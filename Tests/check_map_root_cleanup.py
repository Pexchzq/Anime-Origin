#!/usr/bin/env python3
"""Contract for exact workspace.Map and workspace.MapTrash client cleanup."""

from pathlib import Path


ROOT = Path(__file__).resolve().parents[1]
CONFIG = (ROOT / "Config.lua").read_text(encoding="utf-8")
OPTIMIZER = (ROOT / "Optimizer.lua").read_text(encoding="utf-8")

for token in (
    "destroyMapRoots = true",
    "Map = true",
    "MapTrash = true",
):
    assert token in CONFIG, f"missing map cleanup config: {token}"

for token in (
    "local function destroyConfiguredMapRoot(instance)",
    "instance.Parent ~= Workspace",
    "allowlist[instance.Name] ~= true",
    "Workspace.ChildAdded:Connect",
    'for _, rootName in ipairs({ "Map", "MapTrash" })',
    "instance:Destroy()",
):
    assert token in OPTIMIZER, f"missing map cleanup implementation: {token}"

print("workspace.Map and workspace.MapTrash exact-root cleanup contract passed")
