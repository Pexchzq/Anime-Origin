#!/usr/bin/env python3
"""Static gate for the quest claim path.

`ClaimAllQuests` was never fired once, on any account, in any captured run. The
cause was a precondition that could not be satisfied: claimAllQuests returned
early unless it found a quest record with `Claimable == true`, and `Claimable` is
written by the quest UI when it renders rather than replicated by the server. This
project reads PlayerData without ever opening UI, so the flag was false in 396 of
396 captured records while `Claimed` moved independently -- all eight captured
bootstrap states recorded `attempted: false` with `claimable: 0`.

The verification suffered from the same assumption: `claimable < before.claimable`
is `0 < 0` for every account, so even a successful claim would have been reported
as unproven.

Both halves are asserted here because they fail the same way -- silently, with a
state file that looks healthy -- and because the fix is one this file's own history
shows is easy to reintroduce while "tightening" the guard.
"""

from __future__ import annotations

import pathlib
import re
import sys


ROOT = pathlib.Path(__file__).resolve().parent.parent


def fail(message: str, failures: list[str]) -> None:
    failures.append(message)
    print(f"[QuestClaimGate][FAIL] {message}")


def read_claim_function() -> str | None:
    source = (ROOT / "FastMode.lua").read_text(encoding="utf-8")
    body = re.search(r"local function claimAllQuests\(\)(.*?)\nend\n", source, re.S)
    return body.group(1) if body else None


def check_no_claimable_precondition(failures: list[str]) -> None:
    """The remote must be reachable. Nothing may return early on a Claimable count:
    firing costs nothing here (the server no-ops when no reward is due, unlike a
    summon, which spends Gems), so readiness is proven after the call, not before."""
    body = read_claim_function()
    if body is None:
        fail("claimAllQuests was not found in FastMode.lua", failures)
        return

    fire = body.find('FireServer("ClaimAllQuests")')
    if fire < 0:
        fail("claimAllQuests no longer fires ClaimAllQuests", failures)
        return

    # Any `return` that precedes the FireServer and sits under a claimable test is
    # the defect. `available` is a legitimate guard: without the table there is
    # nothing to verify against afterwards.
    preamble = body[:fire]
    for match in re.finditer(r"if[^\n]*claimable[^\n]*then", preamble):
        fail(
            f"claimAllQuests still gates the remote on a claimable count "
            f"(`{match.group(0).strip()}`); Claimable is a UI-written flag and was "
            f"false in every captured record, so this blocks 100% of claims",
            failures,
        )


def check_verification_uses_claimed(failures: list[str]) -> None:
    """`Claimed` is server-written and is the field that actually moved in the
    captures. A predicate resting only on `claimable` can never become true."""
    body = read_claim_function()
    if body is None:
        return

    fire = body.find('FireServer("ClaimAllQuests")')
    proof = body[fire:] if fire >= 0 else body

    if "claimed >" not in proof.replace(" ", " "):
        fail(
            "the post-claim predicate does not compare `claimed`; verification would "
            "rest on a flag that is false on every account",
            failures,
        )


def check_reader_reports_both_fields(failures: list[str]) -> None:
    """readQuestClaimState must keep reporting `claimed` and `records` alongside
    `claimable`. They are what distinguishes "nothing was due" from "the server
    refused", and a capture without them cannot tell those apart."""
    source = (ROOT / "FastMode.lua").read_text(encoding="utf-8")
    body = re.search(r"local function readQuestClaimState\(\)(.*?)\nend\n", source, re.S)
    if not body:
        fail("readQuestClaimState was not found", failures)
        return
    for field in ("claimable", "claimed", "records"):
        if field not in body.group(1):
            fail(f"readQuestClaimState no longer reports `{field}`", failures)


def check_stage_loop_is_isolated(failures: list[str]) -> None:
    """Quests complete during a match, and Infinite restarts with RestartGame without
    ever passing through the lobby -- so a stage-side claim loop is the only place
    those get collected. It shares this file with the lobby bootstrap, which makes
    three collisions possible, each of which costs a whole account's run:

    - the log file is truncated on load, so a stage run must not use the lobby name;
    - the bootstrap state file holds summon progress and must never be written from
      a stage, nor be able to block the loop when it is corrupt;
    - main's bootstrap gate reads the lifecycle entry, so SKIPPED has to be published
      before the loop starts rather than after it ends.
    """
    source = (ROOT / "FastMode.lua").read_text(encoding="utf-8")

    if "stageQuestOnly" not in source:
        fail("FastMode.lua has no stage quest path", failures)
        return

    if "FastModeStageQuests_" not in source:
        fail(
            "the stage quest loop shares the lobby log file name; loading truncates "
            "it, so a stage entry would erase the lobby bootstrap log",
            failures,
        )

    if not re.search(r"local state = not stageQuestOnly and loadState\(\)", source):
        fail(
            "the stage path still loads bootstrap state; a corrupt state file would "
            "block quest claiming in a stage, which does not depend on it",
            failures,
        )

    loop = re.search(r"local function runStageQuestLoop\(\)(.*?)\nend\n", source, re.S)
    if not loop:
        fail("runStageQuestLoop was not found", failures)
        return
    if "saveState" in loop.group(1):
        fail(
            "the stage quest loop writes bootstrap state; summon progress belongs to "
            "the lobby run alone",
            failures,
        )
    # Unbounded growth is the failure this project keeps having; a loop that logs
    # every no-op for a whole night reintroduces it.
    if 'log("STAGE_QUESTS", "Claimed quests during the stage."' not in loop.group(1):
        fail(
            "the stage quest loop does not log on a successful claim, or logs "
            "unconditionally; it must log on change only",
            failures,
        )

    # SKIPPED must be published on the stage branch itself, not deferred.
    branch = re.search(r"if not isLobbyPlace then(.*?)\nend\n", source, re.S)
    if branch and 'publishLifecycle("SKIPPED"' not in branch.group(1):
        fail(
            "the stage branch no longer publishes SKIPPED up front; main's bootstrap "
            "gate would see a worker that never reported",
            failures,
        )


def main() -> int:
    failures: list[str] = []
    check_no_claimable_precondition(failures)
    check_verification_uses_claimed(failures)
    check_reader_reports_both_fields(failures)
    check_stage_loop_is_isolated(failures)

    if failures:
        print(f"\n[QuestClaimGate] {len(failures)} check(s) failed")
        return 1
    print(
        "[QuestClaimGate][PASS] ClaimAllQuests is reachable and proven from the "
        "server-written Claimed field"
    )
    return 0


if __name__ == "__main__":
    sys.exit(main())
