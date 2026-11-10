--!native
--!optimize 2
-- MPEG transport stream (.ts, the segments of an HLS stream) and HLS playlists (.m3u8).
--
--   local ts = Ts.parse(buf)   -- buffer of 188-byte packets
--   ts.video = { codec = "h264", units = { { pts, dts, data = buffer } ... } }   one access unit (Annex B) each, in
--              decoding order; times in seconds
--   ts.audio = { codec = "aac", frames = { { pts, data = buffer } ... } }       ADTS frames (header included)
--   Ts.isTs(buf)
--   Ts.packUnits(units, audio) -> buffer: access units ({ { pts, data } ... }, Annex B) handed on without a transport
--       stream (an MP4 streamed in parts, Tools.Live.openMp4), and its sound (ADTS frames, as ts.audio.frames; optional);
--       Ts.parse reads it back the same way as a segment
--
--   local pl = Ts.playlist(text, baseUrl)
--   pl.variants = { { url, bandwidth, width, height } ... }   (a master playlist: pick one, read its playlist)
--   pl.segments = { { url, duration, start } ... }, pl.duration, pl.ended (true: the whole video is listed)
--   Ts.pickVariant(pl.variants, lines) -> the variant at most `lines` tall with the highest bandwidth (else the smallest)

local Ts = {}

local readu8 = buffer.readu8

function Ts.isTs(b)
	local n = buffer.len(b)
	if n < 188 * 2 then
		return n >= 188 and readu8(b, 0) == 0x47
	end
	return readu8(b, 0) == 0x47 and readu8(b, 188) == 0x47
end

-- 33-bit PTS / DTS at p -> seconds
local function readTime(b, p)
	local a = readu8(b, p)
	local v = bit32.band(bit32.rshift(a, 1), 7) * 1073741824
	v += readu8(b, p + 1) * 4194304 + bit32.rshift(readu8(b, p + 2), 1) * 32768
	v += readu8(b, p + 3) * 128 + bit32.rshift(readu8(b, p + 4), 1)
	return v / 90000
end

function Ts.packUnits(units, audio)
	local total = 8
	for _, u in ipairs(units) do
		total += 12 + buffer.len(u.data)
	end
	if audio and #audio > 0 then
		total += 8
		for _, f in ipairs(audio) do
			total += 12 + buffer.len(f.data)
		end
	end
	local b = buffer.create(total)
	buffer.writestring(b, 0, "FLAU")
	buffer.writeu32(b, 4, #units)
	local p = 8
	for _, u in ipairs(units) do
		local len = buffer.len(u.data)
		buffer.writef64(b, p, u.pts)
		buffer.writeu32(b, p + 8, len)
		buffer.copy(b, p + 12, u.data, 0, len)
		p += 12 + len
	end
	if audio and #audio > 0 then
		buffer.writestring(b, p, "AUDS")
		buffer.writeu32(b, p + 4, #audio)
		p += 8
		for _, f in ipairs(audio) do
			local len = buffer.len(f.data)
			buffer.writef64(b, p, f.pts)
			buffer.writeu32(b, p + 8, len)
			buffer.copy(b, p + 12, f.data, 0, len)
			p += 12 + len
		end
	end
	return b
end

local function unpackUnits(b)
	local units = {}
	local p = 8
	for i = 1, buffer.readu32(b, 4) do
		local pts, len = buffer.readf64(b, p), buffer.readu32(b, p + 8)
		local d = buffer.create(len)
		buffer.copy(d, 0, b, p + 12, len)
		units[i] = { pts = pts, dts = pts, data = d }
		p += 12 + len
	end
	local audio = {}
	if p + 8 <= buffer.len(b) and buffer.readstring(b, p, 4) == "AUDS" then
		local frames = {}
		local n = buffer.readu32(b, p + 4)
		p += 8
		for i = 1, n do
			local pts, len = buffer.readf64(b, p), buffer.readu32(b, p + 8)
			local d = buffer.create(len)
			buffer.copy(d, 0, b, p + 12, len)
			frames[i] = { pts = pts, data = d }
			p += 12 + len
		end
		audio = { codec = "aac", frames = frames }
	end
	return { video = { codec = "h264", units = units }, audio = audio }
end

function Ts.parse(b)
	local n = buffer.len(b)
	if n >= 8 and buffer.readstring(b, 0, 4) == "FLAU" then
		return unpackUnits(b)
	end
	local start = 0
	-- (find the first sync byte with another one a packet later)
	while start + 188 < n and not (readu8(b, start) == 0x47 and readu8(b, start + 188) == 0x47) do
		start += 1
	end
	local pmtPid, videoPid, audioPid
	local videoType, audioType
	local pes = {} -- pid -> { parts = { {pos, len} }, size, pts, dts }
	local out = { video = { codec = nil, units = {} }, audio = { codec = nil, frames = {} } }

	local function flush(pid)
		local cur = pes[pid]
		pes[pid] = nil
		if not cur or cur.size == 0 then
			return
		end
		local data = buffer.create(cur.size)
		local o = 0
		for _, part in ipairs(cur.parts) do
			buffer.copy(data, o, b, part[1], part[2])
			o += part[2]
		end
		if pid == videoPid then
			table.insert(out.video.units, { pts = cur.pts, dts = cur.dts or cur.pts, data = data })
		elseif pid == audioPid then
			-- split into ADTS frames; times follow the PES time (1024 samples a frame)
			local p, t = 0, cur.pts or 0
			while p + 7 <= cur.size do
				if readu8(data, p) ~= 0xFF or bit32.band(readu8(data, p + 1), 0xF0) ~= 0xF0 then
					p += 1
					continue
				end
				local len = bit32.bor(bit32.lshift(bit32.band(readu8(data, p + 3), 3), 11), bit32.lshift(readu8(data, p + 4), 3),
					bit32.rshift(readu8(data, p + 5), 5))
				if len < 7 or p + len > cur.size then
					break
				end
				local rateIndex = bit32.band(bit32.rshift(readu8(data, p + 2), 2), 15)
				local rates = { 96000, 88200, 64000, 48000, 44100, 32000, 24000, 22050, 16000, 12000, 11025, 8000, 7350 }
				local frame = buffer.create(len)
				buffer.copy(frame, 0, data, p, len)
				table.insert(out.audio.frames, { pts = t, data = frame })
				t += 1024 / (rates[rateIndex + 1] or 48000)
				p += len
			end
		end
	end

	for p = start, n - 188, 188 do
		if readu8(b, p) ~= 0x47 then
			continue
		end
		local b1, b2, b3 = readu8(b, p + 1), readu8(b, p + 2), readu8(b, p + 3)
		local unitStart = bit32.band(b1, 0x40) ~= 0
		local pid = bit32.band(b1, 0x1F) * 256 + b2
		local afc = bit32.band(bit32.rshift(b3, 4), 3)
		local q = p + 4
		if afc == 2 or afc == 3 then
			q += 1 + readu8(b, q)
		end
		if afc == 2 or afc == 0 or q >= p + 188 then
			continue
		end
		local stop = p + 188
		if pid == 0 then
			-- PAT: the first program's PMT
			if unitStart then
				q += 1 + readu8(b, q)
			end
			local secLen = bit32.band(readu8(b, q + 1), 15) * 256 + readu8(b, q + 2)
			local e = math.min(q + 3 + secLen - 4, stop)
			local r = q + 8
			while r + 4 <= e do
				local prog = readu8(b, r) * 256 + readu8(b, r + 1)
				local ppid = bit32.band(readu8(b, r + 2), 0x1F) * 256 + readu8(b, r + 3)
				if prog ~= 0 then
					pmtPid = ppid
					break
				end
				r += 4
			end
		elseif pid == pmtPid then
			if unitStart then
				q += 1 + readu8(b, q)
			end
			local secLen = bit32.band(readu8(b, q + 1), 15) * 256 + readu8(b, q + 2)
			local e = math.min(q + 3 + secLen - 4, stop)
			local infoLen = bit32.band(readu8(b, q + 10), 15) * 256 + readu8(b, q + 11)
			local r = q + 12 + infoLen
			while r + 5 <= e do
				local st = readu8(b, r)
				local epid = bit32.band(readu8(b, r + 1), 0x1F) * 256 + readu8(b, r + 2)
				local esLen = bit32.band(readu8(b, r + 3), 15) * 256 + readu8(b, r + 4)
				if not videoPid and (st == 0x1B or st == 0x24 or st == 0x01 or st == 0x02) then
					videoPid, videoType = epid, st
				elseif not audioPid and (st == 0x0F or st == 0x03 or st == 0x04 or st == 0x81) then
					audioPid, audioType = epid, st
				end
				r += 5 + esLen
			end
		elseif pid == videoPid or pid == audioPid then
			if unitStart then
				flush(pid)
				-- PES header: 00 00 01, stream id, length (2), flags (2), header length, PTS / DTS
				if readu8(b, q) == 0 and readu8(b, q + 1) == 0 and readu8(b, q + 2) == 1 then
					local flags = readu8(b, q + 7)
					local hlen = readu8(b, q + 8)
					local cur = { parts = {}, size = 0 }
					if bit32.band(flags, 0x80) ~= 0 then
						cur.pts = readTime(b, q + 9)
						if bit32.band(flags, 0x40) ~= 0 then
							cur.dts = readTime(b, q + 14)
						end
					end
					pes[pid] = cur
					q += 9 + hlen
				end
			end
			local cur = pes[pid]
			if cur and q < stop then
				table.insert(cur.parts, { q, stop - q })
				cur.size += stop - q
			end
		end
	end
	if videoPid then
		flush(videoPid)
	end
	if audioPid then
		flush(audioPid)
	end
	local vnames = { [0x1B] = "h264", [0x24] = "h265", [0x01] = "mpeg1", [0x02] = "mpeg2" }
	local anames = { [0x0F] = "aac", [0x03] = "mp3", [0x04] = "mp3", [0x81] = "ac3" }
	out.video.codec = videoType and vnames[videoType] or nil
	out.audio.codec = audioType and anames[audioType] or nil
	return out
end

-- ------------------------------------------------------------------------------------------------- playlists
local function resolve(base, ref)
	if string.match(ref, "^%a[%w+.-]*://") then
		return ref
	end
	local scheme, host = string.match(base, "^(%a[%w+.-]*://)([^/]+)")
	if not scheme then
		return ref
	end
	if string.sub(ref, 1, 2) == "//" then
		return string.match(scheme, "^(%a[%w+.-]*:)") .. ref
	elseif string.sub(ref, 1, 1) == "/" then
		return scheme .. host .. ref
	end
	local dir = string.match(string.gsub(base, "[?#].*$", ""), "^(.*/)") or (scheme .. host .. "/")
	return dir .. ref
end
Ts.resolve = resolve

function Ts.playlist(text, baseUrl)
	local pl = { variants = {}, segments = {}, duration = 0, ended = false }
	local pendingVariant, pendingDuration
	for line in string.gmatch(text .. "\n", "([^\r\n]*)\r?\n") do
		line = string.gsub(line, "^%s+", "")
		if line == "" then
			continue
		end
		if string.sub(line, 1, 1) == "#" then
			if string.sub(line, 1, 18) == "#EXT-X-STREAM-INF:" then
				local attrs = string.sub(line, 19)
				local v = { bandwidth = tonumber(string.match(attrs, "BANDWIDTH=(%d+)")) or 0 }
				local w, h = string.match(attrs, "RESOLUTION=(%d+)x(%d+)")
				v.width, v.height = tonumber(w), tonumber(h)
				pendingVariant = v
			elseif string.sub(line, 1, 8) == "#EXTINF:" then
				pendingDuration = tonumber(string.match(line, "^#EXTINF:%s*([%d%.]+)")) or 0
			elseif string.sub(line, 1, 14) == "#EXT-X-ENDLIST" then
				pl.ended = true
			elseif string.sub(line, 1, 21) == "#EXT-X-PLAYLIST-TYPE:" and string.find(line, "VOD", 1, true) then
				pl.ended = true
			end
		elseif pendingVariant then
			pendingVariant.url = resolve(baseUrl or "", line)
			table.insert(pl.variants, pendingVariant)
			pendingVariant = nil
		elseif pendingDuration then
			table.insert(pl.segments, { url = resolve(baseUrl or "", line), duration = pendingDuration, start = pl.duration })
			pl.duration += pendingDuration
			pendingDuration = nil
		end
	end
	return pl
end

function Ts.pickVariant(variants, lines)
	local best, smallest
	for _, v in ipairs(variants) do
		local l = (v.width and v.height) and math.min(v.width, v.height) or nil
		if l and l <= lines then
			local bl = best and math.min(best.width, best.height)
			if not best or l > bl or (l == bl and v.bandwidth > best.bandwidth) then
				best = v
			end
		end
		if not smallest or v.bandwidth < smallest.bandwidth then
			smallest = v
		end
	end
	return best or smallest
end

return Ts
