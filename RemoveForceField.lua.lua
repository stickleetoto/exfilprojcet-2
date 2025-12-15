-- ?? ServerScriptService.RemoveForceField

local Players = game:GetService("Players")

Players.PlayerAdded:Connect(function(player)
	player.CharacterAdded:Connect(function(character)
		-- 캐릭터에 ForceField가 생기면 자동으로 제거
		local shield = character:FindFirstChildOfClass("ForceField")
		if shield then
			shield:Destroy()
			print("??? ForceField 제거 완료:", player.Name)
		end
	end)
end)
