#!/usr/bin/env python3
"""Static gate for the failure modes that only appear on a loaded host.

Every check here corresponds to a real, reproduced symptom on a machine running
dozens of clients: either the script never ran at all, or it ran and left the
account standing in the lobby. All four were the same class of defect -- a wait
with no bound, or an early bail that treated "not replicated yet" as "not there".

A static gate is the correct seam for these. The bugs are structural (a missing
deadline), not data-dependent, so they are visible in the source and cannot be
caught by replaying a log from a run that never got far enough to log anything.
"""

from __future__ import annotations

import pathlib
import re
import sys


ROOT = pathlib.Path(__file__).resolve().parent.parent

# Files that run in production on every client. Probes and tests are excluded:
# they are operator-driven and an unbounded wait there blocks only the operator.
RUNTIME_FILES = (
    "Loader.lua",
    "main.lua",
    "FastMode.lua",
    "UnitProgression.lua",
    "InGameSettings.lua",
    "AutoPlay.lua",
    "Optimizer.lua",
    "logstats.lua",
)


def fail(message: str, failures: list[str]) -> None:
    failures.append(message)
    print(f"[LagResilience][FAIL] {message}")


def check_no_unbounded_wait(failures: list[str]) -> None:
    """`signal:Wait()` has no timeout; if the signal never fires the thread parks
    forever. Two of these were live: Loader's `game.Loaded:Wait()` (which also
    fires only once, so a build where it had already fired would park on it), and
    main's `player.CharacterAdded:Wait()` inside Story Pod entry, which stalled the
    whole route whenever a respawn lagged."""
    pattern = re.compile(r"([A-Za-z_][\w.]*)\s*:\s*Wait\s*\(\s*\)")
    for name in RUNTIME_FILES:
        source = (ROOT / name).read_text(encoding="utf-8")
        for line_number, line in enumerate(source.splitlines(), start=1):
            if line.lstrip().startswith("--"):
                continue
            match = pattern.search(line)
            if match:
                fail(
                    f"{name}:{line_number} waits on `{match.group(0)}` with no timeout; "
                    f"use a bounded poll so a signal that never fires cannot park the run",
                    failures,
                )


def check_portal_waits_for_replication(failures: list[str]) -> None:
    """The Story Pod hierarchy is not replicated for the first seconds after a join
    on a loaded host. Returning on zero candidates spent all six transition attempts
    and all three route restarts before the Pods existed, so the account stood in the
    lobby with a dead route on a map that finished loading moments later."""
    source = (ROOT / "main.lua").read_text(encoding="utf-8")
    body = re.search(
        r"local function enterStoryPortal\(\)(.*?)\n\tif not attemptedPortal then",
        source,
        re.S,
    )
    if not body:
        fail("enterStoryPortal body was not found; the resilience gate cannot verify it", failures)
        return
    text = body.group(1)

    if re.search(r"if\s+#portalCandidates\s*==\s*0\s+then\s+return", text):
        fail(
            "enterStoryPortal returns immediately when no Pod has replicated yet; "
            "it must wait inside its own occupiedPortalWaitTimeout budget instead",
            failures,
        )
    if "occupancyPollInterval" not in text:
        fail("enterStoryPortal no longer polls while waiting for a usable Pod", failures)
    # The loop must still be bounded -- waiting forever is the opposite failure.
    if "deadline" not in text:
        fail("enterStoryPortal lost its deadline; the wait is now unbounded", failures)


def check_bootstrap_detects_silent_death(failures: list[str]) -> None:
    """A worker that dies during startup never publishes a lifecycle entry, and the
    gate could not tell that apart from a worker still doing useful work. Both read
    as PENDING, so main waited the full 300s timeout before failing -- five minutes
    of an idle account. Absence past a grace window must count as failure."""
    source = (ROOT / "main.lua").read_text(encoding="utf-8")
    config = (ROOT / "Config.lua").read_text(encoding="utf-8")

    if not re.search(r"^\s*startupGrace\s*=\s*\d+\s*,", config, re.MULTILINE):
        fail("Config.main.bootstrapGate.startupGrace is missing", failures)

    body = re.search(
        r"local function waitForBootstrapWorkers\(\)(.*?)\n\tfail\(\"BOOTSTRAP\"",
        source,
        re.S,
    )
    if not body:
        fail("waitForBootstrapWorkers body was not found", failures)
        return
    text = body.group(1)

    if "startupGrace" not in text:
        fail(
            "waitForBootstrapWorkers ignores startupGrace; a worker that published "
            "nothing is still treated as merely slow",
            failures,
        )
    # Absence must land in FAILED, so the existing fatal / non-fatal policy applies.
    if not re.search(r"startupGrace\s+then\s*\n\s*status\s*=\s*\"FAILED\"", text):
        fail(
            "expired startupGrace does not resolve to FAILED; absence must reuse the "
            "fatalTasks policy rather than inventing a third outcome",
            failures,
        )

    # startupGrace must exceed the workers' own startup waits or a slow worker is
    # declared dead while it is still legitimately waiting for Config/LocalPlayer.
    grace = re.search(r"^\s*startupGrace\s*=\s*(\d+)\s*,", config, re.MULTILINE)
    if grace:
        worker_startup_timeout = 30  # waitForConfig / waitForLocalPlayer default
        if int(grace.group(1)) <= worker_startup_timeout:
            fail(
                f"startupGrace = {grace.group(1)}s is not above the workers' own "
                f"{worker_startup_timeout}s Config/LocalPlayer waits; a merely slow "
                f"worker would be reported dead",
                failures,
            )


def check_loader_arms_queue_first(failures: list[str]) -> None:
    """queue_on_teleport is the only thing that brings the script back after a place
    transition. Anything that yields before it is armed is a window where a teleport
    drops the script permanently -- and waiting for the game to load is the longest
    yield in the file."""
    source = (ROOT / "Loader.lua").read_text(encoding="utf-8")

    arm = source.find("pcall(queueTeleport")
    load_wait = source.find("game:IsLoaded()")
    jitter = source.find("AnimeOriginLoaderJitter")

    if arm < 0:
        fail("Loader.lua never arms queue_on_teleport", failures)
        return
    if 0 <= load_wait < arm:
        fail(
            "Loader.lua waits for the game to load before arming queue_on_teleport; "
            "a teleport during that wait drops the script permanently",
            failures,
        )
    if 0 <= jitter < arm:
        fail(
            "Loader.lua applies its startup jitter before arming queue_on_teleport; "
            "a teleport during the delay drops the script permanently",
            failures,
        )
    if "loadDeadline" not in source:
        fail("Loader.lua's game-load wait is unbounded", failures)


def main() -> int:
    failures: list[str] = []
    check_no_unbounded_wait(failures)
    check_portal_waits_for_replication(failures)
    check_bootstrap_detects_silent_death(failures)
    check_loader_arms_queue_first(failures)

    if failures:
        print(f"\n[LagResilience] {len(failures)} check(s) failed")
        return 1
    print("[LagResilience][PASS] every startup and entry wait is bounded, and "
          "absent replication/workers are treated as retryable rather than fatal")
    return 0


if __name__ == "__main__":
    sys.exit(main())
