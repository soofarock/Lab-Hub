--!native
--!optimize 2
-- Ogg Vorbis decoder (.ogg / .oga). Reads the first Vorbis stream of an Ogg file: every codebook kind (ordered,
-- sparse, lookup types 1 and 2), floor type 1, residue types 0 / 1 / 2, channel coupling, short / long blocks with
-- the Vorbis power-sine window, and the end trim from the last page's granule position. Written from the Vorbis I
-- specification; stb_vorbis (public domain) was the reference for the codeword assignment. Floor type 0 (only
-- pre-1.0 encoders made it) and Opus / FLAC inside Ogg are reported as unsupported.
-- Checked against ffmpeg's decoder (libvorbis q0-q10 and ffmpeg's own encoder, mono / stereo / 5.1, 22-48 kHz):
-- sample-for-sample within float rounding (difference ~134 dB under the signal), same length.
-- Channels come out in the WAV / FLAC order (L, R, C, LFE, rear / side).
-- Result: { signal = Signal, format = { codec = "vorbis", sampleRate, channels, bitrate } }
--
--   local result = Ogg.decode(bytes, { Yield = task.wait?, MaxSeconds = n? })
--   Ogg.isOgg(bytes)

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

local Ogg = {}

local readu8 = buffer.readu8
local band, lshift, rshift = bit32.band, bit32.lshift, bit32.rshift
local floor, sin, cos, pi = math.floor, math.sin, math.cos, math.pi

local INVERSE_DB = {
	1.0649863e-07, 1.1341951e-07, 1.2079015e-07, 1.2863978e-07,
	1.3699951e-07, 1.4590251e-07, 1.5538408e-07, 1.6548181e-07,
	1.7623575e-07, 1.8768855e-07, 1.9988561e-07, 2.1287530e-07,
	2.2670913e-07, 2.4144197e-07, 2.5713223e-07, 2.7384213e-07,
	2.9163793e-07, 3.1059021e-07, 3.3077411e-07, 3.5226968e-07,
	3.7516214e-07, 3.9954229e-07, 4.2550680e-07, 4.5315863e-07,
	4.8260743e-07, 5.1396998e-07, 5.4737065e-07, 5.8294187e-07,
	6.2082472e-07, 6.6116941e-07, 7.0413592e-07, 7.4989464e-07,
	7.9862701e-07, 8.5052630e-07, 9.0579828e-07, 9.6466216e-07,
	1.0273513e-06, 1.0941144e-06, 1.1652161e-06, 1.2409384e-06,
	1.3215816e-06, 1.4074654e-06, 1.4989305e-06, 1.5963394e-06,
	1.7000785e-06, 1.8105592e-06, 1.9282195e-06, 2.0535261e-06,
	2.1869758e-06, 2.3290978e-06, 2.4804557e-06, 2.6416497e-06,
	2.8133190e-06, 2.9961443e-06, 3.1908506e-06, 3.3982101e-06,
	3.6190449e-06, 3.8542308e-06, 4.1047004e-06, 4.3714470e-06,
	4.6555282e-06, 4.9580707e-06, 5.2802740e-06, 5.6234160e-06,
	5.9888572e-06, 6.3780469e-06, 6.7925283e-06, 7.2339451e-06,
	7.7040476e-06, 8.2047000e-06, 8.7378876e-06, 9.3057248e-06,
	9.9104632e-06, 1.0554501e-05, 1.1240392e-05, 1.1970856e-05,
	1.2748789e-05, 1.3577278e-05, 1.4459606e-05, 1.5399272e-05,
	1.6400004e-05, 1.7465768e-05, 1.8600792e-05, 1.9809576e-05,
	2.1096914e-05, 2.2467911e-05, 2.3928002e-05, 2.5482978e-05,
	2.7139006e-05, 2.8902651e-05, 3.0780908e-05, 3.2781225e-05,
	3.4911534e-05, 3.7180282e-05, 3.9596466e-05, 4.2169667e-05,
	4.4910090e-05, 4.7828601e-05, 5.0936773e-05, 5.4246931e-05,
	5.7772202e-05, 6.1526565e-05, 6.5524908e-05, 6.9783085e-05,
	7.4317983e-05, 7.9147585e-05, 8.4291040e-05, 8.9768747e-05,
	9.5602426e-05, 0.00010181521, 0.00010843174, 0.00011547824,
	0.00012298267, 0.00013097477, 0.00013948625, 0.00014855085,
	0.00015820453, 0.00016848555, 0.00017943469, 0.00019109536,
	0.00020351382, 0.00021673929, 0.00023082423, 0.00024582449,
	0.00026179955, 0.00027881276, 0.00029693158, 0.00031622787,
	0.00033677814, 0.00035866388, 0.00038197188, 0.00040679456,
	0.00043323036, 0.00046138411, 0.00049136745, 0.00052329927,
	0.00055730621, 0.00059352311, 0.00063209358, 0.00067317058,
	0.00071691700, 0.00076350630, 0.00081312324, 0.00086596457,
	0.00092223983, 0.00098217216, 0.0010459992, 0.0011139742,
	0.0011863665, 0.0012634633, 0.0013455702, 0.0014330129,
	0.0015261382, 0.0016253153, 0.0017309374, 0.0018434235,
	0.0019632195, 0.0020908006, 0.0022266726, 0.0023713743,
	0.0025254795, 0.0026895994, 0.0028643847, 0.0030505286,
	0.0032487691, 0.0034598925, 0.0036847358, 0.0039241906,
	0.0041792066, 0.0044507950, 0.0047400328, 0.0050480668,
	0.0053761186, 0.0057254891, 0.0060975636, 0.0064938176,
	0.0069158225, 0.0073652516, 0.0078438871, 0.0083536271,
	0.0088964928, 0.009474637, 0.010090352, 0.010746080,
	0.011444421, 0.012188144, 0.012980198, 0.013823725,
	0.014722068, 0.015678791, 0.016697687, 0.017782797,
	0.018938423, 0.020169149, 0.021479854, 0.022875735,
	0.024362330, 0.025945531, 0.027631618, 0.029427276,
	0.031339626, 0.033376252, 0.035545228, 0.037855157,
	0.040315199, 0.042935108, 0.045725273, 0.048696758,
	0.051861348, 0.055231591, 0.058820850, 0.062643361,
	0.066714279, 0.071049749, 0.075666962, 0.080584227,
	0.085821044, 0.091398179, 0.097337747, 0.10366330,
	0.11039993, 0.11757434, 0.12521498, 0.13335215,
	0.14201813, 0.15124727, 0.16107617, 0.17154380,
	0.18269168, 0.19456402, 0.20720788, 0.22067342,
	0.23501402, 0.25028656, 0.26655159, 0.28387361,
	0.30232132, 0.32196786, 0.34289114, 0.36517414,
	0.38890521, 0.41417847, 0.44109412, 0.46975890,
	0.50028648, 0.53279791, 0.56742212, 0.60429640,
	0.64356699, 0.68538959, 0.72993007, 0.77736504,
	0.82788260, 0.88168307, 0.9389798, 1.0,
}

function Ogg.isOgg(bytes)
	local buf = type(bytes) == "string" and buffer.fromstring(bytes) or bytes
	return buffer.len(buf) >= 4 and buffer.readstring(buf, 0, 4) == "OggS"
end

---------------------------------------------------------------------------------------------------------------------
-- Ogg pages -> packets of the first logical stream

local function readPackets(buf)
	local len = buffer.len(buf)
	local pos = 0
	local serial = nil
	local packets = {}
	local pending = {} -- segments of a packet continued on the next page
	local pendingLen = 0
	local lastGranule = -1
	while pos + 27 <= len do
		if buffer.readstring(buf, pos, 4) ~= "OggS" then
			-- resync to the next page
			local found = false
			for p = pos + 1, len - 4 do
				if readu8(buf, p) == 0x4F and buffer.readstring(buf, p, 4) == "OggS" then
					pos = p
					found = true
					break
				end
			end
			if not found then
				break
			end
		end
		local headerType = readu8(buf, pos + 5)
		local glo, ghi = buffer.readu32(buf, pos + 6), buffer.readu32(buf, pos + 10)
		local granule = (glo == 0xFFFFFFFF and ghi == 0xFFFFFFFF) and -1 or (ghi * 4294967296 + glo)
		local pageSerial = buffer.readu32(buf, pos + 14)
		local nseg = readu8(buf, pos + 26)
		local dataAt = pos + 27 + nseg
		if serial == nil then
			if band(headerType, 0x02) ~= 0 then
				serial = pageSerial
			end
		end
		if pageSerial == serial then
			local at = dataAt
			local endedHere = 0
			for s = 0, nseg - 1 do
				local lace = readu8(buf, pos + 27 + s)
				if lace > 0 then
					table.insert(pending, { at, lace })
					pendingLen += lace
				end
				at += lace
				if lace < 255 then
					-- packet complete
					local pb = buffer.create(pendingLen)
					local o = 0
					for _, seg in ipairs(pending) do
						buffer.copy(pb, o, buf, seg[1], seg[2])
						o += seg[2]
					end
					table.insert(packets, { buf = pb, granule = -1 })
					endedHere += 1
					table.clear(pending)
					pendingLen = 0
				end
			end
			if endedHere > 0 and granule >= 0 then
				packets[#packets].granule = granule
				lastGranule = granule
			end
			pos = at
		else
			local at = dataAt
			for s = 0, nseg - 1 do
				at += readu8(buf, pos + 27 + s)
			end
			pos = at
		end
	end
	return packets, lastGranule
end

---------------------------------------------------------------------------------------------------------------------
-- LSB-first bit reader over one packet

local function reader(buf)
	return { buf = buf, pos = 0, endb = buffer.len(buf) * 8, eop = false }
end

local function read(r, n)
	if n == 0 then
		return 0
	end
	local buf, pos, endb = r.buf, r.pos, r.endb
	local v, shift = 0, 1
	while n > 0 do
		if pos >= endb then
			r.eop = true
			r.pos = pos
			return 0
		end
		local used = pos % 8
		local take = 8 - used
		if take > n then
			take = n
		end
		local chunk = band(rshift(readu8(buf, pos // 8), used), lshift(1, take) - 1)
		v += chunk * shift
		shift *= 2 ^ take
		n -= take
		pos += take
	end
	r.pos = pos
	return v
end

-- next n bits without consuming them (zeros past the end of the packet)
local function peek(r, n)
	local buf, pos, endb = r.buf, r.pos, r.endb
	local v, shift = 0, 1
	while n > 0 and pos < endb do
		local used = pos % 8
		local take = 8 - used
		if take > n then
			take = n
		end
		local chunk = band(rshift(readu8(buf, pos // 8), used), lshift(1, take) - 1)
		v += chunk * shift
		shift *= 2 ^ take
		n -= take
		pos += take
	end
	return v
end

local function ilog(x)
	local n = 0
	while x > 0 do
		n += 1
		x = x // 2
	end
	return n
end

local function float32Unpack(x)
	local mantissa = x % 2097152 -- 0x1fffff + 1
	local sign = x >= 2147483648
	local exp = (x // 2097152) % 1024
	local v = mantissa * 2 ^ (exp - 788)
	return sign and -v or v
end

local function lookup1Values(entries, dims)
	local r = floor(math.exp(math.log(entries) / dims))
	if floor((r + 1) ^ dims) <= entries then
		r += 1
	end
	while r > 0 and r ^ dims > entries do
		r -= 1
	end
	return r
end

local function rev32(x)
	local r = 0
	for _ = 1, 32 do
		r = r * 2 + x % 2
		x = x // 2
	end
	return r
end

---------------------------------------------------------------------------------------------------------------------
-- Codebooks

local FAST_BITS = 10
local FAST_SIZE = 2 ^ FAST_BITS

local function readCodebook(r)
	if read(r, 24) ~= 0x564342 then
		error("Vorbis: bad codebook sync")
	end
	local dims = read(r, 16)
	local entries = read(r, 24)
	local lengths = table.create(entries, 0)
	if read(r, 1) == 0 then
		local sparse = read(r, 1) == 1
		for i = 1, entries do
			if sparse then
				if read(r, 1) == 1 then
					lengths[i] = read(r, 5) + 1
				end
			else
				lengths[i] = read(r, 5) + 1
			end
		end
	else
		local current = 0
		local curLen = read(r, 5) + 1
		while current < entries do
			local number = read(r, ilog(entries - current))
			for i = current + 1, current + number do
				lengths[i] = curLen
			end
			current += number
			curLen += 1
		end
	end
	local book = { dims = dims, entries = entries }
	-- codewords (lowest free leaf first, as the specification and stb_vorbis assign them)
	local fast = table.create(FAST_SIZE, 0)
	local fastLen = table.create(FAST_SIZE, 0)
	local tree = { 0, 0 } -- tree[node * 2 + bit + 1]: > 0 next node, < 0 -(entry + 1), 0 none
	local nodes = 1
	local used = 0
	local only = nil
	for i = 1, entries do
		if lengths[i] > 0 then
			used += 1
			only = i
		end
	end
	book.single = (used == 1) and only or nil
	book.singleLen = book.single and lengths[only] or nil
	local available = table.create(32, 0)
	local function add(entry, code, len) -- code: LSB-first, low len bits
		if len <= FAST_BITS then
			local step = 2 ^ len
			for k = 0, FAST_SIZE / step - 1 do
				local idx = code + k * step
				fast[idx + 1] = entry
				fastLen[idx + 1] = len
			end
		end
		local node = 0
		for b = 0, len - 1 do
			local bit = (code // 2 ^ b) % 2
			local slot = node * 2 + bit + 1
			if b == len - 1 then
				tree[slot] = -entry
			else
				if tree[slot] == nil or tree[slot] == 0 then
					nodes += 1
					tree[nodes * 2 - 1] = 0
					tree[nodes * 2] = 0
					tree[slot] = nodes - 1
				end
				node = tree[slot]
			end
		end
	end
	local k = 1
	while k <= entries and lengths[k] == 0 do
		k += 1
	end
	if k <= entries and used > 1 then
		add(k, 0, lengths[k])
		for i = 1, lengths[k] do
			available[i] = 2 ^ (32 - i)
		end
		for i = k + 1, entries do
			local z = lengths[i]
			if z > 0 then
				local zz = z
				while zz > 0 and available[zz] == 0 do
					zz -= 1
				end
				if zz == 0 then
					error("Vorbis: overspecified codebook")
				end
				local res = available[zz]
				available[zz] = 0
				add(i, rev32(res) % 2 ^ z, z)
				if zz ~= z then
					for y = z, zz + 1, -1 do
						available[y] = res + 2 ^ (32 - y)
					end
				end
			end
		end
	end
	book.fast, book.fastLen, book.tree = fast, fastLen, tree
	-- vector lookup
	local lookupType = read(r, 4)
	book.lookupType = lookupType
	if lookupType == 1 or lookupType == 2 then
		local minv = float32Unpack(read(r, 32))
		local delta = float32Unpack(read(r, 32))
		local valueBits = read(r, 4) + 1
		local seq = read(r, 1) == 1
		local nvals = (lookupType == 1) and lookup1Values(entries, dims) or entries * dims
		local mult = table.create(nvals)
		for i = 1, nvals do
			mult[i] = read(r, valueBits)
		end
		local vq = table.create(entries * dims, 0)
		for e = 0, entries - 1 do
			local last = 0
			local divisor = 1
			for j = 0, dims - 1 do
				local off
				if lookupType == 1 then
					off = (e // divisor) % nvals
					divisor *= nvals
				else
					off = e * dims + j
				end
				local v = mult[off + 1] * delta + minv + last
				if seq then
					last = v
				end
				vq[e * dims + j + 1] = v
			end
		end
		book.vq = vq
	elseif lookupType ~= 0 then
		error("Vorbis: bad codebook lookup type")
	end
	return book
end

-- one entry (1-based) of a codebook from the packet, or nil at the end of the packet
local function decodeEntry(r, book)
	if book.single then
		r.pos += book.singleLen
		if r.pos > r.endb then
			r.eop = true
			return nil
		end
		return book.single
	end
	local v = peek(r, FAST_BITS)
	local e = book.fast[v + 1]
	if e > 0 then
		r.pos += book.fastLen[v + 1]
		if r.pos > r.endb then
			r.eop = true
			return nil
		end
		return e
	end
	local tree = book.tree
	local node = 0
	while true do
		if r.pos >= r.endb then
			r.eop = true
			return nil
		end
		local bit = read(r, 1)
		local nxt = tree[node * 2 + bit + 1]
		if nxt == nil or nxt == 0 then
			return nil -- invalid code
		elseif nxt < 0 then
			return -nxt
		end
		node = nxt
	end
end

---------------------------------------------------------------------------------------------------------------------
-- Setup header parts

local function readFloor(r, books)
	local kind = read(r, 16)
	if kind ~= 1 then
		error("Vorbis: floor type 0 is not supported (a pre-1.0 encoder made this file)")
	end
	local f = { partitions = read(r, 5) }
	local classList = {}
	local maxClass = -1
	for i = 1, f.partitions do
		classList[i] = read(r, 4)
		maxClass = math.max(maxClass, classList[i])
	end
	local classes = {}
	for c = 0, maxClass do
		local cl = { dims = read(r, 3) + 1, subBits = read(r, 2) }
		if cl.subBits > 0 then
			cl.master = read(r, 8) + 1
		end
		cl.subBooks = {}
		for j = 0, 2 ^ cl.subBits - 1 do
			cl.subBooks[j] = read(r, 8) -- book + 1, 0 = none
		end
		classes[c] = cl
	end
	f.multiplier = read(r, 2) + 1
	local rangeBits = read(r, 4)
	local X = { 0, 2 ^ rangeBits }
	for i = 1, f.partitions do
		local cl = classes[classList[i]]
		for _ = 1, cl.dims do
			table.insert(X, read(r, rangeBits))
		end
	end
	f.classList, f.classes, f.X = classList, classes, X
	local values = #X
	f.values = values
	-- neighbours and drawing order
	local low, high = {}, {}
	for i = 3, values do
		local lo, hi = 1, 2
		local lx, hx = -1, math.huge
		for j = 1, i - 1 do
			if X[j] < X[i] and X[j] > lx then
				lx, lo = X[j], j
			end
			if X[j] > X[i] and X[j] < hx then
				hx, hi = X[j], j
			end
		end
		low[i], high[i] = lo, hi
	end
	f.low, f.high = low, high
	local order = {}
	for i = 1, values do
		order[i] = i
	end
	table.sort(order, function(a, b)
		return X[a] < X[b]
	end)
	f.order = order
	return f
end

local function readResidue(r)
	local res = { kind = read(r, 16) }
	if res.kind > 2 then
		error("Vorbis: bad residue type")
	end
	res.rbegin = read(r, 24)
	res.rend = read(r, 24)
	res.partSize = read(r, 24) + 1
	res.classifications = read(r, 6) + 1
	res.classbook = read(r, 8) + 1
	local cascade = {}
	for i = 1, res.classifications do
		local low = read(r, 3)
		local high = 0
		if read(r, 1) == 1 then
			high = read(r, 5)
		end
		cascade[i] = high * 8 + low
	end
	res.books = {}
	for i = 1, res.classifications do
		local bks = {}
		for j = 0, 7 do
			if (cascade[i] // 2 ^ j) % 2 == 1 then
				bks[j] = read(r, 8) + 1
			end
		end
		res.books[i] = bks
	end
	return res
end

local function readMapping(r, channels)
	if read(r, 16) ~= 0 then
		error("Vorbis: bad mapping type")
	end
	local m = { submaps = 1, coupling = {}, mux = {}, submapFloor = {}, submapResidue = {} }
	if read(r, 1) == 1 then
		m.submaps = read(r, 4) + 1
	end
	if read(r, 1) == 1 then
		local steps = read(r, 8) + 1
		local bits = ilog(channels - 1)
		for _ = 1, steps do
			local mag = read(r, bits) + 1
			local ang = read(r, bits) + 1
			table.insert(m.coupling, { mag, ang })
		end
	end
	if read(r, 2) ~= 0 then
		error("Vorbis: bad mapping reserved field")
	end
	for c = 1, channels do
		m.mux[c] = (m.submaps > 1) and (read(r, 4) + 1) or 1
	end
	for s = 1, m.submaps do
		read(r, 8)
		m.submapFloor[s] = read(r, 8) + 1
		m.submapResidue[s] = read(r, 8) + 1
	end
	return m
end

---------------------------------------------------------------------------------------------------------------------
-- Floor 1 curve

local function floorDecode(r, f, books)
	if read(r, 1) == 0 then
		return nil
	end
	local range = ({ 256, 128, 86, 64 })[f.multiplier]
	local Y = table.create(f.values, 0)
	local rb = ilog(range - 1)
	Y[1] = read(r, rb)
	Y[2] = read(r, rb)
	local offset = 3
	for i = 1, f.partitions do
		local cl = f.classes[f.classList[i]]
		local cdim, cbits = cl.dims, cl.subBits
		local csub = 2 ^ cbits
		local cval = 0
		if cbits > 0 then
			cval = (decodeEntry(r, books[cl.master]) or 1) - 1
		end
		for j = 0, cdim - 1 do
			local book = cl.subBooks[cval % csub]
			cval = cval // csub
			if book and book > 0 then
				Y[offset + j] = (decodeEntry(r, books[book]) or 1) - 1
			else
				Y[offset + j] = 0
			end
		end
		offset += cdim
	end
	if r.eop then
		return nil
	end
	return Y
end

local function renderPoint(x0, y0, x1, y1, x)
	local dy = y1 - y0
	local adx = x1 - x0
	local err = math.abs(dy) * (x - x0)
	local off = err // adx
	return dy < 0 and y0 - off or y0 + off
end

local function renderLine(out, x0, y0, x1, y1, n)
	local dy = y1 - y0
	local adx = x1 - x0
	local ady = math.abs(dy)
	local base = (dy < 0) and -((-dy) // adx) or (dy // adx)
	local sy = dy < 0 and base - 1 or base + 1
	ady -= math.abs(base) * adx
	if x1 > n then
		x1 = n
	end
	local y = y0
	local err = 0
	if x0 < x1 then
		out[x0 + 1] = INVERSE_DB[y + 1]
		for x = x0 + 1, x1 - 1 do
			err += ady
			if err >= adx then
				err -= adx
				y += sy
			else
				y += base
			end
			out[x + 1] = INVERSE_DB[y + 1]
		end
	end
end

local function floorCurve(f, Y, n2, out)
	local X, low, high = f.X, f.low, f.high
	local range = ({ 256, 128, 86, 64 })[f.multiplier]
	local step2 = table.create(f.values, false)
	local final = table.create(f.values, 0)
	step2[1], step2[2] = true, true
	final[1], final[2] = Y[1], Y[2]
	for i = 3, f.values do
		local lo, hi = low[i], high[i]
		local predicted = renderPoint(X[lo], final[lo], X[hi], final[hi], X[i])
		local val = Y[i]
		local highroom = range - predicted
		local lowroom = predicted
		local room = (highroom < lowroom and highroom or lowroom) * 2
		if val ~= 0 then
			step2[lo], step2[hi], step2[i] = true, true, true
			if val >= room then
				if highroom > lowroom then
					final[i] = val - lowroom + predicted
				else
					final[i] = predicted - val + highroom - 1
				end
			elseif val % 2 == 1 then
				final[i] = predicted - (val + 1) // 2
			else
				final[i] = predicted + val // 2
			end
		else
			step2[i] = false
			final[i] = predicted
		end
	end
	local order = f.order
	local mult = f.multiplier
	local lx, ly = 0, final[order[1]] * mult
	for j = 2, f.values do
		local idx = order[j]
		if step2[idx] then
			local hy = final[idx] * mult
			local hx = X[idx]
			renderLine(out, lx, ly, hx, hy, n2)
			lx, ly = hx, hy
		end
	end
	if lx < n2 then
		local v = INVERSE_DB[ly + 1]
		for x = lx, n2 - 1 do
			out[x + 1] = v
		end
	end
end

---------------------------------------------------------------------------------------------------------------------
-- Residue

local function decodePartition(r, book, vec, offset, partSize, kind)
	local dims = book.dims
	local vq = book.vq
	if kind == 0 then
		local step = partSize // dims
		for i = 0, step - 1 do
			local e = decodeEntry(r, book)
			if not e then
				return false
			end
			local base = (e - 1) * dims
			for j = 0, dims - 1 do
				local at = offset + i + j * step + 1
				vec[at] += vq[base + j + 1]
			end
		end
	else
		local i = 0
		while i < partSize do
			local e = decodeEntry(r, book)
			if not e then
				return false
			end
			local base = (e - 1) * dims
			for j = 0, dims - 1 do
				vec[offset + i + 1] += vq[base + j + 1]
				i += 1
			end
		end
	end
	return true
end

local function residueDecode(r, res, books, vectors, dnd, n2)
	local kind = res.kind
	local chs = #vectors
	local work, workDnd, size
	if kind == 2 then
		local any = false
		for c = 1, chs do
			if not dnd[c] then
				any = true
			end
		end
		if not any then
			return
		end
		size = n2 * chs
		work = { table.create(size, 0) }
		workDnd = { false }
	else
		work, workDnd, size = vectors, dnd, n2
	end
	local wch = #work
	local limitBegin = math.min(res.rbegin, size)
	local limitEnd = math.min(res.rend, size)
	local partSize = res.partSize
	local toRead = math.max(0, limitEnd - limitBegin) // partSize
	if toRead > 0 then
		local classbook = books[res.classbook]
		local cpw = classbook.dims
		local ncls = res.classifications
		local classes = {}
		for c = 1, wch do
			classes[c] = table.create(toRead + cpw, 0)
		end
		local done = false
		for pass = 0, 7 do
			local pc = 0
			while pc < toRead do
				if pass == 0 then
					for c = 1, wch do
						if not workDnd[c] then
							local temp = decodeEntry(r, classbook)
							if not temp then
								done = true
								break
							end
							temp -= 1
							for i = cpw - 1, 0, -1 do
								classes[c][pc + i + 1] = temp % ncls
								temp = temp // ncls
							end
						end
					end
					if done then
						break
					end
				end
				for _ = 1, cpw do
					if pc >= toRead then
						break
					end
					for c = 1, wch do
						if not workDnd[c] then
							local cls = classes[c][pc + 1]
							local bk = res.books[cls + 1][pass]
							if bk then
								if not decodePartition(r, books[bk], work[c], limitBegin + pc * partSize, partSize, kind == 2 and 1 or kind) then
									done = true
									break
								end
							end
						end
					end
					if done then
						break
					end
					pc += 1
				end
				if done then
					break
				end
			end
			if done then
				break
			end
		end
	end
	if kind == 2 then
		local w = work[1]
		for c = 1, chs do
			local v = vectors[c]
			for i = 0, n2 - 1 do
				v[i + 1] = w[i * chs + c]
			end
		end
	end
end

---------------------------------------------------------------------------------------------------------------------
-- Inverse MDCT: n outputs from n/2 coefficients, y[i] = sum X[k] cos(2 pi / n (i + 1/2 + n/4)(k + 1/2)), through a
-- DCT-IV of size n/2 computed with a complex FFT of size n/4

local fftCache = {}
local function fftTables(m) -- m = complex FFT size
	local t = fftCache[m]
	if t then
		return t
	end
	local rev = table.create(m, 0)
	local bits = ilog(m - 1)
	for i = 0, m - 1 do
		local x, r = i, 0
		for _ = 1, bits do
			r = r * 2 + x % 2
			x = x // 2
		end
		rev[i + 1] = r
	end
	local wr, wi = table.create(m / 2), table.create(m / 2)
	for k = 0, m / 2 - 1 do
		wr[k + 1] = cos(-2 * pi * k / m)
		wi[k + 1] = sin(-2 * pi * k / m)
	end
	t = { rev = rev, wr = wr, wi = wi }
	fftCache[m] = t
	return t
end

local function fft(re, im, m)
	local t = fftTables(m)
	local rev = t.rev
	for i = 0, m - 1 do
		local j = rev[i + 1]
		if j > i then
			re[i + 1], re[j + 1] = re[j + 1], re[i + 1]
			im[i + 1], im[j + 1] = im[j + 1], im[i + 1]
		end
	end
	local wr, wi = t.wr, t.wi
	local size = 2
	while size <= m do
		local half = size / 2
		local stride = m / size
		for start = 0, m - 1, size do
			for k = 0, half - 1 do
				local a = start + k + 1
				local b = a + half
				local cr, ci = wr[k * stride + 1], wi[k * stride + 1]
				local xr = re[b] * cr - im[b] * ci
				local xi = re[b] * ci + im[b] * cr
				re[b] = re[a] - xr
				im[b] = im[a] - xi
				re[a] += xr
				im[a] += xi
			end
		end
		size *= 2
	end
end

local twCache = {}
local function imdctTables(M) -- M = n/2
	local t = twCache[M]
	if t then
		return t
	end
	local h = M / 2
	-- pre-twiddle exp(-i pi k / M), post-twiddle exp(-i pi (k + 1/4) / M)
	local pr, pim, qr, qi = table.create(h), table.create(h), table.create(h), table.create(h)
	for k = 0, h - 1 do
		local a = -pi * k / M
		pr[k + 1], pim[k + 1] = cos(a), sin(a)
		local b = -pi * (k + 0.25) / M
		qr[k + 1], qi[k + 1] = cos(b), sin(b)
	end
	t = { pr = pr, pi = pim, qr = qr, qi = qi, re = table.create(h, 0), im = table.create(h, 0), u = table.create(M, 0) }
	twCache[M] = t
	return t
end

-- DCT-IV of X[1..M] into u[1..M]: u[n] = sum X[k] cos(pi / M (n + 1/2)(k + 1/2))
local function dct4(X, M)
	local t = imdctTables(M)
	local h = M / 2
	local re, im, pr, pim, qr, qi, u = t.re, t.im, t.pr, t.pi, t.qr, t.qi, t.u
	for k = 0, h - 1 do
		local a, b = X[2 * k + 1], X[M - 2 * k]
		re[k + 1] = a * pr[k + 1] - b * pim[k + 1]
		im[k + 1] = a * pim[k + 1] + b * pr[k + 1]
	end
	fft(re, im, h)
	for k = 0, h - 1 do
		local a, b = re[k + 1], im[k + 1]
		u[2 * k + 1] = a * qr[k + 1] - b * qi[k + 1]
		u[M - 2 * k] = -(a * qi[k + 1] + b * qr[k + 1])
	end
	return u
end

Ogg._dct4 = dct4 -- (tests)

---------------------------------------------------------------------------------------------------------------------

local slopeCache = {}
local function slope(n2) -- rising half of the Vorbis window, n2 samples
	local s = slopeCache[n2]
	if s then
		return s
	end
	s = table.create(n2)
	for i = 0, n2 - 1 do
		local x = sin((i + 0.5) / n2 * pi / 2)
		s[i + 1] = sin(pi / 2 * x * x)
	end
	slopeCache[n2] = s
	return s
end

function Ogg.decode(bytes, options)
	options = options or {}
	local buf = type(bytes) == "string" and buffer.fromstring(bytes) or bytes
	if not Ogg.isOgg(buf) then
		error("not an Ogg file")
	end
	local packets, lastGranule = readPackets(buf)
	if #packets < 3 then
		error("OGG: no complete stream found")
	end
	local p1 = packets[1].buf
	local magic = buffer.len(p1) >= 8 and buffer.readstring(p1, 0, 8) or ""
	if magic == "OpusHead" then
		error("OGG: this file holds Opus audio; only Vorbis is supported for now", 0)
	elseif buffer.readstring(p1, 0, math.min(5, buffer.len(p1))) == "\x7FFLAC" then
		error("OGG: this file holds FLAC audio inside Ogg; save it as a plain .flac", 0)
	elseif buffer.len(p1) < 30 or readu8(p1, 0) ~= 1 or buffer.readstring(p1, 1, 6) ~= "vorbis" then
		error("OGG: not a Vorbis stream", 0)
	end
	-- identification header
	local channels = readu8(p1, 11)
	local rate = buffer.readu32(p1, 12)
	local bitrate = buffer.readi32(p1, 20)
	local bsByte = readu8(p1, 28)
	local bs0, bs1 = 2 ^ (bsByte % 16), 2 ^ (bsByte // 16)
	if channels < 1 or rate < 1 or bs0 < 64 or bs1 < bs0 then
		error("Vorbis: bad identification header")
	end
	-- setup header (packet 3)
	local r = reader(packets[3].buf)
	if read(r, 8) ~= 5 or read(r, 8) ~= 0x76 then
		error("Vorbis: missing setup header")
	end
	for _ = 1, 5 do
		read(r, 8)
	end
	local books = {}
	for i = 1, read(r, 8) + 1 do
		books[i] = readCodebook(r)
		if options.Yield and i % 16 == 0 then
			options.Yield()
		end
	end
	for _ = 1, read(r, 6) + 1 do
		if read(r, 16) ~= 0 then
			error("Vorbis: bad time domain transform")
		end
	end
	local floors = {}
	for i = 1, read(r, 6) + 1 do
		floors[i] = readFloor(r, books)
	end
	local residues = {}
	for i = 1, read(r, 6) + 1 do
		residues[i] = readResidue(r)
	end
	local mappings = {}
	for i = 1, read(r, 6) + 1 do
		mappings[i] = readMapping(r, channels)
	end
	local modes = {}
	for i = 1, read(r, 6) + 1 do
		local blockflag = read(r, 1)
		read(r, 16)
		read(r, 16)
		modes[i] = { blockflag = blockflag, mapping = read(r, 8) + 1 }
	end
	local modeBits = ilog(#modes - 1)
	-- output
	local total = lastGranule > 0 and lastGranule or nil
	local maxOut = options.MaxSeconds and floor(options.MaxSeconds * rate) or math.huge
	local estimate = total or (#packets * bs1)
	local capacity = math.min(estimate, maxOut)
	local MARGIN = bs1
	local acc = {}
	for c = 1, channels do
		acc[c] = buffer.create((capacity + 2 * MARGIN) * 4)
	end
	local vectors = {}
	local floorOut = {}
	for c = 1, channels do
		vectors[c] = table.create(bs1 / 2, 0)
		floorOut[c] = table.create(bs1 / 2, 0)
	end
	local center = 0 -- absolute position of the current block's centre
	local prevN = nil
	local produced = 0
	for pi_ = 4, #packets do
		local pr = reader(packets[pi_].buf)
		if read(pr, 1) ~= 0 then
			continue -- not an audio packet
		end
		local mode = modes[read(pr, modeBits) + 1]
		if not mode then
			continue
		end
		local long = mode.blockflag == 1
		local n = long and bs1 or bs0
		local prevFlag, nextFlag = 1, 1
		if long then
			prevFlag = read(pr, 1)
			nextFlag = read(pr, 1)
		end
		local n2 = n / 2
		local map = mappings[mode.mapping]
		-- floors
		local noResidue = {}
		local floorY = {}
		for c = 1, channels do
			local f = floors[map.submapFloor[map.mux[c]]]
			local Y = floorDecode(pr, f, books)
			floorY[c] = Y
			noResidue[c] = (Y == nil)
		end
		for _, step in ipairs(map.coupling) do
			if not noResidue[step[1]] or not noResidue[step[2]] then
				noResidue[step[1]] = false
				noResidue[step[2]] = false
			end
		end
		for c = 1, channels do
			local v = vectors[c]
			for i = 1, n2 do
				v[i] = 0
			end
		end
		-- residues per submap
		for s = 1, map.submaps do
			local vs, dnd = {}, {}
			for c = 1, channels do
				if map.mux[c] == s then
					table.insert(vs, vectors[c])
					table.insert(dnd, noResidue[c])
				end
			end
			if #vs > 0 then
				residueDecode(pr, residues[map.submapResidue[s]], books, vs, dnd, n2)
			end
		end
		-- inverse coupling
		for i = #map.coupling, 1, -1 do
			local M, A = vectors[map.coupling[i][1]], vectors[map.coupling[i][2]]
			for j = 1, n2 do
				local m, a = M[j], A[j]
				if m > 0 then
					if a > 0 then
						A[j] = m - a
					else
						A[j] = m
						M[j] = m + a
					end
				else
					if a > 0 then
						A[j] = m + a
					else
						A[j] = m
						M[j] = m - a
					end
				end
			end
		end
		-- block position: centres advance by a quarter of each neighbouring block
		if prevN then
			center += prevN / 4 + n / 4
		end
		prevN = n
		-- window
		local leftStart, leftEnd, leftN, rightStart, rightEnd, rightN
		if long and prevFlag == 0 then
			leftStart, leftEnd, leftN = n / 4 - bs0 / 4, n / 4 + bs0 / 4, bs0 / 2
		else
			leftStart, leftEnd, leftN = 0, n2, n2
		end
		if long and nextFlag == 0 then
			rightStart, rightEnd, rightN = 3 * n / 4 - bs0 / 4, 3 * n / 4 + bs0 / 4, bs0 / 2
		else
			rightStart, rightEnd, rightN = n2, n, n2
		end
		local ls, rs = slope(leftN), slope(rightN)
		local blockStart = center - n2 -- absolute position of output sample 0 of this block
		for c = 1, channels do
			local v = vectors[c]
			if floorY[c] then
				local fo = floorOut[c]
				floorCurve(floors[map.submapFloor[map.mux[c]]], floorY[c], n2, fo)
				for i = 1, n2 do
					v[i] *= fo[i]
				end
			else
				for i = 1, n2 do
					v[i] = 0
				end
			end
			if floorY[c] or noResidue[c] == false then
				local u = dct4(v, n2)
				local o = acc[c]
				local half = n2 / 2
				for i = leftStart, rightEnd - 1 do
					local y
					if i < half then
						y = u[i + half + 1]
					elseif i < 3 * half then
						y = -u[3 * half - i]
					else
						y = -u[i - 3 * half + 1]
					end
					local w
					if i < leftEnd then
						w = ls[i - leftStart + 1]
					elseif i < rightStart then
						w = 1
					else
						w = rs[rightEnd - i]
					end
					local at = blockStart + i + MARGIN
					if at >= 0 and at < capacity + 2 * MARGIN then
						buffer.writef32(o, at * 4, buffer.readf32(o, at * 4) + y * w)
					end
				end
			end
		end
		produced = center
		if produced >= capacity then
			break
		end
		if options.Yield and pi_ % 64 == 0 then
			options.Yield()
		end
	end
	local length = math.min(capacity, math.max(0, floor(produced)))
	if total then
		length = math.min(length, total)
	end
	-- Vorbis channel order -> the WAV / FLAC order (front L, R, centre, LFE, rear / side) the rest of AudioLab uses
	local ORDER = {
		[3] = { 1, 3, 2 },
		[5] = { 1, 3, 2, 4, 5 },
		[6] = { 1, 3, 2, 6, 4, 5 },
		[7] = { 1, 3, 2, 7, 6, 4, 5 },
		[8] = { 1, 3, 2, 8, 6, 7, 4, 5 },
	}
	local order = ORDER[channels]
	local signal = Signal.new(rate, channels, length)
	for c = 1, channels do
		local src = order and order[c] or c
		buffer.copy(signal.data[c], 0, acc[src], MARGIN * 4, length * 4)
	end
	return { signal = signal, format = { codec = "vorbis", sampleRate = rate, channels = channels, bitrate = bitrate } }
end

return Ogg
