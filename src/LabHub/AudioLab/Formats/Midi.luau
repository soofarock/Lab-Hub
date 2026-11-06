--!optimize 2
-- Standard MIDI File (SMF) parser: formats 0, 1 and 2, running status, meta and sysex events,
-- tempo map (ticks -> seconds, PPQ or SMPTE timing) and note pairing with channel state.
--
-- Result:
--   format, division, ticksPerQuarter (nil for SMPTE), trackCount
--   tracks  = { { name = string?, events = {...} } }
--   events  = merged events sorted by (tick, track, order), each:
--             { tick, time, track, order, kind, channel?, a?, b?, metaType?, data? }
--             kinds: noteOn noteOff polyPressure cc program channelPressure pitchBend sysex meta
--   notes   = { { channel, key, velocity, program, bank, track, startTick, endTick,
--                 start, duration, volume, expression, pan } }  (seconds; volume etc. 0..127 at note start)
--   tempoMap, duration (seconds), endTick
--   Midi.secondsAtTick(result, tick)

local AudioLab = script:FindFirstAncestor("AudioLab")
local ByteReader = require(AudioLab.Util.ByteReader)

local Midi = {}

local DEFAULT_MAX_EVENTS = 500000
local DATA_BYTES = { [0x8] = 2, [0x9] = 2, [0xA] = 2, [0xB] = 2, [0xC] = 1, [0xD] = 1, [0xE] = 2 }
local KIND = {
	[0x8] = "noteOff", [0x9] = "noteOn", [0xA] = "polyPressure", [0xB] = "cc",
	[0xC] = "program", [0xD] = "channelPressure", [0xE] = "pitchBend",
}

local function parseTrack(r, trackIndex, events, budget)
	local tick = 0
	local status = nil
	local order = 0
	local name = nil
	local list = {}
	while r:remaining() > 0 do
		tick += r:varlen()
		local b = r:u8()
		local ev
		if b == 0xFF then
			local metaType = r:u8()
			local len = r:varlen()
			local data = r:str(math.min(len, r:remaining()))
			ev = { kind = "meta", metaType = metaType, data = data }
			if metaType == 0x03 and not name then
				name = data
			end
			status = nil -- meta/sysex cancel running status
			if metaType == 0x2F then
				ev.tick, ev.track, ev.order = tick, trackIndex, order
				table.insert(list, ev)
				break -- end of track
			end
		elseif b == 0xF0 or b == 0xF7 then
			local len = r:varlen()
			ev = { kind = "sysex", data = r:str(math.min(len, r:remaining())) }
			status = nil
		else
			local first
			if b >= 0x80 then
				status = b
				first = nil
			else
				if not status then
					error(("data byte 0x%02X without running status in track %d"):format(b, trackIndex))
				end
				first = b
			end
			local hi = bit32.rshift(status, 4)
			local count = DATA_BYTES[hi]
			if not count then
				error(("unsupported status byte 0x%02X in track %d"):format(status, trackIndex))
			end
			local a = first or r:u8()
			local c = count == 2 and r:u8() or nil
			ev = { kind = KIND[hi], channel = bit32.band(status, 0x0F), a = a, b = c }
			if ev.kind == "noteOn" and c == 0 then
				ev.kind = "noteOff"
			elseif ev.kind == "pitchBend" then
				ev.a = a + c * 128 - 8192 -- signed -8192..8191
				ev.b = nil
			end
		end
		ev.tick, ev.track, ev.order = tick, trackIndex, order
		order += 1
		table.insert(list, ev)
		table.insert(events, ev)
		budget.count += 1
		if budget.count > budget.max then
			error("MIDI exceeds the event safety limit")
		end
	end
	return { name = name, events = list, endTick = tick }
end

local function buildTempoMap(result)
	local points = { { tick = 0, usPerQuarter = 500000, seconds = 0 } }
	if not result.ticksPerQuarter then
		return points
	end
	local tempos = {}
	for _, ev in ipairs(result.events) do
		if ev.kind == "meta" and ev.metaType == 0x51 and #ev.data >= 3 then
			local d = ev.data
			local us = string.byte(d, 1) * 65536 + string.byte(d, 2) * 256 + string.byte(d, 3)
			if us > 0 then
				table.insert(tempos, { tick = ev.tick, us = us })
			end
		end
	end
	local tpq = result.ticksPerQuarter
	for _, t in ipairs(tempos) do
		local last = points[#points]
		local seconds = last.seconds + (t.tick - last.tick) * last.usPerQuarter / (tpq * 1e6)
		if t.tick == last.tick then
			last.usPerQuarter = t.us -- later tempo at the same tick wins
		else
			table.insert(points, { tick = t.tick, usPerQuarter = t.us, seconds = seconds })
		end
	end
	return points
end

function Midi.secondsAtTick(result, tick)
	if not result.ticksPerQuarter then
		return tick / result.ticksPerSecond
	end
	local points = result.tempoMap
	-- binary search: last point with point.tick <= tick
	local lo, hi = 1, #points
	while lo < hi do
		local mid = (lo + hi + 1) // 2
		if points[mid].tick <= tick then
			lo = mid
		else
			hi = mid - 1
		end
	end
	local p = points[lo]
	return p.seconds + (tick - p.tick) * p.usPerQuarter / (result.ticksPerQuarter * 1e6)
end

local function pairNotes(result)
	local notes = {}
	local open = {} -- [channel*128+key] = FIFO of open notes
	local state = {}
	for c = 0, 15 do
		state[c] = { program = 0, bankMsb = 0, bankLsb = 0, volume = 100, expression = 127, pan = 64 }
	end
	for _, ev in ipairs(result.events) do
		local ch = ev.channel
		if ev.kind == "program" then
			state[ch].program = ev.a
		elseif ev.kind == "cc" then
			local s = state[ch]
			if ev.a == 0 then
				s.bankMsb = ev.b
			elseif ev.a == 32 then
				s.bankLsb = ev.b
			elseif ev.a == 7 then
				s.volume = ev.b
			elseif ev.a == 10 then
				s.pan = ev.b
			elseif ev.a == 11 then
				s.expression = ev.b
			end
		elseif ev.kind == "noteOn" then
			local s = state[ch]
			local note = {
				channel = ch, key = ev.a, velocity = ev.b, program = s.program,
				bank = s.bankMsb * 128 + s.bankLsb, track = ev.track, startTick = ev.tick,
				volume = s.volume, expression = s.expression, pan = s.pan,
			}
			local k = ch * 128 + ev.a
			open[k] = open[k] or {}
			table.insert(open[k], note)
			table.insert(notes, note)
		elseif ev.kind == "noteOff" then
			local q = open[ch * 128 + ev.a]
			if q and #q > 0 then
				local note = table.remove(q, 1)
				note.endTick = ev.tick
			end
		end
	end
	for _, note in ipairs(notes) do
		note.endTick = note.endTick or result.endTick -- unterminated notes run to the end
		note.start = Midi.secondsAtTick(result, note.startTick)
		note.duration = Midi.secondsAtTick(result, note.endTick) - note.start
	end
	return notes
end

-- bytes: buffer or string. options.maxEvents (default 500000).
function Midi.decode(bytes, options)
	options = options or {}
	local r = ByteReader.new(bytes)
	-- Some files carry a RIFF RMID wrapper.
	if r:size() >= 20 and r:str(4) == "RIFF" then
		r:skip(4)
		local form = r:str(4)
		if form == "WAVE" then
			error("this is a WAV file, not MIDI: play it with AudioLab.Player (or AudioLab.play(path))", 2)
		elseif form == "sfbk" then
			error("this is a SoundFont, not MIDI: pass it as MidiSynth.new({ SoundFont = Sf2.decode(bytes) })", 2)
		elseif form ~= "RMID" then
			error("RIFF file is not RMID (form " .. form .. ")", 2)
		end
		while r:remaining() >= 8 do
			local id = r:str(4)
			local size = r:u32()
			if id == "data" then
				r = r:sub(math.min(size, r:remaining()))
				break
			end
			r:skip(math.min(size + size % 2, r:remaining()))
		end
	else
		r:seek(0)
	end

	if r:str(4) ~= "MThd" then
		error("not a MIDI file (missing MThd)")
	end
	local headerLen = r:u32be()
	if headerLen < 6 then
		error("MThd chunk too short")
	end
	local hdr = r:sub(headerLen)
	local result = {}
	result.format = hdr:u16be()
	result.trackCount = hdr:u16be()
	local division = hdr:u16be()
	result.division = division
	if division >= 0x8000 then
		local fps = 256 - bit32.rshift(division, 8) -- two's complement negative SMPTE rate
		local tpf = bit32.band(division, 0xFF)
		if fps == 29 then
			fps = 29.97
		end
		result.ticksPerSecond = fps * tpf
	else
		if division == 0 then
			error("MIDI division is zero")
		end
		result.ticksPerQuarter = division
	end

	local budget = { count = 0, max = options.maxEvents or DEFAULT_MAX_EVENTS }
	local events = {}
	result.tracks = {}
	local endTick = 0
	local trackIndex = 0
	while r:remaining() >= 8 do
		local id = r:str(4)
		local len = math.min(r:u32be(), r:remaining())
		local body = r:sub(len)
		if id == "MTrk" then
			trackIndex += 1
			local track = parseTrack(body, trackIndex, events, budget)
			table.insert(result.tracks, track)
			if result.format == 2 then
				endTick = math.max(endTick, track.endTick)
			else
				endTick = math.max(endTick, track.endTick)
			end
		end -- unknown chunks are skipped
	end
	if trackIndex == 0 then
		error("MIDI file has no MTrk chunks")
	end

	table.sort(events, function(x, y)
		if x.tick ~= y.tick then
			return x.tick < y.tick
		end
		if x.track ~= y.track then
			return x.track < y.track
		end
		return x.order < y.order
	end)
	result.events = events
	result.endTick = endTick
	result.tempoMap = buildTempoMap(result)
	for _, ev in ipairs(events) do
		ev.time = Midi.secondsAtTick(result, ev.tick)
	end
	result.notes = pairNotes(result)
	result.duration = Midi.secondsAtTick(result, endTick)
	return result
end

function Midi.noteToFrequency(key)
	return 440 * 2 ^ ((key - 69) / 12)
end

return Midi
