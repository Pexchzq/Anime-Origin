--[[
	Anime Origin runtime loadout probe (read-only)

	Run without opening any UI. The probe finds live PlayerData, collects owned
	unit UUIDs, then searches runtime state for references to those UUIDs under
	keys/paths related to equip, team, loadout, tower, or slot.

	Output: AnimeOrigin_LoadoutProbe.json in the executor workspace.
]]

local HttpService = game:GetService("HttpService")

local function isPlayerData(value)
	if typeof(value) ~= "table" then return false end
	local inventory = rawget(value, "Inventory")
	return typeof(inventory) == "table"
		and typeof(rawget(inventory, "Towers")) == "table"
		and typeof(rawget(inventory, "Currency")) == "table"
end

local roots = {}
local playerData, playerDataSource

if typeof(getgc) == "function" then
	local ok, objects = pcall(getgc, true)
	if ok and typeof(objects) == "table" then
		for index, object in ipairs(objects) do
			if typeof(object) == "table" then
				table.insert(roots, { value = object, source = "getgc[" .. index .. "]" })
			end
		end
	end
end

-- Find PlayerData without using inventory cards or another UI instance.
for _, root in ipairs(roots) do
	if isPlayerData(root.value) then
		playerData = root.value
		playerDataSource = root.source
		break
	end
	local nested = rawget(root.value, "PlayerData")
	if isPlayerData(nested) then
		playerData = nested
		playerDataSource = root.source .. ".PlayerData"
		break
	end
end

assert(playerData, "Runtime PlayerData was not found. Wait for loading and run again.")

local towers = rawget(rawget(playerData, "Inventory"), "Towers")
local owned = {}
for uuid in next, towers do
	if typeof(uuid) == "string" then owned[uuid] = true end
end

local Report = {
	playerDataSource = playerDataSource,
	ownedCount = 0,
	-- Observed as 100; retained only as diagnostic inventory-capacity evidence.
	reportedMaxTowerSlot = tonumber(rawget(playerData, "MaxTowerSlot")) or 0,
	slots = {},
	playerDataCandidates = {},
	runtimeCandidates = {},
}
for _ in next, owned do Report.ownedCount += 1 end

-- This is the canonical loadout state. It exists in PlayerData without opening
-- Units, and the UUID values can be joined to Inventory.Towers directly.
local equippedTowers = rawget(playerData, "EquippedTowers")
for slotNumber = 1, 6 do
	local slotKey = "Tower" .. slotNumber
	local uuid = typeof(equippedTowers) == "table" and rawget(equippedTowers, slotKey) or nil
	local ownedRecord = typeof(uuid) == "string" and rawget(towers, uuid) or nil
	table.insert(Report.slots, {
		slot = slotNumber,
		key = slotKey,
		unlocked = uuid ~= nil and true or nil,
		empty = uuid == nil,
		uuid = uuid,
		identifier = typeof(ownedRecord) == "table" and rawget(ownedRecord, "Name") or nil,
	})
end

local relevantWords = { "equip", "team", "loadout", "slot", "tower", "unit", "selected" }

local function isRelevantKey(value)
	local lower = string.lower(tostring(value))
	for _, word in ipairs(relevantWords) do
		if string.find(lower, word, 1, true) then return true end
	end
	return false
end

local function scan(root, source, destination, maxDepth)
	local visited = {}
	local function visit(value, path, depth)
		if typeof(value) ~= "table" or visited[value] or depth > maxDepth then return end
		visited[value] = true

		local matchedUUIDs = {}
		local relevantKeys = {}
		local lowerPath = string.lower(source .. path)
		local isInventoryTowersPath = string.find(lowerPath, "inventory", 1, true)
			and string.find(lowerPath, "towers", 1, true)
		local count = 0
		for key, child in next, value do
			count += 1
			if count > 2000 then break end
			if isRelevantKey(key) then
				table.insert(relevantKeys, tostring(key))
			end
			if typeof(child) == "string" and owned[child] then
				table.insert(matchedUUIDs, child)
			elseif typeof(key) == "string" and owned[key] and not isInventoryTowersPath then
				table.insert(matchedUUIDs, key)
			end
		end

		if #matchedUUIDs > 0 or #relevantKeys > 0 then
			table.insert(destination, {
				path = source .. path,
				matchedUUIDs = matchedUUIDs,
				relevantKeys = relevantKeys,
			})
		end

		count = 0
		for key, child in next, value do
			count += 1
			if count > 2000 then break end
			if typeof(child) == "table" then
				visit(child, path .. "[" .. string.format("%q", tostring(key)) .. "]", depth + 1)
			end
		end
	end
	pcall(visit, root, "", 0)
end

-- PlayerData candidates are the strongest evidence and are listed separately.
scan(playerData, playerDataSource, Report.playerDataCandidates, 10)

-- Search all loaded runtime roots for a live loadout cache if PlayerData keeps
-- equipped state elsewhere. No callback is executed.
for _, root in ipairs(roots) do
	scan(root.value, root.source, Report.runtimeCandidates, 7)
end

getgenv().AnimeOriginLoadoutProbe = Report
print("[OriginLoadout][PLAYER_DATA] " .. tostring(playerDataSource))
for _, slot in ipairs(Report.slots) do
	print("[OriginLoadout][SLOT] " .. HttpService:JSONEncode(slot))
end
print("[OriginLoadout][SUMMARY] PlayerDataCandidates=" .. #Report.playerDataCandidates
	.. " RuntimeCandidates=" .. #Report.runtimeCandidates)

if typeof(writefile) == "function" then
	writefile("AnimeOrigin_LoadoutProbe.json", HttpService:JSONEncode(Report))
	print("[OriginLoadout][FILE] AnimeOrigin_LoadoutProbe.json")
end

return Report
