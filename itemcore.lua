--!strict
-- ?? ServerScriptService/ItemCore.server.lua
-- EFR ItemCore (Models/{Ammo,Mags,Weapons} 폴더 자동 주입판)
-- - 모델명에서 "Model" 제거 → 그 문자열을 Tag로 사용(요구사항)
-- - Ammo/Mags/Weapons 하위 폴더 재귀 스캔, 중복(.001 등) 무시
-- - 칼리버 자동 추출(5.56x45 / 300 BLK / .50 BMG / .277 Fury / 9x19 등 + "55645"→"5.56x45" 등 압축형도 지원)
-- - Mags는 10rnd/30rd/40rnd 등에서 Capacity 추출, 드럼 추정 사이즈
-- - Category 보존(ammo/mag/primaryweapon/secondaryweapon), Tag 정규화(cal:<canon> 등)
-- - 기존 하드코딩과 겹치면 폴더에서 읽은 항목이 우선(덮어씀)

local ReplicatedStorage = game:GetService("ReplicatedStorage")

-- RemoteFunction 보장
local GetStashData = ReplicatedStorage:FindFirstChild("GetStashData")
if not GetStashData or not GetStashData:IsA("RemoteFunction") then
	if GetStashData then GetStashData:Destroy() end
	GetStashData = Instance.new("RemoteFunction")
	GetStashData.Name = "GetStashData"
	GetStashData.Parent = ReplicatedStorage
end

-- 루트 폴더
local MODELS = ReplicatedStorage:FindFirstChild("Models")

-- ─────────────────────────────────────────────────────────
-- 문자열/칼리버 유틸
local function _stripModelSuffix(n: string): string
	return (n:gsub("[ _%-]*[Mm][Oo][Dd][Ee][Ll]$",""))
end
local function _stripCopySuffix(n: string): string
	return (n:gsub("%.%d+$",""))
end
local function _slugLower(s: string): string
	s = s:lower():gsub("%s+", " "):gsub("^%s+", ""):gsub("%s+$","")
	return s
end

-- "5.56x45 NATO" → "556x45", "300 BLK"→"300blk", ".50 BMG"→"127x99", ".277 Fury"→"68x51"
local function _canonCaliber(s: string?): string?
	if typeof(s) ~= "string" or s == "" then return nil end
	local raw = string.lower((s :: string):gsub("[^%w]+",""))
	raw = raw
		:gsub("nato$", ""):gsub("win$", ""):gsub("blk$", "")
		:gsub("rem$",  ""):gsub("lr$",  "")
	raw = raw:gsub("^300aacblackout$", "300blk")
	raw = raw:gsub("^300aac$", "300blk")
	raw = raw:gsub("^300blackout$", "300blk")
	raw = raw:gsub("^50bmg$", "127x99")
	raw = raw:gsub("^277fury$", "68x51")
	return raw
end

-- 모델 표시명에서 칼리버(표시용) 추출
local function _extractCaliberDisplay(name: string): string?
	local n = name
	-- 명시 키워드 우선
	if n:find("300%W*BLK") then return "300 BLK" end
	if n:find("%.?50%W*BMG") then return "12.7x99" end
	if n:find("%.?277%W*Fury") then return "6.8x51" end
	-- 일반 패턴 d(.d)? x d+
	do
		local a,b = n:lower():match("(%d+%.?%d*)%s*x%s*(%d+)")
		if a and b then return (a .. "x" .. b) end
	end
	-- 압축형(예: 55645 → 5.56x45, 54539 → 5.45x39, 76251→7.62x51, 4630→4.6x30, 12799→12.7x99)
	local lower = n:lower()
	local map5 = {
		["55645"]="5.56x45", ["54539"]="5.45x39", ["76239"]="7.62x39",
		["76251"]="7.62x51", ["76254"]="7.62x54R", ["12799"]="12.7x99",
	}
	for comp, pretty in pairs(map5) do
		if lower:find(comp) then return pretty end
	end
	-- 4자리 전용 (4.6x30)
	if lower:find("4630") then return "4.6x30" end
	-- 9x19 등 간단형
	if lower:find("9x19") then return "9x19" end
	return nil
end

-- ─────────────────────────────────────────────────────────
-- 기본 아이템(폴더 외 기타만 남김)
local ItemData: {[string]: any} = {
	["purina"] = { Name="purina", Image="rbxassetid://81311253759915", Width=2, Height=1, DisplayType="image", Tag="purina", Category="misc" },
	["burnis"] = { Name="burnis", Image="rbxassetid://81816177301870", Width=1, Height=1, DisplayType="image", Tag="burnis", Category="misc" },
	["dollar"] = { Name="dollar", Image="", Width=1, Height=1, DisplayType="model", ModelName="DollarModel", Tag="Dollar", Category="misc" },
	["jjkbock"] = { Name="jjkbock", Image="", Width=1, Height=2, DisplayType="model", ModelName="jjkbock Model", Tag="jjkbock", Category="misc" },
	["Hip Flask"] = { Name="Hip Flask", Image="", Width=1, Height=2, DisplayType="model", ModelName="Hip Flask Model", Tag="Hip Flask", Category="misc" },
	["3060"] = {
		Name        = "3060",
		Image       = "",
		Width       = 2, Height = 1,              -- 1x2
		DisplayType = "model",
		ModelName   = "3060",                     -- ?? ReplicatedStorage.Models 안에 "3060" 모델 존재해야 함
		Tag         = "3060",                     -- 모델명 그대로 태그
		Category    = "misc",                     -- 필요하면 "electronics"/"gpu" 등으로 바꿔도 됨
	},

	-- 장비(컨테이너 예시)
	["MILITARY_BACKPACK"] = {
		Name="MILITARY_BACKPACK", Image="", Width=6, Height=7, DisplayType="model", ModelName="MILITARY_BACKPACK Model",
		Tag="MILITARY_BACKPACK", Category="backpack", ContainerCols=6, ContainerRows=8, IsContainer=true,
	},
	["Case"] = {
		Name="Case", Image="", Width=3, Height=3, DisplayType="model", ModelName="Case Model",
		Tag="Case", Category="backpack", ContainerCols=3, ContainerRows=3, IsContainer=true,
	},
	["Case M"] = {
		Name="Case M", Image="", Width=3, Height=3, DisplayType="model",
		ModelName="Case M", Tag="Case M", Category="backpack",
		ContainerCols=2, ContainerRows=2, IsContainer=true,
	},
	["Case L"] = {
		Name="Case L", Image="", Width=3, Height=3, DisplayType="model",
		ModelName="Case L", Tag="Case L", Category="backpack",
		ContainerCols=2, ContainerRows=3, IsContainer=true,
	},
	["Case XL"] = {
		Name="Case XL", Image="", Width=3, Height=3, DisplayType="model",
		ModelName="Case XL", Tag="Case XL", Category="backpack",
		ContainerCols=3, ContainerRows=3, IsContainer=true,
	},
	["Case XXL"] = {
		Name="Case XXL", Image="", Width=3, Height=3, DisplayType="model",
		ModelName="Case XXL", Tag="Case XXL", Category="backpack",
		ContainerCols=3, ContainerRows=4, IsContainer=true,
	},
	["FASThelmet"] = { Name="FASThelmet", Image="", Width=2, Height=2, DisplayType="model", ModelName="FASThelmetModel", Tag="FASThelmet", Category="helmet" },
	-- ?? StrandHogg PC: 조끼 + 내부 파우치(6x3)
	["FirstSpear StrandHogg PC MCam"] = {
		Name        = "FirstSpear StrandHogg PC MCam",
		Image       = "",
		Width       = 3, Height = 3,
		DisplayType = "model",
		ModelName   = "FirstSpear StrandHogg PC MCam_Model",

		-- ? 태그 규칙: 모델명에서 'Model'만 제거
		Tag         = "FirstSpear StrandHogg PC MCam",
		Category    = "vest",

		-- 컨테이너(조끼 내부 파우치)
		ContainerCols = 6,
		ContainerRows = 3,
		IsContainer   = true,
	},

	-- ──────── [FOOD] 추가 ────────
	["MRE"] = {
		Name="MRE", Image="", Width=1, Height=2, DisplayType="model", ModelName="MRE Model",
		Tag="MRE", Category="food",
		ConsumeHint = { Energy=40, Hydration=15, UseTime=2.0 },
	},
	["Canned Meat"] = {
		Name="Canned Meat", Image="", Width=1, Height=1, DisplayType="model",ModelName="Canned Meat Model",
		Tag="Canned Meat", Category="food",
		ConsumeHint = { Energy=25, Hydration=0, UseTime=1.5 },
	},
	["Condensed Milk"] = {
		Name="Condensed Milk", Image="", Width=1, Height=1, DisplayType="model",ModelName="Condensed Milk Model",
		Tag="Condensed Milk", Category="food",
		ConsumeHint = { Energy=10, Hydration=30, UseTime=1.2 },
	},
	-- ─────────────────────────────
}

-- ─────────────────────────────────────────────────────────
-- 폴더 스캐너
local function _collectModels(root: Instance?): {Model}
	local out = {}
	if not (root and root:IsA("Folder")) then return out end
	for _, d in ipairs(root:GetDescendants()) do
		if d:IsA("Model") then table.insert(out, d) end
	end
	table.sort(out, function(a,b) return a.Name < b.Name end)
	return out
end

-- 중복 방지(표시명 기준)
local _seenKeys: {[string]: boolean} = {}
local function _put(key: string, data: {[string]: any})
	ItemData[key] = data
	_seenKeys[_slugLower(key)] = true
end

-- Ammo 모델 → 아이템 (Tag=모델기반, Category="ammo")
local function _ingestAmmoFolder(folder: Instance?)
	local count = 0
	for _, m in ipairs(_collectModels(folder)) do
		local base = _stripModelSuffix(_stripCopySuffix(m.Name)) -- ex) "5.56x45 M855A1"
		local key  = base
		local kLow = _slugLower(key)
		if not _seenKeys[kLow] then
			local calDisp = _extractCaliberDisplay(base) or ""
			_put(key, {
				Name        = base,
				Image       = "",
				Width       = 1, Height = 1,
				DisplayType = "model",
				ModelName   = m.Name,

				-- ? 규칙: 모델기반 Tag
				Tag         = base,
				Category    = "ammo",

				Caliber     = calDisp,
				IsStackable = true, StackUnit="round", StackMax=60, Stack=30,
			})
			count += 1
		end
	end
	return count
end

-- Mags 모델 → 아이템 (Tag=모델기반, Category="mag")
local function _ingestMagsFolder(folder: Instance?)
	local count = 0
	for _, m in ipairs(_collectModels(folder)) do
		local base = _stripModelSuffix(_stripCopySuffix(m.Name))
		local key  = base
		local kLow = _slugLower(key)
		if not _seenKeys[kLow] then
			local calDisp = _extractCaliberDisplay(base) or ""
			local cap = 0
			do
				local capStr = base:lower():match("(%d+)%s*rn?d") -- 10rnd/30rd/20rd…
				if capStr then cap = tonumber(capStr) or 0 end
			end

			-- ▶ 새 규칙: Height 매핑
			local height: number
			if cap >= 90 then           -- 100발(?90+) → 3칸
				height = 3
			elseif cap == 40 then       -- 40발 → 3칸(예외)
				height = 3
			elseif cap >= 25 then       -- 25, 30, 60, 50, 70… → 2칸
				height = 2
			elseif cap > 0 then         -- 25 미만 → 1칸
				height = 1
			else
				height = 2              -- cap 파싱 실패 시 안전한 기본값
			end

			_put(key, {
				Name        = base,
				Image       = "",
				Width       = (base:lower():find("drum") or (cap >= 90)) and 2 or 1,
				Height      = height,   -- ← 여기만 바뀜
				DisplayType = "model",
				ModelName   = m.Name,

				Tag         = base,
				Category    = "mag",

				Caliber     = calDisp,
				Capacity    = cap > 0 and cap or nil,
			})
			count += 1
		end
	end
	return count
end

-- Weapons 모델 → 아이템 (Tag=모델기반, Category=무기 분류)
local function _ingestWeaponsFolder(folder: Instance?)
	local count = 0
	for _, m in ipairs(_collectModels(folder)) do
		local base = _stripModelSuffix(_stripCopySuffix(m.Name))
		local key  = base
		local kLow = _slugLower(key)
		if not _seenKeys[kLow] then
			local lower = base:lower()
			local isPistol = (lower:find("g17") or lower:find("glock") or lower:find("92fs")
				or lower:find("p226") or lower:find("pistol"))
			local category = isPistol and "secondaryweapon" or "primaryweapon"
			local calDisp = _extractCaliberDisplay(base) or ""
			_put(key, {
				Name        = base,
				Image       = "",
				Width       = isPistol and 2 or 3,
				Height      = isPistol and 1 or 2,
				DisplayType = "model",
				ModelName   = m.Name,

				Tag         = base,
				Category    = category,

				Caliber     = calDisp,
				WeaponId    = base,
			})
			count += 1
		end
	end
	return count
end

-- 폴더 자동 주입
local ammoAdded, magsAdded, weapAdded = 0, 0, 0
if MODELS and MODELS:IsA("Folder") then
	local Ammo    = MODELS:FindFirstChild("Ammo")
	local Mags    = MODELS:FindFirstChild("Mags")
	local Weapons = MODELS:FindFirstChild("Weapons")
	ammoAdded = _ingestAmmoFolder(Ammo)
	magsAdded = _ingestMagsFolder(Mags)
	weapAdded = _ingestWeaponsFolder(Weapons)
end
print(("[ItemCore] Auto-ingested: Ammo=%d, Mags=%d, Weapons=%d"):format(ammoAdded, magsAdded, weapAdded))

-- ─────────────────────────────────────────────────────────
-- 태그 정규화(공통)
local function _dedupLower(tags: {string})
	local seen: {[string]: boolean} = {}
	local out: {string} = {}
	for _, t in ipairs(tags) do
		local k = string.lower(t)
		if not seen[k] then seen[k]=true; table.insert(out, k) end
	end
	return out
end

local function _normalizeTagsForAllItems(itemData: {[string]: any})
	for key, it in pairs(itemData) do
		-- 모델기반 Tag(없을 일은 없지만 방어)
		local modelTag = (typeof(it.Tag) == "string" and it.Tag ~= "" and it.Tag) or _stripModelSuffix(key)
		local category = (typeof(it.Category) == "string" and it.Category ~= "" and it.Category) or "misc"

		local tags = { category:lower(), _slugLower(modelTag) }

		-- 구경 태그
		if typeof(it.Caliber) == "string" and it.Caliber ~= "" then
			local calDisp = it.Caliber
			local calCanon = _canonCaliber(calDisp)
			table.insert(tags, calDisp:lower())
			if calCanon then table.insert(tags, "cal:"..calCanon) end
		end

		-- 무기 보조태그
		if category:lower() == "primaryweapon" then
			table.insert(tags, "primaryweapon2")
		end

		-- 모델명도 보조 태그
		if typeof(it.ModelName) == "string" and it.ModelName ~= "" then
			local mb = _stripModelSuffix(it.ModelName)
			if mb ~= "" then table.insert(tags, mb:lower()) end
		end

		it.Tags = _dedupLower(tags)
		it.Tag  = modelTag -- ? 최종 Tag = 모델에서 'Model' 뺀 문자열
	end
end

_normalizeTagsForAllItems(ItemData)

-- ─────────────────────────────────────────────────────────
-- 안전 얕은 복사 + RemoteFunction
local function _shallowCopy(tbl: {[any]: any}): {[any]: any}
	local out: {[any]: any} = {}
	for k, v in pairs(tbl) do out[k] = v end
	return out
end

GetStashData.OnServerInvoke = function(player, itemName: string)
	print(("?? [서버] %s 요청: %s"):format(player.Name, tostring(itemName)))
	local data = ItemData[itemName]
	if not data then
		warn("? 존재하지 않는 아이템:", itemName)
		return nil
	end

	local tagsStr = data.Tags and table.concat(data.Tags, ",") or tostring(data.Tag)
	print(("? 반환: %s W=%d H=%d Tag(s)=%s"):format(
		data.Name, data.Width or -1, data.Height or -1, tagsStr
		))
	if data.ContainerCols and data.ContainerRows then
		print(("?? 컨테이너: %dx%d"):format(data.ContainerCols, data.ContainerRows))
	end
	return _shallowCopy(data)
end

-- 선택) 전체 데이터 접근용
function GetAllItemData()
	return ItemData
end
