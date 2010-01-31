local Recorder = select(2, ...)
Recorder.version = 1

local L = Recorder.L
local CanMerchantRepair, GetInboxHeaderInfo, GetInboxItem, GetInboxItemLink, GetInboxNumItems, GetMerchantItemCostInfo = CanMerchantRepair, GetInboxHeaderInfo, GetInboxItem, GetInboxItemLink, GetInboxNumItems, GetMerchantItemCostInfo
local GetMerchantItemCostItem, GetMerchantItemLink, GetNumFactions, GetNumLootItems, GetNumTrainerServices, GetTrainerGreetingText, LootSlotIsItem, UnitAura, GetTitleText = GetMerchantItemCostItem, GetMerchantItemLink, GetNumFactions, GetNumLootItems, GetNumTrainerServices, GetTrainerGreetingText, LootSlotIsItem, UnitAura, GetTitleText

local DEBUG_LEVEL = 4
local ALLOWED_COORD_DIFF = 0.02
local LOOT_EXPIRATION = 10 * 60
local ZONE_DIFFICULTY = 0

local npcToDB = {["npc"] = "npcs", ["item"] = "items", ["object"] = "objects"}
local NPC_TYPES = {["mailbox"] = 0x01, ["auctioneer"] = 0x02, ["battlemaster"] = 0x04, ["binder"] = 0x08, ["bank"] = 0x10, ["guildbank"] = 0x20, ["canrepair"] = 0x40, ["flightmaster"] = 0x80, ["stable"] = 0x100, ["tabard"] = 0x200, ["vendor"] = 0x400, ["trainer"] = 0x800, ["spiritres"] = 0x1000, ["book"] = 0x2000, ["talentwipe"] = 0x4000}
local BATTLEFIELD_TYPES = {["av"] = 1, ["wsg"] = 2, ["ab"] = 3, ["nagrand"] = 4, ["bem"] = 5, ["all_arenas"] = 6, ["eots"] = 7, ["rol"] = 8, ["sota"] = 9, ["dalaran"] = 10, ["rov"] = 11, ["ioc"] = 30, ["all_battlegrounds"] = 32}
local BATTLEFIELD_MAP = {[L["Alterac Valley"]] = "av", [L["Warsong Gulch"]] = "wsg", [L["Eye of the Storm"]] = "eots", [L["Strand of the Ancients"]] = "sota", [L["Isle of Conquest"]] = "ioc", [L["All Arenas"]] = "all_arenas"}
-- Items to ignore when looted in a *regular* way
local IGNORE_LOOT = {[34055] = true}

local setToAbandon, abandonedName, lootedGUID
local repGain, lootedGUID = {}, {}
local playerName = UnitName("player")

if( DEBUG_LEVEL > 0 ) then MMOCRecorder = Recorder end
local function debug(level, msg, ...)
	if( level <= DEBUG_LEVEL ) then
		print(string.format(msg, ...))
	end
end

function Recorder:InitializeDB()
	local version, build = GetBuildInfo()
	build = tonumber(build) or -1
	
	-- Invalidate he database if the player guid changed or the build changed
	if( SigrieDB and ( not SigrieDB.version or not SigrieDB.build or SigrieDB.build < build ) ) then
		SigrieDB = nil
		debug(1, "Reset DB, %s, %s, %s.", tostring(SigrieDB.version), tostring(SigrieDB.build), tostring(build))
	end
	
	-- Initialize the database
	SigrieDB = SigrieDB or {}
	SigrieDB.class = select(2, UnitClass("player"))
	SigrieDB.race = string.upper(select(2, UnitRace("player")))
	SigrieDB.guid = SigrieDB.guid or UnitGUID("player")
	SigrieDB.version = version
	SigrieDB.build = build
	SigrieDB.locale = GetLocale()
	SigrieDB.addonVersion = self.version
	
	self.db = {}
end

-- GUID changes infrequently enough, I'm not too worried about this
function Recorder:PLAYER_LOGIN()
	local guid = UnitGUID("player")
	if( SigrieDB.guid and SigrieDB.guid ~= guid ) then
		SigrieDB = nil
		self:InitializeDB()
		debug(1, "Reset DB, GUID changed.")
	end
	SigrieDB.guid = guid
end

function Recorder:ADDON_LOADED(event, addon)
	if( addon ~= "+MMOC_Recorder" ) then return end
	self:UnregisterEvent("ADDON_LOADED")
	
	self:InitializeDB()
	if( SigrieDB.error ) then
		DEFAULT_CHAT_FRAME:AddMessage(string.format(L["Message: %s"], SigrieDB.error.msg))
		DEFAULT_CHAT_FRAME:AddMessage(string.format(L["Trace: %s"], SigrieDB.error.trace))
		self:Print(L["An error happened while the MMOC Recorder was serializing your data, please report the above error. You might have to scroll up to see it all."])
		SigrieDB.error = nil
	end
	
	self.tooltip = CreateFrame("GameTooltip", "RecorderTooltip", UIParent, "GameTooltipTemplate")
	self.tooltip:SetOwner(UIParent, "ANCHOR_NONE")
	self.tooltip:Hide()
	
	self.activeSpell = {}
	self.factions = {}
	self:UpdateFactions()

	self:RegisterEvent("MAIL_SHOW")
	self:RegisterEvent("MERCHANT_SHOW")
	self:RegisterEvent("MERCHANT_UPDATE")
	self:RegisterEvent("AUCTION_HOUSE_SHOW")
	self:RegisterEvent("TRAINER_SHOW")
	self:RegisterEvent("PLAYER_LEAVING_WORLD")
	self:RegisterEvent("LOOT_OPENED")
	self:RegisterEvent("LOOT_CLOSED")
	self:RegisterEvent("QUEST_LOG_UPDATE")
	self:RegisterEvent("QUEST_COMPLETE")
	self:RegisterEvent("QUEST_DETAIL")
	self:RegisterEvent("CHAT_MSG_ADDON")
	self:RegisterEvent("UNIT_SPELLCAST_SENT")
	self:RegisterEvent("UNIT_SPELLCAST_SUCCEEDED")
	self:RegisterEvent("WORLD_MAP_UPDATE")
	self:RegisterEvent("COMBAT_TEXT_UPDATE")
	self:RegisterEvent("COMBAT_LOG_EVENT_UNFILTERED")
	self:RegisterEvent("BANKFRAME_OPENED")
	self:RegisterEvent("PET_STABLE_SHOW")
	self:RegisterEvent("GOSSIP_SHOW")
	self:RegisterEvent("CONFIRM_XP_LOSS")
	self:RegisterEvent("TAXIMAP_OPENED")
	self:RegisterEvent("GUILDBANKFRAME_OPENED")
	self:RegisterEvent("PLAYER_TARGET_CHANGED")
	self:RegisterEvent("BATTLEFIELDS_SHOW")
	self:RegisterEvent("CHAT_MSG_SYSTEM")
	self:RegisterEvent("CONFIRM_BINDER")
	self:RegisterEvent("PLAYER_LOGOUT")
	self:RegisterEvent("PLAYER_DIFFICULTY_CHANGED")
	self:RegisterEvent("UPDATE_INSTANCE_INFO")
	self:RegisterEvent("PLAYER_ENTERING_WORLD")
	self:RegisterEvent("ZONE_CHANGED_NEW_AREA")	
	self:RegisterEvent("PLAYER_LOGIN")
	--self:RegisterEvent("ITEM_TEXT_READY")
	self:RegisterEvent("ITEM_TEXT_BEGIN")
	
	self:PLAYER_LEAVING_WORLD()
end

-- For pulling data out of the actual database. This isn't the most efficient system compared to a transparent metatable
-- like I normally use, but because of how the table is structured it's a lot easier to cache "minor" bits of data instead of the ENTIRE table and unserialize it as we need it, also simplifies serializing it again
-- The downside is, it creates duplicate parent and child tables, but it saves a lot more on not loading the excess data
function Recorder:GetBasicData(parent, key)
	self.db[parent] = self.db[parent] or {}
	if( self.db[parent][key] ) then return self.db[parent][key] end
	
	-- Load it out of the database, we've already got it
	if( SigrieDB[parent] and SigrieDB[parent][key] ) then
		local func, msg = loadstring("return " .. SigrieDB[parent][key])
		if( func ) then
			self.db[parent][key] = func()
		else
			geterrorhandler(msg)
		end
	else
		self.db[parent][key] = {}
	end
	
	self.db[parent][key].START_SERIALIZER = true
	return self.db[parent][key]
end

function Recorder:GetData(parent, child, key)
	self.db[parent] = self.db[parent] or {}
	self.db[parent][child] = self.db[parent][child] or {}
	if( self.db[parent][child][key] ) then return self.db[parent][child][key] end
	
	-- Load it out of the database, we've already got it
	if( SigrieDB[parent] and SigrieDB[parent][child] and SigrieDB[parent][child][key] ) then
		local func, msg = loadstring("return " .. SigrieDB[parent][child][key])
		if( func ) then
			self.db[parent][child][key] = func()
		else
			geterrorhandler(msg)
		end
	else
		self.db[parent][child][key] = {}
	end
	
	self.db[parent][child][key].START_SERIALIZER = true
	return self.db[parent][child][key]
end

-- NPC identification
local npcIDMetatable = {
	__index = function(tbl, guid)
		local id = tonumber(string.sub(guid, -12, -7), 16) or false
		rawset(tbl, guid, id)
		return id
	end

}
local npcTypeMetatable = {
	__index = function(tbl, guid)
		local type = tonumber(string.sub(guid, 3, 5), 16)
		local npcType = false
		if( type == 3857 ) then
			npcType = "object"
		elseif( type == 1024 ) then
			npcType = "item"
		elseif( bit.band(type, 0x00f) == 3 ) then
			npcType = "npc"
		end
		
		rawset(tbl, guid, npcType)
		return npcType
	end,
}

function Recorder:PLAYER_LEAVING_WORLD()
	self:SaveQueuedQuest()
	self.GUID_ID = setmetatable({}, npcIDMetatable)
	self.GUID_TYPE = setmetatable({}, npcTypeMetatable)
end

local function parseText(text)
	text = string.gsub(text, "%%d", "%%d+")
	text = string.gsub(text, "%%s", ".+")
	return string.lower(string.trim(text))
end

-- Drunk identification, so we can discard tracking levels until no longer drunk
local DRUNK_ITEM1, DRUNK_ITEM2, DRUNK_ITEM3, DRUNK_ITEM4 = string.gsub(DRUNK_MESSAGE_ITEM_SELF1, "%%s", ".+"), string.gsub(DRUNK_MESSAGE_ITEM_SELF2, "%%s", ".+"), string.gsub(DRUNK_MESSAGE_ITEM_SELF3, "%%s", ".+"), string.gsub(DRUNK_MESSAGE_ITEM_SELF4, "%%s", ".+")
function Recorder:CHAT_MSG_SYSTEM(event, message)
	if( message == DRUNK_MESSAGE_SELF1 ) then
		self.playerIsDrunk = nil
	elseif( not self.playerIsDrunk and ( message == DRUNK_MESSAGE_SELF2 or message == DRUNK_MESSAGE_SELF4 or message == DRUNK_MESSAGE_SELF3 ) ) then
		self.playerIsDrunk = true
	elseif( not self.playerIsDrunk and ( string.match(message, DRUNK_ITEM1) or string.match(message, DRUNK_ITEM2) or string.match(message, DRUNK_ITEM3) or string.match(message, DRUNK_ITEM4) ) ) then
		self.playerIsDrunk = true
	end
end

-- Rating identification
local ITEM_REQ_ARENA_RATING = "^" .. parseText(ITEM_REQ_ARENA_RATING)
local ITEM_REQ_ARENA_RATING_3V3 = "^" .. parseText(ITEM_REQ_ARENA_RATING_3V3)
local ITEM_REQ_ARENA_RATING_5V5 = "^" .. parseText(ITEM_REQ_ARENA_RATING_5V5)

function Recorder:GetArenaData(index)
	self.tooltip:SetMerchantItem(index)
	for i=1, self.tooltip:NumLines() do
		local text = _G["RecorderTooltipTextLeft" .. i]:GetText()
		
		local rating = string.match(text, ITEM_REQ_ARENA_RATING_5V5)
		if( rating ) then
			return tonumber(rating), 5
		end
		
		local rating = string.match(text, ITEM_REQ_ARENA_RATING_3V3)
		if( rating ) then
			return tonumber(rating), 3
		end
		
		local rating = string.match(text, ITEM_REQ_ARENA_RATING)
		if( rating ) then
			return tonumber(rating)
		end
	end
	
	return nil
end

-- Faction discounts
function Recorder:UpdateFactions()
	-- If you use GetNumFactions, you will miss those that are collapsed
	local i = 1
	while( true ) do
		local name, _, standing, _, _, _, _, _, header = GetFactionInfo(i)
		if( not name ) then break end
		if( name and not header ) then
			self.factions[name] = standing
		end
		
		i = i + 1
	end
end

function Recorder:GetFaction(guid)
	if( not guid ) then return 1 end
	self:UpdateFactions()
	
	local faction
	self.tooltip:SetHyperlink(string.format("unit:%s", guid))
	for i=1, self.tooltip:NumLines() do
		local text = _G["RecorderTooltipTextLeft" .. i]:GetText()
		if( text and self.factions[text] ) then
			return text
		end
	end
	
	return nil
end

function Recorder:GetFactionDiscount(guid)
	local faction = self:GetFaction(guid)
	if( not faction ) then return 1 end
	return self.factions[faction] == 5 and 0.95 or self.factions[faction] == 6 and 0.90 or self.factions[faction] == 7 and 0.85 or self.factions[faction] == 8 and 0.80 or 1
end

-- Reputation and spell handling
local COMBATLOG_OBJECT_REACTION_HOSTILE = COMBATLOG_OBJECT_REACTION_HOSTILE
local eventsRegistered = {["PARTY_KILL"] = true, ["SPELL_CAST_SUCCESS"] = true, ["SPELL_CAST_START"] = true, ["SPELL_AURA_APPLIED"] = true}
function Recorder:COMBAT_LOG_EVENT_UNFILTERED(event, timestamp, eventType, sourceGUID, sourceName, sourceFlags, destGUID, destName, destFlags, ...)
	if( not eventsRegistered[eventType] ) then return end
	
	if( ( eventType == "SPELL_CAST_START" or eventType == "SPELL_CAST_SUCCESS" or eventType == "SPELL_AURA_APPLIED" ) and bit.band(sourceFlags, COMBATLOG_OBJECT_TYPE_NPC) == COMBATLOG_OBJECT_TYPE_NPC ) then
		local spellID = ...
		local type = eventType == "SPELL_AURA_APPLIED" and "auras" or "spells"
		local npcData = self:GetData("npcs", ZONE_DIFFICULTY, self.GUID_ID[sourceGUID])
		npcData[type] = npcData[type] or {}
		npcData[type][spellID] = true
		if( not npcData[type][spellID] ) then
			debug(4, "%s casting %s %s (%d)", sourceName, type, select(2, ...), spellID)
		end
		
	elseif( eventType == "PARTY_KILL" and bit.band(destFlags, COMBATLOG_OBJECT_REACTION_HOSTILE) == COMBATLOG_OBJECT_REACTION_HOSTILE and bit.band(destFlags, COMBATLOG_OBJECT_TYPE_NPC) == COMBATLOG_OBJECT_TYPE_NPC ) then
		repGain.npcID = self.GUID_ID[destGUID]
		repGain.npcType = self.GUID_TYPE[destGUID]
		repGain.timeout = GetTime() + 1
	end
end

-- Reputation modifiers
local reputationModifiers = {
	[GetSpellInfo(39953)] = true, -- A'dal's Song of Battle
	[GetSpellInfo(30754)] = true, -- Cenarion Favor
	[GetSpellInfo(32098)] = true, -- Honor Hold's Favor
	[GetSpellInfo(24705)] = true, -- Invocation of the Wickerman
	[GetSpellInfo(39913)] = true, -- Nazgrel's Fervor
	[GetSpellInfo(61849)] = true, -- The Spirit of Sharing
	[GetSpellInfo(58440)] = true, -- Pork Red Ribbon (Cause Adys is crazy)
}
	
function Recorder:HasReputationModifier()
	if( select(2, UnitRace("player")) == "Human" ) then return true end
	
	for name in pairs(reputationModifiers) do
		if( UnitBuff("player", name) ) then
			return true
		end
	end
	
	return false
end

function Recorder:COMBAT_TEXT_UPDATE(event, type, faction, amount)
	if( type ~= "FACTION" ) then return end
	
	if( repGain.timeout and repGain.timeout >= GetTime() and not self:HasReputationModifier() ) then
		local npcData = self:GetData(npcToDB[repGain.npcType], ZONE_DIFFICULTY, repGain.npcID)
		npcData.info = npcData.info or {}
		npcData.info.faction = faction
		npcData.info.factionAmount = amount
		
		debug(2, "NPC #%d gives %d %s faction", repGain.npcID, amount, faction)
	end
end

-- Handle quest abandoning
hooksecurefunc("AbandonQuest", function()
	abandonedName = setToAbandon
	setToAbandon = nil
end)

hooksecurefunc("SetAbandonQuest", function()
	setToAbandon = GetAbandonQuestName()
end)

Recorder.InteractSpells = {
	-- Opening
	[GetSpellInfo(3365) or ""] = {item = true, location = true},
	-- Herb Gathering
	[GetSpellInfo(2366) or ""] = {item = true, location = true},
	-- Mining
	[GetSpellInfo(2575) or ""] = {item = true, location = true},
	-- Disenchanting
	[GetSpellInfo(13262) or ""] = {item = true, location = false, parentItem = true},
	-- Milling
	[GetSpellInfo(51005) or ""] = {item = true, location = false, parentItem = true},
	-- Prospecting
	[GetSpellInfo(31252) or ""] = {item = true, location = false, parentItem = true},
	-- Skinning
	[GetSpellInfo(8613) or ""] = {item = true, location = false, parentNPC = true, lootType = "skinning"},
	-- Engineering
	[GetSpellInfo(49383) or ""] = {item = true, location = false, parentNPC = true, lootType = "engineering"},
	-- Fishing
	[GetSpellInfo(13615) or ""] = {item = true, lootByZone = true, lootType = "fishing"},
	-- Pick Pocket
	[GetSpellInfo(921) or ""] = {item = true, location = false, parentNPC = true, lootType = "pickpocket"},
	-- Used when opening an item, such as Champion's Purse
	["Bag"] = {item = true, location = false, parentItem = true},
	-- Pick Lock
	--[GetSpellInfo(1804) or ""] = {item = true, location = false, parentItem = true},
}

-- Might have to use DungeonUsesTerrainMap, Blizzard seems to use it for subtracting from dungeon level?
function Recorder:RecordLocation()
	local currentCont = GetCurrentMapContinent()
	local currentZone = GetCurrentMapZone()
	local currentLevel = GetCurrentMapDungeonLevel()
	
	SetMapToCurrentZone()
	local dungeonLevel, zone = GetCurrentMapDungeonLevel(), GetMapInfo()
	local x, y = GetPlayerMapPosition("player")

	if( x == 0 and y == 0 ) then
		for level=1, GetNumDungeonMapLevels() do
			SetDungeonMapLevel(level)
			x, y = GetPlayerMapPosition("player")
			
			if( x > 0 and y > 0 ) then
				dungeonLevel = level
				break
			end
		end
	end

	SetMapZoom(currentCont, currentZone)
	SetDungeonMapLevel(currentLevel)
	
	-- No map, return zone name + sub zone
	if( x == 0 and y == 0 and IsInInstance() ) then
		return 0, 0, GetRealZoneText(), GetSubZoneText()
	end

	return tonumber(string.format("%.2f", x * 100)), tonumber(string.format("%.2f", y * 100)), zone, dungeonLevel
end

-- For recording a location by zone, primarily for fishing
function Recorder:RecordZoneLocation(type)
	local x, y, zone, level = self:RecordLocation()
	local zoneData = self:GetData("zone", ZONE_DIFFICULTY, zone)
	zoneData.coords = zoneData.coords or {}
	
	if( x == 0 and y == 0 and type(level) == "string" ) then
		for i=1, #(zoneData.coords), 5 do
			if( zoneData.coords[i] == 0 and zoneData.coords[i + 1] == 0 and zoneData.coords[i + 2] == zone and zoneData.coords[i + 3] == level ) then
				return zoneData
			end
		end
		
		table.insert(zoneData.coords, x)
		table.insert(zoneData.coords, y)
		table.insert(zoneData.coords, zone)
		table.insert(zoneData.coords, level)
		table.insert(zoneData.coords, 1)
		
		debug(3, "Recording %s location in %s (%s), no map found", type, zone, level)
		return zoneData
	end
	
	-- See if we already have an entry for them
	for i=1, #(zoneData.coords), 4 do
		local npcX, npcY, npcLevel, npcCount = zoneData.coords[i], zoneData.coords[i + 1], zoneData.coords[i + 2], zoneData.coords[i + 3]
		if( npcLevel == level ) then
			local xDiff, yDiff = math.abs(npcX - x), math.abs(npcY - y)
			if( xDiff <= ALLOWED_COORD_DIFF and yDiff <= ALLOWED_COORD_DIFF ) then
				zoneData.coords[i] = tonumber(string.format("%.2f", (npcX + x) / 2))
				zoneData.coords[i + 1] = tonumber(string.format("%.2f", (npcY + y) / 2))
				zoneData.coords[i + 4] = npcCount + 1
				
				debug(3, "Recording %s location at %.2f, %.2f in %s (%d level), counter %d", type, x, y, zone, level, zoneData.coords[i + 4])
				return zoneData
			end
		end
	end
	
	table.insert(zoneData.coords, x)
	table.insert(zoneData.coords, y)
	table.insert(zoneData.coords, level)
	table.insert(zoneData.coords, 1)
	debug(3, "Recording %s location at %.2f, %.2f in %s (%d level), counter %d", type, x, y, zone, level, 1)
	
	return zoneData
end

-- Location, location, location
function Recorder:RecordDataLocation(type, npcID, isGeneric)
	local x, y, zone, level = self:RecordLocation()
	local coordModifier = isGeneric and 200 or 0
	local npcData = self:GetData(type, ZONE_DIFFICULTY, npcID)
	npcData.coords = npcData.coords or {}
	
	if( x == 0 and y == 0 and type(level) == "string" ) then
		for i=1, #(npcData.coords), 5 do
			if( npcData.coords[i] == 0 and npcData.coords[i + 1] == 0 and npcData.coords[i + 2] == zone and npcData.coords[i + 3] == level ) then
				return npcData
			end
		end
		
		table.insert(npcData.coords, x)
		table.insert(npcData.coords, y)
		table.insert(npcData.coords, zone)
		table.insert(npcData.coords, level)
		table.insert(npcData.coords, 1)
		
		debug(3, "Recording npc %s (%s) location in %s (%s), no map found", npcID, type, zone, level)
		return npcData
	end
	
	-- See if we already have an entry for them
	for i=1, #(npcData.coords), 5 do
		local npcX, npcY, npcZone, npcLevel, npcCount = npcData.coords[i], npcData.coords[i + 1], npcData.coords[i + 2], npcData.coords[i + 3], npcData.coords[i + 4]
		if( npcLevel == level and npcZone == zone ) then
			-- If the recorded one is a generic coord, will check against the "normal" one to see if we can merge them
			-- if they are both generics, will readd the 200 modifier
			local modifier = 0
			if( npcX >= 200 and npcY >= 200 ) then
				npcX = npcX - 200
				npcY = npcY - 200
				
				modifier = isGeneric and 200 or 0
			end
			
			local xDiff, yDiff = math.abs(npcX - x), math.abs(npcY - y)
			if( xDiff <= ALLOWED_COORD_DIFF and yDiff <= ALLOWED_COORD_DIFF ) then
				npcData.coords[i] = tonumber(string.format("%.2f", (npcX + x) / 2)) + modifier
				npcData.coords[i + 1] = tonumber(string.format("%.2f", (npcY + y) / 2)) + modifier
				npcData.coords[i + 4] = npcCount + 1
				
				debug(3, "Recording npc %s (%s) location at %.2f, %.2f in %s (%d level), counter %d, generic %s", npcID, type, x, y, zone, level, npcData.coords[i + 4], tostring(isGeneric))
				return npcData
			end
		end
	end
	
	-- No data yet
	table.insert(npcData.coords, x + coordModifier)
	table.insert(npcData.coords, y + coordModifier)
	table.insert(npcData.coords, zone)
	table.insert(npcData.coords, level)
	table.insert(npcData.coords, 1)
	
	debug(3, "Recording npc %s location at %.2f, %.2f in %s (%d level), generic %s", npcID, x, y, zone, level, tostring(isGeneric))
	return npcData
end

-- Add all of the data like title, health, power, faction, etc here
function Recorder:GetCreatureDB(unit)
	local guid = UnitGUID(unit)
	local npcID, npcType = self.GUID_ID[guid], self.GUID_TYPE[guid]
	if( not npcID or not npcType ) then return end
	
	return self:GetData(npcToDB[npcType], ZONE_DIFFICULTY, npcID), npcID, npcType
end

function Recorder:RecordCreatureType(npcData, type)
	npcData.info.bitType = npcData.info.bitType and bit.bor(npcData.info.bitType, NPC_TYPES[type]) or NPC_TYPES[type]
	debug(3, "Recording npc %s, type %s", npcData.info and npcData.info.name or "nil", type)
end

function Recorder:RecordCreatureData(type, unit)
	local npcData, npcID, npcType = self:GetCreatureDB(unit)
	if( not npcData ) then return end

	local hasAura = UnitAura(unit, 1, "HARMFUL") or UnitAura(unit, 1, "HELPFUL")
	local level = UnitLevel(unit)
	
	npcData.info = npcData.info or {}
	npcData.info.name = UnitName(unit)
	npcData.info.reaction = UnitReaction("player", unit)
	npcData.info.faction = self:GetFaction(unit)
	
	-- Store by level for these
	if( level and not self.playerIsDrunk ) then
		npcData.info[level] = npcData.info[level] or {}
		npcData.info[level].maxHealth = hasAura and npcData.info.maxHealth or npcData.info.maxHealth and math.max(npcData.info.maxHealth, UnitHealthMax(unit)) or UnitHealthMax(unit)
		npcData.info[level].maxPower = hasAura and npcData.info.maxPower or npcData.info.maxPower and math.min(npcData.info.maxPower, UnitPowerMax(unit)) or UnitPowerMax(unit)
		npcData.info[level].powerType = UnitPowerType(unit)
		
		debug(2, "Recording npc data, %s #%s (%s primary, %s guid), %d level, %d health, %d power (%d type)", npcData.info.name, npcID, type or "nil", npcType, level, npcData.info[level].maxHealth or -1, npcData.info[level].maxPower or -1, npcData.info[level].powerType or -1)
	end
	
	if( type and type ~= "generic" ) then
		self:RecordCreatureType(npcData, type)
	end

	self:RecordDataLocation(npcToDB[npcType], npcID, type == "generic")
	return npcData
end

-- Record trainer data
local playerCache
function Recorder:UpdateTrainerData(npcData)
	-- No sense in recording training data unless the data was reset. It's not going to change
	if( npcData.taeches ) then return end
	
	local guid = UnitGUID("npc")
	local factionDiscount = self:GetFactionDiscount(guid)
	local trainerSpellMap = {}

	npcData.info.greeting = GetTrainerGreetingText()
	npcData.teaches = {}
	
	-- Save the original settings
	local availActive = GetTrainerServiceTypeFilter("available")
	local unavailActive = GetTrainerServiceTypeFilter("unavailable")
	local usedActive = GetTrainerServiceTypeFilter("used")
	SetTrainerServiceTypeFilter("available", 1)
	SetTrainerServiceTypeFilter("unavailable", 1)
	SetTrainerServiceTypeFilter("used", 1)	

	-- Cache the spell name -> spellID to reduce the need for associating spell names to spell ids manually
	if( not playerCache ) then
		playerCache = {}
		local offset, numSpells = select(3, GetSpellTabInfo(GetNumSpellTabs()))
		for id=1, (offset + numSpells) do
			local spellName, spellRank = GetSpellName(id, BOOKTYPE_SPELL)
			self.tooltip:SetSpell(id, BOOKTYPE_SPELL)
			
			local spellID = select(3, self.tooltip:GetSpell())
			if( spellID ) then
				if( spellRank and spellRank ~= "" ) then
					playerCache[string.format("%s (%s)", spellName, spellRank)] = spellID
				else
					playerCache[spellName] = spellID
				end
			end
		end
	end
	-- Scan everything!
	for serviceID=1, GetNumTrainerServices() do
		local serviceName, serviceSubText, serviceType, isExpanded = GetTrainerServiceInfo(serviceID)
		
		if( serviceType ~= "header" ) then
			local moneyCost, talentCost, skillCost = GetTrainerServiceCost(serviceID)
			self.tooltip:SetOwner(UIParent, "ANCHOR_NONE")
			self.tooltip:SetTrainerService(serviceID)
			
			local spellID = select(3, self.tooltip:GetSpell())
			if( spellID ) then
				-- Apparently :GetSpell() is not returning rank anymore?
				local spellName, spellRank = GetSpellInfo(spellID)
				
				-- Used for associating requirements with spellID if possible
				if( spellRank and spellRank ~= "" ) then
					trainerSpellMap[string.format("%s (%s)", spellName, spellRank)] = spellID
				else
					trainerSpellMap[spellName] = spellID
				end
				
				local teach = {["id"] = spellID, ["price"] = moneyCost / factionDiscount, ["levelReq"] = GetTrainerServiceLevelReq(serviceID)}
				
				-- For Typhoon (Rank 2)
				if( GetTrainerServiceNumAbilityReq(serviceID) > 0 ) then
					teach.abilityRequirements = {}
					
					-- Requirements are always listed before the ability required, Typhoon (Rank 2) is after Typhon (Rank 1)
					-- this shouldn't need any special "queuing" or rechecking
					for reqID=1, GetTrainerServiceNumAbilityReq(serviceID) do
						local reqName, hasReq = GetTrainerServiceAbilityReq(serviceID, reqID)
						table.insert(teach.abilityRequirements, trainerSpellMap[reqName] or playerCache[reqName] or reqName)
					end
				end
				
				-- For Enchanting (50) etc
				local skill, rank = GetTrainerServiceSkillReq(serviceID)
				teach.skillReq = skill
				teach.skillLevelReq = rank
				
				table.insert(npcData.teaches, teach)
			end
		end
	end
	
	-- Restore!				
	SetTrainerServiceTypeFilter("available", availActive or 0)
	SetTrainerServiceTypeFilter("unavailable", unavailActive or 0)
	SetTrainerServiceTypeFilter("used", usedActive or 0)
end

-- Record merchant items
-- This should be changed to use some sort of ID, such as price .. cost to identify items
-- that way if an item is limited it won't be wiped when they review it after it's been bought out
function Recorder:UpdateMerchantData(npcData)
	if( CanMerchantRepair() ) then
		self:RecordCreatureType(npcData, "canrepair")
	end
	
	npcData.sold = npcData.sold or {}
	table.wipe(npcData.sold)
	
	local factionDiscount = self:GetFactionDiscount(UnitGUID("npc"))
	for i=1, GetMerchantNumItems() do
		local name, _, price, quantity, limitedQuantity, _, extendedCost = GetMerchantItemInfo(i)
		if( name ) then
			local itemCost, bracket, rating
			local honor, arena, total = GetMerchantItemCostInfo(i)
			-- If it costs honor or arena points, check for a personal rating
			if( honor > 0 or arena > 0 ) then
				rating, bracket = self:GetArenaData(i)
			end
			
			-- Check for item quest (Tokens -> Tier set/etc)
			for extendedIndex=1, total do
				local amount, link = select(2, GetMerchantItemCostItem(i, extendedIndex))
				if( link ) then
					itemCost = itemCost or {}
					itemCost[tonumber(string.match(link, "item:(%d+)"))] = amount
				end
			end
			
			honor = honor > 0 and honor or nil
			arena = arena > 0 and arena or nil
			limitedQuantity = limitedQuantity >= 0 and limitedQuantity or nil
			
			-- Can NPCs sell anything besides items? I don't think so
			local itemID = tonumber(string.match(GetMerchantItemLink(i), "item:(%d+)"))
			table.insert(npcData.sold, {id = itemID, price = price / factionDiscount, quantity = quantity, limitedQuantity = limitedQuantity, honor = honor, arena = arena, rating = rating, bracket = bracket, itemCost = itemCost})
		end
	end
end

-- LOOT TRACKING AND ALL HIS PALS
function Recorder:CHAT_MSG_ADDON(prefix, message, channel, sender)
	if( sender == playerName or prefix ~= "Recorder" or ( channel ~= "RAID" and channel ~= "PARTY" ) ) then return end
	
	local type, arg = string.split(":", message, 2)
	if( type == "loot" ) then
		lootedGUID[arg] = GetTime() + LOOT_EXPIRATION
	end
end

local COPPER_AMOUNT = string.gsub(COPPER_AMOUNT, "%%d", "(%%d+)")
local SILVER_AMOUNT = string.gsub(SILVER_AMOUNT, "%%d", "(%%d+)")
local GOLD_AMOUNT = string.gsub(GOLD_AMOUNT, "%%d", "(%%d+)")

function Recorder:LOOT_CLOSED()
	self.activeSpell.object = nil
end

function Recorder:LOOT_OPENED()
	local npcData, isMob
	local time = GetTime()
	-- Object set, so looks like we're good
	if( self.activeSpell.object and self.activeSpell.endTime <= (time + 0.50) ) then
		-- We want to save it by the zone, this is really just for Fishing.
		if( self.activeSpell.object.lootByZone ) then
			npcData = self:RecordZoneLocation(self.activeSpell.object.lootType)
		-- It has a location, meaning it's some sort of object
		elseif( self.activeSpell.object.location ) then
			npcData = self:RecordDataLocation("objects", self.activeSpell.target)
		-- This has a parent item like Milling, Prospecting or Disenchanting, so record the data their
		elseif( self.activeSpell.object.parentItem ) then
			local itemID = tonumber(string.match(self.activeSpell.item, "item:(%d+)"))
			npcData = self:GetBasicData("items", itemID)
			
		-- Has a parent NPC, so skinning, engineering, etc
		elseif( self.activeSpell.object.parentNPC ) then
			npcData = self:GetCreatureDB("target")
			npcData[self.activeSpell.object.lootType] = npcData[self.activeSpell.object.lootType] or {}
			npcData = npcData[self.activeSpell.object.lootType]
		end

	-- If the target exists, is dead, not a player, and it's an actual NPC then we will say we're looting that NPC
	elseif( UnitExists("target") and UnitIsDead("target") and not UnitIsPlayer("target") ) then
		local guid = UnitGUID("target")
		if( not guid or lootedGUID[guid] ) then
			return
		end
		
		lootedGUID[guid] = time + LOOT_EXPIRATION

		-- Make sure the GUID is /actually an NPC ones
		local npcID = self.GUID_TYPE[guid] == "npc" and self.GUID_ID[guid]
		if( npcID ) then
			npcData = self:RecordCreatureData(nil, "target")
			isMob = true
			
			-- This is necessary because sending it just to raid or party without checking can cause not in raid errors
			local instanceType = select(2, IsInInstance())
			if( instanceType ~= "arena" and instanceType ~= "pvp" and ( GetNumPartyMembers() > 0 or GetNumRaidMembers() > 0 ) ) then
				SendAddonMessage("Recorder", string.format("loot:%s", guid), "RAID")
			end
		end
	end
	
	-- Clean up the list
	for guid, expiresOn in pairs(lootedGUID) do
		if( expiresOn <= time ) then
			lootedGUID[guid] = nil
		end
	end
	
	if( not npcData ) then return end
	npcData.looted = (npcData.looted or 0) + 1
		
	for i=1, GetNumLootItems() do
		-- Parse out coin
		if( LootSlotIsCoin(i) ) then
			local currency = select(2, GetLootSlotInfo(i))
			local gold = (tonumber(string.match(currency, GOLD_AMOUNT)) or 0) * COPPER_PER_GOLD
			local silver = (tonumber(string.match(currency, SILVER_AMOUNT)) or 0) * COPPER_PER_SILVER
			
			npcData.coin = npcData.coin or {}
			table.insert(npcData.coin, (tonumber(string.match(currency, COPPER_AMOUNT)) or 0) + gold + silver)
		-- Record item data
		elseif( LootSlotIsItem(i) ) then
			local link = GetLootSlotLink(i)
			local itemID = link and tonumber(string.match(link, "item:(%d+)"))
			if( itemID and ( not isMob or not IGNORE_LOOT[itemID] ) ) then
				local quantity = select(3, GetLootSlotInfo(i))
				
				-- If we have an NPC ID then associate the npc with dropping that item
				npcData.loot = npcData.loot or {}
				npcData.loot[itemID] = npcData.loot[itemID] or {}
				npcData.loot[itemID].looted = (npcData.loot[itemID].looted or 0) + 1
				npcData.loot[itemID].minStack = npcData.loot[itemID].minStack and math.min(npcData.loot[itemID].minStack, quantity) or quantity
				npcData.loot[itemID].maxStack = npcData.loot[itemID].maxStack and math.max(npcData.loot[itemID].maxStack, quantity) or quantity
				
				debug(2, "Looted item %d from them %d out of %d times", itemID, npcData.loot[itemID].looted, npcData.looted)
			end
		end
	end
end

-- Record items being opened
local function itemUsed(link)
	if( Recorder.activeSpell.object and Recorder.activeSpell.object.parentItem and not Recorder.activeSpell.useSet ) then
		Recorder.activeSpell.item = link
		Recorder.activeSpell.useSet = true
	elseif( not Recorder.activeSpell.endTime or Recorder.activeSpell.endTime <= (time() + 0.30) ) then
		Recorder.activeSpell.item = link
		Recorder.activeSpell.endTime = GetTime()
		Recorder.activeSpell.object = Recorder.InteractSpells.Bag
	end
end

hooksecurefunc("UseContainerItem", function(bag, slot, target)
	if( not target ) then
		itemUsed(GetContainerItemLink(bag, slot))
	end
end)

hooksecurefunc("UseItemByName", function(name, target)
	if( not target ) then
		itemUsed(select(2, GetItemInfo(name)))
	end
end)


function Recorder:UNIT_SPELLCAST_SENT(event, unit, name, rank, target)
	if( unit ~= "player" or not self.InteractSpells[name] ) then return end

	local itemName, link = GameTooltip:GetItem()
	self.activeSpell.name = name
	self.activeSpell.rank = rank
	self.activeSpell.target = target
	self.activeSpell.startTime = GetTime()
	self.activeSpell.endTime = -1
	self.activeSpell.item = link
	self.activeSpell.useSet = nil
	self.activeSpell.object = self.InteractSpells[name]
end

function Recorder:UNIT_SPELLCAST_SUCCEEDED(event, unit, name, rank)
	if( unit ~= "player" ) then return end
	
	if( self.activeSpell.endTime == -1 and self.activeSpell.name == self.activeSpell.name and self.activeSpell.rank == rank ) then
		self.activeSpell.endTime = GetTime()
	end
end

function Recorder:UNIT_SPELLCAST_FAILED(event, unit)
	if( unit ~= "player" ) then return end
	
	self.activeSpell.object = nil
end

-- QUEST DATA HANDLER
function Recorder:GetQuestName(questID)
	self.tooltip:SetOwner(UIParent, "ANCHOR_NONE")
	self.tooltip:SetHyperlink(string.format("quest:%d", questID))
	
	return RecorderTooltipTextLeft1:GetText()
end

local lastRecordedPOI = {}
function Recorder:RecordQuestPOI(questID)
	local posX, posY, objectiveID = select(2, QuestPOIGetIconInfo(questID))
	if( not posX or not posY or GetCurrentMapZone() == 0 ) then return end

	-- Quick ID so we're not saving the POIs every single map update, which tends to be a bit spammy
	local currentLevel = GetCurrentMapDungeonLevel()
	local poiID = posX + (currentLevel * 100) + (posY * 1000) + (objectiveID * 10000)
	if( lastRecordedPOI[questID] and lastRecordedPOI[questID] == poiID ) then return end
	lastRecordedPOI[questID] = poiID
	
	local questData = self:GetBasicData("quests", questID)
	questData.poi = questData.poi or  {}

	local currentZone = GetMapInfo()
	local posX, posY = tonumber(string.format("%.2f", posX * 100)), tonumber(string.format("%.2f", posY * 100))

	-- POIs don't change, if we find one with all the same data then we can just exit
	-- You can't simply index the table by objective ID and go by that because some quests can have different coords with the same objective
	for i=1, #(questData.poi), 5 do
		local dataX, dataY, dataObjectiveID, dataLevel, dataZone = questData.poi[i], questData.poi[i + 1], questData.poi[i + 2], questData.poi[i + 3], questData.poi[i + 4]
		if( dataZone == currentZone and dataLevel == currentLevel and dataObjectiveID == objectiveID and dataX == posX and dataY == posY ) then
			return
		end
	end
	
	table.insert(questData.poi, posX)
	table.insert(questData.poi, posY)
	table.insert(questData.poi, objectiveID)
	table.insert(questData.poi, currentLevel)
	table.insert(questData.poi, currentZone)

	debug(3, "Recording quest poi %s location at %.2f, %.2f, obj %d, in %s (%d level)", questID, posX, posY, objectiveID, currentZone, currentLevel)
end

function Recorder:WORLD_MAP_UPDATE()
	for i=1, QuestMapUpdateAllQuests() do
		local questID, logIndex = QuestPOIGetQuestIDByVisibleIndex(i)
		if( questID and logIndex and logIndex > 0 ) then
			self:RecordQuestPOI(questID)
		end
	end
end

-- Quest log updated, see what changed quest-wise
local questGiverType, questGiverID
local tempQuestLog, questByName, questLog = {}, {}
function Recorder:QUEST_LOG_UPDATE(event)
	-- Scan quest log
	local foundQuests, index = 0, 1
	local numQuests = select(2, GetNumQuestLogEntries())
	while( foundQuests <= numQuests ) do
		local questName, _, _, _, isHeader = GetQuestLogTitle(index)
		if( not questName ) then break end
		
		if( not isHeader ) then
			foundQuests = foundQuests + 1
			
			local questID = string.match(GetQuestLink(index), "quest:(%d+)")
			tempQuestLog[tonumber(questID)] = true
			
			-- If the quest log has it, then will be able to get the GUID for it
			if( questByName.name == questName ) then
				table.wipe(questByName)
			end
		end
		
		index = index + 1
	end
	
	-- We don't have any previous data to go off of yet, store what we had
	if( not questLog ) then
		questLog = CopyTable(tempQuestLog)
		return
	end
		
	-- Find quests we accepted
	if( questGiverID ) then
		for questID in pairs(tempQuestLog) do
			if( not questLog[questID] and questGiverType ) then
				local questData = self:GetBasicData("quests", questID)
				questData.startsID = questGiverID * (questGiverType == "npc" and 1 or -1)
				
				debug(1, "Quest #%d starts at %s #%d.", questID, questGiverType or "nil", questGiverID or -1)
				self:RecordQuestPOI(questID)
			end
		end
	end

	-- Find quests we abandoned or accepted
	for questID in pairs(questLog) do
		if( not tempQuestLog[questID] ) then
			if( abandonedName and abandonedName == self:GetQuestName(questID) ) then
				lastRecordedPOI[questID] = nil
				questLog[questID] = nil
				abandonedName = nil
				
				debug(1, "Quest #%d abandoned", questID)
				break
			elseif( not abandonedName and questGiverID ) then
				questLog[questID] = nil
				lastRecordedPOI[questID] = nil
				
				local questData = self:GetBasicData("quests", questID)
				questData.endsID = questGiverID * (questGiverType == "npc" and 1 or -1)
				
				debug(1, "Quest #%d ends at %s #%d.", questID, questGiverType or "nil", questGiverID or -1)	
			end
		end
	end
					
	for questID in pairs(tempQuestLog) do questLog[questID] = true end
	table.wipe(tempQuestLog)
end

-- Because we can't save by ID for these, but we don't want to store all by name, the data will get queued
-- so we can make sure it's not going to popup in the quest log
function Recorder:SaveQueuedQuest()
	if( questByName.name ) then
		debug(3, "Found quest %s that does not enter log, starts/ends at %d", questByName.name, questByName.id)

		local questData = self:GetBasicData("quests", questByName.name)
		questData.startsID = id
		questData.endsID = id
		questByName.name = nil
	end
end

function Recorder:QuestProgress()
	local guid = UnitGUID("npc")
	local id, type = self.GUID_ID[guid], self.GUID_TYPE[guid]
	
	-- Don't need to record start location of items
	if( type ~= "item" ) then
		questGiverID, questGiverType = id, type
		self:RecordCreatureData(nil, "npc")
		self:SaveQueuedQuest()
		
		-- Store it by name temporarily as the NPC starting and ending it
		local id = questGiverID * (questGiverType == "npc" and 1 or -1)
		questByName.name = GetTitleText()
		questByName.id = id
	end
end

function Recorder:QUEST_COMPLETE(event)
	self:QuestProgress()
end

-- We're looking at the details of the quest, save the quest info so we can use it later
function Recorder:QUEST_DETAIL(event)
	-- When a quest is shared with the player, "npc" is actually the "player" unitid
	if( UnitIsPlayer("npc") ) then
		questGiverType, questGiverID = nil, nil
		return
	end
	
	self:QuestProgress()
end

-- General handling
function Recorder:AUCTION_HOUSE_SHOW()
	self:RecordCreatureData("auctioneer", "npc")
end

function Recorder:MAIL_SHOW()
	self:RecordCreatureData("mailbox", "npc")
end

local merchantData
function Recorder:MERCHANT_SHOW()
	merchantData = self:RecordCreatureData("vendor", "npc")
	self:UpdateMerchantData(merchantData)
end

function Recorder:MERCHANT_UPDATE()
	self:UpdateMerchantData(merchantData)
end

function Recorder:TRAINER_SHOW()
	local npcData = self:RecordCreatureData("trainer", "npc")
	self:UpdateTrainerData(npcData)
end

function Recorder:PET_STABLE_SHOW()
	self:RecordCreatureData("stable", "npc")
end

function Recorder:TAXIMAP_OPENED()
	local npcData = self:RecordCreatureData("flightmaster", "npc")
	for i=1, NumTaxiNodes() do
		if( TaxiNodeGetType(i) == "CURRENT" ) then
			npcData.info.taxiNode = TaxiNodeName(i)
			debug(3, "Set taxi node to %s.", npcData.info.taxiNode)
			break
		end
	end
end

function Recorder:BANKFRAME_OPENED()
	self:RecordCreatureData("bank", "npc")
end

function Recorder:CONFIRM_XP_LOSS()
	self:RecordCreatureData("spiritres", "npc")
end

function Recorder:CONFIRM_BINDER()
	self:RecordCreatureData("binder", "npc")
end

function Recorder:GUILDBANKFRAME_OPENED()
	if( UnitGUID("npc") ) then
		self:RecordCreatureData("guildbank", "npc")
	end
end

function Recorder:PLAYER_TARGET_CHANGED()
	if( UnitExists("target") and not UnitPlayerControlled("target") and not UnitAffectingCombat("target") and CheckInteractDistance("target", 3) ) then
		self:RecordCreatureData("generic", "target")
	end
end

function Recorder:BATTLEFIELDS_SHOW()
	if( not UnitExists("npc") ) then return end

	local type = BATTLEFIELD_TYPES[BATTLEFIELD_MAP[GetBattlefieldInfo()] or ""]
	if( type ) then
		local npcData = self:RecordCreatureData("battlemaster", "target")
		npcData.info.battlefields = type
	end
end

-- Record book locations
function Recorder:ITEM_TEXT_BEGIN()
	-- ItemTextGetCreator() is true if the item is from an user, such as mail letters
	local guid = UnitGUID("npc")
	if( not ItemTextGetCreator() and self.GUID_TYPE[guid] ) then
		self:RecordDataLocation("objects", self.GUID_ID[guid])
	end
end

-- Gossip returns most of the types: banker, battlemaster, binder, gossip, tabard, taxi, trainer, vendor
-- It's a way of identifying what a NPC does without the player checking out every single option
local function checkGossip(...)
	local npcData = Recorder:RecordCreatureData(nil, "npc")
	
	for i=1, select("#", ...), 2 do
		local text, type = select(i, ...)
		if( NPC_TYPES[type] ) then
			Recorder:RecordCreatureType(npcData, type)
		end
	end
end

function Recorder:GOSSIP_SHOW()
	-- Have more than one gossip
	if( GetNumGossipAvailableQuests() > 0 or GetNumGossipActiveQuests() > 0 or GetNumGossipOptions() >= 2 ) then 
		checkGossip(GetGossipOptions())
	-- No gossip, just grab the location
	elseif( GetNumGossipAvailableQuests() == 0 and GetNumGossipActiveQuests() == 0 and GetNumGossipOptions() == 0 ) then
		self:RecordCreatureData(nil, "npc")
	end
end

-- Cache difficulty so we can't always rechecking it
function Recorder:UpdateDifficulty()
	local difficulty = GetInstanceDifficulty()
	local inInstance, instanceType = IsInInstance()
	ZONE_DIFFICULTY = instanceType == "raid" and (difficulty + 100) or inInstance and difficulty or 0	
	debug(1, "Set zone difficulty to %d, %d, %s, %s", ZONE_DIFFICULTY, difficulty, instanceType, tostring(inInstance))
end

Recorder.UPDATE_INSTANCE_INFO = Recorder.UpdateDifficulty
Recorder.PLAYER_DIFFICULTY_CHANGED = Recorder.UpdateDifficulty
Recorder.PLAYER_ENTERING_WORLD = Recorder.UpdateDifficulty
Recorder.ZONE_CHANGED_NEW_AREA = Recorder.UpdateDifficulty

-- Table writing
-- Encodes text in a way that it won't interfere with the table being loaded
local map = {	["{"] = "\\" .. string.byte("{"), ["}"] = "\\" .. string.byte("}"),
				['"'] = "\\" .. string.byte('"'), [";"] = "\\" .. string.byte(";"),
				["%["] = "\\" .. string.byte("["), ["%]"] = "\\" .. string.byte("]"),
				["@"] = "\\" .. string.byte("@")}
local function encode(text)
	if( not text ) then return nil end
	
	for find, replace in pairs(map) do
		text = string.gsub(text, find, replace)
	end
	
	return text
end

local function writeTable(tbl)
	local data = ""
	for key, value in pairs(tbl) do
		if( key ~= "START_SERIALIZER" ) then
			local valueType = type(value)

			-- Wrap the key in brackets if it's a number
			if( type(key) == "number" ) then
				key = string.format("[%s]", key)
				-- This will match any punctuation, spacing or control characters, basically anything that requires wrapping around them
			elseif( string.match(key, "[%p%s%c%d]") ) then
				key = string.format("[\"%s\"]", key)
			end

			-- foo = {bar = 5}
			if( valueType == "table" ) then
				data = string.format("%s%s=%s;", data, key, writeTable(value))
				-- foo = true / foo = 5
			elseif( valueType == "number" or valueType == "boolean" ) then
				data = string.format("%s%s=%s;", data, key, tostring(value))
				-- foo = "bar"
			else
				data = string.format("%s%s=[[%s]];", data, key, tostring(encode(value)))
			end
		end
	end

	return "{" .. data .. "}"
end

local function serializeDatabase(tbl, db, parent)
	for key, value in pairs(tbl) do
		if( type(value) == "table" ) then
			-- Find the serializer marker, so we know to just turn it into a string and don't go in farther
			if( value.START_SERIALIZER ) then
				db[key] = writeTable(value)
			-- Still no serialize marker, so just keep building the structure
			else
				db[key] = db[key] or {}
				serializeDatabase(value, db[key], parent or key)
			end   
		end
	end
end

-- Because serializing happens during logout, will save the error so users can report them still, without having BugGrabber
local function serializeError(msg)
	if( not SigrieDB.error ) then
		SigrieDB.error = {msg = msg, trace = debugstack(2)}
	end
end

function Recorder:PLAYER_LOGOUT()
	local errorHandler = geterrorhandler()
	seterrorhandler(serializeError)
	serializeDatabase(self.db, SigrieDB)
	seterrorhandler(errorHandler)
end

-- General stuff
function Recorder:RegisterEvent(event) self.frame:RegisterEvent(event) end
function Recorder:UnregisterEvent(event) self.frame:UnregisterEvent(event) end
Recorder.frame = CreateFrame("Frame")
Recorder.frame:SetScript("OnEvent", function(self, event, ...) Recorder[event](Recorder, event, ...) end)
Recorder.frame:RegisterEvent("ADDON_LOADED")
Recorder.frame:Hide()


function Recorder:Print(msg)
	DEFAULT_CHAT_FRAME:AddMessage(string.format("|cff33ff99MMOC Recorder|r: %s", msg))
end

SLASH_MMOCRECORDER1 = "/mmoc"
SLASH_MMOCRECORDER2 = "/mmochampion"
SlashCmdList["MMOCRECORDER"] = function(msg)
	msg = string.lower(msg or "")
	
	if( msg == "reset" ) then
		if( not StaticPopupDialogs["MMOCRECORD_CONFIRM_RESET"] ) then
			StaticPopupDialogs["MMOCRECORD_CONFIRM_RESET"] = {
				text = L["Are you sure you want to reset ALL data recorded?"],
				button1 = L["Yes"],
				button2 = L["No"],
				OnAccept = function()
					SigrieDB = nil
					Recorder.db = {}
					Recorder:InitializeDB()
					Recorder:Print(L["Reset all saved data for this character."])
				end,
				timeout = 30,
				whileDead = 1,
				hideOnEscape = 1,
			}
		end
		
		StaticPopup_Show("MMOCRECORD_CONFIRM_RESET")
	else
		Recorder:Print(L["Slash commands"])
		DEFAULT_CHAT_FRAME:AddMessage(L["/mmoc reset - Resets all saved data for this character"])
	end
end