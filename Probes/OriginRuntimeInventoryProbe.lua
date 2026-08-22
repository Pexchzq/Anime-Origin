--[[
	Anime Origin runtime-only inventory probe (read-only)

	This probe does not inspect inventory cards, open menus, click buttons, or
	invoke remotes. It locates PlayerData in already-loaded Lua memory, resolves
	each owned UUID through the unit-definition table, and saves name + rarity.

	Run immediately after joining. Output: AnimeOrigin_RuntimeInventoryProbe.json
]]

local HttpService = game:GetService("HttpService")

local function safeCopy(value, depth, visited)
	depth = depth or 0
	visited = visited or {}
	local kind = typeof(value)
	if kind == "nil" or kind == "string" or kind == "number" or kind == "boolean" then return value end
	if kind ~= "table" then return "<" .. kind .. ">" end
	if visited[value] then return "<circular>" end
	if depth >= 4 then return "<max-depth>" end
	visited[value] = true
	local output, count = {}, 0
	for key, child in next, value do
		count += 1
		if count > 100 then output._truncated = true; break end
		output[tostring(key)] = safeCopy(child, depth + 1, visited)
	end
	visited[value] = nil
	return output
end

local function isPlayerData(value)
	if typeof(value) ~= "table" then return false end
	local inventory = rawget(value, "Inventory")
	return typeof(inventory) == "table"
		and typeof(rawget(inventory, "Towers")) == "table"
		and typeof(rawget(inventory, "Currency")) == "table"
end

local playerData, playerDataSource
local definitionByIdentifier = {}
local definitionSources = {}

local function inspectRoot(root, source)
	local visited = {}
	local function visit(value, path, depth)
		if typeof(value) ~= "table" or visited[value] or depth > 10 then return end
		visited[value] = true

		if not playerData and isPlayerData(value) then
			playerData = value
			playerDataSource = source .. path
		end
		local nestedPlayerData = rawget(value, "PlayerData")
		if not playerData and isPlayerData(nestedPlayerData) then
			playerData = nestedPlayerData
			playerDataSource = source .. path .. ".PlayerData"
		end

		-- Unit-definition tables use the internal unit identifier as the parent key.
		-- Example: definitions["Itachi"] = { Name="Itaki", Rarity="Legendary" }.
		local count = 0
		for key, child in next, value do
			count += 1
			if count > 1500 then break end
			if typeof(child) == "table" then
				local rarity = rawget(child, "Rarity") or rawget(child, "rarity")
				local displayName = rawget(child, "Name") or rawget(child, "DisplayName")
				if typeof(key) == "string" and typeof(rarity) == "string"
					and typeof(displayName) == "string" then
					definitionByIdentifier[key] = child
					definitionSources[key] = source .. path .. "[" .. string.format("%q", key) .. "]"
				end
				visit(child, path .. "[" .. string.format("%q", tostring(key)) .. "]", depth + 1)
			end
		end
	end
	pcall(visit, root, "", 0)
end

if typeof(getgc) == "function" then
	local ok, objects = pcall(getgc, true)
	if ok and typeof(objects) == "table" then
		for index, object in ipairs(objects) do
			if typeof(object) == "table" then inspectRoot(object, "getgc[" .. index .. "]") end
		end
	end
end

assert(playerData, "Runtime PlayerData was not found. Wait for game loading to finish and run again.")

local inventory = rawget(playerData, "Inventory")
local currency = rawget(inventory, "Currency")
local towers = rawget(inventory, "Towers")
local Report = {
	playerDataSource = playerDataSource,
	gems = rawget(currency, "Gems"),
	units = {},
	unresolved = {},
}

for uuid, record in next, towers do
	if typeof(uuid) == "string" and typeof(record) == "table" then
		local identifier = rawget(record, "Name")
		local definition = typeof(identifier) == "string" and definitionByIdentifier[identifier] or nil
		local unit = {
			uuid = uuid,
			identifier = identifier,
			displayName = definition and rawget(definition, "Name") or nil,
			rarity = definition and (rawget(definition, "Rarity") or rawget(definition, "rarity")) or nil,
			definitionSource = typeof(identifier) == "string" and definitionSources[identifier] or nil,
			ownedRecord = safeCopy(record),
		}
		table.insert(Report.units, unit)
		if not unit.rarity then table.insert(Report.unresolved, uuid) end
	end
end

table.sort(Report.units, function(a, b) return a.uuid < b.uuid end)
getgenv().AnimeOriginRuntimeInventoryProbe = Report

print("[OriginRuntime][PLAYER_DATA] " .. tostring(Report.playerDataSource))
print("[OriginRuntime][GEMS] " .. tostring(Report.gems))
print("[OriginRuntime][SUMMARY] Units=" .. #Report.units .. " Unresolved=" .. #Report.unresolved)
for _, unit in ipairs(Report.units) do
	print("[OriginRuntime][UNIT] " .. HttpService:JSONEncode(unit))
end

if typeof(writefile) == "function" then
	writefile("AnimeOrigin_RuntimeInventoryProbe.json", HttpService:JSONEncode(Report))
	print("[OriginRuntime][FILE] AnimeOrigin_RuntimeInventoryProbe.json")
end

return Report
