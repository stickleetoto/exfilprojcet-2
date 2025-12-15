--!strict
-- StarterPlayerScripts/a.lua
-- (ViewModel hotkeys + mods + VM-only yaw + Ctrl+G anim/sequence + submodel attach + RMB ADS pose w/ CAS)
-- 기능 요약
--  - 숫자 1: 1번 슬롯 토글, 숫자 2(Shift 조합 Sink): 2번 슬롯 토글
--  - VM 보일 땐 캐릭터 Tool 파츠 가림, 숨기면 원복
--  - 장착 정보(ModsJson) 기반으로 뷰모델에 탄창 등 부착
--  - 뷰모델에서만 탄창에 Y축 +90° 추가 회전 (YawExtraDeg=90)
--  - Ctrl+G: 기본 스페셜 애니 / VM_buter일 때는 A→B→(B끝 2초 유지)→A 역재생 시퀀스
--  - 우클릭: 조준 애니(102299578490322) 전진 → 끝 포즈 고정, 우클릭 해제: 역재생 후 Idle 복귀 (CAS로 바인딩해 GUI/gpe 영향 최소화)
--  - RenderStep/입력/모듈 부재에 안전 가드

local ReplicatedStorage     = game:GetService("ReplicatedStorage")
local UserInputService      = game:GetService("UserInputService")
local ContextActionService  = game:GetService("ContextActionService")
local RunService            = game:GetService("RunService")
local Players               = game:GetService("Players")
local HttpService           = game:GetService("HttpService")

-- 선택 모듈 (없으면 안전 스텁으로 대체)
local WeaponMods:any = nil
local WeaponAttachSvc:any = nil
do
	local ok1, mod1 = pcall(function() return require(ReplicatedStorage:WaitForChild("WeaponMods")) end)
	WeaponMods = ok1 and mod1 or { Read = function(_: any): any return {} end }

	local ok2, mod2 = pcall(function() return require(ReplicatedStorage:WaitForChild("WeaponAttachService")) end)
	WeaponAttachSvc = ok2 and mod2 or { ApplyModsToModel = function(_: any, _: any) end }
end

local player  = Players.LocalPlayer
local camera  = workspace.CurrentCamera

-- 슬롯 이름(인벤토리 장비 슬롯 키와 일치)
local SLOT_PRIMARY1_NAME = "first weapon"
local SLOT_PRIMARY2_NAME = "first weapon2"

-- 뷰모델 프리셋(태그명 → VM 폴더 내 모델명)
local VIEWMODELS_FOLDER  = ReplicatedStorage:WaitForChild("ViewModels")
type Preset = { ModelName: string, IdleAnimId: string?, Offset: CFrame? }
local WeaponVMRegistry: {[string]: Preset} = {
	mcx        = { ModelName = "VM_MCX" },
	mcx_spear  = { ModelName = "VM_MCX_Spear" },
	m4a1       = { ModelName = "VM_M4A1" },
	ak74m      = { ModelName = "VM_AKM" },
	ak74       = { ModelName = "VM_AK" },
	ak12       = { ModelName = "VM_AK12" },
	mp7a1      = { ModelName = "VM_MP7" },
	mp5sd      = { ModelName = "VM_MP5SD" },
	mpx        = { ModelName = "VM_MPX" },
	fnfal      = { ModelName = "VM_FNFAL" },
	aa12       = { ModelName = "VM_AA12" },
	svdm       = { ModelName = "VM_SVD" },
	l96a1      = { ModelName = "VM_L96" },
	m82a1      = { ModelName = "VM_M82" },
	g17        = { ModelName = "VM_G17" },
	gunmin20ak47 = { ModelName = "VM_gunmin20ak47" },
	-- (기존 테이블에서 gojo 항목만 교체)
	gojo = { ModelName = "VM_gojo", IdleAnimId = "rbxassetid://73878165232358" }, -- ← 고죠 기본 아이들
	supersoaker50 = { ModelName = "VM_supersoaker50" },
	fgm = { ModelName = "VM_fgm" },
	buter = { ModelName = "VM_buter", IdleAnimId = "rbxassetid://127323293340568" },
	
}

local DEFAULT_IDLE_ANIM = "rbxassetid://107945350891209"
local DEFAULT_VM_OFFSET = CFrame.new(1, -3, -2)

local RENDER_BIND       = ("VM_Follow_%d"):format(player.UserId)
local ACTION1, ACTION2  = "VM_Toggle_Primary1", "VM_Toggle_Primary2"
local ACTION_GCTRL      = "VM_Play_GCtrl"
local ACTION_ADS        = "VM_ADS_RMB"      -- 우클릭 ADS (CAS)

local BIND_PRIORITY     = 150      -- 일반
local BIND_PRIORITY_2   = 5000     -- Shift+2 충돌 방지
local BIND_PRIORITY_3   = 4000     -- Ctrl+G

local SPECIAL_ANIM_ID   = "rbxassetid://109456308218380" -- 기본 Ctrl+G
-- VM_buter 전용 Ctrl+G 시퀀스
local BUTER_SEQ_A_ID    = "rbxassetid://113297957044056"
local BUTER_SEQ_B_ID    = "rbxassetid://112249756847851"

-- 우클릭 ADS
local AIM_ANIM_ID       = "rbxassetid://87152520713899"
local AIM_EPS           = 0.03 -- 끝/처음 프레임 근처에서 고정 여유

-- ===== 슬롯별 VM 캐시 =====
type VMRecord = {
	Model: Model,           -- VM 루트 (카메라에 붙음)
	WeaponModel: Model,     -- VM 내부의 실제 무기 서브모델(여기에 부착물 적용)
	Track: AnimationTrack,  -- Idle 루프 트랙
	WeaponKey: string,      -- 레지스트리 키
	Offset: CFrame,         -- 카메라 기준 위치
	Visible: boolean,

	-- ADS(조준) 제어 필드
	AimTrack: AnimationTrack?,         -- 조준 애니 트랙
	AimHoldConn: RBXScriptConnection?, -- 끝 프레임 고정용 Heartbeat 연결
	Aiming: boolean?,                  -- 현재 조준 상태 플래그

	-- Ctrl+G 시퀀스 중복 방지
	SpecialPlaying: boolean?,
}
local VMs: {[string]: VMRecord} = {}
local cachedIdleAnims: {[string]: Animation} = {}
local cachedCustomAnims: {[string]: Animation} = {}
local _debounce = false

-- ===== 유틸 =====
local function isTyping() return UserInputService:GetFocusedTextBox() ~= nil end
local function setModelVisible(m: Model, visible: boolean)
	for _, d in ipairs(m:GetDescendants()) do
		if d:IsA("BasePart") then d.LocalTransparencyModifier = visible and 0 or 1 end
	end
end
local function anyVMVisible(): boolean
	for _, rec in pairs(VMs) do if rec.Visible then return true end end
	return false
end
local function firstVisibleVM(): (string?, VMRecord?)
	for slot, rec in pairs(VMs) do
		if rec.Visible then return slot, rec end
	end
	return nil, nil
end
local function applyToolVisibilityByAnyVMVisible()
	local showTools = not anyVMVisible()
	local char = player.Character
	if not char then return end
	for _, tool in ipairs(char:GetChildren()) do
		if tool:IsA("Tool") then
			for _, d in ipairs(tool:GetDescendants()) do
				if d:IsA("BasePart") then d.LocalTransparencyModifier = showTools and 0 or 1 end
			end
		end
	end
end

-- 태그에서 무기 키 추출
local function getTagsFromItemGui(gui: Instance?): {string}
	if not gui then return {} end
	local ok, arr = pcall(function()
		local js = gui:GetAttribute("TagsJson")
		if typeof(js) ~= "string" or js == "" then return nil end
		return HttpService:JSONDecode(js)
	end)
	if ok and typeof(arr) == "table" then
		local out = {}
		for _, t in ipairs(arr) do table.insert(out, string.lower(tostring(t))) end
		return out
	end
	local t = gui:GetAttribute("Tag")
	if typeof(t) == "string" and t ~= "" then return { string.lower(t) } end
	return {}
end
local function pickWeaponNameTag(tags: {string}): string?
	for _, t in ipairs(tags) do if WeaponVMRegistry[t] then return t end end
	return nil
end

local function getEquipmentMap()
	local SlotMapRegistry = require(ReplicatedStorage:WaitForChild("SlotMapRegistry"))
	return SlotMapRegistry.Get and SlotMapRegistry.Get("Equipment") or nil
end
local function findEquipSlotByName(slotMap:any, slotName: string)
	if not slotMap then return nil end
	if slotMap[slotName] then return slotMap[slotName] end
	for k,v in pairs(slotMap) do
		if typeof(v)=="table" and (v.Name==slotName or k==slotName) then return v end
	end
	return nil
end
local function resolveWeaponKeyFromSlot(slotName: string): string?
	local equip = getEquipmentMap()
	local slotData = findEquipSlotByName(equip, slotName)
	if not slotData or not slotData.Frame or not slotData.EquippedItem then return nil end
	local tags = getTagsFromItemGui(slotData.EquippedItem)
	return pickWeaponNameTag(tags)
end
local function slotHasItem(slotName: string): boolean
	local equip = getEquipmentMap()
	local slotData = findEquipSlotByName(equip, slotName)
	return slotData ~= nil and slotData.EquippedItem ~= nil
end

-- 애니 로더
local function loadIdleTrack(animator: Animator, animId: string): AnimationTrack
	if not cachedIdleAnims[animId] then
		local a = Instance.new("Animation"); a.AnimationId = animId
		cachedIdleAnims[animId] = a
	end
	local track = animator:LoadAnimation(cachedIdleAnims[animId])
	track.Looped = true; track.Priority = Enum.AnimationPriority.Action
	return track
end
local function loadCustomTrack(animator: Animator, animId: string): AnimationTrack
	if not cachedCustomAnims[animId] then
		local a = Instance.new("Animation"); a.AnimationId = animId
		cachedCustomAnims[animId] = a
	end
	local track = animator:LoadAnimation(cachedCustomAnims[animId])
	track.Looped = false; track.Priority = Enum.AnimationPriority.Action2
	return track
end

-- VM 루트 모델 안에서 실제 무기 서브모델을 찾는다.
local function findWeaponSubModel(vm: Model): Model
	-- 1순위: 이름에 "model" 포함된 Model
	for _, ch in ipairs(vm:GetChildren()) do
		if ch:IsA("Model") and string.find(string.lower(ch.Name), "model") then
			return ch
		end
	end
	-- 2순위: 자손 중 "mag" 파트를 보유한 Model
	for _, ch in ipairs(vm:GetChildren()) do
		if ch:IsA("Model") and ch:FindFirstChild("mag", true) then
			return ch
		end
	end
	-- 폴백: 첫 번째 Model 또는 vm 자체
	return vm:FindFirstChildWhichIsA("Model") or vm
end

-- ===== 모딩 적용 (뷰모델 전용 회전 지시 포함) =====
local function applyModsToVM(slotName: string)
	local equip = getEquipmentMap()
	local slotData = findEquipSlotByName(equip, slotName)
	if not slotData or not slotData.EquippedItem then return end

	local mods:any = {}
	if WeaponMods and typeof(WeaponMods.Read) == "function" then
		local ok, res = pcall(function() return WeaponMods.Read(slotData.EquippedItem) end)
		if ok and typeof(res) == "table" then mods = res end
	end

	local rec = VMs[slotName]
	if rec and rec.WeaponModel and typeof(WeaponAttachSvc.ApplyModsToModel) == "function" then
		rec.WeaponModel:SetAttribute("YawExtraDeg", 90) -- VM에서만 Y +90°
		pcall(function() WeaponAttachSvc.ApplyModsToModel(rec.WeaponModel, mods) end)
	end
end

-- ===== VM 생성/캐시 =====
local function buildVM(slotName: string, weaponKey: string): VMRecord?
	local preset = WeaponVMRegistry[weaponKey]; if not preset then return nil end
	local template = VIEWMODELS_FOLDER:FindFirstChild(preset.ModelName)
	if not template or not template:IsA("Model") then return nil end

	local vm = template:Clone()
	vm.Name = ("ViewModel_%s"):format(slotName)
	vm.Parent = camera

	for _, d in ipairs(vm:GetDescendants()) do
		if d:IsA("BasePart") then
			d.CanCollide=false; d.CanQuery=false; d.CanTouch=false; d.Massless=true; d.CastShadow=false
		end
	end

	if not vm.PrimaryPart then
		vm.PrimaryPart = vm:FindFirstChild("Root") or vm:FindFirstChildWhichIsA("BasePart")
	end

	local weaponSub = findWeaponSubModel(vm)
	if not weaponSub.PrimaryPart then
		weaponSub.PrimaryPart = weaponSub:FindFirstChild("Root") or weaponSub:FindFirstChildWhichIsA("BasePart")
	end

	local ac = vm:FindFirstChildOfClass("AnimationController") or Instance.new("AnimationController"); ac.Parent = vm
	local animator = ac:FindFirstChildOfClass("Animator") or Instance.new("Animator"); animator.Parent = ac

	local idleId = preset.IdleAnimId or DEFAULT_IDLE_ANIM
	local offset = preset.Offset or DEFAULT_VM_OFFSET
	local track = loadIdleTrack(animator, idleId)

	setModelVisible(vm, false)
	local rec: VMRecord = {
		Model = vm,
		WeaponModel = weaponSub,
		Track = track,
		WeaponKey = weaponKey,
		Offset = offset,
		Visible = false,
		AimTrack = nil,
		AimHoldConn = nil,
		Aiming = false,
		SpecialPlaying = false,
	}
	VMs[slotName] = rec

	applyModsToVM(slotName)
	return rec
end

-- 표시/숨김
local function showSlot(slotName: string)
	local rec = VMs[slotName]; if not rec then return end
	if rec.Visible then return end
	applyModsToVM(slotName)
	setModelVisible(rec.Model, true)
	if not rec.Track.IsPlaying then rec.Track:Play() end
	rec.Visible = true
	applyToolVisibilityByAnyVMVisible()
end
local function hideSlot(slotName: string)
	local rec = VMs[slotName]; if not rec then return end
	if not rec.Visible then return end

	-- ADS 정리
	if rec.AimHoldConn then rec.AimHoldConn:Disconnect(); rec.AimHoldConn = nil end
	if rec.AimTrack and rec.AimTrack.IsPlaying then pcall(function() rec.AimTrack:Stop(0.1) end) end
	rec.Aiming = false

	if rec.Track.IsPlaying then rec.Track:Stop() end
	setModelVisible(rec.Model, false)
	rec.Visible = false
	applyToolVisibilityByAnyVMVisible()
end
local function otherSlotName(slotName: string): string
	return (slotName == SLOT_PRIMARY1_NAME) and SLOT_PRIMARY2_NAME or SLOT_PRIMARY1_NAME
end

-- VM 위치 업데이트(렌더스텝)
pcall(function() RunService:UnbindFromRenderStep(RENDER_BIND) end) -- 중복 예방
RunService:BindToRenderStep(RENDER_BIND, Enum.RenderPriority.Camera.Value + 1, function()
	for _, rec in pairs(VMs) do
		if rec.Model and rec.Model.PrimaryPart then
			rec.Model:PivotTo(camera.CFrame * rec.Offset)
		end
	end
end)

-- 이동 컨트롤 강제 Enable 가드
local function enableControlsGuard()
	task.defer(function()
		local pm = player:FindFirstChild("PlayerScripts") and player.PlayerScripts:FindFirstChild("PlayerModule")
		if pm then
			local ok, mod = pcall(require, pm)
			if ok and mod and mod.GetControls then
				local controls = mod:GetControls()
				if controls and controls.Enable then pcall(function() controls:Enable() end) end
			end
		end
	end)
end

-- 슬롯 토글
local function toggleSlot(slotName: string)
	if _debounce then return end
	_debounce = true

	local ok, wKey = pcall(resolveWeaponKeyFromSlot, slotName)
	if not ok then _debounce=false; return end
	if not wKey then hideSlot(slotName); _debounce=false; return end

	local rec = VMs[slotName]
	if not rec or rec.WeaponKey ~= wKey then
		if rec and rec.Model then pcall(function() rec.Model:Destroy() end) end
		VMs[slotName] = nil
		rec = buildVM(slotName, wKey)
		if not rec then _debounce=false; return end
	end

	if rec.Visible then
		hideSlot(slotName)
	else
		hideSlot(otherSlotName(slotName))
		showSlot(slotName)
	end

	enableControlsGuard()
	_debounce = false
end

-- ===== 애니/Animator 핸들 =====
local function getAnimator(rec: VMRecord?): Animator?
	if not rec then return nil end
	local ac = rec.Model and rec.Model:FindFirstChildOfClass("AnimationController")
	return ac and ac:FindFirstChildOfClass("Animator") or nil
end

-- 공용 트랙 보장
local function ensureTrack(animator: Animator, animId: string): AnimationTrack
	local tr = loadCustomTrack(animator, animId)
	tr.Looped = false
	tr.Priority = Enum.AnimationPriority.Action2
	return tr
end

-- 정방향 재생 후 자연 정지 대기
local function playForwardAndWait(tr: AnimationTrack)
	tr.Looped = false
	tr.TimePosition = 0
	tr:Play(0.05)
	tr:AdjustSpeed(1)
	local done = Instance.new("BindableEvent")
	local conn; conn = tr.Stopped:Connect(function() done:Fire() end)
	done.Event:Wait()
	conn:Disconnect()
end

-- 역재생: 끝 근처에서 시작해 0 근처에서 정지
local function playReverseAndWait(tr: AnimationTrack)
	tr.Looped = false
	-- 길이 로드 대기(안전)
	local t0 = time()
	while tr.Length == 0 and time() - t0 < 1.0 do RunService.Heartbeat:Wait() end
	local len = tr.Length > 0 and tr.Length or 0.5
	tr.TimePosition = math.max(0, len - 0.02)
	tr:Play(0.0)
	tr:AdjustSpeed(-1)
	while tr.IsPlaying and tr.TimePosition > 0.02 do RunService.Heartbeat:Wait() end
	tr:Stop(0.05)
end

-- 끝 프레임을 지정 시간만큼 '고정' 유지 (시퀀스용)
local function holdAtEnd(tr: AnimationTrack, seconds: number, eps: number?)
	eps = eps or 0.02
	-- 길이 로드 보장
	local t0 = time()
	while tr.Length == 0 and time() - t0 < 1.0 do RunService.Heartbeat:Wait() end
	local len = tr.Length > 0 and tr.Length or 0.5

	-- 끝 프레임 근처로 점프해 속도 0으로 고정
	tr:Play(0.0)
	tr.TimePosition = math.max(0, len - eps)
	tr:AdjustSpeed(0)

	-- 유지
	task.wait(math.max(0, seconds))

	-- 영향 제거(부드럽게 블렌드 아웃)
	tr:Stop(0.05)
end

-- ===== Ctrl+G: 현재 보이는 VM에 스페셜 애니 / buter 시퀀스 재생 =====
local function loadCustomTrackOnRec(rec: VMRecord, animId: string): AnimationTrack?
	local animator = getAnimator(rec); if not animator then return nil end
	local tr = loadCustomTrack(animator, animId)
	return tr
end

local function playButerSequence(rec: VMRecord): boolean
	if rec.SpecialPlaying then return false end
	rec.SpecialPlaying = true

	task.spawn(function()
		local animator = getAnimator(rec)
		if not animator then rec.SpecialPlaying=false; return end

		local A = ensureTrack(animator, BUTER_SEQ_A_ID)
		local B = ensureTrack(animator, BUTER_SEQ_B_ID)

		-- Idle 블렌딩 보장
		if rec.Track and not rec.Track.IsPlaying then
			pcall(function() rec.Track:Play() end)
		end

		-- A 정방향 → B 정방향 → (B 끝 포즈 2초 유지) → A 역재생
		playForwardAndWait(A)
		playForwardAndWait(B)
		holdAtEnd(B, 2.0)   -- ★ 마지막 포즈 2초 유지
		playReverseAndWait(A)

		-- Idle 유지(이미 루프 중)
		rec.SpecialPlaying = false
	end)

	return true
end

local function playSpecialOnVisibleVM(): boolean
	local _, rec = firstVisibleVM()
	if not rec then return false end

	-- VM_buter 전용 분기
	if string.lower(rec.WeaponKey or "") == "buter" then
		return playButerSequence(rec)
	end

	-- 기본: 단일 스페셜 애니 재생
	local track = loadCustomTrackOnRec(rec, SPECIAL_ANIM_ID)
	if not track then return false end
	if track.IsPlaying then pcall(function() track:Stop(0.05) end) end
	pcall(function() track:Play(0.1) end)
	return true
end

-- ===== RMB 조준: 전진 → 끝 프레임 직전 고정 → 해제 시 역재생 =====
local function ensureAimTrack(rec: VMRecord): AnimationTrack?
	if rec.AimTrack and rec.AimTrack.Parent then return rec.AimTrack end
	local animator = getAnimator(rec); if not animator then return nil end
	local tr = loadCustomTrack(animator, AIM_ANIM_ID)
	tr.Looped = false
	tr.Priority = Enum.AnimationPriority.Action2
	rec.AimTrack = tr
	return tr
end

local function aimBegin()
	local _, rec = firstVisibleVM()
	if not rec or not rec.Model then return end
	if rec.Aiming then return end
	local tr = ensureAimTrack(rec); if not tr then return end

	-- 혹시 이전 연결이 남아있다면 정리
	if rec.AimHoldConn then rec.AimHoldConn:Disconnect(); rec.AimHoldConn = nil end

	-- 전진 재생 시작
	pcall(function()
		tr:Stop(0.05)
		tr.TimePosition = 0
		tr:Play(0.1)
		tr:AdjustSpeed(1.0)
	end)

	-- 끝 프레임 직전에서 속도 0으로 고정(마지막 포즈 유지)
	rec.AimHoldConn = RunService.Heartbeat:Connect(function()
		if not tr.IsPlaying then return end
		local len = tr.Length
		if len > 0 and tr.TimePosition >= (len - AIM_EPS) then
			tr.TimePosition = math.max(0, len - AIM_EPS)
			tr:AdjustSpeed(0)
		end
	end)

	rec.Aiming = true
end

local function aimEnd()
	local _, rec = firstVisibleVM()
	if not rec or not rec.Aiming then return end
	local tr = rec.AimTrack
	if not tr then return end

	-- 고정 연결 해제
	if rec.AimHoldConn then rec.AimHoldConn:Disconnect(); rec.AimHoldConn = nil end

	-- 역재생: 끝 근처에서 시작 → 0 근처 도달 시 Stop
	pcall(function()
		if not tr.IsPlaying then tr:Play(0) end
		local len = tr.Length
		if len > 0 then
			tr.TimePosition = math.min(tr.TimePosition, math.max(0, len - AIM_EPS))
		end
		tr:AdjustSpeed(-1.0)
	end)

	-- 0프레임 근처에서 정지
	local stopConn: RBXScriptConnection? = nil
	stopConn = RunService.Heartbeat:Connect(function()
		if not tr.IsPlaying then
			if stopConn then stopConn:Disconnect() end
			return
		end
		if tr.TimePosition <= AIM_EPS then
			if stopConn then stopConn:Disconnect() end
			pcall(function() tr:Stop(0.05) end) -- Idle만 남기기
		end
	end)

	rec.Aiming = false
end

-- 입력 핸들러(키/조합)
local function onAction1(_name, state, _obj)
	if state ~= Enum.UserInputState.Begin or isTyping() then return Enum.ContextActionResult.Pass end
	task.defer(toggleSlot, SLOT_PRIMARY1_NAME)
	return Enum.ContextActionResult.Pass
end

local function onAction2(_name, state, _obj)
	if state ~= Enum.UserInputState.Begin or isTyping() then return Enum.ContextActionResult.Pass end
	local shiftDown = UserInputService:IsKeyDown(Enum.KeyCode.LeftShift)
		or UserInputService:IsKeyDown(Enum.KeyCode.RightShift)

	task.defer(toggleSlot, SLOT_PRIMARY2_NAME)
	enableControlsGuard()

	if shiftDown and slotHasItem(SLOT_PRIMARY2_NAME) then
		return Enum.ContextActionResult.Sink
	end
	return Enum.ContextActionResult.Pass
end

local function onActionGCtrl(_name, state, _obj)
	if state ~= Enum.UserInputState.Begin or isTyping() then return Enum.ContextActionResult.Pass end
	local ctrlDown = UserInputService:IsKeyDown(Enum.KeyCode.LeftControl)
		or UserInputService:IsKeyDown(Enum.KeyCode.RightControl)
	if not ctrlDown then return Enum.ContextActionResult.Pass end

	if playSpecialOnVisibleVM() then
		return Enum.ContextActionResult.Sink
	end
	return Enum.ContextActionResult.Pass
end

-- 우클릭(마우스 버튼 2): 조준 시작/해제 (CAS로 바인딩해 GUI/gpe 영향 최소화)
local function onAdsAction(_name, state, _obj)
	if isTyping() then return Enum.ContextActionResult.Pass end
	if state == Enum.UserInputState.Begin then
		aimBegin()
		return Enum.ContextActionResult.Sink
	elseif state == Enum.UserInputState.End then
		aimEnd()
		return Enum.ContextActionResult.Sink
	end
	return Enum.ContextActionResult.Pass
end

-- 바인딩
ContextActionService:BindActionAtPriority(ACTION1,      onAction1,    false, BIND_PRIORITY,    Enum.KeyCode.One)
ContextActionService:BindActionAtPriority(ACTION2,      onAction2,    false, BIND_PRIORITY_2,  Enum.KeyCode.Two)
ContextActionService:BindActionAtPriority(ACTION_GCTRL, onActionGCtrl,false, BIND_PRIORITY_3,  Enum.KeyCode.G)
ContextActionService:BindActionAtPriority(ACTION_ADS,   onAdsAction,  false, BIND_PRIORITY_3-100, Enum.UserInputType.MouseButton2)

-- 캐릭터 리셋 시 초기화
local function onCharacterAdded()
	for slot, _ in pairs(VMs) do hideSlot(slot) end
	applyToolVisibilityByAnyVMVisible()
end
if player.Character then onCharacterAdded() end
player.CharacterAdded:Connect(onCharacterAdded)

-- 정리
script.Destroying:Connect(function()
	ContextActionService:UnbindAction(ACTION1)
	ContextActionService:UnbindAction(ACTION2)
	ContextActionService:UnbindAction(ACTION_GCTRL)
	ContextActionService:UnbindAction(ACTION_ADS)
	for _, rec in pairs(VMs) do
		if rec.AimHoldConn then rec.AimHoldConn:Disconnect() end
		if rec.AimTrack and rec.AimTrack.IsPlaying then pcall(function() rec.AimTrack:Stop() end) end
		if rec.Track and rec.Track.IsPlaying then pcall(function() rec.Track:Stop() end) end
		if rec.Model then pcall(function() rec.Model:Destroy() end) end
	end
	table.clear(VMs)
	pcall(function() RunService:UnbindFromRenderStep(RENDER_BIND) end)
end)
