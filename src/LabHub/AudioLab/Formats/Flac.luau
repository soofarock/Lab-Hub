--!native
--!optimize 2
-- FLAC decoder (native FLAC streams, "fLaC"). Every subframe type (constant, verbatim, fixed order 0-4, LPC order
-- 1-32), Rice / Rice2 residuals with escape partitions, wasted bits, and all stereo decorrelation modes
-- (left/side, side/right, mid/side). 4 to 32 bits per sample, any sample rate, 1 to 8 channels.
-- Result: { signal = Signal, format = { codec = "flac", sampleRate, channels, bitsPerSample, totalSamples } }
-- Checked bit-exact against ffmpeg's decoder (16 / 24 bit, mono / stereo / 5.1, every stereo mode, LPC order 32).
--
--   local result = Flac.decode(bytes, { Yield = task.wait?, MaxSeconds = n? })
--   Flac.isFlac(bytes)

local AudioLab = script and script:FindFirstAncestor("AudioLab")
local Signal
if AudioLab then
	Signal = require(AudioLab.DSP.Signal)
else
	Signal = { -- standalone Luau (outside Roblox)
		new = function(sampleRate, channels, length)
			local data = table.create(channels)
			for c = 1, channels do
				data[c] = buffer.create(math.max(length, 1) * 4)
			end
			return { sampleRate = sampleRate, channels = channels, length = length, data = data }
		end,
	}
end

local Flac = {}

local readu8 = buffer.readu8
local band, bor, lshift, rshift = bit32.band, bit32.bor, bit32.lshift, bit32.rshift

function Flac.isFlac(bytes)
	local buf = type(bytes) == "string" and buffer.fromstring(bytes) or bytes
	if buffer.len(buf) < 4 then
		return false
	end
	if buffer.readstring(buf, 0, 4) == "fLaC" then
		return true
	end
	-- an ID3v2 tag in front of the stream (some taggers write one)
	if buffer.readstring(buf, 0, 3) == "ID3" and buffer.len(buf) > 10 then
		local size = bor(lshift(band(readu8(buf, 6), 0x7F), 21), lshift(band(readu8(buf, 7), 0x7F), 14), lshift(band(readu8(buf, 8), 0x7F), 7), band(readu8(buf, 9), 0x7F))
		local at = 10 + size
		return buffer.len(buf) >= at + 4 and buffer.readstring(buf, at, 4) == "fLaC"
	end
	return false
end

-- Bit reader over a buffer (MSB first). State in a table so helpers can share it; hot loops inline it.
local function reader(buf, pos)
	return { buf = buf, pos = pos * 8, len = buffer.len(buf) * 8 }
end

local function bits(r, n) -- n <= 32, unsigned
	if n == 0 then
		return 0
	end
	local buf, pos = r.buf, r.pos
	local v = 0
	local remaining = n
	while remaining > 0 do
		local byte = readu8(buf, pos // 8)
		local used = pos % 8
		local avail = 8 - used
		local take = math.min(avail, remaining)
		local chunk = band(rshift(byte, avail - take), lshift(1, take) - 1)
		v = v * 2 ^ take + chunk
		remaining -= take
		pos += take
	end
	r.pos = pos
	return v
end

local function sbits(r, n)
	if n == 0 then
		return 0
	end
	local v = bits(r, n)
	if v >= 2 ^ (n - 1) then
		v -= 2 ^ n
	end
	return v
end

local function unary(r) -- number of 0 bits before the next 1
	local buf, pos = r.buf, r.pos
	local count = 0
	while true do
		local byteIndex = pos // 8
		local used = pos % 8
		local byte = band(lshift(readu8(buf, byteIndex), used), 0xFF)
		if byte ~= 0 then
			-- leading zeros of the remaining bits
			local lz = 7 - math.floor(math.log(byte, 2) + 1e-9)
			count += lz
			pos += lz + 1
			break
		end
		count += 8 - used
		pos += 8 - used
	end
	r.pos = pos
	return count
end

local function alignByte(r)
	r.pos = (r.pos + 7) // 8 * 8
end

local BLOCK_SIZES = { [1] = 192, [2] = 576, [3] = 1152, [4] = 2304, [5] = 4608, [8] = 256, [9] = 512, [10] = 1024, [11] = 2048, [12] = 4096, [13] = 8192, [14] = 16384, [15] = 32768 }
local SAMPLE_SIZES = { [1] = 8, [2] = 12, [4] = 16, [5] = 20, [6] = 24, [7] = 32 }

-- Rice-coded residual for one subframe, written into out[order + 1 .. blockSize]
local function residual(r, out, blockSize, order)
	local method = bits(r, 2)
	if method > 1 then
		error("FLAC: reserved residual coding method")
	end
	local paramBits = method == 0 and 4 or 5
	local escape = method == 0 and 15 or 31
	local partOrder = bits(r, 4)
	local parts = 2 ^ partOrder
	local perPart = blockSize // parts
	local i = order + 1
	local buf = r.buf
	for p = 0, parts - 1 do
		local count = (p == 0) and (perPart - order) or perPart
		local k = bits(r, paramBits)
		if k == escape then
			local n = bits(r, 5)
			for _ = 1, count do
				out[i] = sbits(r, n)
				i += 1
			end
		else
			-- Rice: unary quotient, then k low bits; zigzag to signed. Inlined bit reading for speed.
			local pos = r.pos
			local scale = 2 ^ k
			for _ = 1, count do
				-- unary
				local q = 0
				while true do
					local used = pos % 8
					local byte = band(lshift(readu8(buf, pos // 8), used), 0xFF)
					if byte ~= 0 then
						local lz = 7 - math.floor(math.log(byte, 2) + 1e-9)
						q += lz
						pos += lz + 1
						break
					end
					q += 8 - used
					pos += 8 - used
				end
				-- k low bits
				local low = 0
				local remaining = k
				while remaining > 0 do
					local byte = readu8(buf, pos // 8)
					local used = pos % 8
					local avail = 8 - used
					local take = avail < remaining and avail or remaining
					low = low * 2 ^ take + band(rshift(byte, avail - take), lshift(1, take) - 1)
					remaining -= take
					pos += take
				end
				local u = q * scale + low
				if u % 2 == 0 then
					out[i] = u / 2
				else
					out[i] = -(u + 1) / 2
				end
				i += 1
			end
			r.pos = pos
		end
	end
end

-- one subframe into s[1..blockSize] (integers)
local function subframe(r, s, blockSize, bps)
	if bits(r, 1) ~= 0 then
		error("FLAC: bad subframe padding")
	end
	local kind = bits(r, 6)
	local wasted = 0
	if bits(r, 1) == 1 then
		wasted = unary(r) + 1
		bps -= wasted
	end
	if kind == 0 then
		local v = sbits(r, bps)
		for i = 1, blockSize do
			s[i] = v
		end
	elseif kind == 1 then
		for i = 1, blockSize do
			s[i] = sbits(r, bps)
		end
	elseif kind >= 8 and kind <= 12 then
		local order = kind - 8
		for i = 1, order do
			s[i] = sbits(r, bps)
		end
		residual(r, s, blockSize, order)
		if order == 1 then
			for i = 2, blockSize do
				s[i] += s[i - 1]
			end
		elseif order == 2 then
			for i = 3, blockSize do
				s[i] += 2 * s[i - 1] - s[i - 2]
			end
		elseif order == 3 then
			for i = 4, blockSize do
				s[i] += 3 * s[i - 1] - 3 * s[i - 2] + s[i - 3]
			end
		elseif order == 4 then
			for i = 5, blockSize do
				s[i] += 4 * s[i - 1] - 6 * s[i - 2] + 4 * s[i - 3] - s[i - 4]
			end
		end
	elseif kind >= 32 then
		local order = kind - 31
		for i = 1, order do
			s[i] = sbits(r, bps)
		end
		local precision = bits(r, 4) + 1
		if precision == 16 then
			error("FLAC: invalid LPC precision")
		end
		local shift = sbits(r, 5)
		local coef = table.create(order)
		for j = 1, order do
			coef[j] = sbits(r, precision)
		end
		residual(r, s, blockSize, order)
		local div = 2 ^ shift
		for i = order + 1, blockSize do
			local sum = 0
			for j = 1, order do
				sum += coef[j] * s[i - j]
			end
			s[i] += math.floor(sum / div)
		end
	else
		error(("FLAC: reserved subframe type %d"):format(kind))
	end
	if wasted > 0 then
		local m = 2 ^ wasted
		for i = 1, blockSize do
			s[i] *= m
		end
	end
end

local function readUtf8Number(r)
	local first = bits(r, 8)
	local extra, v
	if first < 0x80 then
		return first
	elseif first >= 0xFE then
		extra, v = 6, 0
	elseif first >= 0xFC then
		extra, v = 5, band(first, 0x01)
	elseif first >= 0xF8 then
		extra, v = 4, band(first, 0x03)
	elseif first >= 0xF0 then
		extra, v = 3, band(first, 0x07)
	elseif first >= 0xE0 then
		extra, v = 2, band(first, 0x0F)
	elseif first >= 0xC0 then
		extra, v = 1, band(first, 0x1F)
	else
		error("FLAC: bad frame number")
	end
	for _ = 1, extra do
		v = v * 64 + band(bits(r, 8), 0x3F)
	end
	return v
end

function Flac.decode(bytes, options)
	options = options or {}
	local buf = type(bytes) == "string" and buffer.fromstring(bytes) or bytes
	local len = buffer.len(buf)
	local at = 0
	if buffer.readstring(buf, 0, 3) == "ID3" then
		local size = bor(lshift(band(readu8(buf, 6), 0x7F), 21), lshift(band(readu8(buf, 7), 0x7F), 14), lshift(band(readu8(buf, 8), 0x7F), 7), band(readu8(buf, 9), 0x7F))
		at = 10 + size
	end
	if buffer.readstring(buf, at, 4) ~= "fLaC" then
		error("not a FLAC stream")
	end
	at += 4
	-- metadata blocks
	local info
	while true do
		local h = readu8(buf, at)
		local last = h >= 0x80
		local kind = band(h, 0x7F)
		local size = readu8(buf, at + 1) * 65536 + readu8(buf, at + 2) * 256 + readu8(buf, at + 3)
		if kind == 0 then
			local r = reader(buf, at + 4)
			local minBlock, maxBlock = bits(r, 16), bits(r, 16)
			bits(r, 24)
			bits(r, 24)
			local rate = bits(r, 20)
			local channels = bits(r, 3) + 1
			local bps = bits(r, 5) + 1
			local total = bits(r, 4) * 2 ^ 32 + bits(r, 32)
			info = { sampleRate = rate, channels = channels, bitsPerSample = bps, totalSamples = total, minBlock = minBlock, maxBlock = maxBlock }
		end
		at += 4 + size
		if last then
			break
		end
		if at >= len then
			error("FLAC: truncated metadata")
		end
	end
	if not info then
		error("FLAC: no STREAMINFO")
	end
	local channels = info.channels
	local maxFrames = options.MaxSeconds and math.floor(options.MaxSeconds * info.sampleRate) or math.huge
	local capacity = info.totalSamples > 0 and info.totalSamples or math.max(1, (len - at) // math.max(1, channels))
	capacity = math.min(capacity, maxFrames)
	local out = table.create(channels)
	for c = 1, channels do
		out[c] = buffer.create(math.max(capacity, 1) * 4)
	end
	local written = 0
	local r = reader(buf, at)
	local work = {}
	for c = 1, 8 do
		work[c] = table.create(info.maxBlock > 0 and info.maxBlock or 4608, 0)
	end
	local frames = 0
	local scale = 1 / 2 ^ (info.bitsPerSample - 1)
	while r.pos // 8 + 2 < len and written < capacity do
		-- frame header: sync 0b11111111111110, reserved, blocking strategy
		local byteAt = r.pos // 8
		if readu8(buf, byteAt) ~= 0xFF or band(readu8(buf, byteAt + 1), 0xFE) ~= 0xF8 then
			-- lost sync (trailing garbage / tag): look for the next frame start
			local found = false
			for b = byteAt + 1, len - 2 do
				if readu8(buf, b) == 0xFF and band(readu8(buf, b + 1), 0xFE) == 0xF8 then
					r.pos = b * 8
					found = true
					break
				end
			end
			if not found then
				break
			end
		end
		bits(r, 16)
		local bsCode = bits(r, 4)
		local rateCode = bits(r, 4)
		local chanCode = bits(r, 4)
		local sizeCode = bits(r, 3)
		bits(r, 1)
		readUtf8Number(r)
		local blockSize
		if bsCode == 6 then
			blockSize = bits(r, 8) + 1
		elseif bsCode == 7 then
			blockSize = bits(r, 16) + 1
		else
			blockSize = BLOCK_SIZES[bsCode]
		end
		if rateCode == 12 then
			bits(r, 8)
		elseif rateCode == 13 or rateCode == 14 then
			bits(r, 16)
		end
		bits(r, 8) -- CRC-8
		if not blockSize then
			error("FLAC: reserved block size")
		end
		local bps = SAMPLE_SIZES[sizeCode] or info.bitsPerSample
		local nch = chanCode < 8 and chanCode + 1 or 2
		for c = 1, nch do
			local s = work[c]
			local cbps = bps
			if (chanCode == 8 and c == 2) or (chanCode == 9 and c == 1) or (chanCode == 10 and c == 2) then
				cbps += 1 -- the side channel has one more bit
			end
			subframe(r, s, blockSize, cbps)
		end
		alignByte(r)
		bits(r, 16) -- CRC-16
		-- stereo decorrelation
		local a, b = work[1], work[2]
		if chanCode == 8 then -- left, side
			for i = 1, blockSize do
				b[i] = a[i] - b[i]
			end
		elseif chanCode == 9 then -- side, right
			for i = 1, blockSize do
				a[i] = a[i] + b[i]
			end
		elseif chanCode == 10 then -- mid, side
			for i = 1, blockSize do
				local side = b[i]
				local mid = a[i] * 2 + (side % 2)
				a[i] = (mid + side) / 2
				b[i] = (mid - side) / 2
			end
		end
		local n = math.min(blockSize, capacity - written)
		for c = 1, math.min(nch, channels) do
			local s, o = work[c], out[c]
			for i = 1, n do
				buffer.writef32(o, (written + i - 1) * 4, s[i] * scale)
			end
		end
		written += n
		frames += 1
		if options.Yield and frames % (options.YieldEvery or 64) == 0 then
			options.Yield()
		end
	end
	local signal = Signal.new(info.sampleRate, channels, written)
	for c = 1, channels do
		if written == capacity then
			signal.data[c] = out[c]
		else
			buffer.copy(signal.data[c], 0, out[c], 0, written * 4)
		end
	end
	info.codec = "flac"
	return { signal = signal, format = info }
end

return Flac
