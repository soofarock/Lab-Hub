-- FrameLab network: what the server sends to the client that asks for it, so big data doesn't replicate to everyone.
-- The server side (Runtime/Server/Media) makes the remotes in FrameLab.Remotes:
--   Media (RemoteFunction)  Media:InvokeServer(action, ...)   lists, video bytes in ranges, pictures, admin check
--   TV, Spray (RemoteEvent) the tools' requests
--   Cache (RemoteEvent)     server -> client: "clear" (an admin cleared this client's video memory)
--
-- Client use:
--   Net.videos() -> { { name, Width, Height, Seconds, Fps, Bytes, Server }, ... }    (cached a few seconds)
--   Net.images() -> { { name, Width, Height }, ... }
--   local s = Net.openVideo(name, { Lines, Rendition })   streams a video's bytes in the background, the part being
--       watched first. A video kept at several sizes streams one of them: the largest at most Lines tall (default
--       Video.Stream.deviceLines()), or number Rendition; s.renditions ({ width, height, bytesPerSecond }) and
--       s.rendition say which. options.Direct: a stream (s.direct) comes unconverted (its HLS segments, rendition 0),
--       for the client to decode itself (Video.DirectReader); s.chunkData then also gives each segment's time offset.
--       options.Blocks: a stream (s.blocks) comes as the server's block picture instead (Video.BlockStream: its
--       pieces are the chunks), for a client that doesn't decode it.
--       A stream (an HLS address, Tools.Live: s.live) is converted by the server as it plays;
--       its chunks are asked for one at a time (s.chunkData then also gives each chunk's coder stream sizes)
--       s.bytes (an FLV2 video: its header and chunk directory; an older one: all of it), s.chunkData(chunkIndex) ->
--       buffer, offset (nil until it arrives), s.info, s.ready(chunkIndex), s.complete, s.failed
--       s.follow(function() -> seconds)   which part to fetch first (the playing position)
--       s.waitFor(seconds, timeout) -> true when the chunk for that time is there      s.close()
--       The chunks behind the playhead are dropped as it moves on: all streams together stay under Config.VideoCacheMB.
--       A video that fits in its share is kept whole (jumping about in it never waits), and a closed one keeps its
--       chunks while there is room, so a screen switching back to it starts at once.
--   Net.cacheUsage() -> { video = bytes held, limit, streams, pictures (sprayed / shown pictures held), sounds
--       (AudioLab clips and files held), memory, luau (the client's whole memory and its Luau heap, MB) }
--   Net.buffered(name) -> { { from, to } ... }: the parts of that video held here, as fractions of its length (in order;
--       the seek bar's lighter line)
--   Net.clearCache()   drops the video chunks (except what each screen shows) and the pictures held
--   Net.image(key) -> image table ("lib:<name>" for a library picture, "url:<n>" for one an admin loaded from a URL)
--   Net.isAdmin() -> bool
--   Net.clip(path) -> the bytes of an in-game import's sound (AudioLab clip "video/imported/<name>"), or nil (yields;
--       the clips live in the server's memory, so only a client that plays one downloads it)

local Net = {}
local root = script:FindFirstAncestor("FrameLab")
local RunService = game:GetService("RunService")
local EncodingService = game:GetService("EncodingService")

Net.RANGE = 60 * 1024 -- bytes per request

function Net.remotes(create)
	local folder = root:FindFirstChild("Remotes")
	if not folder then
		if not create then
			folder = root:WaitForChild("Remotes")
		else
			folder = Instance.new("Folder")
			folder.Name = "Remotes"
			local media = Instance.new("RemoteFunction")
			media.Name = "Media"
			media.Parent = folder
			for _, n in ipairs({ "TV", "Spray", "Cache" }) do
				local e = Instance.new("RemoteEvent")
				e.Name = n
				e.Parent = folder
			end
			folder.Parent = root
		end
	end
	return folder
end

local function invoke(action, ...)
	return Net.remotes(false):WaitForChild("Media"):InvokeServer(action, ...)
end
Net.invoke = invoke

local listCache = {}
local function cachedList(action)
	local c = listCache[action]
	if c and os.clock() - c.t < 5 then
		return c.v
	end
	local ok, v = pcall(invoke, action)
	v = ok and v or {}
	listCache[action] = { t = os.clock(), v = v }
	return v
end
function Net.videos()
	return cachedList("videos")
end
function Net.images()
	return cachedList("images")
end
function Net.forget()
	listCache = {}
end

local adminAnswer
-- asks again (a few times) while the server gives no answer: a request can go unanswered while the server is still
-- starting, or be dropped when a player sends many at once
function Net.isAdmin()
	if adminAnswer == nil then
		for attempt = 1, 6 do
			local ok, v = pcall(invoke, "isAdmin")
			if ok and type(v) == "boolean" then
				adminAnswer = v
				break
			end
			task.wait(attempt)
		end
		adminAnswer = adminAnswer == true
	end
	return adminAnswer
end

-- the 1-based chunk byte ranges of an FLV2 video (from its header and directory)
local function flv2Chunks(head)
	local n = buffer.readu16(head, 16)
	local start = 24 + n * 16
	local list = {}
	for i = 1, n do
		local d = 24 + (i - 1) * 16
		local off = buffer.readu32(head, d)
		local size = buffer.readu32(head, d + 4) + buffer.readu32(head, d + 8)
		list[i] = { from = start + off, to = start + off + size, first = buffer.readu32(head, d + 12) }
	end
	return list
end

-- the video this client holds (every Net.openVideo stream): kept under Config.VideoCacheMB, shared by the screens
local openStreams = {}
local function cacheLimit()
	local Config = require(game:GetService("ReplicatedStorage"):WaitForChild("LabHub"):WaitForChild("Config"))
	return math.clamp(tonumber(Config.VideoCacheMB) or 6, 1, 64) * 1048576
end
-- one stream's share: the limit split between the open streams, except that a stream holding its whole video leaves
-- what it doesn't need to the others (a short video stays whole, so jumping about in it never waits)
local function perStream(self)
	local limit, n = cacheLimit(), 0
	for st in pairs(openStreams) do
		if st ~= self and st.complete then
			limit -= st.held()
		else
			n += 1
		end
	end
	return math.max(limit, 0) / math.max(n, 1)
end

-- videos a screen stopped playing (it switched to another one): their chunks stay while there is room, so switching
-- back starts at once. parked[key] = { loaded, sizes, held, t }; the oldest go first when an open stream needs room
local parked = {}
local function parkedBytes()
	local n = 0
	for _, p in pairs(parked) do
		n += p.held
	end
	return n
end
local function makeRoom(need)
	local open = 0
	for st in pairs(openStreams) do
		open += st.held()
	end
	while open + parkedBytes() + need > cacheLimit() do
		local oldest, ot
		for k, p in pairs(parked) do
			if not ot or p.t < ot then
				oldest, ot = k, p.t
			end
		end
		if not oldest then
			return
		end
		parked[oldest] = nil
	end
end

local imageCache = {}

function Net.buffered(name)
	for st in pairs(openStreams) do
		if st.name == name and not st.closed then
			return st.ranges()
		end
	end
	return {}
end

function Net.cacheUsage()
	local total, n = 0, 0
	for st in pairs(openStreams) do
		total += st.held()
		n += 1
	end
	local pictures = 0
	for _, img in pairs(imageCache) do
		if type(img) == "table" and typeof(img.data) == "buffer" then
			pictures += buffer.len(img.data)
		end
	end
	local sounds = 0
	pcall(function()
		local al = game:GetService("ReplicatedStorage"):WaitForChild("LabHub"):FindFirstChild("AudioLab")
		if al then
			local u = require(al.Tools.Assets).usage()
			sounds = u.files + u.clips
		end
	end)
	local Stats = game:GetService("Stats")
	local okM, memory = pcall(Stats.GetTotalMemoryUsageMb, Stats)
	local okL, luau = pcall(Stats.GetMemoryUsageMbForTag, Stats, Enum.DeveloperMemoryTag.LuaHeap)
	return { video = total + parkedBytes(), limit = cacheLimit(), streams = n, pictures = pictures, sounds = sounds,
		memory = okM and memory or 0, luau = okL and luau or 0 }
end

-- drops every chunk except the one each screen is showing; the rest stream in again as they are needed
function Net.clearCache()
	for st in pairs(openStreams) do
		st.trim(0, math.huge)
	end
	table.clear(imageCache)
	table.clear(parked)
end

function Net.openVideo(name, options)
	options = options or {}
	local s = { name = name, info = nil, bytes = nil, complete = false, failed = nil, closed = false }
	local base = 0 -- where the rendition being streamed starts in the video's entry
	local liveSizes = {} -- a stream made as it plays (Tools.Live): chunk index -> { sizeA, sizeB }
	local loaded = {} -- FLV2 chunk index -> its bytes
	local held, whole = 0, 0 -- bytes in `loaded`; bytes of an older stream, which is held whole
	local chunks
	local followFn
	openStreams[s] = true
	function s.ready(ci)
		if s.complete then
			return true
		end
		return loaded[ci] ~= nil
	end
	-- a chunk's bytes for the reader: buffer, offset (nil while it isn't here)
	function s.chunkData(ci)
		local c = loaded[ci]
		if c then
			local sz = liveSizes[ci]
			if sz then
				return c, 0, sz[1], sz[2], sz[3]
			end
			return c, 0
		end
		return nil
	end
	function s.held()
		return held + whole
	end
	-- the parts held, as fractions of the video's length: { { from, to } ... } in order, neighbours joined
	function s.ranges()
		if s.complete then
			return { { 0, 1 } }
		end
		local out = {}
		if not chunks then
			return out
		end
		local frames = math.max(1, buffer.readu32(s.bytes, 10))
		for i, c in ipairs(chunks) do
			if loaded[i] then
				local a = c.first / frames
				local b = (chunks[i + 1] and chunks[i + 1].first or frames) / frames
				local last = out[#out]
				if last and math.abs(last[2] - a) < 1e-9 then
					last[2] = b
				else
					table.insert(out, { a, b })
				end
			end
		end
		return out
	end
	function s.follow(fn)
		followFn = fn
	end
	function s.close()
		s.closed = true
		openStreams[s] = nil
		if s.key and held > 0 then
			-- (kept for a switch back, while there is room)
			parked[s.key] = { loaded = loaded, sizes = liveSizes, held = held, t = os.clock() }
			makeRoom(0)
		end
		loaded, liveSizes = {}, {}
		held, whole = 0, 0
	end
	-- the chunk being watched
	local function current()
		if not (followFn and chunks) then
			return 1
		end
		local frame = math.floor(math.max(0, followFn()) * buffer.readu8(s.bytes, 5))
		local want = 1
		for i, c in ipairs(chunks) do
			if c.first <= frame then
				want = i
			else
				break
			end
		end
		return want
	end
	-- drops the chunks furthest ahead of the one being watched (what has played wraps round to the far end, so it goes
	-- first) until `need` more bytes fit; keeps the chunks up to keepAhead past the current one
	function s.trim(keepAhead, need)
		if not chunks then
			return
		end
		local want, n = current(), #chunks
		local per = perStream(s)
		while held + need > per do
			local far, farK = nil, keepAhead
			for i in pairs(loaded) do
				local k = (i - want) % n
				if k > farK then
					far, farK = i, k
				end
			end
			if not far then
				return
			end
			held -= buffer.len(loaded[far])
			loaded[far] = nil
			s.complete = false
		end
	end
	-- bytes [from, to) of the video, in ranges; nil when it failed or was closed
	local function fetch(from, to)
		local data = buffer.create(to - from)
		local pos = from
		while pos < to do
			if s.closed then
				return nil
			end
			local len = math.min(Net.RANGE, to - pos)
			-- (nil: the server's request budget for this second is used up - a sound downloading alongside - so wait and
			-- ask again; a video failed on the first refusal)
			local ok, part
			for try = 1, 20 do
				ok, part = pcall(invoke, "videoRange", name, base + pos, len)
				if (ok and typeof(part) == "buffer") or s.closed then
					break
				end
				task.wait(0.25 * try)
			end
			if s.closed then
				return nil
			end
			if not ok or typeof(part) ~= "buffer" then
				s.failed = tostring(part)
				return nil
			end
			buffer.copy(data, pos - from, part, 0, buffer.len(part))
			pos += len
		end
		return data
	end
	task.spawn(function()
		local ok, head
		local lines = math.min(options.Lines or require(root.Video.Stream).deviceLines(), 10000)
		for try = 1, 10 do
			ok, head = pcall(invoke, "videoHead", name, lines, options.Rendition,
				(options.Blocks and not options.Direct) and "blocks" or options.Direct == true)
			if ok and type(head) == "table" then
				break
			end
			task.wait(0.25 * try)
		end
		if not ok or type(head) ~= "table" then
			s.failed = ok and "no such video" or tostring(head)
			return
		end
		base = tonumber(head.base) or 0
		s.renditions, s.rendition = head.renditions, head.rendition
		s.direct, s.source = head.direct == true, head.source
		s.blocks = head.blocks == true
		s.info = head.attrs
		local headLen = buffer.len(head.head)
		if buffer.readstring(head.head, 0, 4) ~= "FLV2" then
			-- older streams need all their bytes before they play
			s.bytes = buffer.create(head.size)
			whole = head.size
			buffer.copy(s.bytes, 0, head.head, 0, headLen)
			local rest = fetch(headLen, head.size)
			if rest then
				buffer.copy(s.bytes, headLen, rest, 0)
				s.complete = true
			end
			return
		end
		s.bytes = head.head -- the header and chunk directory; the chunks themselves stay in `loaded`
		chunks = flv2Chunks(head.head)
		s.chunks = chunks
		-- a stream (an HLS video the server converts as it is watched): each chunk is asked for, made if needed, then
		-- fetched in ranges; its size is known only then (an estimate from the data rate until it is here)
		local live = head.live == true
		s.live = live
		local liveRate = 60000
		if live and head.renditions and head.renditions[head.rendition] then
			liveRate = head.renditions[head.rendition].bytesPerSecond or liveRate
		end
		local fps = math.max(1, buffer.readu8(head.head, 5))
		local frames = buffer.readu32(head.head, 10)
		local function chunkSize(i)
			if not live then
				return chunks[i].to - chunks[i].from
			end
			local stop = chunks[i + 1] and chunks[i + 1].first or frames
			return math.floor(liveRate * (stop - chunks[i].first) / fps)
		end
		local function fetchLive(ci)
			local info
			for _ = 1, 600 do -- (the server makes or downloads it: a few seconds, longer while it is busy)
				local ok, v = pcall(invoke, "liveChunk", name, s.rendition, ci)
				if s.closed then
					return nil
				end
				if ok and type(v) == "table" then
					info = v
					break
				elseif ok and type(v) == "string" then
					s.failed = v
					return nil
				end
				task.wait(0.2)
			end
			if not info then
				s.failed = "the stream's server didn't make the part in time"
				return nil
			end
			local n = info.sizeA + info.sizeB
			local data = buffer.create(n)
			-- (three ranges at a time: a whole segment is many ranges, and each is a round trip to the server)
			local starts = {}
			for p = 0, n - 1, Net.RANGE do
				table.insert(starts, p)
			end
			local nextRange, lost, running = 1, false, 0
			local function fetcher()
				while nextRange <= #starts and not lost and not s.closed do
					local p = starts[nextRange]
					nextRange += 1
					local len = math.min(Net.RANGE, n - p)
					local part
					for try = 1, 20 do
						local ok, v = pcall(invoke, "liveRange", name, s.rendition, ci, p, len)
						if s.closed then
							break
						end
						if ok and typeof(v) == "buffer" then
							part = v
							break
						end
						task.wait(0.25 * try)
					end
					if not part then
						lost = true
						break
					end
					buffer.copy(data, p, part, 0, buffer.len(part))
				end
				running -= 1
			end
			for _ = 1, math.min(3, #starts) do
				running += 1
				task.spawn(fetcher)
			end
			while running > 0 do
				task.wait()
			end
			if s.closed then
				return nil
			end
			if lost then
				s.failed = "the stream's part didn't arrive"
				return nil
			end
			liveSizes[ci] = { info.sizeA, info.sizeB, info.offset }
			return data
		end
		-- the chunks kept from when this video last played here (at this size)
		s.key = name .. "#" .. tostring(head.rendition or 1)
		local p = parked[s.key]
		if p then
			parked[s.key] = nil
			loaded, liveSizes, held = p.loaded, p.sizes, p.held
			local count = 0
			for _ in pairs(loaded) do
				count += 1
			end
			s.complete = count == #chunks
		end
		-- the chunk being watched first, then the ones after it (wrapping), as far ahead as the cache allows: one at a
		-- time, except that the chunk being watched starts at once even while one further ahead is still coming (a jump
		-- doesn't wait for it)
		local fetching, nFetching, stopped = {}, 0, false
		local function start(pick, pickK)
			local size = chunkSize(pick)
			makeRoom(size)
			s.trim(pickK, size)
			fetching[pick] = true
			nFetching += 1
			task.spawn(function()
				local data
				if live then
					data = fetchLive(pick)
				else
					data = fetch(chunks[pick].from, chunks[pick].to)
				end
				fetching[pick] = nil
				nFetching -= 1
				if not data then
					stopped = true
					return
				end
				if s.closed then
					return
				end
				loaded[pick] = data
				held += buffer.len(data)
				local count = 0
				for _ in pairs(loaded) do
					count += 1
				end
				s.complete = count == #chunks
			end)
		end
		while not s.closed and not stopped do
			local want, n = current(), #chunks
			local per = perStream(s)
			local pick, pickK
			local ahead = 0
			for k = 0, n - 1 do
				local i = (want - 1 + k) % n + 1
				local size = chunkSize(i)
				if not loaded[i] and not fetching[i] then
					if k <= 1 or ahead + size <= per then -- (the current chunk and the next always load)
						pick, pickK = i, k
					end
					break
				end
				ahead += size
			end
			if pick and (nFetching == 0 or (pickK == 0 and nFetching < 2)) then
				start(pick, pickK)
			else
				task.wait(0.1)
			end
		end
	end)
	function s.waitFor(seconds, timeout)
		local t0 = os.clock()
		while os.clock() - t0 < (timeout or 15) do
			if s.failed then
				return false
			end
			if s.complete then
				return true
			end
			if chunks and s.info then
				local frame = math.floor(math.max(0, seconds) * buffer.readu8(s.bytes, 5))
				local ci = 1
				for i, c in ipairs(chunks) do
					if c.first <= frame then
						ci = i
					end
				end
				if loaded[ci] then
					return true
				end
			end
			task.wait(0.1)
		end
		return false
	end
	return s
end

function Net.clip(path)
	if type(path) ~= "string" or string.sub(path, 1, 15) ~= "video/imported/" then
		return nil
	end
	local ok, head = pcall(invoke, "clipHead", path)
	if not ok or type(head) ~= "table" or type(head.size) ~= "number" then
		return nil
	end
	local size = head.size
	local bytes = buffer.create(size)
	-- four ranges at a time, at most ~20 requests a second (the server allows 30 a second per player, and the video
	-- streams alongside with a few), so a sound arrives close behind its picture
	local nextPos, running, failed = 0, 0, false
	local lastAsk = 0
	local function worker()
		while not failed and nextPos < size do
			local pos = nextPos
			local len = math.min(Net.RANGE, size - pos)
			nextPos += len
			local part
			for _ = 1, 8 do -- (nil: over the request budget this second; try again)
				while os.clock() - lastAsk < 0.05 do
					task.wait()
				end
				lastAsk = os.clock()
				local okR, r = pcall(invoke, "clipRange", path, pos, len)
				if okR and typeof(r) == "buffer" and buffer.len(r) == len then
					part = r
					break
				end
				task.wait(0.5)
			end
			if not part then
				failed = true
				break
			end
			buffer.copy(bytes, pos, part, 0, len)
		end
		running -= 1
	end
	for _ = 1, 4 do
		running += 1
		task.spawn(worker)
	end
	while running > 0 do
		task.wait()
	end
	if failed then
		if require(game:GetService("ReplicatedStorage"):WaitForChild("LabHub"):WaitForChild("Config")).Debug then
			warn("[FrameLab] couldn't download the sound " .. path)
		end
		return nil
	end
	return bytes
end

function Net.image(key)
	local c = imageCache[key]
	if c then
		return c
	end
	local ok, bytes = pcall(invoke, "image", key)
	if not ok or typeof(bytes) ~= "buffer" then
		return nil
	end
	local FrameLab = require(root)
	local img = FrameLab.unpackImage(bytes)
	imageCache[key] = img
	return img
end

return Net
