#!/usr/bin/env python3
"""Static regression checks for live PlayerData and non-fatal progression gating."""

from pathlib import Path


ROOT = Path(__file__).resolve().parents[1]
unit = (ROOT / "UnitProgression.lua").read_text(encoding="utf-8")
main = (ROOT / "main.lua").read_text(encoding="utf-8")
config = (ROOT / "Config.lua").read_text(encoding="utf-8")

checks = {
    "UnitProgression prefers wrapper PlayerData": (
        'isPlayerData(rawget(object, "PlayerData"))' in unit
        and "local function currentPlayerData()" in unit
        and 'rawget(currentPlayerData(), "Inventory")' in unit
    ),
    "Unverified food purchase is degraded, not fatal": (
        'log("SHOP_WARNING"' in unit
        and 'fail("SHOP", "Gold/Food change was not verified' not in unit
        and '"COMPLETE_WITH_WARNINGS"' in unit
    ),
    "Temporary UnitProgression getgc snapshot is released": "gcObjects = nil" in unit,
    "Pre-run discovery failures publish a terminal lifecycle": (
        'publishLifecycle("FAILED", { phase = stage' in unit
        and 'UnitProgression requires getgc(true).") end' in unit
    ),
    "Main waits for terminal optional worker failure": (
        'local terminal = status == "COMPLETE" or status == "SKIPPED" or status == "FAILED"' in main
        and "fatalTasks[taskName] == true" in main
    ),
    "Main follows the replaceable PlayerData wrapper": (
        "cachedPlayerDataContainer" in main
        and "cachedPlayerDataIsWrapper" in main
        and "readCachedPlayerData" in main
    ),
    "Config marks only FastMode fatal": (
        "fatalTasks = {" in config
        and "FastMode = true" in config
        and "UnitProgression = false" in config
    ),
}

failed = [name for name, passed in checks.items() if not passed]
for name, passed in checks.items():
    print(("PASS" if passed else "FAIL") + ": " + name)
if failed:
    raise SystemExit(1)
