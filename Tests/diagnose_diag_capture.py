#!/usr/bin/env python3
"""Read an AnimeOriginDiag capture and say what broke, where, and whether it chained.

    Tests/diagnose_diag_capture.py                     # the live capture folder
    Tests/diagnose_diag_capture.py ~/Downloads/x.zip   # a capture sent for analysis
    Tests/diagnose_diag_capture.py --account 1000000001
    Tests/diagnose_diag_capture.py --events            # include the raw event tails

Nothing here reads Lua source. Every line printed comes from what the clients
actually recorded, which is the whole point: the static gates already assert what the
code says, and the recurring bugs in this project were all cases where the code said
one thing and the run did another.

The grouping matters more than any single account. The last hand-read capture took a
night of reading twelve log files per account to reach "six died one way, six died
another, twenty-eight were fine". That conclusion is a `defaultdict` over a field the
clients now compute themselves.
"""

from __future__ import annotations

import argparse
import json
import sys
import zipfile
from collections import Counter, defaultdict
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
from _artifacts import RUNTIME  # noqa: E402

DIAG_FOLDER = RUNTIME.parent / "AnimeOriginDiag"

VERDICT_ORDER = {"STALLED": 0, "DEGRADED": 1, "UNKNOWN": 2, "HEALTHY": 3}


def load_digests(source: Path) -> tuple[list[dict], list[str]]:
    """Return (digests, problems). A digest that will not parse is itself a finding:
    a client killed mid-write leaves a truncated file, and that has happened before."""
    digests: list[dict] = []
    problems: list[str] = []

    def ingest(name: str, raw: bytes) -> None:
        try:
            digests.append(json.loads(raw.decode("utf-8", "replace")))
        except json.JSONDecodeError as error:
            problems.append(f"{name}: unreadable ({error.msg} at byte {error.pos})")

    if source.is_file() and source.suffix == ".zip":
        with zipfile.ZipFile(source) as archive:
            for entry in archive.namelist():
                if Path(entry).name.startswith("digest_") and entry.endswith(".json"):
                    ingest(Path(entry).name, archive.read(entry))
    elif source.is_dir():
        for path in sorted(source.glob("**/digest_*.json")):
            ingest(path.name, path.read_bytes())
    else:
        problems.append(f"{source}: not a folder or .zip")

    return digests, problems


def render_chain(chain: list[dict], indent: str = "      ") -> list[str]:
    lines = []
    for index, link in enumerate(chain):
        arrow = "  " if index == 0 else "->"
        via = link.get("via")
        via_note = ""
        if via and via != "parent":
            # Naming the edge kind is the difference between "these two things both
            # went wrong" and "this one caused that one".
            via_note = f"  [via {via}]"
        where = f"  ({link['where']})" if link.get("where") else ""
        lines.append(
            f"{indent}{arrow} [{link.get('at', '?')}s] {link.get('name')} "
            f"= {link.get('verdict')}{where}{via_note}"
        )
        if link.get("reason"):
            lines.append(f"{indent}     reason: {link['reason']}")
    return lines


def other_problems(digest: dict) -> list[tuple[str, dict]]:
    """Non-OK steps the chain does not cover.

    The client computes exactly one chain -- the one rooted at the worst thing it saw --
    because carrying several would multiply the size of every digest in a 54-account
    capture. That is the right trade only if what the chain leaves out is still visible,
    and it is: `steps` carries every name, verdict and anchor already, so the remainder
    is a set difference done here instead of bytes shipped from every client.
    """
    covered = {link.get("name") for link in (digest.get("chain") or [])}
    rest = []
    for name, entry in (digest.get("steps") or {}).items():
        if name in covered:
            continue
        if entry.get("noop") or entry.get("fail") or entry.get("stuck"):
            rest.append((name, entry))
    return sorted(rest, key=lambda kv: -(kv[1].get("stuck", 0) * 100
                                         + kv[1].get("fail", 0) * 10
                                         + kv[1].get("noop", 0)))


def account_label(digest: dict) -> str:
    return f"{digest.get('userId', 'unknown')}@{digest.get('placeId', '?')}"


def report_fleet(digests: list[dict], show_events: bool) -> int:
    by_verdict = Counter(d.get("verdict", "UNKNOWN") for d in digests)
    total = len(digests)

    print(f"\n=== fleet: {total} account(s) ===")
    for verdict in sorted(by_verdict, key=lambda v: VERDICT_ORDER.get(v, 9)):
        print(f"  {verdict:<9} {by_verdict[verdict]:>3}")

    # The clustering. Accounts that died the same way share a headline, and a headline
    # is already the chain in compressed form.
    clusters: dict[str, list[dict]] = defaultdict(list)
    for digest in digests:
        if digest.get("verdict") not in (None, "HEALTHY"):
            clusters[digest.get("headline") or "(no headline)"].append(digest)

    if not clusters:
        print("\n  No account reported a non-OK step. Nothing to explain.")
    else:
        print(f"\n=== {len(clusters)} distinct failure signature(s) ===")
        for headline, group in sorted(clusters.items(), key=lambda kv: -len(kv[1])):
            example = group[0]
            places = Counter(d.get("placeId") for d in group)
            print(f"\n  [{len(group)} account(s)] {headline}")
            print(f"      places: {dict(places)}")
            print(f"      example: {account_label(example)}  (uptime {example.get('uptime')}s)")
            head = example.get("head") or {}
            if head:
                # The head is the claim worth arguing with. Everything after it in the
                # chain is a consequence, and fixing a consequence is how a bug comes back.
                print(f"      ROOT: {head.get('name')} = {head.get('verdict')}"
                      f"{'  (' + head['where'] + ')' if head.get('where') else ''}")
                if head.get("reason"):
                    print(f"            {head['reason']}")
            chain = example.get("chain") or []
            if len(chain) > 1:
                print(f"      chain ({len(chain)} links):")
                for line in render_chain(chain):
                    print(line)
            elif chain:
                print("      chain: single link -- isolated, not a chain")
            rest = other_problems(example)
            if rest:
                print(f"      {len(rest)} other non-OK step(s) outside this chain:")
                for name, entry in rest[:4]:
                    print(f"        {name} = {entry.get('lastVerdict')}"
                          f"{'  (' + entry['where'] + ')' if entry.get('where') else ''}")
                    if entry.get("lastReason"):
                        print(f"            {entry['lastReason']}")
            for item in (example.get("open") or [])[:3]:
                flag = "STUCK" if item.get("stuck") else "open"
                print(f"      {flag}: {item.get('name')} for {item.get('openFor')}s"
                      f" (deadline {item.get('deadline')}s)"
                      f"{'  ' + item['where'] if item.get('where') else ''}")
                if item.get("expect"):
                    print(f"            expected: {item['expect']}")
            if show_events:
                for record in (example.get("tail") or [])[-12:]:
                    print(f"        . {json.dumps(record, ensure_ascii=False)[:160]}")

    # Fleet-wide silent-failure leaderboard. A step that returns cleanly but never
    # produces its declared evidence is invisible to every other tool here.
    rollup: dict[str, Counter] = defaultdict(Counter)
    for digest in digests:
        for name, entry in (digest.get("steps") or {}).items():
            for field in ("runs", "ok", "noop", "fail", "stuck"):
                rollup[name][field] += entry.get(field, 0) or 0
    suspicious = {n: c for n, c in rollup.items() if c["noop"] or c["fail"] or c["stuck"]}
    if suspicious:
        print("\n=== steps that did not produce their declared evidence ===")
        print(f"  {'step':<38} {'runs':>6} {'ok':>6} {'NO_OP':>6} {'FAIL':>6} {'STUCK':>6}")
        for name, counts in sorted(suspicious.items(),
                                   key=lambda kv: -(kv[1]["stuck"] * 100 + kv[1]["fail"] * 10 + kv[1]["noop"])):
            print(f"  {name:<38} {counts['runs']:>6} {counts['ok']:>6} "
                  f"{counts['noop']:>6} {counts['fail']:>6} {counts['stuck']:>6}")
        print("\n  NO_OP is the column to read first: the function ran, returned cleanly,")
        print("  and the evidence it declared never appeared. No other artifact in this")
        print("  project can distinguish that from success.")

    # Recorder self-report. A capture that quietly lost data must say so, or the next
    # conclusion gets drawn from a hole.
    truncated = [d for d in digests if (d.get("recorder") or {}).get("eventsTruncated")]
    no_anchor = [d for d in digests if not (d.get("recorder") or {}).get("hasDebugInfo", True)]
    dropped = [d for d in digests if (d.get("recorder") or {}).get("droppedOpenSteps")]
    if truncated or no_anchor or dropped:
        print("\n=== recorder health ===")
        if truncated:
            print(f"  {len(truncated)} account(s) hit the event byte cap; their .jsonl is partial")
            print("    (the digest is still complete -- it is rebuilt from live state, not from the file)")
        if no_anchor:
            print(f"  {len(no_anchor)} account(s) have no debug.info; 'where' anchors are missing there")
        if dropped:
            print(f"  {len(dropped)} account(s) exceeded maximumOpenSteps; some steps went untracked")
    return 0


def report_account(digests: list[dict], user_id: str, show_events: bool) -> int:
    matches = [d for d in digests if str(d.get("userId")) == str(user_id)]
    if not matches:
        print(f"no digest for account {user_id}")
        return 1
    digest = matches[0]
    print(f"\n=== {account_label(digest)} ===")
    print(f"  verdict : {digest.get('verdict')}")
    print(f"  headline: {digest.get('headline')}")
    print(f"  uptime  : {digest.get('uptime')}s   job {digest.get('jobId')}")

    chain = digest.get("chain") or []
    if chain:
        print(f"\n  chain ({len(chain)} link(s))"
              f"{' -- single link, isolated' if len(chain) == 1 else ''}:")
        for line in render_chain(chain, indent="    "):
            print(line)

    if digest.get("open"):
        print("\n  still open:")
        for item in digest["open"]:
            print(f"    {'STUCK' if item.get('stuck') else 'open '} {item.get('name')} "
                  f"{item.get('openFor')}s / {item.get('deadline')}s"
                  f"{'  ' + item['where'] if item.get('where') else ''}")
            if item.get("expect"):
                print(f"          expected: {item['expect']}")

    rest = other_problems(digest)
    if rest:
        print(f"\n  {len(rest)} other non-OK step(s) outside that chain:")
        for name, entry in rest:
            print(f"    {name} = {entry.get('lastVerdict')}"
                  f"{'  (' + entry['where'] + ')' if entry.get('where') else ''}")
            if entry.get("lastReason"):
                print(f"        {entry['lastReason']}")

    print("\n  steps:")
    for name, entry in sorted((digest.get("steps") or {}).items()):
        print(f"    {name:<38} runs={entry.get('runs', 0)} ok={entry.get('ok', 0)} "
              f"noop={entry.get('noop', 0)} fail={entry.get('fail', 0)} stuck={entry.get('stuck', 0)}"
              f"  last={entry.get('lastVerdict')}")
        if entry.get("lastReason"):
            print(f"          {entry['lastReason']}")

    if digest.get("signals"):
        print("\n  signals:")
        for name, signal in sorted(digest["signals"].items()):
            arrow = f"{signal.get('from')} -> " if signal.get("from") else ""
            print(f"    {name:<32} {arrow}{signal.get('status')}  @{signal.get('at')}s")

    if show_events and digest.get("tail"):
        print("\n  recent events:")
        for record in digest["tail"]:
            print(f"    {json.dumps(record, ensure_ascii=False)[:200]}")
    return 0


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__,
                                     formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("source", nargs="?", default=str(DIAG_FOLDER),
                        help="capture folder or .zip (default: the live AnimeOriginDiag folder)")
    parser.add_argument("--account", help="print one account in full")
    parser.add_argument("--events", action="store_true", help="include raw event tails")
    args = parser.parse_args()

    source = Path(args.source).expanduser()
    digests, problems = load_digests(source)

    print(f"capture: {source}")
    for problem in problems:
        print(f"  !! {problem}")
    if not digests:
        print("  no digests found. Either the run has not written one yet (the first")
        print("  digest lands ~10s after join), or Diag.lua never loaded on any client.")
        return 1

    if args.account:
        return report_account(digests, args.account, args.events)
    return report_fleet(digests, args.events)


if __name__ == "__main__":
    sys.exit(main())
