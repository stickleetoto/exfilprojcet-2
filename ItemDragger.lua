--!strict
-- ReplicatedStorage/ItemDragger.lua
-- 드래그 배치 + 회전 + 오토스크롤 + 스택 병합 + 장비 슬롯 드랍
-- (탄→탄창) 장전 지원 / 전량 장전·완전 병합 시 점유 정리 + GUI 제거 확실화

local UserInputService   = game:GetService("UserInputService")
local RunService         = game:GetService("RunService")
local GuiService         = game:GetService("GuiService")
local ReplicatedStorage  = game:GetService("ReplicatedStorage")
local HttpService        = game:GetService("HttpService")

local StackBadge      = require(ReplicatedStorage:WaitForChild("StackBadge"))
local SlotMapRegistry = require(ReplicatedStorage:WaitForChild("SlotMapRegistry"))
local MagService      = require(ReplicatedStorage:WaitForChild("MagService"))

local WeaponMods, WeaponAttachSvc do
	local ok1, mod1 = pcall(function() return require(ReplicatedStorage:WaitForChild("WeaponMods")) end)
	if ok1 then WeaponMods = mod1 else
		WeaponMods = { WriteMagFromGui = function() return {} end }
	end
	local ok2, mod2 = pcall(function() return require(ReplicatedStorage:WaitForChild("WeaponAttachService")) end)
	if ok2 then WeaponAttachSvc = mod2 else
		WeaponAttachSvc = { ApplyModsToModel = function(...) end }
	end
end
local GuiService = game:GetService("GuiService")

local function rootIgnoresInset(inst: Instance): boolean
	local cur = inst
	while cur and cur.Parent do
		if cur:IsA("ScreenGui") then
			return (cur :: ScreenGui).IgnoreGuiInset == true
		end
		cur = cur.Parent
	end
	return false
end
local ItemDragger = {}

-- ===== 튜닝 =====
local SLOT = 40
local AUTOSCROLL_MARGIN = 24
local AUTOSCROLL_MAXSPD = 14
local DEFAULT_AMMO_STACK_MAX = 60

-- ===== 점유자 ID =====
local GetOccId
do
	local ok, mod = pcall(function()
		return require(ReplicatedStorage:WaitForChild("Utils"):WaitForChild("GetOccId"))
	end)
	if ok and typeof(mod) == "function" then
		GetOccId = mod
	else
		GetOccId = function(gui: Instance, itemData: any?): any
			local id = gui and gui:GetAttribute("ItemUID")
			if typeof(id)=="string" and id~="" then return id end
			local v = itemData and (itemData.UID or itemData.Id or itemData.id)
			if v ~= nil then return v end
			local newId = HttpService:GenerateGUID(false)
			if gui then gui:SetAttribute("ItemUID", newId) end
			return newId
		end
	end
end

-- ===== 태그/스택 유틸 =====
local function getTagsFromGui(gui: Instance): {string}
	if not gui then return {} end
	local out: {string} = {}

	-- JSON 배열
	local okJ, arr = pcall(function()
		local j = gui:GetAttribute("TagsJson")
		return (typeof(j)=="string" and #j>0) and HttpService:JSONDecode(j) or nil
	end)
	if okJ and typeof(arr)=="table" then
		for _, t in ipairs(arr) do
			if typeof(t)=="string" then out[#out+1] = string.lower(t) end
		end
	end

	-- CSV 문자열
	local csv = gui:GetAttribute("Tags")
	if typeof(csv)=="string" and #csv>0 then
		for tok in string.gmatch(csv, "[^,%s]+") do
			out[#out+1] = string.lower(tok)
		end
	end

	-- 단일 Tag
	local t = gui:GetAttribute("Tag")
	if typeof(t)=="string" and #t>0 then
		out[#out+1] = string.lower(t)
	end

	-- 중복 제거
	local uniq, seen = {}, {}
	for _, v in ipairs(out) do
		if not seen[v] then seen[v]=true; uniq[#uniq+1]=v end
	end
	return uniq
end

local function hasTag(tags:{string}, want:string): boolean
	want = string.lower(want)
	for _,t in ipairs(tags) do if t==want then return true end end
	return false
end

local function isAmmo(gui: Instance): boolean
	for _, t in ipairs(getTagsFromGui(gui)) do
		if t == "ammo" then return true end
	end
	return false
end
local function isMag(gui: Instance): boolean
	return gui and gui:GetAttribute("IsMag") == true
end

local function isWeapon(gui: Instance): boolean
	local tags = getTagsFromGui(gui)
	for _, t in ipairs(tags) do
		if t == "primaryweapon" or t == "secondaryweapon" then return true end
	end
	return false
end


local function getNameFromGui(gui: Instance): string
	local n = gui:GetAttribute("ItemName")
	if typeof(n)=="string" and #n>0 then return n end
	local n2 = gui:GetAttribute("Name")
	if typeof(n2)=="string" and #n2>0 then return n2 end
	return gui.Name
end

local function getCount(gui: Instance): number
	return tonumber(gui:GetAttribute("Count")) or 1
end
local function setCount(gui: Instance, n: number)
	gui:SetAttribute("Count", n)
	StackBadge.Update(gui, n)
end

-- StackMax: Attr -> Tags의 stackmax:<n> -> ammo=60 -> 1
local function getStackMax(gui: Instance, tags:{string}?): number
	tags = tags or getTagsFromGui(gui)
	local sm = gui:GetAttribute("StackMax")
	if typeof(sm)=="number" and sm >= 2 then return math.floor(sm) end
	for _, t in ipairs(tags) do
		if string.sub(t,1,9)=="stackmax:" then
			local n = tonumber(string.sub(t,10))
			if n and n >= 2 then return math.floor(n) end
		end
	end
	if hasTag(tags, "ammo") then return DEFAULT_AMMO_STACK_MAX end
	return 1
end

-- 병합키: StackKey -> (ammo: "ammo|name|cal") -> (generic: "gen|name")
local function mergeKeyOf(gui: Instance): string?
	local tags = getTagsFromGui(gui)
	if getStackMax(gui, tags) <= 1 then return nil end

	local sk = gui:GetAttribute("StackKey")
	if typeof(sk)=="string" and #sk>0 then
		return string.lower(sk)
	end

	local name = string.lower(getNameFromGui(gui))
	if hasTag(tags, "ammo") then
		local cal = ""
		for _, tt in ipairs(tags) do
			if string.sub(tt,1,4)=="cal:" then cal = tt break end
		end
		return "ammo|"..name.."|"..cal
	end
	return "gen|"..name
end

local function isMouseOverFrame(mousePos: Vector2, frame: GuiObject, padding: number?)
	if not frame then return false end
	padding = padding or 6

	-- 프레임이 속한 ScreenGui가 인셋을 무시하지 않으면, 마우스 좌표에서 인셋을 빼야 같은 좌표계가 됨.
	local inset = rootIgnoresInset(frame) and Vector2.zero or GuiService:GetGuiInset()
	local mx = mousePos.X - inset.X
	local my = mousePos.Y - inset.Y

	local p, s = frame.AbsolutePosition, frame.AbsoluteSize
	return (mx >= p.X - padding and mx <= p.X + s.X + padding)
		and (my >= p.Y - padding and my <= p.Y + s.Y + padding)
end
local function localPosInFrame(mousePos: Vector2, _guiInset: Vector2, frame: GuiObject)
	-- 여기서도 동일하게: 해당 프레임이 속한 ScreenGui가 인셋을 무시하면 보정 없음.
	local inset = rootIgnoresInset(frame) and Vector2.zero or GuiService:GetGuiInset()

	local x = mousePos.X - inset.X - frame.AbsolutePosition.X
	local y = mousePos.Y - inset.Y - frame.AbsolutePosition.Y
	if frame.ClassName == "ScrollingFrame" then
		local sc = frame :: ScrollingFrame
		x += sc.CanvasPosition.X
		y += sc.CanvasPosition.Y
	end
	return x, y
end
local function snapToCell(px:number, py:number, w:number, h:number, rows:number, cols:number)
	local maxC = math.max(1, (cols or 1) - w + 1)
	local maxR = math.max(1, (rows or 1) - h + 1)
	local EPS = 0.0001
	local col = math.floor((px + SLOT*0.5 + EPS) / SLOT) + 1
	local row = math.floor((py + SLOT*0.5 + EPS) / SLOT) + 1
	col = math.clamp(col, 1, maxC)
	row = math.clamp(row, 1, maxR)
	return row, col
end

local function autoscrollUnderMouse(sc: ScrollingFrame, gx:number, gy:number, mapCols:number, mapRows:number)
	local visW, visH = sc.AbsoluteSize.X, sc.AbsoluteSize.Y
	local maxX = math.max(0, mapCols * SLOT - visW)
	local maxY = math.max(0, mapRows * SLOT - visH)

	local dx = 0
	if gx < AUTOSCROLL_MARGIN then
		dx = -math.clamp(AUTOSCROLL_MAXSPD * (AUTOSCROLL_MARGIN - gx) / AUTOSCROLL_MARGIN, 0, AUTOSCROLL_MAXSPD)
	elseif gx > visW - AUTOSCROLL_MARGIN then
		dx = math.clamp(AUTOSCROLL_MAXSPD * (gx - (visW - AUTOSCROLL_MARGIN)) / AUTOSCROLL_MARGIN, 0, AUTOSCROLL_MAXSPD)
	end

	local dy = 0
	if gy < AUTOSCROLL_MARGIN then
		dy = -math.clamp(AUTOSCROLL_MAXSPD * (AUTOSCROLL_MARGIN - gy) / AUTOSCROLL_MARGIN, 0, AUTOSCROLL_MAXSPD)
	elseif gy > visH - AUTOSCROLL_MARGIN then
		dy = math.clamp(AUTOSCROLL_MAXSPD * (gy - (visH - AUTOSCROLL_MARGIN)) / AUTOSCROLL_MARGIN, 0, AUTOSCROLL_MAXSPD)
	end

	if dx ~= 0 or dy ~= 0 then
		local cp = sc.CanvasPosition
		local nx = math.clamp(cp.X + dx, 0, maxX)
		local ny = math.clamp(cp.Y + dy, 0, maxY)
		sc.CanvasPosition = Vector2.new(nx, ny)
	end
end

-- ===== 맵/그리드 헬퍼 =====
local function tryFindInventoryGui(from: Instance): Instance?
	local cur = from
	while cur and cur.Parent do
		if cur.Name == "InventoryGui" then return cur end
		cur = cur.Parent
	end
	return nil
end

local function getMapAnyCase(key:string)
	return SlotMapRegistry.Get(key)
		or SlotMapRegistry.Get(string.lower(key))
		or SlotMapRegistry.Get(string.upper(key))
		or SlotMapRegistry.Get((string.lower(key):gsub("^%l", string.upper)))
end

local function mapFromScroll(sc: Instance): any
	if not sc or not sc:IsA("ScrollingFrame") then return nil end
	local gk = sc:GetAttribute("GridKey")
	if typeof(gk)=="string" and #gk>0 then
		return SlotMapRegistry.Get(gk)
	end
	local pop = sc.Parent and sc.Parent.Parent
	if pop then
		local tag = pop:GetAttribute("ContainerTag")
		if typeof(tag)=="string" and #tag>0 then
			return getMapAnyCase(tag)
		end
	end
	return nil
end

local function buildDefaultGridList(parentFrame: GuiObject, defaultMap: any)
	local list = {}
	local function push(frame, map)
		if not (frame and map) then return end
		for _, it in ipairs(list) do
			if it.Frame == frame or it.Map == map then return end
		end
		list[#list+1] = { Frame = frame, Map = map }
	end

	if defaultMap and parentFrame then push(parentFrame, defaultMap) end
	local inv = tryFindInventoryGui(parentFrame)
	if not inv then return list end

	-- 스태시
	local stashFrame = inv:FindFirstChild("ScrollingInventory")
	local stashMap   = getMapAnyCase("Stash")
	if stashFrame and stashMap then push(stashFrame, stashMap) end

	-- 포켓 + 바디그리드
	local equipIngame = inv:FindFirstChild("Equipmentingame")
	if equipIngame then
		local pocketFrame = equipIngame:FindFirstChild("poket")
		local pocketMap = getMapAnyCase("Pocket")
		if pocketFrame and pocketMap then push(pocketFrame, pocketMap) end

		local body = inv:FindFirstChild("BodyGrids")
		if body then
			for _, fr in ipairs(body:GetChildren()) do
				if fr:IsA("Frame") then
					local sc = fr:FindFirstChild("Scroll")
					if sc and sc:IsA("ScrollingFrame") then
						local map = mapFromScroll(sc)
						if map then push(sc, map) end
					end
				end
			end
		end
	end

	-- 슬롯 팝아웃(컨테이너)
	local slotPopouts = inv:FindFirstChild("SlotPopouts")
	if slotPopouts then
		for _, pop in ipairs(slotPopouts:GetChildren()) do
			if pop:IsA("Frame") then
				local area = pop:FindFirstChild("GridArea")
				local sc   = area and area:FindFirstChild("Scroll")
				if sc and sc:IsA("ScrollingFrame") then
					local map = mapFromScroll(sc)
					if map then push(sc, map) end
				end
			end
		end
	end

	return list
end

local function ensureGridMapFor(frame: GuiObject, currentMap: any)
	if currentMap then return currentMap end
	if frame and frame:IsA("ScrollingFrame") then
		return mapFromScroll(frame) or currentMap
	end
	return currentMap
end

local function getHoverGrid(mousePos: Vector2, grids: {any}?): any
	if not grids then return nil end
	for _, g in ipairs(grids) do
		if g and g.Frame and isMouseOverFrame(mousePos, g.Frame, 6) then
			return g
		end
	end
	return nil
end

local function findHoverGridDynamic(mousePos: Vector2, context: Instance?)
	local inv = tryFindInventoryGui(context or Instance.new("Folder"))
	if not inv then return nil end
	local function check(sc: Instance)
		if sc and sc:IsA("ScrollingFrame") and isMouseOverFrame(mousePos, sc, 6) then
			local map = mapFromScroll(sc)
			if map then return { Frame = sc, Map = map } end
		end
		return nil
	end

	local slotPopouts = inv:FindFirstChild("SlotPopouts")
	if slotPopouts then
		for _, pop in ipairs(slotPopouts:GetChildren()) do
			if pop:IsA("Frame") then
				local area = pop:FindFirstChild("GridArea")
				local sc   = area and area:FindFirstChild("Scroll")
				local hit = check(sc); if hit then return hit end
			end
		end
	end

	local body = inv:FindFirstChild("BodyGrids")
	if body then
		for _, fr in ipairs(body:GetChildren()) do
			if fr:IsA("Frame") then
				local sc = fr:FindFirstChild("Scroll")
				local hit = check(sc); if hit then return hit end
			end
		end
	end

	local equipIngame = inv:FindFirstChild("Equipmentingame")
	if equipIngame then
		local pocket = equipIngame:FindFirstChild("poket")
		if pocket and pocket:IsA("GuiObject") and isMouseOverFrame(mousePos, pocket, 6) then
			local pmap = getMapAnyCase("Pocket")
			if pmap then return { Frame = pocket :: GuiObject, Map = pmap } end
		end
	end

	local stash = inv:FindFirstChild("ScrollingInventory")
	local hit = check(stash); if hit then return hit end

	return nil
end

-- ===== UIStroke =====
local function ensureStroke(image: ImageLabel): UIStroke
	local stroke = image:FindFirstChild("DragStroke")
	if stroke and stroke:IsA("UIStroke") then return stroke end
	local s = Instance.new("UIStroke")
	s.Name = "DragStroke"
	s.Thickness = 1
	s.ApplyStrokeMode = Enum.ApplyStrokeMode.Border
	s.Enabled = false
	s.Parent = image
	return s
end
local function setStroke(stroke: UIStroke, good:boolean?)
	if good == nil then stroke.Enabled = false return end
	stroke.Enabled = true
	stroke.Color = good and Color3.fromRGB(60,220,120) or Color3.fromRGB(220,70,70)
end

-- ===== (추가) 장비 슬롯 허용 태그 유틸 =====
local function getSlotAcceptTags(slotFrame: Instance): {string}
	if not slotFrame then return {} end
	local ok, arr = pcall(function()
		local j = slotFrame:GetAttribute("AcceptTagsJson")
		if typeof(j) ~= "string" or j == "" then return nil end
		return HttpService:JSONDecode(j)
	end)
	if ok and typeof(arr) == "table" then
		local out = {}
		for _, t in ipairs(arr) do
			if typeof(t)=="string" then out[#out+1] = string.lower(t) end
		end
		return out
	end
	local p = slotFrame:GetAttribute("PrimaryTag")
	return (typeof(p)=="string" and p~="") and { string.lower(p) } or {}
end
local function tagsIntersect(itemTags:{string}, acceptTags:{string}): boolean
	if #itemTags == 0 or #acceptTags == 0 then return false end
	local set: {[string]: boolean} = {}
	for _, t in ipairs(itemTags) do set[t]=true end
	for _, a in ipairs(acceptTags) do if set[a] then return true end end
	return false
end
local function tagsAllowed(itemTags:{string}, acceptTags:{string}): boolean
	return (#acceptTags == 0) or tagsIntersect(itemTags, acceptTags)
end

-- ===== (추가) 점유 정리 + Destroy 안전 헬퍼 =====
local function findOwnerScroll(gui: Instance): ScrollingFrame?
	local sc: Instance? = gui.Parent
	while sc and sc.Parent and not sc:IsA("ScrollingFrame") do
		sc = sc.Parent
	end
	return (sc and sc:IsA("ScrollingFrame")) and (sc :: any) or nil
end

local function safeClearOccupancyByAttrs(map:any?, gui: Instance, fallbackOcc:any?)
	if not gui then return end
	local r = tonumber(gui:GetAttribute("Row"))
	local c = tonumber(gui:GetAttribute("Col"))
	local w = tonumber(gui:GetAttribute("Width")) or 1
	local h = tonumber(gui:GetAttribute("Height")) or 1
	local occId = fallbackOcc
	if not occId then
		local id = gui:GetAttribute("ItemUID") or gui:GetAttribute("Id")
		occId = id
	end
	if map and r and c then
		pcall(function() map:ClearArea(r, c, w, h, occId) end)
		return true
	end
	return false
end

local function purgeEverywhere(occ:any?)
	if not occ then return end
	local ok, f = pcall(function() return (SlotMapRegistry :: any).PurgeId end)
	if ok and typeof(f)=="function" then
		pcall(function() f(occ) end)
	end
end

local function clearAndDestroy(gui: GuiObject, itemData: table, originMap:any?)
	if not gui then return end
	local occId = GetOccId(gui, itemData)
	-- 1) 우선 originMap 시도
	if originMap then
		if safeClearOccupancyByAttrs(originMap, gui, occId) then
			gui:Destroy(); return
		end
	end
	-- 2) 소유 스크롤에서 map 재구성
	local sc = findOwnerScroll(gui)
	local map = sc and mapFromScroll(sc)
	if map then
		if safeClearOccupancyByAttrs(map, gui, occId) then
			gui:Destroy(); return
		end
	end
	-- 3) 최후: 전역 PurgeId
	purgeEverywhere(occId)
	gui:Destroy()
end

-- ===== 메인 =====
function ItemDragger.EnableDrag(image: ImageLabel, itemData: table, parentFrame: GuiObject, defaultMap: any, equipmentSlotMap: any, gridList: any, opts: any)
	if image:FindFirstChild("__DragBound") then return end
	Instance.new("BoolValue", image).Name = "__DragBound"

	opts = opts or {}
	local allowRotate = (opts.allowRotate ~= false)
	local rotateKey = opts.rotateKey or Enum.KeyCode.R

	itemData.BaseWidth  = itemData.BaseWidth  or itemData.Width
	itemData.BaseHeight = itemData.BaseHeight or itemData.Height
	itemData.Rotated    = itemData.Rotated or false

	local stroke = ensureStroke(image)

	image.InputBegan:Connect(function(input)
		if input.UserInputType ~= Enum.UserInputType.MouseButton1 then return end

		local dragging = true
		local occId = GetOccId(image, itemData)
		image:SetAttribute("Id", occId)
		image:SetAttribute("ItemUID", occId)
		local original = {
			Pos = image.Position,
			Parent = image.Parent,
			Z = image.ZIndex,
			Row = itemData.Row, Col = itemData.Col,
			W = itemData.Width, H = itemData.Height,
			Rot = itemData.Rotated == true,
			WasEquipped = itemData.IsEquipped == true,
			MapRef = itemData.MapRef,
			Anchor = image.AnchorPoint,
			Visible = image.Visible,
		}

		local draggedKey: string? = mergeKeyOf(image)

		local function refreshGridList()
			gridList = buildDefaultGridList(parentFrame, defaultMap)
		end
		if not gridList then refreshGridList() end

		-- 시작 위치 맵 (late-clear)
		local originMap = original.MapRef
		if not originMap and gridList and original.Parent then
			for _, g in ipairs(gridList) do
				if g and g.Frame and (original.Parent==g.Frame or original.Parent:IsDescendantOf(g.Frame)) then
					originMap = g.Map
					break
				end
			end
		end

		-- (추가) 장비 슬롯 점유 참조
		local equippedSlotRef: any = nil
		if equipmentSlotMap then
			for _, slotData in pairs(equipmentSlotMap) do
				if slotData.Frame and slotData.EquippedItem == image then
					equippedSlotRef = slotData
					break
				end
			end
		end

		local prevW = itemData.BaseWidth
		local prevH = itemData.BaseHeight
		if original.Rot then prevW, prevH = prevH, prevW end

		local dragLayer = (function()
			local inv = tryFindInventoryGui(parentFrame)
			local layer = inv and inv:FindFirstChild("DragLayer")
			if layer and layer:IsA("Frame") then return layer end
			layer = Instance.new("Frame")
			layer.Name = "DragLayer"
			layer.BackgroundTransparency = 1
			layer.Size = UDim2.fromScale(1, 1)
			layer.ClipsDescendants = false
			layer.ZIndex = 9000
			(layer :: GuiObject).Parent = inv or image.Parent
			return layer
		end)()

		image.AnchorPoint = Vector2.new(0,0)
		image.ZIndex = 2000
		image.Parent = dragLayer
		image.Size = UDim2.fromOffset(SLOT * prevW, SLOT * prevH)
		image.Visible = true
		setStroke(stroke, nil)

		local mouseOffset: Vector2
		do
			local m = UserInputService:GetMouseLocation()
			local inset = GuiService:GetGuiInset()
			local x = m.X - inset.X - dragLayer.AbsolutePosition.X
			local y = m.Y - inset.Y - dragLayer.AbsolutePosition.Y
			local px = math.floor(x - (SLOT * prevW) / 2)
			local py = math.floor(y - (SLOT * prevH) / 2)
			image.Position = UDim2.fromOffset(px, py)
			mouseOffset = Vector2.new(x - px, y - py)
		end

		local conns: {[string]: RBXScriptConnection} = {}

		-- 팝아웃 동적 갱신
		do
			local inv = tryFindInventoryGui(parentFrame)
			if inv then
				local popouts = inv:FindFirstChild("SlotPopouts")
				if popouts then
					conns["popAdd"] = popouts.ChildAdded:Connect(refreshGridList)
					conns["popRem"] = popouts.ChildRemoved:Connect(refreshGridList)
				end
			end
		end

		-- 회전/취소
		if allowRotate then
			conns["rotate"] = UserInputService.InputBegan:Connect(function(kb)
				if kb.UserInputType ~= Enum.UserInputType.Keyboard then return end
				if kb.KeyCode == rotateKey then
					prevW, prevH = prevH, prevW
					image.Size = UDim2.fromOffset(SLOT * prevW, SLOT * prevH)
					local m = UserInputService:GetMouseLocation()
					local inset = GuiService:GetGuiInset()
					local x = m.X - inset.X - dragLayer.AbsolutePosition.X
					local y = m.Y - inset.Y - dragLayer.AbsolutePosition.Y
					local px = math.floor(x - (SLOT * prevW) / 2)
					local py = math.floor(y - (SLOT * prevH) / 2)
					image.Position = UDim2.fromOffset(px, py)
					mouseOffset = Vector2.new(x - px, y - py)
				elseif kb.KeyCode == Enum.KeyCode.Escape then
					dragging = false
				end
			end)
		end

		local function restoreAndRemark()
			image.Parent = original.Parent
			image.Position = original.Pos
			if original.W and original.H then
				if original.Row and original.Col then
					image.Size = UDim2.fromOffset(SLOT * original.W, SLOT * original.H)
				else
					image.Size = UDim2.fromScale(1,1)
				end
			end
			itemData.IsEquipped = original.WasEquipped
			itemData.Row, itemData.Col = original.Row, original.Col
			itemData.Width, itemData.Height = original.W, original.H
			itemData.Rotated = original.Rot
			itemData.MapRef = original.MapRef
			image.ZIndex = original.Z
			image.AnchorPoint = original.Anchor
			image.Visible = original.Visible ~= false
			setStroke(stroke, nil)
		end

		-- 미리보기(병합/빈칸) + 장비 슬롯 프리뷰
		conns["render"] = RunService.RenderStepped:Connect(function()
			if not dragging then return end

			local m = UserInputService:GetMouseLocation()
			local inset = GuiService:GetGuiInset()
			local x = m.X - inset.X - dragLayer.AbsolutePosition.X
			local y = m.Y - inset.Y - dragLayer.AbsolutePosition.Y
			image.Position = UDim2.fromOffset(x - mouseOffset.X, y - mouseOffset.Y)

			-- 장비 슬롯 프리뷰 우선
			if equipmentSlotMap then
				local itemTags = getTagsFromGui(image)
				local target, fallback = nil, nil
				for _, slotData in pairs(equipmentSlotMap) do
					local f = slotData.Frame
					if f and isMouseOverFrame(m, f, 6) then
						fallback = fallback or slotData
						local accept = getSlotAcceptTags(f)
						local allow = tagsAllowed(itemTags, accept)
						local freeOrSame = (not slotData.Occupied) or (slotData == equippedSlotRef)
						if freeOrSame and allow then
							target = slotData
							break
						end
					end
				end
				if target or fallback then
					local cand = target or fallback
					local accept = getSlotAcceptTags(cand.Frame)
					local allow = tagsAllowed(itemTags, accept)
					local freeOrSame = (not cand.Occupied) or (cand == equippedSlotRef)
					setStroke(stroke, freeOrSame and allow)
					return
				end
			end

			-- 그리드 프리뷰
			local hover = getHoverGrid(m, gridList) or findHoverGridDynamic(m, dragLayer)
			if not hover then setStroke(stroke, false) return end
			hover.Map = ensureGridMapFor(hover.Frame, hover.Map)
			if not (hover.Map and hover.Map.rows and hover.Map.cols) then setStroke(stroke, false) return end

			-- 오토스크롤
			if hover.Frame:IsA("ScrollingFrame") then
				local sc = hover.Frame :: ScrollingFrame
				local gx, gy = localPosInFrame(m, inset, sc)
				autoscrollUnderMouse(sc, gx, gy, hover.Map.cols, hover.Map.rows)
			end

			local r, c = hover.Map.rows, hover.Map.cols
			local gx, gy = localPosInFrame(m, inset, hover.Frame)
			local row, col = snapToCell(gx - mouseOffset.X, gy - mouseOffset.Y, prevW, prevH, r, c)
			row = math.clamp(row, 1, math.max(1, r - prevH + 1))
			col = math.clamp(col, 1, math.max(1, c - prevW + 1))

			-- 같은 맵일 때만 ignoreId 적용
			local ignoreId = (originMap and hover.Map == originMap) and occId or nil
			local canPlace = hover.Map:IsAreaFree(row, col, prevW, prevH, ignoreId)

			-- (탄 → 탄창) 프리뷰
			if isAmmo(image) then
				local function _rectOf(g: GuiObject)
					if g.Size.X.Scale ~= 0 or g.Size.Y.Scale ~= 0 then return nil end
					local w = math.max(1, math.floor(g.Size.X.Offset / SLOT + 0.5))
					local h = math.max(1, math.floor(g.Size.Y.Offset / SLOT + 0.5))
					local cc = math.floor(g.Position.X.Offset / SLOT + 0.5) + 1
					local rr = math.floor(g.Position.Y.Offset / SLOT + 0.5) + 1
					return rr, cc, h, w
				end
				local function _covers(g: GuiObject, r2:number, c2:number): boolean
					local rr, cc, hh, ww = _rectOf(g)
					if not rr then return false end
					return (r2 >= rr and r2 <= rr + hh - 1 and c2 >= cc and c2 <= cc + ww - 1)
				end
				local top: GuiObject? = nil
				for _, ch in ipairs(hover.Frame:GetChildren()) do
					if (ch:IsA("ImageLabel") or ch:IsA("ViewportFrame")) and ch.Visible then
						if _covers(ch, row, col) then top = ch; break end
					end
				end
				if top and isMag(top) then
					local can = MagService.CanLoadAmmo(top, image)
					local free = MagService.GetFree(top)
					canPlace = (can and free > 0)
				end
			end

			-- 병합 후보 검사
			if not canPlace and draggedKey then
				local function rectOfGuiInGrid(gui: GuiObject)
					if gui.Size.X.Scale ~= 0 or gui.Size.Y.Scale ~= 0 then return nil end
					local w = math.max(1, math.floor(gui.Size.X.Offset / SLOT + 0.5))
					local h = math.max(1, math.floor(gui.Size.Y.Offset / SLOT + 0.5))
					local cc = math.floor(gui.Position.X.Offset / SLOT + 0.5) + 1
					local rr = math.floor(gui.Position.Y.Offset / SLOT + 0.5) + 1
					return rr, cc, h, w
				end
				local function guiCoversCell(gui: GuiObject, row2:number, col2:number): boolean
					local rr, cc, hh, ww = rectOfGuiInGrid(gui)
					if not rr then return false end
					return (row2 >= rr and row2 <= rr + hh - 1 and col2 >= cc and col2 <= cc + ww - 1)
				end
				local primary: GuiObject? = nil
				local fallback: GuiObject? = nil
				local fallbackSpace = -1
				for _, ch in ipairs(hover.Frame:GetChildren()) do
					if (ch:IsA("ImageLabel") or ch:IsA("ViewportFrame")) and ch.Visible then
						if guiCoversCell(ch, row, col) then
							local key = mergeKeyOf(ch)
							if key and key == draggedKey then
								local rr, cc = (function(g:GuiObject)
									local c2 = math.floor(g.Position.X.Offset / SLOT + 0.5) + 1
									local r2 = math.floor(g.Position.Y.Offset / SLOT + 0.5) + 1
									return r2, c2
								end)(ch)
								local space = math.max(0, getStackMax(ch) - getCount(ch))
								if rr == row and cc == col then
									primary = ch; break
								end
								if space > fallbackSpace then
									fallbackSpace = space; fallback = ch
								end
							end
						end
					end
				end
				local cand = primary or fallback
				if cand then
					local anySpace = (getStackMax(cand) - getCount(cand) > 0)
					if not anySpace then
						for _, ch in ipairs(hover.Frame:GetChildren()) do
							if ch ~= cand and (ch:IsA("ImageLabel") or ch:IsA("ViewportFrame")) and ch.Visible then
								if mergeKeyOf(ch) == draggedKey and (getStackMax(ch) - getCount(ch) > 0) then
									anySpace = true; break
								end
							end
						end
					end
					canPlace = anySpace
				end
			end
			setStroke(stroke, canPlace)
		end)

		-- 드랍
		conns["ended"] = UserInputService.InputEnded:Connect(function(ie)
			if ie.UserInputType ~= Enum.UserInputType.MouseButton1
				and ie.UserInputType ~= Enum.UserInputType.MouseButton2 then return end

			dragging = false
			for _, c in pairs(conns) do
				if c and (c :: any).Disconnect then pcall(function() (c :: any):Disconnect() end) end
			end

			if ie.UserInputType == Enum.UserInputType.MouseButton2 then
				restoreAndRemark()
				return
			end

			local m = UserInputService:GetMouseLocation()

			local finalW, finalH = itemData.BaseWidth, itemData.BaseHeight
			if original.Rot then finalW, finalH = finalH, finalW end
			local finalRot = (finalW ~= itemData.BaseWidth or finalH ~= itemData.BaseHeight)

			-- (우선) 장비 슬롯 드랍
			if equipmentSlotMap then
				local itemTags = getTagsFromGui(image)
				local best, fallback = nil, nil
				for _, slotData in pairs(equipmentSlotMap) do
					local f = slotData.Frame
					if f and isMouseOverFrame(m, f, 6) then
						fallback = fallback or slotData
						local accept = getSlotAcceptTags(f)
						local allow = tagsAllowed(itemTags, accept)
						local freeOrSame = (not slotData.Occupied) or (slotData == equippedSlotRef)
						if freeOrSame and allow then
							best = slotData
							break
						end
					end
				end
				local target = best or fallback
				if target then
					local accept = getSlotAcceptTags(target.Frame)
					local allow = tagsAllowed(itemTags, accept)
					local freeOrSame = (not target.Occupied) or (target == equippedSlotRef)
					if freeOrSame and allow then
						-- 원본 Clear (성공 확정 후)
						if originMap and original.Row and original.Col then
							originMap:ClearArea(original.Row, original.Col, original.W, original.H, occId)
						else
							purgeEverywhere(occId)
						end
						if equippedSlotRef and equippedSlotRef ~= target then
							equippedSlotRef.Occupied = false
							equippedSlotRef.EquippedItem = nil
						end
						image.Parent = target.Frame
						image.Position = UDim2.fromOffset(0,0)
						image.Size = UDim2.fromScale(1,1)

						itemData.IsEquipped = true
						itemData.Row, itemData.Col = nil, nil
						itemData.Width, itemData.Height = itemData.BaseWidth, itemData.BaseHeight
						itemData.Rotated = false
						itemData.MapRef = nil

						target.Occupied = true
						target.EquippedItem = image

						image.AnchorPoint = original.Anchor
						image.ZIndex = original.Z
						setStroke(stroke, nil)
						return
					end
				end
			end

			-- 병합 우선 -> 빈칸 배치
			local hover = getHoverGrid(m, gridList) or findHoverGridDynamic(m, dragLayer)
			if hover then
				hover.Map = ensureGridMapFor(hover.Frame, hover.Map)
				if hover.Map and hover.Map.rows and hover.Map.cols then
					local r, c = hover.Map.rows, hover.Map.cols
					local inset = GuiService:GetGuiInset()
					local gx, gy = localPosInFrame(m, inset, hover.Frame)
					local row, col = snapToCell(gx - mouseOffset.X, gy - mouseOffset.Y, finalW, finalH, r, c)
					row = math.clamp(row, 1, math.max(1, r - finalH + 1))
					col = math.clamp(col, 1, math.max(1, c - finalW + 1))

					local inBounds = (row >= 1 and col >= 1
						and row + finalH - 1 <= r
						and col + finalW - 1 <= c)

					-- (탄 → 탄창) 장전 처리
					if inBounds and isAmmo(image) then
						local function _rectOf(g: GuiObject)
							if g.Size.X.Scale ~= 0 or g.Size.Y.Scale ~= 0 then return nil end
							local w = math.max(1, math.floor(g.Size.X.Offset / SLOT + 0.5))
							local h = math.max(1, math.floor(g.Size.Y.Offset / SLOT + 0.5))
							local cc = math.floor(g.Position.X.Offset / SLOT + 0.5) + 1
							local rr = math.floor(g.Position.Y.Offset / SLOT + 0.5) + 1
							return rr, cc, h, w
						end
						local function _covers(g: GuiObject, r2:number, c2:number): boolean
							local rr, cc, hh, ww = _rectOf(g)
							if not rr then return false end
							return (r2 >= rr and r2 <= rr + hh - 1 and c2 >= cc and c2 <= cc + ww - 1)
						end
						local top: GuiObject? = nil
						for _, ch in ipairs(hover.Frame:GetChildren()) do
							if (ch:IsA("ImageLabel") or ch:IsA("ViewportFrame")) and ch.Visible then
								if _covers(ch, row, col) then top = ch; break end
							end
						end
						if top and isMag(top) then
							if not MagService.CanLoadAmmo(top, image) or MagService.GetFree(top) <= 0 then
								-- 배치 실패(원위치)
								restoreAndRemark()
								setStroke(stroke, false)
								return
							end
							local moved = MagService.LoadFromAmmo(top, image)
							local left  = tonumber(image:GetAttribute("Count")) or 0
							if moved > 0 then
								if left <= 0 then
									-- ? 전량 장전: 점유 정리 후 GUI 제거(안전)
									clearAndDestroy(image, itemData, originMap)
									setStroke(stroke, nil)
									return
								else
									-- ? 부분 장전: 수량만 감소, 원위치 복귀
									restoreAndRemark()
									setStroke(stroke, nil)
									return
								end
							else
								restoreAndRemark()
								setStroke(stroke, false)
								return
							end
						end
					end


					-- (탄창 → 무기) 장착 처리
					if inBounds and isMag(image) then
						local function _rectOf(g: GuiObject)
							if g.Size.X.Scale ~= 0 or g.Size.Y.Scale ~= 0 then return nil end
							local w = math.max(1, math.floor(g.Size.X.Offset / SLOT + 0.5))
							local h = math.max(1, math.floor(g.Size.Y.Offset / SLOT + 0.5))
							local cc = math.floor(g.Position.X.Offset / SLOT + 0.5) + 1
							local rr = math.floor(g.Position.Y.Offset / SLOT + 0.5) + 1
							return rr, cc, h, w
						end
						local function _covers(g: GuiObject, r2:number, c2:number): boolean
							local rr, cc, hh, ww = _rectOf(g)
							if not rr then return false end
							return (r2 >= rr and r2 <= rr + hh - 1 and c2 >= cc and c2 <= cc + ww - 1)
						end
						local top: GuiObject? = nil
						for _, ch in ipairs(hover.Frame:GetChildren()) do
							if (ch:IsA("ImageLabel") or ch:IsA("ViewportFrame")) and ch.Visible then
								if _covers(ch, row, col) then top = ch; break end
							end
						end
						if top and isWeapon(top) then
							local mods = WeaponMods.WriteMagFromGui(top, image)
							-- 원본 Clear + GUI 제거(공용 함수)
							clearAndDestroy(image, itemData, originMap)
							-- 인벤토리 프리뷰(뷰포트)에 즉시 반영
							local vpf = top:FindFirstChildOfClass("ViewportFrame", true)
							if vpf then
								local mdl = vpf:FindFirstChildWhichIsA("Model", true)
								if mdl then
									pcall(function() WeaponAttachSvc.ApplyModsToModel(mdl, mods) end)
								end
							end
							setStroke(stroke, nil)
							return
						end
					end

					-- 1) 병합
					if inBounds and draggedKey then
						local function rectOfGuiInGrid(gui: GuiObject)
							if gui.Size.X.Scale ~= 0 or gui.Size.Y.Scale ~= 0 then return nil end
							local w = math.max(1, math.floor(gui.Size.X.Offset / SLOT + 0.5))
							local h = math.max(1, math.floor(gui.Size.Y.Offset / SLOT + 0.5))
							local cc = math.floor(gui.Position.X.Offset / SLOT + 0.5) + 1
							local rr = math.floor(gui.Position.Y.Offset / SLOT + 0.5) + 1
							return rr, cc, h, w
						end
						local function guiCoversCell(gui: GuiObject, row2:number, col2:number): boolean
							local rr, cc, hh, ww = rectOfGuiInGrid(gui)
							if not rr then return false end
							return (row2 >= rr and row2 <= rr + hh - 1 and col2 >= cc and col2 <= cc + ww - 1)
						end
						local primary: GuiObject? = nil
						local fallback: GuiObject? = nil
						local fallbackSpace = -1
						for _, ch in ipairs(hover.Frame:GetChildren()) do
							if (ch:IsA("ImageLabel") or ch:IsA("ViewportFrame")) and ch.Visible then
								if guiCoversCell(ch, row, col) then
									local k = mergeKeyOf(ch)
									if k and k == draggedKey then
										local rr, cc = (function(g:GuiObject)
											local c2 = math.floor(g.Position.X.Offset / SLOT + 0.5) + 1
											local r2 = math.floor(g.Position.Y.Offset / SLOT + 0.5) + 1
											return r2, c2
										end)(ch)
										local space = math.max(0, getStackMax(ch) - getCount(ch))
										if rr == row and cc == col then
											primary = ch; break
										end
										if space > fallbackSpace then
											fallbackSpace = space; fallback = ch
										end
									end
								end
							end
						end
						local cand = primary or fallback
						if cand then
							local draggedCount = getCount(image)
							local movedTotal = 0
							do
								local have  = getCount(cand)
								local space = math.max(0, getStackMax(cand) - have)
								if space > 0 and draggedCount > 0 then
									local move = math.min(space, draggedCount)
									setCount(cand, have + move)
									draggedCount -= move
									movedTotal += move
								end
							end
							if draggedCount > 0 then
								for _, ch in ipairs(hover.Frame:GetChildren()) do
									if draggedCount <= 0 then break end
									if ch ~= cand and (ch:IsA("ImageLabel") or ch:IsA("ViewportFrame")) and ch.Visible then
										if mergeKeyOf(ch) == draggedKey then
											local have = getCount(ch)
											local space = math.max(0, getStackMax(ch) - have)
											if space > 0 then
												local move = math.min(space, draggedCount)
												setCount(ch, have + move)
												draggedCount -= move
											end
										end
									end
								end
							end
							if movedTotal > 0 and draggedCount <= 0 then
								-- 완전 병합 -> 점유 정리 후 GUI 제거(안전)
								clearAndDestroy(image, itemData, originMap)
								setStroke(stroke, nil)
								return
							elseif movedTotal > 0 then
								-- 부분 병합 -> 수량만 감소, 원위치
								setCount(image, draggedCount)
								restoreAndRemark()
								setStroke(stroke, nil)
								return
							end
						end
					end

					-- 2) 빈칸 배치 (원자적 커밋)
					if inBounds then
						local ignoreId = (originMap and hover.Map == originMap) and occId or nil
						if hover.Map:IsAreaFree(row, col, finalW, finalH, ignoreId) then
							hover.Map:MarkArea(row, col, finalW, finalH, occId)
							-- [추가] 다른 맵으로 이동이라면 전역 Purge로 이전 점유 흔적 제거
							if originMap and (hover.Map ~= originMap) then
								local okP, fP = pcall(function()
									return (SlotMapRegistry :: any).PurgeId
								end)
								if okP and typeof(fP) == "function" then
									pcall(function() fP(occId) end)
								end
							end
							
							if originMap and original.Row and original.Col then
								originMap:ClearArea(original.Row, original.Col, original.W, original.H, occId)
							else
								purgeEverywhere(occId)
							end

							if equippedSlotRef then
								equippedSlotRef.Occupied = false
								equippedSlotRef.EquippedItem = nil
							end

							image.Parent = hover.Frame
							image.Size = UDim2.fromOffset(SLOT * finalW, SLOT * finalH)
							image.Position = UDim2.fromOffset((col - 1) * SLOT, (row - 1) * SLOT)

							itemData.IsEquipped = false
							itemData.Row, itemData.Col = row, col
							itemData.Width, itemData.Height = finalW, finalH
							itemData.Rotated = finalRot
							itemData.MapRef = hover.Map

							image.ZIndex = original.Z
							image.AnchorPoint = original.Anchor
							setStroke(stroke, nil)
							return
						end
					end
				end
			end

			-- 실패 -> 원복
			restoreAndRemark()

		end)
	end)
end

return ItemDragger
