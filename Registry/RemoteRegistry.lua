--[[
	Anime Origin remote registry

	This project is independent from Anime SQ. Paths, arguments and assumptions
	must come from Anime Origin observations only.

	The registry describes remotes without invoking them. Runtime scripts can use
	this metadata later, which keeps discovery evidence separate from execution.
]]

local RemoteRegistry = {
	-- Remotes verified for use only while the player is in the lobby.
	use_in_lobby = {
		get_current_gold_shop_rotation = {
			description = "Read the server-generated current Gold Shop catalog without opening its UI.",
			path = "ReplicatedStorage.LobbyRemotes.ShopFunction",
			remoteType = "RemoteFunction",
			method = "InvokeServer",
			arguments = {
				{ name = "action", type = "string", example = "GetCurrentGoldShopRotation" },
			},
			verification = "Returned table contains ShopItems; CurrentSeed is compared with PlayerData.Shops.GoldShop.Seed",
		},

		buy_gold_shop_item = {
			description = "Buy a quantity of one Gold Shop item by the current shop index.",
			path = "ReplicatedStorage.LobbyRemotes.ShopRemote",
			remoteType = "RemoteEvent",
			method = "FireServer",
			arguments = {
				{ name = "action", type = "string", example = "BuyShopItem" },
				{ name = "shop", type = "string", example = "GoldShop" },
				{
					name = "itemIndex",
					type = "number",
					example = 3,
					dynamic = true,
					note = "Resolve this index from ShopFunction.GetCurrentGoldShopRotation every run; never reuse an index across rotations.",
				},
				{ name = "quantity", type = "number", example = 1, userEditable = true },
			},
			verification = "Gold decreases and the resolved PlayerData item quantity increases",
		},

		redeem_code = {
			description = "Redeem a code.",
			path = "ReplicatedStorage.LobbyRemotes.CodesFunction",
			remoteType = "RemoteFunction",
			method = "InvokeServer",
			arguments = {
				{ name = "action", type = "string", example = "RedeemCode" },
				{ name = "code", type = "string", example = "100K!", userEditable = true },
			},
		},

		claim_daily_reward = {
			description = "Claim the daily reward.",
			path = "ReplicatedStorage.Remotes.RemoteEvent",
			remoteType = "RemoteEvent",
			method = "FireServer",
			arguments = {
				{ name = "action", type = "string", example = "ClaimDailyReward" },
				{ name = "rewardType", type = "string", example = "Normal", userEditable = true },
			},
		},

		claim_all_quests = {
			description = "Claim every quest whose authoritative PlayerData Claimable flag is true.",
			path = "ReplicatedStorage.LobbyRemotes.QuestRemote",
			remoteType = "RemoteEvent",
			method = "FireServer",
			arguments = {
				{ name = "action", type = "string", example = "ClaimAllQuests" },
			},
			verification = "PlayerData.Quests nested Claimable=true count decreases",
		},

		claim_playtime_reward = {
			description = "Claim one playtime reward by reward index.",
			path = "ReplicatedStorage.LobbyRemotes.PlayTimeRewardsRemote",
			remoteType = "RemoteEvent",
			method = "FireServer",
			arguments = {
				{ name = "action", type = "string", example = "ClaimPlayTimeReward" },
				{ name = "rewardIndex", type = "number", example = 1, userEditable = true },
			},
		},

		claim_battlepass_once = {
			description = "Claim the configured battlepass season once.",
			path = "ReplicatedStorage.LobbyRemotes.BattlepassRemote",
			remoteType = "RemoteEvent",
			method = "FireServer",
			arguments = {
				{ name = "action", type = "string", example = "ClaimBattlepass" },
				{ name = "season", type = "string", example = "Season1", userEditable = true },
			},
		},

		toggle_auto_sell_rare = {
			description = "Toggle automatic selling of Rare units for the Standard summon.",
			path = "ReplicatedStorage.LobbyRemotes.SummonRemote",
			remoteType = "RemoteEvent",
			method = "FireServer",
			arguments = {
				{ name = "action", type = "string", example = "ToggleAutoSell" },
				{ name = "banner", type = "string", example = "Standard", userEditable = true },
				{ name = "rarity", type = "string", example = "Rare", userEditable = true },
			},
			verification = "PlayerData.AutoSell[<banner>][<rarity>] equals the configured boolean",
		},

		summon_standard_ten = {
			description = "Summon ten times from the Standard banner.",
			path = "ReplicatedStorage.LobbyRemotes.SummonFunction",
			remoteType = "RemoteFunction",
			method = "InvokeServer",
			arguments = {
				{ name = "action", type = "string", example = "SummonTower" },
				{ name = "banner", type = "string", example = "Standard", userEditable = true },
				{ name = "amount", type = "number", example = 10, userEditable = true },
			},
		},

		spin_daily_wheel = {
			description = "Spin the daily wheel.",
			path = "ReplicatedStorage.Remotes.DailyWheelFunction",
			remoteType = "RemoteFunction",
			method = "InvokeServer",
			arguments = {
				-- The boolean meaning is not inferred until more runtime evidence exists.
				{ name = "value", type = "boolean", example = true, userEditable = false },
			},
		},

		-- PRECONDITION, measured: the server ignores StartSelection until it has seen
		-- this player enter a Story Pod. Firing it from outside a Pod was refused 26
		-- times out of 26 -- no AfterMapSelect, no MapSelect of any kind.
		--
		-- The Pod's DoorUIPart carries a TouchInterest (a TouchTransmitter), which is
		-- the structural proof that .Touched is connected server-side. Raising that
		-- event satisfies the precondition without moving the character:
		--
		--     firetouchinterest(humanoidRootPart, doorUIPart, 0)
		--     task.wait(0.15)
		--     firetouchinterest(humanoidRootPart, doorUIPart, 1)
		--
		-- Verified by Probes/PodEntryBypassProbe.lua from 180 studs away with no
		-- movement and no CFrame write: the server answered MapSelect and
		-- UpdatePlayersInside naming this player, then accepted StartSelection, on the
		-- first attempt.
		start_map_selection = {
			description = "Select a stage without starting it. Requires a Story Pod entry first.",
			path = "ReplicatedStorage.LobbyRemotes.MapSelectRemote",
			remoteType = "RemoteEvent",
			method = "FireServer",
			precondition = "Server has observed this player entering a Story Pod (walk in, or fire the DoorUIPart TouchInterest).",
			arguments = {
				{ name = "action", type = "string", example = "StartSelection" },
				{ name = "mode", type = "string", example = "Story", userEditable = true },
				{ name = "world", type = "string", example = "WestCity", userEditable = true },
				-- The observed act value is a string, not a number.
				{ name = "act", type = "string", example = "1", userEditable = true },
				{ name = "difficulty", type = "string", example = "Normal", userEditable = true },
			},
			verification = "AfterMapSelect arrives and its target matches the requested mode/world/act/difficulty. Firing alone is not success.",
		},

		-- Final Start button. The tracer persisted this call before the immediate
		-- teleport, confirming it is separate from StartSelection.
		start_teleport = {
			description = "Start the selected stage and teleport into the game.",
			path = "ReplicatedStorage.LobbyRemotes.MapSelectRemote",
			remoteType = "RemoteEvent",
			method = "FireServer",
			precondition = "A matching AfterMapSelect from start_map_selection has already been observed.",
			arguments = {
				{ name = "action", type = "string", example = "StartTeleport" },
			},
			verification = "TeleportGui arrives, or LocalPlayer.OnTeleport fires. Firing alone is not success.",
		},
	},

	-- Remotes verified for use only while the player is inside a stage.
	use_in_game = {
		restart_game = {
			description = "Restart the active match immediately.",
			path = "ReplicatedStorage.Remotes.RemoteEvent",
			remoteType = "RemoteEvent",
			method = "FireServer",
			arguments = {
				{ name = "action", type = "string", example = "RestartGame" },
			},
			verification = "A new match lifecycle/epoch must be observed; FireServer alone is not success proof",
		},

		-- Captured from the normal pre-match Confirm callback. The no-hook V3 run
		-- observed StartWaveVote -> EndWaveVote and GameStarted false -> true, proving
		-- the call shape while also proving that the earlier hook caused the freeze.
		wave_vote_ready = {
			description = "Vote that the local player is ready to start the active match.",
			path = "ReplicatedStorage.LobbyRemotes.ActRemoteEvent",
			remoteType = "RemoteEvent",
			method = "FireServer",
			arguments = {
				{ name = "action", type = "string", example = "WaveVote" },
				{ name = "ready", type = "boolean", example = true },
			},
		},

		-- SettingsRemote has both toggle-only and explicit-value overloads. A caller
		-- must read live state before using the toggle form; firing it blindly can
		-- invert an already-correct setting.
		set_setting_toggle = {
			description = "Toggle one in-game setting after verifying its current runtime value.",
			path = "ReplicatedStorage.Remotes.SettingsRemote",
			remoteType = "RemoteEvent",
			method = "FireServer",
			arguments = {
				{ name = "action", type = "string", example = "SetSetting" },
				{
					name = "settingName",
					type = "string",
					example = "AutoSkipWave",
					userEditable = true,
					note = "No boolean argument exists; compare live state before firing.",
				},
			},
		},

		set_setting_value = {
			description = "Set one in-game setting to an explicit value.",
			path = "ReplicatedStorage.Remotes.SettingsRemote",
			remoteType = "RemoteEvent",
			method = "FireServer",
			arguments = {
				{ name = "action", type = "string", example = "SetSetting" },
				{ name = "settingName", type = "string", example = "GraphicsQuality", userEditable = true },
				{ name = "value", type = "string", example = "Low", userEditable = true },
			},
		},

		replay_act_vote = {
			description = "Vote to replay after the stage ends.",
			path = "ReplicatedStorage.LobbyRemotes.ActRemoteEvent",
			remoteType = "RemoteEvent",
			method = "FireServer",
			arguments = {
				{ name = "action", type = "string", example = "ReplayActVote" },
			},
			verification = "Send once, then require a new UpdateClientGame or StartWaveVote lifecycle signal",
		},

		next_act_vote = {
			description = "Vote for the next act after the stage ends.",
			path = "ReplicatedStorage.LobbyRemotes.ActRemoteEvent",
			remoteType = "RemoteEvent",
			method = "FireServer",
			arguments = {
				{ name = "action", type = "string", example = "NextActVote" },
			},
			verification = "Send once, then require the expected next UpdateClientGame or a new StartWaveVote signal",
		},

		-- MainFlowStateProbe captured this outbound call twice before the client
		-- received RemoteEvent.OnClientEvent("TeleportGui", ...). Persist/observe the
		-- server response or Players.LocalPlayer.OnTeleport; FireServer alone is not
		-- sufficient proof that the transition was accepted.
		return_to_lobby = {
			description = "Return from an end screen to the lobby place.",
			path = "ReplicatedStorage.Remotes.RemoteEvent",
			remoteType = "RemoteEvent",
			method = "FireServer",
			arguments = {
				{ name = "action", type = "string", example = "TeleportToLobby" },
			},
			verification = "Wait for OnClientEvent('TeleportGui', ...) or LocalPlayer.OnTeleport before treating the action as accepted",
		},

		change_speed = {
			description = "Change the active stage speed.",
			path = "ReplicatedStorage.Remotes.RemoteEvent",
			remoteType = "RemoteEvent",
			method = "FireServer",
			arguments = {
				{ name = "action", type = "string", example = "ChangeSpeed" },
				{ name = "speedLevel", type = "string", example = "Two", userEditable = true },
			},
		},

		place_tower_slot_1 = {
			description = "Place the character equipped in slot one.",
			path = "ReplicatedStorage.LobbyRemotes.TowerHandlerRemotes.TowerHandlerFunction",
			remoteType = "RemoteFunction",
			method = "InvokeServer",
			arguments = {
				{ name = "action", type = "string", example = "PlaceTower" },
				{ name = "towerSlot", type = "string", example = "Tower1" },
				{
					name = "position",
					type = "Vector3",
					example = Vector3.new(-543.914794921875, 126.51518249511719, -797.2826538085938),
					userEditable = true,
					dynamic = true,
					note = "Observed position only; calculate or select a valid placement position at runtime.",
				},
				{ name = "surfaceNormal", type = "Vector3", example = Vector3.new(0, 1, 0) },
				{ name = "rotation", type = "number", example = 0, userEditable = true },
				{ name = "unknown6", type = "nil", nullable = true, note = "Observed value is nil." },
				{ name = "confirmed", type = "boolean", example = true },
			},
		},

		place_tower_slot_2 = {
			description = "Place the character equipped in slot two.",
			path = "ReplicatedStorage.LobbyRemotes.TowerHandlerRemotes.TowerHandlerFunction",
			remoteType = "RemoteFunction",
			method = "InvokeServer",
			arguments = {
				{ name = "action", type = "string", example = "PlaceTower" },
				{ name = "towerSlot", type = "string", example = "Tower2" },
				{
					name = "position",
					type = "Vector3",
					example = Vector3.new(-537.3198852539062, 126.51518249511719, -778.6162109375),
					userEditable = true,
					dynamic = true,
					note = "Observed position only; calculate or select a valid placement position at runtime.",
				},
				{ name = "surfaceNormal", type = "Vector3", example = Vector3.new(0, 1, 0) },
				{ name = "rotation", type = "number", example = 0, userEditable = true },
				{ name = "unknown6", type = "nil", nullable = true, note = "Observed value is nil." },
				{ name = "confirmed", type = "boolean", example = true },
			},
		},

		-- The focused callback scan confirmed that every equipped slot uses the same
		-- RemoteFunction and PlaceTower overload; only towerSlot/position are dynamic.
		place_tower = {
			description = "Place any equipped tower and verify CreateNewTower afterward.",
			path = "ReplicatedStorage.LobbyRemotes.TowerHandlerRemotes.TowerHandlerFunction",
			remoteType = "RemoteFunction",
			method = "InvokeServer",
			arguments = {
				{ name = "action", type = "string", example = "PlaceTower" },
				{ name = "towerSlot", type = "string", example = "Tower3", dynamic = true },
				{ name = "position", type = "Vector3", dynamic = true },
				{ name = "surfaceNormal", type = "Vector3", example = Vector3.new(0, 1, 0) },
				{ name = "rotation", type = "number", example = 0 },
				{ name = "unknown6", type = "nil", nullable = true },
				{ name = "confirmed", type = "boolean", example = true },
			},
			verification = "TowerHandlerRemote.OnClientEvent('CreateNewTower', TowerInfo)",
		},

		-- UpgradeTower callback constants and upvalues point to this RemoteFunction.
		-- The UUID here is the placed-tower UUID, not the inventory UUID.
		upgrade_tower = {
			description = "Upgrade one placed tower and verify a higher Stage afterward.",
			path = "ReplicatedStorage.LobbyRemotes.TowerHandlerRemotes.TowerHandlerFunction",
			remoteType = "RemoteFunction",
			method = "InvokeServer",
			arguments = {
				{ name = "action", type = "string", example = "UpgradeTower" },
				{ name = "placedTowerUUID", type = "string", dynamic = true },
			},
			verification = "TowerHandlerRemote.OnClientEvent('UpdateTower', UUID, patch) with Stage increasing",
		},
	},

	-- Remotes verified to work in both lobby and stage places.
	cross_remote = {
		lock_tower = {
			description = "Lock one owned unit by inventory UUID so later automation cannot consume it.",
			path = "ReplicatedStorage.Remotes.InventoryRemotes.InventoryFunction",
			remoteType = "RemoteFunction",
			method = "InvokeServer",
			arguments = {
				{ name = "action", type = "string", example = "LockTower" },
				{
					name = "towerUUID",
					type = "string",
					example = "cd938939-e9e3-4740-bf28-cf4cbfb19234",
					dynamic = true,
					note = "Observed UUID only; resolve configured identifiers to every matching live UUID.",
				},
			},
			verification = "InvokeServer returns the authoritative boolean; official callback assigns it to Inventory.Towers[UUID].Locked",
		},

		feed_tower = {
			description = "Consume explicit Food counts to grant EXP to one owned unit.",
			path = "ReplicatedStorage.Remotes.InventoryRemotes.InventoryRemote",
			remoteType = "RemoteEvent",
			method = "FireServer",
			arguments = {
				{ name = "action", type = "string", example = "FeedTower" },
				{ name = "targetTowerUUID", type = "string", dynamic = true },
				{
					name = "foodCounts",
					type = "table<string, number>",
					dynamic = true,
					example = { HoiBoi = 1 },
					note = "Keys are internal ItemInfo.Food names; values cannot exceed PlayerData.Inventory.Food counts.",
				},
			},
			verification = "Selected Food counts decrease and target Inventory.Towers[UUID].Exp increases",
		},

		fuse_towers = {
			description = "Consume selected owned unit UUIDs to grant EXP to one target unit.",
			path = "ReplicatedStorage.Remotes.InventoryRemotes.InventoryRemote",
			remoteType = "RemoteEvent",
			method = "FireServer",
			arguments = {
				{ name = "action", type = "string", example = "FuseTower" },
				{ name = "targetTowerUUID", type = "string", dynamic = true },
				{
					name = "consumedTowerUUIDs",
					type = "table<string, boolean>",
					dynamic = true,
					note = "Build only from verified disposable UUIDs; never include targets, equipped, locked, configured protected, Shiny, Mythic or Secret units.",
				},
			},
			verification = "Every consumed UUID disappears and target Exp/Level increases in PlayerData",
		},

		unequip_all_towers = {
			description = "Unequip every character from the current loadout.",
			path = "ReplicatedStorage.Remotes.InventoryRemotes.InventoryRemote",
			remoteType = "RemoteEvent",
			method = "FireServer",
			arguments = {
				{ name = "action", type = "string", example = "UnEquipAllTowers" },
			},
		},

		equip_tower = {
			description = "Equip the selected character using its inventory UUID.",
			path = "ReplicatedStorage.Remotes.InventoryRemotes.InventoryRemote",
			remoteType = "RemoteEvent",
			method = "FireServer",
			arguments = {
				{ name = "action", type = "string", example = "EquipTower" },
				{
					name = "towerUUID",
					type = "string",
					example = "433b6bd9-16d0-41e2-aeee-82c1e175c700",
					userEditable = true,
					dynamic = true,
					note = "Observed UUID only; resolve the selected character UUID from live inventory data.",
				},
			},
		},
	},
}

return RemoteRegistry
