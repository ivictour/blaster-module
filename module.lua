local TurretModule = {}
TurretModule.__index = TurretModule
local Players = game:GetService("Players")
local Debris = game:GetService("Debris")
local RunService = game:GetService("RunService")
local Workspace = game:GetService("Workspace")
local GRAVITY = Vector3.new(0, -Workspace.Gravity, 0)
local bulletPool = {} -- pool for reusing bullets to reduce creation overhead
-- create a turret instance from  turret model and settings
-- turret model  has a base and a barrel part
function TurretModule.new(turretModel, config)
	local self = setmetatable({}, TurretModule)
	self.Model = turretModel
	self.Base = turretModel:WaitForChild("Base")
	self.Barrel = turretModel:WaitForChild("Barrel")
	self.Config = config or {}
	self.Config.DetectionRange = self.Config.DetectionRange or 50
	self.Config.FireRate = self.Config.FireRate or 2
	self.Config.Damage = self.Config.Damage or 20
	self.Config.ProjectileSpeed = self.Config.ProjectileSpeed or 100
	self.Config.ProjectileLifetime = self.Config.ProjectileLifetime or 5
	self.Config.ProjectileBounce = self.Config.ProjectileBounce or 2
	-- owner is stored as the player  so the turret does not target the one who spawned it (its owner) 
	self.Owner = self.Config.Owner
	self.Projectiles = {} -- table to store active projectiles fired by  turret
	self.LastFireTime = 0 -- used to track when the turret last fired
	self.Target = nil -- current target the turret is aiming at
	self.State = "idle" -- state of the turret
	self.Active = true -- flag to check if turret is active
	return self
end
--  changes the turret state 
function TurretModule:SetState(state)
	self.State = state
end
--  begins the turret loop 
function TurretModule:Start()
	self.Running = true
	self.UpdateConn = RunService.Heartbeat:Connect(function(dt)
		self:Update(dt)
	end)
end
--  disconnects the heartbeat connection stopping the loop
function TurretModule:Stop()
	self.Running = false
	if self.UpdateConn then
		self.UpdateConn:Disconnect()
	end
end
-- called every frame to perform tasks such as scanning for targets aiming and firing
function TurretModule:Update(dt)
	-- scan the workspace for a target within detection range
	self:ScanForTarget()
	if self.Target then
		-- change turret state to tracking when a target is found
		self:SetState("tracking")
		-- if the target has a hrp use predicive targeting to lead the shot
		if self.Target:FindFirstChild("HumanoidRootPart") then
			local intercept = self:CalculateInterceptPoint(self.Target)
			local desiredCF = CFrame.new(self.Barrel.Position, intercept)
			-- smoothly interpolate barrel orientation toward the predicted intercept using lerp
			self.Barrel.CFrame = self.Barrel.CFrame:Lerp(desiredCF, dt * 5)
		else
			-- fallback to aiming directly at target if predictive targeting is not possible
			self:AimAtTarget(self.Target, dt)
		end
		-- check fire rate timer to decide if turret can fire another shot
		if tick() - self.LastFireTime >= self.Config.FireRate then
			self:FireProjectile()
			self.LastFireTime = tick()
			self:SetState("firing")
		end
	else
		-- no target found so turret remains idle
		self:SetState("idle")
	end
	-- update all active projectiles 
	self:UpdateProjectiles(dt)
end
--  searches the workspace for the closest model with a humanoid and a hrp
--  skips the turret owner's character so that the turret does not attack its owner
function TurretModule:ScanForTarget()
	local closest, minDist = nil, self.Config.DetectionRange
	for _, model in ipairs(Workspace:GetDescendants()) do
		if model:IsA("Model") and model:FindFirstChildOfClass("Humanoid") and model:FindFirstChild("HumanoidRootPart") then
			if self.Owner and model == self.Owner.Character then
				-- skip turret owner's character
			else
				local dist = (model.HumanoidRootPart.Position - self.Base.Position).Magnitude
				if dist < minDist then
					minDist = dist
					closest = model
				end
			end
		end
	end
	self.Target = closest
end
-- rotates the turret barrel toward the target using linear interpolation 
function TurretModule:AimAtTarget(target, dt)
	if target and target:FindFirstChild("HumanoidRootPart") then
		local desiredCF = CFrame.new(self.Barrel.Position, target.HumanoidRootPart.Position)
		self.Barrel.CFrame = self.Barrel.CFrame:Lerp(desiredCF, dt * 5)
	end
end
-- uses the target's velocity to predict where the shot should go to intercept the target
function TurretModule:CalculateInterceptPoint(target)
	local hrp = target:FindFirstChild("HumanoidRootPart")
	if not hrp then
		return self.Barrel.Position
	end
	local targetPos = hrp.Position
	local targetVel = hrp.Velocity
	local dist = (targetPos - self.Barrel.Position).Magnitude
	-- timeToReach is calculated by dividing the distance by projectile speed
	local timeToReach = dist / self.Config.ProjectileSpeed
	return targetPos + targetVel * timeToReach
end
-- retrieves a bullet from the pool if available or creates a new one to reduce overhead
function TurretModule:GetBullet()
	if #bulletPool > 0 then
		local bullet = table.remove(bulletPool)
		bullet.Parent = Workspace
		return bullet
	else
		local bullet = Instance.new("Part")
		bullet.Size = Vector3.new(0.3, 0.3, 0.3)
		bullet.Color = Color3.new(1, 1, 0)
		bullet.Material = Enum.Material.Neon
		bullet.Shape = Enum.PartType.Ball
		bullet.Anchored = false
		bullet.CanCollide = false
		bullet.Name = "Bullet"
		return bullet
	end
end
--  puts the bullet back into the pool for reuse
function TurretModule:ReturnBullet(bullet)
	bullet.Parent = nil
	table.insert(bulletPool, bullet)
end
-- uses the object pool to get or create a bullet and sets its position to the barrel
function TurretModule:CreateBullet()
	local bullet = self:GetBullet()
	bullet.CFrame = CFrame.new(self.Barrel.Position)
	bullet.Parent = Workspace
	return bullet
end
-- creates a new projectile from the turret barrel and plays the fire sound from the turret model 
function TurretModule:FireProjectile()
	local origin = self.Barrel.Position
	local dir = self.Barrel.CFrame.LookVector
	local bullet = self:CreateBullet()
	-- check for sound and play it 
	if self.Model:FindFirstChild("Fire") and self.Model.Fire:IsA("Sound") then
		self.Model.Fire:Play()
	end
	local proj = {
		Part = bullet,
		Position = origin,
		Velocity = dir * self.Config.ProjectileSpeed,
		Damage = self.Config.Damage,
		Lifetime = self.Config.ProjectileLifetime,
		StartTime = tick(),
		BounceCount = 0,
		MaxBounces = self.Config.ProjectileBounce,
	}
	table.insert(self.Projectiles, proj)
end
-- simulates the flight of each projectile using Euler integration and handles collision detection and bouncing
function TurretModule:UpdateProjectiles(dt)
	for i = #self.Projectiles, 1, -1 do
		local proj = self.Projectiles[i]
		if tick() - proj.StartTime >= proj.Lifetime then
			self:DestroyProjectile(proj)
		else
			local oldPos = proj.Position
			-- calculate new position based on current velocity and gravity
			local newPos = oldPos + proj.Velocity * dt + 0.5 * GRAVITY * (dt^2)
			proj.Velocity = proj.Velocity + GRAVITY * dt
			local rayDir = newPos - oldPos
			local rayParams = RaycastParams.new()
			rayParams.FilterType = Enum.RaycastFilterType.Exclude
			local filters = {proj.Part}
			rayParams.FilterDescendantsInstances = filters
			local rayResult = Workspace:Raycast(oldPos, rayDir, rayParams)
			if rayResult then
				-- collision detected update projectile position to collision point
				proj.Position = rayResult.Position
				proj.Part.CFrame = CFrame.new(rayResult.Position)
				local hit = rayResult.Instance
				local character = hit.Parent
				local hitDamageable = false
				-- if the hit object has a humanoid then it is damageable
				if character and character:FindFirstChildOfClass("Humanoid") then
					hitDamageable = true
					local humanoid = character:FindFirstChildOfClass("Humanoid")
					humanoid:TakeDamage(proj.Damage)
					local hrp = character:FindFirstChild("HumanoidRootPart")
					if hrp then
						-- push target in the same direction as bullet 
						local pushDir = (proj.Velocity).Unit
						local bv = Instance.new("BodyVelocity")
						bv.Velocity = pushDir * 5
						bv.MaxForce = Vector3.new(1e5, 1e5, 1e5)
						bv.Parent = hrp
						Debris:AddItem(bv, 0.5)
						-- add red outline effect using a highlight to indicate a hit
						local highlight = Instance.new("Highlight")
						highlight.FillColor = Color3.new(1, 0, 0)
						highlight.OutlineColor = Color3.new(1, 0, 0)
						highlight.Parent = character
						Debris:AddItem(highlight, 1)
					end
				end
				if hitDamageable then
					self:DestroyProjectile(proj)
				elseif proj.BounceCount < proj.MaxBounces then
					proj.BounceCount = proj.BounceCount + 1
					local normal = rayResult.Normal
					-- reflect projectile  off surface to simulate bounce
					local reflected = proj.Velocity - 2 * proj.Velocity:Dot(normal) * normal
					local newVel = reflected * 0.8
					if newVel.Magnitude > proj.Velocity.Magnitude then
						newVel = newVel.Unit * proj.Velocity.Magnitude
					end
					proj.Velocity = newVel
					proj.Position = rayResult.Position + normal * 0.5
				else
					self:DestroyProjectile(proj)
				end
			else
				proj.Position = newPos
				proj.Part.CFrame = CFrame.new(newPos)
			end
		end
	end
end
-- removes a projectile and returns its bullet to the pool
function TurretModule:DestroyProjectile(proj)
	if proj.Part then
		proj.Part:Destroy()
	end
	for i = #self.Projectiles, 1, -1 do
		if self.Projectiles[i] == proj then
			table.remove(self.Projectiles, i)
			break
		end
	end
end
--  merges new settings values into the turret's settings
function TurretModule:Upgrade(upgradeConfig)
	for k, v in pairs(upgradeConfig) do
		self.Config[k] = v
	end
end
--  stops the turret loop and cleans up all projectiles then removes the turret model from the world
function TurretModule:Shutdown()
	self:Stop()
	for i = #self.Projectiles, 1, -1 do
		self:DestroyProjectile(self.Projectiles[i])
	end
	if self.Model then
		self.Model:Destroy()
	end
	self.Active = false
end
-- returns a table of positions showing the predicted path of a projectile for debugging
function TurretModule:GetProjectileTrajectory(proj, steps, dt)
	steps = steps or 20
	dt = dt or 0.1
	local traj = {}
	local pos = proj.Position
	local vel = proj.Velocity
	for i = 1, steps do
		pos = pos + vel * dt + 0.5 * GRAVITY * (dt^2)
		vel = vel + GRAVITY * dt
		table.insert(traj, pos)
	end
	return traj
end
--  creates markers along the predicted path for debugging purposes
function TurretModule:DrawTrajectory(proj, steps, dt)
	local traj = self:GetProjectileTrajectory(proj, steps, dt)
	for i, pos in ipairs(traj) do
		local marker = Instance.new("Part")
		marker.Size = Vector3.new(0.2, 0.2, 0.2)
		marker.Shape = Enum.PartType.Ball
		marker.CFrame = CFrame.new(pos)
		marker.Anchored = true
		marker.CanCollide = false
		marker.Transparency = 0.5
		marker.Parent = Workspace
		Debris:AddItem(marker, 3)
	end
end
return TurretModule
