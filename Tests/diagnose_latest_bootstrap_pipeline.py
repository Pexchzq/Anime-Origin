#!/usr/bin/env python3
"""Replay the latest lobby bootstrap reports and expose route-blocking failures."""

from __future__ import annotations

import json
import sys
from pathlib import Path


RUNTIME = Path("/Users/siwakantalasak/Documents/Macsploit Workspace/AnimeOrigin")


def latest(prefix: str) -> Path:
    matches = sorted(
        RUNTIME.glob(f"{prefix}_*_latest.json"),
        key=lambda path: path.stat().st_mtime,
        reverse=True,
    )
    if not matches:
        raise SystemExit(f"missing runtime report: {prefix}_*_latest.json")
    return matches[0]


def read(path: Path) -> dict:
    return json.loads(path.read_text(encoding="utf-8"))


unit_path = latest("UnitProgression")
main_path = latest("MainRoute")
unit = read(unit_path)
main = read(main_path)

problems: list[str] = []
if unit.get("jobId") != main.get("jobId"):
    problems.append("latest UnitProgression and MainRoute reports are from different jobs")

if unit.get("status") == "FAILED":
    problems.append(
        "UnitProgression failed at "
        f"{unit.get('failedStage')}: {unit.get('reason')}"
    )

gate = main.get("bootstrapGate") or {}
if gate.get("UnitProgression") == "FAILED" and main.get("status") == "FAILED":
    problems.append("Main treated optional UnitProgression failure as a fatal route gate")

if main.get("status") == "FAILED" and not main.get("actions"):
    problems.append("Main stopped before emitting any Story/Hard/Infinite route action")

print(f"UnitProgression: {unit_path.name} status={unit.get('status')}")
print(f"MainRoute:       {main_path.name} status={main.get('status')}")
for problem in problems:
    print(f"RED: {problem}")

if problems:
    sys.exit(1)

print("GREEN: latest lobby bootstrap reached route selection without a fatal worker gate")
