--[[ EARTHQUAKE  M0 -> M20  |  client-side LocalScript (Delta / mobile)
     Everything is local to you (other players won't see it).
     Tap STOP (bottom-left) to end it. Rejoin to fully reset the map. ]]

local Players = game:GetService("Players")
local RunService = game:GetService("RunService")
local TweenService = game:GetService("TweenService")
local Lighting = game:GetService("Lighting")
local Debris = game:GetService("Debris")
local SoundService = game:GetService("SoundService")

local plr = Players.LocalPlayer
local cam = workspace.CurrentCamera
local rng = Random.new()

local env = (getgenv and getgenv()) or _G
if env.__QuakeStop then pcall(env.__QuakeStop) end

---------------------------------------------------------------- CONFIG
local CFG = {
	MapRadius = 600,        -- how far from you effects spawn
	TsunamiChance = 0.35,   -- chance at M8
	SplitDistance = 50,     -- each half moves this far apart (M20)
	MaxCracks = 700,        -- crack part cap (mobile performance)
	RumbleSoundId = "",     -- put your own "rbxassetid://..." here for a better rumble
	CollapseSoundId = "",   -- same for crashes
}
local BUILTIN_SOUND = "rbxasset://sounds/impact_explosion_03.mp3" -- slowed down = deep rumble

---------------------------------------------------------------- STATE
local running = true
local conns = {}
local magNow, shakeNow = 0, 0
local levelIdx, levelStart = 1, os.clock()
local scan = { loose = {}, small = {}, big = {}, ground = {}, poles = {}, lights = {}, glass = {}, buildings = {} }
local origEnabled, deadLights, collapsed = {}, {}, {}
local crackCount, bombsAlive = 0, 0
local ash

local fx = Instance.new("Folder")
fx.Name = "FX_" .. tostring(rng:NextInteger(1000, 9999))
fx.Parent = workspace

local origLighting = {}
for _, k in ipairs({ "Ambient", "OutdoorAmbient", "FogColor", "FogEnd", "FogStart", "Brightness", "ClockTime" }) do
	origLighting[k] = Lighting[k]
end
local cc = Instance.new("ColorCorrectionEffect")
cc.Parent = Lighting

---------------------------------------------------------------- UI
local gui = Instance.new("ScreenGui")
gui.Name = "QuakeUI"; gui.ResetOnSpawn = false; gui.IgnoreGuiInset = true; gui.DisplayOrder = 50
if not pcall(function() gui.Parent = gethui() end) then gui.Parent = plr:WaitForChild("PlayerGui") end

local function mkLabel(pos, size, ts, bg)
	local l = Instance.new("TextLabel")
	l.AnchorPoint = Vector2.new(0.5, 0); l.Position = pos; l.Size = size
	l.BackgroundColor3 = Color3.new(0, 0, 0); l.BackgroundTransparency = bg
	l.TextColor3 = Color3.new(1, 1, 1); l.Font = Enum.Font.GothamBold; l.TextSize = ts
	l.TextWrapped = true; l.Parent = gui
	return l
end
local magLbl = mkLabel(UDim2.new(0.5, 0, 0, 36), UDim2.new(0, 240, 0, 40), 20, 0.4)
Instance.new("UICorner", magLbl)
local bannerLbl = mkLabel(UDim2.new(0.5, 0, 0, 84), UDim2.new(0.9, 0, 0, 60), 22, 1)
bannerLbl.TextColor3 = Color3.fromRGB(255, 170, 60); bannerLbl.TextStrokeTransparency = 0; bannerLbl.TextTransparency = 1
local flashFrame = Instance.new("Frame")
flashFrame.Size = UDim2.fromScale(1, 1); flashFrame.BackgroundColor3 = Color3.fromRGB(255, 40, 0)
flashFrame.BackgroundTransparency = 1; flashFrame.BorderSizePixel = 0; flashFrame.Active = false; flashFrame.Parent = gui

local function banner(text, secs)
	bannerLbl.Text = text; bannerLbl.TextTransparency = 0
	task.delay(secs or 4, function()
		if bannerLbl.Text == text then TweenService:Create(bannerLbl, TweenInfo.new(1), { TextTransparency = 1 }):Play() end
	end)
end
local function flash()
	flashFrame.BackgroundTransparency = 0.35
	TweenService:Create(flashFrame, TweenInfo.new(2.5), { BackgroundTransparency = 1 }):Play()
end

---------------------------------------------------------------- HELPERS
local function getHRP()
	local c = plr.Character
	return c and c:FindFirstChild("HumanoidRootPart")
end

local function ray(origin, dir)
	local rp = RaycastParams.new()
	rp.FilterType = Enum.RaycastFilterType.Exclude
	rp.FilterDescendantsInstances = { fx, plr.Character }
	rp.IgnoreWater = true
	return workspace:Raycast(origin, dir, rp)
end

local function overlap()
	local op = OverlapParams.new()
	op.FilterType = Enum.RaycastFilterType.Exclude
	op.FilterDescendantsInstances = { fx, plr.Character }
	return op
end

local function newPart(size, cf, color, neon, material)
	local p = Instance.new("Part")
	p.Anchored = true; p.CanCollide = false; p.CanQuery = false; p.CanTouch = false; p.CastShadow = false
	p.Size = size; p.CFrame = cf; p.Color = color
	p.Material = neon and Enum.Material.Neon or (material or Enum.Material.Slate)
	p.TopSurface = Enum.SurfaceType.Smooth; p.BottomSurface = Enum.SurfaceType.Smooth
	p.Parent = fx
	return p
end

local function newSound(parent, id, speed, vol, looped)
	local s = Instance.new("Sound")
	s.SoundId = (id ~= "" and id) or BUILTIN_SOUND
	s.PlaybackSpeed = speed; s.Volume = vol; s.Looped = looped or false
	s.RollOffMaxDistance = 600
	s.Parent = parent
	return s
end
local function boom(parent, speed, vol)
	local s = newSound(parent or SoundService, CFG.CollapseSoundId, speed, vol)
	s:Play(); Debris:AddItem(s, 6)
end

local rumble = newSound(SoundService, CFG.RumbleSoundId, 0.25, 0, true)
rumble:Play()

local function groundY()
	local hrp = getHRP()
	if not hrp then return 0 end
	local r = ray(hrp.Position + Vector3.new(0, 5, 0), Vector3.new(0, -500, 0))
	return r and r.Position.Y or (hrp.Position.Y - 3)
end

local function groundHit(near)
	local hrp = getHRP()
	local c = hrp and hrp.Position or Vector3.zero
	local r = near and rng:NextNumber(10, 160) or rng:NextNumber(0, CFG.MapRadius)
	local a = rng:NextNumber(0, math.pi * 2)
	local o = c + Vector3.new(math.cos(a) * r, 250, math.sin(a) * r)
	local h = ray(o, Vector3.new(0, -800, 0))
	if h and h.Normal.Y > 0.85 then return h end
end

local function dust(pos, size)
	local a = newPart(Vector3.one, CFrame.new(pos), Color3.new(), false)
	a.Transparency = 1
	local e = Instance.new("ParticleEmitter")
	e.Texture = "rbxasset://textures/particles/smoke_main.dds"
	e.Color = ColorSequence.new(Color3.fromRGB(150, 140, 130))
	e.Size = NumberSequence.new({ NumberSequenceKeypoint.new(0, size * 0.3), NumberSequenceKeypoint.new(1, size) })
	e.Transparency = NumberSequence.new({ NumberSequenceKeypoint.new(0, 0.4), NumberSequenceKeypoint.new(1, 1) })
	e.Lifetime = NumberRange.new(5, 9); e.Speed = NumberRange.new(8, 25)
	e.SpreadAngle = Vector2.new(180, 180); e.Rate = 0
	e.Parent = a; e:Emit(50)
	Debris:AddItem(a, 10)
end

---------------------------------------------------------------- MAP SCAN
local function charPart(inst)
	local m = inst:FindFirstAncestorOfClass("Model")
	while m do
		if m:FindFirstChildOfClass("Humanoid") then return true end
		m = m:FindFirstAncestorOfClass("Model")
	end
	return false
end

local function scanMap()
	local n = 0
	for _, d in ipairs(workspace:GetDescendants()) do
		n += 1
		if n % 400 == 0 then task.wait() end
		if d:IsA("Light") then
			if not charPart(d) and #scan.lights < 1500 then
				table.insert(scan.lights, d); origEnabled[d] = d.Enabled
			end
		elseif d:IsA("BasePart") and not d:IsA("Terrain") and not d:IsDescendantOf(fx) and not charPart(d) then
			local s = d.Size
			local mx = math.max(s.X, s.Z)
			if d.Anchored then
				local flat = s.Y < math.min(s.X, s.Z) / 3
				if mx >= 60 and s.Y <= 60 and flat then
					table.insert(scan.ground, d)
				elseif s.Y >= 14 and s.X <= 3 and s.Z <= 3 then
					if #scan.poles < 400 then table.insert(scan.poles, d) end
				elseif s.Magnitude <= 7 and d.CanCollide then
					if #scan.small < 3000 then table.insert(scan.small, d) end
				end
				if s.Magnitude >= 10 and not flat and #scan.big < 3000 then table.insert(scan.big, d) end
				if (d.Material == Enum.Material.Glass or (d.Transparency > 0.15 and d.Transparency < 0.9))
					and math.min(s.X, s.Y, s.Z) < 1.5 and math.max(s.X, s.Y, s.Z) >= 4 and #scan.glass < 800 then
					table.insert(scan.glass, d)
				end
			elseif s.Magnitude < 40 and #scan.loose < 2000 then
				table.insert(scan.loose, d)
			end
		end
	end
	-- buildings: top-level models (not inside another model)
	for _, m in ipairs(workspace:GetDescendants()) do
		if m:IsA("Model") and not m:FindFirstAncestorOfClass("Model") and not m:FindFirstChildOfClass("Humanoid") and m ~= plr.Character then
			local cnt = 0
			for _, q in ipairs(m:GetDescendants()) do if q:IsA("BasePart") then cnt += 1 end end
			local ext = m:GetExtentsSize()
			if cnt >= 6 and cnt <= 4000 and ext.Y >= 10 and math.max(ext.X, ext.Z) <= 400 then
				table.insert(scan.buildings, { inst = m, height = ext.Y })
			end
		end
	end
	if #scan.buildings < 3 then -- fallback: tall single parts count as towers
		for _, p in ipairs(scan.big) do
			if p.Size.Y >= 14 then table.insert(scan.buildings, { inst = p, height = p.Size.Y }) end
		end
	end
end

---------------------------------------------------------------- CRACKS / SINKHOLES
local CRACK = Color3.fromRGB(12, 12, 12)
local LAVA = Color3.fromRGB(255, 90, 0)

local function makeCrack(p, n, segs, segLen, width, color, neon, depth)
	depth = depth or 0
	if crackCount > CFG.MaxCracks then return end
	local up = math.abs(n.Y) > 0.99 and Vector3.xAxis or Vector3.yAxis
	local at = p + n * 0.05
	local base = CFrame.lookAt(at, at + n, up) -- local -Z = surface normal
	local a = rng:NextNumber(0, math.pi * 2)
	local pos = Vector3.zero
	for i = 1, segs do
		a += rng:NextNumber(-0.7, 0.7)
		local l = segLen * rng:NextNumber(0.6, 1.3)
		local d = Vector3.new(math.cos(a), math.sin(a), 0)
		local w = width * (1 - i / (segs * 1.6))
		local part = newPart(Vector3.new(l, w, 0.05), base * CFrame.new(pos + d * l / 2) * CFrame.Angles(0, 0, a), color, neon)
		crackCount += 1
		if neon and i % 4 == 0 then
			local pl = Instance.new("PointLight"); pl.Color = LAVA; pl.Range = 16; pl.Brightness = 2; pl.Parent = part
		end
		pos += d * l
		if depth == 0 and segs > 4 and rng:NextNumber() < 0.18 then
			local wp = (base * CFrame.new(pos)).Position - n * 0.05
			makeCrack(wp, n, math.max(3, segs // 3), segLen * 0.7, width * 0.6, color, neon, 1)
		end
	end
end

local function spawnCrack()
	local mag = magNow
	local segs = rng:NextInteger(5, 8) + math.floor(mag / 2)
	local segLen = 3 + mag * 0.35
	local width = 0.25 + mag * 0.05
	local r = rng:NextNumber()
	if r < 0.55 or #scan.big == 0 then
		local h = groundHit(rng:NextNumber() < 0.6)
		if h then makeCrack(h.Position, h.Normal, segs, segLen, width, CRACK, false) end
	else
		local p = scan.big[rng:NextInteger(1, #scan.big)]
		if not (p and p.Parent) then return end
		local ceil = r > 0.88
		local half = p.Size / 2
		local origin, dir
		if ceil then
			origin = p.Position - Vector3.new(0, half.Y + 8, 0) + Vector3.new(rng:NextNumber(-half.X, half.X), 0, rng:NextNumber(-half.Z, half.Z))
			dir = Vector3.new(0, half.Y + 16, 0)
		else
			local a = rng:NextNumber(0, math.pi * 2)
			local d = Vector3.new(math.cos(a), 0, math.sin(a))
			local reach = math.max(half.X, half.Z)
			origin = p.Position + d * (reach + 10) + Vector3.new(0, rng:NextNumber(-half.Y, half.Y) * 0.8, 0)
			dir = -d * (reach + 12)
		end
		local h = ray(origin, dir)
		if h and ((ceil and h.Normal.Y < -0.7) or (not ceil and math.abs(h.Normal.Y) < 0.3)) then
			makeCrack(h.Position, h.Normal, segs, segLen * 0.8, width * 0.8, Color3.fromRGB(25, 25, 25), false)
		end
	end
end

local function sinkhole(p, radius)
	local rim = newPart(Vector3.new(0.2, 1, 1), CFrame.new(p + Vector3.new(0, 0.06, 0)) * CFrame.Angles(0, 0, math.pi / 2), Color3.fromRGB(60, 45, 35))
	rim.Shape = Enum.PartType.Cylinder
	local hole = newPart(Vector3.new(0.3, 1, 1), CFrame.new(p + Vector3.new(0, 0.12, 0)) * CFrame.Angles(0, 0, math.pi / 2), Color3.fromRGB(3, 3, 3))
	hole.Shape = Enum.PartType.Cylinder
	local ti = TweenInfo.new(1.8, Enum.EasingStyle.Quad, Enum.EasingDirection.Out)
	TweenService:Create(rim, ti, { Size = Vector3.new(0.2, radius * 2.6, radius * 2.6) }):Play()
	TweenService:Create(hole, ti, { Size = Vector3.new(0.3, radius * 2, radius * 2) }):Play()
	if radius > 6 then
		boom(hole, 0.35, 1)
		pcall(function() workspace.Terrain:FillCylinder(CFrame.new(p - Vector3.new(0, 20, 0)), 40, radius, Enum.Material.Air) end)
		for _, part in ipairs(workspace:GetPartBoundsInRadius(p, radius + 4, overlap())) do
			if not part:IsA("Terrain") and part.Size.X < 150 and part.Size.Z < 150 then
				if part.Anchored then part.Anchored = false end
				part.AssemblyLinearVelocity = Vector3.new(rng:NextNumber(-4, 4), -25, rng:NextNumber(-4, 4))
			end
		end
		dust(p, radius * 1.5)
	end
end

local function spawnSink(big)
	local h = groundHit(rng:NextNumber() < 0.55)
	if not h then return end
	local r = big and rng:NextNumber(8, 14) + magNow * 0.8 or rng:NextNumber(1.5, 3)
	sinkhole(h.Position, r)
end

local function spawnRift()
	local h = groundHit(rng:NextNumber() < 0.7)
	if h then makeCrack(h.Position, h.Normal, 12, 14, 3.5, LAVA, true) end
end

local function spawnUplift()
	local h = groundHit(rng:NextNumber() < 0.5)
	if not h then return end
	local pos, inst = h.Position, h.Instance
	local size = Vector3.new(34, 26, 34)
	local slab = newPart(size, CFrame.new(pos - Vector3.new(0, size.Y / 2 - 0.2, 0)), inst.Color, false, inst.Material)
	slab.CanCollide = true
	local carry = workspace:GetPartBoundsInBox(CFrame.new(pos + Vector3.new(0, 12, 0)), Vector3.new(34, 24, 34), overlap())
	local ti = TweenInfo.new(7, Enum.EasingStyle.Quad)
	local n = 0
	for _, p in ipairs(carry) do
		if p ~= inst and not p:IsA("Terrain") and p.Anchored and p.Size.Magnitude < 120 and n < 120 then
			n += 1
			TweenService:Create(p, ti, { CFrame = p.CFrame + Vector3.new(0, 20, 0) }):Play()
		end
	end
	TweenService:Create(slab, ti, { CFrame = slab.CFrame + Vector3.new(0, 20, 0) }):Play()
	for i = 1, 3 do
		local a = rng:NextNumber(0, math.pi * 2)
		makeCrack(pos + Vector3.new(math.cos(a) * 17, 0, math.sin(a) * 17), Vector3.yAxis, 5, 6, 0.8, CRACK, false)
	end
	boom(slab, 0.4, 1)
end

---------------------------------------------------------------- OBJECTS / LIGHTS / BUILDINGS
local function dropObject()
	local hrp = getHRP()
	if not hrp or #scan.small == 0 then return end
	local gy = groundY()
	for _ = 1, 25 do
		local p = scan.small[rng:NextInteger(1, #scan.small)]
		if p and p.Parent and p.Anchored and p.Position.Y > gy + 2 and (p.Position - hrp.Position).Magnitude < 400 then
			p.Anchored = false
			p.AssemblyLinearVelocity = Vector3.new(rng:NextNumber(-6, 6), rng:NextNumber(0, 5), rng:NextNumber(-6, 6))
			p.AssemblyAngularVelocity = Vector3.new(rng:NextNumber(-5, 5), rng:NextNumber(-5, 5), rng:NextNumber(-5, 5))
			return
		end
	end
end

local function fallPole()
	if #scan.poles == 0 then return end
	local p = scan.poles[rng:NextInteger(1, #scan.poles)]
	if p and p.Parent and p.Anchored then
		p.Anchored = false
		local d = Vector3.new(rng:NextNumber(-1, 1), 0, rng:NextNumber(-1, 1))
		p.AssemblyLinearVelocity = d * 14
		p.AssemblyAngularVelocity = Vector3.new(d.Z, 0, -d.X) * 2
		boom(p, 0.8, 0.7)
	end
end

local function breakWindow()
	if #scan.glass == 0 then return end
	local p = scan.glass[rng:NextInteger(1, #scan.glass)]
	if not (p and p.Parent) then return end
	local pos, col = p.Position, p.Color
	p:Destroy()
	for _ = 1, 8 do
		local s = Instance.new("Part")
		s.Size = Vector3.new(rng:NextNumber(0.3, 1), 0.1, rng:NextNumber(0.3, 1))
		s.Color = col; s.Material = Enum.Material.Glass; s.Transparency = 0.4
		s.CFrame = CFrame.new(pos + Vector3.new(rng:NextNumber(-1.5, 1.5), rng:NextNumber(-1.5, 1.5), rng:NextNumber(-1.5, 1.5)))
		s.CanCollide = false; s.Parent = fx
		s.AssemblyLinearVelocity = Vector3.new(rng:NextNumber(-8, 8), rng:NextNumber(0, 6), rng:NextNumber(-8, 8))
		Debris:AddItem(s, 6)
	end
end

local function collapseBuilding()
	if #scan.buildings == 0 then return end
	local best
	for _ = 1, 4 do
		local b = scan.buildings[rng:NextInteger(1, #scan.buildings)]
		if b and not collapsed[b] and b.inst.Parent and (not best or b.height > best.height) then best = b end
	end
	if not best then return end
	collapsed[best] = true
	local m = best.inst
	local parts = {}
	if m:IsA("BasePart") then parts = { m } else
		for _, d in ipairs(m:GetDescendants()) do if d:IsA("BasePart") then table.insert(parts, d) end end
	end
	pcall(function() m:BreakJoints() end)
	local sum = Vector3.zero
	for _, p in ipairs(parts) do sum += p.Position end
	local center = sum / math.max(#parts, 1)
	table.sort(parts, function(a, b) return a.Position.Y < b.Position.Y end) -- bottom fails first
	boom(SoundService, 0.55, 1)
	dust(center, 40)
	task.spawn(function()
		local chunk = math.max(8, #parts // 25)
		for i = 1, #parts, chunk do
			if not running then return end
			for j = i, math.min(i + chunk - 1, #parts) do
				local p = parts[j]
				if p.Parent then
					p.Anchored = false
					p.AssemblyLinearVelocity = Vector3.new(rng:NextNumber(-12, 12), rng:NextNumber(-3, 5), rng:NextNumber(-12, 12))
					p.AssemblyAngularVelocity = Vector3.new(rng:NextNumber(-2, 2), rng:NextNumber(-2, 2), rng:NextNumber(-2, 2))
				end
			end
			task.wait(0.08)
		end
		dust(center, 60)
	end)
end

---------------------------------------------------------------- TSUNAMI (M8 chance)
local function tsunami()
	local hrp = getHRP()
	if not hrp then return end
	banner("UNDERSEA EARTHQUAKE - TSUNAMI INCOMING!", 8)
	task.wait(6)
	local gy = groundY()
	local dir = Vector3.new(rng:NextNumber(-1, 1), 0, rng:NextNumber(-1, 1))
	if dir.Magnitude < 0.1 then dir = Vector3.zAxis end
	dir = dir.Unit
	local start = hrp.Position - dir * 1100
	local wave = newPart(Vector3.new(2400, 90, 50), CFrame.new(start), Color3.fromRGB(20, 110, 170), false, Enum.Material.SmoothPlastic)
	wave.Transparency = 0.35
	local foam = newPart(Vector3.new(2400, 8, 60), CFrame.new(start), Color3.fromRGB(235, 245, 255), false, Enum.Material.SmoothPlastic)
	foam.Transparency = 0.1
	boom(SoundService, 0.3, 1)
	local last, dist, acc = os.clock(), 0, 0
	while running and dist < 2400 do
		local now = os.clock(); local dt = now - last; last = now
		dist += 95 * dt; acc += dt
		local pos = start + dir * dist
		local cf = CFrame.lookAt(Vector3.new(pos.X, gy + 35, pos.Z), Vector3.new(pos.X, gy + 35, pos.Z) + dir)
		wave.CFrame = cf; foam.CFrame = cf * CFrame.new(0, 43, 0)
		if acc > 0.2 then
			acc = 0
			for _, p in ipairs(workspace:GetPartBoundsInBox(cf, wave.Size, overlap())) do
				if not p.Anchored then p.AssemblyLinearVelocity = dir * 70 + Vector3.new(0, 25, 0) end
			end
			local h = getHRP()
			if h then
				local rel = cf:PointToObjectSpace(h.Position)
				if math.abs(rel.X) < 1200 and math.abs(rel.Y) < 50 and math.abs(rel.Z) < 28 then
					h.AssemblyLinearVelocity = dir * 60 + Vector3.new(0, 22, 0)
				end
			end
		end
		task.wait()
	end
	wave:Destroy(); foam:Destroy()
	if not running then return end
	banner("The flood waters are rising...", 6)
	local c = (getHRP() and getHRP().Position) or Vector3.zero
	local water = newPart(Vector3.new(4000, 1, 4000), CFrame.new(c.X, gy - 2, c.Z), Color3.fromRGB(20, 110, 170), false, Enum.Material.SmoothPlastic)
	water.Transparency = 0.45
	TweenService:Create(water, TweenInfo.new(25, Enum.EasingStyle.Sine), { CFrame = water.CFrame + Vector3.new(0, 10, 0) }):Play()
end

---------------------------------------------------------------- VOLCANOES (M15)
local function lavaBomb(pos, scale)
	if bombsAlive > 110 then return end
	bombsAlive += 1
	local s = rng:NextNumber(2.5, 6) * math.sqrt(scale)
	local b = Instance.new("Part")
	b.Shape = Enum.PartType.Ball; b.Size = Vector3.one * s
	b.Material = Enum.Material.Neon; b.Color = Color3.fromRGB(255, 95, 15)
	b.CFrame = CFrame.new(pos); b.Parent = fx
	b.AssemblyLinearVelocity = Vector3.new(rng:NextNumber(-70, 70), rng:NextNumber(120, 200), rng:NextNumber(-70, 70)) * math.sqrt(scale)
	local f = Instance.new("Fire"); f.Size = s * 2; f.Heat = 0; f.Parent = b
	task.delay(10, function()
		bombsAlive -= 1
		if b.Parent then b:Destroy() end
	end)
end

local function shockwave(pos, scale)
	local r = newPart(Vector3.new(3, 10, 10), CFrame.new(pos) * CFrame.Angles(0, 0, math.pi / 2), Color3.fromRGB(255, 150, 60), true)
	r.Shape = Enum.PartType.Cylinder
	TweenService:Create(r, TweenInfo.new(3, Enum.EasingStyle.Quad, Enum.EasingDirection.Out),
		{ Size = Vector3.new(3, 700 * scale, 700 * scale), Transparency = 1 }):Play()
	Debris:AddItem(r, 3.2)
	for _, p in ipairs(workspace:GetPartBoundsInRadius(pos, 250 * scale, overlap())) do
		if not p.Anchored and not p:IsA("Terrain") then
			local d = p.Position - pos
			if d.Magnitude > 0.1 then p.AssemblyLinearVelocity = d.Unit * 80 + Vector3.new(0, 60, 0) end
		end
	end
end

local function volcano(pos, scale, riseTime)
	local H, R, layers = 110 * scale, 70 * scale, 9
	local lh = H / layers
	local all = {}
	for i = 1, layers do
		local r = R * (1 - (i - 1) / layers) + 4
		local c = newPart(Vector3.new(lh + 0.5, r * 2, r * 2),
			CFrame.new(pos + Vector3.new(0, (i - 0.5) * lh - H, 0)) * CFrame.Angles(0, 0, math.pi / 2),
			Color3.fromRGB(45, 35, 32), false, Enum.Material.Slate)
		c.Shape = Enum.PartType.Cylinder; c.CanCollide = true
		table.insert(all, c)
	end
	local lr = R * 0.12 + 3
	-- crater lava disc sits just above the top layer (positions are pre-rise, i.e. offset by -H)
	local lava = newPart(Vector3.new(1, lr * 2, lr * 2),
		CFrame.new(pos + Vector3.new(0, 0.6, 0)) * CFrame.Angles(0, 0, math.pi / 2), LAVA, true)
	lava.Shape = Enum.PartType.Cylinder
	table.insert(all, lava)
	local pl = Instance.new("PointLight"); pl.Color = LAVA; pl.Range = 120; pl.Brightness = 4; pl.Parent = lava
	local sm = Instance.new("ParticleEmitter")
	sm.Texture = "rbxasset://textures/particles/smoke_main.dds"
	sm.Color = ColorSequence.new(Color3.fromRGB(60, 55, 55))
	sm.Size = NumberSequence.new({ NumberSequenceKeypoint.new(0, 12 * scale), NumberSequenceKeypoint.new(1, 45 * scale) })
	sm.Transparency = NumberSequence.new({ NumberSequenceKeypoint.new(0, 0.3), NumberSequenceKeypoint.new(1, 1) })
	sm.Lifetime = NumberRange.new(6, 10); sm.Speed = NumberRange.new(15, 30)
	sm.EmissionDirection = Enum.NormalId.Right; sm.Rate = 18; sm.Parent = lava
	local ti = TweenInfo.new(riseTime, Enum.EasingStyle.Quad, Enum.EasingDirection.Out)
	for _, c in ipairs(all) do
		TweenService:Create(c, ti, { CFrame = c.CFrame + Vector3.new(0, H, 0) }):Play()
	end
	boom(SoundService, 0.3, 1)
	task.delay(riseTime, function()
		if not running then return end
		local top = pos + Vector3.new(0, H + 6, 0)
		shockwave(top, scale)
		boom(SoundService, 0.25, 1)
		for _ = 1, 25 do lavaBomb(top + Vector3.new(rng:NextNumber(-6, 6), 4, rng:NextNumber(-6, 6)), scale) end
		while running do
			for _ = 1, rng:NextInteger(1, 3) do
				lavaBomb(top + Vector3.new(rng:NextNumber(-6, 6), 8, rng:NextNumber(-6, 6)), scale)
			end
			task.wait(rng:NextNumber(0.35, 0.9))
		end
	end)
end

local function spawnVolcanoes()
	local hrp = getHRP()
	if not hrp then return end
	banner("Magnitude 15 - volcanoes are rising!", 6)
	for _ = 1, 5 do
		if not running then return end
		local a, r = rng:NextNumber(0, math.pi * 2), rng:NextNumber(220, 520)
		local o = hrp.Position + Vector3.new(math.cos(a) * r, 400, math.sin(a) * r)
		local h = ray(o, Vector3.new(0, -900, 0))
		if h then volcano(h.Position, rng:NextNumber(0.8, 1.3), 12) end
		task.wait(1.2)
	end
	local a = rng:NextNumber(0, math.pi * 2)
	local o = hrp.Position + Vector3.new(math.cos(a) * 560, 500, math.sin(a) * 560)
	local h = ray(o, Vector3.new(0, -1000, 0))
	if h then
		banner("A SUPERVOLCANO IS AWAKENING", 6)
		volcano(h.Position, 2.6, 22)
	end
end

---------------------------------------------------------------- ATMOSPHERE
local function skyTo(secs, props)
	TweenService:Create(Lighting, TweenInfo.new(secs), props):Play()
end

local function startAsh(embers)
	if not ash then
		ash = newPart(Vector3.new(150, 1, 150), CFrame.new(cam.CFrame.Position), Color3.new(), false)
		ash.Transparency = 1
		local e = Instance.new("ParticleEmitter")
		e.Texture = "rbxasset://textures/particles/smoke_main.dds"
		e.Color = ColorSequence.new(Color3.fromRGB(110, 105, 105))
		e.Size = NumberSequence.new(0.8); e.Transparency = NumberSequence.new(0.3)
		e.Lifetime = NumberRange.new(8, 10); e.Speed = NumberRange.new(4, 8)
		e.EmissionDirection = Enum.NormalId.Bottom; e.Rate = 60; e.Parent = ash
	end
	if embers and not ash:FindFirstChild("Embers") then
		local e = Instance.new("ParticleEmitter")
		e.Name = "Embers"
		e.Texture = "rbxasset://textures/particles/sparkles_main.dds"
		e.Color = ColorSequence.new(Color3.fromRGB(255, 120, 30))
		e.LightEmission = 1; e.Size = NumberSequence.new(0.6)
		e.Lifetime = NumberRange.new(6, 9); e.Speed = NumberRange.new(6, 12)
		e.EmissionDirection = Enum.NormalId.Bottom; e.Rate = 50; e.Parent = ash
	end
end

---------------------------------------------------------------- M20: THE WORLD SPLITS
local function worldSplit()
	local hrp = getHRP()
	if not hrp then return end
	banner("MAGNITUDE 20 - GLOBAL CATASTROPHE", 10)
	flash()
	startAsh(true)
	skyTo(8, { Ambient = Color3.fromRGB(90, 25, 10), OutdoorAmbient = Color3.fromRGB(110, 35, 15),
		FogColor = Color3.fromRGB(110, 30, 10), FogEnd = 900, FogStart = 50, Brightness = 0.6 })
	TweenService:Create(cc, TweenInfo.new(8), { TintColor = Color3.fromRGB(255, 170, 140), Contrast = 0.15 }):Play()
	boom(SoundService, 0.2, 1)

	local gy = groundY()
	local seamZ = hrp.Position.Z + 45
	local stripHalf = 40

	-- 1) pick ground parts near ground level (axis-aligned only)
	local groundParts = {}
	for _, p in ipairs(scan.ground) do
		if p.Parent and p.Anchored then
			local top = p.Position.Y + p.Size.Y / 2
			local cf = p.CFrame
			if top > gy - 25 and top < gy + 12 and math.abs(cf.RightVector.X) > 0.999 and math.abs(cf.UpVector.Y) > 0.999 then
				table.insert(groundParts, p)
			end
		end
	end
	local spanning = {}
	local xmin, xmax = math.huge, -math.huge
	for _, p in ipairs(groundParts) do
		local z0, z1 = p.Position.Z - p.Size.Z / 2, p.Position.Z + p.Size.Z / 2
		if z0 < seamZ - stripHalf and z1 > seamZ + stripHalf then
			table.insert(spanning, p)
			xmin = math.min(xmin, p.Position.X - p.Size.X / 2)
			xmax = math.max(xmax, p.Position.X + p.Size.X / 2)
		end
	end
	if #spanning == 0 then xmin, xmax = hrp.Position.X - 500, hrp.Position.X + 500 end

	-- 2) jagged boundary line (random walk) so the split looks like a real crack
	local STEP = math.max(16, math.sqrt((xmax - xmin) * stripHalf * 2 / 1400))
	local nCols = math.ceil((xmax - xmin) / STEP) + 2
	local jag, z = {}, 0
	for i = 1, nCols do
		z = math.clamp(z + rng:NextNumber(-6, 6), -stripHalf * 0.55, stripHalf * 0.55)
		jag[i] = z
	end
	local function boundaryZ(x)
		local f = math.clamp((x - xmin) / STEP, 0, nCols - 2)
		local i = math.floor(f)
		local a, b = jag[i + 1], jag[i + 2]
		return seamZ + a + (b - a) * (f - i)
	end

	-- 3) shatter ground into tiny blocks along the seam
	local stripBlocks = {}
	local function piece(p, xa, xb, za, zb, extra)
		if xb - xa < 0.5 or zb - za < 0.5 then return end
		local c = p:Clone()
		for _, ch in ipairs(c:GetChildren()) do if ch:IsA("BaseScript") then ch:Destroy() end end
		local top = p.Position.Y + p.Size.Y / 2
		local depth = p.Size.Y + extra
		c.Size = Vector3.new(xb - xa, depth, zb - za)
		c.CFrame = CFrame.new((xa + xb) / 2, top - depth / 2, (za + zb) / 2)
		c.Anchored = true
		c.Parent = p.Parent
		return c
	end
	local made = 0
	for _, p in ipairs(spanning) do
		local x0, x1 = p.Position.X - p.Size.X / 2, p.Position.X + p.Size.X / 2
		local z0, z1 = p.Position.Z - p.Size.Z / 2, p.Position.Z + p.Size.Z / 2
		piece(p, x0, x1, seamZ + stripHalf, z1, 80)
		piece(p, x0, x1, z0, seamZ - stripHalf, 80)
		local x = x0
		while x < x1 do
			local xb = math.min(x + STEP, x1)
			local zz = seamZ - stripHalf
			while zz < seamZ + stripHalf do
				local zb = math.min(zz + STEP, seamZ + stripHalf)
				local blk = piece(p, x, xb, zz, zb, rng:NextNumber(10, 70))
				if blk then table.insert(stripBlocks, blk) end
				made += 1
				if made % 150 == 0 then task.wait() end
				zz = zb
			end
			x = xb
		end
		p:Destroy()
	end

	-- 4) glowing seam
	banner("The ground is tearing open...", 6)
	for _, b in ipairs(stripBlocks) do
		if b.Parent and math.abs(b.Position.Z - boundaryZ(b.Position.X)) < STEP * 1.1 then
			b.Color = Color3.fromRGB(255, 80, 0); b.Material = Enum.Material.Neon
		end
	end
	task.wait(3)

	-- 5) chasm: lava floor + glow, carve terrain
	local lavaFloor = newPart(Vector3.new(6000, 2, 6000), CFrame.new(hrp.Position.X, gy - 130, seamZ), LAVA, true)
	local fl = Instance.new("PointLight"); fl.Color = LAVA; fl.Range = 60; fl.Brightness = 3; fl.Parent = lavaFloor
	for i = -5, 5 do
		local lp = newPart(Vector3.one, CFrame.new(xmin + (xmax - xmin) * (i + 5) / 10, gy - 90, seamZ), Color3.new(), false)
		lp.Transparency = 1
		local l = Instance.new("PointLight"); l.Color = LAVA; l.Range = 60; l.Brightness = 3; l.Parent = lp
	end
	pcall(function()
		workspace.Terrain:FillBlock(CFrame.new(hrp.Position.X, gy - 200, seamZ), Vector3.new(4000, 420, CFG.SplitDistance * 2 + 60), Enum.Material.Air)
	end)

	-- 6) gather everything anchored and split it into north / south
	local list, orig, sd, alive, idxOf = {}, {}, {}, {}, {}
	local n = 0
	for _, d in ipairs(workspace:GetDescendants()) do
		n += 1
		if n % 500 == 0 then task.wait() end
		if d:IsA("BasePart") and not d:IsA("Terrain") and d.Anchored and d ~= lavaFloor and not charPart(d) then
			local i = #list + 1
			list[i] = d; orig[i] = d.CFrame; alive[i] = true; idxOf[d] = i
			sd[i] = d.Position.Z > boundaryZ(d.Position.X) and 1 or -1
		end
	end
	local pSide = hrp.Position.Z > boundaryZ(hrp.Position.X) and 1 or -1

	-- 7) the two halves move apart
	banner("THE WORLD IS SPLITTING IN HALF", 10)
	boom(SoundService, 0.2, 1)
	local T, t0, prevOff = 16, os.clock(), 0
	while running do
		local a = math.min((os.clock() - t0) / T, 1)
		local off = (a * a * (3 - 2 * a)) * CFG.SplitDistance
		-- edge blocks crumble into the chasm
		if #stripBlocks > 0 then
			for _ = 1, 3 do
				local b = stripBlocks[rng:NextInteger(1, #stripBlocks)]
				local i = idxOf[b]
				if i and alive[i] and b.Parent and rng:NextNumber() < 0.35
					and math.abs(b.Position.Z - boundaryZ(b.Position.X)) < STEP * 1.6 then
					alive[i] = false
					b.Anchored = false
					b.AssemblyLinearVelocity = Vector3.new(rng:NextNumber(-6, 6), -10, rng:NextNumber(-6, 6))
					b.AssemblyAngularVelocity = Vector3.new(rng:NextNumber(-3, 3), rng:NextNumber(-3, 3), rng:NextNumber(-3, 3))
				end
			end
		end
		local ps, cfs = {}, {}
		for i, p in ipairs(list) do
			if alive[i] and p.Parent then
				ps[#ps + 1] = p
				cfs[#cfs + 1] = orig[i] + Vector3.new(0, 0, sd[i] * off)
			end
		end
		pcall(function() workspace:BulkMoveTo(ps, cfs, Enum.BulkMoveMode.FireCFrameChanged) end)
		local h = getHRP()
		if h then h.CFrame = h.CFrame + Vector3.new(0, 0, pSide * (off - prevOff)) end
		prevOff = off
		if a >= 1 then break end
		task.wait(0.05)
	end
	if running then
		flash()
		banner("THE WORLD HAS SPLIT.", 8)
		boom(SoundService, 0.2, 1)
	end
end

---------------------------------------------------------------- LEVELS
local LEVELS = {
	{ mag = 0, dur = 4, shake = 0, rumble = 0 },
	{ mag = 1, dur = 5, shake = 0.06, rumble = 0.25,
		enter = function() banner("Magnitude 1 - you hear a low rumble...", 4) end },
	{ mag = 2, dur = 8, shake = 0.16, rumble = 0.4 },
	{ mag = 5, dur = 13, shake = 0.4, rumble = 0.6, cracks = 1.2, sink = 0.15, fall = 1.2, flicker = 0.25,
		enter = function() banner("Magnitude 5 - cracks are spreading across the map", 5) end },
	{ mag = 8, dur = 15, shake = 1.0, rumble = 0.85, cracks = 3, sink = 0.5, bigSink = 0.12, fall = 3,
		flicker = 0.7, lightsOut = 0.15, collapse = 0.4, poles = 0.15, glass = 0.6,
		enter = function()
			banner("Magnitude 8 - buildings are collapsing!", 5)
			skyTo(10, { Brightness = 1.2 })
			if rng:NextNumber() < CFG.TsunamiChance then task.spawn(tsunami) end
		end },
	{ mag = 10, dur = 20, shake = 1.5, rumble = 1, cracks = 4, sink = 0.7, bigSink = 0.2, fall = 4,
		flicker = 1, lightsOut = 0.3, collapse = 0.65, poles = 0.3, glass = 1,
		enter = function() banner("Magnitude 10 - the city is coming apart", 5) end },
	{ mag = 15, dur = 20, shake = 2.4, rumble = 1.1, cracks = 5, sink = 1, bigSink = 0.3, fall = 5,
		flicker = 1, lightsOut = 0.5, collapse = 1, poles = 0.4, glass = 1.5, rifts = 0.25, uplift = 0.07,
		enter = function()
			skyTo(10, { Ambient = Color3.fromRGB(80, 60, 55), OutdoorAmbient = Color3.fromRGB(90, 70, 65),
				FogColor = Color3.fromRGB(90, 70, 65), FogEnd = 1800, Brightness = 0.9 })
			startAsh(false)
			task.spawn(spawnVolcanoes)
		end },
	{ mag = 20, dur = math.huge, shake = 3.4, rumble = 1.3, cracks = 6, sink = 1.2, bigSink = 0.4, fall = 6,
		flicker = 1, lightsOut = 0.8, collapse = 1.2, poles = 0.5, glass = 2, rifts = 0.5, uplift = 0.1,
		enter = function() task.spawn(worldSplit) end },
}

local function smooth(x) x = math.clamp(x, 0, 1) return x * x * (3 - 2 * x) end
local function field(name)
	local ramp = smooth((os.clock() - levelStart) / 3)
	local c = LEVELS[levelIdx][name] or 0
	local p = (LEVELS[levelIdx - 1] or {})[name] or 0
	return p + (c - p) * ramp
end

---------------------------------------------------------------- LOOPS
-- per-frame values, UI, ash follow
conns[#conns + 1] = RunService.Heartbeat:Connect(function()
	magNow = field("mag"); shakeNow = field("shake")
	local rv = field("rumble")
	rumble.Volume = math.min(rv * 0.9, 1.2); rumble.PlaybackSpeed = 0.22 + rv * 0.18
	magLbl.Text = string.format("MAGNITUDE %.1f", magNow)
	magLbl.TextColor3 = Color3.new(1, 1, 1):Lerp(Color3.fromRGB(255, 60, 40), magNow / 20)
	if ash then ash.CFrame = CFrame.new(cam.CFrame.Position + Vector3.new(0, 50, 0)) end
end)

-- camera shake
RunService:BindToRenderStep("QuakeShake", Enum.RenderPriority.Camera.Value + 1, function()
	if shakeNow <= 0 then return end
	local a = shakeNow
	cam.CFrame = cam.CFrame
		* CFrame.new(rng:NextNumber(-1, 1) * a * 0.35, rng:NextNumber(-1, 1) * a * 0.35, rng:NextNumber(-1, 1) * a * 0.2)
		* CFrame.Angles(math.rad(rng:NextNumber(-1, 1) * a * 0.8), math.rad(rng:NextNumber(-1, 1) * a * 0.8), math.rad(rng:NextNumber(-1, 1) * a * 1.6))
end)

-- rattle anchored objects near you
local rattleSet = {}
local function refreshRattle()
	for p, cf in pairs(rattleSet) do if p.Parent and p.Anchored then p.CFrame = cf end end
	table.clear(rattleSet)
	local hrp = getHRP()
	if not hrp or #scan.small == 0 then return end
	local c = 0
	for _ = 1, 250 do
		local p = scan.small[rng:NextInteger(1, #scan.small)]
		if p and p.Parent and p.Anchored and (p.Position - hrp.Position).Magnitude < 120 then
			rattleSet[p] = p.CFrame; c += 1
			if c >= 120 then break end
		end
	end
end
conns[#conns + 1] = RunService.Heartbeat:Connect(function()
	if shakeNow <= 0 then return end
	local a = math.min(shakeNow * 0.08, 0.4)
	for p, cf in pairs(rattleSet) do
		if p.Parent and p.Anchored then
			p.CFrame = cf * CFrame.new(rng:NextNumber(-a, a), rng:NextNumber(-a, a) * 0.6, rng:NextNumber(-a, a))
		else
			rattleSet[p] = nil
		end
	end
end)
task.spawn(function()
	while running do
		if shakeNow > 0 then refreshRattle() end
		task.wait(3)
	end
end)

-- rattle loose (unanchored) objects
task.spawn(function()
	while running do
		task.wait(0.12)
		local hrp = getHRP()
		if shakeNow > 0 and hrp and #scan.loose > 0 then
			for _ = 1, 30 do
				local p = scan.loose[rng:NextInteger(1, #scan.loose)]
				if p and p.Parent and not p.Anchored and (p.Position - hrp.Position).Magnitude < 250 then
					p.AssemblyLinearVelocity = p.AssemblyLinearVelocity
						+ Vector3.new(rng:NextNumber(-1, 1), rng:NextNumber(0.3, 1.2), rng:NextNumber(-1, 1)) * shakeNow * 1.5
				end
			end
		end
	end
end)

-- light flicker / blackout / destruction
task.spawn(function()
	while running do
		task.wait(rng:NextNumber(0.08, 0.25))
		local lv = LEVELS[levelIdx]
		local f = lv.flicker or 0
		if f > 0 and #scan.lights > 0 then
			local n = math.floor(math.min(#scan.lights, 40) * f) + 1
			for _ = 1, n do
				local li = scan.lights[rng:NextInteger(1, #scan.lights)]
				if li and li.Parent and not deadLights[li] then
					li.Enabled = rng:NextNumber() < 0.5
					if rng:NextNumber() < (lv.lightsOut or 0) * 0.05 then
						deadLights[li] = true
						li.Enabled = false
						local par = li.Parent
						if par and par:IsA("BasePart") then
							if par.Material == Enum.Material.Neon then par.Material = Enum.Material.SmoothPlastic end
							if rng:NextNumber() < 0.3 then par:Destroy() end
						end
					end
				end
			end
		end
	end
end)

-- event spawner
local acc = {}
local function rate(name, r, dt, fn)
	if not r or r <= 0 then return end
	acc[name] = (acc[name] or 0) + r * dt
	while acc[name] >= 1 do
		acc[name] -= 1
		pcall(fn)
	end
end
task.spawn(function()
	while running do
		local dt = task.wait(0.25)
		local L = LEVELS[levelIdx]
		rate("crack", L.cracks, dt, spawnCrack)
		rate("sink", L.sink, dt, function() spawnSink(false) end)
		rate("bsink", L.bigSink, dt, function() spawnSink(true) end)
		rate("fall", L.fall, dt, dropObject)
		rate("collapse", L.collapse, dt, collapseBuilding)
		rate("pole", L.poles, dt, fallPole)
		rate("glass", L.glass, dt, breakWindow)
		rate("rift", L.rifts, dt, spawnRift)
		rate("uplift", L.uplift, dt, spawnUplift)
	end
end)

---------------------------------------------------------------- STOP
local function stop()
	if not running then return end
	running = false
	pcall(function() RunService:UnbindFromRenderStep("QuakeShake") end)
	for _, c in ipairs(conns) do c:Disconnect() end
	for p, cf in pairs(rattleSet) do if p.Parent and p.Anchored then p.CFrame = cf end end
	pcall(function() rumble:Stop(); rumble:Destroy() end)
	for li, en in pairs(origEnabled) do if li.Parent then li.Enabled = en end end
	for k, v in pairs(origLighting) do pcall(function() Lighting[k] = v end) end
	pcall(function() cc:Destroy() end)
	pcall(function() fx:Destroy() end)
	pcall(function() gui:Destroy() end)
	env.__QuakeStop = nil
end
env.__QuakeStop = stop

local stopBtn = Instance.new("TextButton")
stopBtn.Size = UDim2.new(0, 90, 0, 36); stopBtn.Position = UDim2.new(0, 12, 1, -52)
stopBtn.BackgroundColor3 = Color3.fromRGB(170, 30, 30); stopBtn.TextColor3 = Color3.new(1, 1, 1)
stopBtn.Font = Enum.Font.GothamBold; stopBtn.TextSize = 16; stopBtn.Text = "STOP"; stopBtn.Parent = gui
Instance.new("UICorner", stopBtn)
stopBtn.MouseButton1Click:Connect(stop)

---------------------------------------------------------------- START
banner("Scanning the map...", 3)
scanMap()
banner("Magnitude 0 - everything is calm...", 4)

task.spawn(function()
	for i, lv in ipairs(LEVELS) do
		if not running then return end
		levelIdx = i; levelStart = os.clock()
		if lv.enter then task.spawn(lv.enter) end
		while running and os.clock() - levelStart < lv.dur do task.wait() end
	end
end)
