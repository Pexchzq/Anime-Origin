--[[
	Anime Origin - verified persistent unit progression

	Run Config.lua first, then run this file in the lobby. This controller:
	  1. Ranks unique damage units with the game's live CalculateStuff functions
	     at max upgrade, including level, Trait, Shiny, Stars, Grades and account
	     multipliers; DPS = Damage / Cooldown, then Range and UUID break ties.
	  2. Protects the six ranked targets and every configured/locked/equipped/Shiny
	     unit before constructing any fusion payload.
	  3. Balances ranks 1-3 by current EXP. Only after all three reach level 70
	     does it continue with ranks 4-6.
	  4. Fuses verified disposable UUIDs, buys live-rotation Gold Shop food, and
	     feeds explicit item counts. Every action waits for PlayerData evidence.

	Config.unitProgression.dryRun=true performs the complete read-only plan and
	writes the same report without invoking any remote.
]]

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local HttpService = game:GetService("HttpService")

local environment = getgenv()

-- Shared milestone trace. Resolved per call rather than captured at load time,
-- because Config publishes the tracer and Auto-Execute does not guarantee order.
local function trace(message, data)
	local tracer = environment.AnimeOriginTrace
	if typeof(tracer) == "function" then tracer("UnitProgress", message, data) end
	-- The same milestone, in structured form, into the folder capture. Feeding
	-- the recorder from the existing trace points means the whole milestone
	-- stream is captured without a second set of call sites to keep in sync.
	local diag = environment.AnimeOriginDiag
	if typeof(diag) == "table" and typeof(diag.mark) == "function" then
		diag.mark("UnitProgress", message, data)
	end
end

-- Diagnostics accessors. Resolved per call and always returning something callable,
-- so instrumentation can never become the reason a controller stops: a client whose
-- Diag.lua download failed runs exactly as before, minus the folder capture.
local INERT_STEP = {}
function INERT_STEP.ok() return INERT_STEP end
function INERT_STEP.noop() return INERT_STEP end
function INERT_STEP.fail() return INERT_STEP end
function INERT_STEP.note() return INERT_STEP end
function INERT_STEP.because() return INERT_STEP end
function INERT_STEP.extend() return INERT_STEP end

local function diagStep(name, opts)
	local diag = environment.AnimeOriginDiag
	if typeof(diag) ~= "table" or typeof(diag.step) ~= "function" then return INERT_STEP end
	opts = opts or {}
	-- Anchor here rather than inside Diag: one level up from this helper is the real
	-- call site, which is the line a capture has to name when it says where the bug is.
	if opts.where == nil and typeof(debug) == "table" and typeof(debug.info) == "function" then
		local ok, source, line = pcall(debug.info, 2, "sl")
		if ok and source then
			opts.where = (tostring(source):match("([^/\\]+)$") or tostring(source)) .. ":" .. tostring(line)
		end
	end
	return diag.step(name, opts)
end

-- MacSploit starts Auto-Execute files without a dependable inter-file order.
-- Wait for shared configuration and LocalPlayer so this worker can then wait on
-- FastMode through the lifecycle gate instead of dying before that gate exists.
local function waitForAnimeOriginConfig(timeout)
	local deadline = os.clock() + (tonumber(timeout) or 30)
	repeat
		local config = environment.AnimeOriginConfig
		if typeof(config) == "table" then return config end
		task.wait(0.05)
	until os.clock() >= deadline
	error("[UnitProgression][AUTO_EXECUTE] Timed out waiting for Config.lua.", 0)
end

local function waitForLocalPlayer(timeout)
	local deadline = os.clock() + (tonumber(timeout) or 30)
	repeat
		if Players.LocalPlayer then return Players.LocalPlayer end
		task.wait(0.05)
	until os.clock() >= deadline
	error("[UnitProgression][AUTO_EXECUTE] Timed out waiting for LocalPlayer.", 0)
end

local player = waitForLocalPlayer()
local Config = waitForAnimeOriginConfig()

local Settings = Config.unitProgression
assert(typeof(Settings) == "table", "Config.unitProgression is missing.")
assert(Settings.enabled == true, "Config.unitProgression.enabled is false.")
local consoleStatusOnly = typeof(Config.console) == "table"
	and Config.console.statusOnly == true
-- Scope duplicate protection to the current server. Executor globals may remain
-- alive briefly across teleports even though the old worker thread is gone.
local previousRun = environment.AnimeOriginUnitProgressionRunning
assert(not (typeof(previousRun) == "table" and previousRun.jobId == game.JobId),
	"UnitProgression is already running in this server.")
local runToken = { jobId = game.JobId, userId = player.UserId, startedAt = os.time() }
environment.AnimeOriginUnitProgressionRunning = runToken

-- Share only lifecycle status across controllers; the detailed progression report
-- remains in its own JSON file. main.lua uses this signal as a lobby routing gate.
local function publishLifecycle(status, details)
	local lifecycle = environment.AnimeOriginLifecycle
	if typeof(lifecycle) ~= "table" or lifecycle.jobId ~= game.JobId then
		lifecycle = { version = 1, jobId = game.JobId, createdAt = os.time(), tasks = {} }
		environment.AnimeOriginLifecycle = lifecycle
	end
	lifecycle.tasks = typeof(lifecycle.tasks) == "table" and lifecycle.tasks or {}
	lifecycle.tasks.UnitProgression = {
		status = status,
		updatedAt = os.time(),
		userId = player.UserId,
		details = details,
	}
	-- The cross-controller edge, recorded at the write. main.lua's bootstrap gate
	-- reads exactly this entry, and a worker that dies here without the gate noticing
	-- is the most expensive chain this project has: the account then stands in the
	-- lobby until the host is restarted by hand.
	local diag = environment.AnimeOriginDiag
	if typeof(diag) == "table" and typeof(diag.signal) == "function" then
		diag.signal("lifecycle.UnitProgression", status, details, "UnitProgression")
	end
end

-- Persistent inventory progression is lobby-only. A stage teleport starts a new
-- Auto-Execute lifecycle, but that lifecycle has no shop/inventory progression
-- authority and should not block or fail the match controller.
local lobbyPlaces = Config.runtimePlaces and Config.runtimePlaces.lobby
local isLobbyPlace = typeof(lobbyPlaces) == "table" and lobbyPlaces[game.PlaceId] == true
if not isLobbyPlace then
	local skipped = { status = "SKIPPED_STAGE", placeId = game.PlaceId, jobId = game.JobId }
	publishLifecycle("SKIPPED", { phase = "context", reason = "stage place" })
	trace("SKIPPED: stage place, lobby progression does not apply here")
	if environment.AnimeOriginUnitProgressionRunning == runToken then
		environment.AnimeOriginUnitProgressionRunning = nil
	end
	environment.AnimeOriginUnitProgressionReport = skipped
	if not consoleStatusOnly then
		print("[UnitProgression] Stage place detected; lobby progression skipped.")
	end
	return skipped
end

publishLifecycle("RUNNING", { phase = "startup" })
trace("start", { placeId = game.PlaceId, userId = player.UserId })

-- FastMode adds/removes inventory UUIDs while summoning and Auto Sell may remove
-- Rare copies. Wait before taking any inventory/stat snapshot so progression ranks
-- the final post-bootstrap inventory instead of a stale mid-summon team.
local function waitForFastModeDependency()
	if typeof(Config.fastGems) == "table" and Config.fastGems.enabled == false then return end
	local gate = Config.main and Config.main.bootstrapGate
	local timeout = (typeof(gate) == "table" and tonumber(gate.timeout)) or 300
	-- The middle link of the longest chain in the project: FastMode dies, this waits
	-- out the full bootstrap timeout, publishes FAILED, and main's gate then sees TWO
	-- dead workers -- of which only the first is a real fault. The because() edges
	-- below are what let a capture say that out loud instead of blaming both.
	local dependencyStep = diagStep("UnitProgression.waitForFastMode", {
		expect = "lifecycle.FastMode reaches COMPLETE",
		deadline = timeout + 15,
	})
	local deadline = os.clock() + timeout
	repeat
		local lifecycle = environment.AnimeOriginLifecycle
		local entry = typeof(lifecycle) == "table" and lifecycle.jobId == game.JobId
			and typeof(lifecycle.tasks) == "table" and lifecycle.tasks.FastMode or nil
		local status = typeof(entry) == "table" and tostring(entry.status) or "PENDING"
		if status == "COMPLETE" then
			dependencyStep.ok()
			return
		end
		if status == "FAILED" then
			dependencyStep.because("lifecycle.FastMode")
			dependencyStep.fail("FastMode reported FAILED, so progression never started")
			publishLifecycle("FAILED", { phase = "dependency", error = "FastMode failed" })
			error("[UnitProgression][DEPENDENCY] FastMode failed; inventory progression was not started.", 0)
		end
		task.wait(0.1)
	until os.clock() >= deadline
	dependencyStep.because("lifecycle.FastMode")
	dependencyStep.fail(string.format("FastMode never reached a terminal status within %ss", tostring(timeout)))
	publishLifecycle("FAILED", { phase = "dependency", error = "FastMode timeout" })
	error("[UnitProgression][DEPENDENCY] Timed out waiting for FastMode completion.", 0)
end

-- This wait is silent for up to the whole bootstrap timeout, so without these two
-- lines a capture cannot tell "blocked on FastMode" from "hung on its own".
trace("waiting for FastMode before snapshotting inventory")
waitForFastModeDependency()
trace("FastMode dependency satisfied")

local stateFolder = tostring(Settings.stateFolder or "AnimeOrigin")
local reportFile = stateFolder .. "/UnitProgression_" .. tostring(player.UserId) .. "_latest.json"
local logFile = stateFolder .. "/UnitProgression_" .. tostring(player.UserId) .. "_latest.log"
local pollInterval = tonumber(Settings.statePollInterval) or 0.2
local verifyTimeout = tonumber(Settings.verifyTimeout) or 8
local actionDelay = tonumber(Settings.actionDelay) or 0.35

local report = {
	-- Version 2 resolves FuseTowerExp from callback upvalues and shares the exact
	-- CalculateStuff stat formula with AutoPlay.
	version = 2,
	userId = player.UserId,
	placeId = game.PlaceId,
	jobId = game.JobId,
	dryRun = Settings.dryRun == true,
	status = "STARTING",
	actions = {},
	ranking = {},
	protected = {},
	plans = {},
	evidence = {},
}

local logBuffer = {}
-- Both bounds must stay in step with the identical block in main.lua, AutoPlay.lua,
-- FastMode.lua and InGameSettings.lua.
local maximumRetainedLogLines = math.max(50, tonumber(Settings.maximumRetainedLogLines) or 300)
local maximumLogBytes = math.max(65536, tonumber(Settings.maximumLogBytes) or 1048576)
local writtenLogBytes = 0
local sequence = 0

local function ensureFolder()
	if typeof(makefolder) == "function" and typeof(isfolder) == "function" and not isfolder(stateFolder) then
		makefolder(stateFolder)
	end
end

local function encode(value)
	local ok, result = pcall(HttpService.JSONEncode, HttpService, value)
	return ok and result or tostring(value)
end

local function log(stage, message, data, showConsole)
	sequence += 1
	local suffix = data ~= nil and (" | " .. encode(data)) or ""
	local line = string.format("[UnitProgression][%03d][%s] %s%s", sequence, stage, message, suffix)
	table.insert(logBuffer, line)
	-- appendfile already persists the history, so the Lua table is only a fallback
	-- ring. Without this bound every formatted diagnostic string is retained for the
	-- whole session, in every controller, in every client -- which is why RAM climbed
	-- steadily across a long multi-account run.
	if #logBuffer > maximumRetainedLogLines then table.remove(logBuffer, 1) end
	if showConsole ~= false and not consoleStatusOnly then print("[UnitProgression] " .. message) end
	if typeof(appendfile) == "function" then
		appendfile(logFile, line .. "\n")
		-- The file itself has no bound either. A session left running for hours
		-- produced logs too large to send. Restart the file from the retained tail
		-- once it passes the cap; recent history is what diagnosis actually uses.
		writtenLogBytes += #line + 1
		if writtenLogBytes >= maximumLogBytes and typeof(writefile) == "function" then
			pcall(writefile, logFile, table.concat(logBuffer, "\n") .. "\n")
			writtenLogBytes = 0
		end
	elseif typeof(writefile) == "function" then
		writefile(logFile, table.concat(logBuffer, "\n") .. "\n")
	end
end

local function saveReport(reason)
	report.reason = reason
	report.updatedAt = os.time()
	if typeof(writefile) == "function" then
		writefile(reportFile, HttpService:JSONEncode(report))
	end
end

local function fail(stage, message)
	report.status = "FAILED"
	report.failedStage = stage
	log("ERROR", stage .. ": " .. message)
	saveReport(stage .. ": " .. message)
	-- Initialization performs runtime discovery before the main xpcall. Publish a
	-- terminal signal here as well, otherwise Main can wait the full bootstrap
	-- timeout for a worker that already stopped before entering run().
	publishLifecycle("FAILED", { phase = stage, error = message, reportFile = reportFile })
	if environment.AnimeOriginUnitProgressionRunning == runToken then
		environment.AnimeOriginUnitProgressionRunning = nil
	end
	error(string.format("[UnitProgression][%s] %s", stage, message), 0)
end

-- `parent:WaitForChild(name)` with no timeout yields FOREVER. The remote lookups
-- below run at MODULE scope -- before run() and its xpcall exist -- so an infinite
-- yield there leaves this worker's lifecycle entry at RUNNING permanently. main
-- cannot tell that apart from "still working", so the account stands in the lobby
-- until the bootstrap gate runs out. Bound every lookup and route a missing remote
-- through fail(), which publishes the terminal signal main is waiting for.
local function requireChild(parent, name)
	local timeout = math.max(1, tonumber(Settings.remoteWaitTimeout) or 30)
	local child = parent:WaitForChild(name, timeout)
	if not child then
		fail("REMOTE", string.format("%s.%s did not replicate within %ss.",
			parent:GetFullName(), tostring(name), tostring(timeout)))
	end
	return child
end

local function waitFor(predicate, timeout)
	local deadline = os.clock() + (tonumber(timeout) or verifyTimeout)
	repeat
		local ok, value = pcall(predicate)
		if ok and value then return true, value end
		task.wait(pollInterval)
	until os.clock() >= deadline
	local ok, value = pcall(predicate)
	return ok and value ~= nil and value ~= false, value
end

ensureFolder()
if typeof(writefile) == "function" then writefile(logFile, "") end

if typeof(getgc) ~= "function" then fail("RUNTIME", "UnitProgression requires getgc(true).") end

-- Both predicates live here, above the snapshot acquisition, because the
-- acquisition has to test for exactly what the discovery below requires. When the
-- probe was a separate copy it drifted: it accepted a table carrying MaxTowerLevel
-- and GetTowerLevelFromExp but not NeededTowerLevelExp, declared the snapshot
-- usable on the first try, and then the real scan still failed with "Level formula
-- module was not found" -- with no rescan, because the probe had already said yes.
local function isPlayerData(value)
	if typeof(value) ~= "table" then return false end
	local inventory = rawget(value, "Inventory")
	return typeof(inventory) == "table"
		and typeof(rawget(inventory, "Towers")) == "table"
		and typeof(rawget(inventory, "Currency")) == "table"
		and typeof(rawget(value, "EquippedTowers")) == "table"
end

local function isLevelModule(value)
	if typeof(value) ~= "table" then return false end
	return typeof(rawget(value, "MaxTowerLevel")) == "number"
		and typeof(rawget(value, "GetTowerLevelFromExp")) == "function"
		and typeof(rawget(value, "NeededTowerLevelExp")) == "function"
end

-- The Loader starts this file the moment the place finishes teleporting, so the
-- very first getgc(true) routinely lands in a lobby whose modules have not been
-- created yet. Everything below reads that one snapshot and turns any miss into a
-- fatal error, which is why this worker reported "Level formula module was not
-- found" on four of four accounts while the same lobby served main.lua correctly
-- seconds later. Keep re-taking the snapshot until it is both plausibly sized and
-- actually carries what this file needs; a genuinely absent module still fails
-- below, but a merely late one no longer kills the worker for the session.
local function snapshotIsUsable(objects)
	if typeof(objects) ~= "table" then return false end
	if #objects < (tonumber(Settings.minimumGCSnapshotSize) or 1000) then return false end
	local hasLevelModule, hasPlayerData = false, false
	for _, object in ipairs(objects) do
		if typeof(object) == "table" then
			if not hasLevelModule and isLevelModule(object) then hasLevelModule = true end
			if not hasPlayerData
				and (isPlayerData(object) or isPlayerData(rawget(object, "PlayerData"))) then
				hasPlayerData = true
			end
			if hasLevelModule and hasPlayerData then return true end
		end
	end
	return false
end

local gcObjects
do
	local timeout = math.max(0, tonumber(Settings.runtimeLoadTimeout) or 60)
	local interval = math.max(0.1, tonumber(Settings.runtimeDiscoveryInterval) or 0.5)
	local deadline = os.clock() + timeout
	local attempts, usable = 0, false
	-- getgc(true) walks the entire Lua heap; measured snapshots here run from 41k to
	-- 404k objects. Retrying on a fixed interval meant up to 120 full walks per
	-- client, and the loop got *longer* exactly when the machine was busiest -- a
	-- loaded host makes the lobby modules appear later, which triggered more walks,
	-- which loaded the host further. Backing off reaches the same deadline in about
	-- a dozen walks instead, and eases off under pressure rather than piling on.
	local wait = interval
	repeat
		attempts += 1
		local ok, objects = pcall(getgc, true)
		if ok and typeof(objects) == "table" then
			-- Keep the newest snapshot either way: if the deadline expires we still
			-- want the best view available rather than no view at all.
			if typeof(gcObjects) == "table" and gcObjects ~= objects then table.clear(gcObjects) end
			gcObjects = objects
			usable = snapshotIsUsable(objects)
		end
		if usable then break end
		task.wait(math.min(wait, math.max(0, deadline - os.clock())))
		wait = math.min(wait * 1.5, 8)
	until os.clock() >= deadline
	if typeof(gcObjects) ~= "table" then fail("RUNTIME", "getgc(true) failed.") end
	if attempts > 1 then
		log("RUNTIME", usable
			and "Lobby definitions were absent from the first getgc snapshot; rescanned until they appeared."
			or "Lobby definitions never appeared within the load timeout; continuing on the last snapshot.", {
			attempts = attempts,
			objects = #gcObjects,
			usable = usable,
		})
	end
end

-- Keep the stable container instead of freezing the first direct PlayerData
-- table found in getgc. The server can replace container.PlayerData after a
-- purchase/fusion/feed; old direct tables remain in getgc and caused successful
-- shop requests to look unchanged forever.
local playerDataContainer
local playerDataSource
local directPlayerDataCandidate
local directPlayerDataSource
for index, object in ipairs(gcObjects) do
	if typeof(object) == "table" and isPlayerData(rawget(object, "PlayerData")) then
		playerDataContainer = object
		playerDataSource = "getgc[" .. index .. "].PlayerData"
		break
	elseif not directPlayerDataCandidate and isPlayerData(object) then
		directPlayerDataCandidate = object
		directPlayerDataSource = "getgc[" .. index .. "]"
	end
end
if not playerDataContainer and directPlayerDataCandidate then
	playerDataContainer = directPlayerDataCandidate
	playerDataSource = directPlayerDataSource
end
if not playerDataContainer then fail("RUNTIME", "Live PlayerData was not found. Wait for lobby loading.") end

local function currentPlayerData()
	local nested = typeof(playerDataContainer) == "table" and rawget(playerDataContainer, "PlayerData") or nil
	if isPlayerData(nested) then return nested end
	if isPlayerData(playerDataContainer) then return playerDataContainer end
	fail("RUNTIME", "The live PlayerData container no longer has a valid payload.")
end

-- A wrapper can appear after the initial getgc snapshot. One bounded rescan is
-- used only when post-action evidence stays unchanged; no remote is retried, so
-- a delayed successful purchase cannot be duplicated accidentally.
local function refreshPlayerDataContainer()
	local ok, objects = pcall(getgc, true)
	if not ok or typeof(objects) ~= "table" then return false end
	for index, object in ipairs(objects) do
		local nested = typeof(object) == "table" and rawget(object, "PlayerData") or nil
		if isPlayerData(nested) then
			playerDataContainer = object
			playerDataSource = "getgc[" .. index .. "].PlayerData"
			objects = nil
			return true
		end
	end
	objects = nil
	return false
end

local function inventory()
	local value = rawget(currentPlayerData(), "Inventory")
	if typeof(value) ~= "table" then fail("RUNTIME", "PlayerData.Inventory disappeared.") end
	return value
end

local function towers()
	local value = rawget(inventory(), "Towers")
	if typeof(value) ~= "table" then fail("RUNTIME", "PlayerData.Inventory.Towers disappeared.") end
	return value
end

local function foodInventory()
	local value = rawget(inventory(), "Food")
	return typeof(value) == "table" and value or {}
end

local function currency(name)
	local values = rawget(inventory(), "Currency")
	return typeof(values) == "table" and (tonumber(rawget(values, name)) or 0) or 0
end

local function equippedSet()
	local result = {}
	local equipped = rawget(currentPlayerData(), "EquippedTowers")
	if typeof(equipped) == "table" then
		for _, uuid in next, equipped do
			if typeof(uuid) == "string" then result[uuid] = true end
		end
	end
	return result
end

local function hasStageStats(value)
	return typeof(value) == "table" and typeof(rawget(value, "StageStats")) == "table"
end

-- Resolve only definitions for currently-owned identifiers. getgc indices drift,
-- so no index from the probe is reused here.
local function resolveDefinitions()
	local needed = {}
	for _, record in next, towers() do
		if typeof(record) == "table" and typeof(rawget(record, "Name")) == "string" then
			needed[rawget(record, "Name")] = true
		end
	end

	local definitions, sources = {}, {}
	for index, object in ipairs(gcObjects) do
		if typeof(object) == "table" then
			for identifier in pairs(needed) do
				if not definitions[identifier] then
					local candidate = rawget(object, identifier)
					if hasStageStats(candidate) then
						definitions[identifier] = candidate
						sources[identifier] = "getgc[" .. index .. "][" .. string.format("%q", identifier) .. "]"
					end
				end
			end
		end
	end

	if debug and typeof(debug.getupvalues) == "function" then
		for index, object in ipairs(gcObjects) do
			if typeof(object) == "function" then
				local ok, values = pcall(debug.getupvalues, object)
				if ok and typeof(values) == "table" then
					for upvalueIndex, value in next, values do
						if typeof(value) == "table" then
							for identifier in pairs(needed) do
								if not definitions[identifier] then
									local candidate = rawget(value, identifier)
									if hasStageStats(candidate) then
										definitions[identifier] = candidate
										sources[identifier] = "getgc[" .. index .. "].upvalue["
											.. tostring(upvalueIndex) .. "][" .. string.format("%q", identifier) .. "]"
									end
								end
							end
						end
					end
				end
			end
		end
	end
	return definitions, sources
end

local definitions, definitionSources = resolveDefinitions()

local levelModule
local levelModuleSource
local fuseExpByRarity
local fuseExpSource
local foodDefinitions
local foodDefinitionsSource

local function considerResourceContainer(container, source)
	if typeof(container) ~= "table" then return end
	local fuseCandidate = rawget(container, "FuseTowerExp")
	if not fuseExpByRarity and typeof(fuseCandidate) == "table"
		and tonumber(rawget(fuseCandidate, "Rare"))
		and tonumber(rawget(fuseCandidate, "Epic")) then
		fuseExpByRarity = fuseCandidate
		fuseExpSource = source .. ".FuseTowerExp"
	end

	local foodCandidate = rawget(container, "Food")
	if not foodDefinitions and typeof(foodCandidate) == "table" then
		local valid = 0
		for _, record in next, foodCandidate do
			if typeof(record) == "table"
				and tonumber(rawget(record, "Exp") or rawget(record, "XP") or rawget(record, "FeedExp")) then
				valid += 1
			end
		end
		if valid >= 2 then
			foodDefinitions = foodCandidate
			foodDefinitionsSource = source .. ".Food"
		end
	end
end

for index, object in ipairs(gcObjects) do
	if typeof(object) == "table" then
		if not levelModule and isLevelModule(object) then
			levelModule, levelModuleSource = object, "getgc[" .. index .. "]"
		end

		considerResourceContainer(object, "getgc[" .. index .. "]")
	end
end

-- FuseTowerExp is held inside a UI callback upvalue in the current lobby build,
-- not as a direct getgc table. Read that configuration without invoking the UI.
if (not fuseExpByRarity or not foodDefinitions) and debug and typeof(debug.getupvalues) == "function" then
	for index, object in ipairs(gcObjects) do
		if fuseExpByRarity and foodDefinitions then break end
		if typeof(object) == "function" then
			local ok, upvalues = pcall(debug.getupvalues, object)
			if ok and typeof(upvalues) == "table" then
				for upvalueIndex, value in next, upvalues do
					considerResourceContainer(value,
						"getgc[" .. index .. "].upvalue[" .. tostring(upvalueIndex) .. "]")
				end
			end
		end
	end
end
if not levelModule then fail("LEVEL", "Level formula module was not found.") end
if not fuseExpByRarity then fail("FUSE_EXP", "FuseTowerExp table was not found.") end
if not foodDefinitions then fail("FOOD_INFO", "Food EXP definitions were not found.") end

-- Definitions and callback resources are now held by their specific references.
-- Drop the massive temporary getgc array before remote actions begin so a failed
-- shop verification cannot retain the whole client object graph for the run.
gcObjects = nil

local maxLevel = tonumber(rawget(levelModule, "MaxTowerLevel")) or 70
local getLevel = rawget(levelModule, "GetTowerLevelFromExp")
local neededLevelExp = rawget(levelModule, "NeededTowerLevelExp")
local calculateDamage = rawget(levelModule, "Damage")
local calculateCooldown = rawget(levelModule, "Cooldown")
local calculateRange = rawget(levelModule, "Range")
if typeof(calculateDamage) ~= "function"
	or typeof(calculateCooldown) ~= "function"
	or typeof(calculateRange) ~= "function" then
	fail("CALCULATE", "CalculateStuff Damage/Cooldown/Range functions were not found.")
end

local function levelFrom(exp, rarity)
	local ok, level = pcall(getLevel, tonumber(exp) or 0, rarity)
	return ok and tonumber(level) or nil
end

local function maxExpFor(rarity)
	local ok, value = pcall(neededLevelExp, maxLevel, rarity)
	return ok and tonumber(value) or nil
end

local function isFarmDefinition(definition)
	if rawget(definition, "MoneyUnit") == true then return true end
	local elements = rawget(definition, "Elements")
	if typeof(elements) == "table" then
		for _, element in next, elements do
			if string.lower(tostring(element)) == "farm" then return true end
		end
	end
	return false
end

local function highestDamageStage(definition)
	local best, bestIndex
	for key, stage in next, rawget(definition, "StageStats") do
		if typeof(stage) == "table"
			and tonumber(rawget(stage, "Damage"))
			and tonumber(rawget(stage, "Cooldown"))
			and tonumber(rawget(stage, "Range")) then
			local index = tonumber(key)
			if not best or (index and (not bestIndex or index > bestIndex)) then
				best, bestIndex = stage, index
			end
		end
	end
	return best, bestIndex
end

local function rankOwnedDamage()
	local all = {}
	local excludedTypes = Config.autoPlay and Config.autoPlay.excludedPlacementTypes or {}
	for uuid, record in next, towers() do
		if typeof(uuid) == "string" and typeof(record) == "table" then
			local identifier = rawget(record, "Name")
			local definition = definitions[identifier]
			if definition and not isFarmDefinition(definition) then
				local placementType = tostring(rawget(definition, "PlacementType") or "Ground")
				if rawget(excludedTypes, placementType) ~= true then
					local stage, stageIndex = highestDamageStage(definition)
					local grades = rawget(record, "Grades")
					local damageMultiplier = typeof(grades) == "table"
						and tonumber(rawget(grades, "DamageMultiplier")) or 1
					local cooldownMultiplier = typeof(grades) == "table"
						and tonumber(rawget(grades, "CooldownMultiplier")) or 1
					local rangeMultiplier = typeof(grades) == "table"
						and tonumber(rawget(grades, "RangeMultiplier")) or 1
					if stage and damageMultiplier and cooldownMultiplier and cooldownMultiplier > 0 and rangeMultiplier then
						local damageOK, damage = pcall(calculateDamage, record, stageIndex)
						local cooldownOK, cooldown = pcall(calculateCooldown, record, stageIndex)
						local rangeOK, range = pcall(calculateRange, record, stageIndex)
						damage = damageOK and tonumber(damage) or nil
						cooldown = cooldownOK and tonumber(cooldown) or nil
						range = rangeOK and tonumber(range) or nil
						if not damage or not cooldown or cooldown <= 0 or not range then
							fail("CALCULATE", "CalculateStuff could not evaluate max-stage stats for "
								.. tostring(identifier) .. " UUID " .. tostring(uuid) .. ".")
						end
						local rarity = rawget(definition, "Rarity")
						local exp = tonumber(rawget(record, "Exp")) or 0
						table.insert(all, {
							uuid = uuid,
							identifier = identifier,
							displayName = rawget(definition, "DisplayName") or identifier,
							rarity = rarity,
							exp = exp,
							level = levelFrom(exp, rarity),
							maxExp = maxExpFor(rarity),
							damage = damage,
							cooldown = cooldown,
							range = range,
							dps = damage / cooldown,
							maxStage = stageIndex,
							placementType = placementType,
							definitionSource = definitionSources[identifier],
						})
					end
				end
			end
		end
	end

	table.sort(all, function(left, right)
		if left.dps ~= right.dps then return left.dps > right.dps end
		if left.range ~= right.range then return left.range > right.range end
		if left.exp ~= right.exp then return left.exp > right.exp end
		return left.uuid < right.uuid
	end)

	local unique, seen = {}, {}
	for _, candidate in ipairs(all) do
		if not seen[candidate.identifier] then
			seen[candidate.identifier] = true
			table.insert(unique, candidate)
		end
	end
	return unique, all
end

local ranking, allDamageCopies = rankOwnedDamage()
local targetLimit = math.max(1, math.floor(tonumber(Settings.maximumRankedTargets) or 6))
while #ranking > targetLimit do table.remove(ranking) end
if #ranking == 0 then
	-- A brand-new account can reach this worker before it owns a compatible
	-- damage unit. This is an empty-work pass, not a pipeline failure; FastMode
	-- can summon units and the next lobby lifecycle will rank them normally.
	report.status = "SKIPPED_NO_ELIGIBLE_DAMAGE"
	report.warnings = { "No eligible damage unit was available; progression was skipped." }
	log("SKIP", "No eligible damage unit was available; progression was skipped.")
	saveReport(report.status)
	publishLifecycle("COMPLETE", {
		reportStatus = report.status,
		skipped = true,
		reason = "empty eligible damage inventory",
		reportFile = reportFile,
	})
	if environment.AnimeOriginUnitProgressionRunning == runToken then
		environment.AnimeOriginUnitProgressionRunning = nil
	end
	environment.AnimeOriginUnitProgressionReport = report
	return report
end

local function publicUnit(unit, rank)
	return {
		rank = rank,
		uuid = unit.uuid,
		identifier = unit.identifier,
		displayName = unit.displayName,
		rarity = unit.rarity,
		exp = unit.exp,
		level = unit.level,
		maxExp = unit.maxExp,
		damage = unit.damage,
		cooldown = unit.cooldown,
		range = unit.range,
		dps = unit.dps,
		maxStage = unit.maxStage,
		placementType = unit.placementType,
	}
end

for index, unit in ipairs(ranking) do
	report.ranking[index] = publicUnit(unit, index)
end

local protected = {}
local protectedReasons = {}
local function protect(uuid, reason)
	protected[uuid] = true
	protectedReasons[uuid] = protectedReasons[uuid] or {}
	table.insert(protectedReasons[uuid], reason)
end

for index, unit in ipairs(ranking) do protect(unit.uuid, "rank_" .. index) end
for uuid in pairs(equippedSet()) do protect(uuid, "equipped") end

local damageCopyByUUID = {}
for _, unit in ipairs(allDamageCopies) do damageCopyByUUID[unit.uuid] = unit end
local bestCopyByIdentifier = {}
for uuid, record in next, towers() do
	if typeof(uuid) == "string" and typeof(record) == "table" then
		local identifier = rawget(record, "Name")
		if typeof(identifier) == "string" then
			local damage = damageCopyByUUID[uuid]
			local candidate = {
				uuid = uuid,
				dps = damage and damage.dps or -1,
				range = damage and damage.range or -1,
				exp = tonumber(rawget(record, "Exp")) or 0,
			}
			local current = bestCopyByIdentifier[identifier]
			if not current
				or candidate.dps > current.dps
				or (candidate.dps == current.dps and candidate.range > current.range)
				or (candidate.dps == current.dps and candidate.range == current.range and candidate.exp > current.exp)
				or (candidate.dps == current.dps and candidate.range == current.range
					and candidate.exp == current.exp and candidate.uuid < current.uuid) then
				bestCopyByIdentifier[identifier] = candidate
			end
		end
	end
end
for identifier, candidate in pairs(bestCopyByIdentifier) do
	if Settings.preserveBestCopyPerIdentifier ~= false then
		protect(candidate.uuid, "best_copy_" .. identifier)
	end
end

for uuid, record in next, towers() do
	if typeof(record) == "table" then
		local identifier = rawget(record, "Name")
		if rawget(record, "Locked") == true then protect(uuid, "locked") end
		if Settings.preserveShiny ~= false and rawget(record, "Shiny") == true then protect(uuid, "shiny") end
		if typeof(Settings.protectedIdentifiers) == "table"
			and rawget(Settings.protectedIdentifiers, identifier) == true then
			protect(uuid, "configured_identifier")
		end
		if Settings.preserveUnitsWithExp ~= false and (tonumber(rawget(record, "Exp")) or 0) > 0 then
			protect(uuid, "existing_exp")
		end
	end
end
report.protected = protectedReasons

local function refreshTarget(unit)
	local record = rawget(towers(), unit.uuid)
	if typeof(record) ~= "table" then return nil end
	local exp = tonumber(rawget(record, "Exp")) or 0
	return {
		rank = unit.rank,
		uuid = unit.uuid,
		identifier = unit.identifier,
		rarity = unit.rarity,
		exp = exp,
		level = levelFrom(exp, unit.rarity) or 1,
		maxExp = unit.maxExp or maxExpFor(unit.rarity),
	}
end

local rankedTargets = {}
for index, unit in ipairs(ranking) do
	unit.rank = index
	table.insert(rankedTargets, unit)
end

local function currentCohort()
	local primarySize = math.max(1, math.floor(tonumber(Settings.primaryCohortSize) or 3))
	local primary = {}
	for index = 1, math.min(primarySize, #rankedTargets) do
		table.insert(primary, refreshTarget(rankedTargets[index]))
	end
	local primaryMaxed = #primary > 0
	for _, unit in ipairs(primary) do
		if not unit or unit.level < maxLevel then primaryMaxed = false; break end
	end

	local selected = primary
	local cohortName = "ranks_1_" .. tostring(#primary)
	if primaryMaxed and #rankedTargets > primarySize then
		selected = {}
		for index = primarySize + 1, math.min(targetLimit, #rankedTargets) do
			table.insert(selected, refreshTarget(rankedTargets[index]))
		end
		cohortName = "ranks_" .. tostring(primarySize + 1) .. "_" .. tostring(primarySize + #selected)
	end
	return selected, cohortName, primaryMaxed
end

local function chooseTarget()
	local cohort, cohortName, primaryMaxed = currentCohort()
	local available = {}
	for _, unit in ipairs(cohort) do
		if unit and unit.level < maxLevel then table.insert(available, unit) end
	end
	table.sort(available, function(left, right)
		if left.level ~= right.level then return left.level < right.level end
		if left.exp ~= right.exp then return left.exp < right.exp end
		return left.rank < right.rank
	end)
	return available[1], cohort, cohortName, primaryMaxed
end

-- Balance only up to the next cohort member's EXP. When all members are tied,
-- one smallest resource is used so the next iteration naturally chooses another.
local function balanceBudget(target, cohort, smallestResourceExp)
	local nextExp
	for _, member in ipairs(cohort) do
		if member and member.uuid ~= target.uuid and member.exp > target.exp
			and (not nextExp or member.exp < nextExp) then
			nextExp = member.exp
		end
	end
	local remaining = math.max(0, (target.maxExp or target.exp) - target.exp)
	local desired = nextExp and math.max(1, nextExp - target.exp) or math.max(1, smallestResourceExp or 1)
	return math.min(remaining, desired)
end

local inventoryRemotes = requireChild(requireChild(ReplicatedStorage, "Remotes"), "InventoryRemotes")
local inventoryFunction = requireChild(inventoryRemotes, "InventoryFunction")
-- Was `ReplicatedStorage.Remotes.InventoryRemotes:WaitForChild(...)`: direct indexing
-- raises a RAW error when the folder has not replicated, and a raw error at module
-- scope bypasses fail() entirely -- leaving the lifecycle stuck at RUNNING instead of
-- reporting FAILED. Reuse the container resolved above through the bounded path.
local inventoryRemote = requireChild(inventoryRemotes, "InventoryRemote")
local lobbyRemotes = requireChild(ReplicatedStorage, "LobbyRemotes")
local shopRemote = requireChild(lobbyRemotes, "ShopRemote")
local shopFunction = requireChild(lobbyRemotes, "ShopFunction")

local function configuredLockCandidates()
	local result = {}
	if Settings.lockConfiguredUnits == false or typeof(Settings.lockIdentifiers) ~= "table" then return result end
	for uuid, record in next, towers() do
		if typeof(record) == "table"
			and rawget(Settings.lockIdentifiers, rawget(record, "Name")) == true
			and rawget(record, "Locked") ~= true then
			table.insert(result, { uuid = uuid, identifier = rawget(record, "Name") })
		end
	end
	table.sort(result, function(left, right) return left.uuid < right.uuid end)
	return result
end

local lockCandidates = configuredLockCandidates()
report.plans.lock = lockCandidates

local function lockConfiguredUnits()
	for _, candidate in ipairs(configuredLockCandidates()) do
		if Settings.dryRun then break end
		log("LOCK", "Locking " .. candidate.identifier .. " (" .. candidate.uuid .. ").")
		local ok, locked = pcall(inventoryFunction.InvokeServer, inventoryFunction, "LockTower", candidate.uuid)
		local record = rawget(towers(), candidate.uuid)
		if ok and locked == true and typeof(record) == "table" then
			-- Mirror the official callback: the server return is authoritative and
			-- the client writes it into GlobalTables.Inventory.Towers[uuid].Locked.
			record.Locked = true
		end
		local verified = ok and locked == true and typeof(record) == "table" and rawget(record, "Locked") == true
		table.insert(report.actions, {
			type = "lock",
			uuid = candidate.uuid,
			identifier = candidate.identifier,
			remoteReturn = tostring(locked),
			verified = verified,
		})
		if not verified then fail("LOCK", "Server did not return Locked=true for " .. candidate.uuid) end
		protect(candidate.uuid, "locked")
		task.wait(actionDelay)
	end
end

local function fusionSources()
	local result = {}
	local equipped = equippedSet()
	local currentTowers = towers()
	for uuid, record in next, currentTowers do
		if typeof(uuid) == "string" and typeof(record) == "table" and not protected[uuid] then
			local identifier = rawget(record, "Name")
			local definition = definitions[identifier]
			local rarity = definition and rawget(definition, "Rarity") or nil
			local fuseExp = rarity and tonumber(rawget(fuseExpByRarity, rarity)) or nil
			local allowed = typeof(Settings.consumableRarities) == "table"
				and rawget(Settings.consumableRarities, rarity) == true
			if allowed and fuseExp and fuseExp > 0
				and not equipped[uuid]
				and rawget(record, "Locked") ~= true
				and (Settings.preserveShiny == false or rawget(record, "Shiny") ~= true) then
				table.insert(result, {
					uuid = uuid,
					identifier = identifier,
					rarity = rarity,
					fuseExp = fuseExp,
					existingExp = tonumber(rawget(record, "Exp")) or 0,
				})
			end
		end
	end
	table.sort(result, function(left, right)
		if left.fuseExp ~= right.fuseExp then return left.fuseExp < right.fuseExp end
		if left.existingExp ~= right.existingExp then return left.existingExp < right.existingExp end
		return left.uuid < right.uuid
	end)
	return result
end

local function selectFusionBatch(target, cohort)
	local sources = fusionSources()
	if #sources == 0 then return {}, {}, 0 end
	local budget = balanceBudget(target, cohort, sources[1].fuseExp)
	local maximum = math.max(1, math.floor(tonumber(Settings.maximumFuseSourcesPerRequest) or 24))
	local selected, payload, total = {}, {}, 0
	for _, source in ipairs(sources) do
		if #selected >= maximum then break end
		table.insert(selected, source)
		payload[source.uuid] = true
		total += source.fuseExp
		if total >= budget then break end
	end
	return selected, payload, total
end

local function runFusion()
	if Settings.fuseEnabled == false then return end
	local maximumRequests = math.max(0, math.floor(tonumber(Settings.maximumFuseRequestsPerRun) or 60))
	for request = 1, maximumRequests do
		local target, cohort, cohortName = chooseTarget()
		if not target then return end
		local selected, payload, plannedExp = selectFusionBatch(target, cohort)
		if #selected == 0 then
			report.plans.fusion = {
				cohort = cohortName,
				target = target,
				sources = {},
				status = "No disposable source passed every protection rule.",
			}
			return
		end
		if Settings.dryRun then
			report.plans.fusion = {
				cohort = cohortName,
				target = target,
				sources = selected,
				plannedBaseExp = plannedExp,
			}
			return
		end

		local beforeExp = target.exp
		log("FUSE", string.format("Fusing %d unit(s) into rank %d %s.", #selected, target.rank, target.identifier))
		inventoryRemote:FireServer("FuseTower", target.uuid, payload)
		local verified = waitFor(function()
			local currentTarget = rawget(towers(), target.uuid)
			if typeof(currentTarget) ~= "table" then return false end
			for _, source in ipairs(selected) do
				if rawget(towers(), source.uuid) ~= nil then return false end
			end
			return (tonumber(rawget(currentTarget, "Exp")) or 0) > beforeExp
		end, verifyTimeout)
		local afterRecord = rawget(towers(), target.uuid)
		local afterExp = typeof(afterRecord) == "table" and tonumber(rawget(afterRecord, "Exp")) or nil
		table.insert(report.actions, {
			type = "fuse",
			request = request,
			targetUuid = target.uuid,
			targetRank = target.rank,
			sourceCount = #selected,
			beforeExp = beforeExp,
			afterExp = afterExp,
			verified = verified,
		})
		saveReport("fusion_request_" .. request)
		if not verified then fail("FUSE", "Consumed UUIDs/target EXP were not verified; stopped without retry.") end
		task.wait(actionDelay)
	end
end

local function normalizeItemName(value)
	return string.lower(tostring(value or "")):gsub("[^%w]", "")
end

-- Shop display names may contain spaces or hyphens while Inventory.Food uses an
-- internal key. Resolve both through the authoritative Food definition table.
local function resolveFoodName(name)
	if typeof(rawget(foodDefinitions, name)) == "table" then return name end
	local wanted = normalizeItemName(name)
	for internalName, record in next, foodDefinitions do
		if typeof(record) == "table" and normalizeItemName(internalName) == wanted then
			return internalName
		end
	end
	return nil
end

local function foodExp(name)
	local internalName = resolveFoodName(name)
	local record = internalName and rawget(foodDefinitions, internalName) or nil
	local exp = typeof(record) == "table"
		and tonumber(rawget(record, "Exp") or rawget(record, "XP") or rawget(record, "FeedExp")) or nil
	return exp, internalName
end

local function isGoldCatalog(value)
	if typeof(value) ~= "table" or typeof(rawget(value, "ShopItems")) ~= "table" then return false end
	local shopCurrency = rawget(value, "Currency")
	-- The server return is accepted when it explicitly declares Gold. Some game
	-- builds omit Currency from the wrapper, so GoldShop identity is also proven
	-- by the dedicated GetCurrentGoldShopRotation endpoint used below.
	return shopCurrency == nil
		or (typeof(shopCurrency) == "table" and tostring(rawget(shopCurrency, "ItemName")) == "Gold")
end

local function isShopItemsTable(value)
	if typeof(value) ~= "table" then return false end
	local matches = 0
	for _, item in next, value do
		if typeof(item) == "table"
			and rawget(item, "ItemName") ~= nil
			and rawget(item, "ItemType") ~= nil
			and tonumber(rawget(item, "Price"))
			and tonumber(rawget(item, "Stock")) then
			matches += 1
			if matches >= 1 then return true end
		end
	end
	return false
end

local function findCatalog(value, depth, visited)
	if isGoldCatalog(value) then return value end
	if typeof(value) ~= "table" or depth <= 0 then return nil end
	visited = visited or {}
	if visited[value] then return nil end
	visited[value] = true
	for _, child in next, value do
		if typeof(child) == "table" then
			local found = findCatalog(child, depth - 1, visited)
			if found then return found end
		end
	end
	return nil
end

local function resultShape(value)
	local valueType = typeof(value)
	if valueType ~= "table" then return valueType end
	local keys = {}
	for key, child in next, value do
		table.insert(keys, tostring(key) .. ":" .. typeof(child))
		if #keys >= 20 then break end
	end
	table.sort(keys)
	return "table{" .. table.concat(keys, ",") .. "}"
end

local function goldShopState()
	local shops = rawget(currentPlayerData(), "Shops")
	return typeof(shops) == "table" and rawget(shops, "GoldShop") or nil
end

local function activeGoldCatalog()
	local state = goldShopState()
	local stateSeed = typeof(state) == "table" and rawget(state, "Seed") or nil

	-- This is the normal game's own read endpoint, recovered from the GoldShop
	-- callback. It initializes nothing in the UI and returns the current rotation
	-- even when the player has never opened Gold Shop in this session.
	-- Preserve every return value. Roblox callbacks commonly return a success
	-- boolean followed by the payload; assigning only two pcall results discarded
	-- that payload and caused the previous server_response_missing_catalog bug.
	local remoteResults = table.pack(pcall(
		shopFunction.InvokeServer,
		shopFunction,
		"GetCurrentGoldShopRotation"
	))
	local remoteOK = remoteResults[1] == true
	local responseShapes = {}
	local catalog
	local returnedItems
	local returnedShopInfo
	local returnedSeed
	for index = 2, remoteResults.n do
		local response = remoteResults[index]
		table.insert(responseShapes, resultShape(response))
		catalog = catalog or findCatalog(response, 5)
		if not returnedItems and isShopItemsTable(response) then returnedItems = response end
		if typeof(response) == "table" and not returnedShopInfo then
			local responseCurrency = rawget(response, "Currency")
			if typeof(responseCurrency) == "table"
				and tostring(rawget(responseCurrency, "ItemName")) == "Gold" then
				returnedShopInfo = response
			end
		end
		if typeof(response) == "number" then returnedSeed = response end
	end
	-- Some builds return ShopInfo, ShopItems and CurrentSeed as three separate
	-- values. Rebuild only the minimal catalog wrapper required by this script;
	-- item identity/index still comes entirely from the server-returned table.
	if not catalog and returnedItems then
		catalog = {
			ShopItems = returnedItems,
			CurrentSeed = returnedSeed or stateSeed,
			Currency = returnedShopInfo and rawget(returnedShopInfo, "Currency") or { ItemName = "Gold" },
		}
	end
	if remoteOK then
		if catalog then
			local catalogSeed = rawget(catalog, "CurrentSeed") or stateSeed
			-- Give PlayerData a short chance to catch up when a daily rotation changed
			-- between joining and this request. BoughtItems is only trusted afterward.
			if catalogSeed ~= nil and stateSeed ~= catalogSeed then
				waitFor(function()
					local current = goldShopState()
					return typeof(current) == "table" and rawget(current, "Seed") == catalogSeed
				end, math.min(verifyTimeout, 2))
				state = goldShopState()
				stateSeed = typeof(state) == "table" and rawget(state, "Seed") or stateSeed
			end
			return catalog, state, catalogSeed, "ShopFunction", stateSeed, responseShapes
		end
	end

	-- Compatibility fallback for a build that returns no table. Rescan getgc at
	-- request time rather than using the startup snapshot that caused this bug.
	local liveOK, liveObjects = pcall(getgc, true)
	if liveOK and typeof(liveObjects) == "table" then
		for _, object in ipairs(liveObjects) do
			local shopCurrency = typeof(object) == "table" and rawget(object, "Currency") or nil
			if isGoldCatalog(object)
				and typeof(shopCurrency) == "table"
				and tostring(rawget(shopCurrency, "ItemName")) == "Gold"
				and (stateSeed == nil or rawget(object, "CurrentSeed") == stateSeed) then
				return object, state, rawget(object, "CurrentSeed") or stateSeed,
					"getgc_fallback", stateSeed, responseShapes
			end
		end
	end
	local remoteError = not remoteOK and tostring(remoteResults[2]) or nil
	return nil, state, stateSeed,
		remoteOK and "server_response_missing_catalog" or remoteError,
		stateSeed, responseShapes
end

local function foodAllowed(name)
	if Settings.shop.buyEveryFoodInRotation ~= false then return true end
	local allowlist = Settings.shop.foodAllowlist
	if typeof(allowlist) ~= "table" then return false end
	local wanted = normalizeItemName(name)
	for allowedName, enabled in next, allowlist do
		if enabled == true and normalizeItemName(allowedName) == wanted then return true end
	end
	return false
end

local function shopFoodPlan()
	local catalog, state, seed, source, playerDataSeed, responseShapes = activeGoldCatalog()
	if not catalog then
		return {}, {
			seed = seed,
			playerDataSeed = playerDataSeed,
			source = source,
			responseShapes = responseShapes,
			error = "active_catalog_not_found",
		}
	end
	-- BoughtItems belongs to one seed only. If PlayerData is still showing the
	-- previous daily seed, ignoring its old counters is safer and correct because
	-- the server-returned rotation has fresh stock; every purchase is still
	-- verified through Gold and Inventory.Food changes before another request.
	local boughtItemsTrusted = seed == nil or playerDataSeed == nil or seed == playerDataSeed
	local bought = boughtItemsTrusted and typeof(state) == "table" and rawget(state, "BoughtItems") or nil
	bought = typeof(bought) == "table" and bought or {}
	local foods = {}
	for index, item in next, rawget(catalog, "ShopItems") do
		if typeof(item) == "table"
			and tostring(rawget(item, "ItemType")) == "Food"
			and foodAllowed(rawget(item, "ItemName")) then
			local shopName = rawget(item, "ItemName")
			local exp, name = foodExp(shopName)
			local price = tonumber(rawget(item, "Price"))
			local stock = tonumber(rawget(item, "Stock")) or 0
			local already = tonumber(rawget(bought, index) or rawget(bought, tostring(index))) or 0
			if price and price > 0 and exp and stock > already then
				table.insert(foods, {
					index = tonumber(index) or index,
					name = name,
					shopName = shopName,
					price = price,
					exp = exp,
					remainingStock = stock - already,
					expPerGold = exp / price,
				})
			end
		end
	end
	table.sort(foods, function(left, right)
		if left.expPerGold ~= right.expPerGold then return left.expPerGold > right.expPerGold end
		return tostring(left.name) < tostring(right.name)
	end)
	return foods, {
		seed = seed,
		playerDataSeed = playerDataSeed,
		boughtItemsTrusted = boughtItemsTrusted,
		gold = currency("Gold"),
		source = source,
		responseShapes = responseShapes,
	}
end

local shopPlan, shopEvidence = shopFoodPlan()
report.plans.shop = { foods = shopPlan, evidence = shopEvidence }

local function remainingRankedTargetExp()
	local total = 0
	for _, unit in ipairs(rankedTargets) do
		local current = refreshTarget(unit)
		if current and current.level < maxLevel and current.maxExp then
			total += math.max(0, current.maxExp - current.exp)
		end
	end
	return total
end

local function storedFoodExp()
	local total = 0
	for name, amount in next, foodInventory() do
		local exp = foodExp(name)
		if exp then total += math.max(0, tonumber(amount) or 0) * exp end
	end
	return total
end

local function buyFood()
	if Settings.shop.enabled == false then return end
	local missingFoodExp = math.max(0, remainingRankedTargetExp() - storedFoodExp())
	report.plans.shop.missingExpBeforePurchase = missingFoodExp
	if missingFoodExp <= 0 then
		report.plans.shop.skipped = "Stored food already covers every ranked target or all targets are maxed."
		return
	end
	local remainingPurchases = math.max(0, math.floor(tonumber(Settings.shop.maximumPurchasesPerRun) or 100))
	local reserveGold = math.max(0, tonumber(Settings.shop.reserveGold) or 0)
	if #(report.plans.shop.foods or {}) == 0 then
		if report.plans.shop.evidence and report.plans.shop.evidence.error then
			report.plans.shop.skipped = "The server Gold Shop catalog could not be resolved."
		else
			report.plans.shop.skipped = "No live Food entry with stock and a verified EXP definition was found."
		end
	end
	for _, item in ipairs(report.plans.shop.foods or {}) do
		if remainingPurchases <= 0 then break end
		local availableGold = math.max(0, currency("Gold") - reserveGold)
		local quantity = math.min(
			item.remainingStock,
			remainingPurchases,
			math.floor(availableGold / item.price),
			math.ceil(missingFoodExp / item.exp)
		)
		if quantity > 0 then
			if Settings.dryRun then
				item.plannedQuantity = quantity
			else
				local beforeGold = currency("Gold")
				local beforeFood = tonumber(rawget(foodInventory(), item.name)) or 0
				log("SHOP", string.format("Buying %dx %s from live GoldShop index %s.",
					quantity, item.name, tostring(item.index)))
				shopRemote:FireServer("BuyShopItem", tostring(Settings.shop.name or "GoldShop"), item.index, quantity)
				local verified = waitFor(function()
					return currency("Gold") < beforeGold
						and (tonumber(rawget(foodInventory(), item.name)) or 0) > beforeFood
				end, verifyTimeout)
				if not verified and refreshPlayerDataContainer() then
					verified = waitFor(function()
						return currency("Gold") < beforeGold
							and (tonumber(rawget(foodInventory(), item.name)) or 0) > beforeFood
					end, math.min(verifyTimeout, 2))
				end
				local afterGold = currency("Gold")
				local afterFood = tonumber(rawget(foodInventory(), item.name)) or 0
				table.insert(report.actions, {
					type = "buy_food",
					item = item.name,
					index = item.index,
					quantity = quantity,
					goldBefore = beforeGold,
					goldAfter = afterGold,
					foodBefore = beforeFood,
					foodAfter = afterFood,
					verified = verified,
				})
				saveReport("buy_" .. item.name)
				if not verified then
					report.warnings = report.warnings or {}
					table.insert(report.warnings,
						"Gold/Food change was not verified for " .. item.name .. "; remaining shop purchases were skipped.")
					log("SHOP_WARNING", "Purchase was not verified; progression will continue with stored food only.", {
						item = item.name,
						playerDataSource = playerDataSource,
					})
					break
				end
				task.wait(actionDelay)
			end
			remainingPurchases -= quantity
			missingFoodExp = math.max(0, missingFoodExp - quantity * item.exp)
			if missingFoodExp <= 0 then break end
		end
	end
	report.plans.shop.missingExpAfterPlannedPurchase = missingFoodExp
end

local function availableFood()
	local result = {}
	for name, amount in next, foodInventory() do
		local exp = foodExp(name)
		local count = math.max(0, math.floor(tonumber(amount) or 0))
		if exp and exp > 0 and count > 0 then
			table.insert(result, { name = name, amount = count, exp = exp })
		end
	end
	table.sort(result, function(left, right)
		if left.exp ~= right.exp then return left.exp < right.exp end
		return left.name < right.name
	end)
	return result
end

local function selectFoodBatch(target, cohort)
	local foods = availableFood()
	if #foods == 0 then return {}, 0 end
	local budget = balanceBudget(target, cohort, foods[1].exp)
	local selected, total = {}, 0
	for _, item in ipairs(foods) do
		if total >= budget then break end
		local needed = math.max(1, math.ceil((budget - total) / item.exp))
		local amount = math.min(item.amount, needed)
		if amount > 0 then
			selected[item.name] = amount
			total += amount * item.exp
		end
	end
	return selected, total
end

local function countSelectedFood(selected)
	local count = 0
	for _, amount in next, selected do count += tonumber(amount) or 0 end
	return count
end

local function runFood()
	if Settings.feedFoodEnabled == false then return end
	local maximumRequests = math.max(0, math.floor(tonumber(Settings.maximumFeedRequestsPerRun) or 120))
	for request = 1, maximumRequests do
		local target, cohort, cohortName = chooseTarget()
		if not target then return end
		local selected, plannedExp = selectFoodBatch(target, cohort)
		if next(selected) == nil then return end
		if Settings.dryRun then
			report.plans.feed = {
				cohort = cohortName,
				target = target,
				items = selected,
				plannedBaseExp = plannedExp,
			}
			return
		end

		local beforeExp = target.exp
		local beforeFood = {}
		for name in pairs(selected) do beforeFood[name] = tonumber(rawget(foodInventory(), name)) or 0 end
		log("FEED", string.format("Feeding %d item(s) to rank %d %s.",
			countSelectedFood(selected), target.rank, target.identifier))
		inventoryRemote:FireServer("FeedTower", target.uuid, selected)
		local verified = waitFor(function()
			local record = rawget(towers(), target.uuid)
			if typeof(record) ~= "table" or (tonumber(rawget(record, "Exp")) or 0) <= beforeExp then return false end
			for name, before in pairs(beforeFood) do
				if (tonumber(rawget(foodInventory(), name)) or 0) < before then return true end
			end
			return false
		end, verifyTimeout)
		local afterRecord = rawget(towers(), target.uuid)
		local afterExp = typeof(afterRecord) == "table" and tonumber(rawget(afterRecord, "Exp")) or nil
		table.insert(report.actions, {
			type = "feed",
			request = request,
			targetUuid = target.uuid,
			targetRank = target.rank,
			items = selected,
			beforeExp = beforeExp,
			afterExp = afterExp,
			verified = verified,
		})
		saveReport("feed_request_" .. request)
		if not verified then fail("FEED", "Food decrease/target EXP increase was not verified; stopped without retry.") end
		task.wait(actionDelay)
	end
end

local function finalLevels()
	local output = {}
	for index, unit in ipairs(rankedTargets) do
		local current = refreshTarget(unit)
		output[index] = current
	end
	return output
end

local function run()
	report.status = Settings.dryRun and "DRY_RUN" or "RUNNING"
		report.evidence = {
			playerDataSource = playerDataSource,
			levelModuleSource = levelModuleSource,
			fuseExpSource = fuseExpSource,
			foodDefinitionsSource = foodDefinitionsSource,
		maxTowerLevel = maxLevel,
		gold = currency("Gold"),
		food = availableFood(),
	}
	log("PLAN", string.format("Ranked %d target(s); dryRun=%s.", #ranking, tostring(Settings.dryRun)))

	lockConfiguredUnits()
	runFusion()
	buyFood()
	runFood()

	report.finalLevels = finalLevels()
	report.finalFood = availableFood()
	report.finalGold = currency("Gold")
	report.status = Settings.dryRun and "DRY_RUN_COMPLETE"
		or (report.warnings and #report.warnings > 0 and "COMPLETE_WITH_WARNINGS" or "COMPLETE")
	saveReport(report.status)
	log("DONE", report.status .. " | report=" .. reportFile)
	return report
end

local ok, result = xpcall(run, function(message)
	return debug and debug.traceback and debug.traceback(tostring(message), 2) or tostring(message)
end)

if environment.AnimeOriginUnitProgressionRunning == runToken then
	environment.AnimeOriginUnitProgressionRunning = nil
end
environment.AnimeOriginUnitProgressionReport = ok and result or {
	status = "FAILED",
	error = result,
	reportFile = reportFile,
	logFile = logFile,
}
trace(ok and "COMPLETE" or "FAILED", {
	reportStatus = ok and result.status or "FAILED",
	error = not ok and tostring(result):sub(1, 220) or nil,
})
publishLifecycle(ok and "COMPLETE" or "FAILED", {
	reportStatus = ok and result.status or "FAILED",
	reportFile = reportFile,
	logFile = logFile,
	error = not ok and result or nil,
})
if not ok then
	log("FATAL", "Execution stopped.", { trace = result })
	error(result, 0)
end
return result
