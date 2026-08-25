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


def check_no_unbounded_wait_for_child(failures: list[str]) -> None:
    """`parent:WaitForChild(name)` with no second argument yields FOREVER, exactly
    like `signal:Wait()` -- but the check above cannot see it, because the method
    name differs and it always carries an argument. That blind spot let 24 unbounded
    lookups survive a round of fixes that reported PASS.

    The consequence is worse than a parked thread. FastMode and UnitProgression
    publish RUNNING before these lookups, so a worker yielding forever on a remote
    that has not replicated keeps its lifecycle entry at RUNNING permanently. main
    reads RUNNING as "still working" rather than "dead", waits out the entire
    bootstrap gate, and the account stands in the lobby -- which is precisely the
    symptom this gate exists to prevent.

    Requiring the timeout argument is the whole rule: what a caller does with the
    nil return is its own business, and the surrounding code proves that separately.
    """
    pattern = re.compile(r":\s*WaitForChild\s*\(([^)]*)\)")
    for name in RUNTIME_FILES:
        source = (ROOT / name).read_text(encoding="utf-8")
        for line_number, line in enumerate(source.splitlines(), start=1):
            if line.lstrip().startswith("--"):
                continue
            for match in pattern.finditer(line):
                # A timeout is the second argument. Instance names cannot contain a
                # comma, so a top-level comma is a reliable arity test here.
                if "," in match.group(1):
                    continue
                fail(
                    f"{name}:{line_number} calls `{match.group(0).strip()}` with no timeout; "
                    f"an instance that never replicates parks the worker at RUNNING forever "
                    f"and main then burns its whole bootstrap gate waiting for it",
                    failures,
                )


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

    # Any indentation: the timeout fail() now sits inside a fatal-task guard rather
    # than at the top level of the function.
    body = re.search(
        r"local function waitForBootstrapWorkers\(\)(.*?)\n\s*fail\(\"BOOTSTRAP\"",
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
        # waitForLocalPlayer(30) and waitForAnimeOriginConfig(30) run SEQUENTIALLY,
        # so the worst case a healthy worker can spend before publishing anything is
        # their sum. Comparing against one of them let startupGrace sit at 45s, where
        # a loaded host could declare a worker dead inside its own documented budget.
        worker_startup_timeout = 60
        if int(grace.group(1)) <= worker_startup_timeout:
            fail(
                f"startupGrace = {grace.group(1)}s is not above the workers' own "
                f"{worker_startup_timeout}s Config/LocalPlayer waits; a merely slow "
                f"worker would be reported dead",
                failures,
            )


def check_gate_timeout_respects_fatal_tasks(failures: list[str]) -> None:
    """Config marks UnitProgression non-fatal on purpose: unit leveling is account
    enrichment, not a routing prerequisite. That policy was applied only to a
    self-reported FAILED, while the gate's own timeout called fail() unconditionally
    -- so a merely slow UnitProgression killed the route even after FastMode had
    reported COMPLETE, and the account stood in the lobby for nothing.

    A timeout is the same evidence as a reported failure (the worker did not
    finish), so it has to go through the same fatal / non-fatal decision."""
    source = (ROOT / "main.lua").read_text(encoding="utf-8")

    # Scope to the gate first: `until os.clock() >= deadline` also ends waitUntil,
    # which appears earlier in the file and would match instead.
    gate = re.search(
        r"local function waitForBootstrapWorkers\(\)(.*?)\nend\n", source, re.S
    )
    tail = re.search(
        r"until os\.clock\(\) >= deadline(.*)", gate.group(1), re.S
    ) if gate else None
    if not tail:
        fail("waitForBootstrapWorkers timeout path was not found", failures)
        return
    text = tail.group(1)

    if "fatalTasks" not in text:
        fail(
            "the bootstrap gate's timeout path ignores fatalTasks; a non-fatal worker "
            "that is merely slow must not stop map selection",
            failures,
        )
    if "return true" not in text:
        fail(
            "the bootstrap gate's timeout path has no way to continue routing; a "
            "timeout on non-fatal workers only must not be fatal",
            failures,
        )


def check_gate_budget_survives_route_restart(failures: list[str]) -> None:
    """run() is re-entered by the supervisor after every route error. A gate deadline
    computed inside the function handed each attempt a fresh full budget, so a worker
    stuck at a non-terminal status cost maximumRouteRestarts x timeout of an account
    standing still -- and since restarting main never restarts the workers, every
    attempt re-observed the same stuck entry. The anchor must outlive one call."""
    source = (ROOT / "main.lua").read_text(encoding="utf-8")

    if not re.search(r"^local gateStartedAt\b", source, re.MULTILINE):
        fail(
            "gateStartedAt is not anchored outside waitForBootstrapWorkers; each "
            "supervised restart would receive a fresh bootstrap budget",
            failures,
        )
    if not re.search(r"gateStartedAt\s*=\s*gateStartedAt\s+or\s+os\.clock\(\)", source):
        fail(
            "gateStartedAt is reset on every gate entry; the bootstrap budget must be "
            "consumed once per lobby, not once per supervised attempt",
            failures,
        )


def check_failed_teleport_is_not_evidence(failures: list[str]) -> None:
    """Player.OnTeleport reports a FAILED teleport through the same signal as a
    successful one. Counting every state as transition evidence made the two
    indistinguishable -- and TeleportState.Failed is exactly what a host running
    dozens of clients produces, because Roblox rate-limits matchmaking (HTTP 429).
    main then set TELEPORTING_TO_STAGE, the supervisor treated the place lifecycle as
    committed and returned for good, and the account stood in the lobby with a report
    claiming the transition had been verified.

    Two things must hold: a failed state must not advance teleportGeneration, and an
    accepted StartTeleport must be re-checked, since only an actual place change ends
    this script's session."""
    source = (ROOT / "main.lua").read_text(encoding="utf-8")

    handler = re.search(r"player\.OnTeleport:Connect\(function\((.*?)\n\s*end\)\)", source, re.S)
    if not handler:
        fail("the OnTeleport handler was not found", failures)
        return
    text = handler.group(1)

    if "TeleportState.Failed" not in text:
        fail(
            "the OnTeleport handler does not distinguish TeleportState.Failed; a "
            "rate-limited host would record a failed teleport as transition evidence",
            failures,
        )
    if not re.search(r"teleportGeneration\s*\+=\s*1", text):
        fail("the OnTeleport handler no longer records teleport evidence at all", failures)

    if not re.search(r"^\s*stageTeleportSettleTimeout\s*=\s*\d+\s*,", (ROOT / "Config.lua").read_text(encoding="utf-8"), re.MULTILINE):
        fail(
            "Config.main.stageTeleportSettleTimeout is missing; an accepted "
            "StartTeleport that never lands would go unnoticed",
            failures,
        )
    if "STAGE_TELEPORT_STALLED" not in source:
        fail(
            "main never leaves TELEPORTING_TO_STAGE when a teleport does not land; the "
            "supervisor would treat the place lifecycle as committed and stop watching",
            failures,
        )


def check_loader_survives_throttling(failures: list[str]) -> None:
    """`game:HttpGet` RAISES on failure, and the Loader calls it 8 times per join at
    module scope. On a host running dozens of clients that is thousands of requests
    an hour against one IP, which GitHub throttles -- so one transient response used
    to kill a client for the whole session, silently, with Config.lua the worst place
    for it because nothing at all runs afterwards."""
    source = (ROOT / "Loader.lua").read_text(encoding="utf-8")

    if "pcall(game.HttpGet" not in source:
        fail(
            "Loader.lua calls game:HttpGet unprotected; a single throttled response "
            "would abort the whole client",
            failures,
        )
    if not re.search(r"for attempt = 1, maximumAttempts do", source):
        fail(
            "Loader.lua does not retry a failed download; transient throttling must "
            "not be terminal",
            failures,
        )
    # An empty 200 behind a proxy compiles to a chunk that does nothing at all, which
    # is indistinguishable from success unless it is rejected explicitly.
    if "#result > 0" not in source:
        fail(
            "Loader.lua accepts an empty response body as a successful download",
            failures,
        )


def check_every_runtime_file_traces(failures: list[str]) -> None:
    """A captured F9 console is the only diagnostic available for a farm host, and
    console.statusOnly silences the normal log path. Without a channel that ignores
    that flag, "the executor never injected", "a download failed" and "a worker died"
    all produce the same empty console -- which is exactly what happened on the
    capture that prompted this check.

    Every runtime file must be able to say it started, and the Loader must narrate
    the stages that precede Config entirely."""
    for name in RUNTIME_FILES:
        source = (ROOT / name).read_text(encoding="utf-8")
        if name == "Loader.lua":
            # The Loader cannot use Config's tracer; it carries its own copy.
            if "local function trace(" not in source:
                fail(f"{name} has no trace channel of its own", failures)
            for stage in ("attached", "ready:", "ABORT"):
                if stage not in source:
                    fail(f"{name} never traces the '{stage}' stage", failures)
            continue
        if "environment.AnimeOriginTrace" not in source:
            fail(
                f"{name} does not resolve the shared trace channel; a capture could "
                f"not tell whether this file ran at all",
                failures,
            )

    config = (ROOT / "Config.lua").read_text(encoding="utf-8")
    if not re.search(r"^\s*diagnostics\s*=\s*true\s*,", config, re.MULTILINE):
        fail(
            "Config.console.diagnostics is not enabled; the trace channel exists but "
            "emits nothing",
            failures,
        )


def check_reward_claims_are_not_fatal(failures: list[str]) -> None:
    """The concurrent reward phase used to get `claimSettlementTimeout + 5` = 9s for
    five jobs, and raised when they overran. But each job is a SEQUENCE of verified
    round-trips -- claimPlayTimeRewards alone walks every configured index and waits
    the full settlement timeout on each unavailable one, six at four seconds -- so the
    budget was structurally below the work.

    Six accounts died on it in one captured night, and the logs prove the jobs were
    still succeeding: "Daily Wheel verified" was written AFTER the FATAL line. Because
    main treats FastMode as a fatal bootstrap task, each one cost the account its whole
    route. Free-reward claims must never be fatal, and the budget must scale with the
    longest job rather than with one verification."""
    source = (ROOT / "FastMode.lua").read_text(encoding="utf-8")
    body = re.search(r"local function claimConfiguredRewards\(\)(.*?)\nend\n", source, re.S)
    if not body:
        fail("claimConfiguredRewards was not found", failures)
        return
    text = body.group(1)

    for match in re.finditer(r'fail\("CLAIMS"', text):
        fail(
            "claimConfiguredRewards still raises on a claim timeout or a claim "
            "failure; main treats FastMode as fatal, so a slow free-reward claim "
            "would again cost the account its entire route",
            failures,
        )
        break

    if "playTimeRewardIndices" not in text:
        fail(
            "the claim budget does not scale with the longest job; a per-verification "
            "timeout cannot bound a job that performs many verifications in sequence",
            failures,
        )


def check_lobby_return_has_a_landing_check(failures: list[str]) -> None:
    """returnToLobby was left without the settle watchdog on the argument that a stage
    has its own stall recovery. Six accounts disproved it in one night: they finished
    Act 6, fired TeleportToLobby, had it accepted, persisted "server accepted Return To
    Lobby" -- and were still in the stage place afterwards with every controller
    stopped. Server acceptance is not arrival, in either direction."""
    source = (ROOT / "main.lua").read_text(encoding="utf-8")
    body = re.search(r"local function returnToLobby\(reason\)(.*?)\nend\n", source, re.S)
    if not body:
        fail("returnToLobby was not found", failures)
        return
    if "LOBBY_RETURN_STALLED" not in body.group(1):
        fail(
            "returnToLobby treats an accepted TeleportToLobby as arrival; a teleport "
            "that never lands would leave the account in the stage with nothing watching",
            failures,
        )


def check_lobby_return_contract_matches_its_callers(failures: list[str]) -> None:
    """Adding the settle watchdog to returnToLobby silently changed what it returns, and
    the seven callers were not updated. The result was a function with no `return true`
    on any path -- landing destroys the script mid-call, so arrival is unobservable from
    inside -- while every caller still tested it as though there were one.

    The five in handleActOver do `if not returnToLobby(...) then fail("END_ACTION") end`,
    so they called fail() unconditionally: controller.active = false, every listener
    disconnected, and the surrounding xpcall swallowing the error so the route supervisor
    never restarted. An account that finished an act sat in the stage until morning.

    Two halves are asserted, because fixing either one alone reintroduces the other bug:
    the function must return something that CAN be true (server acceptance), and the two
    callers that would then stop watching the account must not treat acceptance as
    arrival.
    """
    source = (ROOT / "main.lua").read_text(encoding="utf-8")
    body = re.search(r"local function returnToLobby\(reason\)(.*?)\n\treturn ([a-zA-Z]+)\nend\n",
                     source, re.S)
    if not body:
        fail("returnToLobby was not found, or no longer ends in a plain return", failures)
        return

    returned = body.group(2)
    if returned in ("false", "true", "nil"):
        fail(
            f"returnToLobby ends in `return {returned}`; a caller writing "
            f"`if not returnToLobby(...) then fail(...) end` then fails on every call, "
            f"which kills the controller and disconnects its listeners",
            failures,
        )
    elif not re.search(rf"\n\tlocal {returned} = false\n", body.group(1)) \
            or not re.search(rf"\n\t\t\t{returned} = true\n", body.group(1)):
        fail(
            f"returnToLobby returns `{returned}`, but nothing sets it from false to true "
            f"on server acceptance; the caller contract is unsatisfiable again",
            failures,
        )

    # A `return` on a truthy result means "we left" -- which this function cannot know.
    # Both sites below would stop watching an account that is still in the stage.
    stage = re.search(r"local ok, ([a-zA-Z]+) = pcall\(returnToLobby,(.*?)\n\t\t\tend\n",
                      source, re.S)
    if not stage:
        fail("the stall watchdog's returnToLobby call was not found", failures)
    # No trailing newline required: the captured block ends AT the `return` when that
    # return is the last statement before the block closes, which is exactly the shape
    # this check exists to reject. Requiring one let the mutant through.
    elif re.search(rf"if ok and {stage.group(1)} then(?:(?!\n\t\t\tend).)*?\n\t+return(?![a-zA-Z])",
                   stage.group(2), re.S):
        fail(
            "the stall watchdog stops monitoring when the server merely ACCEPTS a lobby "
            "return; reaching that line is itself proof the client is still in the stage",
            failures,
        )

    context = re.search(r'returnToLobby\("context never loaded"\)(.{0,200})', source, re.S)
    if not context:
        fail("run()'s unknown-place escape was not found", failures)
    elif re.search(r"then\n\t{3,}.*?\n\t{3,}return\n", context.group(1), re.S):
        fail(
            "run() returns when the lobby teleport is merely accepted; falling through to "
            "fail() is what earns the supervised restart that tries again",
            failures,
        )


def check_unknown_place_is_escapable(failures: list[str]) -> None:
    """A place where neither the lobby portal nor any stage runtime appears is the one
    situation main cannot solve locally -- and it never tried. It failed CONTEXT,
    exhausted its restarts and stopped, while AutoPlay did the same, leaving six
    captured accounts idle for the rest of the night. It must ask the server for a
    lobby teleport, and it must say WHERE the portal path broke so the next capture
    can distinguish a slow lobby from an unrecognised place."""
    source = (ROOT / "main.lua").read_text(encoding="utf-8")
    run = re.search(r"local function run\(\)(.*?)\nend\n", source, re.S)
    if not run:
        fail("main's run() was not found", failures)
        return
    text = run.group(1)

    if "returnToLobby(" not in text:
        fail(
            "main gives up on an unusable place instead of trying to leave it; the "
            "account stays there with every controller stopped",
            failures,
        )
    if "portalPath" not in text:
        fail(
            "the CONTEXT failure does not report where the portal path broke; a slow "
            "lobby, a stage whose match never started and an unrecognised place all "
            "look identical in the log",
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
    check_no_unbounded_wait_for_child(failures)
    check_gate_timeout_respects_fatal_tasks(failures)
    check_gate_budget_survives_route_restart(failures)
    check_failed_teleport_is_not_evidence(failures)
    check_loader_survives_throttling(failures)
    check_every_runtime_file_traces(failures)
    check_reward_claims_are_not_fatal(failures)
    check_lobby_return_has_a_landing_check(failures)
    check_lobby_return_contract_matches_its_callers(failures)
    check_unknown_place_is_escapable(failures)
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
