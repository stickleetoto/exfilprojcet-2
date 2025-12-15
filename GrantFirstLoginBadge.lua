--!strict
-- ServerScriptService/GrantFirstLoginBadge.server.lua
-- 첫 접속 시 배지 지급 (중복 지급 방지)

local Players = game:GetService("Players")
local BadgeService = game:GetService("BadgeService")
local RunService = game:GetService("RunService")

-- ?? 여기만 바꾸면 됨
local BADGE_ID: number = 467315723298110 -- "게임에 처음 들어왔습니다" 배지 ID

-- 내부 상태: 한 세션에서 중복 시도 방지
local _tried: {[number]: boolean} = {}

-- 안전 호출 + 재시도 유틸
local function retry(fn: () -> (boolean, any), tries: number, delaySec: number): (boolean, any)
	for i = 1, tries do
		local ok, result = pcall(fn)
		if ok then return true, result end
		if i < tries then task.wait(delaySec) end
	end
	return false, nil
end

-- 배지 메타 정보(활성/비활성) 한 번 확인(선택)
local badgeEnabled = true
do
	local ok, info = retry(function()
		return BadgeService:GetBadgeInfoAsync(BADGE_ID)
	end, 3, 0.5)
	if ok and typeof(info) == "table" and info.IsEnabled ~= nil then
		badgeEnabled = info.IsEnabled
	else
		-- 정보 조회 실패 시, 지급 시도는 계속함(일시적 오류 대비)
		badgeEnabled = true
	end
end

local function grantBadge(player: Player)
	if _tried[player.UserId] then return end
	_tried[player.UserId] = true

	if not badgeEnabled then
		warn(string.format("[Badge] Badge %d is disabled; skip.", BADGE_ID))
		return
	end

	-- 스튜디오에선 AwardBadge가 제한될 수 있음
	if RunService:IsStudio() then
		print(string.format("[Badge][Studio] Would grant badge %d to %s", BADGE_ID, player.Name))
		return
	end

	-- 이미 소유했는지 확인
	local hasIt = false
	do
		local ok, res = retry(function()
			return BadgeService:UserHasBadgeAsync(player.UserId, BADGE_ID)
		end, 3, 0.5)
		hasIt = ok and res == true
	end
	if hasIt then
		return -- 이미 있음
	end

	-- 지급 시도(재시도 포함)
	local ok, _ = retry(function()
		BadgeService:AwardBadge(player.UserId, BADGE_ID)
		return true, nil
	end, 3, 0.75)

	if ok then
		print(string.format("[Badge] Granted %d to %s", BADGE_ID, player.Name))
	else
		warn(string.format("[Badge] Failed to grant %d to %s (will not retry further this session)", BADGE_ID, player.Name))
	end
end

-- 플레이어 진입 처리
Players.PlayerAdded:Connect(function(player: Player)
	grantBadge(player)
end)

-- 서버 시작 시 이미 들어와 있는 플레이어 처리(핫리로드 대비)
for _, p in ipairs(Players:GetPlayers()) do
	task.defer(grantBadge, p)
end
