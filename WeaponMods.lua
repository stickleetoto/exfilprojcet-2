--!strict
-- ReplicatedStorage/WeaponMods.lua
-- 기존 기능: 무기 GUI에 모딩(탄창 등) 상태를 ModsJson으로 저장/로드
-- 추가 기능: 무기별 RPM/반동/사격모드/칼리버/ADS 애니 제공 API

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local HttpService       = game:GetService("HttpService")

local M = {}

-- =========================
-- 기존: ModsJson read/write
-- =========================
local function _read(gui: Instance): {[string]: any}
	if not gui then return {} end
	local j = gui:GetAttribute("ModsJson")
	if typeof(j) == "string" and j ~= "" then
		local ok, t = pcall(function() return HttpService:JSONDecode(j) end)
		if ok and typeof(t) == "table" then return t end
	end
	return {}
end

local function _write(gui: Instance, mods: {[string]: any})
	gui:SetAttribute("ModsJson", HttpService:JSONEncode(mods))
end

local function _getStr(gui: Instance, keys: {string}, fallback: string?): string?
	for _, k in ipairs(keys) do
		local v = gui:GetAttribute(k)
		if typeof(v) == "string" and v ~= "" then return v end
	end
	return fallback
end

-- ?? 장착: 무기 GUI에 장착 상태 기록(HasMag/ModsJson/MagModelName)
function M.WriteMagFromGui(weaponGui: Instance, magGui: Instance): {[string]: any}
	local mods = _read(weaponGui)
	mods.mag = {
		ItemName  = _getStr(magGui, {"ItemName","Name"}, magGui.Name),
		ModelName = _getStr(magGui, {"ModelName","ItemModelName"}, magGui.Name),
		Caliber   = _getStr(magGui, {"Caliber","CaliberDisplay"}, nil),
		Capacity  = tonumber(magGui:GetAttribute("Capacity")) or tonumber(magGui:GetAttribute("MagMax")) or nil,
	}
	_write(weaponGui, mods)

	weaponGui:SetAttribute("HasMag", true)
	weaponGui:SetAttribute("MagModelName", mods.mag.ModelName or "")

	local dirty = ReplicatedStorage:FindFirstChild("InventoryDirty")
	if dirty and dirty:IsA("BindableEvent") then dirty:Fire() end

	return mods
end

-- ?? 탈착(Eject): 상태 비우기
function M.ClearMag(weaponGui: Instance)
	local mods = _read(weaponGui)
	mods.mag = nil
	_write(weaponGui, mods)
	weaponGui:SetAttribute("HasMag", false)
	weaponGui:SetAttribute("MagModelName", "")
	local dirty = ReplicatedStorage:FindFirstChild("InventoryDirty")
	if dirty and dirty:IsA("BindableEvent") then dirty:Fire() end
end

function M.HasMag(weaponGui: Instance): boolean
	return weaponGui and weaponGui:GetAttribute("HasMag") == true
end

function M.Read(weaponGui: Instance): {[string]: any}
	return _read(weaponGui)
end

-- =========================
-- 추가: 무기 스펙(타르코프 풍)
-- =========================
local DB: {[string]: {caliber:string, rpm:number, recoilV:number, recoilH:number, modes:{string}, adsId:number?}} = {
	ak47   = { caliber="7.62x39", rpm=600, recoilV=5.5, recoilH=1.2, modes={"semi","auto"} },
	hk416  = { caliber="5.56x45", rpm=750, recoilV=4.4, recoilH=0.9, modes={"semi","auto"} },
	mcx    = { caliber="300 blk", rpm=800, recoilV=4.8, recoilH=1.0, modes={"semi","auto"} },
	g17    = { caliber="9x19",    rpm=450, recoilV=3.0, recoilH=0.6, modes={"semi"} },
	mk12   = { caliber="5.56x45", rpm=700, recoilV=3.9, recoilH=0.8, modes={"semi"} }, -- DMR
	gunmin20ak47 = { caliber="7.62x39", rpm=600, recoilV=5.2, recoilH=1.1, modes={"semi","auto"} },
	SuperSoaker50 = { caliber="7.62x39", rpm=600, recoilV=5.2, recoilH=1.1, modes={"semi","auto"} },
}

local function norm(id:string?): string?
	if not id then return nil end
	id = id:lower()
	id = id:gsub("%s+","")
	return id
end

function M.GetRPM(id:string): number
	local r = DB[norm(id)]
	return r and r.rpm or 600
end

function M.GetRecoil(id:string): (number, number)
	local r = DB[norm(id)]
	return (r and r.recoilV or 5), (r and r.recoilH or 1)
end

function M.GetFireModes(id:string): {string}
	local r = DB[norm(id)]
	return (r and r.modes) or {"semi","auto","burst"}
end

function M.GetCaliber(id:string): string
	local r = DB[norm(id)]
	return (r and r.caliber) or "5.56x45"
end

-- 옵션: ADS 애니메이션 에셋ID (없으면 0/미사용)
function M.GetADSAnimId(id:string): number
	local r = DB[norm(id)]
	return (r and r.adsId) or 0
end

return M
