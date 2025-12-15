--!strict
-- StarterPlayerScripts/MovementEFT.client.lua
-- EFT풍 무브먼트: "관성 최소화 + 스탠스 + ADS 슬로우 + 과적 가속저하"
-- - Shift 스프린트/스태미나는 기존 Stamina.lua가 처리
-- - Q/E Lean은 QE.lua가 처리
-- - 본 스크립트는 수평 속도 XY를 하드 캡/가속 제어하여 '똑 떨어지는' 손맛 구현

local Players = game:GetService("Players")
local RunService = game:GetService("RunService")
local UIS = game:GetService("UserInputService")
local TweenService = game:GetService("TweenService")

local player = Players.LocalPlayer
local character = player.Character or player.CharacterAdded:Wait()
local humanoid: Humanoid = character:WaitForChild("Humanoid") :: Humanoid
local hrp: BasePart = character:WaitForChild("HumanoidRootPart") :: BasePart

-- ===== 튜닝(필요시만 만져) =====
local SNAP_STOP_TIME = 0.06           -- 키 떼고 완정지에 걸리는 목표 시간(짧을수록 '관성 거의 0')
local BASE_ACCEL = 220                 -- 기본 가속(Stud/s^2). 과적일수록 자동 감소
local MIN_ACCEL  = 120                 -- 과적 최악일 때도 이 값 밑으로는 안 떨어지게
local ADS_SLOW_MULT = 0.72             -- 우클릭(ADS) 시 이동속도 배율
local STANCE = { STAND=1, CROUCH=2, PRONE=3 }
local STANCE_SPEED_MULT = {
	[STANCE.STAND]  = 1.00,
	[STANCE.CROUCH] = 0.62,   -- EFT 느낌의 웅크림
	[STANCE.PRONE]  = 0.26,   -- EFT 느낌의 엎드림
}
local STANCE_CAM_Y = {
	[STANCE.STAND]  = 0.00,
	[STANCE.CROUCH] = -1.20,
	[STANCE.PRONE]  = -2.80,
}
local STANCE_TWEEN = TweenInfo.new(0.12, Enum.EasingStyle.Sine, Enum.EasingDirection.Out)

-- 내부 상태
local stance = STANCE.STAND
local camOffsetY = 0
local uiLock = false

-- 텍스트 입력/인벤토리 등 UI 잠금 추적(네가 쓰는 _G 플래그도 존중)
local function isUILocked(): boolean
	if UIS:GetFocusedTextBox() then return true end
	local g = _G
	if g and (g.InventoryOpen == true or g.DialogueActive == true) then return true end
	return false
end

-- 스탠스 전환(카메라 오프셋만; 충돌 박스는 건드리지 않음 → 안전/호환)
local camTween: Tween? = nil
local function applyStance(newStance: number)
	if stance == newStance then return end
	stance = newStance
	local targetY = STANCE_CAM_Y[stance] or 0
	if camTween then camTween:Cancel() end
	camTween = TweenService:Create(humanoid, STANCE_TWEEN, { CameraOffset = Vector3.new(0, targetY, 0) })
	camTween:Play()
end

-- 입력: C=토글 웅크림, Z=토글 엎드림, Space 시 엎드림→서기, 웅크림 점프 시 자동 서기
UIS.InputBegan:Connect(function(input, gpe)
	if gpe or isUILocked() then return end
	if input.KeyCode == Enum.KeyCode.C then
		if stance == STANCE.CROUCH then applyStance(STANCE.STAND) else applyStance(STANCE.CROUCH) end
	elseif input.KeyCode == Enum.KeyCode.Z then
		if stance == STANCE.PRONE then applyStance(STANCE.STAND) else applyStance(STANCE.PRONE) end
	elseif input.KeyCode == Enum.KeyCode.Space then
		if stance == STANCE.PRONE then
			applyStance(STANCE.STAND)
		elseif stance == STANCE.CROUCH then
			-- 웅크림 상태에서 점프 요청 시 자연스럽게 서기
			applyStance(STANCE.STAND)
		end
	end
end)

-- 리스폰 안정화
local function bindChar(char: Model)
	character = char
	humanoid = character:WaitForChild("Humanoid") :: Humanoid
	hrp = character:WaitForChild("HumanoidRootPart") :: BasePart
	applyStance(STANCE.STAND)
end
player.CharacterAdded:Connect(bindChar)

-- 유틸: 수평 성분만 교체
local function setHorizontalVelocity(targetV: Vector3)
	local cur = hrp.AssemblyLinearVelocity
	hrp.AssemblyLinearVelocity = Vector3.new(targetV.X, cur.Y, targetV.Z)
end

-- 과적 비율(0~1): StatsService가 Attribute로 뿌려줌
local function overweightRatio(): number
	local v = player:GetAttribute("OverweightRatio")
	return (typeof(v)=="number") and math.clamp(v,0,1) or 0
end

-- ADS 추정: RMB 눌림 여부(네 뷰모델 스크립트는 CAS 바인딩으로 ADS, 여기선 ‘눌림’만 감지)
local function adsHeld(): boolean
	return UIS:IsMouseButtonPressed(Enum.UserInputType.MouseButton2)
end

-- 메인 루프: 관성 제거 + 목표 속도 캡 + 가속 제어
RunService.RenderStepped:Connect(function(dt)
	if not character or not humanoid or humanoid.Health <= 0 then return end
	uiLock = isUILocked()
	if uiLock then return end

	-- 1) 현재 WalkSpeed는 Stamina.lua가 '걷기/달리기/과적' 종합 반영해서 세팅 중
	--    → 우리는 그 값을 기반으로 스탠스/ADS만 추가로 덮어쓴 목표속도를 만든다.
	local baseSpeed = humanoid.WalkSpeed  -- 이미 과적/스태미나 적용됨
	local stanceMult = STANCE_SPEED_MULT[stance] or 1
	local adsMult = adsHeld() and ADS_SLOW_MULT or 1
	local targetSpeed = baseSpeed * stanceMult * adsMult

	-- 2) 목표 수평 벡터
	local dir = humanoid.MoveDirection
	local want = dir.Magnitude > 0.01 and (dir.Unit * targetSpeed) or Vector3.zero

	-- 3) 가속 성능: 과적일수록 낮아짐(시동이 묵직), 감속은 항상 '스냅'에 가깝게
	local ow = overweightRatio() -- 0~1
	local accel = math.max(MIN_ACCEL, BASE_ACCEL * (1 - 0.55 * ow))

	-- 4) 현재 수평 속도
	local v = hrp.AssemblyLinearVelocity
	local v2 = Vector3.new(v.X, 0, v.Z)

	if want.Magnitude < 0.01 then
		-- 입력 없음 → 'SNAP_STOP_TIME' 안에 0으로 만들어줌 (관성 거의 0)
		if v2.Magnitude > 0 then
			local decelPerSec = (v2.Magnitude / math.max(dt, 1e-4)) -- 초당으로 환산
			-- 즉시 0으로 날리는 대신, dt 동안 목표 0에 꽤 세게 수렴
			local k = math.clamp(dt / SNAP_STOP_TIME, 0, 1)
			local newV2 = v2 * (1 - k)
			setHorizontalVelocity(newV2)
		end
	else
		-- 이동 입력 중 → 가속 제한 아래에서 목표 속도로 수렴
		local dv = want - v2
		local maxStep = accel * dt
		local step = (dv.Magnitude <= maxStep) and dv or (dv.Unit * maxStep)
		local newV2 = v2 + step

		-- 속도 캡(과도한 가속/쏠림 방지)
		if newV2.Magnitude > targetSpeed then
			newV2 = newV2.Unit * targetSpeed
		end
		setHorizontalVelocity(newV2)
	end

	-- 엎드림 상태에서 스프린트 금지 느낌을 조금 더: WalkSpeed가 높게 와도 하드캡
	if stance == STANCE.PRONE then
		local vv = hrp.AssemblyLinearVelocity
		local flat = Vector3.new(vv.X,0,vv.Z)
		local cap = targetSpeed * 1.02
		if flat.Magnitude > cap then
			setHorizontalVelocity(flat.Unit * cap)
		end
	end
end)
 	