local ReplicatedStorage = game:GetService("ReplicatedStorage")
local CollectionService = game:GetService("CollectionService")

local LootRemove = ReplicatedStorage:WaitForChild("LootRemove")

LootRemove.OnServerEvent:Connect(function(player, model)
	if not model or not model:IsDescendantOf(workspace) then return end
	if not model:IsA("Model") then return end

	-- 중복 획득 방지: 태그 제거
	CollectionService:RemoveTag(model, "loot")
	CollectionService:RemoveTag(model, "g17")
	CollectionService:RemoveTag(model, "MCX")
	CollectionService:RemoveTag(model, "m4a1")

	-- 서버에서 모델 제거
	model:Destroy()
end)
