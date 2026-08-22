#!/usr/bin/env python3
"""Fast, deterministic diagnosis of the latest live Main/AutoPlay run."""

import json
import re
from collections import Counter
from pathlib import Path

REPORTS = Path("/Users/siwakantalasak/Documents/Macsploit Workspace/AnimeOrigin")
user_id = "11549462455"
main_path = REPORTS / f"MainRoute_{user_id}_latest.log"
auto_path = REPORTS / f"AutoPlay_{user_id}_latest.log"

main_lines = main_path.read_text(errors="replace").splitlines()
auto_lines = auto_path.read_text(errors="replace").splitlines()

ends = []
for line in main_lines:
    if "][END] " not in line:
        continue
    payload = line.split(" | ", 1)[1] if " | " in line else "{}"
    try:
        ends.append(json.loads(payload))
    except json.JSONDecodeError:
        pass

restart_lines = [line for line in main_lines if "][ACTION] RestartGame" in line]
replay_lines = [line for line in main_lines if "][ACTION] ReplayActVote" in line]

reject_pattern = re.compile(
    r'Server rejected the upgrade immediately.*?\| (\{.*\})$'
)
rejects = []
for line in auto_lines:
    match = reject_pattern.search(line)
    if not match:
        continue
    try:
        payload = json.loads(match.group(1))
    except json.JSONDecodeError:
        continue
    rejects.append((payload.get("matchEpoch"), payload.get("placedUUID"), payload.get("targetStage")))

reject_counts = Counter(rejects)
worst_key, worst_count = reject_counts.most_common(1)[0] if reject_counts else (None, 0)
early_defeats = [end for end in ends if not end.get("success") and int(end.get("wavesCompleted") or 0) < 15]

print(f"[PlayRuntime] matches={len(ends)} early_defeats={len(early_defeats)}")
print(f"[PlayRuntime] RestartGame_actions={len(restart_lines)} ReplayActVote_actions={len(replay_lines)}")
print(f"[PlayRuntime] upgrade_rejections={len(rejects)} worst_same_target={worst_count} key={worst_key}")

failed = []
if restart_lines:
    failed.append("Main emitted RestartGame during the captured Story run")
if worst_count >= 10:
    failed.append(f"AutoPlay hammered one rejected upgrade target {worst_count} times")
if early_defeats:
    waves = ",".join(str(item.get("wavesCompleted")) for item in early_defeats)
    failed.append(f"Story matches ended in early defeat at waves {waves}")

if failed:
    for reason in failed:
        print(f"[PlayRuntime][RED] {reason}")
    raise SystemExit(1)

print("[PlayRuntime][GREEN] no premature restart, rejection storm, or early defeat")
