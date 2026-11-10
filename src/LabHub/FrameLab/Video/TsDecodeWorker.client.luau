-- A FrameLab stream decoder: Video.DirectReader puts copies of this script in Actors under the player's PlayerScripts
-- (here it doesn't run). Each decodes one HLS segment at a time (H.264, Tools.ImportJob.tsFrames) in parallel with the
-- game, as far ahead as the reader allows, and hands each picture back: whole for a segment's first frame (and the
-- first after frames it was told to skip), else only the bands of 8 rows with blocks that changed.
local actor = script:GetActor()
if not actor then
	return
end
local RunService = game:GetService("RunService")
local FrameLab = game:GetService("ReplicatedStorage"):WaitForChild("LabHub"):WaitForChild("FrameLab")
local ImportJob = require(FrameLab.Tools.ImportJob)

local BUDGET = 0.012 -- seconds of decoding per game frame
local job -- the segment being decoded
local wants = {} -- reader id -> last frame it wants decoded
local floors = {} -- reader id -> frames before this one aren't sent (the clock has passed them)
local t0 = 0
-- decoding speed: frames made a second, over the time a segment had frames still wanted (sent to the reader about once a
-- second)
local rateFrames, rateTime, lastBeat, wasBusy = 0, 0, nil, false

-- frame k's picture against the last one sent: changed 8 x 8 blocks (sampled: every other pixel each way)
local function pack(j, k, img)
	local W, H, PW = j.w, j.h, j.pw
	local rgba = buffer.create(PW * j.ph * 4)
	for y = 0, H - 1 do
		buffer.copy(rgba, y * PW * 4, img.data, y * W * 4, W * 4)
	end
	local prev = j.prev
	j.prev = rgba
	if not prev then
		return { frame = k, info = { key = true, dx = 0, dy = 0, blocks = {} }, data = rgba }
	end
	local bw, bh = PW // 8, j.ph // 8
	local blocks, bandSet = {}, {}
	local readu8 = buffer.readu8
	for by = 0, bh - 1 do
		for bx = 0, bw - 1 do
			local s = 0
			for yy = 0, 7, 2 do
				local o = ((by * 8 + yy) * PW + bx * 8) * 4
				for xx = 0, 28, 8 do
					s += math.abs(readu8(rgba, o + xx) - readu8(prev, o + xx)) + math.abs(readu8(rgba, o + xx + 1) - readu8(prev, o + xx + 1))
						+ math.abs(readu8(rgba, o + xx + 2) - readu8(prev, o + xx + 2))
				end
			end
			if s > 96 then
				table.insert(blocks, by * bw + bx)
				bandSet[by] = true
			end
		end
	end
	local bands = {}
	for by in pairs(bandSet) do
		table.insert(bands, by)
	end
	table.sort(bands)
	local rowBytes = PW * 32
	local d = buffer.create(#bands * rowBytes)
	for i, by in ipairs(bands) do
		buffer.copy(d, (i - 1) * rowBytes, rgba, by * rowBytes, rowBytes)
	end
	return { frame = k, info = { key = false, dx = 0, dy = 0, blocks = blocks }, data = d, bands = bands }
end

-- a segment to decode: frames [k0, k1); frames before skipTo are decoded but not sent (a jump into the segment: the
-- first one sent is whole). It decodes up to the reader's `want` frame, and at least `lead` frames into the segment
-- (so the next segment is under way while the one before it plays)
actor:BindToMessage("seg", function(id, gen, si, bytes, k0, k1, offset, fps, w, h, reply, skipTo, lead)
	skipTo = skipTo or 0
	local j = { id = id, gen = gen, si = si, k0 = k0, k1 = k1, w = w, h = h, pw = (w + 7) // 8 * 8, ph = (h + 7) // 8 * 8,
		reply = reply, out = {}, next = k0, decoded = 0, minWant = math.max(k0, skipTo) + (lead or 0) }
	-- the decoding, from frame `from` on (a fresh start after a lost thread: the next frame sent is whole)
	function j.start(from)
		j.prev = nil
		j.co = coroutine.create(function()
			ImportJob.tsFrames(bytes, k0, k1, offset, fps, { { w = w, h = h } }, function(k, imgs)
				if k >= skipTo and k >= (floors[id] or 0) then
					table.insert(j.out, pack(j, k, imgs[1]))
				else
					j.prev = nil -- (skipped: the next one sent is whole)
				end
				j.next = k + 1
				j.decoded += 1
				j.started = true
				if j.next > math.max(wants[id] or -1, j.minWant) or os.clock() - t0 > BUDGET then
					coroutine.yield()
				end
			end, function()
				if os.clock() - t0 > BUDGET then
					coroutine.yield()
				end
			end, math.max(from, floors[id] or 0))
		end)
	end
	j.start(skipTo)
	job = j
end)
actor:BindToMessage("want", function(id, frame, floor)
	wants[id] = frame
	floors[id] = floor
end)
actor:BindToMessage("stop", function(id)
	if job and job.id == id then
		job = nil
	end
	wants[id] = nil
	floors[id] = nil
end)

RunService.Heartbeat:ConnectParallel(function()
	local now = os.clock()
	if wasBusy and lastBeat then
		rateTime += now - lastBeat
	end
	lastBeat = now
	local j = job
	if not j then
		wasBusy = false
		return
	end
	t0 = now
	local before = j.decoded
	local err
	-- (resumed only while it waits on this loop; a thread the engine took over is started again where it was)
	while job == j and coroutine.status(j.co) == "suspended" and j.next <= math.max(wants[j.id] or -1, j.minWant)
		and os.clock() - t0 < BUDGET do
		local ok, e = coroutine.resume(j.co)
		if not ok then
			if string.find(tostring(e), "non-suspended", 1, true) and not j.restarted then
				j.restarted = true
				j.start(math.max(j.next, j.k0))
			else
				err = tostring(e)
				break
			end
		end
	end
	-- (a segment wholly before the floor: nothing in it will be shown)
	local done = err ~= nil or coroutine.status(j.co) == "dead" or (floors[j.id] or 0) >= j.k1
	rateFrames += j.decoded - before
	-- (timed from the first frame out: the keyframe-to-jump decoding before it makes nothing to count)
	wasBusy = j.started == true and not done and job == j and j.next <= math.max(wants[j.id] or -1, j.minWant)
	local rate
	if rateTime >= 1 then
		rate = rateFrames / rateTime
		rateFrames, rateTime = 0, 0
	end
	if #j.out > 0 or done or rate then
		local out = j.out
		j.out = {}
		task.synchronize()
		j.reply:Fire(j.id, j.gen, j.si, out, done, err, rate)
		if done and job == j then
			job = nil
		end
	end
end)
actor:SetAttribute("Ready", true)
