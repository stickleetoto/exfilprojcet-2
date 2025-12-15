-- StarterPlayerScripts/HookHideoutViewport.client.lua
-- 휠(줌) 제거, WASD 자유이동 + 마우스 드래그 회전
-- RMB 드래그 또는 Shift+LMB 드래그: 회전
-- WASD: 평면 이동 / E 또는 Space: 상승 / Q 또는 Ctrl: 하강
-- Shift: 가속 / Ctrl: 감속
-- 규칙:
--  1) 퀵바 내부 Hideout 버튼만 오버레이 "열기"
--  2) 퀵바가 아닌 위치의 Hideout 버튼은 "닫기"
--  3) backtohide 버튼은 "열기"
--  4) backtorobby 버튼은 "닫기"
-- 필요: ReplicatedStorage/HideoutViewportService

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")
local UserInputService = game:GetService("UserInputService")

local HVS = require(ReplicatedStorage:WaitForChild("HideoutViewportService"))

local player = Players.LocalPlayer
local pg = player:WaitForChild("PlayerGui")

-- ================== 오버레이 GUI ==================
local overlay = Instance.new("ScreenGui")
overlay.Name = "HideoutOverlay"
overlay.ResetOnSpawn = false
overlay.IgnoreGuiInset = true
overlay.Enabled = false
overlay.DisplayOrder = 999999
overlay.ZIndexBehavior = Enum.ZIndexBehavior.Sibling
overlay.Parent = pg

-- 카드 컨테이너(딤 없음, 오른쪽 살짝 오프셋)
local card = Instance.new("Frame")
card.Name = "Card"
card.AnchorPoint = Vector2.new(0.5, 0.5)
card.BackgroundColor3 = Color3.fromRGB(20, 20, 24)
card.BackgroundTransparency = 0.15
card.Size = UDim2.fromScale(0.80, 0.80)
card.Position = UDim2.new(0.56, 0, 0.52, 0)
card.Parent = overlay
do
	local corner = Instance.new("UICorner"); corner.CornerRadius = UDim.new(0, 14); corner.Parent = card
	local stroke = Instance.new("UIStroke"); stroke.Thickness = 1; stroke.Transparency = 0.35; stroke.Parent = card
end

local vpf = Instance.new("ViewportFrame")
vpf.Name = "HideoutViewport"
vpf.AnchorPoint = Vector2.new(0.5, 0.5)
vpf.Size = UDim2.fromScale(0.98, 0.98)
vpf.Position = UDim2.fromScale(0.5, 0.5)
vpf.BackgroundTransparency = 1
vpf.Parent = card

-- ================== 내부 카메라(자체 제어) ==================
local cam = Instance.new("Camera")
cam.Parent = vpf
vpf.CurrentCamera = cam

local function getWorldModel()
	local wm = vpf:FindFirstChildOfClass("WorldModel")
	if not wm then
		pcall(function()
			local prop = (vpf :: any).WorldModel
			if typeof(prop) == "Instance" then wm = prop end
		end)
	end
	return wm
end

local function findInitialCF()
	-- WorldModel 내부에서 'hideoutview' 계열 마커 찾기 → 없으면 AABB 중앙 바라보게
	local wm = getWorldModel()
	if not wm then return CFrame.new(0, 5, -10), CFrame.new(0,0,0) end

	local function isName(match)
		local m = string.lower(match)
		return m == "hideoutview" or m == "hideout_view" or m == "hideoutcam" or m == "hidecam"
	end

	local markerCF: CFrame? = nil
	for _, d in ipairs(wm:GetDescendants()) do
		local name = d.Name and string.lower(d.Name) or ""
		if isName(name) then
			if d:IsA("BasePart") then
				markerCF = d.CFrame
				break
			elseif d:IsA("Attachment") then
				markerCF = d.WorldCFrame
				break
			end
		end
	end
	if markerCF then
		-- 마커 뒤쪽 약간 떨어져서 시작
		local start = markerCF * CFrame.new(0, 2,  -8)
		return start, markerCF
	end

	-- 폴백: AABB 기반
	local minV, maxV
	for _, d in ipairs(wm:GetDescendants()) do
		if d:IsA("BasePart") then
			local p = d.Position
			minV = minV and Vector3.new(math.min(minV.X, p.X), math.min(minV.Y, p.Y), math.min(minV.Z, p.Z)) or p
			maxV = maxV and Vector3.new(math.max(maxV.X, p.X), math.max(maxV.Y, p.Y), math.max(maxV.Z, p.Z)) or p
		end
	end
	local center = (minV and maxV) and (minV:Lerp(maxV, 0.5)) or Vector3.new(0,0,0)
	local size = (minV and maxV) and (maxV - minV) or Vector3.new(40,20,40)
	local eye = center + Vector3.new(0, size.Y*0.5 + 4, size.Magnitude*0.6)
	return CFrame.new(eye, center), CFrame.new(center)
end

-- 상태: 위치/각도/속도
local camPos = Vector3.new(0,5,-10)
local yawDeg, pitchDeg = 160, -10
local baseSpeed = 12
local boostMult = 2.2
local slowMult  = 0.35
local verticalSpeedMult = 1.0
local rotating = false
local lastMouse: Vector2? = nil

-- 이동 키 상태
local held = {
	W=false, A=false, S=false, D=false,
	Q=false, E=false,
	Space=false, LeftControl=false, RightControl=false,
	Shift=false,
	MouseR=false, MouseL=false,
}

local beganConn, endedConn, changedConn, stepConn

local function key(k: Enum.KeyCode) return UserInputService:IsKeyDown(k) end
local function anyCtrl() return key(Enum.KeyCode.LeftControl) or key(Enum.KeyCode.RightControl) end

local function connectInput()
	if stepConn then return end

	beganConn = UserInputService.InputBegan:Connect(function(input, gp)
		if gp or not overlay.Enabled then return end
		if input.UserInputType == Enum.UserInputType.MouseButton2 then
			held.MouseR = true; rotating = true
			lastMouse = UserInputService:GetMouseLocation()
			UserInputService.MouseBehavior = Enum.MouseBehavior.LockCurrentPosition
			UserInputService.MouseIconEnabled = false
		elseif input.UserInputType == Enum.UserInputType.MouseButton1 and (key(Enum.KeyCode.LeftShift) or key(Enum.KeyCode.RightShift)) then
			held.MouseL = true; rotating = true
			lastMouse = UserInputService:GetMouseLocation()
			UserInputService.MouseBehavior = Enum.MouseBehavior.LockCurrentPosition
			UserInputService.MouseIconEnabled = false
		elseif input.KeyCode == Enum.KeyCode.W then held.W = true
		elseif input.KeyCode == Enum.KeyCode.A then held.A = true
		elseif input.KeyCode == Enum.KeyCode.S then held.S = true
		elseif input.KeyCode == Enum.KeyCode.D then held.D = true
		elseif input.KeyCode == Enum.KeyCode.E then held.E = true
		elseif input.KeyCode == Enum.KeyCode.Q then held.Q = true
		elseif input.KeyCode == Enum.KeyCode.Space then held.Space = true
		elseif input.KeyCode == Enum.KeyCode.LeftShift or input.KeyCode == Enum.KeyCode.RightShift then held.Shift = true
		elseif input.KeyCode == Enum.KeyCode.LeftControl or input.KeyCode == Enum.KeyCode.RightControl then held.LeftControl = true; held.RightControl = true
		end
	end)

	endedConn = UserInputService.InputEnded:Connect(function(input, _gp)
		if input.UserInputType == Enum.UserInputType.MouseButton2 then
			held.MouseR = false; rotating = false
			UserInputService.MouseBehavior = Enum.MouseBehavior.Default
			UserInputService.MouseIconEnabled = true
		elseif input.UserInputType == Enum.UserInputType.MouseButton1 then
			held.MouseL = false; rotating = false
			UserInputService.MouseBehavior = Enum.MouseBehavior.Default
			UserInputService.MouseIconEnabled = true
		elseif input.KeyCode == Enum.KeyCode.W then held.W = false
		elseif input.KeyCode == Enum.KeyCode.A then held.A = false
		elseif input.KeyCode == Enum.KeyCode.S then held.S = false
		elseif input.KeyCode == Enum.KeyCode.D then held.D = false
		elseif input.KeyCode == Enum.KeyCode.E then held.E = false
		elseif input.KeyCode == Enum.KeyCode.Q then held.Q = false
		elseif input.KeyCode == Enum.KeyCode.Space then held.Space = false
		elseif input.KeyCode == Enum.KeyCode.LeftShift or input.KeyCode == Enum.KeyCode.RightShift then held.Shift = false
		elseif input.KeyCode == Enum.KeyCode.LeftControl or input.KeyCode == Enum.KeyCode.RightControl then held.LeftControl = false; held.RightControl = false
		end
	end)

	-- 마우스 휠 바인딩 제거(줌 비활성) → 일부 UI가 휠을 써도 간섭 안함
	changedConn = nil

	stepConn = RunService.RenderStepped:Connect(function(dt)
		if not overlay.Enabled then return end

		-- 회전
		if rotating then
			local m = UserInputService:GetMouseLocation()
			local l = lastMouse or m
			local dx, dy = m.X - l.X, m.Y - l.Y
			lastMouse = m
			if dx ~= 0 or dy ~= 0 then
				local sensX, sensY = 0.20, 0.22
				yawDeg   += dx * sensX
				pitchDeg = math.clamp(pitchDeg - dy * sensY, -80, 80)
			end
		end

		-- 이동
		local yawRad = math.rad(yawDeg)
		local forward = Vector3.new(math.sin(yawRad), 0, -math.cos(yawRad)) -- 평면 forward
		local right   = Vector3.new(math.cos(yawRad), 0,  math.sin(yawRad))
		local upVec   = Vector3.yAxis

		local move = Vector3.zero
		if held.W then move += forward end
		if held.S then move -= forward end
		if held.D then move += right end
		if held.A then move -= right end

		-- 상승/하강: E/Space = up, Q/Ctrl = down
		if held.E or held.Space then move += upVec * verticalSpeedMult end
		if held.Q or anyCtrl() then move -= upVec * verticalSpeedMult end

		if move.Magnitude > 0 then
			move = move.Unit
			local speed = baseSpeed
			if held.Shift then speed *= boostMult end
			if anyCtrl() then speed *= slowMult end
			camPos += move * speed * dt
		end

		-- 카메라 적용
		local lookDir = CFrame.Angles(0, math.rad(yawDeg), 0) * CFrame.Angles(math.rad(pitchDeg), 0, 0)
		local cf = CFrame.new(camPos) * lookDir
		-- CFrame.new(pos) * R 은 pos가 원점으로 적용되므로, LookAt 형태로 만들려면 뒤에 -Z 축
		cam.CFrame = cf * CFrame.new(0,0,0)
		cam.Focus  = cf * CFrame.new(0,0,-10)
	end)
end

local function disconnectInput()
	for _, c in ipairs({ beganConn, endedConn, changedConn, stepConn }) do
		if c then c:Disconnect() end
	end
	beganConn, endedConn, changedConn, stepConn = nil, nil, nil, nil
	rotating = false
	lastMouse = nil
	UserInputService.MouseBehavior = Enum.MouseBehavior.Default
	UserInputService.MouseIconEnabled = true
end

-- ================== 열기/닫기 ==================
local handle
local function openOverlay()
	if overlay.Enabled then return end
	overlay.Enabled = true

	-- HVS 오픈(내부 입력 비활성화만 하고, 카메라는 우리가 제어)
	handle = HVS.Open(vpf, { fov = 70 })
	pcall(function() if handle.EnableInternalInput then handle:EnableInternalInput(false) end end)

	-- 초기 위치/각도 세팅
	local startCF, lookCF = findInitialCF()
	cam.CFrame = startCF
	cam.Focus = lookCF
	camPos = startCF.Position

	-- yaw/pitch을 CFrame에서 추정(수평 yaw만 추출)
	local look = (lookCF.Position - camPos)
	if look.Magnitude > 0 then
		local flat = Vector3.new(look.X, 0, look.Z)
		if flat.Magnitude > 0 then
			yawDeg = math.deg(math.atan2(flat.X, -flat.Z))
		end
		pitchDeg = math.deg(math.asin(look.Unit.Y))
	end

	connectInput()
end

local function closeOverlay()
	if not overlay.Enabled then return end
	overlay.Enabled = false
	disconnectInput()
	if handle then pcall(function() handle:Close() end); handle = nil end
end

-- ================== 버튼 스캐닝/바인딩 ==================
local function lc(s) return typeof(s)=="string" and string.lower(s) or s end
local wired = setmetatable({}, { __mode = "k" })
local function hookOnce(btn, fn)
	if btn and btn:IsA("GuiButton") and not wired[btn] then
		wired[btn] = true
		btn.MouseButton1Click:Connect(fn)
	end
end

local HIDE_BUTTON_NAMES      = { "btnhideout", "hideout", "hide", "btn_hideout" }
local BACK_TO_HIDE_NAMES     = { "backtohide", "tohide", "tohideout", "hidecam" }
local LOBBY_BUTTON_NAMES     = { "backtorobby", "backtolobby", "tolobby", "robby", "lobby" }

local QUICKBAR_ROOT_NAMES = { "quickbarui", "quickbar", "qbar" }
local QUICKBAR_BAR_NAMES  = { "bar" }
local INV_NAMES  = { "btninv","btninventory","inventory","inv" }
local SHOP_NAMES = { "btnshop","shop","market","store" }

local function nameIsOneOf(inst, list)
	if not inst then return false end
	local n = lc(inst.Name)
	for _, v in ipairs(list) do
		if n == v then return true end
	end
	return false
end

local function hasDescendantByName(root, names)
	if not root then return false end
	for _, d in ipairs(root:GetDescendants()) do
		if d:IsA("GuiObject") and nameIsOneOf(d, names) then
			return true
		end
	end
	return false
end

local function isInsideQuickbar(btn)
	local cur = btn and btn.Parent
	while cur do
		if cur:GetAttribute("EFRQuickbar") == true then
			return true
		end
		if nameIsOneOf(cur, QUICKBAR_ROOT_NAMES) or nameIsOneOf(cur, QUICKBAR_BAR_NAMES) then
			return true
		end
		if cur:IsA("GuiObject") then
			if hasDescendantByName(cur, INV_NAMES) or hasDescendantByName(cur, SHOP_NAMES) then
				return true
			end
		end
		cur = cur.Parent
	end
	return false
end

local function isHideoutButton(inst)  return inst and inst:IsA("GuiButton") and nameIsOneOf(inst, HIDE_BUTTON_NAMES) end
local function isBackToHideButton(inst) return inst and inst:IsA("GuiButton") and nameIsOneOf(inst, BACK_TO_HIDE_NAMES) end
local function isLobbyButton(inst)    return inst and inst:IsA("GuiButton") and nameIsOneOf(inst, LOBBY_BUTTON_NAMES) end

local function wireForButton(btn)
	if not btn or wired[btn] then return end

	if isBackToHideButton(btn) then
		hookOnce(btn, openOverlay)
		print("[HookHVF] Enter(open) wired (backtohide):", btn:GetFullName())
		return
	end
	if isLobbyButton(btn) then
		hookOnce(btn, closeOverlay)
		print("[HookHVF] Exit(close) wired (lobby):", btn:GetFullName())
		return
	end
	if isHideoutButton(btn) then
		if isInsideQuickbar(btn) then
			hookOnce(btn, openOverlay)
			print("[HookHVF] Enter(open) wired (quickbar hideout):", btn:GetFullName())
		else
			hookOnce(btn, closeOverlay)
			print("[HookHVF] Exit(close) wired (non-quickbar hideout):", btn:GetFullName())
		end
	end
end

local function initialScan(root)
	for _, d in ipairs(root:GetDescendants()) do
		if d:IsA("GuiButton") then
			if isHideoutButton(d) or isBackToHideButton(d) or isLobbyButton(d) then
				wireForButton(d)
			end
		end
	end
end

initialScan(pg)
pg.DescendantAdded:Connect(function(inst)
	if not inst:IsA("GuiButton") then return end
	RunService.Heartbeat:Wait()
	wireForButton(inst)
end)

player.CharacterAdded:Connect(function()
	if overlay.Enabled then closeOverlay() end
end)
