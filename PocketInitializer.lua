-- 포켓 그리드 초기화
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Players = game:GetService("Players")
local SlotMapRegistry = require(ReplicatedStorage:WaitForChild("SlotMapRegistry"))
local SlotMapManager  = require(ReplicatedStorage:WaitForChild("SlotMapManager"))

local SIZE, COLS, ROWS = 40,4,1
local player=Players.LocalPlayer
local gui=player:WaitForChild("PlayerGui"):WaitForChild("ScreenGui")
local frame=gui:WaitForChild("InventoryGui"):WaitForChild("Equipmentingame"):WaitForChild("poket")

frame.Size=UDim2.fromOffset(SIZE*COLS,SIZE*ROWS)
frame.Active=true; frame.ClipsDescendants=true; frame.ZIndex=50

local map=SlotMapManager.new(ROWS,COLS)
SlotMapRegistry.Set("Pocket",map)

for r=1,ROWS do for c=1,COLS do
		local s=Instance.new("Frame")
		s.Size=UDim2.fromOffset(SIZE,SIZE)
		s.Position=UDim2.fromOffset((c-1)*SIZE,(r-1)*SIZE)
		s.BackgroundColor3=Color3.fromRGB(70,70,70)
		s.Active=true; s.ZIndex=51
		s.Parent=frame
		map:RegisterSlotFrame(r,c,s)
	end end
