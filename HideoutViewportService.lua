-- ReplicatedStorage/HideoutViewportService.lua
-- ViewportFrame 안에서 오빗(회전/줌/패닝) 3인칭을 제공하는 경량 모듈
-- 사용: local HVS = require(RS.HideoutViewportService)
--       local handle = HVS.Open(vpf, { minDist=2, maxDist=120, zoomSpeed=2.0, rotateSpeed=0.18, defaultPitchDeg=-20, defaultYawDeg=160 })
--       handle:Close()

local RunService = game:GetService("RunService")
local UserInputService = game:GetService("UserInputService")

local M = {}

-- 기본값
local function defaults(opts)
	opts = opts or {}
	return {
		-- 탐색 관련
		sourceModel = opts.sourceModel,                   -- 뷰포트에 복제할 소스(없으면 자동탐색)
		sourcePaths = opts.sourcePaths or {               -- 자동탐색 경로(순서대로 시도)
			"Workspace.HideoutPreview.Hideout",
			"Workspace.Hideout",
			"ReplicatedStorage.HideoutPreview.Hideout",
			"ReplicatedStorage.Hideout"
		},
		focusPartNames = opts.focusPartNames or { "hideoutview", "HideoutView", "HIDEOUTVIEW" },

		-- 카메라 프리셋
		fov = math.clamp(tonumber(opts.fov) or 70, 20, 120),
		defaultYawDeg = tonumber(opts.defaultYawDeg) or 160,      -- 좌/우
		defaultPitchDeg = tonumber(opts.defaultPitchDeg) or -15,  -- 위/아래(음수면 내려다봄)
		startDist = tonumber(opts.startDist),                     -- 없으면 bbox 기반으로 추정

		-- 한계/감도
		minDist = math.max(0.1, tonumber(opts.minDist) or 3.5),   -- 더 붙으려면 값 ↓
		maxDist = math.max(tonumber(opts.maxDist) or 60, 5),      -- 더 멀리 가려면 값 ↑
		zoomSpeed = math.max(0.05, tonumber(opts.zoomSpeed) or 1.3),
		rotateSpeed = math.max(0.01, tonumber(opts.rotateSpeed) or 0.18),   -- 마우스 이동에 대한 회전 감도
		rotateSpeedY = tonumber(opts.rotateSpeedY),               -- 세로 감도(없으면 rotateSpeed 사용)
		panSpeed = math.max(0.001, tonumber(opts.panSpeed) or 0.05),

		-- 제한각
		pitchMinDeg = tonumber(opts.pitchMinDeg) or -80,
		pitchMaxDeg = tonumber(opts.pitchMaxDeg) or 30,
		freeYaw = (opts.freeYaw == nil) and true or not not opts.freeYaw,   -- true면 Yaw 무제한
		yawMinDeg = tonumber(opts.yawMinDeg) or -180,
		yawMaxDeg = tonumber(opts.yawMaxDeg) or 180,
	}
end

-- 문자열 경로로 인스턴스 찾기
local function getByPath(path)
	local cur = game
	for seg in string.gmatch(path, "[^%.]+") do
		cur = cur:FindFirstChild(seg)
		if not cur then return nil end
	end
	return cur
end

-- 소스 모델/폴더 찾기
local function findSource(opts)
	if opts.sourceModel and opts.sourceModel.Parent then
		return opts.sourceModel
	end
	for _, p in ipairs(opts.sourcePaths) do
		local inst = getByPath(p)
		if inst then return inst end
	end
	return nil
end

-- 바운딩박스(AABB) 구하기(폴더/모델 모두 지원)
local function computeBounds(root)
	local minV, maxV
	for _, d in ipairs(root:GetDescendants()) do
		if d:IsA("BasePart") then
			local cf, size = d.CFrame, d.Size
			local corners = {
				cf * Vector3.new( size.X/2,  size.Y/2,  size.Z/2),
				cf * Vector3.new( size.X/2,  size.Y/2, -size.Z/2),
				cf * Vector3.new( size.X/2, -size.Y/2,  size.Z/2),
				cf * Vector3.new( size.X/2, -size.Y/2, -size.Z/2),
				cf * Vector3.new(-size.X/2,  size.Y/2,  size.Z/2),
				cf * Vector3.new(-size.X/2,  size.Y/2, -size.Z/2),
				cf * Vector3.new(-size.X/2, -size.Y/2,  size.Z/2),
				cf * Vector3.new(-size.X/2, -size.Y/2, -size.Z/2),
			}
			for _, v in ipairs(corners) do
				if not minV then
					minV, maxV = v, v
				else
					minV = Vector3.new(math.min(minV.X, v.X), math.min(minV.Y, v.Y), math.min(minV.Z, v.Z))
					maxV = Vector3.new(math.max(maxV.X, v.X), math.max(maxV.Y, v.Y), math.max(maxV.Z, v.Z))
				end
			end
		end
	end
	if not minV then
		return CFrame.new(), Vector3.new(16,16,16) -- 비상값
	end
	local size = maxV - minV
	local center = (minV + maxV) / 2
	return CFrame.new(center), size
end

local function findFocusCF(root, focusNames)
	for _, n in ipairs(focusNames) do
		local part = root:FindFirstChild(n, true)
		if part and part:IsA("BasePart") then
			return part:GetPivot()
		end
	end
	-- 없으면 전체 중앙
	local cf = computeBounds(root)
	return cf
end

-- 카메라 CFrame 계산
local function camCFrame(targetCF, yawDeg, pitchDeg, dist)
	local yaw = math.rad(yawDeg)
	local pitch = math.rad(pitchDeg)
	local rot = CFrame.Angles(0, yaw, 0) * CFrame.Angles(pitch, 0, 0)
	local look = rot.LookVector
	local focusPos = targetCF.Position
	local camPos = focusPos - look * dist
	return CFrame.new(camPos, focusPos)
end

-- WorldModel 생성(뷰포트용)
local function ensureWorld(vpf)
	local world = vpf:FindFirstChild("World")
	if not world then
		world = Instance.new("WorldModel")
		world.Name = "World"
		world.Parent = vpf
	end
	return world
end

function M.Open(vpf, opts)
	assert(typeof(vpf) == "Instance" and vpf:IsA("ViewportFrame"), "HVS.Open: ViewportFrame 필요")
	opts = defaults(opts)

	local world = ensureWorld(vpf)

	-- 소스 복제
	local src = findSource(opts)
	if not src then
		warn("[HVS] no source model (tried paths): ", table.concat(opts.sourcePaths, ", "))
	end

	local clone
	if src then
		clone = src:Clone()
		clone.Name = "Hideout"
		clone.Parent = world
	end

	-- 카메라 세팅
	local cam = Instance.new("Camera")
	cam.FieldOfView = opts.fov
	cam.Parent = world
	vpf.CurrentCamera = cam

	-- 타깃(집중점) CF
	local targetCF = clone and findFocusCF(clone, opts.focusPartNames) or CFrame.new()

	-- 바운드 기반 시작 거리
	local bboxCF, bboxSize = clone and computeBounds(clone) or CFrame.new(), Vector3.new(32,32,32)
	local diag = bboxSize.Magnitude
	local startDist = math.clamp(opts.startDist or (diag * 0.45), opts.minDist, opts.maxDist)

	-- 상태
	local state = {
		vpf = vpf,
		world = world,
		model = clone,
		camera = cam,
		targetCF = targetCF,
		dist = startDist,
		yawDeg = opts.defaultYawDeg,
		pitchDeg = math.clamp(opts.defaultPitchDeg, opts.pitchMinDeg, opts.pitchMaxDeg),
		opts = opts,
		conns = {},
		dragRMB = false,
		lastMouse = nil,
	}

	-- 입력 바인딩
	state.conns[#state.conns+1] = UserInputService.InputBegan:Connect(function(input, gpe)
		if gpe then return end
		if input.UserInputType == Enum.UserInputType.MouseButton2 then
			state.dragRMB = true
			state.lastMouse = UserInputService:GetMouseLocation()
		end
	end)

	state.conns[#state.conns+1] = UserInputService.InputEnded:Connect(function(input, gpe)
		if input.UserInputType == Enum.UserInputType.MouseButton2 then
			state.dragRMB = false
		end
	end)

	state.conns[#state.conns+1] = UserInputService.InputChanged:Connect(function(input, gpe)
		if gpe then return end
		-- 줌
		if input.UserInputType == Enum.UserInputType.MouseWheel then
			local delta = -input.Position.Z
			local speed = opts.zoomSpeed
			state.dist = math.clamp(state.dist + delta * -speed, opts.minDist, opts.maxDist)
		end
		-- 회전/패닝
		if input.UserInputType == Enum.UserInputType.MouseMovement and state.dragRMB then
			local pos = UserInputService:GetMouseLocation()
			local dx = pos.X - state.lastMouse.X
			local dy = pos.Y - state.lastMouse.Y
			state.lastMouse = pos

			if UserInputService:IsKeyDown(Enum.KeyCode.LeftShift) or UserInputService:IsKeyDown(Enum.KeyCode.RightShift) then
				-- 패닝은 타깃을 이동 (카메라가 아닌)
				local yaw = math.rad(state.yawDeg)
				local right = Vector3.new(math.cos(yaw), 0, -math.sin(yaw))
				local up = Vector3.new(0,1,0)
				local scale = (opts.panSpeed) * (state.dist * 0.1 + 1)
				state.targetCF = state.targetCF + CFrame.new((-right * dx + up * dy) * scale)
			else
				local rsX = opts.rotateSpeed
				local rsY = opts.rotateSpeedY or opts.rotateSpeed
				state.yawDeg = state.yawDeg - dx * rsX
				state.pitchDeg = math.clamp(state.pitchDeg - dy * rsY, opts.pitchMinDeg, opts.pitchMaxDeg)
				if not opts.freeYaw then
					state.yawDeg = math.clamp(state.yawDeg, opts.yawMinDeg, opts.yawMaxDeg)
				end
			end
		end
	end)

	-- 렌더 루프
	state.conns[#state.conns+1] = RunService.RenderStepped:Connect(function()
		cam.CFrame = camCFrame(state.targetCF, state.yawDeg, state.pitchDeg, state.dist)
	end)

	-- 핸들
	local closed = false
	local handle = {}

	function handle:SetYawPitch(yawDeg, pitchDeg)
		if closed then return end
		state.yawDeg = yawDeg or state.yawDeg
		state.pitchDeg = math.clamp(pitchDeg or state.pitchDeg, opts.pitchMinDeg, opts.pitchMaxDeg)
	end

	function handle:SetDist(dist)
		if closed then return end
		state.dist = math.clamp(dist, opts.minDist, opts.maxDist)
	end

	function handle:Close()
		if closed then return end
		closed = true
		for _, c in ipairs(state.conns) do pcall(function() c:Disconnect() end) end
		if state.model then state.model:Destroy() end
		if cam then cam:Destroy() end
		if state.world and #state.world:GetChildren() == 0 then state.world:Destroy() end
	end

	return handle
end

return M
