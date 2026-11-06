--!native
--!optimize 2
-- A picture made of GUI strips. Each strip is one Frame with a UIGradient: up to 20 colour keypoints along a row (or
-- a column), blended linearly by Roblox. Strips come from a pool: a strip that is no longer needed is hidden and
-- reused, never destroyed while the canvas lives (making and destroying instances strains phones and Studio).
--
--   local canvas = Canvas.new(parent, width, height, options)
--       options: Size, Position, AnchorPoint (the canvas Frame; default fills the parent, aspect kept), ZIndex,
--                Background (Color3 behind the picture, nil = none)
--   canvas.Frame                                   -- the container (clips its strips)
--   local s = canvas:acquire()  canvas:release(s)  -- a strip object from the pool
--   canvas:set(s, columns, line, line1, kp, col, m, ox, oy, openA?, openB?)
--       kp[1..m]: keypoint positions along the line (canvas coordinates), col: r, g, b per keypoint (0..255),
--       line .. line1: the rows (or columns) it covers; ox, oy: the canvas offset (picture x = canvas x - ox)
--       openA / openB: no neighbouring strip shares that end pixel (next to transparency): reach the pixel's edge
--   canvas:recolour(s, col, m)                      -- same shape, new colours (one property write)
--   canvas:setOffset(ox, oy)                         -- slide the whole picture (one property write)
--   canvas:prewarm(n)                                -- make n pooled strips ahead of use
--   canvas:count() -> strips in use, pooled
--   canvas:destroy()
--   canvas.gradients                                 -- strips of this canvas drawn with a gradient
--   Canvas.gradientsUsed() -> strips of all canvases drawn with a gradient
--
-- Drawing (Render.Shapes there): see "Shared shapes" below; without Shapes, the older scheme:
-- Roblox draws only about a thousand UIGradients at a time (all GUIs together); past that it draws them as their plain
-- white Frame. So at most Canvas.MaxGradients strips (all canvases) use one; a strip past that is drawn in one colour
-- (the mean of its keypoints) until room frees up. Players keep their own use well under it (they raise Tolerance).
-- With a ramp image (Config.RampImage: white, transparent at the left to opaque at the right) a strip can instead be
-- drawn as ImageLabels, one per pair of neighbouring keypoints: background = the first colour, image tinted the second,
-- which is the same blend without using the budget. Then short strips (2 - 3 keypoints) always use the ramp, longer ones
-- use a gradient while there is room and the ramp after that, so nothing is drawn flat for lack of gradients.

local Canvas = {}
Canvas.__index = Canvas

-- (well under the ~1000 Roblox draws: a video replaces hundreds of gradients a frame, and the old ones are still counted
-- for a moment, so a budget close to the limit flickers white strips)
-- (The limit is on DIFFERENT gradients: identical ColorSequences are shared by the engine, so 1500 gradients sharing
-- 16 ColorSequences all draw, while 1500 each with its own colours draw ~1000 and the rest white.)
-- With the shared shapes (Render.Shapes) only the strips they would draw worst get a gradient of their own, at most
-- Canvas.MaxGradients of them; the shapes add at most Shapes.Slots (640) more, and the gradients being replaced this frame
-- (MaxGradientChanges + Shapes.MaxNewPerFrame) are still counted for a moment: together under the ~1000.
-- (The ~1000 is one allowance for every SurfaceGui together, not one per SurfaceGui; ScreenGuis
-- seem to have their own.) Videos give every strip a gradient of its own (no shared shapes: ~900 objects for a 240p
-- picture instead of ~5700); the player keeps its strip count under its share of this.
Canvas.MaxGradients = 880
local gradUsed = 0 -- strips (all canvases) drawn with a UIGradient of their own
-- Videos come first: still pictures (sprays, pictures in GUIs; every canvas not made with options.Video) share at most
-- Canvas.MaxStaticGradients between them, so a few detailed sprays can't starve a TV
Canvas.MaxStaticGradients = 160
local staticUsed = 0

function Canvas.gradientsUsed()
	return gradUsed
end

-- Roblox still counts a replaced gradient for a moment, so many gradients (re)coloured at once (a scene cut, sprays
-- coming into view as you move) went past its limit for a frame and those strips flashed white. At most
-- Canvas.MaxGradientChanges gradients change per frame, across every canvas; past that a strip uses the ramp image for
-- now and goes back to a gradient on a later frame (without the ramp image there is no cap).
Canvas.MaxGradientChanges = 120
local frameNo, churnFrame, churn = 0, -1, 0

-- Videos: a gradient replaced this frame still counts against the limit with its new one (a rotating picture replaced
-- ~600 of ~780 gradients in one frame: white strips). Players keep live gradients + this frame's replacements under
-- Canvas.DrawLimit (Canvas.videoChurn), and spread the rest of a video frame over the next screen frames.
Canvas.DrawLimit = 940
local vFrame, vChurn, vTotal = -1, 0, 0
-- (counted per DRAWN frame: an unfocused Studio / client draws far fewer frames than it runs scripts, and every
-- replacement between two drawn frames counts at once: white strips whenever the window lost focus)
local renderNo, byRender = 0, false
pcall(function()
	local RS = game:GetService("RunService")
	if RS:IsClient() and RS:IsRunning() then
		byRender = true
		RS.RenderStepped:Connect(function()
			renderNo += 1
		end)
	end
end)
-- the drawn frame now (the script frame where nothing is drawn: Edit mode, a server)
function Canvas.renderFrame()
	return byRender and renderNo or frameNo
end
function Canvas.videoChurn()
	return vFrame == Canvas.renderFrame() and vChurn or 0
end
function Canvas.videoChangesTotal()
	return vTotal
end

-- Shared shapes (Render.Shapes): a strip is drawn as one or a few "cells", each a Frame tinted with the strip's colour
-- times one of the shared gradient shapes (Roblox multiplies a gradient's colours with its frame's), so any number of
-- strips use at most Shapes.Slots different gradients (a pool that follows what is shown: Render.Shapes). Cells are runs of keypoints a 12-point evenly spaced shape follows within
-- Canvas.ShareTolerance. A strip whose shapes miss its colours by more than Canvas.exactThreshold (squared error summed
-- over its pixels) gets a gradient of its own while there is room; the threshold follows the demand so the own
-- gradients stay near Canvas.MaxGradients. (The ramp pieces would take one ImageLabel per keypoint
-- pair: ~15000 objects for a 240p video; the cells are ~3000 Frames.)
-- (Off by default: matching every strip to a shape costs most of a TV's script time and its cells ~5000 objects,
-- while exact gradients under the budget draw as sharp with ~900. USE_SHAPES = true turns them on.)
local USE_SHAPES = false
local Shapes = nil
if USE_SHAPES then
	local ok, m = pcall(function()
		return require(script.Parent:WaitForChild("Shapes", 5))
	end)
	Shapes = ok and m or nil
end
Canvas.Shared = Shapes ~= nil
local SP = Shapes and Shapes.P or 12
Canvas.ShareTolerance = 20
Canvas.exactThreshold = 4000
pcall(function()
	game:GetService("RunService").Heartbeat:Connect(function()
		frameNo += 1
		if gradUsed > Canvas.MaxGradients * 0.9 then
			Canvas.exactThreshold = math.min(Canvas.exactThreshold * 1.05, 1e8)
		elseif gradUsed < Canvas.MaxGradients * 0.75 then
			Canvas.exactThreshold = math.max(Canvas.exactThreshold * 0.98, 200)
		end
	end)
end)

local RAMP, rampChecked = nil, false
function Canvas.rampImage()
	if not rampChecked then
		rampChecked = true
		local root = script:FindFirstAncestor("FrameLab")
		local ok, Config = pcall(function()
			return require(game:GetService("ReplicatedStorage"):WaitForChild("LabHub"):WaitForChild("Config"))
		end)
		local v = ok and Config.RampImage
		RAMP = (type(v) == "string" and v ~= "") and v or nil
	end
	return RAMP
end

local WHITE = Color3.new(1, 1, 1)
local fromRGB = Color3.fromRGB
local Keypoint = ColorSequenceKeypoint.new

function Canvas.new(parent, width, height, options)
	options = options or {}
	local self = setmetatable({}, Canvas)
	self.width, self.height = width, height
	local frame = Instance.new("Frame")
	frame.Name = options.Name or "FrameLabCanvas"
	frame.BorderSizePixel = 0
	frame.ClipsDescendants = true
	frame.Size = options.Size or UDim2.fromScale(1, 1)
	frame.Position = options.Position or UDim2.fromScale(0.5, 0.5)
	frame.AnchorPoint = options.AnchorPoint or Vector2.new(0.5, 0.5)
	frame.ZIndex = options.ZIndex or 1
	if options.Background then
		frame.BackgroundColor3 = options.Background
		frame.BackgroundTransparency = 0
	else
		frame.BackgroundTransparency = 1
	end
	if options.KeepAspect ~= false then
		local ar = Instance.new("UIAspectRatioConstraint")
		ar.AspectRatio = width / height
		ar.Parent = frame
	end
	local board = Instance.new("Frame")
	board.Name = "Board"
	board.BackgroundTransparency = 1
	board.BorderSizePixel = 0
	board.Size = UDim2.fromScale(1, 1)
	board.ZIndex = frame.ZIndex
	board.Parent = frame
	self.Frame, self.Board = frame, board
	self.pool, self.used, self.gradients = {}, 0, 0
	self.all = {} -- every strip made (the shapes they hold are given back on destroy)
	self.static = options.Video ~= true
	self.zindex = frame.ZIndex
	frame.Parent = parent
	return self
end

local function newStrip(self)
	local f = Instance.new("Frame")
	f.BorderSizePixel = 0
	f.BackgroundColor3 = WHITE
	f.ZIndex = self.zindex
	f.Visible = false
	local g = Instance.new("UIGradient")
	g.Parent = f
	f.Parent = self.Board
	local s = { frame = f, grad = g, mode = nil, columns = nil, owner = self, pieces = nil, shown = 0, cells = nil, cellsShown = 0 }
	table.insert(self.all, s)
	return s
end

function Canvas:prewarm(n, perYield)
	for i = 1, n - #self.pool do
		table.insert(self.pool, newStrip(self))
		if perYield and i % perYield == 0 then
			task.wait()
		end
	end
end

function Canvas:acquire()
	local s = table.remove(self.pool) or newStrip(self)
	s.frame.Visible = true
	self.used += 1
	return s
end

local function leaveMode(s)
	if s.mode == "grad" then
		gradUsed -= 1
		s.owner.gradients -= 1
		if s.owner.static then
			staticUsed -= 1
		end
		s.grad.Enabled = false
	elseif s.mode == "pieces" then
		for i = 1, s.shown do
			s.pieces[i].Visible = false
		end
		s.shown = 0
		s.frame.BackgroundTransparency = 0
	elseif s.mode == "shared" then
		for i = 1, s.cellsShown do
			local cell = s.cells[i]
			cell.frame.Visible = false
			Shapes.drop(cell.seq) -- (the shape may now be given to another profile)
			cell.seq = 0
		end
		s.cellsShown = 0
		s.frame.BackgroundTransparency = 0
	elseif s.mode == "shared1" then
		s.grad.Enabled = false
		if s.own then
			Shapes.drop(s.own.seq)
			s.own.seq = 0
		end
	end
	s.mode = nil
end

function Canvas:release(s)
	if s.mode == "grad" or s.mode == "shared" or s.mode == "shared1" then
		leaveMode(s) -- give the gradient / shapes back (the strip is drawn afresh when it is used again)
	end
	s.frame.Visible = false
	table.insert(self.pool, s)
	self.used -= 1
end

function Canvas:count()
	return self.used, #self.pool
end

-- GUI objects this canvas shows (each costs drawing time): strips, their cells and ramp pieces; and by mode
function Canvas:objects()
	local n = 0
	local modes = { grad = 0, shared = 0, shared1 = 0, pieces = 0, flat = 0 }
	for _, s in ipairs(self.all) do
		if s.frame.Visible then
			n += 1
			local m = s.mode or "flat"
			modes[m] = (modes[m] or 0) + 1
			if m == "shared" then
				n += s.cellsShown
			elseif m == "pieces" then
				n += s.shown
			end
		end
	end
	return n, modes
end

function Canvas.shapesInUse()
	return Shapes and Shapes.inUse() or 0
end

-- the ramp ImageLabels of a strip, shown 1 .. n
local function showPieces(s, n)
	local list = s.pieces
	if not list then
		list = {}
		s.pieces = list
	end
	for i = #list + 1, n do
		local l = Instance.new("ImageLabel")
		l.BorderSizePixel = 0
		l.Image = RAMP
		l.ZIndex = s.frame.ZIndex
		l.Visible = false
		l.Parent = s.frame
		list[i] = l
	end
	for i = n + 1, s.shown do
		list[i].Visible = false
	end
	for i = s.shown + 1, n do
		list[i].Visible = true
	end
	s.shown = n
	return list
end

-- colours of a strip: flat (one colour), its own gradient (ColorSequence), shared shapes (cells), or ramp pieces
local kps = table.create(20)
local corner = table.create(20, 0)
local cellBuf = table.create(40, 0)
local cellIdx = table.create(20, 0)
local cellTint = table.create(60, 0)
local cellD, cellTm, cellP = table.create(20, 0), table.create(20, 0), {}
local taken = table.create(20, 0)
-- a cell whose shape misses its colours by more than this (rms, colour units) when no shape could be made for it (the
-- pool is full of shapes in use, or too many were made this frame) makes its strip use the ramp pieces instead: exact,
-- only more objects (a rainbow-like picture has more different blends than the pool holds; it came out grey smears)
Canvas.BadShapeRms = 20
Canvas.PiecesFallback = false
local samp = table.create(36, 0)
local prof = table.create(36, 0)

-- Cells of a strip for the shared shapes: runs of keypoints whose blend a SP-point evenly spaced profile follows within
-- Canvas.ShareTolerance. A corner (a keypoint where the blend changes slope) between two profile points is missed by
-- at most |slope change| x spacing / 4, so a run grows while that stays small enough (one pass over the keypoints).
local function cellsOf(kpT, col, m)
	for k = 2, m - 1 do
		local c = (k - 1) * 3
		local dt1 = math.max(kpT[k] - kpT[k - 1], 1e-5)
		local dt2 = math.max(kpT[k + 1] - kpT[k], 1e-5)
		local d = 0
		for ch = 1, 3 do
			local v = math.abs((col[c + 3 + ch] - col[c + ch]) / dt2 - (col[c + ch] - col[c - 3 + ch]) / dt1)
			if v > d then
				d = v
			end
		end
		corner[k] = d
	end
	local lim = Canvas.ShareTolerance * 4 * (SP - 1)
	local n, i0 = 0, 1
	while i0 < m do
		local j, dmax = i0 + 1, 0
		while j < m do
			local d = math.max(dmax, corner[j])
			if d * (kpT[j + 1] - kpT[i0]) > lim then
				break
			end
			dmax = d
			j += 1
		end
		n += 1
		cellBuf[n * 2 - 1], cellBuf[n * 2] = i0, j
		i0 = j
	end
	return n
end

-- cell [i0, i1] -> shape index, tint (into cellTint at slot n) and its squared error (colour units, per profile point)
local function shapeOf(kpT, col, i0, i1, n)
	local a, e = kpT[i0], kpT[i1]
	local q = i0
	local tr, tg, tb = 1, 1, 1
	for k = 0, SP - 1 do
		local t = a + (e - a) * k / (SP - 1)
		while q < i1 - 1 and kpT[q + 1] < t do
			q += 1
		end
		local t0, t1 = kpT[q], kpT[q + 1]
		local f = (t1 > t0) and math.clamp((t - t0) / (t1 - t0), 0, 1) or 0
		local c = (q - 1) * 3
		local r = col[c + 1] + (col[c + 4] - col[c + 1]) * f
		local g = col[c + 2] + (col[c + 5] - col[c + 2]) * f
		local b = col[c + 3] + (col[c + 6] - col[c + 3]) * f
		samp[k * 3 + 1], samp[k * 3 + 2], samp[k * 3 + 3] = r, g, b
		if r > tr then
			tr = r
		end
		if g > tg then
			tg = g
		end
		if b > tb then
			tb = b
		end
	end
	for k = 0, SP - 1 do
		prof[k * 3 + 1], prof[k * 3 + 2], prof[k * 3 + 3] = samp[k * 3 + 1] / tr, samp[k * 3 + 2] / tg, samp[k * 3 + 3] / tb
	end
	local idx, d = Shapes.match(prof)
	cellIdx[n], cellD[n] = idx, d
	local cp = cellP[n]
	if not cp then
		cp = table.create(SP * 3, 0)
		cellP[n] = cp
	end
	table.move(prof, 1, SP * 3, 1, cp)
	cellTint[n * 3 - 2], cellTint[n * 3 - 1], cellTint[n * 3] = tr, tg, tb
	local tm = math.max(tr, tg, tb)
	cellTm[n] = tm
	return d * tm * tm / 3
end

-- the child frames a strip's cells are drawn with, shown 1 .. n
local function showCells(s, n)
	local list = s.cells
	if not list then
		list = {}
		s.cells = list
	end
	for i = #list + 1, n do
		local f = Instance.new("Frame")
		f.BorderSizePixel = 0
		f.ZIndex = s.frame.ZIndex
		f.Visible = false
		local g = Instance.new("UIGradient")
		g.Parent = f
		f.Parent = s.frame
		list[i] = { frame = f, grad = g, seq = 0, a = -1, e = -1, r = -1, g = -1, b = -1, rot = 0 }
	end
	for i = n + 1, s.cellsShown do
		local cell = list[i]
		cell.frame.Visible = false
		Shapes.drop(cell.seq)
		cell.seq = 0
	end
	for i = s.cellsShown + 1, n do
		list[i].frame.Visible = true
	end
	s.cellsShown = n
	return list
end

local function setTint(f, cell, r, g, b)
	r, g, b = math.floor(r + 0.5), math.floor(g + 0.5), math.floor(b + 0.5)
	if cell.r ~= r or cell.g ~= g or cell.b ~= b then
		cell.r, cell.g, cell.b = r, g, b
		f.BackgroundColor3 = fromRGB(r, g, b)
	end
end

-- draw the cells worked out by cellsOf / shapeOf (n of them)
local function drawShared(s, kpT, n)
	if n == 1 then
		-- one cell: the strip's own frame and gradient
		local own = s.own
		if not own then
			own = { seq = 0, r = -1, g = -1, b = -1 }
			s.own = own
		end
		setTint(s.frame, own, cellTint[1], cellTint[2], cellTint[3])
		local idx = taken[1]
		Shapes.drop(own.seq) -- (taken in paint: a slot kept stays in use)
		if own.seq ~= idx then
			s.grad.Color = Shapes.sequence(idx)
		end
		own.seq = idx
		return
	end
	local list = showCells(s, n)
	local columns = s.columns
	for i = 1, n do
		local cell = list[i]
		local f = cell.frame
		local a, e = kpT[cellBuf[i * 2 - 1]], kpT[cellBuf[i * 2]]
		if cell.a ~= a or cell.e ~= e or cell.cols ~= columns then
			cell.a, cell.e, cell.cols = a, e, columns
			if columns then
				f.Position = UDim2.fromScale(0, a)
				f.Size = UDim2.new(1, 0, e - a, 1)
			else
				f.Position = UDim2.fromScale(a, 0)
				f.Size = UDim2.new(e - a, 1, 1, 0)
			end
			local rot = columns and 90 or 0
			if cell.rot ~= rot then
				cell.rot = rot
				cell.grad.Rotation = rot
			end
		end
		setTint(f, cell, cellTint[i * 3 - 2], cellTint[i * 3 - 1], cellTint[i * 3])
		local idx = taken[i]
		Shapes.drop(cell.seq)
		if cell.seq ~= idx then
			cell.grad.Color = Shapes.sequence(idx)
		end
		cell.seq = idx
	end
end

-- the shapes of the n cells (taken: in use until drawShared hands them on, or given back here); the mode they allow
local function takeCells(s, n)
	local bad = Canvas.BadShapeRms * Canvas.BadShapeRms
	local ok = true
	for i = 1, n do
		local idx, e = Shapes.take(cellP[i], cellTm[i], cellIdx[i], cellD[i])
		taken[i] = idx
		if e > bad then
			ok = false
		end
	end
	-- (the ramp pieces as a fallback for badly matched strips made a cartoon TV ~4700 ImageLabels and 15 fps; now only
	-- with Canvas.PiecesFallback = true: otherwise the nearest shape is used and the pool catches up within a few frames)
	if not ok and Canvas.PiecesFallback and Canvas.rampImage() ~= nil and not s.columns then
		for i = 1, n do
			Shapes.drop(taken[i])
		end
		return "pieces"
	end
	return n == 1 and "shared1" or "shared"
end

local function paint(s, kpT, col, m)
	local r, g, b = col[1], col[2], col[3]
	local flat = true
	for i = 2, m do
		local c = (i - 1) * 3
		if col[c + 1] ~= r or col[c + 2] ~= g or col[c + 3] ~= b then
			flat = false
			break
		end
	end
	local want = "flat"
	local nCells = 0
	if not flat then
		local room = s.mode == "grad"
			or (gradUsed < Canvas.MaxGradients and not (s.owner.static and staticUsed >= Canvas.MaxStaticGradients))
		if Shapes then
			-- shared shapes, unless the strip is among the ones they draw worst and a gradient of its own is free
			nCells = cellsOf(kpT, col, m)
			local err = 0
			for i = 1, nCells do
				err += shapeOf(kpT, col, cellBuf[i * 2 - 1], cellBuf[i * 2], i) * (kpT[cellBuf[i * 2]] - kpT[cellBuf[i * 2 - 1]])
			end
			err *= (s.span or 1) / SP -- ~ squared error summed over the strip's pixels
			local thr = Canvas.exactThreshold
			if room and (err > thr or (s.mode == "grad" and err > thr * 0.5)) then
				want = "grad"
			else
				want = takeCells(s, nCells)
			end
		else
			local ramp = Canvas.rampImage() ~= nil and not s.columns
			if ramp and (m <= 3 or not room) then
				want = "pieces"
			elseif room then
				want = "grad"
			else
				-- no gradient left (and no ramp image): one colour, the mean of the keypoints
				local sr, sg, sb = 0, 0, 0
				for i = 1, m do
					local c = (i - 1) * 3
					sr += col[c + 1]
					sg += col[c + 2]
					sb += col[c + 3]
				end
				r, g, b = sr // m, sg // m, sb // m
			end
		end
	end
	if want == "grad" then
		if churnFrame ~= frameNo then
			churnFrame, churn = frameNo, 0
		end
		-- (videos: their player keeps its own count; capping their changes sent whole scene cuts to the ramp pieces)
		if churn >= Canvas.MaxGradientChanges and s.owner.static then
			if Shapes then
				want = takeCells(s, nCells)
			elseif Canvas.rampImage() ~= nil and not s.columns then
				want = "pieces"
			end
		end
		if want == "grad" then
			churn += 1
		end
	end
	if want ~= s.mode then
		leaveMode(s)
		if want == "grad" then
			gradUsed += 1
			s.owner.gradients += 1
			if s.owner.static then
				staticUsed += 1
			end
			s.grad.Enabled = true
			s.frame.BackgroundColor3 = WHITE
		elseif want == "pieces" or want == "shared" then
			s.grad.Enabled = false
			s.frame.BackgroundTransparency = 1
		elseif want == "shared1" then
			s.grad.Enabled = true
			if s.own then
				s.own.r = -1 -- (the frame's colour was used otherwise meanwhile)
			end
		else
			s.grad.Enabled = false
		end
		s.mode = want
	end
	if want == "flat" then
		s.frame.BackgroundColor3 = fromRGB(r, g, b)
		return
	end
	if want == "shared" or want == "shared1" then
		drawShared(s, kpT, nCells)
		return
	end
	if want == "pieces" then
		local list = showPieces(s, m - 1)
		for i = 1, m - 1 do
			local pc = list[i]
			local a, e = kpT[i], kpT[i + 1]
			local c = (i - 1) * 3
			pc.Position = UDim2.fromScale(a, 0)
			pc.Size = UDim2.new(e - a, 1, 1, 0)
			pc.BackgroundColor3 = fromRGB(col[c + 1], col[c + 2], col[c + 3])
			pc.ImageColor3 = fromRGB(col[c + 4], col[c + 5], col[c + 6])
		end
		return
	end
	table.clear(kps)
	for i = 1, m do
		local c = (i - 1) * 3
		kps[i] = Keypoint(kpT[i], fromRGB(col[c + 1], col[c + 2], col[c + 3]))
	end
	s.grad.Color = ColorSequence.new(kps)
	if not s.owner.static then
		local now = Canvas.renderFrame()
		if vFrame ~= now then
			vFrame, vChurn = now, 0
		end
		vChurn += 1
		vTotal += 1
	end
end

-- keypoint times of the last set() per strip (recolour reuses them)
function Canvas:set(s, columns, line, line1, kp, col, m, ox, oy, openA, openB)
	local L = columns and self.height or self.width -- length along the strip
	local N = columns and self.width or self.height -- lines
	local o = columns and oy or ox
	local a, b = kp[1], kp[m]
	-- the strip runs from the centre of its first keypoint pixel to the centre of its last (neighbours meet there);
	-- at the picture's edges it reaches the edge
	local x0 = (openA or a - o <= 0) and a or (a + 0.5)
	local x1 = (openB or b - o >= L - 1) and (b + 1) or (b + 0.5)
	if x1 - x0 < 1 then
		x1 = x0 + 1
	end
	local span = x1 - x0
	local t = s.t or table.create(20)
	s.t = t
	local prev = -1
	for i = 1, m do
		local v = (kp[i] + 0.5 - x0) / span
		if i == 1 then
			v = 0
		elseif i == m then
			v = 1
		end
		if v <= prev then
			v = math.min(1, prev + 1e-4)
		end
		t[i] = v
		prev = v
	end
	t[m] = 1
	local p0, p1 = line, line1 + 1
	s.span = span
	if s.columns ~= columns then
		s.grad.Rotation = columns and 90 or 0
		s.columns = columns
	end
	local f = s.frame
	if columns then
		f.Position = UDim2.fromScale(p0 / N, x0 / L)
		f.Size = UDim2.new((p1 - p0) / N, 1, span / L, 1)
	else
		f.Position = UDim2.fromScale(x0 / L, p0 / N)
		f.Size = UDim2.new(span / L, 1, (p1 - p0) / N, 1)
	end
	paint(s, t, col, m)
end

function Canvas:recolour(s, col, m)
	paint(s, s.t, col, m)
end

function Canvas:setOffset(ox, oy)
	self.Board.Position = UDim2.fromScale(-ox / self.width, -oy / self.height)
end

-- a whole still picture (Strips.encode output), built a chunk at a time when yieldEvery is given; alpha: the picture
-- has transparent gaps (strips next to them reach their pixel's edge)
function Canvas:draw(strips, yieldEvery, alpha)
	local columns = strips.orientation == "columns"
	local starts, ends = {}, {}
	if alpha then
		for _, st in ipairs(strips.list) do
			starts[st.line * 65536 + st.kp[1]] = true
			ends[st.line * 65536 + st.kp[#st.kp]] = true
		end
	end
	-- yieldEvery: pause after that many strips, or after 4 ms (a detailed picture drawn with the ramp image creates
	-- thousands of GUI objects; all in one frame would be a visible hitch)
	local t0 = os.clock()
	for i, st in ipairs(strips.list) do
		local s = self:acquire()
		local m = #st.kp
		local openA = alpha and not ends[st.line * 65536 + st.kp[1]]
		local openB = alpha and not starts[st.line * 65536 + st.kp[m]]
		self:set(s, columns, st.line, st.line1, st.kp, st.col, m, 0, 0, openA, openB)
		if yieldEvery and (i % yieldEvery == 0 or os.clock() - t0 > 0.004) then
			task.wait()
			t0 = os.clock()
		end
	end
end

function Canvas:destroy()
	for _, s in ipairs(self.all) do
		if s.mode == "shared" or s.mode == "shared1" then
			leaveMode(s)
		end
	end
	self.all = {}
	gradUsed -= self.gradients
	if self.static then
		staticUsed -= self.gradients
	end
	self.gradients = 0
	self.Frame:Destroy()
	self.pool = {}
end

return Canvas
