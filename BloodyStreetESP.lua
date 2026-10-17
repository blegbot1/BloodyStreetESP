-- ============================================================
--  BLOODY STREET - ESP + КЛИЕНТ АИМ + ТАНЕЦ  v11.9
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
-- БЕСКОНЕЧНЫЕ ПАТРОНЫ УДАЛЕНЫ: счётчик патронов живёт на сервере,
-- клиентом его не наполнить - сервер всё равно не засчитывает
-- выстрел (проверено на игре). Зато есть кулдаун: он клиентский, и его
-- можно снять. Config.Combat.WEAPON_COOLDOWN = 0.3.
G.BS.NoCooldown   = G.BS.NoCooldown ~= false
-- СТАТУС ЦЕЛИ в ESP (сбит/раскрыт/оглушён) + ХИТМАРКЕР при попадании
-- + ЛЕНТА СОБЫТИЙ (раунд, разоблачения, смерти) в углу экрана.
G.BS.ShowStatus   = G.BS.ShowStatus ~= false
G.BS.HitMark      = G.BS.HitMark ~= false
G.BS.HitMarkColor = safeColor(G.BS.HitMarkColor, Color3.new(1, 0.25, 0.25))
G.BS.HitMarkLife  = tonumber(G.BS.HitMarkLife) or 0.25
G.BS.EventsOn     = G.BS.EventsOn ~= false
-- Сдвиг времени выстрела в ремоуте (аргумент №5) вперёд, чтобы
-- сервер считал, что WEAPON_COOLDOWN уже прошёл.
G.BS.ShotTimeHack = G.BS.ShotTimeHack == true
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
-- Скорость доворота: 1 = мгновенно (нужно по правилу сервера
-- SHOT_ANGLE_SLACK_DEG = 3), меньше 1 = плавно, 0 = не доворачивать.
-- ПО УМОЛЧАНИЮ 1: плавный доворот давал «отставание» при ходьбе.
G.BS.AimLock       = G.BS.AimLock ~= false
G.BS.AimLockSpeed  = tonumber(G.BS.AimLockSpeed) or 1
-- Аимlock включается только когда это нужно, чтобы не дёргать камеру:
--   FireOnly — только пока зажат огонь.
-- Плюс в коде проверяется, что в руках именно ОРУЖИЕ.
G.BS.AimLockFireOnly = G.BS.AimLockFireOnly == true
-- УДЕРЖАНИЕ ЦЕЛИ, секунды. Пока идёт это время (и тем более пока
-- зажат огонь), аимлок ведёт ту же цель, даже если она отошла из
-- под прицела. Раньше цель каждый кадр выбиралась заново, и стоило
-- чуть дёрнуть камеру - захват слетал.
G.BS.LockHold       = tonumber(G.BS.LockHold) or 0.6
G.BS.LockHoldOnFire = G.BS.LockHoldOnFire ~= false
-- Единый список целей: маркер ESP, аимлок и подмена патрона всегда
-- про одного и того же врага.
G.BS.SyncTarget     = G.BS.SyncTarget ~= false
-- Аимлок и точка прицела по цели ИЗ СПИСКА (а не по свободной части).
G.BS.AimLockListTarget = G.BS.AimLockListTarget == true
-- ТРИГГЕР УДАЛЁН (по просьбе): раньше скрипт работал только когда
-- враг был ПРЯМО в конусе прицела (12 градусов, как автоатака
-- игры), иначе выстрел вообще не подменялся - бот молчал, пока
-- цель не попадала в узкий конус. Теперь цель выбирается всегда:
-- сначала та, что ближе к центру экрана, иначе ближайшая.
G.BS.Trigger         = true   -- оставлено только для совместимости
                               -- старых сохранённых настроек, не влияет
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
-- ГЛУБОКИЙ ЛОГ: все 94 ремоута без ограничения вызовов + разбор
-- таблиц + входящие события сервера ([BS IN]). Консоль будет
-- большой - это того стоит, по нему видно правила сервера.
G.BS.DeepRemoteLog = G.BS.DeepRemoteLog == true
G.BS.MaxInLog    = tonumber(G.BS.MaxInLog) or 400

-- ЗВУКОВЫЕ МЕТКИ. Игра шлёт SoundPing {pos, sound} на каждый шум
-- (Config.Detection.SOUND_PING_ENABLED, RADIUS 90, DURATION 2.2):
-- выстрел, крик. Раньше скрипт их только собирал, теперь рисует
-- кольцо в точке шума - видно, где стреляли, даже если стрелявшего
-- не видно.
G.BS.NoiseMarks = G.BS.NoiseMarks ~= false
G.BS.NoiseLife  = tonumber(G.BS.NoiseLife) or 2.2
-- ОСОБЫЕ РОЛИ ПО ПРЕДМЕТУ (Config.Roles.ROLE_TOOL_MODEL):
-- Medkit = доктор, MagnifyingGlass = детектив, SeerStaff = сейер,
-- HolyCross = жрец, Garlic = торговец, SupplyCrate = оружейщик,
-- Baton/Claw = вампир. Показывать в подписи к ESP.
G.BS.ShowSpecialRole = G.BS.ShowSpecialRole ~= false
-- HUD: одна строка в углу - своя роль, фаза, патроны, текущая цель.
G.BS.Hud = G.BS.Hud ~= false
-- ТАНЕЦ НА ХОДЬБЕ + СПИН. Игровые эмоуты отменяются движением,
-- поэтому анимацию проигрываем сами (LoadAnimation + высокий приоритет).
-- Спин и покачивание - свои, поворот модели, ассеты не нужны.
G.BS.DanceOn     = false
G.BS.Spin        = false
G.BS.Sway        = false
G.BS.SpinSpeed   = tonumber(G.BS.SpinSpeed) or 360   -- градусов в секунду
G.BS.SwayAmp     = tonumber(G.BS.SwayAmp) or 20      -- градусов
G.BS.DanceHotkey = G.BS.DanceHotkey ~= false        -- клавиша F7
G.BS.DanceAutoScan = G.BS.DanceAutoScan ~= false
-- БОЕВОЙ СПРИНТ («спин» в бою): модель доворачивается по направлению
-- бега, а не едет боком. Отдельно от танца — работает всегда.
G.BS.Sprint       = G.BS.Sprint ~= false
G.BS.SprintSpeed  = tonumber(G.BS.SprintSpeed) or 1     -- м/с, порог бега
G.BS.SprintTurn   = tonumber(G.BS.SprintTurn) or 10    -- скорость доворота

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
if G.BS.CfgV ~= 26 then
    G.BS.CfgV      = 26
    G.BS.AimLockSpeed = 1      -- мгновенный доворот (иначе отстаёт на ходу)
    G.BS.LockHold      = 0.6
    G.BS.LockHoldOnFire = true
    G.BS.SyncTarget    = true
    G.BS.AimLockListTarget = false
    G.BS.AimLockSpeed = 25     -- SHOT_ANGLE_SLACK_DEG = 3
    G.BS.DanceOn   = false
    G.BS.Spin      = false
    G.BS.Sway      = false
    G.BS.SpinSpeed = 360
    G.BS.SwayAmp   = 20
    G.BS.DanceHotkey   = true
    G.BS.DanceAutoScan = true
    G.BS.NoiseMarks = true
    G.BS.NoiseLife  = 2.2
    G.BS.ShowSpecialRole = true
    G.BS.Hud        = true
    G.BS.AimChain  = true
    G.BS.AimFreePart = true
    G.BS.NoCooldown = true
    G.BS.ShowStatus = true
    G.BS.HitMark    = true
    G.BS.EventsOn   = true
    G.BS.ShotTimeHack = false
    G.BS.TargetMark = true
    G.BS.AimMaxDist   = 290    -- Config.Combat.BULLET_RANGE = 300
    G.BS.AimLead   = 0.08
    G.BS.AimLock   = true
    -- SHOT_ANGLE_SLACK_DEG = 3: взгляд и патрон должны совпадать
    G.BS.AimLockFireOnly = false
    G.BS.AimLockNoWall = true
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
             sending = false, lastSend = 0, lastShotT = 0,
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
-- ОБЩИЙ СПИСОК ЦЕЛЕЙ. Его наполняет computeBulletPreShot (раз в кадр),
-- а читают: хук подмены патрона, аимлок, маркер цели в ESP и HUD.
-- Когда список один на всех, они не могут разойтись по целям.
local bulletList       = {}       -- [{part, char, player, dist, screen}]
local bulletListTarget = nil      -- выбранный Part (BOS)

-- ХИТМАРКЕР И ЛЕНТА СОБЫТИЙ. Определения ниже (после hitMarkAt нужно
-- поймать урон из обработчика ремоутов, который объявлен раньше), здесь
-- только forward-объявления.
local EVENTS       = {}     -- последние события (последние 8)
local addEvent               -- добавить строку в ленту (ниже)
local hitMarkAt   = 0       -- os.clock() последнего реального попадания
local hitLines    = {}      -- Drawing-линии хитмаркера
local eventsLabel = nil     -- TextLabel ленты в углу экрана
local updateHitMark, updateEvents

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
        special = nil, status = nil,
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

-- СПИСОК ЦЕЛЕЙ, ОТСОРТИРОВАННЫЙ ПО ЭКРАНУ. Именно он выбирается
    -- и для подмены патрона (хук), и для аимлока, и для точки
    -- прицела. Раньше каждая из этих вещей решала «какая цель»
    -- по-своему, из-за чего аимлок смотрел на одного, а патрон летел
    -- в другого - и всё выглядело сломанным.
    -- (объявлен ниже, рядом с computeBulletPreShot - там, где уже
    --  определена pickPartOf)
local function pickTarget(cam)
    -- ГЛАВНОЕ: маркер цели и аимлок должны показывать ОДНОГО человека.
    -- Раньше здесь был отдельный поиск (свои FOV и приоритет), а
    -- патрон летел по pickPartOf - можно было получить «маркер на
    -- одном, пуля в другом». Теперь приоритет у bulletListTarget,
    -- который реально выбрал клиент-айм; старый поиск - запасной.
    if G.BS.SyncTarget ~= false and bulletListTarget and bulletListTarget.Parent then
        local ok, plr = pcall(function()
            return Players:GetPlayerFromCharacter(bulletListTarget.Parent)
        end)
        if ok and plr and plr ~= LP and by[plr] and isEnemy(plr) then
            locked = plr
            return plr
        end
    end
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

local incomingSeen = {}   -- сколько раз напечатали каждый входящий ремоут
local incomingCount = 0   -- всего строк входящего лога (ограничиваем)
local dumpArgs     -- разбор таблицы-аргумента ремоута (объявлен ниже)

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
                            addEvent("ФАЗА: " .. tostring(st.phase)
                                .. " (в " .. tostring(st.vampires or 0)
                                .. " в, " .. tostring(st.hunters or 0) .. " х)")
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
                            addEvent("РАЗОБЛАЧЕНИЕ: " .. tostring(a.name)
                                .. " = " .. tostring(a.role))
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
                            addEvent("ТЕСТ КРОВИ: " .. tostring(f.name)
                                .. (f.vampire == true and " = ВАМПИР" or " = не вампир"))
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
                        -- ХИТМАРКЕР: урон пришёл с сервера = попадание
                        -- реально засчиталось. Плюс строка в ленту событий.
                        hitMarkAt = os.clock()
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
                        elseif G.BS.DmgLog and cnt % 10 == 0 then
                            -- раз в 10 событий, а не каждое: иначе
                            -- за бой улетало 300+ строк одного и того же
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

-- ЛОГ ВХОДЯЩИХ СОБЫТИЙ (сервер -> клиент). Лог ремоутов выше ловит
-- только FireServer/InvokeServer, а самые ценные данные игра шлёт
-- ВНУТРЬ: CombatFeed/DamagePopup (урон), DetectionFeed/Announce
-- (разоблачение), EmotePlay (эмоуты), MatchResults, SuddenDeath.
-- С глубоким разбором таблиц это даёт полную картину серверных
-- правил - по ней и калибруется аим.
if Remotes and G.BS.DeepRemoteLog then
    for _, r in ipairs(Remotes:GetChildren()) do
        if r:IsA("RemoteEvent") then
            local cc = r.OnClientEvent:Connect(function(...)
                local cap = tonumber(G.BS.MaxInLog) or 400
                if incomingCount >= cap then return end
                local inSeenKey = r.Name
                local c2 = incomingSeen[inSeenKey] or 0
                if c2 >= 3 then return end
                incomingSeen[inSeenKey] = c2 + 1
                incomingCount = incomingCount + 1
                local n = select("#", ...)
                local list = {}
                for i = 1, math.min(n, 8) do
                    local a = select(i, ...)
                    local t = typeof(a)
                    local v
                    if t == "string" or t == "boolean" then
                        v = tostring(a)
                    elseif t == "number" then
                        v = string.format("%.2f", a)
                    elseif t == "Vector3" then
                        v = string.format("%.1f, %.1f, %.1f", a.X, a.Y, a.Z)
                    elseif t == "Instance" then
                        v = a.ClassName .. " " .. a.Name
                    elseif t == "Player" then
                        v = "Player " .. a.Name
                    elseif t == "EnumItem" then
                        v = tostring(a.Name)
                    elseif t == "table" then
                        v = dumpArgs(a, 1)
                    end
                    list[i] = i .. ":" .. t .. (v and (" (" .. v .. ")") or "")
                end
                print("[BS IN] " .. r.Name .. " n=" .. n .. "  "
                    .. table.concat(list, " | "))
            end)
            netConns[#netConns + 1] = cc
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

-- Названия ролей для HUD и подписи ESP.
local ROLE_NAME = {
    doctor     = "Доктор",
    detective  = "Детектив",
    seer       = "Сейер",
    priest     = "Жрец",
    merchant   = "Торговец",
    armsdealer = "Оружейщик",
    vampire    = "Вампир",
    hunter     = "Хантер",
    none       = "Гражданский",
}

-- ============================================================
--  HUD: своя роль, фаза раунда, патроны, текущая цель
-- ============================================================
-- Одна строка в углу: видно, кто мы, что за фаза, сколько патронов
-- и в кого сейчас целимся - без открытия GUI.
local hudLabel = nil
local hudGui = nil
local lastHud = 0

local function ensureHud()
    if hudLabel then return true end
    local okG, gui = pcall(function() return Instance.new("ScreenGui") end)
    if not okG or not gui then return false end
    gui.Name                 = "BS_Hud"
    gui.IgnoreGuiInset       = false
    gui.ResetOnSpawn         = false
    gui.DisplayOrder         = 10
    local okP = pcall(function() gui.Parent = game:GetService("CoreGui") end)
    if not okP then return false end
    local okT, t = pcall(function() return Instance.new("TextLabel") end)
    if not okT or not t then return false end
    t.Name             = "BS_HudText"
    t.BackgroundColor3 = Color3.new(0, 0, 0)
    t.BackgroundTransparency = 0.55
    t.TextColor3       = Color3.new(0.95, 0.95, 1)
    t.Size             = UDim2.fromOffset(560, 20)
    t.Position         = UDim2.new(0, 10, 0, 8)
    t.Font             = Enum.Font.Code
    t.TextSize         = 13
    t.TextXAlignment   = Enum.TextXAlignment.Left
    t.TextYAlignment   = Enum.TextYAlignment.Center
    t.Parent           = gui
    hudGui, hudLabel = gui, t
    return true
end

local function updateHud(now)
    if not G.BS.Hud then
        if hudLabel then hudLabel.Visible = false end
        return
    end
    if not ensureHud() then return end
    if now - lastHud < 0.2 then return end
    lastHud = now

    local me = ROLE_NAME[string.lower(tostring(G.BS.MyRole or ""))] or "?"
    local ch = LP and LP.Character
    local tool = ch and ch:FindFirstChildOfClass("Tool")
    local myRoot = ch and ch:FindFirstChild("HumanoidRootPart")
    local charges = "?"
    if tool then
        local cv = tool:GetAttribute("Charges")
        local mx = tool:GetAttribute("MaxCharges")
        if type(cv) == "number" then
            charges = tostring(math.floor(cv))
            if type(mx) == "number" then charges = charges .. "/" .. tostring(math.floor(mx)) end
        end
    end
    local pre = bulletPreShot
    local tgt = "нет"
    if pre and pre.part and pre.part.Parent then
        local root = pre.part.Parent:FindFirstChild("HumanoidRootPart")
        local d = (root and myRoot and (root.Position - myRoot.Position).Magnitude)
            or pre.dist
        tgt = pre.part.Name .. " (" .. math.floor(d + 0.5) .. " st)"
        if pre.wallPast then tgt = tgt .. " [за стеной]" end
    end
    local line = string.format("[BS] роль: %s | фаза: %s | заряды: %s | оружие: %s | цель: %s",
        me, tostring(G.BS.RoundPhase or "?"), charges,
        tool and tool.Name or "нет", tgt)
    hudLabel.Text = line
    hudLabel.Visible = true
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
--  ЗВУКОВЫЕ МЕТКИ (SoundPing) — радар шума
-- ============================================================
-- Игра шлёт SoundPing {pos, sound}, когда кто-то выстрелил или
-- закричал (Config.Detection.SOUND_PING_ENABLED, RADIUS 90,
-- DURATION 2.2). Раньше мы эти данные просто собирали в soundMarks и
-- НИЧЕГО не рисовали. Теперь это видимый радар: кольцо расходится и
-- гаснет в точке шума, с подписью типа звука.
local noiseRings, noiseLabels = {}, {}
local NOISE_POOL = 14

local function noiseColor(s)
    local n = string.lower(tostring(s or ""))
    if string.find(n, "gun", 1, true) or string.find(n, "shot", 1, true)
        or string.find(n, "fire", 1, true) then
        return Color3.new(1, 0.35, 0.2)
    end
    if string.find(n, "scream", 1, true) or string.find(n, "help", 1, true)
        or string.find(n, "call", 1, true) then
        return Color3.new(1, 0.95, 0.25)
    end
    return Color3.new(0.8, 0.9, 1)
end

local function ensureNoisePool()
    if #noiseRings >= NOISE_POOL then return end
    if not DRAW_OK then return end
    for i = #noiseRings + 1, NOISE_POOL do
        local ok, d = pcall(function() return Drawing.new("Circle") end)
        if not ok or not d then return end
        d.Thickness    = 2
        d.NumSides     = 24
        d.Filled       = false
        d.Visible      = false
        noiseRings[i]  = d
        local ok2, t = pcall(function() return Drawing.new("Text") end)
        if ok2 and t then
            t.Visible = false
            t.Center  = true
            t.Size    = 13
            noiseLabels[i] = t
        end
    end
end

local function updateNoiseMarks()
    ensureNoisePool()
    if not G.BS.NoiseMarks then
        for i = 1, #noiseRings do
            noiseRings[i].Visible = false
            if noiseLabels[i] then noiseLabels[i].Visible = false end
        end
        return
    end
    local cam = workspace.CurrentCamera
    if not cam then return end
    local now = os.clock()
    local life = tonumber(G.BS.NoiseLife) or 2.2
    for i = #soundMarks, 1, -1 do
        if now - soundMarks[i].t > life then table.remove(soundMarks, i) end
    end
    local n = #soundMarks
    for i = 1, NOISE_POOL do
        local ring = noiseRings[i]
        if not ring then break end
        local lb = noiseLabels[i]
        local idx = n - i + 1
        if idx >= 1 then
            local m = soundMarks[idx]
            local age = now - m.t
            local sp = cam:WorldToViewportPoint(m.pos)
            if sp.Z > 0 and age <= life then
                local k = 1 - age / life          -- 1 = свежее
                ring.Position = Vector2.new(sp.X, sp.Y)
                ring.Radius   = math.floor(6 + (1 - k) * 30)
                ring.Color    = noiseColor(m.s)
                ring.Transparency = k * 0.55
                ring.Visible  = true
                if lb then
                    lb.Position     = Vector2.new(sp.X, sp.Y - 20)
                    lb.Text         = tostring(m.s or "шум")
                    lb.Color        = ring.Color
                    lb.Transparency = k * 0.4
                    lb.Visible      = true
                end
            else
                ring.Visible = false
                if lb then lb.Visible = false end
            end
        else
            ring.Visible = false
            if lb then lb.Visible = false end
        end
    end
end

-- ============================================================
--  ТАНЕЦ НА ХОДЬБЕ + СПИН
-- ============================================================
-- Игровые эмоуты отменяются движением: начал идти - танец слетел.
-- Поэтому мы проигрываем анимацию САМИ через Animator:LoadAnimation:
-- свой трек с высоким приоритетом и Looped = movement его не сбрасывает.
-- Персонаж идёт и танцует одновременно.
--
-- Откуда берём танцы (три источника):
--   1) Animation-объекты в реплицируемых папках игры - их ассеты
--      точно принадлежат игре, значит проиграются всегда;
--   2) строки rbxassetid:// в таблицах клиентских модулей
--      (require + обход таблицы, как в deepScan);
--   3) анимации, которые игра УЖЕ играет на нашем персонаже
--      (Animator:GetPlayingAnimationTracks) - если станцевать
--      штатным эмоутом, его ID сам попадёт в список.
--
-- Плюс два СВОИХ режима, которым не нужен ни один ассет и которые
-- работают ВСЕГДА: «Спин» (оборот на 360) и «Покачивание».
-- Они крутят модель через PivotTo и не мешают ходьбе.
--
-- Спин работает и ПОВЕРХ ассетного танца (можно включить оба).

local DANCES  = {}          -- [{label, id}] - найденные анимации
local DANCE_BY_LABEL = {}   -- "label|id" -> true (защита от повторов)
local DANCE_BY_NAME  = {}   -- label -> id (для выпадающего списка)
local dance = {
    on = false,             -- танец включён
    label = "", id = nil,    -- выбранная анимация
    track = nil, anim = nil, animator = nil, lowered = {},
    spin = false, sway = false,
    spinSpeed = 360, swayAmp = 20, swaySpeed = 2.4,
    yaw = 0, prevYaw = 0, autoRotSaved = nil, arHum = nil,
    hotkey = "F7", scanAt = 0,
}

local CORE_P = (Enum.AnimationPriority and Enum.AnimationPriority.Core
    and Enum.AnimationPriority.Core.Value) or 127

-- "Idle"/"Walk"/"Run" - это НЕ танцы, их в список не берём.
local MOVE_TRACKS = {
    idle = true, walk = true, run = true, jump = true, fall = true,
    climb = true, swim = true, land = true, sprint = true, crouch = true,
    death = true, seated = true, freefall = true,
}

local function normAnimId(id)
    if type(id) ~= "string" then return nil end
    local s = string.match(id, "rbxassetid://(%d+)")
    if not s then s = string.match(id, "^(%d+)$") end
    if not s or s == "0" then return nil end
    return s
end

local function addDance(label, id)
    local s = normAnimId(id)
    if not s then return false end
    label = tostring(label or "?")
    if string.len(label) > 42 then label = string.sub(label, 1, 42) end
    local key = label .. "|" .. s
    if DANCE_BY_LABEL[key] then return false end
    DANCE_BY_LABEL[key] = true
    if not DANCE_BY_NAME[label] then DANCE_BY_NAME[label] = s end
    DANCES[#DANCES + 1] = { label = label, id = s }
    return true
end

-- 1) Animation-объекты игры
local function scanAnimInstances(out)
    local names = { "ReplicatedStorage", "StarterPlayer", "StarterGui" }
    for _, n in ipairs(names) do
        local root
        pcall(function() root = game:GetService(n) end)
        if root then
            pcall(function()
                for _, d in ipairs(root:GetDescendants()) do
                    if d.ClassName == "Animation" and d.AnimationId
                       and d.AnimationId ~= "" then
                        if addDance(d.Name, d.AnimationId) then
                            out[#out + 1] = d.Name .. "  (" .. d.AnimationId .. ")"
                        end
                    end
                end
            end)
        end
    end
end

-- 2) строки rbxassetid:// в таблицах модулей
local function scanModuleIds(out)
    local mods = {}
    local function collect(inst, depth)
        if depth > 3 or #mods > 60 then return end
        local kids
        pcall(function() kids = inst:GetChildren() end)
        if not kids then return end
        for _, ch in ipairs(kids) do
            if ch:IsA("ModuleScript") then
                mods[#mods + 1] = ch
            elseif ch:IsA("Folder") or ch:IsA("Model") then
                collect(ch, depth + 1)
            end
        end
    end
    pcall(function() collect(game:GetService("ReplicatedStorage"), 0) end)
    for i = 1, math.min(#mods, 45) do
        local m = mods[i]
        local ok, t = pcall(function() return require(m) end)
        if ok and type(t) == "table" then
            local seen = 0
            local function walk(tb, d)
                if d > 4 or seen > 40 then return end
                local okP, pairsList = pcall(function() return pairs(tb) end)
                if not okP then return end
                for k, v in pairsList do
                    if type(v) == "string" then
                        if normAnimId(v) and addDance(tostring(k) .. " @ " .. m.Name, v) then
                            out[#out + 1] = tostring(k) .. " @ " .. m.Name .. "  (" .. v .. ")"
                            seen = seen + 1
                        end
                    elseif type(v) == "table" and d < 4 then
                        walk(v, d + 1)
                    end
                end
            end
            pcall(function() walk(t, 0) end)
        end
    end
end

-- 3) что игра играет прямо сейчас (ловушка на штатные эмоуты)
local function scanPlayingAnims(out, all)
    local ch = LP and LP.Character
    if not ch then return end
    local hum = ch:FindFirstChildOfClass("Humanoid")
    local animator = hum and hum:FindFirstChildOfClass("Animator")
    if not animator then return end
    local ok, tracks = pcall(function() return animator:GetPlayingAnimationTracks() end)
    if not ok or type(tracks) ~= "table" then return end
    for _, t in ipairs(tracks) do
        local a = t.Animation
        if a and a.AnimationId and a.AnimationId ~= "" then
            local nm = string.lower(tostring(t.Name or ""))
            if not MOVE_TRACKS[nm] then
                if addDance(tostring(t.Name or a.Name or "анимация"), a.AnimationId) then
                    out[#out + 1] = string.format("%s  (%s, приоритет %s)",
                        tostring(t.Name or a.Name), a.AnimationId, tostring(t.Priority))
                    if all then
                        print("[BS DANCE] поймали анимацию игры: "
                            .. tostring(t.Name) .. " -> " .. tostring(a.AnimationId))
                    end
                end
            end
        end
    end
end

-- КНОПКА «НАЙТИ ТАНЦЫ В ИГРЕ» + автозапуск при старте.
local function scanDances(silent)
    local out = {}
    scanAnimInstances(out)
    scanModuleIds(out)
    scanPlayingAnims(out, true)
    -- печатаем только имена (ID - в конце), чтобы не забить консоль
    if #out == 0 then
        print("[BS DANCE] анимаций-танцев не найдено. Включи «Спин» или "
            .. "вставь ID в поле вручную.")
    else
        print("[BS DANCE] найдено танцев: " .. #out)
        for i = 1, math.min(#out, 30) do
            print("   " .. i .. ") " .. tostring(out[i]))
        end
        if #out > 30 then print("   ... и ещё " .. (#out - 30)) end
    end
    if not silent then
        notify("Танцы", "Найдено: " .. #out .. ". Обнови список в GUI", 3)
    end
    return out
end

-- СТАРТ/СТОП ТАНЦА
local function restoreLowered()
    for _, t in ipairs(dance.lowered) do
        pcall(function() t.Priority = t.__bsOldPrio end)
    end
    dance.lowered = {}
end

local function stopDance(restore)
    restoreLowered()
    if dance.track then
        local tr = dance.track
        pcall(function() tr:Stop(0.15) end)
        pcall(function() tr:Destroy() end)
    end
    dance.track, dance.anim = nil, nil
    dance.yaw, dance.prevYaw = 0, 0
    -- AutoRotate возвращаем тому гуманоиду, которого трогали (после
    -- респавна это уже другой персонаж)
    if restore and dance.autoRotSaved ~= nil and dance.arHum then
        pcall(function() dance.arHum.AutoRotate = dance.autoRotSaved end)
    end
    dance.autoRotSaved, dance.arHum = nil, nil
end

local function startDance(silent)
    stopDance(true)
    if not (dance.id and dance.label ~= "") then
        -- ассет не выбран - работают только спин/покачивание
        return true
    end
    local ch = LP and LP.Character
    if not ch then
        if not silent then notify("Танец", "Нет персонажа") end
        return false
    end
    local hum = ch:FindFirstChildOfClass("Humanoid")
    if not hum then return false end
    local animator = hum:FindFirstChildOfClass("Animator")
    if not animator then
        if not silent then notify("Танец", "У персонажа нет Animator") end
        return false
    end
    if hum.Health <= 0 then return false end
    dance.animator = animator
    local anim = Instance.new("Animation")
    anim.AnimationId = "rbxassetid://" .. dance.id
    local ok, tr = pcall(function() return animator:LoadAnimation(anim) end)
    if not ok or not tr then
        print("[BS DANCE] LoadAnimation не удался: " .. tostring(tr))
        return false
    end
    tr.Looped  = true
    tr.Priority = Enum.AnimationPriority.Action4
    -- ПОХОДКА МОЖЕТ БЫТЬ НА Core (127) - это выше Action4, и тогда
    -- она перебьёт танец. Опускаем такие треки до Action2 и потом
    -- возвращаем обратно при остановке танца.
    pcall(function()
        for _, t in ipairs(animator:GetPlayingAnimationTracks()) do
            if t ~= tr and t.Priority.Value >= CORE_P then
                t.__bsOldPrio = t.Priority
                t.Priority = Enum.AnimationPriority.Action2
                dance.lowered[#dance.lowered + 1] = t
            end
        end
    end)
    pcall(function() tr:Play(0.25) end)
    dance.track, dance.anim = tr, anim
    -- ассет может не принадлежать игре - тогда трек молча не пойдёт
    task.delay(0.7, function()
        local playing = false
        pcall(function() playing = (dance.track == tr) and tr.IsPlaying end)
        if not playing then
            print("[BS DANCE] анимация «" .. tostring(dance.label) .. "» НЕ "
                .. "запустилась: скорее всего ассет не принадлежит этой игре. "
                .. "Возьми любой из списка «Спин»/«Покачивание» или свой ID.")
        end
    end)
    return true
end

local function setDance(on, silent)
    dance.on = on and true or false
    G.BS.DanceOn = dance.on
    if dance.on then
        dance.yaw, dance.prevYaw = 0, 0
        startDance(silent)
    else
        stopDance(true)
    end
end

local function pickDance(label)
    dance.label = tostring(label or "")
    -- ID лежит в DANCE_BY_NAME по названию (если имя повторяется с
    -- разными ассетами - берём первый).
    dance.id = DANCE_BY_NAME[dance.label]
    if dance.on then startDance(true) end
end

-- КАЖДЫЙ КАДР: ассетный трек сам играет, а спин/покачивание крутим
-- сами через PivotTo (дельта угла, чтобы не сбивать направление).
-- КАЖДЫЙ КАДР: ассетный трек сам играет, а спин/покачивание крутим
-- сами через PivotTo (дельта угла, чтобы не сбивать направление).
-- Если включён «спринт», модель доворачивается по направлению движения:
-- это боевой вариант (спин-стрейф), а не походка боком.
local function sprintTick(now)
    if not G.BS.Sprint then return end
    local ch = LP and LP.Character
    if not ch or not ch.Parent then return end
    local hum = ch:FindFirstChildOfClass("Humanoid")
    local root = ch:FindFirstChild("HumanoidRootPart")
    if not (hum and root) then return end
    if hum.Health <= 0 then return end
    if not root:IsDescendantOf(workspace) then return end
    local vel = root.AssemblyLinearVelocity
    local flat = Vector3.new(vel.X, 0, vel.Z)
    if flat.Magnitude < (tonumber(G.BS.SprintSpeed) or 1) then return end
    local look = flat.Unit
    local cur = root.CFrame.LookVector
    local flatCur = Vector3.new(cur.X, 0, cur.Z)
    if flatCur.Magnitude < 0.1 then return end
    local dot = flatCur.Unit:Dot(look)
    if dot >= 0.9995 then return end       -- уже смотрит куда надо
    local ang = math.acos(dot > 1 and 1 or (dot < -1 and -1 or dot))
    local step = ang * (1 - math.exp(-(tonumber(G.BS.SprintTurn) or 10) * 0.016))
    if step <= 0.0005 then return end
    local yaw = CFrame.Angles(0, step, 0)
    pcall(function()
        local piv = ch:GetPivot()
        ch:PivotTo(CFrame.new(piv.Position) * yaw * piv.Rotation)
    end)
end

local function danceTick(dt, now)
    if not dance.on then return end
    if not (dance.spin or dance.sway) then return end
    local ch = LP and LP.Character
    if not ch or not ch.Parent then return end
    local hum = ch:FindFirstChildOfClass("Humanoid")
    if hum and hum.Health <= 0 then return end
    if hum then
        -- без AutoRotate = false гуманоид каждый кадр доворачивает
        -- персонажа по вектору движения и спин не виден
        if dance.autoRotSaved == nil or dance.arHum ~= hum then
            if dance.arHum and dance.autoRotSaved ~= nil
               and dance.arHum.Parent then
                pcall(function() dance.arHum.AutoRotate = dance.autoRotSaved end)
            end
            dance.autoRotSaved = hum.AutoRotate
            dance.arHum = hum
        end
        pcall(function() hum.AutoRotate = false end)
    end
    local yaw
    if dance.sway and not dance.spin then
        yaw = math.rad(dance.swayAmp) * math.sin(now * dance.swaySpeed)
    elseif dance.spin and dance.sway then
        yaw = dance.yaw + math.rad(dance.swayAmp) * math.sin(now * dance.swaySpeed)
    elseif dance.spin then
        yaw = dance.yaw + dance.spinSpeed * dt
    else
        return
    end
    local d = yaw - dance.prevYaw
    dance.prevYaw = yaw
    if math.abs(d) < 0.000001 then return end
    pcall(function()
        local piv = ch:GetPivot()
        ch:PivotTo(CFrame.new(piv.Position)
            * CFrame.Angles(0, d, 0) * piv.Rotation)
    end)
end

-- КЛАВИША (по умолчанию F7) - включает/выключает танец, чтобы не
-- лазить в GUI на ходу. UIS объявлен ниже по файлу, поэтому здесь
-- берём сервис напрямую.
local connDanceKey = nil
local function hookDanceKey()
    if connDanceKey then pcall(function() connDanceKey:Disconnect() end) end
    connDanceKey = nil
    if G.BS.DanceHotkey == false then return end
    local okUIS, uis = pcall(function() return game:GetService("UserInputService") end)
    if not okUIS or not uis then return end
    connDanceKey = uis.InputBegan:Connect(function(k, gpe)
        if gpe or not dance.hotkey then return end
        local code
        pcall(function() code = Enum.KeyCode[dance.hotkey] end)
        if code and k and k.KeyCode == code then setDance(not dance.on) end
    end)
end

-- ============================================================
--  ОСОБЫЕ РОЛИ ПО ПРЕДМЕТУ В РУКАХ
-- ============================================================
-- В конфиге игры прямо прописано:
--   Config.Roles.ROLE_TOOL_MODEL = { Doctor = Medkit, Merchant = Garlic,
--     Priest = HolyCross, Detective = MagnifyingGlass, Seer = SeerStaff,
--     ArmsDealer = SupplyCrate }
-- Предмет в руках надёжно выдаёт особую роль. Плюс дубинка/когти —
-- только у вампиров (у остальных Baton лежит в кобуре моделью, а не
-- экипированным Tool).
local TOOL_ROLE = {
    ["medkit"]         = "doctor",
    ["magnifying glass"] = "detective",
    ["seerstaff"]      = "seer",
    ["holycross"]      = "priest",
    ["garlic"]         = "merchant",
    ["supplycrate"]    = "armsdealer",
    ["baton"]          = "vampire",
    ["claw"]           = "vampire",
}

local function roleFromTool(plr)
    local ch = plr and plr.Character
    if not ch then return nil end
    local tool = ch:FindFirstChildOfClass("Tool")
    if not tool then return nil end
    local r = TOOL_ROLE[string.lower(tostring(tool.Name))]
    if r then return r end
    return nil
end

-- ============================================================
--  СТАТУС ЦЕЛИ: сбит / раскрыт / оглушён / разоружён
-- ============================================================
-- В игре у персонажа несколько состояний, и они решают всё:
--   * Сбит (Downed) — HP ещё есть, но враг лежит: можно добивать;
--   * Раскрыт (Revealed) — вампира уже открыли, самое время стрелять;
--   * Оглушён (Stunned) — тайзер, цель стоит;
--   * Разоружён (DisarmedUntil, модуль Disarm) — стрелять нечем.
-- Берём из атрибутов, а «Сбит» - из модуля PlayerState
-- (PlayerState.DOWNED / ALIVE / DEAD / GONE / BODYLESS).
local PS_MOD = nil        -- require(ReplicatedStorage.BloodyStreet.PlayerState)
local function loadPlayerState()
    if PS_MOD ~= nil then return PS_MOD end
    pcall(function()
        PS_MOD = require(game:GetService("ReplicatedStorage")
            .BloodyStreet.PlayerState)
    end)
    if PS_MOD == nil then PS_MOD = false end
    return PS_MOD
end

local function playerStatus(plr)
    local ch = plr and plr.Character
    if not ch or not ch.Parent then return nil end
    local hum = ch:FindFirstChildOfClass("Humanoid")
    if not hum then return nil end
    if hum.Health <= 0 then return "Мёртв", 0 end
    local now = os.time()
    local st, pri = nil, 9
    pcall(function()
        local r = plr:GetAttribute("RevealedUntil")
        if type(r) == "number" and r > now then st, pri = "Раскрыт", 1 end
        local s = plr:GetAttribute("StunnedUntil")
        if type(s) == "number" and s > now and pri > 2 then st, pri = "Оглушён", 2 end
        local b = plr:GetAttribute("BloodyUntil")
        if type(b) == "number" and b > now and pri > 3 then st, pri = "Истекает", 3 end
        local d = plr:GetAttribute("DisarmedUntil")
        if type(d) == "number" and d > now and pri > 4 then st, pri = "Разоружён", 4 end
    end)
    if st == nil then
        local ps = loadPlayerState()
        if ps then
            pcall(function()
                local s = ps.of(plr)
                if s == "Downed" then st, pri = "Сбит", 2
                elseif s == "Gone" then st, pri = "Пропал", 5
                elseif s == "Bodyless" then st, pri = "Без тела", 5 end
            end)
        end
    end
    return st, pri
end

-- ============================================================
--  ХИТМАРКЕР: подтверждение попадания
-- ============================================================
-- Урон приходит с сервера (DamagePopup / CombatFeed) - значит можно
-- показать метку в центре экрана в момент реального попадания. Раньше
-- приходилось считать проценты по логу; теперь видно сразу, попал
-- конкретный выстрел или нет.
updateHitMark = function(now)
    if not G.BS.HitMark then
        for i = 1, #hitLines do hitLines[i].Visible = false end
        return
    end
    if #hitLines == 0 then
        if not DRAW_OK then return end
        for i = 1, 4 do
            local ok, d = pcall(function() return Drawing.new("Line") end)
            if not ok or not d then return end
            d.Thickness = 2
            d.Visible = false
            hitLines[i] = d
        end
    end
    local cam = workspace.CurrentCamera
    if not cam then return end
    local age = now - hitMarkAt
    local life = tonumber(G.BS.HitMarkLife) or 0.25
    if hitMarkAt <= 0 or age > life then
        for i = 1, #hitLines do hitLines[i].Visible = false end
        return
    end
    local vp = cam.ViewportSize
    local cx, cy = vp.X * 0.5, vp.Y * 0.5
    local k = 1 - age / life
    local r0, r1 = 4 + (1 - k) * 4, 12 + (1 - k) * 8
    local col = safeColor(G.BS.HitMarkColor, Color3.new(1, 0.25, 0.25))
    for i = 1, 4 do
        local sx = (i == 1 or i == 4) and 1 or -1
        local sy = (i == 1 or i == 2) and 1 or -1
        local l = hitLines[i]
        l.From = Vector2.new(cx + sx * r0, cy + sy * r0)
        l.To   = Vector2.new(cx + sx * r1, cy + sy * r1)
        l.Color = col
        l.Transparency = (1 - k) * 0.4
        l.Visible = true
    end
end

-- ============================================================
--  ЛЕНТА СОБЫТИЙ
-- ============================================================
-- Раунд, разоблачения, смерти, попадания - короткой строкой в GUI.
-- Раньше это было только в консоли и терялось.
addEvent = function(text)
    if type(text) ~= "string" or text == "" then return end
    EVENTS[#EVENTS + 1] = os.clock() .. "|" .. string.sub(text, 1, 90)
    while #EVENTS > 8 do table.remove(EVENTS, 1) end
    print("[BS EVT] " .. text)
end

local lastEventsDraw = 0
updateEvents = function(now)
    if not G.BS.EventsOn then
        if eventsLabel then eventsLabel.Visible = false end
        return
    end
    if now - lastEventsDraw < 0.25 then return end
    lastEventsDraw = now
    if not ensureHud() then return end
    if not eventsLabel then
        local ok, t = pcall(function()
            local x = Instance.new("TextLabel")
            x.Name = "BS_Events"
            x.BackgroundTransparency = 1
            x.Size = UDim2.fromOffset(560, 92)
            x.Position = UDim2.new(0, 10, 0, 30)
            x.Font = Enum.Font.Code
            x.TextSize = 12
            x.TextColor3 = Color3.new(0.85, 0.9, 1)
            x.TextXAlignment = Enum.TextXAlignment.Left
            x.TextYAlignment = Enum.TextYAlignment.Top
            x.TextWrapped = true
            x.Parent = hudGui
            return x
        end)
        if not ok or not t then return end
        eventsLabel = t
    end
    local lines = {}
    for i = 1, #EVENTS do
        local p = string.find(EVENTS[i], "|", 1, true)
        if p then lines[#lines + 1] = string.sub(EVENTS[i], p + 1) end
    end
    eventsLabel.Text = table.concat(lines, "\n")
    eventsLabel.Visible = true
end

-- ============================================================
--  БЕЗ КУЛДАУНА ОРУЖИЯ (вместо «бесконечных патронов»)
-- ============================================================
-- ПРО «бесконечные патроны»: это чисто клиентский счётчик, сервер
-- ведёт СВОЙ учёт и всё равно не засчитывает выстрел. Проверено на
-- игре: патроны в клиенте можно держать полными сколько угодно,
-- сервер всё равно блокирует выстрел. Поэтому эту фичу убрали.
--
-- ЧТО ДЕЙСТВИТЕЛЬНО БЛОКИРУЕТ СТРЕЛЬБУ - кулдаун. В конфиге игры:
--   Config.Combat.WEAPON_COOLDOWN      = 0.30  (секунды между выстрелами)
--   Config.Combat.GUN_DRY_FIRE_GAP     = 0.25
--   Config.Combat.SHOT_FIRE_JITTER     = 0.10
--   Config.Combat.GUN_RECOIL_RECOVER   = 0.25..0.5 (по оружию)
--   Config.Combat.SHOT_MAX_REWIND      = 0.50
--   Config.Combat.SHOT_HISTORY_SECONDS = 1.00
-- Клиентский код смотрит на ReadyAt/Cooldown-атрибут оружия (у самой
-- игры это ToolCooldown.ATTR: LuminolReadyAt, StunGunReadyAt, ...), и
-- пока время в будущем - кнопка не стреляет. Поэтому держим эти
-- метки в прошлом: оружие всегда готово, WEAPON_COOLDOWN не мешает.
--
-- Сам кулдаун тоже можно обойти на уровне ремоута: игра шлёт
-- FireWeapon(origin, dir, seed, data, time). Если подменить
-- последний аргумент (время выстрела) на ВРЕМЯ СРАЗУ ПОСЛЕ
-- предыдущего выстрела, сервер посчитает, что прошло больше
-- WEAPON_COOLDOWN, даже если реально стреляли чаще.
local cdDumpDone = false
local function looksLikeCooldown(name)
    local n = string.lower(tostring(name or ""))
    return string.find(n, "ready", 1, true) ~= nil
        or string.find(n, "cooldown", 1, true) ~= nil
        or string.find(n, "until", 1, true) ~= nil
        or string.find(n, "next", 1, true) ~= nil
        or string.find(n, "reload", 1, true) ~= nil
        or string.find(n, "fire", 1, true) ~= nil
end

local function clearWeaponCooldown(quiet)
    local ch = LP and LP.Character
    if not ch then return end
    local tool = ch:FindFirstChildOfClass("Tool")
    if not tool then return end
    local okA, attrs = pcall(function() return tool:GetAttributes() end)
    if not (okA and type(attrs) == "table") then return end
    local list = {}
    for k in pairs(attrs) do list[#list + 1] = k end
    table.sort(list)

    if not cdDumpDone and not quiet then
        cdDumpDone = true
        local parts = {}
        for _, k in ipairs(list) do
            parts[#parts + 1] = k .. "=" .. tostring(attrs[k])
        end
        print("[BS CD] оружие " .. tostring(tool.Name) .. ": "
            .. (#parts > 0 and table.concat(parts, ", ") or "(атрибутов нет)"))
    end
    if not G.BS.NoCooldown then return end
    for _, k in ipairs(list) do
        local v = attrs[k]
        if type(v) == "number" and v > 1000000000 and looksLikeCooldown(k) then
            -- это заведомо метка времени «будущее» (os.time-подобная)
            pcall(function() tool:SetAttribute(k, 0) end)
        end
    end
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
        -- ОСОБАЯ РОЛЬ ПО ПРЕДМЕТУ: Medkit = доктор, Baton = вампир...
        local spRole = roleFromTool(plr)
        if spRole then
            print(string.format("      в руках особая роль: %s",
                tostring(ROLE_NAME[spRole] or spRole)))
        end
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

-- СПИСОК ЦЕЛЕЙ, ОТСОРТИРОВАННЫЙ ПО ЭКРАНУ. Именно он выбирается
    -- и для подмены патрона (хук), и для аимлока, и для точки
    -- прицела. Раньше каждая из этих вещей решала «какая цель»
    -- по-своему, из-за чего аимлок смотрел на одного, а патрон летел
    -- в другого - и всё выглядело сломанным.
-- (объявлены выше, в блоке состояния - ими пользуется и pickTarget)

local function buildList(cam, myRoot)
    bulletList = {}
    local vp = cam.ViewportSize
    local ccx, ccy = vp.X * 0.5, vp.Y * 0.5
    local maxD = tonumber(G.BS.AimMaxDist) or 0
    for _, plr in ipairs(Players:GetPlayers()) do
        if plr ~= LP and by[plr] and isEnemy(plr) then
            local ch = plr.Character
            local hum = ch and ch:FindFirstChildOfClass("Humanoid")
            if ch and ch.Parent and hum and hum.Health > 0 then
                local q = pickPartOf(ch)
                if q then
                    local d = (q.Position - myRoot.Position).Magnitude
                    if maxD <= 0 or d <= maxD then
                        local scr = 1e9
                        pcall(function()
                            local sp = cam:WorldToViewportPoint(q.Position)
                            if sp.Z > 0 then
                                local dx, dy = sp.X - ccx, sp.Y - ccy
                                scr = math.sqrt(dx * dx + dy * dy)
                            end
                        end)
                        bulletList[#bulletList + 1] = {
                            part = q, char = ch, player = plr,
                            dist = d, screen = scr,
                        }
                    end
                end
            end
        end
    end
    table.sort(bulletList, function(a, b)
        if a.screen ~= b.screen then return a.screen < b.screen end
        return a.dist < b.dist
    end)
end

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

    -- ПРИОРИТЕТ ЦЕЛИ: строим общий список (buildList) и берём из него
    -- первую цель по экранному расстоянию. Список нужен ещё и хуку
    -- (подмена патрона), и аимлоку - раньше у каждого была своя
    -- логика выбора, из-за чего они целились в разных людей.
    local CONE = math.max(220, math.floor(cam.ViewportSize.Y * 0.35))
    local CONE2 = CONE * CONE
    buildList(cam, myRoot)

    -- первая цель в широком конусе, иначе просто первая в списке
    local best, bestChar
    for _, it in ipairs(bulletList) do
        if it.screen <= CONE2 then
            best, bestChar = it.part, it.char
            break
        end
    end
    if not best then
        local first = bulletList[1]
        if first then best, bestChar = first.part, first.char end
    end
    bulletListTarget = best

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
        onScreen = true,  -- цель выбирается всегда (триггер удалён)
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

-- ПРИЦЕЛ С ЦЕЛЬЮ. Пока держим ЛКМ - держим ту же цель, даже если
-- она отошла из-под прицела: иначе взгляд постоянно «соскакивает» на
-- того, кто случайно ближе к центру экрана (тот же враг сбоку, второй
-- враг и т.п.) - аимлок выглядел мигающим: «чуть повернул камеру и
-- он слетел».
local LOCK_TARGET = nil          -- Part (BOS)
local LOCK_LAST_S, LOCK_UNTIL = nil, 0

local function dropLock()
    LOCK_TARGET, LOCK_LAST_S = nil, nil
end

local function pointScore(pos)
    -- насколько точка близка к центру экрана (меньше - лучше)
    local cam = workspace.CurrentCamera
    if not cam then return 1e9 end
    local vp = cam.ViewportSize
    local sp = cam:WorldToViewportPoint(pos)
    if sp.Z <= 0 then return 1e9 end
    local dx, dy = sp.X - vp.X * 0.5, sp.Y - vp.Y * 0.5
    return math.sqrt(dx * dx + dy * dy)
end

local function resolveLock(cam, now)
    local pre = bulletPreShot
    if not (pre and pre.pos) then dropLock() return end
    local camPos
    local okC, p = pcall(function() return cam.CFrame.Position end)
    if not okC then return end
    camPos = p
    local mouseDown = false
    pcall(function()
        mouseDown = UIS:IsMouseButtonPressed(Enum.UserInputType.MouseButton1)
    end)
    -- старая цель ещё жива и не улетела с экрана?
    local stillThere = false
    if LOCK_TARGET and LOCK_TARGET.Parent then
        local d = (LOCK_TARGET.Position - camPos).Magnitude
        if G.BS.AimMaxDist <= 0 or d <= G.BS.AimMaxDist then
            stillThere = pointScore(LOCK_TARGET.Position) <= (LOCK_LAST_S or 0) + 40
        end
    end
    local held = LOCK_TARGET and LOCK_TARGET.Parent and LOCK_UNTIL > now
    if held and ((mouseDown and G.BS.LockHoldOnFire ~= false) or stillThere) then return end
    -- выбираем новую цель
    dropLock()
    LOCK_UNTIL = now + (tonumber(G.BS.LockHold) or 0.6)
    if not (pre.part and pre.part.Parent) then return end
    local d = (pre.part.Position - camPos).Magnitude
    if G.BS.AimMaxDist > 0 and d > G.BS.AimMaxDist then return end
    LOCK_TARGET = pre.part
    LOCK_LAST_S = pointScore(pre.part.Position)
end

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
    if not (G.BS.AimLock and pre and pre.pos) then dropLock() return end
    if not refreshGunFlag(now) then dropLock() return end
    if G.BS.AimLockFireOnly then
        local okP, down = pcall(function()
            return UIS:IsMouseButtonPressed(Enum.UserInputType.MouseButton1)
        end)
        if not (okP and down) then return end
    end

    local cam = workspace.CurrentCamera
    if not cam then return end
    -- ЦЕЛЬ АИМЛОКА. По умолчанию - реальная точка удара (pre.pos):
    -- она уже с опережением и с учётом свободной части тела.
    -- Если включена «только цель из списка», берём именно её часть -
    -- тогда аимлок, подмена патрона и точка прицела всегда про одну
    -- цель и не расходятся между собой.
    local tgt = pre.part
    if G.BS.AimLockListTarget and bulletListTarget and bulletListTarget.Parent
       and bulletListTarget:IsA("BasePart") then
        tgt = bulletListTarget
    end
    resolveLock(cam, now)
    if LOCK_TARGET and LOCK_TARGET.Parent then tgt = LOCK_TARGET end
    if not (tgt and tgt.Parent) then dropLock() return end

    local cf = cam.CFrame
    local pos = cf.Position
    local look = pre.pos
    local toT = look - pos
    if toT.Magnitude < 0.5 then return end

    -- НЕ ДОВОДИМ КАМЕРУ СКВОЗЬ СТЕНЫ (по просьбе): если между нами и
    -- целью стена - взгляд остаётся твоим.
    if G.BS.AimLockNoWall then
        local blocked = false
        pcall(function()
            AIMLOCKRAY.FilterDescendantsInstances = { LP.Character, tgt.Parent }
            local hit = workspace:Raycast(pos, toT, AIMLOCKRAY)
            if hit and hit.Distance < toT.Magnitude - 1.2 then blocked = true end
        end)
        if blocked then return end
    end

    local target = CFrame.lookAt(pos, look, cf.UpVector)

    -- ДОВОРОТ. По умолчанию МГНОВЕННЫЙ (доля 1), и это не «крутая
    -- опция», а требование сервера: Config.Combat.SHOT_ANGLE_SLACK_DEG
    -- = 3, то есть взгляд и патрон должны совпадать в пределах 3°.
    -- Плавный LerCFrame как раз и давал жалобу «иду вперёд - аимлок
    -- тянет назад»: каждый кадр камера недодоводила, и на ходу взгляд
    -- оставался ПОЗАДИ цели. Ползунок скорости уменьшает доворот
    -- только осознанно: 1 = мгновенно, 0 = не доворачивать, 0.3 = плавно.
    local sp = tonumber(G.BS.AimLockSpeed)
    if sp == nil then sp = 1.0 end
    local frac
    if sp <= 0 then
        frac = 0
    elseif sp >= 1 then
        frac = 1
    else
        local dist = toT.Magnitude
        frac = sp * (1 - (dist / 400) * 0.5)
        if frac < 0.02 then frac = 0.02 end
        if frac > 1 then frac = 1 end
    end
    if frac <= 0 then return end
    if frac >= 1 then
        cam.CFrame = target
        return
    end
    -- Плавный режим: сглаживание по ВРЕМЕНИ, а не по кадрам, чтобы
    -- скорость не зависела от FPS.
    local k = 1 - math.exp(-frac / math.max(dt or 0.016, 0.001))
    if k > 1 then k = 1 end
    cam.CFrame = cf:Lerp(target, k)
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

    -- ПЕРЕСЧЁТ ТОЧКИ ПРИЦЕЛА В МОМЕНТ ВЫСТРЕЛА. pre.pos посчитан в
    -- начале кадра, а пока мы шли вперёд, камера (и точка вылета,
    -- которую игра передаёт аргументом №1) уже сдвинулась. Разница
    -- небольшая, но именно из-за неё пуля уходила чуть НАЗАД - «аймлок
    -- отставал». Поэтому здесь цель и опережение считаются заново, по
    -- актуальной позиции цели.
    -- Внутри хука ":"-вызовы запрещены, поэтому только свойства.
    local tgtPart = LOCK_TARGET or bulletListTarget
    if tgtPart and tgtPart.Parent then
        local p = tgtPart.Position
        local vel = tgtPart.AssemblyLinearVelocity
        if vel and (vel.X * vel.X + vel.Y * vel.Y + vel.Z * vel.Z) > 1 then
            local lead = tonumber(G.BS.AimLead) or 0
            if lead > 0 then
                local ox, oy, oz = vel.X * lead, vel.Y * lead, vel.Z * lead
                local m = math.sqrt(ox * ox + oy * oy + oz * oz)
                if m > 2.5 then
                    local s = 2.5 / m
                    ox, oy, oz = ox * s, oy * s, oz * s
                end
                p = p + Vector3.new(ox, oy, oz)
            end
        end
        local from = (posIdx and typeof(out[posIdx]) == "Vector3") and out[posIdx] or pre.src
        if from then
            local dx, dy, dz = p.X - from.X, p.Y - from.Y, p.Z - from.Z
            local d = math.sqrt(dx * dx + dy * dy + dz * dz)
            if d > 0.001 then
                aimDir  = Vector3.new(dx / d, dy / d, dz / d)
                aimDist = d
            end
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

    -- 4) ОБХОД КУЛДАУНА ЧЕРЕЗ ВРЕМЯ ВЫСТРЕЛА.
    -- FireWeapon(origin, dir, seed, data, time). Сервер сверяет `time`
    -- с записью о последнем выстреле и режет, если прошло меньше
    -- Config.Combat.WEAPON_COOLDOWN = 0.3 c (плюс SHOT_FIRE_JITTER).
    -- Если отдать время = "предыдущий выстрел + WEAPON_COOLDOWN + 0.2",
    -- сервер посчитает, что интервал выдержан, даже если мы стреляли
    -- быстрее. Правдоподобно и без резких скачков: подвигали время
    -- вперёд, как будто выстрел случился чуть позже.
    if G.BS.ShotTimeHack then
        local step = tonumber(G.BS.ShotTimeStep)
        if step == nil then step = 0.55 end
        local last = NC.lastShotT or 0
        for i = n, 1, -1 do
            local t = typeof(out[i])
            if t == "number" and i >= 2 and out[i] > 1000 then
                -- похоже на os.time/workspace:GetServerTimeNow (секунды)
                NC.lastShotT = last
                out[i] = out[i] + step
                bits[#bits + 1] = "время выстрела #" .. tostring(i)
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
                .. "getgenv().BS.AimLockSpeed = 35  2) дальность "
                .. "getgenv().BS.AimMaxDist = 150  3) опережение "
                .. "getgenv().BS.AimLead = 0.15")
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
-- ГЛУБОКИЙ РЕЖИМ (DeepRemoteLog): печатает ВСЕ 94 ремоута без
-- ограничения по числу вызовов и разбирает вложенные таблицы. Именно
-- он нужен, чтобы найти, какими ДАННЫМИ сервер рисует урон
-- (CombatFeed / DamagePopup / DetectionFeed), ставит метку попадания
-- (HIT_MARK) и различает хантера/вампира в Mystery.
-- (dumpArgs объявлен выше, рядом с incomingSeen, и заполняется тут)
dumpArgs = function(v, depth)
    if depth > 2 then return "{...}" end
    local parts = {}
    local n = 0
    pcall(function()
        for k, x in pairs(v) do
            n = n + 1
            if n > 12 then break end
            local t = typeof(x)
            local s
            if t == "string" or t == "number" or t == "boolean" then
                s = tostring(x)
            elseif t == "Vector3" then
                s = string.format("%.1f, %.1f, %.1f", x.X, x.Y, x.Z)
            elseif t == "EnumItem" then
                s = tostring(x.Name)
            elseif t == "Instance" or t == "Player" then
                s = tostring(x.Name)
            elseif t == "table" then
                s = dumpArgs(x, depth + 1)
            end
            if s then
                parts[#parts + 1] = tostring(k) .. "=" .. s
            else
                parts[#parts + 1] = tostring(k) .. "=" .. t
            end
        end
    end)
    return "{" .. table.concat(parts, ", ") .. "}"
end

local logSeen = {}
local function logRemoteCall(self, method, ...)
    local name = "?"
    if typeof(self) == "Instance" then
        name = tostring(self.Name)
        local p = self.Parent
        if p then name = name .. "@" .. tostring(p.Name) end
    end
    local key = name .. "." .. tostring(method)
    local deep = G.BS.DeepRemoteLog == true
    if not deep then
        local c = logSeen[key] or 0
        if c >= 2 then return end
        logSeen[key] = c + 1
    end

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
        elseif t == "EnumItem" then
            v = tostring(a.Name)
        elseif t == "table" and deep then
            v = dumpArgs(a, 1)
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
                -- ОСОБАЯ РОЛЬ ПО ПРЕДМЕТУ (раз в секунду, вместе со
                -- сканом): предмет в руках - надёжный признак роли.
                if G.BS.ShowSpecialRole then
                    local e2 = by[plr]
                    if e2 then e2.special = roleFromTool(plr) end
                end
                -- СТАТУС ЦЕЛИ (раз в секунду): сбит / раскрыт /
                -- оглушён / разоружён. По нему видно, кого можно
                -- добивать, а кого не стоит трогать.
                if G.BS.ShowStatus then
                    local e3 = by[plr]
                    if e3 then
                        local st = playerStatus(plr)
                        e3.status = st
                    end
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

    -- хитмаркер (подтверждение попадания) + лента событий
    pcall(updateHitMark, now)
    pcall(updateEvents, now)

    -- звуковые метки: радар шума (выстрелы, крики)
    pcall(updateNoiseMarks)

    -- танец на ходьбе + спин/покачивание (модель крутим сами)
    pcall(danceTick, dt, now)
    -- боевой спринт: разворачиваем модель по направлению бега
    pcall(sprintTick, now)

    -- раз в 4 с ловим анимации, которые игра играет на персонаже:
    -- если станцевать штатным эмоутом, его ID попадёт в список
    if G.BS.DanceAutoScan and now - dance.scanAt > 4 then
        dance.scanAt = now
        pcall(function() scanPlayingAnims({}, false) end)
    end

    -- снятие кулдауна оружия (метки готовности держим в прошлом)
    if G.BS.NoCooldown and now - lastAmmo >= 0.1 then
        lastAmmo = now
        pcall(clearWeaponCooldown, true)
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

    -- HUD: роль / фаза / патроны / цель (внутри — обновление раз в 0.2 с)
    pcall(updateHud, now)

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
                -- ОСОБАЯ РОЛЬ ПО ПРЕДМЕТУ: Medkit = доктор,
                -- MagnifyingGlass = детектив, Baton = вампир и т.д.
                if G.BS.ShowSpecialRole and e.special then
                    parts[#parts + 1] = ROLE_NAME[e.special] or e.special
                end
                -- СТАТУС: сбит / раскрыт / оглушён. Помечаем ярким -
                -- сбитого можно добивать, раскрытого надо убить сразу.
                if G.BS.ShowStatus and e.status then
                    parts[#parts + 1] = "[" .. tostring(e.status) .. "]"
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
    LoadingSubtitle = "ESP + Aim + Танец v11.9",
    ConfigurationSaving = { Enabled = true },
})

local TAB  = Window:CreateTab("ESP", 4483362458)
local AIMT = Window:CreateTab("AIM", 1101060692)
local DNC  = Window:CreateTab("ТАНЕЦ", 1183774348)

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
local DN = mkTab(DNC,  "ТАНЕЦ")

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
    Name = "Без кулдауна оружия", Flag = "BS_NoCooldown",
    CurrentValue = G.BS.NoCooldown,
    Callback = function(v)
        G.BS.NoCooldown = v
        cdDumpDone = false   -- пусть напечатает актуальные атрибуты
        pcall(clearWeaponCooldown, false)
    end,
})
TB.CreateButton({ Name = "Показать метки кулдауна (в консоль)",
    Callback = function()
        cdDumpDone = false
        pcall(clearWeaponCooldown, false)
        notify("Метки кулдауна — смотри [BS CD] в консоли", 4)
    end })
TB.CreateToggle({
    Name = "Время выстрела сдвигать вперёд (обход WEAPON_COOLDOWN)",
    Flag = "BS_ShotTimeHack",
    CurrentValue = G.BS.ShotTimeHack,
    Callback = function(v) G.BS.ShotTimeHack = v end,
})
TB.CreateSlider({ Name = "Сдвиг времени выстрела", Flag = "BS_ShotTimeStep",
    Range = {0.1, 2}, Increment = 0.05,
    CurrentValue = tonumber(G.BS.ShotTimeStep) or 0.55,
    Suffix = " c",
    Callback = function(v) G.BS.ShotTimeStep = v end })
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

TB.CreateToggle({ Name = "Звуковые метки (где стреляли/кричали)", Flag = "BS_NoiseMarks",
    CurrentValue = G.BS.NoiseMarks,
    Callback = function(v) G.BS.NoiseMarks = v end })
TB.CreateToggle({ Name = "Особая роль по предмету в подписи", Flag = "BS_ShowSpecialRole",
    CurrentValue = G.BS.ShowSpecialRole,
    Callback = function(v) G.BS.ShowSpecialRole = v end })
TB.CreateToggle({ Name = "HUD (роль, фаза, патроны, цель)", Flag = "BS_Hud",
    CurrentValue = G.BS.Hud,
    Callback = function(v)
        G.BS.Hud = v
        if not v and hudLabel then hudLabel.Visible = false end
    end })
TB.CreateToggle({ Name = "Статус цели (сбит/раскрыт/оглушён)", Flag = "BS_ShowStatus",
    CurrentValue = G.BS.ShowStatus,
    Callback = function(v) G.BS.ShowStatus = v end })
TB.CreateToggle({ Name = "Хитмаркер при попадании", Flag = "BS_HitMark",
    CurrentValue = G.BS.HitMark,
    Callback = function(v) G.BS.HitMark = v end })
TB.CreateColorPicker({ Name = "Цвет хитмаркера", Flag = "BS_HitMarkColor",
    Color = G.BS.HitMarkColor,
    Callback = function(c) G.BS.HitMarkColor = c end })
TB.CreateToggle({ Name = "Лента событий (раунд/разоблачения)", Flag = "BS_EventsOn",
    CurrentValue = G.BS.EventsOn,
    Callback = function(v)
        G.BS.EventsOn = v
        if not v and eventsLabel then eventsLabel.Visible = false end
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
    Name = "Аимлок только пока держишь огонь", Flag = "BS_AimLockFireOnly",
    CurrentValue = G.BS.AimLockFireOnly,
    Callback = function(v) G.BS.AimLockFireOnly = v end,
})
AI.CreateSlider({ Name = "Удержание цели (сек)", Flag = "BS_LockHold",
    Range = {0, 5}, Increment = 0.1,
    CurrentValue = tonumber(G.BS.LockHold) or 0.6,
    Suffix = " c",
    Callback = function(v) G.BS.LockHold = v end })
AI.CreateToggle({
    Name = "Держать цель, пока зажат огонь", Flag = "BS_LockHoldOnFire",
    CurrentValue = G.BS.LockHoldOnFire,
    Callback = function(v) G.BS.LockHoldOnFire = v end,
})
AI.CreateToggle({
    Name = "Маркер цели = цели аима", Flag = "BS_SyncTarget",
    CurrentValue = G.BS.SyncTarget,
    Callback = function(v)
        G.BS.SyncTarget = v
        locked = nil
    end,
})
AI.CreateToggle({
    Name = "Аим по цели из списка (без выбора свободной части)", Flag = "BS_AimLockListTarget",
    CurrentValue = G.BS.AimLockListTarget,
    Callback = function(v) G.BS.AimLockListTarget = v end,
})
AI.CreateToggle({
    Name = "Аимлок не наводится сквозь стены", Flag = "BS_AimLockNoWall",
    CurrentValue = G.BS.AimLockNoWall,
    Callback = function(v) G.BS.AimLockNoWall = v end,
})
AI.CreateSlider({ Name = "Плавность доворота (1 = мгновенно)", Flag = "BS_AimLockSpeed",
    Range = {0, 1}, Increment = 0.05,
    CurrentValue = tonumber(G.BS.AimLockSpeed) or 1,
    Suffix = " (0 = выкл)",
    Callback = function(v) G.BS.AimLockSpeed = v end })

AI.CreateSection("Прострел и дальность")
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
            if v then
            notify("Глубокий лог: все ремоуты + входящие события", 5)
        else
            notify("Лог ремоутов включён: постреляй, смотри [BS REMOTE]", 5)
        end
        end
    end,
})

-- ============================================================
--  ТАНЕЦ
-- ============================================================
DN.CreateParagraph({ Name = "Танец играется САМИМ скриптом: свой трек с "
    .. "высоким приоритетом и Looped, поэтому ходьба его не сбивает. "
    .. "Спин и покачивание - наш собственный поворот модели, им не нужны "
    .. "ассеты, работают всегда." })

DN.CreateSection("Танец")
DN.CreateToggle({ Name = "Танцевать", Flag = "BS_DanceOn",
    CurrentValue = G.BS.DanceOn,
    Callback = function(v) pcall(setDance, v) end })

-- Список анимаций: сначала пусто, потом наполняется сканом.
local danceDD = nil
local DANCE_PLACEHOLDER = { "— сначала найди танцы —" }
local function refreshDanceDropdown()
    local opts = {}
    for i = 1, #DANCES do opts[i] = DANCES[i].label end
    if #opts == 0 then opts = DANCE_PLACEHOLDER end
    if danceDD then
        local ok = pcall(function() danceDD:SetOptions(opts) end)
        if not ok then pcall(function() danceDD:AddOptions(opts) end) end
    end
end

danceDD = DN.CreateDropdown({ Name = "Анимация танца", Flag = "BS_DancePick",
    Options = DANCE_PLACEHOLDER,
    CurrentValue = DANCE_PLACEHOLDER[1],
    Callback = function(v) pcall(pickDance, v) end })
refreshDanceDropdown()

DN.CreateButton({ Name = "НАЙТИ ТАНЦЫ В ИГРЕ", Callback = function()
    pcall(function()
        scanDances(false)
        refreshDanceDropdown()
    end)
end })
DN.CreateInput({ Name = "Свой ID (rbxassetid://...)", Flag = "BS_DanceManual",
    Placeholder = "rbxassetid://1234567890",
    Callback = function(txt)
        local s = normAnimId(txt)
        if not s then
            notify("Танец", "Не похоже на ID анимации", 2)
            return
        end
        local lbl = "Мой ID " .. s
        addDance(lbl, s)
        pcall(pickDance, lbl)
        refreshDanceDropdown()
        if dance.on then pcall(startDance, true) end
    end })

DN.CreateSection("Спин и покачивание")
DN.CreateToggle({ Name = "Спин (оборот 360°)", Flag = "BS_Spin",
    CurrentValue = G.BS.Spin,
    Callback = function(v)
        G.BS.Spin = v
        if v then
            dance.spin = true
            if dance.on then pcall(startDance, true) end
        else
            dance.spin = false
        end
    end })
DN.CreateToggle({ Name = "Покачивание", Flag = "BS_Sway",
    CurrentValue = G.BS.Sway,
    Callback = function(v)
        G.BS.Sway = v
        dance.sway = v
    end })
DN.CreateSlider({ Name = "Скорость оборота", Flag = "BS_SpinSpeed",
    Range = {60, 1080}, Increment = 10, CurrentValue = G.BS.SpinSpeed,
    Suffix = " °/с", Callback = function(v)
        G.BS.SpinSpeed = v
        dance.spinSpeed = v
    end })
DN.CreateSlider({ Name = "Размах покачивания", Flag = "BS_SwayAmp",
    Range = {5, 60}, Increment = 1, CurrentValue = G.BS.SwayAmp,
    Suffix = " °", Callback = function(v)
        G.BS.SwayAmp = v
        dance.swayAmp = v
    end })
DN.CreateToggle({ Name = "Клавиша F7 — танец вкл/выкл", Flag = "BS_DanceHotkey",
    CurrentValue = G.BS.DanceHotkey,
    Callback = function(v)
        G.BS.DanceHotkey = v
        if v then
            dance.hotkey = "F7"
            pcall(hookDanceKey)
        else
            pcall(function()
                if connDanceKey then connDanceKey:Disconnect() end
                connDanceKey = nil
            end)
        end
    end })
DN.CreateToggle({ Name = "Ловить танцы, которые игра играет сама", Flag = "BS_DanceAutoScan",
    CurrentValue = G.BS.DanceAutoScan,
    Callback = function(v) G.BS.DanceAutoScan = v end })

DN.CreateSection("Спринт («спин» в бою)")
DN.CreateParagraph({ Name = "Модель доворачивается по направлению бега, "
    .. "поэтому в бою не уезжает боком. Отдельно от танца: работает "
    .. "всегда и не требует ассетов." })
DN.CreateToggle({ Name = "Спинт (поворот по бегу)", Flag = "BS_Sprint",
    CurrentValue = G.BS.Sprint,
    Callback = function(v) G.BS.Sprint = v end })
DN.CreateSlider({ Name = "Порог бега", Flag = "BS_SprintSpeed",
    Range = {0, 10}, Increment = 0.5,
    CurrentValue = tonumber(G.BS.SprintSpeed) or 1,
    Suffix = " studs/c", Callback = function(v) G.BS.SprintSpeed = v end })
DN.CreateSlider({ Name = "Скорость доворота в бегу", Flag = "BS_SprintTurn",
    Range = {2, 30}, Increment = 1,
    CurrentValue = tonumber(G.BS.SprintTurn) or 10,
    Callback = function(v) G.BS.SprintTurn = v end })

AI.CreateToggle({
    Name = "Глубокий лог всех 94 ремоутов + входящие события",
    Flag = "BS_DeepRemoteLog",
    CurrentValue = G.BS.DeepRemoteLog,
    Callback = function(v)
        G.BS.DeepRemoteLog = v
        logSeen = {}
        incomingSeen = {}
        incomingCount = 0
        if v then pcall(installBulletHook) end
    end,
})
AI.CreateSlider({ Name = "Лимит строк входящего лога", Flag = "BS_MaxInLog",
    Range = {50, 2000}, Increment = 50,
    CurrentValue = tonumber(G.BS.MaxInLog) or 400,
    Callback = function(v) G.BS.MaxInLog = v end })

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
    -- звуковые метки и HUD тоже снимаем, иначе останутся висеть
    for i = 1, #noiseRings do pcall(function() noiseRings[i]:Remove() end) end
    for i = 1, #noiseLabels do pcall(function() noiseLabels[i]:Remove() end) end
    noiseRings, noiseLabels = {}, {}
    if hudGui then pcall(function() hudGui:Destroy() end) end
    hudGui, hudLabel, eventsLabel = nil, nil, nil
    for i = 1, #hitLines do pcall(function() hitLines[i]:Remove() end) end
    hitLines = {}
    EVENTS = {}
    -- танец: снимаем свой трек, возвращаем походку и AutoRotate
    pcall(stopDance, true)
    if connDanceKey then pcall(function() connDanceKey:Disconnect() end) end
    connDanceKey = nil
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
    print("[BS HUB] v11.9 остановлен")
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
    -- ТАНЦЫ: ищем анимации игры (Animation-объекты + модули) и
    -- сразу печатаем список в консоль. Сам танец не включаем -
    -- включается галочкой или клавишей F7.
    hookDanceKey()
    if G.BS.DanceAutoScan then
        task.wait(1)
        pcall(scanDances, true)
    end
    -- значения из сохранённого конфига Rayfield -> состояние движка
    dance.spin      = G.BS.Spin == true
    dance.sway      = G.BS.Sway == true
    dance.spinSpeed = tonumber(G.BS.SpinSpeed) or 360
    dance.swayAmp   = tonumber(G.BS.SwayAmp) or 20
    if G.BS.DanceOn then
        -- персонаж мог ещё не появиться - ждём и возобновляем
        task.spawn(function()
            task.wait(2)
            pcall(setDance, true)
        end)
    end
end)

print("[BS HUB] v11.9 запущен | хуков=" .. #netConns
    .. " | клиент айм: " .. tostring(G.BS.BulletSwap)
    .. " | аимлок: " .. tostring(G.BS.AimLock)
    .. " | выбор цели: всегда"
    .. " | лома: " .. tostring(G.BS.MeleeAim)
    .. " | без кулдауна: " .. tostring(G.BS.NoCooldown)
    .. " | прострел: " .. tostring(G.BS.Penetrate)
    .. " | ошибок GUI=" .. #UI_ERR)
