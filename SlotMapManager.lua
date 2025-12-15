--!strict
-- ?? ReplicatedStorage/SlotMapManager.lua
-- 1-based grid occupancy manager. rows=세로(행), cols=가로(열).
-- ? 변경점
-- 1) 절대 "임의 축소" 금지: new/Resize가 받은 rows/cols를 그대로 씀(하한만 보정).
-- 2) 경계 포함(inclusive) inBounds 재검증.
-- 3) FindFirstFreeSlot이 rows-h+1 / cols-w+1까지만 스캔(마지막 줄 손실 방지).
-- 4) Mark/Clear 시 out-of-bounds 시도는 막고 원인 로그(옵션).
-- 5) DebugSnapshot/OnSizeChanged로 디버깅 편의 제공.

export type TMap = {
	rows: number,
	cols: number,
	_grid: {{any?}}, -- [row][col] = occId or nil

	-- API
	Clear: (self: TMap) -> (),
	IsAreaFree: (self: TMap, row: number, col: number, w: number, h: number, ignoreId: any?) -> boolean,
	MarkArea: (self: TMap, row: number, col: number, w: number, h: number, occId: any?) -> boolean,
	ClearArea: (self: TMap, row: number, col: number, w: number, h: number, occId: any?) -> (),
	PurgeId: (self: TMap, occId: any) -> (),
	FindFirstFreeSlot: (self: TMap, w: number, h: number, ignoreId: any?) -> (number?, number?),

	-- 디버그/시각화
	RegisterSlotFrame: (self: TMap, row: number, col: number, frame: Instance) -> (),
	Highlight: (self: TMap, row: number, col: number, w: number, h: number, ok: boolean) -> (),

	-- 크기 변경
	Resize: (self: TMap, rows: number, cols: number, keepExisting: boolean?) -> (),

	-- 디버그 도우미
	DebugSnapshot: (self: TMap) -> (),
	OnSizeChanged: (self: TMap, cb: (rows: number, cols: number) -> ()) -> (),
}

local SlotMapManager = {}
SlotMapManager.__index = SlotMapManager

-- ?? 디버그 토글
local DEBUG = false
local function dprint(...)
	if DEBUG then
		print("[SlotMapManager]", ...)
	end
end

-- 내부: 비어있는 2차원 그리드 생성 (정확히 rows×cols)
local function newGrid(rows: number, cols: number): {{any?}}
	local g: {{any?}} = table.create(rows)
	for r = 1, rows do
		local line = table.create(cols)
		for c = 1, cols do
			line[c] = nil
		end
		g[r] = line
	end
	return g
end

-- ? 생성자: rows/cols를 절대 축소하지 않고 그대로 반영(하한 1만 보정)
function SlotMapManager.new(rows: number, cols: number): TMap
	-- 하한만 보정. 반올림/내림 절대 금지(상위에서 이미 정수 전달 가정).
	if rows < 1 then rows = 1 end
	if cols < 1 then cols = 1 end

	local self: any = setmetatable({}, SlotMapManager)
	self.rows = rows
	self.cols = cols
	self._grid = newGrid(rows, cols)
	self._frames = {} -- [row][col] = Frame (선택: 하이라이트용)
	self._sizeChanged = {} -- 콜백 리스트
	dprint("new rows=", rows, "cols=", cols)
	return self
end

-- ─────────── 내부 유틸 ───────────
local function inBounds(self: TMap, row: number, col: number, w: number, h: number): boolean
	-- 1-based inclusive bound check: (row+h-1) <= rows / (col+w-1) <= cols
	if row < 1 or col < 1 or w < 1 or h < 1 then return false end
	local r2 = row + h - 1
	local c2 = col + w - 1
	return (r2 <= self.rows) and (c2 <= self.cols)
end

-- ─────────── API ───────────

function SlotMapManager:Clear()
	for r = 1, self.rows do
		for c = 1, self.cols do
			self._grid[r][c] = nil
		end
	end
end

-- ignoreId: 해당 occId는 빈 칸 취급
function SlotMapManager:IsAreaFree(row: number, col: number, w: number, h: number, ignoreId: any?): boolean
	if not inBounds(self, row, col, w, h) then
		return false
	end
	for r = row, row + h - 1 do
		for c = col, col + w - 1 do
			local occ = self._grid[r][c]
			if occ ~= nil and occ ~= ignoreId then
				return false
			end
		end
	end
	return true
end

-- 성공 시 true
function SlotMapManager:MarkArea(row: number, col: number, w: number, h: number, occId: any?): boolean
	if not inBounds(self, row, col, w, h) then
		dprint("? Mark OOB", "row=", row, "col=", col, "w=", w, "h=", h, "bounds=", self.rows, self.cols)
		return false
	end
	-- 완전히 비어 있어야만 마킹
	if not self:IsAreaFree(row, col, w, h, nil) then
		dprint("? Mark blocked", "row=", row, "col=", col, "w=", w, "h=", h)
		return false
	end
	for r = row, row + h - 1 do
		for c = col, col + w - 1 do
			self._grid[r][c] = occId or true
		end
	end
	return true
end

-- occId 지정 시 그 occId로 찍힌 칸만 지움(안전)
function SlotMapManager:ClearArea(row: number, col: number, w: number, h: number, occId: any?)
	if not inBounds(self, row, col, w, h) then
		dprint("?? Clear OOB ignored", "row=", row, "col=", col, "w=", w, "h=", h, "bounds=", self.rows, self.cols)
		return
	end
	for r = row, row + h - 1 do
		for c = col, col + w - 1 do
			if occId == nil or self._grid[r][c] == occId then
				self._grid[r][c] = nil
			end
		end
	end
end

-- 전체에서 특정 occId 제거
function SlotMapManager:PurgeId(occId: any)
	if occId == nil then return end
	for r = 1, self.rows do
		for c = 1, self.cols do
			if self._grid[r][c] == occId then
				self._grid[r][c] = nil
			end
		end
	end
end

-- 첫 빈칸 찾기(좌→우, 상→하). 마지막 줄 포함되도록 maxRow/maxCol 안전계산.
function SlotMapManager:FindFirstFreeSlot(w: number, h: number, ignoreId: any?): (number?, number?)
	if w < 1 or h < 1 then return nil, nil end
	local maxRow = self.rows - h + 1
	local maxCol = self.cols - w + 1
	if maxRow < 1 or maxCol < 1 then return nil, nil end
	for r = 1, maxRow do
		for c = 1, maxCol do
			if self:IsAreaFree(r, c, w, h, ignoreId) then
				return r, c
			end
		end
	end
	return nil, nil
end

-- (선택) 셀 프레임 등록: 디버그/하이라이트용
function SlotMapManager:RegisterSlotFrame(row: number, col: number, frame: Instance)
	if row < 1 or col < 1 or row > self.rows or col > self.cols then return end
	self._frames[row] = self._frames[row] or {}
	self._frames[row][col] = frame
end

-- (선택) 하이라이트
function SlotMapManager:Highlight(row: number, col: number, w: number, h: number, ok: boolean)
	for r = 1, self.rows do
		for c = 1, self.cols do
			local fr = self._frames[r] and self._frames[r][c]
			if fr and fr:IsA("GuiObject") then
				fr.BackgroundTransparency = 0.2
				fr.BackgroundColor3 = Color3.fromRGB(60,60,60)
			end
		end
	end
	local color = ok and Color3.fromRGB(60,180,90) or Color3.fromRGB(200,70,70)
	for rr = row, math.min(self.rows, row + h - 1) do
		for cc = col, math.min(self.cols, col + w - 1) do
			local fr = self._frames[rr] and self._frames[rr][cc]
			if fr and fr:IsA("GuiObject") then
				fr.BackgroundTransparency = 0.05
				fr.BackgroundColor3 = color
			end
		end
	end
end

-- 사이즈 변경(들어온 값 그대로 적용. keepExisting=true면 그리드 복사)
function SlotMapManager:Resize(rows: number, cols: number, keepExisting: boolean?)
	if rows < 1 then rows = 1 end
	if cols < 1 then cols = 1 end
	if rows == self.rows and cols == self.cols then return end

	local oldR, oldC = self.rows, self.cols
	if keepExisting then
		local newG = newGrid(rows, cols)
		for r = 1, math.min(rows, self.rows) do
			for c = 1, math.min(cols, self.cols) do
				newG[r][c] = self._grid[r][c]
			end
		end
		self._grid = newG
	else
		self._grid = newGrid(rows, cols)
	end
	self.rows = rows
	self.cols = cols
	self._frames = {} -- 프레임 매핑은 재등록 권장
	dprint(("Resize %dx%d → %dx%d"):format(oldR, oldC, rows, cols))

	-- 콜백 알림
	for _, cb in ipairs(self._sizeChanged) do
		local ok, err = pcall(cb, rows, cols)
		if not ok then warn("[SlotMapManager] OnSizeChanged cb error:", err) end
	end
end

-- ?? 현재 점유 찍어보는 디버그 도우미
function SlotMapManager:DebugSnapshot()
	local lines = {}
	for r = 1, self.rows do
		local row = {}
		for c = 1, self.cols do
			table.insert(row, self._grid[r][c] and "■" or "·")
		end
		table.insert(lines, table.concat(row, " "))
	end
	dprint("snapshot rows=", self.rows, "cols=", self.cols)
	for _, L in ipairs(lines) do dprint(L) end
end

function SlotMapManager:OnSizeChanged(cb: (rows: number, cols: number) -> ())
	table.insert(self._sizeChanged, cb)
end

return SlotMapManager
