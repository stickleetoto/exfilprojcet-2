-- ?? DisableDefaultInventory.lua
local StarterGui = game:GetService("StarterGui")




-- ? 체력 표시 UI 비활성화
StarterGui:SetCoreGuiEnabled(Enum.CoreGuiType.Health, false)

-- (선택) 이모트 휠도 막고 싶다면
StarterGui:SetCoreGuiEnabled(Enum.CoreGuiType.EmotesMenu, false)

