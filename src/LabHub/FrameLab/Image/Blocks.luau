--!native
--!optimize 2
-- Block pictures (JPEG's idea for GUI objects): the picture in 8 x 8 blocks, a block cut into four 4 x 4 where 8 x 8 misses
-- by more than Threshold. A block is ONE ImageLabel: background colour A, a pattern from the shared library
-- (Render.Patterns: one uploaded image) tinted colour B, so pixel = A + pattern x (B - A). Flat blocks are plain Frames,
-- and neighbouring flat blocks of one colour become one Frame. No UIGradients at all (no ~1000 limit), no strips (no
-- sideways streaks): a 400-pixel photo is ~3500 objects, a 512 one ~9000.
--
--   local list = Blocks.encode(image, { Threshold = 6, Yield = true }) -> { width, height, count, items = {...} }
--   local view = Blocks.draw(list, parent, { KeepAspect = true, ZIndex }) -> { Frame, destroy = function }
--   Blocks.ready() -> the pattern library is available
--   Blocks.fitBlock(...) / Blocks.errorOf(...) / Blocks.recolor(...): one block's fit, its error, new colours for it

local Blocks = {}

local FrameLab = script:FindFirstAncestor("FrameLab")
local Patterns = require(FrameLab.Render.Patterns)

function Blocks.ready()
	return Patterns.ready()
end

local readu8 = buffer.readu8
local FLAT = 6 -- a block whose colours span less than this (0..255) is one colour

local pr, pg, pb = table.create(64, 0), table.create(64, 0), table.create(64, 0)
local av = table.create(64, 0)

-- fit the BS x BS block at (x0, y0): returns kind ("flat" | "pat"), A r g b, B r g b, pattern index, rms error
-- (stride: pixels per row of data, default W)
local function fitBlock(data, W, H, x0, y0, BS, stride)
	stride = stride or W
	local n = BS * BS
	local mr, mg, mb = 0, 0, 0
	for y = 0, BS - 1 do
		local yy = math.min(y0 + y, H - 1)
		for x = 0, BS - 1 do
			local xx = math.min(x0 + x, W - 1)
			local o = (yy * stride + xx) * 4
			local k = y * BS + x + 1
			local r, g, b = readu8(data, o), readu8(data, o + 1), readu8(data, o + 2)
			pr[k], pg[k], pb[k] = r, g, b
			mr += r
			mg += g
			mb += b
		end
	end
	mr /= n
	mg /= n
	mb /= n
	-- main colour axis (power iteration on the 3x3 covariance)
	local crr, cgg, cbb, crg, crb, cgb = 0, 0, 0, 0, 0, 0
	for k = 1, n do
		local dr, dg, db = pr[k] - mr, pg[k] - mg, pb[k] - mb
		crr += dr * dr
		cgg += dg * dg
		cbb += db * db
		crg += dr * dg
		crb += dr * db
		cgb += dg * db
	end
	local ax, ay, az = 0.577, 0.577, 0.577
	if crr >= cgg and crr >= cbb then
		ax, ay, az = 1, 0.3, 0.3
	elseif cgg >= cbb then
		ax, ay, az = 0.3, 1, 0.3
	else
		ax, ay, az = 0.3, 0.3, 1
	end
	for _ = 1, 8 do
		local nx = crr * ax + crg * ay + crb * az
		local ny = crg * ax + cgg * ay + cgb * az
		local nz = crb * ax + cgb * ay + cbb * az
		local l = math.sqrt(nx * nx + ny * ny + nz * nz)
		if l < 1e-9 then
			break
		end
		ax, ay, az = nx / l, ny / l, nz / l
	end
	local lo, hi = math.huge, -math.huge
	for k = 1, n do
		local t = (pr[k] - mr) * ax + (pg[k] - mg) * ay + (pb[k] - mb) * az
		av[k] = t
		if t < lo then lo = t end
		if t > hi then hi = t end
	end
	if hi - lo < FLAT then
		local se = 0
		for k = 1, n do
			local dr, dg, db = pr[k] - mr, pg[k] - mg, pb[k] - mb
			se += dr * dr + dg * dg + db * db
		end
		return "flat", mr, mg, mb, mr, mg, mb, 0, math.sqrt(se / (3 * n))
	end
	local inv = 15 / (hi - lo)
	for k = 1, n do
		av[k] = (av[k] - lo) * inv
	end
	local idx = Patterns.match(BS, av)
	-- least-squares colours for pixel = A + p (B - A)
	local sp, spp, sr, sg, sb, spr, spg, spb = 0, 0, 0, 0, 0, 0, 0, 0
	for k = 1, n do
		local p = Patterns.value(BS, idx, k) / 15
		av[k] = p
		sp += p
		spp += p * p
		sr += pr[k]
		sg += pg[k]
		sb += pb[k]
		spr += p * pr[k]
		spg += p * pg[k]
		spb += p * pb[k]
	end
	local det = n * spp - sp * sp
	if math.abs(det) < 1e-6 then
		det = 1e-6
	end
	local Ar = math.clamp((spp * sr - sp * spr) / det, 0, 255)
	local Ag = math.clamp((spp * sg - sp * spg) / det, 0, 255)
	local Ab = math.clamp((spp * sb - sp * spb) / det, 0, 255)
	local Br = math.clamp(Ar + (n * spr - sp * sr) / det, 0, 255)
	local Bg = math.clamp(Ag + (n * spg - sp * sg) / det, 0, 255)
	local Bb = math.clamp(Ab + (n * spb - sp * sb) / det, 0, 255)
	local se = 0
	for k = 1, n do
		local p = av[k]
		local er, eg, eb = Ar + p * (Br - Ar) - pr[k], Ag + p * (Bg - Ag) - pg[k], Ab + p * (Bb - Ab) - pb[k]
		se += er * er + eg * eg + eb * eb
	end
	return "pat", Ar, Ag, Ab, Br, Bg, Bb, idx, math.sqrt(se / (3 * n))
end

Blocks.fitBlock = fitBlock

-- new colours for a block keeping its pattern (idx; -1: one colour): A r g b, B r g b, rms error. Much cheaper than
-- fitBlock (no pattern search): a block whose shape still fits only changes colour
function Blocks.recolor(data, W, H, x0, y0, BS, stride, idx)
	stride = stride or W
	local n = BS * BS
	local sp, spp, sr, sg, sb, spr, spg, spb = 0, 0, 0, 0, 0, 0, 0, 0
	for y = 0, BS - 1 do
		local yy = math.min(y0 + y, H - 1)
		for x = 0, BS - 1 do
			local xx = math.min(x0 + x, W - 1)
			local o = (yy * stride + xx) * 4
			local k = y * BS + x + 1
			local r, g, b = readu8(data, o), readu8(data, o + 1), readu8(data, o + 2)
			pr[k], pg[k], pb[k] = r, g, b
			local p = (idx >= 0) and Patterns.value(BS, idx, k) / 15 or 0
			av[k] = p
			sp += p
			spp += p * p
			sr += r
			sg += g
			sb += b
			spr += p * r
			spg += p * g
			spb += p * b
		end
	end
	local Ar, Ag, Ab, Br, Bg, Bb
	if idx < 0 then
		Ar, Ag, Ab = sr / n, sg / n, sb / n
		Br, Bg, Bb = Ar, Ag, Ab
	else
		local det = n * spp - sp * sp
		if math.abs(det) < 1e-6 then
			det = 1e-6
		end
		Ar = math.clamp((spp * sr - sp * spr) / det, 0, 255)
		Ag = math.clamp((spp * sg - sp * spg) / det, 0, 255)
		Ab = math.clamp((spp * sb - sp * spb) / det, 0, 255)
		Br = math.clamp(Ar + (n * spr - sp * sr) / det, 0, 255)
		Bg = math.clamp(Ag + (n * spg - sp * sg) / det, 0, 255)
		Bb = math.clamp(Ab + (n * spb - sp * sb) / det, 0, 255)
	end
	local se = 0
	for k = 1, n do
		local p = av[k]
		local er, eg, eb = Ar + p * (Br - Ar) - pr[k], Ag + p * (Bg - Ag) - pg[k], Ab + p * (Bb - Ab) - pb[k]
		se += er * er + eg * eg + eb * eb
	end
	return Ar, Ag, Ab, Br, Bg, Bb, math.sqrt(se / (3 * n))
end

-- rms error of a drawn block (pattern idx, or -1 for one colour A) against the picture at (x0, y0)
function Blocks.errorOf(data, W, H, x0, y0, BS, stride, idx, ar, ag, ab, br, bg, bb)
	local se = 0
	for y = 0, BS - 1 do
		local yy = math.min(y0 + y, H - 1)
		for x = 0, BS - 1 do
			local xx = math.min(x0 + x, W - 1)
			local o = (yy * stride + xx) * 4
			local p = (idx >= 0) and Patterns.value(BS, idx, y * BS + x + 1) / 15 or 0
			local er = ar + p * (br - ar) - readu8(data, o)
			local eg = ag + p * (bg - ag) - readu8(data, o + 1)
			local eb = ab + p * (bb - ab) - readu8(data, o + 2)
			se += er * er + eg * eg + eb * eb
		end
	end
	return math.sqrt(se / (3 * BS * BS))
end

function Blocks.encode(image, options)
	options = options or {}
	local T = options.Threshold or 6
	local W, H, data = image.width, image.height, image.data
	local items = {}
	local t0 = os.clock()
	local pending -- a run of flat 8x8 blocks of one colour (one Frame)
	local function flush()
		if pending then
			table.insert(items, pending)
			pending = nil
		end
	end
	for by = 0, (H - 1) // 8 do
		for bx = 0, (W - 1) // 8 do
			local x0, y0 = bx * 8, by * 8
			local kind, ar, ag, ab, br, bg, bb, idx, e = fitBlock(data, W, H, x0, y0, 8)
			if e <= T then
				if kind == "flat" then
					local r, g, b = math.floor(ar + 0.5), math.floor(ag + 0.5), math.floor(ab + 0.5)
					if pending and pending.y == y0 and pending.x + pending.w == x0 and math.abs(pending.r - r) <= 2
						and math.abs(pending.g - g) <= 2 and math.abs(pending.b - b) <= 2 then
						pending.w += 8
					else
						flush()
						pending = { flat = true, x = x0, y = y0, w = 8, h = 8, r = r, g = g, b = b }
					end
				else
					flush()
					table.insert(items, { x = x0, y = y0, s = 8, a = { ar, ag, ab }, b = { br, bg, bb }, idx = idx })
				end
			else
				flush()
				for q = 0, 3 do
					local sx, sy = x0 + (q % 2) * 4, y0 + (q // 2) * 4
					if sx < W and sy < H then
						local k2, r1, g1, b1, r2, g2, b2, i2 = fitBlock(data, W, H, sx, sy, 4)
						if k2 == "flat" then
							table.insert(items, { flat = true, x = sx, y = sy, w = 4, h = 4, r = r1, g = g1, b = b1 })
						else
							table.insert(items, { x = sx, y = sy, s = 4, a = { r1, g1, b1 }, b = { r2, g2, b2 }, idx = i2 })
						end
					end
				end
			end
			if options.Yield and os.clock() - t0 > 0.008 then
				task.wait()
				t0 = os.clock()
			end
		end
		flush()
	end
	return { width = W, height = H, count = #items, items = items }
end

local fromRGB = Color3.fromRGB

function Blocks.draw(list, parent, options)
	options = options or {}
	local W, H = list.width, list.height
	local frame = Instance.new("Frame")
	frame.Name = "FrameLabBlocks"
	frame.BackgroundTransparency = 1
	frame.BorderSizePixel = 0
	frame.ClipsDescendants = true
	frame.Size = UDim2.fromScale(1, 1)
	frame.AnchorPoint = Vector2.new(0.5, 0.5)
	frame.Position = UDim2.fromScale(0.5, 0.5)
	if options.KeepAspect ~= false then
		local ar = Instance.new("UIAspectRatioConstraint")
		ar.AspectRatio = W / H
		ar.Parent = frame
	end
	local img = Patterns.image()
	local z = options.ZIndex or 1
	local t0 = os.clock()
	local view = { Frame = frame, alive = true }
	function view.destroy()
		view.alive = false
		frame:Destroy()
	end
	frame.Parent = parent
	-- (built a chunk at a time: ~9000 objects at once would hitch)
	local chunk = Instance.new("Folder")
	for i, it in ipairs(list.items) do
		if not view.alive then
			return view
		end
		local o
		if it.flat then
			o = Instance.new("Frame")
			o.BackgroundColor3 = fromRGB(it.r, it.g, it.b)
			o.Position = UDim2.fromScale(it.x / W, it.y / H)
			o.Size = UDim2.new(it.w / W, 1, it.h / H, 1)
		else
			o = Instance.new("ImageLabel")
			o.BackgroundColor3 = fromRGB(it.a[1], it.a[2], it.a[3])
			o.ImageColor3 = fromRGB(it.b[1], it.b[2], it.b[3])
			o.Image = img
			o.ImageRectOffset = Patterns.rect(it.s, it.idx)
			o.ImageRectSize = Vector2.new(it.s, it.s)
			o.Position = UDim2.fromScale(it.x / W, it.y / H)
			o.Size = UDim2.new(it.s / W, 1, it.s / H, 1)
		end
		o.BorderSizePixel = 0
		o.ZIndex = z
		o.Parent = chunk
		if i % 800 == 0 then
			for _, c in ipairs(chunk:GetChildren()) do
				c.Parent = frame
			end
			if os.clock() - t0 > 0.006 then
				task.wait()
				t0 = os.clock()
			end
		end
	end
	for _, c in ipairs(chunk:GetChildren()) do
		c.Parent = frame
	end
	chunk:Destroy()
	return view
end

return Blocks
