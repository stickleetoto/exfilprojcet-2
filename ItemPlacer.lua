--!strict
-- ?? ItemPlacer.lua
-- - 저장 스냅샷(Count 포함) 우선 배치
-- - 모델/이미지 소스는 서버 메타(GetStashData)에서 참고
-- - ReplicatedStorage/Models 하위(Ammo/Weapons/Mags) 재귀 검색 + 'Model' 유무 관대 매칭

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local HttpService       = game:GetService("HttpService")

local GetStashData  = ReplicatedStorage:WaitForChild("GetStashData") :: RemoteFunction
local MODELS_FOLDER = ReplicatedStorage:WaitForChild("Models")
local SLOT_SIZE     = 40

local GetOccId   = require(ReplicatedStorage:WaitForChild("Utils"):WaitForChild("GetOccId"))
local StackBadge = require(ReplicatedStorage:WaitForChild("StackBadge"))


-- ▼▼▼ EFR PATCH: WeaponMods / WeaponAttachService (optional) + helpers ▼▼▼
local WeaponMods, WeaponAttachSvc
do
	local ok1, m1 = pcall(function() return require(ReplicatedStorage:WaitForChild("WeaponMods", 0.5)) end)
	local ok2, m2 = pcall(function() return require(ReplicatedStorage:WaitForChild("WeaponAttachService", 0.5)) end)
	if ok1 then WeaponMods = m1 end
	if ok2 then WeaponAttachSvc = m2 end
end

local function _applyModsToViewportFrameIfAny(gui: Instance)
	if not gui then return end
	if not (WeaponMods and WeaponAttachSvc) then return end
	local vps = {}
	if gui:IsA("ViewportFrame") then table.insert(vps, gui) end
	for _, d in ipairs(gui:GetDescendants()) do
		if d:IsA("ViewportFrame") then table.insert(vps, d) end
	end
	if #vps == 0 then return end
	local mods = WeaponMods.Read(gui)
	for _, vp in ipairs(vps) do
		local world = vp:FindFirstChildOfClass("WorldModel")
		local model
		if world then
			model = world:FindFirstChildWhichIsA("Model", true)
		else
			model = vp:FindFirstChildWhichIsA("Model", true)
		end
		if model then
			WeaponAttachSvc.ApplyModsToModel(model, mods)
		else
			local conn; conn = vp.DescendantAdded:Connect(function(d)
				if d:IsA("Model") then
					task.defer(function()
						WeaponAttachSvc.ApplyModsToModel(d, WeaponMods.Read(gui))
					end)
					if conn then conn:Disconnect() end
				end
			end)
		end
	end
end
-- ▲▲▲ EFR PATCH END ▲▲▲
local module = {}
module._lock = false

-- ───────────────────────────────
-- 모델 검색(재귀) + 캐시 + 관대 매칭
-- ───────────────────────────────
local _modelCache: {[string]: Model} = {}

local function _stripModelSuffix(n: string): string
	return (n:gsub("[ _%-]*[Mm][Oo][Dd][Ee][Ll]$",""))
end

local function _normName(n: string): string
	-- 공백 축약 + 대소문자 무시 비교용
	return n:lower():gsub("%s+"," "):gsub("^%s+",""):gsub("%s+$","")
end

local function findModelDeep(modelName: string): Model?
	if not modelName or modelName == "" then return nil end
	-- 캐시 우선
	if _modelCache[modelName] then return _modelCache[modelName] end

	local wanted = modelName
	local wantedBase = _stripModelSuffix(modelName)
	local wantedN = _normName(wanted)
	local wantedBaseN = _normName(wantedBase)

	-- 1) 정확 이름 매칭
	for _, inst in ipairs(MODELS_FOLDER:GetDescendants()) do
		if inst:IsA("Model") and inst.Name == wanted then
			_modelCache[modelName] = inst
			return inst
		end
	end
	-- 2) 'Model' 유무/공백 관대 매칭
	for _, inst in ipairs(MODELS_FOLDER:GetDescendants()) do
		if inst:IsA("Model") then
			local base = _stripModelSuffix(inst.Name)
			if _normName(base) == wantedBaseN or _normName(inst.Name) == wantedN then
				_modelCache[modelName] = inst
				return inst
			end
		end
	end

	warn(("! 모델 없음(Models 하위): %s"):format(modelName))
	return nil
end

-- ───────────────────────────────
-- 중복 배치 방지
-- ───────────────────────────────
local function isAlreadyPlacedById(id: any, parent: Instance)
	if not id or not parent then return false end
	for _, child in ipairs(parent:GetChildren()) do
		if (child:IsA("ImageLabel") or child:IsA("ViewportFrame"))
			and child:GetAttribute("Id") == id then
			return true
		end
	end
	return false
end

-- ───────────────────────────────
-- ViewportFrame 카메라 프레이밍
-- ───────────────────────────────
local function frameCameraToModel(vp: ViewportFrame, model: Model)
	local cf, size = model:GetBoundingBox()
	local maxDim = math.max(size.X, size.Y, size.Z)
	if maxDim <= 0 then
		vp.CurrentCamera = nil
		return
	end
	local viewDir: Vector3 = (-cf.LookVector).Unit
	local fov = 50
	local halfFov = math.rad(fov * 0.5)
	local radius = math.max(size.X, size.Y) * 0.5
	local distance = (radius / math.tan(halfFov)) + (size.Z * 0.6)
	local lookAt = cf.Position
	local eye = lookAt - viewDir * distance

	local cam = vp:FindFirstChildOfClass("Camera") or Instance.new("Camera")
	cam.FieldOfView = fov
	cam.CFrame = CFrame.new(eye, lookAt)
	cam.Parent = vp
	vp.CurrentCamera = cam
end

-- ───────────────────────────────
-- 캔버스 자동 확장
-- ───────────────────────────────
local function growCanvasAsync(sf: ScrollingFrame, gui: GuiObject)
	if not sf or not gui then return end
	task.defer(function()
		if not sf.Parent or not gui.Parent then return end
		local needX = gui.Position.X.Offset + gui.AbsoluteSize.X
		local needY = gui.Position.Y.Offset + gui.AbsoluteSize.Y
		local curX  = sf.CanvasSize.X.Offset
		local curY  = sf.CanvasSize.Y.Offset
		if needX > curX or needY > curY then
			sf.CanvasSize = UDim2.fromOffset(math.max(curX, needX), math.max(curY, needY))
		end
		sf.ScrollingEnabled = true
	end)
end

-- ───────────────────────────────
-- 서버 메타로 GUI 인스턴스 제작
-- ───────────────────────────────
local function createInstanceFromCoreData(itemName: string)
	local base = GetStashData:InvokeServer(itemName)
	if not base then
		warn("! 서버에서 아이템 데이터 없음:", itemName)
		return nil
	end

	local image: Instance
	if base.DisplayType == "model" and base.ModelName then
		local src = findModelDeep(base.ModelName)
		if not src then return nil end

		local vp = Instance.new("ViewportFrame")
		vp.Name = base.Name
		vp.BackgroundTransparency = 1
		vp.ZIndex = 600
		vp.Active = true
		vp:SetAttribute("BaseZ", 600)
		vp.Ambient    = Color3.new(1,1,1)
		vp.LightColor = Color3.new(1,1,1)

		local stroke = Instance.new("UIStroke")
		stroke.Thickness = 1
		stroke.Color = Color3.fromRGB(255,255,255)
		stroke.Parent = vp

		local world = Instance.new("WorldModel")
		world.Name = "VMWorld"
		world.Parent = vp

		local clone = src:Clone()
		clone:PivotTo(CFrame.new())
		clone.Parent = world

		frameCameraToModel(vp, clone)
		image = vp
	else
		local img = Instance.new("ImageLabel")
		img.Name = base.Name
		img.Image = base.Image or ""
		img.BackgroundTransparency = 1
		img.ZIndex = 600
		img.Active = true
		img:SetAttribute("BaseZ", 600)
		img.BorderSizePixel = 1
		img.BorderColor3 = Color3.fromRGB(255,255,255)
		image = img
	end

	-- 기본 태그/메타 복사
	local repTag: string = (base.Tag and tostring(base.Tag)) or "misc"
	local tagsArray: {any} = (typeof(base.Tags) == "table" and base.Tags) or {repTag}
	image:SetAttribute("Tag", repTag)
	image:SetAttribute("TagsJson", HttpService:JSONEncode(tagsArray))

	-- [EFR PATCH] 무기 기본값(장착 여부 플래그)
	do
		local category = tostring(base.Category or ""):lower()
		if category == "primaryweapon" or category == "secondaryweapon" then
			if image:GetAttribute("HasMag") == nil then
				image:SetAttribute("HasMag", false)
			end
		end
	end

	-- [MAG] 탄창 속성 시드
	local category = tostring(base.Category or ""):lower()
	if category == "mag" or string.lower(repTag) == "mag" then
		image:SetAttribute("IsMag", true)
		image:SetAttribute("MagMax", tonumber(base.Capacity) or 30)
		image:SetAttribute("MagCur", 0) -- PlaceSavedItem에서 Count로 덮어씀
		image:SetAttribute("CaliberDisplay", tostring(base.Caliber or ""))
	end

	return image, base
end

-- ───────────────────────────────
-- 공개 API: 저장값 우선 배치(Count 포함)
-- ───────────────────────────────
function module.PlaceSavedItem(itemData: {[string]: any}, slotMapManager: any, scrollingFrame: ScrollingFrame): Instance?
	if module._lock then return nil end
	module._lock = true

	-- 1) 인스턴스 생성
	local image, baseData = createInstanceFromCoreData(itemData.Name)
	if not image then module._lock = false; return nil end

	-- 2) 고유 Id
	local occId = itemData.Id
	if not occId then
		occId = GetOccId(image, itemData)
	end

	-- 3) 중복 방지
	if isAlreadyPlacedById(occId, scrollingFrame) then
		itemData.Id = nil
		occId = GetOccId(image, itemData)
	end

	-- 4) 저장된 크기/좌표 우선
	local savedW  = tonumber(itemData.Width)
	local savedH  = tonumber(itemData.Height)
	local width   = savedW or (tonumber(baseData.Width)  or 1)
	local height  = savedH or (tonumber(baseData.Height) or 1)

	local row = tonumber(itemData.Row)
	local col = tonumber(itemData.Col)

	if image:IsA("GuiObject") then
		image.Size = UDim2.fromOffset(width * SLOT_SIZE, height * SLOT_SIZE)
	end

	-- 5) 자리 확보
	local function canPlaceAt(r, c)
		if not r or not c then return false end
		return slotMapManager:IsAreaFree(r, c, width, height, occId)
	end
	if not canPlaceAt(row, col) then
		if slotMapManager.PurgeId then slotMapManager:PurgeId(occId) end
		local r, c = slotMapManager:FindFirstFreeSlot(width, height, occId)
		if not r then
			image:Destroy()
			module._lock = false
			return nil
		end
		row, col = r, c
	end

	-- 6) 배치
	if image:IsA("GuiObject") then
		image.Position = UDim2.fromOffset((col - 1) * SLOT_SIZE, (row - 1) * SLOT_SIZE)
	end
	image.Parent = scrollingFrame
	slotMapManager:MarkArea(row, col, width, height, occId)

	-- 7) 메타/저장값 반영 + 수량/배지
	local count = tonumber(itemData.Count) or 1

	itemData.Id       = occId
	itemData.Row      = row
	itemData.Col      = col
	itemData.Width    = width
	itemData.Height   = height
	itemData.Tag      = itemData.Tag or (baseData.Tag and tostring(baseData.Tag)) or "misc"
	itemData.Tags     = itemData.Tags or (typeof(baseData.Tags) == "table" and baseData.Tags) or { itemData.Tag }
	itemData.Rotated  = (itemData.Rotated == true)
	itemData.Count    = count

	if image:IsA("GuiObject") then
		image:SetAttribute("Id",       itemData.Id)
		image:SetAttribute("Row",      itemData.Row)
		image:SetAttribute("Col",      itemData.Col)
		image:SetAttribute("Width",    itemData.Width)
		image:SetAttribute("Height",   itemData.Height)
		image:SetAttribute("Rotated",  itemData.Rotated)
		image:SetAttribute("Tag",      itemData.Tag)
		image:SetAttribute("TagsJson", HttpService:JSONEncode(itemData.Tags))
		image:SetAttribute("Count",    count)

		-- [MAG] 저장된 Count를 현재 장탄으로 해석
		if image:GetAttribute("IsMag") == true then
			local max = tonumber(image:GetAttribute("MagMax")) or 0
			image:SetAttribute("MagCur", math.clamp(count, 0, max))
		end

		StackBadge.Attach(image)

		-- [EFR PATCH] 무기 장착 상태(ModsJson/HasMag) 반영 + 뷰포트 모델 갱신
		do
			local category = tostring(baseData.Category or ""):lower()
			local isWeapon = (category == "primaryweapon" or category == "secondaryweapon")
			if isWeapon then
				if typeof(itemData.ModsJson) == "string" and itemData.ModsJson ~= "" then
					image:SetAttribute("ModsJson", itemData.ModsJson)
					local ok, tbl = pcall(function() return HttpService:JSONDecode(itemData.ModsJson) end)
					if ok and typeof(tbl) == "table" and tbl.mag then
						image:SetAttribute("HasMag", true)
						image:SetAttribute("MagModelName", tbl.mag.ModelName or "")
					end
				elseif itemData.HasMag == true then
					image:SetAttribute("HasMag", true)
				else
					if image:GetAttribute("HasMag") == nil then
						image:SetAttribute("HasMag", false)
					end
				end
				_applyModsToViewportFrameIfAny(image)
				image:GetAttributeChangedSignal("ModsJson"):Connect(function()
					_applyModsToViewportFrameIfAny(image)
				end)
				image:GetAttributeChangedSignal("HasMag"):Connect(function()
					_applyModsToViewportFrameIfAny(image)
				end)
			end
		end
	end

	-- 8) 스크롤 캔버스 확장
	if image:IsA("GuiObject") then
		growCanvasAsync(scrollingFrame, image)
	end

	module._lock = false
	return image
end

-- 장비 초기 세팅 등에서 GUI만 생성할 때 사용
function module.CreateGuiFor(itemName: string): (Instance?, {[string]: any}?)
	local ok, image, meta = pcall(function()
		local img, base = createInstanceFromCoreData(itemName)
		return img, base
	end)
	if not ok or not image then
		warn("[ItemPlacer] CreateGuiFor 실패:", itemName)
		return nil, nil
	end

	-- [EFR PATCH] Public Create: 무기일 경우 HasMag 기본값 및 초기 1회 적용
	do
		if image and meta then
			local category = tostring(meta.Category or ""):lower()
			if category == "primaryweapon" or category == "secondaryweapon" then
				if image:GetAttribute("HasMag") == nil then
					image:SetAttribute("HasMag", false)
				end
				_applyModsToViewportFrameIfAny(image)
				image:GetAttributeChangedSignal("ModsJson"):Connect(function()
					_applyModsToViewportFrameIfAny(image)
				end)
				image:GetAttributeChangedSignal("HasMag"):Connect(function()
					_applyModsToViewportFrameIfAny(image)
				end)
			end
		end
	end
	return image, meta
end

return module
