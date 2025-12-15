--!strict
-- InventorySnapshot.client.lua
-- - 첫 접속: GUI 준비 대기 후 자동 로드(실패시 1회 재시도 훅)
-- - 60초 주기 자동 저장
-- - 캐릭터 제거 시 보조 저장
-- - 서버 Pull 요청 대응(RemoteFunction OnClientInvoke)
-- - InventoryGui 안 "XB"(ImageButton) 클릭 시 즉시 저장 + 배지 피드백

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local StarterGui = game:GetService("StarterGui")
local TweenService = game:GetService("TweenService")

local RF = ReplicatedStorage:WaitForChild("InventorySnapshot") :: RemoteFunction
local PullRF = ReplicatedStorage:WaitForChild("InventorySnapshotPull") :: RemoteFunction
local InventoryPersistence = require(ReplicatedStorage:WaitForChild("InventoryPersistence"))

-- ================= 공용 유틸 =================
local function safeNotify(title: string, text: string, dur: number?)
	pcall(function()
		StarterGui:SetCore("SendNotification", {
			Title = title,
			Text = text,
			Duration = dur or 2,
		})
	end)
end

local function waitInventoryGui(timeout: number?): Instance?
	local plr = Players.LocalPlayer
	local t0 = os.clock()
	timeout = timeout or 10
	while os.clock() - t0 < timeout do
		local pg = plr:FindFirstChild("PlayerGui")
		if pg then
			local screen = pg:FindFirstChild("ScreenGui")
			if screen then
				local invGui = screen:FindFirstChild("InventoryGui")
				if invGui then return invGui end
			end
		end
		task.wait(0.05)
	end
	return nil
end

-- ================= 저장/로드 =================
local function saveNow()
	local snap = InventoryPersistence.BuildSnapshot()
	if not snap then
		warn("[InventorySnapshot] BuildSnapshot 실패")
		return
	end
	local ok, err = pcall(function()
		RF:InvokeServer("save", snap)
	end)
	if not ok then
		warn("[InventorySnapshot] save 호출 실패:", err)
	end
end

local function tryLoadOnce(): boolean
	local snap: any = nil
	local ok, res = pcall(function()
		return RF:InvokeServer("load")
	end)
	if ok and typeof(res) == "table" then
		snap = res
	end
	if snap then
		InventoryPersistence.ApplySnapshot(snap)
		return true
	end
	return false
end

-- 서버가 끌어갈 때: 즉시 스냅샷 반환
PullRF.OnClientInvoke = function()
	return InventoryPersistence.BuildSnapshot()
end

-- 초기 로드: GUI 준비될 때까지 기다렸다가 시도
task.spawn(function()
	-- 1) GUI가 만들어질 때까지 대기
	local invGui = waitInventoryGui(10)
	if not invGui then
		warn("[InventorySnapshot] InventoryGui 미탐지(10s). 로드를 건너뜀.")
	else
		-- 2) 로드 시도
		if not tryLoadOnce() then
			-- 3) 만약 아직 로드 실패(예: 내부 팝아웃/맵 초기화 지연)하면,
			--    InventoryGui가 PlayerGui에 등장(또는 재생성)하는 순간 1회 더 로드
			local plr = Players.LocalPlayer
			local pg = plr:FindFirstChild("PlayerGui")
			if pg then
				local fired = false
				local conn
				conn = pg.DescendantAdded:Connect(function(desc)
					if fired then return end
					if desc.Name == "InventoryGui" then
						fired = true
						task.delay(0.1, function()
							tryLoadOnce()
						end)
						if conn then conn:Disconnect() end
					end
				end)
				-- 혹시 이미 열려 있었다면 소량 지연 후 1회 재시도
				task.delay(0.5, function()
					if not fired then
						tryLoadOnce()
					end
				end)
			end
		end
	end
end)

-- 주기 저장
task.spawn(function()
	while task.wait(60) do
		saveNow()
	end
end)

-- 캐릭터 제거 시 보조 저장
Players.LocalPlayer.CharacterRemoving:Connect(function()
	saveNow()
end)
-- (주의) BindToClose는 클라이언트에서 금지

-- ============ XB 버튼: InventoryGui/XB(ImageButton) ============
task.spawn(function()
	-- 경로 대기
	local invGui = waitInventoryGui(15)
	if not invGui then
		warn("[XB Save] InventoryGui 미탐지")
		return
	end

	local xb = invGui:WaitForChild("XB")
	if not xb:IsA("GuiButton") then
		warn("[XB Save] 'XB'가 GuiButton이 아님:", xb.ClassName)
		return
	end

	-- ? / ! 배지 생성 유틸(우상단)
	local function getBadge(): Frame
		local existing = xb:FindFirstChild("SaveBadge")
		if existing and existing:IsA("Frame") then
			return existing
		end

		local badge = Instance.new("Frame")
		badge.Name = "SaveBadge"
		badge.AnchorPoint = Vector2.new(1, 0)
		badge.Position = UDim2.new(1, -6, 0, 6) -- 우상단
		badge.Size = UDim2.fromOffset(20, 20)
		badge.BackgroundColor3 = Color3.fromRGB(46, 204, 113) -- 기본 성공 초록
		badge.BackgroundTransparency = 1
		badge.ZIndex = xb.ZIndex + 10
		badge.Parent = xb

		local corner = Instance.new("UICorner")
		corner.CornerRadius = UDim.new(1, 0)
		corner.Parent = badge

		local glyph = Instance.new("TextLabel")
		glyph.Name = "Glyph"
		glyph.BackgroundTransparency = 1
		glyph.Size = UDim2.fromScale(1, 1)
		glyph.Font = Enum.Font.GothamBold
		glyph.TextScaled = true
		glyph.TextColor3 = Color3.new(1, 1, 1)
		glyph.Text = "?"
		glyph.ZIndex = badge.ZIndex + 1
		glyph.Parent = badge

		return badge
	end

	local function pulseBadge(success: boolean)
		local badge = getBadge()
		local glyph = badge:FindFirstChild("Glyph")
		if glyph and glyph:IsA("TextLabel") then
			if success then
				badge.BackgroundColor3 = Color3.fromRGB(46, 204, 113) -- green
				glyph.Text = "?"
			else
				badge.BackgroundColor3 = Color3.fromRGB(231, 76, 60) -- red
				glyph.Text = "!"
			end
		end

		-- 나타났다가 사라지는 짧은 펄스
		badge.Visible = true
		badge.BackgroundTransparency = 0.2
		if glyph and glyph:IsA("TextLabel") then glyph.TextTransparency = 0 end

		local show = TweenService:Create(badge, TweenInfo.new(0.12, Enum.EasingStyle.Sine, Enum.EasingDirection.Out), {
			BackgroundTransparency = 0.1,
		})
		show:Play()
		show.Completed:Wait()

		task.delay(0.8, function()
			if not badge or not badge.Parent then return end
			local hide1 = TweenService:Create(badge, TweenInfo.new(0.2, Enum.EasingStyle.Sine, Enum.EasingDirection.In), {
				BackgroundTransparency = 1,
			})
			hide1:Play()
			if glyph and glyph:IsA("TextLabel") then
				local hide2 = TweenService:Create(glyph, TweenInfo.new(0.2, Enum.EasingStyle.Sine, Enum.EasingDirection.In), {
					TextTransparency = 1,
				})
				hide2:Play()
			end
		end)
	end

	local busy = false
	xb.Activated:Connect(function()
		if busy then return end
		busy = true

		xb.AutoButtonColor = false
		xb.Active = false

		local ok, err = pcall(saveNow)
		pulseBadge(ok)

		task.delay(0.5, function()
			if xb and xb.Parent then
				xb.AutoButtonColor = true
				xb.Active = true
			end
			busy = false
		end)

		if not ok then
			warn("[XB Save] 저장 실패:", err)
			safeNotify("Inventory", "저장 실패", 2)
		else
			safeNotify("Inventory", "저장 완료", 1.5)
		end
	end)
end)
