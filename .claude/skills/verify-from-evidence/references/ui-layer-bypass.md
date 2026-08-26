# Working underneath a UI you are not using

Automating an application whose only intended interface is its UI. The techniques below
are the ones this project actually depends on, with the measurements that justified each.

**Scope.** This is about reaching the *same server-facing seam the UI uses* — reading
state the client already holds, and sending the requests the UI would have sent. It is not
about defeating anti-cheat, anti-tamper, or detection, and none of that is documented here.
If the thing standing between you and the seam is a security control rather than a
presentation layer, this file does not apply and you should stop.

---

## The principle

**The UI is a client of the same server you are.** It reads a replicated state table and
sends requests. Anything it can do is reachable at that layer, usually more reliably,
because you skip rendering, animation, input handling, and pathing.

Two consequences that drive everything below:

- **State the UI computes for itself is not evidence.** It never left the client.
- **Precondition the UI satisfies is not the precondition the server checks.** Find out
  which one the server actually checks, then satisfy *that* one directly.

---

## Reading state: the live object, not a copy of it

Walking the runtime heap (`getgc(true)` here; equivalent facilities exist in most managed
runtimes) gives you the client's own state tables without opening anything.

**The trap that cost this project the most:** a heap walk exposes *several* objects that
all look like the state you want. Only one of them is still being written to.

> Two accounts bound a **detached warm-up copy** at `getgc[510]` / `getgc[1808]` while the
> live wrapper sat at `getgc[84269]` / `getgc[86851]`. Every remote succeeded — the server
> said `Code Redeemed!`, the wheel returned a prize — while the bound copy stayed at zero.
> The run therefore summoned nothing and reached the stage with no units, with every log
> line reporting a healthy no-change result.

This is the worst class of bug in the whole project, because **the actions genuinely work
and the verification genuinely fails.** You conclude the action is broken and go fix the
wrong thing.

Rules that fall out of it:

1. **Prefer the container over the inner table.** The server replaces `container.State`
   wholesale after some operations. Holding the container survives that; holding the inner
   table silently detaches you.
2. **Resolve by structure, never by index.** Heap indices drift every session. Match on the
   shape of the object (which keys it has, which types they are).
3. **Scan the whole heap, do not take the first match.** First-match is a lottery between
   live and dead objects.
4. **Give the live object a grace window.** Prefer the wrapper for a bounded period before
   settling for a bare table, so one that replicates a moment later still wins.
5. **Re-scan at every verification point.** Re-reading the table you already hold cannot
   detect that you detached from it.
6. **Log which one you bound.** `trace("PlayerData bound", { source = ..., wrapper = ... })`
   is the single most diagnostic line in that file. Without it, "no change" is unfalsifiable.

---

## Acting: satisfy the server's precondition, not the UI's choreography

The server here refuses a map-selection request until it has seen the player enter a
physical pod. The UI satisfies that by having you walk in. What the server actually
observes is a `Touched` event on a specific part.

That part carries a `TouchInterest`, which means the handler is connected **server-side** —
so the event can be raised directly:

```lua
firetouchinterest(root, doorUIPart, 0)
task.wait(touchHoldDelay)          -- a hold, then release; the pair is what registers
firetouchinterest(root, doorUIPart, 1)
```

**Measured, not assumed.** A dedicated probe fired this once while the character stood
**180 studs away and never moved**. The server answered `MapSelect` and
`UpdatePlayersInside` naming that player, then accepted the selection. First attempt, no
walking, no position write.

Why it mattered: fresh accounts failed the walk on **all 8 doors on every recorded run**
and had never once entered a stage. The walk is not a dependable gate; the touch is.

**Keep the fallback.** The walk path is retained behind a config flag for runtimes without
the capability, and for the day the server stops trusting a replicated touch. A bypass that
removes its own fallback is one server patch away from a dead fleet.

---

## Proof still comes from the server, always

Bypassing the UI changes *how you act*. It changes nothing about *how you verify*. Every
step in this project keeps its server-side evidence:

| action | proof required |
| --- | --- |
| `StartSelection` | a matching `AfterMapSelect` |
| `StartTeleport` | `TeleportGui` or `LocalPlayer.OnTeleport` |
| any claim | a server-written field moving in the live state object |

Firing a remote is never success. See the parent `SKILL.md`, Rule 1.

---

## Negative results are load-bearing — write them down

> `preferDirectSelection` was built on the assumption that the selection remote would be
> accepted without entering the pod at all. The server refused it **26 out of 26 times**,
> with no `MapSelect` of any kind — on the same account and session where the walk was also
> failing on all 8 doors.

The config key is still there, defaulted `false`, with that comment attached. It costs one
line and stops the next person — or the next agent — from spending a night rediscovering
it. Keep a "disproven theories" section in the docs and put every one there.

---

## Surviving context resets

When the host tears down and rebuilds the scripting context (a place transition here; a
navigation, respawn, or worker restart elsewhere), anything you loaded is gone.

```lua
queue_on_teleport('loadstring(game:HttpGet(LOADER_URL, true))()')
```

Two rules:

1. **Arm it before the first yield.** Any wait after attach is a window in which a
   transition drops the script permanently. This project's loader arms the queue *before*
   it waits for the game to load, because that wait is the longest one in the run.
2. **Queue the small bootstrap, not the payload.** Every joined context re-downloads fresh
   files, so a stale queued copy can never pin an old version.

If the capability is missing, say so loudly on the diagnostic channel. Without it the
script silently ceases to exist after the first transition, which looks exactly like the
script never working.

---

## Fleet scale: do not become your own outage

Dozens of clients on one host, attaching at the same moment, all downloading the same files
and all walking the heap at once. That thundering herd *is* what turns a busy host into
failed attachments.

- **Jitter every startup.** `task.wait(math.random() * jitter)` before the download burst,
  after the transition queue is armed.
- **Back off heap scans.** Start at a short interval and widen it; a full heap walk is
  slowest exactly when the host is loaded.
- **Retry downloads with backoff, and reject empty 200s.** An empty body behind a throttling
  proxy compiles into an empty chunk that does nothing at all.
- **Expect the platform's own rate limits and stop debugging them.** `HTTP 429` from the
  platform's matchmaking API on a host running many clients is not your bug. Jitter reduces
  collisions; it does not remove the limit. Write that in known-issues so nobody chases it.

---

## Checklist for a new bypass

- [ ] What does the **server** check? Not what the UI does — what arrives on the wire.
- [ ] Can I raise that directly, or am I simulating the UI's choreography?
- [ ] Did I **measure** it with a probe, or am I assuming? Record the result either way.
- [ ] Is the state I read the **live** object, or a copy the server abandoned?
- [ ] Does verification re-read from source, or re-read a table I might have detached from?
- [ ] Is the old path still available behind a flag?
- [ ] If this stops working after a server update, what line in the log will say so?
