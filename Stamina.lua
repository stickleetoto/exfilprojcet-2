--!strict
-- ?? StarterPlayerScripts/StaminaController.client.lua
-- EFT식 스태미나: 인게임일 때만 바 표시(자동 페이드), 얇고 부드러운 전환
-- 레벨↑ → MaxStamina↑, 회복속도↑ (서버 파생치가 없을 때만 로컬 스케일)

-- Services
local Players           = game:GetService("Players")
local UserInputService  = game:GetService("UserInputService")
local RunService        = game:GetService("RunService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local TweenService      = game:GetService("TweenService")

-- Player/Character
local player    = Players.LocalPlayer
local character = player.Character or player.CharacterAdded:Wait()
local humanoid  = character:WaitForChild("Humanoid") :: Humanoid

-- ===== 기본 파라미터 =====
local BASE_MAX_STAMINA        = 100
local BASE_IDLE_REGEN_PER_SEC = 18
local BASE_WALK_REGEN_SCALE   = 0.55
local BASE_RUN_DRAIN_PER_SEC  = 20
local AIRBORNE_DRAIN_PER_SEC  = 8
local JUMP_COST_ONCE          = 5
local EXHAUST_COOLDOWN_SEC    = 1.5

local WALK_SPEED, RUN_SPEED   = 16, 28

-- 소비량→XP(옵션)
local XP_PER_STAMINA_SPENT    = 0.8
local XP_SEND_INTERVAL        = 0.30
local StatsAddXP: RemoteEvent? = ReplicatedStorage:FindFirstChild("Stats_AddXP") :: RemoteEvent?

-- ===== 레벨 스케일 파라미터(서버 파생치가 없을 때만 적용) =====
local END_LVL_ATTR        = "EnduranceLevel" -- 서버가 Endurance 레벨을 이 Attribute로 세팅한다고 가정
local END_LVL_DEFAULT     = 1
local MAX_STAMINA_PER_LVL = 5      -- 레벨당 MaxStamina +5
local REGEN_MULT_PER_LVL  = 0.02   -- 레벨당 회복속도 +2%
local MAX_LVL_CLAMP       = 100

-- ===== 상태 =====
local currentWalk, currentRun = WALK_SPEED, RUN_SPEED
local stamina: number         = BASE_MAX_STAMINA
local lastExhaustTime: number? = nil
local lastJumpTime            = 0
local isAirborne              = false

-- 연결 핸들
local jumpConn: RBXScriptConnection? = nil
local jumpPropConn: RBXScriptConnection? = nil
local jumpingBackupConn: RBXScriptConnection? = nil
local humanoidDiedConn: RBXScriptConnection? = nil

-- ===== UI(좌하단, 얇고 부드럽게 + 자동 페이드) =====
local screenGui = (function()
	local pg = player:WaitForChild("PlayerGui")
	local g = pg:FindFirstChild("HUD_Stamina")
	if not g then
		g = Instance.new("ScreenGui")
		g.Name = "HUD_Stamina"
		g.ResetOnSpawn = false
		g.IgnoreGuiInset = true
		g.Parent = pg
	end
	return g
end)()

local barBG: Frame? = nil
local bar: Frame? = nil
local displayedRatio = 1.0
local LERP_SPEED = 8 -- 클수록 빨리 따라감

local function ensureUI()
	if not screenGui then return end

	-- 기존 객체 있으면 재사용
	local existingBG = screenGui:FindFirstChild("StaminaBarBG")
	local existingBar = existingBG and existingBG:FindFirstChild("StaminaBar")
	if existingBG and existingBG:IsA("Frame") and existingBar and existingBar:IsA("Frame") then
		barBG = existingBG :: Frame
		bar   = existingBar :: Frame
		return
	end

	-- 새로 생성
	local bg = Instance.new("Frame")
	bg.Name = "StaminaBarBG"
	bg.AnchorPoint = Vector2.new(0,1)
	bg.Position = UDim2.new(0, 16, 1, -40)          -- ?? 왼쪽 아래
	bg.Size = UDim2.new(0.15, 0, 0, 8)              -- 얇게
	bg.BackgroundColor3 = Color3.fromRGB(40,40,40)
	bg.BackgroundTransparency = 0.3
	bg.BorderSizePixel = 0
	bg.ZIndex = 50
	bg.Parent = screenGui

	local corner = Instance.new("UICorner")
	corner.CornerRadius = UDim.new(0, 4)
	corner.Parent = bg

	local fill = Instance.new("Frame")
	fill.Name = "StaminaBar"
	fill.Size = UDim2.new(1, 0, 1, 0)
	fill.BackgroundColor3 = Color3.fromRGB(90,220,90)
	fill.BorderSizePixel = 0
	fill.ZIndex = 51
	fill.Parent = bg

	local fillCorner = Instance.new("UICorner")
	fillCorner.CornerRadius = UDim.new(0, 4)
	fillCorner.Parent = fill

	barBG, bar = bg, fill
end
ensureUI()

-- 페이드 상태
local HIDE_AFTER_IDLE = 1.0   -- 초: 이 시간 이상 “정지 + 풀스태미나”면 숨김
local fadeState = { idleT = 0, visible = true }

local function setBarVisible(v: boolean)
	if not barBG or not bar then return end
	if fadeState.visible == v then return end
	fadeState.visible = v
	-- 배경/바 둘 다 투명도 트윈
	pcall(function()
		TweenService:Create(barBG, TweenInfo.new(0.18), { BackgroundTransparency = v and 0.3 or 1 }):Play()
		TweenService:Create(bar,   TweenInfo.new(0.18), { BackgroundTransparency = v and 0   or 1 }):Play()
	end)
end

local function updateUI(ratio: number, dt: number)
	if not barBG or not bar then return end
	if not character or not humanoid or humanoid.Health <= 0 then
		setBarVisible(false)
		return
	end

	-- dt 기반 부드러운 보간
	local alpha = math.clamp(dt * LERP_SPEED, 0, 1)
	displayedRatio = math.clamp(displayedRatio + (ratio - displayedRatio) * alpha, 0, 1)

	bar.Size = UDim2.new(displayedRatio, 0, 1, 0)

	-- 색상 단계
	local c = (displayedRatio < 0.25) and Color3.fromRGB(220,60,60)
		or (displayedRatio < 0.5)  and Color3.fromRGB(220,200,60)
		or Color3.fromRGB(90,220,90)
	bar.BackgroundColor3 = c

	-- 자동 페이드: 정지 + 풀스태미나면 숨김 카운트
	local idle = humanoid.MoveDirection.Magnitude < 0.05
	if idle and displayedRatio >= 0.999 then
		fadeState.idleT += dt
	else
		fadeState.idleT = 0
	end
	setBarVisible(fadeState.idleT < HIDE_AFTER_IDLE)
end

-- ===== 서버 파생치/레벨 읽기 =====
local function numAttr(name: string, default: number): number
	local v = player:GetAttribute(name)
	return (typeof(v) == "number") and v or default
end

local function getEnduranceLevel(): number
	local lvl = numAttr(END_LVL_ATTR, END_LVL_DEFAULT)
	if lvl ~= lvl then lvl = END_LVL_DEFAULT end -- NaN 방지
	return math.clamp(lvl, 1, MAX_LVL_CLAMP)
end

local function readDerived()
	-- 서버가 파생치를 주는지 여부(중복 스케일 방지)
	local hasServerMax   = (player:GetAttribute("MaxStamina")   ~= nil)
	local hasServerRegen = (player:GetAttribute("StaminaRegen") ~= nil)

	local level = getEnduranceLevel()

	-- 최대 스태미나
	local baseMax = hasServerMax and numAttr("MaxStamina", BASE_MAX_STAMINA) or BASE_MAX_STAMINA
	local maxStamina = baseMax
	if not hasServerMax then
		maxStamina = baseMax + (MAX_STAMINA_PER_LVL * (level - 1))
	end

	-- 회복 속도
	local baseRegen = hasServerRegen and numAttr("StaminaRegen", BASE_IDLE_REGEN_PER_SEC) or BASE_IDLE_REGEN_PER_SEC
	local regen = baseRegen
	if not hasServerRegen then
		regen = baseRegen * (1 + REGEN_MULT_PER_LVL * (level - 1))
	end

	return {
		MaxStamina      = maxStamina,
		StaminaRegen    = regen,
		SprintDrainMult = numAttr("SprintDrainMult", 1),
		MoveSpeedMult   = numAttr("MoveSpeedMult",   1),
		MoveOverMult    = numAttr("MoveOverMult",    1),
		StamDrainOver   = numAttr("StaminaDrainOverMult", 1),
	}
end

-- ===== 입력 =====
local function isShiftDown(): boolean
	return UserInputService:IsKeyDown(Enum.KeyCode.LeftShift)
		or UserInputService:IsKeyDown(Enum.KeyCode.RightShift)
end

-- 점프 요청 시 차단(상태 비활성화 없이)
UserInputService.JumpRequest:Connect(function()
	if not humanoid then return end
	if stamina < JUMP_COST_ONCE then
		humanoid.Jump = false
	end
end)

UserInputService.InputBegan:Connect(function(input, _gp)
	if input.KeyCode == Enum.KeyCode.Space and stamina < JUMP_COST_ONCE and humanoid then
		humanoid.Jump = false
	end
end)

-- ===== 점프 게이트/바인딩 =====
local function applyJumpGate()
	if not humanoid then return end
	if stamina < JUMP_COST_ONCE then
		humanoid.Jump = false
	end
end

local function unbindCharacter()
	if jumpConn then jumpConn:Disconnect() jumpConn = nil end
	if jumpPropConn then jumpPropConn:Disconnect() jumpPropConn = nil end
	if jumpingBackupConn then jumpingBackupConn:Disconnect() jumpingBackupConn = nil end
end

local function bindJump(h: Humanoid)
	if jumpConn then jumpConn:Disconnect() jumpConn = nil end
	if jumpPropConn then jumpPropConn:Disconnect() jumpPropConn = nil end
	if jumpingBackupConn then jumpingBackupConn:Disconnect() jumpingBackupConn = nil end

	jumpConn = h.StateChanged:Connect(function(_, new)
		if new == Enum.HumanoidStateType.Jumping
			or new == Enum.HumanoidStateType.Freefall
			or new == Enum.HumanoidStateType.FallingDown then
			isAirborne = true
		elseif new == Enum.HumanoidStateType.Landed
			or new == Enum.HumanoidStateType.Running
			or new == Enum.HumanoidStateType.RunningNoPhysics
			or new == Enum.HumanoidStateType.Seated then
			isAirborne = false
		end

		if new == Enum.HumanoidStateType.Jumping then
			local now = time()
			if (now - lastJumpTime) > 0.2 then
				if stamina >= JUMP_COST_ONCE then
					stamina -= JUMP_COST_ONCE
					if stamina <= 0 then
						stamina = 0
						lastExhaustTime = now
					end
				else
					h.Jump = false
				end
				lastJumpTime = now
			end
		end
	end)

	jumpPropConn = h:GetPropertyChangedSignal("Jump"):Connect(function()
		if h.Jump and stamina < JUMP_COST_ONCE then
			h.Jump = false
		end
	end)

	jumpingBackupConn = h.Jumping:Connect(function(active)
		if not active then return end
		local now = time()
		if (now - lastJumpTime) > 0.2 then
			if stamina >= JUMP_COST_ONCE then
				stamina -= JUMP_COST_ONCE
				if stamina <= 0 then
					stamina = 0
					lastExhaustTime = now
				end
			else
				h.Jump = false
			end
			lastJumpTime = now
		end
	end)

	applyJumpGate()
end

local function bindCharacter(char: Model)
	unbindCharacter()
	character = char
	humanoid  = character:WaitForChild("Humanoid") :: Humanoid

	-- 리스폰 시 상태 초기화
	currentWalk, currentRun = WALK_SPEED, RUN_SPEED
	isAirborne = false
	stamina = readDerived().MaxStamina  -- ? 리스폰 시 현재 스태미나를 최대치로 세팅

	-- 이동속도 초기화
	if humanoid then humanoid.WalkSpeed = currentWalk end

	-- 점프/상태 바인딩
	bindJump(humanoid)

	-- UI 재보장
	ensureUI()
	setBarVisible(true)

	-- 이전 Died 연결 해제 후 재연결
	if humanoidDiedConn then humanoidDiedConn:Disconnect() humanoidDiedConn = nil end
	if humanoid then
		humanoidDiedConn = humanoid.Died:Connect(function()
			-- 죽는 순간에는 바를 감추기만 (루프는 다음 캐릭터에서 재개)
			setBarVisible(false)
		end)
	end
end

player.CharacterAdded:Connect(bindCharacter)
player.CharacterRemoving:Connect(function()
	unbindCharacter()
	if humanoidDiedConn then humanoidDiedConn:Disconnect() humanoidDiedConn = nil end
	character = nil
	humanoid  = nil
	-- 죽는 순간 바를 숨기되 ScreenGui는 남김 → 다음 스폰에서 재사용
	setBarVisible(false)
end)

-- 초기 보장
bindJump(humanoid)
applyJumpGate()
ensureUI()
setBarVisible(true)

-- ===== 속도/XP/루프 =====
local function setSpeed(speed: number)
	if not humanoid then return end
	-- 0.25 단위 스냅으로 변경 빈도↓
	local snapped = math.floor(speed * 4 + 0.5) / 4
	if math.abs(humanoid.WalkSpeed - snapped) >= 0.125 then
		humanoid.WalkSpeed = snapped
	end
end

local xpBuffer, xpSendAcc = 0, 0
local function sendXP(amount: number)
	if amount <= 0 then return end
	if StatsAddXP then
		pcall(function() (StatsAddXP :: RemoteEvent):FireServer("Endurance", amount) end)
	else
		player:SetAttribute("EnduranceXPLocal", numAttr("EnduranceXPLocal", 0) + amount)
	end
end

-- 공중 판정 보정(경사/짧은 Freefall 대응)
RunService.Heartbeat:Connect(function()
	if not humanoid then return end
	local airborne = humanoid.FloorMaterial == Enum.Material.Air
	if airborne ~= isAirborne then
		isAirborne = airborne
	end
end)

RunService.RenderStepped:Connect(function(dt)
	if not humanoid or humanoid.Health <= 0 then
		setBarVisible(false)
		return
	end

	local D = readDerived()
	local walkSpd = math.max(2, currentWalk  * D.MoveSpeedMult * D.MoveOverMult)
	local runSpd  = math.max(walkSpd + 1, currentRun * D.MoveSpeedMult * D.MoveOverMult)

	local moveMag     = humanoid.MoveDirection.Magnitude
	local sprintHeld  = isShiftDown()
	local isSprinting = sprintHeld and moveMag > 0.05 and stamina > 0

	local prev = stamina
	local maxStamina = D.MaxStamina

	if isSprinting then
		local drainMult = math.max(0.05, D.SprintDrainMult * D.StamDrainOver)
		stamina -= (BASE_RUN_DRAIN_PER_SEC * drainMult) * dt
		if stamina <= 0 then
			stamina = 0
			lastExhaustTime = time()
		end
	else
		local canRecover = true
		if stamina <= 0 and lastExhaustTime then
			canRecover = (time() - lastExhaustTime) >= EXHAUST_COOLDOWN_SEC
		end
		if canRecover then
			local regen = moveMag > 0.05 and (D.StaminaRegen * BASE_WALK_REGEN_SCALE) or D.StaminaRegen
			stamina += regen * dt
			if stamina >= maxStamina then
				stamina = maxStamina
				lastExhaustTime = nil
			end
		end
	end

	if isAirborne and stamina > 0 then
		stamina -= AIRBORNE_DRAIN_PER_SEC * dt
		if stamina <= 0 then
			stamina = 0
			lastExhaustTime = time()
		end
	end

	local spent = math.max(prev - stamina, 0)
	if spent > 0 then xpBuffer += (spent * XP_PER_STAMINA_SPENT) end
	xpSendAcc += dt
	if xpSendAcc >= XP_SEND_INTERVAL and xpBuffer > 0 then
		local grant = math.floor(xpBuffer)
		if grant > 0 then
			sendXP(grant)
			xpBuffer -= grant -- 남은 소수는 버퍼에 유지
		end
		xpSendAcc = 0
	end

	if stamina < 0 then stamina = 0 end
	if stamina > maxStamina then stamina = maxStamina end
	setSpeed(isSprinting and runSpd or walkSpd)
	applyJumpGate()

	-- ? dt 기반 부드러운 바 업데이트
	updateUI((maxStamina > 0) and (stamina / maxStamina) or 0, dt)
end)
