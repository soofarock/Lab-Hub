-- FrameLab: decodes an FLV2 video on a worker thread (Parallel Luau) ahead of the player, so the game's own frames keep
-- only the drawing (and the sound's timing). Video.Player uses it for every FLV2 video. It has the reader's interface
-- (advance / render / seek / ready / frame / rgba ...); the pictures come from the worker (Video.DecodeWorker, in an
-- Actor under the player's PlayerScripts), about a second ahead of the one shown.
--   AsyncReader.available() -> true on a running client with the worker script
--   local r = AsyncReader.wrap(reader, options)   reader: an FLV2 reader (its header, sizes and picture buffer are used;
--       it doesn't decode any more); options.ChunkData / options.Ready as for that reader (a streamed video).
--       nil when the worker can't start. r.async = true; r.close() when done.
--   r:seek(frame) returns nil: the picture arrives with the next frames (the first one after a seek is a key frame)
local AsyncReader = {}

local RunService = game:GetService("RunService")
local Players = game:GetService("Players")
local FrameLab = script:FindFirstAncestor("FrameLab")

local AHEAD = 1 -- seconds of frames decoded ahead of the one shown

local actor, nextId = nil, 0
local readers = {} -- id -> state
local pumping = false

function AsyncReader.available()
	return RunService:IsClient() and RunService:IsRunning() and Players.LocalPlayer ~= nil
		and FrameLab.Video:FindFirstChild("DecodeWorker") ~= nil
end

local function ensureActor()
	if actor and actor.Parent and actor:GetAttribute("Ready") then
		return true
	end
	local ps = Players.LocalPlayer:FindFirstChildOfClass("PlayerScripts") or Players.LocalPlayer:WaitForChild("PlayerScripts", 5)
	if not ps then
		return false
	end
	if not (actor and actor.Parent) then
		actor = Instance.new("Actor")
		actor.Name = "FrameLabDecode"
		local s = FrameLab.Video.DecodeWorker:Clone()
		s.Enabled = true
		s.Parent = actor
		local reply = Instance.new("BindableEvent")
		reply.Name = "Frames"
		reply.Parent = actor
		reply.Event:Connect(function(id, gen, list)
			local st = readers[id]
			if st then
				st.receive(gen, list)
			end
		end)
		actor.Parent = ps
	end
	local t0 = os.clock()
	while not actor:GetAttribute("Ready") do
		if os.clock() - t0 > 5 then
			return false
		end
		task.wait()
	end
	return true
end

local function pumpAll()
	for _, st in pairs(readers) do
		st.pump()
	end
end

function AsyncReader.wrap(r, options)
	if not ensureActor() then
		return nil
	end
	options = options or {}
	nextId += 1
	local id = nextId
	local st = { queue = {}, gen = 0, sent = {}, wantSent = -2 }
	local reply = actor:FindFirstChild("Frames")
	local headLen = 24 + #r.chunks * 16
	local head = buffer.create(headLen)
	buffer.copy(head, 0, r.bytes, 0, headLen)

	-- a chunk's bytes (its two coder streams), from the stream or from the whole video in memory, and their sizes
	local function chunkBytes(ci)
		local c = r.chunks[ci]
		local sizeA, sizeB = c.sizeA, c.sizeB
		if options.ChunkData then
			local b, off, sA, sB = options.ChunkData(ci)
			if not b then
				return nil
			end
			if sA then
				sizeA, sizeB = sA, sB
			end
			local n = sizeA + sizeB
			if off == 0 and buffer.len(b) == n then
				return b, sizeA, sizeB
			end
			local out = buffer.create(n)
			buffer.copy(out, 0, b, off, n)
			return out, sizeA, sizeB
		end
		local n = sizeA + sizeB
		local out = buffer.create(n)
		buffer.copy(out, 0, r.bytes, c.off, n)
		return out, sizeA, sizeB
	end

	r.async = true
	r.frame = -1
	r.render = function() end -- (each picture is copied in by advance)
	actor:SendMessage("open", id, head, reply, { FastColour = r.FastColour == true, SkipDroppable = r.SkipDroppable == true })
	st.skip, st.fast = r.SkipDroppable == true, r.FastColour == true

	function st.receive(gen, list)
		if gen ~= st.gen then
			return
		end
		for _, e in ipairs(list) do
			st.queue[e.frame] = e
		end
	end

	function r:ready(frame)
		if frame <= r.frame then
			return true
		end
		return st.queue[frame] ~= nil
	end

	function r:advance()
		local f = r.frame + 1
		local e = st.queue[f]
		if not e then
			return nil
		end
		st.queue[f] = nil
		r.frame = f
		if e.bands then
			-- only the bands of 8 rows that changed
			local rowBytes = r.pw * 32
			for k, by in ipairs(e.bands) do
				buffer.copy(r.rgba, by * rowBytes, e.data, (k - 1) * rowBytes, rowBytes)
			end
		else
			buffer.copy(r.rgba, 0, e.data)
		end
		return e.info
	end

	function r:seek(frame)
		frame = math.clamp(frame, 0, r.frameCount - 1)
		st.gen += 1
		table.clear(st.queue)
		r.frame = frame - 1
		st.wantSent = -2
		actor:SendMessage("seek", id, frame, st.gen)
		st.pump()
		return nil
	end

	-- every frame: the chunks the worker needs (from the one being shown to AHEAD seconds on), how far to decode,
	-- and the reader settings the player changes (SkipDroppable)
	function st.pump()
		local from = math.max(r.frame, 0)
		local want = math.min(r.frameCount - 1, from + math.floor(r.fps * AHEAD) + 1)
		local c0, c1 = r:chunkOf(from), r:chunkOf(want)
		for ci = c0, c1 do
			if not st.sent[ci] and (not options.Ready or options.Ready(ci)) then
				local data, sizeA, sizeB = chunkBytes(ci)
				if data then
					actor:SendMessage("chunk", id, ci, data, sizeA, sizeB)
					st.sent[ci] = true
				end
			end
		end
		for ci in pairs(st.sent) do
			if ci < c0 or ci > c1 + 1 then
				st.sent[ci] = nil
				actor:SendMessage("drop", id, ci)
			end
		end
		if want ~= st.wantSent then
			st.wantSent = want
			actor:SendMessage("want", id, want)
		end
		local skip, fast = r.SkipDroppable == true, r.FastColour == true
		if skip ~= st.skip then
			st.skip = skip
			actor:SendMessage("set", id, "SkipDroppable", skip)
		end
		if fast ~= st.fast then
			st.fast = fast
			actor:SendMessage("set", id, "FastColour", fast)
		end
	end

	function r.close()
		if readers[id] then
			readers[id] = nil
			actor:SendMessage("close", id)
		end
	end

	readers[id] = st
	if not pumping then
		pumping = true
		RunService.Heartbeat:Connect(pumpAll)
	end
	return r
end

return AsyncReader
