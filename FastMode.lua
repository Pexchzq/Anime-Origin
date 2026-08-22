--[[
	Anime Origin - Fast Gems claims and new-account bootstrap

	This file has one responsibility:
	  1. Claim every configured free reward source for both new and old accounts.
	  2. Prove summon eligibility from PlayerData.ProfileData.TotalSummons == 0.
	  3. For an eligible new account, freeze a ten-pull budget from live Gems.
	  4. Spend that budget, at most ten batches, verifying both Gems and
	     TotalSummons after every server call.

	It does not equip units, enter a map, create a room or teleport. AutoPlay owns
	the team and match; main.lua will own progression routing later.

	Run Config.lua before this file. Progress is saved before the first summon so
	an interrupted run can resume even after TotalSummons changes from 0 to 10.
]]

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local HttpService = game:GetService("HttpService")

local environment = getgenv()

-- Auto-Execute tasks are concurrent in MacSploit, so alphabetical filenames do
-- not guarantee that Config.lua wins the startup race. These bounded waits make
-- the controller safe on both a fresh join and a place teleport.
local function waitForAnimeOriginConfig(timeout)
	local deadline = os.clock() + (tonumber(timeout) or 30)
	repeat
		local config = environment.AnimeOriginConfig
		if typeof(config) == "table" then return config end
		task.wait(0.05)
	until os.clock() >= deadline
	error("[FastMode][AUTO_EXECUTE] Timed out waiting for Config.lua.", 0)
end

local function waitForLocalPlayer(timeout)
	local deadline = os.clock() + (tonumber(timeout) or 30)
	repeat
		if Players.LocalPlayer then return Players.LocalPlayer end
		task.wait(0.05)
	until os.clock() >= deadline
	error("[FastMode][AUTO_EXECUTE] Timed out waiting for LocalPlayer.", 0)
end

local player = waitForLocalPlayer()
local Config = waitForAnimeOriginConfig()

local Settings = Config.fastGems
assert(typeof(Settings) == "table", "Config.fastGems is missing.")
assert(Settings.enabled == true, "Config.fastGems.enabled is false.")
local consoleStatusOnly = typeof(Config.console) == "table"
	and Config.console.statusOnly == true

local Bootstrap = Settings.bootstrap
assert(typeof(Bootstrap) == "table", "Config.fastGems.bootstrap is missing.")
assert(Bootstrap.spendAllAvailableGems == true, "FastMode requires spendAllAvailableGems=true.")

-- Two executor runs must never claim or summon concurrently.
-- Job-scoped tokens reject a duplicate in one server without letting a stale
-- boolean from the previous place suppress the next Auto-Execute lifecycle.
local previousRun = environment.AnimeOriginFastModeRunning
assert(not (typeof(previousRun) == "table" and previousRun.jobId == game.JobId),
	"FastMode is already running in this server.")
local runToken = { jobId = game.JobId, userId = player.UserId, startedAt = os.time() }
environment.AnimeOriginFastModeRunning = runToken

-- Publish a small cross-file lifecycle record. UnitProgression waits for this
-- inventory-mutating worker, while main.lua waits for both terminal signals before
-- moving the character into the Story portal.
local function publishLifecycle(status, details)
	local lifecycle = environment.AnimeOriginLifecycle
	if typeof(lifecycle) ~= "table" or lifecycle.jobId ~= game.JobId then
		lifecycle = { version = 1, jobId = game.JobId, createdAt = os.time(), tasks = {} }
		environment.AnimeOriginLifecycle = lifecycle
	end
	lifecycle.tasks = typeof(lifecycle.tasks) == "table" and lifecycle.tasks or {}
	lifecycle.tasks.FastMode = {
		status = status,
		updatedAt = os.time(),
		userId = player.UserId,
		details = details,
	}
end

publishLifecycle("RUNNING", { phase = "startup" })

-- FastMode owns lobby claims and summons only. Auto-Execute also runs after a
-- stage teleport, where lobby PlayerData/remotes do not exist and must not be
-- reported as a bootstrap failure.
local lobbyPlaces = Config.runtimePlaces and Config.runtimePlaces.lobby
local isLobbyPlace = typeof(lobbyPlaces) == "table" and lobbyPlaces[game.PlaceId] == true
if not isLobbyPlace then
	local skipped = { status = "SKIPPED_STAGE", placeId = game.PlaceId, jobId = game.JobId }
	publishLifecycle("SKIPPED", { phase = "context", reason = "stage place" })
	if environment.AnimeOriginFastModeRunning == runToken then
		environment.AnimeOriginFastModeRunning = nil
	end
	environment.AnimeOriginFastModeReport = skipped
	if not consoleStatusOnly then
		print("[FastMode] Stage place detected; lobby bootstrap skipped.")
	end
	return skipped
end

local stateFolder = tostring(Settings.stateFolder or "AnimeOrigin")
local stateFile = stateFolder .. "/FastModeBootstrap_" .. tostring(player.UserId) .. ".json"
local logFile = stateFolder .. "/FastModeBootstrap_" .. tostring(player.UserId) .. "_latest.log"
local logBuffer = {}
local sequence = 0

local function ensureStateFolder()
	if typeof(makefolder) == "function" and typeof(isfolder) == "function" and not isfolder(stateFolder) then
		makefolder(stateFolder)
	end
end

if typeof(writefile) == "function" then
	ensureStateFolder()
	writefile(logFile, "")
end

-- Console output stays human-readable; the file retains structured evidence.
local function writeLog(stage, message, data, showInConsole)
	sequence += 1
	local suffix = ""
	if data ~= nil then
		local ok, encoded = pcall(HttpService.JSONEncode, HttpService, data)
		suffix = " | " .. (ok and encoded or tostring(data))
	end
	local line = string.format("[FastMode][%03d][%s] %s%s", sequence, stage, message, suffix)
	if showInConsole and not consoleStatusOnly then print("[FastMode] " .. message) end
	table.insert(logBuffer, line)
	if typeof(appendfile) == "function" then
		appendfile(logFile, line .. "\n")
	elseif typeof(writefile) == "function" then
		writefile(logFile, table.concat(logBuffer, "\n") .. "\n")
	end
end

local function log(stage, message, data)
	writeLog(stage, message, data, true)
end

local function debugLog(stage, message, data)
	if Settings.debug then writeLog(stage, message, data, false) end
end

local function fail(stage, message)
	log("ERROR", stage .. ": " .. message)
	error(string.format("[FastMode][%s] %s", stage, message), 0)
end

local function waitUntil(predicate, timeout)
	local interval = tonumber(Bootstrap.statePollInterval) or 0.2
	local deadline = os.clock() + (tonumber(timeout) or tonumber(Bootstrap.verifyTimeout) or 10)
	repeat
		local ok, result = pcall(predicate)
		if ok and result then return true end
		task.wait(interval)
	until os.clock() >= deadline
	local ok, result = pcall(predicate)
	return ok and result == true
end

local function isPlayerData(value)
	if typeof(value) ~= "table" then return false end
	local inventory = rawget(value, "Inventory")
	return typeof(inventory) == "table"
		and typeof(rawget(inventory, "Towers")) == "table"
		and typeof(rawget(inventory, "Currency")) == "table"
		and typeof(rawget(value, "ProfileData")) == "table"
end

-- The getgc index drifts each session, so resolve by structure rather than index.
local playerData
local playerDataSource
local function scanPlayerDataOnce()
	if isPlayerData(playerData) then return playerData end
	assert(typeof(getgc) == "function", "FastMode requires getgc(true).")
	local ok, objects = pcall(getgc, true)
	if not ok or typeof(objects) ~= "table" then fail("RUNTIME", "getgc(true) failed.") end
	for index, object in ipairs(objects) do
		if isPlayerData(object) then
			playerData = object
			playerDataSource = "getgc[" .. index .. "]"
			break
		end
		if typeof(object) == "table" and isPlayerData(rawget(object, "PlayerData")) then
			playerData = rawget(object, "PlayerData")
			playerDataSource = "getgc[" .. index .. "].PlayerData"
			break
		end
	end
	return playerData
end

-- The first Auto-Execute scan often occurs while critical lobby assets are still
-- loading. Re-run getgc so newly-created PlayerData tables can actually appear;
-- sleeping while retaining the first snapshot would never resolve the race.
local function resolvePlayerData()
	if isPlayerData(playerData) then return playerData end
	local timeout = tonumber(Bootstrap.runtimeLoadTimeout) or 60
	local interval = tonumber(Bootstrap.runtimeDiscoveryInterval) or 0.5
	local deadline = os.clock() + timeout
	log("WAIT", "Waiting for authoritative lobby PlayerData before bootstrap actions.", {
		timeout = timeout,
		placeId = game.PlaceId,
	})
	repeat
		if scanPlayerDataOnce() then break end
		task.wait(interval)
	until os.clock() >= deadline
	if not playerData then
		fail("RUNTIME", "Live PlayerData was not found before the bounded lobby-load timeout.")
	end
	debugLog("RUNTIME", "Resolved authoritative PlayerData.", { source = playerDataSource })
	return playerData
end

local function readGems()
	local data = resolvePlayerData()
	local inventory = rawget(data, "Inventory")
	local currency = typeof(inventory) == "table" and rawget(inventory, "Currency") or nil
	if typeof(currency) ~= "table" then fail("GEMS", "PlayerData.Inventory.Currency disappeared.") end
	local rawValue = rawget(currency, "Gems")
	if rawValue == nil then return 0 end
	local value = tonumber(rawValue)
	if not value then fail("GEMS", "PlayerData.Inventory.Currency.Gems is non-numeric.") end
	return value
end

local function readTotalSummons()
	local profile = rawget(resolvePlayerData(), "ProfileData")
	local value = typeof(profile) == "table" and tonumber(rawget(profile, "TotalSummons")) or nil
	if value == nil then fail("GATE", "PlayerData.ProfileData.TotalSummons was not found.") end
	return value
end

-- Protect configured units as soon as they appear after a summon batch. LockTower
-- is toggle-like, so it is invoked only when the authoritative record is not
-- already Locked. Its boolean return is mirrored exactly like the game's callback.
local function towerUUIDSnapshot()
	local result = {}
	local data = resolvePlayerData()
	local inventory = rawget(data, "Inventory")
	local currentTowers = typeof(inventory) == "table" and rawget(inventory, "Towers") or nil
	if typeof(currentTowers) == "table" then
		for uuid in next, currentTowers do result[uuid] = true end
	end
	return result
end

local function lockConfiguredUnits(context, beforeUUIDs)
	local progression = Config.unitProgression
	if typeof(progression) ~= "table"
		or progression.lockNewUnitsAfterSummon == false
		or typeof(progression.lockIdentifiers) ~= "table" then
		return
	end

	local data = resolvePlayerData()
	local inventory = rawget(data, "Inventory")
	local currentTowers = typeof(inventory) == "table" and rawget(inventory, "Towers") or nil
	if typeof(currentTowers) ~= "table" then return end
	local remote = ReplicatedStorage:WaitForChild("Remotes")
		:WaitForChild("InventoryRemotes"):WaitForChild("InventoryFunction")

	for uuid, record in next, currentTowers do
		local isNew = beforeUUIDs == nil or beforeUUIDs[uuid] ~= true
		local identifier = typeof(record) == "table" and rawget(record, "Name") or nil
		if isNew and typeof(identifier) == "string"
			and rawget(progression.lockIdentifiers, identifier) == true
			and rawget(record, "Locked") ~= true then
			local ok, locked = pcall(remote.InvokeServer, remote, "LockTower", uuid)
			if ok and locked == true then record.Locked = true end
			log("LOCK", string.format("%s %s (%s): server Locked=%s.",
				tostring(context), tostring(identifier), tostring(uuid), tostring(locked)), {
				invokeSucceeded = ok,
				verified = ok and locked == true and rawget(record, "Locked") == true,
			})
		end
	end
end

local function tableContainsValue(value, target)
	if typeof(value) ~= "table" then return false end
	for _, child in next, value do
		if tostring(child) == tostring(target) then return true end
	end
	return false
end

local function isCodeRedeemed(code)
	return tableContainsValue(rawget(resolvePlayerData(), "RedeemedCodes"), code)
end

local function readDailyState()
	local daily = rawget(resolvePlayerData(), "DailyRewards")
	if typeof(daily) ~= "table" then return { missing = true } end
	return {
		LastClaimTime = tonumber(rawget(daily, "LastClaimTime")) or 0,
		CurrentDay = tonumber(rawget(daily, "CurrentDay")) or 0,
		DailySpinLastClaimTime = tonumber(rawget(daily, "DailySpinLastClaimTime")) or 0,
	}
end

-- PlayerData.Quests is authoritative even when the Quests UI was never opened.
-- Count every nested record whose Claimable flag is true and which is not already
-- Claimed; this covers Daily/Weekly and future server-added quest categories.
local function readQuestClaimState()
	local quests = rawget(resolvePlayerData(), "Quests")
	local result = {
		available = typeof(quests) == "table",
		claimable = 0,
		claimed = 0,
		records = 0,
	}
	if typeof(quests) ~= "table" then return result end

	local visited = {}
	local function visit(value)
		if typeof(value) ~= "table" or visited[value] then return end
		visited[value] = true
		local claimable = rawget(value, "Claimable")
		local claimed = rawget(value, "Claimed")
		if claimable ~= nil or claimed ~= nil then
			result.records = result.records + 1
			if claimed == true then result.claimed = result.claimed + 1 end
			if claimable == true and claimed ~= true then result.claimable = result.claimable + 1 end
		end
		for _, child in next, value do
			if typeof(child) == "table" then visit(child) end
		end
	end
	visit(quests)
	return result
end

-- Auto Sell belongs to InGameSettings.lua, but FastMode is the consumer that must
-- not summon before that toggle is proven. Read the same authoritative PlayerData
-- branch here as a readiness gate; FastMode never fires ToggleAutoSell itself.
local function configuredAutoSellReady()
	local settings = Config.inGameSettings
	if typeof(settings) ~= "table" or settings.enabled == false or typeof(settings.autoSell) ~= "table" then
		return true
	end
	local autoSell = rawget(resolvePlayerData(), "AutoSell")
	-- AutoSell is sparse: nil means every configured rarity is currently false.
	-- A non-nil non-table value is malformed and must remain unresolved.
	if autoSell ~= nil and typeof(autoSell) ~= "table" then return false end
	for banner, rarityConfig in next, settings.autoSell do
		if typeof(rarityConfig) ~= "table" then return false end
		local bannerState = typeof(autoSell) == "table" and rawget(autoSell, banner) or nil
		if bannerState ~= nil and typeof(bannerState) ~= "table" then return false end
		for rarity, desired in next, rarityConfig do
			if typeof(desired) ~= "boolean" then return false end
			local current = typeof(bannerState) == "table" and rawget(bannerState, rarity) or nil
			if current == nil then current = false end
			if current ~= desired then return false end
		end
	end
	return true
end

local function readPlayTimeState(index)
	local branch = rawget(resolvePlayerData(), "PlayTimeRewards")
	local claimed = typeof(branch) == "table" and rawget(branch, "Claimed") or nil
	local isClaimed = typeof(claimed) == "table"
		and (rawget(claimed, index) ~= nil or rawget(claimed, tostring(index)) ~= nil)
	return {
		claimed = isClaimed,
		playTime = typeof(branch) == "table" and tonumber(rawget(branch, "PlayTime")) or nil,
	}
end

local function readBattlepassState(season)
	local battlepasses = rawget(resolvePlayerData(), "Battlepasses")
	local record = typeof(battlepasses) == "table" and rawget(battlepasses, season) or nil
	return {
		Claimed = typeof(record) == "table" and tonumber(rawget(record, "Claimed")) or 0,
		PremiumClaimed = typeof(record) == "table" and tonumber(rawget(record, "PremiumClaimed")) or 0,
		Exp = typeof(record) == "table" and tonumber(rawget(record, "Exp")) or 0,
	}
end

local function changedDaily(left, right, includeSpin)
	if includeSpin then return left.DailySpinLastClaimTime ~= right.DailySpinLastClaimTime end
	return left.LastClaimTime ~= right.LastClaimTime or left.CurrentDay ~= right.CurrentDay
end

local function loadState()
	local default = {
		version = 2,
		userId = player.UserId,
		bootstrapStarted = false,
		status = "new",
		claimResults = { codes = {}, playTimeRewards = {} },
		verifiedBatches = 0,
	}
	if typeof(isfile) ~= "function" or typeof(readfile) ~= "function" or not isfile(stateFile) then
		return default
	end
	local ok, decoded = pcall(HttpService.JSONDecode, HttpService, readfile(stateFile))
	if not ok or typeof(decoded) ~= "table" or decoded.userId ~= player.UserId or decoded.version ~= 2 then
		fail("STATE", "Bootstrap state is invalid: " .. stateFile)
	end
	decoded.claimResults = typeof(decoded.claimResults) == "table" and decoded.claimResults or {}
	decoded.claimResults.codes = typeof(decoded.claimResults.codes) == "table" and decoded.claimResults.codes or {}
	decoded.claimResults.playTimeRewards = typeof(decoded.claimResults.playTimeRewards) == "table"
		and decoded.claimResults.playTimeRewards or {}
	decoded.verifiedBatches = math.max(0, math.floor(tonumber(decoded.verifiedBatches) or 0))
	return decoded
end

local function saveState(state, reason)
	if typeof(writefile) ~= "function" then
		fail("STATE", "writefile is unavailable; crash-safe summon persistence is required.")
	end
	ensureStateFolder()
	state.updatedAt = os.time()
	state.lastReason = reason
	writefile(stateFile, HttpService:JSONEncode(state))
	debugLog("STATE", "Persisted bootstrap state: " .. reason, {
		status = state.status,
		targetBatches = state.targetBatches,
		verifiedBatches = state.verifiedBatches,
	})
end

local function classifyRedeemResponse(invokeSucceeded, response)
	if not invokeSucceeded then return "retryable" end
	local text = string.lower(tostring(response or ""))
	if string.find(text, "try again", 1, true)
		or string.find(text, "few seconds", 1, true)
		or string.find(text, "too fast", 1, true) then return "retryable" end
	if string.find(text, "code redeemed", 1, true) then return "redeemed" end
	if string.find(text, "already", 1, true) then return "already_redeemed" end
	if string.find(text, "invalid", 1, true)
		or string.find(text, "expired", 1, true)
		or string.find(text, "not valid", 1, true)
		or string.find(text, "doesn't exist", 1, true) then return "invalid" end
	return "unknown"
end

local state = loadState()

local function redeemCodes()
	local codesFunction = ReplicatedStorage:WaitForChild("LobbyRemotes"):WaitForChild("CodesFunction")
	local requestDelay = tonumber(Settings.redeemRequestDelay) or 3
	local retryDelay = tonumber(Settings.redeemRetryDelay) or requestDelay
	local maxAttempts = math.max(1, math.floor(tonumber(Settings.redeemMaxAttempts) or 3))
	local lastRequestAt

	local function pace()
		if not lastRequestAt then return end
		local remaining = requestDelay - (os.clock() - lastRequestAt)
		if remaining > 0 then task.wait(remaining) end
	end

	for _, code in ipairs(Settings.redeemCodes or {}) do
		if isCodeRedeemed(code) then
			state.claimResults.codes[code] = { status = "already_in_player_data", verified = true }
			debugLog("CLAIM_CODE", "Code already exists in PlayerData; skipped.", { code = code })
		else
			local prior = state.claimResults.codes[code]
			if typeof(prior) == "table" and prior.terminal == true then
				debugLog("CLAIM_CODE", "Code has a persisted terminal response; skipped.", { code = code, status = prior.status })
			else
				for attempt = 1, maxAttempts do
					pace()
					local beforeGems = readGems()
					log("ACTION", string.format("Redeem code %s (%d/%d).", code, attempt, maxAttempts))
					local ok, response = pcall(codesFunction.InvokeServer, codesFunction, "RedeemCode", code)
					lastRequestAt = os.clock()
					local status = classifyRedeemResponse(ok, response)
					local verified = waitUntil(function()
						return isCodeRedeemed(code) or readGems() ~= beforeGems
					end, Bootstrap.claimSettlementTimeout)
					local afterGems = readGems()
					local terminal = verified or status == "redeemed"
						or status == "already_redeemed" or status == "invalid"
					state.claimResults.codes[code] = {
						status = status,
						terminal = terminal,
						verified = verified or isCodeRedeemed(code),
						response = tostring(response),
						gemsBefore = beforeGems,
						gemsAfter = afterGems,
						attempts = attempt,
					}
					saveState(state, "code_" .. tostring(code))
					if terminal then break end
					if attempt < maxAttempts then task.wait(retryDelay) end
				end
			end
		end
	end
end

local function claimDailyReward()
	if not (Settings.claimRewards and Settings.claimRewards.dailyReward) then return end
	local remote = ReplicatedStorage:WaitForChild("Remotes"):WaitForChild("RemoteEvent")
	local before = readDailyState()
	local beforeGems = readGems()
	log("ACTION", "Claim Daily Reward.")
	remote:FireServer("ClaimDailyReward", tostring(Settings.dailyRewardType or "Normal"))
	local verified = waitUntil(function()
		return changedDaily(before, readDailyState(), false) or readGems() ~= beforeGems
	end, Bootstrap.claimSettlementTimeout)
	state.claimResults.dailyReward = {
		attempted = true,
		verified = verified,
		before = before,
		after = readDailyState(),
		gemChange = readGems() - beforeGems,
	}
	saveState(state, "daily_reward_attempted")
	log("CLAIM", verified and "Daily Reward verified." or "Daily Reward unavailable; no state change.")
end

local function claimPlayTimeRewards()
	if not (Settings.claimRewards and Settings.claimRewards.playTimeRewards) then return end
	local remote = ReplicatedStorage:WaitForChild("LobbyRemotes"):WaitForChild("PlayTimeRewardsRemote")
	local pending = {}
	local gemsBefore = readGems()

	-- Playtime claims share one server-state branch and have no observed request
	-- rate limit. Send every unclaimed index first, then use one settlement window;
	-- waiting four seconds per unavailable index made a fresh-account run needlessly
	-- slow without adding stronger evidence.
	for _, rawIndex in ipairs(Settings.playTimeRewardIndices or {}) do
		local index = tonumber(rawIndex)
		if index then
			local before = readPlayTimeState(index)
			if before.claimed then
				state.claimResults.playTimeRewards[tostring(index)] = { verified = true, status = "already_claimed" }
			else
				log("ACTION", "Claim Playtime Reward index " .. tostring(index) .. ".")
				remote:FireServer("ClaimPlayTimeReward", index)
				table.insert(pending, { index = index, playTime = before.playTime })
			end
		end
	end

	if #pending > 0 then
		-- One shared bounded wait lets every server push settle, including later
		-- indices, while still costing less than six sequential timeouts.
		task.wait(tonumber(Bootstrap.claimSettlementTimeout) or 4)
	end

	local gemsAfter = readGems()
	for _, entry in ipairs(pending) do
		local verified = readPlayTimeState(entry.index).claimed
		state.claimResults.playTimeRewards[tostring(entry.index)] = {
			attempted = true,
			verified = verified,
			playTime = entry.playTime,
			-- This delta belongs to the batch of playtime claims. Per-index Gem
			-- attribution would be invented when several claims settle together.
			batchGemChange = gemsAfter - gemsBefore,
		}
		log("CLAIM", verified
			and ("Playtime Reward " .. entry.index .. " verified.")
			or ("Playtime Reward " .. entry.index .. " unavailable; no state change."))
	end
	saveState(state, "playtime_rewards_settled")
end

local function claimBattlepass()
	if not (Settings.claimRewards and Settings.claimRewards.battlepass) then return end
	local season = tostring(Settings.battlepassSeason or "Season1")
	local remote = ReplicatedStorage:WaitForChild("LobbyRemotes"):WaitForChild("BattlepassRemote")
	local before = readBattlepassState(season)
	local beforeGems = readGems()
	log("ACTION", "Claim Battlepass " .. season .. " once.")
	remote:FireServer("ClaimBattlepass", season)
	local verified = waitUntil(function()
		local after = readBattlepassState(season)
		return after.Claimed ~= before.Claimed
			or after.PremiumClaimed ~= before.PremiumClaimed
			or readGems() ~= beforeGems
	end, Bootstrap.claimSettlementTimeout)
	state.claimResults.battlepass = {
		attempted = true,
		verified = verified,
		season = season,
		before = before,
		after = readBattlepassState(season),
		gemChange = readGems() - beforeGems,
	}
	saveState(state, "battlepass_attempted")
	log("CLAIM", verified and "Battlepass claim verified." or "Battlepass unavailable; no state change.")
end

local function spinDailyWheel()
	if not (Settings.claimRewards and Settings.claimRewards.dailyWheel) then return end
	local remote = ReplicatedStorage:WaitForChild("Remotes"):WaitForChild("DailyWheelFunction")
	local before = readDailyState()
	local beforeGems = readGems()
	log("ACTION", "Spin Daily Wheel.")
	local ok, response = pcall(remote.InvokeServer, remote, true)
	local verified = waitUntil(function()
		return changedDaily(before, readDailyState(), true) or readGems() ~= beforeGems
	end, Bootstrap.claimSettlementTimeout)
	state.claimResults.dailyWheel = {
		attempted = true,
		invokeSucceeded = ok,
		verified = verified,
		response = tostring(response),
		before = before,
		after = readDailyState(),
		gemChange = readGems() - beforeGems,
	}
	saveState(state, "daily_wheel_attempted")
	log("CLAIM", verified and "Daily Wheel verified." or "Daily Wheel unavailable; no state change.")
end

local function claimAllQuests()
	if not (Settings.claimRewards and Settings.claimRewards.quests) then return end
	local before = readQuestClaimState()
	if not before.available then
		state.claimResults.quests = { attempted = false, verified = false, status = "quest_state_missing" }
		log("SKIP", "PlayerData.Quests is unavailable; ClaimAllQuests was not fired.")
		return
	end
	if before.claimable <= 0 then
		state.claimResults.quests = { attempted = false, verified = true, status = "nothing_claimable", before = before }
		debugLog("CLAIM_QUESTS", "No authoritative Claimable=true quest exists; remote skipped.", before)
		return
	end

	local remote = ReplicatedStorage:WaitForChild("LobbyRemotes"):WaitForChild("QuestRemote")
	local beforeGems = readGems()
	log("ACTION", string.format("Claim All Quests (%d claimable).", before.claimable))
	remote:FireServer("ClaimAllQuests")
	local verified = waitUntil(function()
		return readQuestClaimState().claimable < before.claimable
	end, Bootstrap.claimSettlementTimeout)
	local after = readQuestClaimState()
	state.claimResults.quests = {
		attempted = true,
		verified = verified,
		before = before,
		after = after,
		gemChange = readGems() - beforeGems,
	}
	saveState(state, "quests_attempted")
	log("CLAIM", verified and "Claim All Quests verified from PlayerData."
		or "Claim All Quests was not confirmed; no blind retry was sent.")
end

-- Independent reward endpoints settle concurrently. This removes the old sum of
-- several full verification timeouts while preserving each function's own
-- PlayerData proof and error handling.
local function claimConfiguredRewards()
	local jobs = {
		{ name = "DailyReward", callback = claimDailyReward },
		{ name = "PlayTimeRewards", callback = claimPlayTimeRewards },
		{ name = "Battlepass", callback = claimBattlepass },
		{ name = "DailyWheel", callback = spinDailyWheel },
		{ name = "Quests", callback = claimAllQuests },
	}
	local remaining = #jobs
	local failures = {}
	for _, job in ipairs(jobs) do
		-- Capture per-iteration values before spawning so executor Lua versions that
		-- reuse loop variables cannot make every worker call the final callback.
		local jobName = job.name
		local callback = job.callback
		task.spawn(function()
			local ok, message = xpcall(callback, function(errorMessage)
				return debug and debug.traceback and debug.traceback(tostring(errorMessage), 2)
					or tostring(errorMessage)
			end)
			if not ok then failures[jobName] = message end
			remaining -= 1
		end)
	end

	local timeout = (tonumber(Bootstrap.claimSettlementTimeout) or 4) + 5
	if not waitUntil(function() return remaining == 0 end, timeout) then
		fail("CLAIMS", "Concurrent reward jobs exceeded their bounded settlement window.")
	end
	for name, message in next, failures do
		fail("CLAIMS", name .. " failed: " .. tostring(message))
	end
end

local function run()
	local currentTotal = readTotalSummons()
	local newAccountValue = tonumber(Bootstrap.newAccountTotalSummons) or 0
	local resumable = state.bootstrapStarted == true and state.status ~= "complete"

	log("STEP", string.format("[1/4] TotalSummons=%d | state=%s", currentTotal, tostring(state.status)))
	lockConfiguredUnits("existing inventory")

	-- Every account may claim free rewards. TotalSummons gates only the summon
	-- bootstrap, so an existing account can redeem a newly-added code or collect a
	-- currently available Daily/Playtime/Battlepass/Wheel reward without spending.
	if not resumable and currentTotal ~= newAccountValue then
		-- An existing account is not a new account, but it still accumulates Gems from
		-- farming, newly added codes, and today's rewards. Ending the run here used to
		-- strand every one of them: FastMode is the only module in the project that
		-- spends Gems, so once this branch was taken the account could never summon
		-- again. Claim first, then re-evaluate the budget against the real balance.
		log("GATE", "Existing account detected; claiming rewards before re-evaluating the summon budget.", {
			totalSummons = currentTotal,
			expectedNewAccountValue = newAccountValue,
		})
		state.lastClaimsOnlyStartedAt = os.time()
		state.claimResults = state.claimResults or { codes = {}, playTimeRewards = {} }
		saveState(state, "existing_account_claims_started")
		log("STEP", "[2/4] Claiming every currently available free reward...")
		redeemCodes()
		claimConfiguredRewards()
		state.lastClaimsOnlyCompletedAt = os.time()

		local claimBatchCost = math.max(1, tonumber(Bootstrap.summonBatchCost) or 500)
		local claimMaximum = math.max(0, math.floor(tonumber(Bootstrap.maximumSummonBatches) or 10))
		local gemsAfterClaims = readGems()
		local affordable = math.min(math.floor(gemsAfterClaims / claimBatchCost), claimMaximum)

		if Bootstrap.spendAllAvailableGems ~= true or affordable < 1 then
			saveState(state, "existing_account_claims_complete_no_summons")
			log("STEP", string.format("[4/4] DONE claims only | Gems=%d | TotalSummons=%d | no summons.",
				gemsAfterClaims, readTotalSummons()))
			return {
				status = "CLAIMS_ONLY_COMPLETE",
				gems = gemsAfterClaims,
				totalSummons = readTotalSummons(),
				stateFile = stateFile,
				logFile = logFile,
			}
		end

		-- Enough for at least one ten-pull. Open a fresh summon budget for this run and
		-- fall through to the normal summon loop instead of returning.
		state.bootstrapStarted = true
		state.startedAt = os.time()
		state.startTotalSummons = readTotalSummons()
		state.verifiedBatches = 0
		state.gemsAfterClaims = gemsAfterClaims
		state.targetBatches = affordable
		state.status = "summoning"
		saveState(state, "existing_account_summon_budget_opened")
		log("BUDGET", string.format("Gems=%d | ten-pull target=%d/%d for this existing account.",
			gemsAfterClaims, affordable, claimMaximum))
		-- The budget is now persisted, so the blocks below must treat this run the
		-- same way they treat a resumed bootstrap: no re-claiming, no target reset.
		resumable = true
	end

	if not resumable then
		-- A completed zero-summon account may be re-opened if it later receives Gems.
		-- The user's rule explicitly allows spending all Gems while TotalSummons is 0.
		state.bootstrapStarted = true
		state.status = "claiming"
		state.startedAt = os.time()
		state.startTotalSummons = currentTotal
		state.targetBatches = nil
		state.verifiedBatches = 0
		state.claimResults = { codes = {}, playTimeRewards = {} }
		saveState(state, "bootstrap_started_before_remote_calls")
		log("GATE", "New-account gate verified and persisted before any remote call.")
	else
		log("GATE", "Resuming persisted bootstrap despite non-zero TotalSummons.")
	end

	-- Reconcile a crash that occurred after the server accepted a summon but before
	-- the local state file recorded it.
	local expectedIncrease = math.max(1, tonumber(Bootstrap.expectedSummonsPerBatch) or 10)
	local observedBatches = math.floor(math.max(0, currentTotal - (tonumber(state.startTotalSummons) or 0)) / expectedIncrease)
	state.verifiedBatches = math.max(tonumber(state.verifiedBatches) or 0, observedBatches)
	state.uncertainBatch = nil
	saveState(state, "reconciled_total_summons")

	if state.status == "claiming" then
		log("STEP", "[2/4] Claiming every currently available free reward...")
		redeemCodes()
		claimConfiguredRewards()

		-- Freeze the batch count once after all claims settle. Later farmed Gems can
		-- never expand this persisted target on a resumed run.
		local batchCost = math.max(1, tonumber(Bootstrap.summonBatchCost) or 500)
		local maximum = math.max(0, math.floor(tonumber(Bootstrap.maximumSummonBatches) or 10))
		state.gemsAfterClaims = readGems()
		state.targetBatches = math.min(math.floor(state.gemsAfterClaims / batchCost), maximum)
		state.status = "summoning"
		saveState(state, "frozen_summon_target_after_claims")
		log("BUDGET", string.format("Gems=%d | frozen ten-pull target=%d/%d.",
			state.gemsAfterClaims, state.targetBatches, maximum))
	end

	local batchCost = math.max(1, tonumber(Bootstrap.summonBatchCost) or 500)
	local targetBatches = math.max(0, math.floor(tonumber(state.targetBatches) or 0))
	-- Set when a batch cannot be proven. The summon phase stops, but the run stays
	-- terminal and non-fatal so InGameSettings, UnitProgression and routing still
	-- happen; the next run reconciles from the authoritative TotalSummons.
	local summonWarning = nil
	if state.verifiedBatches < targetBatches then
		log("WAIT", "Waiting for configured Auto Sell state before the first remaining summon batch.")
		local autoSellReady = waitUntil(configuredAutoSellReady,
			(Config.inGameSettings and tonumber(Config.inGameSettings.verifyTimeout) or 5) + 3)
		if not autoSellReady then
			-- AutoSell only controls disposal of low-rarity pulls. Some executors can
			-- send its remote but cannot observe the replaced PlayerData table, so it
			-- must never block the summon that creates a fresh account's first team.
			state.autoSellVerificationDegraded = true
			saveState(state, "autosell_unverified_summons_continue")
			log("AUTO_SELL_WARNING", "AutoSell was not verified; summon batches will continue.")
		else
			state.autoSellVerificationDegraded = nil
			saveState(state, "autosell_verified_before_summons")
			log("VERIFY", "Configured Auto Sell state is authoritative and ready.")
		end
	end
	local summonFunction = ReplicatedStorage:WaitForChild("LobbyRemotes"):WaitForChild("SummonFunction")
	log("STEP", string.format("[3/4] Summoning verified batches %d/%d.", state.verifiedBatches, targetBatches))

	while state.verifiedBatches < targetBatches do
		local batchNumber = state.verifiedBatches + 1
		local beforeGems = readGems()
		local beforeTotal = readTotalSummons()
		local beforeTowerUUIDs = towerUUIDSnapshot()
		if beforeGems < batchCost then
			log("SUMMON", "Current Gems cannot fund the remaining frozen batch; stopping safely.", {
				gems = beforeGems,
				batchCost = batchCost,
			})
			break
		end

		state.pendingBatch = {
			batchNumber = batchNumber,
			gemsBefore = beforeGems,
			totalSummonsBefore = beforeTotal,
			writtenAt = os.time(),
		}
		saveState(state, "write_ahead_batch_" .. tostring(batchNumber))

		log("ACTION", string.format("Standard ten-pull %d/%d.", batchNumber, targetBatches))
		local ok, response = pcall(
			summonFunction.InvokeServer,
			summonFunction,
			"SummonTower",
			tostring(Settings.summonBanner or "Standard"),
			tonumber(Settings.summonBatchSize) or 10
		)
		local verified = waitUntil(function()
			return readGems() <= beforeGems - batchCost
				and readTotalSummons() >= beforeTotal + expectedIncrease
		end, Bootstrap.verifyTimeout)
		task.wait(tonumber(Settings.summonSettlementDelay) or 1)

		local afterGems = readGems()
		local afterTotal = readTotalSummons()
		if not verified then
			-- The dual-proof window can expire on a batch that merely settled late.
			-- TotalSummons stays authoritative either way, so reconcile against it
			-- before deciding anything: a landed batch is counted here instead of
			-- being re-fired and paid for twice on the next run.
			local settled = math.floor(
				math.max(0, afterTotal - (tonumber(state.startTotalSummons) or 0)) / expectedIncrease)
			state.verifiedBatches = math.max(tonumber(state.verifiedBatches) or 0, settled)
			state.uncertainBatch = {
				batchNumber = batchNumber,
				invokeSucceeded = ok,
				response = tostring(response),
				gemsBefore = beforeGems,
				gemsAfter = afterGems,
				totalSummonsBefore = beforeTotal,
				totalSummonsAfter = afterTotal,
				reconciledBatches = state.verifiedBatches,
			}
			state.pendingBatch = nil
			summonWarning = string.format(
				"batch %d was not proven within %ss; summons stopped for this run",
				batchNumber, tostring(Bootstrap.verifyTimeout))
			saveState(state, "unverified_batch_stopped_without_retry")
			-- Never re-fire an unproven batch inside the same run: the server may have
			-- taken the Gems already. Stopping the summon phase is enough to stay safe.
			-- Killing the controller here was not -- it also cost the account every
			-- later worker, because main treats a failed FastMode as a fatal route gate.
			log("UNCERTAIN", "Server result was not proven by both Gems and TotalSummons; "
				.. "summons stopped for this run and left to reconcile on the next run.",
				state.uncertainBatch)
			break
		end

		local reconciled = math.floor(math.max(0, afterTotal - (tonumber(state.startTotalSummons) or 0)) / expectedIncrease)
		state.verifiedBatches = math.max(batchNumber, reconciled)
		state.pendingBatch = nil
		state.uncertainBatch = nil
		saveState(state, "verified_batch_" .. tostring(batchNumber))
		log("SUMMON", string.format("Batch %d verified: Gems %d -> %d | TotalSummons %d -> %d.",
			batchNumber, beforeGems, afterGems, beforeTotal, afterTotal))
		lockConfiguredUnits("summon batch " .. tostring(batchNumber), beforeTowerUUIDs)
	end

	-- Only a run that proved every batch may mark the state complete. Leaving it
	-- unfinished is what lets the next run resume and spend the remaining Gems.
	state.status = summonWarning == nil and "complete" or "summons_incomplete"
	state.completedAt = os.time()
	state.finishedGems = readGems()
	state.finishedTotalSummons = readTotalSummons()
	state.pendingBatch = nil
	saveState(state, summonWarning == nil and "bootstrap_complete"
		or "bootstrap_stopped_with_unverified_batch")

	log("STEP", string.format("[4/4] %s | batches=%d/%d | Gems=%d | TotalSummons=%d.",
		summonWarning == nil and "DONE" or "STOPPED EARLY",
		state.verifiedBatches, targetBatches, state.finishedGems, state.finishedTotalSummons))
	return {
		status = summonWarning == nil and "COMPLETE" or "COMPLETE_WITH_WARNINGS",
		warning = summonWarning,
		verifiedBatches = state.verifiedBatches,
		targetBatches = targetBatches,
		gems = state.finishedGems,
		totalSummons = state.finishedTotalSummons,
		stateFile = stateFile,
		logFile = logFile,
	}
end

local ok, result = xpcall(run, function(message)
	return debug and debug.traceback and debug.traceback(tostring(message), 2) or tostring(message)
end)

if environment.AnimeOriginFastModeRunning == runToken then
	environment.AnimeOriginFastModeRunning = nil
end
environment.AnimeOriginFastModeReport = ok and result or { status = "FAILED", error = result, logFile = logFile }
publishLifecycle(ok and "COMPLETE" or "FAILED", {
	reportStatus = ok and result.status or "FAILED",
	stateFile = stateFile,
	logFile = logFile,
	error = not ok and result or nil,
})
if not ok then
	log("FATAL", "Execution stopped; persisted state can resume safely.", { trace = result, logFile = logFile })
	error(result, 0)
end
return result
