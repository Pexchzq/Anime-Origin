--[[
	Anime Origin client optimizer

	The module exposes one small interface at getgenv().AnimeOriginOptimizer:
	report, cleanupTransientUi(reason), and stop(). cleanupTransientUi is retained
	as a compatibility no-op; match-result and reward UI belongs to the game's
	lifecycle and must never be hidden or destroyed by an optimizer.

	It changes client-only visual properties. Its only Workspace destruction is
	explicitly limited to direct children workspace.Map and workspace.MapTrash when
	configured. It never destroys, reparents or replaces remotes, scripts,
	workspace.Path.Model, workspace.Towers, workspace.Enemies, the local Character
	or CurrentCamera.
	It never destroys or hides PlayerGui roots. In particular, End Screen LocalScripts
	and callbacks must survive so the server-driven next match can reset cleanly.
	Rejoin restores all visual mutations. stop() restores 3D rendering, FPS and
	temporarily suppressed PlayerGui objects without retaining a large rollback
	table for every world Instance.
]]

local Players = game:GetService("Players")
local Lighting = game:GetService("Lighting")
local RunService = game:GetService("RunService")
local UserInputService = game:GetService("UserInputService")
local Workspace = game:GetService("Workspace")
local HttpService = game:GetService("HttpService")
local Stats = game:GetService("Stats")

local environment = getgenv()

-- Shared milestone trace. Resolved per call rather than captured at load time,
-- because Config publishes the tracer and Auto-Execute does not guarantee order.
local function trace(message, data)
	local tracer = environment.AnimeOriginTrace
	if typeof(tracer) == "function" then tracer("Optimizer", message, data) end
	-- The same milestone, in structured form, into the folder capture. Feeding
	-- the recorder from the existing trace points means the whole milestone
	-- stream is captured without a second set of call sites to keep in sync.
	local diag = environment.AnimeOriginDiag
	if typeof(diag) == "table" and typeof(diag.mark) == "function" then
		diag.mark("Optimizer", message, data)
	end
end

local function waitForConfig(timeout)
	local deadline = os.clock() + (tonumber(timeout) or 30)
	repeat
		if typeof(environment.AnimeOriginConfig) == "table" then
			return environment.AnimeOriginConfig
		end
		task.wait(0.05)
	until os.clock() >= deadline
	error("[Optimizer][AUTO_EXECUTE] Timed out waiting for Config.lua.", 0)
end

local Config = waitForConfig()
local Settings = Config.optimizer
assert(typeof(Settings) == "table", "Config.optimizer is missing.")
assert(Settings.enabled == true, "Config.optimizer.enabled is false.")
local consoleStatusOnly = typeof(Config.console) == "table"
	and Config.console.statusOnly == true

local previous = environment.AnimeOriginOptimizer
if typeof(previous) == "table" and typeof(previous.stop) == "function" then
	pcall(previous.stop)
end

local function waitForLocalPlayer(timeout)
	local deadline = os.clock() + (tonumber(timeout) or 30)
	repeat
		if Players.LocalPlayer then return Players.LocalPlayer end
		task.wait(0.05)
	until os.clock() >= deadline
	error("[Optimizer][AUTO_EXECUTE] Timed out waiting for LocalPlayer.", 0)
end

local localPlayer = waitForLocalPlayer()
local profile = string.lower(tostring(Settings.profile or "Safe"))
local multiAccountProfile = profile == "multiaccount" or profile == "multi_account"
local farmProfile = profile == "farm" or profile == "headless" or multiAccountProfile
local headlessProfile = profile == "headless" or Settings.disable3DRendering == true
local adaptiveFocus = multiAccountProfile and Settings.adaptiveFocus ~= false
local connections = {}
local queue = {}
local queued = setmetatable({}, { __mode = "k" })
local otherCharacters = setmetatable({}, { __mode = "k" })
local guiOriginalStates = setmetatable({}, { __mode = "k" })
local cleanupHiddenGui = setmetatable({}, { __mode = "k" })
local stateFolder = tostring(Settings.stateFolder or "AnimeOrigin")
local telemetryFile = stateFolder .. "/RuntimeLeakWatch_"
	.. tostring(localPlayer and localPlayer.UserId or 0) .. "_latest.json"
local maximumLeakSamples = math.max(8, tonumber(Settings.maximumLeakSamples) or 120)
local maximumLeakAlerts = math.max(5, tonumber(Settings.maximumLeakAlerts) or 30)
local report = {
	version = 3,
	jobId = game.JobId,
	placeId = game.PlaceId,
	profile = profile,
	startedAt = os.time(),
	processed = 0,
	mutations = 0,
	byClass = {},
	focusTransitions = 0,
	samples = {},
	alerts = {},
	cleanupEvents = {},
	destroyedMapRoots = 0,
	destroyedMapDescendants = 0,
	telemetryFile = telemetryFile,
	status = "STARTING",
}
local controller = { active = true, report = report }
local currentFocus = true
local focusPolicyReady = not adaptiveFocus
local renderingDisabled = false
local guiSuppressed = false
local stableGui = setmetatable({}, { __mode = "k" })
local baselineSealed = false
local baselineStartedAt = os.clock()
local baselineSampleSequence = 1
local sampleSequence = 0
local cleanupSequence = 0
local frameSeconds = 0
local frameCount = 0
local frameMaximum = 0
local towersRoot = Workspace:FindFirstChild("Towers")
local enemiesRoot = Workspace:FindFirstChild("Enemies")

local foregroundFpsCap = tonumber(Settings.foregroundFpsCap)
	or tonumber(Settings.fpsCap) or 30
local backgroundFpsCap = tonumber(Settings.backgroundFpsCap) or 10

local function log(message, data)
	if Settings.debug ~= true or consoleStatusOnly then return end
	if data == nil then
		print("[Optimizer] " .. message)
	else
		print("[Optimizer] " .. message, data)
	end
end

local function ensureFolder()
	if typeof(makefolder) ~= "function" then return end
	local exists = typeof(isfolder) == "function" and isfolder(stateFolder)
	if not exists then pcall(makefolder, stateFolder) end
end

local function saveTelemetry(reason)
	report.updatedAt = os.time()
	report.lastReason = reason
	if typeof(writefile) ~= "function" then return false end
	ensureFolder()
	local ok, encoded = pcall(HttpService.JSONEncode, HttpService, report)
	if not ok then return false end
	return pcall(writefile, telemetryFile, encoded)
end

local function pushBounded(list, value, maximum)
	table.insert(list, value)
	while #list > maximum do table.remove(list, 1) end
end

local memoryTagAllowList = {
	LuaHeap = true,
	Instances = true,
	Signals = true,
	Gui = true,
	GraphicsTexture = true,
	GraphicsMeshParts = true,
	PhysicsParts = true,
	Animation = true,
}

local function readMemoryTags()
	local result = {}
	local ok, items = pcall(function() return Enum.DeveloperMemoryTag:GetEnumItems() end)
	if not ok then return result end
	for _, tag in ipairs(items) do
		if memoryTagAllowList[tag.Name] then
			local readOk, value = pcall(function()
				return Stats:GetMemoryUsageMbForTag(tag)
			end)
			if readOk and tonumber(value) then result[tag.Name] = value end
		end
	end
	return result
end

local function readPerformanceStats()
	local result = {}
	local root = Stats:FindFirstChild("PerformanceStats")
	if not root then return result end
	for _, item in ipairs(root:GetChildren()) do
		local okValue, value = pcall(function() return item:GetValue() end)
		local okString, valueString = pcall(function() return item:GetValueString() end)
		if okValue or okString then
			result[item.Name] = {
				value = okValue and value or nil,
				display = okString and valueString or nil,
			}
		end
	end
	return result
end

local function isEffectivelyVisible(gui)
	local cursor = gui
	while cursor and cursor ~= localPlayer do
		if cursor:IsA("ScreenGui") then
			local ok, enabled = pcall(function() return cursor.Enabled end)
			if ok and enabled == false then return false end
		elseif cursor:IsA("GuiObject") then
			local ok, visible = pcall(function() return cursor.Visible end)
			if ok and visible == false then return false end
		end
		cursor = cursor.Parent
	end
	return true
end

-- End/result/reward roots may preload while hidden and become visible only when a
-- match finishes. Clearing their images early makes a valid result screen appear
-- broken, so preserve the whole lifecycle branch even in aggressive profiles.
local function isLifecycleGui(instance)
	local cursor = instance
	while cursor and cursor ~= localPlayer do
		local name = string.lower(tostring(cursor.Name or "")):gsub("[^%w]", "")
		if name == "endscreen" or name == "endgame" or name == "result"
			or name == "results" or name == "rewards" then
			return true
		end
		cursor = cursor.Parent
	end
	return false
end

-- Multi-account farm clients preload tens of thousands of hidden unit/shop
-- images. They dominated the captured GraphicsTexture tag even though the
-- visible stage HUD used only a small fraction. Visible HUD assets are untouched;
-- a rejoin restores every client-only image cleared during this session.
local function stripHiddenGuiImage(instance)
	if Settings.stripHiddenGuiImages ~= true or not baselineSealed then return false end
	if not (instance:IsA("ImageLabel") or instance:IsA("ImageButton")) then return false end
	if isLifecycleGui(instance) then return false end
	if isEffectivelyVisible(instance) then return false end
	local ok, image = pcall(function() return instance.Image end)
	if not ok or image == "" then return false end
	local changed = pcall(function() instance.Image = "" end)
	if changed then report.strippedGuiImages = (report.strippedGuiImages or 0) + 1 end
	return changed
end

local function countPlayerGui()
	local counts = {
		PlayerGuiDescendants = 0,
		ScreenGui = 0,
		GuiObject = 0,
		Frame = 0,
		ImageLabel = 0,
		ImageButton = 0,
		ViewportFrame = 0,
		TextLabel = 0,
		TextButton = 0,
	}
	local playerGui = localPlayer and localPlayer:FindFirstChildOfClass("PlayerGui")
	if not playerGui then return counts end
	local descendants = playerGui:GetDescendants()
	counts.PlayerGuiDescendants = #descendants
	local strippedThisPass = 0
	local maximumStrip = math.max(100, tonumber(Settings.maximumHiddenGuiImagesPerPass) or 4000)
	for _, instance in ipairs(descendants) do
		if strippedThisPass < maximumStrip and stripHiddenGuiImage(instance) then
			strippedThisPass += 1
		end
		if instance:IsA("ScreenGui") then counts.ScreenGui += 1 end
		if instance:IsA("GuiObject") then counts.GuiObject += 1 end
		if counts[instance.ClassName] ~= nil then counts[instance.ClassName] += 1 end
	end
	descendants = nil
	return counts
end

local function largestPlayerGuiRoots()
	local playerGui = localPlayer and localPlayer:FindFirstChildOfClass("PlayerGui")
	if not playerGui then return {} end
	local roots = {}
	for _, root in ipairs(playerGui:GetChildren()) do
		local descendants = root:GetDescendants()
		table.insert(roots, {
			name = root.Name,
			class = root.ClassName,
			descendants = #descendants,
			enabled = root:IsA("ScreenGui") and root.Enabled or nil,
			visible = root:IsA("GuiObject") and root.Visible or nil,
		})
		descendants = nil
	end
	table.sort(roots, function(left, right) return left.descendants > right.descendants end)
	while #roots > 12 do table.remove(roots) end
	return roots
end

local function countRuntimeRoot(name)
	local root = Workspace:FindFirstChild(name)
	if not root then return { direct = 0, descendants = 0 } end
	local descendants = root:GetDescendants()
	local result = { direct = #root:GetChildren(), descendants = #descendants }
	descendants = nil
	return result
end

local function addAlert(kind, message, sample)
	local alert = {
		kind = kind,
		message = message,
		sequence = sample and sample.sequence or sampleSequence,
		unixTime = os.time(),
	}
	pushBounded(report.alerts, alert, maximumLeakAlerts)
	report.latestAlert = alert
	-- Leak evidence is still persisted in telemetry. In compact-console mode the
	-- observer dashboard owns normal output, so warnings do not flood the console.
	if not consoleStatusOnly then warn("[Optimizer][LEAK] " .. message) end
end

-- This detector uses a fixed ring and one overwritten file. It attributes
-- growth to total memory, Roblox memory tags and PlayerGui rather than guessing
-- from the visible frame alone.
local function takeLeakSample(reason)
	if not controller.active or Settings.leakTelemetry ~= true then return nil end
	sampleSequence += 1
	local totalOk, totalMemory = pcall(function() return Stats:GetTotalMemoryUsageMb() end)
	local luaHeap = typeof(gcinfo) == "function" and gcinfo() / 1024 or nil
	local gui = countPlayerGui()
	local sample = {
		sequence = sampleSequence,
		unixTime = os.time(),
		clock = os.clock(),
		reason = reason,
		totalMemoryMb = totalOk and totalMemory or nil,
		luaHeapMb = luaHeap,
		memoryTagsMb = readMemoryTags(),
		performance = readPerformanceStats(),
		gui = gui,
		focused = currentFocus,
		renderingDisabled = renderingDisabled,
		fpsCap = report.fpsCap,
		optimizerQueueDepth = #queue,
		optimizerConnectionCount = #connections,
		frame = {
			averageMs = frameCount > 0 and (frameSeconds / frameCount) * 1000 or nil,
			maximumMs = frameCount > 0 and frameMaximum * 1000 or nil,
			fps = frameSeconds > 0 and frameCount / frameSeconds or nil,
		},
	}
	frameSeconds, frameCount, frameMaximum = 0, 0, 0

	if sampleSequence == 1
		or sampleSequence % math.max(1, tonumber(Settings.detailedSampleEvery) or 4) == 0 then
		sample.runtime = {
			Towers = countRuntimeRoot("Towers"),
			Enemies = countRuntimeRoot("Enemies"),
			Debris = countRuntimeRoot("Debris"),
		}
		sample.guiRoots = largestPlayerGuiRoots()
	end

	local previousSample = report.samples[#report.samples]
	if previousSample then
		sample.delta = {
			totalMemoryMb = sample.totalMemoryMb and previousSample.totalMemoryMb
				and sample.totalMemoryMb - previousSample.totalMemoryMb or nil,
			luaHeapMb = sample.luaHeapMb and previousSample.luaHeapMb
				and sample.luaHeapMb - previousSample.luaHeapMb or nil,
			PlayerGuiDescendants = gui.PlayerGuiDescendants
				- (previousSample.gui and previousSample.gui.PlayerGuiDescendants or 0),
		}
	end

	table.insert(report.samples, sample)
	while #report.samples > maximumLeakSamples do table.remove(report.samples, 1) end
	report.latestSample = sample

	-- Four non-decreasing samples avoid flagging a one-off load spike as a leak.
	if #report.samples >= 4 then
		local first = report.samples[#report.samples - 3]
		local monotonicMemory = true
		local monotonicGui = true
		for index = #report.samples - 2, #report.samples do
			local before = report.samples[index - 1]
			local after = report.samples[index]
			monotonicMemory = monotonicMemory and before.totalMemoryMb ~= nil
				and after.totalMemoryMb ~= nil and after.totalMemoryMb >= before.totalMemoryMb
			monotonicGui = monotonicGui and after.gui.PlayerGuiDescendants
				>= before.gui.PlayerGuiDescendants
		end
		local memoryGrowth = sample.totalMemoryMb and first.totalMemoryMb
			and sample.totalMemoryMb - first.totalMemoryMb or 0
		local guiGrowth = gui.PlayerGuiDescendants
			- (first.gui and first.gui.PlayerGuiDescendants or 0)
		local afterStartupBaseline = first.sequence >= baselineSampleSequence
		if afterStartupBaseline and monotonicMemory
			and memoryGrowth >= (tonumber(Settings.leakMemoryAlertMb) or 350) then
			addAlert("MEMORY_GROWTH", string.format(
				"Total memory grew %.1f MB across four samples.", memoryGrowth), sample)
		end
		if afterStartupBaseline and monotonicGui
			and guiGrowth >= (tonumber(Settings.leakGuiAlertCount) or 150) then
			addAlert("PLAYERGUI_GROWTH", string.format(
				"PlayerGui grew by %d descendants across four samples.", guiGrowth), sample)
		end
	end

	saveTelemetry("sample:" .. tostring(reason))
	return sample
end

local function rememberMutation(instance)
	report.mutations += 1
	report.byClass[instance.ClassName] = (report.byClass[instance.ClassName] or 0) + 1
end

local function setProperty(instance, property, value)
	local ok, current = pcall(function() return instance[property] end)
	if not ok or current == value then return false end
	local changed = pcall(function() instance[property] = value end)
	if changed then rememberMutation(instance) end
	return changed
end

-- Destroy only exact, configured direct children of Workspace. Keeping this as a
-- narrow allowlist prevents similarly named gameplay folders elsewhere from being
-- removed, while ChildAdded handling also catches map roots recreated after reset.
local function destroyConfiguredMapRoot(instance)
	if not controller.active or Settings.destroyMapRoots ~= true then return false end
	if not instance or instance.Parent ~= Workspace then return false end
	local allowlist = typeof(Settings.mapRootsToDestroy) == "table"
		and Settings.mapRootsToDestroy or {}
	if allowlist[instance.Name] ~= true then return false end

	local descendantCount = 0
	pcall(function() descendantCount = #instance:GetDescendants() end)
	local path = "workspace." .. instance.Name
	local destroyed = pcall(function() instance:Destroy() end)
	if destroyed then
		report.destroyedMapRoots += 1
		report.destroyedMapDescendants += descendantCount
		log(string.format("Destroyed %s and %d descendant(s).", path, descendantCount))
	end
	return destroyed
end

local function isUnder(instance, ancestor)
	return ancestor ~= nil and instance ~= ancestor and instance:IsDescendantOf(ancestor)
end

local function isLocalCharacter(instance)
	return localPlayer and isUnder(instance, localPlayer.Character)
end

local function isOtherCharacter(instance)
	if Settings.hideOtherPlayers ~= true then return false end
	local cursor = instance
	while cursor and cursor ~= Workspace do
		if otherCharacters[cursor] then return true end
		cursor = cursor.Parent
	end
	return false
end

local function isCombatVisual(instance)
	if Settings.hideCombatModels ~= true then return false end
	if not towersRoot or not towersRoot.Parent then towersRoot = Workspace:FindFirstChild("Towers") end
	if not enemiesRoot or not enemiesRoot.Parent then enemiesRoot = Workspace:FindFirstChild("Enemies") end
	return isUnder(instance, towersRoot) or isUnder(instance, enemiesRoot)
end

-- Filter before queueing so a spawn burst does not retain Models, values and
-- gameplay metadata that this optimizer will never mutate.
local function isOptimizable(instance)
	if Settings.disableEffects == true and (
		instance:IsA("ParticleEmitter") or instance:IsA("Trail") or instance:IsA("Beam")
		or instance:IsA("Smoke") or instance:IsA("Fire") or instance:IsA("Sparkles")
		or instance:IsA("Highlight")
	) then return true end
	if Settings.disablePostEffects == true and instance:IsA("PostEffect") then return true end
	if Settings.disableLights == true and instance:IsA("Light") then return true end
	if Settings.muteSounds == true and instance:IsA("Sound") then return true end
	if instance:IsA("BasePart") and (Settings.disableShadows == true or farmProfile) then return true end
	return farmProfile and Settings.hideMapTextures == true
		and (instance:IsA("Decal") or instance:IsA("Texture"))
end

local function apply(instance)
	if not controller.active or not instance or not instance.Parent or not isOptimizable(instance) then return end
	report.processed += 1

	-- Effects have no role in server evidence or placement geometry.
	if Settings.disableEffects == true then
		if instance:IsA("ParticleEmitter") or instance:IsA("Trail") or instance:IsA("Beam")
			or instance:IsA("Smoke") or instance:IsA("Fire") or instance:IsA("Sparkles")
			or instance:IsA("Highlight") then
			setProperty(instance, "Enabled", false)
		end
	end
	if Settings.disablePostEffects == true and instance:IsA("PostEffect") then
		setProperty(instance, "Enabled", false)
	end
	if Settings.disableLights == true and instance:IsA("Light") then
		setProperty(instance, "Enabled", false)
	end
	if Settings.disableShadows == true and instance:IsA("BasePart") then
		setProperty(instance, "CastShadow", false)
	end
	if Settings.muteSounds == true and instance:IsA("Sound") then
		-- Preserve Sound identity/playback state for scripts waiting on it.
		setProperty(instance, "Volume", 0)
	end

	if farmProfile and not isLocalCharacter(instance) then
		if Settings.hideMapTextures == true
			and (instance:IsA("Decal") or instance:IsA("Texture")) then
			setProperty(instance, "Transparency", 1)
		elseif instance:IsA("BasePart")
			and (isOtherCharacter(instance) or isCombatVisual(instance)) then
			-- Preserve CFrame, Size, collision and every evidence path AutoPlay uses.
			setProperty(instance, "LocalTransparencyModifier", 1)
		end
	end
end

local function enqueue(instance)
	if not instance or queued[instance] or not isOptimizable(instance) then return end
	queued[instance] = true
	table.insert(queue, instance)
end

local function initialScan(root)
	local batchSize = math.max(50, tonumber(Settings.maximumBatchSize) or 250)
	local descendants = root:GetDescendants()
	for index, instance in ipairs(descendants) do
		apply(instance)
		if index % batchSize == 0 then task.wait() end
	end
	-- Release the broad descendant array before long-running watchers start.
	descendants = nil
end

local function setFpsCap(value)
	-- When disabled, do not call the executor adapter at all. A fresh join therefore
	-- retains the user's/Roblox's own FPS behavior instead of imposing a script cap.
	if Settings.lockFps ~= true then
		report.fpsCap = "unlocked"
		return false
	end
	if typeof(setfpscap) ~= "function" then return false end
	local cap = math.max(10, math.floor(tonumber(value) or 30))
	local ok = pcall(setfpscap, cap)
	if ok then report.fpsCap = cap end
	return ok
end

local function setRenderingDisabled(disabled)
	if renderingDisabled == disabled then return true end
	local ok = pcall(function() RunService:Set3dRenderingEnabled(not disabled) end)
	if ok then
		renderingDisabled = disabled
		report.renderingDisabled = disabled
	end
	return ok
end

local function suppressPlayerGui(suppressed)
	if Settings.hidePlayerGuiWhenUnfocused ~= true then return end
	local playerGui = localPlayer and localPlayer:FindFirstChildOfClass("PlayerGui")
	if not playerGui then return end
	for _, gui in ipairs(playerGui:GetChildren()) do
		if gui:IsA("ScreenGui") then
			if suppressed then
				if guiOriginalStates[gui] == nil then guiOriginalStates[gui] = gui.Enabled end
				setProperty(gui, "Enabled", false)
			elseif guiOriginalStates[gui] ~= nil then
				setProperty(gui, "Enabled", cleanupHiddenGui[gui] and false or guiOriginalStates[gui])
				guiOriginalStates[gui] = nil
			end
		end
	end
	guiSuppressed = suppressed
	report.playerGuiSuppressed = suppressed
end

local function captureStableGui()
	local playerGui = localPlayer and localPlayer:FindFirstChildOfClass("PlayerGui")
	if not playerGui then return 0 end
	stableGui[playerGui] = true
	local descendants = playerGui:GetDescendants()
	for _, instance in ipairs(descendants) do stableGui[instance] = true end
	local count = #descendants
	descendants = nil
	return count
end

local function normalizedText(instance)
	if not (instance:IsA("TextLabel") or instance:IsA("TextButton")
		or instance:IsA("TextBox")) then return nil end
	local ok, value = pcall(function() return instance.Text end)
	if not ok then return nil end
	value = string.lower(tostring(value or ""))
	value = string.gsub(value, "<[^>]->", "")
	return string.gsub(value, "%s+", " ")
end

local function hasPlain(text, needle)
	return text ~= nil and string.find(text, needle, 1, true) ~= nil
end

local function dynamicRootFor(instance, playerGui)
	local cursor = instance
	local candidate = nil
	while cursor and cursor ~= playerGui do
		if stableGui[cursor] then break end
		candidate = cursor
		cursor = cursor.Parent
	end
	return candidate
end

local function lowestCommonGuiAncestor(instances, playerGui)
	if #instances == 0 then return nil end
	local cursor = instances[1]
	while cursor and cursor ~= playerGui do
		local includesAll = true
		for index = 2, #instances do
			local other = instances[index]
			local ok, included = pcall(function()
				return other == cursor or other:IsDescendantOf(cursor)
			end)
			if not ok or not included then includesAll = false; break end
		end
		if includesAll and (cursor:IsA("GuiObject") or cursor:IsA("ScreenGui")) then
			return cursor
		end
		cursor = cursor.Parent
	end
	return nil
end

local function protectedGuiRoot(instance, playerGui)
	if not instance or instance == playerGui or stableGui[instance] then return true end
	if instance:IsA("ScreenGui") then
		local name = string.lower(instance.Name)
		if name == "mainui" or name == "coregui" then return true end
	end
	return false
end

local function destroyTransientRoot(candidate, playerGui)
	if Settings.destroyTransientGuiClones ~= true or protectedGuiRoot(candidate, playerGui) then
		return false
	end
	local ok, inside = pcall(function() return candidate:IsDescendantOf(playerGui) end)
	if not ok or not inside then return false end
	-- Only this marker-proven PlayerGui candidate is destructive. No workspace,
	-- gameplay, remote or script Instance can enter this function.
	return pcall(function() candidate:Destroy() end)
end

local function hidePersistentPanel(candidate)
	if not candidate then return false end
	if candidate:IsA("GuiObject") then
		local changed = setProperty(candidate, "Visible", false)
		pcall(function() candidate.Active = false end)
		return changed
	end
	if candidate:IsA("ScreenGui") then
		cleanupHiddenGui[candidate] = true
		return setProperty(candidate, "Enabled", false)
	end
	return false
end

local function cleanupGroup(instances, playerGui)
	local destroyed = 0
	local dynamicRoots = {}
	for _, instance in ipairs(instances) do
		local root = dynamicRootFor(instance, playerGui)
		if root then dynamicRoots[root] = true end
	end
	for root in pairs(dynamicRoots) do
		if root.Parent and destroyTransientRoot(root, playerGui) then destroyed += 1 end
	end
	if destroyed > 0 then return destroyed, 0 end
	local persistent = lowestCommonGuiAncestor(instances, playerGui)
	return 0, hidePersistentPanel(persistent) and 1 or 0
end

local function cleanupPass(reason, passNumber)
	if not controller.active or Settings.cleanupTransientUi ~= true then return false end
	local playerGui = localPlayer and localPlayer:FindFirstChildOfClass("PlayerGui")
	if not playerGui or not baselineSealed then return false end

	local evidence = {
		endResult = {},
		endDetail = {},
		endAction = {},
		popupUsed = {},
		popupOwned = {},
	}
	local descendants = playerGui:GetDescendants()
	for _, instance in ipairs(descendants) do
		local text = normalizedText(instance)
		if text then
			if hasPlain(text, "victory") or hasPlain(text, "defeat") then
				table.insert(evidence.endResult, instance)
			end
			if hasPlain(text, "xp progress") or text == "rewards:" or text == "rewards" then
				table.insert(evidence.endDetail, instance)
			end
			if hasPlain(text, "return to lobby") or hasPlain(text, "replay")
				or hasPlain(text, "next(") then
				table.insert(evidence.endAction, instance)
			end
			if hasPlain(text, "used to summon new units") then
				table.insert(evidence.popupUsed, instance)
			end
			if hasPlain(text, "owned") then table.insert(evidence.popupOwned, instance) end
		end
	end
	descendants = nil

	local destroyed, hidden = 0, 0
	if #evidence.endResult > 0
		and (#evidence.endDetail > 0 or #evidence.endAction > 0) then
		local group = {}
		for _, list in ipairs({ evidence.endResult, evidence.endDetail, evidence.endAction }) do
			for _, instance in ipairs(list) do table.insert(group, instance) end
		end
		local groupDestroyed, groupHidden = cleanupGroup(group, playerGui)
		destroyed += groupDestroyed
		hidden += groupHidden
	end
	if #evidence.popupUsed > 0 and #evidence.popupOwned > 0 then
		local group = {}
		for _, instance in ipairs(evidence.popupUsed) do table.insert(group, instance) end
		for _, instance in ipairs(evidence.popupOwned) do table.insert(group, instance) end
		local groupDestroyed, groupHidden = cleanupGroup(group, playerGui)
		destroyed += groupDestroyed
		hidden += groupHidden
	end

	cleanupSequence += 1
	local event = {
		sequence = cleanupSequence,
		unixTime = os.time(),
		reason = tostring(reason),
		pass = passNumber,
		destroyed = destroyed,
		hidden = hidden,
		endMarkers = #evidence.endResult + #evidence.endDetail + #evidence.endAction,
		popupMarkers = #evidence.popupUsed + #evidence.popupOwned,
	}
	pushBounded(report.cleanupEvents, event, 40)
	report.latestCleanup = event
	if destroyed > 0 or hidden > 0 then
		log(string.format("Transient UI cleanup: destroyed=%d hidden=%d (%s).",
			destroyed, hidden, tostring(reason)))
	end
	saveTelemetry("cleanup:" .. tostring(reason))
	return destroyed > 0 or hidden > 0
end

function controller.cleanupTransientUi(reason)
	-- Compatibility seam for older main.lua copies. Destructive cleanup is
	-- intentionally disabled even if a stale Config still asks for it; correctness
	-- of the next match takes priority over removing a few visible GUI descendants.
	report.latestCleanup = {
		unixTime = os.time(),
		reason = tostring(reason),
		preserved = true,
	}
	return false
end

-- One focus-policy interface hides all executor and Roblox-specific adapters:
-- FPS cap, 3D rendering and PlayerGui suppression change as one atomic policy.
local function applyFocusPolicy(focused, reason)
	currentFocus = focused == true
	if not controller.active or not focusPolicyReady then return end

	if headlessProfile then
		setFpsCap(backgroundFpsCap)
		setRenderingDisabled(true)
		suppressPlayerGui(true)
	elseif adaptiveFocus and not currentFocus then
		setFpsCap(backgroundFpsCap)
		if Settings.disable3DWhenUnfocused ~= false then setRenderingDisabled(true) end
		suppressPlayerGui(true)
	else
		setFpsCap(foregroundFpsCap)
		setRenderingDisabled(false)
		suppressPlayerGui(false)
	end

	report.focused = currentFocus
	report.focusReason = reason
	report.focusTransitions += 1
	log(string.format("Focus policy: %s, FPS=%s, 3D=%s, GUI=%s (%s).",
		currentFocus and "foreground" or "background",
		tostring(report.fpsCap),
		renderingDisabled and "off" or "on",
		guiSuppressed and "hidden" or "visible",
		tostring(reason)))
end

function controller.stop()
	if not controller.active then return end
	takeLeakSample("stop")
	controller.active = false
	for _, connection in ipairs(connections) do pcall(function() connection:Disconnect() end) end
	table.clear(connections)
	table.clear(queue)
	setRenderingDisabled(false)
	suppressPlayerGui(false)
	setFpsCap(foregroundFpsCap)
	report.status = "STOPPED"
	report.stoppedAt = os.time()
	saveTelemetry("stopped")
	log("Stopped. Rejoin to restore world visual properties changed before stop().")
end

environment.AnimeOriginOptimizer = controller

-- Stagger initial scans so many clients joining together do not all traverse
-- their worlds on the same frame. The delay is deterministic per account.
local maximumJitter = math.max(0, tonumber(Settings.maximumStartupJitter) or 0)
if maximumJitter > 0 and localPlayer then
	local fraction = (localPlayer.UserId % 997) / 997
	task.wait(fraction * maximumJitter)
end

-- Use Roblox/client quality controls first; they reduce work before per-instance
-- fallbacks are needed.
setFpsCap(foregroundFpsCap)
pcall(function() settings().Rendering.QualityLevel = Enum.QualityLevel.Level01 end)
if Settings.disableShadows == true then pcall(function() Lighting.GlobalShadows = false end) end
pcall(function()
	Workspace.Terrain.WaterWaveSize = 0
	Workspace.Terrain.WaterWaveSpeed = 0
	Workspace.Terrain.WaterReflectance = 0
end)

for _, player in ipairs(Players:GetPlayers()) do
	if player ~= localPlayer and player.Character then otherCharacters[player.Character] = true end
	if player ~= localPlayer then
		table.insert(connections, player.CharacterAdded:Connect(function(character)
			otherCharacters[character] = true
		end))
	end
end
table.insert(connections, Players.PlayerAdded:Connect(function(player)
	if player == localPlayer then return end
	table.insert(connections, player.CharacterAdded:Connect(function(character)
		otherCharacters[character] = true
	end))
end))

-- Install the direct-child watcher before the initial pass so a map root that
-- replicates during startup cannot escape cleanup. Existing roots are removed once.
table.insert(connections, Workspace.ChildAdded:Connect(function(instance)
	destroyConfiguredMapRoot(instance)
end))
for _, rootName in ipairs({ "Map", "MapTrash" }) do
	local root = Workspace:FindFirstChild(rootName)
	if root then destroyConfiguredMapRoot(root) end
end

initialScan(Workspace)
initialScan(Lighting)

-- Frame telemetry uses one connection and resets its accumulators after every
-- sample. It does not retain individual frames or RenderStepped callbacks.
table.insert(connections, RunService.Heartbeat:Connect(function(deltaTime)
	if not controller.active then return end
	frameSeconds += deltaTime
	frameCount += 1
	if deltaTime > frameMaximum then frameMaximum = deltaTime end
end))

-- The baseline is refreshed only during startup for leak attribution. It is not
-- permission to destroy later EndScreen/reward roots; those remain game-owned.
task.spawn(function()
	local duration = math.max(3, tonumber(Settings.transientUiBaselineSeconds) or 12)
	repeat
		report.baselineGuiDescendants = captureStableGui()
		task.wait(1)
	until not controller.active or os.clock() - baselineStartedAt >= duration
	if not controller.active then return end
	captureStableGui()
	baselineSealed = true
	-- Exclude the empty startup sample from leak windows. The first comparison
	-- begins only after Roblox has completed its normal PlayerGui bootstrap.
	baselineSampleSequence = sampleSequence + 1
	report.baselineSealed = true
	report.baselineSealedAt = os.time()
	log("PlayerGui baseline sealed at " .. tostring(report.baselineGuiDescendants) .. " descendants.")
	saveTelemetry("baseline sealed")
end)

if Settings.stripHiddenGuiImages == true and localPlayer then
	local playerGui = localPlayer:FindFirstChildOfClass("PlayerGui")
	if playerGui then
		-- New hidden reward/shop/unit images are stripped immediately after baseline;
		-- the regular telemetry census also rechecks properties rewritten by the game.
		table.insert(connections, playerGui.DescendantAdded:Connect(function(instance)
			stripHiddenGuiImage(instance)
		end))
	end
end

-- Newly spawned visuals are queued and processed in bounded batches. Filtering
-- happens before retention, avoiding a large queue of irrelevant game state.
table.insert(connections, Workspace.DescendantAdded:Connect(enqueue))
table.insert(connections, Lighting.DescendantAdded:Connect(enqueue))
task.spawn(function()
	local interval = math.max(0.1, tonumber(Settings.batchInterval) or 0.75)
	local maximum = math.max(50, tonumber(Settings.maximumBatchSize) or 250)
	while controller.active do
		local current = queue
		queue = {}
		local count = math.min(#current, maximum)
		for index = 1, count do
			local instance = current[index]
			queued[instance] = nil
			apply(instance)
		end
		for index = count + 1, #current do table.insert(queue, current[index]) end
		table.clear(current)
		task.wait(interval)
	end
end)

if adaptiveFocus then
	local ok, focused = pcall(function() return UserInputService:IsWindowFocused() end)
	if ok then
		currentFocus = focused == true
	else
		currentFocus = true
	end
	table.insert(connections, UserInputService.WindowFocused:Connect(function()
		applyFocusPolicy(true, "WindowFocused")
	end))
	table.insert(connections, UserInputService.WindowFocusReleased:Connect(function()
		applyFocusPolicy(false, "WindowFocusReleased")
	end))

	-- Let Config, FastMode and UnitProgression discover their runtime tables before
	-- a background account stops drawing. Disabled rendering does not stop tasks.
	local delaySeconds = math.max(0, tonumber(Settings.focusPolicyDelay) or 12)
	task.delay(delaySeconds, function()
		if not controller.active then return end
		focusPolicyReady = true
		applyFocusPolicy(currentFocus, "StartupDelayComplete")
	end)
else
	applyFocusPolicy(currentFocus, "StaticProfile")
end

if Settings.hidePlayerGuiWhenUnfocused == true and localPlayer then
	local playerGui = localPlayer:FindFirstChildOfClass("PlayerGui")
	if playerGui then
		table.insert(connections, playerGui.ChildAdded:Connect(function(gui)
			if guiSuppressed and gui:IsA("ScreenGui") then
				guiOriginalStates[gui] = gui.Enabled
				setProperty(gui, "Enabled", false)
			end
		end))
	end
end

report.status = "RUNNING"
report.readyAt = os.time()
trace("profile active", {
	profile = profile,
	mutations = report.mutations,
	-- lockFps was once true in name only: every cap under it was configured while the
	-- flag itself was false, so dozens of background clients rendered uncapped.
	lockFps = Settings.lockFps == true,
	fpsCap = tonumber(Settings.fpsCap),
})
log(string.format("%s profile active: %d visual mutations from %d relevant instances.",
	profile, report.mutations, report.processed), report.byClass)
saveTelemetry("optimizer ready")

if Settings.leakTelemetry == true then
	task.spawn(function()
		takeLeakSample("startup")
		local interval = math.max(5, tonumber(Settings.leakSampleInterval) or 15)
		while controller.active do
			task.wait(interval)
			if controller.active then takeLeakSample("interval") end
		end
	end)
end
return controller
