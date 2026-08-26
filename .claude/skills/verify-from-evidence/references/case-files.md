# Case files

Eight real bugs from one unattended automation fleet (~54 Roblox clients running Lua
scripts against a live game server, driven by `getgc` heap reads and RemoteEvents).

They are recorded in full because abstract principles do not transfer — the shape of a
specific bug does. Every one of these was invisible in ordinary logs, and every one cost
real running time before it was found.

Read the **Why it was invisible** line in each. That is the transferable part.

---

## 1. The precondition that could never be satisfied

**Symptom** — Quests were never claimed on any account. The remote demonstrably worked
when fired by hand, in both the lobby and in-stage.

**What the log said** — Nothing. `claimAllQuests` returned cleanly every time. The state
file recorded `attempted: false, claimable: 0` and looked healthy.

**What was actually true** — The function was gated on `PlayerData.Quests[*].Claimable`:

```lua
if before.claimable <= 0 then return end
```

`Claimable` is written by the game's quest **UI when it renders**, not replicated by the
server. This project reads `PlayerData` without ever opening UI, so the flag was `false`
in **396 of 396** captured records — while the sibling field `Claimed` moved on its own
(one account showed `claimed: 9`). The verification suffered the identical assumption:
`now.claimable < before.claimable` is `0 < 0` for every account, so even a *successful*
claim would have been reported unproven.

**Why it was invisible** — Returning early is not an error. The state file's shape was
indistinguishable from "there was nothing to claim". The remote was never fired **once,
on any account, in any run**, for the entire life of the project.

**Rule produced** — Rule 3. Free, idempotent actions get fired and proven from the result.
Preconditions are for actions that spend something. And: check a real capture for whether
a field you are about to branch on ever takes the other value.

---

## 2. Acceptance mistaken for arrival

**Symptom** — 6 of 40 accounts finished the final act and stood in the stage all night.

**What the log said** — `server accepted Return To Lobby`, persisted to state as the last
successful transition. Everything downstream reported success.

**What was actually true** — The server acknowledging `TeleportToLobby` is not Roblox
moving the client. On a rate-limited host the acknowledgement arrives and the teleport
never lands. The code treated the acknowledgement as the outcome and returned.

The identical watchdog **had** been added to the stage-entry teleport in the same session
and deliberately **skipped** here, on the reasoning that "returning to lobby is less
critical" and stall recovery would cover it. It did not.

**Why it was invisible** — Every artifact reported success, because by the code's own
definition it *was* success. Only the absence of a subsequent place change disproved it,
and nothing was watching for that.

**Rule produced** — Rule 1, and the closing note of Rule 10: two paths with the same
failure mode get the same guard, or you write down why not.

**The trick that made it detectable** — A real place transition destroys the script. So
*reaching the line after the settle wait is itself proof the teleport never landed.* When
success destroys the observer, absence of the observer's death is the evidence.

---

## 3. The budget that killed work in progress

**Symptom** — 6 of 40 accounts died in the lobby during startup.

**What the log said** — `FATAL: claim budget exceeded`.

**What was actually true** — Five reward jobs ran concurrently under a shared
`claimSettlementTimeout + 5` = **9 second** budget. But each job is a *sequence* of
verified round-trips, not one call: one of them walked six configured indices and waited
the full settlement timeout on each unavailable one — 6 × 4 = **24 seconds** on its own.
The budget was impossible from the first day it was written.

The logs prove the jobs were still succeeding when they were killed: `Daily Wheel
verified` was written **after** the `FATAL` line.

And the fatality cascaded: raising made the worker `FAILED`, which the router treats as a
fatal bootstrap task, which killed the entire route.

**Why it was invisible** — The failure was loud and *plausible*. "Budget exceeded" reads
like a real diagnosis, so nobody questioned whether the budget was correct.

**Rule produced** — Rule 4.3 (budget belongs to the operation, sized from the slowest path)
and: a best-effort operation must never be fatal. Compute budgets from the work, never
from a round number.

---

## 4. The contract change that killed every match end

**Symptom** — Accounts froze in the stage after winning, with the end-of-match vote
buttons showing `Next(0/1)` and `Replay(0/1)` — zero votes cast.

**What the log said** — Nothing useful. The controller had disconnected its own listeners.

**What was actually true** — Adding the settle watchdog from case 2 meant `returnToLobby`
had **no `return true` on any path** — arrival destroys the script mid-call, so it became
structurally unanswerable from inside. Seven callers were not updated. Five read:

```lua
if not returnToLobby(reason) then fail("END_ACTION", "...") end
```

So `fail()` ran on every act that ended. A **local** `xpcall` caught it, set
`controller.active = false`, disconnected every listener — and the error never reached the
route supervisor that would have restarted it.

Two further callers were also silently broken, including an "escape an unusable place"
recovery added in the very same commit, which could therefore never have taken effect.

**Why it was invisible** — Every individual piece was correct. The watchdog was right, the
callers were right *before*, and the `xpcall` was right for its original purpose. The bug
lived in the seam.

**Rule produced** — Rule 5. Grep every caller in the same commit as a return-contract
change. And: an `xpcall` that swallows an error prevents the supervisor above it from ever
seeing the failure — scope error handling to what it can actually recover from.

---

## 5. Silent startup death

**Symptom** — Accounts waited out a 300-second bootstrap gate and then failed, on a host
under heavy load.

**What was actually true** — A worker publishes `RUNNING` early, then executes hundreds of
lines of module-scope initialisation before its own error handler exists. A raise in that
window unwinds past every publish site it has, so it never writes a terminal status. Its
lifecycle entry stays `RUNNING` forever, and to the waiting gate "no signal" is
indistinguishable from "still working".

**Why it was invisible** — The absence of a signal was being read as patience.

**Rule produced** — **Prolonged absence IS a signal.** After a startup grace window,
promote "never reported" to `FAILED` and feed it through the same fatal/non-fatal policy
as a self-reported failure. Separately: the component that *starts* workers is the one
place that sees every such death — have it publish the failure on their behalf.

---

## 6. Failure counted as success

**What was actually true** — A teleport-state handler incremented the same generation
counter for every state, including `Enum.TeleportState.Failed`. Downstream code waited for
that counter to advance as proof the teleport succeeded — so **a failed teleport satisfied
the success condition.**

**Why it was invisible** — The counter did exactly what it was written to do: count
events. Nobody noticed it was being read as counting *successes*.

**Rule produced** — When one counter serves as evidence, make sure every increment is
evidence of the *same thing*. Split failure generations from success generations.

---

## 7. The place nobody recognised

**Symptom** — 6 accounts stranded in a place with `main` failing its context check four
times and the play controller restarting five times, then both stopping.

**What the log said** — `Neither lobby portal nor stage runtime loaded.` True of a lobby
whose objects have not replicated, of a stage whose match never started, **and** of a place
the project does not recognise at all. Three different problems, one message.

**Rule produced** — A diagnostic that is true of three different causes is not a
diagnostic. Report **where** the resolution broke, by walking the expected path and
recording each segment: `MainFolder=ok > Lobby=ok > MapSelectors=MISSING`.

Also: when a process is somewhere it cannot function, it must have an escape action.
These six had none and idled until morning.

---

## 8. The diagnostics tool that stopped diagnosing

**Symptom** — Found by the executable harness before it ever shipped: an analyzer run
against real recorder output printed `digest encode failed` for the whole account.

**What was actually true** — One retained payload contained a cyclic table. Serialising
the digest raised, and because the digest is rebuilt from the same retained state every
cycle, it raised **forever after** — silently, with the last good digest still on disk
looking current.

**Why it was invisible** — Per-record serialisation failures were already handled. The
whole-digest path was not. And the failure mode of a diagnostics tool is *the absence of
new information*, which looks exactly like *nothing new happening*.

**Rule produced** — Rule 6, last bullet. Sanitise at ingestion with a bounded deep copy:
depth cap (which doubles as the cycle guard), width cap, string cap, and explicit handling
for NaN, ±infinity, and non-serialisable handle types. Never retain a caller's table.

Two sibling bugs from the same harness run:

- An edge label was written onto the node it pointed **at** and left there. The leaf ended
  up unlabelled, and because the digest rebuilds every 10 seconds, the stale label
  resurfaced in later chains that never had that edge. *Mutating shared state during a
  read-only build is a bug even when the read looks correct.*
- Events emitted before an identifier resolved were written to `events_unknown` while later
  ones went to `events_<id>` — splitting every capture across two files at exactly the
  window (the first seconds after start) where a process that never starts spends its
  entire life. *Buffer until the key is known; never fall back to a placeholder filename.*
