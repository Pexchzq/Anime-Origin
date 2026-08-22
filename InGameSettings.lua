--[[
	Anime Origin settings synchronizer

	This file is deliberately separate from AutoPlay.lua.

	SetSetting has two behaviors:
	  * Toggle-only: SetSetting, settingName
	  * Explicit:    SetSetting, settingName, desiredValue

	The toggle-only form is never fired blindly. This script first resolves the
	live server-fed settings table, compares its current value with Config.lua,
	then fires exactly once only when the value differs. Every mutation is verified
	by reading runtime state again. If a trustworthy live table cannot be found,
	the script writes discovery evidence and sends no toggle remotes.

	Summon Auto Sell follows the same rule through PlayerData.AutoSell: the
	ToggleAutoSell remote is sent only when the live rarity value differs.
]]

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local HttpService = game:GetService("HttpService")
local Workspace = game:GetService("Workspace")

local environment = getgenv()

-- MacSploit launches enabled Auto-Execute files concurrently and does not
-- guarantee filename order. Wait for Config.lua and LocalPlayer instead of
-- failing during the first frames of a join/teleport.
local function waitForAnimeOriginConfig(timeout)
	local deadline = os.clock() + (tonumber(timeout) or 30)
	repeat
		local config = environment.AnimeOriginConfig
		if typeof(config) == "table" then return config end
		task.wait(0.05)
	until os.clock() >= deadline
	error("[InGameSettings][AUTO_EXECUTE] Timed out waiting for Config.lua.", 0)
end

local function waitForLocalPlayer(timeout)
	local deadline = os.clock() + (tonumber(timeout) or 30)
	repeat
		if Players.LocalPlayer then return Players.LocalPlayer end
		task.wait(0.05)
	until os.clock() >= deadline
	error("[InGameSettings][AUTO_EXECUTE] Timed out waiting for LocalPlayer.", 0)
end

local player = waitForLocalPlayer()
local Config = waitForAnimeOriginConfig()

local Settings = Config.inGameSettings
assert(typeof(Settings) == "table", "Config.inGameSettings is missing.")
assert(Settings.enabled == true, "Config.inGameSettings.enabled is false.")
local consoleStatusOnly = typeof(Config.console) == "table"
	and Config.console.statusOnly == true
-- A boolean left by an older place cannot identify its JobId. New run tokens
-- block duplicates only inside the current server and allow clean auto-runs
-- after TeleportService moves the client to another place.
local previousRun = environment.AnimeOriginInGameSettingsRunning
assert(not (typeof(previousRun) == "table" and previousRun.jobId == game.JobId),
	"InGameSettings is already running in this server.")
local runToken = { jobId = game.JobId, userId = player.UserId, startedAt = os.time() }
environment.AnimeOriginInGameSettingsRunning = runToken

local stateFolder = tostring(Settings.stateFolder or "AnimeOrigin")
local reportFile = stateFolder .. "/InGameSettings_" .. tostring(player.UserId) .. "_latest.json"
local logFile = stateFolder .. "/InGameSettings_" .. tostring(player.UserId) .. "_latest.log"
local pollInterval = tonumber(Settings.statePollInterval) or 0.2
local verifyTimeout = tonumber(Settings.verifyTimeout) or 5
local report = {
	version = 1,
	userId = player.UserId,
	placeId = game.PlaceId,
	jobId = game.JobId,
	actions = {},
	candidates = {},
	unresolved = {},
	warnings = {},
}
local controller = {
	stopRequested = false,
	report = report,
}
function controller.stop()
	controller.stopRequested = true
end
environment.AnimeOriginInGameSettings = controller

local logBuffer, sequence = {}, 0

local function ensureFolder()
	if typeof(makefolder) == "function" and typeof(isfolder) == "function" and not isfolder(stateFolder) then
		makefolder(stateFolder)
	end
end

local function encode(value)
	local ok, result = pcall(HttpService.JSONEncode, HttpService, value)
	return ok and result or tostring(value)
end

local function log(stage, message, data, console)
	sequence += 1
	local suffix = data ~= nil and (" | " .. encode(data)) or ""
	local line = string.format("[InGameSettings][%03d][%s] %s%s", sequence, stage, message, suffix)
	table.insert(logBuffer, line)
	if console ~= false and not consoleStatusOnly then print("[InGameSettings] " .. message) end
	if typeof(appendfile) == "function" then
		appendfile(logFile, line .. "\n")
	elseif typeof(writefile) == "function" then
		writefile(logFile, table.concat(logBuffer, "\n") .. "\n")
	end
end

local function saveReport(reason)
	report.reason = reason
	report.updatedAt = os.time()
	if typeof(writefile) == "function" then
		writefile(reportFile, HttpService:JSONEncode(report))
	end
end

local function fail(stage, message)
	report.status = "FAILED"
	report.failedStage = stage
	log("ERROR", stage .. ": " .. message)
	saveReport(stage .. ": " .. message)
	error(string.format("[InGameSettings][%s] %s", stage, message), 0)
end

ensureFolder()
if typeof(writefile) == "function" then writefile(logFile, "") end

local desiredKeys = {}
for key in pairs(Settings.toggles or {}) do desiredKeys[key] = true end
for key in pairs(Settings.values or {}) do desiredKeys[key] = true end

local gcObjects
local function getGCObjects(refresh)
	if gcObjects and refresh ~= true then return gcObjects end
	assert(typeof(getgc) == "function", "getgc is unavailable.")
	local ok, objects = pcall(getgc, true)
	assert(ok and typeof(objects) == "table", "getgc(true) failed.")
	gcObjects = objects
	return objects
end

local function isPlayerData(value)
	if typeof(value) ~= "table" then return false end
	local inventory = rawget(value, "Inventory")
	return typeof(inventory) == "table" and typeof(rawget(inventory, "Towers")) == "table"
end

local function resolvePlayerData(refresh)
	local directCandidate, directSource
	-- Prefer a stable wrapper whose PlayerData field can be replaced by the
	-- server. Old direct PlayerData tables remain in getgc on some executors and
	-- made a successful AutoSell toggle look unchanged forever.
	for index, object in ipairs(getGCObjects(refresh)) do
		if typeof(object) == "table" then
			local nested = rawget(object, "PlayerData")
			if isPlayerData(nested) then return nested, "getgc[" .. index .. "].PlayerData" end
			if not directCandidate and isPlayerData(object) then
				directCandidate = object
				directSource = "getgc[" .. index .. "]"
			end
		end
	end
	return directCandidate, directSource
end

local function simpleValue(value)
	local kind = typeof(value)
	if kind == "string" or kind == "number" or kind == "boolean" or kind == "nil" then return value end
	return "<" .. kind .. ">"
end

local function inspectCandidate(value, path, authority, candidates, seen)
	if typeof(value) ~= "table" or seen[value] then return end
	seen[value] = true
	-- Never mistake the desired Config tables for current game state.
	if value == Config or value == Settings or value == Settings.toggles or value == Settings.values then return end

	local values, matches = {}, 0
	for key in pairs(desiredKeys) do
		local current = rawget(value, key)
		if current ~= nil then
			values[key] = simpleValue(current)
			matches += 1
		end
	end
	if matches > 0 then
		table.insert(candidates, {
			table = value,
			path = path,
			authority = authority,
			matches = matches,
			values = values,
			score = (authority == "PlayerData" and 100000 or 0) + matches,
		})
	end
end

local function scanPlayerData(root, rootPath, candidates, seen)
	local visited = {}
	local function visit(value, path, depth)
		if typeof(value) ~= "table" or visited[value] or depth > 8 then return end
		visited[value] = true
		inspectCandidate(value, path, "PlayerData", candidates, seen)
		local inspected = 0
		for key, child in next, value do
			inspected += 1
			if inspected > 1500 then break end
			if typeof(child) == "table" then
				visit(child, path .. "[" .. string.format("%q", tostring(key)) .. "]", depth + 1)
			end
		end
	end
	visit(root, rootPath, 0)
end

local namedSettingsKeys = {
	"Settings",
	"GameSettings",
	"UserSettings",
	"PlayerSettings",
	"SettingsData",
	"Preferences",
}

local function findSettingCandidates(refresh)
	local candidates = {}
	local seen = setmetatable({}, { __mode = "k" })
	local playerData, playerDataSource = resolvePlayerData(refresh)
	if playerData then scanPlayerData(playerData, playerDataSource, candidates, seen) end
	-- PlayerData descendants are authoritative and sufficient. Avoid scanning all
	-- getgc functions repeatedly during post-remote verification when one exists.
	if #candidates > 0 then
		table.sort(candidates, function(left, right)
			if left.score ~= right.score then return left.score > right.score end
			return left.path < right.path
		end)
		return candidates
	end

	for index, object in ipairs(getGCObjects(refresh)) do
		if typeof(object) == "table" then
			inspectCandidate(object, "getgc[" .. index .. "]", "getgc", candidates, seen)
			for _, key in ipairs(namedSettingsKeys) do
				local nested = rawget(object, key)
				if typeof(nested) == "table" then
					inspectCandidate(nested, "getgc[" .. index .. "][" .. string.format("%q", key) .. "]", "getgc", candidates, seen)
				end
			end
		end
	end

	if debug and typeof(debug.getupvalues) == "function" then
		for index, object in ipairs(getGCObjects(refresh)) do
			if typeof(object) == "function" then
				local ok, upvalues = pcall(debug.getupvalues, object)
				if ok and typeof(upvalues) == "table" then
					for upvalueIndex, upvalue in pairs(upvalues) do
						if typeof(upvalue) == "table" then
							inspectCandidate(upvalue, "getgc[" .. index .. "].upvalue[" .. tostring(upvalueIndex) .. "]", "upvalue", candidates, seen)
						end
					end
				end
			end
		end
	end

	table.sort(candidates, function(left, right)
		if left.score ~= right.score then return left.score > right.score end
		return left.path < right.path
	end)
	return candidates
end

-- Only a PlayerData descendant is authoritative enough for toggle decisions.
-- A getgc/upvalue match may be defaults or a UI-owned stale copy.
local function resolveAuthoritativeSettings(refresh)
	local candidates = findSettingCandidates(refresh)
	report.candidates = {}
	for index = 1, math.min(#candidates, 20) do
		local candidate = candidates[index]
		table.insert(report.candidates, {
			path = candidate.path,
			authority = candidate.authority,
			matches = candidate.matches,
			values = candidate.values,
		})
	end
	for _, candidate in ipairs(candidates) do
		if candidate.authority == "PlayerData" then return candidate end
	end
	return nil
end

local function normalizeBoolean(value)
	if typeof(value) == "boolean" then return value end
	if value == 1 or value == "1" then return true end
	if value == 0 or value == "0" then return false end
	if typeof(value) == "string" then
		local normalized = string.lower(value)
		if normalized == "true" or normalized == "on" or normalized == "enabled" then return true end
		if normalized == "false" or normalized == "off" or normalized == "disabled" then return false end
	end
	return nil
end

-- AutoSell is a sparse PlayerData branch rather than a SetSetting key. Verified
-- runtime evidence shows enabled values as AutoSell[banner][rarity] = true, while
-- a new account with the option disabled omits AutoSell/banner/rarity entirely.
-- Therefore a missing key under an authoritative PlayerData table means false;
-- malformed non-table values remain unresolved and never trigger a blind toggle.
local function currentAutoSell(banner, rarity, refresh)
	local playerData, source = resolvePlayerData(refresh)
	if typeof(playerData) ~= "table" then return nil, source, false end
	local baseSource = tostring(source or "<PlayerData>") .. ".AutoSell"
	local autoSell = rawget(playerData, "AutoSell")
	if autoSell == nil then return false, baseSource .. " (sparse default)", true end
	if typeof(autoSell) ~= "table" then return nil, baseSource .. " (malformed)", false end
	local bannerState = rawget(autoSell, banner)
	local bannerSource = baseSource .. "[" .. string.format("%q", banner) .. "]"
	if bannerState == nil then return false, bannerSource .. " (sparse default)", true end
	if typeof(bannerState) ~= "table" then return nil, bannerSource .. " (malformed)", false end
	local rawValue = rawget(bannerState, rarity)
	local raritySource = bannerSource .. "[" .. string.format("%q", rarity) .. "]"
	if rawValue == nil then return false, raritySource .. " (sparse default)", true end
	return normalizeBoolean(rawValue), raritySource, true
end

-- A toggle remote must never be fired twice merely because an executor exposes
-- a stale cache: the second call could undo the first. Continue observing fresh
-- getgc snapshots in the background and upgrade the report if evidence arrives.
local function observeAutoSellLate(banner, rarity, desired, actionRecord, unresolvedKey)
	task.spawn(function()
		local deadline = os.clock() + math.max(15, verifyTimeout * 3)
		repeat
			local after, afterSource = currentAutoSell(banner, rarity, true)
			if after == desired then
				actionRecord.after = after
				actionRecord.source = afterSource
				actionRecord.verified = true
				actionRecord.verifiedLate = true
				for index = #report.unresolved, 1, -1 do
					if report.unresolved[index].key == unresolvedKey then
						table.remove(report.unresolved, index)
					end
				end
				log("VERIFY_LATE", "Auto Sell " .. banner .. "." .. rarity
					.. " was confirmed by a refreshed PlayerData snapshot.", { source = afterSource })
				saveReport("Late AutoSell verification")
				return
			end
			task.wait(pollInterval)
		until os.clock() >= deadline or controller.stopRequested
	end)
end

local function syncAutoSell()
	local configured = Settings.autoSell
	if typeof(configured) ~= "table" then return end

	local lobbyRemotes = ReplicatedStorage:FindFirstChild("LobbyRemotes")
	local summonRemote = lobbyRemotes and lobbyRemotes:FindFirstChild("SummonRemote")
	if not summonRemote or not summonRemote:IsA("RemoteEvent") then
		table.insert(report.unresolved, { key = "AutoSell", reason = "LobbyRemotes.SummonRemote was not found" })
		log("SKIP", "SummonRemote is unavailable; Auto Sell synchronization was skipped.")
		return
	end

	local banners = {}
	for banner in pairs(configured) do table.insert(banners, banner) end
	table.sort(banners)
	for _, banner in ipairs(banners) do
		local rarityConfig = configured[banner]
		if typeof(rarityConfig) ~= "table" then fail("CONFIG", "AutoSell banner " .. banner .. " must be a table.") end
		local rarities = {}
		for rarity in pairs(rarityConfig) do table.insert(rarities, rarity) end
		table.sort(rarities)
		for _, rarity in ipairs(rarities) do
			local desired = rarityConfig[rarity]
			if typeof(desired) ~= "boolean" then
				fail("CONFIG", "AutoSell " .. banner .. "." .. rarity .. " must be true or false.")
			end
			local before, source, branchFound = currentAutoSell(banner, rarity)
			if not branchFound or before == nil then
				table.insert(report.unresolved, {
					key = "AutoSell." .. banner .. "." .. rarity,
					reason = "Authoritative PlayerData.AutoSell branch was not found",
					source = source,
				})
				log("SKIP", "Auto Sell " .. banner .. "." .. rarity .. " has no authoritative state; remote not fired.")
			elseif before == desired then
				table.insert(report.actions, {
					key = "AutoSell." .. banner .. "." .. rarity,
					type = "toggle",
					before = before,
					desired = desired,
					action = "none",
					verified = true,
				})
				log("MATCH", "Auto Sell " .. banner .. "." .. rarity .. " already matches Config.", nil, false)
			else
				log("ACTION", "Toggling Auto Sell " .. banner .. "." .. rarity .. " to " .. tostring(desired) .. ".")
				summonRemote:FireServer("ToggleAutoSell", banner, rarity)
				local deadline = os.clock() + verifyTimeout
				local verified, after, afterSource = false, nil, source
				repeat
					after, afterSource = currentAutoSell(banner, rarity, true)
					verified = after == desired
					if not verified then task.wait(pollInterval) end
				until verified or os.clock() >= deadline
				local actionRecord = {
					key = "AutoSell." .. banner .. "." .. rarity,
					type = "toggle",
					before = before,
					desired = desired,
					action = "ToggleAutoSell",
					after = after,
					source = afterSource,
					verified = verified,
				}
				table.insert(report.actions, actionRecord)
				if not verified then
					local unresolvedKey = "AutoSell." .. banner .. "." .. rarity
					table.insert(report.unresolved, {
						key = unresolvedKey,
						reason = "Toggle was sent once but refreshed PlayerData did not confirm it",
						source = afterSource,
					})
					table.insert(report.warnings,
						"AutoSell verification is degraded for " .. banner .. "." .. rarity)
					log("DEGRADED", "AutoSell verification is degraded; background retry will continue.", {
						banner = banner,
						rarity = rarity,
						desired = desired,
					})
					observeAutoSellLate(banner, rarity, desired, actionRecord, unresolvedKey)
				else
				-- Make the authoritative post-remote transition visible in both console
				-- and the persisted log so FastMode dependency failures are easy to audit.
					log("VERIFY", "Auto Sell " .. banner .. "." .. rarity .. " confirmed as " .. tostring(desired) .. ".", {
						source = afterSource,
					})
				end
			end
		end
	end
end

local function currentSetting(key)
	local candidate = resolveAuthoritativeSettings()
	if not candidate then return nil, nil, nil end
	local rawValue = rawget(candidate.table, key)
	return rawValue, candidate.path, candidate
end

local function waitForSetting(key, desired, booleanMode)
	local deadline = os.clock() + verifyTimeout
	repeat
		local current, path = currentSetting(key)
		local comparable = booleanMode and normalizeBoolean(current) or current
		if comparable == desired then return true, current, path end
		task.wait(pollInterval)
	until os.clock() >= deadline
	return false, nil, nil
end

local function inspectSpeedInstances()
	local evidence = {}
	local constants = ReplicatedStorage:FindFirstChild("Constants")
	-- This exact non-UI path was already verified in the current game build.
	-- Reading it directly removes two full GetDescendants traversals per check.
	for _, container in ipairs({ constants, ReplicatedStorage, Workspace }) do
		if container then
			for _, name in ipairs({ "GameSpeed", "GameSpeedLevel", "SpeedLevel" }) do
				local instance = container:FindFirstChild(name)
				if instance and instance:IsA("ValueBase") then
					table.insert(evidence, {
						kind = "ValueBase",
						path = instance:GetFullName(),
						value = simpleValue(instance.Value),
					})
				end
				local attribute = container:GetAttribute(name)
				if attribute ~= nil then
					table.insert(evidence, {
						kind = "Attribute",
						path = container:GetFullName() .. ":GetAttribute(" .. string.format("%q", name) .. ")",
						value = simpleValue(attribute),
					})
				end
			end
		end
	end
	return evidence
end

local function speedMatches(value, desired)
	if value == desired then return true end
	local configured = Settings.gameSpeedRuntimeMultipliers
	local expected = typeof(configured) == "table" and tonumber(configured[desired]) or nil
	return expected ~= nil and tonumber(value) ~= nil and math.abs(tonumber(value) - expected) < 0.0001
end

local function hasDesiredSpeed(evidence, desired)
	for _, item in ipairs(evidence) do
		if speedMatches(item.value, desired) then return true end
	end
	return false
end

-- Auto-Execute may start before both ReplicatedStorage remotes and PlayerData are
-- created. Refresh getgc during a bounded readiness gate; a cached initial list
-- cannot observe tables that are created later in the join lifecycle.
local function waitForRuntimeDependencies()
	local timeout = tonumber(Settings.runtimeLoadTimeout) or 60
	local interval = tonumber(Settings.runtimeDiscoveryInterval) or 0.5
	local deadline = os.clock() + timeout
	local lobbyPlaces = Config.runtimePlaces and Config.runtimePlaces.lobby
	local isLobby = typeof(lobbyPlaces) == "table" and lobbyPlaces[game.PlaceId] == true
	local lastMissing = {}
	log("WAIT", "Waiting for settings remotes and authoritative PlayerData.", {
		timeout = timeout,
		placeId = game.PlaceId,
	})
	repeat
		local remotes = ReplicatedStorage:FindFirstChild("Remotes")
		local settingRemote = remotes and remotes:FindFirstChild("SettingsRemote")
		local generalRemote = remotes and remotes:FindFirstChild("RemoteEvent")
		-- Do not run the expensive fallback/upvalue settings scan while PlayerData
		-- itself is absent. First refresh only the structural PlayerData lookup;
		-- once found, the authoritative descendant scan is narrow and deterministic.
		local livePlayerData = resolvePlayerData(true)
		local authoritative = livePlayerData and resolveAuthoritativeSettings(false) or nil
		local lobbyRemotes = ReplicatedStorage:FindFirstChild("LobbyRemotes")
		local summonRemote = lobbyRemotes and lobbyRemotes:FindFirstChild("SummonRemote")
		local autoSellReady = not isLobby or typeof(Settings.autoSell) ~= "table"
			or (summonRemote and summonRemote:IsA("RemoteEvent"))
		lastMissing = {
			settingsRemote = not (settingRemote and settingRemote:IsA("RemoteEvent")),
			generalRemote = not (generalRemote and generalRemote:IsA("RemoteEvent")),
			playerDataSettings = authoritative == nil,
			summonRemote = not autoSellReady,
		}
		if not lastMissing.settingsRemote and not lastMissing.generalRemote
			and not lastMissing.playerDataSettings and not lastMissing.summonRemote then
			return settingRemote, generalRemote, authoritative, isLobby
		end
		task.wait(interval)
	until os.clock() >= deadline
	return nil, nil, nil, isLobby, lastMissing
end

local function run()
	local settingRemote, generalRemote, authoritative, isLobby, missing = waitForRuntimeDependencies()
	if not settingRemote or not generalRemote or not authoritative then
		report.status = "DISCOVERY_REQUIRED"
		report.unresolvedRuntime = missing
		log("DISCOVERY", "Runtime dependencies did not become authoritative before timeout.", missing)
		saveReport("Runtime dependencies timed out")
		return report
	end
	-- Auto Sell has its own authoritative branch and may synchronize even if the
	-- generic SetSetting table changes shape in a future game update. It exists in
	-- the lobby only, so stage Auto-Execute deliberately skips this branch.
	if isLobby then syncAutoSell() end
	report.stateSource = authoritative and authoritative.path or nil
	report.before = authoritative and authoritative.values or nil

	if not authoritative then
		report.status = "DISCOVERY_REQUIRED"
		log("DISCOVERY", "No authoritative PlayerData settings table was found; no toggle remotes were sent.")
		saveReport("Runtime settings table not found")
		return report
	end
	log("RUNTIME", "Resolved authoritative settings table.", {
		source = authoritative.path,
		matches = authoritative.matches,
		values = authoritative.values,
	})

	local toggleKeys = {}
	for key in pairs(Settings.toggles or {}) do table.insert(toggleKeys, key) end
	table.sort(toggleKeys)
	for _, key in ipairs(toggleKeys) do
		local desired = Settings.toggles[key]
		if typeof(desired) ~= "boolean" then fail("CONFIG", "Toggle " .. key .. " must be true or false.") end
		local current, source = currentSetting(key)
		local normalized = normalizeBoolean(current)
		if normalized == nil then
			table.insert(report.unresolved, { key = key, reason = "Current boolean value not found", source = source })
			log("SKIP", key .. " was not found in authoritative runtime state; toggle was not fired.")
		elseif normalized == desired then
			table.insert(report.actions, { key = key, type = "toggle", before = current, desired = desired, action = "none", verified = true })
			log("MATCH", key .. " already matches Config.", nil, false)
		else
			log("ACTION", "Toggling " .. key .. " from " .. tostring(normalized) .. " to " .. tostring(desired) .. ".")
			settingRemote:FireServer("SetSetting", key)
			local verified, after, afterSource = waitForSetting(key, desired, true)
			table.insert(report.actions, {
				key = key,
				type = "toggle",
				before = current,
				desired = desired,
				action = "SetSetting",
				after = after,
				source = afterSource,
				verified = verified,
			})
			if not verified then
				-- Toggles are applied in alphabetical order, so killing the controller
				-- on the first slow replication silently skipped every later key and
				-- the whole GameSpeed block. Degrade the way the GameSpeed path already
				-- does: record it as unresolved, report PARTIAL, and keep applying.
				table.insert(report.unresolved, {
					key = key,
					reason = string.format(
						"SetSetting was fired but %s did not become %s within %ss",
						key, tostring(desired), tostring(verifyTimeout)),
					source = afterSource,
				})
				log("UNRESOLVED", key .. " did not become " .. tostring(desired)
					.. "; continuing with the remaining settings.",
					{ after = after, source = afterSource })
			end
		end
	end

	local valueKeys = {}
	for key in pairs(Settings.values or {}) do table.insert(valueKeys, key) end
	table.sort(valueKeys)
	for _, key in ipairs(valueKeys) do
		local desired = Settings.values[key]
		local current, source = currentSetting(key)
		if current == desired then
			table.insert(report.actions, { key = key, type = "value", before = current, desired = desired, action = "none", verified = true })
			log("MATCH", key .. " already equals " .. tostring(desired) .. ".", nil, false)
		else
			log("ACTION", "Setting " .. key .. " to " .. tostring(desired) .. ".", { before = current, source = source })
			settingRemote:FireServer("SetSetting", key, desired)
			local verified, after, afterSource = waitForSetting(key, desired, false)
			table.insert(report.actions, {
				key = key,
				type = "value",
				before = current,
				desired = desired,
				action = "SetSetting",
				after = after,
				source = afterSource,
				verified = verified,
			})
			if not verified then
				-- Same degrade path as the toggle loop above: one unconfirmed value
				-- must not cost the run every remaining setting.
				table.insert(report.unresolved, {
					key = key,
					reason = string.format(
						"SetSetting was fired but %s did not become %s within %ss",
						key, tostring(desired), tostring(verifyTimeout)),
					source = afterSource,
				})
				log("UNRESOLVED", key .. " did not become " .. tostring(desired)
					.. "; continuing with the remaining settings.",
					{ after = after, source = afterSource })
			end
		end
	end

	-- GameSpeed is a stage-only concern. Firing and monitoring it in the lobby
	-- produced an endless reset/retry loop because the lobby legitimately stays at 1x.
	local desiredSpeed = tostring(Settings.gameSpeed or "Two")
	if not isLobby then
		local speedMapping = Settings.gameSpeedRuntimeMultipliers
		report.expectedSpeedMultiplier = typeof(speedMapping) == "table" and tonumber(speedMapping[desiredSpeed]) or nil
		report.speedBefore = inspectSpeedInstances()
		log("ACTION", "Setting game speed to " .. desiredSpeed .. ".")
		generalRemote:FireServer("ChangeSpeed", desiredSpeed)
		local speedVerified, speedAfter = false, {}
		local deadline = os.clock() + verifyTimeout
		repeat
			speedAfter = inspectSpeedInstances()
			speedVerified = hasDesiredSpeed(speedAfter, desiredSpeed)
			if not speedVerified then task.wait(pollInterval) end
		until speedVerified or os.clock() >= deadline
		report.speedAfter = speedAfter
		report.speedVerified = speedVerified
		table.insert(report.actions, {
			key = "GameSpeed",
			type = "explicit-remote",
			desired = desiredSpeed,
			action = "ChangeSpeed",
			verified = speedVerified,
		})
		if not speedVerified then
			table.insert(report.unresolved, { key = "GameSpeed", reason = "No replicated non-UI speed evidence was found" })
			log("VERIFY", "ChangeSpeed was explicit but no non-UI replicated speed evidence was found.")
		end
	else
		log("SKIP", "Lobby context: GameSpeed action and monitor are disabled.", nil, false)
	end

	local after = resolveAuthoritativeSettings()
	report.after = after and after.values or nil
	report.status = #report.unresolved == 0 and "COMPLETE" or "PARTIAL"
	log("COMPLETE", "In-game settings synchronization finished.", {
		status = report.status,
		unresolved = report.unresolved,
	})
	saveReport("Settings synchronization finished")
	-- Later GameSpeed checks read direct replicated Instances. Release the broad
	-- discovery snapshot before entering the long-running monitor.
	gcObjects = nil

	if Settings.monitorGameSpeed == true and not isLobby then
		report.monitoringGameSpeed = true
		report.status = "MONITORING"
		report.speedReapplyCount = 0
		log("MONITOR", "Watching replicated GameSpeed for per-match resets.")
		saveReport("Monitoring GameSpeed")
		local interval = tonumber(Settings.gameSpeedMonitorInterval) or 0.5
		while not controller.stopRequested do
			local evidence = inspectSpeedInstances()
			if not hasDesiredSpeed(evidence, desiredSpeed) then
				local beforeReset = evidence
				log("ACTION", "GameSpeed reset detected; re-applying level " .. desiredSpeed .. ".", beforeReset)
				generalRemote:FireServer("ChangeSpeed", desiredSpeed)
				local verified, afterReset = false, {}
				local resetDeadline = os.clock() + verifyTimeout
				repeat
					afterReset = inspectSpeedInstances()
					verified = hasDesiredSpeed(afterReset, desiredSpeed)
					if not verified then task.wait(pollInterval) end
				until verified or os.clock() >= resetDeadline or controller.stopRequested
				report.speedReapplyCount += 1
				report.speedAfter = afterReset
				table.insert(report.actions, {
					key = "GameSpeed",
					type = "monitor-reapply",
					desired = desiredSpeed,
					verified = verified,
				})
				-- Monitor reports are diagnostic only; cap them so a long farm session
				-- cannot grow the JSON payload without bound.
				if #report.actions > 200 then table.remove(report.actions, 1) end
				if not verified then
					log("VERIFY", "GameSpeed reset re-apply was not confirmed; monitor will retry.")
				else
					log("VERIFY", "GameSpeed level " .. desiredSpeed .. " restored from runtime evidence.")
				end
				saveReport("GameSpeed monitor re-apply")
			end
			task.wait(interval)
		end
		report.monitoringGameSpeed = false
		report.status = "STOPPED"
		log("STOP", "GameSpeed monitor stopped.")
		saveReport("Stopped by user")
	end
	return report
end

local ok, result = xpcall(run, function(message)
	return debug and debug.traceback and debug.traceback(tostring(message), 2) or tostring(message)
end)
if environment.AnimeOriginInGameSettingsRunning == runToken then
	environment.AnimeOriginInGameSettingsRunning = nil
end
if not ok then
	if report.status ~= "FAILED" then
		report.status = "FAILED"
		report.error = result
		saveReport("Unhandled error")
	end
	error(result, 0)
end

environment.AnimeOriginInGameSettingsReport = result
return result
