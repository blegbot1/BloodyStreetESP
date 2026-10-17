-- ============================================================
--  BLOODY STREET - ESP + КЛИЕНТ АИМ  v10.1
--  GUI на Rayfield. Вкладки: ESP / AIM.
--
--  ESP (вкладка ESP): 3D-коробки, ники, дистанция, HP, цвет по
--  ролям (вампир / хантер / неизвестный), сканер игры.
--  (Блоки «главный RGB», «Точность ролей», «Выживание» и «Прострел»
--   удалены по просьбе — GUI их больше не показывает.)
--
--  КЛИЕНТ АИМ (вкладка AIM): ПОДМЕНА ПАТРОНА. Remotes.FireWeapon
--  перехватывается через глобальный __namecall, и аргументы
--  выстрела подменяются на вектор к цели. Камера НЕ крутится —
--  стреляешь ты сам, патрон уходит в цель.
--  ПРОСТРЕЛ: по умолчанию ВКЛ — стены не мешают.
--  Аимбота с доводкой камеры НЕТ (удалён по просьбе).
--
--  КАК ЧИТАЕТСЯ РОЛЬ (сервер атрибут -> 100% с первого кадра):
--  У КАЖДОГО игрока есть атрибут player.Role (None / Vampire /
--  Hunter). Сервер ставит его КАЖДОМУ, атрибуты реплицируются
--  ВСЕМ клиентам — в начале раунда там сразу точная роль.
--
--  Резервные источники (если атрибут недоступен):
--    BurstFX #4 = Model(стрелка) ......... хантер       (уверенность 5)
--    Announce + DetectionFeed redoutline . раскрытие   (уверенность 5)
--    ForensicsFeed testresult ........... раскрытие   (уверенность 5)
--    RoundState счётчики + "я один" ..... вывод        (уверенность 4)
--    SoundPing "gun" рядом .............. хантер       (уверенность 3)
--
--  СТАМИНА: игра тратит энергию ЧЕРЕЗ РЕМОУТ Remotes.UseEnergy,
--  а не через NumberValue — поэтому хукаем FireServer.
--
--  ЗАПУСК: вставь скрипт целиком в Jy (или в RunBox).
--  Только аккаунт-альт. Всё клиентское, сервер об этом не знает.
-- ============================================================

local G = getgenv()
G.BS = G.BS or {}

local Players    = game:GetService("Players")
local RunService = game:GetService("RunService")
local TRS        = game:GetService("ReplicatedStorage")
local LP         = Players.LocalPlayer

local function notify(t, d)
    pcall(function() Rayfield:Notify({ Title = "BLOODY STREET", Content = t, Duration = d or 3 }) end)
end

if not Rayfield then
    local okR, errR = pcall(function()
        Rayfield = loadstring(game:HttpGet(
            "https://raw.githubusercontent.com/SiriusSoftwareLtd/Rayfield/main/source.lua"
        ))()
    end)
    if not okR or not Rayfield then
        error("[BS ESP] не удалось загрузить Rayfield: " .. tostring(errR))
    end
end

-- СТАРЫЙ КОНФИГ может содержать значения, которых больше нет в
-- списках. Rayfield падает на CreateDropdown с несуществующим
-- CurrentOption — всё, чего нет в списке, тихо заменяем.
local function pickOpt(value, opts, fallback)
    if type(value) ~= "string" then return fallback end
    for _, o in ipairs(opts) do
        if o == value then return value end
    end
    return fallback
end

-- ТИП-БЕЗОПАСНЫЙ ЦВЕТ. Из старого конфига может прийти строка
-- (например после правки руками), а FillColor = "строка" падает
-- КАЖДЫЙ КАДР. Здесь принимаем только Color3.
local function safeColor(v, d)
    if typeof(v) == "Color3" then return v end
    return d
end

-- ============================================================
--  СПИСКИ ЗНАЧЕНИЙ (все в одном месте, чтобы sanitize прошёл раньше,
--  чем Rayfield увидит мусор из конфига)
-- ============================================================
local AIM_TARGETS  = { "Противники по роли", "Только вампиров", "Только людей", "Все" }
local AIM_PRIORITY = { "Ближе к прицелу", "Ближе по расстоянию", "Больше HP" }
local AIM_PART     = { "Head", "UpperTorso", "HumanoidRootPart", "Torso" }
local RGB_TARGETS  = {
    "Метка: захват цели",
    "ESP вампиров",
    "ESP хантеров",
    "ESP игроков",
    "Метка цели",
}

-- ============================================================
--  НАСТРОЙКИ
-- ============================================================
G.BS.Run = (G.BS.Run or 0) + 1
local RUN_ID = G.BS.Run

-- ---------- ESP ----------
G.BS.PlayerESP   = G.BS.PlayerESP   ~= false
G.BS.PlayerColor = safeColor(G.BS.PlayerColor, Color3.fromRGB(200, 200, 200))
G.BS.VampESP     = G.BS.VampESP     ~= false
G.BS.VampColor   = safeColor(G.BS.VampColor, Color3.fromRGB(255, 55, 55))
G.BS.HunterESP   = G.BS.HunterESP   ~= false
G.BS.HunterColor = safeColor(G.BS.HunterColor, Color3.fromRGB(70, 190, 255))
G.BS.OnlyVamps   = G.BS.OnlyVamps   or false
G.BS.ShowUnknown = G.BS.ShowUnknown ~= false
G.BS.Names       = G.BS.Names       ~= false
G.BS.ShowDist    = G.BS.ShowDist    ~= false
G.BS.ShowHP      = G.BS.ShowHP      ~= false
G.BS.Boxes       = G.BS.Boxes       ~= false
G.BS.BoxThick    = G.BS.BoxThick    or 2
G.BS.MaxDist     = G.BS.MaxDist     or 0
-- Прозрачность заливки подсветки тела: 0 = тело залито цветом роли,
-- 1 = заливки нет (остаётся только контур). Контур красится всегда.
-- Меняется на ходу: getgenv().BS.FillTransparency = 0.4
G.BS.FillTransparency = tonumber(G.BS.FillTransparency) or 0.7

-- ---------- РОЛИ ----------
G.BS.RoleSticks  = G.BS.RoleSticks  or 1
G.BS.RoleFreeze  = G.BS.RoleFreeze  or false
G.BS.EventRole   = G.BS.EventRole   ~= false
G.BS.SoundRole   = G.BS.SoundRole   ~= false
G.BS.SoundRadius = G.BS.SoundRadius or 35
G.BS.RoundPhase  = G.BS.RoundPhase  or "?"
G.BS.RoundVamps  = G.BS.RoundVamps  or 0
G.BS.RoundHunters = G.BS.RoundHunters or 0
G.BS.LastPhase   = G.BS.LastPhase   or "?"
G.BS.MyRole      = G.BS.MyRole      or "?"

-- ---------- КЛИЕНТ АИМ ----------
-- КЛИЕНТ АЙМ по умолчанию ВКЛ (иначе подмена патрона молча
-- не работала: в стартовой строке статуса было "klient aym: false").
G.BS.BulletSwap      = G.BS.BulletSwap      ~= false
G.BS.BulletDebug     = G.BS.BulletDebug     or false
G.BS.SilentShots     = G.BS.SilentShots     or 0
-- ПРОСТРЕЛ СТЕН — всегда ВКЛ.
-- Переключателя в GUI больше нет, поэтому сохранённое в getgenv
-- старое false только вредило: цель за стеной отбрасывалась.
-- Для выстрелов через всю карту прострел обязателен.
G.BS.Penetrate       = true
-- ШИРОКИЙ ПОИСК: берём ближайшего противника в радиусе, даже если он
-- вне экрана. Иначе цель за спиной не находится.
G.BS.BulletWideAim   = G.BS.BulletWideAim ~= false
G.BS.AimTargets      = pickOpt(G.BS.AimTargets, AIM_TARGETS, AIM_TARGETS[1])
G.BS.AimPriority     = pickOpt(G.BS.AimPriority, AIM_PRIORITY, AIM_PRIORITY[1])
G.BS.AimPart         = pickOpt(G.BS.AimPart, AIM_PART, AIM_PART[1])
-- ДАЛЬНОСТЬ ПОДМЕНЫ. 0 = БЕЗ ОГРАНИЧЕНИЯ (через всю карту).
-- Раньше по умолчанию стояло 300, поэтому дальше 300 студов цель
-- вообще не выбиралась и пуля не подменялась. Слайдер этой настройки
-- удалён из GUI, значит 300 мог быть только старым дефолтом —
-- мигрируем его в 0 (без ограничения).
G.BS.AimMaxDist      = tonumber(G.BS.AimMaxDist) or 0
if G.BS.AimMaxDist == 300 then G.BS.AimMaxDist = 0 end
G.BS.RGBTarget       = pickOpt(G.BS.RGBTarget, RGB_TARGETS, RGB_TARGETS[1])

-- ---------- RGB ----------
G.BS.R = math.clamp(math.floor(tonumber(G.BS.R) or 255), 0, 255)
G.BS.G = math.clamp(math.floor(tonumber(G.BS.G) or 55), 0, 255)
G.BS.B = math.clamp(math.floor(tonumber(G.BS.B) or 55), 0, 255)

-- ---------- ВЫЖИВАНИЕ ----------
G.BS.InfStamina  = G.BS.InfStamina  or false
G.BS.StaminaDebug = G.BS.StaminaDebug or false
G.BS.HealthLock  = G.BS.HealthLock  or false
G.BS.HealthMax   = G.BS.HealthMax   or 5000
G.BS.ScanOnStart = G.BS.ScanOnStart or false

G.BS.AimLockColor  = safeColor(G.BS.AimLockColor,  Color3.fromRGB(255, 50, 50))
G.BS.AimMarkColor  = safeColor(G.BS.AimMarkColor,  Color3.fromRGB(255, 200, 0))
-- Радиус захвата в пикселях. 600 = без ограничения.
G.BS.AimFOV        = G.BS.AimFOV or 160
-- ОТКУДА СЧИТЫВАЕТСЯ НАПРАВЛЕНИЕ ВЫСТРЕЛА:
--   "camera" (по умолчанию) — от камеры, как стреляет сама игра;
--   "head"   — от головы персонажа;
--   "root"   — от HumanoidRootPart (пояс).
-- Если пуля уходит выше/ниже цели — переключи на ходу:
--   getgenv().BS.AimOrigin = "head"
G.BS.AimOrigin     = G.BS.AimOrigin or "camera"
-- ОПЕРЕЖЕНИЕ ЦЕЛИ (сек), фиксированное, без слайдера. Пакет идёт до
-- сервера ~0.1 с — за это время цель убегает, и без опережения пуля
-- приходит туда, где враг БЫЛ. Меняется на ходу:
--   getgenv().BS.AimLead = 0.15
G.BS.AimLead       = tonumber(G.BS.AimLead) or 0.08
-- ЛОГ РЕМОУТОВ (клиент -> сервер) в консоль. Вкладка AIM.
G.BS.RemoteLog  = G.BS.RemoteLog or false

-- РАСШИРИТЕЛЬ ХИТБОКСА удалён: невидимая часть на голове не помогала
-- (попадание считает сервер, наш клиент его не видит).
-- «ТИХИЙ ВЫСТРЕЛ» удалён: гасил вспышку/звук, но выстрел всё равно
-- было видно, пользы не было.
-- «ОПЕРЕЖЕНИЕ ЦЕЛИ»: слайдер удалён, но само опережение внутри аима
-- осталось (фиксированное, меняется из консоли) — без него по бегущим
-- не попадает вообще.

-- СПУФИНГ ТОЧКИ ВЫЛЕТА. По умолчанию ВЫКЛЮЧЕН (0): сервер всё равно
-- считает луч от позиции игрока, а подмена точки вылета приводила к
-- тому, что выстрел просто не засчитывался (выстрел есть, урона нет).
-- Включить из консоли: getgenv().BS.SpoofBack = 6
G.BS.SpoofBack   = tonumber(G.BS.SpoofBack) or 0

-- МИГРАЦИЯ НАСТРОЕК: getgenv() живёт между запусками, и старые
-- значения перебивали новые дефолты.
if G.BS.CfgV ~= 9 then
    G.BS.CfgV      = 9
    G.BS.AimLead   = 0.08
    G.BS.SpoofBack = 0
    G.BS.SilentShot = false
    G.BS.Hitbox    = false
    G.BS.RapidFire = false
end

if G.BS_Stop then pcall(function() G.BS_Stop() end) end

-- ЕДИНЫЙ ХУК __namecall (заменил флаги-таблицы на Instance из v8.6:
-- они были нужны из-за отдельных hookmetamethod, которые здесь не
-- работают; теперь общего хука достаточно).
--   orig      — исходный game.__namecall (нужен и для форвардинга
--               ВСЕХ вызовов, и для корректного снятия хука).
--   installed — хук реально стоит.
--   fw/ue/myHum — кэш целей (внутри хука нельзя звать методы через ":").
--   ОСТАТОЧНЫЕ ПОЛЯ ОБЪЯВЛЕНЫ ЯВНО (sending, lastSend, tpl, burst):
--   часть исполнителей ругается «Key 'sending' not found in table 'NC'»
--   на первое присваивание нового ключа.
local NC = { orig = nil, installed = false, wrapper = nil,
             fw = nil, ue = nil, myHum = nil,
             burst = nil, burstBlocked = 0,
             sending = false, lastSend = 0,
             tpl = nil, tplN = nil, tplSrc = nil }
-- forward-декларация: реализация ниже (после всех зависимостей).
-- Именно forward-декларация, а не `local installNamecall = function`,
-- потому что так безопаснее: сначала имя в области видимости, потом
-- присвоение.
local installNamecall

-- СОСТОЯНИЕ
-- STOPPED: после G.BS_Stop() фоновые циклы и коннекты обязаны
-- замолчать, иначе ESP пересоздаётся через секунду и хук ставится
-- заново при респавне.
local STOPPED = false
local connAdded, connRemoving, connChar
local by           = {}   -- [Player] = {char, role, conf, votes, lastStable, hl, gui, lbl, box}
local netRoles     = {}
local burstShooters = {}
local soundMarks   = {}
local revealMap    = {}
local pendingReveal
local locked       = nil  -- запертая цель (Player)
local bulletPreShot = nil -- {part, dir} — вычисляется каждый кадр

-- Уверенность источников роли
local CONF = { attr = 6, event = 5, deduce = 4, sound = 3, gear = 2 }

local function aliasOf(v)
    local s = string.lower(tostring(v or ""))
    if s == "" then return nil end
    if string.find(s, "vamp", 1, true) then return "vampire" end
    if string.find(s, "hunt", 1, true) then return "hunter" end
    if string.find(s, "none", 1, true) then return "none" end
    if string.find(s, "civil", 1, true) then return "human" end
    return nil
end

-- ИМЯ АТРИБУТА — ПРО КОСМЕТИКУ? Значение "claw_vamp_2" (скин когтей
-- вампира из лобби) содержит "vamp" и раньше попадало в роль: игрока
-- с Role=None красило как вампира. Такие поля отбрасываем.
local COSMETIC_MARK = {
    "cos_", "cosmetic", "skin", "claw", "wing", "aura", "emote",
    "pose", "trail", "hair", "owned", "unlocked", "bundle",
    "nametag", "loadout", "gun", "pass_", "season",
}
local function cosmeticName(name)
    local n = string.lower(tostring(name or ""))
    for i = 1, #COSMETIC_MARK do
        if string.find(n, COSMETIC_MARK[i], 1, true) then return true end
    end
    return false
end

-- ============================================================
--  РЕМОУТЫ
-- ============================================================
local function findRemotes()
    local b = TRS:FindFirstChild("BloodyStreet")
    if b then
        local r = b:FindFirstChild("Remotes")
        if r then return r end
    end
    for _, d in ipairs(TRS:GetDescendants()) do
        if d:IsA("Folder") and d.Name == "Remotes" then return d end
    end
    return nil
end

local Remotes = findRemotes()
local netConns = {}

-- ПОИСК РОЛИ.
-- Раньше проверялся только фиксированный список ИМЁН атрибутов
-- ("Role", "Team", ...). Если игра называла атрибут иначе — роль не
-- находилась НИ У КОГО, и ESP не красил ни вампиров, ни хантеров.
-- Теперь смотрим на ЗНАЧЕНИЕ, а не на имя: любой атрибут игрока или
-- персонажа (а также StringValue / BoolValue в персонаже), значение
-- которого похоже на роль, считается ролью. Какое именно поле
-- сработало — видно в консоли через «Сканер игры».
local function roleFromInstance(inst)
    if not inst then return nil end

    local ok, attrs = pcall(function() return inst:GetAttributes() end)
    if ok and type(attrs) == "table" then
        -- 1) СНАЧАЛА точное имя "Role" — в этой игре роль лежит именно
        -- там: player.Role = Hunter / Vampire / None. Раньше перебор
        -- шёл в случайном порядке (pairs), и первым попадался мусор
        -- вроде Cos_Claws.
        for name, v in pairs(attrs) do
            if string.lower(name) == "role" then
                local k = aliasOf(v)
                if k then
                    return k, "атрибут " .. tostring(name) .. "=" .. tostring(v)
                end
            end
        end
        -- 2) потом любые другие атрибуты, кроме косметики
        for name, v in pairs(attrs) do
            if not cosmeticName(name) then
                local k = aliasOf(v)
                if k and k ~= "none" then
                    return k, "атрибут " .. tostring(name) .. "=" .. tostring(v)
                end
            end
        end
    end

    local ok2, kids = pcall(function() return inst:GetChildren() end)
    if ok2 and type(kids) == "table" then
        for _, c in ipairs(kids) do
            local cls = c.ClassName
            if cls == "StringValue" and not cosmeticName(c.Name) then
                local k = aliasOf(c.Value)
                if k and k ~= "none" then
                    return k, "StringValue " .. c.Name .. "=" .. tostring(c.Value)
                end
            elseif cls == "BoolValue" then
                -- например IsVampire = true
                if c.Value == true then
                    local nm = string.lower(c.Name)
                    if string.find(nm, "vamp", 1, true) then
                        return "vampire", "BoolValue " .. c.Name
                    end
                    if string.find(nm, "hunt", 1, true) then
                        return "hunter", "BoolValue " .. c.Name
                    end
                end
            end
        end
    end
    return nil
end

local function roleFromAttr(plr)
    -- 1) атрибуты/значения самого игрока
    local k = roleFromInstance(plr)
    if k then return k end
    -- 2) атрибуты/значения персонажа
    local ch = plr.Character
    if ch then
        k = roleFromInstance(ch)
        if k then return k end
    end
    -- 3) Team НЕ используем: в этой игре Team у всех = Citizens (роль
    -- там не лежит), раньше это могло красить всех одинаково.
    return nil
end

-- ВЫВОД ПО СЧЁТЧИКАМ РАУНДА
local function deduceOthers()
    local ph = string.lower(tostring(G.BS.RoundPhase or ""))
    if ph == "lobby" or ph == "countdown" or ph == "?" or ph == "" then return nil end
    if G.BS.RoundVamps <= 0 and G.BS.RoundHunters <= 0 then return nil end
    local mine = string.lower(tostring(G.BS.MyRole or "?"))
    if mine == "vampire" and G.BS.RoundVamps == 1 then return "hunter" end
    if mine == "hunter" and G.BS.RoundHunters == 1 then return "vampire" end
    return nil
end

local function resetRound()
    for k in pairs(netRoles) do netRoles[k] = nil end
    for _, e in pairs(by) do
        e.role, e.conf, e.votes, e.lastStable = nil, 0, 0, nil
    end
    G.BS.MyRole = "?"
end

-- ============================================================
--  GUI-ЭЛЕМЕНТЫ НА ИГРОКОВ
-- ============================================================
local Screen = nil

local function screen()
    if Screen and Screen.Parent then
        if not Screen.Enabled then Screen.Enabled = true end
        return Screen
    end
    local sg = Instance.new("ScreenGui")
    sg.Name           = "BS_ESP"
    sg.ResetOnSpawn   = false
    sg.IgnoreGuiInset = true
    -- DisplayOrder = 1, а не 500: иначе ESP ложился ПОВЕРХ окна
    -- Rayfield и меню было не видно.
    sg.DisplayOrder   = 1
    sg.Parent         = game:GetService("CoreGui")
    Screen = sg
    return sg
end
screen()

local function makeHighlight()
    local ok, h = pcall(function()
        return Instance.new("Highlight")
    end)
    if not ok or not h then return nil end
    h.Adornee      = nil
    h.FillColor    = Color3.new(1, 1, 1)
    -- ВАЖНО: раньше заливка была ПОЛНОСТЬЮ прозрачной (1), а цвет роли
    -- писался только в FillColor, то есть в невидимую заливку. При
    -- этом OutlineColor — то, что реально видно — вообще не менялся
    -- и оставался БЕЛЫМ. Из-за этого сам игрок по роли не красился:
    -- красились только коробка (у неё свой color) и текст.
    h.FillTransparency = tonumber(G.BS.FillTransparency) or 0.7
    h.OutlineColor = Color3.new(1, 1, 1)
    h.OutlineTransparency = 0
    h.DepthMode    = Enum.HighlightDepthMode.AlwaysOnTop
    h.Parent       = screen()
    return h
end

local function makeBillboard()
    local ok, gui = pcall(function()
        local g = Instance.new("BillboardGui")
        g.Adornee      = nil
        g.Size         = UDim2.new(0, 220, 0, 60)
        g.StudsOffset  = Vector3.new(0, 3.2, 0)
        g.AlwaysOnTop  = true
        g.MaxDistance   = 1500
        g.Parent       = screen()
        return g
    end)
    if not ok or not gui then return nil end
    return gui, gui:FindFirstChild("Lbl") or Instance.new("TextLabel", gui)
end

-- 3D-КОРОБКИ. Drawing есть не во всех исполнителях — при отказе
-- просто отключаем коробки, скрипт не падает.
local DRAW_OK = false
do
    local ok, l = pcall(function() return Drawing.new("Line") end)
    if ok and l then
        l.Visible = false
        l:Remove()
        DRAW_OK = true
    end
end

local function makeBox()
    if not DRAW_OK then return nil end
    local b = {}
    b.lines = {}
    -- 12 РЁБЕР: 4 нижних + 4 верхних + 4 вертикальных.
    -- Раньше тут создавалось только 4 линии, а drawBox рисовал ими 12
    -- рёбер в цикле — линии затирали друг друга, и оставались лишь
    -- 4 вертикальные стойки. Отсюда «нет полосок сверху».
    for i = 1, 12 do
        local ok, ln = pcall(function() return Drawing.new("Line") end)
        if not ok or not ln then return nil end
        ln.Visible   = false
        ln.Thickness = G.BS.BoxThick
        ln.Color     = Color3.new(1, 1, 1)
        b.lines[i] = ln
    end
    return b
end

local function drawBox(b, root, cam)
    if not b or not b.lines then return end
    local pos, onScreen = workspace.CurrentCamera:WorldToViewportPoint(root.Position)
    if not onScreen or pos.Z <= 0 then
        for i = 1, #b.lines do b.lines[i].Visible = false end
        return
    end
    local function project(x, y, z)
        local v = workspace.CurrentCamera:WorldToViewportPoint(
            root.Position + Vector3.new(x, y, z))
        return v
    end
    local s = 1.5
    local h = 2.75
    local d = 1.0
    local p1 = project(-s, -h, -d)
    local p2 = project( s, -h, -d)
    local p3 = project( s, -h,  d)
    local p4 = project(-s, -h,  d)
    local p5 = project(-s,  h, -d)
    local p6 = project( s,  h, -d)
    local p7 = project( s,  h,  d)
    local p8 = project(-s,  h,  d)
    local corners = { p1, p2, p3, p4, p5, p6, p7, p8 }
    local idx = { {1,2},{2,3},{3,4},{4,1},{5,6},{6,7},{7,8},{8,5},{1,5},{2,6},{3,7},{4,8} }
    for i = 1, 12 do
        local a = corners[idx[i][1]]
        local b2 = corners[idx[i][2]]
        local ln = b.lines[i]
        if ln then
            ln.From = a
            ln.To   = b2
            ln.Visible = true
            ln.Color  = b.color or Color3.new(1, 1, 1)
            ln.Thickness = G.BS.BoxThick
        end
    end
end

local function hideBox(b)
    if not b or not b.lines then return end
    for i = 1, #b.lines do
        if b.lines[i] then b.lines[i].Visible = false end
    end
end

-- Полное уничтожение коробки. hideBox только прячет, а объекты Drawing
-- остаются жить -> при каждом респавне утекали линии. Remove() их
-- освобождает.
local function destroyBox(b)
    if not b or not b.lines then return end
    local n = #b.lines
    for i = 1, n do
        if b.lines[i] then pcall(function() b.lines[i]:Remove() end) end
        b.lines[i] = nil
    end
end

-- ============================================================
--  ДОБАВЛЕНИЕ / УДАЛЕНИЕ ИГРОКОВАVLENIE / UДАЛЕНИЕ IGROKOV
-- ============================================================
local applyRole

local function remove(plr)
    local e = by[plr]
    if not e then return end
    if e.hl then pcall(function() e.hl:Destroy() end) end
    if e.gui then pcall(function() e.gui:Destroy() end) end
    destroyBox(e.box)
    by[plr] = nil
    if locked == plr then locked = nil end
end

local function add(plr)
    local ch = plr.Character
    if not ch then return end
    local hl = makeHighlight()
    if not hl then return end
    local gui, lbl = makeBillboard()
    if not gui or not lbl then
        pcall(function() hl:Destroy() end)
        return
    end
    lbl.Size                  = UDim2.new(1, 0, 0, 40)
    lbl.BackgroundTransparency = 1
    lbl.TextSize               = 13
    lbl.Font                   = Enum.Font.Gotham
    lbl.TextStrokeTransparency = 0.4
    lbl.Text                   = ""
    lbl.Visible                = false
    lbl.Parent                 = gui

    hl.Adornee = ch
    gui.Adornee = ch
    by[plr] = {
        char = ch, hl = hl, gui = gui, lbl = lbl,
        role = nil, conf = 0, votes = 0, lastStable = nil, box = nil,
    }
end

applyRole = function(e, role, conf)
    if not e then return end
    if conf > e.conf then
        -- ВАЖНО: пишем lastStable здесь. Ранее этот путь не писал
        -- его, и при RoleSticks > 1 первая зафиксированная роль
        -- откатывалась через nil -> роль не показывалась ~5 секунд.
        e.role, e.conf, e.votes, e.lastStable = role, conf, 1, role
        return
    end
    if role == e.role then
        e.votes = e.votes + 1
        if e.votes >= math.max(1, G.BS.RoleSticks) then
            e.lastStable = role
        end
        return
    end
    if e.votes < math.max(1, G.BS.RoleSticks) then
        e.role = e.lastStable
        e.votes = 0
        return
    end
    e.role, e.conf, e.votes, e.lastStable = role, conf, 1, role
end

local function detectRole(plr)
    local e = by[plr]
    if not e then return end
    -- 1) atribut servera
    local r = roleFromAttr(plr)
    if r then
        applyRole(e, r, CONF.attr)
        return
    end
    -- 2) сети из ремоутов
    local nr = netRoles[plr]
    if nr then
        applyRole(e, nr, CONF.event)
        return
    end
    -- 3) zdravstvuyushchiy HP > 0 -> ne mertvy
    applyRole(e, nil, 0)
end

-- ============================================================
--  ОВЕРЛЕЙ (Frame вместо Drawing: работает везде)
-- ============================================================
local Overlay = nil
local FOVSegs  = {}
local FOV_N    = 48
local MarkLines = {}
local NameLabel = nil

local function mkSeg(parent)
    local s = Instance.new("Frame")
    s.BackgroundColor3       = Color3.new(1, 1, 1)
    s.BorderSizePixel        = 0
    s.AnchorPoint            = Vector2.new(0.5, 0.5)
    s.Size                   = UDim2.fromOffset(0, 0)
    s.BackgroundTransparency = 1
    s.ZIndex                 = 60
    s.Visible                = false
    s.Parent                 = parent
    return s
end

local function ensureOverlay()
    if Overlay and Overlay.Parent then return Overlay end
    Overlay = Instance.new("ScreenGui")
    Overlay.Name           = "BS_AIM"
    Overlay.ResetOnSpawn   = false
    Overlay.IgnoreGuiInset  = true
    Overlay.DisplayOrder   = 1
    Overlay.Parent         = game:GetService("CoreGui")
    for i = 1, FOV_N do FOVSegs[i] = mkSeg(Overlay) end
    for i = 1, 4 do MarkLines[i] = mkSeg(Overlay) end
    NameLabel = Instance.new("TextLabel")
    NameLabel.BackgroundTransparency = 1
    NameLabel.Size                   = UDim2.new(0, 320, 0, 22)
    NameLabel.AnchorPoint            = Vector2.new(0.5, 1)
    NameLabel.TextSize               = 13
    NameLabel.Font                   = Enum.Font.Gotham
    NameLabel.TextStrokeTransparency = 0.4
    NameLabel.Text                   = ""
    NameLabel.Visible                = false
    NameLabel.ZIndex                 = 62
    NameLabel.Parent                 = Overlay
    return Overlay
end

local function placeSeg(seg, from, to, thick, color, alpha)
    local dx = to.X - from.X
    local dy = to.Y - from.Y
    local len = math.sqrt(dx * dx + dy * dy)
    if len < 0.01 then seg.Visible = false return end
    seg.Size     = UDim2.new(0, len, 0, thick)
    seg.Position = UDim2.new(0, (from.X + to.X) / 2, 0, (from.Y + to.Y) / 2)
    seg.Rotation = math.deg(math.atan2(dy, dx))
    seg.BackgroundColor3       = color
    seg.BackgroundTransparency = alpha or 0
    seg.Visible = true
end

local function hideFOV()
    for i = 1, FOV_N do
        if FOVSegs[i] then FOVSegs[i].Visible = false end
    end
end

local function hideOverlay()
    if not Overlay then return end
    for i = 1, FOV_N do
        if FOVSegs[i] then FOVSegs[i].Visible = false end
    end
    for i = 1, 4 do
        if MarkLines[i] then MarkLines[i].Visible = false end
    end
    if NameLabel then NameLabel.Visible = false end
end

local function drawTarget(plr)
    ensureOverlay()
    if not plr then
        for i = 1, 4 do
            if MarkLines[i] then MarkLines[i].Visible = false end
        end
        if NameLabel then NameLabel.Visible = false end
        return
    end
    local ch = plr.Character
    local root = ch and ch:FindFirstChild("HumanoidRootPart")
    local cam = workspace.CurrentCamera
    if not root or not root.Parent or not cam then
        for i = 1, 4 do
            if MarkLines[i] then MarkLines[i].Visible = false end
        end
        if NameLabel then NameLabel.Visible = false end
        return
    end
    local head = ch:FindFirstChild("Head") or root
    local sp   = cam:WorldToViewportPoint(head.Position)
    if sp.Z <= 0 then
        for i = 1, 4 do
            if MarkLines[i] then MarkLines[i].Visible = false end
        end
        if NameLabel then NameLabel.Visible = false end
        return
    end
    local s = 9
    local function mark(i, fx, fy, tx, ty)
        placeSeg(MarkLines[i],
            Vector2.new(sp.X + fx * s, sp.Y + fy * s),
            Vector2.new(sp.X + tx * s, sp.Y + ty * s),
            2, G.BS.AimMarkColor)
    end
    mark(1, -1, -1, 0, -1)
    mark(2, 0, -1, 1, -1)
    mark(3, -1, 0, -1, 1)
    mark(4, 1, 0, 0, 1)
    if NameLabel then
        NameLabel.Position = UDim2.new(0, sp.X, 0, sp.Y - 14)
        NameLabel.TextColor3 = G.BS.AimMarkColor
        NameLabel.Visible = true
    end
end

-- ============================================================
--  РЕЙКАСТ ВИДИМОСТИ + ВЫБОР ЧАСТИ ТЕЛА
-- ============================================================
local RAY = RaycastParams.new()
RAY.FilterType = Enum.RaycastFilterType.Exclude
RAY.IgnoreWater = true

local function visible(from, part, ch)
    if G.BS.Penetrate then return true end
    -- Ранее здесь было `{ LP.Character }`: в Lua таблица с nil ВНУТРИ
    -- ПУСТАЯ, и луч шёл сквозь себя. Исключаем оба.
    local me = LP and LP.Character
    RAY.FilterDescendantsInstances = me and { me, ch } or { ch }
    local dir = part.Position - from
    local mag = dir.Magnitude
    if mag < 0.05 then return true end
    local hit = workspace:Raycast(from, dir.Unit * math.max(mag - 0.4, 0.05), RAY)
    if hit == nil then return true end
    return hit.Instance:IsDescendantOf(ch)
end

local function lockPart(ch, from)
    local p = ch:FindFirstChild(G.BS.AimPart)
    if p and p:IsA("BasePart") and p.Parent then return p end
    for _, n in ipairs(AIM_PART) do
        local q = ch:FindFirstChild(n)
        if q and q:IsA("BasePart") and q.Parent then return q end
    end
    return ch:FindFirstChild("HumanoidRootPart")
end

local function isEnemy(plr)
    local e = by[plr]
    if not e then return true end
    local me = string.lower(tostring(G.BS.MyRole or "?"))
    -- ВАЖНО: G.BS.AimTargets — это СТРОКА из AIM_TARGETS, а не индекс.
    -- Раньше тут было AIM_TARGETS[G.BS.AimTargets], то есть поиск по
    -- строке в массиве -> всегда nil -> фильтр не работал и аим бил
    -- по всем подряд (включая своих).
    local t  = G.BS.AimTargets
    if t == "Только вампиров" then
        if e.role and e.role ~= "vampire" then return false end
        return true
    elseif t == "Только людей" then
        if e.role == "vampire" then return false end
        return true
    elseif t == "Противники по роли" then
        if e.role and me ~= "?" and e.role ~= me then return true end
        return e.role == nil
    end
    return true
end

local function targetPart(plr, cam)
    local ch = plr.Character
    if not ch or not ch.Parent then return nil end
    local hum = ch:FindFirstChildOfClass("Humanoid")
    if not hum then return nil end
    if hum.Health <= 0 then return nil end
    local root = ch:FindFirstChild("HumanoidRootPart")
    if not root then return nil end
    local d = (root.Position - cam.CFrame.Position).Magnitude
    if G.BS.AimMaxDist > 0 and d > G.BS.AimMaxDist then return nil end
    local p = lockPart(ch, cam.CFrame.Position)
    if not p then return nil end
    if not G.BS.Penetrate and not visible(cam.CFrame.Position, p, ch) then return nil end
    return p
end

local function pickTarget(cam)
    if locked and locked.Parent and by[locked] then
        if isEnemy(locked) then
            if targetPart(locked, cam) then return locked end
        end
        locked = nil
    end
    local best, bestScore = nil, nil
    -- РАДИУС ЗАХВАТА. Раньше его не было вообще: слайдер «Радиус захвата»
    -- не влиял ни на что, цель выбиралась из всех, кто просто перед камерой,
    -- то есть радиус фактически был бесконечным (жалобы «через всю карту»).
    -- Теперь 600 px = без ограничения, любое меньшее значение = реальный круг.
    local vp  = cam.ViewportSize
    local ccx, ccy = vp.X * 0.5, vp.Y * 0.5
    local fov = tonumber(G.BS.AimFOV) or 160
    if fov < 0 then fov = 0 end
    local unlimited = fov >= 600
    for _, plr in ipairs(Players:GetPlayers()) do
        if plr ~= LP and by[plr] and isEnemy(plr) then
            local p = targetPart(plr, cam)
            if p then
                local sp = cam:WorldToViewportPoint(p.Position)
                if sp.Z > 0 then
                    -- отсечка по радиусу, иначе берём кого угодно с карты
                    if not unlimited then
                        local dx, dy = sp.X - ccx, sp.Y - ccy
                        if (dx * dx + dy * dy) > (fov * fov) then
                            p = nil
                        end
                    end
                    if p then
                    local dist = (p.Position - cam.CFrame.Position).Magnitude
                    local score
                    if G.BS.AimPriority == "Ближе по расстоянию" then
                        score = dist
                    elseif G.BS.AimPriority == "Больше HP" then
                        local hum = plr.Character:FindFirstChildOfClass("Humanoid")
                        score = -(hum and hum.Health or 100)
                    else
                        score = dist
                    end
                    if not bestScore or score < bestScore then
                        bestScore, best = score, plr
                    end
                    end
                end
            end
        end
    end
    locked = best
    return best
end

-- ============================================================
--  СЛУШАНИЕ РЕМОУТОВ: РОЛИ + СТАМИНА
-- ============================================================
local function rolesFromEvents()
    if not G.BS.EventRole then return end
    local now = os.clock()
    for model, t in pairs(burstShooters) do
        if (now - t) > 20 then burstShooters[model] = nil end
    end
    for model, r in pairs(revealMap) do
        if (now - r.t) > 25 then revealMap[model] = nil end
    end
end

local function rolesFromSounds()
    if not G.BS.SoundRole then return end
    local now = os.clock()
    local rad = math.max(5, G.BS.SoundRadius)
    for _, m in ipairs(soundMarks) do
        -- В Lua нет `continue`, поэтому через условие
        if (now - m.t) <= 10 then
        local s = string.lower(m.s)
        local kind
        if string.find(s, "gun", 1, true) or string.find(s, "shot", 1, true)
           or string.find(s, "pistol", 1, true) or string.find(s, "rifle", 1, true) then
            kind = "hunter"
        end
        if kind then
            for _, e in pairs(by) do
                local root = e.char and e.char:FindFirstChild("HumanoidRootPart")
                if root and root.Parent and (root.Position - m.pos).Magnitude <= rad then
                    applyRole(e, kind, CONF.sound)
                    break
                end
            end
        end
        end
    end
end

-- ТИХИЙ ПЕРЕХВАТ РОЛЕЙ. Консоль не засоряется.
if Remotes then
    for _, r in ipairs(Remotes:GetChildren()) do
        if r:IsA("RemoteEvent") then
            local c = r.OnClientEvent:Connect(function(...)
                local args = table.pack(...)
                for i = 1, args.n do
                    -- RoundState: {phase, vampires, hunters}
                    if r.Name == "RoundState" and i == 1 and type(args[i]) == "table" then
                        local st = args[i]
                        G.BS.RoundPhase   = tostring(st.phase or "?")
                        G.BS.RoundVamps   = tonumber(st.vampires) or 0
                        G.BS.RoundHunters = tonumber(st.hunters) or 0
                        if G.BS.RoundPhase ~= G.BS.LastPhase then
                            if G.BS.RoundPhase == "Lobby" then resetRound() end
                            G.BS.LastPhase = G.BS.RoundPhase
                        end
                    end
                    -- RoleAssigned
                    if r.Name == "RoleAssigned" and i == 1 then
                        local k = aliasOf(args[i]) or string.lower(tostring(args[i] or ""))
                        if k and k ~= "none" then G.BS.MyRole = k end
                    end
                    -- SoundPing {pos, sound}
                    if r.Name == "SoundPing" and i == 1 and typeof(args[i]) == "Vector3" then
                        soundMarks[#soundMarks + 1] = {
                            pos = args[i], s = tostring(args[2] or ""), t = os.clock(),
                        }
                        if #soundMarks > 40 then table.remove(soundMarks, 1) end
                    end
                    -- BurstFX #4 = Model(strelka) -> hunter
                    if r.Name == "BurstFX" and args.n >= 4
                       and typeof(args[4]) == "Instance" and args[4]:IsA("Model") then
                        burstShooters[args[4]] = os.clock()
                    end
                    -- Announce {name, role} -> otlozhennoye raskrytie
                    if r.Name == "Announce" and i == 1 and type(args[i]) == "table" then
                        local a = args[i]
                        if a.name and a.role then
                            pendingReveal = { role = aliasOf(a.role), t = os.clock() }
                        end
                    end
                    -- ForensicsFeed {type="testresult", vampire=bool}
                    if r.Name == "ForensicsFeed" and i == 1 and type(args[i]) == "table" then
                        local f = args[i]
                        if f.type == "testresult" and f.name then
                            pendingReveal = {
                                role = (f.vampire == true) and "vampire" or "hunter",
                                t = os.clock(),
                            }
                        end
                    end
                    -- DetectionFeed redoutline: skleivaem s Announce
                    if r.Name == "DetectionFeed" and i == 1 and type(args[i]) == "table" then
                        local d = args[i]
                        if d.type == "redoutline" and typeof(d.target) == "Instance" then
                            if pendingReveal and (os.clock() - pendingReveal.t) < 4 then
                                revealMap[d.target] = {
                                    role = pendingReveal.role, t = os.clock(),
                                }
                                pendingReveal = nil
                            end
                        end
                    end
                end
            end)
            netConns[#netConns + 1] = c
        end
    end
end

-- ============================================================
--  СТАМИНА (Remotes.UseEnergy) и ЗАЩИТА ОТ УРОНА (Humanoid:TakeDamage)
-- ============================================================
-- Оба перехватываются ЕДИНЫМ хуком __namecall (см. ниже). Отдельные
-- hookmetamethod(ue, "FireServer") / hookmetamethod(hum, "TakeDamage")
-- в этом исполнителе НЕ работают: он принимает только имена
-- метаметодов. Поэтому здесь только запуск общего хука.
local damageBlocked = 0

local function patchEnergy()
    if installNamecall then pcall(installNamecall) end
end

local function installDamageHooks()
    if installNamecall then pcall(installNamecall) end
end

local function pumpHealth()
    local ch = LP and LP.Character
    if not ch then return end
    local hum = ch:FindFirstChildOfClass("Humanoid")
    if not hum or not hum.Parent then return end
    pcall(function()
        if hum.MaxHealth ~= G.BS.HealthMax then hum.MaxHealth = G.BS.HealthMax end
        if hum.Health < G.BS.HealthMax then hum.Health = G.BS.HealthMax end
    end)
end

-- ============================================================
--  СКАНЕР: SLIV INFO OB IGRE V KONSOL
-- ============================================================
local function hr(t)
    print("[BS SCAN] " .. string.rep("=", 46))
    print(t)
end

local function scanAll()
    if not Remotes then print("[BS SCAN] папка Remotes НЕ НАЙДЕНА") return end

    hr("РЕМОУТЫ (" .. #Remotes:GetChildren() .. " шт)")
    local names = {}
    for _, r in ipairs(Remotes:GetChildren()) do names[#names + 1] = r.Name end
    table.sort(names)
    for i = 1, #names do print(string.format("  %2d. %s", i, names[i])) end

    -- ВСЕ ремоуты игры, не только папка Remotes: урон может уходить
    -- отдельным ремоутом с другим путём.
    hr("ВСЕ РЕМОУТЫ В ИГРЕ (RemoteEvent / RemoteFunction)")
    local rc, shown = 0, 0
    for _, d in ipairs(game:GetDescendants()) do
        local cls = d.ClassName
        if cls == "RemoteEvent" or cls == "RemoteFunction"
           or cls == "UnreliableRemoteEvent" then
            rc = rc + 1
            if shown < 150 then
                shown = shown + 1
                local path = d:GetFullName()
                if #path > 110 then path = "..." .. string.sub(path, -107) end
                print("  " .. path)
            end
        end
    end
    print("  ВСЕГО: " .. rc)

    hr("ВЫРАН ЗАКЛЮЧЕНЫ ХУКИ")
    print("  __namecall     : " .. tostring(NC.installed)
        .. " (orig=" .. tostring(NC.orig ~= nil) .. ")")
    print("  FireWeapon     : " .. tostring(NC.fw ~= nil))
    print("  UseEnergy      : " .. tostring(NC.ue ~= nil))
    print("  getnamecallmethod: " .. tostring(type(getnamecallmethod)))
    print("  getrawmetatable: " .. tostring(type(getrawmetatable)))
    print("  setreadonly    : " .. tostring(type(setreadonly)))

    local ch = LP and LP.Character
    if ch then
        hr("ЗНАЧЕНИЯ В ПЕРСОНАЖЕ (NumberValue / IntValue)")
        local cnt = 0
        for _, d in ipairs(ch:GetDescendants()) do
            if d:IsA("NumberValue") or d:IsA("IntValue") then
                cnt = cnt + 1
                print(string.format("  %s = %s", d.Name, tostring(d.Value)))
            end
        end
        if cnt == 0 then print("  (нет ни одного)") end

        hr("АТРИБУТЫ ПЕРСОНАЖА")
        local a = 0
        for k, v in pairs(ch:GetAttributes()) do
            a = a + 1
            print(string.format("  %s = %s (%s)", tostring(k), tostring(v), typeof(v)))
        end
        if a == 0 then print("  (нет атрибутов)") end

        local hum = ch:FindFirstChildOfClass("Humanoid")
        if hum then
            hr("ГУМАНОИД")
            print("  Health = " .. tostring(hum.Health)
                .. "  MaxHealth = " .. tostring(hum.MaxHealth)
                .. "  WalkSpeed = " .. tostring(hum.WalkSpeed))
        end
    end

    hr("МОЯ РОЛЬ")
    print("  G.BS.MyRole    = " .. tostring(G.BS.MyRole))
    print("  RoundPhase     = " .. tostring(G.BS.RoundPhase))
    print("  вампир/хантер  = " .. tostring(G.BS.RoundVamps) .. "/" .. tostring(G.BS.RoundHunters))

    -- РОЛИ ИГРОКОВ. Печатаем только то, что похоже на роль (иначе
    -- консоль забивалась сотнями строк косметики и было нечитаемо).
    hr("РОЛИ ИГРОКОВ (откуда берём)")
    for _, plr in ipairs(Players:GetPlayers()) do
        local found, src = roleFromInstance(plr)
        print(string.format("  %s -> %s (%s)", plr.Name,
            tostring(found), tostring(src or "-")))
        local okA, attrs = pcall(function() return plr:GetAttributes() end)
        if okA and type(attrs) == "table" then
            for k, v in pairs(attrs) do
                if string.lower(tostring(k)) == "role" or aliasOf(v) then
                    print(string.format("      player.%s = %s",
                        tostring(k), tostring(v)))
                end
            end
        end
        local pch = plr.Character
        if pch then
            local okC, cattrs = pcall(function() return pch:GetAttributes() end)
            if okC and type(cattrs) == "table" then
                for k, v in pairs(cattrs) do
                    if string.lower(tostring(k)) == "role" or aliasOf(v) then
                        print(string.format("      char.%s = %s",
                            tostring(k), tostring(v)))
                    end
                end
            end
        end
    end

    hr("ТЕПЕРЬ ВЫСТРЕЛИ С ДИАГНОСТИКОЙ ПАТРОНА")
end

-- ============================================================
--  ГЛУБОКОЕ СКАНИРОВАНИЕ (кнопка в ESP)
-- ============================================================
-- Перечитывает ВСЁ, что нужно для аима: структуру игры, модули
-- (через require с дампом таблиц), что лежит в руках/рюкзаке.
-- По этому выводу видно, чем сервер проверяет выстрел и почему
-- стена не пробивается.
local function valToStr(v)
    local t = typeof(v)
    if t == "Vector3" then
        return string.format("Vector3(%.1f, %.1f, %.1f)", v.X, v.Y, v.Z)
    elseif t == "number" then
        return string.format("%.3f", v)
    elseif t == "string" then
        return string.format("%s", v)
    elseif t == "boolean" then
        return tostring(v)
    elseif t == "Instance" then
        return v.ClassName .. " " .. v.Name
    elseif t == "Player" then
        return "Player " .. v.Name
    elseif t == "function" then
        return "<функция>"
    end
    return t
end

local function dumpTable(label, t, maxKeys, depth)
    if type(t) ~= "table" then return end
    local n = 0
    pcall(function()
        for k, v in pairs(t) do
            n = n + 1
            if n > maxKeys then break end
            if type(v) == "table" and depth > 0 then
                print("    " .. label .. "." .. tostring(k) .. " = {таблица}")
                dumpTable(label .. "." .. tostring(k), v, maxKeys, depth - 1)
            else
                print("    " .. label .. "." .. tostring(k) .. " = " .. valToStr(v))
            end
        end
    end)
end

-- ДАМП ИНСТАНСА (атрибуты + дети). Используется точечно.
local function dumpInst(inst, prefix)
    local okA, at = pcall(function() return inst:GetAttributes() end)
    if okA and type(at) == "table" then
        for k, v in pairs(at) do
            print("    " .. prefix .. tostring(k) .. " = " .. valToStr(v))
        end
    end
    local okC, kids = pcall(function() return inst:GetChildren() end)
    if okC and type(kids) == "table" then
        for _, c in ipairs(kids) do
            print("    " .. prefix .. c.Name .. " [" .. c.ClassName .. "]")
        end
    end
end

-- МОДУЛЬ НЕ ИНТЕРЕСУЕТ (внутренние пакеты Roblox) — их сотни, и
-- они забивали весь вывод, а нужные модули игры не печатались.
local function isRobloxInternal(path)
    return string.find(path, "CorePackages", 1, true) ~= nil
        or string.find(path, "_Index.", 1, true) ~= nil
        or string.find(path, "_Workspace.", 1, true) ~= nil
end

-- ВАЖНЫЕ МОДУЛИ ИГРЫ: сначала они, с require + дампом.
local DEEP_PRIORITY = {
    "Combat", "Ballistics", "Murder", "Mystery", "Loadout", "Match",
    "Roles", "Detection", "ToolCooldown", "Disarm", "NearestInFront",
    "GameModes", "PlayerState", "Config", "Shop", "Lootboxes",
}

local function requireDump(mod, label, maxKeys, depth)
    local okr, mod2 = pcall(require, mod)
    if okr and type(mod2) == "table" then
        dumpTable(label, mod2, maxKeys or 40, depth or 2)
        return true
    end
    print("     (require: " .. tostring(mod2) .. ")")
    return false
end

local function deepScan()
    hr("ГЛУБОКОЕ СКАНИРОВАНИЕ")
    local base = TRS:FindFirstChild("BloodyStreet")
    if not base then
        print("[BS DEEP] ReplicatedStorage.BloodyStreet НЕ НАЙДЕН")
        return
    end

    hr("СТРУКТУРА ReplicatedStorage.BloodyStreet")
    for _, d in ipairs(base:GetChildren()) do
        local ok, kids = pcall(function() return d:GetChildren() end)
        local n = 0
        if ok and type(kids) == "table" then n = #kids end
        print(string.format("  %s [%s]  потомков: %d", d.Name, d.ClassName, n))
        if ok and type(kids) == "table" and n > 0 then
            local names = {}
            for _, c in ipairs(kids) do
                names[#names + 1] = c.Name .. "[" .. c.ClassName .. "]"
            end
            table.sort(names)
            local line = "     "
            for i = 1, math.min(#names, 40) do line = line .. names[i] .. ", " end
            print(line)
        end
    end

    -- 1) ВАЖНЫЕ МОДУЛИ ИГРЫ: require + полный дамп их таблиц.
    hr("МОДУЛИ ИГРЫ (require + содержимое таблиц)")
    for _, nm in ipairs(DEEP_PRIORITY) do
        local m = base:FindFirstChild(nm)
        local okF, found = pcall(function()
            if m then return m end
            for _, d in ipairs(base:GetDescendants()) do
                if d.ClassName == "ModuleScript" and d.Name == nm then return d end
            end
            return nil
        end)
        if okF and found and found.ClassName == "ModuleScript" then
            local okP, fp = pcall(function() return found:GetFullName() end)
            print("  " .. (okP and fp or nm))
            pcall(requireDump, found, nm, 60, 2)
        end
    end

    -- 2) ОСТАЛЬНЫЕ МОДУЛИ ИГРЫ: только список (require слишком шумно).
    hr("ВСЕ МОДУЛИ ИГРЫ (список)")
    local okl, all = pcall(function() return game:GetDescendants() end)
    local cnt = 0
    if okl and type(all) == "table" then
        for _, d in ipairs(all) do
            if d.ClassName == "ModuleScript" then
                local okP, fp = pcall(function() return d:GetFullName() end)
                local path = okP and fp or d.Name
                if not isRobloxInternal(path) and cnt < 200 then
                    cnt = cnt + 1
                    print("  " .. path)
                end
            end
        end
    end
    print("  модулей игры (без внутренних Roblox): " .. cnt)

    -- 3) ОРУЖИЕ И ПЕРСОНАЖ: коротко, без анимаций и аксессуаров.
    hr("МОЙ ПЕРСОНАЖ (кратко)")
    local ch = LP and LP.Character
    if ch then
        local okA, at = pcall(function() return ch:GetAttributes() end)
        if okA and type(at) == "table" then
            for k, v in pairs(at) do print("  char." .. tostring(k) .. " = " .. valToStr(v)) end
        end
        local hum = ch:FindFirstChildOfClass("Humanoid")
        if hum then
            print(string.format("  Humanoid: HP=%.0f/%.0f  WalkSpeed=%d",
                hum.Health, hum.MaxHealth, hum.WalkSpeed))
        end
        local tool = ch:FindFirstChildOfClass("Tool")
        if tool then
            print("  ОРУЖИЕ: " .. tool.Name)
            dumpInst(tool, "    ")
            for _, d in ipairs(tool:GetChildren()) do
                local extra = ""
                if d:IsA("Attachment") then
                    extra = string.format("  WorldPosition=(%.1f, %.1f, %.1f)",
                        d.WorldPosition.X, d.WorldPosition.Y, d.WorldPosition.Z)
                elseif d:IsA("BasePart") then
                    extra = string.format("  size=(%.2f, %.2f, %.2f) pos=(%.1f, %.1f, %.1f)",
                        d.Size.X, d.Size.Y, d.Size.Z,
                        d.Position.X, d.Position.Y, d.Position.Z)
                end
                print("    " .. d.Name .. " [" .. d.ClassName .. "]" .. extra)
            end
        else
            print("  (оружия в руках нет)")
        end
    else
        print("  (персонажа нет)")
    end

    hr("ГЛУБОКОЕ СКАНИРОВАНИЕ ЗАКОНЧЕНО")
end

-- ============================================================
--  КЛИЕНТ АИМ: ПОДМЕНА ПАТРОНА (Remotes.FireWeapon)
-- ============================================================
-- Сигнатуру FireWeapon мы не знаем, поэтому хук не угадывает один
-- вариант, а смотрит на ФАКТИЧЕСКИЕ аргументы при выстреле:
--   - ищем Vector3, который не похож на позицию ствола (то есть не
--     рядом с нами), и берём самый длинный — это направление выстрела;
--   - подменяем его на вектор к цели, СОХРАНЯЯ длину (не меньше
--     расстояния до цели) — иначе пуля летит верно, но не достаёт;
--   - если Vector3 нет, но есть Instance/Player — считаем это целью;
--   - если ничего не распознали — стреляем КАК ЕСТЬ, без подмены.
local sigLogged = false

local function pickPartOf(ch)
    local p = ch:FindFirstChild(G.BS.AimPart)
    if p and p:IsA("BasePart") and p.Parent then return p end
    for _, nm in ipairs(AIM_PART) do
        local q = ch:FindFirstChild(nm)
        if q and q:IsA("BasePart") and q.Parent then return q end
    end
    return nil
end

-- ВЫЧИСЛЯЕТСЯ КАЖДЫЙ КАДР, чтобы в хуке ничего не искать.
local function computeBulletPreShot()
    if not G.BS.BulletSwap then bulletPreShot = nil return end
    local cam = workspace.CurrentCamera
    local myRoot = LP and LP.Character and LP.Character:FindFirstChild("HumanoidRootPart")
    if not cam or not myRoot or not myRoot.Parent then
        bulletPreShot = nil
        return
    end

    -- ПРИОРИТЕТ ЦЕЛИ:
    --   1) тот, кто ПОД ПРИЦЕЛОМ (близко к центру экрана) — тогда пуля
    --      идёт именно в того, в кого ты стреляешь;
    --   2) если под прицелом никого — ближайший по расстоянию.
    -- Раньше брался только ближайший по расстоянию, поэтому выстрел
    -- в дальнего врага уходил в ближнего, который стоял сбоку.
    local vp  = cam.ViewportSize
    local ccx, ccy = vp.X * 0.5, vp.Y * 0.5
    -- «Под прицелом» = в пределах ~трети экрана от центра. Шире, чем
    -- раньше (жёсткие 220 px): дальний враг на экране занимает всего
    -- пару пикселей, и в узкий круг он не попадал.
    local CONE = math.max(220, math.floor(vp.Y * 0.35))
    local CONE2 = CONE * CONE

    local bestAim,  bestAimS    -- под прицелом: у кого МЕНЬШЕ расстояние
                                -- до центра экрана, тот и цель
    local bestNear, bestNearD   -- иначе — ближайший по расстоянию
    for _, plr in ipairs(Players:GetPlayers()) do
        if plr ~= LP and by[plr] and isEnemy(plr) then
            local ch = plr.Character
            local hum = ch and ch:FindFirstChildOfClass("Humanoid")
            if ch and ch.Parent and hum and hum.Health > 0 then
                local q = pickPartOf(ch)
                if q then
                    local d = (q.Position - myRoot.Position).Magnitude
                    if G.BS.AimMaxDist <= 0 or d <= G.BS.AimMaxDist then
                        if not bestNearD or d < bestNearD then
                            bestNear, bestNearD = q, d
                        end
                        local sp = cam:WorldToViewportPoint(q.Position)
                        if sp.Z > 0 then
                            local dx, dy = sp.X - ccx, sp.Y - ccy
                            local s2 = dx * dx + dy * dy
                            if s2 <= CONE2 then
                                if not bestAimS or s2 < bestAimS then
                                    bestAim, bestAimS = q, s2
                                end
                            end
                        end
                    end
                end
            end
        end
    end
    local best = bestAim or bestNear

    if not best then
        bulletPreShot = nil
        return
    end

    -- ТОЧКА ВЫЛЕТА — КАМЕРА, а не HumanoidRootPart.
    -- Раньше направление считалось от корня (пояс, ~3.5 студа), а игра
    -- пускает пулю от камеры/головы (~5 студов). Разница по высоте
    -- (~1.5 студа) уходила прямо в прицел: пуля летела ВЫШЕ головы
    -- ровно на эту разницу — и на близкой, и на дальней дистанции.
    -- Считаем от камеры: именно оттуда игра и стреляет.
    -- Можно поменять на ходу: getgenv().BS.AimOrigin = "head" / "root".
    local srcPos
    local originMode = G.BS.AimOrigin
    if originMode == "root" then
        srcPos = myRoot.Position
    elseif originMode == "head" then
        local myHead = LP.Character and LP.Character:FindFirstChild("Head")
        srcPos = (myHead and myHead.Position) or cam.CFrame.Position
    else
        -- "camera": берём НАСТОЯЩИЙ ствол. У оружия есть Attachment
        -- "Muzzle" — это ровно та точка, которую игра кладёт первым
        -- аргументом FireWeapon. Если ствола нет — камера.
        local tool = LP.Character and LP.Character:FindFirstChildOfClass("Tool")
        local mz = tool and tool:FindFirstChild("Muzzle")
        srcPos = (mz and mz:IsA("Attachment") and mz.WorldPosition)
            or cam.CFrame.Position
    end

    -- ОПЕРЕЖЕНИЕ ЦЕЛИ — фиксированное, без слайдера. Без него по бегущим
-- не попадает физически: пакет идёт до сервера ~0.1 с, за это время
-- цель убегает на 1.5-2 студа, а голова — всего 1.2.
-- Меняется из консоли (слайдера в GUI нет):
--   getgenv().BS.AimLead = 0     -- выключить совсем
--   getgenv().BS.AimLead = 0.15  -- сильнее забег вперёд

    local aimPos = best.Position
    do
        local lead = tonumber(G.BS.AimLead) or 0
        if lead > 0 then
            local vel = best.AssemblyLinearVelocity
            if vel and vel.Magnitude > 1 then
                aimPos = aimPos + vel * lead
            end
        end
    end

    local dir = aimPos - srcPos
    local dist = dir.Magnitude
    if dist < 0.001 then
        bulletPreShot = nil
        return
    end
    bulletPreShot = {
        part = best,     -- цель (Instance)
        pos  = aimPos,   -- куда целимся
        src  = srcPos,   -- откуда стреляем
        dist = dist,     -- расстояние до цели
        dir  = dir.Unit, -- направление
    }
end

-- ============================================================
--  ЕДИНЫЙ ХУК __namecall
--  (прострел стен / клиент айм + блок стамины + защита от урона)
-- ============================================================
-- ГЛАВНАЯ ПРИЧИНА ПАДЕНИЙ ИГРЫ (v8.6 и раньше) — это НЕ newcclosure,
-- а область видимости локальной переменной в Lua:
--
--   local old = hookmetamethod(game, "__namecall", function(self, ...)
--       return old(self, ...)   -- <-- здесь old ГЛОБАЛЬНАЯ (nil)!
--   end)
--
-- В Lua область видимости `local old` начинается ТОЛЬКО ПОСЛЕ
-- объявления. Поэтому внутри функции справа `old` — не та переменная,
-- что объявляется, а глобальная (nil). Итог: на КАЖДЫЙ вызов через
-- ":" в игре (FindFirstChild, FireServer, ...) хук делал
-- "attempt to call a nil value". Отсюда сыпались GarlicController,
-- ControlModule, CameraModule, InputLock, HotbarController.
--
-- ЛЕЧЕНИЕ: forward-декларация (`local old` + отдельное присвоение) и
-- получение оригинала из СЫРОЙ метатаблицы, чтобы вообще не зависеть
-- от того, что вернёт hookmetamethod.

-- ВАЖНО: внутри хука нельзя вызывать методы через ":" (FindFirstChild,
-- FindFirstChildOfClass, ...) — это снова namecall и рекурсия. Поэтому
-- все нужные Instance кэшируем снаружи, в refreshHookTargets().
local function refreshHookTargets()
    if Remotes then
        NC.fw = Remotes:FindFirstChild("FireWeapon")
        NC.ue = Remotes:FindFirstChild("UseEnergy")
    end
    local ch = LP and LP.Character
    NC.myHum = (ch and ch:FindFirstChildOfClass("Humanoid")) or nil
end

-- Подмена аргументов выстрела. Возвращает (out, n) либо nil.
local function ncFireWeapon(...)
    local pre = bulletPreShot
    if not (pre and pre.part and pre.part.Parent and pre.dir) then return nil end
    local n = select("#", ...)
    if n < 1 then return nil end

    local args = table.pack(...)
    local out = {}
    for i = 1, n do out[i] = args[i] end

    -- ПОДМЕНА ПО ФАКТИЧЕСКОЙ СИГНАТУРЕ FireWeapon. По логу ремоутов:
    --   1: Vector3 — точка вылета (рядом с нами: ствол/камера)
    --   2: Vector3 — направление выстрела (единичный вектор с разбросом)
    --   3: number  — seed разброса
    --   4: table   — данные выстрела
    --   5: number  — время выстрела
    -- Раньше подменялся «самый длинный НЕ похожий на позицию» вектор —
    -- это оказался аргумент №2, а точку вылета (№1) мы не трогали,
    -- поэтому сервер пускал луч от НАС и стена его гасила.
    local myPos = pre.src
    local posIdx, posFar = nil, nil     -- «мировая точка» рядом с нами
    local dirIdx, dirLen = nil, nil     -- короткий вектор = направление
    for i = 1, n do
        if typeof(out[i]) == "Vector3" then
            local v = out[i]
            local len = v.Magnitude
            local near = myPos and (v - myPos).Magnitude or nil
            if near and len > 8 and near < 30 then
                -- из нескольких точек берём самую далёкую от камеры:
                -- это конец луча, а не сам ствол
                if not posFar or near > posFar then
                    posIdx, posFar = i, near
                end
            elseif not dirLen or len > dirLen then
                dirIdx, dirLen = i, len
            end
        end
    end

    local replaced = false
    local bits = {}

    -- НАПРАВЛЕНИЕ СЧИТАЕМ ОТ ТОЧКИ ВЫЛЕТА САМОЙ ИГРЫ (аргумент №1),
    -- а НЕ от камеры. Сервер пускает луч именно от этой точки, поэтому
    -- так попадание точное: нет ошибки из-за того, что камера смещена
    -- назад/в сторону от ствола. Именно из-за этой разницы пуля уходила
    -- мимо головы.
    local aimDir, aimDist = pre.dir, pre.dist
    if posIdx and typeof(out[posIdx]) == "Vector3" then
        local v = pre.pos - out[posIdx]
        if v.Magnitude > 0.001 then
            aimDir  = v.Unit
            aimDist = v.Magnitude
        end
    end

    -- 1) НАПРАВЛЕНИЕ. Длину НЕ уменьшаем: если игра берёт из неё
    --    дальность полёта (или вообще складывает origin + vector как
    --    конечную точку), короткий вектор = короткий выстрел.
    if dirIdx then
        local base = dirLen or 1
        if base < aimDist then base = aimDist end
        if base < 1 then base = 1 end
        if base > 20000 then base = 20000 end
        out[dirIdx] = aimDir * base
        replaced = true
        bits[#bits + 1] = "направление #" .. tostring(dirIdx)
    end

    -- 2) ТОЧКА ВЫЛЕТА. По умолчанию НЕ трогаем (SpoofBack = 0): сервер
    --    всё равно считает луч от игрока, а подмена точки вылета
    --    приводила к тому, что выстрел просто не засчитывался.
    --    Включить из консоли: getgenv().BS.SpoofBack = 6
    if posIdx then
        local back = tonumber(G.BS.SpoofBack) or 0
        if back > 0 then
            if back > 100 then back = 100 end
            out[posIdx] = pre.pos - aimDir * back
            replaced = true
            bits[#bits + 1] = "точка вылета #" .. tostring(posIdx)
        end
    end

    -- 3) нет распознанных векторов -> возможно цель передаётся объектом
    if not replaced then
        for i = n, 1, -1 do
            local t = typeof(out[i])
            if t == "Instance" or t == "Player" then
                out[i] = pre.part
                replaced = true
                bits[#bits + 1] = "объект-цель #" .. tostring(i)
                break
            end
        end
    end
    local how = (#bits > 0) and table.concat(bits, " + ") or nil

    -- ДИАГНОСТИКА: печатаем не только типы, но и ЗНАЧЕНИЯ — по ним
    -- видно, какой аргумент за что отвечает.
    if G.BS.BulletDebug and not sigLogged then
        sigLogged = true
        local list = {}
        local show = n
        if show > 14 then show = 14 end
        for i = 1, show do
            local t = typeof(args[i])
            local val = nil
            if t == "Vector3" then
                val = string.format("%.1f, %.1f, %.1f",
                    args[i].X, args[i].Y, args[i].Z)
            elseif t == "number" then
                val = string.format("%.2f", args[i])
            elseif t == "string" then
                val = args[i]
            elseif t == "boolean" then
                val = tostring(args[i])
            elseif t == "Instance" then
                val = args[i].ClassName .. " " .. args[i].Name
            elseif t == "Player" then
                val = "Player " .. args[i].Name
            end
            list[i] = i .. ":" .. t .. (val and (" (" .. val .. ")") or "")
        end
        print("[BS BULLET] аргументов " .. n .. ": " .. table.concat(list, " | "))
        print(string.format("[BS BULLET] цель=%s дистанция=%.1f -> %s",
            pre.part.Name, pre.dist, how or "СИГНАТУРА НЕ РАСПОЗНАНА"))

        -- ДАМП ТАБЛИЧНЫХ арГУМЕНТОВ. В FireWeapon 4-й аргумент — это
        -- table: там может лежать цель, точка попадания, урон. Если
        -- сервер доверяет этим данным, через них можно пробить стену.
        for i = 1, n do
            if typeof(args[i]) == "table" then
                local keys, cnt = {}, 0
                pcall(function()
                    for k, v in pairs(args[i]) do
                        cnt = cnt + 1
                        if cnt <= 14 then
                            local t = typeof(v)
                            local s
                            if t == "Vector3" then
                                s = string.format("%.1f, %.1f, %.1f", v.X, v.Y, v.Z)
                            elseif t == "number" or t == "string" or t == "boolean" then
                                s = tostring(v)
                            elseif t == "Instance" then
                                s = v.ClassName .. " " .. v.Name
                            elseif t == "Player" then
                                s = "Player " .. v.Name
                            elseif t == "table" then
                                s = "{...}"
                            end
                            keys[#keys + 1] = tostring(k) .. "=" .. t .. (s and ("(" .. s .. ")") or "")
                        end
                    end
                end)
                print("[BS BULLET] таблица #" .. i .. " (" .. cnt .. " полей): "
                    .. table.concat(keys, " | "))
            end
        end
    end
    if not replaced then return nil end

    G.BS.SilentShots = G.BS.SilentShots + 1
    return out, n
end

-- ============================================================
--  ЛОГ РЕМОУТОВ (клиент -> сервер)
-- ============================================================
-- Печатает по 2 первых вызова каждого ремоута вместе с аргументами.
-- Зачем: если у игры есть ОТДЕЛЬНЫЙ ремоут урона (как HitRemote в
-- EliteHub: HitRemote:FireServer(head, 1)), то «тихий выстрел» можно
-- сделать по-настоящему — урон без выстрела, и тогда его не увидит
-- вообще никто.
local logSeen = {}
local function logRemoteCall(self, method, ...)
    local name = "?"
    if typeof(self) == "Instance" then
        name = tostring(self.Name)
        local p = self.Parent
        if p then name = name .. "@" .. tostring(p.Name) end
    end
    local key = name .. "." .. tostring(method)
    local c = logSeen[key] or 0
    if c >= 2 then return end
    logSeen[key] = c + 1

    local n = select("#", ...)
    local show = n
    if show > 8 then show = 8 end
    local list = {}
    for i = 1, show do
        local a = select(i, ...)
        local t = typeof(a)
        local v
        if t == "Vector3" then
            v = string.format("%.1f, %.1f, %.1f", a.X, a.Y, a.Z)
        elseif t == "number" then
            v = string.format("%.2f", a)
        elseif t == "string" then
            v = a
        elseif t == "boolean" then
            v = tostring(a)
        elseif t == "Instance" then
            v = a.ClassName .. " " .. a.Name
        elseif t == "Player" then
            v = "Player " .. a.Name
        end
        list[i] = i .. ":" .. t .. (v and (" (" .. v .. ")") or "")
    end
    print("[BS REMOTE] " .. name .. ":" .. tostring(method)
        .. "  n=" .. n .. "  " .. table.concat(list, " | "))
end

-- Сам хук. Хот-путь максимально дешёвый: без ":"-вызовов и без pcall.
local function ncWrapper(self, ...)
    local method = getnamecallmethod()
    -- ЛОГ РЕМОУТОВ: только когда включён (проверка — одно обращение).
    if G.BS.RemoteLog and type(method) == "string"
       and (method == "FireServer" or method == "InvokeServer") then
        pcall(logRemoteCall, self, method, ...)
    end
    if type(method) == "string" then
        -- СТАМИНА: не даём игре списывать энергию
        if method == "FireServer" and self == NC.ue then
            if G.BS.InfStamina then return end
        -- ПРОСТРЕЛ / КЛИЕНТ АЙМ
        elseif method == "FireServer" and self == NC.fw then
            if G.BS.BulletSwap then
                local out, n = ncFireWeapon(...)
                if out then
                    return NC.orig(self, table.unpack(out, 1, n))
                end
            end
        -- ЗАЩИТА ОТ УРОНА
        elseif method == "TakeDamage" and self == NC.myHum then
            if G.BS.HealthLock then
                damageBlocked = damageBlocked + 1
                return 0
            end
        end
    end
    -- ВСЕГДА возвращаем оригинал. Если orig вдруг nil — НЕ вызываем
    -- его (иначе снова "attempt to call a nil value").
    if NC.orig then
        return NC.orig(self, ...)
    end
end

-- Установка хука. Пробуем два пути, ни один не оставляем «висеть»
-- без оригинала.
function installNamecall()
    if NC.installed then return true end
    if not NC.wrapper then NC.wrapper = ncWrapper end
    -- без getnamecallmethod не понять, какой ремоут вызывают -> не хукаем
    if type(getnamecallmethod) ~= "function" then
        print("[BS HOOK] нет getnamecallmethod — хук не ставим")
        return false
    end

    -- ШАГ 0: страховка. Пытаемся достать оригинал из СЫРОЙ
    -- метатаблицы. Он нужен, если hookmetamethod установит хук, но не
    -- вернёт оригинал: тогда нам всё равно будет чем форвардить.
    local origRaw
    pcall(function()
        if type(getrawmetatable) ~= "function" then return end
        local mt = getrawmetatable(game)
        if type(mt) ~= "table" then return end
        local v = rawget(mt, "__namecall")
        if type(v) ~= "function" then
            local okI, w = pcall(function() return mt.__namecall end)
            if okI then v = w end
        end
        if type(v) == "function" and v ~= NC.wrapper then origRaw = v end
    end)

    -- ПУТЬ 1: сырая метатаблица (надёжнее всего, не зависит от
    -- того, что возвращает hookmetamethod).
    if origRaw then
        local okA, resA = pcall(function()
            local mt = getrawmetatable(game)
            if type(mt) ~= "table" then return false end
            NC.orig = origRaw
            if type(setreadonly) == "function" then pcall(setreadonly, mt, false) end
            mt.__namecall = NC.wrapper
            if type(setreadonly) == "function" then pcall(setreadonly, mt, true) end
            -- проверяем, что подмена реально применилась
            return mt.__namecall == NC.wrapper
        end)
        if okA and resA then
            NC.installed = true
            print("[BS HOOK] __namecall перехвачен (сырая метатаблица)")
            return true
        end
        NC.orig = nil
    end

    -- ПУТЬ 2: hookmetamethod + FORWARD-ДЕКЛАРАЦИЯ (ключевое отличие
    -- от сломанных версий: `local old` ОТДЕЛЬНО от присвоения).
    if type(hookmetamethod) == "function" then
        local old
        local okB, errB = pcall(function()
            old = hookmetamethod(game, "__namecall", NC.wrapper)
        end)
        if okB then
            if old == NC.wrapper then
                -- Хук УЖЕ стоит нашим же wrapper'ом. Ещё раз звать
                -- hookmetamethod нельзя: он вернёт сам wrapper, и
                -- NC.orig стал бы равен себе -> бесконечная рекурсия.
                NC.orig = origRaw or NC.orig
                if NC.orig then
                    NC.installed = true
                    print("[BS HOOK] __namecall уже перехвачен")
                    return true
                end
                return false
            end
            -- страховка origRaw: даже если hookmetamethod вернул nil,
            -- хук можно безопасно форвардить имеющимся оригиналом.
            NC.orig = (type(old) == "function") and old or origRaw
            if NC.orig then
                NC.installed = true
                print("[BS HOOK] __namecall перехвачен (hookmetamethod)")
                return true
            end
            print("[BS HOOK] hookmetamethod не дал оригинал — хук не ставим")
            return false
        end
        print("[BS HOOK] hookmetamethod ошибка: " .. tostring(errB))
    end

    print("[BS HOOK] не удалось перехватить __namecall (нет getrawmetatable/hookmetamethod)")
    return false
end

-- Совместимость: раньше установщик звался installBulletHook.
local installBulletHook = installNamecall

-- «ТИХИЙ ВЫСТРЕЛ» и «РАСШИРИТЕЛЬ ХИТБОКСА» удалены (не работали:
-- выстрел всё равно рисуют другие клиенты по команде сервера, а
-- хитбокс сервер всё равно считает по своим частям).

-- ============================================================
--  СКАН ИГРОКОВ
-- ============================================================
local function scan()
    -- pcall вокруг GetPlayers: если движок Roblox временно отдаёт
    -- не-таблицу, scan() падал и ронял весь цикл (было в логе:
    -- "line 1089 - function scan").
    local ok, list = pcall(function() return Players:GetPlayers() end)
    if not ok or type(list) ~= "table" then return end
    for _, plr in ipairs(list) do
        if plr ~= LP then
            local ch = plr.Character
            if ch and ch.Parent then
                local e = by[plr]
                if not e then
                    add(plr)
                elseif e.char ~= ch then
                    -- respawn: peresozdajom ob'ekty ESP
                    remove(plr)
                    add(plr)
                end
                if not G.BS.RoleFreeze then
                    -- applyRole зовём ТОЛЬКО когда роль реально найдена:
                    -- иначе nil получал уверенность 6 и мешал настоящим
                    -- источникам роли перебить его.
                    local rr = roleFromAttr(plr) or netRoles[plr]
                    if rr then applyRole(by[plr], rr, CONF.attr) end
                end
            end
        end
    end
    -- чистим тех, кто ушёл или умер
    for plr, e in pairs(by) do
        if not plr.Parent or not plr.Character or not plr.Character.Parent
           or (e and e.hl and not e.hl.Parent) then
            remove(plr)
        end
    end
    rolesFromSounds()
    rolesFromEvents()
    local deduced = deduceOthers()
    if deduced and not G.BS.RoleFreeze then
        for _, e in pairs(by) do
            if e.role == nil then applyRole(e, deduced, CONF.deduce) end
        end
    end
end

scan()
task.spawn(function() while not STOPPED and task.wait(1) do pcall(scan) end end)
connAdded    = Players.PlayerAdded:Connect(function() task.delay(0.5, scan) end)
connRemoving = Players.PlayerRemoving:Connect(function(p) remove(p) end)

-- ============================================================
--  КАДР
-- ============================================================
local lastT = os.clock()
local conn = RunService.RenderStepped:Connect(function()
    local now = os.clock()
    local dt = math.min(0.1, math.max(0.001, now - lastT))
    lastT = now

    -- держим кэш целей хука свежим (внутри хука ":"-вызовы нельзя)
    if NC.installed then pcall(refreshHookTargets) end

    -- vyzhivanie
    if G.BS.InfStamina then pcall(patchEnergy) end
    if G.BS.HealthLock then
        pcall(installDamageHooks)
        pcall(pumpHealth)
    end

    -- цель для подмены патрона
    if G.BS.BulletSwap then
        pcall(computeBulletPreShot)
    elseif bulletPreShot then
        bulletPreShot = nil
    end

    local cam = workspace.CurrentCamera
    if not cam then
        hideOverlay()
        return
    end
    -- pcall: при отсутствии персонажа FindFirstChild на уничтоженном
    -- объекте бросает ошибку и роняет весь кадр (было в логе:
    -- "line 1158").
    local me, myRoot
    pcall(function()
        me = LP and LP.Character
        myRoot = me and me:FindFirstChild("HumanoidRootPart")
    end)

    -- ---------- ESP ----------
    for plr, e in pairs(by) do
        local ch = e.char
        -- ВАЖНО: обращение к уничтоженному Instance в Luau
        -- бросает ошибку и роняет ВЕСЬ кадр. Проверяем Parent.
        if ch and ch.Parent and e.hl and e.hl.Parent and e.gui and e.gui.Parent then
            local role = e.role
            local vis, color
            if role == "vampire" then
                vis, color = G.BS.VampESP == true, G.BS.VampColor
            elseif role == "hunter" then
                vis, color = G.BS.HunterESP == true, G.BS.HunterColor
            else
                vis, color = G.BS.PlayerESP == true, G.BS.PlayerColor
            end
            if G.BS.OnlyVamps and role ~= "vampire" then vis = false end

            local root = ch:FindFirstChild("HumanoidRootPart")
            if root and myRoot and G.BS.MaxDist > 0 then
                local d = (root.Position - myRoot.Position).Magnitude
                if d > G.BS.MaxDist then vis = false end
            end

            e.hl.FillColor        = color
            -- Красим И контур: именно он виден (заливка полупрозрачная).
            e.hl.OutlineColor     = color
            e.hl.FillTransparency = tonumber(G.BS.FillTransparency) or 0.7
            e.hl.Enabled   = vis
            e.gui.Enabled  = vis

            if vis then
                local parts = {}
                if G.BS.Names then parts[#parts + 1] = plr.DisplayName end
                if role == nil and G.BS.ShowUnknown then
                    parts[#parts + 1] = "[?]"
                end
                if G.BS.ShowDist and root and myRoot then
                    parts[#parts + 1] = math.floor(
                        (root.Position - myRoot.Position).Magnitude + 0.5) .. " st"
                end
                if G.BS.ShowHP then
                    local hum = ch:FindFirstChildOfClass("Humanoid")
                    if hum then parts[#parts + 1] = "HP " .. math.floor(hum.Health + 0.5) end
                end
                local txt = table.concat(parts, "  ")
                if e.lbl.Text ~= txt then e.lbl.Text = txt end
                e.lbl.TextColor3 = color
                e.lbl.Visible = true

                if G.BS.Boxes then
                    if not e.box then e.box = makeBox() end
                    if e.box and root then
                        e.box.color = color
                        drawBox(e.box, root, cam)
                    end
                elseif e.box then
                    hideBox(e.box)
                end
            else
                e.lbl.Visible = false
                hideBox(e.box)
            end
        else
            remove(plr)
        end
    end

    -- ---------- KLIENT AYM: METKA ЦельI ----------
    if G.BS.BulletSwap then
        if locked then
            if not pickTarget(cam) then locked = nil end
        else
            locked = pickTarget(cam)
        end
        drawTarget(locked)
        if NameLabel and locked then
            NameLabel.Text = locked.DisplayName
        end
    else
        locked = nil
        drawTarget(nil)
    end
end)

-- ============================================================
--  GUI
-- ============================================================
local Window = Rayfield:CreateWindow({
    Name = "Bloody Street",
    LoadingTitle = "BLOODY STREET",
    LoadingSubtitle = "ESP + Client Aim v10.1",
    ConfigurationSaving = { Enabled = true },
})

local TAB  = Window:CreateTab("ESP", 4483362458)
local AIMT = Window:CreateTab("AIM", 1101060692)

-- ЗАЩИТА СОЗДАНИЯ ЭЛЕМЕНТОВ: один упавший Create* не должен
-- ронять всю вкладку.
local UI_ERR = {}
local ELEM_NAMES = {
    "CreateSection", "CreateToggle", "CreateColorPicker", "CreateSlider",
    "CreateDropdown", "CreateButton", "CreateParagraph", "CreateInput",
    "CreateKeybind", "CreateLabel",
}

local function mkTab(tab, tag)
    local api = {}
    for _, n in ipairs(ELEM_NAMES) do
        api[n] = function(settings)
            -- ВАЖНО: возвращаем САМ элемент Rayfield, а НЕ флаг
            -- uspekha. Ran'she bylo `return ok` -> elementy poluchali
            -- boolean и :Set на них падал.
            local obj
            local ok, err = pcall(function()
                obj = tab[n](tab, settings)
            end)
            if not ok then
                UI_ERR[#UI_ERR + 1] = "[" .. tag .. "] " .. n .. ": " .. tostring(err)
                return nil
            end
            return obj
        end
    end
    return api
end

local TB = mkTab(TAB,  "ESP")
local AI = mkTab(AIMT, "AIM")

-- Блок «ГЛАВНЫЙ ЦВЕТ (RGB)» удалён по просьбе: rgbColor/hexStr/
-- hexToRGB/applyMainColor больше не вызываются.

-- ======================= ESP =======================
TB.CreateSection("Игроки")
TB.CreateToggle({ Name = "ESP игроков", Flag = "BS_PlayerESP",
    CurrentValue = G.BS.PlayerESP, Callback = function(v) G.BS.PlayerESP = v end })
TB.CreateColorPicker({ Name = "Цвет игроков", Flag = "BS_PlayerColor",
    Color = G.BS.PlayerColor, Callback = function(c) G.BS.PlayerColor = c end })

TB.CreateSection("Роли")
TB.CreateToggle({ Name = "ESP ВАМПИРОВ", Flag = "BS_VampESP",
    CurrentValue = G.BS.VampESP, Callback = function(v) G.BS.VampESP = v end })
TB.CreateColorPicker({ Name = "Цвет вампиров", Flag = "BS_VampColor",
    Color = G.BS.VampColor, Callback = function(c) G.BS.VampColor = c end })
TB.CreateToggle({ Name = "ESP ХАНТЕРОВ / ЛЮДЕЙ", Flag = "BS_HunterESP",
    CurrentValue = G.BS.HunterESP, Callback = function(v) G.BS.HunterESP = v end })
TB.CreateColorPicker({ Name = "Цвет хантеров", Flag = "BS_HunterColor",
    Color = G.BS.HunterColor, Callback = function(c) G.BS.HunterColor = c end })
TB.CreateToggle({ Name = "Только вампиры (остальных скрыть)", Flag = "BS_OnlyVamps",
    CurrentValue = G.BS.OnlyVamps, Callback = function(v) G.BS.OnlyVamps = v end })
TB.CreateToggle({ Name = "Помечать неизвестных [?]", Flag = "BS_ShowUnknown",
    CurrentValue = G.BS.ShowUnknown, Callback = function(v) G.BS.ShowUnknown = v end })

TB.CreateSection("Вид")
TB.CreateToggle({ Name = "Ники", Flag = "BS_Names",
    CurrentValue = G.BS.Names, Callback = function(v) G.BS.Names = v end })
TB.CreateToggle({ Name = "Дистанция", Flag = "BS_ShowDist",
    CurrentValue = G.BS.ShowDist, Callback = function(v) G.BS.ShowDist = v end })
TB.CreateToggle({ Name = "HP", Flag = "BS_ShowHP",
    CurrentValue = G.BS.ShowHP, Callback = function(v) G.BS.ShowHP = v end })
TB.CreateToggle({ Name = "3D коробки", Flag = "BS_Boxes",
    CurrentValue = G.BS.Boxes,
    Callback = function(v)
        G.BS.Boxes = v
        if v and not DRAW_OK then
            G.BS.Boxes = false
            notify("в этом исполнителе нет Drawing — коробки выключены", 4)
        end
    end })
TB.CreateSlider({ Name = "Толщина коробки", Flag = "BS_BoxThick",
    Range = {1, 6}, Increment = 1, CurrentValue = G.BS.BoxThick,
    Callback = function(v) G.BS.BoxThick = v end })
TB.CreateSlider({ Name = "Макс. дистанция ESP (0 = вся)", Flag = "BS_MaxDist",
    Range = {0, 2000}, Increment = 25, CurrentValue = G.BS.MaxDist,
    Suffix = " studs", Callback = function(v) G.BS.MaxDist = v end })

TB.CreateSection("Сканер")
TB.CreateButton({ Name = "СКАНИРОВАТЬ ИГРУ (в консоль)", Callback = function()
    pcall(scanAll)
    notify("Скан отработал, смотри консоль", 4)
end })
TB.CreateButton({ Name = "ГЛУБОКОЕ СКАНИРОВАНИЕ (найти модули оружия)", Callback = function()
    pcall(deepScan)
    notify("Глубокий скан отработал, смотри консоль", 4)
end })
TB.CreateToggle({ Name = "Сканировать при запуске", Flag = "BS_ScanOnStart",
    CurrentValue = G.BS.ScanOnStart,
    Callback = function(v)
        G.BS.ScanOnStart = v
        if v then pcall(scanAll) end
    end })

-- ======================= AIM =======================
AI.CreateSection("Клиент айм")
AI.CreateToggle({
    Name = "Клиент айм (patron v tsel)", Flag = "BS_BulletSwap",
    CurrentValue = G.BS.BulletSwap,
    Callback = function(v)
        G.BS.BulletSwap = v
        locked = nil
        bulletPreShot = nil
        if v then
            pcall(installBulletHook)
            pcall(computeBulletPreShot)
            notify("Патроны идут в цель", 3)
        else
            notify("Клиент айм выключен", 2)
        end
    end,
})

-- Секция «Цель» («Кого целить», «Приоритет», «Радиус захвата») и
-- пикеры «Цвет: захват цели» / «Цвет метки» удалены по просьбе.
-- Логика выбора цели осталась и работает на дефолтах:
--   AIM_TARGETS  = противники по роли, AIM_PRIORITY = ближе,
--   радиус 160 px, прострел включён.

AI.CreateSection("Диагностика")
AI.CreateToggle({
    Name = "Диагностика патрона (в консоль)", Flag = "BS_BulletDebug",
    CurrentValue = G.BS.BulletDebug,
    Callback = function(v)
        G.BS.BulletDebug = v
        if v then pcall(installBulletHook) end
    end,
})
AI.CreateToggle({
    Name = "Лог ремоутов (что уходит на сервер)", Flag = "BS_RemoteLog",
    CurrentValue = G.BS.RemoteLog,
    Callback = function(v)
        G.BS.RemoteLog = v
        logSeen = {}
        if v then
            pcall(installBulletHook)
            notify("Лог ремоутов включён: постреляй, смотри [BS REMOTE]", 5)
        end
    end,
})

-- ============================================================
--  СТОП
-- ============================================================
G.BS_Stop = function()
    STOPPED = true
    pcall(function() conn:Disconnect() end)
    if connAdded    then pcall(function() connAdded:Disconnect() end) end
    if connRemoving then pcall(function() connRemoving:Disconnect() end) end
    if connChar     then pcall(function() connChar:Disconnect() end) end
    connAdded, connRemoving, connChar = nil, nil, nil
    for i = #netConns, 1, -1 do
        pcall(function() netConns[i]:Disconnect() end)
        netConns[i] = nil
    end
    for plr in pairs(by) do remove(plr) end
    by = {}
    locked = nil
    bulletPreShot = nil
    if Screen then pcall(function() Screen:Destroy() end) end
    if Overlay then pcall(function() Overlay:Destroy() end) end
    Screen = nil
    Overlay = nil
    G.BS.MyRole = "?"
    -- BulletSwap НЕ трогаем: getgenv() живёт между запусками, и если
    -- выставить false, то при повторном запуске клиент айм не включится.
    -- Снимаем __namecall, иначе он останется висеть и при повторном
    -- запуске скрипта хуки состыкуются.
    if NC.installed then
        local orig = NC.orig
        pcall(function()
            if orig and type(getrawmetatable) == "function" then
                local mt = getrawmetatable(game)
                if type(mt) == "table" then
                    if type(setreadonly) == "function" then
                        pcall(setreadonly, mt, false)
                    end
                    mt.__namecall = orig
                    if type(setreadonly) == "function" then
                        pcall(setreadonly, mt, true)
                    end
                end
            end
            if orig and type(hookmetamethod) == "function" then
                hookmetamethod(game, "__namecall", orig)
            end
        end)
        NC.installed = false
        NC.orig = nil
    end
    G.BS_Stop = nil
    print("[BS HUB] v10.1 остановлен")
end

-- Пересканирование при старте: устанавливаем хуки и сталкин.
task.spawn(function()
    pcall(patchEnergy)
    pcall(installDamageHooks)
    pcall(installBulletHook)
    pcall(refreshHookTargets)
    if LP then
        connChar = LP.CharacterAdded:Connect(function()
            task.wait(0.5)
            if STOPPED then return end
            pcall(installDamageHooks)
            pcall(scan)
        end)
    end
    if G.BS.ScanOnStart then
        task.wait(2)
        pcall(scanAll)
    end
end)

print("[BS HUB] v10.1 запущен | хуков=" .. #netConns
    .. " | клиент айм: " .. tostring(G.BS.BulletSwap)
    .. " | прострел: " .. tostring(G.BS.Penetrate)
    .. " | ошибок GUI=" .. #UI_ERR)
