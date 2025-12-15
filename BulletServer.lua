--!strict
-- ServerScriptService/BulletServer.server.lua
-- 클라가 보낸 MUZZLE origin/direction을 받아 서버 레이캐스트로 판정 → BodyHealth로 부위 피해 적용
-- (+) 월드 히트 시 총알 자국 생성/관리

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Players           = game:GetService("Players")
local Workspace         = game:GetService("Workspace")
local Debris            = game:GetService("Debris")

-- ===== Remotes =====
local Remotes = ReplicatedStorage:FindFirstChild("Remotes")
if not Remotes then
	Remotes = Instance.new("Folder")
	Remotes.Name = "Remotes"
	Remotes.Parent = ReplicatedStorage
end

local FireBullet = Remotes:FindFirstChild("FireBullet") :: RemoteEvent?
if not FireBullet then
	FireBullet = Instance.new("RemoteEvent")
	FireBullet.Name = "FireBullet" -- 이름 반드시 고정
	FireBullet.Parent = Remotes
end

-- ===== 모듈 (있으면 사용) =====
local AmmoCatalog:any?;      pcall(function() AmmoCatalog      = require(ReplicatedStorage:WaitForChild("AmmoCatalog")) end)
local BodyHealth:any?;       pcall(function() BodyHealth       = require(ReplicatedStorage:WaitForChild("Shared"):WaitForChild("BodyHealth")) end)

-- ===== 기본 파라미터 =====
local MAX_TRACE_DIST     = 1200
local DEFAULT_DAMAGE     = 32

-- 총알 자국(스코치) 관리
local MARK_LIFETIME_SEC  = 20         -- 자국 유지 시간
local MAX_BULLET_MARKS   = 200        -- 서버 전체 자국 상한
local MARK_SIZE_MIN      = 0.18       -- 자국 지름 랜덤 범위
local MARK_SIZE_MAX      = 0.32
local MARK_THICKNESS     = 0.02       -- 얇게

-- ===== 컨테이너 & 큐 =====
local BulletMarksFolder = Workspace:FindFirstChild("BulletMarks") :: Folder?
if not BulletMarksFolder then
	BulletMarksFolder = Instance.new("Folder")
	BulletMarksFolder.Name = "BulletMarks"
	BulletMarksFolder.Parent = Workspace
end

local MARK_QUEUE: {BasePart} = {}

local function trackMark(p: BasePart)
	table.insert(MARK_QUEUE, p)
	if #MARK_QUEUE > MAX_BULLET_MARKS then
		local old = table.remove(MARK_QUEUE, 1)
		if old and old.Parent then old:Destroy() end
	end
end

-- ===== 유틸 =====
local function resolveAmmo(ammoId:string?): any
	if AmmoCatalog and ammoId then
		local ok, a = pcall(function()
			return (AmmoCatalog.Get and AmmoCatalog.Get(ammoId)) or AmmoCatalog[ammoId]
		end)
		if ok and a then return a end
	end
	return { damage = DEFAULT_DAMAGE }
end

local function makeRayParams(ignore: {Instance}): RaycastParams
	local rp = RaycastParams.new()
	rp.FilterType = Enum.RaycastFilterType.Blacklist
	rp.FilterDescendantsInstances = ignore
	rp.IgnoreWater = false
	return rp
end

local function isCharacterModel(model: Model?): boolean
	if not model then return false end
	return model:FindFirstChildOfClass("Humanoid") ~= nil
end

-- BodyHealth가 있으면 부위 피해, 없으면 Humanoid:TakeDamage
local function applyDamage(attacker: Player, hit: BasePart, dmg: number)
	local char = hit:FindFirstAncestorOfClass("Model")
	if not char then return end

	-- BodyHealth 경로
	if BodyHealth then
		local ok = pcall(function()
			BodyHealth.DamageByHitInstance(char, hit, dmg)
		end)
		if ok then return end
	end

	-- 폴백: 기본 휴머노이드 피해
	local hum = char:FindFirstChildOfClass("Humanoid")
	if hum then hum:TakeDamage(dmg) end
end

-- ===== 총알 자국 생성 =====
local function spawnBulletHole(hitPart: BasePart, hitPos: Vector3, hitNormal: Vector3)
	-- 캐릭터에는 기본값으로 자국 생략 (원하면 아래 주석 해제해서 Weld 부착 구현)
	local topModel = hitPart:FindFirstAncestorOfClass("Model")
	if isCharacterModel(topModel) then
		return
	end

	-- 자국 파트 생성
	local mark = Instance.new("Part")
	mark.Name = "BulletHole"
	mark.Anchored = true
	mark.CanCollide = false
	mark.CanTouch = false
	mark.CanQuery = false -- 레이캐스트 제외
	mark.Material = Enum.Material.SmoothPlastic
	mark.Color = Color3.fromRGB(30, 30, 30)
	mark.Transparency = 0.1

	local size = math.random()*(MARK_SIZE_MAX - MARK_SIZE_MIN) + MARK_SIZE_MIN
	mark.Size = Vector3.new(size, size, MARK_THICKNESS)

	-- 표면에 밀착(법선 방향으로 살짝 띄움)
	local rotRand = CFrame.Angles(0, 0, math.rad(math.random(0, 359)))
	mark.CFrame = CFrame.lookAt(hitPos + hitNormal * (MARK_THICKNESS * 0.5 + 0.01), hitPos + hitNormal) * rotRand
	mark.Parent = BulletMarksFolder

	-- 수명 관리
	trackMark(mark)
	Debris:AddItem(mark, MARK_LIFETIME_SEC)
end

local function fireOneTrace(attacker: Player, origin: Vector3, dir: Vector3, dmg:number)
	local ignore = {}
	if attacker.Character then table.insert(ignore, attacker.Character) end
	-- 자국 폴더 자체는 레이캐스트에서 제외
	table.insert(ignore, BulletMarksFolder)

	local params = makeRayParams(ignore)
	local res = Workspace:Raycast(origin, dir.Unit * MAX_TRACE_DIST, params)
	if not res or not res.Instance or not res.Instance:IsA("BasePart") then return end

	-- 피해
	applyDamage(attacker, res.Instance, dmg)

	-- 자국 (Terrain 포함이면 생략; Terrain은 별도 Decal이 안 붙음)
	if res.Instance ~= workspace.Terrain then
		spawnBulletHole(res.Instance, res.Position, res.Normal)
	end

	-- (선택) 스파크/먼지 파티클 등을 넣고 싶다면 여기서 Attachment 만들어서 짧게 재생 가능
end

-- ===== 엔트리 =====
FireBullet.OnServerEvent:Connect(function(plr: Player, payload)
	if typeof(payload) ~= "table" then return end

	local origin:any = payload.origin
	local dir:any    = payload.direction
	if typeof(origin) ~= "Vector3" or typeof(dir) ~= "Vector3" or dir.Magnitude < 1e-6 then return end

	local ammo      = resolveAmmo(payload.ammoId)
	local baseDmg   = tonumber(ammo.damage) or DEFAULT_DAMAGE
	local pellets   = tonumber(payload.pellets)
	local spreadDeg = tonumber(payload.pelletSpread)

	-- 샷건 펠릿
	if pellets and pellets > 1 then
		local spread = math.rad(spreadDeg or 3)
		-- 간단한 원뿔 분산
		local f = dir.Unit
		local upGuess = math.abs(f.Y) > 0.9 and Vector3.xAxis or Vector3.yAxis
		local r = (f:Cross(upGuess)).Unit
		local u = (r:Cross(f)).Unit

		for _ = 1, math.clamp(pellets, 1, 128) do
			local theta = math.random() * math.pi * 2
			local alpha = math.random() * spread
			local offset = (r * math.cos(theta) + u * math.sin(theta)) * math.tan(alpha)
			fireOneTrace(plr, origin, (f + offset).Unit, baseDmg)
		end
	else
		fireOneTrace(plr, origin, dir.Unit, baseDmg)
	end
end)
