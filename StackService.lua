--!strict
-- ReplicatedStorage/StackService.lua
-- 변경 요약:
--  - AMMO Max=60 유지
--  - 탄창(tag="mag")은 Count<=0이어도 제거하지 않음(존재 유지)
--  - 머지/코얼레싱 후 정리 시, "탄창만" 0 스택 허용

local AMMO_DEFAULT_MAX = 60

export type Item = {
	Name: string,
	Id: string?,
	Tag: string?,      -- "ammo" / "mag" 등
	Tags: {any}?,
	Count: number?,    -- 스택 수
	StackMax: number?,
}

local M = {}

-- ---------- utils ----------
local function lower(s:any): string
	return typeof(s)=="string" and string.lower(s) or ""
end

local function hasTag(it: Item, tag: string): boolean
	local want = lower(tag)
	if lower(it.Tag) == want then return true end
	if typeof(it.Tags) == "table" then
		for _,t in ipairs(it.Tags :: {any}) do
			if typeof(t)=="string" and lower(t)==want then return true end
		end
	end
	return false
end

local function getTagValue(it: Item, prefix: string): string?
	if typeof(it.Tags) ~= "table" then return nil end
	local want = lower(prefix)
	for _,t in ipairs(it.Tags :: {any}) do
		if typeof(t)=="string" then
			local s = lower(t)
			if string.sub(s,1,#want) == want then
				local v = string.sub(s, #want+1)
				if v and #v>0 then return v end
			end
		end
	end
	return nil
end

local function isAmmo(it: Item): boolean
	return hasTag(it, "ammo")
end

local function isMag(it: Item): boolean
	return hasTag(it, "mag")
end

local function getCal(it: Item): string
	return getTagValue(it, "cal:") or ""
end

-- ---------- stacking rules ----------
local function getMaxStack(it: Item): number
	if not it then return 1 end
	if isAmmo(it) then
		return AMMO_DEFAULT_MAX -- 60 유지
	end
	if typeof(it.StackMax)=="number" and (it.StackMax :: number) >= 2 then
		return math.floor(it.StackMax :: number)
	end
	local byTag = getTagValue(it, "stackmax:")
	if byTag then
		local n = tonumber(byTag)
		if n and n >= 2 then return math.floor(n) end
	end
	return 1
end

local function stackKey(it: Item): string
	local name = lower(it.Name)
	if isAmmo(it) then
		return table.concat({"ammo", name, getCal(it)}, "|")
	end
	if isMag(it) then
		return table.concat({"mag", name}, "|")
	end
	return table.concat({"gen", name}, "|")
end

function M.GetMaxStack(it: Item): number
	return getMaxStack(it)
end

function M.CanStackWith(a: Item, b: Item): boolean
	if not a or not b then return false end
	local ma, mb = getMaxStack(a), getMaxStack(b)
	if ma < 2 or mb < 2 then return false end
	return stackKey(a) == stackKey(b)
end

function M.MergePair(a: Item, b: Item): number
	if not M.CanStackWith(a,b) then return 0 end
	a.Count = tonumber(a.Count) or 1
	b.Count = tonumber(b.Count) or 1
	local maxA = getMaxStack(a)
	local moved = math.min(maxA - a.Count, b.Count)
	if moved <= 0 then return 0 end
	a.Count += moved
	b.Count -= moved
	return moved
end

-- uidA(아래/기존) <- uidB(위/드래그)의 순서로 흡수
function M.TryMergeList(list:{Item}, uidA:string, uidB:string): boolean
	local ia, ib
	for i,it in ipairs(list) do
		if tostring(it.Id or "") == uidA then ia = i end
		if tostring(it.Id or "") == uidB then ib = i end
	end
	if not ia or not ib then return false end
	local A, B = list[ia], list[ib]
	if M.MergePair(A,B) <= 0 then return false end

	-- ★ 변경: B가 0이어도 탄창이면 남긴다
	if (tonumber(B.Count) or 0) <= 0 then
		if isMag(B) then
			B.Count = 0 -- 존재 유지
		else
			table.remove(list, ib)
		end
	end
	return true
end

-- 같은 키끼리 전부 압축(각 아이템의 '자기 Max'를 존중)
function M.EnsureCoalesced(list:{Item})
	local buckets: {[string]: {idxs:{number}, total:number}} = {}
	local maxByIdx: {[number]: number} = {}

	for i,it in ipairs(list) do
		local maxN = getMaxStack(it)
		it.Count = tonumber(it.Count) or 1
		maxByIdx[i] = maxN
		if maxN >= 2 then
			local k = stackKey(it)
			local b = buckets[k]
			if not b then b = {idxs={}, total=0}; buckets[k]=b end
			table.insert(b.idxs, i)
			b.total += it.Count
		end
	end

	for _,b in pairs(buckets) do
		local remain = b.total
		for _,idx in ipairs(b.idxs) do
			if remain <= 0 then
				list[idx].Count = 0
			else
				local maxN = maxByIdx[idx]
				local give = math.min(maxN, remain)
				list[idx].Count = give
				remain -= give
			end
		end
	end

	-- ★ 변경: 탄창은 Count<=0이어도 삭제하지 않음
	local j=1
	while j<=#list do
		local c = tonumber(list[j].Count) or 0
		if c <= 0 and not isMag(list[j]) then
			table.remove(list, j)
		else
			j += 1
		end
	end
end

-- (선택) UI에서 쓸 때, 표시용 카운트 계산기
function M.GetDisplayCount(it: Item): number
	local raw = math.floor(tonumber(it.Count) or 0)
	if raw <= 0 then return 1 end -- 0→1 규칙(표시 전용)
	return raw
end

return M
