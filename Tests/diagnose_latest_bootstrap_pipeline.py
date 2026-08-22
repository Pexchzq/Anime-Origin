#!/usr/bin/env python3
"""Diagnose the lobby bootstrap phase (FastMode -> InGameSettings -> UnitProgression -> route).

Reads the real per-UserId artifacts. Every check below can go RED on data the
game actually produced; none of them inspect the Lua source.

    python3 Tests/diagnose_latest_bootstrap_pipeline.py                # all accounts
    python3 Tests/diagnose_latest_bootstrap_pipeline.py --since 30     # active in last 30 min
    python3 Tests/diagnose_latest_bootstrap_pipeline.py --user 1155... # one account
"""

from __future__ import annotations

import argparse
import sys

from _artifacts import Account, Finding, report, select_accounts

SUMMON_BATCH_COST = 500     # Config.fastGems.bootstrap.summonBatchCost
GOLD_STRANDED_MIN = 1000    # below this, an empty GoldShop plan is not worth flagging


def check_fastmode(account: Account, out: list[Finding]) -> None:
    state = account.json("FastModeBootstrap", latest=False)
    lines = account.log("FastModeBootstrap")

    errors = [line for line in lines if line.tag == "ERROR"]
    for line in errors:
        out.append(Finding("RED", "FASTMODE_ERROR", account.user,
                           f"FastMode aborted: {line.message}", {"seq": line.seq}))

    if state is None:
        if lines:
            out.append(Finding("RED", "FASTMODE_NO_STATE", account.user,
                               "FastMode wrote a log but no state file; bootstrap cannot resume."))
        return

    status = state.get("status")
    gems = state.get("finishedGems")
    verified = state.get("verifiedBatches") or 0
    target = state.get("targetBatches") or 0
    reason = state.get("lastReason") or ""

    if status not in ("complete", None):
        out.append(Finding("RED", "FASTMODE_INCOMPLETE", account.user,
                           f"FastMode state is '{status}' ({reason}); bootstrap never finished.",
                           {"verifiedBatches": verified, "targetBatches": target}))

    if state.get("uncertainBatch"):
        out.append(Finding("RED", "FASTMODE_UNCERTAIN_BATCH", account.user,
                           "A summon batch was fired but never proven by Gems+TotalSummons.",
                           state["uncertainBatch"]))

    # FastMode is the only module in the codebase that spends Gems. Once it has
    # gated itself to claims-only, any remaining Gems can never be spent again.
    gated = "claims" in reason.lower() or any(
        line.tag == "GATE" and "Existing account detected" in line.message for line in lines
    )
    if gated and isinstance(gems, (int, float)) and gems >= SUMMON_BATCH_COST:
        out.append(Finding("RED", "FASTMODE_GEMS_STRANDED", account.user,
                           f"{int(gems)} Gems are unspendable: the claims-only gate disabled summons "
                           f"and no other module spends Gems.",
                           {"finishedGems": gems, "batchCost": SUMMON_BATCH_COST,
                            "affordableBatches": int(gems // SUMMON_BATCH_COST),
                            "lastReason": reason}))


def check_settings(account: Account, out: list[Finding]) -> None:
    data = account.json("InGameSettings")
    lines = account.log("InGameSettings")

    for line in (line for line in lines if line.tag == "ERROR"):
        out.append(Finding("RED", "SETTINGS_ERROR", account.user,
                           f"InGameSettings aborted: {line.message}", {"seq": line.seq}))

    if data is None:
        return

    unresolved = data.get("unresolved") or []
    if unresolved:
        out.append(Finding("RED", "SETTINGS_UNRESOLVED", account.user,
                           f"{len(unresolved)} setting(s) never reached the configured value.",
                           {"unresolved": unresolved}))

    expected = data.get("expectedSpeedMultiplier")
    if expected:
        applied = [entry.get("value") for entry in (data.get("speedAfter") or [])]
        if data.get("speedVerified") is False:
            out.append(Finding("RED", "SETTINGS_SPEED_UNVERIFIED", account.user,
                               f"GameSpeed {expected}x was requested but never verified.",
                               {"speedAfter": data.get("speedAfter")}))
        elif applied and all(value != expected for value in applied):
            out.append(Finding("RED", "SETTINGS_SPEED_WRONG", account.user,
                               f"GameSpeed is {applied} but Config expects {expected}.",
                               {"speedBefore": data.get("speedBefore")}))

    for action in data.get("actions") or []:
        if action.get("verified") is False:
            out.append(Finding("RED", "SETTINGS_TOGGLE_UNVERIFIED", account.user,
                               f"Setting '{action.get('key')}' did not become "
                               f"{action.get('desired')} (was {action.get('before')}).", action))


def check_unit_progression(account: Account, out: list[Finding]) -> None:
    data = account.json("UnitProgression")
    lines = account.log("UnitProgression")

    for line in (line for line in lines if line.tag == "ERROR"):
        out.append(Finding("RED", "UNIT_ERROR", account.user,
                           f"UnitProgression aborted: {line.message}", {"seq": line.seq}))

    if data is None:
        return

    status = data.get("status")
    if status == "FAILED":
        out.append(Finding("RED", "UNIT_FAILED", account.user,
                           f"UnitProgression FAILED at {data.get('failedStage')}: {data.get('reason')}"))

    shop = ((data.get("plans") or {}).get("shop")) or {}
    gold = (data.get("evidence") or {}).get("gold")
    missing = shop.get("missingExpBeforePurchase") or 0
    if shop.get("skipped") and isinstance(gold, (int, float)) and gold >= GOLD_STRANDED_MIN and missing > 0:
        out.append(Finding("RED", "UNIT_SHOP_SKIPPED_WITH_GOLD", account.user,
                           f"GoldShop plan was empty while holding {int(gold)} Gold and still "
                           f"missing {int(missing)} EXP; the run still reported {status}.",
                           {"skipped": shop.get("skipped"), "gold": gold, "missingExp": missing}))

    for action in data.get("actions") or []:
        if action.get("verified") is False:
            out.append(Finding("WARN", "UNIT_ACTION_UNVERIFIED", account.user,
                               f"{action.get('type')} action was not confirmed by the server.", action))


def check_route_handoff(account: Account, out: list[Finding]) -> None:
    unit = account.json("UnitProgression")
    persisted = account.json("MainRoute", latest=False)
    live = account.json("MainRoute")

    if unit and persisted:
        selected_from = persisted.get("selectedFromJobId")
        if selected_from and unit.get("jobId") and selected_from != unit.get("jobId"):
            out.append(Finding("WARN", "ROUTE_JOB_DRIFT", account.user,
                               "The persisted route was chosen in a different lobby session than the "
                               "one that ran UnitProgression.",
                               {"unitProgressionJobId": unit.get("jobId"),
                                "routeSelectedFromJobId": selected_from}))

    if live is None:
        if unit is not None:
            out.append(Finding("RED", "ROUTE_NEVER_STARTED", account.user,
                               "Bootstrap workers finished but Main never produced a route report."))
        return

    if live.get("status") == "FAILED" and not live.get("actions"):
        out.append(Finding("RED", "ROUTE_GATE_BLOCKED", account.user,
                           f"Main stopped before any route action: {live.get('lastReason')}"))

    # Infinite is a distinct mode; persisting it as Story/Infinite makes the target
    # unmatchable by anything that compares mode strings.
    target = (persisted or {}).get("target") or {}
    if str(target.get("act")).lower() == "infinite" and str(target.get("mode")).lower() != "infinite":
        out.append(Finding("RED", "ROUTE_INFINITE_MODE_MISLABELLED", account.user,
                           f"Infinite route persisted as mode='{target.get('mode')}' "
                           f"act='{target.get('act')}'.", {"target": target}))


def check_stale_playerdata(account: Account, out: list[Finding]) -> None:
    """Remotes the server accepted while our PlayerData copy never moved.

    This is a dead reference, not a rejected request: the server answered "Code
    Redeemed!" while Gems stayed at zero, because the run was reading a detached
    warm-up PlayerData table instead of the live one.

    The trigger is freshly redeemed codes specifically. An unverified daily or
    battlepass claim is ordinary -- an account that already claimed today gets a
    genuine refusal (11540208855: the wheel returned nil and LastClaimTime was
    already set). A code the server had NOT already recorded and answers "Code
    Redeemed!" to must move Gems, so several of those moving nothing, with no
    other action verifying either, can only mean the table being read is dead.
    """
    state = account.json("FastModeBootstrap", latest=False) or {}
    results = state.get("claimResults") or {}
    attempted: list[str] = []
    verified: list[str] = []

    codes = results.get("codes")
    if isinstance(codes, dict):
        for code, record in codes.items():
            if not isinstance(record, dict) or record.get("status") != "redeemed":
                continue
            attempted.append(f"code:{code}")
            if record.get("verified"):
                verified.append(f"code:{code}")

    for key in ("dailyReward", "dailyWheel", "battlepass", "quests"):
        record = results.get(key)
        if not isinstance(record, dict) or not record.get("attempted"):
            continue
        attempted.append(key)
        if record.get("verified"):
            verified.append(key)

    fresh_codes = [name for name in attempted if name.startswith("code:")]
    if len(fresh_codes) >= 3 and not verified:
        out.append(Finding("RED", "STALE_PLAYERDATA", account.user,
                           f"{len(attempted)} server-accepted action(s) and not one changed the "
                           f"PlayerData this run was reading; the reference is detached from the "
                           f"live table, so Gems and TotalSummons are being read from a dead copy.",
                           {"attempted": len(attempted), "freshlyRedeemedCodes": len(fresh_codes),
                            "verified": 0,
                            "gemsAfterClaims": state.get("gemsAfterClaims"),
                            "sample": attempted[:6]}))


def check_vacuous_completion(account: Account, out: list[Finding]) -> None:
    """A bootstrap sealed as complete that never summoned anything.

    verifiedBatches == 0 on an account still at zero summons is not a finished
    bootstrap; it is a run that gave up on bad data and then locked itself out,
    because a completed bootstrap never re-opens.
    """
    state = account.json("FastModeBootstrap", latest=False) or {}
    if state.get("status") != "complete":
        return
    batches = state.get("verifiedBatches") or 0
    total = state.get("finishedTotalSummons")
    if total is None:
        total = state.get("startTotalSummons") or 0
    if batches == 0 and total == 0:
        out.append(Finding("RED", "BOOTSTRAP_SEALED_EMPTY", account.user,
                           "Bootstrap is recorded complete with zero verified batches on an "
                           "account that still has zero summons; it will start every match with "
                           "an empty inventory and never re-open on its own.",
                           {"verifiedBatches": batches, "targetBatches": state.get("targetBatches"),
                            "totalSummons": total, "gemsAfterClaims": state.get("gemsAfterClaims")}))


def check_stage_entry(account: Account, out: list[Finding]) -> None:
    """Pod walks the server never acknowledged at all.

    Entering a Story Pod is supposed to make the server emit MapSelect, and every
    later step (AfterMapSelect, UpdatePlayersInside, TeleportGui) is logged as
    MAP_EVENT too. Portal failures with not one MAP_EVENT of any kind means the
    server never registered the player entering: the walk is not losing a race,
    it is not landing. In the captured run this was 100% of accounts with zero
    clears, while an established account on the same build played to Wave 6.
    """
    lines = account.log("MainRoute")
    if not lines:
        return
    failures = [line for line in lines
                if line.tag == "PORTAL" and "No available Story Pod" in line.message]
    if not failures:
        return
    if any(line.tag == "MAP_EVENT" for line in lines):
        return

    state = account.json("MainRoute", latest=False) or {}
    out.append(Finding("RED", "STAGE_ENTRY_BLOCKED", account.user,
                       f"{len(failures)} Pod walk(s) failed and the server never emitted a single "
                       f"MapSelect; stage entry is being refused outright, not merely timing out.",
                       {"portalFailures": len(failures),
                        "matchEpoch": state.get("matchEpoch"),
                        "everEnteredAStage": bool(state.get("matchEpoch")),
                        "lastPortalError": failures[-1].get("error")}))


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--user", action="append", help="restrict to this UserId (repeatable)")
    parser.add_argument("--since", type=float, help="only accounts whose artifacts changed in the last N minutes")
    args = parser.parse_args()

    accounts = select_accounts(args.user, args.since)
    findings: list[Finding] = []
    for account in accounts:
        check_fastmode(account, findings)
        check_stale_playerdata(account, findings)
        check_vacuous_completion(account, findings)
        check_settings(account, findings)
        check_unit_progression(account, findings)
        check_route_handoff(account, findings)
        check_stage_entry(account, findings)

    return report("BOOTSTRAP PIPELINE", findings, accounts)


if __name__ == "__main__":
    sys.exit(main())
