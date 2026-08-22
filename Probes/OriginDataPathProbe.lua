--[[
	Anime Origin data-path probe (read-only)

	Purpose:
	  1. Find the live Gems value and player Level with their source paths.
	  2. Find inventory records containing both a unit UUID and rarity.

	The probe never invokes remotes and never clicks UI. It scans only data already
	replicated or loaded into this client. Results are printed and, when supported,
	saved as AnimeOrigin_DataPathProbe.json in the executor workspace.
]]

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local HttpService = game:GetService("HttpService")

local player = Players.LocalPlayer
local playerGui = player:WaitForChild("PlayerGui")

local Report = {
	placeId = game.PlaceId,
	jobId = game.JobId,
	currencyCandidates = {},
	levelCandidates = {},
	inventoryCandidates = {},
	statistics = {},
}

local MAX_DEPTH = 8
local MAX_ITEMS = 500
local MAX_INVENTORY_RESULTS = 1000
local seenTables = {}
local seenInventoryTables = {}

local currencyWords = { "gem", "gems", "diamond", "diamonds", "crystal", "crystals" }
local levelWords = { "level", "lvl", "playerlevel", "player_level" }

local function safePath(instance)
	local success, result = pcall(function() return instance:GetFullName() end)
	return success and result or tostring(instance)
end

local function lower(value)
	return string.lower(tostring(value or ""))
end

local function trim(value)
	return (tostring(value or ""):gsub("^%s+", ""):gsub("%s+$", ""))
end

local function containsWord(value, words)
	local text = lower(value):gsub("[^%w_]", "")
	for _, word in ipairs(words) do
		if text == word or string.find(text, word, 1, true) then return true end
	end
	return false
end

local function isSimple(value)
	local kind = typeof(value)
	return kind == "nil" or kind == "string" or kind == "number" or kind == "boolean"
end

local function jsonSafe(value, depth, visited)
	depth = depth or 0
	visited = visited or {}
	local kind = typeof(value)
	if isSimple(value) then return value end
	if kind == "Instance" then
		return { class = value.ClassName, path = safePath(value) }
	end
	if kind ~= "table" then return "<" .. kind .. ">" end
	if visited[value] then return "<circular>" end
	if depth >= MAX_DEPTH then return "<max-depth>" end

	visited[value] = true
	local output = {}
	local count = 0
	for key, child in next, value do
		count += 1
		if count > MAX_ITEMS then output._truncated = true; break end
		output[tostring(key)] = jsonSafe(child, depth + 1, visited)
	end
	visited[value] = nil
	return output
end

local function addUnique(list, record)
	local signature = tostring(record.source) .. "|" .. tostring(record.key) .. "|" .. tostring(record.value)
	for _, existing in ipairs(list) do
		local existingSignature = tostring(existing.source) .. "|" .. tostring(existing.key) .. "|" .. tostring(existing.value)
		if signature == existingSignature then return end
	end
	table.insert(list, record)
end

local function classifyScalar(source, key, value, evidenceType)
	if not isSimple(value) then return end
	local record = {
		source = source,
		key = tostring(key),
		value = value,
		evidenceType = evidenceType,
	}
	if containsWord(key, currencyWords) or containsWord(source, currencyWords) then
		addUnique(Report.currencyCandidates, record)
	end
	if containsWord(key, levelWords) or containsWord(source, levelWords) then
		addUnique(Report.levelCandidates, record)
	end
end

-- Roblox UUIDs observed by EquipTower use the canonical 8-4-4-4-12 layout.
local function looksLikeUUID(value)
	if typeof(value) ~= "string" then return false end
	return string.match(lower(value), "^[0-9a-f]+%-[0-9a-f]+%-[0-9a-f]+%-[0-9a-f]+%-[0-9a-f]+$") ~= nil
		and #value >= 32
end

local function findInventoryFields(value)
	local uuidKey, uuidValue, rarityKey, rarityValue
	for key, child in next, value do
		local keyText = lower(key)
		if looksLikeUUID(child) then
			uuidKey, uuidValue = tostring(key), child
		elseif looksLikeUUID(key) then
			uuidKey, uuidValue = "<table-key>", tostring(key)
		end
		if (string.find(keyText, "rarity", 1, true)
			or keyText == "rank" or keyText == "tier") and isSimple(child) then
			rarityKey, rarityValue = tostring(key), child
		end
	end
	return uuidKey, uuidValue, rarityKey, rarityValue
end

local function inspectTable(value, source, depth)
	if typeof(value) ~= "table" or seenTables[value] or depth > MAX_DEPTH then return end
	seenTables[value] = true

	local uuidKey, uuidValue, rarityKey, rarityValue = findInventoryFields(value)
	if uuidValue and rarityValue and not seenInventoryTables[value]
		and #Report.inventoryCandidates < MAX_INVENTORY_RESULTS then
		seenInventoryTables[value] = true
		table.insert(Report.inventoryCandidates, {
			source = source,
			uuidKey = uuidKey,
			uuid = uuidValue,
			rarityKey = rarityKey,
			rarity = rarityValue,
			record = jsonSafe(value),
		})
	end

	local count = 0
	for key, child in next, value do
		count += 1
		if count > MAX_ITEMS then break end
		if isSimple(child) then
			classifyScalar(source .. "." .. tostring(key), key, child, "runtime-table")
		elseif typeof(child) == "table" then
			inspectTable(child, source .. "." .. tostring(key), depth + 1)
		end
	end
end

-- First preference: exact replicated paths from Instances and attributes.
local instanceRoots = { player, playerGui, ReplicatedStorage }
local instanceCount = 0
for _, root in ipairs(instanceRoots) do
	local instances = { root }
	for _, descendant in ipairs(root:GetDescendants()) do table.insert(instances, descendant) end

	for _, instance in ipairs(instances) do
		instanceCount += 1
		local path = safePath(instance)
		local attributes = instance:GetAttributes()
		for key, value in pairs(attributes) do
			classifyScalar(path .. ":GetAttribute(" .. string.format("%q", key) .. ")", key, value, "attribute")
		end

		if instance:IsA("ValueBase") then
			classifyScalar(path .. ".Value", instance.Name, instance.Value, "ValueBase")
		end

		if instance:IsA("TextLabel") or instance:IsA("TextButton") or instance:IsA("TextBox") then
			local text = trim(instance.Text)
			if text ~= "" then
				classifyScalar(path .. ".Text", instance.Name, text, "GuiText")
			end
		end

		-- Inventory UI cards sometimes expose UUID and rarity as separate attributes
		-- on the same Instance. Treat their attribute table as one candidate record.
		if next(attributes) ~= nil then inspectTable(attributes, path .. ".attributes", 0) end
	end
end

-- Second preference: callback-owned state. Its source includes the exact button
-- path so a stable client seam can be identified later.
local callbackCount = 0
if typeof(getconnections) == "function" and debug and debug.getupvalues then
	for _, button in ipairs(playerGui:GetDescendants()) do
		if button:IsA("GuiButton") then
			for signalName, signal in pairs({ Activated = button.Activated, MouseButton1Click = button.MouseButton1Click }) do
				local success, connections = pcall(getconnections, signal)
				if success then
					for connectionIndex, connection in ipairs(connections) do
						if connection.Function then
							callbackCount += 1
							local upvalueSuccess, upvalues = pcall(debug.getupvalues, connection.Function)
							if upvalueSuccess then
								for upvalueIndex, upvalue in pairs(upvalues) do
									if typeof(upvalue) == "table" then
										inspectTable(
											upvalue,
											safePath(button) .. "." .. signalName
												.. "[" .. connectionIndex .. "].upvalue[" .. tostring(upvalueIndex) .. "]",
											0
										)
									end
								end
							end
						end
					end
				end
			end
		end
	end
end

-- Final fallback: enumerate all executor-visible Lua tables. A getgc source is
-- evidence of loaded client state, but it is not accepted as a stable path until
-- correlated with a callback or replicated Instance.
local gcCount = 0
if typeof(getgc) == "function" then
	local success, objects = pcall(getgc, true)
	if success and typeof(objects) == "table" then
		for index, object in ipairs(objects) do
			gcCount += 1
			if typeof(object) == "table" then inspectTable(object, "getgc[" .. index .. "]", 0) end
		end
	end
end

Report.statistics.instances = instanceCount
Report.statistics.callbacks = callbackCount
Report.statistics.gcObjects = gcCount
Report.statistics.currencyCandidates = #Report.currencyCandidates
Report.statistics.levelCandidates = #Report.levelCandidates
Report.statistics.inventoryCandidates = #Report.inventoryCandidates

getgenv().AnimeOriginDataPathProbe = Report

print("[OriginDataProbe][SUMMARY] " .. HttpService:JSONEncode(Report.statistics))
for _, candidate in ipairs(Report.currencyCandidates) do
	print("[OriginDataProbe][GEMS] " .. HttpService:JSONEncode(candidate))
end
for _, candidate in ipairs(Report.levelCandidates) do
	print("[OriginDataProbe][LEVEL] " .. HttpService:JSONEncode(candidate))
end
for _, candidate in ipairs(Report.inventoryCandidates) do
	print("[OriginDataProbe][INVENTORY] " .. HttpService:JSONEncode(candidate))
end

if typeof(writefile) == "function" then
	local success, errorMessage = pcall(function()
		writefile("AnimeOrigin_DataPathProbe.json", HttpService:JSONEncode(Report))
	end)
	if success then
		print("[OriginDataProbe][FILE] AnimeOrigin_DataPathProbe.json")
	else
		warn("[OriginDataProbe][FILE_ERROR]", errorMessage)
	end
end

return Report
