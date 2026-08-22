--[[
	Anime Origin main-flow state probe (read-only)

	Finds the non-UI evidence required by main.lua:
	  1. Account EXP/level.
	  2. StoryProgress.WestCity Acts 1-6, including every Normal/Hard marker.
	  3. Current stage identity, match start/end state and current Wave.
	  4. Runtime changes and relevant incoming events around end/restart.

	It never invokes/fires, blocks or rewrites a remote, clicks UI, changes game
	callbacks or reads PlayerGui. It only records outbound calls before forwarding
	them unchanged, so teleport actions survive the current server closing. Files
	are created immediately and observation continues until:

		getgenv().AnimeOriginMainFlowProbe.stop()

	Executor files:
	  AnimeOrigin/MainFlowProbe_latest.json
	  AnimeOrigin/MainFlowProbe_trace.jsonl
]]

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local HttpService = game:GetService("HttpService")

local player = Players.LocalPlayer
local environment = getgenv()
local outputFolder = "AnimeOrigin"
local summaryFile = outputFolder .. "/MainFlowProbe_latest.json"
local traceFile = outputFolder .. "/MainFlowProbe_trace.jsonl"
local pollInterval = 0.2

-- Re-running replaces the older observer so events are never duplicated.
local previous = environment.AnimeOriginMainFlowProbe
if typeof(previous) == "table" and typeof(previous.stop) == "function" then
	pcall(previous.stop)
end

if typeof(makefolder) == "function" then
	local exists = typeof(isfolder) == "function" and isfolder(outputFolder)
	if not exists then pcall(makefolder, outputFolder) end
end
if typeof(writefile) == "function" then pcall(writefile, traceFile, "") end

local function safePath(instance)
	local ok, value = pcall(function() return instance:GetFullName() end)
	return ok and value or tostring(instance)
end

local function normalize(value)
	return string.lower(tostring(value or "")):gsub("[^%w]", "")
end

local function appendKey(path, key)
	if typeof(key) == "string" and string.match(key, "^[%a_][%w_]*$") then
		return path .. "." .. key
	end
	return path .. "[" .. string.format("%q", tostring(key)) .. "]"
end

local function serialize(value, depth, visited)
	depth = depth or 0
	visited = visited or {}
	local kind = typeof(value)
	if kind == "nil" then return { type = "nil" } end
	if kind == "string" or kind == "number" or kind == "boolean" then return value end
	if kind == "Instance" then
		return { type = "Instance", path = safePath(value), class = value.ClassName }
	end
	if kind == "Vector3" then return { type = kind, x = value.X, y = value.Y, z = value.Z } end
	if kind == "CFrame" then return { type = kind, components = { value:GetComponents() } } end
	if kind ~= "table" then return { type = kind, value = tostring(value) } end
	if visited[value] then return "<cycle>" end
	if depth >= 6 then return "<max-depth>" end
	visited[value] = true
	local result, count = {}, 0
	for key, child in next, value do
		count += 1
		if count > 500 then result.__truncated = true; break end
		result[tostring(key)] = serialize(child, depth + 1, visited)
	end
	visited[value] = nil
	return result
end

local function encode(value)
	local ok, result = pcall(HttpService.JSONEncode, HttpService, value)
	return ok and result or HttpService:JSONEncode({ encodingError = tostring(result) })
end

local function isPlayerData(value)
	if typeof(value) ~= "table" then return false end
	local inventory = rawget(value, "Inventory")
	return typeof(inventory) == "table"
		and typeof(rawget(inventory, "Towers")) == "table"
		and typeof(rawget(inventory, "Currency")) == "table"
		and typeof(rawget(value, "ProfileData")) == "table"
end

assert(typeof(getgc) == "function", "MainFlowStateProbe requires getgc(true).")
local gcOK, objects = pcall(getgc, true)
assert(gcOK and typeof(objects) == "table", "getgc(true) failed.")

local playerData
local playerDataSource
for index, object in ipairs(objects) do
	if isPlayerData(object) then
		playerData, playerDataSource = object, "getgc[" .. index .. "]"
		break
	elseif typeof(object) == "table" and isPlayerData(rawget(object, "PlayerData")) then
		playerData = rawget(object, "PlayerData")
		playerDataSource = "getgc[" .. index .. "].PlayerData"
		break
	end
end
assert(playerData, "Live PlayerData was not found. Wait for game loading and run again.")

local report = {
	version = 1,
	startedAt = os.time(),
	userId = player.UserId,
	placeId = game.PlaceId,
	jobId = game.JobId,
	context = "observer_no_PlayerGui_outbound_calls_forwarded_unchanged",
	playerDataSource = playerDataSource,
	account = {},
	story = {},
	infinite = {},
	selection = {},
	matchRuntimes = {},
	runtimeCandidates = {},
	playerAttributes = {},
	replicatedCandidates = {},
	changes = {},
	incoming = {},
	outgoing = {},
	counts = {},
}

local controller = {
	active = true,
	sequence = 0,
	connections = {},
	watchers = {},
	report = report,
}

local function save(reason)
	report.updatedAt = os.time()
	report.reason = reason
	if typeof(writefile) == "function" then pcall(writefile, summaryFile, encode(report)) end
end

local function emit(kind, data, quiet)
	if not controller.active then return end
	controller.sequence += 1
	report.counts[kind] = (report.counts[kind] or 0) + 1
	local record = {
		sequence = controller.sequence,
		kind = kind,
		unixTime = os.time(),
		clock = os.clock(),
		data = data,
	}
	if typeof(appendfile) == "function" then
		pcall(appendfile, traceFile, encode(record) .. "\n")
	end
	if not quiet then print("[MainFlowProbe][" .. kind .. "] " .. encode(data)) end
	return record
end

local function simpleSignature(value)
	local kind = typeof(value)
	return kind .. ":" .. tostring(value)
end

local function watchTableField(owner, key, path, category)
	local value = rawget(owner, key)
	local kind = typeof(value)
	if kind ~= "string" and kind ~= "number" and kind ~= "boolean" and kind ~= "nil" then return end
	table.insert(controller.watchers, {
		owner = owner,
		key = key,
		path = path,
		category = category,
		last = simpleSignature(value),
	})
end

-- Account level is derived from server-fed cumulative PlayerData.Exp. Calling
-- this pure formula changes no state and avoids parsing a rendered XP bar.
local profileData = rawget(playerData, "ProfileData")
report.account.expCandidates = {
	{ path = "PlayerData.Exp", value = serialize(rawget(playerData, "Exp")) },
	{ path = "PlayerData.XP", value = serialize(rawget(playerData, "XP")) },
	{ path = "PlayerData.ProfileData.Exp", value = serialize(typeof(profileData) == "table" and rawget(profileData, "Exp") or nil) },
	{ path = "PlayerData.ProfileData.XP", value = serialize(typeof(profileData) == "table" and rawget(profileData, "XP") or nil) },
}

local levelUtility
local levelUtilitySource
for index, object in ipairs(objects) do
	if typeof(object) == "table"
		and typeof(rawget(object, "GetPlayerLevelFromExp")) == "function"
		and typeof(rawget(object, "NeededPlayerEXP")) == "function" then
		levelUtility, levelUtilitySource = object, "getgc[" .. index .. "]"
		break
	end
end
report.account.levelUtilitySource = levelUtilitySource
report.account.formula = "GetPlayerLevelFromExp(PlayerData.Exp)"
local accountExp = tonumber(rawget(playerData, "Exp"))
if accountExp and levelUtility then
	local ok, level = pcall(rawget(levelUtility, "GetPlayerLevelFromExp"), accountExp)
	report.account.authoritative = {
		expPath = "PlayerData.Exp",
		exp = accountExp,
		level = ok and tonumber(level) or nil,
		formulaVerified = ok and tonumber(level) ~= nil,
	}
	watchTableField(playerData, "Exp", "PlayerData.Exp", "account")
end

-- Keep every Act field. We intentionally do not guess whether Claimed means
-- Normal or Hard until values from accounts with different clears are compared.
local storyProgress = rawget(playerData, "StoryProgress")
local westCity = typeof(storyProgress) == "table" and rawget(storyProgress, "WestCity") or nil
report.story.path = "PlayerData.StoryProgress.WestCity"
report.story.raw = serialize(westCity)
report.story.acts = {}
for act = 1, 6 do
	local key = tostring(act)
	local record = typeof(westCity) == "table" and (rawget(westCity, key) or rawget(westCity, act)) or nil
	local path = "PlayerData.StoryProgress.WestCity[" .. string.format("%q", key) .. "]"
	report.story.acts[key] = {
		path = path,
		raw = serialize(record),
		claimed = typeof(record) == "table" and rawget(record, "Claimed") or nil,
	}
	if typeof(record) == "table" then
		for field in next, record do
			watchTableField(record, field, appendKey(path, field), "story")
		end
	end
end

local infiniteProgress = rawget(playerData, "InfiniteProgress")
local westCityInfinite = typeof(infiniteProgress) == "table" and rawget(infiniteProgress, "WestCity") or nil
report.infinite = {
	path = "PlayerData.InfiniteProgress.WestCity",
	raw = serialize(westCityInfinite),
}

-- Diagnostic selection cache; never used as clear-history authority.
local selectionKeys = {
	"SelectedStageType", "SelectedAct", "SelectedDifficulty",
	"SelectedWorld", "SelectedGameMode",
}
for index, object in ipairs(objects) do
	if typeof(object) == "table" then
		local complete = true
		for _, key in ipairs(selectionKeys) do
			if rawget(object, key) == nil then complete = false; break end
		end
		if complete then
			report.selection.path = "getgc[" .. index .. "]"
			for _, key in ipairs(selectionKeys) do
				report.selection[key] = serialize(rawget(object, key))
				watchTableField(object, key, report.selection.path .. "." .. key, "selection")
			end
			break
		end
	end
end

local exactRuntimeKeys = {
	wave = true, currentwave = true, wavenumber = true,
	gamestarted = true, matchstarted = true, gameended = true, matchended = true,
	victory = true, defeat = true, result = true, won = true,
	world = true, map = true, mapname = true, act = true, chapter = true,
	difficulty = true, mode = true, gamemode = true,
}

local function runtimeSiblingSnapshot(object)
	local values = {}
	for key, value in next, object do
		if exactRuntimeKeys[normalize(key)] then
			local kind = typeof(value)
			if kind == "string" or kind == "number" or kind == "boolean" then
				values[tostring(key)] = value
			end
		end
	end
	return values
end

for index, object in ipairs(objects) do
	if typeof(object) == "table" then
		local isMatchRuntime = typeof(rawget(object, "GameStarted")) == "boolean"
			and typeof(rawget(object, "TowerDict")) == "table"
			and typeof(rawget(object, "TowerNPCDict")) == "table"
			and typeof(rawget(object, "PathPositions")) == "table"
		local siblingValues = runtimeSiblingSnapshot(object)
		local siblingCount = 0
		for _ in next, siblingValues do siblingCount += 1 end
		local path = "getgc[" .. index .. "]"

		if isMatchRuntime then
			local towerCount = 0
			for _ in next, rawget(object, "TowerDict") do towerCount += 1 end
			table.insert(report.matchRuntimes, {
				path = path,
				GameStarted = rawget(object, "GameStarted"),
				siblings = siblingValues,
				TowerCount = towerCount,
			})
			watchTableField(object, "GameStarted", path .. ".GameStarted", "match")
		end

		-- Two related fields sharply reduce config/default-table false matches.
		if siblingCount >= 2 or isMatchRuntime then
			for key, value in next, object do
				if exactRuntimeKeys[normalize(key)] then
					local kind = typeof(value)
					if kind == "string" or kind == "number" or kind == "boolean" then
						local fieldPath = appendKey(path, key)
						table.insert(report.runtimeCandidates, {
							path = fieldPath,
							key = tostring(key),
							value = value,
							siblings = siblingValues,
							matchRuntime = isMatchRuntime,
							score = (isMatchRuntime and 100 or 0) + siblingCount * 10,
						})
						watchTableField(object, key, fieldPath, "runtime")
					end
				end
			end
		end
	end
end

table.sort(report.runtimeCandidates, function(left, right)
	if left.score ~= right.score then return left.score > right.score end
	return left.path < right.path
end)
while #report.runtimeCandidates > 250 do table.remove(report.runtimeCandidates) end

-- Attributes and replicated ValueObjects are allowed non-UI evidence.
for key, value in pairs(player:GetAttributes()) do
	report.playerAttributes[tostring(key)] = serialize(value)
end
table.insert(controller.connections, player.AttributeChanged:Connect(function(key)
	local value = player:GetAttribute(key)
	report.playerAttributes[tostring(key)] = serialize(value)
	local record = emit("PLAYER_ATTRIBUTE_CHANGED", {
		path = "Players.LocalPlayer.Attributes." .. key,
		value = serialize(value),
	})
	table.insert(report.changes, record)
	if #report.changes > 300 then table.remove(report.changes, 1) end
	save("player attribute changed")
end))

for _, instance in ipairs(ReplicatedStorage:GetDescendants()) do
	if instance:IsA("ValueBase") and exactRuntimeKeys[normalize(instance.Name)] then
		table.insert(report.replicatedCandidates, {
			path = safePath(instance) .. ".Value",
			value = serialize(instance.Value),
		})
		table.insert(controller.connections, instance:GetPropertyChangedSignal("Value"):Connect(function()
			local record = emit("REPLICATED_VALUE_CHANGED", {
				path = safePath(instance) .. ".Value",
				value = serialize(instance.Value),
			})
			table.insert(report.changes, record)
			if #report.changes > 300 then table.remove(report.changes, 1) end
			save("replicated value changed")
		end))
	end
end

-- Observe only server-to-client traffic. The generic remote may carry Wave or
-- end actions in its first argument, so both path and primitive args are tested.
local incomingTokens = {
	"wave", "game", "match", "stage", "map", "act", "story", "infinite",
	"restart", "victory", "defeat", "result", "end", "teleport",
}
local function relevantIncoming(path, packed)
	local text = string.lower(path)
	for index = 1, packed.n do text = text .. " " .. string.lower(tostring(packed[index])) end
	for _, token in ipairs(incomingTokens) do
		if string.find(text, token, 1, true) then return true end
	end
	return false
end

for _, instance in ipairs(ReplicatedStorage:GetDescendants()) do
	if instance:IsA("RemoteEvent") then
		table.insert(controller.connections, instance.OnClientEvent:Connect(function(...)
			local packed = table.pack(...)
			local path = safePath(instance)
			if not relevantIncoming(path, packed) then return end
			local arguments = { count = packed.n }
			for index = 1, packed.n do arguments[tostring(index)] = serialize(packed[index]) end
			local record = emit("INCOMING_REMOTE", { remotePath = path, arguments = arguments }, true)
			table.insert(report.incoming, record)
			if #report.incoming > 300 then table.remove(report.incoming, 1) end
			save("incoming remote")
		end))
	end
end

-- Capture client-to-server transition calls before the original remote runs.
-- This hook never changes arguments or return values. Synchronous persistence is
-- required because Return To Lobby can destroy the current client immediately.
if typeof(hookmetamethod) == "function"
	and typeof(newcclosure) == "function"
	and typeof(getnamecallmethod) == "function" then
	local oldNamecall
	oldNamecall = hookmetamethod(game, "__namecall", newcclosure(function(self, ...)
		local method = getnamecallmethod()
		if controller.active
			and (method == "FireServer" or method == "InvokeServer")
			and typeof(self) == "Instance"
			and (self:IsA("RemoteEvent") or self:IsA("RemoteFunction")) then
			local packed = table.pack(...)
			local arguments = { count = packed.n }
			for index = 1, packed.n do arguments[tostring(index)] = serialize(packed[index]) end
			local record = emit("OUTGOING_REMOTE", {
				remotePath = safePath(self),
				method = method,
				arguments = arguments,
			}, true)
			table.insert(report.outgoing, record)
			if #report.outgoing > 100 then table.remove(report.outgoing, 1) end
			save("outgoing remote before forwarding")
		end
		return oldNamecall(self, ...)
	end))
else
	report.outboundCaptureUnavailable = true
end

-- Poll only focused primitive fields; no repeated whole-game scan occurs.
task.spawn(function()
	while controller.active do
		task.wait(pollInterval)
		local changed = false
		for _, watcher in ipairs(controller.watchers) do
			local value = rawget(watcher.owner, watcher.key)
			local signature = simpleSignature(value)
			if signature ~= watcher.last then
				local before = watcher.last
				watcher.last = signature
				local record = emit("RUNTIME_CHANGED", {
					path = watcher.path,
					category = watcher.category,
					before = before,
					after = serialize(value),
				})
				table.insert(report.changes, record)
				if #report.changes > 300 then table.remove(report.changes, 1) end
				changed = true
			end
		end
		if changed then save("runtime changed") end
	end
end)

function controller.stop()
	if not controller.active then return end
	controller.active = false
	for _, connection in ipairs(controller.connections) do
		pcall(function() connection:Disconnect() end)
	end
	report.status = "STOPPED"
	report.stoppedAt = os.time()
	save("manual stop")
	print("[MainFlowProbe][STOPPED] records=" .. controller.sequence)
end

report.status = "ACTIVE"
environment.AnimeOriginMainFlowProbe = controller
save("initial snapshot")

print("[MainFlowProbe][LEVEL] " .. encode(report.account.authoritative or report.account.expCandidates))
print("[MainFlowProbe][STORY] " .. encode(report.story.acts))
print("[MainFlowProbe][MATCH] " .. encode({
	matchRuntimes = #report.matchRuntimes,
	runtimeCandidates = #report.runtimeCandidates,
}))
warn("[MainFlowProbe][FILE] " .. summaryFile)
warn("[MainFlowProbe][ACTIVE] Let it observe match/end/restart changes, then call AnimeOriginMainFlowProbe.stop().")
return controller
