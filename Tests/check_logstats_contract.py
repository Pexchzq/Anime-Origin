#!/usr/bin/env python3
"""Static contract for the compact non-UI realtime status observer."""

from pathlib import Path


ROOT = Path(__file__).resolve().parents[1]
observer = (ROOT / "logstats.lua").read_text(encoding="utf-8")
config = (ROOT / "Config.lua").read_text(encoding="utf-8")
registry = (ROOT / "Registry" / "DataPathRegistry.lua").read_text(encoding="utf-8")

# Regression: when Config and LocalPlayer already exist before logstats starts,
# the wait loop is skipped. The local player reference must therefore be seeded
# before that loop rather than assigned only inside its body.
wait_loop = observer.index(
    'while controller.active and (typeof(config) ~= "table" or not player) do'
)
assert observer.index("local player = Players.LocalPlayer") < wait_loop, (
    "LocalPlayer must be initialized before the readiness loop can be skipped"
)
assert 'or not Players.LocalPlayer) do' not in observer, (
    "readiness must test the cached local that OnTeleport later dereferences"
)

for token in (
    "logStats = {",
    "pollInterval = 0.2",
    "runtimeDiscoveryInterval = 0.5",
    "statusOnly = true",
):
    assert token in config, f"missing compact-console config: {token}"

for token in (
    'rawget(currency, "Gems")',
    'rawget(currency, "TraitReroll")',
    'rawget(data, "Exp")',
    'rawget(levelUtility, "GetPlayerLevelFromExp")',
    'action == "UpdateClientGame"',
    'action == "ActOver"',
    'return "INF"',
    'return "HARD"',
    'return "NORMAL"',
    '"[LogStats] Status=%s | Level=%s | Gems=%s | TraitReroll=%s | Farm=%s"',
    "if signature == lastSignature then return end",
    "objects = nil",
):
    assert token in observer, f"missing logstats behavior: {token}"

assert ':FindFirstChildOfClass("PlayerGui")' not in observer
assert ':WaitForChild("PlayerGui")' not in observer
assert "FireServer" not in observer and "InvokeServer" not in observer, (
    "logstats must remain read-only"
)
assert 'traitReroll = "<RuntimeResolver>.PlayerData.Inventory.Currency.TraitReroll"' in registry

# Every production controller must honor Config.console.statusOnly. Detailed
# file reports remain active; only their normal console prints are suppressed.
for filename in (
    "FastMode.lua",
    "InGameSettings.lua",
    "UnitProgression.lua",
    "main.lua",
    "AutoPlay.lua",
    "Optimizer.lua",
):
    source = (ROOT / filename).read_text(encoding="utf-8")
    assert "consoleStatusOnly" in source, f"{filename} ignores compact-console mode"

print("logstats contract passed")
