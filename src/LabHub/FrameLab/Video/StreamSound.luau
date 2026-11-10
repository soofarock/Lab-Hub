-- FrameLab: the sound of a stream (Tools.Live: an HLS address, or an MP4 / MOV in stream mode) for AudioLab, as a clip
-- that fills in while it plays. The server makes each part's sound into an AudioLab clip (RBA3) when it is asked for;
-- this keeps WINDOW seconds of it around the playhead, in the window form AudioLab's Synth.Player plays (clip.base,
-- clip.want: the frames outside it are silent until they arrive).
--   StreamSound.clip(name) -> clip, or nil when the stream has no sound (yields until the part being watched is in)
-- FrameLabClient hands these to AudioLab (Tools.Assets source) for the clip path "stream/<name>".
local StreamSound = {}

local CollectionService = game:GetService("CollectionService")
local FrameLab = script:FindFirstAncestor("FrameLab")
local Net = require(FrameLab.Tools.Net)

local BEHIND = 5 -- seconds kept before the playhead
local AHEAD = 20 -- seconds fetched ahead of it
local WINDOW = 40 -- seconds the clip holds

-- where a screen showing this stream is (its server playhead), or 0
local function playheadOf(name)
	local Sync = require(FrameLab.Sync)
	for _, inst in ipairs(CollectionService:GetTagged(Sync.Tag)) do
		if inst:GetAttribute("FrameLabVideo") == name then
			return Sync.getTime(inst, { duration = inst:GetAttribute("FrameLabDuration") or 0,
				loop = inst:GetAttribute("FrameLabLoop") == true })
		end
	end
	return 0
end

-- part si's sound: clip bytes, start (seconds); nil when it has none (or it didn't arrive)
local function fetch(name, si)
	local info
	for _ = 1, 400 do -- (made on the server as it is asked for: a few seconds)
		local ok, v = pcall(Net.invoke, "liveSound", name, si)
		if ok and type(v) == "table" then
			info = v
			break
		elseif ok and type(v) == "string" then
			return nil
		end
		task.wait(0.25)
	end
	if not info then
		return nil
	end
	local size = info.size
	local data = buffer.create(size)
	local starts = {}
	for p = 0, size - 1, Net.RANGE do
		table.insert(starts, p)
	end
	local nextRange, lost, running = 1, false, 0
	local function fetcher()
		while nextRange <= #starts and not lost do
			local p = starts[nextRange]
			nextRange += 1
			local len = math.min(Net.RANGE, size - p)
			local part
			for try = 1, 10 do
				local ok, v = pcall(Net.invoke, "liveSoundRange", name, si, p, len)
				if ok and typeof(v) == "buffer" then
					part = v
					break
				end
				task.wait(0.25 * try)
			end
			if not part then
				lost = true
				break
			end
			buffer.copy(data, p, part, 0, buffer.len(part))
		end
		running -= 1
	end
	for _ = 1, math.min(3, #starts) do
		running += 1
		task.spawn(fetcher)
	end
	while running > 0 do
		task.wait()
	end
	if lost then
		return nil
	end
	return data, info.start
end

function StreamSound.clip(name)
	local AL = game:GetService("ReplicatedStorage"):WaitForChild("LabHub"):FindFirstChild("AudioLab")
	if not AL then
		return nil
	end
	local Partials = require(AL.Codec.Partials)
	-- the stream's parts (where each starts): its head, as a client decoding it reads it
	local ok, head = pcall(Net.invoke, "videoHead", name, 180, nil, true)
	if not ok or type(head) ~= "table" or not head.direct then
		return nil
	end
	local hb = head.head
	local vfps = math.max(1, buffer.readu8(hb, 5))
	local duration = buffer.readu32(hb, 10) / vfps
	local starts = {}
	for i = 1, buffer.readu16(hb, 16) do
		starts[i] = buffer.readu32(hb, 24 + (i - 1) * 16 + 12) / vfps
	end
	local function partAt(t)
		local si = 1
		for i, s in ipairs(starts) do
			if s <= t then
				si = i
			else
				break
			end
		end
		return si
	end

	-- the first part heard (at the playhead) sets the clip's layout
	local si0 = partAt(playheadOf(name))
	local first, firstStart, firstAt
	for si = si0, math.min(si0 + 2, #starts) do
		local bytes, start = fetch(name, si)
		if bytes then
			local okU, u = pcall(Partials.unpack, bytes)
			if okU then
				first, firstStart, firstAt = u, start, si
				break
			end
		end
	end
	if not first then
		return nil
	end
	local fps, K, nN, stereo = first.fps, first.slots, first.nN, first.stereo
	local W = WINDOW * fps
	local clip = {
		version = 3, stream = true, fps = fps, slots = K, noise = first.noise, nN = nN, stereo = stereo,
		sourceRate = first.sourceRate, sourceLength = math.floor(duration * first.sourceRate), bankVersion = first.bankVersion,
		duration = duration, frameCount = W, base = 0,
	}
	-- the planes, frame-major: bytes per frame
	local ROWS = { amp = K, pitch = K * 2, pan = stereo and K or nil, nz = nN, nzR = stereo and nN or nil }
	local function alloc()
		local t = {}
		for key, row in pairs(ROWS) do
			t[key] = buffer.create(math.max(1, W * row))
		end
		return t
	end
	local held = {} -- part -> true: its frames are in the window
	local spans = {} -- part -> { first frame, frames }

	-- move the window to start at frame newBase (what both share is kept; parts not wholly in it are fetched again)
	local function rebase(newBase)
		local old = clip.base
		local fresh = alloc()
		local lo, hi = math.max(old, newBase), math.min(old + W, newBase + W)
		if hi > lo then
			for key, row in pairs(ROWS) do
				buffer.copy(fresh[key], (lo - newBase) * row, clip[key], (lo - old) * row, (hi - lo) * row)
			end
		end
		for key in pairs(ROWS) do
			clip[key] = fresh[key]
		end
		clip.base = newBase
		for si in pairs(held) do
			local sp = spans[si]
			if not sp or sp[1] < newBase or sp[1] + sp[2] > newBase + W then
				held[si] = nil
			end
		end
	end
	-- a part's frames into the window; false when it is laid out differently from the clip's first part
	local function put(si, u, start)
		if u.slots ~= K or u.nN ~= nN or u.stereo ~= stereo or u.fps ~= fps then
			return false
		end
		local f0 = math.floor(start * fps + 0.5)
		spans[si] = { f0, u.frameCount }
		local lo, hi = math.max(f0, clip.base), math.min(f0 + u.frameCount, clip.base + W)
		if hi > lo then
			for key, row in pairs(ROWS) do
				buffer.copy(clip[key], (lo - clip.base) * row, u[key], (lo - f0) * row, (hi - lo) * row)
			end
		end
		held[si] = true
		return true
	end

	local function baseFor(t)
		return math.max(0, math.floor((t - BEHIND) * fps))
	end
	local lastT, lastWant = firstStart or 0, os.clock()
	local fetching = false
	local tried = {} -- part -> os.clock() of a fetch that brought nothing
	local function fetchLoop()
		fetching = true
		while os.clock() - lastWant < 30 do
			local t = lastT
			local any = false
			for si = partAt(t), partAt(math.min(t + AHEAD, duration)) do
				if not held[si] and (not tried[si] or os.clock() - tried[si] > 10) then
					any = true
					local bytes, start = fetch(name, si)
					local okU, u = false, nil
					if bytes then
						okU, u = pcall(Partials.unpack, bytes)
					end
					if not (okU and put(si, u, start)) then
						tried[si] = os.clock() -- (tried again in 10 s at the soonest)
					end
					break -- (the playhead may have moved: look again)
				end
			end
			if not any then
				task.wait(0.25)
			end
		end
		fetching = false
	end
	-- (Synth.Player calls this with the time it plays, every audio block)
	function clip.want(t)
		lastT, lastWant = t, os.clock()
		local f = t * fps
		if f < clip.base or f > clip.base + W - AHEAD * fps then
			rebase(baseFor(t))
		end
		if not fetching then
			task.spawn(fetchLoop)
		end
	end
	clip.base = baseFor(firstStart or 0)
	for key, b in pairs(alloc()) do
		clip[key] = b
	end
	put(firstAt, first, firstStart)
	task.spawn(fetchLoop)
	return clip
end

return StreamSound
