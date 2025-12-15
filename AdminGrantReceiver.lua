--!strict
-- ?? AdminGrantReceiver.client.lua
-- 서버의 AdminGrantDeliver를 받아 스태시에 생성/병합/분할
-- 수정 요약:
--  - 스택형(탄/소모품 등)만 Count로 병합/증가
--  - 비스택형(무기/방어구 등)은 GUI가 생성되면 그 자체로 1개 납품 완료로 간주
--  - "스택 설정 실패" 오검출 제거

local Players           = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local StarterGui        = game:GetService("StarterGui")
local HttpService       = game:GetService("HttpService")

local SlotMapRegistry   = require(ReplicatedStorage:WaitForChild("SlotMapRegistry"))
local LootHandler       = require(ReplicatedStorage:WaitForChild("LootHandler"))
local StackBadge        = require(ReplicatedStorage:WaitForChild("StackBadge"))
local StackService      = require(ReplicatedStorage:WaitForChild("StackService"))

local plr    = Players.LocalPlayer
local DELIVER= ReplicatedStorage:WaitForChild("AdminGrantDeliver") :: RemoteEvent
local RESULT = ReplicatedStorage:FindFirstChild("AdminGrantResult") :: RemoteEvent?

-- ========= 인벤토리 UI 탐색/대기 =========
local function getInventoryRoot(): Instance?
	local pg = plr:FindFirstChildOfClass("PlayerGui")
	if not pg then return nil end
	local screen = pg:FindFirstChild("ScreenGui")
	if not screen then return nil end
	local invGui = screen:FindFirstChild("InventoryGui")
	if not invGui then return nil end
	return invGui:FindFirstChild("ScrollingInventory")
end

local function waitInventory(timeout: number): Instance?
	local t0 = time()
	repeat
		local inv = getInventoryRoot()
		if inv then return inv end
		task.wait(0.1)
	until time() - t0 >= timeout
	return nil
end

-- ========= 태그/스택 유틸 =========
local function readTags(gui: Instance): {string}
	local out = {}
	local ok, arr = pcall(function()
		local j = gui:GetAttribute("TagsJson")
		return (typeof(j)=="string" and #j>0) and HttpService:JSONDecode(j) or nil
	end)
	if ok and typeof(arr)=="table" then
		for _, t in ipairs(arr) do
			if typeof(t)=="string" then table.insert(out, t:lower()) end
		end
	end
	local csv = gui:GetAttribute("Tags")
	if typeof(csv)=="string" and #csv>0 then
		for tok in string.gmatch(csv, "[^,%s]+") do table.insert(out, tok:lower()) end
	end
	local t = gui:GetAttribute("Tag")
	if typeof(t)=="string" and #t>0 then table.insert(out, t:lower()) end

	local seen: {[string]: boolean} = {}
	local uniq: {string} = {}
	for _, v in ipairs(out) do
		if not seen[v] then seen[v]=true; table.insert(uniq, v) end
	end
	return uniq
end

local function hasTag(gui: Instance, tag: string): boolean
	tag = tag:lower()
	for _, t in ipairs(readTags(gui)) do
		if t == tag then return true end
	end
	return false
end

local function getMaxStackFor(guiOrName: Instance|string): number
	if typeof(guiOrName) == "Instance" then
		local gui = guiOrName :: Instance
		return StackService.GetMaxStack({
			Name     = gui:GetAttribute("ItemName") or gui.Name,
			Tag      = gui:GetAttribute("Tag"),
			Tags     = readTags(gui),
			StackMax = gui:GetAttribute("StackMax"),
		})
	else
		-- 이름만 있을 때는 Max를 “미정(1)”로 취급.
		-- 새 GUI를 만든 직후 실제 Max는 gui 속성/태그로 정확히 판별됨.
		return 1
	end
end

-- 스택형 판단: Count로 수량을 표현하는 타입
local function isStackable(gui: Instance): boolean
	-- 탄/소모품 등 명시 태그
	if hasTag(gui, "ammo") or hasTag(gui, "stackable") then return true end
	-- StackMax 속성 기반
	local sm = gui:GetAttribute("StackMax")
	if typeof(sm)=="number" and sm > 1 then return true end
	-- StackService 판단
	local maxN = getMaxStackFor(gui)
	return maxN > 1
end

local function setStack(gui: GuiObject, desired: number)
	local maxN = getMaxStackFor(gui)
	local n = math.clamp(desired or 1, 1, maxN)
	gui:SetAttribute("Count", n)
	StackBadge.Update(gui, n)
end

-- ========= 스택 머지/탐색(스택형 전용) =========
local function iterItemStacks(inv: Instance, itemName: string): {GuiObject}
	local out: {GuiObject} = {}
	for _, d in ipairs(inv:GetDescendants()) do
		if d:IsA("ImageLabel") or d:IsA("ViewportFrame") then
			local n = d:GetAttribute("ItemName") or d.Name
			if tostring(n) == itemName and isStackable(d) then
				table.insert(out, d :: GuiObject)
			end
		end
	end
	table.sort(out, function(a: GuiObject, b: GuiObject)
		local ca = tonumber(a:GetAttribute("Count")) or 1
		local cb = tonumber(b:GetAttribute("Count")) or 1
		local ma = getMaxStackFor(a)
		local mb = getMaxStackFor(b)
		return (ma - ca) > (mb - cb)
	end)
	return out
end

-- ========= 새 GUI 생성 폴백 =========
local function findLatestItemGuiByName(inv: Instance, itemName: string): GuiObject?
	local last: GuiObject? = nil
	for _, d in ipairs(inv:GetDescendants()) do
		if d:IsA("ImageLabel") or d:IsA("ViewportFrame") then
			local n = d:GetAttribute("ItemName") or d.Name
			if tostring(n) == itemName then
				last = d :: GuiObject
			end
		end
	end
	return last
end

local function grantOne(inv: Instance, stash: any, itemName: string, totalCount: number)
	local remain = math.max(1, math.floor(totalCount))

	-- 1) 기존 스택 채우기(스택형만)
	do
		local stacks = iterItemStacks(inv, itemName)
		for _, gui in ipairs(stacks) do
			if remain <= 0 then break end
			local cur = tonumber(gui:GetAttribute("Count")) or 1
			local cap = getMaxStackFor(gui)
			if cur < cap then
				local add = math.min(remain, cap - cur)
				setStack(gui, cur + add)
				remain -= add
			end
		end
	end

	-- 2) 남으면 새 GUI 생성 반복
	while remain > 0 do
		local gui = LootHandler.RequestItemByName(itemName, stash, inv) :: GuiObject?
		if not gui then
			gui = findLatestItemGuiByName(inv, itemName)
		end
		if not gui then
			warn(("[AdminGrant] '%s' GUI 생성 실패(칸 부족/이름 불일치 가능) - 남은 수량: %d"):format(itemName, remain))
			break
		end

		local placed = 0
		if isStackable(gui) then
			-- 스택형: Count로 채움(자동 클램프)
			local before = tonumber(gui:GetAttribute("Count")) or 0
			setStack(gui, before + remain)
			local after  = tonumber(gui:GetAttribute("Count")) or before
			placed = math.max(0, after - before)
		else
			-- 비스택형: GUI 생성 자체가 1개 납품
			placed = 1
			-- 혹시 Count가 생긴다면 1로 표준화(선택)
			if gui:GetAttribute("Count") == nil then
				gui:SetAttribute("Count", 1)
			end
			StackBadge.Update(gui, 1)
		end

		if placed <= 0 then
			-- 스택형인데 어딘가에서 Count 업데이트를 가로막은 경우
			warn(("[AdminGrant] '%s' 스택 증가 실패 - 남은 수량: %d"):format(itemName, remain))
			break
		end
		remain -= placed
	end
end

-- ========= 배치 처리 =========
local function performGrantBatch(items: {{name: string, count: number}})
	local stash = SlotMapRegistry.Get("Stash")
	local inv = waitInventory(10)
	if not stash or not inv then
		warn("[AdminGrant] 스태시/인벤토리 UI를 찾을 수 없음(나중에 다시 시도)")
		return false
	end
	for _, it in ipairs(items) do
		local name = tostring(it.name)
		local count = tonumber(it.count or 1) or 1
		if name ~= "" and count > 0 then
			grantOne(inv, stash, name, count)
		end
	end
	return true
end

-- ========= 큐/처리기 =========
local pending: { {name: string, count: number} } = {}
local processing = false

local function shallowCopy<T>(arr: {T}): {T}
	local out: {T} = {}
	for i = 1, #arr do out[i] = arr[i] end
	return out
end

local function flushPending()
	if processing then return end
	processing = true
	local invReady = waitInventory(30) ~= nil
	if not invReady then
		processing = false
		return
	end
	if #pending > 0 then
		local batch = shallowCopy(pending)
		table.clear(pending)
		local ok = performGrantBatch(batch)
		if not ok then
			for _, v in ipairs(batch) do table.insert(pending, v) end
		end
	end
	processing = false
end

-- ========= 이벤트 바인딩 =========
DELIVER.OnClientEvent:Connect(function(items)
	if typeof(items) ~= "table" then return end
	for _, it in ipairs(items) do
		local name = tostring((it and it.name) or "")
		local count = tonumber((it and it.count) or 1) or 1
		if name ~= "" and count > 0 then
			table.insert(pending, { name = name, count = count })
		end
	end
	task.defer(flushPending)
end)

if RESULT then
	RESULT.OnClientEvent:Connect(function(ok: boolean, msg: string)
		pcall(function()
			StarterGui:SetCore("SendNotification", {
				Title    = ok and "지급 완료" or "지급 실패",
				Text     = tostring(msg or ""),
				Duration = 3,
			})
		end)
	end)
end
