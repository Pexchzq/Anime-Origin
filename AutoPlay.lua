--[[
	Anime Origin AutoPlay - verified team, placement and upgrade controller

	This file intentionally contains only AutoPlay/team logic. InGameSettings.lua
	owns user settings and game speed.

	Implemented phases:
	  1. Read PlayerData, owned UUIDs, unit definitions and StageStats from runtime.
	  2. Rank unique damage units by the game's live max-upgrade stats and
	     DPS = Damage / Cooldown, including owned-copy level and modifiers.
	  3. Build Damage x3, then either Leorio or the next Damage from Config.
	  4. Equip sequentially and verify PlayerData.EquippedTowers after every remote.
	  5. Ready the match and verify MatchRuntime.GameStarted.
	  6. Place three damage towers, optionally place three Leorio towers, then fill
	     every equipped damage unit to its definition Limit.
	  7. When enabled, upgrade the farmer first and reserve its next cost. With the
	     farmer disabled, place and upgrade damage without a farmer reserve.

	Slots after the first three are discovered through server acceptance. If the
	next TowerN value never appears, that slot is locked/rejected and later slots
	are not attempted. No UI path or account-level guess is used.

	Remote returns are diagnostic only. Success requires CreateNewTower/UpdateTower
	evidence or the corresponding MatchRuntime.TowerDict mutation.
]]

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local HttpService = game:GetService("HttpService")

local environment = getgenv()

-- MacSploit may inject AutoPlay before Config.lua on a new place lifecycle.
-- Bounded waits remove that ordering dependency while still surfacing a clear
-- error if Auto-Execute was configured without the central config file.
local function waitForAnimeOriginConfig(timeout)
	local deadline = os.clock() + (tonumber(timeout) or 30)
	repeat
		local config = environment.AnimeOriginConfig
		if typeof(config) == "table" then return config end
		task.wait(0.05)
	until os.clock() >= deadline
	error("[AutoPlay][AUTO_EXECUTE] Timed out waiting for Config.lua.", 0)
end

local function waitForLocalPlayer(timeout)
	local deadline = os.clock() + (tonumber(timeout) or 30)
	repeat
		if Players.LocalPlayer then return Players.LocalPlayer end
		task.wait(0.05)
	until os.clock() >= deadline
	error("[AutoPlay][AUTO_EXECUTE] Timed out waiting for LocalPlayer.", 0)
end

local player = waitForLocalPlayer()
local Config = waitForAnimeOriginConfig()

local Settings = Config.autoPlay
assert(typeof(Settings) == "table", "Config.autoPlay is missing.")
assert(Settings.enabled == true, "Config.autoPlay.enabled is false.")
local consoleStatusOnly = typeof(Config.console) == "table"
	and Config.console.statusOnly == true
-- A JobId-scoped token blocks accidental duplicate injection in one server but
-- does not let a stale pre-teleport flag disable AutoPlay in the next stage.
local previousRun = environment.AnimeOriginAutoPlayRunning
assert(not (typeof(previousRun) == "table" and previousRun.jobId == game.JobId),
	"AutoPlay is already running in this server.")
local runToken = { jobId = game.JobId, userId = player.UserId, startedAt = os.time() }
environment.AnimeOriginAutoPlayRunning = runToken

local stateFolder = tostring(Settings.stateFolder or "AnimeOrigin")
local reportFile = stateFolder .. "/AutoPlay_" .. tostring(player.UserId) .. "_latest.json"
local logFile = stateFolder .. "/AutoPlay_" .. tostring(player.UserId) .. "_latest.log"
local pollInterval = tonumber(Settings.statePollInterval) or 0.2
local verifyTimeout = tonumber(Settings.verifyTimeout) or 6
local report = {
	-- Version 12 additionally isolates the game's append-only TowerDict by match
	-- epoch, so Replay/Next can never reuse or upgrade an old placed UUID.
	version = 12,
	userId = player.UserId,
	placeId = game.PlaceId,
	jobId = game.JobId,
	phase = "FULL_AUTO_PLAY",
	actions = {},
	rankedDamage = {},
	farmCandidates = {},
	excludedPlacementUnits = {},
	desiredTeam = {},
	teamPolicy = {},
	finalLoadout = {},
	configurations = {},
	lifecycle = {
		monitoring = false,
		completedReconfigurations = 0,
		events = {},
	},
	gameplay = {
		matchRuntimeSource = nil,
		moneySource = nil,
		towerEvents = {},
		actions = {},
		matchEpoch = 0,
	},
}
local controller = {
	stopRequested = false,
	report = report,
}
function controller.stop()
	controller.stopRequested = true
end
environment.AnimeOriginAutoPlay = controller

local logBuffer = {}
local sequence = 0
local maximumRetainedLogLines = math.max(50, tonumber(Settings.maximumRetainedLogLines) or 300)
local maximumRetainedTeamActions = math.max(50, tonumber(Settings.maximumRetainedTeamActions) or 300)
-- Record monotonic elapsed time in every diagnostic line. This makes placement
-- latency measurable even when several executor console messages share a timestamp.
local sessionStartedClock = os.clock()

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
	local line = string.format(
		"[AutoPlay][%03d][%s][+%.3fs] %s%s",
		sequence,
		stage,
		os.clock() - sessionStartedClock,
		message,
		suffix
	)
	table.insert(logBuffer, line)
	-- appendfile already persists the complete history. Keep only a fixed-size
	-- fallback ring in Lua so a multi-hour farming session cannot retain every
	-- formatted diagnostic string forever.
	if #logBuffer > maximumRetainedLogLines then table.remove(logBuffer, 1) end
	if console ~= false and not consoleStatusOnly then print("[AutoPlay] " .. message) end
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
	error(string.format("[AutoPlay][%s] %s", stage, message), 0)
end

ensureFolder()
if typeof(writefile) == "function" then writefile(logFile, "") end

local gcObjects
local function releaseGCObjects()
	-- getgc(true) can return millions of references. Nil alone leaves that large
	-- array alive until the next collector pass; clearing it releases references
	-- immediately and prevents retry loops from stacking several snapshots.
	if typeof(gcObjects) == "table" then table.clear(gcObjects) end
	gcObjects = nil
end

local function getGCObjects(refresh)
	if gcObjects and refresh ~= true then return gcObjects end
	if refresh == true then releaseGCObjects() end
	assert(typeof(getgc) == "function", "getgc is unavailable.")
	local ok, objects = pcall(getgc, true)
	assert(ok and typeof(objects) == "table", "getgc(true) failed.")
	gcObjects = objects
	return objects
end

local function isPlayerData(value)
	if typeof(value) ~= "table" then return false end
	local inventory = rawget(value, "Inventory")
	return typeof(inventory) == "table"
		and typeof(rawget(inventory, "Towers")) == "table"
		and typeof(rawget(value, "EquippedTowers")) == "table"
end

-- Cache the stable wrapper, not its current PlayerData value. Server pushes can
-- replace wrapper.PlayerData outright; dereferencing the wrapper on every read
-- follows that replacement without rescanning millions of getgc entries. Direct
-- PlayerData tables are only a fallback because old snapshots remain in getgc.
local playerDataContainer
local playerDataContainerSource

local function readPlayerDataContainer()
	if typeof(playerDataContainer) ~= "table" then return nil, nil end
	local nested = rawget(playerDataContainer, "PlayerData")
	if isPlayerData(nested) then
		return nested, playerDataContainerSource .. ".PlayerData"
	end
	if isPlayerData(playerDataContainer) then return playerDataContainer, playerDataContainerSource end
	return nil, nil
end

local function resolvePlayerData(forceRefresh)
	local cached, cachedSource = readPlayerDataContainer()
	if cached and forceRefresh ~= true then return cached, cachedSource end

	local directCandidate, directSource
	local objects = getGCObjects(forceRefresh == true)
	for index, object in ipairs(objects) do
		if typeof(object) == "table" then
			local nestedCandidate = rawget(object, "PlayerData")
			if isPlayerData(nestedCandidate) then
				playerDataContainer = object
				playerDataContainerSource = "getgc[" .. index .. "]"
				return nestedCandidate, playerDataContainerSource .. ".PlayerData"
			end
			if not directCandidate and isPlayerData(object) then
				directCandidate = object
				directSource = "getgc[" .. index .. "]"
			end
		end
	end
	if directCandidate then
		playerDataContainer = directCandidate
		playerDataContainerSource = directSource
		return directCandidate, directSource
	end
	return nil, nil
end

local function readRuntime()
	local playerData, source = resolvePlayerData()
	if not playerData then fail("RUNTIME", "Live PlayerData was not found. Wait for stage loading.") end
	local inventory = rawget(playerData, "Inventory")
	local towers = inventory and rawget(inventory, "Towers")
	local equipped = rawget(playerData, "EquippedTowers")
	if typeof(towers) ~= "table" or typeof(equipped) ~= "table" then
		fail("RUNTIME", "Inventory.Towers or EquippedTowers is unavailable.")
	end
	return playerData, towers, equipped, source
end

local function isFarmDefinition(definition)
	if rawget(definition, "MoneyUnit") == true then return true end
	local elements = rawget(definition, "Elements")
	if typeof(elements) == "table" then
		for _, element in next, elements do
			if string.lower(tostring(element)) == "farm" then return true end
		end
	end
	return false
end

local function hasStageStats(definition)
	return typeof(definition) == "table" and typeof(rawget(definition, "StageStats")) == "table"
end

local function resolveDefinitions(towers)
	local needed = {}
	for _, record in next, towers do
		if typeof(record) == "table" and typeof(rawget(record, "Name")) == "string" then
			needed[rawget(record, "Name")] = true
		end
	end

	local definitions, sources = {}, {}
	local remaining = 0
	for _ in pairs(needed) do remaining += 1 end

	for index, object in ipairs(getGCObjects()) do
		if remaining == 0 then break end
		if typeof(object) == "table" then
			for identifier in pairs(needed) do
				if not definitions[identifier] then
					local definition = rawget(object, identifier)
					if hasStageStats(definition) then
						definitions[identifier] = definition
						sources[identifier] = "getgc[" .. index .. "][" .. string.format("%q", identifier) .. "]"
						remaining -= 1
					end
				end
			end
		end
	end

	-- Definition maps can be function upvalues in some client builds. Inspect the
	-- upvalue tables read-only, but never invoke those callbacks.
	if remaining > 0 and debug and typeof(debug.getupvalues) == "function" then
		for index, object in ipairs(getGCObjects()) do
			if remaining == 0 then break end
			if typeof(object) == "function" then
				local ok, upvalues = pcall(debug.getupvalues, object)
				if ok and typeof(upvalues) == "table" then
					for upvalueIndex, upvalue in pairs(upvalues) do
						if typeof(upvalue) == "table" then
							for identifier in pairs(needed) do
								if not definitions[identifier] then
									local definition = rawget(upvalue, identifier)
									if hasStageStats(definition) then
										definitions[identifier] = definition
										sources[identifier] = "getgc[" .. index .. "].upvalue[" .. tostring(upvalueIndex) .. "][" .. string.format("%q", identifier) .. "]"
										remaining -= 1
									end
								end
							end
						end
					end
				end
			end
		end
	end

	local unresolved = {}
	for identifier in pairs(needed) do
		if not definitions[identifier] then table.insert(unresolved, identifier) end
	end
	table.sort(unresolved)
	return definitions, sources, unresolved
end

local function highestStage(definition, farm)
	local stageStats = rawget(definition, "StageStats")
	local selected, selectedRank
	for key, stage in next, stageStats do
		if typeof(stage) == "table" then
			local rank = tonumber(key)
			local valid
			if farm then
				valid = tonumber(rawget(stage, "GiveMoney")) ~= nil
			else
				valid = tonumber(rawget(stage, "Damage")) ~= nil
					and tonumber(rawget(stage, "Cooldown")) ~= nil
					and tonumber(rawget(stage, "Range")) ~= nil
			end
			if valid and (not selected or (rank and (not selectedRank or rank > selectedRank))) then
				selected, selectedRank = stage, rank
			end
		end
	end
	return selected, selectedRank
end

-- Use the game's own stat calculator instead of reimplementing only part of the
-- formula. These functions include unit level, Trait, Shiny, Stars, Grades and
-- server-owned account multipliers, matching the values shown by the inventory.
local function resolveStatCalculator()
	for index, object in ipairs(getGCObjects()) do
		if typeof(object) == "table"
			and typeof(rawget(object, "Damage")) == "function"
			and typeof(rawget(object, "Cooldown")) == "function"
			and typeof(rawget(object, "Range")) == "function"
			and typeof(rawget(object, "GetTowerLevelFromExp")) == "function" then
			return object, "getgc[" .. index .. "]"
		end
	end
	return nil, nil
end

local function calculatedNumber(calculator, functionName, record, stageRank)
	local callback = rawget(calculator, functionName)
	local ok, value = pcall(callback, record, stageRank)
	return ok and tonumber(value) or nil
end

local function buildRankings(towers, definitions, sources)
	local damage, farms, excludedPlacement = {}, {}, {}
	local calculator, calculatorSource = resolveStatCalculator()
	if not calculator then
		fail("CALCULATE", "The live CalculateStuff Damage/Cooldown/Range module was not found.")
	end
	report.statCalculatorSource = calculatorSource
	local excludedTypes = typeof(Settings.excludedPlacementTypes) == "table"
		and Settings.excludedPlacementTypes or {}
	for uuid, record in next, towers do
		if typeof(uuid) == "string" and typeof(record) == "table" then
			local identifier = rawget(record, "Name")
			local definition = definitions[identifier]
			if definition then
				local farm = isFarmDefinition(definition)
				local stage, stageRank = highestStage(definition, farm)
				local stageStats = rawget(definition, "StageStats")
				local placementStage = rawget(stageStats, 1) or rawget(stageStats, "1")
				local grades = rawget(record, "Grades")
				local damageMultiplier = typeof(grades) == "table" and tonumber(rawget(grades, "DamageMultiplier")) or 1
				local cooldownMultiplier = typeof(grades) == "table" and tonumber(rawget(grades, "CooldownMultiplier")) or 1
				local rangeMultiplier = typeof(grades) == "table" and tonumber(rawget(grades, "RangeMultiplier")) or 1
				local placementType = tostring(rawget(definition, "PlacementType") or "Ground")
				if rawget(excludedTypes, placementType) == true then
					-- A blocked placement type must never enter desiredTeam; the next
					-- eligible unit in the DPS ranking is promoted automatically.
					table.insert(excludedPlacement, {
						uuid = uuid,
						identifier = identifier,
						displayName = rawget(definition, "DisplayName") or identifier,
						placementType = placementType,
					})
				elseif farm and stage then
					table.insert(farms, {
						uuid = uuid,
						identifier = identifier,
						displayName = rawget(definition, "DisplayName") or identifier,
						giveMoney = tonumber(rawget(stage, "GiveMoney")),
						range = (tonumber(rawget(stage, "Range")) or 0) * rangeMultiplier,
						cost = placementStage and tonumber(rawget(placementStage, "Cost")) or nil,
						stageRank = stageRank,
						stageStats = stageStats,
						limit = tonumber(rawget(definition, "Limit")) or 1,
						placementType = placementType,
						definitionSource = sources[identifier],
					})
				elseif stage and damageMultiplier and cooldownMultiplier and cooldownMultiplier > 0 and rangeMultiplier then
					local finalDamage = calculatedNumber(calculator, "Damage", record, stageRank)
					local finalCooldown = calculatedNumber(calculator, "Cooldown", record, stageRank)
					local finalRange = calculatedNumber(calculator, "Range", record, stageRank)
					if not finalDamage or not finalCooldown or finalCooldown <= 0 or not finalRange then
						fail("CALCULATE", "CalculateStuff could not evaluate max-stage stats for "
							.. tostring(identifier) .. " UUID " .. tostring(uuid) .. ".")
					end
					local getLevel = rawget(calculator, "GetTowerLevelFromExp")
					local levelOK, level = pcall(getLevel, tonumber(rawget(record, "Exp")) or 0, rawget(definition, "Rarity"))
					table.insert(damage, {
						uuid = uuid,
						identifier = identifier,
						displayName = rawget(definition, "DisplayName") or identifier,
						rarity = rawget(definition, "Rarity"),
						damage = finalDamage,
						cooldown = finalCooldown,
						range = finalRange,
						dps = finalDamage / finalCooldown,
						cost = placementStage and tonumber(rawget(placementStage, "Cost")) or nil,
						stageRank = stageRank,
						stageStats = stageStats,
						limit = tonumber(rawget(definition, "Limit")) or 1,
						placementType = placementType,
						trait = rawget(record, "Trait"),
						traitApplied = rawget(record, "Trait") ~= nil,
						exp = tonumber(rawget(record, "Exp")) or 0,
						level = levelOK and tonumber(level) or nil,
						statCalculatorSource = calculatorSource,
						definitionSource = sources[identifier],
					})
				end
			end
		end
	end

	table.sort(damage, function(left, right)
		if left.dps ~= right.dps then return left.dps > right.dps end
		if left.range ~= right.range then return left.range > right.range end
		return left.uuid < right.uuid
	end)
	table.sort(farms, function(left, right)
		if left.giveMoney ~= right.giveMoney then return left.giveMoney > right.giveMoney end
		if left.range ~= right.range then return left.range > right.range end
		return left.uuid < right.uuid
	end)

	-- Keep only the strongest owned copy of each internal unit. This prevents the
	-- server from rejecting a duplicate identifier after the first copy is equipped.
	local uniqueDamage, seenIdentifiers = {}, {}
	for _, unit in ipairs(damage) do
		if not seenIdentifiers[unit.identifier] then
			seenIdentifiers[unit.identifier] = true
			table.insert(uniqueDamage, unit)
		end
	end
	return uniqueDamage, farms, excludedPlacement
end

local function readLoadout()
	local _, _, equipped = readRuntime()
	local slots = {}
	for slot = 1, tonumber(Settings.maximumTeamSlots) or 6 do
		slots[slot] = rawget(equipped, "Tower" .. slot)
	end
	return slots
end

local function occupiedCount(slots)
	local count = 0
	for slot = 1, tonumber(Settings.maximumTeamSlots) or 6 do
		if typeof(slots[slot]) == "string" then count += 1 end
	end
	return count
end

local function waitFor(predicate, timeout)
	local deadline = os.clock() + timeout
	repeat
		local ok, result = pcall(predicate)
		if ok and result then return true, result end
		task.wait(pollInterval)
	until os.clock() >= deadline
	return false, nil
end

local function buildDesiredTeam(damage, farms)
	local desired, selectedDamage = {}, {}
	local minimumDamage = tonumber(Settings.minimumDamageSlots) or 3
	local maximumSlots = tonumber(Settings.maximumTeamSlots) or 6
	local maximumLowCost = tonumber(Settings.maximumLowCostDamagePlacementCost)
	local minimumLowCost = math.max(0, math.floor(tonumber(Settings.minimumLowCostDamageSlots) or 0))
	minimumLowCost = math.min(minimumLowCost, minimumDamage)

	local function isLowCostDamage(unit)
		return unit and maximumLowCost ~= nil
			and tonumber(unit.cost) ~= nil
			and tonumber(unit.cost) <= maximumLowCost
	end

	local function selectDamage(unit)
		table.insert(desired, unit)
		selectedDamage[unit.uuid] = true
	end

	-- Begin with the normal max-stage DPS order. The low-cost rule modifies only
	-- the weakest required selection when the first three do not satisfy it.
	for index = 1, minimumDamage do
		local unit = damage[index]
		if not unit then fail("TEAM", "Not enough unique damage units for the first three slots.") end
		selectDamage(unit)
	end

	local selectedLowCost = 0
	for _, unit in ipairs(desired) do
		if isLowCostDamage(unit) then selectedLowCost += 1 end
	end
	if selectedLowCost < minimumLowCost then
		for _, candidate in ipairs(damage) do
			if selectedLowCost >= minimumLowCost then break end
			if isLowCostDamage(candidate) and not selectedDamage[candidate.uuid] then
				-- desired is currently DPS ordered, so scan backward and replace the
				-- weakest non-low-cost unit while preserving every existing guarantee.
				local replaceIndex
				for index = #desired, 1, -1 do
					if not isLowCostDamage(desired[index]) then
						replaceIndex = index
						break
					end
				end
				if replaceIndex then
					selectedDamage[desired[replaceIndex].uuid] = nil
					desired[replaceIndex] = candidate
					selectedDamage[candidate.uuid] = true
					selectedLowCost += 1
				end
			end
		end
	end
	if selectedLowCost < minimumLowCost then
		fail("TEAM", string.format(
			"Need at least %d damage unit(s) with placement cost <= %s, but the inventory cannot satisfy it.",
			minimumLowCost,
			tostring(maximumLowCost)
		))
	end
	-- Persist the resolved guarantee in JSON so a team can be audited without
	-- opening the inventory UI or inferring costs from cards.
	report.teamPolicy = {
		minimumLowCostDamageSlots = minimumLowCost,
		maximumLowCostDamagePlacementCost = maximumLowCost,
		selectedLowCostDamageSlots = selectedLowCost,
	}

	-- Optional slots resume the original DPS order while skipping UUIDs already
	-- selected by either the normal rank or the low-cost replacement above.
	local function nextUnusedDamage()
		for _, candidate in ipairs(damage) do
			if not selectedDamage[candidate.uuid] then
				selectedDamage[candidate.uuid] = true
				return candidate
			end
		end
		return nil
	end

	local useFarmerUnit = Settings.useFarmerUnit ~= false
	local farmer
	if #desired < maximumSlots then
		if useFarmerUnit then
			for _, candidate in ipairs(farms) do
				if candidate.identifier == tostring(Settings.farmerIdentifier or "Leorio") then
					farmer = candidate
					break
				end
			end
		end
		if farmer then
			table.insert(desired, farmer)
		else
			local fallback = nextUnusedDamage()
			if fallback then table.insert(desired, fallback) end
		end
	end
	-- Record both the requested policy and actual selection; if Leorio is missing,
	-- the same next-DPS fallback is used even while the farmer option is enabled.
	report.teamPolicy.useFarmerUnit = useFarmerUnit
	report.teamPolicy.farmerSelected = farmer ~= nil
	log("TEAM", "Damage-cost and farmer-slot policies resolved.", report.teamPolicy)

	while #desired < maximumSlots do
		local unit = nextUnusedDamage()
		if not unit then break end
		table.insert(desired, unit)
	end
	return desired
end

local function serializableUnit(unit, slot)
	return {
		slot = slot,
		uuid = unit.uuid,
		identifier = unit.identifier,
		displayName = unit.displayName,
		role = unit.giveMoney and "farm" or "damage",
		dps = unit.dps,
		damage = unit.damage,
		cooldown = unit.cooldown,
		range = unit.range,
		giveMoney = unit.giveMoney,
		placementCost = unit.cost,
		placementType = unit.placementType,
		limit = unit.limit,
		maxStage = unit.stageRank,
		level = unit.level,
		exp = unit.exp,
	}
end

local function countEntries(value)
	local count = 0
	for _ in next, value do count += 1 end
	return count
end

local function loadoutSignature(slots)
	local values = {}
	for slot = 1, tonumber(Settings.maximumTeamSlots) or 6 do
		values[slot] = tostring(slots[slot] or "-")
	end
	return table.concat(values, "|")
end

local function recordLifecycleEvent(kind, source, values)
	local events = report.lifecycle.events
	table.insert(events, {
		time = os.time(),
		kind = kind,
		source = source,
		values = values,
	})
	-- Keep the latest evidence bounded during long farming sessions.
	if #events > 150 then table.remove(events, 1) end
end

local function simpleRemoteValue(value, depth, visited)
	depth = depth or 0
	visited = visited or {}
	local kind = typeof(value)
	if kind == "string" or kind == "number" or kind == "boolean" or kind == "nil" then return value end
	-- Preserve exact coordinates in JSON/logs. The previous <Vector3> placeholder
	-- made rejected placement points impossible to compare after a live run.
	if kind == "Vector3" then return { x = value.X, y = value.Y, z = value.Z } end
	if kind == "CFrame" then
		local position = value.Position
		return { x = position.X, y = position.Y, z = position.Z }
	end
	if kind ~= "table" then return "<" .. kind .. ">" end
	if visited[value] then return "<circular>" end
	if depth >= 2 then return "<table>" end
	visited[value] = true
	local result, count = {}, 0
	for key, child in next, value do
		count += 1
		if count > 40 then result._truncated = true; break end
		result[tostring(key)] = simpleRemoteValue(child, depth + 1, visited)
	end
	visited[value] = nil
	return result
end

local function disconnectAll(connections)
	for _, connection in ipairs(connections) do
		pcall(function() connection:Disconnect() end)
	end
end

-- MatchRuntime is stable by shape even though its getgc index changes on every
-- join. This is the same four-key signature verified by the no-hook V3 probe.
local function resolveMatchRuntime(preferredStarted, refresh)
	local fallback, fallbackSource
	for index, object in ipairs(getGCObjects(refresh)) do
		if typeof(object) == "table"
			and typeof(rawget(object, "GameStarted")) == "boolean"
			and typeof(rawget(object, "TowerDict")) == "table"
			and typeof(rawget(object, "TowerNPCDict")) == "table"
			and typeof(rawget(object, "PathPositions")) == "table" then
			local source = "getgc[" .. tostring(index) .. "]"
			if preferredStarted == nil or rawget(object, "GameStarted") == preferredStarted then
				return object, source
			end
			fallback, fallbackSource = fallback or object, fallbackSource or source
		end
	end
	return fallback, fallbackSource
end

-- PlaceTower and UpgradeTower both compare against a server-replicated Money
-- attribute. Prefer the runtime's PlayerData Instance, then LocalPlayer; table
-- fallbacks are retained for client builds that copy the scalar into PlayerData.
local function readMatchMoney(matchRuntime)
	local candidates = {
		{ value = matchRuntime and rawget(matchRuntime, "PlayerData"), path = "<MatchRuntime>.PlayerData" },
		{ value = player, path = "Players.LocalPlayer" },
	}

	for _, candidate in ipairs(candidates) do
		local value = candidate.value
		if typeof(value) == "Instance" then
			local amount = tonumber(value:GetAttribute("Money"))
			if amount then return amount, candidate.path .. ":GetAttribute(\"Money\")" end
		elseif typeof(value) == "table" then
			local amount = tonumber(rawget(value, "Money"))
			if amount then return amount, candidate.path .. ".Money" end
		end
	end

	-- Only perform the broader getgc PlayerData resolution when neither verified
	-- Instance exposes Money; the normal path remains a cheap attribute read.
	local playerData = resolvePlayerData()
	if typeof(playerData) == "table" then
		local amount = tonumber(rawget(playerData, "Money"))
		if amount then return amount, "<PlayerData>.Money" end
	end
	return nil, nil
end

local function stageAt(stageStats, stage)
	if typeof(stageStats) ~= "table" then return nil end
	return rawget(stageStats, stage) or rawget(stageStats, tostring(stage))
end

local function towerStageStats(tower, unit)
	if typeof(tower) == "table" then
		local towerInfo = rawget(tower, "TowerInfo")
		local liveStats = typeof(towerInfo) == "table" and rawget(towerInfo, "StageStats") or nil
		if typeof(liveStats) == "table" then return liveStats end
	end
	return unit and unit.stageStats or nil
end

local function nextUpgrade(tower, unit)
	local current = tonumber(rawget(tower, "Stage")) or 1
	local nextStage = stageAt(towerStageStats(tower, unit), current + 1)
	if typeof(nextStage) ~= "table" then return nil, nil, current end
	return tonumber(rawget(nextStage, "Cost")), current + 1, current
end

local function towerUUID(tower, fallback)
	local value = typeof(tower) == "table" and rawget(tower, "UUID") or nil
	return tostring(value or fallback)
end

local function appendGameplayEvent(kind, data)
	local events = report.gameplay.towerEvents
	table.insert(events, {
		time = os.time(),
		kind = kind,
		data = simpleRemoteValue(data),
	})
	if #events > 250 then table.remove(events, 1) end
end

-- This observer consumes only normal server-to-client events. It never hooks a
-- namecall or replaces a game callback, so it cannot block the Confirm button.
local function createTowerObserver(matchRuntime)
	local observer = {
		byUUID = {},
		revision = {},
		matchEpoch = 0,
		-- This game's TowerDict is append-only across Replay/Next. UUIDs present at
		-- the beginning of a new match belong to the previous epoch and must never
		-- count as current placements or upgrade targets.
		priorEpochUUIDs = {},
		rejectedUpgradeUntil = {},
		-- Rejected points use a short cooldown rather than a permanent blacklist:
		-- insufficient money and temporary placement limits can mimic bad geometry.
		rejectedPlacementUntil = {},
		-- A placement point is reserved from InvokeServer until authoritative tower
		-- evidence or rejection arrives, preventing another slot from selecting it.
		pendingPlacementPositions = {},
		connection = nil,
	}

	function observer:merge(uuid, patch, eventKind)
		if typeof(patch) ~= "table" then return nil end
		uuid = tostring(rawget(patch, "UUID") or uuid or "")
		if uuid == "" then return nil end
		if eventKind == "CreateNewTower" then
			-- A newly created server tower is current even if an impossible UUID reuse
			-- occurs; normal UUIDs are unique and will not be in the baseline.
			self.priorEpochUUIDs[uuid] = nil
		elseif self.priorEpochUUIDs[uuid] then
			return nil
		end
		local existing = self.byUUID[uuid]
		local changed = typeof(existing) ~= "table"
			or rawget(existing, "Stage") ~= rawget(patch, "Stage")
			or rawget(existing, "TeamSlot") ~= rawget(patch, "TeamSlot")
			or rawget(existing, "TowerInventoryUUID") ~= rawget(patch, "TowerInventoryUUID")
		if typeof(existing) ~= "table" then existing = {}; self.byUUID[uuid] = existing end
		for key, value in next, patch do existing[key] = value end
		existing.UUID = rawget(existing, "UUID") or uuid
		if changed or eventKind ~= "TowerDictRefresh" then
			self.revision[uuid] = (self.revision[uuid] or 0) + 1
			appendGameplayEvent(eventKind, {
				uuid = uuid,
				stage = rawget(existing, "Stage"),
				teamSlot = rawget(existing, "TeamSlot"),
				inventoryUUID = rawget(existing, "TowerInventoryUUID"),
			})
		end
		return existing
	end

	function observer:refresh(runtime)
		local source = runtime or matchRuntime
		local dictionary = source and rawget(source, "TowerDict")
		if typeof(dictionary) ~= "table" then return end
		local liveUUIDs = {}
		for key, tower in next, dictionary do
			if typeof(tower) == "table" then
				local uuid = tostring(rawget(tower, "UUID") or key)
				local merged = not self.priorEpochUUIDs[uuid]
					and self:merge(key, tower, "TowerDictRefresh") or nil
				if merged then liveUUIDs[tostring(rawget(merged, "UUID") or key)] = true end
			end
		end

		-- TowerDict is an authoritative snapshot, not an append-only event stream.
		-- Remove UUIDs absent from the current dictionary so towers destroyed at the
		-- end of a match cannot be mistaken for placements in the following match.
		for uuid in next, self.byUUID do
			if not liveUUIDs[uuid] then
				self.byUUID[uuid] = nil
				self.revision[uuid] = nil
				appendGameplayEvent("TowerRemovedFromSnapshot", { uuid = uuid, epoch = self.matchEpoch })
			end
		end
	end

	function observer:owned()
		local result = {}
		local towerFolder = workspace:FindFirstChild("Towers")
		-- An empty workspace.Towers folder is direct scene evidence that no placed
		-- unit exists, even if a delayed client event still references an old table.
		if towerFolder and #towerFolder:GetChildren() == 0 then return result end
		for uuid, tower in next, self.byUUID do
			local owner = rawget(tower, "Owner")
			local linkedInstanceFound = false
			local linkedToWorkspace = false
			if towerFolder then
				for _, field in ipairs({ "Node", "Rig" }) do
					local instance = rawget(tower, field)
					if typeof(instance) == "Instance" then
						linkedInstanceFound = true
						if instance:IsDescendantOf(towerFolder) then linkedToWorkspace = true end
					end
				end
			end
			if (owner == nil or owner == player)
				and (not linkedInstanceFound or linkedToWorkspace) then
				result[uuid] = tower
			end
		end
		return result
	end

	function observer:beginMatch(runtime, epoch)
		-- Match-local UUIDs are invalid after replay/next. Clear every cache that can
		-- otherwise leak placement or rejection state across the match boundary.
		self.byUUID = {}
		self.revision = {}
		self.rejectedPlacementUntil = {}
		self.pendingPlacementPositions = {}
		self.rejectedUpgradeUntil = {}
		self.priorEpochUUIDs = {}
		self.matchEpoch = epoch
		-- Capture the append-only dictionary before any placement in this epoch.
		-- Do not merge this baseline: every entry is residue from an older match.
		local dictionary = runtime and rawget(runtime, "TowerDict")
		if typeof(dictionary) == "table" then
			for key, tower in next, dictionary do
				if typeof(tower) == "table" then
					local uuid = tostring(rawget(tower, "UUID") or key)
					self.priorEpochUUIDs[uuid] = true
				end
			end
		end
		local towerFolder = workspace:FindFirstChild("Towers")
		local enemyFolder = workspace:FindFirstChild("Enemies")
		appendGameplayEvent("MatchObserverReset", {
			epoch = epoch,
			workspaceTowers = towerFolder and #towerFolder:GetChildren() or nil,
			workspaceEnemies = enemyFolder and #enemyFolder:GetChildren() or nil,
			observedTowers = countEntries(self.byUUID),
			ignoredPriorEpochTowers = countEntries(self.priorEpochUUIDs),
		})
	end

	observer:refresh(matchRuntime)
	local remote = ReplicatedStorage:WaitForChild("LobbyRemotes")
		:WaitForChild("TowerHandlerRemotes")
		:WaitForChild("TowerHandlerRemote")
	observer.connection = remote.OnClientEvent:Connect(function(action, uuidOrInfo, patch)
		if action == "CreateNewTower" and typeof(uuidOrInfo) == "table" then
			observer:merge(nil, uuidOrInfo, "CreateNewTower")
		elseif action == "UpdateTower" and typeof(uuidOrInfo) == "string" and typeof(patch) == "table" then
			observer:merge(uuidOrInfo, patch, "UpdateTower")
		end
	end)
	return observer
end

local function vectorDistanceXZ(left, right)
	local dx, dz = left.X - right.X, left.Z - right.Z
	return math.sqrt(dx * dx + dz * dz)
end

local function towerPosition(tower)
	if typeof(tower) ~= "table" then return nil end
	local position = rawget(tower, "Position")
	if typeof(position) == "Vector3" then return position end
	local cf = rawget(tower, "cf")
	if typeof(cf) == "CFrame" then return cf.Position end
	return nil
end

local function collectPathPositions(value, result, visited, depth)
	result = result or {}
	visited = visited or {}
	depth = depth or 0
	if typeof(value) == "Vector3" then table.insert(result, value); return result end
	if typeof(value) ~= "table" or visited[value] or depth > 3 then return result end
	visited[value] = true
	-- Preserve numeric route order so index 1 and the final index remain usable as
	-- endpoint evidence. Non-array keys are still scanned deterministically after it.
	local length = #value
	for index = 1, length do
		collectPathPositions(rawget(value, index), result, visited, depth + 1)
	end
	local extraKeys = {}
	for key in next, value do
		if typeof(key) ~= "number" or key < 1 or key > length or key % 1 ~= 0 then
			table.insert(extraKeys, key)
		end
	end
	table.sort(extraKeys, function(left, right) return tostring(left) < tostring(right) end)
	for _, key in ipairs(extraKeys) do
		collectPathPositions(rawget(value, key), result, visited, depth + 1)
	end
	return result
end

local function instanceWorldPosition(instance)
	if typeof(instance) ~= "Instance" then return nil end
	if instance:IsA("BasePart") then return instance.Position end
	if instance:IsA("Model") then
		local ok, pivot = pcall(instance.GetPivot, instance)
		if ok then return pivot.Position end
	end
	return nil
end

local function collectWorkspacePositions(folderName)
	local result = {}
	local folder = workspace:FindFirstChild(folderName)
	if not folder then return result end
	for _, child in ipairs(folder:GetChildren()) do
		local position = instanceWorldPosition(child)
		if position then table.insert(result, position) end
	end
	return result
end

local function resolveWorkspacePathModel()
	local path = workspace:FindFirstChild("Path")
	return path and path:FindFirstChild("Model") or nil
end

local function collectWorkspacePathParts()
	local result = {}
	local model = resolveWorkspacePathModel()
	if not model then return result, nil end
	for _, descendant in ipairs(model:GetDescendants()) do
		if descendant:IsA("BasePart") then table.insert(result, descendant) end
	end
	table.sort(result, function(left, right) return left:GetFullName() < right:GetFullName() end)
	return result, model
end

local function pointBlockedByPath(position, pathParts, padding)
	padding = tonumber(padding) or 0
	for _, part in ipairs(pathParts) do
		-- Convert the world coordinate into each path part's local space so rotated
		-- roads are tested against their real oriented rectangle, not an AABB guess.
		local localPoint = part.CFrame:PointToObjectSpace(position)
		if math.abs(localPoint.X) <= part.Size.X * 0.5 + padding
			and math.abs(localPoint.Z) <= part.Size.Z * 0.5 + padding then
			return true, part
		end
	end
	return false, nil
end

local function minimumDistanceXZ(position, candidates)
	local nearest = math.huge
	for _, candidate in ipairs(candidates) do
		nearest = math.min(nearest, vectorDistanceXZ(position, candidate))
	end
	return nearest
end

local function placementCenter(region, placementPolicy)
	if placementPolicy == "spawn-forward" then
		return rawget(region, "forwardCenter")
	end
	-- mainCenter is the public Config name. Keep center as a compatibility alias
	-- so an older user config does not stop placement after updating AutoPlay.
	return rawget(region, "mainCenter") or rawget(region, "center")
end

local function appendSquareLayer(points, center, spacing, layer)
	if layer == 0 then
		table.insert(points, center)
		return
	end
	-- square-grid-dynamic: each layer adds only the perimeter of a larger odd
	-- square (3x3, 5x5, 7x7...), so no coordinate is generated twice.
	for offsetX = -layer, layer do
		for _, offsetZ in ipairs({ -layer, layer }) do
			table.insert(points, Vector3.new(
				center.X + offsetX * spacing,
				center.Y,
				center.Z + offsetZ * spacing
			))
		end
	end
	for offsetZ = -layer + 1, layer - 1 do
		for _, offsetX in ipairs({ -layer, layer }) do
			table.insert(points, Vector3.new(
				center.X + offsetX * spacing,
				center.Y,
				center.Z + offsetZ * spacing
			))
		end
	end
end

local function expandPlacementPoints(region, placementPolicy, requiredAvailable, pathParts, occupiedPositions)
	if typeof(region) ~= "table" then return {}, nil, {} end
	local center = placementCenter(region, placementPolicy)
	if typeof(center) ~= "Vector3" then return {}, nil, {} end

	local spacing = math.max(0.5, tonumber(rawget(region, "gridSpacing")) or 2.2)
	local reserveRatio = math.max(0, tonumber(rawget(region, "gridReserveRatio")) or 0.5)
	local required = math.max(1, math.ceil(tonumber(requiredAvailable) or 1))
	local targetAvailable = required + math.max(2, math.ceil(required * reserveRatio))
	local maximumLayers = math.max(1, math.floor(tonumber(rawget(region, "maximumGridLayers")) or 30))
	local pathPadding = tonumber(rawget(region, "pathPadding")) or 0
	local minimumSpacing = tonumber(Settings.minimumTowerSpacing) or spacing
	local points = {}
	local availableCount = 0
	local generatedLayers = 0

	for layer = 0, maximumLayers do
		local before = #points
		appendSquareLayer(points, center, spacing, layer)
		for index = before + 1, #points do
			local position = points[index]
			local isCenter = vectorDistanceXZ(position, center) < 0.01
			local blockedByPath = not isCenter and pointBlockedByPath(position, pathParts, pathPadding)
			local blockedByTower = minimumDistanceXZ(position, occupiedPositions) < minimumSpacing
			if not blockedByPath and not blockedByTower then availableCount += 1 end
		end
		generatedLayers = layer
		if availableCount >= targetAvailable then break end
	end

	return points, center, {
		policy = placementPolicy,
		required = required,
		targetAvailable = targetAvailable,
		available = availableCount,
		layers = generatedLayers,
		spacing = spacing,
	}
end

local function renderPlacementHolograms(region, capacities)
	local old = workspace:FindFirstChild("AnimeOriginPlacementHolograms")
	if old then old:Destroy() end
	-- A previous debug run may have left preview Parts behind. Always clean them,
	-- then return without allocating replacements when production previews are off.
	if rawget(region, "showHolograms") ~= true then return end

	local folder = Instance.new("Folder")
	folder.Name = "AnimeOriginPlacementHolograms"
	folder.Parent = workspace
	local pathParts, pathModel = collectWorkspacePathParts()
	local padding = tonumber(rawget(region, "pathPadding")) or 0
	local occupiedPositions = collectWorkspacePositions("Towers")
	local preview = {
		pathModel = pathModel and pathModel:GetFullName() or nil,
		pathParts = {},
		candidates = {},
		regions = {},
	}

	-- Outline the exact path BaseParts in red without changing collision,
	-- transparency or any other property of the game's own road geometry.
	for index, part in ipairs(pathParts) do
		table.insert(preview.pathParts, {
			index = index,
			path = part:GetFullName(),
			position = simpleRemoteValue(part.Position),
			size = simpleRemoteValue(part.Size),
			rightVector = simpleRemoteValue(part.CFrame.RightVector),
			lookVector = simpleRemoteValue(part.CFrame.LookVector),
		})
		local outline = Instance.new("SelectionBox")
		outline.Name = "Path_" .. tostring(index)
		outline.Adornee = part
		outline.Color3 = Color3.fromRGB(255, 55, 55)
		outline.SurfaceColor3 = Color3.fromRGB(255, 55, 55)
		outline.SurfaceTransparency = 0.86
		outline.LineThickness = 0.03
		outline.Parent = folder
	end

	local totalPoints = 0
	for _, specification in ipairs({
		{ policy = "cluster", required = tonumber(capacities and capacities.main) or 1 },
		{ policy = "spawn-forward", required = tonumber(capacities and capacities.forward) or 0 },
	}) do
		if specification.required > 0 then
			local points, center, generation = expandPlacementPoints(
				region,
				specification.policy,
				specification.required,
				pathParts,
				occupiedPositions
			)
			preview.regions[specification.policy] = generation
			for index, position in ipairs(points) do
				totalPoints += 1
				local isCenter = center and vectorDistanceXZ(position, center) < 0.01
				local blocked, blockingPart = pointBlockedByPath(position, pathParts, padding)
				-- Both centers came from successful PlaceTower calls and remain candidates
				-- even when path padding touches an edge of the road geometry.
				if isCenter then blocked, blockingPart = false, nil end
				local marker = Instance.new("Part")
				marker.Name = string.format("%s_%02d", specification.policy, index)
				marker.Shape = Enum.PartType.Cylinder
				marker.Size = Vector3.new(0.12, 1.35, 1.35)
				marker.CFrame = CFrame.new(position + Vector3.new(0, 0.12, 0))
					* CFrame.Angles(0, 0, math.rad(90))
				marker.Anchored = true
				marker.CanCollide = false
				marker.CanQuery = false
				marker.CanTouch = false
				marker.Material = Enum.Material.Neon
				marker.Transparency = 0.25
				marker.Color = isCenter and Color3.fromRGB(0, 190, 255)
					or (blocked and Color3.fromRGB(255, 45, 45)
						or (specification.policy == "spawn-forward"
							and Color3.fromRGB(255, 205, 50) or Color3.fromRGB(50, 255, 95)))
				marker.Parent = folder

				-- Keep only neon dots in-world. Full square-grid evidence remains in JSON.
				table.insert(preview.candidates, {
					index = index,
					policy = specification.policy,
					position = simpleRemoteValue(position),
					center = isCenter,
					blockedByPath = blocked,
					blockingPart = blockingPart and blockingPart:GetFullName() or nil,
				})
			end
		end
	end

	report.gameplay.placementPreview = preview
	log("HOLOGRAM", string.format("Rendered %d dynamic square-grid candidates against %d workspace.Path.Model parts.", totalPoints, #pathParts), {
		folder = folder:GetFullName(),
		pathModel = preview.pathModel,
		regions = preview.regions,
	})
	saveReport("Placement holograms rendered")
end

local function rankedPlacementPoints(unit, matchRuntime, observer, placementPolicy, spawnPosition, requiredAvailable)
	local fastStage = Config.fastGems and Config.fastGems.stage or {}
	local world = tostring(rawget(fastStage, "world") or "")
	local regions = Settings.placementRegions
	local worldRegions = typeof(regions) == "table" and rawget(regions, world) or nil
	local placementType = tostring(unit.placementType or "Ground")
	local region = typeof(worldRegions) == "table" and rawget(worldRegions, placementType) or nil
	if typeof(region) ~= "table" then return {}, world, placementType end
	local route = collectPathPositions(rawget(matchRuntime, "PathPositions"))
	local pathParts, pathModel = collectWorkspacePathParts()
	local occupied = observer:owned()
	local workspaceTowers = collectWorkspacePositions("Towers")
	local occupiedPositions = {}
	for _, tower in next, occupied do
		local position = towerPosition(tower)
		if position then table.insert(occupiedPositions, position) end
	end
	for _, position in ipairs(workspaceTowers) do table.insert(occupiedPositions, position) end
	for _, position in next, observer.pendingPlacementPositions do
		if typeof(position) == "Vector3" then table.insert(occupiedPositions, position) end
	end
	local points, clusterCenter = expandPlacementPoints(
		region,
		placementPolicy,
		requiredAvailable,
		pathParts,
		occupiedPositions
	)
	local pathPadding = tonumber(rawget(region, "pathPadding")) or 0
	report.gameplay.pathModel = pathModel and pathModel:GetFullName() or nil
	report.gameplay.pathPartCount = #pathParts
	local ranked = {}
	for ordinal, position in ipairs(points) do
		if typeof(position) == "Vector3" then
			local available = true
			local centerPoint = clusterCenter and vectorDistanceXZ(position, clusterCenter) < 0.01
			if minimumDistanceXZ(position, occupiedPositions) < (tonumber(Settings.minimumTowerSpacing) or 2.2) then
				available = false
			end
			-- workspace.Path.Model is the actual road geometry. Test generated points
			-- against every oriented BasePart and keep PathPositions only for coverage.
			if available and not centerPoint then
				local blocked = pointBlockedByPath(position, pathParts, pathPadding)
				if blocked then available = false end
			end
			if available then
				local coverage = 0
				for _, routePosition in ipairs(route) do
					if vectorDistanceXZ(position, routePosition) <= (tonumber(unit.range) or 0) then coverage += 1 end
				end
					table.insert(ranked, {
					position = position,
					coverage = coverage,
					clusterDistance = clusterCenter and vectorDistanceXZ(position, clusterCenter) or ordinal,
					spawnDistance = typeof(spawnPosition) == "Vector3"
						and vectorDistanceXZ(position, spawnPosition) or math.huge,
					ordinal = ordinal,
					pathModel = pathModel and pathModel:GetFullName() or nil,
				})
			end
		end
	end
	table.sort(ranked, function(left, right)
		-- Damage number four and later use the second square center. Spawn distance
		-- breaks ties toward the monster entrance inside that forward grid.
		if placementPolicy == "spawn-forward" and left.spawnDistance ~= right.spawnDistance then
			return left.spawnDistance < right.spawnDistance
		end
		if left.clusterDistance ~= right.clusterDistance then
			return left.clusterDistance < right.clusterDistance
		end
		if left.coverage ~= right.coverage then return left.coverage > right.coverage end
		return left.ordinal < right.ordinal
	end)
	return ranked, world, placementType
end

local function findTowersForUnit(observer, unit, slotName)
	local result = {}
	for uuid, tower in next, observer:owned() do
		if rawget(tower, "TowerInventoryUUID") == unit.uuid
			and (slotName == nil or rawget(tower, "TeamSlot") == slotName) then
			table.insert(result, { tower = tower, uuid = uuid })
		end
	end
	table.sort(result, function(left, right) return tostring(left.uuid) < tostring(right.uuid) end)
	return result
end

local function findTowerForUnit(observer, unit, slotName)
	local matches = findTowersForUnit(observer, unit, slotName)
	if matches[1] then return matches[1].tower, matches[1].uuid end
	return nil, nil
end

local function recordGameplayAction(action)
	-- Keep the same monotonic clock in JSON so a future diagnosis does not have
	-- to infer delays or match ownership from console line order alone.
	action.elapsed = action.elapsed or (os.clock() - sessionStartedClock)
	action.matchEpoch = action.matchEpoch or report.gameplay.matchEpoch
	table.insert(report.gameplay.actions, action)
	if #report.gameplay.actions > 250 then table.remove(report.gameplay.actions, 1) end
	saveReport("Gameplay action: " .. tostring(action.action))
end

local function placeUnit(towerFunction, observer, matchRuntime, unit, slot, targetCount, placementPolicy, spawnPosition, spawnSource, requiredAvailable)
	local slotName = "Tower" .. tostring(slot)
	local existing = findTowersForUnit(observer, unit, slotName)
	targetCount = tonumber(targetCount) or (#existing + 1)
	if #existing >= targetCount then
		return true, existing[1].tower, existing[1].uuid, "target-count-already-placed"
	end

	local points, world, placementType = rankedPlacementPoints(
		unit,
		matchRuntime,
		observer,
		placementPolicy,
		spawnPosition,
		requiredAvailable
	)
	if #points == 0 then
		return false, nil, nil, string.format("No unused %s point configured for %s", placementType, world)
	end

	local attempts = 0
	for _, candidate in ipairs(points) do
		-- Rejection and reservation keys are coordinate-global, not slot-specific;
		-- otherwise two different slots could repeatedly collide at the same point.
		local pointKey = string.format("%.3f|%.3f|%.3f", candidate.position.X, candidate.position.Y, candidate.position.Z)
		local retryAt = observer.rejectedPlacementUntil[pointKey]
		if not retryAt or os.clock() >= retryAt then
			attempts += 1
			local known = {}
			for uuid in next, observer:owned() do known[uuid] = true end
			local action = {
				action = "PlaceTower",
				slot = slotName,
				inventoryUUID = unit.uuid,
				identifier = unit.identifier,
				position = simpleRemoteValue(candidate.position),
				coverage = candidate.coverage,
				candidateIndex = candidate.ordinal,
				clusterDistance = candidate.clusterDistance,
				placementPolicy = placementPolicy or "cluster",
				spawnDistance = candidate.spawnDistance ~= math.huge and candidate.spawnDistance or nil,
				spawnPosition = simpleRemoteValue(spawnPosition),
				spawnSource = spawnSource,
				requiredAvailable = requiredAvailable,
				beforeCount = #existing,
				targetCount = targetCount,
			}
			log("PLACE", string.format("Trying %s at the best verified %s point.", slotName, placementType), action)
			observer.pendingPlacementPositions[pointKey] = candidate.position
			local ok, response = pcall(function()
				return towerFunction:InvokeServer(
					"PlaceTower",
					slotName,
					candidate.position,
					Vector3.new(0, 1, 0),
					0,
					nil,
					false
				)
			end)
			action.invokeOk = ok
			action.invokeResponse = simpleRemoteValue(response)

			local verified, evidence
			local rejectedByServer = ok and (response == false
				or (typeof(response) == "number" and response < 0))
			action.rejectedImmediately = rejectedByServer
			if rejectedByServer then
				-- Captured runs show invalid placement geometry returns -1. Treat both
				-- false and negative numbers as authoritative rejections so the planner
				-- advances through hologram candidates without a six-second stall.
				verified, evidence = false, nil
			else
				verified, evidence = waitFor(function()
					observer:refresh(matchRuntime)
					for uuid, tower in next, observer:owned() do
						if not known[uuid]
							and rawget(tower, "TowerInventoryUUID") == unit.uuid
							and rawget(tower, "TeamSlot") == slotName then
							return { tower = tower, uuid = uuid }
						end
					end
					return nil
				end, verifyTimeout)
			end
			-- Release only after the server result/evidence window closes. The next
			-- planner iteration can then use the authoritative tower position or retry.
			observer.pendingPlacementPositions[pointKey] = nil
			action.verified = verified
			if verified then
				observer.rejectedPlacementUntil[pointKey] = nil
				action.placedUUID = evidence.uuid
				action.afterCount = #existing + 1
				action.serverStage = rawget(evidence.tower, "Stage")
				recordGameplayAction(action)
				log("VERIFY", string.format("%s placement confirmed by CreateNewTower/TowerDict.", slotName), action)
				return true, evidence.tower, evidence.uuid, "verified"
			end
			observer.rejectedPlacementUntil[pointKey] = os.clock() + (tonumber(Settings.placementPointRetryDelay) or 10)
			recordGameplayAction(action)
			log("RETRY", string.format("Server did not confirm %s at this point; trying the next configured point.", slotName), action)
			if attempts >= (tonumber(Settings.maxPlacementAttemptsPerAction) or 3) then break end
		end
	end
	return false, nil, nil, "All configured points were rejected or timed out"
end

local function upgradeTower(towerFunction, observer, matchRuntime, tower, uuid, unit, observedMoney, moneySource)
	uuid = towerUUID(tower, uuid)
	local cost, targetStage, beforeStage = nextUpgrade(tower, unit)
	if not cost then return false, "max", nil end
	local action = {
		action = "UpgradeTower",
		placedUUID = uuid,
		identifier = unit.identifier,
		beforeStage = beforeStage,
		targetStage = targetStage,
		cost = cost,
		observedMoney = observedMoney,
		moneySource = moneySource,
	}
	log("UPGRADE", string.format("Upgrading %s from Stage %d to %d.", unit.displayName, beforeStage, targetStage), action)
	local ok, response = pcall(function()
		return towerFunction:InvokeServer("UpgradeTower", uuid)
	end)
	action.invokeOk = ok
	action.invokeResponse = simpleRemoteValue(response)
	if ok and response == false then
		-- Old/invalid UUIDs and server-side rejections return false immediately;
		-- record the negative evidence without blocking the gameplay loop for six seconds.
		action.verified = false
		action.rejectedImmediately = true
		observer.rejectedUpgradeUntil[uuid] = os.clock()
			+ (tonumber(Settings.upgradeRejectionCooldown) or 8)
		recordGameplayAction(action)
		log("RETRY", "Server rejected the upgrade immediately; the target will be re-resolved.", action)
		return false, "server-rejected", nil
	end
	local verified, updated = waitFor(function()
		observer:refresh(matchRuntime)
		local current = observer.byUUID[uuid]
		if current and (tonumber(rawget(current, "Stage")) or 0) > beforeStage then return current end
		return nil
	end, verifyTimeout)
	action.verified = verified
	action.afterStage = updated and rawget(updated, "Stage") or nil
	recordGameplayAction(action)
	if verified then
		observer.rejectedUpgradeUntil[uuid] = nil
		log("VERIFY", "Upgrade confirmed by UpdateTower/TowerDict.", action)
		return true, "verified", updated
	end
	observer.rejectedUpgradeUntil[uuid] = os.clock()
		+ (tonumber(Settings.upgradeRejectionCooldown) or 8)
	log("RETRY", "Upgrade was not confirmed; it will be retried after the cooldown.", action)
	return false, "not-confirmed", nil
end

local function run()
	-- AutoPlay owns the stage lifecycle. On the confirmed lobby place it must stay
	-- idle rather than treating the intentional absence of MatchRuntime as an error;
	-- Auto-Execute will launch a fresh controller after main.lua teleports to stage.
	local lobbyPlaces = Config.runtimePlaces and Config.runtimePlaces.lobby
	if typeof(lobbyPlaces) == "table" and lobbyPlaces[game.PlaceId] == true then
		report.status = "IDLE_LOBBY"
		log("CONTEXT", "Lobby detected; AutoPlay is idle until the stage teleport.", {
			placeId = game.PlaceId,
		})
		saveReport("Lobby context; waiting for stage Auto-Execute lifecycle")
		return report
	end

	local inventoryRemote = ReplicatedStorage:WaitForChild("Remotes"):WaitForChild("InventoryRemotes"):WaitForChild("InventoryRemote")
	local requiredDamage = tonumber(Settings.minimumDamageSlots) or 3
	local expectedDesired = {}
	local connections = {}

	-- Ranking is reusable when the script starts in the middle of a match: the
	-- desired team can be read without mutating EquippedTowers until pre-match.
	local function resolveDesiredTeam(reason)
		local _, towers, _, playerDataSource = readRuntime()
		report.playerDataSource = playerDataSource
		log("RUNTIME", "Resolving team for " .. reason .. ".", {
			source = playerDataSource,
			owned = countEntries(towers),
		})

		local definitions, sources, unresolved = resolveDefinitions(towers)
		report.unresolvedDefinitions = unresolved
		if #unresolved > 0 then fail("DEFINITIONS", "Missing StageStats for: " .. table.concat(unresolved, ", ")) end

		local damage, farms, excludedPlacement = buildRankings(towers, definitions, sources)
		if #damage < requiredDamage then fail("RANK", "Fewer than three unique damage units were resolved.") end
		report.rankedDamage, report.farmCandidates = {}, {}
		report.excludedPlacementUnits = excludedPlacement
		for index, unit in ipairs(damage) do report.rankedDamage[index] = serializableUnit(unit, nil) end
		for index, unit in ipairs(farms) do report.farmCandidates[index] = serializableUnit(unit, nil) end
		if #excludedPlacement > 0 then
			log("TEAM", "Excluded units with unsupported placement types.", excludedPlacement)
		end

		local desired = buildDesiredTeam(damage, farms)
		report.desiredTeam = {}
		for slot, unit in ipairs(desired) do report.desiredTeam[slot] = serializableUnit(unit, slot) end
		log("TEAM", "Desired order resolved for " .. reason .. ".", report.desiredTeam)
		-- Selected unit/definition tables now have direct references. Release the
		-- broad getgc array before the long-running match monitor begins.
		releaseGCObjects()
		return desired
	end

	local function recordTeamAction(action, configuration)
		table.insert(report.actions, action)
		if #report.actions > maximumRetainedTeamActions then table.remove(report.actions, 1) end
		if configuration then table.insert(configuration.actions, action) end
	end

	local function configureTeam(reason, nonFatal)
		report.firstLockedOrRejectedSlot = nil
		local desired = resolveDesiredTeam(reason)

		local before = readLoadout()
		if not report.initialLoadout then report.initialLoadout = before end
		local configuration = {
			reason = reason,
			startedAt = os.time(),
			before = before,
			actions = {},
		}
		table.insert(report.configurations, configuration)
		if #report.configurations > 50 then table.remove(report.configurations, 1) end

		log("ACTION", "Unequipping loadout for deterministic slot assignment.", before)
		inventoryRemote:FireServer("UnEquipAllTowers")
		local unequipAction = { action = "UnEquipAllTowers", before = before }
		recordTeamAction(unequipAction, configuration)

		local cleared = waitFor(function()
			return occupiedCount(readLoadout()) == 0
		end, verifyTimeout)
		unequipAction.verified = cleared
		if not cleared then
			if nonFatal then
				configuration.verified = false
				configuration.failedStage = "UNEQUIP_VERIFY"
				log("RETRY", "Server did not clear EquippedTowers in this vote window; team rebuild will retry.")
				return desired, false
			end
			fail("UNEQUIP_VERIFY", "EquippedTowers did not become empty.")
		end
		log("VERIFY", "Server loadout is empty.")

		for slot, unit in ipairs(desired) do
			log("ACTION", string.format("Equip slot %d: %s (%s)", slot, tostring(unit.displayName), unit.giveMoney and "farm" or "damage"), {
				uuid = unit.uuid,
				identifier = unit.identifier,
			})
			inventoryRemote:FireServer("EquipTower", unit.uuid)
			local verified = waitFor(function()
				local slots = readLoadout()
				return slots[slot] == unit.uuid and slots
			end, verifyTimeout)
			local equipAction = {
				action = "EquipTower",
				slot = slot,
				uuid = unit.uuid,
				verified = verified,
			}
			recordTeamAction(equipAction, configuration)

			if not verified then
				if slot <= requiredDamage then
					if nonFatal then
						configuration.verified = false
						configuration.failedStage = "EQUIP_VERIFY"
						configuration.failedSlot = slot
						log("RETRY", "Required slot " .. slot .. " was not confirmed; team rebuild will retry.")
						return desired, false
					end
					fail("EQUIP_VERIFY", "Required slot " .. slot .. " was rejected or did not update.")
				end
				report.firstLockedOrRejectedSlot = slot
				configuration.firstLockedOrRejectedSlot = slot
				log("SLOTS", "Slot " .. slot .. " is locked or server-rejected; later slots were not attempted.")
				break
			end
			log("VERIFY", "Slot " .. slot .. " confirmed by PlayerData.EquippedTowers.")
		end

		report.finalLoadout = readLoadout()
		for slot = 1, requiredDamage do
			if report.finalLoadout[slot] ~= desired[slot].uuid then
				fail("FINAL_VERIFY", "Final required slot " .. slot .. " does not match the desired UUID.")
			end
		end

		configuration.finishedAt = os.time()
		configuration.after = report.finalLoadout
		configuration.verified = true
		report.lifecycle.completedReconfigurations += 1
		report.lifecycle.lastReason = reason
		report.lifecycle.lastReconfiguredAt = os.time()
		report.lifecycle.pendingReason = nil
		expectedDesired = desired
		log("COMPLETE", "Team selection verified for " .. reason .. ".", report.finalLoadout)
		saveReport("Team selection verified: " .. reason)
		return desired, true
	end

	-- Later match preparations must preserve the already verified loadout. The
	-- first configuration is intentionally destructive for deterministic slot
	-- order, but repeating UnEquipAllTowers at every vote can be rejected by the
	-- server and previously caused UNEQUIP_VERIFY. Only append newly unlocked
	-- slots here and verify each accepted UUID through EquippedTowers.
	local function extendTeamAtVote(reason)
		local desired = resolveDesiredTeam(reason)
		local slots = readLoadout()
		local configuration = {
			reason = reason,
			mode = "fill-missing-slots",
			startedAt = os.time(),
			before = slots,
			actions = {},
		}
		table.insert(report.configurations, configuration)
		if #report.configurations > 50 then table.remove(report.configurations, 1) end

		-- A correct prefix followed by nil slots is recoverable in place. Clearing
		-- that prefix caused the old loop to equip slot 1, time out on slot 2, then
		-- erase slot 1 again forever. Rebuild only when a required slot is occupied
		-- by the wrong UUID; missing slots are filled below.
		for slot = 1, requiredDamage do
			local actual = slots[slot]
			if actual ~= nil and actual ~= desired[slot].uuid then
				configuration.verified = false
				configuration.after = slots
				configuration.blockedRequiredSlot = slot
				log("TEAM", "Required slot " .. slot .. " differs; rebuilding the Ground-only team before ready.", {
				expected = desired[slot].uuid,
				actual = slots[slot],
			})
				-- This commonly occurs once after enabling Hill exclusion. Rebuild only
				-- during the authoritative pre-match vote and keep failures non-fatal so
				-- the same vote window can retry after a short cooldown.
				return configureTeam(reason .. " required-team rebuild", true)
			end
		end

		local slotProbeTimeout = tonumber(Settings.slotProbeTimeout) or 1.5
		for slot = 1, #desired do
			if slots[slot] == desired[slot].uuid then
				-- This slot is already authoritative and needs no remote call.
			elseif slots[slot] ~= nil then
				local occupiedIsFarmer = false
				for _, candidate in ipairs(report.farmCandidates or {}) do
					if candidate.uuid == slots[slot] then occupiedIsFarmer = true; break end
				end
				if Settings.useFarmerUnit == false and occupiedIsFarmer then
					-- A farmer-disabled policy is different from an ordinary optional-slot
					-- mismatch. Rebuild only in this authoritative pre-match window so an
					-- old Leorio cannot remain equipped forever while merely being skipped
					-- by the placement loop.
					log("TEAM", "Farmer-disabled policy found an equipped farmer; rebuilding the loadout.", {
						slot = slot,
						actual = slots[slot],
						expected = desired[slot].uuid,
					})
					return configureTeam(reason .. " farmer-policy rebuild", true)
				end
				-- Preserve a different occupied optional slot; changing it is not worth
				-- risking the three verified damage slots during a live vote window.
				configuration.preservedDifferentSlot = slot
				log("DEFER", "Optional slot " .. slot .. " is occupied by another UUID; preserving it.", {
				expected = desired[slot].uuid,
				actual = slots[slot],
			})
				break
			else
				local unit = desired[slot]
				log("ACTION", string.format("Probing newly unlocked slot %d with %s.", slot, tostring(unit.displayName)), {
				uuid = unit.uuid,
				identifier = unit.identifier,
			})
				inventoryRemote:FireServer("EquipTower", unit.uuid)
				local confirmationTimeout = slot <= requiredDamage and verifyTimeout or slotProbeTimeout
				local verified, updatedSlots = waitFor(function()
					local current = readLoadout()
					return current[slot] == unit.uuid and current
				end, confirmationTimeout)
				local action = {
					action = "EquipTower",
					mode = "newly-unlocked-slot-probe",
					slot = slot,
					uuid = unit.uuid,
					verified = verified,
				}
				recordTeamAction(action, configuration)
				if not verified then
					if slot <= requiredDamage then
						configuration.verified = false
						configuration.failedStage = "FILL_REQUIRED_SLOT_VERIFY"
						configuration.failedSlot = slot
						log("RETRY", "Required missing slot " .. slot
							.. " was not confirmed; preserving the correct prefix and retrying.")
						return desired, false
					end
					report.firstLockedOrRejectedSlot = slot
					configuration.firstLockedOrRejectedSlot = slot
					log("SLOTS", "Slot " .. slot .. " is still locked or server-rejected; keeping the current team.")
					break
				end
				-- Continue from the authoritative table returned by the successful
				-- predicate; the boolean verification flag is not the loadout itself.
				slots = updatedSlots
				log("VERIFY", "New slot " .. slot .. " confirmed by PlayerData.EquippedTowers.")
			end
		end

		configuration.finishedAt = os.time()
		configuration.after = readLoadout()
		configuration.verified = true
		report.finalLoadout = configuration.after
		report.lifecycle.completedReconfigurations += 1
		report.lifecycle.lastReason = reason
		report.lifecycle.lastReconfiguredAt = os.time()
		expectedDesired = desired
		log("COMPLETE", "Existing team preserved and unlocked-slot probe completed.", configuration.after)
		saveReport("Unlocked-slot probe completed: " .. reason)
		return desired, true
	end

	-- MatchRuntime is normally created after the initial Auto-Execute scan. Use a
	-- slower dedicated discovery cadence here instead of the 0.1-second gameplay
	-- polling loop, which would repeatedly traverse the entire getgc list.
	local matchRuntime, matchRuntimeSource
	local runtimeDeadline = os.clock() + (tonumber(Settings.startupContextTimeout) or 60)
	repeat
		matchRuntime, matchRuntimeSource = resolveMatchRuntime(nil, true)
		if matchRuntime then break end
		task.wait(tonumber(Settings.runtimeDiscoveryInterval) or 0.25)
	until os.clock() >= runtimeDeadline
	if not matchRuntime then fail("MATCH_RUNTIME", "MatchRuntime was not found before the bounded stage-load timeout.") end
	report.gameplay.matchRuntimeSource = matchRuntimeSource
	log("RUNTIME", "Verified MatchRuntime resolved.", { source = report.gameplay.matchRuntimeSource })

	local towerFunction = ReplicatedStorage:WaitForChild("LobbyRemotes")
		:WaitForChild("TowerHandlerRemotes")
		:WaitForChild("TowerHandlerFunction")
	local actRemote = ReplicatedStorage:WaitForChild("LobbyRemotes"):WaitForChild("ActRemoteEvent")
	-- TeleportToLobby is the verified emergency reset for a replay scene that never
	-- removes its old server towers. It is deliberately separate from ready voting.
	local genericRemote = ReplicatedStorage:WaitForChild("Remotes"):WaitForChild("RemoteEvent")
	local observer = createTowerObserver(matchRuntime)
	table.insert(connections, observer.connection)
	local function renderConfiguredPlacementPreview()
		local previewStage = Config.fastGems and Config.fastGems.stage or {}
		local previewWorld = tostring(rawget(previewStage, "world") or "")
		local previewRegions = typeof(Settings.placementRegions) == "table"
			and rawget(Settings.placementRegions, previewWorld) or nil
		local previewRegion = typeof(previewRegions) == "table"
			and rawget(previewRegions, "Ground") or nil
		if typeof(previewRegion) == "table" then
			local damageCapacity, farmerCapacity = 0, 0
			local liveSlots = readLoadout()
			for slot, unit in ipairs(expectedDesired) do
				-- Locked desired slots are plans, not placeable capacity. Count only UUIDs
				-- proven present in the live EquippedTowers table.
				if liveSlots[slot] == unit.uuid then
					local limit = math.max(1, tonumber(unit.limit) or 1)
					if unit.giveMoney then
						farmerCapacity = farmerCapacity + limit
					else
						damageCapacity = damageCapacity + limit
					end
				end
			end
			local initialGate = tonumber(Settings.initialDamagePlacements or Settings.targetDamagePlacements) or 3
			local farmerTarget = tonumber(Settings.targetFarmerPlacements) or 3
			-- Grid sizes come from actual equipped-definition capacity, never fixed
			-- hologram counts. Extra blocked cells cause more square layers automatically.
			renderPlacementHolograms(previewRegion, {
				main = math.min(initialGate, damageCapacity) + math.min(farmerTarget, farmerCapacity),
				forward = math.max(0, damageCapacity - initialGate),
			})
		end
	end

	-- StartWaveVote is the authoritative pre-match window. Listening for it avoids
	-- firing WaveVote from the end screen, where GameStarted is also false.
	local voteState = { active = false, generation = 0 }
	table.insert(connections, actRemote.OnClientEvent:Connect(function(action)
		if action == "StartWaveVote" then
			voteState.active = true
			voteState.generation += 1
			recordLifecycleEvent("StartWaveVote", actRemote:GetFullName(), { generation = voteState.generation })
		elseif action == "UpdateWaveVote" then
			-- A script can attach after StartWaveVote was already delivered. The
			-- countdown update proves that the same pre-match window is still active.
			voteState.active = true
		elseif action == "EndWaveVote" then
			voteState.active = false
			recordLifecycleEvent("EndWaveVote", actRemote:GetFullName(), { generation = voteState.generation })
		end
	end))

	local started = rawget(matchRuntime, "GameStarted") == true
	if not started then
		-- Allow an already-running vote countdown to identify pre-match. Without
		-- this evidence, GameStarted=false may be an end screen and team remotes are
		-- deliberately deferred instead of repeating the old UNEQUIP_VERIFY bug.
		-- Keep the listener settle bounded and configurable; the old fixed 0.5s wait
		-- delayed every initial ready vote even when StartWaveVote was already live.
		task.wait(math.max(pollInterval, tonumber(Settings.voteAttachSettleDelay) or 0.15))
		started = rawget(matchRuntime, "GameStarted") == true
	end
	local initialPrematch = not started and voteState.active
	local initialVoteWindow = initialPrematch
	local configuredForVoteGeneration = nil
	local readySentGeneration = nil
	local readySentAt = nil
	local pendingReadyAction = nil
	-- Set only while AutoPlay is parked waiting for a StartWaveVote it may never
	-- receive; nil at every other time. See missedVoteRecoveryTimeout in Config.
	local missedVoteDeadline = nil
	-- This state is scoped to one StartWaveVote generation. TowerDict is append-only
	-- in this game, so only workspace.Towers is authoritative scene-cleanup evidence.
	local sceneCleanupGate = {
		generation = nil,
		startedAt = nil,
		zeroSamples = 0,
		warningLogged = false,
		dirtyBeforeReady = false,
		preReadyTowerCount = 0,
		postStartAt = nil,
		postStartZeroSamples = 0,
		postStartVerified = true,
		recoverySent = false,
	}
	local nextTeamPrepareAt = 0
	local lastStarted = started
	local nextActionAt = 0
	local placementBlockedUntil = 0
	local lastWaitLogAt = 0
	local gameplayAllowed = true

	local function workspaceTowerCount()
		local folder = workspace:FindFirstChild("Towers")
		return folder and #folder:GetChildren() or 0
	end

	-- Never ready a replay while old scene towers still exist. The server counts
	-- those instances even when the epoch observer correctly ignores their UUIDs,
	-- which is why placement eventually failed at 43 retained towers.
	local function sceneReadyForWaveVote(generation)
		if sceneCleanupGate.generation ~= generation then
			sceneCleanupGate.generation = generation
			sceneCleanupGate.startedAt = os.clock()
			sceneCleanupGate.zeroSamples = 0
			sceneCleanupGate.warningLogged = false
			sceneCleanupGate.dirtyBeforeReady = false
			sceneCleanupGate.preReadyTowerCount = 0
			sceneCleanupGate.postStartAt = nil
			sceneCleanupGate.postStartZeroSamples = 0
			sceneCleanupGate.postStartVerified = true
			sceneCleanupGate.recoverySent = false
		end

		local towerCount = workspaceTowerCount()
		if towerCount == 0 then
			sceneCleanupGate.zeroSamples += 1
		else
			sceneCleanupGate.zeroSamples = 0
		end

		local requiredSamples = math.max(1, tonumber(Settings.sceneCleanupStableSamples) or 2)
		if sceneCleanupGate.zeroSamples >= requiredSamples then
			sceneCleanupGate.dirtyBeforeReady = false
			sceneCleanupGate.preReadyTowerCount = 0
			return true, towerCount
		end

		if towerCount > 0 and not sceneCleanupGate.warningLogged then
			sceneCleanupGate.warningLogged = true
			log("CLEANUP_WAIT", "Scene residue blocks WaveVote; waiting for workspace.Towers to clear.", {
				generation = generation,
				workspaceTowers = towerCount,
			})
		end

		-- The normal server path may clear the old scene only after receiving WaveVote.
		-- After a short grace period, allow that transition but remember that gameplay
		-- must remain disabled until a post-start empty-scene sample is verified.
		local grace = math.max(0, tonumber(Settings.sceneCleanupPreReadyGrace) or 1.5)
		if os.clock() - sceneCleanupGate.startedAt >= grace then
			sceneCleanupGate.dirtyBeforeReady = towerCount > 0
			sceneCleanupGate.preReadyTowerCount = towerCount
			if sceneCleanupGate.dirtyBeforeReady then
				log("CLEANUP_PENDING", "WaveVote may proceed, but gameplay remains blocked until the new scene is empty.", {
					generation = generation,
					workspaceTowers = towerCount,
				})
			end
			return true, towerCount
		end

		return false, towerCount
	end

	-- Verify cleanup after GameStarted because Replay can defer removal until the
	-- vote transition. No placement or upgrade is allowed while this returns false.
	local function sceneReadyForGameplay()
		if sceneCleanupGate.postStartVerified then return true end

		local towerCount = workspaceTowerCount()
		if towerCount == 0 then
			sceneCleanupGate.postStartZeroSamples += 1
		else
			sceneCleanupGate.postStartZeroSamples = 0
		end

		local requiredSamples = math.max(1, tonumber(Settings.sceneCleanupStableSamples) or 2)
		if sceneCleanupGate.postStartZeroSamples >= requiredSamples then
			sceneCleanupGate.postStartVerified = true
			log("CLEANUP_VERIFY", "New match scene is empty; placement and upgrades are now enabled.", {
				generation = sceneCleanupGate.generation,
				previousWorkspaceTowers = sceneCleanupGate.preReadyTowerCount,
			})
			saveReport("Post-WaveVote scene cleanup verified")
			return true
		end

		local timeout = math.max(1, tonumber(Settings.sceneCleanupTimeout) or 5)
		if os.clock() - sceneCleanupGate.postStartAt >= timeout and not sceneCleanupGate.recoverySent then
			sceneCleanupGate.recoverySent = true
			local action = {
				action = "TeleportToLobby",
				reason = "STALE_WORKSPACE_TOWERS",
				generation = sceneCleanupGate.generation,
				workspaceTowers = towerCount,
				verified = false,
			}
			recordGameplayAction(action)
			genericRemote:FireServer("TeleportToLobby")
			log("RECOVERY", "Scene cleanup timed out; requested one server-reset return to lobby.", action)
			saveReport("Stale replay scene recovery requested")
		end

		return false
	end

	if started then
		expectedDesired = resolveDesiredTeam("mid-match read-only plan")
		local liveSlots = readLoadout()
		for slot = 1, requiredDamage do
			if not expectedDesired[slot] or liveSlots[slot] ~= expectedDesired[slot].uuid then
				gameplayAllowed = false
				break
			end
		end
		log("DEFER", gameplayAllowed
			and "Script started mid-match; keeping the live team and enabling verified gameplay."
			or "Script started mid-match with a different team; team mutation and gameplay are deferred to the next StartWaveVote.")
	elseif initialPrematch then
		expectedDesired = configureTeam("initial pre-match")
		configuredForVoteGeneration = voteState.generation
		initialPrematch = false
	else
		expectedDesired = resolveDesiredTeam("waiting for authoritative StartWaveVote")
		gameplayAllowed = false
		-- Arm the missed-vote recovery: this is the only branch that can wait forever.
		local recoveryWindow = math.max(0, tonumber(Settings.missedVoteRecoveryTimeout) or 20)
		missedVoteDeadline = recoveryWindow > 0 and (os.clock() + recoveryWindow) or nil
		log("DEFER", "GameStarted is false without a live vote signal; treating this as an end/loading screen until StartWaveVote arrives.", {
			recoveryWindow = recoveryWindow > 0 and recoveryWindow or nil,
		})
	end
	-- Render only after desiredTeam is known so square-grid capacity is derived from
	-- live unit Limits, including when AutoPlay attaches during an active match.
	renderConfiguredPlacementPreview()

	environment.AnimeOriginAutoPlayReport = report
	report.lifecycle.monitoring = true
	report.status = "MONITORING"
	log("MONITOR", "No-hook match observer armed; waiting for server lifecycle evidence.")
	saveReport("Full AutoPlay monitor armed")

	local function activeDesiredUnits()
		local slots = readLoadout()
		local active = {}
		for slot, unit in ipairs(expectedDesired) do
			if slots[slot] == unit.uuid then active[slot] = unit end
		end
		report.lifecycle.currentLoadoutSignature = loadoutSignature(slots)
		return active
	end

	-- Accept the old name for existing user configs, but "initial" states the
	-- actual semantics: three is a safety gate, never the final damage count.
	local initialDamagePlacements = tonumber(
		Settings.initialDamagePlacements or Settings.targetDamagePlacements
	) or 3
	local targetFarmerPlacements = tonumber(Settings.targetFarmerPlacements) or 3
	local damageForwardPlacementStart = tonumber(Settings.damageForwardPlacementStart) or 4
	local monsterSpawnEvidence = { position = nil, source = nil, confirmed = false }

	local function placedCounts(active)
		local summary = {
			damage = 0,
			farmer = 0,
			damageCapacity = 0,
			farmerCapacity = 0,
			bySlot = {},
		}
		for slot, unit in pairs(active) do
			local count = #findTowersForUnit(observer, unit, "Tower" .. tostring(slot))
			local limit = math.max(1, tonumber(unit.limit) or 1)
			summary.bySlot[slot] = count
			-- Keep damage and farmer instance totals separate. These are live tower
			-- counts, so placing the same equipped unit three times counts as three.
			if unit.giveMoney then
				summary.farmer = summary.farmer + count
				summary.farmerCapacity = summary.farmerCapacity + limit
			else
				summary.damage = summary.damage + count
				summary.damageCapacity = summary.damageCapacity + limit
			end
		end
		return summary
	end

	local function resolveMonsterSpawnEvidence()
		local route = collectPathPositions(rawget(matchRuntime, "PathPositions"))
		local firstRoute = route[1]
		local lastRoute = route[#route]
		local enemyPositions = collectWorkspacePositions("Enemies")

		-- The first live enemy sample disambiguates route direction. Snap that sample
		-- to the nearer route endpoint so later movement cannot move the spawn target.
		if not monsterSpawnEvidence.confirmed and #enemyPositions > 0 then
			local sample = enemyPositions[1]
			if typeof(firstRoute) == "Vector3" and typeof(lastRoute) == "Vector3" then
				monsterSpawnEvidence.position = vectorDistanceXZ(sample, firstRoute)
					<= vectorDistanceXZ(sample, lastRoute) and firstRoute or lastRoute
				monsterSpawnEvidence.source = "workspace.Enemies sample -> nearest PathPositions endpoint"
			else
				monsterSpawnEvidence.position = sample
				monsterSpawnEvidence.source = "workspace.Enemies first observed position"
			end
			monsterSpawnEvidence.confirmed = true
			report.gameplay.monsterSpawnPosition = simpleRemoteValue(monsterSpawnEvidence.position)
			report.gameplay.monsterSpawnSource = monsterSpawnEvidence.source
			log("SPAWN", "Monster spawn direction confirmed without UI evidence.", {
				position = report.gameplay.monsterSpawnPosition,
				source = monsterSpawnEvidence.source,
			})
		end

		if monsterSpawnEvidence.confirmed then
			return monsterSpawnEvidence.position, monsterSpawnEvidence.source
		end
		-- Damage number four normally occurs after enemies exist. PathPositions[1]
		-- remains a non-UI fallback if no enemy model has replicated yet.
		return firstRoute, firstRoute and "MatchRuntime.PathPositions first endpoint (fallback)" or nil
	end

	-- Placement targets count live tower instances. The first three damage towers
	-- are only a safety gate: after the optional Leorio target is met (or skipped),
	-- fill all damage definitions to their Limits instead of treating three as a cap.
	local function choosePlacement(active, money)
		local counts = placedCounts(active)
		local pool = {}
		local farmerEquipped = counts.farmerCapacity > 0
		local farmerTarget = math.min(targetFarmerPlacements, counts.farmerCapacity)
		local phase = counts.damage < math.min(initialDamagePlacements, counts.damageCapacity)
			and "core-damage"
			or (farmerEquipped and counts.farmer < farmerTarget and "farmer" or "remaining-damage")

		for slot = 1, #expectedDesired do
			local unit = active[slot]
			if unit then
				local placed = counts.bySlot[slot] or 0
				local limit = math.max(1, tonumber(unit.limit) or 1)
				local candidate = {
					slot = slot,
					unit = unit,
					cost = tonumber(unit.cost) or math.huge,
					placed = placed,
					targetCount = placed + 1,
					limit = limit,
				}
				if phase == "core-damage" and not unit.giveMoney and placed < limit then
					table.insert(pool, candidate)
				elseif phase == "farmer" and unit.giveMoney
					and placed < math.min(limit, targetFarmerPlacements) then
					table.insert(pool, candidate)
				elseif phase == "remaining-damage" and not unit.giveMoney and placed < limit then
					table.insert(pool, candidate)
				end
			end
		end

		if #pool == 0 then return nil, nil, nil, nil, nil, nil, counts end
		table.sort(pool, function(left, right)
			if phase == "farmer" and left.unit.giveMoney ~= right.unit.giveMoney then
				return left.unit.giveMoney > right.unit.giveMoney
			end
			local leftDPS = tonumber(left.unit.dps) or 0
			local rightDPS = tonumber(right.unit.dps) or 0
			if leftDPS ~= rightDPS then return leftDPS > rightDPS end
			if left.cost ~= right.cost then return left.cost < right.cost end
			return left.slot < right.slot
		end)

		local selected
		if money ~= nil then
			for _, candidate in ipairs(pool) do
				if money >= candidate.cost then
					selected = candidate
					break
				end
			end
		end

		local cheapest = pool[1]
		for _, candidate in ipairs(pool) do
			if candidate.cost < cheapest.cost then cheapest = candidate end
		end
		return selected and selected.slot or nil,
			selected and selected.unit or nil,
			cheapest.slot,
			cheapest.unit,
			phase,
			selected and selected.targetCount or nil,
			counts
	end

	local function placementTargetsMet(active)
		local counts = placedCounts(active)
		-- Clamp gates to actual equipped capacity so a locked slot or lower server
		-- Limit cannot deadlock upgrades forever.
		local damageTarget = math.min(initialDamagePlacements, counts.damageCapacity)
		local farmerTarget = math.min(targetFarmerPlacements, counts.farmerCapacity)
		return counts.damage >= damageTarget and counts.farmer >= farmerTarget, counts
	end

	local function nextFarmerUpgradeReserve(active)
		local reserve
		for slot, unit in pairs(active) do
			if unit.giveMoney then
				for _, match in ipairs(findTowersForUnit(observer, unit, "Tower" .. tostring(slot))) do
					local cost = nextUpgrade(match.tower, unit)
					if cost and (reserve == nil or cost < reserve) then reserve = cost end
				end
			end
		end
		-- Zero means every farmer is maxed or no farmer exists. Before that point,
		-- damage placement/upgrades may spend only money above this next farm cost.
		return reserve or 0
	end

	local function chooseUpgrade(active, money)
		if not placementTargetsMet(active) then return nil end
		local farmerCandidates = {}
		local damageCandidates = {}
		for slot, unit in pairs(active) do
			for _, match in ipairs(findTowersForUnit(observer, unit, "Tower" .. tostring(slot))) do
				local tower, uuid = match.tower, match.uuid
				local cost = nextUpgrade(tower, unit)
				local rejectedUntil = observer.rejectedUpgradeUntil[uuid]
				if rejectedUntil and os.clock() < rejectedUntil then cost = nil end
				if unit.giveMoney then
					if cost then table.insert(farmerCandidates, { tower = tower, uuid = uuid, unit = unit, cost = cost }) end
				elseif cost then
					table.insert(damageCandidates, { tower = tower, uuid = uuid, unit = unit, cost = cost })
				end
			end
		end

		table.sort(farmerCandidates, function(left, right)
			if left.cost ~= right.cost then return left.cost < right.cost end
			return tostring(left.uuid) < tostring(right.uuid)
		end)
		for _, candidate in ipairs(farmerCandidates) do
			if money >= candidate.cost then
				return candidate.tower, candidate.uuid, candidate.unit, candidate.cost, "farmer-priority"
			end
		end

		-- Reserve the cheapest next upgrade among all three Leorio instances before
		-- spending the remainder on any damage tower.
		local reserve = farmerCandidates[1] and farmerCandidates[1].cost or 0
		table.sort(damageCandidates, function(left, right)
			if left.unit.dps ~= right.unit.dps then return left.unit.dps > right.unit.dps end
			return left.cost < right.cost
		end)
		for _, candidate in ipairs(damageCandidates) do
			if money - reserve >= candidate.cost then
				return candidate.tower, candidate.uuid, candidate.unit, candidate.cost, "damage-from-remainder"
			end
		end
		return nil
	end

	while not controller.stopRequested do
		observer:refresh(matchRuntime)
		started = rawget(matchRuntime, "GameStarted") == true

		if started ~= lastStarted then
			if started then
				report.gameplay.matchEpoch += 1
				-- Replay/Next may allocate a new runtime table. Prefer the currently
				-- started instance, then reset all match-local tower UUID evidence.
				local currentRuntime, currentSource = resolveMatchRuntime(true, true)
				if currentRuntime then
					matchRuntime = currentRuntime
					report.gameplay.matchRuntimeSource = currentSource
				end
				-- Keep only the new MatchRuntime table, not its temporary getgc snapshot.
				releaseGCObjects()
				observer:beginMatch(matchRuntime, report.gameplay.matchEpoch)
				-- A replay creates a new enemy route lifecycle. Discard the previous
				-- endpoint evidence so forward damage follows this match's spawn.
				monsterSpawnEvidence.position = nil
				monsterSpawnEvidence.source = nil
				monsterSpawnEvidence.confirmed = false
				report.gameplay.monsterSpawnPosition = nil
				report.gameplay.monsterSpawnSource = nil
				-- Rebuild the visible candidate map for every replay/next because the
				-- stage scene and workspace.Path.Model instances can be recreated.
				renderConfiguredPlacementPreview()
				-- A dirty pre-ready scene must prove its old towers were removed after
				-- GameStarted before any placement or upgrade is allowed.
				sceneCleanupGate.postStartAt = os.clock()
				sceneCleanupGate.postStartZeroSamples = 0
				sceneCleanupGate.postStartVerified = not sceneCleanupGate.dirtyBeforeReady
				sceneCleanupGate.recoverySent = false
				gameplayAllowed = sceneCleanupGate.postStartVerified
				initialVoteWindow = false
				readySentAt = nil
				if pendingReadyAction then pendingReadyAction.verified = true; pendingReadyAction = nil end
				log("VERIFY", "WaveVote confirmed: MatchRuntime.GameStarted changed to true.", {
					epoch = report.gameplay.matchEpoch,
					workspaceTowers = workspace:FindFirstChild("Towers") and #workspace.Towers:GetChildren() or nil,
					workspaceEnemies = workspace:FindFirstChild("Enemies") and #workspace.Enemies:GetChildren() or nil,
					runtimeSource = report.gameplay.matchRuntimeSource,
				})
			else
				gameplayAllowed = false
				configuredForVoteGeneration = nil
				readySentGeneration = nil
				log("LIFECYCLE", "MatchRuntime.GameStarted changed to false; waiting for the next StartWaveVote.")
			end
			lastStarted = started
			saveReport("GameStarted changed")
		end

		-- Sample workspace.Enemies continuously while a match is active. The first
		-- replicated sample confirms which PathPositions endpoint is the monster spawn.
		if started then
			if not sceneCleanupGate.postStartVerified then
				gameplayAllowed = sceneReadyForGameplay()
			end
			resolveMonsterSpawnEvidence()
		end

		if not started then
			-- Recover a StartWaveVote that was delivered before this listener existed.
			-- Restricted to the exact shape of that failure so an end screen can never
			-- match it: no vote generation was ever observed, the match is stopped, and
			-- workspace.Towers has been verifiably empty. An end screen reached after a
			-- real match always has a generation, because AutoPlay saw that match start.
			if missedVoteDeadline and not voteState.active and voteState.generation == 0
				and os.clock() >= missedVoteDeadline then
				local towerCount = workspaceTowerCount()
				if towerCount == 0 then
					voteState.active = true
					voteState.generation += 1
					missedVoteDeadline = nil
					log("RECOVER", "No StartWaveVote arrived on a stopped, empty scene; assuming the vote "
						.. "window opened before AutoPlay attached and preparing the team.", {
						waitedSeconds = tonumber(Settings.missedVoteRecoveryTimeout) or 20,
						towerCount = towerCount,
						generation = voteState.generation,
					})
					recordLifecycleEvent("StartWaveVoteAssumed", "AutoPlay.missedVoteRecovery",
						{ generation = voteState.generation })
				else
					-- Towers still present means a scene that has not been cleaned yet,
					-- which is an end/replay screen rather than a fresh pre-match.
					missedVoteDeadline = os.clock() + 5
					log("DEFER", "Missed-vote recovery deferred; the scene still holds towers.", {
						towerCount = towerCount,
					})
				end
			end

			local mayPrepare = initialVoteWindow or voteState.active
			if mayPrepare and configuredForVoteGeneration ~= voteState.generation
				and os.clock() >= nextTeamPrepareAt then
				local teamPrepared = false
				if initialVoteWindow and #expectedDesired >= requiredDamage then
					-- The initial team was already verified before StartWaveVote arrived;
					-- reuse it instead of unequipping and equipping the same UUIDs twice.
					teamPrepared = true
					log("TEAM", "Initial verified team reused for the active vote generation.")
				else
					-- On later matches only probe empty newly unlocked slots. Rebuilding
					-- the entire team here was both slow and rejected by some transitions.
					local extended, verified = extendTeamAtVote(initialPrematch and "initial pre-match refresh" or "next StartWaveVote")
					expectedDesired = extended
					teamPrepared = verified
				end
				gameplayAllowed = teamPrepared
				if teamPrepared then
					configuredForVoteGeneration = voteState.generation
					nextTeamPrepareAt = 0
				else
					-- A transition can reject loadout mutation briefly. Retry the same
					-- generation instead of marking it configured and remaining stuck.
					configuredForVoteGeneration = nil
					nextTeamPrepareAt = os.clock() + (tonumber(Settings.teamPrepareRetryDelay) or 1.5)
				end
				initialPrematch = false
			end

			if Settings.autoReady == true and gameplayAllowed and mayPrepare
				and configuredForVoteGeneration == voteState.generation
				and readySentGeneration ~= voteState.generation then
				local sceneReady = sceneReadyForWaveVote(voteState.generation)
				if sceneReady then
					actRemote:FireServer("WaveVote", true)
					readySentGeneration = voteState.generation
					readySentAt = os.clock()
					local action = { action = "WaveVote", ready = true, generation = voteState.generation, verified = false }
					pendingReadyAction = action
					recordGameplayAction(action)
					log("READY", "WaveVote sent after verified scene cleanup; waiting for GameStarted server evidence.", action)
				end
			end

			if readySentAt and os.clock() - readySentAt > (tonumber(Settings.readyVerifyTimeout) or 45) then
				log("RETRY", "WaveVote did not produce GameStarted within the verification window; it may retry on the next vote.")
				readySentAt = nil
				readySentGeneration = nil
			end
		elseif gameplayAllowed and os.clock() >= nextActionAt then
			local money, moneySource = readMatchMoney(matchRuntime)
			report.gameplay.money = money
			report.gameplay.moneySource = moneySource
			local active = activeDesiredUnits()
			local gatesMet = placementTargetsMet(active)
			local farmerReserve = gatesMet and nextFarmerUpgradeReserve(active) or 0
			local placementBudget = money
			if gatesMet and money then placementBudget = math.max(0, money - farmerReserve) end
			local placementSlot, placementUnit, waitingSlot, waitingUnit, placementPhase, placementTargetCount, placementCounts = choosePlacement(active, placementBudget)
			local upgradeTarget, upgradeUUID, upgradeUnit, upgradeCost, upgradeReason
			if Settings.upgradeEnabled == true and money and gatesMet then
				upgradeTarget, upgradeUUID, upgradeUnit, upgradeCost, upgradeReason = chooseUpgrade(active, money)
			end
			local acted = false

			local function performPlacement()
				local placementPolicy = placementPhase == "remaining-damage"
					and not placementUnit.giveMoney
					and placementCounts.damage + 1 >= damageForwardPlacementStart
					and "spawn-forward" or "cluster"
				local requiredAvailable
				if placementPolicy == "spawn-forward" then
					requiredAvailable = math.max(1, placementCounts.damageCapacity - placementCounts.damage)
				else
					local initialRemaining = math.max(0,
						math.min(initialDamagePlacements, placementCounts.damageCapacity) - placementCounts.damage)
					local farmerRemaining = math.max(0,
						math.min(targetFarmerPlacements, placementCounts.farmerCapacity) - placementCounts.farmer)
					requiredAvailable = math.max(1, initialRemaining + farmerRemaining)
				end
				local spawnPosition, spawnSource
				if placementPolicy == "spawn-forward" then
					spawnPosition, spawnSource = resolveMonsterSpawnEvidence()
				end
				log("PLAN", string.format("%s selected for immediate placement from %s candidates.", tostring(placementUnit.displayName), tostring(placementPhase)), {
					slot = placementSlot,
					money = money,
					placementBudget = placementBudget,
					farmerReserve = farmerReserve,
					cost = placementUnit.cost,
					dps = placementUnit.dps,
					targetInstance = placementTargetCount,
					damagePlaced = placementCounts.damage,
					farmerPlaced = placementCounts.farmer,
					damageCapacity = placementCounts.damageCapacity,
					placementPolicy = placementPolicy,
					spawnPosition = simpleRemoteValue(spawnPosition),
					spawnSource = spawnSource,
					requiredAvailable = requiredAvailable,
				})
				local verified, _, _, reason = placeUnit(
					towerFunction,
					observer,
					matchRuntime,
					placementUnit,
					placementSlot,
					placementTargetCount,
					placementPolicy,
					spawnPosition,
					spawnSource,
					requiredAvailable
				)
				if verified then
					placementBlockedUntil = 0
				else
					-- A full rejected grid pass yields to upgrades for a short window. This
					-- prevents bad geometry from starving every upgrade action indefinitely.
					placementBlockedUntil = os.clock() + (tonumber(Settings.placementFailureYield) or 3)
					log("WAIT", "Placement yielded to upgrades after rejection: " .. tostring(reason))
				end
				return true
			end

			local initialPlacementRequired = placementPhase == "core-damage" or placementPhase == "farmer"
			local placementAllowed = Settings.placementEnabled == true and placementUnit
				and os.clock() >= placementBlockedUntil

			if initialPlacementRequired and placementAllowed then
				-- The initial 3 damage + 3 Leorio gate must be physically established
				-- before any upgrade spending begins.
				acted = performPlacement()
			elseif upgradeTarget and upgradeReason == "farmer-priority" then
				-- Once all six initial placements exist, every affordable Leorio upgrade
				-- outranks forward damage placement.
				upgradeTower(towerFunction, observer, matchRuntime, upgradeTarget, upgradeUUID, upgradeUnit, money, moneySource)
				acted = true
				log("PRIORITY", "Affordable Leorio upgrade selected before remaining placement.", {
					cost = upgradeCost,
					farmerReserve = farmerReserve,
				})
			elseif placementAllowed then
				-- Damage number four and later spend only money above the next farmer
				-- reserve, and use the independent forward square grid.
				acted = performPlacement()
			elseif upgradeTarget then
				-- Damage upgrades run only when no higher-priority placement can proceed,
				-- including the short yield after all candidate coordinates are rejected.
				upgradeTower(towerFunction, observer, matchRuntime, upgradeTarget, upgradeUUID, upgradeUnit, money, moneySource)
				acted = true
				log("PRIORITY", "Upgrade budget selected by " .. tostring(upgradeReason) .. ".")
			end

			if acted then
				nextActionAt = os.clock() + (tonumber(Settings.actionRetryDelay) or 1)
			elseif os.clock() - lastWaitLogAt >= 5 then
				lastWaitLogAt = os.clock()
				log("WAIT", "No verified action is affordable yet.", {
					money = money,
					moneySource = moneySource,
					placementBudget = placementBudget,
					farmerReserve = farmerReserve,
					placementBlockedFor = math.max(0, placementBlockedUntil - os.clock()),
					placementPhase = placementPhase,
					waitingSlot = waitingSlot,
					waitingCost = waitingUnit and waitingUnit.cost or nil,
					damagePlaced = placementCounts and placementCounts.damage or nil,
					farmerPlaced = placementCounts and placementCounts.farmer or nil,
					damageCapacity = placementCounts and placementCounts.damageCapacity or nil,
					initialDamageGate = initialDamagePlacements,
					targetFarmer = targetFarmerPlacements,
				}, false)
				saveReport("Waiting for an affordable verified action")
			end
		end

		task.wait(tonumber(Settings.gameplayLoopInterval) or 0.2)
	end

	disconnectAll(connections)
	report.lifecycle.monitoring = false
	report.status = "STOPPED"
	log("STOP", "AutoPlay lifecycle monitor stopped.")
	saveReport("Stopped by user")
	return report
end

local ok, result = xpcall(run, function(message)
	return debug and debug.traceback and debug.traceback(tostring(message), 2) or tostring(message)
end)
if environment.AnimeOriginAutoPlayRunning == runToken then
	environment.AnimeOriginAutoPlayRunning = nil
end
if not ok then
	if report.status ~= "FAILED" then
		report.status = "FAILED"
		report.error = result
		saveReport("Unhandled error")
	end
	error(result, 0)
end

environment.AnimeOriginAutoPlayReport = result
return result
