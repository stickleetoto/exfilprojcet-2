--!strict
-- ReplicatedStorage/StackBadge.lua
-- 스타일: 작고 깔끔한 pill 배지 + 숫자 길이에 따른 자동 폭
-- 규칙:
--  - Count<=0 → UI표시 1로 취급
--  - 비(非)탄창: 표시값 1이면 숨김
--  - 탄창: 표시값 1이어도 표시 (예외)
--  - DisplayCount가 있으면 그 값을 "그대로" 사용(0->1 보정 없음)
-- 공개 API: StackBadge.Attach(gui), StackBadge.Update(gui)

local HttpService = game:GetService("HttpService")
local TextService = game:GetService("TextService")

-- ===== 튜닝 포인트 =====
local FONT            = Enum.Font.Gotham
local FONT_SIZE       = 12              -- 숫자 크기(작고 또렷)
local HEIGHT_PX       = 14              -- 배지 높이
local PADDING_X_PX    = 4               -- 좌우 여백
local MIN_WIDTH_PX    = 16              -- 최소 폭
local BG_COLOR        = Color3.fromRGB(18, 20, 24)
local BG_TRANSPARENCY = 0.25            -- 0(불투명) ~ 1(투명)
local TEXT_COLOR      = Color3.fromRGB(255, 255, 255)
local TEXT_TRANSP     = 0.0             -- 0(불투명)
local TEXT_STROKE_T   = 1.0             -- 1로 두어 외곽선 제거(촌스러움 방지)
-- ========================

local M = {}

-- 탄창 판별: ItemType/Tag/TagsJson 간단 스캔
local function isMagazine(gui: Instance): boolean
	local itemType = tostring(gui:GetAttribute("ItemType") or ""):lower()
	if itemType == "mag" or itemType == "magazine" then return true end
	local tag = tostring(gui:GetAttribute("Tag") or ""):lower()
	if tag:find("mag", 1, true) then return true end
	local tj = gui:GetAttribute("TagsJson")
	if typeof(tj) == "string" and #tj > 0 then
		local ok, arr = pcall(function() return HttpService:JSONDecode(tj) end)
		if ok and typeof(arr) == "table" then
			for _, v in ipairs(arr) do
				if typeof(v) == "string" and v:lower():find("mag", 1, true) then
					return true
				end
			end
		end
	end
	return false
end

-- 표시값 계산: DisplayCount 우선, 없으면 Count(0→1 보정)
local function computeDisplayCount(gui: Instance): number
	local disp = gui:GetAttribute("DisplayCount")
	if typeof(disp) == "number" then
		return math.floor(disp)
	end
	local raw = tonumber(gui:GetAttribute("Count")) or 0
	if raw <= 0 then return 1 end
	return math.floor(raw)
end

local function ensureBadge(gui: Instance): TextLabel
	local existing = gui:FindFirstChild("_stackBadge")
	if existing and existing:IsA("TextLabel") then
		return existing
	end
	local lbl = Instance.new("TextLabel")
	lbl.Name = "_stackBadge"
	lbl.BackgroundTransparency = BG_TRANSPARENCY
	lbl.BackgroundColor3 = BG_COLOR
	lbl.Size = UDim2.fromOffset(MIN_WIDTH_PX, HEIGHT_PX)
	lbl.AnchorPoint = Vector2.new(1, 1)
	lbl.Position = UDim2.fromScale(1, 1) -- 위치는 그대로(오른쪽-아래)
	lbl.TextScaled = false                -- 선명도를 위해 고정 px 사용
	lbl.TextSize = FONT_SIZE
	lbl.Font = FONT
	lbl.TextColor3 = TEXT_COLOR
	lbl.TextTransparency = TEXT_TRANSP
	lbl.TextStrokeTransparency = TEXT_STROKE_T
	lbl.TextXAlignment = Enum.TextXAlignment.Center
	lbl.TextYAlignment = Enum.TextYAlignment.Center
	lbl.BorderSizePixel = 0
	lbl.ZIndex = 9999
	-- pill 모양
	local corner = Instance.new("UICorner")
	corner.CornerRadius = UDim.new(1, 0)
	corner.Parent = lbl
	lbl.Parent = gui
	return lbl
end

local function autoSize(badge: TextLabel, text: string)
	-- 숫자 길이에 맞춰 폭 자동 조절
	local bounds = TextService:GetTextSize(text, FONT_SIZE, FONT, Vector2.new(1000, HEIGHT_PX))
	local w = math.max(MIN_WIDTH_PX, math.ceil(bounds.X) + PADDING_X_PX*2)
	badge.Size = UDim2.fromOffset(w, HEIGHT_PX)
end

function M.Update(gui: Instance?)
	if not gui then return end
	local badge = ensureBadge(gui)
	local n = computeDisplayCount(gui)
	local mag = isMagazine(gui)

	-- 비탄창은 1이면 숨김, 탄창은 1이어도 표시
	if n == 1 and not mag then
		badge.Visible = false
		return
	end

	local text = tostring(n)
	badge.Text = text
	autoSize(badge, text)
	badge.Visible = true
end

function M.Attach(gui: Instance?): TextLabel?
	if not gui then return nil end
	local badge = ensureBadge(gui)
	M.Update(gui)
	return badge
end

return M
