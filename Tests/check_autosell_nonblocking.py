#!/usr/bin/env python3
"""Regression contract for executors whose live AutoSell cache is unverifiable."""

from pathlib import Path


ROOT = Path(__file__).resolve().parents[1]
SETTINGS = (ROOT / "InGameSettings.lua").read_text(encoding="utf-8")
FAST_MODE = (ROOT / "FastMode.lua").read_text(encoding="utf-8")
PROGRESSION = (ROOT / "UnitProgression.lua").read_text(encoding="utf-8")


def require(condition: bool, message: str) -> None:
    if not condition:
        raise AssertionError(message)


# AutoSell is an optional inventory convenience. Executors such as Voit may send
# the toggle successfully without exposing the same mutable PlayerData cache.
require(
    "AutoSell verification is degraded; background retry will continue." in SETTINGS,
    "InGameSettings must downgrade an unverifiable AutoSell toggle instead of failing",
)
require(
    'fail("VERIFY", "AutoSell' not in SETTINGS,
    "InGameSettings still hard-fails when the AutoSell cache cannot be verified",
)

# The first summon is the recovery path that creates usable units. It must never
# be held hostage by an optional AutoSell confirmation.
require(
    "AutoSell was not verified; summon batches will continue." in FAST_MODE,
    "FastMode must explicitly continue summoning after bounded AutoSell verification",
)
require(
    'fail("AUTO_SELL"' not in FAST_MODE,
    "FastMode still turns an AutoSell verification miss into a fatal bootstrap error",
)

# A fresh account can legitimately have no rankable damage unit before its first
# successful summon. Unit progression should skip that pass without killing a worker.
require(
    "No eligible damage unit was available; progression was skipped." in PROGRESSION,
    "UnitProgression must make an empty fresh-account inventory non-fatal",
)
require(
    'fail("RANK", "No eligible damage unit could be ranked.")' not in PROGRESSION,
    "UnitProgression still throws on an empty fresh-account inventory",
)

print("PASS: AutoSell verification cannot block fresh-account summoning")
