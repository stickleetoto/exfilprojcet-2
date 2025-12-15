--!strict
-- GunClient.lua (타르코프식: 조끼 탄창만 사용, 중간 리로드 시 "쓴 탄창"을 조끼로 배출)
-- - 루즈탄 스택은 리로드 때 건드리지 않음
-- - 0발 자동 배출 없음(원하면 EJECT_EMPTY_ON_ZERO=true)

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")
local UserInputService = game:GetService("UserInputService")
local HttpService = game:GetService("HttpService")
local Debris = game:GetService("Debris")

local player = Players.LocalPlayer
local camera = workspace.CurrentCamera
local reloadLockUntil = 0

-- 설정
local EJECT_EMPTY_ON_ZERO = false -- 0발 시 자동 배출 비활성화(타르코프 감성)

-- 모듈
local AmmoCatalog = require(ReplicatedStorage:WaitForChild("AmmoCatalog"))
local GunConfig   = require(ReplicatedStorage:WaitForChild("GunConfig"))

local function tryRequire(name:string)
	local ok, mod = pcall(function() return require(ReplicatedStorage:WaitForChild(name, 0.5)) end)
	if ok then return mod end
	return nil
end
local WeaponAttachService = tryRequire("WeaponAttachService")
local SlotMapRegistry     = tryRequire("SlotMapRegistry")
local StackBadge          = tryRequire("StackBadge")

-- Remotes
local Remotes = ReplicatedStorage:FindFirstChild("Remotes")
if not Remotes then Remotes = Instance.new("Folder"); Remotes.Name="Remotes"; Remotes.Parent=ReplicatedStorage end

local FireBullet  = Remotes:FindFirstChild("FireBullet") :: RemoteEvent?
if not FireBullet then local ev=Instance.new("RemoteEvent"); ev.Name="FireBullet"; ev.Parent=Remotes; FireBullet=ev end
local RequestReload = Remotes:FindFirstChild("RequestReload") :: RemoteFunction?
local ApplyReload   = Remotes:FindFirstChild("ApplyReload")   :: RemoteEvent?
local BulletFired   = Remotes:FindFirstChild("BulletFired")   :: RemoteEvent?
if not BulletFired then local ev=Instance.new("RemoteEvent"); ev.Name="BulletFired"; ev.Parent=Remotes; BulletFired=ev end

-- 유틸
local function updateStackBadge(gui:GuiObject?)
	if StackBadge and gui then pcall(function() (StackBadge :: any).Update(gui) end) end
end

local function _findFirstDescendantByNames(root: Instance, names:{string}): Instance?
	for _, n in ipairs(names) do
		local ins = root:FindFirstChild(n, true)
		if ins then return ins end
	end
	for _, d in ipairs(root:GetDescendants()) do
		for _, n in ipairs(names) do
			if string.lower(d.Name) == string.lower(n) then return d end
		end
	end
	return nil
end

local MUZZLE_CANDIDATE_NAMES = { "MUZZLE","Muzzle","MuzzlePoint","Muzzle_Att","MuzzleAttachment" }
local function getMuzzleWorldCFrameFromVM(vm: Model): CFrame?
	local mu = _findFirstDescendantByNames(vm, MUZZLE_CANDIDATE_NAMES)
	if not mu then return nil end
	if mu:IsA("Attachment") then return (mu :: Attachment).WorldCFrame end
	if mu:IsA("BasePart") then return (mu :: BasePart).CFrame end
	return nil
end

local function readTagsJson(gui: Instance?): {[string]: boolean}
	local t : {[string]: boolean} = {}
	if not gui then return t end
	local Http = HttpService
	local tj = gui:GetAttribute("TagsJson")
	if typeof(tj) == "string" and #tj > 0 then
		local ok, arr = pcall(function() return Http:JSONDecode(tj) end)
		if ok and typeof(arr) == "table" then
			for _, s in ipairs(arr) do t[string.lower(tostring(s))] = true end
		end
	end
	local tag = gui:GetAttribute("Tag")
	if typeof(tag) == "string" and #tag > 0 then t[string.lower(tag)] = true end
	return t
end

-- 뷰모델 & 장착 GUI
local function getVisibleVM(): (Model?, string?)
	for _, m in ipairs(camera:GetChildren()) do
		if m:IsA("Model") and m.Name:sub(1,10)=="ViewModel_" then
			local bp = m:FindFirstChildWhichIsA("BasePart", true)
			if bp and bp.LocalTransparencyModifier < 0.99 then
				return m, m.Name:sub(11)
			end
		end
	end
	return nil,nil
end

local function getEquippedGui(slotName:string?): GuiObject?
	if not slotName then return nil end
	if SlotMapRegistry then
		local ok, equip = pcall(function()
			return (SlotMapRegistry.Get and SlotMapRegistry.Get("Equipment"))
				or (SlotMapRegistry :: any).Equipment
		end)
		if ok and equip and equip[slotName] and equip[slotName].EquippedItem then
			return equip[slotName].EquippedItem
		end
	end
	local pg = player:FindFirstChildOfClass("PlayerGui")
	if not pg then return nil end
	for _, g in ipairs(pg:GetDescendants()) do
		if g:IsA("GuiObject") and g:GetAttribute("Id") and string.find(string.lower(g.Name), string.lower(slotName or ""), 1, true) then
			return g
		end
	end
	return nil
end

-- 탄/탄창 상태
local function readAmmoState(weaponKey:string, slotName:string?): (boolean, number, string, string)
	local spec = GunConfig.Get(weaponKey)
	if not spec then return false,0,"","" end
	local g = getEquippedGui(slotName)
	local hasMag = (g and g:GetAttribute("HasMag")==true) or false
	local ammoId = (g and (g:GetAttribute("AmmoId") or g:GetAttribute("ChamberAmmoId"))) or spec.defaultAmmoId
	local caliber = spec.caliber
	local left = tonumber(g and g:GetAttribute("AmmoInMag")) or (hasMag and spec.magSize or 0)
	if g then g:SetAttribute("AmmoInMag", left) end
	return hasMag, left, tostring(ammoId), caliber
end
local function writeAmmoState(slotName:string?, newLeft:number)
	local g = getEquippedGui(slotName)
	if g then g:SetAttribute("AmmoInMag", math.max(0, math.floor(newLeft))) end
end

-- 타 유저 총구섬광 레이
if BulletFired then
	BulletFired.OnClientEvent:Connect(function(data)
		if type(data) ~= "table" then return end
		if tonumber(data.shooter) == player.UserId then return end
		local dir = data.direction
		local len = (dir * 16).Magnitude
		local beam = Instance.new("Part")
		beam.Anchored, beam.CanCollide, beam.Material = true, false, Enum.Material.Neon
		beam.Color = Color3.new(1,1,0.8)
		beam.Size  = Vector3.new(0.06,0.06,len)
		local origin = data.origin
		local cf = CFrame.new(origin, origin + dir) * CFrame.new(0,0,-len/2)
		beam.CFrame = cf
		beam.Parent = workspace
		Debris:AddItem(beam, 0.08)
	end)
end

-- 발사 모드
local function getMode(weaponKey:string, slotName:string?): string
	local spec = GunConfig.Get(weaponKey)
	if not spec then return "semi" end
	local g = getEquippedGui(slotName)
	local m = g and (g:GetAttribute("FireMode")) or spec.modes[1]
	local ok=false
	for _, s in ipairs(spec.modes) do if s==m then ok=true break end end
	return ok and m or spec.modes[1]
end
local function cycleMode(weaponKey:string, slotName:string?)
	local spec = GunConfig.Get(weaponKey); if not (spec and slotName) then return end
	local cur = getMode(weaponKey, slotName)
	local idx = 1
	for i,s in ipairs(spec.modes) do if s==cur then idx=i break end end
	local nxt = spec.modes[(idx % #spec.modes)+1]
	local g = getEquippedGui(slotName)
	if g then g:SetAttribute("FireMode", nxt) end
end

-- 반동
local recoilPitch, recoilYaw, recoilRoll = 0, 0, 0
local recoilDecay = 10
local lastUpdate = time()
local function addRecoil(p:number?, y:number?, r:number?)
	local pch = tonumber(p) or 1.8
	local yaw = tonumber(y) or 0.6
	local rol = tonumber(r) or 0.25
	recoilPitch += math.rad(pch)
	recoilYaw   += math.rad((math.random()-0.5)*2*yaw)
	recoilRoll  += math.rad((math.random()-0.5)*2*rol)
end
local BIND = ("VM_Recoil_%d"):format(player.UserId)
pcall(function() RunService:UnbindFromRenderStep(BIND) end)
RunService:BindToRenderStep(BIND, Enum.RenderPriority.Last.Value, function()
	local now = time()
	local dt = math.clamp(now - lastUpdate, 0, 0.05)
	lastUpdate = now
	local decay = math.exp(-recoilDecay * dt)
	recoilPitch *= decay; recoilYaw *= decay; recoilRoll *= decay
	local vm = select(1, getVisibleVM())
	if vm and vm:IsA("Model") then
		local base = vm:GetPivot()
		vm:PivotTo(base * CFrame.Angles(-recoilPitch, recoilYaw, recoilRoll))
	end
end)

-- 발사
local firing, blockUntil = false, 0.0
local function canFireNow() return time() >= blockUntil end
local function rpmToDelay(rpm:number):number return 60 / math.max(1, rpm) end

local function currentWeaponKeyFromVisibleVM(): (string?, string?)
	local vm, slot = getVisibleVM()
	if not (vm and slot) then return nil,nil end
	local g = getEquippedGui(slot)
	if g then
		local tags = readTagsJson(g)
		for key,_ in pairs(GunConfig.DB) do
			if tags[string.lower(key)] then return string.lower(key), slot end
		end
		local tag = g:GetAttribute("Tag")
		if typeof(tag)=="string" and (GunConfig.DB :: any)[string.lower(tag)] then
			return string.lower(tag), slot
		end
	end
	for key,_ in pairs(GunConfig.DB) do
		if string.find(string.lower(vm.Name), string.lower(key), 1, true) then
			return string.lower(key), slot
		end
	end
	return nil, slot
end

-- 조끼 컨테이너/아이템 탐색
local VEST_KEYS = { "vest","rig","chest","carrier","platecarrier","strandhogg","pc","chestrig" }
local function getVestContainerOf(gui:GuiObject):Instance?
	local p: Instance? = gui and gui.Parent
	while p and not (p:IsA("ScrollingFrame") or p:IsA("Frame")) do p = p.Parent end
	return p
end
local function iterVestItems(): {GuiObject}
	local out = {}
	if SlotMapRegistry then
		for _, key in ipairs(VEST_KEYS) do
			local map=nil
			pcall(function()
				map = (SlotMapRegistry.Get and SlotMapRegistry.Get(key))
					or (SlotMapRegistry.GetMap and SlotMapRegistry.GetMap(key))
			end)
			if map then
				local container = map.GuiContainer or map.Container or map.Root
				if container then
					for _, d in ipairs(container:GetDescendants()) do
						if d:IsA("GuiObject") and d:GetAttribute("Id") then table.insert(out, d) end
					end
				elseif map.Items then
					for _, it in pairs(map.Items) do
						if typeof(it)=="Instance" and it:IsA("GuiObject") then table.insert(out, it) end
					end
				end
			end
		end
	end
	if #out==0 then
		local pg = player:FindFirstChildOfClass("PlayerGui")
		if pg then
			for _, f in ipairs(pg:GetDescendants()) do
				if f:IsA("Frame") or f:IsA("ScrollingFrame") then
					local n = string.lower(f.Name)
					for _, key in ipairs(VEST_KEYS) do
						if string.find(n, key, 1, true) then
							for _, c in ipairs(f:GetDescendants()) do
								if c:IsA("GuiObject") and c:GetAttribute("Id") then table.insert(out, c) end
							end
						end
					end
				end
			end
		end
	end
	return out
end
local function isMagazine(gui:Instance?):boolean
	if not gui then return false end
	if gui:GetAttribute("ItemType")=="Mag" then return true end
	for k,_ in pairs(readTagsJson(gui)) do if string.find(k,"mag",1,true) then return true end end
	return false
end
local function caliberOfMagazine(gui:Instance?):string?
	if not gui then return nil end
	local cal = gui:GetAttribute("MagCaliber")
	if typeof(cal)=="string" and #cal>0 then return cal end
	for k,_ in pairs(readTagsJson(gui)) do
		if string.sub(k,1,4)=="cal:" then return string.sub(k,5) end
	end
	return nil
end
local function getCount(gui:GuiObject):number return tonumber(gui:GetAttribute("Count")) or 0 end
local function setCount(gui:GuiObject, n:number)
	gui:SetAttribute("Count", math.max(0, math.floor(n)))
	updateStackBadge(gui)
end

-- 스택에서 1개 떼어내기(탄창)
local function splitOneFromStack(stackGui:GuiObject):GuiObject?
	local cnt = getCount(stackGui); if cnt <= 1 then return nil end
	local container = getVestContainerOf(stackGui); if not container then return nil end
	setCount(stackGui, cnt-1)
	local single = stackGui:Clone()
	single.Name = stackGui.Name.."_single"
	single.Parent = container
	single.Visible = true
	single:SetAttribute("Count", nil)
	updateStackBadge(single)
	-- 만탄 가정(모델 메타 따라감)
	local cap = tonumber(stackGui:GetAttribute("MagCap")) or tonumber(single:GetAttribute("MagCap")) or 0
	if cap>0 then single:SetAttribute("AmmoInMag", cap) end
	local aid = stackGui:GetAttribute("AmmoId") or single:GetAttribute("AmmoId")
	if aid then single:SetAttribute("AmmoId", aid) end
	if not single:GetAttribute("Id") then single:SetAttribute("Id", HttpService:GenerateGUID(false)) end
	-- 모델명 전파
	local modelName = stackGui:GetAttribute("MagModelName") or stackGui:GetAttribute("ModelName")
	if typeof(modelName)=="string" and #modelName>0 then single:SetAttribute("MagModelName", modelName) end
	return single
end

-- 가장 “탄 많이 든” 호환 탄창 선택
local function findBestVestMagazine(caliber:string):GuiObject?
	local best:GuiObject? = nil
	local bestAmmo = -1
	for _, gui in ipairs(iterVestItems()) do
		if isMagazine(gui) then
			local cal = caliberOfMagazine(gui) or gui:GetAttribute("Caliber")
			if string.lower(tostring(cal or "")) == string.lower(tostring(caliber or "")) then
				local left = tonumber(gui:GetAttribute("AmmoInMag")) or 0
				local cnt  = getCount(gui)
				if cnt>1 then
					local cap = tonumber(gui:GetAttribute("MagCap")) or 0
					left = math.max(left, cap)
				end
				if left > bestAmmo then best, bestAmmo = gui, left end
			end
		end
	end
	return best
end

-- 시각: mag 파츠 제거
local MAG_PART_NAMES = { "mag","Mag","MAG","magazine","Magazine","MagPart" }
local function _collectMagPartsUnder(root: Instance): {BasePart}
	local list : {BasePart} = {}
	for _, d in ipairs(root:GetDescendants()) do
		if d:IsA("BasePart") then
			local n = string.lower(d.Name)
			for _, k in ipairs(MAG_PART_NAMES) do
				if n == string.lower(k) then table.insert(list, d :: BasePart); break end
			end
		end
	end
	return list
end
local function _destroyAllMagPartsUnder(root: Instance): number
	local n = 0
	for _, p in ipairs(_collectMagPartsUnder(root)) do n += 1; pcall(function() p:Destroy() end) end
	return n
end
local function clearMagVisuals(slotName: string)
	if WeaponAttachService and (WeaponAttachService.ClearMagazineForSlot or WeaponAttachService.ClearForSlot) then
		pcall(function()
			if WeaponAttachService.ClearMagazineForSlot then WeaponAttachService.ClearMagazineForSlot(slotName)
			else WeaponAttachService.ClearForSlot(slotName) end
		end)
	end
	local vm = select(1, getVisibleVM())
	if vm and vm:IsA("Model") then _destroyAllMagPartsUnder(vm) end
	local g = getEquippedGui(slotName)
	if g then
		for _, vpf in ipairs(g:GetDescendants()) do
			if vpf:IsA("ViewportFrame") then
				for _, ch in ipairs(vpf:GetDescendants()) do
					if ch.ClassName == "Model" or ch.ClassName == "WorldModel" then _destroyAllMagPartsUnder(ch) end
				end
			end
		end
	end
end

-- 조끼에 “빈/쓴 탄창” 넣기
local function spawnUsedMagInVest(container: Instance, template: GuiObject?, caliber: string, cap: number, ammoId: string?, roundsLeft: number, modelName: string?)
	local gui: GuiObject
	if template then
		gui = template:Clone()
	else
		local f = Instance.new("Frame"); f.Size = UDim2.fromOffset(64,64); f.BackgroundTransparency = 0.5; gui = f
	end
	gui.Parent = container; gui.Visible=true
	gui:SetAttribute("Count", nil)
	gui:SetAttribute("Id", HttpService:GenerateGUID(false))
	gui:SetAttribute("ItemType", "Mag")
	gui:SetAttribute("MagCaliber", caliber)
	gui:SetAttribute("MagCap", math.max(0, cap))
	gui:SetAttribute("AmmoInMag", math.max(0, math.min(roundsLeft, cap)))
	gui:SetAttribute("AmmoId", ammoId or "")
	if typeof(modelName)=="string" and #modelName>0 then
		gui:SetAttribute("MagModelName", modelName)
	end
	updateStackBadge(gui)
	return gui
end

local function forceRefresh(guiOrContainer: Instance?)
	if not guiOrContainer then return end
	local p = guiOrContainer.Parent
	if p then guiOrContainer.Parent = nil; guiOrContainer.Parent = p end
	guiOrContainer:SetAttribute("DirtyTick", os.clock())
end

local function findVestGuiById(idStr: string): GuiObject?
	if idStr == "" then return nil end
	for _, gui in ipairs(iterVestItems()) do
		local gid = tostring(gui:GetAttribute("Id") or "")
		if gid == idStr then return gui end
	end
	return nil
end

if ApplyReload then
	ApplyReload.OnClientEvent:Connect(function(payload)
		local removeMagId = payload and payload.removeMagId
		if typeof(removeMagId) ~= "string" or removeMagId == "" then return end
		local mag = findVestGuiById(removeMagId)
		if mag then
			local cont = getVestContainerOf(mag)
			pcall(function() mag:Destroy() end)
			forceRefresh(cont)
		end
	end)
end

-- 발사 구현
local function fireOne(weaponKey:string, slotName:string, spec:any, _mode:string)
	if not FireBullet then return end
	local hasMag, left, ammoId, caliber = readAmmoState(weaponKey, slotName)
	if not hasMag or left <= 0 then return end

	local vm, _ = getVisibleVM()
	local muzzleCF = vm and getMuzzleWorldCFrameFromVM(vm)
	local originCF = muzzleCF or camera.CFrame
	local origin   = originCF.Position
	local dir      = originCF.LookVector

	local pellets, spread = nil, nil
	if spec.pellets and spec.pelletSpread then pellets, spread = spec.pellets, spec.pelletSpread end

	FireBullet:FireServer({
		origin = origin, direction = dir,
		ammoId = ammoId, caliber = caliber,
		pellets = pellets, pelletSpread = spread,
		fromMuzzle = (muzzleCF ~= nil)
	})

	writeAmmoState(slotName, left - 1)

	-- 자동 배출 옵션(기본 false)
	if EJECT_EMPTY_ON_ZERO then
		local gWeapon = getEquippedGui(slotName)
		local nowLeft = math.max(0, left - 1)
		if nowLeft <= 0 and gWeapon then
			-- 자동 배출: 시각 제거 + 조끼로 0발 탄창 배출
			clearMagVisuals(slotName)
			local cap = tonumber(gWeapon:GetAttribute("MagCap")) or spec.magSize
			local containerSample: GuiObject? = nil
			for _, any in ipairs(iterVestItems()) do containerSample = any; break end
			if containerSample then
				local cont = getVestContainerOf(containerSample) or containerSample.Parent
				if cont then
					local tmpl: GuiObject? = nil
					for _, ch in ipairs(cont:GetChildren()) do if ch:IsA("GuiObject") then tmpl=ch; break end end
					spawnUsedMagInVest(cont, tmpl, tostring(caliber), cap, tostring(ammoId), 0, gWeapon:GetAttribute("MagModelName"))
					forceRefresh(cont)
				end
			end
			gWeapon:SetAttribute("HasMag", false)
			gWeapon:SetAttribute("AmmoInMag", 0)
		end
	end

	local r = spec.recoil
	addRecoil(r.pitchUp, r.randomYaw, r.randomRoll)
end

local function doFireLoop()
	while firing do
		if time() < reloadLockUntil then RunService.Heartbeat:Wait(); continue end
		local weaponKey, slot = currentWeaponKeyFromVisibleVM()
		if not (weaponKey and slot) then break end
		local spec = GunConfig.Get(weaponKey); if not spec then break end
		local mode = getMode(weaponKey, slot)
		local rpm  = spec.rpm[mode] or spec.rpm.semi or 600
		local shotDelay = rpmToDelay(rpm)

		if canFireNow() then
			if mode=="semi" then
				fireOne(weaponKey, slot, spec, mode); blockUntil = time() + shotDelay; break
			elseif string.sub(mode,1,5)=="burst" then
				local n = spec.burstCount or 3
				for _=1,n do if not firing then break end
					fireOne(weaponKey, slot, spec, mode)
					blockUntil = time() + shotDelay
					task.wait(shotDelay)
				end
			else
				fireOne(weaponKey, slot, spec, mode); blockUntil = time() + shotDelay
			end
		end
		RunService.Heartbeat:Wait()
	end
end

UserInputService.InputBegan:Connect(function(input, gpe)
	if gpe then return end
	if input.UserInputType == Enum.UserInputType.MouseButton1 then
		firing = true; task.spawn(doFireLoop)
	elseif input.KeyCode == Enum.KeyCode.V then
		local key, slot = currentWeaponKeyFromVisibleVM()
		if key and slot then cycleMode(key, slot) end
	end
end)
UserInputService.InputEnded:Connect(function(input, gpe)
	if gpe then return end
	if input.UserInputType == Enum.UserInputType.MouseButton1 then firing = false end
end)

-- 서버 리로드 승인(없으면 클라 단독 처리)
local function requestServerReload(slot:string, magGui:GuiObject):boolean
	if not RequestReload then return true end
	local ok, res = pcall(function()
		return RequestReload:InvokeServer({
			slot       = slot,
			magId      = tostring(magGui:GetAttribute("Id") or ""),
			consume    = true,   -- 조끼에서 그 탄창 한 개 소비
			returnOld  = "keep", -- 기존 탄창은 클라가 조끼로 되돌림
		})
	end)
	return ok and typeof(res)=="table" and (res :: any).ok==true
end

-- 리로드: 조끼 탄창만 사용 + 쓰던 탄창 되돌리기
local function reloadCurrentWeapon()
	local weaponKey, slot = currentWeaponKeyFromVisibleVM()
	if not (weaponKey and slot) then return end
	local spec = GunConfig.Get(weaponKey); if not spec then return end
	if time() < reloadLockUntil then return end

	-- 현재 무기 상태(되돌릴 탄창 스냅샷)
	local hasMag, curLeft, curAmmoId, caliber = readAmmoState(weaponKey, slot)
	local gWeapon = getEquippedGui(slot)
	local curCap  = tonumber(gWeapon and gWeapon:GetAttribute("MagCap")) or spec.magSize
	local curModelName = gWeapon and (gWeapon:GetAttribute("MagModelName") or gWeapon:GetAttribute("ModelName"))

	-- 1) 조끼에서 새 탄창 선정
	local vestMag = findBestVestMagazine(caliber); if not vestMag then return end
	local container = getVestContainerOf(vestMag) or vestMag.Parent

	-- 2) 스택이면 1개 분리
	local useMag: GuiObject = vestMag
	if getCount(vestMag) > 1 then
		local single = splitOneFromStack(vestMag)
		if not single then return end
		useMag = single
	end

	-- 3) 서버 승인
	if not requestServerReload(slot, useMag) then return end

	-- 4) 시각상: 기존 탄창 제거
	clearMagVisuals(slot)
	if gWeapon then gWeapon:SetAttribute("HasMag", false) end

	-- 5) 새 탄창 수치 읽기
	local newAmmoId = tostring(useMag:GetAttribute("AmmoId") or curAmmoId)
	local newCap    = tonumber(useMag:GetAttribute("MagCap")) or spec.magSize
	local newAmmo   = tonumber(useMag:GetAttribute("AmmoInMag")) or newCap
	if newAmmo <= 0 then newAmmo = newCap end

	-- 6) 무기 상태 갱신
	writeAmmoState(slot, math.min(newAmmo, newCap))
	if gWeapon then
		gWeapon:SetAttribute("HasMag", true)
		gWeapon:SetAttribute("AmmoId", newAmmoId)
		gWeapon:SetAttribute("MagCap", newCap)
		-- 새로 장착된 탄창의 모델명이 있다면 무기에 기록(다음에 되돌릴 때 쓰려고)
		local nm = useMag:GetAttribute("MagModelName") or useMag:GetAttribute("ModelName")
		if typeof(nm)=="string" and #nm>0 then gWeapon:SetAttribute("MagModelName", nm) end
	end

	-- 7) 시각: 새 탄창 장착
	if WeaponAttachService and WeaponAttachService.AttachMagazineForSlot then
		pcall(function() WeaponAttachService.AttachMagazineForSlot(slot, useMag) end)
	end

	-- 8) 사용한 탄창 GUI 삭제(조끼에서 1개 소비)
	local contBefore = getVestContainerOf(useMag) or container
	pcall(function() useMag:Destroy() end)
	forceRefresh(contBefore)

	-- 9) (중요) 루즈 탄 스택 소모 없음 ? 타르코프처럼 "미리 채워둔 탄창" 교체만 처리

	-- 10) 빼낸 기존 탄창을 “쓴 만큼 남은” 상태로 조끼에 생성
	if hasMag and container then
		local templateFor: GuiObject? = nil
		for _, d in ipairs(container:GetChildren()) do if d:IsA("GuiObject") then templateFor = d; break end end
		spawnUsedMagInVest(
			container,
			templateFor,
			tostring(caliber),
			tonumber(curCap) or spec.magSize,
			tostring(curAmmoId or ""),
			math.max(0, curLeft),
			(typeof(curModelName)=="string" and #tostring(curModelName)>0) and tostring(curModelName) or nil
		)
		forceRefresh(container)
	end

	reloadLockUntil = time() + (spec.reloadSec or 1.8)
end

-- 입력: R = 리로드
UserInputService.InputBegan:Connect(function(input, gpe)
	if gpe then return end
	if input.KeyCode == Enum.KeyCode.R then
		reloadCurrentWeapon()
	end
end)
