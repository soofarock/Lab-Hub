-- Builds ReplicatedFirst.AudioLabPreload: one AudioPlayer per generic audio file of the manifests (Codec.Manifests), so a
-- joining client starts loading the audio files before the rest of the game (and AudioLab itself) has arrived. Its
-- attributes: Profile (the manifest the clients play: AudioLab attribute Manifest, else Manifests.Default) and Count (how
-- many files that profile loads). Runtime/Client/PreloadLoader does the loading on each client.
return function(AudioLab)
	local ReplicatedFirst = game:GetService("ReplicatedFirst")
	local root = script:FindFirstAncestor("AudioLab")
	local Manifests = require(root.Codec.Manifests)
	local copy = Instance.new("Folder")
	local files = Instance.new("Folder")
	files.Name = "Files"
	files.Parent = copy
	Manifests.syncPreload(files)
	local profile = root:GetAttribute("Manifest")
	if type(profile) ~= "string" or not Manifests.Profiles[profile] then
		profile = Manifests.Default
	end
	local count = 0
	for _, p in ipairs(copy.Files:GetChildren()) do
		if table.find(string.split(p:GetAttribute("Profiles") or "", ","), profile) then
			count += 1
		end
	end
	copy.Name = "AudioLabPreload"
	copy:SetAttribute("Profile", profile)
	copy:SetAttribute("Count", count)
	local old = ReplicatedFirst:FindFirstChild("AudioLabPreload")
	if old then
		old:Destroy()
	end
	copy.Parent = ReplicatedFirst
end
