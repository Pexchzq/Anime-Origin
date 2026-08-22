--[[
	Anime Origin transition remote tracer

	Run this file immediately before an action that may teleport, including the
	final Start button or Return To Lobby. Every FireServer and InvokeServer call
	is written to disk before the original call continues, so the outbound call
	remains recorded even when the current server closes immediately afterward.

	Outputs in the executor workspace:
	  AnimeOrigin_TransitionRemoteTrace.jsonl
	  AnimeOrigin_TransitionRemote_latest.json
	Stop manually with: getgenv().AnimeOriginStartRemoteTracer.stop()
]]

local HttpService = game:GetService("HttpService")
local outputFile = "AnimeOrigin_TransitionRemoteTrace.jsonl"
local latestFile = "AnimeOrigin_TransitionRemote_latest.json"
local environment = getgenv()

if environment.AnimeOriginStartRemoteTracer
	and environment.AnimeOriginStartRemoteTracer.stop then
	environment.AnimeOriginStartRemoteTracer.stop()
end

local active = true
local sequence = 0

local function safePath(instance)
	local ok, value = pcall(function() return instance:GetFullName() end)
	return ok and value or tostring(instance)
end

local function serialize(value, depth, visited)
	depth = depth or 0
	visited = visited or {}
	local kind = typeof(value)
	if kind == "nil" then return { type = "nil" } end
	if kind == "string" or kind == "number" or kind == "boolean" then return value end
	if kind == "Instance" then return { type = kind, path = safePath(value), class = value.ClassName } end
	if kind == "Vector3" then return { type = kind, x = value.X, y = value.Y, z = value.Z } end
	if kind == "CFrame" then return { type = kind, components = { value:GetComponents() } } end
	if kind ~= "table" then return { type = kind, value = tostring(value) } end
	if visited[value] then return "<circular>" end
	if depth >= 5 then return "<max-depth>" end
	visited[value] = true
	local output, count = {}, 0
	for key, child in next, value do
		count += 1
		if count > 200 then output._truncated = true; break end
		output[tostring(key)] = serialize(child, depth + 1, visited)
	end
	visited[value] = nil
	return output
end

local function persist(record)
	local encoded = HttpService:JSONEncode(record)
	-- Write the latest call first. This synchronous write completes before the
	-- original remote is allowed to teleport the client out of the current job.
	if typeof(writefile) == "function" then writefile(latestFile, encoded) end
	local line = encoded .. "\n"
	if typeof(appendfile) == "function" then
		appendfile(outputFile, line)
	elseif typeof(writefile) == "function" then
		-- Fallback retains at least the latest remote when appendfile is unavailable.
		writefile(outputFile, line)
	end
end

if typeof(writefile) == "function" then writefile(outputFile, "") end

local oldNamecall
oldNamecall = hookmetamethod(game, "__namecall", newcclosure(function(self, ...)
	local method = getnamecallmethod()
	if active and (method == "FireServer" or method == "InvokeServer")
		and typeof(self) == "Instance"
		and (self:IsA("RemoteEvent") or self:IsA("RemoteFunction")) then
		sequence += 1
		local packed = table.pack(...)
		local arguments = { count = packed.n }
		for index = 1, packed.n do arguments[tostring(index)] = serialize(packed[index]) end
		local record = {
			sequence = sequence,
			time = os.clock(),
			method = method,
			remotePath = safePath(self),
			arguments = arguments,
		}
		persist(record) -- Persist before allowing a possible teleport.
		print("[OriginStartTrace] " .. record.remotePath .. " " .. method)
	end
	return oldNamecall(self, ...)
end))

local Controller = {}
function Controller.stop()
	active = false
	print("[OriginStartTrace] stopped; captured " .. sequence .. " remotes")
end

environment.AnimeOriginStartRemoteTracer = Controller
print("[OriginStartTrace] active; press Start or Return To Lobby now")
return Controller
