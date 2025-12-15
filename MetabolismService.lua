--!strict
local Players           = game:GetService("Players")
local RunService        = game:GetService("RunService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local ServerScriptService = game:GetService("ServerScriptService")

local Defs = require(ReplicatedStorage:WaitForChild("Shared"):WaitForChild("MetabolismDefs"))

-- 지연 로드 핸들(처음엔 비어 있고, 나중에 모듈이 생기면 require 시도)
local ConstOk, Const = false, nil :: any
local PlayerStateSvcOk, PlayerStateSvc = false, nil :: any

local function tryBindStateModules()
	if not PlayerStateSvcOk then
		local mod = ServerScriptService:FindFirstChild("PlayerStateService")
		if mod and mod:IsA("ModuleScript") then
			local ok, svc = pcall(require, mod)
			if ok and svc then PlayerStateSvcOk, PlayerStateSvc = true, svc end
		end
	end
	if PlayerStateSvcOk and not ConstOk then
		local folder = ReplicatedStorage:FindFirstChild("Shared")
		local ok, c = pcall(function()
			return folder and folder:FindFirstChild("Const") and require(folder.Const) or nil
		end)
		if ok and c then ConstOk, Const = true, c end
	end
end

local function now(): number return os.clock() end
local function clamp(x: number, lo: number, hi: number): number
	if x < lo then return lo elseif x > hi then return hi end; return x
end

-- 상태머신 준비 전에는 드레인하지 않는다(로비/하이드에서 깎임 방지)
local function isDraining(p: Player): boolean
	tryBindStateModules()
	if PlayerStateSvcOk and ConstOk then
		local s = PlayerStateSvc.GetState(p)
		return s == Const.PlayerState.RaidWarmup or s == Const.PlayerState.RaidLive
	end
	return false
end

-- 속성 보장 + 기본값
local function ensureAttrs(p: Player)
	if p:GetAttribute("Energy") == nil then p:SetAttribute("Energy", Defs.MaxEnergy) end
	if p:GetAttribute("Hydration") == nil then p:SetAttribute("Hydration", Defs.MaxHydration) end
	if p:GetAttribute("Meta_MoveMult") == nil then p:SetAttribute("Meta_MoveMult", 1.0) end
	if p:GetAttribute("Meta_StaminaRegenMult") == nil then p:SetAttribute("Meta_StaminaRegenMult", 1.0) end
	if p:GetAttribute("WellFedUntil") == nil then p:SetAttribute("WellFedUntil", 0) end
	if p:GetAttribute("WellHydratedUntil") == nil then p:SetAttribute("WellHydratedUntil", 0) end
end

-- 불필요한 복제를 줄이기 위한 set-if-changed
local function setAttrIfChanged(p: Player, name: string, newVal: number, eps: number?)
	local cur = p:GetAttribute(name)
	if typeof(cur) ~= "number" or math.abs((cur :: number) - newVal) > (eps or 1e-3) then
		p:SetAttribute(name, newVal)
	end
end

-- 외부에서 호출: 음식 적용 (ConsumeService에서 사용)
local Svc = {}

function Svc.ApplyFood(p: Player, energyGain: number?, hydraGain: number?)
	ensureAttrs(p)
	local e = (p:GetAttribute("Energy") :: number) or 0
	local h = (p:GetAttribute("Hydration") :: number) or 0
	e = clamp(e + (energyGain or 0), 0, Defs.MaxEnergy)
	h = clamp(h + (hydraGain or 0), 0, Defs.MaxHydration)
	setAttrIfChanged(p, "Energy", e)
	setAttrIfChanged(p, "Hydration", h)

	-- 버프 연장(겹치면 더 먼 시각으로)
	if (energyGain or 0) > 0 then
		local untilE = math.max(p:GetAttribute("WellFedUntil") or 0, now()) + Defs.WellFedDurationSec
		setAttrIfChanged(p, "WellFedUntil", untilE)
	end
	if (hydraGain or 0) > 0 then
		local untilH = math.max(p:GetAttribute("WellHydratedUntil") or 0, now()) + Defs.WellHydratedDurationSec
		setAttrIfChanged(p, "WellHydratedUntil", untilH)
	end
end

-- 주기 처리
local accum = 0
RunService.Heartbeat:Connect(function(dt)
	accum += dt
	if accum < 1.0 then return end
	local step = accum; accum = 0

	-- 모듈이 나중에 생겨도 주기적으로 바인딩 시도
	tryBindStateModules()

	for _, p in ipairs(Players:GetPlayers()) do
		ensureAttrs(p)
		if not isDraining(p) then
			-- 레이드 중이 아니면 패널티만 초기화(한 번만)
			setAttrIfChanged(p, "Meta_MoveMult", 1.0)
			setAttrIfChanged(p, "Meta_StaminaRegenMult", 1.0)
			continue
		end

		local e = (p:GetAttribute("Energy") :: number) or 0
		local h = (p:GetAttribute("Hydration") :: number) or 0

		-- 버프에 따른 드레인 배수
		local emul, hmul = 1.0, 1.0
		if (p:GetAttribute("WellFedUntil") or 0) > now() then emul *= Defs.WellFedDrainMul end
		if (p:GetAttribute("WellHydratedUntil") or 0) > now() then hmul *= Defs.WellHydratedDrainMul end

		-- 분당 → 초당 → step 적용
		local eDrain = (Defs.BaseEnergyDrainPerMin/60) * step * emul
		local hDrain = (Defs.BaseHydrationDrainPerMin/60) * step * hmul

		e = clamp(e - eDrain, 0, Defs.MaxEnergy)
		h = clamp(h - hDrain, 0, Defs.MaxHydration)
		setAttrIfChanged(p, "Energy", e)
		setAttrIfChanged(p, "Hydration", h)

		-- 패널티 계산
		local moveMul, stamMul = 1.0, 1.0
		if e <= Defs.EnergyCrit then
			moveMul *= Defs.Penalties.EnergyCrit.MoveMult
			stamMul *= Defs.Penalties.EnergyCrit.StaminaRegenMult
		elseif e <= Defs.EnergyLow then
			moveMul *= Defs.Penalties.EnergyLow.MoveMult
			stamMul *= Defs.Penalties.EnergyLow.StaminaRegenMult
		end
		if h <= Defs.HydraCrit then
			moveMul *= Defs.Penalties.HydraCrit.MoveMult
			stamMul *= Defs.Penalties.HydraCrit.StaminaRegenMult
		elseif h <= Defs.HydraLow then
			moveMul *= Defs.Penalties.HydraLow.MoveMult
			stamMul *= Defs.Penalties.HydraLow.StaminaRegenMult
		end

		setAttrIfChanged(p, "Meta_MoveMult", moveMul)
		setAttrIfChanged(p, "Meta_StaminaRegenMult", stamMul)

		-- (선택) 서버 훅
		local g = (_G :: any)
		if typeof(g.EFR_ON_METABOLIC_UPDATE) == "function" then
			pcall(function() g.EFR_ON_METABOLIC_UPDATE(p, e, h, moveMul, stamMul) end)
		end
	end
end)

-- 초기화
Players.PlayerAdded:Connect(ensureAttrs)

return Svc
