--[[
	Anime Origin Fast Gems route orchestrator

	Responsibilities are intentionally narrow:
	  1. In the lobby, read server-fed account EXP and WestCity clear history.
	  2. Enter the Story portal through normal character movement, select the
	     required stage, and verify the server accepted it before teleporting.
	  3. In a stage, consume non-UI Wave/ActOver/UpdateClientGame evidence to
	     choose Next, Replay, Return To Lobby, or an exact-wave Infinite restart.

	FastMode.lua still owns claims/summons. AutoPlay.lua still owns the team and
	combat loop. InGameSettings.lua still owns settings and speed. This file never
	reads or clicks PlayerGui and never treats FireServer alone as success proof.

	Run Config.lua before this file in every newly joined server. State is written
	to the executor workspace so the selected route survives place transitions.
]]

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Workspace = game:GetService("Workspace")
local HttpService = game:GetService("HttpService")

local environment = getgenv()

-- Auto-Execute order is intentionally treated as nondeterministic. main.lua may
-- be injected before Config.lua during a join, so wait for both shared config and
-- LocalPlayer before creating route state or lifecycle listeners.
local function waitForAnimeOriginConfig(timeout)
	local deadline = os.clock() + (tonumber(timeout) or 30)
	repeat
		local config = environment.AnimeOriginConfig
		if typeof(config) == "table" then return config end
		task.wait(0.05)
	until os.clock() >= deadline
	error("[Main][AUTO_EXECUTE] Timed out waiting for Config.lua.", 0)
end

local function waitForLocalPlayer(timeout)
	local deadline = os.clock() + (tonumber(timeout) or 30)
	repeat
		if Players.LocalPlayer then return Players.LocalPlayer end
		task.wait(0.05)
	until os.clock() >= deadline
	error("[Main][AUTO_EXECUTE] Timed out waiting for LocalPlayer.", 0)
end

local player = waitForLocalPlayer()
local Config = waitForAnimeOriginConfig()

local Settings = Config.main
assert(typeof(Settings) == "table", "Config.main is missing.")
assert(Settings.enabled == true, "Config.main.enabled is false.")
local consoleStatusOnly = typeof(Config.console) == "table"
	and Config.console.statusOnly == true

local Route = Settings.fastGemsRoute
local Entrance = Settings.lobbyEntrance
assert(typeof(Route) == "table", "Config.main.fastGemsRoute is missing.")
assert(typeof(Entrance) == "table", "Config.main.lobbyEntrance is missing.")

-- Stop an older observer before installing another set of lifecycle listeners.
local previous = environment.AnimeOriginMain
if typeof(previous) == "table" and typeof(previous.stop) == "function" then
	pcall(previous.stop)
end

local stateFolder = tostring(Settings.stateFolder or "AnimeOrigin")
local stateFile = stateFolder .. "/MainRoute_" .. tostring(player.UserId) .. ".json"
local reportFile = stateFolder .. "/MainRoute_" .. tostring(player.UserId) .. "_latest.json"
local logFile = stateFolder .. "/MainRoute_" .. tostring(player.UserId) .. "_latest.log"
local pollInterval = tonumber(Settings.statePollInterval) or 0.2
local verifyTimeout = tonumber(Settings.transitionVerifyTimeout) or 12
local maximumRetainedLogLines = math.max(50, tonumber(Settings.maximumRetainedLogLines) or 300)
local maximumLogBytes = math.max(65536, tonumber(Settings.maximumLogBytes) or 1048576)
local writtenLogBytes = 0

local report = {
	version = 1,
	userId = player.UserId,
	placeId = game.PlaceId,
	jobId = game.JobId,
	startedAt = os.time(),
	status = "STARTING",
	context = nil,
	decision = nil,
	actions = {},
	events = {},
}

local controller = {
	active = true,
	connections = {},
	report = report,
}

local logLines = {}
local sequence = 0

local function ensureFolder()
	if typeof(makefolder) == "function" then
		local exists = typeof(isfolder) == "function" and isfolder(stateFolder)
		if not exists then pcall(makefolder, stateFolder) end
	end
end

local function encode(value)
	local ok, result = pcall(HttpService.JSONEncode, HttpService, value)
	return ok and result or HttpService:JSONEncode({ encodingError = tostring(result) })
end

local function serializable(value, depth, visited)
	depth = depth or 0
	visited = visited or {}
	local kind = typeof(value)
	if kind == "nil" or kind == "string" or kind == "number" or kind == "boolean" then return value end
	if kind == "Instance" then
		local ok, path = pcall(function() return value:GetFullName() end)
		return { type = "Instance", path = ok and path or tostring(value), class = value.ClassName }
	end
	if kind == "Vector3" then return { x = value.X, y = value.Y, z = value.Z } end
	if kind ~= "table" then return { type = kind, value = tostring(value) } end
	if visited[value] then return "<cycle>" end
	if depth >= 5 then return "<max-depth>" end
	visited[value] = true
	local result, count = {}, 0
	for key, child in next, value do
		count += 1
		if count > 300 then result.__truncated = true; break end
		result[tostring(key)] = serializable(child, depth + 1, visited)
	end
	visited[value] = nil
	return result
end

local lastReportWrite = -math.huge
local terminalReportStatuses = {
	FAILED = true,
	STOPPED = true,
	COMPLETE = true,
	DRY_RUN_COMPLETE = true,
	TELEPORTING_TO_STAGE = true,
	TELEPORTING_TO_LOBBY = true,
}

local function saveReport(reason, force)
	report.updatedAt = os.time()
	report.lastReason = reason
	local flushInterval = math.max(0, tonumber(Settings.reportFlushInterval) or 2)
	local immediate = force == true or terminalReportStatuses[tostring(report.status)] == true
	if not immediate and os.clock() - lastReportWrite < flushInterval then return false end
	if typeof(writefile) == "function" then
		ensureFolder()
		pcall(writefile, reportFile, encode(report))
	end
	lastReportWrite = os.clock()
	return true
end

local function log(stage, message, data, quiet)
	sequence += 1
	local record = {
		sequence = sequence,
		stage = stage,
		message = message,
		data = serializable(data),
		unixTime = os.time(),
		clock = os.clock(),
	}
	table.insert(report.events, record)
	if #report.events > 300 then table.remove(report.events, 1) end
	local line = string.format("[Main][%03d][%s] %s%s", sequence, stage, message,
		data ~= nil and (" | " .. encode(record.data)) or "")
	table.insert(logLines, line)
	if #logLines > maximumRetainedLogLines then table.remove(logLines, 1) end
	if typeof(appendfile) == "function" then
		pcall(appendfile, logFile, line .. "\n")
		-- The ring bounds memory but not the file. A night of farming across many
		-- accounts produced a log set too large to send. Restart the file from the
		-- retained tail once it passes the cap; recent history is what diagnosis uses.
		writtenLogBytes += #line + 1
		if writtenLogBytes >= maximumLogBytes and typeof(writefile) == "function" then
			pcall(writefile, logFile, table.concat(logLines, "\n") .. "\n")
			writtenLogBytes = 0
		end
	elseif typeof(writefile) == "function" then
		-- Some executor builds expose writefile without appendfile. Keep the same
		-- human-readable debug log available instead of silently losing it.
		pcall(writefile, logFile, table.concat(logLines, "\n") .. "\n")
	end
	if not quiet and not consoleStatusOnly then print("[Main] " .. message) end
	saveReport(stage)
	return record
end

local function fail(stage, message)
	report.status = "FAILED"
	report.error = stage .. ": " .. message
	log("ERROR", report.error)
	error("[Main][" .. stage .. "] " .. message, 0)
end

local function waitUntil(predicate, timeout)
	local deadline = os.clock() + (tonumber(timeout) or verifyTimeout)
	repeat
		if not controller.active then return false end
		local ok, result = pcall(predicate)
		if ok and result then return true end
		task.wait(pollInterval)
	until os.clock() >= deadline
	local ok, result = pcall(predicate)
	return ok and result == true
end

-- FastMode and UnitProgression own separate phases of the lobby pipeline. Routing
-- waits for both workers to become terminal, but only tasks explicitly marked
-- fatal may stop map selection. Persistent unit leveling is useful enrichment;
-- a rejected shop item must never strand Story -> Hard -> Infinite progression.
local function waitForBootstrapWorkers()
	local gate = Settings.bootstrapGate
	if typeof(gate) ~= "table" or gate.enabled ~= true then
		log("BOOTSTRAP", "Lobby bootstrap gate is disabled in Config.")
		return true
	end

	local required = typeof(gate.requiredTasks) == "table"
		and gate.requiredTasks or { "FastMode", "UnitProgression" }
	local fatalTasks = typeof(gate.fatalTasks) == "table" and gate.fatalTasks or {}
	local featureSettings = {
		FastMode = Config.fastGems,
		UnitProgression = Config.unitProgression,
	}
	local gateStartedAt = os.clock()
	local deadline = gateStartedAt + (tonumber(gate.timeout) or 300)
	-- Both workers publish RUNNING within their first moments of executing. If
	-- nothing has appeared after this window, the worker died during startup --
	-- before it could ever report FAILED -- and to the loop below "no signal" is
	-- indistinguishable from "still working". That is how one silent startup death
	-- became five minutes of an account standing in the lobby before main timed out
	-- and failed too. Prolonged absence IS a failure signal; feed it into the same
	-- fatal / non-fatal policy that a self-reported failure already goes through.
	local startupGrace = math.max(5, tonumber(gate.startupGrace) or 45)
	local lastSignature
	report.status = "WAITING_FOR_BOOTSTRAP"

	repeat
		if not controller.active then return false end
		local lifecycle = environment.AnimeOriginLifecycle
		local tasks = typeof(lifecycle) == "table" and lifecycle.jobId == game.JobId
			and lifecycle.tasks or nil
		local snapshot = {}
		local allComplete = true

		for _, taskName in ipairs(required) do
			local feature = featureSettings[taskName]
			local entry = typeof(tasks) == "table" and rawget(tasks, taskName) or nil
			local status
			local silent
			if typeof(feature) == "table" and feature.enabled == false then
				status = "SKIPPED"
			elseif typeof(entry) == "table" and entry.userId == player.UserId then
				status = tostring(entry.status or "PENDING")
			elseif os.clock() - gateStartedAt >= startupGrace then
				status = "FAILED"
				-- %s, not %d: startupGrace comes from Config and a fractional value would
				-- make string.format itself error -- inside the very path that reports a
				-- failure, turning a diagnosable stall into an unexplained crash.
				silent = string.format("published no lifecycle signal within %ss; it died during startup",
					tostring(startupGrace))
			else
				status = "PENDING"
			end
			snapshot[taskName] = silent and (status .. " (no signal)") or status
			if status == "FAILED" and fatalTasks[taskName] == true then
				report.bootstrapGate = snapshot
				fail("BOOTSTRAP", taskName .. " failed; main routing was not started."
					.. (silent and (" It " .. silent .. ".") or ""))
			elseif status == "FAILED" then
				report.bootstrapWarnings = report.bootstrapWarnings or {}
				report.bootstrapWarnings[taskName] = silent
					or "Worker failed after a bounded run; routing continued."
			end
			local terminal = status == "COMPLETE" or status == "SKIPPED" or status == "FAILED"
			if not terminal then allComplete = false end
		end

		local signature = encode(snapshot)
		if signature ~= lastSignature then
			lastSignature = signature
			report.bootstrapGate = snapshot
			log("BOOTSTRAP", allComplete and "Lobby workers are complete."
				or "Waiting for lobby workers before route selection.", snapshot)
		end
		if allComplete then return true end
		task.wait(pollInterval)
	until os.clock() >= deadline

	fail("BOOTSTRAP", "Timed out waiting for FastMode/UnitProgression completion signals.")
end

local function loadState()
	local default = {
		version = 1,
		userId = player.UserId,
		routeActive = false,
		matchEpoch = 0,
	}
	if typeof(isfile) ~= "function" or typeof(readfile) ~= "function" or not isfile(stateFile) then
		return default
	end
	local ok, value = pcall(HttpService.JSONDecode, HttpService, readfile(stateFile))
	if not ok or typeof(value) ~= "table" or value.version ~= 1 or value.userId ~= player.UserId then
		return default
	end
	return value
end

local state = loadState()

local function saveState(reason)
	if typeof(writefile) ~= "function" then fail("STATE", "writefile is required for teleport-safe routing.") end
	ensureFolder()
	state.updatedAt = os.time()
	state.lastReason = reason
	writefile(stateFile, encode(state))
	report.persistedState = serializable(state)
	saveReport("state: " .. reason)
end

ensureFolder()
if typeof(writefile) == "function" then
	writefile(logFile, "")
	writefile(reportFile, encode(report))
end

-- Remotes currently attached, keyed by role. Cleared by disconnectAll.
local boundRemotes = {}

local function disconnectAll()
	for _, connection in ipairs(controller.connections) do
		pcall(function() connection:Disconnect() end)
	end
	controller.connections = {}
	-- boundRemotes records what is currently attached, and bindRemote skips any key
	-- it still believes is bound. Leaving it populated after a teardown would make a
	-- restarted route run deaf: no MapSelect, no Notification, no generic events.
	table.clear(boundRemotes)
end

function controller.stop()
	if not controller.active then return end
	controller.active = false
	disconnectAll()
	report.status = "STOPPED"
	saveReport("manual stop")
	if not consoleStatusOnly then print("[Main] stopped") end
end

environment.AnimeOriginMain = controller

-- PlayerData/getgc indices drift every join, so every resolver uses structural
-- evidence instead of a fixed index copied from a probe report.
local gcObjects
local gcCapturedAt = -math.huge
local function getGCObjects(forceRefresh)
	-- Replay/Next/Restart may replace runtime tables without replacing the Lua
	-- environment. A short cache avoids an expensive getgc scan every poll while
	-- still allowing a new match lifecycle to become visible promptly.
	if not forceRefresh and gcObjects and os.clock() - gcCapturedAt < 0.5 then return gcObjects end
	assert(typeof(getgc) == "function", "main.lua requires getgc(true).")
	local ok, objects = pcall(getgc, true)
	assert(ok and typeof(objects) == "table", "getgc(true) failed.")
	gcObjects = objects
	gcCapturedAt = os.clock()
	return objects
end

local function isPlayerData(value)
	if typeof(value) ~= "table" then return false end
	local inventory = rawget(value, "Inventory")
	return typeof(inventory) == "table"
		and typeof(rawget(inventory, "Towers")) == "table"
		and typeof(rawget(inventory, "Currency")) == "table"
		and typeof(rawget(value, "ProfileData")) == "table"
end

local cachedPlayerDataContainer
local cachedPlayerDataSource
local cachedPlayerDataIsWrapper = false
local cachedLevelUtility
local cachedLevelUtilitySource

local function readCachedPlayerData()
	if typeof(cachedPlayerDataContainer) ~= "table" then return nil end
	if cachedPlayerDataIsWrapper then
		local nested = rawget(cachedPlayerDataContainer, "PlayerData")
		return isPlayerData(nested) and nested or nil
	end
	return isPlayerData(cachedPlayerDataContainer) and cachedPlayerDataContainer or nil
end

-- Resolve PlayerData and the level utility in one getgc traversal. The old code
-- traversed the same large snapshot once for each dependency on every poll.
local function resolveLobbyRuntime(forceRefresh)
	local cachedPlayerData = readCachedPlayerData()
	local playerDataValid = isPlayerData(cachedPlayerData)
	local levelUtilityValid = typeof(cachedLevelUtility) == "table"
		and typeof(rawget(cachedLevelUtility, "GetPlayerLevelFromExp")) == "function"
		and typeof(rawget(cachedLevelUtility, "NeededPlayerEXP")) == "function"
	if playerDataValid and levelUtilityValid
		and (cachedPlayerDataIsWrapper or forceRefresh ~= true) then
		return cachedPlayerData, cachedPlayerDataSource, cachedLevelUtility, cachedLevelUtilitySource
	end

	local directCandidate, directSource
	for index, object in ipairs(getGCObjects(forceRefresh == true)) do
		if typeof(object) == "table" then
			local nested = rawget(object, "PlayerData")
			if isPlayerData(nested) then
				cachedPlayerDataContainer = object
				cachedPlayerDataSource = "getgc[" .. index .. "].PlayerData"
				cachedPlayerDataIsWrapper = true
				cachedPlayerData = nested
				playerDataValid = true
			elseif not directCandidate and isPlayerData(object) then
				directCandidate = object
				directSource = "getgc[" .. index .. "]"
			end
		end
		if not levelUtilityValid and typeof(object) == "table"
			and typeof(rawget(object, "GetPlayerLevelFromExp")) == "function"
			and typeof(rawget(object, "NeededPlayerEXP")) == "function" then
			cachedLevelUtility = object
			cachedLevelUtilitySource = "getgc[" .. index .. "]"
			levelUtilityValid = true
		end
		-- A direct PlayerData snapshot can occur before the stable wrapper in getgc;
		-- keep scanning until the wrapper is found instead of freezing stale clears/EXP.
		if cachedPlayerDataIsWrapper and levelUtilityValid then break end
	end
	if not playerDataValid and directCandidate then
		cachedPlayerDataContainer = directCandidate
		cachedPlayerDataSource = directSource
		cachedPlayerDataIsWrapper = false
		cachedPlayerData = directCandidate
	end
	return cachedPlayerData, cachedPlayerDataSource, cachedLevelUtility, cachedLevelUtilitySource
end

local function readAccountLevel(forceRefresh)
	local data, dataSource, utility, utilitySource = resolveLobbyRuntime(forceRefresh)
	if not data then return nil, nil, nil end
	local exp = tonumber(rawget(data, "Exp"))
	if not exp or not utility then return nil, exp, dataSource end
	local levelFunction = rawget(utility, "GetPlayerLevelFromExp")
	if typeof(levelFunction) ~= "function" then return nil, exp, dataSource end
	local ok, level = pcall(levelFunction, exp)
	if not ok or not tonumber(level) then return nil, exp, dataSource end
	return tonumber(level), exp, dataSource .. " + " .. utilitySource
end

-- The Story portal and remotes often replicate before PlayerData after returning
-- from Act 6. Keep Main alive across bounded windows and refresh getgc only at the
-- configured discovery interval until both authoritative dependencies exist.
local function waitForLobbyRuntime()
	local window = math.max(60, tonumber(Settings.lobbyPlayerDataTimeout)
		or tonumber(Settings.runtimeLoadTimeout) or 60)
	local interval = math.max(0.25, tonumber(Settings.runtimeDiscoveryInterval) or 0.5)
	local windowNumber = 0
	while controller.active do
		windowNumber += 1
		local deadline = os.clock() + window
		local lastProgressLog = -math.huge
		repeat
			local data, source, utility = resolveLobbyRuntime(true)
			local level, exp, levelSource = readAccountLevel(false)
			if data and utility and level then
				-- Keep only verified runtime tables; the temporary getgc array can hold
				-- hundreds of thousands of references and must not live for the route.
				gcObjects = nil
				return data, source, level, exp, levelSource
			end
			if os.clock() - lastProgressLog >= 10 then
				lastProgressLog = os.clock()
				log("PLAYER_DATA_WAIT", "Waiting for late lobby PlayerData/level utility.", {
					window = windowNumber,
					playerData = data ~= nil,
					levelUtility = utility ~= nil,
					exp = exp,
				}, true)
			end
			task.wait(interval)
		until os.clock() >= deadline or not controller.active
		if controller.active then
			log("PLAYER_DATA_RETRY", "Lobby runtime window elapsed; continuing discovery instead of stopping Main.", {
				window = windowNumber,
				seconds = window,
			})
		end
	end
	return nil
end

local function resolveMatchRuntime(preferredStarted)
	local fallback, fallbackSource
	for index, object in ipairs(getGCObjects()) do
		if typeof(object) == "table"
			and typeof(rawget(object, "GameStarted")) == "boolean"
			and typeof(rawget(object, "TowerDict")) == "table"
			and typeof(rawget(object, "TowerNPCDict")) == "table"
			and typeof(rawget(object, "PathPositions")) == "table" then
			local source = "getgc[" .. index .. "]"
			if preferredStarted == nil or rawget(object, "GameStarted") == preferredStarted then
				gcObjects = nil
				return object, source
			end
			fallback, fallbackSource = fallback or object, fallbackSource or source
		end
	end
	-- MatchRuntime is retained by the caller; release the broad executor snapshot.
	gcObjects = nil
	return fallback, fallbackSource
end

local function normalize(value)
	return string.lower(tostring(value or "")):gsub("[^%w]", "")
end

local function targetFromPayload(payload)
	if typeof(payload) ~= "table" then return nil end
	local world = rawget(payload, "WorldName") or rawget(payload, "World")
	local mode = rawget(payload, "GameMode") or rawget(payload, "Mode")
	local act = rawget(payload, "Act")
	local difficulty = rawget(payload, "Difficulty")
	if world == nil and mode == nil and act == nil and difficulty == nil then return nil end
	return {
		mode = tostring(mode or Route.storyMode or "Story"),
		world = tostring(world or Route.world or "WestCity"),
		act = tostring(act or ""),
		difficulty = tostring(difficulty or ""),
	}
end

local function targetMatches(left, right)
	if typeof(left) ~= "table" or typeof(right) ~= "table" then return false end
	local leftAct = normalize(left.act)
	local rightAct = normalize(right.act)
	local sameAct = leftAct == rightAct
		or (string.find(leftAct, "infinite", 1, true) ~= nil
			and string.find(rightAct, "infinite", 1, true) ~= nil)
	return normalize(left.world) == normalize(right.world)
		and sameAct
		and normalize(left.difficulty) == normalize(right.difficulty)
		and (normalize(left.mode) == normalize(right.mode)
			or (normalize(left.mode) == "infinite" and normalize(right.act) == "infinite")
			or (normalize(right.mode) == "infinite" and normalize(left.act) == "infinite"))
end

local function isInfiniteTarget(target)
	return typeof(target) == "table"
		and (normalize(target.mode) == "infinite" or string.find(normalize(target.act), "infinite", 1, true) ~= nil)
end

-- These remotes do not necessarily replicate in both places. In particular,
-- Notification may exist only inside a stage. Never WaitForChild indefinitely
-- during startup: bind each remote lazily when its current place exposes it.
local mapRemote
local actRemote
local genericRemote
local notificationRemote

local bus = {
	mapSelectGeneration = 0,
	afterMapSelectGeneration = 0,
	playersInsideGeneration = 0,
	updateClientGeneration = 0,
	startVoteGeneration = 0,
	actOverGeneration = 0,
	teleportGeneration = 0,
	waveGeneration = 0,
	currentStage = nil,
	currentWave = nil,
	lastActOver = nil,
	playersInside = {},
	localPlayerInside = false,
	portalOccupiedByOther = false,
	portalReservedByOther = false,
}

local function recordAction(name, details)
	local action = {
		name = name,
		details = serializable(details),
		startedAt = os.time(),
		verified = false,
	}
	table.insert(report.actions, action)
	if #report.actions > 150 then table.remove(report.actions, 1) end
	log("ACTION", name, details)
	return action
end

local function collectPlayerInstances(value, result, visited, depth)
	result = result or {}
	visited = visited or {}
	depth = depth or 0
	if depth > 4 then return result end
	if typeof(value) == "Instance" then
		if value:IsA("Player") then result[value.UserId] = value end
		return result
	end
	if typeof(value) ~= "table" or visited[value] then return result end
	visited[value] = true
	for _, child in next, value do collectPlayerInstances(child, result, visited, depth + 1) end
	visited[value] = nil
	return result
end

local function onMapEvent(action, payload, ...)
	if action == "MapSelect" then
		bus.mapSelectGeneration += 1
	elseif action == "AfterMapSelect" and typeof(payload) == "table" then
		bus.afterMapSelectGeneration += 1
		bus.afterMapSelect = targetFromPayload(payload)
	elseif action == "UpdatePlayersInside" then
		-- Captured normal flow: action, changedPlayer, playersInside, selectionData.
		-- Keep the players array separate from selectionData so a PartyLeader field
		-- cannot masquerade as occupancy. This event is the server's Pod evidence.
		local playersList, selectionData = ...
		local playersInside = collectPlayerInstances(playersList)
		if next(playersInside) == nil then collectPlayerInstances(payload, playersInside) end
		local occupiedByOther = false
		for userId in next, playersInside do
			if userId ~= player.UserId then occupiedByOther = true; break end
		end
		local partyLeader = typeof(selectionData) == "table" and rawget(selectionData, "PartyLeader") or nil
		bus.playersInsideGeneration += 1
		bus.playersInside = playersInside
		bus.localPlayerInside = playersInside[player.UserId] ~= nil
		bus.portalOccupiedByOther = occupiedByOther
		bus.portalReservedByOther = typeof(partyLeader) == "Instance"
			and partyLeader:IsA("Player") and partyLeader ~= player
		bus.lastOccupancySubject = payload
		bus.lastPortalPartyLeader = partyLeader
	elseif action == "TeleportGui" then
		bus.teleportGeneration += 1
	end
	log("MAP_EVENT", tostring(action), payload, true)
end

local function onGenericEvent(action, payload, ...)
	if action == "TeleportGui" then bus.teleportGeneration += 1 end
	log("GENERIC_EVENT", tostring(action), payload, true)
end

local function onNotificationEvent(action, message, ...)
	if action ~= "Notification" or typeof(message) ~= "string" then return end
	local wave = tonumber(string.match(message, "^Wave%s+(%d+)$"))
	if not wave then return end
	bus.currentWave = wave
	bus.waveGeneration += 1
	log("WAVE", "Server announced Wave " .. wave .. ".", { wave = wave }, true)
	if typeof(controller.onWave) == "function" then task.spawn(controller.onWave, wave) end
end

local function onActEvent(action, payload, ...)
	if action == "UpdateClientGame" and typeof(payload) == "table" then
		bus.updateClientGeneration += 1
		bus.currentStage = targetFromPayload(payload)
		if bus.currentStage then
			state.target = bus.currentStage
			state.routeActive = true
			saveState("server UpdateClientGame")
		end
	elseif action == "StartWaveVote" then
		bus.startVoteGeneration += 1
	elseif action == "ActOver" and typeof(payload) == "table" then
		bus.actOverGeneration += 1
		bus.lastActOver = payload
		local resultTarget = targetFromPayload(payload)
		if resultTarget then bus.currentStage = resultTarget end
		if typeof(controller.onActOver) == "function" then task.spawn(controller.onActOver, payload) end
	elseif action == "EndGame" then
		bus.endGameSeenAt = os.clock()
	end
	log("ACT_EVENT", tostring(action), payload, true)
end

local function bindRemote(key, remote, callback)
	if not remote or boundRemotes[key] == remote then return end
	if not remote:IsA("RemoteEvent") then return end
	boundRemotes[key] = remote
	table.insert(controller.connections, remote.OnClientEvent:Connect(callback))
	log("REMOTE_BOUND", key .. " listener attached.", { path = remote:GetFullName() }, true)
end

local function tryBindRemotes()
	local lobbyRemotes = ReplicatedStorage:FindFirstChild("LobbyRemotes")
	local remotes = ReplicatedStorage:FindFirstChild("Remotes")

	mapRemote = lobbyRemotes and lobbyRemotes:FindFirstChild("MapSelectRemote") or mapRemote
	actRemote = lobbyRemotes and lobbyRemotes:FindFirstChild("ActRemoteEvent") or actRemote
	genericRemote = remotes and remotes:FindFirstChild("RemoteEvent") or genericRemote
	notificationRemote = remotes and remotes:FindFirstChild("Notification") or notificationRemote

	bindRemote("MapSelectRemote", mapRemote, onMapEvent)
	bindRemote("ActRemoteEvent", actRemote, onActEvent)
	bindRemote("RemoteEvent", genericRemote, onGenericEvent)
	bindRemote("Notification", notificationRemote, onNotificationEvent)
end

-- Initial binding is non-yielding. The background resolver covers delayed
-- replication and place-specific remotes without holding up controller startup.
tryBindRemotes()
task.spawn(function()
	local remoteBindInterval = math.max(0.5, tonumber(Settings.remoteBindInterval) or 1)
	while controller.active do
		tryBindRemotes()
		task.wait(remoteBindInterval)
	end
end)

table.insert(controller.connections, player.OnTeleport:Connect(function(teleportState, placeId, spawnName)
	bus.teleportGeneration += 1
	log("TELEPORT", tostring(teleportState), { placeId = placeId, spawnName = spawnName }, true)
end))

local function resolveWorkspacePath(path)
	local current = Workspace
	for _, segment in ipairs(path or {}) do
		current = current and current:FindFirstChild(tostring(segment)) or nil
		if not current then return nil end
	end
	return current
end

-- Sibling Story Pods share both their Name and their GetFullName path, so a log
-- line that prints only the path cannot tell one door from another -- every
-- captured failure looked like the same door being retried. The rounded world
-- position is the cheap identity that actually distinguishes them.
local function portalKey(door)
	if typeof(door) ~= "Instance" then return nil end
	local ok, position = pcall(function() return door.Position end)
	if not ok or typeof(position) ~= "Vector3" then return nil end
	return string.format("%.1f,%.1f,%.1f", position.X, position.Y, position.Z)
end

local recentPortalFailures = {}
-- How many times each door refused us this session. A timestamp alone cannot
-- deprioritise a door for longer than one attempt takes.
local portalFailureCounts = {}

-- Occupancy must be decided before moving the local character. Every Story Pod
-- owns an InsideModel, so its live bounding box gives us a per-door signal that
-- UpdatePlayersInside alone cannot provide (that remote does not identify a Pod).
local function portalHasOtherPlayer(portal)
	local pod = portal and portal.Parent
	local insideModel = pod and pod:FindFirstChild("InsideModel")
	if not insideModel or not insideModel:IsA("Model") then return false, nil end
	local ok, boxCFrame, boxSize = pcall(function()
		return insideModel:GetBoundingBox()
	end)
	if not ok or typeof(boxCFrame) ~= "CFrame" or typeof(boxSize) ~= "Vector3" then
		return false, nil
	end
	local padding = math.max(0, tonumber(Entrance.occupancyBoundsPadding) or 1.5)
	for _, otherPlayer in ipairs(Players:GetPlayers()) do
		if otherPlayer ~= player then
			local character = otherPlayer.Character
			local otherRoot = character and character:FindFirstChild("HumanoidRootPart")
			if otherRoot then
				local point = boxCFrame:PointToObjectSpace(otherRoot.Position)
				if math.abs(point.X) <= boxSize.X * 0.5 + padding
					and math.abs(point.Y) <= boxSize.Y * 0.5 + padding
					and math.abs(point.Z) <= boxSize.Z * 0.5 + padding then
					return true, otherPlayer
				end
			end
		end
	end
	return false, nil
end

-- Story contains multiple sibling Pods with the same Instance name, so a direct
-- FindFirstChild chain always binds to only the first door. Discover every
-- DoorUIPart below Story and sort deterministically by cooldown then distance.
local function resolvePortalCandidates()
	local candidates, seen = {}, {}
	local root = resolveWorkspacePath(Entrance.portalRootPath)
	local doorName = tostring(Entrance.portalDoorName or "DoorUIPart")
	if root then
		for _, descendant in ipairs(root:GetDescendants()) do
			if descendant:IsA("BasePart") and descendant.Name == doorName and not seen[descendant] then
				seen[descendant] = true
				table.insert(candidates, descendant)
			end
		end
	end
	local fallback = resolveWorkspacePath(Entrance.portalPath)
	if fallback and fallback:IsA("BasePart") and not seen[fallback] then
		seen[fallback] = true
		table.insert(candidates, fallback)
	end
	local character = player.Character
	local rootPart = character and character:FindFirstChild("HumanoidRootPart")
	local now = os.clock()
	local cooldown = tonumber(Entrance.portalFailureCooldown) or 1

	-- table.sort demands a strict weak ordering, and the previous comparator broke
	-- it two different ways.
	--
	-- 1. `recentPortalFailures[door] and <compare>` evaluates to nil for a door that
	--    never failed and to false for one whose cooldown has expired. nil ~= false,
	--    so those two doors each sorted strictly before the other and Luau raised
	--    "invalid order function for sorting". That is the crash that killed the
	--    route on 11540209823 once some doors had been tried and aged out while
	--    others were still untried.
	-- 2. An epsilon tie-break (|a - b| > 0.01) is not transitive: a ties b and b
	--    ties c while a and c compare strictly. Quantise onto one integer grid and
	--    compare exactly instead.
	--
	-- Ranks are also precomputed, so a character that walks mid-sort cannot change
	-- a key underneath table.sort and reintroduce an inconsistent ordering.
	--
	-- Failure count leads the ordering because a wall-clock cooldown cannot work
	-- here: one attempt waits up to occupiedPortalWaitTimeout (20s) for MapSelect,
	-- four times portalFailureCooldown (5s), so a rejected door was always cool
	-- again by the next attempt and got picked repeatedly. Ordering by how often a
	-- door has been refused makes "try a different one" true regardless of timing.
	local rank = {}
	for _, door in ipairs(candidates) do
		local failedAt = recentPortalFailures[door]
		local position = door.Position
		rank[door] = {
			failures = portalFailureCounts[door] or 0,
			cooling = (failedAt ~= nil and now - failedAt < cooldown) and 1 or 0,
			distance = rootPart
				and math.floor((rootPart.Position - position).Magnitude * 100 + 0.5)
				or 0,
			-- Position is stable and executor-safe; GetDebugId can require elevated
			-- identity on some builds and must not be part of the routing path.
			x = math.floor(position.X * 100 + 0.5),
			z = math.floor(position.Z * 100 + 0.5),
		}
	end
	table.sort(candidates, function(left, right)
		local a, b = rank[left], rank[right]
		if a.failures ~= b.failures then return a.failures < b.failures end
		if a.cooling ~= b.cooling then return a.cooling < b.cooling end
		if a.distance ~= b.distance then return a.distance < b.distance end
		if a.x ~= b.x then return a.x < b.x end
		return a.z < b.z
	end)
	return candidates
end

local function resolvePortal()
	return resolvePortalCandidates()[1]
end

local function modelCenter(container)
	if not container then return nil end
	if container:IsA("Model") then
		local ok, cframe = pcall(function() return select(1, container:GetBoundingBox()) end)
		if ok and typeof(cframe) == "CFrame" then return cframe.Position end
	end
	local total, count = Vector3.zero, 0
	for _, child in ipairs(container:GetDescendants()) do
		if child:IsA("BasePart") then
			total = total + child.Position
			count = count + 1
		end
	end
	return count > 0 and (total / count) or nil
end

-- Called once MapSelect has arrived, by either entry route. MapSelect alone only
-- proves the server noticed an entry: the Pod is ours only if the server's own
-- occupancy snapshot names this player and shows nobody else holding it.
local function confirmPodEntry(portal, beforeOccupancy)
	-- UpdatePlayersInside normally arrives just before MapSelect, but do not
	-- depend on network callback ordering. Give the matching local-player Pod
	-- snapshot one short bounded window before deciding whether it is reserved.
	if not (bus.playersInsideGeneration > beforeOccupancy
		and bus.lastOccupancySubject == player) then
		waitUntil(function()
			return bus.playersInsideGeneration > beforeOccupancy
				and bus.lastOccupancySubject == player
		end, 0.5)
	end
	local matchingOccupancy = bus.playersInsideGeneration > beforeOccupancy
		and bus.lastOccupancySubject == player
	if matchingOccupancy and (bus.portalOccupiedByOther or bus.portalReservedByOther) then
		local leader = bus.lastPortalPartyLeader
		return false, "Story Pod is occupied/reserved by another player"
			.. (leader and (" (" .. leader.Name .. ")") or ""), portal
	end
	return true, nil, portal
end

-- The DoorUIPart carries a TouchInterest, so the server learns that a player
-- entered from a replicated Touched event rather than from where the character
-- actually is. firetouchinterest raises exactly that event.
--
-- Measured, not assumed: PodEntryBypassProbe fired this once against the nearest
-- door while the character stood 180 studs away and never moved. The server
-- answered MapSelect and UpdatePlayersInside naming this player, and then
-- accepted StartSelection. First attempt, no walking, no CFrame write.
--
-- This is what unblocks fresh accounts. They failed the walk on all 8 doors on
-- every recorded run and had never once entered a stage.
local function fireDoorTouch(portal, root)
	if Settings.useTouchInterestEntry == false then return false end
	if typeof(firetouchinterest) ~= "function" then return false end
	return (pcall(function()
		firetouchinterest(root, portal, 0)
		task.wait(math.max(0, tonumber(Entrance.touchHoldDelay) or 0.15))
		firetouchinterest(root, portal, 1)
	end))
end

local function tryEnterStoryPortal(portal, deadline)
	-- CharacterAdded:Wait() has no timeout. A respawn on a loaded host can lag for
	-- many seconds, and if the character never arrives at all this parks the whole
	-- route forever with the account standing still and nothing in the log to say
	-- why. Every other wait on this path is bounded; so is this one.
	local character = player.Character
	if not character then
		waitUntil(function() return player.Character ~= nil end,
			tonumber(Entrance.characterWaitTimeout) or 10)
		character = player.Character
	end
	if not character then return false, "character did not spawn within the entry window", portal end
	local root = character:FindFirstChild("HumanoidRootPart")
	local humanoid = character:FindFirstChildOfClass("Humanoid")
	if not root or not humanoid then return false, "character root/humanoid missing", portal end
	if not portal or not portal.Parent or not portal.CanTouch then
		return false, "Story DoorUIPart is unavailable or cannot touch", portal
	end

	local before = bus.mapSelectGeneration
	local beforeOccupancy = bus.playersInsideGeneration

	-- Touch route first: no CFrame write, no pathing, no walk budget. The proof is
	-- unchanged -- the server's own MapSelect still has to arrive.
	if fireDoorTouch(portal, root) then
		local touchTimeout = math.max(0.1, tonumber(Entrance.touchEntryTimeout) or 2)
		if waitUntil(function() return bus.mapSelectGeneration > before end, touchTimeout) then
			log("PORTAL_TOUCH", "Server accepted a fired door touch; the character never moved.", {
				portal = portalKey(portal),
			})
			return confirmPodEntry(portal, beforeOccupancy)
		end
	end

	-- Executors without firetouchinterest, and any build where the server stops
	-- trusting a replicated touch, still walk in the original way.
	local pod = portal.Parent
	local insideCenter = modelCenter(pod and pod:FindFirstChild("InsideModel"))
	local flat = insideCenter and Vector3.new(
		insideCenter.X - portal.Position.X,
		0,
		insideCenter.Z - portal.Position.Z
	) or Vector3.zero
	if flat.Magnitude < 0.1 then
		local look = portal.CFrame.LookVector
		flat = Vector3.new(look.X, 0, look.Z)
	end
	if flat.Magnitude < 0.1 then return false, "portal direction could not be derived", portal end
	local direction = flat.Unit
	local outside = portal.Position - direction * (tonumber(Entrance.outsideDistance) or 10)
	local inside = portal.Position + direction * (tonumber(Entrance.insideDistance) or 6)
	local y = portal.Position.Y
	outside = Vector3.new(outside.X, y, outside.Z)
	inside = Vector3.new(inside.X, y, inside.Z)

	root.CFrame = CFrame.lookAt(outside, inside)
	task.wait(tonumber(Entrance.teleportSettleDelay) or 0.2)
	local attemptDeadline = math.min(deadline, os.clock() + (tonumber(Entrance.walkTimeout) or 3))
	repeat
		humanoid:MoveTo(inside)
		if waitUntil(function()
			return bus.mapSelectGeneration > before
		end, math.min(0.35, math.max(0, attemptDeadline - os.clock()))) then
			return confirmPodEntry(portal, beforeOccupancy)
		end
	until not controller.active or os.clock() >= attemptDeadline
	return false, "server did not emit MapSelect for this Story Pod", portal
end

-- Select one physically empty sibling Pod before moving. A single call performs
-- at most one teleport/approach; it never bounces through candidates to probe
-- them. A coordinate is not success: the server still has to emit MapSelect.
local function enterStoryPortal()
	local deadline = os.clock() + (tonumber(Entrance.occupiedPortalWaitTimeout) or 20)
	local lastError = "Story DoorUIPart was not found"
	local attemptedPortal
	repeat
		local portalCandidates = resolvePortalCandidates()
		-- Zero candidates used to return immediately. That is wrong on a loaded host:
		-- the lobby's MapSelectors branch has simply not replicated yet during the
		-- first seconds after a join, so the bail consumed every transition attempt
		-- AND every route restart before the Pods ever existed -- leaving the account
		-- standing in the lobby with a dead route. This loop already owns a deadline
		-- (occupiedPortalWaitTimeout); an absent Pod is no more fatal than a busy one,
		-- so wait for replication inside that same budget instead of giving up.
		if #portalCandidates == 0 then
			lastError = "Story Pod hierarchy has not replicated yet"
		end
		for index = 1, #portalCandidates do
			local portal = portalCandidates[index]
			local failedAt = recentPortalFailures[portal]
			local cooling = failedAt ~= nil
				and os.clock() - failedAt < (tonumber(Entrance.portalFailureCooldown) or 1)
			local occupied, occupant = portalHasOtherPlayer(portal)
			if not cooling and not occupied then
				attemptedPortal = portal
				break
			elseif occupied then
				lastError = "Story Pod is physically occupied by " .. tostring(occupant and occupant.Name or "another player")
			end
		end
		if not attemptedPortal and os.clock() < deadline then
			task.wait(tonumber(Entrance.occupancyPollInterval) or 0.5)
		end
	until attemptedPortal or not controller.active or os.clock() >= deadline
	if not attemptedPortal then return false, lastError end

	-- Recheck immediately before moving to close the race where another player
	-- enters after candidate selection but before our character is repositioned.
	local occupied, occupant = portalHasOtherPlayer(attemptedPortal)
	if occupied then
		return false, "Story Pod became occupied by " .. tostring(occupant and occupant.Name or "another player"), attemptedPortal
	end
	local entered, entryError = tryEnterStoryPortal(attemptedPortal, deadline)
	if entered then return true, nil, attemptedPortal end
	recentPortalFailures[attemptedPortal] = os.clock()
	portalFailureCounts[attemptedPortal] = (portalFailureCounts[attemptedPortal] or 0) + 1
	lastError = entryError or lastError
	log("PORTAL_CANDIDATE", "Selected Story Pod rejected; the next bounded route attempt will use another door.", {
		portal = attemptedPortal,
		error = lastError,
	})
	return false, lastError, attemptedPortal
end

local function chooseLobbyTarget()
	local data, source, level, exp, levelSource = waitForLobbyRuntime()
	if not data then fail("PLAYER_DATA", "Main was stopped while waiting for lobby PlayerData.") end
	local story = rawget(data, "StoryProgress")
	local westCity = typeof(story) == "table" and rawget(story, tostring(Route.world or "WestCity")) or nil

	local firstAct = math.floor(tonumber(Route.firstNormalAct) or 1)
	local lastAct = math.floor(tonumber(Route.lastNormalAct) or 6)
	local clears = {}
	for act = firstAct, lastAct do
		local record = typeof(westCity) == "table"
			and (rawget(westCity, tostring(act)) or rawget(westCity, act)) or nil
		local normalClears = typeof(record) == "table" and tonumber(rawget(record, "Clears")) or 0
		local hardClears = typeof(record) == "table" and tonumber(rawget(record, "HardClears")) or 0
		clears[tostring(act)] = { normal = normalClears, hard = hardClears }
		if normalClears <= 0 then
			return {
				mode = tostring(Route.storyMode or "Story"),
				world = tostring(Route.world or "WestCity"),
				act = tostring(act),
				difficulty = tostring(Route.normalDifficulty or "Normal"),
				reason = "first uncleared Normal act",
				level = level,
				exp = exp,
				clears = clears,
				source = source .. " + " .. tostring(levelSource),
			}
		end
	end

	if level < (tonumber(Route.minimumInfiniteLevel) or 15) then
		return {
			mode = tostring(Route.storyMode or "Story"),
			world = tostring(Route.world or "WestCity"),
			act = tostring(Route.levelFarmAct or "1"),
			difficulty = tostring(Route.hardDifficulty or "Hard"),
			reason = "Normal 1-6 complete; account level below Infinite gate",
			level = level,
			exp = exp,
			clears = clears,
			source = source .. " + " .. tostring(levelSource),
		}
	end

	return {
		mode = tostring(Route.storyMode or "Story"),
		world = tostring(Route.world or "WestCity"),
		act = tostring(Route.infiniteAct or "Infinite"),
		difficulty = tostring(Route.hardDifficulty or "Hard"),
		reason = "Normal 1-6 complete and account level reached Infinite gate",
		level = level,
		exp = exp,
		clears = clears,
		source = source .. " + " .. tostring(levelSource),
	}
end

local function publishTarget(target)
	state.target = {
		mode = target.mode,
		world = target.world,
		act = target.act,
		difficulty = target.difficulty,
	}
	state.routeActive = true
	state.selectedFromJobId = game.JobId
	state.selectionStartedAt = os.time()
	Config.fastGems.stage.mode = target.mode
	Config.fastGems.stage.world = target.world
	Config.fastGems.stage.act = target.act
	Config.fastGems.stage.difficulty = target.difficulty
	report.decision = serializable(target)
	saveState("route decision persisted before lobby actions")
end

local function startSelectedStage(target)
	if not waitUntil(function()
		tryBindRemotes()
		return mapRemote ~= nil
	end, tonumber(Settings.runtimeLoadTimeout) or 20) then
		fail("REMOTE", "MapSelectRemote did not replicate in the lobby.")
	end
	local action = recordAction("SELECT_STAGE", target)
	local maximumAttempts = math.max(1, tonumber(Settings.maximumTransitionAttempts) or 2)

	-- Ask the server to select the stage and report whether it accepted. This is the
	-- same remote and the same acceptance proof the physical route uses: a matching
	-- AfterMapSelect. Nothing about verification is relaxed by calling it directly.
	local function requestSelection(timeout)
		local beforeSelection = bus.afterMapSelectGeneration
		mapRemote:FireServer("StartSelection", target.mode, target.world, tostring(target.act), target.difficulty)
		return waitUntil(function()
			return bus.afterMapSelectGeneration > beforeSelection
				and targetMatches(bus.afterMapSelect, target)
		end, timeout or verifyTimeout)
	end

	-- Selection is accepted; ask for the teleport and require TeleportGui as proof.
	local function completeTeleport(via, attempt)
		action.selectionVerified = true
		action.selectionVia = via
		action.selectionAttempt = attempt
		saveReport("selection verified")

		local beforeTeleport = bus.teleportGeneration
		local teleportAction = recordAction("START_TELEPORT", target)
		mapRemote:FireServer("StartTeleport")
		local teleported = waitUntil(function() return bus.teleportGeneration > beforeTeleport end, verifyTimeout)
		teleportAction.verified = teleported
		action.verified = teleported
		if not teleported then
			log("VERIFY", "StartTeleport was not confirmed; no blind success recorded.",
				{ attempt = attempt, via = via })
			return false
		end
		state.lastTransition = "START_TELEPORT"
		state.lastTransitionVerifiedAt = os.time()
		saveState("server accepted stage teleport")
		report.status = "TELEPORTING_TO_STAGE"
		saveReport("stage teleport verified")
		return true
	end

	-- Walking into a Pod is only how the game's own UI opens the map screen; the
	-- selection itself is this remote. Asking directly costs one bounded wait and
	-- takes character spawn, CFrame writes, humanoid pathing, the 3s walk budget and
	-- server-side touch detection off the happy path entirely.
	--
	-- The captured run makes the case: every account with zero clears failed the walk
	-- on all 24 attempts and never emitted a single MapSelect, while 11540208855 --
	-- same build, same executor, same session -- played Infinite to Wave 6. The walk
	-- is not a dependable gate for a fresh account, and today it is a hard gate: when
	-- it fails, StartSelection is never even attempted, so the server is never asked.
	local directTimeout = tonumber(Settings.directSelectionTimeout) or 5
	if Settings.preferDirectSelection ~= false then
		if requestSelection(directTimeout) then
			log("SELECT", "Server accepted the stage selection without a Pod walk.", { target = target })
			if completeTeleport("direct", 0) then return true end
		else
			log("SELECT", "Server did not accept a direct selection; falling back to the Pod walk.",
				{ waited = directTimeout })
		end
	end

	for attempt = 1, maximumAttempts do
		local entered, entryError, selectedPortal = enterStoryPortal()
		log("PORTAL", entered and "Story portal entry evidence observed." or "No available Story Pod accepted the player.", {
			attempt = attempt,
			error = entryError,
			portal = selectedPortal,
			-- Sibling Pods share a name, so GetFullName cannot tell them apart. The
			-- position can, which is the only way to see whether rotation is working.
			portalPosition = selectedPortal and portalKey(selectedPortal) or nil,
			candidates = #resolvePortalCandidates(),
		})
		if entered then
			if requestSelection() then
				if completeTeleport("pod-walk", attempt) then return true end
			else
				if selectedPortal then
					recentPortalFailures[selectedPortal] = os.clock()
					portalFailureCounts[selectedPortal] = (portalFailureCounts[selectedPortal] or 0) + 1
				end
				log("VERIFY", "StartSelection was not confirmed by matching AfterMapSelect.", { attempt = attempt })
			end
		end
		if attempt < maximumAttempts then
			task.wait(tonumber(Settings.transitionRetryDelay) or 1)
		end
	end

	-- Account state can change while the walk is being retried -- the captured run
	-- shows EquipStarterSelected arriving mid-sequence -- so ask once more before
	-- giving up rather than burning a whole supervised restart.
	if Settings.preferDirectSelection ~= false and requestSelection(directTimeout) then
		log("SELECT", "Server accepted a direct selection after the Pod walks failed.", { target = target })
		if completeTeleport("direct-retry", maximumAttempts) then return true end
	end
	return false
end

-- Stage selection is server-rejected when no unit is equipped. Preserve every
-- non-empty user/AutoPlay loadout; only a completely empty EquippedTowers table
-- receives one deterministic Inventory UUID, verified through live PlayerData.
local function ensureLobbyLoadout()
	local guard = Settings.lobbyLoadoutGuard
	if typeof(guard) ~= "table" or guard.enabled ~= true then
		log("LOADOUT", "Lobby loadout guard is disabled in Config.")
		return true
	end

	local function readLoadoutEvidence()
		local data = select(1, resolveLobbyRuntime(true))
		if typeof(data) ~= "table" then return nil, nil, nil end
		local equipped = rawget(data, "EquippedTowers")
		local inventory = rawget(data, "Inventory")
		local towers = typeof(inventory) == "table" and rawget(inventory, "Towers") or nil
		if typeof(equipped) ~= "table" or typeof(towers) ~= "table" then return nil, nil, nil end

		local equippedUUIDs = {}
		for slot, uuid in next, equipped do
			if typeof(uuid) == "string" and uuid ~= "" then
				equippedUUIDs[tostring(slot)] = uuid
			end
		end
		return equippedUUIDs, towers, data
	end

	local equipped, towers
	local runtimeReady = waitUntil(function()
		equipped, towers = readLoadoutEvidence()
		return equipped ~= nil and towers ~= nil
	end, tonumber(Settings.runtimeLoadTimeout) or 20)
	if not runtimeReady then
		fail("LOBBY_LOADOUT", "PlayerData.EquippedTowers/Inventory.Towers did not settle before stage selection.")
	end
	if next(equipped) ~= nil then
		log("LOADOUT", "At least one equipped UUID is already verified; fallback equip skipped.", equipped)
		return true
	end

	local candidates = {}
	for uuid, record in next, towers do
		if typeof(uuid) == "string" and uuid ~= "" and typeof(record) == "table" then
			table.insert(candidates, {
				uuid = uuid,
				identifier = tostring(rawget(record, "Name") or "Unknown"),
			})
		end
	end
	table.sort(candidates, function(left, right) return left.uuid < right.uuid end)
	if #candidates == 0 then
		fail("LOBBY_LOADOUT", "Inventory contains no unit UUID that can be equipped.")
	end

	local inventoryRemote
	local remoteReady = waitUntil(function()
		local remotes = ReplicatedStorage:FindFirstChild("Remotes")
		local inventoryRemotes = remotes and remotes:FindFirstChild("InventoryRemotes")
		local candidate = inventoryRemotes and inventoryRemotes:FindFirstChild("InventoryRemote")
		if candidate and candidate:IsA("RemoteEvent") then inventoryRemote = candidate end
		return inventoryRemote ~= nil
	end, tonumber(Settings.runtimeLoadTimeout) or 20)
	if not remoteReady then fail("LOBBY_LOADOUT", "InventoryRemote did not replicate in the lobby.") end

	local maximum = math.min(#candidates, math.max(1, tonumber(guard.maximumCandidates) or 10))
	local equipTimeout = math.max(1, tonumber(guard.equipVerifyTimeout) or 5)
	for index = 1, maximum do
		local candidate = candidates[index]
		local action = recordAction("LOBBY_EQUIP_FALLBACK", candidate)
		inventoryRemote:FireServer("EquipTower", candidate.uuid)
		local verified = waitUntil(function()
			local current = readLoadoutEvidence()
			return typeof(current) == "table" and next(current) ~= nil
		end, equipTimeout)
		action.verified = verified
		if verified then
			local finalEquipped = readLoadoutEvidence()
			action.after = serializable(finalEquipped)
			log("LOADOUT", "Fallback unit was confirmed before stage selection.", action)
			saveReport("lobby fallback loadout verified")
			return true
		end
		log("LOADOUT_RETRY", "Fallback UUID was not confirmed; trying the next owned unit.", candidate)
	end

	fail("LOBBY_LOADOUT", "No fallback Inventory UUID was accepted by the server.")
end

local function runLobby()
	report.context = "LOBBY"
	report.status = "DECIDING_ROUTE"
	local target = chooseLobbyTarget()
	log("DECISION", string.format("%s / %s / %s / %s: %s",
		target.mode, target.world, target.act, target.difficulty, target.reason), target)
	publishTarget(target)
	if Settings.dryRun == true then
		report.status = "DRY_RUN_COMPLETE"
		saveReport("lobby dry run")
		return
	end
	ensureLobbyLoadout()
	report.status = "ENTERING_STAGE"
	if not startSelectedStage(target) then
		fail("START_STAGE", "Server did not confirm selection and teleport within bounded attempts.")
	end
end

local function currentTarget()
	return bus.currentStage or (state.routeActive and state.target or nil)
end

local function returnToLobby(reason)
	if not waitUntil(function()
		tryBindRemotes()
		return genericRemote ~= nil
	end, tonumber(Settings.runtimeLoadTimeout) or 20) then
		fail("REMOTE", "RemoteEvent did not replicate before Return To Lobby.")
	end
	local action = recordAction("RETURN_TO_LOBBY", { reason = reason })
	for attempt = 1, math.max(1, tonumber(Settings.maximumTransitionAttempts) or 2) do
		local before = bus.teleportGeneration
		genericRemote:FireServer("TeleportToLobby")
		if waitUntil(function() return bus.teleportGeneration > before end, verifyTimeout) then
			action.verified = true
			action.attempt = attempt
			state.lastTransition = "TELEPORT_TO_LOBBY"
			state.lastTransitionVerifiedAt = os.time()
			saveState("server accepted Return To Lobby")
			report.status = "TELEPORTING_TO_LOBBY"
			saveReport("return lobby verified")
			return true
		end
		log("VERIFY", "TeleportToLobby was not confirmed on this attempt.", { attempt = attempt })
		if attempt < (tonumber(Settings.maximumTransitionAttempts) or 2) then
			task.wait(tonumber(Settings.transitionRetryDelay) or 1)
		end
	end
	return false
end

-- ReplayActVote/NextActVote may be toggle-like votes. Send exactly once, then
-- wait for a new UpdateClientGame or StartWaveVote; never fire twice blindly.
local function voteForTransition(remoteAction, expectedTarget)
	if not waitUntil(function()
		tryBindRemotes()
		return actRemote ~= nil
	end, tonumber(Settings.runtimeLoadTimeout) or 20) then
		fail("REMOTE", "ActRemoteEvent did not replicate before " .. tostring(remoteAction) .. ".")
	end
	local action = recordAction(remoteAction, expectedTarget)
	local beforeUpdate = bus.updateClientGeneration
	local beforeVote = bus.startVoteGeneration
	actRemote:FireServer(remoteAction)
	local verified = waitUntil(function()
		if bus.updateClientGeneration > beforeUpdate then
			return expectedTarget == nil or targetMatches(bus.currentStage, expectedTarget)
		end
		return bus.startVoteGeneration > beforeVote
	end, verifyTimeout)
	action.verified = verified
	if verified then
		state.lastTransition = remoteAction
		state.lastTransitionVerifiedAt = os.time()
		if expectedTarget then state.target = expectedTarget end
		saveState("server accepted " .. remoteAction)
	end
	saveReport(remoteAction .. (verified and " verified" or " unverified"))
	return verified
end

local handlingEnd = false
local restartPending = false
local restartAccepted = false

local function handleActOver(result)
	if handlingEnd or not controller.active then return end
	if restartPending then
		log("END", "ActOver arrived during an intentional Infinite restart; waiting for the new match lifecycle.", result)
		return
	end
	handlingEnd = true
	local ok, errorMessage = xpcall(function()
		local target = targetFromPayload(result) or currentTarget()
		local success = rawget(result, "Success") == true
		local canReplay = rawget(result, "CanPlayReplay") == true
		local canNext = rawget(result, "CanPlayNext") == true
		state.lastResult = {
			target = serializable(target),
			success = success,
			canReplay = canReplay,
			canNext = canNext,
			wavesCompleted = typeof(rawget(result, "PlayerStats")) == "table"
				and tonumber(rawget(rawget(result, "PlayerStats"), "WavesCompleted")) or nil,
		}
		saveState("ActOver received")
		log("END", success and "Match ended in victory." or "Match ended in defeat.", state.lastResult)

		if isInfiniteTarget(target) then
			if canReplay and voteForTransition("ReplayActVote", target) then return end
			if not returnToLobby("Infinite ended before the Wave restart transition") then
				fail("END_ACTION", "Infinite ended and neither Replay nor Return Lobby was verified.")
			end
			return
		end

		local actNumber = target and tonumber(target.act) or nil
		local isNormal = target and normalize(target.difficulty) == normalize(Route.normalDifficulty)
		local isHard = target and normalize(target.difficulty) == normalize(Route.hardDifficulty)

		if isNormal and actNumber and actNumber >= tonumber(Route.firstNormalAct or 1)
			and actNumber <= tonumber(Route.lastNormalAct or 6) then
			if success and actNumber < tonumber(Route.lastNormalAct or 6)
				and Route.useNextWhenAvailable == true and canNext then
				local nextTarget = {
					mode = tostring(Route.storyMode or "Story"),
					world = tostring(Route.world or "WestCity"),
					act = tostring(actNumber + 1),
					difficulty = tostring(Route.normalDifficulty or "Normal"),
				}
				state.target = nextTarget
				saveState("next Normal target persisted before vote")
				if voteForTransition("NextActVote", nextTarget) then return end
				log("RECOVERY", "Next vote was not verified; returning to lobby for a fresh clear-history decision.")
			elseif not success and canReplay then
				if voteForTransition("ReplayActVote", target) then return end
				log("RECOVERY", "Replay vote was not verified; returning to lobby.")
			end
			if not returnToLobby(success and "Normal route boundary reached" or "Normal retry unavailable") then
				fail("END_ACTION", "Normal end action was not verified.")
			end
			return
		end

		if isHard and actNumber == tonumber(Route.levelFarmAct or 1) then
			-- PlayerData.Exp settled immediately after ActOver in the live capture, but
			-- allow a short bounded window before applying the level threshold.
			task.wait(math.max(0.5, pollInterval * 3))
			local level, exp = readAccountLevel()
			log("LEVEL", "Level-farm result evaluated.", { level = level, exp = exp })
			if level and level >= (tonumber(Route.minimumInfiniteLevel) or 15) then
				if not returnToLobby("account reached Infinite level gate") then
					fail("END_ACTION", "Level gate reached but Return Lobby was not verified.")
				end
				return
			end
			if canReplay and voteForTransition("ReplayActVote", target) then return end
			if not returnToLobby("Hard level-farm replay unavailable") then
				fail("END_ACTION", "Hard level-farm transition was not verified.")
			end
			return
		end

		if not returnToLobby("unexpected stage identity; re-plan safely in lobby") then
			fail("END_ACTION", "Unexpected stage could not return to lobby.")
		end
	end, function(message)
		return debug and debug.traceback and debug.traceback(tostring(message), 2) or tostring(message)
	end)
	handlingEnd = false
	if not ok then
		report.status = "FAILED"
		report.error = errorMessage
		log("FATAL", "End-match handler failed.", { trace = errorMessage })
		-- Stop every listener after an unhandled transition error. Leaving them armed
		-- could send a later Replay/Restart action from a known-bad controller state.
		controller.active = false
		disconnectAll()
	end
end

local function handleWave(wave)
	if restartPending or not controller.active then return end
	local target = currentTarget()
	local restartWave = tonumber(Route.restartInfiniteAtWave) or 20
	if not isInfiniteTarget(target) or wave ~= restartWave then return end
	if not genericRemote then
		fail("REMOTE", "RemoteEvent is unavailable at Infinite Wave " .. tostring(wave) .. ".")
	end

	restartPending = true
	-- Infinite has no reliable empty-enemy interval. The server's numbered Wave
	-- notification is therefore the exact trigger; restart once and verify the new
	-- lifecycle without waiting on workspace.Enemies or touching game-owned UI.
	local action = recordAction("RESTART_GAME", { wave = wave, target = target })
	local beforeUpdate = bus.updateClientGeneration
	local beforeVote = bus.startVoteGeneration
	local runtime = resolveMatchRuntime()
	local wasStarted = runtime and rawget(runtime, "GameStarted") == true
	genericRemote:FireServer("RestartGame")

	-- Acceptance is proven by a new client-game payload, a new ready vote, or the
	-- current MatchRuntime leaving its started state. Wave 1 later opens a new epoch.
	local accepted = waitUntil(function()
		if bus.updateClientGeneration > beforeUpdate or bus.startVoteGeneration > beforeVote then return true end
		local current = resolveMatchRuntime()
		return wasStarted and current and rawget(current, "GameStarted") == false
	end, verifyTimeout)
	action.verified = accepted
	restartAccepted = accepted
	state.lastInfiniteRestart = {
		wave = wave,
		accepted = accepted,
		requestedAt = os.time(),
	}
	if accepted then
		state.matchEpoch = (tonumber(state.matchEpoch) or 0) + 1
		state.lastTransition = "RestartGame"
		state.lastTransitionVerifiedAt = os.time()
		log("VERIFY", "RestartGame was accepted at the configured Infinite wave.", state.lastInfiniteRestart)
	else
		-- The exact-wave notification fires once, so clearing pending cannot duplicate
		-- this request. It does allow a later ActOver to take Replay/Return-Lobby
		-- recovery; the former permanent pending flag stranded an Infinite end screen.
		restartPending = false
		restartAccepted = false
		log("VERIFY", "RestartGame was not confirmed; end-match recovery remains armed.", state.lastInfiniteRestart)
	end
	saveState("Infinite Wave restart evaluated")
end

local function runStage()
	report.context = "STAGE"
	report.status = "MONITORING_STAGE"
	local remotesReady = waitUntil(function()
		tryBindRemotes()
		return actRemote ~= nil and genericRemote ~= nil and notificationRemote ~= nil
	end, tonumber(Settings.runtimeLoadTimeout) or 20)
	if not remotesReady then
		fail("REMOTE", "Stage lifecycle remotes did not all replicate before the timeout.")
	end
	local runtime, source = resolveMatchRuntime()
	report.matchRuntimeSource = source
	log("CONTEXT", "Stage monitor armed.", {
		matchRuntimeSource = source,
		persistedTarget = state.routeActive and state.target or nil,
	})

	controller.onActOver = handleActOver
	controller.onWave = function(wave)
		if restartPending and restartAccepted and wave <= 1 then
			restartPending = false
			restartAccepted = false
			log("EPOCH", "Infinite restart reached a fresh Wave 1; the next configured restart wave is armed.", {
				matchEpoch = state.matchEpoch,
				restartWave = tonumber(Route.restartInfiniteAtWave) or 20,
			})
		end
		handleWave(wave)
	end

	-- This task intentionally stays armed across Replay/Next lifecycles. AutoPlay
	-- independently re-resolves MatchRuntime and handles team/combat state.
	--
	-- Only log() advances `sequence`, and the heartbeat below never logs, so a
	-- frozen sequence means the server replicated nothing at all: no wave, no act
	-- event, no verified action. Without this watchdog the loop kept writing
	-- heartbeats through a dead match and burned the rest of the session.
	local stallTimeout = math.max(0, tonumber(Settings.stageStallTimeout) or 180)
	local maximumRecoveries = math.max(0, tonumber(Settings.maximumStallRecoveries) or 3)
	local lastProgressAt = os.clock()
	local lastSequence = sequence
	local stallRecoveries = 0

	while controller.active do
		task.wait(1)
		report.currentStage = serializable(currentTarget())
		report.currentWave = bus.currentWave

		if sequence ~= lastSequence then
			lastSequence = sequence
			lastProgressAt = os.clock()
			report.stalled = nil
		end

		local quietFor = os.clock() - lastProgressAt
		if stallTimeout > 0 and quietFor >= stallTimeout then
			report.stalled = {
				quietSeconds = math.floor(quietFor),
				wave = bus.currentWave,
				matchEpoch = state.matchEpoch,
				recoveries = stallRecoveries,
			}
			log("STALL", string.format(
				"No replicated stage event for %ds; the match is not progressing.",
				math.floor(quietFor)), report.stalled)

			if stallRecoveries >= maximumRecoveries then
				report.status = "STALLED"
				log("STALL", "Stall recovery budget is exhausted; leaving a STALLED report for diagnosis.", {
					recoveries = stallRecoveries,
					maximumStallRecoveries = maximumRecoveries,
				})
				saveReport("stage stalled beyond recovery budget", true)
				return
			end

			stallRecoveries += 1
			-- returnToLobby() calls fail() when the remote never binds, and a stalled
			-- stage is exactly when that is most likely. Killing Main here would only
			-- trade a silent hang for a silent death, so recover instead of failing.
			local ok, recovered = pcall(returnToLobby,
				string.format("stage stalled for %ds", math.floor(quietFor)))
			if ok and recovered then
				log("STALL", "Stall recovered through the verified lobby return.", {
					recoveries = stallRecoveries,
				})
				return
			end
			log("STALL", "Stall recovery did not confirm a lobby return; re-arming the watchdog.", {
				recoveries = stallRecoveries,
				error = (not ok) and tostring(recovered) or nil,
			})
			-- The STALL lines above advanced `sequence` themselves; they are not progress.
			lastProgressAt = os.clock()
			lastSequence = sequence
		end

		saveReport("stage heartbeat")
	end
end

local function run()
	report.status = "WAITING_FOR_CONTEXT"
	local contextReady = waitUntil(function()
		tryBindRemotes()
		return resolvePortal() ~= nil
			or resolveMatchRuntime() ~= nil
			or Workspace:FindFirstChild("Towers") ~= nil
	end, tonumber(Settings.runtimeLoadTimeout) or 20)
	if not contextReady then fail("CONTEXT", "Neither lobby portal nor stage runtime loaded.") end

	-- The live Story DoorUIPart is the strongest lobby identity. Prefer it over a
	-- stale getgc MatchRuntime left behind by an earlier place lifecycle.
	if resolvePortal() then
		waitForBootstrapWorkers()
		runLobby()
	else
		runStage()
	end
end

-- The Loader starts each controller exactly once with task.spawn + pcall, so any
-- error inside the route used to end the whole session: main.lua raised FATAL and
-- nothing routed again until the account was rejoined. AutoPlay already runs under
-- a supervisor; this closes the same gap for the route that feeds it.
task.spawn(function()
	local function traceback(message)
		return debug and debug.traceback and debug.traceback(tostring(message), 2) or tostring(message)
	end
	local maximumRestarts = math.max(0, math.floor(tonumber(Settings.maximumRouteRestarts) or 3))
	local restartDelay = math.max(0, tonumber(Settings.routeRestartDelay) or 5)

	for attempt = 0, maximumRestarts do
		local ok, result = xpcall(run, traceback)
		if ok then
			if controller.active and report.context == "LOBBY"
				and report.status ~= "TELEPORTING_TO_STAGE" then
				report.status = "COMPLETE"
				saveReport("lobby run complete")
			end
			return
		end
		if not controller.active then return end
		-- A teleport already committed this place lifecycle. The Loader rebuilds every
		-- controller against the new runtime, so restarting here would race it.
		if report.status == "TELEPORTING_TO_STAGE" then return end

		report.error = result
		if attempt >= maximumRestarts then
			report.status = "FAILED"
			log("FATAL", "Main route stopped.", { trace = result, restarts = attempt })
			-- The report remains FAILED (not STOPPED) while all event listeners are
			-- disconnected so no partial controller continues acting in the background.
			controller.active = false
			disconnectAll()
			return
		end

		report.status = "RESTARTING"
		report.routeRestarts = attempt + 1
		log("SUPERVISOR", "Main route stopped on an error; restarting the route.", {
			attempt = attempt + 1,
			maximumRestarts = maximumRestarts,
			trace = result,
		})
		saveReport("supervised route restart")
		disconnectAll()
		task.wait(restartDelay)
	end
end)

if not consoleStatusOnly then print("[Main] controller started; report: " .. reportFile) end
return controller
