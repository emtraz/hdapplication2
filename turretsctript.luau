-- Discord: emtrazaltaccount | Roblox: emtraz
-- Turret logic. All tunable values live in ReplicatedStorage.Config.TurretSettings
local CollectionService = game:GetService("CollectionService")
local RunService = game:GetService("RunService")
local Players = game:GetService("Players")
local TweenService = game:GetService("TweenService")
local Debris = game:GetService("Debris")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Settings = require(ReplicatedStorage:WaitForChild("Config"):WaitForChild("TurretSettings"))

local PARTS = Settings.PartNames
local TARGETING = Settings.Targeting
local BULLETS = Settings.Bullets
local SPIN = Settings.Spin
local LASER = Settings.Laser
local COLORS = Settings.Colors
local SOUNDS = Settings.Sounds

local projectileFolder = workspace:WaitForChild(Settings.Folders.Projectiles)
local turretFolder = workspace:WaitForChild(Settings.Folders.Turrets)

-- Values worked out once from the settings
local AIM_TOLERANCE = math.cos(math.rad(TARGETING.AimToleranceDegrees)) -- Stored as a cosine so the check is one dot product
local SWEEP_ANGLE = math.rad(Settings.IdleSweep.AngleDegrees)
local FLAT = TARGETING.IgnoreJumping and Vector3.new(1, 0, 1) or Vector3.one
local GRAVITY = Vector3.new(0, -workspace.Gravity * BULLETS.GravityScale, 0)
local FLASH_TWEEN = TweenInfo.new(Settings.MuzzleEffects.FlashFadeTime, Enum.EasingStyle.Quad, Enum.EasingDirection.Out)
local BULLET_HALF_LENGTH = BULLETS.Size.Z * 0.5

-- Turn each kind's SpinParts list into a lookup set
local spinPartSets = {}
for kindName, kind in Settings.Kinds do
	if kind.SpinParts then
		local set = {}
		for _, partName in kind.SpinParts do
			set[partName] = true
		end
		spinPartSets[kindName] = set
	end
end

local bulletParams = RaycastParams.new()
bulletParams.FilterType = Enum.RaycastFilterType.Exclude
bulletParams.FilterDescendantsInstances = { projectileFolder, turretFolder }
bulletParams.IgnoreWater = true

local sightParams = RaycastParams.new()
sightParams.FilterType = Enum.RaycastFilterType.Exclude
sightParams.FilterDescendantsInstances = { projectileFolder, turretFolder }
sightParams.IgnoreWater = true

local pool = {} -- Reused bullet parts, the Minigun fires a lot
local activeBullets = {}

local function createBulletPart()
	local part = Instance.new("Part")
	part.Name = "Bullet"
	part.Size = BULLETS.Size
	part.Material = Enum.Material.Neon
	part.Anchored = true -- Moved by raycasts, not physics
	part.CanCollide = false
	part.CanQuery = false
	part.CanTouch = false
	part.CastShadow = false

	local back = Instance.new("Attachment")
	back.Name = "Back"
	back.Position = Vector3.new(0, 0, BULLET_HALF_LENGTH)
	back.Parent = part
	local front = Instance.new("Attachment")
	front.Name = "Front"
	front.Position = Vector3.new(0, 0, -BULLET_HALF_LENGTH)
	front.Parent = part

	local trail = Instance.new("Trail")
	trail.Attachment0 = back
	trail.Attachment1 = front
	trail.LightEmission = 1
	trail.Lifetime = BULLETS.TrailLifetime
	trail.Transparency = NumberSequence.new(0.4, 1)
	trail.WidthScale = NumberSequence.new(1, 0)
	trail.FaceCamera = true
	trail.Enabled = false
	trail.Parent = part
	return part
end

local function acquireBullet()
	return table.remove(pool) or createBulletPart() -- Reuse a spare part if there is one
end

local function releaseBullet(part)
	part.Trail.Enabled = false
	part.Parent = nil
	if #pool < BULLETS.PoolSize then
		table.insert(pool, part)
	else
		part:Destroy()
	end
end

local function spawnImpact(position, normal, material, color)
	local effects = Settings.ImpactEffects

	local anchor = Instance.new("Attachment")
	anchor.CFrame = CFrame.lookAt(position + normal * 0.05, position + normal * 2)
	anchor.Parent = workspace.Terrain

	local burst = Instance.new("ParticleEmitter")
	burst.Texture = "rbxasset://textures/particles/sparkles_main.dds"
	burst.Color = ColorSequence.new(color)
	burst.LightEmission = 1
	burst.Size = NumberSequence.new(0.25, 0)
	burst.Lifetime = NumberRange.new(0.15, 0.35)
	burst.Speed = NumberRange.new(8, 18)
	burst.SpreadAngle = Vector2.new(60, 60)
	burst.Acceleration = Vector3.new(0, -workspace.Gravity * 0.5, 0)
	burst.EmissionDirection = Enum.NormalId.Front
	burst.Rate = 0 -- One burst instead of a stream
	burst.Parent = anchor

	local dust = Instance.new("ParticleEmitter")
	dust.Texture = "rbxasset://textures/particles/smoke_main.dds"
	dust.Color = ColorSequence.new(material == Enum.Material.Neon and color or COLORS.ImpactDust)
	dust.Transparency = NumberSequence.new(0.5, 1)
	dust.Size = NumberSequence.new(0.4, 1.6)
	dust.Lifetime = NumberRange.new(0.3, 0.5)
	dust.Speed = NumberRange.new(2, 4)
	dust.SpreadAngle = Vector2.new(30, 30)
	dust.EmissionDirection = Enum.NormalId.Front
	dust.Rate = 0
	dust.Parent = anchor

	local sound = Instance.new("Sound")
	sound.SoundId = SOUNDS.ImpactId
	sound.Volume = SOUNDS.ImpactVolume
	sound.PlaybackSpeed = 0.9 + math.random() * 0.3
	sound.RollOffMaxDistance = SOUNDS.ImpactHearingDistance
	sound.Parent = anchor

	burst:Emit(effects.SparkCount)
	dust:Emit(effects.DustCount)
	sound:Play()
	Debris:AddItem(anchor, effects.Lifetime) -- One cleanup for every effect
end

local function fireBullet(origin, velocity, damage, color)
	local part = acquireBullet()
	part.Color = color
	part.Trail.Color = ColorSequence.new(color)
	part.CFrame = CFrame.lookAt(origin, origin + velocity)
	part.Parent = projectileFolder
	part.Trail:Clear()
	part.Trail.Enabled = true

	table.insert(activeBullets, {
		position = origin,
		velocity = velocity,
		damage = damage,
		color = color,
		age = 0,
		part = part,
	})
end

local function onBulletHit(bullet, result)
	local character = result.Instance:FindFirstAncestorOfClass("Model")
	local humanoid = character and character:FindFirstChildOfClass("Humanoid")
	if humanoid and humanoid.Health > 0 then
		humanoid:TakeDamage(bullet.damage) -- Respects ForceFields
	end
	spawnImpact(result.Position, result.Normal, result.Material, bullet.color)
	releaseBullet(bullet.part)
end

local function stepBullet(bullet, dt)
	local nextVelocity = bullet.velocity + GRAVITY * dt
	local displacement = (bullet.velocity + nextVelocity) * 0.5 * dt

	local result = workspace:Raycast(bullet.position, displacement, bulletParams) -- Stops fast bullets passing through walls
	if result then
		onBulletHit(bullet, result)
		return false
	end

	bullet.position += displacement
	bullet.velocity = nextVelocity
	bullet.age += dt
	if bullet.age >= BULLETS.Lifetime then
		releaseBullet(bullet.part)
		return false
	end

	bullet.part.CFrame = CFrame.lookAt(bullet.position, bullet.position + bullet.velocity)
	return true
end

local function updateBullets(dt)
	for i = #activeBullets, 1, -1 do
		if not stepBullet(activeBullets[i], dt) then
			activeBullets[i] = activeBullets[#activeBullets] -- Swap-remove, no shifting
			activeBullets[#activeBullets] = nil
		end
	end
end

local Turret = {}
Turret.__index = Turret

function Turret.new(model)
	local head = model:FindFirstChild(PARTS.Head)
	local swivel = head and head.PrimaryPart
	local muzzle = swivel and swivel:FindFirstChild(PARTS.Muzzle)
	if not muzzle then
		warn(`[TurretSystem] {model:GetFullName()} is missing {PARTS.Head} / PrimaryPart / {PARTS.Muzzle}`)
		return nil
	end

	local self = setmetatable({}, Turret)
	self.model = model
	self.head = head
	self.swivel = swivel
	self.muzzle = muzzle
	self.flash = swivel:FindFirstChild(PARTS.MuzzleFlash)
	self.eye = head:FindFirstChild(PARTS.Eye)

	self.restCFrame = head:GetPivot()
	self.aimCFrame = self.restCFrame
	self.origin = self.restCFrame.Position
	self.recoil = 0
	self.lastShot = 0
	self.sweepTime = math.random() * math.pi * 2
	self.scanTimer = math.random() * TARGETING.ScanInterval -- Spreads scans across frames

	self:buildEffects()
	self:readConfig()
	self:setupSpin()
	self:setTarget(nil)

	self.configConnection = model.AttributeChanged:Connect(function(name)
		if Settings.Defaults[name] ~= nil or name == Settings.KindAttribute then
			self:readConfig()
		end
	end)

	return self
end

function Turret:buildEffects()
	self.laserEnd = Instance.new("Attachment")
	self.laserEnd.Name = self.model.Name .. "LaserEnd"
	self.laserEnd.Parent = workspace.Terrain -- Terrain never moves

	self.laser = Instance.new("Beam")
	self.laser.Attachment0 = self.muzzle
	self.laser.Attachment1 = self.laserEnd
	self.laser.Color = ColorSequence.new(COLORS.Alert)
	self.laser.Width0 = LASER.Width
	self.laser.Width1 = LASER.Width
	self.laser.LightEmission = 1
	self.laser.Transparency = NumberSequence.new(LASER.Transparency)
	self.laser.FaceCamera = true
	self.laser.Segments = 1
	self.laser.Enabled = false
	self.laser.Parent = self.swivel

	self.fireSound = Instance.new("Sound")
	self.fireSound.SoundId = SOUNDS.FireId
	self.fireSound.Volume = SOUNDS.FireVolume
	self.fireSound.RollOffMaxDistance = SOUNDS.FireHearingDistance
	self.fireSound.Parent = self.swivel

	self.sparks = Instance.new("ParticleEmitter")
	self.sparks.Texture = "rbxasset://textures/particles/sparkles_main.dds"
	self.sparks.Color = ColorSequence.new(COLORS.MuzzleSparks[1], COLORS.MuzzleSparks[2])
	self.sparks.LightEmission = 1
	self.sparks.Size = NumberSequence.new(0.35, 0)
	self.sparks.Lifetime = NumberRange.new(0.08, 0.18)
	self.sparks.Speed = NumberRange.new(14, 24)
	self.sparks.SpreadAngle = Vector2.new(18, 18)
	self.sparks.EmissionDirection = Enum.NormalId.Front
	self.sparks.Rate = 0
	self.sparks.Parent = self.muzzle
end

-- Reads stats from attributes on the model, falling back to Settings.Defaults
function Turret:readConfig()
	local model = self.model
	local function get(name)
		local value = model:GetAttribute(name)
		if value == nil then
			return Settings.Defaults[name]
		end
		return value
	end
	self.range = get("Range")
	self.fireInterval = 1 / math.max(get("FireRate"), 0.01)
	self.damage = get("Damage")
	self.bulletSpeed = get("BulletSpeed")
	self.turnSpeed = get("TurnSpeed")

	local kindName = model:GetAttribute(Settings.KindAttribute)
	if not Settings.Kinds[kindName] then
		kindName = Settings.DefaultKind -- Unknown kinds fall back to the default
	end
	self.kindName = kindName
	self.style = Settings.Kinds[kindName]
	self.fireSound.PlaybackSpeed = self.style.SoundPitch or 1
end

function Turret:setupSpin()
	self.spinParts = nil
	self.spinSpeed = 0
	self.spinAngle = 0
	local names = spinPartSets[self.kindName]
	if not names then
		return
	end
	self.spinParts = {}
	local swivelCFrame = self.swivel.CFrame
	for _, part in self.head:GetChildren() do
		if part:IsA("BasePart") and names[part.Name] then
			self.spinParts[part] = swivelCFrame:ToObjectSpace(part.CFrame) -- Offset from the swivel, rebuilt every frame
		end
	end
	local muzzlePosition = self.muzzle.Position
	self.spinAxis = CFrame.new(muzzlePosition.X, muzzlePosition.Y, 0)
end

function Turret:hasLineOfSight(character, offset)
	local result = workspace:Raycast(self.origin, offset, sightParams)
	return result == nil or result.Instance:IsDescendantOf(character)
end

function Turret:findTarget()
	local bestRoot, bestHumanoid, bestPlayer
	local bestDistance = self.range
	for _, player in Players:GetPlayers() do
		local character = player.Character
		local humanoid = character and character:FindFirstChildOfClass("Humanoid")
		local root = character and character:FindFirstChild("HumanoidRootPart")
		if humanoid and root and humanoid.Health > 0 then
			local offset = root.Position - self.origin
			local distance = offset.Magnitude
			if distance < bestDistance and self:hasLineOfSight(character, offset) then
				bestRoot, bestHumanoid, bestPlayer, bestDistance = root, humanoid, player, distance
			end
		end
	end
	return bestRoot, bestHumanoid, bestPlayer
end

function Turret:setTarget(root, humanoid, player)
	if root == self.target and root ~= nil then
		return
	end
	self.target, self.targetHumanoid, self.targetPlayer = root, humanoid, player
	self.model:SetAttribute(Settings.TargetAttribute, player and player.UserId or 0) -- The HUD reads this

	local color = root and COLORS.Alert or COLORS.Idle
	self.laser.Enabled = root ~= nil
	if self.eye then
		self.eye.Color = color
		local glow = self.eye:FindFirstChildOfClass("PointLight")
		if glow then
			glow.Color = color
		end
	end
end

function Turret:predictAimPoint(root)
	local origin = self.muzzle.WorldPosition
	local velocity = root.AssemblyLinearVelocity * FLAT
	local point = root.Position
	local travelTime = 0
	for _ = 1, TARGETING.PredictionPasses do
		travelTime = (point - origin).Magnitude / self.bulletSpeed
		point = root.Position + velocity * travelTime
	end
	return point - GRAVITY * 0.5 * travelTime * travelTime -- Aim up to cancel bullet drop
end

function Turret:isReadyToFire(now)
	if now - self.lastShot < self.fireInterval then
		return false
	end
	if self.spinParts and self.spinSpeed < SPIN.MaxSpeed * SPIN.FireThreshold then
		return false
	end
	return true
end

function Turret:fire(aimPoint, now)
	local effects = Settings.MuzzleEffects
	self.lastShot = now
	local origin = self.muzzle.WorldPosition
	fireBullet(origin, (aimPoint - origin).Unit * self.bulletSpeed, self.damage, self.style.BulletColor)
	self.recoil = Settings.Recoil.Distance
	self.fireSound:Play()
	self.sparks:Emit(effects.SparkCount)
	if self.flash then
		self.flash.Brightness = effects.FlashBrightness
		TweenService:Create(self.flash, FLASH_TWEEN, { Brightness = 0 }):Play()
	end
end

function Turret:updateSpin(dt)
	if not self.spinParts then
		return
	end
	local goal = self.target and SPIN.MaxSpeed or 0
	self.spinSpeed += (goal - self.spinSpeed) * (1 - math.exp(-SPIN.Response * dt))
	self.spinAngle = (self.spinAngle + self.spinSpeed * dt) % (math.pi * 2)

	local spin = self.spinAxis * CFrame.Angles(0, 0, self.spinAngle) * self.spinAxis:Inverse() -- Rotate around the barrel axis
	local swivelCFrame = self.swivel.CFrame
	for part, offset in self.spinParts do
		part.CFrame = swivelCFrame * spin * offset
	end
end

function Turret:updateLaser(now)
	if not self.style.ChargeLaser then
		return
	end
	local charge = math.clamp((now - self.lastShot) / self.fireInterval, 0, 1)
	local width = LASER.ChargeMinWidth + (LASER.ChargeMaxWidth - LASER.ChargeMinWidth) * charge
	self.laser.Width0 = width
	self.laser.Width1 = width
end

function Turret:update(dt, now)
	self.scanTimer -= dt
	if self.scanTimer <= 0 then
		self.scanTimer = TARGETING.ScanInterval
		self:setTarget(self:findTarget())
	end

	local desired
	local target = self.target
	if target and target.Parent and self.targetHumanoid.Health > 0 then
		local aimPoint = self:predictAimPoint(target)
		desired = CFrame.lookAt(self.origin, aimPoint)
		self.laserEnd.WorldPosition = target.Position
		local aligned = self.aimCFrame.LookVector:Dot(desired.LookVector) >= AIM_TOLERANCE
		if aligned and self:isReadyToFire(now) then
			self:fire(aimPoint, now)
		end
		self:updateLaser(now)
	else
		if target then
			self:setTarget(nil)
		end
		self.sweepTime += dt
		desired = self.restCFrame * CFrame.Angles(0, math.sin(self.sweepTime * Settings.IdleSweep.Speed) * SWEEP_ANGLE, 0)
	end

	self.aimCFrame = self.aimCFrame:Lerp(desired, 1 - math.exp(-self.turnSpeed * dt)) -- Smooth turning at any frame rate
	self.recoil *= math.exp(-Settings.Recoil.Recovery * dt)
	self.head:PivotTo(self.aimCFrame * CFrame.new(0, 0, self.recoil))
	self:updateSpin(dt)
end

function Turret:destroy()
	self:setTarget(nil)
	self.configConnection:Disconnect()
	if self.spinParts then
		local swivelCFrame = self.swivel.CFrame
		for part, offset in self.spinParts do
			part.CFrame = swivelCFrame * offset
		end
	end
	self.laser:Destroy()
	self.fireSound:Destroy()
	self.sparks:Destroy()
	self.laserEnd:Destroy()
end

local turrets = {}

local function register(model)
	if turrets[model] or not model:IsDescendantOf(workspace) then
		return
	end
	turrets[model] = Turret.new(model)
end

local function unregister(model)
	local turret = turrets[model]
	if turret then
		turret:destroy()
		turrets[model] = nil
	end
end

CollectionService:GetInstanceAddedSignal(Settings.Tag):Connect(register)
CollectionService:GetInstanceRemovedSignal(Settings.Tag):Connect(unregister)
for _, model in CollectionService:GetTagged(Settings.Tag) do
	register(model)
end

RunService.Heartbeat:Connect(function(dt)
	local now = os.clock()
	for _, turret in turrets do
		turret:update(dt, now)
	end
	updateBullets(dt) -- After turrets fire, so new bullets move this frame
end)
