-- current blaster module script

--[[
	Author: ivictour
	Date updated: march 22, 2025
	Description: 
		This module's purpose is to give functionality to blasters in the game.
		It handles (not in order): projectile creation and physics,
								   target selection,
								   custom settings for each blaster,
								   damage calculations,
								   hit visualization,
								   sound handling,
								   bullet pooling to reduce lag,
								   blaster state handling,
								   some debugging methods,
								   error handling.
]]

-- set the __index metamethod 
-- this simulates a class in lua, allowing us to manage multiple blasters, each with their own state and custom settings
local Blaster = {}
Blaster.__index = Blaster

-- get needed services
local Players = game:GetService("Players")
local Debris = game:GetService("Debris")
local RunService = game:GetService("RunService")
local Workspace = game:GetService("Workspace")

-- define a gravity vector based on the workspace gravity, this is used in the physics calculations so that the projectile motion is realistic
local GRAVITY = Vector3.new(0, -Workspace.Gravity, 0)

-- bulletPool is a table used to store and reuse bullet parts instead of creating new ones each time, reducing lag
local bulletPool = {}

-- =====================================
-- bullet pooling and helper functions
-- =====================================

-- this method returns a bullet object from the pool or creates a new one if the pool is empty
function Blaster:GetBullet()
	if #bulletPool > 0 then
		-- remove and return the last bullet in the pool
		local bullet = table.remove(bulletPool)
		bullet.Parent = Workspace
		return bullet
	end
	-- create a new bullet if none are available
	local bullet = Instance.new("Part")
	bullet.Size = Vector3.new(0.3, 0.3, 0.3)
	-- a unique color is chosen so that the shot is easily visible in game
	bullet.Color = Color3.new(0, 0.94902, 1)
	bullet.Material = Enum.Material.Neon
	bullet.Shape = Enum.PartType.Block
	bullet.Anchored = false
	bullet.CanCollide = false
	bullet.Name = "Bullet"
	return bullet
end

-- this method returns a bullet back to the pool so it can be reused
function Blaster:ReturnBullet(bullet)
	bullet.Parent = nil
	table.insert(bulletPool, bullet)
end

-- this method gets a bullet and sets its position to match the blaster barrel
function Blaster:CreateBullet()
	local bullet = self:GetBullet()
	bullet.CFrame = CFrame.new(self.Barrel.Position)
	bullet.Parent = Workspace
	return bullet
end

--=====================================
-- constructor and initialization
--=========================================

-- this method acts as a constructor to create a new blaster instance
-- the model must have a base and a barrel part
function Blaster.new(blasterModel, config)
	local self = setmetatable({}, Blaster)
	self.Model = blasterModel
	-- ensure the model has the necessary parts
	self.Base = blasterModel:FindFirstChild("Base")
	self.Barrel = blasterModel:FindFirstChild("Barrel")
	
	if not self.Base or not self.Barrel then
		error("Blaster model missing essential parts (Base or Barrel)")
	end
	self.Config = config or {}
	-- detection range defines how far the blaster can detect targets in studs
	self.Config.DetectionRange = self.Config.DetectionRange or 50
	-- fire rate is the minimum interval between shots in seconds
	self.Config.FireRate = self.Config.FireRate or 2
	-- damage per shot applied to targets
	self.Config.Damage = self.Config.Damage or 20
	-- projectile speed defines how fast shots travel
	self.Config.ProjectileSpeed = self.Config.ProjectileSpeed or 100
	-- projectile lifetime in seconds before it despawns
	self.Config.ProjectileLifetime = self.Config.ProjectileLifetime or 5
	-- maximum bounces allowed for a projectile before it is destroyed
	self.Config.ProjectileBounce = self.Config.ProjectileBounce or 2
	-- owner is stored to ensure the blaster does not target the one who spawned it
	self.Owner = self.Config.Owner
	self.Projectiles = {} -- table to hold active projectiles fired by this blaster
	self.LastFireTime = 0 -- timestamp used to control fire rate
	self.Target = nil -- the current target the blaster is aiming at
	self.State = "idle" -- possible states are idle, tracking, or firing
	self.Active = true -- flag indicating if the blaster is active
	return self
end

--===================================================
-- state management and loop control
--======================================

-- this method updates the current state, useful for debugging and behavior
function Blaster:SetState(state)
	self.State = state
end

-- this method begins the blaster loop by connecting to the heartbeat event
-- the heartbeat loop is a technique to run logic every frame
function Blaster:Start()
	self.Running = true
	self.UpdateConn = RunService.Heartbeat:Connect(function(dt)
		self:Update(dt)
	end)
end

-- this method disconnects the heartbeat connection, which stops the update loop
function Blaster:Stop()
	self.Running = false
	if self.UpdateConn then
		self.UpdateConn:Disconnect()
	end
end

--====================================
-- main update loop and target selection
--==========================================

-- this method is called every frame and does the following:
-- - scan for targets nearby
-- - aim using predictive targeting if possible
-- - fire projectiles if the fire rate timer allows
-- - update the positions of all active projectiles using basic physics
function Blaster:Update(dt)
	if not self.Model or not self.Model.Parent then
		self:Shutdown()
		return
	end
	self:ScanForTarget()
	if self.Target then
		self:SetState("tracking")
		-- if the target has a humanoid root part, use predictive targeting to account for possible target movement
		if self.Target:FindFirstChild("HumanoidRootPart") then
			local interceptPoint = self:CalculateInterceptPoint(self.Target)
			local desiredCF = CFrame.new(self.Barrel.Position, interceptPoint)
			-- lerp is used to smoothly rotate the barrel toward the target
			self.Barrel.CFrame = self.Barrel.CFrame:Lerp(desiredCF, dt * 5)
		else
			self:AimAtTarget(self.Target, dt)
		end
		-- check if the time since the last shot exceeds the fire rate
		-- if so, fire a projectile and set the state accordingly, while also updating the last fire time
		if os.clock() - self.LastFireTime >= self.Config.FireRate then
			self:FireProjectile()
			self.LastFireTime = os.clock()
			self:SetState("firing")
		end
	else
		-- since there's no target, we must be idle
		self:SetState("idle")
	end
	-- update projectiles
	self:UpdateProjectiles(dt)
end

-- this method scans for targets using GetPartBoundsInRadius
function Blaster:ScanForTarget()
	local overlapParams = OverlapParams.new()
	-- exclude the owner's character if available to avoid self targeting
	if self.Owner and self.Owner.Character then
		overlapParams.FilterDescendantsInstances = {self.Owner.Character}
	else
		overlapParams.FilterDescendantsInstances = {}
	end
	overlapParams.FilterType = Enum.RaycastFilterType.Exclude

	-- get parts in a sphere around the base position
	local parts = Workspace:GetPartBoundsInRadius(self.Base.Position, self.Config.DetectionRange, overlapParams)
	local models = {}
	-- use a for loop to store unique models that have a humanoid and humanoid root part
	for _, part in ipairs(parts) do
		local model = part.Parent
		if model and model:IsA("Model") and model:FindFirstChildOfClass("Humanoid") and model:FindFirstChild("HumanoidRootPart") then
			models[model] = true
		end
	end
	-- determine the closest model by iterating over the models table
	local closest, minDistance = nil, self.Config.DetectionRange
	for model, _ in pairs(models) do
		local hrp = model:FindFirstChild("HumanoidRootPart")
		if hrp then
			local d = (hrp.Position - self.Base.Position).Magnitude
			if d < minDistance then
				minDistance = d
				closest = model
			end
		end
	end
	self.Target = closest
end

-- this method rotates the barrel directly at the target using a lerp 
function Blaster:AimAtTarget(target, dt)
	if target and target:FindFirstChild("HumanoidRootPart") then
		-- if the target isn't nil and has a humanoid root part, set the barrel's rotation to look at the target
		local desiredCF = CFrame.new(self.Barrel.Position, target.HumanoidRootPart.Position)
		self.Barrel.CFrame = self.Barrel.CFrame:Lerp(desiredCF, dt * 5)
	end
end

--=======================================================================
-- predictive targeting and physics helper functions
--=====================================================

-- this method calculates where the projectile should be aimed based on the target's velocity
-- it uses basic kinematics, timeToReach is estimated by dividing the distance by projectile speed,
-- then the target's velocity is multiplied by this time to predict the intercept position
function Blaster:CalculateInterceptPoint(target)
	local hrp = target:FindFirstChild("HumanoidRootPart")
	if not hrp then return self.Barrel.Position end
	local tPos = hrp.Position
	local tVel = hrp.Velocity
	local d = (tPos - self.Barrel.Position).Magnitude
	local timeToReach = d / self.Config.ProjectileSpeed
	return tPos + tVel * timeToReach
end

-- this method uses euler integration to compute new position and velocity
-- new position = old position + velocity * dt + half gravity * dt squared
function Blaster:CalculateProjectilePhysics(proj, dt)
	local newPos = proj.Position + proj.Velocity * dt + 0.5 * GRAVITY * (dt^2)
	local newVel = proj.Velocity + GRAVITY * dt
	return newPos, newVel
end

-- this method does raycasting with error handling using pcall
function Blaster:PerformRaycast(startPos, endPos, ignorePart)
	local rayParams = RaycastParams.new()
	rayParams.FilterType = Enum.RaycastFilterType.Exclude
	rayParams.FilterDescendantsInstances = {ignorePart}
	local success, result = pcall(function()
		return Workspace:Raycast(startPos, endPos - startPos, rayParams)
	end)
	if not success then
		warn("raycast error occurred in projectile update: ", result)
		return nil
	end
	return result
end

--=========================================
-- firing and projectile simulation
--===============================================

-- this method creates a projectile at the barrel and plays the fire sound
function Blaster:FireProjectile()
	local origin = self.Barrel.Position
	local direction = self.Barrel.CFrame.LookVector
	local bullet = self:CreateBullet()
	-- check and play the fire sound from the model if it exists
	if self.Model:FindFirstChild("Fire") and self.Model.Fire:IsA("Sound") then
		self.Model.Fire:Play()
	end
	-- set up projectile configurations for this blaster
	local proj = {
		Part = bullet,
		Position = origin,
		Velocity = direction * self.Config.ProjectileSpeed,
		Damage = self.Config.Damage,
		Lifetime = self.Config.ProjectileLifetime,
		StartTime = os.clock(),
		BounceCount = 0,
		MaxBounces = self.Config.ProjectileBounce,
	}
	table.insert(self.Projectiles, proj)
end

-- this method checks if the hit object is damageable and applies damage and impact effects
function Blaster:HandleProjectileHit(proj, rayResult)
	local hit = rayResult.Instance
	local character = hit.Parent
	
	if not character then return false end
	
	if character:FindFirstChildOfClass("Humanoid") then
		local humanoid = character:FindFirstChildOfClass("Humanoid")
		if humanoid then
			humanoid:TakeDamage(proj.Damage)
		else
			warn("humanoid missing in character")
		end
		local hrp = character:FindFirstChild("HumanoidRootPart")
		if hrp then
			self:ApplyImpactEffects(character, proj.Velocity.Unit)
		end
		return true
	end
	return false
end

-- this method reflects the projectile velocity off the surface normal if bounces remain
function Blaster:HandleProjectileBounce(proj, rayResult)
	if proj.BounceCount < proj.MaxBounces then
		proj.BounceCount = proj.BounceCount + 1
		local normal = rayResult.Normal
		local reflected = proj.Velocity - 2 * proj.Velocity:Dot(normal) * normal
		local newVel = reflected * 0.8
		if newVel.Magnitude > proj.Velocity.Magnitude then
			newVel = newVel.Unit * proj.Velocity.Magnitude
		end
		proj.Velocity = newVel
		proj.Position = rayResult.Position + normal * 0.5
		return true
	end
	return false
end

-- this method applies impact effects using linear velocity to push the target and adds a highlight for visualization
function Blaster:ApplyImpactEffects(character, direction)
	local hrp = character:FindFirstChild("HumanoidRootPart")
	if not hrp then return end
	-- linear velocity offers better control and stability than body velocity
	local attach = Instance.new("Attachment")
	attach.Parent = hrp
	local lv = Instance.new("LinearVelocity")
	lv.Attachment0 = attach
	lv.VectorVelocity = direction * 5
	lv.MaxForce = 1e5
	lv.Parent = hrp
	Debris:AddItem(lv, 0.5)
	Debris:AddItem(attach, 0.5)
	-- add a purple highlight to indicate a hit
	local highlight = Instance.new("Highlight")
	highlight.FillColor = Color3.new(1, 0.219608, 0.933333)
	highlight.OutlineColor = Color3.new(1, 0.219608, 0.933333)
	highlight.Parent = character
	Debris:AddItem(highlight, 1)
end

-- this method updates the positions of all active projectiles using our helper functions
function Blaster:UpdateProjectiles(dt)
	for i = #self.Projectiles, 1, -1 do
		local proj = self.Projectiles[i]
		if os.clock() - proj.StartTime >= proj.Lifetime then
			self:DestroyProjectile(proj)
		else
			local oldPos = proj.Position
			-- calculate new position and velocity using euler integration based on kinematics
			local newPos, newVel = self:CalculateProjectilePhysics(proj, dt)
			-- perform raycast to check for collision between oldPos and newPos
			local rayResult = self:PerformRaycast(oldPos, newPos, proj.Part)
			if rayResult then
				proj.Position = rayResult.Position
				proj.Part.CFrame = CFrame.new(rayResult.Position)
				-- if the hit is on a damageable target, handle impact
				if self:HandleProjectileHit(proj, rayResult) then
					self:DestroyProjectile(proj)
					-- if not and the projectile can bounce, handle bounce and update velocity and position accordingly
				elseif self:HandleProjectileBounce(proj, rayResult) then
					-- bounce handled
				else
					self:DestroyProjectile(proj)
				end
			else
				-- no collision detected, so update normally
				proj.Position = newPos
				proj.Velocity = newVel
				proj.Part.CFrame = CFrame.new(newPos)
			end
		end
	end
end

-- this method removes a projectile and returns its bullet to the pool for reuse
function Blaster:DestroyProjectile(proj)
	if proj.Part then
		proj.Part:Destroy()
	end
	-- iterate over projectiles to remove the record
	for i = #self.Projectiles, 1, -1 do
		if self.Projectiles[i] == proj then
			table.remove(self.Projectiles, i)
			break
		end
	end
end

---===============================================
-- additional methods for upgrades and shutdown
--=================================================

-- this method merges new settings into the current blaster config
function Blaster:Upgrade(newConfig)
	for key, value in pairs(newConfig) do
		self.Config[key] = value
	end
end

-- this method stops the blaster loop, cleans up projectiles, and removes the blaster model from the workspace
function Blaster:Shutdown()
	self:Stop()
	for i = #self.Projectiles, 1, -1 do
		self:DestroyProjectile(self.Projectiles[i])
	end
	if self.Model then
		self.Model:Destroy()
	end
	self.Active = false
end

---========================================================
-- debug methods
--==========================================================

-- this method returns a table of positions representing the predicted path of a projectile
function Blaster:GetProjectileTrajectory(proj, steps, dt)
	steps = steps or 20
	dt = dt or 0.1
	local traj = {}
	local pos = proj.Position
	local vel = proj.Velocity
	for i = 1, steps do
		-- calculation based on kinematics, newPos = pos + vel * dt + 0.5 * gravity * (dt^2)
		pos = pos + vel * dt + 0.5 * GRAVITY * (dt^2)
		vel = vel + GRAVITY * dt
		table.insert(traj, pos)
	end
	return traj
end

-- this method creates visual markers along the predicted trajectory for debugging
function Blaster:DrawTrajectory(proj, steps, dt)
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

-- finally, return the blaster table
return Blaster
