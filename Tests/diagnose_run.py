#!/usr/bin/env python3
"""One-shot health check over every Anime Origin runtime artifact.

    python3 Tests/diagnose_run.py                 # everything on disk
    python3 Tests/diagnose_run.py --since 10      # only accounts active in the last 10 minutes
    python3 Tests/diagnose_run.py --watch 60      # re-scan every 60s and print only what changed

Exit code 1 means at least one RED finding.
"""

from __future__ import annotations

import argparse
import subprocess
import sys
import time
from pathlib import Path

HERE = Path(__file__).resolve().parent
STAGES = ("diagnose_latest_bootstrap_pipeline.py", "diagnose_latest_play_runtime.py")


def run_once(extra: list[str]) -> tuple[int, str]:
    chunks: list[str] = []
    worst = 0
    for stage in STAGES:
        proc = subprocess.run(
            [sys.executable, str(HERE / stage), *extra],
            capture_output=True, text=True, cwd=HERE,
        )
        chunks.append(proc.stdout + (proc.stderr if proc.returncode not in (0, 1) else ""))
        worst = max(worst, proc.returncode)
    return worst, "\n".join(chunks)


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--user", action="append", help="restrict to this UserId (repeatable)")
    parser.add_argument("--since", type=float, help="only accounts whose artifacts changed in the last N minutes")
    parser.add_argument("--watch", type=float, metavar="SECONDS",
                        help="re-scan on this interval and print only when the findings change")
    args = parser.parse_args()

    extra: list[str] = []
    for user in args.user or []:
        extra += ["--user", user]
    if args.since is not None:
        extra += ["--since", str(args.since)]

    if not args.watch:
        code, output = run_once(extra)
        print(output)
        return code

    previous = None
    while True:
        code, output = run_once(extra)
        stamp = time.strftime("%H:%M:%S")
        if output != previous:
            print(f"\n########## {stamp} findings changed ##########")
            print(output, flush=True)
            previous = output
        else:
            print(f"[{stamp}] unchanged (exit={code})", flush=True)
        time.sleep(args.watch)


if __name__ == "__main__":
    sys.exit(main())
