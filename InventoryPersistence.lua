--!strict
-- 저장/불러오기 전용: 클라에서 UI 스냅샷을 만들고, 다시 적용
-- ? Count(수량) 포함 + 탄창 장착 상태(HasMag/ModsJson/MagModelName)까지 저장/복원
-- ? 적용 시 리스트를 StackService로 1차 병합(Coalesce) 후 배치

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local HttpService = game:GetService("HttpService")

local SlotMapRegistry = require(ReplicatedStorage:WaitForChild("SlotMapRegistry"))
local SlotMapManager  = require(ReplicatedStorage:WaitForChild("SlotMapManager"))
local ItemPlacer      = require(ReplicatedStorage:WaitForChild("ItemPlacer"))
local ItemDragger     = require(ReplicatedStorage:WaitForChild("ItemDragger"))
local StackService    = require(ReplicatedStorage:WaitForChild("StackService"))

-- ─────────────────────────────────────────────────────────────────────────────
-- [EFR PATCH] 선택 의존: 저장 복원 시 Viewport에 즉시 부착까지 하기 위한 헬퍼
local WeaponMods:any?, WeaponAttachSvc:any?
do
	local ok1, m1 = pcall(function() return require(ReplicatedStorage:WaitForChild("WeaponMods", 0.5)) end)
	local ok2, m2 = pcall(function() return require(ReplicatedStorage:WaitForChild("WeaponAttachService", 0.5)) end)
	if ok1 then WeaponMods = m1 end
	if ok2 then WeaponAttachSvc = m2 end
end

local function _applyModsToGui(gui: Instance, modsJson: any, hasMag: any, magModelName: any)
	-- 1) GUI Attribute로 상태 기록(저장 시스템/다른 모듈들이 참조)
	if hasMag ~= nil then
		gui:SetAttribute("HasMag", hasMag == true)
	end
	if typeof(modsJson) == "string" and #modsJson > 0 then
		gui:SetAttribute("ModsJson", modsJson)
	end
	if typeof(magModelName) == "string" and #magModelName > 0 then
		gui:SetAttribute("MagModelName", magModelName)
	end

	-- 2) (옵션) ViewportFrame 모델에 즉시 반영
	if not WeaponAttachSvc then return end

	local function applyOne(vp: ViewportFrame)
		local model: Model? = nil
		local world = vp:FindFirstChildOfClass("WorldModel")
		if world then
			model = world:FindFirstChildWhichIsA("Model", true)
		else
			model = vp:FindFirstChildWhichIsA("Model", true)
		end
		if not model then return end

		local modsTbl:any = nil
		if WeaponMods and typeof(modsJson) == "string" and #modsJson > 0 then
			local ok, t = pcall(function() return HttpService:JSONDecode(modsJson) end)
			if ok and typeof(t) == "table" then modsTbl = t end
		end
		if not modsTbl and WeaponMods then
			local ok2, t2 = pcall(function() return WeaponMods.Read(gui) end)
			if ok2 and typeof(t2) == "table" then modsTbl = t2 end
		end
		if typeof(modsTbl) == "table" then
			WeaponAttachSvc.ApplyModsToModel(model, modsTbl)
		end
	end

	if gui:IsA("ViewportFrame") then applyOne(gui) end
	for _, d in ipairs(gui:GetDescendants()) do
		if d:IsA("ViewportFrame") then
			applyOne(d)
		end
	end
end
-- ─────────────────────────────────────────────────────────────────────────────

local VER = 3
local M = {}

-- ===== 공용 유틸 =====

local function getInvGui(): Instance?
	local p = Players.LocalPlayer
	local gui = p and p:FindFirstChild("PlayerGui")
	if not gui then return nil end
	local screen = gui:FindFirstChild("ScreenGui") or gui:FindFirstChildOfClass("ScreenGui")
	if not screen then return nil end
	return screen:FindFirstChild("InventoryGui")
end

local function isItemGui(inst: Instance): boolean
	return inst and (inst:IsA("ImageLabel") or inst:IsA("ViewportFrame"))
end

-- ? GUI → Item(Count 포함 + 장착 상태) 추출
local function readItemFromGui(gui: Instance): {[string]: any}?
	if not isItemGui(gui) then return nil end
	local function g(name: string, default: any)
		local v = gui:GetAttribute(name)
		if v == nil then return default end
		return v
	end
	local id = g("Id", nil)
	local row = tonumber(g("Row", nil))
	local col = tonumber(g("Col", nil))
	local w   = tonumber(g("Width", 1))
	local h   = tonumber(g("Height",1))
	local rot = (g("Rotated", false) == true)

	local tag = g("Tag", nil)
	local tags: {any} = {}
	local tj = g("TagsJson", nil)
	if typeof(tj) == "string" and #tj > 0 then
		local ok, arr = pcall(function() return HttpService:JSONDecode(tj) end)
		if ok and typeof(arr)=="table" then tags = arr :: {any} end
	end

	local count = tonumber(g("Count", 1)) or 1 -- ★ Count

	-- [EFR PATCH] 저장할 모딩 상태
	local hasMag:any = g("HasMag", nil)
	local modsJson:any = g("ModsJson", nil)
	local magModelName:any = g("MagModelName", nil)

	return {
		Name = gui.Name,
		Id = id,
		Row = row, Col = col,
		Width = w, Height = h,
		Rotated = rot,
		Tag = tag, Tags = tags,
		Count = count,               -- ★ Count 저장
		HasMag = hasMag,             -- [EFR] 장착 여부
		ModsJson = modsJson,         -- [EFR] 장착 상세(JSON)
		MagModelName = magModelName, -- [EFR] 탄창 모델명
	}
end

local function collectGridItems(scrolling: ScrollingFrame): {[number]: any}
	local items = {}
	for _, ch in ipairs(scrolling:GetChildren()) do
		if isItemGui(ch) then
			local it = readItemFromGui(ch)
			if it then table.insert(items, it) end
		end
	end
	return items
end

-- InventoryGui/SlotPopouts/<container>/GridArea/Scroll 전체 스캔
local function findPopoutScrolls(invGui: Instance): {[string]: ScrollingFrame}
	local out: {[string]: ScrollingFrame} = {}
	local pops = invGui:FindFirstChild("SlotPopouts")
	if not pops then return out end
	for _, pop in ipairs(pops:GetChildren()) do
		if pop:IsA("Frame") then
			local tag = pop:GetAttribute("ContainerTag")
			local area = pop:FindFirstChild("GridArea")
			local sc = area and area:FindFirstChild("Scroll")
			if typeof(tag)=="string" and sc and sc:IsA("ScrollingFrame") then
				out[string.lower(tag)] = sc
			end
		end
	end
	return out
end

-- 슬롯칸 UI는 보존하고, 아이템 GUI만 제거
local function clearItemsOnly(inst: Instance)
	for _, ch in ipairs(inst:GetChildren()) do
		if ch:IsA("ImageLabel") or ch:IsA("ViewportFrame") then
			ch:Destroy()
		end
	end
end

-- Scroll에 Rows/Cols Attribute 읽기
local function sizeFromScroll(sc: ScrollingFrame?, fallbackRows: number, fallbackCols: number)
	if sc then
		local r = tonumber(sc:GetAttribute("Rows"))
		local c = tonumber(sc:GetAttribute("Cols"))
		if r and c then return math.max(1,r), math.max(1,c) end
	end
	return fallbackRows, fallbackCols
end

-- baseFrame 이 nil이어도 맵만 먼저 생성
local function getOrCreateMap(name: string, baseFrame: Instance?, rows: number, cols: number)
	local map = SlotMapRegistry.Get(name)
	if not map then
		map = SlotMapManager.new(rows, cols)
		SlotMapRegistry.Set(name, map)
		-- UI 슬롯 프레임 바인딩
		if baseFrame then
			for r = 1, rows do
				for c = 1, cols do
					local cellName = string.format("%d_%d", r, c)
					local cell = baseFrame:FindFirstChild(cellName, true)
					if cell and cell:IsA("Frame") then
						map:RegisterSlotFrame(r, c, cell)
					end
				end
			end
		end
	end
	return map
end

-- 경계 밖 좌표는 자동 재배치(=Row/Col 제거)
local function sanitizeForScrollBounds(item: {[string]: any}, sc: ScrollingFrame?)
	if not sc then return end
	local rows, cols = sizeFromScroll(sc, 99, 99)
	if item.Row and item.Col and item.Width and item.Height then
		local r2 = item.Row + item.Height - 1
		local c2 = item.Col + item.Width  - 1
		if item.Row < 1 or item.Col < 1 or r2 > rows or c2 > cols then
			item.Row, item.Col = nil, nil
		end
	end
end

-- ? 리스트를 StackService 규칙으로 병합해 깔끔히 만든 뒤 순차 배치
local function placeListInto(sc: ScrollingFrame, map:any, list:{any})
	StackService.EnsureCoalesced(list)
	local equipMap = SlotMapRegistry.Get("Equipment")
	if type(map) == "table" and typeof(map.Clear) == "function" then
		pcall(function() map:Clear() end)
	end
	for _, it in ipairs(list) do
		sanitizeForScrollBounds(it, sc)
		local image = ItemPlacer.PlaceSavedItem(it, map, sc)
		if image then
			local baseZ = tonumber(sc:GetAttribute("ItemBaseZ")) or 60
			image.ZIndex = baseZ
			image:SetAttribute("BaseZ", baseZ)
			if image:IsA("GuiObject") then image.Active = true end
			ItemDragger.EnableDrag(image, it, sc, map, equipMap)

			-- [EFR PATCH] 그리드 아이템에도 장착 상태 즉시 반영(+Viewport 적용)
			_applyModsToGui(image, it.ModsJson, it.HasMag, it.MagModelName)
		end
	end
end

local function findEquipSlot(slotName: string)
	local equip:any = SlotMapRegistry.Get("Equipment")
	return equip and equip[slotName] or nil
end

local function waitPopoutScroll(invGui: Instance, tagLower: string, timeout: number?): ScrollingFrame?
	local t0 = os.clock()
	timeout = timeout or 5
	while os.clock() - t0 < timeout do
		local pops = findPopoutScrolls(invGui)
		if pops[tagLower] then return pops[tagLower] end
		task.wait(0.05)
	end
	return nil
end

-- ===== Snapshot 만들기 =====

function M.BuildSnapshot(): {[string]: any}?
	local inv = getInvGui()
	if not inv then return nil end

	local stash = inv:FindFirstChild("ScrollingInventory") :: ScrollingFrame?
	local equipIngame = inv:FindFirstChild("Equipmentingame") :: Frame?
	local pocketFrame = equipIngame and equipIngame:FindFirstChild("poket") :: ScrollingFrame?

	-- 1) 장비(착용)
	local equipped: {[string]: any} = {}
	local equipMap:any = SlotMapRegistry.Get("Equipment")
	if equipMap then
		for slotName, data in pairs(equipMap) do
			local f = data and data.Frame
			if f then
				local itemGui = data.EquippedItem
					or f:FindFirstChildWhichIsA("ImageLabel")
					or f:FindFirstChildWhichIsA("ViewportFrame")
				if itemGui then
					local it = readItemFromGui(itemGui)
					if it then
						-- [EFR PATCH] 장착 상태까지 저장
						equipped[slotName] = {
							Name = it.Name, Tag = it.Tag, Id = it.Id,
							HasMag = it.HasMag, ModsJson = it.ModsJson, MagModelName = it.MagModelName,
						}
					end
				end
			end
		end
	end

	-- 2) 슬롯맵(스태시/포켓/모든 팝아웃)
	local grids = {
		Stash = { items = {} :: {any} },
		Pocket = { items = {} :: {any} },
		Containers = {} :: {[string]: {items:{any}}},
	}

	if stash and stash:IsA("ScrollingFrame") then
		grids.Stash.items = collectGridItems(stash)
	end
	if pocketFrame and pocketFrame:IsA("ScrollingFrame") then
		grids.Pocket.items = collectGridItems(pocketFrame)
	end
	for tagLower, sc in pairs(findPopoutScrolls(inv)) do
		grids.Containers[tagLower] = { items = collectGridItems(sc) }
	end

	return {
		ver = VER,
		t = os.time(),
		equipped = equipped,
		grids = grids,
	}
end

-- ===== Snapshot 적용 =====

function M.ApplySnapshot(snapshot: {[string]: any}?)
	if not snapshot or type(snapshot)~="table" then return end

	local inv = getInvGui()
	if not inv then return end

	-- 적용 중 플래그
	inv:SetAttribute("ApplyingSnapshot", true)

	-- 현재 GUI 레퍼런스 확보
	local stashScroll = inv:FindFirstChild("ScrollingInventory") :: ScrollingFrame?
	local equipIngame = inv:FindFirstChild("Equipmentingame") :: Frame?
	local pocketFrame = equipIngame and equipIngame:FindFirstChild("poket") :: ScrollingFrame?

	-- 스태시 맵(30x10) 보장 + Rows/Cols Attribute 동기화
	local stashMap = getOrCreateMap("Stash", stashScroll, 30, 10)
	if stashScroll then
		stashScroll:SetAttribute("Rows", 30)
		stashScroll:SetAttribute("Cols", 10)
	end -- <<< 여기! 잘못된 '}'를 'end'로 수정되어 있음

	-- 1) 장비 먼저 장착(팝아웃 생성 유도)
	local equipMap:any = SlotMapRegistry.Get("Equipment")
	if snapshot.equipped and equipMap then
		for slotName, data in pairs(snapshot.equipped) do
			if type(data)=="table" and data.Name then
				local slot = findEquipSlot(slotName)
				if slot and slot.Frame and not slot.EquippedItem then
					local gui, meta = ItemPlacer.CreateGuiFor(data.Name)
					if gui then
						local w = (meta and meta.Width) or 1
						local h = (meta and meta.Height) or 1
						local baseZ = tonumber(slot.Frame:GetAttribute("ItemBaseZ")) or 60

						gui.Parent = slot.Frame
						gui.Position = UDim2.fromOffset(0,0)
						gui.Size = UDim2.fromScale(1,1)
						gui.ZIndex = baseZ
						gui:SetAttribute("BaseZ", baseZ)
						if gui:IsA("GuiObject") then gui.Active = true end

						gui:SetAttribute("Id", data.Id or HttpService:GenerateGUID(false))
						gui:SetAttribute("Tag", meta and meta.Tag or data.Tag or "misc")
						gui:SetAttribute("TagsJson", HttpService:JSONEncode(meta and meta.Tags or { meta and meta.Tag or data.Tag or "misc" }))
						gui:SetAttribute("Rotated", false)
						gui:SetAttribute("Width", w)
						gui:SetAttribute("Height", h)
						gui:SetAttribute("Count", 1) -- 장비는 단일 품목 취급

						-- [EFR PATCH] 장비에도 장착 상태 즉시 반영(+Viewport 적용)
						_applyModsToGui(gui, (data and data.ModsJson), (data and data.HasMag), (data and data.MagModelName))

						slot.Occupied     = true
						slot.EquippedItem = gui

						ItemDragger.EnableDrag(gui, {
							Name = data.Name, Id = gui:GetAttribute("Id"),
							Width = w, Height = h, Rotated = false, Tag = gui:GetAttribute("Tag"), Count = 1
						}, slot.Frame, nil, equipMap)
					end
				end
			end
		end
	end

	-- 2) 스태시
	if stashScroll and snapshot.grids and snapshot.grids.Stash then
		local list = snapshot.grids.Stash.items or {}
		if #list > 0 then
			clearItemsOnly(stashScroll)
			local map = getOrCreateMap("Stash", stashScroll, 30, 10)
			placeListInto(stashScroll, map, list)
		end
	end

	-- 3) 포켓
	if pocketFrame and pocketFrame:IsA("ScrollingFrame") and snapshot.grids and snapshot.grids.Pocket then
		local list = snapshot.grids.Pocket.items or {}
		if #list > 0 then
			clearItemsOnly(pocketFrame)
			pocketFrame:SetAttribute("Rows", tonumber(pocketFrame:GetAttribute("Rows")) or 1)
			pocketFrame:SetAttribute("Cols", tonumber(pocketFrame:GetAttribute("Cols")) or 4)
			local pr, pc = sizeFromScroll(pocketFrame, 1, 4)
			local map = getOrCreateMap("Pocket", pocketFrame, pr, pc)
			placeListInto(pocketFrame, map, list)
		end
	end

	-- 4) 모든 팝아웃 컨테이너
	if snapshot.grids and snapshot.grids.Containers then
		for tagLower, container in pairs(snapshot.grids.Containers) do
			local list = (container and container.items) or {}
			if #list > 0 then
				local sc = waitPopoutScroll(inv, tagLower, 5)
				if sc then
					clearItemsOnly(sc)
					local rr, cc = sizeFromScroll(sc, 6, 6)
					local map = getOrCreateMap(tagLower, sc, rr, cc)
					placeListInto(sc, map, list)
				else
					warn("[InventoryPersistence] 팝아웃 Scroll 미탐지:", tagLower)
				end
			end
		end
	end

	inv:SetAttribute("ApplyingSnapshot", false)
end

return M
