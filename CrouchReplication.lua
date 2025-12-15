--!strict
-- 모든 플레이어의 웅크리기 깊이를 서버에서 적용해 모두에게 보이게 함
-- - 클라가 보낸 depth(0~1)를 검증/클램프
-- - 서버에서 HipHeight/WalkSpeed/JumpPower를 계산해 적용(복제됨)
-- - 천장 체크로 기립 불가 시 강제 소폭 crouch 유지

local Players          = game:GetService("Players")
local ReplicatedStorage= game:GetService("ReplicatedStorage")
local Workspace        = game:GetService("Workspace")

-- ===== Remotes 준비 =====
local Remotes = ReplicatedStorage:FindFirstChild("Remotes")
if not Remotes then
	Remotes = Instance.new("Folder")
	Remotes.Name = "Remotes"
	Remotes.Parent = ReplicatedStorage
end
local CrouchRE = Remotes:FindFirstChild("EFR_CrouchDepth") :: RemoteEvent?
if not CrouchRE then
	local ev = Instance.new("RemoteEvent")
	ev.Name = "EFR_CrouchDepth"
	ev.Parent = Remotes
	CrouchRE = ev
end

-- ===== 튜닝(클라와 동일 값 권장) =====
local CROUCH_HIP_DELTA   = 1.4
local STAND_WALK_DEFAULT = 16
local CROUCH_WALK        = 9
local STAND_JUMP_DEFAULT = 50
local CROUCH_JUMP        = 0

local MIN_DEPTH = 0.0
local MAX_DEPTH = 1.0
local MIN_CROUCH_IF_BLOCKED = 0.2
local CEILING_BUFFER = 0.15

-- ===== 상태 테이블 =====
type Baseline = {
	StandHip: number,
	StandWalk: number,
	StandJump: number,
}
local PData: {[number]: {
	baseline: Baseline?,
	lastSendT: number,
	lastDepth: number,
	rp: RaycastParams
}} = {}

local function ensurePlayer(plr: Player)
	if PData[plr.UserId] then return end
	local rp = RaycastParams.new()
	rp.FilterType = Enum.RaycastFilterType.Exclude
	PData[plr.UserId] = {
		baseline = nil,
		lastSendT = 0,
		lastDepth = 0,
		rp = rp,
	}
end

local function onCharacter(plr: Player, char: Model)
	ensurePlayer(plr)
	local pd = PData[plr.UserId]
	pd.rp.FilterDescendantsInstances = { char } -- 자기 몸 제외

	local hum = char:WaitForChild("Humanoid") :: Humanoid
	-- 현재 캐릭터 값을 기준선으로 저장(리그마다 다를 수 있음)
	local base: Baseline = {
		StandHip  = hum.HipHeight,
		StandWalk = hum.WalkSpeed > 0 and hum.WalkSpeed or STAND_WALK_DEFAULT,
		StandJump = hum.JumpPower > 0 and hum.JumpPower or STAND_JUMP_DEFAULT,
	}
	pd.baseline = base
	hum:SetAttribute("EFR_StandHip", base.StandHip)
	hum:SetAttribute("EFR_StandWalk", base.StandWalk)
	hum:SetAttribute("EFR_StandJump", base.StandJump)
end

Players.PlayerAdded:Connect(function(plr)
	ensurePlayer(plr)
	plr.CharacterAdded:Connect(function(char) onCharacter(plr, char) end)
	if plr.Character then onCharacter(plr, plr.Character) end
end)
Players.PlayerRemoving:Connect(function(plr) PData[plr.UserId] = nil end)

local function mapDepth(base: Baseline, depth: number)
	depth = math.clamp(depth, MIN_DEPTH, MAX_DEPTH)
	local hip  = base.StandHip  - (CROUCH_HIP_DELTA * depth)
	local walk = base.StandWalk + (CROUCH_WALK - base.StandWalk) * depth
	local jump = base.StandJump + (CROUCH_JUMP - base.StandJump) * depth
	return hip, walk, jump
end

local function canStand(char: Model, pd, depth: number): boolean
	-- depth에서 0으로 갈 때 머리가 올라갈 여유가 있는지 체크
	local head = char:FindFirstChild("Head") :: BasePart?
	if not head then return true end
	local rise = (CROUCH_HIP_DELTA * depth) + CEILING_BUFFER
	if rise <= 0 then return true end
	local hit = Workspace:Raycast(head.Position, Vector3.new(0, rise, 0), pd.rp)
	return hit == nil
end

CrouchRE.OnServerEvent:Connect(function(plr: Player, depth: any)
	repeat
		if typeof(depth) ~= "number" then break end
		ensurePlayer(plr)
		local pd = PData[plr.UserId]
		local char = plr.Character
		if not char then break end
		local hum = char:FindFirstChildOfClass("Humanoid") :: Humanoid?
		if not hum then break end
		local base = pd.baseline
		if not base then break end

		-- 간단한 레이트리밋(20Hz) + 변동 없으면 무시
		local t = os.clock()
		if (t - pd.lastSendT) < 0.05 and math.abs(depth - pd.lastDepth) < 0.02 then
			return
		end
		pd.lastSendT = t
		pd.lastDepth = depth

		local d = math.clamp(depth, MIN_DEPTH, MAX_DEPTH)
		-- 기립 시도인데 천장 때문에 불가하면 최소 웅크림 유지
		if d <= 0.05 and not canStand(char, pd, pd.lastDepth) then
			d = MIN_CROUCH_IF_BLOCKED
		end

		local hip, walk, jump = mapDepth(base, d)

		-- 실제 적용(서버 권위 → 전클라 복제)
		if math.abs(hum.HipHeight - hip) > 1e-3 then hum.HipHeight = hip end
		if math.abs(hum.WalkSpeed - walk) > 1e-3 then hum.WalkSpeed = walk end
		if math.abs(hum.JumpPower - jump) > 1e-3 then hum.JumpPower = jump end

		hum:SetAttribute("EFR_CrouchDepth", d)
	until true
end)
