--!strict
-- ?? AdminGrantService.server.lua
-- 화이트리스트 운영자 전용 지급 + "킷(세트)" 지급 지원

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

-- ===== 운영자 화이트리스트 =====
local ADMIN_IDS: {[number]: true} = {
	[5688250920] = true,
	[1555653765] = true,
}

local function isAdmin(plr: Player?): boolean
	return plr ~= nil and ADMIN_IDS[plr.UserId] == true
end

-- ===== Remotes =====
local REQ = ReplicatedStorage:FindFirstChild("AdminGrantRequest") :: RemoteEvent?
if not REQ then
	local ev = Instance.new("RemoteEvent")
	ev.Name = "AdminGrantRequest"
	ev.Parent = ReplicatedStorage
	REQ = ev
end
local DELIVER = ReplicatedStorage:FindFirstChild("AdminGrantDeliver") :: RemoteEvent?
if not DELIVER then
	local ev = Instance.new("RemoteEvent")
	ev.Name = "AdminGrantDeliver"
	ev.Parent = ReplicatedStorage
	DELIVER = ev
end
local RESULT = ReplicatedStorage:FindFirstChild("AdminGrantResult") :: RemoteEvent?
if not RESULT then
	local ev = Instance.new("RemoteEvent")
	ev.Name = "AdminGrantResult"
	ev.Parent = ReplicatedStorage
	RESULT = ev
end

-- ===== 유틸 =====
local function slug(s: string): string
	s = s:lower()
	s = s:gsub("[%s]+", "_")
	s = s:gsub("[^%w_]+", "")
	return s
end

local function findPlayerByAny(token: string): Player?
	token = tostring(token)
	local num = tonumber(token)
	if num then
		for _, p in ipairs(Players:GetPlayers()) do
			if p.UserId == num then return p end
		end
	end
	for _, p in ipairs(Players:GetPlayers()) do
		local nameL = p.Name:lower()
		local dispL = p.DisplayName:lower()
		local tokL  = token:lower()
		if nameL:find(tokL, 1, true) or dispL:find(tokL, 1, true) then
			return p
		end
	end
	return nil
end

local function deliverToClient(target: Player, items: {{name: string, count: number}})
	DELIVER:FireClient(target, items)
end

local function mergeItem(into: {[string]: number}, name: string, count: number)
	if name == "" or count <= 0 then return end
	into[name] = (into[name] or 0) + count
end

local function flattenItems(map: {[string]: number}): {{name: string, count: number}}
	local out = {}
	for nm, ct in pairs(map) do
		table.insert(out, { name = nm, count = math.clamp(math.floor(ct), 1, 999999) })
	end
	table.sort(out, function(a, b) return a.name < b.name end)
	return out
end

-- ===== 킷(세트) 정의 =====
type KitItem = { name: string, count: number }
type KitDef  = { items: {KitItem} }

local KITS: {[string]: KitDef} = {
	["mcx_basic"] = {
		items = {
			{ name = "mcx",            count = 1   },
			{ name = "55645 m16 mag empty 60rnd (surfire)",     count = 1   },
			{ name = "5.56x45 M995",      count = 59 },
			{ name = "5.56x45 M995",      count = 59 },
			{ name = "FirstSpear StrandHogg PC MCam_",      count = 1 },
			{ name = "MILITARY_BACKPACK",      count = 1 },
		}
	},
	["ak47_basic"] = {
		items = {
			{ name = "weapon_ak47",           count = 1   },
			{ name = "mag_762_ak_30",         count = 4   },
			{ name = "ammo_762x39_m43",       count = 120 },
		}
	},
}

local KIT_ALIASES: {[string]: string} = {
	["mcx"]        = "mcx_basic",
	["mcx_basic"]  = "mcx_basic",
	["ak"]         = "ak47_basic",
	["ak47"]       = "ak47_basic",
	["ak47_basic"] = "ak47_basic",
}

local function resolveKitKey(raw: string): string?
	local key = slug(raw)
	if KIT_ALIASES[key] then return KIT_ALIASES[key] end
	if KITS[key] then return key end
	return nil
end

local function expandKit(kitKey: string, times: number, acc: {[string]: number})
	local def = KITS[kitKey]
	if not def then return end
	for _, it in ipairs(def.items) do
		mergeItem(acc, it.name, it.count * times)
	end
end

local function parseTrailingMultiplier(tokens: {string}): (string, number)
	local rawName = table.concat(tokens, " ", 1, #tokens)
	local mult = 1
	local mm = rawName:lower():match("x(%d+)$")
	if mm then
		mult = math.max(1, tonumber(mm) or 1)
		rawName = rawName:sub(1, #rawName - (#mm + 1)):gsub("%s+$","")
	end
	return rawName, mult
end

-- ===== Remote 처리 =====
REQ.OnServerEvent:Connect(function(sender: Player, payload: any)
	if not isAdmin(sender) then
		if RESULT then RESULT:FireClient(sender, false, "권한 없음") end
		warn(("[AdminGrant] 권한 없는 요청 by %s (%d)"):format(sender.Name, sender.UserId))
		return
	end
	if type(payload) ~= "table" then
		if RESULT then RESULT:FireClient(sender, false, "잘못된 요청 형식") end
		return
	end

	local target: Player? = nil
	if type(payload.target) == "string" then
		target = findPlayerByAny(payload.target)
	end
	if not target then
		if RESULT then RESULT:FireClient(sender, false, "대상 플레이어 없음") end
		return
	end

	local acc: {[string]: number} = {}
	local filled = false

	-- kits 배열
	if type(payload.kits) == "table" then
		for _, k in ipairs(payload.kits) do
			local raw = tostring(k.name or k.kit or "")
			if raw ~= "" then
				local key = resolveKitKey(raw)
				if key then
					local times = math.max(1, math.floor(tonumber(k.count or 1) or 1))
					expandKit(key, times, acc)
					filled = true
				end
			end
		end
	end

	-- 단일 kit
	if not filled and type(payload.kit) == "string" then
		local key = resolveKitKey(payload.kit)
		if key then
			local times = math.max(1, math.floor(tonumber(payload.count or 1) or 1))
			expandKit(key, times, acc)
			filled = true
		end
	end

	-- 개별 items
	if type(payload.items) == "table" then
		for _, it in ipairs(payload.items) do
			local nm = tostring(it.name or "")
			local ct = tonumber(it.count or 1) or 1
			if nm ~= "" and ct > 0 then
				mergeItem(acc, nm, math.clamp(ct, 1, 999999))
				filled = true
			end
		end
	end

	if not filled then
		if RESULT then RESULT:FireClient(sender, false, "지급 목록 또는 킷이 비어있음/해석 불가") end
		return
	end

	local items = flattenItems(acc)
	deliverToClient(target :: Player, items)
	if RESULT then
		RESULT:FireClient(sender, true, ("지급 완료: %s → %d개 항목"):format((target :: Player).Name, #items))
	end
end)

-- ===== 채팅 명령 =====
local function reply(plr: Player, ok: boolean, msg: string)
	if RESULT then RESULT:FireClient(plr, ok, msg) end
end

local function cmdGrant(plr: Player, tokens: {string})
	if #tokens < 4 then
		reply(plr, false, "형식: !grant <player> <count> <item name>")
		return
	end
	local targetTok = tokens[2]
	local count = tonumber(tokens[3]) or 1
	local itemName = table.concat(tokens, " ", 4)

	local target = findPlayerByAny(targetTok)
	if not target then
		reply(plr, false, "대상 플레이어 없음")
		return
	end

	local acc: {[string]: number} = {}
	mergeItem(acc, itemName, math.max(1, math.floor(count)))
	deliverToClient(target, flattenItems(acc))
	reply(plr, true, ("지급 완료: %s x%d → %s"):format(itemName, count, target.Name))
end

local function cmdGrantKit(plr: Player, tokens: {string})
	if #tokens < 3 then
		reply(plr, false, "형식: !grantkit <player> <kit name [xN]>")
		return
	end
	local targetTok = tokens[2]
	local target = findPlayerByAny(targetTok)
	if not target then
		reply(plr, false, "대상 플레이어 없음")
		return
	end

	local nameTokens = {}
	for i = 3, #tokens do table.insert(nameTokens, tokens[i]) end
	local rawName, mult = parseTrailingMultiplier(nameTokens)
	local key = resolveKitKey(rawName)
	if not key then
		reply(plr, false, ("알 수 없는 킷: %s"):format(rawName))
		return
	end

	local acc: {[string]: number} = {}
	expandKit(key, mult, acc)
	deliverToClient(target, flattenItems(acc))
	reply(plr, true, ("킷 지급 완료: %s x%d → %s"):format(key, mult, target.Name))
end

local function cmdListKits(plr: Player)
	local keys = {}
	for k, _ in pairs(KITS) do table.insert(keys, k) end
	table.sort(keys)
	reply(plr, true, ("등록된 킷: %s"):format(table.concat(keys, ", ")))
end

local function onChatted(plr: Player, msg: string)
	if not isAdmin(plr) then return end
	msg = msg or ""
	if msg:match("^!grant%s+") then
		local tokens = {}
		for w in msg:gmatch("%S+") do table.insert(tokens, w) end
		cmdGrant(plr, tokens)
		return
	end
	if msg:match("^!grantkit%s+") or msg:match("^!grantset%s+") then
		local tokens = {}
		for w in msg:gmatch("%S+") do table.insert(tokens, w) end
		cmdGrantKit(plr, tokens)
		return
	end
	if msg:match("^!kits$") then
		cmdListKits(plr)
		return
	end
end

Players.PlayerAdded:Connect(function(p)
	p.Chatted:Connect(function(msg) onChatted(p, msg) end)
end)
