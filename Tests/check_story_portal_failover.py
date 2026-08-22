#!/usr/bin/env python3
"""Regression contract for occupied Story pods and verified portal entry."""

from pathlib import Path


ROOT = Path(__file__).resolve().parents[1]
MAIN = (ROOT / "main.lua").read_text(encoding="utf-8")
CONFIG = (ROOT / "Config.lua").read_text(encoding="utf-8")

# The portal scanner must not stay coupled to one Pod/DoorUIPart instance.
for token in (
    "local function resolvePortalCandidates()",
    "local function portalHasOtherPlayer(portal)",
    'portalRootPath = { "MainFolder", "Lobby", "MapSelectors", "Story" }',
    'portalDoorName = "DoorUIPart"',
    "occupancyPollInterval = 0.5",
    "occupiedPortalWaitTimeout = 20",
):
    source = MAIN if token.startswith("local function") else CONFIG
    assert token in source, f"missing Story portal failover contract: {token}"

# UpdatePlayersInside is the authoritative occupancy evidence captured by the
# successful normal UI flow. Entry is only successful after MapSelect evidence;
# merely reaching a coordinate is not server confirmation.
for token in (
    'action == "UpdatePlayersInside"',
    "bus.playersInside",
    "bus.localPlayerInside",
    "bus.mapSelectGeneration > before",
    "recentPortalFailures",
):
    assert token in MAIN, f"missing occupied-portal evidence handling: {token}"

entry_start = MAIN.index("local function enterStoryPortal")
entry_end = MAIN.index("local function chooseLobbyTarget", entry_start)
entry = MAIN[entry_start:entry_end]
assert "(root.Position - inside).Magnitude <= 3" not in entry, (
    "coordinates must not be accepted as portal-entry proof"
)

selection_start = MAIN.index("local function startSelectedStage")
selection_end = MAIN.index("local function ensureLobbyLoadout", selection_start)
selection = MAIN[selection_start:selection_end]
assert "if not entered then" in selection, (
    "StartSelection must be skipped when no Story portal accepted the player"
)

# Do not discover occupancy by teleporting through every candidate. Physical
# InsideModel bounds select one free Pod first; one enterStoryPortal call may
# invoke the character-moving helper only once.
assert "insideModel:GetBoundingBox()" in MAIN
assert "portalHasOtherPlayer(portal)" in MAIN
assert "local attemptedPortal" in entry
assert entry.count("tryEnterStoryPortal(attemptedPortal, deadline)") == 1
assert "for _, portal in ipairs(portalCandidates) do" not in entry

# Small behavioral model: a reserved first door must not prevent selecting the
# next available candidate.
def choose(candidates, occupied, cooling):
    return next(
        (door for door in candidates if door not in occupied and door not in cooling),
        None,
    )


assert choose(["PodA", "PodB"], {"PodA"}, set()) == "PodB"
assert choose(["PodA", "PodB"], {"PodA"}, {"PodB"}) is None

print("Story portal occupancy/failover contract passed")
