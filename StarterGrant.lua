--!strict
-- 계정당 최초 1회만 지급 트리거
local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local DataStoreService = game:GetService("DataStoreService")

local DS_VERSION = "v2" -- 지급 목록을 바꾸면 v2로 올려서 다시 1회 허용
local store = DataStoreService:GetDataStore("StarterGrant_"..DS_VERSION)

-- RemoteEvent 준비
local RE = ReplicatedStorage:FindFirstChild("StarterGrantEvent")
if not RE then
	RE = Instance.new("RemoteEvent")
	RE.Name = "StarterGrantEvent"
	RE.Parent = ReplicatedStorage
end

local function shouldGrantOnce(userId: number): boolean
	local grant = false
	local ok, err = pcall(function()
		store:UpdateAsync(tostring(userId), function(old)
			if old == nil then
				grant = true
				return { grantedAt = os.time(), version = DS_VERSION }
			else
				return old
			end
		end)
	end)
	if not ok then
		warn("[StarterGrant] DataStore 실패:", err)
		-- 실패시 중복지급 방지 차원에서 grant=false 로 둔다(안전)
	end
	return grant
end

Players.PlayerAdded:Connect(function(plr)
	if shouldGrantOnce(plr.UserId) then
		RE:FireClient(plr) -- 최초 1회만 클라에게 지급 작업 시작 신호
	end
end)
