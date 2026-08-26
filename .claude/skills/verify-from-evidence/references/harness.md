# Executable harnesses and mutation-tested gates

Two techniques. The first proves the code is *correct*; the second proves your tests can
*fail*. Most projects have neither, and both are cheap.

---

## Part 1 — Running code that cannot run in situ

Plenty of code cannot be executed where it is tested: a game script needing a live client,
an embedded module needing hardware, a plugin needing a host application. The usual
response is to test the source with regexes and hope. You can do better.

**Stub the host, run the real file, splice nothing.**

### The four pieces

**1. Stub only what the file touches.** Start with nothing, run, add what the error names.
Resist building a fake framework — you want the smallest surface that lets the real code
execute.

```lua
-- Roblox-ish globals, ~40 lines total
function typeof(v) local t = type(v); return (t == "table" and v.__instance) and "Instance" or t end
game = { PlaceId = 129932912185311, JobId = "job-under-test",
         GetService = function(_, name) return services[name] or { __instance = true } end }
local disk, folders = {}, {}          -- in-memory filesystem, also your assertion surface
function writefile(p, b) disk[p] = b end
function appendfile(p, b) disk[p] = (disk[p] or "") .. b end
```

An in-memory filesystem is worth more than a temp directory: it lets you assert *exactly*
which paths were written, which is how "nothing was written into the state folder" becomes
a one-line check.

**2. A virtual clock.** Non-negotiable. Deadline, timeout, and stall logic all depend on
elapsed time, and a test that waits 90 real seconds is a test nobody runs.

```lua
local now = 0
local realOs = os                      -- some runtimes freeze stdlib tables, so rebind
os = setmetatable({                    -- the global rather than assigning into it
    clock = function() return now end,
    time  = function() return 1700000000 + math.floor(now) end,
}, { __index = realOs })

task = {
    spawn = function(fn) table.insert(spawned, fn) end,   -- capture, drive manually
    wait  = function(s) now += tonumber(s) or 0.05 end,
}
```

Capturing `spawn` instead of running it lets you drive background loops deliberately.
Terminate them by flipping the condition they loop on:

```lua
local watchdog = 0
task.wait = function(s) now += s; watchdog += 1; if watchdog >= 3 then game.JobId = "gone" end end
spawned[1]()                                   -- the reaper, now guaranteed to exit
```

**3. Splice the real sources verbatim.** No test-only variant — a harness that edits the
code under test proves nothing about the code that ships. If the runtime has no module
loader (or gives each file its own globals), concatenate. Wrap each file so its top-level
`return` stays legal:

```python
def wrap(name):                       # -> local Config = (function() <source> end)()
    return f"local {name.split('.')[0]} = (function()\n{read(name)}\nend)()"

harness = template.replace("--@@INJECT_CONFIG@@", wrap("Config.lua")) \
                  .replace("--@@INJECT_DIAG@@",   wrap("Diag.lua"))
```

Say so in the driver's stderr: line numbers in the assembled chunk are not line numbers in
any real file, and a confused reader will waste an hour.

**4. Report the exit code out of band.** Sandboxed runtimes often lack `os.exit`. Print a
sentinel and let the driver translate it:

```lua
print("@@RESULT " .. tostring(failures))
```

```python
if reported is None:
    print("the harness did not run to completion", file=sys.stderr)
    return result.returncode or 1     # checks that printed "ok" prove nothing about
return 1 if reported else 0           # the ones that never ran
```

### What to assert

Replay the **real failure shapes**, not synthetic ones. For a diagnostics recorder that
meant: a healthy operation, a silent no-op, a cross-component chain, an operation that
never closes — each mirroring a bug that actually happened.

Then assert the **safety contract** explicitly, because it is the part review always
assumes:

```lua
check("a garbage name still returns a usable handle", ...)
check("closing twice does not raise", ...)
check("a double close is counted, not hidden", ...)     -- silently swallowing is its own bug
check("an unencodable payload does not raise", ...)
check("output still writes after an unencodable payload", ...)
check("nothing was written into the state folder", ...)
```

### Emit the artifacts

Have the harness hand its in-memory filesystem back so the driver can write it out:

```
@@FILE AnimeOriginDiag/digest_1000000001.json
@@DATA {"version":1,...}
@@END
```

Now downstream analysis tools are tested against output the code **actually produced**,
rather than a sample hand-written to match what the analyzer expects. In this project that
step immediately surfaced case-file #8 — the analyzer's first real run printed
`digest encode failed`.

---

## Part 2 — Mutation-testing static gates

A static gate reads source and asserts an invariant. It is the cheapest defence against a
later "cleanup" quietly removing a hard-won fix. It is also the easiest test in the world
to write *wrong*, because a regex that matches nothing passes exactly like a regex that
matches the right thing.

**A gate that cannot fail is decoration. Prove yours can.**

```python
MUTANTS = [
    (file, original_text, broken_text, "one-line label"),
    ...
]
for path, old, new, label in MUTANTS:
    source = path.read_text()
    assert source.count(old) == 1, label      # anchor must be unambiguous
    path.write_text(source.replace(old, new, 1))
    result = subprocess.run([sys.executable, gate], capture_output=True)
    path.write_text(source)                   # ALWAYS restore, even on exception
    print(("caught " if result.returncode else "MISSED ") + label)
```

**Mutate the real defect, not a caricature.** The most valuable mutant is the bug that
actually shipped. This session's gate for the `returnToLobby` contract was mutated with
the literal regression (`return accepted` → `return false`) and caught it — which is the
only evidence that matters.

### The two survivors this session, and what they teach

Both loops found a surviving mutant on the first pass:

**A loose pattern satisfied by a different call site.** The check asserted
`\tdata = sanitise\(data\)` appeared. Removing it from `closeNode` left the gate green
because an *unrelated* function contained the same line. Fix: anchor patterns to their
neighbours, not to their own text.

```python
("closeNode", r"node\.reason = clip\(reason\)\n\tdata = sanitise\(data\)\n\tnode\.data = data"),
```

**A pattern requiring a trailing newline the real defect did not have.** The check looked
for `\n\t+return\n`, but the offending `return` was the last statement in its block, so the
captured region ended *at* it with no trailing newline. Fix: `\n\t+return(?![a-zA-Z])`.

Both gates passed happily against broken code. Neither would have been noticed by reading.

### Practical notes

- Restore the file in a `finally`, or a crashed run leaves the repo mutated.
- Keep the mutation loop as a throwaway during development. Committing it is optional; the
  value is in having run it, and the tightened patterns are what ships.
- Aim for one mutant per invariant the gate claims. If you cannot construct a mutant for
  some assertion, that assertion probably is not testing anything.

---

## Where the three test kinds sit

| kind | reads | catches | example failure it caught |
| --- | --- | --- | --- |
| static gate | source | an invariant silently deleted later | a claim gated on a UI-written flag reappearing |
| executable harness | the real file, under stubs | logic wrong in ways source-reading cannot see | edge label written to the wrong node |
| capture diagnoser | artifacts from real runs | the gap between what the code says and what the run did | 396/396 records with a constant flag |

They are not substitutes. The static gate would never have found the edge-label bug; the
harness would never have found the constant flag; the diagnoser cannot run before the code
ships. Build all three, and mutate the first one.
