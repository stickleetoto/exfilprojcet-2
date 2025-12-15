--!strict
-- 서버 영속화: 클라 스냅샷 save/load + 서버가 클라로부터 Pull
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Players = game:GetService("Players")
local DataStoreService  = game:GetService("DataStoreService")

local DS = DataStoreService:GetDataStore("EFR_Inventory_v1")

-- RemoteFunction 타입 보장 유틸
local function ensureRemoteFunction(name: string): RemoteFunction
	local existing = ReplicatedStorage:FindFirstChild(name)
	if existing then
		if not existing:IsA("RemoteFunction") then
			existing:Destroy()
		end
	end
	local rf = ReplicatedStorage:FindFirstChild(name) :: RemoteFunction?
	if not rf then
		rf = Instance.new("RemoteFunction")
		rf.Name = name
		rf.Parent = ReplicatedStorage
	end
	return rf :: RemoteFunction
end

-- 클라 주도 save/load
local RF = ensureRemoteFunction("InventorySnapshot")         -- Client → Server
-- 서버 주도 pull
local PullRF = ensureRemoteFunction("InventorySnapshotPull") -- Server → Client

-- DataStore retry helpers
local function trySet(key: string, value: any): boolean
	for i = 1, 5 do
		local ok, err = pcall(function()
			DS:SetAsync(key, value)
		end)
		if ok then return true end
		warn(("[InventoryStore] Set 실패(%d): %s"):format(i, tostring(err)))
		task.wait(0.5 * i)
	end
	return false
end

local function tryGet(key: string): any
	for i = 1, 5 do
		local ok, res = pcall(function()
			return DS:GetAsync(key)
		end)
		if ok then return res end
		warn(("[InventoryStore] Get 실패(%d): %s"):format(i, tostring(res)))
		task.wait(0.5 * i)
	end
	return nil
end

-- 클라 save/load 엔트리
RF.OnServerInvoke = function(player: Player, action: string, payload: any)
	local key = ("u:%d"):format(player.UserId)
	if action == "save" then
		if typeof(payload) ~= "table" then return false end
		return trySet(key, payload)
	elseif action == "load" then
		return tryGet(key)
	end
	return nil
end

-- 플레이어 퇴장 시: 최신본 Pull 후 저장(가능하면)
Players.PlayerRemoving:Connect(function(plr)
	local key = ("u:%d"):format(plr.UserId)
	local snap: any = nil

	local ok, res = pcall(function()
		return PullRF:InvokeClient(plr) -- 클라 스냅샷 즉시 요청
	end)
	if ok and typeof(res) == "table" then
		snap = res
	end

	if snap then
		trySet(key, snap)
	end
end)

-- 서버 종료 시: 현재 남아있는 전원에게 Pull → 저장
game:BindToClose(function()
	local plist = Players:GetPlayers()
	for _, plr in ipairs(plist) do
		local key = ("u:%d"):format(plr.UserId)
		local snap: any = nil

		local ok, res = pcall(function()
			return PullRF:InvokeClient(plr)
		end)
		if ok and typeof(res) == "table" then
			snap = res
		end
		if snap then
			trySet(key, snap)
		end
	end
end)
