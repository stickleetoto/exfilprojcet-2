--!strict
-- ?? ReplicatedStorage/AmmoCatalog.lua
-- 단일 진실원본: 탄 데이터(300 BLK 삭제판)

local Catalog = {}

export type AmmoInfo = {
	name: string,
	caliber: string,      -- "5.56x45", "7.62x39", "9x19", "12x70", "4.6x30" 등
	pen: number,          -- 관통
	damage: number,       -- 유효피해
	armorDamage: number?, -- 방탄 내구도 피해
	muzzleVel: number?,   -- 초속
	pellets: number?,     -- 샷건 펠릿 수
	pelletSpread: number?,-- 펠릿 퍼짐(deg)
	tags: {string}?,      -- {"AP","tracer","subsonic",...}
}

-- 느슨한 키 매칭용
local function slug(s: string): string
	s = s:lower()
	s = s:gsub("%s+", "")
	s = s:gsub("[^%w]+", "")
	return s
end

local IDX: {[string]: AmmoInfo} = {}
local function add(ai: AmmoInfo)
	Catalog[ai.name] = ai
	IDX[slug(ai.name)] = ai
	-- 보조 인덱스: 구경별 기본 레코드
	if not IDX[slug(ai.caliber or "")] then
		IDX[slug(ai.caliber or "")] = ai
	end
end

-- ======== 9x19 ========
add{ name="9x19 M882",  caliber="9x19", pen=18, damage=58, tags={"ball"} }
add{ name="9x19 7N21",  caliber="9x19", pen=33, damage=54, tags={"AP"} }
add{ name="9x19 7N31",  caliber="9x19", pen=39, damage=52, tags={"AP"} }

-- ======== 5.56x45 ========
add{ name="5.56x45 M193",   caliber="5.56x45", pen=28, damage=80, tags={"ball"} }
add{ name="5.56x45 M855",   caliber="5.56x45", pen=30, damage=54, tags={"steel"} }
add{ name="5.56x45 M855A1", caliber="5.56x45", pen=38, damage=49, tags={"AP"} }
add{ name="5.56x45 M995",   caliber="5.56x45", pen=53, damage=40, tags={"AP"} }
add{ name="5.56x45 M993",   caliber="5.56x45", pen=58, damage=37, tags={"AP"} }

-- ======== 5.45x39 ========
add{ name="5.45x39 7N6",  caliber="5.45x39", pen=20, damage=46, tags={"ball"} }
add{ name="5.45x39 7N10", caliber="5.45x39", pen=33, damage=58, tags={"enhanced"} }
add{ name="5.45x39 7N22", caliber="5.45x39", pen=40, damage=52, tags={"AP"} }
add{ name="5.45x39 7N24", caliber="5.45x39", pen=45, damage=44, tags={"AP"} }

-- ======== 7.62x39 ========
add{ name="7.62x39 PS", caliber="7.62x39", pen=32, damage=57, tags={"ball"} }
add{ name="7.62x39 BP", caliber="7.62x39", pen=47, damage=58, tags={"AP"} }
add{ name="7.62x39 BZ", caliber="7.62x39", pen=28, damage=55, tags={"incendiary"} }

-- ======== 7.62x51 (.308) ========
add{ name="7.62x51 M80", caliber="7.62x51", pen=41, damage=80, tags={"ball"} }
add{ name="7.62x51 M61", caliber="7.62x51", pen=68, damage=70, tags={"AP"} }
add{ name="7.62x51 M62", caliber="7.62x51", pen=54, damage=79, tags={"tracer"} }

-- ======== 4.6x30 (MP7) ========
add{ name="4.6x30 DM11", caliber="4.6x30", pen=35, damage=43, tags={"AP"} }
add{ name="4.6x30 DM21", caliber="4.6x30", pen=28, damage=46, tags={"ball"} }
add{ name="4.6x30 DM31", caliber="4.6x30", pen=40, damage=42, tags={"AP"} }
add{ name="4.6x30 DM41", caliber="4.6x30", pen=53, damage=35, tags={"AP"} }

-- ======== 12x70 (12게이지) ========
add{ name="12x70 00 Buckshot",      caliber="12x70", pen=1,  damage=37,  pellets=8, pelletSpread=3.5, tags={"buck"} }
add{ name="12x70 1oz Foster Slug",  caliber="12x70", pen=15, damage=160, tags={"slug"} }
add{ name="12x70 Brenneke Special Forces", caliber="12x70", pen=18, damage=180, tags={"slug"} }
add{ name="12x70 Sabot Steel Penetrator",  caliber="12x70", pen=28, damage=140, tags={"slug","sabot","AP"} }

-- 공개 API
local M = {}

function M.GetAmmoInfo(ammoIdOrName: string?, caliberHint: string?): AmmoInfo?
	if not ammoIdOrName and not caliberHint then return nil end
	if ammoIdOrName then
		local hit = Catalog[ammoIdOrName]
		if hit then return hit end
		hit = IDX[slug(ammoIdOrName)]
		if hit then return hit end
	end
	if caliberHint then
		return IDX[slug(caliberHint)]
	end
	return nil
end

return M
