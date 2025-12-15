-- ReplicatedStorage/ViewportOrbitController.lua
-- Orbit(기본) + FreeCam(토글) 컨트롤러
local RunService = game:GetService("RunService")
local UserInputService = game:GetService("UserInputService")

local M = {}

local function getBounds(target)
	if typeof(target) == "Vector3" then
		return target, 6
	elseif typeof(target) == "CFrame" then
		return target.Position, 6
	elseif typeof(target) == "Instance" then
		if target:IsA("BasePart") then
			return target.Position, target.Size.Magnitude
		elseif target:IsA("Model") then
			local cf, size = target:GetBoundingBox()
			return cf.Position, size.Magnitude
		end
	end
	return Vector3.new(), 6
end

function M.Attach(viewport, target, opts)
	opts = opts or {}
	local self = {
		vpf = viewport,
		active = true,

		-- 공통 상태
		yaw = 0,
		pitch = -15,
		minPitch = opts.minPitch or -80,
		maxPitch = opts.maxPitch or  80,
		fov = opts.fov or 70,

		-- Orbit 모드
		dist = opts.dist,
		minDist = opts.minDist or 2,
		maxDist = opts.maxDist or 40,

		-- Free 모드
		mode = opts.startMode or "orbit", -- "orbit" | "free"
		camCF = nil,
		moveSpeed = opts.freeSpeed or 10,
		boostMul  = opts.freeBoost or 3,
		freeBoundsRadius = opts.freeBoundsRadius, -- 수치 있으면 반경 클램프
		keys = {W=false,A=false,S=false,D=false,Up=false,Down=false,Boost=false},

		-- 입력 감도
		rotSpeed = opts.rotSpeed or 0.25,
		zoomSpeed = opts.zoomSpeed or 2.0,
		panSpeed = opts.panSpeed or 0.02,

		dragging = false, -- RMB
		panning = false,  -- MMB
		worldRoot = opts.worldRoot,
		toggleFreeKey = opts.toggleFreeKey or Enum.KeyCode.F,

		focus = nil,
	}

	local focusPos, sizeMag = getBounds(target)
	self.focus = focusPos
	self.dist = self.dist or math.clamp(sizeMag * 0.6, self.minDist, self.maxDist)

	-- 카메라
	local cam = Instance.new("Camera")
	cam.FieldOfView = self.fov
	cam.Parent = viewport
	viewport.CurrentCamera = cam

	local function inside(vpf)
		local m = UserInputService:GetMouseLocation()
		local p, s = vpf.AbsolutePosition, vpf.AbsoluteSize
		return m.X >= p.X and m.X <= p.X + s.X and m.Y >= p.Y and m.Y <= p.Y + s.Y
	end

	-- ===== 업데이트 =====
	local lastDt = 1/60
	local function updateOrbit()
		local focus = self.focus
		local desired =
			CFrame.new(focus)
			* CFrame.Angles(0, math.rad(self.yaw), 0)
			* CFrame.Angles(math.rad(self.pitch), 0, 0)
			* CFrame.new(0, 0, self.dist)

		local pos = desired.Position

		--(선택) 간단 충돌 클램프
		if self.worldRoot and self.worldRoot.Raycast then
			local dir = pos - focus
			local params = RaycastParams.new()
			params.FilterType = Enum.RaycastFilterType.Exclude
			local hit = self.worldRoot:Raycast(focus, dir, params)
			if hit then
				pos = hit.Position + (focus - hit.Position).Unit * 0.25
			end
		end

		cam.CFrame = CFrame.new(pos, focus)
	end

	local function clampToSphere(p, center, r)
		if not r then return p end
		local off = p - center
		local mag = off.Magnitude
		if mag <= r then return p end
		return center + off.Unit * r
	end

	local function updateFree(dt)
		-- 초기 camCF 없으면 포커스 기준 생성
		if not self.camCF then
			local base =
				CFrame.new(self.focus)
				* CFrame.Angles(0, math.rad(self.yaw), 0)
				* CFrame.Angles(math.rad(self.pitch), 0, 0)
				* CFrame.new(0, 0, self.dist)
			self.camCF = CFrame.new(base.Position, self.focus)
		end

		local cf = self.camCF
		local f, r, u = cf.LookVector, cf.RightVector, cf.UpVector
		local v = Vector3.zero
		if self.keys.W     then v += f end
		if self.keys.S     then v -= f end
		if self.keys.A     then v -= r end
		if self.keys.D     then v += r end
		if self.keys.Up    then v += u end   -- Space
		if self.keys.Down  then v -= u end   -- Ctrl
		if v.Magnitude > 0 then v = v.Unit end

		local speed = self.moveSpeed * (self.keys.Boost and self.boostMul or 1)
		local delta = v * speed * dt
		local newPos = cf.Position + delta

		-- 경계(선택): 반경 클램프
		newPos = clampToSphere(newPos, self.focus, self.freeBoundsRadius)

		self.camCF = CFrame.new(newPos, newPos + f)
		cam.CFrame = self.camCF
	end

	local connRender = RunService.RenderStepped:Connect(function(dt)
		lastDt = dt
		if not self.active then return end
		if self.mode == "orbit" then
			updateOrbit()
		else
			updateFree(dt)
		end
	end)

	-- ===== 입력 =====
	local function onInputBegan(input, gpe)
		if gpe then return end
		if input.UserInputType == Enum.UserInputType.MouseButton2 and inside(viewport) then
			self.dragging = true
		elseif input.UserInputType == Enum.UserInputType.MouseButton3 and inside(viewport) then
			self.panning = true
		elseif input.KeyCode == self.toggleFreeKey and inside(viewport) then
			self.mode = (self.mode == "orbit") and "free" or "orbit"
		elseif self.mode == "free" then
			if input.KeyCode == Enum.KeyCode.W then self.keys.W = true
			elseif input.KeyCode == Enum.KeyCode.S then self.keys.S = true
			elseif input.KeyCode == Enum.KeyCode.A then self.keys.A = true
			elseif input.KeyCode == Enum.KeyCode.D then self.keys.D = true
			elseif input.KeyCode == Enum.KeyCode.Space then self.keys.Up = true
			elseif input.KeyCode == Enum.KeyCode.LeftControl then self.keys.Down = true
			elseif input.KeyCode == Enum.KeyCode.LeftShift then self.keys.Boost = true end
		end
	end

	local function onInputEnded(input, gpe)
		if input.UserInputType == Enum.UserInputType.MouseButton2 then
			self.dragging = false
		elseif input.UserInputType == Enum.UserInputType.MouseButton3 then
			self.panning = false
		elseif self.mode == "free" then
			if input.KeyCode == Enum.KeyCode.W then self.keys.W = false
			elseif input.KeyCode == Enum.KeyCode.S then self.keys.S = false
			elseif input.KeyCode == Enum.KeyCode.A then self.keys.A = false
			elseif input.KeyCode == Enum.KeyCode.D then self.keys.D = false
			elseif input.KeyCode == Enum.KeyCode.Space then self.keys.Up = false
			elseif input.KeyCode == Enum.KeyCode.LeftControl then self.keys.Down = false
			elseif input.KeyCode == Enum.KeyCode.LeftShift then self.keys.Boost = false end
		end
	end

	local function onInputChanged(input, gpe)
		if gpe then return end
		if input.UserInputType == Enum.UserInputType.MouseMovement and self.dragging then
			local d = input.Delta
			self.yaw   = self.yaw - d.X * self.rotSpeed
			self.pitch = math.clamp(self.pitch - d.Y * self.rotSpeed, self.minPitch, self.maxPitch)
			if self.mode == "free" and self.camCF then
				-- free: 카메라 자체 회전
				local pos = self.camCF.Position
				local cf =
					CFrame.new(pos)
					* CFrame.Angles(0, math.rad(self.yaw), 0)
					* CFrame.Angles(math.rad(self.pitch), 0, 0)
				self.camCF = cf
			end
		elseif input.UserInputType == Enum.UserInputType.MouseWheel and inside(viewport) then
			if self.mode == "orbit" then
				self.dist = math.clamp(self.dist - input.Position.Z * self.zoomSpeed, self.minDist, self.maxDist)
			else
				self.moveSpeed = math.clamp(self.moveSpeed + input.Position.Z, 1, 100)
			end
		elseif self.panning and input.UserInputType == Enum.UserInputType.MouseMovement and self.mode == "orbit" then
			local d = input.Delta
			local right = cam.CFrame.RightVector
			local up = cam.CFrame.UpVector
			self.focus = self.focus - (right * d.X + up * d.Y) * self.panSpeed * self.dist
		end
	end

	local c1 = UserInputService.InputBegan:Connect(onInputBegan)
	local c2 = UserInputService.InputEnded:Connect(onInputEnded)
	local c3 = UserInputService.InputChanged:Connect(onInputChanged)

	-- ===== API =====
	function self:Detach()
		self.active = false
		if connRender then connRender:Disconnect() end
		if c1 then c1:Disconnect() end
		if c2 then c2:Disconnect() end
		if c3 then c3:Disconnect() end
		if viewport.CurrentCamera == cam then viewport.CurrentCamera = nil end
		cam:Destroy()
	end

	function self:SetTarget(t)
		local p, sz = getBounds(t)
		self.focus = p
		if self.mode == "orbit" and sz then
			self.dist = math.clamp(sz * 0.6, self.minDist, self.maxDist)
		end
	end

	function self:SetYawPitchDist(y, p, d)
		if y then self.yaw = y end
		if p then self.pitch = math.clamp(p, self.minPitch, self.maxPitch) end
		if d then self.dist = math.clamp(d, self.minDist, self.maxDist) end
	end

	function self:SetMode(mode)
		if mode == self.mode then return end
		self.mode = mode
		if self.mode == "free" then
			self.camCF = nil -- 다음 프레임에 포커스 기준으로 초기화
		end
	end

	return self
end

return M
