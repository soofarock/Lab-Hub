-- Started by FrameLab:init() on the server: the data manager's server side (admins only).
-- In-game imports live in the server's memory (Runtime/Server/Media) and are gone when it closes. The library keeps a
-- small record of each in a DataStore instead of the data itself: where it came from (the URL), its kind, quality,
-- size, length, who imported it, and a thumbnail that fits 64 x 64. A record whose data isn't in memory can be
-- imported again from its URL with one click (Load).
--
-- Requests (FrameLab.Net, remotes.Media): libList, libThumb(id), libDelete(id), libLoad(id), libStats,
-- libSetStore(on)
-- The DataStore is OFF by default (Config.LibraryDataStore = false): records live only in this server's memory. An
-- admin turns it on in the data manager (the "DataStore" switch, for this server) or sets the attribute to true.
-- Config.LibraryStore: the DataStore's name
return function(FrameLab)
	local Players = game:GetService("Players")
	local HttpService = game:GetService("HttpService")
	local EncodingService = game:GetService("EncodingService")
	local root = script:FindFirstAncestor("FrameLab")
	local Config = require(game:GetService("ReplicatedStorage"):WaitForChild("LabHub"):WaitForChild("Config"))
	local Stream = require(root.Video.Stream)
	local ImportJob = require(root.Tools.ImportJob)

	-- the media runtime makes FrameLab.Server
	local t0 = os.clock()
	while not FrameLab.Server and os.clock() - t0 < 30 do
		task.wait(0.1)
	end
	local server = FrameLab.Server
	if not server then
		warn("[FrameLab] library: the media runtime didn't start")
		return
	end
	local h, session, isAdmin = server.handlers, server.session, server.isAdmin

	-- the DataStores, or nil: switched off (the default), or not available (no API access). Records are kept one
	-- per key (store: "rec/<id>", "thumb/<id>"), and an OrderedDataStore holds id -> import time, which lists them
	-- newest first a page at a time (no single key that grows with every import)
	local store, ordered, storeError
	local function openStore()
		store, ordered, storeError = nil, nil, nil
		local name = Config.LibraryStore
		if type(name) ~= "string" or name == "" then
			name = "FrameLabLibrary_v1"
		end
		local ok, err = pcall(function()
			local DSS = game:GetService("DataStoreService")
			store = DSS:GetDataStore(name)
			ordered = DSS:GetOrderedDataStore(name .. "_order")
		end)
		if not ok then
			store, ordered, storeError = nil, nil, tostring(err)
		end
	end
	if Config.LibraryDataStore == true then
		openStore()
	end

	-- records: id -> { id, kind, name, url, quality, seconds, width, height, bytes, by, byName, at, tw, th }
	local records = {}
	local loadedIndex = false
	-- the newest Config.LibraryListSize (50) records, read once per server (each record is one GetAsync)
	local reading = false
	local function readIndex()
		if loadedIndex or not store or reading then
			return
		end
		reading = true
		local ok, err = pcall(function()
			local want = Config.LibraryListSize or 50
			local pages = ordered:GetSortedAsync(false, math.min(want, 100))
			local ids = {}
			while true do
				for _, e in ipairs(pages:GetCurrentPage()) do
					table.insert(ids, e.key)
				end
				if #ids >= want or pages.IsFinished then
					break
				end
				pages:AdvanceToNextPageAsync()
			end
			for i = 1, math.min(#ids, want) do
				local id = ids[i]
				if not records[id] then
					local r = store:GetAsync("rec/" .. id)
					if type(r) == "table" and type(r.url) == "string" then
						records[id] = r
					end
				end
			end
		end)
		reading = false
		if ok then
			loadedIndex = true
		else
			storeError = tostring(err)
		end
	end
	-- keep one record (and its place in the order)
	local function writeIndex(id)
		local r = records[id]
		if not store or not r then
			return
		end
		local ok, err = pcall(function()
			store:SetAsync("rec/" .. id, r)
			ordered:SetAsync(id, math.floor(r.at or os.time()))
		end)
		if not ok then
			storeError = tostring(err)
			warn("[FrameLab] library: couldn't save a record: " .. tostring(err))
		end
	end
	local function deleteRecord(id)
		records[id] = nil
		if store then
			pcall(function()
				ordered:RemoveAsync(id)
				store:RemoveAsync("rec/" .. id)
				store:RemoveAsync("thumb/" .. id)
			end)
		end
	end
	task.spawn(readIndex) -- (nothing while the DataStore is off)

	-- a thumbnail: the picture fitted into 64 x 64, RGB, zstd, base64 (a few KB)
	local function thumbOf(image)
		local small = FrameLab.Resize.fit(image, 64)
		local w, hgt = small.width, small.height
		local rgb = buffer.create(w * hgt * 3)
		for i = 0, w * hgt - 1 do
			buffer.writeu8(rgb, i * 3, buffer.readu8(small.data, i * 4))
			buffer.writeu8(rgb, i * 3 + 1, buffer.readu8(small.data, i * 4 + 1))
			buffer.writeu8(rgb, i * 3 + 2, buffer.readu8(small.data, i * 4 + 2))
		end
		local z = EncodingService:CompressBuffer(rgb, Enum.CompressionAlgorithm.Zstd, 9)
		return buffer.tostring(EncodingService:Base64Encode(z)), w, hgt
	end

	-- a picture of an imported video: the frame a tenth of the way in
	local function videoFrame(bytes)
		local reader = Stream.reader(bytes, { Decompress = function(b)
			return EncodingService:DecompressBuffer(b, Enum.CompressionAlgorithm.Zstd)
		end })
		local target = math.floor(reader.frameCount * 0.1)
		if target > 0 then
			reader:seek(target)
		else
			reader:advance()
		end
		if reader.render then
			reader.render()
		end
		local W, H, pw = reader.width, reader.height, reader.pw
		local data = buffer.create(W * H * 4)
		for y = 0, H - 1 do
			buffer.copy(data, y * W * 4, reader.rgba, y * pw * 4, W * 4)
		end
		return { width = W, height = H, data = data }
	end

	-- a picture of a stream (Tools.Live): a second into its first part (downloaded when it started)
	local function streamFrame(live)
		local bytes, offset = live.rawChunk(1)
		if not bytes then
			error("its first part isn't here", 0)
		end
		local k0 = live.raw[1].k0
		local k1 = live.raw[2] and live.raw[2].k0 or live.frames
		local s = math.min(1, 160 / math.max(live.width, live.height))
		local tw, th = math.max(1, math.floor(live.width * s)), math.max(1, math.floor(live.height * s))
		local got
		pcall(ImportJob.tsFrames, bytes, k0, k1, offset, live.fps, { { w = tw, h = th } }, function(_, imgs)
			got = imgs[1]
			error("enough", 0)
		end, nil, math.min(k1 - 1, k0 + live.fps))
		if not got then
			error("no picture in its first part", 0)
		end
		return got
	end

	local thumbs = {} -- id -> { data, w, h } (this server's copy)

	-- AudioLab imports (sounds: a clip under AudioLab's Data/Clips; music: a MIDI (and SoundFont) under Data/Files)
	local function audioImporter()
		local AL = game:GetService("ReplicatedStorage"):WaitForChild("LabHub"):FindFirstChild("AudioLab")
		return AL and AL:FindFirstChild("Tools") and AL.Tools:FindFirstChild("Importer") and require(AL.Tools.Importer)
	end
	local function isAudio(r)
		return r.kind == "sound" or r.kind == "music"
	end
	local function audioLoaded(r)
		local ok, yes = pcall(function()
			local I = audioImporter()
			if not I then
				return false
			end
			if r.kind == "sound" then
				return I.hasClip(r.path)
			end
			return I.has(r.path .. "/" .. r.name .. ".mid")
		end)
		return ok and yes == true
	end
	-- remove an AudioLab import's stored data (the node at path under root)
	local function dropPath(rootInst, path)
		local node = rootInst
		for seg in string.gmatch(path, "[^/]+") do
			node = node and node:FindFirstChild(seg)
		end
		if node and node ~= rootInst then
			node:Destroy()
		end
	end

	-- the session entry of a record (or nil: not in memory)
	local function loadedName(r)
		if isAudio(r) then
			return audioLoaded(r) and r.name or nil
		end
		local kind = r.kind == "image" and "Images" or "Videos"
		if r.name and session[kind][r.name] and session[kind][r.name].attrs.Url == r.url then
			return r.name
		end
		for name, e in pairs(session[kind]) do
			if e.attrs.Url == r.url and (e.attrs.Quality == r.quality or r.kind == "image") then
				return name
			end
		end
		return nil
	end

	-- after each import (Media calls it): a record for it, with its thumbnail
	server.onImported = function(result, url, quality, player)
		local kind = result.kind == "image" and "image" or "video"
		local e = session[kind == "image" and "Images" or "Videos"][result.name]
		if not e then
			return
		end
		readIndex()
		local id
		for rid, r in pairs(records) do
			if r.url == url and r.kind == kind and (kind == "image" or r.quality == quality) then
				id = rid
			end
		end
		id = id or HttpService:GenerateGUID(false)
		local r = {
			id = id, kind = kind, name = result.name, url = url, quality = kind == "video" and quality or nil,
			seconds = result.seconds, width = result.width, height = result.height, bytes = result.bytes,
			by = player and player.UserId or 0, byName = player and player.Name or "server", at = os.time(),
			stream = result.stream == true or nil,
		}
		local function makeThumb()
			local ok, err = pcall(function()
				local img = kind == "image" and FrameLab.unpackImage(e.bytes) or (e.live and streamFrame(e.live)) or videoFrame(e.bytes)
				local data, w, hgt = thumbOf(img)
				thumbs[id] = { data = data, w = w, h = hgt }
				r.tw, r.th = w, hgt
				if store then
					store:SetAsync("thumb/" .. id, data)
				end
			end)
			if not ok and Config.Debug then
				warn("[FrameLab] library: no thumbnail for " .. tostring(result.name) .. ": " .. tostring(err))
			end
		end
		records[id] = r
		if e.live then
			-- (a stream's picture is decoded after it has started playing, not before)
			task.spawn(function()
				makeThumb()
				if r.tw then
					writeIndex(id)
				end
			end)
		else
			makeThumb()
		end
		writeIndex(id)
	end

	-- after each AudioLab import (AudioLab's import server calls it): a record, no thumbnail
	server.onAudioImported = function(info)
		readIndex()
		local id
		for rid, r in pairs(records) do
			if r.kind == info.kind and r.path == info.path then
				id = rid
			end
		end
		id = id or HttpService:GenerateGUID(false)
		records[id] = {
			id = id, kind = info.kind, name = info.name, path = info.path, url = info.url, soundFontUrl = info.soundFontUrl,
			seconds = info.seconds, bytes = info.bytes, detail = info.detail,
			by = info.player and info.player.UserId or 0, byName = info.player and info.player.Name or "server", at = os.time(),
		}
		writeIndex(id)
	end

	local function sizeOf(e)
		if e.live and e.live.held then
			return e.live.held() -- (a stream: the parts it holds right now)
		end
		return typeof(e.bytes) == "buffer" and buffer.len(e.bytes) or 0
	end

	-- the DataStore switch (this server; the default comes from Config.LibraryDataStore)
	h.libSetStore = function(player, on)
		if not isAdmin(player) then
			return nil
		end
		if on == true then
			if not store then
				openStore()
				if store then
					-- this server's records join the kept ones
					local mine = records
					records = {}
					loadedIndex = false
					readIndex()
					for id, r in pairs(mine) do
						records[id] = r
						local t = thumbs[id]
						if t then
							pcall(store.SetAsync, store, "thumb/" .. id, t.data)
						end
						writeIndex(id)
					end
				end
			end
		else
			store, storeError = nil, nil
			-- (kept records that aren't in memory leave the list; this server's own stay)
			for id, r in pairs(records) do
				if not loadedName(r) then
					records[id] = nil
				end
			end
			loadedIndex = false
		end
		return { on = store ~= nil, storeError = storeError }
	end

	h.libStats = function(player)
		if not isAdmin(player) then
			return nil
		end
		local n, total = 0, 0
		for _, kind in ipairs({ "Videos", "Images", "Sounds" }) do
			for _, e in pairs(session[kind]) do
				n += 1
				total += sizeOf(e)
			end
		end
		return { entries = n, bytes = total, records = store ~= nil, storeError = storeError }
	end

	-- everything: this server's imports (loaded) and the kept records (loaded or not)
	h.libList = function(player)
		if not isAdmin(player) then
			return nil
		end
		readIndex()
		local out, seen = {}, {}
		for id, r in pairs(records) do
			local name = loadedName(r)
			local e = name and session[r.kind == "image" and "Images" or "Videos"][name]
			local soundBytes = 0
			if e and e.attrs.Audio then
				local s = session.Sounds[string.sub(e.attrs.Audio, 6)]
				soundBytes = s and sizeOf(s) or 0
			end
			if name then
				seen[name] = true
			end
			table.insert(out, {
				id = id, kind = r.kind, name = name or r.name, url = r.url, quality = r.quality, seconds = r.seconds,
				width = r.width, height = r.height, by = r.byName, at = r.at, loaded = name ~= nil,
				bytes = e and (sizeOf(e) + soundBytes) or r.bytes, kept = store ~= nil, thumb = r.tw ~= nil, detail = r.detail,
				soundFontUrl = r.soundFontUrl, stream = r.stream == true or (e ~= nil and e.live ~= nil),
			})
		end
		for kind, k in pairs({ Videos = "video", Images = "image" }) do
			for name, e in pairs(session[kind]) do
				if not seen[name] then
					local a = e.attrs
					table.insert(out, {
						id = "session:" .. kind .. ":" .. name, kind = k, name = name, url = a.Url, quality = a.Quality,
						seconds = a.Seconds, width = a.Width, height = a.Height, loaded = true, bytes = sizeOf(e), kept = false,
						stream = e.live ~= nil,
					})
				end
			end
		end
		table.sort(out, function(a, b)
			return (a.at or math.huge) > (b.at or math.huge)
		end)
		return out
	end

	h.libThumb = function(player, id)
		if not isAdmin(player) or type(id) ~= "string" then
			return nil
		end
		local t = thumbs[id]
		if not t and store and records[id] then
			local ok, v = pcall(store.GetAsync, store, "thumb/" .. id)
			if ok and type(v) == "string" then
				t = { data = v, w = records[id].tw, h = records[id].th }
				thumbs[id] = t
			end
		end
		if not t then
			return nil
		end
		local ok, rgb = pcall(function()
			return EncodingService:DecompressBuffer(EncodingService:Base64Decode(buffer.fromstring(t.data)), Enum.CompressionAlgorithm.Zstd)
		end)
		return ok and { w = t.w, h = t.h, rgb = rgb } or nil
	end

	-- remove: from this server's memory (picture / video and its sound) and from the records
	h.libDelete = function(player, id)
		if not isAdmin(player) or type(id) ~= "string" then
			return { error = "only admins" }
		end
		local kind, name
		local sk, sn = string.match(id, "^session:(%a+):(.+)$")
		if sk then
			kind, name = sk, sn
		else
			readIndex()
			local r = records[id]
			if r and isAudio(r) then
				-- an AudioLab import: its stored clip / MIDI and SoundFont go too
				pcall(function()
					local I = audioImporter()
					if I then
						if r.kind == "sound" then
							dropPath(I.clipsRoot(), r.path)
						else
							dropPath(I.filesRoot(), r.path)
						end
					end
				end)
				deleteRecord(id)
				return { ok = true }
			end
			if r then
				kind = r.kind == "image" and "Images" or "Videos"
				name = loadedName(r)
				thumbs[id] = nil
				deleteRecord(id)
			end
		end
		if kind and name and session[kind] and session[kind][name] then
			local e = session[kind][name]
			if e.attrs.Audio then
				session.Sounds[string.sub(e.attrs.Audio, 6)] = nil
			end
			session[kind][name] = nil
		end
		return { ok = true }
	end

	-- load a kept record that isn't in memory: import it again from its URL
	h.libLoad = function(player, id)
		if not isAdmin(player) or type(id) ~= "string" then
			return { error = "only admins" }
		end
		readIndex()
		local r = records[id]
		if not r then
			return { error = "no such record" }
		end
		if loadedName(r) then
			return { ok = true, name = loadedName(r) }
		end
		if isAudio(r) then
			return { error = "import it again from the music player's Import (Studio): its URL is under URL" }
		end
		return h.importUrl(player, r.kind, r.url, r.quality, r.stream == true)
	end

	Players.PlayerRemoving:Connect(function() end)
end
