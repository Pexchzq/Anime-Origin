---
name: verify-from-evidence
description: >
  How to build and debug unattended automation whose failure mode is silence — fleets of
  bots, scrapers, game scripts, schedulers, batch jobs, anything that runs without a human
  watching. Teaches the rule that success is evidence that appeared, never a call that was
  made; the four verdicts (OK / NO_OP / FAIL / STUCK) that ordinary logs cannot produce;
  bounded waits; contract changes; fleet-scale diagnostics; mutation-tested static gates;
  and how to report findings without overclaiming.
  Use when work involves a long-running unattended process, a bug that "should be impossible"
  because the logs look healthy, instrumentation or diagnostics design, or any code whose
  correctness depends on a remote system actually doing something.
---

# Verify from evidence, not from control flow

## The failure mode this exists for

Every bug shipped in the system this was learned from had exactly one shape:

> **A function ran, returned without raising, wrote a log line that looked healthy, and accomplished nothing.**

Four real examples, all from production, all invisible for weeks:

| what the code did | what the log said | what was actually true |
| --- | --- | --- |
| `claimAllQuests` returned early on a `Claimable` flag | nothing — clean exit | the remote was **never fired once, on any account, in any run** |
| `returnToLobby` fired its remote, server acknowledged | `server accepted Return To Lobby` | the character never left; 6 accounts idle all night |
| `claimConfiguredRewards` enforced a 9s budget | `FATAL: claim budget exceeded` | the jobs were still succeeding — `Daily Wheel verified` was written **after** the FATAL line |
| `returnToLobby` lost its `return true` in a refactor | `END_ACTION not verified` | every act-end killed the controller; the error was swallowed by a local `xpcall` |

None of these are catchable by a log that records **what the code did**, because in every case the code did exactly what it was told. Logging harder does not help. The instrument has to change.

---

## Rule 1 — Success is evidence that appeared, not a call that was made

Firing a remote, issuing a command, POSTing to an API, enqueueing a job: all of these are **requests**. None is a result.

Before writing the action, name the observable that would prove it worked. Then wait for it, bounded.

```lua
-- WRONG: the call is treated as the outcome
remote:FireServer("ClaimAllQuests")
log("Claimed quests.")            -- a lie the moment the server no-ops

-- RIGHT: name the proof, then go and look for it
local before = readQuestState()   -- server-written field
remote:FireServer("ClaimAllQuests")
local proved = waitUntil(function()
    return readQuestState().claimed > before.claimed
end, settlementTimeout)
```

The proof must come from state **the other side writes**. A field your own UI computes is not evidence (see Rule 3).

---

## Rule 2 — Four verdicts, not two

Two-valued thinking (`ok` / `error`) is what hides these bugs. Use four:

| verdict | meaning |
| --- | --- |
| `OK` | ran, and the declared evidence appeared |
| `NO_OP` | ran, returned cleanly, and **the evidence never appeared** |
| `FAIL` | ran and reported its own failure |
| `STUCK` | started and never finished |

`NO_OP` and `STUCK` are the two verdicts an ordinary log cannot produce, and between them they covered **every** stall ever captured in this system. Build them in from the start.

`STUCK` needs something actively looking: a reaper that periodically scans open operations against their deadlines. Without it, "which function is this process frozen in?" is unanswerable.

**Be precise about what `STUCK` claims.** A reaper cannot distinguish "still waiting" from "something raised past the close". Say both in the reason and let the source anchor settle it — a verdict that overclaims sends the investigation the wrong way.

---

## Rule 3 — Never gate an action on a precondition you have not proven is real

The single most expensive bug in this system:

```lua
if before.claimable <= 0 then return end   -- blocked 100% of claims, forever
```

`Claimable` looked like a server field. It was written by the game's **UI when it rendered**. This project never opens UI, so it read `false` in **396 of 396** captured records while the sibling field `Claimed` moved independently. Every state file recorded `attempted: false` and looked perfectly healthy.

**Decide by cost:**

- The action **spends** something (money, credits, a rate-limit budget, an irreversible write) → a precondition is mandatory, and it must be verified against real captured data.
- The action is **free and idempotent** (the other side no-ops when nothing is due) → fire it and prove from the result. A guard here buys nothing and can silently block everything.

Corollary: when you find a field you are about to branch on, check a real capture for whether it ever takes the other value. If it is constant across every record you have, it is not the field you think it is.

---

## Rule 4 — Every wait is bounded, and a timeout is evidence

Both directions are bugs, and they look nothing alike:

- **Unbounded wait** (`signal:Wait()`, `WaitForChild(name)` with no timeout) → a process that is attached, alive, and permanently silent. Indistinguishable from "never started".
- **Giving up instantly** → in this system, an object that had not replicated yet caused 6 entry attempts **and** 3 supervisor restarts to burn *before the object existed*. It appeared seconds later, to a dead controller.

Three properties every wait needs:

1. **A bound.** Always.
2. **The timeout feeds the same policy as a self-reported failure.** A worker that times out did not finish; treat it identically to one that said so. In this system the gate called `fail()` unconditionally on timeout, ignoring its own `fatalTasks` config, so a slow non-critical worker killed a route that a failed one would not have.
3. **The budget belongs to the operation, not to one attempt.** A per-call deadline inside a supervised retry loop silently multiplies: 4 restarts × 300s = 20 minutes of a process standing still. Anchor the deadline once, outside the retry.

---

## Rule 5 — Changing what a function returns is changing its contract

Told plainly because it was my own regression, shipped and pushed:

Adding a settle watchdog to `returnToLobby` meant the function could no longer return `true` on **any** path — a successful teleport destroys the script mid-call, so "did we arrive?" became structurally unanswerable from inside. The seven callers were not updated. Five of them read:

```lua
if not returnToLobby(reason) then
    fail("END_ACTION", "...")     -- now runs every single time
end
```

`fail()` raised, a local `xpcall` caught it, the controller disabled itself and disconnected every listener, and the error never reached the supervisor that would have restarted it. Accounts froze permanently at the end of every match.

**Procedure, non-negotiable:**

1. Changing a return type, adding a return path, or removing one → grep every caller **in the same commit**.
2. If a function **cannot** return a value by construction, that is a design fact. Document it at the return site and make the callers reflect it. `-- Acceptance, not arrival. A caller must never read this as "we left".`
3. Return what the function can honestly know. `returnToLobby` knows whether the server *acknowledged*; it can never know whether the client *arrived*. Returning the second was always a lie.

---

## Rule 6 — Diagnostics must be incapable of breaking what they observe

A recorder attached to N unattended processes has asymmetric failure costs: missing an event costs one capture, raising an exception costs the whole fleet.

- Every public entry point `pcall`-wrapped; return an **inert handle** on failure so call sites can chain unconditionally.
- Absent recorder → no-ops at every call site, not `nil` derefs.
- Its own download/import is **non-fatal**, unlike every other module.
- Every retained container has a ceiling: byte caps, ring buffers, node limits, depth limits.
- Background loops bound to the session/job they started in — never `while true`.
- **Sanitise payloads at ingestion.** One unencodable value (a cycle, a NaN, a handle object) reaching retained state kills serialisation for the rest of the run — silently. That is the worst possible failure for a diagnostics tool. Bounded deep-copy at the boundary; never trust a caller's table.

---

## Rule 7 — A capture must be sendable, or it does not exist

Raw logs do not scale. One account produced 568 KB across 12 files; 54 accounts is 30 MB nobody will ever read.

- Write a **digest per unit**: the verdict, the chain, open operations, per-function counters, a bounded tail. 4–8 KB.
- Keep raw events too, hard-capped (64 KB), for when the digest is not enough.
- **Rewrite the digest on a timer, not at completion.** A stuck process never reaches completion — and that is the one you most need to read.
- Separate the diagnostics folder from the state folder. If deleting logs and destroying resumable state look identical, someone will eventually do the second while meaning the first.
- **Cluster on the analysis side.** Grouping N digests by failure signature turns a night of reading into one line: `6 accounts: X · 6 accounts: Y · 28 healthy`.

---

## Rule 8 — Record causal edges, do not infer them

One unit dying is usually several things in a row. Two edge kinds make a chain reconstructable rather than guessable:

- **parent** — an operation opened inside another. Key the stack **per coroutine/thread**, or concurrent workers braid into one bogus chain.
- **signal** — an operation whose outcome depended on a value another component wrote. **Record it at the read**, not the write: `step:because("lifecycle.FastMode")`. That makes the dependency a fact, not an assumption about who probably influenced whom.

Then name the **head** — the earliest non-OK link. Everything after it is a consequence, and *fixing a consequence is how a bug comes back*.

---

## Rule 9 — Three kinds of test, and mutation-test the gates

| kind | reads | catches |
| --- | --- | --- |
| **static gate** | source | invariants silently removed by a later "cleanup" |
| **executable harness** | runs the real file under stubs | logic that is wrong in ways source-reading cannot see |
| **capture diagnoser** | real artifacts from real runs | the gap between what the code says and what the run did |

The harness is the one people skip, and it is the one that pays. Writing one for the recorder in this session found **three real bugs review had missed**: an edge label written onto the wrong node and left there (so it leaked into later, unrelated output); events written before an identifier resolved going to a second file, splitting every capture at exactly the moment that matters; and one unencodable payload killing serialisation permanently and silently.

Use a **virtual clock**. Deadline and stall logic depends on elapsed time, and a test that waits 90 real seconds is a test nobody runs.

**Then mutate your gates.** A gate that cannot fail is decoration:

```
for each invariant the gate asserts:
    break it in the source
    run the gate
    assert it fails
    restore
```

This session ran that loop twice and found a surviving mutant **both times** — a loose regex satisfied by a different call site, and a pattern requiring a trailing newline that the real defect did not have. Both gates passed happily against broken code until mutated.

---

## Rule 10 — Report honestly: separate what you verified from what you suspect

Three tiers. Never blend them into one confident paragraph.

1. **Verified from source** — "`returnToLobby` has no `return true` on any path" — a claim anyone can check by reading.
2. **Verified from a captured run** — "396 of 396 records had `Claimable: false`" — a claim backed by data you actually loaded.
3. **Consistent with the evidence, unproven** — "the screenshot matches this bug's signature" — say *exactly this*, and say what capture would settle it.

Also maintain a written **"not yet proven"** list alongside the known-issues doc. When a fix has shipped but never run in production, that is not a fix that is confirmed — the first capture is the *test*, not the confirmation.

**A decision to skip something is a claim too.** In this system, adding a watchdog to one teleport path but skipping the identical second path — reasoning it was "less critical" — cost 6 accounts a full night. If two paths have the same failure mode, they get the same guard, or you write down why not.

---

## Working checklist

Before writing an action:
- [ ] What observable proves this worked? Who writes it — me or the other side?
- [ ] Does this action spend anything? If not, drop the precondition.
- [ ] Is every wait bounded, and does the timeout route into the same policy as a failure?

Before closing a change:
- [ ] Did I change any function's return contract? Grep every caller **now**.
- [ ] Can this operation report `NO_OP` and `STUCK`, not just ok/error?
- [ ] Is every new container bounded?
- [ ] Did I add a static gate, and did I **mutate it** to prove it fails?
- [ ] Does the fix touch every path with the same failure mode, or did I write down why not?

Before reporting:
- [ ] Is each claim tagged: verified-from-source / verified-from-capture / hypothesis?
- [ ] Did I say what capture would settle the open questions?
- [ ] Is anything that has never run in production listed as unproven?

---

## References

- `references/case-files.md` — the eight real bugs, each with symptom, what the log said, what was actually true, why it was invisible, and the rule it produced.
- `references/harness.md` — building an executable harness for code that cannot run in situ (stubs, virtual clock, splicing real sources), plus the mutation-testing recipe for static gates.
