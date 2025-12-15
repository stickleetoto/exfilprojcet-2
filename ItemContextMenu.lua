--!strict
-- ReplicatedStorage/ItemContextMenu.lua (v5: Food-aware context menu)
-- - 음식(Category=food 또는 Consume/ConsumeHint 존재) → "먹기" 버튼만 노출
-- - 그 외 아이템 → 기존처럼 "모딩" 버튼 노출
-- - 외부 클릭 닫기, 한 번에 하나만 표시 유지

local Players           = game:GetService("Players")
local UserInputService  = game:GetService("UserInputService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local HttpService       = game:GetService("HttpService")

-- (선택) 무기 모딩 모듈
local WeaponModding: any = nil
do
	local ok, mod = pcall(function()
		return require(ReplicatedStorage:WaitForChild("WeaponModding", 1))
	end)
	if ok then WeaponModding = mod end
end

-- 서버 메타/소비 호출
local GetStashData: RemoteFunction? = ReplicatedStorage:FindFirstChild("GetStashData") :: RemoteFunction?
local Remotes = ReplicatedStorage:FindFirstChild("Remotes")
local RequestConsume: RemoteFunction? = Remotes and Remotes:FindFirstChild("RequestConsume") :: RemoteFunction?

local ItemContextMenu = {}

-- ===== 레이어/스타일 =====
local OVERLAY_DISPLAY_ORDER = 300
local MENU_Z                = 1000
local MENU_BTN_H     = 28
local MENU_BTN_PAD   = 6
local MENU_SIDE_PAD  = 6
local MENU_BG        = Color3.fromRGB(20,20,20)

-- ===== 상태 =====
local ACTIVE_MENU: Frame? = nil
local ACTIVE_TARGET: GuiObject? = nil

-- ===== 유틸 =====
local function getMousePos(): Vector2
	if typeof(UserInputService.GetMouseLocation) == "function" then
		return UserInputService:GetMouseLocation()
	end
	local plr = Players.LocalPlayer
	if plr and typeof(plr.GetMouse) == "function" then
		local m = plr:GetMouse()
		if m then return Vector2.new(m.X, m.Y) end
	end
	return Vector2.new(0,0)
end

local function _getOverlayRoot(): ScreenGui
	local pg = Players.LocalPlayer:WaitForChild("PlayerGui")
	local gui = pg:FindFirstChild("ContextMenuGui") :: ScreenGui
	if not gui then
		gui = Instance.new("ScreenGui")
		gui.Name = "ContextMenuGui"
		gui.IgnoreGuiInset = true
		gui.ZIndexBehavior = Enum.ZIndexBehavior.Global
		gui.DisplayOrder = OVERLAY_DISPLAY_ORDER
		gui.ResetOnSpawn = false
		gui.Parent = pg
	end
	return gui
end

-- “아이템 GUI” 판별
local function isItemGui(inst: Instance): boolean
	if not (inst and inst:IsA("GuiObject")) then return false end
	local c = inst.ClassName
	if c ~= "ImageLabel" and c ~= "ImageButton" and c ~= "ViewportFrame" then
		return false
	end
	if inst:GetAttribute("Tag") then return true end
	if inst:GetAttribute("TagsJson") then return true end
	if inst:GetAttribute("StackKey") then return true end
	if inst:GetAttribute("Width") and inst:GetAttribute("Height") then return true end
	return false
end

-- 프레임/래퍼 클릭 → 아이템 GUI로 보정
local function resolveItemGui(g: GuiObject): GuiObject?
	if isItemGui(g) then return g end
	local cur: Instance? = g
	for _ = 1, 5 do
		if not cur then break end
		if cur:IsA("GuiObject") and isItemGui(cur) then return cur end
		cur = cur.Parent
	end
	for _, d in ipairs(g:GetDescendants()) do
		if d:IsA("GuiObject") and isItemGui(d) then return d end
	end
	return nil
end

local function _isPointInside(gui: GuiObject, screenPos: Vector2): boolean
	local p, s = gui.AbsolutePosition, gui.AbsoluteSize
	return (screenPos.X >= p.X and screenPos.X <= p.X + s.X
		and screenPos.Y >= p.Y and screenPos.Y <= p.Y + s.Y)
end

local function _bindOutsideClose(menu: Frame)
	local c1: RBXScriptConnection? = nil
	local c2: RBXScriptConnection? = nil
	local function onInput(input: InputObject, gpe: boolean)
		if gpe or not menu.Parent then return end
		if input.UserInputType == Enum.UserInputType.MouseButton1
			or input.UserInputType == Enum.UserInputType.MouseButton2
			or input.UserInputType == Enum.UserInputType.Touch then
			if _isPointInside(menu, getMousePos()) then return end
			menu:Destroy()
			ACTIVE_MENU, ACTIVE_TARGET = nil, nil
		end
	end
	c1 = UserInputService.InputBegan:Connect(onInput)
	c2 = menu.AncestryChanged:Connect(function()
		if not menu.Parent then
			if c1 then c1:Disconnect() end
			if c2 then c2:Disconnect() end
		end
	end)
end

local function _placeBelow(target: GuiObject, menu: Frame)
	local overlay = _getOverlayRoot()
	menu.Parent = overlay
	menu.ZIndex = MENU_Z
	menu.ClipsDescendants = false
	local p, s = target.AbsolutePosition, target.AbsoluteSize
	menu.Position = UDim2.fromOffset(p.X, p.Y + s.Y + 4)
end

local function _makeButton(text: string, onClick: (() -> ())?)
	local b = Instance.new("TextButton")
	b.Name = "Btn_"..text
	b.Text = text
	b.AutoButtonColor = true
	b.Font = Enum.Font.Gotham
	b.TextSize = 14
	b.TextColor3 = Color3.new(1,1,1)
	b.BackgroundColor3 = Color3.fromRGB(35,35,35)
	b.Size = UDim2.new(1, -MENU_SIDE_PAD*2, 0, MENU_BTN_H)
	b.BorderSizePixel = 0
	b.ZIndex = MENU_Z
	local corner = Instance.new("UICorner"); corner.CornerRadius = UDim.new(0,6); corner.Parent = b
	if typeof(onClick) == "function" then
		b.MouseButton1Click:Connect(onClick)
	end
	return b
end

-- ===== 메타/음식 판별 =====
type ItemInfo = { tag: string?, stackKey: string?, category: string?, tags: {string} }

local function parseTagsJson(s: string?): {string}
	if not s or s == "" then return {} end
	local ok, arr = pcall(function() return HttpService:JSONDecode(s) end)
	if not ok or typeof(arr) ~= "table" then return {} end
	local out: {string} = {}
	for _, v in ipairs(arr) do
		if typeof(v) == "string" then table.insert(out, string.lower(v)) end
	end
	return out
end

local function getItemInfo(target: GuiObject): ItemInfo
	local tag = target:GetAttribute("Tag") and tostring(target:GetAttribute("Tag")) or nil
	local stackKey = target:GetAttribute("StackKey") and tostring(target:GetAttribute("StackKey")) or nil
	local category = target:GetAttribute("Category") and tostring(target:GetAttribute("Category")) or nil
	local tags = parseTagsJson(target:GetAttribute("TagsJson") and tostring(target:GetAttribute("TagsJson")) or nil)

	-- 서버 메타로 보조
	if GetStashData and tag then
		local ok, data = pcall(function() return GetStashData:InvokeServer(tag) end)
		if ok and typeof(data) == "table" then
			if not category or category == "" then
				category = (data :: any).Category and tostring((data :: any).Category) or category
			end
			if typeof((data :: any).Tags) == "table" then
				for _, t in ipairs((data :: any).Tags) do
					if typeof(t) == "string" then table.insert(tags, string.lower(t)) end
				end
			end
			-- 음식 힌트(Consume/ConsumeHint)도 체크할 수 있게 저장
			if (data :: any).Consume or (data :: any).ConsumeHint then
				table.insert(tags, "food") -- 메뉴 판정에 도움
			end
		end
	end
	return { tag = tag, stackKey = stackKey, category = category, tags = tags }
end

local function isFood(info: ItemInfo): boolean
	if info.category and string.lower(info.category) == "food" then return true end
	for _, t in ipairs(info.tags) do
		if t == "food" then return true end
	end
	return false
end

-- ===== 동작 구현 =====
local function doEat(target: GuiObject)
	if not RequestConsume then
		warn("[ItemContextMenu] RequestConsume RemoteFunction이 없습니다(Remotes.RequestConsume)")
		return
	end
	local info = getItemInfo(target)
	if not info.tag then
		warn("[ItemContextMenu] 태그를 알 수 없어 먹기 취소")
		return
	end
	local ok, resOrErr = pcall(function()
		return RequestConsume:InvokeServer({ tag = info.tag, stackKey = info.stackKey })
	end)
	if not ok then
		warn("[ItemContextMenu] 서버 소비 호출 실패: ", tostring(resOrErr))
		return
	end
	local res = resOrErr
	if typeof(res) == "table" and res.ok == true then
		-- (선택) 클라 인벤에서 즉시 제거 훅
		if _G and typeof((_G :: any).EFR_INVENTORY_CLIENT_REMOVE) == "function" and info.stackKey then
			pcall(function() (_G :: any).EFR_INVENTORY_CLIENT_REMOVE(info.stackKey) end)
		end
		print(("[Eat] %s consumed %s → E=%s H=%s")
			:format(Players.LocalPlayer.Name, info.tag, tostring(res.energy), tostring(res.hydration)))
	else
		warn("[ItemContextMenu] 소비 거부: ", typeof(res)=="table" and tostring(res.reason) or "?")
	end
end

-- ===== 메뉴 생성 =====
local function _buildMenuFor(target: GuiObject): Frame
	local menu = Instance.new("Frame")
	menu.Name = "ItemContextMenu"
	menu.BackgroundColor3 = MENU_BG
	menu.BorderSizePixel = 0
	menu.ZIndex = MENU_Z
	menu.Active = true

	local layout = Instance.new("UIListLayout")
	layout.FillDirection = Enum.FillDirection.Vertical
	layout.HorizontalAlignment = Enum.HorizontalAlignment.Center
	layout.VerticalAlignment  = Enum.VerticalAlignment.Top
	layout.Padding = UDim.new(0, MENU_BTN_PAD)
	layout.Parent = menu

	local pad = Instance.new("UIPadding")
	pad.PaddingTop    = UDim.new(0, MENU_BTN_PAD)
	pad.PaddingBottom = UDim.new(0, MENU_BTN_PAD)
	pad.PaddingLeft   = UDim.new(0, MENU_SIDE_PAD)
	pad.PaddingRight  = UDim.new(0, MENU_SIDE_PAD)
	pad.Parent = menu

	local corner = Instance.new("UICorner"); corner.CornerRadius = UDim.new(0,8); corner.Parent = menu

	-- 음식 여부 판정
	local info = getItemInfo(target)
	if isFood(info) then
		-- 음식: '먹기'만 노출
		local eatBtn = _makeButton("먹기", function()
			doEat(target)
			if menu then menu:Destroy() end
			ACTIVE_MENU, ACTIVE_TARGET = nil, nil
		end)
		eatBtn.Parent = menu
	else
		-- 그 외: 기존 '모딩'
		local modBtn = _makeButton("모딩", function()
			local item = resolveItemGui(target)
			if not item then
				warn("[ItemContextMenu] 아이템 GUI를 찾지 못했습니다:", target:GetFullName())
			elseif WeaponModding and typeof(WeaponModding.Open) == "function" then
				WeaponModding.Open(item)
			else
				warn("[ItemContextMenu] WeaponModding.Open 이 없어 호출을 건너뜀")
			end
			if menu then menu:Destroy() end
			ACTIVE_MENU, ACTIVE_TARGET = nil, nil
		end)
		modBtn.Parent = menu
	end

	-- 크기/배치
	task.defer(function()
		local count = 0
		for _, ch in ipairs(menu:GetChildren()) do
			if ch:IsA("GuiObject") and ch ~= pad then count += 1 end
		end
		local h = MENU_BTN_PAD*2 + count*MENU_BTN_H + math.max(0,(count-1))*MENU_BTN_PAD
		menu.Size = UDim2.fromOffset(math.max(target.AbsoluteSize.X, 140), h)
		_placeBelow(target, menu)
	end)

	_bindOutsideClose(menu)
	return menu
end

local function _toggleMenu(target: GuiObject)
	if ACTIVE_MENU and ACTIVE_TARGET == target then
		ACTIVE_MENU:Destroy(); ACTIVE_MENU, ACTIVE_TARGET = nil, nil; return
	end
	if ACTIVE_MENU then ACTIVE_MENU:Destroy() end
	local m = _buildMenuFor(target)
	ACTIVE_MENU, ACTIVE_TARGET = m, target
end

local function _bindRightClick(target: GuiObject)
	if target:GetAttribute("__icm_bound") then return end
	target:SetAttribute("__icm_bound", true)
	target.InputBegan:Connect(function(input: InputObject)
		if input.UserInputType == Enum.UserInputType.MouseButton2 then
			local item = resolveItemGui(target)
			if item then _toggleMenu(item) end
		end
	end)
end

function ItemContextMenu.AttachTo(gui: Instance)
	if gui and gui:IsA("GuiObject") and isItemGui(gui) then
		_bindRightClick(gui)
	end
end

function ItemContextMenu.AutoBindUnder(container: Instance)
	if not container then return end
	for _, d in ipairs(container:GetDescendants()) do
		if d:IsA("GuiObject") and isItemGui(d) then _bindRightClick(d) end
	end
	container.DescendantAdded:Connect(function(d)
		if d:IsA("GuiObject") and isItemGui(d) then _bindRightClick(d) end
	end)
end

return ItemContextMenu
