--!strict
-- 채팅 명령어로 특정 부위 체력 깎기 (관리자 전용)
-- 사용법: /damage <playerName> <partName> <amount>

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local BodyHealth = require(ReplicatedStorage:WaitForChild("Shared"):WaitForChild("BodyHealth"))

-- ? 관리자 계정(UserId 입력)
local ADMIN_IDS = {
	[5688250920] = true, -- 여기에 너의 UserId를 넣어줘
}

local function findPlayerByName(name: string): Player?
	for _, plr in ipairs(Players:GetPlayers()) do
		if string.lower(plr.Name) == string.lower(name) then
			return plr
		end
	end
	return nil
end

Players.PlayerAdded:Connect(function(plr)
	plr.Chatted:Connect(function(msg)
		-- 권한 체크
		if not ADMIN_IDS[plr.UserId] then
			return
		end

		local args = string.split(msg, " ")
		if #args >= 4 and string.lower(args[1]) == "/damage" then
			local targetName = args[2]
			local partName   = args[3]
			local dmg = tonumber(args[4])

			if not dmg then return end
			local target = findPlayerByName(targetName)
			if target and target.Character then
				BodyHealth.DamageRegion(target.Character, partName, dmg)
				print(string.format("▶ %s의 %s에 %d 데미지 적용", target.Name, partName, dmg))
			end
		end
	end)
end)
