--!strict
-- 서버 권위:
-- - RequestReload 검증/승인(탄창 개체 Id 기반)
-- - 승인 시 해당 탄창 Id 제거를 클라에 알림(ApplyReload)
-- - FireBullet 수신 → BulletFired 브로드캐스트(이펙트/사운드 싱크)

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Players           = game:GetService("Players")

-- Remotes 폴더
local Remotes = ReplicatedStorage:FindFirstChild("Remotes")
if not Remotes then
	Remotes = Instance.new("Folder")
	Remotes.Name = "Remotes"
	Remotes.Parent = ReplicatedStorage
end

-- RemoteFunction: 리로드 요청(탄창 소비)
local RequestReload = Remotes:FindFirstChild("RequestReload") :: RemoteFunction?
if not RequestReload then
	local rf = Instance.new("RemoteFunction")
	rf.Name = "RequestReload"
	rf.Parent = Remotes
	RequestReload = rf
end

-- RemoteEvent: 서버 승인 후 클라에게 “이 탄창 제거해라(Id)” 알림
local ApplyReload = Remotes:FindFirstChild("ApplyReload") :: RemoteEvent?
if not ApplyReload then
	local ev = Instance.new("RemoteEvent")
	ev.Name = "ApplyReload"
	ev.Parent = Remotes
	ApplyReload = ev
end

-- 총알 발사: 클라→서버
local FireBullet = Remotes:FindFirstChild("FireBullet") :: RemoteEvent?
if not FireBullet then
	local ev = Instance.new("RemoteEvent")
	ev.Name = "FireBullet"
	ev.Parent = Remotes
	FireBullet = ev
end

-- 총알 브로드캐스트: 서버→모든 클라
local BulletFired = Remotes:FindFirstChild("BulletFired") :: RemoteEvent?
if not BulletFired then
	local ev = Instance.new("RemoteEvent")
	ev.Name = "BulletFired"
	ev.Parent = Remotes
	BulletFired = ev
end

-- 간단 검증 헬퍼(실제 인벤토리 서버저장 없으면 최소 방어만)
local function validReloadPayload(p: any): boolean
	return type(p)=="table"
		and type(p.slot)=="string"
		and type(p.magId)=="string"
		and p.magId ~= ""
end

-- 리로드 요청 처리
RequestReload.OnServerInvoke = function(plr: Player, payload: any)
	if not validReloadPayload(payload) then
		warn(("[Reload] bad payload from %s"):format(plr.Name))
		return { ok=false, reason="bad_payload" }
	end

	-- (선택) 여기서 서버 보관 인벤토리가 있다면:
	--  - payload.magId 가 plr 소유의 탄창인지 확인
	--  - 정책(consume/returnOld) 적용
	-- 지금은 클라-주도 GUI 인벤이므로 승인만 하고 삭제 지시
	ApplyReload:FireClient(plr, { removeMagId = payload.magId })

	return { ok=true }
end

-- 총알 발사 브리지: 서버에서 정규화 후 전체 브로드캐스트
FireBullet.OnServerEvent:Connect(function(sender: Player, data)
	if type(data) ~= "table" then return end
	local origin = data.origin
	local dir    = data.direction
	if typeof(origin)~="Vector3" or typeof(dir)~="Vector3" then return end

	-- 방향 정규화(사거리/피해 계산은 각자 게임 룰에 맞춰 확장)
	local d = dir.Magnitude > 0 and dir.Unit or Vector3.new(0,0,-1)

	BulletFired:FireAllClients({
		shooter      = sender.UserId,
		origin       = origin,
		direction    = d,
		pellets      = tonumber(data.pellets),
		pelletSpread = tonumber(data.pelletSpread),
		fromMuzzle   = data.fromMuzzle == true,
	})
end)
