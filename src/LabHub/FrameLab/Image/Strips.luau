--!native
--!optimize 2
-- Strip encoder: a picture as GUI strips. A strip is one span of one pixel row (or column) drawn by a Frame whose
-- UIGradient holds up to 20 colour keypoints; Roblox blends linearly between them. Keypoints are chosen so the blend
-- stays within `tol` (0..255) of every pixel, and they sit on pixels (each keypoint colour is that pixel's colour).
--
--   Strips.fitRow(px, base, step, a, b, tol, out)  -> number of keypoints written to out (pixel indices)
--   Strips.fitRowFree(px, base, step, a, b, tol, out, colOut) -> n; keypoint colours free (colOut: r, g, b each)
--   Strips.nextCut(kp, s0, n) -> s1: the strip from keypoint s0 ends at s1 (<= 19 segments; shorter where detail is fine)
--   Strips.encode(image, options) -> strips
--       image: { width, height, data = buffer RGBA }
--       options: Tol (default 12), Merge (true: a strip grows down while the next row still matches), Orientation
--                ("rows" | "columns" | "auto": the one with fewer strips, default)
--       strips = { orientation, width, height, list = { { line, line1, kp = {positions}, col = {r, g, b, ...} } } }
--       (line .. line1 = the rows (or columns) it covers, kp = positions along the line, col = 0..255 per keypoint)

local Strips = {}

Strips.MaxKeypoints = 20

-- Greedy fit of one line from index a to b (inclusive). Pixel i of the line is at byte base + i * step (RGBA).
-- For each segment start i, the slope of the blend towards a candidate end k must keep every pixel in between within
-- tol: each pixel narrows the allowed slope range per channel (a cone), and the segment ends at the last k whose own
-- slope still fits. O(length) per line.
function Strips.fitRow(px, base, step, a, b, tol, out)
	local n = 1
	out[1] = a
	local i = a
	while i < b do
		local o = base + i * step
		local r0, g0, b0 = buffer.readu8(px, o), buffer.readu8(px, o + 1), buffer.readu8(px, o + 2)
		local loR, hiR, loG, hiG, loB, hiB = -math.huge, math.huge, -math.huge, math.huge, -math.huge, math.huge
		local last = i + 1
		local k = i + 1
		while k <= b do
			local p = base + k * step
			local d = k - i
			local vr, vg, vb = buffer.readu8(px, p) - r0, buffer.readu8(px, p + 1) - g0, buffer.readu8(px, p + 2) - b0
			-- k can end the segment if its own slope fits the cone of the pixels before it
			local sr, sg, sb = vr / d, vg / d, vb / d
			if sr >= loR and sr <= hiR and sg >= loG and sg <= hiG and sb >= loB and sb <= hiB then
				last = k
			end
			-- narrow the cone with pixel k (for segments ending further on)
			local t = tol / d
			local l, h = sr - t, sr + t
			if l > loR then
				loR = l
			end
			if h < hiR then
				hiR = h
			end
			l, h = sg - t, sg + t
			if l > loG then
				loG = l
			end
			if h < hiG then
				hiG = h
			end
			l, h = sb - t, sb + t
			if l > loB then
				loB = l
			end
			if h < hiB then
				hiB = h
			end
			if loR > hiR or loG > hiG or loB > hiB then
				break
			end
			k += 1
		end
		n += 1
		out[n] = last
		i = last
	end
	return n
end

-- Like fitRow, but a keypoint's colour may be anything within tol of its pixel (not the pixel's own colour): a segment
-- runs while any blend from its start colour stays inside every pixel's +-tol band, and ends at the middle of what is
-- left. Same accuracy with ~20% fewer keypoints (Monkey Watch, 240p: the strip budget fits at tolerance 22 instead
-- of 29, so thin curves smear less). colOut gets whole numbers 0..255.
function Strips.fitRowFree(px, base, step, a, b, tol, out, colOut)
	local readu8 = buffer.readu8
	local o = base + a * step
	local r0, g0, b0 = readu8(px, o), readu8(px, o + 1), readu8(px, o + 2)
	out[1] = a
	colOut[1], colOut[2], colOut[3] = r0, g0, b0
	local n = 1
	local i = a
	local t0 = math.max(tol - 0.5, 0) -- (room for rounding the colours)
	while i < b do
		local loR, hiR, loG, hiG, loB, hiB = -math.huge, math.huge, -math.huge, math.huge, -math.huge, math.huge
		local k = i + 1
		while k <= b do
			local p = base + k * step
			local d = k - i
			local vr, vg, vb = readu8(px, p), readu8(px, p + 1), readu8(px, p + 2)
			local l1, h1 = (vr - t0 - r0) / d, (vr + t0 - r0) / d
			local l2, h2 = (vg - t0 - g0) / d, (vg + t0 - g0) / d
			local l3, h3 = (vb - t0 - b0) / d, (vb + t0 - b0) / d
			if l1 < loR then l1 = loR end
			if h1 > hiR then h1 = hiR end
			if l2 < loG then l2 = loG end
			if h2 > hiG then h2 = hiG end
			if l3 < loB then l3 = loB end
			if h3 > hiB then h3 = hiB end
			if l1 > h1 or l2 > h2 or l3 > h3 then
				break
			end
			loR, hiR, loG, hiG, loB, hiB = l1, h1, l2, h2, l3, h3
			k += 1
		end
		local e = k - 1
		local d = e - i
		r0 = math.clamp(math.floor(r0 + (loR + hiR) * 0.5 * d + 0.5), 0, 255)
		g0 = math.clamp(math.floor(g0 + (loG + hiG) * 0.5 * d + 0.5), 0, 255)
		b0 = math.clamp(math.floor(b0 + (loB + hiB) * 0.5 * d + 0.5), 0, 255)
		n += 1
		out[n] = e
		colOut[n * 3 - 2], colOut[n * 3 - 1], colOut[n * 3] = r0, g0, b0
		i = e
	end
	return n
end

-- Roblox draws a gradient from a texture of limited width: in a strip 800 pixels long a 1-pixel dark line vanishes and a
-- 2-pixel one is faint, while short strips show them. So a strip ends early when its span would pass
-- Strips.DetailSpan x its shortest segment (fine detail stays in short strips; smooth rows keep long ones).
Strips.DetailSpan = 256
function Strips.nextCut(kp, s0, n)
	local MAXK = Strips.MaxKeypoints
	local K = Strips.DetailSpan
	local s1 = s0 + 1
	if s1 > n then
		return n
	end
	local minSeg = kp[s1] - kp[s0]
	while s1 < n and s1 - s0 < MAXK - 1 do
		local seg = kp[s1 + 1] - kp[s1]
		local m2 = seg < minSeg and seg or minSeg
		if kp[s1 + 1] - kp[s0] > K * math.max(m2, 1) then
			break
		end
		minSeg = m2
		s1 += 1
	end
	return s1
end

-- strips a row fitted into n keypoints takes (nextCut)
function Strips.countStrips(kp, n)
	local c, s0 = 0, 1
	while s0 < n do
		s0 = Strips.nextCut(kp, s0, n)
		c += 1
	end
	return math.max(c, 1)
end

-- does the strip (positions kp[1..m], colours col) still draw line `line` within tol?
local function fits(px, base, step, kp, col, m, tol)
	for s = 1, m - 1 do
		local x0, x1 = kp[s], kp[s + 1]
		local c = (s - 1) * 3
		local r0, g0, b0 = col[c + 1], col[c + 2], col[c + 3]
		local dr, dg, db = col[c + 4] - r0, col[c + 5] - g0, col[c + 6] - b0
		local inv = 1 / (x1 - x0)
		for x = x0, x1 do
			local t = (x - x0) * inv
			local p = base + x * step
			if math.abs(r0 + dr * t - buffer.readu8(px, p)) > tol or math.abs(g0 + dg * t - buffer.readu8(px, p + 1)) > tol
				or math.abs(b0 + db * t - buffer.readu8(px, p + 2)) > tol then
				return false
			end
		end
	end
	return true
end
Strips.fits = fits

local function encodeDir(image, tol, merge, columns)
	local W, H = image.width, image.height
	local alpha = image.hasAlpha == true
	if alpha then
		merge = false
	end
	local px = image.data
	local lines, length, lineStep, step
	if columns then
		lines, length, lineStep, step = W, H, 4, W * 4
	else
		lines, length, lineStep, step = H, W, W * 4, 4
	end
	local MAXK = Strips.MaxKeypoints
	local list = {}
	local active = {} -- strips still growing (merge)
	local kpBuf = table.create(length + 1, 0)
	local colBuf = table.create((length + 1) * 3, 0)
	for line = 0, lines - 1 do
		local base = line * lineStep
		local keep = {}
		if merge then
			for _, s in ipairs(active) do
				if fits(px, base, step, s.kp, s.col, #s.kp, tol) then
					s.line1 = line
					table.insert(keep, s)
				end
			end
		end
		-- positions not covered by a continuing strip get new strips
		table.sort(keep, function(x, y)
			return x.kp[1] < y.kp[1]
		end)
		local spans = {}
		if alpha then
			-- transparent pixels (alpha < 128) get no strip: one span per opaque run
			local x = 0
			while x < length do
				while x < length and buffer.readu8(px, base + x * step + 3) < 128 do
					x += 1
				end
				local a = x
				while x < length and buffer.readu8(px, base + x * step + 3) >= 128 do
					x += 1
				end
				if x > a then
					table.insert(spans, { a, x - 1 })
				end
			end
		else
			local x = 0
			for _, s in ipairs(keep) do
				if s.kp[1] > x then
					table.insert(spans, { x, s.kp[1] })
				end
				x = math.max(x, s.kp[#s.kp])
			end
			if x < length - 1 or #keep == 0 then
				table.insert(spans, { (#keep == 0) and 0 or x, length - 1 })
			end
		end
		local fresh = {}
		for _, sp in ipairs(spans) do
			local a, b = sp[1], sp[2]
			local n = Strips.fitRowFree(px, base, step, a, b, tol, kpBuf, colBuf)
			if n == 1 then
				kpBuf[2] = b
				colBuf[4], colBuf[5], colBuf[6] = colBuf[1], colBuf[2], colBuf[3]
				n = 2
			end
			-- cut into strips of at most MAXK keypoints, shorter around fine detail (neighbours share their end keypoint)
			local s0 = 1
			while s0 < n do
				local s1 = Strips.nextCut(kpBuf, s0, n)
				local kp, col = table.create(s1 - s0 + 1), table.create((s1 - s0 + 1) * 3)
				for q = s0, s1 do
					kp[q - s0 + 1] = kpBuf[q]
					local c = (q - s0) * 3
					col[c + 1], col[c + 2], col[c + 3] = colBuf[q * 3 - 2], colBuf[q * 3 - 1], colBuf[q * 3]
				end
				local s = { line = line, line1 = line, kp = kp, col = col }
				table.insert(list, s)
				table.insert(fresh, s)
				s0 = s1
			end
		end
		if merge then
			for _, s in ipairs(fresh) do
				table.insert(keep, s)
			end
			active = keep
		end
	end
	return { orientation = columns and "columns" or "rows", width = W, height = H, list = list }
end

function Strips.encode(image, options)
	options = options or {}
	local tol = options.Tol or 12
	local merge = options.Merge ~= false
	local o = options.Orientation or "auto"
	if o == "rows" then
		return encodeDir(image, tol, merge, false)
	elseif o == "columns" then
		return encodeDir(image, tol, merge, true)
	end
	local r = encodeDir(image, tol, merge, false)
	local c = encodeDir(image, tol, merge, true)
	return (#c.list < #r.list) and c or r
end

-- draw strips back into an RGBA buffer (tests / previews)
function Strips.render(strips)
	local W, H = strips.width, strips.height
	local out = buffer.create(W * H * 4)
	local cols = strips.orientation == "columns"
	for _, s in ipairs(strips.list) do
		local kp, col = s.kp, s.col
		for line = s.line, s.line1 do
			for q = 1, #kp - 1 do
				local x0, x1 = kp[q], kp[q + 1]
				local c = (q - 1) * 3
				for x = x0, x1 do
					local t = (x1 == x0) and 0 or (x - x0) / (x1 - x0)
					local px, py = x, line
					if cols then
						px, py = line, x
					end
					local o = (py * W + px) * 4
					buffer.writeu8(out, o, math.floor(col[c + 1] + (col[c + 4] - col[c + 1]) * t + 0.5))
					buffer.writeu8(out, o + 1, math.floor(col[c + 2] + (col[c + 5] - col[c + 2]) * t + 0.5))
					buffer.writeu8(out, o + 2, math.floor(col[c + 3] + (col[c + 6] - col[c + 3]) * t + 0.5))
					buffer.writeu8(out, o + 3, 255)
				end
			end
		end
	end
	return out
end

return Strips
