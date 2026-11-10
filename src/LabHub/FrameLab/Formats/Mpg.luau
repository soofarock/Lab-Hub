--!native
--!optimize 2
-- MPEG program streams (.mpg / .mpeg / .vob, MPEG-1 system streams), transport stream files (.ts / .m2ts / .mts) and
-- MPEG video elementary streams (.m1v / .m2v): the video as frames to decode, and the sound's elementary stream.
--
--   Mpg.isMpg(bytes) -> true for any of these
--   local m = Mpg.parse(bytes)
--   m.container = "MPEG-PS" | "MPEG-TS" | "MPEG video"
--   m.video = { codec = "mpgv" (MPEG-1 / MPEG-2: Video.Mpeg2), "avc1" (H.264) or "hvc1" (H.265; both annexB = true,
--               from transport streams), data = buffer (the
--               elementary stream), samples = { { pos, size, pts, sync } ... } in decode order (pts: seconds from the
--               first frame shown; a field pair is one sample), duration, width, height (the picture's shape: wide
--               pictures are widened), mpeg2, fps }
--   m.audio = { codec = "mpga" (MPEG audio: MP1 / MP2 / MP3) | "ac-3" | "aac" (ADTS) | "lpcm", data = buffer (the
--               elementary stream; "lpcm": 16-bit big-endian samples), sampleRate, channels (lpcm), start (seconds
--               from the first frame shown to the sound's first sample; negative: the sound starts earlier) } or nil
--   m.otherVideo = the name of a video codec found that isn't read (transport streams), or nil
--   (frames before the first key frame, and the B frames right after it that lean on a picture before it, are left out)

local Mpg = {}

local readu8, band, rshift = buffer.readu8, bit32.band, bit32.rshift

local function isStartCode(b, p, code)
	return readu8(b, p) == 0 and readu8(b, p + 1) == 0 and readu8(b, p + 2) == 1 and (code == nil or readu8(b, p + 3) == code)
end

-- transport stream packet size (188, or 192 for .m2ts / .mts) and the first packet's offset, or nil
local function tsLayout(b)
	local n = buffer.len(b)
	for _, size in ipairs({ 188, 192 }) do
		local lead = size - 188
		if n >= lead + 3 * size and readu8(b, lead) == 0x47 and readu8(b, lead + size) == 0x47 and readu8(b, lead + 2 * size) == 0x47 then
			return size, lead
		end
	end
	return nil
end

function Mpg.isMpg(b)
	local n = buffer.len(b)
	if n < 8 then
		return false
	end
	if isStartCode(b, 0, 0xBA) or isStartCode(b, 0, 0xB3) then
		return true
	end
	return tsLayout(b) ~= nil
end

-- 33-bit PTS at p -> seconds
local function readTime(b, p)
	local a = readu8(b, p)
	local v = band(rshift(a, 1), 7) * 1073741824
	v += readu8(b, p + 1) * 4194304 + rshift(readu8(b, p + 2), 1) * 32768
	v += readu8(b, p + 3) * 128 + rshift(readu8(b, p + 4), 1)
	return v / 90000
end

-- an elementary stream gathered from packets: parts { pos, len } of the file, payload times { esOffset, pts }
local function newStream(kind)
	return { kind = kind, parts = {}, size = 0, times = {} }
end
local function addPart(st, b, pos, len, pts)
	if len <= 0 then
		return
	end
	if pts then
		table.insert(st.times, { st.size, pts })
	end
	table.insert(st.parts, { pos, len })
	st.size += len
end
local function gather(st, b)
	local data = buffer.create(math.max(st.size, 1))
	local o = 0
	for _, part in ipairs(st.parts) do
		buffer.copy(data, o, b, part[1], part[2])
		o += part[2]
	end
	return data
end

---------------------------------------------------------------------------------------------------------------------------
-- MPEG-1 / MPEG-2 video: pictures -> frames, display order, times

local FRAME_RATES = { 24000 / 1001, 24, 25, 30000 / 1001, 30, 50, 60000 / 1001, 60 }
-- MPEG-1 pixel shapes (height / width of a pixel) by aspect code
local MPEG1_PEL = { 1.0, 0.6735, 0.7031, 0.7615, 0.8055, 0.8437, 0.8935, 0.9157, 0.9815, 1.0255, 1.0695, 1.0950, 1.1575, 1.2015 }

local function mpegVideo(es, times)
	local n = buffer.len(es)
	local info = { width = 0, height = 0, fps = 25, mpeg2 = false, progressive = true, aspect = 1 }
	local pics = {}
	local headerStart = nil
	local gopClosed, gopBroken, newGop = false, false, false
	local cur = nil
	local p = 0
	while p + 3 < n do
		local c2 = readu8(es, p + 2)
		if c2 > 1 then
			p += 3
			continue
		elseif c2 == 0 or readu8(es, p + 1) ~= 0 or readu8(es, p) ~= 0 then
			p += 1
			continue
		end
		local code = p + 3 < n and readu8(es, p + 3) or 0
		if code == 0xB3 and p + 11 < n then
			info.width = readu8(es, p + 4) * 16 + rshift(readu8(es, p + 5), 4)
			info.height = band(readu8(es, p + 5), 15) * 256 + readu8(es, p + 6)
			info.aspect = rshift(readu8(es, p + 7), 4)
			info.rate = band(readu8(es, p + 7), 15)
			info.fps = FRAME_RATES[info.rate] or info.fps
			headerStart = headerStart or p
		elseif code == 0xB8 and p + 7 < n then
			gopClosed = band(readu8(es, p + 7), 0x40) ~= 0
			gopBroken = band(readu8(es, p + 7), 0x20) ~= 0
			newGop = true
			headerStart = headerStart or p
		elseif code == 0xB5 and p + 9 < n then
			local id = rshift(readu8(es, p + 4), 4)
			if id == 1 then
				info.mpeg2 = true
				info.progressive = band(readu8(es, p + 5), 0x08) ~= 0
				local hx = band(readu8(es, p + 5), 1) * 2 + rshift(readu8(es, p + 6), 7)
				local vx = band(rshift(readu8(es, p + 6), 5), 3)
				info.width = band(info.width, 0xFFF) + hx * 4096
				info.height = band(info.height, 0xFFF) + vx * 4096
				local en = band(rshift(readu8(es, p + 9), 5), 3)
				local ed = band(readu8(es, p + 9), 31)
				info.fps = (FRAME_RATES[info.rate or 3] or 25) * (en + 1) / (ed + 1)
			elseif id == 8 and cur then
				local b6, b7, b8 = readu8(es, p + 6), readu8(es, p + 7), readu8(es, p + 8)
				cur.structure = band(b6, 3)
				cur.tff = band(b7, 0x80) ~= 0
				cur.rff = band(b7, 0x02) ~= 0
				cur.progressiveFrame = band(b8, 0x80) ~= 0
			end
		elseif code == 0x00 and p + 5 < n then
			cur = { pos = p, start = headerStart or p, type = band(rshift(readu8(es, p + 5), 3), 7), structure = 3, tff = true,
				rff = false, progressiveFrame = true, newGop = newGop, closed = gopClosed, broken = gopBroken }
			table.insert(pics, cur)
			headerStart = nil
			newGop = false
		end
		p += 4
	end
	-- frames: a frame picture, or two field pictures
	local frames = {}
	local i = 1
	while i <= #pics do
		local pic = pics[i]
		local f = { pos = pic.start, pic = pic }
		local nx = pics[i + 1]
		if pic.structure ~= 3 and nx and nx.structure ~= 3 and nx.structure ~= pic.structure and nx.start == nx.pos then
			i += 2
		else
			i += 1
		end
		table.insert(frames, f)
	end
	for k, f in ipairs(frames) do
		local stop = frames[k + 1] and frames[k + 1].pos or n
		f.size = stop - f.pos
	end
	-- the frame shown first after the first key frame, and B frames that lean on pictures before a key frame
	local kept = {}
	local seenI, dropB = false, false
	for _, f in ipairs(frames) do
		local t = f.pic.type
		if t == 1 then
			dropB = (not seenI and not (f.pic.newGop and f.pic.closed)) or f.pic.broken
			seenI = true
			table.insert(kept, f)
		elseif seenI then
			if t == 3 then
				if not dropB then
					table.insert(kept, f)
				end
			elseif t == 2 then
				dropB = false
				table.insert(kept, f)
			end
		end
	end
	-- display order (a B frame shows at once; an I / P frame when the next one arrives) and times: a frame lasts two
	-- fields, three with repeat_first_field (a progressive sequence: two or three frames)
	local order = {}
	local held = nil
	for _, f in ipairs(kept) do
		if f.pic.type == 3 then
			table.insert(order, f)
		else
			if held then
				table.insert(order, held)
			end
			held = f
		end
	end
	if held then
		table.insert(order, held)
	end
	local t = 0
	for _, f in ipairs(order) do
		f.pts = t
		local fields = 2
		if f.pic.rff then
			if info.mpeg2 and info.progressive then
				fields = f.pic.tff and 6 or 4
			elseif f.pic.structure == 3 then
				fields = 3
			end
		end
		t += fields / (2 * info.fps)
	end
	-- the time of the first frame shown, from a packet time (it belongs to the first picture starting in that packet)
	local t0 = nil
	if times and #times > 0 then
		local ti = 1
		for _, pic in ipairs(pics) do
			while times[ti + 1] and times[ti + 1][1] <= pic.pos do
				ti += 1
			end
			local tm = times[ti]
			if tm and tm[1] <= pic.pos and not tm.used then
				tm.used = true
				pic.time = tm[2]
			end
		end
		for _, f in ipairs(kept) do
			if f.pic.time then
				t0 = f.pic.time - f.pts
				break
			end
		end
	end
	local samples = table.create(#kept)
	for k, f in ipairs(kept) do
		samples[k] = { pos = f.pos, size = f.size, pts = f.pts, sync = f.pic.type == 1 }
	end
	-- the picture's shape
	local w, h = info.width, info.height
	local shownW = w
	if info.mpeg2 then
		local dar = ({ [2] = 4 / 3, [3] = 16 / 9, [4] = 2.21 })[info.aspect]
		if dar then
			shownW = math.floor(h * dar / 2 + 0.5) * 2
		end
	else
		local pel = MPEG1_PEL[info.aspect]
		if pel and pel ~= 1 then
			shownW = math.floor(w / pel / 2 + 0.5) * 2
		end
	end
	return {
		codec = "mpgv", data = es, samples = samples, duration = t, width = shownW, height = h, pixelWidth = w,
		mpeg2 = info.mpeg2, fps = info.fps,
	}, t0
end

-- H.264 / H.265 access units (one per timed packet): samples in decode order
local function h264Video(st, es, hevc)
	local times = st.times
	local samples = {}
	local base = math.huge
	for k, tm in ipairs(times) do
		local stop = times[k + 1] and times[k + 1][1] or buffer.len(es)
		if stop > tm[1] then
			-- (an IDR slice anywhere in the unit; H.265: an IRAP picture - IDR, CRA or BLA)
			local sync = false
			local p = tm[1]
			while p + 3 < stop do
				if readu8(es, p) == 0 and readu8(es, p + 1) == 0 and readu8(es, p + 2) == 1 then
					if hevc then
						local nt = band(rshift(readu8(es, p + 3), 1), 63)
						if nt >= 16 and nt <= 21 then
							sync = true
							break
						elseif nt <= 9 then
							break
						end
					else
						local nt = band(readu8(es, p + 3), 31)
						if nt == 5 then
							sync = true
							break
						elseif nt == 1 then
							break
						end
					end
					p += 3
				else
					p += 1
				end
			end
			table.insert(samples, { pos = tm[1], size = stop - tm[1], pts = tm[2], sync = sync })
			base = math.min(base, tm[2])
		end
	end
	-- (from the first key frame)
	local first = 1
	while first <= #samples and not samples[first].sync do
		first += 1
	end
	local kept = {}
	for k = first, #samples do
		table.insert(kept, samples[k])
	end
	base = math.huge
	for _, s in ipairs(kept) do
		base = math.min(base, s.pts)
	end
	local last, dur = 0, 0
	for _, s in ipairs(kept) do
		s.pts -= base
		last = math.max(last, s.pts)
	end
	if #kept > 1 then
		dur = last + last / (#kept - 1)
	end
	return { codec = hevc and "hvc1" or "avc1", annexB = true, data = es, samples = kept, duration = dur }, base
end

---------------------------------------------------------------------------------------------------------------------------
-- containers

local function parsePs(b)
	local n = buffer.len(b)
	local video = nil
	local audios = {} -- key -> stream
	local p = 0
	while p + 4 <= n do
		if not isStartCode(b, p) or readu8(b, p + 3) < 0xB9 then
			-- (resynchronise at the next pack or packet)
			p += 1
			while p + 4 <= n and not (isStartCode(b, p) and readu8(b, p + 3) >= 0xB9) do
				p += 1
			end
			continue
		end
		local code = readu8(b, p + 3)
		if code == 0xBA then
			if p + 14 > n then
				break
			end
			if band(readu8(b, p + 4), 0xC0) == 0x40 then
				p += 14 + band(readu8(b, p + 13), 7)
			else
				p += 12
			end
		elseif code == 0xB9 then
			p += 4
		else
			if p + 6 > n then
				break
			end
			local len = readu8(b, p + 4) * 256 + readu8(b, p + 5)
			local q, stop = p + 6, math.min(p + 6 + len, n)
			local isVideo = code >= 0xE0 and code <= 0xEF
			local isAudio = code >= 0xC0 and code <= 0xDF
			if (isVideo or isAudio or code == 0xBD) and q < stop then
				local pts = nil
				if band(readu8(b, q), 0xC0) == 0x80 then
					local flags, hlen = readu8(b, q + 1), readu8(b, q + 2)
					if band(flags, 0x80) ~= 0 then
						pts = readTime(b, q + 3)
					end
					q += 3 + hlen
				else
					while q < stop and readu8(b, q) == 0xFF do
						q += 1
					end
					if q < stop and band(readu8(b, q), 0xC0) == 0x40 then
						q += 2
					end
					if q < stop then
						local c = band(readu8(b, q), 0xF0)
						if c == 0x20 then
							pts = readTime(b, q)
							q += 5
						elseif c == 0x30 then
							pts = readTime(b, q)
							q += 10
						else
							q += 1
						end
					end
				end
				if isVideo then
					video = video or newStream(code)
					if video.kind == code then
						addPart(video, b, q, stop - q, pts)
					end
				elseif isAudio then
					local st = audios[code] or newStream("mpga")
					audios[code] = st
					addPart(st, b, q, stop - q, pts)
				elseif q < stop then
					local sub = readu8(b, q)
					if sub >= 0x80 and sub <= 0x87 then
						local st = audios[0x100 + sub] or newStream("ac-3")
						audios[0x100 + sub] = st
						addPart(st, b, q + 4, stop - q - 4, pts)
					elseif sub >= 0xA0 and sub <= 0xA7 and q + 7 <= stop then
						local st = audios[0x100 + sub] or newStream("lpcm")
						audios[0x100 + sub] = st
						local fmt = readu8(b, q + 5)
						st.bits = ({ 16, 20, 24 })[rshift(fmt, 6) + 1] or 16
						st.sampleRate = band(rshift(fmt, 4), 3) == 1 and 96000 or 48000
						st.channels = band(fmt, 7) + 1
						addPart(st, b, q + 7, stop - q - 7, pts)
					end
				end
			end
			p += 6 + len
		end
	end
	return video, audios
end

local function parseTs(b)
	local n = buffer.len(b)
	local size, lead = tsLayout(b)
	local pmtPid, videoPid, audioPid, videoType, audioType
	local video, audio, other
	local open = {} -- pid -> stream receiving the current packet's payload
	for p = lead, n - 188, size do
		if readu8(b, p) ~= 0x47 then
			continue
		end
		local b1, b2, b3 = readu8(b, p + 1), readu8(b, p + 2), readu8(b, p + 3)
		local unitStart = band(b1, 0x40) ~= 0
		local pid = band(b1, 0x1F) * 256 + b2
		local afc = band(rshift(b3, 4), 3)
		local q = p + 4
		local stop = p + 188
		if afc == 2 or afc == 3 then
			q += 1 + readu8(b, q)
		end
		if afc == 2 or afc == 0 or q >= stop then
			continue
		end
		if pid == 0 and not pmtPid then
			if unitStart then
				q += 1 + readu8(b, q)
			end
			local secLen = band(readu8(b, q + 1), 15) * 256 + readu8(b, q + 2)
			local e = math.min(q + 3 + secLen - 4, stop)
			local r = q + 8
			while r + 4 <= e do
				local prog = readu8(b, r) * 256 + readu8(b, r + 1)
				if prog ~= 0 then
					pmtPid = band(readu8(b, r + 2), 0x1F) * 256 + readu8(b, r + 3)
					break
				end
				r += 4
			end
		elseif pid == pmtPid and not videoPid then
			if unitStart then
				q += 1 + readu8(b, q)
			end
			local secLen = band(readu8(b, q + 1), 15) * 256 + readu8(b, q + 2)
			local e = math.min(q + 3 + secLen - 4, stop)
			local infoLen = band(readu8(b, q + 10), 15) * 256 + readu8(b, q + 11)
			local r = q + 12 + infoLen
			while r + 5 <= e do
				local st = readu8(b, r)
				local epid = band(readu8(b, r + 1), 0x1F) * 256 + readu8(b, r + 2)
				local esLen = band(readu8(b, r + 3), 15) * 256 + readu8(b, r + 4)
				-- (stream type 6 is private data: AC-3 when its descriptors say so)
				local ac3 = st == 0x81
				if st == 0x06 then
					local d = r + 5
					while d + 2 <= r + 5 + esLen do
						local tag, dlen = readu8(b, d), readu8(b, d + 1)
						if tag == 0x6A or (tag == 0x05 and dlen >= 4 and buffer.readstring(b, d + 2, 4) == "AC-3") then
							ac3 = true
						end
						d += 2 + dlen
					end
				end
				if not videoPid and (st == 0x01 or st == 0x02 or st == 0x1B or st == 0x24) then
					videoPid, videoType = epid, st
				elseif st == 0x10 or st == 0xEA or st == 0x42 then
					other = other or ({ [0x10] = "MPEG-4 Part 2", [0xEA] = "VC-1", [0x42] = "AVS" })[st]
				elseif not audioPid and (st == 0x03 or st == 0x04 or st == 0x0F or ac3) then
					audioPid, audioType = epid, ac3 and "ac-3" or (st == 0x0F and "aac" or "mpga")
				end
				r += 5 + esLen
			end
			if videoPid then
				video = newStream(videoType == 0x1B and "h264" or (videoType == 0x24 and "h265" or "mpgv"))
			end
			if audioPid then
				audio = newStream(audioType)
			end
		elseif pid == videoPid or pid == audioPid then
			local st = pid == videoPid and video or audio
			local pts = nil
			if unitStart then
				if readu8(b, q) == 0 and readu8(b, q + 1) == 0 and readu8(b, q + 2) == 1 then
					local flags, hlen = readu8(b, q + 7), readu8(b, q + 8)
					if band(flags, 0x80) ~= 0 then
						pts = readTime(b, q + 9)
					end
					q += 9 + hlen
					open[pid] = true
				end
			end
			if open[pid] and q < stop then
				if unitStart and not pts and (st.kind == "h264" or st.kind == "h265") then
					-- (an H.264 / H.265 unit without a time: interpolated later)
					pts = -1
				end
				addPart(st, b, q, stop - q, pts)
			end
		end
	end
	return video, audio, other
end

function Mpg.parse(b)
	local n = buffer.len(b)
	local m = { audio = nil }
	local vst, audio
	if tsLayout(b) and not isStartCode(b, 0) then
		m.container = "MPEG-TS"
		vst, audio, m.otherVideo = parseTs(b)
	elseif isStartCode(b, 0, 0xB3) then
		m.container = "MPEG video"
		vst = { kind = "mpgv", parts = { { 0, n } }, size = n, times = {} }
	else
		m.container = "MPEG-PS"
		local audios
		vst, audios = parsePs(b)
		-- the sound: the first MPEG audio stream, else the first AC-3, else the first PCM
		local keys = {}
		for k in pairs(audios) do
			table.insert(keys, k)
		end
		table.sort(keys)
		for _, pref in ipairs({ "mpga", "ac-3", "lpcm" }) do
			for _, k in ipairs(keys) do
				if not audio and audios[k].kind == pref and audios[k].size > 0 then
					audio = audios[k]
				end
			end
		end
	end
	local t0 = nil
	if vst and vst.size > 0 then
		local es = gather(vst, b)
		if vst.kind == "h264" or vst.kind == "h265" then
			-- (times: units without one get the one before plus a frame)
			local last = nil
			for _, tm in ipairs(vst.times) do
				if tm[2] < 0 then
					tm[2] = last and last + 1 / 30 or 0
				end
				last = tm[2]
			end
			m.video, t0 = h264Video(vst, es, vst.kind == "h265")
		else
			m.video, t0 = mpegVideo(es, vst.times)
		end
		if #m.video.samples == 0 then
			m.video = nil
		end
	end
	if audio and audio.size > 0 then
		local a = { codec = audio.kind, data = gather(audio, b), sampleRate = audio.sampleRate, channels = audio.channels,
			bits = audio.bits }
		local first = audio.times[1]
		if first and t0 then
			a.start = first[2] - t0
		end
		m.audio = a
	end
	return m
end

return Mpg
