--!strict
-- Tarkov-like Body Part HUD (Top-Left, compact)
-- 읽는 값: BH_Head, BH_Thorax, BH_Stomach, BH_LeftArm, BH_RightArm, BH_LeftLeg, BH_RightLeg
-- (선택) BH_Max_<Part>가 있으면 Max로 사용, 없으면 EFT 기본치 사용

local Players  = game:GetService("Players")
local RunService = game:GetService("RunService")
local player   = Players.LocalPlayer

-- ===== EFT 기본 최대치(서버 Max 미제공 시 폴백) =====
local DEFAULT_MAX = {
	Head     = 35,
	Thorax   = 85,
	Stomach  = 70,
	LeftArm  = 60,
	RightArm = 60,
	LeftLeg  = 65,
	RightLeg = 65,
}

local PREFIX = "BH_"

-- ===== 화면/색상 설정 (좌상단 & 컴팩트) =====
local PANEL_POS   = UDim2.new(0, 16, 0, 16)    -- 좌상단
local PANEL_SIZE  = UDim2.fromOffset(96, 156)  -- 작게
local OUTLINE_CLR = Color3.fromRGB(40, 255, 60)
local FILL_FULL   = Color3.fromRGB(40, 220, 70)
local FILL_ZERO   = Color3.fromRGB(220, 40, 40)
local FILL_BLACK  = Color3.fromRGB(60, 60, 60)

-- ===== 부위 목록 =====
local PARTS = { "Head","Thorax","Stomach","LeftArm","RightArm","LeftLeg","RightLeg" }

-- ───────── UI 생성 ─────────
local function partFrame(parent: Instance, name: string, x: number, y: number, w: number, h: number): Frame
	local fr = Instance.new("Frame")
	fr.Name = name
	fr.BackgroundColor3 = FILL_FULL
	fr.BackgroundTransparency = 0.2
	fr.BorderSizePixel = 0
	fr.Position = UDim2.fromScale(x, y)
	fr.Size     = UDim2.fromScale(w, h)
	fr.Parent = parent

	local corner = Instance.new("UICorner")
	corner.CornerRadius = UDim.new(0, 4)  -- 더 작게
	corner.Parent = fr

	local stroke = Instance.new("UIStroke")
	stroke.Thickness = 1.5
	stroke.Color = OUTLINE_CLR
	stroke.ApplyStrokeMode = Enum.ApplyStrokeMode.Border
	stroke.Parent = fr

	return fr
end

local function buildHUD(): Frame
	local pg = player:WaitForChild("PlayerGui")

	local gui = Instance.new("ScreenGui")
	gui.Name = "BodyHUDGui"
	gui.ResetOnSpawn = false
	gui.IgnoreGuiInset = true
	gui.DisplayOrder = 50
	gui.Parent = pg

	local host = Instance.new("Frame")
	host.Name = "BodyHUD"
	host.AnchorPoint = Vector2.new(0,0)
	host.Position = PANEL_POS
	host.Size = PANEL_SIZE
	host.BackgroundTransparency = 1
	host.BorderSizePixel = 0
	host.Parent = gui

	-- 비율 배치(컴팩트 스케일 재조정)
	partFrame(host, "Head",     0.36, 0.02, 0.28, 0.16)
	partFrame(host, "Thorax",   0.20, 0.20, 0.60, 0.22)
	partFrame(host, "Stomach",  0.24, 0.44, 0.52, 0.16)
	partFrame(host, "LeftArm",  0.04, 0.20, 0.16, 0.30)
	partFrame(host, "RightArm", 0.80, 0.20, 0.16, 0.30)
	partFrame(host, "LeftLeg",  0.25, 0.62, 0.22, 0.34)
	partFrame(host, "RightLeg", 0.53, 0.62, 0.22, 0.34)

	return host
end

local host = buildHUD()

-- ───────── 데이터 읽기 ─────────
local function getMaxFromAttrOrDefault(char: Model, part: string): number
	local maxAttr = char:GetAttribute(PREFIX.."Max_"..part)
	if typeof(maxAttr) == "number" then
		return math.max(1, maxAttr :: number)
	end
	return DEFAULT_MAX[part]
end

local function getHP(char: Model, part: string): number
	local v = char:GetAttribute(PREFIX..part)
	if typeof(v) == "number" then
		return v :: number
	end
	return DEFAULT_MAX[part] -- 폴백
end

local function lerpColor(a: Color3, b: Color3, t: number): Color3
	t = math.clamp(t, 0, 1)
	return Color3.new(a.R + (b.R - a.R) * t, a.G + (b.G - a.G) * t, a.B + (b.B - a.B) * t)
end

local function setPartVisual(partFrameObj: Frame, ratio: number, isBlackout: boolean)
	if isBlackout then
		partFrameObj.BackgroundColor3 = FILL_BLACK
		partFrameObj.BackgroundTransparency = 0.25
		return
	end
	local col = lerpColor(FILL_ZERO, FILL_FULL, ratio)
	partFrameObj.BackgroundColor3 = col
	partFrameObj.BackgroundTransparency = 0.20 + (1 - ratio) * 0.15
end

-- ───────── 업데이트 ─────────
local function updateHUD()
	local char = player.Character
	if not char then return end
	host.Visible = true

	for _, part in ipairs(PARTS) do
		local cur = getHP(char, part)
		local max = getMaxFromAttrOrDefault(char, part)
		local ratio = (max > 0) and (cur / max) or 0
		local blackout = (cur <= 0.001)

		local fr = host:FindFirstChild(part)
		if fr and fr:IsA("Frame") then
			setPartVisual(fr, ratio, blackout)
		end
	end
end

local function hookCharacter(char: Model)
	-- AttributeChanged + 폴링 둘 다 사용 (어떤 무기/AI가 속성 갱신을 벌크로 해도 안전)
	for _, part in ipairs(PARTS) do
		char:GetAttributeChangedSignal(PREFIX..part):Connect(updateHUD)
		char:GetAttributeChangedSignal(PREFIX.."Max_"..part):Connect(updateHUD)
	end
	-- 초기 1회 갱신
	updateHUD()
end

-- 바인딩
if player.Character then hookCharacter(player.Character) end
player.CharacterAdded:Connect(hookCharacter)

-- 주기적 폴링(업데이트 누락 방지)
task.spawn(function()
	while true do
		task.wait(0.10) -- 10fps 정도로 가볍게
		updateHUD()
	end
end)
