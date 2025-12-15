--!strict
-- ReplicatedStorage/MagService.lua (교체본)
-- GUI 탄/탄창 속성 차이 흡수 + 로딩/소모 규칙 제공
-- - MagCur/MagMax <-> AmmoInMag/MagCap 동기화
-- - 태그/칼리버 정규화("×"→"x", 점/공백 제거 등)
-- - StackBadge가 있으면 배지 업데이트 호출(시각 숫자는 '현재 장탄수'를 그대로 표시)

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local HttpService       = game:GetService("HttpService")

local function _tryRequire(name: string)
	local ok, m = pcall(function() return require(ReplicatedStorage:WaitForChild(name, 0.5)) end)
	return ok and m or nil
end

local StackBadge = _tryRequire("StackBadge")

local M = {}

-- ───────── 유틸

local function _updateBadge(gui: Instance?)
	if not (StackBadge and gui) then return end
	pcall(function()
		if (StackBadge :: any).Update then
			(StackBadge :: any).Update(gui)
		elseif (StackBadge :: any).Attach then
			(StackBadge :: any).Attach(gui)
		end
	end)
end

-- 탄창 배지 숫자를 '현재 장탄수'로 고정 표시
local function _setMagDisplayToCur(gui: Instance)
	local cur = tonumber(gui:GetAttribute("MagCur"))
		or tonumber(gui:GetAttribute("AmmoInMag")) or 0
	gui:SetAttribute("DisplayCount", math.max(0, math.floor(cur))) -- 0도 그대로 보이게(탄창은 0/1 모두 표시 규칙)
end

local function _collectTags(gui: Instance?): {string}
	if not gui then return {} end
	local tags: {string} = {}

	local raw = gui:GetAttribute("TagsJson")
	if typeof(raw) == "string" and raw ~= "" then
		local ok, arr = pcall(function() return HttpService:JSONDecode(raw) end)
		if ok and typeof(arr) == "table" then
			for _, v in ipairs(arr) do table.insert(tags, string.lower(tostring(v))) end
		else
			for tok in string.gmatch(raw, "[^,%s]+") do
				table.insert(tags, string.lower(tok))
			end
		end
	end
	local t = gui:GetAttribute("Tag")
	if typeof(t) == "string" and t ~= "" then table.insert(tags, string.lower(t)) end

	-- uniq
	local seen: {[string]: boolean} = {}
	local out: {string} = {}
	for _, v in ipairs(tags) do
		if not seen[v] then seen[v] = true; table.insert(out, v) end
	end
	return out
end

local function _normCal(s: string?): string
	local x = tostring(s or ""):lower()
	x = x:gsub("%s+",""):gsub("%.",""):gsub("×","x")
	if x == "55645"  then return "556x45"  end
	if x == "54539"  then return "545x39"  end
	if x == "76239"  then return "762x39"  end
	if x == "76251"  then return "762x51"  end
	if x == "76254r" then return "762x54r" end
	return x
end

local function _caliberFrom(gui: Instance?): string
	if not gui then return "" end
	local c = gui:GetAttribute("AmmoCaliber")
		or gui:GetAttribute("MagCaliber")
		or gui:GetAttribute("Caliber")
		or gui:GetAttribute("CaliberDisplay")
	if typeof(c) == "string" and c ~= "" then return _normCal(c) end
	for _, t in ipairs(_collectTags(gui)) do
		if t:sub(1,4) == "cal:" then return _normCal(t:sub(5)) end
	end
	return ""
end

-- ───────── 판정

local function _isAmmo(gui: Instance?): boolean
	if not gui then return false end
	for _, t in ipairs(_collectTags(gui)) do if t == "ammo" then return true end end
	if gui:GetAttribute("IsAmmo") == true then return true end
	return gui:GetAttribute("Count") ~= nil and gui:GetAttribute("AmmoId") ~= nil
end

local function _isMag(gui: Instance?): boolean
	if not gui then return false end
	if gui:GetAttribute("IsMag") == true or gui:GetAttribute("ItemType") == "Mag" then return true end
	if gui:GetAttribute("MagMax") ~= nil or gui:GetAttribute("MagCur") ~= nil
		or gui:GetAttribute("MagCap") ~= nil or gui:GetAttribute("AmmoInMag") ~= nil then
		return true
	end
	for _, t in ipairs(_collectTags(gui)) do if t == "mag" then return true end end
	return false
end

M.IsMag  = _isMag
M.IsAmmo = _isAmmo

-- ───────── 정규화/동기화

local function _ensureMagAttrs(m: Instance)
	if not _isMag(m) then return end
	local cap = tonumber(m:GetAttribute("MagMax")) or tonumber(m:GetAttribute("MagCap")) or 0
	if cap <= 0 then cap = 30 end
	local cur = tonumber(m:GetAttribute("MagCur")) or tonumber(m:GetAttribute("AmmoInMag")) or 0
	cur = math.clamp(cur, 0, cap)
	m:SetAttribute("MagMax", cap)
	m:SetAttribute("MagCap", cap)
	m:SetAttribute("MagCur", cur)
	m:SetAttribute("AmmoInMag", cur)
	_setMagDisplayToCur(m) -- ★ 배지 숫자 = 현재 장탄수
	_updateBadge(m)
end

-- MagCur/AmmoInMag 변경 감지 → DisplayCount/배지 즉시 갱신
local function _watchMagDisplay(mag: Instance)
	if not _isMag(mag) then return end
	if mag:GetAttribute("_MagWatchOn") == true then return end
	mag:SetAttribute("_MagWatchOn", true)
	local function refresh()
		_setMagDisplayToCur(mag)
		_updateBadge(mag)
	end
	mag:GetAttributeChangedSignal("AmmoInMag"):Connect(refresh)
	mag:GetAttributeChangedSignal("MagCur"):Connect(refresh)
end

function M.Normalize(gui: Instance)
	if _isMag(gui) then
		_ensureMagAttrs(gui)
		_watchMagDisplay(gui) -- ★ 외부에서 수치가 바뀌어도 즉시 반영
	elseif _isAmmo(gui) then
		local n = tonumber(gui:GetAttribute("Count")) or 0
		n = math.max(0, math.floor(n))
		gui:SetAttribute("Count", n)
		-- 탄(루즈탄)은 DisplayCount를 건드리지 않음(기본 배지 규칙 유지)
		_updateBadge(gui)
	end
end

-- ───────── 칼리버 호환

function M.GetCompatCals(m: Instance): {[string]: boolean}
	local set: {[string]: boolean} = {}
	local c = _normCal(_caliberFrom(m))
	if c ~= "" then set[c] = true end
	return set
end

function M.CanLoadAmmo(mag: Instance, ammo: Instance): boolean
	if not (_isMag(mag) and _isAmmo(ammo)) then return false end
	local cset = M.GetCompatCals(mag)
	local acal = _normCal(_caliberFrom(ammo))
	if acal == "" then return false end
	local locked = _normCal(tostring(mag:GetAttribute("MagAmmoCal") or ""))
	if locked ~= "" and locked ~= acal then return false end
	return cset[acal] == true
end

function M.GetCur(mag: Instance): number _ensureMagAttrs(mag); return tonumber(mag:GetAttribute("MagCur")) or 0 end
function M.GetMax(mag: Instance): number _ensureMagAttrs(mag); return tonumber(mag:GetAttribute("MagMax")) or 0 end
function M.GetFree(mag: Instance): number return math.max(0, M.GetMax(mag) - M.GetCur(mag)) end

local function _setAmmoCount(ammo: Instance, n: number)
	n = math.max(0, math.floor(n))
	ammo:SetAttribute("Count", n)
	_updateBadge(ammo)
end

local function _setMagCur(mag: Instance, cur: number)
	_ensureMagAttrs(mag)
	local max = tonumber(mag:GetAttribute("MagMax")) or 0
	cur = math.clamp(math.floor(cur), 0, max)
	mag:SetAttribute("MagCur", cur)
	mag:SetAttribute("AmmoInMag", cur)
	if cur == 0 then mag:SetAttribute("MagAmmoCal", "") end
	_setMagDisplayToCur(mag) -- ★ 숫자 즉시 갱신
	_updateBadge(mag)
end

function M.LoadFromAmmo(mag: Instance, ammo: Instance): number
	if not M.CanLoadAmmo(mag, ammo) then return 0 end
	local free = M.GetFree(mag); if free <= 0 then return 0 end
	local have = tonumber(ammo:GetAttribute("Count")) or 0; if have <= 0 then return 0 end
	local moved = math.min(free, have)
	_setMagCur(mag, M.GetCur(mag) + moved)
	if tostring(mag:GetAttribute("MagAmmoCal") or "") == "" then
		mag:SetAttribute("MagAmmoCal", _normCal(_caliberFrom(ammo)))
	end
	_setAmmoCount(ammo, have - moved)
	return moved
end

function M.Empty(mag: Instance) if _isMag(mag) then _setMagCur(mag, 0) end end

return M
