--!native
--!optimize 2
-- FrameLab video player. The stream (Video.Stream) gives the picture; the player fits GUI strips to it at runtime and
-- updates only the strips the new frame broke, so its quality settings can change while it plays:
--
--   player.Tolerance   how far (0..255) a strip may stray from the picture before it is redrawn (lower = sharper)
--   player.Budget      most strip updates per video frame (the rest catch up over the next frames)
--   player.MaxFps      frames per second shown (at most the video's, at most 24; with AutoQuality a half or a third of
--                      that while the device can't finish its pictures in time)
--   player.AutoQuality true: Tolerance and Budget follow the device (keeps the player's work near TargetMs per frame)
--   player.TargetMs    work per screen frame the auto quality aims for (default 3 ms)
--   player.MaxGradients most strips drawn with a gradient (Roblox draws about a thousand at once, all GUIs together:
--                      Canvas.MaxGradients); past it the player draws coarser (raises Tolerance) and refits the rows cut
--                      into the most strips (default 820). Every strip has a gradient of its own, so this is the strip
--                      budget; the Tolerance is picked for it before the first picture and at every cut / jump.
--   FLV2 videos (the small-file codec) are decoded here too; with AutoQuality a device that can't keep up skips the
--   droppable half of the frames (12 fps) until it can again, and MaxFps 12 or less always skips them. A video kept
--   at several sizes plays at the one Video.Stream picks for the device (options.Rendition: a given one); on a device
--   without native code the colour is worked out without the chroma blend (options.FastColour). An FLV2 video is
--   decoded on a worker thread a second ahead of the picture (Video.AsyncReader; options.Parallel = false: not).
--
-- Paced: a picture is finished and shown before the next one starts (the frames the clock passed meanwhile are skipped),
-- and with the block player a picture worked out over several screen frames is shown all at once, never its new top
-- over its old bottom.
--
-- A whole-picture move in the stream (a camera pan) slides the canvas with one write; only the uncovered edge is
-- drawn. Strip objects come from a pool and are never destroyed while the video plays.
--
--   local p = Player.new(streamBytes, parent, { Loop, Clock = function() -> seconds, Tolerance, Budget, MaxFps, ... })
--       (options.Reader: a reader of your own instead, e.g. Video.DirectReader for a stream this client decodes)
--   p:play() / p:pause() / p:resume() / p:stop() / p:seek(seconds) / p:destroy()
--   p:getTime(), p.Duration, p.Ended (event), p.Stats (strips, updates, ms, behind)

local FrameLab = script:FindFirstAncestor("FrameLab")
local Stream = require(FrameLab.Video.Stream)
local Strips = require(FrameLab.Image.Strips)
local Canvas = require(FrameLab.Render.Canvas)
local BlockGrid = require(FrameLab.Render.BlockGrid)
local okBlocks, Blocks = pcall(require, FrameLab.Image.Blocks)
Blocks = okBlocks and Blocks or nil

local RunService = game:GetService("RunService")
local EncodingService = game:GetService("EncodingService")
local UIS = game:GetService("UserInputService")

local Player = {}
Player.__index = Player

local MAXK = Strips.MaxKeypoints
local KEEP = 1.3 -- a strip within KEEP x Tolerance stays as it is (fewer redraws of noise)

local function decompress(buf)
	return EncodingService:DecompressBuffer(buf, Enum.CompressionAlgorithm.Zstd)
end

function Player.new(bytes, parent, options)
	options = options or {}
	local self = setmetatable({}, Player)
	local reader = options.Reader or Stream.reader(bytes, { Decompress = decompress, Ready = options.Ready, ChunkData = options.ChunkData,
		Rendition = options.Rendition })
	self.reader = reader
	-- (FLV2 on a device without native code: colour without the chroma blend, half the colour work)
	if options.FastColour ~= nil then
		reader.FastColour = options.FastColour
	else
		reader.FastColour = Stream.benchmark() > 3.5
	end
	-- an FLV2 video decodes on a worker thread, ahead of the picture (Video.AsyncReader; options.Parallel = false: on the
	-- game's own thread), so the game's frames keep only the drawing (and the sound's timing doesn't wait on decoding)
	local parallel = options.Parallel ~= false
	if parallel and reader.codec == "FLV2" then
		local AsyncReader = require(FrameLab.Video.AsyncReader)
		if AsyncReader.available() then
			reader = AsyncReader.wrap(reader, options) or reader
			self.reader = reader
		end
	end
	self.W, self.H = reader.width, reader.height
	self.fps = reader.fps
	self.Duration = reader.duration
	-- the block player (Render.BlockGrid: 8x8 blocks from the pattern library) when the library is in place, else strips
	if options.Blocks ~= false and Blocks and Blocks.ready() then
		self.blocks = true
		self.canvas = BlockGrid.new(parent, self.W, self.H, options)
	else
		self.canvas = Canvas.new(parent, self.W, self.H, setmetatable({ Video = true }, { __index = options })) -- videos first (Canvas)
	end
	self.BlockSkip = options.BlockSkip or 5 -- a block stays as drawn while it misses the new picture by at most this (rms)
	-- an 8x8 block missing by more than BlockSplit is tried as four 4x4 (text, outlines); at most MaxSplits at once
	self.BlockSplit = options.BlockSplit or 6
	self.MaxSplits = options.MaxSplits or ((UIS.TouchEnabled and not UIS.KeyboardEnabled) and 300 or 1200)
	local phone = UIS.TouchEnabled and not UIS.KeyboardEnabled
	self.Tolerance = options.Tolerance or 6
	self.MinTolerance = options.MinTolerance or self.Tolerance
	self.MaxTolerance = options.MaxTolerance or 40
	self.Budget = options.Budget or (phone and 120 or 300)
	self.MaxBudget = options.MaxBudget or (phone and 250 or 600)
	self.MaxFps = math.min(options.MaxFps or 24, reader.fps, 24)
	self.Batch = options.Batch ~= false -- redraw once per video frame (see step)
	self.AutoQuality = options.AutoQuality ~= false
	-- (PC 6 ms: at 3 the auto quality kept trading sharpness for time and a TV drifted to tolerance 20 - 40, a smear)
	self.TargetMs = options.TargetMs or (phone and 3 or 6)
	self.Loop = options.Loop == true
	self.Clock = options.Clock
	self.MaxGradients = options.MaxGradients or 820
	-- (the share then follows how many gradients the picture replaces per screen frame: see step)
	self.GradientCeiling = self.MaxGradients
	self.churnCap = math.huge
	-- with the ramp image (no gradient limit) the strip count is kept near this instead: each strip is work when the
	-- picture changes, and a whole new picture should be drawn in one frame
	self.MaxStrips = options.MaxStrips or (phone and 900 or 3000)
	self.gradFloor = 0 -- lowest Tolerance while the gradients are short
	self.refit = {} -- [image row] = true: fit the whole row afresh
	self.rows = {} -- [canvas row] = { strip records sorted by first keypoint }
	self.ox, self.oy = 0, 0
	self.dirty, self.queue = {}, {}
	self.kpBuf = table.create(self.W + 2, 0)
	self.colBuf = table.create((self.W + 2) * 3, 0)
	self.Stats = { strips = 0, updates = 0, ms = 0, behind = 0, frame = -1, decodeMs = 0, halfRate = false }
	self.emaMs = 0
	self.decodeEma = 0
	self.pending = {} -- block changes worked out but not shown yet (see workBlocks)
	self.fitPend = {} -- blocks a reader worked out itself (info.fits: cell -> its fit), shown together
	self.FpsCap = self.MaxFps
	self.endedEvent = Instance.new("BindableEvent")
	self.Ended = self.endedEvent.Event
	self.playing = false
	self.timeOffset = 0
	return self
end

-- image row y needs work
local function markRow(self, y)
	if y >= 0 and y < self.H and not self.dirty[y] then
		self.dirty[y] = true
		table.insert(self.queue, y)
	end
end

local function markAll(self)
	-- (every row is worked out again: block changes not shown yet are dropped)
	if self.pending then
		table.clear(self.pending)
	end
	if self.reader and self.reader.fits then
		table.clear(self.fitPend) -- (its next picture comes with every block)
		self.fitDirty = false
		return
	end
	for y = 0, self.H - 1 do
		markRow(self, y)
	end
end

-- does strip rec still draw image row (base) within tol? keypoints are canvas x; picture x = kp - ox
local function fitsAt(px, base, rec, ox, W, tol)
	local kp, col = rec.kp, rec.col
	for s = 1, rec.m - 1 do
		local x0, x1 = kp[s] - ox, kp[s + 1] - ox
		local c = (s - 1) * 3
		local r0, g0, b0 = col[c + 1], col[c + 2], col[c + 3]
		local dr, dg, db = col[c + 4] - r0, col[c + 5] - g0, col[c + 6] - b0
		local inv = (x1 > x0) and 1 / (x1 - x0) or 0
		for x = math.max(x0, 0), math.min(x1, W - 1) do
			local t = (x - x0) * inv
			local p = base + x * 4
			if math.abs(r0 + dr * t - buffer.readu8(px, p)) > tol or math.abs(g0 + dg * t - buffer.readu8(px, p + 1)) > tol
				or math.abs(b0 + db * t - buffer.readu8(px, p + 2)) > tol then
				return false
			end
		end
	end
	return true
end

-- new strips for picture x range [a, b] of image row y; returns a list of records (not yet drawn)
local function fitSpan(self, y, a, b)
	local px = self.reader.rgba
	local base = y * self.reader.pw * 4
	local kpBuf, colBuf = self.kpBuf, self.colBuf
	-- (free keypoint colours and detail-aware cuts: Strips.fitRowFree / nextCut)
	local n = Strips.fitRowFree(px, base, 4, a, b, self.Tolerance, kpBuf, colBuf)
	if n == 1 then
		kpBuf[2] = b
		colBuf[4], colBuf[5], colBuf[6] = colBuf[1], colBuf[2], colBuf[3]
		n = 2
	end
	local out = {}
	local s0 = 1
	while s0 < n do
		local s1 = Strips.nextCut(kpBuf, s0, n)
		local m = s1 - s0 + 1
		local kp, col = table.create(m), table.create(m * 3)
		for q = s0, s1 do
			local i = q - s0 + 1
			kp[i] = kpBuf[q] + self.ox
			col[i * 3 - 2], col[i * 3 - 1], col[i * 3] = colBuf[q * 3 - 2], colBuf[q * 3 - 1], colBuf[q * 3]
		end
		table.insert(out, { kp = kp, col = col, m = m })
		s0 = s1
	end
	return out
end

local function same(a, b)
	if a.m ~= b.m then
		return false
	end
	local ka, kb = a.kp, b.kp
	for i = 1, a.m do
		if ka[i] ~= kb[i] then
			return false
		end
	end
	local ca, cb = a.col, b.col
	for i = 1, a.m * 3 do
		if ca[i] ~= cb[i] then
			return false
		end
	end
	return true
end

-- draw new records into row c, reusing strip objects from `old` (released when there are more old than new); a strip
-- that comes out the same as the old one in its place is left alone (a refitted row keeps its unchanged start)
local function place(self, c, recs, old)
	local canvas = self.canvas
	local updates = 0
	for i, r in ipairs(recs) do
		local reuse = old and old[i]
		r.obj = reuse and reuse.obj or canvas:acquire()
		r.setOx = self.ox
		if not (reuse and reuse.setOx == self.ox and same(reuse, r)) then
			canvas:set(r.obj, false, c, c, r.kp, r.col, r.m, self.ox, self.oy)
			updates += 1
		end
	end
	if old then
		for i = #recs + 1, #old do
			canvas:release(old[i].obj)
		end
	end
	return updates
end

-- bring image row y up to date; returns the number of strip updates it took
local function processRow(self, y)
	local c = y + self.oy
	local W, ox = self.W, self.ox
	local px = self.reader.rgba
	local base = y * self.reader.pw * 4
	local tol = self.Tolerance
	local list = self.rows[c]
	local updates = 0
	if not list or #list == 0 then
		list = fitSpan(self, y, 0, W - 1)
		updates += place(self, c, list, nil)
		self.rows[c] = list
		return updates
	end
	if self.refit[y] then
		self.refit[y] = nil
		list = fitSpan(self, y, 0, W - 1)
		updates += place(self, c, list, self.rows[c])
		self.rows[c] = list
		return updates
	end
	-- strips that slid off the picture
	local keep = {}
	for _, r in ipairs(list) do
		if r.kp[r.m] - ox < 0 or r.kp[1] - ox > W - 1 then
			self.canvas:release(r.obj)
		else
			table.insert(keep, r)
		end
	end
	list = keep
	if #list == 0 then
		list = fitSpan(self, y, 0, W - 1)
		updates += place(self, c, list, nil)
		self.rows[c] = list
		return updates
	end
	-- uncovered edges (after a slide): refit together with the strip next to them (no sliver strips)
	if list[1].kp[1] - ox > 0 then
		local first = table.remove(list, 1)
		local recs = fitSpan(self, y, 0, math.min(first.kp[first.m] - ox, W - 1))
		updates += place(self, c, recs, { first })
		for i = #recs, 1, -1 do
			table.insert(list, 1, recs[i])
		end
	end
	local last = list[#list]
	if last.kp[last.m] - ox < W - 1 then
		table.remove(list)
		local recs = fitSpan(self, y, math.max(last.kp[1] - ox, 0), W - 1)
		updates += place(self, c, recs, { last })
		for _, r in ipairs(recs) do
			table.insert(list, r)
		end
	end
	-- check every strip: keep, recolour, or mark for a new shape
	local bad = {}
	for i, r in ipairs(list) do
		if not fitsAt(px, base, r, ox, W, tol * KEEP) then
			-- same keypoints, colours of the new picture
			local col = r.newCol or table.create(r.m * 3)
			for k = 1, r.m do
				local x = math.clamp(r.kp[k] - ox, 0, W - 1)
				local p = base + x * 4
				col[k * 3 - 2], col[k * 3 - 1], col[k * 3] = buffer.readu8(px, p), buffer.readu8(px, p + 1), buffer.readu8(px, p + 2)
			end
			local trial = { kp = r.kp, col = col, m = r.m }
			if fitsAt(px, base, trial, ox, W, tol) then
				r.newCol, r.col = r.col, col
				self.canvas:recolour(r.obj, col, r.m)
				updates += 1
			else
				bad[i] = true
			end
		end
	end
	-- runs of neighbouring bad strips get new shapes; but when that would leave the row in more strips than a fresh
	-- fit of it (every strip costs a gradient, and patching cut rows into ever more strips: ~1570 for a picture a fresh
	-- fit draws with ~1080), the whole row is fitted afresh instead (its unchanged start stays as it is: place)
	if next(bad) then
		local out, jobs = {}, {}
		local i = 1
		while i <= #list do
			if bad[i] then
				local j = i
				while bad[j + 1] do
					j += 1
				end
				local a = math.max(list[i].kp[1] - ox, 0)
				local b = math.min(list[j].kp[list[j].m] - ox, W - 1)
				local recs = fitSpan(self, y, a, b)
				table.insert(jobs, { recs = recs, old = table.move(list, i, j, 1, {}) })
				for _, r in ipairs(recs) do
					table.insert(out, r)
				end
				i = j + 1
			else
				table.insert(out, list[i])
				i += 1
			end
		end
		local fresh = 1
		if #out > 1 then
			local n = Strips.fitRowFree(px, base, 4, 0, W - 1, tol, self.kpBuf, self.colBuf)
			fresh = Strips.countStrips(self.kpBuf, n)
		end
		if #out > fresh then
			local recs = fitSpan(self, y, 0, W - 1)
			updates += place(self, c, recs, list)
			list = recs
		else
			for _, job in ipairs(jobs) do
				updates += place(self, c, job.recs, job.old)
			end
			list = out
		end
	end
	self.rows[c] = list
	return updates
end

-- release rows that slid out of view (vertical moves)
local function dropHiddenRows(self)
	for c, list in pairs(self.rows) do
		local y = c - self.oy
		if y < 0 or y >= self.H then
			for _, r in ipairs(list) do
				self.canvas:release(r.obj)
			end
			self.rows[c] = nil
		end
	end
end

local function applyFrame(self, info)
	if not info then
		return
	end
	if info.fits then
		-- (a reader whose blocks were worked out on other threads, Video.DirectReader: only set here)
		for _, f in ipairs(info.fits) do
			self.fitPend[f[1]] = f
		end
		self.fitDirty = true
		return
	end
	if info.dx ~= 0 or info.dy ~= 0 then
		self.ox += info.dx
		self.oy += info.dy
		self.canvas:setOffset(self.ox, self.oy)
		if info.dy ~= 0 then
			dropHiddenRows(self)
		end
		markAll(self) -- every row gets its uncovered edge (cheap where nothing else changed)
	end
	if info.key then
		markAll(self)
		return
	end
	local BW = self.reader.bw
	local seen = {}
	for _, id in ipairs(info.blocks) do
		local by = id // BW
		if not seen[by] then
			seen[by] = true
			for y = by * 8, by * 8 + 7 do
				markRow(self, y)
			end
		end
	end
end

-- this picture's share of the gradients Roblox can draw
local function gradientShare(self)
	local own = self.canvas.gradients
	return math.min(self.MaxGradients, Canvas.MaxGradients - (Canvas.gradientsUsed() - own)), own
end

-- the n rows cut into the most strips: fitted afresh (at the current Tolerance)
local function refitWorst(self, n)
	local list = {}
	for c, rows in pairs(self.rows) do
		local y = c - self.oy
		if y >= 0 and y < self.H and not self.refit[y] then
			table.insert(list, { y = y, n = #rows })
		end
	end
	table.sort(list, function(a, b)
		return a.n > b.n
	end)
	for i = 1, math.min(n, #list) do
		local y = list[i].y
		self.refit[y] = true
		markRow(self, y)
	end
end

-- strips a fresh fit of the whole current picture at tolerance tol would use
local function estimate(self, tol)
	local px, pw = self.reader.rgba, self.reader.pw
	local kpBuf, W = self.kpBuf, self.W
	local n = 0
	for y = 0, self.H - 1 do
		local k = Strips.fitRowFree(px, y * pw * 4, 4, 0, W - 1, tol, kpBuf, self.colBuf)
		n += Strips.countStrips(kpBuf, k)
	end
	return n
end

-- the Tolerance for this picture: the lowest whose fresh fit stays under the gradient share. full: search the whole
-- range (before the first picture, yielding); otherwise a few steps from the current one (a cut, a jump)
local function retune(self, full)
	if Canvas.Shared then
		return
	end
	local share = gradientShare(self) * 0.85
	local t = self.Tolerance
	if full then
		local lo, hi = math.max(1, self.MinTolerance), 64
		while lo < hi do
			local mid = (lo + hi) // 2
			if estimate(self, mid) <= share then
				hi = mid
			else
				lo = mid + 1
			end
			task.wait()
		end
		t = lo
	else
		local e = estimate(self, t)
		if e > share then
			for _ = 1, 3 do
				t = math.min(64, math.floor(t * 1.3 + 1.5))
				if estimate(self, t) <= share then
					break
				end
			end
		elseif e < share * 0.7 and t > self.MinTolerance then
			local t2 = math.max(self.MinTolerance, math.floor(t * 0.75))
			if estimate(self, t2) <= share then
				t = t2
			end
		end
	end
	self.Tolerance = t
	self.gradFloor = t
end

-- too many gradients: draw coarser
local function gradientPressure(self)
	if Canvas.Shared then
		-- strips past the gradient budget are drawn with the shared shapes (or the ramp image); only the strip count is
		-- kept in check
		-- (playing cuts rows into ever more strips; refitting the worst rows undoes that first, and the tolerance only
		-- rises when that isn't enough, and comes down again soon, so it doesn't ratchet up over a few loops of a video)
		local used = self.canvas.used
		if used > self.MaxStrips then
			refitWorst(self, 8)
			if used > self.MaxStrips * 1.1 then
				self.gradFloor = math.min(40, math.max(self.gradFloor, self.Tolerance) + 0.1)
				self.Tolerance = math.max(self.Tolerance, self.gradFloor)
			end
		elseif used < self.MaxStrips * 0.9 and self.gradFloor > 0 then
			self.gradFloor = math.max(0, self.gradFloor - 0.5)
		end
		return
	end
	-- (strips past the share are drawn with the ramp pieces, or flat: correct but more objects / blurry, so the count is
	-- kept under it: refit the rows in the most strips, and raise the tolerance a little at a time while still over)
	local share, own = gradientShare(self)
	local now = os.clock()
	if own > share * 0.95 then
		refitWorst(self, 12)
		if now - (self.pressedAt or 0) > 0.15 then
			self.pressedAt = now
			self.gradFloor = math.min(64, math.max(self.gradFloor, self.Tolerance) + 1)
			self.Tolerance = math.max(self.Tolerance, self.gradFloor)
		end
	elseif own < share * 0.8 and self.gradFloor > 0 then
		self.gradFloor = math.max(0, self.gradFloor - 0.1)
	end
end

-- the block player: bring the 8x8 blocks of the dirty rows up to date. A block is refitted only when the drawn one
-- misses the new picture by more than BlockSkip (and redrawn only when the new fit is better). Time-limited
-- (TargetMs x 2, x 4 for a whole video frame); the rest goes on next screen frame (a picture too big for the device
-- then shows its new top over its old bottom for a moment: FrameLabClient moves such a screen to the video's smaller
-- size)
local function commitBlocks(self)
	local grid = self.canvas
	for _, p in ipairs(self.pending) do
		if p[3] == nil then
			grid:setSplit(p[1], p[2])
		else
			grid:set(p[1], p[2], p[3], p[4], p[5], p[6], p[7], p[8])
		end
	end
	table.clear(self.pending)
end

-- the blocks a reader worked out (info.fits), all at once
local function commitFits(self)
	local grid = self.canvas
	for ci, f in pairs(self.fitPend) do
		if f[2] == -2 then
			grid:setSplit(ci, f[3])
		else
			grid:set(ci, f[2], f[3], f[4], f[5], f[6], f[7], f[8])
		end
	end
	table.clear(self.fitPend)
	self.fitDirty = false
end

local function workBlocks(self, unlimited)
	local t0 = os.clock()
	local limit = self.TargetMs * (unlimited and 4 or 2) / 1000
	local grid = self.canvas
	local px, pw = self.reader.rgba, self.reader.pw
	local W, H = self.W, self.H
	local cols = grid.cols
	local skip = self.BlockSkip
	local fit, errorOf, recolor = Blocks.fitBlock, Blocks.errorOf, Blocks.recolor
	-- (batched: the changes are kept until the whole picture is worked out, then shown together)
	local pend = self.Batch and self.pending or nil
	local done = {}
	local used = 0
	local q = self.queue
	local i = 1
	while i <= #q do
		local y = q[i]
		i += 1
		self.dirty[y] = nil
		local r = y // 8
		if not done[r] then
			done[r] = true
			for c = 0, cols - 1 do
				local ci = r * cols + c + 1
				local cur = grid.idx[ci]
				local curErr = math.huge
				local x0, y0 = c * 8, r * 8
				if cur == -2 then
					-- split: the four 4x4 blocks together
					local fits, s = grid.subFits[ci], 0
					for q = 1, 4 do
						local f = fits[q]
						local e = errorOf(px, W, H, x0 + ((q - 1) % 2) * 4, y0 + ((q - 1) // 2) * 4, 4, pw, f[1], f[2], f[3], f[4], f[5], f[6], f[7])
						s += e * e
					end
					curErr = math.sqrt(s / 4)
				elseif cur ~= nil then
					local k = grid.col[ci]
					curErr = errorOf(px, W, H, x0, y0, 8, pw, cur, k[1], k[2], k[3], k[4], k[5], k[6])
				end
				-- (a block whose shape still fits gets new colours only: no pattern search)
				local recolored = false
				if curErr > skip and cur ~= nil and cur ~= -2 then
					local ar, ag, ab, br, bg, bb, e = recolor(px, W, H, x0, y0, 8, pw, cur)
					if e <= skip then
						recolored = true
						if pend then
							table.insert(pend, { ci, cur, ar, ag, ab, br, bg, bb })
						else
							grid:set(ci, cur, ar, ag, ab, br, bg, bb)
						end
						used += 1
					end
				end
				if curErr > skip and not recolored then
					local kind, ar, ag, ab, br, bg, bb, pidx, e = fit(px, W, H, x0, y0, 8, pw)
					local fits, e4
					if e > self.BlockSplit and (cur == -2 or grid.splits < self.MaxSplits) then
						fits, e4 = {}, 0
						for q = 1, 4 do
							local k2, r1, g1, b1, r2, g2, b2, i2, eq = fit(px, W, H, x0 + ((q - 1) % 2) * 4, y0 + ((q - 1) // 2) * 4, 4, pw)
							fits[q] = { k2 == "flat" and -1 or i2, r1, g1, b1, r2, g2, b2 }
							e4 += eq * eq
						end
						e4 = math.sqrt(e4 / 4)
					end
					if fits and e4 + 1.5 < e then
						if e4 + 1 < curErr then
							if pend then
								table.insert(pend, { ci, fits })
							else
								grid:setSplit(ci, fits)
							end
							used += 1
						end
					elseif e + 1 < curErr then
						local idx = kind == "flat" and -1 or pidx
						if pend then
							table.insert(pend, { ci, idx, ar, ag, ab, br, bg, bb })
						else
							grid:set(ci, idx, ar, ag, ab, br, bg, bb)
						end
						used += 1
					end
				end
			end
			if os.clock() - t0 > limit then
				break
			end
		end
	end
	-- keep the rows not reached (in order); rows of a cell row already done are dropped
	local rest = {}
	for k = i, #q do
		local y = q[k]
		if not done[y // 8] then
			table.insert(rest, y)
		else
			self.dirty[y] = nil
		end
	end
	table.clear(q)
	table.move(rest, 1, #rest, 1, q)
	-- the whole picture worked out: shown in one go
	if pend and #q == 0 and #pend > 0 then
		commitBlocks(self)
	end
	return used, os.clock() - t0
end

-- work through dirty rows until the budget (strip updates) or the time limit is used up
local function work(self, unlimited)
	if self.blocks then
		return workBlocks(self, unlimited)
	end
	local t0 = os.clock()
	-- most rows changed (a cut, a key frame): draw them all now, a little over the usual time, instead of sweeping the
	-- new picture down over several frames (that looked like scan lines)
	local whole = #self.queue > self.H * 0.5
	if whole and not self.retuned then
		-- a new picture (a cut, a jump): its tolerance first, once per such picture
		self.retuned = true
		retune(self, false)
	elseif not whole then
		self.retuned = false
	end
	-- a jump (the loop going back to the start, a seek): the canvas is hidden (see jump) and the whole new picture is
	-- drawn now, past the per-frame gradient cap (hidden gradients aren't drawn), and shown next screen frame
	local hidden = self.redrawHidden
	if hidden then
		unlimited = true
	end
	local cap = hidden and math.huge or self.churnCap
	local budget = (unlimited or whole) and math.huge or self.Budget
	local limit = unlimited and math.huge or self.TargetMs * (whole and 5 or 2) / 1000
	local used = 0
	local q = self.queue
	local i = 1
	while i <= #q do
		local y = q[i]
		i += 1
		self.dirty[y] = nil
		used += processRow(self, y)
		if used >= budget or os.clock() - t0 > limit or Canvas.videoChurn() >= cap then
			break
		end
	end
	-- keep the rows not reached (in order)
	table.move(q, i, #q, 1)
	for k = #q - i + 2, #q do
		q[k] = nil
	end
	return used, os.clock() - t0
end

-- the whole first picture before playback starts (yields every few rows)
function Player:prepare()
	if self.prepared then
		return
	end
	local info
	local start = self.Clock and math.floor(math.max(0, self.Clock()) * self.fps) or 0
	if self.reader.async then
		-- decoding on a worker: ask for the first picture and wait for it
		local r = self.reader
		r:seek((start > 0 and start < r.frameCount) and start or 0)
		local t0 = os.clock()
		while not r:ready(r.frame + 1) and os.clock() - t0 < 15 do
			task.wait()
		end
		info = r:advance()
		markAll(self)
	elseif start > 0 and start < self.reader.frameCount then
		-- joining a video that is already playing (a synced TV): start from where it is now
		info = self.reader:seek(start)
		markAll(self)
	else
		info = self.reader:advance()
	end
	applyFrame(self, info)
	if self.reader.render then
		self.reader.render()
	end
	-- warm-up: the first picture is drawn hidden (so it doesn't appear row by row), at the tolerance that fits the budget
	local frame = self.canvas.Frame
	local wasVisible = frame.Visible
	frame.Visible = false
	local q = self.queue
	if self.blocks then
		self.canvas:build(400)
		while #q > 0 do
			workBlocks(self, true)
			task.wait()
		end
	else
		retune(self, true)
	end
	if self.fitDirty and self.blocks then
		commitFits(self)
	end
	while #q > 0 do
		local y = table.remove(q, 1)
		self.dirty[y] = nil
		processRow(self, y)
		if #q % 12 == 0 then
			task.wait()
		end
	end
	-- more strips than Roblox has gradients for (or, with the ramp image, than MaxStrips): coarser, all rows again
	local function over()
		if self.blocks then
			return false
		end
		if Canvas.Shared then
			return self.canvas.used > self.MaxStrips * 1.5 -- (the pressure in play trims the rest gently)
		end
		return self.canvas.gradients > gradientShare(self) * 0.95
	end
	while over() and self.Tolerance < 64 do
		self.Tolerance = math.min(64, self.Tolerance + 4)
		self.gradFloor = self.Tolerance
		for y = 0, self.H - 1 do
			self.refit[y] = true
			processRow(self, y)
			if y % 12 == 11 then
				task.wait()
			end
		end
	end
	-- a few spare strips for the frames ahead
	self.canvas:prewarm(math.floor(self.canvas.used * 0.3), 100)
	frame.Visible = wasVisible
	self.prepared = true
end

function Player:_time()
	if self.Clock then
		return self.Clock()
	end
	if self.playing then
		return os.clock() - self.timeOffset
	end
	return self.pausedAt or 0
end

function Player:getTime()
	return math.max(0, self:_time())
end

-- the picture jumps (loop, seek): hide it until the new one is drawn (drawn in place under the gradient cap it took
-- several frames: old and new rows mixed, a visible struggle at every loop)
local function jump(self)
	self.jumped = true
	self.drawT0 = nil
	if self.blocks then
		return -- (blocks have no gradient limit: the new picture is simply drawn over the next few frames)
	end
	if not self.redrawHidden then
		self.redrawHidden = true
		self.canvas.Board.Visible = false
	end
end

-- the rate shown follows how long a picture takes to be worked out and shown: while pictures can't be finished in time
-- it steps down to a half, then a third of the video's (24 -> 12 -> 8 fps: even motion instead of late, uneven
-- frames), and back up once a picture takes well under the faster rate's time
local function pace(self, dur)
	self.drawEma = self.drawEma and self.drawEma * 0.8 + dur * 0.2 or dur
	if not self.AutoQuality then
		return
	end
	local now = os.clock()
	if now < (self.paceAt or 0) then
		return
	end
	local k = math.floor(self.FpsCap / self.MaxFps + 0.5)
	local nk = k
	if self.drawEma > 0.9 / self.MaxFps and k < 3 then
		nk = k + 1
	elseif k > 1 and self.drawEma < 0.5 * (k - 1) / self.FpsCap then
		nk = k - 1
	end
	if nk ~= k then
		self.MaxFps = self.FpsCap / nk
		self.paceAt = now + 3
	end
end

local function step(self)
	-- (shown once a frame has been drawn with the picture hidden: shown sooner, the replaced gradients still counted)
	if self.revealNext and Canvas.renderFrame() > self.revealAfter then
		self.revealNext = false
		self.redrawHidden = false
		self.canvas.Board.Visible = true
	end
	-- gradients: live ones + this screen frame's replacements stay under Canvas.DrawLimit (white strips past it). The share
	-- of live strips leaves room for the replacements a screen frame needs on average (fewer screen frames per video
	-- frame, or a busier picture: fewer strips, so the picture keeps up)
	local now = os.clock()
	local dtR = now - (self.lastStep or now)
	self.lastStep = now
	if dtR > 0 and dtR < 0.5 then
		-- (drawn frames per second, not script frames: the replacements must fit between drawn frames)
		local rn = Canvas.renderFrame()
		local drawn = rn - (self.lastRender or rn)
		self.lastRender = rn
		self.rfps = (self.rfps or 60) * 0.95 + (drawn / dtR) * 0.05
		local tot = Canvas.videoChangesTotal()
		local d = tot - (self.lastTotal or tot)
		self.lastTotal = tot
		self.cps = (self.cps or 0) * 0.97 + (d / dtR) * 0.03
		local perFrame = self.cps / math.max(self.rfps, 1)
		self.MaxGradients = math.clamp(math.floor(Canvas.DrawLimit - 1.3 * perFrame), 420, self.GradientCeiling)
	end
	self.churnCap = math.max(40, Canvas.DrawLimit - Canvas.gradientsUsed())
	local t = self:_time()
	local fps = self.fps
	local maxFps = math.min(self.MaxFps, fps)
	local target = math.floor(math.floor(t * maxFps + 1e-6) / maxFps * fps + 1e-6)
	local reader = self.reader
	local t0 = os.clock()
	if target >= reader.frameCount then
		if self.Loop and not self.Clock then
			self.timeOffset = os.clock()
			t = 0
			target = 0
			reader:seek(0)
			markAll(self)
			jump(self)
		elseif not self.Clock then
			self.playing = false
			self.endedEvent:Fire()
			return
		else
			target = reader.frameCount - 1
		end
	end
	-- paced: while the picture before is still being worked out, the reader isn't moved on
	local hold = self.Batch and #self.queue > 0
	local ready = reader.ready == nil or reader:ready(target)
	self.Stats.buffering = not ready
	if not ready then
		-- a streamed video whose bytes haven't arrived: play on as far as they go, then hold the last picture
		if reader.async then
			-- (the worker isn't keeping up: counts as slow decoding, so the droppable half gets skipped)
			self.decodeEma += self.TargetMs * 0.3
		end
		if (reader.direct or reader.blocks) and target - reader.frame > fps * 2 then
			-- (a stream decoded here, Video.DirectReader, or the server's block picture, Video.BlockStream: a jump ahead
			-- to frames not here yet, or fallen more than 2 s behind, goes straight to the spot and waits there, rather
			-- than playing on from where it was)
			reader:seek(target)
			markAll(self)
			jump(self)
		elseif not hold and target > reader.frame and (reader.async or target - reader.frame <= fps * 2) then
			-- (a reader decoding on a worker hands over its frames ready-made: it catches up)
			while reader.frame < target and reader:ready(reader.frame + 1) do
				applyFrame(self, reader:advance())
			end
		end
	elseif target < reader.frame then
		-- the clock went back (seek or a looping audio track): start over from that chunk
		local info = reader:seek(target)
		markAll(self)
		applyFrame(self, info)
		jump(self)
		self.Stats.buffering = reader.async == true -- (its picture there isn't decoded yet)
	elseif target - reader.frame > fps * 2 then
		reader:seek(target)
		markAll(self)
		jump(self)
		self.Stats.buffering = reader.async == true
	elseif not hold then
		-- (a reader decoding on a worker may not have every frame yet: the rest next screen frame)
		while reader.frame < target and reader:ready(reader.frame + 1) do
			applyFrame(self, reader:advance())
		end
	end
	if reader.render then
		reader.render()
	end
	if self.fitDirty and self.blocks then
		commitFits(self)
	end
	local decodeMs = (os.clock() - t0) * 1000
	self.decodeEma = self.decodeEma * 0.9 + decodeMs * 0.1
	-- Batch (default): every strip a new video frame broke is redrawn in that same frame, and nothing changes in the
	-- frames between. On a SurfaceGui, once a few hundred of its objects change in a frame, Roblox redraws the
	-- whole screen (8000 objects: ~37 fps with changes every frame, ~54 fps with changes every 3rd frame), so spreading
	-- a picture's updates over several frames would pay for a full redraw in every one of them.
	local used, dt = 0, 0
	local worked = true
	if self.Batch then
		-- (after a jump - the loop going back to the start, a seek - the whole new picture is drawn over a few frames,
		-- TargetMs x 5 each: drawn in one frame it would be a visible hitch every time the video loops)
		if reader.frame ~= self.workedFrame or #self.queue > 0 and (self.workedFrame == nil or self.catchUp) then
			if reader.frame ~= self.workedFrame and not self.jumped and not self.redrawHidden and not self.drawT0 then
				self.drawT0 = now -- (a new picture: timed until it is shown)
			end
			self.workedFrame = reader.frame
			local jumping = self.catchUp or self.jumped
			self.jumped = false
			if self.redrawHidden then
				used, dt = work(self, true)
				worked = false
				self.catchUp = #self.queue > 0
				if not self.catchUp then
					self.revealNext = true
					self.revealAfter = Canvas.renderFrame()
				end
			elseif jumping then
				used, dt = work(self, false)
				worked = false -- (a whole picture's time says nothing about the device: no quality change for it)
				self.catchUp = #self.queue > 0
			else
				used, dt = work(self, true)
				self.catchUp = #self.queue > 0 -- (stopped by the gradient limit: the rest next screen frame)
			end
		else
			worked = false
		end
	else
		used, dt = work(self, false)
	end
	if self.drawT0 and #self.queue == 0 then
		pace(self, os.clock() - self.drawT0)
		self.drawT0 = nil
	end
	local ms = dt * 1000
	if worked then
		self.emaMs = self.emaMs * 0.9 + ms * 0.1
	end
	local st = self.Stats
	st.updates, st.ms, st.behind, st.frame = used, self.emaMs, #self.queue, reader.frame
	st.decodeMs = self.decodeEma
	st.fps, st.drawMs = self.MaxFps, (self.drawEma or 0) * 1000
	if reader.layers == 2 then
		-- FLV2: half the frames are droppable; skip them when shown at 12 fps or less, or when decoding is too heavy
		local skip = reader.SkipDroppable
		if self.MaxFps <= 12 then
			skip = true
		elseif self.AutoQuality then
			if self.decodeEma > self.TargetMs * 1.5 then
				skip = true
			elseif self.decodeEma < self.TargetMs * 0.5 then
				skip = false
			end
		elseif self.ForceHalfRate ~= nil then
			skip = self.ForceHalfRate
		else
			skip = false
		end
		reader.SkipDroppable = skip
		st.halfRate = skip
	end
	st.strips = self.canvas.used
	st.gradients = self.canvas.gradients
	if not self.blocks then
		gradientPressure(self)
	end
	st.tolerance, st.budget = self.Tolerance, self.Budget
	-- (batched: the work comes once per video frame, so it may take the time of the screen frames in between)
	local targetMs = self.Batch and self.TargetMs * 2.5 or self.TargetMs
	if self.AutoQuality and worked then
		if self.emaMs > targetMs * 1.2 then
			self.Tolerance = math.min(self.MaxTolerance, self.Tolerance + 1)
			self.Budget = math.max(40, math.floor(self.Budget * 0.9))
		elseif self.emaMs < targetMs * 0.6 then
			if #self.queue > 0 then
				self.Budget = math.min(self.MaxBudget, math.floor(self.Budget * 1.1) + 1)
			end
			if self.Tolerance > math.max(self.MinTolerance, self.gradFloor) then
				self.Tolerance = math.max(self.MinTolerance, self.gradFloor, self.Tolerance - 0.5)
			end
		end
	end
end

function Player:play()
	if not self.prepared then
		self:prepare()
	end
	self.playing = true
	self.timeOffset = os.clock() - (self.pausedAt or 0)
	self.pausedAt = nil
	if not self.conn then
		self.conn = RunService.Heartbeat:Connect(function()
			if self.playing or self.Clock then
				step(self)
			end
		end)
	end
end

function Player:pause()
	if self.playing then
		self.pausedAt = os.clock() - self.timeOffset
		self.playing = false
	end
end

function Player:resume()
	if not self.playing then
		self:play()
	end
end

function Player:seek(seconds)
	if self.Clock then
		return -- follows its clock
	end
	if self.playing then
		self.timeOffset = os.clock() - seconds
	else
		self.pausedAt = seconds
	end
end

function Player:stop()
	self.playing = false
	self.pausedAt = 0
	if self.conn then
		self.conn:Disconnect()
		self.conn = nil
	end
end

function Player:destroy()
	self:stop()
	if self.reader.close then
		self.reader.close()
	end
	self.canvas:destroy()
	self.rows = {}
	self.endedEvent:Destroy()
end

return Player
