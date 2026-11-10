--!native
--!optimize 2
-- FrameLab block streams: a stream sent as the block player's own picture (Render.BlockGrid: 8 x 8 blocks from the
-- pattern library, two colours each, some cut into four 4 x 4), worked out on the server, so a client only sets the
-- blocks that change: no video decoding and no fitting on it (phones). Made from a stream's segments (Tools.Live) on
-- the import workers, in pieces of a few seconds. Each piece starts with every block (a jump can start at any piece)
-- and then holds each frame's changes, at most Cap of them a frame: the rest follow in the next frames, so a scene cut
-- is spread over a few and never redraws the whole screen at once.
--   BlockStream.size(srcW, srcH, lines) -> W, H   the picture's size: the short side at most `lines` (never enlarged)
--   BlockStream.encodeSegment(job, yield, emit, ImportJob)   (an import worker: Tools.ImportWorker "blocks", which
--       passes its Tools.ImportJob: no require in parallel) job = { bytes
--       (MPEG-TS, or access units: Formats.Ts.packUnits), k0, k1, offset, fps, w, h, cuts (each piece's first frame),
--       from (the first piece made, 1-based), state (where the fitting stood at frame k0 - 1: the segment before's, so
--       its end and this one's start join without a redraw) }; emit("piece", i, bytes) for each piece made (i within
--       cuts), then emit("state", state)
--   BlockStream.reader(stream) -> a reader for Video.Player (stream: Tools.Net.openVideo with options.Blocks, whose
--       chunks are the pieces); its frames come with the blocks that change (info.fits), as Video.DirectReader's do
--
-- A piece (Zstd-compressed by the server): u32 first frame, u16 frames, u16 columns, u16 rows; every block as it is
-- at the first frame; then for each later frame: u16 count, and per changed block a varint (blocks skipped since the
-- last one) and the block. A block: u16 tag (0: one colour; 1 - 4096: pattern + 1, two colours; 0xFFFE: new colours for
-- the pattern it has; 0xFFFF: four 4 x 4, each a tag 0 / pattern + 1 and its colours), colours as RGB 5:6:5 (u16).
local BlockStream = {}

local FrameLab = script:FindFirstAncestor("FrameLab")
local Blocks = require(FrameLab.Image.Blocks)

local readu8, readu16, readu32 = buffer.readu8, buffer.readu16, buffer.readu32
local writeu8, writeu16 = buffer.writeu8, buffer.writeu16

local FULL_CHECK = 12 -- every this many frames every block is checked (slow drifts the change test misses)
local SPLIT, RECOLOUR = 0xFFFF, 0xFFFE

-- the server's settings: a block is refitted once it misses by more than Skip (rms, 0..255), tried as four 4 x 4 past
-- Split; at most MaxSplits split blocks, at most Cap changes a frame
BlockStream.Options = { Skip = 7, Split = 9, MaxSplits = 150, Cap = 250 }

function BlockStream.size(srcW, srcH, lines)
	local s = math.min(1, lines / math.min(srcW, srcH))
	return math.max(8, math.floor(srcW * s / 2 + 0.5) * 2), math.max(8, math.floor(srcH * s / 2 + 0.5) * 2)
end

------------------------------------------------------------------------------------------------------------------------
-- fitting (server)

local function newState()
	return { idx = {}, col = {}, subs = {}, splits = 0, n = 0, stale = {} }
end

-- the state as it is handed between threads (Actor messages and events keep only plain arrays: every cell filled, false
-- where a cell isn't split) and back
local function packState(st, n)
	local idx, col, subs = table.create(n), table.create(n), table.create(n)
	for ci = 1, n do
		idx[ci] = st.idx[ci] or -1
		col[ci] = st.col[ci] or { 0, 0, 0, 0, 0, 0 }
		subs[ci] = st.subs[ci] or false
	end
	return { idx = idx, col = col, subs = subs, splits = st.splits, n = st.n, prev = st.prev }
end
local function unpackState(p)
	local st = newState()
	for ci, v in ipairs(p.idx) do
		st.idx[ci] = v
		st.col[ci] = p.col[ci]
		st.subs[ci] = p.subs[ci] or nil
	end
	st.splits, st.n, st.prev = p.splits, p.n, p.prev
	return st
end

-- one frame: the blocks that change, { ci, idx, ar, ag, ab, br, bg, bb } (idx -1: one colour), { ci, -2, fits }
-- (four 4 x 4: fits[q] = { idx, colours }) or { ci, -3, colours } (the same pattern, new colours); the state follows
local function fitFrame(st, key, data, W, H, o)
	local fit, errorOf, recolor = Blocks.fitBlock, Blocks.errorOf, Blocks.recolor
	local skip, split, maxSplits, cap = o.Skip, o.Split, o.MaxSplits, o.Cap
	local cols, rows = (W + 7) // 8, (H + 7) // 8
	local prev = st.prev
	st.n += 1
	local full = key or not prev or st.n % FULL_CHECK == 0
	local stale = st.stale
	st.stale = {}
	local splits = st.splits
	local cands = {}
	for r = 0, rows - 1 do
		local ly = r * 8
		for c = 0, cols - 1 do
			local x0 = c * 8
			local ci = r * cols + c + 1
			local check = full or stale[ci] == true
			if not check then
				if ly + 7 < H and x0 + 7 < W then
					-- (changed since the last frame: sampled, every other pixel each way)
					local s = 0
					for yy = 0, 7, 2 do
						local ob = ((ly + yy) * W + x0) * 4
						for xx = 0, 28, 8 do
							s += math.abs(readu8(data, ob + xx) - readu8(prev, ob + xx))
								+ math.abs(readu8(data, ob + xx + 1) - readu8(prev, ob + xx + 1))
								+ math.abs(readu8(data, ob + xx + 2) - readu8(prev, ob + xx + 2))
						end
					end
					check = s > 48
				else
					check = true -- (an edge block: checked every frame)
				end
			end
			if check then
				local cur = st.idx[ci]
				local curErr = math.huge
				if not key and cur ~= nil then
					if cur == -2 then
						local fits, se = st.subs[ci], 0
						for q = 1, 4 do
							local f = fits[q]
							local e = errorOf(data, W, H, x0 + ((q - 1) % 2) * 4, ly + ((q - 1) // 2) * 4, 4, W, f[1], f[2], f[3], f[4],
								f[5], f[6], f[7])
							se += e * e
						end
						curErr = math.sqrt(se / 4)
					else
						local k = st.col[ci]
						curErr = errorOf(data, W, H, x0, ly, 8, W, cur, k[1], k[2], k[3], k[4], k[5], k[6])
					end
				end
				if curErr > skip then
					local cand
					-- (the same shape, new colours)
					if cur ~= nil and cur >= 0 and not key then
						local ar, ag, ab, br, bg, bb, e = recolor(data, W, H, x0, ly, 8, W, cur)
						if e <= skip then
							cand = { ci, -3, ar, ag, ab, br, bg, bb, gain = curErr - e }
						end
					end
					if not cand then
						local kind, ar, ag, ab, br, bg, bb, pidx, e = fit(data, W, H, x0, ly, 8, W)
						local fits, e4
						if e > split and (cur == -2 or splits < maxSplits) then
							fits, e4 = {}, 0
							for q = 1, 4 do
								local k2, r1, g1, b1, r2, g2, b2, i2, eq = fit(data, W, H, x0 + ((q - 1) % 2) * 4, ly + ((q - 1) // 2) * 4, 4, W)
								fits[q] = { k2 == "flat" and -1 or i2, r1, g1, b1, r2, g2, b2 }
								e4 += eq * eq
							end
							e4 = math.sqrt(e4 / 4)
						end
						if fits and e4 + 1.5 < e then
							if e4 + 1 < curErr then
								if cur ~= -2 then
									splits += 1
								end
								cand = { ci, -2, fits, gain = curErr - e4 }
							end
						elseif e + 1 < curErr then
							if cur == -2 then
								splits -= 1
							end
							cand = { ci, kind == "flat" and -1 or pidx, ar, ag, ab, br, bg, bb, gain = curErr - e }
						end
					end
					if cand then
						table.insert(cands, cand)
					end
				end
			end
		end
	end
	-- (over the cap: the biggest improvements now, the rest are looked at again next frame)
	if cap and not key and #cands > cap then
		table.sort(cands, function(a, b)
			return a.gain > b.gain
		end)
		for i = #cands, cap + 1, -1 do
			st.stale[cands[i][1]] = true
			cands[i] = nil
		end
	end
	for _, cd in ipairs(cands) do
		local ci, kind = cd[1], cd[2]
		local cur = st.idx[ci]
		if kind == -2 then
			if cur ~= -2 then
				st.splits += 1
			end
			st.idx[ci], st.subs[ci] = -2, cd[3]
		else
			if cur == -2 then
				st.splits -= 1
				st.subs[ci] = nil
			end
			if kind ~= -3 then
				st.idx[ci] = kind
			end
			st.col[ci] = { cd[3], cd[4], cd[5], cd[6], cd[7], cd[8] }
		end
		cd.gain = nil
	end
	st.prev = data
	return cands
end

------------------------------------------------------------------------------------------------------------------------
-- pieces

local function rgb565(r, g, b)
	return bit32.bor(bit32.lshift(math.clamp(math.floor(r + 0.5), 0, 255) // 8, 11),
		bit32.lshift(math.clamp(math.floor(g + 0.5), 0, 255) // 4, 5), math.clamp(math.floor(b + 0.5), 0, 255) // 8)
end

local function writer(first, cols, rows)
	local w = {}
	local b = buffer.create(4096)
	local p = 10
	local frames = 1
	local function room(n)
		if p + n > buffer.len(b) then
			local nb = buffer.create(math.max(buffer.len(b) * 2, p + n))
			buffer.copy(nb, 0, b, 0, p)
			b = nb
		end
	end
	local function u8(v)
		writeu8(b, p, v)
		p += 1
	end
	local function u16(v)
		writeu16(b, p, v)
		p += 2
	end
	local function colours(idx, ar, ag, ab, br, bg, bb)
		u16(rgb565(ar, ag, ab))
		if idx >= 0 then
			u16(rgb565(br, bg, bb))
		end
	end
	local function block(idx, a, b2)
		-- (a: colours table or fits; b2 unused)
		if idx == -2 then
			u16(SPLIT)
			for q = 1, 4 do
				local f = a[q]
				u16(f[1] + 1)
				colours(f[1], f[2], f[3], f[4], f[5], f[6], f[7])
			end
		else
			u16(idx + 1)
			colours(idx, a[1], a[2], a[3], a[4], a[5], a[6])
		end
	end
	-- every block as the state has it
	function w.snapshot(st)
		room(cols * rows * 34)
		for ci = 1, cols * rows do
			local idx = st.idx[ci] or -1
			if idx == -2 then
				block(-2, st.subs[ci])
			else
				block(idx, st.col[ci] or { 0, 0, 0, 0, 0, 0 })
			end
		end
	end
	-- one more frame's changes (fitFrame)
	function w.frame(changes)
		frames += 1
		table.sort(changes, function(x, y)
			return x[1] < y[1]
		end)
		room(2 + #changes * 40)
		u16(#changes)
		local last = 0
		for _, c in ipairs(changes) do
			local gap = c[1] - last - 1
			last = c[1]
			while gap >= 128 do
				u8(bit32.bor(gap % 128, 128))
				gap = gap // 128
			end
			u8(gap)
			if c[2] == -2 then
				block(-2, c[3])
			elseif c[2] == -3 then
				u16(RECOLOUR)
				u16(rgb565(c[3], c[4], c[5]))
				u16(rgb565(c[6], c[7], c[8]))
			else
				u16(c[2] + 1)
				colours(c[2], c[3], c[4], c[5], c[6], c[7], c[8])
			end
		end
	end
	function w.finish()
		buffer.writeu32(b, 0, first)
		writeu16(b, 4, frames)
		writeu16(b, 6, cols)
		writeu16(b, 8, rows)
		local out = buffer.create(p)
		buffer.copy(out, 0, b, 0, p)
		return out
	end
	return w
end

-- colours back from 5:6:5
local R5, G6 = table.create(32, 0), table.create(64, 0)
for v = 0, 31 do
	R5[v + 1] = math.floor(v * 255 / 31 + 0.5)
end
for v = 0, 63 do
	G6[v + 1] = math.floor(v * 255 / 63 + 0.5)
end

-- a piece's bytes (decompressed) -> { first, frames, cols, rows, snapshot = { [cell] = fit }, deltas = { [frame within
-- the piece, 2 ..] = { fit ... } } }; a fit as Video.Player takes it: { cell, idx, ar, ag, ab, br, bg, bb },
-- { cell, -2, fits } or { cell, -3, ar, ag, ab, br, bg, bb } (new colours for the pattern it has)
function BlockStream.readPiece(b)
	local p = 10
	local function col()
		local v = readu16(b, p)
		p += 2
		return R5[bit32.rshift(v, 11) + 1], G6[bit32.band(bit32.rshift(v, 5), 63) + 1], R5[bit32.band(v, 31) + 1]
	end
	local function block(ci)
		local tag = readu16(b, p)
		p += 2
		if tag == SPLIT then
			local fits = table.create(4)
			for q = 1, 4 do
				local t = readu16(b, p)
				p += 2
				local r1, g1, b1 = col()
				if t == 0 then
					fits[q] = { -1, r1, g1, b1, r1, g1, b1 }
				else
					local r2, g2, b2 = col()
					fits[q] = { t - 1, r1, g1, b1, r2, g2, b2 }
				end
			end
			return { ci, -2, fits }
		elseif tag == RECOLOUR then
			local r1, g1, b1 = col()
			local r2, g2, b2 = col()
			return { ci, -3, r1, g1, b1, r2, g2, b2 }
		elseif tag == 0 then
			local r1, g1, b1 = col()
			return { ci, -1, r1, g1, b1, r1, g1, b1 }
		end
		local r1, g1, b1 = col()
		local r2, g2, b2 = col()
		return { ci, tag - 1, r1, g1, b1, r2, g2, b2 }
	end
	local first, frames, cols, rows = readu32(b, 0), readu16(b, 4), readu16(b, 6), readu16(b, 8)
	local n = cols * rows
	local snapshot = table.create(n)
	for ci = 1, n do
		snapshot[ci] = block(ci)
	end
	local deltas = {}
	for t = 2, frames do
		local count = readu16(b, p)
		p += 2
		local list = table.create(count)
		local ci = 0
		for k = 1, count do
			local gap, shift = 0, 1
			while true do
				local v = readu8(b, p)
				p += 1
				gap += bit32.band(v, 127) * shift
				if v < 128 then
					break
				end
				shift *= 128
			end
			ci += gap + 1
			list[k] = block(ci)
		end
		deltas[t] = list
	end
	return { first = first, frames = frames, cols = cols, rows = rows, snapshot = snapshot, deltas = deltas }
end

------------------------------------------------------------------------------------------------------------------------
-- a segment (import worker)

function BlockStream.encodeSegment(job, yield, emit, ImportJob)
	ImportJob = ImportJob or require(FrameLab.Tools.ImportJob)
	local o = job.options or BlockStream.Options
	local W, H = job.w, job.h
	local cols, rows = (W + 7) // 8, (H + 7) // 8
	local cuts = job.cuts
	local from = math.clamp(job.from or 1, 1, #cuts)
	local st = (from == 1 and job.state) and unpackState(job.state) or newState()
	local key = not (from == 1 and job.state)
	local pi = from
	local w
	ImportJob.tsFrames(job.bytes, job.k0, job.k1, job.offset, job.fps, { { w = W, h = H } }, function(k, imgs)
		if k < cuts[from] then
			return
		end
		-- (the next piece: the one before is done)
		while cuts[pi + 1] and k >= cuts[pi + 1] do
			if w then
				emit("piece", pi, w.finish())
				w = nil
			end
			pi += 1
		end
		local changes = fitFrame(st, key, imgs[1].data, W, H, o)
		key = false
		if w then
			w.frame(changes)
		else
			w = writer(k, cols, rows)
			w.snapshot(st)
		end
		yield()
	end, yield, cuts[from])
	if w then
		emit("piece", pi, w.finish())
	end
	emit("state", packState(st, cols * rows))
end

------------------------------------------------------------------------------------------------------------------------
-- the reader (client)

function BlockStream.reader(stream)
	local EncodingService = game:GetService("EncodingService")
	local head = stream.bytes
	local fps = buffer.readu8(head, 5)
	local W, H = readu16(head, 6), readu16(head, 8)
	local cols = (W + 7) // 8
	local r = { codec = "BLOCKS", async = true, blocks = true, fits = true, layers = 1, fps = fps, width = W, height = H,
		frameCount = readu32(head, 10), frame = -1 }
	r.duration = r.frameCount / fps
	r.chunks = {}
	for i = 1, readu16(head, 16) do
		r.chunks[i] = { first = readu32(head, 24 + (i - 1) * 16 + 12) }
	end
	r.render = function() end
	local n = cols * ((H + 7) // 8)
	local cur = table.create(n, -1) -- cell -> the pattern it shows (for new colours alone)
	local needKey = true
	local parsed, parsedOrder = {}, {}

	function r:chunkOf(frame)
		local lo, hi = 1, #r.chunks
		while lo < hi do
			local mid = (lo + hi + 1) // 2
			if r.chunks[mid].first <= frame then
				lo = mid
			else
				hi = mid - 1
			end
		end
		return lo
	end
	local function piece(ci)
		local p = parsed[ci]
		if p then
			return p
		end
		local data = stream.chunkData(ci)
		if not data then
			return nil
		end
		local ok, raw = pcall(EncodingService.DecompressBuffer, EncodingService, data, Enum.CompressionAlgorithm.Zstd)
		if not ok then
			r.broken = tostring(raw)
			return nil
		end
		local okP, pc = pcall(BlockStream.readPiece, raw)
		if not okP or pc.cols * pc.rows ~= n then
			r.broken = okP and "the stream's blocks don't fit the picture" or tostring(pc)
			return nil
		end
		parsed[ci] = pc
		table.insert(parsedOrder, ci)
		if #parsedOrder > 4 then
			parsed[table.remove(parsedOrder, 1)] = nil
		end
		return pc
	end
	function r:ready(frame)
		if frame <= r.frame then
			return true
		end
		if frame >= r.frameCount then
			return false
		end
		return stream.chunkData(r:chunkOf(frame)) ~= nil
	end
	function r:seek(frame)
		frame = math.clamp(math.floor(frame), 0, r.frameCount - 1)
		r.frame = frame - 1
		needKey = true
		return nil -- (the picture there comes from the next advance, every block of it)
	end
	function r:advance()
		local f = r.frame + 1
		if f >= r.frameCount then
			return nil
		end
		local p = piece(r:chunkOf(f))
		if not p then
			return nil
		end
		local j = f - p.first + 1
		local fits
		if needKey or j <= 1 then
			-- every block as it is at frame f: the piece's first picture and its changes up to f (a block drawn as it
			-- already is costs nothing: Render.BlockGrid only writes what differs)
			fits = table.clone(p.snapshot)
			for t = 2, j do
				for _, e in ipairs(p.deltas[t]) do
					if e[2] == -3 then
						local was = fits[e[1]]
						fits[e[1]] = { e[1], was[2] >= 0 and was[2] or -1, e[3], e[4], e[5], e[6], e[7], e[8] }
					else
						fits[e[1]] = e
					end
				end
			end
			for ci = 1, n do
				cur[ci] = fits[ci][2]
			end
			needKey = false
		else
			local list = p.deltas[j] or {}
			fits = table.create(#list)
			for k, e in ipairs(list) do
				local ci, idx = e[1], e[2]
				if idx == -3 then
					idx = cur[ci] >= 0 and cur[ci] or -1
					e = { ci, idx, e[3], e[4], e[5], e[6], e[7], e[8] }
				end
				cur[ci] = idx
				fits[k] = e
			end
		end
		r.frame = f
		return { key = false, dx = 0, dy = 0, blocks = {}, fits = fits }
	end
	function r.failed()
		return r.broken
	end
	function r.close() end
	return r
end

return BlockStream
