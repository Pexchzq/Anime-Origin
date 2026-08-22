--[[
	Anime Origin in-game discovery probe

	Purpose:
	  1. Verify the pre-match Confirm/start transition from server-side evidence.
	  2. Find non-UI candidates for current match money and match state.
	  3. Discover PlaceTower/UpgradeTower functions and remotes from loaded runtime
	     constants, then observe their follow-up state changes.
	  4. Identify the Workspace model and runtime table created for a placed unit.

	This version installs no __namecall or function hook. The earlier hook-based
	versions were retired after two clean sessions showed WaveVote leaving the UI
	while GameStarted remained false.

	Run this after entering a stage but before pressing Confirm. Perform one normal
	placement and at least two normal upgrades, then stop the probe with:

	getgenv().AnimeOriginInGameDiscovery.stop()

	Files in the executor workspace:
	  AnimeOrigin/InGameDiscoveryTrace.jsonl
	  AnimeOrigin/InGameDiscovery_latest.json
]]

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local CollectionService = game:GetService("CollectionService")
local HttpService = game:GetService("HttpService")

local player = Players.LocalPlayer
local playerGui = player:FindFirstChildOfClass("PlayerGui")
local environment = getgenv()
local outputFolder = "AnimeOrigin"
local traceFile = outputFolder .. "/InGameDiscoveryTrace.jsonl"
local summaryFile = outputFolder .. "/InGameDiscovery_latest.json"
local pollInterval = 0.2

-- Stop a previous observer before publishing a fresh session. V3 does not install
-- a new hook; the inactive proxy near the end only neutralizes older closures.
if environment.AnimeOriginInGameDiscovery
	and environment.AnimeOriginInGameDiscovery.stop then
	environment.AnimeOriginInGameDiscovery.stop()
end

if typeof(makefolder) == "function" then
	local exists = typeof(isfolder) == "function" and isfolder(outputFolder)
	if not exists then pcall(makefolder, outputFolder) end
end
if typeof(writefile) == "function" then
	pcall(writefile, traceFile, "")
end

local summary = {
	version = 3,
	hookMode = "none",
	startedAt = os.time(),
	userId = player.UserId,
	placeId = game.PlaceId,
	jobId = game.JobId,
	status = "STARTING",
	counts = {},
	incoming = {},
	runtimeChanges = {},
	instanceChanges = {},
	valueChanges = {},
	candidateScans = {},
	remoteInventory = {},
	actionFunctions = {},
	manualSteps = {
		"Press the in-stage Confirm button once.",
		"Place one damage unit normally.",
		"Upgrade that placed unit at least twice.",
		"Call getgenv().AnimeOriginInGameDiscovery.stop().",
	},
}

local Controller = {
	active = true,
	sequence = 0,
	records = {},
	connections = {},
	candidates = {},
	candidateById = {},
	summary = summary,
	traceFile = traceFile,
	summaryFile = summaryFile,
}

local function safePath(instance)
	local success, result = pcall(function()
		return instance:GetFullName()
	end)
	return success and result or tostring(instance)
end

-- Keep every trace JSON-safe and bounded. Exact primitive arguments, Vector3
-- placement positions and Instance paths remain intact for later implementation.
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
	if valueType == "Vector2" then
		return { type = "Vector2", x = value.X, y = value.Y }
	end
	if valueType == "CFrame" then
		return { type = "CFrame", components = { value:GetComponents() } }
	end
	if valueType == "Color3" then
		return { type = "Color3", r = value.R, g = value.G, b = value.B }
	end
	if valueType ~= "table" then
		return { type = valueType, value = tostring(value) }
	end
	if visited[value] then return "<circular>" end
	if depth >= 4 then return "<max-depth>" end

	visited[value] = true
	local result = {}
	local count = 0
	for key, child in next, value do
		count += 1
		if count > 100 then
			result._truncated = true
			break
		end
		result[tostring(key)] = serialize(child, depth + 1, visited)
	end
	visited[value] = nil
	return result
end

local function serializePacked(packed)
	local result = { count = packed.n }
	for index = 1, packed.n do
		result[tostring(index)] = serialize(packed[index])
	end
	return result
end

local function encode(value)
	local success, result = pcall(HttpService.JSONEncode, HttpService, value)
	return success and result or HttpService:JSONEncode({ encodingError = tostring(result) })
end

local function saveSummary(reason)
	summary.updatedAt = os.time()
	summary.reason = reason
	if typeof(writefile) == "function" then
		pcall(writefile, summaryFile, encode(summary))
	end
end

local function boundedInsert(target, value, maximum)
	table.insert(target, value)
	if #target > maximum then table.remove(target, 1) end
end

-- JSONL is the chronological source of truth. The compact summary is refreshed
-- separately so a teleport or executor console truncation cannot erase evidence.
local function emit(kind, data, quiet)
	Controller.sequence += 1
	summary.counts[kind] = (summary.counts[kind] or 0) + 1
	local record = {
		sequence = Controller.sequence,
		kind = kind,
		unixTime = os.time(),
		clock = os.clock(),
		data = data,
	}
	boundedInsert(Controller.records, record, 500)

	local line = encode(record) .. "\n"
	if typeof(appendfile) == "function" then
		pcall(appendfile, traceFile, line)
	elseif typeof(writefile) == "function" then
		local lines = {}
		for _, saved in ipairs(Controller.records) do
			table.insert(lines, encode(saved))
		end
		pcall(writefile, traceFile, table.concat(lines, "\n") .. "\n")
	end

	if not quiet then
		print("[InGameDiscovery][" .. string.upper(kind) .. "] " .. encode(data))
	end
	return record
end

local function normalize(value)
	return string.lower(tostring(value)):gsub("[^%w]", "")
end

local strongScalarNames = {
	money = true,
	cash = true,
	yen = true,
	currentmoney = true,
	playermoney = true,
	startingmoney = true,
	wave = true,
	currentwave = true,
	wavenumber = true,
	ready = true,
	started = true,
	gamestarted = true,
	matchstarted = true,
	gamestate = true,
	matchstate = true,
	gamephase = true,
	phase = true,
	-- Stage identity is required to bind a captured placement seed to the correct
	-- map instead of reusing one world's coordinates in another world.
	world = true,
	map = true,
	mapname = true,
	act = true,
	chapter = true,
	mode = true,
	difficulty = true,
	stageid = true,
	stagename = true,
}

local contextualNames = {
	upgrade = true,
	upgradelevel = true,
	upgradeindex = true,
	level = true,
	stage = true,
	owner = true,
	ownerid = true,
	player = true,
	playerid = true,
	uuid = true,
	toweruuid = true,
	unituuid = true,
	tower = true,
	unit = true,
	towerslot = true,
	slot = true,
	position = true,
	cframe = true,
}

local collectionNames = {
	placedtowers = true,
	placedunits = true,
	currenttowers = true,
	currentunits = true,
	playertowers = true,
	playerunits = true,
	towersplaced = true,
	unitsplaced = true,
}

-- Exact names keep the observer focused. Substring matching previously treated
-- GiveMoney, MoneyUnit and tooltip keys such as Tower1 as live match state,
-- creating hundreds of false candidates and unnecessary polling work.
local function isStrongScalarName(normalizedName)
	return strongScalarNames[normalizedName] == true
end

local function isContextualName(normalizedName)
	return contextualNames[normalizedName] == true
end

local function isCollectionName(normalizedName)
	if collectionNames[normalizedName] then return true end
	local placed = string.find(normalizedName, "placed", 1, true) ~= nil
	local towerOrUnit = string.find(normalizedName, "tower", 1, true)
		or string.find(normalizedName, "unit", 1, true)
	return placed and towerOrUnit ~= nil
end

local function tableContextScore(owner)
	if typeof(owner) ~= "table" then return 0 end
	local score = 0
	local inspected = 0
	for key in next, owner do
		inspected += 1
		if isContextualName(normalize(key)) then score += 1 end
		if inspected >= 120 then break end
	end
	return score
end

local function simpleSignature(value)
	local valueType = typeof(value)
	if valueType == "nil" then return "nil" end
	if valueType == "string" or valueType == "number" or valueType == "boolean" then
		return valueType .. ":" .. tostring(value)
	end
	if valueType == "Instance" then return "Instance:" .. safePath(value) end
	if valueType == "Vector3" then
		return string.format("Vector3:%.5f,%.5f,%.5f", value.X, value.Y, value.Z)
	end
	if valueType == "CFrame" then return "CFrame:" .. tostring(value) end
	if valueType ~= "table" then return valueType .. ":" .. tostring(value) end

	local pieces = {}
	local count = 0
	for key, child in next, value do
		count += 1
		if count > 80 then
			table.insert(pieces, "<truncated>")
			break
		end
		local childType = typeof(child)
		local childValue
		if childType == "string" or childType == "number" or childType == "boolean" then
			childValue = tostring(child)
		elseif childType == "Instance" then
			childValue = safePath(child)
		else
			childValue = childType .. ":" .. tostring(child)
		end
		table.insert(pieces, tostring(key) .. "=" .. childValue)
	end
	table.sort(pieces)
	return "table:" .. table.concat(pieces, "|")
end

local function candidateId(owner, key)
	return tostring(owner) .. "::" .. typeof(key) .. ":" .. tostring(key)
end

local function addCandidate(owner, key, path, reason)
	local id = candidateId(owner, key)
	if Controller.candidateById[id] then return false end
	if #Controller.candidates >= 800 then return false end

	local current = rawget(owner, key)
	local candidate = {
		id = id,
		owner = owner,
		key = key,
		path = path,
		reason = reason,
		lastSignature = simpleSignature(current),
		lastSerialized = serialize(current),
	}
	Controller.candidateById[id] = candidate
	table.insert(Controller.candidates, candidate)
	return true
end

-- getgc tables are inspected read-only. We retain references to strong scalar
-- and placed-unit candidates, then poll only those references instead of doing a
-- destructive or continuous full-game scan.
local discoveryRunning = false
local function discoverRuntimeCandidates(trigger)
	if discoveryRunning or not Controller.active then return end
	discoveryRunning = true
	local added = 0
	local scannedTables = 0

	if typeof(getgc) == "function" then
		local success, objects = pcall(getgc, true)
		if success and typeof(objects) == "table" then
			for index, object in ipairs(objects) do
				if not Controller.active then break end
				if typeof(object) == "table" then
					scannedTables += 1
					local contextScore = tableContextScore(object)
					local inspected = 0
					for key, value in next, object do
						inspected += 1
						if inspected > 250 then break end
						local normalizedKey = normalize(key)
						local valueType = typeof(value)
						local path = "getgc[" .. index .. "][" .. string.format("%q", tostring(key)) .. "]"

						if isStrongScalarName(normalizedKey)
							and (valueType == "string" or valueType == "number" or valueType == "boolean") then
							if addCandidate(object, key, path, "strong-scalar") then added += 1 end
						elseif isStrongScalarName(normalizedKey) and valueType == "table" then
							if addCandidate(object, key, path, "strong-table") then added += 1 end
						elseif isContextualName(normalizedKey)
							and contextScore >= 2
							and (valueType == "string" or valueType == "number" or valueType == "boolean"
								or valueType == "Vector3" or valueType == "CFrame" or valueType == "Instance") then
							if addCandidate(object, key, path, "placed-record-scalar") then added += 1 end
						elseif valueType == "table"
							and (isCollectionName(normalizedKey) or (contextScore >= 3 and isContextualName(normalizedKey))) then
							if addCandidate(object, key, path, "placed-record-table") then added += 1 end
						end
					end
				end
			end
		end
	end

	local sample = {}
	for index = math.max(1, #Controller.candidates - 39), #Controller.candidates do
		local candidate = Controller.candidates[index]
		if candidate then
			table.insert(sample, {
				path = candidate.path,
				reason = candidate.reason,
				value = candidate.lastSerialized,
			})
		end
	end
	local scan = {
		trigger = trigger,
		scannedTables = scannedTables,
		added = added,
		totalCandidates = #Controller.candidates,
		sample = sample,
	}
	boundedInsert(summary.candidateScans, scan, 20)
	emit("candidate-scan", scan, true)
	discoveryRunning = false
	saveSummary("Runtime candidate scan: " .. tostring(trigger))
	print(string.format("[InGameDiscovery][SCAN] %s: +%d, total %d candidates",
		tostring(trigger), added, #Controller.candidates))
end

local function pollRuntimeCandidates()
	for _, candidate in ipairs(Controller.candidates) do
		local success, current = pcall(rawget, candidate.owner, candidate.key)
		if success then
			local signature = simpleSignature(current)
			if signature ~= candidate.lastSignature then
				local change = {
					path = candidate.path,
					reason = candidate.reason,
					before = candidate.lastSerialized,
					after = serialize(current),
				}
				candidate.lastSignature = signature
				candidate.lastSerialized = change.after
				boundedInsert(summary.runtimeChanges, change, 300)
				emit("runtime-change", change, true)
			end
		end
	end
end

local function isNonUI(instance)
	if not playerGui then return true end
	local success, descendant = pcall(instance.IsDescendantOf, instance, playerGui)
	return not success or not descendant
end

local function isRelevantValue(instance)
	if not instance:IsA("ValueBase") or not isNonUI(instance) then return false end
	local name = normalize(instance.Name)
	return isStrongScalarName(name) or isContextualName(name)
end

local observedValues = setmetatable({}, { __mode = "k" })
local function observeValue(instance)
	if observedValues[instance] or not isRelevantValue(instance) then return end
	observedValues[instance] = true
	local previous = serialize(instance.Value)
	local connection = instance.Changed:Connect(function(value)
		if not Controller.active then return end
		local change = {
			path = safePath(instance),
			class = instance.ClassName,
			before = previous,
			after = serialize(value),
		}
		previous = change.after
		boundedInsert(summary.valueChanges, change, 300)
		emit("value-change", change, true)
		saveSummary("Replicated value changed")
	end)
	table.insert(Controller.connections, connection)
end

local function copyAttributes(instance)
	local result = {}
	local success, attributes = pcall(instance.GetAttributes, instance)
	if success then
		for key, value in pairs(attributes) do result[key] = serialize(value) end
	end
	return result
end

local function snapshotInstance(instance)
	local snapshot = {
		path = safePath(instance),
		class = instance.ClassName,
		name = instance.Name,
		attributes = copyAttributes(instance),
		tags = CollectionService:GetTags(instance),
		values = {},
	}
	if instance:IsA("Model") then
		local success, pivot = pcall(instance.GetPivot, instance)
		if success then snapshot.pivot = serialize(pivot) end
	elseif instance:IsA("BasePart") then
		snapshot.position = serialize(instance.Position)
		snapshot.size = serialize(instance.Size)
	end

	local count = 0
	for _, descendant in ipairs(instance:GetDescendants()) do
		if descendant:IsA("ValueBase") then
			count += 1
			snapshot.values[safePath(descendant)] = serialize(descendant.Value)
			if count >= 60 then
				snapshot.values._truncated = true
				break
			end
		end
	end
	return snapshot
end

-- Models created after a manual PlaceTower call are the strongest Workspace
-- evidence for the placed-unit registry. Capture them after a short settle time.
local function observeDescendantAdded(instance)
	if not Controller.active or not isNonUI(instance) then return end
	if instance:IsA("ValueBase") then observeValue(instance) end
	if not instance:IsA("Model") then return end

	task.delay(0.15, function()
		if not Controller.active or not instance.Parent then return end
		local change = snapshotInstance(instance)
		boundedInsert(summary.instanceChanges, change, 200)
		emit("workspace-model-added", change, true)
		saveSummary("Workspace model added")
	end)
end

local incomingLastSeen = {}
local observedRemotes = setmetatable({}, { __mode = "k" })
local function observeRemoteEvent(remote)
	if observedRemotes[remote] then return end
	observedRemotes[remote] = true
	local connection = remote.OnClientEvent:Connect(function(...)
		if not Controller.active then return end
		local packed = table.pack(...)
		local arguments = serializePacked(packed)
		local first = packed.n > 0 and tostring(packed[1]) or "<none>"
		local signature = safePath(remote) .. "::" .. first
		local now = os.clock()

		-- Repeated wave-vote ticks are sampled once per second while unique server
		-- responses remain complete.
		if incomingLastSeen[signature] and now - incomingLastSeen[signature] < 1 then return end
		incomingLastSeen[signature] = now
		local record = {
			remotePath = safePath(remote),
			remoteClass = remote.ClassName,
			arguments = arguments,
		}
		boundedInsert(summary.incoming, record, 300)
		emit("incoming-remote", record, true)
		saveSummary("Incoming server remote")
	end)
	table.insert(Controller.connections, connection)
end

local function observeReplicatedDescendant(instance)
	if instance:IsA("RemoteEvent") then observeRemoteEvent(instance) end
	if instance:IsA("ValueBase") then observeValue(instance) end
end

local actionTokens = {
	"placetower",
	"selecttower",
	"upgradetower",
	"upgrade",
	"selltower",
	"towerhandler",
	"wavevote",
	"startgame",
	"gamestarted",
	"confirm",
}

local function containsActionToken(value)
	local normalizedValue = normalize(value)
	for _, token in ipairs(actionTokens) do
		if string.find(normalizedValue, token, 1, true) then return true, token end
	end
	return false, nil
end

local function inspectFunction(functionValue, sourcePath, sourceKey, seenFunctions)
	if seenFunctions[functionValue] then return false end

	local keyMatched, keyToken = containsActionToken(sourceKey)
	local constants, matchedConstants = {}, {}
	if debug and typeof(debug.getconstants) == "function" then
		local success, rawConstants = pcall(debug.getconstants, functionValue)
		if success and typeof(rawConstants) == "table" then
			for _, constant in pairs(rawConstants) do
				if #constants >= 120 then break end
				if typeof(constant) == "string" or typeof(constant) == "number" or typeof(constant) == "boolean" then
					table.insert(constants, constant)
					local matched = containsActionToken(constant)
					if matched then table.insert(matchedConstants, constant) end
				end
			end
		end
	end
	if not keyMatched and #matchedConstants == 0 then return false end
	seenFunctions[functionValue] = true

	local info = {}
	if debug and typeof(debug.info) == "function" then
		local sourceSuccess, source = pcall(debug.info, functionValue, "s")
		local lineSuccess, line = pcall(debug.info, functionValue, "l")
		local nameSuccess, name = pcall(debug.info, functionValue, "n")
		if sourceSuccess then info.source = source end
		if lineSuccess then info.line = line end
		if nameSuccess then info.name = name end
	end

	-- Upvalues are summarized read-only. Remote Instances and action-named fields
	-- reveal the production seam without firing the callback or opening a UI panel.
	local upvalues = {}
	if debug and typeof(debug.getupvalues) == "function" then
		local success, rawUpvalues = pcall(debug.getupvalues, functionValue)
		if success and typeof(rawUpvalues) == "table" then
			for upvalueIndex, upvalue in pairs(rawUpvalues) do
				if #upvalues >= 40 then break end
				local upvalueType = typeof(upvalue)
				if upvalueType == "Instance"
					and (upvalue:IsA("RemoteEvent") or upvalue:IsA("RemoteFunction")) then
					table.insert(upvalues, { index = tostring(upvalueIndex), value = serialize(upvalue) })
				elseif upvalueType == "table" then
					local selected = {}
					local inspected = 0
					for key, child in next, upvalue do
						inspected += 1
						if inspected > 100 then break end
						local childMatches = containsActionToken(key)
						local childIsRemote = typeof(child) == "Instance"
							and (child:IsA("RemoteEvent") or child:IsA("RemoteFunction"))
						if childMatches or childIsRemote then
							selected[tostring(key)] = serialize(child)
						end
					end
					if next(selected) ~= nil then
						table.insert(upvalues, { index = tostring(upvalueIndex), selected = selected })
					end
				end
			end
		end
	end

	local record = {
		sourcePath = sourcePath,
		sourceKey = tostring(sourceKey),
		keyToken = keyToken,
		matchedConstants = matchedConstants,
		constants = constants,
		upvalues = upvalues,
		info = info,
	}
	boundedInsert(summary.actionFunctions, record, 250)
	emit("action-function", record, true)
	return true
end

-- Search function fields and constants in loaded runtime tables. This replaces
-- outgoing remote interception entirely and cannot change a button callback.
local function scanActionFunctions()
	if typeof(getgc) ~= "function" then return end
	local success, objects = pcall(getgc, true)
	if not success or typeof(objects) ~= "table" then return end

	local seenFunctions = setmetatable({}, { __mode = "k" })
	local inspectedFunctions = 0
	local matchedFunctions = 0
	for tableIndex, object in ipairs(objects) do
		if not Controller.active then break end
		if typeof(object) == "table" then
			local inspectedFields = 0
			for key, child in next, object do
				inspectedFields += 1
				if inspectedFields > 300 then break end
				if typeof(child) == "function" and not seenFunctions[child] then
					inspectedFunctions += 1
					local path = "getgc[" .. tableIndex .. "][" .. string.format("%q", tostring(key)) .. "]"
					if inspectFunction(child, path, key, seenFunctions) then matchedFunctions += 1 end
				end
			end
		end
	end

	summary.actionScan = {
		inspectedFunctions = inspectedFunctions,
		matchedFunctions = matchedFunctions,
	}
	emit("action-scan", summary.actionScan, true)
	saveSummary("Runtime action function scan complete")
	print(string.format("[InGameDiscovery][FUNCTIONS] inspected %d, matched %d",
		inspectedFunctions, matchedFunctions))
end

local function scanRemoteInventory()
	summary.remoteInventory = {}
	for _, instance in ipairs(ReplicatedStorage:GetDescendants()) do
		if instance:IsA("RemoteEvent") or instance:IsA("RemoteFunction") then
			table.insert(summary.remoteInventory, {
				path = safePath(instance),
				class = instance.ClassName,
			})
		end
	end
	table.sort(summary.remoteInventory, function(left, right) return left.path < right.path end)
	emit("remote-inventory", { count = #summary.remoteInventory }, true)
end

function Controller.mark(label)
	if Controller.active then emit("manual-mark", { label = tostring(label) }, false) end
end

local stopped = false
function Controller.stop()
	if stopped then return summary end
	stopped = true
	Controller.active = false
	for _, connection in ipairs(Controller.connections) do
		pcall(function() connection:Disconnect() end)
	end
	summary.status = "STOPPED"
	summary.stoppedAt = os.time()
	summary.totalRuntimeCandidates = #Controller.candidates
	if environment.AnimeOriginInGameDiscoveryObserver == Controller then
		environment.AnimeOriginInGameDiscoveryObserver = nil
	end
	environment.AnimeOriginInGameDiscoverySafeController = nil
	saveSummary("Stopped by user")
	warn("[InGameDiscovery] stopped; trace: " .. traceFile .. "; summary: " .. summaryFile)
	return summary
end

-- Publish an inactive proxy under the legacy global name. Any hook left by an
-- older probe sees active=false and becomes an inert forwarder. Version 3 itself
-- installs no hook; a fresh rejoin removes those older closures completely.
local PublicController = {
	active = false,
	summary = summary,
	traceFile = traceFile,
	summaryFile = summaryFile,
}
function PublicController.stop()
	return Controller.stop()
end
function PublicController.mark(label)
	return Controller.mark(label)
end
environment.AnimeOriginInGameDiscovery = PublicController
environment.AnimeOriginInGameDiscoveryObserver = Controller
environment.AnimeOriginInGameDiscoverySafeController = nil

-- Observe existing and newly created non-UI replicated evidence. Connections are
-- read-only and are removed by Controller.stop().
for _, instance in ipairs(ReplicatedStorage:GetDescendants()) do observeReplicatedDescendant(instance) end
for _, root in ipairs({ Workspace, player }) do
	for _, instance in ipairs(root:GetDescendants()) do
		if instance:IsA("ValueBase") then observeValue(instance) end
	end
end
table.insert(Controller.connections, ReplicatedStorage.DescendantAdded:Connect(observeReplicatedDescendant))
table.insert(Controller.connections, Workspace.DescendantAdded:Connect(observeDescendantAdded))
table.insert(Controller.connections, player.DescendantAdded:Connect(function(instance)
	if instance:IsA("ValueBase") then observeValue(instance) end
end))

-- Start the candidate scan and targeted polling after every observer is armed.
scanRemoteInventory()
discoverRuntimeCandidates("initial")
scanActionFunctions()
task.spawn(function()
	while Controller.active do
		pollRuntimeCandidates()
		task.wait(pollInterval)
	end
end)

summary.status = "CAPTURING"
saveSummary("Probe armed")
warn("[InGameDiscovery] READY: press Confirm, place one unit, upgrade it twice, then stop().")
return Controller
