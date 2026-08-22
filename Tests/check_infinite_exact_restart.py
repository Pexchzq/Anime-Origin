#!/usr/bin/env python3
"""Regression contract for exact-wave Infinite restart and intact End Screen UI."""

from pathlib import Path


ROOT = Path(__file__).resolve().parents[1]
MAIN = (ROOT / "main.lua").read_text(encoding="utf-8")
CONFIG = (ROOT / "Config.lua").read_text(encoding="utf-8")
OPTIMIZER = (ROOT / "Optimizer.lua").read_text(encoding="utf-8")

for token in (
    "if not isInfiniteTarget(target) or wave ~= restartWave then return end",
    'local action = recordAction("RESTART_GAME"',
    'genericRemote:FireServer("RestartGame")',
    "Infinite has no reliable empty-enemy interval",
):
    assert token in MAIN, f"missing exact-wave restart contract: {token}"

assert 'Workspace:FindFirstChild("Enemies")' not in MAIN
assert "restartInfiniteAtWave = 15" in CONFIG
assert "cleanupTransientUi = false" in CONFIG
assert "destroyTransientGuiClones = false" in CONFIG
assert "preserved = true" in OPTIMIZER
assert "if isLifecycleGui(instance) then return false end" in OPTIMIZER

print("Infinite restarts at the configured exact wave and preserves game-owned End Screen UI")
