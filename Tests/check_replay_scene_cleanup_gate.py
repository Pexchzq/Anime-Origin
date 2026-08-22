#!/usr/bin/env python3
"""Regression contract for replay scene cleanup before WaveVote."""

from pathlib import Path


ROOT = Path(__file__).resolve().parents[1]
SOURCE = (ROOT / "AutoPlay.lua").read_text(encoding="utf-8")
CONFIG = (ROOT / "Config.lua").read_text(encoding="utf-8")


def model_ready_votes(tower_counts: list[int], stable_samples: int) -> list[bool]:
    """Small state model matching the Lua gate: only consecutive zero samples pass."""
    zero_samples = 0
    results = []
    for count in tower_counts:
        zero_samples = zero_samples + 1 if count == 0 else 0
        results.append(zero_samples >= stable_samples)
    return results


assert model_ready_votes([12, 12, 0, 0], 2) == [False, False, False, True]
assert model_ready_votes([0, 12, 0, 0], 2) == [False, False, False, True]

required_source_contracts = {
    "authoritative workspace tower count": "local function workspaceTowerCount()",
    "per-generation cleanup state": "local sceneCleanupGate =",
    "ready vote checks cleanup": "sceneReadyForWaveVote(voteState.generation)",
    "post-start gameplay cleanup": "local function sceneReadyForGameplay()",
    "bounded server recovery": 'genericRemote:FireServer("TeleportToLobby")',
    "ready is not sent while dirty": "Scene residue blocks WaveVote",
}
for name, token in required_source_contracts.items():
    assert token in SOURCE, f"missing {name}: {token}"

required_config_contracts = {
    "stable clean samples": "sceneCleanupStableSamples = 2",
    "short pre-ready grace": "sceneCleanupPreReadyGrace = 1.5",
    "bounded cleanup timeout": "sceneCleanupTimeout = 5",
}
for name, token in required_config_contracts.items():
    assert token in CONFIG, f"missing {name}: {token}"

print("replay scene cleanup gate contract passed")
