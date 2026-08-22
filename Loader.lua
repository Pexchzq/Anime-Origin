--[[
	Anime Origin remote loader for executors such as Voit.

	The loader keeps the same dependency order as the verified MacSploit
	Auto-Execute setup. It also queues itself before a place transition so the
	lobby and in-stage controllers are rebuilt against the new Roblox runtime.
]]

local RAW_ROOT = "https://raw.githubusercontent.com/Pexchzq/Anime-Origin/main/"
local LOADER_URL = RAW_ROOT .. "Loader.lua"

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
