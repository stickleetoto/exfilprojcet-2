--!strict
-- Starter 지급: 서버에서 StarterGrantEvent 를 쏠 때 "딱 한 번" 실행
local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local HttpService = game:GetService("HttpService")

local SlotMapRegistry = require(ReplicatedStorage:WaitForChild("SlotMapRegistry"))
local LootHandler     = require(ReplicatedStorage:WaitForChild("LootHandler"))
local StackBadge      = require(ReplicatedStorage:WaitForChild("StackBadge"))
local StackService    = require(ReplicatedStorage:WaitForChild("StackService"))

local player = Players.LocalPlayer
local RE = ReplicatedStorage:WaitForChild("StarterGrantEvent")

-- 세션 중 중복 방지
local alreadyDid = false

-- 원하는 지급 내역(이름과 스택 개수)
local grants = {
	{ name = "5.56x45 M995", count = 60 },
	{ name = "Case", count = 1 },
	{ name = "MCX", count = 1 },
	{ name = "3060", count = 1 },
	{ name = "burnis", count = 1 },
	{ name = "6SH118", count = 1 },
	{ name = "FASThelmet", count = 1 },
	{ name = "FirstSpear StrandHogg PC MCam", count = 1 },
	{ name = "Case", count = 1 },
}

-- 태그 읽기( TagsJson / Tags CSV / Tag 단일 )
local function readTags(gui: Instance): {string}
	local out = {}
	local ok, arr = pcall(function()
		local j = gui:GetAttribute("TagsJson")
		return (typeof(j)=="string" and #j>0) and HttpService:JSONDecode(j) or nil
	end)
	if ok and typeof(arr)=="table" then
		for _, t in ipairs(arr) do
			if typeof(t)=="string" then table.insert(out, string.lower(t)) end
		end
	end
	local csv = gui:GetAttribute("Tags")
	if typeof(csv)=="string" and #csv>0 then
		for tok in string.gmatch(csv, "[^,%s]+") do
			table.insert(out, string.lower(tok))
		end
	end
	local t = gui:GetAttribute("Tag")
	if typeof(t)=="string" and #t>0 then
		table.insert(out, string.lower(t))
	end
	-- 중복 제거
	local seen, uniq = {}, {}
	for _, v in ipairs(out) do if not seen[v] then seen[v]=true; table.insert(uniq, v) end end
	return uniq
end

-- 갓 만든 동일 이름 아이템 GUI를 찾아주는 폴백
local function findLatestItemGuiByName(inv: Instance, itemName: string): GuiObject?
	local last
	for _, d in ipairs(inv:GetDescendants()) do
		if (d:IsA("ImageLabel") or d:IsA("ViewportFrame")) then
			local n = d:GetAttribute("ItemName") or d.Name
			if tostring(n) == itemName then
				last = d
			end
		end
	end
	return last
end

-- 생성 직후 Count 세팅(스택 최대치에 맞춰 클램프)
local function setInitialStack(gui: GuiObject, desired: number)
	local tags = readTags(gui)
	local maxN = StackService.GetMaxStack({
		Name     = gui:GetAttribute("ItemName") or gui.Name,
		Tag      = gui:GetAttribute("Tag"),
		Tags     = tags,
		StackMax = gui:GetAttribute("StackMax"),
	})
	local n = math.clamp(desired or 1, 1, maxN)
	gui:SetAttribute("Count", n)
	StackBadge.Update(gui, n)
end

local function waitForInventory(timeout: number): Instance?
	local t0 = time()
	while time() - t0 < timeout do
		local pg = player:FindFirstChildOfClass("PlayerGui")
		local inv = pg
			and pg:FindFirstChild("ScreenGui")
			and pg.ScreenGui:FindFirstChild("InventoryGui")
			and pg.ScreenGui.InventoryGui:FindFirstChild("ScrollingInventory")
		if inv then return inv end
		task.wait(0.1)
	end
	return nil
end

local function doGrantOnce()
	if alreadyDid then return end
	alreadyDid = true

	-- UI 준비를 조금 기다려 준다
	task.wait(3)

	local stash = SlotMapRegistry.Get("Stash")
	local inv = waitForInventory(10) -- 최대 10초 대기

	if not stash or not inv then
		warn("[StarterGrant] 스태시 또는 인벤토리 UI를 찾을 수 없음")
		return
	end

	for _, g in ipairs(grants) do
		local gui = LootHandler.RequestItemByName(g.name, stash, inv)
		if not gui then
			gui = findLatestItemGuiByName(inv, g.name)
		end
		if gui then
			setInitialStack(gui, g.count or 1)
		else
			warn(("[StarterGrant] '%s' GUI를 찾지 못해 Count 설정을 건너뜀"):format(g.name))
		end
	end
end

-- 서버가 “진짜 최초”인 플레이어에게만 이 이벤트를 쏜다
RE.OnClientEvent:Connect(doGrantOnce)
