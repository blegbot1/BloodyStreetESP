-- ============================================================
--  BLOODY STREET - ESP + КЛИЕНТ АИМ  v11.2
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
-- АИМ ПО ЧАСТЯМ ТЕЛА: голова/корпус -> ноги -> руки.
G.BS.AimPart         = pickOpt(G.BS.AimPart, AIM_PART, AIM_PART[1])
G.BS.AimChain        = G.BS.AimChain ~= false
-- «СВОБОДНЫЕ» части тела: целимся в ту часть, до которой есть
-- прямая видимость. Голова/корпус перекрыты -> ноги -> руки.
G.BS.AimFreePart     = G.BS.AimFreePart ~= false
-- ДАЛЬНОСТЬ ПОДМЕНЫ. В конфиге игры Config.Combat.BULLET_RANGE = 300
-- и WEAPON_RANGE = 320: дальше 300 студов пуля физически не летит.
-- Раньше стояло 0 (без ограничения), и скрипт спокойно выбирал цель
-- в 404 студах - такие выстрелы в принципе не могли попасть.
G.BS.AimMaxDist      = tonumber(G.BS.AimMaxDist) or 290
if G.BS.AimMaxDist == 0 then G.BS.AimMaxDist = 290 end
if G.BS.AimMaxDist == 300 then G.BS.AimMaxDist = 290 end
if G.BS.AimMaxDist > 300 then G.BS.AimMaxDist = 300 end
G.BS.RGBTarget       = pickOpt(G.BS.RGBTarget, RGB_TARGETS, RGB_TARGETS[1])

-- ---------- RGB ----------
G.BS.R = math.clamp(math.floor(tonumber(G.BS.R) or 255), 0, 255)
G.BS.G = math.clamp(math.floor(tonumber(G.BS.G) or 55), 0, 255)
G.BS.B = math.clamp(math.floor(tonumber(G.BS.B) or 55), 0, 255)

-- ---------- ВЫЖИВАНИЕ ----------
G.BS.InfStamina  = G.BS.InfStamina  or false
-- БЕСКОНЕЧНЫЕ ПАТРОНЫ: держим Charges = MaxCharges.
G.BS.InfAmmo     = G.BS.InfAmmo ~= false
-- ПОДСВЕТКА ТЕКУЩЕЙ ЦЕЛИ (кто выбран аимом).
G.BS.TargetMark  = G.BS.TargetMark ~= false
G.BS.TargetMarkColor = safeColor(G.BS.TargetMarkColor, Color3.new(1, 1, 1))
-- ТОЧКА ПРИЦЕЛИВАНИЯ: метка там, куда реально уходит патрон.
G.BS.AimDot      = G.BS.AimDot ~= false
G.BS.AimDotColor = safeColor(G.BS.AimDotColor, Color3.new(1, 0.25, 0.25))
-- ЛОГ ПОПАДАНИЙ: печатать каждое событие урона (DamagePopup/CombatFeed).
G.BS.DmgLog      = G.BS.DmgLog == true
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
-- АИМЛОК: камера доворачивается на цель. Нужен потому, что сервер
-- проверяет направление взгляда: направить патрон в цель, глядя в
-- сторону, нельзя — выстрел отклоняется.
-- Скорость доворота: 0 = мгновенно, 20 = очень быстро, 40 = мягко.
G.BS.AimLock       = G.BS.AimLock ~= false
G.BS.AimLockSpeed  = tonumber(G.BS.AimLockSpeed) or 14
-- Аимlock включается только когда это нужно, чтобы не дёргать камеру:
--   NeedAim  — цель под прицелом (иначе догоняет всех подряд);
--   FireOnly — только пока зажат огонь;
-- плюс в коде проверяется, что в руках именно ОРУЖИЕ.
G.BS.AimLockNeedAim  = G.BS.AimLockNeedAim ~= false
G.BS.AimLockFireOnly = G.BS.AimLockFireOnly == true
-- ТРИГГЕР: работаем только когда враг ПРЯМО ПО КУРСУ (в конусе
-- прицела). Нет врага впереди - не целимся и не доворачиваем камеру.
G.BS.Trigger         = G.BS.Trigger ~= false
-- Радиус триггера в ГРАДУСАХ (игра сама стреляет по конусу
-- Config.UI.AUTO_ATTACK.CONE_DEG = 12). Поставь 0, чтобы вернуть
-- запасной режим "узкий конус на экране" (TriggerCone).
G.BS.TriggerDeg     = tonumber(G.BS.TriggerDeg) or 12
G.BS.TriggerCone     = tonumber(G.BS.TriggerCone) or 0.10
-- АИМ ДЛЯ ЛОМЫ (MeleeSwing) / формы вампира (TrueFormMelee) /
-- тейзера (StunFire). Удар принимает направление и проверяется так
-- же, как выстрел, поэтому направление подменяется на цель.
G.BS.MeleeAim        = G.BS.MeleeAim ~= false
-- Аимлок НЕ доводит камеру сквозь стены.
G.BS.AimLockNoWall   = G.BS.AimLockNoWall ~= false
-- ПРОСТРЕЛ СТЕН. Сервер разрешает увести точку вылета на
-- Config.Combat.SHOT_ORIGIN_SLACK = 14 студов. Ставим её за стеной.
G.BS.WallPenetrate   = G.BS.WallPenetrate ~= false
G.BS.OriginSlack     = tonumber(G.BS.OriginSlack) or 13
-- РАСШИРИТЕЛЬ ХИТБОКСА удалён: работает только при клиентском
-- подсчёте урона, а игра считает урон на сервере.
-- АВТОПРОВЕРКА ОРУЖИЯ при запуске (дальность/разброс/урон в консоль).
G.BS.WeaponProbeOnStart = G.BS.WeaponProbeOnStart ~= false
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
if G.BS.CfgV ~= 20 then
    G.BS.CfgV      = 20
    G.BS.TriggerDeg = 12
    G.BS.AimChain  = true
    G.BS.AimFreePart = true
    G.BS.InfAmmo   = true
    G.BS.TargetMark = true
    G.BS.AimMaxDist   = 290    -- Config.Combat.BULLET_RANGE = 300
    G.BS.AimLead   = 0.08
    G.BS.AimLock   = true
    G.BS.AimLockSpeed = 25     -- SHOT_ANGLE_SLACK_DEG = 3
    G.BS.AimLockNeedAim = true
    G.BS.AimLockFireOnly = false
    G.BS.AimLockNoWall = true
    G.BS.Trigger   = true
    G.BS.TriggerDeg = 12
    G.BS.TriggerCone = 0.10
    G.BS.MeleeAim  = true
    G.BS.WallPenetrate = true
    G.BS.OriginSlack = 13     -- SHOT_ORIGIN_SLACK = 14
    G.BS.SpoofBack = 0
    G.BS.SilentShot = false
    G.BS.Hitbox    = false   -- расширитель удалён
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
             melee = nil, tfmelee = nil, stun = nil,
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
local dmgFmt = {}

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
                -- СЧЁТ ПОПАДАНИЙ. DamagePopup / CombatFeed сервер
                    -- шлёт, когда урон РЕАЛЬНО прошёл. Это единственный
                    -- способ понять, попадает аим или нет: подмена
                    -- патрона может выглядеть правильно, а урона нет.
                    if r.Name == "DamagePopup" or r.Name == "CombatFeed" then
                        local cnt = (G.BS.DmgEvents or 0) + 1
                        G.BS.DmgEvents = cnt
                        if not dmgFmt[r.Name] then
                            dmgFmt[r.Name] = true
                            local list = {}
                            for k = 1, args.n do
                                local a = args[k]
                                local t = typeof(a)
                                local s
                                if t == "number" then
                                    s = string.format("%.2f", a)
                                elseif t == "string" then
                                    s = a
                                elseif t == "boolean" then
                                    s = tostring(a)
                                elseif t == "Instance" then
                                    s = a.ClassName .. " " .. a.Name
                                elseif t == "Player" then
                                    s = "Player " .. a.Name
                                elseif t == "table" then
                                    s = "{"
                                    local n2 = 0
                                    for k2, v2 in pairs(a) do
                                        n2 = n2 + 1
                                        if n2 <= 5 then
                                            local tv = typeof(v2)
                                            local sv
                                            if tv == "number" then sv = string.format("%.2f", v2)
                                            elseif tv == "string" or tv == "boolean" then sv = tostring(v2)
                                            else sv = tv end
                                            s = s .. tostring(k2) .. "=" .. sv .. ","
                                        end
                                    end
                                    s = s .. "}"
                                end
                                list[#list + 1] = k .. ":" .. t .. (s and ("(" .. s .. ")") or "")
                            end
                            print("[BS DMG] формат " .. r.Name .. ": " .. table.concat(list, " | "))
                        elseif G.BS.DmgLog then
                            print("[BS DMG] " .. r.Name .. " #" .. cnt
                                .. " | выстрелов подменено: " .. tostring(G.BS.SilentShots or 0))
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
--  ТОЧКА ПРИЦЕЛИВАНИЯ
-- ============================================================
-- Маленькая метка там, куда реально уходит патрон
-- (bulletPreShot.pos). Без неё не видно, куда скрипт наводится на
-- самом деле — особенно важно при подборе опережения: видно, что
-- точка уходит выше/ниже головы бегущего.
local aimDot = nil
local function updateAimDot()
    if not G.BS.AimDot then
        if aimDot then aimDot.Visible = false end
        return
    end
    local pre = bulletPreShot
    local cam = workspace.CurrentCamera
    if not (pre and cam) then
        if aimDot then aimDot.Visible = false end
        return
    end
    if not aimDot then
        local ok, d = pcall(function() return Drawing.new("Circle") end)
        if not ok or not d then return end
        d.Thickness    = 2
        d.NumSides     = 16
        d.Filled       = false
        d.Transparency = 1
        aimDot = d
    end
    local vp = cam:WorldToViewportPoint(pre.pos)
    if vp.Z <= 0 then
        aimDot.Visible = false
        return
    end
    aimDot.Position = Vector2.new(vp.X, vp.Y)
    aimDot.Radius   = 5
    aimDot.Color    = safeColor(G.BS.AimDotColor, Color3.new(1, 0.25, 0.25))
    aimDot.Visible  = true
end

-- ============================================================
--  БЕСКОНЕЧНЫЕ ПАТРОНЫ
-- ============================================================
-- У оружия атрибуты Charges / MaxCharges (у дробовика 8, у пистолета
-- 12/18, у снайпера 4 - Config.Loadout.TOOL_GUN_CHARGES). Держим
-- запас полным: клиентский счётчик и проверка «есть ли чем стрелять»
-- берутся отсюда, и перезарядка не прерывает стрельбу.
local function refillCharges()
    if not G.BS.InfAmmo then return end
    local ch = LP and LP.Character
    if not ch then return end
    local tool = ch:FindFirstChildOfClass("Tool")
    if not tool then return end
    pcall(function()
        local mx = tool:GetAttribute("MaxCharges")
        if type(mx) == "number" and mx > 0 then
            tool:SetAttribute("Charges", mx)
        end
        local cv = tool:FindFirstChild("Charges")
        if cv and cv:IsA("NumberValue") then
            local mx2 = mx or cv.Value
            if type(mx2) == "number" and mx2 > 0 then cv.Value = mx2 end
        end
    end)
end

-- ============================================================
--  ПОДСВЕТКА ТЕКУЩЕЙ ЦЕЛИ
-- ============================================================
-- Показывает, в кого именно сейчас наводится аим. Без неё легко
-- не понять, что скрипт выбрал соседа, а не того, кто по курсу.
local TargetHL = nil
local function updateTargetMark()
    if not G.BS.TargetMark then
        if TargetHL then TargetHL.Enabled = false end
        return
    end
    local pre = bulletPreShot
    local ch = pre and pre.part and pre.part.Parent
    if not ch then
        if TargetHL then TargetHL.Enabled = false end
        return
    end
    if not TargetHL then
        local ok, hl = pcall(function() return Instance.new("Highlight") end)
        if not ok or not hl then return end
        hl.Name                = "BS_TargetMark"
        hl.FillTransparency     = 1
        hl.OutlineTransparency  = 0.1
        hl.DepthMode            = Enum.HighlightDepthMode.AlwaysOnTop
        hl.Parent               = screen()
        TargetHL                = hl
    end
    TargetHL.Adornee      = ch
    TargetHL.OutlineColor = safeColor(G.BS.TargetMarkColor, Color3.new(1, 1, 1))
    TargetHL.Enabled      = true
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

-- ПРИОРИТЕТ ЧАСТЕЙ ТЕЛА ПРИ НАВЕДЕНИИ.
-- 1) ГОЛОВА / КОРПУС — приоритет (если выбранная в G.BS.AimPart есть и
--    она «свободна», т.е. видима).
-- 2) НОГИ — если корпуса нет (например персонаж без торса).
-- 3) РУКИ — если нет ни корпуса, ни ног.
-- Часть считается «свободной», если она есть, это BasePart, у неё
-- есть родитель и она не прозрачная (скрытые прокси-части игнорим).
local AIM_CHAIN = {
    -- корпус и голова (приоритет)
    "Head", "UpperTorso", "Torso", "LowerTorso", "HumanoidRootPart",
    -- ноги
    "LeftUpperLeg", "RightUpperLeg", "LeftLowerLeg", "RightLowerLeg",
    "LeftLeg", "RightLeg", "LeftUpLeg", "RightUpLeg",
    -- руки
    "LeftUpperArm", "RightUpperArm", "LeftLowerArm", "RightLowerArm",
    "Left Arm", "Right Arm", "LeftHand", "RightHand",
}

local function partUsable(p)
    if not p or not p:IsA("BasePart") then return false end
    if not p.Parent then return false end
    if p.Transparency >= 0.95 then return false end
    return true
end

-- «СВОБОДНАЯ» ЧАСТЬ ТЕЛА = та, до которой есть прямая видимость.
-- Если голова или корпус чем-то перекрыты (стена, ящик, укрытие),
-- берём первую свободную: ноги, потом руки. Проверяем не больше
-- AIM_VIS_MAX кандидатов и только для уже выбранной цели.
local AIM_VIS_MAX = 9
local VIS_CHECK = RaycastParams.new()
VIS_CHECK.FilterType = Enum.RaycastFilterType.Exclude

local function visiblePart(ch, part, from)
    if not partUsable(part) then return false end
    local ok, res = pcall(function()
        VIS_CHECK.FilterDescendantsInstances = { LP.Character, ch }
        local d = part.Position - from
        if d.Magnitude < 0.5 then return true end
        local hit = workspace:Raycast(from, d, VIS_CHECK)
        if not hit then return true end
        -- попали в самого персонажа (другая его часть) = тоже видно
        return hit.Instance:IsDescendantOf(ch)
    end)
    return ok and res == true
end

-- Перебираем части по приоритету и берём первую свободную.
local function refineFreePart(ch, from, cur)
    if not (ch and from) then return cur end
    if cur and visiblePart(ch, cur, from) then return cur end
    local n = #AIM_CHAIN
    if n > AIM_VIS_MAX then n = AIM_VIS_MAX end
    for i = 1, n do
        local p = ch:FindFirstChild(AIM_CHAIN[i])
        if visiblePart(ch, p, from) then return p end
    end
    return cur
end

local function pickPartOf(ch)
    if not G.BS.AimChain then
        -- старый режим: только выбранная часть, иначе список AIM_PART
        local p = ch:FindFirstChild(G.BS.AimPart)
        if partUsable(p) then return p end
        for _, nm in ipairs(AIM_PART) do
            local q = ch:FindFirstChild(nm)
            if partUsable(q) then return q end
        end
        return nil
    end
    -- приоритет: сначала выбранная часть (по умолчанию Head)
    local first = ch:FindFirstChild(G.BS.AimPart)
    if partUsable(first) then return first end
    -- потом корпус/голова -> ноги -> руки
    for i = 1, #AIM_CHAIN do
        local q = ch:FindFirstChild(AIM_CHAIN[i])
        if partUsable(q) then return q end
    end
    return nil
end

-- ВЫЧИСЛЯЕТСЯ КАЖДЫЙ КАДР, чтобы в хуке ничего не искать.
-- WALLRAY — для проверки стены между нами и целью (прострел).
local WALLRAY = RaycastParams.new()
WALLRAY.FilterType = Enum.RaycastFilterType.Exclude

local function computeBulletPreShot()
    if not G.BS.BulletSwap then bulletPreShot = nil return end
    -- ОБЕЗОРУЖЕН (модуль Disarm, атрибут DisarmedUntil): стрелять
    -- всё равно нечем, цель не выбираем.
    pcall(function()
        local du = LP:GetAttribute("DisarmedUntil")
        if type(du) == "number" and du > os.time() then
            bulletPreShot = nil
            G.BS.Disarmed = true
        else
            G.BS.Disarmed = false
        end
    end)
    if bulletPreShot == nil and G.BS.Disarmed then return end
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
    -- ТРИГГЕР В ГРАДУСАХ. Игра сама стреляет по конусу:
    -- Config.UI.AUTO_ATTACK.CONE_DEG = 12. Считаем ровно тот же угол
    -- между взглядом и целью - тогда аим и автоатака решают одно и то же
    -- и скрипт не доворачивает камеру туда, куда игра не стреляет.
    local look = cam.CFrame.LookVector
    local camPos = cam.CFrame.Position
    local trigDeg = tonumber(G.BS.TriggerDeg) or 12
    if trigDeg <= 0 then trigDeg = 0.1 end
    local trigCos = math.cos(math.rad(trigDeg))
    -- запасной вариант: узкий конус на экране (если градусы выключены)
    local TCONE = math.max(80, math.floor(vp.Y * (tonumber(G.BS.TriggerCone) or 0.10)))
    local TCONE2 = TCONE * TCONE

    local bestAim,  bestAimS    -- под прицелом (широкий конус)
    local bestTrig, bestTrigD   -- прямо по курсу (угол взгляда)
    local bestNear, bestNearD   -- иначе — ближайший по расстоянию
    local bestCh = nil                -- персонаж выбранной цели
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
                            bestCh = ch
                        end
                        local sp = cam:WorldToViewportPoint(q.Position)
                        if sp.Z > 0 then
                            local dx, dy = sp.X - ccx, sp.Y - ccy
                            local s2 = dx * dx + dy * dy
                            if s2 <= CONE2 then
                                if not bestAimS or s2 < bestAimS then
                                    bestAim, bestAimS = q, s2
                                    bestCh = ch
                                end
                            end
                            if trigDeg > 0 then
                                -- ТРИГГЕР В ГРАДУСАХ: угол между
                                -- взглядом и целью <= TriggerDeg
                                local toT = q.Position - camPos
                                if toT.Magnitude > 0.5 then
                                    if toT.Unit:Dot(look) >= trigCos then
                                        if not bestTrigD or d < bestTrigD then
                                            bestTrig, bestTrigD = q, d
                                            bestCh = ch
                                        end
                                    end
                                end
                            elseif s2 <= TCONE2 then
                                -- запасной вариант: узкий конус на экране
                                if not bestTrigD or d < bestTrigD then
                                    bestTrig, bestTrigD = q, d
                                    bestCh = ch
                                end
                            end
                        end
                    end
                end
            end
        end
    end
    local best = bestAim or bestNear
    local bestChar = bestCh

    -- ТРИГГЕР: если вампир/враг прямо по курсу (в конусе прицела) -
    -- работаем; если впереди никого нет - НЕ целимся и НЕ ведём
    -- камеру. Никто сзади/сбоку не трогаем.
    if G.BS.Trigger and not bestTrig then
        bulletPreShot = nil
        return
    end

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

    -- «СВОБОДНАЯ» ЧАСТЬ ТЕЛА: если голова или корпус перекрыты (стена,
    -- ящик, укрытие), берём первую часть с прямой видимостью - ноги,
    -- потом руки. Проверка только для уже выбранной цели.
    if G.BS.AimFreePart and bestChar and srcPos then
        local refined = refineFreePart(bestChar, srcPos, best)
        if refined then best = refined end
    end

    local aimPos = best.Position
    do
        local lead = tonumber(G.BS.AimLead) or 0
        if lead > 0 then
            local vel = best.AssemblyLinearVelocity
            if vel and vel.Magnitude > 1 then
                -- СМЕЩЕНИЕ ОГРАНИЧЕНО. Прыгающий игрок летит вверх со
                -- скоростью ~25 студов/с, и опережение 0.08 с уводило
                -- точку на 2 студа ВЫШЕ головы - аимлок от этого
                -- сбрасывался, а выстрел шёл мимо.
                local off = vel * lead
                local m = off.Magnitude
                local maxOff = 2.5
                if m > maxOff then off = off * (maxOff / m) end
                aimPos = aimPos + off
            end
        end
    end

    local dir = aimPos - srcPos
    local dist = dir.Magnitude
    if dist < 0.001 then
        bulletPreShot = nil
        return
    end
    -- СТЕНА МЕЖДУ НАМИ И ЦЕЛЬЮ.
    -- В конфиге игры: Config.Combat.SHOT_ORIGIN_SLACK = 14 — сервер
    -- РАЗРЕШАЕТ увести точку вылета на 14 студов в сторону. Значит
    -- стену можно обойти честно: ставим точку вылета сразу ЗА стеной
    -- (но не дальше 14 студов, иначе сервер отклонит выстрел).
    local wallPast = nil
    if G.BS.WallPenetrate then
        local len = (aimPos - srcPos).Magnitude
        if len > 1 then
            local okW, res = pcall(function()
                WALLRAY.FilterDescendantsInstances = { LP.Character, best.Parent }
                local hit = workspace:Raycast(srcPos, aimPos - srcPos, WALLRAY)
                if not hit then return nil end
                if hit.Distance >= len - 1.2 then return nil end   -- это цель
                local slack = tonumber(G.BS.OriginSlack) or 13
                if slack < 1 then slack = 1 end
                if hit.Distance > slack then return nil end
                local d = (aimPos - srcPos).Unit
                return hit.Position + d * 2
            end)
            if okW and res then wallPast = res end
        end
    end

    bulletPreShot = {
        part = best,     -- цель (Instance)
        pos  = aimPos,   -- куда целимся
        src  = srcPos,   -- откуда стреляем
        dist = dist,     -- расстояние до цели
        dir  = dir.Unit, -- направление
        onScreen = bestAim ~= nil,  -- цель именно ПОД ПРИЦЕЛОМ
        wallPast = wallPast,        -- точка вылета ЗА стеной
    }
end

-- ============================================================
--  АИМЛОК: камера доворачивается на цель
-- ============================================================
-- ЗАЧЕМ. Сервер проверяет, что выстрел уходит ТУДА, КУДА СМОТРИТ
-- игрок: если подменить направление патрона на цель, а камера
-- смотрит в сторону — выстрел отклоняется («выстрел защищается»).
-- Поэтому доводим камеру на ту же цель: тогда и взгляд, и патрон
-- совпадают, и сервер не придрается.
-- Позиция камеры не меняется (вид от третьего лица сохраняется),
-- меняется только направление взгляда.
--
-- ЧТОБЫ НЕ БЕСИЛО. Доворот включается только когда реально нужно:
--   1) в руках ОРУЖИЕ (Attachment Muzzle или атрибут Variant) —
--      взял дубинку/анализатор, аимлок выключен, камера твоя;
--   2) цель именно ПОД ПРИЦЕЛОМ, а не просто ближайшая сзади;
--   3) по желанию — только пока зажат огонь;
--   4) персонаж жив.
local UIS = game:GetService("UserInputService")
local AIMLOCKRAY = RaycastParams.new()
AIMLOCKRAY.FilterType = Enum.RaycastFilterType.Exclude
local gunInHand, gunCheckAt = false, 0

local function refreshGunFlag(now)
    if now - gunCheckAt < 0.3 then return gunInHand end
    gunCheckAt = now
    local res = false
    pcall(function()
        local ch = LP and LP.Character
        if not ch then res = false return end
        local hum = ch:FindFirstChildOfClass("Humanoid")
        if hum and hum.Health <= 0 then res = false return end
        local tool = ch:FindFirstChildOfClass("Tool")
        if not tool then res = false return end
        if tool:FindFirstChild("Muzzle") then res = true return end
        if tool:GetAttribute("Variant") then res = true return end
        local n = string.lower(tool.Name)
        if string.find(n, "gun", 1, true) then res = true return end
    end)
    gunInHand = res
    return res
end

local function aimLockTick(dt, now)
    local pre = bulletPreShot
    if not (G.BS.AimLock and pre and pre.part and pre.part.Parent) then return end
    if not refreshGunFlag(now) then return end
    if G.BS.AimLockNeedAim and not pre.onScreen then return end
    if G.BS.AimLockFireOnly then
        local okP, down = pcall(function()
            return UIS:IsMouseButtonPressed(Enum.UserInputType.MouseButton1)
        end)
        if not (okP and down) then return end
    end

    local cam = workspace.CurrentCamera
    if not cam then return end
    local cf = cam.CFrame
    local pos = cf.Position

    -- Камера смотрит в ТОЧКУ ПОПАДАНИЯ (pre.pos), а не в Head:
    -- там уже учтено опережение. Иначе взгляд и патрон смотрят в
    -- разные точки, а сервер режет выстрел при расхождении больше
    -- SHOT_ANGLE_SLACK_DEG = 3 градусов.
    local look = pre.pos
    local toT = look - pos
    if toT.Magnitude < 0.5 then return end

    -- НЕ ДОВОДИМ КАМЕРУ СКВОЗЬ СТЕНЫ (по просьбе): если между нами и
    -- целью стена - взгляд остаётся твоим.
    if G.BS.AimLockNoWall then
        local blocked = false
        pcall(function()
            AIMLOCKRAY.FilterDescendantsInstances = { LP.Character, pre.part.Parent }
            local hit = workspace:Raycast(pos, toT, AIMLOCKRAY)
            if hit and hit.Distance < toT.Magnitude - 1.2 then blocked = true end
        end)
        if blocked then return end
    end

    local target = CFrame.lookAt(pos, look, cf.UpVector)
    local sp = tonumber(G.BS.AimLockSpeed) or 25
    if sp <= 0 then
        cam.CFrame = target
        return
    end

    -- ПРЫГАЮЩАЯ ЦЕЛЬ. Плавный доворот отстаёт от быстрого движения
    -- (особенно вверх) и угол взгляда уходит за 3 градуса. Если
    -- расхождение большое - доворачиваем мгновенно.
    local wantDir = toT.Unit
    local dot = cf.LookVector:Dot(wantDir)
    if dot < 1 then
        if dot < -1 then dot = -1 end
        local ang = math.acos(dot) * (180 / math.pi)
        if ang > 12 then
            cam.CFrame = target
            return
        end
    end
    local t = sp * (dt or 0.016)
    if t > 1 then t = 1 end
    cam.CFrame = cf:Lerp(target, t)
end

-- ============================================================
--  МЕЛЬЕ: подмена направления удара
-- ============================================================
-- Лома (MeleeSwing), форма вампира (TrueFormMelee) и тейзер
-- (StunFire) принимают по одному Vector3 - направление удара, по
-- логу ремоутов:
--   MeleeSwing@Remotes:FireServer n=1  1:Vector3 (-0.1, -0.1, -1.0)
-- Удар проверяется так же, как выстрел (конус + дальность), поэтому
-- направление просто заменяем на наше - в ту же цель, куда наводит
-- аимлок. Дальность удара Config.Combat.MELEE_RANGE = 17.
local MELEE_RANGE = 18

local function ncMeleeDir(...)
    local pre = bulletPreShot
    if not (pre and pre.part and pre.part.Parent and pre.dir) then return nil end
    if pre.dist > MELEE_RANGE then return nil end
    local n = select("#", ...)
    if n < 1 then return nil end

    local args = table.pack(...)
    local out = {}
    for i = 1, n do out[i] = args[i] end

    -- ищем Vector3-направление: длинный и НЕ рядом с нами
    local myPos = pre.src
    local pickIdx, pickLen = nil, nil
    for i = 1, n do
        if typeof(out[i]) == "Vector3" then
            local v = out[i]
            local len = v.Magnitude
            local near = myPos and (v - myPos).Magnitude or 999
            if near > 8 then
                if not pickLen or len > pickLen then
                    pickIdx, pickLen = i, len
                end
            end
        end
    end
    if not pickIdx then return nil end

    -- длину сохраняем: игра шлёт ЕДИНИЧНЫЙ вектор (0.9-1.0)
    local base = pickLen or 1
    if base < 0.001 then base = 1 end
    out[pickIdx] = pre.dir * base
    G.BS.SilentShots = (G.BS.SilentShots or 0) + 1
    return out, n
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
        -- МЕЛЬЕ. По логу ремоутов: MeleeSwing/TrueFormMelee/StunFire
        -- принимают ОДИН Vector3 - направление удара. Значит удар
        -- проверяется так же, как выстрел, и подменяется так же.
        NC.melee  = Remotes:FindFirstChild("MeleeSwing")
        NC.tfmelee = Remotes:FindFirstChild("TrueFormMelee")
        NC.stun   = Remotes:FindFirstChild("StunFire")
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

    -- 2) ТОЧКА ВЫЛЕТА. Сервер разрешает увести её на SHOT_ORIGIN_SLACK
    --    (14 студов). Если стена ближе этого - ставим точку ЗА стеной,
    --    и пуля начинается по ту сторону стены.
    if posIdx then
        if pre.wallPast then
            out[posIdx] = pre.wallPast
            replaced = true
            bits[#bits + 1] = "точка вылета ЗА стеной #" .. tostring(posIdx)
        else
            local back = tonumber(G.BS.SpoofBack) or 0
            if back > 0 then
                if back > 100 then back = 100 end
                out[posIdx] = pre.pos - aimDir * back
                replaced = true
                bits[#bits + 1] = "точка вылета #" .. tostring(posIdx)
            end
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
    -- КАЖДЫЕ 25 ВЫСТРЕЛОВ печатаем долю попаданий. Так сразу видно,
    -- работает ли подмена: 0% = выстрелы отклоняются (угол взгляда
    -- больше SHOT_ANGLE_SLACK_DEG = 3), 100% = попадает.
    if (G.BS.SilentShots % 25) == 0 then
        local shots = G.BS.SilentShots
        local dmg = tonumber(G.BS.DmgEvents) or 0
        local pct = 0
        if shots > 0 then pct = math.floor((dmg / shots) * 100) end
        print(string.format("[BS DMG] выстрелов: %d | урон получен: %d | ~%d%%",
            shots, dmg, pct))
        -- ПОДСКАЗКА, что крутить дальше.
        if pct >= 85 then
            print("[BS DMG] Отлично. Если хочешь дальше — снизь AimLead "
                .. "до 0.05 (стабильнее по стоящим).")
        elseif pct >= 45 then
            print("[BS DMG] Работает, но не всегда. По бегущим добавь "
                .. "опережение: getgenv().BS.AimLead = 0.15")
        else
            print("[BS DMG] Мало попаданий. Проверь: 1) скорость аимлока "
                .. "getgenv().BS.AimLockSpeed = 35  2) угол триггера "
                .. "getgenv().BS.TriggerDeg = 20  3) дальность "
                .. "getgenv().BS.AimMaxDist = 150")
        end
    end
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
        -- МЕЛЬЕ: удар дубинкой / формой вампира / тейзером.
        elseif method == "FireServer"
            and (self == NC.melee or self == NC.tfmelee or self == NC.stun) then
            if G.BS.MeleeAim then
                local out, n = ncMeleeDir(...)
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
--  АВТОПРОВЕРКА ОРУЖИЯ (дальность, разброс, урон)
-- ============================================================
-- Запускается сама через несколько секунд после загрузки и печатает
-- в консоль ТОЛЬКО то, что относится к стрельбе: дальность, разброс,
-- урон, темп, заряд. По этим числам видно, почему выстрел не
-- достаёт (например у дробовика дальность 90 студов, а мы стреляем
-- на 404).
local WEAPON_WORDS = {
    "range", "distance", "dist", "spread", "damage", "dmg", "fire",
    "rate", "ammo", "charge", "recoil", "speed", "cooldown", "pellet",
    "hit", "pierce", "wall", "bullet", "shot", "gun", "weapon",
    "murder", "lethal", "power", "accuracy", "velocity", "duration",
}

local function weaponKey(k)
    local n = string.lower(tostring(k or ""))
    for i = 1, #WEAPON_WORDS do
        if string.find(n, WEAPON_WORDS[i], 1, true) then return true end
    end
    return false
end

local function probeMod(mod, label, depth, found, cnt)
    if depth > 3 or cnt[1] > 140 then return end
    pcall(function()
        for k, v in pairs(mod) do
            if type(v) == "table" then
                probeMod(v, label .. "." .. tostring(k), depth + 1, found, cnt)
            elseif weaponKey(k) and (type(v) == "number" or type(v) == "string"
                   or type(v) == "boolean") then
                cnt[1] = cnt[1] + 1
                if cnt[1] <= 140 then
                    found[#found + 1] = label .. "." .. tostring(k) .. " = " .. valToStr(v)
                end
            end
        end
    end)
end

local function probeWeapon()
    hr("ПРОВЕРКА ОРУЖИЯ (дальность / разброс / урон)")
    local base = TRS:FindFirstChild("BloodyStreet")
    if not base then
        print("[BS WEAPON] ReplicatedStorage.BloodyStreet не найден")
        return
    end
    local names = { "Combat", "Ballistics", "Murder", "Mystery",
                    "Loadout", "Match", "ToolCooldown", "Roles" }
    for _, nm in ipairs(names) do
        local found, cnt = {}, { 0 }
        local mod = base:FindFirstChild(nm)
        if not mod then
            pcall(function()
                for _, d in ipairs(base:GetDescendants()) do
                    if d.ClassName == "ModuleScript" and d.Name == nm then
                        mod = d
                        break
                    end
                end
            end)
        end
        if mod then
            local okr, m2 = pcall(require, mod)
            if okr and type(m2) == "table" then
                probeMod(m2, nm, 1, found, cnt)
                print("  " .. nm .. ": найдено параметров — " .. cnt[1])
                for i = 1, #found do print("    " .. found[i]) end
            else
                print("  " .. nm .. ": require не удался")
            end
        end
    end

    -- моё оружие: что реально в руках
    local ch = LP and LP.Character
    local tool = ch and ch:FindFirstChildOfClass("Tool")
    if tool then
        print("  ОРУЖИЕ: " .. tool.Name)
        local okA, at = pcall(function() return tool:GetAttributes() end)
        if okA and type(at) == "table" then
            for k, v in pairs(at) do print("    " .. tostring(k) .. " = " .. valToStr(v)) end
        end
        local mz = tool:FindFirstChild("Muzzle")
        if mz then
            local wp = mz.WorldPosition
            print(string.format("    Muzzle = (%.1f, %.1f, %.1f)", wp.X, wp.Y, wp.Z))
        end
    end
    hr("ПРОВЕРКА ОРУЖИЯ ЗАКОНЧЕНА")
end

-- «РАСШИРИТЕЛЬ ХИТБОКСА» удалён по просьбе: работает только при
-- клиентском подсчёте урона, а игра считает урон на сервере
-- (Config.Combat — серверные проверки SHOT_ORIGIN_SLACK / SHOT_HIT_SLACK).

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
local lastAmmo = 0
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

    -- аимлок: доводим взгляд на ту же цель, чтобы сервер принял выстрел
    if G.BS.AimLock then pcall(aimLockTick, dt, now) end

    -- подсветка текущей цели
    pcall(updateTargetMark)

    -- точка прицеливания (видно, куда реально летит патрон)
    if G.BS.AimDot then pcall(updateAimDot) end

    -- бесконечные патроны (раз в 0.25 с)
    if G.BS.InfAmmo and now - lastAmmo >= 0.25 then
        lastAmmo = now
        pcall(refillCharges)
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
    LoadingSubtitle = "ESP + Client Aim v11.2",
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

TB.CreateToggle({
    Name = "Бесконечные патроны", Flag = "BS_InfAmmo",
    CurrentValue = G.BS.InfAmmo,
    Callback = function(v)
        G.BS.InfAmmo = v
        pcall(refillCharges)
    end,
})
TB.CreateToggle({ Name = "Подсветка текущей цели", Flag = "BS_TargetMark",
    CurrentValue = G.BS.TargetMark,
    Callback = function(v)
        G.BS.TargetMark = v
        if not v and TargetHL then TargetHL.Enabled = false end
    end })
TB.CreateColorPicker({ Name = "Цвет подсветки цели", Flag = "BS_TargetMarkColor",
    Color = G.BS.TargetMarkColor,
    Callback = function(c) G.BS.TargetMarkColor = c end })

TB.CreateColorPicker({ Name = "Цвет точки прицела", Flag = "BS_AimDotColor",
    Color = G.BS.AimDotColor,
    Callback = function(c) G.BS.AimDotColor = c end })
TB.CreateToggle({ Name = "Точка прицеливания (видно, куда летит)", Flag = "BS_AimDot",
    CurrentValue = G.BS.AimDot,
    Callback = function(v)
        G.BS.AimDot = v
        if not v and aimDot then aimDot.Visible = false end
    end })
TB.CreateSection("Сканер")
TB.CreateButton({ Name = "СКАНИРОВАТЬ ИГРУ (в консоль)", Callback = function()
    pcall(scanAll)
    notify("Скан отработал, смотри консоль", 4)
end })
TB.CreateButton({ Name = "ГЛУБОКОЕ СКАНИРОВАНИЕ (найти модули оружия)", Callback = function()
    pcall(deepScan)
    notify("Глубокий скан отработал, смотри консоль", 4)
end })
TB.CreateButton({ Name = "ПРОВЕРКА ОРУЖИЯ (дальность/разброс)", Callback = function()
    pcall(probeWeapon)
    notify("Проверка оружия отработала, смотри консоль", 4)
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

-- АИМЛОК доводит взгляд на цель только когда реально стреляешь.
AI.CreateToggle({
    Name = "Аим по частям (голова → ноги → руки)", Flag = "BS_AimChain",
    CurrentValue = G.BS.AimChain,
    Callback = function(v)
        G.BS.AimChain = v
        notify(v and "Голова/корпус, иначе ноги, иначе руки" or "Только выбранная часть", 3)
    end,
})
AI.CreateToggle({
    Name = "Целиться в свободные (видимые) части", Flag = "BS_AimFreePart",
    CurrentValue = G.BS.AimFreePart,
    Callback = function(v)
        G.BS.AimFreePart = v
        notify(v and "Перекрыто -> берём ноги, потом руки" or "Всегда выбранная часть", 3)
    end,
})
AI.CreateToggle({
    Name = "Аимлок (камера целится в жертву)", Flag = "BS_AimLock",
    CurrentValue = G.BS.AimLock,
    Callback = function(v)
        G.BS.AimLock = v
        notify(v and "Камера доводится на цель" or "Аимлок выключен", 3)
    end,
})
AI.CreateToggle({
    Name = "Аимлок только с оружием в руках", Flag = "BS_AimLockNeedAim",
    CurrentValue = G.BS.AimLockNeedAim,
    Callback = function(v) G.BS.AimLockNeedAim = v end,
})
AI.CreateToggle({
    Name = "Аимлок только пока держишь огонь", Flag = "BS_AimLockFireOnly",
    CurrentValue = G.BS.AimLockFireOnly,
    Callback = function(v) G.BS.AimLockFireOnly = v end,
})
AI.CreateToggle({
    Name = "Аимлок не наводится сквозь стены", Flag = "BS_AimLockNoWall",
    CurrentValue = G.BS.AimLockNoWall,
    Callback = function(v) G.BS.AimLockNoWall = v end,
})
AI.CreateSlider({ Name = "Скорость доворота камеры", Flag = "BS_AimLockSpeed",
    Range = {0, 40}, Increment = 1, CurrentValue = G.BS.AimLockSpeed,
    Suffix = " (0 = мгновенно)",
    Callback = function(v) G.BS.AimLockSpeed = v end })

AI.CreateSection("Триггер и прострел")
AI.CreateToggle({
    Name = "Только враг прямо по курсу", Flag = "BS_Trigger",
    CurrentValue = G.BS.Trigger,
    Callback = function(v)
        G.BS.Trigger = v
        notify(v and "Целимся только тех, кто впереди" or "Целимся и сзади", 3)
    end,
})
AI.CreateSlider({ Name = "Угол триггера (как у игры)", Flag = "BS_TriggerDeg",
    Range = {1, 60}, Increment = 1, CurrentValue = G.BS.TriggerDeg,
    Suffix = " градусов",
    Callback = function(v) G.BS.TriggerDeg = v end })
AI.CreateSlider({ Name = "Радиус триггера (экран, при 0°)", Flag = "BS_TriggerCone",
    Range = {3, 40}, Increment = 1,
    CurrentValue = math.floor((G.BS.TriggerCone or 0.1) * 100),
    Suffix = " x0.01 экрана",
    Callback = function(v) G.BS.TriggerCone = v / 100 end })
AI.CreateToggle({
    Name = "Аим для ломы / формы / тейзера", Flag = "BS_MeleeAim",
    CurrentValue = G.BS.MeleeAim,
    Callback = function(v)
        G.BS.MeleeAim = v
        notify(v and "Удар ломой идёт в цель" or "Аим для ломы выключен", 3)
    end,
})
AI.CreateToggle({
    Name = "Прострел стен (точка вылета за стеной)", Flag = "BS_WallPenetrate",
    CurrentValue = G.BS.WallPenetrate,
    Callback = function(v)
        G.BS.WallPenetrate = v
        notify(v and "Стена ближе 13 студов - выстрел из-за неё" or "Прострел выключен", 4)
    end,
})
AI.CreateSlider({ Name = "Дальность подмены (макс 300)", Flag = "BS_AimMaxDist",
    Range = {30, 300}, Increment = 10, CurrentValue = G.BS.AimMaxDist,
    Suffix = " studs",
    Callback = function(v) G.BS.AimMaxDist = v end })

-- Секция «Расширитель хитбокса» удалена: прозрачные CanQuery-части
-- видны только клиенту, а урон считает сервер (Config.Combat).

-- Секция «Цель» («Кого целить», «Приоритет», «Радиус захвата») и
-- пикеры «Цвет: захват цели» / «Цвет метки» удалены по просьбе.
-- Логика выбора цели осталась и работает на дефолтах:
--   AIM_TARGETS  = противники по роли, AIM_PRIORITY = ближе,
--   радиус 160 px, прострел включён.

AI.CreateToggle({
    Name = "Лог попаданий (урон от сервера)", Flag = "BS_DmgLog",
    CurrentValue = G.BS.DmgLog,
    Callback = function(v)
        G.BS.DmgLog = v
        if v then notify("Каждое попадание будет в консоли", 3) end
    end,
})
AI.CreateButton({ Name = "СЧЁТ: выстрелы / попадания", Callback = function()
    print(string.format(
        "[BS DMG] выстрелов подменено: %d | событий урона: %d | цель: %s",
        tonumber(G.BS.SilentShots) or 0, tonumber(G.BS.DmgEvents) or 0,
        tostring(bulletPreShot and bulletPreShot.part.Name or "нет")))
end })

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
    if TargetHL then pcall(function() TargetHL:Destroy() end) end
    if aimDot then pcall(function() aimDot:Remove() end) end
    if Overlay then pcall(function() Overlay:Destroy() end) end
    Screen = nil
    Overlay = nil
    TargetHL = nil
    aimDot = nil
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
    print("[BS HUB] v11.2 остановлен")
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
    -- АВТОПРОВЕРКА ОРУЖИЯ: сама собирает дальность/разброс/урон и
    -- печатает в консоль. Ничего нажимать не нужно — смотри блок
    -- [BS WEAPON] и пришли его.
    if G.BS.WeaponProbeOnStart then
        task.wait(3)
        pcall(probeWeapon)
    end
end)

print("[BS HUB] v11.2 запущен | хуков=" .. #netConns
    .. " | клиент айм: " .. tostring(G.BS.BulletSwap)
    .. " | аимлок: " .. tostring(G.BS.AimLock)
    .. " | триггер: " .. tostring(G.BS.Trigger)
    .. " | лома: " .. tostring(G.BS.MeleeAim)
    .. " | патроны: " .. tostring(G.BS.InfAmmo)
    .. " | прострел: " .. tostring(G.BS.Penetrate)
    .. " | ошибок GUI=" .. #UI_ERR)
