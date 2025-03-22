-- current blaster module script

--[[
	Author: Ivictor
	Date updated: March 22, 2025.
	Description: 
			This module's purpose is to give functionality to blasters in the game.
			It handles (not in order): projectile creation and physics,
									   Target selection,
						               Costum settings for each blaster,
						               Damage calculations,
						               Hit visualization,
						               Sound handling,
						               Bullet pooling to reduce lag,
						               Blaster state handling,
						               Some debugging methods,
						               Error handling
						               
						

]]

-- the following sets the __index metamethod for blaster
-- this lets blaster objects access the methods in the blaster table, hence simulating a class
-- classes let us effectively manage multiple blasters, each with their own state and custom settings
local Blaster = {}
Blaster.__index = Blaster

-- get needed services
local Players = game:GetService("Players")
local Debris = game:GetService("Debris")
local RunService = game:GetService("RunService")
local Workspace = game:GetService("Workspace")

-- define a gravity vector based on the workspace gravity; this is used in the physics calculations so that projectile motion is realistic
local GRAVITY = Vector3.new(0, -Workspace.Gravity, 0)

-- this is a table used to store and reuse bullet parts instead of creating new ones each time
local bulletPool = {} 

-- this method returns a bullet object from the pool or creates a new one if the pool is empty
function Blaster:GetBullet()
	if #bulletPool > 0 then
		-- remove and return the last bullet in the pool
		local bullet = table.remove(bulletPool)
		bullet.Parent = Workspace
		return bullet
	else
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

-- this method acts as a constructor to create a new blaster instance
function Blaster.new(blasterModel, config)
	local self = setmetatable({}, Blaster)
	self.Model = blasterModel
	-- ensures the model has the necessary parts 
	self.Base = blasterModel:WaitForChild("Base")
	self.Barrel = blasterModel:WaitForChild("Barrel")
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
	self.State = "idle" -- possible states are idle tracking or firing
	self.Active = true -- flag indicating if the blaster is active
	return self
end


-- this method simply updates the current state, this is useful for debugging and behavior
function Blaster:SetState(state)
	self.State = state
end

-- this method begins the blaster loop by connecting to the heartbeat event
-- The heartbeat loop is a technique to run logic every frame
function Blaster:Start()
	self.Running = true
	self.UpdateConn = RunService.Heartbeat:Connect(function(dt)
		self:Update(dt)
	end)
end

-- this method disconnects the heartbeat connection which stops the update loop
function Blaster:Stop()
	self.Running = false
	if self.UpdateConn then
		self.UpdateConn:Disconnect()
	end
end


-- this method is called every frame and does the following:
-- - scan for targets using a loop
-- - aim using predictive targeting if possible
-- - fire projectiles if the fire rate timer allows it
-- -  update the positions of all active projectiles using basic physics
function Blaster:Update(dt)
	self:ScanForTarget()
	if self.Target then
		self:SetState("tracking")
		-- if target has a hrp (humanoid root part) then predictive targeting is used to account for possible target movement
		if self.Target:FindFirstChild("HumanoidRootPart") then
			local interceptPoint = self:CalculateInterceptPoint(self.Target)
			local desiredCF = CFrame.new(self.Barrel.Position, interceptPoint)
			-- Lerp is used to smoothly rotate the barrel toward the target
			self.Barrel.CFrame = self.Barrel.CFrame:Lerp(desiredCF, dt * 5)
		else
			self:AimAtTarget(self.Target, dt)
		end
		-- check if the time since the last shot exceeds the fire rate
		-- if so, fire a projectile and set the state accordingly, while also updating last fire time
		if tick() - self.LastFireTime >= self.Config.FireRate then
			self:FireProjectile()
			self.LastFireTime = tick()
			self:SetState("firing")
		end
	else
		-- since theres no target, we must be idle
		self:SetState("idle")
	end
	-- update projectiles
	self:UpdateProjectiles(dt)
end

-- this method iterates over all models in the workspace to find the closest valid target
-- A  loop is used here because it effectively processes an array/list of objects
function Blaster:ScanForTarget()
	local closest, minDistance = nil, self.Config.DetectionRange
	for _, model in ipairs(Workspace:GetDescendants()) do
		-- check if the model has a humanoid and hrp, which would make it a valid target
		if model:IsA("Model") and model:FindFirstChildOfClass("Humanoid") and model:FindFirstChild("HumanoidRootPart") then
			-- skip the owner so the blaster does not target it's spawner
			if self.Owner and model == self.Owner.Character then
				-- do nothing 
			else
				-- calculate distance between the blaster and the target
				local d = (model.HumanoidRootPart.Position - self.Base.Position).Magnitude
				-- if the distance is within range, set it as the target
				-- if its not, then set the target to nil, since we cant see it anyway
				if d < minDistance then
					minDistance = d
					closest = model
				end
			end
		end
	end
	self.Target = closest
end

-- this mehod rotates the barrel directly at the target using a lerp for smooth movement
function Blaster:AimAtTarget(target, dt)
	if target and target:FindFirstChild("HumanoidRootPart") then
		-- if target isnt nil and target has a hrp, then set the barrels rotation to look at the target
		local desiredCF = CFrame.new(self.Barrel.Position, target.HumanoidRootPart.Position)
		self.Barrel.CFrame = self.Barrel.CFrame:Lerp(desiredCF, dt * 5)
	end
end


-- this method calculates where the projectile should be aimed based on the targets velocity
-- This method uses basic kinematics, timeToReach is estimated by dividing the distance by projectile speed,
-- then the targets velocity is multiplied by this time to predict the intercept position
function Blaster:CalculateInterceptPoint(target)
	local hrp = target:FindFirstChild("HumanoidRootPart")
	if not hrp then return self.Barrel.Position end
	local tPos = hrp.Position
	local tVel = hrp.Velocity
	local d = (tPos - self.Barrel.Position).Magnitude
	local timeToReach = d / self.Config.ProjectileSpeed
	return tPos + tVel * timeToReach
end


-- this method creates a projectile at the barrel and plays the fire sound
-- This method uses the CreateBullet method to get a bullet from the pool and then creates a projectile record
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
		StartTime = tick(),
		BounceCount = 0,
		MaxBounces = self.Config.ProjectileBounce,
	}
	table.insert(self.Projectiles, proj)
end

-- this method updates the positions of all active projectiles
-- it uses euler integration to estimate motion by calculating the following: newPos = oldPos + velocity * dt + 0.5 * gravity * (dt^2)
-- raycast is then used to check if the projectiles path collides with an object
-- we use pcall for raycasting, it is to catch errors so the script does not crash during unexpected issues
function Blaster:UpdateProjectiles(dt)
	-- iterate through blaster projectiles
	for i = #self.Projectiles, 1, -1 do
		local proj = self.Projectiles[i]
		-- if projectile is too old, destroy it
		if tick() - proj.StartTime >= proj.Lifetime then
			self:DestroyProjectile(proj)
		else
			-- if not , continue calculations
			local oldPos = proj.Position
			-- here we use euler integration to update position
			local newPos = oldPos + proj.Velocity * dt + 0.5 * GRAVITY * (dt^2)
			proj.Velocity = proj.Velocity + GRAVITY * dt
			-- calculate ray direction
			local rayDir = newPos - oldPos
			-- set up ray params to exclude the projectile itself
			local rayParams = RaycastParams.new()
			rayParams.FilterType = Enum.RaycastFilterType.Exclude
			local filters = {proj.Part}
			rayParams.FilterDescendantsInstances = filters

			-- attempt raycasting and use pcall to catch any errors during this process
			local success, rayResult = pcall(function()
				return Workspace:Raycast(oldPos, rayDir, rayParams)
			end)
			if not success then
				warn("Raycast error occurred in projectile update: ", rayResult)
				rayResult = nil
			end

			if rayResult then
				-- a collision was detected, update projectile position to the point of impact
				proj.Position = rayResult.Position
				proj.Part.CFrame = CFrame.new(rayResult.Position)
				local hit = rayResult.Instance
				local character = hit.Parent
				local hitDamageable = false
				-- if the hit object contains a humanoid then it is a valid target for damage
				if character and character:FindFirstChildOfClass("Humanoid") then
					hitDamageable = true
					local humanoid = character:FindFirstChildOfClass("Humanoid")
					if humanoid then
						-- use TakeDamage method of a humanoid instance to actually apply damage
						humanoid:TakeDamage(proj.Damage)
					else
						-- if for some reason the character has no humanoid we just push a warning
						warn("Humanoid missing in character")
					end
					local hrp = character:FindFirstChild("HumanoidRootPart")
					if hrp then
						-- use linear velocity to push the target in the same direction as the shot
						-- linear velocity allows us to apply controlled force predictivley with more customization capability 
						-- unlive body velocity which is depreciated
						local pushDir = (proj.Velocity).Unit -- calculate push direction
						local attach = Instance.new("Attachment") -- init an attatchment to be used for the lv
						attach.Parent = hrp -- create and parent it to the hrp
						local lv = Instance.new("LinearVelocity") -- init a linear velocity instance
						lv.Attachment0 = attach -- set its necessary configurations
						lv.VectorVelocity = pushDir * 5
						lv.MaxForce = 1e5
						lv.Parent = hrp
						Debris:AddItem(lv, 0.5) -- add the linear velocity to debris so it despawns on its own
						Debris:AddItem(attach, 0.5) -- do the same for the attachment 
						-- add a purple high light to the target to visualize a hit
						local highlight = Instance.new("Highlight")
						-- set its properties
						highlight.FillColor = Color3.new(1, 0.219608, 0.933333)
						highlight.OutlineColor = Color3.new(1, 0.219608, 0.933333)
						-- parent it to the character and add it to debris
						highlight.Parent = character
						Debris:AddItem(highlight, 1)
					end
				end
				-- if damage was applied, remove the projectile
				if hitDamageable then
					self:DestroyProjectile(proj)
					-- if the projectile can bounce, reflect its velocity off the surface using the surface normal
				elseif proj.BounceCount < proj.MaxBounces then
					proj.BounceCount = proj.BounceCount + 1
					local normal = rayResult.Normal
					local reflected = proj.Velocity - 2 * proj.Velocity:Dot(normal) * normal
					local newVel = reflected * 0.8
					-- this check prevents the projectile from gaining extra speed due to rounding errors
					if newVel.Magnitude > proj.Velocity.Magnitude then
						newVel = newVel.Unit * proj.Velocity.Magnitude
					end
					proj.Velocity = newVel
					proj.Position = rayResult.Position + normal * 0.5
				else
					self:DestroyProjectile(proj)
				end
			else
				-- if no collision was detected update projectile normally
				proj.Position = newPos
				proj.Part.CFrame = CFrame.new(newPos)
			end
		end
	end
end

-- this removes a projectile and returns its bullet to the pool for reuse
function Blaster:DestroyProjectile(proj)
	if proj.Part then
		proj.Part:Destroy()
	end
	-- iterate over the projectiles table using a loop to remove the projectile record
	for i = #self.Projectiles, 1, -1 do
		if self.Projectiles[i] == proj then
			table.remove(self.Projectiles, i)
			break
		end
	end
end

-- this method merges new configuration settings into the current blaster config
function Blaster:Upgrade(newConfig)
	for key, value in pairs(newConfig) do
		self.Config[key] = value
	end
end

-- this method stops the blaster loop, cleans up all projectiles and removes the blaster model from workspace
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

-- this method returns a table of positions that represent the predicted path of a projectile
function Blaster:GetProjectileTrajectory(proj, steps, dt)
	steps = steps or 20
	dt = dt or 0.1
	local traj = {}
	local pos = proj.Position
	local vel = proj.Velocity
	for i = 1, steps do
		-- the formula here is derived from physics: position = initial position + velocity * time + 0.5 * acceleration * time^2
		pos = pos + vel * dt + 0.5 * GRAVITY * (dt^2)
		vel = vel + GRAVITY * dt
		table.insert(traj, pos)
	end
	return traj
end

-- this method creates visual markers along the predicted trajectory for debugging 
-- this method uses a loop to create and display small parts along the calculated path
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
-- finally return the Blaster table
return Blaster
