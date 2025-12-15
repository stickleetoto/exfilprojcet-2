--!strict
-- ReplicatedStorage/ViewmodelController.lua
-- 카메라 반동 + ADS(FOV 조절) 전담 모듈.
-- 기본 카메라 스크립트가 계산한 CFrame 위에 덮어씌우는 구조라
-- 다른 시스템과 충돌을 최소화한다.

local RunService = game:GetService("RunService")
local Workspace = game:GetService("Workspace")

local camera = Workspace.CurrentCamera

export type RecoilSpec = {
	pitchUp: number,      -- 위로 튀는 각도(도 단위)
	returnTime: number,   -- 복구 시간(초) 0.1~0.2 정도
	randomYaw: number,    -- 좌우 랜덤 (도)
	randomRoll: number,   -- 롤링 랜덤 (도)
	viewKickScale: number -- 시각적 강도(곱셈 계수, 1이면 기본)
}

local DEFAULT_RECOIL: RecoilSpec = {
	pitchUp = 2,
	returnTime = 0.15,
	randomYaw = 1.5,
	randomRoll = 1.0,
	viewKickScale = 1.0,
}

local DEFAULT_FOV = 70
local ADS_FOV = 55
local ADS_LERP_SPEED = 12 -- 값 클수록 빠르게 줌

local recoilPitch = 0.0
local recoilYaw = 0.0
local recoilRoll = 0.0
local currentReturnTime = DEFAULT_RECOIL.returnTime

local adsAlpha = 0.0
local adsTarget = 0.0
local isAiming = false

local BIND_NAME = "EFR_CameraRecoil"
local BIND_PRIORITY = Enum.RenderPriority.Camera.Value + 1

local function getCamera(): Camera?
	if camera and camera ~= Workspace.CurrentCamera then
		camera = Workspace.CurrentCamera
	end
	if not camera then
		camera = Workspace.CurrentCamera
	end
	return camera
end

local function step(dt: number)
	local cam = getCamera()
	if not cam then return end

	-- FOV ADS 보간
	local lerpT = math.clamp(dt * ADS_LERP_SPEED, 0, 1)
	adsAlpha = adsAlpha + (adsTarget - adsAlpha) * lerpT
	local fov = DEFAULT_FOV + (ADS_FOV - DEFAULT_FOV) * adsAlpha
	cam.FieldOfView = fov

	-- 반동 각도 복원 (단순 지수 감쇠)
	if currentReturnTime <= 0 then
		recoilPitch = 0
		recoilYaw = 0
		recoilRoll = 0
	else
		local decay = math.exp(-dt / currentReturnTime)
		recoilPitch *= decay
		recoilYaw   *= decay
		recoilRoll  *= decay
	end

	-- 기본 카메라 CFrame 에 반동 오프셋만 곱해준다.
	local baseCF = cam.CFrame
	if recoilPitch ~= 0 or recoilYaw ~= 0 or recoilRoll ~= 0 then
		local rx = math.rad(-recoilPitch) -- 위로 튀는 느낌이라 부호 뒤집기
		local ry = math.rad(recoilYaw)
		local rz = math.rad(recoilRoll)
		local recoilCF = CFrame.Angles(rx, ry, rz)
		cam.CFrame = baseCF * recoilCF
	end
end

RunService:BindToRenderStep(BIND_NAME, BIND_PRIORITY, step)

local M = {}

function M.Kick(spec: RecoilSpec?)
	local s = spec or DEFAULT_RECOIL

	-- 시야 반동 강도 스케일
	local scale = s.viewKickScale or 1.0

	local pitchUp = (s.pitchUp or DEFAULT_RECOIL.pitchUp) * scale
	local yawRand = (s.randomYaw or DEFAULT_RECOIL.randomYaw) * scale
	local rollRand = (s.randomRoll or DEFAULT_RECOIL.randomRoll) * scale

	recoilPitch += pitchUp
	recoilYaw   += (math.random() - 0.5) * 2 * yawRand
	recoilRoll  += (math.random() - 0.5) * 2 * rollRand

	currentReturnTime = s.returnTime > 0 and s.returnTime or DEFAULT_RECOIL.returnTime
end

function M.SetADS(on: boolean)
	isAiming = on
	adsTarget = on and 1.0 or 0.0
end

function M.IsADS(): boolean
	return isAiming
end

return M
