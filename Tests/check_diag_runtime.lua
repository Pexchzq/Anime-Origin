--!nocheck
-- Executable proof that Diag.lua works, not just that it parses.
--
-- Every other test in this folder reads Lua source or reads captured artifacts.
-- Neither can answer the only question that matters about a recorder: when the run
-- goes wrong, does it actually produce the right verdict? So this stubs the Roblox
-- and executor globals, drives a virtual clock, replays the two failure shapes from
-- the captured night, and asserts the digest.
--
--     Tests/check_diag_runtime.py        (assembles this file and runs luau)
--
-- The virtual clock is the point. STUCK detection depends on real elapsed time, and
-- a test that waits 90 real seconds is a test nobody runs.

-- ---------------------------------------------------------------- virtual clock
-- The luau CLI freezes the stdlib tables, so the clock is swapped by rebinding the
-- global `os` to a shim that falls through to the real one for everything else.
local now = 0
local realOs = os
os = setmetatable({
	clock = function() return now end,
	time = function() return 1700000000 + math.floor(now) end,
}, { __index = realOs })

local spawned = {}
task = {
	spawn = function(fn) table.insert(spawned, fn) end,
	wait = function(seconds) now += tonumber(seconds) or 0.05 end,
}

-- ------------------------------------------------------------ Roblox-ish globals
function typeof(value)
	local basic = type(value)
	if basic == "table" and value.__instance then return "Instance" end
	return basic
end

local function encodeJson(value, seen)
	seen = seen or {}
	local kind = type(value)
	if value == nil then return "null" end
	if kind == "boolean" or kind == "number" then
		if kind == "number" and (value ~= value or value == math.huge or value == -math.huge) then
			error("cannot encode non-finite number")
		end
		return tostring(value)
	end
	if kind == "string" then
		return '"' .. value:gsub('[%c"\\]', function(c)
			if c == '"' then return '\\"' end
			if c == "\\" then return "\\\\" end
			if c == "\n" then return "\\n" end
			return string.format("\\u%04x", string.byte(c))
		end) .. '"'
	end
	if kind ~= "table" then error("cannot encode " .. kind) end
	if seen[value] then error("cycle") end
	seen[value] = true
	local parts = {}
	if #value > 0 then
		for _, item in ipairs(value) do table.insert(parts, encodeJson(item, seen)) end
		seen[value] = nil
		return "[" .. table.concat(parts, ",") .. "]"
	end
	local keys = {}
	for key in pairs(value) do table.insert(keys, tostring(key)) end
	table.sort(keys)
	for _, key in ipairs(keys) do
		local raw = value[key] ~= nil and value[key] or value[tonumber(key)]
		table.insert(parts, encodeJson(key, seen) .. ":" .. encodeJson(raw, seen))
	end
	seen[value] = nil
	return "{" .. table.concat(parts, ",") .. "}"
end

local HttpService = { __instance = true }
function HttpService:JSONEncode(value) return encodeJson(value) end

-- Deliberately a synthetic id. This repository is public and auto-executed by every
-- client; a real UserId in a fixture is a permanent disclosure for no test value.
local Players = { __instance = true, LocalPlayer = { __instance = true, UserId = 1000000001 } }

-- Config.lua holds real map coordinates, so the datatype has to exist for the file to
-- load. Nothing in Diag touches it; this is purely so the REAL Config can be spliced
-- in rather than a stripped copy that might not match what ships.
Vector3 = { new = function(x, y, z) return { __instance = true, X = x, Y = y, Z = z } end }

game = {
	__instance = true,
	PlaceId = 129932912185311,
	JobId = "job-under-test",
	GetService = function(_, name)
		if name == "HttpService" then return HttpService end
		if name == "Players" then return Players end
		return { __instance = true }
	end,
	IsLoaded = function() return true end,
}

-- ------------------------------------------------------------- executor file API
local disk = {}
local folders = {}
function makefolder(path) folders[path] = true end
function isfolder(path) return folders[path] == true end
function writefile(path, body) disk[path] = body end
function appendfile(path, body) disk[path] = (disk[path] or "") .. body end
function isfile(path) return disk[path] ~= nil end
function readfile(path) return disk[path] end

local env = {}
function getgenv() return env end

-- ---------------------------------------------------------------------- helpers
local failures = 0
local function check(label, condition, detail)
	if condition then
		print(string.format("  ok    %s", label))
	else
		failures += 1
		print(string.format("  FAIL  %s%s", label, detail and ("  -- " .. detail) or ""))
	end
end

-- ============================================================================
-- The luau CLI has no io library and does not share globals between files, so the
-- driver splices the two real production files in here verbatim. They are wrapped as
-- immediately-called functions purely so their top-level `return` stays legal.
print("[DiagRuntime] loading Config.lua + Diag.lua under stubs")
--@@INJECT_CONFIG@@
--@@INJECT_DIAG@@

check("Diag published on getgenv", env.AnimeOriginDiag == Diag)
check("recorder enabled from Config.debugRecorder", Diag.enabled == true)
check("folder is NOT the state folder", Diag.folder ~= "AnimeOrigin" and Diag.folder == "AnimeOriginDiag",
	tostring(Diag.folder))
check("reaper was spawned", #spawned == 1)

-- ---------------------------------------------------------------------------
-- Shape 1: a step whose declared evidence appears.
-- ---------------------------------------------------------------------------
print("\n[DiagRuntime] shape 1: healthy step")
local healthy = Diag.step("FastMode.claimAllQuests", { expect = "Claimed increases", deadline = 60 })
now += 2
healthy.ok({ claimedBefore = 0, claimedAfter = 3 })

local digest = Diag.snapshot()
check("healthy step counted as ok", digest.steps["FastMode.claimAllQuests"].ok == 1)
check("account still HEALTHY", digest.verdict == "HEALTHY", digest.verdict)

-- ---------------------------------------------------------------------------
-- Shape 2: the silent no-op. This is the class no existing log can produce -- the
-- function ran, returned cleanly, and the evidence never showed up.
-- ---------------------------------------------------------------------------
print("\n[DiagRuntime] shape 2: silent no-op")
local silent = Diag.step("FastMode.claimConfiguredRewards", {
	expect = "all five reward jobs settle inside the budget",
	deadline = 240,
})
now += 9
silent.noop("2 of 5 jobs were still running after 9s")

digest = Diag.snapshot()
check("no-op recorded", digest.steps["FastMode.claimConfiguredRewards"].noop == 1)
check("no-op alone downgrades the account", digest.verdict == "DEGRADED", digest.verdict)
check("no-op is NOT counted as ok", digest.steps["FastMode.claimConfiguredRewards"].ok == 0)

-- ---------------------------------------------------------------------------
-- Shape 3: the chain. FastMode publishes FAILED; main's gate reads it and dies.
-- Two controllers, two coroutines, no call-stack relationship at all -- the edge
-- exists only because the gate recorded the read.
-- ---------------------------------------------------------------------------
print("\n[DiagRuntime] shape 3: cross-controller chain")
Diag.signal("lifecycle.FastMode", "FAILED",
	{ phase = "claims", reason = "reward budget exceeded" }, "FastMode")
now += 1

local gate = Diag.step("Main.bootstrapGate", {
	expect = "every required worker reaches COMPLETE / SKIPPED / FAILED",
	deadline = 315,
})
now += 40
gate.because("lifecycle.FastMode")
gate.fail("FastMode reported FAILED and is fatal")

digest = Diag.snapshot()
check("chain has at least two links", #digest.chain >= 2, "#chain=" .. #digest.chain)
local head = digest.head or {}
check("chain head is the FastMode signal, not the gate",
	tostring(head.name):find("lifecycle.FastMode", 1, true) ~= nil, tostring(head.name))
check("chain leaf is the gate",
	digest.chain[#digest.chain].name == "Main.bootstrapGate",
	tostring(digest.chain[#digest.chain].name))
check("edge is labelled as a signal, not a parent",
	tostring(digest.chain[#digest.chain].via):find("signal:", 1, true) ~= nil,
	tostring(digest.chain[#digest.chain].via))
check("headline names both links",
	digest.headline:find("lifecycle.FastMode", 1, true) ~= nil
		and digest.headline:find("Main.bootstrapGate", 1, true) ~= nil,
	digest.headline)

-- ---------------------------------------------------------------------------
-- Shape 4: STUCK. A step that never closes is the literal answer to "which function
-- is my account frozen in", and it only exists because the reaper goes looking.
-- ---------------------------------------------------------------------------
print("\n[DiagRuntime] shape 4: a step that never closes")
local hung = Diag.step("Main.returnToLobby", {
	expect = "the client leaves this place",
	deadline = 150,
})
check("open step reports as open before its deadline", (function()
	for _, item in ipairs(Diag.snapshot().open) do
		if item.name == "Main.returnToLobby" then return not item.stuck end
	end
	return false
end)())

-- Drive the reaper. It loops on JobId, so flip it once enough virtual time passed.
now += 400
local reaper = spawned[1]
local watchdog = 0
local originalWait = task.wait
task.wait = function(seconds)
	now += tonumber(seconds) or 0.05
	watchdog += 1
	if watchdog >= 3 then game.JobId = "a-different-server" end
end
reaper()
task.wait = originalWait

digest = Diag.snapshot()
check("open step past its deadline is STUCK", (function()
	for _, item in ipairs(digest.open) do
		if item.name == "Main.returnToLobby" then return item.stuck == true end
	end
	return false
end)())
check("account verdict escalates to STALLED", digest.verdict == "STALLED", digest.verdict)
check("stuck step carries its source anchor", (function()
	for _, item in ipairs(digest.open) do
		if item.name == "Main.returnToLobby" then return item.where ~= nil and item.expect ~= nil end
	end
	return false
end)())

-- ---------------------------------------------------------------------------
-- Files. A capture that never reaches disk is worth nothing.
-- ---------------------------------------------------------------------------
print("\n[DiagRuntime] files")
Diag.flush()
local digestPath = "AnimeOriginDiag/digest_1000000001.json"
local eventsPath = "AnimeOriginDiag/events_1000000001.jsonl"
check("digest written to the diagnostics folder", disk[digestPath] ~= nil)
check("events written to the diagnostics folder", disk[eventsPath] ~= nil)
check("README explains the folder is deletable",
	(disk["AnimeOriginDiag/README.txt"] or ""):find("SAFE TO DELETE", 1, true) ~= nil)
check("nothing was written into the state folder", (function()
	for path in pairs(disk) do
		if path:find("^AnimeOrigin/") then return false end
	end
	return true
end)())
check("digest is a single line of valid-looking JSON",
	(disk[digestPath] or ""):sub(1, 1) == "{" and (disk[digestPath] or ""):sub(-1) == "}")

local eventLines = 0
for _ in (disk[eventsPath] or ""):gmatch("[^\n]+") do eventLines += 1 end
check("event stream has one line per recorded event", eventLines >= 6, tostring(eventLines))

-- ---------------------------------------------------------------------------
-- The safety contract. This is a passive observer on ~54 unattended clients; it
-- must be incapable of taking a run down with it.
-- ---------------------------------------------------------------------------
print("\n[DiagRuntime] safety contract")
check("a step given a garbage name still returns a usable handle", (function()
	local ok, handle = pcall(Diag.step, {}, { expect = 1 })
	return ok and type(handle) == "table" and pcall(handle.ok)
end)())
check("closing twice does not raise", (function()
	local step = Diag.step("double.close")
	return pcall(function() step.ok() step.ok() step.fail("late") end)
end)())
check("a double close is counted, not hidden", Diag.snapshot().recorder.doubleCloses >= 1)
check("an unencodable payload does not raise", (function()
	local cyclic = {}
	cyclic.self = cyclic
	local step = Diag.step("cyclic.payload")
	return pcall(function() step.ok(cyclic) end)
end)())
check("the digest still writes after an unencodable payload", (function()
	return pcall(Diag.flush) and disk[digestPath] ~= nil
end)())
check("signal with a nil name does not raise", pcall(Diag.signal, nil, "FAILED"))
check("mark with a nil message does not raise", pcall(Diag.mark, "Tag", nil))

-- ---------------------------------------------------------------------------
-- Hand the produced files back to the driver, so --emit can write a real capture to
-- disk. The analyzer is then tested against output the recorder actually generated
-- rather than against a sample written by hand to match it.
local paths = {}
for path in pairs(disk) do table.insert(paths, path) end
table.sort(paths)
for _, path in ipairs(paths) do
	print("@@FILE " .. path)
	for line in (disk[path] .. "\n"):gmatch("([^\n]*)\n") do
		print("@@DATA " .. line)
	end
	print("@@END")
end

print()
if failures > 0 then
	print(string.format("[DiagRuntime] %d check(s) FAILED", failures))
else
	print("[DiagRuntime] PASS -- the recorder produces OK / NO_OP / FAIL / STUCK correctly,")
	print("               reconstructs a cross-controller chain, writes only to its own")
	print("               folder, and cannot raise into game code.")
end
-- The luau CLI sandbox has no os.exit, so the count goes back to the driver on stdout
-- and it sets the process status. A harness that cannot fail the build is decoration.
print("@@RESULT " .. tostring(failures))
