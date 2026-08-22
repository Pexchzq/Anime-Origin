#!/usr/bin/env python3
"""Regression check for Main stopping before lobby PlayerData finishes loading."""

from __future__ import annotations

import glob
import json
import math
import pathlib
import re
import sys


SOURCE_ROOT = pathlib.Path("/Users/siwakantalasak/Desktop/Anime Origin")
RUNTIME_ROOT = pathlib.Path("/Users/siwakantalasak/Documents/Macsploit Workspace/AnimeOrigin")
CONFIG_COPIES = (
    SOURCE_ROOT / "Config.lua",
    pathlib.Path("/Users/siwakantalasak/Documents/Macsploit Automatic Execution/1Config.lua"),
    pathlib.Path("/Users/siwakantalasak/Documents/MacsploitUI/scripts/1Config.lua"),
)


def main_runtime_timeout(path: pathlib.Path) -> int:
    """Read only Config.main.runtimeLoadTimeout, not FastMode's similarly named value."""
    source = path.read_text(encoding="utf-8")
    match = re.search(r"\n\s*main\s*=\s*\{.*?\nruntimeLoadTimeout\s*=\s*(\d+)", source, re.S)
    if not match:
        # Preserve indentation tolerance while keeping the search inside Config.main.
        match = re.search(r"\n\s*main\s*=\s*\{.*?runtimeLoadTimeout\s*=\s*(\d+)", source, re.S)
    if not match:
        raise AssertionError(f"Config.main.runtimeLoadTimeout not found in {path}")
    return int(match.group(1))


def latest_player_data_failure() -> tuple[pathlib.Path, dict]:
    """Replay the newest captured Main report that contains the user's exact failure."""
    reports = sorted(
        (pathlib.Path(item) for item in glob.glob(str(RUNTIME_ROOT / "MainRoute_*_latest.json"))),
        key=lambda item: item.stat().st_mtime,
        reverse=True,
    )
    for path in reports:
        payload = json.loads(path.read_text(encoding="utf-8"))
        if "[Main][PLAYER_DATA]" in str(payload.get("error", "")):
            return path, payload
    raise AssertionError("No captured Main PLAYER_DATA failure report was found")


def failure_wait_seconds(payload: dict) -> float:
    """Measure the failed readiness window from worker completion to PLAYER_DATA error."""
    events = payload.get("events") or []
    bootstrap_clock = None
    failure_clock = None
    for event in events:
        if event.get("stage") == "BOOTSTRAP" and event.get("message") == "Lobby workers are complete.":
            bootstrap_clock = float(event["clock"])
        if event.get("stage") == "ERROR" and "PLAYER_DATA" in str(event.get("message", "")):
            failure_clock = float(event["clock"])
    if bootstrap_clock is None or failure_clock is None:
        raise AssertionError("Captured report does not contain the required bootstrap/error timestamps")
    return failure_clock - bootstrap_clock


def main() -> int:
    try:
        report_path, payload = latest_player_data_failure()
        observed_wait = failure_wait_seconds(payload)
        # Leave at least 30 seconds beyond the reproduced slow join. The regression
        # occurred at roughly 20 seconds, so the prior 20-second mirror must fail.
        required_timeout = max(60, math.ceil(observed_wait + 30))
        replay_label = f"{report_path.name} observed_wait={observed_wait:.3f}s"
    except AssertionError:
        # latest reports are intentionally overwritten. Once the historical
        # failure artifact expires, retain the proven 60-second minimum rather
        # than turning a source regression test into an unrelated false failure.
        required_timeout = 60
        replay_label = "historical fixture expired; static minimum=60s"
    failures: list[str] = []

    for path in CONFIG_COPIES:
        if not path.is_file():
            failures.append(f"missing Config copy: {path}")
            continue
        timeout = main_runtime_timeout(path)
        if timeout < required_timeout:
            failures.append(f"{path}: timeout={timeout}s, required>={required_timeout}s")

    source_main = (SOURCE_ROOT / "main.lua").read_text(encoding="utf-8")
    if "waitForLobbyRuntime" not in source_main:
        failures.append("main.lua does not contain the dedicated refreshed lobby runtime gate")

    print(f"[LobbyRuntimeGate] replay={replay_label}")
    if failures:
        for failure in failures:
            print(f"[LobbyRuntimeGate][FAIL] {failure}")
        return 1
    print(f"[LobbyRuntimeGate][PASS] every Config copy waits at least {required_timeout}s")
    return 0


if __name__ == "__main__":
    sys.exit(main())
