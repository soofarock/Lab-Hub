-- Started by FrameLab:init() on the server: makes the FrameLab remotes and answers the clients'
-- requests for videos and pictures. Videos in ServerStorage.FrameLabData (the big ones) never replicate; a client gets
-- only the byte ranges it asks for, while it plays them. Other server runtimes add actions to FrameLab.Server.handlers.
return function(FrameLab)
	local Players = game:GetService("Players")
	local ServerStorage = game:GetService("ServerStorage")
	local root = script:FindFirstAncestor("FrameLab")
	local Net = require(root.Tools.Net)
	local Store = FrameLab.Store
	local Config = require(game:GetService("ReplicatedStorage"):WaitForChild("LabHub"):WaitForChild("Config"))
	local remotes = Net.remotes(true)

	local function serverRoot(kind)
		local data = ServerStorage:FindFirstChild("FrameLabData")
		return data and data:FindFirstChild(kind)
	end
	local function roots(kind) -- "Videos" / "Images": the replicated library, then the server-only one
		local list = { root.Data[kind] }
		local s = serverRoot(kind)
		if s then
			table.insert(list, s)
		end
		return list
	end
	-- in-game imports: kept in memory while the server runs ("imported/<name>"); Sounds: their AudioLab clips
	-- ("video/imported/<name>"), sent to a client only when it plays one (clipHead / clipRange)
	local session = { Images = {}, Videos = {}, Sounds = {} }
	local function sessionEntry(kind, name)
		local s = session[kind] and session[kind][name]
		if not s then
			return nil
		end
		return {
			Name = name,
			GetAttribute = function(_, k)
				return s.attrs[k]
			end,
			GetAttributes = function()
				return table.clone(s.attrs)
			end,
		}
	end
	local function find(kind, name)
		local se = sessionEntry(kind, name)
		if se then
			return "session", se
		end
		for _, r in ipairs(roots(kind)) do
			if Store.has(r, name) then
				return r, Store.entry(r, name)
			end
		end
		return nil
	end

	-- recently read entries (decoding a big entry's text is the slow part)
	local cache, order = {}, {}
	local function readEntry(kind, name)
		local key = kind .. "/" .. name
		local c = cache[key]
		if c then
			return c
		end
		local r = find(kind, name)
		if not r then
			return nil
		end
		if r == "session" then
			return session[kind][name].bytes
		end
		c = Store.read(r, name)
		cache[key] = c
		table.insert(order, key)
		if #order > (Config.CachedEntries or 6) then
			cache[table.remove(order, 1)] = nil
		end
		return c
	end

	local function isAdmin(player)
		if game.CreatorType == Enum.CreatorType.User and player.UserId == game.CreatorId then
			return true
		end
		if game.CreatorType == Enum.CreatorType.Group then
			local ok, rank = pcall(player.GetRankInGroup, player, game.CreatorId)
			if ok and rank >= 254 then
				return true
			end
		end
		return Config.listed(player, "Admins")
	end

	local server = { handlers = {}, isAdmin = isAdmin, readEntry = readEntry, find = find, remotes = remotes, urlImages = {}, session = session }
	require(root.Sync).extraEntry = function(name)
		return sessionEntry("Videos", name)
	end
	-- seconds a client needs to download an imported video's sound (~300 KB/s with FrameLab.Net.clip, plus a margin)
	require(root.Sync).soundLoadDelay = function(clip)
		local s = session.Sounds[clip]
		if not s then
			return 0
		end
		local size = typeof(s.bytes) == "buffer" and buffer.len(s.bytes) or #tostring(s.bytes)
		return math.clamp(size / 300000 + 0.7, 0.5, 6)
	end

	local function listOf(kind)
		local out, seen = {}, {}
		local names = {}
		for name in pairs(session[kind]) do
			table.insert(names, name)
		end
		table.sort(names)
		for _, name in ipairs(names) do
			seen[name] = true
			local a = session[kind][name].attrs
			table.insert(out, { name = name, Width = a.Width, Height = a.Height, Seconds = a.Seconds, Fps = a.Fps, Bytes = a.Bytes, Audio = a.Audio, Server = true, Imported = true })
		end
		for i, r in ipairs(roots(kind)) do
			for _, name in ipairs(Store.list(r)) do
				if not seen[name] then
					seen[name] = true
					local e = Store.entry(r, name)
					local a = e and e:GetAttributes() or {}
					table.insert(out, { name = name, Width = a.Width, Height = a.Height, Seconds = a.Seconds, Fps = a.Fps, Bytes = a.Bytes, Audio = a.Audio, Server = i > 1 })
				end
			end
		end
		return out
	end

	local h = server.handlers
	h.videos = function()
		return listOf("Videos")
	end
	h.images = function()
		return listOf("Images")
	end
	h.isAdmin = function(player)
		return isAdmin(player)
	end
	h.videoHead = function(_, name)
		if type(name) ~= "string" then
			return nil
		end
		local bytes = readEntry("Videos", name)
		if not bytes then
			return nil
		end
		local headLen = 24
		if buffer.readstring(bytes, 0, 4) == "FLV2" then
			headLen = 24 + buffer.readu16(bytes, 16) * 16
		else
			headLen = math.min(buffer.len(bytes), 20 + buffer.readu16(bytes, 16) * 16)
		end
		local head = buffer.create(headLen)
		buffer.copy(head, 0, bytes, 0, headLen)
		local _, e = find("Videos", name)
		return { size = buffer.len(bytes), head = head, attrs = e and e:GetAttributes() or {} }
	end
	h.videoRange = function(_, name, offset, len)
		if type(name) ~= "string" or type(offset) ~= "number" or type(len) ~= "number" then
			return nil
		end
		local bytes = readEntry("Videos", name)
		if not bytes then
			return nil
		end
		offset = math.floor(offset)
		len = math.clamp(math.floor(len), 0, Net.RANGE)
		if offset < 0 or offset >= buffer.len(bytes) then
			return nil
		end
		len = math.min(len, buffer.len(bytes) - offset)
		local out = buffer.create(len)
		buffer.copy(out, 0, bytes, offset, len)
		return out
	end
	h.clipHead = function(_, path)
		local s = type(path) == "string" and session.Sounds[path]
		return s and { size = buffer.len(s.bytes) } or nil
	end
	h.clipRange = function(_, path, offset, len)
		local s = type(path) == "string" and session.Sounds[path]
		if not s or type(offset) ~= "number" or type(len) ~= "number" then
			return nil
		end
		local bytes = s.bytes
		offset = math.floor(offset)
		len = math.clamp(math.floor(len), 0, Net.RANGE)
		if offset < 0 or offset >= buffer.len(bytes) then
			return nil
		end
		len = math.min(len, buffer.len(bytes) - offset)
		local out = buffer.create(len)
		buffer.copy(out, 0, bytes, offset, len)
		return out
	end
	h.image = function(_, key)
		if type(key) ~= "string" then
			return nil
		end
		if string.sub(key, 1, 4) == "lib:" then
			return readEntry("Images", string.sub(key, 5))
		elseif string.sub(key, 1, 4) == "url:" then
			local u = server.urlImages[key]
			return u and u.bytes
		end
		return nil
	end

	-- YouTube links go through the VideoLab YouTube helper (yt-dlp + ffmpeg in a small program of your own: see
	-- VideoLab's helper folder). It answers 202 while it works, so this asks again until the MP4 is ready.
	local function youtubeId(url)
		local host = string.lower(string.match(url, "^https?://([^/:?#]+)") or "")
		host = string.gsub(string.gsub(string.gsub(host, "^www%.", ""), "^m%.", ""), "^music%.", "")
		local id
		if host == "youtu.be" then
			id = string.match(url, "^https?://[^/]+/([%w_%-]+)")
		elseif host == "youtube.com" or host == "youtube-nocookie.com" then
			id = string.match(url, "[?&]v=([%w_%-]+)") or string.match(url, "/shorts/([%w_%-]+)")
				or string.match(url, "/embed/([%w_%-]+)") or string.match(url, "/live/([%w_%-]+)")
		end
		return id and #id == 11 and id or nil, host == "youtube.com" or host == "youtu.be" or host == "youtube-nocookie.com"
	end
	local function fetchYouTube(id, size, onWait)
		local HttpService = game:GetService("HttpService")
		local base = string.gsub(tostring(Config.YouTubeHelper or "http://localhost:8787"), "/+$", "")
		local q = ("%s/fetch?id=%s&size=%d&seconds=%d&key=%s"):format(base, id, size or 256, Config.ImportMaxSeconds or 120,
			HttpService:UrlEncode(tostring(Config.YouTubeHelperKey or "")))
		local t0 = os.clock()
		while true do
			local ok, r = pcall(HttpService.RequestAsync, HttpService, { Url = q, Method = "GET" })
			if not ok then
				local local_ = string.find(base, "localhost", 1, true) or string.find(base, "127.0.0.1", 1, true)
				return nil, ("the YouTube helper at %s didn't answer: start it (start-windows.bat in the helper folder)%s (%s)"):format(base,
					(local_ and not game:GetService("RunService"):IsStudio()) and "; a live server can't reach localhost, so give YouTubeHelper a public address" or "",
					tostring(r))
			end
			if r.StatusCode == 202 then
				if onWait then
					onWait()
				end
				if os.clock() - t0 > 900 then
					return nil, "the YouTube helper is still working after 15 minutes"
				end
				task.wait(2)
			elseif r.Success then
				return r
			else
				local okJ, j = pcall(HttpService.JSONDecode, HttpService, r.Body)
				return nil, "YouTube: " .. ((okJ and type(j) == "table" and j.error) or ("the helper answered " .. r.StatusCode))
			end
		end
	end

	-- admins: import a picture or a video from a web address, kept in memory while the server runs
	local importing = false
	-- how far the import is: attribute ImportStatus on the FrameLab remotes folder ("" when none runs), which the TV's
	-- panel shows, e.g. "42% - video - 31 s"; the server's output gets each step's time when it ends
	local statusAt = 0
	local function setStatus(text, force)
		if force or os.clock() - statusAt > 0.25 then
			statusAt = os.clock()
			remotes:SetAttribute("ImportStatus", text)
		end
	end
	-- quality: "144p" / "240p" / "360p" (FrameLab.Importer.Qualities) or nil for Config.ImportVideoQuality
	h.importUrl = function(player, kind, url, quality) -- player nil: server code (FrameLab.Server.importUrl)
		if player ~= nil and not isAdmin(player) then
			return { error = "only admins can import" }
		end
		if quality ~= nil and (type(quality) ~= "string" or not FrameLab.Importer.Qualities[quality]) then
			quality = nil
		end
		local q, qName = FrameLab.Importer.quality(quality)
		if kind ~= "image" and kind ~= "video" then
			return { error = "import a picture or a video" }
		end
		if type(url) ~= "string" or #url > 2000 or not string.match(url, "^https?://[%w%.%-]+") then
			return { error = "that isn't a web address (http:// or https://)" }
		end
		if kind == "image" then
			local allowed, why = Config.imageUrlAllowed(url)
			if not allowed then
				return { error = why }
			end
		end
		if importing then
			return { error = "another import is running, try again in a moment" }
		end
		importing = true
		local tStart = os.clock()
		local timing = {}
		setStatus("0% - downloading", true)
		local ok, res = pcall(function()
			local HttpService = game:GetService("HttpService")
			local host = string.match(url, "^https?://([^/:?#]+)") or url
			local ytId, isYouTube = youtubeId(url)
			if isYouTube and not ytId then
				return { error = "that YouTube link has no video in it (use a watch, youtu.be or shorts link)" }
			end
			local okHttp, r
			if ytId then
				-- (the helper shrinks to fit a size x size box: the long side of the quality)
				local res2, err2 = fetchYouTube(ytId, math.ceil(q.lines * 16 / 9), function()
					setStatus(("0%% - the YouTube helper is downloading - %d s"):format(os.clock() - tStart))
				end)
				if not res2 then
					return { error = err2 }
				end
				okHttp, r = true, res2
			else
				okHttp, r = pcall(HttpService.RequestAsync, HttpService, { Url = url, Method = "GET" })
			end
			if not okHttp then
				local raw = tostring(r)
				local low = string.lower(raw)
				local why
				if string.find(low, "not enabled", 1, true) then
					why = "HTTP requests are off for this game: turn on Game Settings > Security > Allow HTTP Requests"
				elseif string.find(low, "roblox", 1, true) and string.find(low, "not allowed", 1, true) then
					why = "Roblox doesn't let games download from its own sites (" .. host .. "): use a picture uploaded somewhere else, or the Decal ID tab"
				elseif string.find(low, "dns", 1, true) or string.find(low, "resolve", 1, true) then
					why = "couldn't find the site " .. host .. " (check the address)"
				elseif string.find(low, "timeout", 1, true) or string.find(low, "timed out", 1, true) then
					why = host .. " took too long to answer"
				elseif string.find(low, "number of requests exceeded", 1, true) then
					why = "too many downloads this minute: try again in a moment"
				elseif string.find(low, "trust", 1, true) or string.find(low, "ssl", 1, true) or string.find(low, "certificate", 1, true) then
					why = host .. "'s secure connection failed (bad certificate)"
				else
					why = "the download failed"
				end
				return { error = ("%s (%s)"):format(why, raw) }
			end
			if not r.Success then
				local code = r.StatusCode
				local hint = ""
				if code == 404 or code == 410 then
					hint = string.find(host, "discord", 1, true)
							and ": Discord links expire after about a day, so copy a fresh one"
						or ": the file isn't there (check the link)"
				elseif code == 403 or code == 401 then
					hint = string.find(host, "discord", 1, true) and ": the Discord link expired or is private, so copy a fresh one"
						or ": the site won't share it (it may need a login, or block downloads from games)"
				elseif code == 429 then
					hint = ": the site is limiting downloads, so try again later"
				elseif code >= 500 then
					hint = ": the site is having trouble, so try again later"
				end
				local msg = tostring(r.StatusMessage or "")
				return { error = ("%s answered %d%s%s"):format(host, code, msg ~= "" and (" " .. msg) or "", hint) }
			end
			if #r.Body == 0 then
				return { error = host .. " sent an empty file" }
			end
			local maxBytes = Config.ImportMaxBytes or 8388608
			if #r.Body > maxBytes then
				return { error = ("that file is %.1f MB; the limit is %.1f MB (ImportMaxBytes)"):format(#r.Body / 1048576, maxBytes / 1048576) }
			end
			local ctype = r.Headers and (r.Headers["content-type"] or r.Headers["Content-Type"]) or nil
			local fileName = string.match(url, "([^/?#]+)[?#]?[^/]*$") or "import"
			fileName = string.gsub(fileName, "%%(%x%x)", function(hex) -- "%28" -> "("
				return string.char(tonumber(hex, 16))
			end)
			if ytId then
				-- named after the video's title (the helper sends it URL-encoded)
				local title = r.Headers and (r.Headers["x-title"] or r.Headers["X-Title"]) or ""
				title = string.gsub(title, "%%(%x%x)", function(hex)
					return string.char(tonumber(hex, 16))
				end)
				title = string.sub(string.gsub(title, "[^%w%-_ ]", ""), 1, 40)
				fileName = (title ~= "" and title or ytId) .. ".mp4"
			end
			timing.download = os.clock() - tStart
			local tImport = os.clock()
			local result
			local okImp, err = pcall(function()
				result = FrameLab.Importer.importFile(fileName, buffer.fromstring(r.Body), {
					Timing = timing,
					-- (the picture takes most of the time: video 0 - 80 %, the sound 80 - 100 %)
					Progress = function(stage, f)
						local pct = stage == "video" and f * 80 or 80 + f * 20
						setStatus(("%d%% - %s - %d s"):format(math.floor(pct), stage, os.clock() - tStart))
					end,
					Folder = "imported", MaxImage = Config.ImportMaxPicture or 320, MaxSeconds = Config.ImportMaxSeconds or 120,
					Quality = qName,
					Log = function() end,
					Taken = function(name)
						return find("Videos", name) ~= nil or find("Images", name) ~= nil
					end,
					Sink = function(k, name, bytes, attrs)
						attrs.Bytes = buffer.len(bytes)
						attrs.Url = url
						attrs.ImportedBy = player and player.UserId or 0
						session[k][name] = { bytes = bytes, attrs = attrs }
					end,
				})
			end)
			timing.import = os.clock() - tImport
			if not okImp then
				local msg = FrameLab.Importer.cleanError(err)
				if ctype and string.find(msg, "FrameLab reads", 1, true) then
					msg ..= (" (the site said it's %s)"):format(ctype)
				end
				return { error = msg }
			end
			if (kind == "image") ~= (result.kind == "image") then
				return { error = ("that's a %s, not a %s"):format(result.kind == "image" and "picture" or "video", kind == "image" and "picture" or "video"), name = result.name, kind = result.kind }
			end
			-- the data manager keeps a record of it (Runtime/Server/Library)
			if server.onImported then
				local okRec, errRec = pcall(server.onImported, result, url, qName, player)
				if not okRec then
					warn("[FrameLab] library record: " .. tostring(errRec))
				end
			end
			return { name = result.name, kind = result.kind, width = result.width, height = result.height, seconds = result.seconds, bytes = result.bytes }
		end)
		importing = false
		setStatus("", true)
		local parts = {}
		for _, k in ipairs({ "download", "video", "sound decode", "sound encode" }) do
			if timing[k] then
				table.insert(parts, ("%s %.1f s"):format(k, timing[k]))
			end
		end
		if Config.Debug then
			print(("[FrameLab] import of %s took %.1f s: %s"):format(url, os.clock() - tStart, table.concat(parts, ", ")))
		end
		if not ok then
			return { error = tostring(res) }
		end
		return res
	end

	-- a few requests a second per player is plenty for playback (a 60 KB range is ~2 s of video)
	local budget = {}
	remotes.Media.OnServerInvoke = function(player, action, ...)
		local b = budget[player]
		local now = os.clock()
		if not b or now - b.t > 1 then
			b = { t = now, n = 0 }
			budget[player] = b
		end
		b.n += 1
		if b.n > (Config.RequestsPerSecond or 30) then
			return nil
		end
		local fn = type(action) == "string" and h[action]
		if not fn then
			return nil
		end
		local ok, res = pcall(fn, player, ...)
		if not ok then
			warn("[FrameLab] " .. tostring(action) .. " failed: " .. tostring(res))
			return nil
		end
		return res
	end
	Players.PlayerRemoving:Connect(function(p)
		budget[p] = nil
	end)

	-- server code (VideoLab.importUrl): the same import, without the admin check
	server.importUrl = function(kind, url, quality)
		return h.importUrl(nil, kind, url, quality)
	end
	server.listOf = listOf

	FrameLab.Server = server
end
