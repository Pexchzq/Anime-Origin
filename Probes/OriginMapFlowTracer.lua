--[[
	Anime Origin safe map-flow observer (diagnostic only)

	Run this in the lobby BEFORE opening the stage-selection UI. Then perform the
	whole flow manually: open selection, choose Story/WestCity/Act 1/Normal, and
	press Start. This version never hooks __namecall and never runs a Workspace
	scan inside a game callback. It observes GUI signals, incoming server events,
	selection-state changes, and teleport state without intercepting remotes.

	Output: AnimeOrigin_MapFlowTrace.jsonl
	Stop: getgenv().AnimeOriginMapFlowTracer.stop()
]]

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local HttpService = game:GetService("HttpService")
local Workspace = game:GetService("Workspace")

local player = Players.LocalPlayer
local outputFile = "AnimeOrigin_MapFlowTrace.jsonl"
local active = true
local sequence = 0
local connections = {}
local selectionSnapshot

-- Stop an older copy before installing new listeners. Re-running the tracer
-- should produce one clean record per event instead of duplicate evidence.
local previousController = getgenv().AnimeOriginMapFlowTracer
if typeof(previousController) == "table" and typeof(previousController.stop) == "function" then
	pcall(previousController.stop)
end

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
	if kind ~= "table" then return { type = kind, value = tostring(value) } end
	if visited[value] then return "<circular>" end
	if depth >= 5 then return "<max-depth>" end
	visited[value] = true
	local result, count = {}, 0
	for key, child in next, value do
		count += 1
		if count > 250 then result._truncated = true; break end
		result[tostring(key)] = serialize(child, depth + 1, visited)
	end
	visited[value] = nil
	return result
end

local function append(kind, data)
	if not active then return end
	sequence += 1
	local record = {
		sequence = sequence,
		kind = kind,
		time = os.clock(),
		data = data,
	}
	local line = HttpService:JSONEncode(record) .. "\n"
	if typeof(appendfile) == "function" then appendfile(outputFile, line)
	elseif typeof(writefile) == "function" then writefile(outputFile, line) end
	print("[OriginMapTrace] " .. kind)
end

local function readProperty(instance, property)
	local ok, value = pcall(function() return instance[property] end)
	return ok and value or nil
end

-- Capture the physical lobby context at the exact moment the server confirms
-- that the player entered Map Select. FastMode can later locate the same zone
-- by instance path instead of relying on a fixed coordinate.
local function characterContext()
	local character = player.Character
	local root = character and character:FindFirstChild("HumanoidRootPart")
	if not root then return { characterFound = character ~= nil, rootFound = false } end

	local nearby = {}
	for _, instance in ipairs(Workspace:GetDescendants()) do
		if instance:IsA("BasePart") and not instance:IsDescendantOf(character) then
			local distance = (instance.Position - root.Position).Magnitude
			if distance <= 35 then
				table.insert(nearby, {
					path = safePath(instance),
					name = instance.Name,
					class = instance.ClassName,
					distance = distance,
					position = serialize(instance.Position),
					size = serialize(instance.Size),
					canTouch = instance.CanTouch,
					canCollide = instance.CanCollide,
					transparency = instance.Transparency,
					attributes = serialize(instance:GetAttributes()),
				})
			end
		end
	end
	table.sort(nearby, function(left, right) return left.distance < right.distance end)
	while #nearby > 120 do table.remove(nearby) end

	return {
		characterFound = true,
		rootFound = true,
		rootPath = safePath(root),
		rootPosition = serialize(root.Position),
		rootCFrame = tostring(root.CFrame),
		nearbyParts = nearby,
	}
end

local function buttonText(button)
	if button:IsA("TextButton") then return button.Text end
	local pieces = {}
	for _, child in ipairs(button:GetDescendants()) do
		if child:IsA("TextLabel") and child.Text ~= "" then table.insert(pieces, child.Text) end
	end
	return table.concat(pieces, " | ")
end

-- Preserve visible text around the Start click. Server validation failures are
-- often shown through a notification remote or a short-lived text label rather
-- than returned through MapSelectRemote itself.
local function visibleTextSnapshot()
	local result = {}
	local playerGui = player:FindFirstChild("PlayerGui")
	if not playerGui then return result end
	for _, instance in ipairs(playerGui:GetDescendants()) do
		if (instance:IsA("TextLabel") or instance:IsA("TextButton") or instance:IsA("TextBox"))
			and instance.Visible and instance.Text ~= "" then
			table.insert(result, {
				path = safePath(instance),
				text = instance.Text,
			})
			if #result >= 300 then break end
		end
	end
	return result
end

-- Record the GUI signal independently from the game's own callback. If the
-- click is present but no remote follows, the callback/prerequisite failed; if
-- the click itself is absent, the input never reached the intended button.
local watchedButtons = setmetatable({}, { __mode = "k" })
local function watchButton(button)
	if watchedButtons[button] or not button:IsA("GuiButton") then return end
	watchedButtons[button] = true
	table.insert(connections, button.Activated:Connect(function(inputObject, clickCount)
		local textValue = buttonText(button)
		local callbackCount
		if typeof(getconnections) == "function" then
			local ok, callbacks = pcall(getconnections, button.Activated)
			if ok and typeof(callbacks) == "table" then callbackCount = #callbacks end
		end
		append("GUI_BUTTON_ACTIVATED", {
			path = safePath(button),
			text = textValue,
			visible = readProperty(button, "Visible"),
			active = readProperty(button, "Active"),
			interactable = readProperty(button, "Interactable"),
			clickCount = clickCount,
			callbackCount = callbackCount,
			selection = selectionSnapshot(),
		})

		if string.lower(textValue) == "start" then
			-- Defer snapshots so this observer returns from Activated immediately
			-- and cannot delay the game's own Start callback.
			for _, delaySeconds in ipairs({ 0, 0.25, 1, 3 }) do
				task.delay(delaySeconds, function()
					if active then
						append("START_UI_SNAPSHOT", {
							delay = delaySeconds,
							visibleText = visibleTextSnapshot(),
						})
					end
				end)
			end
		end
	end))
end

if typeof(writefile) == "function" then writefile(outputFile, "") end

-- Locate the loaded local selection state without opening any UI. This table
-- was previously observed with all five Selected* keys in one runtime object.
local selectionState
if typeof(getgc) == "function" then
	local ok, objects = pcall(getgc, true)
	if ok and typeof(objects) == "table" then
		for _, object in ipairs(objects) do
			if typeof(object) == "table"
				and rawget(object, "SelectedStageType") ~= nil
				and rawget(object, "SelectedAct") ~= nil
				and rawget(object, "SelectedDifficulty") ~= nil
				and rawget(object, "SelectedWorld") ~= nil
				and rawget(object, "SelectedGameMode") ~= nil then
				selectionState = object
				break
			end
		end
	end
end

selectionSnapshot = function()
	if not selectionState then return nil end
	return {
		SelectedStageType = serialize(rawget(selectionState, "SelectedStageType")),
		SelectedAct = serialize(rawget(selectionState, "SelectedAct")),
		SelectedDifficulty = serialize(rawget(selectionState, "SelectedDifficulty")),
		SelectedWorld = serialize(rawget(selectionState, "SelectedWorld")),
		SelectedGameMode = serialize(rawget(selectionState, "SelectedGameMode")),
	}
end

append("TRACE_STARTED", { selectionStateFound = selectionState ~= nil, selection = selectionSnapshot() })

if selectionState then
	local previous = HttpService:JSONEncode(selectionSnapshot())
	task.spawn(function()
		while active do
			task.wait(0.05)
			local snapshot = selectionSnapshot()
			local encoded = HttpService:JSONEncode(snapshot)
			if encoded ~= previous then
				previous = encoded
				append("SELECTION_STATE_CHANGED", snapshot)
			end
		end
	end)
end

local mapRemote = ReplicatedStorage:WaitForChild("LobbyRemotes"):WaitForChild("MapSelectRemote")
table.insert(connections, mapRemote.OnClientEvent:Connect(function(...)
	local packed = table.pack(...)
	local arguments = { count = packed.n }
	for index = 1, packed.n do arguments[tostring(index)] = serialize(packed[index]) end
	append("MAP_REMOTE_CLIENT_EVENT", {
		arguments = arguments,
		selection = selectionSnapshot(),
	})
	-- A full Workspace scan is deferred until after every game callback has had
	-- a chance to consume the same server event.
	task.defer(function()
		if active then append("MAP_CHARACTER_CONTEXT", characterContext()) end
	end)
end))

-- MapSelectRemote is not necessarily the channel used for validation errors.
-- Listen read-only to every other RemoteEvent so the rejecting server response
-- is persisted even when it is routed through a generic notification remote.
local watchedIncomingRemotes = setmetatable({}, { __mode = "k" })
local function watchIncomingRemote(remote)
	if watchedIncomingRemotes[remote] or remote == mapRemote or not remote:IsA("RemoteEvent") then return end
	watchedIncomingRemotes[remote] = true
	table.insert(connections, remote.OnClientEvent:Connect(function(...)
		local packed = table.pack(...)
		local arguments = { count = packed.n }
		for index = 1, packed.n do arguments[tostring(index)] = serialize(packed[index]) end
		append("INCOMING_REMOTE", {
			remotePath = safePath(remote),
			arguments = arguments,
		})
	end))
end

for _, instance in ipairs(ReplicatedStorage:GetDescendants()) do watchIncomingRemote(instance) end
table.insert(connections, ReplicatedStorage.DescendantAdded:Connect(function(instance)
	watchIncomingRemote(instance)
end))

local playerGui = player:WaitForChild("PlayerGui")
for _, instance in ipairs(playerGui:GetDescendants()) do watchButton(instance) end
table.insert(connections, playerGui.DescendantAdded:Connect(function(instance)
	watchButton(instance)
end))

table.insert(connections, player.OnTeleport:Connect(function(state, placeId, spawnName)
	append("TELEPORT_STATE", {
		state = tostring(state),
		placeId = placeId,
		spawnName = spawnName,
		selection = selectionSnapshot(),
	})
end))

local Controller = {}
function Controller.stop()
	active = false
	for _, connection in ipairs(connections) do pcall(function() connection:Disconnect() end) end
	print("[OriginMapTrace] stopped; records=" .. sequence)
end

getgenv().AnimeOriginMapFlowTracer = Controller
print("[OriginMapTrace] ACTIVE - now perform the complete map flow manually")
return Controller
