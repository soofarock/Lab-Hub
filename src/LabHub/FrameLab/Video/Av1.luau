--!native
--!optimize 2
-- FrameLab AV1 video decoder in pure Luau: Main, High and Professional profiles (8 or 10 bits; 10-bit pictures are
-- handed out as 8-bit planes), every coding tool of the format: intra and inter frames, compound and masked
-- prediction, warped and overlapped motion, palette and intra block copy, the loop filter, CDEF, loop restoration,
-- super-resolution and film grain. Used for AV1 video (MP4 / WebM / MKV) and AVIF pictures.
--
--   local dec = Av1.new(av1C)                  av1C: the av1C box payload / CodecPrivate (buffer) or nil
--   local pic = dec:decodeSample(buf, pos, len)      one temporal unit (a sample) -> the shown picture or nil
--   pic.Y, pic.U, pic.V (8-bit planes), pic.ys / pic.cs (strides), pic.yo / pic.co = 0 (offset of pixel 0,0)
--   dec.width, dec.height (shown size), dec.cropX = dec.cropY = 0, dec.fullRange, dec.bt709, dec.matrix (the
--   colour matrix code), dec.monochrome, dec.chromaShiftX / dec.chromaShiftY (chroma subsampling of the planes handed
--   out: 1, 1 - 4:2:0 - unless dec.fullChroma is set, which keeps 4:4:4 / 4:2:2 chroma as coded)
--   The planes are valid until the next call. Pictures come out in display order of the stream's shown frames.
--   dec:reset()   forget the frames decoded so far: decoding starts again at the next key frame

local band, bor, bxor, rshift, lshift = bit32.band, bit32.bor, bit32.bxor, bit32.rshift, bit32.lshift
local countlz = bit32.countlz
local readu8, writeu8, readu16, writeu16 = buffer.readu8, buffer.writeu8, buffer.readu16, buffer.writeu16
local readi16, writei16, readi8, writei8 = buffer.readi16, buffer.writei16, buffer.readi8, buffer.writei8
local readu32 = buffer.readu32
local bcopy, bfill, bcreate, blen = buffer.copy, buffer.fill, buffer.create, buffer.len
local abs, min, max, floor = math.abs, math.min, math.max, math.floor
local tmove, tcreate = table.move, table.create

local Tab = require(script.Parent.Av1Tables)
local Post = require(script.Parent.Av1Post)
local Transform = require(script.Parent.Av1Transform)

local Av1 = {}

local function fail(msg)
	error("AV1: " .. msg, 0)
end

local lastYield = os.clock()
local function breathe()
	if task and os.clock() - lastYield > 0.05 then
		task.wait()
		lastYield = os.clock()
	end
end

-- powers of two (P2[k + 1] = 2^k) for the windowed arithmetic decoder and shifts of negative values
local P2 = {}
for k = 0, 60 do
	P2[k + 1] = 2 ^ k
end

local function round2(x, n)
	if n == 0 then
		return x
	end
	return (x + P2[n]) // P2[n + 1]
end

local function round2signed(x, n)
	if x >= 0 then
		return round2(x, n)
	end
	return -round2(-x, n)
end

local function floorLog2(x)
	return 31 - countlz(x)
end

local function ceilLog2(x)
	if x < 2 then
		return 0
	end
	local i, p = 1, 2
	while p < x do
		i += 1
		p *= 2
	end
	return i
end

------------------------------------------------------------------------------------------------------------------------
-- tables (1-based, row-major)

local Num4x4W = { 1, 1, 2, 2, 2, 4, 4, 4, 8, 8, 8, 16, 16, 16, 32, 32, 1, 4, 2, 8, 4, 16 }
local Num4x4H = { 1, 2, 1, 2, 4, 2, 4, 8, 4, 8, 16, 8, 16, 32, 16, 32, 4, 1, 8, 2, 16, 4 }
local MiWLog2 = { 0, 0, 1, 1, 1, 2, 2, 2, 3, 3, 3, 4, 4, 4, 5, 5, 0, 2, 1, 3, 2, 4 }
local MiHLog2 = { 0, 1, 0, 1, 2, 1, 2, 3, 2, 3, 4, 3, 4, 5, 4, 5, 2, 0, 3, 1, 4, 2 }
local BlockW, BlockH = {}, {}
for i = 1, 22 do
	BlockW[i] = Num4x4W[i] * 4
	BlockH[i] = Num4x4H[i] * 4
end
local SizeGroup = Tab.Size_Group
local MaxTxSizeRect = Tab.Max_Tx_Size_Rect
local MaxTxDepth = Tab.Max_Tx_Depth
local TxW = Tab.Tx_Width
local TxH = Tab.Tx_Height
local TxWLog2 = Tab.Tx_Width_Log2
local TxHLog2 = Tab.Tx_Height_Log2
local TxSqr = Tab.Tx_Size_Sqr
local TxSqrUp = Tab.Tx_Size_Sqr_Up
local SplitTx = Tab.Split_Tx_Size
local PartitionSubsize = Tab.Partition_Subsize -- [partition][bsize]
local SubsampledSize = Tab.Subsampled_Size -- [bsize][subx][suby]
local AdjustedTx = Tab.Adjusted_Tx_Size
local ModeToTxfm = Tab.Mode_To_Txfm
local WedgeBits = Tab.Wedge_Bits

-- block size of a plane: Subsampled_Size[bsize][ssx][ssy]
local function planeSize(bsize, ssx, ssy)
	return SubsampledSize[bsize * 4 + ssx * 2 + ssy + 1]
end

-- the transform size with the given width and height
local TX_BY_WH = {}
for t = 0, 18 do
	TX_BY_WH[TxW[t + 1] * 128 + TxH[t + 1]] = t
end

-- the decoder whose state is loaded into the variables below
local D
local bb, bpos, f, su, ns, leb128, byteAlign, sequenceHeader, S, F, relDist, getQIndex, inverseRecenter, uncompressedHeader, initNonCoeffCdfs, initCoeffCdfs, loadCdfs
do

	------------------------------------------------------------------------------------------------------------------------
	-- bit reader (headers)

	bb, bpos = buffer.create(0), 0 -- buffer and bit position

	function f(n)
		local x = 0
		for _ = 1, n do
			local byte = readu8(bb, bpos // 8)
			x = x * 2 + (byte // P2[8 - bpos % 8]) % 2
			bpos += 1
		end
		return x
	end

	function su(n)
		local v = f(n)
		local m = P2[n]
		if v >= m then
			v -= 2 * m
		end
		return v
	end

	function ns(n)
		local w = floorLog2(n) + 1
		local m = P2[w + 1] - n
		local v = f(w - 1)
		if v < m then
			return v
		end
		return v * 2 - m + f(1)
	end

	function leb128(pos, limit)
		local v, mult = 0, 1
		for _ = 1, 8 do
			if pos >= limit then
				fail("truncated size field")
			end
			local b = readu8(bb, pos)
			pos += 1
			v += (b % 128) * mult
			mult *= 128
			if b < 128 then
				break
			end
		end
		return v, pos
	end

	local function uvlc()
		local lz = 0
		while f(1) == 0 do
			lz += 1
			if lz >= 32 then
				return 0xFFFFFFFF
			end
		end
		return f(lz) + P2[lz + 1] - 1
	end

	function byteAlign()
		bpos = (bpos + 7) // 8 * 8
	end

	------------------------------------------------------------------------------------------------------------------------
	-- sequence header

	local function colorConfig(S)
		local hbd = f(1)
		S.BitDepth = 8
		if S.seq_profile == 2 and hbd == 1 then
			S.BitDepth = f(1) == 1 and 12 or 10
		elseif S.seq_profile <= 2 then
			S.BitDepth = hbd == 1 and 10 or 8
		end
		S.mono_chrome = S.seq_profile ~= 1 and f(1) or 0
		S.NumPlanes = S.mono_chrome == 1 and 1 or 3
		if f(1) == 1 then
			S.color_primaries, S.transfer_characteristics, S.matrix_coefficients = f(8), f(8), f(8)
		else
			S.color_primaries, S.transfer_characteristics, S.matrix_coefficients = 2, 2, 2
		end
		S.separate_uv_delta_q = 0
		if S.mono_chrome == 1 then
			S.color_range = f(1)
			S.subsampling_x, S.subsampling_y = 1, 1
			return
		elseif S.color_primaries == 1 and S.transfer_characteristics == 13 and S.matrix_coefficients == 0 then
			S.color_range = 1
			S.subsampling_x, S.subsampling_y = 0, 0
		else
			S.color_range = f(1)
			if S.seq_profile == 0 then
				S.subsampling_x, S.subsampling_y = 1, 1
			elseif S.seq_profile == 1 then
				S.subsampling_x, S.subsampling_y = 0, 0
			elseif S.BitDepth == 12 then
				S.subsampling_x = f(1)
				S.subsampling_y = S.subsampling_x == 1 and f(1) or 0
			else
				S.subsampling_x, S.subsampling_y = 1, 0
			end
			if S.subsampling_x == 1 and S.subsampling_y == 1 then
				f(2) -- chroma sample position
			end
		end
		S.separate_uv_delta_q = f(1)
	end

	function sequenceHeader()
		local S = {}
		S.seq_profile = f(3)
		S.still_picture = f(1)
		S.reduced_still_picture_header = f(1)
		S.decoder_model_info_present_flag = 0
		S.equal_picture_interval = 0
		S.OperatingPointIdc = 0
		if S.reduced_still_picture_header == 1 then
			f(5)
		else
			if f(1) == 1 then -- timing info
				f(32)
				f(32)
				S.equal_picture_interval = f(1)
				if S.equal_picture_interval == 1 then
					uvlc()
				end
				S.decoder_model_info_present_flag = f(1)
				if S.decoder_model_info_present_flag == 1 then
					S.buffer_delay_length_minus_1 = f(5)
					f(32)
					S.buffer_removal_time_length_minus_1 = f(5)
					S.frame_presentation_time_length_minus_1 = f(5)
				end
			end
			local initialDisplayDelay = f(1)
			S.operating_points_cnt_minus_1 = f(5)
			S.operating_point_idc = {}
			S.decoder_model_present_for_this_op = {}
			for i = 0, S.operating_points_cnt_minus_1 do
				S.operating_point_idc[i] = f(12)
				local level = f(5)
				if level > 7 then
					f(1)
				end
				S.decoder_model_present_for_this_op[i] = 0
				if S.decoder_model_info_present_flag == 1 then
					S.decoder_model_present_for_this_op[i] = f(1)
					if S.decoder_model_present_for_this_op[i] == 1 then
						local n = S.buffer_delay_length_minus_1 + 1
						f(n)
						f(n)
						f(1)
					end
				end
				if initialDisplayDelay == 1 then
					if f(1) == 1 then
						f(4)
					end
				end
			end
			S.OperatingPointIdc = S.operating_point_idc[0]
		end
		S.frame_width_bits_minus_1 = f(4)
		S.frame_height_bits_minus_1 = f(4)
		S.max_frame_width_minus_1 = f(S.frame_width_bits_minus_1 + 1)
		S.max_frame_height_minus_1 = f(S.frame_height_bits_minus_1 + 1)
		S.frame_id_numbers_present_flag = S.reduced_still_picture_header == 1 and 0 or f(1)
		if S.frame_id_numbers_present_flag == 1 then
			S.delta_frame_id_length_minus_2 = f(4)
			S.additional_frame_id_length_minus_1 = f(3)
		end
		S.use_128x128_superblock = f(1)
		S.enable_filter_intra = f(1)
		S.enable_intra_edge_filter = f(1)
		if S.reduced_still_picture_header == 1 then
			S.enable_interintra_compound, S.enable_masked_compound, S.enable_warped_motion = 0, 0, 0
			S.enable_dual_filter, S.enable_order_hint, S.enable_jnt_comp, S.enable_ref_frame_mvs = 0, 0, 0, 0
			S.seq_force_screen_content_tools = 2
			S.seq_force_integer_mv = 2
			S.OrderHintBits = 0
		else
			S.enable_interintra_compound = f(1)
			S.enable_masked_compound = f(1)
			S.enable_warped_motion = f(1)
			S.enable_dual_filter = f(1)
			S.enable_order_hint = f(1)
			if S.enable_order_hint == 1 then
				S.enable_jnt_comp = f(1)
				S.enable_ref_frame_mvs = f(1)
			else
				S.enable_jnt_comp, S.enable_ref_frame_mvs = 0, 0
			end
			if f(1) == 1 then
				S.seq_force_screen_content_tools = 2
			else
				S.seq_force_screen_content_tools = f(1)
			end
			if S.seq_force_screen_content_tools > 0 then
				if f(1) == 1 then
					S.seq_force_integer_mv = 2
				else
					S.seq_force_integer_mv = f(1)
				end
			else
				S.seq_force_integer_mv = 2
			end
			S.OrderHintBits = S.enable_order_hint == 1 and f(3) + 1 or 0
		end
		S.enable_superres = f(1)
		S.enable_cdef = f(1)
		S.enable_restoration = f(1)
		colorConfig(S)
		S.film_grain_params_present = f(1)
		return S
	end

	------------------------------------------------------------------------------------------------------------------------
	-- frame header



	function relDist(a, b)
		if S.enable_order_hint == 0 then
			return 0
		end
		local diff = a - b
		local m = P2[S.OrderHintBits]
		return band(diff, m - 1) - band(diff, m)
	end

	local function superresParams()
		F.use_superres = S.enable_superres == 1 and f(1) or 0
		if F.use_superres == 1 then
			F.SuperresDenom = f(3) + 9
		else
			F.SuperresDenom = 8
		end
		F.UpscaledWidth = F.FrameWidth
		F.FrameWidth = (F.UpscaledWidth * 8 + F.SuperresDenom // 2) // F.SuperresDenom
	end

	local function computeImageSize()
		F.MiCols = 2 * ((F.FrameWidth + 7) // 8)
		F.MiRows = 2 * ((F.FrameHeight + 7) // 8)
	end

	local function frameSize()
		if F.frame_size_override_flag == 1 then
			F.FrameWidth = f(S.frame_width_bits_minus_1 + 1) + 1
			F.FrameHeight = f(S.frame_height_bits_minus_1 + 1) + 1
		else
			F.FrameWidth = S.max_frame_width_minus_1 + 1
			F.FrameHeight = S.max_frame_height_minus_1 + 1
		end
		superresParams()
		computeImageSize()
	end

	local function renderSize()
		if f(1) == 1 then
			F.RenderWidth = f(16) + 1
			F.RenderHeight = f(16) + 1
		else
			F.RenderWidth = F.UpscaledWidth
			F.RenderHeight = F.FrameHeight
		end
	end

	local function tileLog2(blk, target)
		local k = 0
		while blk * P2[k + 1] < target do
			k += 1
		end
		return k
	end

	local function tileInfo()
		local sb128 = S.use_128x128_superblock == 1
		local sbCols = sb128 and (F.MiCols + 31) // 32 or (F.MiCols + 15) // 16
		local sbRows = sb128 and (F.MiRows + 31) // 32 or (F.MiRows + 15) // 16
		local sbShift = sb128 and 5 or 4
		local sbSize = sbShift + 2
		local maxTileWidthSb = 4096 // P2[sbSize + 1]
		local maxTileAreaSb = (4096 * 2304) // P2[2 * sbSize + 1]
		local minLog2TileCols = tileLog2(maxTileWidthSb, sbCols)
		local maxLog2TileCols = tileLog2(1, min(sbCols, 64))
		local maxLog2TileRows = tileLog2(1, min(sbRows, 64))
		local minLog2Tiles = max(minLog2TileCols, tileLog2(maxTileAreaSb, sbRows * sbCols))
		local colStarts, rowStarts = {}, {}
		F.MiColStarts, F.MiRowStarts = colStarts, rowStarts
		if f(1) == 1 then
			F.TileColsLog2 = minLog2TileCols
			while F.TileColsLog2 < maxLog2TileCols do
				if f(1) == 1 then
					F.TileColsLog2 += 1
				else
					break
				end
			end
			local tileWidthSb = (sbCols + P2[F.TileColsLog2 + 1] - 1) // P2[F.TileColsLog2 + 1]
			local i = 0
			local startSb = 0
			while startSb < sbCols do
				colStarts[i] = startSb * P2[sbShift + 1]
				i += 1
				startSb += tileWidthSb
			end
			colStarts[i] = F.MiCols
			F.TileCols = i
			local minLog2TileRows = max(minLog2Tiles - F.TileColsLog2, 0)
			F.TileRowsLog2 = minLog2TileRows
			while F.TileRowsLog2 < maxLog2TileRows do
				if f(1) == 1 then
					F.TileRowsLog2 += 1
				else
					break
				end
			end
			local tileHeightSb = (sbRows + P2[F.TileRowsLog2 + 1] - 1) // P2[F.TileRowsLog2 + 1]
			i = 0
			startSb = 0
			while startSb < sbRows do
				rowStarts[i] = startSb * P2[sbShift + 1]
				i += 1
				startSb += tileHeightSb
			end
			rowStarts[i] = F.MiRows
			F.TileRows = i
		else
			local widestTileSb = 0
			local startSb = 0
			local i = 0
			while startSb < sbCols do
				colStarts[i] = startSb * P2[sbShift + 1]
				local maxWidth = min(sbCols - startSb, maxTileWidthSb)
				local sizeSb = ns(maxWidth) + 1
				widestTileSb = max(sizeSb, widestTileSb)
				startSb += sizeSb
				i += 1
			end
			colStarts[i] = F.MiCols
			F.TileCols = i
			F.TileColsLog2 = tileLog2(1, F.TileCols)
			if minLog2Tiles > 0 then
				maxTileAreaSb = (sbRows * sbCols) // P2[minLog2Tiles + 2]
			else
				maxTileAreaSb = sbRows * sbCols
			end
			local maxTileHeightSb = max(maxTileAreaSb // widestTileSb, 1)
			startSb = 0
			i = 0
			while startSb < sbRows do
				rowStarts[i] = startSb * P2[sbShift + 1]
				local maxHeight = min(sbRows - startSb, maxTileHeightSb)
				startSb += ns(maxHeight) + 1
				i += 1
			end
			rowStarts[i] = F.MiRows
			F.TileRows = i
			F.TileRowsLog2 = tileLog2(1, F.TileRows)
		end
		F.context_update_tile_id = 0
		F.TileSizeBytes = 4
		if F.TileColsLog2 > 0 or F.TileRowsLog2 > 0 then
			F.context_update_tile_id = f(F.TileRowsLog2 + F.TileColsLog2)
			F.TileSizeBytes = f(2) + 1
		end
	end

	local function readDeltaQ()
		if f(1) == 1 then
			return su(7)
		end
		return 0
	end

	local SEG_BITS = { 8, 6, 6, 6, 6, 3, 0, 0 }
	local SEG_SIGNED = { 1, 1, 1, 1, 1, 0, 0, 0 }
	local SEG_MAX = { 255, 63, 63, 63, 63, 7, 0, 0 }

	local function segmentationParams()
		F.segmentation_enabled = f(1)
		F.segmentation_update_map = 0
		F.segmentation_temporal_update = 0
		local FE, FD = F.FeatureEnabled, F.FeatureData -- [seg * 8 + feature + 1]
		if F.segmentation_enabled == 1 then
			local updateData
			if F.primary_ref_frame == 7 then
				F.segmentation_update_map = 1
				F.segmentation_temporal_update = 0
				updateData = 1
			else
				F.segmentation_update_map = f(1)
				if F.segmentation_update_map == 1 then
					F.segmentation_temporal_update = f(1)
				end
				updateData = f(1)
			end
			if updateData == 1 then
				for i = 0, 7 do
					for j = 0, 7 do
						local en = f(1)
						local v = 0
						if en == 1 then
							local bits = SEG_BITS[j + 1]
							local limit = SEG_MAX[j + 1]
							if SEG_SIGNED[j + 1] == 1 then
								v = math.clamp(su(1 + bits), -limit, limit)
							else
								v = math.clamp(f(bits), 0, limit)
							end
						end
						FE[i * 8 + j + 1] = en
						FD[i * 8 + j + 1] = v
					end
				end
			end
		else
			for k = 1, 64 do
				FE[k] = 0
				FD[k] = 0
			end
		end
		F.SegIdPreSkip = 0
		F.LastActiveSegId = 0
		for i = 0, 7 do
			for j = 0, 7 do
				if FE[i * 8 + j + 1] == 1 then
					F.LastActiveSegId = i
					if j >= 5 then
						F.SegIdPreSkip = 1
					end
				end
			end
		end
	end

	function getQIndex(ignoreDeltaQ, segmentId, currentQIndex)
		if F.segmentation_enabled == 1 and F.FeatureEnabled[segmentId * 8 + 1] == 1 then
			local data = F.FeatureData[segmentId * 8 + 1]
			local q = F.base_q_idx + data
			if ignoreDeltaQ == 0 and F.delta_q_present == 1 then
				q = currentQIndex + data
			end
			return math.clamp(q, 0, 255)
		end
		if ignoreDeltaQ == 0 and F.delta_q_present == 1 then
			return currentQIndex
		end
		return F.base_q_idx
	end

	local function decodeSubexp(numSyms)
		local i, mk, k = 0, 0, 3
		while true do
			local b2 = i > 0 and k + i - 1 or k
			local a = P2[b2 + 1]
			if numSyms <= mk + 3 * a then
				return ns(numSyms - mk) + mk
			elseif f(1) == 1 then
				i += 1
				mk += a
			else
				return f(b2) + mk
			end
		end
	end

	function inverseRecenter(r, v)
		if v > 2 * r then
			return v
		elseif v % 2 == 1 then
			return r - (v + 1) // 2
		end
		return r + v // 2
	end

	local function decodeSignedSubexpWithRef(low, high, r)
		local mx = high - low
		r -= low
		local v = decodeSubexp(mx)
		local x
		if r * 2 <= mx then
			x = inverseRecenter(r, v)
		else
			x = mx - 1 - inverseRecenter(mx - 1 - r, v)
		end
		return x + low
	end

	local function readGlobalParam(typ, ref, idx)
		local absBits, precBits = 12, 15
		if idx < 2 then
			if typ == 1 then
				local hp = F.allow_high_precision_mv == 1 and 0 or 1
				absBits = 9 - hp
				precBits = 3 - hp
			else
				absBits = 12
				precBits = 6
			end
		end
		local precDiff = 16 - precBits
		local round = idx % 3 == 2 and 65536 or 0
		local sub = idx % 3 == 2 and P2[precBits + 1] or 0
		local mx = P2[absBits + 1]
		local r = F.PrevGmParams[ref * 6 + idx + 1] // P2[precDiff + 1] - sub
		F.gm_params[ref * 6 + idx + 1] = decodeSignedSubexpWithRef(-mx, mx + 1, r) * P2[precDiff + 1] + round
	end

	local function globalMotionParams()
		local gm = {}
		F.gm_params = gm
		F.GmType = {}
		for ref = 1, 7 do
			F.GmType[ref] = 0
			for i = 0, 5 do
				gm[ref * 6 + i + 1] = i % 3 == 2 and 65536 or 0
			end
		end
		if F.FrameIsIntra == 1 then
			return
		end
		for ref = 1, 7 do
			local typ = 0
			if f(1) == 1 then
				if f(1) == 1 then
					typ = 2
				else
					typ = f(1) == 1 and 1 or 3
				end
			end
			F.GmType[ref] = typ
			if typ >= 2 then
				readGlobalParam(typ, ref, 2)
				readGlobalParam(typ, ref, 3)
				if typ == 3 then
					readGlobalParam(typ, ref, 4)
					readGlobalParam(typ, ref, 5)
				else
					gm[ref * 6 + 5] = -gm[ref * 6 + 4]
					gm[ref * 6 + 6] = gm[ref * 6 + 3]
				end
			end
			if typ >= 1 then
				readGlobalParam(typ, ref, 0)
				readGlobalParam(typ, ref, 1)
			end
		end
	end

	local function resetGrain()
		F.grain = { apply_grain = 0 }
	end

	local function filmGrainParams()
		if S.film_grain_params_present == 0 or (F.show_frame == 0 and F.showable_frame == 0) then
			resetGrain()
			return
		end
		local g = { apply_grain = f(1) }
		F.grain = g
		if g.apply_grain == 0 then
			return
		end
		g.grain_seed = f(16)
		local update = F.frame_type == 1 and f(1) or 1
		if update == 0 then
			local idx = f(3)
			local seed = g.grain_seed
			local src = D.refs[idx].grain
			g = table.clone(src or { apply_grain = 0 })
			g.grain_seed = seed
			F.grain = g
			return
		end
		g.num_y_points = f(4)
		g.point_y_value, g.point_y_scaling = {}, {}
		for i = 0, g.num_y_points - 1 do
			g.point_y_value[i] = f(8)
			g.point_y_scaling[i] = f(8)
		end
		g.chroma_scaling_from_luma = S.mono_chrome == 1 and 0 or f(1)
		g.point_cb_value, g.point_cb_scaling, g.point_cr_value, g.point_cr_scaling = {}, {}, {}, {}
		if S.mono_chrome == 1 or g.chroma_scaling_from_luma == 1
			or (S.subsampling_x == 1 and S.subsampling_y == 1 and g.num_y_points == 0) then
			g.num_cb_points, g.num_cr_points = 0, 0
		else
			g.num_cb_points = f(4)
			for i = 0, g.num_cb_points - 1 do
				g.point_cb_value[i] = f(8)
				g.point_cb_scaling[i] = f(8)
			end
			g.num_cr_points = f(4)
			for i = 0, g.num_cr_points - 1 do
				g.point_cr_value[i] = f(8)
				g.point_cr_scaling[i] = f(8)
			end
		end
		g.grain_scaling_minus_8 = f(2)
		g.ar_coeff_lag = f(2)
		local numPosLuma = 2 * g.ar_coeff_lag * (g.ar_coeff_lag + 1)
		local numPosChroma = numPosLuma
		g.ar_coeffs_y, g.ar_coeffs_cb, g.ar_coeffs_cr = {}, {}, {}
		if g.num_y_points > 0 then
			numPosChroma = numPosLuma + 1
			for i = 0, numPosLuma - 1 do
				g.ar_coeffs_y[i] = f(8) - 128
			end
		end
		if g.chroma_scaling_from_luma == 1 or g.num_cb_points > 0 then
			for i = 0, numPosChroma - 1 do
				g.ar_coeffs_cb[i] = f(8) - 128
			end
		end
		if g.chroma_scaling_from_luma == 1 or g.num_cr_points > 0 then
			for i = 0, numPosChroma - 1 do
				g.ar_coeffs_cr[i] = f(8) - 128
			end
		end
		g.ar_coeff_shift_minus_6 = f(2)
		g.grain_scale_shift = f(2)
		if g.num_cb_points > 0 then
			g.cb_mult, g.cb_luma_mult, g.cb_offset = f(8), f(8), f(9)
		end
		if g.num_cr_points > 0 then
			g.cr_mult, g.cr_luma_mult, g.cr_offset = f(8), f(8), f(9)
		end
		g.overlap_flag = f(1)
		g.clip_to_restricted_range = f(1)
	end

	local function temporalPointInfo()
		f(S.frame_presentation_time_length_minus_1 + 1)
	end

	local function setFrameRefs(lastIdx, goldIdx)
		local idx = F.ref_frame_idx
		for i = 0, 6 do
			idx[i] = -1
		end
		idx[0] = lastIdx
		idx[3] = goldIdx
		local used = {}
		for i = 0, 7 do
			used[i] = false
		end
		used[lastIdx] = true
		used[goldIdx] = true
		local curFrameHint = P2[S.OrderHintBits]
		local shifted = {}
		for i = 0, 7 do
			shifted[i] = curFrameHint + relDist(D.refs[i].RefOrderHint, F.OrderHint)
		end
		local function latestBackward()
			local ref, latest = -1, 0
			for i = 0, 7 do
				local hint = shifted[i]
				if not used[i] and hint >= curFrameHint and (ref < 0 or hint >= latest) then
					ref, latest = i, hint
				end
			end
			return ref
		end
		local function earliestBackward()
			local ref, earliest = -1, 0
			for i = 0, 7 do
				local hint = shifted[i]
				if not used[i] and hint >= curFrameHint and (ref < 0 or hint < earliest) then
					ref, earliest = i, hint
				end
			end
			return ref
		end
		local ref = latestBackward()
		if ref >= 0 then
			idx[6] = ref
			used[ref] = true
		end
		ref = earliestBackward()
		if ref >= 0 then
			idx[4] = ref
			used[ref] = true
		end
		ref = earliestBackward()
		if ref >= 0 then
			idx[5] = ref
			used[ref] = true
		end
		for _, refFrame in { 2, 3, 5, 6, 7 } do
			if idx[refFrame - 1] < 0 then
				local r, latest = -1, 0
				for i = 0, 7 do
					local hint = shifted[i]
					if not used[i] and hint < curFrameHint and (r < 0 or hint >= latest) then
						r, latest = i, hint
					end
				end
				if r >= 0 then
					idx[refFrame - 1] = r
					used[r] = true
				end
			end
		end
		ref = -1
		local earliest = 0
		for i = 0, 7 do
			local hint = shifted[i]
			if ref < 0 or hint < earliest then
				ref, earliest = i, hint
			end
		end
		for i = 0, 6 do
			if idx[i] < 0 then
				idx[i] = ref
			end
		end
	end



	local function setupPastIndependence()
		for k = 1, 64 do
			F.FeatureEnabled[k] = 0
			F.FeatureData[k] = 0
		end
		F.PrevSegmentIds = nil
		local pg = {}
		for ref = 1, 7 do
			for i = 0, 5 do
				pg[ref * 6 + i + 1] = i % 3 == 2 and 65536 or 0
			end
		end
		F.PrevGmParams = pg
		F.loop_filter_delta_enabled = 1
		F.loop_filter_ref_deltas = { [0] = 1, 0, 0, 0, -1, 0, -1, -1 }
		F.loop_filter_mode_deltas = { [0] = 0, 0 }
	end

	local function loadPrevious()
		local prev = D.refs[F.ref_frame_idx[F.primary_ref_frame]]
		F.PrevGmParams = table.clone(prev.gm_params)
		F.loop_filter_ref_deltas = table.clone(prev.loop_filter_ref_deltas)
		F.loop_filter_mode_deltas = table.clone(prev.loop_filter_mode_deltas)
		F.FeatureEnabled = table.clone(prev.FeatureEnabled)
		F.FeatureData = table.clone(prev.FeatureData)
	end

	-- uncompressed_header(); returns false when the frame shows an existing frame
	function uncompressedHeader()
		local idLen = 0
		if S.frame_id_numbers_present_flag == 1 then
			idLen = S.additional_frame_id_length_minus_1 + S.delta_frame_id_length_minus_2 + 3
		end
		local refs = D.refs
		F.FeatureEnabled, F.FeatureData = table.create(64, 0), table.create(64, 0)
		if S.reduced_still_picture_header == 1 then
			F.show_existing_frame = 0
			F.frame_type = 0
			F.FrameIsIntra = 1
			F.show_frame = 1
			F.showable_frame = 0
			F.error_resilient_mode = 1
		else
			F.show_existing_frame = f(1)
			if F.show_existing_frame == 1 then
				F.frame_to_show_map_idx = f(3)
				if S.decoder_model_info_present_flag == 1 and S.equal_picture_interval == 0 then
					temporalPointInfo()
				end
				F.refresh_frame_flags = 0
				if S.frame_id_numbers_present_flag == 1 then
					f(idLen)
				end
				F.frame_type = refs[F.frame_to_show_map_idx].RefFrameType
				if F.frame_type == 0 then
					F.refresh_frame_flags = 255
				end
				return
			end
			F.frame_type = f(2)
			F.FrameIsIntra = (F.frame_type == 2 or F.frame_type == 0) and 1 or 0
			F.show_frame = f(1)
			if F.show_frame == 1 and S.decoder_model_info_present_flag == 1 and S.equal_picture_interval == 0 then
				temporalPointInfo()
			end
			if F.show_frame == 1 then
				F.showable_frame = F.frame_type ~= 0 and 1 or 0
			else
				F.showable_frame = f(1)
			end
			if F.frame_type == 3 or (F.frame_type == 0 and F.show_frame == 1) then
				F.error_resilient_mode = 1
			else
				F.error_resilient_mode = f(1)
			end
		end
		if F.frame_type == 0 and F.show_frame == 1 then
			for i = 0, 7 do
				refs[i].RefValid = 0
				refs[i].RefOrderHint = 0
			end
			for i = 0, 6 do
				F.OrderHints[i + 1] = 0
			end
		end
		F.disable_cdf_update = f(1)
		if S.seq_force_screen_content_tools == 2 then
			F.allow_screen_content_tools = f(1)
		else
			F.allow_screen_content_tools = S.seq_force_screen_content_tools
		end
		if F.allow_screen_content_tools == 1 then
			if S.seq_force_integer_mv == 2 then
				F.force_integer_mv = f(1)
			else
				F.force_integer_mv = S.seq_force_integer_mv
			end
		else
			F.force_integer_mv = 0
		end
		if F.FrameIsIntra == 1 then
			F.force_integer_mv = 1
		end
		if S.frame_id_numbers_present_flag == 1 then
			F.current_frame_id = f(idLen)
		else
			F.current_frame_id = 0
		end
		if F.frame_type == 3 then
			F.frame_size_override_flag = 1
		elseif S.reduced_still_picture_header == 1 then
			F.frame_size_override_flag = 0
		else
			F.frame_size_override_flag = f(1)
		end
		F.OrderHint = f(S.OrderHintBits)
		if F.FrameIsIntra == 1 or F.error_resilient_mode == 1 then
			F.primary_ref_frame = 7
		else
			F.primary_ref_frame = f(3)
		end
		if S.decoder_model_info_present_flag == 1 then
			if f(1) == 1 then
				for op = 0, S.operating_points_cnt_minus_1 do
					if S.decoder_model_present_for_this_op[op] == 1 then
						local idc = S.operating_point_idc[op]
						local inT = band(rshift(idc, D.temporal_id), 1)
						local inS = band(rshift(idc, D.spatial_id + 8), 1)
						if idc == 0 or (inT == 1 and inS == 1) then
							f(S.buffer_removal_time_length_minus_1 + 1)
						end
					end
				end
			end
		end
		F.allow_high_precision_mv = 0
		F.use_ref_frame_mvs = 0
		F.allow_intrabc = 0
		if F.frame_type == 3 or (F.frame_type == 0 and F.show_frame == 1) then
			F.refresh_frame_flags = 255
		else
			F.refresh_frame_flags = f(8)
		end
		if F.FrameIsIntra == 0 or F.refresh_frame_flags ~= 255 then
			if F.error_resilient_mode == 1 and S.enable_order_hint == 1 then
				for i = 0, 7 do
					local h = f(S.OrderHintBits)
					if h ~= refs[i].RefOrderHint then
						refs[i].RefValid = 0
						refs[i].RefOrderHint = h
					end
				end
			end
		end
		F.ref_frame_idx = {}
		if F.FrameIsIntra == 1 then
			frameSize()
			renderSize()
			if F.allow_screen_content_tools == 1 and F.UpscaledWidth == F.FrameWidth then
				F.allow_intrabc = f(1)
			end
		else
			local short = 0
			if S.enable_order_hint == 1 then
				short = f(1)
				if short == 1 then
					local lastIdx = f(3)
					local goldIdx = f(3)
					setFrameRefs(lastIdx, goldIdx)
				end
			end
			for i = 0, 6 do
				if short == 0 then
					F.ref_frame_idx[i] = f(3)
				end
				if S.frame_id_numbers_present_flag == 1 then
					f(S.delta_frame_id_length_minus_2 + 2)
				end
			end
			for i = 0, 6 do
				if refs[F.ref_frame_idx[i]].RefValid ~= 1 then
					fail("a frame refers to a frame that is missing")
				end
			end
			if F.frame_size_override_flag == 1 and F.error_resilient_mode == 0 then
				local found = 0
				for i = 0, 6 do
					found = f(1)
					if found == 1 then
						local r = refs[F.ref_frame_idx[i]]
						F.UpscaledWidth = r.RefUpscaledWidth
						F.FrameWidth = F.UpscaledWidth
						F.FrameHeight = r.RefFrameHeight
						F.RenderWidth = r.RefRenderWidth
						F.RenderHeight = r.RefRenderHeight
						break
					end
				end
				if found == 0 then
					frameSize()
					renderSize()
				else
					superresParams()
					computeImageSize()
				end
			else
				frameSize()
				renderSize()
			end
			if F.force_integer_mv == 1 then
				F.allow_high_precision_mv = 0
			else
				F.allow_high_precision_mv = f(1)
			end
			if f(1) == 1 then
				F.interpolation_filter = 4
			else
				F.interpolation_filter = f(2)
			end
			F.is_motion_mode_switchable = f(1)
			if F.error_resilient_mode == 1 or S.enable_ref_frame_mvs == 0 then
				F.use_ref_frame_mvs = 0
			else
				F.use_ref_frame_mvs = f(1)
			end
			F.RefFrameSignBias = {}
			for i = 0, 6 do
				local refFrame = i + 1
				local hint = refs[F.ref_frame_idx[i]].RefOrderHint
				F.OrderHints[refFrame] = hint
				if S.enable_order_hint == 0 then
					F.RefFrameSignBias[refFrame] = 0
				else
					F.RefFrameSignBias[refFrame] = relDist(hint, F.OrderHint) > 0 and 1 or 0
				end
			end
		end
		if S.reduced_still_picture_header == 1 or F.disable_cdf_update == 1 then
			F.disable_frame_end_update_cdf = 1
		else
			F.disable_frame_end_update_cdf = f(1)
		end
		if F.primary_ref_frame == 7 then
			initNonCoeffCdfs()
			setupPastIndependence()
		else
			loadCdfs(F.ref_frame_idx[F.primary_ref_frame])
			loadPrevious()
		end
		-- (motion field estimation runs once the frame's arrays are set up)
		tileInfo()
		-- quantization_params
		F.base_q_idx = f(8)
		F.DeltaQYDc = readDeltaQ()
		if S.NumPlanes > 1 then
			local diffUv = S.separate_uv_delta_q == 1 and f(1) or 0
			F.DeltaQUDc = readDeltaQ()
			F.DeltaQUAc = readDeltaQ()
			if diffUv == 1 then
				F.DeltaQVDc = readDeltaQ()
				F.DeltaQVAc = readDeltaQ()
			else
				F.DeltaQVDc, F.DeltaQVAc = F.DeltaQUDc, F.DeltaQUAc
			end
		else
			F.DeltaQUDc, F.DeltaQUAc, F.DeltaQVDc, F.DeltaQVAc = 0, 0, 0, 0
		end
		F.using_qmatrix = f(1)
		if F.using_qmatrix == 1 then
			F.qm_y = f(4)
			F.qm_u = f(4)
			F.qm_v = S.separate_uv_delta_q == 1 and f(4) or F.qm_u
		end
		segmentationParams()
		-- delta_q_params / delta_lf_params
		F.delta_q_res, F.delta_q_present = 0, 0
		if F.base_q_idx > 0 then
			F.delta_q_present = f(1)
		end
		if F.delta_q_present == 1 then
			F.delta_q_res = f(2)
		end
		F.delta_lf_present, F.delta_lf_res, F.delta_lf_multi = 0, 0, 0
		if F.delta_q_present == 1 then
			if F.allow_intrabc == 0 then
				F.delta_lf_present = f(1)
			end
			if F.delta_lf_present == 1 then
				F.delta_lf_res = f(2)
				F.delta_lf_multi = f(1)
			end
		end
		if F.primary_ref_frame == 7 then
			initCoeffCdfs()
		else
			F.loadPrevSegmentIds = true
		end
		F.CodedLossless = 1
		F.LosslessArray = {}
		F.SegQMLevel = {}
		for segmentId = 0, 7 do
			local q = getQIndex(1, segmentId, 0)
			local lossless = q == 0 and F.DeltaQYDc == 0 and F.DeltaQUAc == 0 and F.DeltaQUDc == 0
				and F.DeltaQVAc == 0 and F.DeltaQVDc == 0
			F.LosslessArray[segmentId] = lossless and 1 or 0
			if not lossless then
				F.CodedLossless = 0
			end
			if F.using_qmatrix == 1 then
				F.SegQMLevel[segmentId] = lossless and 15 or F.qm_y
				F.SegQMLevel[8 + segmentId] = lossless and 15 or F.qm_u
				F.SegQMLevel[16 + segmentId] = lossless and 15 or F.qm_v
			end
		end
		F.AllLossless = (F.CodedLossless == 1 and F.FrameWidth == F.UpscaledWidth) and 1 or 0
		-- loop_filter_params
		F.loop_filter_level = { [0] = 0, 0, 0, 0 }
		F.loop_filter_sharpness = 0
		if F.CodedLossless == 1 or F.allow_intrabc == 1 then
			F.loop_filter_ref_deltas = { [0] = 1, 0, 0, 0, -1, 0, -1, -1 }
			F.loop_filter_mode_deltas = { [0] = 0, 0 }
		else
			local lvl = F.loop_filter_level
			lvl[0] = f(6)
			lvl[1] = f(6)
			if S.NumPlanes > 1 and (lvl[0] ~= 0 or lvl[1] ~= 0) then
				lvl[2] = f(6)
				lvl[3] = f(6)
			end
			F.loop_filter_sharpness = f(3)
			F.loop_filter_delta_enabled = f(1)
			if F.loop_filter_delta_enabled == 1 then
				if f(1) == 1 then
					for i = 0, 7 do
						if f(1) == 1 then
							F.loop_filter_ref_deltas[i] = su(7)
						end
					end
					for i = 0, 1 do
						if f(1) == 1 then
							F.loop_filter_mode_deltas[i] = su(7)
						end
					end
				end
			end
		end
		-- cdef_params
		F.cdef_y_pri, F.cdef_y_sec, F.cdef_uv_pri, F.cdef_uv_sec = { [0] = 0 }, { [0] = 0 }, { [0] = 0 }, { [0] = 0 }
		F.cdef_bits = 0
		F.CdefDamping = 3
		F.cdefOn = false
		if not (F.CodedLossless == 1 or F.allow_intrabc == 1 or S.enable_cdef == 0) then
			F.cdefOn = true
			F.CdefDamping = f(2) + 3
			F.cdef_bits = f(2)
			for i = 0, P2[F.cdef_bits + 1] - 1 do
				F.cdef_y_pri[i] = f(4)
				F.cdef_y_sec[i] = f(2)
				if F.cdef_y_sec[i] == 3 then
					F.cdef_y_sec[i] += 1
				end
				if S.NumPlanes > 1 then
					F.cdef_uv_pri[i] = f(4)
					F.cdef_uv_sec[i] = f(2)
					if F.cdef_uv_sec[i] == 3 then
						F.cdef_uv_sec[i] += 1
					end
				end
			end
		end
		-- lr_params
		F.FrameRestorationType = { [0] = 0, 0, 0 }
		F.UsesLr = 0
		F.LoopRestorationSize = { [0] = 64, 64, 64 }
		if not (F.AllLossless == 1 or F.allow_intrabc == 1 or S.enable_restoration == 0) then
			local usesChromaLr = false
			local remap = { [0] = 0, 3, 1, 2 }
			for i = 0, S.NumPlanes - 1 do
				local t = remap[f(2)]
				F.FrameRestorationType[i] = t
				if t ~= 0 then
					F.UsesLr = 1
					if i > 0 then
						usesChromaLr = true
					end
				end
			end
			if F.UsesLr == 1 then
				local shift
				if S.use_128x128_superblock == 1 then
					shift = f(1) + 1
				else
					shift = f(1)
					if shift == 1 then
						shift += f(1)
					end
				end
				local size = 256 // P2[3 - shift]
				local uvShift = 0
				if S.subsampling_x == 1 and S.subsampling_y == 1 and usesChromaLr then
					uvShift = f(1)
				end
				F.LoopRestorationSize[0] = size
				F.LoopRestorationSize[1] = size // P2[uvShift + 1]
				F.LoopRestorationSize[2] = size // P2[uvShift + 1]
			end
		end
		-- read_tx_mode
		if F.CodedLossless == 1 then
			F.TxMode = 0
		else
			F.TxMode = f(1) == 1 and 2 or 1
		end
		-- frame_reference_mode
		F.reference_select = F.FrameIsIntra == 1 and 0 or f(1)
		-- skip_mode_params
		F.skip_mode_present = 0
		F.SkipModeFrame = { [0] = 0, 0 }
		if not (F.FrameIsIntra == 1 or F.reference_select == 0 or S.enable_order_hint == 0) then
			local forwardIdx, backwardIdx = -1, -1
			local forwardHint, backwardHint = 0, 0
			for i = 0, 6 do
				local refHint = refs[F.ref_frame_idx[i]].RefOrderHint
				if relDist(refHint, F.OrderHint) < 0 then
					if forwardIdx < 0 or relDist(refHint, forwardHint) > 0 then
						forwardIdx = i
						forwardHint = refHint
					end
				elseif relDist(refHint, F.OrderHint) > 0 then
					if backwardIdx < 0 or relDist(refHint, backwardHint) < 0 then
						backwardIdx = i
						backwardHint = refHint
					end
				end
			end
			local allowed = false
			if forwardIdx < 0 then
				allowed = false
			elseif backwardIdx >= 0 then
				allowed = true
				F.SkipModeFrame[0] = 1 + min(forwardIdx, backwardIdx)
				F.SkipModeFrame[1] = 1 + max(forwardIdx, backwardIdx)
			else
				local secondIdx, secondHint = -1, 0
				for i = 0, 6 do
					local refHint = refs[F.ref_frame_idx[i]].RefOrderHint
					if relDist(refHint, forwardHint) < 0 then
						if secondIdx < 0 or relDist(refHint, secondHint) > 0 then
							secondIdx = i
							secondHint = refHint
						end
					end
				end
				if secondIdx >= 0 then
					allowed = true
					F.SkipModeFrame[0] = 1 + min(forwardIdx, secondIdx)
					F.SkipModeFrame[1] = 1 + max(forwardIdx, secondIdx)
				end
			end
			if allowed then
				F.skip_mode_present = f(1)
			end
		end
		if F.FrameIsIntra == 1 or F.error_resilient_mode == 1 or S.enable_warped_motion == 0 then
			F.allow_warped_motion = 0
		else
			F.allow_warped_motion = f(1)
		end
		F.reduced_tx_set = f(1)
		globalMotionParams()
		filmGrainParams()
	end

end
local CDF_INIT, C, FC, SAVED, cdfUpdate, initSymbol, sym, symFixed2, bool, literal, symNS
do

	------------------------------------------------------------------------------------------------------------------------
	-- probability tables
	--
	-- Every adaptive distribution lives in one flat array: N inverted cumulative values (32768 - cdf) followed by a use
	-- counter. C is the set used by the tile being decoded, FC the frame's set; reference slots keep copies.

	CDF_INIT = Tab.CDF_INIT
	local CDF_COEF = { [0] = Tab.CDF_COEF0, Tab.CDF_COEF1, Tab.CDF_COEF2, Tab.CDF_COEF3 }
	C = tcreate(7885, 0) -- tile probabilities
	FC = tcreate(7885, 0) -- frame probabilities
	SAVED = tcreate(7885, 0) -- probabilities kept from the tile named by context_update_tile_id

	function initNonCoeffCdfs()
		tmove(CDF_INIT, 1, 3887 - 1, 1, FC)
	end

	function initCoeffCdfs()
		local q = F.base_q_idx
		local idx = q <= 20 and 0 or q <= 60 and 1 or q <= 120 and 2 or 3
		tmove(CDF_COEF[idx], 1, 7885 - 3887 + 1, 3887, FC)
	end

	-- positions of the use counters (reset when probabilities are taken over from a reference frame)
	local COUNTER_AT = Tab.CDF_COUNTERS

	function loadCdfs(slot)
		local src = D.refs[slot].cdf
		if not src then
			fail("missing probability tables of a reference frame")
		end
		tmove(src, 1, 7885, 1, FC)
		for i = 1, #COUNTER_AT do
			FC[COUNTER_AT[i]] = 0
		end
	end

	------------------------------------------------------------------------------------------------------------------------
	-- arithmetic (symbol) decoder
	--
	-- dif holds the decoder value at bit 32 and up, with up to 32 more bits of the (inverted) stream below; cnt counts
	-- those extra bits.

	local sb, spos, send = buffer.create(0), 0, 0 -- tile data
	local dif, rng, cnt = 0, 0, 0
	cdfUpdate = true
	local TWO32 = 4294967296

	local function refill()
		while cnt <= 24 do
			local byte = 0
			if spos < send then
				byte = readu8(sb, spos)
				spos += 1
			end
			dif += (255 - byte) * P2[25 - cnt]
			cnt += 8
		end
	end

	function initSymbol(buf, pos, size)
		sb, spos, send = buf, pos, pos + size
		dif = 0
		for i = 0, 4 do
			local byte = 0
			if spos < send then
				byte = readu8(sb, spos)
				spos += 1
			end
			dif += (255 - byte) * P2[40 - 8 * i]
		end
		cnt = 25
		rng = 32768
	end

	-- adaptation rate base by alphabet size: 3 + min(FloorLog2(N), 2) (+1 / +2 as the counter grows)
	local RATE = { 4, 4, 5, 5, 5, 5, 5, 5, 5, 5, 5, 5, 5, 5, 5, 5, 5 }
	RATE[2], RATE[3] = 4, 4

	function sym(off, n)
		local r8 = rng // 256
		local prev = rng
		local s = 0
		local cur
		local d32 = dif // TWO32
		while true do
			cur = (r8 * (C[off + s] // 64)) // 2 + 4 * (n - s - 1)
			if d32 >= cur then
				break
			end
			prev = cur
			s += 1
		end
		rng = prev - cur
		dif -= cur * TWO32
		local d = countlz(rng) - 16
		if d > 0 then
			rng *= P2[d + 1]
			dif *= P2[d + 1]
			cnt -= d
			if cnt <= 24 then
				refill()
			end
		end
		if cdfUpdate then
			local cv = C[off + n]
			local rate = RATE[n] + (cv > 15 and 1 or 0) + (cv > 31 and 1 or 0)
			local div = P2[rate + 1]
			for i = 0, n - 2 do
				local v = C[off + i]
				if i < s then
					C[off + i] = v + (32768 - v) // div
				else
					C[off + i] = v - v // div
				end
			end
			if cv < 32 then
				C[off + n] = cv + 1
			end
		end
		return s
	end

	-- a binary symbol from an explicit (non-adapting) probability: p = 32768 - cdf[0]
	function symFixed2(icdf0)
		local cur = ((rng // 256) * (icdf0 // 64)) // 2 + 4
		local s
		if dif // TWO32 >= cur then
			s = 0
			rng -= cur
			dif -= cur * TWO32
		else
			s = 1
			rng = cur
		end
		local d = countlz(rng) - 16
		if d > 0 then
			rng *= P2[d + 1]
			dif *= P2[d + 1]
			cnt -= d
			if cnt <= 24 then
				refill()
			end
		end
		return s
	end

	function bool()
		local cur = (rng // 256) * 128 + 4
		local s
		if dif // TWO32 >= cur then
			s = 0
			rng -= cur
			dif -= cur * TWO32
		else
			s = 1
			rng = cur
		end
		local d = countlz(rng) - 16
		if d > 0 then
			rng *= P2[d + 1]
			dif *= P2[d + 1]
			cnt -= d
			if cnt <= 24 then
				refill()
			end
		end
		return s
	end

	function literal(n)
		local x = 0
		for _ = 1, n do
			x = x * 2 + bool()
		end
		return x
	end

	-- NS(n): a uniformly coded value below n
	function symNS(n)
		local w = floorLog2(n) + 1
		local m = P2[w + 1] - n
		local v = literal(w - 1)
		if v < m then
			return v
		end
		return v * 2 - m + literal(1)
	end

end

------------------------------------------------------------------------------------------------------------------------
-- frame-wide block information (per 4x4 unit: index row * MiCols + col)

local MiRows, MiCols = 0, 0
local mYMode, mUVMode, mRef, mIsInter, mSkipMode, mSkip = bcreate(0), bcreate(0), bcreate(0), bcreate(0), bcreate(0), bcreate(0)
local mTxSize, mMiSize, mSeg, mPalY, mPalUV, mInterTx = bcreate(0), bcreate(0), bcreate(0), bcreate(0), bcreate(0), bcreate(0)
local mComp, mInterp, mMv, mDeltaLF, mTxType = bcreate(0), bcreate(0), bcreate(0), bcreate(0), bcreate(0)
local mLfTx = { [0] = bcreate(0), bcreate(0), bcreate(0) }
-- mRef: 2 x i8 (RefFrame[0], RefFrame[1]); mComp: CompGroupIdx + 2 * CompoundIdx; mInterp: 2 x u8;
-- mMv: 2 lists x (row, col) i16; mDeltaLF: 4 x i8
local prevSegIds -- PrevSegmentIds (buffer) or nil for all zero

-- tile contexts
local MiRowStart, MiRowEnd, MiColStart, MiColEnd = 0, 0, 0, 0
local aLevel, aDc, lLevel, lDc = {}, {}, {}, {} -- [plane] = buffer by 4x4 column / row of the plane
local aSegPred, lSegPred = bcreate(0), bcreate(0)
local CurrentQIndex = 0
local DeltaLF = { [0] = 0, 0, 0, 0 }
local ReadDeltas = 0
local cdefIdx = bcreate(0) -- i8 per 64x64 unit
local cdefStride = 0
local RefSgrXqd, RefLrWiener = {}, {}
local lrUnits = {} -- [plane] = { type = {}, wiener = {}, sgrSet = {}, sgrXqd = {}, rows, cols }

local ssx, ssy, NumPlanes, BitDepth = 1, 1, 3, 8
local sb128 = false

-- the frame being decoded: 16-bit samples, planes[p] with stride pstride[p] (in samples)
local planes = { [0] = bcreate(0), bcreate(0), bcreate(0) }
local pstride = { [0] = 0, 0, 0 }
local pixMax = 255
local curFrame -- the frame store being decoded
local getFrame -- (wAlloc, hAlloc) -> a free frame store
local mWritten = bcreate(0) -- 1 once a 4x4 unit's mode info has been decoded in this frame

------------------------------------------------------------------------------------------------------------------------
-- block decoding

local decodeTile, resetBlockQuant, interSupported, motionFieldEstimation, storeMotionField = (function()

------------------------------------------------------------------------------------------------------------------------
-- the current block
local MiRow, MiCol, MiSize, bw4, bh4 = 0, 0, 0, 1, 1
local HasChroma, AvailU, AvailL, AvailUChroma, AvailLChroma = false, false, false, false, false
local skip, skipMode, isInter, useIntrabc, segmentId, Lossless = 0, 0, 0, 0, 0, false
local YMode, UVMode, AngleDeltaY, AngleDeltaUV, CflAlphaU, CflAlphaV = 0, 0, 0, 0, 0, 0
local useFilterIntra, filterIntraMode = 0, 0
local PaletteSizeY, PaletteSizeUV = 0, 0
local palY, palU, palV = {}, {}, {}
local ColorMapY, ColorMapUV = bcreate(64 * 64), bcreate(64 * 64)
local TxSize = 0
local MaxLumaW, MaxLumaH = 0, 0
local RefFrame0, RefFrame1 = 0, -1
local I = {} -- inter block state: Mv, interp filters, motion / compound modes, mv stack, ...

local predictInterBlock, transformBlockRecon, findMvStack, readInterModes
local palAbove, palLeft = { [0] = {}, {} }, { [0] = {}, {} } -- palette colours along the last decoded row / column
-- block decoded flags of the superblock: [plane][(y + 1) * 34 + (x + 1)]
local blockDecoded = { [0] = {}, {}, {} }

local function miIdx(r, c)
	return r * MiCols + c
end

local function isInside(r, c)
	return c >= MiColStart and c < MiColEnd and r >= MiRowStart and r < MiRowEnd
end

local function segFeatureActive(feature)
	return F.segmentation_enabled == 1 and F.FeatureEnabled[segmentId * 8 + feature + 1] == 1
end

------------------------------------------------------------------------------------------------------------------------
-- segment ids, skip, cdef, delta q / lf

local function readSegmentId()
	local prevUL, prevU, prevL = -1, -1, -1
	if AvailU and AvailL then
		prevUL = readu8(mSeg, miIdx(MiRow - 1, MiCol - 1))
	end
	if AvailU then
		prevU = readu8(mSeg, miIdx(MiRow - 1, MiCol))
	end
	if AvailL then
		prevL = readu8(mSeg, miIdx(MiRow, MiCol - 1))
	end
	local pred
	if prevU == -1 then
		pred = prevL == -1 and 0 or prevL
	elseif prevL == -1 then
		pred = prevU
	else
		pred = prevUL == prevU and prevU or prevL
	end
	if skip == 1 then
		segmentId = pred
		return
	end
	local ctx
	if prevUL < 0 then
		ctx = 0
	elseif prevUL == prevU and prevUL == prevL then
		ctx = 2
	elseif prevUL == prevU or prevUL == prevL or prevU == prevL then
		ctx = 1
	else
		ctx = 0
	end
	local diff = sym(1039 + ctx * 9, 8)
	local mx = F.LastActiveSegId + 1
	local v
	if pred == 0 then
		v = diff
	elseif pred >= mx - 1 then
		v = mx - diff - 1
	elseif 2 * pred < mx then
		if diff <= 2 * pred then
			if diff % 2 == 1 then
				v = pred + (diff + 1) // 2
			else
				v = pred - diff // 2
			end
		else
			v = diff
		end
	else
		if diff <= 2 * (mx - pred - 1) then
			if diff % 2 == 1 then
				v = pred + (diff + 1) // 2
			else
				v = pred - diff // 2
			end
		else
			v = mx - (diff + 1)
		end
	end
	segmentId = v
end

local function intraSegmentId()
	if F.segmentation_enabled == 1 then
		readSegmentId()
	else
		segmentId = 0
	end
	Lossless = F.LosslessArray[segmentId] == 1
end

local function getSegmentIdPred()
	local xMis = min(MiCols - MiCol, bw4)
	local yMis = min(MiRows - MiRow, bh4)
	local seg = 7
	if not prevSegIds then
		return 0
	end
	for y = 0, yMis - 1 do
		local base = miIdx(MiRow + y, MiCol)
		for x = 0, xMis - 1 do
			seg = min(seg, readu8(prevSegIds, base + x))
		end
	end
	return seg
end

local function setSegPred(v)
	for i = 0, bw4 - 1 do
		writeu8(aSegPred, MiCol + i, v)
	end
	for i = 0, bh4 - 1 do
		writeu8(lSegPred, MiRow + i, v)
	end
end

local function interSegmentId(preSkip)
	if F.segmentation_enabled == 1 then
		local predicted = getSegmentIdPred()
		if F.segmentation_update_map == 1 then
			if preSkip and F.SegIdPreSkip == 0 then
				segmentId = 0
				return
			end
			if not preSkip then
				if skip == 1 then
					setSegPred(0)
					readSegmentId()
					return
				end
			end
			if F.segmentation_temporal_update == 1 then
				local ctx = readu8(lSegPred, MiRow) + readu8(aSegPred, MiCol)
				local p = sym(1066 + ctx * 3, 2)
				if p == 1 then
					segmentId = predicted
				else
					readSegmentId()
				end
				setSegPred(p)
			else
				readSegmentId()
			end
		else
			segmentId = predicted
		end
	else
		segmentId = 0
	end
end

local function readSkip()
	if F.SegIdPreSkip == 1 and segFeatureActive(6) then
		skip = 1
	else
		local ctx = 0
		if AvailU then
			ctx += readu8(mSkip, miIdx(MiRow - 1, MiCol))
		end
		if AvailL then
			ctx += readu8(mSkip, miIdx(MiRow, MiCol - 1))
		end
		skip = sym(1566 + ctx * 3, 2)
	end
end

local function readSkipMode()
	if segFeatureActive(6) or segFeatureActive(5) or segFeatureActive(7) or F.skip_mode_present == 0
		or BlockW[MiSize + 1] < 8 or BlockH[MiSize + 1] < 8 then
		skipMode = 0
		return
	end
	local ctx = 0
	if AvailU then
		ctx += readu8(mSkipMode, miIdx(MiRow - 1, MiCol))
	end
	if AvailL then
		ctx += readu8(mSkipMode, miIdx(MiRow, MiCol - 1))
	end
	skipMode = sym(1557 + ctx * 3, 2)
end

local function readCdef()
	if skip == 1 or F.CodedLossless == 1 or S.enable_cdef == 0 or F.allow_intrabc == 1 then
		return
	end
	local r = MiRow // 16
	local c = MiCol // 16
	local at = r * cdefStride + c
	if readi8(cdefIdx, at) == -1 then
		local v = literal(F.cdef_bits)
		local w4 = Num4x4W[MiSize + 1]
		local h4 = Num4x4H[MiSize + 1]
		for i = r, r + (h4 - 1) // 16 do
			for j = c, c + (w4 - 1) // 16 do
				writei8(cdefIdx, i * cdefStride + j, v)
			end
		end
	end
end

local function readDeltaQIndex()
	local sbSize = sb128 and 15 or 12
	if MiSize == sbSize and skip == 1 then
		return
	end
	if ReadDeltas == 1 then
		local a = sym(2561, 4)
		if a == 3 then
			local rem = literal(3) + 1
			a = literal(rem) + P2[rem + 1] + 1
		end
		if a > 0 then
			local sign = literal(1)
			local reduced = sign == 1 and -a or a
			CurrentQIndex = math.clamp(CurrentQIndex + reduced * P2[F.delta_q_res + 1], 1, 255)
		end
	end
end

local function readDeltaLf()
	local sbSize = sb128 and 15 or 12
	if MiSize == sbSize and skip == 1 then
		return
	end
	if ReadDeltas == 1 and F.delta_lf_present == 1 then
		local count = 1
		if F.delta_lf_multi == 1 then
			count = NumPlanes > 1 and 4 or 2
		end
		for i = 0, count - 1 do
			local off = F.delta_lf_multi == 1 and 2571 + i * 5 or 2566
			local a = sym(off, 4)
			if a == 3 then
				local n = literal(3) + 1
				a = literal(n) + P2[n + 1] + 1
			end
			if a > 0 then
				local sign = literal(1)
				local reduced = sign == 1 and -a or a
				DeltaLF[i] = math.clamp(DeltaLF[i] + reduced * P2[F.delta_lf_res + 1], -63, 63)
			end
		end
	end
end

------------------------------------------------------------------------------------------------------------------------
-- transform sizes

local function aboveTxWidth(row, col)
	if row == MiRow then
		if not AvailU then
			return 64
		end
		local i = miIdx(row - 1, col)
		if readu8(mSkip, i) == 1 and readu8(mIsInter, i) == 1 then
			return BlockW[readu8(mMiSize, i) + 1]
		end
	end
	return TxW[readu8(mInterTx, miIdx(row - 1, col)) + 1]
end

local function leftTxHeight(row, col)
	if col == MiCol then
		if not AvailL then
			return 64
		end
		local i = miIdx(row, col - 1)
		if readu8(mSkip, i) == 1 and readu8(mIsInter, i) == 1 then
			return BlockH[readu8(mMiSize, i) + 1]
		end
	end
	return TxH[readu8(mInterTx, miIdx(row, col - 1)) + 1]
end

local function readTxSize(allowSelect)
	if Lossless then
		TxSize = 0
		return
	end
	local maxRect = MaxTxSizeRect[MiSize + 1]
	local maxDepth = MaxTxDepth[MiSize + 1]
	TxSize = maxRect
	if MiSize > 0 and allowSelect and F.TxMode == 2 then
		local maxW, maxH = TxW[maxRect + 1], TxH[maxRect + 1]
		local aboveW, leftH = 0, 0
		if AvailU then
			local i = miIdx(MiRow - 1, MiCol)
			if readu8(mIsInter, i) == 1 then
				aboveW = BlockW[readu8(mMiSize, i) + 1]
			else
				aboveW = aboveTxWidth(MiRow, MiCol)
			end
		end
		if AvailL then
			local i = miIdx(MiRow, MiCol - 1)
			if readu8(mIsInter, i) == 1 then
				leftH = BlockH[readu8(mMiSize, i) + 1]
			else
				leftH = leftTxHeight(MiRow, MiCol)
			end
		end
		local ctx = (aboveW >= maxW and 1 or 0) + (leftH >= maxH and 1 or 0)
		local depth
		if maxDepth == 4 then
			depth = sym(1108 + ctx * 4, 3)
		elseif maxDepth == 3 then
			depth = sym(1096 + ctx * 4, 3)
		elseif maxDepth == 2 then
			depth = sym(1084 + ctx * 4, 3)
		else
			depth = sym(1075 + ctx * 3, 2)
		end
		for _ = 1, depth do
			TxSize = SplitTx[TxSize + 1]
		end
	end
end

local function readVarTxSize(row, col, txSz, depth)
	if row >= MiRows or col >= MiCols then
		return
	end
	local split = 0
	if not (txSz == 0 or depth == 2) then
		local above = aboveTxWidth(row, col) < TxW[txSz + 1] and 1 or 0
		local left = leftTxHeight(row, col) < TxH[txSz + 1] and 1 or 0
		local size = min(64, max(BlockW[MiSize + 1], BlockH[MiSize + 1]))
		local maxTxSz = TX_BY_WH[size * 128 + size]
		local ctx = (TxSqrUp[txSz + 1] ~= maxTxSz and 1 or 0) * 3 + (4 - maxTxSz) * 6 + above + left
		split = sym(1120 + ctx * 3, 2)
	end
	local w4 = TxW[txSz + 1] // 4
	local h4 = TxH[txSz + 1] // 4
	if split == 1 then
		local sub = SplitTx[txSz + 1]
		local stepW = TxW[sub + 1] // 4
		local stepH = TxH[sub + 1] // 4
		for i = 0, h4 - 1, stepH do
			for j = 0, w4 - 1, stepW do
				readVarTxSize(row + i, col + j, sub, depth + 1)
			end
		end
	else
		for i = 0, h4 - 1 do
			if row + i < MiRows then
				for j = 0, w4 - 1 do
					if col + j < MiCols then
						writeu8(mInterTx, miIdx(row + i, col + j), txSz)
					end
				end
			end
		end
		TxSize = txSz
	end
end

local function readBlockTxSize()
	if F.TxMode == 2 and MiSize > 0 and isInter == 1 and skip == 0 and not Lossless then
		local maxTx = MaxTxSizeRect[MiSize + 1]
		local txW4 = TxW[maxTx + 1] // 4
		local txH4 = TxH[maxTx + 1] // 4
		for row = MiRow, MiRow + bh4 - 1, txH4 do
			for col = MiCol, MiCol + bw4 - 1, txW4 do
				readVarTxSize(row, col, maxTx, 0)
			end
		end
	else
		readTxSize(skip == 0 or isInter == 0)
		for row = MiRow, min(MiRow + bh4, MiRows) - 1 do
			local base = row * MiCols
			for col = MiCol, min(MiCol + bw4, MiCols) - 1 do
				writeu8(mInterTx, base + col, TxSize)
			end
		end
	end
end

------------------------------------------------------------------------------------------------------------------------
-- intra modes, palette

local IntraModeCtx = Tab.Intra_Mode_Context

local function isDirectional(mode)
	return mode >= 1 and mode <= 8
end

local function readCflAlphas()
	local signs = sym(3182, 8)
	local signU = (signs + 1) // 3
	local signV = (signs + 1) % 3
	if signU ~= 0 then
		local a = sym(3775 + ((signU - 1) * 3 + signV) * 17, 16) + 1
		CflAlphaU = signU == 1 and -a or a
	else
		CflAlphaU = 0
	end
	if signV ~= 0 then
		local a = sym(3775 + ((signV - 1) * 3 + signU) * 17, 16) + 1
		CflAlphaV = signV == 1 and -a or a
	else
		CflAlphaV = 0
	end
end

local function readUVMode()
	local cflAllowed
	if Lossless and planeSize(MiSize, ssx, ssy) == 0 then
		cflAllowed = true
	elseif not Lossless and max(BlockW[MiSize + 1], BlockH[MiSize + 1]) <= 32 then
		cflAllowed = true
	else
		cflAllowed = false
	end
	if cflAllowed then
		UVMode = sym(589 + YMode * 15, 14)
	else
		UVMode = sym(407 + YMode * 14, 13)
	end
	if UVMode == 13 then
		readCflAlphas()
	end
	AngleDeltaUV = 0
	if MiSize >= 3 and isDirectional(UVMode) then
		AngleDeltaUV = sym(784 + (UVMode - 1) * 8, 7) - 3
	end
end

local function getPaletteCache(plane, cache)
	local aboveN, leftN = 0, 0
	if (MiRow * 4) % 64 ~= 0 then
		aboveN = readu8(plane == 0 and mPalY or mPalUV, miIdx(MiRow - 1, MiCol))
	end
	if AvailL then
		leftN = readu8(plane == 0 and mPalY or mPalUV, miIdx(MiRow, MiCol - 1))
	end
	local A, L = palAbove[plane], palLeft[plane]
	local ab, lb = MiCol * 8, MiRow * 8
	local ai, li, n = 0, 0, 0
	while ai < aboveN and li < leftN do
		local aboveC = A[ab + ai + 1]
		local leftC = L[lb + li + 1]
		if leftC < aboveC then
			if n == 0 or leftC ~= cache[n] then
				n += 1
				cache[n] = leftC
			end
			li += 1
		else
			if n == 0 or aboveC ~= cache[n] then
				n += 1
				cache[n] = aboveC
			end
			ai += 1
			if leftC == aboveC then
				li += 1
			end
		end
	end
	while ai < aboveN do
		local v = A[ab + ai + 1]
		ai += 1
		if n == 0 or v ~= cache[n] then
			n += 1
			cache[n] = v
		end
	end
	while li < leftN do
		local v = L[lb + li + 1]
		li += 1
		if n == 0 or v ~= cache[n] then
			n += 1
			cache[n] = v
		end
	end
	return n
end

local paletteCache = {}

local function readPaletteColors(plane, size, out)
	local n = getPaletteCache(plane, paletteCache)
	local idx = 0
	local i = 1
	while i <= n and idx < size do
		if literal(1) == 1 then
			out[idx] = paletteCache[i]
			idx += 1
		end
		i += 1
	end
	local maxV = P2[BitDepth + 1] - 1
	if idx < size then
		out[idx] = literal(BitDepth)
		idx += 1
	end
	local bits = 0
	if idx < size then
		bits = BitDepth - 3 + literal(2)
	end
	while idx < size do
		local delta = literal(bits)
		if plane == 0 then
			delta += 1
		end
		out[idx] = min(out[idx - 1] + delta, maxV)
		local range = P2[BitDepth + 1] - out[idx] - (plane == 0 and 1 or 0)
		bits = min(bits, ceilLog2(range))
		idx += 1
	end
	-- ascending order
	for a = 1, size - 1 do
		local v = out[a]
		local b = a - 1
		while b >= 0 and out[b] > v do
			out[b + 1] = out[b]
			b -= 1
		end
		out[b + 1] = v
	end
end

local function paletteModeInfo()
	local bsizeCtx = MiWLog2[MiSize + 1] + MiHLog2[MiSize + 1] - 2
	if YMode == 0 then
		local ctx = 0
		if AvailU and readu8(mPalY, miIdx(MiRow - 1, MiCol)) > 0 then
			ctx += 1
		end
		if AvailL and readu8(mPalY, miIdx(MiRow, MiCol - 1)) > 0 then
			ctx += 1
		end
		if sym(1960 + (bsizeCtx * 3 + ctx) * 3, 2) == 1 then
			PaletteSizeY = sym(2029 + bsizeCtx * 8, 7) + 2
			readPaletteColors(0, PaletteSizeY, palY)
		end
	end
	if HasChroma and UVMode == 0 then
		if sym(2023 + (PaletteSizeY > 0 and 3 or 0), 2) == 1 then
			PaletteSizeUV = sym(2085 + bsizeCtx * 8, 7) + 2
			readPaletteColors(1, PaletteSizeUV, palU)
			if literal(1) == 1 then
				local bits = BitDepth - 4 + literal(2)
				local maxVal = P2[BitDepth + 1]
				palV[0] = literal(BitDepth)
				for idx = 1, PaletteSizeUV - 1 do
					local delta = literal(bits)
					if delta ~= 0 and literal(1) == 1 then
						delta = -delta
					end
					local v = palV[idx - 1] + delta
					if v < 0 then
						v += maxVal
					end
					if v >= maxVal then
						v -= maxVal
					end
					palV[idx] = math.clamp(v, 0, maxVal - 1)
				end
			else
				for idx = 0, PaletteSizeUV - 1 do
					palV[idx] = literal(BitDepth)
				end
			end
		end
	end
end

local function filterIntraModeInfo()
	useFilterIntra = 0
	if S.enable_filter_intra == 1 and YMode == 0 and PaletteSizeY == 0
		and max(BlockW[MiSize + 1], BlockH[MiSize + 1]) <= 32 then
		useFilterIntra = sym(1189 + MiSize * 3, 2)
		if useFilterIntra == 1 then
			filterIntraMode = sym(1183, 5)
		end
	end
end

local function intraAngleY()
	AngleDeltaY = 0
	if MiSize >= 3 and isDirectional(YMode) then
		AngleDeltaY = sym(784 + (YMode - 1) * 8, 7) - 3
	end
end

local function intraModesRest()
	if HasChroma then
		readUVMode()
	else
		UVMode = 0
	end
	PaletteSizeY, PaletteSizeUV = 0, 0
	if MiSize >= 3 and BlockW[MiSize + 1] <= 64 and BlockH[MiSize + 1] <= 64 and F.allow_screen_content_tools == 1 then
		paletteModeInfo()
	end
	filterIntraModeInfo()
end

local function intraFrameModeInfo()
	skip = 0
	if F.SegIdPreSkip == 1 then
		intraSegmentId()
	end
	skipMode = 0
	readSkip()
	if F.SegIdPreSkip == 0 then
		intraSegmentId()
	end
	readCdef()
	readDeltaQIndex()
	readDeltaLf()
	ReadDeltas = 0
	RefFrame0, RefFrame1 = 0, -1
	useIntrabc = 0
	if F.allow_intrabc == 1 then
		useIntrabc = sym(848, 2)
	end
	useFilterIntra = 0
	if useIntrabc == 1 then
		isInter = 1
		YMode, UVMode = 0, 0
		AngleDeltaY, AngleDeltaUV = 0, 0
		PaletteSizeY, PaletteSizeUV = 0, 0
		I.motion_mode = 0
		I.compound_type = 2
		I.interp0, I.interp1 = 3, 3
		I.interintra = 0
		findMvStack(0)
		I.assignMv(0)
	else
		isInter = 0
		local above = IntraModeCtx[(AvailU and readu8(mYMode, miIdx(MiRow - 1, MiCol)) or 0) + 1]
		local left = IntraModeCtx[(AvailL and readu8(mYMode, miIdx(MiRow, MiCol - 1)) or 0) + 1]
		YMode = sym(1 + (above * 5 + left) * 14, 13)
		intraAngleY()
		intraModesRest()
	end
end

local function intraBlockModeInfo()
	RefFrame0, RefFrame1 = 0, -1
	YMode = sym(351 + SizeGroup[MiSize + 1] * 14, 13)
	intraAngleY()
	intraModesRest()
end

local function interFrameModeInfo()
	useIntrabc = 0
	local la, aa = AvailL and miIdx(MiRow, MiCol - 1), AvailU and miIdx(MiRow - 1, MiCol)
	I.LeftRef0 = la and readi8(mRef, la * 2) or 0
	I.AboveRef0 = aa and readi8(mRef, aa * 2) or 0
	I.LeftRef1 = la and readi8(mRef, la * 2 + 1) or -1
	I.AboveRef1 = aa and readi8(mRef, aa * 2 + 1) or -1
	I.LeftIntra = I.LeftRef0 <= 0
	I.AboveIntra = I.AboveRef0 <= 0
	I.LeftSingle = I.LeftRef1 <= 0
	I.AboveSingle = I.AboveRef1 <= 0
	skip = 0
	interSegmentId(true)
	readSkipMode()
	if skipMode == 1 then
		skip = 1
	else
		readSkip()
	end
	if F.SegIdPreSkip == 0 then
		interSegmentId(false)
	end
	Lossless = F.LosslessArray[segmentId] == 1
	readCdef()
	readDeltaQIndex()
	readDeltaLf()
	ReadDeltas = 0
	-- read_is_inter
	if skipMode == 1 then
		isInter = 1
	elseif segFeatureActive(5) then
		isInter = F.FeatureData[segmentId * 8 + 6] ~= 0 and 1 or 0
	elseif segFeatureActive(7) then
		isInter = 1
	else
		local ctx
		if AvailU and AvailL then
			ctx = (I.LeftIntra and I.AboveIntra) and 3 or ((I.LeftIntra or I.AboveIntra) and 1 or 0)
		elseif AvailU or AvailL then
			ctx = 2 * ((if AvailU then I.AboveIntra else I.LeftIntra) and 1 or 0)
		else
			ctx = 0
		end
		isInter = sym(1530 + ctx * 3, 2)
	end
	useFilterIntra = 0
	if isInter == 1 then
		PaletteSizeY, PaletteSizeUV = 0, 0
		AngleDeltaY, AngleDeltaUV = 0, 0
		YMode = 0
		UVMode = 0
		readInterModes()
	else
		intraBlockModeInfo()
	end
end
local coeffs, paletteTokens, setupBlockQuant, resetBlockQuant
do

	------------------------------------------------------------------------------------------------------------------------
	-- coefficients

	local SCAN = {} -- [txSz + 1] = { [0] = default, mrow, mcol }
	do
		local names = { [0] = "4x4", "8x8", "16x16", "32x32", "32x32", "4x8", "8x4", "8x16", "16x8", "16x32", "32x16",
			"32x32", "32x32", "4x16", "16x4", "8x32", "32x8", "16x32", "32x16" }
		for t = 0, 18 do
			local n = names[t]
			local d = Tab["Default_Scan_" .. n]
			SCAN[t + 1] = { [0] = d, Tab["Mrow_Scan_" .. n] or d, Tab["Mcol_Scan_" .. n] or d }
		end
	end
	local SigRefDiff = Tab.Sig_Ref_Diff_Offset
	local MagRefOff = Tab.Mag_Ref_Offset_With_Tx_Class
	local CoeffBaseCtxOffset = Tab.Coeff_Base_Ctx_Offset
	local DcQ, AcQ = Tab.Dc_Qlookup, Tab.Ac_Qlookup
	local TxInSetIntra, TxInSetInter = Tab.Tx_Type_In_Set_Intra, Tab.Tx_Type_In_Set_Inter
	local IntraInv1, IntraInv2 = Tab.Tx_Type_Intra_Inv_Set1, Tab.Tx_Type_Intra_Inv_Set2
	local InterInv1, InterInv2, InterInv3 = Tab.Tx_Type_Inter_Inv_Set1, Tab.Tx_Type_Inter_Inv_Set2, Tab.Tx_Type_Inter_Inv_Set3
	local FilterIntraDir = Tab.Filter_Intra_Mode_To_Intra_Dir
	local QmOffset = { 0, 16, 80, 336, 336, 1360, 1392, 1424, 1552, 1680, 2192, 336, 336, 2704, 2768, 2832, 3088, 1680, 2192 }
	local QM -- the quantizer matrices (loaded on first use)
	-- transform class: 0 = 2D, 1 = horizontal (H_*), 2 = vertical (V_*)
	local TX_CLASS = { [0] = 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 2, 1, 2, 1, 2, 1 }

	local QS = 36 -- row stride of the padded level array
	local QL = tcreate(QS * QS, 0) -- levels by (row, col) with zero margins (contexts read past the edges)
	local QLtouched, nQL = {}, 0
	local DQ = tcreate(64 * 64, 0) -- dequantized coefficients, row-major with stride min(32, width)
	local DQnz, nDQ = {}, 0
	local PlaneTxType = 0
	local scanPos = tcreate(1024, 0)

	local function getTxSet(txSz)
		local sqr, sqrUp = TxSqr[txSz + 1], TxSqrUp[txSz + 1]
		if sqrUp > 3 then
			return 0
		end
		if isInter == 1 then
			if F.reduced_tx_set == 1 or sqrUp == 3 then
				return 3
			elseif sqr == 2 then
				return 2
			end
			return 1
		end
		if sqrUp == 3 then
			return 0
		elseif F.reduced_tx_set == 1 or sqr == 2 then
			return 2
		end
		return 1
	end

	local function txTypeInSet(set, t)
		if isInter == 1 then
			return TxInSetInter[set * 16 + t + 1] == 1
		end
		return TxInSetIntra[set * 16 + t + 1] == 1
	end

	local function computeTxType(plane, txSz, x4, y4)
		if Lossless or TxSqrUp[txSz + 1] > 3 then
			return 0
		end
		local set = getTxSet(txSz)
		if plane == 0 then
			return readu8(mTxType, y4 * MiCols + x4)
		end
		local t
		if isInter == 1 then
			local lx = max(MiCol, x4 * P2[ssx + 1])
			local ly = max(MiRow, y4 * P2[ssy + 1])
			t = readu8(mTxType, ly * MiCols + lx)
		else
			t = ModeToTxfm[UVMode + 1]
		end
		if not txTypeInSet(set, t) then
			return 0
		end
		return t
	end

	local function readTransformType(x4, y4, txSz)
		local set = getTxSet(txSz)
		local t = 0
		local q = F.segmentation_enabled == 1 and getQIndex(1, segmentId, CurrentQIndex) or F.base_q_idx
		if set > 0 and q > 0 then
			local sqr = TxSqr[txSz + 1]
			if isInter == 1 then
				if set == 1 then
					t = InterInv1[sym(3033 + sqr * 17, 16) + 1]
				elseif set == 2 then
					t = InterInv2[sym(3067, 12) + 1]
				else
					t = InterInv3[sym(3080 + sqr * 3, 2) + 1]
				end
			else
				local dir = useFilterIntra == 1 and FilterIntraDir[filterIntraMode + 1] or YMode
				if set == 1 then
					t = IntraInv1[sym(2591 + (sqr * 13 + dir) * 8, 7) + 1]
				else
					t = IntraInv2[sym(2799 + (sqr * 13 + dir) * 6, 5) + 1]
				end
			end
		end
		local w4, h4 = TxW[txSz + 1] // 4, TxH[txSz + 1] // 4
		for j = 0, h4 - 1 do
			if y4 + j < MiRows then
				local base = (y4 + j) * MiCols
				for i = 0, w4 - 1 do
					if x4 + i < MiCols then
						writeu8(mTxType, base + x4 + i, t)
					end
				end
			end
		end
	end

	-- quantizers of the current block: [plane * 2 + 1] = dc, [plane * 2 + 2] = ac
	local blockQ = { 0, 0, 0, 0, 0, 0 }
	local blockQIndex = -1

	function resetBlockQuant()
		blockQIndex = -1
	end

	function setupBlockQuant()
		local qi = getQIndex(0, segmentId, CurrentQIndex)
		if qi == blockQIndex then
			return
		end
		blockQIndex = qi
		local base = ((BitDepth - 8) // 2) * 256 + 1
		blockQ[1] = DcQ[base + math.clamp(qi + F.DeltaQYDc, 0, 255)]
		blockQ[2] = AcQ[base + math.clamp(qi, 0, 255)]
		blockQ[3] = DcQ[base + math.clamp(qi + F.DeltaQUDc, 0, 255)]
		blockQ[4] = AcQ[base + math.clamp(qi + F.DeltaQUAc, 0, 255)]
		blockQ[5] = DcQ[base + math.clamp(qi + F.DeltaQVDc, 0, 255)]
		blockQ[6] = AcQ[base + math.clamp(qi + F.DeltaQVAc, 0, 255)]
	end

	-- coeffs(): reads one transform block's coefficients into DQ (dequantized); returns eob
	function coeffs(plane, startX, startY, txSz)
		local x4, y4 = startX // 4, startY // 4
		local w4, h4 = TxW[txSz + 1] // 4, TxH[txSz + 1] // 4
		local txSzCtx = (TxSqr[txSz + 1] + TxSqrUp[txSz + 1] + 1) // 2
		local ptype = plane > 0 and 1 or 0
		local maxX4, maxY4 = MiCols, MiRows
		if plane > 0 then
			maxX4 = maxX4 // P2[ssx + 1]
			maxY4 = maxY4 // P2[ssy + 1]
		end
		local AL, AD, LL, LD = aLevel[plane], aDc[plane], lLevel[plane], lDc[plane]
		-- all_zero
		local ctx
		local w, h = TxW[txSz + 1], TxH[txSz + 1]
		local bsize = planeSize(MiSize, plane > 0 and ssx or 0, plane > 0 and ssy or 0)
		local bw, bh = BlockW[bsize + 1], BlockH[bsize + 1]
		if plane == 0 then
			local top, left = 0, 0
			for k = 0, min(w4, maxX4 - x4) - 1 do
				top = max(top, readu8(AL, x4 + k))
			end
			for k = 0, min(h4, maxY4 - y4) - 1 do
				left = max(left, readu8(LL, y4 + k))
			end
			if bw == w and bh == h then
				ctx = 0
			elseif top == 0 and left == 0 then
				ctx = 1
			elseif top == 0 or left == 0 then
				ctx = 2 + (max(top, left) > 3 and 1 or 0)
			elseif max(top, left) <= 3 then
				ctx = 4
			elseif min(top, left) <= 3 then
				ctx = 5
			else
				ctx = 6
			end
		else
			local above, left = 0, 0
			for k = 0, min(w4, maxX4 - x4) - 1 do
				above = bor(above, readu8(AL, x4 + k), readu8(AD, x4 + k))
			end
			for k = 0, min(h4, maxY4 - y4) - 1 do
				left = bor(left, readu8(LL, y4 + k), readu8(LD, y4 + k))
			end
			ctx = 7 + (above ~= 0 and 1 or 0) + (left ~= 0 and 1 or 0)
			if bw * bh > w * h then
				ctx += 3
			end
		end
		local eob = 0
		local culLevel, dcCategory = 0, 0
		if sym(3887 + (txSzCtx * 13 + ctx) * 3, 2) == 1 then
			if plane == 0 then
				for j = 0, h4 - 1 do
					if y4 + j < MiRows then
						local base = (y4 + j) * MiCols
						for i = 0, w4 - 1 do
							if x4 + i < MiCols then
								writeu8(mTxType, base + x4 + i, 0)
							end
						end
					end
				end
			end
		else
			if plane == 0 then
				readTransformType(x4, y4, txSz)
			end
			local ptt = computeTxType(plane, txSz, x4, y4)
			PlaneTxType = ptt
			local txClass = TX_CLASS[ptt]
			-- scan
			local scan
			if txSz == 17 then
				scan = SCAN[10][0]
			elseif txSz == 18 then
				scan = SCAN[11][0]
			elseif TxSqrUp[txSz + 1] == 4 then
				scan = SCAN[4][0]
			elseif ptt == 9 then
				scan = SCAN[txSz + 1][0]
			elseif ptt == 10 or ptt == 12 or ptt == 14 then
				scan = SCAN[txSz + 1][1]
			elseif ptt == 11 or ptt == 13 or ptt == 15 then
				scan = SCAN[txSz + 1][2]
			else
				scan = SCAN[txSz + 1][0]
			end
			local eobMultisize = min(TxWLog2[txSz + 1], 5) + min(TxHLog2[txSz + 1], 5) - 4
			local ectx = txClass == 0 and 0 or 1
			local eobPt
			if eobMultisize == 0 then
				eobPt = sym(4082 + (ptype * 2 + ectx) * 6, 5) + 1
			elseif eobMultisize == 1 then
				eobPt = sym(4106 + (ptype * 2 + ectx) * 7, 6) + 1
			elseif eobMultisize == 2 then
				eobPt = sym(4134 + (ptype * 2 + ectx) * 8, 7) + 1
			elseif eobMultisize == 3 then
				eobPt = sym(4166 + (ptype * 2 + ectx) * 9, 8) + 1
			elseif eobMultisize == 4 then
				eobPt = sym(4202 + (ptype * 2 + ectx) * 10, 9) + 1
			elseif eobMultisize == 5 then
				eobPt = sym(4242 + ptype * 11, 10) + 1
			else
				eobPt = sym(4264 + ptype * 12, 11) + 1
			end
			eob = eobPt < 2 and eobPt or P2[eobPt - 1] + 1
			local eobShift = eobPt - 3
			if eobShift >= 0 then
				if sym(4288 + ((txSzCtx * 2 + ptype) * 9 + eobPt - 3) * 3, 2) == 1 then
					eob += P2[eobShift + 1]
				end
				for i = 1, max(0, eobPt - 2) - 1 do
					eobShift = max(0, eobPt - 2) - 1 - i
					if bool() == 1 then
						eob += P2[eobShift + 1]
					end
				end
			end
			-- levels, last to first
			local adj = AdjustedTx[txSz + 1]
			local bwl = TxWLog2[adj + 1]
			local width = P2[bwl + 1]
			local height = TxH[adj + 1]
			local area = height * width
			local baseOff = 4736 + (txSzCtx * 2 + ptype) * 42 * 5
			local brOff = 6836 + (min(txSzCtx, 3) * 2 + ptype) * 21 * 5
			local cbOff = (txSz * 25) + 1
			local sr = txClass * 10 + 1
			local mr = txClass * 6 + 1
			local d1r, d1c, d2r, d2c, d3r, d3c, d4r, d4c, d5r, d5c = SigRefDiff[sr], SigRefDiff[sr + 1], SigRefDiff[sr + 2],
				SigRefDiff[sr + 3], SigRefDiff[sr + 4], SigRefDiff[sr + 5], SigRefDiff[sr + 6], SigRefDiff[sr + 7],
				SigRefDiff[sr + 8], SigRefDiff[sr + 9]
			local o1 = d1r * QS + d1c + 1
			local o2 = d2r * QS + d2c + 1
			local o3 = d3r * QS + d3c + 1
			local o4 = d4r * QS + d4c + 1
			local o5 = d5r * QS + d5c + 1
			local m1 = MagRefOff[mr] * QS + MagRefOff[mr + 1] + 1
			local m2 = MagRefOff[mr + 2] * QS + MagRefOff[mr + 3] + 1
			local m3 = MagRefOff[mr + 4] * QS + MagRefOff[mr + 5] + 1
			for c = eob - 1, 0, -1 do
				local pos = scan[c + 1]
				local row = pos // width
				local col = pos - row * width
				local qi = row * QS + col
				local level
				if c == eob - 1 then
					local ectx2 = c == 0 and 0 or (c <= area // 8 and 1 or (c <= area // 4 and 2 or 3))
					level = sym(4576 + ((txSzCtx * 2 + ptype) * 4 + ectx2) * 4, 3) + 1
				else
					local mag = min(QL[qi + o1], 3) + min(QL[qi + o2], 3) + min(QL[qi + o3], 3) + min(QL[qi + o4], 3)
						+ min(QL[qi + o5], 3)
					local cctx = min((mag + 1) // 2, 4)
					if txClass == 0 then
						if pos == 0 then
							cctx = 0
						else
							cctx += CoeffBaseCtxOffset[cbOff + min(row, 4) * 5 + min(col, 4)]
						end
					elseif txClass == 2 then
						cctx += 26 + min(row, 2) * 5
					else
						cctx += 26 + min(col, 2) * 5
					end
					level = sym(baseOff + cctx * 5, 4)
				end
				if level > 2 then
					local mag = min(QL[qi + m1], 15) + min(QL[qi + m2], 15) + min(QL[qi + m3], 15)
					mag = min((mag + 1) // 2, 6)
					local bctx
					if pos == 0 then
						bctx = mag
					elseif txClass == 0 then
						bctx = (row < 2 and col < 2) and mag + 7 or mag + 14
					elseif txClass == 1 then
						bctx = col == 0 and mag + 7 or mag + 14
					else
						bctx = row == 0 and mag + 7 or mag + 14
					end
					local boff = brOff + bctx * 5
					for _ = 1, 4 do
						local br = sym(boff, 4)
						level += br
						if br < 3 then
							break
						end
					end
				end
				if level > 0 then
					QL[qi + 1] = level
					nQL += 1
					QLtouched[nQL] = qi + 1
				end
				scanPos[c + 1] = level
			end
			-- signs, large values, dequantization
			local dqDenom = 1
			if txSz == 3 or txSz == 9 or txSz == 10 or txSz == 17 or txSz == 18 then
				dqDenom = 2
			elseif txSz == 4 or txSz == 11 or txSz == 12 then
				dqDenom = 4
			end
			local dcq, acq = blockQ[plane * 2 + 1], blockQ[plane * 2 + 2]
			local lim = P2[8 + BitDepth]
			local qmBase
			if F.using_qmatrix == 1 and ptt < 9 then
				local level = F.SegQMLevel[plane * 8 + segmentId]
				if level < 15 then
					if not QM then
						QM = require(script.Parent.Av1QuantMatrix)
					end
					qmBase = (level * 2 + (plane > 0 and 1 or 0)) * 3344 + QmOffset[txSz + 1]
				end
			end
			for c = 0, eob - 1 do
				local level = scanPos[c + 1]
				if level ~= 0 then
					local pos = scan[c + 1]
					local sign
					if c == 0 then
						local dcSign = 0
						for k = 0, min(w4, maxX4 - x4) - 1 do
							local s = readu8(AD, x4 + k)
							if s == 1 then
								dcSign -= 1
							elseif s == 2 then
								dcSign += 1
							end
						end
						for k = 0, min(h4, maxY4 - y4) - 1 do
							local s = readu8(LD, y4 + k)
							if s == 1 then
								dcSign -= 1
							elseif s == 2 then
								dcSign += 1
							end
						end
						local sctx = dcSign < 0 and 1 or (dcSign > 0 and 2 or 0)
						sign = sym(4558 + (ptype * 3 + sctx) * 3, 2)
					else
						sign = bool()
					end
					if level > 14 then
						local length = 0
						repeat
							length += 1
							local b = bool()
							if length > 32 then
								fail("broken coefficient")
							end
						until b == 1
						local x = 1
						for _ = length - 2, 0, -1 do
							x = x * 2 + bool()
						end
						level = x + 14
					end
					if pos == 0 then
						dcCategory = sign == 1 and 1 or 2
					end
					level %= 1048576
					culLevel += level
					local q = pos == 0 and dcq or acq
					if qmBase then
						q = (q * readu8(QM, qmBase + pos) + 16) // 32
					end
					local dq = (level * q) % 16777216
					if dqDenom > 1 then
						dq //= dqDenom
					end
					if sign == 1 then
						dq = -dq
					end
					if dq < -lim then
						dq = -lim
					elseif dq > lim - 1 then
						dq = lim - 1
					end
					DQ[pos + 1] = dq
					nDQ += 1
					DQnz[nDQ] = pos + 1
				end
			end
			culLevel = min(63, culLevel)
			-- clear the level array
			for k = 1, nQL do
				QL[QLtouched[k]] = 0
			end
			nQL = 0
		end
		for i = 0, w4 - 1 do
			writeu8(AL, x4 + i, culLevel)
			writeu8(AD, x4 + i, dcCategory)
		end
		for i = 0, h4 - 1 do
			writeu8(LL, y4 + i, culLevel)
			writeu8(LD, y4 + i, dcCategory)
		end
		return eob
	end

	------------------------------------------------------------------------------------------------------------------------
	-- palette colour indices

	local PaletteColorContext = Tab.Palette_Color_Context
	local scores, colorOrder = {}, {}

	local function paletteTokens1(map, bw, bh, onW, onH, n, isY)
		local first = symNS(n)
		writeu8(map, 0, first)
		local cdfBase, step = 0, n + 1
		if isY then
			cdfBase = ({ [2] = 2141, [3] = 2171, [4] = 2211, [5] = 2261, [6] = 2321, [7] = 2391,
				[8] = 2471 })[n]
		else
			cdfBase = ({ [2] = 2156, [3] = 2191, [4] = 2236, [5] = 2291, [6] = 2356, [7] = 2431,
				[8] = 2516 })[n]
		end
		for i = 1, onH + onW - 2 do
			for j = min(i, onW - 1), max(0, i - onH + 1), -1 do
				local r, c = i - j, j
				for k = 0, 7 do
					scores[k] = 0
					colorOrder[k] = k
				end
				if c > 0 then
					local nb = readu8(map, r * 64 + c - 1)
					scores[nb] += 2
				end
				if r > 0 and c > 0 then
					local nb = readu8(map, (r - 1) * 64 + c - 1)
					scores[nb] += 1
				end
				if r > 0 then
					local nb = readu8(map, (r - 1) * 64 + c)
					scores[nb] += 2
				end
				for a = 0, 2 do
					local maxScore, maxIdx = scores[a], a
					for b = a + 1, n - 1 do
						if scores[b] > maxScore then
							maxScore = scores[b]
							maxIdx = b
						end
					end
					if maxIdx ~= a then
						maxScore = scores[maxIdx]
						local mco = colorOrder[maxIdx]
						for k = maxIdx, a + 1, -1 do
							scores[k] = scores[k - 1]
							colorOrder[k] = colorOrder[k - 1]
						end
						scores[a] = maxScore
						colorOrder[a] = mco
					end
				end
				local hash = scores[0] * 1 + scores[1] * 2 + scores[2] * 2
				local ctx = PaletteColorContext[hash + 1]
				local v = sym(cdfBase + ctx * step, n)
				writeu8(map, r * 64 + c, colorOrder[v])
			end
		end
		for i = 0, onH - 1 do
			local last = readu8(map, i * 64 + onW - 1)
			for j = onW, bw - 1 do
				writeu8(map, i * 64 + j, last)
			end
		end
		for i = onH, bh - 1 do
			bcopy(map, i * 64, map, (onH - 1) * 64, bw)
		end
	end

	function paletteTokens()
		local bh = BlockH[MiSize + 1]
		local bw = BlockW[MiSize + 1]
		local onH = min(bh, (MiRows - MiRow) * 4)
		local onW = min(bw, (MiCols - MiCol) * 4)
		if PaletteSizeY > 0 then
			paletteTokens1(ColorMapY, bw, bh, onW, onH, PaletteSizeY, true)
		end
		if PaletteSizeUV > 0 then
			bh //= P2[ssy + 1]
			bw //= P2[ssx + 1]
			onH //= P2[ssy + 1]
			onW //= P2[ssx + 1]
			if bw < 4 then
				bw += 2
				onW += 2
			end
			if bh < 4 then
				bh += 2
				onH += 2
			end
			paletteTokens1(ColorMapUV, bw, bh, onW, onH, PaletteSizeUV, false)
		end
	end

	------------------------------------------------------------------------------------------------------------------------
	-- inverse transforms

	local idct4, idct8, idct16, idct32, idct64 = Transform.idct4, Transform.idct8, Transform.idct16,
		Transform.idct32, Transform.idct64
	local iadst8, iadst16 = Transform.iadst8, Transform.iadst16

	local function iadst4(T, o, s, lo, hi)
		local x0, x1, x2, x3 = T[o], T[o + s], T[o + 2 * s], T[o + 3 * s]
		local s0 = 1321 * x0
		local s1 = 2482 * x0
		local s2 = 3344 * x1
		local s3 = 3803 * x2
		local s4 = 1321 * x2
		local s5 = 2482 * x3
		local s6 = 3803 * x3
		local b7 = x0 - x2 + x3
		s0 = s0 + s3
		s1 = s1 - s4
		s3 = s2
		s2 = 3344 * b7
		s0 = s0 + s5
		s1 = s1 - s6
		local y0 = s0 + s3
		local y1 = s1 + s3
		local y2 = s2
		local y3 = s0 + s1 - s3
		T[o] = (y0 + 2048) // 4096
		T[o + s] = (y1 + 2048) // 4096
		T[o + 2 * s] = (y2 + 2048) // 4096
		T[o + 3 * s] = (y3 + 2048) // 4096
	end

	local function iwht(T, o, s, shift)
		local d = P2[shift + 1]
		local a = T[o] // d
		local c = T[o + s] // d
		local dd = T[o + 2 * s] // d
		local b = T[o + 3 * s] // d
		a += c
		dd -= b
		local e = (a - dd) // 2
		b = e - b
		c = e - c
		a -= b
		dd += c
		T[o], T[o + s], T[o + 2 * s], T[o + 3 * s] = a, b, c, dd
	end

	local function iidentity(T, o, s, n)
		local N = P2[n + 1]
		if n == 2 then
			for k = 0, N - 1 do
				T[o + k * s] = (T[o + k * s] * 5793 + 2048) // 4096
			end
		elseif n == 3 then
			for k = 0, N - 1 do
				T[o + k * s] *= 2
			end
		elseif n == 4 then
			for k = 0, N - 1 do
				T[o + k * s] = (T[o + k * s] * 11586 + 2048) // 4096
			end
		else
			for k = 0, N - 1 do
				T[o + k * s] *= 4
			end
		end
	end

	local DCT_FN = { [2] = idct4, [3] = idct8, [4] = idct16, [5] = idct32, [6] = idct64 }
	local ADST_FN = { [2] = iadst4, [3] = iadst8, [4] = iadst16 }
	-- per transform type: vertical (column) kind, horizontal (row) kind: 0 = DCT, 1 = ADST, 2 = identity
	local TX_V = { [0] = 0, 1, 0, 1, 1, 0, 1, 1, 1, 2, 0, 2, 1, 2, 1, 2 }
	local TX_H = { [0] = 0, 0, 1, 1, 0, 1, 1, 1, 1, 2, 2, 0, 2, 1, 2, 1 }
	local FLIP_UD = { [4] = true, [6] = true, [8] = true, [14] = true }
	local FLIP_LR = { [5] = true, [6] = true, [7] = true, [15] = true }
	local RowShift = Tab.Transform_Row_Shift
	local RES = tcreate(64 * 64, 0)

	local function run1d(kind, n, T, o, s, lo, hi)
		if kind == 0 then
			DCT_FN[n](T, o, s, lo, hi)
		elseif kind == 1 then
			ADST_FN[n](T, o, s, lo, hi)
		else
			iidentity(T, o, s, n)
		end
	end

	function transformBlockRecon(plane, x, y, txSz)
		local log2W, log2H = TxWLog2[txSz + 1], TxHLog2[txSz + 1]
		local w, h = P2[log2W + 1], P2[log2H + 1]
		local tw = min(32, w)
		local ptt = PlaneTxType
		if Lossless then
			ptt = 0
		end
		local rowShift = Lossless and 0 or RowShift[txSz + 1]
		local colShift = Lossless and 0 or 4
		local rlo, rhi = -P2[BitDepth + 8], P2[BitDepth + 8] - 1
		local cr = max(BitDepth + 6, 16)
		local clo, chi = -P2[cr], P2[cr] - 1
		local hKind, vKind = TX_H[ptt], TX_V[ptt]
		-- rows that hold coefficients
		local maxRow = 0
		for k = 1, nDQ do
			local r = (DQnz[k] - 1) // tw
			if r > maxRow then
				maxRow = r
			end
		end
		local rect = abs(log2W - log2H) == 1
		local rs = P2[rowShift + 1]
		local rhalf = rowShift > 0 and P2[rowShift] or 0
		for i = 0, h - 1 do
			local o = i * w + 1
			if i <= maxRow then
				local src = i * tw
				for j = 0, w - 1 do
					local v = j < 32 and DQ[src + j + 1] or 0
					if rect then
						v = (v * 2896 + 2048) // 4096
					end
					RES[o + j] = v
				end
				if Lossless then
					iwht(RES, o, 1, 2)
				else
					run1d(hKind, log2W, RES, o, 1, rlo, rhi)
				end
				for j = 0, w - 1 do
					local v = (RES[o + j] + rhalf) // rs
					if v < clo then
						v = clo
					elseif v > chi then
						v = chi
					end
					RES[o + j] = v
				end
			else
				for j = 0, w - 1 do
					RES[o + j] = 0
				end
			end
		end
		local buf, stride = planes[plane], pstride[plane]
		local flipUD, flipLR = FLIP_UD[ptt], FLIP_LR[ptt]
		local cs = P2[colShift + 1]
		local chalf = colShift > 0 and P2[colShift] or 0
		for j = 0, w - 1 do
			if Lossless then
				iwht(RES, j + 1, w, 0)
			else
				run1d(vKind, log2H, RES, j + 1, w, clo, chi)
			end
			local xx = flipLR and (w - j - 1) or j
			for i = 0, h - 1 do
				local yy = flipUD and (h - i - 1) or i
				local off = ((y + yy) * stride + x + xx) * 2
				local v = readu16(buf, off) + (RES[i * w + j + 1] + chalf) // cs
				if v < 0 then
					v = 0
				elseif v > pixMax then
					v = pixMax
				end
				writeu16(buf, off, v)
			end
		end
		for k = 1, nDQ do
			DQ[DQnz[k]] = 0
		end
		nDQ = 0
	end

end
local predictIntra, predictPalette, predictCfl
do


	------------------------------------------------------------------------------------------------------------------------
	-- intra prediction

	local SmW = { [2] = Tab.Sm_Weights_Tx_4x4, [3] = Tab.Sm_Weights_Tx_8x8, [4] = Tab.Sm_Weights_Tx_16x16,
		[5] = Tab.Sm_Weights_Tx_32x32, [6] = Tab.Sm_Weights_Tx_64x64 }
	local ModeToAngle = Tab.Mode_To_Angle
	local DrIntraDeriv = Tab.Dr_Intra_Derivative
	local IntraFilterTaps = Tab.Intra_Filter_Taps
	local IntraEdgeKernel = Tab.Intra_Edge_Kernel

	local AR, LC = tcreate(300, 0), tcreate(300, 0) -- AboveRow / LeftCol: entry i at [i + 17]
	local EDGE = tcreate(300, 0)
	local PRED = tcreate(64 * 64, 0)

	local function isSmooth(row, col, plane)
		local i = row * MiCols + col
		local mode
		if plane == 0 then
			mode = readu8(mYMode, i)
		else
			if readi8(mRef, i * 2) > 0 then
				return false
			end
			mode = readu8(mUVMode, i)
		end
		return mode == 9 or mode == 10 or mode == 11
	end

	local function getFilterType(plane)
		local aboveSmooth, leftSmooth = false, false
		if (plane == 0 and AvailU) or (plane > 0 and AvailUChroma) then
			local r, c = MiRow - 1, MiCol
			if plane > 0 then
				if ssx == 1 and MiCol % 2 == 0 then
					c += 1
				end
				if ssy == 1 and MiRow % 2 == 1 then
					r -= 1
				end
			end
			aboveSmooth = isSmooth(r, c, plane)
		end
		if (plane == 0 and AvailL) or (plane > 0 and AvailLChroma) then
			local r, c = MiRow, MiCol - 1
			if plane > 0 then
				if ssx == 1 and MiCol % 2 == 1 then
					c -= 1
				end
				if ssy == 1 and MiRow % 2 == 0 then
					r += 1
				end
			end
			leftSmooth = isSmooth(r, c, plane)
		end
		return (aboveSmooth or leftSmooth) and 1 or 0
	end

	local function edgeStrength(w, h, filterType, delta)
		local d = abs(delta)
		local blkWh = w + h
		local s = 0
		if filterType == 0 then
			if blkWh <= 8 then
				if d >= 56 then
					s = 1
				end
			elseif blkWh <= 16 then
				if d >= 40 then
					s = 1
				end
			elseif blkWh <= 24 then
				if d >= 8 then
					s = 1
				end
				if d >= 16 then
					s = 2
				end
				if d >= 32 then
					s = 3
				end
			elseif blkWh <= 32 then
				s = 1
				if d >= 4 then
					s = 2
				end
				if d >= 32 then
					s = 3
				end
			else
				s = 3
			end
		else
			if blkWh <= 8 then
				if d >= 40 then
					s = 1
				end
				if d >= 64 then
					s = 2
				end
			elseif blkWh <= 16 then
				if d >= 20 then
					s = 1
				end
				if d >= 48 then
					s = 2
				end
			elseif blkWh <= 24 then
				if d >= 4 then
					s = 3
				end
			else
				s = 3
			end
		end
		return s
	end

	local function useUpsample(w, h, filterType, delta)
		local d = abs(delta)
		if d <= 0 or d >= 40 then
			return 0
		elseif filterType == 0 then
			return (w + h <= 16) and 1 or 0
		end
		return (w + h <= 8) and 1 or 0
	end

	-- filters entries -1 .. sz - 2 of buf (AR or LC)
	local function edgeFilter(buf, sz, strength)
		if strength == 0 then
			return
		end
		for i = 0, sz - 1 do
			EDGE[i + 1] = buf[i + 16]
		end
		local k0 = (strength - 1) * 5
		local t0, t1, t2, t3, t4 = IntraEdgeKernel[k0 + 1], IntraEdgeKernel[k0 + 2], IntraEdgeKernel[k0 + 3],
			IntraEdgeKernel[k0 + 4], IntraEdgeKernel[k0 + 5]
		local last = sz - 1
		for i = 1, sz - 1 do
			local s = t0 * EDGE[max(i - 2, 0) + 1] + t1 * EDGE[max(i - 1, 0) + 1] + t2 * EDGE[i + 1]
				+ t3 * EDGE[min(i + 1, last) + 1] + t4 * EDGE[min(i + 2, last) + 1]
			buf[i + 16] = (s + 8) // 16
		end
	end

	local function edgeUpsample(buf, numPx)
		-- dup[k] = EDGE[k + 1]
		EDGE[1] = buf[16]
		for i = -1, numPx - 1 do
			EDGE[i + 3] = buf[i + 17]
		end
		EDGE[numPx + 3] = buf[numPx + 16]
		buf[15] = EDGE[1]
		for i = 0, numPx - 1 do
			local s = -EDGE[i + 1] + 9 * EDGE[i + 2] + 9 * EDGE[i + 3] - EDGE[i + 4]
			s = (s + 8) // 16
			if s < 0 then
				s = 0
			elseif s > pixMax then
				s = pixMax
			end
			buf[2 * i + 16] = s
			buf[2 * i + 17] = EDGE[i + 3]
		end
	end

	function predictIntra(plane, x, y, haveLeft, haveAbove, haveAboveRight, haveBelowLeft, mode, log2W, log2H)
		local buf, stride = planes[plane], pstride[plane]
		local w, h = P2[log2W + 1], P2[log2H + 1]
		local maxX = MiCols * 4 - 1
		local maxY = MiRows * 4 - 1
		if plane > 0 then
			maxX = (MiCols * 4) // P2[ssx + 1] - 1
			maxY = (MiRows * 4) // P2[ssy + 1] - 1
		end
		local base = y * stride + x
		local n = w + h
		local half = P2[BitDepth]
		-- above row
		if not haveAbove and haveLeft then
			local v = readu16(buf, (base - 1) * 2)
			for i = 0, n - 1 do
				AR[i + 17] = v
			end
		elseif not haveAbove then
			for i = 0, n - 1 do
				AR[i + 17] = half - 1
			end
		else
			local aboveLimit = min(maxX, x + (haveAboveRight and 2 * w or w) - 1) - x
			local rb = (base - stride) * 2
			for i = 0, n - 1 do
				AR[i + 17] = readu16(buf, rb + min(aboveLimit, i) * 2)
			end
		end
		-- left column
		if not haveLeft and haveAbove then
			local v = readu16(buf, (base - stride) * 2)
			for i = 0, n - 1 do
				LC[i + 17] = v
			end
		elseif not haveLeft then
			for i = 0, n - 1 do
				LC[i + 17] = half + 1
			end
		else
			local leftLimit = min(maxY, y + (haveBelowLeft and 2 * h or h) - 1) - y
			for i = 0, n - 1 do
				LC[i + 17] = readu16(buf, ((base - 1) + min(leftLimit, i) * stride) * 2)
			end
		end
		local corner
		if haveAbove and haveLeft then
			corner = readu16(buf, (base - stride - 1) * 2)
		elseif haveAbove then
			corner = readu16(buf, (base - stride) * 2)
		elseif haveLeft then
			corner = readu16(buf, (base - 1) * 2)
		else
			corner = half
		end
		AR[16] = corner
		LC[16] = corner

		if plane == 0 and useFilterIntra == 1 then
			local w4, h2 = w // 4, h // 2
			local tapsBase = filterIntraMode * 56
			for i2 = 0, h2 - 1 do
				for j4 = 0, w4 - 1 do
					local p0, p1, p2, p3, p4, p5, p6
					local r0 = (i2 * 2 - 1) * w -- previous row in PRED
					if i2 == 0 then
						local a = j4 * 4 + 16
						p0, p1, p2, p3, p4 = AR[a], AR[a + 1], AR[a + 2], AR[a + 3], AR[a + 4]
					else
						if j4 == 0 then
							p0 = LC[i2 * 2 - 1 + 17]
						else
							p0 = PRED[r0 + j4 * 4 - 1 + 1]
						end
						p1 = PRED[r0 + j4 * 4 + 1]
						p2 = PRED[r0 + j4 * 4 + 2]
						p3 = PRED[r0 + j4 * 4 + 3]
						p4 = PRED[r0 + j4 * 4 + 4]
					end
					if j4 == 0 then
						p5 = LC[i2 * 2 + 17]
						p6 = LC[i2 * 2 + 1 + 17]
					else
						p5 = PRED[(i2 * 2) * w + j4 * 4 - 1 + 1]
						p6 = PRED[(i2 * 2 + 1) * w + j4 * 4 - 1 + 1]
					end
					for i1 = 0, 1 do
						for j1 = 0, 3 do
							local t = tapsBase + (i1 * 4 + j1) * 7
							local pr = IntraFilterTaps[t + 1] * p0 + IntraFilterTaps[t + 2] * p1 + IntraFilterTaps[t + 3] * p2
								+ IntraFilterTaps[t + 4] * p3 + IntraFilterTaps[t + 5] * p4 + IntraFilterTaps[t + 6] * p5
								+ IntraFilterTaps[t + 7] * p6
							local v = pr >= 0 and (pr + 8) // 16 or -((-pr + 8) // 16)
							if v < 0 then
								v = 0
							elseif v > pixMax then
								v = pixMax
							end
							PRED[(i2 * 2 + i1) * w + j4 * 4 + j1 + 1] = v
						end
					end
				end
			end
			for i = 0, h - 1 do
				local o = (base + i * stride) * 2
				local p = i * w
				for j = 0, w - 1 do
					writeu16(buf, o + j * 2, PRED[p + j + 1])
				end
			end
			return
		end

		if mode >= 1 and mode <= 8 then
			local angleDelta = plane == 0 and AngleDeltaY or AngleDeltaUV
			local pAngle = ModeToAngle[mode + 1] + angleDelta * 3
			local upA, upL = 0, 0
			if S.enable_intra_edge_filter == 1 then
				if pAngle ~= 90 and pAngle ~= 180 then
					if pAngle > 90 and pAngle < 180 and (w + h) >= 24 then
						local s = LC[17] * 5 + AR[16] * 6 + AR[17] * 5
						local v = (s + 8) // 16
						AR[16] = v
						LC[16] = v
					end
					local filterType = getFilterType(plane)
					if haveAbove then
						local strength = edgeStrength(w, h, filterType, pAngle - 90)
						local numPx = min(w, maxX - x + 1) + (pAngle < 90 and h or 0) + 1
						edgeFilter(AR, numPx, strength)
					end
					if haveLeft then
						local strength = edgeStrength(w, h, filterType, pAngle - 180)
						local numPx = min(h, maxY - y + 1) + (pAngle > 180 and w or 0) + 1
						edgeFilter(LC, numPx, strength)
					end
				end
				local filterType = getFilterType(plane)
				upA = useUpsample(w, h, filterType, pAngle - 90)
				if upA == 1 then
					edgeUpsample(AR, w + (pAngle < 90 and h or 0))
				end
				upL = useUpsample(w, h, filterType, pAngle - 180)
				if upL == 1 then
					edgeUpsample(LC, h + (pAngle > 180 and w or 0))
				end
			end
			local dx, dy = 0, 0
			if pAngle < 90 then
				dx = DrIntraDeriv[pAngle + 1]
			elseif pAngle > 90 and pAngle < 180 then
				dx = DrIntraDeriv[180 - pAngle + 1]
			end
			if pAngle > 90 and pAngle < 180 then
				dy = DrIntraDeriv[pAngle - 90 + 1]
			elseif pAngle > 180 then
				dy = DrIntraDeriv[270 - pAngle + 1]
			end
			if pAngle < 90 then
				local maxBaseX = (w + h - 1) * P2[upA + 1]
				local sh = P2[7 - upA] -- 2^(6 - upA)
				for i = 0, h - 1 do
					local idx = (i + 1) * dx
					local shift = ((idx * P2[upA + 1]) // 2) % 32
					local b0 = idx // sh
					local o = (base + i * stride) * 2
					for j = 0, w - 1 do
						local b = b0 + j * P2[upA + 1]
						local v
						if b < maxBaseX then
							v = (AR[b + 17] * (32 - shift) + AR[b + 18] * shift + 16) // 32
						else
							v = AR[maxBaseX + 17]
						end
						writeu16(buf, o + j * 2, v)
					end
				end
			elseif pAngle > 90 and pAngle < 180 then
				local shA, shL = P2[7 - upA], P2[7 - upL]
				local lim = -P2[upA + 1]
				for i = 0, h - 1 do
					local o = (base + i * stride) * 2
					for j = 0, w - 1 do
						local idx = j * 64 - (i + 1) * dx
						local b = idx // shA
						local v
						if b >= lim then
							local shift = ((idx * P2[upA + 1]) // 2) % 32
							v = (AR[b + 17] * (32 - shift) + AR[b + 18] * shift + 16) // 32
						else
							idx = i * 64 - (j + 1) * dy
							b = idx // shL
							local shift = ((idx * P2[upL + 1]) // 2) % 32
							v = (LC[b + 17] * (32 - shift) + LC[b + 18] * shift + 16) // 32
						end
						writeu16(buf, o + j * 2, v)
					end
				end
			elseif pAngle > 180 then
				local sh = P2[7 - upL]
				for j = 0, w - 1 do
					local idx = (j + 1) * dy
					local b0 = idx // sh
					local shift = ((idx * P2[upL + 1]) // 2) % 32
					for i = 0, h - 1 do
						local b = b0 + i * P2[upL + 1]
						local v = (LC[b + 17] * (32 - shift) + LC[b + 18] * shift + 16) // 32
						writeu16(buf, (base + i * stride + j) * 2, v)
					end
				end
			elseif pAngle == 90 then
				for i = 0, h - 1 do
					local o = (base + i * stride) * 2
					for j = 0, w - 1 do
						writeu16(buf, o + j * 2, AR[j + 17])
					end
				end
			else
				for i = 0, h - 1 do
					local o = (base + i * stride) * 2
					local v = LC[i + 17]
					for j = 0, w - 1 do
						writeu16(buf, o + j * 2, v)
					end
				end
			end
		elseif mode == 9 then
			local wx, wy = SmW[log2W], SmW[log2H]
			local bl, tr = LC[h - 1 + 17], AR[w - 1 + 17]
			for i = 0, h - 1 do
				local o = (base + i * stride) * 2
				local wyi = wy[i + 1]
				local li = LC[i + 17]
				for j = 0, w - 1 do
					local wxj = wx[j + 1]
					local s = wyi * AR[j + 17] + (256 - wyi) * bl + wxj * li + (256 - wxj) * tr
					writeu16(buf, o + j * 2, (s + 256) // 512)
				end
			end
		elseif mode == 10 then
			local wy = SmW[log2H]
			local bl = LC[h - 1 + 17]
			for i = 0, h - 1 do
				local o = (base + i * stride) * 2
				local wyi = wy[i + 1]
				for j = 0, w - 1 do
					writeu16(buf, o + j * 2, (wyi * AR[j + 17] + (256 - wyi) * bl + 128) // 256)
				end
			end
		elseif mode == 11 then
			local wx = SmW[log2W]
			local tr = AR[w - 1 + 17]
			for i = 0, h - 1 do
				local o = (base + i * stride) * 2
				local li = LC[i + 17]
				for j = 0, w - 1 do
					local wxj = wx[j + 1]
					writeu16(buf, o + j * 2, (wxj * li + (256 - wxj) * tr + 128) // 256)
				end
			end
		elseif mode == 0 then
			local avg
			if haveLeft and haveAbove then
				local sum = 0
				for k = 0, h - 1 do
					sum += LC[k + 17]
				end
				for k = 0, w - 1 do
					sum += AR[k + 17]
				end
				avg = (sum + (w + h) // 2) // (w + h)
			elseif haveLeft then
				local sum = 0
				for k = 0, h - 1 do
					sum += LC[k + 17]
				end
				avg = min((sum + h // 2) // h, pixMax)
			elseif haveAbove then
				local sum = 0
				for k = 0, w - 1 do
					sum += AR[k + 17]
				end
				avg = min((sum + w // 2) // w, pixMax)
			else
				avg = half
			end
			for i = 0, h - 1 do
				local o = (base + i * stride) * 2
				for j = 0, w - 1 do
					writeu16(buf, o + j * 2, avg)
				end
			end
		else
			-- Paeth
			local tl = AR[16]
			for i = 0, h - 1 do
				local o = (base + i * stride) * 2
				local l = LC[i + 17]
				for j = 0, w - 1 do
					local a = AR[j + 17]
					local b = a + l - tl
					local pL, pT, pTL = abs(b - l), abs(b - a), abs(b - tl)
					local v
					if pL <= pT and pL <= pTL then
						v = l
					elseif pT <= pTL then
						v = a
					else
						v = tl
					end
					writeu16(buf, o + j * 2, v)
				end
			end
		end
	end

	function predictPalette(plane, startX, startY, x, y, txSz)
		local w, h = TxW[txSz + 1], TxH[txSz + 1]
		local pal = plane == 0 and palY or (plane == 1 and palU or palV)
		local map = plane == 0 and ColorMapY or ColorMapUV
		local buf, stride = planes[plane], pstride[plane]
		for i = 0, h - 1 do
			local o = ((startY + i) * stride + startX) * 2
			local m = (y * 4 + i) * 64 + x * 4
			for j = 0, w - 1 do
				writeu16(buf, o + j * 2, pal[readu8(map, m + j)])
			end
		end
	end

	local CFL_L = tcreate(32 * 32, 0)

	function predictCfl(plane, startX, startY, txSz)
		local w, h = TxW[txSz + 1], TxH[txSz + 1]
		local alpha = plane == 1 and CflAlphaU or CflAlphaV
		local Y, ys = planes[0], pstride[0]
		local buf, stride = planes[plane], pstride[plane]
		local sum = 0
		local mul = P2[4 - ssx - ssy] -- 2^(3 - subX - subY)
		for i = 0, h - 1 do
			local lumaY = min((startY + i) * P2[ssy + 1], MaxLumaH - P2[ssy + 1])
			for j = 0, w - 1 do
				local lumaX = min((startX + j) * P2[ssx + 1], MaxLumaW - P2[ssx + 1])
				local o = (lumaY * ys + lumaX) * 2
				local t = readu16(Y, o)
				if ssx == 1 then
					t += readu16(Y, o + 2)
				end
				if ssy == 1 then
					t += readu16(Y, o + ys * 2)
					if ssx == 1 then
						t += readu16(Y, o + ys * 2 + 2)
					end
				end
				local v = t * mul
				CFL_L[i * w + j + 1] = v
				sum += v
			end
		end
		local avg = round2(sum, TxWLog2[txSz + 1] + TxHLog2[txSz + 1])
		for i = 0, h - 1 do
			local o = ((startY + i) * stride + startX) * 2
			for j = 0, w - 1 do
				local dc = readu16(buf, o + j * 2)
				local sl = round2signed(alpha * (CFL_L[i * w + j + 1] - avg), 6)
				local v = dc + sl
				if v < 0 then
					v = 0
				elseif v > pixMax then
					v = pixMax
				end
				writeu16(buf, o + j * 2, v)
			end
		end
	end

end
local decodeTile
do

	------------------------------------------------------------------------------------------------------------------------
	-- loop restoration coefficients

	local SgrParams = Tab.Sgr_Params
	local WIENER_MIN, WIENER_MAX, WIENER_K = { -5, -23, -17 }, { 10, 8, 46 }, { 1, 2, 3 }
	local SGR_MIN, SGR_MAX = { -96, -32 }, { 31, 95 }

	local function subexpWithRefBool(low, high, k, r)
		local mx = high - low
		r -= low
		local i, mk = 0, 0
		local v
		while true do
			local b2 = i > 0 and k + i - 1 or k
			local a = P2[b2 + 1]
			if mx <= mk + 3 * a then
				v = symNS(mx - mk) + mk
				break
			elseif literal(1) == 1 then
				i += 1
				mk += a
			else
				v = literal(b2) + mk
				break
			end
		end
		local x
		if r * 2 <= mx then
			x = inverseRecenter(r, v)
		else
			x = mx - 1 - inverseRecenter(mx - 1 - r, v)
		end
		return x + low
	end

	local function countUnits(unitSize, frameSize)
		return max((frameSize + unitSize // 2) // unitSize, 1)
	end

	local function readLrUnit(plane, idx)
		local U = lrUnits[plane]
		local frt = F.FrameRestorationType[plane]
		local t
		if frt == 1 then
			t = sym(3877, 2) == 1 and 1 or 0
		elseif frt == 2 then
			t = sym(3880, 2) == 1 and 2 or 0
		else
			t = sym(3883, 3)
		end
		U.type[idx] = t
		if t == 1 then
			for pass = 0, 1 do
				local first = 0
				if plane > 0 then
					first = 1
					U.wiener[idx * 6 + pass * 3 + 1] = 0
				end
				for j = first, 2 do
					local ref = RefLrWiener[plane * 6 + pass * 3 + j + 1]
					local v = subexpWithRefBool(WIENER_MIN[j + 1], WIENER_MAX[j + 1] + 1, WIENER_K[j + 1], ref)
					U.wiener[idx * 6 + pass * 3 + j + 1] = v
					RefLrWiener[plane * 6 + pass * 3 + j + 1] = v
				end
			end
		elseif t == 2 then
			local set = literal(4)
			U.sgrSet[idx] = set
			for i = 0, 1 do
				local radius = SgrParams[set * 4 + i * 2 + 1]
				local lo, hi = SGR_MIN[i + 1], SGR_MAX[i + 1]
				local v
				if radius ~= 0 then
					v = subexpWithRefBool(lo, hi + 1, 4, RefSgrXqd[plane * 2 + i + 1])
				else
					v = 0
					if i == 1 then
						v = math.clamp(128 - RefSgrXqd[plane * 2 + 1], lo, hi)
					end
				end
				U.sgrXqd[idx * 2 + i + 1] = v
				RefSgrXqd[plane * 2 + i + 1] = v
			end
		end
	end

	local function readLr(r, c, bSize)
		if F.allow_intrabc == 1 then
			return
		end
		local w = Num4x4W[bSize + 1]
		local h = Num4x4H[bSize + 1]
		for plane = 0, NumPlanes - 1 do
			if F.FrameRestorationType[plane] ~= 0 then
				local sx = plane == 0 and 0 or ssx
				local sy = plane == 0 and 0 or ssy
				local U = lrUnits[plane]
				local unitSize = F.LoopRestorationSize[plane]
				local unitRows, unitCols = U.rows, U.cols
				local unitRowStart = (r * (4 // P2[sy + 1]) + unitSize - 1) // unitSize
				local unitRowEnd = min(unitRows, ((r + h) * (4 // P2[sy + 1]) + unitSize - 1) // unitSize)
				local num, den
				if F.use_superres == 1 then
					num = (4 // P2[sx + 1]) * F.SuperresDenom
					den = unitSize * 8
				else
					num = 4 // P2[sx + 1]
					den = unitSize
				end
				local unitColStart = (c * num + den - 1) // den
				local unitColEnd = min(unitCols, ((c + w) * num + den - 1) // den)
				for unitRow = unitRowStart, unitRowEnd - 1 do
					for unitCol = unitColStart, unitColEnd - 1 do
						readLrUnit(plane, unitRow * unitCols + unitCol)
					end
				end
			end
		end
	end

	------------------------------------------------------------------------------------------------------------------------
	-- transform blocks

	local function bdGet(plane, y, x)
		return blockDecoded[plane][(y + 1) * 34 + x + 2]
	end

	local function getTxSizeUV(txSz)
		local uvTx = MaxTxSizeRect[planeSize(MiSize, ssx, ssy) + 1]
		local tw, th = TxW[uvTx + 1], TxH[uvTx + 1]
		if tw == 64 or th == 64 then
			if tw == 16 then
				return 9
			elseif th == 16 then
				return 10
			end
			return 3
		end
		return uvTx
	end


	local function transformBlock(plane, baseX, baseY, txSz, x, y)
		local startX = baseX + 4 * x
		local startY = baseY + 4 * y
		local sx = plane > 0 and ssx or 0
		local sy = plane > 0 and ssy or 0
		local row = (startY * P2[sy + 1]) // 4
		local col = (startX * P2[sx + 1]) // 4
		local sbMask = sb128 and 31 or 15
		local sbRow = band(row, sbMask)
		local sbCol = band(col, sbMask)
		local stepX = TxW[txSz + 1] // 4
		local stepY = TxH[txSz + 1] // 4
		local maxX = (MiCols * 4) // P2[sx + 1]
		local maxY = (MiRows * 4) // P2[sy + 1]
		if startX >= maxX or startY >= maxY then
			return
		end
		if isInter == 0 then
			if (plane == 0 and PaletteSizeY > 0) or (plane ~= 0 and PaletteSizeUV > 0) then
				predictPalette(plane, startX, startY, x, y, txSz)
			else
				local isCfl = plane > 0 and UVMode == 13
				local mode
				if plane == 0 then
					mode = YMode
				else
					mode = isCfl and 0 or UVMode
				end
				local haveLeft = (plane == 0 and AvailL or (plane > 0 and AvailLChroma)) or x > 0
				local haveAbove = (plane == 0 and AvailU or (plane > 0 and AvailUChroma)) or y > 0
				local ar = bdGet(plane, (sbRow // P2[sy + 1]) - 1, (sbCol // P2[sx + 1]) + stepX)
				local bl = bdGet(plane, (sbRow // P2[sy + 1]) + stepY, (sbCol // P2[sx + 1]) - 1)
				predictIntra(plane, startX, startY, haveLeft, haveAbove, ar, bl, mode, TxWLog2[txSz + 1], TxHLog2[txSz + 1])
				if isCfl then
					predictCfl(plane, startX, startY, txSz)
				end
			end
			if plane == 0 then
				MaxLumaW = startX + stepX * 4
				MaxLumaH = startY + stepY * 4
			end
		end
		if skip == 0 then
			local eob = coeffs(plane, startX, startY, txSz)
			if eob > 0 then
				transformBlockRecon(plane, startX, startY, txSz)
			end
		end
		local lf = mLfTx[plane]
		local pr, pc = row // P2[sy + 1], col // P2[sx + 1]
		local pRows, pCols = MiRows // P2[sy + 1], MiCols // P2[sx + 1]
		local BD = blockDecoded[plane]
		local bdr, bdc = sbRow // P2[sy + 1], sbCol // P2[sx + 1]
		for i = 0, stepY - 1 do
			if pr + i < pRows then
				local base = (pr + i) * MiCols + pc
				for j = 0, min(stepX, pCols - pc) - 1 do
					writeu8(lf, base + j, txSz)
				end
			end
			local bbase = (bdr + i + 1) * 34 + bdc + 2
			for j = 0, stepX - 1 do
				BD[bbase + j] = true
			end
		end
	end

	local function transformTree(startX, startY, w, h)
		if startX >= MiCols * 4 or startY >= MiRows * 4 then
			return
		end
		local row = startY // 4
		local col = startX // 4
		local lumaTx = readu8(mInterTx, row * MiCols + col)
		if w <= TxW[lumaTx + 1] and h <= TxH[lumaTx + 1] then
			transformBlock(0, startX, startY, TX_BY_WH[w * 128 + h], 0, 0)
		elseif w > h then
			transformTree(startX, startY, w // 2, h)
			transformTree(startX + w // 2, startY, w // 2, h)
		elseif w < h then
			transformTree(startX, startY, w, h // 2)
			transformTree(startX, startY + h // 2, w, h // 2)
		else
			transformTree(startX, startY, w // 2, h // 2)
			transformTree(startX + w // 2, startY, w // 2, h // 2)
			transformTree(startX, startY + h // 2, w // 2, h // 2)
			transformTree(startX + w // 2, startY + h // 2, w // 2, h // 2)
		end
	end

	local function residual()
		local widthChunks = max(1, BlockW[MiSize + 1] // 64)
		local heightChunks = max(1, BlockH[MiSize + 1] // 64)
		local miSizeChunk = (widthChunks > 1 or heightChunks > 1) and 12 or MiSize
		setupBlockQuant()
		for chunkY = 0, heightChunks - 1 do
			for chunkX = 0, widthChunks - 1 do
				local miRowChunk = MiRow + chunkY * 16
				local miColChunk = MiCol + chunkX * 16
				for plane = 0, (HasChroma and 2 or 0) do
					local txSz
					if Lossless then
						txSz = 0
					elseif plane == 0 then
						txSz = TxSize
					else
						txSz = getTxSizeUV(TxSize)
					end
					local stepX = TxW[txSz + 1] // 4
					local stepY = TxH[txSz + 1] // 4
					local sx = plane > 0 and ssx or 0
					local sy = plane > 0 and ssy or 0
					local pSz = planeSize(miSizeChunk, sx, sy)
					local num4x4W = Num4x4W[pSz + 1]
					local num4x4H = Num4x4H[pSz + 1]
					local baseX = (miColChunk // P2[sx + 1]) * 4
					local baseY = (miRowChunk // P2[sy + 1]) * 4
					if isInter == 1 and not Lossless and plane == 0 then
						transformTree(baseX, baseY, num4x4W * 4, num4x4H * 4)
					else
						local baseXBlock = (MiCol // P2[sx + 1]) * 4
						local baseYBlock = (MiRow // P2[sy + 1]) * 4
						for y = 0, num4x4H - 1, stepY do
							for x = 0, num4x4W - 1, stepX do
								transformBlock(plane, baseXBlock, baseYBlock, txSz, x + (chunkX * 16) // P2[sx + 1],
									y + (chunkY * 16) // P2[sy + 1])
							end
						end
					end
				end
			end
		end
	end

	------------------------------------------------------------------------------------------------------------------------
	-- blocks, partitions, tiles

	local function resetBlockContext()
		for plane = 0, (HasChroma and 2 or 0) do
			local sx = plane > 0 and ssx or 0
			local sy = plane > 0 and ssy or 0
			local a0, a1 = MiCol // P2[sx + 1], (MiCol + bw4) // P2[sx + 1]
			if a1 > a0 then
				bfill(aLevel[plane], a0, 0, a1 - a0)
				bfill(aDc[plane], a0, 0, a1 - a0)
			end
			local l0, l1 = MiRow // P2[sy + 1], (MiRow + bh4) // P2[sy + 1]
			if l1 > l0 then
				bfill(lLevel[plane], l0, 0, l1 - l0)
				bfill(lDc[plane], l0, 0, l1 - l0)
			end
		end
	end

	local function decodeBlock(r, c, subSize)
		MiRow, MiCol, MiSize = r, c, subSize
		bw4 = Num4x4W[subSize + 1]
		bh4 = Num4x4H[subSize + 1]
		if bh4 == 1 and ssy == 1 and r % 2 == 0 then
			HasChroma = false
		elseif bw4 == 1 and ssx == 1 and c % 2 == 0 then
			HasChroma = false
		else
			HasChroma = NumPlanes > 1
		end
		AvailU = isInside(r - 1, c)
		AvailL = isInside(r, c - 1)
		AvailUChroma, AvailLChroma = AvailU, AvailL
		if HasChroma then
			if ssy == 1 and bh4 == 1 then
				AvailUChroma = isInside(r - 2, c)
			end
			if ssx == 1 and bw4 == 1 then
				AvailLChroma = isInside(r, c - 2)
			end
		else
			AvailUChroma, AvailLChroma = false, false
		end
		if F.FrameIsIntra == 1 then
			intraFrameModeInfo()
		else
			interFrameModeInfo()
		end
		if PaletteSizeY > 0 or PaletteSizeUV > 0 then
			paletteTokens()
		end
		readBlockTxSize()
		if skip == 1 then
			resetBlockContext()
		end
		local rEnd, cEnd = min(r + bh4, MiRows), min(c + bw4, MiCols)
		local storeUV = RefFrame0 == 0 and HasChroma
		local compVal = (I.comp_group_idx or 0) + 2 * (I.compound_idx or 0)
		for y = r, rEnd - 1 do
			local base = y * MiCols
			for x = c, cEnd - 1 do
				local i = base + x
				writeu8(mYMode, i, YMode)
				if storeUV then
					writeu8(mUVMode, i, UVMode)
				end
				writei8(mRef, i * 2, RefFrame0)
				writei8(mRef, i * 2 + 1, RefFrame1)
				writeu8(mWritten, i, 1)
				if isInter == 1 then
					if useIntrabc == 0 then
						writeu8(mComp, i, compVal)
					end
					writeu8(mInterp, i * 2, I.interp0)
					writeu8(mInterp, i * 2 + 1, I.interp1)
					writei16(mMv, i * 8, I.mv0r)
					writei16(mMv, i * 8 + 2, I.mv0c)
					if RefFrame1 > 0 then
						writei16(mMv, i * 8 + 4, I.mv1r)
						writei16(mMv, i * 8 + 6, I.mv1c)
					end
				end
			end
		end
		if isInter == 1 then
			predictInterBlock()
		end
		residual()
		for y = r, rEnd - 1 do
			local base = y * MiCols
			for x = c, cEnd - 1 do
				local i = base + x
				writeu8(mIsInter, i, isInter)
				writeu8(mSkipMode, i, skipMode)
				writeu8(mSkip, i, skip)
				writeu8(mTxSize, i, TxSize)
				writeu8(mMiSize, i, MiSize)
				writeu8(mSeg, i, segmentId)
				writeu8(mPalY, i, PaletteSizeY)
				writeu8(mPalUV, i, PaletteSizeUV)
				writei8(mDeltaLF, i * 4, DeltaLF[0])
				writei8(mDeltaLF, i * 4 + 1, DeltaLF[1])
				writei8(mDeltaLF, i * 4 + 2, DeltaLF[2])
				writei8(mDeltaLF, i * 4 + 3, DeltaLF[3])
			end
		end
		if PaletteSizeY > 0 or PaletteSizeUV > 0 or F.allow_screen_content_tools == 1 then
			for plane = 0, 1 do
				local n = plane == 0 and PaletteSizeY or PaletteSizeUV
				local cols = plane == 0 and palY or palU
				local A, L = palAbove[plane], palLeft[plane]
				for x = c, cEnd - 1 do
					for k = 0, n - 1 do
						A[x * 8 + k + 1] = cols[k]
					end
				end
				for y = r, rEnd - 1 do
					for k = 0, n - 1 do
						L[y * 8 + k + 1] = cols[k]
					end
				end
			end
		end
	end

	local function decodePartition(r, c, bSize)
		if r >= MiRows or c >= MiCols then
			return
		end
		local availU = isInside(r - 1, c)
		local availL = isInside(r, c - 1)
		local num4x4 = Num4x4W[bSize + 1]
		local half = num4x4 // 2
		local quarter = half // 2
		local hasRows = (r + half) < MiRows
		local hasCols = (c + half) < MiCols
		local partition
		if bSize < 3 then
			partition = 0
		else
			local bsl = MiWLog2[bSize + 1]
			local above = (availU and MiWLog2[readu8(mMiSize, miIdx(r - 1, c)) + 1] < bsl) and 1 or 0
			local left = (availL and MiHLog2[readu8(mMiSize, miIdx(r, c - 1)) + 1] < bsl) and 1 or 0
			local ctx = left * 2 + above
			local off, n
			if bsl == 1 then
				off, n = 851 + ctx * 5, 4
			elseif bsl == 2 then
				off, n = 871 + ctx * 11, 10
			elseif bsl == 3 then
				off, n = 915 + ctx * 11, 10
			elseif bsl == 4 then
				off, n = 959 + ctx * 11, 10
			else
				off, n = 1003 + ctx * 9, 8
			end
			if hasRows and hasCols then
				partition = sym(off, n)
			elseif hasCols then
				-- split or horizontal
				local function p(x)
					return C[off + x - 1] - C[off + x]
				end
				local psum = p(2) + p(3) + p(4) + p(6) + p(7)
				if bSize ~= 15 then
					psum += p(9)
				end
				partition = symFixed2(psum) == 1 and 3 or 1
			elseif hasRows then
				local function p(x)
					return C[off + x - 1] - C[off + x]
				end
				local psum = p(1) + p(3) + p(4) + p(5) + p(6)
				if bSize ~= 15 then
					psum += p(8)
				end
				partition = symFixed2(psum) == 1 and 3 or 2
			else
				partition = 3
			end
		end
		local subSize = PartitionSubsize[partition * 22 + bSize + 1]
		local splitSize = PartitionSubsize[3 * 22 + bSize + 1]
		if partition == 0 then
			decodeBlock(r, c, subSize)
		elseif partition == 1 then
			decodeBlock(r, c, subSize)
			if hasRows then
				decodeBlock(r + half, c, subSize)
			end
		elseif partition == 2 then
			decodeBlock(r, c, subSize)
			if hasCols then
				decodeBlock(r, c + half, subSize)
			end
		elseif partition == 3 then
			decodePartition(r, c, subSize)
			decodePartition(r, c + half, subSize)
			decodePartition(r + half, c, subSize)
			decodePartition(r + half, c + half, subSize)
		elseif partition == 4 then
			decodeBlock(r, c, splitSize)
			decodeBlock(r, c + half, splitSize)
			decodeBlock(r + half, c, subSize)
		elseif partition == 5 then
			decodeBlock(r, c, subSize)
			decodeBlock(r + half, c, splitSize)
			decodeBlock(r + half, c + half, splitSize)
		elseif partition == 6 then
			decodeBlock(r, c, splitSize)
			decodeBlock(r + half, c, splitSize)
			decodeBlock(r, c + half, subSize)
		elseif partition == 7 then
			decodeBlock(r, c, subSize)
			decodeBlock(r, c + half, splitSize)
			decodeBlock(r + half, c + half, splitSize)
		elseif partition == 8 then
			decodeBlock(r, c, subSize)
			decodeBlock(r + quarter, c, subSize)
			decodeBlock(r + quarter * 2, c, subSize)
			if r + quarter * 3 < MiRows then
				decodeBlock(r + quarter * 3, c, subSize)
			end
		else
			decodeBlock(r, c, subSize)
			decodeBlock(r, c + quarter, subSize)
			decodeBlock(r, c + quarter * 2, subSize)
			if c + quarter * 3 < MiCols then
				decodeBlock(r, c + quarter * 3, subSize)
			end
		end
	end

	local function clearBlockDecoded(r, c, sbSize4)
		for plane = 0, NumPlanes - 1 do
			local sx = plane > 0 and ssx or 0
			local sy = plane > 0 and ssy or 0
			local sbW4 = (MiColEnd - c) // P2[sx + 1]
			local sbH4 = (MiRowEnd - r) // P2[sy + 1]
			local BD = blockDecoded[plane]
			local ny, nx = sbSize4 // P2[sy + 1], sbSize4 // P2[sx + 1]
			for y = -1, ny do
				local base = (y + 1) * 34 + 2
				for x = -1, nx do
					if y < 0 and x < sbW4 then
						BD[base + x] = true
					elseif x < 0 and y < sbH4 then
						BD[base + x] = true
					else
						BD[base + x] = false
					end
				end
			end
			BD[(ny + 1) * 34 + 1] = false
		end
	end

	function decodeTile()
		for plane = 0, NumPlanes - 1 do
			local sx = plane > 0 and ssx or 0
			local a0 = MiColStart // P2[sx + 1]
			local a1 = (MiColEnd + sx) // P2[sx + 1]
			bfill(aLevel[plane], a0, 0, a1 - a0 + 1)
			bfill(aDc[plane], a0, 0, a1 - a0 + 1)
		end
		bfill(aSegPred, MiColStart, 0, MiColEnd - MiColStart)
		for i = 0, 3 do
			DeltaLF[i] = 0
		end
		for plane = 0, NumPlanes - 1 do
			for pass = 0, 1 do
				RefSgrXqd[plane * 2 + pass + 1] = pass == 0 and -32 or 31
				RefLrWiener[plane * 6 + pass * 3 + 1] = 3
				RefLrWiener[plane * 6 + pass * 3 + 2] = -7
				RefLrWiener[plane * 6 + pass * 3 + 3] = 15
			end
		end
		local sbSize = sb128 and 15 or 12
		local sbSize4 = Num4x4W[sbSize + 1]
		for r = MiRowStart, MiRowEnd - 1, sbSize4 do
			for plane = 0, NumPlanes - 1 do
				local sy = plane > 0 and ssy or 0
				local l0 = MiRowStart // P2[sy + 1]
				local l1 = (MiRowEnd + sy) // P2[sy + 1]
				bfill(lLevel[plane], l0, 0, l1 - l0 + 1)
				bfill(lDc[plane], l0, 0, l1 - l0 + 1)
			end
			bfill(lSegPred, MiRowStart, 0, MiRowEnd - MiRowStart)
			for c = MiColStart, MiColEnd - 1, sbSize4 do
				ReadDeltas = F.delta_q_present
				-- clear_cdef
				local cr, cc = r // 16, c // 16
				writei8(cdefIdx, cr * cdefStride + cc, -1)
				if sb128 then
					writei8(cdefIdx, cr * cdefStride + cc + 1, -1)
					writei8(cdefIdx, (cr + 1) * cdefStride + cc, -1)
					writei8(cdefIdx, (cr + 1) * cdefStride + cc + 1, -1)
				end
				clearBlockDecoded(r, c, sbSize4)
				readLr(r, c, sbSize)
				decodePartition(r, c, sbSize)
			end
			breathe()
		end
	end

end
local motionFieldEstimation, storeMotionField
do

	------------------------------------------------------------------------------------------------------------------------
	-- motion vector prediction

	local RefStackMv = tcreate(8 * 4, 0) -- [idx * 4 + list * 2 + comp + 1]
	local WeightStack = tcreate(8, 0) -- [idx + 1]
	local DrlCtxStack = tcreate(8, 0)
	local GlobalMvs = { 0, 0, 0, 0 } -- [list * 2 + comp + 1]
	local NumMvFound, NewMvCount, FoundMatch = 0, 0, 0
	local ZeroMvContext, NewMvContext, RefMvContext = 0, 0, 0
	local CloseMatches, TotalMatches = 0, 0
	local motionField = {} -- [ref] = buffer of i16 (row, col) per 8x8 unit
	local mfW8, mfH8 = 0, 0
	local MV_INVALID = -32768

	local function lowerMv(v)
		if F.allow_high_precision_mv == 1 then
			return v
		end
		if F.force_integer_mv == 1 then
			local a = abs(v)
			local aInt = (a + 3) // 8
			return v > 0 and aInt * 8 or -(aInt * 8)
		end
		if v % 2 ~= 0 then
			return v > 0 and v - 1 or v + 1
		end
		return v
	end

	local function setupGlobalMv(refList)
		local ref = refList == 0 and RefFrame0 or RefFrame1
		local mvr, mvc = 0, 0
		local typ = ref > 0 and F.GmType[ref] or 0
		if ref <= 0 or typ == 0 then
			mvr, mvc = 0, 0
		elseif typ == 1 then
			local gm = F.gm_params
			mvr = gm[ref * 6 + 1] // 8192
			mvc = gm[ref * 6 + 2] // 8192
		else
			local gm = F.gm_params
			local b = ref * 6
			local x = MiCol * 4 + BlockW[MiSize + 1] // 2 - 1
			local y = MiRow * 4 + BlockH[MiSize + 1] // 2 - 1
			local xc = (gm[b + 3] - 65536) * x + gm[b + 4] * y + gm[b + 1]
			local yc = gm[b + 5] * x + (gm[b + 6] - 65536) * y + gm[b + 2]
			if F.allow_high_precision_mv == 1 then
				mvr = round2signed(yc, 13)
				mvc = round2signed(xc, 13)
			else
				mvr = round2signed(yc, 14) * 2
				mvc = round2signed(xc, 14) * 2
			end
		end
		GlobalMvs[refList * 2 + 1] = lowerMv(mvr)
		GlobalMvs[refList * 2 + 2] = lowerMv(mvc)
	end

	local function hasNewmv(mode)
		return mode == 17 or mode == 25 or mode == 22 or mode == 23 or mode == 20 or mode == 21
	end

	local function addRefMvCandidate(mvRow, mvCol, isCompound, weight)
		local i = mvRow * MiCols + mvCol
		if readu8(mIsInter, i) == 0 then
			return
		end
		local candMode = readu8(mYMode, i)
		local candSize = readu8(mMiSize, i)
		if not isCompound then
			for candList = 0, 1 do
				if readi8(mRef, i * 2 + candList) == RefFrame0 then
					local large = min(BlockW[candSize + 1], BlockH[candSize + 1]) >= 8
					local cr, cc
					if (candMode == 16 or candMode == 24) and F.GmType[RefFrame0] > 1 and large then
						cr, cc = GlobalMvs[1], GlobalMvs[2]
					else
						cr = readi16(mMv, i * 8 + candList * 4)
						cc = readi16(mMv, i * 8 + candList * 4 + 2)
					end
					cr, cc = lowerMv(cr), lowerMv(cc)
					if hasNewmv(candMode) then
						NewMvCount += 1
					end
					FoundMatch = 1
					local found = false
					for idx = 0, NumMvFound - 1 do
						if RefStackMv[idx * 4 + 1] == cr and RefStackMv[idx * 4 + 2] == cc then
							WeightStack[idx + 1] += weight
							found = true
							break
						end
					end
					if not found and NumMvFound < 8 then
						RefStackMv[NumMvFound * 4 + 1] = cr
						RefStackMv[NumMvFound * 4 + 2] = cc
						WeightStack[NumMvFound + 1] = weight
						NumMvFound += 1
					end
				end
			end
		else
			if readi8(mRef, i * 2) == RefFrame0 and readi8(mRef, i * 2 + 1) == RefFrame1 then
				local c0r, c0c = readi16(mMv, i * 8), readi16(mMv, i * 8 + 2)
				local c1r, c1c = readi16(mMv, i * 8 + 4), readi16(mMv, i * 8 + 6)
				if candMode == 24 then
					if F.GmType[RefFrame0] > 1 then
						c0r, c0c = GlobalMvs[1], GlobalMvs[2]
					end
					if F.GmType[RefFrame1] > 1 then
						c1r, c1c = GlobalMvs[3], GlobalMvs[4]
					end
				end
				c0r, c0c, c1r, c1c = lowerMv(c0r), lowerMv(c0c), lowerMv(c1r), lowerMv(c1c)
				FoundMatch = 1
				local found = false
				for idx = 0, NumMvFound - 1 do
					local b = idx * 4
					if RefStackMv[b + 1] == c0r and RefStackMv[b + 2] == c0c and RefStackMv[b + 3] == c1r
						and RefStackMv[b + 4] == c1c then
						WeightStack[idx + 1] += weight
						found = true
						break
					end
				end
				if not found and NumMvFound < 8 then
					local b = NumMvFound * 4
					RefStackMv[b + 1], RefStackMv[b + 2], RefStackMv[b + 3], RefStackMv[b + 4] = c0r, c0c, c1r, c1c
					WeightStack[NumMvFound + 1] = weight
					NumMvFound += 1
				end
				if hasNewmv(candMode) then
					NewMvCount += 1
				end
			end
		end
	end

	local function scanRow(deltaRow, isCompound)
		local end4 = min(min(bw4, MiCols - MiCol), 16)
		local deltaCol = 0
		local useStep16 = bw4 >= 16
		if abs(deltaRow) > 1 then
			deltaRow += MiRow % 2
			deltaCol = 1 - MiCol % 2
		end
		local i = 0
		while i < end4 do
			local mvRow = MiRow + deltaRow
			local mvCol = MiCol + deltaCol + i
			if not isInside(mvRow, mvCol) then
				break
			end
			local len = min(bw4, Num4x4W[readu8(mMiSize, mvRow * MiCols + mvCol) + 1])
			if abs(deltaRow) > 1 then
				len = max(2, len)
			end
			if useStep16 then
				len = max(4, len)
			end
			addRefMvCandidate(mvRow, mvCol, isCompound, len * 2)
			i += len
		end
	end

	local function scanCol(deltaCol, isCompound)
		local end4 = min(min(bh4, MiRows - MiRow), 16)
		local deltaRow = 0
		local useStep16 = bh4 >= 16
		if abs(deltaCol) > 1 then
			deltaRow = 1 - MiRow % 2
			deltaCol += MiCol % 2
		end
		local i = 0
		while i < end4 do
			local mvRow = MiRow + deltaRow + i
			local mvCol = MiCol + deltaCol
			if not isInside(mvRow, mvCol) then
				break
			end
			local len = min(bh4, Num4x4H[readu8(mMiSize, mvRow * MiCols + mvCol) + 1])
			if abs(deltaCol) > 1 then
				len = max(2, len)
			end
			if useStep16 then
				len = max(4, len)
			end
			addRefMvCandidate(mvRow, mvCol, isCompound, len * 2)
			i += len
		end
	end

	local function scanPoint(deltaRow, deltaCol, isCompound)
		local mvRow = MiRow + deltaRow
		local mvCol = MiCol + deltaCol
		if isInside(mvRow, mvCol) and readu8(mWritten, mvRow * MiCols + mvCol) == 1 then
			addRefMvCandidate(mvRow, mvCol, isCompound, 4)
		end
	end

	local function addTplRefMv(deltaRow, deltaCol, isCompound)
		local mvRow = bor(MiRow + deltaRow, 1)
		local mvCol = bor(MiCol + deltaCol, 1)
		if not isInside(mvRow, mvCol) then
			return
		end
		local x8, y8 = mvCol // 2, mvRow // 2
		local at = (y8 * mfW8 + x8) * 4
		if deltaRow == 0 and deltaCol == 0 then
			ZeroMvContext = 1
		end
		if not isCompound then
			local mf = motionField[RefFrame0]
			local cr = readi16(mf, at)
			if cr == MV_INVALID then
				return
			end
			local cc = readi16(mf, at + 2)
			cr, cc = lowerMv(cr), lowerMv(cc)
			if deltaRow == 0 and deltaCol == 0 then
				if abs(cr - GlobalMvs[1]) >= 16 or abs(cc - GlobalMvs[2]) >= 16 then
					ZeroMvContext = 1
				else
					ZeroMvContext = 0
				end
			end
			for idx = 0, NumMvFound - 1 do
				if RefStackMv[idx * 4 + 1] == cr and RefStackMv[idx * 4 + 2] == cc then
					WeightStack[idx + 1] += 2
					return
				end
			end
			if NumMvFound < 8 then
				RefStackMv[NumMvFound * 4 + 1] = cr
				RefStackMv[NumMvFound * 4 + 2] = cc
				WeightStack[NumMvFound + 1] = 2
				NumMvFound += 1
			end
		else
			local mf0, mf1 = motionField[RefFrame0], motionField[RefFrame1]
			local c0r = readi16(mf0, at)
			if c0r == MV_INVALID then
				return
			end
			local c1r = readi16(mf1, at)
			if c1r == MV_INVALID then
				return
			end
			local c0c, c1c = readi16(mf0, at + 2), readi16(mf1, at + 2)
			c0r, c0c, c1r, c1c = lowerMv(c0r), lowerMv(c0c), lowerMv(c1r), lowerMv(c1c)
			if deltaRow == 0 and deltaCol == 0 then
				if abs(c0r - GlobalMvs[1]) >= 16 or abs(c0c - GlobalMvs[2]) >= 16 or abs(c1r - GlobalMvs[3]) >= 16
					or abs(c1c - GlobalMvs[4]) >= 16 then
					ZeroMvContext = 1
				else
					ZeroMvContext = 0
				end
			end
			for idx = 0, NumMvFound - 1 do
				local b = idx * 4
				if RefStackMv[b + 1] == c0r and RefStackMv[b + 2] == c0c and RefStackMv[b + 3] == c1r
					and RefStackMv[b + 4] == c1c then
					WeightStack[idx + 1] += 2
					return
				end
			end
			if NumMvFound < 8 then
				local b = NumMvFound * 4
				RefStackMv[b + 1], RefStackMv[b + 2], RefStackMv[b + 3], RefStackMv[b + 4] = c0r, c0c, c1r, c1c
				WeightStack[NumMvFound + 1] = 2
				NumMvFound += 1
			end
		end
	end

	local function temporalScan(isCompound)
		local stepW4 = bw4 >= 16 and 4 or 2
		local stepH4 = bh4 >= 16 and 4 or 2
		for deltaRow = 0, min(bh4, 16) - 1, stepH4 do
			for deltaCol = 0, min(bw4, 16) - 1, stepW4 do
				addTplRefMv(deltaRow, deltaCol, isCompound)
			end
		end
		local allowExtension = bh4 >= 2 and bh4 < 16 and bw4 >= 2 and bw4 < 16
		if allowExtension then
			local pos = { bh4, -2, bh4, bw4, bh4 - 2, bw4 }
			for i = 0, 2 do
				local dr, dc = pos[i * 2 + 1], pos[i * 2 + 2]
				local row = MiRow % 16 + dr
				local col = MiCol % 16 + dc
				if row >= 0 and row < 16 and col >= 0 and col < 16 then
					addTplRefMv(dr, dc, isCompound)
				end
			end
		end
	end

	local function sortStack(start, stop, isCompound)
		while stop > start do
			local newEnd = start
			for idx = start + 1, stop - 1 do
				if WeightStack[idx] < WeightStack[idx + 1] then
					WeightStack[idx], WeightStack[idx + 1] = WeightStack[idx + 1], WeightStack[idx]
					local a, b = (idx - 1) * 4, idx * 4
					for k = 1, 4 do
						RefStackMv[a + k], RefStackMv[b + k] = RefStackMv[b + k], RefStackMv[a + k]
					end
					newEnd = idx
				end
			end
			stop = newEnd
		end
	end

	local RefIdMvs, RefDiffMvs = {}, {} -- [list * 4 + idx * 2 + comp + 1]
	local RefIdCount, RefDiffCount = { 0, 0 }, { 0, 0 }

	local function addExtraMvCandidate(mvRow, mvCol, isCompound)
		local i = mvRow * MiCols + mvCol
		local bias = F.RefFrameSignBias
		if isCompound then
			for candList = 0, 1 do
				local candRef = readi8(mRef, i * 2 + candList)
				if candRef > 0 then
					for list = 0, 1 do
						local cr = readi16(mMv, i * 8 + candList * 4)
						local cc = readi16(mMv, i * 8 + candList * 4 + 2)
						local rf = list == 0 and RefFrame0 or RefFrame1
						if candRef == rf and RefIdCount[list + 1] < 2 then
							local k = list * 4 + RefIdCount[list + 1] * 2
							RefIdMvs[k + 1], RefIdMvs[k + 2] = cr, cc
							RefIdCount[list + 1] += 1
						elseif RefDiffCount[list + 1] < 2 then
							if bias[candRef] ~= bias[rf] then
								cr, cc = -cr, -cc
							end
							local k = list * 4 + RefDiffCount[list + 1] * 2
							RefDiffMvs[k + 1], RefDiffMvs[k + 2] = cr, cc
							RefDiffCount[list + 1] += 1
						end
					end
				end
			end
		else
			for candList = 0, 1 do
				local candRef = readi8(mRef, i * 2 + candList)
				if candRef > 0 then
					local cr = readi16(mMv, i * 8 + candList * 4)
					local cc = readi16(mMv, i * 8 + candList * 4 + 2)
					if bias[candRef] ~= bias[RefFrame0] then
						cr, cc = -cr, -cc
					end
					local found = false
					for idx = 0, NumMvFound - 1 do
						if RefStackMv[idx * 4 + 1] == cr and RefStackMv[idx * 4 + 2] == cc then
							found = true
							break
						end
					end
					if not found then
						RefStackMv[NumMvFound * 4 + 1] = cr
						RefStackMv[NumMvFound * 4 + 2] = cc
						WeightStack[NumMvFound + 1] = 2
						NumMvFound += 1
					end
				end
			end
		end
	end

	local function extraSearch(isCompound)
		RefIdCount[1], RefIdCount[2], RefDiffCount[1], RefDiffCount[2] = 0, 0, 0, 0
		local w4 = min(min(16, bw4), MiCols - MiCol)
		local h4 = min(min(16, bh4), MiRows - MiRow)
		local num4x4 = min(w4, h4)
		for pass = 0, 1 do
			local idx = 0
			while idx < num4x4 and NumMvFound < 2 do
				local mvRow, mvCol
				if pass == 0 then
					mvRow, mvCol = MiRow - 1, MiCol + idx
				else
					mvRow, mvCol = MiRow + idx, MiCol - 1
				end
				if not isInside(mvRow, mvCol) then
					break
				end
				addExtraMvCandidate(mvRow, mvCol, isCompound)
				local sz = readu8(mMiSize, mvRow * MiCols + mvCol)
				if pass == 0 then
					idx += Num4x4W[sz + 1]
				else
					idx += Num4x4H[sz + 1]
				end
			end
		end
		if isCompound then
			local combined = {} -- [cand * 4 + list * 2 + comp + 1]
			for list = 0, 1 do
				local compCount = 0
				for idx = 0, RefIdCount[list + 1] - 1 do
					combined[compCount * 4 + list * 2 + 1] = RefIdMvs[list * 4 + idx * 2 + 1]
					combined[compCount * 4 + list * 2 + 2] = RefIdMvs[list * 4 + idx * 2 + 2]
					compCount += 1
				end
				local idx = 0
				while idx < RefDiffCount[list + 1] and compCount < 2 do
					combined[compCount * 4 + list * 2 + 1] = RefDiffMvs[list * 4 + idx * 2 + 1]
					combined[compCount * 4 + list * 2 + 2] = RefDiffMvs[list * 4 + idx * 2 + 2]
					compCount += 1
					idx += 1
				end
				while compCount < 2 do
					combined[compCount * 4 + list * 2 + 1] = GlobalMvs[list * 2 + 1]
					combined[compCount * 4 + list * 2 + 2] = GlobalMvs[list * 2 + 2]
					compCount += 1
				end
			end
			if NumMvFound == 1 then
				local b = NumMvFound * 4
				if combined[1] == RefStackMv[1] and combined[2] == RefStackMv[2] and combined[3] == RefStackMv[3]
					and combined[4] == RefStackMv[4] then
					RefStackMv[b + 1], RefStackMv[b + 2], RefStackMv[b + 3], RefStackMv[b + 4] =
						combined[5], combined[6], combined[7], combined[8]
				else
					RefStackMv[b + 1], RefStackMv[b + 2], RefStackMv[b + 3], RefStackMv[b + 4] =
						combined[1], combined[2], combined[3], combined[4]
				end
				WeightStack[NumMvFound + 1] = 2
				NumMvFound += 1
			else
				for idx = 0, 1 do
					local b = NumMvFound * 4
					RefStackMv[b + 1], RefStackMv[b + 2], RefStackMv[b + 3], RefStackMv[b + 4] =
						combined[idx * 4 + 1], combined[idx * 4 + 2], combined[idx * 4 + 3], combined[idx * 4 + 4]
					WeightStack[NumMvFound + 1] = 2
					NumMvFound += 1
				end
			end
		else
			for idx = NumMvFound, 1 do
				RefStackMv[idx * 4 + 1] = GlobalMvs[1]
				RefStackMv[idx * 4 + 2] = GlobalMvs[2]
			end
		end
	end

	local function clampMvRow(v, border)
		local top = -(MiRow * 4 * 8)
		local bottom = (MiRows - bh4 - MiRow) * 4 * 8
		return math.clamp(v, top - border, bottom + border)
	end

	local function clampMvCol(v, border)
		local left = -(MiCol * 4 * 8)
		local right = (MiCols - bw4 - MiCol) * 4 * 8
		return math.clamp(v, left - border, right + border)
	end

	function findMvStack(isCompoundN)
		local isCompound = isCompoundN == 1
		NumMvFound = 0
		NewMvCount = 0
		for k = 1, 8 do
			WeightStack[k] = 0
		end
		GlobalMvs[3], GlobalMvs[4] = 0, 0
		setupGlobalMv(0)
		if isCompound then
			setupGlobalMv(1)
		end
		FoundMatch = 0
		scanRow(-1, isCompound)
		local foundAboveMatch = FoundMatch
		FoundMatch = 0
		scanCol(-1, isCompound)
		local foundLeftMatch = FoundMatch
		FoundMatch = 0
		if max(bw4, bh4) <= 16 then
			scanPoint(-1, bw4, isCompound)
		end
		if FoundMatch == 1 then
			foundAboveMatch = 1
		end
		CloseMatches = foundAboveMatch + foundLeftMatch
		local numNearest = NumMvFound
		local numNew = NewMvCount
		for idx = 1, numNearest do
			WeightStack[idx] += 640
		end
		ZeroMvContext = 0
		if F.use_ref_frame_mvs == 1 then
			temporalScan(isCompound)
		end
		scanPoint(-1, -1, isCompound)
		if FoundMatch == 1 then
			foundAboveMatch = 1
		end
		FoundMatch = 0
		scanRow(-3, isCompound)
		if FoundMatch == 1 then
			foundAboveMatch = 1
		end
		FoundMatch = 0
		scanCol(-3, isCompound)
		if FoundMatch == 1 then
			foundLeftMatch = 1
		end
		FoundMatch = 0
		if bh4 > 1 then
			scanRow(-5, isCompound)
		end
		if FoundMatch == 1 then
			foundAboveMatch = 1
		end
		FoundMatch = 0
		if bw4 > 1 then
			scanCol(-5, isCompound)
		end
		if FoundMatch == 1 then
			foundLeftMatch = 1
		end
		TotalMatches = foundAboveMatch + foundLeftMatch
		sortStack(0, numNearest, isCompound)
		sortStack(numNearest, NumMvFound, isCompound)
		if NumMvFound < 2 then
			extraSearch(isCompound)
		end
		-- contexts and clamping
		for idx = 0, NumMvFound - 1 do
			local z = 0
			if idx + 1 < NumMvFound then
				local w0, w1 = WeightStack[idx + 1], WeightStack[idx + 2]
				if w0 >= 640 then
					if w1 < 640 then
						z = 1
					end
				else
					z = 2
				end
			end
			DrlCtxStack[idx + 1] = z
		end
		local bw, bh = BlockW[MiSize + 1], BlockH[MiSize + 1]
		for list = 0, isCompound and 1 or 0 do
			for idx = 0, NumMvFound - 1 do
				local b = idx * 4 + list * 2
				RefStackMv[b + 1] = clampMvRow(RefStackMv[b + 1], 128 + bh * 8)
				RefStackMv[b + 2] = clampMvCol(RefStackMv[b + 2], 128 + bw * 8)
			end
		end
		if CloseMatches == 0 then
			NewMvContext = min(TotalMatches, 1)
			RefMvContext = TotalMatches
		elseif CloseMatches == 1 then
			NewMvContext = 3 - min(numNew, 1)
			RefMvContext = 2 + TotalMatches
		else
			NewMvContext = 5 - min(numNew, 1)
			RefMvContext = 5
		end
	end

	------------------------------------------------------------------------------------------------------------------------
	-- inter mode syntax

	local function countRefs(frameType)
		local c = 0
		if AvailU then
			if I.AboveRef0 == frameType then
				c += 1
			end
			if I.AboveRef1 == frameType then
				c += 1
			end
		end
		if AvailL then
			if I.LeftRef0 == frameType then
				c += 1
			end
			if I.LeftRef1 == frameType then
				c += 1
			end
		end
		return c
	end

	local function refCountCtx(c0, c1)
		if c0 < c1 then
			return 0
		elseif c0 == c1 then
			return 1
		end
		return 2
	end

	local function checkBackward(r)
		return r >= 5 and r <= 7
	end

	local function ctxCompRef()
		return refCountCtx(countRefs(1) + countRefs(2), countRefs(3) + countRefs(4))
	end
	local function ctxCompRefP1()
		return refCountCtx(countRefs(1), countRefs(2))
	end
	local function ctxCompRefP2()
		return refCountCtx(countRefs(3), countRefs(4))
	end
	local function ctxCompBwdref()
		return refCountCtx(countRefs(5) + countRefs(6), countRefs(7))
	end
	local function ctxCompBwdrefP1()
		return refCountCtx(countRefs(5), countRefs(6))
	end
	local function ctxSingleRefP1()
		return refCountCtx(countRefs(1) + countRefs(2) + countRefs(3) + countRefs(4),
			countRefs(5) + countRefs(6) + countRefs(7))
	end

	local function readRefFrames()
		if skipMode == 1 then
			RefFrame0, RefFrame1 = F.SkipModeFrame[0], F.SkipModeFrame[1]
		elseif segFeatureActive(5) then
			RefFrame0, RefFrame1 = F.FeatureData[segmentId * 8 + 6], -1
		elseif segFeatureActive(6) or segFeatureActive(7) then
			RefFrame0, RefFrame1 = 1, -1
		else
			local compMode = 0
			if F.reference_select == 1 and min(bw4, bh4) >= 2 then
				local ctx
				local AS, LS, AI, LI = I.AboveSingle, I.LeftSingle, I.AboveIntra, I.LeftIntra
				if AvailU and AvailL then
					if AS and LS then
						ctx = bxor(checkBackward(I.AboveRef0) and 1 or 0, checkBackward(I.LeftRef0) and 1 or 0)
					elseif AS then
						ctx = 2 + ((checkBackward(I.AboveRef0) or AI) and 1 or 0)
					elseif LS then
						ctx = 2 + ((checkBackward(I.LeftRef0) or LI) and 1 or 0)
					else
						ctx = 4
					end
				elseif AvailU then
					ctx = AS and (checkBackward(I.AboveRef0) and 1 or 0) or 3
				elseif AvailL then
					ctx = LS and (checkBackward(I.LeftRef0) and 1 or 0) or 3
				else
					ctx = 1
				end
				compMode = sym(1542 + ctx * 3, 2)
			end
			if compMode == 1 then
				-- comp_ref_type
				local a0, a1, l0, l1 = I.AboveRef0, I.AboveRef1, I.LeftRef0, I.LeftRef1
				local function samedir(r0, r1)
					return (r0 >= 5) == (r1 >= 5)
				end
				local aboveCompInter = AvailU and not I.AboveIntra and not I.AboveSingle
				local leftCompInter = AvailL and not I.LeftIntra and not I.LeftSingle
				local aboveUniComp = aboveCompInter and samedir(a0, a1)
				local leftUniComp = leftCompInter and samedir(l0, l1)
				local ctx
				if AvailU and not I.AboveIntra and AvailL and not I.LeftIntra then
					local sd = samedir(a0, l0) and 1 or 0
					if not aboveCompInter and not leftCompInter then
						ctx = 1 + 2 * sd
					elseif not aboveCompInter then
						ctx = not leftUniComp and 1 or 3 + sd
					elseif not leftCompInter then
						ctx = not aboveUniComp and 1 or 3 + sd
					else
						if not aboveUniComp and not leftUniComp then
							ctx = 0
						elseif not aboveUniComp or not leftUniComp then
							ctx = 2
						else
							ctx = 3 + (((a0 == 5) == (l0 == 5)) and 1 or 0)
						end
					end
				elseif AvailU and AvailL then
					if aboveCompInter then
						ctx = 1 + 2 * (aboveUniComp and 1 or 0)
					elseif leftCompInter then
						ctx = 1 + 2 * (leftUniComp and 1 or 0)
					else
						ctx = 2
					end
				elseif aboveCompInter then
					ctx = 4 * (aboveUniComp and 1 or 0)
				elseif leftCompInter then
					ctx = 4 * (leftUniComp and 1 or 0)
				else
					ctx = 2
				end
				local compRefType = sym(3167 + ctx * 3, 2)
				if compRefType == 0 then
					if sym(3191 + (ctxSingleRefP1() * 3 + 0) * 3, 2) == 1 then
						RefFrame0, RefFrame1 = 5, 7
					else
						local c1 = refCountCtx(countRefs(2), countRefs(3) + countRefs(4))
						if sym(3191 + (c1 * 3 + 1) * 3, 2) == 1 then
							if sym(3191 + (ctxCompRefP2() * 3 + 2) * 3, 2) == 1 then
								RefFrame0, RefFrame1 = 1, 4
							else
								RefFrame0, RefFrame1 = 1, 3
							end
						else
							RefFrame0, RefFrame1 = 1, 2
						end
					end
				else
					if sym(1575 + (ctxCompRef() * 3 + 0) * 3, 2) == 0 then
						RefFrame0 = sym(1575 + (ctxCompRefP1() * 3 + 1) * 3, 2) == 1 and 2 or 1
					else
						RefFrame0 = sym(1575 + (ctxCompRefP2() * 3 + 2) * 3, 2) == 1 and 4 or 3
					end
					if sym(1602 + (ctxCompBwdref() * 2 + 0) * 3, 2) == 0 then
						RefFrame1 = sym(1602 + (ctxCompBwdrefP1() * 2 + 1) * 3, 2) == 1 and 6 or 5
					else
						RefFrame1 = 7
					end
				end
			else
				if sym(1620 + (ctxSingleRefP1() * 6 + 0) * 3, 2) == 1 then
					if sym(1620 + (ctxCompBwdref() * 6 + 1) * 3, 2) == 0 then
						RefFrame0 = sym(1620 + (ctxCompBwdrefP1() * 6 + 5) * 3, 2) == 1 and 6 or 5
					else
						RefFrame0 = 7
					end
				else
					if sym(1620 + (ctxCompRef() * 6 + 2) * 3, 2) == 1 then
						RefFrame0 = sym(1620 + (ctxCompRefP2() * 6 + 4) * 3, 2) == 1 and 4 or 3
					else
						RefFrame0 = sym(1620 + (ctxCompRefP1() * 6 + 3) * 3, 2) == 1 and 2 or 1
					end
				end
				RefFrame1 = -1
			end
		end
	end

	local function readMvComponent(ctx, comp)
		local base = ctx * 2 + comp
		local sign = sym(1816 + base * 3, 2)
		local class = sym(1684 + base * 12, 11)
		local mag
		if class == 0 then
			local c0bit = sym(1732 + base * 3, 2)
			local fr = 3
			if F.force_integer_mv == 0 then
				fr = sym(1764 + (base * 2 + c0bit) * 5, 4)
			end
			local hp = 1
			if F.allow_high_precision_mv == 1 then
				hp = sym(1804 + base * 3, 2)
			end
			mag = (c0bit * 8 + fr * 2 + hp) + 1
		else
			local d = 0
			for i = 0, class - 1 do
				d += sym(1828 + (base * 10 + i) * 3, 2) * P2[i + 1]
			end
			mag = 2 * P2[class + 3]
			local fr = 3
			if F.force_integer_mv == 0 then
				fr = sym(1744 + base * 5, 4)
			end
			local hp = 1
			if F.allow_high_precision_mv == 1 then
				hp = sym(1948 + base * 3, 2)
			end
			mag += (d * 8 + fr * 2 + hp) + 1
		end
		return sign == 1 and -mag or mag
	end

	local function readMv(ref, predR, predC)
		local ctx = useIntrabc == 1 and 1 or 0
		local joint = sym(1674 + ctx * 5, 4)
		local dr, dc = 0, 0
		if joint == 2 or joint == 3 then
			dr = readMvComponent(ctx, 0)
		end
		if joint == 1 or joint == 3 then
			dc = readMvComponent(ctx, 1)
		end
		return predR + dr, predC + dc
	end

	local function getMode(refList)
		local y = YMode
		if refList == 0 then
			if y < 18 then
				return y
			elseif y == 25 or y == 21 or y == 23 then
				return 17
			elseif y == 18 or y == 20 then
				return 14
			elseif y == 19 or y == 22 then
				return 15
			end
			return 16
		end
		if y == 25 or y == 20 or y == 22 then
			return 17
		elseif y == 18 or y == 21 then
			return 14
		elseif y == 19 or y == 23 then
			return 15
		end
		return 16
	end

	local function assignMv(isCompound)
		for i = 0, isCompound do
			local compMode = useIntrabc == 1 and 17 or getMode(i)
			local pr, pc
			if useIntrabc == 1 then
				pr, pc = RefStackMv[1], RefStackMv[2]
				if pr == 0 and pc == 0 then
					pr, pc = RefStackMv[5], RefStackMv[6]
				end
				if pr == 0 and pc == 0 then
					local sbSize4 = sb128 and 32 or 16
					if MiRow - sbSize4 < MiRowStart then
						pr = 0
						pc = -(sbSize4 * 4 + 256) * 8
					else
						pr = -(sbSize4 * 4 * 8)
						pc = 0
					end
				end
			elseif compMode == 16 then
				pr, pc = GlobalMvs[i * 2 + 1], GlobalMvs[i * 2 + 2]
			else
				local pos = compMode == 14 and 0 or I.RefMvIdx
				if compMode == 17 and NumMvFound <= 1 then
					pos = 0
				end
				pr, pc = RefStackMv[pos * 4 + i * 2 + 1], RefStackMv[pos * 4 + i * 2 + 2]
			end
			local mr, mc = pr, pc
			if compMode == 17 then
				mr, mc = readMv(i, pr, pc)
			end
			if i == 0 then
				I.mv0r, I.mv0c = mr, mc
			else
				I.mv1r, I.mv1c = mr, mc
			end
		end
	end
	I.assignMv = assignMv

	local function isScaled(refFrame)
		local r = D.refs[F.ref_frame_idx[refFrame - 1]]
		local xScale = (r.RefUpscaledWidth * 16384 + F.FrameWidth // 2) // F.FrameWidth
		local yScale = (r.RefFrameHeight * 16384 + F.FrameHeight // 2) // F.FrameHeight
		return xScale ~= 16384 or yScale ~= 16384
	end

	local function hasOverlappable()
		if AvailU then
			for x4 = MiCol, min(MiCols, MiCol + bw4) - 1, 2 do
				if readi8(mRef, ((MiRow - 1) * MiCols + bor(x4, 1)) * 2) > 0 then
					return true
				end
			end
		end
		if AvailL then
			for y4 = MiRow, min(MiRows, MiRow + bh4) - 1, 2 do
				if readi8(mRef, (bor(y4, 1) * MiCols + MiCol - 1) * 2) > 0 then
					return true
				end
			end
		end
		return false
	end

	-- warp samples: CandList[k * 4 + j + 1]
	local CandList = tcreate(8 * 4, 0)
	local NumSamples, NumSamplesScanned = 0, 0

	local function addSample(deltaRow, deltaCol)
		if NumSamplesScanned >= 8 then
			return
		end
		local mvRow = MiRow + deltaRow
		local mvCol = MiCol + deltaCol
		if not isInside(mvRow, mvCol) then
			return
		end
		local i = mvRow * MiCols + mvCol
		if readu8(mWritten, i) == 0 then
			return
		end
		if readi8(mRef, i * 2) ~= RefFrame0 or readi8(mRef, i * 2 + 1) ~= -1 then
			return
		end
		local candSz = readu8(mMiSize, i)
		local candW4, candH4 = Num4x4W[candSz + 1], Num4x4H[candSz + 1]
		local candRow = mvRow - mvRow % candH4
		local candCol = mvCol - mvCol % candW4
		local midY = candRow * 4 + candH4 * 2 - 1
		local midX = candCol * 4 + candW4 * 2 - 1
		local threshold = math.clamp(max(BlockW[MiSize + 1], BlockH[MiSize + 1]), 16, 112)
		local ci = candRow * MiCols + candCol
		local cmr, cmc = readi16(mMv, ci * 8), readi16(mMv, ci * 8 + 2)
		local valid = abs(cmr - I.mv0r) + abs(cmc - I.mv0c) <= threshold
		NumSamplesScanned += 1
		if not valid and NumSamplesScanned > 1 then
			return
		end
		local b = NumSamples * 4
		CandList[b + 1] = midY * 8
		CandList[b + 2] = midX * 8
		CandList[b + 3] = midY * 8 + cmr
		CandList[b + 4] = midX * 8 + cmc
		if valid then
			NumSamples += 1
		end
	end

	local function findWarpSamplesFn()
		NumSamples, NumSamplesScanned = 0, 0
		local w4, h4 = bw4, bh4
		local doTopLeft, doTopRight = true, true
		if AvailU then
			local srcSize = readu8(mMiSize, (MiRow - 1) * MiCols + MiCol)
			local srcW = Num4x4W[srcSize + 1]
			if w4 <= srcW then
				local colOffset = -(MiCol % srcW)
				if colOffset < 0 then
					doTopLeft = false
				end
				if colOffset + srcW > w4 then
					doTopRight = false
				end
				addSample(-1, 0)
			else
				local i = 0
				while i < min(w4, MiCols - MiCol) do
					local sz = readu8(mMiSize, (MiRow - 1) * MiCols + MiCol + i)
					local step = min(w4, Num4x4W[sz + 1])
					addSample(-1, i)
					i += step
				end
			end
		end
		if AvailL then
			local srcSize = readu8(mMiSize, MiRow * MiCols + MiCol - 1)
			local srcH = Num4x4H[srcSize + 1]
			if h4 <= srcH then
				local rowOffset = -(MiRow % srcH)
				if rowOffset < 0 then
					doTopLeft = false
				end
				addSample(0, -1)
			else
				local i = 0
				while i < min(h4, MiRows - MiRow) do
					local sz = readu8(mMiSize, (MiRow + i) * MiCols + MiCol - 1)
					local step = min(h4, Num4x4H[sz + 1])
					addSample(i, -1)
					i += step
				end
			end
		end
		if doTopLeft then
			addSample(-1, -1)
		end
		if doTopRight and max(w4, h4) <= 16 then
			addSample(-1, w4)
		end
		if NumSamples == 0 and NumSamplesScanned > 0 then
			NumSamples = 1
		end
	end

	function readInterModes()
		I.interintra = 0
		I.motion_mode = 0
		I.compound_type = 2
		I.comp_group_idx = 0
		I.compound_idx = 1
		I.mv1r, I.mv1c = 0, 0
		readRefFrames()
		local isCompound = RefFrame1 > 0 and 1 or 0
		findMvStack(isCompound)
		if skipMode == 1 then
			YMode = 18
		elseif segFeatureActive(6) or segFeatureActive(7) then
			YMode = 16
		elseif isCompound == 1 then
			local ctx = Tab.Compound_Mode_Ctx_Map[(RefMvContext // 2) * 5 + min(NewMvContext, 4) + 1]
			YMode = 18 + sym(1449 + ctx * 9, 8)
		else
			if sym(1407 + NewMvContext * 3, 2) == 0 then
				YMode = 17
			elseif sym(1425 + ZeroMvContext * 3, 2) == 0 then
				YMode = 16
			else
				YMode = sym(1431 + RefMvContext * 3, 2) == 0 and 14 or 15
			end
		end
		local refMvIdx = 0
		if YMode == 17 or YMode == 25 then
			for idx = 0, 1 do
				if NumMvFound > idx + 1 then
					local drl = sym(1521 + DrlCtxStack[idx + 1] * 3, 2)
					if drl == 0 then
						refMvIdx = idx
						break
					end
					refMvIdx = idx + 1
				end
			end
		elseif YMode == 15 or YMode == 19 or YMode == 22 or YMode == 23 then
			refMvIdx = 1
			for idx = 1, 2 do
				if NumMvFound > idx + 1 then
					local drl = sym(1521 + DrlCtxStack[idx + 1] * 3, 2)
					if drl == 0 then
						refMvIdx = idx
						break
					end
					refMvIdx = idx + 1
				end
			end
		end
		I.RefMvIdx = refMvIdx
		assignMv(isCompound)
		-- read_interintra_mode
		I.interintra = 0
		if skipMode == 0 and S.enable_interintra_compound == 1 and isCompound == 0 and MiSize >= 3 and MiSize <= 9 then
			local ctx = SizeGroup[MiSize + 1] - 1
			I.interintra = sym(3158 + ctx * 3, 2)
			if I.interintra == 1 then
				I.interintra_mode = sym(3386 + ctx * 5, 4)
				RefFrame1 = 0
				AngleDeltaY, AngleDeltaUV = 0, 0
				useFilterIntra = 0
				I.wedge_interintra = sym(3218 + MiSize * 3, 2)
				if I.wedge_interintra == 1 then
					I.wedge_index = sym(3401 + MiSize * 17, 16)
					I.wedge_sign = 0
				end
			end
		end
		-- read_motion_mode
		I.motion_mode = 0
		if skipMode == 0 and F.is_motion_mode_switchable == 1 and min(BlockW[MiSize + 1], BlockH[MiSize + 1]) >= 8 then
			local globalSkip = F.force_integer_mv == 0 and (YMode == 16 or YMode == 24) and F.GmType[RefFrame0] > 1
			if not globalSkip and isCompound == 0 and RefFrame1 ~= 0 and hasOverlappable() then
				findWarpSamplesFn()
				if F.force_integer_mv == 1 or NumSamples == 0 or F.allow_warped_motion == 0 or isScaled(RefFrame0) then
					I.motion_mode = sym(3092 + MiSize * 3, 2)
				else
					I.motion_mode = sym(1319 + MiSize * 4, 3)
				end
			end
		end
		-- read_compound_type
		I.comp_group_idx = 0
		I.compound_idx = 1
		if skipMode == 1 then
			I.compound_type = 2
		elseif isCompound == 1 then
			local n = WedgeBits[MiSize + 1]
			if S.enable_masked_compound == 1 then
				local ctx = 0
				if AvailU then
					if not I.AboveSingle then
						ctx += readu8(mComp, (MiRow - 1) * MiCols + MiCol) % 2
					elseif I.AboveRef0 == 7 then
						ctx += 3
					end
				end
				if AvailL then
					if not I.LeftSingle then
						ctx += readu8(mComp, MiRow * MiCols + MiCol - 1) % 2
					elseif I.LeftRef0 == 7 then
						ctx += 3
					end
				end
				I.comp_group_idx = sym(3284 + min(5, ctx) * 3, 2)
			end
			if I.comp_group_idx == 0 then
				if S.enable_jnt_comp == 1 then
					local fwd = abs(relDist(F.OrderHints[RefFrame0], F.OrderHint))
					local bck = abs(relDist(F.OrderHints[RefFrame1], F.OrderHint))
					local ctx = fwd == bck and 3 or 0
					if AvailU then
						if not I.AboveSingle then
							ctx += readu8(mComp, (MiRow - 1) * MiCols + MiCol) // 2
						elseif I.AboveRef0 == 7 then
							ctx += 1
						end
					end
					if AvailL then
						if not I.LeftSingle then
							ctx += readu8(mComp, MiRow * MiCols + MiCol - 1) // 2
						elseif I.LeftRef0 == 7 then
							ctx += 1
						end
					end
					I.compound_idx = sym(3302 + ctx * 3, 2)
					I.compound_type = I.compound_idx == 1 and 2 or 4
				else
					I.compound_type = 2
				end
			else
				if n == 0 then
					I.compound_type = 1
				else
					I.compound_type = sym(3320 + MiSize * 3, 2)
				end
			end
			if I.compound_type == 0 then
				I.wedge_index = sym(3401 + MiSize * 17, 16)
				I.wedge_sign = literal(1)
			elseif I.compound_type == 1 then
				I.mask_type = literal(1)
			end
		else
			if I.interintra == 1 then
				I.compound_type = I.wedge_interintra == 1 and 0 or 3
			else
				I.compound_type = 2
			end
		end
		-- interpolation filters
		if F.interpolation_filter == 4 then
			local dual = S.enable_dual_filter == 1
			for dir = 0, dual and 1 or 0 do
				local need
				local large = min(BlockW[MiSize + 1], BlockH[MiSize + 1]) >= 8
				if skipMode == 1 or I.motion_mode == 2 then
					need = false
				elseif large and YMode == 16 then
					need = F.GmType[RefFrame0] == 1
				elseif large and YMode == 24 then
					need = F.GmType[RefFrame0] == 1 or F.GmType[RefFrame1] == 1
				else
					need = true
				end
				local v = 0
				if need then
					local ctx = ((dir % 2) * 2 + (RefFrame1 > 0 and 1 or 0)) * 4
					local leftType, aboveType = 3, 3
					if AvailL then
						local i = MiRow * MiCols + MiCol - 1
						if readi8(mRef, i * 2) == RefFrame0 or readi8(mRef, i * 2 + 1) == RefFrame0 then
							leftType = readu8(mInterp, i * 2 + dir)
						end
					end
					if AvailU then
						local i = (MiRow - 1) * MiCols + MiCol
						if readi8(mRef, i * 2) == RefFrame0 or readi8(mRef, i * 2 + 1) == RefFrame0 then
							aboveType = readu8(mInterp, i * 2 + dir)
						end
					end
					if leftType == aboveType then
						ctx += leftType
					elseif leftType == 3 then
						ctx += aboveType
					elseif aboveType == 3 then
						ctx += leftType
					else
						ctx += 3
					end
					v = sym(1255 + ctx * 4, 3)
				end
				if dir == 0 then
					I.interp0 = v
				else
					I.interp1 = v
				end
			end
			if not dual then
				I.interp1 = I.interp0
			end
		else
			I.interp0 = F.interpolation_filter
			I.interp1 = F.interpolation_filter
		end
	end

	------------------------------------------------------------------------------------------------------------------------
	-- inter prediction

	local SubpelFilters = Tab.Subpel_Filters
	local WarpedFilters = Tab.Warped_Filters
	local DivLut = Tab.Div_Lut
	local ObmcMasks = { [2] = Tab.Obmc_Mask_2, [4] = Tab.Obmc_Mask_4, [8] = Tab.Obmc_Mask_8, [16] = Tab.Obmc_Mask_16,
		[32] = Tab.Obmc_Mask_32 }
	local IiWeights = Tab.Ii_Weights_1d
	local QuantDistWeight, QuantDistLookup = Tab.Quant_Dist_Weight, Tab.Quant_Dist_Lookup
	local PREDS = { [0] = tcreate(128 * 128, 0), tcreate(128 * 128, 0) }
	local INTERM = tcreate(140 * 128, 0)
	local MASK = tcreate(128 * 128, 0)
	local maskStride = 0
	local OBMCP = tcreate(64 * 128, 0)
	local InterRound0, InterRound1, InterPostRound = 3, 11, 0
	local FwdWeight, BckWeight = 0, 0
	local LocalWarpParams = { 0, 0, 0, 0, 0, 0 }
	local LocalValid = false

	-- round2signed(v * f, s) for products past 2^53
	local function mulRound2Signed(v, f, s)
		local neg = (v < 0) ~= (f < 0)
		local a, b = abs(v), abs(f)
		local hi = a // 16777216
		local lo = a - hi * 16777216
		local X = hi * b
		local Y = lo * b + (s > 0 and P2[s] or 0)
		local r
		if s >= 24 then
			local Yh = Y // 16777216
			r = (X + Yh) // P2[s - 23]
		else
			r = X * P2[25 - s] + Y // P2[s + 1]
		end
		return neg and -r or r
	end

	local function resolveDivisor(d)
		local n = floorLog2(abs(d))
		if abs(d) >= 4294967296 then
			n = 32
			while P2[n + 2] <= abs(d) do
				n += 1
			end
		end
		local e = abs(d) - P2[n + 1]
		local fv
		if n > 8 then
			fv = round2(e, n - 8)
		else
			fv = e * P2[9 - n]
		end
		local divShift = n + 14
		local divFactor = d < 0 and -DivLut[fv + 1] or DivLut[fv + 1]
		return divShift, divFactor
	end

	local function setupShear(wp)
		local alpha0 = math.clamp(wp[3] - 65536, -32768, 32767)
		local beta0 = math.clamp(wp[4], -32768, 32767)
		local divShift, divFactor = resolveDivisor(wp[3])
		local v = wp[5] * 65536
		local gamma0 = math.clamp(mulRound2Signed(v, divFactor, divShift), -32768, 32767)
		local w = wp[4] * wp[5]
		local delta0 = math.clamp(wp[6] - mulRound2Signed(w, divFactor, divShift) - 65536, -32768, 32767)
		local alpha = round2signed(alpha0, 6) * 64
		local beta = round2signed(beta0, 6) * 64
		local gamma = round2signed(gamma0, 6) * 64
		local delta = round2signed(delta0, 6) * 64
		local valid = true
		if 4 * abs(alpha) + 7 * abs(beta) >= 65536 then
			valid = false
		end
		if 4 * abs(gamma) + 4 * abs(delta) >= 65536 then
			valid = false
		end
		return valid, alpha, beta, gamma, delta
	end

	local function warpEstimation()
		local A00, A01, A11, Bx0, Bx1, By0, By1 = 0, 0, 0, 0, 0, 0, 0
		local midY = MiRow * 4 + bh4 * 2 - 1
		local midX = MiCol * 4 + bw4 * 2 - 1
		local suy, sux = midY * 8, midX * 8
		local duy, dux = suy + I.mv0r, sux + I.mv0c
		local function ls(a, b)
			return (a * b) // 4 + (a + b)
		end
		for i = 0, NumSamples - 1 do
			local b = i * 4
			local sy = CandList[b + 1] - suy
			local sx = CandList[b + 2] - sux
			local dy = CandList[b + 3] - duy
			local dx = CandList[b + 4] - dux
			if abs(sx - dx) < 256 and abs(sy - dy) < 256 then
				A00 += ls(sx, sx) + 8
				A01 += ls(sx, sy) + 4
				A11 += ls(sy, sy) + 8
				Bx0 += ls(sx, dx) + 8
				Bx1 += ls(sy, dx) + 4
				By0 += ls(sx, dy) + 4
				By1 += ls(sy, dy) + 8
			end
		end
		local det = A00 * A11 - A01 * A01
		if det == 0 then
			LocalValid = false
			return
		end
		LocalValid = true
		local divShift, divFactor = resolveDivisor(det)
		divShift -= 16
		if divShift < 0 then
			divFactor *= P2[-divShift + 1]
			divShift = 0
		end
		local function nondiag(v)
			return math.clamp(mulRound2Signed(v, divFactor, divShift), -8191, 8191)
		end
		local function diag(v)
			return math.clamp(mulRound2Signed(v, divFactor, divShift), 65536 - 8191, 65536 + 8191)
		end
		local W = LocalWarpParams
		W[3] = diag(A11 * Bx0 - A01 * Bx1)
		W[4] = nondiag(-A01 * Bx0 + A00 * Bx1)
		W[5] = nondiag(A11 * By0 - A01 * By1)
		W[6] = diag(-A01 * By0 + A00 * By1)
		local vx = I.mv0c * 8192 - (midX * (W[3] - 65536) + midY * W[4])
		local vy = I.mv0r * 8192 - (midX * W[5] + midY * (W[6] - 65536))
		W[1] = math.clamp(vx, -8388608, 8388607)
		W[2] = math.clamp(vy, -8388608, 8388607)
	end

	-- the block inter prediction process: into out[r * w + c + 1]
	local function blockInterPred(ref, stride, lastX, lastY, x, y, xStep, yStep, w, h, filtV, filtH, out)
		local iH = (((h - 1) * yStep + 1023) // 1024) + 8
		if w <= 4 then
			if filtH == 0 or filtH == 2 then
				filtH = 4
			elseif filtH == 1 then
				filtH = 5
			end
		end
		if h <= 4 then
			if filtV == 0 or filtV == 2 then
				filtV = 4
			elseif filtV == 1 then
				filtV = 5
			end
		end
		local r0d, r0h = P2[InterRound0 + 1], P2[InterRound0]
		local r1d, r1h = P2[InterRound1 + 1], P2[InterRound1]
		local y0 = y // 1024 - 3
		local fh = filtH * 128 + 1
		local fv = filtV * 128 + 1
		if xStep == 1024 then
			local fx = (x // 64) % 16
			local x0 = x // 1024 - 3
			local f = fh + fx * 8
			local t0, t1, t2, t3, t4, t5, t6, t7 = SubpelFilters[f], SubpelFilters[f + 1], SubpelFilters[f + 2],
				SubpelFilters[f + 3], SubpelFilters[f + 4], SubpelFilters[f + 5], SubpelFilters[f + 6], SubpelFilters[f + 7]
			local inside = x0 >= 0 and x0 + w + 7 <= lastX
			for r = 0, iH - 1 do
				local ry = y0 + r
				if ry < 0 then
					ry = 0
				elseif ry > lastY then
					ry = lastY
				end
				local rowOff = ry * stride
				local ob = r * w + 1
				if inside then
					local o = (rowOff + x0) * 2
					if fx == 0 then
						for c = 0, w - 1 do
							INTERM[ob + c] = (readu16(ref, o + c * 2 + 6) * 128 + r0h) // r0d
						end
					else
						for c = 0, w - 1 do
							local oc = o + c * 2
							local s = t0 * readu16(ref, oc) + t1 * readu16(ref, oc + 2) + t2 * readu16(ref, oc + 4)
								+ t3 * readu16(ref, oc + 6) + t4 * readu16(ref, oc + 8) + t5 * readu16(ref, oc + 10)
								+ t6 * readu16(ref, oc + 12) + t7 * readu16(ref, oc + 14)
							INTERM[ob + c] = (s + r0h) // r0d
						end
					end
				else
					for c = 0, w - 1 do
						local s = 0
						for t = 0, 7 do
							local sx = x0 + c + t
							if sx < 0 then
								sx = 0
							elseif sx > lastX then
								sx = lastX
							end
							s += SubpelFilters[f + t] * readu16(ref, (rowOff + sx) * 2)
						end
						INTERM[ob + c] = (s + r0h) // r0d
					end
				end
			end
		else
			for r = 0, iH - 1 do
				local ry = y0 + r
				if ry < 0 then
					ry = 0
				elseif ry > lastY then
					ry = lastY
				end
				local rowOff = ry * stride
				local ob = r * w + 1
				for c = 0, w - 1 do
					local p = x + xStep * c
					local f = fh + ((p // 64) % 16) * 8
					local px = p // 1024 - 3
					local s = 0
					for t = 0, 7 do
						local sx = px + t
						if sx < 0 then
							sx = 0
						elseif sx > lastX then
							sx = lastX
						end
						s += SubpelFilters[f + t] * readu16(ref, (rowOff + sx) * 2)
					end
					INTERM[ob + c] = (s + r0h) // r0d
				end
			end
		end
		if yStep == 1024 then
			local fy = (y // 64) % 16
			local f = fv + fy * 8
			local t0, t1, t2, t3, t4, t5, t6, t7 = SubpelFilters[f], SubpelFilters[f + 1], SubpelFilters[f + 2],
				SubpelFilters[f + 3], SubpelFilters[f + 4], SubpelFilters[f + 5], SubpelFilters[f + 6], SubpelFilters[f + 7]
			for r = 0, h - 1 do
				local ob = r * w + 1
				local ib = r * w + 1
				if fy == 0 then
					local ib3 = ib + 3 * w
					for c = 0, w - 1 do
						out[ob + c] = (INTERM[ib3 + c] * 128 + r1h) // r1d
					end
				else
					for c = 0, w - 1 do
						local i = ib + c
						local s = t0 * INTERM[i] + t1 * INTERM[i + w] + t2 * INTERM[i + 2 * w] + t3 * INTERM[i + 3 * w]
							+ t4 * INTERM[i + 4 * w] + t5 * INTERM[i + 5 * w] + t6 * INTERM[i + 6 * w] + t7 * INTERM[i + 7 * w]
						out[ob + c] = (s + r1h) // r1d
					end
				end
			end
		else
			for r = 0, h - 1 do
				local p = (y % 1024) + yStep * r
				local f = fv + ((p // 64) % 16) * 8
				local ib = (p // 1024) * w + 1
				local ob = r * w + 1
				for c = 0, w - 1 do
					local s = 0
					for t = 0, 7 do
						s += SubpelFilters[f + t] * INTERM[ib + t * w + c]
					end
					out[ob + c] = (s + r1h) // r1d
				end
			end
		end
	end

	local WARPI = tcreate(15 * 8, 0)

	local function blockWarp(wp, ref, stride, lastX, lastY, plane, x, y, i8, j8, w, h, out)
		local sx = plane > 0 and ssx or 0
		local sy = plane > 0 and ssy or 0
		local srcX = (x + j8 * 8 + 4) * P2[sx + 1]
		local srcY = (y + i8 * 8 + 4) * P2[sy + 1]
		local dstX = wp[3] * srcX + wp[4] * srcY + wp[1]
		local dstY = wp[5] * srcX + wp[6] * srcY + wp[2]
		local _, alpha, beta, gamma, delta = setupShear(wp)
		local x4 = dstX // P2[sx + 1]
		local y4 = dstY // P2[sy + 1]
		local ix4 = x4 // 65536
		local sx4 = x4 % 65536
		local iy4 = y4 // 65536
		local sy4 = y4 % 65536
		local r0d, r0h = P2[InterRound0 + 1], P2[InterRound0]
		local r1d, r1h = P2[InterRound1 + 1], P2[InterRound1]
		for i1 = -7, 7 do
			local ry = iy4 + i1
			if ry < 0 then
				ry = 0
			elseif ry > lastY then
				ry = lastY
			end
			local rowOff = ry * stride
			for i2 = -4, 3 do
				local sxv = sx4 + alpha * i2 + beta * i1
				local offs = (sxv + 512) // 1024 + 64
				local fb = offs * 8 + 1
				local s = 0
				for i3 = 0, 7 do
					local cx = ix4 + i2 - 3 + i3
					if cx < 0 then
						cx = 0
					elseif cx > lastX then
						cx = lastX
					end
					s += WarpedFilters[fb + i3] * readu16(ref, (rowOff + cx) * 2)
				end
				WARPI[(i1 + 7) * 8 + i2 + 4 + 1] = (s + r0h) // r0d
			end
		end
		for i1 = -4, min(4, h - i8 * 8 - 4) - 1 do
			for i2 = -4, min(4, w - j8 * 8 - 4) - 1 do
				local syv = sy4 + gamma * i2 + delta * i1
				local offs = (syv + 512) // 1024 + 64
				local fb = offs * 8 + 1
				local s = 0
				for i3 = 0, 7 do
					s += WarpedFilters[fb + i3] * WARPI[(i1 + i3 + 4) * 8 + i2 + 4 + 1]
				end
				out[(i8 * 8 + i1 + 4) * w + j8 * 8 + i2 + 4 + 1] = (s + r1h) // r1d
			end
		end
	end

	-- reference frame data for a reference frame type (or the current frame for intra block copy)
	local function refInfo(refFrame)
		if useIntrabc == 1 then
			return curFrame, F.UpscaledWidth, F.FrameWidth, F.FrameHeight, true
		end
		local r = D.refs[F.ref_frame_idx[refFrame - 1]]
		return r.frame, r.RefUpscaledWidth, r.RefFrameWidth, r.RefFrameHeight, false
	end

	-- motion vector scaling: start position and steps (1/1024 sample)
	local function scaleMv(plane, refUpW, refH, x, y, mvr, mvc)
		local xScale = (refUpW * 16384 + F.FrameWidth // 2) // F.FrameWidth
		local yScale = (refH * 16384 + F.FrameHeight // 2) // F.FrameHeight
		local sx = plane > 0 and ssx or 0
		local sy = plane > 0 and ssy or 0
		local origX = x * 16 + (2 * mvc) // P2[sx + 1] + 8
		local origY = y * 16 + (2 * mvr) // P2[sy + 1] + 8
		local baseX = origX * xScale - 8 * 16384
		local baseY = origY * yScale - 8 * 16384
		local startX = round2signed(baseX, 8) + 32
		local startY = round2signed(baseY, 8) + 32
		local stepX = round2signed(xScale, 4)
		local stepY = round2signed(yScale, 4)
		return startX, startY, stepX, stepY
	end

	local wedgeCache = {}
	local masterMask

	local function getWedgeMask(bsize, sign, wedge)
		local key = (bsize * 2 + sign) * 16 + wedge
		local m = wedgeCache[key]
		if m then
			return m
		end
		if not masterMask then
			masterMask = {}
			for d = 0, 5 do
				masterMask[d] = tcreate(64 * 64, 0)
			end
			local odd, even, vert = Tab.Wedge_Master_Oblique_Odd, Tab.Wedge_Master_Oblique_Even, Tab.Wedge_Master_Vertical
			for j = 0, 63 do
				local shift = 16
				for i = 0, 63, 2 do
					masterMask[3][i * 64 + j + 1] = even[math.clamp(j - shift, 0, 63) + 1]
					shift -= 1
					masterMask[3][(i + 1) * 64 + j + 1] = odd[math.clamp(j - shift, 0, 63) + 1]
					masterMask[1][i * 64 + j + 1] = vert[j + 1]
					masterMask[1][(i + 1) * 64 + j + 1] = vert[j + 1]
				end
			end
			for i = 0, 63 do
				for j = 0, 63 do
					local msk = masterMask[3][i * 64 + j + 1]
					masterMask[2][j * 64 + i + 1] = msk
					masterMask[4][i * 64 + 63 - j + 1] = 64 - msk
					masterMask[5][(63 - j) * 64 + i + 1] = 64 - msk
					masterMask[0][j * 64 + i + 1] = masterMask[1][i * 64 + j + 1]
				end
			end
		end
		local w, h = BlockW[bsize + 1], BlockH[bsize + 1]
		local w4, h4 = Num4x4W[bsize + 1], Num4x4H[bsize + 1]
		local shape = h4 > w4 and 0 or (h4 < w4 and 1 or 2)
		local cb = (shape * 16 + wedge) * 3 + 1
		local codebook = Tab.Wedge_Codebook
		local dir = codebook[cb]
		local xoff = 32 - (codebook[cb + 1] * w) // 8
		local yoff = 32 - (codebook[cb + 2] * h) // 8
		local MM = masterMask[dir]
		local sum = 0
		for i = 0, w - 1 do
			sum += MM[yoff * 64 + xoff + i + 1]
		end
		for i = 1, h - 1 do
			sum += MM[(yoff + i) * 64 + xoff + 1]
		end
		local avg = (sum + (w + h - 1) // 2) // (w + h - 1)
		local flipSign = avg < 32 and 1 or 0
		for s = 0, 1 do
			local t = tcreate(w * h, 0)
			for i = 0, h - 1 do
				for j = 0, w - 1 do
					local v = MM[(yoff + i) * 64 + xoff + j + 1]
					t[i * w + j + 1] = s == flipSign and v or 64 - v
				end
			end
			wedgeCache[(bsize * 2 + s) * 16 + wedge] = t
		end
		return wedgeCache[key]
	end

	local function distanceWeights(candRow, candCol)
		local i0 = candRow * MiCols + candCol
		local dist = {}
		for refList = 0, 1 do
			local h = F.OrderHints[readi8(mRef, i0 * 2 + refList)]
			dist[refList] = math.clamp(abs(relDist(h, F.OrderHint)), 0, 31)
		end
		local d0, d1 = dist[1], dist[0]
		local order = d0 <= d1 and 1 or 0
		if d0 == 0 or d1 == 0 then
			FwdWeight = QuantDistLookup[3 * 2 + order + 1]
			BckWeight = QuantDistLookup[3 * 2 + 1 - order + 1]
			return
		end
		local i = 0
		while i < 3 do
			local c0 = QuantDistWeight[i * 2 + order + 1]
			local c1 = QuantDistWeight[i * 2 + 1 - order + 1]
			if order == 1 then
				if d0 * c0 > d1 * c1 then
					break
				end
			elseif d0 * c0 < d1 * c1 then
				break
			end
			i += 1
		end
		FwdWeight = QuantDistLookup[i * 2 + order + 1]
		BckWeight = QuantDistLookup[i * 2 + 1 - order + 1]
	end

	local function predictInter(plane, baseX, baseY, w, h, candRow, candCol, isInterIntra)
		local ci = candRow * MiCols + candCol
		local isCompound = readi8(mRef, ci * 2 + 1) > 0
		InterRound0 = 3
		InterRound1 = isCompound and 7 or 11
		if BitDepth == 12 then
			InterRound0 = 5
			if not isCompound then
				InterRound1 = 9
			end
		end
		InterPostRound = 14 - (InterRound0 + InterRound1)
		if plane == 0 and I.motion_mode == 2 then
			warpEstimation()
			if LocalValid then
				LocalValid = setupShear(LocalWarpParams)
			end
		end
		local filtV, filtH = readu8(mInterp, ci * 2), readu8(mInterp, ci * 2 + 1)
		local buf, stride = planes[plane], pstride[plane]
		local sx = plane > 0 and ssx or 0
		local sy = plane > 0 and ssy or 0
		for refList = 0, isCompound and 1 or 0 do
			local refFrame = readi8(mRef, ci * 2 + refList)
			local globalValid = false
			local gm
			if (YMode == 16 or YMode == 24) and refFrame > 0 and F.GmType[refFrame] > 1 then
				gm = { F.gm_params[refFrame * 6 + 1], F.gm_params[refFrame * 6 + 2], F.gm_params[refFrame * 6 + 3],
					F.gm_params[refFrame * 6 + 4], F.gm_params[refFrame * 6 + 5], F.gm_params[refFrame * 6 + 6] }
				globalValid = setupShear(gm)
			end
			local useWarp = 0
			if w < 8 or h < 8 then
				useWarp = 0
			elseif F.force_integer_mv == 1 then
				useWarp = 0
			elseif I.motion_mode == 2 and LocalValid then
				useWarp = 1
			elseif (YMode == 16 or YMode == 24) and refFrame > 0 and F.GmType[refFrame] > 1 and not isScaled(refFrame)
				and globalValid then
				useWarp = 2
			end
			local mvr = readi16(mMv, ci * 8 + refList * 4)
			local mvc = readi16(mMv, ci * 8 + refList * 4 + 2)
			local fr, refUpW, refW, refH, isCur = refInfo(refFrame)
			local refBuf, refStride = fr.planes[plane], fr.stride[plane]
			local startX, startY, stepX, stepY = scaleMv(plane, refUpW, refH, baseX, baseY, mvr, mvc)
			local lastX, lastY
			if isCur then
				lastX = (MiCols * 4 + sx) // P2[sx + 1] - 1
				lastY = (MiRows * 4 + sy) // P2[sy + 1] - 1
			else
				lastX = (refUpW + sx) // P2[sx + 1] - 1
				lastY = (refH + sy) // P2[sy + 1] - 1
			end
			local out = PREDS[refList]
			if useWarp ~= 0 then
				local wp = useWarp == 1 and LocalWarpParams or gm
				for i8 = 0, (h - 1) // 8 do
					for j8 = 0, (w - 1) // 8 do
						blockWarp(wp, refBuf, refStride, lastX, lastY, plane, baseX, baseY, i8, j8, w, h, out)
					end
				end
			else
				blockInterPred(refBuf, refStride, lastX, lastY, startX, startY, stepX, stepY, w, h, filtV, filtH, out)
			end
		end
		local ctype = I.compound_type
		if ctype == 0 and plane == 0 then
			local m = getWedgeMask(MiSize, I.wedge_sign, I.wedge_index)
			for k = 1, w * h do
				MASK[k] = m[k]
			end
			maskStride = w
		elseif ctype == 3 then
			local sizeScale = 128 // max(h, w)
			local mode = I.interintra_mode
			for i = 0, h - 1 do
				for j = 0, w - 1 do
					local v
					if mode == 1 then
						v = IiWeights[i * sizeScale + 1]
					elseif mode == 2 then
						v = IiWeights[j * sizeScale + 1]
					elseif mode == 3 then
						v = IiWeights[min(i, j) * sizeScale + 1]
					else
						v = 32
					end
					MASK[i * w + j + 1] = v
				end
			end
			maskStride = w
		elseif ctype == 1 and plane == 0 then
			local sh = (BitDepth - 8) + InterPostRound
			local p0, p1 = PREDS[0], PREDS[1]
			for k = 1, w * h do
				local diff = round2(abs(p0[k] - p1[k]), sh)
				local m = math.clamp(38 + diff // 16, 0, 64)
				MASK[k] = I.mask_type == 1 and 64 - m or m
			end
			maskStride = w
		end
		if ctype == 4 then
			distanceWeights(candRow, candCol)
		end
		local p0, p1 = PREDS[0], PREDS[1]
		if not isCompound and not isInterIntra then
			for i = 0, h - 1 do
				local o = ((baseY + i) * stride + baseX) * 2
				local b = i * w + 1
				for j = 0, w - 1 do
					local v = p0[b + j]
					if v < 0 then
						v = 0
					elseif v > pixMax then
						v = pixMax
					end
					writeu16(buf, o + j * 2, v)
				end
			end
		elseif isCompound and ctype == 2 then
			local d, hd = P2[InterPostRound + 2], P2[InterPostRound + 1]
			for i = 0, h - 1 do
				local o = ((baseY + i) * stride + baseX) * 2
				local b = i * w + 1
				for j = 0, w - 1 do
					local v = (p0[b + j] + p1[b + j] + hd) // d
					if v < 0 then
						v = 0
					elseif v > pixMax then
						v = pixMax
					end
					writeu16(buf, o + j * 2, v)
				end
			end
		elseif isCompound and ctype == 4 then
			local d, hd = P2[InterPostRound + 5], P2[InterPostRound + 4]
			for i = 0, h - 1 do
				local o = ((baseY + i) * stride + baseX) * 2
				local b = i * w + 1
				for j = 0, w - 1 do
					local v = (FwdWeight * p0[b + j] + BckWeight * p1[b + j] + hd) // d
					if v < 0 then
						v = 0
					elseif v > pixMax then
						v = pixMax
					end
					writeu16(buf, o + j * 2, v)
				end
			end
		else
			-- mask blend
			local ii = I.interintra == 1
			local direct = (sx == 0 and sy == 0) or (ii and I.wedge_interintra ~= 1)
			local ms = maskStride
			local pr = P2[InterPostRound + 1]
			local prh = InterPostRound > 0 and P2[InterPostRound] or 0
			local d6, h6 = P2[7 + InterPostRound], P2[6 + InterPostRound]
			for y = 0, h - 1 do
				local o = ((baseY + y) * stride + baseX) * 2
				for x = 0, w - 1 do
					local m
					if direct then
						m = MASK[y * ms + x + 1]
					elseif sx == 1 and sy == 0 then
						m = (MASK[y * ms + 2 * x + 1] + MASK[y * ms + 2 * x + 2] + 1) // 2
					else
						local k = 2 * y * ms + 2 * x + 1
						m = (MASK[k] + MASK[k + 1] + MASK[k + ms] + MASK[k + ms + 1] + 2) // 4
					end
					local v
					if ii then
						local pred0 = (p0[y * w + x + 1] + prh) // pr
						if pred0 < 0 then
							pred0 = 0
						elseif pred0 > pixMax then
							pred0 = pixMax
						end
						local pred1 = readu16(buf, o + x * 2)
						v = (m * pred1 + (64 - m) * pred0 + 32) // 64
					else
						v = (m * p0[y * w + x + 1] + (64 - m) * p1[y * w + x + 1] + h6) // d6
						if v < 0 then
							v = 0
						elseif v > pixMax then
							v = pixMax
						end
					end
					writeu16(buf, o + x * 2, v)
				end
			end
		end
	end

	local function overlappedMotion(plane, w, h)
		local sx = plane > 0 and ssx or 0
		local sy = plane > 0 and ssy or 0
		local buf, stride = planes[plane], pstride[plane]
		local function predictOverlap(candRow, candCol, x4, y4, predW, predH, pass, mask)
			local ci = candRow * MiCols + candCol
			local mvr, mvc = readi16(mMv, ci * 8), readi16(mMv, ci * 8 + 2)
			local refFrame = readi8(mRef, ci * 2)
			local r = D.refs[F.ref_frame_idx[refFrame - 1]]
			local fr = r.frame
			local predX = (x4 * 4) // P2[sx + 1]
			local predY = (y4 * 4) // P2[sy + 1]
			local startX, startY, stepX, stepY = scaleMv(plane, r.RefUpscaledWidth, r.RefFrameHeight, predX, predY, mvr, mvc)
			local lastX = (r.RefUpscaledWidth + sx) // P2[sx + 1] - 1
			local lastY = (r.RefFrameHeight + sy) // P2[sy + 1] - 1
			local save0, save1 = InterRound0, InterRound1
			InterRound0 = BitDepth == 12 and 5 or 3
			InterRound1 = BitDepth == 12 and 9 or 11
			blockInterPred(fr.planes[plane], fr.stride[plane], lastX, lastY, startX, startY, stepX, stepY, predW, predH,
				readu8(mInterp, ci * 2), readu8(mInterp, ci * 2 + 1), OBMCP)
			InterRound0, InterRound1 = save0, save1
			for i = 0, predH - 1 do
				local o = ((predY + i) * stride + predX) * 2
				for j = 0, predW - 1 do
					local op = OBMCP[i * predW + j + 1]
					if op < 0 then
						op = 0
					elseif op > pixMax then
						op = pixMax
					end
					local m = pass == 0 and mask[i + 1] or mask[j + 1]
					local cur = readu16(buf, o + j * 2)
					writeu16(buf, o + j * 2, (m * cur + (64 - m) * op + 32) // 64)
				end
			end
		end
		if AvailU then
			if planeSize(MiSize, sx, sy) >= 3 then
				local x4 = MiCol
				local nCount = 0
				local nLimit = min(4, MiWLog2[MiSize + 1])
				while nCount < nLimit and x4 < min(MiCols, MiCol + bw4) do
					local candRow = MiRow - 1
					local candCol = bor(x4, 1)
					local candSz = readu8(mMiSize, candRow * MiCols + candCol)
					local step4 = math.clamp(Num4x4W[candSz + 1], 2, 16)
					if readi8(mRef, (candRow * MiCols + candCol) * 2) > 0 then
						nCount += 1
						local predW = min(w, (step4 * 4) // P2[sx + 1])
						local predH = min(h // 2, 32 // P2[sy + 1])
						predictOverlap(candRow, candCol, x4, MiRow, predW, predH, 0, ObmcMasks[min(predH, 32)])
					end
					x4 += step4
				end
			end
		end
		if AvailL then
			local y4 = MiRow
			local nCount = 0
			local nLimit = min(4, MiHLog2[MiSize + 1])
			while nCount < nLimit and y4 < min(MiRows, MiRow + bh4) do
				local candCol = MiCol - 1
				local candRow = bor(y4, 1)
				local candSz = readu8(mMiSize, candRow * MiCols + candCol)
				local step4 = math.clamp(Num4x4H[candSz + 1], 2, 16)
				if readi8(mRef, (candRow * MiCols + candCol) * 2) > 0 then
					nCount += 1
					local predW = min(w // 2, 32 // P2[sx + 1])
					local predH = min(h, (step4 * 4) // P2[sy + 1])
					predictOverlap(candRow, candCol, MiCol, y4, predW, predH, 1, ObmcMasks[min(predW, 32)])
				end
				y4 += step4
			end
		end
	end

	-- compute_prediction() for an inter block
	function predictInterBlock()
		local sbMask = sb128 and 31 or 15
		local sbRow = MiRow % (sbMask + 1)
		local sbCol = MiCol % (sbMask + 1)
		local isII = RefFrame1 == 0
		for plane = 0, HasChroma and 2 or 0 do
			local sx = plane > 0 and ssx or 0
			local sy = plane > 0 and ssy or 0
			local pSz = planeSize(MiSize, sx, sy)
			local num4x4W = Num4x4W[pSz + 1]
			local num4x4H = Num4x4H[pSz + 1]
			local log2W = 2 + MiWLog2[pSz + 1]
			local log2H = 2 + MiHLog2[pSz + 1]
			local baseX = (MiCol // P2[sx + 1]) * 4
			local baseY = (MiRow // P2[sy + 1]) * 4
			local candRow = (MiRow // P2[sy + 1]) * P2[sy + 1]
			local candCol = (MiCol // P2[sx + 1]) * P2[sx + 1]
			if isII then
				local im = I.interintra_mode
				local mode = im == 0 and 0 or (im == 1 and 1 or (im == 2 and 2 or 9))
				local BD = blockDecoded[plane]
				local ar = BD[((sbRow // P2[sy + 1]) - 1 + 1) * 34 + (sbCol // P2[sx + 1]) + num4x4W + 2]
				local bl = BD[((sbRow // P2[sy + 1]) + num4x4H + 1) * 34 + (sbCol // P2[sx + 1]) - 1 + 2]
				predictIntra(plane, baseX, baseY, plane == 0 and AvailL or AvailLChroma, plane == 0 and AvailU or AvailUChroma,
					ar, bl, mode, log2W, log2H)
			end
			local predW = BlockW[MiSize + 1] // P2[sx + 1]
			local predH = BlockH[MiSize + 1] // P2[sy + 1]
			local someUseIntra = false
			for r = 0, min(num4x4H * P2[sy + 1], MiRows - candRow) - 1 do
				for c = 0, min(num4x4W * P2[sx + 1], MiCols - candCol) - 1 do
					if readi8(mRef, ((candRow + r) * MiCols + candCol + c) * 2) == 0 then
						someUseIntra = true
					end
				end
			end
			if someUseIntra then
				predW = num4x4W * 4
				predH = num4x4H * 4
				candRow = MiRow
				candCol = MiCol
			end
			local r = 0
			for y = 0, num4x4H * 4 - 1, predH do
				local c = 0
				for x = 0, num4x4W * 4 - 1, predW do
					predictInter(plane, baseX + x, baseY + y, predW, predH, candRow + r, candCol + c, isII)
					c += 1
				end
				r += 1
			end
			if I.motion_mode == 1 then
				overlappedMotion(plane, num4x4W * 4, num4x4H * 4)
			end
		end
	end

	------------------------------------------------------------------------------------------------------------------------
	-- motion fields

	function motionFieldEstimation()
		mfW8, mfH8 = MiCols // 2, MiRows // 2
		local n = mfW8 * mfH8 * 4
		for ref = 1, 7 do
			local b = motionField[ref]
			if not b or blen(b) < n then
				b = bcreate(n)
				motionField[ref] = b
			end
			for k = 0, mfW8 * mfH8 - 1 do
				writei16(b, k * 4, MV_INVALID)
				writei16(b, k * 4 + 2, MV_INVALID)
			end
		end
		local DivMult = Tab.Div_Mult
		local function projMv(v, num, den)
			local cd = min(31, den)
			local cn = math.clamp(num, -31, 31)
			local scaled = round2signed(v * cn * DivMult[cd + 1], 14)
			return math.clamp(scaled, -16383, 16383)
		end
		local function project(v8, delta, dstSign, max8, maxOff8)
			local base8 = (v8 // 8) * 8
			local offset8
			if delta >= 0 then
				offset8 = delta // 64
			else
				offset8 = -((-delta) // 64)
			end
			v8 += dstSign * offset8
			if v8 < 0 or v8 >= max8 or v8 < base8 - maxOff8 or v8 >= base8 + 8 + maxOff8 then
				return v8, false
			end
			return v8, true
		end
		local function projection(src, dstSign)
			local srcIdx = F.ref_frame_idx[src - 1]
			local r = D.refs[srcIdx]
			if r.RefMiRows ~= MiRows or r.RefMiCols ~= MiCols or r.RefFrameType == 2 or r.RefFrameType == 0 or not r.mf then
				return false
			end
			local mf = r.mf
			local refToCur = relDist(F.OrderHints[src], F.OrderHint)
			local refToDst = {}
			for dst = 1, 7 do
				refToDst[dst] = relDist(F.OrderHint, F.OrderHints[dst])
			end
			for y8 = 0, mfH8 - 1 do
				for x8 = 0, mfW8 - 1 do
					local k = y8 * mfW8 + x8
					local srcRef = readi8(mf.ref, k)
					if srcRef > 0 then
						local refOffset = relDist(F.OrderHints[src], r.SavedOrderHints[srcRef])
						local posValid = abs(refToCur) <= 31 and abs(refOffset) <= 31 and refOffset > 0
						if posValid then
							local mvr, mvc = readi16(mf.mv, k * 4), readi16(mf.mv, k * 4 + 2)
							local pr = projMv(mvr, refToCur * dstSign, refOffset)
							local pc = projMv(mvc, refToCur * dstSign, refOffset)
							local posY8, okY = project(y8, pr, dstSign, mfH8, 0)
							local posX8, okX = project(x8, pc, dstSign, mfW8, 8)
							if okY and okX then
								local at = (posY8 * mfW8 + posX8) * 4
								for dst = 1, 7 do
									local num = refToDst[dst]
									writei16(motionField[dst], at, projMv(mvr, num, refOffset))
									writei16(motionField[dst], at + 2, projMv(mvc, num, refOffset))
								end
							end
						end
					end
				end
			end
			return true
		end
		local lastIdx = F.ref_frame_idx[0]
		local curGold = F.OrderHints[4]
		local lastAlt = D.refs[lastIdx].SavedOrderHints and D.refs[lastIdx].SavedOrderHints[7]
		if lastAlt ~= curGold then
			projection(1, -1)
		end
		local refStamp = 1
		if relDist(F.OrderHints[5], F.OrderHint) > 0 then
			if projection(5, 1) then
				refStamp -= 1
			end
		end
		if relDist(F.OrderHints[6], F.OrderHint) > 0 then
			if projection(6, 1) then
				refStamp -= 1
			end
		end
		if relDist(F.OrderHints[7], F.OrderHint) > 0 and refStamp >= 0 then
			if projection(7, 1) then
				refStamp -= 1
			end
		end
		if refStamp >= 0 then
			projection(2, -1)
		end
	end

	function storeMotionField()
		local w8, h8 = MiCols // 2, MiRows // 2
		local mf = { ref = bcreate(w8 * h8), mv = bcreate(w8 * h8 * 4) }
		if F.FrameIsIntra == 0 then
			for y8 = 0, h8 - 1 do
				for x8 = 0, w8 - 1 do
					local i = (2 * y8 + 1) * MiCols + 2 * x8 + 1
					local k = y8 * w8 + x8
					local outRef, outR, outC = -1, 0, 0
					for list = 0, 1 do
						local r = readi8(mRef, i * 2 + list)
						if r > 0 then
							local refIdx = F.ref_frame_idx[r - 1]
							local dist = relDist(D.refs[refIdx].RefOrderHint, F.OrderHint)
							if dist < 0 then
								local mvr, mvc = readi16(mMv, i * 8 + list * 4), readi16(mMv, i * 8 + list * 4 + 2)
								if abs(mvr) <= 4095 and abs(mvc) <= 4095 then
									outRef, outR, outC = r, mvr, mvc
								end
							end
						end
					end
					writei8(mf.ref, k, outRef)
					writei16(mf.mv, k * 4, outR)
					writei16(mf.mv, k * 4 + 2, outC)
				end
			end
		else
			bfill(mf.ref, 0, 255)
		end
		D.curMf = mf
	end

end

return decodeTile, resetBlockQuant, predictInterBlock ~= nil, motionFieldEstimation, storeMotionField

end)()

------------------------------------------------------------------------------------------------------------------------
-- frames


local function countUnits(unitSize, frameSize)
	return max((frameSize + unitSize // 2) // unitSize, 1)
end

local function ensureBuf(b, size)
	if blen(b) < size then
		return bcreate(size)
	end
	return b
end

-- a frame store: planes of 16-bit samples plus what references keep
local function newFrame(wAlloc, hAlloc)
	local cw, ch = wAlloc // P2[ssx + 1], hAlloc // P2[ssy + 1]
	return {
		planes = { [0] = bcreate(wAlloc * hAlloc * 2), bcreate(cw * ch * 2), bcreate(cw * ch * 2) },
		stride = { [0] = wAlloc, cw, cw },
		wAlloc = wAlloc,
		hAlloc = hAlloc,
		ssx = ssx,
		ssy = ssy,
	}
end

local function frameInUse(fr)
	for i = 0, 7 do
		if D.refs[i].frame == fr then
			return true
		end
	end
	return false
end

function getFrame(wAlloc, hAlloc)
	for _, fr in D.pool do
		if fr.wAlloc == wAlloc and fr.hAlloc == hAlloc and fr.ssx == ssx and fr.ssy == ssy and not frameInUse(fr) then
			return fr
		end
	end
	local fr = newFrame(wAlloc, hAlloc)
	table.insert(D.pool, fr)
	-- drop stores nothing refers to any more
	for i = #D.pool, 1, -1 do
		local o = D.pool[i]
		if o ~= fr and not frameInUse(o) and (o.wAlloc ~= wAlloc or o.hAlloc ~= hAlloc) then
			table.remove(D.pool, i)
		end
	end
	return fr
end

local function setupFrame()
	MiRows, MiCols = F.MiRows, F.MiCols
	ssx, ssy = S.subsampling_x, S.subsampling_y
	NumPlanes, BitDepth = S.NumPlanes, S.BitDepth
	pixMax = P2[BitDepth + 1] - 1
	sb128 = S.use_128x128_superblock == 1
	local n = MiRows * MiCols
	mYMode = ensureBuf(mYMode, n)
	mUVMode = ensureBuf(mUVMode, n)
	mRef = ensureBuf(mRef, n * 2)
	mIsInter = ensureBuf(mIsInter, n)
	mSkipMode = ensureBuf(mSkipMode, n)
	mSkip = ensureBuf(mSkip, n)
	mTxSize = ensureBuf(mTxSize, n)
	mMiSize = ensureBuf(mMiSize, n)
	mSeg = bcreate(n) -- kept by references
	mPalY = ensureBuf(mPalY, n)
	mPalUV = ensureBuf(mPalUV, n)
	mInterTx = ensureBuf(mInterTx, n)
	mComp = ensureBuf(mComp, n)
	mInterp = ensureBuf(mInterp, n * 2)
	mMv = ensureBuf(mMv, n * 8)
	mDeltaLF = ensureBuf(mDeltaLF, n * 4)
	mTxType = ensureBuf(mTxType, n)
	mWritten = ensureBuf(mWritten, n)
	bfill(mWritten, 0, 0, n)
	for p = 0, 2 do
		mLfTx[p] = ensureBuf(mLfTx[p], n)
	end
	for p = 0, 2 do
		aLevel[p] = ensureBuf(aLevel[p] or bcreate(0), MiCols + 64)
		aDc[p] = ensureBuf(aDc[p] or bcreate(0), MiCols + 64)
		lLevel[p] = ensureBuf(lLevel[p] or bcreate(0), MiRows + 64)
		lDc[p] = ensureBuf(lDc[p] or bcreate(0), MiRows + 64)
	end
	aSegPred = ensureBuf(aSegPred, MiCols + 64)
	lSegPred = ensureBuf(lSegPred, MiRows + 64)
	cdefStride = MiCols // 16 + 2
	cdefIdx = ensureBuf(cdefIdx, (MiRows // 16 + 2) * cdefStride)
	bfill(cdefIdx, 0, 255)
	-- loop restoration units
	for plane = 0, NumPlanes - 1 do
		if F.FrameRestorationType[plane] ~= 0 then
			local sx = plane == 0 and 0 or ssx
			local sy = plane == 0 and 0 or ssy
			local unitSize = F.LoopRestorationSize[plane]
			local rows = countUnits(unitSize, round2(F.FrameHeight, sy))
			local cols = countUnits(unitSize, round2(F.UpscaledWidth, sx))
			lrUnits[plane] = { rows = rows, cols = cols, type = {}, wiener = {}, sgrSet = {}, sgrXqd = {} }
		else
			lrUnits[plane] = nil
		end
	end
	-- the frame store
	local sbPx = sb128 and 128 or 64
	local wAlloc = (MiCols * 4 + sbPx - 1) // sbPx * sbPx
	local hAlloc = (MiRows * 4 + sbPx - 1) // sbPx * sbPx
	curFrame = getFrame(wAlloc, hAlloc)
	for p = 0, 2 do
		planes[p] = curFrame.planes[p]
		pstride[p] = curFrame.stride[p]
	end
	-- segmentation map of the previous frame
	prevSegIds = nil
	if F.loadPrevSegmentIds then
		local prev = D.refs[F.ref_frame_idx[F.primary_ref_frame]]
		if F.segmentation_enabled == 1 and prev.RefMiCols == MiCols and prev.RefMiRows == MiRows then
			prevSegIds = prev.segIds
		end
	end
	resetBlockQuant()
end

local function decodeTiles(buf, pos, size, tgStart, tgEnd)
	for tileNum = tgStart, tgEnd do
		local tileRow = tileNum // F.TileCols
		local tileCol = tileNum % F.TileCols
		local tileSize
		if tileNum == tgEnd then
			tileSize = size
		else
			tileSize = 0
			for k = 0, F.TileSizeBytes - 1 do
				tileSize += readu8(buf, pos + k) * P2[8 * k + 1]
			end
			tileSize += 1
			pos += F.TileSizeBytes
			size -= tileSize + F.TileSizeBytes
		end
		if tileSize < 0 or size < 0 then
			fail("damaged tile sizes")
		end
		MiRowStart = F.MiRowStarts[tileRow]
		MiRowEnd = F.MiRowStarts[tileRow + 1]
		MiColStart = F.MiColStarts[tileCol]
		MiColEnd = F.MiColStarts[tileCol + 1]
		CurrentQIndex = F.base_q_idx
		tmove(FC, 1, 7885, 1, C)
		tmove(CDF_INIT, 1, 351 - 1, 1, C)
		cdfUpdate = F.disable_cdf_update == 0
		initSymbol(buf, pos, tileSize)
		decodeTile()
		if F.disable_frame_end_update_cdf == 0 and tileNum == F.context_update_tile_id then
			tmove(C, 1, 7885, 1, SAVED)
		end
		pos += tileSize
	end
end

-- the shown picture as 8-bit planes; chroma other than 4:2:0 is averaged down to 4:2:0 unless the decoder's
-- fullChroma is set
local function outputFrame(fr, w, h, bd, grain)
	local sx, sy = fr.ssx, fr.ssy
	local cw, ch = (w + sx) // P2[sx + 1], (h + sy) // P2[sy + 1]
	local to420 = not D.fullChroma and (sx ~= 1 or sy ~= 1)
	local nY, nC = w * h, cw * ch
	D.outY = ensureBuf(D.outY, nY)
	D.outU = ensureBuf(D.outU, nC)
	D.outV = ensureBuf(D.outV, nC)
	local srcPlanes = fr.planes
	if grain and grain.apply_grain == 1 then
		srcPlanes = Post.applyFilmGrain(fr, w, h, bd, grain)
	end
	local outs = { [0] = D.outY, D.outU, D.outV }
	local mono = D.S.mono_chrome == 1
	for p = 0, 2 do
		local pw, ph = p == 0 and w or cw, p == 0 and h or ch
		local src, ss, dst = srcPlanes[p], fr.stride[p], outs[p]
		if p > 0 and mono then
			bfill(dst, 0, 128, nC)
		elseif bd == 8 then
			for y = 0, ph - 1 do
				local so, dO = y * ss * 2, y * pw
				for x = 0, pw - 1 do
					writeu8(dst, dO + x, readu16(src, so + x * 2))
				end
			end
		else
			local div = P2[bd - 7]
			local add = P2[bd - 8]
			for y = 0, ph - 1 do
				local so, dO = y * ss * 2, y * pw
				for x = 0, pw - 1 do
					local v = (readu16(src, so + x * 2) + add) // div
					writeu8(dst, dO + x, v > 255 and 255 or v)
				end
			end
		end
	end
	D.width, D.height = w, h
	if to420 then
		local cw2, ch2 = (w + 1) // 2, (h + 1) // 2
		local fx, fy = sx == 0 and 2 or 1, sy == 0 and 2 or 1
		D.out420U = ensureBuf(D.out420U or bcreate(0), cw2 * ch2)
		D.out420V = ensureBuf(D.out420V or bcreate(0), cw2 * ch2)
		for p = 1, 2 do
			local src, dst = outs[p], p == 1 and D.out420U or D.out420V
			if mono then
				bfill(dst, 0, 128, cw2 * ch2)
			else
				for y = 0, ch2 - 1 do
					local y0 = min(y * fy, ch - 1)
					local y1 = min(y * fy + fy - 1, ch - 1)
					for x = 0, cw2 - 1 do
						local x0 = min(x * fx, cw - 1)
						local x1 = min(x * fx + fx - 1, cw - 1)
						local s = readu8(src, y0 * cw + x0) + readu8(src, y0 * cw + x1) + readu8(src, y1 * cw + x0)
							+ readu8(src, y1 * cw + x1)
						writeu8(dst, y * cw2 + x, (s + 2) // 4)
					end
				end
			end
		end
		return { Y = D.outY, U = D.out420U, V = D.out420V, ys = w, cs = cw2, yo = 0, co = 0 }
	end
	return { Y = D.outY, U = D.outU, V = D.outV, ys = w, cs = cw, yo = 0, co = 0 }
end

-- the reference frame update process
local function updateRefs()
	local frameCdf
	for i = 0, 7 do
		if band(rshift(F.refresh_frame_flags, i), 1) == 1 then
			if not frameCdf then
				frameCdf = table.clone(FC)
			end
			D.refs[i] = {
				RefValid = 1,
				RefFrameId = F.current_frame_id,
				RefUpscaledWidth = F.UpscaledWidth,
				RefFrameWidth = F.FrameWidth,
				RefFrameHeight = F.FrameHeight,
				RefRenderWidth = F.RenderWidth,
				RefRenderHeight = F.RenderHeight,
				RefMiCols = F.MiCols,
				RefMiRows = F.MiRows,
				RefFrameType = F.frame_type,
				RefBitDepth = S.BitDepth,
				RefOrderHint = F.OrderHint,
				SavedOrderHints = table.clone(F.OrderHints),
				frame = curFrame,
				mf = D.curMf,
				gm_params = F.gm_params,
				segIds = mSeg,
				cdf = frameCdf,
				grain = F.grain,
				loop_filter_ref_deltas = F.loop_filter_ref_deltas,
				loop_filter_mode_deltas = F.loop_filter_mode_deltas,
				FeatureEnabled = F.FeatureEnabled,
				FeatureData = F.FeatureData,
				showable = F.showable_frame,
			}
		end
	end
end

local function decodeFrameWrapup()
	if F.show_existing_frame == 0 then
		local lvl = F.loop_filter_level
		Post.bind({
			F = F, S = S, planes = planes, pstride = pstride, MiRows = MiRows, MiCols = MiCols,
			mSeg = mSeg, mRef = mRef, mYMode = mYMode, mDeltaLF = mDeltaLF, mLfTx = mLfTx, mMiSize = mMiSize,
			mSkip = mSkip, cdefIdx = cdefIdx, cdefStride = cdefStride, lrUnits = lrUnits, curFrame = curFrame,
			getFrame = getFrame, ssx = ssx, ssy = ssy, NumPlanes = NumPlanes, BitDepth = BitDepth, pixMax = pixMax,
		})
		if lvl[0] ~= 0 or lvl[1] ~= 0 then
			Post.loopFilterFrame()
		end
		if F.cdefOn then
			Post.cdefFrame()
		end
		if F.use_superres == 1 then
			Post.superresFrame()
			curFrame = Post.frame()
		end
		if F.UsesLr == 1 then
			Post.loopRestorationFrame()
		end
		if storeMotionField then
			storeMotionField()
		end
		if F.segmentation_enabled == 1 and F.segmentation_update_map == 0 then
			if prevSegIds then
				bcopy(mSeg, 0, prevSegIds, 0, MiRows * MiCols)
			else
				bfill(mSeg, 0, 0, MiRows * MiCols)
			end
		end
		updateRefs()
		if F.show_frame == 1 then
			return outputFrame(curFrame, F.UpscaledWidth, F.FrameHeight, S.BitDepth, F.grain)
		end
		return nil
	end
	-- show an existing frame
	local r = D.refs[F.frame_to_show_map_idx]
	if r.RefValid ~= 1 or not r.frame then
		fail("a frame to show is missing")
	end
	local pic = outputFrame(r.frame, r.RefUpscaledWidth, r.RefFrameHeight, r.RefBitDepth, F.grain)
	if F.frame_type == 0 then
		-- reference frame loading, then the update with refresh_frame_flags = all
		for i = 0, 7 do
			D.refs[i] = table.clone(r)
		end
		D.lastOrderHints = table.clone(r.SavedOrderHints)
	end
	return pic
end

------------------------------------------------------------------------------------------------------------------------
-- OBUs

local function frameHeaderObu()
	F = { OrderHints = table.clone(D.lastOrderHints) }
	uncompressedHeader()
	if F.show_existing_frame == 1 then
		if S.film_grain_params_present == 1 then
			F.grain = D.refs[F.frame_to_show_map_idx].grain
		else
			F.grain = nil
		end
		D.seenFrameHeader = false
		return decodeFrameWrapup()
	end
	D.lastOrderHints = F.OrderHints
	D.seenFrameHeader = true
	setupFrame()
	if F.use_ref_frame_mvs == 1 and motionFieldEstimation then
		motionFieldEstimation()
	end
	if F.FrameIsIntra == 0 and not interSupported then
		fail("inter frames are not supported")
	end
	return nil
end

local function tileGroupObu(buf, pos, size)
	local numTiles = F.TileCols * F.TileRows
	local startBit = bpos
	local tgStart, tgEnd = 0, numTiles - 1
	local flag = 0
	if numTiles > 1 then
		flag = f(1)
	end
	if numTiles > 1 and flag == 1 then
		local bits = F.TileColsLog2 + F.TileRowsLog2
		tgStart = f(bits)
		tgEnd = f(bits)
	end
	byteAlign()
	local headerBytes = (bpos - startBit) // 8
	decodeTiles(buf, pos + headerBytes, size - headerBytes, tgStart, tgEnd)
	if tgEnd == numTiles - 1 then
		if F.disable_frame_end_update_cdf == 0 then
			tmove(SAVED, 1, 7885, 1, FC)
		end
		D.seenFrameHeader = false
		return decodeFrameWrapup(), true
	end
	return nil, false
end

local function decodeObus(buf, pos, len)
	local stop = pos + len
	local shown
	bb = buf
	while pos < stop do
		bpos = pos * 8
		f(1)
		local obuType = f(4)
		local ext = f(1)
		local hasSize = f(1)
		f(1)
		local temporalId, spatialId = 0, 0
		if ext == 1 then
			temporalId = f(3)
			spatialId = f(2)
			f(3)
		end
		local p = bpos // 8
		local size
		if hasSize == 1 then
			size, p = leb128(p, stop)
		else
			size = stop - p
		end
		if p + size > stop then
			fail("damaged data (an OBU runs past its sample)")
		end
		local nextPos = p + size
		local drop = false
		if obuType ~= 1 and obuType ~= 2 and S and S.OperatingPointIdc ~= 0 and ext == 1 then
			local inT = band(rshift(S.OperatingPointIdc, temporalId), 1)
			local inS = band(rshift(S.OperatingPointIdc, spatialId + 8), 1)
			drop = inT == 0 or inS == 0
		end
		if not drop then
			D.temporal_id, D.spatial_id = temporalId, spatialId
			bpos = p * 8
			if obuType == 1 then
				S = sequenceHeader()
				D.S = S
			elseif obuType == 2 then
				D.seenFrameHeader = false
			elseif obuType == 3 or obuType == 6 then
				if not S then
					fail("a frame comes before its sequence header")
				end
				if D.seenFrameHeader then
					-- a copy of the frame header: nothing new
					if obuType == 6 then
						fail("a frame repeats its header")
					end
				else
					local pic = frameHeaderObu()
					if pic then
						shown = pic
					end
					if obuType == 6 and F.show_existing_frame == 0 then
						byteAlign()
						local hb = bpos // 8 - p
						local pic2 = tileGroupObu(buf, p + hb, size - hb)
						if pic2 then
							shown = pic2
						end
					end
				end
			elseif obuType == 4 then
				if not D.seenFrameHeader then
					fail("tiles come before their frame header")
				end
				local pic = tileGroupObu(buf, p, size)
				if pic then
					shown = pic
				end
			end
		end
		pos = nextPos
	end
	return shown
end

------------------------------------------------------------------------------------------------------------------------
-- decoder objects

local Decoder = {}
Decoder.__index = Decoder

local busy = nil

local function emptyRef()
	return { RefValid = 0, RefOrderHint = 0, RefFrameType = 0 }
end

local function bind(self)
	while busy and busy ~= self do
		task.wait()
	end
	busy = self
	D = self
	S = self.S
end

function Decoder:decodeSample(buf: buffer, pos: number, len: number)
	bind(self)
	local ok, res = pcall(decodeObus, buf, pos, len)
	busy = nil
	self.S = S
	if not ok then
		self.seenFrameHeader = false
		error(res, 0)
	end
	if res and S then
		self.fullRange = S.color_range == 1
		self.matrix = S.matrix_coefficients
		self.bt709 = S.matrix_coefficients == 1
		self.monochrome = S.mono_chrome == 1
		local full = self.fullChroma
		self.chromaShiftX = full and S.subsampling_x or 1
		self.chromaShiftY = full and S.subsampling_y or 1
		self.bitDepth = S.BitDepth
	end
	return res
end

function Decoder:reset()
	for i = 0, 7 do
		self.refs[i] = emptyRef()
	end
	self.pool = {}
	self.seenFrameHeader = false
	self.lastOrderHints = {}
end

-- av1C: the AV1CodecConfigurationRecord (4 bytes, then the sequence header OBU)
function Av1.new(av1C)
	local self = setmetatable({
		refs = {},
		pool = {},
		seenFrameHeader = false,
		lastOrderHints = {},
		temporal_id = 0,
		spatial_id = 0,
		outY = bcreate(0),
		outU = bcreate(0),
		outV = bcreate(0),
		width = 0,
		height = 0,
		cropX = 0,
		cropY = 0,
	}, Decoder)
	for i = 0, 7 do
		self.refs[i] = emptyRef()
	end
	if typeof(av1C) == "buffer" and blen(av1C) > 4 then
		bind(self)
		local ok, err = pcall(decodeObus, av1C, 4, blen(av1C) - 4)
		busy = nil
		self.S = S
		if not ok then
			error(err, 0)
		end
		if S then
			self.width = S.max_frame_width_minus_1 + 1
			self.height = S.max_frame_height_minus_1 + 1
		end
	end
	return self
end

return Av1
