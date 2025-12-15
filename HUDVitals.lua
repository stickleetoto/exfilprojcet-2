--!strict
-- HUDStatusCompact.client.lua (교체본 · 심플 현재값 전용)
-- 생성 위치: PlayerGui/ScreenGui/InventoryGui/EquipmentFrame
-- 패널: Position={0.052,0},{0.845,0} / Size={0,349},{0,100}

local Players            = game:GetService("Players")
local RunService         = game:GetService("RunService")
local ReplicatedStorage  = game:GetService("ReplicatedStorage")

local player = Players.LocalPlayer
if not player then return end
local pg = player:WaitForChild("PlayerGui")

-- (선택) BodyHealth 모듈(없어도 안전)
local BodyHealth: any? = nil
do
	local ok, mod = pcall(function()
		local Shared = ReplicatedStorage:FindFirstChild("Shared")
		return Shared and require(Shared:WaitForChild("BodyHealth"))
	end)
	if ok then BodyHealth = mod end
end

-- 경로
local SCREEN_GUI_NAME = "ScreenGui"
local INVENTORY_GUI_NAME = "InventoryGui"
local EQUIP_FRAME_NAME = "EquipmentFrame"

-- 패널 위치/크기(유지)
local PANEL_POS  = UDim2.new(0.052, 0, 0.845, 0)
local PANEL_SIZE = UDim2.new(0, 349, 0, 100)

-- 스타일
local COL_LABEL  = Color3.fromRGB(160,160,160)
local COL_VALUE  = Color3.fromRGB(235,235,235)
local LABEL_SIZE = 11
local VALUE_SIZE = 18
local GAP_X      = 12

-- 기존 HUDStatus/HUDVitals 제거(중복 방지)
for _, name in ipairs({ "HUDStatus", "HUDVitals" }) do
	local g = pg:FindFirstChild(name)
	if g and g:IsA("ScreenGui") then g:Destroy() end
end

-- 부모 찾기/대기
local function findEquip(): Frame?
	local screen = pg:FindFirstChild(SCREEN_GUI_NAME) :: ScreenGui?
	if not screen then return nil end
	local inv = screen:FindFirstChild(INVENTORY_GUI_NAME) :: Frame?
	if not inv then return nil end
	local equip = inv:FindFirstChild(EQUIP_FRAME_NAME) :: Frame?
	if equip and equip:IsA("Frame") then return equip end
	return nil
end

local function waitForEquip(): Frame
	while true do
		local e = findEquip()
		if e then return e end
		task.wait(0.2)
	end
end

-- UI 구성
local panel: Frame? = nil
local root: Frame? = nil
local cells: {Frame} = {}
local setHP: ( (string) -> () )? = nil
local setEn: ( (string) -> () )? = nil
local setH2O:( (string) -> () )? = nil
local setW : ( (string) -> () )? = nil

local function makeCell(parent: Frame, titleText: string, order: number)
	local cell = Instance.new("Frame")
	cell.Name = "Cell_"..titleText
	cell.BackgroundTransparency = 1
	cell.Size = UDim2.fromOffset(80, 72) -- 실제 폭은 아래에서 재계산
	cell.LayoutOrder = order
	cell.Parent = parent
	table.insert(cells, cell)

	local label = Instance.new("TextLabel")
	label.Name = "Label"
	label.BackgroundTransparency = 1
	label.Font = Enum.Font.GothamMedium
	label.TextSize = LABEL_SIZE
	label.TextColor3 = COL_LABEL
	label.Text = string.upper(titleText)
	label.TextXAlignment = Enum.TextXAlignment.Left
	label.Position = UDim2.fromOffset(6, 4)
	label.Size = UDim2.new(1, -12, 0, 14)
	label.Parent = cell

	local value = Instance.new("TextLabel")
	value.Name = "Value"
	value.BackgroundTransparency = 1
	value.Font = Enum.Font.Code
	value.TextSize = VALUE_SIZE
	value.TextColor3 = COL_VALUE
	value.TextXAlignment = Enum.TextXAlignment.Left
	value.TextTruncate = Enum.TextTruncate.AtEnd
	value.Text = "--"
	value.Position = UDim2.fromOffset(6, 26)
	value.Size = UDim2.new(1, -12, 0, 26)
	value.Parent = cell

	return function(txt: string) value.Text = txt end
end

local function applyCellWidths()
	if not panel or not root then return end
	-- 패널 안쪽 폭/높이
	local innerW = panel.AbsoluteSize.X - 16    -- 좌우 여백 8px
	local innerH = panel.AbsoluteSize.Y - 16
	local gaps   = GAP_X * 3                    -- 4셀 → 간격 3
	local eachW  = math.max(70, math.floor((innerW - gaps) / 4))
	local cellH  = math.max(54, innerH - 16)

	for _, c in ipairs(cells) do
		c.Size = UDim2.fromOffset(eachW, cellH)
	end
end

local function buildUI(equip: Frame)
	local old = equip:FindFirstChild("StatusPanel")
	if old then old:Destroy() end

	panel = Instance.new("Frame")
	panel.Name = "StatusPanel"
	panel.Position = PANEL_POS
	panel.Size     = PANEL_SIZE
	panel.BackgroundTransparency = 1
	panel.BorderSizePixel = 0
	panel.ClipsDescendants = true
	panel.Parent = equip

	root = Instance.new("Frame")
	root.Name = "Root"
	root.BackgroundTransparency = 1
	root.Position = UDim2.fromOffset(8, 8)
	root.Size     = UDim2.new(1, -16, 1, -16)
	root.Parent = panel

	local hList = Instance.new("UIListLayout")
	hList.FillDirection = Enum.FillDirection.Horizontal
	hList.SortOrder = Enum.SortOrder.LayoutOrder
	hList.Padding = UDim.new(0, GAP_X)
	hList.VerticalAlignment = Enum.VerticalAlignment.Center
	hList.Parent = root

	setHP = makeCell(root, "HP",     1)
	setH2O= makeCell(root, "H2O",    2)
	setEn = makeCell(root, "Energy", 3)
	setW  = makeCell(root, "Weight", 4)

	panel:GetPropertyChangedSignal("AbsoluteSize"):Connect(applyCellWidths)
	applyCellWidths()
end

-- 값 읽기
local function getHP(): number?
	local char = player.Character
	if not char then return nil end
	-- BodyHealth 모듈이 있으면 사용
	if BodyHealth and typeof(BodyHealth.GetTotalHP) == "function" then
		local ok, sum = pcall(function() return BodyHealth.GetTotalHP(char) end)
		if ok and typeof(sum)=="number" then return sum end
	end
	-- 없으면 BH_* 속성 합산
	local names = {"BH_Head","BH_Thorax","BH_Stomach","BH_LeftArm","BH_RightArm","BH_LeftLeg","BH_RightLeg"}
	local s = 0
	local any = false
	for _, n in ipairs(names) do
		local v = char:GetAttribute(n)
		if typeof(v) == "number" then s += math.max(0, v); any = true end
	end
	return any and s or nil
end

local function getAttrNum(obj: Instance, name: string): number?
	local v = obj:GetAttribute(name)
	return (typeof(v)=="number") and (v :: number) or nil
end

-- 업데이트 루프(현재값만)
RunService.RenderStepped:Connect(function()
	if not panel or not panel.Parent then return end

	-- HP
	local hp = getHP()
	if setHP then setHP(hp and tostring(math.floor(hp+0.5)) or "--") end

	-- Hydration
	local h = getAttrNum(player, "Hydration")
	if setH2O then setH2O(h and tostring(math.floor(h+0.5)) or "--") end

	-- Energy
	local e = getAttrNum(player, "Energy")
	if setEn then setEn(e and tostring(math.floor(e+0.5)) or "--") end

	-- Weight(kg, 소수1자리)
	local w: number? = getAttrNum(player, "WeightKg")
	if (not w) and player.Character then
		w = getAttrNum(player.Character, "WeightKg") or getAttrNum(player.Character, "CarryWeight")
	end
	if setW then
		setW(w and string.format("%.1fkg", w) or "?")
	end
end)

-- 부착 루프
task.spawn(function()
	local equip = waitForEquip()
	while true do
		buildUI(equip)
		repeat task.wait(0.2) until not equip.Parent or not panel or not panel.Parent
		panel, root, cells = nil, nil, {}
		setHP, setEn, setH2O, setW = nil, nil, nil, nil
		equip = waitForEquip()
	end
end)

-- 토글(호환)
_G.HUDStatus_Toggle = function(on: boolean)
	if panel then panel.Visible = on end
end
_G.HUDVitals_Toggle = function(on: boolean)
	if panel then panel.Visible = on end
end
