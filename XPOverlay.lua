--!strict
-- ?? StarterPlayerScripts/XPOverlay.client.lua
-- 우상단 XP 오버레이 (Endurance/Strength 레벨 & XP/다음 필요치 + 진행바)
-- - 서버 Attribute 사용: Endurance, Strength, XPEndurance, XPStrength
-- - ReplicatedStorage.Shared.StatDefs.xpPerLevel(level) 있으면 사용, 없으면 100 * 1.15^(L-1) 폴백
-- - 플레이어 Attribute 변경 시 자동 갱신
-- - ResetOnSpawn = false (리스폰에도 유지)

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local player = Players.LocalPlayer

-- ===== StatDefs(선택) =====
local XP_BASE = 100
local XP_GROWTH = 1.15

local function getShared()
	local shared = ReplicatedStorage:FindFirstChild("Shared")
	if not shared then return nil end
	local mod = shared:FindFirstChild("StatDefs")
	if mod and mod:IsA("ModuleScript") then
		local ok, t = pcall(require, mod)
		if ok and type(t) == "table" then return t end
	end
	return nil
end

local Shared = getShared()
local StatDefs = Shared and Shared.StatDefs or nil

local function xpToNext(statName: "Endurance" | "Strength", level: number): number
	local def = StatDefs and StatDefs[statName]
	if def and typeof(def.xpPerLevel) == "function" then
		local ok, v = pcall(def.xpPerLevel, level)
		if ok and typeof(v) == "number" then return math.max(1, math.floor(v)) end
	end
	-- 폴백
	return math.max(1, math.floor(XP_BASE * (XP_GROWTH ^ math.max(0, level - 1))))
end

-- ===== 안전한 숫자 읽기 =====
local function numAttr(name: string, default: number): number
	local v = player:GetAttribute(name)
	return (typeof(v) == "number") and v or default
end

-- ===== GUI 빌드 =====
local function ensureHost(): Frame
	local pg = player:WaitForChild("PlayerGui")

	-- 전용 GUI 생성
	local gui = pg:FindFirstChild("XPOverlayGui") :: ScreenGui
	if not gui then
		gui = Instance.new("ScreenGui")
		gui.Name = "XPOverlayGui"
		gui.ResetOnSpawn = false
		gui.IgnoreGuiInset = false
		gui.Parent = pg
	end

	local host = gui:FindFirstChild("XPOverlay")
	if host and host:IsA("Frame") then return host :: Frame end

	host = Instance.new("Frame")
	host.Name = "XPOverlay"
	host.AnchorPoint = Vector2.new(1, 0)
	host.Position = UDim2.new(1, -16, 0, 16)
	host.Size = UDim2.fromOffset(260, 92)
	host.BackgroundColor3 = Color3.fromRGB(20, 20, 20)
	host.BackgroundTransparency = 0.15
	host.BorderSizePixel = 0
	host.Parent = gui

	local stroke = Instance.new("UIStroke")
	stroke.ApplyStrokeMode = Enum.ApplyStrokeMode.Border
	stroke.Thickness = 1
	stroke.Color = Color3.fromRGB(60, 60, 60)
	stroke.Parent = host

	local corner = Instance.new("UICorner")
	corner.CornerRadius = UDim.new(0, 6)
	corner.Parent = host

	local layout = Instance.new("UIListLayout")
	layout.FillDirection = Enum.FillDirection.Vertical
	layout.Padding = UDim.new(0, 6)
	layout.HorizontalAlignment = Enum.HorizontalAlignment.Right
	layout.VerticalAlignment = Enum.VerticalAlignment.Top
	layout.SortOrder = Enum.SortOrder.LayoutOrder
	layout.Parent = host

	return host
end

local function makeRow(parent: Instance, labelText: string, color: Color3, order: number): Frame
	local row = Instance.new("Frame")
	row.Name = "Row_" .. labelText
	row.Size = UDim2.new(1, -12, 0, 36)
	row.BackgroundTransparency = 1
	row.BorderSizePixel = 0
	row.LayoutOrder = order
	row.Parent = parent

	local title = Instance.new("TextLabel")
	title.Name = "Title"
	title.BackgroundTransparency = 1
	title.Size = UDim2.new(1, 0, 0, 16)
	title.Position = UDim2.new(0, 0, 0, 0)
	title.Font = Enum.Font.GothamMedium
	title.TextSize = 14
	title.TextXAlignment = Enum.TextXAlignment.Right
	title.TextColor3 = Color3.fromRGB(225, 225, 225)
	title.Text = labelText
	title.Parent = row

	local barBG = Instance.new("Frame")
	barBG.Name = "BarBG"
	barBG.Size = UDim2.new(1, 0, 0, 10)
	barBG.Position = UDim2.new(0, 0, 0, 22)
	barBG.BackgroundColor3 = Color3.fromRGB(40, 40, 40)
	barBG.BorderSizePixel = 0
	barBG.Parent = row

	local bgCorner = Instance.new("UICorner")
	bgCorner.CornerRadius = UDim.new(0, 3)
	bgCorner.Parent = barBG

	local barFill = Instance.new("Frame")
	barFill.Name = "Fill"
	barFill.Size = UDim2.new(0, 0, 1, 0)
	barFill.BackgroundColor3 = color
	barFill.BorderSizePixel = 0
	barFill.Parent = barBG

	local fillCorner = Instance.new("UICorner")
	fillCorner.CornerRadius = UDim.new(0, 3)
	fillCorner.Parent = barFill

	return row
end

local host = ensureHost()
local rowEnd = makeRow(host, "Endurance", Color3.fromRGB(90, 200, 90), 1) -- 초록
local rowStr = makeRow(host, "Strength",  Color3.fromRGB(220, 80, 80),  2) -- 빨강

-- ===== 업데이트 =====
local function updateRow(statName: "Endurance"|"Strength", row: Frame)
	local levelAttr = statName
	local xpAttr    = "XP" .. statName

	local level = numAttr(levelAttr, 1)
	local xp    = numAttr(xpAttr, 0)

	local maxLvl = 100
	if StatDefs and StatDefs[statName] and typeof(StatDefs[statName].max) == "number" then
		maxLvl = StatDefs[statName].max
	end

	local need = (level >= maxLvl) and 1 or xpToNext(statName, level)
	local ratio = (level >= maxLvl) and 1 or math.clamp(xp / math.max(1, need), 0, 1)

	local title = row:FindFirstChild("Title") :: TextLabel
	local barBG = row:FindFirstChild("BarBG") :: Frame
	local fill  = barBG and barBG:FindFirstChild("Fill") :: Frame

	if title then
		if level >= maxLvl then
			title.Text = string.format("%s  Lv.%d  (MAX)", statName, level)
		else
			title.Text = string.format("%s  Lv.%d  (%d / %d)", statName, level, xp, need)
		end
	end
	if fill then
		fill.Size = UDim2.new(ratio, 0, 1, 0)
	end
end

local function updateAll()
	updateRow("Endurance", rowEnd)
	updateRow("Strength",  rowStr)
end

-- 최초 업데이트
updateAll()

-- ===== Attribute 변경 감시 =====
player.AttributeChanged:Connect(function(attr)
	if attr == "Endurance" or attr == "XPEndurance" then
		updateRow("Endurance", rowEnd)
	elseif attr == "Strength" or attr == "XPStrength" then
		updateRow("Strength", rowStr)
	end
end)

-- 주기적 보정
task.spawn(function()
	while true do
		task.wait(1.0)
		updateAll()
	end
end)
