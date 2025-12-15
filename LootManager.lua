--!strict
-- StarterPlayerScripts/LootManager.lua (교체본)
-- + 도어 상호작용 추가: m3 > body > door 조준 시 포인트 표시, F로 문 열고/닫기
-- - 우선순위: mil box > loot item > door
-- - 도어는 서버 RemoteEvent "ToggleDoor"로 처리

local Players            = game:GetService("Players")
local RunService         = game:GetService("RunService")
local CollectionService  = game:GetService("CollectionService")
local UserInputService   = game:GetService("UserInputService")
local ReplicatedStorage  = game:GetService("ReplicatedStorage")

-- RemoteEvent
local RE_FOLDER    = ReplicatedStorage:WaitForChild("RemoteEvents")
local MilBoxToggle = RE_FOLDER:WaitForChild("MilBoxToggle") :: RemoteEvent
local ToggleDoor   = RE_FOLDER:WaitForChild("ToggleDoor")   :: RemoteEvent  -- ★ 추가

-- Modules
local SlotMapRegistry = require(ReplicatedStorage:WaitForChild("SlotMapRegistry"))
local LootHandler     = require(ReplicatedStorage:WaitForChild("LootHandler"))

-- Shortcuts
local player  = Players.LocalPlayer
local camera  = workspace.CurrentCamera

-- State
local stashSlotMap   = SlotMapRegistry.Get("Stash")
local pointUI        : GuiObject? = nil
local inventoryGui   : Instance?  = nil
local scrollingFrame : ScrollingFrame? = nil

local lastTarget     : Model? = nil
local isRequesting   : boolean = false
local lastIsMilBox   : boolean = false

-- ★ 도어 상태 추가
local lastDoorPart   : BasePart? = nil
local lastIsDoor     : boolean = false

local tabHeld        : boolean = false

-- ====== 레이어링(같은 ScreenGui: ZIndex / 다른 ScreenGui: DisplayOrder) ======
local POINT_Z_BEHIND : number = 0
local pointOrigZ     : number? = nil

local pointGui       : ScreenGui? = nil
local pointGuiOrigDO : number? = nil

local invGuiRoot     : ScreenGui? = nil
local invGuiDO       : number = 0

local lootGui        : Instance? = nil
local lootGuiRoot    : ScreenGui? = nil
local lootGuiDO      : number = 0

local DO_GAP_BEHIND  : number = 2

-- ====== 유틸 ======
local function findDescendantByName(root: Instance, name: string): Instance?
	for _, d in ipairs(root:GetDescendants()) do
		if d.Name == name then return d end
	end
	return nil
end

local function findAnyGuiByNames(root: Instance, names: {string}): Instance?
	for _, n in ipairs(names) do
		local hit = findDescendantByName(root, n)
		if hit then return hit end
	end
	return nil
end

local function isScreenGuiEnabled(gui: ScreenGui?): boolean
	if not gui then return false end
	local ok, enabled = pcall(function() return gui.Enabled end)
	return not ok and true or (enabled ~= false)
end

local function anyVisibleUnder(inst: Instance?): boolean
	if not inst then return false end
	if inst:IsA("GuiObject") and inst.Visible then return true end
	for _, d in ipairs(inst:GetDescendants()) do
		if d:IsA("GuiObject") and d.Visible then return true end
	end
	return false
end

-- ★ 도어 탐색: 히트 파트로부터 m3 > body > door를 찾아 반환
local function findDoorFromHit(hitPart: Instance?): BasePart?
	if not hitPart then return nil end
	local bp = hitPart:IsA("BasePart") and hitPart or hitPart:FindFirstAncestorOfClass("BasePart")
	if bp and bp.Name == "door" then return bp end

	local mdl = hitPart:FindFirstAncestorOfClass("Model")
	if not mdl then return nil end
	-- body → door
	local body = mdl:FindFirstChild("body") or findDescendantByName(mdl, "body")
	if not body then return nil end
	local door = body:FindFirstChild("door") or findDescendantByName(body, "door")
	if door and door:IsA("BasePart") then
		return door
	end
	-- 태그 백업: InteractDoor
	if hitPart:IsA("BasePart") and CollectionService:HasTag(hitPart, "InteractDoor") then
		return hitPart
	end
	return nil
end

-- ====== UI 참조 초기화 ======
local function refreshUI()
	local pg = player:FindFirstChild("PlayerGui")
	if not pg then return end

	local screenGui = pg:FindFirstChild("ScreenGui")
	pointUI = screenGui and (screenGui:FindFirstChild("point") :: GuiObject?) or (findDescendantByName(pg, "point") :: GuiObject?)
	inventoryGui = screenGui and screenGui:FindFirstChild("InventoryGui") or findDescendantByName(pg, "InventoryGui")
	scrollingFrame = inventoryGui and (inventoryGui :: Instance):FindFirstChild("ScrollingInventory") :: ScrollingFrame?
	lootGui = (screenGui and (screenGui:FindFirstChild("LootGui") or screenGui:FindFirstChild("MilBoxGui")))
		or findAnyGuiByNames(pg, { "LootGui","MilBoxGui","MilBox","MilboxGui","Milbox" })

	if pointUI then
		if pointOrigZ == nil then pointOrigZ = pointUI.ZIndex end
		pointUI.Visible = false
		pointGui = pointUI:FindFirstAncestorOfClass("ScreenGui")
		if pointGui and pointGuiOrigDO == nil then
			pointGuiOrigDO = pointGui.DisplayOrder
		end
	end

	if inventoryGui then
		invGuiRoot = inventoryGui:FindFirstAncestorOfClass("ScreenGui")
		invGuiDO = (invGuiRoot and invGuiRoot.DisplayOrder) or 0
	end
	if lootGui then
		lootGuiRoot = lootGui:FindFirstAncestorOfClass("ScreenGui")
		lootGuiDO = (lootGuiRoot and lootGuiRoot.DisplayOrder) or 0
	end
end
refreshUI()

local function getActiveOverlayTopDO(): (boolean, number?)
	local invActive = tabHeld and invGuiRoot ~= nil
	local lootActive = false
	if lootGuiRoot then
		lootActive = isScreenGuiEnabled(lootGuiRoot) and anyVisibleUnder(lootGuiRoot)
	elseif lootGui then
		lootActive = anyVisibleUnder(lootGui)
	end
	if not invActive and not lootActive then
		return false, nil
	end
	local topDO = -1e9
	if invActive and invGuiRoot then
		topDO = math.max(topDO, invGuiDO)
	end
	if lootActive then
		if lootGuiRoot then
			topDO = math.max(topDO, lootGuiDO)
		elseif invGuiRoot then
			topDO = math.max(topDO, invGuiDO)
		else
			topDO = math.max(topDO, 0)
		end
	end
	return true, topDO
end

local function applyPointLayering()
	if not pointUI then return end
	local overlayActive, overlayTopDO = getActiveOverlayTopDO()
	pointUI.ZIndex = overlayActive and POINT_Z_BEHIND or (pointOrigZ or pointUI.ZIndex)
	if pointGui then
		if overlayActive and overlayTopDO ~= nil then
			pointGui.DisplayOrder = overlayTopDO - DO_GAP_BEHIND
		else
			if pointGuiOrigDO ~= nil then
				pointGui.DisplayOrder = pointGuiOrigDO
			end
		end
	end
end

player.CharacterAdded:Connect(function()
	task.defer(function()
		task.wait(0.2)
		camera = workspace.CurrentCamera
		refreshUI()
		lastTarget = nil
		lastIsMilBox = false
		isRequesting = false
		stashSlotMap = SlotMapRegistry.Get("Stash") or stashSlotMap

		-- ★ 도어 상태 리셋
		lastDoorPart = nil
		lastIsDoor   = false

		applyPointLayering()
	end)
end)

player:WaitForChild("PlayerGui").ChildAdded:Connect(function()
	task.defer(function()
		refreshUI()
		applyPointLayering()
	end)
end)

UserInputService.InputBegan:Connect(function(input, _)
	if input.KeyCode == Enum.KeyCode.Tab then
		tabHeld = true
		applyPointLayering()
	end
end)

UserInputService.InputEnded:Connect(function(input, _)
	if input.KeyCode == Enum.KeyCode.Tab then
		tabHeld = false
		applyPointLayering()
	end
end)

local function isMilBoxModel(model: Instance?): boolean
	if not model then return false end
	return CollectionService:HasTag(model, "mil box")
		or CollectionService:HasTag(model, "MilBox")
		or CollectionService:HasTag(model, "milbox")
		or CollectionService:HasTag(model, "MIL_BOX")
end

local function hasStrictLootTag(part: Instance?, model: Instance?): boolean
	if part and LootHandler.HasLootTag(part) then return true end
	if model and LootHandler.HasLootTag(model) then return true end
	return false
end

-- ====== 시야 감지 ======
RunService.RenderStepped:Connect(function()
	applyPointLayering()

	if not camera or not player.Character then
		if pointUI then pointUI.Visible = false end
		lastTarget   = nil
		lastIsMilBox = false
		lastDoorPart = nil
		lastIsDoor   = false
		return
	end

	local rayOrigin    = camera.CFrame.Position
	local rayDirection = camera.CFrame.LookVector * 12
	local rayParams    = RaycastParams.new()
	rayParams.FilterDescendantsInstances = { player.Character }
	rayParams.FilterType = Enum.RaycastFilterType.Blacklist

	local result = workspace:Raycast(rayOrigin, rayDirection, rayParams)

	if result and result.Instance then
		local part  = result.Instance
		local model = part:FindFirstAncestorWhichIsA("Model")

		-- 1) mil box 우선
		local isMil      = isMilBoxModel(model)
		local isLootable = hasStrictLootTag(part, model)

		if isMil or isLootable then
			lastTarget   = model
			lastIsMilBox = isMil
			lastDoorPart = nil
			lastIsDoor   = false
			if pointUI then
				pointUI.Visible = true
				applyPointLayering()
			end
			return
		end

		-- 2) 도어 감지 (m3 > body > door)
		local door = findDoorFromHit(part)
		if door then
			lastDoorPart = door
			lastIsDoor   = true
			lastTarget   = nil
			lastIsMilBox = false
			if pointUI then
				pointUI.Visible = true
				applyPointLayering()
			end
			return
		end
	end

	-- 아무것도 아님 → 숨김
	if pointUI then pointUI.Visible = false end
	lastTarget   = nil
	lastIsMilBox = false
	lastDoorPart = nil
	lastIsDoor   = false
end)

-- ====== 상호작용(F) ======
UserInputService.InputBegan:Connect(function(input, processed)
	if processed or isRequesting then return end
	if input.KeyCode ~= Enum.KeyCode.F then return end

	-- mil box / loot 우선 처리
	if lastTarget then
		if lastIsMilBox then
			MilBoxToggle:FireServer(lastTarget)
			if pointUI then pointUI.Visible = false end
			lastTarget   = nil
			lastIsMilBox = false
			return
		end

		if not (stashSlotMap and scrollingFrame) then return end
		isRequesting = true
		LootHandler.CollectItem(lastTarget, stashSlotMap, scrollingFrame, function()
			isRequesting = false
			lastTarget = nil
			if pointUI then pointUI.Visible = false end
		end)
		return
	end

	-- 도어 토글
	if lastIsDoor and lastDoorPart then
		ToggleDoor:FireServer(lastDoorPart)
		if pointUI then pointUI.Visible = false end
		lastDoorPart = nil
		lastIsDoor   = false
	end
end)
