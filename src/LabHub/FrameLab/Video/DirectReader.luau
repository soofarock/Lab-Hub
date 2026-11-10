-- FrameLab: a stream decoded on this client (H.264 from the HLS segments the server passes on unconverted, Tools.Live),
-- on worker threads (Video.TsDecodeWorker in Actors), each decoding one segment ahead of the picture. It has the
-- reader's interface (advance / render / seek / ready / frame / rgba ...), so Video.Player plays it like any video.
-- Frames the clock has already passed (after a jump: the segment is decoded from its start) are decoded but not sent:
-- the picture waits, then goes straight to the frame due, instead of racing through the ones before it.
--   DirectReader.available() -> true on a running client with the worker script
--   local r = DirectReader.new(stream, options)   stream: Net.openVideo(name, { Direct = true }) once its head is in
--       (stream.direct); options.Lines (the picture's short side, default 180: the source is shrunk to it, never
--       enlarged), options.Workers (default 2), options.Fit = { Skip, Split, MaxSplits } (the block player's settings:
--       the pictures' 8 x 8 blocks are worked out on more threads too, Video.BlockFitWorker, in horizontal stripes, and
--       advance() hands over only the blocks that change, info.fits; r.fits is then true). nil when the workers can't
--       start.
--   r.decodeRate(): frames a second the workers decode together (measured while they had frames to make; nil until known): below
--       the video's rate this client can't keep up, and FrameLabClient goes back to the server's converted copy
--   r.close()
local DirectReader = {}

local RunService = game:GetService("RunService")
local Players = game:GetService("Players")
local FrameLab = script:FindFirstAncestor("FrameLab")

local AHEAD = 1.5 -- seconds of frames decoded ahead of the one shown
local FIT_STRIPES = 3 -- block fitters (one stripe of the picture each)
local FIT_AHEAD = 6 -- pictures being fitted at once

local actors, reply = {}, nil
local fitters, fitReply = {}, nil
local readers, nextId = {}, 0
local pumping = false

function DirectReader.available()
	return RunService:IsClient() and RunService:IsRunning() and Players.LocalPlayer ~= nil
		and FrameLab.Video:FindFirstChild("TsDecodeWorker") ~= nil
end

local function ensureActors(n)
	local ps = Players.LocalPlayer:FindFirstChildOfClass("PlayerScripts") or Players.LocalPlayer:WaitForChild("PlayerScripts", 5)
	if not ps then
		return false
	end
	if not reply then
		reply = Instance.new("BindableEvent")
		reply.Event:Connect(function(id, gen, si, list, done, err, rate)
			local st = readers[id]
			if st then
				st.receive(gen, si, list, done, err, rate)
			end
		end)
	end
	while #actors < n do
		local a = Instance.new("Actor")
		a.Name = "FrameLabStreamDecode" .. (#actors + 1)
		local s = FrameLab.Video.TsDecodeWorker:Clone()
		s.Enabled = true
		s.Parent = a
		a.Parent = ps
		table.insert(actors, { actor = a, busy = nil })
	end
	local t0 = os.clock()
	for i = 1, n do
		while not actors[i].actor:GetAttribute("Ready") do
			if os.clock() - t0 > 5 then
				return false
			end
			task.wait()
		end
	end
	return true
end

-- the block fitters (false when they can't start: no pattern library)
local function ensureFitters(n)
	local ps = Players.LocalPlayer:FindFirstChildOfClass("PlayerScripts")
	if not ps or not FrameLab.Video:FindFirstChild("BlockFitWorker") then
		return false
	end
	if not fitReply then
		fitReply = Instance.new("BindableEvent")
		fitReply.Event:Connect(function(id, gen, frame, cr0, fits, err)
			local st = readers[id]
			if st and st.fitReceive then
				st.fitReceive(gen, frame, cr0, fits, err)
			end
		end)
	end
	while #fitters < n do
		local a = Instance.new("Actor")
		a.Name = "FrameLabBlockFit" .. (#fitters + 1)
		local s = FrameLab.Video.BlockFitWorker:Clone()
		s.Enabled = true
		s.Parent = a
		a.Parent = ps
		table.insert(fitters, a)
	end
	local t0 = os.clock()
	for i = 1, n do
		while fitters[i]:GetAttribute("Ready") == nil do
			if os.clock() - t0 > 5 then
				return false
			end
			task.wait()
		end
		if fitters[i]:GetAttribute("Ready") == false then
			return false
		end
	end
	return true
end

function DirectReader.new(stream, options)
	options = options or {}
	local workers = math.clamp(options.Workers or 2, 1, 4)
	if not ensureActors(workers) then
		return nil
	end
	nextId += 1
	local id = nextId
	local head = stream.bytes
	local fps = buffer.readu8(head, 5)
	local srcW, srcH = buffer.readu16(head, 6), buffer.readu16(head, 8)
	local lines = options.Lines or 180
	local s = math.min(1, lines / math.min(srcW, srcH))
	local W, H = math.max(8, math.floor(srcW * s / 2 + 0.5) * 2), math.max(8, math.floor(srcH * s / 2 + 0.5) * 2)
	local PW, PH = (W + 7) // 8 * 8, (H + 7) // 8 * 8
	local r = { codec = "H264", async = true, direct = true, layers = 1, fps = fps, width = W, height = H,
		frameCount = buffer.readu32(head, 10), pw = PW, ph = PH, bw = PW // 8, bh = PH // 8, frame = -1 }
	r.duration = r.frameCount / fps
	r.rgba = buffer.create(PW * PH * 4)
	r.chunks = {}
	local nChunks = buffer.readu16(head, 16)
	for i = 1, nChunks do
		r.chunks[i] = { first = buffer.readu32(head, 24 + (i - 1) * 16 + 12) }
	end
	r.render = function() end

	local st = { queue = {}, gen = 0, assigned = {}, failed = nil }
	-- blocks worked out on the fitters: decoded pictures wait in `decoded`, are sent in order (`fitAt`: the last one sent),
	-- and reach `queue` once every stripe is back
	local fitOpts = options.Fit
	if fitOpts and not ensureFitters(FIT_STRIPES) then
		fitOpts = nil
	end
	r.fits = fitOpts ~= nil
	local stripes = {}
	if fitOpts then
		local bh = PH // 8
		for k = 0, FIT_STRIPES - 1 do
			local a, b = bh * k // FIT_STRIPES, bh * (k + 1) // FIT_STRIPES
			if b > a then
				-- (each fitter keeps its share of the picture's split blocks)
				local o = table.clone(fitOpts)
				o.MaxSplits = math.ceil((fitOpts.MaxSplits or 0) * (b - a) / bh)
				table.insert(stripes, { cr0 = a, crows = b - a, actor = fitters[k + 1], opts = o })
			end
		end
		st.decoded, st.fitting, st.fitAt = {}, {}, -1
		st.picture = buffer.create(PW * PH * 4) -- (the decoded picture the fitters are given stripes of)
	end
	local mine = {} -- worker index -> segment it decodes for this reader
	function r:chunkOf(frame)
		local ci = 1
		for i, c in ipairs(r.chunks) do
			if c.first <= frame then
				ci = i
			else
				break
			end
		end
		return ci
	end
	local function segEnd(si)
		return r.chunks[si + 1] and r.chunks[si + 1].first or r.frameCount
	end

	local rates = {} -- worker -> { frames a second it decodes, os.clock() of its report }
	function st.receive(gen, si, list, done, err, rate)
		if rate then
			local w = "segment " .. si
			for k, seg in pairs(mine) do
				if seg == si then
					w = k
				end
			end
			local old = rates[w]
			rates[w] = { old and old[1] * 0.5 + rate * 0.5 or rate, os.clock() }
		end
		if gen ~= st.gen then
			return
		end
		for _, e in ipairs(list) do
			e.key = e.bands == nil
			if fitOpts then
				st.decoded[e.frame] = e
			else
				st.queue[e.frame] = e
			end
		end
		if done then
			st.assigned[si] = "done"
			for w, seg in pairs(mine) do
				if seg == si then
					mine[w] = nil
					actors[w].busy = nil
				end
			end
			if err then
				st.failed = err
			end
		end
	end

	-- the frame the next advance goes to: the one after the current, or (frames skipped) a whole one no later than the
	-- frames passed over
	local function nextIn(list, after)
		local e = list[after + 1]
		if e then
			return e
		end
		local best
		for k, x in pairs(list) do
			if k > after and k <= (st.floor or 0) and x.key and (not best or k < best.frame) then
				best = x
			end
		end
		return best
	end
	local function nextEntry()
		return nextIn(st.queue, r.frame)
	end
	-- the next decoded pictures, in order, to the fitters (a stripe each)
	function st.feed()
		if not fitOpts then
			return
		end
		local inflight = 0
		for _ in pairs(st.fitting) do
			inflight += 1
		end
		while inflight < FIT_AHEAD do
			local e = nextIn(st.decoded, st.fitAt)
			if not e then
				return
			end
			for k in pairs(st.decoded) do
				if k <= e.frame then
					st.decoded[k] = nil
				end
			end
			st.fitAt = e.frame
			local pic = st.picture
			local rowBytes = PW * 32
			if e.bands then
				for k, by in ipairs(e.bands) do
					buffer.copy(pic, by * rowBytes, e.data, (k - 1) * rowBytes, rowBytes)
				end
			else
				buffer.copy(pic, 0, e.data)
			end
			st.fitting[e.frame] = { left = #stripes, fits = {}, key = e.key }
			for _, sp in ipairs(stripes) do
				local slice = buffer.create(sp.crows * rowBytes)
				buffer.copy(slice, 0, pic, sp.cr0 * rowBytes, sp.crows * rowBytes)
				sp.actor:SendMessage("stripe", id, st.gen, e.frame, e.key, slice, W, H, PW, sp.cr0 * 8, sp.cr0, sp.crows, PW // 8,
					sp.opts, fitReply)
			end
			inflight += 1
		end
	end
	function st.fitReceive(gen, frame, _, fits, err)
		if gen ~= st.gen then
			return
		end
		local f = st.fitting[frame]
		if not f then
			return
		end
		if err then
			st.failed = err
		end
		table.move(fits, 1, #fits, #f.fits + 1, f.fits)
		f.left -= 1
		if f.left == 0 then
			st.fitting[frame] = nil
			st.queue[frame] = { frame = frame, key = f.key, info = { key = f.key, dx = 0, dy = 0, blocks = {}, fits = f.fits } }
		end
	end
	-- a frame decoded and waiting; or one far past what is being decoded (a jump ahead, more than 2 s) whose segment is
	-- here: the player then seeks there. Asking also tells the workers where the picture is due.
	function r:ready(frame)
		if frame <= r.frame or st.queue[frame] then
			return true
		end
		if frame == r.frame + 1 then
			return nextEntry() ~= nil
		end
		st.target = math.max(st.target or -1, frame)
		if frame > r.frame + fps * 2 then
			local ci = r:chunkOf(frame)
			return not st.assigned[ci] and stream.chunkData(ci) ~= nil
		end
		return false
	end
	function r:advance()
		local e = nextEntry()
		if not e then
			return nil
		end
		for k in pairs(st.queue) do
			if k <= e.frame then
				st.queue[k] = nil
			end
		end
		r.frame = e.frame
		if fitOpts then
			return e.info -- (the blocks that change: the picture itself stays with the fitters)
		end
		if e.bands then
			local rowBytes = PW * 32
			for k, by in ipairs(e.bands) do
				buffer.copy(r.rgba, by * rowBytes, e.data, (k - 1) * rowBytes, rowBytes)
			end
		else
			buffer.copy(r.rgba, 0, e.data)
		end
		return e.info
	end
	-- the segments are decoded again from the one holding `frame` (frames before it are dropped as they come)
	function r:seek(frame)
		frame = math.clamp(frame, 0, r.frameCount - 1)
		st.gen += 1
		table.clear(st.queue)
		table.clear(st.assigned)
		if fitOpts then
			table.clear(st.decoded)
			table.clear(st.fitting)
			st.fitAt = frame - 1
		end
		for w in pairs(mine) do
			actors[w].actor:SendMessage("stop", id)
			actors[w].busy = nil
		end
		table.clear(mine)
		r.frame = frame - 1
		st.skipTo = frame
		st.target = frame
		st.floor = frame
		st.lastWant = nil
		st.pump()
		return nil
	end
	function r.decodeRate()
		-- (the workers decoding at once add up: the rates reported in the last 2 s)
		local sum, now = nil, os.clock()
		for w, v in pairs(rates) do
			if now - v[2] < 2 then
				sum = (sum or 0) + v[1]
			elseif now - v[2] > 10 then
				rates[w] = nil
			end
		end
		return sum
	end

	function st.pump()
		-- decoded up to AHEAD past the frame due; the picture more than a quarter second behind it: the frames before
		-- the one due are skipped (`floor`: not sent)
		local from = math.min(r.frame + 1, r.frameCount - 1)
		local due = math.max(from, st.target or 0)
		local floor = due - from > fps / 4 and due or (st.skipTo or 0)
		if floor > (st.floor or 0) then
			st.floor = floor
		end
		local want = math.min(r.frameCount - 1, due + math.floor(fps * AHEAD))
		if want ~= st.lastWant or st.floor ~= st.lastFloor then
			st.lastWant, st.lastFloor = want, st.floor
			for w in pairs(mine) do
				actors[w].actor:SendMessage("want", id, want, st.floor)
			end
		end
		-- the next segments not yet decoded, each to a free worker, as far as `want` reaches (one segment past `want`
		-- too: its worker starts on it while this one plays); none wholly before the floor
		local c0, c1 = r:chunkOf(math.max(from, st.floor or 0)), math.min(r:chunkOf(want) + 1, #r.chunks)
		for si = c0, c1 do
			if not st.assigned[si] then
				local data, _, sizeA, _, offset = stream.chunkData(si)
				if not data then
					break
				end
				local free
				for w = 1, workers do
					if not actors[w].busy then
						free = w
						break
					end
				end
				if not free then
					break
				end
				local bytes = data
				if sizeA and buffer.len(data) ~= sizeA then
					bytes = buffer.create(sizeA)
					buffer.copy(bytes, 0, data, 0, sizeA)
				end
				actors[free].busy = id
				mine[free] = si
				st.assigned[si] = true
				actors[free].actor:SendMessage("want", id, want, st.floor or 0)
				actors[free].actor:SendMessage("seg", id, st.gen, si, bytes, r.chunks[si].first, segEnd(si), offset or 0, fps, W, H, reply,
					st.skipTo or 0, math.floor(fps * AHEAD))
			end
		end
	end

	function r.close()
		if readers[id] then
			readers[id] = nil
			for _, sp in ipairs(stripes) do
				sp.actor:SendMessage("forget", id)
			end
			for w in pairs(mine) do
				actors[w].actor:SendMessage("stop", id)
				actors[w].busy = nil
			end
		end
	end
	function r.failed()
		return st.failed
	end

	readers[id] = st
	if not pumping then
		pumping = true
		RunService.Heartbeat:Connect(function()
			for _, x in pairs(readers) do
				x.pump()
				if x.feed then
					x.feed()
				end
			end
		end)
	end
	return r
end

return DirectReader
