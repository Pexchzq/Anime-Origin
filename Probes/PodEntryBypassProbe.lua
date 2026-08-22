--[[
	Anime Origin Story Pod entry bypass probe

	Question this answers: the server only accepts MapSelectRemote "StartSelection"
	after the player has entered a Story Pod. Can that entry be produced without
	walking the character there?

	It first reports HOW the Pod detects entry, which decides whether a bypass is
	even possible:

	  * a TouchTransmitter child on DoorUIPart means something has connected
	    .Touched to it, and firetouchinterest can raise that event directly;
	  * a ClickDetector or ProximityPrompt means the trigger is fireclickdetector
	    or fireproximityprompt instead;
	  * none of those means detection is a position/region check on the server,
	    which no client-side call can fake -- the character genuinely has to be
	    inside, and the walk is the only route.

	Then it tries each applicable method against the nearest door and waits for the
	server's own MapSelect. Nothing is assumed: the probe reports only what the
	server actually replied.

	Safe by default. It never moves the character and stops at proof that the gate
	opened. It does not fire StartTeleport unless you ask for it:

		getgenv().AnimeOriginPodProbeTeleport = true

	Output: AnimeOrigin_PodEntryBypass.json  (and printed to the console)
]]

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local HttpService = game:GetService("HttpService")
local Workspace = game:GetService("Workspace")

local player = Players.LocalPlayer
local OUTPUT = "AnimeOrigin_PodEntryBypass.json"
local SETTLE = 2.5 -- seconds to wait for the server after each attempt

local report = {
	userId = player.UserId,
	placeId = game.PlaceId,
	startedAt = os.time(),
	executor = {},
	doors = {},
	attempts = {},
	conclusion = nil,
}

local function say(message)
	print("[PodEntryProbe] " .. message)
end

local function save()
	local ok, encoded = pcall(HttpService.JSONEncode, HttpService, report)
	if ok and typeof(writefile) == "function" then pcall(writefile, OUTPUT, encoded) end
end

-- ---------------------------------------------------------------- executor API

report.executor.firetouchinterest = typeof(firetouchinterest) == "function"
report.executor.fireclickdetector = typeof(fireclickdetector) == "function"
report.executor.fireproximityprompt = typeof(fireproximityprompt) == "function"
report.executor.getconnections = typeof(getconnections) == "function"
say("executor support: " .. HttpService:JSONEncode(report.executor))

-- ------------------------------------------------------------------ the doors

local storyRoot = Workspace:FindFirstChild("MainFolder")
storyRoot = storyRoot and storyRoot:FindFirstChild("Lobby")
storyRoot = storyRoot and storyRoot:FindFirstChild("MapSelectors")
storyRoot = storyRoot and storyRoot:FindFirstChild("Story")
if not storyRoot then
	report.conclusion = "Story MapSelectors folder was not found; run this in the lobby."
	say(report.conclusion)
	save()
	return
end

local character = player.Character or player.CharacterAdded:Wait()
local root = character:WaitForChild("HumanoidRootPart", 10)
if not root then
	report.conclusion = "HumanoidRootPart missing."
	say(report.conclusion)
	save()
	return
end

-- Describe every door and, crucially, what kind of trigger sits on or beside it.
local doors = {}
for _, descendant in ipairs(storyRoot:GetDescendants()) do
	if descendant:IsA("BasePart") and descendant.Name == "DoorUIPart" then
		local pod = descendant.Parent
		local triggers = {}
		local scanRoots = { descendant }
		if pod then table.insert(scanRoots, pod) end
		for _, scanRoot in ipairs(scanRoots) do
			for _, child in ipairs(scanRoot:GetDescendants()) do
				local class = child.ClassName
				if class == "TouchTransmitter" or class == "ClickDetector"
					or class == "ProximityPrompt" then
					table.insert(triggers, { class = class, name = child.Name,
						path = child:GetFullName(), instance = child })
				end
			end
		end
		local entry = {
			position = string.format("%.1f,%.1f,%.1f",
				descendant.Position.X, descendant.Position.Y, descendant.Position.Z),
			canTouch = descendant.CanTouch,
			canCollide = descendant.CanCollide,
			anchored = descendant.Anchored,
			distance = math.floor((root.Position - descendant.Position).Magnitude),
			podChildren = {},
			triggers = {},
			part = descendant,
			triggerInstances = triggers,
		}
		if pod then
			for _, child in ipairs(pod:GetChildren()) do
				table.insert(entry.podChildren, child.Name .. ":" .. child.ClassName)
			end
		end
		for _, trigger in ipairs(triggers) do
			table.insert(entry.triggers, trigger.class .. " @ " .. trigger.path)
		end
		table.insert(doors, entry)
	end
end

table.sort(doors, function(left, right) return left.distance < right.distance end)
for _, door in ipairs(doors) do
	table.insert(report.doors, {
		position = door.position, canTouch = door.canTouch, canCollide = door.canCollide,
		anchored = door.anchored, distance = door.distance,
		podChildren = door.podChildren, triggers = door.triggers,
	})
end
say(string.format("found %d door(s); nearest is %d studs away", #doors, doors[1] and doors[1].distance or -1))
save()

if #doors == 0 then
	report.conclusion = "No DoorUIPart found under Story."
	say(report.conclusion)
	save()
	return
end

local target = doors[1]
say("nearest door pod contains: " .. table.concat(target.podChildren, ", "))
say("triggers on/around it: " .. (#target.triggers > 0 and table.concat(target.triggers, ", ") or "NONE"))

-- ------------------------------------------------------- listen for the server

local mapRemote = ReplicatedStorage:FindFirstChild("LobbyRemotes")
mapRemote = mapRemote and mapRemote:FindFirstChild("MapSelectRemote")
if not mapRemote then
	report.conclusion = "MapSelectRemote not found."
	say(report.conclusion)
	save()
	return
end

local observed = { mapSelect = 0, afterMapSelect = 0, playersInside = 0, events = {} }
local connection = mapRemote.OnClientEvent:Connect(function(action, ...)
	if action == "MapSelect" then observed.mapSelect += 1 end
	if action == "AfterMapSelect" then observed.afterMapSelect += 1 end
	if action == "UpdatePlayersInside" then observed.playersInside += 1 end
	table.insert(observed.events, { at = os.clock(), action = tostring(action) })
	say("server -> " .. tostring(action))
end)

local function snapshot()
	return { mapSelect = observed.mapSelect, afterMapSelect = observed.afterMapSelect,
		playersInside = observed.playersInside }
end

-- Run one candidate method and report whether the server reacted to it.
local function attempt(name, note, action)
	local before = snapshot()
	local ok, err = pcall(action)
	local deadline = os.clock() + SETTLE
	repeat task.wait(0.1) until os.clock() >= deadline
		or observed.mapSelect > before.mapSelect
		or observed.playersInside > before.playersInside
	local after = snapshot()
	local opened = after.mapSelect > before.mapSelect or after.playersInside > before.playersInside
	local record = {
		method = name, note = note, invoked = ok, error = not ok and tostring(err) or nil,
		mapSelectBefore = before.mapSelect, mapSelectAfter = after.mapSelect,
		playersInsideBefore = before.playersInside, playersInsideAfter = after.playersInside,
		gateOpened = opened,
	}
	table.insert(report.attempts, record)
	say(string.format("%-34s invoked=%s  MapSelect %d->%d  UpdatePlayersInside %d->%d  %s",
		name, tostring(ok), before.mapSelect, after.mapSelect,
		before.playersInside, after.playersInside, opened and "<<< GATE OPENED" or "no reaction"))
	save()
	return opened
end

-- ------------------------------------------------------------- the attempts

local door = target.part
local winner = nil

if report.executor.firetouchinterest then
	-- Touched replicates from the character's own parts, so try a leg as well as
	-- the root: some doors only register a foot-height contact.
	local touchers = { { "HumanoidRootPart", root } }
	for _, partName in ipairs({ "LeftFoot", "RightFoot", "Left Leg", "Right Leg", "Torso", "UpperTorso" }) do
		local part = character:FindFirstChild(partName)
		if part and part:IsA("BasePart") then table.insert(touchers, { partName, part }) end
	end

	for _, pair in ipairs(touchers) do
		if winner then break end
		local label, part = pair[1], pair[2]
		if attempt("firetouchinterest(" .. label .. ", door)", "toucher first", function()
			firetouchinterest(part, door, 0)
			task.wait(0.15)
			firetouchinterest(part, door, 1)
		end) then winner = "firetouchinterest(" .. label .. ", door)" end

		if not winner and attempt("firetouchinterest(door, " .. label .. ")", "door first", function()
			firetouchinterest(door, part, 0)
			task.wait(0.15)
			firetouchinterest(door, part, 1)
		end) then winner = "firetouchinterest(door, " .. label .. ")" end

		-- Some handlers only run while the touch is held open.
		if not winner and attempt("firetouchinterest hold 1s (" .. label .. ")", "held open", function()
			firetouchinterest(part, door, 0)
			task.wait(1)
			firetouchinterest(part, door, 1)
		end) then winner = "firetouchinterest hold (" .. label .. ")" end
	end
else
	table.insert(report.attempts, { method = "firetouchinterest", invoked = false,
		error = "not provided by this executor" })
	say("firetouchinterest is NOT available on this executor; skipping touch tests")
end

for _, trigger in ipairs(target.triggerInstances) do
	if winner then break end
	if trigger.class == "ClickDetector" and report.executor.fireclickdetector then
		if attempt("fireclickdetector " .. trigger.name, trigger.path, function()
			fireclickdetector(trigger.instance)
		end) then winner = "fireclickdetector " .. trigger.name end
	elseif trigger.class == "ProximityPrompt" and report.executor.fireproximityprompt then
		if attempt("fireproximityprompt " .. trigger.name, trigger.path, function()
			fireproximityprompt(trigger.instance)
		end) then winner = "fireproximityprompt " .. trigger.name end
	end
end

-- ------------------------------------------------------------------ verdict

if winner then
	report.winningMethod = winner
	say("GATE OPENED BY: " .. winner .. " -- now testing whether StartSelection is accepted")
	local before = observed.afterMapSelect
	mapRemote:FireServer("StartSelection", "Story", "WestCity", "1", "Normal")
	local deadline = os.clock() + 6
	repeat task.wait(0.1) until os.clock() >= deadline or observed.afterMapSelect > before
	report.startSelectionAccepted = observed.afterMapSelect > before

	if report.startSelectionAccepted then
		report.conclusion = "BYPASS WORKS: " .. winner
			.. " produced server entry evidence and StartSelection was accepted."
		say(report.conclusion)
		if getgenv().AnimeOriginPodProbeTeleport == true then
			say("AnimeOriginPodProbeTeleport is set; firing StartTeleport")
			mapRemote:FireServer("StartTeleport")
			task.wait(3)
			report.teleportFired = true
		else
			say("StartTeleport NOT fired. Set getgenv().AnimeOriginPodProbeTeleport = true to complete entry.")
		end
	else
		report.conclusion = "PARTIAL: " .. winner .. " produced entry evidence, but StartSelection "
			.. "was still refused -- something beyond Pod entry is gating a fresh account."
		say(report.conclusion)
	end
else
	local hasTouchTransmitter = false
	for _, trigger in ipairs(target.triggerInstances) do
		if trigger.class == "TouchTransmitter" then hasTouchTransmitter = true end
	end
	if not report.executor.firetouchinterest then
		report.conclusion = "INCONCLUSIVE: this executor does not provide firetouchinterest, so the "
			.. "touch route could not be tested here. Re-run on the executor that will run the bot."
	elseif hasTouchTransmitter then
		report.conclusion = "NO BYPASS: DoorUIPart has a TouchTransmitter (something is connected to "
			.. ".Touched) yet a fired touch produced no MapSelect. The handler is most likely "
			.. "validating the character's real position, not just the touch."
	else
		report.conclusion = "NO BYPASS AND NO TOUCH HANDLER: DoorUIPart carries no TouchTransmitter, "
			.. "ClickDetector or ProximityPrompt, so Pod entry is not event-driven at all. The "
			.. "server is running its own position/region check, which a client call cannot fake; "
			.. "the character has to actually be inside."
	end
	say(report.conclusion)
end

report.observedEvents = observed.events
report.finishedAt = os.time()
save()
connection:Disconnect()
say("report written to " .. OUTPUT)
