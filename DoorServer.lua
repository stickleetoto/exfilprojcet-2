--!strict
-- 문 열고 닫기 (Attachment 피벗 전용)
-- 구조: m3 > body > door(BasePart)  +  door 하위 어딘가에 Attachment 존재 필수
-- 사용 Attribute(door 파트에 설정 가능):
--   - OpenAngleDeg: number (기본 90)        -- 열릴 각도
--   - Axis: "X"|"Y"|"Z" (기본 "Y")         -- Attachment 로컬 기준 회전축
--   - OpenSign: number (1 또는 -1, 기본 1)  -- 열리는 방향 반전용
-- 내부 Attribute:
--   - IsOpen: bool
--   - DoorBusy: bool

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local TweenService      = game:GetService("TweenService")
local Players           = game:GetService("Players")

-- RemoteEvent 보장
local RE_FOLDER = ReplicatedStorage:FindFirstChild("RemoteEvents")
if not RE_FOLDER then
	RE_FOLDER = Instance.new("Folder")
	RE_FOLDER.Name = "RemoteEvents"
	RE_FOLDER.Parent = ReplicatedStorage
end

local ToggleDoor : RemoteEvent = RE_FOLDER:FindFirstChild("ToggleDoor") :: RemoteEvent
if not ToggleDoor then
	ToggleDoor = Instance.new("RemoteEvent")
	ToggleDoor.Name = "ToggleDoor"
	ToggleDoor.Parent = RE_FOLDER
end

-- 간단 쿨다운
local lastUse: {[Player]: number} = {}
local function canUse(p: Player): boolean
	local now = os.clock()
	local last = lastUse[p] or 0
	if now - last < 0.25 then return false end
	lastUse[p] = now
	return true
end

-- door 유효성
local function isDoorPart(inst: Instance?): BasePart?
	if inst and inst:IsA("BasePart") and inst.Name == "door" then
		return inst
	end
	return nil
end

local function verifyPath(door: BasePart): boolean
	local body = door:FindFirstAncestor("body")
	if not body then return false end
	local m3 = body:FindFirstAncestor("m3")
	return m3 ~= nil
end

-- door 하위에서 Attachment 찾기 (선호 이름 → 없으면 아무 Attachment)
local PIVOT_NAMES = { "DoorPivot", "Hinge", "Pivot", "hinge", "pivot" }
local function findPivotAttachment(door: BasePart): Attachment?
	-- 이름 우선
	for _, d in ipairs(door:GetDescendants()) do
		if d:IsA("Attachment") then
			for _, n in ipairs(PIVOT_NAMES) do
				if d.Name == n then
					return d
				end
			end
		end
	end
	-- 아무거나(마지막 백업)
	for _, d in ipairs(door:GetDescendants()) do
		if d:IsA("Attachment") then
			return d
		end
	end
	return nil
end

local function getOpenAngleRad(door: BasePart): number
	local degAttr = door:GetAttribute("OpenAngleDeg")
	local signAttr = door:GetAttribute("OpenSign")
	local deg = (typeof(degAttr) == "number") and (degAttr :: number) or 90
	local sign = (typeof(signAttr) == "number") and (signAttr :: number) or 1
	return math.rad(deg) * sign
end

local function getAxisRotCFrame(axis: string, angle: number): CFrame
	axis = string.upper(axis)
	if axis == "X" then
		return CFrame.Angles(angle, 0, 0)
	elseif axis == "Z" then
		return CFrame.Angles(0, 0, angle)
	else
		-- 기본 Y
		return CFrame.Angles(0, angle, 0)
	end
end

local function tweenDoorCFrame(door: BasePart, target: CFrame)
	local info = TweenInfo.new(0.35, Enum.EasingStyle.Sine, Enum.EasingDirection.Out)
	local tw = TweenService:Create(door, info, { CFrame = target })
	tw:Play()
	return tw
end

local function toggleDoor(door: BasePart)
	if door:GetAttribute("DoorBusy") then return end
	door:SetAttribute("DoorBusy", true)

	-- 필수: Attachment 피벗
	local pivotAtt = findPivotAttachment(door)
	if not pivotAtt then
		warn(("[Door] '%s' 에 Attachment 피벗이 없습니다."):format(door:GetFullName()))
		door:SetAttribute("DoorBusy", false)
		return
	end

	local pivotCF = (pivotAtt :: Attachment).WorldCFrame
	local relCF   = pivotCF:ToObjectSpace(door.CFrame)

	local isOpen  = (door:GetAttribute("IsOpen") == true)
	local openAng = getOpenAngleRad(door)

	local axisAttr = door:GetAttribute("Axis")
	local axis = (typeof(axisAttr) == "string") and (axisAttr :: string) or "Y"

	-- 열기: +angle, 닫기: -angle  (Attachment 로컬축 기준)
	local R = getAxisRotCFrame(axis, isOpen and -openAng or openAng)
	local targetCF = pivotCF * R * relCF

	local tw = tweenDoorCFrame(door, targetCF)
	tw.Completed:Connect(function()
		door:SetAttribute("IsOpen", not isOpen)
		door:SetAttribute("DoorBusy", false)
	end)
end

ToggleDoor.OnServerEvent:Connect(function(player: Player, doorInst: Instance)
	if not canUse(player) then return end
	local door = isDoorPart(doorInst)
	if not door then return end
	if not verifyPath(door) then return end

	-- 거리 제한(안전)
	local char = player.Character
	if not char then return end
	local hrp = char:FindFirstChild("HumanoidRootPart") :: BasePart?
	if hrp and (hrp.Position - door.Position).Magnitude > 12 then return end

	toggleDoor(door)
end)

Players.PlayerRemoving:Connect(function(p)
	lastUse[p] = nil
end)
