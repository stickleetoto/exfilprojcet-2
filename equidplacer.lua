--!strict
-- 장비 슬롯 초기화 (화이트리스트 + 레거시 호환 + 키 정규화)
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local SlotMapRegistry   = require(ReplicatedStorage:WaitForChild("SlotMapRegistry"))
local HttpService       = game:GetService("HttpService")
local Players           = game:GetService("Players")

local player = Players.LocalPlayer
local gui    = player:WaitForChild("PlayerGui"):WaitForChild("ScreenGui")
local inv    = gui:WaitForChild("InventoryGui")

-- 공백 정리 + 소문자
local function norm(s: string): string
	return s:lower():gsub("%s+"," "):gsub("^%s+",""):gsub("%s+$","")
end

-- ?? 오버라이드를 "정규화된 키"로 선언
--   accept에는 모델 태그 + 카테고리 태그를 함께 넣어 장착 허용 범위를 넓힌다.
local overridesByKey: {[string]: { accept: {string }, primaryTag: string }} = {
	[norm("first weapon")]  = {
		-- 1번 슬롯은 'primaryweapon' 계열
		accept     = { "primaryweapon", "mcx", "m4a1" },
		primaryTag = "primaryweapon",
	},
	[norm("first weapon2")] = {
		-- 2번 슬롯은 'primaryweapon2' 계열로 분리
		accept     = { "primaryweapon2", "mcx", "m4a1" },
		primaryTag = "primaryweapon2",
	},
	[norm("backpack")]      = {
		accept     = { "backpack", "MILITARY_BACKPACK" },
		primaryTag = "backpack",
	},
	[norm("vest")]          = {
		accept     = { "vest", "firstspear strandhogg pc mcam" },
		primaryTag = "vest",
	},
	[norm("helmet")]        = {
		accept     = { "helmet", "fasthelmet" },
		primaryTag = "helmet",
	},
	[norm("Secure Container")] = {
		accept     = { "securecontainer", "case" },
		primaryTag = "securecontainer",
	},
}

-- 오버라이드가 없으면 슬롯 이름 자체를 태그로 사용(레거시 폴백)
local function fallbackFor(slotName: string): { accept: {string}, primaryTag: string }
	local tag = norm(slotName)
	return { accept = { tag }, primaryTag = tag }
end

local function reg(slotParent: Instance)
	if not slotParent:IsA("Frame") then return end

	-- ? 슬롯 이름을 정규화해서 오버라이드 조회
	local key = norm(slotParent.Name)
	local cfg = overridesByKey[key] or fallbackFor(slotParent.Name)

	-- 안전한 배열 생성
	local accepts: {string} = {}
	for _, t in ipairs(cfg.accept) do
		accepts[#accepts+1] = norm(t)
	end
	local primary = norm(cfg.primaryTag)

	-- 슬롯 프레임
	local f = Instance.new("Frame")
	f.Name  = "Slot"
	f.Size  = UDim2.fromScale(1, 1)
	f.BackgroundTransparency = 1
	f.Parent = slotParent

	-- 드래그-드롭 검사용 허용 태그 목록
	f:SetAttribute("AcceptTagsJson", HttpService:JSONEncode(accepts))

	-- 레지스터: 세 번째 인자는 대표 카테고리(레거시 스크립트 보호용)
	-- 1번=primaryweapon, 2번=primaryweapon2 로 명확히 분리
	SlotMapRegistry.RegisterEquipmentSlot(slotParent.Name, f, primary)
end

for _, p in ipairs(inv.EquipmentFrame:GetChildren()) do
	if p:IsA("Frame") then reg(p) end
end
for _, p in ipairs(inv.Equipmentingame:GetChildren()) do
	if p:IsA("Frame") then reg(p) end
end
