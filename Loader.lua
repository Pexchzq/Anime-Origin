--[[
	Anime Origin remote loader for executors such as Voit.

	The loader keeps the same dependency order as the verified MacSploit
	Auto-Execute setup. It also queues itself before a place transition so the
	lobby and in-stage controllers are rebuilt against the new Roblox runtime.
]]

local RAW_ROOT = "https://raw.githubusercontent.com/Pexchzq/Anime-Origin/main/"
local LOADER_URL = RAW_ROOT .. "Loader.lua"

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
	pcall(queueTeleport, string.format(
		'loadstring(game:HttpGet(%q, true), "AnimeOrigin.Loader")()',
		LOADER_URL
	))
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
if not game:IsLoaded() then
	local loadDeadline = os.clock() + (tonumber(getgenv().AnimeOriginLoaderLoadTimeout) or 120)
	repeat
		task.wait(0.2)
	until game:IsLoaded() or os.clock() >= loadDeadline
end

-- Every client on this machine reaches this point at the same moment, then all of
-- them download eight files and walk the whole Lua heap at once. That thundering
-- herd is what turns a busy host into failed attachments. Spread the start.
--
-- This waits only after the teleport queue above is armed: a place transition
-- during the delay must still bring the loader back, not drop it.
--
-- Raise it on a host running many clients:
--     getgenv().AnimeOriginLoaderJitter = 20
local jitter = tonumber(getgenv().AnimeOriginLoaderJitter) or 8
if jitter > 0 then
	task.wait(math.random() * jitter)
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

local function downloadChunk(fileName)
	local url = RAW_ROOT .. fileName
	local source = game:HttpGet(url, true)
	local chunk, compileError = loadstring(source, "AnimeOrigin." .. fileName)
	if not chunk then
		error(string.format("[AnimeOriginLoader] Compile failed for %s: %s", fileName, tostring(compileError)), 0)
	end
	return chunk
end

-- Config publishes the shared table and must complete first. Every remaining
-- controller is started in its own task, matching separate Auto-Execute files;
-- a long-running AutoPlay loop therefore cannot block Optimizer or logstats.
local configChunk = downloadChunk("Config.lua")
local configOk, configError = pcall(configChunk)
if not configOk then
	error("[AnimeOriginLoader] Config.lua failed: " .. tostring(configError), 0)
end

for index, fileName in ipairs(workerFiles) do
	local chunk = downloadChunk(fileName)
	task.spawn(function()
		local ok, runtimeError = pcall(chunk)
		if not ok then
			error(string.format("[AnimeOriginLoader] Runtime failed at worker %d/%d %s: %s",
				index, #workerFiles, fileName, tostring(runtimeError)), 0)
		end
	end)
end

return true
