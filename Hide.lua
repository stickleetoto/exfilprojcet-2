--!strict
-- TAB 누르면 "어떤 상황이든" 즉시 마우스 자유 + 하이드 1인칭 강제 가드
-- (교체본) RunService 루프 없이 동작, backtohide 클릭 시 모든 탭 우선 닫기

local Players = game:GetService("Players")
local UIS = game:GetService("UserInputService")
local CAS = game:GetService("ContextActionService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Workspace = game:GetService("Workspace")

local player = Players.LocalPlayer
local camera = Workspace.CurrentCamera
local pg = player:WaitForChild("PlayerGui")

-- ===== 설정 =====
local FREE_BURST_SEC = 1.0 -- 하이드 밖 TAB 시 마우스 자유 유지 시간

-- Remotes(선택)
local HideRemotes = ReplicatedStorage:FindFirstChild("HideoutRemotes")
local RequestEnter: RemoteEvent? = HideRemotes and HideRemotes:FindFirstChild("RequestEnter") :: RemoteEvent
local RequestExit : RemoteEvent?  = HideRemotes and HideRemotes:FindFirstChild("RequestExit")  :: RemoteEvent
local StateChanged: RemoteEvent?  = HideRemotes and HideRemotes:FindFirstChild("StateChanged") :: RemoteEvent

-- 루팅(선택)
local RE_FOLDER = ReplicatedStorage:FindFirstChild("RemoteEvents")
local MilBoxLoot: RemoteEvent? = RE_FOLDER and RE_FOLDER:FindFirstChild("MilBoxLoot") :: RemoteEvent

_G.DialogueActive = _G.DialogueActive or false

local function _toggleVitalsHUD(on: boolean)
	local ok, f = pcall(function() return (_G :: any).HUDVitals_Toggle end)
	if ok and typeof(f) == "function" then f(on); return end
	local pg2 = game:GetService("Players").LocalPlayer:WaitForChild("PlayerGui")
	local equip = pg2:FindFirstChild("InventoryGui", true)
	if equip then
		local ef = equip:FindFirstChild("EquipmentFrame", true)
		local stats = ef and ef:FindFirstChild("StatsRoot")
		if stats and stats:IsA("GuiObject") then stats.Visible = on end
	end
end

-- ===== 상태 =====
local S = {
	isInHideout = false,
	invOpen = false,              -- 풀 인벤
	equipOverlayOpen = false,     -- TAB 오버레이
	milBoxOpen = false,

	_prevCamMode = nil :: Enum.CameraMode?,

	-- 인벤 패널
	inventoryGui = nil :: Instance?,
	equipFrame   = nil :: Frame?,
	equipIngame  = nil :: Frame?,
	stashFrame   = nil :: ScrollingFrame?,
	xbButton     = nil :: GuiObject?,
	shopGui      = nil :: GuiObject?,

	-- 퀵바
	root    = nil :: ScreenGui?,
	bar     = nil :: Frame?,
	btnHide = nil :: TextButton?,
	btnInv  = nil :: TextButton?,
	btnShop = nil :: TextButton?,
	btnBackToHide = nil :: TextButton?,

	-- mapui
	mapui          = nil :: Instance?,
	mapHideout     = nil :: GuiObject?,
	mapBackToHide  = nil :: GuiObject?,
	mapBackToRobby = nil :: GuiObject?,

	-- Guards
	mouseGuardConns = {} :: {RBXScriptConnection},
	mouseDesiredBehavior = nil :: Enum.MouseBehavior?,
	mouseDesiredIconOn = nil :: boolean?,
	fpConns = {} :: {RBXScriptConnection},
	fpWatchdogToken = 0,
}

-- ===== 유틸 =====
local function addConn(list: {RBXScriptConnection}, c: RBXScriptConnection?)
	if c then table.insert(list, c) end
end
local function clearConns(list: {RBXScriptConnection})
	for _,c in ipairs(list) do pcall(function() c:Disconnect() end) end
	table.clear(list)
end

local function setQuickBarVisible(on: boolean)
	if S.root and S.root:IsA("ScreenGui") then (S.root :: ScreenGui).Enabled = on end
	if S.bar  then S.bar.Visible = on end
end

local function bindActionSafe(name: string, handler, priorityOrKeys, ...)
	CAS:UnbindAction(name)
	if typeof(CAS.BindActionAtPriority) == "function" and typeof(priorityOrKeys) == "number" then
		return CAS:BindActionAtPriority(name, handler, false, priorityOrKeys, ...)
	end
	if typeof(priorityOrKeys) == "EnumItem" then
		return CAS:BindAction(name, handler, false, priorityOrKeys, ...)
	elseif typeof(priorityOrKeys) == "table" then
		return CAS:BindAction(name, handler, false, table.unpack(priorityOrKeys))
	else
		return CAS:BindAction(name, handler, false, ...)
	end
end

-- ===== MouseGuard (이벤트 기반) =====
local function mouseApplyOnce()
	if _G.DialogueActive then
		if UIS.MouseBehavior ~= Enum.MouseBehavior.Default then UIS.MouseBehavior = Enum.MouseBehavior.Default end
		if not UIS.MouseIconEnabled then UIS.MouseIconEnabled = true end
		return
	end
	if S.mouseDesiredBehavior and UIS.MouseBehavior ~= S.mouseDesiredBehavior then
		UIS.MouseBehavior = S.mouseDesiredBehavior
	end
	if S.mouseDesiredIconOn ~= nil and UIS.MouseIconEnabled ~= S.mouseDesiredIconOn then
		UIS.MouseIconEnabled = S.mouseDesiredIconOn
	end
end
local function MouseGuard_Start(mode: "unlock"|"lock")
	S.mouseDesiredBehavior = (mode == "unlock") and Enum.MouseBehavior.Default or Enum.MouseBehavior.LockCenter
	S.mouseDesiredIconOn   = (mode == "unlock")
	mouseApplyOnce()
	clearConns(S.mouseGuardConns)
	addConn(S.mouseGuardConns, UIS:GetPropertyChangedSignal("MouseBehavior"):Connect(mouseApplyOnce))
	addConn(S.mouseGuardConns, UIS:GetPropertyChangedSignal("MouseIconEnabled"):Connect(mouseApplyOnce))
	-- 터치/패드에서도 교란을 막기 위한 약한 방어막
	addConn(S.mouseGuardConns, UIS.InputBegan:Connect(function() mouseApplyOnce() end))
	addConn(S.mouseGuardConns, UIS.InputEnded:Connect(function() mouseApplyOnce() end))
end
local function MouseGuard_Stop()
	S.mouseDesiredBehavior = nil
	S.mouseDesiredIconOn = nil
	clearConns(S.mouseGuardConns)
end
local function mouseFreeBurst(sec: number)
	MouseGuard_Start("unlock")
	task.delay(math.max(0.05, sec), function()
		if S.equipOverlayOpen then return end
		if S.isInHideout then
			MouseGuard_Start("lock")
		else
			MouseGuard_Stop()
		end
	end)
end

local function setControlsEnabled(on: boolean)
	if on then
		CAS:UnbindAction("Hide_DisableControls")
	else
		CAS:BindAction("Hide_DisableControls", function() return Enum.ContextActionResult.Sink end,
		false,
		Enum.PlayerActions.CharacterForward, Enum.PlayerActions.CharacterBackward,
		Enum.PlayerActions.CharacterLeft,    Enum.PlayerActions.CharacterRight,
		Enum.PlayerActions.CharacterJump)
	end
end

local function setCameraInputBlocked(on: boolean)
	if on then
		bindActionSafe("Hide_BlockCamera", function(_, state, input)
			if state == Enum.UserInputState.Begin or state == Enum.UserInputState.Change then
				local t = input.UserInputType
				if t == Enum.UserInputType.MouseButton2 or t == Enum.UserInputType.MouseWheel then
					return Enum.ContextActionResult.Sink
				end
				if t == Enum.UserInputType.Touch then
					if input.Target and input.Target:IsA("GuiBase2d") then
						return Enum.ContextActionResult.Pass
					end
					return Enum.ContextActionResult.Sink
				end
				if input.KeyCode == Enum.KeyCode.Thumbstick2 then
					return Enum.ContextActionResult.Sink
				end
			end
			return Enum.ContextActionResult.Pass
		end, 2500,
		Enum.UserInputType.MouseButton2, Enum.UserInputType.MouseWheel, Enum.UserInputType.Touch, Enum.KeyCode.Thumbstick2)
	else
		CAS:UnbindAction("Hide_BlockCamera")
	end
end

-- ===== 1인칭 강제 가드 (이벤트 기반 + 워치독) =====
local function getHumanoid(): Humanoid?
	local ch = player.Character
	return ch and ch:FindFirstChildOfClass("Humanoid") or nil
end

local function fpApplyOnce()
	if not (S.isInHideout and not S.equipOverlayOpen) then return end
	local hum = getHumanoid()
	if player.CameraMode ~= Enum.CameraMode.LockFirstPerson then player.CameraMode = Enum.CameraMode.LockFirstPerson end
	if player.CameraMinZoomDistance ~= 0.5 then player.CameraMinZoomDistance = 0.5 end
	if player.CameraMaxZoomDistance ~= 0.5 then player.CameraMaxZoomDistance = 0.5 end
	if camera and camera.CameraType ~= Enum.CameraType.Custom then camera.CameraType = Enum.CameraType.Custom end
	if hum and camera and camera.CameraSubject ~= hum then camera.CameraSubject = hum end
end

local function setFirstPersonGuard(on: boolean)
	if on then
		-- 즉시 3회 펄스 적용(경쟁 스크립트 대비)
		fpApplyOnce(); task.delay(0.10, fpApplyOnce); task.delay(0.35, fpApplyOnce)

		-- 연결 재구성
		clearConns(S.fpConns)
		addConn(S.fpConns, player:GetPropertyChangedSignal("CameraMode"):Connect(fpApplyOnce))
		addConn(S.fpConns, player:GetPropertyChangedSignal("CameraMinZoomDistance"):Connect(fpApplyOnce))
		addConn(S.fpConns, player:GetPropertyChangedSignal("CameraMaxZoomDistance"):Connect(fpApplyOnce))

		if camera then
			addConn(S.fpConns, camera:GetPropertyChangedSignal("CameraType"):Connect(fpApplyOnce))
			addConn(S.fpConns, camera:GetPropertyChangedSignal("CameraSubject"):Connect(fpApplyOnce))
		end
		addConn(S.fpConns, Workspace:GetPropertyChangedSignal("CurrentCamera"):Connect(function()
			camera = Workspace.CurrentCamera
			fpApplyOnce()
			if camera then
				addConn(S.fpConns, camera:GetPropertyChangedSignal("CameraType"):Connect(fpApplyOnce))
				addConn(S.fpConns, camera:GetPropertyChangedSignal("CameraSubject"):Connect(fpApplyOnce))
			end
		end))

		-- 워치독(루프 아님: 토큰 기반 지연 호출)
		S.fpWatchdogToken += 1
		local myTok = S.fpWatchdogToken
		local function watchdog()
			if myTok ~= S.fpWatchdogToken then return end
			fpApplyOnce()
			task.delay(0.75, watchdog)
		end
		task.delay(0.75, watchdog)
	else
		S.fpWatchdogToken += 1
		clearConns(S.fpConns)
	end
end

-- ===== InventoryGui + mapui 참조 =====
local function refreshMapRefs()
	if not S.mapui then
		S.mapui = pg:FindFirstChild("mapui", true)
	end
	if S.mapui then
		if not S.mapHideout then
			S.mapHideout = (S.mapui :: Instance):FindFirstChild("hideout", true) :: GuiObject?
		end
		if not S.mapBackToHide then
			S.mapBackToHide = (S.mapui :: Instance):FindFirstChild("backtohide", true) :: GuiObject?
		end
		if not S.mapBackToRobby then
			S.mapBackToRobby = (S.mapui :: Instance):FindFirstChild("backtorobby", true) :: GuiObject?
		end
	end
end

local function bindInventoryGui()
	local sg: ScreenGui? = pg:FindFirstChild("ScreenGui") :: ScreenGui?
	if not sg then sg = pg:FindFirstChildOfClass("ScreenGui") end
	if not sg then return end

	refreshMapRefs()

	local invGui: Instance? = sg:FindFirstChild("InventoryGui") or pg:FindFirstChild("InventoryGui")
	if not invGui then return end

	local invSg: ScreenGui? = invGui:IsA("ScreenGui") and invGui or invGui:FindFirstAncestorOfClass("ScreenGui")
	if invSg then invSg.ResetOnSpawn = false end

	S.inventoryGui = invGui :: any
	S.equipFrame   = (invGui :: Instance):FindFirstChild("EquipmentFrame")  :: Frame?
	S.equipIngame  = (invGui :: Instance):FindFirstChild("Equipmentingame") :: Frame?
	S.stashFrame   = (invGui :: Instance):FindFirstChild("ScrollingInventory") :: ScrollingFrame?
	S.xbButton     = (invGui :: Instance):FindFirstChild("XB") :: GuiObject?

	if S.xbButton    then S.xbButton.Visible    = false end
	if S.equipFrame  then S.equipFrame.Visible  = false end
	if S.equipIngame then S.equipIngame.Visible = false end
	if S.stashFrame  then S.stashFrame.Visible  = false end
end

-- mapui visible helper
local function setMapUIVisible(on: boolean)
	local mu = S.mapui
	if not mu then return end
	if mu:IsA("ScreenGui") then
		(mu :: ScreenGui).Enabled = on
	elseif mu:IsA("GuiObject") then
		(mu :: GuiObject).Visible = on
	end
end

-- mapui에서 backtohide만 보이게/끄기
local function showOnlyMapBackToHide(on: boolean)
	refreshMapRefs()
	if not S.mapui then return end
	if on then
		setMapUIVisible(true)
		for _, d in ipairs(S.mapui:GetDescendants()) do
			if d:IsA("GuiObject") then
				d.Visible = (S.mapBackToHide ~= nil and d == S.mapBackToHide)
			end
		end
	else
		if S.mapBackToHide and S.mapBackToHide:IsA("GuiObject") then
			(S.mapBackToHide :: GuiObject).Visible = false
		end
		setMapUIVisible(false)
	end
end

-- ===== 공통 표시 =====
local function showInv(equip:boolean, hud:boolean, stash:boolean)
	if S.equipFrame  then S.equipFrame.Visible  = equip end
	if S.equipIngame then S.equipIngame.Visible = hud   end
	if S.stashFrame  then S.stashFrame.Visible  = stash end
	if S.xbButton    then S.xbButton.Visible    = (equip or hud or stash) end
end

-- 단일 스위처
local function showOnly(which: string)
	showInv(false,false,false)
	if S.shopGui then S.shopGui.Visible = false end

	if which == "inventory" then
		showInv(true, true, true)
		S.invOpen = true
		setControlsEnabled(false)
		setCameraInputBlocked(false)
		MouseGuard_Start("unlock")
	elseif which == "shop" then
		S.invOpen = false
		if S.shopGui then S.shopGui.Visible = true end
		setControlsEnabled(true)
		setCameraInputBlocked(false)
		MouseGuard_Start("unlock")
	else
		S.invOpen = false
		setControlsEnabled(true)
		setCameraInputBlocked(false)
		if S.isInHideout then MouseGuard_Start("lock") else MouseGuard_Stop() end
	end
end

-- ===== 퀵바 UI =====
local function mkBtn(name:string, parent:Instance, text:string): TextButton
	local b = Instance.new("TextButton")
	b.Name = name
	b.Size = UDim2.new(1, 0, 0, 44)
	b.BackgroundColor3 = Color3.fromRGB(45,45,45)
	b.TextColor3 = Color3.new(1,1,1)
	b.Text = text
	b.Font = Enum.Font.GothamBold
	b.TextSize = 16
	b.AutoButtonColor = true
	local c = Instance.new("UICorner"); c.CornerRadius = UDim.new(0, 10); c.Parent = b
	b.Parent = parent
	return b
end

local function buildQuickBar()
	if S.root and S.root.Parent then return end

	local gui = Instance.new("ScreenGui")
	gui.Name = "QuickBarUi"
	gui.ResetOnSpawn = false
	gui.IgnoreGuiInset = true
	gui.DisplayOrder = 100000
	gui.ZIndexBehavior = Enum.ZIndexBehavior.Sibling
	gui.Parent = pg

	local bar = Instance.new("Frame")
	bar.Name = "Bar"
	bar.AnchorPoint = Vector2.new(0.5, 0.5)
	bar.Position = UDim2.fromScale(0.5, 0.7)
	bar.Size = UDim2.fromOffset(220, 0)
	bar.AutomaticSize = Enum.AutomaticSize.Y
	bar.BackgroundColor3 = Color3.fromRGB(22,22,22)
	bar.BackgroundTransparency = 0.05
	bar.ZIndex = 100
	bar.Parent = gui
	local corner = Instance.new("UICorner"); corner.CornerRadius = UDim.new(0, 12); corner.Parent = bar
	local stroke = Instance.new("UIStroke"); stroke.Thickness = 1; stroke.Transparency = 0.8; stroke.Color = Color3.fromRGB(255,255,255); stroke.Parent = bar
	local pad = Instance.new("UIPadding"); pad.PaddingLeft = UDim.new(0,10); pad.PaddingRight = UDim.new(0,10); pad.PaddingTop = UDim.new(0,10); pad.PaddingBottom = UDim.new(0,10); pad.Parent = bar

	local list = Instance.new("UIListLayout")
	list.FillDirection = Enum.FillDirection.Vertical
	list.Padding = UDim.new(0, 8)
	list.HorizontalAlignment = Enum.HorizontalAlignment.Center
	list.VerticalAlignment = Enum.VerticalAlignment.Top
	list.SortOrder = Enum.SortOrder.LayoutOrder
	list.Parent = bar

	local bHide = mkBtn("BtnHideout",   bar, "하이드아웃")
	local bInv  = mkBtn("BtnInventory", bar, "인벤토리")
	local bShop = mkBtn("BtnShop",      bar, "상점")
	local bBack = mkBtn("BtnBackToHide", bar, "Back → Hide")
	bBack.Visible = false

	S.root, S.bar, S.btnHide, S.btnInv, S.btnShop, S.btnBackToHide =
		gui,  bar,  bHide,     bInv,      bShop,     bBack

	setQuickBarVisible(true)
end

-- ===== 하이드 인/아웃 =====
local function enterHideout()
	if RequestEnter then pcall(function() RequestEnter:FireServer() end) end
	S.isInHideout = true
	S.invOpen = false

	setQuickBarVisible(false)
	setMapUIVisible(false)

	local hum = getHumanoid()
	if hum then hum.AutoRotate = false end

	player.CameraMode = Enum.CameraMode.LockFirstPerson
	player.CameraMaxZoomDistance, player.CameraMinZoomDistance = 0.5, 0.5

	setControlsEnabled(true)
	setCameraInputBlocked(false)
	MouseGuard_Start("lock")

	setFirstPersonGuard(true)   -- ★ 1인칭 가드 ON
end

local function exitHideout()
	if RequestExit then pcall(function() RequestExit:FireServer() end) end
	S.isInHideout = false
	S.invOpen = false

	setMapUIVisible(false)
	setQuickBarVisible(true)

	local hum = getHumanoid()
	if hum then hum.AutoRotate = true end

	player.CameraMode = Enum.CameraMode.Classic
	player.CameraMaxZoomDistance, player.CameraMinZoomDistance = 10, 0.5

	setControlsEnabled(true)
	setCameraInputBlocked(false)
	MouseGuard_Stop()

	setFirstPersonGuard(false)  -- ★ 1인칭 가드 OFF
end

-- ===== TAB: 장비 오버레이 =====
local function openEquipOverlay()
	if S.equipOverlayOpen then return end
	S.equipOverlayOpen = true
	S.invOpen = false

	-- 장비+HUD만, 스태시/ XB 숨김
	showInv(true, true, false)
	if S.xbButton then S.xbButton.Visible = false end

	-- 카메라/마우스 자유
	setControlsEnabled(false)
	setCameraInputBlocked(false)

	S._prevCamMode = player.CameraMode
	player.CameraMode = Enum.CameraMode.Classic
	player.CameraMaxZoomDistance, player.CameraMinZoomDistance = 10, 0.5

	MouseGuard_Start("unlock")
	showOnlyMapBackToHide(true)
	setQuickBarVisible(false)
	_toggleVitalsHUD(true)
	setFirstPersonGuard(false)  -- ★ 오버레이 열면 가드 OFF
end

local function closeEquipOverlay()
	if not S.equipOverlayOpen then return end
	S.equipOverlayOpen = false

	showInv(false,false,false)

	setControlsEnabled(true)
	setCameraInputBlocked(false)

	if S._prevCamMode then
		player.CameraMode = S._prevCamMode
		S._prevCamMode = nil
	else
		player.CameraMode = S.isInHideout and Enum.CameraMode.LockFirstPerson or Enum.CameraMode.Classic
	end

	if S.isInHideout then
		player.CameraMaxZoomDistance, player.CameraMinZoomDistance = 0.5, 0.5
		MouseGuard_Start("lock")
	else
		player.CameraMaxZoomDistance, player.CameraMinZoomDistance = 10, 0.5
		MouseGuard_Stop()
	end

	showOnlyMapBackToHide(false)
	setQuickBarVisible(false)
	_toggleVitalsHUD(false)
	if S.isInHideout then
		setFirstPersonGuard(true) -- ★ 하이드 복귀 시 가드 재개
	end
end

local function bindTabForOverlayOnly()
	CAS:UnbindAction("Hide_ToggleInv")
	CAS:UnbindAction("ToggleInventory")
	CAS:UnbindAction("Inventory_Toggle")

	bindActionSafe("Hide_Tab_EquipOverlay", function(_, state)
		if state ~= Enum.UserInputState.Begin then return Enum.ContextActionResult.Pass end

		-- 어떤 상황이든 즉시 마우스 자유
		MouseGuard_Start("unlock")

		-- 하이드 중이면 오버레이 토글, 아니면 버스트만
		if S.isInHideout then
			if S.equipOverlayOpen then closeEquipOverlay() else openEquipOverlay() end
		else
			mouseFreeBurst(FREE_BURST_SEC)
		end
		return Enum.ContextActionResult.Sink
	end, 9999, Enum.KeyCode.Tab)
end

-- ===== (추가) 모든 탭 UI 닫기 헬퍼 =====
local function closeAllTabs()
	if S.equipOverlayOpen then closeEquipOverlay() end
	showInv(false, false, false)
	if S.shopGui then S.shopGui.Visible = false end
	S.invOpen = false
end
-- (교체본) hookIfButton: 컨테이너도 인식 + Activated 기반 + 이중 발화 방지
local function hookIfButton(btn: Instance?, cb: ()->())
	if not btn or typeof(cb) ~= "function" then return end

	-- 1) 대상 버튼 찾기: 직접 버튼이면 그대로, 아니면 자손에서 첫 GuiButton 탐색
	local target: GuiButton? = nil
	if btn:IsA("GuiButton") then
		target = btn :: GuiButton
	else
		target = (btn :: Instance):FindFirstChildWhichIsA("GuiButton", true)
	end
	if not target then return end

	-- 2) 중복 훅 방지
	if target:GetAttribute("__QB_Hooked") then return end
	target:SetAttribute("__QB_Hooked", true)

	-- 3) 안전 실행 + 디바운스(Activated/MouseButton1Click 동시 연결 대비)
	local firing = false
	local function fireOnce()
		if firing then return end
		firing = true
		task.defer(function()
			local ok, err = pcall(cb)
			if not ok then
				warn("[Hide] hookIfButton callback error:", err)
			end
			task.wait(0.06) -- 짧은 디바운스
			firing = false
		end)
	end

	-- 4) Activated가 마우스/터치/패드 모두 커버. 예외 대비로 MouseButton1Click도 연결(디바운스로 중복 방지)
	target.Activated:Connect(fireOnce)
	target.MouseButton1Click:Connect(fireOnce)
end
-- 컨텍스트 메뉴 강제 닫기(있으면)
local function _closeContextMenuOverlay()
	local pg2 = Players.LocalPlayer:FindFirstChild("PlayerGui")
	if not pg2 then return end
	local cm = pg2:FindFirstChild("ContextMenuGui")
	if cm then cm:Destroy() end
end

-- XB 버튼 바인딩
local function bindXBButton()
	-- InventoryGui 참조 갱신(리스폰 직후 등 대비)
	if not S.xbButton then bindInventoryGui() end
	if not S.xbButton then return end

	-- 이미 훅되어 있으면 재훅 방지
	if S.xbButton:GetAttribute("__QB_Hooked") then return end

	hookIfButton(S.xbButton, function()
		-- 우클릭 컨텍스트 메뉴가 열려 있으면 먼저 닫기
		_closeContextMenuOverlay()

		-- 장비 오버레이가 켜져 있으면 닫고, 아니면 인벤/상점 등 전부 닫기
		if S.equipOverlayOpen then
			closeEquipOverlay()
		else
			closeAllTabs()
			showOnly("none")
		end

		-- 상태 복구: 하이드아웃이면 마우스 락, 그 외엔 퀵바 다시 노출
		if S.isInHideout then
			MouseGuard_Start("lock")
			setMapUIVisible(false)
			setQuickBarVisible(false)
			-- 하이드 1인칭 가드 재개
			setFirstPersonGuard(true)
		else
			MouseGuard_Stop()
			setMapUIVisible(false)
			setQuickBarVisible(true)
		end
	end)
end

local function bindMapUIButtons()
	refreshMapRefs()
	if not S.mapui then return end

	-- hideout
	hookIfButton(S.mapHideout, function()
		if not S.isInHideout then enterHideout() end
		setMapUIVisible(true)
		setQuickBarVisible(false)
	end)

	-- backtohide: 탭 닫기 → (필요 시) 하이드 퇴장 → 선택 화면 유지
	hookIfButton(S.mapBackToHide, function()
		closeAllTabs()
		if S.isInHideout then exitHideout() end
		setMapUIVisible(true)
		local ho, br = S.mapHideout, S.mapBackToRobby
		for _, d in ipairs(S.mapui:GetDescendants()) do
			if d:IsA("GuiObject") then
				d.Visible = (d == ho or d == br)
			end
		end
		setQuickBarVisible(false)
	end)

	-- backtorobby
	hookIfButton(S.mapBackToRobby, function()
		if S.isInHideout then exitHideout() end
		setMapUIVisible(false)
		task.defer(function() setQuickBarVisible(true) end)
	end)
end

-- ===== 퀵바 버튼 =====
local function bindQuickBarButtons()
	if not (S.btnHide and S.btnInv and S.btnShop) then return end

	S.btnHide.MouseButton1Click:Connect(function()
		refreshMapRefs()
		if not S.mapui then return end
		setMapUIVisible(true)
		local ho, br = S.mapHideout, S.mapBackToRobby
		for _, d in ipairs(S.mapui:GetDescendants()) do
			if d:IsA("GuiObject") then
				d.Visible = (d == ho or d == br)
			end
		end
		setQuickBarVisible(false)
	end)

	S.btnInv.MouseButton1Click:Connect(function()
		closeEquipOverlay()
		showOnly("inventory")
	end)

	S.btnShop.MouseButton1Click:Connect(function()
		closeEquipOverlay()
		showOnly("shop")
	end)
end

-- ===== 서버 상태 수신(선택) =====
if StateChanged then
	StateChanged.OnClientEvent:Connect(function(isIn:boolean)
		S.isInHideout = isIn
		if not isIn then
			setQuickBarVisible(true)
			showOnly("none")
			setMapUIVisible(false)
			MouseGuard_Stop()
			setFirstPersonGuard(false)
		end
	end)
end

-- ===== 밀박스 연동(선택) =====
if MilBoxLoot then
	MilBoxLoot.OnClientEvent:Connect(function(kind:string)
		if kind == "open" then
			S.milBoxOpen = true
			MouseGuard_Start("unlock")
		elseif kind == "close" then
			S.milBoxOpen = false
			if S.invOpen or S.equipOverlayOpen then
				MouseGuard_Start("unlock")
			else
				if S.isInHideout then MouseGuard_Start("lock") else MouseGuard_Stop() end
			end
		end
	end)
end

-- ===== 캐릭터 생애주기 =====
local function bindHumanoid(h: Humanoid)
	h.Died:Connect(function()
		S.isInHideout = false
		S.invOpen = false
		S.equipOverlayOpen = false
		showOnly("none")
		player.CameraMode = Enum.CameraMode.Classic
		player.CameraMaxZoomDistance, player.CameraMinZoomDistance = 10, 0.5
		setControlsEnabled(true)
		setCameraInputBlocked(false)
		MouseGuard_Stop()
		setQuickBarVisible(true)
		setMapUIVisible(false)
		setFirstPersonGuard(false)
	end)
end

if player.Character then
	local h0 = player.Character:FindFirstChildOfClass("Humanoid")
	if h0 then bindHumanoid(h0) end
end
player.CharacterAdded:Connect(function(char)
	local h = char:WaitForChild("Humanoid")
	bindHumanoid(h)
	task.defer(function()
		bindInventoryGui()
		buildQuickBar()
		bindQuickBarButtons()
		bindTabForOverlayOnly()
		bindMapUIButtons()
		bindXBButton()
		-- 리스폰 직후 하이드 상태면 가드 재개
		if S.isInHideout and not S.equipOverlayOpen then setFirstPersonGuard(true) end
	end)
end)

-- ===== 최초 부팅 =====
bindInventoryGui()
buildQuickBar()
bindQuickBarButtons()
bindTabForOverlayOnly()
bindMapUIButtons()
bindXBButton()
-- ===== 외부 공개 훅 =====
_G.EnterHideout = function() enterHideout() end
_G.ExitHideout  = function() exitHideout()  end
_G.ToggleInventory = function(open:boolean)
	if not S.isInHideout then
		MouseGuard_Start("unlock"); mouseFreeBurst(FREE_BURST_SEC); return
	end
	if open then openEquipOverlay() else closeEquipOverlay() end
end
