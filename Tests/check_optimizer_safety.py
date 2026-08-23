#!/usr/bin/env python3
"""Static safety gate for changes that run in every lobby and stage."""

from __future__ import annotations

import pathlib
import re
import sys


ROOT = pathlib.Path("/Users/siwakantalasak/Desktop/Anime Origin")


def fail(message: str, failures: list[str]) -> None:
    failures.append(message)
    print(f"[OptimizerSafety][FAIL] {message}")


def main() -> int:
    failures: list[str] = []
    optimizer = (ROOT / "Optimizer.lua").read_text(encoding="utf-8")
    config = (ROOT / "Config.lua").read_text(encoding="utf-8")
    settings = (ROOT / "InGameSettings.lua").read_text(encoding="utf-8")
    autoplay = (ROOT / "AutoPlay.lua").read_text(encoding="utf-8")

    # Production optimization preserves gameplay identity and hierarchy. Destroy
    # calls are limited to a guarded PlayerGui candidate and an explicitly
    # allowlisted direct Workspace map root requested by the user.
    destroy_calls = re.findall(r"([A-Za-z_][A-Za-z0-9_]*)\s*:\s*Destroy\s*\(", optimizer)
    if any(name not in {"candidate", "instance"} for name in destroy_calls):
        fail(f"Optimizer.lua has an unguarded Destroy target: {destroy_calls}", failures)
    if destroy_calls and "candidate:IsDescendantOf(playerGui)" not in optimizer:
        fail("transient PlayerGui destruction lacks a descendant guard", failures)
    for guard in (
        "instance.Parent ~= Workspace",
        "allowlist[instance.Name] ~= true",
        'for _, rootName in ipairs({ "Map", "MapTrash" })',
    ):
        if guard not in optimizer:
            fail(f"Workspace map destruction guard is missing: {guard}", failures)
    if re.search(r"\.Parent\s*=", optimizer):
        fail("Optimizer.lua reparents an Instance", failures)

    for required in ("workspace.Path.Model", "workspace.Towers", "workspace.Enemies"):
        if required not in optimizer:
            fail(f"protection contract comment is missing {required}", failures)

    if 'profile = "MultiAccount"' not in config:
        fail("MultiAccount is not the configured default profile", failures)
    if "disable3DRendering = false" not in config:
        fail("Headless rendering is enabled by default", failures)
    for required in (
        "destroyMapRoots = true",
        "Map = true",
        "MapTrash = true",
    ):
        if required not in config:
            fail(f"configured map-root cleanup is missing: {required}", failures)
    for required in (
        "disable3DWhenUnfocused = false",
        # Whole-ScreenGui suppression races the game's own lobby/stage HUD
        # transitions. Keep 3D/FPS optimization, but preserve live UI state.
        "hidePlayerGuiWhenUnfocused = false",
    ):
        if required not in config:
            fail(f"MultiAccount setting is missing: {required}", failures)
    if 'if Settings.lockFps ~= true then' not in optimizer:
        fail("setfpscap calls are not guarded by the lockFps setting", failures)

    # This used to require lockFps = false, which disabled every configured cap and
    # left dozens of background clients rendering as fast as the host allowed. The
    # real hazard was never capping itself, it is capping too low: task.wait resolves
    # on Heartbeat, so the frame time becomes the floor on every poll loop, and the
    # tightest interval in this project is 0.1s. A 10 FPS cap is a 100ms frame, which
    # sits exactly on that floor and starves the verification windows every remote
    # action depends on. Assert the floor instead of forbidding the feature.
    tightest_poll_seconds = 0.1
    minimum_safe_fps = int(round(1.0 / (tightest_poll_seconds / 2)))  # 20 FPS
    for key in ("fpsCap", "foregroundFpsCap", "backgroundFpsCap"):
        match = re.search(rf"^\s*{key}\s*=\s*(\d+)\s*,", config, re.MULTILINE)
        if not match:
            fail(f"MultiAccount setting is missing: {key}", failures)
            continue
        value = int(match.group(1))
        if value < minimum_safe_fps:
            fail(
                f"{key} = {value} is below {minimum_safe_fps} FPS; a frame would take "
                f"longer than half the tightest poll interval ({tightest_poll_seconds}s) "
                f"and starve remote verification",
                failures,
            )
    for required in (
        "UserInputService.WindowFocused",
        "UserInputService.WindowFocusReleased",
        "RunService:Set3dRenderingEnabled(not disabled)",
        "suppressPlayerGui(false)",
    ):
        if required not in optimizer:
            fail(f"reversible focus policy is missing: {required}", failures)
    if "showHolograms = false" not in config:
        fail("placement holograms are enabled in production", failures)

    speed_body = re.search(
        r"local function inspectSpeedInstances\(\)(.*?)\nend\n\nlocal function speedMatches",
        settings,
        re.S,
    )
    if not speed_body:
        fail("inspectSpeedInstances body was not found", failures)
    elif re.search(r":GetDescendants\s*\(", speed_body.group(1)):
        fail("GameSpeed verification still performs a full-tree scan", failures)
    if "Settings.monitorGameSpeed == true and not isLobby" not in settings:
        fail("GameSpeed monitor is not stage-gated", failures)

    cleanup_then_gate = re.search(
        r"local old = workspace:FindFirstChild\(\"AnimeOriginPlacementHolograms\"\).*?"
        r"if old then old:Destroy\(\) end.*?showHolograms.*?then return end",
        autoplay,
        re.S,
    )
    if not cleanup_then_gate:
        fail("AutoPlay does not clean old holograms before the production gate", failures)

    if failures:
        return 1
    print("[OptimizerSafety][PASS] only configured workspace.Map/MapTrash roots may be destroyed")
    return 0


if __name__ == "__main__":
    sys.exit(main())
