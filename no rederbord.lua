--!strict
-- StarterPlayerScripts/DisablePlayerList.client.lua
-- TAB을 눌러도 기본 리더보드(PlayerList)가 절대 뜨지 않도록 비활성화

local Players     = game:GetService("Players")
local StarterGui  = game:GetService("StarterGui")
local RunService  = game:GetService("RunService")
local CAS         = game:GetService("ContextActionService")

local function disablePlayerList()
	-- CoreGui PlayerList 비활성화 (실패해도 pcall로 안전)
	pcall(function()
		StarterGui:SetCoreGuiEnabled(Enum.CoreGuiType.PlayerList, false)
	end)
end

-- 최초 적용
disablePlayerList()

-- 리스폰 시에도 재적용(드물게 CoreScript가 다시 켜는 경우 대비)
Players.LocalPlayer.CharacterAdded:Connect(function()
	task.defer(disablePlayerList)
	task.delay(0.5, disablePlayerList)
end)

-- 혹시 다른 스크립트가 주기적으로 다시 켜면 꾸준히 꺼주기(저비용)
task.spawn(function()
	while true do
		task.wait(2.0)
		disablePlayerList()
	end
end)

-- (선택) 정말 드물게 Tab 토글이 남아있다면 아래 주석 해제해서 입력 자체를 싱크 처리
-- 이건 CoreScript보다 높은 우선순위로 Tab을 "먹어버림".
-- 주의: 너의 TAB 단축키를 CAS로 쓰는 스크립트가 있다면 충돌할 수 있음.
--[[
CAS:BindActionAtPriority("SinkPlayerlistTab", function(_, state)
	if state == Enum.UserInputState.Begin then
		return Enum.ContextActionResult.Sink
	end
	return Enum.ContextActionResult.Pass
end, false, Enum.ContextActionPriority.High.Value, Enum.KeyCode.Tab)
]]
