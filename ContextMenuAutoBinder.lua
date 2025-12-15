--!strict
-- ?? StarterPlayerScripts/ContextMenuAutoBinder.client.lua
-- 우클릭 컨텍스트 메뉴 자동 바인딩(이름/경로에 의존하지 않음)
-- - PlayerGui 전체를 스캔해서 인벤토리용 컨테이너(ScrollingFrame/그리드)를 자동 인식
-- - 동적으로 생성/파괴되어도 DescendantAdded/AncestryChanged로 즉시 추적
-- - 중복 바인딩 방지

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")

local ItemContextMenu = require(ReplicatedStorage:WaitForChild("ItemContextMenu"))

-- ===== 판별 규칙 =====
-- 이름 힌트(느슨): 일부만 포함해도 후보로 인정
local NAME_HINTS = {
	"inventory","stash","scroll","grid","items","container","loot","bag","vest","case","pouch"
}

-- 후보 컨테이너인지 점수화
local function scoreContainer(inst: Instance): number
	local s = 0
	if inst:IsA("ScrollingFrame") then
		s += 5
		local sf = inst :: ScrollingFrame
		if sf.ScrollBarThickness > 0 then s += 1 end
		if sf.CanvasSize.X.Offset > 0 or sf.CanvasSize.Y.Offset > 0 then s += 1 end
	end
	if inst:IsA("Frame") then
		-- 그리드 레이아웃 여부
		if inst:FindFirstChildOfClass("UIGridLayout") then s += 4 end
		if inst:FindFirstChildOfClass("UIListLayout") then s += 2 end
	end
	-- 이름 힌트
	local name = string.lower(inst.Name)
	for _, key in ipairs(NAME_HINTS) do
		if string.find(name, key, 1, true) then
			s += 2
			break
		end
	end
	-- 아이템 GUI가 실제로 들어있을 법한 흔적(이미지/뷰포트/버튼)
	for _, ch in ipairs(inst:GetChildren()) do
		if ch:IsA("ImageLabel") or ch:IsA("ImageButton") or ch:IsA("ViewportFrame") then
			s += 2
			break
		end
	end
	return s
end

local function isLikelyInventoryContainer(inst: Instance): boolean
	return scoreContainer(inst) >= 5
end

-- ===== 자동 바인딩 =====
local BOUND = setmetatable({}, { __mode = "k" }) -- 약참조: 파괴되면 자동 해제

local function tryBind(inst: Instance)
	if not (inst and inst.Parent) then return end
	if not (inst:IsA("GuiObject")) then return end
	if BOUND[inst] then return end
	if not isLikelyInventoryContainer(inst) then return end

	-- 중복 방지 플래그(속성/테이블 두 겹)
	if inst:GetAttribute("__icm_autobound") then
		BOUND[inst] = true
		return
	end
	inst:SetAttribute("__icm_autobound", true)
	BOUND[inst] = true

	-- 실제 바인딩
	ItemContextMenu.AutoBindUnder(inst)
	-- print(("[ContextMenuAutoBinder] 바인딩: %s (%s)"):format(inst:GetFullName(), inst.ClassName))

	-- 컨테이너가 파괴되면 기록 정리
	inst.AncestryChanged:Connect(function(_, parent)
		if parent == nil then
			BOUND[inst] = nil
		end
	end)
end

-- 초기 전체 스캔
local function initialScan(pg: PlayerGui)
	for _, g in ipairs(pg:GetDescendants()) do
		if g:IsA("GuiObject") then
			tryBind(g)
		end
	end
end

-- 동적 감시
local function watch(pg: PlayerGui)
	pg.DescendantAdded:Connect(function(inst)
		if inst:IsA("GuiObject") then
			tryBind(inst)
		end
	end)
end

-- ===== 진입점 =====
local function init()
	local player = Players.LocalPlayer
	if not player then return end
	local pg = player:WaitForChild("PlayerGui") :: PlayerGui

	-- 프레임이 아직 로드 중일 수 있으니 렌더 한 틱 뒤에 스캔
	RunService.Heartbeat:Wait()
	initialScan(pg)
	watch(pg)

	-- 안전망: 가끔 UI가 통째로 갈아끼워질 때를 대비해 주기적 재스캔(가벼움)
	task.spawn(function()
		while true do
			task.wait(2.0)
			initialScan(pg)
		end
	end)
end

task.defer(init)
