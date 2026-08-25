--[[
	Anime Origin compact realtime status observer

	This file is read-only. It never opens PlayerGui and never invokes or fires a
	remote. Account values come from the live PlayerData table, account level is
	derived with the game's GetPlayerLevelFromExp function, and stage identity
	comes from ActRemoteEvent/main.lua's server-backed route state.

	Normal output is intentionally one line containing only Status, Level, Gems,
	TraitReroll and Farm. A new line is printed only when one of those values
	changes. Dependency failures are deduplicated ERROR lines.
]]

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local environment = getgenv()

-- Shared milestone trace. Resolved per call rather than captured at load time,
-- because Config publishes the tracer and Auto-Execute does not guarantee order.
local function trace(message, data)
	local tracer = environment.AnimeOriginTrace
	if typeof(tracer) == "function" then tracer("LogStats", message, data) end
	-- The same milestone, in structured form, into the folder capture. Feeding
	-- the recorder from the existing trace points means the whole milestone
	-- stream is captured without a second set of call sites to keep in sync.
	local diag = environment.AnimeOriginDiag
	if typeof(diag) == "table" and typeof(diag.mark) == "function" then
		diag.mark("LogStats", message, data)
	end
end

-- Stop an older observer before attaching a fresh set of listeners. Re-running
-- this file therefore cannot multiply polling loops or duplicate console lines.
local previous = environment.AnimeOriginLogStats
if typeof(previous) == "table" and typeof(previous.stop) == "function" then
	pcall(previous.stop)
end

local controller = {
	active = true,
	connections = {},
	lastSnapshot = nil,
}
environment.AnimeOriginLogStats = controller

local function disconnectAll()
	for _, connection in ipairs(controller.connections) do
		pcall(function() connection:Disconnect() end)
	end
	controller.connections = {}
end

function controller.stop()
	controller.active = false
	disconnectAll()
end

local config
local settings
-- Seed both readiness references before the loop. The loop must test the cached
-- local player, not Players.LocalPlayer directly: during Auto-Execute the service
-- value can become ready between iterations, otherwise the loop exits before the
-- newly-ready value is copied into this local variable.
local player = Players.LocalPlayer
local startedAt = os.clock()
local errorTimes = {}

local function emitError(key, message)
	local cooldown = settings and tonumber(settings.errorCooldown) or 15
	local now = os.clock()
	if now - (errorTimes[key] or -math.huge) < cooldown then return end
	errorTimes[key] = now
	print("[LogStats][ERROR] " .. tostring(message))
end

local function isPlayerData(value)
	if typeof(value) ~= "table" then return false end
	local inventory = rawget(value, "Inventory")
	return typeof(inventory) == "table"
		and typeof(rawget(inventory, "Currency")) == "table"
		and typeof(rawget(inventory, "Towers")) == "table"
		and typeof(rawget(value, "ProfileData")) == "table"
end

local function isLevelUtility(value)
	return typeof(value) == "table"
		and typeof(rawget(value, "GetPlayerLevelFromExp")) == "function"
		and typeof(rawget(value, "NeededPlayerEXP")) == "function"
end

local function isMatchRuntime(value)
	return typeof(value) == "table"
		and typeof(rawget(value, "GameStarted")) == "boolean"
		and typeof(rawget(value, "TowerDict")) == "table"
		and typeof(rawget(value, "TowerNPCDict")) == "table"
		and typeof(rawget(value, "PathPositions")) == "table"
end

local playerDataContainer
local playerDataIsWrapper = false
local levelUtility
local matchRuntime
local lastDiscoveryAt = -math.huge
local forceDiscovery = true

local function readPlayerData()
	if typeof(playerDataContainer) ~= "table" then return nil end
	if playerDataIsWrapper then
		local current = rawget(playerDataContainer, "PlayerData")
		return isPlayerData(current) and current or nil
	end
	return isPlayerData(playerDataContainer) and playerDataContainer or nil
end

-- All three volatile runtime dependencies are resolved in one getgc traversal.
-- The broad array is released immediately so this observer does not retain the
-- game graph or become another source of long-session memory growth.
local function discoverRuntime()
	if typeof(getgc) ~= "function" then
		emitError("getgc", "getgc(true) is unavailable.")
		return
	end
	local ok, objects = pcall(getgc, true)
	if not ok or typeof(objects) ~= "table" then
		emitError("getgc", "getgc(true) failed.")
		return
	end

	local directPlayerData
	for _, object in ipairs(objects) do
		if typeof(object) == "table" then
			local nested = rawget(object, "PlayerData")
			if isPlayerData(nested) then
				playerDataContainer = object
				playerDataIsWrapper = true
			elseif not directPlayerData and isPlayerData(object) then
				directPlayerData = object
			end
			if not isLevelUtility(levelUtility) and isLevelUtility(object) then
				levelUtility = object
			end
			if not isMatchRuntime(matchRuntime) and isMatchRuntime(object) then
				matchRuntime = object
			end
		end
	end
	if not readPlayerData() and directPlayerData then
		playerDataContainer = directPlayerData
		playerDataIsWrapper = false
	end
	objects = nil
	lastDiscoveryAt = os.clock()
	forceDiscovery = false
end

local currentTarget
local eventStatus
local boundActRemote

local function targetFromPayload(payload)
	if typeof(payload) ~= "table" then return nil end
	local world = rawget(payload, "WorldName") or rawget(payload, "World")
	local mode = rawget(payload, "GameMode") or rawget(payload, "Mode")
	local act = rawget(payload, "Act")
	local difficulty = rawget(payload, "Difficulty")
	if world == nil and mode == nil and act == nil and difficulty == nil then return nil end
	return {
		world = world,
		mode = mode,
		act = act,
		difficulty = difficulty,
	}
end

local function onActEvent(action, payload)
	if action == "UpdateClientGame" then
		currentTarget = targetFromPayload(payload) or currentTarget
		eventStatus = "WAITING_START"
		forceDiscovery = true
	elseif action == "StartWaveVote" then
		eventStatus = "WAITING_START"
		forceDiscovery = true
	elseif action == "ActOver" then
		currentTarget = targetFromPayload(payload) or currentTarget
		eventStatus = "END_MATCH"
	elseif action == "EndGame" then
		eventStatus = "END_MATCH"
	end
end

local function tryBindActRemote()
	local lobbyRemotes = ReplicatedStorage:FindFirstChild("LobbyRemotes")
	local remote = lobbyRemotes and lobbyRemotes:FindFirstChild("ActRemoteEvent")
	if not remote or not remote:IsA("RemoteEvent") or remote == boundActRemote then return end
	boundActRemote = remote
	table.insert(controller.connections, remote.OnClientEvent:Connect(onActEvent))
end

local function normalize(value)
	return string.lower(tostring(value or "")):gsub("[^%w]", "")
end

local function targetFromMain()
	local main = environment.AnimeOriginMain
	local report = typeof(main) == "table" and rawget(main, "report") or nil
	if typeof(report) ~= "table" then return nil end
	local stage = rawget(report, "currentStage")
	if typeof(stage) == "table" then return stage end
	local decision = rawget(report, "decision")
	return typeof(decision) == "table" and decision or nil
end

local function fallbackTarget()
	local fromMain = targetFromMain()
	if fromMain then return fromMain end
	local fastGems = config and config.fastGems
	local stage = typeof(fastGems) == "table" and rawget(fastGems, "stage") or nil
	return typeof(stage) == "table" and stage or nil
end

local function farmLabel(target)
	if typeof(target) ~= "table" then return "-" end
	local mode = normalize(rawget(target, "mode") or rawget(target, "GameMode"))
	local act = normalize(rawget(target, "act") or rawget(target, "Act"))
	local difficulty = normalize(rawget(target, "difficulty") or rawget(target, "Difficulty"))
	if mode == "infinite" or string.find(act, "infinite", 1, true) then return "INF" end
	if difficulty == "hard" then return "HARD" end
	if difficulty == "normal" then return "NORMAL" end
	return "-"
end

local function isLobbyPlace()
	local places = config and config.runtimePlaces and config.runtimePlaces.lobby
	return typeof(places) == "table" and places[game.PlaceId] == true
end

local function isStagePlace()
	local places = config and config.runtimePlaces and config.runtimePlaces.stage
	return typeof(places) == "table" and places[game.PlaceId] == true
end

local mainStatusMap = {
	TELEPORTING_TO_STAGE = "TELEPORTING",
	TELEPORTING_TO_LOBBY = "TELEPORTING",
	ENTERING_STAGE = "SELECTING_STAGE",
	DECIDING_ROUTE = "SELECTING_STAGE",
	WAITING_FOR_CONTEXT = "LOADING",
	WAITING_FOR_LOBBY_RUNTIME = "LOADING",
	MONITORING_STAGE = "FARMING",
	FAILED = "ERROR",
}

local function statusLabel()
	if eventStatus == "TELEPORTING" then return "TELEPORTING" end
	if isStagePlace() then
		if eventStatus == "END_MATCH" then return "END_MATCH" end
		if isMatchRuntime(matchRuntime) then
			return rawget(matchRuntime, "GameStarted") == true and "FARMING" or "WAITING_START"
		end
		return eventStatus or "LOADING"
	end

	local main = environment.AnimeOriginMain
	local report = typeof(main) == "table" and rawget(main, "report") or nil
	local mainStatus = typeof(report) == "table" and tostring(rawget(report, "status") or "") or ""
	if mainStatusMap[mainStatus] then return mainStatusMap[mainStatus] end

	local lifecycle = environment.AnimeOriginLifecycle
	local tasks = typeof(lifecycle) == "table" and rawget(lifecycle, "tasks") or nil
	if typeof(tasks) == "table" then
		for _, name in ipairs({ "FastMode", "UnitProgression" }) do
			local entry = rawget(tasks, name)
			if typeof(entry) == "table" and rawget(entry, "status") == "RUNNING" then
				return "PREPARING"
			end
		end
	end
	return isLobbyPlace() and "LOBBY" or "LOADING"
end

local function roundedInteger(value)
	local number = tonumber(value)
	return number and math.floor(number + 0.5) or "?"
end

local function readSnapshot()
	local data = readPlayerData()
	local inventory = data and rawget(data, "Inventory")
	local currency = typeof(inventory) == "table" and rawget(inventory, "Currency") or nil
	local exp = data and tonumber(rawget(data, "Exp")) or nil
	local level = nil
	if exp and isLevelUtility(levelUtility) then
		local ok, result = pcall(rawget(levelUtility, "GetPlayerLevelFromExp"), exp)
		if ok then level = tonumber(result) end
	end
	local target = currentTarget or fallbackTarget()
	return {
		status = statusLabel(),
		level = roundedInteger(level),
		gems = roundedInteger(typeof(currency) == "table" and rawget(currency, "Gems") or nil),
		traitReroll = roundedInteger(typeof(currency) == "table" and rawget(currency, "TraitReroll") or nil),
		farm = farmLabel(target),
	}
end

local function snapshotSignature(snapshot)
	return table.concat({
		tostring(snapshot.status),
		tostring(snapshot.level),
		tostring(snapshot.gems),
		tostring(snapshot.traitReroll),
		tostring(snapshot.farm),
	}, "\0")
end

local lastSignature
local function emitSnapshot(snapshot)
	local signature = snapshotSignature(snapshot)
	if signature == lastSignature then return end
	lastSignature = signature
	controller.lastSnapshot = snapshot
	print(string.format(
		"[LogStats] Status=%s | Level=%s | Gems=%s | TraitReroll=%s | Farm=%s",
		tostring(snapshot.status),
		tostring(snapshot.level),
		tostring(snapshot.gems),
		tostring(snapshot.traitReroll),
		tostring(snapshot.farm)
	))
end

task.spawn(function()
	while controller.active and (typeof(config) ~= "table" or not player) do
		config = environment.AnimeOriginConfig
		player = Players.LocalPlayer
		if os.clock() - startedAt >= 60 then
			if typeof(config) ~= "table" then emitError("config", "Config.lua was not found.") end
			if not player then emitError("player", "LocalPlayer was not found.") end
		end
		task.wait(0.1)
	end
	if not controller.active then return end
	settings = typeof(config.logStats) == "table" and config.logStats or {}
	if settings.enabled == false then controller.stop(); return end

	-- Teleport is status evidence only; the new place's Auto-Execute lifecycle will
	-- replace this observer and rediscover every runtime table from scratch.
	table.insert(controller.connections, player.OnTeleport:Connect(function()
		eventStatus = "TELEPORTING"
		emitSnapshot(readSnapshot())
	end))

	trace("observing", { placeId = game.PlaceId })
	local pollInterval = math.max(0.05, tonumber(settings.pollInterval) or 0.2)
	local discoveryInterval = math.max(0.25, tonumber(settings.runtimeDiscoveryInterval) or 0.5)
	local grace = math.max(5, tonumber(settings.dependencyGraceSeconds) or 60)
	local runtimeWaitStartedAt = os.clock()
	while controller.active do
		tryBindActRemote()
		local data = readPlayerData()
		local runtimeInvalid = not data or not isLevelUtility(levelUtility)
			or (isStagePlace() and not isMatchRuntime(matchRuntime))
		if forceDiscovery or (runtimeInvalid and os.clock() - lastDiscoveryAt >= discoveryInterval) then
			discoverRuntime()
			data = readPlayerData()
		end

		if os.clock() - runtimeWaitStartedAt >= grace then
			if not data then emitError("playerData", "Live PlayerData was not found.") end
			if not isLevelUtility(levelUtility) then
				emitError("levelUtility", "GetPlayerLevelFromExp was not found.")
			end
			if isStagePlace() and not boundActRemote then
				emitError("actRemote", "ActRemoteEvent was not found in the stage.")
			end
		end

		emitSnapshot(readSnapshot())
		task.wait(pollInterval)
	end
end)

return controller
