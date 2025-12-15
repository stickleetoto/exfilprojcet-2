--!strict
-- GlobalUIController.client.lua
-- - 전역 배경/robby/map/인벤토리 기본 로직
-- - mil box 연동: 우측 파밍 슬롯맵 + 장비 패널 동시 표시
-- - mil box 열림 동안 TAB은 ContextActionService로 차단
-- - ★ mil box 열림 동안 마우스 자유 유지(포인터 보임 + Lock 해제)
-- - ? 레거시 버튼/프레임이 없어도(_삭제해도_) 퀵바(_G.__GlobalUI)만으로 동작

local Players = game:GetService("Players")
local RunService = game:GetService("RunService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local StarterGui = game:GetService("StarterGui")
local UserInputService = game:GetService("UserInputService")
local ContextActionService = game:GetService("ContextActionService")

local RE_FOLDER    = ReplicatedStorage:FindFirstChild("RemoteEvents") or ReplicatedStorage:WaitForChild("RemoteEvents")
local MilBoxToggle = RE_FOLDER:FindFirstChild("MilBoxToggle") :: RemoteEvent?
local MilBoxLoot   = RE_FOLDER:FindFirstChild("MilBoxLoot")   :: RemoteEvent?

-- SlotMap 의존성(없으면 스킵)
local SlotMapRegistry = ReplicatedStorage:FindFirstChild("SlotMapRegistry")
	and require(ReplicatedStorage:WaitForChild("SlotMapRegistry")) or nil
local SlotMapManager  = ReplicatedStorage:FindFirstChild("SlotMapManager")
	and require(ReplicatedStorage:WaitForChild("SlotMapManager")) or nil

local player    = Players.LocalPlayer
local playerGui = player:WaitForChild("PlayerGui")

-- ===== 파밍 패널(Grid) 사이즈 =====
local FARM_COLS = 12
local FARM_ROWS = 8
local CELL      = 40

local S = {
	bound = false,
	isWaitingForTab = false,
	hasPressedHideout = false,

	-- 배경
	bgGui = nil :: ScreenGui?,
	background = nil :: ImageLabel?,

	-- robby/map (없어도 동작)
	robbyui = nil :: Frame?,
	mapui = nil :: Frame?,
	btn_inventory = nil :: TextButton?,
	btn_maps = nil :: TextButton?,
	btn_market = nil :: TextButton?,
	btn_hideout = nil :: TextButton?,
	btn_backtorobby = nil :: TextButton?,
	btn_backtohide = nil :: TextButton?,

	-- InventoryGui (없어도 동작)
	inventoryGui = nil :: Instance?,
	scrollingInventory = nil :: ScrollingFrame?,
	xbButton = nil :: TextButton?,
	equipFrame = nil :: Frame?,
	equipIngame = nil :: Frame?,
	prevEquipFrameVis = nil :: boolean?,
	prevEquipIngameVis = nil :: boolean?,

	-- mil box / 파밍 슬롯맵
	milBoxOpen = false,
	lootGui = nil :: ScreenGui?,
	lootPanel = nil :: Frame?,
	lootGrid = nil :: ScrollingFrame?,
	lootGridLayout = nil :: UIGridLayout?,

	-- TAB 차단
	tabActionBound = false,

	-- ★ mil box 열림 동안 마우스 자유 유지용 후크
	mouseFreeConn = nil :: RBXScriptConnection?,

	-- 연결 관리
	conns = {} :: { RBXScriptConnection },
}

local function addConn(c: RBXScriptConnection?) if c then table.insert(S.conns, c) end end
local function disconnectAll()
	for _, c in ipairs(S.conns) do pcall(function() c:Disconnect() end) end
	S.conns = {}
	S.bound = false
end

-- =========================
--  SlotMap(파밍) 유틸
-- =========================
local function ensureRaidLootMap(cols: number, rows: number)
	if not (SlotMapRegistry and SlotMapManager) then return nil end
	local cur = SlotMapRegistry.Get and SlotMapRegistry.Get("RaidLoot")
	if cur and cur.cols == cols and cur.rows == rows then return cur end
	local newMap = SlotMapManager.new(rows, cols)
	if SlotMapRegistry.Set then SlotMapRegistry.Set("RaidLoot", newMap) end
	return newMap
end

local function registerGridCellsToMap(grid: ScrollingFrame, cols: number, rows: number, map)
	if not (grid and map and map.RegisterSlotFrame) then return end
	for r = 1, rows do
		for c = 1, cols do
			local idx = (r - 1) * cols + c
			local slot = grid:FindFirstChild("S_" .. idx)
			if slot and slot:IsA("Frame") then
				map:RegisterSlotFrame(r, c, slot)
			end
		end
	end
end

-- =========================
--  Background
-- =========================
local function ensureBackgroundGui(): ScreenGui
	local bgGui = playerGui:FindFirstChild("GlobalBackgroundGui") :: ScreenGui?
	if not bgGui then
		bgGui = Instance.new("ScreenGui")
		bgGui.Name = "GlobalBackgroundGui"
		bgGui.IgnoreGuiInset = true
		bgGui.ResetOnSpawn = false
		bgGui.ZIndexBehavior = Enum.ZIndexBehavior.Sibling
		bgGui.DisplayOrder = -1000
		bgGui.Parent = playerGui
	end
	local old = bgGui:FindFirstChild("GlobalBackground"); if old then old:Destroy() end

	local background = Instance.new("ImageLabel")
	background.Name = "GlobalBackground"
	background.Size = UDim2.new(1, 0, 1, 0)
	background.Position = UDim2.new(0, 0, 0, 0)
	background.Image = "rbxassetid://81816177301870"  -- 필요하면 교체
	background.BackgroundTransparency = 1
	background.ImageTransparency = 0
	background.ScaleType = Enum.ScaleType.Crop
	background.ZIndex = 0
	background.Active = false
	background.Visible = true            -- ★ 처음부터 보이게!
	background.Parent = bgGui

	S.bgGui = bgGui
	S.background = background
	return bgGui
end

local function showBackground(on: boolean)
	if not S.background or not S.background.Parent then ensureBackgroundGui() end
	if S.background then S.background.Visible = on end
end

-- =========================
--  Farming UI (Right)
-- =========================
local function ensureFarmingUI()
	if S.lootGui and S.lootGui.Parent and S.lootPanel and S.lootGrid then
		local map = ensureRaidLootMap(FARM_COLS, FARM_ROWS)
		if map then registerGridCellsToMap(S.lootGrid :: ScrollingFrame, FARM_COLS, FARM_ROWS, map) end
		return
	end

	local gui = Instance.new("ScreenGui")
	gui.Name = "LootGui"
	gui.ResetOnSpawn = false
	gui.DisplayOrder = 20
	gui.IgnoreGuiInset = false
	gui.ZIndexBehavior = Enum.ZIndexBehavior.Sibling
	gui.Parent = playerGui

	local panel = Instance.new("Frame")
	panel.Name = "RightInventory"
	panel.AnchorPoint = Vector2.new(1, 0.5)
	panel.Position = UDim2.fromScale(0.98, 0.5)
	panel.Size = UDim2.new(0.28, 0, 0.72, 0)
	panel.BackgroundColor3 = Color3.fromRGB(22,22,22)
	panel.BackgroundTransparency = 0.1
	panel.BorderSizePixel = 0
	panel.Visible = false
	panel.ZIndex = 100
	panel.Parent = gui
	Instance.new("UICorner", panel).CornerRadius = UDim.new(0, 12)

	local title = Instance.new("TextLabel")
	title.Name = "Title"
	title.BackgroundTransparency = 1
	title.Position = UDim2.fromOffset(12, 6)
	title.Size = UDim2.new(1, -24, 0, 28)
	title.Font = Enum.Font.GothamBold
	title.TextColor3 = Color3.fromRGB(235,235,235)
	title.TextXAlignment = Enum.TextXAlignment.Left
	title.TextSize = 18
	title.Text = "Container (Farming)"
	title.ZIndex = 101
	title.Parent = panel

	local sep = Instance.new("Frame")
	sep.Size = UDim2.new(1, -24, 0, 1)
	sep.Position = UDim2.fromOffset(12, 36)
	sep.BackgroundColor3 = Color3.fromRGB(60, 60, 60)
	sep.BackgroundTransparency = 0.4
	sep.BorderSizePixel = 0
	sep.ZIndex = 101
	sep.Parent = panel

	local gridFrame = Instance.new("ScrollingFrame")
	gridFrame.Name = "FarmingGrid"
	gridFrame.BackgroundTransparency = 1
	gridFrame.BorderSizePixel = 0
	gridFrame.Position = UDim2.fromOffset(12, 42)
	gridFrame.Size = UDim2.new(1, -24, 1, -84)
	gridFrame.ScrollBarThickness = 8
	gridFrame.TopImage = "rbxassetid://1"
	gridFrame.MidImage = "rbxassetid://1"
	gridFrame.BottomImage = "rbxassetid://1"
	gridFrame.CanvasSize = UDim2.fromOffset(FARM_COLS * CELL, FARM_ROWS * CELL)
	gridFrame.ZIndex = 101
	gridFrame.ClipsDescendants = true
	gridFrame.Parent = panel

	local grid = Instance.new("UIGridLayout")
	grid.CellPadding = UDim2.fromOffset(2,2)
	grid.CellSize = UDim2.fromOffset(CELL, CELL)
	grid.SortOrder = Enum.SortOrder.LayoutOrder
	grid.Parent = gridFrame

	for i = 1, FARM_ROWS * FARM_COLS do
		local slot = Instance.new("Frame")
		slot.Name = "S_" .. i
		slot.Size = UDim2.fromOffset(CELL, CELL)
		slot.BackgroundColor3 = Color3.fromRGB(34,34,34)
		slot.BorderSizePixel = 0
		slot.ZIndex = 102
		Instance.new("UICorner", slot).CornerRadius = UDim.new(0,6)
		slot.Parent = gridFrame
	end

	local map = ensureRaidLootMap(FARM_COLS, FARM_ROWS)
	if map then registerGridCellsToMap(gridFrame, FARM_COLS, FARM_ROWS, map) end

	S.lootGui = gui
	S.lootPanel = panel
	S.lootGrid = gridFrame
	S.lootGridLayout = grid
end

-- =========================
--  UI refs (있으면 잡고, 없어도 그냥 넘어감)
-- =========================
local function collectRefs()
	local screenGui = playerGui:FindFirstChild("ScreenGui")
	if screenGui then
		S.robbyui = screenGui:FindFirstChild("robbyui") :: Frame?
		S.mapui   = screenGui:FindFirstChild("mapui")   :: Frame?

		if S.robbyui then
			S.btn_inventory = S.robbyui:FindFirstChild("Inventory") :: TextButton?
			S.btn_maps      = S.robbyui:FindFirstChild("maps")      :: TextButton?
			S.btn_market    = S.robbyui:FindFirstChild("Market")    :: TextButton?
		end
		if S.mapui then
			S.btn_hideout     = S.mapui:FindFirstChild("hideout")     :: TextButton?
			S.btn_backtorobby = S.mapui:FindFirstChild("backtorobby") :: TextButton?
			S.btn_backtohide  = S.mapui:FindFirstChild("backtohide")  :: TextButton?
		end

		S.inventoryGui = screenGui:FindFirstChild("InventoryGui")
		if S.inventoryGui then
			S.scrollingInventory = S.inventoryGui:FindFirstChild("ScrollingInventory") :: ScrollingFrame?
			S.xbButton           = S.inventoryGui:FindFirstChild("XB") :: TextButton?
			S.equipFrame         = S.inventoryGui:FindFirstChild("EquipmentFrame")  :: Frame?
			S.equipIngame        = S.inventoryGui:FindFirstChild("Equipmentingame") :: Frame?
		end
	end
end

local function setInitialVisibility()
	if S.btn_hideout     then S.btn_hideout.Visible     = false end
	if S.btn_backtorobby then S.btn_backtorobby.Visible = false end
	if S.btn_backtohide  then S.btn_backtohide.Visible  = false end
end

-- 장비 UI 표시/복구
local function showEquipPanels()
	if S.equipFrame then
		if S.prevEquipFrameVis == nil then S.prevEquipFrameVis = S.equipFrame.Visible end
		S.equipFrame.Visible = true
	end
	if S.equipIngame then
		if S.prevEquipIngameVis == nil then S.prevEquipIngameVis = S.equipIngame.Visible end
		S.equipIngame.Visible = true
	end
	if S.xbButton then S.xbButton.Visible = false end
end

local function restoreEquipPanels()
	if S.equipFrame and S.prevEquipFrameVis ~= nil then
		S.equipFrame.Visible = S.prevEquipFrameVis; S.prevEquipFrameVis = nil
	end
	if S.equipIngame and S.prevEquipIngameVis ~= nil then
		S.equipIngame.Visible = S.prevEquipIngameVis; S.prevEquipIngameVis = nil
	end
	if S.xbButton then S.xbButton.Visible = false end
end

-- ===== TAB 차단기 =====
local TAB_ACTION = "MilBox_Tab_Close"
local TAB_PRIORITY = 3000

local function bindTabBlocker()
	if S.tabActionBound or not MilBoxToggle then return end
	S.tabActionBound = true
	ContextActionService:BindActionAtPriority(
		TAB_ACTION,
		function(_name, state, _input)
			if state ~= Enum.UserInputState.Begin then
				return Enum.ContextActionResult.Pass
			end
			if not S.milBoxOpen then
				return Enum.ContextActionResult.Pass
			end
			S.milBoxOpen = false
			MilBoxToggle:FireServer(nil, "close")
			if S.lootPanel then S.lootPanel.Visible = false end
			restoreEquipPanels()
			return Enum.ContextActionResult.Sink
		end,
		false,
		TAB_PRIORITY,
		Enum.KeyCode.Tab
	)
end

local function unbindTabBlocker()
	if not S.tabActionBound then return end
	S.tabActionBound = false
	pcall(function() ContextActionService:UnbindAction(TAB_ACTION) end)
end

-- ===== 인벤/오버레이/루팅 등 탭 UI 전체 닫기 =====
local function closeAllTabUIs()
	if S.scrollingInventory then S.scrollingInventory.Visible = false end
	if S.xbButton           then S.xbButton.Visible           = false end
	restoreEquipPanels()
	if S.lootPanel          then S.lootPanel.Visible          = false end
end

-- ===== 레거시 버튼 바인딩(있으면만). 없어도 퀵바로 동작.
local function bindRobbyAndMap()
	disconnectAll()
	collectRefs()
	setInitialVisibility()

	if S.btn_maps then
		addConn(S.btn_maps.MouseButton1Click:Connect(function()
			if S.btn_inventory then S.btn_inventory.Visible = false end
			if S.btn_market   then S.btn_market.Visible   = false end
			if S.btn_maps     then S.btn_maps.Visible     = false end
			if S.btn_hideout  then S.btn_hideout.Visible  = true end
			if S.btn_backtorobby then S.btn_backtorobby.Visible = true end
			if S.btn_backtohide  then S.btn_backtohide.Visible  = false end
			S.isWaitingForTab, S.hasPressedHideout = false, false
		end))
	end

	if S.btn_hideout then
		addConn(S.btn_hideout.MouseButton1Click:Connect(function()
			-- 기존 동작 유지
			if S.btn_hideout then S.btn_hideout.Visible = false end
			if S.btn_backtorobby then S.btn_backtorobby.Visible = false end
			if S.btn_backtohide then S.btn_backtohide.Visible = false end
			if S.background then S.background.Visible = false end
			S.isWaitingForTab, S.hasPressedHideout = true, true
		end))
	end

	if S.btn_backtorobby then
		addConn(S.btn_backtorobby.MouseButton1Click:Connect(function()
			closeAllTabUIs()
			if S.btn_inventory then S.btn_inventory.Visible = true end
			if S.btn_market   then S.btn_market.Visible   = true end
			if S.btn_maps     then S.btn_maps.Visible     = true end
			if S.btn_hideout  then S.btn_hideout.Visible  = false end
			if S.btn_backtorobby then S.btn_backtorobby.Visible = false end
			if S.btn_backtohide  then S.btn_backtohide.Visible  = false end
			if S.background then S.background.Visible = true end
			S.isWaitingForTab, S.hasPressedHideout = false, false
		end))
	end

	-- ★ backtohide: 배경 켜고, 인벤 UI 모두 닫고, hideout과 동일한 플래그/가시성으로 동작
	if S.btn_backtohide then
		addConn(S.btn_backtohide.MouseButton1Click:Connect(function()
			-- 인벤/루팅 패널 닫기
			closeAllTabUIs()
			-- hideout과 동일한 가시성/플래그 (단, 배경은 켠다)
			if S.btn_hideout then S.btn_hideout.Visible = false end
			if S.btn_backtorobby then S.btn_backtorobby.Visible = false end
			if S.btn_backtohide then S.btn_backtohide.Visible = false end
			showBackground(true)
			S.isWaitingForTab, S.hasPressedHideout = true, true
		end))
	end

	-- Hideout 안내 → TAB 한 번 누르면 backtohide 표시
	addConn(UserInputService.InputBegan:Connect(function(input, processed)
		if processed or input.KeyCode ~= Enum.KeyCode.Tab then return end
		if S.milBoxOpen == true then return end
		if S.isWaitingForTab and S.hasPressedHideout then
			if S.btn_backtohide then S.btn_backtohide.Visible = true end
			S.isWaitingForTab, S.hasPressedHideout = false, false
		end
	end))

	S.bound = true
end

local function bindInventory()
	collectRefs()
	if not (S.btn_inventory and S.inventoryGui and S.scrollingInventory) then return end

	addConn(S.btn_inventory.MouseButton1Click:Connect(function()
		S.scrollingInventory.Visible = true
		if S.xbButton then S.xbButton.Visible = true end
		if S.btn_inventory then S.btn_inventory.Visible = false end
		if S.btn_maps then S.btn_maps.Visible = false end
		if S.btn_market then S.btn_market.Visible = false end
	end))

	if S.xbButton then
		addConn(S.xbButton.MouseButton1Click:Connect(function()
			S.scrollingInventory.Visible = false
			if S.xbButton then S.xbButton.Visible = false end
			if S.btn_inventory then S.btn_inventory.Visible = true end
			if S.btn_maps then S.btn_maps.Visible = true end
			if S.btn_market then S.btn_market.Visible = true end
		end))
	end
end

-- === 마우스 자유화 헬퍼들 ===
local function ensureMouseFreeWhileOpen()
	if S.mouseFreeConn then return end
	S.mouseFreeConn = RunService.RenderStepped:Connect(function()
		if not S.milBoxOpen then return end
		if UserInputService.MouseBehavior ~= Enum.MouseBehavior.Default then
			UserInputService.MouseBehavior = Enum.MouseBehavior.Default
		end
		if not UserInputService.MouseIconEnabled then
			UserInputService.MouseIconEnabled = true
		end
	end)
end

local function stopMouseFree()
	if S.mouseFreeConn then S.mouseFreeConn:Disconnect(); S.mouseFreeConn = nil end
end

if MilBoxLoot then
	MilBoxLoot.OnClientEvent:Connect(function(kind: string, _model: Model)
		if kind == "open" then
			S.milBoxOpen = true
			ensureFarmingUI()
			if S.lootPanel then S.lootPanel.Visible = true end
			showEquipPanels()
			bindTabBlocker()
			ensureMouseFreeWhileOpen()   -- ★ 실제 사용
			-- 전역 심판이 있으면 알림(있을 수도, 없을 수도 있음)
			if typeof(_G) == "table" and type((_G :: any).setMouseGov) == "function" then
				((_G :: any).setMouseGov)("unlock")
			end

		elseif kind == "close" then
			S.milBoxOpen = false
			if S.lootPanel then S.lootPanel.Visible = false end
			restoreEquipPanels()
			unbindTabBlocker()
			stopMouseFree()              -- ★ 실제 사용
		end
	end)
end

-- 초기화
local function initOnce()
	ensureBackgroundGui()
	ensureFarmingUI()
	bindRobbyAndMap()
	bindInventory()
	unbindTabBlocker()
end
initOnce()

-- 재바인딩/보장(없으면 스킵, 있으면 동작)
addConn(player.CharacterAdded:Connect(function(_char)
	if (not S.bgGui) or (not S.bgGui.Parent) or (not S.background) or (not S.background.Parent) then
		ensureBackgroundGui()
	end
	if (not S.lootGui) or (not S.lootGui.Parent) or (not S.lootPanel) or (not S.lootPanel.Parent) then
		ensureFarmingUI()
	end
	task.delay(0.2, function()
		bindRobbyAndMap()
		bindInventory()
		if S.milBoxOpen then bindTabBlocker() else unbindTabBlocker() end
	end)
end))

addConn(playerGui.ChildAdded:Connect(function(_child)
	task.delay(0.2, function()
		if (not S.lootGui) or (not S.lootGui.Parent) or (not S.lootPanel) or (not S.lootPanel.Parent) then
			ensureFarmingUI()
		end
		bindRobbyAndMap()
		bindInventory()
		if S.milBoxOpen then bindTabBlocker() else unbindTabBlocker() end
	end)
end))

addConn(RunService.Heartbeat:Connect(function()
	if not S.background or not S.background.Parent then ensureBackgroundGui() end
	if not S.lootPanel or not S.lootPanel.Parent then ensureFarmingUI() end
	if not S.bound then bindRobbyAndMap(); bindInventory() end
end))

-- ====== [브릿지] 외부(퀵바)에서 맵/인벤/마켓을 제어할 수 있도록 전역 훅 공개 ======
_G.__GlobalUI = _G.__GlobalUI or {}

-- 인벤토리 열기/닫기/토글 (로비 맥락 그대로 재현) ? 버튼 없어도 동작
_G.__GlobalUI.OpenInventory = function()
	collectRefs()
	if S.scrollingInventory then S.scrollingInventory.Visible = true end
	if S.xbButton           then S.xbButton.Visible           = true end
	if S.btn_inventory      then S.btn_inventory.Visible      = false end
	if S.btn_maps           then S.btn_maps.Visible           = false end
	if S.btn_market         then S.btn_market.Visible         = false end
end

_G.__GlobalUI.CloseInventory = function()
	collectRefs()
	if S.scrollingInventory then S.scrollingInventory.Visible = false end
	if S.xbButton           then S.xbButton.Visible           = false end
	if S.btn_inventory      then S.btn_inventory.Visible      = true end
	if S.btn_maps           then S.btn_maps.Visible           = true end
	if S.btn_market         then S.btn_market.Visible         = true end
end

_G.__GlobalUI.ToggleInventory = function()
	collectRefs()
	local open = S.scrollingInventory and S.scrollingInventory.Visible
	if open then _G.__GlobalUI.CloseInventory() else _G.__GlobalUI.OpenInventory() end
end

-- 맵 버튼이 하던 화면 전환(로비 → 맵/하이드 진입 대기 상태)
_G.__GlobalUI.OpenMap = function()
	collectRefs()
	if S.btn_inventory then S.btn_inventory.Visible = false end
	if S.btn_market   then S.btn_market.Visible   = false end
	if S.btn_maps     then S.btn_maps.Visible     = false end
	if S.btn_hideout  then S.btn_hideout.Visible  = true end
	if S.btn_backtorobby then S.btn_backtorobby.Visible = true end
	if S.btn_backtohide  then S.btn_backtohide.Visible  = false end
	S.isWaitingForTab, S.hasPressedHideout = false, false
end

-- 맵 화면에서 로비로 복귀
_G.__GlobalUI.BackToRobby = function()
	collectRefs()
	closeAllTabUIs()
	if S.btn_inventory then S.btn_inventory.Visible = true end
	if S.btn_market   then S.btn_market.Visible   = true end
	if S.btn_maps     then S.btn_maps.Visible     = true end
	if S.btn_hideout  then S.btn_hideout.Visible  = false end
	if S.btn_backtorobby then S.btn_backtorobby.Visible = false end
	if S.btn_backtohide  then S.btn_backtohide.Visible  = false end
	if S.background then S.background.Visible = true end
	S.isWaitingForTab, S.hasPressedHideout = false, false
end

-- (선택) 마켓: 실제 마켓 UI가 있으면 여기에 연결. 없으면 퀵바 쪽 폴백 사용.
_G.__GlobalUI.OpenMarket = _G.__GlobalUI.OpenMarket or function()
	-- TODO: 마켓 UI 연동 시 구현
end
