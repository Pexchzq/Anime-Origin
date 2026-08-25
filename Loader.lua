--[[
	Anime Origin remote loader for executors such as Voit.

	The loader keeps the same dependency order as the verified MacSploit
	Auto-Execute setup. It also queues itself before a place transition so the
	lobby and in-stage controllers are rebuilt against the new Roblox runtime.

	Every stage below announces itself on the [AO][LOADER] trace channel. That is
	not decoration: this file used to contain zero print statements, so a client
	where the executor never injected, a client whose Config download failed, and a
	client that loaded perfectly all produced exactly the same empty F9 console.
	One captured console must be able to say which of those happened.
]]

local RAW_ROOT = "https://raw.githubusercontent.com/Pexchzq/Anime-Origin/main/"
local LOADER_URL = RAW_ROOT .. "Loader.lua"

local environment = getgenv()

-- Config publishes the shared tracer, but the lines below happen before Config
-- exists. Keep a local copy in the same format and hand the epoch over, so the
-- Loader's half and the controllers' half of a capture share one clock and one
-- sequence counter.
local traceEpoch = os.clock()
environment.AnimeOriginTraceEpoch = traceEpoch
environment.AnimeOriginTraceSequence = tonumber(environment.AnimeOriginTraceSequence) or 0

local function trace(message, data)
	if environment.AnimeOriginLoaderTrace == false then return end
	environment.AnimeOriginTraceSequence += 1
	local suffix = ""
	if data ~= nil then
		local ok, encoded = pcall(function()
			return game:GetService("HttpService"):JSONEncode(data)
		end)
		suffix = " " .. (ok and encoded or tostring(data))
	end
	print(string.format("[AO][%03d][%6.1fs][LOADER] %s%s",
		environment.AnimeOriginTraceSequence, os.clock() - traceEpoch, tostring(message), suffix))
	-- Also record into the diagnostics capture once it exists. Resolved per call
	-- rather than captured, because the lines above run before Diag.lua is downloaded
	-- and those belong to the console half of the capture only.
	local diag = environment.AnimeOriginDiag
	if typeof(diag) == "table" and typeof(diag.mark) == "function" then
		diag.mark("Loader", message, data)
	end
end

trace("attached", {
	placeId = game.PlaceId,
	jobId = game.JobId,
	-- Executor capability matters more than executor name here: every failure mode
	-- below is a missing capability, and a capture that omits them cannot be judged.
	httpGet = typeof(game.HttpGet) == "function",
	loadstring = typeof(loadstring) == "function",
	getgc = typeof(getgc) == "function",
	writefile = typeof(writefile) == "function",
	firetouchinterest = typeof(firetouchinterest) == "function",
})

-- Arm the teleport queue FIRST, before anything below can yield. Every wait after
-- this point is a window in which a place transition would otherwise drop the
-- script permanently, and the load wait below can be the longest wait of the run.
--
-- Executor APIs use different names for the same teleport queue capability.
-- Queue only the small loader call; every joined place downloads fresh files.
local queueTeleport = queue_on_teleport
	or (syn and syn.queue_on_teleport)
	or (fluxus and fluxus.queue_on_teleport)
if typeof(queueTeleport) == "function" then
	local queued = pcall(queueTeleport, string.format(
		'loadstring(game:HttpGet(%q, true), "AnimeOrigin.Loader")()',
		LOADER_URL
	))
	trace(queued and "teleport queue armed" or "teleport queue call FAILED")
else
	-- Worth a line of its own: without it the script silently stops existing after
	-- the first stage teleport, which looks exactly like the script never working.
	trace("teleport queue UNAVAILABLE on this executor; the script will not survive a teleport")
end

-- Auto-Execute fires the moment the client attaches, which on a machine running
-- many clients happens well before the game is actually playable. Every controller
-- below reads live game state -- remotes, Workspace, PlayerData -- so starting
-- early is precisely how a client ends up attached but doing nothing.
--
-- Polled rather than `game.Loaded:Wait()`, for two reasons. The signal fires once,
-- so a build where it has already fired would park here forever. And this must be
-- bounded: if loading genuinely stalls, proceeding is better than never running at
-- all -- each controller has its own runtimeLoadTimeout and will keep looking for
-- live state, whereas an unbounded wait here produces a client that is attached
-- and permanently silent.
local loadWaitStartedAt = os.clock()
local loadTimeout = tonumber(environment.AnimeOriginLoaderLoadTimeout) or 120
if not game:IsLoaded() then
	local loadDeadline = os.clock() + loadTimeout
	repeat
		task.wait(0.2)
	until game:IsLoaded() or os.clock() >= loadDeadline
end
trace(game:IsLoaded() and "game loaded" or "game load TIMED OUT; continuing anyway", {
	waited = string.format("%.1fs", os.clock() - loadWaitStartedAt),
	timeout = loadTimeout,
})

-- Every client on this machine reaches this point at the same moment, then all of
-- them download eight files and walk the whole Lua heap at once. That thundering
-- herd is what turns a busy host into failed attachments. Spread the start.
--
-- This waits only after the teleport queue above is armed: a place transition
-- during the delay must still bring the loader back, not drop it.
--
-- Raise it on a host running many clients:
--     getgenv().AnimeOriginLoaderJitter = 20
local jitter = tonumber(environment.AnimeOriginLoaderJitter) or 8
if jitter > 0 then
	local delay = math.random() * jitter
	trace(string.format("startup jitter %.1fs", delay))
	task.wait(delay)
end

local workerFiles = {
	"InGameSettings.lua",
	"FastMode.lua",
	"UnitProgression.lua",
	"main.lua",
	"AutoPlay.lua",
	"Optimizer.lua",
	"logstats.lua",
}

-- 8 files x ~390 KB per join, on a host running dozens of clients, is thousands of
-- requests an hour against one IP. GitHub rate-limits that, and `game:HttpGet`
-- RAISES on failure -- so a single transient response used to kill the entire
-- client for the rest of the session, silently, with Config.lua the most damaging
-- place for it to happen because nothing at all runs after that.
--
-- Retry with backoff, and say so on the trace channel. A capture must show whether
-- a file needed retries even when the run eventually succeeded, because that is the
-- early warning that the host is being throttled.
local maximumAttempts = math.max(1, tonumber(environment.AnimeOriginLoaderDownloadRetries) or 3)
local retryBackoff = math.max(0, tonumber(environment.AnimeOriginLoaderRetryBackoff) or 2)

local function downloadSource(fileName)
	local url = RAW_ROOT .. fileName
	local lastError
	for attempt = 1, maximumAttempts do
		local startedAt = os.clock()
		local ok, result = pcall(game.HttpGet, game, url, true)
		if ok and typeof(result) == "string" and #result > 0 then
			return result, attempt, os.clock() - startedAt
		end
		-- An empty 200 is a real failure mode behind a throttling proxy and would
		-- otherwise compile into an empty chunk that does nothing at all.
		lastError = ok and "empty response body" or tostring(result)
		trace(string.format("download %s FAILED (attempt %d/%d)", fileName, attempt, maximumAttempts),
			{ error = lastError })
		if attempt < maximumAttempts then
			task.wait(retryBackoff * attempt)
		end
	end
	return nil, maximumAttempts, 0, lastError
end

local function downloadChunk(fileName, index, total)
	local source, attempts, elapsed, downloadError = downloadSource(fileName)
	if not source then
		trace(string.format("ABORT at %d/%d %s: download failed after %d attempts",
			index, total, fileName, maximumAttempts), { error = downloadError })
		error(string.format("[AnimeOriginLoader] Download failed for %s: %s",
			fileName, tostring(downloadError)), 0)
	end
	local chunk, compileError = loadstring(source, "AnimeOrigin." .. fileName)
	if not chunk then
		trace(string.format("ABORT at %d/%d %s: compile failed", index, total, fileName),
			{ error = tostring(compileError) })
		error(string.format("[AnimeOriginLoader] Compile failed for %s: %s", fileName, tostring(compileError)), 0)
	end
	trace(string.format("download %d/%d %s ok", index, total, fileName), {
		kb = string.format("%.1f", #source / 1024),
		seconds = string.format("%.2f", elapsed),
		-- Only interesting when > 1, but always present so a capture can be diffed
		-- across clients to see which hosts are being throttled hardest.
		attempts = attempts,
	})
	return chunk
end

-- Config publishes the shared table and must complete first. Every remaining
-- controller is started in its own task, matching separate Auto-Execute files;
-- a long-running AutoPlay loop therefore cannot block Optimizer or logstats.
local totalFiles = #workerFiles + 1
local configChunk = downloadChunk("Config.lua", 1, totalFiles)
local configOk, configError = pcall(configChunk)
if not configOk then
	trace("ABORT: Config.lua raised on execution", { error = tostring(configError) })
	error("[AnimeOriginLoader] Config.lua failed: " .. tostring(configError), 0)
end
trace("Config.lua executed")

-- The diagnostics recorder loads next so it can observe the seven workers below.
-- Its download is deliberately NON-FATAL, unlike every other file here: a recorder
-- that can abort the loader would be a new way for the farm to die, and the whole
-- reason it exists is that the farm keeps dying in ways nothing records. A client
-- that fails this download still farms normally; it just produces a console capture
-- instead of a folder capture, and the line below says which happened.
do
	local source = downloadSource("Diag.lua")
	local chunk = source and loadstring(source, "AnimeOrigin.Diag.lua") or nil
	local ok = false
	if chunk then
		ok = pcall(chunk)
	end
	if ok and typeof(environment.AnimeOriginDiag) == "table" then
		trace("Diag.lua ready", { folder = environment.AnimeOriginDiag.folder })
	else
		trace("Diag.lua UNAVAILABLE; continuing without folder diagnostics", {
			downloaded = source ~= nil,
			compiled = chunk ~= nil,
		})
	end
end

-- A worker publishes RUNNING early, then runs hundreds of lines of module-scope
-- initialisation before its own xpcall exists. A raw error in that window --
-- a failed assert, an index into a folder that has not replicated -- unwinds past
-- every publish site the worker has, so nothing terminal is ever written and its
-- lifecycle entry stays RUNNING forever. main.lua cannot distinguish that from a
-- worker that is merely slow, so it waits out the whole bootstrap gate and the
-- account stands in the lobby.
--
-- The Loader is the one place that sees every such failure, so it reports them.
-- Only a non-terminal entry is overwritten: a worker that already published its own
-- FAILED (with a real stage and message) keeps that more specific record.
local function publishWorkerFailure(fileName, runtimeError)
	local taskName = fileName:gsub("%.lua$", "")
	local lifecycle = environment.AnimeOriginLifecycle
	if typeof(lifecycle) ~= "table" or lifecycle.jobId ~= game.JobId then return end
	if typeof(lifecycle.tasks) ~= "table" then return end
	local entry = lifecycle.tasks[taskName]
	local status = typeof(entry) == "table" and tostring(entry.status) or nil
	if status == "COMPLETE" or status == "SKIPPED" or status == "FAILED" then return end
	local details = {
		phase = "loader",
		error = tostring(runtimeError),
		reason = "the worker raised before it could publish a terminal signal",
	}
	lifecycle.tasks[taskName] = {
		status = "FAILED",
		updatedAt = os.time(),
		userId = entry and entry.userId or (game:GetService("Players").LocalPlayer
			and game:GetService("Players").LocalPlayer.UserId or nil),
		details = details,
	}
	-- Record the same thing as a signal edge. This is the head of the most damaging
	-- chain the project has: a worker dies here, main's gate waits out a task that
	-- will never report, and the account stands in the lobby until the host restarts.
	local diag = environment.AnimeOriginDiag
	if typeof(diag) == "table" and typeof(diag.signal) == "function" then
		diag.signal("lifecycle." .. taskName, "FAILED", details, "Loader")
	end
end

-- Downloads stay sequential so one throttled response cannot be mistaken for eight,
-- but each worker RUNS in its own task: a long AutoPlay loop must not delay the
-- download of Optimizer and logstats behind it.
local function diagStep(name, opts)
	local diag = environment.AnimeOriginDiag
	if typeof(diag) == "table" and typeof(diag.step) == "function" then
		return diag.step(name, opts)
	end
	return { ok = function() end, noop = function() end, fail = function() end }
end

for index, fileName in ipairs(workerFiles) do
	-- The download and the worker's own module-scope initialisation are separate
	-- steps because they fail for unrelated reasons and one capture must tell them
	-- apart: a failed download is a throttled host, a failed init is a bug in the file.
	local downloadStep = diagStep("Loader.download:" .. fileName, {
		expect = "the file compiles into a chunk",
		deadline = 60,
	})
	local chunk = downloadChunk(fileName, index + 1, totalFiles)
	downloadStep.ok()

	task.spawn(function()
		local initStep = diagStep("Loader.init:" .. fileName, {
			expect = "the worker reaches its own main loop without raising",
			deadline = 120,
		})
		local ok, runtimeError = pcall(chunk)
		if not ok then
			initStep.fail(runtimeError)
			pcall(publishWorkerFailure, fileName, runtimeError)
			trace(string.format("worker %s RAISED", fileName), { error = tostring(runtimeError) })
			error(string.format("[AnimeOriginLoader] Runtime failed at worker %d/%d %s: %s",
				index, #workerFiles, fileName, tostring(runtimeError)), 0)
		end
		initStep.ok()
	end)
end

-- The line that says the Loader itself finished its job. Anything wrong after this
-- point belongs to a controller, and the trace tag on the next line will name it.
trace(string.format("ready: %d/%d files loaded", totalFiles, totalFiles), {
	elapsed = string.format("%.1fs", os.clock() - traceEpoch),
})

return true
