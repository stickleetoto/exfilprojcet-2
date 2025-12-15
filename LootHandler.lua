--!strict
-- ReplicatedStorage/LootHandler.lua
-- 요구사항:
--  - 줍기(CollectItem): 조끼/가방 컨테이너에 빈칸이 있어야만 자동 수납. 없으면 안 줍는다(월드 유지).
--  - 요청(RequestItemByName): 항상 스태시에 배치.
--  - 외부에서 slotMap/scroll 파라미터가 와도 무시하고, 내부에서 컨테이너/스태시를 직접 탐색한다.

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local CollectionService = game:GetService("CollectionService")
local Players           = game:GetService("Players")

local SlotMapRegistry = require(ReplicatedStorage:WaitForChild("SlotMapRegistry"))
local ItemPlacer      = require(ReplicatedStorage:WaitForChild("ItemPlacer"))
local ItemDragger     = require(ReplicatedStorage:WaitForChild("ItemDragger"))

local GetStashData = ReplicatedStorage:WaitForChild("GetStashData") :: RemoteFunction
local LootRemove   = ReplicatedStorage:FindFirstChild("LootRemove") :: RemoteEvent?

local LootHandler = {}

----------------------------------------------------------------
-- 키/별칭 인덱스 (간소)
----------------------------------------------------------------
local TagToItemLower : {[string]: string} = {}
local function _norm(s: string?) : string?
	if typeof(s) ~= "string" then return nil end
	local lower = string.lower(s)
	return lower:gsub("%s+", " ")
end
local function _addAliases(src: {string})
	for _, key in ipairs(src) do
		local k = _norm(key)
		if k then
			TagToItemLower[k] = key
			TagToItemLower[k:gsub("_"," ")] = key
			TagToItemLower[k:gsub("-"," ")] = key
		end
	end
end
_addAliases({
	"m4a1","mcx","g17","mp5sd","mp7a1","ak74","ak74m","ak12","fnfal","svdm","l96a1","m82a1","m203_ar",
	"purina","burnis","dollar","doro","case","jjkbock","MRE","Hip Flask",
	"fasthelmet","MILITARY_BACKPACK","firstspear strandhogg pc mcam",
})
TagToItemLower["fasth elmet"] = "FASThelmet"
TagToItemLower["firstspear strandhogg pc mcam"] = "FirstSpear StrandHogg PC MCam"

-- 인스턴스(주로 Model)에서 태그/이름으로 아이템 이름 해석
local function resolveItemNameFromWorldInstance(inst: Instance): string?
	if not inst then return nil end
	for _, t in ipairs(CollectionService:GetTags(inst)) do
		local nm = TagToItemLower[_norm(t) or ""]; if nm then return nm end
	end
	local hostModel = inst:FindFirstAncestorOfClass("Model")
	if hostModel then
		for _, t in ipairs(CollectionService:GetTags(hostModel)) do
			local nm = TagToItemLower[_norm(t) or ""]; if nm then return nm end
		end
		local byName = TagToItemLower[_norm(hostModel.Name or "")]; if byName then return byName end
	end
	return TagToItemLower[_norm(inst.Name or "") or ""]
end
LootHandler.ResolveItemNameFromInstance = resolveItemNameFromWorldInstance

function LootHandler.HasLootTag(inst: Instance?): boolean
	if not inst then return false end
	if resolveItemNameFromWorldInstance(inst) then return true end
	local m = inst:FindFirstAncestorOfClass("Model")
	if m and resolveItemNameFromWorldInstance(m) then return true end
	return false
end

function LootHandler.IsLootableModel(model: Instance?): boolean
	if not model then return false end
	if LootHandler.HasLootTag(model) then return true end
	for _, ch in ipairs(model:GetChildren()) do
		if LootHandler.HasLootTag(ch) then return true end
	end
	return false
end

----------------------------------------------------------------
-- 인벤토리/컨테이너 탐색
----------------------------------------------------------------
local function getInventoryGui()
	local player = Players.LocalPlayer
	if not player then return nil end
	local pg = player:FindFirstChildOfClass("PlayerGui"); if not pg then return nil end
	local sg = pg:FindFirstChild("ScreenGui"); if not sg then return nil end
	local inv = sg:FindFirstChild("InventoryGui"); if not inv then return nil end
	return inv
end

-- "vest/backpack"만 자동수납, "case/secure"는 제외
local function canonicalContainer(tagKey: string?): string?
	local s = string.lower(tagKey or "")
	if s:find("vest") or s:find("rig") then return "vest" end
	if s:find("backpack") or s:find("bag") then return "backpack" end
	if s:find("case") or s:find("secure") then return "case" end
	return nil
end

type ContainerTarget = { Map:any, Scroll:ScrollingFrame, Kind:string }

local function collectVestBackpackTargets(): {ContainerTarget}
	local inv = getInventoryGui(); if not inv then return {} end
	local host = inv:FindFirstChild("SlotPopouts"); if not host then return {} end

	local out: {ContainerTarget} = {}
	for _, pop in ipairs(host:GetChildren()) do
		if pop:IsA("Frame") then
			local kind  = canonicalContainer((pop:GetAttribute("ContainerTag") or "") :: string)
			if kind == "vest" or kind == "backpack" then
				local area = pop:FindFirstChild("GridArea") :: Frame?
				local sc   = area and area:FindFirstChild("Scroll") :: ScrollingFrame?
				if sc then
					local gridKey = sc:GetAttribute("GridKey")
					if typeof(gridKey)=="string" and #gridKey>0 then
						local map = SlotMapRegistry.Get and SlotMapRegistry.Get(gridKey) or nil
						if map then table.insert(out, { Map = map, Scroll = sc, Kind = kind }) end
					end
				end
			end
		end
	end
	-- 간단 정렬: vest → backpack
	table.sort(out, function(a,b)
		if a.Kind ~= b.Kind then return a.Kind=="vest" end
		return a.Scroll.AbsolutePosition.X < b.Scroll.AbsolutePosition.X
	end)
	return out
end

----------------------------------------------------------------
-- 줍기: 조끼/가방에 빈칸 있을 때만 성공 (없으면 주지 않음)
----------------------------------------------------------------
function LootHandler.CollectItem(target: Instance, _slotMapManagerIgnored, _scrollingFrameIgnored, onComplete)
	if not target then if onComplete then onComplete() end; return end

	local host = target:IsA("Model") and target or target:FindFirstAncestorWhichIsA("Model") or target
	local itemName = resolveItemNameFromWorldInstance(host)
	if not itemName then if onComplete then onComplete() end; return end

	local meta = GetStashData:InvokeServer(itemName)
	if not meta then
		warn("[LootHandler] 서버 메타 실패:", itemName)
		if onComplete then onComplete() end; return
	end

	local itemData = {
		Name       = meta.Name,
		Tag        = meta.Tag,
		Tags       = meta.Tags,
		BaseWidth  = meta.Width,
		BaseHeight = meta.Height,
	}

	-- 조끼/가방 후보 스캔
	local targets = collectVestBackpackTargets()
	if #targets == 0 then
		-- 장비 팝아웃이 없거나(닫힘) 컨테이너가 없음 → 안 줍는다
		if onComplete then onComplete() end
		return
	end

	-- 순서대로 배치 시도
	local image: Instance? = nil
	local usedMap:any, usedScroll:ScrollingFrame? = nil, nil
	for _, t in ipairs(targets) do
		image = ItemPlacer.PlaceSavedItem(itemData, t.Map, t.Scroll)
		if image then usedMap, usedScroll = t.Map, t.Scroll; break end
	end

	if not image then
		-- 조끼/가방 모두 빈칸 없음 → 안 줍는다(월드 유지)
		if onComplete then onComplete() end
		return
	end

	-- 드래그 활성화(기본 맵 = 해당 컨테이너 맵)
	local equipMap = SlotMapRegistry.Get and SlotMapRegistry.Get("Equipment") or nil
	ItemDragger.EnableDrag(image :: any, itemData, usedScroll :: any, usedMap, equipMap)

	-- 월드에서 제거
	if LootRemove then LootRemove:FireServer(host) end
	if host.Destroy then host:Destroy() end
	if onComplete then onComplete() end
end

----------------------------------------------------------------
-- 요청 생성: 항상 스태시에 배치
----------------------------------------------------------------
function LootHandler.RequestItemByName(itemName: string, _ignoredMap, _ignoredScroll)
	if not itemName then return nil end

	local inv = getInventoryGui()
	if not inv then warn("[RequestItemByName] 인벤토리 GUI 없음"); return nil end

	local stashScroll = inv:FindFirstChild("ScrollingInventory") :: ScrollingFrame?
	local stashMap    = SlotMapRegistry.Get and SlotMapRegistry.Get("Stash") or nil
	if not stashScroll or not stashMap then
		warn("[RequestItemByName] 스태시 UI/맵을 찾을 수 없음")
		return nil
	end

	local meta = GetStashData:InvokeServer(itemName)
	if not meta then
		warn("[RequestItemByName] 서버 메타 실패:", itemName); return nil
	end

	local itemData = {
		Name       = meta.Name,
		Tag        = meta.Tag,
		Tags       = meta.Tags,
		BaseWidth  = meta.Width,
		BaseHeight = meta.Height,
	}

	local image = ItemPlacer.PlaceSavedItem(itemData, stashMap, stashScroll)
	if not image then
		warn("[RequestItemByName] 스태시 빈칸 없음/충돌:", meta.Name); return nil
	end

	local equipMap = SlotMapRegistry.Get and SlotMapRegistry.Get("Equipment") or nil
	ItemDragger.EnableDrag(image, itemData, stashScroll, stashMap, equipMap)

	return image
end

return LootHandler
