--[[
	Anime Origin unit-progression probe V4 (read-only)

	V1 proved the stable PlayerData food/shop branches and found the game's level
	utility table, but its generic token scan included the executor's own probe
	functions. V2 records only structural matches and callbacks whose source is a
	real ReplicatedStorage module. V3 also tests the pure level reader with the
	unit identifier and records a bounded decompile of only the exact feed/lock
	callbacks so their remote argument order can be verified without clicking UI.
	V4 decompiles the two owning ModuleScripts themselves (rather than closures,
	which MacSploit rejects) and records every bounded target-callback upvalue.

	Run in the lobby without opening Units or Gold Shop. This file never invokes a
	remote, fires a signal, hooks a function, buys, feeds, locks or fuses anything.
]]

local Players = game:GetService("Players")
local HttpService = game:GetService("HttpService")

local player = Players.LocalPlayer
local outputFolder = "AnimeOrigin"
local outputFile = outputFolder .. "/UnitProgressionProbe_latest.json"

local function boundedTree(value, maximumDepth, maximumNodes)
	local visited = setmetatable({}, { __mode = "k" })
	local nodes = 0
	local function visit(current, depth)
		local valueType = typeof(current)
		if valueType == "string" or valueType == "number" or valueType == "boolean" or valueType == "nil" then
			return current
		end
		if valueType ~= "table" then return tostring(current) end
		if visited[current] then return "<cycle>" end
		if depth > maximumDepth or nodes >= maximumNodes then return "<limit>" end
		visited[current] = true
		nodes += 1
		local output = {}
		for key, child in next, current do
			if nodes >= maximumNodes then
				output.__truncated = true
				break
			end
			output[tostring(key)] = visit(child, depth + 1)
		end
		return output
	end
	return visit(value, 0)
end

local function normalize(value)
	return string.lower(tostring(value)):gsub("[^%w]", "")
end

local relevantTokens = {
	"feed",
	"food",
	"locktower",
	"lockedtower",
	"lockedtowers",
	"fusetower",
	"inventoryremote",
	"inventoryfunction",
	"buyshopitem",
	"goldshop",
}

local function relevant(value)
	local text = normalize(value)
	for _, token in ipairs(relevantTokens) do
		if string.find(text, token, 1, true) then return token end
	end
	return nil
end

local function isPlayerData(value)
	if typeof(value) ~= "table" then return false end
	local inventory = rawget(value, "Inventory")
	return typeof(inventory) == "table"
		and typeof(rawget(inventory, "Towers")) == "table"
		and typeof(rawget(inventory, "Currency")) == "table"
end

local function functionSource(callback)
	if debug and typeof(debug.info) == "function" then
		local ok, source = pcall(debug.info, callback, "s")
		if ok then return tostring(source) end
	end
	return nil
end

local function inspectFunction(callback, path)
	local source = functionSource(callback)
	-- Executor-injected functions use Script Raptor.Thread and were the main V1
	-- false-positive source. Only loaded game modules are useful evidence here.
	if not source or not string.find(source, "ReplicatedStorage", 1, true) then return nil end
	if typeof(getconstants) ~= "function" then return nil end
	local ok, constants = pcall(getconstants, callback)
	if not ok or typeof(constants) ~= "table" then return nil end

	local tokens = {}
	local stringConstants = {}
	for _, constant in next, constants do
		if typeof(constant) == "string" then
			local token = relevant(constant)
			if token then tokens[token] = true end
			table.insert(stringConstants, constant)
		end
	end
	if next(tokens) == nil then return nil end

	local upvalues = {}
	if debug and typeof(debug.getupvalues) == "function" then
		local upOK, values = pcall(debug.getupvalues, callback)
		if upOK and typeof(values) == "table" then
			for index, value in next, values do
				local valueType = typeof(value)
				if valueType == "string" or valueType == "number" or valueType == "boolean" then
					table.insert(upvalues, { index = tostring(index), value = value })
				elseif valueType == "Instance" then
					table.insert(upvalues, { index = tostring(index), value = value:GetFullName(), class = value.ClassName })
				elseif valueType == "table" then
					local matched = false
					for key, child in next, value do
						if relevant(key) or (typeof(child) == "string" and relevant(child)) then
							matched = true
							break
						end
					end
					if matched then
						table.insert(upvalues, {
							index = tostring(index),
							value = boundedTree(value, 4, 300),
						})
					end
				end
			end
		end
	end

	local record = {
		path = path,
		source = source,
		tokens = tokens,
		constants = stringConstants,
		upvalues = upvalues,
	}

	-- FeedTower and LockTower are the only two call shapes still unverified.
	-- Decompilation is read-only and bounded to avoid repeating V1's huge dump.
	local exactTarget = false
	for _, constant in ipairs(stringConstants) do
		if constant == "FeedTower" or constant == "LockTower" then
			exactTarget = true
			break
		end
	end
	if exactTarget and typeof(decompile) == "function" then
		local decompileOK, sourceText = pcall(decompile, callback)
		if decompileOK and typeof(sourceText) == "string" then
			record.decompiled = string.sub(sourceText, 1, 30000)
			record.decompiledTruncated = #sourceText > 30000
		else
			record.decompileError = tostring(sourceText)
		end
	end

	if exactTarget and debug and typeof(debug.getupvalues) == "function" then
		local allOK, allValues = pcall(debug.getupvalues, callback)
		if allOK and typeof(allValues) == "table" then
			record.allUpvalues = {}
			for index, value in next, allValues do
				table.insert(record.allUpvalues, {
					index = tostring(index),
					valueType = typeof(value),
					value = typeof(value) == "Instance"
						and value:GetFullName()
						or boundedTree(value, 5, 500),
				})
			end
		end
	end

	if debug and typeof(debug.info) == "function" then
		local infoOK, parameterCount, isVararg = pcall(debug.info, callback, "a")
		if infoOK then
			record.parameterCount = parameterCount
			record.isVararg = isVararg
		end
	end

	return record
end

assert(typeof(getgc) == "function", "OriginUnitProgressionProbe requires getgc(true).")
local gcOK, objects = pcall(getgc, true)
assert(gcOK and typeof(objects) == "table", "getgc(true) failed.")

local result = {
	version = 4,
	userId = player.UserId,
	placeId = game.PlaceId,
	jobId = game.JobId,
	playerDataSource = nil,
	foodInventory = {},
	shopState = {},
	lockStateMatches = {},
	levelUtility = nil,
	ownedLevels = {},
	goldShopCatalogs = {},
	moduleTableMatches = {},
	callbackMatches = {},
	decompiledModules = {},
	scan = { getgcObjects = #objects },
}

local playerData
for index, object in ipairs(objects) do
	if isPlayerData(object) then
		playerData = object
		result.playerDataSource = "getgc[" .. index .. "]"
		break
	elseif typeof(object) == "table" and isPlayerData(rawget(object, "PlayerData")) then
		playerData = rawget(object, "PlayerData")
		result.playerDataSource = "getgc[" .. index .. "].PlayerData"
		break
	end
end
assert(playerData, "Live PlayerData was not found. Wait for lobby loading.")

local inventory = rawget(playerData, "Inventory")
local towers = rawget(inventory, "Towers")
result.foodInventory = boundedTree(rawget(inventory, "Food"), 3, 100)
local shops = rawget(playerData, "Shops")
result.shopState = boundedTree(typeof(shops) == "table" and rawget(shops, "GoldShop") or nil, 4, 100)

-- Lock state may live outside the individual tower record. Traverse only the
-- confirmed PlayerData tree and record exact keys containing "lock".
do
	local visited = setmetatable({}, { __mode = "k" })
	local function visit(value, path, depth)
		if typeof(value) ~= "table" or visited[value] or depth > 9 then return end
		visited[value] = true
		for key, child in next, value do
			local childPath = path .. "." .. tostring(key)
			if string.find(normalize(key), "lock", 1, true) then
				table.insert(result.lockStateMatches, {
					path = childPath,
					value = boundedTree(child, 5, 300),
				})
			end
			if typeof(child) == "table" then visit(child, childPath, depth + 1) end
		end
	end
	visit(playerData, "PlayerData", 0)
end

-- Resolve the utility module structurally, then call only its pure level reader.
-- This is equivalent to reading a formula; no server state can be changed.
local levelModule
for index, object in ipairs(objects) do
	if typeof(object) == "table"
		and typeof(rawget(object, "MaxTowerLevel")) == "number"
		and typeof(rawget(object, "GetTowerLevelFromExp")) == "function"
		and typeof(rawget(object, "NeededTowerLevelExp")) == "function" then
		levelModule = object
		result.levelUtility = {
			path = "getgc[" .. index .. "]",
			maxTowerLevel = rawget(object, "MaxTowerLevel"),
			getTowerLevelFromExp = tostring(rawget(object, "GetTowerLevelFromExp")),
			neededTowerLevelExp = tostring(rawget(object, "NeededTowerLevelExp")),
		}
		break
	end
end

if levelModule then
	local getLevel = rawget(levelModule, "GetTowerLevelFromExp")
	for uuid, record in next, towers do
		if typeof(uuid) == "string" and typeof(record) == "table" then
			local exp = tonumber(rawget(record, "Exp")) or 0
			local identifier = rawget(record, "Name")
			local rarity = rawget(record, "Rarity")
			local attempts = {
				{ label = "identifier_exp_rarity", args = { identifier, exp, rarity } },
				{ label = "identifier_rarity_exp", args = { identifier, rarity, exp } },
				{ label = "exp_rarity", args = { exp, rarity } },
				{ label = "rarity_exp", args = { rarity, exp } },
				{ label = "record_exp", args = { record, exp } },
				{ label = "record_only", args = { record } },
				{ label = "identifier_exp", args = { identifier, exp } },
				{ label = "module_identifier_exp", args = { levelModule, identifier, exp } },
				{ label = "exp_identifier", args = { exp, identifier } },
				{ label = "exp_only", args = { exp } },
			}
			local ok, level, levelSignature = false, nil, nil
			local errors = {}
			for _, attempt in ipairs(attempts) do
				local attemptOK, attemptLevel = pcall(getLevel, table.unpack(attempt.args))
				if attemptOK and tonumber(attemptLevel) then
					ok = true
					level = tonumber(attemptLevel)
					levelSignature = attempt.label
					break
				end
				table.insert(errors, attempt.label .. ": " .. tostring(attemptLevel))
			end
			table.insert(result.ownedLevels, {
				uuid = uuid,
				identifier = identifier,
				rarity = rarity,
				exp = exp,
				level = ok and level or nil,
				levelSignature = levelSignature,
				levelError = ok and nil or table.concat(errors, " | "),
				shiny = rawget(record, "Shiny"),
				lockedFields = {
					Locked = rawget(record, "Locked"),
					IsLocked = rawget(record, "IsLocked"),
				},
				record = boundedTree(record, 2, 80),
			})
		end
	end
	table.sort(result.ownedLevels, function(left, right) return left.uuid < right.uuid end)
end

-- MacSploit's decompiler accepts ModuleScript instances, not function closures.
-- Save source for the exact owners so argument ordering is read from game code
-- instead of inferred from constants.
if typeof(makefolder) == "function" and typeof(isfolder) == "function" and not isfolder(outputFolder) then
	makefolder(outputFolder)
end
if typeof(decompile) == "function" then
	local replicatedStorage = game:GetService("ReplicatedStorage")
	local modulePaths = {
		{ "Modules", "CalculateStuff" },
		{ "LobbyModules", "UIHandler", "TowerFeedModule" },
		{ "LobbyModules", "UIHandler", "TowerInventoryModule" },
	}
	for _, parts in ipairs(modulePaths) do
		local instance = replicatedStorage
		for _, name in ipairs(parts) do
			instance = instance and instance:FindFirstChild(name)
		end
		local label = table.concat(parts, "_")
		if instance and instance:IsA("ModuleScript") then
			local ok, sourceText = pcall(decompile, instance)
			result.decompiledModules[label] = {
				path = instance:GetFullName(),
				ok = ok,
				error = not ok and tostring(sourceText) or nil,
				length = ok and typeof(sourceText) == "string" and #sourceText or 0,
			}
			if ok and typeof(sourceText) == "string" and typeof(writefile) == "function" then
				writefile(outputFolder .. "/Decompiled_" .. label .. ".lua", sourceText)
			end
		else
			result.decompiledModules[label] = { ok = false, error = "ModuleScript not found" }
		end
	end
end

-- A Gold Shop catalog is identified by Currency.ItemName == Gold, never by a
-- drifting getgc index. PlayerData.Shops.GoldShop.Seed identifies the active one.
for index, object in ipairs(objects) do
	if typeof(object) == "table" then
		local items = rawget(object, "ShopItems")
		local currency = rawget(object, "Currency")
		if typeof(items) == "table" and typeof(currency) == "table"
			and tostring(rawget(currency, "ItemName")) == "Gold" then
			table.insert(result.goldShopCatalogs, {
				path = "getgc[" .. index .. "]",
				seed = rawget(object, "CurrentSeed"),
				active = typeof(shops) == "table"
					and typeof(rawget(shops, "GoldShop")) == "table"
					and rawget(object, "CurrentSeed") == rawget(rawget(shops, "GoldShop"), "Seed"),
				items = boundedTree(items, 4, 300),
			})
		end
	end
end

-- Inspect real module callbacks and relevant keyed functions. Callback identity
-- and argument constants are sufficient to derive the missing Feed call shape.
local callbackDedup = {}
for index, object in ipairs(objects) do
	if typeof(object) == "function" then
		local match = inspectFunction(object, "getgc[" .. index .. "]")
		if match then
			local dedup = tostring(match.source) .. "|" .. table.concat(match.constants, "\0")
			if not callbackDedup[dedup] then
				callbackDedup[dedup] = true
				table.insert(result.callbackMatches, match)
			end
		end
	elseif typeof(object) == "table" then
		for key, child in next, object do
			local token = relevant(key)
			if token then
				local entry = {
					path = "getgc[" .. index .. "]." .. tostring(key),
					token = token,
					valueType = typeof(child),
					value = typeof(child) == "function" and tostring(child) or boundedTree(child, 4, 300),
				}
				if typeof(child) == "function" then
					entry.callback = inspectFunction(child, entry.path)
				end
				table.insert(result.moduleTableMatches, entry)
			end
		end
	end
end

if typeof(makefolder) == "function" and typeof(isfolder) == "function" and not isfolder(outputFolder) then
	makefolder(outputFolder)
end
assert(typeof(writefile) == "function", "writefile is unavailable.")
writefile(outputFile, HttpService:JSONEncode(result))

getgenv().AnimeOriginUnitProgressionProbe = result
print(string.format("[UnitProgressionProbeV4] levels=%d shopCatalogs=%d lockMatches=%d callbacks=%d",
	#result.ownedLevels, #result.goldShopCatalogs, #result.lockStateMatches, #result.callbackMatches))
print("[UnitProgressionProbeV4][FILE] " .. outputFile)
return result
