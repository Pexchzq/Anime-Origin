--[[
	Anime Origin focused player-data probe (read-only)

	This second probe uses only paths discovered from the first Anime Origin scan.
	It reads the live Gems HUD, finds the account XP/level label by its text shape,
	and correlates inventory UI card UUIDs with PlayerData.Inventory.Towers records.
	No remote is invoked and no UI callback is executed.
]]

local Players = game:GetService("Players")
local HttpService = game:GetService("HttpService")

local player = Players.LocalPlayer
local mainUI = player:WaitForChild("PlayerGui"):WaitForChild("MainUI")

local function safePath(instance)
	local success, result = pcall(function() return instance:GetFullName() end)
	return success and result or tostring(instance)
end

local function looksLikeUUID(value)
	return typeof(value) == "string"
		and #value >= 32
		and string.match(string.lower(value), "^[0-9a-f]+%-[0-9a-f]+%-[0-9a-f]+%-[0-9a-f]+%-[0-9a-f]+$") ~= nil
end

local function parseNumber(text)
	local cleaned = tostring(text or ""):gsub(",", ""):match("%-?%d+%.?%d*")
	return cleaned and tonumber(cleaned) or nil
end

local function simpleCopy(value, depth, visited)
	depth = depth or 0
	visited = visited or {}
	local kind = typeof(value)
	if kind == "nil" or kind == "string" or kind == "number" or kind == "boolean" then return value end
	if kind == "Instance" then return { class = value.ClassName, path = safePath(value) } end
	if kind ~= "table" then return "<" .. kind .. ">" end
	if visited[value] then return "<circular>" end
	if depth >= 4 then return "<max-depth>" end

	visited[value] = true
	local output = {}
	local count = 0
	for key, child in next, value do
		count += 1
		if count > 100 then output._truncated = true; break end
		output[tostring(key)] = simpleCopy(child, depth + 1, visited)
	end
	visited[value] = nil
	return output
end

local Report = {
	gems = nil,
	accountLevel = nil,
	playerDataSource = nil,
	inventoryUIPath = nil,
	units = {},
	unresolvedRarity = {},
}

-- Confirmed by the first scan: this is the always-visible current Gems counter,
-- not a reward preview or shop price.
local gemsLabel = mainUI
	:WaitForChild("HUD")
	:WaitForChild("BottomUI")
	:WaitForChild("Currencies")
	:WaitForChild("Gems")
	:WaitForChild("Inner")
	:WaitForChild("Amount")

Report.gems = {
	value = parseNumber(gemsLabel.Text),
	rawText = gemsLabel.Text,
	path = safePath(gemsLabel) .. ".Text",
}

-- The account-level bar contains both Lvl and XP. Matching both tokens excludes
-- unit-level labels such as "Lvl. 15" visible on inventory cards.
for _, instance in ipairs(mainUI:GetDescendants()) do
	if instance:IsA("TextLabel") or instance:IsA("TextButton") then
		local text = tostring(instance.Text or "")
		local lowerText = string.lower(text)
		if string.find(lowerText, "lvl", 1, true)
			and string.find(lowerText, "xp", 1, true)
			and string.find(text, "/", 1, true) then
			local level = tonumber(string.match(lowerText, "lvl%.?%s*(%d+)"))
			local currentXP, requiredXP = string.match(text:gsub(",", ""), "%((%d+)%s*/%s*(%d+)%s*[Xx][Pp]%)")
			Report.accountLevel = {
				level = level,
				currentXP = tonumber(currentXP),
				requiredXP = tonumber(requiredXP),
				rawText = text,
				path = safePath(instance) .. ".Text",
			}
			break
		end
	end
end

-- Confirmed inventory-card container. Every live card is named with the UUID
-- consumed by EquipTower; templates and layout objects are ignored.
local inventoryCards = mainUI
	:WaitForChild("TowerInventoryFolder")
	:WaitForChild("TowerInventoryFrame")
	:WaitForChild("Main")
	:WaitForChild("ContentFrame")
	:WaitForChild("CanvasGroup")
	:WaitForChild("ScrollingFrame")

Report.inventoryUIPath = safePath(inventoryCards)

local cardsByUUID = {}
for _, card in ipairs(inventoryCards:GetChildren()) do
	if looksLikeUUID(card.Name) then
		local cardEvidence = {
			uuid = card.Name,
			cardPath = safePath(card),
			texts = {},
			attributes = simpleCopy(card:GetAttributes()),
		}
		for _, descendant in ipairs(card:GetDescendants()) do
			if (descendant:IsA("TextLabel") or descendant:IsA("TextButton"))
				and tostring(descendant.Text or "") ~= "" then
				table.insert(cardEvidence.texts, {
					name = descendant.Name,
					text = descendant.Text,
					path = safePath(descendant) .. ".Text",
				})
			end
		end
		cardsByUUID[card.Name] = cardEvidence
	end
end

-- Locate the live PlayerData object from loaded callback state. We inspect
-- upvalues but never call their functions. The first table containing the same
-- UUIDs as the rendered inventory is considered the verified live candidate.
local playerData
local playerDataSource
local visitedSearch = {}

local function countCardMatches(towers)
	local matches = 0
	if typeof(towers) ~= "table" then return matches end
	for uuid in pairs(cardsByUUID) do
		if towers[uuid] ~= nil then matches += 1 end
	end
	return matches
end

local function searchPlayerData(value, source, depth)
	if playerData or typeof(value) ~= "table" or visitedSearch[value] or depth > 6 then return end
	visitedSearch[value] = true

	local direct = value.PlayerData
	if typeof(direct) == "table"
		and typeof(direct.Inventory) == "table"
		and countCardMatches(direct.Inventory.Towers) > 0 then
		playerData = direct
		playerDataSource = source .. ".PlayerData"
		return
	end
	if typeof(value.Inventory) == "table" and countCardMatches(value.Inventory.Towers) > 0 then
		playerData = value
		playerDataSource = source
		return
	end

	local count = 0
	for key, child in next, value do
		count += 1
		if count > 300 then break end
		if typeof(child) == "table" then
			searchPlayerData(child, source .. "." .. tostring(key), depth + 1)
			if playerData then return end
		end
	end
end

if typeof(getconnections) == "function" and debug and debug.getupvalues then
	for _, button in ipairs(mainUI:GetDescendants()) do
		if playerData then break end
		if button:IsA("GuiButton") then
			for signalName, signal in pairs({ Activated = button.Activated, MouseButton1Click = button.MouseButton1Click }) do
				local success, connections = pcall(getconnections, signal)
				if success then
					for connectionIndex, connection in ipairs(connections) do
						if connection.Function then
							local upvalueSuccess, upvalues = pcall(debug.getupvalues, connection.Function)
							if upvalueSuccess then
								for upvalueIndex, upvalue in pairs(upvalues) do
									searchPlayerData(
										upvalue,
										safePath(button) .. "." .. signalName
											.. "[" .. connectionIndex .. "].upvalue[" .. tostring(upvalueIndex) .. "]",
										0
									)
									if playerData then break end
								end
							end
						end
						if playerData then break end
					end
				end
				if playerData then break end
			end
		end
	end
end

-- Build a unit-definition rarity index from loaded client tables. Definitions
-- commonly store Rarity separately from each owned UUID record.
local rarityByIdentifier = {}
local seenDefinitions = {}

local function indexRarities(value, parentKey, depth)
	if typeof(value) ~= "table" or seenDefinitions[value] or depth > 4 then return end
	seenDefinitions[value] = true

	-- rawget is required here: some getgc tables use __index metamethods that run
	-- game AnimationScripts when an unknown field such as Rarity is requested.
	local rarity = rawget(value, "Rarity")
	if typeof(rarity) == "string" then
		local identifiers = {
			parentKey,
			rawget(value, "Name"),
			rawget(value, "TowerName"),
			rawget(value, "UnitName"),
			rawget(value, "DisplayName"),
			rawget(value, "Tower"),
		}
		for _, identifier in ipairs(identifiers) do
			if typeof(identifier) == "string" and identifier ~= "" then
				rarityByIdentifier[identifier] = rarity
			end
		end
	end

	local count = 0
	for key, child in next, value do
		count += 1
		if count > 500 then break end
		if typeof(child) == "table" then indexRarities(child, tostring(key), depth + 1) end
	end
end

if typeof(getgc) == "function" then
	local success, objects = pcall(getgc, true)
	if success and typeof(objects) == "table" then
		for _, object in ipairs(objects) do
			if typeof(object) == "table" then
				-- One hostile or malformed client table must not abort the complete scan.
				pcall(indexRarities, object, nil, 0)
			end
		end
	end
end

local function findRarity(record)
	if typeof(record) ~= "table" then return nil, nil end
	for key, value in next, record do
		local keyText = string.lower(tostring(key))
		if (keyText == "rarity" or keyText == "tier" or keyText == "rank")
			and typeof(value) == "string" then
			return value, "record." .. tostring(key)
		end
	end
	for _, key in ipairs({ "Name", "TowerName", "UnitName", "Tower", "Unit", "ID" }) do
		local identifier = rawget(record, key)
		if typeof(identifier) == "string" and rarityByIdentifier[identifier] then
			return rarityByIdentifier[identifier], "definition[" .. identifier .. "].Rarity"
		end
	end
	return nil, nil
end

Report.playerDataSource = playerDataSource
local towers = playerData and playerData.Inventory and playerData.Inventory.Towers
for uuid, card in pairs(cardsByUUID) do
	local record = typeof(towers) == "table" and towers[uuid] or nil
	local rarity, raritySource = findRarity(record)
	local unit = {
		uuid = uuid,
		cardPath = card.cardPath,
		cardTexts = card.texts,
		rarity = rarity,
		raritySource = raritySource,
		playerDataPath = playerDataSource and (playerDataSource .. ".Inventory.Towers[" .. string.format("%q", uuid) .. "]") or nil,
		record = simpleCopy(record),
	}
	table.insert(Report.units, unit)
	if not rarity then table.insert(Report.unresolvedRarity, uuid) end
end

table.sort(Report.units, function(a, b) return a.uuid < b.uuid end)
getgenv().AnimeOriginFocusedDataProbe = Report

print("[OriginFocused][GEMS] " .. HttpService:JSONEncode(Report.gems or {}))
print("[OriginFocused][ACCOUNT_LEVEL] " .. HttpService:JSONEncode(Report.accountLevel or {}))
print("[OriginFocused][PLAYER_DATA_SOURCE] " .. tostring(Report.playerDataSource))
for _, unit in ipairs(Report.units) do
	print("[OriginFocused][UNIT] " .. HttpService:JSONEncode(unit))
end

if typeof(writefile) == "function" then
	writefile("AnimeOrigin_FocusedDataProbe.json", HttpService:JSONEncode(Report))
	print("[OriginFocused][FILE] AnimeOrigin_FocusedDataProbe.json")
end

return Report
