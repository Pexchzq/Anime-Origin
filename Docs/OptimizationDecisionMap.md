# Anime Origin Optimization Decision Map

Goal: reduce Roblox client CPU, GPU, memory growth and executor overhead while
preserving every server-verified FastMode, UnitProgression, Main and AutoPlay
transition across lobby, first match, Replay/Next and later matches.

## protection-contract: What Must Never Be Broken?

Blocked by:
Status: resolved
Type: Grilling

### Question

Which runtime evidence and instances must survive every optimization profile?

### Answer

Never destroy, reparent or replace remotes, LocalScripts, ModuleScripts,
PlayerData/MatchRuntime tables, the local Character, CurrentCamera,
`workspace.Path.Model`, `workspace.Towers`, `workspace.Enemies`, the Story portal
used by Main, or the placement coordinates in Config. Visual properties may only
be changed where the instance identity, bounds and position remain intact.
Controller success remains server-evidence based; visible UI is not proof.

## baseline: Measure The Actual Cost

Blocked by: protection-contract
Status: in-progress
Type: Prototype

### Question

What are the lobby, match-start, wave and second-match baselines for FPS/frame
time, Roblox memory, Lua heap, instance/effect count, full `getgc` scans, full
tree scans, report writes and controller action latency?

### Answer

Create a read-only low-frequency performance probe and a small macOS process
snapshot. Sample the same account in lobby, match start, wave 10/20 and the
second match. Record medians, not a single screenshot. The probe must itself
avoid frequent `GetDescendants` calls and write one compact terminal snapshot.

`Probes/PerformanceProbe.lua` now captures the Roblox half of this baseline;
live lobby/match/second-match samples are still required before resolution.

## script-runtime: Remove Controller Overhead

Blocked by: baseline
Status: open
Type: Prototype

### Question

How can all controllers keep their current verification strength with less
polling, scanning, JSON encoding and file I/O?

### Answer

Build a lazy shared runtime cache per JobId, use events where Roblox exposes
them, add adaptive polling for plain runtime tables, buffer logs, coalesce report
writes, and disable debug visuals by default. InGameSettings must monitor speed
only in a confirmed stage and cache the exact replicated speed instance instead
of scanning ReplicatedStorage and Workspace every verification cycle.

## safe-game-profile: Disable Purely Visual Work

Blocked by: baseline
Status: open
Type: Prototype

### Question

Which client visuals can be disabled without changing gameplay instances or
server-backed evidence?

### Answer

Create a separate Optimizer controller. The Safe profile disables particles,
trails, beams, post-processing, highlights, unnecessary lights, shadows and
optional sounds; keeps critical roots and all scripts/remotes; and processes new
effects through a batched DescendantAdded queue rather than rescanning every
frame. Existing in-game Low/Optimized settings remain the first layer.

## farm-profile: Reduce Rendering Further

Blocked by: script-runtime, safe-game-profile
Status: open
Type: Prototype

### Question

How far can a farming profile reduce GPU and CPU work while AutoPlay remains
fully functional?

### Answer

Add configurable FPS capping, hide other players and noncritical decorations,
neutralize map textures/decals without deleting geometry, and optionally hide
tower/enemy rendering while preserving their models, positions and descendants.
Every mutation is class- and root-guarded. No broad name-only deletion.

## headless-profile: Optional Maximum Reduction

Blocked by: farm-profile
Status: open
Type: Prototype

### Question

Can 3D rendering be disabled after runtime readiness without stalling callbacks,
Replay/Next lifecycle, MatchRuntime changes or AutoPlay timing?

### Answer

Test `Set3dRenderingEnabled(false)` and a very low FPS cap as an explicit opt-in
profile. Automatically fall back to Farm when MatchRuntime, WaveVote, placement
or upgrade verification exceeds its normal latency budget. Never make this the
default until two consecutive matches pass.

## orchestration: Start And Stop In The Right Context

Blocked by: script-runtime, safe-game-profile
Status: open
Type: Grilling

### Question

How should optimization cooperate with the current Config -> FastMode ->
UnitProgression -> Main -> AutoPlay lifecycle?

### Answer

Optimizer is independent and nonblocking. It reads Config, applies a lobby
profile immediately, then applies the stage profile after runtime readiness. It
publishes status but is not a Main bootstrap dependency. Teleport/rejoin creates
a fresh JobId state, and re-running the file remains idempotent.

## validation: Prove It Is Lighter And Still Correct

Blocked by: farm-profile, orchestration
Status: open
Type: Research

### Question

What evidence is required before enabling an optimization profile by default?

### Answer

Compare the baseline scenarios using the same account and route. Require no
FastMode/UnitProgression/Main/AutoPlay failures, correct team/placement/upgrade
evidence in match one and match two, no unbounded memory growth, no repeated
full-tree scans after discovery, bounded report/log size and materially lower
median frame time or Roblox process CPU/RSS. Sync verified source files to both
MacSploit mirrors only after these checks pass.
