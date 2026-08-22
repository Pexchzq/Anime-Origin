--[[
	Read-only Anime Origin performance baseline probe.

	Run manually in the lobby, at match start, at the target wave and again in the
	second match. It samples frame time for a short window, counts visual instances
	once at each boundary, then writes one compact JSON file to the executor workspace.
]]

local HttpService = game:GetService("HttpService")
local RunService = game:GetService("RunService")
local Stats = game:GetService("Stats")

local sampleSeconds = 10
local frameTimes = {}

local function memoryMb()
	local ok, value = pcall(function() return Stats:GetTotalMemoryUsageMb() end)
	return ok and value or nil
end

local function luaHeapKb()
	-- gcinfo is the supported Luau heap-size API and does not trigger collection.
	local ok, value = pcall(gcinfo)
	return ok and value or nil
end

local function instanceSnapshot()
	local counts = {
		total = 0,
		BasePart = 0,
		ParticleEmitter = 0,
		Trail = 0,
		Beam = 0,
		Light = 0,
		Sound = 0,
		Texture = 0,
		Decal = 0,
		PostEffect = 0,
	}
	for _, instance in ipairs(game:GetDescendants()) do
		counts.total += 1
		for className in pairs(counts) do
			if className ~= "total" and instance:IsA(className) then
				counts[className] += 1
			end
		end
	end
	return counts
end

local before = {
	memoryMb = memoryMb(),
	luaHeapKb = luaHeapKb(),
	instances = instanceSnapshot(),
}

local connection
connection = RunService.RenderStepped:Connect(function(delta)
	if delta > 0 and delta < 1 then table.insert(frameTimes, delta) end
end)
task.wait(sampleSeconds)
connection:Disconnect()

table.sort(frameTimes)
local sum = 0
for _, value in ipairs(frameTimes) do sum += value end
local median = #frameTimes > 0 and frameTimes[math.ceil(#frameTimes / 2)] or nil
local average = #frameTimes > 0 and sum / #frameTimes or nil
local report = {
	version = 1,
	jobId = game.JobId,
	placeId = game.PlaceId,
	capturedAt = os.time(),
	sampleSeconds = sampleSeconds,
	frames = #frameTimes,
	averageFps = average and 1 / average or nil,
	medianFps = median and 1 / median or nil,
	averageFrameMs = average and average * 1000 or nil,
	medianFrameMs = median and median * 1000 or nil,
	before = before,
	after = {
		memoryMb = memoryMb(),
		luaHeapKb = luaHeapKb(),
		instances = instanceSnapshot(),
	},
	optimizer = getgenv().AnimeOriginOptimizer and getgenv().AnimeOriginOptimizer.report or nil,
}

if typeof(makefolder) == "function" and typeof(isfolder) == "function" and not isfolder("AnimeOrigin") then
	makefolder("AnimeOrigin")
end
local file = "AnimeOrigin/PerformanceProbe_" .. tostring(game.PlaceId) .. "_" .. tostring(os.time()) .. ".json"
if typeof(writefile) == "function" then writefile(file, HttpService:JSONEncode(report)) end
getgenv().AnimeOriginPerformanceProbe = report
print("[PerformanceProbe]", HttpService:JSONEncode(report))
print("[PerformanceProbe][FILE]", file)
return report
