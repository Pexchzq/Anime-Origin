--[[
	Anime Origin confirmed data-path registry

	This file documents only paths verified from live Anime Origin evidence.
	It does not read data, invoke remotes, click UI, or depend on Anime SQ paths.
	Dynamic player names and UUIDs are represented with descriptive placeholders.
]]

local DataPaths = {
	-- Canonical automation sources. These are runtime tables and do not require
	-- opening HUD, Profile, or Units screens. A resolver must rediscover the
	-- containing callback/getgc table each session because getgc indices drift.
	--
	-- RESOLVER CONTRACT, learned the hard way: getgc(true) exposes at least three
	-- things that all satisfy a naive PlayerData shape test --
	--
	--   1. the WRAPPER: a table with a .PlayerData field. Only this one keeps
	--      receiving server writes. Always prefer it.
	--   2. the inner PlayerData table itself.
	--   3. detached warm-up copies made before the account finished loading.
	--
	-- Binding (2) or (3) is silent and total: every claim, redeem and summon still
	-- reports "no state change" while the server is actually crediting the account,
	-- because the bound table is simply not the one being written to. A resolver
	-- must scan the WHOLE snapshot and prefer a wrapper before settling for a bare
	-- table, and must re-scan on every verification rather than trusting the table
	-- it bound at attach time. See Config.fastGems.bootstrap.wrapperGraceTimeout.
	runtime = {
		-- Root client state containing Currency, Towers, account progression, etc.
		-- <RuntimeResolver> is the wrapper described in the resolver contract above.
		playerData = "<RuntimeResolver>.PlayerData",
		gems = "<RuntimeResolver>.PlayerData.Inventory.Currency.Gems",
		-- Confirmed internal currency key for the inventory item's displayed
		-- "Trait Reroll" count; this is available without opening the Items UI.
		traitReroll = "<RuntimeResolver>.PlayerData.Inventory.Currency.TraitReroll",
		towers = "<RuntimeResolver>.PlayerData.Inventory.Towers",
		towerRecord = "<RuntimeResolver>.PlayerData.Inventory.Towers[<UUID>]",

		-- Confirmed by OriginBootstrapStateProbe without opening Profile. This is the
		-- authoritative new-account gate; a Standard ten-pull increases it by 10.
		profileData = "<RuntimeResolver>.PlayerData.ProfileData",
		totalSummons = "<RuntimeResolver>.PlayerData.ProfileData.TotalSummons",

		-- MainFlowStateProbe verified that account level is not stored as a rendered
		-- level scalar. PlayerData.Exp is the authoritative cumulative EXP and the
		-- game's pure CalculateStuff formula returned level 13 for EXP 3785.
		accountExp = "<RuntimeResolver>.PlayerData.Exp",
		accountLevel = "<CalculateStuff>.GetPlayerLevelFromExp(<RuntimeResolver>.PlayerData.Exp)",

		-- WestCity progression is server-fed PlayerData and is available in the lobby
		-- without opening the Story screen. Clears counts Normal completions while
		-- HardClears counts Hard completions; do not use Claimed as the difficulty gate.
		storyProgressWestCity = "<RuntimeResolver>.PlayerData.StoryProgress.WestCity",
		storyActRecord = "<RuntimeResolver>.PlayerData.StoryProgress.WestCity[<ACT_AS_STRING>]",
		storyNormalClears = "<RuntimeResolver>.PlayerData.StoryProgress.WestCity[<ACT_AS_STRING>].Clears",
		storyHardClears = "<RuntimeResolver>.PlayerData.StoryProgress.WestCity[<ACT_AS_STRING>].HardClears",
		storyNormalFastestClear = "<RuntimeResolver>.PlayerData.StoryProgress.WestCity[<ACT_AS_STRING>].FastestClear",
		storyHardFastestClear = "<RuntimeResolver>.PlayerData.StoryProgress.WestCity[<ACT_AS_STRING>].HardFastestClear",
		infiniteProgressWestCity = "<RuntimeResolver>.PlayerData.InfiniteProgress.WestCity",
		infiniteHighestWave = "<RuntimeResolver>.PlayerData.InfiniteProgress.WestCity.HighestWave",
		-- Confirmed bootstrap claim-state branches. Production still needs the
		-- matching reward-definition thresholds before deciding claim availability.
		redeemedCodes = "<RuntimeResolver>.PlayerData.RedeemedCodes",
		dailyRewards = "<RuntimeResolver>.PlayerData.DailyRewards",
		dailyRewardLastClaimTime = "<RuntimeResolver>.PlayerData.DailyRewards.LastClaimTime",
		dailyRewardCurrentDay = "<RuntimeResolver>.PlayerData.DailyRewards.CurrentDay",
		dailyWheelLastClaimTime = "<RuntimeResolver>.PlayerData.DailyRewards.DailySpinLastClaimTime",
		playTimeRewards = "<RuntimeResolver>.PlayerData.PlayTimeRewards",
		playTime = "<RuntimeResolver>.PlayerData.PlayTimeRewards.PlayTime",
		playTimeRewardsClaimed = "<RuntimeResolver>.PlayerData.PlayTimeRewards.Claimed",
		battlepasses = "<RuntimeResolver>.PlayerData.Battlepasses",
		battlepassSeasonClaimed = "<RuntimeResolver>.PlayerData.Battlepasses.Season1.Claimed",
		battlepassSeasonPremiumClaimed = "<RuntimeResolver>.PlayerData.Battlepasses.Season1.PremiumClaimed",
		-- Confirmed without opening Quests. FastMode recursively counts only records
		-- whose Claimable flag is true and verifies that count after ClaimAllQuests.
		quests = "<RuntimeResolver>.PlayerData.Quests",
		questClaimable = "<RuntimeResolver>.PlayerData.Quests[<CATEGORY>][<QUEST>].Claimable",
		questClaimed = "<RuntimeResolver>.PlayerData.Quests[<CATEGORY>][<QUEST>].Claimed",
		-- Confirmed in PlayerData from UnitProgressionProbe_latest.json. Missing rarity
		-- keys inside an existing banner table represent disabled Auto Sell state.
		autoSell = "<RuntimeResolver>.PlayerData.AutoSell",
		autoSellRarity = "<RuntimeResolver>.PlayerData.AutoSell[<BANNER>][<RARITY>]",
		-- OriginBootstrapStateProbe V2 also found the non-UI reward-definition keys
		-- PlayTimeRewards, DailyRewards, UpgradedDailyRewards and DailyWheelRewards in
		-- loaded getgc tables. Their getgc indices drift, so production uses the stable
		-- PlayerData claim branches above as post-remote evidence instead of fixing an
		-- index or reading a rendered reward card.

		-- Owned records contain an internal Name such as Itachi or GokuSSJ.
		ownedUnitIdentifier = "<RuntimeResolver>.PlayerData.Inventory.Towers[<UUID>].Name",

		-- Confirmed per-owned-copy stat grades. These multipliers distinguish two
		-- UUIDs of the same internal unit and are applied after base/max stats.
		ownedUnitGrades = "<RuntimeResolver>.PlayerData.Inventory.Towers[<UUID>].Grades",
		ownedDamageMultiplier = "<RuntimeResolver>.PlayerData.Inventory.Towers[<UUID>].Grades.DamageMultiplier",
		ownedCooldownMultiplier = "<RuntimeResolver>.PlayerData.Inventory.Towers[<UUID>].Grades.CooldownMultiplier",
		ownedRangeMultiplier = "<RuntimeResolver>.PlayerData.Inventory.Towers[<UUID>].Grades.RangeMultiplier",
		ownedTrait = "<RuntimeResolver>.PlayerData.Inventory.Towers[<UUID>].Trait",
		-- Confirmed against the live Goju UI at max upgrade:
		-- final Damage = StageStats[max].Damage * DamageMultiplier
		-- final Cooldown = StageStats[max].Cooldown * CooldownMultiplier
		-- final Range = StageStats[max].Range * RangeMultiplier
		-- DPS = final Damage / final Cooldown. Trait effects remain separate until a
		-- runtime formula is verified and must not be guessed here.

		-- Join the owned internal Name to the definition-table key. The resulting
		-- definition contains display Name and Rarity without selecting a UI card.
		unitDefinition = "<UnitDefinitions>[PlayerData.Inventory.Towers[<UUID>].Name]",
		unitRarity = "<UnitDefinitions>[PlayerData.Inventory.Towers[<UUID>].Name].Rarity",
		unitDisplayName = "<UnitDefinitions>[PlayerData.Inventory.Towers[<UUID>].Name].DisplayName",

		-- UnitProgressionProbe V4 decompiled the official formulas and callbacks.
		-- Level is derived from stored EXP plus the definition rarity; it is not a
		-- stable scalar on the owned record.
		ownedUnitExp = "<RuntimeResolver>.PlayerData.Inventory.Towers[<UUID>].Exp",
		ownedUnitLocked = "<RuntimeResolver>.PlayerData.Inventory.Towers[<UUID>].Locked",
		unitLevel = "<CalculateStuff>.GetTowerLevelFromExp(<OWNED_EXP>, <DEFINITION_RARITY>)",
		unitMaxLevel = "<CalculateStuff>.MaxTowerLevel", -- Confirmed value: 70.
		unitMaxLevelExp = "<CalculateStuff>.NeededTowerLevelExp(<MAX_LEVEL>, <DEFINITION_RARITY>)",
		foodInventory = "<RuntimeResolver>.PlayerData.Inventory.Food",
		foodCount = "<RuntimeResolver>.PlayerData.Inventory.Food[<INTERNAL_FOOD_NAME>]",
		foodExp = "<ItemInfo>.Food[<INTERNAL_FOOD_NAME>].Exp",
		gold = "<RuntimeResolver>.PlayerData.Inventory.Currency.Gold",
		goldShopState = "<RuntimeResolver>.PlayerData.Shops.GoldShop",
		goldShopSeed = "<RuntimeResolver>.PlayerData.Shops.GoldShop.Seed",
		goldShopBoughtItems = "<RuntimeResolver>.PlayerData.Shops.GoldShop.BoughtItems",
		-- The game's GoldShop callback reads this server endpoint before building UI.
		-- It works without opening the shop and returns dynamic ShopItems/indexes.
		activeGoldShopCatalog = "LobbyRemotes.ShopFunction:InvokeServer('GetCurrentGoldShopRotation')",

		-- Confirmed max-upgrade combat source. StageStats is keyed by the server's
		-- stage number; its highest numeric key is the unit's final upgrade. For
		-- example, keys 1..6 correspond to the UI positions 0/5..5/5.
		unitStageStats = "<UnitDefinitions>[PlayerData.Inventory.Towers[<UUID>].Name].StageStats",
		unitStage = "<UnitDefinitions>[PlayerData.Inventory.Towers[<UUID>].Name].StageStats[<STAGE_NUMBER>]",
		unitStageDamage = "<UnitDefinitions>[PlayerData.Inventory.Towers[<UUID>].Name].StageStats[<STAGE_NUMBER>].Damage",
		unitStageCooldown = "<UnitDefinitions>[PlayerData.Inventory.Towers[<UUID>].Name].StageStats[<STAGE_NUMBER>].Cooldown",
		unitStageRange = "<UnitDefinitions>[PlayerData.Inventory.Towers[<UUID>].Name].StageStats[<STAGE_NUMBER>].Range",
		unitStageCost = "<UnitDefinitions>[PlayerData.Inventory.Towers[<UUID>].Name].StageStats[<STAGE_NUMBER>].Cost",
		-- Raw StageStats omit owned-copy level, Trait, Shiny, Stars and account
		-- multipliers. AutoPlay/UnitProgression must call these live functions with
		-- the inventory record and maximum stage to match the inventory's numbers.
		unitExactDamage = "<CalculateStuff>.Damage(PlayerData.Inventory.Towers[<UUID>], <MAX_STAGE>)",
		unitExactCooldown = "<CalculateStuff>.Cooldown(PlayerData.Inventory.Towers[<UUID>], <MAX_STAGE>)",
		unitExactRange = "<CalculateStuff>.Range(PlayerData.Inventory.Towers[<UUID>], <MAX_STAGE>)",

		-- Farm units are intentionally not DPS units. MoneyUnit=true and/or the Farm
		-- element identifies them; their StageStats use GiveMoney and Cooldown="Wave".
		unitIsMoneyUnit = "<UnitDefinitions>[PlayerData.Inventory.Towers[<UUID>].Name].MoneyUnit",
		unitElements = "<UnitDefinitions>[PlayerData.Inventory.Towers[<UUID>].Name].Elements",
		unitStageGiveMoney = "<UnitDefinitions>[PlayerData.Inventory.Towers[<UUID>].Name].StageStats[<STAGE_NUMBER>].GiveMoney",

		-- Confirmed non-UI game-speed evidence. ChangeSpeed("Two") changed this
		-- replicated NumberValue from 1 to 1.4; "Two" is a level name, not multiplier 2.
		gameSpeedMultiplier = "ReplicatedStorage.Constants.GameSpeed.Value",

		-- The focused in-game scan found one structural match-runtime table. Its
		-- getgc index changes each session, so production must resolve the table by
		-- the simultaneous presence of GameStarted, TowerDict, TowerNPCDict and
		-- PathPositions. TowerDict/TowerNPCDict were empty before match start; their
		-- The no-hook V3 capture confirmed TowerDict entries from CreateNewTower and
		-- later UpdateTower patches. Each entry includes UUID, TowerInventoryUUID,
		-- TeamSlot, Stage, StageStats, Position and current combat stats.
		matchRuntime = "<RuntimeResolver table with GameStarted, TowerDict, TowerNPCDict, PathPositions>",
		gameStarted = "<MatchRuntime>.GameStarted",
		-- MainFlowStateProbe captured these server-to-client messages directly from
		-- ActRemoteEvent. UpdateClientGame is authoritative stage identity; ActOver
		-- is the end result and carries Success=true/false plus the same identity.
		matchStateRemote = "ReplicatedStorage.LobbyRemotes.ActRemoteEvent.OnClientEvent",
		currentStageSignal = "ActRemoteEvent.OnClientEvent('UpdateClientGame', <STAGE_DATA>)",
		currentStageWorld = "<STAGE_DATA>.WorldName",
		currentStageMode = "<STAGE_DATA>.GameMode",
		currentStageAct = "<STAGE_DATA>.Act",
		currentStageDifficulty = "<STAGE_DATA>.Difficulty",
		currentStageTotalWaves = "<STAGE_DATA>.ActInfo.TotalWaves",
		matchEndSignal = "ActRemoteEvent.OnClientEvent('ActOver', <RESULT_DATA>)",
		matchSucceeded = "<RESULT_DATA>.Success",
		matchCompletedWaves = "<RESULT_DATA>.PlayerStats.WavesCompleted",
		-- Current Wave is announced by a non-UI server event as text such as
		-- 'Wave 20'. Production parses only the anchored /^Wave (%d+)$/ form so the
		-- separate 'Wave Completed' notification cannot be mistaken for a number.
		waveSignal = "ReplicatedStorage.Remotes.Notification.OnClientEvent('Notification', 'Wave <N>', nil, nil)",
		placedTowerRegistryCandidate = "<MatchRuntime>.TowerDict",
		placedTowerNPCRegistryCandidate = "<MatchRuntime>.TowerNPCDict",
		placedTowerUUID = "<MatchRuntime>.TowerDict[<PLACED_UUID>].UUID",
		placedTowerInventoryUUID = "<MatchRuntime>.TowerDict[<PLACED_UUID>].TowerInventoryUUID",
		placedTowerSlot = "<MatchRuntime>.TowerDict[<PLACED_UUID>].TeamSlot",
		placedTowerStage = "<MatchRuntime>.TowerDict[<PLACED_UUID>].Stage",
		placedTowerStageStats = "<MatchRuntime>.TowerDict[<PLACED_UUID>].TowerInfo.StageStats",
		-- Workspace scene folders are match-local truth. AutoPlay uses Towers to
		-- reject stale UUIDs from prior matches and Enemies to avoid live path occupancy.
		workspaceTowers = "workspace.Towers",
		workspaceEnemies = "workspace.Enemies",
		workspacePathModel = "workspace.Path.Model",
		-- AutoPlay confirms spawn direction by sampling the first replicated enemy
		-- and selecting the nearer ordered PathPositions endpoint. This avoids fixed
		-- coordinates and does not depend on the visible world "Start" marker.
		monsterSpawnEndpoint = "nearest(<workspace.Enemies first sample>, <MatchRuntime>.PathPositions endpoints)",
		-- Placement geometry uses two user-editable 2.2-stud square grids from
		-- Config.autoPlay.placementRegions[world].Ground. The final false argument
		-- came from a successful forward PlaceTower capture.
		mainPlacementCenter = "Vector3.new(-543.1865844726562, 126.51518249511719, -797.84228515625)",
		forwardPlacementCenter = "Vector3.new(-542.35791015625, 126.51518249511719, -783.6130981445312)",
		placeTowerFinalBoolean = false,
		-- PlaceTower/UpgradeTower callbacks compare against PlayerData:GetAttribute
		-- ("Money"). AutoPlay tests MatchRuntime.PlayerData and LocalPlayer, then
		-- records the exact successful source in its report instead of fixing one.
		matchMoney = "<Runtime PlayerData Instance>:GetAttribute(\"Money\")",
		-- PathPositions describes the enemy route and must not be mistaken for the
		-- user-configured tower placement region.
		enemyPathPositions = "<MatchRuntime>.PathPositions",
		reversedEnemyPathPositions = "<MatchRuntime>.ReversedPathPositions",

		-- Confirmed live loadout. Tower1, Tower2, ... contain equipped UUIDs;
		-- a missing/nil value within the unlocked range is an empty slot.
		equippedTowers = "<RuntimeResolver>.PlayerData.EquippedTowers",
		equippedSlot = "<RuntimeResolver>.PlayerData.EquippedTowers.Tower<SLOT_NUMBER>",
		-- Observed value was 100 while the team UI had only six positions. This is
		-- inventory capacity and must not be used to determine unlocked team slots.
		towerInventoryCapacity = "<RuntimeResolver>.PlayerData.MaxTowerSlot",
	},

	-- UI paths below remain documented as diagnostic evidence only. Production
	-- automation must not use them as its source of truth.
	player = {
		-- Current gem amount displayed by the permanent HUD currency counter.
		gemsText = "Players.LocalPlayer.PlayerGui.MainUI.HUD.BottomUI.Currencies.Gems.Inner.Amount.Text",

		-- Account level and XP text, for example: Lvl 9 (74/364 XP).
		accountLevelText = "Players.LocalPlayer.PlayerGui.MainUI.Misc.ProfileFrame.Main.ContentFrame.Bottom.Stats.XPBar.TextLabel.Text",
	},

	inventory = {
		-- Container holding the rendered inventory cards. Each live card is named by UUID.
		cards = "Players.LocalPlayer.PlayerGui.MainUI.TowerInventoryFolder.TowerInventoryFrame.Main.ContentFrame.CanvasGroup.ScrollingFrame",

		-- Replace <UUID> with the card name. This UUID is accepted by EquipTower.
		card = "Players.LocalPlayer.PlayerGui.MainUI.TowerInventoryFolder.TowerInventoryFrame.Main.ContentFrame.CanvasGroup.ScrollingFrame.<UUID>",

		-- User-facing unit name shown on an inventory card, for example Choto or Itaki.
		cardNameText = "Players.LocalPlayer.PlayerGui.MainUI.TowerInventoryFolder.TowerInventoryFrame.Main.ContentFrame.CanvasGroup.ScrollingFrame.<UUID>.ImageLabel.Info.NameLabel.Text",

		-- Current unit level shown on an inventory card, for example 15.
		cardLevelText = "Players.LocalPlayer.PlayerGui.MainUI.TowerInventoryFolder.TowerInventoryFrame.Main.ContentFrame.CanvasGroup.ScrollingFrame.<UUID>.ImageLabel.Info.Level.Text",

		-- Live owned-unit records found in a loaded UI callback upvalue.
		-- The callback location is evidence, not a stable API; probes must rediscover it.
		liveTowersTable = "<LiveCallbackUpvalue>.PlayerData.Inventory.Towers",

		-- Owned-unit record selected by the same UUID used as the inventory card name.
		liveTowerRecord = "<LiveCallbackUpvalue>.PlayerData.Inventory.Towers[<UUID>]",
	},

	rarity = {
		-- Diagnostic-only selected-unit label; requires a user-selected unit and
		-- therefore must never be used by unattended automation.
		selectedUnitRarityText = "Players.LocalPlayer.PlayerGui.MainUI.TowerInventoryFolder.TowerInventoryFrame.Main.ContentFrame.ViewFrame.Inner.InfoFrame.NameInfo.Main.Rarity.TextLabel.Text",
	},
}

return DataPaths
