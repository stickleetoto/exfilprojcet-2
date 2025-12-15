--!strict
-- EFR VehicleSeatingMatchmaker (Lobby/Hideout)
-- 기능:
--  1) 차량 반경 진입 순대로 Seat1→Seat2→... 자동 착석  ← (요청에 의해 비활성화)
--  2) Seat1 = 리더
--  3) 리더가 매칭 시작(키 M) → 대기열 진입(임계치/타임아웃 기준 출발)
--  4) 리더 전용 "이동" 버튼(Remote) → 즉시 출발(그 차량만 묶어 텔레포트)
--  5) 같은 차량(=세트)은 레이드에서 같은 스폰 지점으로 배치

local Players           = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local TeleportService   = game:GetService("TeleportService")
local RunService        = game:GetService("RunService")

-- ===== 설정 =====
local RAID_PLACE_ID = 81043022235770            -- ★ 실제 레이드 PlaceId 로 교체
local MIN_LAUNCH_PLAYERS = 6
local MAX_RAID_PLAYERS   = 12
local QUEUE_TIMEOUT_SEC  = 45
local AUTO_START_ON_SEAT1 = false
local INSTANT_LAUNCH_SPAWN = "Spawn_A"

local VEHICLE_PREFIXES = { "Humvee", "M2Bradley" }
local BOARD_RADIUS_PER_PREFIX : {[string]: number} = { Humvee = 12, M2Bradley = 16 }
local GLOBAL_FALLBACK_RADIUS = 12
local SCAN_INTERVAL = 0.25
local REENTER_COOLDOWN = 1.0
local RIDE_UP_OFFSET = 2.0
local MAX_TRACK_DIST = 80

local VEHICLE_ROOT : Instance = (workspace:FindFirstChild("eject") or workspace)

local RAID_SPAWNS : {string} = {
	"Spawn_A","Spawn_B","Spawn_C","Spawn_D","Spawn_E","Spawn_F",
	"Spawn_G","Spawn_H","Spawn_I","Spawn_J","Spawn_K","Spawn_L",
}

-- ===== Remotes =====
local Remotes = ReplicatedStorage:FindFirstChild("Remotes")
if not Remotes then
	Remotes = Instance.new("Folder")
	Remotes.Name = "Remotes"
	Remotes.Parent = ReplicatedStorage
end

local Match_Update = Remotes:FindFirstChild("Match_Update") :: RemoteEvent
if not Match_Update then
	Match_Update = Instance.new("RemoteEvent")
	Match_Update.Name = "Match_Update"
	Match_Update.Parent = Remotes
end

local Match_StartRequest = Remotes:FindFirstChild("Match_StartRequest") :: RemoteEvent
if not Match_StartRequest then
	Match_StartRequest = Instance.new("RemoteEvent")
	Match_StartRequest.Name = "Match_StartRequest"
	Match_StartRequest.Parent = Remotes
end

local Match_CancelRequest = Remotes:FindFirstChild("Match_CancelRequest") :: RemoteEvent
if not Match_CancelRequest then
	Match_CancelRequest = Instance.new("RemoteEvent")
	Match_CancelRequest.Name = "Match_CancelRequest"
	Match_CancelRequest.Parent = Remotes
end

local Match_LeaderLaunchNow = Remotes:FindFirstChild("Match_LeaderLaunchNow") :: RemoteEvent
if not Match_LeaderLaunchNow then
	Match_LeaderLaunchNow = Instance.new("RemoteEvent")
	Match_LeaderLaunchNow.Name = "Match_LeaderLaunchNow"
	Match_LeaderLaunchNow.Parent = Remotes
end

-- ===== 유틸 =====
local function startsWith(s: string, prefix: string): boolean
	return string.sub(s, 1, #prefix) == prefix
end

local function isVehicleModel(m: Instance): boolean
	if not m:IsA("Model") then return false end
	for _, p in ipairs(VEHICLE_PREFIXES) do
		if startsWith(m.Name, p) then return true end
	end
	return false
end

local function vehiclePrefix(modelName: string): string?
	for _, p in ipairs(VEHICLE_PREFIXES) do
		if startsWith(modelName, p) then return p end
	end
	return nil
end

local function getModelCenter(model: Model): Vector3
	if model.PrimaryPart then return model.PrimaryPart.Position end
	local cf, size = model:GetBoundingBox()
	return cf.Position + Vector3.new(0, size.Y * 0.5, 0)
end

local function getBoardRadius(model: Model): number
	local pref = vehiclePrefix(model.Name)
	if pref and BOARD_RADIUS_PER_PREFIX[pref] then return BOARD_RADIUS_PER_PREFIX[pref] end
	local _, size = model:GetBoundingBox()
	local r = math.max(size.X, size.Z) * 0.6
	return math.clamp(r, GLOBAL_FALLBACK_RADIUS * 0.6, GLOBAL_FALLBACK_RADIUS * 1.8)
end

local function seatIndexFromName(inst: Instance): number?
	local n = string.match(inst.Name, "(%d+)$")
	return n and tonumber(n) or nil
end

local function getHumanoid(plr: Player): Humanoid?
	local char = plr.Character
	if not char then return nil end
	return char:FindFirstChildOfClass("Humanoid")
end

local function getRootPart(plr: Player): BasePart?
	local char = plr.Character
	if not char then return nil end
	return char:FindFirstChild("HumanoidRootPart") :: BasePart
end

local function playerFromOccupant(occ: Humanoid?): Player?
	if not occ then return nil end
	local char = occ.Parent
	if not char then return nil end
	return Players:GetPlayerFromCharacter(char)
end

-- ===== 상태 =====
type WaitEntry = { player: Player, enterClock: number }

type VehicleState = {
	model: Model,
	radius: number,
	seats: {[number]: Seat},
	seatOrder: {Seat},
	occupants: {[number]: Player},
	leaderIndex: number,
	status: "idle"|"queued"|"starting",
	queueTime: number?,
	waitQueue: {WaitEntry},
	lastSeen: {[number]: number},
}
local vehicles : {VehicleState} = {}
local vehiclesByModel : {[Model]: VehicleState} = {}
local playerTargetVehicle : {[number]: VehicleState} = {}

type GroupEntry = { vehicle: VehicleState, leader: Player, groupId: string }
local pendingGroups : {GroupEntry} = {}
local pendingStartTime : number? = nil

local function broadcastToPlayers(players:{Player}, msg:string)
	for _,plr in ipairs(players) do
		Match_Update:FireClient(plr, msg)
	end
end

local function listVehiclePlayers(v: VehicleState): {Player}
	local arr : {Player} = {}
	for _, plr in pairs(v.occupants) do
		if plr and plr.Parent == Players then table.insert(arr, plr) end
	end
	return arr
end

local function chooseSpawnNamesForGroups(groups: {GroupEntry}): {[string]: string}
	local map : {[string]:string} = {}
	local i = 1
	for _, g in ipairs(groups) do
		map[g.groupId] = RAID_SPAWNS[i] or RAID_SPAWNS[#RAID_SPAWNS]
		i += 1
	end
	return map
end

local function makeGroupId(vehicleName: string): string
	return string.format("%s_%d", vehicleName, os.time())
end

-- ===== 매칭: 큐/취소/출발 =====
local function queueVehicle(v: VehicleState)
	if v.status ~= "idle" then return end
	local players = listVehiclePlayers(v)
	if #players == 0 then return end
	local leader = v.occupants[v.leaderIndex]
	if not leader then return end

	local entry : GroupEntry = { vehicle = v, leader = leader, groupId = makeGroupId(v.model.Name) }
	table.insert(pendingGroups, entry)
	v.status = "queued"; v.queueTime = os.clock()
	broadcastToPlayers(players, "[매칭] 대기열에 진입했습니다.")
end

local function findGroupByVehicle(v: VehicleState): number?
	for i, g in ipairs(pendingGroups) do
		if g.vehicle == v then return i end
	end
	return nil
end

local function cancelQueueByVehicle(v: VehicleState, reason: string?)
	local idx = findGroupByVehicle(v)
	if idx then
		broadcastToPlayers(listVehiclePlayers(v), "[매칭] 취소됨: "..(reason or "리더 변경/요청"))
		table.remove(pendingGroups, idx)
	end
	v.status = "idle"
	v.queueTime = nil
end

local function cancelQueueByLeader(leader: Player)
	for _, v in ipairs(vehicles) do
		if v.occupants[v.leaderIndex] == leader then
			cancelQueueByVehicle(v, "리더가 취소")
			return
		end
	end
end

local function allAlive(players:{Player}): {Player}
	local alive = {}
	for _, plr in ipairs(players) do
		if plr.Parent == Players then table.insert(alive, plr) end
	end
	return alive
end

local function launchRaid(groupsToSend:{GroupEntry})
	if RAID_PLACE_ID <= 0 then
		for _,g in ipairs(groupsToSend) do
			broadcastToPlayers(listVehiclePlayers(g.vehicle), "[매칭] RAID_PLACE_ID 미설정: 텔레포트 불가.")
		end
		warn("[VehicleSeatingMatchmaker] RAID_PLACE_ID=0")
		return
	end

	local code = TeleportService:ReserveServer(RAID_PLACE_ID)
	local spawnMap = chooseSpawnNamesForGroups(groupsToSend)

	for _, g in ipairs(groupsToSend) do
		local alive = allAlive(listVehiclePlayers(g.vehicle))
		if #alive > 0 then
			local tpData = { raidId = code, groupId = g.groupId, spawnName = spawnMap[g.groupId] }
			broadcastToPlayers(alive, string.format("[매칭] 레이드 생성됨 → 스폰: %s", spawnMap[g.groupId]))
			TeleportService:TeleportToPrivateServer(RAID_PLACE_ID, code, alive, spawnMap[g.groupId], tpData)
		end
	end
end

local function processQueue()
	if #pendingGroups == 0 then
		pendingStartTime = nil
		return
	end

	local count = 0
	for _, g in ipairs(pendingGroups) do
		count += #listVehiclePlayers(g.vehicle)
	end

	local timedOut = false
	if pendingStartTime then
		if (os.clock() - pendingStartTime) >= QUEUE_TIMEOUT_SEC then
			timedOut = true
		end
	else
		pendingStartTime = os.clock()
	end

	if count >= MIN_LAUNCH_PLAYERS or timedOut then
		local batch : {GroupEntry} = {}
		local acc = 0
		local i = 1
		while i <= #pendingGroups do
			local g = pendingGroups[i]
			local sz = #listVehiclePlayers(g.vehicle)
			if acc + sz <= MAX_RAID_PLAYERS or acc == 0 then  -- ← 여기 or 로 수정
				table.insert(batch, g)
				acc += sz
				table.remove(pendingGroups, i)
			else
				i += 1
			end
			if acc >= MAX_RAID_PLAYERS then break end
		end

		for _, g in ipairs(batch) do
			broadcastToPlayers(listVehiclePlayers(g.vehicle), "[매칭] 출발합니다!")
			g.vehicle.status = "starting"
		end
		launchRaid(batch)
		for _, g in ipairs(batch) do
			g.vehicle.status = "idle"
			g.vehicle.queueTime = nil
		end
		pendingStartTime = (#pendingGroups > 0) and os.clock() or nil
	else
		local remain = math.max(0, MIN_LAUNCH_PLAYERS - count)
		for _, g in ipairs(pendingGroups) do
			broadcastToPlayers(listVehiclePlayers(g.vehicle), string.format("[매칭] 대기 중: %d명 더 필요", remain))
		end
	end
end

-- ===== 좌석/차량 등록 =====
local function buildSeatOrder(model: Model): ({[number]: Seat}, {Seat})
	local byIndex : {[number]: Seat} = {}
	for _, d in ipairs(model:GetDescendants()) do
		if d:IsA("Seat") or d:IsA("VehicleSeat") then
			local idx = seatIndexFromName(d)
			if idx then byIndex[idx] = d end
		end
	end
	local tmp : {Seat} = {}
	for _, seat in pairs(byIndex) do table.insert(tmp, seat) end
	table.sort(tmp, function(a: Seat, b: Seat)
		local ai = seatIndexFromName(a) or 999
		local bi = seatIndexFromName(b) or 999
		return ai < bi
	end)
	return byIndex, tmp
end

local function registerVehicle(model: Model)
	if vehiclesByModel[model] then return end
	local seatsByIndex, seatOrder = buildSeatOrder(model)
	if not seatsByIndex[1] then warn(("[%s] Seat1 없음 → 리더 불가"):format(model.Name)) end

	local v: VehicleState = {
		model = model, radius = getBoardRadius(model),
		seats = seatsByIndex, seatOrder = seatOrder,
		occupants = {}, leaderIndex = 1,
		status = "idle", queueTime = nil,
		waitQueue = {}, lastSeen = {},
	}
	table.insert(vehicles, v)
	vehiclesByModel[model] = v

	for _, s in ipairs(seatOrder) do
		s:GetPropertyChangedSignal("Occupant"):Connect(function()
			local idx = seatIndexFromName(s) or -1
			local occ = s.Occupant
			local plr = playerFromOccupant(occ)

			if v.occupants[idx] and v.occupants[idx] ~= plr then v.occupants[idx] = nil end
			if plr then
				v.occupants[idx] = plr
				if idx == v.leaderIndex then
					Match_Update:FireClient(plr, "[매칭] 당신은 리더입니다. (M: 매칭 / 버튼: 즉시 이동)")
					if AUTO_START_ON_SEAT1 and v.status == "idle" then queueVehicle(v) end
				else
					Match_Update:FireClient(plr, "[매칭] 리더 출발 시 함께 이동합니다.")
				end
			else
				v.occupants[idx] = nil
			end

			if not v.occupants[v.leaderIndex] then
				local lowest : number? = nil
				for seatIdx, p in pairs(v.occupants) do
					if p and ((not lowest) or seatIdx < lowest) then lowest = seatIdx end
				end
				if lowest then
					v.leaderIndex = lowest
					local newLeader = v.occupants[lowest]
					if newLeader then Match_Update:FireClient(newLeader, "[매칭] 좌석 변경으로 리더가 되었습니다. (M/버튼)") end
					if v.status == "queued" then cancelQueueByVehicle(v, "리더 변경") end
				end
			end
		end)
	end
end

for _, inst in ipairs(VEHICLE_ROOT:GetDescendants()) do if isVehicleModel(inst) then registerVehicle(inst :: Model) end end
VEHICLE_ROOT.DescendantAdded:Connect(function(inst)
	if isVehicleModel(inst) then task.wait(0.2); registerVehicle(inst :: Model) end
end)

-- ===== 자동 착석 (비활성화) =====
-- 요청에 따라 '근처로 가면 강제로 앉히는' 로직을 제거.
-- 매칭 큐(processQueue)만 주기적으로 동작하여, 수동으로 착석한 인원들 기준으로 출발을 진행합니다.
task.spawn(function()
	while true do
		processQueue()
		task.wait(SCAN_INTERVAL)
	end
end)

-- ===== 리더: 매칭/취소 & 즉시 이동 =====
Match_StartRequest.OnServerEvent:Connect(function(plr: Player)
	for _, v in ipairs(vehicles) do
		if v.occupants[v.leaderIndex] == plr then
			if v.status == "idle" then queueVehicle(v)
			else Match_Update:FireClient(plr, "[매칭] 이미 대기열에 있습니다.") end
			return
		end
	end
	Match_Update:FireClient(plr, "[매칭] 리더 좌석(Seat1)에 앉아야 시작할 수 있습니다.")
end)

Match_CancelRequest.OnServerEvent:Connect(function(plr: Player)
	cancelQueueByLeader(plr)
end)

Match_LeaderLaunchNow.OnServerEvent:Connect(function(plr: Player)
	for _, v in ipairs(vehicles) do
		if v.occupants[v.leaderIndex] == plr then
			local players = listVehiclePlayers(v)
			if #players == 0 then return end
			if RAID_PLACE_ID <= 0 then
				Match_Update:FireClient(plr, "[매칭] RAID_PLACE_ID 미설정으로 이동 불가."); return
			end
			if v.status == "queued" then cancelQueueByVehicle(v, "즉시 이동") end
			v.status = "starting"
			local code = TeleportService:ReserveServer(RAID_PLACE_ID)
			local tpData = { raidId = code, groupId = makeGroupId(v.model.Name), spawnName = INSTANT_LAUNCH_SPAWN }
			broadcastToPlayers(players, "[매칭] 리더가 ‘이동’을 눌러 즉시 출발합니다.")
			TeleportService:TeleportToPrivateServer(RAID_PLACE_ID, code, allAlive(players), INSTANT_LAUNCH_SPAWN, tpData)
			v.status = "idle"; v.queueTime = nil
			return
		end
	end
	Match_Update:FireClient(plr, "[매칭] 리더 좌석(Seat1)에 앉아야 ‘이동’할 수 있습니다.")
end)

Players.PlayerRemoving:Connect(function(plr)
	local uid = plr.UserId
	for _, v in ipairs(vehicles) do
		for i = #v.waitQueue, 1, -1 do
			if v.waitQueue[i].player == plr then table.remove(v.waitQueue, i) end
		end
		v.lastSeen[uid] = nil
		if v.occupants[v.leaderIndex] == plr and v.status == "queued" then
			cancelQueueByVehicle(v, "리더 이탈")
		end
	end
	playerTargetVehicle[uid] = nil
end)
