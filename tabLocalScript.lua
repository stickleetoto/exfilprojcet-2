--!strict
-- StarterPlayerScripts/LocalScript.client.lua
-- Hide.client.lua가 제공하는 공개 훅만 호출하는 "안전 스텁"
-- 요구 동작:
-- - 하이드 아웃일 때만 TAB 동작
-- - TAB: 장비창(EquipmentFrame+Equipmentingame) + backtohide 표시, 마우스 unlock
-- - 다시 TAB: 장비창/오버레이 닫기 (하이드 상태면 마우스 lock 복귀 시도)

local Players = game:GetService("Players")
local CAS = game:GetService("ContextActionService")

-- 안전: 이전 바인딩 제거
pcall(function() CAS:UnbindAction("Stub_ToggleInv") end)
pcall(function() CAS:UnbindAction("Stub_TabEquipOverlay") end)

-- 스텁 로컬 상태(전역 훅이 열림/닫힘을 반환하지 않을 때 대비)
local overlayOpenLocal = false

-- 열기 시도: Hide가 노출한 훅만 사용
local function openEquipOverlay()
	-- 선호도: 전용 토글/열기 훅이 있으면 그것 사용
	if typeof(_G.ToggleEquipOverlay) == "function" then
		local opened = _G.ToggleEquipOverlay(true) -- 열기 의도 전달 가능 시도
		overlayOpenLocal = (opened == nil) and true or opened
	elseif typeof(_G.OpenEquipOverlay) == "function" then
		_G.OpenEquipOverlay()
		overlayOpenLocal = true
		-- 구버전 호환: 장비만 여는 훅이 따로 있다면
	elseif typeof(_G.OpenEquipOnly) == "function" then
		_G.OpenEquipOnly()
		overlayOpenLocal = true
	else
		-- 공개 훅이 없다면 아무 것도 하지 않음(인벤 전체 토글은 금지)
		return
	end

	-- backtohide 버튼 보이기 훅이 있으면 요청
	if typeof(_G.SetBackToHideVisible) == "function" then
		_G.SetBackToHideVisible(true)
	elseif typeof(_G.ShowBackToHide) == "function" then
		_G.ShowBackToHide(true)
	end

	-- 마우스 자유
	if typeof(_G.setMouseGov) == "function" then
		_G.setMouseGov("unlock")
	end
end

-- 닫기 시도
local function closeEquipOverlay()
	if typeof(_G.ToggleEquipOverlay) == "function" then
		local opened = _G.ToggleEquipOverlay(false)
		overlayOpenLocal = (opened == nil) and false or opened
	elseif typeof(_G.CloseEquipOverlay) == "function" then
		_G.CloseEquipOverlay()
		overlayOpenLocal = false
	elseif typeof(_G.CloseEquipOnly) == "function" then
		_G.CloseEquipOnly()
		overlayOpenLocal = false
	else
		return
	end

	-- backtohide는 닫을 때 굳이 숨기지 않아도 되지만, 훅이 있으면 정합성 위해 끔
	if typeof(_G.SetBackToHideVisible) == "function" then
		_G.SetBackToHideVisible(false)
	elseif typeof(_G.ShowBackToHide) == "function" then
		_G.ShowBackToHide(false)
	end

	-- 하이드 중에는 다시 잠금, 아니면 유지
	if typeof(_G.setMouseGov) == "function" then
		if _G.isInHideout then _G.setMouseGov("lock") end
	end
end

-- TAB 처리: 하이드 아웃일 때만 토글
CAS:BindActionAtPriority(
	"Stub_TabEquipOverlay",
	function(_, state)
		if state ~= Enum.UserInputState.Begin then
			return Enum.ContextActionResult.Pass
		end

		-- 하이드 아웃 아닐 땐 PASS (다른 시스템이 TAB을 쓸 수 있게)
		if not _G.isInHideout then
			return Enum.ContextActionResult.Pass
		end

		-- 장비 오버레이 토글
		if overlayOpenLocal then
			closeEquipOverlay()
		else
			openEquipOverlay()
		end

		-- 우리가 처리했으니 소비
		return Enum.ContextActionResult.Sink
	end,
	false,
	-- 우선순위는 너무 높지 않게, Hide의 자체 핸들러보다 약간 낮거나 동일 선호
	2500,
	Enum.KeyCode.Tab
)

-- (옵션) 외부에서 하이드 토글을 원할 때 예시 호출 함수
local function QuickEnter()
	if typeof(_G.EnterHideout) == "function" then _G.EnterHideout() end
end
local function QuickExit()
	if typeof(_G.ExitHideout) == "function" then _G.ExitHideout() end
end
-- 사용 예:
-- QuickEnter()
-- QuickExit()
