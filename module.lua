local BlasterModule = {}
BlasterModule.__index = BlasterModule
local Players = game:GetService("Players")
local Debris = game:GetService("Debris")
local RunService = game:GetService("RunService")
local Workspace = game:GetService("Workspace")
local GRAVITY = Vector3.new(0, -Workspace.Gravity, 0)
local bulletPool = {} -- pool to reuse bullets 
-- create a blaster from a blaster model and settings
-- the model will have a base and a barrel part
function BlasterModule.new(blasterModel, config)
	local self = setmetatable({}, BlasterModule)
	self.Model = blasterModel
	self.Base = blasterModel:WaitForChild("Base")
	self.Barrel = blasterModel:WaitForChild("Barrel")
	self.Config = config or {}
	-- detection range defines how far the blaster can detect targets
	self.Config.DetectionRange = self.Config.DetectionRange or 50
	-- fire rate is how fast the blaster fires
	self.Config.FireRate = self.Config.FireRate or 2
	-- damage applied by each blaster shot
	self.Config.Damage = self.Config.Damage or 20
	-- projectile speed determines how fast blaster shots travel
	self.Config.ProjectileSpeed = self.Config.ProjectileSpeed or 100
	-- lifetime is how long a projectile lasts before despawning
	self.Config.ProjectileLifetime = self.Config.ProjectileLifetime or 5
	-- projectile bounce is how many times a blaster shot can bounce off surfaces
	self.Config.ProjectileBounce = self.Config.ProjectileBounce or 2
	-- owner is stored so the blaster does not target the one who spawned it
	self.Owner = self.Config.Owner
	self.Projectiles = {} -- table to hold active projectiles
	self.LastFireTime = 0 -- timestamp for last shot fired
	self.Target = nil -- current target blaster is aiming at
	self.State = "idle" -- current state of blaster
	self.Active = true -- switch to indicate if the blaster is active
	return self
end
-- set the state of the blaster 
function BlasterModule:SetState(state)
	self.State = state
end
-- start the blaster loop by connecting to  heartbeat event
function BlasterModule:Start()
	self.Running = true
	self.UpdateConn = RunService.Heartbeat:Connect(function(dt)
		self:Update(dt)
	end)
end
-- stop the blaster loop by disconnecting  heartbeat connection
function BlasterModule:Stop()
	self.Running = false
	if self.UpdateConn then
		self.UpdateConn:Disconnect()
	end
end
--  runs every frame to scan for targets aim and fire as needed
function BlasterModule:Update(dt)
	-- scan the workspace for a target within range
	self:ScanForTarget()
	if self.Target then
		self:SetState("tracking")
		-- if target has a hrp use predictive targeting to lead the shot
		if self.Target:FindFirstChild("HumanoidRootPart") then
			local interceptPoint = self:CalculateInterceptPoint(self.Target)
			local desiredCF = CFrame.new(self.Barrel.Position, interceptPoint)
			self.Barrel.CFrame = self.Barrel.CFrame:Lerp(desiredCF, dt * 5)
		else
			self:AimAtTarget(self.Target, dt)
		end
		-- if enough time has passed based on fire rate then fire a projectile
		if tick() - self.LastFireTime >= self.Config.FireRate then
			self:FireProjectile()
			self.LastFireTime = tick()
			self:SetState("firing")
		end
	else
		self:SetState("idle")
	end
	-- update all projectiles in flight
	self:UpdateProjectiles(dt)
end
-- scan for the closest model with a humanoid and a hrp while ignoring the owner
function BlasterModule:ScanForTarget()
	local closest, minDist = nil, self.Config.DetectionRange
	for _, model in ipairs(Workspace:GetDescendants()) do
		if model:IsA("Model") and model:FindFirstChildOfClass("Humanoid") and model:FindFirstChild("HumanoidRootPart") then
			-- skip the blaster owner character so it does not target itself
			if self.Owner and model == self.Owner.Character then
				-- do nothing
			else
				local distance = (model.HumanoidRootPart.Position - self.Base.Position).Magnitude
				if distance < minDist then
					minDist = distance
					closest = model
				end
			end
		end
	end
	self.Target = closest
end
-- aim the barrel directly at the target using lerp for smooth motion
function BlasterModule:AimAtTarget(target, dt)
	if target and target:FindFirstChild("HumanoidRootPart") then
		local desiredCF = CFrame.new(self.Barrel.Position, target.HumanoidRootPart.Position)
		self.Barrel.CFrame = self.Barrel.CFrame:Lerp(desiredCF, dt * 5)
	end
end
-- calculate the intercept point using the target's current velocity and distance
function BlasterModule:CalculateInterceptPoint(target)
	local hrp = target:FindFirstChild("HumanoidRootPart")
	if not hrp then
		return self.Barrel.Position
	end
	local targetPosition = hrp.Position
	local targetVelocity = hrp.Velocity
	local distance = (targetPosition - self.Barrel.Position).Magnitude
	-- time to reach is estimated by dividing distance by projectile speed
	local timeToReach = distance / self.Config.ProjectileSpeed
	return targetPosition + targetVelocity * timeToReach
end
-- get a bullet from the pool if available or create a new one 
function BlasterModule:GetBullet()
	if #bulletPool > 0 then
		local bullet = table.remove(bulletPool)
		bullet.Parent = Workspace
		return bullet
	else
		local bullet = Instance.new("Part")
		bullet.Size = Vector3.new(0.3, 0.3, 0.3)
		-- using a distinct color so blaster shots are visible
		bullet.Color = Color3.new(0, 0.94902, 1)
		bullet.Material = Enum.Material.Neon
		bullet.Shape = Enum.PartType.Block
		bullet.Anchored = false
		bullet.CanCollide = false
		bullet.Name = "Bullet"
		return bullet
	end
end
-- return a bullet to the pool for reuse
function BlasterModule:ReturnBullet(bullet)
	bullet.Parent = nil
	table.insert(bulletPool, bullet)
end
-- create a shot at the barrel
function BlasterModule:CreateBullet()
	local bullet = self:GetBullet()
	bullet.CFrame = CFrame.new(self.Barrel.Position)
	bullet.Parent = Workspace
	return bullet
end
-- fire a projectile from the blaster barrel and play fire sound
function BlasterModule:FireProjectile()
	local origin = self.Barrel.Position
	local direction = self.Barrel.CFrame.LookVector
	local bullet = self:CreateBullet()
	-- if sound then play it
	if self.Model:FindFirstChild("Shoot") and self.Model.Shoot:IsA("Sound") then
		self.Model.Shoot:Play()
	end
	local proj = {
		Part = bullet,
		Position = origin,
		Velocity = direction * self.Config.ProjectileSpeed,
		Damage = self.Config.Damage,
		Lifetime = self.Config.ProjectileLifetime,
		StartTime = tick(),
		BounceCount = 0,
		MaxBounces = self.Config.ProjectileBounce,
	}
	table.insert(self.Projectiles, proj)
end
-- update active projectiles 
function BlasterModule:UpdateProjectiles(dt)
	for i = #self.Projectiles, 1, -1 do
		local proj = self.Projectiles[i]
		if tick() - proj.StartTime >= proj.Lifetime then
			self:DestroyProjectile(proj)
		else
			local oldPos = proj.Position
			-- calculate new position based on velocity and gravity
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
				-- if the hit model has a humanoid then it is damageable
				if character and character:FindFirstChildOfClass("Humanoid") then
					hitDamageable = true
					local humanoid = character:FindFirstChildOfClass("Humanoid")
					humanoid:TakeDamage(proj.Damage)
					local hrp = character:FindFirstChild("HumanoidRootPart")
					if hrp then
						-- push target in the direction as shot travel to simulate force
						local pushDir = (proj.Velocity).Unit
						local bv = Instance.new("BodyVelocity")
						bv.Velocity = pushDir * 5
						bv.MaxForce = Vector3.new(1e5, 1e5, 1e5)
						bv.Parent = hrp
						Debris:AddItem(bv, 0.5)
						-- add a purple outline to the target using a high light so the hit is visible
						local highlight = Instance.new("Highlight")
						highlight.FillColor = Color3.new(1, 0.219608, 0.933333)
						highlight.OutlineColor = Color3.new(1, 0.219608, 0.933333)
						highlight.Parent = character
						Debris:AddItem(highlight, 1)
					end
				end
				if hitDamageable then
					self:DestroyProjectile(proj)
				elseif proj.BounceCount < proj.MaxBounces then
					-- if projectile can bounce then reflect its velo off the surface
					proj.BounceCount = proj.BounceCount + 1
					local normal = rayResult.Normal
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
-- remove a projectile and return its bullet to the pool
function BlasterModule:DestroyProjectile(proj)
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
--  merges new setting values into the current blaster settings
function BlasterModule:Upgrade(upgradeConfig)
	for key, value in pairs(upgradeConfig) do
		self.Config[key] = value
	end
end
--  stops the blaster loop cleans up all projectiles and removes the blaster model
function BlasterModule:Shutdown()
	self:Stop()
	for i = #self.Projectiles, 1, -1 do
		self:DestroyProjectile(self.Projectiles[i])
	end
	if self.Model then
		self.Model:Destroy()
	end
	self.Active = false
end
-- get predicted trajectory of a projectile for debug
function BlasterModule:GetProjectileTrajectory(proj, steps, dt)
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
--  markers along the predicted trajectory for debug
function BlasterModule:DrawTrajectory(proj, steps, dt)
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
return BlasterModule
