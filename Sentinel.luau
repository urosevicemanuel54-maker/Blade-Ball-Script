--[[
	Sentinel :: Blade Ball remote parry engine

	Fires the game's own parry RemoteEvent instead of synthesizing mouse input.
	Mouse synthesis (VirtualInputManager) is kept only as a fallback and can be
	switched off entirely.

	Usage:
		loadstring(game:HttpGet("<raw url of this file>"))()

	Toggle auto parry: Right Shift
]]

local Players = game:GetService("Players")
local RunService = game:GetService("RunService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local UserInputService = game:GetService("UserInputService")
local TweenService = game:GetService("TweenService")
local Stats = game:GetService("Stats")
local StarterGui = game:GetService("StarterGui")
local Workspace = workspace

local LocalPlayer = Players.LocalPlayer

local VIM = nil
do
	local ok, service = pcall(function()
		return game:GetService("VirtualInputManager")
	end)
	if ok then
		VIM = service
	end
end

local DrawingLib = nil
do
	local ok, lib = pcall(function()
		return Drawing
	end)
	if ok and lib then
		DrawingLib = lib
	end
end

local ENV
do
	local ok, env = pcall(function()
		return getgenv()
	end)
	if ok and type(env) == "table" then
		ENV = env
	else
		ENV = _G
	end
end

if ENV.Sentinel and type(ENV.Sentinel) == "table" and ENV.Sentinel.Destroy then
	pcall(ENV.Sentinel.Destroy)
end

-- ---------------------------------------------------------------- config

local Config = {
	AutoParry = true,
	UseRemote = true,
	FallbackToMouse = true,
	PingCompensation = true,
	EventHook = false,
	EventHookRange = 220,

	Window = 0.62,
	Cooldown = 0.12,
	Burst = 2,
	BurstGap = 0.03,

	TrackUntargeted = true,

	Highlight = true,
	Trail = true,

	OverrideRemote = "",

	ToggleKey = Enum.KeyCode.RightShift,
}

local Perf = {
	Unlimited = true,
	TargetFps = 120,
	LowGraphics = true,
}

-- ---------------------------------------------------------------- state

local connections = {}
local destroyed = false

local function track(conn)
	table.insert(connections, conn)
	return conn
end

local lastFireAt = 0
local parryCount = 0
local argMode = 0 -- 0 = FireServer(), 1 = FireServer(part), 2 = FireServer(part, position)
local Sentinel -- forward declaration, assigned at the bottom
local pingCache = { value = 0, at = 0 }

local currentETA = nil
local currentDist = nil
local currentSpeed = nil
local currentTargeted = false

local highlightBall = nil
local highlightInst = nil
local trailLine = nil

-- ---------------------------------------------------------------- helpers

local function notify(text)
	pcall(function()
		StarterGui:SetCore("SendNotification", {
			Title = "Sentinel",
			Text = text,
			Duration = 5,
		})
	end)
end

local function ballsFolder()
	return Workspace:FindFirstChild("Balls")
end

local function ballPart(ball)
	local zoom = ball:FindFirstChild("zoomies")
	if zoom and zoom:IsA("BasePart") then
		return zoom
	end
	if ball:IsA("BasePart") then
		return ball
	end
	return ball:FindFirstChildWhichIsA("BasePart", true)
end

local function ballVelocity(ball, part)
	local v = nil

	if part and part:IsA("BasePart") then
		v = part.AssemblyLinearVelocity
	end

	if (not v or v.Magnitude < 0.01) and ball:IsA("BasePart") then
		v = ball.AssemblyLinearVelocity
	end

	if not v or v.Magnitude < 0.01 then
		local zoom = ball:FindFirstChild("zoomies")
		if zoom and zoom:IsA("BasePart") then
			v = zoom.AssemblyLinearVelocity
		end
	end

	return v or Vector3.zero
end

local function targetIsMe(ball)
	local t = ball:GetAttribute("target")
	if t == nil then
		return false
	end

	local char = LocalPlayer.Character

	if typeof(t) == "Instance" then
		if t == LocalPlayer or (char and t == char) then
			return true
		end
		if t.Parent == LocalPlayer then
			return true
		end
		return t.Name == LocalPlayer.Name
	end

	local s = tostring(t)
	return s == LocalPlayer.Name
		or s == LocalPlayer.DisplayName
		or (char ~= nil and s == char.Name)
end

local function pingSeconds()
	local now = os.clock()
	if now - pingCache.at < 0.5 then
		return pingCache.value
	end
	pingCache.at = now

	local ms = 0

	local ok = pcall(function()
		ms = LocalPlayer:GetNetworkPing() * 1000
	end)

	if not ok or ms <= 0 then
		pcall(function()
			ms = Stats.Network.ServerStatsItem["Data Ping"]:GetValue()
		end)
	end

	pingCache.value = math.max(0, ms) / 1000
	return pingCache.value
end

-- ---------------------------------------------------------------- remote discovery

local parryRemote = nil
local lastResolve = 0

local function isRemote(inst)
	return inst:IsA("RemoteEvent") or inst:IsA("UnreliableRemoteEvent")
end

local function scoreRemoteName(name)
	local n = string.lower(name)

	if n == "parry" then
		return 120
	end

	if string.find(n, "parry", 1, true) then
		local s = 92
		if string.find(n, "request", 1, true) or string.find(n, "remote", 1, true) then
			s = 104
		end
		if string.find(n, "client", 1, true) then
			s = s + 4
		end
		return s
	end

	if string.find(n, "deflect", 1, true) then
		return 70
	end

	return 0
end

local function resolveOverride(path)
	local resolved = ReplicatedStorage
	local ok = pcall(function()
		for segment in string.gmatch(path, "[^%.]+") do
			if segment == "game" then
				resolved = game
			elseif segment == "ReplicatedStorage" then
				resolved = ReplicatedStorage
			elseif segment == "workspace" then
				resolved = Workspace
			elseif resolved then
				resolved = resolved:FindFirstChild(segment)
			end
		end
	end)
	if ok and resolved and isRemote(resolved) then
		return resolved
	end
	return nil
end

local function resolveParryRemote(force)
	if parryRemote and parryRemote.Parent and not force then
		return parryRemote
	end

	if parryRemote and (not parryRemote.Parent or force) then
		parryRemote = nil
	end

	if Config.OverrideRemote ~= "" then
		local overridden = resolveOverride(Config.OverrideRemote)
		if overridden then
			parryRemote = overridden
			return overridden
		end
	end

	local best, bestScore = nil, 0

	pcall(function()
		for _, inst in ipairs(ReplicatedStorage:GetDescendants()) do
			if isRemote(inst) then
				local s = scoreRemoteName(inst.Name)
				if s >= 70 and s > bestScore then
					best, bestScore = inst, s
				end
			end
		end
	end)

	parryRemote = best
	lastResolve = os.clock()
	return best
end

-- ---------------------------------------------------------------- firing

local function fireRemoteOnce(ball)
	local remote = resolveParryRemote()
	if not remote then
		return false
	end

	local part = ball and ballPart(ball)

	local ok = pcall(function()
		if argMode == 0 then
			remote:FireServer()
		elseif argMode == 1 then
			remote:FireServer(part)
		else
			remote:FireServer(part, part and part.Position or Vector3.zero)
		end
	end)

	if ok then
		return true
	end

	argMode = 0
	ok = pcall(function()
		remote:FireServer()
	end)
	return ok
end

local function fireMouseParry()
	if not VIM then
		return false
	end
	local ok = pcall(function()
		VIM:SendMouseButtonEvent(0, 0, 0, true, game, 0)
	end)
	if ok then
		task.delay(0.03, function()
			pcall(function()
				VIM:SendMouseButtonEvent(0, 0, 0, false, game, 0)
			end)
		end)
	end
	return ok
end

local function attemptParry(ball)
	if Config.UseRemote and fireRemoteOnce(ball) then
		parryCount = parryCount + 1
		return true
	end
	if Config.FallbackToMouse and fireMouseParry() then
		parryCount = parryCount + 1
		return true
	end
	return false
end

-- ---------------------------------------------------------------- prediction

local function getIncoming(hrp)
	local folder = ballsFolder()
	if not folder then
		return nil
	end

	local best, bestEta = nil, math.huge

	for _, ball in ipairs(folder:GetChildren()) do
		if ball:GetAttribute("realBall") then
			local part = ballPart(ball)
			if part then
				local vel = ballVelocity(ball, part)
				local speed = vel.Magnitude

				if speed > 1 then
					local d = hrp.Position - part.Position
					local dist = d.Magnitude

					if dist > 0.01 then
						local closing = d.Unit:Dot(vel.Unit) > 0.2
						local mine = targetIsMe(ball)

						if closing and (mine or Config.TrackUntargeted) then
							local eta = dist / speed
							if eta < bestEta then
								bestEta = eta
								best = {
									ball = ball,
									part = part,
									vel = vel,
									speed = speed,
									dist = dist,
									eta = eta,
									mine = mine,
								}
							end
						end
					end
				end
			end
		end
	end

	return best
end

local function onStep()
	if destroyed then
		return
	end

	local char = LocalPlayer.Character
	local hrp = char and char:FindFirstChild("HumanoidRootPart")
	local hum = char and char:FindFirstChildOfClass("Humanoid")

	if not hrp or not hum or hum.Health <= 0 then
		currentETA = nil
		return
	end

	local info = getIncoming(hrp)

	if not info then
		currentETA = nil
		currentDist = nil
		currentSpeed = nil
		currentTargeted = false
		return
	end

	currentETA = info.eta
	currentDist = info.dist
	currentSpeed = info.speed
	currentTargeted = info.mine

	if not Config.AutoParry then
		return
	end

	local window = Config.Window
	if Config.PingCompensation then
		window = window + pingSeconds() / 2
	end
	if info.mine then
		window = window + 0.05
	end

	if info.eta > window then
		return
	end

	local now = os.clock()
	if now - lastFireAt < Config.Cooldown then
		return
	end
	lastFireAt = now

	if attemptParry(info.ball) then
		for i = 2, math.max(1, Config.Burst) do
			task.delay((i - 1) * Config.BurstGap, function()
				if destroyed or not Config.AutoParry then
					return
				end
				fireRemoteOnce(info.ball)
			end)
		end
	end
end

-- ---------------------------------------------------------------- event hook

local ballConns = setmetatable({}, { __mode = "k" })

local function watchBall(ball)
	if ballConns[ball] then
		return
	end
	ballConns[ball] = ball:GetAttributeChangedSignal("target"):Connect(function()
		if destroyed or not Config.AutoParry or not Config.EventHook then
			return
		end
		if not targetIsMe(ball) then
			return
		end

		local char = LocalPlayer.Character
		local hrp = char and char:FindFirstChild("HumanoidRootPart")
		local part = ballPart(ball)
		if not hrp or not part then
			return
		end

		if (hrp.Position - part.Position).Magnitude > Config.EventHookRange then
			return
		end

		local now = os.clock()
		if now - lastFireAt < Config.Cooldown then
			return
		end
		lastFireAt = now

		attemptParry(ball)
	end)
end

local function bindBallsFolder()
	local folder = ballsFolder()
	if not folder then
		task.spawn(function()
			while not destroyed and not ballsFolder() do
				task.wait(1)
			end
			if not destroyed then
				bindBallsFolder()
			end
		end)
		return
	end

	for _, ball in ipairs(folder:GetChildren()) do
		watchBall(ball)
	end

	track(folder.ChildAdded:Connect(function(ball)
		watchBall(ball)
	end))
end

-- ---------------------------------------------------------------- visualizer

local function setHighlight(part, on)
	if part == highlightBall and on then
		return
	end
	if highlightInst then
		pcall(function()
			highlightInst:Destroy()
		end)
		highlightInst = nil
	end
	highlightBall = nil
	if not on or not part then
		return
	end

	local inst = Instance.new("Highlight")
	inst.Name = "SentinelMark"
	inst.FillColor = Color3.fromRGB(255, 96, 40)
	inst.FillTransparency = 0.55
	inst.OutlineColor = Color3.fromRGB(255, 210, 120)
	inst.OutlineTransparency = 0
	inst.DepthMode = Enum.HighlightDepthMode.AlwaysOnTop
	inst.Parent = part

	highlightInst = inst
	highlightBall = part
end

local function updateTrail(hrp, part)
	if not DrawingLib then
		return
	end

	if not trailLine then
		local ok, created = pcall(function()
			local line = DrawingLib.new("Line")
			line.Thickness = 1.5
			line.Color = Color3.fromRGB(255, 140, 60)
			line.Transparency = 0.35
			return line
		end)
		if ok then
			trailLine = created
		end
		if not trailLine then
			return
		end
	end

	if not part then
		pcall(function()
			trailLine.Visible = false
		end)
		return
	end

	local camera = Workspace.CurrentCamera
	if not camera or not hrp then
		return
	end

	pcall(function()
		trailLine.From = camera:WorldToViewportPoint(hrp.Position)
		trailLine.To = camera:WorldToViewportPoint(part.Position)
		trailLine.Visible = true
	end)
end

-- ---------------------------------------------------------------- performance

local setFlag, getFlag = nil, nil
do
	local okSetter, setter = pcall(function()
		return setfflag
	end)
	if okSetter and type(setter) == "function" then
		setFlag = setter
	end
	if not setFlag and type(ENV.setfflag) == "function" then
		setFlag = ENV.setfflag
	end

	local okGetter, getter = pcall(function()
		return getfflag
	end)
	if okGetter and type(getter) == "function" then
		getFlag = getter
	end
	if not getFlag and type(ENV.getfflag) == "function" then
		getFlag = ENV.getfflag
	end
end

-- Flags a Roblox build does not know are ignored by the client; setting one that
-- was renamed in a newer build is harmless.
local GRAPHICS_FLAGS = {
	{ "DFIntDebugFRMQualityLevelOverride", 1 },
	{ "FIntRenderShadowIntensity", 0 },
	{ "FIntFRMMinGrassDistance", 0 },
	{ "FIntFRMMaxGrassDistance", 0 },
	{ "FIntRenderGrassDetailStrands", 0 },
	{ "DFFlagTextureQualityOverrideEnabled", true },
	{ "DFIntTextureQualityOverride", 0 },
	{ "FFlagDisablePostFx", true },
	{ "FIntRenderLocalLightUpdatesMax", 1 },
	{ "FIntRenderLocalLightUpdatesMin", 0 },
	{ "FFlagDebugSkyGray", true },
}

local flagPrev = {}
local fpsAvg = 0

local function flagString(value)
	if type(value) == "boolean" then
		return value and "true" or "false"
	end
	return tostring(value)
end

local function applyFlag(name, value)
	if not setFlag then
		return false
	end

	if flagPrev[name] == nil then
		local captured = nil
		if getFlag then
			local ok, current = pcall(getFlag, name)
			if ok then
				captured = current
			end
		end
		flagPrev[name] = captured or false
	end

	return pcall(setFlag, name, flagString(value))
end

local function restoreFlag(name)
	if not setFlag then
		return
	end
	local previous = flagPrev[name]
	if previous == nil or previous == false then
		return
	end
	pcall(setFlag, name, flagString(previous))
end

local function applyFpsCap()
	applyFlag("DFIntTaskSchedulerTargetFps", Perf.Unlimited and 10000 or Perf.TargetFps)
end

local function applyGraphicsFlags()
	for _, flag in ipairs(GRAPHICS_FLAGS) do
		if Perf.LowGraphics then
			applyFlag(flag[1], flag[2])
		else
			restoreFlag(flag[1])
		end
	end
end

-- ---------------------------------------------------------------- UI

local Theme = {
	bg = Color3.fromRGB(16, 18, 24),
	panel = Color3.fromRGB(23, 26, 34),
	panelAlt = Color3.fromRGB(32, 36, 46),
	stroke = Color3.fromRGB(52, 58, 72),
	text = Color3.fromRGB(232, 236, 244),
	dim = Color3.fromRGB(138, 148, 166),
	accent = Color3.fromRGB(255, 118, 52),
	good = Color3.fromRGB(90, 220, 140),
}

local refreshers = {}

local function addRefresher(fn)
	table.insert(refreshers, fn)
end

local function refreshAll()
	for _, fn in ipairs(refreshers) do
		pcall(fn)
	end
end

local function corner(parent, radius)
	local c = Instance.new("UICorner")
	c.CornerRadius = UDim.new(0, radius or 6)
	c.Parent = parent
	return c
end

local gui = Instance.new("ScreenGui")
gui.Name = "SentinelBB"
gui.ResetOnSpawn = false
gui.IgnoreGuiInset = true
gui.DisplayOrder = 512
gui.ZIndexBehavior = Enum.ZIndexBehavior.Sibling
gui.Parent = LocalPlayer:WaitForChild("PlayerGui")

local main = Instance.new("Frame")
main.Name = "Main"
main.Size = UDim2.fromOffset(322, 508)
main.Position = UDim2.fromOffset(28, 120)
main.BackgroundColor3 = Theme.bg
main.BorderSizePixel = 0
main.Parent = gui
corner(main, 10)

local stroke = Instance.new("UIStroke")
stroke.Color = Theme.stroke
stroke.Thickness = 1
stroke.Parent = main

local header = Instance.new("Frame")
header.Size = UDim2.new(1, 0, 0, 40)
header.BackgroundColor3 = Theme.panel
header.BorderSizePixel = 0
header.ClipsDescendants = true
header.Parent = main
corner(header, 10)

local headerCover = Instance.new("Frame")
headerCover.Size = UDim2.new(1, 0, 0, 12)
headerCover.Position = UDim2.new(0, 0, 1, -12)
headerCover.BackgroundColor3 = Theme.panel
headerCover.BorderSizePixel = 0
headerCover.Parent = header

local title = Instance.new("TextLabel")
title.Size = UDim2.new(0, 116, 1, 0)
title.Position = UDim2.fromOffset(14, 0)
title.BackgroundTransparency = 1
title.Font = Enum.Font.GothamBold
title.TextSize = 14
title.TextColor3 = Theme.text
title.TextXAlignment = Enum.TextXAlignment.Left
title.Text = "SENTINEL"
title.Parent = header

local subtitle = Instance.new("TextLabel")
subtitle.Size = UDim2.new(1, -142, 1, 0)
subtitle.Position = UDim2.fromOffset(130, 0)
subtitle.BackgroundTransparency = 1
subtitle.Font = Enum.Font.Gotham
subtitle.TextSize = 11
subtitle.TextColor3 = Theme.dim
subtitle.TextXAlignment = Enum.TextXAlignment.Right
subtitle.Text = ""
subtitle.Parent = header

-- dragging
do
	local dragging = false
	local dragStart, startPos
	header.InputBegan:Connect(function(input)
		if input.UserInputType == Enum.UserInputType.MouseButton1
			or input.UserInputType == Enum.UserInputType.Touch then
			dragging = true
			dragStart = input.Position
			startPos = main.Position
		end
	end)
	track(UserInputService.InputChanged:Connect(function(input)
		if not dragging then
			return
		end
		if input.UserInputType == Enum.UserInputType.MouseMovement
			or input.UserInputType == Enum.UserInputType.Touch then
			local delta = input.Position - dragStart
			main.Position = UDim2.new(
				startPos.X.Scale,
				startPos.X.Offset + delta.X,
				startPos.Y.Scale,
				startPos.Y.Offset + delta.Y
			)
		end
	end))
	track(UserInputService.InputEnded:Connect(function(input)
		if input.UserInputType == Enum.UserInputType.MouseButton1
			or input.UserInputType == Enum.UserInputType.Touch then
			dragging = false
		end
	end))
end

local body = Instance.new("ScrollingFrame")
body.Name = "Body"
body.Size = UDim2.new(1, -16, 1, -52)
body.Position = UDim2.fromOffset(8, 46)
body.BackgroundTransparency = 1
body.BorderSizePixel = 0
body.ScrollBarThickness = 3
body.ScrollBarImageColor3 = Theme.stroke
body.CanvasSize = UDim2.new(0, 0, 0, 0)
body.AutomaticCanvasSize = Enum.AutomaticSize.Y
body.ScrollingDirection = Enum.ScrollingDirection.Y
body.ClipsDescendants = true
body.Parent = main

local layout = Instance.new("UIListLayout")
layout.Padding = UDim.new(0, 5)
layout.SortOrder = Enum.SortOrder.LayoutOrder
layout.Parent = body

local function sectionLabel(text)
	local lbl = Instance.new("TextLabel")
	lbl.Size = UDim2.new(1, 0, 0, 20)
	lbl.BackgroundTransparency = 1
	lbl.Font = Enum.Font.GothamBold
	lbl.TextSize = 10
	lbl.TextColor3 = Theme.dim
	lbl.TextXAlignment = Enum.TextXAlignment.Left
	lbl.Text = text
	lbl.Parent = body
	return lbl
end

local function makeToggle(parent, labelText, get, set)
	local row = Instance.new("Frame")
	row.Size = UDim2.new(1, 0, 0, 28)
	row.BackgroundColor3 = Theme.panel
	row.BorderSizePixel = 0
	row.Parent = parent
	corner(row, 6)

	local hit = Instance.new("TextButton")
	hit.Size = UDim2.fromScale(1, 1)
	hit.BackgroundTransparency = 1
	hit.Text = ""
	hit.Parent = row

	local lbl = Instance.new("TextLabel")
	lbl.Size = UDim2.new(1, -50, 1, 0)
	lbl.Position = UDim2.fromOffset(10, 0)
	lbl.BackgroundTransparency = 1
	lbl.Font = Enum.Font.Gotham
	lbl.TextSize = 12
	lbl.TextColor3 = Theme.text
	lbl.TextXAlignment = Enum.TextXAlignment.Left
	lbl.Text = labelText
	lbl.Parent = row

	local pill = Instance.new("Frame")
	pill.Size = UDim2.fromOffset(34, 18)
	pill.Position = UDim2.new(1, -44, 0.5, -9)
	pill.BackgroundColor3 = Theme.panelAlt
	pill.BorderSizePixel = 0
	pill.Parent = row
	corner(pill, 9)

	local dot = Instance.new("Frame")
	dot.Size = UDim2.fromOffset(12, 12)
	dot.Position = UDim2.fromOffset(3, 3)
	dot.BackgroundColor3 = Theme.text
	dot.BorderSizePixel = 0
	dot.Parent = pill
	corner(dot, 6)

	local function render()
		local on = get()
		pill.BackgroundColor3 = on and Theme.accent or Theme.panelAlt
		TweenService:Create(dot, TweenInfo.new(0.12), {
			Position = on and UDim2.fromOffset(19, 3) or UDim2.fromOffset(3, 3),
		}):Play()
	end

	hit.MouseButton1Click:Connect(function()
		set(not get())
		render()
	end)

	addRefresher(render)
	render()
	return row
end

local function makeSlider(parent, labelText, min, max, step, get, set, fmt)
	local row = Instance.new("Frame")
	row.Size = UDim2.new(1, 0, 0, 42)
	row.BackgroundColor3 = Theme.panel
	row.BorderSizePixel = 0
	row.Parent = parent
	corner(row, 6)

	local lbl = Instance.new("TextLabel")
	lbl.Size = UDim2.new(1, -70, 0, 20)
	lbl.Position = UDim2.fromOffset(10, 2)
	lbl.BackgroundTransparency = 1
	lbl.Font = Enum.Font.Gotham
	lbl.TextSize = 12
	lbl.TextColor3 = Theme.text
	lbl.TextXAlignment = Enum.TextXAlignment.Left
	lbl.Text = labelText
	lbl.Parent = row

	local val = Instance.new("TextLabel")
	val.Size = UDim2.new(0, 60, 0, 20)
	val.Position = UDim2.new(1, -70, 0, 2)
	val.BackgroundTransparency = 1
	val.Font = Enum.Font.GothamBold
	val.TextSize = 12
	val.TextColor3 = Theme.accent
	val.TextXAlignment = Enum.TextXAlignment.Right
	val.Text = ""
	val.Parent = row

	local bar = Instance.new("Frame")
	bar.Size = UDim2.new(1, -20, 0, 6)
	bar.Position = UDim2.new(0, 10, 0, 28)
	bar.BackgroundColor3 = Theme.panelAlt
	bar.BorderSizePixel = 0
	bar.Parent = row
	corner(bar, 3)

	local fill = Instance.new("Frame")
	fill.Size = UDim2.fromScale(0, 1)
	fill.BackgroundColor3 = Theme.accent
	fill.BorderSizePixel = 0
	fill.Parent = bar
	corner(fill, 3)

	local thumb = Instance.new("Frame")
	thumb.AnchorPoint = Vector2.new(0.5, 0.5)
	thumb.Size = UDim2.fromOffset(12, 12)
	thumb.Position = UDim2.new(0, 0, 0.5, 0)
	thumb.BackgroundColor3 = Theme.text
	thumb.BorderSizePixel = 0
	thumb.ZIndex = 2
	thumb.Parent = bar
	corner(thumb, 6)

	local function render()
		local value = get()
		local alpha = (max > min) and math.clamp((value - min) / (max - min), 0, 1) or 0
		fill.Size = UDim2.fromScale(alpha, 1)
		thumb.Position = UDim2.new(alpha, 0, 0.5, 0)
		val.Text = fmt and fmt(value) or tostring(value)
	end

	local function setFromX(absX)
		local width = math.max(bar.AbsoluteSize.X, 1)
		local a = math.clamp((absX - bar.AbsolutePosition.X) / width, 0, 1)
		local raw = min + (max - min) * a
		local snapped = math.round(raw / step) * step
		snapped = math.clamp(snapped, min, max)
		set(snapped)
		render()
	end

	local dragging = false
	bar.InputBegan:Connect(function(input)
		if input.UserInputType == Enum.UserInputType.MouseButton1
			or input.UserInputType == Enum.UserInputType.Touch then
			dragging = true
			setFromX(input.Position.X)
		end
	end)
	track(UserInputService.InputChanged:Connect(function(input)
		if not dragging then
			return
		end
		if input.UserInputType == Enum.UserInputType.MouseMovement
			or input.UserInputType == Enum.UserInputType.Touch then
			setFromX(input.Position.X)
		end
	end))
	track(UserInputService.InputEnded:Connect(function(input)
		if input.UserInputType == Enum.UserInputType.MouseButton1
			or input.UserInputType == Enum.UserInputType.Touch then
			dragging = false
		end
	end))

	addRefresher(render)
	render()
	return row
end

sectionLabel("PARRY")

makeToggle(body, "Auto Parry", function()
	return Config.AutoParry
end, function(v)
	Config.AutoParry = v
end)

makeToggle(body, "Use Remote Event", function()
	return Config.UseRemote
end, function(v)
	Config.UseRemote = v
end)

makeToggle(body, "Mouse Fallback", function()
	return Config.FallbackToMouse
end, function(v)
	Config.FallbackToMouse = v
end)

makeToggle(body, "Ping Compensation", function()
	return Config.PingCompensation
end, function(v)
	Config.PingCompensation = v
end)

makeToggle(body, "Burst on Target Lock", function()
	return Config.EventHook
end, function(v)
	Config.EventHook = v
end)

makeSlider(body, "Parry Window", 0.05, 1.2, 0.01, function()
	return Config.Window
end, function(v)
	Config.Window = v
end, function(v)
	return string.format("%.2fs", v)
end)

makeSlider(body, "Fire Delay", 0.02, 0.5, 0.01, function()
	return Config.Cooldown
end, function(v)
	Config.Cooldown = v
end, function(v)
	return string.format("%.2fs", v)
end)

makeSlider(body, "Burst Count", 1, 5, 1, function()
	return Config.Burst
end, function(v)
	Config.Burst = math.round(v)
end, function(v)
	return string.format("%d", math.round(v))
end)

sectionLabel("PERFORMANCE")

makeToggle(body, "Unlimited FPS", function()
	return Perf.Unlimited
end, function(v)
	Perf.Unlimited = v
	applyFpsCap()
end)

makeSlider(body, "FPS Cap", 30, 240, 30, function()
	return Perf.TargetFps
end, function(v)
	Perf.TargetFps = math.round(v)
	if not Perf.Unlimited then
		applyFpsCap()
	end
end, function(v)
	return string.format("%d", math.round(v))
end)

makeToggle(body, "Low Graphics", function()
	return Perf.LowGraphics
end, function(v)
	Perf.LowGraphics = v
	applyGraphicsFlags()
end)

sectionLabel("VISUALS")

makeToggle(body, "Highlight Incoming", function()
	return Config.Highlight
end, function(v)
	Config.Highlight = v
end)

makeToggle(body, "Trajectory Line", function()
	return Config.Trail
end, function(v)
	Config.Trail = v
end)

sectionLabel("STATUS")

local statusLabel = Instance.new("TextLabel")
statusLabel.Size = UDim2.new(1, 0, 0, 78)
statusLabel.BackgroundColor3 = Theme.panel
statusLabel.BorderSizePixel = 0
statusLabel.Font = Enum.Font.Code
statusLabel.TextSize = 11
statusLabel.TextColor3 = Theme.dim
statusLabel.TextXAlignment = Enum.TextXAlignment.Left
statusLabel.TextYAlignment = Enum.TextYAlignment.Top
statusLabel.Text = ""
statusLabel.Parent = body
corner(statusLabel, 6)

local statusPad = Instance.new("UIPadding")
statusPad.PaddingLeft = UDim.new(0, 10)
statusPad.PaddingTop = UDim.new(0, 6)
statusPad.Parent = statusLabel

local buttonRow = Instance.new("Frame")
buttonRow.Size = UDim2.new(1, 0, 0, 28)
buttonRow.BackgroundTransparency = 1
buttonRow.Parent = body

local rowLayout = Instance.new("UIListLayout")
rowLayout.FillDirection = Enum.FillDirection.Horizontal
rowLayout.Padding = UDim.new(0, 6)
rowLayout.Parent = buttonRow

local resetBtn = Instance.new("TextButton")
resetBtn.Size = UDim2.new(0.5, -3, 1, 0)
resetBtn.BackgroundColor3 = Theme.panel
resetBtn.BorderSizePixel = 0
resetBtn.Font = Enum.Font.GothamBold
resetBtn.TextSize = 12
resetBtn.TextColor3 = Theme.text
resetBtn.Text = "RESCAN REMOTE"
resetBtn.Parent = buttonRow
corner(resetBtn, 6)
resetBtn.MouseButton1Click:Connect(function()
	resolveParryRemote(true)
	refreshAll()
end)

local destroyBtn = Instance.new("TextButton")
destroyBtn.Size = UDim2.new(0.5, -3, 1, 0)
destroyBtn.BackgroundColor3 = Theme.panel
destroyBtn.BorderSizePixel = 0
destroyBtn.Font = Enum.Font.GothamBold
destroyBtn.TextSize = 12
destroyBtn.TextColor3 = Theme.text
destroyBtn.Text = "UNLOAD"
destroyBtn.Parent = buttonRow
corner(destroyBtn, 6)

-- ---------------------------------------------------------------- status refresh

local function refreshStatus()
	if destroyed then
		return
	end

	local remoteName = parryRemote and parryRemote.Name or "not found"
	if parryRemote and not parryRemote.Parent then
		remoteName = "stale"
	end

	subtitle.Text = string.format("%s | %.0f ms", remoteName, pingSeconds() * 1000)

	if not parryRemote and os.clock() - lastResolve > 2 then
		resolveParryRemote(true)
	end

	local etaText = currentETA and string.format("%.2fs", currentETA) or "--"
	local speedText = currentSpeed and string.format("%.0f", currentSpeed) or "--"

	statusLabel.Text = string.format(
		"remote   %s\nwindow   %.2fs  |  eta %s\nspeed    %s st/s  |  fired %d\nfps      %.0f  |  cap %s",
		remoteName,
		Config.Window,
		etaText,
		speedText,
		parryCount,
		fpsAvg,
		Perf.Unlimited and "uncapped" or tostring(Perf.TargetFps)
	)
	if currentTargeted then
		statusLabel.TextColor3 = Theme.good
	else
		statusLabel.TextColor3 = Theme.dim
	end
end

-- ---------------------------------------------------------------- bind

track(UserInputService.InputBegan:Connect(function(input, processed)
	if processed then
		return
	end
	if input.KeyCode == Config.ToggleKey then
		Config.AutoParry = not Config.AutoParry
		refreshAll()
	end
end))

local stepConnection = (RunService.PreSimulation or RunService.Heartbeat):Connect(onStep)
track(stepConnection)

-- visual pass
track(RunService.RenderStepped:Connect(function(dt)
	if destroyed then
		return
	end

	if dt and dt > 0 then
		local instant = 1 / dt
		fpsAvg = fpsAvg > 0 and (fpsAvg + (instant - fpsAvg) * 0.1) or instant
	end

	local char = LocalPlayer.Character
	local hrp = char and char:FindFirstChild("HumanoidRootPart")
	local folder = ballsFolder()
	local incoming = nil

	if folder and hrp then
		for _, ball in ipairs(folder:GetChildren()) do
			if ball:GetAttribute("realBall") then
				local part = ballPart(ball)
				if part then
					local vel = ballVelocity(ball, part)
					local speed = vel.Magnitude
					if speed > 1 then
						local d = hrp.Position - part.Position
						local dist = d.Magnitude
						if dist > 0.01 and d.Unit:Dot(vel.Unit) > 0.2 then
							if targetIsMe(ball) or Config.TrackUntargeted then
								incoming = part
								break
							end
						end
					end
				end
			end
		end
	end

	if Config.Highlight then
		setHighlight(incoming, incoming ~= nil)
	else
		setHighlight(nil, false)
	end

	if Config.Trail then
		updateTrail(hrp, incoming)
	else
		updateTrail(nil, nil)
	end
end))

destroyBtn.MouseButton1Click:Connect(function()
	if ENV.Sentinel and ENV.Sentinel.Destroy then
		ENV.Sentinel.Destroy()
	end
end)

task.spawn(function()
	while not destroyed do
		pcall(refreshStatus)
		task.wait(0.15)
	end
end)

-- ---------------------------------------------------------------- api

local function Destroy()
	if destroyed then
		return
	end
	destroyed = true

	for _, conn in ipairs(connections) do
		pcall(function()
			conn:Disconnect()
		end)
	end
	table.clear(connections)

	if highlightInst then
		pcall(function()
			highlightInst:Destroy()
		end)
		highlightInst = nil
	end

	if trailLine then
		pcall(function()
			trailLine:Remove()
		end)
		trailLine = nil
	end

	for _, flag in ipairs(GRAPHICS_FLAGS) do
		restoreFlag(flag[1])
	end

	if gui then
		gui:Destroy()
	end

	if ENV.Sentinel == Sentinel then
		ENV.Sentinel = nil
	end
end

Sentinel = {
	Destroy = Destroy,
	Config = Config,
	ResolveRemote = resolveParryRemote,
	Ping = pingSeconds,
}

ENV.Sentinel = Sentinel

resolveParryRemote()
bindBallsFolder()
applyFpsCap()
applyGraphicsFlags()
refreshAll()

if not setFlag then
	notify("setfflag unavailable in this executor — FPS and graphics flags skipped")
else
	notify(string.format(
		"loaded | remote: %s",
		parryRemote and parryRemote:GetFullName() or "not found"
	))
end
