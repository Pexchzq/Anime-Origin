#!/usr/bin/env python3
"""Replay the summon-eligibility rule against every real bootstrap state file.

The rule under test, mirroring FastMode.classifyAccount:

  * an account is classified once, on the first run that ever sees it, and the
    verdict is persisted as accountClass;
  * only TotalSummons == newAccountTotalSummons means NEW;
  * maximumSummonBatches is the spending ceiling, never an eligibility test;
  * a NEW account whose bootstrap reached status "complete" never re-opens.

A single farming account classified NEW is a RED: that is the defect that spent
1500 Gems on UserId 11540208855 (startTotalSummons=150, targetBatches=3).

    python3 Tests/check_summon_policy.py
    ANIME_ORIGIN_RUNTIME=~/Desktop/VoltLogs/AnimeOrigin python3 Tests/check_summon_policy.py
"""

from __future__ import annotations

import sys

from _artifacts import Account, discover_users

NEW_ACCOUNT_TOTAL_SUMMONS = 0    # Config.fastGems.bootstrap.newAccountTotalSummons
MAXIMUM_SUMMON_BATCHES = 20      # spending ceiling: 20 x 10 = 200 summons
SUMMON_BATCH_COST = 500
FORCED_USER_IDS: set[str] = set()  # mirrors Config.forceBootstrapUserIds


def classify(user: str, state: dict) -> tuple[str, str]:
    persisted = state.get("accountClass")
    if persisted in ("NEW", "FARMING"):
        return persisted, "persisted"
    if user in FORCED_USER_IDS:
        return "NEW", "forced by Config.forceBootstrapUserIds"
    total = state.get("finishedTotalSummons")
    if total is None:
        total = state.get("startTotalSummons") or 0
    if total == NEW_ACCOUNT_TOTAL_SUMMONS:
        return "NEW", f"TotalSummons=={total} on first sight"
    return "FARMING", f"TotalSummons=={total} on first sight"


def may_summon(state: dict, account_class: str) -> tuple[bool, str]:
    if account_class == "FARMING":
        return False, "farming account"
    if state.get("status") == "complete":
        return False, "bootstrap already completed"
    return True, "new account with an unfinished bootstrap"


def main() -> int:
    failures: list[str] = []
    rows: list[tuple] = []

    for user in discover_users():
        state = Account(user).json("FastModeBootstrap", latest=False)
        if not state:
            continue
        total = state.get("finishedTotalSummons") or state.get("startTotalSummons") or 0
        gems = state.get("finishedGems") or 0
        account_class, reason = classify(user, state)
        allowed, why = may_summon(state, account_class)
        would_spend = min(gems // SUMMON_BATCH_COST, MAXIMUM_SUMMON_BATCHES) * SUMMON_BATCH_COST if allowed else 0
        rows.append((user, total, gems, account_class, allowed, would_spend, why))

        if account_class == "NEW" and total > NEW_ACCOUNT_TOTAL_SUMMONS and user not in FORCED_USER_IDS:
            failures.append(f"user={user} has {total} summons but was classified NEW ({reason})")
        if allowed and total > NEW_ACCOUNT_TOTAL_SUMMONS and user not in FORCED_USER_IDS:
            failures.append(f"user={user} has {total} summons and would still spend {would_spend} Gems")
        target = state.get("targetBatches") or 0
        if target > MAXIMUM_SUMMON_BATCHES:
            failures.append(f"user={user} has targetBatches={target}, above the {MAXIMUM_SUMMON_BATCHES} ceiling")

    print(f"{'UserId':<14}{'Summons':>9}{'Gems':>8}  {'Class':<9}{'MaySummon':<11}{'WouldSpend':>11}  why")
    print("-" * 92)
    for user, total, gems, klass, allowed, spend, why in rows:
        print(f"{user:<14}{total:>9}{gems:>8}  {klass:<9}{str(allowed):<11}{spend:>11}  {why}")
    print("-" * 92)

    if not rows:
        print("no bootstrap state files found; nothing to verify")
        return 0

    if failures:
        for failure in failures:
            print(f"[RED] {failure}")
        return 1

    print(f"[GREEN] {len(rows)} account(s) checked; no farming account can spend Gems")
    return 0


if __name__ == "__main__":
    sys.exit(main())
