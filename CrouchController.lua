--!strict
-- EFT-like Crouch(토글 C / 홀드 LeftCtrl / C+휠 미세조절)
-- 변경점: HipHeight/WalkSpeed/JumpPower는 서버가 적용 → 클라는 깊이 전송 + 카메라만 보정

if _G.__EFR_CROUCHCTRL_RUNNING then
	warn("[CrouchController] duplicate detected; destroying this copy")
	script:Destroy()
	return
end
_G.__EFR_CROUCHCTRL_RUNNING = true

local Players        = game:GetService("Players")
local UserInput      = game:GetService("UserInputService")
local RunService     = game:GetService("RunService")
local ContextAction  = game:GetService("ContextActionService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local player   = Players.LocalPlayer
local char     = player.Character or player.CharacterAdded:Wait()
local humanoid = char:WaitForChild("Humanoid") :: Humanoid

-- Remote
local Remotes   = ReplicatedStorage:WaitForChild("Remotes")
local CrouchRE  = Remotes:WaitForChild("EFR_CrouchDepth") :: RemoteEvent

-- ===== 튜닝(서버와 값 일치 권장) =====
local CAMERA_Y_OFFSET   = -0.9
local LERP              = 0.18
local DEPTH_STEP        = 0.1
local MIN_DEPTH         = 0.0
local MAX_DEPTH         = 1.0

local toggleKey = Enum.KeyCode.C


-- 내부 상태
local targetDepth = 0.0
local currentDepth = 0.0
local holdCrouch = false

-- 서버 전송 스로틀
local lastSentDepth = -1
local lastSentT = 0.0
local function sendDepthNow(d: number, force: boolean?)
	local t = os.clock()
	if not force and (t - lastSentT) < 0.05 and math.abs(d - lastSentDepth) < 0.02 then
		return
	end
	lastSentT = t
	lastSentDepth = d
	CrouchRE:FireServer(d)
end

-- 천장 체크(로컬 감각용, 최종 권위는 서버)
local function canStandLocal(): boolean
	local head = char:FindFirstChild("Head") :: BasePart?
	if not head then return true end
	-- 대략적인 여유만 검사(클라 감각)
	local rise = currentDepth * 1.4 + 0.15
	local ray = workspace:Raycast(head.Position, Vector3.new(0, rise, 0))
	return ray == nil
end

-- 공개 훅
function _G.SetCrouchDepth(d: number)
	targetDepth = math.clamp(d, MIN_DEPTH, MAX_DEPTH)
	sendDepthNow(targetDepth, true)
end
function _G.GetCrouchDepth(): number
	return targetDepth
end
function _G.IsCrouched(): boolean
	return targetDepth > 0.05
end

-- 입력
local ACTION_TOGGLE = "EFR_Crouch_Toggle"
local ACTION_HOLD   = "EFR_Crouch_Hold"

local function onToggle(_, state, _io)
	if state ~= Enum.UserInputState.Begin then return Enum.ContextActionResult.Pass end
	if targetDepth > 0.05 then
		if canStandLocal() then
			targetDepth = 0.0
		else
			targetDepth = math.max(targetDepth, 0.2)
		end
	else
		targetDepth = 1.0
	end
	sendDepthNow(targetDepth, true)
	return Enum.ContextActionResult.Sink
end

ContextAction:BindAction(ACTION_TOGGLE, onToggle, false, toggleKey)


-- 휠 미세조절(C 누르고 있을 때)
UserInput.InputChanged:Connect(function(io)
	if io.UserInputType ~= Enum.UserInputType.MouseWheel then return end
	if not UserInput:IsKeyDown(toggleKey) then return end
	local delta = io.Position.Z
	if delta == 0 then return end
	local step = DEPTH_STEP * (delta > 0 and -1 or 1)
	targetDepth = math.clamp(targetDepth + step, MIN_DEPTH, MAX_DEPTH)
	-- 기립 근처면 로컬 천장 체크
	if targetDepth <= 0.05 and not canStandLocal() then
		targetDepth = 0.2
	end
	sendDepthNow(targetDepth, false)
end)

-- 리스폰 대비
player.CharacterAdded:Connect(function(c)
	char = c
	humanoid = c:WaitForChild("Humanoid") :: Humanoid
end)

-- 메인 루프: 카메라 오프셋만 로컬 보간(서버는 신체값 적용)
RunService.RenderStepped:Connect(function(dt)
	currentDepth = currentDepth + (targetDepth - currentDepth) * math.clamp(LERP, 0.05, 0.35)
	local camY = CAMERA_Y_OFFSET * currentDepth
	local co = humanoid.CameraOffset
	if math.abs(co.Y - camY) > 1e-3 then
		humanoid.CameraOffset = Vector3.new(0, camY, 0)
	end
end)

_G.__EFR_CROUCHCTRL_UNBIND = function()
	pcall(function() ContextAction:UnbindAction(ACTION_TOGGLE) end)
	pcall(function() ContextAction:UnbindAction(ACTION_HOLD) end)
	_G.__EFR_CROUCHCTRL_RUNNING = nil
end
