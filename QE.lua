--!strict
-- EFR LeanController (multi-user safe)
-- Q/E  : 카메라+뷰모델 롤
-- Ctrl+: 카메라만 롤(뷰모델 수평 유지)
-- +2 studs 좌/우 이동, 멀티유저/중복 실행/우선순위 충돌 방지
-- 벽(측면 충돌) 감지 시 즉시 기본 자세로 복귀

if _G.__EFR_LEANCTRL_RUNNING then
	warn("[LeanController] duplicate detected; destroying this copy")
	script:Destroy()
	return
end
_G.__EFR_LEANCTRL_RUNNING = true

local Players   = game:GetService("Players")
local RunService= game:GetService("RunService")
local CAS       = game:GetService("ContextActionService")
local UIS       = game:GetService("UserInputService")
local Workspace = game:GetService("Workspace")

local player = Players.LocalPlayer
local userId = player.UserId

-- ===== 튜닝 =====
local LEAN_MAX_DEG     = 18     -- 기울기 강도
local LEAN_LERP        = 0.18   -- 회전 보간
local OFFSET_STUDS     = 2      -- 좌/우 이동량(+2)
local OFFSET_LERP      = 0.18   -- 이동 보간
local INV_SIGN         = 1      -- 회전 방향 반전(-1로 바꾸면 좌우 반대)
local INV_OFFSET_SIGN  = 1      -- 이동 방향 반전(-1로 바꾸면 좌우 반대)

-- 충돌(벽) 감지 파라미터
local WALL_MARGIN      = 0.20   -- 여유 거리
local WALL_MIN_CLEAR   = 0.10   -- 이 값보다 가까우면 충돌로 간주
local EPS              = 1e-4

local function cam(): Camera?
	return Workspace.CurrentCamera
end

-- 레이캐스트 파라미터(자기 캐릭터/카메라/뷰모델은 무시)
local function makeRCParams(): RaycastParams
	local params = RaycastParams.new()
	params.FilterType = Enum.RaycastFilterType.Exclude
	local list = {}
	if player.Character then table.insert(list, player.Character) end
	local c = cam()
	if c then table.insert(list, c) end
	params.FilterDescendantsInstances = list
	params.IgnoreWater = true
	return params
end

-- ===== 상태 =====
local targetRad = 0
local currRad   = 0
local offsetTarget = 0
local offsetCurr   = 0
local ctrlHeld  = false
local leftHeld  = false
local rightHeld = false

-- ===== 유틸 =====
local function iterViewModels(c: Camera?): {Model}
	local t = {}
	if not c then return t end
	for _, m in ipairs(c:GetChildren()) do
		if m:IsA("Model") then
			local n = string.lower(m.Name)
			if n:sub(1,3)=="vm_" or n:find("viewmodel",1,true) then
				table.insert(t, m)
			end
		end
	end
	return t
end

local function setTarget(sign: number)
	targetRad = math.rad(LEAN_MAX_DEG * sign * INV_SIGN)
end

local function refreshTarget()
	if leftHeld and not rightHeld then
		setTarget(1)
	elseif rightHeld and not leftHeld then
		setTarget(-1)
	else
		targetRad = 0
	end
end

local function resetState()
	leftHeld, rightHeld, ctrlHeld = false, false, false
	targetRad, offsetTarget = 0, 0
end

-- ===== 입력 =====
UIS.InputBegan:Connect(function(input, _)
	if input.KeyCode == Enum.KeyCode.LeftControl or input.KeyCode == Enum.KeyCode.RightControl then
		ctrlHeld = true
	end
end)
UIS.InputEnded:Connect(function(input)
	if input.KeyCode == Enum.KeyCode.LeftControl or input.KeyCode == Enum.KeyCode.RightControl then
		ctrlHeld = false
	end
end)
UIS.WindowFocusReleased:Connect(function()
	resetState()
end)

-- 멀티스크립트 충돌 방지: 액션/스텝 이름을 유저별로 네임스페이스
local ACTION_LEFT  = ("EFR_LeanLeft_%d"):format(userId)
local ACTION_RIGHT = ("EFR_LeanRight_%d"):format(userId)
local STEP_CAM     = ("EFR_LeanCam_%d"):format(userId)
local STEP_VM      = ("EFR_LeanVM_%d"):format(userId)

local function leanAction(actionName: string, state: Enum.UserInputState, _input: InputObject)
	-- 텍스트 입력 중이면 패스
	if UIS:GetFocusedTextBox() then
		return Enum.ContextActionResult.Pass
	end
	if state == Enum.UserInputState.Begin then
		if actionName == ACTION_LEFT then
			leftHeld = true
		elseif actionName == ACTION_RIGHT then
			rightHeld = true
		end
		refreshTarget()
		return Enum.ContextActionResult.Sink
	elseif state == Enum.UserInputState.End or state == Enum.UserInputState.Cancel then
		if actionName == ACTION_LEFT then
			leftHeld = false
		elseif actionName == ACTION_RIGHT then
			rightHeld = false
		end
		refreshTarget()
		return Enum.ContextActionResult.Sink
	end
	return Enum.ContextActionResult.Pass
end

-- 다른 스크립트와 공존을 위해 과도한 우선순위는 사용하지 않음
CAS:BindAction(ACTION_LEFT,  leanAction, false, Enum.KeyCode.Q)
CAS:BindAction(ACTION_RIGHT, leanAction, false, Enum.KeyCode.E)

-- ===== 측면 충돌 감지 =====
-- sign: +1(왼쪽), -1(오른쪽) ? setTarget에서 쓰는 부호와 동일
local function isSideObstructed(sign: number): boolean
	local c = cam()
	if not c then return false end
	local right = c.CFrame.RightVector
	local dir = right * (-sign * OFFSET_STUDS * INV_OFFSET_SIGN)
	local len = math.abs(OFFSET_STUDS) + WALL_MARGIN
	if dir.Magnitude < EPS then return false end
	local result = Workspace:Raycast(c.CFrame.Position, dir.Unit * len, makeRCParams())
	if not result then return false end
	if result.Instance and result.Instance:IsA("BasePart") and result.Instance.CanCollide then
		return result.Distance <= (math.abs(OFFSET_STUDS) - WALL_MIN_CLEAR + WALL_MARGIN)
	end
	return false
end

-- ===== 키 상태 폴링(키업 누락 방지) =====
local function refreshHeldFromKeyboard()
	leftHeld  = UIS:IsKeyDown(Enum.KeyCode.Q)
	rightHeld = UIS:IsKeyDown(Enum.KeyCode.E)
	ctrlHeld  = UIS:IsKeyDown(Enum.KeyCode.LeftControl) or UIS:IsKeyDown(Enum.KeyCode.RightControl)
	refreshTarget()
end

-- ===== 적용 =====
pcall(function()
	RunService:UnbindFromRenderStep(STEP_CAM)
	RunService:UnbindFromRenderStep(STEP_VM)
end)

local CAM_PRIORITY = Enum.RenderPriority.Camera.Value + 1
local VM_PRIORITY  = CAM_PRIORITY + 1

RunService:BindToRenderStep(STEP_CAM, CAM_PRIORITY, function()
	local c = cam()
	if not c then return end

	-- UI/Scriptable 카메라 상태면 강제로 복귀
	local uiLock = (_G and ((_G.DialogueActive == true) or (_G.InventoryOpen == true))) or false
	local camLocked = (c.CameraType ~= Enum.CameraType.Custom)
	if uiLock or camLocked then
		resetState()
	else
		-- 이벤트 누락 방지: 실제 키 상태로 동기화
		refreshHeldFromKeyboard()
	end

	-- 벽 감지: 현재 입력 방향 기준으로 충돌이면 즉시 기본 자세로
	if leftHeld and not rightHeld then
		if isSideObstructed(1) then targetRad, offsetTarget = 0, 0 end
	elseif rightHeld and not leftHeld then
		if isSideObstructed(-1) then targetRad, offsetTarget = 0, 0 end
	end

	-- 회전 보간
	currRad = currRad + (targetRad - currRad) * LEAN_LERP
	if math.abs(currRad) < EPS then currRad = 0 end

	-- 좌/우 이동(+2): 현재 기울기 비율에 따라 선형 스케일
	local maxRad = math.rad(LEAN_MAX_DEG)
	local progress = (maxRad > EPS) and (currRad / maxRad) or 0 -- [-1,1]
	offsetTarget = (-progress) * OFFSET_STUDS * INV_OFFSET_SIGN
	offsetCurr   = offsetCurr + (offsetTarget - offsetCurr) * OFFSET_LERP
	if math.abs(offsetCurr) < EPS then offsetCurr = 0 end

	-- 카메라 CFrame: 위치는 RightVector로 offsetCurr, 시선 유지, 그리고 Z-롤
	local base = c.CFrame
	local pos  = base.Position + base.RightVector * offsetCurr
	local look = base.LookVector
	local noRoll = CFrame.new(pos, pos + look)
	c.CFrame = noRoll * CFrame.Angles(0, 0, currRad)
end)

RunService:BindToRenderStep(STEP_VM, VM_PRIORITY, function()
	local c = cam()
	if not c then return end

	-- UI/고정 중에는 뷰모델도 건드리지 않음
	local uiLock = (_G and ((_G.DialogueActive == true) or (_G.InventoryOpen == true))) or false
	local camLocked = (c.CameraType ~= Enum.CameraType.Custom)
	if uiLock or camLocked then return end
	if math.abs(currRad) < EPS then return end

	-- Ctrl+Q/E → 뷰모델 따라가지 않음(카메라 롤 상쇄)
	-- 일반 Q/E → 뷰모델 따라감(카메라 롤과 동일)
	local rollCF = ctrlHeld and CFrame.Angles(0, 0, -currRad) or CFrame.new()
	local ccf = c.CFrame

	for _, vm in ipairs(iterViewModels(c)) do
		local pivot = vm:GetPivot()
		local rel = ccf:ToObjectSpace(pivot)
		vm:PivotTo((ccf * rollCF) * rel)
	end
end)

-- 리스폰/캐릭터 교체 시 상태 안정화
local function onCharacter(_char: Model)
	resetState()
	task.defer(function()
		currRad, offsetCurr = 0, 0
	end)
end

if player.Character then onCharacter(player.Character) end
player.CharacterAdded:Connect(onCharacter)

-- 정리
script.Destroying:Connect(function()
	pcall(function()
		RunService:UnbindFromRenderStep(STEP_CAM)
		RunService:UnbindFromRenderStep(STEP_VM)
		CAS:UnbindAction(ACTION_LEFT)
		CAS:UnbindAction(ACTION_RIGHT)
	end)
	_G.__EFR_LEANCTRL_RUNNING = nil
end)
