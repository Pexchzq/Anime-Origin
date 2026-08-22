#!/usr/bin/env python3
"""Regression guards for replay epochs, restart routing and visible HUD state."""

from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
auto = (ROOT / "AutoPlay.lua").read_text()
main = (ROOT / "main.lua").read_text()
config = (ROOT / "Config.lua").read_text()

checks = {
    "Story waves cannot call Infinite restart": (
        'if not isInfiniteTarget(target) or wave ~= restartWave then return end' in main
    ),
    "prior match UUID baseline exists": "priorEpochUUIDs = {}" in auto,
    "prior epoch TowerDict entries are ignored": "not self.priorEpochUUIDs[uuid]" in auto,
    "new server placements escape baseline": 'eventKind == "CreateNewTower"' in auto,
    "rejected upgrades have a circuit breaker": "rejectedUpgradeUntil[uuid]" in auto,
    "unverified Infinite restart leaves end recovery armed": (
        "restartPending = false" in main
        and "end-match recovery remains armed" in main
    ),
    "whole PlayerGui suppression is disabled": "hidePlayerGuiWhenUnfocused = false" in config,
}

failed = [name for name, ok in checks.items() if not ok]
if failed:
    for name in failed:
        print(f"[PlaySafety][FAIL] {name}")
    raise SystemExit(1)

print("[PlaySafety][PASS] restart guard, epoch isolation, upgrade backoff and HUD policy")
