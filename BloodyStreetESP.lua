-- ============================================================
--  BLOODY STREET - ESP + КЛИЕНТ АИМ + АИМЛОК + ИГРОК  v11.43
--  GUI на Rayfield. Вкладки: ESP / AIM / ИГРОК. Самописного HUD нет.
--
--  ПАТРОНЫ (вкладка ИГРОК): пополнение из Workspace.SupplyCaches.
--  Кнопка ищет ближайший SupplyCrate, пробует ProximityPrompt,
--  ClickDetector и Touched, при необходимости телепортируется к ящику
--  и возвращает на место. Есть авто-пополнение рядом с ящиком.
--
--  МОНЕТЫ (вкладка ИГРОК): магнит физически тащит CoinPickup к игроку
--  (PivotTo/CFrame), затем дёргает ProximityPrompt и известный ремоут.
--
--  ESP (вкладка ESP): 3D/2D-коробки, ники, дистанция, HP, цвет по
--  ролям, скелет, полоски HP, рамка головы, цифры урона, стрелки,
--  snaplines, аура под вампирами, трейсеры, объекты, миникарта.
--
--  КЛИЕНТ АИМ (вкладка AIM): ПОДМЕНА ПАТРОНА. Remotes.FireWeapon
--  перехватывается через глобальный __namecall, и аргументы
--  выстрела подменяются на вектор к цели.
--  АИМЛОК: камера сама ведётся на цель, пока в руках оружие и цель
--  внутри круга (ПОВ). Работает ВСЕГДА, а не только пока зажат огонь;
--  целиться начинает, как только игрок появился впереди в круге.
--  ПРОСТРЕЛ: всегда ВКЛ — при цели за стеной скрипт временно переносит
--  персонажа за цель, ждёт репликации CFrame и только потом стреляет.
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
-- Ускоритель по Левому Shift удалён в v11.17.1. Флаг гасим явно:
-- InputBegan-хэндлеры предыдущего запуска читают именно G.BS.SpeedKey,
-- и без этого Shift продолжал бы разгонять персонажа после перезапуска.
G.BS.SpeedKey = false
G.BS.SpeedMul  = nil
-- Старые прыжковые хэндлеры v11.16 читают G.BS.JumpBoost. Гасим его,
-- чтобы после перезапуска поверх старой версии рывок не срабатывал
-- дважды. Новый флаг - JumpBoostV2.
G.BS.JumpBoost = false

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
-- Откуда начинать экранные трейсеры. Раньше начало было жёстко
-- прибито к низу/центру экрана, из-за чего линии выглядели как
-- «паутина» из одной точки. Теперь это настраивается отдельно.
local TRACER_ORIGINS = { "Центр", "Низ экрана", "Верх экрана" }
-- Стили коробки ESP (v11.36): плоская рамка, уголки или настоящая
-- 3D-коробка по рёбрам модели.
local BOX_STYLES = { "Рамка", "Уголки", "3D-коробка" }
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
-- Флаг «идёт телепорт» (прострел/сбор монеты). Сбрасываем при запуске:
-- если прошлая версия упала посреди телепорта, флаг мог остаться true.
G.BS._tpBusy = false

-- ---------- ESP ----------
G.BS.PlayerESP   = G.BS.PlayerESP   ~= false
G.BS.PlayerColor = safeColor(G.BS.PlayerColor, Color3.fromRGB(200, 200, 200))
G.BS.VampESP     = G.BS.VampESP     ~= false
G.BS.VampColor   = safeColor(G.BS.VampColor, Color3.fromRGB(255, 55, 55))
G.BS.HunterESP   = G.BS.HunterESP   ~= false
G.BS.HunterColor = safeColor(G.BS.HunterColor, Color3.fromRGB(70, 190, 255))
G.BS.OnlyVamps   = G.BS.OnlyVamps   or false
G.BS.ShowUnknown = false
G.BS.Names       = G.BS.Names       ~= false
G.BS.ShowDist    = G.BS.ShowDist    ~= false
G.BS.ShowHP      = G.BS.ShowHP      ~= false
G.BS.Boxes       = G.BS.Boxes       ~= false
G.BS.BoxThick    = G.BS.BoxThick    or 2
G.BS.BoxMargin   = math.clamp(tonumber(G.BS.BoxMargin) or 0, 0, 10)
G.BS.MaxDist     = G.BS.MaxDist     or 0
-- Подсветка тела (Highlight/chams) УДАЛЕНА по просьбе: красный шар
-- поверх модели закрывал персонажа. Флаги оставлены для совместимости.
G.BS.FillTransparency = 0.7
G.BS.BodyHighlight = false
-- КОРОБКИ. ЖЁСТКИЙ ПРЯМОУГОЛЬНИК по габаритам всей модели (3D-коробка)
-- или плоский экранный прямоугольник (стиль «Рамка»/«Уголки»).
-- Размер задаётся размерами модели; BoxMargin — отступ от тела (3D-стиль).
G.BS.BoxPad      = tonumber(G.BS.BoxPad) or 4
G.BS.BoxAlpha    = math.clamp(tonumber(G.BS.BoxAlpha) or 0, 0, 0.9)
G.BS.BoxThick    = math.clamp(tonumber(G.BS.BoxThick) or 2, 1, 6)
-- v11.34: стиль коробки (рамка / уголки / ромб для вампиров).
G.BS.BoxStyle    = pickOpt(G.BS.BoxStyle, BOX_STYLES, "3D-коробка")
G.BS.CornerBoxes = G.BS.CornerBoxes == true
-- v11.32: мелкие, но полезные настройки ESP.
G.BS.HideDead       = G.BS.HideDead ~= false   -- прятать ESP мёртвых
G.BS.HPPercent      = G.BS.HPPercent == true   -- HP в процентах
G.BS.MarkAim        = G.BS.MarkAim ~= false    -- звёздочка у цели аима
G.BS.SkelOnlyTarget = G.BS.SkelOnlyTarget == true
G.BS.SkelMinDist    = tonumber(G.BS.SkelMinDist) or 12

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
if G.BS.AimMaxDist <= 0 then G.BS.AimMaxDist = 290 end
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
-- «Без кулдауна» убрано из GUI по просьбе: по умолчанию выключено.
G.BS.NoCooldown   = G.BS.NoCooldown == true
-- СТАТУС ЦЕЛИ в ESP (сбит/раскрыт/оглушён). Хитмаркер и лента
-- событий удалены: в центре экрана больше нет лишних вспышек.
G.BS.ShowStatus   = G.BS.ShowStatus ~= false
G.BS.EventsOn     = false   -- HUD-лента удалена
G.BS.SpinSpeed = tonumber(G.BS.SpinSpeed) or 50
G.BS.SpinOnlyStill = nil   -- тумблер удалён: спин крутит и на ходу
-- УСКОРЕНИЕ В ПРЫЖКЕ: при каждом прыжке кратковременный рывок.
-- Ускоритель по Shift удалён по просьбе. V2 - чтобы старые хэндлеры
-- (они читают JumpBoost) не срабатывали вместе с новым.
-- Блок прыжка удалён из GUI по просьбе: фичи выключены по умолчанию.
G.BS.JumpBoostV2   = false
G.BS.JumpBoostMul  = tonumber(G.BS.JumpBoostMul) or 1.7
G.BS.JumpBoostTime = tonumber(G.BS.JumpBoostTime) or 0.8
G.BS.JumpPowerOn   = false
G.BS.JumpPowerMul  = tonumber(G.BS.JumpPowerMul) or 1.5
-- СКОРОСТЬ ТОЛЬКО В СПИД-ГЛИТЧЕ (v11.43): подброс вверх и
-- длительность разгона УДАЛЕНЫ по просьбе. Осталась одна механика:
-- прыжок + разгон (WalkSpeed x N), база запоминается автоматически.
-- Разгон держится фиксированное время (1.2 с) после прыжка.
G.BS.SpeedGlitch     = G.BS.SpeedGlitch == true
G.BS.SpeedGlitchMul  = math.clamp(tonumber(G.BS.SpeedGlitchMul) or 2.5, 1.1, 6)
-- ДОПОЛНИТЕЛЬНЫЕ ВИЗУАЛЫ (модуль G.BS.VIS): трейсеры, скелет, HP,
-- Прицел и хитмаркер УДАЛЕНЫ по просьбе. Остались только трейсеры
-- и информативные ESP-элементы.
-- v11.43: ТРЕЙСЕР ВЫСТРЕЛА УДАЛЁН по просьбе (не работал). Флаг
-- принудительно false — даже если в сохранёнке остался true.
-- Цвет/время/толщина трейсера больше нигде не используются.
G.BS.ShotTracer       = false
G.BS.AimLine       = G.BS.AimLine ~= false
G.BS.AimLineColor  = safeColor(G.BS.AimLineColor, Color3.new(1, 0, 0))
-- v11.43: минимальная толщина 1 px — стрелки можно делать тоньше.
G.BS.AimLineThick  = math.clamp(tonumber(G.BS.AimLineThick) or 2, 1, 6)
G.BS.AimLineAlpha  = math.clamp(tonumber(G.BS.AimLineAlpha) or 1, 0, 1)
G.BS.SnapFrom      = pickOpt(G.BS.SnapFrom, TRACER_ORIGINS, "Низ экрана")
G.BS.AimLineFrom   = pickOpt(G.BS.AimLineFrom, TRACER_ORIGINS, "Центр")
G.BS.SnapAlpha     = math.clamp(tonumber(G.BS.SnapAlpha) or 1, 0, 1)
G.BS.Skeleton      = G.BS.Skeleton or false
G.BS.SkeletonThick = tonumber(G.BS.SkeletonThick) or 1
G.BS.HealthBars    = G.BS.HealthBars ~= false
G.BS.HealthBarWidth  = tonumber(G.BS.HealthBarWidth) or 40
G.BS.HealthBarHeight = tonumber(G.BS.HealthBarHeight) or 4
G.BS.OffArrows     = G.BS.OffArrows ~= false
-- НОВЫЕ ESP-ВИЗУАЛЫ: стрелки к игрокам (snaplines).
G.BS.Snaplines     = G.BS.Snaplines ~= false
G.BS.SnapThick     = tonumber(G.BS.SnapThick) or 1
-- v11.43: тоньше и регулируемее — минимум 1 px, дефолт 2 px.
G.BS.SnapArrowThick = math.clamp(tonumber(G.BS.SnapArrowThick) or 2, 1, 6)
-- v11.39: КОЛЬЦО ПОД ИГРОКОМ И АУРА ВАМПИРА УДАЛЕНЫ по просьбе.
-- На близкой дистанции кольцо радиусом 2–4 студа занимало пол-экрана
-- и выглядело как огромный красный круг. Принудительно выключаем, даже
-- если в getgenv() остались старые true.
G.BS.VampAura      = false
G.BS.FootRing      = false
-- v11.31: скорость цели в подписи и цвет ника по HP.
G.BS.ShowSpeed     = G.BS.ShowSpeed == true
G.BS.NameHPColor   = G.BS.NameHPColor == true
-- v11.31: линии между вампирами (видно, кто рядом с кем).
G.BS.VampLinks     = G.BS.VampLinks == true
G.BS.LabelSize     = tonumber(G.BS.LabelSize) or 13
G.BS.CrateESP      = G.BS.CrateESP or false
G.BS.CrateColor    = safeColor(G.BS.CrateColor, Color3.new(1, 1, 0))
G.BS.CoinESP       = G.BS.CoinESP or false
G.BS.CoinColor     = safeColor(G.BS.CoinColor, Color3.new(1, 1, 0))
G.BS.RoleIcons     = G.BS.RoleIcons ~= false
G.BS.WeaponESP     = G.BS.WeaponESP ~= false
G.BS.RoundTimer    = false
G.BS.KillCounter   = false
G.BS.CountsESP     = false
-- v11.27: ещё визуалы.
G.BS.HeadBox       = G.BS.HeadBox ~= false
G.BS.HeadBoxSize   = tonumber(G.BS.HeadBoxSize) or 22
G.BS.HeadBoxColor  = safeColor(G.BS.HeadBoxColor, Color3.new(1, 0, 0))
-- v11.36: рамка головы красится в цвет роли игрока (иначе у всех был
-- один и тот же красный квадрат).
G.BS.HeadBoxRole   = G.BS.HeadBoxRole ~= false
G.BS.DamageNumbers = G.BS.DamageNumbers ~= false
G.BS.DmgNumColor   = safeColor(G.BS.DmgNumColor, Color3.new(1, 1, 0))
-- СТРЕЛКИ ЗВУКА УДАЛЕНЫ (по просьбе): вместе с меню убран и рендер.
G.BS.SoundArrows   = false
G.BS.SoundArrowColor = safeColor(G.BS.SoundArrowColor, Color3.new(0, 1, 0.5))
G.BS.StaminaBar    = false
G.BS.AmmoBar       = false
G.BS.FPSCounter    = false
G.BS.CoordsTime    = false
G.BS.Minimap       = G.BS.Minimap or false
G.BS.MinimapSize   = tonumber(G.BS.MinimapSize) or 160
G.BS.MinimapSelf   = G.BS.MinimapSelf ~= false
-- v11.27.1: пинг/скорость, затухание коробок, цифры HP, улики.
G.BS.PingSpeed     = false
G.BS.DistFade      = G.BS.DistFade or false
G.BS.HPBarText     = G.BS.HPBarText ~= false
-- Подсветка улик и пульс низкого HP удалены вместе с подсветкой тела.
-- v11.43: ПУЛЬС НИЗКОГО HP УДАЛЁН по просьбе.
G.BS.ClueESP       = false
G.BS.ClueColor     = safeColor(G.BS.ClueColor, Color3.new(0.6, 1, 0.2))
-- МОНЕТЫ (Workspace.CoinPickups). Магнит двигает монеты к игроку.
-- АВТО-ОБУЧЕНИЕ: пока ремоут сбора не выучен, скрипт сам запоминает
-- первый FireServer с монетой, когда монета рядом. Ручная кнопка не нужна.
-- Авто-сбор (prompt/ремоут) теперь ВСЕГДА включён и без тумблера:
-- пользователь просил убрать переключатель, чтобы монеты просто
-- притягивались и собирались. Телепорт-сбор к серверной позиции монеты
-- остаётся отдельным тумблером (по умолчанию выключен).
G.BS.CoinAuto      = true
G.BS.CoinBlink     = false
G.BS.CoinLearn     = true
-- v11.36: AFK-ФАРМ МОНЕТ. Скрипт сам собирает монеты по всей карте и
-- подбирает их заново, когда игра сбрасывает новые. Тумблер в меню.
-- По умолчанию ВЫКЛЮЧЕН: фарм постоянно телепортирует персонажа к монетам,
-- и включать такое без явного согласия опасно. Тумблер в меню.
G.BS.CoinFarm      = G.BS.CoinFarm == true
G.BS.CoinFarmGap   = math.clamp(tonumber(G.BS.CoinFarmGap) or 1.0, 0.2, 10)
G.BS.CoinFarmRange = tonumber(G.BS.CoinFarmRange) or 700
G.BS.CoinRange     = tonumber(G.BS.CoinRange) or 600
G.BS.CoinScanEvery = tonumber(G.BS.CoinScanEvery) or 1.0
-- МАГНИТ МОНЕТ УДАЛЁН (v11.33) по просьбе: монеты больше не притягиваются
-- к игроку. Код остался, но выключен — включить из консоли:
--   getgenv().BS.CoinMagnet = true
-- Сбор при этом работает как раньше: prompt / click / touch / ремоут.
G.BS.CoinMagnet      = false
G.BS.CoinMagnetRadius = tonumber(G.BS.CoinMagnetRadius) or 300
G.BS.CoinMagnetPower  = tonumber(G.BS.CoinMagnetPower) or 0.55
-- ТЕЛЕПОРТ-ВЫСТРЕЛ ЧЕРЕЗ СТЕНЫ. На время выстрела персонаж окажется
-- за спиной/над целью (для сервера), потом вернётся. Требует аимлока:
-- камера должна смотреть на цель, иначе сервер может отклонить выстрел.
-- Прострел стен теперь ВСЕГДА включён: отдельного тумблера нет.
G.BS.GhostShot     = true
-- 0.12 c: даём серверу получить новый CFrame ДО выстрела, иначе он
-- видит старую позицию и отклоняет выстрел («прострел не работает»).
G.BS.GhostHold     = tonumber(G.BS.GhostHold) or 0.12
-- Сдвиг времени выстрела в ремоуте (аргумент №5) вперёд, чтобы
-- сервер считал, что WEAPON_COOLDOWN уже прошёл.
G.BS.ShotTimeHack = G.BS.ShotTimeHack == true
-- ПОДСВЕТКА ТЕКУЩЕЙ ЦЕЛИ ОТКЛЮЧЕНА по умолчанию: пользователь просил
-- убрать подсветку тела. Флаги оставлены для совместимости.
G.BS.TargetMark  = false
G.BS.TargetMarkColor = safeColor(G.BS.TargetMarkColor, Color3.new(1, 1, 1))
-- ТОЧКА ПРИЦЕЛИВАНИЯ: метка там, куда реально уходит патрон.
-- (точка прицеливания удалена вместе с HUD/AIM-мусором)
-- ЛОГ ПОПАДАНИЙ: печатать каждое событие урона (DamagePopup/CombatFeed).
G.BS.DmgLog      = G.BS.DmgLog == true
G.BS.StaminaDebug = G.BS.StaminaDebug or false
G.BS.HealthLock  = G.BS.HealthLock  or false
G.BS.HealthMax   = G.BS.HealthMax   or 5000
G.BS.ScanOnStart = G.BS.ScanOnStart or false

G.BS.AimLockColor  = safeColor(G.BS.AimLockColor,  Color3.fromRGB(255, 50, 50))
G.BS.AimMarkColor  = safeColor(G.BS.AimMarkColor,  Color3.fromRGB(255, 200, 0))
-- v11.33: КРАСИВАЯ МЕТКА ЦЕЛИ. Вместо грубых жёлтых полосок — тонкая
-- обводка (Highlight), аккуратные уголки в цвете роли и подробная
-- табличка цели (имя / дистанция / HP / оружие).
G.BS.TargetMark      = G.BS.TargetMark ~= false      -- обводка Highlight
G.BS.TargetMarkAlpha = math.clamp(tonumber(G.BS.TargetMarkAlpha) or 0.15, 0, 1)
-- КОЛЬЦО ЗАХВАТА (v11.34): главный индикатор «на кого работает аимлок».
G.BS.TargetRing      = G.BS.TargetRing ~= false
G.BS.TargetRingSize  = tonumber(G.BS.TargetRingSize) or 26
G.BS.TargetRingThick = tonumber(G.BS.TargetRingThick) or 1
G.BS.TargetTicks     = G.BS.TargetTicks ~= false
G.BS.TargetTickSpeed = tonumber(G.BS.TargetTickSpeed) or 1.1
G.BS.TargetLockAnim  = G.BS.TargetLockAnim ~= false
-- Цвет таблички цели: по роли (по умолчанию) или свой.
G.BS.TargetBracketRole  = G.BS.TargetBracketRole ~= false -- цвет по роли
G.BS.TargetBracketColor = safeColor(G.BS.TargetBracketColor, Color3.fromRGB(255, 255, 255))
G.BS.TargetPlate     = G.BS.TargetPlate ~= false    -- табличка под целью
G.BS.TargetPlateName = G.BS.TargetPlateName ~= false
G.BS.TargetPlateDist = G.BS.TargetPlateDist ~= false
G.BS.TargetPlateHP   = G.BS.TargetPlateHP ~= false
G.BS.TargetPlateWeap = G.BS.TargetPlateWeap == true
-- Радиус захвата в пикселях. 600 = без ограничения.
G.BS.AimFOV        = tonumber(G.BS.AimFOV) or 300
-- v11.18: старый дефолт 160 px был слишком узким — цель впереди, но чуть
-- в стороне от прицела, не захватывалась. Расширяем один раз до 300.
if G.BS.AimFOVDefault ~= 2 then
    G.BS.AimFOVDefault = 2
    if G.BS.AimFOV == nil or G.BS.AimFOV == 160 then
        G.BS.AimFOV = 300
    end
end
G.BS.AimFOVShow    = G.BS.AimFOVShow ~= false
G.BS.AimFOVColor   = safeColor(G.BS.AimFOVColor, Color3.fromRGB(255, 255, 255))
G.BS.AimFOVThick   = tonumber(G.BS.AimFOVThick) or 2
G.BS.AimFOVAlpha   = tonumber(G.BS.AimFOVAlpha) or 0.35
-- v11.32: «только видимые цели» удалено — прострел должен работать
-- всегда, без скрытого отбрасывания целей за стеной.
-- Уголки метки цели (жёлтые полоски) больше не рисуются.
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
-- Скорость доворота: 1 = плавно, 35 = мгновенно (нужно по правилу
-- сервера SHOT_ANGLE_SLACK_DEG = 3). В момент выстрела камера и
-- персонаж всё равно доворачиваются точно на цель в ncFireWeapon,
-- поэтому плавность влияет только на вид, а не на попадание.
-- ПО УМОЛЧАНИЮ 35: плавный доворот давал «отставание» при ходьбе.
G.BS.AimLock       = G.BS.AimLock ~= false
G.BS.AimLockSpeed  = tonumber(G.BS.AimLockSpeed) or 35
-- ПОВ (поворот камеры). true  - камера доворачивается на цель
--                         (иначе подмена патрона работает молча).
-- false - камера остаётся твоей, но выстрел всё равно идёт в цель.
G.BS.AimLockTurn   = true   -- камера доворачивается (тумблер убран)
-- Аимлок работает ВСЕГДА, пока в руках оружие и цель в круге.
-- Режим «только пока зажат огонь» удалён в v11.18: именно из-за него
-- камера велась только во время стрельбы. Флаг принудительно false.
G.BS.AimLockFireOnly = false
-- v11.18: один раз включаем аимлок после обновления, чтобы он точно
-- работал без стрельбы. Если выключить тумблером — при следующем
-- запуске останется выключенным (это осознанный выбор пользователя).
if G.BS.AimAlwaysV ~= 18 then
    G.BS.AimAlwaysV = 18
    G.BS.AimLock = true
    G.BS.AimFireMode = nil  -- старый флаг удалённого тумблера
end
-- УДЕРЖАНИЕ ЦЕЛИ, секунды. Пока идёт это время, аимлок ведёт ту же
-- цель, даже если она чуть сместилась. ЛКМ влияет ТОЛЬКО на удержание
-- выбора цели, а не на сам аимлок: камера ведётся всегда (v11.18).
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
-- ВАЖНО ДЛЯ ПРОСТРЕЛА: сервер сверяет направление пули с взглядом
-- (SHOT_ANGLE_SLACK_DEG = 3). Если камера не доводится на цель за стеной,
-- выстрел отклоняется. Поэтому при включённом простреле камера ВЕДЁТСЯ
-- сквозь стены: AimLockNoWall = false. Отдельного тумблера нет.
G.BS.AimLockNoWall   = false
-- v11.43: «ЦЕЛИТЬСЯ ТОЛЬКО В ВИДИМЫХ» — тумблер в разделе аимлока.
-- true = цель за стеной НЕ выбирается (список целей отбрасывает её)
-- и камера не доводится сквозь стену. При включении вместе с ним
-- включается и AimLockNoWall; при выключении — оба выключаются.
G.BS.AimVisibleOnly  = G.BS.AimVisibleOnly == true
-- ПРОСТРЕЛ СТЕН. Сервер разрешает увести точку вылета на
-- Config.Combat.SHOT_ORIGIN_SLACK = 14 студов. Ставим её за стеной.
G.BS.WallPenetrate   = G.BS.WallPenetrate ~= false
G.BS.OriginSlack     = tonumber(G.BS.OriginSlack) or 13
-- РАСШИРИТЕЛЬ ХИТБОКСА удалён: работает только при клиентском
-- подсчёте урона, а игра считает урон на сервере.
-- АВТОПРОВЕРКА ОРУЖИЯ при запуске (дальность/разброс/урон в консоль).
G.BS.WeaponProbeOnStart = G.BS.WeaponProbeOnStart ~= false
-- ЛОВИМ АНИМАЦИИ, КОТОРЫЕ ИГРА ГРУЗИТ САМА (функция ниже, рядом с
-- addDance). Главный источник эмоутов: когда открывают колесо эмоутов
-- или включают танец, игра зовёт Animator:LoadAnimation(Animation) либо
-- Humanoid:PlayAnimation(Animation) - наш глобальный хук __namecall это
-- видит, поэтому ID анимации снимается на лету.

-- captureEmoteArgs (разбор EmotePlay) - рядом с addDance, ниже.

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
G.BS.NoiseMarks = false
G.BS.NoiseLife  = tonumber(G.BS.NoiseLife) or 2.2
-- ОСОБЫЕ РОЛИ ПО ПРЕДМЕТУ (Config.Roles.ROLE_TOOL_MODEL):
-- Medkit = доктор, MagnifyingGlass = детектив, SeerStaff = сейер,
-- HolyCross = жрец, Garlic = торговец, SupplyCrate = оружейщик,
-- Baton/Claw = вампир. Показывать в подписи к ESP.
G.BS.ShowSpecialRole = false
-- HUD удалён; поле оставлено только чтобы старый конфиг не включал его.
G.BS.Hud = false
-- ТАНЕЦ НА ХОДЬБЕ + СПИН. Игровые эмоуты отменяются движением,
-- поэтому анимацию проигрываем сами (LoadAnimation + высокий приоритет).
-- Спин и покачивание - свои, поворот модели, ассеты не нужны.
G.BS.DanceOn     = false
G.BS.Spin        = false
G.BS.Sway        = false
G.BS.SpinSpeed   = tonumber(G.BS.SpinSpeed) or 50   -- градусов в секунду
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
if G.BS.CfgV ~= 39 then
    -- Старые сохранённые 1/2..34 означали «мгновенно», потому что код
    -- трактовал всё >= 1 как instant. Новая шкала: 1 = плавно,
    -- 35 = мгновенно. Один раз переводим старый дефолт в 35.
    if (tonumber(G.BS.AimLockSpeed) or 1) <= 35 then
        local oldSpeed = tonumber(G.BS.AimLockSpeed) or 1
        if oldSpeed >= 1 and oldSpeed < 35 then
            G.BS.AimLockSpeed = 35
        end
    end
    G.BS.CfgV      = 39
    -- АИМЛОК РАБОТАЕТ ВСЕГДА, а не только пока зажата ЛКМ.
    G.BS.AimLockFireOnly = false
    G.BS.AimLockTurn     = true
    G.BS.AimLock   = true
    G.BS.BulletSwap = true
    G.BS.AimLockSpeed = 35
    G.BS.LockHold      = 0.6
    G.BS.LockHoldOnFire = true
    G.BS.SyncTarget    = true
    G.BS.AimLockListTarget = false
    G.BS.SpinSpeed = 50
    G.BS.DanceOn   = false
    G.BS.Spin      = false
    G.BS.Sway      = false
    G.BS.SwayAmp   = 20
    G.BS.DanceAutoScan = true
    G.BS.NoiseMarks = false
    G.BS.NoiseLife  = 2.2
    G.BS.ShowSpecialRole = false
    G.BS.ShowUnknown = false
    G.BS.MaxDist = 0
    G.BS.Hud        = false
    G.BS.AimFOV     = 300
    G.BS.AimFOVShow = true
    G.BS.AimChain  = true
    G.BS.AimFreePart = true
    G.BS.NoCooldown = false
    G.BS.ShowStatus = true
    G.BS.EventsOn   = false
    G.BS.JumpBoostV2 = false
    G.BS.JumpPowerOn = false
    G.BS.GhostShot = true
    G.BS.ShotTimeHack = false
    G.BS.AimMaxDist   = 290
    G.BS.AimLead   = 0.08
    G.BS.AimLockNoWall = false
    G.BS.MeleeAim  = true
    G.BS.WallPenetrate = true
    G.BS.OriginSlack = 13
    G.BS.SpoofBack = 0
    G.BS.SilentShot = false
    G.BS.Hitbox    = false
    G.BS.RapidFire = false
    -- v11.32: чистая графика и безопасные дефолты.
    G.BS.Boxes         = true
    G.BS.BoxPad        = 4
    G.BS.BoxAlpha      = 0
    G.BS.BoxThick      = 2
    G.BS.CornerBoxes   = false
    G.BS.BodyHighlight = false
    G.BS.ClueESP       = false
    -- v11.43: G.BS.LowHPWarn (пульс низкого HP) удалён.
    -- v11.33/v11.34: подсветка цели — тонкая обводка + кольцо захвата
    -- с засечками + табличка с подробностями.
    G.BS.TargetMark       = true
    G.BS.TargetMarkAlpha  = 0.15
    G.BS.TargetRing       = true
    G.BS.TargetRingSize   = 26
    G.BS.TargetRingThick  = 1
    G.BS.TargetTicks      = true
    G.BS.TargetTickSpeed  = 1.1
    G.BS.TargetLockAnim   = true
    G.BS.TargetBrackets   = false
    G.BS.TargetBracketSize = 10
    G.BS.TargetBracketThick = 2
    G.BS.TargetBracketRole = true
    G.BS.TargetPulse      = true
    G.BS.TargetPlate      = true
    G.BS.TargetPlateName  = true
    G.BS.TargetPlateDist  = true
    G.BS.TargetPlateHP    = true
    G.BS.TargetPlateWeap  = false
    G.BS.HideDead      = true
    G.BS.MarkAim       = true
    G.BS.SkelOnlyTarget = false
    G.BS.SkelMinDist   = 12
    -- v11.36: коробка по габаритам модели, стиль, рамка головы по роли,
    -- спид глитч, сбор монет по всей карте, авто-телепорт к ящику убран.
    G.BS.Boxes         = true
    G.BS.BoxStyle      = "3D-коробка"
    G.BS.HeadBoxRole   = true
    G.BS.CoinFarm        = false
    G.BS.CoinFarmGap     = 1.0
    G.BS.CoinFarmRange   = 700
    G.BS.SpeedGlitch     = false
    G.BS.SpeedGlitchMul  = 2.5
    -- v11.43: SpeedGlitchLift / SpeedGlitchHold удалены.
    -- v11.33: магнит монет убран из меню и выключен.
    G.BS.CoinMagnet    = false
    G.BS.CoinAuto      = true
    G.BS.CoinLearn     = true
    G.BS.CoinBlink     = false
    G.BS.CoinMagnetRadius = 300
    G.BS.CoinMagnetPower  = 0.55
    G.BS.SpeedGlitch     = false
    G.BS.SpeedGlitchMul  = 2.5
    G.BS.AmmoAuto      = true
    G.BS.AmmoAutoTP    = false
    G.BS.AmmoBringCrate = true
    -- 0 = пополнять ТОЛЬКО когда патроны закончились (0 шт).
    G.BS.AmmoLowPct    = 0
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
             burst = nil, burstBlocked = 0, emote = nil,
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
-- УДЕРЖАНИЕ ЦЕЛИ АИМЛОКОМ. Объявлено здесь (а не рядом с aimLockTick),
-- чтобы computeBulletPreShot ниже мог отдать приоритет уже захваченной
-- цели. Иначе камера/патрон/маркер могли разъехаться по разным игрокам.
local LOCK_TARGET = nil           -- Part (BOS)
local LOCK_LAST_S, LOCK_UNTIL = nil, 0

-- ХИТМАРКЕР И ЛЕНТА СОБЫТИЙ. Определения ниже (после hitMarkAt нужно
-- поймать урон из обработчика ремоутов, который объявлен раньше), здесь
-- только forward-объявления.
local EVENTS       = {}     -- последние события (последние 8)
local addEvent               -- добавить строку в ленту (ниже)
local hitMarkAt   = 0       -- os.clock() последнего реального попадания
-- ХИТМАРКЕР УДАЛЁН (v11.32): линий и вспышки в центре экрана больше нет.
local danceDD = nil         -- выпадающий список танцев (создаётся в GUI)
local refreshDanceDropdown -- наполнение списка найденными анимациями
local emoteTables = {}      -- таблицы из EmoteSetSlots (список эмоутов)
local UI_ERR = {}           -- ошибки создания элементов GUI (пишутся в лог)

-- Уверенность источников роли
local CONF = { attr = 6, event = 5, deduce = 4, sound = 3, gear = 2 }

local function aliasOf(v)
    local s = string.lower(tostring(v or ""))
    if s == "" then return nil end
    if string.find(s, "vamp", 1, true) then return "vampire" end
    if string.find(s, "hunt", 1, true) then return "hunter" end
    -- Мирные роли игры (доктор, детектив, провидец...) — это люди.
    -- Без этого «Противники по роли» считали их отдельной ролью и
    -- аимлок мог бить по своим.
    if s == "doctor" or s == "detective" or s == "seer"
       or s == "medic" or s == "civilian" or s == "citizen"
       or s == "survivor" or s == "crew" or s == "human"
       or s == "innocent" or s == "villager" then
        return "human"
    end
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

-- ============================================================
--  МОНЕТЫ: авто-сбор через ремоут игры
-- ============================================================
local COIN = {
    remote = nil, args = nil, argIdx = nil, argType = nil,
    learned = false, lastScan = 0,
    -- Слабые ключи: монеты удаляются, и старые записи не должны
    -- копиться в памяти весь матч.
    seen = setmetatable({}, { __mode = "k" }),
    magnetList = {}, magnetAt = 0,
    tryAt = setmetatable({}, { __mode = "k" }),
    nearPlayer = false,
    promptCheck = setmetatable({}, { __mode = "k" }),
    firedLog = setmetatable({}, { __mode = "k" }),
    -- v11.31: исходные (серверные) позиции монет. Слабые ключи, чтобы
    -- удалённые монеты не держались в памяти.
    origin = setmetatable({}, { __mode = "k" }),
    originCF = setmetatable({}, { __mode = "k" }),
    -- v11.36: состояние AFK-фарма монет (куда монету уже жали).
    farmState = setmetatable({}, { __mode = "k" }),
    farmCount = 0,
    fns = {}, blinkBusy = false, blinkAt = 0,
}
G.BS.Coins = COIN

function COIN.findFolder()
    if COIN.folder and COIN.folder.Parent then return COIN.folder end
    -- не сканировать весь workspace каждую секунду: если папки нет,
    -- повторяем поиск не чаще раза в 5 с.
    if COIN.folderAt and (os.clock() - COIN.folderAt) < 5 then return nil end
    COIN.folderAt = os.clock()
    -- FindFirstChild с recursive=true ищет на стороне движка: без
    -- Lua-обхода всего workspace (раньше это подвешивало кадр).
    -- Имена папки у разных карт разные — пробуем несколько.
    -- "CoinPickup" здесь больше нет: так называется сама модель монеты,
    -- и FindFirstChild мог закэшировать одну монету вместо папки.
    local names = { "CoinPickups", "Coins", "Pickups", "CoinSpawner" }
    for _, n in ipairs(names) do
        local f = workspace:FindFirstChild(n, true)
        if f and not (f:IsA("Model") and f.Name == "CoinPickup") then
            COIN.folder = f
            return f
        end
    end
    COIN.folder = nil
    return nil
end

function COIN.findRemote()
    if COIN.remote and COIN.remote.Parent then return COIN.remote end
    -- не сканировать всю игру каждые 0.5 с: если ремоут ещё не найден,
    -- повторяем поиск не чаще раза в 5 с
    if COIN.remoteScanAt and (os.clock() - COIN.remoteScanAt) < 5 then return nil end
    COIN.remoteScanAt = os.clock()
    local found
    local function check(inst)
        if not found and (inst:IsA("RemoteEvent") or inst:IsA("UnreliableRemoteEvent")) then
            local n = string.lower(inst.Name)
            if string.find(n, "coin", 1, true) or string.find(n, "pickup", 1, true)
               or string.find(n, "collect", 1, true) then
                found = inst
            end
        end
    end
    if Remotes then
        for _, r in ipairs(Remotes:GetChildren()) do check(r) end
    end
    if not found then
        -- Только ReplicatedStorage: game:GetDescendants() — это десятки
        -- тысяч объектов и фриз раз в 5 секунд. Нужные ремоуты игры
        -- лежат в ReplicatedStorage, этого достаточно.
        for _, d in ipairs(TRS:GetDescendants()) do
            check(d)
            if found then break end
        end
    end
    COIN.remote = found
    return found
end

function COIN.collectOne(coin)
    if not coin or not coin.Parent then return false end
    local remote = COIN.remote or COIN.findRemote()
    if not remote then return false end
    local args
    if COIN.args and COIN.argIdx == 0 then
        -- игра сама определяет монету (например, по касанию) —
        -- повторяем вызов с теми же аргументами, что запомнили.
        local n = tonumber(COIN.args.n) or 0
        pcall(function() remote:FireServer(table.unpack(COIN.args, 1, n)) end)
        return true
    elseif COIN.args and COIN.argIdx and COIN.argIdx > 0 and COIN.argIdx <= COIN.args.n then
        -- Model не имеет .Position: берём позицию пивота/части.
        -- ВАЖНО: для позиции используем СЕРВЕРНУЮ (origin), а не
        -- клиентскую после магнита — иначе ремоут отвергнет точку.
        local coinPos = COIN.origin[coin]
        if not coinPos then
            pcall(function()
                if coin:IsA("BasePart") then
                    coinPos = coin.Position
                elseif coin:IsA("Model") then
                    coinPos = coin:GetPivot().Position
                end
            end)
        end
        args = {}
        for i = 1, COIN.args.n do
            if i == COIN.argIdx then
                if COIN.argType == "position" then args[i] = coinPos or coin
                elseif COIN.argType == "name" then args[i] = coin.Name
                else args[i] = coin end
            else
                args[i] = COIN.args[i]
            end
        end
    else
        args = { coin }
    end
    pcall(function() remote:FireServer(table.unpack(args, 1, #args)) end)
    return true
end

function COIN.scan()
    local folder = COIN.findFolder()
    if not folder then return 0 end
    -- Если ремоута нет, не сканируем ReplicatedStorage каждые 5 с:
    -- сбор идёт через prompt/click/touch. Поиск ремоута — раз в 15 с.
    if not (COIN.remote and COIN.remote.Parent) then
        local nowR = os.clock()
        if nowR - (COIN.remoteSearchAt or 0) >= 15 then
            COIN.remoteSearchAt = nowR
            pcall(COIN.findRemote)
        end
    end
    if not (COIN.remote or COIN.learned) then return 0 end
    local n = 0
    -- Собираем только то, что рядом: remote на каждую монету карты —
    -- это сотни вызовов и гарантированный спам серверу.
    local ch = LP and LP.Character
    local myRoot = ch and ch:FindFirstChild("HumanoidRootPart")
    for _, coin in ipairs(folder:GetDescendants()) do
        if coin:IsA("Model") and coin.Name == "CoinPickup" then
            local now = os.clock()
            local last = COIN.seen[coin]
            if not last or (now - last) >= 5 then
                COIN.seen[coin] = now
                local part = coinPart(coin)
                local near = part and myRoot
                    and (part.Position - myRoot.Position).Magnitude <= 14
                if near and COIN.collectOne(coin) then n = n + 1 end
            end
        end
    end
    return n
end

-- СБОР МОНЕТ ПО ВСЕЙ КАРТЕ (v11.36) — реализация ниже, после
-- fireCoinPrompts: функция должна быть объявлена раньше по тексту,
-- иначе ссылка превратится в nil.
function COIN.autoTick(now)
    if G.BS.CoinAuto == false then return end
    -- AFK-фарм: сканируем чаще, чтобы успевать за сбрасываемыми
    -- монетами (иначе между монетами остаются пустые секунды).
    local every = tonumber(G.BS.CoinScanEvery) or 1.0
    if G.BS.CoinFarm ~= false then every = math.min(every, 0.5) end
    if now - COIN.lastScan < every then return end
    COIN.lastScan = now
    pcall(COIN.scan)
    -- v11.36: сбор по всей карте.
    if G.BS.CoinFarm ~= false then
        pcall(COIN.collectAll, now)
    end
end

-- ============================================================
--  МАГНИТ МОНЕТ: монеты летят к игроку
-- ============================================================
local function coinPart(coin)
    if coin:IsA("BasePart") then return coin end
    local p = coin.PrimaryPart
    if p and p.Parent then return p end
    local ok, found = pcall(function()
        return coin:FindFirstChildWhichIsA("BasePart", true)
    end)
    if ok then return found end
    return nil
end
COIN.coinPart = coinPart

local function coinPivot(coin)
    if coin:IsA("Model") then
        local ok, cf = pcall(function() return coin:GetPivot() end)
        if ok then return cf end
    end
    local p = coinPart(coin)
    if p then
        local ok, cf = pcall(function() return p.CFrame end)
        if ok then return cf end
    end
    return nil
end

-- ФУНКЦИИ ИСПОЛНИТЕЛЯ. getgenv()/fireproximityprompt есть не везде:
-- проверяем и env, и _G, и кэшируем результат, чтобы не искать каждый
-- кадр. Если функции нет — остаётся InputHoldBegin/InputHoldEnd.
local function coinFn(name)
    local cached = COIN.fns and COIN.fns[name]
    if cached ~= nil then return cached or nil end
    local f
    if type(getgenv) == "function" then
        local ok, env = pcall(getgenv)
        if ok and type(env) == "table" then f = env[name] end
    end
    if type(f) ~= "function" then
        local ok, g = pcall(function() return _G[name] end)
        if ok and type(g) == "function" then f = g end
    end
    if not COIN.fns then COIN.fns = {} end
    COIN.fns[name] = f or false
    return f
end

local function coinPromptAndClick(coin)
    local prompt, click
    for _, d in ipairs(coin:GetDescendants()) do
        if not prompt and d:IsA("ProximityPrompt") then prompt = d end
        if not click and d:IsA("ClickDetector") then click = d end
        if prompt and click then break end
    end
    return prompt, click
end

-- ВЗАИМОДЕЙСТВИЕ С МОНЕТОЙ. Вызывать ТОЛЬКО когда персонаж уже стоит
-- у исходной (серверной) позиции монеты: prompt проверяет дистанцию
-- на сервере, а не на нашем клиенте.
local function fireCoinPrompts(coin)
    local prompt, click = coinPromptAndClick(coin)
    local fired = false
    local fpp = coinFn("fireproximityprompt")
    if prompt then
        fired = true
        if fpp then
            local ok = pcall(fpp, prompt)
            if not ok then pcall(fpp, prompt, 1) end
        end
        -- Ручной путь: InputHoldBegin/End. Он нужен и как запасной, и
        -- для prompt'ов с HoldDuration > 0 (executor-функция у многих
        -- исполнителей отпускает prompt мгновенно, но сервер ждёт hold).
        pcall(function()
            if prompt.Enabled then
                prompt:InputHoldBegin()
                local hold = tonumber(prompt.HoldDuration) or 0
                task.delay(math.max(0.06, hold + 0.08), function()
                    pcall(function() prompt:InputHoldEnd() end)
                end)
            end
        end)
    end
    local fcd = coinFn("fireclickdetector")
    if click and fcd then
        pcall(fcd, click, 0)
        fired = true
    end
    -- TouchTransmitter: некоторые игры собирают монету по касанию.
    local part = coinPart(coin)
    local ft = coinFn("firetouchinterest")
    if part and ft then
        local myRoot = LP and LP.Character and LP.Character:FindFirstChild("HumanoidRootPart")
        if myRoot then
            pcall(ft, part, myRoot, 0)
            task.delay(0.12, function()
                if part.Parent then pcall(ft, part, myRoot, 1) end
            end)
            fired = true
        end
    end
    -- Ремоут — только если он реально есть/выучен. Иначе findRemote
    -- каждую секунду обходил бы ReplicatedStorage без пользы.
    if (COIN.remote and COIN.remote.Parent) or COIN.learned then
        pcall(function() COIN.collectOne(coin) end)
        fired = true
    end
    return fired
end

-- СБОР МОНЕТ ПО ВСЕЙ КАРТЕ + AFK-ФАРМ (v11.36).
-- Важный момент: игра часто НЕ удаляет собранную монету, а
-- ПЕРЕСТАВЛЯЕТ её на новое место (сброс). Из-за паузы в пару секунд
-- фарм «зависал» на одной и той же монете. Теперь: если монета
-- сместилась — считаем её новой и берём сразу.
function COIN.collectAll(now)
    local folder = COIN.findFolder()
    if not folder then return 0 end
    local n = 0
    local okAll, list = pcall(function() return folder:GetDescendants() end)
    if not okAll or type(list) ~= "table" then return 0 end
    local gap = tonumber(G.BS.CoinFarmGap) or 1.0
    if gap < 0.2 then gap = 0.2 elseif gap > 10 then gap = 10 end
    -- Ближний сбор: prompt/click/touch срабатывают только рядом с игроком.
    -- Раньше fireCoinPrompts вызывался для КАЖДОЙ монеты карты — это
    -- тысячи вызовов в секунду и гарантированный спам серверу.
    local ch = LP and LP.Character
    local myRoot = ch and ch:FindFirstChild("HumanoidRootPart")
    for i = 1, #list do
        local coin = list[i]
        if coin and coin:IsA("Model") and coin.Name == "CoinPickup" and coin.Parent then
            local part = coinPart(coin)
            local pos = part and part.Parent and part.Position or nil
            local st = COIN.farmState[coin]
            local take = true
            if not (part and pos and myRoot) then
                take = false
            elseif (pos - myRoot.Position).Magnitude > 14 then
                -- Далёкие монеты собирает телепорт (blinkCollect), не prompt.
                take = false
            end
            if take and st and pos and st.pos and (pos - st.pos).Magnitude < 3 then
                -- та же самая монета на том же месте — ждём паузу
                take = (now - st.at) >= gap
            end
            if take then
                COIN.farmState[coin] = { at = now, pos = pos }
                local ok, fired = pcall(fireCoinPrompts, coin)
                if ok and fired then
                    n = n + 1
                    COIN.farmCount = (COIN.farmCount or 0) + 1
                    local c = COIN.farmCount
                    if c % 10 == 0 then
                        print("[BS COIN] AFK-фарм: собрано " .. c)
                    end
                end
            end
        end
    end
    return n
end

-- СБОР ТЕЛЕПОРТОМ. Монета на сервере остаётся на исходной позиции:
-- клиентский PivotTo её не двигает. Поэтому переносим ПЕРСОНАЖА к
-- COIN.origin (запомненной до магнита), ждём репликацию, жмём prompt
-- и возвращаемся. За один раз — одна монета, иначе персонажа будет
-- швырять между точками.
function COIN.blinkCollect(coin, now)
    -- Телепорт-сбор включается тумблером «Сбор телепортом к монете»
    -- ИЛИ активным AFK-фармом: без телепорта сервер не засчитывает
    -- монету, до которой игрок не дошёл.
    if G.BS.CoinBlink == false and G.BS.CoinFarm == false then return false end
    if COIN.blinkBusy or G.BS._tpBusy then return false end
    local ch = LP and LP.Character
    local hum = ch and ch:FindFirstChildOfClass("Humanoid")
    local root = ch and ch:FindFirstChild("HumanoidRootPart")
    if not (ch and root and hum and hum.Health > 0) then return false end
    local part = coinPart(coin)
    if not part or not part.Parent then return false end
    local origin = COIN.origin[coin]
    if not origin then
        local cf0 = coinPivot(coin)
        origin = (cf0 and cf0.Position) or part.Position
        COIN.origin[coin] = origin
        COIN.originCF[coin] = cf0
    end
    local originCF = COIN.originCF[coin] or CFrame.new(origin)
    local radius = tonumber(G.BS.CoinMagnetRadius) or 250
    -- AFK-фарм работает по всей карте: радиус телепорта больше.
    if G.BS.CoinFarm ~= false then
        local fr = tonumber(G.BS.CoinFarmRange) or 700
        if fr > radius then radius = fr end
    end
    local dist = (origin - root.Position).Magnitude
    if dist > radius + 30 then return false end
    if now - (COIN.blinkAt or 0) < 0.75 then return false end
    -- Если у монеты нет ни prompt, ни click, ни touch и ремоут не выучен,
    -- телепорт всё равно ничего не даст — не дёргаем персонажа зря.
    local prompt, click = coinPromptAndClick(coin)
    local hasTouch = coinFn("firetouchinterest") ~= nil
    local hasRemote = (COIN.remote and COIN.remote.Parent) or COIN.learned
    if not prompt and not click and not hasTouch and not hasRemote then
        return false
    end
    COIN.blinkAt = now
    COIN.blinkBusy = true
    G.BS._tpBusy = true
    -- Диагностика именно попытки сбора: раньше лог печатался даже когда
    -- телепорт был занят прострелом и blink не запускался.
    if not COIN.firedLog[coin] then
        COIN.firedLog[coin] = true
        local nm = "?"
        pcall(function() nm = coin:GetFullName() end)
        print(string.format("[BS COIN] сбор: %s | серверная дистанция %.0f",
            nm, dist))
        task.delay(1.6, function()
            if coin.Parent then
                print("[BS COIN] НЕ собралась: " .. nm
                    .. " (prompt/click/touch не сработали)")
            else
                print("[BS COIN] собрана: " .. nm)
            end
        end)
    end

    local hold = prompt and tonumber(prompt.HoldDuration) or 0
    -- Держим персонажа у монеты, пока prompt не доиграет hold. Иначе
    -- InputHoldEnd уходил уже после телепорта назад, и сервер отклонял
    -- сбор по дистанции.
    local stay = math.clamp(hold + 0.18, 0.16, 1.5)

    local oldCF = root.CFrame
    local oldVel = root.AssemblyLinearVelocity
    local spot = origin + Vector3.new(0, 2.4, 0)

    task.spawn(function()
        local okBody, errBody = pcall(function()
            -- Возвращаем монету на серверную позицию: prompt проверяет
            -- дистанцию по ЛОКАЛЬНОЙ позиции объекта, а магнит утащил её
            -- к игроку. Без этого InputHoldBegin считал цель далёкой.
            if coin.Parent then
                pcall(function()
                    if coin:IsA("Model") then
                        coin:PivotTo(originCF)
                    elseif coin:IsA("BasePart") then
                        coin.CFrame = originCF
                    end
                end)
            end
            root.CFrame = CFrame.new(spot)
            -- 0.22 c: сервер должен увидеть новую позицию персонажа.
            task.wait(0.22)
            if coin.Parent then pcall(fireCoinPrompts, coin) end
            task.wait(stay)
        end)
        -- Возвращаем только если игрок всё ещё там, куда мы его ставили:
        -- иначе можно откатить его движение/респавн.
        pcall(function()
            if root.Parent and ch.Parent and hum.Health > 0 then
                if (root.Position - spot).Magnitude < 16 then
                    root.CFrame = oldCF
                    root.AssemblyLinearVelocity = oldVel
                end
            end
        end)
        -- Флаги сбрасываем ВСЕГДА: ошибка внутри не должна навсегда
        -- заблокировать и телепорт-сбор, и прострел.
        COIN.blinkBusy = false
        G.BS._tpBusy = false
        if not okBody then
            print("[BS COIN] blink: " .. tostring(errBody))
        end
    end)
    return true
end

-- ОДИН РАЗ печатаем структуру первой монеты: по ней видно, чем игра
-- собирает монеты (ProximityPrompt / ClickDetector / скрипт / атрибуты).
function COIN.dumpOnce(coin)
    if COIN.dumped or not coin or not coin.Parent then return end
    COIN.dumped = true
    print("[BS COIN] структура: " .. coin:GetFullName() .. " (" .. coin.ClassName .. ")")
    local p = coinPart(coin)
    if p then
        local myRoot = LP and LP.Character and LP.Character:FindFirstChild("HumanoidRootPart")
        local dist = myRoot and (p.Position - myRoot.Position).Magnitude or -1
        print(string.format(
            "  часть=%s | Anchored=%s | CanCollide=%s | Size=%.1f,%.1f,%.1f | дистанция=%.0f",
            p:GetFullName(), tostring(p.Anchored), tostring(p.CanCollide),
            p.Size.X, p.Size.Y, p.Size.Z, dist))
    end
    local attrs = {}
    pcall(function()
        local a = coin:GetAttributes()
        for k, v in pairs(a) do attrs[#attrs + 1] = tostring(k) .. "=" .. tostring(v) end
    end)
    table.sort(attrs)
    if #attrs > 0 then print("  атрибуты: " .. table.concat(attrs, ", ")) end
    local shown = 0
    for _, d in ipairs(coin:GetDescendants()) do
        if shown < 25 then
            print("  " .. d.ClassName .. " " .. d.Name)
            shown = shown + 1
        end
        if d:IsA("ProximityPrompt") then
            print(string.format(
                "  PROMPT %s | Enabled=%s | Hold=%.2f | MaxDist=%.1f | Action=%s | Object=%s | LOS=%s",
                d:GetFullName(), tostring(d.Enabled), tonumber(d.HoldDuration) or -1,
                tonumber(d.MaxActivationDistance) or -1, tostring(d.ActionText),
                tostring(d.ObjectText), tostring(d.RequiresLineOfSight)))
        elseif d:IsA("ClickDetector") then
            print("  CLICK " .. d:GetFullName()
                .. " | MaxDist=" .. tostring(d.MaxActivationDistance))
        end
    end
    print("[BS COIN] структура выведена один раз")
end

function COIN.magnetTick(now)
    -- v11.33: магнит (двигание монет к игроку) выключен по умолчанию,
    -- но СБОР продолжает работать: поэтому список монет, исходные
    -- позиции, prompt и телепорт-сбор считаются всегда.
    local ch = LP and LP.Character
    local root = ch and ch:FindFirstChild("HumanoidRootPart")
    if not root then return end
    COIN.nearPlayer = false
    -- список монет обновляем раз в секунду, а не каждый кадр
    if now - COIN.magnetAt > 1 then
        COIN.magnetAt = now
        COIN.magnetList = {}
        local folder = COIN.findFolder()
        if folder then
            for _, d in ipairs(folder:GetDescendants()) do
                if d:IsA("Model") and d.Name == "CoinPickup" and d.Parent then
                    COIN.magnetList[#COIN.magnetList + 1] = d
                    -- ВАЖНО: исходную позицию запоминаем ДО первого
                    -- PivotTo. Клиентский магнит двигает монету только
                    -- у нас; на сервере она остаётся здесь.
                    if not COIN.origin[d] then
                        local cf = coinPivot(d)
                        if cf then
                            COIN.origin[d] = cf.Position
                            COIN.originCF[d] = cf
                        end
                    end
                end
            end
        end
        if not COIN.dumped and #COIN.magnetList > 0 then
            pcall(COIN.dumpOnce, COIN.magnetList[1])
        end
    end
    local radius = tonumber(G.BS.CoinMagnetRadius) or 250
    -- AFK-фарм ищет монеты по всей карте, а не только в радиусе магнита.
    if G.BS.CoinFarm == true then
        radius = math.max(radius, tonumber(G.BS.CoinFarmRange) or 700)
    end
    local power = math.clamp(tonumber(G.BS.CoinMagnetPower) or 0.45, 0.1, 1)
    local rp = root.Position
    local bestCoin, bestDist
    for i = 1, #COIN.magnetList do
        local coin = COIN.magnetList[i]
        -- После удаления монеты в списке остаётся дырка (nil), пока
        -- список не пересоберётся через секунду. Без проверки `coin`
        -- следующий тик падал на coin.Parent и магнит замирал.
        if coin and coin.Parent then
            local part = coinPart(coin)
            if part and part.Parent then
                if not COIN.origin[coin] then
                    local cf0 = coinPivot(coin)
                    COIN.origin[coin] = cf0 and cf0.Position or part.Position
                    COIN.originCF[coin] = cf0
                end
                -- МОНЕТУ ПЕРЕСТАВИЛИ (сброс на новое место): обновляем
                -- исходную позицию, иначе скрипт бежит туда, где монеты
                -- уже нет, и фарм стоит.
                local o0 = COIN.origin[coin]
                if o0 and (part.Position - o0).Magnitude > 3 then
                    local cf0 = coinPivot(coin)
                    COIN.origin[coin] = cf0 and cf0.Position or part.Position
                    COIN.originCF[coin] = cf0
                end
                local serverPos = COIN.origin[coin]
                local serverDist = (serverPos - rp).Magnitude
                if serverDist <= 20 then COIN.nearPlayer = true end
                if serverDist <= radius then
                    if not bestCoin or serverDist < bestDist then
                        bestCoin, bestDist = coin, serverDist
                    end
                end

                -- ВИЗУАЛЬНЫЙ МАГНИТ: монета летит к игроку на нашем
                -- клиенте. Выключен по умолчанию (v11.33), но код жив.
                local delta = rp - part.Position
                local dist = delta.Magnitude
                if G.BS.CoinMagnet ~= false and dist <= radius and dist > 2.5 then
                    local goal = rp + Vector3.new(
                        math.sin(i * 1.7) * 1.2,
                        1.3,
                        math.cos(i * 1.7) * 1.2)
                    local cf = coinPivot(coin)
                    if cf then
                        -- Сохраняем вращение монеты: иначе она резко
                        -- поворачивается в ноль и выглядит сломанно.
                        local target = CFrame.new(goal) * (cf - cf.Position)
                        if coin:IsA("Model") then
                            pcall(function() coin:PivotTo(cf:Lerp(target, power)) end)
                        elseif coin:IsA("BasePart") then
                            pcall(function() coin.CFrame = cf:Lerp(target, power) end)
                        end
                    end
                end

                -- Если персонаж УЖЕ у серверной позиции монеты — жмём
                -- prompt без телепорта (например, подошёл сам).
                if G.BS.CoinAuto ~= false and serverDist <= 12
                   and now - (COIN.tryAt[coin] or 0) > 1.0 then
                    COIN.tryAt[coin] = now
                    pcall(fireCoinPrompts, coin)
                end
            end
        else
            if coin then
                COIN.magnetList[i] = nil
                COIN.tryAt[coin] = nil
                COIN.firedLog[coin] = nil
                COIN.promptCheck[coin] = nil
            end
        end
    end

    -- AFK-ФАРМ (v11.36): скрипт сам бегает/телепортируется к монетам и
    -- собирает их по кругу, пока игра сбрасывает новые. Поэтому
    -- телепорт-сбор работает и при включённом фарме.
    if G.BS.CoinAuto ~= false
       and (G.BS.CoinBlink ~= false or G.BS.CoinFarm ~= false)
       and bestCoin and bestDist and bestDist > 12 then
        pcall(COIN.blinkCollect, bestCoin, now)
    end
end

function COIN.scanRemotes()
    print("[BS COIN] папка CoinPickups: " .. tostring(COIN.findFolder() ~= nil))
    print("[BS COIN] выученный ремоут: " .. tostring(COIN.remote and COIN.remote:GetFullName() or "нет"))
    local remote = COIN.findRemote()
    print("[BS COIN] авто-найденный ремоут: " .. tostring(remote and remote:GetFullName() or "нет"))
    if COIN.args then
        print("[BS COIN] аргументы: n=" .. tostring(COIN.args.n)
            .. " coinArgIdx=" .. tostring(COIN.argIdx) .. " type=" .. tostring(COIN.argType))
    end
    local folder = COIN.findFolder()
    if folder then
        local cnt = 0
        for _, c in ipairs(folder:GetDescendants()) do
            if c:IsA("Model") and c.Name == "CoinPickup" then cnt = cnt + 1 end
        end
        print("[BS COIN] монет найдено: " .. cnt)
    end
end

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
    local lbl = gui:FindFirstChild("Lbl")
    if not lbl then
        lbl = Instance.new("TextLabel", gui)
        lbl.Name = "Lbl"
    end
    return gui, lbl
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
    -- Если Drawing.new уже падал, не пытаемся создавать 12 линий каждый
    -- кадр: это быстро упирается в лимит объектов исполнителя.
    if os.clock() < (G.BS._boxRetryAt or 0) then return nil end
    local b = {}
    b.lines = {}
    -- 12 линий: 4 — рамка, 8 — уголки, 12 — 3D-коробка (по рёбрам).
    for i = 1, 12 do
        local ok, ln = pcall(function() return Drawing.new("Line") end)
        if not ok or not ln then
            -- Не бросаем уже созданные линии: иначе при каждом кадре
            -- создаются новые Drawing и упираются в лимит исполнителя.
            for j = 1, i - 1 do
                if b.lines[j] then pcall(function() b.lines[j]:Remove() end) end
            end
            G.BS._boxRetryAt = os.clock() + 5
            return nil
        end
        ln.Visible   = false
        ln.Thickness = tonumber(G.BS.BoxThick) or 2
        ln.Color     = Color3.new(1, 1, 1)
        b.lines[i] = ln
    end
    return b
end

-- КОРОБКА ESP. Размер И ЦЕНТР берутся из Model:GetBoundingBox() — это
-- готовый параллелепипед вокруг ВСЕЙ модели. Раньше были GetExtentsSize
-- + GetPivot: у многих ригов pivot стоит на голове, поэтому 3D-коробка
-- рисовалась вокруг головы, а не вокруг тела. GetBoundingBox() возвращает
-- центр габаритов и их ориентацию, так что коробка облегает игрока
-- целиком и поворачивается вместе с ним.
-- Стили: «Рамка» (2D), «Уголки», «3D-коробка» (12 рёбер).
local function drawBox(b, root, cam)
    if not b or not b.lines then return end
    local camera = cam or workspace.CurrentCamera
    local function hideAll()
        for i = 1, #b.lines do
            if b.lines[i] then b.lines[i].Visible = false end
        end
    end
    if not camera or not root or not root.Parent then
        hideAll()
        return
    end
    local ch = root.Parent
    local nowB = os.clock()
    -- Пересчёт ГАБАРИТОВ: при смене персонажа и раз в 0.4 с. Позицию и
    -- поворот берём с корня КАЖДЫЙ кадр: раньше кэшировался весь CFrame,
    -- и коробка дёргалась рывками 2.5 раза в секунду.
    if b.char ~= ch or nowB - (b.sizeAt or 0) > 0.4 then
        b.char = ch
        b.sizeAt = nowB
        b.size = nil
        b.offLocal = nil
        if ch and ch:IsA("Model") then
            local okB, cfB, szB = pcall(function()
                local c, s = ch:GetBoundingBox()
                return c, s
            end)
            if okB and typeof(cfB) == "CFrame"
               and typeof(szB) == "Vector3" and szB.Magnitude > 0.1 then
                b.size = szB
                -- Смещение центра габаритов от HumanoidRootPart в локальных
                -- координатах. Позиция обновляется каждый кадр, поэтому
                -- коробка плавно едет за игроком и не отстаёт.
                local okO, off = pcall(function()
                    return root.CFrame:PointToObjectSpace(cfB.Position)
                end)
                if okO and typeof(off) == "Vector3" then
                    b.offLocal = off
                end
            end
        end
    end
    local cf = root.CFrame * CFrame.new(b.offLocal or Vector3.new(0, 0, 0))
    -- Запасной вариант, если GetBoundingBox не сработал.
    local size = b.size or Vector3.new(2.6, 5.8, 2.2)
    -- Небольшой запас от модели (настраивается, 3D-стиль).
    local hw = size.X * 0.5 + (tonumber(G.BS.BoxMargin) or 0)
    local hh = size.Y * 0.5 + (tonumber(G.BS.BoxMargin) or 0)
    local hd = size.Z * 0.5 + (tonumber(G.BS.BoxMargin) or 0)
    local C = {
        cf * Vector3.new(-hw, -hh, -hd), cf * Vector3.new(hw, -hh, -hd),
        cf * Vector3.new(hw, -hh, hd), cf * Vector3.new(-hw, -hh, hd),
        cf * Vector3.new(-hw, hh, -hd), cf * Vector3.new(hw, hh, -hd),
        cf * Vector3.new(hw, hh, hd), cf * Vector3.new(-hw, hh, hd),
    }
    local proj = {}
    local anyFront = false
    for i = 1, 8 do
        local sp = camera:WorldToViewportPoint(C[i])
        proj[i] = sp
        if sp.Z > 0 then anyFront = true end
    end
    if not anyFront then
        hideAll()
        return
    end
    -- Затухание по дистанции: ближние яркие, дальние почти прозрачные.
    local fade = 0
    if G.BS.DistFade then
        local cpos = camera.CFrame and camera.CFrame.Position
        if cpos then
            local dist = (cf.Position - cpos).Magnitude
            fade = math.clamp((dist - 70) / 180, 0, 0.85)
        end
    end
    local alpha = tonumber(G.BS.BoxAlpha) or 0
    if alpha < 0 then alpha = 0 elseif alpha > 0.9 then alpha = 0.9 end
    local trans = math.clamp(fade + alpha, 0, 1)
    local col = b.color or Color3.new(1, 1, 1)
    local thick = tonumber(G.BS.BoxThick) or 2
    local style = G.BS.BoxStyle or "Рамка"

    local function setLine(i, a, c)
        local ln = b.lines[i]
        if not ln then return end
        ln.From = a
        ln.To = c
        ln.Color = col
        ln.Thickness = thick
        ln.Transparency = trans
        ln.Visible = true
    end
    local function hideFrom(i)
        for k = i, #b.lines do
            if b.lines[k] then b.lines[k].Visible = false end
        end
    end

    -- 3D-КОРОБКА: 12 рёбер настоящего параллелепипеда вокруг ВСЕГО тела.
    -- Рисуем каждое ребро отдельно: если один из углов ушёл за камеру,
    -- прячем только это ребро, а не всю коробку (раньше при allFront
    -- 3D-режим отключался и вместо него рисовалась плоская рамка).
    -- Дальние рёбра бледнее и тоньше — коробка читается объёмно.
    if style == "3D-коробка" then
        local idx = { {1,2},{2,3},{3,4},{4,1},{5,6},{6,7},{7,8},{8,5},
                      {1,5},{2,6},{3,7},{4,8} }
        for i = 1, 12 do
            local ln = b.lines[i]
            local a = proj[idx[i][1]]
            local c = proj[idx[i][2]]
            if ln and a.Z > 0 and c.Z > 0 then
                local depth = (a.Z + c.Z) * 0.5
                local far01 = math.clamp((depth - 14) / 70, 0, 1)
                ln.From = Vector2.new(a.X, a.Y)
                ln.To = Vector2.new(c.X, c.Y)
                ln.Color = col
                ln.Thickness = math.max(1, thick - (far01 > 0.6 and 1 or 0))
                ln.Transparency = math.clamp(trans + far01 * 0.4, 0, 0.97)
                ln.Visible = true
            elseif ln then
                ln.Visible = false
            end
        end
        return
    end

    -- ЭКРАННЫЙ ПРЯМОУГОЛЬНИК по видимым углам.
    local minX, maxX, minY, maxY = math.huge, -math.huge, math.huge, -math.huge
    for i = 1, 8 do
        local sp = proj[i]
        if sp.Z > 0 then
            if sp.X < minX then minX = sp.X end
            if sp.X > maxX then maxX = sp.X end
            if sp.Y < minY then minY = sp.Y end
            if sp.Y > maxY then maxY = sp.Y end
        end
    end
    if minX > maxX then hideAll() return end
    local pad = tonumber(G.BS.BoxPad) or 4
    if pad < 0 then pad = 0 elseif pad > 60 then pad = 60 end
    minX = minX - pad
    maxX = maxX + pad
    minY = minY - pad
    maxY = maxY + pad
    -- Минимальный размер: коробка должна быть видна всегда.
    if maxX - minX < 10 then
        local mid = (minX + maxX) * 0.5
        minX, maxX = mid - 5, mid + 5
    end
    if maxY - minY < 18 then
        local mid = (minY + maxY) * 0.5
        minY, maxY = mid - 9, mid + 9
    end

    -- УГОЛКИ: по две короткие линии на каждый угол. Не закрывают модель
    -- и читаются на любом фоне.
    if style == "Уголки" then
        local len = math.clamp(math.min(maxX - minX, maxY - minY) * 0.28, 5, 26)
        local corners = {
            { Vector2.new(minX, minY), Vector2.new(minX + len, minY), Vector2.new(minX, minY + len) },
            { Vector2.new(maxX, minY), Vector2.new(maxX - len, minY), Vector2.new(maxX, minY + len) },
            { Vector2.new(maxX, maxY), Vector2.new(maxX - len, maxY), Vector2.new(maxX, maxY - len) },
            { Vector2.new(minX, maxY), Vector2.new(minX + len, maxY), Vector2.new(minX, maxY - len) },
        }
        for i = 1, 4 do
            local c = corners[i]
            setLine(i * 2 - 1, c[1], c[2])
            setLine(i * 2, c[1], c[3])
        end
        hideFrom(9)
        return
    end

    -- РАМКА: стороны с небольшим зазором по углам — выглядит как
    -- аккуратная HUD-рамка, а не как дешёвая обводка.
    local gap = math.clamp(math.min(maxX - minX, maxY - minY) * 0.12, 2, 12)
    local pts = {
        Vector2.new(minX + gap, minY), Vector2.new(maxX - gap, minY),
        Vector2.new(maxX, minY + gap), Vector2.new(maxX, maxY - gap),
        Vector2.new(maxX - gap, maxY), Vector2.new(minX + gap, maxY),
        Vector2.new(minX, maxY - gap), Vector2.new(minX, minY + gap),
    }
    for i = 1, 4 do
        local a = pts[(i - 1) * 2 + 1]
        local c = pts[(i - 1) * 2 + 2]
        setLine(i, a, c)
    end
    hideFrom(5)
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
--  ДОПОЛНИТЕЛЬНЫЕ ВИЗУАЛЫ: трейсеры, скелет, полоски HP, стрелки,
--  chams, прицел, круги, подсветка ящиков/монет, счётчики.
-- ============================================================
do
local VIS = {}
local VDRAW
do
    local ok = pcall(function() return Drawing.new("Line") end)
    VDRAW = ok
end

local function vLine()
    if not VDRAW then return nil end
    local ok, l = pcall(function() return Drawing.new("Line") end)
    if ok and l then l.Visible = false; return l end
    return nil
end
local function vSquare()
    if not VDRAW then return nil end
    local ok, s = pcall(function() return Drawing.new("Square") end)
    if ok and s then s.Visible = false; return s end
    return nil
end
local function vCircle()
    if not VDRAW then return nil end
    local ok, c = pcall(function() return Drawing.new("Circle") end)
    if ok and c then c.Visible = false; return c end
    return nil
end
local function vText()
    if not VDRAW then return nil end
    local ok, t = pcall(function() return Drawing.new("Text") end)
    if ok and t then t.Visible = false; return t end
    return nil
end

local VMAX = 20
local vpool = {}
for i = 1, VMAX do
    vpool[i] = {
        skeleton = {},
        hpBg = vSquare(),
        hpBorder = vSquare(),
        hpFg = vSquare(),
        hpText = vText(),
        arrow = vLine(),
        headBox = vSquare(),
        snap = vLine(),
        -- v11.39: стрелка-линия — свечение, тёмная обводка и два уса.
        snapGlow = vLine(),
        snapOut = vLine(),
        snapH1 = vLine(),
        snapH2 = vLine(),
        -- стрелка у края экрана (цель за кадром) — тоже с усами.
        arrowOut = vLine(),
        arrowH1 = vLine(),
        arrowH2 = vLine(),
        aura = {},
        auraOn = false,
    }
end
-- Плавная полоска HP и вспышка при уроне (v11.34).
local hpSmooth = {}
local hpPrev = {}
local hpFlash = {}

local aimLine = vLine()
-- v11.39: линия аимлока тоже стала стрелкой — свечение, обводка, усы.
local aimGlow = vLine()
local aimOut = vLine()
local aimH1 = vLine()
local aimH2 = vLine()
-- КОЛЬЦО ЗАХВАТА: показывает, на кого СЕЙЧАС работает аймлок.
-- Тонкое кольцо вокруг головы + 4 вращающиеся засечки + анимация
-- захвата (при смене цели кольцо схлопывается на место).
local targetRing = vCircle()
local targetTicks = { vLine(), vLine(), vLine(), vLine() }
local ringKey = nil
local ringAt = 0
local crossLines = {}   -- ПРИЦЕЛ УДАЛЁН (v11.32): лишние линии в центре экрана


local crateHL = {}
local coinHL = {}
local lastHealth = {}
local kills = 0

-- v11.27: цифры урона, стрелки звука, миникарта, полоски.
local dmgNums = {}
local soundArrows = {}
local minimapBg = vSquare()
local minimapBorder = vSquare()
local minimapDots = {}
local minimapSelf = vCircle()
local tracerLine = vLine()
local tracerT0 = 0
local tracerFrom, tracerTo
-- v11.31: линии между вампирами (до 16 отрезков, создаются по мере
-- необходимости и переиспользуются).
local vampLinks = {}

local function vProj(cam, pos)
    local ok, sp = pcall(function() return cam:WorldToViewportPoint(pos) end)
    if not ok or not sp then return nil end
    return sp
end

local function vSetLine(l, a, b, color, thickness)
    if not l then return end
    l.From = a
    l.To = b
    l.Color = color
    l.Thickness = thickness or 1
    l.Visible = true
end

local function vHideLine(l)
    if l then l.Visible = false end
end

local function vHideSquare(s)
    if s then s.Visible = false end
end

local function vHideCircle(c)
    if c then c.Visible = false end
end

local function vHideText(t)
    if t then t.Visible = false end
end

-- ПОДСВЕТКА УЛИК УДАЛЕНА (v11.32) по просьбе: лишние зелёные шары
-- по всей карте мешали читать ESP.

function VIS.resetKills() kills = 0 end
function VIS.addKill() kills = kills + 1 end
function VIS.getKills() return kills end

-- Полное снятие всех Drawing/Highlight объектов модуля. Вызывается из
-- G.BS_Stop, иначе после остановки скрипта прицел, миникарта, полоски и
-- цифры урона остаются висеть на экране.
function VIS.destroy()
    local function rm(o)
        if not o then return end
        pcall(function() o:Remove() end)
        pcall(function() o:Destroy() end)
    end
    for i = 1, #crossLines do rm(crossLines[i]) end
    rm(aimLine)
    rm(aimGlow); rm(aimOut); rm(aimH1); rm(aimH2)
    for i = 1, #vpool do
        local p = vpool[i]
        for j = 1, #(p.skeleton or {}) do rm(p.skeleton[j]) end
        for j = 1, #(p.aura or {}) do rm(p.aura[j]) end
        rm(p.hpBg); rm(p.hpBorder); rm(p.hpFg); rm(p.hpText); rm(p.arrow); rm(p.headBox)
        rm(p.snap); rm(p.snapGlow); rm(p.snapOut); rm(p.snapH1); rm(p.snapH2)
        rm(p.arrowOut); rm(p.arrowH1); rm(p.arrowH2)
    end
    for i = 1, #dmgNums do rm(dmgNums[i].obj) end
    for i = 1, #soundArrows do rm(soundArrows[i]) end
    for i = 1, #vampLinks do rm(vampLinks[i]) end
    for i = 1, #minimapDots do rm(minimapDots[i]) end
    rm(minimapBg); rm(minimapBorder); rm(minimapSelf)
    rm(tracerLine)
    rm(targetRing)
    for i = 1, 4 do rm(targetTicks[i]) end
    tracerFrom, tracerTo, tracerT0 = nil, nil, 0
    for _, tbl in pairs({ crateHL, coinHL }) do
        for _, h in pairs(tbl) do
            pcall(function() h:Destroy() end)
        end
    end
    crossLines = {}
    vpool = {}
    dmgNums = {}
    soundArrows = {}
    vampLinks = {}
    minimapDots = {}
    crateHL = {}
    coinHL = {}
    lastHealth = {}
end

-- Всплывающая цифра урона (вызывается из хука попаданий).
function VIS.spawnDmgNum(pos, amount)
    if not G.BS.DamageNumbers then return end
    local t = vText()
    if not t then return end
    t.Text = tostring(amount or "HIT")
    t.Size = 16
    t.Color = safeColor(G.BS.DmgNumColor, Color3.new(1, 1, 0))
    t.Center = true
    t.Outline = true
    t.Position = Vector2.new(0, 0)
    t.Visible = true
    dmgNums[#dmgNums + 1] = { obj = t, pos = pos, t0 = os.clock() }
    if #dmgNums > 20 then
        local old = table.remove(dmgNums, 1)
        pcall(function() old.obj:Remove() end)
    end
end

-- Трейсер выстрела: короткая линия от ствола/головы до точки попадания.
function VIS.spawnTracer(from, to)
    if not G.BS.ShotTracer or not from or not to then return end
    tracerFrom, tracerTo = from, to
    tracerT0 = os.clock()
end

-- ОТКУДА ИДЁТ ЛИНИЯ НА ЭКРАНЕ: центр / низ / верх. Настройки были
-- объявлены, но на отрисовку не влияли — теперь работают.
local function screenOrigin(kind, cx, cy, vp)
    if kind == "Низ экрана" then return Vector2.new(cx, vp.Y) end
    if kind == "Верх экрана" then return Vector2.new(cx, 0) end
    return Vector2.new(cx, cy)
end

-- СТРЕЛКА (v11.39). Раньше линии были одиночными штрихами в 1 px —
-- тонкими и невзрачными. Теперь у стрелки есть свечение, тёмная
-- обводка, толстый ствол и наконечник из двух «усов». Так сразу
-- видно, куда смотреть, и не приходится вглядываться в экран.
local function drawArrowParts(glow, out, shaft, h1, h2, from, to, color, thick, alpha)
    local function hideAll()
        vHideLine(glow); vHideLine(out); vHideLine(shaft)
        vHideLine(h1); vHideLine(h2)
    end
    if not from or not to or not shaft then hideAll() return end
    local dx, dy = to.X - from.X, to.Y - from.Y
    local len = math.sqrt(dx * dx + dy * dy)
    if len < 6 then hideAll() return end
    local ux, uy = dx / len, dy / len
    -- v11.43: наконечник и свечение зависят от толщины — на 1–2 px
    -- стрелка становится ЛЁГКОЙ и узкой, на 6 px остаётся заметной.
    local t = math.clamp(tonumber(thick) or 2, 1, 6)
    local hs = math.clamp(t / 3, 0.5, 1.5)
    local head = math.clamp(len * 0.18, 16, 34) * hs
    local shaftTo = Vector2.new(to.X - ux * head * 0.85, to.Y - uy * head * 0.85)
    -- свечение под линией (раньше +8 px — слишком широко)
    vSetLine(glow, from, shaftTo, color, t + 4)
    if glow then glow.Transparency = 0.85 end
    -- тёмная обводка, чтобы стрелка читалась на любом фоне
    vSetLine(out, from, shaftTo, Color3.new(0, 0, 0), t + 2)
    if out then out.Transparency = 0.5 end
    -- сам ствол
    vSetLine(shaft, from, shaftTo, color, t)
    if shaft then shaft.Transparency = alpha end
    -- наконечник
    local ang = math.atan2(uy, ux)
    local s1, s2 = ang + math.rad(25), ang - math.rad(25)
    vSetLine(h1, to,
        Vector2.new(to.X - math.cos(s1) * head, to.Y - math.sin(s1) * head),
        color, math.max(t, 1))
    vSetLine(h2, to,
        Vector2.new(to.X - math.cos(s2) * head, to.Y - math.sin(s2) * head),
        color, math.max(t, 1))
    if h1 then h1.Transparency = alpha end
    if h2 then h2.Transparency = alpha end
end

local function drawSnapArrow(p, from, to, color, thick, alpha)
    drawArrowParts(p.snapGlow, p.snapOut, p.snap, p.snapH1, p.snapH2,
        from, to, color, thick, alpha)
end

local function hideSnapArrow(p)
    vHideLine(p.snap); vHideLine(p.snapGlow); vHideLine(p.snapOut)
    vHideLine(p.snapH1); vHideLine(p.snapH2)
end

local function drawAimArrow(from, to, color, thick, alpha)
    drawArrowParts(aimGlow, aimOut, aimLine, aimH1, aimH2,
        from, to, color, thick, alpha)
end

local function hideAimArrow()
    vHideLine(aimLine); vHideLine(aimGlow); vHideLine(aimOut)
    vHideLine(aimH1); vHideLine(aimH2)
end

-- Короткая стрелка у КРАЯ ЭКРАНА (цель за кадром). v11.43: меньше
-- и пропорциональнее толщине.
local function drawEdgeArrow(p, tip, ux, uy, color, thick, alpha)
    local t = math.clamp(tonumber(thick) or 2, 1, 6)
    local len = 22 + t * 3
    local from = Vector2.new(tip.X - ux * len, tip.Y - uy * len)
    vSetLine(p.arrowOut, from, tip, Color3.new(0, 0, 0), t + 2)
    if p.arrowOut then p.arrowOut.Transparency = 0.5 end
    vSetLine(p.arrow, from, tip, color, t)
    if p.arrow then p.arrow.Transparency = alpha end
    local ang = math.atan2(uy, ux)
    local hl = math.clamp(len * 0.4, 6, 16)
    local s1, s2 = ang + math.rad(28), ang - math.rad(28)
    vSetLine(p.arrowH1, tip,
        Vector2.new(tip.X - math.cos(s1) * hl, tip.Y - math.sin(s1) * hl),
        color, thick + 1)
    vSetLine(p.arrowH2, tip,
        Vector2.new(tip.X - math.cos(s2) * hl, tip.Y - math.sin(s2) * hl),
        color, thick + 1)
    if p.arrowH1 then p.arrowH1.Transparency = alpha end
    if p.arrowH2 then p.arrowH2.Transparency = alpha end
end

local function hideEdgeArrow(p)
    vHideLine(p.arrow); vHideLine(p.arrowOut)
    vHideLine(p.arrowH1); vHideLine(p.arrowH2)
end

function VIS.update(cam, myRoot, by, locked)
    local vp = cam.ViewportSize
    local cx, cy = vp.X * 0.5, vp.Y * 0.5
    local camPos = cam.CFrame.Position

    -- 0) ВРЕМЯ КАДРА
    local nowT = os.clock()

    -- Без Drawing визуалы рисовать нечем.
    if not VDRAW then return end

    -- 1) ПРИЦЕЛ УДАЛЁН (v11.32) по просьбе: в центре экрана больше нет
    -- ни «3 жёлтых полосок», ни вспышки при попадании.

    -- 2) ЛИНИЯ К ЦЕЛИ (трейсер)
    -- locked — это Player (так его возвращает pickTarget), а не часть.
    -- Раньше здесь было locked.Position: у Player такого свойства нет,
    -- ошибка рвала весь VIS.update через pcall, и ВСЕ визуалы молчали.
    local lockedPart
    if locked and locked.Parent then
        local lch = locked.Character
        lockedPart = lch and (lch:FindFirstChild("Head")
            or lch:FindFirstChild("HumanoidRootPart"))
    end
    if G.BS.AimLine and lockedPart and myRoot then
        local sp = vProj(cam, lockedPart.Position)
        if sp and sp.Z > 0 then
            -- v11.39: линия аимлока — теперь стрелка к цели.
            drawAimArrow(
                screenOrigin(G.BS.AimLineFrom, cx, cy, vp),
                Vector2.new(sp.X, sp.Y),
                safeColor(G.BS.AimLineColor, Color3.new(1, 0, 0)),
                math.clamp(tonumber(G.BS.AimLineThick) or 2, 1, 6),
                math.clamp(tonumber(G.BS.AimLineAlpha) or 1, 0, 1))
        else
            hideAimArrow()
        end
    else
        hideAimArrow()
    end

    -- 2.2) КОЛЬЦО ЗАХВАТА: видно, на кого работает аймлок. Тонкое
    -- кольцо вокруг головы, 4 вращающиеся засечки и короткая анимация
    -- при смене цели.
    if G.BS.TargetRing ~= false and lockedPart and locked then
        local eT = by[locked]
        local roleT = eT and eT.role
        local colT
        if roleT == "vampire" then
            colT = safeColor(G.BS.VampColor, Color3.new(1, 0, 0))
        elseif roleT == "hunter" then
            colT = safeColor(G.BS.HunterColor, Color3.new(0, 0.7, 1))
        else
            colT = safeColor(G.BS.PlayerColor, Color3.new(1, 1, 1))
        end
        local spT = vProj(cam, lockedPart.Position)
        if spT and spT.Z > 0 then
            local distT = (lockedPart.Position - cam.CFrame.Position).Magnitude
            local r = (tonumber(G.BS.TargetRingSize) or 26)
                * (0.7 + math.clamp(distT / 90, 0, 1.3))
            -- АНИМАЦИЯ ЗАХВАТА: кольцо схлопывается на цель.
            if ringKey ~= locked then
                ringKey = locked
                ringAt = nowT
            end
            local age = nowT - ringAt
            local k = 1
            if G.BS.TargetLockAnim ~= false and age < 0.28 then
                k = 1 + (1 - age / 0.28) * 0.9
            end
            -- Короткая белая вспышка в момент захвата.
            local ringCol = colT
            if age < 0.16 then
                ringCol = colT:Lerp(Color3.new(1, 1, 1), 1 - age / 0.16)
            end
            if targetRing then
                targetRing.Position = Vector2.new(spT.X, spT.Y)
                -- ВАЖНО: у Drawing Circle нет свойства Size, только Radius.
                targetRing.Radius = r * k
                targetRing.Color = ringCol
                targetRing.Thickness = tonumber(G.BS.TargetRingThick) or 1
                targetRing.Filled = false
                targetRing.Transparency = 0.2
                targetRing.Visible = true
            end
            if G.BS.TargetTicks ~= false then
                local spd = tonumber(G.BS.TargetTickSpeed) or 1.1
                local ang0 = nowT * spd
                for i = 1, 4 do
                    local a = ang0 + (i - 1) * math.pi / 2
                    local ca, sa = math.cos(a), math.sin(a)
                    local inner = r * k * 1.16
                    local outer = r * k * 1.42
                    local l = targetTicks[i]
                    if l then
                        l.From = Vector2.new(spT.X + ca * inner, spT.Y + sa * inner)
                        l.To = Vector2.new(spT.X + ca * outer, spT.Y + sa * outer)
                        l.Color = ringCol
                        l.Thickness = 1
                        l.Transparency = 0.15
                        l.Visible = true
                    end
                end
            else
                for i = 1, 4 do vHideLine(targetTicks[i]) end
            end
        else
            vHideCircle(targetRing)
            for i = 1, 4 do vHideLine(targetTicks[i]) end
        end
    else
        vHideCircle(targetRing)
        for i = 1, 4 do vHideLine(targetTicks[i]) end
    end

    -- 2.5) ТРЕЙСЕР ВЫСТРЕЛА (от ствола до попадания)
    if G.BS.ShotTracer and tracerFrom and tracerTo and tracerT0 > 0 then
        local age = nowT - tracerT0
        local life = tonumber(G.BS.ShotTracerTime) or 0.25
        if age >= 0 and age <= life then
            local a = vProj(cam, tracerFrom)
            local b = vProj(cam, tracerTo)
            if a and b and a.Z > 0 and b.Z > 0 then
                if tracerLine then
                    tracerLine.Transparency = math.clamp(age / life, 0, 1)
                end
                vSetLine(tracerLine, Vector2.new(a.X, a.Y), Vector2.new(b.X, b.Y),
                    safeColor(G.BS.ShotTracerColor, Color3.new(1, 0.4, 0)),
                    tonumber(G.BS.ShotTracerThick) or 2)
            else
                vHideLine(tracerLine)
            end
        else
            vHideLine(tracerLine)
            if age > life then
                tracerFrom, tracerTo, tracerT0 = nil, nil, 0
            end
        end
    else
        vHideLine(tracerLine)
    end

    -- 3) СЧЁТЧИКИ
    local alive, total = 0, 0
    for plr, e in pairs(by) do
        local ch = e.char
        if ch and ch.Parent then
            total = total + 1
            local hum = ch:FindFirstChildOfClass("Humanoid")
            if hum then
                if hum.Health > 0 then alive = alive + 1 end
                local prev = lastHealth[plr]
                if prev and prev > 0 and hum.Health <= 0 then kills = kills + 1 end
                lastHealth[plr] = hum.Health
            end
        end
    end
    G.BS.PlayerCount = total
    G.BS.AliveCount = alive
    G.BS.Kills = kills

    -- 5) ИГРОКИ: скелет, HP, стрелки
    local idx = 0
    for tPlr, e in pairs(by) do
        idx = idx + 1
        if idx > VMAX then break end
        local ch = e.char
        local root = ch and ch:FindFirstChild("HumanoidRootPart")
        local p = vpool[idx]
        local role = e.role
        local show = (e.vis ~= false)
        local color
        if role == "vampire" then color = safeColor(G.BS.VampColor, Color3.new(1, 0, 0))
        elseif role == "hunter" then color = safeColor(G.BS.HunterColor, Color3.new(0, 0.7, 1))
        else color = safeColor(G.BS.PlayerColor, Color3.new(1, 1, 1)) end

        -- СКЕЛЕТ. Раньше он рисовался ВСЕГДА, и когда стоишь за спиной
        -- у игрока, получалась каша из линий. Теперь:
        --  - рисуется только дальше G.BS.SkelMinDist (по умолч. 12 st);
        --  - по желанию — только у цели аима;
        --  - мёртвые не рисуются.
        local skelOn = false
        if G.BS.Skeleton and show and ch and ch.Parent then
            local humS = ch:FindFirstChildOfClass("Humanoid")
            local alive = (not humS) or humS.Health > 0
            local far = true
            if root and cam and cam.CFrame then
                far = (root.Position - cam.CFrame.Position).Magnitude
                    >= (tonumber(G.BS.SkelMinDist) or 12)
            end
            local isTarget = true
            if G.BS.SkelOnlyTarget == true then
                isTarget = (locked == tPlr)
            end
            skelOn = alive and far and isTarget
        end
        if skelOn then
            local parts = {
                ch:FindFirstChild("Head"),
                ch:FindFirstChild("UpperTorso") or ch:FindFirstChild("Torso"),
                ch:FindFirstChild("LowerTorso") or ch:FindFirstChild("Torso"),
                ch:FindFirstChild("LeftUpperArm") or ch:FindFirstChild("Left Arm"),
                ch:FindFirstChild("RightUpperArm") or ch:FindFirstChild("Right Arm"),
                ch:FindFirstChild("LeftUpperLeg") or ch:FindFirstChild("LeftLeg"),
                ch:FindFirstChild("RightUpperLeg") or ch:FindFirstChild("RightLeg"),
            }
            local pts = {}
            for i = 1, 7 do
                local sp = parts[i] and vProj(cam, parts[i].Position)
                -- Точки за камерой дают зеркальные координаты и рисуют
                -- линии через весь экран — их просто не соединяем.
                pts[i] = (sp and sp.Z > 0) and Vector2.new(sp.X, sp.Y) or nil
            end
            local links = {{1,2},{2,3},{2,4},{2,5},{3,6},{3,7}}
            local thick = tonumber(G.BS.SkeletonThick) or 1
            for i = 1, 6 do
                local l = p.skeleton[i]
                if not l then
                    l = vLine()
                    p.skeleton[i] = l
                end
                local a = pts[links[i][1]]
                local b = pts[links[i][2]]
                if a and b then
                    vSetLine(l, a, b, color, thick)
                else
                    vHideLine(l)
                end
            end
        else
            for i = 1, #p.skeleton do vHideLine(p.skeleton[i]) end
        end

        -- ПОЛОСКА HP (v11.34, красивая): тёмная подложка, тонкая рамка,
        -- плавно падающая заливка по здоровью и короткая белая вспышка
        -- в момент урона. Раньше это был просто зелёный прямоугольник.
        if G.BS.HealthBars and show and ch and ch.Parent then
            local hum = ch:FindFirstChildOfClass("Humanoid")
            local head = ch:FindFirstChild("Head")
            if hum and head and hum.Health > 0 then
                local sp = vProj(cam, head.Position + Vector3.new(0, 0.5, 0))
                if sp and sp.Z > 0 then
                    local maxHp = hum.MaxHealth or 100
                    local hpPct = math.clamp(hum.Health / maxHp, 0, 1)
                    -- ПЛАВНО: полоска не прыгает, а плавно догоняет HP.
                    local cur = hpSmooth[tPlr]
                    if cur == nil then
                        cur = hpPct
                    else
                        cur = cur + (hpPct - cur) * 0.2
                    end
                    hpSmooth[tPlr] = cur
                    -- ВСПЫШКА ПРИ УРОНЕ.
                    local prevHp = hpPrev[tPlr]
                    if prevHp ~= nil and hpPct < prevHp - 0.001 then
                        hpFlash[tPlr] = nowT
                    end
                    hpPrev[tPlr] = hpPct

                    local w = tonumber(G.BS.HealthBarWidth) or 40
                    local h = tonumber(G.BS.HealthBarHeight) or 4
                    local x = sp.X - w * 0.5
                    local y = sp.Y - 18
                    if p.hpBg then
                        p.hpBg.Position = Vector2.new(x, y)
                        p.hpBg.Size = Vector2.new(w, h)
                        p.hpBg.Color = Color3.new(0, 0, 0)
                        p.hpBg.Filled = true
                        p.hpBg.Transparency = 0.35
                        p.hpBg.Visible = true
                    end
                    if p.hpBorder then
                        p.hpBorder.Position = Vector2.new(x - 1, y - 1)
                        p.hpBorder.Size = Vector2.new(w + 2, h + 2)
                        p.hpBorder.Color = Color3.new(1, 1, 1)
                        p.hpBorder.Filled = false
                        p.hpBorder.Thickness = 1
                        p.hpBorder.Transparency = 0.45
                        p.hpBorder.Visible = true
                    end
                    if p.hpFg then
                        local barCol
                        if hpPct > 0.5 then
                            barCol = Color3.fromRGB(80, 220, 110)
                        elseif hpPct > 0.25 then
                            barCol = Color3.fromRGB(255, 205, 70)
                        else
                            barCol = Color3.fromRGB(255, 80, 80)
                        end
                        local fl = hpFlash[tPlr]
                        if fl and (nowT - fl) < 0.18 then
                            barCol = Color3.new(1, 1, 1)
                        end
                        p.hpFg.Position = Vector2.new(x, y)
                        p.hpFg.Size = Vector2.new(math.max(1, w * cur), h)
                        p.hpFg.Color = barCol
                        p.hpFg.Filled = true
                        p.hpFg.Visible = true
                    end
                    if p.hpText then
                        if G.BS.HPBarText then
                            p.hpText.Text = tostring(math.floor(hum.Health + 0.5))
                            p.hpText.Size = 12
                            p.hpText.Color = Color3.new(1, 1, 1)
                            p.hpText.Center = true
                            p.hpText.Outline = true
                            p.hpText.Position = Vector2.new(sp.X, y - 3)
                            p.hpText.Visible = true
                        else
                            vHideText(p.hpText)
                        end
                    end
                else
                    vHideSquare(p.hpBg); vHideSquare(p.hpBorder)
                    vHideSquare(p.hpFg); vHideText(p.hpText)
                end
            else
                vHideSquare(p.hpBg); vHideSquare(p.hpBorder)
                vHideSquare(p.hpFg); vHideText(p.hpText)
            end
        else
            vHideSquare(p.hpBg); vHideSquare(p.hpBorder)
            vHideSquare(p.hpFg); vHideText(p.hpText)
        end

        -- РАМКА ВОКРУГ ГОЛОВЫ
        if G.BS.HeadBox and show and ch and ch.Parent then
            local head = ch:FindFirstChild("Head")
            if head then
                local sp = vProj(cam, head.Position)
                if sp and sp.Z > 0 then
                    local sz = tonumber(G.BS.HeadBoxSize) or 22
                    if p.headBox then
                        p.headBox.Position = Vector2.new(sp.X - sz * 0.5, sp.Y - sz * 0.5)
                        p.headBox.Size = Vector2.new(sz, sz)
                        -- Цвет рамки головы — по роли игрока (v11.36),
                        -- если свой цвет не выбран.
                        local hbCol = color
                        if G.BS.HeadBoxRole == false then
                            hbCol = safeColor(G.BS.HeadBoxColor, Color3.new(1, 0, 0))
                        end
                        p.headBox.Color = hbCol
                        p.headBox.Filled = false
                        p.headBox.Visible = true
                    end
                else
                    vHideSquare(p.headBox)
                end
            else
                vHideSquare(p.headBox)
            end
        else
            vHideSquare(p.headBox)
        end

        -- СТРЕЛКА К ИГРОКУ (v11.39). Раньше — тонкая линия 1 px,
        -- которая терялась на фоне. Теперь это заметная стрелка с
        -- обводкой и наконечником. Себе стрелку не рисуем: игрок и
        -- так видит свой персонаж.
        local isLocal = (tPlr == LP)
        if G.BS.Snaplines ~= false and show and not isLocal and root and root.Parent then
            local sp = vProj(cam, root.Position + Vector3.new(0, 2, 0))
            if sp and sp.Z > 0 then
                drawSnapArrow(p,
                    screenOrigin(G.BS.SnapFrom, cx, cy, vp),
                    Vector2.new(sp.X, sp.Y),
                    color,
                    tonumber(G.BS.SnapArrowThick) or 3,
                    math.clamp(tonumber(G.BS.SnapAlpha) or 1, 0, 1))
            else
                hideSnapArrow(p)
            end
        else
            hideSnapArrow(p)
        end

        -- КОЛЬЦО ПОД ИГРОКОМ И АУРА ВАМПИРА УДАЛЕНЫ (v11.39).
        -- Причина: на близкой дистанции кольцо радиусом 2–4 студа
        -- занимало пол-экрана (огромный красный круг вокруг персонажа).
        if p.auraOn then
            for i = 1, #p.aura do vHideLine(p.aura[i]) end
            p.auraOn = false
        end

        -- СТРЕЛКА У КРАЯ ЭКРАНА (цель за кадром). v11.39: тоже стала
        -- полноценной стрелкой с наконечником, а не штрихом в 12 px.
        if G.BS.OffArrows and show and not isLocal
           and ch and ch.Parent and root and root.Parent then
            local sp = vProj(cam, root.Position)
            local onScreen = sp and sp.Z > 0
                and sp.X >= 0 and sp.X <= vp.X and sp.Y >= 0 and sp.Y <= vp.Y
            if not onScreen then
                local dir
                if sp and sp.Z > 0 then
                    dir = Vector2.new(sp.X - cx, sp.Y - cy)
                else
                    -- За камерой WorldToViewportPoint даёт зеркальные X/Y.
                    -- Берём точку в системе координат камеры: X — вправо,
                    -- -Y — вниз экрана. Иначе стрелка у края показывала
                    -- в случайную сторону (например, вверх, когда цель
                    -- стоит за спиной).
                    local okL, rel = pcall(function()
                        return cam.CFrame:PointToObjectSpace(root.Position)
                    end)
                    if okL and rel then
                        dir = Vector2.new(rel.X, -rel.Y)
                    else
                        dir = Vector2.new(0, 1)
                    end
                end
                local mag = dir.Magnitude
                if mag < 0.001 then dir = Vector2.new(0, -1); mag = 1 end
                local ux, uy = dir.X / mag, dir.Y / mag
                local margin = 34
                local reach = math.min(cx, cy) - margin
                if reach < 10 then reach = 10 end
                local ax = math.clamp(cx + ux * reach, margin, vp.X - margin)
                local ay = math.clamp(cy + uy * reach, margin, vp.Y - margin)
                drawEdgeArrow(p, Vector2.new(ax, ay), ux, uy, color, 3,
                    math.clamp(tonumber(G.BS.SnapAlpha) or 1, 0, 1))
            else
                hideEdgeArrow(p)
            end
        else
            hideEdgeArrow(p)
        end

    end

    -- Гасим слоты пула, которые остались от ушедших игроков. Раньше
    -- при уменьшении числа игроков их HP-бары, стрелки и скелет
    -- застывали на экране навсегда.
    local usedSlots = math.min(idx, VMAX)
    for k = usedSlots + 1, #vpool do
        local pOld = vpool[k]
        if pOld then
            vHideSquare(pOld.hpBg); vHideSquare(pOld.hpBorder)
            vHideSquare(pOld.hpFg); vHideText(pOld.hpText)
            vHideSquare(pOld.headBox)
            hideSnapArrow(pOld)
            hideEdgeArrow(pOld)
            if pOld.skeleton then
                for i = 1, #pOld.skeleton do vHideLine(pOld.skeleton[i]) end
            end
        end
    end

    -- 5.5) ЛИНИИ МЕЖДУ ВАМПИРАМИ. Помогают читать группу: видно, кто
    -- стоит рядом и куда сходится стая. Только между вампирами и
    -- только в пределах 140 студов, чтобы не залить экран паутиной.
    if G.BS.VampLinks then
        local vroots = {}
        for _, e in pairs(by) do
            if e.role == "vampire" and e.char and e.char.Parent then
                local r = e.char:FindFirstChild("HumanoidRootPart")
                if r and r.Parent then vroots[#vroots + 1] = r end
            end
        end
        local li = 0
        for i = 1, #vroots do
            for j = i + 1, #vroots do
                local pa = vroots[i].Position
                local pb = vroots[j].Position
                if (pa - pb).Magnitude <= 140 then
                    li = li + 1
                    if li > 16 then break end
                    local l = vampLinks[li]
                    if not l then l = vLine(); vampLinks[li] = l end
                    local a = vProj(cam, pa)
                    local b = vProj(cam, pb)
                    if l and a and b and a.Z > 0 and b.Z > 0 then
                        vSetLine(l, Vector2.new(a.X, a.Y), Vector2.new(b.X, b.Y),
                            safeColor(G.BS.VampColor, Color3.new(1, 0, 0)), 1)
                        if l.Transparency ~= nil then l.Transparency = 0.45 end
                    else
                        vHideLine(l)
                    end
                end
            end
            if li > 16 then break end
        end
        for k = li + 1, #vampLinks do vHideLine(vampLinks[k]) end
    else
        for k = 1, #vampLinks do vHideLine(vampLinks[k]) end
    end

    -- 6) ПОДСВЕТКА ЯЩИКОВ
    if G.BS.CrateESP then
        local folder = workspace:FindFirstChild("SupplyCaches")
        if folder then
            for _, c in ipairs(folder:GetChildren()) do
                local hl = crateHL[c]
                if not hl or not hl.Parent then
                    local ok, h = pcall(function() return Instance.new("Highlight") end)
                    if ok and h then
                        h.FillColor = safeColor(G.BS.CrateColor, Color3.new(1, 1, 0))
                        h.OutlineColor = safeColor(G.BS.CrateColor, Color3.new(1, 1, 0))
                        h.FillTransparency = 0.5
                        h.Adornee = c
                        h.Parent = c
                        crateHL[c] = h
                        hl = h
                    end
                end
                if hl then
                    hl.Enabled = true
                    hl.FillColor = safeColor(G.BS.CrateColor, Color3.new(1, 1, 0))
                    hl.OutlineColor = safeColor(G.BS.CrateColor, Color3.new(1, 1, 0))
                end
            end
        end
    else
        for _, h in pairs(crateHL) do if h then h.Enabled = false end end
    end

    -- 7) ПОДСВЕТКА МОНЕТ
    if G.BS.CoinESP then
        local folder = workspace:FindFirstChild("CoinPickups")
        if folder then
            local n = 0
            for _, c in ipairs(folder:GetDescendants()) do
                if c:IsA("Model") and c.Name == "CoinPickup" then
                    n = n + 1
                    if n > 20 then break end
                    local hl = coinHL[c]
                    if not hl or not hl.Parent then
                        local ok, h = pcall(function() return Instance.new("Highlight") end)
                        if ok and h then
                            h.FillColor = safeColor(G.BS.CoinColor, Color3.new(1, 1, 0))
                            h.OutlineColor = safeColor(G.BS.CoinColor, Color3.new(1, 1, 0))
                            h.FillTransparency = 0.5
                            h.Adornee = c
                            h.Parent = c
                            coinHL[c] = h
                            hl = h
                        end
                    end
                    if hl then
                        hl.Enabled = true
                        hl.FillColor = safeColor(G.BS.CoinColor, Color3.new(1, 1, 0))
                        hl.OutlineColor = safeColor(G.BS.CoinColor, Color3.new(1, 1, 0))
                    end
                end
            end
        end
    else
        for _, h in pairs(coinHL) do if h then h.Enabled = false end end
    end

    -- 8) ПОДСВЕТКА УЛИК УДАЛЕНА (v11.32) по просьбе.

    -- ЦИФРЫ УРОНА
    for i = #dmgNums, 1, -1 do
        local d = dmgNums[i]
        local age = nowT - d.t0
        if age > 1 or not d.obj then
            if d.obj then pcall(function() d.obj:Remove() end) end
            table.remove(dmgNums, i)
        else
            local sp = vProj(cam, d.pos + Vector3.new(0, age * 1.5, 0))
            if sp and sp.Z > 0 then
                d.obj.Position = Vector2.new(sp.X, sp.Y)
                d.obj.Transparency = age
                d.obj.Visible = true
            else
                d.obj.Visible = false
            end
        end
    end

    -- СТРЕЛКИ ЗВУКА УДАЛЕНЫ (v11.31): звуковые метки остаются только
    -- источником ролей, на экран ничего не рисуется.

    -- МИНИКАРТА
    if G.BS.Minimap and myRoot and minimapBg then
        local size = tonumber(G.BS.MinimapSize) or 160
        local mx, my = vp.X - size - 20, 20
        minimapBg.Position = Vector2.new(mx, my)
        minimapBg.Size = Vector2.new(size, size)
        minimapBg.Color = Color3.new(0, 0, 0)
        minimapBg.Filled = true
        minimapBg.Transparency = 0.5
        minimapBg.Visible = true
        if minimapBorder then
            minimapBorder.Position = Vector2.new(mx, my)
            minimapBorder.Size = Vector2.new(size, size)
            minimapBorder.Color = Color3.new(1, 1, 1)
            minimapBorder.Filled = false
            minimapBorder.Thickness = 1
            minimapBorder.Visible = true
        end
        local scale = 0.5
        local cx0, cy0 = mx + size * 0.5, my + size * 0.5
        if minimapSelf then
            minimapSelf.Position = Vector2.new(cx0, cy0)
            minimapSelf.Radius = 3
            minimapSelf.Color = Color3.new(0, 1, 0)
            minimapSelf.Filled = true
            minimapSelf.Visible = G.BS.MinimapSelf ~= false
        end
        local dotIdx = 0
        for _, e in pairs(by) do
            local ch = e.char
            local root = ch and ch:FindFirstChild("HumanoidRootPart")
            if root and root.Parent then
                local rel = root.Position - myRoot.Position
                local px = cx0 + rel.X * scale
                local py = cy0 + rel.Z * scale
                if px >= mx and px <= mx + size and py >= my and py <= my + size then
                    dotIdx = dotIdx + 1
                    if dotIdx <= 20 then
                        local d = minimapDots[dotIdx]
                        if not d then d = vCircle(); minimapDots[dotIdx] = d end
                        if d then
                            d.Position = Vector2.new(px, py)
                            d.Radius = 3
                            d.Color = e.role == "vampire" and Color3.new(1, 0, 0)
                                or e.role == "hunter" and Color3.new(0, 0.7, 1)
                                or Color3.new(1, 1, 1)
                            d.Filled = true
                            d.Visible = true
                        end
                    end
                end
            end
        end
        for i = dotIdx + 1, #minimapDots do vHideCircle(minimapDots[i]) end
    else
        vHideSquare(minimapBg)
        vHideSquare(minimapBorder)
        vHideCircle(minimapSelf)
        for _, d in pairs(minimapDots) do vHideCircle(d) end
    end

    -- очистка данных ушедших игроков
    for plr in pairs(lastHealth) do
        if not by[plr] then lastHealth[plr] = nil end
    end
end

G.BS.VIS = VIS
end

-- ============================================================
--  ДОБАВЛЕНИЕ / УДАЛЕНИЕ ИГРОКОВАVLENIE / UДАЛЕНИЕ IGROKOV
-- ============================================================
local applyRole

local function remove(plr)
    local e = by[plr]
    if not e then return end
    if e.gui then pcall(function() e.gui:Destroy() end) end
    destroyBox(e.box)
    by[plr] = nil
    if locked == plr then locked = nil end
end

local function add(plr)
    local ch = plr.Character
    if not ch then return end
    local gui, lbl = makeBillboard()
    if not gui or not lbl then return end
    -- КРАСИВАЯ ПОДПИСЬ (v11.34): тёмная плашка с закруглёнными углами
    -- и рамкой в цвете роли. Текст сам подстраивается по ширине.
    lbl.Size                  = UDim2.new(0, 0, 0, 20)
    lbl.AutomaticSize          = Enum.AutomaticSize.X
    lbl.AnchorPoint           = Vector2.new(0.5, 0.5)
    lbl.Position              = UDim2.new(0.5, 0, 0.5, 0)
    lbl.BackgroundColor3      = Color3.new(0, 0, 0)
    lbl.BackgroundTransparency = 0.45
    lbl.BorderSizePixel       = 1
    lbl.BorderColor3          = Color3.new(1, 1, 1)
    lbl.TextSize              = 13
    lbl.Font                  = Enum.Font.GothamMedium
    lbl.TextStrokeTransparency = 0.5
    lbl.TextStrokeColor3      = Color3.new(0, 0, 0)
    lbl.Text                  = ""
    lbl.Visible               = false
    lbl.Parent                = gui
    -- ЗАКРУГЛЁННЫЕ УГЛЫ плашки — выглядит аккуратнее квадратной.
    pcall(function()
        if not lbl:FindFirstChildOfClass("UICorner") then
            local c = Instance.new("UICorner")
            c.CornerRadius = UDim.new(0, 7)
            c.Parent = lbl
        end
    end)

    gui.Adornee = ch
    by[plr] = {
        char = ch, gui = gui, lbl = lbl,
        role = nil, conf = 0, votes = 0, lastStable = nil, box = nil,
        special = nil, status = nil, src = nil, manual = nil,
    }
end

-- РУЧНАЯ ПРАВКА РОЛИ (игрок сам сказал - не сомневаемся)
-- Функции ролей сложены в таблицу ROLES: главный блок скрипта упирается
-- в лимит локальных переменных Lua (200).
local ROLES = {}
local RoleOverride = ROLES.override or {}
ROLES.override = RoleOverride   -- [Player] = "vampire" | "hunter" | nil

function ROLES.clearOverride()
    for k in pairs(RoleOverride) do RoleOverride[k] = nil end
end

-- ОГРАНИЧЕНИЕ ПО СЧЁТЧИКАМ РАУНДА. Игра сама сообщает, сколько в
-- раунде вампиров и хантеров (RoundState: vampires / hunters). Если
-- помечено больше, чем их на самом деле - значит скрипт ошибся
-- (например, признак роли нашёлся у косметики), и в ESP становится
-- "все вампиры". Поэтому лишние метки не выдаём: вместо них роль
-- снимается с того, у кого уверенность ниже всего.
local function countRole(kind)
    local n = 0
    for _, e in pairs(by) do
        if e.role == kind and e.manual ~= true then n = n + 1 end
    end
    return n
end

function ROLES.weakest(kind)
    local weak, wconf = nil, math.huge
    for _, e in pairs(by) do
        if e.role == kind and e.manual ~= true and e.conf < wconf then
            weak, wconf = e, e.conf
        end
    end
    return weak
end

local function roleAllowed(role, conf)
    local cap = 0
    if role == "vampire" then cap = tonumber(G.BS.RoundVamps) or 0
    elseif role == "hunter" then cap = tonumber(G.BS.RoundHunters) or 0 end
    if cap <= 0 then return true end          -- счётчика нет - не проверяем
    if countRole(role) < cap then return true end
    -- уже набрано - вытесняем самую слабую метку
    local weak = ROLES.weakest(role)
    if weak and weak.conf < conf then
        weak.role, weak.conf, weak.votes, weak.lastStable = nil, 0, 0, nil
        weak.src = "вытеснен по счётчику раунда"
        return true
    end
    return false
end

applyRole = function(e, role, conf, src)
    if not e then return end
    e.src = src or e.src
    if not roleAllowed(role, conf) then
        e.role, e.conf, e.votes, e.lastStable = nil, 0, 0, nil
        return
    end
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

-- СВОДКА ПО РОЛЯМ: сколько помечено против реальных счётчиков раунда.
-- Печатается при смене фазы и по кнопке - по ней видно, где скрипт
-- ошибается.
function ROLES.summary()
    local v, h, u = countRole("vampire"), countRole("hunter"), 0
    for _, e in pairs(by) do
        if e.role == nil and e.manual ~= true then u = u + 1 end
    end
    for _, e in pairs(by) do
        if e.manual == true then
            if e.role == "vampire" then v = v + 1 else h = h + 1 end
        end
    end
    local rv = tonumber(G.BS.RoundVamps) or 0
    local rh = tonumber(G.BS.RoundHunters) or 0
    -- by[] хранит только ДРУГИХ игроков (себя скрипт не красит), а
    -- счётчики RoundState - всех вместе с тобой. Раньше из-за этого в
    -- логе выглядело, будто одного вампира не нашли: «2 (в раунде 3)»,
    -- хотя третий - это ты. Показываем честно: «других 2 из 2».
    local mine = string.lower(tostring(G.BS.MyRole or "?"))
    local rvOthers, rhOthers = rv, rh
    if mine == "vampire" then rvOthers = math.max(0, rv - 1) end
    if mine == "hunter"  then rhOthers = math.max(0, rh - 1) end
    local msg = string.format("[BS ROLE] отмечено других: вампиров %d из %d, "
        .. "хантеров %d из %d, без роли %d | ты: %s",
        v, rvOthers, h, rhOthers, u, mine)
    print(msg)
    -- кто именно помечен и по какому источнику
    local names = {}
    for plr, e in pairs(by) do
        if e.role then
            names[#names + 1] = plr.DisplayName .. "=" .. tostring(e.role)
                .. " (" .. tostring(e.src or "?") .. ")"
        end
    end
    table.sort(names)
    for i = 1, #names do print("   " .. names[i]) end
    return msg
end

-- РУЧНАЯ УСТАНОВКА РОЛИ ПО НИКУ (из GUI или консоли)
function ROLES.set(plrOrName, role)
    local plr = plrOrName
    if type(plrOrName) == "string" then
        for _, p in ipairs(Players:GetPlayers()) do
            if p.Name:lower() == plrOrName:lower()
               or p.DisplayName:lower() == plrOrName:lower() then
                plr = p
                break
            end
        end
    end
    if not plr then
        print("[BS ROLE] игрок не найден")
        return false
    end
    local e = by[plr]
    if not e then
        print("[BS ROLE] нет ESP для " .. tostring(plr.Name))
        return false
    end
    if role == nil or role == "none" then
        RoleOverride[plr] = nil
        e.role, e.conf, e.votes, e.lastStable, e.manual = nil, 0, 0, nil, nil
        e.src = "сброшено вручную"
        print("[BS ROLE] " .. plr.Name .. ": роль сброшена")
        return true
    end
    RoleOverride[plr] = role
    e.role, e.conf, e.votes, e.lastStable = role, 99, 1, role
    e.manual, e.src = true, "выставлено вручную"
    print("[BS ROLE] " .. plr.Name .. ": " .. role .. " (вручную)")
    return true
end

function ROLES.reset()
    ROLES.clearOverride()
    for _, e in pairs(by) do
        e.role, e.conf, e.votes, e.lastStable, e.manual = nil, 0, 0, nil, nil
        e.src = nil
    end
    print("[BS ROLE] все роли сброшены")
end

-- ============================================================
--  ОВЕРЛЕЙ (Frame вместо Drawing: работает везде)
-- ============================================================
local Overlay = nil
local FOVSegs  = {}
local FOV_N    = 48
-- v11.33: красивая метка цели. 8 отрезков (4 угла по 2 линии) +
-- табличка с подробностями (имя / дистанция / HP / оружие).
local TPlate   = nil

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
    -- УГОЛКИ МЕТКИ ЦЕЛИ УДАЛЕНЫ (v11.36) — индикатор теперь кольцо
    -- захвата (рисуется в модуле VIS).
    -- ТАБЛИЧКА ЦЕЛИ: тёмный фон, тонкая рамка, аккуратный текст.
    TPlate = Instance.new("TextLabel")
    TPlate.Name                     = "BS_TargetPlate"
    TPlate.BackgroundColor3         = Color3.new(0, 0, 0)
    TPlate.BackgroundTransparency   = 0.35
    TPlate.BorderSizePixel          = 1
    TPlate.BorderColor3             = Color3.new(1, 1, 1)
    TPlate.TextColor3               = Color3.new(1, 1, 1)
    TPlate.TextStrokeTransparency   = 0.35
    TPlate.TextStrokeColor3         = Color3.new(0, 0, 0)
    TPlate.Font                     = Enum.Font.GothamSemibold
    TPlate.TextSize                 = 12
    TPlate.Text                     = ""
    TPlate.AnchorPoint              = Vector2.new(0.5, 0)
    TPlate.AutomaticSize            = Enum.AutomaticSize.X
    TPlate.Size                     = UDim2.new(0, 0, 0, 18)
    TPlate.ZIndex                   = 63
    TPlate.Visible                  = false
    TPlate.Parent                   = Overlay
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

local function hideOverlay()
    if not Overlay then return end
    for i = 1, FOV_N do
        if FOVSegs[i] then FOVSegs[i].Visible = false end
    end
    if TPlate then TPlate.Visible = false end
end

local function drawFOV()
    -- КРУГ АЙМА (ПОВ). Показывает радиус, внутри которого скрипт видит
    -- цель: игрок в круге - аим/выстрел в него, вне круга - не трогаем.
    -- Рисуем не каждый кадр: геометрия меняется только от радиуса/экрана.
    local tick = os.clock()
    if G.BS._fovNext and tick < G.BS._fovNext then return end
    G.BS._fovNext = tick + 0.05
    local on = (G.BS.AimFOVShow ~= false)
        and (G.BS.AimLock ~= false or G.BS.BulletSwap ~= false)
    local r = tonumber(G.BS.AimFOV) or 300
    -- 600+ = без ограничения: границы нет, кольцо не рисуем (иначе оно
    -- показывало бы ложный предел, хотя цель выбирается по всему экрану).
    if not on or r >= 600 then
        for i = 1, FOV_N do
            local s = FOVSegs[i]
            if s then s.Visible = false end
        end
        return
    end
    local cam = workspace.CurrentCamera
    if not cam then return end
    ensureOverlay()
    local vp = cam.ViewportSize
    local cx, cy = vp.X * 0.5, vp.Y * 0.5
    if r < 10 then r = 10 end
    if r > 900 then r = 900 end
    local col = safeColor(G.BS.AimFOVColor, Color3.new(1, 1, 1))
    local thick = math.clamp(tonumber(G.BS.AimFOVThick) or 2, 1, 6)
    local alpha = math.clamp(tonumber(G.BS.AimFOVAlpha) or 0.35, 0, 1)
    for i = 1, FOV_N do
        local a1 = (i - 1) / FOV_N * math.pi * 2
        local a2 = i / FOV_N * math.pi * 2
        local from = Vector2.new(cx + math.cos(a1) * r, cy + math.sin(a1) * r)
        local to   = Vector2.new(cx + math.cos(a2) * r, cy + math.sin(a2) * r)
        local seg  = FOVSegs[i]
        if seg then placeSeg(seg, from, to, thick, col, alpha) end
    end
end

-- ЦВЕТ ЦЕЛИ ПО РОЛИ. Используется и уголками, и табличкой.
local function roleColorOf(plr)
    local e = plr and by[plr]
    local role = e and e.role
    if role == "vampire" then
        return safeColor(G.BS.VampColor, Color3.new(1, 0, 0))
    elseif role == "hunter" then
        return safeColor(G.BS.HunterColor, Color3.new(0, 0.7, 1))
    end
    return safeColor(G.BS.PlayerColor, Color3.new(1, 1, 1))
end

-- КРАСИВАЯ МЕТКА ЦЕЛИ (v11.33). Вместо грубых жёлтых полосок:
--  - тонкая обводка Highlight на персонаже (TargetMark);
--  - аккуратные уголки в цвете роли, размер зависит от дистанции;
--  - табличка под целью: имя, дистанция, HP (в процентах) и оружие.
local function drawTarget(plr)
    ensureOverlay()
    local function hideAll()
        if TPlate then TPlate.Visible = false end
    end
    if not plr or not plr.Parent then hideAll() return end
    local ch = plr.Character
    if not ch or not ch.Parent then hideAll() return end
    local cam = workspace.CurrentCamera
    local root = ch:FindFirstChild("HumanoidRootPart")
    local head = ch:FindFirstChild("Head")
    if not cam or not root or not root.Parent or not head or not head.Parent then
        hideAll()
        return
    end
    local hum = ch:FindFirstChildOfClass("Humanoid")
    if hum and hum.Health <= 0 then hideAll() return end
    local sp = cam:WorldToViewportPoint(head.Position)
    if sp.Z <= 0 then hideAll() return end

    local dist = (root.Position - cam.CFrame.Position).Magnitude
    local col = roleColorOf(plr)
    if G.BS.TargetBracketRole == false then
        col = safeColor(G.BS.TargetBracketColor, Color3.new(1, 1, 1))
    end
    -- УГОЛКИ УДАЛЕНЫ (v11.36) по просьбе: «выглядят плохо». Основной
    -- индикатор цели — кольцо захвата (рисуется в модуле VIS).

    -- ТАБЛИЧКА: подробности о цели (имя / дистанция / HP / оружие).
    if G.BS.TargetPlate ~= false and TPlate then
        local parts = {}
        if G.BS.TargetPlateName ~= false then parts[#parts + 1] = plr.DisplayName end
        if G.BS.TargetPlateDist ~= false then
            parts[#parts + 1] = string.format("%d st", math.floor(dist + 0.5))
        end
        if G.BS.TargetPlateHP ~= false and hum then
            local maxHp = hum.MaxHealth or 0
            if maxHp > 0 then
                parts[#parts + 1] = string.format("HP %d%%",
                    math.floor(hum.Health / maxHp * 100 + 0.5))
            else
                parts[#parts + 1] = "HP " .. math.floor(hum.Health + 0.5)
            end
        end
        if G.BS.TargetPlateWeap then
            local tool = ch:FindFirstChildOfClass("Tool")
            if tool then parts[#parts + 1] = tool.Name end
        end
        local txt = table.concat(parts, "  |  ")
        if txt ~= "" then
            TPlate.Text = txt
            TPlate.TextColor3 = col
            TPlate.BorderColor3 = col
            TPlate.Position = UDim2.new(0, sp.X, 0, sp.Y + 14)
            TPlate.Visible = true
        else
            TPlate.Visible = false
        end
    elseif TPlate then
        TPlate.Visible = false
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

local function lockPart(ch)
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
    -- Свою роль приводим к тем же именам, что и роли других игроков:
    -- RoleAssigned может хранить "doctor"/"detective", а e.role — только
    -- vampire/hunter/human, и сравнение строк давало «все враги».
    local me = aliasOf(G.BS.MyRole)
    if me == "none" then me = "human" end
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
        -- Своя роль ещё не известна (начало раунда / Mystery): не
        -- отсекаем всех подряд, иначе аимлок молчит, хотя игрок впереди.
        if not me then return true end
        if e.role and e.role ~= me then return true end
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
    local p = lockPart(ch)
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
    local fov = tonumber(G.BS.AimFOV) or 300
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
                        -- «Ближе к прицелу» = экранное расстояние, а не
                        -- мировая дистанция (раньше ветка была такой же,
                        -- как «Ближе по расстоянию», и настройка врала).
                        local dx, dy = sp.X - ccx, sp.Y - ccy
                        score = dx * dx + dy * dy
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
local summaryToken = 0 -- защита от двойной сводки ролей при быстрой смене фаз

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
                        -- своя роль может лежать прямо в RoundState
                        -- (role/myRole/...): раньше читали только счётчики,
                        -- поэтому в HUD вечно было «роль: ?».
                        local keys = { "role", "myRole", "selfRole", "roleName" }
                        for ki = 1, #keys do
                            local k = aliasOf(st[keys[ki]])
                            if k and k ~= "none" and G.BS.MyRole ~= k then
                                G.BS.MyRole = k
                                addEvent("твоя роль: " .. k)
                            end
                        end
                        G.BS.RoundPhase   = tostring(st.phase or "?")
                        G.BS.RoundVamps   = tonumber(st.vampires) or 0
                        G.BS.RoundHunters = tonumber(st.hunters) or 0
                        if G.BS.RoundPhase ~= G.BS.LastPhase then
                            if G.BS.RoundPhase == "Lobby" or G.BS.RoundPhase == "Ending" then
                                resetRound()
                            end
                            G.BS.LastPhase = G.BS.RoundPhase
                            if G.BS.RoundPhase == "RoleAssign" or G.BS.RoundPhase == "Active" then
                                G.BS.RoundStart = os.clock()
                            end
                            addEvent("ФАЗА: " .. tostring(st.phase)
                                .. " (в " .. tostring(st.vampires or 0)
                                .. " в, " .. tostring(st.hunters or 0) .. " х)")
                            summaryToken = summaryToken + 1
                            local tok = summaryToken
                            task.delay(1.5, function()
                                if tok == summaryToken then pcall(ROLES.summary) end
                            end)
                            -- ТАНЕЦ: новый раунд может снести анимацию.
                            -- Перезапускаем танец на старте раунда.
                            if G.BS.DanceOn
                               and (G.BS.RoundPhase == "Active"
                                    or G.BS.RoundPhase == "RoleAssign") then
                                local now = os.clock()
                                if now - (G.BS._danceRestartAt or 0) > 1.5 then
                                    G.BS._danceRestartAt = now
                                    task.delay(1, function()
                                        if not STOPPED and G.BS.DanceOn
                                           and G.BS.DanceRestart then
                                            pcall(G.BS.DanceRestart)
                                        end
                                    end)
                                end
                            end
                        end
                    end
                    -- RoleAssigned
                    if r.Name == "RoleAssigned" and i == 1 then
                        -- роль может прийти строкой или таблицей {role=...}
                        local a = args[i]
                        if type(a) == "table" then
                            a = a.role or a.myRole or a.roleName or a.name
                        end
                        local k = aliasOf(a)
                        -- aliasOf знает только vampire/hunter/none/civil.
                        -- Остальные роли игры (doctor, detective, seer...) он
                        -- не распознаёт, поэтому сохраняем строку как есть -
                        -- иначе они снова превращались бы в «роль: ?».
                        if not k and type(a) == "string" and a ~= "" then
                            k = string.lower(a)
                        end
                        if k and k ~= "none" and G.BS.MyRole ~= k then
                            G.BS.MyRole = k
                            addEvent("твоя роль: " .. k)
                        end
                    end
                    -- SoundPing {pos, sound}
                    if r.Name == "SoundPing" and i == 1 and typeof(args[i]) == "Vector3" then
                        soundMarks[#soundMarks + 1] = {
                            pos = args[i], s = tostring(args[2] or ""), t = os.clock(),
                        }
                        if #soundMarks > 40 then table.remove(soundMarks, 1) end
                    end
                    -- EmoteSetSlots: список эмоутов игрока с ID
                    -- анимаций. Складываем таблицы и разбираем позже -
                    -- это главный источник танцев.
                    if r.Name == "EmoteSetSlots" then
                        for k = 1, args.n do
                            if typeof(args[k]) == "table" then
                                emoteTables[#emoteTables + 1] = args[k]
                                if #emoteTables > 6 then table.remove(emoteTables, 1) end
                            end
                        end
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
                        local a0 = args[1]
                        local skip = false
                        if type(a0) == "table" then
                            if a0.type == "progress" or a0.done == true then skip = true end
                            if type(a0.value) == "number" and a0.value <= 0 then skip = true end
                        end
                        if not skip then
                        local cnt = (G.BS.DmgEvents or 0) + 1
                        G.BS.DmgEvents = cnt
                        -- ХИТМАРКЕР: урон пришёл с сервера = попадание
                        -- реально засчиталось. Плюс строка в ленту событий.
                        hitMarkAt = os.clock()
                        -- ЦИФРЫ УРОНА + ТРЕЙСЕР ВЫСТРЕЛА
                        local tpart = bulletListTarget
                        if tpart and tpart.Parent then
                            if G.BS.VIS and G.BS.VIS.spawnDmgNum then
                                local amount = nil
                                if type(a0) == "table" then
                                    amount = a0.value or a0.amount
                                        or a0.damage or a0.dmg
                                end
                                if type(amount) ~= "number" then amount = nil end
                                pcall(G.BS.VIS.spawnDmgNum, tpart.Position, amount)
                            end
                            if G.BS.VIS and G.BS.VIS.spawnTracer then
                                local ch = LP and LP.Character
                                local tool = ch and ch:FindFirstChildOfClass("Tool")
                                local handle = tool and tool:FindFirstChild("Handle")
                                local from = handle and handle.Position
                                if not from then
                                    local head = ch and ch:FindFirstChild("Head")
                                    from = head and head.Position
                                end
                                if not from and workspace.CurrentCamera then
                                    from = workspace.CurrentCamera.CFrame.Position
                                end
                                if from then
                                    pcall(G.BS.VIS.spawnTracer, from, tpart.Position)
                                end
                            end
                        end
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
    human      = "Гражданин",
    none       = "Гражданский",
}

-- HUD удалён по просьбе: в углу больше ничего не рисуется, остаётся
-- только окно Rayfield. Вся информация о роли/фазе/патронах есть в
-- ESP-подписях и в консоли ([BS EVT] / [BS ROLE]).

-- ============================================================
--  ПАТРОНЫ: ЧТЕНИЕ СЧЁТЧИКА
-- ============================================================
-- В этой игре патроны не всегда лежат в Tool: у оружия может не быть
-- атрибутов Charges/Ammo, а счётчик рисуется в PlayerGui ("18/18").
-- Поэтому смотрим три источника по порядку: атрибуты Tool, значения
-- внутри Tool, затем TextLabel в PlayerGui (самый нижний на экране).
-- Возвращаем текущий/максимальный заряд и источник. Функция лежит в
-- G.BS, а не в локальной переменной: в главном блоке уже лимит 200
-- локальных, и лишняя переменная ломала запуск (luac: too many locals).
G.BS.ReadAmmo = (function()
    local ATTRS = {
        { "Charges", "MaxCharges" },
        { "Ammo", "MaxAmmo" },
        { "CurrentAmmo", "MaxAmmo" },
        { "AmmoCount", "MaxAmmo" },
        { "Magazine", "MaxMagazine" },
        { "Clip", "ClipSize" },
        { "Patron", "MaxPatron" },
    }
    -- Кэш найденного HUD-лейбла: PlayerGui у Rayfield большой, и
    -- сканировать его целиком 5 раз в секунду слишком дорого.
    local cachedLabel, cachedAt = nil, 0
    return function()
        local ch = LP and LP.Character
        local tool = ch and ch:FindFirstChildOfClass("Tool")
        if tool then
            for i = 1, #ATTRS do
                local pair = ATTRS[i]
                local okA, cur = pcall(function() return tool:GetAttribute(pair[1]) end)
                if okA and type(cur) == "number" then
                    local okB, mx = pcall(function() return tool:GetAttribute(pair[2]) end)
                    return cur, (okB and type(mx) == "number") and mx or nil,
                        "tool." .. pair[1]
                end
            end
            local okD, kids = pcall(function() return tool:GetDescendants() end)
            if okD and type(kids) == "table" then
                for _, d in ipairs(kids) do
                    if d:IsA("NumberValue") or d:IsA("IntValue") then
                        local n = string.lower(tostring(d.Name))
                        if string.find(n, "ammo", 1, true)
                           or string.find(n, "charge", 1, true)
                           or string.find(n, "patron", 1, true)
                           or string.find(n, "clip", 1, true) then
                            return d.Value, nil, "tool." .. d.Name
                        end
                    end
                end
            end
        end
        local now = os.clock()
        if cachedLabel and cachedLabel.Parent and cachedLabel.Visible
           and now - cachedAt < 3 then
            local a, b = string.match(tostring(cachedLabel.Text or ""),
                "^%s*(%d+)%s*/%s*(%d+)%s*$")
            if a and b then
                return tonumber(a), tonumber(b),
                    "HUD " .. tostring(cachedLabel.Name)
            end
        end
        local pg = LP and (LP:FindFirstChildOfClass("PlayerGui")
            or LP:FindFirstChild("PlayerGui"))
        if pg then
            local vpY = 0
            pcall(function()
                vpY = workspace.CurrentCamera.ViewportSize.Y
            end)
            local bestY, bestCur, bestMax, bestName, bestLabel =
                -1, nil, nil, nil, nil
            local okG, all = pcall(function() return pg:GetDescendants() end)
            if okG and type(all) == "table" then
                for _, d in ipairs(all) do
                    if d.Parent and (d:IsA("TextLabel") or d:IsA("TextButton"))
                       and d.Visible then
                        local a, b = string.match(tostring(d.Text or ""),
                            "^%s*(%d+)%s*/%s*(%d+)%s*$")
                        if a and b then
                            local y = -1
                            pcall(function() y = d.AbsolutePosition.Y end)
                            -- только нижняя часть экрана: там HUD патронов,
                            -- а не счётчики игроков/раунда сверху.
                            if y >= vpY * 0.55 and y > bestY then
                                bestY, bestCur, bestMax, bestName, bestLabel =
                                    y, tonumber(a), tonumber(b), d.Name, d
                            end
                        end
                    end
                end
            end
            if bestCur then
                cachedLabel, cachedAt = bestLabel, now
                return bestCur, bestMax, "HUD " .. tostring(bestName)
            end
        end
        cachedLabel = nil
        return nil, nil, nil
    end
end)()

-- updateHud удалён вместе с HUD.

-- ============================================================
--  ЗВУКОВЫЕ МЕТКИ (SoundPing) — данные для стрелок звука
-- ============================================================
-- Игра шлёт SoundPing {pos, sound}, когда кто-то выстрелил или
-- закричал. Кольца шума убраны вместе с HUD: остались только
-- стрелки к источнику звука (вкладка ESP).

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
-- Спин крутит HRP в отдельном Heartbeat-коннекте (SPIN), анимация
-- и поворот больше не дублируются в danceTick.
--
-- Спин работает и ПОВЕРХ ассетного танца (можно включить оба).

local DANCES  = {}          -- [{label, id}] - найденные анимации
local DANCE_BY_LABEL = {}   -- "label|id" -> true (защита от повторов)
local DANCE_BY_NAME  = {}   -- label -> id (для выпадающего списка)
local dance = {
    on = false,             -- танец включён
    label = "", id = nil,    -- выбранная анимация
    emote = nil,             -- имя эмоута для EmotePlay ("emote_dance")
    emoteId = {},            -- имя эмоута -> ID анимации (для локальной петли)
    emoteAt = 0,             -- когда последний раз посылали EmotePlay
    entry = {},              -- label -> запись (анимация или эмоут)
    track = nil, anim = nil, animator = nil, lowered = {},
    spin = false, sway = false,
    spinSpeed = 50, swayAmp = 20, swaySpeed = 2.4,
    yaw = 0, prevYaw = 0,
    hotkey = "F7", scanAt = 0,
}
dance.byLabel = dance.entry


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
    if string.len(label) > 34 then label = string.sub(label, 1, 34) end
    local key = label .. "|" .. s
    if DANCE_BY_LABEL[key] then return false end
    DANCE_BY_LABEL[key] = true
    if not DANCE_BY_NAME[label] then DANCE_BY_NAME[label] = s end
    local e = { label = label, id = s }
    DANCES[#DANCES + 1] = e
    if not dance.entry[label] then dance.entry[label] = e end
    return true
end

-- ЭМОУТЫ ПО ИМЕНИ. Игра играет танец не анимацией напрямую, а ремоутом:
--   EmotePlay:FireServer("emote_dance")
-- Поэтому имя эмоута - полноценный «танец»: его можно выбрать и играть
-- без всяких ID. Это и есть основной путь, если анимации не находятся.
dance.addEmote = function(name)
    name = tostring(name or "")
    if name == "" then return false end
    if dance.entry[name] then return false end
    local e = { label = name, emote = name }
    dance.entry[name] = e
    DANCES[#DANCES + 1] = e
    return true
end

-- Гарантированный танец: имя известно из лога игры (EmotePlay).
dance.addEmote("emote_dance")

-- КЛАССИЧЕСКИЕ ТАНЦЫ ROBLOX. Они публичные и грузятся в любой игре,
-- поэтому список не будет пустым, даже если игра не отдала свои
-- анимации. emote_dance остаётся ПЕРВЫМ (он и так добавлен выше),
-- классика идёт после него.
addDance("Dance (классика)", "507770677")
addDance("Dance2 (классика)", "507770818")
addDance("Dance3 (классика)", "507771019")
-- Из лога игрока: EmotePlay("emote_dance") играет 507771019. Сразу
-- связываем имя с ID, чтобы танец шёл локальной петлёй с первого кадра,
-- не дожидаясь перехвата LoadAnimation. Если игра пришлёт другой ID,
-- captureId/captureAnimArg обновят связку.
dance.emoteId["emote_dance"] = "507771019"

-- ФИЛЬТР «ПОХОЖЕ НА ТАНЕЦ». В игре сотни Animation-объектов (походка,
-- оружие, катсцены), и раньше в список попадало всё подряд: в логе было
-- 11-15 «танцев», многие ID 19004... не запускались. Берём только те,
-- у кого в имени/пути есть танец/эмоут/поза, и отсекаем боевые и
-- двигательные анимации по имени самого объекта.
dance.danceWords = {
    "dance", "emote", "pose", "wave", "salute", "applaud",
    "celebrate", "taunt", "groove", "boogie", "party", "disco",
    "floss", "dab", "rumba", "samba", "ballet", "cheer",
}
dance.badWords = {
    "idle", "walk", "run", "jump", "fall", "climb", "swim", "land",
    "sprint", "crouch", "death", "dead", "seated", "sit", "freefall",
    "weapon", "gun", "rifle", "pistol", "shotgun", "reload", "aim",
    "equip", "unequip", "hit", "hurt", "block", "stun", "downed",
    "carry", "carried", "spawn", "tool", "slash", "swing", "punch",
    "kick", "throw", "shoot", "fire", "melee",
}
dance.looksLike = function(name, context)
    local nm = string.lower(tostring(name or ""))
    if MOVE_TRACKS[nm] then return false end
    for _, w in ipairs(dance.badWords) do
        if string.find(nm, w, 1, true) then return false end
    end
    local s = nm
    if context and context ~= "" then
        s = s .. " " .. string.lower(tostring(context))
    end
    for _, w in ipairs(dance.danceWords) do
        if string.find(s, w, 1, true) then return true end
    end
    return false
end

-- СВЯЗКА «ИМЯ ЭМОУТА -> ID АНИМАЦИИ».
-- EmoteSetSlots обычно приходит таблицей вида {name="emote_dance",
-- animation="rbxassetid://..."} или {emote_dance = "rbxassetid://..."}.
-- Без этой связи эмоут можно только перезапускать ремоутом, и при ходьбе
-- игра его сбрасывает. С ID мы играем анимацию локально петлёй на
-- высоком приоритете - она не прерывается движением.
dance.pairIds = function(t, depth)
    if type(t) ~= "table" or depth > 4 then return end
    local names, ids = {}, {}
    pcall(function()
        for k, v in pairs(t) do
            if type(v) == "string" then
                local s = normAnimId(v)
                if s then
                    ids[#ids + 1] = s
                    local kl = string.lower(tostring(k))
                    if string.find(kl, "emote", 1, true)
                       or string.find(kl, "dance", 1, true)
                       or string.find(kl, "anim", 1, true) then
                        dance.emoteId[tostring(k)] = s
                    end
                else
                    local vl = string.lower(v)
                    if string.find(vl, "emote", 1, true)
                       or string.find(vl, "dance", 1, true)
                       or string.find(vl, "pose", 1, true)
                       or string.find(vl, "wave", 1, true)
                       or string.find(vl, "sit", 1, true) then
                        names[#names + 1] = v
                    end
                end
            elseif type(v) == "table" and depth < 4 then
                dance.pairIds(v, depth + 1)
            end
        end
        -- одна пара в таблице - почти наверняка имя и его анимация
        if #names == 1 and #ids == 1 then
            dance.emoteId[names[1]] = ids[1]
        end
    end)
end

-- Поиск ID по имени эмоута (регистр не важен).
dance.findId = function(name)
    local n = tostring(name or "")
    if n == "" then return nil end
    if dance.emoteId[n] then return dance.emoteId[n] end
    local ln = string.lower(n)
    for k, v in pairs(dance.emoteId) do
        if string.lower(tostring(k)) == ln then return v end
    end
    return DANCE_BY_NAME[n]
end

-- ПОДПИСИ ТАНЦЕВ. В игре почти все анимации названы одинаково
-- ("Animation"), поэтому в списке было 8 одинаковых строк и непонятно,
-- что выбирать. Добавляем короткий хвост ID - тогда каждая строка
-- уникальна и видно, что за анимация. Эмоуты подписаны по имени.
dance.labels = function()
    local opts = {}
    for i = 1, #DANCES do
        local d = DANCES[i]
        if d.emote then
            opts[i] = "эмоут " .. d.label
        else
            opts[i] = d.label .. " …" .. string.sub(d.id, -5)
        end
    end
    return opts
end

-- Выбор танца теперь только через выпадающий список во вкладке ИГРОК.
-- Кнопки «следующий/предыдущий» удалены в v11.19.

-- ИГРАЕМ ЭМОУТ ШТАТНЫМ РЕМОУТОМ ИГРЫ.
-- EmotePlay:FireServer("emote_dance") - ровно то, что делает игра, когда
-- ты выбираешь танец в колесе эмоутов. Никаких ID и Animator не нужно.
dance.fireEmote = function(name)
    local rem = NC.emote
    if not rem then
        pcall(function()
            local bs = game:GetService("ReplicatedStorage")
                :FindFirstChild("BloodyStreet")
            local rs = bs and bs:FindFirstChild("Remotes")
            rem = rs and rs:FindFirstChild("EmotePlay")
            NC.emote = rem
        end)
    end
    if not rem then
        if dance.reportedEmote ~= "__noremote" then
            dance.reportedEmote = "__noremote"
            addEvent("эмоут: ремоут EmotePlay не найден")
        end
        return false
    end
    -- ЛОВУШКА ДЛЯ ID: следующая анимация, которую загрузит игра после
    -- EmotePlay, — это анимация эмоута. Хук LoadAnimation свяжет её с
    -- именем и включит локальную петлю (см. captureAnimArg).
    dance.pendingEmote = tostring(name)
    dance.pendingAt = os.clock()
    local ok = pcall(function() rem:FireServer(name) end)
    -- В ленту пишем только при смене эмоута, иначе повтор забивал бы
    -- события при каждом перезапуске.
    if dance.reportedEmote ~= tostring(name) then
        dance.reportedEmote = tostring(name)
        if ok then
            addEvent("танец игры: " .. tostring(name))
        else
            addEvent("эмоут: FireServer не прошёл")
        end
    end
    return ok
end

-- ЛОВИМ АНИМАЦИИ, КОТОРЫЕ ИГРА ГРУЗИТ САМА. Когда открывают колесо
-- эмоутов или включают танец, игра зовёт Animator:LoadAnimation или
-- Humanoid:PlayAnimation - наш глобальный хук __namecall это видит,
-- поэтому ID анимации снимается на лету и список наполняется сам.
-- Внутри хука только обращения к свойствам, без ":"-вызовов.
local function captureAnimArg(a)
    if typeof(a) ~= "Instance" then return end
    if a.ClassName ~= "Animation" then return end
    -- Наш собственный LoadAnimation (локальная петля танца) не считаем
    -- эмоутом игры: иначе pendingEmote связывался с ним и трек
    -- перезапускался через task.defer.
    if dance.selfLoad then return end
    local id = a.AnimationId
    if type(id) ~= "string" or id == "" then return end
    local nm = tostring(a.Name or "?")
    if MOVE_TRACKS[string.lower(nm)] then return end   -- ходьба - не танец
    -- СВЯЗКА С ЭМОУТОМ: если только что послали EmotePlay, следующая
    -- загруженная анимация - его ID. Запоминаем и сразу включаем петлю.
    -- В список её отдельной строкой НЕ добавляем: у эмоута уже есть
    -- запись по имени, а "Animation …xxxxx" только засорял dropdown.
    local pn = dance.pendingEmote
    if pn and os.clock() - (dance.pendingAt or 0) < 1.5 then
        local known = dance.emoteId[pn]
        dance.emoteId[pn] = id
        dance.pendingEmote = nil
        print("[BS DANCE] эмоут " .. tostring(pn) .. " -> " .. id
            .. " (хук LoadAnimation)")
        -- Если этот ID уже играет (например, классический Dance3 из
        -- заготовки), НЕ перезапускаем трек: иначе на первом запуске
        -- танца был бы рывок через кадр.
        if known ~= id and dance.on and dance.emote == pn
           and dance.playId then
            -- не грузим анимацию внутри __namecall: откладываем на кадр
            task.defer(function()
                if dance.on and dance.emote == pn then
                    pcall(dance.playId, id, true)
                end
            end)
        end
        return
    end
    -- Без связи с эмоутом берём только явно танцевальные анимации.
    local parentName = a.Parent and a.Parent.Name or ""
    if dance.looksLike(nm, parentName) then addDance(nm, id) end
end
dance.captureAnimArg = captureAnimArg

-- captureEmoteArgs (разбор EmotePlay) объявлен ниже - после
-- scanEmoteTable, на который он ссылается.

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
                        -- Контекст: имя объекта + 3 родителя. Часто сама
                        -- анимация называется "Animation", а папка -
                        -- "Dances"/"Emotes"; по пути её и находим.
                        local ctx = tostring(d.Name or "")
                        local p = d.Parent
                        for _ = 1, 3 do
                            if not p or p == root then break end
                            ctx = ctx .. " " .. tostring(p.Name or "")
                            p = p.Parent
                        end
                        if dance.looksLike(d.Name, ctx)
                           and addDance(d.Name, d.AnimationId) then
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
                        -- БЕРЁМ ТОЛЬКО ПОХОЖЕЕ НА АНИМАЦИЮ. Иначе в
                        -- список попадают ROLE_IMAGE, иконки, звуки:
                        -- в модулях игры полно rbxassetid://, но почти
                        -- все они - картинки.
                        -- Берём только танцевальные ключи. Раньше здесь
                        -- было общее "anim", и в список попадали походка,
                        -- оружие и катсцены (ID 19004... не запускались).
                        if dance.looksLike(k, m.Name) and normAnimId(v)
                           and addDance(tostring(k) .. " @ " .. m.Name, v) then
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

-- 3) ЭМОУТЫ ИЗ СЛОТОВ. EmoteSetSlots приходит с сервера при входе:
--    там список эмоутов игрока, а внутри почти наверняка и ID
--    анимаций. Разбираем таблицу и забираем всё, что похоже на анимацию.
-- 4) что игра играет прямо сейчас (ловушка на штатные эмоуты)
local function scanEmoteTable(t, depth, prefix)
    if depth > 3 then return end
    pcall(function()
        for k, v in pairs(t) do
            local key = tostring(k):lower()
            if type(v) == "string" then
                local low = key
                local looksAnim = (string.find(low, "anim", 1, true)
                    or string.find(low, "emote", 1, true)
                    or string.find(low, "dance", 1, true)
                    or string.find(low, "pose", 1, true)
                    or string.find(low, "id", 1, true))
                local looksBad = (string.find(low, "image", 1, true)
                    or string.find(low, "icon", 1, true)
                    or string.find(low, "sound", 1, true)
                    or string.find(low, "sfx", 1, true)
                    or string.find(low, "sfx_", 1, true))
                if looksAnim and not looksBad and normAnimId(v) then
                    local nm = string.gsub(tostring(k), "^%a+_", "")
                    if nm == "" or nm == tostring(k) then nm = tostring(k) end
                    addDance(nm, v)
                elseif not looksBad and dance.addEmote then
                    -- В слотах бывает не ID, а ИМЯ эмоута: "emote_dance".
                    -- Это тоже рабочий танец - игра играет его ремоутом.
                    local vl = string.lower(v)
                    if string.find(vl, "emote", 1, true)
                       or string.find(vl, "dance", 1, true)
                       or string.find(vl, "pose", 1, true) then
                        pcall(dance.addEmote, tostring(v))
                    end
                end
            elseif type(v) == "table" then
                scanEmoteTable(v, depth + 1, prefix .. "." .. tostring(k))
            end
        end
    end)
end

-- 4) что игра играет прямо сейчас (ловушка на штатные эмоуты)
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
            local trackName = tostring(t.Name or a.Name or "анимация")
            local nm = string.lower(trackName)
            -- Только танец/эмоут/поза, а не любая Action-анимация
            -- (оружие, удар, катсцена). Свой трек пропускаем всегда:
            -- он уже есть в списке под выбранным названием.
            if not MOVE_TRACKS[nm]
               and (dance.track == t
                    or dance.looksLike(trackName, tostring(a.Name or ""))) then
                if addDance(trackName, a.AnimationId) then
                    out[#out + 1] = string.format("%s  (%s, приоритет %s)",
                        trackName, a.AnimationId, tostring(t.Priority))
                    if all then
                        print("[BS DANCE] поймали анимацию игры: "
                            .. trackName .. " -> " .. tostring(a.AnimationId))
                    end
                end
            end
        end
    end
end

-- Ловим эмоут по ремоуту EmotePlay: когда игрок включает танец штатно,
-- игра шлёт EmotePlay:FireServer(...) с названием/ID. Разбираем
-- аргументы и забираем всё, что похоже на анимацию.
local emoteNames = {}
dance.emoteNames = emoteNames

local function captureEmoteArgs(...)
    local n = select("#", ...)
    if n > 6 then n = 6 end
    for i = 1, n do
        local a = select(i, ...)
        local t = typeof(a)
        if t == "string" then
            if normAnimId(a) then
                addDance("эмоут " .. i, a)
            else
                local low = string.lower(a)
                if string.find(low, "emote", 1, true)
                   or string.find(low, "dance", 1, true)
                   or string.find(low, "pose", 1, true)
                   or string.find(low, "wave", 1, true)
                   or string.find(low, "sit", 1, true) then
                    -- ИМЯ ЭМОУТА - самостоятельный танец: игра играет его
                    -- именно так (EmotePlay:FireServer("emote_dance")).
                    emoteNames[tostring(a)] = true
                    if dance.addEmote then pcall(dance.addEmote, tostring(a)) end
                end
            end
        elseif t == "table" then
            pcall(dance.pairIds, a, 0)
            pcall(scanEmoteTable, a, 1, "emoteplay")
        end
    end
end
dance.captureEmoteArgs = captureEmoteArgs

-- ЭМОУТЫ ИЗ СЛОТОВ: разбираем таблицу, которую игра прислала в
-- EmoteSetSlots (сервер шлёт её при входе - там список эмоутов).
local function scanEmoteSlots(out)
    for i = 1, #emoteTables do
        local before = #DANCES
        -- сначала связываем имена эмоутов с ID анимаций
        pcall(dance.pairIds, emoteTables[i], 0)
        pcall(scanEmoteTable, emoteTables[i], 0, "slots")
        if #DANCES > before then
            out[#out + 1] = "из EmoteSetSlots: +" .. (#DANCES - before) .. " анимаций"
        end
    end
end

-- КНОПКА «НАЙТИ ТАНЦЫ В ИГРЕ» + автозапуск при старте.
local function scanDances(silent)
    local out = {}
    local before = #DANCES
    scanAnimInstances(out)
    scanModuleIds(out)
    scanEmoteSlots(out)
    scanPlayingAnims(out, true)
    local added = #DANCES - before
    -- печатаем только имена (ID - в конце), чтобы не забить консоль
    if added == 0 then
        print("[BS DANCE] новых танцев не найдено (в списке уже "
            .. #DANCES .. ": emote_dance + классика).")
        print("[BS DANCE] Открой колесо эмоутов в игре (клавиша эмоутов) "
            .. "и включи любой танец - ID подхватится сам через хук "
            .. "LoadAnimation/PlayAnimation и EmotePlay.")
        addEvent("танцы: открой колесо эмоутов в игре - подхватятся сами")
    else
        print("[BS DANCE] найдено новых: " .. added
            .. " | всего в списке: " .. #DANCES)
        for i = 1, math.min(#out, 30) do
            print("   " .. i .. ") " .. tostring(out[i]))
        end
        if #out > 30 then print("   ... и ещё " .. (#out - 30)) end
    end
    if not silent then
        notify("Танцы", "Найдено новых: " .. added
            .. ". Всего: " .. #DANCES .. ". Список обновлён", 3)
    end
    return out
end

-- СТАРТ/СТОП ТАНЦА
local function restoreLowered()
    for _, t in ipairs(dance.lowered) do
        pcall(function()
            if t.__bsOldPrio ~= nil then
                t.Priority = t.__bsOldPrio
                t.__bsOldPrio = nil
            end
        end)
    end
    dance.lowered = {}
end

local function stopDance()
    restoreLowered()
    if dance.track then
        local tr = dance.track
        -- сначала забываем трек, иначе его Stopped-событие решит, что
        -- танец оборвался случайно, и запустит его заново
        dance.track, dance.anim = nil, nil
        pcall(function() tr:Stop(0.15) end)
        pcall(function() tr:Destroy() end)
    end
    dance.yaw, dance.prevYaw = 0, 0
    dance.emoteAt = 0
    dance.lowerAt = 0
    dance.playTryAt = 0
    -- старая ловушка эмоута не должна сработать на анимацию другого танца
    dance.pendingEmote = nil
    -- AutoRotate здесь НЕ трогаем: им владеет SPIN (спин и поворот под
    -- аимлок). Раньше stopDance возвращал сохранённое false, и после
    -- смены танца персонаж застывал лицом в одну сторону.
end

-- ЗАПУСК АНИМАЦИИ ПО ID (и для обычных танцев, и для эмоутов).
-- Локальная петля на Action4: ходьба её не отменяет, в отличие от
-- штатного эмоута, который игра сбрасывает при движении.
dance.playId = function(id, silent)
    id = normAnimId(tostring(id))
    if not id then return false end
    local ch = LP and LP.Character
    if not ch then return false end
    local hum = ch:FindFirstChildOfClass("Humanoid")
    if not hum or hum.Health <= 0 then return false end
    local animator = hum:FindFirstChildOfClass("Animator")
    if not animator then return false end
    if dance.track then
        local old = dance.track
        dance.track, dance.anim = nil, nil
        pcall(function() old:Stop(0.15) end)
        pcall(function() old:Destroy() end)
    end
    restoreLowered()
    dance.animator = animator
    local anim = Instance.new("Animation")
    anim.AnimationId = "rbxassetid://" .. id
    -- Свой LoadAnimation не должен попадать в ловушку pendingEmote:
    -- иначе хук решал, что это игра загрузила эмоут, и перезапускал
    -- наш же трек через task.defer (танец дёргался через кадр).
    dance.selfLoad = true
    local ok, tr = pcall(function() return animator:LoadAnimation(anim) end)
    dance.selfLoad = false
    if not ok or not tr then
        if not silent then
            print("[BS DANCE] LoadAnimation не удался: " .. tostring(tr))
        end
        return false
    end
    tr.Looped  = true
    tr.Priority = Enum.AnimationPriority.Action4
    -- Походка игры может быть на Core (127) - она выше Action4 и
    -- перебила бы танец. Опускаем такие треки до Action2.
    pcall(function()
        for _, t in ipairs(animator:GetPlayingAnimationTracks()) do
            if t ~= tr and t.Priority.Value >= CORE_P and t.__bsOldPrio == nil then
                t.__bsOldPrio = t.Priority
                t.Priority = Enum.AnimationPriority.Action2
                dance.lowered[#dance.lowered + 1] = t
            end
        end
    end)
    pcall(function() tr:Play(0.25) end)
    dance.track, dance.anim = tr, anim
    -- Если игра всё-таки остановит трек (некоторые эмоут-скрипты глушат
    -- все анимации при движении), поднимаем его через 0.1 с. Остановку
    -- по нашей команде отсекаем по dance.track == tr.
    pcall(function()
        tr.Stopped:Connect(function()
            if dance.track ~= tr or not dance.on then return end
            task.delay(0.1, function()
                if dance.track ~= tr or not dance.on then return end
                local eid = dance.findId(dance.emote)
                if eid then pcall(dance.playId, eid, true) end
            end)
        end)
    end)
    return true
end

-- ПЕРЕХВАТ ID ЭМОУТА. Игра после EmotePlay сама грузит анимацию;
-- запоминаем её ID, чтобы дальше играть локальной петлёй (на ходу).
dance.captureId = function(name)
    local ch = LP and LP.Character
    local hum = ch and ch:FindFirstChildOfClass("Humanoid")
    local animator = hum and hum:FindFirstChildOfClass("Animator")
    if not animator then return end
    local before = {}
    pcall(function()
        for _, t in ipairs(animator:GetPlayingAnimationTracks()) do
            before[t] = true
        end
    end)
    task.delay(0.35, function()
        if not dance.on or dance.emote ~= name then return end
        pcall(function()
            for _, t in ipairs(animator:GetPlayingAnimationTracks()) do
                -- Свой локальный трек не считаем эмоутом игры: иначе
                -- через 0.35 с он «находился» и перезапускался.
                if not before[t] and t ~= dance.track
                   and t.Animation and t.Animation.AnimationId ~= "" then
                    -- отсекаем походку: она ниже Action и часто грузится
                    -- как раз в момент, когда персонаж пошёл
                    local anm = string.lower(tostring(t.Animation.Name or ""))
                    local prio = (t.Priority and t.Priority.Value) or 0
                    if not MOVE_TRACKS[anm]
                       and prio >= Enum.AnimationPriority.Action.Value then
                        local id = normAnimId(t.Animation.AnimationId)
                        if id then
                            local known = dance.emoteId[name]
                            dance.emoteId[name] = id
                            print("[BS DANCE] эмоут " .. tostring(name)
                                .. " -> " .. id .. " (локальная петля)")
                            if known ~= id then
                                pcall(dance.playId, id, true)
                            end
                        end
                        return
                    end
                end
            end
        end)
    end)
end

local function startDance(silent)
    stopDance()
    -- ЭМОУТ: играем штатным ремоутом игры. Работает даже если ни одной
    -- анимации не нашлось - имя эмоута есть всегда.
    if dance.emote then
        dance.emoteAt = os.clock()
        local eid = dance.findId(dance.emote)
        -- ставим ловушку ДО FireServer: новый трек = анимация эмоута
        pcall(dance.captureId, dance.emote)
        pcall(dance.fireEmote, dance.emote)
        -- если ID уже известен - сразу дублируем локальной петлёй
        if eid then pcall(dance.playId, eid, true) end
        return true
    end
    if not (dance.id and dance.label ~= "") then
        -- ассет не выбран - работают только спин/покачивание
        return true
    end
    local ok = dance.playId(dance.id, silent)
    if not ok then return false end
    local tr = dance.track
    -- ассет может не принадлежать игре - тогда трек молча не пойдёт
    task.delay(0.7, function()
        -- captureId/captureAnimArg могли заменить трек своим (эмоут
        -- перехватил ID). Это НЕ ошибка: старый tr уже остановлен.
        if dance.track ~= tr then return end
        local playing = false
        pcall(function() playing = tr and tr.IsPlaying end)
        if tr and not playing then
            print("[BS DANCE] анимация «" .. tostring(dance.label) .. "» НЕ "
                .. "запустилась: скорее всего ассет не принадлежит этой игре. "
                .. "Выбери другой танец в списке.")
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
        stopDance()
    end
end

-- Перезапуск танца при смене раунда/респавне (вызывается из фазы и
-- CharacterAdded через G.BS, чтобы не держать ссылку на setDance).
G.BS.DanceRestart = function()
    if dance.on then pcall(setDance, true) end
end

local function pickDance(id, label)
    -- Принимаем и ID, и название: из dropdown приходит пара (id, label),
    -- из консоли можно передать только название.
    local key = tostring(label or "")
    local e = dance.entry[key]
    dance.label = key ~= "" and key or tostring(dance.label or "")
    if id == nil and e then
        -- выбрали запись из списка: у неё может быть ID или имя эмоута
        dance.id    = e.id
        dance.emote = e.emote
    else
        dance.id    = id or DANCE_BY_NAME[key]
        dance.emote = nil
    end
    if dance.on then startDance(true) end
end
dance.pick = pickDance

-- Имя текущего танца для HUD (updateHud объявлен раньше dance, поэтому
-- он зовёт эту функцию через G.BS, а не через локальную переменную).
G.BS.DanceName = function()
    local nm
    if dance.emote then
        nm = "эмоут " .. tostring(dance.emote)
    elseif dance.id then
        nm = tostring(dance.label) .. " …" .. string.sub(tostring(dance.id), -5)
    else
        nm = tostring(dance.label or "?")
        if nm == "" then nm = "?" end
    end
    if dance.on then return nm end
    return "выкл (" .. nm .. ")"
end

-- СПИН + ПОВОРОТ ПОД АИМЛОК. Раньше спин крутил HRP в Heartbeat, а
-- danceTick В ТО ЖЕ ВРЕМЯ крутил всю модель через PivotTo. Два поворота
-- за кадр давали рывки и «телепорт» на ходу. Теперь владелец поворота
-- один — SPIN:
--   * спин крутит HumanoidRootPart.CFrame напрямую (не PivotTo);
--   * при аимлоке персонаж доворачивается по камере (SPIN.face), чтобы
--     идти вперёд туда, куда смотрит камера, а не в старую сторону;
--   * AutoRotate выключается на время любого из этих поворотов и
--     возвращается, когда не осталось владельцев. Раньше stopDance
--     возвращал сохранённое false — персонаж застывал лицом в одну
--     сторону после смены танца.
-- Всё сложено в одну таблицу SPIN: главный блок скрипта упирается в
-- лимит локальных переменных Lua (200).
local SPIN = { conn = nil, owners = {}, hum = nil, savedAuto = nil }

-- Вернуть AutoRotate. false могло остаться от старой версии (danceTick
-- выключал его и не возвращал) или от ragdoll. В обычном состоянии
-- персонаж обязан доворачиваться по движению, поэтому false лечим на true.
function SPIN.restoreAuto(hum, saved)
    if not (hum and hum.Parent) then return end
    local st, ok = nil, false
    pcall(function()
        st = hum:GetState()
        ok = true
    end)
    if saved == false and ok
       and st ~= Enum.HumanoidStateType.Physics
       and st ~= Enum.HumanoidStateType.Seated then
        saved = true
    end
    if saved ~= nil then
        pcall(function() hum.AutoRotate = saved end)
    end
end

-- Захватить AutoRotate (owner = "spin" или "face").
function SPIN.hold(owner, hum)
    if not hum then return end
    if SPIN.hum and SPIN.hum ~= hum then
        -- респавн: старому гуманоиду возвращаем его настройку
        local old, saved = SPIN.hum, SPIN.savedAuto
        SPIN.restoreAuto(old, saved)
        SPIN.hum, SPIN.savedAuto = nil, nil
        SPIN.owners = {}
    end
    if not SPIN.hum then
        SPIN.hum = hum
        SPIN.savedAuto = hum.AutoRotate
    end
    if owner then SPIN.owners[owner] = true end
    if hum.AutoRotate then
        pcall(function() hum.AutoRotate = false end)
    end
end

-- Отпустить владельца. AutoRotate вернётся только когда владельцев нет.
function SPIN.release(owner)
    if owner then SPIN.owners[owner] = nil end
    if next(SPIN.owners) then return end
    local hum, saved = SPIN.hum, SPIN.savedAuto
    SPIN.restoreAuto(hum, saved)
    SPIN.hum, SPIN.savedAuto = nil, nil
end

function SPIN.releaseAll()
    SPIN.owners = {}
    local hum, saved = SPIN.hum, SPIN.savedAuto
    SPIN.restoreAuto(hum, saved)
    SPIN.hum, SPIN.savedAuto = nil, nil
end

-- ПОВОРОТ ПО КАМЕРЕ. Вызывается из aimLockTick, когда камера уже
-- довернулась на цель. Крутим только yaw и сохраняем позицию/наклон,
-- поэтому это не телепорт и не мешает ходьбе.
function SPIN.face(look, dt)
    if not look then return end
    -- Спин — главный: пока он включён, аимлок не должен перебивать yaw.
    if SPIN.owners.spin then
        pcall(SPIN.release, "face")
        return
    end
    local ch = LP and LP.Character
    local hum = ch and ch:FindFirstChildOfClass("Humanoid")
    local hrp = ch and ch:FindFirstChild("HumanoidRootPart")
    if not (hum and hrp and hum.Health > 0) then
        pcall(SPIN.release, "face")
        return
    end
    -- В машине/на лежачем/в физике персонажа не доворачиваем: там
    -- CFrame root-а управляет игра, и наш поворот только дёргал бы модель.
    if hum.SeatPart then
        pcall(SPIN.release, "face")
        return
    end
    local st, stOk = nil, false
    pcall(function()
        st = hum:GetState()
        stOk = true
    end)
    if stOk and st == Enum.HumanoidStateType.Physics then
        pcall(SPIN.release, "face")
        return
    end
    local flat = Vector3.new(look.X, 0, look.Z)
    if flat.Magnitude < 0.01 then
        -- смотрим строго вниз/вверх: yaw не определён, отпускаем владение,
        -- иначе AutoRotate остался бы false и персонаж снова застыл бы
        pcall(SPIN.release, "face")
        return
    end
    flat = flat.Unit
    local cur = hrp.CFrame.LookVector
    local curFlat = Vector3.new(cur.X, 0, cur.Z)
    if curFlat.Magnitude < 0.01 then
        curFlat = Vector3.new(0, 0, -1)
    else
        curFlat = curFlat.Unit
    end
    local desiredYaw = math.atan2(-flat.X, -flat.Z)
    local curYaw = math.atan2(-curFlat.X, -curFlat.Z)
    local diff = (desiredYaw - curYaw + math.pi) % (2 * math.pi) - math.pi
    if math.abs(diff) < 0.003 then
        SPIN.hold("face", hum)
        return
    end
    -- Ограничение скорости: на лаге dt большой, и без него персонаж
    -- проворачивался бы рывком (снова «телепорт»).
    local maxStep = math.rad(1200) * math.max(dt or 0.016, 0.001)
    if diff > maxStep then diff = maxStep
    elseif diff < -maxStep then diff = -maxStep end
    SPIN.hold("face", hum)
    local pos = hrp.Position
    pcall(function()
        hrp.CFrame = CFrame.new(pos)
            * CFrame.Angles(0, diff, 0) * (hrp.CFrame - pos)
    end)
end

function SPIN.stop()
    if SPIN.conn then pcall(function() SPIN.conn:Disconnect() end) end
    SPIN.conn = nil
    pcall(SPIN.release, "spin")
end

function SPIN.start()
    if SPIN.conn then return end
    SPIN.conn = RunService.Heartbeat:Connect(function(dt)
        if STOPPED then return end
        if not G.BS.Spin then
            pcall(SPIN.release, "spin")
            return
        end
        pcall(function()
            local ch = LP and LP.Character
            if not ch then return end
            local hrp = ch:FindFirstChild("HumanoidRootPart")
            local hum = ch:FindFirstChildOfClass("Humanoid")
            if not hrp or not hrp.Parent then return end
            if hum and hum.Health <= 0 then return end
            -- спин крутит и на ходу, и стоя (движение не мешает)
            SPIN.hold("spin", hum)
            -- зажимаем скорость: сохранённые настройки Rayfield могли
            -- остаться от старой версии (там было 360, а формула
            -- умножает скорость ещё на 3 - персонаж крутился бы рывками)
            local spd = tonumber(G.BS.SpinSpeed) or 50
            if spd < 5 then spd = 5 elseif spd > 200 then spd = 200 end
            -- ограничиваем шаг: при просадке FPS dt=0.2 дал бы рывок
            local step = math.min(math.max(dt or 0.016, 0.001), 0.05)
            local delta = spd * step * 3
            -- Крутим вокруг МИРОВОЙ Y, сохраняя позицию и наклон HRP:
            -- локальный Y при наклоне модели давал бы вихляние.
            local pos = hrp.Position
            hrp.CFrame = CFrame.new(pos)
                * CFrame.Angles(0, math.rad(delta), 0)
                * (hrp.CFrame - pos)
        end)
    end)
end

function SPIN.set(on)
    on = on and true or false
    G.BS.Spin = on
    dance.spin = on
    if on then
        dance.yaw, dance.prevYaw = 0, 0
        pcall(SPIN.start)
    else
        pcall(SPIN.stop)
    end
end

-- КАЖДЫЙ КАДР: только поддержка анимации. Поворот (спин и доворот под
-- аимлок) живёт в SPIN — второго PivotTo здесь больше нет, иначе модель
-- крутилась дважды за кадр и на ходу казалось, что персонаж телепортит.
local function danceTick(_, now)
    if not dance.on then return end
    -- ЭМОУТ. Если знаем ID анимации - играем локальную петлю, которую
    -- ходьба НЕ сбрасывает. Раньше эмоут перезапускался каждые 2.5 с,
    -- из-за чего танец дёргался и «отваливался» на ходу.
    if dance.emote then
        local eid = dance.findId(dance.emote)
        if eid then
            local playing = false
            pcall(function() playing = dance.track and dance.track.IsPlaying end)
            if not playing and now - (dance.playTryAt or 0) > 1 then
                dance.playTryAt = now
                pcall(dance.playId, eid, true)
            end
        elseif now - (dance.emoteAt or 0) > 1.2 then
            -- ID ещё не поймали: повторяем эмоут, пока captureId не
            -- подхватит анимацию (обычно с первого раза)
            dance.emoteAt = now
            pcall(dance.fireEmote, dance.emote)
        end
    end
    -- раз в секунду: если игра пересоздала походку на Core - опускаем,
    -- иначе она перебьёт танец на ходу
    if dance.track and now - (dance.lowerAt or 0) > 1 then
        dance.lowerAt = now
        local lch = LP and LP.Character
        local lhum = lch and lch:FindFirstChildOfClass("Humanoid")
        local lanim = lhum and lhum:FindFirstChildOfClass("Animator")
        if lanim then
            pcall(function()
                for _, t in ipairs(lanim:GetPlayingAnimationTracks()) do
                    if t ~= dance.track and t.Priority.Value >= CORE_P
                       and t.__bsOldPrio == nil then
                        t.__bsOldPrio = t.Priority
                        t.Priority = Enum.AnimationPriority.Action2
                        dance.lowered[#dance.lowered + 1] = t
                    end
                end
            end)
        end
    end
    -- Поворот (спин и доворот под аимлок) делает SPIN в Heartbeat.
    -- Здесь НЕЛЬЗЯ трогать PivotTo или AutoRotate: иначе получается
    -- второй поворот за кадр, персонаж дёргается/«телепортит» при ходьбе,
    -- а после смены танца застывает лицом в одну сторону.
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
--  УСКОРЕНИЕ И СИЛА ПРЫЖКА
-- ============================================================
-- Ускоритель по Левому Shift удалён по просьбе. Остался только
-- рывок при каждом прыжке: WalkSpeed умножается на JumpBoostMul на
-- JumpBoostTime секунд, плюс небольшой горизонтальный импульс по
-- направлению движения - тогда ускорение видно сразу.
-- Отдельно есть СИЛА ПРЫЖКА: множитель JumpPower/JumpHeight (высота),
-- ползунком до 10 x. База берётся от естественного значения игры.
-- v11.32: вернулся и СПИД БУСТ (постоянное ускорение WalkSpeed) —
-- пользователь попросил вернуть его, раньше он был только в коде.
local speedState = { base = nil, hum = nil, jumpHum = nil, jumpConn = nil,
                     active = false, conn = nil, boosted = false,
                     glitchUntil = 0,
                     jumpBasePower = nil, jumpBaseHeight = nil,
                     jumpApplied = false }

function speedState.restore()
    local hum = speedState.hum
    if hum and hum.Parent and speedState.base then
        pcall(function() hum.WalkSpeed = speedState.base end)
    end
    speedState.active = false
    G.BS._jumpUntil = 0
end

-- Вернуть JumpPower/JumpHeight к естественным значениям игры.
function speedState.restoreJump()
    local hum = speedState.hum
    if not hum or not hum.Parent then return end
    if speedState.jumpBasePower and speedState.jumpBasePower >= 1 then
        pcall(function() hum.JumpPower = speedState.jumpBasePower end)
    end
    if speedState.jumpBaseHeight and speedState.jumpBaseHeight >= 1 then
        pcall(function() hum.JumpHeight = speedState.jumpBaseHeight end)
    end
    speedState.jumpApplied = false
end

-- Поднимать высоту прыжка до нужного множителя. Вызывается каждый
-- физический шаг: игра может сбрасывать значения обратно.
function speedState.jumpPowerTick(hum)
    if not hum or not hum.Parent or hum.Health <= 0 then return end
    local on = G.BS.JumpPowerOn ~= false
    local mul = tonumber(G.BS.JumpPowerMul) or 1.5
    if mul < 1 then mul = 1 elseif mul > 10 then mul = 10 end
    if not on or mul <= 1.001 then
        -- буст выключен: вернуть игру исходные значения и запомнить
        -- естественную базу, чтобы множитель считался от неё.
        if speedState.jumpApplied then
            speedState.restoreJump()
        end
        local jp = tonumber(hum.JumpPower) or 0
        local jh = tonumber(hum.JumpHeight) or 0
        if jp >= 1 then speedState.jumpBasePower = jp end
        if jh >= 1 then speedState.jumpBaseHeight = jh end
        return
    end
    -- базу берём только когда буст ещё не применён: иначе через
    -- несколько кадров множитель считался бы от уже поднятого значения.
    if not speedState.jumpBasePower or speedState.jumpBasePower < 1 then
        local jp = tonumber(hum.JumpPower) or 0
        speedState.jumpBasePower = (jp >= 1) and jp or 50
    end
    if not speedState.jumpBaseHeight or speedState.jumpBaseHeight < 1 then
        local jh = tonumber(hum.JumpHeight) or 0
        speedState.jumpBaseHeight = (jh >= 1) and jh or 7.2
    end
    local bp = speedState.jumpBasePower
    local bh = speedState.jumpBaseHeight
    local wantP = bp * mul
    local wantH = bh * mul
    if math.abs((tonumber(hum.JumpPower) or 0) - wantP) > 0.01 then
        pcall(function() hum.JumpPower = wantP end)
    end
    if math.abs((tonumber(hum.JumpHeight) or 0) - wantH) > 0.01 then
        pcall(function() hum.JumpHeight = wantH end)
    end
    speedState.jumpApplied = true
end

function speedState.stop()
    if speedState.conn then
        pcall(function() speedState.conn:Disconnect() end)
    end
    speedState.conn = nil
    if speedState.jumpConn then
        pcall(function() speedState.jumpConn:Disconnect() end)
    end
    speedState.jumpConn = nil
    if speedState.charConn then
        pcall(function() speedState.charConn:Disconnect() end)
    end
    speedState.charConn = nil
    speedState.jumpHum = nil
    speedState.restore()
    speedState.restoreJump()
    speedState.hum, speedState.base = nil, nil
    speedState.jumpBasePower, speedState.jumpBaseHeight = nil, nil
    speedState.jumpApplied = false
end

-- РЫВОК ПРИ ПРЫЖКЕ. Главная ошибка старой версии: base запоминался
-- один раз при появлении персонажа, когда WalkSpeed ещё 0. Теперь base
-- берётся в момент прыжка (последнее нормальное значение), а множитель
-- принудительно держится каждый физический шаг — игра не успевает
-- сбросить WalkSpeed обратно.
function speedState.hookJump()
    if speedState.conn then
        pcall(function() speedState.conn:Disconnect() end)
    end
    speedState.conn = RunService.Stepped:Connect(function()
        if STOPPED then return end
        local hum = speedState.hum
        if not hum or not hum.Parent or hum.Health <= 0 then return end
        -- высота прыжка — независимо от горизонтального разгона
        speedState.jumpPowerTick(hum)
        local now = os.clock()
        if speedState.active and now < (G.BS._jumpUntil or 0) then
            local base = speedState.base or 16
            local mul = tonumber(G.BS.JumpBoostMul) or 1.7
            if mul < 1.1 then mul = 1.1 elseif mul > 10 then mul = 10 end
            pcall(function() hum.WalkSpeed = base * mul end)
        elseif speedState.active then
            local base = speedState.base or 16
            pcall(function() hum.WalkSpeed = base end)
            speedState.active = false
            G.BS._jumpUntil = 0
        elseif G.BS.SpeedGlitch and now < (speedState.glitchUntil or 0) then
            -- СПИД ГЛИТЧ (v11.43): прыгнул — пошёл разгон (WalkSpeed x N).
            -- Подброс вверх и настройка длительности УДАЛЕНЫ по просьбе:
            -- разгон держится фиксированное время после прыжка.
            local base = speedState.base
            if not base or base < 1 then
                base = tonumber(hum.WalkSpeed) or 16
                if base < 1 then base = 16 end
                speedState.base = base
            end
            local mul = tonumber(G.BS.SpeedGlitchMul) or 2.5
            if mul < 1.1 then mul = 1.1 elseif mul > 6 then mul = 6 end
            pcall(function() hum.WalkSpeed = base * mul end)
            speedState.boosted = true
        else
            -- буст выключили — один раз вернуть естественную скорость
            if speedState.boosted then
                speedState.boosted = false
                local base = speedState.base or 16
                pcall(function() hum.WalkSpeed = base end)
            end
            -- пока рывка нет — запоминаем актуальную базовую скорость
            local ws = tonumber(hum.WalkSpeed) or 0
            if ws >= 1 then speedState.base = ws end
        end
    end)

    local function bind(ch)
        if STOPPED then return end
        local hum = ch and ch:WaitForChild("Humanoid", 10)
        if not hum then return end
        if speedState.hum ~= hum then
            speedState.hum = hum
            speedState.active = false
            speedState.base = nil
            speedState.jumpBasePower = nil
            speedState.jumpBaseHeight = nil
            speedState.jumpApplied = false
            G.BS._jumpUntil = 0
        end
        if not speedState.active then
            local ws0 = tonumber(hum.WalkSpeed) or 0
            if ws0 >= 1 then speedState.base = ws0 end
        end
        -- запоминаем естественную высоту прыжка игры
        if not speedState.jumpBasePower or speedState.jumpBasePower < 1 then
            local jp = tonumber(hum.JumpPower) or 0
            speedState.jumpBasePower = (jp >= 1) and jp or 50
        end
        if not speedState.jumpBaseHeight or speedState.jumpBaseHeight < 1 then
            local jh = tonumber(hum.JumpHeight) or 0
            speedState.jumpBaseHeight = (jh >= 1) and jh or 7.2
        end
        -- не подключаем второй Jumping к тому же гуманоиду (двойной
        -- импульс, если CharacterAdded сработал повторно)
        if speedState.jumpHum == hum then return end
        if speedState.jumpConn then
            pcall(function() speedState.jumpConn:Disconnect() end)
            speedState.jumpConn = nil
        end
        speedState.jumpHum = hum
        speedState.jumpConn = hum.Jumping:Connect(function(active)
            if STOPPED or not active then return end
            if speedState.hum ~= hum then return end
            if not hum.Parent or hum.Health <= 0 then return end
            -- СПИД ГЛИТЧ (v11.36): прыжок сам запускает разгон. Работает
            -- независимо от старого рывка JumpBoostV2.
            if G.BS.SpeedGlitch then
                -- v11.43: длительность разгона убрана по просьбе —
                -- фиксированное время после прыжка.
                speedState.glitchUntil = os.clock() + 1.2
                local baseG = speedState.base
                if not baseG or baseG < 1 then
                    baseG = tonumber(hum.WalkSpeed) or 16
                    if baseG < 1 then baseG = 16 end
                    speedState.base = baseG
                end
                local mulG = tonumber(G.BS.SpeedGlitchMul) or 2.5
                if mulG < 1.1 then mulG = 1.1 elseif mulG > 6 then mulG = 6 end
                pcall(function() hum.WalkSpeed = baseG * mulG end)
                speedState.boosted = true
                -- мгновенный горизонтальный толчок по направлению бега
                local hrpG = ch:FindFirstChild("HumanoidRootPart")
                local mdG = hum.MoveDirection
                if hrpG and hrpG.Parent and mdG.Magnitude > 0.05 then
                    local dirG = mdG.Unit
                    local impG = baseG * (mulG - 1) * 1.1
                    local vG = hrpG.AssemblyLinearVelocity
                    pcall(function()
                        hrpG.AssemblyLinearVelocity = Vector3.new(
                            vG.X + dirG.X * impG, vG.Y, vG.Z + dirG.Z * impG)
                    end)
                end
            end
            if G.BS.JumpBoostV2 == false then return end
            local base = speedState.base
            if not base or base < 1 then
                base = tonumber(hum.WalkSpeed) or 16
                if base < 1 then base = 16 end
                speedState.base = base
            end
            local t = tonumber(G.BS.JumpBoostTime) or 0.8
            if t < 0.2 then t = 0.2 elseif t > 5 then t = 5 end
            local mul = tonumber(G.BS.JumpBoostMul) or 1.7
            if mul < 1.1 then mul = 1.1 elseif mul > 10 then mul = 10 end
            G.BS._jumpUntil = os.clock() + t
            speedState.active = true
            pcall(function() hum.WalkSpeed = base * mul end)
            -- горизонтальный импульс по направлению бега: одного
            -- WalkSpeed мало, персонаж разгоняется плавно
            local hrp = ch:FindFirstChild("HumanoidRootPart")
            local md = hum.MoveDirection
            if hrp and md.Magnitude > 0.05 then
                local dir = md.Unit
                local imp = base * (mul - 1) * 1.2
                local v = hrp.AssemblyLinearVelocity
                pcall(function()
                    hrp.AssemblyLinearVelocity = Vector3.new(
                        v.X + dir.X * imp, v.Y, v.Z + dir.Z * imp)
                end)
            end
        end)
    end
    if LP.Character then bind(LP.Character) end
    -- Соединение храним, чтобы stop() мог его снять. Раньше каждый
    -- повторный запуск добавлял ещё один CharacterAdded.
    if speedState.charConn then
        pcall(function() speedState.charConn:Disconnect() end)
    end
    speedState.charConn = LP.CharacterAdded:Connect(bind)
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
--  ХИТМАРКЕР УДАЛЁН (v11.32) по просьбе — лишняя вспышка в центре
--  экрана. Код выстрела и урона остался (цифры урона, трейсер).
-- ============================================================

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

-- Лента событий в GUI удалена: всё уходит в консоль через addEvent.

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
-- ============================================================
--  ПАТРОНЫ: ПОПОЛНЕНИЕ ИЗ SUPPLY CACHES
-- ============================================================
-- В Workspace.SupplyCaches лежат модели SupplyCrate. Внутри — Ammo Box
-- и Main. Игра может требовать ProximityPrompt, ClickDetector или
-- обычное Touched. Поэтому пробуем все способы, а если не вышло —
-- печатаем структуру ящика в консоль ([BS AMMO]).
G.BS.AmmoAuto     = G.BS.AmmoAuto ~= false
G.BS.AmmoTeleport = G.BS.AmmoTeleport ~= false
G.BS.AmmoAutoTP   = G.BS.AmmoAutoTP == true
G.BS.AmmoRange    = tonumber(G.BS.AmmoRange) or 25
G.BS.AmmoSearch   = tonumber(G.BS.AmmoSearch) or 600
G.BS.AmmoEvery    = tonumber(G.BS.AmmoEvery) or 4
-- ПОРОГ АВТО-ПОПОЛНЕНИЯ. 0 = пополнять ТОЛЬКО когда патроны кончились
-- (0 шт) — именно это просил пользователь: раньше терял 1 патрон и
-- персонажа бесконечно телепортировало к ящику. 0.5 = 50% и ниже.
G.BS.AmmoLowPct   = tonumber(G.BS.AmmoLowPct)
if G.BS.AmmoLowPct == nil then G.BS.AmmoLowPct = 0 end
if G.BS.AmmoLowPct < 0 then G.BS.AmmoLowPct = 0 end
if G.BS.AmmoLowPct > 1 then G.BS.AmmoLowPct = 1 end
-- ЯЩИК КО МНЕ: вместо телепорта игрока к ящику временно подвозим
-- сам ящик к игроку, пополняем и возвращаем на место.
G.BS.AmmoBringCrate = G.BS.AmmoBringCrate ~= false

-- Весь модуль в do-блоке: его локальные не расходуют лимит 200
-- локальных переменных главного блока (иначе luac падает).
do
local SUPPLY = {
    busy = false,
    lastAuto = 0,
    crates = {},
    -- -1e9, а не 0: os.clock() в начале процесса может быть < 1,
    -- и первый вызов вернул бы пустой кэш (тест это поймал).
    cratesAt = -1e9,
    -- Если последнее пополнение не помогло — пауза до этого момента
    -- (os.clock). Без неё персонаж телепортировался к ящику по кругу.
    failUntil = 0,
}

local function supplyList()
    local now = os.clock()
    if now - SUPPLY.cratesAt < 1 then return SUPPLY.crates end
    SUPPLY.cratesAt = now
    local out, seen = {}, {}
    local function hasPart(d)
        local ok, all = pcall(function() return d:GetDescendants() end)
        if not ok or type(all) ~= "table" then return false end
        for _, x in ipairs(all) do
            if x:IsA("BasePart") then return true end
        end
        return false
    end
    local folder = workspace:FindFirstChild("SupplyCaches")
    if folder then
        local ok, kids = pcall(function() return folder:GetChildren() end)
        if ok and type(kids) == "table" then
            for _, d in ipairs(kids) do
                -- Не только Model: ящик может быть Tool/Folder-обёрткой.
                if not seen[d] and hasPart(d) then
                    seen[d] = true
                    out[#out + 1] = d
                end
            end
        end
    end
    if #out == 0 then
        local ok, all = pcall(function() return workspace:GetDescendants() end)
        if ok and type(all) == "table" then
            for _, d in ipairs(all) do
                if (d:IsA("Model") or d:IsA("Tool") or d:IsA("Folder"))
                   and (d.Name == "SupplyCrate" or d.Name == "Supply Crate")
                   and not seen[d] then
                    local pn = d.Parent and d.Parent.Name or ""
                    if pn ~= "SupplyCrate" and pn ~= "Supply Crate"
                       and hasPart(d) then
                        seen[d] = true
                        out[#out + 1] = d
                    end
                end
            end
        end
    end
    SUPPLY.crates = out
    return out
end

local function supplyPos(crate)
    local ok, cf = pcall(function() return crate:GetPivot() end)
    if ok and cf then return cf.Position end
    local okA, all = pcall(function() return crate:GetDescendants() end)
    if okA and type(all) == "table" then
        for _, d in ipairs(all) do
            if d:IsA("BasePart") then return d.Position end
        end
    end
    return nil
end

local function supplyParts(crate)
    local ammo, any = {}, {}
    local ok, all = pcall(function() return crate:GetDescendants() end)
    if not (ok and type(all) == "table") then return ammo, any end
    for _, d in ipairs(all) do
        if d:IsA("BasePart") then
            any[#any + 1] = d
            local n = string.lower(tostring(d.Name))
            if string.find(n, "ammo", 1, true)
               or string.find(n, "patron", 1, true) then
                ammo[#ammo + 1] = d
            end
        end
    end
    return ammo, any
end

local function supplyPrompts(crate)
    local prompts, clicks = {}, {}
    local ok, all = pcall(function() return crate:GetDescendants() end)
    if not (ok and type(all) == "table") then return prompts, clicks end
    for _, d in ipairs(all) do
        if d:IsA("ProximityPrompt") then
            prompts[#prompts + 1] = d
        elseif d:IsA("ClickDetector") then
            clicks[#clicks + 1] = d
        end
    end
    return prompts, clicks
end

local function supplyEmpty(crate)
    -- Если на ящике висит "Empty"/"Пусто", не тратим на него заход:
    -- иначе ближайший пустой ящик перекрывал бы полный дальше.
    local ok, all = pcall(function() return crate:GetDescendants() end)
    if not ok or type(all) ~= "table" then return false end
    for _, d in ipairs(all) do
        if d:IsA("TextLabel") then
            local t = string.lower(tostring(d.Text or ""))
            if string.find(t, "empty", 1, true)
               or string.find(t, "пуст", 1, true) then
                return true
            end
        end
    end
    return false
end

local function supplyNearest(maxDist)
    local ch = LP and LP.Character
    local hrp = ch and ch:FindFirstChild("HumanoidRootPart")
    if not hrp then return nil, nil end
    if not maxDist or maxDist <= 0 then maxDist = math.huge end
    local best, bestD
    for _, c in ipairs(supplyList()) do
        if not supplyEmpty(c) then
            local p = supplyPos(c)
            if p then
                local d = (p - hrp.Position).Magnitude
                if d <= maxDist and (not bestD or d < bestD) then
                    best, bestD = c, d
                end
            end
        end
    end
    return best, bestD
end

local function supplyFirePrompt(p)
    if not (p and p.Parent and p.Enabled) then return false end
    local env = getgenv()
    local fn = env and env.fireproximityprompt
    if type(fn) == "function" then
        local ok = pcall(fn, p)
        if not ok then ok = pcall(fn, p, 0) end
        if ok then return true end
    end
    if type(p.InputHoldBegin) == "function" then
        local hold = tonumber(p.HoldDuration) or 0
        local ok = pcall(function()
            p:InputHoldBegin()
            task.delay(math.max(0.05, hold + 0.1), function()
                pcall(function() p:InputHoldEnd() end)
            end)
        end)
        if ok then return true end
    end
    return false
end

local function supplyFireClick(c)
    if not (c and c.Parent) then return false end
    local env = getgenv()
    local fn = env and env.fireclickdetector
    if type(fn) == "function" then
        return pcall(fn, c)
    end
    return false
end

local function supplyTouch(hrp, part)
    if not (hrp and hrp.Parent and part and part.Parent) then return false end
    if part.CanTouch == false then return false end
    local ok = pcall(function()
        local lift = math.max(1.8, part.Size.Y * 0.5 + 1.6)
        hrp.CFrame = part.CFrame * CFrame.new(0, lift, 0)
    end)
    if ok then task.wait(0.2) end
    return ok
end

-- Последний шанс: у игры может быть не ProximityPrompt, а свой
-- обработчик клавиши E на BillboardGui "Status". Жмём E виртуально.
local function supplyPressE()
    local ok = pcall(function()
        local vim = game:GetService("VirtualInputManager")
        vim:SendKeyEvent(true, Enum.KeyCode.E, false, game)
        task.wait(0.9)
        vim:SendKeyEvent(false, Enum.KeyCode.E, false, game)
    end)
    if ok then return true end
    local env = getgenv()
    if env and type(env.keypress) == "function" then
        pcall(env.keypress, 0x45)
        task.wait(0.9)
        if type(env.keyrelease) == "function" then
            pcall(env.keyrelease, 0x45)
        end
        return true
    end
    return false
end

function SUPPLY.scan()
    local crates = supplyList()
    local ch = LP and LP.Character
    local hrp = ch and ch:FindFirstChild("HumanoidRootPart")
    print("[BS AMMO] ящиков SupplyCrate: " .. #crates)
    for i, c in ipairs(crates) do
        local p = supplyPos(c)
        local dist = -1
        if p and hrp then dist = (p - hrp.Position).Magnitude end
        print(string.format("[BS AMMO] %d) %s | dist=%.1f", i,
            c:GetFullName(), dist))
        local ammo, any = supplyParts(c)
        print(string.format("   частей: %d, ammo: %d", #any, #ammo))
        for _, part in ipairs(ammo) do
            print(string.format("   PART %s [%s] CanTouch=%s size=(%.1f,%.1f,%.1f)",
                part.Name, part.ClassName, tostring(part.CanTouch),
                part.Size.X, part.Size.Y, part.Size.Z))
        end
        local prompts, clicks = supplyPrompts(c)
        for _, pr in ipairs(prompts) do
            print(string.format("   PROMPT %s | Action=%s | Object=%s | Hold=%.2f | MaxDist=%.1f | Enabled=%s",
                pr:GetFullName(), tostring(pr.ActionText), tostring(pr.ObjectText),
                tonumber(pr.HoldDuration) or 0,
                tonumber(pr.MaxActivationDistance) or 0, tostring(pr.Enabled)))
        end
        for _, cl in ipairs(clicks) do
            print(string.format("   CLICK %s | MaxDist=%.1f",
                cl:GetFullName(), tonumber(cl.MaxActivationDistance) or 0))
        end
        -- Текст на ящике ("Supply", "Empty", "Hold E") — видно, что
        -- игра вообще предлагает и не кончился ли запас.
        for _, d in ipairs(c:GetDescendants()) do
            if d:IsA("BillboardGui") then
                print("   GUI " .. d:GetFullName())
                for _, t in ipairs(d:GetDescendants()) do
                    if t:IsA("TextLabel") and t.Text ~= "" then
                        print("     TEXT " .. tostring(t.Name) .. "=" .. tostring(t.Text))
                    end
                end
            end
        end
        local okA, attrs = pcall(function() return c:GetAttributes() end)
        if okA and type(attrs) == "table" then
            local n = 0
            for k, v in pairs(attrs) do
                n = n + 1
                print("   ATTR " .. tostring(k) .. "=" .. tostring(v))
            end
            if n == 0 then print("   ATTR (нет)") end
        end
    end
    local cur, max, src = G.BS.ReadAmmo()
    print(string.format("[BS AMMO] сейчас: %s/%s (%s)",
        tostring(cur), tostring(max), tostring(src)))
end

function SUPPLY.refill(opts)
    opts = opts or {}
    if SUPPLY.busy then return false end
    local ch = LP and LP.Character
    local hum = ch and ch:FindFirstChildOfClass("Humanoid")
    local hrp = ch and ch:FindFirstChild("HumanoidRootPart")
    if not (hrp and hum and hum.Health > 0) then
        if not opts.silent then notify("патроны: персонаж не найден", 3) end
        return false
    end
    if hum.Sit or hum.SeatPart then
        if not opts.silent then notify("патроны: сначала встань", 3) end
        return false
    end

    local before, maxBefore = G.BS.ReadAmmo()
    if type(before) == "number" and type(maxBefore) == "number"
       and maxBefore > 0 and before >= maxBefore then
        if not opts.silent then
            notify("патроны уже полные: " .. before .. "/" .. maxBefore, 3)
        end
        return false
    end

    local crate, dist = supplyNearest(opts.search or G.BS.AmmoSearch)
    if not crate then
        if not opts.silent then
            notify("ящики с патронами не найдены (SupplyCaches)", 4)
        end
        return false
    end

    local nearRange = tonumber(opts.nearRange or G.BS.AmmoRange) or 25
    -- Кнопка/авто-телепорт должны реально оказаться у ящика, а не
    -- жать E с 20 студов: для forceTP считаем «рядом» максимум 8.
    if opts.forceTP then nearRange = math.min(nearRange, 8) end
    local mustTP = dist > nearRange
    -- ЯЩИК КО МНЕ: разрешаем «дальний» ящик, но двигаем не игрока,
    -- а сам ящик. Так персонаж остаётся на месте.
    local bringCrate = (opts.bringCrate and G.BS.AmmoBringCrate ~= false) and true or false
    local allowTP = opts.forceTP == true or G.BS.AmmoTeleport ~= false or bringCrate
    if mustTP and not allowTP then
        if not opts.silent then
            notify("ближайший ящик " .. math.floor(dist + 0.5)
                .. " st — подойди ближе или включи телепорт", 4)
        end
        return false
    end

    SUPPLY.busy = true
    local oldCF = hrp.CFrame
    local oldCrateCF = nil
    local touched = false
    local prompts, clicks
    local holdMax = 0
    local okRun = pcall(function()
        if mustTP then
            if bringCrate then
                -- ЯЩИК КО МНЕ: подвозим сам ящик к игроку, персонаж
                -- остаётся на месте. После пополнения вернём на место.
                local okP, cf = pcall(function() return crate:GetPivot() end)
                if okP and cf and crate.Parent then
                    oldCrateCF = cf
                    local target = hrp.CFrame * CFrame.new(0, 0, -3)
                    local okMove = pcall(function() crate:PivotTo(target) end)
                    local moved = false
                    if okMove then
                        local okN, newCF = pcall(function() return crate:GetPivot() end)
                        if okN and newCF and (newCF.Position - target.Position).Magnitude < 5 then
                            moved = true
                        end
                    end
                    if moved then
                        task.wait(0.25)
                    else
                        -- сервер/клиент не дал двигать ящик — откатываемся
                        -- на телепорт игрока, иначе пополнение сломается
                        oldCrateCF = nil
                        bringCrate = false
                    end
                else
                    oldCrateCF = nil
                    bringCrate = false
                end
            end
            if mustTP and not bringCrate then
                local ammo, any = supplyParts(crate)
                local part = ammo[1] or any[1]
                local p = supplyPos(crate)
                if part then
                    local lift = math.max(2.2, part.Size.Y * 0.5 + 1.8)
                    hrp.CFrame = part.CFrame * CFrame.new(0, lift, 0)
                elseif p then
                    hrp.CFrame = CFrame.new(p + Vector3.new(0, 5, 0))
                end
                task.wait(0.35)
            end
        end

        prompts, clicks = supplyPrompts(crate)
        local acted = false
        for _, pr in ipairs(prompts) do
            holdMax = math.max(holdMax, tonumber(pr.HoldDuration) or 0)
            if supplyFirePrompt(pr) then acted = true end
        end
        for _, cl in ipairs(clicks) do
            if supplyFireClick(cl) then acted = true end
        end
        if acted then
            task.wait(math.max(0.4, math.min(holdMax, 3) + 0.25))
        end

        local mid = G.BS.ReadAmmo()
        local needTouch = (not acted) or before == nil
            or (type(mid) == "number" and type(before) == "number"
                and mid <= before)
        -- Авто-режим не дёргает персонажа, если счётчик патронов не
        -- читается: иначе Touch-фолбэк телепортировал бы его каждые 4 с.
        if opts.noTouch then needTouch = false end
        if needTouch then
            -- Трогаем ВСЕ части ящика, а не только Ammo Box: сервер
            -- может слушать Touched на Main или на деревянной основе.
            local _, any = supplyParts(crate)
            for i = 1, math.min(#any, 8) do
                if supplyTouch(hrp, any[i]) then touched = true end
            end
        end

        -- Если ни промпт, ни касание не увеличили счётчик — жмём E.
        task.wait(0.2)
        local afterAction = G.BS.ReadAmmo()
        local improved = type(afterAction) == "number"
            and type(before) == "number" and afterAction > before
        if not improved then supplyPressE() end
    end)
    task.wait(0.2)
    local after, maxAfter = G.BS.ReadAmmo()
    -- После Touched возвращаемся на место. Если это был телепорт к
    -- ящику и «вернуться» выключено — остаёмся у ящика.
    if hrp.Parent and (not mustTP or G.BS.AmmoReturn ~= false) then
        pcall(function() hrp.CFrame = oldCF end)
    end
    -- возвращаем ящик на место, если мы его подвозили
    if oldCrateCF and crate.Parent then
        pcall(function() crate:PivotTo(oldCrateCF) end)
    end
    SUPPLY.busy = false

    -- ПАУЗА ПОСЛЕ НЕУДАЧИ. Если патроны не добавились, авто-пополнение
    -- не дёргает персонажа ещё 25 секунд. Без этого он телепортировался
    -- к ящику по кругу (пользователь жаловался именно на это).
    local gained = type(after) == "number" and type(before) == "number"
        and after > before
    if gained then
        SUPPLY.failUntil = 0
    else
        SUPPLY.failUntil = os.clock() + 25
    end

    if not opts.silent then
        if not okRun then
            notify("патроны: ошибка взаимодействия — [BS AMMO] в консоли", 5)
        elseif type(before) == "number" and type(after) == "number"
           and after > before then
            notify("патроны: " .. before .. " -> " .. after, 3)
        elseif type(after) == "number" and type(maxAfter) == "number"
           and after >= maxAfter then
            notify("патроны полные: " .. after .. "/" .. maxAfter, 3)
        elseif touched or (prompts and #prompts > 0)
           or (clicks and #clicks > 0) then
            notify("ящик обработан; если патроны не пополнились — [BS AMMO] в консоли", 5)
        else
            notify("в ящике нет зон взаимодействия — [BS AMMO] в консоли", 5)
        end
    end
    return okRun
end

function SUPPLY.autoTick(now)
    if not G.BS.AmmoAuto or SUPPLY.busy then return end
    local every = tonumber(G.BS.AmmoEvery) or 4
    if now - SUPPLY.lastAuto < every then return end
    local ch = LP and LP.Character
    local hum = ch and ch:FindFirstChildOfClass("Humanoid")
    local hrp = ch and ch:FindFirstChild("HumanoidRootPart")
    if not (hrp and hum and hum.Health > 0) then return end
    if hum.Sit or hum.SeatPart then return end
    -- Не трогаем персонажа, пока открыто меню Roblox (иначе авто-
    -- пополнение телепортирует его за спиной открытого меню).
    local menuOpen = false
    pcall(function()
        local uis = game:GetService("UserInputService")
        if uis and uis.ModalEnabled then menuOpen = true end
    end)
    pcall(function()
        local gs = game:GetService("GuiService")
        if gs and gs.MenuIsOpen then menuOpen = true end
    end)
    if menuOpen then return end

    -- Троттлинг ставим ДО поиска ящика: если ReadAmmo не читается,
    -- раньше supplyNearest вызывался каждый кадр и сканировал PlayerGui.
    SUPPLY.lastAuto = now

    local cur, max = G.BS.ReadAmmo()
    local known = type(cur) == "number" and type(max) == "number" and max > 0
    if known and cur >= max then
        return
    end
    -- ПОРОГ. 0 = пополнять ТОЛЬКО когда патроны КОНЧИЛИСЬ (0 шт).
    -- Раньше стояло 0.5, но в сохранённом конфиге оставался 0, а при 0
    -- срабатывало на ЛЮБОЙ недобор: потерял 1 патрон — персонаж
    -- телепортировался к ящику, ящик не помогал, и так по кругу.
    -- 0.5 = пополнять при 50% и ниже (как раньше по умолчанию).
    local lowPct = tonumber(G.BS.AmmoLowPct)
    if lowPct == nil then lowPct = 0 end
    if lowPct < 0 then lowPct = 0 end
    if lowPct > 1 then lowPct = 1 end
    if known then
        if lowPct <= 0 then
            -- только когда патронов не осталось совсем
            if cur > 0 then return end
        elseif cur > max * lowPct then
            return
        end
    end
    -- ПАУЗА ПОСЛЕ НЕУДАЧИ. Если пополнение не сработало — не дёргаемся
    -- ещё 25 секунд, иначе персонаж улетал к ящику бесконечно.
    if SUPPLY.failUntil and now < SUPPLY.failUntil then return end
    local near = supplyNearest(tonumber(G.BS.AmmoRange) or 25)
    if near then
        SUPPLY.lastAuto = now
        task.spawn(function()
            pcall(SUPPLY.refill, {
                nearRange = G.BS.AmmoRange, silent = true, forceTP = false,
                bringCrate = true,
                -- если счётчик не читается, не трогаем персонажа
                noTouch = not known,
            })
        end)
        return
    end
    if (G.BS.AmmoAutoTP or G.BS.AmmoBringCrate) and known then
        local far = supplyNearest(tonumber(G.BS.AmmoSearch) or 600)
        if far then
            SUPPLY.lastAuto = now
            task.spawn(function()
                pcall(SUPPLY.refill, { forceTP = true, silent = true, bringCrate = true })
            end)
        end
    end
end

G.BS.RefillAmmo = function()
    return SUPPLY.refill({ forceTP = true, bringCrate = true })
end
G.BS.ScanSupply = function()
    return SUPPLY.scan()
end
-- Доступ для GUI и кадра: G.BS.Supply.refill / .scan / .autoTick
G.BS.Supply = SUPPLY
end

-- ============================================================
--  ПОДСВЕТКА ТЕКУЩЕЙ ЦЕЛИ (тонкая обводка, без заливки)
-- ============================================================
-- Показывает, в кого именно сейчас наводится аим. Без неё легко
-- не понять, что скрипт выбрал соседа, а не того, кто по курсу.
-- Заливки нет (FillTransparency = 1) — это аккуратный контур, а не
-- тот красный шар, из-за которого подсветку тела убрали.
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
    local ot = math.clamp(tonumber(G.BS.TargetMarkAlpha) or 0.15, 0, 1)
    if TargetHL.OutlineTransparency ~= ot then TargetHL.OutlineTransparency = ot end
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
                    -- «Только видимые цели» УДАЛЁН (v11.32): прострел
                    -- работает всегда, цели за стеной не отбрасываются.
                    if (maxD <= 0 or d <= maxD) then
                        -- v11.43: «Только видимые цели» (тумблер в
                        -- аимлоке) — цель за стеной не попадает в список.
                        local visOK = true
                        if G.BS.AimVisibleOnly then
                            pcall(function()
                                WALLRAY.FilterDescendantsInstances =
                                    { LP.Character, ch }
                                local dirQ = q.Position - myRoot.Position
                                if dirQ.Magnitude > 1 then
                                    local h = workspace:Raycast(
                                        myRoot.Position, dirQ, WALLRAY)
                                    if h and not h.Instance:IsDescendantOf(ch)
                                       then visOK = false end
                                end
                            end)
                        end
                        if visOK then
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
                            dist = d, screen = scr, hp = hum.Health,
                        }
                        end -- visOK
                    end
                end
            end
        end
    end
    -- ПРИОРИТЕТ ЦЕЛИ. Раньше список всегда сортировался по близости к
    -- центру экрана, а настройка AimPriority влияла только на запасной
    -- pickTarget. Теперь и клиент-айм, и аимлок, и маркер используют
    -- один и тот же порядок.
    local prio = G.BS.AimPriority
    table.sort(bulletList, function(a, b)
        if prio == "Ближе по расстоянию" then
            if a.dist ~= b.dist then return a.dist < b.dist end
        elseif prio == "Больше HP" then
            local ha = tonumber(a.hp) or 0
            local hb = tonumber(b.hp) or 0
            if ha ~= hb then return ha > hb end
        else
            if a.screen ~= b.screen then return a.screen < b.screen end
        end
        if a.screen ~= b.screen then return a.screen < b.screen end
        return a.dist < b.dist
    end)
end

-- ТОЧКА ДЛЯ ТЕЛЕПОРТ-ВЫСТРЕЛА. Ищем место за целью, откуда она
-- видна и которое не находится внутри стены/пола/потолка. Раньше
-- бралась одна точка «4 студа за целью + 2.5 вверх»: если там была
-- стена, персонаж оказывался внутри геометрии и выстрел не проходил.
local GHOST_CACHE = { at = 0, char = nil, pos = nil, cf = nil }
local function findGhostSpot(aimPos, srcPos, bestChar)
    local toT = aimPos - srcPos
    local len = toT.Magnitude
    if len < 1 or not bestChar then return nil end
    local dir = toT / len
    local side = Vector3.new(-dir.Z, 0, dir.X)
    if side.Magnitude < 0.01 then
        side = Vector3.new(1, 0, 0)
    else
        side = side.Unit
    end
    local cands = {
        aimPos + dir * 4.0 + Vector3.new(0, 2.5, 0),
        aimPos + dir * 3.0 + side * 2.5 + Vector3.new(0, 2.5, 0),
        aimPos + dir * 3.0 - side * 2.5 + Vector3.new(0, 2.5, 0),
        aimPos + dir * 2.5 + Vector3.new(0, 4.0, 0),
    }
    for i = 1, #cands do
        local cand = cands[i]
        local ok, clear = pcall(function()
            WALLRAY.FilterDescendantsInstances = { LP.Character, bestChar }
            -- 1) от кандидата до цели не должно быть стены (иначе
            -- телепорт бессмысленен).
            local d = aimPos - cand
            local hit = workspace:Raycast(cand, d, WALLRAY)
            if hit and hit.Distance < d.Magnitude - 0.8 then return false end
            -- 2) кандидат не должен быть внутри коллизии.
            local overlap = workspace:GetPartBoundsInRadius(cand, 1.6, WALLRAY)
            for _, p in ipairs(overlap) do
                if p:IsA("BasePart") and p.CanCollide then return false end
            end
            return true
        end)
        if ok and clear then
            return cand, CFrame.lookAt(cand, aimPos)
        end
    end
    return nil
end

local function computeBulletPreShot()
    -- Считаем цель, если нужна ХОТЬ ОДНА функция: подмена патрона ИЛИ
    -- аимлок. Раньше аимлок зависел от клиент-аима и молчал, если тот
    -- выключен (жалоба: «аим не целится»).
    if not (G.BS.BulletSwap or G.BS.AimLock) then bulletPreShot = nil return end
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
    -- ПОВ: КРУГ АИМА. Цель берём только внутри круга (G.BS.AimFOV):
    -- игрок вошёл в круг - аимлок/выстрел работают, вышел - не трогаем.
    -- 600 и больше = без ограничения (весь экран).
    local FOV = tonumber(G.BS.AimFOV) or 300
    local UNLIM = FOV >= 600
    buildList(cam, myRoot)

    local best, bestChar
    -- 1) УДЕРЖАНИЕ ЦЕЛИ. Если аимлок уже ведёт цель, и она всё ещё
    -- впереди и внутри круга — держим её, даже если другая стала чуть
    -- ближе к центру. Так камера, патрон и маркер не разъезжаются.
    if G.BS.AimLock and LOCK_TARGET and LOCK_TARGET.Parent then
        for _, it in ipairs(bulletList) do
            if it.part == LOCK_TARGET
               and it.screen < 1e8
               and (UNLIM or it.screen <= FOV) then
                best, bestChar = it.part, it.char
                break
            end
        end
    end
    -- 2) Иначе — первая цель по близости к центру круга.
    if not best then
        for _, it in ipairs(bulletList) do
            -- it.screen - РАССТОЯНИЕ в пикселях (sqrt в buildList), поэтому
            -- сравниваем с FOV, а не с FOV*FOV. Раньше тут был квадрат:
            -- при 160 px цель ловилась в радиусе 25 600 px, то есть круг
            -- рисовался, но ни на что не влиял.
            -- it.screen = 1e9 у целей ЗА камерой; даже при «без ограничения»
            -- их не берём: аимлок должен целиться только вперёд.
            if it.screen < 1e8 and (UNLIM or it.screen <= FOV) then
                best, bestChar = it.part, it.char
                break
            end
        end
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
        -- Луч строим ИЗ КАМЕРЫ, а не из ствола: сервер сверяет
        -- направление пули именно со взглядом камеры (3°). Тогда
        -- точка за стеной лежит на линии камеры, и после подмены
        -- origin направление на цель совпадает с взглядом.
        local raySrc = cam.CFrame.Position
        local rayVec = aimPos - raySrc
        local len = rayVec.Magnitude
        if len > 1 then
            local okW, res = pcall(function()
                WALLRAY.FilterDescendantsInstances = { LP.Character, best.Parent }
                local hit = workspace:Raycast(raySrc, rayVec, WALLRAY)
                if not hit then return nil end
                if hit.Distance >= len - 1.2 then return nil end   -- это цель
                local slack = tonumber(G.BS.OriginSlack) or 13
                if slack < 1 then slack = 1 end
                local d = rayVec.Unit
                -- ТОЛЩИНА СТЕНЫ. Раньше вылет ставился на 2 студа за
                -- поверхностью и при толстой стене оставался ВНУТРИ неё.
                -- Считаем габарит детали вдоль луча и выносим точку за
                -- дальнюю грань. Для Terrain/нестандартных деталей — 3 ст.
                local ext = 1.5
                local part = hit.Instance
                if part and part:IsA("BasePart") then
                    local okS, rel = pcall(function()
                        return part.CFrame:VectorToObjectSpace(d)
                    end)
                    if okS and rel then
                        ext = 0.5 * (
                            math.abs(rel.X) * part.Size.X
                          + math.abs(rel.Y) * part.Size.Y
                          + math.abs(rel.Z) * part.Size.Z)
                    end
                end
                if ext < 0.25 then ext = 0.25 end
                if ext > 10 then ext = 10 end
                local wp = hit.Position + d * (ext * 2 + 0.5)
                -- Сервер меряет сдвиг от исходной точки вылета (ствола).
                if (wp - srcPos).Magnitude > slack then return nil end
                -- ПРОВЕРКА ВТОРОЙ СТЕНЫ: если за первой стеной есть ещё
                -- одна, вылет из-за первой всё равно упрётся в неё.
                -- Тогда wallPast не используем — сработает телепорт.
                local rest = aimPos - wp
                local restLen = rest.Magnitude
                if restLen > 0.1 then
                    local clear = workspace:Raycast(wp, rest, WALLRAY)
                    if clear and clear.Distance < restLen - 1.2 then return nil end
                end
                return wp
            end)
            if okW and res then wallPast = res end
        end
    end

    -- ТЕЛЕПОРТ-ВЫСТРЕЛ: если между нами и целью есть ЛЮБАЯ стена,
    -- ставим точку вылета за спиной/над целью. Для сервера персонаж на
    -- этот момент тоже окажется там (в ncWrapper).
    local ghostPos, ghostCFrame = nil, nil
    -- Телепорт нужен только если стену НЕЛЬЗЯ обойти сдвигом вылета
    -- (wallPast). Иначе лишний телепорт персонажа не нужен.
    if G.BS.GhostShot and best and srcPos and not wallPast then
        local toT = aimPos - srcPos
        local lenG = toT.Magnitude
        if lenG > 1 then
            local okG, hitG = pcall(function()
                WALLRAY.FilterDescendantsInstances = { LP.Character, bestChar }
                return workspace:Raycast(srcPos, toT, WALLRAY)
            end)
            if okG and hitG and hitG.Distance < lenG - 1.2 then
                local nowG = os.clock()
                local canUse = false
                -- Кэш на 0.2 с: не считаем 4 raycast'а каждый кадр.
                if GHOST_CACHE.char == best and GHOST_CACHE.pos
                   and nowG - GHOST_CACHE.at < 0.2 then
                    local d = aimPos - GHOST_CACHE.pos
                    local okC, hitC = pcall(function()
                        WALLRAY.FilterDescendantsInstances = { LP.Character, bestChar }
                        return workspace:Raycast(GHOST_CACHE.pos, d, WALLRAY)
                    end)
                    canUse = okC and (not hitC or hitC.Distance >= d.Magnitude - 0.8)
                end
                if not canUse then
                    local cand, cf = findGhostSpot(aimPos, srcPos, bestChar)
                    GHOST_CACHE.at   = nowG
                    GHOST_CACHE.char = best
                    GHOST_CACHE.pos  = cand
                    GHOST_CACHE.cf   = cf
                    if cand then
                        ghostPos, ghostCFrame = cand, cf
                    end
                else
                    ghostPos, ghostCFrame = GHOST_CACHE.pos, GHOST_CACHE.cf
                end
            end
        end
    end

    -- Если стену можно обойти сдвигом точки вылета в пределах,
    -- которые разрешает сервер (OriginSlack), предпочитаем этот путь:
    -- без телепорта персонажа и без риска анти-чита.
    if wallPast then
        ghostPos, ghostCFrame = nil, nil
    end

    bulletPreShot = {
        part = best,     -- цель (Instance)
        pos  = aimPos,   -- куда целимся
        src  = srcPos,   -- откуда стреляем
        dist = dist,     -- расстояние до цели
        dir  = dir.Unit, -- направление
        onScreen = true,  -- цель выбирается всегда (триггер удалён)
        wallPast = wallPast,        -- точка вылета ЗА стеной
        ghostPos = ghostPos,        -- точка за спиной/над целью
        ghostCFrame = ghostCFrame,  -- CFrame для временного телепорта
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
--   1) в руках ОРУЖИЕ (Muzzle/Variant/атрибуты/название; если предмет
--      неизвестен — считаем оружием, но аптечку/сканер отсекаем);
--   2) цель именно ПОД ПРИЦЕЛОМ (внутри круга), а не сзади;
--   3) аимлок работает ВСЕГДА, а не только пока зажат огонь (v11.18);
--   4) персонаж жив.
local UIS = game:GetService("UserInputService")
local AIMLOCKRAY = RaycastParams.new()
AIMLOCKRAY.FilterType = Enum.RaycastFilterType.Exclude
local gunInHand, gunCheckAt = false, 0

-- ПРИЦЕЛ С ЦЕЛЬЮ. Пока цель удерживается - она приоритетнее для
-- computeBulletPreShot, чтобы взгляд не «соскакивал» на того, кто
-- случайно ближе к центру экрана. Удержание живёт в LOCK_TARGET
-- (объявлен выше, рядом с bulletList).
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
        if not tool then
            -- оружие может быть не Tool, а моделью/стволом в персонаже
            local mz = ch:FindFirstChild("Muzzle", true)
            if mz then res = true return end
            res = false
            return
        end
        -- 1) ЯВНЫЕ ПРИЗНАКИ ОРУЖИЯ.
        if tool:FindFirstChild("Muzzle") then res = true return end
        if tool:GetAttribute("Variant") then res = true return end
        local markers = { "Muzzle", "FirePoint", "Barrel", "Nozzle", "Tip",
                          "Ammo", "Magazine", "Bullet", "Bolt" }
        for i = 1, #markers do
            if tool:FindFirstChild(markers[i]) then res = true return end
        end
        -- 2) АТРИБУТЫ: Ammo/ Damage/ Weapon/ ... (англ. и транслит)
        local okA, at = pcall(function() return tool:GetAttributes() end)
        if okA and type(at) == "table" then
            for k in pairs(at) do
                local kl = string.lower(tostring(k))
                if string.find(kl, "ammo", 1, true)
                   or string.find(kl, "damage", 1, true)
                   or string.find(kl, "weapon", 1, true)
                   or string.find(kl, "gun", 1, true)
                   or string.find(kl, "shot", 1, true)
                   or string.find(kl, "fire", 1, true)
                   or string.find(kl, "patron", 1, true)
                   or string.find(kl, "uron", 1, true) then
                    res = true
                    return
                end
            end
        end
        -- 3) НАЗВАНИЕ: английские и русские корни. Раньше проверялись
        -- только английские слова, поэтому русское оружие не считалось
        -- оружием и аимлок молчал (жалоба «целится только при выстреле»).
        local n = string.lower(tool.Name)
        local weaponWords = {
            "gun", "shot", "sniper", "pistol", "revolver", "rifle", "musket",
            "weapon", "smg", "carbine", "flintlock", "blunderbuss",
            "револьвер", "пистолет", "дробовик", "винтовк", "ружь",
            "автомат", "снайпер", "мушкет", "пушк", "оруж", "карабин",
            "пулемёт", "пулемет", "ствол",
        }
        for i = 1, #weaponWords do
            if string.find(n, weaponWords[i], 1, true) then res = true return end
        end
        -- 4) ЯВНО НЕ ОРУЖИЕ.
        local utilityWords = {
            "medkit", "bandage", "heal", "food", "drink", "scanner", "detector",
            "luminol", "analyzer", "syringe", "key", "radio", "flashlight",
            "camera", "evidence", "map", "compass",
            "аптеч", "бинт", "еда", "сканер", "детектор", "ключ", "рация",
            "фонар", "камер", "уликт", "карта", "компас", "шприц",
        }
        for i = 1, #utilityWords do
            if string.find(n, utilityWords[i], 1, true) then res = false return end
        end
        -- 5) Неизвестный предмет считаем оружием: лучше, чтобы аимлок
        -- работал, чем молчал из-за незнакомого названия.
        res = true
    end)
    gunInHand = res
    return res
end

local function aimLockTick(dt, now)
    if not G.BS.AimLock then
        dropLock()
        pcall(SPIN.release, "face")
        return
    end
    -- цель считаем сами: аимлок больше не зависит от клиент-аима,
    -- иначе при выключенной подмене патрона камера вообще не велась.
    if not bulletPreShot then pcall(computeBulletPreShot) end
    local pre = bulletPreShot
    if not (pre and pre.pos) then
        dropLock()
        pcall(SPIN.release, "face")
        return
    end
    if not refreshGunFlag(now) then
        dropLock()
        pcall(SPIN.release, "face")
        return
    end

    local cam = workspace.CurrentCamera
    if not cam then
        pcall(SPIN.release, "face")
        return
    end
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
    -- LOCK_TARGET не подменяет tgt здесь: computeBulletPreShot уже отдал
    -- удерживаемой цели приоритет, и pre.pos/pre.part — это она же.
    -- Иначе камера могла смотреть в pre.pos, а проверка стены — в другого.
    if not (tgt and tgt.Parent) then
        dropLock()
        pcall(SPIN.release, "face")
        return
    end

    -- ПОВ: поворот камеры можно выключить - тогда подмена патрона
    -- работает молча, а камера остаётся твоей.
    if G.BS.AimLockTurn == false then
        pcall(SPIN.release, "face")
        return
    end

    local cf = cam.CFrame
    local pos = cf.Position
    local look = pre.pos
    local toT = look - pos
    if toT.Magnitude < 0.5 then
        pcall(SPIN.release, "face")
        return
    end

    -- НЕ ДОВОДИМ КАМЕРУ СКВОЗЬ СТЕНЫ (по просьбе): если между нами и
    -- целью стена - взгляд остаётся твоим. v11.43: то же самое делает
    -- тумблер «Целиться только в видимых» (AimVisibleOnly).
    if G.BS.AimLockNoWall or G.BS.AimVisibleOnly then
        local blocked = false
        pcall(function()
            AIMLOCKRAY.FilterDescendantsInstances = { LP.Character, tgt.Parent }
            local hit = workspace:Raycast(pos, toT, AIMLOCKRAY)
            if hit and hit.Distance < toT.Magnitude - 1.2 then blocked = true end
        end)
        if blocked then
            pcall(SPIN.release, "face")
            return
        end
    end

    local target = CFrame.lookAt(pos, look, cf.UpVector)

    -- ДОВОРОТ. Шкала 1..35: 1 = максимально плавно, 35 = мгновенно.
    -- Раньше всё >= 1 было мгновенным, из-за чего ползунок 2..35 ни на
    -- что не влиял. В момент выстрела точное доведение всё равно делает
    -- ncFireWeapon, поэтому здесь важна только визуальная плавность.
    local sp = tonumber(G.BS.AimLockSpeed)
    if sp == nil then sp = 35 end
    if sp < 1 then sp = 1 end
    if sp > 35 then sp = 35 end
    local frac
    if sp >= 35 then
        frac = 1
    else
        -- Экспоненциальное сглаживание, не зависит от FPS. На 60 FPS:
        -- 1 ≈ 3.5 c, 17 ≈ 0.35 c, 34 ≈ 0.2 c до почти полного доведения.
        frac = 1 - math.exp(-sp * (dt or 0.016) * 0.5)
        if frac < 0.006 then frac = 0.006 end
        if frac > 1 then frac = 1 end
    end
    if frac <= 0 then
        pcall(SPIN.release, "face")
        return
    end
    if frac >= 1 then
        cam.CFrame = target
        -- Камера уже смотрит на цель. Доворачиваем и ПЕРСОНАЖА, иначе
        -- при ходьбе вперёд он продолжает идти в старую сторону, хотя
        -- камера повернулась. Позиция и наклон HRP сохраняются.
        pcall(SPIN.face, target.LookVector, dt)
        return
    end
    -- Плавный режим: frac уже посчитан по dt, поэтому Lerp применяем
    -- напрямую (раньше здесь было повторное exp(-frac/dt), из-за чего
    -- любой frac превращался в почти мгновенный доворот).
    local k = frac
    if k > 1 then k = 1 end
    local newCF = cf:Lerp(target, k)
    cam.CFrame = newCF
    pcall(SPIN.face, newCF.LookVector, dt)
end

-- АИМЛОК ВСТРАИВАЕМ В КАДР ПОСЛЕДНИМ. Roblox пересчитывает CFrame
-- камеры в своём BindToRenderStep с приоритетом Camera (200), но игра
-- может вешать и свои шаги. Поэтому цепляемся почти в самом конце
-- кадра (Last - 1), чтобы наш доворот никто не затирал.
local AIM_STEP_BOUND = false
local function bindAimLockStep()
    if AIM_STEP_BOUND then return end
    local prio = 1999
    pcall(function()
        prio = Enum.RenderPriority.Last.Value - 1
    end)
    local ok = pcall(function()
        RunService:BindToRenderStep("BS_AimLock", prio, function(dt)
            if STOPPED then return end
            local ok = pcall(aimLockTick, dt or 0.016, os.clock())
            -- если кадр аимлока упал, не оставляем AutoRotate зажатым:
            -- иначе персонаж застынет лицом в одну сторону до перезапуска
            if not ok then pcall(SPIN.release, "face") end
        end)
    end)
    if ok then AIM_STEP_BOUND = true end
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
    -- Remotes мог не существовать в момент запуска (скрипт вставили до
    -- загрузки карты). Раньше он разрешался один раз, и хуки навсегда
    -- оставались с nil-адресами. Теперь пробуем найти его заново.
    if not (Remotes and Remotes.Parent) then
        local okR, r = pcall(findRemotes)
        if okR and r then Remotes = r end
    end
    if Remotes then
        NC.fw = Remotes:FindFirstChild("FireWeapon")
        NC.ue = Remotes:FindFirstChild("UseEnergy")
        -- МЕЛЬЕ. По логу ремоутов: MeleeSwing/TrueFormMelee/StunFire
        -- принимают ОДИН Vector3 - направление удара. Значит удар
        -- проверяется так же, как выстрел, и подменяется так же.
        NC.melee  = Remotes:FindFirstChild("MeleeSwing")
        NC.tfmelee = Remotes:FindFirstChild("TrueFormMelee")
        NC.stun   = Remotes:FindFirstChild("StunFire")
        NC.emote  = Remotes:FindFirstChild("EmotePlay")
    end
    local ch = LP and LP.Character
    NC.myHum = (ch and ch:FindFirstChildOfClass("Humanoid")) or nil
    NC.myRoot = (ch and ch:FindFirstChild("HumanoidRootPart")) or nil
end

-- Подмена аргументов выстрела. Возвращает (out, n) либо nil.
local function ncFireWeapon(...)
    local pre = bulletPreShot
    if not (pre and pre.part and pre.part.Parent and pre.dir) then
        if not G.BS._noPreLog then
            G.BS._noPreLog = true
            print("[BS BULLET] FireWeapon вызван без цели: bulletPreShot=nil (нет цели в круге/оружия)")
        end
        return nil
    end
    local n = select("#", ...)
    if n < 1 then return nil end

    -- ТОЧНОЕ ДОВЕДЕНИЕ ПЕРЕД ВЫСТРЕЛОМ. Сервер сверяет направление
    -- пули со взглядом (SHOT_ANGLE_SLACK_DEG = 3). Плавный аимлок мог
    -- не успеть довести камеру/персонажа, и выстрел отклонялся.
    -- Здесь поворот делается мгновенно от текущей позиции: персонаж
    -- смотрит на pre.pos, камера тоже. Это не меняет позицию игрока.
    if G.BS.AimLock and pre.pos then
        local root = NC.myRoot
        if root and root.Parent and pre.dist and pre.dist > 0.5 then
            pcall(function()
                root.CFrame = CFrame.lookAt(root.Position, pre.pos)
            end)
        end
        local cam = workspace.CurrentCamera
        if cam then
            pcall(function()
                cam.CFrame = CFrame.lookAt(cam.CFrame.Position, pre.pos)
            end)
        end
    end

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

    -- Телепорт-выстрел имеет смысл только когда игра передала и точку
    -- вылета, и направление. Иначе после переноса за цель направление
    -- осталось бы старым и пуля ушла бы мимо (а камера смотрела назад).
    if pre.ghostPos and not (posIdx and dirIdx) then
        pre.ghostPos, pre.ghostCFrame = nil, nil
    end

    local replaced = false
    local bits = {}

    -- НАПРАВЛЕНИЕ СЧИТАЕМ ОТ ТОЧКИ ВЫЛЕТА САМОЙ ИГРЫ (аргумент №1),
    -- а НЕ от камеры. Сервер пускает луч именно от этой точки, поэтому
    -- так попадание точное: нет ошибки из-за того, что камера смещена
    -- назад/в сторону от ствола. Именно из-за этой разницы пуля уходила
    -- мимо головы.
    local aimDir, aimDist = pre.dir, pre.dist
    local aimPoint = pre.pos
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
    -- bulletListTarget уже учитывает удержание (computeBulletPreShot
    -- отдаёт приоритет LOCK_TARGET). Берём именно его, чтобы пуля и
    -- камера всегда шли в одну цель.
    local tgtPart = bulletListTarget
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
        aimPoint = p
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

    -- ФИНАЛЬНЫЙ ДОВОРОТ по свежей позиции цели. pre.pos посчитан в
    -- начале кадра; если цель бежит, к моменту выстрела камера смотрела
    -- чуть мимо, и сервер (3°) мог отклонить выстрел.
    if G.BS.AimLock and aimPoint then
        local root = NC.myRoot
        if root and root.Parent then
            pcall(function()
                root.CFrame = CFrame.lookAt(root.Position, aimPoint)
            end)
        end
        local cam = workspace.CurrentCamera
        if cam then
            pcall(function()
                cam.CFrame = CFrame.lookAt(cam.CFrame.Position, aimPoint)
            end)
        end
    end
    -- Свежая точка цели для отложенного ghost-выстрела: камера за
    -- спиной должна смотреть туда же, куда уйдёт пуля.
    pre.aimPoint = aimPoint

    -- 1) НАПРАВЛЕНИЕ. Длину НЕ уменьшаем: если игра берёт из неё
    --    дальность полёта (или вообще складывает origin + vector как
    --    конечную точку), короткий вектор = короткий выстрел.
    G.BS.LastShotAt = os.clock()
    if dirIdx then
        local base = dirLen or 1
        if base < aimDist then base = aimDist end
        if base < 1 then base = 1 end
        if base > 20000 then base = 20000 end
        out[dirIdx] = aimDir * base
        replaced = true
        bits[#bits + 1] = "направление #" .. tostring(dirIdx)
    end

    -- 1.5) ТЕЛЕПОРТ-ВЫСТРЕЛ: точка вылета за спиной/над целью.
    -- Направление пересчитываем от НОВОЙ точки, иначе пуля пойдёт
    -- по старому вектору и не попадёт с заспинной позиции.
    if pre.ghostPos and posIdx and dirIdx and G.BS.GhostShot then
        out[posIdx] = pre.ghostPos
        local gd = aimPoint - pre.ghostPos
        local glen = gd.Magnitude
        if glen > 0.001 then
            local gbase = dirLen or glen
            if gbase < glen then gbase = glen end
            out[dirIdx] = gd.Unit * gbase
            replaced = true
            bits[#bits + 1] = "точка вылета за спиной #" .. tostring(posIdx)
        end
    end

    -- 2) ТОЧКА ВЫЛЕТА. Сервер разрешает увести её на SHOT_ORIGIN_SLACK
    --    (14 студов). Если стена ближе этого - ставим точку ЗА стеной,
    --    и пуля начинается по ту сторону стены.
    if posIdx and not (pre.ghostPos and G.BS.GhostShot) then
        if pre.wallPast and dirIdx then
            out[posIdx] = pre.wallPast
            -- ВАЖНО: направление пересчитываем от НОВОЙ точки. Иначе
            -- пуля летит по линии ствола, а стартует из-за стены, и
            -- промахивается на смещение камеры/ствола.
            local wd = aimPoint - pre.wallPast
            local wlen = wd.Magnitude
            if wlen > 0.001 then
                local wbase = dirLen or wlen
                if wbase < wlen then wbase = wlen end
                out[dirIdx] = wd.Unit * wbase
                replaced = true
                bits[#bits + 1] = "точка вылета ЗА стеной #" .. tostring(posIdx)
            end
        else
            -- Нет отдельного аргумента направления — не трогаем origin,
            -- иначе выстрел уйдёт в неизвестном направлении.
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

    -- ДИАГНОСТИКА ПРОСТРЕЛА: раз в секунду пишем, что именно подменили.
    -- По этому логу видно, сработал ли телепорт/точка за стеной.
    if pre.wallPast or pre.ghostPos then
        local tnow = os.clock()
        if not G.BS._bulletLogAt or tnow - G.BS._bulletLogAt >= 1 then
            G.BS._bulletLogAt = tnow
            print(string.format(
                "[BS BULLET] прострел | ghost=%s | wallPast=%s | %s",
                tostring(pre.ghostPos ~= nil),
                tostring(pre.wallPast ~= nil),
                table.concat(bits, ", ")))
        end
    end

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
    -- PASSTHROUGH: отложенный выстрел после телепорта заново вызывает
    -- self:FireServer(...). В этот момент getnamecallmethod() снова
    -- валиден, и вызов сразу уходит в оригинал. Раньше NC.orig звали
    -- из task.spawn — там контекст namecall уже потерян, поэтому
    -- прострел молча не отправлялся.
    if NC.passthrough then
        if NC.orig then return NC.orig(self, ...) end
        return
    end
    local method = getnamecallmethod()
    -- МОНЕТЫ: авто-обучение ремоута. Срабатывает только когда монета
    -- рядом с игроком, чтобы не проверять каждый FireServer в бою.
    -- Берём только ЯВНЫЕ признаки (Instance с "coin"/"pickup" в имени
    -- или имя ремоута), иначе можно случайно перехватить чужой ремоут.
    if G.BS.CoinLearn and COIN.nearPlayer and method == "FireServer"
       and typeof(self) == "Instance" then
        local cls = self.ClassName
        if cls == "RemoteEvent" or cls == "UnreliableRemoteEvent" then
            local rawArgs = table.pack(...)
            pcall(function()
                local args = rawArgs
                local idx, atype = nil, nil
                for i = 1, args.n do
                    local v = args[i]
                    if typeof(v) == "Instance"
                       and (string.find(string.lower(v.Name), "coin", 1, true)
                            or string.find(string.lower(v.Name), "pickup", 1, true)) then
                        idx, atype = i, "instance"; break
                    end
                end
                if not idx then
                    local n = string.lower(self.Name)
                    if string.find(n, "coin", 1, true) or string.find(n, "pickup", 1, true)
                       or string.find(n, "collect", 1, true) then
                        idx, atype = 0, "remote-name"
                    end
                end
                if idx then
                    COIN.remote = self
                    COIN.args = args
                    COIN.argIdx = idx
                    COIN.argType = atype
                    COIN.learned = true
                    G.BS.CoinLearn = false
                    print("[BS COIN] выучил ремоут: " .. self:GetFullName()
                        .. " | аргументов=" .. tostring(args.n)
                        .. " | coinArgIdx=" .. tostring(idx)
                        .. " | тип=" .. tostring(atype))
                end
            end)
        end
    end
    -- ТАНЦЫ: ловим анимации, которые игра грузит сама (эмоуты).
    -- Animator:LoadAnimation(Animation) и Humanoid:PlayAnimation(Animation)
    -- вызываются, когда открывают колесо эмоутов или включают танец -
    -- значит ID добывается без всякого поиска по папкам.
    if G.BS.DanceAutoScan and type(method) == "string"
       and (method == "LoadAnimation" or method == "PlayAnimation") then
        pcall(captureAnimArg, (select(1, ...)))
        -- НЕ возвращаемся: дальше вызов уходит в оригинал как обычно,
        -- иначе игра не сможет загрузить анимацию.
    end
    -- ЛОГ РЕМОУТОВ: только когда включён (проверка — одно обращение).
    if G.BS.RemoteLog and type(method) == "string"
       and (method == "FireServer" or method == "InvokeServer") then
        pcall(logRemoteCall, self, method, ...)
    end
    -- ЭМОУТЫ: EmotePlay летит на сервер, когда включают танец штатно.
    -- Вынимаем оттуда ID/имя анимации.
    if G.BS.DanceAutoScan and method == "FireServer" and NC.emote then
        if self == NC.emote then pcall(captureEmoteArgs, ...) end
    end
    if type(method) == "string" then
        -- СТАМИНА: не даём игре списывать энергию
        if method == "FireServer" and self == NC.ue then
            if G.BS.InfStamina then return end
        -- ПРОСТРЕЛ / КЛИЕНТ АЙМ
        elseif method == "FireServer" and self == NC.fw then
            if G.BS.BulletSwap then
                -- Прострел-телепорт и сбор монет делят одно окно
                -- занятости. Если телепорт сейчас недоступен, убираем
                -- ghost-аргументы ДО ncFireWeapon, иначе выстрел ушёл бы
                -- из точки за целью, где персонажа на сервере нет.
                local preNow = bulletPreShot
                local ghostOK = preNow and preNow.ghostCFrame and G.BS.GhostShot
                    and not NC.ghostBusy and not G.BS._tpBusy
                if preNow and preNow.ghostPos and not ghostOK then
                    preNow.ghostPos, preNow.ghostCFrame = nil, nil
                end
                local out, n = ncFireWeapon(...)
                if out then
                    local pre = bulletPreShot
                    if ghostOK and pre and pre.ghostCFrame and pre.ghostPos then
                        local ch = LP and LP.Character
                        local root = ch and ch:FindFirstChild("HumanoidRootPart")
                        local hum = ch and ch:FindFirstChildOfClass("Humanoid")
                        if root and hum and hum.Health > 0 then
                            local oldCFrame = root.CFrame
                            local cam = workspace.CurrentCamera
                            local oldCam = cam and cam.CFrame
                            local hold = math.clamp(tonumber(G.BS.GhostHold) or 0.12, 0.05, 0.35)
                            NC.ghostBusy = true
                            G.BS._tpBusy = true
                            -- ВАЖНО: не стреляем в том же кадре. Сначала
                            -- ставим CFrame, ждём репликации на сервер, и
                            -- только потом отправляем FireWeapon. Иначе
                            -- сервер видит старую позицию и отклоняет шот.
                            task.spawn(function()
                                local okBody, errBody = pcall(function()
                                    root.CFrame = pre.ghostCFrame
                                    task.wait(hold)
                                    -- Камеру ставим ПОСЛЕ ожидания, прямо перед
                                    -- выстрелом: иначе CameraModule успевал
                                    -- вернуть её назад за эти 0.12 c.
                                    local lookAt = pre.aimPoint or pre.pos
                                    if cam and pre.ghostPos and lookAt then
                                        cam.CFrame = CFrame.lookAt(pre.ghostPos, lookAt)
                                    end
                                    -- Повторно фиксируем позицию/взгляд: между
                                    -- wait и выстрелом персонажа могло сдвинуть.
                                    root.CFrame = pre.ghostCFrame
                                    -- ОТПРАВЛЯЕМ ПОВТОРНЫМ ВЫЗОВОМ, а не через
                                    -- NC.orig: только так снова валиден
                                    -- getnamecallmethod(). NC.passthrough
                                    -- заставляет wrapper сразу пропустить вызов
                                    -- в оригинал без повторной подмены.
                                    NC.passthrough = true
                                    local okSend, errSend = pcall(function()
                                        self:FireServer(table.unpack(out, 1, n))
                                    end)
                                    NC.passthrough = false
                                    if not okSend and G.BS.BulletDebug then
                                        print("[BS BULLET] прострел: отправка не удалась: "
                                            .. tostring(errSend))
                                    end
                                    task.wait(0.06)
                                end)
                                -- Аварийный сброс: passthrough не должен
                                -- остаться включённым, иначе следующие вызовы
                                -- пойдут в обход клиент-айма. Флаги занятости
                                -- сбрасываем ВСЕГДА, иначе один сбой навсегда
                                -- выключает прострел и сбор монет.
                                NC.passthrough = false
                                pcall(function()
                                    if root.Parent and pre.ghostPos
                                       and (root.Position - pre.ghostPos).Magnitude < 16 then
                                        root.CFrame = oldCFrame
                                    end
                                end)
                                if cam and oldCam then
                                    pcall(function() cam.CFrame = oldCam end)
                                end
                                NC.ghostBusy = false
                                G.BS._tpBusy = false
                                if not okBody then
                                    print("[BS BULLET] прострел: ошибка: "
                                        .. tostring(errBody))
                                end
                            end)
                            if G.BS.BulletDebug and (not G.BS._ghostLogAt
                               or os.clock() - G.BS._ghostLogAt > 1) then
                                G.BS._ghostLogAt = os.clock()
                                print(string.format(
                                    "[BS BULLET] прострел: телепорт к цели %s, удержание %.2f c",
                                    tostring(pre.part and pre.part.Name), hold))
                            end
                            return nil
                        end
                    end
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

    -- СВОЯ РОЛЬ: player.Role проверяем и у себя. Раньше roleFromAttr
    -- вызывался только для других игроков, поэтому в HUD могло висеть
    -- «роль: ?», хотя атрибут Role у себя тоже есть.
    if not G.BS.RoleFreeze then
        local myR = roleFromAttr(LP)
        if myR and myR ~= "none" and G.BS.MyRole ~= myR then
            G.BS.MyRole = myR
            if addEvent then addEvent("твоя роль: " .. myR) end
        end
    end
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
                    -- РУЧНАЯ РОЛЬ ВЫШЕ ВСЕГО: если игрок выставил её
                    -- сам через GUI/консоль - перетираем любым другим
                    -- источником (в том числе ошибочным).
                    local ov = RoleOverride[plr]
                    if ov then
                        local e0 = by[plr]
                        e0.role, e0.conf, e0.manual = ov, 99, true
                        e0.votes, e0.lastStable = 1, ov
                    else
                        -- applyRole зовём ТОЛЬКО когда роль реально
                        -- найдена: иначе nil получал уверенность 6 и
                        -- мешал настоящим источникам роли перебить его.
                        local rr, src = roleFromAttr(plr)
                        if not rr then rr = netRoles[plr] end
                        if rr then
                            applyRole(by[plr], rr, CONF.attr, src)
                        end
                    end
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
           or (e and e.gui and not e.gui.Parent) then
            remove(plr)
        end
    end
    rolesFromSounds()
    rolesFromEvents()
    local deduced = deduceOthers()
    if deduced and not G.BS.RoleFreeze then
        -- ВЫВОД ПО СЧЁТЧИКУ НЕ ДОЛЖЕН СТАВИТЬ РОЛЬ ВСЕМ ПОДРЯД.
        -- Если ты хантер и хантеров в раунде 1 - ты и есть тот
        -- единственный, и все остальные действительно вампиры.
        -- Но если ты НЕ единственный (хантеров 4) - вывода нет,
        -- иначе всех остальных пометило бы вампирами.
        local cap = (deduced == "vampire") and (tonumber(G.BS.RoundVamps) or 0)
            or (tonumber(G.BS.RoundHunters) or 0)
        local marked = countRole(deduced)
        for _, e in pairs(by) do
            if e.role == nil and marked < cap then
                applyRole(e, deduced, CONF.deduce, "вывод по счётчику раунда")
                marked = marked + 1
            end
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
local hookRefreshAt = 0
local conn = RunService.RenderStepped:Connect(function()
    local now = os.clock()
    local dt = math.min(0.1, math.max(0.001, now - lastT))
    lastT = now

    -- держим кэш целей хука свежим. Раз в секунду достаточно:
    -- FindFirstChild на каждый кадр — лишние 360 вызовов/с.
    if NC.installed and now - hookRefreshAt > 1 then
        hookRefreshAt = now
        pcall(refreshHookTargets)
    end

    -- vyzhivanie
    if G.BS.InfStamina then pcall(patchEnergy) end
    if G.BS.HealthLock then
        pcall(installDamageHooks)
        pcall(pumpHealth)
    end

    -- цель для подмены патрона и для аимлока (аимлок сам по себе тоже
    -- должен считать цель - он больше не зависит от клиент-аима)
    if G.BS.BulletSwap or G.BS.AimLock then
        pcall(computeBulletPreShot)
    elseif bulletPreShot then
        bulletPreShot = nil
    end

    -- аимлок вызывается НЕ здесь, а в BindToRenderStep с приоритетом
    -- камеры + 1: Roblox пересчитывает CFrame камеры в своём
    -- RenderStepped ПОЗЖЕ обычных коннектов, и наш доворот просто
    -- затирался (отсюда «аймлок не работает» и «тянет назад»).

    -- подсветка текущей цели
    pcall(updateTargetMark)

    -- круг аима (ПОВ): видно, в каком радиусе скрипт видит цель
    pcall(drawFOV)

    -- танец на ходьбе + покачивание (спин крутит отдельный Heartbeat-коннект)
    pcall(danceTick, dt, now)

    -- авто-патроны: рядом с SupplyCrate (телепорт только если включён)
    pcall(function() G.BS.Supply.autoTick(now) end)

    -- магнит монет: 12 раз в секунду, чтобы не грузить кадр
    if now - (G.BS._coinNext or 0) >= 0.08 then
        G.BS._coinNext = now
        pcall(function() G.BS.Coins.magnetTick(now) end)
    end

    -- раз в 4 с ловим анимации, которые игра играет на персонаже:
    -- если станцевать штатным эмоутом, его ID попадёт в список
    if G.BS.DanceAutoScan and now - dance.scanAt > 4 then
        dance.scanAt = now
        local before = #DANCES
        pcall(function() scanPlayingAnims({}, false) end)
        -- новые анимации сразу попадают в выпадающий список
        if #DANCES > before then pcall(refreshDanceDropdown) end
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

    -- ---------- ЦЕЛЬ АИМА (считаем ДО ESP: нужна звезда в подписи) ----
    if G.BS.BulletSwap or G.BS.AimLock then
        locked = pickTarget(cam)
    else
        locked = nil
    end
    -- Красивая метка цели: уголки + табличка с подробностями.
    pcall(drawTarget, locked)

    -- ---------- ESP ----------
    for plr, e in pairs(by) do
        local ch = e.char
        -- ВАЖНО: обращение к уничтоженному Instance в Luau
        -- бросает ошибку и роняет ВЕСЬ кадр. Проверяем Parent.
        if ch and ch.Parent and e.gui and e.gui.Parent then
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

            -- ИГРОК ЗА СПИНОЙ: ESP не должен висеть на экране. Раньше
            -- BillboardGui с AlwaysOnTop рисовал подпись даже когда
            -- игрок был за камерой («ESP остаётся на экране»).
            if root and cam then
                local spB = cam:WorldToViewportPoint(root.Position)
                if spB.Z <= 0 then vis = false end
            end

            -- МЁРТВЫЕ ПРЯЧЕМ (по умолчанию). Раньше подпись и коробка
            -- висели на экране после смерти игрока — «ESP остаётся».
            local humNow = ch:FindFirstChildOfClass("Humanoid")
            if humNow then
                if humNow.Health <= 0 and G.BS.HideDead then vis = false end
            else
                vis = false
            end

            -- ПУЛЬС НИЗКОГО HP УДАЛЁН (v11.43) по просьбе.

            -- ВАЖНО: VIS.update рисует HP, скелет, стрелки и рамку головы
            -- отдельно от подписи. Передаём ему видимость, иначе у скрытых
            -- (мёртвых / выключенных ролью) оставались все эти элементы.
            e.vis = vis
            if e.gui.Enabled ~= vis then e.gui.Enabled = vis end

            if vis then
                local parts = {}
                -- ЗВЕЗДА у цели аима: понятно, в кого целится скрипт.
                if G.BS.MarkAim and locked == plr then parts[#parts + 1] = "★" end
                if G.BS.RoleIcons then
                    if role == "vampire" then parts[#parts + 1] = "V"
                    elseif role == "hunter" then parts[#parts + 1] = "H"
                    elseif role == nil and G.BS.ShowUnknown then parts[#parts + 1] = "?" end
                end
                if G.BS.WeaponESP then
                    local tool = ch:FindFirstChildOfClass("Tool")
                    if tool then parts[#parts + 1] = "[" .. tool.Name .. "]" end
                end
                if G.BS.Names then parts[#parts + 1] = plr.DisplayName end
                if role == nil and G.BS.ShowUnknown then
                    parts[#parts + 1] = "[?]"
                end
                if G.BS.ShowDist and root and myRoot then
                    parts[#parts + 1] = math.floor(
                        (root.Position - myRoot.Position).Magnitude + 0.5) .. " st"
                end
                if G.BS.ShowHP and humNow then
                    if G.BS.HPPercent and (humNow.MaxHealth or 0) > 0 then
                        parts[#parts + 1] = string.format("HP %d%%",
                            math.floor(humNow.Health / humNow.MaxHealth * 100 + 0.5))
                    else
                        parts[#parts + 1] = "HP " .. math.floor(humNow.Health + 0.5)
                    end
                end
                -- v11.31: скорость цели — по ней видно бегущего/стоящего.
                if G.BS.ShowSpeed and root then
                    local spd = root.AssemblyLinearVelocity
                    parts[#parts + 1] = math.floor(spd.Magnitude + 0.5) .. " st/s"
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
                if e.lbl.TextSize ~= G.BS.LabelSize then
                    local ts = tonumber(G.BS.LabelSize) or 13
                    e.lbl.TextSize = ts
                    -- Высота плашки под текущий размер текста.
                    e.lbl.Size = UDim2.new(0, 0, 0, ts + 8)
                end
                local labelColor = color
                if G.BS.NameHPColor and humNow and (humNow.MaxHealth or 0) > 0 then
                    local hp01 = math.clamp(humNow.Health / humNow.MaxHealth, 0, 1)
                    if hp01 > 0.5 then
                        labelColor = Color3.new(1, 1, 1):Lerp(Color3.new(1, 1, 0), (1 - hp01) * 2)
                    else
                        labelColor = Color3.new(1, 1, 0):Lerp(Color3.new(1, 0, 0), 1 - hp01 * 2)
                    end
                end
                if e.lbl.TextColor3 ~= labelColor then
                    e.lbl.TextColor3 = labelColor
                end
                -- Рамка плашки — в цвете роли: так ESP читается даже
                -- на светлых стенах.
                if e.lbl.BorderColor3 ~= color then
                    e.lbl.BorderColor3 = color
                end
                if not e.lbl.Visible then e.lbl.Visible = true end

                if G.BS.Boxes then
                    if not e.box then e.box = makeBox() end
                    if e.box and root then
                        e.box.color = color
                        e.box.corner = (role == "vampire")
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

    -- ДОПОЛНИТЕЛЬНЫЕ ВИЗУАЛЫ (трейсеры, скелет, HP, стрелки, chams...)
    if G.BS.VIS and G.BS.VIS.update then
        pcall(G.BS.VIS.update, cam, myRoot, by, locked)
    end
end)

-- ============================================================
--  GUI
-- ============================================================
-- Всё создание меню завёрнуто в функцию: в главном блоке скрипта
-- уже упёрлись в лимит локальных переменных Lua (200), а локальные
-- переменные из buildGui не нужны снаружи. Всё, что нужно дальше
-- (refreshDanceDropdown, bindAimLockStep), объявлено выше.
local function buildGui()
local Window = Rayfield:CreateWindow({
    Name = "Bloody Street",
    LoadingTitle = "BLOODY STREET",
    LoadingSubtitle = "ESP + Aim + Аимлок + Игрок + Патроны + Монеты v11.43",
    ConfigurationSaving = { Enabled = true },
})

local TAB  = Window:CreateTab("ESP", 4483362458)
local AIMT = Window:CreateTab("AIM", 1101060692)
local PLRT = Window:CreateTab("ИГРОК", 1183774348)

-- ЗАЩИТА СОЗДАНИЯ ЭЛЕМЕНТОВ: один упавший Create* не должен
-- ронять всю вкладку. UI_ERR объявлена выше (в блоке состояния),
-- чтобы её можно было распечатать в стартовом логе.
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
local PL = mkTab(PLRT, "ИГРОК")

-- Вкладка HUD и весь самописный HUD УДАЛЕНЫ по просьбе: остаётся только
-- окно Rayfield. Прицел/хитмаркер переехали во вкладку AIM.

-- Блок «ГЛАВНЫЙ ЦВЕТ (RGB)» удалён по просьбе: rgbColor/hexStr/
-- hexToRGB/applyMainColor больше не вызываются.

-- ======================= ESP =======================
TB.CreateSection("Цели и роли")
TB.CreateParagraph({ Title = "Цели и роли", Content = "Кого видно в ESP и в каком цвете. Цвет роли меняет подпись, коробку, линии и метку цели." })
TB.CreateToggle({ Name = "ESP игроков", Flag = "BS_PlayerESP",
    CurrentValue = G.BS.PlayerESP, Callback = function(v) G.BS.PlayerESP = v end })
TB.CreateColorPicker({ Name = "Цвет игроков", Flag = "BS_PlayerColor",
    Color = G.BS.PlayerColor, Callback = function(c) G.BS.PlayerColor = c end })
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

TB.CreateSection("Подписи")
TB.CreateParagraph({ Title = "Подписи", Content = "Что пишется над игроком. Порядок строк: роль, оружие, ник, дистанция, HP, скорость, статус." })
TB.CreateToggle({ Name = "Ники", Flag = "BS_Names",
    CurrentValue = G.BS.Names, Callback = function(v) G.BS.Names = v end })
TB.CreateToggle({ Name = "Дистанция", Flag = "BS_ShowDist",
    CurrentValue = G.BS.ShowDist, Callback = function(v) G.BS.ShowDist = v end })
TB.CreateToggle({ Name = "HP", Flag = "BS_ShowHP",
    CurrentValue = G.BS.ShowHP, Callback = function(v) G.BS.ShowHP = v end })
-- v11.32: HP ещё и в процентах, и прятать мёртвых (иначе ESP «висит»
-- на экране после смерти игрока).
TB.CreateToggle({ Name = "HP в процентах", Flag = "BS_HPPercent",
    CurrentValue = G.BS.HPPercent == true,
    Callback = function(v) G.BS.HPPercent = v end })
TB.CreateToggle({ Name = "Прятать мёртвых", Flag = "BS_HideDead",
    CurrentValue = G.BS.HideDead ~= false,
    Callback = function(v) G.BS.HideDead = v end })
-- v11.31: новые строки подписи.
TB.CreateToggle({ Name = "Скорость цели", Flag = "BS_ShowSpeed",
    CurrentValue = G.BS.ShowSpeed == true,
    Callback = function(v) G.BS.ShowSpeed = v end })
TB.CreateToggle({ Name = "Цвет ника по HP", Flag = "BS_NameHPColor",
    CurrentValue = G.BS.NameHPColor == true,
    Callback = function(v) G.BS.NameHPColor = v end })
TB.CreateToggle({ Name = "Цель аима: звезда в подписи", Flag = "BS_MarkAim",
    CurrentValue = G.BS.MarkAim ~= false,
    Callback = function(v) G.BS.MarkAim = v end })
TB.CreateToggle({ Name = "Статус (сбит / раскрыт)", Flag = "BS_ShowStatus",
    CurrentValue = G.BS.ShowStatus ~= false,
    Callback = function(v) G.BS.ShowStatus = v end })
TB.CreateSlider({ Name = "Размер текста ESP", Flag = "BS_LabelSize",
    Range = {9, 24}, Increment = 1, CurrentValue = G.BS.LabelSize or 13,
    Suffix = " px", Callback = function(v) G.BS.LabelSize = v end })

TB.CreateSection("Коробки")
TB.CreateParagraph({ Title = "Коробки", Content = "3D-коробка строится по габаритам всей модели: облегает тело целиком, поворачивается вместе с игроком, дальние рёбра бледнее. Есть рамка и уголки." })
TB.CreateToggle({ Name = "Коробки игроков", Flag = "BS_Boxes2",
    CurrentValue = DRAW_OK and G.BS.Boxes ~= false,
    Callback = function(v)
        G.BS.Boxes = v
        if v and not DRAW_OK then
            G.BS.Boxes = false
            notify("в этом исполнителе нет Drawing — коробки выключены", 4)
        end
    end })
-- Стиль коробки: «Рамка», «Уголки» или настоящая 3D-коробка по телу.
TB.CreateSlider({ Name = "Толщина коробки", Flag = "BS_BoxThick",
    Range = {1, 6}, Increment = 1, CurrentValue = G.BS.BoxThick,
    Callback = function(v) G.BS.BoxThick = v end })
TB.CreateSlider({ Name = "Отступ коробки от модели", Flag = "BS_BoxPad",
    Range = {0, 40}, Increment = 1, CurrentValue = G.BS.BoxPad or 4,
    Suffix = " px", Callback = function(v) G.BS.BoxPad = v end })
TB.CreateSlider({ Name = "Отступ 3D-коробки (студов)", Flag = "BS_BoxMargin",
    Range = {0, 5}, Increment = 0.1,
    CurrentValue = math.floor((tonumber(G.BS.BoxMargin) or 0) * 10 + 0.5) / 10,
    Suffix = " st", Callback = function(v) G.BS.BoxMargin = v end })
TB.CreateSlider({ Name = "Прозрачность коробки", Flag = "BS_BoxAlpha",
    Range = {0, 90}, Increment = 5,
    CurrentValue = math.floor((tonumber(G.BS.BoxAlpha) or 0) * 100 + 0.5),
    Suffix = " %", Callback = function(v) G.BS.BoxAlpha = v / 100 end })
-- v11.34: стиль коробки — рамка, уголки или ромб для вампиров.
-- Старый тумблер «Ромб для вампиров» убран: стиль выбирается здесь.
TB.CreateDropdown({
    Name = "Стиль коробки",
    Flag = "BS_BoxStylePick",
    Options = BOX_STYLES,
    CurrentOption = { G.BS.BoxStyle },
    MultipleOptions = false,
    Callback = function(selected)
        local picked = selected
        if type(picked) == "table" then picked = picked[1] end
        if type(picked) == "string" then G.BS.BoxStyle = picked end
    end,
})
TB.CreateToggle({ Name = "Затухание коробок по дистанции", Flag = "BS_DistFade",
    CurrentValue = G.BS.DistFade == true,
    Callback = function(v) G.BS.DistFade = v end })
TB.CreateSection("Визуалы игроков")
TB.CreateParagraph({ Title = "Стрелки и скелет", Content = "Стрелки к игрокам — толстые, со свечением, обводкой и наконечником. Плюс скелет, полоска HP и рамка головы." })
TB.CreateToggle({ Name = "Стрелки к игрокам (snaplines)", Flag = "BS_Snaplines",
    CurrentValue = G.BS.Snaplines ~= false,
    Callback = function(v) G.BS.Snaplines = v end })
TB.CreateSlider({ Name = "Толщина стрелок", Flag = "BS_SnapArrowThick",
    Range = {1, 6}, Increment = 1,
    CurrentValue = math.clamp(tonumber(G.BS.SnapArrowThick) or 2, 1, 6),
    Suffix = " px", Callback = function(v) G.BS.SnapArrowThick = v end })
TB.CreateDropdown({
    Name = "Стрелки от: откуда",
    Flag = "BS_SnapFromPick",
    Options = TRACER_ORIGINS,
    CurrentOption = { G.BS.SnapFrom },
    MultipleOptions = false,
    Callback = function(selected)
        local picked = selected
        if type(picked) == "table" then picked = picked[1] end
        if type(picked) == "string" then G.BS.SnapFrom = picked end
    end,
})
TB.CreateSlider({ Name = "Прозрачность стрелок", Flag = "BS_SnapAlpha",
    Range = {0, 10}, Increment = 1,
    CurrentValue = math.floor((tonumber(G.BS.SnapAlpha) or 1) * 10 + 0.5),
    Suffix = " /10", Callback = function(v) G.BS.SnapAlpha = v / 10 end })
TB.CreateToggle({ Name = "Линии между вампирами", Flag = "BS_VampLinks",
    CurrentValue = G.BS.VampLinks == true,
    Callback = function(v) G.BS.VampLinks = v end })
-- СКЕЛЕТ. Раньше он рисовался всегда и вблизи превращался в кашу из
-- линий (особенно когда стоишь за спиной у игрока). Теперь можно
-- ограничить дистанцию и рисовать его только у цели аима.
TB.CreateToggle({ Name = "Скелет ESP", Flag = "BS_Skeleton",
    CurrentValue = G.BS.Skeleton == true,
    Callback = function(v) G.BS.Skeleton = v end })
TB.CreateSlider({ Name = "Толщина скелета", Flag = "BS_SkeletonThick",
    Range = {1, 4}, Increment = 1, CurrentValue = G.BS.SkeletonThick or 1,
    Callback = function(v) G.BS.SkeletonThick = v end })
TB.CreateSlider({ Name = "Скелет: ближе не показывать", Flag = "BS_SkelMinDist",
    Range = {0, 60}, Increment = 2, CurrentValue = G.BS.SkelMinDist or 12,
    Suffix = " st", Callback = function(v) G.BS.SkelMinDist = v end })
TB.CreateToggle({ Name = "Скелет только у цели аима", Flag = "BS_SkelOnlyTarget",
    CurrentValue = G.BS.SkelOnlyTarget == true,
    Callback = function(v) G.BS.SkelOnlyTarget = v end })
TB.CreateToggle({ Name = "Полоска HP над головой", Flag = "BS_HealthBars",
    CurrentValue = G.BS.HealthBars ~= false,
    Callback = function(v) G.BS.HealthBars = v end })
TB.CreateSlider({ Name = "Ширина полоски HP", Flag = "BS_HealthBarWidth",
    Range = {20, 80}, Increment = 2, CurrentValue = G.BS.HealthBarWidth or 40,
    Suffix = " px", Callback = function(v) G.BS.HealthBarWidth = v end })
TB.CreateSlider({ Name = "Высота полоски HP", Flag = "BS_HealthBarHeight",
    Range = {2, 10}, Increment = 1, CurrentValue = G.BS.HealthBarHeight or 4,
    Suffix = " px", Callback = function(v) G.BS.HealthBarHeight = v end })
TB.CreateToggle({ Name = "Цифры HP на полоске", Flag = "BS_HPBarText",
    CurrentValue = G.BS.HPBarText ~= false,
    Callback = function(v) G.BS.HPBarText = v end })
TB.CreateToggle({ Name = "Рамка вокруг головы", Flag = "BS_HeadBox",
    CurrentValue = G.BS.HeadBox ~= false,
    Callback = function(v) G.BS.HeadBox = v end })
TB.CreateSlider({ Name = "Размер рамки головы", Flag = "BS_HeadBoxSize",
    Range = {10, 50}, Increment = 1, CurrentValue = G.BS.HeadBoxSize or 22,
    Suffix = " px", Callback = function(v) G.BS.HeadBoxSize = v end })
TB.CreateToggle({ Name = "Рамка головы по цвету роли", Flag = "BS_HeadBoxRole",
    CurrentValue = G.BS.HeadBoxRole ~= false,
    Callback = function(v) G.BS.HeadBoxRole = v end })
TB.CreateColorPicker({ Name = "Свой цвет рамки головы", Flag = "BS_HeadBoxColor",
    Color = G.BS.HeadBoxColor, Callback = function(c) G.BS.HeadBoxColor = c end })
TB.CreateToggle({ Name = "Цифры урона", Flag = "BS_DamageNumbers",
    CurrentValue = G.BS.DamageNumbers ~= false,
    Callback = function(v) G.BS.DamageNumbers = v end })
TB.CreateColorPicker({ Name = "Цвет цифр урона", Flag = "BS_DmgNumColor",
    Color = G.BS.DmgNumColor, Callback = function(c) G.BS.DmgNumColor = c end })
TB.CreateToggle({ Name = "Стрелки к целям за экраном", Flag = "BS_OffArrows",
    CurrentValue = G.BS.OffArrows ~= false,
    Callback = function(v) G.BS.OffArrows = v end })
-- v11.43: «Пульс низкого HP» (вместе с порогом и цветом) УДАЛЁН по
-- просьбе.

TB.CreateSection("Стрелка к цели")
-- v11.43: «Трейсер выстрела» (цвет/время/толщина) УДАЛЁН по просьбе —
-- не работал. Осталась только стрелка к цели.
TB.CreateToggle({ Name = "Стрелка к цели (трейсер)", Flag = "BS_AimLine",
    CurrentValue = G.BS.AimLine ~= false,
    Callback = function(v) G.BS.AimLine = v end })
TB.CreateColorPicker({ Name = "Цвет стрелки к цели", Flag = "BS_AimLineColor",
    Color = G.BS.AimLineColor, Callback = function(c) G.BS.AimLineColor = c end })
TB.CreateSlider({ Name = "Толщина стрелки к цели", Flag = "BS_AimLineThick",
    Range = {1, 6}, Increment = 1,
    CurrentValue = math.clamp(tonumber(G.BS.AimLineThick) or 2, 1, 6),
    Suffix = " px", Callback = function(v) G.BS.AimLineThick = v end })
TB.CreateSlider({ Name = "Прозрачность линии к цели", Flag = "BS_AimLineAlpha",
    Range = {0, 10}, Increment = 1,
    CurrentValue = math.floor((tonumber(G.BS.AimLineAlpha) or 1) * 10 + 0.5),
    Suffix = " /10", Callback = function(v) G.BS.AimLineAlpha = v / 10 end })
TB.CreateDropdown({
    Name = "Линия к цели: откуда",
    Flag = "BS_AimLineFromPick",
    Options = TRACER_ORIGINS,
    CurrentOption = { G.BS.AimLineFrom },
    MultipleOptions = false,
    Callback = function(selected)
        local picked = selected
        if type(picked) == "table" then picked = picked[1] end
        if type(picked) == "string" then G.BS.AimLineFrom = picked end
    end,
})

TB.CreateSection("Объекты")
TB.CreateParagraph({ Title = "Подсветка", Content = "Подсветка ящиков и монет на карте, иконки ролей и оружие в подписи ESP." })
TB.CreateToggle({ Name = "Подсветка ящиков", Flag = "BS_CrateESP",
    CurrentValue = G.BS.CrateESP == true,
    Callback = function(v) G.BS.CrateESP = v end })
TB.CreateColorPicker({ Name = "Цвет ящиков", Flag = "BS_CrateColor",
    Color = G.BS.CrateColor, Callback = function(c) G.BS.CrateColor = c end })
TB.CreateToggle({ Name = "Подсветка монет", Flag = "BS_CoinESP",
    CurrentValue = G.BS.CoinESP == true,
    Callback = function(v) G.BS.CoinESP = v end })
TB.CreateColorPicker({ Name = "Цвет монет", Flag = "BS_CoinColor",
    Color = G.BS.CoinColor, Callback = function(c) G.BS.CoinColor = c end })
-- «Подсветка улик / крови» УДАЛЕНА (v11.32) по просьбе.
TB.CreateToggle({ Name = "Иконки ролей в ESP", Flag = "BS_RoleIcons",
    CurrentValue = G.BS.RoleIcons ~= false,
    Callback = function(v) G.BS.RoleIcons = v end })
TB.CreateToggle({ Name = "Оружие в ESP", Flag = "BS_WeaponESP",
    CurrentValue = G.BS.WeaponESP ~= false,
    Callback = function(v) G.BS.WeaponESP = v end })

TB.CreateSection("Миникарта")
TB.CreateParagraph({ Title = "Мини-карта", Content = "Мини-карта в углу экрана: кто и где относительно тебя." })
TB.CreateToggle({ Name = "Миникарта", Flag = "BS_Minimap",
    CurrentValue = G.BS.Minimap == true,
    Callback = function(v) G.BS.Minimap = v end })
TB.CreateSlider({ Name = "Размер миникарты", Flag = "BS_MinimapSize",
    Range = {100, 300}, Increment = 10, CurrentValue = G.BS.MinimapSize or 160,
    Suffix = " px", Callback = function(v) G.BS.MinimapSize = v end })
TB.CreateToggle({ Name = "Точка игрока на миникарте", Flag = "BS_MinimapSelf",
    CurrentValue = G.BS.MinimapSelf ~= false,
    Callback = function(v) G.BS.MinimapSelf = v end })

-- Секция «Сканер» с кнопками СКАНИРОВАТЬ ИГРУ / ГЛУБОКОЕ СКАНИРОВАНИЕ /
-- ПРОВЕРКА ОРУЖИЯ / Сканировать при запуске УБРАНА по просьбе (см.
-- комментарий в конце вкладки AIM): консоль забивалась сотнями строк.
-- Функции остались в файле и включаются из консоли.

-- ======================= ПРЫЖОК =======================
-- Ускоритель по Shift удалён: остался только рывок в прыжке.
-- В v11.19 блок перенесён во вкладку ИГРОК (вместе с танцем/спином).

-- ======================= AIM =======================
-- ДВЕ КНОПКИ (по просьбе): «Клиент айм» и «Аимлок».
-- Аимлок работает, пока держишь пушку (зажата ЛКМ) — камера
-- доводится на цель только в момент стрельбы, поэтому в покое
-- камера твоя.
local function setBulletSwap(v)
    G.BS.BulletSwap = v
    locked = nil
    bulletPreShot = nil
    if v then
        pcall(installBulletHook)
        pcall(computeBulletPreShot)
    end
end

AI.CreateSection("Основное")
-- ВАЖНО: у этих тумблеров НЕТ Flag. Rayfield при запуске восстанавливает
-- сохранённые значения и перебивал ими дефолты (из-за этого аимлок мог
-- остаться выключенным, а режим «только на ЛКМ» - включённым).
AI.CreateToggle({
    Name = "Клиент айм (патрон в цель)",
    CurrentValue = G.BS.BulletSwap,
    Callback = function(v) pcall(setBulletSwap, v) end,
})
AI.CreateToggle({
    Name = "Аимлок (камера целится)",
    CurrentValue = G.BS.AimLock,
    Callback = function(v)
        G.BS.AimLock = v
        if v then bindAimLockStep() end
    end,
})
-- v11.43: кнопка «целиться только в видимых» — цель за стеной не
-- выбирается и камера не доводится сквозь стену (не через стенки).
-- Флага нет — как и у двух тумблеров выше, чтобы сохранёнка Rayfield
-- не перебивала значение.
AI.CreateToggle({
    Name = "Целиться только в видимых (не через стены)",
    CurrentValue = G.BS.AimVisibleOnly == true,
    Callback = function(v)
        G.BS.AimVisibleOnly = v
        G.BS.AimLockNoWall = v
        if v then pcall(computeBulletPreShot) end
    end,
})
-- «Только видимые цели» восстановлен как этот тумблер (v11.43).
-- Тумблер «камера доворачивается» УДАЛЁН по просьбе: аимлок всегда
-- доводит камеру (G.BS.AimLockTurn = true). Если понадобится тихий аим
-- без поворота камеры - из консоли:
--   getgenv().BS.AimLockTurn = false
-- Тумблер «Аим пока держишь пушку» УДАЛЁН в v11.18: из-за него камера
-- велась только во время стрельбы. Теперь аимлок работает всегда, пока
-- в руках оружие и цель внутри круга.

AI.CreateSection("Круг аима (ПОВ)")
-- ПОВ = круг вокруг прицела. Внутри круга скрипт видит цель и стреляет,
-- вне круга - не трогает. 600 px = без ограничения (весь экран).
-- Flag сменён на BS_AimFOV2, чтобы старые сохранённые 160 px не
-- перебивали новый дефолт 300 px.
AI.CreateSlider({ Name = "Радиус круга (FOV)", Flag = "BS_AimFOV2",
    Range = {40, 600}, Increment = 10, CurrentValue = G.BS.AimFOV,
    Suffix = " px", Callback = function(v)
        G.BS.AimFOV = v
    end })
AI.CreateToggle({ Name = "Показывать круг аима",
    CurrentValue = G.BS.AimFOVShow ~= false,
    Callback = function(v) G.BS.AimFOVShow = v end })
AI.CreateColorPicker({ Name = "Цвет круга аима", Flag = "BS_AimFOVColorPick",
    Color = G.BS.AimFOVColor,
    Callback = function(c) G.BS.AimFOVColor = c end })
AI.CreateSlider({ Name = "Толщина круга аима", Flag = "BS_AimFOVThick",
    Range = {1, 6}, Increment = 1, CurrentValue = G.BS.AimFOVThick or 2,
    Suffix = " px", Callback = function(v) G.BS.AimFOVThick = v end })
AI.CreateSlider({ Name = "Прозрачность круга аима", Flag = "BS_AimFOVAlpha",
    Range = {0, 1}, Increment = 0.05, CurrentValue = G.BS.AimFOVAlpha or 0.35,
    Callback = function(v) G.BS.AimFOVAlpha = v end })

AI.CreateSection("Выбор цели")
-- v11.31: вернули выбор целей и приоритет. Настройки AimTargets и
-- AimPriority существовали, но в GUI их не было — работали только
-- дефолты, а приоритет вообще игнорировался клиент-аймом.
AI.CreateDropdown({
    Name = "Кого целить",
    Flag = "BS_AimTargetsPick",
    Options = AIM_TARGETS,
    CurrentOption = { G.BS.AimTargets },
    MultipleOptions = false,
    Callback = function(selected)
        local picked = selected
        if type(picked) == "table" then picked = picked[1] end
        if type(picked) == "string" then G.BS.AimTargets = picked end
    end,
})
AI.CreateDropdown({
    Name = "Приоритет цели",
    Flag = "BS_AimPriorityPick",
    Options = AIM_PRIORITY,
    CurrentOption = { G.BS.AimPriority },
    MultipleOptions = false,
    Callback = function(selected)
        local picked = selected
        if type(picked) == "table" then picked = picked[1] end
        if type(picked) == "string" then G.BS.AimPriority = picked end
    end,
})
local AIM_PART_LABELS = {
    ["Голова"] = "Head",
    ["Корпус"] = "UpperTorso",
    ["Пояс"] = "HumanoidRootPart",
    ["Любая ближайшая"] = "",
}
local AIM_PART_BACK = {
    Head = "Голова",
    UpperTorso = "Корпус",
    HumanoidRootPart = "Пояс",
    [""] = "Любая ближайшая",
}
AI.CreateDropdown({
    Name = "Куда целиться",
    Flag = "BS_AimPartPick",
    Options = { "Голова", "Корпус", "Пояс", "Любая ближайшая" },
    CurrentOption = { AIM_PART_BACK[G.BS.AimPart] or "Голова" },
    MultipleOptions = false,
    Callback = function(selected)
        local picked = selected
        if type(picked) == "table" then picked = picked[1] end
        G.BS.AimPart = AIM_PART_LABELS[picked] or "Head"
    end,
})
AI.CreateSlider({ Name = "Опережение цели", Flag = "BS_AimLeadPick",
    Range = {0, 0.3}, Increment = 0.01,
    CurrentValue = tonumber(G.BS.AimLead) or 0.08,
    Suffix = " c", Callback = function(v) G.BS.AimLead = v end })
-- Новый Flag: старый BS_AimLockSpeedPick хранил 1 из v11.29/11.30,
-- где 1 означало «мгновенно». Теперь 1 = плавно, 35 = мгновенно,
-- поэтому старую сохранённую единицу нельзя восстанавливать.
AI.CreateSlider({ Name = "Скорость доводки (1 = плавно, 35 = мгновенно)",
    Flag = "BS_AimLockSpeedPick2",
    Range = {1, 35}, Increment = 1,
    CurrentValue = tonumber(G.BS.AimLockSpeed) or 35,
    Callback = function(v) G.BS.AimLockSpeed = v end })
AI.CreateSlider({ Name = "Макс. дистанция аима", Flag = "BS_AimMaxDistPick",
    Range = {50, 300}, Increment = 10,
    CurrentValue = tonumber(G.BS.AimMaxDist) or 290,
    Suffix = " st", Callback = function(v) G.BS.AimMaxDist = v end })

AI.CreateSection("Точки тела")
AI.CreateToggle({ Name = "Цепочка частей (голова → корпус → ноги)",
    Flag = "BS_AimChainToggle",
    CurrentValue = G.BS.AimChain ~= false,
    Callback = function(v) G.BS.AimChain = v end })
AI.CreateToggle({ Name = "Свободная часть тела (не в стену)",
    Flag = "BS_AimFreePartToggle",
    CurrentValue = G.BS.AimFreePart ~= false,
    Callback = function(v) G.BS.AimFreePart = v end })

AI.CreateSection("Цель аима (на кого работает аимлок)")
AI.CreateParagraph({ Title = "Метка цели", Content = "Кольцо захвата вокруг головы цели, тонкая обводка и табличка с подробностями. Всё это показывает, на кого СЕЙЧАС целится аимлок." })
AI.CreateToggle({ Name = "Кольцо захвата", Flag = "BS_TargetRing",
    CurrentValue = G.BS.TargetRing ~= false,
    Callback = function(v) G.BS.TargetRing = v end })
AI.CreateSlider({ Name = "Размер кольца", Flag = "BS_TargetRingSize",
    Range = {10, 60}, Increment = 1, CurrentValue = G.BS.TargetRingSize or 26,
    Suffix = " px", Callback = function(v) G.BS.TargetRingSize = v end })
AI.CreateSlider({ Name = "Толщина кольца", Flag = "BS_TargetRingThick",
    Range = {1, 4}, Increment = 1, CurrentValue = G.BS.TargetRingThick or 1,
    Suffix = " px", Callback = function(v) G.BS.TargetRingThick = v end })
AI.CreateToggle({ Name = "Вращающиеся засечки", Flag = "BS_TargetTicks",
    CurrentValue = G.BS.TargetTicks ~= false,
    Callback = function(v) G.BS.TargetTicks = v end })
AI.CreateSlider({ Name = "Скорость засечек", Flag = "BS_TargetTickSpeed",
    Range = {0, 40}, Increment = 1,
    CurrentValue = math.floor((tonumber(G.BS.TargetTickSpeed) or 1.1) * 10 + 0.5),
    Suffix = " x0.1", Callback = function(v) G.BS.TargetTickSpeed = v / 10 end })
AI.CreateToggle({ Name = "Анимация захвата (схлопывание)", Flag = "BS_TargetLockAnim",
    CurrentValue = G.BS.TargetLockAnim ~= false,
    Callback = function(v) G.BS.TargetLockAnim = v end })
AI.CreateToggle({ Name = "Обводка цели (Highlight)", Flag = "BS_TargetMark",
    CurrentValue = G.BS.TargetMark ~= false,
    Callback = function(v)
        G.BS.TargetMark = v
        if not v and TargetHL then TargetHL.Enabled = false end
    end })
AI.CreateColorPicker({ Name = "Цвет обводки", Flag = "BS_TargetMarkColor",
    Color = G.BS.TargetMarkColor,
    Callback = function(c) G.BS.TargetMarkColor = c end })
AI.CreateSlider({ Name = "Прозрачность обводки", Flag = "BS_TargetMarkAlpha",
    Range = {0, 10}, Increment = 1,
    CurrentValue = math.floor((tonumber(G.BS.TargetMarkAlpha) or 0.15) * 10 + 0.5),
    Suffix = " /10", Callback = function(v) G.BS.TargetMarkAlpha = v / 10 end })
AI.CreateToggle({ Name = "Цвет таблички по роли", Flag = "BS_TargetBracketRole",
    CurrentValue = G.BS.TargetBracketRole ~= false,
    Callback = function(v) G.BS.TargetBracketRole = v end })
AI.CreateColorPicker({ Name = "Свой цвет таблички", Flag = "BS_TargetBracketColor",
    Color = G.BS.TargetBracketColor,
    Callback = function(c) G.BS.TargetBracketColor = c end })
AI.CreateToggle({ Name = "Табличка цели (имя / HP / дистанция)", Flag = "BS_TargetPlate",
    CurrentValue = G.BS.TargetPlate ~= false,
    Callback = function(v) G.BS.TargetPlate = v end })
AI.CreateToggle({ Name = "В таблице: ник", Flag = "BS_TargetPlateName",
    CurrentValue = G.BS.TargetPlateName ~= false,
    Callback = function(v) G.BS.TargetPlateName = v end })
AI.CreateToggle({ Name = "В таблице: дистанция", Flag = "BS_TargetPlateDist",
    CurrentValue = G.BS.TargetPlateDist ~= false,
    Callback = function(v) G.BS.TargetPlateDist = v end })
AI.CreateToggle({ Name = "В таблице: HP", Flag = "BS_TargetPlateHP",
    CurrentValue = G.BS.TargetPlateHP ~= false,
    Callback = function(v) G.BS.TargetPlateHP = v end })
AI.CreateToggle({ Name = "В таблице: оружие", Flag = "BS_TargetPlateWeap",
    CurrentValue = G.BS.TargetPlateWeap == true,
    Callback = function(v) G.BS.TargetPlateWeap = v end })

-- ПРИЦЕЛ и ХИТМАРКЕР УДАЛЕНЫ (v11.32) по просьбе: в центре экрана
-- больше нет ни прицела, ни вспышки при попадании.

-- Выбор цели, приоритет и часть тела теперь в секции «Выбор цели»
-- выше; радиус захвата живёт в «Макс. дистанция аима».

-- Секция «Диагностика» (лог попаданий, диагностика патрона, лог
-- ремоутов, глубокий лог 94 ремоутов) и кнопки сканеров УБРАНЫ по
-- просьбе: консоль забивалась, а нужного там всё равно не было.
-- Если что-то понадобится - всё включается из консоли:
--   getgenv().BS.RemoteLog = true
--   getgenv().BS.DeepRemoteLog = true
--   getgenv().BS.DmgLog = true
--   getgenv().BS.BulletDebug = true
-- и вызовом из консоли: loadstring("...") — функции scanAll/deepScan/
-- probeWeapon остались в файле.

-- ============================================================
--  ИГРОК: ПРЫЖОК + ТАНЕЦ/СПИН
-- ============================================================
-- В v11.19 отдельная вкладка ТАНЕЦ удалена: прыжок и танец теперь
-- в одной вкладке ИГРОК. Список танцев - выпадающий (не кнопки
-- «следующий/предыдущий»).
PL.CreateSection("Патроны")
PL.CreateParagraph({ Title = "Патроны", Content = "Авто-пополнение из ящиков. По умолчанию скрипт идёт к ящику только когда патроны закончились (порог 0)." })
PL.CreateToggle({
    Name = "Авто-пополнение рядом с ящиком",
    Flag = "BS_AmmoAuto",
    CurrentValue = G.BS.AmmoAuto,
    Callback = function(v) G.BS.AmmoAuto = v end,
})
PL.CreateSlider({
    Name = "Радиус авто-пополнения",
    Flag = "BS_AmmoRange",
    Range = { 5, 200 },
    Increment = 5,
    CurrentValue = tonumber(G.BS.AmmoRange) or 25,
    Suffix = " st",
    Callback = function(v) G.BS.AmmoRange = v end,
})
PL.CreateToggle({
    Name = "Ящик подходит ко мне",
    Flag = "BS_AmmoBringCrate",
    CurrentValue = G.BS.AmmoBringCrate ~= false,
    Callback = function(v) G.BS.AmmoBringCrate = v end,
})
PL.CreateSlider({
    Name = "Порог автопополнения (0 = только когда кончились)",
    Flag = "BS_AmmoLowPct2",
    Range = { 0, 100 },
    Increment = 5,
    CurrentValue = math.floor((tonumber(G.BS.AmmoLowPct) or 0) * 100 + 0.5),
    Suffix = " %",
    Callback = function(v) G.BS.AmmoLowPct = v / 100 end,
})
PL.CreateSection("Монеты")
-- Магнит монет УДАЛЁН (v11.33) по просьбе: монеты больше не летят к
-- игроку. Сбор работает как раньше — prompt / click / touch / ремоут.
-- v11.36: AFK-ФАРМ — скрипт сам собирает монеты по всей карте и
-- подхватывает их заново, когда игра сбрасывает новые.
PL.CreateParagraph({ Title = "AFK-фарм", Content = "Скрипт сам собирает монеты по всей карте и подхватывает новые, когда игра их сбрасывает. По умолчанию выключен: при включении персонаж телепортируется к монетам. В консоли — счётчик каждые 10 монет." })
PL.CreateToggle({ Name = "AFK фарм монет", Flag = "BS_CoinFarm",
    CurrentValue = G.BS.CoinFarm == true,
    Callback = function(v)
        G.BS.CoinFarm = v
        if v then
            G.BS.Coins.farmCount = 0
        end
        notify(v and "AFK-фарм монет: включён" or "AFK-фарм монет: выключен", 3)
    end })
PL.CreateSlider({ Name = "Пауза между попытками", Flag = "BS_CoinFarmGap",
    Range = {0.2, 5}, Increment = 0.1,
    CurrentValue = tonumber(G.BS.CoinFarmGap) or 1.0,
    Suffix = " c", Callback = function(v) G.BS.CoinFarmGap = v end })
PL.CreateSlider({ Name = "Радиус фарма", Flag = "BS_CoinFarmRange",
    Range = {100, 1200}, Increment = 50,
    CurrentValue = tonumber(G.BS.CoinFarmRange) or 700,
    Suffix = " st", Callback = function(v) G.BS.CoinFarmRange = v end })
PL.CreateToggle({ Name = "Сбор телепортом к монете (риск)", Flag = "BS_CoinBlink",
    CurrentValue = G.BS.CoinBlink == true,
    Callback = function(v) G.BS.CoinBlink = v end })

-- v11.42: СПИД БУСТУ больше нет. Осталась одна механика — СПИД ГЛИТЧ:
-- прыжок + разгон. Раньше был отдельный тумблер «Спид буст» с множителем,
-- по просьбе убран. Вывод в меню оставлен только под глитч.
PL.CreateSection("Скорость")
PL.CreateParagraph({ Title = "Скорость", Content = "Спид глитч — прыжок с разгоном: ускоряешься и летишь вверх, пока держишь прыжок. Множитель разгона — насколько сильно." })
PL.CreateToggle({ Name = "Спид глитч (прыжок + разгон)", Flag = "BS_SpeedGlitch",
    CurrentValue = G.BS.SpeedGlitch == true,
    Callback = function(v) G.BS.SpeedGlitch = v end })
PL.CreateSlider({ Name = "Множитель разгона", Flag = "BS_SpeedGlitchMul",
    Range = {1.2, 6}, Increment = 0.1,
    CurrentValue = tonumber(G.BS.SpeedGlitchMul) or 2.5,
    Suffix = " x", Callback = function(v) G.BS.SpeedGlitchMul = v end })
-- v11.43: «Подброс вверх на прыжке» и «Длительность разгона» УДАЛЕНЫ
-- по просьбе. Остался только множитель разгона.

PL.CreateSection("Танец")
dance.toggle = PL.CreateToggle({ Name = "Танцевать", Flag = "BS_DanceOn",
    CurrentValue = dance.on == true,
    Callback = function(v) pcall(setDance, v) end })
PL.CreateToggle({ Name = "Спин (крутишься)", Flag = "BS_Spin",
    CurrentValue = dance.spin == true,
    Callback = function(v) pcall(SPIN.set, v) end })

-- Список для Rayfield: подписи уникальны (у обычных танцев в конце ID).
-- Если хвосты ID совпали, добавляем #2/#3: Rayfield создаёт Frame с
-- именем опции, и одинаковые имена ломали выбор.
local function danceOptionList()
    local opts = dance.labels()
    if #opts == 0 then opts = { "танец не найден" } end
    local seen = {}
    for i = 1, #opts do
        local base = opts[i]
        local n = 1
        while seen[opts[i]] do
            n = n + 1
            opts[i] = base .. " #" .. n
        end
        seen[opts[i]] = true
    end
    return opts
end

-- Текущая подпись для CurrentOption. Rayfield ждёт ТАБЛИЦУ, а не строку
-- (из-за строки в старом коде dropdown и не создавался).
local function currentDanceLabel()
    local opts = danceOptionList()
    for i = 1, #DANCES do
        local d = DANCES[i]
        if (d.id and dance.id == d.id)
           or (d.emote and dance.emote == d.emote) then
            return opts[i] or opts[1]
        end
    end
    return opts[1]
end

refreshDanceDropdown = function()
    if not danceDD then return end
    local opts = danceOptionList()
    -- Актуальный Rayfield: метод Refresh. Старые SetOptions/AddOptions
    -- оставлены запасным вариантом для кастомных сборок.
    if pcall(function() danceDD:Refresh(opts) end) then return end
    if pcall(function() danceDD:SetOptions(opts) end) then return end
    pcall(function() danceDD:AddOptions(opts) end)
end

danceDD = PL.CreateDropdown({
    Name = "Какой танец",
    Flag = "BS_DancePick2",
    Options = danceOptionList(),
    CurrentOption = { currentDanceLabel() },
    MultipleOptions = false,
    Callback = function(selected)
        -- Rayfield отдаёт CurrentOption-таблицу. Старые сборки могли
        -- отдавать строку - поддерживаем оба варианта.
        local picked = selected
        if type(picked) == "table" then picked = picked[1] end
        if type(picked) ~= "string" then return end
        local opts = danceOptionList()
        for i = 1, #opts do
            if opts[i] == picked then
                local d = DANCES[i]
                if d then
                    -- Сначала меняем выбор, НЕ запуская его (dance.on=false),
                    -- потом синхронизируем тумблер: иначе toggle:Set(true)
                    -- успевал запустить СТАРЫЙ танец, и новый стартовал
                    -- вторым запуском - был лишний рывок анимации.
                    local wasOn = dance.on
                    dance.on = false
                    pcall(pickDance, d.id, d.label)
                    dance.on = true
                    G.BS.DanceOn = true
                    if dance.toggle then
                        if wasOn then
                            pcall(startDance, true)
                        else
                            pcall(function() dance.toggle:Set(true) end)
                        end
                    else
                        pcall(startDance, true)
                    end
                end
                return
            end
        end
        -- запасной путь: вдруг пришла подпись из dance.entry
        pcall(pickDance, nil, picked)
    end,
})

PL.CreateSlider({ Name = "Скорость спина", Flag = "BS_SpinSpeed",
    Range = {10, 200}, Increment = 5, CurrentValue = G.BS.SpinSpeed,
    Suffix = " °/с", Callback = function(v)
        G.BS.SpinSpeed = v
        dance.spinSpeed = v
    end })
-- Тумблер "Спин только стоя" удалён по просьбе: спин крутит и на ходу,
-- и стоя (движение не мешает - модель просто вращается вокруг корня).

PL.CreateSection("Скрипт")
PL.CreateButton({ Name = "ОСТАНОВИТЬ СКРИПТ", Callback = function()
    pcall(function() G.BS_Stop() end)
end })

refreshDanceDropdown()
end   -- конец buildGui

-- БЫСТРЫЙ ПРЕДСКАН ТАНЦЕВ ДО GUI: dropdown создаётся сразу с
-- реальными вариантами, а не с пустым списком. Полный scanDances
-- (с require модулей) запускается позже в task, чтобы тяжёлый require
-- не задерживал открытие меню. Если скан упадёт - останутся
-- emote_dance и классические ID, они добавлены выше.
pcall(function()
    local out = {}
    scanAnimInstances(out)
    scanEmoteSlots(out)
    scanPlayingAnims(out, false)
end)
-- ЛЕЧИМ AutoRotate ОТ СТАРОЙ ВЕРСИИ. v11.18 могла оставить false на
-- текущем персонаже; тогда он не поворачивается даже без спина/аимлока.
-- Новый SPIN сохранит уже правильное значение true.
pcall(function()
    local ch = LP and LP.Character
    local hum = ch and ch:FindFirstChildOfClass("Humanoid")
    if hum and hum.Health > 0 and not hum.SeatPart then
        local st, ok = nil, false
        pcall(function()
            st = hum:GetState()
            ok = true
        end)
        if not ok or (st ~= Enum.HumanoidStateType.Physics
           and st ~= Enum.HumanoidStateType.Seated) then
            hum.AutoRotate = true
        end
    end
end)
buildGui()

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
    if Overlay then pcall(function() Overlay:Destroy() end) end
    -- Rayfield: уничтожаем окно. Без этого Rayfield остаётся truthy,
    -- повторный запуск не загружает библиотеку заново и появляются
    -- дубли вкладок со старыми колбэками. Destroy откладываем, чтобы
    -- не ломать текущий клик по кнопке меню.
    local rfOld = Rayfield
    Rayfield = nil
    if rfOld then
        task.defer(function() pcall(function() rfOld:Destroy() end) end)
    end
    -- снять все Drawing/Highlight визуалов (прицел, миникарта, полоски...)
    if G.BS.VIS and G.BS.VIS.destroy then pcall(G.BS.VIS.destroy) end
    -- звуковые метки и HUD тоже снимаем, иначе останутся висеть.
    -- hitLines нигде не создаётся, поэтому #hitLines на nil ронял stop()
    -- и вся очистка ниже (хуки, скорость, танец) не выполнялась.
    if type(hitLines) == "table" then
        for i = #hitLines, 1, -1 do
            pcall(function() hitLines[i]:Remove() end)
        end
    end
    hitLines = {}
    EVENTS = {}
    -- танец: снимаем свой трек; AutoRotate вернёт SPIN.releaseAll
    pcall(stopDance)
    pcall(SPIN.stop)
    pcall(SPIN.releaseAll)
    -- вернуть скорость, если скрипт сняли в момент прыжкового рывка
    pcall(speedState.stop)
    pcall(function() RunService:UnbindFromRenderStep("BS_AimLock") end)
    AIM_STEP_BOUND = false
    if connDanceKey then pcall(function() connDanceKey:Disconnect() end) end
    connDanceKey = nil
    Screen = nil
    Overlay = nil
    TargetHL = nil
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
    print("[BS HUB] v11.43 остановлен")
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
            -- ТАНЕЦ: персонаж переродился (новый раунд/респавн) — старый
            -- трек потерян. Поднимаем танец заново, если он был включён.
            if dance.on then
                task.delay(0.3, function()
                    if not STOPPED and dance.on then pcall(setDance, true) end
                end)
            end
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
    pcall(speedState.hookJump)
    bindAimLockStep()
    -- МОНЕТЫ: фоновая проверка и вызов ремоута игры.
    task.spawn(function()
        while not STOPPED do
            pcall(function() G.BS.Coins.autoTick(os.clock()) end)
            task.wait(0.5)
        end
    end)
    -- СКАНЕРЫ ОСТАВЛЕНЫ В КОНСОЛИ (кнопки в GUI убраны по просьбе):
    --   getgenv().BS.ScanAll()      -- общая структура игры
    --   getgenv().BS.DeepScan()    -- модули, ремоуты, танцы
    --   getgenv().BS.ProbeWeapon() -- урон/дальность оружия
    G.BS.ScanAll     = scanAll
    G.BS.DeepScan    = deepScan
    G.BS.ProbeWeapon = probeWeapon
    -- Роли можно править и из консоли:
    --   getgenv().BS.SetRole("Ник", "vampire")
    --   getgenv().BS.SetRole("Ник", "hunter")
    --   getgenv().BS.SetRole("Ник")          -- снять
    --   getgenv().BS.RoleSummary()           -- сводка в консоль
    --   getgenv().BS.ResetRoles()            -- сбросить всё
    G.BS.SetRole     = ROLES.set
    G.BS.RoleSummary = ROLES.summary
    G.BS.ResetRoles  = ROLES.reset
    -- Монеты и стрельба через стены:
    --   getgenv().BS.CollectCoins()   -- собрать все монеты сейчас
    --   getgenv().BS.CoinScan()       -- структура монет и ремоутов
    --   getgenv().BS.LearnCoin()      -- запомнить ремоут сбора монеты
    G.BS.CollectCoins = COIN.scan
    G.BS.CoinScan     = COIN.scanRemotes
    G.BS.LearnCoin    = function()
        G.BS.CoinLearn = true
        notify("Подбери одну монету руками — скрипт запомнит ремоут", 5)
    end
    -- значения из сохранённого состояния -> состояние движка.
    -- ВАЖНО: делаем это ДО полного скана танцев, иначе require модулей
    -- мог задержать/подвесить задачу, и танец/спин не восстановились бы.
    dance.spin      = G.BS.Spin == true
    dance.sway      = G.BS.Sway == true
    dance.spinSpeed = tonumber(G.BS.SpinSpeed) or 50
    dance.swayAmp   = tonumber(G.BS.SwayAmp) or 20
    -- если спин был включён в сохранённом конфиге, поднимаем коннект
    -- (тумблер Rayfield мог не вызвать Callback при восстановлении)
    if G.BS.Spin then pcall(SPIN.set, true) end
    -- если танец ещё не выбирали - берём первый из списка
    -- (первым всегда идёт эмоут emote_dance, он работает в любой игре)
    if dance.label == "" and #DANCES > 0 then
        local d = DANCES[1]
        dance.id, dance.emote, dance.label = d.id, d.emote, d.label
    end
    if G.BS.DanceOn then
        -- персонаж мог ещё не появиться - ждём и возобновляем
        task.spawn(function()
            task.wait(2)
            pcall(setDance, true)
        end)
    end
    -- Полный скан (require модулей) - отдельной задачей: даже если
    -- какой-то модуль залипнет, GUI и танец уже работают.
    if G.BS.DanceAutoScan then
        task.spawn(function()
            task.wait(1)
            pcall(scanDances, true)
            pcall(refreshDanceDropdown)
        end)
    end
end)

print("[BS HUB] v11.43 запущен | хуков=" .. #netConns
    .. " | клиент айм: " .. tostring(G.BS.BulletSwap)
    .. " | аимлок: " .. tostring(G.BS.AimLock)
    .. " | выбор цели: всегда"
    .. " | лома: " .. tostring(G.BS.MeleeAim)
    .. " | патроны: авто=" .. tostring(G.BS.AmmoAuto)
    .. " | магнит монет: " .. tostring(G.BS.CoinMagnet ~= false)
    .. " | прострел: " .. tostring(G.BS.WallPenetrate and G.BS.GhostShot)
    .. " | ошибок GUI=" .. #UI_ERR)
-- ОДИН РАЗ проверяем, что ремоут выстрела вообще найден. Без него
-- «клиент айм» и прострел молча не работают — именно это надо видеть
-- в логе, а не догадываться.
task.delay(1, function()
    pcall(refreshHookTargets)
    local names = {}
    if Remotes then
        for _, r in ipairs(Remotes:GetChildren()) do
            if r:IsA("RemoteEvent") or r:IsA("UnreliableRemoteEvent") then
                local n = string.lower(r.Name)
                if string.find(n, "fire", 1, true)
                   or string.find(n, "shoot", 1, true)
                   or string.find(n, "weapon", 1, true)
                   or string.find(n, "gun", 1, true)
                   or string.find(n, "hit", 1, true)
                   or string.find(n, "damage", 1, true)
                   or string.find(n, "coin", 1, true)
                   or string.find(n, "pickup", 1, true)
                   or string.find(n, "collect", 1, true) then
                    names[#names + 1] = r.Name
                end
            end
        end
    end
    print("[BS BULLET] FireWeapon=" .. tostring(NC.fw ~= nil)
        .. " | BulletSwap=" .. tostring(G.BS.BulletSwap)
        .. " | GhostShot=" .. tostring(G.BS.GhostShot)
        .. " | WallPenetrate=" .. tostring(G.BS.WallPenetrate)
        .. " | OriginSlack=" .. tostring(G.BS.OriginSlack)
        .. " | похожие ремоуты: " .. (#names > 0 and table.concat(names, ", ") or "нет"))
    if not NC.fw then
        print("[BS BULLET] ВНИМАНИЕ: Remotes.FireWeapon не найден — клиент-айм/прострел не работают")
    end
end)
-- Ошибки создания элементов печатаем одной строкой: по прошлому логу
-- было "ошибок GUI=2", но не было видно, ЧТО именно не создалось
-- (из-за этого искали причину пустого списка танцев).
if #UI_ERR > 0 then
    print("[BS GUI] что не создалось: " .. table.concat(UI_ERR, " ; "))
end
