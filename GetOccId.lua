-- ReplicatedStorage/Utils/GetOccId.lua
local HttpService = game:GetService("HttpService")
return function(image: Instance?, itemData: table?): string
	local id = (itemData and itemData.Id) or (image and image:GetAttribute("Id"))
	if type(id) ~= "string" or #id == 0 then
		id = HttpService:GenerateGUID(false)
		if image then image:SetAttribute("Id", id) end
		if itemData then itemData.Id = id end
	end
	return id
end
