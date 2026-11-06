-- The TV tool (FrameLab's ToolBinder calls this with the Tool on each client): click / tap to set the TV down in front of you.
-- Then use the prompt on it to pick a video, stop it, or pick it up again.
return function(tool)
	local Players = game:GetService("Players")
	local root = game:GetService("ReplicatedStorage"):WaitForChild("LabHub"):WaitForChild("FrameLab")
	local Net = require(root.Tools.Net)
	local remote = Net.remotes(false):WaitForChild("TV")
	local player = Players.LocalPlayer
	local hint

	tool.Equipped:Connect(function()
		hint = Instance.new("ScreenGui")
		hint.Name = "FrameLabTVHint"
		hint.ResetOnSpawn = true -- a respawn (the tool goes with the old body) clears it too
		local label = Instance.new("TextLabel")
		label.Size = UDim2.new(0, 260, 0, 30)
		label.Position = UDim2.new(0.5, 0, 1, -110)
		label.AnchorPoint = Vector2.new(0.5, 0)
		label.BackgroundColor3 = Color3.fromRGB(20, 23, 30)
		label.BackgroundTransparency = 0.2
		label.TextColor3 = Color3.fromRGB(230, 233, 240)
		label.Font = Enum.Font.GothamMedium
		label.TextSize = 13
		label.Text = "Click to set the TV down"
		local c = Instance.new("UICorner")
		c.CornerRadius = UDim.new(0, 8)
		c.Parent = label
		label.Parent = hint
		hint.Parent = player:WaitForChild("PlayerGui")
	end)
	local function clearHint()
		if hint then
			hint:Destroy()
			hint = nil
		end
	end
	tool.Unequipped:Connect(clearHint)
	-- setting the TV down takes the tool away (it comes back when the TV is picked up)
	tool.AncestryChanged:Connect(function()
		if not player.Character or not tool:IsDescendantOf(player.Character) then
			clearHint()
		end
	end)
	tool.Activated:Connect(function()
		clearHint() -- the server takes the tool away (and this script stops) once the TV is down
		remote:FireServer("drop")
	end)
end
