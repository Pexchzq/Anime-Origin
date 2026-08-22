#!/usr/bin/env python3
"""Static regression gate for the live PlayerData wrapper and prefix repair."""

from __future__ import annotations

import pathlib
import sys


AUTO_PLAY = pathlib.Path("/Users/siwakantalasak/Desktop/Anime Origin/AutoPlay.lua")


def main() -> int:
    source = AUTO_PLAY.read_text(encoding="utf-8")
    required = {
        "local playerDataContainer": "live PlayerData container is not cached",
        'rawget(playerDataContainer, "PlayerData")': "cached wrapper is not dereferenced live",
        "nestedCandidate": "nested .PlayerData candidates are not preferred",
        "actual ~= nil and actual ~= desired[slot].uuid": "required-slot repair still rebuilds a correct prefix",
        'mode = "fill-missing-slots"': "missing slots are not filled in place",
    }
    failures = []
    for needle, message in required.items():
        if needle not in source:
            failures.append(message)
            print(f"[AutoPlayLiveData][FAIL] {message}")
    if failures:
        return 1
    print("[AutoPlayLiveData][PASS] live wrapper and in-place prefix repair are present")
    return 0


if __name__ == "__main__":
    sys.exit(main())
