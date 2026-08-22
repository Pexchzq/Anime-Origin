#!/usr/bin/env python3
"""Static regression checks for the AutoPlay Lua-heap growth incident."""

from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
auto = (ROOT / "AutoPlay.lua").read_text()
config = (ROOT / "Config.lua").read_text()

checks = {
    "config bounds diagnostic strings": "maximumRetainedLogLines = 300" in config,
    "config bounds team action evidence": "maximumRetainedTeamActions = 300" in config,
    "getgc snapshots are explicitly cleared": "table.clear(gcObjects)" in auto,
    "refresh releases prior snapshot": "if refresh == true then releaseGCObjects() end" in auto,
    "diagnostic ring is bounded": "if #logBuffer > maximumRetainedLogLines" in auto,
    "team action ring is bounded": "if #report.actions > maximumRetainedTeamActions" in auto,
    "raw gc nil assignments are gone": "gcObjects = nil" not in auto.replace("\tgcObjects = nil\nend", ""),
}

failed = [name for name, ok in checks.items() if not ok]
if failed:
    for name in failed:
        print(f"[AutoPlayMemory][FAIL] {name}")
    raise SystemExit(1)

print("[AutoPlayMemory][PASS] getgc snapshots and diagnostic history are bounded")
