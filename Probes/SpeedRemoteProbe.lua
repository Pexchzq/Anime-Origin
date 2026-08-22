--[[
	Anime Origin focused game-speed remote probe

	Run this file, then change Game Speed manually from the game's UI. The probe
	records only outgoing remotes whose path or string arguments contain "speed".
	It never changes, blocks, or replays the captured call.

	Output: AnimeOrigin/SpeedRemoteTrace.jsonl in the executor workspace.
	Stop with: getgenv().AnimeOriginSpeedRemoteProbe.stop()
]]

local HttpService = game:GetService("HttpService")
local environment = getgenv()
local outputFolder = "AnimeOrigin"
local outputFile = outputFolder .. "/SpeedRemoteTrace.jsonl"

-- Disable an older controller before publishing a fresh capture session. The
-- shared hook below remains installed but forwards records only to this session.
if environment.AnimeOriginSpeedRemoteProbe
	and environment.AnimeOriginSpeedRemoteProbe.stop then
	environment.AnimeOriginSpeedRemoteProbe.stop()
end

-- Keep executor filesystem setup optional so capture still works in consoles
-- that expose hooking APIs but do not expose file-writing APIs.
if typeof(makefolder) == "function" then
	local folderExists = typeof(isfolder) == "function" and isfolder(outputFolder)
	if not folderExists then
		pcall(makefolder, outputFolder)
	end
end

if typeof(writefile) == "function" then
	pcall(writefile, outputFile, "")
end

local Controller = {
	active = true,
	count = 0,
	records = {},
	outputFile = outputFile,
}

-- Convert Instance arguments and Roblox datatypes into JSON-safe evidence while
-- preserving the exact argument order and explicit nil values.
local function safePath(instance)
	local success, result = pcall(function()
		return instance:GetFullName()
	end)
	return success and result or tostring(instance)
end

local function serialize(value, depth, visited)
	depth = depth or 0
	visited = visited or {}
	local valueType = typeof(value)

	if valueType == "nil" then return { type = "nil" } end
	if valueType == "string" or valueType == "number" or valueType == "boolean" then return value end
	if valueType == "Instance" then
		return { type = "Instance", path = safePath(value), class = value.ClassName }
	end
	if valueType == "Vector3" then
		return { type = "Vector3", x = value.X, y = value.Y, z = value.Z }
	end
	if valueType == "CFrame" then
		return { type = "CFrame", components = { value:GetComponents() } }
	end
	if valueType ~= "table" then
		return { type = valueType, value = tostring(value) }
	end
	if visited[value] then return "<circular>" end
	if depth >= 5 then return "<max-depth>" end

	visited[value] = true
	local result = {}
	local count = 0
	for key, child in next, value do
		count += 1
		if count > 200 then
			result._truncated = true
			break
		end
		result[tostring(key)] = serialize(child, depth + 1, visited)
	end
	visited[value] = nil
	return result
end

-- Generic remotes such as Remotes.RemoteEvent are included when an argument is
-- "ChangeSpeed"; dedicated remotes are included when their own path says speed.
local function isSpeedCall(remote, arguments)
	if string.find(string.lower(safePath(remote)), "speed", 1, true) then
		return true
	end

	for index = 1, arguments.n do
		local value = arguments[index]
		if typeof(value) == "string"
			and string.find(string.lower(value), "speed", 1, true) then
			return true
		end
	end

	return false
end

-- Write before forwarding the original call so even a speed action that causes
-- an immediate state transition remains available for the next debugging pass.
local function persist(record)
	local encoded = HttpService:JSONEncode(record)
	if typeof(appendfile) == "function" then
		pcall(appendfile, outputFile, encoded .. "\n")
	elseif typeof(writefile) == "function" then
		local lines = {}
		for _, savedRecord in ipairs(Controller.records) do
			table.insert(lines, HttpService:JSONEncode(savedRecord))
		end
		pcall(writefile, outputFile, table.concat(lines, "\n") .. "\n")
	end
	return encoded
end

function Controller._capture(remote, method, packedArguments)
	if not Controller.active then return end
	if method ~= "FireServer" and method ~= "InvokeServer" then return end
	if typeof(remote) ~= "Instance" then return end
	if not remote:IsA("RemoteEvent") and not remote:IsA("RemoteFunction") then return end
	if not isSpeedCall(remote, packedArguments) then return end

	Controller.count += 1
	local arguments = { count = packedArguments.n }
	for index = 1, packedArguments.n do
		arguments[tostring(index)] = serialize(packedArguments[index])
	end

	local record = {
		sequence = Controller.count,
		unixTime = os.time(),
		clock = os.clock(),
		placeId = game.PlaceId,
		jobId = game.JobId,
		method = method,
		remotePath = safePath(remote),
		remoteClass = remote.ClassName,
		arguments = arguments,
	}

	table.insert(Controller.records, record)
	local encoded = persist(record)
	print("[SpeedRemoteProbe] " .. record.remotePath .. " " .. method .. " " .. encoded)
end

function Controller.stop()
	if not Controller.active then return end
	Controller.active = false
	warn("[SpeedRemoteProbe] stopped; captured " .. Controller.count
		.. " call(s); file: " .. outputFile)
end

environment.AnimeOriginSpeedRemoteProbe = Controller

-- Install only one permanent forwarding hook. Re-running this file replaces the
-- controller instead of stacking multiple hooks and duplicating every record.
if not environment.AnimeOriginSpeedRemoteHookInstalled then
	assert(typeof(hookmetamethod) == "function", "hookmetamethod is unavailable")
	assert(typeof(getnamecallmethod) == "function", "getnamecallmethod is unavailable")
	assert(typeof(newcclosure) == "function", "newcclosure is unavailable")

	local oldNamecall
	oldNamecall = hookmetamethod(game, "__namecall", newcclosure(function(self, ...)
		local method = getnamecallmethod()
		local calledByExecutor = typeof(checkcaller) == "function" and checkcaller() or false
		local current = getgenv().AnimeOriginSpeedRemoteProbe

		-- Ignore executor-originated calls so the trace shows only the game's normal
		-- UI/runtime callback, then always continue to the original metamethod.
		if not calledByExecutor and current and current.active and current._capture then
			local captureSuccess, captureError = pcall(current._capture, self, method, table.pack(...))
			if not captureSuccess then
				warn("[SpeedRemoteProbe] capture error: " .. tostring(captureError))
			end
		end

		return oldNamecall(self, ...)
	end))

	environment.AnimeOriginSpeedRemoteHookInstalled = true
end

warn("[SpeedRemoteProbe] active; change Game Speed manually, then call stop()")
return Controller
