--!strict
-- ?? ServerScriptService/StatsService.lua
-- EFT 스타일: 레벨/XP 분리, 사용 기반 성장, 과적 페널티, 원격 XP(옵션), 서버틱 XP(옵션)

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local DataStoreService = game:GetService("DataStoreService")
local RunService = game:GetService("RunService")

-- ===== 옵션 =====
local ENABLE_REMOTE_XP = true   -- 클라가 Stats_AddXP로 보고하는 XP를 받음
local ENABLE_TICK_XP   = true   -- 서버 틱 기반(이동/과적) XP 지급

-- Remote XP 레이트 리밋(초당 허용량)
local REMOTE_XP_BUDGET_PER_SEC = 600

-- ===== DataStore =====
local DATASTORE_NAME = "EFR_Stats_v2"
local store = DataStoreService:GetDataStore(DATASTORE_NAME)
local AUTOSAVE_SEC = 60
local DS_RETRY = 5

type SaveState = { dirty: boolean, lastSave: number }
local saveStates: {[number]: SaveState} = {}

-- ===== StatDefs =====
local function requireStatDefs()
	local ok, mod
	local shared = ReplicatedStorage:FindFirstChild("Shared")
	if shared then
		local cand = shared:FindFirstChild("StatDefs")
		if cand and cand:IsA("ModuleScript") then
			ok, mod = pcall(require, cand)
			if ok and type(mod) == "table" then return mod end
		end
	end
	local direct = ReplicatedStorage:FindFirstChild("StatDefs")
	if direct and direct:IsA("ModuleScript") then
		ok, mod = pcall(require, direct)
		if ok and type(mod) == "table" then return mod end
	end
	error("[StatsService] StatDefs module not found")
end

local Shared = requireStatDefs()
local StatDefs = Shared.StatDefs
local Derived  = Shared.Derived
local Overweight = Shared.Overweight

-- ===== 유틸 =====
local function clampLevel(name: string, v: number)
	local d = StatDefs[name]; if not d then return v end
	return math.clamp(math.floor(v), d.min, d.max)
end
local function clampXP(_name: string, v: number)
	return math.max(0, math.floor(v))
end
local function setAttr(plr: Player, name: string, v: number)
	plr:SetAttribute(name, v)
end
local function getAttrN(plr: Player, name: string, default: number): number
	local v = plr:GetAttribute(name)
	if typeof(v) == "number" then return v end
	return default
end

-- ===== 파생 재계산 =====
local function recomputeDerived(plr: Player)
	local E = getAttrN(plr, "Endurance", StatDefs.Endurance.base)
	local S = getAttrN(plr, "Strength",  StatDefs.Strength.base)

	setAttr(plr, "MaxStamina",      Derived.MaxStamina(E))
	setAttr(plr, "SprintDrainMult", Derived.SprintDrainMult(E))
	setAttr(plr, "StaminaRegen",    Derived.StaminaRegen(E))

	setAttr(plr, "CarryCap",        Derived.CarryCap(S))
	setAttr(plr, "MeleeMult",       Derived.MeleeMult(S))
	setAttr(plr, "JumpPowerBonus",  Derived.JumpPowerBonus(S))
	setAttr(plr, "MoveSpeedMult",   Derived.MoveSpeedMult(S))
end

local function markDirty(plr: Player)
	saveStates[plr.UserId] = saveStates[plr.UserId] or {dirty = false, lastSave = 0}
	saveStates[plr.UserId].dirty = true
end

-- ===== 레벨/XP IO =====
local function makeKey(plr: Player): string return ("uid_%d"):format(plr.UserId) end

local function readWithRetry(key: string)
	for i = 1, DS_RETRY do
		local ok, data = pcall(function() return store:GetAsync(key) end)
		if ok then return data end
		task.wait(0.3 * i)
	end
	return nil
end

local function writeWithRetry(key: string, payload: any): boolean
	for i = 1, DS_RETRY do
		local ok = pcall(function() store:SetAsync(key, payload) end)
		if ok then return true end
		task.wait(0.3 * i)
	end
	return false
end

local function loadStats(plr: Player)
	local key = makeKey(plr)
	local data = readWithRetry(key)

	local eLvl = StatDefs.Endurance.base
	local sLvl = StatDefs.Strength.base
	local eXP  = 0
	local sXP  = 0

	if typeof(data) == "table" then
		if typeof(data.Endurance) == "number" then eLvl = clampLevel("Endurance", data.Endurance) end
		if typeof(data.Strength)  == "number" then sLvl = clampLevel("Strength",  data.Strength)  end
		if typeof(data.XPEndurance) == "number" then eXP = clampXP("Endurance", data.XPEndurance) end
		if typeof(data.XPStrength)  == "number" then sXP = clampXP("Strength",  data.XPStrength)  end
	end

	setAttr(plr, "Endurance", eLvl)
	setAttr(plr, "Strength",  sLvl)
	setAttr(plr, "XPEndurance", eXP)
	setAttr(plr, "XPStrength",  sXP)

	recomputeDerived(plr)
	saveStates[plr.UserId] = {dirty = false, lastSave = os.clock()}
end

local function snapshot(plr: Player)
	return {
		Endurance   = clampLevel("Endurance", getAttrN(plr, "Endurance",   StatDefs.Endurance.base)),
		Strength    = clampLevel("Strength",  getAttrN(plr, "Strength",    StatDefs.Strength.base)),
		XPEndurance = clampXP("Endurance",    getAttrN(plr, "XPEndurance", 0)),
		XPStrength  = clampXP("Strength",     getAttrN(plr, "XPStrength",  0)),
		updatedAt   = os.time(),
	}
end

local function saveIfDirty(plr: Player)
	local state = saveStates[plr.UserId]
	if not state or not state.dirty then return true end
	local ok = writeWithRetry(makeKey(plr), snapshot(plr))
	if ok then
		state.dirty = false
		state.lastSave = os.clock()
	end
	return ok
end

-- ===== XP 커브: 레벨↑ → 필요 XP↑ (안전 폴백 포함) =====
local function xpToNext(statName: string, level: number): number
	local def = StatDefs[statName]
	level = math.max(1, math.floor(level))
	if def then
		-- 1) 명시 함수 우선
		if type(def.xpPerLevel) == "function" then
			local ok, v = pcall(def.xpPerLevel, level)
			if ok and typeof(v) == "number" then
				return math.max(1, math.floor(v))
			end
		end
		-- 2) xpBase/xpGrowth 폴백
		if typeof(def.xpBase) == "number" and typeof(def.xpGrowth) == "number" then
			return math.max(1, math.floor(def.xpBase * (def.xpGrowth ^ (level - 1))))
		end
	end
	-- 3) 최종 폴백(절대 터지지 않도록)
	return math.max(1, math.floor(100 * (1.15 ^ (level - 1))))
end

-- ===== XP/레벨 갱신 =====
local function gainXP(plr: Player, statName: "Endurance"|"Strength", delta: number)
	if delta <= 0 then return end
	local lvAttr = statName
	local xpAttr = "XP"..statName

	local level = clampLevel(statName, getAttrN(plr, lvAttr, StatDefs[statName].base))
	local xp    = clampXP(statName, getAttrN(plr, xpAttr, 0))

	if level >= StatDefs[statName].max then return end

	xp += math.floor(delta)
	local leveled = false
	while level < StatDefs[statName].max do
		local need = xpToNext(statName, level)
		if xp >= need then
			xp -= need
			level += 1
			leveled = true
		else
			break
		end
	end

	setAttr(plr, lvAttr, level)
	setAttr(plr, xpAttr, xp)
	if leveled then
		recomputeDerived(plr)
	end
	markDirty(plr)
end

-- ===== 공개 API =====
local StatsService = {}

function StatsService.InitPlayer(plr: Player)
	loadStats(plr)

	-- 캐릭터 스폰 시 점프 보정 적용
	plr.CharacterAdded:Connect(function(char)
		local hum = char:WaitForChild("Humanoid", 5)
		if hum and hum.UseJumpPower then
			local jpBase = 50 -- 안전 기본값(필요시 바꾸기)
			local bonus  = getAttrN(plr, "JumpPowerBonus", 0)
			hum.JumpPower = jpBase + bonus
		end
	end)

	-- 디버그 로그(선택)
	plr.AttributeChanged:Connect(function(attr)
		if attr == "Endurance" or attr == "Strength" or attr == "XPEndurance" or attr == "XPStrength" then
			-- print(("[StatsService] %s %s = %s"):format(plr.Name, attr, tostring(plr:GetAttribute(attr))))
		end
	end)
end

function StatsService.SetLevel(plr: Player, name: "Endurance"|"Strength", value: number)
	if not StatDefs[name] then return end
	setAttr(plr, name, clampLevel(name, value))
	recomputeDerived(plr)
	markDirty(plr)
end

function StatsService.AddXP(plr: Player, name: "Endurance"|"Strength", delta: number)
	if not StatDefs[name] then return end
	gainXP(plr, name, delta)
end

-- ===== 클라 보고 XP(옵션) =====
if ENABLE_REMOTE_XP then
	local StatsAddXP = ReplicatedStorage:FindFirstChild("Stats_AddXP")
	if not StatsAddXP then
		local ev = Instance.new("RemoteEvent")
		ev.Name = "Stats_AddXP"
		ev.Parent = ReplicatedStorage
		StatsAddXP = ev
	end

	-- 간단한 초당 예산 레이트리밋
	local xpBudget: {[number]: {t: number, used: number}} = {}
	(StatsAddXP :: RemoteEvent).OnServerEvent:Connect(function(plr, statName, amount)
		if typeof(statName) ~= "string" or typeof(amount) ~= "number" then return end
		if statName ~= "Endurance" and statName ~= "Strength" then return end
		amount = math.clamp(math.floor(amount), 0, 10000)
		if amount <= 0 then return end

		local now = os.clock()
		local b = xpBudget[plr.UserId]
		if not b or now - b.t >= 1 then
			b = {t = now, used = 0}
			xpBudget[plr.UserId] = b
		end
		local left = math.max(0, REMOTE_XP_BUDGET_PER_SEC - b.used)
		if left <= 0 then return end
		local grant = math.min(left, amount)
		b.used += grant

		gainXP(plr, statName :: any, grant)
	end)
end

-- ===== 서버 틱 기반 XP(옵션) =====
local TICK = 0.5
if ENABLE_TICK_XP then
	task.spawn(function()
		while true do
			task.wait(TICK)
			for _, plr in ipairs(Players:GetPlayers()) do
				local char = plr.Character
				local hum = char and char:FindFirstChildOfClass("Humanoid") :: Humanoid?
				if not hum then continue end

				-- 이동/질주 판정(간단)
				local moving = hum.MoveDirection.Magnitude > 0.05
				local sprinting = moving and (hum.WalkSpeed > 17) -- 기본 16 초과

				-- 무게/과적 계산
				local carryCap = getAttrN(plr, "CarryCap", Derived.CarryCap(getAttrN(plr,"Strength",StatDefs.Strength.base)))
				local curW = getAttrN(plr, "CurrentWeight", 0)
				local owStart = carryCap * Overweight.ThresholdMult
				local owHard  = carryCap * Overweight.HardcapMult
				local overFrac = 0
				if curW > owStart then
					overFrac = math.clamp((curW - owStart) / math.max(1, owHard - owStart), 0, 1)
				end
				setAttr(plr, "OverweightRatio", overFrac)

				-- 이동/소모 보정 값을 Attribute로 노출(클라 HUD/로직용)
				local moveMult = 1
				local drainMult = getAttrN(plr, "SprintDrainMult", 1)
				if overFrac > 0 then
					moveMult = moveMult * (1 - (1 - Overweight.MovePenaltyAtMax) * overFrac)
					drainMult = drainMult * (1 + (Overweight.DrainPenaltyAtMax - 1) * overFrac)
				end
				setAttr(plr, "MoveOverMult", moveMult)
				setAttr(plr, "StaminaDrainOverMult", drainMult)

				-- === XP 지급 ===
				if moving then
					local base = sprinting and 2.0 or 0.75
					gainXP(plr, "Endurance", math.floor(base * (TICK*10)))
				end
				if overFrac > 0 then
					local strGain = 1.5 + 4.5 * overFrac
					gainXP(plr, "Strength", math.floor(strGain * (TICK*10)))
				end
			end
		end
	end)
end

-- 점프 시 Strength/Endurance 소량 증가
Players.PlayerAdded:Connect(function(plr)
	plr.CharacterAdded:Connect(function(char)
		local hum = char:WaitForChild("Humanoid")
		hum.Jumping:Connect(function(active)
			if active then
				gainXP(plr, "Strength", 8)
				gainXP(plr, "Endurance", 4)
			end
		end)
	end)
end)

-- ===== 오토세이브 & 라이프사이클 =====
task.spawn(function()
	while true do
		task.wait(AUTOSAVE_SEC)
		for _, plr in ipairs(Players:GetPlayers()) do
			saveIfDirty(plr)
		end
	end
end)

Players.PlayerAdded:Connect(function(plr)
	saveStates[plr.UserId] = {dirty=false, lastSave=0}
	StatsService.InitPlayer(plr)
end)

Players.PlayerRemoving:Connect(function(plr)
	saveIfDirty(plr)
	saveStates[plr.UserId] = nil
end)

game:BindToClose(function()
	for _, plr in ipairs(Players:GetPlayers()) do
		saveIfDirty(plr)
	end
	task.wait(1.0)
end)

return StatsService
