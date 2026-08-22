#!/usr/bin/env python3
"""Contract for ensuring one equipped unit before lobby stage selection."""

from pathlib import Path


ROOT = Path(__file__).resolve().parents[1]
MAIN = (ROOT / "main.lua").read_text(encoding="utf-8")
CONFIG = (ROOT / "Config.lua").read_text(encoding="utf-8")

for token in (
    "lobbyLoadoutGuard = {",
    "maximumCandidates = 10",
    "equipVerifyTimeout = 5",
):
    assert token in CONFIG, f"missing lobby loadout config: {token}"

for token in (
    "local function ensureLobbyLoadout()",
    'inventoryRemote:FireServer("EquipTower", candidate.uuid)',
    'rawget(data, "EquippedTowers")',
    'rawget(inventory, "Towers")',
    'recordAction("LOBBY_EQUIP_FALLBACK"',
    "ensureLobbyLoadout()",
):
    assert token in MAIN, f"missing lobby loadout guard: {token}"

guard_call = MAIN.index("ensureLobbyLoadout()", MAIN.index("local function runLobby()"))
selection_call = MAIN.index("startSelectedStage(target)", MAIN.index("local function runLobby()"))
assert guard_call < selection_call, "loadout guard must run before stage selection"

print("lobby loadout guard contract passed")
