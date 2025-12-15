--!strict
-- Inventory 버튼/퀵바/XB 버튼으로 EquipmentFrame, Equipmentingame, (있다면) ScrollingInventory 표시/숨김
-- - 로딩 완료(ReplicatedStorage.LoadingReady)까지 대기
-- - 인벤 열면 QuickBar 숨김, 닫으면 복귀
-- - XB가 버튼이 아니어도 클릭/터치로 닫기
-- - InventoryGui/QuickBarUi가 나중에 생겨도 짧은 재시도 루프 + 감시로 자동 후킹
-- - ?? GetDebugId 사용 제거(플레이어 런타임 금지)

local Players = game:GetService("Players")
local RunService = game:GetService("RunService")
local CAS = game:GetService("ContextActionService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local player = Players.LocalPlayer
local pg = player:WaitForChild("PlayerGui")

-- ===== 로딩 완료 신호 대기 =====
local function waitForLoadingReady(timeout: number?)
	timeout = timeout or 12
	local t0 = os.clock()
	local evt = ReplicatedStorage:FindFirstChild("LoadingReady")
	if ReplicatedStorage:GetAttribute("LoadingReady") == true then return end
	if evt and evt:IsA("BindableEvent") then
		local done = false
		task.spawn(function()
			pcall(function() (evt :: BindableEvent).Event:Wait() end)
			done = true
		end)
		while os.clock() - t0 < timeout do
			if done or ReplicatedStorage:GetAttribute("LoadingReady") == true then return end
			RunService.RenderStepped:Wait()
		end
	else
		while os.clock() - t0 < timeout do
			if ReplicatedStorage:GetAttribute("LoadingReady") == true then return end
			RunService.RenderStepped:Wait()
		end
	end
end

-- ===== 안전 탐색 =====
local function findBestInventoryGui(): Instance?
	local best: Instance? = nil
	local fallback: Instance? = nil
	for _, d in ipairs(pg:GetDescendants()) do
		if d.Name == "InventoryGui" then
			fallback = fallback or d
			local ef = d:FindFirstChild("EquipmentFrame")
			local ig = d:FindFirstChild("Equipmentingame")
			if ef and ig then best = d; break end
		end
	end
	return best or fallback
end

local function firstButtonUnder(root: Instance): GuiButton?
	if root:IsA("TextButton") or root:IsA("ImageButton") then return root end
	for _, d in ipairs(root:GetDescendants()) do
		if d:IsA("TextButton") or d:IsA("ImageButton") then return d end
	end
	return nil
end

local function findXBAny(invGui: Instance): GuiObject?
	local xb = invGui:FindFirstChild("XB", true)
	if xb and xb:IsA("GuiObject") then return xb end
	for _, d in ipairs(invGui:GetDescendants()) do
		if d:IsA("GuiObject") then
			local n = string.lower(d.Name)
			if n == "xb" or n == "close" or n == "btn_close" then return d end
			if d:IsA("TextButton") then
				local t = string.lower((d :: TextButton).Text or "")
				if t == "x" or t == "close" then return d end
			end
		end
	end
	return nil
end

-- ===== 상태 =====
local S = {
	invGui = nil :: Instance?,
	equip  = nil :: Frame?,
	ingame = nil :: Frame?,
	stash  = nil :: ScrollingFrame?,
	xbAny  = nil :: GuiObject?,
	xbBtn  = nil :: GuiButton?,

	qb    = nil :: ScreenGui?,  -- QuickBarUi
	qbBar = nil :: Frame?,       -- QuickBarUi/Bar
	qbInv = nil :: TextButton?,  -- BtnInventory
	qbHide= nil :: TextButton?,  -- BtnHideout
	qbShop= nil :: TextButton?,  -- BtnShop

	invOpen = false,
	conns = {} :: {RBXScriptConnection},

	-- 이전에 바인딩했던 실제 인스턴스(참조 비교로 변경 감지)
	lastInvRef = nil :: Instance?,
	lastQbRef  = nil :: Instance?,
}

local function addConn(c: RBXScriptConnection?) if c then table.insert(S.conns, c) end end
local function cleanup()
	for _, c in ipairs(S.conns) do pcall(function() c:Disconnect() end) end
	S.conns = {}
end

local function refreshRefs()
	S.invGui = findBestInventoryGui()
	if S.invGui then
		S.equip  = S.invGui:FindFirstChild("EquipmentFrame")  :: Frame?
		S.ingame = S.invGui:FindFirstChild("Equipmentingame") :: Frame?
		S.stash  = S.invGui:FindFirstChild("ScrollingInventory") :: ScrollingFrame?
		S.xbAny  = findXBAny(S.invGui)
		S.xbBtn  = S.xbAny and firstButtonUnder(S.xbAny) or nil
	else
		S.equip, S.ingame, S.stash, S.xbAny, S.xbBtn = nil, nil, nil, nil, nil
	end

	S.qb    = pg:FindFirstChild("QuickBarUi") :: ScreenGui?
	S.qbBar = S.qb and S.qb:FindFirstChild("Bar") :: Frame?
	if S.qbBar then
		S.qbInv  = S.qbBar:FindFirstChild("BtnInventory") :: TextButton?
		S.qbHide = S.qbBar:FindFirstChild("BtnHideout")   :: TextButton?
		S.qbShop = S.qbBar:FindFirstChild("BtnShop")      :: TextButton?
	else
		S.qbInv, S.qbHide, S.qbShop = nil, nil, nil
	end
end

-- 표시/숨김
local function setQuickBarVisible(on: boolean)
	if S.qb then S.qb.Enabled = on end
	if S.qbBar then S.qbBar.Visible = on end
end

local function showInvPanels(on: boolean)
	if S.equip  then S.equip.Visible  = on end
	if S.ingame then S.ingame.Visible = on end
	if S.stash  then S.stash.Visible  = on end
	if S.xbAny  then S.xbAny.Visible  = on end
end

local function openInventory()
	refreshRefs()
	if not (S.invGui and S.equip and S.ingame) then return end
	S.invOpen = true
	showInvPanels(true)
	setQuickBarVisible(false)
end

local function closeInventory()
	S.invOpen = false
	showInvPanels(false)
	setQuickBarVisible(true)
end

-- XB 후킹
local function hookXB()
	if not S.invGui then return end
	S.xbAny = findXBAny(S.invGui)
	S.xbBtn = S.xbAny and firstButtonUnder(S.xbAny) or nil
	if not S.xbAny then return end
	if S.xbAny:GetAttribute("__InvXB_Wired") then return end
	S.xbAny:SetAttribute("__InvXB_Wired", true)

	if S.xbBtn then
		S.xbBtn.Active = true
		S.xbBtn.AutoButtonColor = true
		addConn(S.xbBtn.Activated:Connect(closeInventory))
		addConn(S.xbBtn.MouseButton1Click:Connect(closeInventory))
	else
		S.xbAny.Active = true
		addConn(S.xbAny.InputBegan:Connect(function(input)
			if input.UserInputType == Enum.UserInputType.MouseButton1 or input.UserInputType == Enum.UserInputType.Touch then
				closeInventory()
			end
		end))
	end
end

-- 전부 바인딩
local function bindAll()
	cleanup()
	refreshRefs()

	-- 변경 감지용 현재 참조 저장
	S.lastInvRef = S.invGui
	S.lastQbRef  = S.qb

	-- (선택) 레거시 로비 인벤 버튼도 여는 동작에 붙이기(있으면)
	local screenGui = pg:FindFirstChild("ScreenGui") :: Instance?
	local legacyInvBtn: Instance? = nil
	if screenGui then
		local robby = screenGui:FindFirstChild("robbyui")
		if robby then legacyInvBtn = robby:FindFirstChild("Inventory") end
	end
	if legacyInvBtn and legacyInvBtn:IsA("TextButton") then
		addConn((legacyInvBtn :: TextButton).MouseButton1Click:Connect(openInventory))
	end

	-- 퀵바
	if S.qbInv then addConn(S.qbInv.MouseButton1Click:Connect(openInventory)) end
	if S.qbHide then
		addConn(S.qbHide.MouseButton1Click:Connect(function()
			closeInventory()
			setQuickBarVisible(false) -- 하이드 진입시 숨김 유지
		end))
	end
	if S.qbShop then
		addConn(S.qbShop.MouseButton1Click:Connect(function()
			closeInventory()
		end))
	end

	-- XB
	hookXB()

	-- TAB 토글
	CAS:UnbindAction("Inventory_Toggle")
	addConn(CAS:BindActionAtPriority(
		"Inventory_Toggle",
		function(_, state)
			if state ~= Enum.UserInputState.Begin then return Enum.ContextActionResult.Pass end
			if S.invOpen then closeInventory() else openInventory() end
			return Enum.ContextActionResult.Sink
		end,
		false,
		3000,
		Enum.KeyCode.Tab
		))
end

-- ===== 초기 부팅 =====
waitForLoadingReady(12)
bindAll()

-- 늦게 뜨는 UI 대비: 짧은 재시도 루프(약 3초)
local function bootstrapRebind()
	local tries = 0
	local MAX = 180 -- ~3초 @60fps
	local conn; conn = RunService.RenderStepped:Connect(function()
		tries += 1
		local curInv = findBestInventoryGui()
		local curQb  = pg:FindFirstChild("QuickBarUi")
		if curInv ~= S.lastInvRef or curQb ~= S.lastQbRef then
			bindAll()
		end
		if tries >= MAX then conn:Disconnect() end
	end)
end
bootstrapRebind()

-- 구조 변화 감시 → 즉시 재바인딩 + 부트스트랩 재가동
local function scheduleSoon()
	task.defer(function()
		bindAll()
		bootstrapRebind()
	end)
end

pg.ChildAdded:Connect(function(_) scheduleSoon() end)
pg.DescendantAdded:Connect(function(desc)
	local n = string.lower(desc.Name)
	if n == "xb" or n == "inventorygui" or n == "quickbarui" then
		scheduleSoon()
	end
end)
pg.AncestryChanged:Connect(function() scheduleSoon() end)
