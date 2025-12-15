--!strict
-- Server bootstrap: bind all players and expose simple demo API

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local BodyHealth = require(Shared:WaitForChild("BodyHealth"))

-- Bind everyone (existing + future)
Players.PlayerAdded:Connect(function(plr)
	BodyHealth.BindPlayer(plr)
end)
for _, plr in ipairs(Players:GetPlayers()) do
	BodyHealth.BindPlayer(plr)
end

-- === (선택) 예시: 총알/레이캐스트 시스템에서 호출하는 RemoteEvent ===
-- ReplicatedStorage/Remotes/DamageHumanoid (RemoteEvent)
-- :FireServer(targetCharacter, hitInstance, damage)
local Remotes = ReplicatedStorage:FindFirstChild("Remotes")
if Remotes and Remotes:FindFirstChild("DamageHumanoid") then
	local evt: RemoteEvent = Remotes:FindFirstChild("DamageHumanoid") :: any
	evt.OnServerEvent:Connect(function(attacker, targetChar: Model, hit: Instance, dmg: number)
		if typeof(dmg) ~= "number" or dmg <= 0 then return end
		if not targetChar or not targetChar:IsA("Model") then return end
		BodyHealth.DamageByHitInstance(targetChar, hit, dmg)
	end)
end

-- === (선택) 디버그 커맨드: 채팅으로 /hit thorax 20 ===
local function tryParse(cmd: string)
	local region, amt = string.match(cmd, "^/hit%s+(%w+)%s+(%d+)$")
	if region and amt then
		return string.gsub(region, "^%l", string.upper), tonumber(amt)
	end
	return nil, nil
end

Players.PlayerAdded:Connect(function(plr)
	plr.Chatted:Connect(function(msg)
		local region, amt = tryParse(msg:lower())
		if region and amt then
			local char = plr.Character
			if char then
				BodyHealth.DamageRegion(char, region, amt)
			end
		end
	end)
end)
