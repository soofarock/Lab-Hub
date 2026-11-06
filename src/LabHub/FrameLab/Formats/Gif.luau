--!native
--!optimize 2
-- GIF decoder (GIF87a / GIF89a): every frame of an animation, composited the way browsers show them (disposal
-- methods, transparency, local colour tables, interlaced frames).
--
--   local gif = Gif.decode(bytes)
--   gif.width, gif.height, gif.frames = { { data = RGBA buffer (full canvas), delay = seconds } }, gif.loop
--   Gif.isGif(bytes)

local Gif = {}

function Gif.isGif(bytes)
	local b = type(bytes) == "string" and buffer.fromstring(bytes) or bytes
	if buffer.len(b) < 6 then
		return false
	end
	local s = buffer.readstring(b, 0, 6)
	return s == "GIF87a" or s == "GIF89a"
end

-- LZW-decode the image data sub-blocks starting at pos into a table of colour indices (pixel count n)
local function lzw(b, pos, minCode, n)
	-- gather the sub-blocks
	local parts, total = {}, 0
	while true do
		local size = buffer.readu8(b, pos)
		pos += 1
		if size == 0 then
			break
		end
		table.insert(parts, { pos, size })
		total += size
		pos += size
	end
	local data = buffer.create(total + 4)
	local o = 0
	for _, part in ipairs(parts) do
		buffer.copy(data, o, b, part[1], part[2])
		o += part[2]
	end
	local out = table.create(n, 0)
	local clear = 2 ^ minCode
	local eoi = clear + 1
	local codeSize = minCode + 1
	local nextCode = eoi + 1
	-- dictionary as prefix / suffix chains, with first symbol and length per entry
	local prefix, suffix, first, length = table.create(4096, 0), table.create(4096, 0), table.create(4096, 0), table.create(4096, 0)
	for i = 0, clear - 1 do
		suffix[i + 1], first[i + 1], length[i + 1], prefix[i + 1] = i, i, 1, -1
	end
	local bitpos, bits = 0, total * 8
	local prev = -1
	local count = 0
	while bitpos + codeSize <= bits and count < n do
		-- read codeSize bits LSB first
		local byte = bitpos // 8
		local raw = buffer.readu8(data, byte) + buffer.readu8(data, byte + 1) * 256 + buffer.readu8(data, byte + 2) * 65536
		local code = bit32.band(bit32.rshift(raw, bitpos % 8), 2 ^ codeSize - 1)
		bitpos += codeSize
		if code == clear then
			codeSize = minCode + 1
			nextCode = eoi + 1
			prev = -1
		elseif code == eoi then
			break
		else
			local entry = code
			local firstSym
			if code < nextCode then
				firstSym = first[code + 1]
			elseif prev >= 0 then
				-- the KwKwK case: the code being defined right now
				firstSym = first[prev + 1]
			else
				break -- corrupt
			end
			if prev >= 0 and nextCode < 4096 then
				prefix[nextCode + 1] = prev
				suffix[nextCode + 1] = firstSym
				first[nextCode + 1] = first[prev + 1]
				length[nextCode + 1] = length[prev + 1] + 1
				nextCode += 1
				if nextCode == 2 ^ codeSize and codeSize < 12 then
					codeSize += 1
				end
			end
			-- write the string for entry (walk the chain backwards)
			local l = length[entry + 1]
			local e = entry
			for k = l - 1, 0, -1 do
				if count + k < n then
					out[count + k + 1] = suffix[e + 1]
				end
				e = prefix[e + 1]
			end
			count += l
			prev = code
		end
	end
	return out, pos
end

function Gif.decode(bytes)
	local b = type(bytes) == "string" and buffer.fromstring(bytes) or bytes
	if not Gif.isGif(b) then
		error("GIF: not a GIF file")
	end
	local len = buffer.len(b)
	local W, H = buffer.readu16(b, 6), buffer.readu16(b, 8)
	local flags = buffer.readu8(b, 10)
	local bgIndex = buffer.readu8(b, 11)
	local pos = 13
	local global
	if bit32.band(flags, 0x80) ~= 0 then
		local size = 2 ^ (bit32.band(flags, 7) + 1)
		global = { pos = pos, size = size }
		pos += size * 3
	end
	local canvas = buffer.create(W * H * 4) -- starts fully transparent
	local frames = {}
	local gce = { delay = 0.1, transparent = -1, disposal = 0 }
	local loop = nil
	local hasAlpha = false
	while pos < len do
		local block = buffer.readu8(b, pos)
		pos += 1
		if block == 0x3B then
			break
		elseif block == 0x21 then
			local label = buffer.readu8(b, pos)
			pos += 1
			if label == 0xF9 then
				local size = buffer.readu8(b, pos)
				local pf = buffer.readu8(b, pos + 1)
				local delay = buffer.readu16(b, pos + 2)
				gce.disposal = bit32.band(bit32.rshift(pf, 2), 7)
				gce.transparent = bit32.band(pf, 1) ~= 0 and buffer.readu8(b, pos + 4) or -1
				-- browsers treat delays under 20 ms as 100 ms
				gce.delay = (delay < 2) and 0.1 or delay / 100
				pos += 1 + size
				-- the sub-blocks that follow (normally just the terminator)
				while pos < len do
					local n = buffer.readu8(b, pos)
					pos += 1 + n
					if n == 0 then
						break
					end
				end
			else
				if label == 0xFF and buffer.readu8(b, pos) == 11 and buffer.readstring(b, pos + 1, 11) == "NETSCAPE2.0" then
					loop = buffer.readu16(b, pos + 14)
				end
				-- skip the sub-blocks
				while pos < len do
					local size = buffer.readu8(b, pos)
					pos += 1 + size
					if size == 0 then
						break
					end
				end
			end
		elseif block == 0x2C then
			local fx, fy = buffer.readu16(b, pos), buffer.readu16(b, pos + 2)
			local fw, fh = buffer.readu16(b, pos + 4), buffer.readu16(b, pos + 6)
			local lf = buffer.readu8(b, pos + 8)
			pos += 9
			local ct = global
			if bit32.band(lf, 0x80) ~= 0 then
				local size = 2 ^ (bit32.band(lf, 7) + 1)
				ct = { pos = pos, size = size }
				pos += size * 3
			end
			local interlaced = bit32.band(lf, 0x40) ~= 0
			local minCode = buffer.readu8(b, pos)
			pos += 1
			local idx
			idx, pos = lzw(b, pos, minCode, fw * fh)
			-- disposal 3 (restore previous): remember the canvas before drawing
			local saved
			if gce.disposal == 3 then
				saved = buffer.create(W * H * 4)
				buffer.copy(saved, 0, canvas, 0)
			end
			-- row order of an interlaced frame
			local rows = table.create(fh, 0)
			if interlaced then
				local r = 0
				for _, pass in ipairs({ { 0, 8 }, { 4, 8 }, { 2, 4 }, { 1, 2 } }) do
					for y = pass[1], fh - 1, pass[2] do
						rows[r + 1] = y
						r += 1
					end
				end
			else
				for y = 0, fh - 1 do
					rows[y + 1] = y
				end
			end
			local tr = gce.transparent
			if tr >= 0 then
				hasAlpha = true
			end
			for r = 0, fh - 1 do
				local y = fy + rows[r + 1]
				if y < H then
					for x = 0, fw - 1 do
						local cx = fx + x
						local ci = idx[r * fw + x + 1] or 0
						if cx < W and ci ~= tr and ct and ci < ct.size then
							local o = (y * W + cx) * 4
							local p = ct.pos + ci * 3
							buffer.writeu8(canvas, o, buffer.readu8(b, p))
							buffer.writeu8(canvas, o + 1, buffer.readu8(b, p + 1))
							buffer.writeu8(canvas, o + 2, buffer.readu8(b, p + 2))
							buffer.writeu8(canvas, o + 3, 255)
						end
					end
				end
			end
			local snapshot = buffer.create(W * H * 4)
			buffer.copy(snapshot, 0, canvas, 0)
			table.insert(frames, { data = snapshot, delay = gce.delay })
			-- dispose for the next frame
			if gce.disposal == 2 then
				for y = fy, math.min(H, fy + fh) - 1 do
					buffer.fill(canvas, (y * W + fx) * 4, 0, math.max(0, math.min(fw, W - fx)) * 4)
				end
				hasAlpha = true
			elseif gce.disposal == 3 and saved then
				canvas = saved
			end
			gce = { delay = 0.1, transparent = -1, disposal = 0 }
		else
			break -- unknown block: stop here (keep what was decoded)
		end
	end
	if #frames == 0 then
		error("GIF: no image in the file")
	end
	-- any pixel never drawn stays transparent
	if not hasAlpha then
		for i = 0, W * H - 1 do
			if buffer.readu8(frames[1].data, i * 4 + 3) == 0 then
				hasAlpha = true
				break
			end
		end
	end
	return { width = W, height = H, frames = frames, loop = loop, hasAlpha = hasAlpha, background = bgIndex }
end

return Gif
