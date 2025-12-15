--!strict
-- Seat1(리더) 앉으면: 간단 UI + 키보드(G) 즉시 이동
-- 마우스 자유는 강제하지 않고, RightAlt로 수동 토글만 제공

local Players = game:GetService("Players")
local UIS = game:GetService("UserInputService")
local CAS = game:GetService("ContextActionService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local L = Players.LocalPlayer
local Remotes = ReplicatedStorage:WaitForChild("Remotes")
local LaunchNow = Remotes:WaitForChild("Match_LeaderLaunchNow") :: RemoteEvent
local MatchUpdate = Remotes:WaitForChild("Match_Update") :: RemoteEvent

-- === 설정 ===
local VEHICLE_PREFIXES = { "Humvee", "M2Bradley" }
local AUTO_MOUSE_FREE_ON_SEAT1 = false -- true로 바꾸면 Seat1 앉을 때 한 번만 커서 풀어줌(강제 유지 X)

-- === 상태 ===
local gui: ScreenGui? = nil
local goBtn: TextButton? = nil
local hintLbl: TextLabel? = nil
local isLeaderSeated = false
local savedMouseBehavior: Enum.MouseBehavior = UIS.MouseBehavior
local savedMouseIconEnabled: boolean = UIS.MouseIconEnabled

-- === 유틸 ===
local function startsWith(s: string, prefix: string): boolean
	return string.sub(s, 1, #prefix) == prefix
end

local function isLeaderSeat(seat: BasePart?): (boolean, Model?)
	if not seat then return false, nil end
	if not (seat:IsA("Seat") or seat:IsA("VehicleSeat")) then return false, nil end
	if not string.match(seat.Name, "Seat1$") then return false, nil end
	local m = seat:FindFirstAncestorOfClass("Model")
	while m and m.Parent and not m:IsA("Model") do
		m = m.Parent
	end
	if not m then return false, nil end
	for _, p in ipairs(VEHICLE_PREFIXES) do
		if startsWith(m.Name, p) then
			return true, m
		end
	end
	return false, nil
end

local function ensureGui()
	if gui and gui.Parent then return end
	gui = Instance.new("ScreenGui")
	gui.Name = "LeaderMoveUi"
	gui.ResetOnSpawn = false
	gui.IgnoreGuiInset = true
	gui.DisplayOrder = 120000
	gui.ZIndexBehavior = Enum.ZIndexBehavior.Sibling
	gui.Enabled = false
	gui.Parent = L:WaitForChild("PlayerGui")

	local frame = Instance.new("Frame")
	frame.AnchorPoint = Vector2.new(0.5, 1)
	frame.Position = UDim2.fromScale(0.5, 0.95)
	frame.Size = UDim2.fromOffset(260, 68)
	frame.BackgroundColor3 = Color3.fromRGB(16,16,16)
	frame.BackgroundTransparency = 0.1
	frame.Parent = gui
	local corner = Instance.new("UICorner"); corner.CornerRadius = UDim.new(0, 12); corner.Parent = frame
	local stroke = Instance.new("UIStroke"); stroke.Thickness = 1; stroke.Transparency = 0.75; stroke.Color = Color3.fromRGB(255,255,255); stroke.Parent = frame

	goBtn = Instance.new("TextButton")
	goBtn.Name = "GoBtn"
	goBtn.Size = UDim2.fromOffset(120, 40)
	goBtn.Position = UDim2.fromOffset(12, 14)
	goBtn.BackgroundColor3 = Color3.fromRGB(36,36,36)
	goBtn.Text = "이동"
	goBtn.Font = Enum.Font.GothamBold
	goBtn.TextSize = 20
	goBtn.TextColor3 = Color3.new(1,1,1)
	goBtn.Parent = frame
	local bcorner = Instance.new("UICorner"); bcorner.CornerRadius = UDim.new(0, 10); bcorner.Parent = goBtn

	hintLbl = Instance.new("TextLabel")
	hintLbl.BackgroundTransparency = 1
	hintLbl.Size = UDim2.fromOffset(120, 40)
	hintLbl.Position = UDim2.fromOffset(128, 14)
	hintLbl.TextXAlignment = Enum.TextXAlignment.Left
	hintLbl.TextYAlignment = Enum.TextYAlignment.Center
	hintLbl.TextWrapped = true
	hintLbl.Font = Enum.Font.Gotham
	hintLbl.TextSize = 14
	hintLbl.TextColor3 = Color3.fromRGB(220,220,220)
	hintLbl.Text = "G: 즉시 이동\nRightAlt: 커서 토글"
	hintLbl.Parent = frame

	goBtn.MouseButton1Click:Connect(function()
		LaunchNow:FireServer()
	end)
end

local function setLeaderUi(on: boolean)
	ensureGui()
	gui.Enabled = on
end

local function toggleCursor()
	-- 현재 상태를 반대로 토글
	if UIS.MouseBehavior == Enum.MouseBehavior.LockCenter then
		UIS.MouseBehavior = Enum.MouseBehavior.Default
		UIS.MouseIconEnabled = true
	else
		UIS.MouseBehavior = Enum.MouseBehavior.LockCenter
		-- MouseIconEnabled는 LockCenter일 때 숨겨져도 무방
	end
end

local function setMouseFreeOnce()
	-- 다른 스크립트와 싸우지 않기 위해 '한 번'만 풀어줌(유지 X)
	savedMouseBehavior = UIS.MouseBehavior
	savedMouseIconEnabled = UIS.MouseIconEnabled
	UIS.MouseBehavior = Enum.MouseBehavior.Default
	UIS.MouseIconEnabled = true
end

local function restoreMouse()
	UIS.MouseBehavior = savedMouseBehavior
	UIS.MouseIconEnabled = savedMouseIconEnabled
end

local function bindLeaderActions(bind: boolean)
	if bind then
		CAS:BindAction(
			"EFR_GoNow",
			function(_, state)
				if state == Enum.UserInputState.Begin then
					LaunchNow:FireServer()
				end
				return Enum.ContextActionResult.Sink
			end,
			false,
			Enum.KeyCode.G
		)
		CAS:BindAction(
			"EFR_ToggleCursor",
			function(_, state)
				if state == Enum.UserInputState.Begin then
					toggleCursor()
				end
				return Enum.ContextActionResult.Sink
			end,
			false,
			Enum.KeyCode.RightAlt
		)
	else
		pcall(function() CAS:UnbindAction("EFR_GoNow") end)
		pcall(function() CAS:UnbindAction("EFR_ToggleCursor") end)
	end
end

-- 좌석 이벤트 연결
local function hookHumanoid(h: Humanoid)
	h.Seated:Connect(function(active: boolean, seat: Seat?)
		if active then
			local isLead, _ = isLeaderSeat(seat)
			isLeaderSeated = isLead
			if isLead then
				setLeaderUi(true)
				bindLeaderActions(true)
				if AUTO_MOUSE_FREE_ON_SEAT1 then
					setMouseFreeOnce() -- 한 번만 풀어줌
				end
			else
				setLeaderUi(false)
				bindLeaderActions(false)
			end
		else
			isLeaderSeated = false
			setLeaderUi(false)
			bindLeaderActions(false)
			restoreMouse()
		end
	end)

	-- 초기 상태 체크(이미 앉아있을 때)
	local sp = h.SeatPart
	if sp then
		local isLead, _ = isLeaderSeat(sp)
		isLeaderSeated = isLead
		if isLead then
			setLeaderUi(true)
			bindLeaderActions(true)
			if AUTO_MOUSE_FREE_ON_SEAT1 then
				setMouseFreeOnce()
			end
		end
	end
end

local function onChar(char: Model)
	local hum = char:WaitForChild("Humanoid") :: Humanoid
	hookHumanoid(hum)
end

if L.Character then onChar(L.Character) end
L.CharacterAdded:Connect(onChar)

-- 서버 메시지(로그용)
MatchUpdate.OnClientEvent:Connect(function(msg: string)
	print("[매칭]", msg)
end)
