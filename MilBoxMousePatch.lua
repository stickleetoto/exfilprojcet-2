--!strict
-- mil box 열림/닫힘에 맞춰 마우스 상태만 바꾸는 비침투형 패치
-- - Hide.lua, GlobalUIController.lua 수정 없이 작동
-- - 열림: _G.setMouseGov("unlock") / 닫힘: _G.setMouseGov("lock")
-- - 전역 훅이 없으면 동일 동작을 직접 수행(폴백)

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local UserInputService  = game:GetService("UserInputService")

local RE_FOLDER  = ReplicatedStorage:WaitForChild("RemoteEvents")
local MilBoxLoot = RE_FOLDER:WaitForChild("MilBoxLoot") :: RemoteEvent

local function mouseGov(mode: "lock" | "unlock")
	if _G and type(_G.setMouseGov) == "function" then
		_G.setMouseGov(mode)
	else
		-- 폴백: 전역 훅이 아직 없다면 동일 효과 직접 적용
		if mode == "lock" then
			UserInputService.MouseBehavior = Enum.MouseBehavior.LockCenter
			UserInputService.MouseIconEnabled = false
		else
			UserInputService.MouseBehavior = Enum.MouseBehavior.Default
			UserInputService.MouseIconEnabled = true
		end
	end
end

MilBoxLoot.OnClientEvent:Connect(function(kind: string, _model: Model?)
	if kind == "open" then
		mouseGov("unlock")
	elseif kind == "close" then
		mouseGov("lock")
	end
end)
