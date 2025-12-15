-- 스태시 그리드 초기화
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local SlotMapRegistry = require(ReplicatedStorage:WaitForChild("SlotMapRegistry"))
local SIZE,COLS,ROWS=40,10,30
local Players=game:GetService("Players")
local player=Players.LocalPlayer
local gui=player:WaitForChild("PlayerGui"):WaitForChild("ScreenGui")
local scroll=gui:WaitForChild("InventoryGui"):WaitForChild("ScrollingInventory")
scroll.CanvasSize=UDim2.fromOffset(COLS*SIZE,ROWS*SIZE)

local map=SlotMapRegistry.Get("Stash")
for r=1,ROWS do for c=1,COLS do
		local s=Instance.new("Frame")
		s.Size=UDim2.fromOffset(SIZE,SIZE)
		s.Position=UDim2.fromOffset((c-1)*SIZE,(r-1)*SIZE)
		s.BackgroundColor3=Color3.fromRGB(60,60,60)
		s.Parent=scroll
		map:RegisterSlotFrame(r,c,s)
	end end
