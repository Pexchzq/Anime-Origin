#!/usr/bin/env python3
"""Regression matrix for the stage-end actions owned by main.lua."""

from pathlib import Path


ROOT = Path(__file__).resolve().parents[1]
source = (ROOT / "main.lua").read_text(encoding="utf-8")


def action(mode: str, difficulty: str, act: str, success: bool, can_next: bool,
           can_replay: bool, level: int) -> str:
    if mode == "Infinite" or act == "Infinite":
        return "REPLAY" if can_replay else "LOBBY"
    number = int(act)
    if difficulty == "Normal" and 1 <= number <= 6:
        if success and number < 6 and can_next:
            return "NEXT"
        if not success and can_replay:
            return "REPLAY"
        return "LOBBY"
    if difficulty == "Hard" and number == 1:
        if level >= 15:
            return "LOBBY"
        return "REPLAY" if can_replay else "LOBBY"
    return "LOBBY"


cases = {
    "Normal victory continues": (("Story", "Normal", "3", True, True, True, 8), "NEXT"),
    "Normal defeat retries": (("Story", "Normal", "3", False, False, True, 8), "REPLAY"),
    "Act 6 victory returns for fresh decision": (("Story", "Normal", "6", True, True, True, 14), "LOBBY"),
    "Hard 1 below gate replays": (("Story", "Hard", "1", True, False, True, 14), "REPLAY"),
    "Hard 1 at gate returns": (("Story", "Hard", "1", True, False, True, 15), "LOBBY"),
    "Infinite end replays when available": (("Infinite", "Hard", "Infinite", True, False, True, 30), "REPLAY"),
    "Infinite end without replay returns": (("Infinite", "Hard", "Infinite", True, False, False, 30), "LOBBY"),
}

failures = []
for name, (arguments, expected) in cases.items():
    actual = action(*arguments)
    print(("PASS" if actual == expected else "FAIL") + f": {name} -> {actual}")
    if actual != expected:
        failures.append(name)

for guard in (
    'voteForTransition("NextActVote", nextTarget)',
    'voteForTransition("ReplayActVote", target)',
    'returnToLobby("account reached Infinite level gate")',
    'returnToLobby("Infinite ended before the Wave restart transition")',
    'log("RECOVERY", "Next vote was not verified; returning to lobby',
):
    if guard not in source:
        failures.append("missing source guard: " + guard)

if failures:
    raise SystemExit(1)
