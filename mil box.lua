--!strict
-- ?? ServerScriptService/MilBoxController.server.lua
-- 서버 권위로 mil box head(Model) 회전 + 열림/닫힘 신호
-- 변경: 자동 닫힘 제거, Tab 요청("close")으로만 닫힘

local Players            = game:GetService("Players")
local CollectionService  = game:GetService("CollectionService")
local ReplicatedStorage  = game:GetService("ReplicatedStorage")
local TweenService       = game:GetService("TweenService")

-- RemoteEvent 보장
local RE_FOLDER = ReplicatedStorage:FindFirstChild("RemoteEvents") or Instance.new("Folder")
RE_FOLDER.Name = "RemoteEvents"
RE_FOLDER.Parent = ReplicatedStorage

local MilBoxToggle = RE_FOLDER:FindFirstChild("MilBoxToggle") or Instance.new("RemoteEvent")
MilBoxToggle.Name = "MilBoxToggle"
MilBoxToggle.Parent = RE_FOLDER

local MilBoxLoot = RE_FOLDER:FindFirstChild("MilBoxLoot") or Instance.new("RemoteEvent")
MilBoxLoot.Name = "MilBoxLoot"
MilBoxLoot.Parent = RE_FOLDER

-- 유틸
local function findHeadModel(root: Instance): Model?
	local any = root:FindFirstChild("head", true)
	return (any and any:IsA("Model")) and any or nil
end

local function axisToVector3(axis: string): Vector3
	axis = string.lower(axis or "x")
	if axis == "x" then return Vector3.new(1,0,0)
	elseif axis == "y" then return Vector3.new(0,1,0)
	else return Vector3.new(0,0,1) end
end

local function hasMilBoxTag(model: Model): boolean
	return CollectionService:HasTag(model, "mil box")
		or CollectionService:HasTag(model, "MilBox")
		or CollectionService:HasTag(model, "milbox")
		or CollectionService:HasTag(model, "MIL_BOX")
end

-- 쿨다운(스팸 방지)
local lastUse: {[Model]: number} = {}
local function canUse(model: Model, cd: number): boolean
	cd = cd or 0.25
	local t = os.clock()
	if (lastUse[model] or 0) + cd > t then return false end
	lastUse[model] = t
	return true
end

-- 요청 검증
local function validate(plr: Player, model: Model, maxDist: number?): boolean
	if not model or not model:IsA("Model") then return false end
	if not model:IsDescendantOf(workspace) then return false end
	if not hasMilBoxTag(model) then return false end
	local char = plr.Character
	if not char then return false end
	local hrp = char:FindFirstChild("HumanoidRootPart") :: BasePart?
	if not hrp then return false end
	local dist = (model:GetPivot().Position - hrp.Position).Magnitude
	return dist <= (maxDist or 15)
end

-- 트윈 중복 방지
local activeTweenValue: {[Model]: NumberValue} = {}
local function cancelActiveTween(model: Model)
	local nv = activeTweenValue[model]
	if nv then
		nv:Destroy()
		activeTweenValue[model] = nil
	end
end

-- 서버 트윈
local function tweenHead(model: Model, head: Model, startCF: CFrame, targetCF: CFrame, duration: number, snapToTargetAtEnd: boolean)
	cancelActiveTween(model)

	local progress = Instance.new("NumberValue")
	progress.Name = "_MilBoxTween"
	progress.Value = 0
	progress.Parent = head
	activeTweenValue[model] = progress

	local tween = TweenService:Create(
		progress,
		TweenInfo.new(duration, Enum.EasingStyle.Sine, Enum.EasingDirection.InOut),
		{Value = 1}
	)

	progress.Changed:Connect(function(alpha)
		if not head.Parent then
			cancelActiveTween(model)
			return
		end
		head:PivotTo(startCF:Lerp(targetCF, alpha))
	end)

	tween.Completed:Connect(function()
		activeTweenValue[model] = nil
		if progress.Parent then progress:Destroy() end
		if snapToTargetAtEnd and head.Parent then
			head:PivotTo(targetCF)
		end
	end)

	tween:Play()
end

-- 플레이어별 마지막으로 연 박스
local lastOpenedByPlayer: {[Player]: Model} = {}

MilBoxToggle.OnServerEvent:Connect(function(plr, model: Model?, action: string?)
	-- ▼ 닫기(Tab) 처리
	if action == "close" then
		local target = (typeof(model) == "Instance" and model and model:IsA("Model")) and model or lastOpenedByPlayer[plr]
		if not target then return end
		if not validate(plr, target, 20) then return end -- 닫기는 20m 허용

		local head = findHeadModel(target)
		if not head then return end

		local closedAny = target:GetAttribute("_ClosedHeadPivot")
		local closedCF: CFrame
		if typeof(closedAny) ~= "CFrame" then
			local now = head:GetPivot()
			target:SetAttribute("_ClosedHeadPivot", now)
			closedCF = now
		else
			closedCF = closedAny :: CFrame
		end

		if target:GetAttribute("IsOpen") ~= true then return end

		local nowCF = head:GetPivot()
		target:SetAttribute("IsOpen", false)
		tweenHead(target, head, nowCF, closedCF, (target:GetAttribute("Duration") :: number) or 0.35, true)

		-- Loot UI 닫힘 알림
		MilBoxLoot:FireClient(plr, "close", target)
		return
	end

	-- ▼ 열기(F) 처리
	if not model or not validate(plr, model, 15) or not canUse(model, 0.25) then return end

	local head = findHeadModel(model)
	if not head then return end

	-- 속성 or 기본값
	local openAngleDeg = (model:GetAttribute("OpenAngleDeg") :: number) or -60
	local axisName     = (model:GetAttribute("Axis") :: string) or "X"
	local duration     = (model:GetAttribute("Duration") :: number) or 0.35

	-- 닫힌 기준 CFrame
	local closedAny = model:GetAttribute("_ClosedHeadPivot")
	local closedCF: CFrame
	if typeof(closedAny) ~= "CFrame" then
		local now = head:GetPivot()
		model:SetAttribute("_ClosedHeadPivot", now)
		closedCF = now
	else
		closedCF = closedAny :: CFrame
	end

	-- 이미 열려 있으면 무시(닫기는 Tab으로만)
	if model:GetAttribute("IsOpen") == true then return end

	-- 열기
	local startCF = head:GetPivot()
	local rot = CFrame.fromAxisAngle(axisToVector3(axisName), math.rad(openAngleDeg))
	local targetCF = closedCF * rot

	model:SetAttribute("IsOpen", true)
	lastOpenedByPlayer[plr] = model
	tweenHead(model, head, startCF, targetCF, duration, false)

	-- Loot UI 열림 알림
	MilBoxLoot:FireClient(plr, "open", model)
end)
