--!strict
-- StarterPlayerScripts/MouseGovEnforcer.client.lua
-- 전역 마우스 거버넌스(최종판)
-- - _G.setMouseGov("unlock"|"lock") 호출만 하면, 코어 카메라 이후(Last) 프레임에 '최종 상태' 강제
-- - 기존에 약한 구현이 있어도 자동 wrap
-- - 중복 설치 방지

local RunService        = game:GetService("RunService")
local UserInputService  = game:GetService("UserInputService")
local Players           = game:GetService("Players")
local HttpService       = game:GetService("HttpService")

if typeof(_G) ~= "table" then _G = {} end
if _G.__MouseGovEnforcerInstalled then return end
_G.__MouseGovEnforcerInstalled = true

-- 고유 스텝 이름
local userId = (Players.LocalPlayer and Players.LocalPlayer.UserId) or 0
local STEP_NAME = ("MouseGov_Enforcer_%s"):format(tostring(userId ~= 0 and userId or HttpService:GenerateGUID(false)))

-- 우리가 '원하는' 최종 상태를 저장
local desiredMode: "unlock" | "lock" = "unlock"

-- 실제 적용 함수(매 프레임, 카메라 이후 '마지막'에 강제)
local function applyMouse()
	if desiredMode == "unlock" then
		if UserInputService.MouseBehavior ~= Enum.MouseBehavior.Default then
			UserInputService.MouseBehavior = Enum.MouseBehavior.Default
		end
		if not UserInputService.MouseIconEnabled then
			UserInputService.MouseIconEnabled = true
		end
	else -- "lock"
		if UserInputService.MouseBehavior ~= Enum.MouseBehavior.LockCenter then
			UserInputService.MouseBehavior = Enum.MouseBehavior.LockCenter
		end
		if UserInputService.MouseIconEnabled then
			UserInputService.MouseIconEnabled = false
		end
	end
end

-- RenderStep 바인드: 카메라 처리 이후 '마지막' 우선순위에서 실행
RunService:BindToRenderStep(STEP_NAME, Enum.RenderPriority.Last.Value, applyMouse)

-- === setMouseGov 래핑/정의 ===
local OUR_WRAPPER_MARK = {} :: any

local function installWrapper()
	local existing = rawget(_G, "setMouseGov")

	if typeof(existing) == "function" and rawget(_G, "__MouseGovWrapperMark") ~= OUR_WRAPPER_MARK then
		_G.__OriginalSetMouseGov = existing
		local function wrapper(mode: string)
			desiredMode = (mode == "lock") and "lock" or "unlock"
			local ok, err = pcall(existing, mode) -- 호환성 유지
			if not ok then warn("[MouseGov] original setMouseGov failed: ", err) end
		end
		_G.setMouseGov = wrapper
		_G.__MouseGovWrapperMark = OUR_WRAPPER_MARK
	elseif typeof(existing) ~= "function" then
		function _G.setMouseGov(mode: string)
			desiredMode = (mode == "lock") and "lock" or "unlock"
		end
		_G.__MouseGovWrapperMark = OUR_WRAPPER_MARK
	end
end

installWrapper()

-- 혹시 다른 스크립트가 나중에 setMouseGov를 갈아끼우면 주기적으로 다시 래핑
task.spawn(function()
	while true do
		task.wait(0.5)
		if rawget(_G, "__MouseGovWrapperMark") ~= OUR_WRAPPER_MARK then
			installWrapper()
		end
	end
end)

-- 선택: 즉시 한 번 적용(초기값은 unlock)
applyMouse()
