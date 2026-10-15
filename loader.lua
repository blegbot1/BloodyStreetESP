-- ============================================================
--  BLOODY STREET ESP — LOADER
--
--  ОДНА СТРОКА ДЛЯ ЗАПУСКА (вставить в Jy):
--  loadstring(game:HttpGet("https://raw.githubusercontent.com/blegbot1/BloodyStreetESP/main/BloodyStreetESP.lua",true))()
--
--  В Jy попадает только URL — тела скрипта редактор не видит,
--  поэтому внутренний сканер Jy не срабатывает.
-- ============================================================

local URL = "https://raw.githubusercontent.com/blegbot1/BloodyStreetESP/main/BloodyStreetESP.lua"

local g = getgenv()
local now = os.clock()
if g.BS_LOADED_AT and (now - g.BS_LOADED_AT) < 5 then
    warn("[BS ESP] только что запущен, подожди 5 сек")
    return
end
g.BS_LOADED_AT = now

print("[BS ESP] загрузка:", URL)

local ok, err = pcall(function()
    local src = game:HttpGet(URL, true)
    if type(src) ~= "string" or #src < 100 then
        error("пустой или битый ответ")
    end
    local chunk = loadstring(src, "BloodyStreetESP")
    if not chunk then
        error("loadstring вернул nil — синтаксис сломан")
    end
    chunk()
end)

if not ok then
    g.BS_LOADED_AT = nil
    warn("[BS ESP] ошибка загрузки:", err)
    error("[BS ESP] не удалось загрузить скрипт: " .. tostring(err))
end

print("[BS ESP] готово")