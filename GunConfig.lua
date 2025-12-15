--!strict
-- ReplicatedStorage/GunConfig.lua
-- 기본 스펙 + "장전 탄창/탄" 기준 동적 스펙 해석(300 BLK 제거판)

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local MagService = require(ReplicatedStorage:WaitForChild("MagService"))

export type RecoilSpec = {
	pitchUp:number, returnTime:number, randomYaw:number, randomRoll:number, viewKickScale:number,
}
export type GunSpec = {
	name:string, caliber:string, defaultAmmoId:string, magSize:number,
	modes:{string}, rpm:{[string]:number}, burstCount:number?, pellets:number?, pelletSpread:number?,
	recoil:RecoilSpec, reloadSec:number?,
}

local function spec(t:GunSpec) return t end

local M = {}

-- 기본값: MCX는 5.56x45로 통일
M.DB = {
	m4a1 = spec({
		name="M4A1", caliber="556x45", defaultAmmoId="M855A1", magSize=60,
		modes={"semi","auto"},
		rpm={ semi=650, auto=800 },
		recoil={ pitchUp=2.6, returnTime=0.11, randomYaw=0.6, randomRoll=0.4, viewKickScale=1.0 },
		reloadSec=2.2,
	}),
	ak74 = spec({
		name="AK-74", caliber="545x39", defaultAmmoId="7N10", magSize=30,
		modes={"semi","auto"},
		rpm={ semi=600, auto=650 },
		recoil={ pitchUp=3.2, returnTime=0.12, randomYaw=0.7, randomRoll=0.5, viewKickScale=1.05 },
		reloadSec=2.4,
	}),
	ak74m = spec({
		name="AK-74M", caliber="545x39", defaultAmmoId="7N10", magSize=30,
		modes={"semi","auto"},
		rpm={ semi=600, auto=650 },
		recoil={ pitchUp=3.1, returnTime=0.12, randomYaw=0.7, randomRoll=0.45, viewKickScale=1.05 },
		reloadSec=2.4,
	}),
	mcx = spec({
		name="MCX", caliber="556x45", defaultAmmoId="M855A1", magSize=60,
		modes={"semi","burst3","auto"}, burstCount=3,
		rpm={ semi=700, burst3=900, auto=850 },
		recoil={ pitchUp=2.8, returnTime=0.10, randomYaw=0.7, randomRoll=0.5, viewKickScale=1.0 },
		reloadSec=2.1,
	}),
	mp7a1 = spec({
		name="MP7A1", caliber="4.6x30", defaultAmmoId="DM31", magSize=40,
		modes={"semi","auto"},
		rpm={ semi=700, auto=950 },
		recoil={ pitchUp=1.4, returnTime=0.09, randomYaw=0.4, randomRoll=0.3, viewKickScale=0.8 },
		reloadSec=1.9,
	}),
	aa12 = spec({
		name="AA-12", caliber="12x70", defaultAmmoId="00 Buckshot", magSize=8,
		modes={"semi","auto"}, pellets=8, pelletSpread=3.0,
		rpm={ semi=300, auto=300 },
		recoil={ pitchUp=5.0, returnTime=0.16, randomYaw=1.2, randomRoll=0.8, viewKickScale=1.2 },
		reloadSec=2.8,
	}),
	g17 = spec({
		name="G17", caliber="9x19", defaultAmmoId="M882", magSize=17,
		modes={"semi"},
		rpm={ semi=450 },
		recoil={ pitchUp=3.0, returnTime=0.10, randomYaw=0.6, randomRoll=0.3, viewKickScale=0.9 },
		reloadSec=1.7,
	}),
}

function M.Get(weaponKey:string):GunSpec? return M.DB[weaponKey] end

local function normCal(s:string?): string
	s = (s or ""):lower():gsub("%s+",""):gsub("%.","")
	if s == "55645" then return "556x45" end
	if s == "54539" then return "545x39" end
	if s == "76239" then return "762x39" end
	return s
end

local function cloneSpec(s:GunSpec): GunSpec
	return {
		name=s.name, caliber=s.caliber, defaultAmmoId=s.defaultAmmoId, magSize=s.magSize,
		modes=table.clone(s.modes), rpm=table.clone(s.rpm),
		burstCount=s.burstCount, pellets=s.pellets, pelletSpread=s.pelletSpread,
		recoil={
			pitchUp=s.recoil.pitchUp, returnTime=s.recoil.returnTime,
			randomYaw=s.recoil.randomYaw, randomRoll=s.recoil.randomRoll, viewKickScale=s.recoil.viewKickScale,
		},
		reloadSec=s.reloadSec,
	}
end

export type ResolveOpts = {
	weaponGui: Instance?, -- 선택
	magGui: Instance?,    -- 장전된 탄창
	ammoGui: Instance?,   -- 바로 로딩할 탄(선택)
	ammoCalOverride: string?, -- 강제 구경(선택)
}

function M.ResolveSpec(weaponKey:string, opts:ResolveOpts?): GunSpec
	local base = M.DB[weaponKey]
	if not base then error(("Unknown weaponKey: %s"):format(tostring(weaponKey))) end
	opts = opts or {}
	local out = cloneSpec(base)

	local effCal = ""

	-- 1) 우선순위: override > (mag의 로딩 칼리버) > (mag의 기계호환 단일값) > 기본
	if opts.ammoCalOverride and #opts.ammoCalOverride > 0 then
		effCal = normCal(opts.ammoCalOverride)
	end

	if effCal == "" and opts.magGui then
		effCal = normCal(MagService.GetLoadedCal(opts.magGui))
		if effCal == "" then
			local set = MagService.GetCompatCals(opts.magGui)
			local count, only = 0, ""
			for k, v in pairs(set) do if v then count += 1; only = k end end
			if count == 1 then effCal = only end
		end
	end

	if effCal == "" then effCal = normCal(base.caliber) end
	out.caliber = effCal

	-- 2) 장탄수(탄창 기준 우선)
	if opts.magGui then
		local cap = opts.magGui:GetAttribute("MagCap") or opts.magGui:GetAttribute("MagMax")
		if typeof(cap) == "number" and cap > 0 then
			out.magSize = cap
		end
	end

	return out
end

return M
