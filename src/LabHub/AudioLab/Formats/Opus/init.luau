--!native
--!optimize 2
-- Opus decoder (RFC 6716): SILK (speech), CELT (music) and hybrid frames, mono or stereo, decoded to 48 kHz.
-- Opus streams arrive in MP4 / M4A (sample entry "Opus", from Formats.Mp4 on the FrameLab side) and in Ogg (.opus).
--
--   local st = Opus.new(channels)                                  -- output channels (1 or 2)
--   local n = Opus.decodePacket(st, buf, offset, length, out, outOff) -- out[c][outOff + 1 ..] gets n samples (-1..1)
--   local signal = Opus.decodeOgg(bytes, options?)                 -- a whole .opus file -> DSP.Signal (48 kHz)
--   local signal = Opus.decodePackets(list, channels, preSkip, options?, gainDb?) -- list of { buf, offset, length }
--   Opus.readDops(buffer, from, to) -> { channels, preSkip, gainDb, mapping, streams }   -- MP4 Opus setup box
--   Opus.isOgg(bytes)
-- options: Yield (function called now and then), MaxSeconds
--
-- Ported from libopus 1.5 (https://opus-codec.org), which carries this notice:
--   Copyright (c) 2001-2011 Xiph.Org, Skype Limited, Octasic, Jean-Marc Valin, Timothy B. Terriberry, CSIRO,
--   Gregory Maxwell, Mark Borgerding, Erik de Castro Lopo. Redistribution and use in source and binary forms, with or
--   without modification, are permitted provided that the following conditions are met: redistributions of source
--   code must retain the above copyright notice, this list of conditions and the following disclaimer; redistributions
--   in binary form must reproduce the above copyright notice, this list of conditions and the following disclaimer in
--   the documentation and/or other materials provided with the distribution; neither the name of Internet Society,
--   IETF or IETF Trust, nor the names of specific contributors, may be used to endorse or promote products derived
--   from this software without specific prior written permission. THIS SOFTWARE IS PROVIDED BY THE COPYRIGHT HOLDERS
--   AND CONTRIBUTORS "AS IS" AND ANY EXPRESS OR IMPLIED WARRANTIES, INCLUDING, BUT NOT LIMITED TO, THE IMPLIED
--   WARRANTIES OF MERCHANTABILITY AND FITNESS FOR A PARTICULAR PURPOSE ARE DISCLAIMED. IN NO EVENT SHALL THE COPYRIGHT
--   OWNER OR CONTRIBUTORS BE LIABLE FOR ANY DIRECT, INDIRECT, INCIDENTAL, SPECIAL, EXEMPLARY, OR CONSEQUENTIAL DAMAGES
--   (INCLUDING, BUT NOT LIMITED TO, PROCUREMENT OF SUBSTITUTE GOODS OR SERVICES; LOSS OF USE, DATA, OR PROFITS; OR
--   BUSINESS INTERRUPTION) HOWEVER CAUSED AND ON ANY THEORY OF LIABILITY, WHETHER IN CONTRACT, STRICT LIABILITY, OR TORT
--   (INCLUDING NEGLIGENCE OR OTHERWISE) ARISING IN ANY WAY OUT OF THE USE OF THIS SOFTWARE, EVEN IF ADVISED OF THE
--   POSSIBILITY OF SUCH DAMAGE.

local Opus = {}

local Entropy, Celt, Silk
if script then
	Entropy = require(script.Entropy)
	Celt = require(script.Celt)
	Silk = require(script.Silk)
else
	Entropy = require("@self/Entropy")
	Celt = require("@self/Celt")
	Silk = require("@self/Silk")
end

local MODE_SILK, MODE_HYBRID, MODE_CELT = 1000, 1001, 1002
local BW_NB, BW_MB, BW_WB, BW_SWB, BW_FB = 1, 2, 3, 4, 5
local FS = 48000
local F20, F10, F5, F2_5 = 960, 480, 240, 120
local WINDOW
do
	local T = if script then require(script.CeltTables) else require("@self/CeltTables")
	WINDOW = T.window
end

local function packetMode(toc)
	if bit32.band(toc, 0x80) ~= 0 then
		return MODE_CELT
	elseif bit32.band(toc, 0x60) == 0x60 then
		return MODE_HYBRID
	end
	return MODE_SILK
end

local function packetBandwidth(toc)
	if bit32.band(toc, 0x80) ~= 0 then
		local bw = BW_MB + bit32.band(bit32.rshift(toc, 5), 3)
		if bw == BW_MB then
			bw = BW_NB
		end
		return bw
	elseif bit32.band(toc, 0x60) == 0x60 then
		return bit32.band(toc, 0x10) ~= 0 and BW_FB or BW_SWB
	end
	return BW_NB + bit32.band(bit32.rshift(toc, 5), 3)
end

local function samplesPerFrame(toc)
	if bit32.band(toc, 0x80) ~= 0 then
		return (FS * 2 ^ bit32.band(bit32.rshift(toc, 3), 3)) // 400
	elseif bit32.band(toc, 0x60) == 0x60 then
		return bit32.band(toc, 0x08) ~= 0 and FS // 50 or FS // 100
	end
	local a = bit32.band(bit32.rshift(toc, 3), 3)
	if a == 3 then
		return FS * 60 // 1000
	end
	return (FS * 2 ^ a) // 100
end
Opus.samplesPerFrame = samplesPerFrame

-- frame sizes of one packet: returns count, sizes (list), first frame offset; nil on a malformed packet
local function parseSize(buf, pos, len)
	if len < 1 then
		return -1, 0
	end
	local b0 = buffer.readu8(buf, pos)
	if b0 < 252 then
		return b0, 1
	end
	if len < 2 then
		return -1, 0
	end
	return 4 * buffer.readu8(buf, pos + 1) + b0, 2
end

local function parsePacket(buf, off, len)
	if len < 1 then
		return nil
	end
	local toc = buffer.readu8(buf, off)
	local framesize = samplesPerFrame(toc)
	local pos = off + 1
	len -= 1
	local lastSize = len
	local sizes = {}
	local count
	local code = bit32.band(toc, 3)
	if code == 0 then
		count = 1
	elseif code == 1 then
		count = 2
		if len % 2 ~= 0 then
			return nil
		end
		lastSize = len // 2
		sizes[1] = lastSize
	elseif code == 2 then
		count = 2
		local s, bytes = parseSize(buf, pos, len)
		len -= bytes
		if s < 0 or s > len then
			return nil
		end
		sizes[1] = s
		pos += bytes
		lastSize = len - s
	else
		if len < 1 then
			return nil
		end
		local ch = buffer.readu8(buf, pos)
		pos += 1
		count = bit32.band(ch, 0x3F)
		if count <= 0 or framesize * count > 5760 then
			return nil
		end
		len -= 1
		if bit32.band(ch, 0x40) ~= 0 then
			local p
			repeat
				if len <= 0 then
					return nil
				end
				p = buffer.readu8(buf, pos)
				pos += 1
				len -= 1
				local tmp = p == 255 and 254 or p
				len -= tmp
			until p ~= 255
		end
		if len < 0 then
			return nil
		end
		local cbr = bit32.band(ch, 0x80) == 0
		if not cbr then
			lastSize = len
			for i = 1, count - 1 do
				local s, bytes = parseSize(buf, pos, len)
				len -= bytes
				if s < 0 or s > len then
					return nil
				end
				sizes[i] = s
				pos += bytes
				lastSize -= bytes + s
			end
			if lastSize < 0 then
				return nil
			end
		else
			lastSize = len // count
			if lastSize * count ~= len then
				return nil
			end
			for i = 1, count - 1 do
				sizes[i] = lastSize
			end
		end
	end
	if lastSize > 1275 then
		return nil
	end
	sizes[count] = lastSize
	return toc, count, sizes, pos
end

function Opus.new(channels)
	return {
		channels = channels, celt = Celt.new(channels), silk = nil,
		mode = 0, prevMode = 0, prevRedundancy = false, frameSize = F20, bandwidth = 0, streamChannels = channels,
	}
end

local function newBuf(channels, n)
	local t = {}
	for c = 1, channels do
		t[c] = table.create(n, 0)
	end
	return t
end

-- out = w^2 * in2 + (1 - w^2) * in1 over `overlap` samples (arrays with their own 0-based offsets)
local function smoothFade(in1, o1, in2, o2, out, oo, overlap, channels)
	for c = 1, channels do
		local a, b, y = in1[c], in2[c], out[c]
		for i = 1, overlap do
			local w = WINDOW[i]
			w = w * w
			y[oo + i] = w * b[o2 + i] + (1 - w) * a[o1 + i]
		end
	end
end

local decodeFrame
decodeFrame = function(st, buf, off, len, out, outOff, frameSize)
	local channels = st.channels
	frameSize = math.min(frameSize, FS // 25 * 3)
	local data = buf
	if len <= 1 then
		data = nil
		frameSize = math.min(frameSize, st.frameSize)
	end
	local audiosize, mode, bandwidth
	local ec
	if data then
		audiosize = st.frameSize
		mode = st.mode
		bandwidth = st.bandwidth
		ec = Entropy.new(buf, off, len)
	else
		audiosize = frameSize
		mode = st.prevRedundancy and MODE_CELT or st.prevMode
		bandwidth = 0
		if mode == 0 then
			for c = 1, channels do
				local y = out[c]
				for i = 1, audiosize do
					y[outOff + i] = 0
				end
			end
			return audiosize
		end
		if audiosize > F20 then
			local done = 0
			repeat
				local ret = decodeFrame(st, nil, 0, 0, out, outOff + done, math.min(audiosize, F20))
				done += ret
				audiosize -= ret
			until audiosize <= 0
			return frameSize
		elseif audiosize < F20 then
			if audiosize > F10 then
				audiosize = F10
			elseif mode ~= MODE_SILK and audiosize > F5 and audiosize < F10 then
				audiosize = F5
			end
		end
	end
	local celtAccum = mode ~= MODE_CELT
	local transition = false
	local pcmTransition
	if data and st.prevMode > 0 and ((mode == MODE_CELT and st.prevMode ~= MODE_CELT and not st.prevRedundancy)
		or (mode ~= MODE_CELT and st.prevMode == MODE_CELT)) then
		transition = true
	end
	if transition and mode == MODE_CELT then
		pcmTransition = newBuf(channels, F5)
		decodeFrame(st, nil, 0, 0, pcmTransition, 0, math.min(F5, audiosize))
	end
	if audiosize > frameSize then
		error("Opus: frame larger than the buffer")
	end
	frameSize = audiosize
	if mode ~= MODE_CELT then
		if not st.silk then
			st.silk = Silk.new()
		end
		if st.prevMode == MODE_CELT then
			Silk.reset(st.silk)
		end
		local ctl = st.silk.control
		ctl.payloadSizeMs = math.max(10, 1000 * audiosize // FS)
		if data then
			ctl.nChannelsInternal = st.streamChannels
			if mode == MODE_SILK then
				if bandwidth == BW_NB then
					ctl.internalSampleRate = 8000
				elseif bandwidth == BW_MB then
					ctl.internalSampleRate = 12000
				else
					ctl.internalSampleRate = 16000
				end
			else
				ctl.internalSampleRate = 16000
			end
		end
		ctl.nChannelsAPI = channels
		local lostFlag = data and 0 or 1
		local decoded = 0
		repeat
			local n = Silk.decode(st.silk, lostFlag, decoded == 0, ec, out, outOff + decoded, frameSize - decoded)
			decoded += n
		until decoded >= frameSize
	end
	local startBand = 0
	local redundancy = false
	local redundancyBytes = 0
	local celtToSilk = false
	if data and mode ~= MODE_CELT and ec:tell() + 17 + (mode == MODE_HYBRID and 20 or 0) <= 8 * len then
		if mode == MODE_HYBRID then
			redundancy = ec:bitLogp(12) ~= 0
		else
			redundancy = true
		end
		if redundancy then
			celtToSilk = ec:bitLogp(1) ~= 0
			if mode == MODE_HYBRID then
				redundancyBytes = ec:uint(256) + 2
			else
				redundancyBytes = len - ((ec:tell() + 7) // 8)
			end
			len -= redundancyBytes
			if len * 8 < ec:tell() then
				len = 0
				redundancyBytes = 0
				redundancy = false
			end
			ec.storage -= redundancyBytes
		end
	end
	if mode ~= MODE_CELT then
		startBand = 17
	end
	if redundancy then
		transition = false
	end
	if transition and mode ~= MODE_CELT then
		pcmTransition = newBuf(channels, F5)
		decodeFrame(st, nil, 0, 0, pcmTransition, 0, math.min(F5, audiosize))
	end
	local celt = st.celt
	if bandwidth ~= 0 then
		local endband = 21
		if bandwidth == BW_NB then
			endband = 13
		elseif bandwidth == BW_MB or bandwidth == BW_WB then
			endband = 17
		elseif bandwidth == BW_SWB then
			endband = 19
		end
		celt.endBand = endband
	end
	celt.streamChannels = st.streamChannels
	local redundant
	if redundancy then
		redundant = newBuf(channels, F5)
	end
	if redundancy and celtToSilk then
		celt.start = 0
		Celt.decode(celt, Entropy.new(buf, off + len, redundancyBytes), redundancyBytes, F5, redundant, 0, false)
	end
	celt.start = startBand
	if mode ~= MODE_SILK then
		local celtFrame = math.min(F20, frameSize)
		if mode ~= st.prevMode and st.prevMode > 0 and not st.prevRedundancy then
			Celt.reset(celt)
		end
		Celt.decode(celt, data and ec or nil, data and len or 0, celtFrame, out, outOff, celtAccum)
	else
		if not celtAccum then
			for c = 1, channels do
				for i = 1, frameSize do
					out[c][outOff + i] = 0
				end
			end
		end
		if st.prevMode == MODE_HYBRID and not (redundancy and celtToSilk and st.prevRedundancy) then
			celt.start = 0
			local silence = buffer.create(2)
			buffer.writeu8(silence, 0, 0xFF)
			buffer.writeu8(silence, 1, 0xFF)
			local tmp = newBuf(channels, F2_5)
			for c = 1, channels do
				for i = 1, F2_5 do
					tmp[c][i] = out[c][outOff + i]
				end
			end
			Celt.decode(celt, Entropy.new(silence, 0, 2), 2, F2_5, tmp, 0, celtAccum)
			for c = 1, channels do
				for i = 1, F2_5 do
					out[c][outOff + i] = tmp[c][i]
				end
			end
		end
	end
	if redundancy and not celtToSilk then
		Celt.reset(celt)
		celt.start = 0
		Celt.decode(celt, Entropy.new(buf, off + len, redundancyBytes), redundancyBytes, F5, redundant, 0, false)
		smoothFade(out, outOff + frameSize - F2_5, redundant, F2_5, out, outOff + frameSize - F2_5, F2_5, channels)
	end
	if redundancy and celtToSilk and (st.prevMode ~= MODE_SILK or st.prevRedundancy) then
		for c = 1, channels do
			for i = 1, F2_5 do
				out[c][outOff + i] = redundant[c][i]
			end
		end
		smoothFade(redundant, F2_5, out, outOff + F2_5, out, outOff + F2_5, F2_5, channels)
	end
	if transition then
		if audiosize >= F5 then
			for c = 1, channels do
				for i = 1, F2_5 do
					out[c][outOff + i] = pcmTransition[c][i]
				end
			end
			smoothFade(pcmTransition, F2_5, out, outOff + F2_5, out, outOff + F2_5, F2_5, channels)
		else
			smoothFade(pcmTransition, 0, out, outOff, out, outOff, F2_5, channels)
		end
	end
	st.prevMode = mode
	st.prevRedundancy = redundancy and not celtToSilk
	return audiosize
end

-- decodes one packet (or a lost one: length 0) into out[c][outOff + 1 ..]; returns the samples written
function Opus.decodePacket(st, buf, off, len, out, outOff, lostFrameSize)
	outOff = outOff or 0
	if not buf or len == 0 then
		local frameSize = lostFrameSize or st.frameSize
		local count = 0
		repeat
			count += decodeFrame(st, nil, 0, 0, out, outOff + count, frameSize - count)
		until count >= frameSize
		return count
	end
	local toc, count, sizes, pos = parsePacket(buf, off, len)
	if not toc then
		return 0
	end
	st.mode = packetMode(toc)
	st.bandwidth = packetBandwidth(toc)
	st.frameSize = samplesPerFrame(toc)
	st.streamChannels = bit32.band(toc, 0x4) ~= 0 and 2 or 1
	local n = 0
	for i = 1, count do
		local ret = decodeFrame(st, buf, pos, sizes[i], out, outOff + n, 5760 - n)
		pos += sizes[i]
		n += ret
	end
	return n
end

-- packets: list of { buf, offset, length } (a length of 0 is a lost packet) -> AudioLab DSP.Signal layout:
-- { sampleRate = 48000, channels, length, data = { f32 buffer per channel } }. gainDb: the stream's output gain.
function Opus.decodePackets(packets, channels, preSkip, options, gainDb)
	options = options or {}
	preSkip = preSkip or 0
	local outCh = math.min(2, math.max(1, channels))
	local st = Opus.new(outCh)
	local maxSamples = options.MaxSeconds and math.floor(options.MaxSeconds * FS) or math.huge
	local gain = 10 ^ ((gainDb or 0) / 20)
	local scratch = newBuf(outCh, 5760)
	local cap = 48000 * 10
	local data = {}
	for c = 1, outCh do
		data[c] = buffer.create(cap * 4)
	end
	local total = 0 -- samples kept
	local skip = preSkip
	local lastYield = os.clock()
	for _, p in ipairs(packets) do
		local got = Opus.decodePacket(st, p[1], p[2], p[3], scratch, 0)
		local from = math.min(skip, got)
		skip -= from
		local keep = math.min(got - from, maxSamples - total)
		if keep > 0 then
			if total + keep > cap then
				while total + keep > cap do
					cap *= 2
				end
				for c = 1, outCh do
					local nb = buffer.create(cap * 4)
					buffer.copy(nb, 0, data[c], 0, total * 4)
					data[c] = nb
				end
			end
			for c = 1, outCh do
				local src, dst = scratch[c], data[c]
				for i = 1, keep do
					local v = src[from + i] * gain
					if v > 1 then
						v = 1
					elseif v < -1 then
						v = -1
					end
					buffer.writef32(dst, (total + i - 1) * 4, v)
				end
			end
			total += keep
		end
		if total >= maxSamples then
			break
		end
		if options.Yield and os.clock() - lastYield > 0.02 then
			options.Yield()
			lastYield = os.clock()
		end
	end
	for c = 1, outCh do
		if buffer.len(data[c]) ~= math.max(total, 1) * 4 then
			local nb = buffer.create(math.max(total, 1) * 4)
			buffer.copy(nb, 0, data[c], 0, total * 4)
			data[c] = nb
		end
	end
	return { sampleRate = FS, channels = outCh, length = total, data = data }
end

-- the dOps box of an MP4 "Opus" sample entry (payload bytes) -> { channels, preSkip, gainDb, mapping, streams }
function Opus.readDops(b, p, q)
	if q - p < 11 then
		error("Opus: the dOps box is too short", 0)
	end
	local gain = buffer.readu8(b, p + 8) * 256 + buffer.readu8(b, p + 9)
	if gain >= 32768 then
		gain -= 65536
	end
	return {
		channels = buffer.readu8(b, p + 1),
		preSkip = buffer.readu8(b, p + 2) * 256 + buffer.readu8(b, p + 3),
		gainDb = gain / 256,
		mapping = buffer.readu8(b, p + 10),
		streams = if buffer.readu8(b, p + 10) ~= 0 and q - p >= 12 then buffer.readu8(b, p + 11) else 1,
	}
end

function Opus.isOgg(bytes)
	local b = type(bytes) == "string" and buffer.fromstring(bytes) or bytes
	return buffer.len(b) >= 36 and buffer.readstring(b, 0, 4) == "OggS" and buffer.readstring(b, 28, 8) == "OpusHead"
end

-- an Ogg Opus file: the first logical stream's packets (pages joined by lacing), OpusHead, the audio
function Opus.decodeOgg(bytes, options)
	local b = type(bytes) == "string" and buffer.fromstring(bytes) or bytes
	local n = buffer.len(b)
	local pos = 0
	local packets = {}
	local pending -- { parts } of a packet continued over pages
	local serial
	while pos + 27 <= n do
		if buffer.readstring(b, pos, 4) ~= "OggS" then
			error("Opus: not an Ogg page at " .. pos, 0)
		end
		local pageSerial = buffer.readu32(b, pos + 14)
		local nseg = buffer.readu8(b, pos + 26)
		local p = pos + 27 + nseg
		serial = serial or pageSerial
		for s = 0, nseg - 1 do
			local L = buffer.readu8(b, pos + 27 + s)
			if pageSerial == serial then
				pending = pending or {}
				table.insert(pending, { p, L })
				if L < 255 then
					-- join the parts into one packet
					if #pending == 1 then
						table.insert(packets, { b, pending[1][1], pending[1][2] })
					else
						local total = 0
						for _, part in ipairs(pending) do
							total += part[2]
						end
						local pk = buffer.create(total)
						local o = 0
						for _, part in ipairs(pending) do
							buffer.copy(pk, o, b, part[1], part[2])
							o += part[2]
						end
						table.insert(packets, { pk, 0, total })
					end
					pending = nil
				end
			end
			p += L
		end
		pos = p
	end
	local head = packets[1]
	if not head or buffer.readstring(head[1], head[2], 8) ~= "OpusHead" then
		error("Opus: no OpusHead", 0)
	end
	local channels = buffer.readu8(head[1], head[2] + 9)
	local preSkip = buffer.readu16(head[1], head[2] + 10)
	local gainDb = buffer.readi16(head[1], head[2] + 16) / 256
	local mapping = buffer.readu8(head[1], head[2] + 18)
	if mapping ~= 0 and (channels > 2 or buffer.readu8(head[1], head[2] + 19) > 1) then
		error("Opus: surround (multistream) audio isn't supported; mono and stereo are", 0)
	end
	local audio = table.move(packets, 3, #packets, 1, {})
	return Opus.decodePackets(audio, channels, preSkip, options, gainDb)
end

return Opus
