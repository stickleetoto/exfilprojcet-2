--!strict
-- ServerScriptService/MoneyBootstrap.server.lua
local RunService = game:GetService("RunService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Players = game:GetService("Players")

-- 폴더/리모트 준비
local remotes = ReplicatedStorage:FindFirstChild("Remotes") or Instance.new("Folder", ReplicatedStorage)
remotes.Name = "Remotes"
local moneyFolder = remotes:FindFirstChild("Money") or Instance.new("Folder", remotes)
moneyFolder.Name = "Money"
local updateRemote = moneyFolder:FindFirstChild("Update") or Instance.new("RemoteEvent", moneyFolder)
updateRemote.Name = "Update"

-- 서비스 로드
local MoneyService = require(game.ServerStorage.Services.MoneyService)
MoneyService.Init()

-- 플레이어 라이프사이클
Players.PlayerAdded:Connect(function(plr)
	MoneyService.PlayerAdded(plr)
end)

Players.PlayerRemoving:Connect(function(plr)
	MoneyService.PlayerRemoving(plr)
end)

-- 서버 틱: AFK/분당 정산
local acc = 0
RunService.Heartbeat:Connect(function(dt)
	MoneyService.ServerTick(dt)
	acc += dt
	-- 60초마다 안전 저장
	if acc >= 60 then
		acc = 0
		MoneyService.PeriodicSave()
	end
end)

-- 다른 서버 스크립트에서 연동하기 쉽게 전역 테이블로 노출(선택)
_G.EFR_Money = {
	Get = function(plr) return MoneyService.GetBalance(plr) end,
	Add = function(plr, amt, why) return MoneyService.Add(plr, amt, why) end,
	Spend = function(plr, amt, why) return MoneyService.Spend(plr, amt, why) end,
}
