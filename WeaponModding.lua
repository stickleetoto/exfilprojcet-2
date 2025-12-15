--!strict
-- ?? ReplicatedStorage/WeaponModding.lua
-- - Open(targetGui)로 호출
-- - 대상 GUI 내부의 "원본 ViewportFrame"을 그대로 오버레이로 이동해 프리뷰에 사용(복제 X)
-- - 닫을 때 원위치/사이즈/ZIndex 등 복원
-- - ModsJson/HasMag 변화 시 같은 VPF의 모델에 즉시 재적용

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local UserInputService = game:GetService("UserInputService")
local HttpService = game:GetService("HttpService")

local ItemPlacer = require(ReplicatedStorage:WaitForChild("ItemPlacer"))
local GetStashData = ReplicatedStorage:WaitForChild("GetStashData") :: RemoteFunction

-- 옵션 모듈(없으면 조용히 패스)
local WeaponMods:any?, WeaponAttachSvc:any?
do
	local ok1, m1 = pcall(function() return require(ReplicatedStorage:WaitForChild("WeaponMods", 0.5)) end)
	local ok2, m2 = pcall(function() return require(ReplicatedStorage:WaitForChild("WeaponAttachService", 0.5)) end)
	if ok1 then WeaponMods = m1 end
	if ok2 then WeaponAttachSvc = m2 end
end

local Z_FG = 100

local WeaponModding = {}

-- PlayerGui 헬퍼
local function _getPg(): PlayerGui?
	local p = Players.LocalPlayer
	if not p then return nil end
	return p:FindFirstChildOfClass("PlayerGui")
end

-- 대상 GUI 내부의 ViewportFrame(첫 번째) 찾기
local function _findViewportUnder(gui: Instance): ViewportFrame?
	for _, d in ipairs(gui:GetDescendants()) do
		if d:IsA("ViewportFrame") then
			return d
		end
	end
	return nil
end

-- 프리뷰용 오버레이 생성 (닫기 콜백 지원)
local function _buildOverlay(onClose: (() -> ())?): ScreenGui
	local pg = _getPg()
	assert(pg, "PlayerGui not found")

	local sg = Instance.new("ScreenGui")
	sg.ResetOnSpawn = false
	sg.IgnoreGuiInset = true
	sg.Name = "WeaponModdingGui"
	sg.ZIndexBehavior = Enum.ZIndexBehavior.Global
	sg.DisplayOrder = 50
	sg.Parent = pg

	local dim = Instance.new("TextButton")
	dim.Name = "Dim"
	dim.BackgroundColor3 = Color3.fromRGB(0,0,0)
	dim.BackgroundTransparency = 0.3
	dim.Text = ""
	dim.AutoButtonColor = false
	dim.Size = UDim2.fromScale(1,1)
	dim.ZIndex = Z_FG
	dim.Parent = sg

	local panel = Instance.new("Frame")
	panel.Name = "Panel"
	panel.AnchorPoint = Vector2.new(0.5,0.5)
	panel.Position = UDim2.fromScale(0.5,0.5)
	panel.Size = UDim2.fromScale(0.82,0.78)
	panel.BackgroundColor3 = Color3.fromRGB(18,18,18)
	panel.BorderSizePixel = 0
	panel.ZIndex = Z_FG
	panel.Parent = sg
	do
		local corner = Instance.new("UICorner")
		corner.CornerRadius = UDim.new(0,12)
		corner.Parent = panel
		local stroke = Instance.new("UIStroke")
		stroke.Thickness = 1
		stroke.Color = Color3.fromRGB(70,70,70)
		stroke.Parent = panel
	end

	local layout = Instance.new("UIListLayout")
	layout.FillDirection = Enum.FillDirection.Horizontal
	layout.HorizontalAlignment = Enum.HorizontalAlignment.Center
	layout.VerticalAlignment = Enum.VerticalAlignment.Center
	layout.Padding = UDim.new(0,12)
	layout.Parent = panel

	local left = Instance.new("Frame")
	left.Name = "LeftPreview"
	left.Size = UDim2.fromScale(0.62, 0.92)
	left.BackgroundTransparency = 1
	left.ZIndex = Z_FG
	left.Parent = panel

	local right = Instance.new("Frame")
	right.Name = "RightColumn"
	right.Size = UDim2.fromScale(0.32, 0.92)
	right.BackgroundTransparency = 1
	right.ZIndex = Z_FG
	right.Parent = panel

	do
		local rlay = Instance.new("UIListLayout")
		rlay.FillDirection = Enum.FillDirection.Vertical
		rlay.HorizontalAlignment = Enum.HorizontalAlignment.Center
		rlay.VerticalAlignment = Enum.VerticalAlignment.Top
		rlay.Padding = UDim.new(0,8)
		rlay.Parent = right
	end

	local title = Instance.new("TextLabel")
	title.Name = "Title"
	title.Text = "무기 모딩"
	title.Font = Enum.Font.GothamBold
	title.TextSize = 22
	title.TextColor3 = Color3.new(1,1,1)
	title.BackgroundTransparency = 1
	title.Size = UDim2.new(1,0,0,28)
	title.ZIndex = Z_FG
	title.Parent = right

	local close = Instance.new("TextButton")
	close.Name = "CloseBtn"
	close.Text = "닫기 (ESC)"
	close.Font = Enum.Font.Gotham
	close.TextSize = 16
	close.TextColor3 = Color3.new(1,1,1)
	close.AutoButtonColor = true
	close.BackgroundColor3 = Color3.fromRGB(50,50,50)
	close.Size = UDim2.new(1,0,0,32)
	close.ZIndex = Z_FG
	close.Parent = right
	do
		local c = Instance.new("UICorner")
		c.CornerRadius = UDim.new(0,8)
		c.Parent = close
	end

	local slots = Instance.new("Frame")
	slots.Name = "AttachmentSlots"
	slots.BackgroundColor3 = Color3.fromRGB(24,24,24)
	slots.Size = UDim2.new(1,0,1,-(28+8+32+8))
	slots.ZIndex = Z_FG
	slots.Parent = right
	do
		local c = Instance.new("UICorner")
		c.CornerRadius = UDim.new(0,8)
		c.Parent = slots
	end

	local function doClose()
		if onClose then
			pcall(onClose)
		end
		sg:Destroy()
	end
	close.MouseButton1Click:Connect(doClose)
	dim.MouseButton1Click:Connect(doClose)
	UserInputService.InputBegan:Connect(function(i,gpe)
		if gpe then return end
		if i.KeyCode == Enum.KeyCode.Escape then doClose() end
	end)

	return sg
end

-- (옵션) Mods 상태를 특정 ViewportFrame의 모델에 적용
local function _applyModsToViewport(vpf: ViewportFrame, modsTbl: {[string]: any}?)
	if not (WeaponAttachSvc and modsTbl and typeof(modsTbl)=="table") then return end
	local model: Model? = nil
	local world = vpf:FindFirstChildOfClass("WorldModel")
	if world then
		model = world:FindFirstChildWhichIsA("Model", true)
	else
		model = vpf:FindFirstChildWhichIsA("Model", true)
	end
	if model then
		WeaponAttachSvc.ApplyModsToModel(model, modsTbl)
	end
end

-- 공개: 모딩 창 열기
-- targetGui: 우클릭된 아이템 GUI(Attributes: Tag/TagsJson/Name …)
function WeaponModding.Open(targetGui: Instance)
	if not targetGui or not targetGui:IsA("GuiObject") then return end

	-- 서버 메타(없어도 치명적이진 않지만 이름 보정 위해 시도)
	local itemName = targetGui.Name
	local meta: {[string]: any}? = nil
	pcall(function() meta = GetStashData:InvokeServer(itemName) end)
	if not meta and typeof(targetGui:GetAttribute("Tag")) == "string" then
		pcall(function() meta = GetStashData:InvokeServer(targetGui:GetAttribute("Tag")) end)
	end

	-- 1) 대상의 "원본" VPF를 찾는다
	local srcVpf = _findViewportUnder(targetGui)

	-- 2) 오버레이 생성 (닫을 때 원위치 복구)
	local restoreFn: (() -> ())? = nil
	local sg = _buildOverlay(function()
		if restoreFn then restoreFn() end
	end)
	local panel = sg:FindFirstChild("Panel") :: Frame
	local left = panel and panel:FindFirstChild("LeftPreview") :: Frame
	if not left then return end

	if srcVpf then
		-- 원본 보존 정보
		local origParent = srcVpf.Parent
		local placeholder = Instance.new("Frame")
		placeholder.Name = "ViewportPlaceholder"
		placeholder.Size = srcVpf.Size
		placeholder.LayoutOrder = srcVpf.LayoutOrder
		placeholder.BackgroundTransparency = 1
		placeholder.Visible = true
		placeholder.Parent = origParent

		local orig = {
			Size = srcVpf.Size,
			Position = srcVpf.Position,
			Anchor = srcVpf.AnchorPoint,
			Z = srcVpf.ZIndex,
			Parent = origParent,
		}

		-- 프리뷰 스타일로 이동
		srcVpf.AnchorPoint = Vector2.new(0.5,0.5)
		srcVpf.Position = UDim2.fromScale(0.5,0.5)
		srcVpf.Size = UDim2.fromScale(0.95,0.95)
		srcVpf.ZIndex = Z_FG
		srcVpf.Parent = left

		-- 외곽선
		do
			local stroke = Instance.new("UIStroke")
			stroke.Thickness = 1
			stroke.Color = Color3.fromRGB(80,80,80)
			stroke.Parent = srcVpf
		end

		-- ModsJson/HasMag 바뀌면 같은 VPF 모델에 즉시 재적용
		if WeaponMods and WeaponAttachSvc then
			local function reapply()
				_applyModsToViewport(srcVpf, WeaponMods.Read(targetGui))
			end
			reapply()
			targetGui:GetAttributeChangedSignal("ModsJson"):Connect(reapply)
			targetGui:GetAttributeChangedSignal("HasMag"):Connect(reapply)
		end

		-- 닫을 때 원위치 복구
		restoreFn = function()
			if not srcVpf.Parent then return end
			srcVpf.Parent = orig.Parent
			srcVpf.Size = orig.Size
			srcVpf.Position = orig.Position
			srcVpf.AnchorPoint = orig.Anchor
			srcVpf.ZIndex = orig.Z
			if placeholder and placeholder.Parent then
				-- placeholder 자리에 다시 꽂기
				srcVpf.LayoutOrder = placeholder.LayoutOrder
				placeholder:Destroy()
			end
		end

	else
		-- 폴백: 프리뷰를 새로 만든다(원본 VPF가 없을 때만)
		local gui, meta2 = ItemPlacer.CreateGuiFor((meta and meta.Name) or targetGui.Name)
		if gui then
			if gui:IsA("GuiObject") then
				gui.AnchorPoint = Vector2.new(0.5,0.5)
				gui.Position = UDim2.fromScale(0.5,0.5)
				gui.Size = UDim2.fromScale(0.95,0.95)
				gui.ZIndex = Z_FG
				if gui:IsA("ViewportFrame") then
					gui.BackgroundTransparency = 0
					gui.BackgroundColor3 = Color3.fromRGB(10,10,10)
				end
				local stroke = Instance.new("UIStroke")
				stroke.Thickness = 1
				stroke.Color = Color3.fromRGB(80,80,80)
				stroke.Parent = gui
			end
			gui.Parent = left

			-- 이 경우에도 대상 GUI의 Mods 변화를 감지해 프리뷰에 반영
			local vpf: ViewportFrame? = nil
			if gui:IsA("ViewportFrame") then
				vpf = gui
			else
				for _, d in ipairs(gui:GetDescendants()) do
					if d:IsA("ViewportFrame") then vpf = d; break end
				end
			end
			if vpf and WeaponMods and WeaponAttachSvc then
				local function reapply()
					_applyModsToViewport(vpf :: ViewportFrame, WeaponMods.Read(targetGui))
				end
				reapply()
				targetGui:GetAttributeChangedSignal("ModsJson"):Connect(reapply)
				targetGui:GetAttributeChangedSignal("HasMag"):Connect(reapply)
			end
		end
	end
end

return WeaponModding
