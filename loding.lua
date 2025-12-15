--!strict
-- ReplicatedFirst/CustomLoadingScreen.client.lua
-- 입장 시 1회만 표시되는 커스텀 로딩 UI + 모든 UI/기능 준비 완료까지 대기 + 완료 신호 발사

-- ===== Services =====
local ReplicatedFirst   = game:GetService("ReplicatedFirst")
local Players           = game:GetService("Players")
local ContentProvider   = game:GetService("ContentProvider")
local CollectionService = game:GetService("CollectionService")
local RunService        = game:GetService("RunService")
local Workspace         = game:GetService("Workspace")
local StarterGui        = game:GetService("StarterGui")
local StarterPack       = game:GetService("StarterPack")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

pcall(function() ReplicatedFirst:RemoveDefaultLoadingScreen() end)

-- ===== 설정 =====
local MIN_SHOW_SEC         = 0.7      -- 최소 표시 시간
local BATCH_SIZE           = 30       -- PreloadAsync 배치 크기
local INCLUDE_DEFAULTS     = true     -- 태그 외 기본 묶음 포함 여부
local BACKGROUND_IMAGE     = "rbxassetid://81816177301870"

-- ? 준비 대기 관련
local WAIT_FOR_CHARACTER   = true
local WAIT_FOR_INVENTORY   = true
local WAIT_FOR_QUICKBAR    = true     -- 퀵바 사용하지 않으면 false
local UI_WAIT_DEADLINE_SEC = 15.0     -- 전체 UI 준비 대기 상한
local QUICKBAR_SOFT_LIMIT  = 6.0      -- 퀵바는 이 시간까지만 우선 기다리고, 안 뜨면 나머지 준비가 끝났는지 보며 추가로 기다림
local EXTRA_SETTLE_SEC     = 0.15     -- 레이아웃 settle용 짧은 대기

-- ===== 이벤트 보장 =====
local function ensureLoadingReadyEvent(): BindableEvent
	local evt = ReplicatedStorage:FindFirstChild("LoadingReady")
	if not evt or not evt:IsA("BindableEvent") then
		if evt then evt:Destroy() end
		evt = Instance.new("BindableEvent")
		evt.Name = "LoadingReady"
		evt.Parent = ReplicatedStorage
	end
	return evt
end

local function ensurePlayerReadyRE()
	local Remotes = ReplicatedStorage:FindFirstChild("Remotes")
	if not Remotes then
		Remotes = Instance.new("Folder"); Remotes.Name = "Remotes"; Remotes.Parent = ReplicatedStorage
	end
	local re = Remotes:FindFirstChild("PlayerLoadingReady")
	if not re then
		local ev = Instance.new("RemoteEvent"); ev.Name = "PlayerLoadingReady"; ev.Parent = Remotes
		re = ev
	end
	return re :: RemoteEvent
end

-- ===== 수집: PreloadCritical 태그 + 기본 묶음(선택) =====
local function gatherList(): {Instance}
	local list: {Instance} = {}

	for _, inst in ipairs(CollectionService:GetTagged("PreloadCritical")) do
		table.insert(list, inst)
		for _, d in ipairs(inst:GetDescendants()) do
			table.insert(list, d)
		end
	end

	if INCLUDE_DEFAULTS then
		table.insert(list, ReplicatedStorage)
		table.insert(list, StarterGui)
		table.insert(list, StarterPack)
		table.insert(list, Workspace)
	end

	local seen: {[Instance]: boolean} = {}
	local out: {Instance} = {}
	for _, v in ipairs(list) do
		if not seen[v] then
			seen[v] = true
			table.insert(out, v)
		end
	end
	return out
end

-- ===== 전역 배경 생성/보장 =====
local function ensureBackgroundGui(playerGui: PlayerGui): ImageLabel
	local bgGui = playerGui:FindFirstChild("GlobalBackgroundGui") :: ScreenGui?
	if not bgGui then
		bgGui = Instance.new("ScreenGui")
		bgGui.Name = "GlobalBackgroundGui"
		bgGui.IgnoreGuiInset = true
		bgGui.ResetOnSpawn = false
		bgGui.ZIndexBehavior = Enum.ZIndexBehavior.Sibling
		bgGui.DisplayOrder = -1000
		bgGui.Parent = playerGui
	end

	local old = bgGui:FindFirstChild("GlobalBackground")
	if old then old:Destroy() end

	local background = Instance.new("ImageLabel")
	background.Name = "GlobalBackground"
	background.Size = UDim2.new(1, 0, 1, 0)
	background.Position = UDim2.new(0, 0, 0, 0)
	background.Image = BACKGROUND_IMAGE
	background.BackgroundTransparency = 1
	background.ImageTransparency = 0
	background.ScaleType = Enum.ScaleType.Crop
	background.ZIndex = 0
	background.Active = false
	background.Parent = bgGui

	return background
end

-- ===== 로딩 UI 만들기 =====
local function createGui(playerGui: PlayerGui): ScreenGui
	local gui = Instance.new("ScreenGui")
	gui.Name = "LoadingScreen"
	gui.IgnoreGuiInset = true
	gui.ResetOnSpawn = false
	gui.ZIndexBehavior = Enum.ZIndexBehavior.Global
	gui.DisplayOrder = 1_000_000
	gui.Parent = playerGui

	local bg = Instance.new("Frame")
	bg.Name = "Background"
	bg.Size = UDim2.new(1, 0, 1, 0)
	bg.BackgroundColor3 = Color3.new(0, 0, 0)
	bg.BackgroundTransparency = 0
	bg.ZIndex = 1_000_000
	bg.Parent = gui

	local text = Instance.new("TextLabel")
	text.Name = "LoadingText"
	text.Size = UDim2.new(1, 0, 0, 72)
	text.Position = UDim2.new(0, 0, 0.5, -36)
	text.BackgroundTransparency = 1
	text.Text = "Loading..."
	text.TextColor3 = Color3.fromRGB(255,255,255)
	text.TextStrokeTransparency = 0
	text.TextScaled = true
	text.Font = Enum.Font.GothamBold
	text.ZIndex = 1_000_001
	text.Parent = gui

	local counter = Instance.new("TextLabel")
	counter.Name = "Counter"
	counter.AnchorPoint = Vector2.new(1, 1)
	counter.Position = UDim2.new(1, -20, 1, -20)
	counter.Size = UDim2.new(0, 220, 0, 36)
	counter.BackgroundTransparency = 1
	counter.Text = "0 / 0"
	counter.TextColor3 = Color3.fromRGB(200,200,200)
	counter.TextScaled = true
	counter.Font = Enum.Font.Gotham
	counter.TextXAlignment = Enum.TextXAlignment.Right
	counter.ZIndex = 1_000_001
	counter.Parent = gui

	local blocker = Instance.new("TextButton")
	blocker.Name = "Blocker"
	blocker.Size = UDim2.new(1, 0, 1, 0)
	blocker.BackgroundTransparency = 1
	blocker.TextTransparency = 1
	blocker.AutoButtonColor = false
	blocker.Selectable = true
	blocker.Active = true
	blocker.Modal = true
	blocker.ZIndex = 1_000_002
	blocker.Parent = gui

	return gui
end

-- ===== 페이드 =====
local function setAlpha(gui: ScreenGui, a: number)
	a = math.clamp(a, 0, 1)
	if not gui or not gui.Parent then return end
	local bg      = gui:FindFirstChild("Background") :: Frame?
	local text    = gui:FindFirstChild("LoadingText") :: TextLabel?
	local counter = gui:FindFirstChild("Counter") :: TextLabel?
	if bg then bg.BackgroundTransparency = a end
	if text then text.TextTransparency = a; text.TextStrokeTransparency = a end
	if counter then counter.TextTransparency = a end
end

-- ====== 준비 대기 유틸 ======
local function stepWait()
	RunService.RenderStepped:Wait()
end

local function waitUntil(pred: ()->(boolean), timeout: number): boolean
	local deadline = os.clock() + timeout
	while os.clock() < deadline do
		if pred() then return true end
		stepWait()
	end
	return pred() -- 마지막 한 번 더 시도
end

local function setStage(gui: ScreenGui, msg: string)
	local text = gui:FindFirstChild("LoadingText") :: TextLabel?
	if text and text.Parent then
		text.Text = msg
	end
end

-- Inventory/QuickBar 준비 검사
local function collectUIRefs(playerGui: PlayerGui)
	local refs = {}

	local screenGui = playerGui:FindFirstChild("ScreenGui")
	local invGui = (screenGui and screenGui:FindFirstChild("InventoryGui")) or playerGui:FindFirstChild("InventoryGui")
	refs.invGui = invGui

	if invGui then
		refs.equip  = invGui:FindFirstChild("EquipmentFrame")
		refs.ingame = invGui:FindFirstChild("Equipmentingame")
		refs.stash  = invGui:FindFirstChild("ScrollingInventory")
		refs.xb     = invGui:FindFirstChild("XB", true)
	end

	local qb = playerGui:FindFirstChild("QuickBarUi")
	if qb then
		local bar = qb:FindFirstChild("Bar")
		refs.qbBar = bar
		if bar then
			refs.btnInv  = bar:FindFirstChild("BtnInventory")
			refs.btnHide = bar:FindFirstChild("BtnHideout")
			refs.btnShop = bar:FindFirstChild("BtnShop")
		end
	end
	return refs
end

local function isInventoryReady(refs): boolean
	if not refs.invGui then return false end
	if not refs.equip or not refs.ingame then return false end
	-- stash는 있으면 좋고, 없으면 패스
	return true
end

local function isQuickBarReady(refs): boolean
	if not refs.qbBar then return false end
	return (refs.btnInv and refs.btnHide and refs.btnShop) ~= nil
end

-- ===== 실행 =====
local function run()
	local player = Players.LocalPlayer
	local playerGui = player:WaitForChild("PlayerGui")

	-- 전역 배경 보장
	local _background = ensureBackgroundGui(playerGui)
	RunService.RenderStepped:Wait()

	local gui = createGui(playerGui)
	local counter = gui:WaitForChild("Counter") :: TextLabel

	-- 1) 자산 프리로드
	setStage(gui, "Loading assets…")
	local list = gatherList()
	local total = #list
	local loaded = 0
	counter.Text = string.format("%d / %d", loaded, total)

	local startT = os.clock()

	if total > 0 then
		for i = 1, total, BATCH_SIZE do
			local batchCount = math.min(BATCH_SIZE, total - i + 1)
			local batch = table.create(batchCount)
			for k = 1, batchCount do
				batch[k] = list[i + k - 1]
			end
			pcall(function() ContentProvider:PreloadAsync(batch) end)
			loaded = math.min(loaded + batchCount, total)
			if counter and counter.Parent then
				counter.Text = string.format("%d / %d", loaded, total)
			end
			stepWait()
		end
	end

	-- 2) 엔진 로드 보정
	setStage(gui, "Finishing engine setup…")
	if not game:IsLoaded() then
		waitUntil(function() return game:IsLoaded() end, 2.0)
	end

	-- 3) 필수 런타임 준비 (캐릭터/휴머노이드)
	if WAIT_FOR_CHARACTER then
		setStage(gui, "Spawning character…")
		waitUntil(function()
			local ch = player.Character
			return ch and ch:FindFirstChildOfClass("Humanoid") ~= nil
		end, 8.0)
	end

	-- 4) UI 준비 (Inventory / QuickBar)
	local t0 = os.clock()
	local qbSoftDeadline = t0 + QUICKBAR_SOFT_LIMIT
	local hardDeadline = t0 + UI_WAIT_DEADLINE_SEC

	while os.clock() < hardDeadline do
		local refs = collectUIRefs(playerGui)

		local invOK = (not WAIT_FOR_INVENTORY) or isInventoryReady(refs)
		local qbOK  = (not WAIT_FOR_QUICKBAR) or isQuickBarReady(refs) or (os.clock() >= qbSoftDeadline)

		if not invOK then
			setStage(gui, "Preparing inventory UI…")
		elseif not qbOK and WAIT_FOR_QUICKBAR then
			setStage(gui, "Preparing quick bar…")
		end

		if invOK and qbOK then
			break
		end
		stepWait()
	end

	-- 5) 레이아웃 settle
	task.wait(EXTRA_SETTLE_SEC)

	-- 6) 최소 노출 시간 충족
	local remain = MIN_SHOW_SEC - (os.clock() - startT)
	if remain > 0 then task.wait(remain) end

	-- 7) 페이드아웃
	for step = 1, 10 do
		setAlpha(gui, step/10)
		task.wait(0.03)
	end

	-- 8) 완료 브로드캐스트 (서버/클라)
	local readyEvt = ensureLoadingReadyEvent()
	ReplicatedStorage:SetAttribute("LoadingReady", true)
	readyEvt:Fire()

	local readyRE = ensurePlayerReadyRE()
	pcall(function()
		readyRE:FireServer({ ts = os.clock(), client="ready" })
	end)

	if gui and gui.Parent then gui:Destroy() end
end

run()
