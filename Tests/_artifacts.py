#!/usr/bin/env python3
"""Shared loader for Anime Origin runtime artifacts.

Every diagnose_* script reads real per-UserId logs and JSON reports through
this module. Nothing here greps the Lua source: a check may only fail or pass
because of what the game actually wrote to disk.
"""

from __future__ import annotations

import json
import os
import re
import time
from dataclasses import dataclass, field
from pathlib import Path

DEFAULT_RUNTIME = Path.home() / "Documents" / "Macsploit Workspace" / "AnimeOrigin"
RUNTIME = Path(os.environ.get("ANIME_ORIGIN_RUNTIME", DEFAULT_RUNTIME))

# [Component][seq][TAG][+12.34s] message | {json}      (clock is optional)
LINE_RE = re.compile(
    r"^\[(?P<component>[A-Za-z]+)\]"
    r"\[(?P<seq>\d+)\]"
    r"\[(?P<tag>[A-Z_]+)\]"
    r"(?:\[\+(?P<clock>[0-9.]+)s\])?"
    r"\s*(?P<message>.*?)"
    r"(?:\s\|\s(?P<payload>[\[{].*))?$"
)

PREFIXES = (
    "FastModeBootstrap",
    "InGameSettings",
    "UnitProgression",
    "MainRoute",
    "AutoPlay",
    "RuntimeLeakWatch",
)


@dataclass
class LogLine:
    component: str
    seq: int
    tag: str
    clock: float | None
    message: str
    data: object | None
    raw: str

    def get(self, key, default=None):
        if isinstance(self.data, dict):
            return self.data.get(key, default)
        return default


@dataclass
class Finding:
    severity: str          # RED | WARN
    code: str              # stable short id, e.g. "FASTMODE_GEMS_STRANDED"
    user: str
    detail: str
    evidence: dict = field(default_factory=dict)

    def render(self) -> str:
        mark = "RED " if self.severity == "RED" else "WARN"
        line = f"[{mark}][{self.code}] user={self.user} {self.detail}"
        if self.evidence:
            line += "\n       evidence: " + json.dumps(self.evidence, default=str)[:600]
        return line


def parse_log(text: str) -> list[LogLine]:
    lines: list[LogLine] = []
    for raw in text.splitlines():
        m = LINE_RE.match(raw)
        if not m:
            continue
        payload = m.group("payload")
        data = None
        if payload:
            try:
                data = json.loads(payload)
            except json.JSONDecodeError:
                data = None
        clock = m.group("clock")
        lines.append(
            LogLine(
                component=m.group("component"),
                seq=int(m.group("seq")),
                tag=m.group("tag"),
                clock=float(clock) if clock else None,
                message=m.group("message").strip(),
                data=data,
                raw=raw,
            )
        )
    return lines


def discover_users(runtime: Path = RUNTIME) -> list[str]:
    """Every UserId that has at least one artifact, newest activity first."""
    seen: dict[str, float] = {}
    for prefix in PREFIXES:
        for path in runtime.glob(f"{prefix}_*"):
            m = re.match(rf"{prefix}_(\d+)(?:_latest)?\.(?:log|json)$", path.name)
            if not m:
                continue
            uid = m.group(1)
            if uid == "0":          # RuntimeLeakWatch writes UserId 0 before login
                continue
            mtime = path.stat().st_mtime
            seen[uid] = max(seen.get(uid, 0.0), mtime)
    return [uid for uid, _ in sorted(seen.items(), key=lambda kv: kv[1], reverse=True)]


class Account:
    """All artifacts belonging to one UserId."""

    def __init__(self, user: str, runtime: Path = RUNTIME):
        self.user = user
        self.runtime = runtime
        self._json: dict[str, object] = {}
        self._logs: dict[str, list[LogLine]] = {}

    def path(self, name: str) -> Path:
        return self.runtime / name

    def json(self, prefix: str, latest: bool = True) -> dict | None:
        name = f"{prefix}_{self.user}{'_latest' if latest else ''}.json"
        if name in self._json:
            return self._json[name]          # type: ignore[return-value]
        path = self.path(name)
        value = None
        if path.exists():
            try:
                value = json.loads(path.read_text(encoding="utf-8", errors="replace"))
            except json.JSONDecodeError:
                value = None
        self._json[name] = value
        return value

    def log(self, prefix: str) -> list[LogLine]:
        name = f"{prefix}_{self.user}_latest.log"
        if name in self._logs:
            return self._logs[name]
        path = self.path(name)
        lines = parse_log(path.read_text(encoding="utf-8", errors="replace")) if path.exists() else []
        self._logs[name] = lines
        return lines

    def mtime(self, prefix: str, latest: bool = True) -> float | None:
        name = f"{prefix}_{self.user}{'_latest' if latest else ''}.json"
        path = self.path(name)
        return path.stat().st_mtime if path.exists() else None

    def newest_mtime(self) -> float:
        best = 0.0
        for prefix in PREFIXES:
            for suffix in ("_latest.log", "_latest.json", ".json"):
                path = self.path(f"{prefix}_{self.user}{suffix}")
                if path.exists():
                    best = max(best, path.stat().st_mtime)
        return best

    def age_minutes(self) -> float:
        newest = self.newest_mtime()
        return (time.time() - newest) / 60.0 if newest else float("inf")


def select_accounts(users: list[str] | None, since_minutes: float | None,
                    runtime: Path = RUNTIME) -> list[Account]:
    ids = users or discover_users(runtime)
    accounts = [Account(uid, runtime) for uid in ids]
    if since_minutes is not None:
        accounts = [a for a in accounts if a.age_minutes() <= since_minutes]
    return accounts


def report(title: str, findings: list[Finding], scanned: list[Account]) -> int:
    print(f"===== {title} =====")
    if not scanned:
        print("  no accounts matched the filter (nothing to diagnose)")
        return 0
    for account in scanned:
        print(f"  scanned user={account.user} (artifacts {account.age_minutes():.1f} min old)")
    reds = [f for f in findings if f.severity == "RED"]
    warns = [f for f in findings if f.severity == "WARN"]
    print()
    for finding in reds + warns:
        print(finding.render())
    print()
    print(f"  RED={len(reds)} WARN={len(warns)} accounts={len(scanned)}")
    return 1 if reds else 0
