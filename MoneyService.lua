--!strict
-- ServerStorage/Services/MoneyService.lua
local DataStoreService = game:GetService("DataStoreService")
local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local MoneyService = {}
MoneyService.__index = MoneyService

-- ====== 튜닝 파라미터 ======
local DATASTORE_NAME              = "EFR_Money_v1"
local START_CASH                  = 0

-- 접속 중 초당 지급
local CASH_PER_SEC                = 100       -- 접속해 있는 동안 초당 100원
local JOIN_BONUS_CASH             = 1000 -- 접속 즉시 1회 보너스 (원). 필요 없으면 0 유지

-- 오프라인(접속 끊긴 동안) 축적
local OFFLINE_RATE_PER_MIN        = 3
local OFFLINE_ACCUM_CAP_MIN       = 36 * 60  -- 최대 12시간치까지만 지급

-- 저장 재시도
local DS_RETRY                    = 5

-- ====== 내부 상태 ======
local store = DataStoreService:GetDataStore(DATASTORE_NAME)

export type PlayerState = {
	lastSeen: number,     -- unix time (초)
	cash: number,
	_tickAcc: number,     -- 초당 정산 누적(초)
}

local stateByUserId: {[number]: PlayerState} = {}
local balanceChangedEvent: BindableEvent -- ServerStorage/Signals/BalanceChanged

-- ====== 유틸 ======
local function now(): number
	return os.time()
end

local function clamp(n: number, minN: number, maxN: number): number
	return math.max(minN, math.min(maxN, n))
end

local function getBalanceChangedEvent(): BindableEvent
	if balanceChangedEvent then return balanceChangedEvent end
	local signalsFolder = game.ServerStorage:FindFirstChild("Signals") or Instance.new("Folder")
	signalsFolder.Name = "Signals"
	signalsFolder.Parent = game.ServerStorage

	local ev = signalsFolder:FindFirstChild("BalanceChanged") :: BindableEvent?
	if not ev then
		ev = Instance.new("BindableEvent")
		ev.Name = "BalanceChanged"
		ev.Parent = signalsFolder
	end
	balanceChangedEvent = ev
	return balanceChangedEvent
end

local function deepCopy<T>(t: T): T
	local nt: {[any]: any} = {}
	for k, v in pairs(t :: any) do
		nt[k] = v
	end
	return nt :: any
end

local function fireClientUpdate(plr: Player, newBalance: number)
	local r = ReplicatedStorage:FindFirstChild("Remotes")
	if r and r:FindFirstChild("Money") and (r.Money :: Instance):FindFirstChild("Update") then
		(r.Money.Update :: RemoteEvent):FireClient(plr, newBalance)
	end
end

-- ====== 저장/로드 ======
local function loadUser(userId: number): PlayerState
	local initial: PlayerState = {
		lastSeen = now(),
		cash = START_CASH,
		_tickAcc = 0,
	}

	local ok, result
	for i=1, DS_RETRY do
		ok, result = pcall(function()
			return store:GetAsync("u_"..userId)
		end)
		if ok then break end
		if i == DS_RETRY then warn("[MoneyService] GetAsync failed:", result) end
	end

	if ok and result then
		initial.cash = tonumber(result.cash) or START_CASH
		initial.lastSeen = tonumber(result.lastSeen) or now()
	end
	return initial
end

local function saveUser(userId: number, st: PlayerState)
	local copy = { cash = st.cash, lastSeen = st.lastSeen }
	local ok, err
	for i=1, DS_RETRY do
		ok, err = pcall(function()
			store:UpdateAsync("u_"..userId, function(_old)
				return deepCopy(copy)
			end)
		end)
		if ok then break end
		if i == DS_RETRY then warn("[MoneyService] UpdateAsync failed:", err) end
	end
end

-- ====== 공개 API ======
function MoneyService.Init() end

function MoneyService.PlayerAdded(plr: Player)
	local uid = plr.UserId
	local st = loadUser(uid)

	-- 오프라인 수익 계산
	local dtMin = math.floor(clamp((now() - st.lastSeen)/60, 0, OFFLINE_ACCUM_CAP_MIN))
	if dtMin > 0 then
		local gain = dtMin * OFFLINE_RATE_PER_MIN
		st.cash += gain
	end

	st.lastSeen = now()
	stateByUserId[uid] = st

	-- leaderstats(선택)
	local ls = Instance.new("Folder")
	ls.Name = "leaderstats"
	ls.Parent = plr

	local cashVal = Instance.new("IntValue")
	cashVal.Name = "Cash"
	cashVal.Value = st.cash
	cashVal.Parent = ls

	-- 초기 동기화 (UI 용도)
	fireClientUpdate(plr, st.cash)

	-- (선택) 접속 즉시 1회 보너스
	if JOIN_BONUS_CASH > 0 then
		MoneyService.Add(plr, JOIN_BONUS_CASH, "join")
	end
end

function MoneyService.PlayerRemoving(plr: Player)
	local uid = plr.UserId
	local st = stateByUserId[uid]
	if not st then return end
	st.lastSeen = now()
	saveUser(uid, st)
	stateByUserId[uid] = nil
end

function MoneyService.GetBalance(plr: Player): number
	local st = stateByUserId[plr.UserId]
	return st and st.cash or 0
end

function MoneyService.Add(plr: Player, amount: number, reason: string?): boolean
	if amount <= 0 then return false end
	local uid = plr.UserId
	local st = stateByUserId[uid]; if not st then return false end

	st.cash += math.floor(amount)

	local lsCash = plr:FindFirstChild("leaderstats") and plr.leaderstats:FindFirstChild("Cash")
	if lsCash then (lsCash :: IntValue).Value = st.cash end

	getBalanceChangedEvent():Fire(plr, st.cash, amount, reason or "add")
	fireClientUpdate(plr, st.cash)
	return true
end

function MoneyService.Spend(plr: Player, amount: number, reason: string?): boolean
	if amount <= 0 then return false end
	local uid = plr.UserId
	local st = stateByUserId[uid]; if not st then return false end

	if st.cash < amount then return false end
	st.cash -= math.floor(amount)

	local lsCash = plr:FindFirstChild("leaderstats") and plr.leaderstats:FindFirstChild("Cash")
	if lsCash then (lsCash :: IntValue).Value = st.cash end

	getBalanceChangedEvent():Fire(plr, st.cash, -amount, reason or "spend")
	fireClientUpdate(plr, st.cash)
	return true
end

-- 서버 틱에서 호출 (부트스트랩)
function MoneyService.ServerTick(deltaSec: number)
	for _, plr in ipairs(Players:GetPlayers()) do
		local st = stateByUserId[plr.UserId]
		if not st then continue end

		-- 접속해 있는 동안 초당 1원 지급
		st._tickAcc += deltaSec
		if st._tickAcc >= 1 then
			local seconds = math.floor(st._tickAcc)
			st._tickAcc -= seconds
			local gain = seconds * CASH_PER_SEC
			if gain > 0 then
				MoneyService.Add(plr, gain, "online")
			end
		end
	end
end

-- 주기 저장 (부트스트랩에서 호출)
function MoneyService.PeriodicSave()
	for _, plr in ipairs(Players:GetPlayers()) do
		local st = stateByUserId[plr.UserId]
		if st then
			st.lastSeen = now()
			saveUser(plr.UserId, st)
		end
	end
end

return MoneyService