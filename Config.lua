--[[
	Anime Origin central configuration

	All user-editable values belong in this file. Feature scripts must read this
	table instead of duplicating fixed values in their implementation.
]]

local Config = {
	-- Keep the executor console as a compact live dashboard. Feature controllers
	-- still write their detailed reports/log files, but only logstats.lua may print
	-- normal status lines; thrown errors remain visible for diagnosis.
	console = {
		statusOnly = true,
	},

	-- Confirmed Roblox place identities let Auto-Execute controllers distinguish
	-- the lobby from an active stage without reading any UI hierarchy. Unknown
	-- future place IDs still fall back to bounded runtime discovery.
	runtimePlaces = {
		lobby = {
			[129932912185311] = true,
		},
		stage = {
			[116173040971120] = true,
			[135941552414666] = true,
		},
	},

	-- Read-only realtime account/stage observer. It uses the same non-UI runtime
	-- tables and server events as the controllers and never sends a remote.
	logStats = {
		enabled = true,
		pollInterval = 0.2,
		runtimeDiscoveryInterval = 0.5,
		dependencyGraceSeconds = 60,
		errorCooldown = 15,
	},

	fastGems = {
		-- FastMode is now only the new-account reward/summon bootstrap. Team
		-- selection belongs to AutoPlay, while map routing belongs to main.lua.
		enabled = true,
		debug = true,
		stateFolder = "AnimeOrigin",

		-- PlayerData.ProfileData.TotalSummons is the authoritative new-account gate.
		-- A write-ahead state file lets an interrupted run resume after its first
		-- ten-pull has already changed TotalSummons from 0 to 10.
		bootstrap = {
			-- ELIGIBILITY, decided once on the first run that ever sees the account and
			-- then persisted as accountClass. Only an account sitting at exactly this
			-- many TotalSummons is NEW; everything above it is a farming account whose
			-- Gems are never spent, no matter how many it accumulates later.
			--
			-- maximumSummonBatches below is the SPENDING CEILING, never an eligibility
			-- test. Treating "under 20 batches" as new would reclassify every farming
			-- account that has not yet reached 200 summons and drain it.
			newAccountTotalSummons = 0,
			expectedSummonsPerBatch = 10,
			-- Ceiling for one account's entire bootstrap: 20 x 10 = 200 summons.
			maximumSummonBatches = 20,
			-- UserIds listed here are re-classified as NEW even when TotalSummons is
			-- above the gate. Use it only to finish a bootstrap whose state file was
			-- lost; leaving an id here lets that account spend Gems on every run.
			forceBootstrapUserIds = {},
			summonBatchCost = 500,
			verifyTimeout = 10,
			-- Faster polling is safe because every mutation still requires PlayerData
			-- evidence before FastMode advances to its next phase.
			statePollInterval = 0.1,
			claimSettlementTimeout = 4,
			-- Auto-Execute begins before the lobby's live tables on slower joins.
			-- Refresh getgc during this window instead of failing on the first scan.
			runtimeLoadTimeout = 60,
			runtimeDiscoveryInterval = 0.5,
			-- getgc exposes both the PlayerData wrapper and its inner table, plus any
			-- detached warm-up copies. Only the wrapper keeps receiving server writes, so
			-- keep looking for it for this long before settling for a bare table; binding
			-- a dead copy makes every claim report "no state change" while the server is
			-- actually crediting the account.
			wrapperGraceTimeout = 10,
			-- When the gate is exactly zero, every current Gem may fund this bootstrap,
			-- even if that Gem did not come from a reward claimed in the same run.
			spendAllAvailableGems = true,
		},

		-- Every account may claim the sources below. TotalSummons controls only
		-- whether FastMode may continue into the summon bootstrap afterward.
		-- Server-owned PlayerData fields verify results; UI text is never consulted.
		claimRewards = {
			dailyReward = true,
			playTimeRewards = true,
			battlepass = true,
			dailyWheel = true,
			quests = true,
		},
		dailyRewardType = "Normal",
		playTimeRewardIndices = { 1, 2, 3, 4, 5, 6 },
		battlepassSeason = "Season1",

		-- RedeemedCodes is authoritative. A configured code already present there is
		-- skipped even when the local executor state file has been deleted.
		redeemCodes = {
			"100K!",
			"HappyPatch!",
			"ChallengesFixed",
			"GAMESPEED",
			"THANKYOU!",
			"TYKaito!",
			"AO",
			"Release!",
			"Origins",
		},
		-- The code endpoint rate-limits back-to-back requests.
		redeemRequestDelay = 3,
		redeemRetryDelay = 3,
		redeemMaxAttempts = 3,

		-- Standard ten-pull settings confirmed from the captured summon remote.
		summonBanner = "Standard",
		summonBatchSize = 10,
		-- Gems and TotalSummons already verify acceptance; this short settle window
		-- only gives newly-created inventory UUIDs time to replicate before locking.
		summonSettlementDelay = 0.25,

		-- AutoPlay still reads this stage identity to choose placement coordinates.
		-- main.lua updates these values after its server-backed route decision.
		stage = {
			mode = "Story",
			world = "WestCity",
			act = "1", -- MapSelectRemote expects Act as a string.
			difficulty = "Normal",
		},
	},

	-- main.lua owns only map progression and end-match transitions. FastMode keeps
	-- reward/summon bootstrap ownership, while AutoPlay keeps team/combat ownership.
	main = {
		enabled = true,
		debug = true,
		stateFolder = "AnimeOrigin",
		-- Route state is event-driven. A 0.2 second fallback is responsive without
		-- waking every account ten times per second while it is idle.
		statePollInterval = 0.2,
		remoteBindInterval = 1,
		-- Only used by executor builds without appendfile. The ring prevents the
		-- human-readable fallback log from retaining an entire multi-hour session.
		maximumRetainedLogLines = 300,
		-- Main's report can contain hundreds of events. Coalesce nonterminal JSON
		-- snapshots instead of re-encoding the whole report for every diagnostic line.
		reportFlushInterval = 2,
		runtimeLoadTimeout = 60,
		-- Returning from Act 6 can recreate the lobby UI/runtime tables after the
		-- portal and remotes already exist. Main keeps retrying this dedicated gate
		-- instead of treating the earlier context-ready signal as PlayerData-ready.
		lobbyPlayerDataTimeout = 120,
		-- A full getgc refresh is expensive; half-second discovery is fast enough to
		-- catch late PlayerData without scanning hundreds of thousands of objects at 10 Hz.
		runtimeDiscoveryInterval = 0.5,
		transitionVerifyTimeout = 12,
		-- Walking into a Story Pod is only how the game's own UI opens the map screen;
		-- the selection itself is MapSelectRemote "StartSelection", which main.lua fires
		-- either way. Ask the server directly first and keep the walk as the fallback.
		-- Acceptance proof is unchanged: a matching AfterMapSelect from the server.
		-- Set false to restore the walk-first order.
		preferDirectSelection = true,
		directSelectionTimeout = 5,
		transitionRetryDelay = 1,
		-- A Story row contains several Pod instances with identical names. A Pod can
		-- already contain another player or an active party, so main.lua rotates to
		-- another verified Pod instead of retrying the first DoorUIPart forever.
		maximumTransitionAttempts = 6,
		-- A route error used to end the session outright, because the Loader starts
		-- main.lua exactly once with task.spawn + pcall. Restart the route a bounded
		-- number of times instead; listeners are torn down and re-bound each time.
		maximumRouteRestarts = 3,
		routeRestartDelay = 5,
		-- A live match replicates a wave or lifecycle event every few seconds. When
		-- the server goes quiet the stage monitor used to keep writing heartbeats
		-- forever: one captured session sat at Wave 6 for eleven minutes with both
		-- Main and AutoPlay still reporting MONITORING. After this many seconds
		-- without any replicated event, main returns to the lobby through the normal
		-- verified transition so the route can restart. Set 0 to disable.
		stageStallTimeout = 180,
		-- A stall that survives repeated recoveries is an environment problem, not a
		-- transient one. Main stops re-teleporting after this many attempts and
		-- leaves a STALLED report for the diagnose_* tools instead of looping.
		maximumStallRecoveries = 3,
		-- Set true to print and persist the chosen route without moving the character
		-- or sending progression remotes. Normal operation requires false.
		dryRun = false,

		-- In a lobby, main.lua must not enter the Story portal while reward/summon
		-- bootstrap or persistent unit progression is still changing account state.
		-- Both worker files may be launched concurrently; UnitProgression waits for
		-- FastMode's final inventory, and main.lua waits for both terminal signals.
		bootstrapGate = {
			enabled = true,
			timeout = 300,
			requiredTasks = { "FastMode", "UnitProgression" },
			-- Both workers must finish before routing. Only FastMode is fatal because
			-- UnitProgression is optional account enrichment (fuse/shop/feed), not a
			-- prerequisite for selecting Story, Hard or Infinite.
			fatalTasks = {
				FastMode = true,
				UnitProgression = false,
			},
		},

		-- Roblox rejects stage entry when every equipped slot is empty. main.lua
		-- leaves an existing loadout untouched; only an entirely empty account gets
		-- one verified fallback unit from Inventory before Story portal selection.
		lobbyLoadoutGuard = {
			enabled = true,
			maximumCandidates = 10,
			equipVerifyTimeout = 5,
		},

		fastGemsRoute = {
			world = "WestCity",
			storyMode = "Story",
			normalDifficulty = "Normal",
			hardDifficulty = "Hard",
			firstNormalAct = 1,
			lastNormalAct = 6,
			levelFarmAct = "1",
			-- Infinite user settings: change these two values only when adjusting
			-- the account-level gate or the exact wave used to restart the run.
			minimumInfiniteLevel = 20, -- Enter Infinite when account level >= this value.
			infiniteAct = "Infinite",
			-- After a Normal clear, use the server's CanPlayNext flag. Act 6 and
			-- every level-threshold transition return to lobby for a fresh decision.
			useNextWhenAvailable = true,
			-- The anchored parser uses this exact numbered wave and never treats
			-- "Wave Completed" as a numbered-wave signal. Infinite enemies stream
			-- continuously, so main.lua restarts immediately at this configured wave.
			restartInfiniteAtWave = 15,
		},

		lobbyEntrance = {
			-- Scan every same-named Pod under the Story selector. portalPath remains as
			-- a compatibility fallback for a lobby build exposing only one Pod.
			portalRootPath = { "MainFolder", "Lobby", "MapSelectors", "Story" },
			portalDoorName = "DoorUIPart",
			portalPath = { "MainFolder", "Lobby", "MapSelectors", "Story", "Pod", "DoorUIPart" },
			outsideDistance = 10,
			insideDistance = 6,
			teleportSettleDelay = 0.2,
			walkTimeout = 3,
			-- Detect players inside each Pod before moving. If every Pod is occupied,
			-- remain where the character is and poll until one becomes free; never bounce
			-- through all door coordinates to discover occupancy.
			occupancyBoundsPadding = 1.5,
			occupancyPollInterval = 0.5,
			portalFailureCooldown = 5,
			portalRetryDelay = 0.35,
			occupiedPortalWaitTimeout = 20,
		},
	},

	-- Persistent account-unit progression is intentionally separate from AutoPlay.
	-- AutoPlay decides combat strength and match actions; UnitProgression will use
	-- the same max-stage DPS formula to choose long-term EXP recipients.
	unitProgression = {
		enabled = true,
		debug = true,
		stateFolder = "AnimeOrigin",
		-- V4 confirmed every payload and the first dry-run was audited successfully.
		-- Set true again whenever the game's inventory/shop schema changes.
		dryRun = false,
		statePollInterval = 0.1,
		verifyTimeout = 8,
		-- This file takes one getgc snapshot at attach time and turns any missing
		-- definition into a fatal error. The Loader starts it the instant the place
		-- teleport finishes, so that snapshot regularly predates the lobby's modules.
		-- Keep re-taking it until it is plausibly sized and actually carries the level
		-- formula and a PlayerData container.
		runtimeLoadTimeout = 60,
		runtimeDiscoveryInterval = 0.5,
		minimumGCSnapshotSize = 1000,
		-- Every request is already verified from PlayerData; this delay only yields
		-- briefly to replication instead of idling a third of a second per action.
		actionDelay = 0.05,
		maximumFuseRequestsPerRun = 60,
		maximumFeedRequestsPerRun = 120,
		primaryCohortSize = 3,
		maximumRankedTargets = 6,

		-- Level the lowest-progress member inside ranks 1-3 first. Only after all
		-- three are maxed does the planner move to ranks 4-6.
		balanceWithinCohort = true,

		-- Internal identifiers, not display names. Every newly-summoned matching UUID
		-- will be locked after authoritative inventory evidence confirms it exists.
		lockIdentifiers = {
			Leorio = true,
		},
		protectedIdentifiers = {
			Leorio = true,
		},

		-- Conservative defaults for disposable units. Higher rarities, Shiny units,
		-- equipped UUIDs, locked UUIDs and all six ranked targets are always protected
		-- independently of this allow-list.
		consumableRarities = {
			Rare = true,
			Epic = true,
		},
		preserveShiny = true,
		preserveEquipped = true,
		-- Rare/Epic are explicitly configured as progression material. Setting these
		-- two guards false allows even the last copy of a name or a copy with EXP to
		-- be fused. Top-six, equipped, locked, Shiny and configured identifiers such
		-- as Leorio remain independently protected and can never enter the payload.
		preserveBestCopyPerIdentifier = false,
		preserveUnitsWithExp = false,
		maximumFuseSourcesPerRequest = 24,
		fuseEnabled = true,
		feedFoodEnabled = true,
		lockConfiguredUnits = true,
		lockNewUnitsAfterSummon = true,

		shop = {
			enabled = true,
			name = "GoldShop",
			-- Gold Shop Food names and indexes rotate. When this is true, the
			-- progression controller buys every live ItemType="Food" entry that also
			-- exists in the game's Food EXP definitions; no Food name is hard-coded.
			buyEveryFoodInRotation = true,
			-- Used only when buyEveryFoodInRotation=false. Keys may use either the
			-- shop spelling or internal Food key because matching is normalized.
			foodAllowlist = {},
			-- Resolve the current catalog through ShopFunction first, then validate
			-- every rotating index against the server-returned ShopItems table.
			reserveGold = 0,
			maximumPurchasesPerRun = 100,
		},
	},

	-- Runtime settings are kept separate from AutoPlay. This section includes the
	-- lobby/cross-place Summon Auto Sell policy plus in-stage visual/gameplay values.
	-- Toggle-style remotes do not accept a boolean argument, so InGameSettings.lua
	-- compares every desired value with live PlayerData before firing anything.
	inGameSettings = {
		enabled = true,
		debug = true,
		stateFolder = "AnimeOrigin",
		statePollInterval = 0.2,
		verifyTimeout = 5,
		-- Settings remotes and authoritative PlayerData may appear well after the
		-- Auto-Execute thread starts, especially on the first lobby join.
		runtimeLoadTimeout = 60,
		runtimeDiscoveryInterval = 0.5,

		-- ToggleAutoSell has no explicit boolean argument. InGameSettings.lua reads
		-- PlayerData.AutoSell[banner][rarity] first, then fires only on a mismatch.
		-- Change Rare to false to disable it without risking an accidental inversion.
		autoSell = {
			Standard = {
				Rare = true,
			},
		},

		-- These names use a toggle-only SetSetting call. Change true to false when
		-- the future settings UI lets the user choose the opposite state.
		toggles = {
			AutoSkipWave = true,
			SkipSummonCutscene = true,
			SkipGameCutscene = true,
			SellFarms = true,
			HideVFX = true,
			WindowFocusTracking = true,
			HideOtherVFX = true,
			HideOtherPets = true,
			HideEnemyTag = true,
			SkipBossEntrance = true,
			HideDamageIndicator = true,
		},

		-- These SetSetting calls accept an explicit value and are naturally
		-- idempotent; the implementation still verifies the runtime value afterward.
		values = {
			GraphicsQuality = "Low",
			GraphicsQualityGame = "Low",
			EnemyMovement = "Optimized",
		},

		-- ChangeSpeed uses Remotes.RemoteEvent rather than SettingsRemote.
		gameSpeed = "Two",
		-- Confirmed runtime multiplier for the captured level name. The game labels
		-- this speed level "Two" while ReplicatedStorage.Constants.GameSpeed stores 1.4.
		gameSpeedRuntimeMultipliers = {
			Two = 1.4,
		},
		monitorGameSpeed = true,
		-- Direct replicated evidence is inexpensive, but one check per second is
		-- sufficient to catch a per-match reset without a permanent 2 Hz loop.
		gameSpeedMonitorInterval = 1,
	},

	-- AutoPlay owns team selection and the live match loop. Every placement and
	-- upgrade is accepted only after TowerHandlerRemote returns authoritative
	-- CreateNewTower/UpdateTower evidence; an InvokeServer return alone is not proof.
	autoPlay = {
		enabled = true,
		debug = true,
		stateFolder = "AnimeOrigin",
		-- Long multi-account sessions must not retain every diagnostic string and
		-- team action in Lua. Files still receive every line through appendfile;
		-- these limits bound only the in-memory fallback/report history.
		maximumRetainedLogLines = 300,
		maximumRetainedTeamActions = 300,
		statePollInterval = 0.2,
		verifyTimeout = 6,
		-- In a stage, refresh getgc until MatchRuntime exists. In the confirmed
		-- lobby place AutoPlay becomes idle immediately and waits for teleport.
		startupContextTimeout = 60,
		runtimeDiscoveryInterval = 0.5,
		maximumTeamSlots = 6,
		minimumDamageSlots = 3,
		-- Guarantee an affordable starter among the first three always-unlocked
		-- damage slots. AutoPlay still selects the highest-DPS eligible unit whose
		-- initial placement cost is at or below this user-editable ceiling.
		minimumLowCostDamageSlots = 1,
		maximumLowCostDamagePlacementCost = 600,
		-- Set false to build an all-damage loadout. Slot 4 then receives the next
		-- highest-DPS unit; farmer placement, money reserve and farmer upgrades are
		-- skipped automatically because no equipped farmer capacity exists.
		useFarmerUnit = false,
		-- This is the initial safety gate, not a placement cap. With the farmer
		-- enabled, three farmer instances follow; otherwise damage resumes immediately.
		initialDamagePlacements = 3,
		targetFarmerPlacements = 3,
		-- The first three damage instances protect the base. Damage number four and
		-- every later instance uses the independent square grid near the monster spawn;
		-- when enabled, the three Leorio placements occur before that transition.
		damageForwardPlacementStart = 4,
		farmerIdentifier = "Leorio",
		farmerPreferredSlot = 4,
		-- WestCity has no reliable ground location for Hill towers in this farm
		-- route. Exclude them before loadout construction and promote the next DPS
		-- candidate instead of equipping a unit AutoPlay cannot place.
		excludedPlacementTypes = {
			Hill = true,
		},
		-- Keep the controller alive across matches. Team mutation is gated by the
		-- authoritative StartWaveVote event, never by EndGame or a UI transition.
		autoReady = true,
		readyVerifyTimeout = 20,
		-- Replay/Next can expose StartWaveVote before the previous scene has removed
		-- workspace.Towers. Require two consecutive empty samples before readying;
		-- otherwise old server towers accumulate and later PlaceTower calls return -1.
		sceneCleanupStableSamples = 2,
		-- Some servers remove old towers only after accepting WaveVote. Give the normal
		-- pre-ready cleanup a short chance, then allow the vote but keep gameplay gated.
		sceneCleanupPreReadyGrace = 1.5,
		-- Once GameStarted changes to true, the scene must become empty within this
		-- bounded window or AutoPlay returns to the lobby without placing another tower.
		sceneCleanupTimeout = 5,
		placementEnabled = true,
		upgradeEnabled = true,
		-- Server evidence drives actions; a quarter-second fallback avoids a hot idle
		-- loop while still placing within one visible frame at the 10 FPS background cap.
		gameplayLoopInterval = 0.25,
		actionRetryDelay = 0.2,
		-- A false UpgradeTower response is authoritative for that placed UUID.
		-- Back it off instead of hammering the same stale/rejected target every frame.
		upgradeRejectionCooldown = 8,
		-- getgc(true) called while a place or act transition is tearing the Lua VM
		-- down returns an empty or near-empty table. That is a failed snapshot, not
		-- proof the game holds no data -- but an empty table still satisfies
		-- typeof(x) == "table", so it used to reach callers as fact. One captured run
		-- shows the cost precisely: 28 definition scans took 0.095-0.295s each, the
		-- 29th finished in 0.022s having found none of the ten owned units, and
		-- AutoPlay died for the remaining 49 minutes of the session. Reject a
		-- snapshot smaller than this and retry instead of believing it.
		minimumGCSnapshotSize = 1000,
		gcSnapshotAttempts = 6,
		gcSnapshotRetryDelay = 0.75,
		-- Rescan from a fresh snapshot before treating missing StageStats as a real
		-- content problem. A genuinely unknown unit stays unresolved after the
		-- rescan; a transition-window snapshot does not.
		definitionRetryDelay = 1,
		-- The Loader starts each controller exactly once with task.spawn+pcall, so a
		-- controller that errors is gone until the next teleport -- which is how a
		-- single transient failure cost a whole session. Restart the monitor this
		-- many times, disconnecting every listener first so restarts cannot stack.
		maximumMonitorRestarts = 5,
		monitorRestartDelay = 3,
		-- AutoPlay attaches shortly after StartWaveVote in normal use. Keep only a
		-- short event-listener settle period before deciding whether the vote is live.
		voteAttachSettleDelay = 0.15,
		-- StartWaveVote is delivered exactly once. An act transition that teleports to
		-- a new place restarts every controller, and the Loader must re-download each
		-- file over HTTP before AutoPlay can attach, so the event can already be gone
		-- by the time the listener exists. That parked a run on the unit-selection
		-- screen indefinitely with no error printed anywhere. After this many seconds
		-- of waiting with a stopped match and a verified empty scene, AutoPlay assumes
		-- the window opened before it attached and prepares the vote. Set 0 to disable
		-- and keep the old wait-forever behaviour.
		missedVoteRecoveryTimeout = 20,
		-- A locked optional slot is a normal server rejection. Keep this probe short
		-- so the next ready vote is not delayed by the full action verification timeout.
		slotProbeTimeout = 0.75,
		-- Temporary transition rejection must retry within the same pre-match vote;
		-- otherwise one missed mutation would disable every later match.
		teamPrepareRetryDelay = 0.5,
		-- Invalid geometry returns -1 immediately. Try enough distinct hologram
		-- candidates in one planner action instead of waiting six seconds per point.
		maxPlacementAttemptsPerAction = 12,
		placementPointRetryDelay = 10,
		-- If every candidate in one action is rejected, pause placement briefly so
		-- verified upgrades can run instead of being starved by geometry retries.
		placementFailureYield = 1,
		-- Square-grid cells and live occupancy checks use the user-confirmed 2.2-stud
		-- spacing. Pending points are reserved until server verification completes.
		minimumTowerSpacing = 2.2,

		-- AutoPlay expands two square grids dynamically. The main grid holds the first
		-- three damage units plus three Leorio units; the forward grid holds every
		-- damage placement from number four through each equipped unit's Limit.
		placementRegions = {
			WestCity = {
				Ground = {
					-- User-editable coordinates for this stage. mainCenter holds the
					-- first three damage units and three Leorio units. forwardCenter
					-- holds damage placement number four and every later instance.
					-- Add another world beside WestCity with the same structure when
					-- supporting a new stage; AutoPlay selects it from fastGems.stage.world.
					mainCenter = Vector3.new(-539.5164794921875, 129.64273071289062, -780.28070068359375),
					forwardCenter = Vector3.new(-539.5164794921875, 129.64273071289062, -780.28070068359375),
					gridSpacing = 2.2,
					-- Add a proportional spare-point margin, then continue adding square
					-- perimeter layers until enough non-path candidates exist.
					gridReserveRatio = 0.5,
					maximumGridLayers = 30,
					-- Padding is applied to the oriented BasePart bounds under
					-- workspace.Path.Model, not to approximate runtime path nodes.
					pathPadding = 0.15,
					-- Placement previews are diagnostics, not gameplay evidence. Keep them off
					-- during farming to avoid dozens of neon Parts and SelectionBoxes.
					showHolograms = false,
				},
			},
		},
	},

	-- Client-only optimizer. It changes no server data and keeps every path/remote
	-- used by the controllers. The two explicitly configured map-visual roots below
	-- are the only Workspace branches it is allowed to destroy locally.
	optimizer = {
		enabled = true,
		-- MultiAccount is Farm plus an adaptive foreground/background policy. A
		-- background Roblox client uses 10 FPS, disables 3D and suppresses PlayerGui;
		-- selecting that window restores the screen automatically for inspection.
		profile = "MultiAccount", -- Supported: Safe, Farm, MultiAccount, Headless.
		debug = true,
		batchInterval = 0.75,
		maximumBatchSize = 250,
		maximumStartupJitter = 2,
		-- False leaves Roblox/executor FPS control untouched; no foreground or
		-- background cap is applied by Optimizer.lua.
		lockFps = false,
		fpsCap = 30,
		foregroundFpsCap = 30,
		backgroundFpsCap = 10,
		adaptiveFocus = true,
		focusPolicyDelay = 12,
		-- Keep the world rendered while unfocused to prevent the white/blank screen.
		disable3DWhenUnfocused = false,
		-- Never disable complete ScreenGui trees. The game can change a HUD from
		-- disabled to enabled while Roblox is in the background; restoring an old
		-- boolean then hides the stage/wave HUD even after the window is focused.
		hidePlayerGuiWhenUnfocused = false,
		disableEffects = true,
		disablePostEffects = true,
		disableLights = true,
		disableShadows = true,
		muteSounds = true,
		hideOtherPlayers = true,
		hideMapTextures = true,
		hideCombatModels = true,
		-- Remove these exact direct children and every descendant to reduce map memory.
		-- workspace.Path, Towers and Enemies remain intact for routing and AutoPlay.
		destroyMapRoots = true,
		mapRootsToDestroy = {
			Map = true,
			MapTrash = true,
		},
		-- Multi-account sessions preload tens of thousands of hidden card images.
		-- Clear only assets under currently hidden GUI ancestry; visible stage/wave/
		-- currency HUD remains intact. Rejoin restores every image automatically.
		stripHiddenGuiImages = true,
		-- Spread property changes across telemetry passes to avoid a single-frame
		-- hitch when a lobby has more than twenty thousand hidden ImageLabels.
		maximumHiddenGuiImagesPerPass = 4000,
		-- End Screen, reward popups and their LocalScripts are part of the game's
		-- lifecycle. Never hide or destroy them: removing the visual root also removes
		-- callbacks that clear the previous match and can leave workspace.Towers stale.
		cleanupTransientUi = false,
		destroyTransientGuiClones = false,
		transientUiBaselineSeconds = 12,
		cleanupRepeatDelays = { 0, 0.5, 2 },
		-- The detector is intentionally bounded and overwrites one latest JSON file.
		-- It therefore diagnoses long-session growth without becoming another leak.
		leakTelemetry = true,
		leakSampleInterval = 15,
		maximumLeakSamples = 120,
		maximumLeakAlerts = 30,
		detailedSampleEvery = 4,
		leakMemoryAlertMb = 350,
		leakGuiAlertCount = 150,
		-- This means always-headless. MultiAccount instead disables 3D only while
		-- unfocused, after focusPolicyDelay, and restores it when selected.
		disable3DRendering = false,
	},
}

local environment = getgenv()

-- Preserve worker signals when Config.lua is re-run in the same server, but never
-- carry completion from an old JobId into a newly joined lobby or stage.
local lifecycle = environment.AnimeOriginLifecycle
if typeof(lifecycle) ~= "table" or lifecycle.jobId ~= game.JobId then
	lifecycle = {
		version = 1,
		jobId = game.JobId,
		createdAt = os.time(),
		tasks = {},
	}
end
lifecycle.configuredAt = os.time()
lifecycle.tasks = typeof(lifecycle.tasks) == "table" and lifecycle.tasks or {}

environment.AnimeOriginLifecycle = lifecycle
environment.AnimeOriginConfig = Config
return Config
