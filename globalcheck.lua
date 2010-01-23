local leaks = {}
local results = ""
local function output(msg)
	results = results .. "\r\n" .. msg
end

local function scanFile(path)
	output(io.popen(string.format("luac -l %s", path)):read("*all"))
end

local function scanFolder(path)
	for file in io.popen(string.format("dir /B \"%s\"", path or "")):lines() do
		local extension = string.match(file, "%.([%a%d]+)$")
		if( file ~= "" and not extension and file ~= "libs" ) then
			if( path ) then
				scanFolder(path .. "/" .. file)
			else
				scanFolder(file)
			end
		elseif( extension == "lua" and file ~= "localcheck.lua" and file ~= "globalcheck.lua" and not string.match(file, "^localization%.([a-zA-Z]+)%.lua") ) then
			if( path ) then
				scanFile(path .. "/" .. file)
			else
				scanFile(file)
			end
		end
	end
end

scanFolder()

io.popen("del luac.out")

local file = io.open("results.txt", "w")
file:write(tostring(results))
file:flush()
file:close()


local f = io.open("results.txt", "r")
local data = f:read("*all")
function lines(str)
	local t = {}
	local function helper(line) table.insert(t, line) return "" end
	helper((str:gsub("(.-)\r?\n", helper)))
	return t
end

local printFile
for _, line in pairs(lines(data)) do
	if( string.match(line, "(.+) <(.+)>") ) then
		file = line
		printFile = nil
	end
	
	if( string.match(line, "SETGLOBAL") ) then
		if( not printFile ) then
			print(file)
			printFile = true
		end
		
		print(line)
	end
end

f:close()
io.popen("del results.txt")
