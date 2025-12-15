-- ?? StarterPlayerScripts/NewsPlayerZSwapSlideshow.client.lua
-- Workspace."news player".SurfaceGui 안의 neonato/paymon/mcx ImageLabel을
-- 10초 유지 + 3초 크로스페이드하며, 전환 중간에 ZIndex도 서로 교대로 스왑

local TweenService = game:GetService("TweenService")

local SHOW_TIME = 10
local FADE_TIME = 3

-- 참조
local part = workspace:WaitForChild("news player")
local gui  = part:WaitForChild("SurfaceGui")

local images = {
	gui:WaitForChild("neonato") :: ImageLabel,
	gui:WaitForChild("paymon")  :: ImageLabel,
	gui:WaitForChild("f22")     :: ImageLabel,
	gui:WaitForChild("pla") :: ImageLabel,
	gui:WaitForChild("HI") :: ImageLabel,
}

-- 초기 상태: 첫번째 이미지만 보이게, 나머지는 숨기기
for i, img in ipairs(images) do
	if i == 1 then
		img.ImageTransparency = 0
		img.ZIndex = 2
	else
		img.ImageTransparency = 1
		img.ZIndex = 1
	end
end

local currentIndex = 1

local tweenInfo = TweenInfo.new(FADE_TIME, Enum.EasingStyle.Quad, Enum.EasingDirection.InOut)

local function crossFadeWithZFlip(fromImg: ImageLabel, toImg: ImageLabel)
	-- 전환 시작: from이 위
	fromImg.ZIndex = 2
	toImg.ZIndex   = 1
	toImg.ImageTransparency = 1

	-- 트윈 실행
	local tOut = TweenService:Create(fromImg, tweenInfo, { ImageTransparency = 1 })
	local tIn  = TweenService:Create(toImg,   tweenInfo, { ImageTransparency = 0 })
	tOut:Play(); tIn:Play()

	-- 중간에 ZIndex 교체
	task.delay(FADE_TIME * 0.5, function()
		toImg.ZIndex   = 2
		fromImg.ZIndex = 1
	end)

	tIn.Completed:Wait()
end

-- 메인 루프
task.spawn(function()
	while gui and gui.Parent do
		task.wait(SHOW_TIME)

		local nextIndex = (currentIndex % #images) + 1
		local currentImg = images[currentIndex]
		local nextImg    = images[nextIndex]

		crossFadeWithZFlip(currentImg, nextImg)
		currentIndex = nextIndex
	end
end)
