-- ?? ServerScriptService/PlayGojoAnim.server.lua
local RunService = game:GetService("RunService")

local model = workspace:WaitForChild("Gojo satoru")
local humanoid = model:WaitForChild("Humanoid")

local animation = Instance.new("Animation")
animation.AnimationId = "rbxassetid://106786884591179"

local animator = humanoid:FindFirstChildOfClass("Animator")
if not animator then
	animator = Instance.new("Animator")
	animator.Parent = humanoid
end

local track = animator:LoadAnimation(animation)
track.Looped = false
track:Play() -- 속도 1배로 시작

-- ?? 0~3초: 자유 재생 → 이후: 2~3초 구간 반복
local LOOP_START, LOOP_END = 2.0, 3.0
local enteredLoop = false
local conn

conn = RunService.Heartbeat:Connect(function()
	if not track.IsPlaying then return end
	local t = track.TimePosition

	if not enteredLoop then
		-- 처음 3초까지는 그대로 감
		if t >= LOOP_END then
			enteredLoop = true
			track.TimePosition = LOOP_START
		end
	else
		-- 2~3초 사이만 왕복 없이 루프
		if t >= LOOP_END then
			track.TimePosition = LOOP_START
		elseif t < LOOP_START - 0.02 then
			-- 외부에서 TimePosition이 건드려졌을 때 구간 밖으로 벗어나지 않게 보정
			track.TimePosition = LOOP_START
		end
	end
end)

-- (선택) 모델이 사라지면 정리
model.AncestryChanged:Connect(function(_, parent)
	if not parent and conn then
		conn:Disconnect()
	end
end)
