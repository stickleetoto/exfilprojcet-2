--!strict
-- ReplicatedStorage/WeaponAttachService.lua (교체본)
-- GunClient가 "요청"만 하면, 이 서비스가 1) 뷰모델, 2) 장착 UI 뷰포트 모델 모두에
-- 탄창을 장착/해제해 준다. (타르코프식 시각 장착 전담)

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local camera = workspace.CurrentCamera

local DEBUG = false

local MODELS: Instance? = nil
do
	local ok, res = pcall(function()
		return ReplicatedStorage:WaitForChild("Models", 1)
	end)
	if ok then MODELS = res end
end

local M = {}

-- ===== 내부 유틸 =====
local MOUNT_CANDIDATES = {
	"mag","Mag","MagMount","MagazineMount","MagAttachment","MagazineAttachment","Mag_Att","Magazine_Att"
}
local ROT_90 = CFrame.Angles(0, math.rad(90), 0) -- 기본 회전

local function dprint(...)
	if DEBUG then print("[WeaponAttachService]", ...) end
end

local function clearModsFolder(weaponModel: Model): Folder
	local old = weaponModel:FindFirstChild("_mods")
	if old then old:Destroy() end
	local bucket = Instance.new("Folder")
	bucket.Name = "_mods"
	bucket.Parent = weaponModel
	return bucket
end

local function sanitizeParts(root: Instance)
	for _, d in ipairs(root:GetDescendants()) do
		if d:IsA("BasePart") then
			d.CanCollide = false
			d.CanQuery = false
			d.CanTouch = false
			d.CastShadow = false
			d.Massless = true
		end
	end
end

local function findMagMount(weaponModel: Model): (BasePart?, Attachment?)
	if not weaponModel then return nil, nil end
	-- 이름 매치 우선
	for _, cand in ipairs(MOUNT_CANDIDATES) do
		local hit = weaponModel:FindFirstChild(cand, true)
		if hit then
			if hit:IsA("Attachment") and hit.Parent and hit.Parent:IsA("BasePart") then
				return hit.Parent :: BasePart, hit :: Attachment
			elseif hit:IsA("BasePart") then
				return hit :: BasePart, nil
			end
		end
	end
	-- 대소문자 무시
	for _, d in ipairs(weaponModel:GetDescendants()) do
		local n = string.lower(d.Name)
		for _, cand in ipairs(MOUNT_CANDIDATES) do
			if n == string.lower(cand) then
				if d:IsA("Attachment") and d.Parent and d.Parent:IsA("BasePart") then
					return d.Parent :: BasePart, d :: Attachment
				elseif d:IsA("BasePart") then
					return d :: BasePart, nil
				end
			end
		end
	end
	-- 폴백
	if weaponModel.PrimaryPart then return weaponModel.PrimaryPart, nil end
	return weaponModel:FindFirstChildWhichIsA("BasePart"), nil
end

local function findMagPrefabByName(name: string?): Model?
	if not name or name == "" then return nil end
	if MODELS then
		local mags = MODELS:FindFirstChild("Mags") or MODELS:FindFirstChild("Magazines")
		if mags then
			local tpl = mags:FindFirstChild(name)
				or mags:FindFirstChild(name .. " Model")
				or mags:FindFirstChild(name .. "_Model")
			if tpl and tpl:IsA("Model") then
				return tpl:Clone()
			end
		end
	end
	-- 백업: ReplicatedStorage 전체 탐색
	for _, d in ipairs(ReplicatedStorage:GetDescendants()) do
		if d:IsA("Model") and d.Name == name then
			return (d :: Model):Clone()
		end
	end
	return nil
end

local function weldParts(p0: BasePart, p1: BasePart)
	local ok = pcall(function()
		local wc = Instance.new("WeldConstraint")
		wc.Part0 = p0
		wc.Part1 = p1
		wc.Parent = p0
	end)
	if not ok then
		local w = Instance.new("Weld")
		w.Part0 = p0
		w.Part1 = p1
		w.C0 = p0.CFrame:ToObjectSpace(p1.CFrame)
		w.Parent = p0
	end
end

local function tryRequire(name:string)
	local ok, mod = pcall(function()
		return require(ReplicatedStorage:WaitForChild(name, 0.5))
	end)
	if ok then return mod end
	return nil
end
local SlotMapRegistry = tryRequire("SlotMapRegistry")

local function getEquippedGui(slotName:string): GuiObject?
	if SlotMapRegistry then
		local ok, equip = pcall(function()
			return (SlotMapRegistry.Get and SlotMapRegistry.Get("Equipment")) or (SlotMapRegistry :: any).Equipment
		end)
		if ok and equip and equip[slotName] and equip[slotName].EquippedItem then
			return equip[slotName].EquippedItem
		end
	end
	local pg = Players.LocalPlayer:FindFirstChildOfClass("PlayerGui")
	if not pg then return nil end
	for _, g in ipairs(pg:GetDescendants()) do
		if g:IsA("GuiObject")
			and g:GetAttribute("Id")
			and string.find(string.lower(g.Name), string.lower(slotName), 1, true) then
			return g
		end
	end
	return nil
end

local function getViewportModelFromEquippedGui(slotName:string): Model?
	local g = getEquippedGui(slotName); if not g then return nil end
	local vp: ViewportFrame? = nil
	for _, d in ipairs(g:GetDescendants()) do
		if d:IsA("ViewportFrame") then vp = d; break end
	end
	if not vp then return nil end
	for _, ch in ipairs(vp:GetChildren()) do
		if ch:IsA("Model") then return ch end
	end
	for _, d in ipairs(vp:GetDescendants()) do
		if d:IsA("Model") then return d end
	end
	return nil
end

local function getViewModelForSlot(slotName: string): Model?
	for _, m in ipairs(camera:GetChildren()) do
		if m:IsA("Model") and m.Name:sub(1,10)=="ViewModel_" then
			if slotName == "" or m.Name:sub(11) == slotName then
				local bp = m:FindFirstChildWhichIsA("BasePart", true)
				if not bp or bp.LocalTransparencyModifier < 0.99 then
					return m
				end
			end
		end
	end
	return nil
end

local function pickWeaponSubModel(root: Model?): Model?
	if not (root and root:IsA("Model")) then return nil end
	for _, d in ipairs(root:GetDescendants()) do
		if d:IsA("Model") then
			if d:FindFirstChild("mag", true) then
				return d
			end
		end
	end
	return root
end

local function modelNameFromMagGui(magGui: Instance?): string?
	if not magGui then return nil end
	local keys = { "ModelName","MagModelName","Prefab","DisplayName","ItemName" }
	for _, k in ipairs(keys) do
		local v = magGui:GetAttribute(k)
		if typeof(v)=="string" and #v>0 then return v end
	end
	return nil
end

-- ===== 공개 API =====

function M.ApplyModsToModel(weaponModel: Model, mods: {[string]: any}?)
	if not (weaponModel and weaponModel:IsA("Model")) then return end
	local bucket = clearModsFolder(weaponModel)
	if not (mods and typeof(mods) == "table") then
		dprint("mods=nil -> cleared on", weaponModel:GetFullName())
		return
	end

	-- ── 탄창 부착
	local magInfo = mods.mag
	if magInfo and typeof(magInfo) == "table" then
		local mag = findMagPrefabByName(tostring(magInfo.ModelName or ""))
		if not mag then
			if DEBUG then warn("[WeaponAttachService] Mag model not found:", tostring(magInfo.ModelName)) end
			return
		end
		mag.Name = "_mod_mag"
		mag.Parent = bucket
		if not mag.PrimaryPart then
			mag.PrimaryPart = mag:FindFirstChildWhichIsA("BasePart")
		end
		if not mag.PrimaryPart then
			if DEBUG then warn("[WeaponAttachService] Magazine prefab has no PrimaryPart") end
			return
		end

		sanitizeParts(mag)

		local mountPart, mountAtt = findMagMount(weaponModel)
		if not mountPart then
			mountPart = weaponModel.PrimaryPart or weaponModel:FindFirstChildWhichIsA("BasePart")
		end
		if not mountPart then
			if DEBUG then warn("[WeaponAttachService] No mount base") end
			return
		end

		local userRot = (typeof(magInfo.Rotation)=="CFrame") and magInfo.Rotation or CFrame.new()
		local userOff = (typeof(magInfo.Offset)=="CFrame") and magInfo.Offset or CFrame.new()
		local targetCF: CFrame
		if mountAtt then
			targetCF = mountAtt.WorldCFrame * ROT_90 * userRot * userOff
		else
			targetCF = mountPart.CFrame * ROT_90 * userRot * userOff
		end

		mag:PivotTo(targetCF)
		weldParts(mountPart, mag.PrimaryPart)
	end
end

-- 슬롯 단위(뷰모델 + 뷰프레임) 동시 장착
function M.AttachMagazineForSlot(slotName: string, magSource: any)
	local modelName: string? = nil
	if typeof(magSource) == "Instance" then
		modelName = modelNameFromMagGui(magSource)
	elseif typeof(magSource) == "string" then
		modelName = magSource
	end
	if not modelName or modelName == "" then
		if DEBUG then warn("[WeaponAttachService] AttachMagazineForSlot: model name missing") end
		return
	end

	local mods = { mag = { ModelName = modelName } }

	-- 1) 1인칭 뷰모델
	local vm = getViewModelForSlot(slotName)
	if vm then
		local weaponModel = pickWeaponSubModel(vm)
		M.ApplyModsToModel(weaponModel, mods)
	end

	-- 2) UI 뷰포트 모델
	local vpWeapon = getViewportModelFromEquippedGui(slotName)
	if vpWeapon then
		M.ApplyModsToModel(vpWeapon, mods)
	end
end

-- 슬롯 시각 모드 제거
function M.ClearForSlot(slotName: string)
	local vm = getViewModelForSlot(slotName)
	if vm then
		local weaponModel = pickWeaponSubModel(vm)
		M.ApplyModsToModel(weaponModel, nil)
	end
	local vpWeapon = getViewportModelFromEquippedGui(slotName)
	if vpWeapon then
		M.ApplyModsToModel(vpWeapon, nil)
	end
end

return M
