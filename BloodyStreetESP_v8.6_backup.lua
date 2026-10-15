-- ============================================================
--  BLOODY STREET - ESP + КЛИЕНТ АИМ  v8.6
--  GUI на Rayfield. Вкладки: ESP / AIM.
--
--  ESP (вкладка ESP): 3D-коробки, ники, дистанция, HP, цвет по
--  ролям (вампир / хантер / неизвестный), главный RGB-палитра,
--  сканер игры, выживание (стамина + защита от урона NPC).
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
-- ПРОСТРЕЛ СТЕН по умолчанию ВКЛ. Иначе цель за стеной отбрасывалась,
-- и подмена не срабатывала там, где она нужнее всего.
G.BS.Penetrate       = G.BS.Penetrate ~= false
-- ШИРОКИЙ ПОИСК: берём ближайшего противника в радиусе, даже если он
-- вне экрана. Иначе цель за спиной не находится.
G.BS.BulletWideAim   = G.BS.BulletWideAim ~= false
G.BS.AimTargets      = pickOpt(G.BS.AimTargets, AIM_TARGETS, AIM_TARGETS[1])
G.BS.AimPriority     = pickOpt(G.BS.AimPriority, AIM_PRIORITY, AIM_PRIORITY[1])
G.BS.AimPart         = pickOpt(G.BS.AimPart, AIM_PART, AIM_PART[1])
G.BS.AimMaxDist      = G.BS.AimMaxDist or 300
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

if G.BS_Stop then pcall(function() G.BS_Stop() end) end

-- ФЛАГИ ХУКОВ в LUA-ТАБЛИЦАХ, а НЕ на Instance.
-- Roblox ЗАПРЕЩАЕТ писать новые поля на Instance:
--   hum.__BS = true -> "__BS is not a valid member of Humanoid".
-- Чтение отсутствующего поля даёт nil (без ошибки), но ЗАПИСЬ
-- падает ВСЕГДА -> флаг навсегда оставался nil и хук ставился
-- заново каждый кадр (тысячи вложенных обёрток над TakeDamage).
local hookedHumans = setmetatable({}, { __mode = "k" })
local energyHooked  = setmetatable({}, { __mode = "k" })
local fwHooked      = setmetatable({}, { __mode = "k" })
local hookErr       = setmetatable({}, { __mode = "k" })
-- Исходный game.__namecall до установки нашего хука. Нужен, чтобы
-- G.BS_Stop() вернул всё как было: глобальный хук иначе остался бы
-- висеть и при повторном запуске скрипта хуки стыковались бы.
local namecallOld   = nil

-- СОСТОЯНИЕ
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

-- РОЛЬ ИЗ АТРИБУТА — единственный источник с первого кадра
local ROLE_ATTRS = {
    "Role", "TicketArmedRole", "RealRole", "HiddenRole",
    "AssignedRole", "GameRole", "Team", "TeamName",
}

local function roleFromAttr(plr)
    for _, key in ipairs(ROLE_ATTRS) do
        local k = aliasOf(plr:GetAttribute(key))
        if k and k ~= "none" then return k end
    end
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
    h.FillTransparency = 1
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
    for i = 1, 4 do
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
        for i = 1, 4 do b.lines[i].Visible = false end
        return
    end
    local function project(x, y, z)
        local v = workspace.CurrentCamera:WorldToViewportPoint(
            root.Position + Vector3.new(x, y, z))
        return v
    end
    local function seg(i, a, b2)
        local ln = b.lines[i]
        if not ln then return end
        ln.From = a
        ln.To   = b2
        ln.Visible = true
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
        local ln = b.lines[((i - 1) % 4) + 1]
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
    for i = 1, 4 do
        if b.lines[i] then b.lines[i].Visible = false end
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
    hideBox(e.box)
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
    local t  = AIM_TARGETS[G.BS.AimTargets]
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
--  СТАМИНА: игра тратит энергию ЧЕРЕЗ Remotes.UseEnergy
-- ============================================================
local energyPatched = false

local function patchEnergy()
    if energyPatched or not Remotes then return end
    local ue = Remotes:FindFirstChild("UseEnergy")
    if not ue or not ue:IsA("RemoteEvent") or energyHooked[ue] then return end
    -- pcall ОБЯЗАТЕЛЕН: без него любая ошибка здесь убила бы весь
    -- поток, а вместе с ним пересканирование стамины при респавне.
    local ok, errS = pcall(function()
        local old = hookmetamethod(ue, "FireServer", function(self, ...)
            if G.BS.InfStamina then return end
            return old(self, ...)
        end)
    end)
    if ok then
        energyHooked[ue] = true
        energyPatched = true
        if G.BS.StaminaDebug then
            print("[BS STAM] Remotes.UseEnergy перехват (трата энергии блокируется)")
        end
    elseif G.BS.StaminaDebug then
        print("[BS STAM] перехват НЕ встал. Причина: " .. tostring(errS))
    end
end

-- ============================================================
--  ЗАЩИТА ОТ УРОНА NPC
-- ============================================================
local damageBlocked = 0

local function installDamageHooks()
    local ch = LP and LP.Character
    if not ch then return end
    local hum = ch:FindFirstChildOfClass("Humanoid")
    if not hum or not hum.Parent then return end
    if hookedHumans[hum] then return end
    local ok = pcall(function()
        local old = hookmetamethod(hum, "TakeDamage", function(self, amount)
            if G.BS.HealthLock then
                damageBlocked = damageBlocked + (tonumber(amount) or 0)
                return 0
            end
            return old(self, amount)
        end)
    end)
    if ok then hookedHumans[hum] = true end
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

    hr("ВЫРАН ЗАКЛЮЧЕНЫ ХУКИ")
    local fwNow = Remotes and Remotes:FindFirstChild("FireWeapon")
    print("  FireWeapon     : " .. tostring(fwHooked[fwNow or false] ~= nil))
    print("  UseEnergy      : " .. tostring(energyPatched))
    -- Причина сразу, иначе "false" ни о чём не говорит
    if fwNow and hookErr[fwNow] then
        print("  ПРИЧИНА        : " .. tostring(hookErr[fwNow]))
    end
    print("  newcclosure    : " .. tostring(type(newcclosure)))
    print("  getnamecallmethod: " .. tostring(type(getnamecallmethod)))

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
    hr("ТЕПЕРЬ ВЫСТРЕЛИ С ДИАГНОСТИКОЙ ПАТРОНА")
end

-- ============================================================
--  КЛИЕНТ АИМ: ПОДМЕНА ПАТРОНА (Remotes.FireWeapon)
-- ============================================================
-- Сигнатуру FireWeapon мы не знаем, поэтому хук не угадывает один
-- вариант, а смотрит на ФАКТИЧЕСКИЕ аргументы при выстреле:
--   - есть Vector3  -> считаем направлением/позицией, подменяем на
--     вектор к цели (единичный, если исходный единичный);
--   - нет Vector3, но есть Instance -> считаем это целью;
--   - ничего не узнали -> стреляем КАК ЕСТЬ (безопасный откат).
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

    local best, bestD
    for _, plr in ipairs(Players:GetPlayers()) do
        if plr ~= LP and by[plr] and isEnemy(plr) then
            local ch = plr.Character
            local hum = ch and ch:FindFirstChildOfClass("Humanoid")
            if ch and ch.Parent and hum and hum.Health > 0 then
                local q = pickPartOf(ch)
                if q then
                    local d = (q.Position - myRoot.Position).Magnitude
                    if G.BS.AimMaxDist <= 0 or d <= G.BS.AimMaxDist then
                        if not bestD or d < bestD then
                            best, bestD = q, d
                        end
                    end
                end
            end
        end
    end

    if not best then
        bulletPreShot = nil
        return
    end
    local dir = best.Position - myRoot.Position
    if dir.Magnitude < 0.001 then
        bulletPreShot = nil
        return
    end
    bulletPreShot = { part = best, dir = dir.Unit }
end

-- Обёртка bsClosure УДАЛЕНА намеренно.
--
-- newcclosure создаёт замыкание БЕЗ upvalue. Из-за этого в хуках
-- `old` не захватывался и оставался nil:
--   return old(self, ...)  ->  "attempt to call a nil value"
-- Из-за этого падало ВСЁ в игре (GarlicController, ControlModule,
-- CameraModule, InputLock, HotbarController, SoundPingController).
-- Для хуков, которым нужен захват переменных, newcclosure нельзя.

local function installBulletHook()
    if not Remotes then return end
    local fw = Remotes:FindFirstChild("FireWeapon")
    if not fw or not fw:IsA("RemoteEvent") then
        if G.BS.BulletDebug then
            print("[BS BULLET] Remotes.FireWeapon НЕ НАЙДЕН")
        end
        return
    end
    if fwHooked[fw] then return end

    local ok, err = pcall(function()
        local lastNamecallOld = nil
        -- ХУК ЧЕРЕЗ ГЛОБАЛЬНЫЙ __namecall.
        --
        -- Почему не hookmetamethod(fw, "FireServer", ...):
        -- в этом исполнителе hookmetamethod принимает ТОЛЬКО имена
        -- метаметодов (__namecall, __index, ...), а обычные методы
        -- вроде FireServer — нет. Проверено, в консоль приходит:
        --   "invalid argument #2 to 'hookmetamethod'
        --    (Metamethod doesn't exist)"
        --
        -- Раньше глобальный __namecall ЛОМАЛ игру (падали
        -- GarlicController, ControlModule, CameraModule, InputLock,
        -- HotbarController) — но причина была не в самом __namecall,
        -- а в том, что `old` НИКОГДА не присваивался:
        --   hookmetamethod(game, "__namecall", function(self, ...)
        --       return old(self, ...)   -- old == nil
        -- Любой вызов через ":" в игре уходил в этот хук и падал.
        --
        -- ВАЖНО: здесь ОБЫЧНАЯ функция, а НЕ newcclosure.
        -- `newcclosure` создаёт замыкание БЕЗ upvalue, поэтому `old`
        -- в неё не попадал и оставался nil — снова "attempt to call
        -- a nil value" на строке 1055 и сыпь ошибок по всей игре.
        -- Для хуков, которым нужен захват переменных, newcclosure
        -- использовать нельзя.
        local old = hookmetamethod(game, "__namecall", function(self, ...)
            local okM, method = pcall(getnamecallmethod)
            -- всё, кроме нашего FireWeapon, идёт в оригинал без изменений
            if not (okM and method == "FireServer" and self == fw
                    and G.BS.BulletSwap) then
                return old(self, ...)
            end
            local pre = bulletPreShot
            if not (pre and pre.part and pre.part.Parent and pre.dir) then
                return old(self, ...)
            end
            local n = select("#", ...)
            if n < 1 then return old(self, ...) end

            local args = table.pack(...)
            local nargs = {}
            for i = 1, n do nargs[i] = args[i] end

            -- ищем последний Vector3: обычно это направление выстрела
            local replaced = false
            for i = n, 1, -1 do
                if typeof(nargs[i]) == "Vector3" then
                    local len = nargs[i].Magnitude
                    if len > 0.01 and len < 1.5 then
                        nargs[i] = pre.dir
                    else
                        nargs[i] = pre.part.Position
                    end
                    replaced = true
                    break
                end
            end

            -- нет Vector3 -> возможно передаётся цель объектом
            if not replaced then
                for i = n, 1, -1 do
                    local t = typeof(nargs[i])
                    if t == "Instance" or t == "Player" then
                        nargs[i] = pre.part
                        replaced = true
                        break
                    end
                end
            end

            if replaced then
                if G.BS.BulletDebug and not sigLogged then
                    sigLogged = true
                    local kinds = {}
                    for i = 1, n do kinds[i] = typeof(args[i]) end
                    print("[BS BULLET] подмена работает (" .. n
                        .. " arg): " .. table.concat(kinds, ", "))
                end
                G.BS.SilentShots = G.BS.SilentShots + 1
                return old(self, table.unpack(nargs, 1, n))
            end

            -- не узнали сигнатуру -> пишем раз за сессию
            if G.BS.BulletDebug and not sigLogged then
                sigLogged = true
                local kinds = {}
                for i = 1, n do kinds[i] = typeof(args[i]) end
                print("[BS BULLET] сигнатура не распознана (" .. n
                    .. " arg): " .. table.concat(kinds, ", "))
            end
            return old(self, ...)
        end)
        if not old then
            error("hookmetamethod вернул nil (нет исходной функции)")
        end
        lastNamecallOld = old
        -- __namecall хукается глобально, fwHooked ставим только
        -- если реально есть old.
    end)

    if ok then
        fwHooked[fw] = true
        hookErr[fw] = nil
        namecallOld = lastNamecallOld
        if G.BS.BulletDebug then
            print("[BS BULLET] хук FireWeapon.FireServer установлен")
        end
    else
        hookErr[fw] = tostring(err)
        -- ПРИЧИНА ОБЯЗАТЕЛЬНО печатается: раньше pcall глотал ошибку
        -- и в консоль уходило бесполезное "исполнитель заблокировал",
        -- из-за чего невозможно было понять, что именно не так.
        print("[BS BULLET] ХУК НЕ ВСТАЛ. Причина: " .. tostring(err))
    end
end

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
                    applyRole(by[plr], roleFromAttr(plr) or netRoles[plr], CONF.attr)
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
task.spawn(function() while task.wait(1) do pcall(scan) end end)
Players.PlayerAdded:Connect(function() task.delay(0.5, scan) end)
Players.PlayerRemoving:Connect(function(p) remove(p) end)

-- ============================================================
--  КАДР
-- ============================================================
local lastT = os.clock()
local conn = RunService.RenderStepped:Connect(function()
    local now = os.clock()
    local dt = math.min(0.1, math.max(0.001, now - lastT))
    lastT = now

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

            e.hl.FillColor = color
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
    LoadingSubtitle = "ESP + Client Aim v8.6",
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

-- ============================================================
--  СТОП
-- ============================================================
G.BS_Stop = function()
    pcall(function() conn:Disconnect() end)
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
    G.BS.BulletSwap = false
    -- Снимаем глобальный __namecall, иначе он останется висеть
    -- и при повторном запуске скрипта хуки стыкуются.
    if namecallOld then
        pcall(function()
            hookmetamethod(game, "__namecall", namecallOld)
        end)
        namecallOld = nil
    end
    G.BS_Stop = nil
    print("[BS HUB] v8.6 остановлен")
end

-- Пересканирование при старте: устанавливаем хуки и сталкин.
task.spawn(function()
    pcall(patchEnergy)
    pcall(installDamageHooks)
    pcall(installBulletHook)
    if LP then
        LP.CharacterAdded:Connect(function()
            task.wait(0.5)
            pcall(installDamageHooks)
            pcall(scan)
        end)
    end
    if G.BS.ScanOnStart then
        task.wait(2)
        pcall(scanAll)
    end
end)

print("[BS HUB] v8.6 запущен | хуков=" .. #netConns
    .. " | клиент айм: " .. tostring(G.BS.BulletSwap)
    .. " | прострел: " .. tostring(G.BS.Penetrate)
    .. " | ошибок GUI=" .. #UI_ERR)
