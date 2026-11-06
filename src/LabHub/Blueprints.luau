-- Blueprints: the instances LabHub builds at run time with Instancer (the tools and the placeable TV).
-- tools: handed out by FrameLab's ToolAccess (TVToolAccess / SprayToolAccess); their behaviour (FrameLab.Tools.TVTool,
-- FrameLab.Tools.SprayTool) is attached on each client. tv: the TV the TV tool sets down (FrameLab Runtime/Server/TV).
return {
	tools = {
		["TV"] = {
			class = "Tool", name = "TV",
			props = {
				CanBeDropped = false,
				Grip = CFrame.new(0, -0.20000000298023224, 0.75, 1, 0, 0, 0, 1, 0, 0, 0, 1),
				TextureId = "rbxthumb://type=Asset&id=2309346267&w=150&h=150",
				ToolTip = "Set down a TV that plays FrameLab videos",
			},
			attributes = { FrameLabTV = true },
			children = {
				{
					class = "Part", name = "Handle",
					props = {
						CFrame = CFrame.new(0.0031620000954717398, 0.40006598830223083, -0.00044999999227002263, -0.69421792030334473, 4.4798736780649051e-05, 0.71976494789123535, 0, 1, -6.2240789702627808e-05, -0.71976494789123535, -4.3208670831518248e-05, -0.69421792030334473),
						CanCollide = false,
						Massless = true,
						Size = Vector3.new(1.7709499597549438, 1.6013000011444092, 1.6039700508117676),
					},
					children = {
					{
						class = "SpecialMesh", name = "Mesh",
						props = {
							MeshType = Enum.MeshType.FileMesh,
							MeshId = "rbxassetid://2309330801",
							TextureId = "rbxassetid://2309333814",
						},
					},
				},
				},
			},
		},
		["Spray Paint"] = {
			class = "Tool", name = "Spray Paint",
			props = {
				Grip = CFrame.new(0.20000000298023224, -0.25, -0.20000000298023224, 0.26749888062477112, 0, 0.96355819702148438, 0, 1, 0, -0.96355819702148438, 0, 0.26749888062477112),
				TextureId = "http://www.roblox.com/asset/?id=79155357",
				ToolTip = "Spray pictures, decals (and, for admins, pictures from a URL)",
			},
			children = {
				{
					class = "Part", name = "Handle",
					props = {
						CFrame = CFrame.new(0, 0.49999964237213135, 0.30000019073486328, -1, 0, 0, 0, 1, 0, 0, 0, -1),
						Color = Color3.new(0.76862746477127075, 0.15686275064945221, 0.10980392247438431),
						Reflectance = 0.34999999403953552,
						Size = Vector3.new(0.75999784469604492, 1.7099988460540771, 0.57999998331069946),
					},
					children = {
						{
							class = "SpecialMesh", name = "Mesh",
							props = {
								MeshId = "http://www.roblox.com/asset/?id=79146128",
								MeshType = Enum.MeshType.FileMesh,
								TextureId = "http://www.roblox.com/asset/?id=79146220",
							},
						},
						{
							class = "Sound", name = "Sound",
							props = {
								SoundId = "http://www.roblox.com/asset/?id=78496487",
								Volume = 1,
							},
						},
					},
				},
				{
					class = "Animation", name = "SprayPaint",
					props = {
						AnimationId = "http://www.roblox.com/Asset?ID=78494810",
					},
				},
			},
		},
	},
	tv = {
		class = "Model", name = "TV",
		refs = { PrimaryPart = "Body" },
		children = {
			{
				class = "Part", name = "Backing",
				props = {
					Anchored = true,
					BottomSurface = Enum.SurfaceType.Smooth,
					CFrame = CFrame.new(0, 0.90633577108383179, -0.74498498439788818, 1, 0, 0, 0, 1, 0, 0, 0, 1),
					CanCollide = false,
					CanQuery = false,
					CanTouch = false,
					CastShadow = false,
					Color = Color3.new(0, 0, 0),
					Material = Enum.Material.SmoothPlastic,
					Size = Vector3.new(1.2927935123443604, 0.92875397205352783, 0.11999998986721039),
					TopSurface = Enum.SurfaceType.Smooth,
				},
			},
			{
				class = "Part", name = "Body",
				props = {
					Anchored = true,
					CFrame = CFrame.new(0, 0.80065000057220459, 0, 1, 0, 0, 0, 1, 0, 0, 0, 1),
					PivotOffset = CFrame.new(0, -0.80065000057220459, 0, 1, 0, 0, 0, 1, 0, 0, 0, 1),
					Size = Vector3.new(1.7709499597549438, 1.6013000011444092, 1.6039700508117676),
				},
				children = {
					{
						class = "SpecialMesh", name = "Mesh",
						props = {
							MeshType = Enum.MeshType.FileMesh,
							MeshId = "rbxassetid://2309330801",
							TextureId = "rbxassetid://2309333814",
						},
					},
					{
						class = "ProximityPrompt", name = "Change",
						props = {
							ActionText = "Change video",
							MaxActivationDistance = 12,
							ObjectText = "TV",
							RequiresLineOfSight = false,
						},
					},
					{
						class = "ParticleEmitter", name = "Puff",
						props = {
							Color = ColorSequence.new({ ColorSequenceKeypoint.new(0, Color3.new(0.92156863212585449, 0.93333333730697632, 0.96078431606292725)), ColorSequenceKeypoint.new(1, Color3.new(0.92156863212585449, 0.93333333730697632, 0.96078431606292725)) }),
							Enabled = false,
							Lifetime = NumberRange.new(0.40000000596046448, 0.80000001192092896),
							Size = NumberSequence.new({ NumberSequenceKeypoint.new(0, 0.60000002384185791, 0), NumberSequenceKeypoint.new(1, 1.6000000238418579, 0) }),
							Speed = NumberRange.new(4, 8),
							SpreadAngle = Vector2.new(180, 180),
							Texture = "rbxasset://textures/particles/smoke_main.dds",
							Transparency = NumberSequence.new({ NumberSequenceKeypoint.new(0, 0.30000001192092896, 0), NumberSequenceKeypoint.new(1, 1, 0) }),
						},
					},
				},
			},
			{
				class = "Part", name = "Screen",
				props = {
					Anchored = true,
					CFrame = CFrame.new(0, 0.90633577108383179, -0.74898499250411987, 1, 0, 0, 0, 1, 0, 0, 0, 1),
					CanCollide = false,
					CastShadow = false,
					Color = Color3.new(0.047058824449777603, 0.054901961237192154, 0.070588238537311554),
					Material = Enum.Material.SmoothPlastic,
					Size = Vector3.new(1.2927935123443604, 0.92875397205352783, 0.11999998986721039),
				},
			},
			{
				class = "ClickDetector", name = "Watch",
				props = {
					MaxActivationDistance = 100,
				},
			},
		},
	},
}
