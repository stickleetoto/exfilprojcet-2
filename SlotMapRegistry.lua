
local SlotMapManager = require(script.Parent:WaitForChild("SlotMapManager"))

-- ==== 글로벌 싱글톤 슬롯 ====
local KEY = "__SLOT_REG_SINGLETON_GRIDKEY_V1__"
_G[KEY] = _G[KEY] or { __init = false }
local R = _G[KEY] :: {
	__init: boolean?,
	__booted: boolean?,
	_maps: {[string]: any}?,
	_alias: {[string]: string}?,
	Equipment: {[string]: {
		Frame: Instance,
		Tag: string,
		Occupied: boolean,
		EquippedItem: any?,
	}}?,
	[string]: any,
}

if not R.__init then
	R._maps     = {} :: {[string]: any}      -- gridkey → SlotMapManager
	R._alias    = {} :: {[string]: string}   -- alias  → gridkey
	R.Equipment = {}                         -- [slotName] = { Frame, Tag, Occupied, EquippedItem }
	R.__init    = true
end

-- ==== 유틸 ====
local function slug(s: string?): string
	local t = tostring(s or ""):lower()
	t = t:gsub("[%s_]+",""):gsub("[^%w:]+","")
	return t
end

local function capFirst(k: string): string
	return (k:gsub("^%l", string.upper))
end

local function isGridKey(k: string): boolean
	return k:sub(1,5) == "grid:"
end

local function MakeGridKey(tagKey: string, ownerUid: string?): string
	local t = slug(tagKey)
	if ownerUid and ownerUid ~= "" then
		return ("grid:%s:%s"):format(t, slug(ownerUid))
	end
	return ("grid:%s"):format(t)
end

-- 흔한 별칭 정규화(철자 실수 포함)
local aliasLower: {[string]: string} = {
	stash="stash", ["poket"]="pocket", pocket="pocket",
	raid="raidloot", raidloot="raidloot",
	rig="vest", vest="vest",
	backpack="backpack", bag="backpack",
	securecontainer="securecontainer", secure="securecontainer",
	equipment="equipment",
}
local function normAlias(k: string): string
	k = tostring(k or ""):lower()
	return aliasLower[k] or k
end

local function _putGrid(gridKey: string, map: any)
	(R._maps :: any)[gridKey] = map
end

local function _bindAlias(alias: string, gridKey: string)
	(R._alias :: any)[alias] = gridKey
end

-- ==== 공개 API ====
local registry = {}

-- GridKey 생성기 노출
function registry.MakeGridKey(tagKey: string, ownerUid: string?): string
	return MakeGridKey(tagKey, ownerUid)
end

-- gridkey 또는 alias로 맵 보장 생성
-- rows/cols는 항상 "맵" 기준
function registry.Ensure(slotTypeOrGridKey: string, rows: number, cols: number)
	rows = math.max(1, math.floor(rows or 1))
	cols = math.max(1, math.floor(cols or 1))

	local key = slug(slotTypeOrGridKey)
	if not isGridKey(key) then
		-- alias → gridkey 해석(미등록 시 기본 grid:<alias>)
		local a  = normAlias(key)
		local gk = (R._alias :: any)[a] or MakeGridKey(a)
		key = gk
	end

	local existing = (R._maps :: any)[key]
	if existing and existing.rows == rows and existing.cols == cols then
		return existing
	end

	local newMap = SlotMapManager.new(rows, cols)
	newMap.rows, newMap.cols = rows, cols
	_putGrid(key, newMap)

	-- 단일 별칭(grid:<alias>)이면 R.<Alias> 포인터도 갱신
	do
		local alias = key:match("^grid:([^:]+)$")
		if alias then
			R[capFirst(alias)] = newMap
			_bindAlias(alias, key)
		end
	end

	return newMap
end

-- gridkey/alias로 조회(없으면 R.<Alias> 폴백)
function registry.Get(slotTypeOrGridKey: string)
	if type(slotTypeOrGridKey) ~= "string" then return nil end
	local key = slug(slotTypeOrGridKey)

	-- grid:<...> 직접 키
	if isGridKey(key) then
		return (R._maps :: any)[key]
	end

	-- 별칭 → 바운드 gridkey
	local a  = normAlias(key)
	local gk = (R._alias :: any)[a]
	if gk and (R._maps :: any)[gk] then
		return (R._maps :: any)[gk]
	end

	-- 폴백: R.Stash / R.Pocket / R.RaidLoot / R.Backpack / R.Vest / R.Securecontainer 등
	return R[capFirst(a)]
end

-- gridkey/alias에 맵 바인딩(이미 생성된 맵을 주입)
function registry.Set(slotTypeOrGridKey: string, map: any)
	if not map then return end
	local key = slug(slotTypeOrGridKey)
	if not isGridKey(key) then
		local a  = normAlias(key)
		local gk = (R._alias :: any)[a] or MakeGridKey(a)
		key = gk
		_bindAlias(a, gk)
	end
	_putGrid(key, map)

	-- 단일 별칭이면 R.<Alias> 포인터도 동기화
	local alias = key:match("^grid:([^:]+)$")
	if alias then
		R[capFirst(alias)] = map
	end
end

-- 장비 슬롯 프레임/태그 등록
function registry.RegisterEquipmentSlot(slotName: string, frame: Instance, tag: string?)
	if type(slotName) ~= "string" or not frame then
		warn("[SlotMapRegistry] invalid RegisterEquipmentSlot args"); return
	end
	(R.Equipment :: any)[slotName] = {
		Frame        = frame,
		Tag          = (tag or slotName):lower(),
		Occupied     = false,
		EquippedItem = nil,
	}
end

-- 디버그 포인터(테스트/프린트용)
function registry._debugPointers()
	return R.Stash, R.Pocket, R.Equipment, R.RaidLoot, R.Vest, R.Backpack, R.Securecontainer
end

-- ==== 초기 부팅(기본 그리드 보장) ====
if not R.__booted then
	-- 행/열 기준(세로 rows, 가로 cols)
	-- EFT풍 기본치: 스태쉬 10x30, 포켓 4x1, 레이드루트 8x10
	local stash  = registry.Ensure("stash",     30, 10); R.Stash    = stash
	local pocket = registry.Ensure("pocket",     4,  1); R.Pocket   = pocket
	local raid   = registry.Ensure("raidloot",   8, 10); R.RaidLoot = raid
	-- vest/backpack/securecontainer는 실제 장착/팝아웃 시점에 Ensure/Set으로 주입
	R.__booted = true
end

return registry
