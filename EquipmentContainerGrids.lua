--!strict
-- StarterPlayerScripts/EquipmentContainerGrids.lua
-- 컨테이너(vest/backpack/securecontainer) 팝아웃 그리드 생성/갱신
-- ? SlotMapRegistry 가 만든 슬롯맵과 1:1로 동일하게 연결(GridKey 표준 사용)
-- ? 행/열 보정 없음: UI 셀 (c-1, r-1) == 맵 (row=r, col=c)
-- ? UID(장착 아이템 고유ID) 기반으로 GridKey를 만들어 장비별 맵이 섞이지 않음

-- ========= 설정 =========
local CELL_SIZE   = 40
local SLOT_PAD    = 8
local SCROLL_W    = 8

-- ?? 메타/로컬 속성이 비어도 가방/조끼는 기본 크기로 생성
local FALLBACK_DIM_BY_TAG = {
	backpack        = { cols = 6, rows = 8 }, -- 6SH118 등
	vest            = { cols = 6, rows = 3 }, -- StrandHogg 등
	-- securecontainer는 서버 메타가 확실히 있으므로 생략(	 그냥 표시 안함)
}

-- tag key는 공백/밑줄/대시 제거 + 소문자
local function keyify(s: string?): string
	if typeof(s) ~= "string" then return "" end
	s = s:lower()
	s = s:gsub("[%s_%-]+", "") -- 공백/밑줄/대시 제거
	return s
end

-- 컨테이너로 인정하는 '정규 키'
local CONTAINER_KEYS = {
	vest = true,
	backpack = true,
	securecontainer = true,
}

-- ========= Services =========
local Players           = game:GetService("Players")
local RunService        = game:GetService("RunService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local HttpService       = game:GetService("HttpService")

local player       = Players.LocalPlayer
local guiRoot      = player:WaitForChild("PlayerGui"):WaitForChild("ScreenGui")
local inventoryGui = guiRoot:WaitForChild("InventoryGui")
local equipFrame   = inventoryGui:WaitForChild("EquipmentFrame")
local equipIngame  = inventoryGui:WaitForChild("Equipmentingame")

-- 의존성 (pcall 안전)
local SlotMapRegistry:any = nil
pcall(function() SlotMapRegistry = require(ReplicatedStorage:WaitForChild("SlotMapRegistry")) end)

local GetStashData : RemoteFunction? = nil
pcall(function() GetStashData = ReplicatedStorage:WaitForChild("GetStashData") :: RemoteFunction end)

-- ========= 유틸 =========
local function toLocal(container: GuiObject, abs: Vector2): Vector2
	return abs - container.AbsolutePosition
end

local function clampTo(container: GuiObject, pos: Vector2, size: Vector2): Vector2
	local maxX = container.AbsoluteSize.X - size.X
	local maxY = container.AbsoluteSize.Y - size.Y
	return Vector2.new(
		math.clamp(pos.X, 0, math.max(0, maxX)),
		math.clamp(pos.Y, 0, math.max(0, maxY))
	)
end

local function readFirstAttr(inst: Instance, keys: {string}): number?
	for _,k in ipairs(keys) do
		local v = inst:GetAttribute(k)
		if typeof(v) == "number" and v > 0 then return v end
	end
	return nil
end

-- 컨테이너 속성 키(로컬 Attribute만 인정)
local COL_KEYS = { "ContainerCols", "CapacityCols" }
local ROW_KEYS = { "ContainerRows", "CapacityRows" }

-- 컨테이너 속성 읽기: Slot/자식 GUI에서 ContainerRows/ContainerCols만
local function findCapacityFromLocal(slot: Frame): (number?, number?, boolean)
	local function scan(inst: Instance): (number?, number?, boolean)
		if inst:GetAttribute("IsContainer") == true then
			local c = readFirstAttr(inst, COL_KEYS)
			local r = readFirstAttr(inst, ROW_KEYS)
			if c and r then return c, r, true end
		end
		return nil, nil, false
	end

	-- 1) 슬롯 자체
	local c, r, ok = scan(slot)
	if ok then return c, r, true end

	-- 2) 자식 GUI(아이템)
	for _,ch in ipairs(slot:GetChildren()) do
		if ch:IsA("GuiObject") then
			c, r, ok = scan(ch)
			if ok then return c, r, true end
		end
	end
	return nil, nil, false
end

-- 서버 메타에서 컨테이너 사이즈 획득(보강)
local function findCapacityFromServerByGui(g: GuiObject): (number?, number?, boolean)
	if not GetStashData then return nil, nil, false end

	local function guessName(inst: Instance): string?
		local n = inst:GetAttribute("ItemName")
		if typeof(n) == "string" and #n > 0 then return n end
		if inst.Name and #inst.Name > 0 then return inst.Name end
		return nil
	end

	local name: string? = guessName(g)
	local p = g.Parent
	while (not name) and p and p ~= inventoryGui do
		name = guessName(p); p = p.Parent
	end
	if not name then return nil, nil, false end

	local ok, data = pcall(function() return GetStashData:InvokeServer(name) end)
	if not ok or type(data) ~= "table" then return nil, nil, false end
	if data.IsContainer ~= true then return nil, nil, false end

	local cc = tonumber(data.ContainerCols)
	local rr = tonumber(data.ContainerRows)
	if cc and rr then return cc, rr, true end
	return nil, nil, false
end

-- 장착된 GUI에서 UID(Id) 추출
local function getEquippedUID(slot: Frame): string?
	local g = slot:FindFirstChildWhichIsA("ImageLabel") or slot:FindFirstChildWhichIsA("ViewportFrame")
	if not g then return nil end
	local id = g:GetAttribute("ItemUID") or g:GetAttribute("UID") or g:GetAttribute("Id")
	if typeof(id) == "string" and #id > 0 then return id end
	return nil
end

-- GridKey(표준): SlotMapRegistry.MakeGridKey 가 있으면 그걸 쓰고, 없으면 폴백
local function makeGridKey(tagKey:string, uid:string): string
	if SlotMapRegistry and typeof(SlotMapRegistry.MakeGridKey)=="function" then
		return SlotMapRegistry.MakeGridKey(tagKey, uid)
	end
	-- 폴백: grid:<tag>:<uid>
	return ("grid:%s:%s"):format(tagKey, uid)
end

-- ========= 팝아웃 =========
local function ensurePopoutsFolder(): Folder
	local host = inventoryGui:FindFirstChild("SlotPopouts")
	if not host then
		host = Instance.new("Folder")
		host.Name = "SlotPopouts"
		host.Archivable = false
		host.Parent = inventoryGui
	end
	return host
end

local function ensurePopoutForSlot(tagKey: string): Frame
	local host = ensurePopoutsFolder()
	local key  = ("Popout_%s"):format(tagKey) -- 컨테이너 종류별 1개(동시 2개 착용 가정X)
	local pop  = host:FindFirstChild(key)
	if pop and pop:IsA("Frame") then return pop end

	pop = Instance.new("Frame")
	pop.Name = key
	pop.BackgroundTransparency = 0.1
	pop.BackgroundColor3 = Color3.fromRGB(40,40,40)
	pop.BorderSizePixel = 0
	pop.Visible = false
	pop.ZIndex = 50
	pop:SetAttribute("ContainerTag", tagKey)

	local title = Instance.new("TextLabel")
	title.Name = "Title"
	title.BackgroundTransparency = 1
	title.Size = UDim2.new(1,-12,0,22)
	title.Position = UDim2.new(0,6,0,6)
	title.Font = Enum.Font.GothamBold
	title.TextSize = 16
	title.TextXAlignment = Enum.TextXAlignment.Left
	title.TextColor3 = Color3.fromRGB(220,220,220)
	title.Text = (tagKey=="securecontainer" and "Secure Container")
		or (tagKey:sub(1,1):upper()..tagKey:sub(2))
	title.Parent = pop

	local area = Instance.new("Frame")
	area.Name = "GridArea"
	area.BackgroundTransparency = 1
	area.Position = UDim2.new(0,6,0,30)
	area.Size = UDim2.new(1,-12,1,-36)
	area.ClipsDescendants = true
	area.Parent = pop

	local sc = Instance.new("ScrollingFrame")
	sc.Name = "Scroll"
	sc.BackgroundTransparency = 1
	sc.ScrollBarThickness = SCROLL_W
	sc.Size = UDim2.fromScale(1,1)
	sc.ClipsDescendants = true
	sc.ScrollingEnabled = true
	sc.CanvasPosition = Vector2.new(0,0)
	if sc:GetAttribute("ItemBaseZ") == nil then sc:SetAttribute("ItemBaseZ", 60) end
	sc.Parent = area

	pop.Parent = host
	return pop
end

-- 좌표계 보정: 슬롯 옆으로
local function updatePopoutPlacement(slot: GuiObject, pop: GuiObject, rows: number, cols: number)
	local w = math.max(220, cols * CELL_SIZE + 12)
	local h = 30 + rows * CELL_SIZE + 6
	pop.Size = UDim2.fromOffset(w, h)

	local sAbs  = slot.AbsolutePosition
	local sSize = slot.AbsoluteSize
	local raw   = Vector2.new(sAbs.X + sSize.X + SLOT_PAD, sAbs.Y)
	local cl    = clampTo(inventoryGui, toLocal(inventoryGui, raw), Vector2.new(w, h))
	pop.Position = UDim2.fromOffset(cl.X, cl.Y)
end

-- 셀만 지우기(아이템 GUI 보존)
local function clearOnlyCells(sc: ScrollingFrame)
	for _,ch in ipairs(sc:GetChildren()) do
		if ch:IsA("Frame") and string.sub(ch.Name, 1, 5) == "Cell_" then
			ch:Destroy()
		end
	end
end

local function buildPopoutGrid(slot: Frame, tagKey: string, rows: number, cols: number)
	local pop  = ensurePopoutForSlot(tagKey)
	local area = pop:FindFirstChild("GridArea") :: Frame
	local sc   = area and area:FindFirstChild("Scroll") :: ScrollingFrame
	if not sc then return end

	-- UID 기준 GridKey(없으면 숨김)
	local uid = getEquippedUID(slot)
	if not uid then
		pop.Visible = false
		pop:SetAttribute("HasContent", false)
		return
	end
	local gridKey = makeGridKey(tagKey, uid)

	-- ? SlotMapRegistry로 "그" 맵을 보장 생성(단일 출처)
	local map:any = nil
	if SlotMapRegistry and typeof(SlotMapRegistry.Ensure)=="function" then
		map = SlotMapRegistry.Ensure(gridKey, rows, cols)
	else
		-- 정말 구형 환경용: 동일 키로 재호출하면 같은 map을 돌려줘야 함
		SlotMapRegistry = SlotMapRegistry or {}
		SlotMapRegistry._maps = SlotMapRegistry._maps or {}
		map = SlotMapRegistry._maps[gridKey]
		if not map then
			local SlotMapManager = require(ReplicatedStorage:WaitForChild("SlotMapManager"))
			map = SlotMapManager.new(rows, cols)
			SlotMapRegistry._maps[gridKey] = map
		end
		map.rows, map.cols = rows, cols
	end

	-- Canvas/속성 동기화 (보이는 줄=맵 줄 1:1)
	sc.CanvasPosition = Vector2.new(0,0)
	sc.CanvasSize = UDim2.new(0, map.cols * CELL_SIZE, 0, map.rows * CELL_SIZE)
	sc:SetAttribute("Rows", map.rows)
	sc:SetAttribute("Cols", map.cols)
	sc:SetAttribute("GridKey", gridKey)
	clearOnlyCells(sc)

	-- 셀(시각화) 생성: (col-1, row-1)
	for r = 1, map.rows do
		for c = 1, map.cols do
			local cell = Instance.new("Frame")
			cell.Name  = string.format("Cell_%d_%d", r, c)
			cell.Size  = UDim2.fromOffset(CELL_SIZE, CELL_SIZE)
			cell.Position = UDim2.fromOffset((c - 1) * CELL_SIZE, (r - 1) * CELL_SIZE)
			cell.BackgroundColor3 = Color3.fromRGB(60,60,60)
			cell.BackgroundTransparency = 0.2
			cell.BorderSizePixel = 1
			cell.BorderColor3 = Color3.fromRGB(90,90,90)
			cell.ZIndex = (tonumber(sc:GetAttribute("ItemBaseZ")) or 60) - 1
			cell.Active = false
			cell.Parent = sc
		end
	end

	pop:SetAttribute("HasContent", true)
	updatePopoutPlacement(slot, pop, map.rows, map.cols)
	pop.Visible = equipIngame.Visible

	-- 위치 추적
	local conn; conn = RunService.RenderStepped:Connect(function()
		if not slot:IsDescendantOf(inventoryGui) then conn:Disconnect(); return end
		updatePopoutPlacement(slot, pop, map.rows, map.cols)
	end)
end

-- ========= 감시 =========
local function attachWatch(slotFrame: Frame, tagKey: string)
	local function rebuild()
		-- 1) 로컬 Attribute 우선
		local cols, rows, okLocal = findCapacityFromLocal(slotFrame)

		-- 2) 실패 시 서버 메타(장착 GUI 기준) 보강
		if not okLocal or not cols or not rows then
			for _, ch in ipairs(slotFrame:GetChildren()) do
				if ch:IsA("GuiObject") then
					local sc, sr, ok = findCapacityFromServerByGui(ch)
					if ok and sc and sr then
						cols, rows = sc, sr
						okLocal = true
						break
					end
				end
			end
		end

		-- 3) 그래도 못 찾으면 태그 기반 기본 크기 사용 (백팩/조끼 강제 생성)
		if not okLocal or not cols or not rows then
			local fb = FALLBACK_DIM_BY_TAG[tagKey]
			if fb then
				cols, rows = fb.cols, fb.rows
				okLocal = true
			end
		end

		if not okLocal or not cols or not rows then
			-- 컨테이너 아님 → 팝아웃 숨김
			local host = inventoryGui:FindFirstChild("SlotPopouts")
			if host then
				local pop = host:FindFirstChild(("Popout_%s"):format(tagKey))
				if pop and pop:IsA("Frame") then pop.Visible = false end
			end
			return
		end

		buildPopoutGrid(slotFrame, tagKey, rows, cols)
	end

	slotFrame.ChildAdded:Connect(rebuild)
	slotFrame.ChildRemoved:Connect(rebuild)
	for _,k in ipairs(COL_KEYS) do slotFrame:GetAttributeChangedSignal(k):Connect(rebuild) end
	for _,k in ipairs(ROW_KEYS) do slotFrame:GetAttributeChangedSignal(k):Connect(rebuild) end
	slotFrame:GetAttributeChangedSignal("IsContainer"):Connect(rebuild)

	task.defer(rebuild)
end

local function hookSlotsUnder(root: Instance)
	for _, d in ipairs(root:GetDescendants()) do
		if d:IsA("Frame") and d.Name == "Slot" then
			local parent = d.Parent
			-- 우선순위: Slot.Attribute.Tag → 부모 이름
			local tg = (d:GetAttribute("tag") or d:GetAttribute("Tag")) or (parent and parent.Name) or ""
			local tagKey = keyify(tg)
			if CONTAINER_KEYS[tagKey] then
				attachWatch(d, tagKey)
			end
		end
	end
	root.DescendantAdded:Connect(function(inst)
		if inst:IsA("Frame") and inst.Name == "Slot" then
			local parent = inst.Parent
			local tg = (inst:GetAttribute("tag") or inst:GetAttribute("Tag")) or (parent and parent.Name) or ""
			local tagKey = keyify(tg)
			if CONTAINER_KEYS[tagKey] then
				attachWatch(inst, tagKey)
			end
		end
	end)
end

-- ========= 초기화 =========
hookSlotsUnder(equipFrame)
hookSlotsUnder(equipIngame)

-- 인게임 장비창 보일 때만 팝아웃 보이게
equipIngame:GetPropertyChangedSignal("Visible"):Connect(function()
	local host = inventoryGui:FindFirstChild("SlotPopouts")
	if not host then return end
	for _, ch in ipairs(host:GetChildren()) do
		if ch:IsA("GuiObject") then ch.Visible = equipIngame.Visible and (ch:GetAttribute("HasContent") ~= false) end
	end
end)

-- (선택) 스태시/포켓에도 GridKey 명시해두면 더 명확
do
	local stash = inventoryGui:FindFirstChild("ScrollingInventory")
	if stash and stash:IsA("ScrollingFrame") and not stash:GetAttribute("GridKey") then
		local key = (SlotMapRegistry and SlotMapRegistry.MakeGridKey and SlotMapRegistry.MakeGridKey("stash")) or "grid:stash"
		stash:SetAttribute("GridKey", key)
		if SlotMapRegistry and SlotMapRegistry.Get then
			local m = SlotMapRegistry.Get(key) or (SlotMapRegistry.Ensure and SlotMapRegistry.Ensure(key, 10, 30))
			if m then stash:SetAttribute("Rows", m.rows); stash:SetAttribute("Cols", m.cols) end
		else
			stash:SetAttribute("Rows", 10); stash:SetAttribute("Cols", 30)
		end
	end
	local pok = equipIngame:FindFirstChild("poket")
	if pok and pok:IsA("ScrollingFrame") and not pok:GetAttribute("GridKey") then
		local key = (SlotMapRegistry and SlotMapRegistry.MakeGridKey and SlotMapRegistry.MakeGridKey("pocket")) or "grid:pocket"
		pok:SetAttribute("GridKey", key)
		if SlotMapRegistry and SlotMapRegistry.Get then
			local m = SlotMapRegistry.Get(key) or (SlotMapRegistry.Ensure and SlotMapRegistry.Ensure(key, 4, 1))
			if m then pok:SetAttribute("Rows", m.rows); pok:SetAttribute("Cols", m.cols) end
		else
			pok:SetAttribute("Rows", 4); pok:SetAttribute("Cols", 1)
		end
	end
end
