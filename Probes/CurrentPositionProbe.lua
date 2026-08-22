--[[
	Anime Origin current-position probe (read-only)

	Stand at the desired map point, then run this file. It reads the local
	character's HumanoidRootPart directly, prints a copy-ready Vector3 value,
	and saves both machine-readable JSON and copy-ready Lua in the executor
	workspace. No game UI needs to be open.
]]

local HttpService = game:GetService("HttpService")
local Players = game:GetService("Players")

local LocalPlayer = Players.LocalPlayer
assert(LocalPlayer, "LocalPlayer is unavailable.")
assert(typeof(writefile) == "function", "writefile is unavailable in this executor.")

-- Use a bounded wait so running during a respawn produces a useful error instead
-- of leaving the executor thread suspended forever.
local function waitForRootPart(timeout)
	local deadline = os.clock() + timeout
	repeat
		local character = LocalPlayer.Character
		local rootPart = character and character:FindFirstChild("HumanoidRootPart")
		if rootPart and rootPart:IsA("BasePart") then
			return character, rootPart
		end
		task.wait(0.1)
	until os.clock() >= deadline
	return nil, nil
end

-- Preserve more precision than Roblox's default Vector3 tostring output so the
-- saved value can be pasted into placement configuration without manual rounding.
local function formatNumber(value)
	return string.format("%.17g", value)
end

local character, rootPart = waitForRootPart(15)
assert(rootPart, "HumanoidRootPart was not found within 15 seconds.")

local position = rootPart.Position
local vector3Lua = string.format(
	"Vector3.new(%s, %s, %s)",
	formatNumber(position.X),
	formatNumber(position.Y),
	formatNumber(position.Z)
)

local Report = {
	version = 1,
	capturedAtUnix = os.time(),
	username = LocalPlayer.Name,
	userId = LocalPlayer.UserId,
	placeId = game.PlaceId,
	jobId = game.JobId,
	characterPath = character:GetFullName(),
	rootPartPath = rootPart:GetFullName(),
	position = {
		x = position.X,
		y = position.Y,
		z = position.Z,
	},
	vector3Lua = vector3Lua,
}

local json = HttpService:JSONEncode(Report)
local latestJsonPath = "AnimeOrigin_CurrentPosition.json"
local latestLuaPath = "AnimeOrigin_CurrentPosition.lua"
local historyPath = "AnimeOrigin_PositionHistory.jsonl"

-- The latest files are overwritten intentionally, while JSONL keeps every point
-- captured during the executor session for later map-configuration work.
writefile(latestJsonPath, json)
writefile(latestLuaPath, "-- Captured by Probes/CurrentPositionProbe.lua\nreturn " .. vector3Lua .. "\n")

if typeof(appendfile) == "function" then
	appendfile(historyPath, json .. "\n")
elseif typeof(isfile) == "function" and not isfile(historyPath) then
	-- Executors without appendfile still receive the first history record; the
	-- two latest files above remain authoritative on every subsequent run.
	writefile(historyPath, json .. "\n")
end

getgenv().AnimeOriginCurrentPosition = Report

print("[OriginPosition] " .. vector3Lua)
print("[OriginPosition][JSON] " .. latestJsonPath)
print("[OriginPosition][LUA] " .. latestLuaPath)
if typeof(appendfile) == "function" or (typeof(isfile) == "function" and isfile(historyPath)) then
	print("[OriginPosition][HISTORY] " .. historyPath)
end

return Report
