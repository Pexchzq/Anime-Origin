--[[
	Anime Origin bootstrap-state probe (read-only)

	Run this in the lobby without opening Profile. It searches only:
	  1. confirmed PlayerData-shaped runtime tables,
	  2. direct keys of getgc tables, and
	  3. LocalPlayer attributes/leaderstats (never PlayerGui).

	It does not invoke remotes, click UI, claim rewards or summon. The JSON keeps
	all TotalSummons and claim-state candidates so the production path can be
	verified again after one manual ten-pull. Version 2 also snapshots the exact
	PlayerData claim branches and focused reward-definition tables.
]]

local Players = game:GetService("Players")
local HttpService = game:GetService("HttpService")

local player = Players.LocalPlayer
local environment = getgenv()
local outputFile = "AnimeOrigin_BootstrapStateProbe.json"
-- The screenshot showed 90. This is only a ranking hint; exact key names remain
-- stronger evidence and accounts with a different value are still discovered.
local expectedTotalSummons = tonumber(environment.AnimeOriginExpectedTotalSummons) or 90

local function normalizeKey(value)
	return string.lower(tostring(value)):gsub("[^%w]", "")
end

local function appendKey(path, key)
	if typeof(key) == "string" and string.match(key, "^[%a_][%w_]*$") then
		return path .. "." .. key
	end
	return path .. "[" .. string.format("%q", tostring(key)) .. "]"
end

local function simpleValue(value)
	local valueType = typeof(value)
	if valueType == "string" or valueType == "number" or valueType == "boolean" or valueType == "nil" then
		return value
	end
	if valueType == "table" then
		local summary = { kind = "table", simple = {}, entryCount = 0 }
		for key, child in next, value do
			summary.entryCount += 1
			if summary.entryCount <= 100 then
				local childType = typeof(child)
				if childType == "string" or childType == "number" or childType == "boolean" then
					summary.simple[tostring(key)] = child
				end
			end
		end
		return summary
	end
	return tostring(value)
end

-- Reward-definition tables contain nested thresholds/reward payloads. Serialize
-- only these explicitly selected branches with hard depth/node limits.
local function boundedTree(value, maximumDepth, maximumNodes)
	local visited = setmetatable({}, { __mode = "k" })
	local nodes = 0
	local function visit(current, depth)
		local currentType = typeof(current)
		if currentType == "string" or currentType == "number" or currentType == "boolean" or currentType == "nil" then
			return current
		end
		if currentType ~= "table" then return tostring(current) end
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

local function isPlayerData(value)
	if typeof(value) ~= "table" then return false end
	local inventory = rawget(value, "Inventory")
	return typeof(inventory) == "table"
		and typeof(rawget(inventory, "Towers")) == "table"
		and typeof(rawget(inventory, "Currency")) == "table"
end

local exactTotalKeys = {
	totalsummons = true,
	summonstotal = true,
	summoncount = true,
	totalsummon = true,
}

local claimTokens = {
	"dailyreward",
	"playtime",
	"battlepass",
	"dailywheel",
	"wheelspin",
	"redeem",
	"claimed",
	"claimable",
}

local function claimCategory(normalized)
	for _, token in ipairs(claimTokens) do
		if string.find(normalized, token, 1, true) then return token end
	end
	return nil
end

local result = {
	version = 2,
	userId = player.UserId,
	placeId = game.PlaceId,
	jobId = game.JobId,
	expectedTotalSummonsHint = expectedTotalSummons,
	playerDataSources = {},
	totalSummonsCandidates = {},
	claimStateCandidates = {},
	accountClaimState = {},
	claimDefinitionCandidates = {},
	scan = {
		getgcObjects = 0,
		playerDataTables = 0,
		playerDataNodes = 0,
		directRuntimeTables = 0,
	},
}

local totalDedup = {}
local claimDedup = {}

local function addTotal(path, key, value, source, stablePlayerDataPath)
	local normalized = normalizeKey(key)
	if typeof(value) ~= "number" then return end
	local exact = exactTotalKeys[normalized] == true
	local summonLike = string.find(normalized, "summon", 1, true) ~= nil
	if not exact and not summonLike then return end
	local dedupKey = path .. "|" .. tostring(value)
	if totalDedup[dedupKey] then return end
	totalDedup[dedupKey] = true
	local lowerPath = string.lower(path)
	local score = exact and 100 or 35
	if stablePlayerDataPath then score += 60 end
	if value == expectedTotalSummons then score += 20 end
	if string.find(lowerPath, "profile", 1, true)
		or string.find(lowerPath, "stat", 1, true) then score += 15 end
	table.insert(result.totalSummonsCandidates, {
		path = path,
		key = tostring(key),
		value = value,
		source = source,
		stablePlayerDataPath = stablePlayerDataPath == true,
		exactKey = exact,
		score = score,
	})
end

local function addClaim(path, key, value, source, stablePlayerDataPath)
	local category = claimCategory(normalizeKey(key))
	if not category then return end
	local dedupKey = path
	if claimDedup[dedupKey] then return end
	claimDedup[dedupKey] = true
	table.insert(result.claimStateCandidates, {
		path = path,
		key = tostring(key),
		category = category,
		value = simpleValue(value),
		source = source,
		stablePlayerDataPath = stablePlayerDataPath == true,
	})
end

local function inspectField(path, key, value, source, stablePlayerDataPath)
	addTotal(path, key, value, source, stablePlayerDataPath)
	addClaim(path, key, value, source, stablePlayerDataPath)
end

assert(typeof(getgc) == "function", "OriginBootstrapStateProbe requires getgc(true).")
local ok, objects = pcall(getgc, true)
assert(ok and typeof(objects) == "table", "getgc(true) failed.")
result.scan.getgcObjects = #objects

local playerDataTables = {}
local playerDataSeen = setmetatable({}, { __mode = "k" })
for index, object in ipairs(objects) do
	if typeof(object) == "table" then
		local candidate
		local source
		if isPlayerData(object) then
			candidate = object
			source = "getgc[" .. index .. "]"
		elseif isPlayerData(rawget(object, "PlayerData")) then
			candidate = rawget(object, "PlayerData")
			source = "getgc[" .. index .. "].PlayerData"
		end
		if candidate and not playerDataSeen[candidate] then
			playerDataSeen[candidate] = true
			table.insert(playerDataTables, { value = candidate, source = source })
			table.insert(result.playerDataSources, source)
		end
	end
end
result.scan.playerDataTables = #playerDataTables

-- Snapshot only the exact confirmed bootstrap branches from the first live
-- PlayerData candidate. This is compact enough to compare before/after claims.
if playerDataTables[1] then
	local live = playerDataTables[1].value
	local profileData = rawget(live, "ProfileData")
	result.accountClaimState = {
		totalSummons = typeof(profileData) == "table" and rawget(profileData, "TotalSummons") or nil,
		redeemedCodes = boundedTree(rawget(live, "RedeemedCodes"), 4, 200),
		dailyRewards = boundedTree(rawget(live, "DailyRewards"), 4, 200),
		playTimeRewards = boundedTree(rawget(live, "PlayTimeRewards"), 5, 300),
		battlepasses = boundedTree(rawget(live, "Battlepasses"), 5, 300),
	}
end

-- Fully traverse only confirmed PlayerData. Cycles, depth and node count are
-- bounded so this never becomes another whole-game recursive scan.
local runtimeTablePaths = setmetatable({}, { __mode = "k" })
for candidateIndex, entry in ipairs(playerDataTables) do
	local visited = setmetatable({}, { __mode = "k" })
	local nodeCount = 0
	local rootPath = candidateIndex == 1 and "PlayerData" or ("PlayerDataCandidate[" .. candidateIndex .. "]")
	local function visit(value, path, depth)
		if typeof(value) ~= "table" or visited[value] or depth > 9 or nodeCount >= 25000 then return end
		visited[value] = true
		runtimeTablePaths[value] = runtimeTablePaths[value] or path
		nodeCount += 1
		for key, child in next, value do
			local childPath = appendKey(path, key)
			inspectField(childPath, key, child, entry.source, true)
			if typeof(child) == "table" then visit(child, childPath, depth + 1) end
		end
	end
	visit(entry.value, rootPath, 0)
	result.scan.playerDataNodes += nodeCount
end

-- getgc(true) already exposes nested tables as direct objects. Inspecting one
-- level of each table finds callback/cache snapshots without recursive game scans.
for index, object in ipairs(objects) do
	if typeof(object) == "table" then
		result.scan.directRuntimeTables += 1
		local stablePath = runtimeTablePaths[object]
		local basePath = stablePath or ("getgc[" .. index .. "]")
		for key, value in next, object do
			local path = appendKey(basePath, key)
			inspectField(path, key, value, stablePath and "PlayerData table via getgc" or "getgc direct table", stablePath ~= nil)
			-- Definition roots are runtime tables outside PlayerData. Capture only exact
			-- known names so the probe remains focused and the JSON stays reviewable.
			local normalized = normalizeKey(key)
			if not stablePath and typeof(value) == "table" and (
				normalized == "dailyrewards"
				or normalized == "upgradeddailyrewards"
				or normalized == "playtimerewards"
				or normalized == "dailywheelrewards"
				or normalized == "battlepasses"
				or normalized == "battlepassrewards"
			) then
				table.insert(result.claimDefinitionCandidates, {
					path = path,
					key = tostring(key),
					value = boundedTree(value, 6, 600),
				})
			end
		end
	end
end

-- Include replicated player state while explicitly excluding PlayerGui.
for key, value in pairs(player:GetAttributes()) do
	inspectField("Players.LocalPlayer.Attributes." .. tostring(key), key, value, "LocalPlayer attribute", false)
end
local leaderstats = player:FindFirstChild("leaderstats")
if leaderstats then
	for _, instance in ipairs(leaderstats:GetDescendants()) do
		if instance:IsA("ValueBase") then
			inspectField("Players.LocalPlayer.leaderstats." .. instance.Name, instance.Name, instance.Value, "leaderstats", false)
		end
	end
end

table.sort(result.totalSummonsCandidates, function(left, right)
	if left.score ~= right.score then return left.score > right.score end
	if left.stablePlayerDataPath ~= right.stablePlayerDataPath then return left.stablePlayerDataPath end
	return left.path < right.path
end)
table.sort(result.claimStateCandidates, function(left, right)
	if left.stablePlayerDataPath ~= right.stablePlayerDataPath then return left.stablePlayerDataPath end
	if left.category ~= right.category then return left.category < right.category end
	return left.path < right.path
end)

result.bestTotalSummons = result.totalSummonsCandidates[1]
environment.AnimeOriginBootstrapStateProbe = result
if typeof(writefile) == "function" then
	writefile(outputFile, HttpService:JSONEncode(result))
else
	warn("[BootstrapProbe] writefile is unavailable; result remains in getgenv().AnimeOriginBootstrapStateProbe")
end

if result.bestTotalSummons then
	print("[BootstrapProbe][TotalSummons]", result.bestTotalSummons.path, "=", result.bestTotalSummons.value,
		"score=", result.bestTotalSummons.score, "stable=", result.bestTotalSummons.stablePlayerDataPath)
else
	warn("[BootstrapProbe][TotalSummons] No candidate found. Run in the lobby after PlayerData finishes loading.")
end
warn("[BootstrapProbe][FILE]", outputFile,
	"Total candidates:", #result.totalSummonsCandidates,
	"Claim candidates:", #result.claimStateCandidates,
	"Definition candidates:", #result.claimDefinitionCandidates)
return result
