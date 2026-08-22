#!/usr/bin/env python3
"""Decision-table regression for Normal -> Hard level farm -> Infinite routing."""

from pathlib import Path


ROOT = Path(__file__).resolve().parents[1]
source = (ROOT / "main.lua").read_text(encoding="utf-8")


def decide(clears: list[int], level: int, threshold: int = 20) -> tuple[str, str, str]:
    for index, count in enumerate(clears, start=1):
        if count <= 0:
            return "Story", str(index), "Normal"
    if level < threshold:
        return "Story", "1", "Hard"
    return "Story", "Infinite", "Hard"


cases = {
    "new account starts Normal 1": ([0, 0, 0, 0, 0, 0], 1, ("Story", "1", "Normal")),
    "continues at first uncleared act": ([1, 1, 1, 0, 0, 0], 8, ("Story", "4", "Normal")),
    "Act 6 clear below level gate farms Hard 1": ([1, 1, 1, 1, 1, 1], 19, ("Story", "1", "Hard")),
    "Act 6 clear at level gate enters Infinite": ([1, 1, 1, 1, 1, 1], 20, ("Story", "Infinite", "Hard")),
    "Act 6 clear above level gate enters Infinite": ([1, 1, 1, 1, 1, 1], 30, ("Story", "Infinite", "Hard")),
}

failed = []
for name, (clears, level, expected) in cases.items():
    actual = decide(clears, level)
    print(("PASS" if actual == expected else "FAIL") + f": {name} -> {actual}")
    if actual != expected:
        failed.append(name)

required_source_guards = (
    "first uncleared Normal act",
    "Normal 1-6 complete; account level below Infinite gate",
    "Normal 1-6 complete and account level reached Infinite gate",
)
for guard in required_source_guards:
    if guard not in source:
        failed.append("missing source route guard: " + guard)

config = (ROOT / "Config.lua").read_text(encoding="utf-8")
if "minimumInfiniteLevel = 20" not in config:
    failed.append("Config does not require account level 20 for Infinite")

if failed:
    raise SystemExit(1)
