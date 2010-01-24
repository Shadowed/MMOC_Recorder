Sigrie = select(2, ...)

local L = Sigrie.L
local CanMerchantRepair, GetInboxHeaderInfo, GetInboxItem, GetInboxItemLink, GetInboxNumItems, GetMerchantItemCostInfo = CanMerchantRepair, GetInboxHeaderInfo, GetInboxItem, GetInboxItemLink, GetInboxNumItems, GetMerchantItemCostInfo
local GetMerchantItemCostItem, GetMerchantItemLink, GetNumFactions, GetNumLootItems, GetNumTrainerServices, GetTrainerGreetingText, LootSlotIsItem, UnitAura, GetTitleText = GetMerchantItemCostItem, GetMerchantItemLink, GetNumFactions, GetNumLootItems, GetNumTrainerServices, GetTrainerGreetingText, LootSlotIsItem, UnitAura, GetTitleText

local DEBUG_LEVEL = select(6, GetAddOnInfo("TestCode")) and 0 or 4
local ALLOWED_COORD_DIFF = 0.02
local LOOT_EXPIRATION = 10 * 60
local ZONE_DIFFICULTY = 0

local NPC_TYPES = {["mailbox"] = 0x01, ["auctioneer"] = 0x02, ["battlemaster"] = 0x04, ["binder"] = 0x08, ["bank"] = 0x10, ["guildbank"] = 0x20, ["canrepair"] = 0x40, ["flightmaster"] = 0x80, ["stable"] = 0x100, ["tabard"] = 0x200, ["vendor"] = 0x400, ["trainer"] = 0x800, ["spiritres"] = 0x1000}
local BATTLEFIELD_TYPES = {["av"] = 1, ["wsg"] = 2, ["ab"] = 3, ["nagrand"] = 4, ["bem"] = 5, ["all_arenas"] = 6, ["eots"] = 7, ["rol"] = 8, ["sota"] = 9, ["dalaran"] = 10, ["rov"] = 11, ["ioc"] = 30, ["all_battlegrounds"] = 32}
local BATTLEFIELD_MAP = {[L["Alterac Valley"]] = "av", [L["Warsong Gulch"]] = "wsg", [L["Eye of the Storm"]] = "eots", [L["Strand of the Ancients"]] = "sota", [L["Isle of Conquest"]] = "ioc", [L["All Arenas"]] = "all_arenas"}

local setToAbandon, abandonedName, lootedGUID
local repGain, lootedGUID = {}, {}
local playerName = UnitName("player")

local function debug(level, msg, ...)
	if( level <= DEBUG_LEVEL ) then
		print(string.format(msg, ...))
	end
end

function Sigrie:InitializeDB()
	local guid = UnitGUID("player")
	local version, build = GetBuildInfo()
	build = tonumber(build) or -1
	
	-- Invalidate he database if the player guid changed or the build changed
	if( SigrieDB and ( not SigrieDB.version or not SigrieDB.build or SigrieDB.build < build or SigrieDB.guid ~= guid ) ) then
		SigrieDB = nil
	end
	
	-- Initialize the database
	SigrieDB = SigrieDB or {}
	SigrieDB.guid = guid
	SigrieDB.class = select(2, UnitClass("player"))
	SigrieDB.race = string.upper(select(2, UnitRace("player")))
	SigrieDB.version = version
	SigrieDB.build = build
	SigrieDB.locale = GetLocale()

	self.db = {}
end

function Sigrie:ADDON_LOADED(event, addon)
	if( addon ~= "+SigrieMiner" ) then return end
	self:UnregisterEvent("ADDON_LOADED")
	
	self:InitializeDB()
	if( SigrieDB.error ) then
		DEFAULT_CHAT_FRAME:AddMessage(string.format(L["Message: %s"], SigrieDB.error.msg))
		DEFAULT_CHAT_FRAME:AddMessage(string.format(L["Trace: %s"], SigrieDB.error.trace))
		self:Print(L["An error happened while Sigrie was serializing your data, please report the above error. You might have to scroll up to see it all."])
		SigrieDB.error = nil
	end
	
	self.tooltip = CreateFrame("GameTooltip", "SigrieTooltip", UIParent, "GameTooltipTemplate")
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
		
	self:PLAYER_LEAVING_WORLD()
end

-- For pulling data out of the actual database. This isn't the most efficient system compared to a transparent metatable
-- like I normally use, but because of how the table is structured it's a lot easier to cache "minor" bits of data instead of the ENTIRE table and unserialize it as we need it, also simplifies serializing it again
-- The downside is, it creates duplicate parent and child tables, but it saves a lot more on not loading the excess data
function Sigrie:GetBasicData(parent, key)
	self.db[parent] = self.db[parent] or {}
	if( self.db[parent][key] ) then return self.db[parent][key] end
	
	-- Load it out of the database, we've already got it
	if( SigrieDB[parent] and SigrieDB[parent][key] ) then
		local func, msg = loadstring("return " .. SigrieDB[parent][key])
		if( func ) then
			self.db[parent][key] = func()
		else
			error(msg, 3)
			return nil
		end
	else
		self.db[parent][key] = {}
	end
	
	self.db[parent][key].START_SERIALIZER = true
	return self.db[parent][key]
end

function Sigrie:GetData(parent, child, key)
	self.db[parent] = self.db[parent] or {}
	self.db[parent][child] = self.db[parent][child] or {}
	if( self.db[parent][child][key] ) then return self.db[parent][child][key] end
	
	-- Load it out of the database, we've already got it
	if( SigrieDB[parent] and SigrieDB[parent][child] and SigrieDB[parent][child][key] ) then
		local func, msg = loadstring("return " .. SigrieDB[parent][child][key])
		if( func ) then
			self.db[parent][child][key] = func()
		else
			error(msg, 3)
			return nil
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

function Sigrie:PLAYER_LEAVING_WORLD()
	self.NPC_ID = setmetatable({}, npcIDMetatable)
	self.NPC_TYPE = setmetatable({}, npcTypeMetatable)
end

local function parseText(text)
	text = string.gsub(text, "%%d", "%%d+")
	text = string.gsub(text, "%%s", ".+")
	return string.lower(string.trim(text))
end

-- Drunk identification, so we can discard tracking levels until no longer drunk
local DRUNK_ITEM1, DRUNK_ITEM2, DRUNK_ITEM3, DRUNK_ITEM4 = string.gsub(DRUNK_MESSAGE_ITEM_SELF1, "%%s", ".+"), string.gsub(DRUNK_MESSAGE_ITEM_SELF2, "%%s", ".+"), string.gsub(DRUNK_MESSAGE_ITEM_SELF3, "%%s", ".+"), string.gsub(DRUNK_MESSAGE_ITEM_SELF4, "%%s", ".+")
function Sigrie:CHAT_MSG_SYSTEM(event, message)
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

function Sigrie:GetArenaData(index)
	self.tooltip:SetMerchantItem(index)
	for i=1, self.tooltip:NumLines() do
		local text = _G["SigrieTooltipTextLeft" .. i]:GetText()
		
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
function Sigrie:UpdateFactions()
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

function Sigrie:GetFaction(guid)
	if( not guid ) then return 1 end
	self:UpdateFactions()
	
	local faction
	self.tooltip:SetHyperlink(string.format("unit:%s", guid))
	for i=1, self.tooltip:NumLines() do
		local text = _G["SigrieTooltipTextLeft" .. i]:GetText()
		if( text and self.factions[text] ) then
			return text
		end
	end
	
	return nil
end

function Sigrie:GetFactionDiscount(guid)
	local faction = self:GetFaction(guid)
	if( not faction ) then return 1 end
	return self.factions[faction] == 5 and 0.95 or self.factions[faction] == 6 and 0.90 or self.factions[faction] == 7 and 0.85 or self.factions[faction] == 8 and 0.80 or 1
end

-- Reputation and spell handling
local COMBATLOG_OBJECT_REACTION_HOSTILE = COMBATLOG_OBJECT_REACTION_HOSTILE
local eventsRegistered = {["PARTY_KILL"] = true, ["SPELL_CAST_SUCCESS"] = true, ["SPELL_CAST_START"] = true}
function Sigrie:COMBAT_LOG_EVENT_UNFILTERED(event, timestamp, eventType, sourceGUID, sourceName, sourceFlags, destGUID, destName, destFlags, ...)
	if( not eventsRegistered[eventType] ) then return end
	
	if( ( eventType == "SPELL_CAST_START" or eventType == "SPELL_CAST_SUCCESS" ) and bit.band(sourceFlags, COMBATLOG_OBJECT_TYPE_NPC) == COMBATLOG_OBJECT_TYPE_NPC ) then
		local spellID = ...
		local npcData = self:GetData("npcs", ZONE_DIFFICULTY, self.NPC_ID[sourceGUID])
		npcData.spells = npcData.spells or {}
		npcData.spells[spellID] = true
		debug(4, "%s casting spell %s (%d)", sourceName, select(2, ...), spellID)
		
	elseif( eventType == "PARTY_KILL" and bit.band(destFlags, COMBATLOG_OBJECT_REACTION_HOSTILE) == COMBATLOG_OBJECT_REACTION_HOSTILE and bit.band(destFlags, COMBATLOG_OBJECT_TYPE_NPC) == COMBATLOG_OBJECT_TYPE_NPC ) then
		repGain.npcID = self.NPC_ID[destGUID]
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
}
	
function Sigrie:HasReputationModifier()
	if( SigrieDB.race == "HUMAN" ) then return true end
	
	for name in pairs(reputationModifiers) do
		if( UnitBuff("player", name) ) then
			return true
		end
	end
	
	return false
end

function Sigrie:COMBAT_TEXT_UPDATE(event, type, faction, amount)
	if( type ~= "FACTION" ) then return end
	
	if( repGain.timeout and repGain.timeout >= GetTime() and not self:HasReputationModifier() ) then
		local npcID = repGain.npcID
		local npcData = self:GetData("npcs", difficulty, npc)
		npcData.info = npcData.info or {}
		npcData.info.faction = faction
		npcData.info.factionAmount = amount
		
		debug(2, "NPC #%d gives %d %s faction", npcID, amount, faction)
	end
end

-- Handle any incompatabilies that other mods can cause
function Sigrie:StripData(text)
	-- Strip [<level crap>] <quest title>
	text = string.gsub(text, "%[(.+)%]", "")
	-- Strip color codes
	text = string.gsub(text, "|c%x%x%x%x%x%x%x%x(.+)|r", "%1")
	-- Strip (low level) at the end of a quest
	text = string.gsub(text, "(.+) %((.+)%)", "%1")

	return string.trim(text)
end

-- Handle quest abandoning
hooksecurefunc("AbandonQuest", function()
	abandonedName = setToAbandon
	setToAbandon = nil
end)

hooksecurefunc("SetAbandonQuest", function()
	setToAbandon = GetAbandonQuestName()
end)

Sigrie.InteractSpells = {
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
	-- Pick Lock
	--[GetSpellInfo(1804) or ""] = {item = true, location = false, parentItem = true},
}

-- Might have to use DungeonUsesTerrainMap, Blizzard seems to use it for subtracting from dungeon level?
function Sigrie:RecordLocation()
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

	return tonumber(string.format("%.2f", x * 100)), tonumber(string.format("%.2f", y * 100)), zone, dungeonLevel
end

-- For recording a location by zone, primarily for fishing
function Sigrie:RecordZoneLocation(type)
	local x, y, zone, level = self:RecordLocation()
	local zoneData = self:GetData("zone", ZONE_DIFFICULTY, zone)
	
	-- See if we already have an entry for them
	for i=1, #(zoneData), 4 do
		local npcX, npcY, npcLevel, npcCount = zoneData[i], zoneData[i + 1], zoneData[i + 2], zoneData[i + 3]
		if( npcLevel == level ) then
			local xDiff, yDiff = math.abs(npcX - x), math.abs(npcY - y)
			if( xDiff <= ALLOWED_COORD_DIFF and yDiff <= ALLOWED_COORD_DIFF ) then
				zoneData[i] = tonumber(string.format("%.2f", (npcX + x) / 2))
				zoneData[i + 1] = tonumber(string.format("%.2f", (npcY + y) / 2))
				zoneData[i + 4] = npcCount + 1
				
				debug(3, "Recording %s location at %.2f, %.2f in %s (%d level), counter %d", type, x, y, zone, level, zoneData[i + 4])
				return zoneData
			end
		end
	end
	
	table.insert(zoneData, x)
	table.insert(zoneData, y)
	table.insert(zoneData, level)
	table.insert(zoneData, 1)
	debug(3, "Recording %s location at %.2f, %.2f in %s (%d level), counter %d", type, x, y, zone, level, 1)
	
	return zoneData
end

-- Location, location, location
function Sigrie:RecordDataLocation(type, npcID, isGeneric)
	local npcData = self:GetData(type, ZONE_DIFFICULTY, npcID)
	local x, y, zone, level = self:RecordLocation()
	local coordModifier = isGeneric and 200 or 0
	
	-- See if we already have an entry for them
	for i=1, #(npcData), 5 do
		local npcX, npcY, npcZone, npcLevel, npcCount = npcData[i], npcData[i + 1], npcData[i + 2], npcData[i + 3], npcData[i + 4]
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
				npcData[i] = tonumber(string.format("%.2f", (npcX + x) / 2)) + modifier
				npcData[i + 1] = tonumber(string.format("%.2f", (npcY + y) / 2)) + modifier
				npcData[i + 4] = npcCount + 1
				
				debug(3, "Recording npc %s (%s) location at %.2f, %.2f in %s (%d level), counter %d, generic %s", npcID, type, x, y, zone, level, npcData[i + 4], tostring(isGeneric))
				return npcData
			end
		end
	end
	
	-- No data yet
	table.insert(npcData, x + coordModifier)
	table.insert(npcData, y + coordModifier)
	table.insert(npcData, zone)
	table.insert(npcData, level)
	table.insert(npcData, 1)
	
	debug(3, "Recording npc %s location at %.2f, %.2f in %s (%d level), generic %s", npcID, x, y, zone, level, tostring(isGeneric))
	return npcData
end

-- Add all of the data like title, health, power, faction, etc here
function Sigrie:GetCreatureDB(unit)
	local guid = UnitGUID(unit)
	local npcID, npcType = self.NPC_ID[guid], self.NPC_TYPE[guid]
	if( not npcID or not npcType ) then return end

	return self:GetData("npcs", ZONE_DIFFICULTY, npcID), npcID, npcType
end

function Sigrie:RecordCreatureType(npcData, type)
	npcData.info.bitType = npcData.info.bitType and bit.bor(npcData.info.bitType, NPC_TYPES[type]) or NPC_TYPES[type]
	debug(3, "Recording npc %s, type %s", npcData.info and npcData.info.name or "nil", type)
end

function Sigrie:RecordCreatureData(type, unit)
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

	self:RecordDataLocation("npcs", npcID, type == "generic")
	return npcData
end

-- Record trainer data
local playerCache
function Sigrie:UpdateTrainerData(npcData)
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
function Sigrie:UpdateMerchantData(npcData)
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
					itemCost[string.match(link, "item:(%d+)")] = amount
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
function Sigrie:CHAT_MSG_ADDON(prefix, message, channel, sender)
	if( sender == playerName or prefix ~= "SIGRIE" or ( channel ~= "RAID" and channel ~= "PARTY" ) ) then return end
	
	local type, arg = string.split(":", message, 2)
	if( type == "loot" ) then
		lootedGUID[arg] = GetTime() + LOOT_EXPIRATION
	end
end

local COPPER_AMOUNT = string.gsub(COPPER_AMOUNT, "%%d", "(%%d+)")
local SILVER_AMOUNT = string.gsub(SILVER_AMOUNT, "%%d", "(%%d+)")
local GOLD_AMOUNT = string.gsub(GOLD_AMOUNT, "%%d", "(%%d+)")

function Sigrie:LOOT_OPENED()
	local npcData
	local time = GetTime()
	-- Object set, so looks like we're good
	if( self.activeSpell.object and self.activeSpell.endTime <= (time + 0.60) ) then
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
		local npcID = self.NPC_TYPE[guid] == "npc" and self.NPC_ID[guid]
		if( npcID ) then
			npcData = self:RecordCreatureData("mob", "target")
			
			-- This is necessary because sending it just to raid or party without checking can cause not in raid errors
			local instanceType = select(2, IsInInstance())
			if( instanceType ~= "arena" and instanceType ~= "pvp" and ( GetNumPartyMembers() > 0 or GetNumRaidMembers() > 0 ) ) then
				SendAddonMessage("SIGRIE", string.format("loot:%s", guid), "RAID")
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
			if( link ) then
				local quantity = select(3, GetLootSlotInfo(i))
				local itemID = tonumber(string.match(link, "item:(%d+)"))
				
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

-- Ensure that we still get item data even if the person is using a /use macro
hooksecurefunc("SecureCmdUseItem", function(name, bag, slot, target)
	if( not target and Sigrie.activeSpell.object and Sigrie.activeSpell.object.parentItem and not Sigrie.activeSpell.useSet ) then
		Sigrie.activeSpell.item = select(2, GetItemInfo(name))
		Sigrie.activeSpell.useSet = true
	end
end)

function Sigrie:UNIT_SPELLCAST_SENT(event, unit, name, rank, target)
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

function Sigrie:UNIT_SPELLCAST_SUCCEEDED(event, unit, name, rank)
	if( unit ~= "player" ) then return end
	
	if( self.activeSpell.endTime == -1 and self.activeSpell.name == self.activeSpell.name and self.activeSpell.rank == rank ) then
		self.activeSpell.endTime = GetTime()
	end
end

function Sigrie:UNIT_SPELLCAST_FAILED(event, unit)
	if( unit ~= "player" ) then return end
	
	self.activeSpell.object = nil
end

-- QUEST DATA HANDLER
function Sigrie:GetQuestName(questID)
	self.tooltip:SetOwner(UIParent, "ANCHOR_NONE")
	self.tooltip:SetHyperlink(string.format("quest:%d", questID))
	
	return SigrieTooltipTextLeft1:GetText()
end

local lastRecordedPOI = {}
function Sigrie:RecordQuestPOI(questID)
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

function Sigrie:WORLD_MAP_UPDATE()
	for i=1, QuestMapUpdateAllQuests() do
		local questID, logIndex = QuestPOIGetQuestIDByVisibleIndex(i)
		if( questID and logIndex and logIndex > 0 ) then
			self:RecordQuestPOI(questID)
		end
	end
end

-- Quest log updated, see what changed quest-wise
local questGiverType, questGiverID
local tempQuestLog, questLog = {}
function Sigrie:QUEST_LOG_UPDATE(event)
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
			if( not questLog[questID] ) then
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

function Sigrie:QuestProgress()
	local guid = UnitGUID("npc")
	local questGiven = self:StripData(GetTitleText())
	local id, type = self.NPC_ID[guid], self.NPC_TYPE[guid]
	
	-- We cannot get itemid from GUID, so we have to do an inventory scan to find what we want
	if( type ~= "item" ) then
		questGiverID, questGiverType = id, type
		self:RecordCreatureData("quest", "npc")
	end
end

function Sigrie:QUEST_COMPLETE(event)
	self:QuestProgress()
end

-- We're looking at the details of the quest, save the quest info so we can use it later
function Sigrie:QUEST_DETAIL(event)
	-- When a quest is shared with the player, "npc" is actually the "player" unitid
	if( UnitIsPlayer("npc") ) then
		questGiverType, questGiverID = nil, nil
		return
	end
	
	self:QuestProgress()
end

-- General handling
function Sigrie:AUCTION_HOUSE_SHOW()
	self:RecordCreatureData("auctioneer", "npc")
end

function Sigrie:MAIL_SHOW()
	self:RecordCreatureData("mailbox", "npc")
end

local merchantData
function Sigrie:MERCHANT_SHOW()
	merchantData = self:RecordCreatureData("vendor", "npc")
	self:UpdateMerchantData(merchantData)
end

function Sigrie:MERCHANT_UPDATE()
	self:UpdateMerchantData(merchantData)
end

function Sigrie:TRAINER_SHOW()
	local npcData = self:RecordCreatureData("trainer", "npc")
	self:UpdateTrainerData(npcData)
end

function Sigrie:PET_STABLE_SHOW()
	self:RecordCreatureData("stable", "npc")
end

function Sigrie:TAXIMAP_OPENED()
	local npcData = self:RecordCreatureData("flightmaster", "npc")
	for i=1, NumTaxiNodes() do
		if( TaxiNodeGetType(i) == "CURRENT" ) then
			npcData.info.taxiNode = TaxiNodeName(i)
			debug(3, "Set taxi node to %s.", npcData.info.taxiNode)
			break
		end
	end
end

function Sigrie:BANKFRAME_OPENED()
	self:RecordCreatureData("banker", "npc")
end

function Sigrie:CONFIRM_XP_LOSS()
	self:RecordCreatureData("spiritres", "npc")
end

function Sigrie:CONFIRM_BINDER()
	self:RecordCreatureData("binder", "npc")
end

function Sigrie:GUILDBANKFRAME_OPENED()
	self:RecordCreatureData("guildbank", "npc")
end

function Sigrie:PLAYER_TARGET_CHANGED()
	if( UnitExists("target") and not UnitPlayerControlled("target") and not UnitAffectingCombat("target") and CheckInteractDistance("target", 3) ) then
		self:RecordCreatureData("generic", "target")
	end
end

function Sigrie:BATTLEFIELDS_SHOW()
	if( not UnitExists("npc") ) then return end

	local type = BATTLEFIELD_TYPES[BATTLEFIELD_MAP[GetBattlefieldInfo()] or ""]
	if( type ) then
		local npcData = self:RecordCreatureData("battlemaster", "target")
		npcData.info.battlefields = type
	end
end

-- Gossip returns most of the types: banker, battlemaster, binder, gossip, tabard, taxi, trainer, vendor
-- It's a way of identifying what a NPC does without the player checking out every single option
local function checkGossip(...)
	local npcData = Sigrie:RecordCreatureData(nil, "npc")
	
	for i=1, select("#", ...), 2 do
		local text, type = select(i, ...)
		if( NPC_TYPES[type] ) then
			Sigrie:RecordCreatureType(npcData, type)
		end
	end
end

function Sigrie:GOSSIP_SHOW()
	if( GetNumGossipAvailableQuests() > 0 or GetNumGossipActiveQuests() > 0 or GetNumGossipOptions() >= 2 ) then 
		checkGossip(GetGossipOptions())
	elseif( GetNumGossipAvailableQuests() == 0 and GetNumGossipActiveQuests() == 0 and GetNumGossipOptions() == 0 ) then
		self:RecordCreatureData(nil, "npc")
	end
end

-- Cache difficulty so we can't always rechecking it
function Sigrie:UpdateDifficulty()
	local difficulty = GetInstanceDifficulty()
	local inInstance, instanceType = IsInInstance()
	ZONE_DIFFICULTY = instanceType == "raid" and (difficulty + 100) or inInstance and difficulty or 0	
	debug(1, "Set zone difficulty to %d, %d, %s, %s", ZONE_DIFFICULTY, difficulty, instanceType, tostring(inInstance))
end

Sigrie.UPDATE_INSTANCE_INFO = Sigrie.UpdateDifficulty
Sigrie.PLAYER_DIFFICULTY_CHANGED = Sigrie.UpdateDifficulty
Sigrie.PLAYER_ENTERING_WORLD = Sigrie.UpdateDifficulty
Sigrie.ZONE_CHANGED_NEW_AREA = Sigrie.UpdateDifficulty

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
			elseif( string.match(key, "[%p%s%c]") ) then
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
				data = string.format("%s%s=\"%s\";", data, key, tostring(encode(value)))
			end
		end
	end

	return "{" .. data .. "}"
end

local function serializeDatabase(tbl, db)
	for key, value in pairs(tbl) do
		if( type(value) == "table" ) then
			-- Find the serializer marker, so we know to just turn it into a string and don't go in farther
			if( value.START_SERIALIZER ) then
				db[key] = writeTable(value)
			-- Still no serialize marker, so just keep building the structure
			else
				db[key] = db[key] or {}
				serializeDatabase(value, db[key])
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

function Sigrie:PLAYER_LOGOUT()
	local errorHandler = geterrorhandler()
	seterrorhandler(serializeError)
	serializeDatabase(self.db, SigrieDB)
	seterrorhandler(errorHandler)
end

-- General stuff
function Sigrie:RegisterEvent(event) self.frame:RegisterEvent(event) end
function Sigrie:UnregisterEvent(event) self.frame:UnregisterEvent(event) end
Sigrie.frame = CreateFrame("Frame")
Sigrie.frame:SetScript("OnEvent", function(self, event, ...) Sigrie[event](Sigrie, event, ...) end)
Sigrie.frame:RegisterEvent("ADDON_LOADED")
Sigrie.frame:Hide()


function Sigrie:Print(msg)
	DEFAULT_CHAT_FRAME:AddMessage(string.format("|cff33ff99Sigrie Miner|r: %s", msg))
end

SLASH_SIGRIE1 = "/sigrie"
SLASH_SIGRIE2 = "/mmoc"
SLASH_SIGRIE3 = "/mmochampion"
SlashCmdList["SIGRIE"] = function(msg)
	msg = string.lower(msg or "")
	
	if( msg == "reset" ) then
		if( not StaticPopupDialogs["SIGRIE_CONFIRM_RESET"] ) then
			StaticPopupDialogs["SIGRIE_CONFIRM_RESET"] = {
				text = L["Are you sure you want to reset ALL data recorded?"],
				button1 = L["Yes"],
				button2 = L["No"],
				OnAccept = function()
					SigrieDB = nil
					Sigrie:InitializeDB()
					Sigrie:Print(L["Reset all saved data for this character."])
				end,
				timeout = 30,
				whileDead = 1,
				hideOnEscape = 1,
			}
		end
		
		StaticPopup_Show("SIGRIE_CONFIRM_RESET")
	else
		Sigrie:Print(L["Slash commands"])
		DEFAULT_CHAT_FRAME:AddMessage(L["/sigrie reset - Resets all saved data for this character"])
	end
end