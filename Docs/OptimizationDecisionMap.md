# Anime Origin Optimization Decision Map

Goal: reduce Roblox client CPU, GPU, memory growth and executor overhead while
preserving every server-verified FastMode, UnitProgression, Main and AutoPlay
transition across lobby, first match, Replay/Next and later matches.

Each node keeps its original Question/Answer as the design intent. A **Shipped**
block records what actually landed and what the evidence was; a node is only
`resolved` when that block exists and is backed by a real run, not by reasoning.

## Operating context

The target host now runs ~54 Roblox clients at once (2 sockets, 44 cores, 88
threads) and was measured at 86% CPU / 80% RAM. At that load some clients attach
but never run the script, and some produce errors that never appear on a lightly
loaded machine. Every decision below is judged against that host, not against a
single client.

Two symptoms seen at that load are **not ours** and must not be optimised
against:

- `worm is not a valid member of ...PetsFolder.Toji_Evolved` and
  `Yato Sword is not a valid member of ...PetsFolder.Yato` — the game's own
  errors.
- `matchmaking-api/v1/client-status: HTTP 429 (Too Many Requests)` — Roblox
  rate-limiting a host with too many concurrent clients. The Loader's startup
  jitter reduces collisions; nothing in this project can remove it.

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

### Shipped

`Tests/check_optimizer_safety.py` enforces this statically: `Destroy` targets are
restricted to a PlayerGui candidate behind a descendant guard and to Workspace
roots named in `mapRootsToDestroy`, `.Parent =` is forbidden outright, and the
protection contract comment must still name Path.Model/Towers/Enemies.

## baseline: Measure The Actual Cost

Blocked by: protection-contract
Status: resolved
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

### Shipped

`Probes/PerformanceProbe.lua` captures the Roblox half on demand, and
`leakTelemetry` samples RAM/Lua heap/PlayerGui every 15 seconds into a single
overwritten `RuntimeLeakWatch_<UserId>_latest.json` (max 120 samples, so the
detector cannot itself become a leak).

The load question was then answered directly from captured multi-account
bundles, which is what unblocked the nodes below:

- **`getgc(true)` snapshots ranged 41k–404k objects, median ~95k.** Discovery ran
  on a fixed 0.5s interval against a 60s deadline, so one client could perform up
  to ~120 full heap walks. A loaded host made discovery slower, which caused more
  scanning — a positive feedback loop.
- **`logBuffer` grew without bound in 3 of 5 controllers**, and no controller
  capped its log *file*. Totals across successive bundles grew 0.1 → 0.5 → 1.6 MB;
  one AutoPlay log alone reached 2 MB.
- **`lockFps` was `false`** while every FPS cap under it was configured, so none
  of them applied. Dozens of background clients rendered as fast as the host
  allowed.

## script-runtime: Remove Controller Overhead

Blocked by: baseline
Status: resolved
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

### Shipped

- `getgc` discovery backs off (`wait = math.min(wait * 1.5, 8)`) instead of
  rescanning at a fixed interval until the deadline.
- Every controller bounds its log twice: an in-memory ring of
  `maximumRetainedLogLines`, and a file cap of `maximumLogBytes` (1 MB) after
  which the file restarts from the retained tail. Controllers without their own
  key inherit the same default.
- Main coalesces nonterminal report writes on `reportFlushInterval = 2` rather
  than re-encoding the whole report per diagnostic line.
- `InGameSettings` gates the speed monitor on `monitorGameSpeed == true and not
  isLobby`, and reads the cached replicated instance directly — removing two full
  `GetDescendants` traversals per check.
- `showHolograms = false` in production.

Still open, deliberately deferred until the changes above are measured on a real
night: a **Loader disk cache** (54 clients × 8 files per teleport ≈ 8,600 GitHub
requests/hour) and a **shared `getgc` snapshot across the 5 controllers** (5 heap
walks → 1). The shared snapshot risks reintroducing the stale-PlayerData bug, so
any TTL must be short and `rescanPlayerData` must always force a fresh walk.

## safe-game-profile: Disable Purely Visual Work

Blocked by: baseline
Status: resolved
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

### Shipped

`Optimizer.lua` implements it with `disableEffects`, `disablePostEffects`,
`disableLights`, `disableShadows` and `muteSounds`. New instances arrive through
`Workspace.DescendantAdded`, `Lighting.DescendantAdded` and a PlayerGui listener,
and are drained by a batched pass on `batchInterval = 0.75` with
`maximumBatchSize = 250` — never a per-frame rescan.

## farm-profile: Reduce Rendering Further

Blocked by: script-runtime, safe-game-profile
Status: resolved
Type: Prototype

### Question

How far can a farming profile reduce GPU and CPU work while AutoPlay remains
fully functional?

### Answer

Add configurable FPS capping, hide other players and noncritical decorations,
neutralize map textures/decals without deleting geometry, and optionally hide
tower/enemy rendering while preserving their models, positions and descendants.
Every mutation is class- and root-guarded. No broad name-only deletion.

### Shipped

`hideOtherPlayers`, `hideMapTextures` and `hideCombatModels` are on;
`stripHiddenGuiImages` clears preloaded card images under hidden GUI ancestry
only, spread over `maximumHiddenGuiImagesPerPass = 4000` to avoid a single-frame
hitch.

**The FPS floor is the one hard constraint here.** `task.wait` resolves on
Heartbeat, so frame time is the floor on every poll loop in the project. The
tightest is `statePollInterval = 0.1`; a 10 FPS cap is a 100ms frame sitting
exactly on that floor, which starves the verification windows every remote action
depends on. `lockFps` is therefore `true` at **30 FPS on all three caps** — half
the rendering work of an uncapped client, with a 33ms frame comfortably under the
floor. `check_optimizer_safety.py` asserts a ≥20 FPS floor (half the tightest
poll interval) rather than forbidding capping.

Lowering `backgroundFpsCap` below 30 is the next obvious saving, but it must be
measured against in-match placement timing first.

Two flags stay off despite being nominally "farm" behaviour, because both caused
real regressions: `disable3DWhenUnfocused` produced a white/blank screen, and
`hidePlayerGuiWhenUnfocused` left the stage/wave HUD hidden after refocusing —
the game can flip a HUD from disabled to enabled while the window is in the
background, and restoring the old boolean then hides it.

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

### Status note

`disable3DRendering` remains `false` and `Headless` remains opt-in. The automatic
fall-back to Farm on latency-budget overrun is **not implemented**; it is the
work this node still holds.

## orchestration: Start And Stop In The Right Context

Blocked by: script-runtime, safe-game-profile
Status: resolved
Type: Grilling

### Question

How should optimization cooperate with the current Config -> FastMode ->
UnitProgression -> Main -> AutoPlay lifecycle?

### Answer

Optimizer is independent and nonblocking. It reads Config, applies a lobby
profile immediately, then applies the stage profile after runtime readiness. It
publishes status but is not a Main bootstrap dependency. Teleport/rejoin creates
a fresh JobId state, and re-running the file remains idempotent.

### Shipped

Optimizer publishes `getgenv().AnimeOriginOptimizer`, stops a previous instance
on re-run, and stamps `jobId = game.JobId` so a stale lobby's state cannot leak
into a newly joined server. It is started by the Loader in its own `task.spawn`
and is not a bootstrap dependency for Main.

Startup is staggered at two independent levels, and the order inside `Loader.lua`
is load-bearing:

1. `game:IsLoaded()` is awaited first — Auto-Execute fires at client attach,
   which on a loaded host is long before the game is playable, and every
   controller reads live state.
2. `queue_on_teleport` is armed **before** any delay, so a teleport during the
   delay still brings the loader back instead of dropping the script.
3. Only then does the Loader jitter (`AnimeOriginLoaderJitter`, default 8s), so
   54 clients do not download 8 files and walk the Lua heap simultaneously.
   `optimizer.maximumStartupJitter` separately staggers the optimisation pass.

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

### Status note

Open on purpose. The FPS caps, log caps and discovery backoff are all live but
**have not yet been measured across a full night at 54 clients**. Until that
comparison exists, treat `lockFps = true` at 30 FPS as the conservative setting
it was chosen to be, not as a validated optimum.

The blocker on collecting that evidence is volume, not instrumentation: one
long-running account produced 568.6 KB across 12 files in a single bundle, so raw
logs from 54 accounts are unsendable even with the 1 MB per-file cap. Every
controller already publishes a live report to `getgenv()`
(`AnimeOriginFastModeReport`, `AnimeOriginUnitProgressionReport`,
`AnimeOriginInGameSettingsReport`, `AnimeOriginAutoPlayReport`,
`AnimeOriginMain`, `AnimeOriginLifecycle`), so a compact per-account digest is
the intended transport — not raw log shipping.
