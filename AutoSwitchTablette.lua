-- =============================================================================
-- FS25_AutoSwitchTablette  -  AutoSwitchTablette.lua
-- Auteur : Fabien
--
-- Terminal de bord et tablettes 3D d'AutoSwitch, sortis d'AutoSwitch dans ce mod (13/11).
-- Demande AutoSwitch (dépendance du modDesc : chargé après lui).
--
-- Les scripts du terminal tournent dans l'environnement de ce mod, qui lit celui
-- d'AutoSwitch quand il ne connaît pas un nom (AS, AS_Settings, AS_Diff...) :
--   - AS_MOD_DIR, g_i18n, g_currentModName : ceux de CE mod (images objects/terminal,
--     textes vtpas_tm_*), le reste vient d'AutoSwitch ;
--   - AS.L cherche d'abord les textes de ce mod, puis ceux d'AutoSwitch ;
--   - réglages toujours dans modSettings/FS25_AutoSwitch (positions, tailles gardées) ;
--   - touches Ctrl droit + T, Y, 1 à 4 ajoutées aux touches réservées d'AutoSwitch (AS_KeyLock).
-- =============================================================================

local MY_NAME = g_currentModName or "FS25_AutoSwitchTablette"
local MY_DIR = g_currentModDirectory or ""

local function log(fmt, ...)
    print("[AutoSwitchTablette] " .. string.format(fmt, ...))
end

local FILES = {
    "scripts/CaseFont.lua",
    "scripts/Terminal.lua",
    "scripts/TerminalMachine.lua",
    "scripts/TerminalTools.lua",
    "scripts/TerminalCourses.lua",
    "scripts/TerminalMap.lua",
    "scripts/TerminalGps.lua",
    "scripts/TerminalFarmPilot.lua",
    "scripts/TerminalTablet.lua",
    "scripts/TerminalMassey.lua",
    "scripts/TerminalFendt.lua",
    "scripts/TerminalDeutz.lua",
    "scripts/TerminalJohnDeere.lua",
    "scripts/SectionControl.lua",
}

-- touches réservées (action, touche avec Ctrl droit, où elle marche)
local KEYS = {
    { "AS_TERMINAL",       "KEY_t",  "vehicle" },
    { "AS_TERMINAL_TOUCH", "KEY_y",  "vehicle" },
    { "AS_FKEY1",          "KEY_1",  "vehicle" },
    { "AS_FKEY2",          "KEY_2",  "vehicle" },
    { "AS_FKEY3",          "KEY_3",  "vehicle" },
    { "AS_FKEY4",          "KEY_4",  "vehicle" },
}

-- environnement d'AutoSwitch (nom du mod, ou copie renommée FS25_AutoSwitch...)
local function autoSwitchEnv()
    local function ok(e) return type(e) == "table" and type(rawget(e, "AS")) == "table" end
    if ok(FS25_AutoSwitch) then return FS25_AutoSwitch, "FS25_AutoSwitch" end
    if g_modIsLoaded ~= nil then
        for name, loaded in pairs(g_modIsLoaded) do
            if loaded and name ~= MY_NAME and string.sub(name, 1, 15) == "FS25_AutoSwitch"
                and not string.find(name, "Tablette", 1, true) and not string.find(name, "Updater", 1, true) then
                local e = _G[name]
                if ok(e) then return e, name end
            end
        end
    end
    return nil
end

local function start()
    local asEnv, asName = autoSwitchEnv()
    if asEnv == nil then
        log("ERREUR : AutoSwitch introuvable ou pas démarré, terminal et tablettes non chargés")
        return
    end
    local okE, env = pcall(getfenv, autoSwitchEnv)   -- environnement de ce fichier = celui du mod
    local okG, G0 = pcall(getfenv, 0)
    if not okE or type(env) ~= "table" or env == asEnv or (okG and env == G0) then
        log("ERREUR : environnement du mod introuvable, terminal et tablettes non chargés")
        return
    end

    -- ce que ce mod garde à lui (lu avant de brancher AutoSwitch derrière)
    local myI18n = g_i18n
    rawset(env, "g_i18n", myI18n)
    rawset(env, "g_currentModName", MY_NAME)
    rawset(env, "g_currentModDirectory", MY_DIR)
    rawset(env, "AS_MOD_DIR", MY_DIR)

    -- AS : celui d'AutoSwitch, avec les textes de ce mod d'abord
    local realAS = asEnv.AS
    local myAS = setmetatable({}, { __index = realAS, __newindex = realAS })
    rawset(myAS, "L", function(key)
        if myI18n ~= nil and myI18n.hasText ~= nil and myI18n:hasText(key) then
            return myI18n:getText(key)
        end
        return realAS.L(key)
    end)
    rawset(env, "AS", myAS)

    -- les autres noms : ceux d'AutoSwitch (qui lit lui-même les globales du jeu)
    local mt = getmetatable(env)
    if type(mt) ~= "table" then mt = {} end
    mt.__index = asEnv
    setmetatable(env, mt)

    -- touches Ctrl droit réservées
    local kl = asEnv.AS_KeyLock
    if type(kl) == "table" and type(kl.KEYS) == "table" and type(kl.ours) == "table" and type(kl.byCombo) == "table" then
        for _, k in ipairs(KEYS) do
            if kl.ours[k[1]] == nil then
                table.insert(kl.KEYS, k)
                kl.ours[k[1]] = { key = k[2], where = k[3] }
                kl.byCombo["KEY_rctrl " .. k[2]:lower()] = k[1]
            end
        end
    end

    for _, file in ipairs(FILES) do
        local path = Utils.getFilename(file, MY_DIR)
        if fileExists(path) then
            source(path)
        else
            log("ERREUR : fichier introuvable : %s", tostring(path))
        end
    end
    log("terminal et tablettes chargés (%d fichiers, avec %s)", #FILES, tostring(asName))
end

start()
