--!native
--!optimize 2
-- PNG decoder: every standard colour type (grey, RGB, palette, grey + alpha, RGBA) and bit depth (1, 2, 4, 8, 16),
-- all five row filters, Adam7 interlacing, palette and tRNS transparency. 16-bit samples keep their high byte.
--
--   local image = Png.decode(bytes)   -- bytes: buffer or string
--   image.width, image.height, image.data (buffer, RGBA 8-bit, row-major), image.hasAlpha
--   Png.isPng(bytes)

local Inflate
if script then
	Inflate = require(script.Parent.Inflate)
else
	Inflate = require("./Inflate") -- standalone Luau (outside Roblox)
end

local Png = {}

local SIGNATURE = "\137PNG\r\n\26\n"

function Png.isPng(bytes)
	local b = type(bytes) == "string" and buffer.fromstring(bytes) or bytes
	return buffer.len(b) >= 8 and buffer.readstring(b, 0, 8) == SIGNATURE
end

local function be32(b, o)
	return buffer.readu8(b, o) * 16777216 + buffer.readu8(b, o + 1) * 65536 + buffer.readu8(b, o + 2) * 256 + buffer.readu8(b, o + 3)
end

local CHANNELS = { [0] = 1, [2] = 3, [3] = 1, [4] = 2, [6] = 4 }

-- undo the row filters of one (sub)image in place; rows are (1 + rowBytes) long starting at `base`
local function unfilter(raw, base, rows, rowBytes, bpp)
	local stride = rowBytes + 1
	for y = 0, rows - 1 do
		local r = base + y * stride
		local ft = buffer.readu8(raw, r)
		local cur = r + 1
		local prev = r + 1 - stride -- previous row's data (only read when y > 0)
		if ft == 0 then
			-- none
		elseif ft == 1 then
			for i = bpp, rowBytes - 1 do
				buffer.writeu8(raw, cur + i, (buffer.readu8(raw, cur + i) + buffer.readu8(raw, cur + i - bpp)) % 256)
			end
		elseif ft == 2 then
			if y > 0 then
				for i = 0, rowBytes - 1 do
					buffer.writeu8(raw, cur + i, (buffer.readu8(raw, cur + i) + buffer.readu8(raw, prev + i)) % 256)
				end
			end
		elseif ft == 3 then
			for i = 0, rowBytes - 1 do
				local left = i >= bpp and buffer.readu8(raw, cur + i - bpp) or 0
				local up = y > 0 and buffer.readu8(raw, prev + i) or 0
				buffer.writeu8(raw, cur + i, (buffer.readu8(raw, cur + i) + (left + up) // 2) % 256)
			end
		elseif ft == 4 then
			for i = 0, rowBytes - 1 do
				local a = i >= bpp and buffer.readu8(raw, cur + i - bpp) or 0
				local b = y > 0 and buffer.readu8(raw, prev + i) or 0
				local c = (y > 0 and i >= bpp) and buffer.readu8(raw, prev + i - bpp) or 0
				local p = a + b - c
				local pa, pb, pc = math.abs(p - a), math.abs(p - b), math.abs(p - c)
				local pred
				if pa <= pb and pa <= pc then
					pred = a
				elseif pb <= pc then
					pred = b
				else
					pred = c
				end
				buffer.writeu8(raw, cur + i, (buffer.readu8(raw, cur + i) + pred) % 256)
			end
		else
			error("PNG: bad filter type " .. ft)
		end
	end
end

local ADAM7 = { -- x0, y0, dx, dy
	{ 0, 0, 8, 8 }, { 4, 0, 8, 8 }, { 0, 4, 4, 8 }, { 2, 0, 4, 4 }, { 0, 2, 2, 4 }, { 1, 0, 2, 2 }, { 0, 1, 1, 2 },
}

function Png.decode(bytes, options)
	local yield = options and options.Yield == true
	local lastYield = os.clock()
	local b = type(bytes) == "string" and buffer.fromstring(bytes) or bytes
	if not Png.isPng(b) then
		error("PNG: not a PNG file")
	end
	local len = buffer.len(b)
	local pos = 8
	local width, height, depth, ctype, interlace
	local palette, paletteN = nil, 0
	local trns = nil
	local idat = {}
	local idatLen = 0
	while pos + 8 <= len do
		local clen = be32(b, pos)
		local kind = buffer.readstring(b, pos + 4, 4)
		local data = pos + 8
		if data + clen > len then
			error("PNG: truncated chunk " .. kind)
		end
		if kind == "IHDR" then
			width, height = be32(b, data), be32(b, data + 4)
			depth, ctype = buffer.readu8(b, data + 8), buffer.readu8(b, data + 9)
			interlace = buffer.readu8(b, data + 12)
			if not CHANNELS[ctype] then
				error("PNG: bad colour type " .. ctype)
			end
		elseif kind == "PLTE" then
			paletteN = clen // 3
			palette = buffer.create(256 * 4)
			buffer.fill(palette, 0, 255)
			for i = 0, paletteN - 1 do
				buffer.writeu8(palette, i * 4, buffer.readu8(b, data + i * 3))
				buffer.writeu8(palette, i * 4 + 1, buffer.readu8(b, data + i * 3 + 1))
				buffer.writeu8(palette, i * 4 + 2, buffer.readu8(b, data + i * 3 + 2))
			end
		elseif kind == "tRNS" then
			trns = { at = data, len = clen }
		elseif kind == "IDAT" then
			table.insert(idat, { data, clen })
			idatLen += clen
		elseif kind == "IEND" then
			break
		end
		pos = data + clen + 4 -- skip CRC
	end
	if not width then
		error("PNG: no IHDR")
	end
	if #idat == 0 then
		error("PNG: no image data")
	end
	local ch = CHANNELS[ctype]
	local bitsPP = ch * depth
	local bpp = math.max(1, bitsPP // 8)
	-- palette alpha / colour key
	local hasAlpha = ctype == 4 or ctype == 6
	local keyR, keyG, keyB, keyGrey
	if trns then
		if ctype == 3 and palette then
			for i = 0, math.min(trns.len, 256) - 1 do
				buffer.writeu8(palette, i * 4 + 3, buffer.readu8(b, trns.at + i))
			end
			hasAlpha = true
		elseif ctype == 0 and trns.len >= 2 then
			keyGrey = buffer.readu8(b, trns.at) * 256 + buffer.readu8(b, trns.at + 1)
			hasAlpha = true
		elseif ctype == 2 and trns.len >= 6 then
			keyR = buffer.readu8(b, trns.at) * 256 + buffer.readu8(b, trns.at + 1)
			keyG = buffer.readu8(b, trns.at + 2) * 256 + buffer.readu8(b, trns.at + 3)
			keyB = buffer.readu8(b, trns.at + 4) * 256 + buffer.readu8(b, trns.at + 5)
			hasAlpha = true
		end
	end
	if ctype == 3 and not palette then
		error("PNG: palette image without PLTE")
	end

	-- concatenate IDAT and inflate
	local z = buffer.create(idatLen)
	local o = 0
	for _, c in ipairs(idat) do
		buffer.copy(z, o, b, c[1], c[2])
		o += c[2]
	end
	local passes = {}
	local expected = 0
	if interlace == 1 then
		for p = 1, 7 do
			local a = ADAM7[p]
			local pw = width > a[1] and (width - a[1] + a[3] - 1) // a[3] or 0
			local ph = height > a[2] and (height - a[2] + a[4] - 1) // a[4] or 0
			local rowBytes = (pw * bitsPP + 7) // 8
			passes[p] = { w = pw, h = ph, rowBytes = rowBytes, base = expected, a = a }
			if pw > 0 and ph > 0 then
				expected += ph * (rowBytes + 1)
			end
		end
	else
		local rowBytes = (width * bitsPP + 7) // 8
		passes[1] = { w = width, h = height, rowBytes = rowBytes, base = 0, a = { 0, 0, 1, 1 } }
		expected = height * (rowBytes + 1)
	end
	local raw, rawLen = Inflate.zlib(z, 0, expected)
	if rawLen < expected then
		error(("PNG: image data too short (%d of %d bytes)"):format(rawLen, expected))
	end

	local out = buffer.create(width * height * 4)
	local scale = depth < 8 and (255 // (2 ^ depth - 1)) or 1
	for _, ps in ipairs(passes) do
		local pw, ph = ps.w, ps.h
		if pw > 0 and ph > 0 then
			unfilter(raw, ps.base, ph, ps.rowBytes, bpp)
			local x0, y0, dx, dy = ps.a[1], ps.a[2], ps.a[3], ps.a[4]
			local stride = ps.rowBytes + 1
			for y = 0, ph - 1 do
				local row = ps.base + y * stride + 1
				local oy = (y0 + y * dy) * width
				for x = 0, pw - 1 do
					local r, g, bl, al = 0, 0, 0, 255
					if depth == 8 then
						local s = row + x * ch
						if ctype == 0 then
							r = buffer.readu8(raw, s)
							g, bl = r, r
							if keyGrey and r == keyGrey then
								al = 0
							end
						elseif ctype == 2 then
							r, g, bl = buffer.readu8(raw, s), buffer.readu8(raw, s + 1), buffer.readu8(raw, s + 2)
							if keyR and r == keyR and g == keyG and bl == keyB then
								al = 0
							end
						elseif ctype == 3 then
							local i = buffer.readu8(raw, s) * 4
							r, g, bl, al = buffer.readu8(palette, i), buffer.readu8(palette, i + 1), buffer.readu8(palette, i + 2), buffer.readu8(palette, i + 3)
						elseif ctype == 4 then
							r = buffer.readu8(raw, s)
							g, bl, al = r, r, buffer.readu8(raw, s + 1)
						else
							r, g, bl, al = buffer.readu8(raw, s), buffer.readu8(raw, s + 1), buffer.readu8(raw, s + 2), buffer.readu8(raw, s + 3)
						end
					elseif depth == 16 then
						local s = row + x * ch * 2
						local function v(k)
							return buffer.readu8(raw, s + k * 2) * 256 + buffer.readu8(raw, s + k * 2 + 1)
						end
						if ctype == 0 then
							local gv = v(0)
							r = gv // 256
							g, bl = r, r
							if keyGrey and gv == keyGrey then
								al = 0
							end
						elseif ctype == 2 then
							local rv, gv, bv = v(0), v(1), v(2)
							r, g, bl = rv // 256, gv // 256, bv // 256
							if keyR and rv == keyR and gv == keyG and bv == keyB then
								al = 0
							end
						elseif ctype == 4 then
							r = v(0) // 256
							g, bl, al = r, r, v(1) // 256
						else
							r, g, bl, al = v(0) // 256, v(1) // 256, v(2) // 256, v(3) // 256
						end
					else
						-- 1, 2 or 4 bits per sample: grey or palette, packed MSB first
						local bit = x * depth
						local byte = buffer.readu8(raw, row + bit // 8)
						local shift = 8 - depth - bit % 8
						local val = bit32.band(bit32.rshift(byte, shift), 2 ^ depth - 1)
						if ctype == 3 then
							local i = val * 4
							r, g, bl, al = buffer.readu8(palette, i), buffer.readu8(palette, i + 1), buffer.readu8(palette, i + 2), buffer.readu8(palette, i + 3)
						else
							r = val * scale
							g, bl = r, r
							if keyGrey and val == keyGrey then
								al = 0
							end
						end
					end
					local op = (oy + x0 + x * dx) * 4
					buffer.writeu8(out, op, r)
					buffer.writeu8(out, op + 1, g)
					buffer.writeu8(out, op + 2, bl)
					buffer.writeu8(out, op + 3, al)
				end
				if yield and os.clock() - lastYield > 0.008 then
					task.wait() -- options.Yield: a big picture doesn't freeze the game
					lastYield = os.clock()
				end
			end
		end
	end
	return { width = width, height = height, data = out, hasAlpha = hasAlpha }
end

-- APNG: the frames of an animated PNG, composited the way browsers show them (dispose and blend operations)
--   Png.isAnimated(bytes) -> true for an APNG (an acTL chunk before the image data)
--   local anim = Png.decodeAnimation(bytes, options)
--   anim.width, anim.height, anim.frames = { { data = RGBA buffer (full canvas), delay = seconds } }, anim.loop,
--   anim.hasAlpha; a file without an animation gives its one picture as the only frame

function Png.isAnimated(bytes)
	local b = type(bytes) == "string" and buffer.fromstring(bytes) or bytes
	if not Png.isPng(b) then
		return false
	end
	local len, pos = buffer.len(b), 8
	while pos + 8 <= len do
		local clen = be32(b, pos)
		local kind = buffer.readstring(b, pos + 4, 4)
		if kind == "acTL" then
			return true
		elseif kind == "IDAT" or kind == "IEND" then
			return false
		end
		pos += 12 + clen
	end
	return false
end

-- a chunk (length, type, data, a CRC the decoder doesn't check)
local function putChunk(out, o, kind, src, at, n)
	buffer.writeu32(out, o, bit32.byteswap(n))
	buffer.writestring(out, o + 4, kind)
	if n > 0 then
		buffer.copy(out, o + 8, src, at, n)
	end
	buffer.writeu32(out, o + 8 + n, 0)
	return o + 12 + n
end

function Png.decodeAnimation(bytes, options)
	local b = type(bytes) == "string" and buffer.fromstring(bytes) or bytes
	if not Png.isPng(b) then
		error("PNG: not a PNG file")
	end
	local len, pos = buffer.len(b), 8
	local ihdr, plte, trns, loop
	local frames, cur, seenIdat = {}, nil, false
	while pos + 8 <= len do
		local clen = be32(b, pos)
		local kind = buffer.readstring(b, pos + 4, 4)
		local data = pos + 8
		if data + clen > len then
			error("PNG: truncated chunk " .. kind)
		end
		if kind == "IHDR" then
			ihdr = data
		elseif kind == "PLTE" then
			plte = { data, clen }
		elseif kind == "tRNS" then
			trns = { data, clen }
		elseif kind == "acTL" and clen >= 8 then
			loop = be32(b, data + 4) == 0
		elseif kind == "fcTL" and clen >= 26 then
			local num, den = buffer.readu8(b, data + 20) * 256 + buffer.readu8(b, data + 21), buffer.readu8(b, data + 22) * 256 + buffer.readu8(b, data + 23)
			if den == 0 then
				den = 100
			end
			cur = {
				w = be32(b, data + 4), h = be32(b, data + 8), x = be32(b, data + 12), y = be32(b, data + 16),
				delay = num / den, dispose = buffer.readu8(b, data + 24), blend = buffer.readu8(b, data + 25), parts = {},
			}
			table.insert(frames, cur)
		elseif kind == "IDAT" then
			if not seenIdat and #frames == 0 then
				cur = nil -- (a default picture that is not part of the animation)
			end
			seenIdat = true
			if cur then
				table.insert(cur.parts, { data, clen })
			end
		elseif kind == "fdAT" and cur and clen > 4 then
			table.insert(cur.parts, { data + 4, clen - 4 })
		elseif kind == "IEND" then
			break
		end
		pos = data + clen + 4
	end
	if not ihdr then
		error("PNG: no IHDR")
	end
	local W, H = be32(b, ihdr), be32(b, ihdr + 4)
	if #frames == 0 then
		local img = Png.decode(b, options)
		return { width = img.width, height = img.height, frames = { { data = img.data, delay = 0.1 } }, hasAlpha = img.hasAlpha, loop = true }
	end
	local canvas = buffer.create(W * H * 4)
	local out = {}
	local hasAlpha = false
	for i, f in ipairs(frames) do
		if #f.parts == 0 or f.w < 1 or f.h < 1 or f.x + f.w > W or f.y + f.h > H then
			error(("APNG: frame %d is broken"):format(i), 0)
		end
		-- the frame as a picture of its own: the file's header at the frame's size, its palette, its data
		local total = 0
		for _, p in ipairs(f.parts) do
			total += p[2]
		end
		local mini = buffer.create(8 + 25 + (plte and 12 + plte[2] or 0) + (trns and 12 + trns[2] or 0) + 12 + total + 12)
		buffer.writestring(mini, 0, "\137PNG\r\n\26\n")
		local o = putChunk(mini, 8, "IHDR", b, ihdr, 13)
		buffer.writeu32(mini, 16, bit32.byteswap(f.w))
		buffer.writeu32(mini, 20, bit32.byteswap(f.h))
		if plte then
			o = putChunk(mini, o, "PLTE", b, plte[1], plte[2])
		end
		if trns then
			o = putChunk(mini, o, "tRNS", b, trns[1], trns[2])
		end
		buffer.writeu32(mini, o, bit32.byteswap(total))
		buffer.writestring(mini, o + 4, "IDAT")
		local q = o + 8
		for _, p in ipairs(f.parts) do
			buffer.copy(mini, q, b, p[1], p[2])
			q += p[2]
		end
		buffer.writeu32(mini, q, 0)
		putChunk(mini, q + 4, "IEND", mini, 0, 0)
		local img = Png.decode(mini, options)
		local src = img.data
		local dispose = f.dispose
		if i == 1 and dispose == 2 then
			dispose = 1
		end
		local saved
		if dispose == 2 then
			saved = buffer.create(f.w * f.h * 4)
			for r = 0, f.h - 1 do
				buffer.copy(saved, r * f.w * 4, canvas, ((f.y + r) * W + f.x) * 4, f.w * 4)
			end
		end
		-- draw: replace (SOURCE) or alpha-composite (OVER) the region
		for r = 0, f.h - 1 do
			local so = r * f.w * 4
			local d = ((f.y + r) * W + f.x) * 4
			if f.blend == 0 or i == 1 then
				buffer.copy(canvas, d, src, so, f.w * 4)
			else
				for c = 0, f.w - 1 do
					local s4, d4 = so + c * 4, d + c * 4
					local sa = buffer.readu8(src, s4 + 3)
					if sa == 255 then
						buffer.writeu32(canvas, d4, buffer.readu32(src, s4))
					elseif sa > 0 then
						local da = buffer.readu8(canvas, d4 + 3)
						local a = sa * 255 + da * (255 - sa) -- (out alpha x 255)
						for k = 0, 2 do
							local v = (buffer.readu8(src, s4 + k) * sa * 255 + buffer.readu8(canvas, d4 + k) * da * (255 - sa)) / a
							buffer.writeu8(canvas, d4 + k, math.floor(v + 0.5))
						end
						buffer.writeu8(canvas, d4 + 3, math.floor(a / 255 + 0.5))
					end
				end
			end
		end
		local snap = buffer.create(W * H * 4)
		buffer.copy(snap, 0, canvas)
		if not hasAlpha then
			for k = 3, W * H * 4 - 1, 4 do
				if buffer.readu8(snap, k) < 255 then
					hasAlpha = true
					break
				end
			end
		end
		-- browsers show delays of 10 ms and under as 100 ms
		table.insert(out, { data = snap, delay = f.delay <= 0.01 and 0.1 or f.delay })
		if dispose == 1 then
			for r = 0, f.h - 1 do
				buffer.fill(canvas, ((f.y + r) * W + f.x) * 4, 0, f.w * 4)
			end
		elseif dispose == 2 then
			for r = 0, f.h - 1 do
				buffer.copy(canvas, ((f.y + r) * W + f.x) * 4, saved, r * f.w * 4, f.w * 4)
			end
		end
	end
	return { width = W, height = H, frames = out, hasAlpha = hasAlpha, loop = loop ~= false }
end

return Png
