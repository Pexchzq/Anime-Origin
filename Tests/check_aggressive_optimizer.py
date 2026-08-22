#!/usr/bin/env python3
"""Static red-capable gate for the aggressive multi-account leak controls."""

from __future__ import annotations

import pathlib
import re
import sys


ROOT = pathlib.Path("/Users/siwakantalasak/Desktop/Anime Origin")


def main() -> int:
    config = (ROOT / "Config.lua").read_text(encoding="utf-8")
    optimizer = (ROOT / "Optimizer.lua").read_text(encoding="utf-8")
    main_lua = (ROOT / "main.lua").read_text(encoding="utf-8")
    failures: list[str] = []

    def require(source: str, needle: str, label: str) -> None:
        if needle not in source:
            failures.append(label)
            print(f"[AggressiveOptimizer][FAIL] {label}")

    for needle, label in (
        ("cleanupTransientUi = false", "game-owned end UI cleanup is not disabled"),
        ("destroyTransientGuiClones = false", "game-owned GUI clone destruction is not disabled"),
        ("leakSampleInterval = 15", "15-second leak sampling is not configured"),
        ("maximumLeakSamples = 120", "leak telemetry has no bounded ring"),
        ("maximumRetainedLogLines = 300", "Main fallback log retention is not bounded"),
        ("stripHiddenGuiImages = true", "hidden GUI texture stripping is not enabled"),
        ("maximumHiddenGuiImagesPerPass = 4000", "hidden GUI stripping is not batch-bounded"),
    ):
        require(config, needle, label)

    for needle, label in (
        ("function controller.cleanupTransientUi", "Optimizer cleanup interface is missing"),
        ("IsDescendantOf(playerGui)", "transient destruction lacks a PlayerGui guard"),
        ("Stats:GetTotalMemoryUsageMb()", "total memory telemetry is missing"),
        ("Stats:GetMemoryUsageMbForTag", "memory-tag attribution is missing"),
        ("PerformanceStats", "CPU/GPU performance telemetry is missing"),
        ("report.samples", "bounded runtime samples are missing"),
        ("PlayerGuiDescendants", "PlayerGui growth attribution is missing"),
        ("stripHiddenGuiImage", "hidden PlayerGui texture release is missing"),
        ("baselineSampleSequence", "startup UI loading is still counted as a leak"),
        ("largestPlayerGuiRoots", "large PlayerGui roots are not attributed"),
    ):
        require(optimizer, needle, label)

    if not re.search(r"#report\.samples\s*>\s*maximumLeakSamples", optimizer):
        failures.append("sample ring is not capped")
        print("[AggressiveOptimizer][FAIL] sample ring is not capped")

    if "cleanupTransientUi(" in main_lua:
        failures.append("Main still requests destructive transition UI cleanup")
        print("[AggressiveOptimizer][FAIL] Main still requests destructive transition UI cleanup")

    require(optimizer, "if isLifecycleGui(instance) then return false end",
            "End Screen/reward images are not protected")
    require(optimizer, "preserved = true", "Optimizer compatibility cleanup is not a no-op")
    if not re.search(r"#logLines\s*>\s*maximumRetainedLogLines", main_lua):
        failures.append("Main logLines remains unbounded")
        print("[AggressiveOptimizer][FAIL] Main logLines remains unbounded")

    if failures:
        return 1
    print("[AggressiveOptimizer][PASS] game lifecycle UI is preserved; leak telemetry and logs remain bounded")
    return 0


if __name__ == "__main__":
    sys.exit(main())
