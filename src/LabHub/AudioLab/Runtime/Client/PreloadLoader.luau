-- Started by AudioLab.init() on each client: loads the audio files of ReplicatedFirst.AudioLabPreload (built by the
-- server: Runtime/Server/PreloadSetup) for the profile it names, as early as possible.
-- Progress: attributes on the AudioLabPreload folder: State ("loading" | "ready" | "partial"), Total, Ready, Failed.
-- AudioLab's own preload (OscillatorPool.preload) reuses these players instead of loading the files a second time.
return function(AudioLab)
	local ContentProvider = game:GetService("ContentProvider")
	local folder = game:GetService("ReplicatedFirst"):WaitForChild("AudioLabPreload", 60)
	if not folder then
		return
	end
	local LIMIT = 90 -- seconds before State becomes "partial" (the rest keep loading)
	local profile = folder:GetAttribute("Profile") or "Lean"
	local expected = folder:GetAttribute("Count") or 0
	local files = folder:WaitForChild("Files")

	local function collect()
		local list = {}
		for _, p in ipairs(files:GetChildren()) do
			if p:IsA("AudioPlayer") and table.find(string.split(p:GetAttribute("Profiles") or "", ","), profile) then
				table.insert(list, p)
			end
		end
		return list
	end
	local players = collect()
	local t0 = os.clock()
	while #players < expected and os.clock() - t0 < 5 do -- in case the folder is still arriving
		task.wait()
		players = collect()
	end

	local failed = 0
	local function publish(state, ready)
		folder:SetAttribute("State", state)
		folder:SetAttribute("Total", #players)
		folder:SetAttribute("Ready", ready)
		folder:SetAttribute("Failed", failed)
	end
	publish("loading", 0)
	task.spawn(function()
		pcall(function()
			ContentProvider:PreloadAsync(players, function(_, status)
				if status == Enum.AssetFetchStatus.Failure or status == Enum.AssetFetchStatus.TimedOut then
					failed += 1
				end
			end)
		end)
	end)
	local start = os.clock()
	while true do
		local ready = 0
		for _, p in ipairs(players) do
			if p.IsReady then
				ready += 1
			end
		end
		if ready == #players then
			publish("ready", ready)
			break
		elseif os.clock() - start > LIMIT then
			publish("partial", ready)
			local al = game:GetService("ReplicatedStorage"):WaitForChild("LabHub"):FindFirstChild("AudioLab")
			if al and al:GetAttribute("Debug") == true then 
				warn(("[AudioLab] preload: %d of %d files ready after %d s; the rest keep loading"):format(ready, #players, LIMIT))
			end
			break
		end
		publish("loading", ready)
		task.wait(0.1)
	end
end
