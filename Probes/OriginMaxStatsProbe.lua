--[[
	Anime Origin max-upgrade stats probe (read-only)

	Purpose:
	  1. Resolve PlayerData and owned UUID records without opening Unit Manager.
	  2. Find runtime definition tables keyed by each owned internal unit name.
	  3. Locate Damage/Cooldown/Range triplets at every upgrade level.
	  4. Select the last/max upgrade, apply the owned UUID Grade multipliers,
	     and calculate DPS = Damage / Cooldown.

	This probe never changes a slider, invokes a remote, equips a unit, or starts
	a match. Trait and account/unit-level formulas are reported but not guessed.

	Output: AnimeOrigin_MaxStatsProbe.json in the executor workspace.
]]

local HttpService = game:GetService("HttpService")

local outputFile = "AnimeOrigin_MaxStatsProbe.json"
local MAX_CANDIDATES_PER_IDENTIFIER = 20
local MAX_STAT_DEPTH = 12

local function isPlayerData(value)
	if typeof(value) ~= "table" then return false end
	local inventory = rawget(value, "Inventory")
	return typeof(inventory) == "table"
		and typeof(rawget(inventory, "Towers")) == "table"
		and typeof(rawget(inventory, "Currency")) == "table"
end

local function safeCopy(value, depth, visited)
	depth = depth or 0
	visited = visited or {}
	local kind = typeof(value)
	if kind == "nil" or kind == "string" or kind == "number" or kind == "boolean" then return value end
	if kind ~= "table" then return "<" .. kind .. ">" end
	if visited[value] then return "<circular>" end
	if depth >= 5 then return "<max-depth>" end
	visited[value] = true
	local result, count = {}, 0
	for key, child in next, value do
		count += 1
		if count > 180 then result._truncated = true; break end
		result[tostring(key)] = safeCopy(child, depth + 1, visited)
	end
	visited[value] = nil
	return result
end

local function normalizeKey(key)
	return string.lower(tostring(key)):gsub("[^%w]", "")
end

local aliases = {
	damage = { damage = true, dmg = true, basedamage = true, attackdamage = true },
	cooldown = { cooldown = true, cd = true, spa = true, attackspeed = true, attackcooldown = true, attackdelay = true },
	range = { range = true, attackrange = true, baserange = true },
	cost = { cost = true, price = true, upgradecost = true, placementcost = true },
}

local function directNumberFields(value)
	local found = {}
	local fieldNames = {}
	for key, child in next, value do
		if typeof(child) == "number" then
			local normalized = normalizeKey(key)
			for category, names in pairs(aliases) do
				if names[normalized] and found[category] == nil then
					found[category] = child
					fieldNames[category] = tostring(key)
				end
			end
		end
	end
	return found, fieldNames
end

local function numericRank(value, pathRank)
	for _, key in ipairs({ "Upgrade", "UpgradeLevel", "UpgradeIndex", "Level", "Stage" }) do
		local rank = tonumber(rawget(value, key))
		if rank then return rank end
	end
	return pathRank
end

-- Collect only tables containing a complete direct stat triplet. This avoids
-- confusing owned Grade multipliers or unrelated DamageModifier tables with a
-- real upgrade row.
local function findStatRows(definition, rootPath)
	local rows = {}
	local visited = {}
	rootPath = rootPath or "<definition>"
	local function visit(value, path, depth, pathRank)
		if typeof(value) ~= "table" or visited[value] or depth > MAX_STAT_DEPTH then return end
		visited[value] = true

		local fields, fieldNames = directNumberFields(value)
		if fields.damage and fields.cooldown and fields.range and fields.cooldown > 0 then
			table.insert(rows, {
				path = path,
				upgradeRank = numericRank(value, pathRank),
				damage = fields.damage,
				cooldown = fields.cooldown,
				range = fields.range,
				cost = fields.cost,
				dps = fields.damage / fields.cooldown,
				fieldNames = fieldNames,
			})
		end

		local inspected = 0
		for key, child in next, value do
			inspected += 1
			if inspected > 2000 then break end
			if typeof(child) == "table" then
				-- Preserve the outer numeric index, which is normally the upgrade
				-- level; nested attack/projectile arrays must not replace that rank.
				local childRank = pathRank
				-- StageStats normally uses numeric keys, but tonumber also covers an
				-- executor copy that has converted those keys to numeric strings.
				if childRank == nil then childRank = tonumber(key) end
				visit(child, path .. "[" .. string.format("%q", tostring(key)) .. "]", depth + 1, childRank)
			end
		end
	end
	visit(definition, rootPath, 0, nil)
	return rows
end

local function getRankBounds(rows)
	local minimum, maximum
	for _, row in ipairs(rows) do
		local rank = tonumber(row.upgradeRank)
		if rank then
			minimum = minimum and math.min(minimum, rank) or rank
			maximum = maximum and math.max(maximum, rank) or rank
		end
	end
	return minimum, maximum
end

-- Money units such as Leorio intentionally have no Damage value and use the
-- string "Wave" for Cooldown. Their progression is GiveMoney per wave, so it
-- must be modeled separately instead of being reported as an unresolved damage
-- definition or accidentally included in the DPS ranking.
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

local function findFarmRows(stageStats)
	local rows = {}
	if typeof(stageStats) ~= "table" then return rows end
	for key, stage in next, stageStats do
		if typeof(stage) == "table" then
			local giveMoney = tonumber(rawget(stage, "GiveMoney"))
			if giveMoney then
				table.insert(rows, {
					path = "<definition>[\"StageStats\"][" .. string.format("%q", tostring(key)) .. "]",
					upgradeRank = numericRank(stage, tonumber(key)),
					giveMoney = giveMoney,
					cost = tonumber(rawget(stage, "Cost")),
					range = tonumber(rawget(stage, "Range")),
					cooldown = rawget(stage, "Cooldown"),
				})
			end
		end
	end
	return rows
end

local function chooseMaxFarmRow(rows)
	if #rows == 0 then return nil end
	table.sort(rows, function(left, right)
		local leftRank = tonumber(left.upgradeRank)
		local rightRank = tonumber(right.upgradeRank)
		if leftRank and rightRank and leftRank ~= rightRank then return leftRank > rightRank end
		if leftRank and not rightRank then return true end
		if rightRank and not leftRank then return false end
		if left.giveMoney ~= right.giveMoney then return left.giveMoney > right.giveMoney end
		return left.path < right.path
	end)
	return rows[1]
end

local function chooseMaxRow(rows)
	if #rows == 0 then return nil end
	table.sort(rows, function(left, right)
		local leftRank = tonumber(left.upgradeRank)
		local rightRank = tonumber(right.upgradeRank)
		if leftRank and rightRank and leftRank ~= rightRank then return leftRank > rightRank end
		if leftRank and not rightRank then return true end
		if rightRank and not leftRank then return false end
		-- Fallback for maps without numeric upgrade keys: max-upgrade rows normally
		-- have the largest DPS, then the largest range.
		if left.dps ~= right.dps then return left.dps > right.dps end
		if left.range ~= right.range then return left.range > right.range end
		return left.path < right.path
	end)
	return rows[1]
end

local gcObjects
if typeof(getgc) == "function" then
	local ok, objects = pcall(getgc, true)
	if ok and typeof(objects) == "table" then gcObjects = objects end
end
assert(gcObjects, "getgc(true) is unavailable or failed.")

local playerData, playerDataSource
for index, object in ipairs(gcObjects) do
	if typeof(object) == "table" then
		if isPlayerData(object) then
			playerData = object
			playerDataSource = "getgc[" .. index .. "]"
			break
		end
		local nested = rawget(object, "PlayerData")
		if isPlayerData(nested) then
			playerData = nested
			playerDataSource = "getgc[" .. index .. "].PlayerData"
			break
		end
	end
end
assert(playerData, "Runtime PlayerData was not found. Wait for stage loading and run again.")

local inventory = rawget(playerData, "Inventory")
local towers = rawget(inventory, "Towers")
local needed = {}
for _, record in next, towers do
	if typeof(record) == "table" and typeof(rawget(record, "Name")) == "string" then
		needed[rawget(record, "Name")] = true
	end
end

local candidatesByIdentifier = {}
local seenCandidateTables = setmetatable({}, { __mode = "k" })
local function addCandidate(identifier, definition, source)
	if typeof(definition) ~= "table" or seenCandidateTables[definition] then return nil end
	local candidates = candidatesByIdentifier[identifier]
	if not candidates then candidates = {}; candidatesByIdentifier[identifier] = candidates end
	if #candidates >= MAX_CANDIDATES_PER_IDENTIFIER then return nil end
	seenCandidateTables[definition] = true
	-- Live Anime Origin definitions expose combat progression under StageStats.
	-- Prefer that exact server-fed table so unrelated nested stat triplets cannot
	-- outrank the unit's real upgrade stages. Generic traversal remains a fallback
	-- for a future definition shape change.
	local stageStats = rawget(definition, "StageStats") or rawget(definition, "stageStats")
	local rows
	local farmRows = {}
	local statSource
	if typeof(stageStats) == "table" then
		if isFarmDefinition(definition) then
			rows = {}
			farmRows = findFarmRows(stageStats)
		else
			rows = findStatRows(stageStats, "<definition>[\"StageStats\"]")
		end
		statSource = "StageStats"
	else
		rows = findStatRows(definition)
		statSource = "definition-fallback"
	end
	local role = #farmRows > 0 and "farm" or "damage"
	local selectedRows = role == "farm" and farmRows or rows
	local minimumRank, maximumRank = getRankBounds(selectedRows)
	local candidate = {
		source = source,
		definition = definition,
		rarity = rawget(definition, "Rarity") or rawget(definition, "rarity"),
		displayName = rawget(definition, "DisplayName") or rawget(definition, "Name"),
		rows = rows,
		maxRow = chooseMaxRow(rows),
		farmRows = farmRows,
		farmMaxRow = chooseMaxFarmRow(farmRows),
		role = role,
		statSource = statSource,
		minimumStageRank = minimumRank,
		maximumStageRank = maximumRank,
	}
	table.insert(candidates, candidate)
	return candidate
end

-- Definition exports themselves were previously observed as getgc[index]
-- tables keyed directly by internal names (for example root["GokuSSJ"]).
for index, object in ipairs(gcObjects) do
	if typeof(object) == "table" then
		for identifier in pairs(needed) do
			local definition = rawget(object, identifier)
			if typeof(definition) == "table" then
				addCandidate(identifier, definition, "getgc[" .. index .. "][" .. string.format("%q", identifier) .. "]")
			end
		end
	end
end

-- Some modules keep definition maps only as function upvalues. Inspect those
-- tables read-only when the executor exposes debug.getupvalues; never call the
-- functions themselves.
local fallbackNeeded = {}
for identifier in pairs(needed) do
	local resolved = false
	for _, candidate in ipairs(candidatesByIdentifier[identifier] or {}) do
		if #candidate.rows > 0 or #candidate.farmRows > 0 then resolved = true; break end
	end
	if not resolved then fallbackNeeded[identifier] = true end
end

if next(fallbackNeeded) ~= nil and debug and typeof(debug.getupvalues) == "function" then
	for index, object in ipairs(gcObjects) do
		if next(fallbackNeeded) == nil then break end
		if typeof(object) == "function" then
			local ok, upvalues = pcall(debug.getupvalues, object)
			if ok and typeof(upvalues) == "table" then
				for upvalueIndex, upvalue in pairs(upvalues) do
					if typeof(upvalue) == "table" then
						for identifier in pairs(fallbackNeeded) do
							local definition = rawget(upvalue, identifier)
							if typeof(definition) == "table" then
								local candidate = addCandidate(identifier, definition, "getgc[" .. index .. "].upvalue[" .. tostring(upvalueIndex) .. "][" .. string.format("%q", identifier) .. "]")
								if candidate and (#candidate.rows > 0 or #candidate.farmRows > 0) then
									fallbackNeeded[identifier] = nil
								end
							end
						end
					end
				end
			end
		end
	end
end

local function candidateScore(candidate)
	local selectedRows = candidate.role == "farm" and candidate.farmRows or candidate.rows
	local selectedMax = candidate.role == "farm" and candidate.farmMaxRow or candidate.maxRow
	if not selectedMax then return -math.huge end
	local rankedRows = 0
	for _, row in ipairs(selectedRows) do
		if tonumber(row.upgradeRank) then rankedRows += 1 end
	end
	return (#selectedRows * 1000) + (rankedRows * 100) + (tonumber(selectedMax.upgradeRank) or 0)
end

local bestByIdentifier = {}
for identifier, candidates in pairs(candidatesByIdentifier) do
	table.sort(candidates, function(left, right) return candidateScore(left) > candidateScore(right) end)
	bestByIdentifier[identifier] = candidates[1]
end

local report = {
	version = 3,
	placeId = game.PlaceId,
	jobId = game.JobId,
	playerDataSource = playerDataSource,
	units = {},
	unresolvedIdentifiers = {},
}

for uuid, record in next, towers do
	if typeof(uuid) == "string" and typeof(record) == "table" then
		local identifier = rawget(record, "Name")
		local candidate = typeof(identifier) == "string" and bestByIdentifier[identifier] or nil
		local rawMax = candidate and candidate.maxRow or nil
		local rawFarmMax = candidate and candidate.farmMaxRow or nil
		local grades = rawget(record, "Grades")
		local damageMultiplier = typeof(grades) == "table" and tonumber(rawget(grades, "DamageMultiplier")) or 1
		local cooldownMultiplier = typeof(grades) == "table" and tonumber(rawget(grades, "CooldownMultiplier")) or 1
		local rangeMultiplier = typeof(grades) == "table" and tonumber(rawget(grades, "RangeMultiplier")) or 1
		local adjusted
		if rawMax and damageMultiplier and cooldownMultiplier and rangeMultiplier and cooldownMultiplier > 0 then
			adjusted = {
				damage = rawMax.damage * damageMultiplier,
				cooldown = rawMax.cooldown * cooldownMultiplier,
				range = rawMax.range * rangeMultiplier,
			}
			adjusted.dps = adjusted.damage / adjusted.cooldown
		end
		local farmAdjusted
		if rawFarmMax then
			farmAdjusted = {
				giveMoney = rawFarmMax.giveMoney,
				cost = rawFarmMax.cost,
				cooldown = rawFarmMax.cooldown,
				-- A farm unit's Grade range still belongs to that owned UUID;
				-- GiveMoney itself is server-defined and is not multiplied by grades.
				range = rawFarmMax.range and rangeMultiplier and (rawFarmMax.range * rangeMultiplier) or rawFarmMax.range,
			}
		end

		local unit = {
			uuid = uuid,
			identifier = identifier,
			trait = rawget(record, "Trait"),
			traitApplied = false,
			grades = safeCopy(grades),
			definitionSource = candidate and candidate.source or nil,
			definitionRarity = candidate and candidate.rarity or nil,
			displayName = candidate and candidate.displayName or nil,
			role = candidate and candidate.role or nil,
			moneyUnit = candidate and candidate.role == "farm" or false,
			statRowCount = candidate and (candidate.role == "farm" and #candidate.farmRows or #candidate.rows) or 0,
			statSource = candidate and candidate.statSource or nil,
			-- StageStats uses 1 for UI upgrade 0. Subtracting the minimum
			-- observed stage works for both 1-based and 0-based definitions.
			maxUpgradeLevel = candidate and candidate.minimumStageRank and candidate.maximumStageRank
				and (candidate.maximumStageRank - candidate.minimumStageRank) or nil,
			maxUpgrade = (rawMax or rawFarmMax) and safeCopy(rawMax or rawFarmMax) or nil,
			gradeAdjustedMax = adjusted,
			farmMax = farmAdjusted,
			candidateSources = {},
		}
		local candidates = typeof(identifier) == "string" and candidatesByIdentifier[identifier] or nil
		if candidates then
			for candidateIndex, value in ipairs(candidates) do
				local selectedRows = value.role == "farm" and value.farmRows or value.rows
				local selectedMax = value.role == "farm" and value.farmMaxRow or value.maxRow
				table.insert(unit.candidateSources, {
					source = value.source,
					role = value.role,
					rowCount = #selectedRows,
					statSource = value.statSource,
					minimumStageRank = value.minimumStageRank,
					maximumStageRank = value.maximumStageRank,
					maxRow = selectedMax and safeCopy(selectedMax) or nil,
					-- Keep a small raw preview only when no known stat triplet was
					-- found, so the next pass can learn the game's actual field names.
					preview = #selectedRows == 0 and candidateIndex <= 3 and safeCopy(value.definition) or nil,
				})
			end
		end
		table.insert(report.units, unit)
		if not adjusted and not farmAdjusted and typeof(identifier) == "string" then
			report.unresolvedIdentifiers[identifier] = true
		end
	end
end

table.sort(report.units, function(left, right)
	local leftDps = left.gradeAdjustedMax and left.gradeAdjustedMax.dps or -math.huge
	local rightDps = right.gradeAdjustedMax and right.gradeAdjustedMax.dps or -math.huge
	if leftDps ~= rightDps then return leftDps > rightDps end
	local leftRange = left.gradeAdjustedMax and left.gradeAdjustedMax.range or -math.huge
	local rightRange = right.gradeAdjustedMax and right.gradeAdjustedMax.range or -math.huge
	if leftRange ~= rightRange then return leftRange > rightRange end
	return left.uuid < right.uuid
end)

local unresolvedList = {}
for identifier in pairs(report.unresolvedIdentifiers) do table.insert(unresolvedList, identifier) end
table.sort(unresolvedList)
report.unresolvedIdentifiers = unresolvedList

getgenv().AnimeOriginMaxStatsProbe = report
print("[OriginMaxStats][SUMMARY] units=" .. #report.units .. " unresolvedIdentifiers=" .. #unresolvedList)
for index, unit in ipairs(report.units) do
	local stats = unit.gradeAdjustedMax
	if stats then
		print(string.format(
			"[OriginMaxStats][%d] %s | DPS=%.4f Damage=%.4f Cooldown=%.4f Range=%.4f | %s",
			index,
			tostring(unit.identifier),
			stats.dps,
			stats.damage,
			stats.cooldown,
			stats.range,
			unit.uuid
		))
	elseif unit.farmMax then
		print(string.format(
			"[OriginMaxStats][%d][FARM] %s | GiveMoney=%.4f Cooldown=%s Range=%.4f | %s",
			index,
			tostring(unit.identifier),
			unit.farmMax.giveMoney,
			tostring(unit.farmMax.cooldown),
			unit.farmMax.range or 0,
			unit.uuid
		))
	else
		print("[OriginMaxStats][UNRESOLVED] " .. tostring(unit.identifier) .. " | " .. unit.uuid)
	end
end

if typeof(writefile) == "function" then
	writefile(outputFile, HttpService:JSONEncode(report))
	print("[OriginMaxStats][FILE] " .. outputFile)
else
	warn("[OriginMaxStats] writefile is unavailable; report remains in getgenv().AnimeOriginMaxStatsProbe")
end

return report
