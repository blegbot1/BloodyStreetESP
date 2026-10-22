--==================================================================
--  BLOODY STREET — ДИАГНОСТИЧЕСКИЙ ДАМП  (v1)
--  Только читает и печатает. Ничего в игре не меняет.
--
--  Что выводит:
--    1) PlaceId / JobId, я и мои атрибуты
--    2) Все игроки: команда, персонаж, инструменты, атрибуты
--    3) Верхний уровень Workspace
--    4) ReplicatedStorage деревом (ремоуты и модули)
--    5) Все Remote/Bindable с полными путями
--    6) ProximityPrompt и ClickDetector по всей карте
--    7) Монеты: сколько, CoinIndex, позиции, содержимое
--    8) Ящики/лут: пути и атрибуты
--    9) Все объекты Workspace, у которых есть атрибуты
--   10) Сводка по классам Workspace
--
--  В конце пробует сохранить всё в bs_dump.txt (если умеет исполнитель).
--==================================================================
local Players = game:GetService("Players")
local RS      = game:GetService("ReplicatedStorage")
local WS      = game:GetService("Workspace")
local LP      = Players.LocalPlayer

if not LP then
    print("[BS DUMP] это скрипт для клиента (LocalPlayer не найден)")
    return
end

local lines = {}
local function log(s)
    s = tostring(s)
    lines[#lines + 1] = s
    print("[BS DUMP] " .. s)
end

local function attrsOf(inst)
    local ok, t = pcall(function() return inst:GetAttributes() end)
    if not ok or type(t) ~= "table" then return "" end
    local ks = {}
    for k, v in pairs(t) do
        ks[#ks + 1] = k .. "=" .. tostring(v)
    end
    if #ks == 0 then return "" end
    table.sort(ks)
    return " {" .. table.concat(ks, ", ") .. "}"
end

local function kids(inst)
    local ok, c = pcall(function() return inst:GetChildren() end)
    if ok and type(c) == "table" then return c end
    return {}
end

local function fullName(inst)
    local ok, n = pcall(function() return inst:GetFullName() end)
    return ok and n or inst.Name
end

local function dumpTree(root, maxDepth, maxItems, label)
    log("")
    log("========== " .. label .. " ==========")
    local n = 0
    local function walk(inst, depth)
        if n >= maxItems then return end
        n = n + 1
        local ch = kids(inst)
        log(string.rep("  ", depth) .. inst.Name .. " [" .. inst.ClassName .. "]"
            .. (#ch > 0 and (" +" .. #ch) or "") .. attrsOf(inst))
        if depth >= maxDepth then
            if #ch > 0 then
                log(string.rep("  ", depth + 1) .. "... внутри ещё " .. #ch)
            end
            return
        end
        for _, c in ipairs(ch) do
            if not (c:IsA("Model") and Players:GetPlayerFromCharacter(c)) then
                walk(c, depth + 1)
            end
        end
    end
    walk(root, 0)
    log("--- объектов: " .. n .. (n >= maxItems and " (обрезано)" or ""))
end

--==================================================================
log("BLOODY STREET DUMP | PlaceId=" .. tostring(game.PlaceId)
    .. " | JobId=" .. tostring(game.JobId))

-- ---------- 1. Я ----------
log("")
log("========== Я ==========")
log(LP.Name .. " (" .. tostring(LP.UserId) .. ")" .. attrsOf(LP)
    .. " | team=" .. tostring(LP.Team and LP.Team.Name)
    .. " | char=" .. (LP.Character and "да" or "нет"))

do
    local ch = LP.Character
    if ch then
        for _, d in ipairs(ch:GetDescendants()) do
            if d:IsA("BasePart") or d:IsA("Tool") or d:IsA("Humanoid") then
                log("  " .. d:GetFullName() .. " [" .. d.ClassName .. "]" .. attrsOf(d))
            end
        end
    else
        log("  персонажа нет")
    end
end

-- ---------- 2. Все игроки ----------
log("")
log("========== ИГРОКИ ==========")
for _, p in ipairs(Players:GetPlayers()) do
    local ch = p.Character
    local tools = {}
    if ch then
        for _, t in ipairs(kids(ch)) do
            if t:IsA("Tool") then tools[#tools + 1] = t.Name end
        end
    end
    log(p.Name
        .. " | team=" .. tostring(p.Team and p.Team.Name)
        .. " | char=" .. (ch and "да" or "нет")
        .. " | tools=" .. (#tools > 0 and table.concat(tools, ", ") or "-")
        .. attrsOf(p))
end

-- ---------- 3. Workspace, верхний уровень ----------
log("")
log("========== WORKSPACE (верхний уровень) ==========")
for _, c in ipairs(kids(WS)) do
    local ch = kids(c)
    log(c.Name .. " [" .. c.ClassName .. "] +" .. #ch .. attrsOf(c))
end

local wsDesc = {}
do
    local ok, d = pcall(function() return WS:GetDescendants() end)
    if ok and type(d) == "table" then wsDesc = d end
end
log("--- всего объектов в Workspace: " .. #wsDesc)

-- ---------- 4. ReplicatedStorage деревом ----------
dumpTree(RS, 3, 400, "REPLICATEDSTORAGE (дерево)")

-- ---------- 5. Ремоуты ----------
log("")
log("========== РЕМОУТЫ (Remote / Bindable) ==========")
do
    local names = {}
    for _, d in ipairs(RS:GetDescendants()) do
        if d:IsA("RemoteEvent") or d:IsA("UnreliableRemoteEvent")
           or d:IsA("RemoteFunction") or d:IsA("BindableEvent")
           or d:IsA("BindableFunction") then
            names[#names + 1] = fullName(d) .. " [" .. d.ClassName .. "]" .. attrsOf(d)
        end
    end
    table.sort(names)
    for i = 1, math.min(#names, 250) do log("  " .. names[i]) end
    log("--- ремоутов: " .. #names)
end

-- ---------- 6. Prompts и ClickDetector ----------
log("")
log("========== PROXIMITY PROMPTS ==========")
do
    local n = 0
    for _, d in ipairs(wsDesc) do
        if d:IsA("ProximityPrompt") then
            n = n + 1
            if n <= 150 then
                log("  " .. fullName(d)
                    .. " | ActionText=" .. tostring(d.ActionText)
                    .. " | ObjectText=" .. tostring(d.ObjectText)
                    .. " | Hold=" .. tostring(d.HoldDuration)
                    .. " | Dist=" .. tostring(d.MaxActivationDistance)
                    .. " | Enabled=" .. tostring(d.Enabled)
                    .. attrsOf(d))
            end
        end
    end
    log("--- prompts: " .. n)
end

log("")
log("========== CLICK DETECTORS ==========")
do
    local n = 0
    for _, d in ipairs(wsDesc) do
        if d:IsA("ClickDetector") then
            n = n + 1
            if n <= 50 then
                log("  " .. fullName(d)
                    .. " | Dist=" .. tostring(d.MaxActivationDistance)
                    .. " | Cursor=" .. tostring(d.CursorIcon) .. attrsOf(d))
            end
        end
    end
    log("--- click detectors: " .. n)
end

-- ---------- 7. Монеты ----------
log("")
log("========== МОНЕТЫ ==========")
local function myPos()
    local ch = LP.Character
    local root = ch and ch:FindFirstChild("HumanoidRootPart")
    return root and root.Position or Vector3.new(0, 0, 0)
end
local mp = myPos()
do
    local folder = WS:FindFirstChild("CoinPickups", true)
    log("папка: " .. (folder and fullName(folder) or "НЕ НАЙДЕНА"))
    local coins = {}
    if folder then
        for _, d in ipairs(kids(folder)) do
            if d:IsA("Model") then coins[#coins + 1] = d end
        end
    end
    log("монет в папке: " .. #coins)
    for i = 1, math.min(#coins, 40) do
        local c = coins[i]
        local p = c.PrimaryPart or c:FindFirstChildWhichIsA("BasePart")
        local pos = p and p.Position
        log("  #" .. i .. " " .. c.Name .. attrsOf(c)
            .. (pos and (" | pos=" .. tostring(pos)
                .. " | от меня=" .. math.floor((pos - mp).Magnitude)) or ""))
        if i <= 3 then
            for _, d in ipairs(kids(c)) do
                log("       " .. d.Name .. " [" .. d.ClassName .. "]" .. attrsOf(d))
            end
        end
    end
end

-- ---------- 8. Ящики / лут ----------
log("")
log("========== ЯЩИКИ / ЛУТ ==========")
do
    local hits = {}
    for _, d in ipairs(wsDesc) do
        local n = string.lower(d.Name)
        if string.find(n, "crate", 1, true)
           or string.find(n, "chest", 1, true)
           or string.find(n, "loot", 1, true)
           or string.find(n, "ammo", 1, true)
           or string.find(n, "supply", 1, true) then
            hits[#hits + 1] = d
        end
    end
    for i = 1, math.min(#hits, 40) do
        local d = hits[i]
        log("  " .. fullName(d) .. " [" .. d.ClassName .. "]" .. attrsOf(d))
    end
    log("--- найдено: " .. #hits .. " (показано " .. math.min(#hits, 40) .. ")")
end

-- ---------- 9. Объекты с атрибутами ----------
log("")
log("========== ОБЪЕКТЫ С АТРИБУТАМИ (Workspace) ==========")
do
    local n = 0
    for _, d in ipairs(wsDesc) do
        local a = attrsOf(d)
        if a ~= "" then
            n = n + 1
            if n <= 120 then
                log("  " .. fullName(d) .. " [" .. d.ClassName .. "]" .. a)
            end
        end
    end
    log("--- с атрибутами: " .. n)
end

-- ---------- 10. Сводка по классам ----------
log("")
log("========== СВОДКА ПО КЛАССАМ (Workspace) ==========")
do
    local cnt = {}
    for _, d in ipairs(wsDesc) do
        cnt[d.ClassName] = (cnt[d.ClassName] or 0) + 1
    end
    local arr = {}
    for k, v in pairs(cnt) do arr[#arr + 1] = { k, v } end
    table.sort(arr, function(a, b) return a[2] > b[2] end)
    for i = 1, math.min(#arr, 15) do
        log("  " .. arr[i][1] .. " x" .. arr[i][2])
    end
end

log("")
log("========== КОНЕЦ ДАМПА ==========")

-- ---------- сохранение в файл ----------
if writefile then
    local ok = pcall(writefile, "bs_dump.txt", table.concat(lines, "\n"))
    log(ok and "дамп сохранён в bs_dump.txt" or "writefile не сработал")
end
