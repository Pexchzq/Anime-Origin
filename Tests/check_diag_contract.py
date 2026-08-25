#!/usr/bin/env python3
"""Static gate for the diagnostics recorder.

Diag.lua is a passive observer attached to ~54 unattended clients. That makes its
failure modes asymmetric: a recorder that misses something costs one capture, while a
recorder that raises, blocks, or fills a disk costs a whole night of farming across
the fleet. Every check here defends that asymmetry, plus the two properties the
recorder is worthless without -- that its folder is safe to delete, and that a capture
can actually be sent for analysis.

Nothing here checks whether the recorder produces correct verdicts. That is
Tests/check_diag_runtime.py, which executes the real file.
"""

from __future__ import annotations

import pathlib
import re
import sys


ROOT = pathlib.Path(__file__).resolve().parent.parent

WORKERS = ("main.lua", "FastMode.lua", "AutoPlay.lua", "UnitProgression.lua",
           "InGameSettings.lua", "Optimizer.lua", "logstats.lua")


def fail(message: str, failures: list[str]) -> None:
    failures.append(message)
    print(f"[DiagContract][FAIL] {message}")


def diag_source() -> str:
    """Diag.lua opens with a disabled-mode block that publishes one-line no-op stubs of
    the same public surface, then returns early. Scanning the whole file makes every
    check below match a stub -- which trivially satisfies "cannot raise" while proving
    nothing about the code that actually runs. Cut it off."""
    source = (ROOT / "Diag.lua").read_text(encoding="utf-8")
    marker = "local epoch = tonumber(environment.AnimeOriginTraceEpoch)"
    index = source.find(marker)
    assert index > 0, "Diag.lua no longer has the disabled-mode boundary marker"
    return source[index:]


def check_folder_is_not_state(failures: list[str]) -> None:
    """The whole promise of this folder is that deleting it is always safe. That holds
    only while it shares nothing with the state folder, which carries
    FastModeBootstrap_*.json and MainRoute_*.json -- an account whose bootstrap state
    is deleted mid-run reclassifies itself and never finishes summoning."""
    config = (ROOT / "Config.lua").read_text(encoding="utf-8")
    recorder = re.search(r"debugRecorder = \{(.*?)\n\t\},", config, re.S)
    if not recorder:
        fail("Config.debugRecorder is missing", failures)
        return
    folder = re.search(r'folder = "([^"]+)"', recorder.group(1))
    if not folder:
        fail("Config.debugRecorder.folder is missing", failures)
        return
    state_folders = set(re.findall(r'stateFolder = "([^"]+)"', config))
    if folder.group(1) in state_folders:
        fail(
            f"the diagnostics folder is {folder.group(1)!r}, which is also a stateFolder; "
            f"'delete the diagnostics folder' would then destroy resumable bootstrap state",
            failures,
        )

    diag = (ROOT / "Diag.lua").read_text(encoding="utf-8")
    default = re.search(r'Settings\.folder or "([^"]+)"', diag)
    if not default:
        fail("Diag.lua has no default folder", failures)
    elif default.group(1) in state_folders:
        fail(
            f"Diag.lua falls back to {default.group(1)!r}, a stateFolder, when Config is "
            f"absent -- the dangerous path is the one taken when config is missing",
            failures,
        )

    # Every write must be inside the recorder's own folder.
    for match in re.finditer(r"pcall\((?:writefile|appendfile), ([^,]+),", diag):
        target = match.group(1).strip()
        if not target.startswith("FOLDER") and target not in ("path",):
            fail(f"Diag.lua writes to {target!r}, which is not rooted at its own folder", failures)


def check_recorder_cannot_raise(failures: list[str]) -> None:
    """Every public entry point is called from inside game code that must not care
    whether diagnostics work. One uncaught raise in a claim path is one dead account."""
    diag = diag_source()
    for name in ("mark", "signal", "counter", "flush"):
        body = re.search(rf"function Diag\.{name}\((.*?)\nend\n", diag, re.S)
        if not body:
            fail(f"Diag.{name} is missing", failures)
        elif "pcall" not in body.group(1):
            fail(f"Diag.{name} does not pcall its work; it can raise into game code", failures)

    step = re.search(r"function Diag\.step\((.*?)\nend\n", diag, re.S)
    if not step:
        fail("Diag.step is missing", failures)
    elif "pcall(beginNode" not in step.group(1) or "return INERT" not in step.group(1):
        fail(
            "Diag.step must pcall beginNode and fall back to the inert handle; a call site "
            "that gets nil back would index it and raise",
            failures,
        )

    # The handle methods matter as much: they run at the failure sites themselves.
    for method in ("ok", "noop", "fail", "note", "because", "extend"):
        body = re.search(rf"\tfunction handle\.{method}\((.*?)\n\tend\n", diag, re.S)
        if not body:
            fail(f"handle.{method} is missing", failures)
        elif "pcall" not in body.group(1):
            fail(f"handle.{method} does not pcall its work; closing a step could raise", failures)


def check_everything_is_bounded(failures: list[str]) -> None:
    """This runs all night on a host already short on memory, and unbounded growth is
    the bug this project keeps having. Every retained container needs a ceiling."""
    diag = diag_source()
    for cap, guard in (
        ("EVENT_BYTE_CAP", r"eventBytes >= EVENT_BYTE_CAP"),
        ("MAX_NODES", r"#nodeOrder > MAX_NODES"),
        ("MAX_OPEN", r"openCount >= MAX_OPEN"),
        ("TAIL_EVENTS", r"#tail > TAIL_EVENTS"),
        ("CHAIN_DEPTH", r"depth < CHAIN_DEPTH"),
    ):
        if not re.search(guard, diag):
            fail(f"{cap} is defined but never enforced; the matching container can grow without bound",
                 failures)
    if "#pendingEvents < 64" not in diag:
        fail("the pre-UserId event buffer is unbounded", failures)

    # A `while true` reaper would outlive its own server after a teleport and write one
    # client's story into another's digest.
    reaper = re.search(r"task\.spawn\(function\(\)(.*?)\nend\)", diag, re.S)
    if not reaper:
        fail("the reaper loop was not found", failures)
    elif "while true" in reaper.group(1) or "game.JobId == bootJobId" not in reaper.group(1):
        fail("the reaper loop is not bound to the JobId it started in", failures)


def check_payloads_are_sanitised(failures: list[str]) -> None:
    """A single unencodable payload reaching retained state kills the digest for the
    rest of the run -- silently, which is the worst way for a diagnostics tool to fail.
    This was a real bug caught by check_diag_runtime.py, not a hypothetical."""
    diag = diag_source()
    if "local function sanitise(" not in diag:
        fail("Diag.lua no longer sanitises payloads before retaining them", failures)
        return
    for site, pattern in (
        # Anchored on its neighbours: a bare `data = sanitise(data)` is also what
        # writeSignal contains, so the loose pattern stayed satisfied after closeNode
        # lost its call -- a mutation test caught that, not review.
        ("closeNode", r"node\.reason = clip\(reason\)\n\tdata = sanitise\(data\)\n\tnode\.data = data"),
        ("writeMark", r"data = sanitise\(data\),"),
        ("writeSignal", r"data\.phase\) or nil\)\n\tdata = sanitise\(data\)"),
        ("handle.note", r"node\.notes\[tostring\(key\)\] = sanitise\(value\)"),
    ):
        if not re.search(pattern, diag):
            fail(f"{site} retains a caller payload without sanitising it", failures)


def check_loader_treats_diag_as_optional(failures: list[str]) -> None:
    """Every other download in the Loader aborts the client on failure, correctly. This
    one must not: a recorder that can kill the farm is a new way for the farm to die,
    and the reason it exists is that the farm keeps dying in ways nothing records."""
    loader = (ROOT / "Loader.lua").read_text(encoding="utf-8")
    block = re.search(r'trace\("Config\.lua executed"\)(.*?)\nend\n', loader, re.S)
    if not block or "Diag.lua" not in block.group(1):
        fail("the Loader no longer downloads Diag.lua right after Config.lua", failures)
        return
    body = block.group(1)
    if "downloadChunk(" in body:
        fail(
            "the Loader loads Diag.lua through downloadChunk, which raises on failure; "
            "a failed diagnostics download would abort the whole client",
            failures,
        )
    if re.search(r"\n\terror\(", body):
        fail("the Loader raises when Diag.lua fails to load", failures)
    if "UNAVAILABLE" not in body:
        fail(
            "the Loader does not trace the case where Diag.lua is missing; a capture must "
            "be able to distinguish 'no diagnostics folder' from 'the client never ran'",
            failures,
        )


def check_every_worker_feeds_the_recorder(failures: list[str]) -> None:
    """The existing [AO] milestones are the timeline. Feeding them from trace() means
    every one is captured without a second set of call sites drifting out of sync."""
    for name in WORKERS:
        source = (ROOT / name).read_text(encoding="utf-8")
        body = re.search(r"local function trace\(message, data\)(.*?)\nend\n", source, re.S)
        if not body:
            fail(f"{name} has no trace() helper", failures)
        elif "diag.mark(" not in body.group(1):
            fail(f"{name}'s trace() no longer feeds the recorder; its milestones are console-only",
                 failures)

    # The cross-controller edges. Without these a chain cannot cross a worker boundary,
    # and crossing one is the entire difference between a symptom and a cause.
    for name, task in (("FastMode.lua", "FastMode"), ("UnitProgression.lua", "UnitProgression")):
        source = (ROOT / name).read_text(encoding="utf-8")
        body = re.search(r"local function publishLifecycle\(status, details\)(.*?)\nend\n", source, re.S)
        if not body:
            fail(f"{name} has no publishLifecycle", failures)
        elif f'diag.signal("lifecycle.{task}"' not in body.group(1):
            fail(f"{name}'s publishLifecycle does not record a signal edge", failures)

    loader = (ROOT / "Loader.lua").read_text(encoding="utf-8")
    if 'diag.signal("lifecycle." .. taskName' not in loader:
        fail(
            "the Loader does not record a signal when a worker raises before publishing; "
            "that failure is the head of the most expensive chain in this project",
            failures,
        )


def check_steps_declare_their_evidence(failures: list[str]) -> None:
    """A step without an `expect` is a step judged on whether the function returned,
    which is exactly the assumption every bug in this project has hidden behind."""
    for name in WORKERS:
        source = (ROOT / name).read_text(encoding="utf-8")
        for match in re.finditer(r'diagStep\("([^"]+)"(.*?)\}\)', source, re.S):
            if "expect =" not in match.group(2):
                fail(
                    f"{name}: step {match.group(1)!r} declares no expected evidence, so its "
                    f"verdict can only reflect control flow",
                    failures,
                )
            if "deadline =" not in match.group(2):
                fail(
                    f"{name}: step {match.group(1)!r} has no deadline, so it falls back to the "
                    f"default and a legitimately long wait would be reported STUCK",
                    failures,
                )


def check_capture_stays_out_of_the_public_repo(failures: list[str]) -> None:
    """This repository is public and every client auto-executes Loader.lua from it.
    Digests carry Roblox UserIds; a committed capture is a permanent disclosure."""
    ignored = (ROOT / ".gitignore").read_text(encoding="utf-8")
    for pattern in ("AnimeOriginDiag/", "digest_*.json", "events_*.jsonl"):
        if pattern not in ignored:
            fail(f".gitignore does not exclude {pattern}; a capture could be committed", failures)

    diag = (ROOT / "Diag.lua").read_text(encoding="utf-8")
    for secret in ("ghp_", "github_pat_", "Authorization", "token ="):
        if secret in diag:
            fail(f"Diag.lua contains {secret!r}; nothing the Loader downloads may carry a credential",
                 failures)


def main() -> int:
    failures: list[str] = []
    check_folder_is_not_state(failures)
    check_recorder_cannot_raise(failures)
    check_everything_is_bounded(failures)
    check_payloads_are_sanitised(failures)
    check_loader_treats_diag_as_optional(failures)
    check_every_worker_feeds_the_recorder(failures)
    check_steps_declare_their_evidence(failures)
    check_capture_stays_out_of_the_public_repo(failures)

    if failures:
        print(f"\n[DiagContract] {len(failures)} check(s) failed")
        return 1
    print("[DiagContract][PASS] the recorder is bounded, cannot raise into game code, "
          "writes only to its own deletable folder, and every step declares its evidence")
    return 0


if __name__ == "__main__":
    sys.exit(main())
