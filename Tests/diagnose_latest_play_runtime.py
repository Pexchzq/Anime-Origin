#!/usr/bin/env python3
"""Diagnose the in-match phase (Main route monitor + AutoPlay) from real logs.

    python3 Tests/diagnose_latest_play_runtime.py                # all accounts
    python3 Tests/diagnose_latest_play_runtime.py --since 30     # active in last 30 min
    python3 Tests/diagnose_latest_play_runtime.py --user 1155... # one account
"""

from __future__ import annotations

import argparse
import sys
from collections import Counter

from _artifacts import Account, Finding, report, select_accounts

REJECT_STORM_THRESHOLD = 8      # same slot rejected this many times in one match
LOCKED_SLOT_REPROBE_MAX = 2     # re-probing a known-locked slot beyond this is waste
WAIT_STALL_THRESHOLD = 6        # consecutive "cannot afford" waits while holding the money
EARLY_DEFEAT_WAVE = 15


def check_route(account: Account, out: list[Finding]) -> None:
    lines = account.log("MainRoute")

    for line in lines:
        if line.tag == "ERROR":
            out.append(Finding("RED", "ROUTE_ERROR", account.user,
                               f"Main aborted: {line.message}", {"seq": line.seq}))
        if line.tag == "VERIFY" and "RestartGame was not confirmed" in line.message:
            out.append(Finding("RED", "RESTART_UNCONFIRMED", account.user,
                               "RestartGame was fired but never confirmed, and the code will not "
                               "retry it in this match; the run keeps playing past the restart wave.",
                               {"seq": line.seq, **(line.data or {})}))

    defeats = []
    for line in lines:
        if line.tag != "END" or not isinstance(line.data, dict):
            continue
        if line.data.get("success") is False:
            waves = int(line.data.get("wavesCompleted") or 0)
            if waves < EARLY_DEFEAT_WAVE:
                defeats.append(waves)
    if defeats:
        out.append(Finding("WARN", "EARLY_DEFEAT", account.user,
                           f"{len(defeats)} match(es) lost before wave {EARLY_DEFEAT_WAVE}.",
                           {"wavesCompleted": defeats}))


def check_placements(account: Account, out: list[Finding]) -> None:
    lines = account.log("AutoPlay")

    for line in (line for line in lines if line.tag == "ERROR"):
        out.append(Finding("RED", "AUTOPLAY_ERROR", account.user,
                           f"AutoPlay aborted: {line.message}", {"seq": line.seq}))

    rejects: Counter = Counter()
    for line in lines:
        if line.tag != "RETRY" or not line.get("rejectedImmediately"):
            continue
        rejects[(line.get("matchEpoch"), line.get("slot"), line.get("identifier"))] += 1
    for (epoch, slot, unit), count in rejects.most_common():
        if count >= REJECT_STORM_THRESHOLD:
            out.append(Finding("RED", "PLACEMENT_REJECT_STORM", account.user,
                               f"{unit} was rejected at {slot} {count} times in match epoch {epoch} "
                               f"without the loop giving up on that slot.",
                               {"matchEpoch": epoch, "slot": slot, "identifier": unit, "count": count}))


def check_locked_slot_probes(account: Account, out: list[Finding]) -> None:
    lines = account.log("AutoPlay")
    data = account.json("AutoPlay") or {}
    known_locked = data.get("firstLockedOrRejectedSlot")
    if not known_locked:
        return

    probes = [line for line in lines
              if line.tag == "SLOTS" and "locked or server-rejected" in line.message]
    if len(probes) > LOCKED_SLOT_REPROBE_MAX:
        out.append(Finding("WARN", "LOCKED_SLOT_REPROBED", account.user,
                           f"Slot {known_locked} is already known locked, yet the loadout builder "
                           f"re-probed it {len(probes)} times.",
                           {"firstLockedOrRejectedSlot": known_locked, "probes": len(probes)}))


def check_afford_stall(account: Account, out: list[Finding]) -> None:
    """"No verified action is affordable yet" while the payload shows enough money."""
    lines = account.log("AutoPlay")

    misleading = []
    run = 0
    longest_run = 0
    for line in lines:
        if line.tag != "WAIT" or "affordable" not in line.message:
            run = 0
            continue
        run += 1
        longest_run = max(longest_run, run)
        money = line.get("money")
        cost = line.get("waitingCost")
        if isinstance(money, (int, float)) and isinstance(cost, (int, float)) and money >= cost:
            misleading.append({"seq": line.seq, "money": money, "waitingCost": cost,
                               "damagePlaced": line.get("damagePlaced"),
                               "damageCapacity": line.get("damageCapacity")})

    if misleading:
        out.append(Finding("RED", "WAIT_WHILE_AFFORDABLE", account.user,
                           f"{len(misleading)} wait(s) claimed nothing was affordable while the "
                           f"payload showed enough money; the loop is blocked for another reason.",
                           {"samples": misleading[:3], "total": len(misleading)}))
    elif longest_run >= WAIT_STALL_THRESHOLD:
        out.append(Finding("WARN", "LONG_AFFORD_STALL", account.user,
                           f"AutoPlay waited {longest_run} times in a row without placing anything; "
                           f"the message cannot distinguish 'broke' from 'nothing left to do'.",
                           {"longestRun": longest_run}))


WORKER_ABANDONED_MINUTES = 5


def check_worker_outlived(account: Account, out: list[Finding]) -> None:
    """One controller died while the others kept writing.

    The Loader starts each file once with task.spawn+pcall, so a controller that
    errors is gone for the session while its siblings carry on. On disk that shows
    up as one artifact frozen minutes behind the others -- the cheapest possible
    detector for a whole family of silent stalls.
    """
    stamps = {}
    for prefix in ("AutoPlay", "MainRoute"):
        path = account.path(f"{prefix}_{account.user}_latest.log")
        if path.exists():
            stamps[prefix] = path.stat().st_mtime
    if len(stamps) < 2:
        return

    newest_name = max(stamps, key=lambda k: stamps[k])
    for name, stamp in stamps.items():
        if name == newest_name:
            continue
        behind = (stamps[newest_name] - stamp) / 60.0
        if behind < WORKER_ABANDONED_MINUTES:
            continue
        lines = account.log(name)
        last = lines[-1] if lines else None
        out.append(Finding("RED", "WORKER_ABANDONED", account.user,
                           f"{name} stopped writing {behind:.0f} min before {newest_name} did; "
                           f"it died while the rest of the session kept running.",
                           {"stoppedBehindMinutes": round(behind, 1),
                            "lastTag": last.tag if last else None,
                            "lastMessage": (last.message[:160] if last else None)}))


def check_vote_window(account: Account, out: list[Finding]) -> None:
    """AutoPlay parked on the unit-selection screen waiting for a StartWaveVote."""
    lines = account.log("AutoPlay")
    if not lines:
        return

    recovered = [line for line in lines
                 if line.tag == "RECOVER" and "StartWaveVote" in line.message]
    if recovered:
        out.append(Finding("WARN", "MISSED_VOTE_RECOVERED", account.user,
                           f"AutoPlay had to assume {len(recovered)} StartWaveVote(s): the event was "
                           f"delivered before the listener attached, most likely while the Loader was "
                           f"still downloading after a place teleport.",
                           {"occurrences": len(recovered), **(recovered[-1].data or {})}))

    # Nothing after the deferral means the recovery never ran or never fired.
    last_defer = None
    for index, line in enumerate(lines):
        if line.tag == "DEFER" and "StartWaveVote arrives" in line.message:
            last_defer = index
    if last_defer is None:
        return

    after = [line for line in lines[last_defer + 1:]
             if line.tag in ("READY", "VERIFY", "PLACE", "TEAM", "RECOVER")]
    if not after:
        data = account.json("AutoPlay") or {}
        out.append(Finding("RED", "VOTE_NEVER_ARRIVED", account.user,
                           "AutoPlay deferred waiting for StartWaveVote and never voted, placed, or "
                           "recovered afterwards; the run is parked on the unit-selection screen.",
                           {"status": data.get("status"), "reason": data.get("reason"),
                            "deferAtLine": lines[last_defer].seq,
                            "linesAfterDefer": len(lines) - last_defer - 1}))


def check_match_progress(account: Account, out: list[Finding]) -> None:
    data = account.json("AutoPlay") or {}
    gameplay = data.get("gameplay") or {}
    if not gameplay:
        return
    epoch = gameplay.get("matchEpoch")
    placed = [line for line in account.log("AutoPlay")
              if line.tag == "VERIFY" and "placement confirmed" in line.message]
    if epoch and int(epoch) >= 1 and not placed:
        out.append(Finding("RED", "NO_VERIFIED_PLACEMENT", account.user,
                           f"Match epoch {epoch} started but not a single placement was ever "
                           f"confirmed by the server.",
                           {"money": gameplay.get("money"), "status": data.get("status"),
                            "reason": data.get("reason")}))


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--user", action="append", help="restrict to this UserId (repeatable)")
    parser.add_argument("--since", type=float, help="only accounts whose artifacts changed in the last N minutes")
    args = parser.parse_args()

    accounts = select_accounts(args.user, args.since)
    findings: list[Finding] = []
    for account in accounts:
        check_route(account, findings)
        check_placements(account, findings)
        check_locked_slot_probes(account, findings)
        check_afford_stall(account, findings)
        check_vote_window(account, findings)
        check_worker_outlived(account, findings)
        check_match_progress(account, findings)

    return report("PLAY RUNTIME", findings, accounts)


if __name__ == "__main__":
    sys.exit(main())
