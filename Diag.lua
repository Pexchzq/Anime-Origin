--[[
	Anime Origin runtime diagnostics recorder ("Diag")

	WHY THIS FILE EXISTS

	Every stall this project has shipped had the same shape: a function ran, returned
	without raising, wrote a log line that looked healthy, and accomplished nothing.
	claimAllQuests returned early because a UI-written flag was false. returnToLobby
	fired its remote and reported success while the character never left the stage.
	claimConfiguredRewards killed five reward jobs that were still succeeding. None of
	those are visible in a log that records what the code *did*, because in every case
	the code did exactly what it was told.

	So this recorder does not log control flow. Every instrumented step declares, at
	the moment it starts, the observable evidence that would prove it worked, and the
	verdict comes from whether that evidence showed up -- not from whether the Lua
	function returned:

		OK     ran, and the declared evidence appeared
		NO_OP  ran, returned cleanly, and the evidence never appeared
		FAIL   ran and reported its own failure
		STUCK  started and never finished

	NO_OP and STUCK are the two verdicts no existing log in this project can produce,
	and between them they cover every stall captured so far.

	CHAINS

	One account dying is usually several things in a row: FastMode is killed by a
	budget, main's gate waits out a worker that will never report, the route restarts
	three times, AutoPlay never gets a stage. Two edge kinds make that reconstructable
	instead of guessable:

		parent  a step opened inside another step (per-coroutine, so the seven
		        workers running in separate task.spawns never braid together)
		signal  a step whose outcome depended on a value another controller wrote,
		        recorded at the read via step:because("lifecycle.FastMode")

	Both are recorded facts, not inference. The digest names the head of the chain --
	the earliest non-OK link -- so a capture answers "is it a chain?" by itself.

	SAFETY CONTRACT

	This is a passive observer of a farm that runs unattended on ~54 clients. It must
	never be able to break a run:
	  * every public entry point is pcall-wrapped and hands back an inert handle on error
	  * a missing or disabled recorder degrades to no-ops at every call site
	  * the Loader treats this file's download as NON-FATAL
	  * every output is byte-capped, so a night-long run cannot fill the disk

	The folder is deliberately NOT Config.fastGems.stateFolder. Everything written here
	is derived from a single run and is safe to delete at any moment; AnimeOrigin/ holds
	FastModeBootstrap_*.json and MainRoute_*.json, which are resumable state that an
	interrupted account needs.

	PRIVACY: digests contain Roblox UserIds. This repository is public and auto-executed
	by every client. Diagnostics output must never be committed to it.
]]

local HttpService = game:GetService("HttpService")
local Players = game:GetService("Players")

local environment = getgenv()
local Config = typeof(environment.AnimeOriginConfig) == "table" and environment.AnimeOriginConfig or {}
local Settings = typeof(Config.debugRecorder) == "table" and Config.debugRecorder or {}

local ENABLED = Settings.enabled ~= false
local FOLDER = tostring(Settings.folder or "AnimeOriginDiag")
local EVENT_BYTE_CAP = math.max(4096, tonumber(Settings.eventByteCap) or 65536)
local DIGEST_INTERVAL = math.max(2, tonumber(Settings.digestInterval) or 10)
local REAP_INTERVAL = math.max(1, tonumber(Settings.reapInterval) or 5)
local DEFAULT_DEADLINE = math.max(5, tonumber(Settings.defaultStepDeadline) or 90)
local TAIL_EVENTS = math.max(10, tonumber(Settings.tailEvents) or 40)
local MAX_OPEN = math.max(16, tonumber(Settings.maximumOpenSteps) or 192)
local MAX_NODES = math.max(64, tonumber(Settings.maximumNodes) or 512)
local CHAIN_DEPTH = math.max(2, tonumber(Settings.chainDepth) or 12)
local REASON_CLIP = math.max(40, tonumber(Settings.reasonClip) or 180)

-- ---------------------------------------------------------------------------
-- Inert handle. Returned whenever the recorder is disabled or something inside it
-- went wrong. Call sites must be able to use the result unconditionally: the whole
-- point is that instrumentation can never become the reason a run dies.
-- ---------------------------------------------------------------------------
local INERT = {}
INERT.__index = INERT
function INERT.ok() return INERT end
function INERT.noop() return INERT end
function INERT.fail() return INERT end
function INERT.note() return INERT end
function INERT.because() return INERT end
function INERT.extend() return INERT end
function INERT.expect() return INERT end

local Diag = {
	version = 1,
	enabled = ENABLED,
	folder = FOLDER,
	inert = INERT,
}

if not ENABLED then
	-- Publish the same surface so call sites never have to test for absence twice.
	function Diag.step() return INERT end
	function Diag.mark() end
	function Diag.signal() end
	function Diag.counter() end
	function Diag.flush() end
	function Diag.snapshot() return nil end
	environment.AnimeOriginDiag = Diag
	return Diag
end

-- ---------------------------------------------------------------------------
-- Shared clock and sequence. Deliberately the SAME counter the [AO] console trace
-- uses: Roblox interleaves output from every thread, so a captured F9 console and a
-- captured digest can only be put back into one timeline if they share the counter.
-- ---------------------------------------------------------------------------
local epoch = tonumber(environment.AnimeOriginTraceEpoch) or os.clock()
environment.AnimeOriginTraceEpoch = epoch

local function nextSeq()
	local seq = (tonumber(environment.AnimeOriginTraceSequence) or 0) + 1
	environment.AnimeOriginTraceSequence = seq
	return seq
end

local function elapsed()
	return os.clock() - epoch
end

local HAS_DEBUG_INFO = typeof(debug) == "table" and typeof(debug.info) == "function"

-- Source anchor for "where is the bug". Captured in the public entry point so the
-- stack level is fixed at 2 (the caller) regardless of what happens deeper in.
local function whereAmI(level)
	if not HAS_DEBUG_INFO then return nil end
	local ok, source, line = pcall(debug.info, level, "sl")
	if not ok or source == nil then return nil end
	local short = tostring(source):match("([^/\\]+)$") or tostring(source)
	return short .. ":" .. tostring(line)
end

local function clip(value, limit)
	if value == nil then return nil end
	local text = tostring(value)
	limit = limit or REASON_CLIP
	if #text <= limit then return text end
	return text:sub(1, limit - 3) .. "..."
end

-- Payloads come from a dozen call sites and are whatever the caller had to hand:
-- Instances, cyclic report tables, NaN from a division, tables with mixed key types.
-- Every one of those makes JSONEncode raise, and a single one reaching the retained
-- state would kill the digest permanently -- the worst failure a diagnostics tool can
-- have, because it stops reporting without saying so. So nothing unsanitised is ever
-- retained: this makes a bounded, JSON-safe copy at the moment a payload arrives.
--
-- The copy also decouples the record from the live table. Several call sites pass
-- state that keeps mutating afterwards, which would otherwise make a capture describe
-- the account's state at read time rather than at the moment the step closed.
local function sanitise(value, depth)
	depth = depth or 0
	local kind = typeof(value)
	if kind == "string" then return clip(value, 400) end
	if kind == "boolean" then return value end
	if kind == "number" then
		-- NaN and both infinities are perfectly legal Lua numbers and all three break
		-- JSONEncode. A division by a zero counter is all it takes to produce one.
		if value ~= value or value == math.huge or value == -math.huge then
			return tostring(value)
		end
		return value
	end
	if kind ~= "table" then return "<" .. kind .. ">" end
	-- The depth cap is also the cycle guard: a self-referencing table terminates here
	-- rather than needing a visited set on every payload.
	if depth >= 4 then return "<nested>" end
	local copy = {}
	if #value > 0 then
		for index, item in ipairs(value) do
			if index > 24 then
				table.insert(copy, "...truncated")
				break
			end
			table.insert(copy, sanitise(item, depth + 1))
		end
		return copy
	end
	local count = 0
	for key, item in pairs(value) do
		count += 1
		if count > 24 then
			copy["truncated"] = true
			break
		end
		local keyKind = typeof(key)
		if keyKind == "string" or keyKind == "number" then
			copy[tostring(key)] = sanitise(item, depth + 1)
		end
	end
	return copy
end

local function encode(value)
	local ok, result = pcall(function()
		return HttpService:JSONEncode(value)
	end)
	if ok and typeof(result) == "string" then return result end
	return nil
end

-- ---------------------------------------------------------------------------
-- Recorder state. Every container here is bounded: this runs for a whole night on a
-- host already short on memory, and an unbounded table is the failure this project
-- keeps having.
-- ---------------------------------------------------------------------------
local nodes = {}          -- id -> node (a step instance, or a signal pseudo-node)
local nodeOrder = {}      -- bounded ring of ids, oldest first
local stepStats = {}      -- name -> aggregate across the run
local openNodes = {}      -- id -> node, still running
local openCount = 0
local signals = {}        -- signal name -> latest write
local counters = {}
local tail = {}           -- bounded ring of recent event records
local droppedNodes = 0
local droppedOpen = 0
local doubleCloses = 0
local nextId = 0

local eventBytes = 0
local eventCapped = false
local lastDigestAt = 0
local digestWrites = 0
local userId = nil
local bootJobId = game.JobId

-- Per-coroutine step stacks. The seven controllers run in separate task.spawns, so a
-- single global stack would braid unrelated work into one bogus parent chain. Weak
-- keys let a finished coroutine's stack be collected.
local stacks = setmetatable({}, { __mode = "k" })

local function currentStack()
	local co = coroutine.running() or "main"
	local stack = stacks[co]
	if not stack then
		stack = {}
		stacks[co] = stack
	end
	return stack
end

local function recordNode(node)
	nodes[node.id] = node
	table.insert(nodeOrder, node.id)
	while #nodeOrder > MAX_NODES do
		local oldest = table.remove(nodeOrder, 1)
		-- Never evict something still running: an open node is the most likely answer
		-- to "what is this account stuck on", which is the whole reason for the file.
		if openNodes[oldest] then
			table.insert(nodeOrder, oldest)
			break
		end
		nodes[oldest] = nil
		droppedNodes += 1
	end
end

local function pushTail(record)
	table.insert(tail, record)
	while #tail > TAIL_EVENTS do
		table.remove(tail, 1)
	end
end

-- ---------------------------------------------------------------------------
-- Output. The folder is created lazily so a client whose executor lacks makefolder
-- simply records in memory instead of erroring on every write.
-- ---------------------------------------------------------------------------
local folderReady = false

local function ensureFolder()
	if folderReady then return true end
	if typeof(makefolder) ~= "function" then return false end
	if typeof(isfolder) == "function" and isfolder(FOLDER) then
		folderReady = true
	else
		folderReady = pcall(makefolder, FOLDER)
	end
	if folderReady and typeof(writefile) == "function" then
		-- A note for whoever finds this folder later, including the person deciding
		-- whether it is safe to delete. It is; that is the design.
		pcall(writefile, FOLDER .. "/README.txt", table.concat({
			"Anime Origin diagnostics capture.",
			"",
			"SAFE TO DELETE. Everything in this folder is derived from a single run.",
			"Resumable state lives in the AnimeOrigin/ folder instead -- do not confuse",
			"the two: deleting AnimeOrigin/ mid-bootstrap costs an account its summons.",
			"",
			"digest_<userid>.json   the verdict. Small. This is the file to send.",
			"events_<userid>.jsonl  the raw event stream behind it, byte-capped.",
			"",
			"These files contain Roblox UserIds. Do not commit them to the public",
			"Anime-Origin repository.",
		}, "\n"))
	end
	return folderReady
end

local eventBuffer = {}
local pendingEvents = {}
local droppedPending = 0

local function resolveUserId()
	if userId then return userId end
	local player = Players.LocalPlayer
	if player then userId = player.UserId end
	return userId
end

local function emitEvent(record)
	local line = encode(record)
	if not line then
		line = string.format('{"t":"encode_failed","seq":%d}', tonumber(record.seq) or 0)
	end
	line ..= "\n"
	eventBytes += #line
	local path = FOLDER .. "/events_" .. tostring(userId) .. ".jsonl"
	if typeof(appendfile) == "function" then
		pcall(appendfile, path, line)
	elseif typeof(writefile) == "function" then
		table.insert(eventBuffer, line)
		pcall(writefile, path, table.concat(eventBuffer))
	end
end

local function writeEvent(record, important)
	-- Over the cap, only keep what a post-mortem cannot be done without: failures,
	-- stalls, and the cross-controller signal edges that form the chain.
	if eventBytes >= EVENT_BYTE_CAP then
		if not important then return end
		if not eventCapped then
			eventCapped = true
		end
	end
	-- The filename is the UserId, and LocalPlayer is not guaranteed to exist yet when
	-- the first events arrive. Holding them until it resolves keeps ONE file per
	-- account: the alternative, writing an events_unknown.jsonl alongside, splits a
	-- capture across the first seconds after join -- which is precisely where a client
	-- that never starts spends its whole life.
	if not resolveUserId() then
		if #pendingEvents < 64 then
			table.insert(pendingEvents, record)
		else
			droppedPending += 1
		end
		return
	end
	if not ensureFolder() then return end
	if #pendingEvents > 0 then
		local queued = pendingEvents
		pendingEvents = {}
		for _, item in ipairs(queued) do
			emitEvent(item)
		end
	end
	emitEvent(record)
end

-- ---------------------------------------------------------------------------
-- Verdict ranking. Used to pick which failure a chain should be built from, and to
-- summarise a whole account in one word.
-- ---------------------------------------------------------------------------
local VERDICT_RANK = { OPEN = 0, OK = 1, NO_OP = 2, FAIL = 3, STUCK = 4 }

local function rank(verdict)
	return VERDICT_RANK[verdict] or 0
end

local function statsFor(name)
	local entry = stepStats[name]
	if not entry then
		entry = { runs = 0, ok = 0, noop = 0, fail = 0, stuck = 0 }
		stepStats[name] = entry
	end
	return entry
end

-- ---------------------------------------------------------------------------
-- Steps
-- ---------------------------------------------------------------------------
local function closeNode(node, verdict, reason, data)
	if node.closedAt then
		doubleCloses += 1
		return
	end
	node.closedAt = os.clock()
	node.ms = math.floor((node.closedAt - node.startedAt) * 1000)
	node.verdict = verdict
	node.reason = clip(reason)
	data = sanitise(data)
	node.data = data
	if openNodes[node.id] then
		openNodes[node.id] = nil
		openCount -= 1
	end

	local entry = statsFor(node.name)
	if verdict == "OK" then entry.ok += 1
	elseif verdict == "NO_OP" then entry.noop += 1
	elseif verdict == "FAIL" then entry.fail += 1
	end
	entry.lastVerdict = verdict
	entry.lastReason = node.reason
	entry.lastAt = math.floor(elapsed() * 10) / 10
	entry.lastMs = node.ms
	entry.where = node.where or entry.where

	local record = {
		t = "step",
		seq = node.seq,
		at = math.floor(elapsed() * 10) / 10,
		name = node.name,
		verdict = verdict,
		ms = node.ms,
		reason = node.reason,
		where = node.where,
		parent = node.parentId,
		expect = node.expect,
		data = data,
	}
	pushTail(record)
	writeEvent(record, verdict ~= "OK")
end

local function beginNode(name, opts, anchor)
	opts = typeof(opts) == "table" and opts or {}
	nextId += 1
	local stack = currentStack()
	local parent = stack[#stack]

	local node = {
		id = nextId,
		kind = "step",
		name = tostring(name),
		seq = nextSeq(),
		startedAt = os.clock(),
		startedElapsed = elapsed(),
		-- A call site reaching Diag through a local helper passes its own anchor;
		-- otherwise debug.info would name the helper instead of the real code.
		where = opts.where or anchor,
		expect = clip(opts.expect),
		deadline = math.max(1, tonumber(opts.deadline) or DEFAULT_DEADLINE),
		parentId = parent and parent.id or nil,
		causes = {},
		tag = opts.tag,
	}
	if node.parentId then
		table.insert(node.causes, { via = "parent", id = node.parentId })
	end

	statsFor(node.name).runs += 1
	recordNode(node)

	if openCount >= MAX_OPEN then
		-- Refusing to track a new open step is far better than growing without bound.
		-- Counted so a digest can say the recorder itself hit its ceiling.
		droppedOpen += 1
	else
		openNodes[node.id] = node
		openCount += 1
		table.insert(stack, node)
	end

	writeEvent({
		t = "open",
		seq = node.seq,
		at = math.floor(node.startedElapsed * 10) / 10,
		id = node.id,
		name = node.name,
		where = node.where,
		expect = node.expect,
		parent = node.parentId,
	}, false)

	local handle = {}

	local function pop()
		local s = currentStack()
		for index = #s, 1, -1 do
			if s[index] == node then
				table.remove(s, index)
				break
			end
		end
	end

	local function finish(verdict, reason, data)
		pop()
		closeNode(node, verdict, reason, data)
	end

	-- Every method swallows its own errors and returns the handle, so a call site can
	-- chain freely and a malformed payload can never unwind into game code.
	function handle.ok(evidence)
		pcall(finish, "OK", nil, evidence)
		return handle
	end
	function handle.noop(reason, data)
		pcall(finish, "NO_OP", reason, data)
		return handle
	end
	function handle.fail(reason, data)
		pcall(finish, "FAIL", reason, data)
		return handle
	end
	function handle.note(key, value)
		pcall(function()
			node.notes = node.notes or {}
			node.notes[tostring(key)] = sanitise(value)
		end)
		return handle
	end
	function handle.expect(text)
		pcall(function() node.expect = clip(text) end)
		return handle
	end
	function handle.extend(seconds)
		pcall(function()
			node.deadline = node.deadline + math.max(0, tonumber(seconds) or 0)
			node.stuckAt = nil
		end)
		return handle
	end
	-- The cross-controller edge. Called at the point a step READS a value another
	-- controller wrote, which is the only place the dependency is a fact rather than
	-- an assumption about who probably influenced whom.
	function handle.because(signalName)
		pcall(function()
			local signal = signals[tostring(signalName)]
			if not signal then return end
			table.insert(node.causes, {
				via = "signal:" .. tostring(signalName),
				id = signal.nodeId,
			})
		end)
		return handle
	end

	return handle
end

function Diag.step(name, opts)
	local anchor = whereAmI(2)
	local ok, handle = pcall(beginNode, name, opts, anchor)
	if ok and typeof(handle) == "table" then return handle end
	return INERT
end

-- Convenience wrapper for a step whose success is simply "did not raise". Weaker
-- evidence than an explicit ok()/noop() and named so it reads that way at the call
-- site -- a raise is not the failure mode this project actually suffers from.
function Diag.protect(name, fn, opts)
	local handle = Diag.step(name, opts)
	local results = table.pack(pcall(fn))
	if results[1] then
		handle.ok()
		return table.unpack(results, 2, results.n)
	end
	handle.fail(results[2])
	return nil
end

-- ---------------------------------------------------------------------------
-- Signals: cross-controller values one worker writes and another reads.
-- ---------------------------------------------------------------------------
local function writeSignal(name, status, data, tag)
	name = tostring(name)
	nextId += 1
	local node = {
		id = nextId,
		kind = "signal",
		name = name .. "=" .. tostring(status),
		signal = name,
		status = tostring(status),
		seq = nextSeq(),
		startedAt = os.clock(),
		startedElapsed = elapsed(),
		causes = {},
		tag = tag,
		closedAt = os.clock(),
		ms = 0,
	}
	-- A signal pseudo-node carries a verdict so a chain that runs through it reads the
	-- same way as one that runs through a step. FAILED is the interesting case: it is
	-- exactly how one dead worker takes the rest of the account down with it.
	local upper = node.status:upper()
	if upper == "FAILED" then
		node.verdict = "FAIL"
	elseif upper == "COMPLETE" or upper == "SKIPPED" or upper == "OK" then
		node.verdict = "OK"
	else
		node.verdict = "OPEN"
	end
	node.reason = clip(typeof(data) == "table"
		and (data.reason or data.error or data.phase) or nil)
	data = sanitise(data)

	-- Attribute the write to whatever step was running, so the chain reaches back past
	-- the signal into the code that decided it.
	local stack = currentStack()
	local owner = stack[#stack]
	if owner then
		table.insert(node.causes, { via = "parent", id = owner.id })
	end

	recordNode(node)
	local previous = signals[name]
	signals[name] = {
		status = node.status,
		at = math.floor(node.startedElapsed * 10) / 10,
		seq = node.seq,
		nodeId = node.id,
		tag = tag,
		previous = previous and previous.status or nil,
	}

	local record = {
		t = "signal",
		seq = node.seq,
		at = math.floor(node.startedElapsed * 10) / 10,
		name = name,
		status = node.status,
		from = previous and previous.status or nil,
		tag = tag,
		data = data,
	}
	pushTail(record)
	-- Always important: signals are the edges, and a chain cannot be rebuilt without them.
	writeEvent(record, true)
end

function Diag.signal(name, status, data, tag)
	pcall(writeSignal, name, status, data, tag)
end

-- ---------------------------------------------------------------------------
-- Marks: the existing [AO] console milestones, captured in structured form. Each
-- worker's trace() feeds this, so the whole existing milestone stream lands in the
-- capture with no new call sites to keep in sync.
-- ---------------------------------------------------------------------------
local function writeMark(tag, message, data)
	local record = {
		t = "mark",
		seq = nextSeq(),
		at = math.floor(elapsed() * 10) / 10,
		tag = tostring(tag),
		msg = clip(message, 240),
		data = sanitise(data),
	}
	pushTail(record)
	-- A mark whose text shouts is worth keeping past the cap; the rest is context.
	local loud = typeof(message) == "string"
		and (message:find("FAIL") or message:find("ABORT") or message:find("TIMED OUT")
			or message:find("STALL") or message:find("RAISED")) ~= nil
	writeEvent(record, loud)
end

function Diag.mark(tag, message, data)
	pcall(writeMark, tag, message, data)
end

function Diag.counter(name, delta)
	pcall(function()
		name = tostring(name)
		counters[name] = (counters[name] or 0) + (tonumber(delta) or 1)
	end)
end

-- ---------------------------------------------------------------------------
-- Chain reconstruction
-- ---------------------------------------------------------------------------
local function worstNode()
	local best, bestRank = nil, 0
	for _, id in ipairs(nodeOrder) do
		local node = nodes[id]
		if node then
			local verdict = node.verdict
			if not verdict and openNodes[id] then
				verdict = node.stuckAt and "STUCK" or "OPEN"
			end
			local r = rank(verdict)
			-- Ties go to the LATEST occurrence: the newest symptom is the one whose
			-- chain still explains the account's current state.
			if r > 0 and (r > bestRank or (r == bestRank and best and node.seq > best.seq)) then
				best, bestRank = node, r
			end
		end
	end
	if bestRank <= rank("OK") then return nil end
	return best
end

local function buildChain()
	local leaf = worstNode()
	if not leaf then return {}, nil end

	local path, seen = {}, {}
	local node = leaf
	local depth = 0
	while node and not seen[node.id] and depth < CHAIN_DEPTH do
		seen[node.id] = true
		depth += 1
		local verdict = node.verdict
		if not verdict then
			verdict = node.stuckAt and "STUCK" or "OPEN"
		end
		local link = {
			seq = node.seq,
			at = math.floor(node.startedElapsed * 10) / 10,
			name = node.name,
			kind = node.kind,
			verdict = verdict,
			reason = node.reason,
			where = node.where,
		}
		table.insert(path, 1, link)
		-- Prefer a signal edge over the parent edge when both exist: a cross-controller
		-- dependency explains more than "this ran inside that".
		local chosen
		for _, cause in ipairs(node.causes or {}) do
			local candidate = nodes[cause.id]
			if candidate then
				if not chosen or cause.via ~= "parent" then
					chosen = { node = candidate, via = cause.via }
				end
			end
		end
		if chosen then
			-- The label belongs to THIS link and describes how it reached its cause, so
			-- it is written here rather than onto the cause. Writing it onto the cause
			-- both left the leaf unlabelled and mutated a node that outlives this call:
			-- buildDigest runs every ten seconds, and the stale label would resurface in
			-- a later chain that never had that edge.
			link.via = chosen.via
			node = chosen.node
		else
			node = nil
		end
	end

	-- The head is the earliest link that is not OK. Everything after it is a
	-- consequence, which is the distinction the word "chain" is actually asking about.
	local head
	for _, link in ipairs(path) do
		if link.verdict ~= "OK" and link.verdict ~= "OPEN" then
			head = link
			break
		end
	end
	return path, head or path[#path]
end

-- ---------------------------------------------------------------------------
-- Digest
-- ---------------------------------------------------------------------------
local function buildDigest()
	local openList = {}
	for _, node in pairs(openNodes) do
		table.insert(openList, {
			name = node.name,
			seq = node.seq,
			openFor = math.floor((os.clock() - node.startedAt) * 10) / 10,
			deadline = node.deadline,
			stuck = node.stuckAt ~= nil,
			where = node.where,
			expect = node.expect,
			notes = node.notes,
		})
	end
	table.sort(openList, function(a, b) return a.openFor > b.openFor end)

	local chain, head = buildChain()

	local stalled, degraded = false, false
	for _, entry in pairs(stepStats) do
		if entry.fail > 0 or entry.noop > 0 or entry.stuck > 0 then degraded = true end
	end
	for _, node in pairs(openNodes) do
		if node.stuckAt then stalled = true end
	end

	local verdict = "HEALTHY"
	if stalled then verdict = "STALLED"
	elseif degraded then verdict = "DEGRADED" end

	local headline = "healthy"
	if #chain > 0 then
		local parts = {}
		for _, link in ipairs(chain) do
			if link.verdict ~= "OK" and link.verdict ~= "OPEN" then
				table.insert(parts, link.name .. " " .. link.verdict)
			end
		end
		if #parts > 0 then
			headline = table.concat(parts, " -> ")
		end
	end

	local signalView = {}
	for name, signal in pairs(signals) do
		signalView[name] = { status = signal.status, at = signal.at, from = signal.previous }
	end

	return {
		version = Diag.version,
		writtenAt = os.time(),
		uptime = math.floor(elapsed() * 10) / 10,
		userId = userId,
		placeId = game.PlaceId,
		jobId = bootJobId,
		verdict = verdict,
		headline = headline,
		head = head,
		chain = chain,
		open = openList,
		steps = stepStats,
		signals = signalView,
		counters = counters,
		recorder = {
			digestWrites = digestWrites,
			eventBytes = eventBytes,
			eventsTruncated = eventCapped,
			droppedNodes = droppedNodes,
			droppedOpenSteps = droppedOpen,
			droppedPendingEvents = droppedPending,
			doubleCloses = doubleCloses,
			hasDebugInfo = HAS_DEBUG_INFO,
			hasAppendFile = typeof(appendfile) == "function",
			hasWriteFile = typeof(writefile) == "function",
		},
		tail = tail,
	}
end

local function writeDigest()
	if not resolveUserId() then return end
	if not ensureFolder() then return end
	if typeof(writefile) ~= "function" then return end
	local digest = buildDigest()
	environment.AnimeOriginDiagReport = digest
	local body = encode(digest)
	if not body then
		-- Never leave the previous digest in place claiming a state that is no longer
		-- true; say plainly that the recorder could not serialise itself.
		body = encode({
			version = Diag.version,
			writtenAt = os.time(),
			userId = userId,
			verdict = "UNKNOWN",
			headline = "digest encode failed",
		}) or "{}"
	end
	digestWrites += 1
	lastDigestAt = os.clock()
	pcall(writefile, FOLDER .. "/digest_" .. tostring(userId) .. ".json", body)
end

function Diag.flush()
	pcall(writeDigest)
end

function Diag.snapshot()
	local ok, digest = pcall(buildDigest)
	return ok and digest or nil
end

-- ---------------------------------------------------------------------------
-- Reaper. A step that never closes is the single most valuable thing this file can
-- report -- it is the literal answer to "which function is my account stuck in" --
-- and it only exists if something goes looking for it.
-- ---------------------------------------------------------------------------
local function reap()
	local now = os.clock()
	for _, node in pairs(openNodes) do
		if not node.stuckAt and now - node.startedAt > node.deadline then
			node.stuckAt = now
			local entry = statsFor(node.name)
			entry.stuck += 1
			entry.lastVerdict = "STUCK"
			-- Deliberately not "still running": the reaper cannot distinguish a step that
			-- is genuinely waiting from one that something raised past. The `where`
			-- anchor and the surrounding events settle which, and a verdict that
			-- overclaims here would send an investigation the wrong way.
			entry.lastReason = clip(string.format(
				"never closed; open %.0fs against a %ds deadline (still waiting, or something raised past it)",
				now - node.startedAt, node.deadline))
			local record = {
				t = "stuck",
				seq = nextSeq(),
				at = math.floor(elapsed() * 10) / 10,
				id = node.id,
				name = node.name,
				openFor = math.floor(now - node.startedAt),
				deadline = node.deadline,
				where = node.where,
				expect = node.expect,
				parent = node.parentId,
			}
			pushTail(record)
			writeEvent(record, true)
		end
	end
	if now - lastDigestAt >= DIGEST_INTERVAL then
		writeDigest()
	end
end

task.spawn(function()
	-- Bound to the JobId that loaded this file. On a place transition the Loader
	-- rebuilds everything, and a survivor from the previous place would write another
	-- client's story into this one's digest.
	while game.JobId == bootJobId do
		task.wait(REAP_INTERVAL)
		pcall(reap)
	end
end)

environment.AnimeOriginDiag = Diag
return Diag
