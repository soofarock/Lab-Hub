--!native
--!optimize 2
-- WebP decoder: lossy (VP8) and lossless (VP8L) pictures, transparency (ALPH) and animations (ANIM / ANMF),
-- following libwebp (the same pixels as its decoder, fancy chroma upsampling included).
--
--   local image = Webp.decode(bytes)   -- bytes: buffer or string
--   image.width, image.height, image.data (RGBA buffer), image.hasAlpha
--   an animation also has image.frames = { { data = RGBA buffer (full canvas), delay = seconds } } and image.loop
--   Webp.isWebp(bytes); Webp.describe(bytes) -> "lossy WebP, 512x512" (for messages)

local band, bor, bxor, rshift, lshift = bit32.band, bit32.bor, bit32.bxor, bit32.rshift, bit32.lshift
local readu8, writeu8, readu16, readu32, writeu32 = buffer.readu8, buffer.writeu8, buffer.readu16, buffer.readu32, buffer.writeu32

local Webp = {}

local function fail(msg)
	error("WebP: " .. msg, 0)
end

-- long decodes give the server a breather now and then (Roblox only: standalone Luau has no task library)
local lastYield = os.clock()
local function breathe()
	if task and os.clock() - lastYield > 0.05 then
		task.wait()
		lastYield = os.clock()
	end
end

local COEFFS0 = "808080808080808080808080808080808080808080808080808080808080808080fd88feffe4db8080808080bd81f2ffe3d5ffdb8080806a7ee3fcd6d1ffff8080800162f8ffece2ffff808080b585eefeddeaff9a8080804e86caf7c6b4ffdb80808001b9f9fff3ff8080808080b896f7ffece080808080804d6ed8ffece680808080800165fbfff1ff8080808080aa8bf1fcecd1ffff8080802574c4f3e4ffffff80808001ccfefff5ff8080808080cfa0faffee8080808080806667e7ffd3ab80808080800198fcfff0ff8080808080b187f3ffeae180808080805081d3ffc2e080808080800101ff8080808080808080f601ff8080808080808080ff80808080808080808080c623eddfc1bba2a0919b3e832dc6ddacb0dc9dfcdd01442f92d095a7dda2ffdf800195f1ffdde0ffff808080b88deafddedcffc78080805163b5f2b0bef9caffff800181e8fdd6c5f2c4ffff806379d2fac9c6ffca808080175ba3f2aabbf7d2ffff8001c8f6ffeaff80808080806db2f1ffe7f5ffff8080802c82c9fdcdc0ffff8080800184effbdbd1ffa58080805e88e1fbdabeffff8080801664aef5baa1ffc780808001b6f9ffe8eb80808080807c8ff1ffe3ea8080808080234db5fbc1d3ffcd808080019df7ffece7ffff808080798debffe1e3ffff8080802d63bcfbc3d9ffe08080800101fbffd5ff8080808080cb01f8ffff8080808080808901b1ffe0ff8080808080fd09f8fbcfd0ffc0808080af0de0f3c1b9f9c6ffff804911abdda1b3eca7ffea80015ff7fdd4b7ffff808080ef5af4fad3d1ffff8080809b4dc3f8bcc3ffff8080800118effbdadbffcd808080c933dbffc4ba8080808080452ebeefc9daffe480808001bffbffff808080808080dfa5f9ffd5ff80808080808d7cf8ffff8080808080800110f8ffff808080808080be24e6ffecff80808080809501ff808080808080808001e2ff8080808080808080f7c0ff8080808080808080f080ff80808080808080800186fcffff808080808080d53efaffff808080808080375dff8080808080808080808080808080808080808080808080808080808080808080808080808080808080ca18d5ebbabfdca0f0afff7e26b6e8a9b8e4aeffbb803d2e8adb97b2f0aaffd8800170e6fac7bff79fffff80a66de4fcd3d7ffae808080274da2e8acb4f5b2ffff800134dcf6c6c7f9dcffff807c4abff3b7c1faddffff80184782db9aaaf3b6ffff8001b6e1f9dbf0ffe08080809596e2fcd8cdffab8080801c6caaf2b7c2fedfffff800151e6fccccbffc08080807b66d1f7bcc4ffe9808080145f99f3a4adffcb80808001def8ffd8d58080808080a8aff6fcebcdffff8080802f74d7ffd3d4ffff8080800179ecfdd4d6ffff8080808d54d5fcc9caffdb8080802a50a0f0a2b9ffcd8080800101ff8080808080808080f401ff8080808080808080ee01ff8080808080808080"
local COEFFS_UPDATE = "ffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffb0f6ffffffffffffffffffdff1fcfffffffffffffffff9fdfdfffffffffffffffffff4fcffffffffffffffffeafefefffffffffffffffffdfffffffffffffffffffffff6feffffffffffffffffeffdfefffffffffffffffffefffefffffffffffffffffff8fefffffffffffffffffbfffefffffffffffffffffffffffffffffffffffffffffdfefffffffffffffffffbfefefffffffffffffffffefffefffffffffffffffffffefdfffefffffffffffffafffefffefffffffffffffeffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffd9ffffffffffffffffffffe1fcf1fdfffffeffffffffeafaf1fafdfffdfefffffffffeffffffffffffffffffdffefeffffffffffffffffeefdfefefffffffffffffffff8fefffffffffffffffff9fefffffffffffffffffffffffffffffffffffffffffffdfffffffffffffffffff7fefffffffffffffffffffffffffffffffffffffffffffdfefffffffffffffffffcfffffffffffffffffffffffffffffffffffffffffffffefefffffffffffffffffdfffffffffffffffffffffffffffffffffffffffffffffefdfffffffffffffffffafffffffffffffffffffffeffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffbafbfaffffffffffffffffeafbf4fefffffffffffffffbfbf3fdfefffefffffffffffdfeffffffffffffffffecfdfefffffffffffffffffbfdfdfefefffffffffffffffefefffffffffffffffffefefefffffffffffffffffffffffffffffffffffffffffefffffffffffffffffffefefffffffffffffffffffefffffffffffffffffffffffffffffffffffffffffffefffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffff8fffffffffffffffffffffafefcfefffffffffffffff8fef9fdfffffffffffffffffdfdfffffffffffffffff6fdfdfffffffffffffffffcfefbfefefffffffffffffffefcfffffffffffffffff8fefdfffffffffffffffffdfffefefffffffffffffffffbfefffffffffffffffff5fbfefffffffffffffffffdfdfefffffffffffffffffffbfdfffffffffffffffffcfdfefffffffffffffffffffefffffffffffffffffffffcfffffffffffffffffff9fffefffffffffffffffffffffefffffffffffffffffffffdfffffffffffffffffafffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffeffffffffffffffffffffffffffffffffffffffffff"
local BMODES = "e7783059737178987098b3407eaa762e465faf458f505552489b67383a0aabdabd110d98721a11a32cc3150aad791850c31a3e2c405590470a26abd590221aaa2e371388a021ce473f14087272d00c09e251280b60b6541d102486b7598962656aa59448bb64829d6f204b504266a7634a3e28ea80293509b2f18d1a086b4a2b1a9249a631179d412669a033341f7380684f0c1bd9ff5711075744472c72330fba172f290e6eb6b71511c2422d1966c5bd171216585893962a2e2dc4cd2b61b775552623b33d2735c8571a152be8ab3822336872661d5d4d271c55ab3aa55a6240221674ce17222ba6496b36201a3301512b1f44196a1640ab24e1722213156684bc104c7c3e124e5f5539323033c165239fd76f592e6f3c941facdbe415126f70714d55b3ff267872282a01c4f5d10a196d582b1d8ca6d5252b9a3d3f1e9b432d4401d16450082b9a01331a478e4e4e10ff8022c5ab29280566d3b70401dd333211a8d1c01719528a1f24ab1ba6262ce543573aa952731a3bb33f3b5ab43ba65d499a282815748fd12227af2f0f10b722df312db72e1121b706620f20b7392e16188001361125412049731c801780cd2803097333c01206df572509733b4d40152f68372cda09363582e2405a46cd2829171a39363970b8052926a6d51e221a8598740a2086271335dd1a722049ff1f0941ea020f0176494b200c33c0ffa02b33581f2343665537ba553815176f3bcd2d25c03726467c49660122627d622a58685575af525f543559806471652d4b4f7b2f338051ab0139110547663935293126210d7939491a0155290a438a4d6e5a2f727315020a66ffa61706651d100a558065c41a39120a6666d522142b75140f24a38044011a663d472522351ff3c0453c472649771cde25442d8022012f0bf5ab3e1113469255373e46252b259a64a355a0013f095c881c4020c9554b0f090940ffb8771056061c0540ff19f8013808118489ff3774803a0f145287391a7928a4321f899a851923da33672c83837b1f069e5628408794e02db780161a1183f09a0e01d12d10155b40de0701c53815279b3c8a1766d5530c0d36c0ff442f1c551a555580802092ab120b073f90ab0404f6231b0a92aeab0c1a80be502363b4507e362d557e2f57b033291420654b808b769274805538290fb0ec5525093e471e117776ff11128a65263c8a37462b1a8e9224131eabff611b148a2d3d3edb0151bc4020291475978e1415a370130c3dc380300418"
local DC_TABLE = { 4, 5, 6, 7, 8, 9, 10, 10, 11, 12, 13, 14, 15, 16, 17, 17, 18, 19, 20, 20, 21, 21, 22, 22, 23, 23, 24, 25, 25, 26, 27, 28, 29, 30, 31, 32, 33, 34, 35, 36, 37, 37, 38, 39, 40, 41, 42, 43, 44, 45, 46, 46, 47, 48, 49, 50, 51, 52, 53, 54, 55, 56, 57, 58, 59, 60, 61, 62, 63, 64, 65, 66, 67, 68, 69, 70, 71, 72, 73, 74, 75, 76, 76, 77, 78, 79, 80, 81, 82, 83, 84, 85, 86, 87, 88, 89, 91, 93, 95, 96, 98, 100, 101, 102, 104, 106, 108, 110, 112, 114, 116, 118, 122, 124, 126, 128, 130, 132, 134, 136, 138, 140, 143, 145, 148, 151, 154, 157 }
local AC_TABLE = { 4, 5, 6, 7, 8, 9, 10, 11, 12, 13, 14, 15, 16, 17, 18, 19, 20, 21, 22, 23, 24, 25, 26, 27, 28, 29, 30, 31, 32, 33, 34, 35, 36, 37, 38, 39, 40, 41, 42, 43, 44, 45, 46, 47, 48, 49, 50, 51, 52, 53, 54, 55, 56, 57, 58, 60, 62, 64, 66, 68, 70, 72, 74, 76, 78, 80, 82, 84, 86, 88, 90, 92, 94, 96, 98, 100, 102, 104, 106, 108, 110, 112, 114, 116, 119, 122, 125, 128, 131, 134, 137, 140, 143, 146, 149, 152, 155, 158, 161, 164, 167, 170, 173, 177, 181, 185, 189, 193, 197, 201, 205, 209, 213, 217, 221, 225, 229, 234, 239, 245, 249, 254, 259, 264, 269, 274, 279, 284 }


local function bytesOf(hex)
	local t = table.create(#hex // 2)
	for i = 1, #hex // 2 do
		t[i] = tonumber(string.sub(hex, i * 2 - 1, i * 2), 16)
	end
	return t
end
local P_DEFAULT = bytesOf(COEFFS0)
local P_UPDATE = bytesOf(COEFFS_UPDATE)
local BMODE_P = bytesOf(BMODES)

------------------------------------------------------------------------------------------------------------------------
-- VP8L (lossless)

local CODE_LENGTH_ORDER = { 17, 18, 0, 1, 2, 3, 4, 5, 16, 6, 7, 8, 9, 10, 11, 12, 13, 14, 15 }
local CODE_TO_PLANE = {
	0x18, 0x07, 0x17, 0x19, 0x28, 0x06, 0x27, 0x29, 0x16, 0x1a, 0x26, 0x2a, 0x38, 0x05, 0x37, 0x39, 0x15, 0x1b, 0x36, 0x3a,
	0x25, 0x2b, 0x48, 0x04, 0x47, 0x49, 0x14, 0x1c, 0x35, 0x3b, 0x46, 0x4a, 0x24, 0x2c, 0x58, 0x45, 0x4b, 0x34, 0x3c, 0x03,
	0x57, 0x59, 0x13, 0x1d, 0x56, 0x5a, 0x23, 0x2d, 0x44, 0x4c, 0x55, 0x5b, 0x33, 0x3d, 0x68, 0x02, 0x67, 0x69, 0x12, 0x1e,
	0x66, 0x6a, 0x22, 0x2e, 0x54, 0x5c, 0x43, 0x4d, 0x65, 0x6b, 0x32, 0x3e, 0x78, 0x01, 0x77, 0x79, 0x53, 0x5d, 0x11, 0x1f,
	0x64, 0x6c, 0x42, 0x4e, 0x76, 0x7a, 0x21, 0x2f, 0x75, 0x7b, 0x31, 0x3f, 0x63, 0x6d, 0x52, 0x5e, 0x00, 0x74, 0x7c, 0x41,
	0x4f, 0x10, 0x20, 0x62, 0x6e, 0x30, 0x73, 0x7d, 0x51, 0x5f, 0x40, 0x72, 0x7e, 0x61, 0x6f, 0x50, 0x71, 0x7f, 0x60, 0x70,
}

local function subSample(size, bits)
	return rshift(size + lshift(1, bits) - 1, bits)
end

-- canonical Huffman code -> lookup table: 8-bit first level (entry = symbol * 16 + length), longer codes in second
-- level tables (entry = -(offset * 16 + bits)); a single symbol takes no bits
local function buildCode(lengths, count)
	local num, last, maxLen = 0, 0, 0
	local blCount = table.create(16, 0)
	for s = 0, count - 1 do
		local l = lengths[s]
		if l > 0 then
			num += 1
			last = s
			blCount[l] += 1
			if l > maxLen then
				maxLen = l
			end
		end
	end
	if num == 0 then
		fail("broken lossless data (an empty Huffman code)")
	end
	local t = table.create(256, 0)
	if num == 1 then
		for i = 1, 256 do
			t[i] = last * 16
		end
		return t
	end
	local left = 1
	for l = 1, 15 do
		left = left * 2 - blCount[l]
		if left < 0 then
			fail("broken lossless data (an over-full Huffman code)")
		end
	end
	if left ~= 0 then
		fail("broken lossless data (an incomplete Huffman code)")
	end
	local nextCode = table.create(16, 0)
	local code = 0
	for l = 1, 15 do
		code = (code + (l > 1 and blCount[l - 1] or 0)) * 2
		nextCode[l] = code
	end
	local revs = table.create(count, 0)
	local subMax = {}
	for s = 0, count - 1 do
		local l = lengths[s]
		if l > 0 then
			local c = nextCode[l]
			nextCode[l] = c + 1
			local r = 0
			for _ = 1, l do
				r = r * 2 + band(c, 1)
				c = rshift(c, 1)
			end
			revs[s + 1] = r
			if l > 8 then
				local pre = band(r, 255)
				if (subMax[pre] or 0) < l - 8 then
					subMax[pre] = l - 8
				end
			end
		end
	end
	-- second level tables
	local offset = 256
	local subOff = {}
	for pre = 0, 255 do
		local sb = subMax[pre]
		if sb then
			subOff[pre] = offset
			t[pre + 1] = -(offset * 16 + sb)
			for i = offset + 1, offset + lshift(1, sb) do
				t[i] = false
			end
			offset += lshift(1, sb)
		end
	end
	for s = 0, count - 1 do
		local l = lengths[s]
		if l > 0 then
			local r = revs[s + 1]
			if l <= 8 then
				local step = lshift(1, l)
				for i = r, 255, step do
					t[i + 1] = s * 16 + l
				end
			else
				local pre = band(r, 255)
				local sb = subMax[pre]
				local off = subOff[pre]
				local step = lshift(1, l - 8)
				for i = rshift(r, 8), lshift(1, sb) - 1, step do
					t[off + i + 1] = s * 16 + (l - 8)
				end
			end
		end
	end
	return t
end

-- decode a VP8L image stream (the bits after the 5-byte header, or an ALPH chunk's) into ARGB words
local function decodeLossless(b, pos, stop, width, height)
	local acc, nb = 0, 0
	local over = 0
	local function fill()
		while nb <= 24 do
			local byte = 0
			if pos < stop then
				byte = readu8(b, pos)
			else
				over += 1
			end
			pos += 1
			acc += lshift(byte, nb)
			nb += 8
		end
	end
	local function read(k)
		if nb < k then
			fill()
		end
		local v = band(acc, lshift(1, k) - 1)
		acc = rshift(acc, k)
		nb -= k
		return v
	end
	local function readSym(t)
		if nb < 15 then
			fill()
		end
		local e = t[band(acc, 255) + 1]
		if e >= 0 then
			local l = band(e, 15)
			acc = rshift(acc, l)
			nb -= l
			return rshift(e, 4)
		end
		e = -e
		acc = rshift(acc, 8)
		nb -= 8
		local e2 = t[rshift(e, 4) + band(acc, lshift(1, band(e, 15)) - 1) + 1]
		if not e2 then
			fail("broken lossless data (an unknown Huffman code)")
		end
		local l = band(e2, 15)
		acc = rshift(acc, l)
		nb -= l
		return rshift(e2, 4)
	end
	local function readCode(alphabet)
		local lengths = table.create(alphabet, 0)
		lengths[0] = 0
		if read(1) == 1 then
			local two = read(1) == 1
			local s = read(read(1) == 0 and 1 or 8)
			if s < alphabet then
				lengths[s] = 1
			end
			if two then
				s = read(8)
				if s < alphabet then
					lengths[s] = 1
				end
			end
		else
			local cl = table.create(19, 0)
			cl[0] = 0
			for i = 1, read(4) + 4 do
				cl[CODE_LENGTH_ORDER[i]] = read(3)
			end
			local clt = buildCode(cl, 19)
			local maxSymbol = alphabet
			if read(1) == 1 then
				maxSymbol = 2 + read(2 + 2 * read(3))
				if maxSymbol > alphabet then
					fail("broken lossless data (too many code lengths)")
				end
			end
			local sym, prev = 0, 8
			while sym < alphabet do
				if maxSymbol == 0 then
					break
				end
				maxSymbol -= 1
				local c = readSym(clt)
				if c < 16 then
					lengths[sym] = c
					sym += 1
					if c ~= 0 then
						prev = c
					end
				else
					local rep, v
					if c == 16 then
						rep, v = read(2) + 3, prev
					elseif c == 17 then
						rep, v = read(3) + 3, 0
					else
						rep, v = read(7) + 11, 0
					end
					if sym + rep > alphabet then
						fail("broken lossless data (code lengths run past the end)")
					end
					for _ = 1, rep do
						lengths[sym] = v
						sym += 1
					end
				end
			end
		end
		return buildCode(lengths, alphabet)
	end

	local decodeStream
	-- the pixels of one entropy-coded image
	local function decodePixels(xs, ys, level0)
		local cacheBits = 0
		if read(1) == 1 then
			cacheBits = read(4)
			if cacheBits < 1 or cacheBits > 11 then
				fail("broken lossless data (bad colour cache size)")
			end
		end
		local metaBits, meta, metaXs = 0, nil, 0
		local numGroups = 1
		if level0 and read(1) == 1 then
			metaBits = read(3) + 2
			metaXs = subSample(xs, metaBits)
			local mys = subSample(ys, metaBits)
			local img = decodeStream(metaXs, mys, false)
			meta = table.create(metaXs * mys, 0)
			for i = 0, metaXs * mys - 1 do
				local g = band(rshift(readu32(img, i * 4), 8), 0xffff)
				meta[i + 1] = g
				if g + 1 > numGroups then
					numGroups = g + 1
				end
			end
		end
		local cacheSize = cacheBits > 0 and lshift(1, cacheBits) or 0
		local groups = table.create(numGroups)
		for g = 1, numGroups do
			groups[g] = { readCode(280 + cacheSize), readCode(256), readCode(256), readCode(256), readCode(40) }
		end
		local cache = cacheSize > 0 and table.create(cacheSize, 0) or nil
		local cacheShift = 32 - cacheBits
		local total = xs * ys
		local data = buffer.create(total * 4)
		local mask = metaBits > 0 and lshift(1, metaBits) - 1 or -1
		local grp = groups[1]
		local G, R, B, A, D = grp[1], grp[2], grp[3], grp[4], grp[5]
		local function pick(x, y)
			grp = groups[meta[rshift(y, metaBits) * metaXs + rshift(x, metaBits) + 1] + 1]
			G, R, B, A, D = grp[1], grp[2], grp[3], grp[4], grp[5]
		end
		local p, x, y = 0, 0, 0
		while p < total do
			if meta and band(x, mask) == 0 then
				pick(x, y)
			end
			local g = readSym(G)
			if g < 256 then
				local r = readSym(R)
				local bl = readSym(B)
				local a = readSym(A)
				local argb = a * 16777216 + r * 65536 + g * 256 + bl
				writeu32(data, p * 4, argb)
				if cache then
					local lo, hi = band(argb, 0xffff), rshift(argb, 16)
					local h = (lo * 0xa7bd + ((lo * 0x1e35 + hi * 0xa7bd) % 65536) * 65536) % 4294967296
					cache[rshift(h, cacheShift) + 1] = argb
				end
				p += 1
				x += 1
				if x == xs then
					x = 0
					y += 1
				end
			elseif g < 280 then
				local ls = g - 256
				local len
				if ls < 4 then
					len = ls + 1
				else
					local eb = rshift(ls - 2, 1)
					len = lshift(2 + band(ls, 1), eb) + read(eb) + 1
				end
				local ds = readSym(D)
				local dcode
				if ds < 4 then
					dcode = ds + 1
				else
					local eb = rshift(ds - 2, 1)
					dcode = lshift(2 + band(ds, 1), eb) + read(eb) + 1
				end
				local dist
				if dcode > 120 then
					dist = dcode - 120
				else
					local c = CODE_TO_PLANE[dcode]
					dist = rshift(c, 4) * xs + (8 - band(c, 15))
					if dist < 1 then
						dist = 1
					end
				end
				if dist > p or p + len > total then
					fail("broken lossless data (a copy from outside the picture)")
				end
				for i = p, p + len - 1 do
					local argb = readu32(data, (i - dist) * 4)
					writeu32(data, i * 4, argb)
					if cache then
						local lo, hi = band(argb, 0xffff), rshift(argb, 16)
						local h = (lo * 0xa7bd + ((lo * 0x1e35 + hi * 0xa7bd) % 65536) * 65536) % 4294967296
						cache[rshift(h, cacheShift) + 1] = argb
					end
				end
				p += len
				x += len
				while x >= xs do
					x -= xs
					y += 1
				end
				if meta and p < total then
					pick(x, y)
				end
			else
				if not cache then
					fail("broken lossless data (a colour cache code without a cache)")
				end
				local argb = cache[g - 280 + 1]
				writeu32(data, p * 4, argb)
				local lo, hi = band(argb, 0xffff), rshift(argb, 16)
				local h = (lo * 0xa7bd + ((lo * 0x1e35 + hi * 0xa7bd) % 65536) * 65536) % 4294967296
				cache[rshift(h, cacheShift) + 1] = argb
				p += 1
				x += 1
				if x == xs then
					x = 0
					y += 1
				end
			end
			if over > 8 then
				fail("the lossless picture data ends early (the file is cut off)")
			end
			if band(p, 4095) == 0 then
				breathe()
			end
		end
		return data
	end

	-- ARGB helpers for the predictor transform
	local function avg2(a, c)
		return rshift(band(bxor(a, c), 0xfefefefe), 1) + band(a, c)
	end
	local function clip255(v)
		return v < 0 and 0 or (v > 255 and 255 or v)
	end
	local function addSubFull(a, c, d)
		local out = 0
		for sh = 24, 0, -8 do
			out = out * 256 + clip255(band(rshift(a, sh), 255) + band(rshift(c, sh), 255) - band(rshift(d, sh), 255))
		end
		return out
	end
	local function addSubHalf(a, c, d)
		local ave = avg2(a, c)
		local out = 0
		for sh = 24, 0, -8 do
			local x = band(rshift(ave, sh), 255)
			local diff = x - band(rshift(d, sh), 255)
			local half = diff >= 0 and diff // 2 or -((-diff) // 2) -- C division truncates
			out = out * 256 + clip255(x + half)
		end
		return out
	end
	local function select(t, l, tl) -- libwebp Select(a = top, b = left, c = top-left)
		local s = 0
		for sh = 24, 0, -8 do
			local ta, la, ca = band(rshift(t, sh), 255), band(rshift(l, sh), 255), band(rshift(tl, sh), 255)
			s += math.abs(la - ca) - math.abs(ta - ca)
		end
		return s <= 0 and t or l
	end

	local function inversePredictor(tr, data, w, h)
		local bits = tr.bits
		local tw = subSample(w, bits)
		local modes = tr.data
		for y = 0, h - 1 do
			local row = y * w
			breathe()
			for x = 0, w - 1 do
				local i = (row + x) * 4
				local pred
				if y == 0 then
					pred = x == 0 and 0xff000000 or readu32(data, i - 4)
				elseif x == 0 then
					pred = readu32(data, i - w * 4)
				else
					local mode = band(rshift(readu32(modes, (rshift(y, bits) * tw + rshift(x, bits)) * 4), 8), 15)
					local up = i - w * 4
					if mode == 0 or mode >= 14 then
						pred = 0xff000000
					elseif mode == 1 then
						pred = readu32(data, i - 4)
					elseif mode == 2 then
						pred = readu32(data, up)
					elseif mode == 3 then
						pred = readu32(data, up + 4)
					elseif mode == 4 then
						pred = readu32(data, up - 4)
					elseif mode == 5 then
						pred = avg2(avg2(readu32(data, i - 4), readu32(data, up + 4)), readu32(data, up))
					elseif mode == 6 then
						pred = avg2(readu32(data, i - 4), readu32(data, up - 4))
					elseif mode == 7 then
						pred = avg2(readu32(data, i - 4), readu32(data, up))
					elseif mode == 8 then
						pred = avg2(readu32(data, up - 4), readu32(data, up))
					elseif mode == 9 then
						pred = avg2(readu32(data, up), readu32(data, up + 4))
					elseif mode == 10 then
						pred = avg2(avg2(readu32(data, i - 4), readu32(data, up - 4)), avg2(readu32(data, up), readu32(data, up + 4)))
					elseif mode == 11 then
						pred = select(readu32(data, up), readu32(data, i - 4), readu32(data, up - 4))
					elseif mode == 12 then
						pred = addSubFull(readu32(data, i - 4), readu32(data, up), readu32(data, up - 4))
					else
						pred = addSubHalf(readu32(data, i - 4), readu32(data, up), readu32(data, up - 4))
					end
				end
				local v = readu32(data, i)
				writeu32(data, i, bor(band(band(v, 0xff00ff00) + band(pred, 0xff00ff00), 0xff00ff00), band(band(v, 0x00ff00ff) + band(pred, 0x00ff00ff), 0x00ff00ff)))
			end
		end
	end

	local function s8(v)
		return v >= 128 and v - 256 or v
	end
	local function inverseColor(tr, data, w, h)
		local bits = tr.bits
		local tw = subSample(w, bits)
		for y = 0, h - 1 do
			for x = 0, w - 1 do
				local m = readu32(tr.data, (rshift(y, bits) * tw + rshift(x, bits)) * 4)
				local g2r, g2b, r2b = s8(band(m, 255)), s8(band(rshift(m, 8), 255)), s8(band(rshift(m, 16), 255))
				local i = (y * w + x) * 4
				local argb = readu32(data, i)
				local green = s8(band(rshift(argb, 8), 255))
				local red = band(band(rshift(argb, 16), 255) + (g2r * green) // 32, 255)
				local blue = band(band(argb, 255) + (g2b * green) // 32 + (r2b * s8(red)) // 32, 255)
				writeu32(data, i, band(argb, 0xff00ff00) + red * 65536 + blue)
			end
		end
	end

	local function inverseSubtractGreen(data, n)
		for i = 0, n - 1 do
			local argb = readu32(data, i * 4)
			local g = band(rshift(argb, 8), 255)
			local rb = band(band(argb, 0x00ff00ff) + g * 65536 + g, 0x00ff00ff)
			writeu32(data, i * 4, bor(band(argb, 0xff00ff00), rb))
		end
	end

	local function inverseIndexing(tr, data, w, h)
		local bits = tr.bits
		local map = tr.map
		if bits == 0 then
			for i = 0, w * h - 1 do
				writeu32(data, i * 4, readu32(map, band(rshift(readu32(data, i * 4), 8), 255) * 4))
			end
			return data
		end
		local iw = subSample(w, bits)
		local bpp = rshift(8, bits)
		local perMask = lshift(1, bits) - 1
		local m = lshift(1, bpp) - 1
		local out = buffer.create(w * h * 4)
		for y = 0, h - 1 do
			for x = 0, w - 1 do
				local packed = band(rshift(readu32(data, (y * iw + rshift(x, bits)) * 4), 8), 255)
				local idx = band(rshift(packed, band(x, perMask) * bpp), m)
				writeu32(out, (y * w + x) * 4, readu32(map, idx * 4))
			end
		end
		return out
	end

	decodeStream = function(xs, ys, level0)
		local transforms = {}
		if level0 then
			local seen = {}
			while read(1) == 1 do
				local ty = read(2)
				if seen[ty] then
					fail("broken lossless data (a transform used twice)")
				end
				seen[ty] = true
				local tr = { type = ty, xsize = xs }
				if ty == 0 or ty == 1 then
					tr.bits = read(3) + 2
					tr.data = decodeStream(subSample(xs, tr.bits), subSample(ys, tr.bits), false)
				elseif ty == 3 then
					local nc = read(8) + 1
					local bits = nc > 16 and 0 or (nc > 4 and 1 or (nc > 2 and 2 or 3))
					tr.bits = bits
					local pal = decodeStream(nc, 1, false)
					local final = lshift(1, rshift(8, bits))
					local map = buffer.create(final * 4)
					for i = 0, nc * 4 - 1 do
						local v = readu8(pal, i)
						if i >= 4 then
							v = band(v + readu8(map, i - 4), 255)
						end
						writeu8(map, i, v)
					end
					tr.map = map
					xs = subSample(xs, bits)
				end
				table.insert(transforms, tr)
			end
		end
		local data = decodePixels(xs, ys, level0)
		for i = #transforms, 1, -1 do
			local tr = transforms[i]
			if tr.type == 0 then
				inversePredictor(tr, data, tr.xsize, ys)
			elseif tr.type == 1 then
				inverseColor(tr, data, tr.xsize, ys)
			elseif tr.type == 2 then
				inverseSubtractGreen(data, tr.xsize * ys)
			else
				data = inverseIndexing(tr, data, tr.xsize, ys)
			end
		end
		return data
	end

	return decodeStream(width, height, true)
end

-- a whole VP8L chunk: header, then the image; returns ARGB words, width, height, alpha-used flag
local function decodeVP8L(b, pos, len)
	if len < 5 or readu8(b, pos) ~= 0x2f then
		fail("the lossless picture data is damaged (bad signature)")
	end
	local hdr = readu32(b, pos + 1)
	local w = band(hdr, 0x3fff) + 1
	local h = band(rshift(hdr, 14), 0x3fff) + 1
	local alphaUsed = band(rshift(hdr, 28), 1) == 1
	if rshift(hdr, 29) ~= 0 then
		fail("unknown lossless version " .. rshift(hdr, 29))
	end
	return decodeLossless(b, pos + 5, pos + len, w, h), w, h, alphaUsed
end

------------------------------------------------------------------------------------------------------------------------
-- VP8 (lossy)

local NORM = table.create(255, 0) -- shifts that bring a range back to [128, 255]
for r = 1, 255 do
	local s = 0
	while lshift(r, s) < 128 do
		s += 1
	end
	NORM[r] = s
end

-- boolean entropy decoder over bytes [pos, stop); returns getBit(prob) -> 0 / 1 and an "over" counter
local function newBool(b, pos, stop)
	local function byteAt(i)
		if i < stop then
			return readu8(b, i)
		end
		return 0
	end
	local value = byteAt(pos) * 256 + byteAt(pos + 1)
	pos += 2
	local bits = 8
	local range = 255
	local state = { over = 0 }
	local function getBit(prob)
		local split = 1 + rshift((range - 1) * prob, 8)
		local big = lshift(split, bits)
		local bit
		if value >= big then
			range -= split
			value -= big
			bit = 1
		else
			range = split
			bit = 0
		end
		if range < 128 then
			local sh = NORM[range]
			range = lshift(range, sh)
			bits -= sh
			if bits < 0 then
				value = value * 16777216 + byteAt(pos) * 65536 + byteAt(pos + 1) * 256 + byteAt(pos + 2)
				pos += 3
				bits += 24
				if pos > stop + 3 then
					state.over = pos - stop
				end
			end
		end
		return bit
	end
	state.get = getBit
	return state
end
local function getValue(get, n)
	local v = 0
	for _ = 1, n do
		v = v * 2 + get(128)
	end
	return v
end
local function getSigned(get, n)
	local v = getValue(get, n)
	return get(128) == 1 and -v or v
end
local function optSigned(get, n)
	if get(128) == 1 then
		return getSigned(get, n)
	end
	return 0
end

local KBANDS = { [0] = 0, 1, 2, 3, 6, 4, 5, 6, 6, 6, 6, 6, 6, 6, 6, 7, 0 }
local ZIGZAG = { [0] = 0, 1, 4, 8, 5, 2, 3, 6, 9, 12, 13, 10, 7, 11, 14, 15 }
local CAT = { { 173, 148, 140 }, { 176, 155, 140, 135 }, { 180, 157, 141, 134, 130 }, { 254, 254, 243, 230, 196, 177, 153, 140, 133, 130, 129 } }

local BPS = 32
local Y_OFF = BPS + 8
local U_OFF = Y_OFF + BPS * 16 + BPS
local V_OFF = U_OFF + 16

local function clip8(v)
	return v < 0 and 0 or (v > 255 and 255 or v)
end

-- 4x4 intra predictors on the work buffer (libwebp's mode numbers)
local function avg3(a, c, d)
	return rshift(a + 2 * c + d + 2, 2)
end
local function avg2b(a, c)
	return rshift(a + c + 1, 1)
end
local function pred4(wb, dst, mode)
	local function T(i)
		return readu8(wb, dst - BPS + i)
	end
	local function L(j)
		return readu8(wb, dst - 1 + j * BPS)
	end
	local function S(x, y, v)
		writeu8(wb, dst + x + y * BPS, v)
	end
	if mode == 0 then -- DC
		local dc = 4
		for i = 0, 3 do
			dc += T(i) + L(i)
		end
		dc = rshift(dc, 3)
		for y = 0, 3 do
			for x = 0, 3 do
				S(x, y, dc)
			end
		end
	elseif mode == 1 then -- TM
		local tl = T(-1)
		for y = 0, 3 do
			local l = L(y)
			for x = 0, 3 do
				S(x, y, clip8(l + T(x) - tl))
			end
		end
	elseif mode == 2 then -- VE
		local v0, v1, v2, v3 = avg3(T(-1), T(0), T(1)), avg3(T(0), T(1), T(2)), avg3(T(1), T(2), T(3)), avg3(T(2), T(3), T(4))
		for y = 0, 3 do
			S(0, y, v0)
			S(1, y, v1)
			S(2, y, v2)
			S(3, y, v3)
		end
	elseif mode == 3 then -- HE
		local A, B, C, D, E = T(-1), L(0), L(1), L(2), L(3)
		local r = { avg3(A, B, C), avg3(B, C, D), avg3(C, D, E), avg3(D, E, E) }
		for y = 0, 3 do
			for x = 0, 3 do
				S(x, y, r[y + 1])
			end
		end
	elseif mode == 4 then -- RD
		local I, J, K, Lv, X = L(0), L(1), L(2), L(3), T(-1)
		local A, B, C, D = T(0), T(1), T(2), T(3)
		S(0, 3, avg3(J, K, Lv))
		local v = avg3(I, J, K)
		S(1, 3, v)
		S(0, 2, v)
		v = avg3(X, I, J)
		S(2, 3, v)
		S(1, 2, v)
		S(0, 1, v)
		v = avg3(A, X, I)
		S(3, 3, v)
		S(2, 2, v)
		S(1, 1, v)
		S(0, 0, v)
		v = avg3(B, A, X)
		S(3, 2, v)
		S(2, 1, v)
		S(1, 0, v)
		v = avg3(C, B, A)
		S(3, 1, v)
		S(2, 0, v)
		S(3, 0, avg3(D, C, B))
	elseif mode == 5 then -- VR
		local I, J, K, X = L(0), L(1), L(2), T(-1)
		local A, B, C, D = T(0), T(1), T(2), T(3)
		local v = avg2b(X, A)
		S(0, 0, v)
		S(1, 2, v)
		v = avg2b(A, B)
		S(1, 0, v)
		S(2, 2, v)
		v = avg2b(B, C)
		S(2, 0, v)
		S(3, 2, v)
		S(3, 0, avg2b(C, D))
		S(0, 3, avg3(K, J, I))
		S(0, 2, avg3(J, I, X))
		v = avg3(I, X, A)
		S(0, 1, v)
		S(1, 3, v)
		v = avg3(X, A, B)
		S(1, 1, v)
		S(2, 3, v)
		v = avg3(A, B, C)
		S(2, 1, v)
		S(3, 3, v)
		S(3, 1, avg3(B, C, D))
	elseif mode == 6 then -- LD
		local A, B, C, D, E, F, G, H = T(0), T(1), T(2), T(3), T(4), T(5), T(6), T(7)
		S(0, 0, avg3(A, B, C))
		local v = avg3(B, C, D)
		S(1, 0, v)
		S(0, 1, v)
		v = avg3(C, D, E)
		S(2, 0, v)
		S(1, 1, v)
		S(0, 2, v)
		v = avg3(D, E, F)
		S(3, 0, v)
		S(2, 1, v)
		S(1, 2, v)
		S(0, 3, v)
		v = avg3(E, F, G)
		S(3, 1, v)
		S(2, 2, v)
		S(1, 3, v)
		v = avg3(F, G, H)
		S(3, 2, v)
		S(2, 3, v)
		S(3, 3, avg3(G, H, H))
	elseif mode == 7 then -- VL
		local A, B, C, D, E, F, G, H = T(0), T(1), T(2), T(3), T(4), T(5), T(6), T(7)
		S(0, 0, avg2b(A, B))
		local v = avg2b(B, C)
		S(1, 0, v)
		S(0, 2, v)
		v = avg2b(C, D)
		S(2, 0, v)
		S(1, 2, v)
		v = avg2b(D, E)
		S(3, 0, v)
		S(2, 2, v)
		S(0, 1, avg3(A, B, C))
		v = avg3(B, C, D)
		S(1, 1, v)
		S(0, 3, v)
		v = avg3(C, D, E)
		S(2, 1, v)
		S(1, 3, v)
		v = avg3(D, E, F)
		S(3, 1, v)
		S(2, 3, v)
		S(3, 2, avg3(E, F, G))
		S(3, 3, avg3(F, G, H))
	elseif mode == 8 then -- HD
		local I, J, K, Lv, X = L(0), L(1), L(2), L(3), T(-1)
		local A, B, C = T(0), T(1), T(2)
		local v = avg2b(I, X)
		S(0, 0, v)
		S(2, 1, v)
		v = avg2b(J, I)
		S(0, 1, v)
		S(2, 2, v)
		v = avg2b(K, J)
		S(0, 2, v)
		S(2, 3, v)
		S(0, 3, avg2b(Lv, K))
		S(3, 0, avg3(A, B, C))
		S(2, 0, avg3(X, A, B))
		v = avg3(I, X, A)
		S(1, 0, v)
		S(3, 1, v)
		v = avg3(J, I, X)
		S(1, 1, v)
		S(3, 2, v)
		v = avg3(K, J, I)
		S(1, 2, v)
		S(3, 3, v)
		S(1, 3, avg3(Lv, K, J))
	else -- HU
		local I, J, K, Lv = L(0), L(1), L(2), L(3)
		S(0, 0, avg2b(I, J))
		local v = avg2b(J, K)
		S(2, 0, v)
		S(0, 1, v)
		v = avg2b(K, Lv)
		S(2, 1, v)
		S(0, 2, v)
		S(1, 0, avg3(I, J, K))
		v = avg3(J, K, Lv)
		S(3, 0, v)
		S(1, 1, v)
		v = avg3(K, Lv, Lv)
		S(3, 1, v)
		S(1, 2, v)
		S(3, 2, Lv)
		S(2, 2, Lv)
		S(0, 3, Lv)
		S(1, 3, Lv)
		S(2, 3, Lv)
		S(3, 3, Lv)
	end
end

-- 16x16 (size 16) and 8x8 chroma (size 8) predictors; mode: 0 DC, 1 TM, 2 V, 3 H, 4 DC no top, 5 DC no left,
-- 6 DC with neither
local function predBig(wb, dst, size, mode)
	local fillv
	if mode == 0 or mode == 4 or mode == 5 then
		local sum, n = 0, 0
		if mode ~= 4 then -- top
			for i = 0, size - 1 do
				sum += readu8(wb, dst - BPS + i)
			end
			n += size
		end
		if mode ~= 5 then -- left
			for j = 0, size - 1 do
				sum += readu8(wb, dst - 1 + j * BPS)
			end
			n += size
		end
		fillv = (sum + n // 2) // n
	elseif mode == 6 then
		fillv = 0x80
	end
	if fillv then
		for y = 0, size - 1 do
			for x = 0, size - 1 do
				writeu8(wb, dst + x + y * BPS, fillv)
			end
		end
	elseif mode == 1 then
		local tl = readu8(wb, dst - BPS - 1)
		for y = 0, size - 1 do
			local l = readu8(wb, dst - 1 + y * BPS) - tl
			for x = 0, size - 1 do
				writeu8(wb, dst + x + y * BPS, clip8(l + readu8(wb, dst - BPS + x)))
			end
		end
	elseif mode == 2 then
		for y = 0, size - 1 do
			for x = 0, size - 1 do
				writeu8(wb, dst + x + y * BPS, readu8(wb, dst - BPS + x))
			end
		end
	else
		for y = 0, size - 1 do
			local l = readu8(wb, dst - 1 + y * BPS)
			for x = 0, size - 1 do
				writeu8(wb, dst + x + y * BPS, l)
			end
		end
	end
end

local function mul1(a)
	return (a * 20091) // 65536 + a
end
local function mul2(a)
	return (a * 35468) // 65536
end
local tmpT = table.create(16, 0)
-- inverse DCT of coefficients C[base + 1 .. base + 16] added to the 4x4 block at dst (skipped when all zero)
local function idct(C, base, wb, dst)
	local any = false
	for k = base + 1, base + 16 do
		if C[k] ~= 0 then
			any = true
			break
		end
	end
	if not any then
		return
	end
	for i = 0, 3 do
		local i0, i4, i8, i12 = C[base + i + 1], C[base + i + 5], C[base + i + 9], C[base + i + 13]
		local a, b = i0 + i8, i0 - i8
		local c = mul2(i4) - mul1(i12)
		local d = mul1(i4) + mul2(i12)
		tmpT[i * 4 + 1] = a + d
		tmpT[i * 4 + 2] = b + c
		tmpT[i * 4 + 3] = b - c
		tmpT[i * 4 + 4] = a - d
	end
	for i = 0, 3 do
		local dc = tmpT[i + 1] + 4
		local t8, t4, t12 = tmpT[i + 9], tmpT[i + 5], tmpT[i + 13]
		local a, b = dc + t8, dc - t8
		local c = mul2(t4) - mul1(t12)
		local d = mul1(t4) + mul2(t12)
		local o = dst + i * BPS
		writeu8(wb, o, clip8(readu8(wb, o) + (a + d) // 8))
		writeu8(wb, o + 1, clip8(readu8(wb, o + 1) + (b + c) // 8))
		writeu8(wb, o + 2, clip8(readu8(wb, o + 2) + (b - c) // 8))
		writeu8(wb, o + 3, clip8(readu8(wb, o + 3) + (a - d) // 8))
	end
end

-- loop filters on a plane
local function sclip1(v)
	return v < -128 and -128 or (v > 127 and 127 or v)
end
local function sclip2(v)
	return v < -16 and -16 or (v > 15 and 15 or v)
end
local abs = math.abs
local function doFilter2(P, p, hs)
	local p1, p0, q0, q1 = readu8(P, p - 2 * hs), readu8(P, p - hs), readu8(P, p), readu8(P, p + hs)
	local a = 3 * (q0 - p0) + sclip1(p1 - q1)
	local a1 = sclip2((a + 4) // 8)
	local a2 = sclip2((a + 3) // 8)
	writeu8(P, p - hs, clip8(p0 + a2))
	writeu8(P, p, clip8(q0 - a1))
end
local function doFilter4(P, p, hs)
	local p1, p0, q0, q1 = readu8(P, p - 2 * hs), readu8(P, p - hs), readu8(P, p), readu8(P, p + hs)
	local a = 3 * (q0 - p0)
	local a1 = sclip2((a + 4) // 8)
	local a2 = sclip2((a + 3) // 8)
	local a3 = (a1 + 1) // 2
	writeu8(P, p - 2 * hs, clip8(p1 + a3))
	writeu8(P, p - hs, clip8(p0 + a2))
	writeu8(P, p, clip8(q0 - a1))
	writeu8(P, p + hs, clip8(q1 - a3))
end
local function doFilter6(P, p, hs)
	local p2, p1, p0 = readu8(P, p - 3 * hs), readu8(P, p - 2 * hs), readu8(P, p - hs)
	local q0, q1, q2 = readu8(P, p), readu8(P, p + hs), readu8(P, p + 2 * hs)
	local a = sclip1(3 * (q0 - p0) + sclip1(p1 - q1))
	local a1 = (27 * a + 63) // 128
	local a2 = (18 * a + 63) // 128
	local a3 = (9 * a + 63) // 128
	writeu8(P, p - 3 * hs, clip8(p2 + a3))
	writeu8(P, p - 2 * hs, clip8(p1 + a2))
	writeu8(P, p - hs, clip8(p0 + a1))
	writeu8(P, p, clip8(q0 - a1))
	writeu8(P, p + hs, clip8(q1 - a2))
	writeu8(P, p + 2 * hs, clip8(q2 - a3))
end
local function filterLoop(P, p, hs, vs, size, thresh, ithresh, hevT, inner)
	local t2 = 2 * thresh + 1
	for _ = 1, size do
		local p3, p2, p1, p0 = readu8(P, p - 4 * hs), readu8(P, p - 3 * hs), readu8(P, p - 2 * hs), readu8(P, p - hs)
		local q0, q1, q2, q3 = readu8(P, p), readu8(P, p + hs), readu8(P, p + 2 * hs), readu8(P, p + 3 * hs)
		if 4 * abs(p0 - q0) + abs(p1 - q1) <= t2 and abs(p3 - p2) <= ithresh and abs(p2 - p1) <= ithresh
			and abs(p1 - p0) <= ithresh and abs(q3 - q2) <= ithresh and abs(q2 - q1) <= ithresh and abs(q1 - q0) <= ithresh then
			if abs(p1 - p0) > hevT or abs(q1 - q0) > hevT then
				doFilter2(P, p, hs)
			elseif inner then
				doFilter4(P, p, hs)
			else
				doFilter6(P, p, hs)
			end
		end
		p += vs
	end
end
local function simpleFilter(P, p, hs, vs, thresh)
	local t2 = 2 * thresh + 1
	for _ = 1, 16 do
		local p1, p0, q0, q1 = readu8(P, p - 2 * hs), readu8(P, p - hs), readu8(P, p), readu8(P, p + hs)
		if 4 * abs(p0 - q0) + abs(p1 - q1) <= t2 then
			doFilter2(P, p, hs)
		end
		p += vs
	end
end

-- decode a VP8 key frame; returns Y, U, V planes (strides yStride / uvStride), width, height
local function decodeVP8(b, pos, len)
	if len < 10 then
		fail("the lossy picture data is too short")
	end
	local tag = readu8(b, pos) + readu8(b, pos + 1) * 256 + readu8(b, pos + 2) * 65536
	if band(tag, 1) ~= 0 then
		fail("the lossy picture isn't a key frame")
	end
	if band(rshift(tag, 1), 7) > 3 then
		fail("unknown lossy picture profile")
	end
	local partLen = rshift(tag, 5)
	if readu8(b, pos + 3) ~= 0x9d or readu8(b, pos + 4) ~= 0x01 or readu8(b, pos + 5) ~= 0x2a then
		fail("the lossy picture data is damaged (bad start code)")
	end
	local width = band(readu16(b, pos + 6), 0x3fff)
	local height = band(readu16(b, pos + 8), 0x3fff)
	if width == 0 or height == 0 then
		fail("the lossy picture has no size")
	end
	local stop = pos + len
	local p = pos + 10
	if partLen > stop - p then
		fail("the lossy picture data ends early (the file is cut off)")
	end
	local br = newBool(b, p, p + partLen)
	local get = br.get
	get(128) -- colour space
	get(128) -- clamping type
	-- segments
	local useSegment = get(128) == 1
	local updateMap, absoluteDelta = false, true
	local segQ, segF = { 0, 0, 0, 0 }, { 0, 0, 0, 0 }
	local segProb = { 255, 255, 255 }
	if useSegment then
		updateMap = get(128) == 1
		if get(128) == 1 then
			absoluteDelta = get(128) == 1
			for s = 1, 4 do
				segQ[s] = optSigned(get, 7)
			end
			for s = 1, 4 do
				segF[s] = optSigned(get, 6)
			end
		end
		if updateMap then
			for s = 1, 3 do
				segProb[s] = get(128) == 1 and getValue(get, 8) or 255
			end
		end
	end
	-- filter header
	local simple = get(128) == 1
	local level = getValue(get, 6)
	local sharpness = getValue(get, 3)
	local useLfDelta = get(128) == 1
	local refDelta, modeDelta = { 0, 0, 0, 0 }, { 0, 0, 0, 0 }
	if useLfDelta and get(128) == 1 then
		for i = 1, 4 do
			if get(128) == 1 then
				refDelta[i] = getSigned(get, 6)
			end
		end
		for i = 1, 4 do
			if get(128) == 1 then
				modeDelta[i] = getSigned(get, 6)
			end
		end
	end
	local filterType = level == 0 and 0 or (simple and 1 or 2)
	-- partitions
	local q = p + partLen
	local numParts = lshift(1, getValue(get, 2))
	local sizeLeft = stop - q - 3 * (numParts - 1)
	if sizeLeft < 0 then
		fail("the lossy picture data ends early (the file is cut off)")
	end
	local partStart = q + 3 * (numParts - 1)
	local parts = {}
	for i = 0, numParts - 2 do
		local ps = readu8(b, q + i * 3) + readu8(b, q + i * 3 + 1) * 256 + readu8(b, q + i * 3 + 2) * 65536
		if ps > sizeLeft then
			ps = sizeLeft
		end
		parts[i] = newBool(b, partStart, partStart + ps)
		partStart += ps
		sizeLeft -= ps
	end
	parts[numParts - 1] = newBool(b, partStart, partStart + sizeLeft)
	-- quantizers
	local baseQ = getValue(get, 7)
	local dqY1dc = optSigned(get, 4)
	local dqY2dc = optSigned(get, 4)
	local dqY2ac = optSigned(get, 4)
	local dqUVdc = optSigned(get, 4)
	local dqUVac = optSigned(get, 4)
	local function clipq(v, m)
		return v < 0 and 0 or (v > m and m or v)
	end
	local quant = {}
	for s = 1, 4 do
		local qv
		if useSegment then
			qv = segQ[s]
			if not absoluteDelta then
				qv += baseQ
			end
		else
			qv = baseQ
		end
		local m = {}
		m.y1dc = DC_TABLE[clipq(qv + dqY1dc, 127) + 1]
		m.y1ac = AC_TABLE[clipq(qv, 127) + 1]
		m.y2dc = DC_TABLE[clipq(qv + dqY2dc, 127) + 1] * 2
		m.y2ac = (AC_TABLE[clipq(qv + dqY2ac, 127) + 1] * 101581) // 65536
		if m.y2ac < 8 then
			m.y2ac = 8
		end
		m.uvdc = DC_TABLE[clipq(qv + dqUVdc, 117) + 1]
		m.uvac = AC_TABLE[clipq(qv + dqUVac, 127) + 1]
		quant[s] = m
	end
	get(128) -- refresh entropy probs (ignored)
	local P = table.create(1056, 0)
	for i = 1, 1056 do
		P[i] = get(P_UPDATE[i]) == 1 and getValue(get, 8) or P_DEFAULT[i]
	end
	local useSkip = get(128) == 1
	local skipP = useSkip and getValue(get, 8) or 0

	-- filter strengths per segment and per (i4x4 or not)
	local fstr = {}
	if filterType > 0 then
		for s = 1, 4 do
			local baseLevel
			if useSegment then
				baseLevel = segF[s]
				if not absoluteDelta then
					baseLevel += level
				end
			else
				baseLevel = level
			end
			for i4 = 0, 1 do
				local lv = baseLevel
				if useLfDelta then
					lv += refDelta[1]
					if i4 == 1 then
						lv += modeDelta[1]
					end
				end
				lv = lv < 0 and 0 or (lv > 63 and 63 or lv)
				local info = { limit = 0, ilevel = 0, hev = 0 }
				if lv > 0 then
					local il = lv
					if sharpness > 0 then
						if sharpness > 4 then
							il = rshift(il, 2)
						else
							il = rshift(il, 1)
						end
						if il > 9 - sharpness then
							il = 9 - sharpness
						end
					end
					if il < 1 then
						il = 1
					end
					info.ilevel = il
					info.limit = 2 * lv + il
					info.hev = lv >= 40 and 2 or (lv >= 15 and 1 or 0)
				end
				fstr[s * 2 + i4] = info
			end
		end
	end

	local mbw, mbh = rshift(width + 15, 4), rshift(height + 15, 4)
	local yStride, uvStride = mbw * 16, mbw * 8
	local Yp = buffer.create(yStride * mbh * 16)
	local Up = buffer.create(uvStride * mbh * 8)
	local Vp = buffer.create(uvStride * mbh * 8)
	local wb = buffer.create(BPS * 17 + BPS * 9)
	local topY = buffer.create(yStride)
	local topU = buffer.create(uvStride)
	local topV = buffer.create(uvStride)
	local intraT = table.create(4 * mbw, 0)
	local intraL = { 0, 0, 0, 0 }
	local nzT, nzDcT = table.create(mbw, 0), table.create(mbw, 0)
	local fLimit, fIlevel, fHev, fInner = {}, {}, {}, {}
	local C = table.create(384, 0)
	local dcIn = table.create(16, 0)
	local imodes = table.create(16, 0)
	local whtT = table.create(16, 0)

	-- coefficient tokens of one 4x4 block
	local function largeValue(tg, pi)
		local v
		if tg(P[pi + 3]) == 0 then
			if tg(P[pi + 4]) == 0 then
				v = 2
			else
				v = 3 + tg(P[pi + 5])
			end
		else
			if tg(P[pi + 6]) == 0 then
				if tg(P[pi + 7]) == 0 then
					v = 5 + tg(159)
				else
					v = 7 + 2 * tg(165)
					v += tg(145)
				end
			else
				local bit1 = tg(P[pi + 8])
				local bit0 = tg(P[pi + 9 + bit1])
				local cat = 2 * bit1 + bit0
				v = 0
				for _, pr in ipairs(CAT[cat + 1]) do
					v = v + v + tg(pr)
				end
				v += 3 + lshift(8, cat)
			end
		end
		return v
	end
	local function getCoeffs(tg, t, ctx, dq0, dq1, n, out, base)
		local pi = ((t * 8 + KBANDS[n]) * 3 + ctx) * 11 + 1
		while n < 16 do
			if tg(P[pi]) == 0 then
				return n
			end
			while tg(P[pi + 1]) == 0 do
				n += 1
				if n == 16 then
					return 16
				end
				pi = (t * 8 + KBANDS[n]) * 33 + 1
			end
			local v
			local nb = (t * 8 + KBANDS[n + 1]) * 3
			if tg(P[pi + 2]) == 0 then
				v = 1
				pi = (nb + 1) * 11 + 1
			else
				v = largeValue(tg, pi)
				pi = (nb + 2) * 11 + 1
			end
			if tg(128) == 1 then
				v = -v
			end
			out[base + ZIGZAG[n] + 1] = v * (n > 0 and dq1 or dq0)
			n += 1
		end
		return 16
	end

	local KSCAN = table.create(16, 0)
	for n = 0, 15 do
		KSCAN[n + 1] = (n % 4) * 4 + (n // 4) * 4 * BPS
	end

	for mby = 0, mbh - 1 do
		local tb = parts[band(mby, numParts - 1)]
		local tg = tb.get
		intraL[1], intraL[2], intraL[3], intraL[4] = 0, 0, 0, 0
		local nzL, nzDcL = 0, 0
		-- work buffer edges for this row
		for j = 0, 15 do
			writeu8(wb, Y_OFF + j * BPS - 1, 129)
		end
		for j = 0, 7 do
			writeu8(wb, U_OFF + j * BPS - 1, 129)
			writeu8(wb, V_OFF + j * BPS - 1, 129)
		end
		if mby > 0 then
			writeu8(wb, Y_OFF - 1 - BPS, 129)
			writeu8(wb, U_OFF - 1 - BPS, 129)
			writeu8(wb, V_OFF - 1 - BPS, 129)
		else
			buffer.fill(wb, Y_OFF - BPS - 1, 127, 21)
			buffer.fill(wb, U_OFF - BPS - 1, 127, 9)
			buffer.fill(wb, V_OFF - BPS - 1, 127, 9)
		end
		for mbx = 0, mbw - 1 do
			-- modes (first partition)
			local segment = 0
			if updateMap then
				if get(segProb[1]) == 0 then
					segment = get(segProb[2])
				else
					segment = get(segProb[3]) + 2
				end
			end
			local skip = useSkip and get(skipP) or 0
			local isI4 = get(145) == 0
			local ymode
			if not isI4 then
				if get(156) == 1 then
					ymode = get(128) == 1 and 1 or 3 -- TM : H
				else
					ymode = get(163) == 1 and 2 or 0 -- V : DC
				end
				for k = 1, 4 do
					intraT[mbx * 4 + k] = ymode
					intraL[k] = ymode
				end
			else
				for y = 0, 3 do
					local m = intraL[y + 1]
					for x = 0, 3 do
						local base = (intraT[mbx * 4 + x + 1] * 10 + m) * 9
						local function pr(i)
							return BMODE_P[base + i + 1]
						end
						if get(pr(0)) == 0 then
							m = 0
						elseif get(pr(1)) == 0 then
							m = 1
						elseif get(pr(2)) == 0 then
							m = 2
						elseif get(pr(3)) == 0 then
							if get(pr(4)) == 0 then
								m = 3
							else
								m = get(pr(5)) == 0 and 4 or 5
							end
						else
							if get(pr(6)) == 0 then
								m = 6
							elseif get(pr(7)) == 0 then
								m = 7
							else
								m = get(pr(8)) == 0 and 8 or 9
							end
						end
						intraT[mbx * 4 + x + 1] = m
						imodes[y * 4 + x + 1] = m
					end
					intraL[y + 1] = m
				end
			end
			local uvmode
			if get(142) == 0 then
				uvmode = 0
			elseif get(114) == 0 then
				uvmode = 2
			else
				uvmode = get(183) == 1 and 1 or 3
			end

			-- residuals (token partition)
			local qm = quant[segment + 1]
			for k = 1, 384 do
				C[k] = 0
			end
			local nonZero = false
			if skip == 0 then
				local first, acType
				if not isI4 then
					for k = 1, 16 do
						dcIn[k] = 0
					end
					local nz = getCoeffs(tg, 1, nzDcT[mbx + 1] + nzDcL, qm.y2dc, qm.y2ac, 0, dcIn, 0)
					local f = nz > 0 and 1 or 0
					nzDcT[mbx + 1] = f
					nzDcL = f
					-- inverse Walsh-Hadamard: the 16 blocks' DC
					for i = 0, 3 do
						local a0 = dcIn[i + 1] + dcIn[i + 13]
						local a1 = dcIn[i + 5] + dcIn[i + 9]
						local a2 = dcIn[i + 5] - dcIn[i + 9]
						local a3 = dcIn[i + 1] - dcIn[i + 13]
						whtT[i + 1] = a0 + a1
						whtT[i + 9] = a0 - a1
						whtT[i + 5] = a3 + a2
						whtT[i + 13] = a3 - a2
					end
					for i = 0, 3 do
						local dc = whtT[i * 4 + 1] + 3
						local a0 = dc + whtT[i * 4 + 4]
						local a1 = whtT[i * 4 + 2] + whtT[i * 4 + 3]
						local a2 = whtT[i * 4 + 2] - whtT[i * 4 + 3]
						local a3 = dc - whtT[i * 4 + 4]
						C[i * 64 + 1] = (a0 + a1) // 8
						C[i * 64 + 17] = (a3 + a2) // 8
						C[i * 64 + 33] = (a0 - a1) // 8
						C[i * 64 + 49] = (a3 - a2) // 8
					end
					first, acType = 1, 0
				else
					first, acType = 0, 3
				end
				local tnz = band(nzT[mbx + 1], 0x0f)
				local lnz = band(nzL, 0x0f)
				local blk = 0
				for _ = 0, 3 do
					local l = band(lnz, 1)
					for _ = 0, 3 do
						local ctx = l + band(tnz, 1)
						local nz = getCoeffs(tg, acType, ctx, qm.y1dc, qm.y1ac, first, C, blk)
						l = nz > first and 1 or 0
						tnz = bor(rshift(tnz, 1), lshift(l, 7))
						blk += 16
					end
					tnz = rshift(tnz, 4)
					lnz = bor(rshift(lnz, 1), lshift(l, 7))
				end
				local outT = tnz
				local outL = rshift(lnz, 4)
				for ch = 0, 2, 2 do
					tnz = band(rshift(nzT[mbx + 1], 4 + ch), 255)
					lnz = band(rshift(nzL, 4 + ch), 255)
					for _ = 0, 1 do
						local l = band(lnz, 1)
						for _ = 0, 1 do
							local ctx = l + band(tnz, 1)
							local nz = getCoeffs(tg, 2, ctx, qm.uvdc, qm.uvac, 0, C, blk)
							l = nz > 0 and 1 or 0
							tnz = bor(rshift(tnz, 1), lshift(l, 3))
							blk += 16
						end
						tnz = rshift(tnz, 2)
						lnz = bor(rshift(lnz, 1), lshift(l, 5))
					end
					outT = bor(outT, lshift(lshift(tnz, 4), ch))
					outL = bor(outL, lshift(band(lnz, 0xf0), ch))
				end
				nzT[mbx + 1] = band(outT, 255)
				nzL = band(outL, 255)
				for k = 1, 384 do
					if C[k] ~= 0 then
						nonZero = true
						break
					end
				end
			else
				nzT[mbx + 1] = 0
				nzL = 0
				if not isI4 then
					nzDcT[mbx + 1] = 0
					nzDcL = 0
				end
			end
			if filterType > 0 then
				local info = fstr[(segment + 1) * 2 + (isI4 and 1 or 0)]
				local mi = mby * mbw + mbx
				fLimit[mi] = info.limit
				fIlevel[mi] = info.ilevel
				fHev[mi] = info.hev
				fInner[mi] = isI4 or nonZero
			end

			-- reconstruct into the work buffer
			if mbx > 0 then
				for j = -1, 15 do
					buffer.copy(wb, Y_OFF + j * BPS - 4, wb, Y_OFF + j * BPS + 12, 4)
				end
				for j = -1, 7 do
					buffer.copy(wb, U_OFF + j * BPS - 4, wb, U_OFF + j * BPS + 4, 4)
					buffer.copy(wb, V_OFF + j * BPS - 4, wb, V_OFF + j * BPS + 4, 4)
				end
			end
			if mby > 0 then
				buffer.copy(wb, Y_OFF - BPS, topY, mbx * 16, 16)
				buffer.copy(wb, U_OFF - BPS, topU, mbx * 8, 8)
				buffer.copy(wb, V_OFF - BPS, topV, mbx * 8, 8)
			end
			if isI4 then
				local tr = Y_OFF - BPS + 16
				if mby > 0 then
					if mbx >= mbw - 1 then
						buffer.fill(wb, tr, readu8(topY, mbx * 16 + 15), 4)
					else
						buffer.copy(wb, tr, topY, (mbx + 1) * 16, 4)
					end
				end
				for k = 1, 3 do
					buffer.copy(wb, tr + k * 4 * BPS, wb, tr, 4)
				end
				for n = 0, 15 do
					local dst = Y_OFF + KSCAN[n + 1]
					pred4(wb, dst, imodes[n + 1])
					idct(C, n * 16, wb, dst)
				end
			else
				local mode = ymode
				if mode == 0 then
					if mbx == 0 then
						mode = mby == 0 and 6 or 5
					else
						mode = mby == 0 and 4 or 0
					end
				end
				predBig(wb, Y_OFF, 16, mode)
				for n = 0, 15 do
					idct(C, n * 16, wb, Y_OFF + KSCAN[n + 1])
				end
			end
			local cm = uvmode
			if cm == 0 then
				if mbx == 0 then
					cm = mby == 0 and 6 or 5
				else
					cm = mby == 0 and 4 or 0
				end
			end
			predBig(wb, U_OFF, 8, cm)
			predBig(wb, V_OFF, 8, cm)
			for n = 0, 3 do
				local o = (n % 2) * 4 + (n // 2) * 4 * BPS
				idct(C, 256 + n * 16, wb, U_OFF + o)
				idct(C, 320 + n * 16, wb, V_OFF + o)
			end
			if mby < mbh - 1 then
				buffer.copy(topY, mbx * 16, wb, Y_OFF + 15 * BPS, 16)
				buffer.copy(topU, mbx * 8, wb, U_OFF + 7 * BPS, 8)
				buffer.copy(topV, mbx * 8, wb, V_OFF + 7 * BPS, 8)
			end
			for j = 0, 15 do
				buffer.copy(Yp, (mby * 16 + j) * yStride + mbx * 16, wb, Y_OFF + j * BPS, 16)
			end
			for j = 0, 7 do
				buffer.copy(Up, (mby * 8 + j) * uvStride + mbx * 8, wb, U_OFF + j * BPS, 8)
				buffer.copy(Vp, (mby * 8 + j) * uvStride + mbx * 8, wb, V_OFF + j * BPS, 8)
			end
		end
		breathe()
		if br.over > 0 or tb.over > 0 then
			fail("the lossy picture data ends early (the file is cut off)")
		end
	end

	-- loop filter, macroblock by macroblock in raster order
	if filterType > 0 then
		for mby = 0, mbh - 1 do
			breathe()
			for mbx = 0, mbw - 1 do
				local mi = mby * mbw + mbx
				local limit = fLimit[mi]
				if limit > 0 then
					local yo = mby * 16 * yStride + mbx * 16
					local inner = fInner[mi]
					if filterType == 1 then
						if mbx > 0 then
							simpleFilter(Yp, yo, 1, yStride, limit + 4)
						end
						if inner then
							for k = 1, 3 do
								simpleFilter(Yp, yo + 4 * k, 1, yStride, limit)
							end
						end
						if mby > 0 then
							simpleFilter(Yp, yo, yStride, 1, limit + 4)
						end
						if inner then
							for k = 1, 3 do
								simpleFilter(Yp, yo + 4 * k * yStride, yStride, 1, limit)
							end
						end
					else
						local il, hv = fIlevel[mi], fHev[mi]
						local uo = mby * 8 * uvStride + mbx * 8
						if mbx > 0 then
							filterLoop(Yp, yo, 1, yStride, 16, limit + 4, il, hv, false)
							filterLoop(Up, uo, 1, uvStride, 8, limit + 4, il, hv, false)
							filterLoop(Vp, uo, 1, uvStride, 8, limit + 4, il, hv, false)
						end
						if inner then
							for k = 1, 3 do
								filterLoop(Yp, yo + 4 * k, 1, yStride, 16, limit, il, hv, true)
							end
							filterLoop(Up, uo + 4, 1, uvStride, 8, limit, il, hv, true)
							filterLoop(Vp, uo + 4, 1, uvStride, 8, limit, il, hv, true)
						end
						if mby > 0 then
							filterLoop(Yp, yo, yStride, 1, 16, limit + 4, il, hv, false)
							filterLoop(Up, uo, uvStride, 1, 8, limit + 4, il, hv, false)
							filterLoop(Vp, uo, uvStride, 1, 8, limit + 4, il, hv, false)
						end
						if inner then
							for k = 1, 3 do
								filterLoop(Yp, yo + 4 * k * yStride, yStride, 1, 16, limit, il, hv, true)
							end
							filterLoop(Up, uo + 4 * uvStride, uvStride, 1, 8, limit, il, hv, true)
							filterLoop(Vp, uo + 4 * uvStride, uvStride, 1, 8, limit, il, hv, true)
						end
					end
				end
			end
		end
	end
	return Yp, Up, Vp, yStride, uvStride, width, height
end

-- YUV 4:2:0 -> RGBA (libwebp's "fancy" upsampling and colour conversion), alpha 255
local function yuvToRgba(Yp, Up, Vp, ys, uvs, w, h, out, outStride, ox, oy)
	local function conv(o, yv, u, v)
		local yy = (yv * 19077) // 256
		local r = yy + (v * 26149) // 256 - 14234
		local g = yy - (u * 6419) // 256 - (v * 13320) // 256 + 8708
		local bl = yy + (u * 33050) // 256 - 17685
		writeu8(out, o, r < 0 and 0 or (r >= 16384 and 255 or rshift(r, 6)))
		writeu8(out, o + 1, g < 0 and 0 or (g >= 16384 and 255 or rshift(g, 6)))
		writeu8(out, o + 2, bl < 0 and 0 or (bl >= 16384 and 255 or rshift(bl, 6)))
		writeu8(out, o + 3, 255)
	end
	-- one output row (y) from luma row y, with chroma rows nearRow (weight 3) and farRow (weight 1)
	local function row(y, nearRow, farRow)
		local yo = y * ys
		local no, fo = nearRow * uvs, farRow * uvs
		local base = (oy + y) * outStride + ox * 4
		local nu, nv = readu8(Up, no), readu8(Vp, no)
		local fu, fv = readu8(Up, fo), readu8(Vp, fo)
		conv(base, readu8(Yp, yo), (3 * nu + fu + 2) // 4, (3 * nv + fv + 2) // 4)
		local last = (w - 1) // 2
		for x = 1, last do
			local nu2, nv2 = readu8(Up, no + x), readu8(Vp, no + x)
			local fu2, fv2 = readu8(Up, fo + x), readu8(Vp, fo + x)
			-- the 2x2 neighbourhood: near-left (nu), near-right (nu2), far-left (fu), far-right (fu2)
			local au = fu + fu2 + nu + nu2 + 8
			local av = fv + fv2 + nv + nv2 + 8
			-- pixel 2x-1 is nearer the left samples, 2x the right ones
			local dLu = (au + 2 * (fu + nu2)) // 8 -- the diagonal away from near-left
			local dLv = (av + 2 * (fv + nv2)) // 8
			local dRu = (au + 2 * (fu2 + nu)) // 8
			local dRv = (av + 2 * (fv2 + nv)) // 8
			conv(base + (2 * x - 1) * 4, readu8(Yp, yo + 2 * x - 1), (dLu + nu) // 2, (dLv + nv) // 2)
			conv(base + 2 * x * 4, readu8(Yp, yo + 2 * x), (dRu + nu2) // 2, (dRv + nv2) // 2)
			nu, nv, fu, fv = nu2, nv2, fu2, fv2
		end
		if w % 2 == 0 then
			conv(base + (w - 1) * 4, readu8(Yp, yo + w - 1), (3 * nu + fu + 2) // 4, (3 * nv + fv + 2) // 4)
		end
	end
	row(0, 0, 0)
	local y = 1
	while y + 1 < h do
		if y % 32 == 1 then
			breathe()
		end
		local k = (y + 1) // 2 -- rows y (= 2k - 1) and y + 1 (= 2k) sit between chroma rows k - 1 and k
		row(y, k - 1, k)
		row(y + 1, k, k - 1)
		y += 2
	end
	if h % 2 == 0 and h > 1 then
		local k = h // 2 - 1
		row(h - 1, k, k)
	end
end

------------------------------------------------------------------------------------------------------------------------
-- alpha (ALPH chunk)

local function decodeAlpha(b, pos, len, w, h)
	if len < 1 then
		fail("the transparency data is empty")
	end
	local hdr = readu8(b, pos)
	local method = band(hdr, 3)
	local filter = band(rshift(hdr, 2), 3)
	local a = buffer.create(w * h)
	if method == 0 then
		if len - 1 < w * h then
			fail("the transparency data ends early (the file is cut off)")
		end
		buffer.copy(a, 0, b, pos + 1, w * h)
	elseif method == 1 then
		local argb = decodeLossless(b, pos + 1, pos + len, w, h)
		for i = 0, w * h - 1 do
			writeu8(a, i, readu8(argb, i * 4 + 1)) -- green
		end
	else
		fail("unknown transparency compression " .. method)
	end
	if filter == 1 then -- horizontal
		for y = 0, h - 1 do
			local pred = y == 0 and 0 or readu8(a, (y - 1) * w)
			for x = 0, w - 1 do
				local i = y * w + x
				pred = band(pred + readu8(a, i), 255)
				writeu8(a, i, pred)
			end
		end
	elseif filter == 2 then -- vertical
		for y = 0, h - 1 do
			if y == 0 then
				local pred = 0
				for x = 0, w - 1 do
					pred = band(pred + readu8(a, x), 255)
					writeu8(a, x, pred)
				end
			else
				for x = 0, w - 1 do
					local i = y * w + x
					writeu8(a, i, band(readu8(a, i - w) + readu8(a, i), 255))
				end
			end
		end
	elseif filter == 3 then -- gradient
		for y = 0, h - 1 do
			if y == 0 then
				local pred = 0
				for x = 0, w - 1 do
					pred = band(pred + readu8(a, x), 255)
					writeu8(a, x, pred)
				end
			else
				local prev = (y - 1) * w
				local top = readu8(a, prev)
				local tl, left = top, top
				for x = 0, w - 1 do
					top = readu8(a, prev + x)
					local g = left + top - tl
					g = g < 0 and 0 or (g > 255 and 255 or g)
					left = band(readu8(a, y * w + x) + g, 255)
					tl = top
					writeu8(a, y * w + x, left)
				end
			end
		end
	end
	return a
end

------------------------------------------------------------------------------------------------------------------------
-- container

local function toBuffer(bytes)
	return type(bytes) == "string" and buffer.fromstring(bytes) or bytes
end

function Webp.isWebp(bytes)
	local b = toBuffer(bytes)
	return buffer.len(b) >= 12 and buffer.readstring(b, 0, 4) == "RIFF" and buffer.readstring(b, 8, 4) == "WEBP"
end

-- chunks of a RIFF list in [pos, stop): { { id =, pos =, len = } }
local function chunks(b, pos, stop)
	local list = {}
	while pos + 8 <= stop do
		local id = buffer.readstring(b, pos, 4)
		local len = readu32(b, pos + 4)
		local start = pos + 8
		if start + len > stop then
			len = stop - start -- a cut-off last chunk: decode what's there
			table.insert(list, { id = id, pos = start, len = len, cut = true })
			break
		end
		table.insert(list, { id = id, pos = start, len = len })
		pos = start + len + (len % 2)
	end
	return list
end

-- one picture (VP8 with optional ALPH, or VP8L) into an RGBA buffer region
local function drawPicture(b, list, out, outStride, ox, oy)
	local alph, img
	for _, c in ipairs(list) do
		if c.id == "ALPH" then
			alph = c
		elseif c.id == "VP8 " or c.id == "VP8L" then
			img = c
			break
		end
	end
	if not img then
		fail("no picture data in the file")
	end
	if img.id == "VP8L" then
		local argb, w, h, alphaUsed = decodeVP8L(b, img.pos, img.len)
		for y = 0, h - 1 do
			for x = 0, w - 1 do
				local v = readu32(argb, (y * w + x) * 4)
				local o = (oy + y) * outStride + (ox + x) * 4
				writeu8(out, o, band(rshift(v, 16), 255))
				writeu8(out, o + 1, band(rshift(v, 8), 255))
				writeu8(out, o + 2, band(v, 255))
				writeu8(out, o + 3, rshift(v, 24))
			end
		end
		return w, h, alphaUsed
	end
	local Yp, Up, Vp, ys, uvs, w, h = decodeVP8(b, img.pos, img.len)
	yuvToRgba(Yp, Up, Vp, ys, uvs, w, h, out, outStride, ox, oy)
	if alph then
		local a = decodeAlpha(b, alph.pos, alph.len, w, h)
		for y = 0, h - 1 do
			for x = 0, w - 1 do
				writeu8(out, (oy + y) * outStride + (ox + x) * 4 + 3, readu8(a, y * w + x))
			end
		end
	end
	return w, h, alph ~= nil
end

-- size of a picture's chunks without decoding it
local function pictureSize(b, list)
	for _, c in ipairs(list) do
		if c.id == "VP8L" and c.len >= 5 then
			local hdr = readu32(b, c.pos + 1)
			return band(hdr, 0x3fff) + 1, band(rshift(hdr, 14), 0x3fff) + 1, "lossless"
		elseif c.id == "VP8 " and c.len >= 10 then
			return band(readu16(b, c.pos + 6), 0x3fff), band(readu16(b, c.pos + 8), 0x3fff), "lossy"
		end
	end
	return nil
end

-- "lossy WebP, 512x512" / "animated WebP, 64 frames, 480x270" (for messages)
function Webp.describe(bytes)
	local b = toBuffer(bytes)
	if not Webp.isWebp(b) then
		return "not a WebP file"
	end
	local list = chunks(b, 12, math.min(buffer.len(b), 8 + readu32(b, 4)))
	local frames, w, h = 0, nil, nil
	for _, c in ipairs(list) do
		if c.id == "VP8X" and c.len >= 10 then
			w = readu8(b, c.pos + 4) + readu8(b, c.pos + 5) * 256 + readu8(b, c.pos + 6) * 65536 + 1
			h = readu8(b, c.pos + 7) + readu8(b, c.pos + 8) * 256 + readu8(b, c.pos + 9) * 65536 + 1
		elseif c.id == "ANMF" then
			frames += 1
		end
	end
	if frames > 0 then
		return ("animated WebP, %d frames, %dx%d"):format(frames, w or 0, h or 0)
	end
	local pw, ph, kind = pictureSize(b, list)
	return ("%s WebP, %dx%d"):format(kind or "unknown", pw or w or 0, ph or h or 0)
end

local function blendNonPremult(src, dst)
	local sa = rshift(src, 24)
	if sa == 0 then
		return dst
	end
	local da = rshift(dst, 24)
	local dfa = rshift(da * (256 - sa), 8)
	local ba = sa + dfa
	local scale = 16777216 // ba
	local out = ba * 16777216
	for sh = 0, 16, 8 do
		local sc, dc = band(rshift(src, sh), 255), band(rshift(dst, sh), 255)
		local v = rshift(((sc * sa + dc * dfa) * scale) % 4294967296, 24)
		out += lshift(band(v, 255), sh)
	end
	return out
end

local decodeWhole
function Webp.decode(bytes)
	local b = toBuffer(bytes)
	if not Webp.isWebp(b) then
		fail("not a WebP file")
	end
	local ok, res = pcall(decodeWhole, b)
	if ok then
		return res
	end
	local want = 8 + readu32(b, 4)
	if buffer.len(b) < want then -- a cut-off download explains whatever went wrong
		fail(("the file is cut off (%d of %d bytes arrived)"):format(buffer.len(b), want))
	end
	error(res, 0)
end

decodeWhole = function(b)
	local stop = math.min(buffer.len(b), 8 + readu32(b, 4))
	local list = chunks(b, 12, stop)
	if #list == 0 then
		fail("the file has no chunks (it's cut off or empty)")
	end
	local first = list[1]
	if first.id == "VP8 " or first.id == "VP8L" then
		local w, h = pictureSize(b, list)
		if not w then
			fail("the picture header is damaged")
		end
		local out = buffer.create(w * h * 4)
		local _, _, alpha = drawPicture(b, list, out, w * 4, 0, 0)
		return { width = w, height = h, data = out, hasAlpha = alpha == true }
	end
	if first.id ~= "VP8X" or first.len < 10 then
		fail(("unknown WebP layout (first chunk %q)"):format(first.id))
	end
	local flags = readu8(b, first.pos)
	local cw = readu8(b, first.pos + 4) + readu8(b, first.pos + 5) * 256 + readu8(b, first.pos + 6) * 65536 + 1
	local ch = readu8(b, first.pos + 7) + readu8(b, first.pos + 8) * 256 + readu8(b, first.pos + 9) * 65536 + 1
	if cw * ch > 16384 * 16384 then
		fail(("the picture is too big (%dx%d)"):format(cw, ch))
	end
	local animated = band(flags, 2) ~= 0
	if not animated then
		local out = buffer.create(cw * ch * 4)
		local w, h = pictureSize(b, list)
		if not w then
			fail("no picture data in the file")
		end
		if w ~= cw or h ~= ch then
			fail(("the picture (%dx%d) doesn't match the canvas (%dx%d)"):format(w, h, cw, ch))
		end
		local _, _, alpha = drawPicture(b, list, out, cw * 4, 0, 0)
		return { width = cw, height = ch, data = out, hasAlpha = alpha == true }
	end
	-- animation: frames composited the way libwebp's animation decoder does
	local loop = 0
	local frames = {}
	local canvas = buffer.create(cw * ch * 4)
	local disposed = buffer.create(cw * ch * 4) -- the previous frame after its disposal
	local prev, prevKey = nil, false
	local anyAlpha = false
	local frameNum = 0
	for _, c in ipairs(list) do
		if c.id == "ANIM" and c.len >= 6 then
			loop = readu16(b, c.pos + 4)
		elseif c.id == "ANMF" and c.len >= 16 then
			frameNum += 1
			local p = c.pos
			local fx = (readu8(b, p) + readu8(b, p + 1) * 256 + readu8(b, p + 2) * 65536) * 2
			local fy = (readu8(b, p + 3) + readu8(b, p + 4) * 256 + readu8(b, p + 5) * 65536) * 2
			local fw = readu8(b, p + 6) + readu8(b, p + 7) * 256 + readu8(b, p + 8) * 65536 + 1
			local fh = readu8(b, p + 9) + readu8(b, p + 10) * 256 + readu8(b, p + 11) * 65536 + 1
			local dur = readu8(b, p + 12) + readu8(b, p + 13) * 256 + readu8(b, p + 14) * 65536
			local fflags = readu8(b, p + 15)
			local blend = band(fflags, 2) == 0
			local disposeBg = band(fflags, 1) == 1
			if fx + fw > cw or fy + fh > ch then
				fail(("animation frame %d doesn't fit the canvas"):format(frameNum))
			end
			local sub = chunks(b, p + 16, c.pos + c.len)
			local hasAlpha = false
			for _, s in ipairs(sub) do
				if s.id == "ALPH" then
					hasAlpha = true
				elseif s.id == "VP8L" and s.len >= 5 then
					hasAlpha = band(rshift(readu32(b, s.pos + 1), 28), 1) == 1
				end
			end
			local full = fw == cw and fh == ch
			local key
			if frameNum == 1 then
				key = true
			elseif (not hasAlpha or not blend) and full then
				key = true
			else
				key = prev.disposeBg and (prev.full or prevKey)
			end
			if key then
				buffer.fill(canvas, 0, 0)
			else
				buffer.copy(canvas, 0, disposed, 0)
			end
			local fbuf = buffer.create(fw * fh * 4)
			buffer.fill(fbuf, 0, 0)
			local w, h, alpha = drawPicture(b, sub, fbuf, fw * 4, 0, 0)
			if w ~= fw or h ~= fh then
				fail(("animation frame %d is %dx%d but says %dx%d"):format(frameNum, w, h, fw, fh))
			end
			anyAlpha = anyAlpha or alpha
			-- the frame's pixels go in; with blending, the partly transparent ones mix with what was there
			local doBlend = frameNum > 1 and blend and not key
			for y = 0, fh - 1 do
				local cy = fy + y
				local l1, w1, l2, w2 = fx, fw, -1, 0
				if doBlend and prev.disposeBg then
					local pmx, pmy = prev.x + prev.w, prev.y + prev.h
					if not (cy < prev.y or cy >= pmy or fx >= pmx or fx + fw <= prev.x) then
						l1, w1 = -1, 0
						if fx < prev.x then
							l1, w1 = fx, prev.x - fx
						end
						if fx + fw > pmx then
							l2, w2 = pmx, fx + fw - pmx
						end
					end
				end
				for x = 0, fw - 1 do
					local cx = fx + x
					local src = readu32(fbuf, (y * fw + x) * 4)
					-- RGBA bytes as a little-endian word: A in the top byte
					local o = (cy * cw + cx) * 4
					if doBlend and rshift(src, 24) ~= 255 and ((cx >= l1 and cx < l1 + w1) or (cx >= l2 and cx < l2 + w2)) then
						src = blendNonPremult(src, readu32(disposed, o))
					end
					writeu32(canvas, o, src)
				end
			end
			local snap = buffer.create(cw * ch * 4)
			buffer.copy(snap, 0, canvas, 0)
			table.insert(frames, { data = snap, delay = (dur <= 10 and 100 or dur) / 1000 })
			buffer.copy(disposed, 0, canvas, 0)
			if disposeBg then
				for y = fy, fy + fh - 1 do
					buffer.fill(disposed, (y * cw + fx) * 4, 0, fw * 4)
				end
			end
			prev = { x = fx, y = fy, w = fw, h = fh, disposeBg = disposeBg, full = full }
			prevKey = key
			breathe()
		end
	end
	if #frames == 0 then
		fail("the animation has no frames")
	end
	return { width = cw, height = ch, data = frames[1].data, hasAlpha = anyAlpha or band(flags, 16) ~= 0, frames = frames, loop = loop }
end

return Webp
