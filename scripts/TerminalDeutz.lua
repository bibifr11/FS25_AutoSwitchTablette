-- AutoSwitch : terminal des tracteurs Deutz-Fahr (iMonitor SDF)
-- Fichier chargé par AutoSwitch.lua après Terminal.lua.
--
-- (06/11) même méthode que le Massey et le Fendt : les écrans HD (refaits d'après les tutoriels
-- iMonitor SDF), intégrés tels quels, sans texte dans les images ; textes et valeurs écrits en direct (FR / EN / DE).
--   Deux thèmes, comme le vrai iMonitor : clair le jour, sombre la nuit (heure du jeu) ; réglage Auto / Clair / Sombre.
--   Châssis fixe : colonne des applications à gauche, mini-vue (carte en direct), colonne des pages du tracteur
--   à droite, barre d'état en bas (heure, signal, RTK, vitesse, cap, écart, surface, AUTO).
-- Repères en pixels des écrans 1672 x 941.

AS_TerminalDeutz = {}
local M = AS_TerminalDeutz
M.MOD_NAME = g_currentModName

local WH = { 1, 1, 1, 1 }
local DK = { 0.10, 0.11, 0.12, 1 }
local BLUE = { 0.20, 0.60, 0.96, 1 }
local GRN = { 0.10, 0.85, 0.10, 1 }
local SIGCOL = { fix = { 0.20, 0.75, 0.10, 1 }, float = { 1.00, 0.55, 0.12, 1 }, gps = { 1.00, 0.70, 0.10, 1 }, lost = { 0.90, 0.15, 0.12, 1 } }
local function clamp01(t) return math.max(0, math.min(1, t or 0)) end

local function H() return AS_Terminal.MFH end
local function T(key) return H().T(key) end

-------------------------------------------------------------------------------
-- thème : 1 = Auto (clair de 7 h à 20 h, heure du jeu), 2 = clair, 3 = sombre
-------------------------------------------------------------------------------
function M.isDark(self)
    local s = self.settings or {}
    local m = s.dfTheme or 1
    if m == 2 then return false end
    if m == 3 then return true end
    local env = g_currentMission ~= nil and g_currentMission.environment or nil
    local h = env ~= nil and ((env.dayTime or 0) / 3600000) % 24 or 12
    return h < 7 or h >= 20
end
local function sfx(self) return M.isDark(self) and "_s" or "_c" end
local function ink(self) return M.isDark(self) and WH or DK end
local function dim(self) return M.isDark(self) and { 0.62, 0.64, 0.68, 1 } or { 0.45, 0.47, 0.50, 1 } end
-- voile sur une touche sans fonction dans le jeu (grande fenêtre ; l'écran 3D de la cabine ne sait pas la transparence)
local function offCol(self) return M.isDark(self) and { 0.05, 0.05, 0.06, 0.62 } or { 0.97, 0.97, 0.98, 0.62 } end

-- dessin à l'échelle des écrans
local function frame(self, ctx, Wp, Hp)
    local kx, ky = Wp / self.HOME_W, Hp / self.HOME_H
    local f = {}
    function f.PX(x) return x * kx end
    function f.PY(y) return y * ky end
    function f.PW(w) return w * kx end
    function f.img(x, y, w, h, name)
        local file = H().caseImg(name)
        ctx.image(f.PX(x), f.PY(y), f.PW(w), f.PY(h), ctx.rec == nil and AS_TerminalTools ~= nil and AS_TerminalTools:overlay(file) or nil, "img_" .. name, file)
    end
    function f.txt(x, ymid, size, s, col, align, maxW, bold)
        ctx.text(f.PX(x), f.PY(ymid + size * 0.36), f.PY(size), s, col or DK, align or RenderText.ALIGN_LEFT, bold == true, maxW and f.PW(maxW) or nil)
    end
    function f.ctr(x, ymid, size, s, col, maxW, bold) f.txt(x, ymid, size, s, col, RenderText.ALIGN_CENTER, maxW, bold) end
    function f.rgt(x, ymid, size, s, col, maxW, bold) f.txt(x, ymid, size, s, col, RenderText.ALIGN_RIGHT, maxW, bold) end
    local hot = ctx.hotspot or ctx.button
    function f.hot(x0, y0, x1, y1, action) hot(f.PX(x0), f.PY(y0), f.PW(x1 - x0), f.PY(y1 - y0), action) end
    function f.rect(x, y, w, h, c)
        if ctx.rec ~= nil and (c[4] or 1) < 0.99 then return end
        ctx.rect(f.PX(x), f.PY(y), f.PW(w), f.PY(h), c)
    end
    function f.box(x0, y0, x1, y1)
        if ctx.X == nil then return nil end
        return { x = ctx.X(f.PX(x0)), y = ctx.Y(f.PY(y1)), w = ctx.sx(f.PW(x1 - x0)), h = ctx.sy(f.PY(y1 - y0)) }
    end
    return f
end

local function dec(v, n)
    local s = string.format("%." .. (n or 1) .. "f", v or 0)
    if g_languageShortName ~= "en" then s = s:gsub("%.", ",") end
    return s
end
local function spd(kmh)
    local u = H().unitsOf()
    if u ~= nil and u.kmh ~= nil then return u.kmh(kmh), u.speed or "km/h" end
    return kmh, "km/h"
end
-- vitesse maxi du tracteur (échelle des vitesses mémorisées)
local function vTop(v, d)
    local cc = v ~= nil and v.spec_drivable ~= nil and v.spec_drivable.cruiseControl or nil
    local top = cc ~= nil and tonumber(cc.maxSpeed) or nil
    if top == nil or top < 5 then top = d.maxSpeed end
    if top == nil or top < 5 then top = 50 end
    return top
end
M.mem2 = {}
local function mem2Of(v, d) return M.mem2[v] or math.floor(vTop(v, d) * 0.5 + 0.5) end

-------------------------------------------------------------------------------
-- carte en direct (mini-vue de gauche)
-------------------------------------------------------------------------------
local function liveMap(self, d, ctx, v, f, x0, y0, x1, y1, view)
    local G = AS_TerminalGps
    if G == nil or v == nil then return end
    local cx, cy = f.PX(x0), f.PY(y0)
    local ctx2 = { text = ctx.text, measure = ctx.measure, rect = ctx.rect, button = ctx.button, hotspot = ctx.hotspot, image = ctx.image,
        cx = cx, cy = cy, cw = f.PX(x1) - cx, ch = f.PY(y1) - cy, rx = f.PX(x1), sideY = cy,
        X = ctx.X, Y = ctx.Y, sx = ctx.sx, sy = ctx.sy, rec = ctx.rec, v = v, noKeys = true, mapOnly = true }
    local old, oldSub = G.view, G.sub
    G.view = view; G.sub = nil
    local ok, err = pcall(G.draw, G, self, d, ctx2, v)
    G.view = old; G.sub = oldSub
    if not ok and not M.loggedMap then M.loggedMap = true; print("[AS_Terminal] Deutz : ERREUR mini-vue : " .. tostring(err)) end
end

-------------------------------------------------------------------------------
-- Châssis : colonne des applications (gauche), mini-vue, pages du tracteur (droite), barre d'état (bas)
-------------------------------------------------------------------------------
-- colonne de gauche (de haut en bas) : SDF = accueil, guidage, réglages du tracteur, tâches (compteurs),
-- données (pas dans le jeu), caméra, ISOBUS (outil), carte de travail, GPS, infos machine, produits (outil), réglages
M.APPS = { { 43, "page_home" }, { 125, "page_gps" }, { 205, "page_dfmotor" }, { 283, "page_count" }, { 365, "page_dfcp" }, { 447, "page_fp" },
    { 517, "page_tool" }, { 597, "page_dfsc" }, { 665, "page_work" }, { 735, "page_tractor" }, { 810, "page_tool" }, { 885, "page_dfmenu" } }
-- colonne de droite : moteur, relevage AR, relevage AV, distributeurs, ASM, ComfortTip, infos, réglages
M.SIDE_Y = { 75, 173, 270, 365, 458, 548, 637, 727 }
M.SIDE = { "page_dfmotor", "page_dfhitchr", "page_dfhitchf", "page_dfvalve", "page_dfasm", "page_dfct", "page_tractor", "page_set" }

-- écran 09 (tronçons) : sa colonne de gauche a la trémie, l'appli tronçons et une flèche de défilement
M.APPS_SC = { { 43, "page_home" }, { 125, "page_gps" }, { 205, "page_dfmotor" }, { 283, "page_count" }, { 355, nil }, { 430, "page_tool" },
    { 505, nil }, { 570, "page_dfsc" }, { 640, "page_dfmotor" }, { 710, "page_count" }, { 758, nil }, { 815, "page_tool" }, { 890, "page_dfmenu" } }
M.LIT = { dfmotor = 1, home = 1, dfhitchr = 2, dfhitchf = 3, dfvalve = 4, dfrem = 4, dfasm = 5, dfct = 6, tractor = 7, set = 8, dfmenu = 8 }
function M.chassis(self, d, f, ctx, v, page)
    for _, a in ipairs(M.APPS) do
        local act = a[2]
        -- (06/11) deux cases vides de l'image
        if act == "page_dfcp" or act == "page_fp" then
            local ui = AS_Terminal.ui
            local ok
            if act == "page_dfcp" then ok = ui ~= nil and ui.hasCp ~= nil and ui.hasCp(v) == true
            else ok = AS_TerminalFp ~= nil and AS_TerminalFp.available ~= nil and AS_TerminalFp:available(v) == true end
            -- (13/11) icône seulement si le mod est installé
            local inst = ui ~= nil and ((act == "page_dfcp" and ui.cpInstalled ~= nil and ui.cpInstalled()) or (act == "page_fp" and ui.fpInstalled ~= nil and ui.fpInstalled()))
            if inst then f.img(23, a[1] - 30, 60, 60, (act == "page_dfcp" and "as_df_icp" or "as_df_ifp") .. sfx(self)) end
            if not ok then act = nil end
        end
        if act ~= nil then f.hot(2, a[1] - 38, 104, a[1] + 38, act)
        else f.rect(14, a[1] - 34, 78, 68, offCol(self)) end
    end
    -- (06/11) ronds de droite = sprites, celui de la page ouverte allumé
    local lit = M.LIT[page]
    for i, y in ipairs((page == "gps" or page == "dfsc") and {} or M.SIDE_Y) do
        f.img(1557, y - 46, 100, 92, "as_df_r" .. i .. (i == lit and "_on" or "_off") .. sfx(self))
        local a = M.SIDE[i]
        if a ~= nil then f.hot(1558, y - 46, 1656, y + 46, a)
        else f.rect(1562, y - 42, 90, 84, offCol(self)) end
    end
    -- mini-vue : carte en direct (un appui ouvre le guidage)
    if page ~= "gps" and page ~= "dfsc" and page ~= "dfmenu" and page ~= "gpscourse" then
        liveMap(self, d, ctx, v, f, 110, 6, 496, 808, "top")
        f.hot(110, 6, 496, 808, "page_gps")
    end
    self.headerBox = f.box(500, 0, 1545, 62)
    M.statusBar(self, d, f)
end

-- barre d'état du bas (positions de l'écran 01 ; l'écran 09 tronçons a sa propre barre, plus serrée)
M.SB = { sat = 790, satW = 70, prec = 710, precW = 150, spd = 952, hd = 1090, xte = 1235, wr = 1500, wrW = 110, gps0 = 695, gps1 = 875 }
M.SB_SC = { sat = 768, satW = 48, prec = 692, precW = 122, spd = 880, hd = 1005, xte = 1130, wr = 1355, wrW = 82, gps0 = 685, gps1 = 818 }
function M.statusBar(self, d, f, L)
    L = L or M.SB
    local c = ink(self)
    f.txt(512, 852, 26, H().fmtClock(), c, nil, 92, true)
    local env = g_currentMission ~= nil and g_currentMission.environment or nil
    local day = env ~= nil and (tonumber(env.currentDayInPeriod) or 1) or 1
    f.txt(512, 906, 22, tostring(day), c, nil, 92)
    -- satellites et précision (RTK simulé du terminal)
    local G = AS_TerminalGps
    local sig = "gps"
    if G ~= nil and d.vehicle ~= nil then
        local okR, s1 = pcall(G.rtkSignal, G, d.vehicle)
        if okR and s1 ~= nil then sig = s1 end
    end
    local now = (g_time or 0)
    local sats = math.max(15, math.min(22, math.floor(18.5 + 2.5 * math.sin(now / 97000) + 1.0 * math.sin(now / 23000) + 0.5)))
    f.txt(L.sat, 852, 26, tostring(sats), c, nil, L.satW, true)
    local prec = ({ fix = "0,02 m", float = "0,10 m", gps = "0,30 m", lost = "--" })[sig] or "--"
    f.txt(L.prec, 896, 17, prec, c, nil, L.precW)
    f.txt(L.prec, 918, 16, sig == "fix" and "RTK" or (sig == "float" and "FLOAT" or "GPS"), SIGCOL[sig] or c, nil, L.precW, true)
    -- vitesse, cap, écart à la ligne
    local sv, su = spd(math.abs(d.speed or 0))
    f.ctr(L.spd, 870, 30, dec(sv, 1), c, 96, true)
    f.ctr(L.spd, 902, 15, su, c, 96)
    local hd = "--"
    local v = d.vehicle
    if v ~= nil and v.rootNode ~= nil and localDirectionToWorld ~= nil then
        local dx, _, dz = localDirectionToWorld(v.rootNode, 0, 0, 1)
        local a = math.deg(math.atan2(dx, dz))
        hd = string.format("%d°", math.floor((180 - a) % 360 + 0.5))
    end
    f.ctr(L.hd, 878, 26, hd, c, 92, true)
    local g = d.gps or {}
    local xte = (g.data ~= nil and g.onLine and not g.inTurn and g.xte ~= nil) and tostring(math.floor(math.abs(g.xte) * 100 + 0.5)) or "--"
    f.ctr(L.xte, 870, 28, xte, c, 70, true)
    f.ctr(L.xte, 902, 15, "cm", c, 70)
    -- surface du compteur en cours
    local ha = 0
    local cnt = d.cnt
    if cnt ~= nil and cnt.jobs ~= nil then
        local j = cnt.jobs[cnt.active or 1]
        if j ~= nil then ha = tonumber(j.area or j.ha or 0) or 0 end
    end
    f.rgt(L.wr, 852, 22, (d.width ~= nil and dec(d.width, 1) .. " m") or "---", c, L.wrW)
    f.rgt(L.wr, 900, 26, dec(ha, 2), c, L.wrW + 10, true)
    f.rgt(L.wr, 924, 13, "ha", c, 60)
    -- AUTO : direction automatique du guidage (anneau vert quand elle conduit)
    local steering = g.steer == "on" or g.active == true
    f.ctr(1590, 910, 14, "AUTO", steering and SIGCOL.fix or { 0.85, 0.12, 0.10, 1 }, 90, true)
    f.hot(1535, 822, 1648, 936, "gps_steer")
    f.hot(440, 822, 610, 936, "page_count")
    f.hot(L.gps0, 822, L.gps1, 936, "page_gps")
end

-------------------------------------------------------------------------------
-- 01 Moteur et transmission
-------------------------------------------------------------------------------
local function bar(f, x0, x1, y0, y1, t, col)
    t = clamp01(t)
    if t > 0.005 then f.rect(x0, y0, (x1 - x0) * t, y1 - y0, col) end
end
function M.setCruise(self, v, kmh, go)
    if v == nil then return end
    kmh = math.max(1, kmh)
    if v.setCruiseControlMaxSpeed ~= nil then pcall(v.setCruiseControlMaxSpeed, v, kmh, kmh) end
    if go and v.setCruiseControlState ~= nil and Drivable ~= nil and Drivable.CRUISECONTROL_STATE_ACTIVE ~= nil then
        pcall(v.setCruiseControlState, v, Drivable.CRUISECONTROL_STATE_ACTIVE)
    end
    self.lastRead = -100000
end
function M.motorAction(self, a)
    local d = self.data or {}
    local v = d.vehicle
    if v == nil then return end
    local top = vTop(v, d)
    local cur = d.cruiseSpeed or 10
    if a == "dfm_cc1" then M.setCruise(self, v, cur, true)
    elseif a == "dfm_cc2" then M.setCruise(self, v, mem2Of(v, d), true)
    elseif a == "dfm_c1m" then M.setCruise(self, v, cur - 1, false)
    elseif a == "dfm_c1p" then M.setCruise(self, v, math.min(top, cur + 1), false)
    elseif a == "dfm_c2m" then M.mem2[v] = math.max(1, mem2Of(v, d) - 1)
    elseif a == "dfm_c2p" then M.mem2[v] = math.min(top, mem2Of(v, d) + 1) end
    self.lastRead = -100000
end
-- case de vitesse mémorisée : − à gauche, valeur au milieu (appui = régulateur à cette vitesse), + à droite
local function speedBox(self, f, x0, x1, y, kmh, act, unit)
    local c = ink(self)
    local sv = spd(kmh)
    f.ctr((x0 + x1) * 0.5, y, 30, dec(sv, 1), c, x1 - x0 - 80, true)
    f.ctr(x0 + 22, y, 30, "−", c, 30, true); f.ctr(x1 - 22, y, 30, "+", c, 30, true)
    f.hot(x0, y - 34, x0 + 44, y + 34, act .. "m")
    f.hot(x0 + 44, y - 34, x1 - 44, y + 34, "dfm_cc" .. act:sub(-1))
    f.hot(x1 - 44, y - 34, x1, y + 34, act .. "p")
    f.txt(x1 + 16, y, 22, unit, c, nil, 90)
end
function M.motor(self, d, ctx, v, Wp, Hp)
    local f = frame(self, ctx, Wp, Hp)
    f.img(0, 0, 1672, 941, "as_df_motor" .. sfx(self))
    local c = ink(self)
    f.txt(590, 32, 24, T("df_motor"), c, nil, 380, true)
    f.rgt(1525, 32, 22, d.cvt and "TTV" or (d.manual == true and T("manual") or T("auto")), c, 520)
    -- colonne de gauche : régime de prise de force, régime actuel, régime maxi
    local pto = (d.ptoF or d.ptoR) and d.ptoRpm ~= nil and tostring(math.floor(d.ptoRpm + 0.5)) or "--"
    f.ctr(770, 138, 30, pto, c, 170, true)
    f.ctr(770, 262, 30, d.rpm ~= nil and tostring(math.floor(d.rpm + 0.5)) or "--", c, 170, true)
    f.ctr(770, 386, 30, d.maxRpm ~= nil and tostring(math.floor(d.maxRpm + 0.5)) or "--", c, 170, true)
    for _, y in ipairs({ 262, 386 }) do f.txt(880, y, 22, T("df_rpm"), c, nil, 90) end
    -- sens de marche (06/11) : bouton bleu = sens en cours
    -- à l'arrêt : sens choisi de l'inverseur (moteur du jeu), sinon le sens du mouvement
    local mo = v ~= nil and v.spec_motorized ~= nil and v.spec_motorized.motor or nil
    local rev = (mo ~= nil and type(mo.currentDirection) == "number" and mo.currentDirection < 0) or (d.dir or 0) < 0
    f.img(1015, 104, 203, 86, "as_df_dirL_" .. (rev and "off" or "on") .. sfx(self))
    f.img(1255, 104, 197, 86, "as_df_dirR_" .. (rev and "on" or "off") .. sfx(self))
    -- vitesses mémorisées 1 et 2 (régulateur)
    local _, su = spd(1)
    speedBox(self, f, 1163, 1349, 288, d.cruiseSpeed or 0, "dfm_c1", su)
    speedBox(self, f, 1163, 1349, 390, mem2Of(v, d), "dfm_c2", su)
    -- AUTO PdF : pas dans le jeu (grisé) ; vitesse de travail de l'outil, vitesse maxi
    f.rect(668, 490, 168, 62, offCol(self))
    f.ctr(763, 618, 28, d.workSpeed ~= nil and dec(spd(d.workSpeed), 1) or "--", c, 170, true)
    f.ctr(763, 738, 28, dec(spd(vTop(v, d)), 1), c, 170, true)
    f.txt(872, 618, 20, su, c, nil, 90); f.txt(872, 738, 20, su, c, nil, 90)
    -- charge moteur (vert) et régime (bleu)
    local load = clamp01(d.load or 0)
    bar(f, 1176, 1512, 496, 541, load, GRN)
    f.ctr(1344, 518, 26, string.format("%d %%", math.floor(load * 100 + 0.5)), c, 200, true)
    local acc = (d.rpm ~= nil and d.maxRpm ~= nil and d.maxRpm > 0) and clamp01(d.rpm / d.maxRpm) or 0
    bar(f, 1176, 1512, 611, 654, acc, BLUE)
    f.ctr(1344, 632, 26, string.format("%d %%", math.floor(acc * 100 + 0.5)), c, 200, true)
    -- mode de la transmission
    f.ctr(1300, 730, 30, d.manual == true and "MANU" or "AUTO", c, 380, true)
    f.ctr(1300, 775, 18, string.format("%s : 800 - %s %s", d.manual == true and "MANU" or "AUTO",
        d.maxRpm ~= nil and tostring(math.floor(d.maxRpm + 0.5)) or "--", T("df_rpm")), c, 400)
    M.chassis(self, d, f, ctx, v, "dfmotor")
end

-------------------------------------------------------------------------------
-- 02 Relevages AR et AV
-------------------------------------------------------------------------------
M.HROW = { 190, 284, 375, 468, 562 }
local function slider(self, f, y, t, label, act)
    local x0, x1 = 958, 1495
    bar(f, x0, x1, y - 24, y + 24, t, BLUE)
    f.ctr((x0 + x1) * 0.5, y, 24, label, ink(self), 300, true)
    if act ~= nil then f.hot(x0, y - 34, x1, y + 34, act) end
end
local function hitchPage(self, d, ctx, v, Wp, Hp, front)
    local page = front and "dfhitchf" or "dfhitchr"
    local f = frame(self, ctx, Wp, Hp)
    f.img(0, 0, 1672, 941, "as_df_hitch" .. sfx(self))
    local c = ink(self)
    local hf, hr = H().caseHitches(d)
    local h = front and hf or hr
    local has = h ~= nil and h.object ~= nil
    local up = has and clamp01(h.up or 0) or 0
    local act = front and "hitch_f" or "hitch_r"
    f.txt(600, 32, 24, T(front and "df_hitchF" or "df_hitchR"), c, nil, 380, true)
    f.rgt(1525, 32, 22, has and (H().vehicleName ~= nil and H().vehicleName(h.object) or "") or T("empty"), c, 520)
    -- jauge verticale : hauteur réelle (levé = 100 %, en bas = 0 %)
    if has then
        local y1, y0 = 406, 162
        local yt = y1 - (y1 - y0) * up
        f.rect(646, yt, 70, y1 - yt, GRN)
    end
    f.ctr(560, 285, 26, has and (H().hitchPct(h) .. " %") or "--", c, 110, true)
    f.hot(530, 150, 620, 240, act); f.hot(530, 335, 620, 420, act); f.hot(640, 150, 720, 412, act)
    -- lignes : position réelle (appui = lever / baisser), limite haute, position de travail ; 4 et 5 pas dans le jeu
    slider(self, f, M.HROW[1], up, has and string.format("%d %%", math.floor(up * 100 + 0.5)) or "--", has and act or nil)
    slider(self, f, M.HROW[2], 1, "100 %")
    slider(self, f, M.HROW[3], 0, "0 %")
    for i = 4, 5 do f.rect(955, M.HROW[i] - 28, 545, 56, offCol(self)) end
    -- verrou (cadenas) : la flèche de levée générale l'actionne ou non
    local locked = self.hitchLocked ~= nil and self:hitchLocked(v, front) or false
    f.ctr(668, 510, 16, locked and T("fd_lockOn") or T("fd_lockOff"), locked and c or { 0.80, 0.12, 0.10, 1 }, 230)
    f.hot(612, 430, 724, 505, front and "hlock_f" or "hlock_r")
    f.rect(552, 534, 168, 60, offCol(self))
    -- < > : relevage arrière / avant ; points = page en cours
    f.hot(775, 70, 840, 132, "page_dfhitchr"); f.hot(1466, 70, 1530, 132, "page_dfhitchf")
    -- cadre du bas : outil attelé et état
    local st = has and (h.moveDown and T("df_lowered") or T("df_raised")) or T("empty")
    f.txt(640, 690, 26, has and (H().vehicleName ~= nil and H().vehicleName(h.object) or "") or T("empty"), c, nil, 850, true)
    f.txt(640, 740, 22, st, dim(self), nil, 850)
    M.chassis(self, d, f, ctx, v, page)
end
function M.hitchr(self, d, ctx, v, Wp, Hp) return hitchPage(self, d, ctx, v, Wp, Hp, false) end
function M.hitchf(self, d, ctx, v, Wp, Hp) return hitchPage(self, d, ctx, v, Wp, Hp, true) end

-------------------------------------------------------------------------------
-- 03 Distributeurs : 5 distributeurs = Fonctions 1 à 5 du terminal (mêmes réglages que les autres marques) ;
-- appui = ses fonctions (ou son réglage s'il n'en a pas) ; clé + joystick = réglage du distributeur choisi
-------------------------------------------------------------------------------
M.VX = { 625, 825, 1023, 1222, 1420 }
M.VCOL = { { 0.98, 0.78, 0.05, 1 }, { 0.90, 0.10, 0.10, 1 }, { 0.10, 0.70, 0.10, 1 }, { 0.10, 0.25, 0.85, 1 }, { 0.60, 0.10, 0.12, 1 } }
M.vSel = 1
function M.valve(self, d, ctx, v, Wp, Hp)
    local f = frame(self, ctx, Wp, Hp)
    f.img(0, 0, 1672, 941, "as_df_valve" .. sfx(self))
    local c = ink(self)
    f.txt(600, 32, 24, T("df_valves"), c, nil, 380, true)
    local rem = (v ~= nil and self.remoteFns ~= nil) and self:remoteFns(v) or {}
    for n, cx in ipairs(M.VX) do
        local fns = rem[n] or {}
        f.ctr(cx, 500, 15, #fns > 0 and self:remoteShort(fns[1]) or ("-- " .. n .. " --"), c, 124, #fns > 0)
        if n == (M.vSel or 1) then f.rect(cx - 50, 798, 100, 6, GRN) end
        f.hot(cx - 66, 480, cx + 66, 796, #fns > 0 and ("rem_" .. n) or ("dfv_sel_" .. n))
    end
    -- modes, débit du joystick, chargeur : réglages hydrauliques absents du jeu
    f.rect(612, 108, 196, 72, offCol(self)); f.rect(958, 108, 190, 72, offCol(self)); f.rect(620, 350, 192, 72, offCol(self))
    f.rect(1204, 92, 122, 342, offCol(self))
    -- clé + joystick : réglage des fonctions du distributeur choisi
    f.hot(750, 228, 950, 302, "dfv_sel_" .. (M.vSel or 1))
    f.rgt(1525, 32, 20, T("df_valveHint"), dim(self), 520)
    M.chassis(self, d, f, ctx, v, "dfvalve")
end

-- 04 réglage d'un distributeur : ses 3 fonctions et la liste (AV | AR | Les deux), sur son écran de détail
function M.rem(self, d, ctx, v, Wp, Hp)
    local f = frame(self, ctx, Wp, Hp)
    f.img(0, 0, 1672, 941, "as_df_valved" .. sfx(self))
    local dark = M.isDark(self)
    local c = ink(self)
    local card = dark and { 0.13, 0.13, 0.14, 1 } or { 0.97, 0.97, 0.98, 1 }
    local head = dark and { 0.28, 0.30, 0.33, 1 } or { 0.30, 0.32, 0.35, 1 }
    local rem = (v ~= nil and self.remoteFns ~= nil) and self:remoteFns(v) or {}
    local i = math.max(1, math.min(5, M.vSel or 1))
    f.txt(600, 32, 24, T("df_valves") .. "  " .. i, c, nil, 380, true)
    f.rgt(1525, 32, 20, T("df_valveHint2"), dim(self), 520)
    -- choix du distributeur : appui sur une colonne
    for n, cx in ipairs(M.VX) do
        local fn1 = (rem[n] or {})[1]
        f.ctr(cx, 500, 15, fn1 ~= nil and self:remoteShort(fn1) or ("-- " .. n .. " --"), c, 124, fn1 ~= nil)
        if n == i then f.rect(cx - 50, 798, 100, 6, GRN) end
        f.hot(cx - 66, 480, cx + 66, 796, "dfv_sel_" .. n)
    end
    -- panneau du haut (sur les réglages hydrauliques de son écran) : les 3 fonctions, puis la liste
    f.rect(480, 68, 1062, 384, card)
    f.rect(480, 68, 1062, 8, M.VCOL[i])
    local fns = rem[i] or {}
    local m = self.remoteMenu
    for k = 1, (self.REMOTE_SLOTS or 3) do
        local y = 92 + (k - 1) * 84
        local open = m ~= nil and m.i == i and m.k == k
        f.rect(496, y, 460, 70, open and GRN or (dark and { 0.22, 0.23, 0.25, 1 } or WH))
        f.ctr(526, y + 35, 26, tostring(k), open and WH or dim(self), 40, true)
        local fn = fns[k]
        f.txt(560, y + 35, 20, fn ~= nil and self:remoteLabel(fn) or ((k <= #fns + 1) and "+" or ""), open and WH or c, nil, 390, fn ~= nil)
        if k <= #fns + 1 then f.hot(496, y, 956, y + 70, "rfn_" .. i .. "_" .. k) end
    end
    if #fns > 0 then
        f.rect(496, 352, 460, 80, BLUE)
        f.ctr(726, 392, 24, T("c_apply"), WH, 440, true)
        f.hot(496, 352, 956, 432, "rem_" .. i)
    end
    if m ~= nil and m.i == i then
        local heads = { { T("c_colF"), "@f" }, { T("c_colR"), "@r" }, { T("c_colB"), "" } }
        local x0, y0, cw, rh = 972, 84, 184, 33
        local cur = fns[m.k] or "none"
        for col, hd in ipairs(heads) do
            local cx = x0 + (col - 1) * (cw + 4)
            f.rect(cx, y0, cw, rh, head)
            f.ctr(cx + cw * 0.5, y0 + rh * 0.5, 16, hd[1], WH, cw - 10, true)
            for j = 2, #self.REMOTE_FNS do
                local fn = self.REMOTE_FNS[j] .. hd[2]
                local ry = y0 + (j - 1) * rh + 1
                local on = cur == fn
                f.rect(cx, ry, cw, rh - 2, on and GRN or (dark and { 0.22, 0.23, 0.25, 1 } or WH))
                f.txt(cx + 6, ry + rh * 0.5, 13, self:remoteLabel(fn, true), on and WH or c, nil, cw - 10)
                f.hot(cx, ry, cx + cw, ry + rh - 2, "rsel_" .. m.i .. "_" .. m.k .. "_" .. fn)
            end
        end
        local ny = y0 + #self.REMOTE_FNS * rh + 2
        f.rect(x0, ny, cw * 3 + 8, rh - 2, cur == "none" and GRN or (dark and { 0.22, 0.23, 0.25, 1 } or WH))
        f.ctr(x0 + (cw * 3 + 8) * 0.5, ny + rh * 0.5, 15, T("none"), cur == "none" and WH or c, cw * 3)
        f.hot(x0, ny, x0 + cw * 3 + 8, ny + rh - 2, "rsel_" .. m.i .. "_" .. m.k .. "_none")
    else
        f.txt(980, 150, 18, T("fd_remHint1"), dim(self), nil, 540)
        f.txt(980, 190, 18, T("fd_remHint2"), dim(self), nil, 540)
    end
    M.chassis(self, d, f, ctx, v, "dfrem")
end

-------------------------------------------------------------------------------
-- 05 ASM (gestion auto 4 roues motrices + blocage de différentiel) : seuils d'angle de braquage et de vitesse,
-- comparés en direct à l'angle et à la vitesse du tracteur ; le bouton ASM met la gestion en marche / à l'arrêt
-------------------------------------------------------------------------------
M.ASM = { awdAng = 25, awdSpd = 20, difAng = 10, difSpd = 15 }
M.asmOn = {}
local function steerPct(v)
    if v == nil then return 0 end
    local rt, mx = tonumber(v.rotatedTime) or 0, tonumber(v.maxRotTime) or 0
    if mx <= 0 then mx = math.abs(tonumber(v.minRotTime) or 0) end
    if mx <= 0 then return 0 end
    return math.min(1, math.abs(rt) / mx)
end
M.MAXANG = 40   -- angle de braquage maxi affiché (degrés)
function M.asm(self, d, ctx, v, Wp, Hp)
    local f = frame(self, ctx, Wp, Hp)
    f.img(0, 0, 1672, 941, "as_df_asm" .. sfx(self))
    local c = ink(self)
    local dark = M.isDark(self)
    local on = M.asmOn[v] ~= false
    local ang = steerPct(v) * M.MAXANG
    local kmh = d.speed or 0
    local sv, su = spd(kmh)
    local A = M.ASM
    f.txt(600, 32, 24, "ASM", c, nil, 360, true)
    f.rgt(1525, 32, 20, on and T("df_asmOn") or T("df_asmOff"), on and GRN or dim(self), 520, true)
    local track = dark and { 0.30, 0.31, 0.33, 1 } or { 0.80, 0.81, 0.83, 1 }
    local function bar(y, val, lim, max, label, unitTxt)
        local x0, x1 = 840, 1345
        local w = x1 - x0
        f.rect(x0, y + 4, w, 14, track)
        local p = math.max(0, math.min(1, val / max))
        f.rect(x0, y + 4, w * p, 14, val <= lim and GRN or { 0.90, 0.20, 0.15, 1 })
        f.rect(x0 + w * (lim / max) - 2, y - 2, 4, 26, c)
        f.txt(x0, y - 12, 18, label, c, nil, 330)
        f.rgt(x1, y - 12, 18, unitTxt, c, 200, true)
    end
    bar(137, ang, A.awdAng, M.MAXANG, T("df_asmAngle") .. " < " .. A.awdAng .. "°", dec(ang, 0) .. "°")
    bar(265, kmh, A.awdSpd, 40, T("df_asmSpeed") .. " < " .. dec(select(1, spd(A.awdSpd)), 0) .. " " .. su, dec(sv, 1) .. " " .. su)
    bar(404, ang, A.difAng, M.MAXANG, T("df_asmAngle") .. " < " .. A.difAng .. "°", dec(ang, 0) .. "°")
    bar(518, kmh, A.difSpd, 40, T("df_asmSpeed") .. " < " .. dec(select(1, spd(A.difSpd)), 0) .. " " .. su, dec(sv, 1) .. " " .. su)
    -- état calculé : 4RM et blocage engagés tant que l'angle et la vitesse restent sous les seuils
    local awd = on and ang <= A.awdAng and kmh <= A.awdSpd
    local dif = on and ang <= A.difAng and kmh <= A.difSpd
    f.ctr(602, 690, 18, T("df_asm4wd"), awd and GRN or dim(self), 200, true)
    f.ctr(842, 690, 18, T("df_asmDiff"), dif and GRN or dim(self), 200, true)
    if not awd then f.rect(540, 600, 125, 80, offCol(self)) end
    if not dif then f.rect(785, 596, 115, 84, offCol(self)) end
    f.ctr(1150, 640, 28, on and "ON" or "OFF", on and GRN or dim(self), 200, true)
    f.hot(1415, 595, 1515, 690, "dfasm")
    -- braquage en direct
    local st = steerPct(v)
    f.rect(830, 766, 525, 14, track)
    local mid = 830 + 525 * 0.5
    local sgn = (tonumber(v ~= nil and v.rotatedTime) or 0) >= 0 and -1 or 1
    if sgn < 0 then f.rect(mid - 262.5 * st, 766, 262.5 * st, 14, BLUE) else f.rect(mid, 766, 262.5 * st, 14, BLUE) end
    f.rect(mid - 2, 760, 4, 26, c)
    f.txt(840, 746, 18, T("df_asmSteer"), c, nil, 300)
    f.rgt(1345, 746, 18, dec(ang, 0) .. "°", c, 200, true)
    M.chassis(self, d, f, ctx, v, "dfasm")
end

-------------------------------------------------------------------------------
-- 06 ComfortTip (séquences de bout de champ) : 4 séquences par tracteur (entrée / sortie, AR puis AV),
-- mêmes séquences que le TI du Fendt (réglage du tracteur « ti ») ; jusqu'à 3 étapes par séquence
-------------------------------------------------------------------------------
M.ctSeq, M.ctStep, M.ctSide = 1, 1, "@r"
M.SLOTX = { { 592, 768 }, { 790, 972 }, { 995, 1192 }, { 1218, 1414 } }
local function ctName(n) return T((n % 2 == 1) and "df_ctIn" or "df_ctOut") .. " " .. ((n <= 2) and T("c_colR") or T("c_colF")) end
local function F() return AS_TerminalFendt end
function M.ct(self, d, ctx, v, Wp, Hp)
    local f = frame(self, ctx, Wp, Hp)
    f.img(0, 0, 1672, 941, "as_df_ct" .. sfx(self))
    local dark = M.isDark(self)
    local c = ink(self)
    local t = (v ~= nil and F() ~= nil) and F().tiFns(self, v) or { {}, {}, {}, {} }
    local n = math.max(1, math.min(4, M.ctSeq or 1))
    local fns = t[n] or {}
    local maxS = self.REMOTE_SLOTS or 3
    f.txt(570, 32, 24, "ComfortTip", c, nil, 400, true)
    f.rgt(1525, 32, 20, n .. " / 4", dim(self), 300)
    -- nom de la séquence (appui : suivante)
    f.ctr(1000, 130, 24, ctName(n), c, 560, true)
    f.hot(675, 95, 1365, 165, "dfct_seq")
    f.hot(527, 88, 617, 178, "dfct_def")
    f.hot(1398, 84, 1492, 176, "dfct_run")
    f.hot(488, 218, 553, 452, "dfct_prev"); f.hot(1462, 218, 1530, 452, "dfct_next")
    -- étapes : 8 cases, les 3 premières utilisables
    local slotOn = dark and { 0.22, 0.23, 0.25, 1 } or WH
    local slotOff = dark and { 0.16, 0.16, 0.17, 1 } or { 0.50, 0.51, 0.52, 1 }
    local sel = math.max(1, math.min(maxS, M.ctStep or 1))
    for k = 1, 8 do
        local col, row = (k - 1) % 4 + 1, (k <= 4) and 1 or 2
        local x0, x1 = M.SLOTX[col][1], M.SLOTX[col][2]
        local y0, y1 = (row == 1) and 218 or 360, (row == 1) and 342 or 448
        local usable = k <= maxS
        local fn = fns[k]
        if usable and k == sel then f.rect(x0 - 4, y0 - 4, x1 - x0 + 8, y1 - y0 + 8, BLUE) end
        f.rect(x0, y0, x1 - x0, y1 - y0, (usable and (fn ~= nil or k == #fns + 1)) and slotOn or slotOff)
        if usable then
            f.ctr((x0 + x1) * 0.5, y0 + 20, 20, tostring(k), (fn ~= nil or k == #fns + 1) and c or WH, 40, true)
            if fn ~= nil then
                f.ctr((x0 + x1) * 0.5, y0 + 75, 16, self:remoteLabel(fn), c, x1 - x0 - 12, true)
            elseif k == #fns + 1 then
                f.ctr((x0 + x1) * 0.5, y0 + 75, 30, "+", dim(self), 60, true)
            end
            if k <= #fns + 1 then f.hot(x0, y0, x1, y1, "dfct_step_" .. k) end
        end
    end
    f.hot(600, 465, 688, 545, "dfct_left"); f.hot(836, 465, 922, 545, "dfct_right")
    f.hot(1062, 465, 1148, 545, "dfct_add"); f.hot(1314, 465, 1400, 545, "dfct_del")
    if #fns < 1 or sel == 1 then f.rect(600, 468, 88, 74, offCol(self)) end
    if sel >= #fns then f.rect(836, 468, 88, 74, offCol(self)) end
    if #fns >= maxS then f.rect(1062, 468, 88, 74, offCol(self)) end
    if fns[sel] == nil then f.rect(1314, 468, 88, 74, offCol(self)) end
    -- choix de la fonction de l'étape choisie : côté (AV | AR | Les deux) puis fonction
    local head = dark and { 0.28, 0.30, 0.33, 1 } or { 0.30, 0.32, 0.35, 1 }
    local sides = { { T("c_colF"), "@f" }, { T("c_colR"), "@r" }, { T("c_colB"), "" } }
    for i, sd in ipairs(sides) do
        local x0 = 520 + (i - 1) * 290
        local on = M.ctSide == sd[2]
        f.rect(x0, 574, 282, 40, on and GRN or head)
        f.ctr(x0 + 141, 594, 18, sd[1], WH, 270, true)
        f.hot(x0, 574, x0 + 282, 614, "dfct_side_" .. i)
    end
    local cur = fns[sel]
    for j = 2, #self.REMOTE_FNS do
        local i = j - 2
        local cx, cy = 520 + (i % 5) * 174, 624 + math.floor(i / 5) * 104
        local fn = self.REMOTE_FNS[j] .. M.ctSide
        local on = cur == fn
        f.rect(cx, cy, 166, 96, on and GRN or slotOn)
        f.ctr(cx + 83, cy + 48, 18, self:remoteLabel(fn, true), on and WH or c, 154, on)
        f.hot(cx, cy, cx + 166, cy + 96, "dfct_fn_" .. fn)
    end
    f.hot(1405, 570, 1495, 660, "dfct_x")
    local last = F() ~= nil and F().tiLast or nil
    if last ~= nil and last.n == n and (g_time or 0) - last.at < 1500 then
        f.rect(1398, 84, 94, 92, { 0.10, 0.85, 0.10, 0.45 })
    end
    M.chassis(self, d, f, ctx, v, "dfct")
end
function M.ctAction(self, a)
    local v = (self.data or {}).vehicle
    if v == nil or F() == nil then return end
    local t = F().tiFns(self, v)
    local n = math.max(1, math.min(4, M.ctSeq or 1))
    local fns = t[n]
    local maxS = self.REMOTE_SLOTS or 3
    local sel = math.max(1, math.min(maxS, M.ctStep or 1))
    local store = false
    if a == "dfct_seq" or a == "dfct_next" then M.ctSeq = n % 4 + 1; M.ctStep = 1
    elseif a == "dfct_prev" then M.ctSeq = (n + 2) % 4 + 1; M.ctStep = 1
    elseif a == "dfct_run" then F().tiAction(self, "fdti_run_" .. n)
    elseif a == "dfct_def" then F().tiSel = n; F().tiAction(self, "fdti_def"); M.ctStep = 1
    elseif a:sub(1, 10) == "dfct_step_" then M.ctStep = tonumber(a:sub(11)) or 1
    elseif a:sub(1, 10) == "dfct_side_" then M.ctSide = ({ "@f", "@r", "" })[tonumber(a:sub(11)) or 2] or "@r"
    elseif a:sub(1, 8) == "dfct_fn_" then
        local fn = a:sub(9)
        if sel <= #fns then fns[sel] = fn elseif #fns < maxS then fns[#fns + 1] = fn; M.ctStep = #fns end
        store = true
    elseif a == "dfct_add" then if #fns < maxS then M.ctStep = #fns + 1 end
    elseif a == "dfct_del" or a == "dfct_x" then
        if fns[sel] ~= nil then table.remove(fns, sel); store = true end
        M.ctStep = math.max(1, math.min(sel, #fns + 1))
    elseif a == "dfct_left" and sel > 1 and fns[sel] ~= nil then
        fns[sel], fns[sel - 1] = fns[sel - 1], fns[sel]; M.ctStep = sel - 1; store = true
    elseif a == "dfct_right" and fns[sel + 1] ~= nil then
        fns[sel], fns[sel + 1] = fns[sel + 1], fns[sel]; M.ctStep = sel + 1; store = true
    end
    if store then F().tiStore(self, v, t) end
    self.lastRead = -100000
end

-------------------------------------------------------------------------------
-- 07 Configurations : les réglages du terminal en liste iMonitor (ligne choisie en bleu, détail en bas)
-------------------------------------------------------------------------------
M.cfgSel, M.cfgTop, M.CFG_ROWS = 1, 1, 5
M.CFG_BTN = { { 125, "setHome", "setHome" }, { 222, "resetSize", "resetSize" }, { 322, "change", nil }, { 468, "setSub", "setTab" }, { 565, "resetPos", "resetPos" } }
function M.config(self, d, ctx, v, Wp, Hp, inside)
    local f = frame(self, ctx, Wp, Hp)
    f.img(0, 0, 1672, 941, "as_df_cfg" .. sfx(self))
    local dark = M.isDark(self)
    local c = ink(self)
    local items, tabPage, homePage = self:setItems(d, inside or false, v)
    local n = #items
    M.cfgSel = math.max(1, math.min(n, M.cfgSel or 1))
    if M.cfgSel < M.cfgTop then M.cfgTop = M.cfgSel end
    if M.cfgSel > M.cfgTop + M.CFG_ROWS - 1 then M.cfgTop = M.cfgSel - M.CFG_ROWS + 1 end
    M.cfgTop = math.max(1, math.min(math.max(1, n - M.CFG_ROWS + 1), M.cfgTop))
    local title = tabPage and T("setTab") or (homePage and T("setHome") or T("df_config"))
    f.txt(570, 32, 24, title, c, nil, 400, true)
    f.rgt(1525, 32, 20, M.cfgSel .. " / " .. n, dim(self), 300)
    local selC = { 0.35, 0.69, 0.98, 1 }
    local alt = dark and { 0.17, 0.17, 0.18, 1 } or { 0.82, 0.82, 0.83, 1 }
    local base = dark and { 0.10, 0.10, 0.11, 1 } or { 0.93, 0.93, 0.93, 1 }
    for r = 1, M.CFG_ROWS do
        local i = M.cfgTop + r - 1
        local it = items[i]
        if it == nil then break end
        local y0 = 147 + (r - 1) * 74
        local on = i == M.cfgSel
        f.rect(500, y0, 850, 72, on and selC or ((r % 2 == 0) and alt or base))
        f.txt(520, y0 + 36, 20, it[1], on and WH or c, nil, 470, on)
        f.rgt(1330, y0 + 36, 20, it[2] or "", on and WH or c, 330, true)
        f.hot(500, y0, 1350, y0 + 72, "dfcfg_row_" .. i)
    end
    f.hot(503, 88, 1347, 130, "dfcfg_up"); f.hot(503, 585, 1347, 625, "dfcfg_dn")
    if M.cfgSel <= 1 then f.rect(503, 88, 844, 42, offCol(self)) end
    if M.cfgSel >= n then f.rect(503, 585, 844, 40, offCol(self)) end
    -- détail de la ligne choisie : libellé, valeur, - / + ou CHANGER
    local it = items[M.cfgSel] or {}
    f.txt(520, 690, 20, it[1] or "", dim(self), nil, 560)
    f.txt(520, 750, 30, it[2] or "", c, nil, 560, true)
    if it[3] ~= nil then
        f.rect(1110, 680, 100, 90, BLUE); f.ctr(1160, 725, 40, "-", WH, 80, true); f.hot(1110, 680, 1210, 770, it[3])
        f.rect(1225, 680, 110, 90, BLUE); f.ctr(1280, 725, 40, "+", WH, 80, true); f.hot(1225, 680, 1335, 770, it[4])
    elseif it[4] ~= nil then
        f.rect(1110, 680, 225, 90, BLUE); f.ctr(1222, 725, 20, T("change"), WH, 210, true); f.hot(1110, 680, 1335, 770, it[4])
    end
    -- boutons ronds de droite (nom écrit dessous) ; export / import USB absents du jeu
    for _, b in ipairs(M.CFG_BTN) do
        local y, a, lab = b[1], b[2], b[3]
        if a == "change" then a = it[4] end
        local active = (a == "setSub" and tabPage) or (a == "setHome" and homePage)
        local txt = lab ~= nil and T(lab) or T("change")
        if active then txt = T("setMain") end
        f.ctr(1452, y + 52, 11, txt, active and BLUE or c, 150, true)
        if a ~= nil then f.hot(1410, y - 44, 1495, y + 44, a) else f.rect(1408, y - 44, 90, 88, offCol(self)) end
    end
    f.rect(1408, 631, 90, 88, offCol(self)); f.rect(1408, 721, 90, 88, offCol(self))
    M.chassis(self, d, f, ctx, v, "set")
end

-------------------------------------------------------------------------------
-- (06/11) colonne Courseplay
-- sur la carte, style iMonitor (même logique que la colonne du Case et le Guide du Fendt)
-------------------------------------------------------------------------------
local function cpCall(v, fn)
    if v == nil or v[fn] == nil then return nil end
    local ok, r = pcall(v[fn], v)
    return ok and r or nil
end
local function stS(st)
    if st == nil or st.getString == nil then return "-" end
    local ok, r = pcall(st.getString, st)
    return ok and tostring(r) or "-"
end
function M.cpColumn(self, d, f, v, X0, Y0, X1)
    local g = d.gps or {}
    local dark = M.isDark(self)
    local W = X1 - X0
    local bg = dark and { 0.08, 0.08, 0.09, 1 } or { 0.93, 0.93, 0.94, 1 }
    local bd = dark and { 0.85, 0.85, 0.86, 1 } or { 0.30, 0.31, 0.33, 1 }
    local btn = dark and { 0.20, 0.21, 0.23, 1 } or WH
    local c = ink(self)
    f.rect(X0, Y0, W, 812 - Y0 - 4, bg)
    f.rect(X0, Y0, 3, 812 - Y0 - 4, bd)
    local M0 = 14
    local bx, bw = X0 + M0, W - 2 * M0
    local function B(y, h, label, act, col, x, w, size)
        x, w = x or bx, w or bw
        f.rect(x, y, w, h, bd)
        f.rect(x + 2, y + 2, w - 4, h - 4, col or btn)
        f.ctr(x + w * 0.5, y + h * 0.5, size or 18, label, col ~= nil and WH or c, w - 12, true)
        if act ~= nil then f.hot(x, y, x + w, y + h, act) end
    end
    local function L(y, txt, size) f.ctr(X0 + W * 0.5, y, size or 15, txt, dim(self), W - 16) end
    -- (13/11) sans Courseplay : ni titre ni message, FarmPilot reste en bas s'il est là
    local uiI = AS_Terminal.ui
    local cpInst = uiI == nil or uiI.cpInstalled == nil or uiI.cpInstalled()
    local fpInst = uiI == nil or uiI.fpInstalled == nil or uiI.fpInstalled()
    local function fpButton()
        local fpOk = AS_TerminalFp ~= nil and AS_TerminalFp.available ~= nil and AS_TerminalFp:available(v) == true
        if fpOk or fpInst then B(736, 60, "FarmPilot", fpOk and "page_fp" or nil, nil, nil, nil, 18) end
        if not fpOk then f.rect(bx, 736, bw, 60, offCol(self)) end
    end
    if cpInst then
        f.ctr(X0 + W * 0.5, Y0 + 22, 20, "COURSEPLAY", c, W - 16, true)
        f.rect(bx, Y0 + 40, bw, 3, GRN)
    end
    if g.hasCp ~= true then
        if cpInst then L(Y0 + 120, T("cpMissing"), 17) end
        fpButton()
        return
    end
    local sw = 56
    local mw = bw - 2 * (sw + 8)
    local function trio(y, mid, aL, aR, aMid)
        B(y, 52, "-", aL, nil, bx, sw, 26)
        B(y, 52, mid, aMid, nil, bx + sw + 8, mw, 17)
        B(y, 52, "+", aR, nil, bx + sw + 8 + mw + 8, sw, 26)
    end
    local y = Y0 + 58
    if g.data ~= nil then
        local active = g.active == true
        local lost = not active and AS_TerminalGps ~= nil and AS_TerminalGps.rtkLost ~= nil and AS_TerminalGps:rtkLost(v)
        B(y, 64, active and T("cpStop") or T("cpGo"), "gps_steer", active and { 0.75, 0.13, 0.10, 1 } or (lost and { 0.40, 0.40, 0.42, 1 } or { 0.10, 0.60, 0.15, 1 }), nil, nil, 22)
        y = y + 88; L(y, T("cpStart"))
        B(y + 12, 52, stS(cpCall(v, "getCpStartingPointSetting")), "cp_start")
        y = y + 88; L(y, T("c_cpSave"))
        B(y + 12, 52, self.cpCourseName ~= nil and self:cpCourseName(v, d) or "-", "cp_save", nil, nil, nil, 16)
        y = y + 88; L(y, T("gps_offset"))
        trio(y + 12, g.offset ~= nil and (string.format("%+.2f m", g.offset)) or "-", "gps_shiftL", "gps_shiftR", "gps_off0")
        y = y + 88
        B(y, 52, T("c_cpReset"), "cp_clear")
        local state = active and T("cpActive") or (lost and T("gps_noRtk") or (g.canStart and T("cpReady") or T("cpNotReady")))
        f.ctr(X0 + W * 0.5, y + 86, 17, state, active and GRN or c, W - 16, true)
        if g.rows ~= nil then L(y + 114, string.format(T("gps_courseInfo"), g.rows or 0, g.nHl or 0, (g.data.length or 0) / 1000), 13) end
    else
        B(y, 64, T("cpGenerate"), "cp_cgui", { 0.10, 0.60, 0.15, 1 }, nil, nil, 20)
        y = y + 76; B(y, 58, T("cpFind"), "cp_find")
        y = y + 70; B(y, 58, T("cpLoadSave"), "cp_saves", nil, nil, nil, 16)
        y = y + 94; L(y, T("cpWidth"))
        local cs = cpCall(v, "getCourseGeneratorSettings")
        trio(y + 12, cs ~= nil and stS(cs.workWidth) or "-", "cp_w-", "cp_w+")
        y = y + 88; L(y, T("cpHeadlands"))
        trio(y + 12, cs ~= nil and stS(cs.numberOfHeadlands) or "-", "cp_h-", "cp_h+")
        f.ctr(X0 + W * 0.5, y + 110, 17, T("cpNoCourse"), c, W - 16, true)
    end
    -- FarmPilot (s'il est installé) en bas de la colonne
    fpButton()
end

-- (06/11) parcours enregistrés pour ce champ, sur la carte
-- (recherche auto comme la page GUIDAGE, CHERCHER TRAVAIL la relance) ; un appui sur une ligne charge le parcours
function M.findList(self, d, f, v)
    local R = AS_TerminalCourses
    if R == nil then return end
    pcall(R.auto, R, v, d)
    local r = R.results
    local busy = R.job ~= nil and R.job.vehicle == v and not R.job.done
    if (r == nil or r.vehicle ~= v) and not busy then return end
    local dark = M.isDark(self)
    local c = ink(self)
    local bg = dark and { 0.10, 0.10, 0.11, 1 } or { 0.96, 0.96, 0.97, 1 }
    local alt = dark and { 0.17, 0.17, 0.18, 1 } or { 0.86, 0.86, 0.87, 1 }
    local x0, x1, y0 = 130, 1260, 100
    local list = (r ~= nil and r.vehicle == v and r.msg == nil) and r.list or {}
    local n = math.min(#list, R.SHOWN or 6, 6)
    local h = 70 + math.max(1, n) * 62
    f.rect(x0 - 2, y0 - 2, x1 - x0 + 4, h + 4, { 0.35, 0.69, 0.98, 1 })
    f.rect(x0, y0, x1 - x0, h, bg)
    if r == nil or r.vehicle ~= v then
        f.ctr((x0 + x1) * 0.5, y0 + 34, 20, T("cpFindBusy"), dim(self), x1 - x0 - 30)
        f.ctr((x0 + x1) * 0.5, y0 + 100, 18, "...", c, 200)
        return
    end
    local fieldTxt = tostring(r.field or "-")
    if r.linkedTxt ~= nil then fieldTxt = fieldTxt .. " (+" .. r.linkedTxt .. ")" end
    f.txt(x0 + 18, y0 + 34, 18, string.format(T("cpFindHead"), fieldTxt, r.width ~= nil and string.format("%.1f m", r.width) or "-"), c, nil, x1 - x0 - 36, true)
    if r.msg ~= nil or n == 0 then
        f.ctr((x0 + x1) * 0.5, y0 + 100, 20, r.msg or T("cpSavesNone"), { 0.90, 0.55, 0.05, 1 }, x1 - x0 - 30, true)
        return
    end
    for i = 1, n do
        local e = list[i]
        local yy = y0 + 66 + (i - 1) * 62
        local on = r.loaded == i
        f.rect(x0 + 10, yy, x1 - x0 - 20, 58, on and { 0.35, 0.69, 0.98, 1 } or ((i % 2 == 0) and alt or bg))
        local col = on and WH or c
        local label = (e.dir ~= nil and e.dir ~= "" and (e.dir .. "  -  ") or "") .. tostring(e.fname)
        f.txt(x0 + 26, yy + 29, 18, label, col, nil, 600, true)
        local right = string.format("%s   %s   %s", string.format(T("cpFindField"), e.fieldTxt or "-"),
            e.w ~= nil and string.format("%.1f m", e.w) or "-", e.h ~= nil and string.format(T("cpFindHl"), e.h) or "")
        f.rgt(x1 - 80, yy + 29, 16, right, on and WH or (e.ok and GRN or dim(self)), 420)
        if e.ok then f.rgt(x1 - 24, yy + 29, 18, "OK", on and WH or GRN, 50, true) end
        f.hot(x0 + 10, yy, x1 - 10, yy + 58, "cp_load" .. i)
    end
end

-------------------------------------------------------------------------------
-- 08 Guidage carte : la carte en direct sur tout l'écran, barre d'outils en haut et à droite (nom écrit dessous)
-------------------------------------------------------------------------------
M.MAP_TOP = { { 948, nil, "df_mPan" }, { 1045, "gps_course", "df_mLines" }, { 1143, "gps_view", "df_mView" }, { 1240, nil, "df_mLayers" },
    { 1338, nil, "df_mField" }, { 1432, "gps_zoomOut", "df_mZoomOut" }, { 1520, "gps_zoomIn", "df_mZoomIn" } }
function M.guideMap(self, d, ctx, v, Wp, Hp, inside)
    local G = AS_TerminalGps
    if G ~= nil and G.sub == "course" then return M.page(self, d, ctx, v, Wp, Hp, inside) end
    local f = frame(self, ctx, Wp, Hp)
    local g = d.gps or {}
    f.img(0, 0, 1672, 941, "as_df_map" .. sfx(self))
    liveMap(self, d, ctx, v, f, 106, 86, 1284, 816, (G ~= nil and G.view) or "top")
    M.cpColumn(self, d, f, v, 1284, 86, 1564)
    if g.hasCp and g.data == nil then M.findList(self, d, f, v) end
    local lab = { 0.85, 0.85, 0.86, 1 }
    for _, b in ipairs(M.MAP_TOP) do
        f.ctr(b[1], 76, 11, T(b[3]), lab, 96)
        if b[2] ~= nil then f.hot(b[1] - 46, 0, b[1] + 46, 84, b[2]) else f.rect(b[1] - 40, 4, 80, 64, { 0, 0, 0, 0.62 }) end
    end
    -- enregistrer le bord du champ
    f.hot(1568, 0, 1670, 84, "gps_rec")
    if g.recording then f.rect(1578, 74, 80, 6, { 0.90, 0.15, 0.10, 1 }) end
    -- colonne de droite : parcours, voie, menu Courseplay, direction auto, décalage (moitié gauche / droite)
    local c = ink(self)
    local R = { { 130, "gps_course", "df_mCourse" }, { 215, "gps_lane", "df_mLane" }, { 300, "cp_menu", "df_mCp" }, { 390, "gps_steer", "df_mSteer" } }
    for _, b in ipairs(R) do
        f.ctr(1617, b[1] + 34, 11, T(b[3]), c, 96, true)
        f.hot(1568, b[1] - 42, 1668, b[1] + 42, b[2])
    end
    if g.steer == "on" or g.active then f.rect(1570, 350, 6, 80, GRN) end
    f.ctr(1617, 509, 11, T("gps_shift") .. " " .. ((g.offset ~= nil and string.format("%+.1f m", g.offset)) or "0"), c, 100, true)
    f.hot(1568, 433, 1617, 517, "gps_shiftL"); f.hot(1617, 433, 1668, 517, "gps_shiftR")
    if g.offsetDisabled then f.rect(1570, 436, 96, 80, offCol(self)) end
    M.chassis(self, d, f, ctx, v, "gps")
end

-------------------------------------------------------------------------------
-- 09 Tronçons (Section Control) sur la carte : rampe des tronçons en haut (vert = pulvérise, jaune = prêt,
-- blanc = coupé), rond vert = SC automatique, case du bas = état et tronçons ouverts
-------------------------------------------------------------------------------
M.MAP_TOP_SC = { { 920, nil, "df_mPan" }, { 1015, "gps_course", "df_mLines" }, { 1110, "gps_view", "df_mView" }, { 1205, nil, "df_mLayers" },
    { 1308, nil, "df_mField" }, { 1405, "gps_zoomOut", "df_mZoomOut" }, { 1503, "gps_zoomIn", "df_mZoomIn" } }
local function scSegments(v)
    local SC = AS_SectionControl
    if SC == nil or v == nil then return {} end
    local ok, segs = pcall(SC.bar, SC, v)
    if not ok or type(segs) ~= "table" then return {} end
    -- de gauche à droite vu du siège
    if v.rootNode ~= nil and worldToLocal ~= nil then
        for _, e in ipairs(segs) do
            local okL, lx = pcall(worldToLocal, v.rootNode, (e.x1 + e.x2) * 0.5, 0, (e.z1 + e.z2) * 0.5)
            e.lat = okL and lx or 0
        end
        table.sort(segs, function(a, b) return (a.lat or 0) > (b.lat or 0) end)
    end
    return segs
end
function M.scMap(self, d, ctx, v, Wp, Hp, inside)
    local G = AS_TerminalGps
    -- (06/11) la sous-page « parcours » du guidage ne concerne pas les tronçons (sinon page blanche)
    local f = frame(self, ctx, Wp, Hp)
    local g = d.gps or {}
    local c = ink(self)
    f.img(0, 0, 1672, 941, "as_df_sc" .. sfx(self))
    liveMap(self, d, ctx, v, f, 106, 86, 1564, 816, (G ~= nil and G.view) or "top")
    for _, b in ipairs(M.MAP_TOP_SC) do
        f.ctr(b[1], 76, 11, T(b[3]), c, 92)
        if b[2] ~= nil then f.hot(b[1] - 46, 0, b[1] + 46, 84, b[2]) else f.rect(b[1] - 40, 4, 80, 64, offCol(self)) end
    end
    -- rampe des tronçons
    local segs = scSegments(v)
    local x0, x1, y0, y1 = 484, 856, 44, 66
    if #segs == 0 then
        f.rect(x0, y0, x1 - x0, y1 - y0, M.isDark(self) and { 0.25, 0.25, 0.27, 1 } or { 0.80, 0.80, 0.82, 1 })
        f.ctr((x0 + x1) * 0.5, 28, 15, T("mf_scNone"), dim(self), x1 - x0 - 10)
    else
        local w = (x1 - x0) / #segs
        local nOn = 0
        for i, e in ipairs(segs) do
            local col = e.state == "on" and GRN or (e.state == "ready" and { 0.98, 0.80, 0.10, 1 } or WH)
            if e.state ~= "off" then nOn = nOn + 1 end
            f.rect(x0 + (i - 1) * w + 1, y0, w - 2, y1 - y0, col)
        end
        f.ctr((x0 + x1) * 0.5, 28, 15, nOn .. " / " .. #segs, c, 200, true)
    end
    -- SC automatique (rond vert) et case d'état
    local SC = AS_SectionControl
    local auto = SC ~= nil and v ~= nil and (SC:cfg(v).auto or 0) == 1
    if not auto then f.rect(1580, 6, 76, 72, offCol(self)) end
    f.ctr(1617, 76, 11, "SC " .. (auto and "AUTO" or "MANU"), auto and GRN or c, 96, true)
    f.hot(1568, 0, 1670, 84, "dfsc_auto")
    -- colonne de droite : comme le guidage
    local R = { { 130, "gps_course", "df_mCourse" }, { 215, "gps_lane", "df_mLane" }, { 300, "cp_menu", "df_mCp" }, { 390, "gps_steer", "df_mSteer" } }
    for _, b in ipairs(R) do
        f.ctr(1617, b[1] + 34, 11, T(b[3]), c, 96, true)
        f.hot(1568, b[1] - 42, 1668, b[1] + 42, b[2])
    end
    if g.steer == "on" or g.active then f.rect(1570, 350, 6, 80, GRN) end
    f.ctr(1617, 509, 11, T("gps_shift") .. " " .. ((g.offset ~= nil and string.format("%+.1f m", g.offset)) or "0"), c, 100, true)
    f.hot(1568, 433, 1617, 517, "gps_shiftL"); f.hot(1617, 433, 1668, 517, "gps_shiftR")
    if g.offsetDisabled then f.rect(1570, 436, 96, 80, offCol(self)) end
    M.chassis(self, d, f, ctx, v, "dfsc")
end

-------------------------------------------------------------------------------
-- 10 Menu des paramètres : chaque tuile ouvre sa page (nom + état en direct) ; icônes du bas = raccourcis
-------------------------------------------------------------------------------
M.MENU_L = { { 84, 166 }, { 176, 244 }, { 256, 326 }, { 336, 406 }, { 416, 486 }, { 496, 566 } }
function M.menu(self, d, ctx, v, Wp, Hp)
    local f = frame(self, ctx, Wp, Hp)
    f.img(0, 0, 1672, 941, "as_df_menu" .. sfx(self))
    local c = ink(self)
    local SC = AS_SectionControl
    local auto = SC ~= nil and v ~= nil and (SC:cfg(v).auto or 0) == 1
    local cnt = d.cnt
    local ha = 0
    if cnt ~= nil and cnt.jobs ~= nil then
        local j = cnt.jobs[cnt.active or 1]
        if j ~= nil then ha = tonumber(j.area or j.ha or 0) or 0 end
    end
    local hs = H().caseHitches ~= nil and H().caseHitches(v) or nil
    local tool = d.toolName or (d.tools ~= nil and d.tools[1] ~= nil and d.tools[1].name) or nil
    local s = self.settings
    local tiles = {
        { 1, "Section Control", auto and "AUTO" or "MANU", "page_dfsc" },
        { 2, T("df_mnWork"), "", "page_work" },
        { 3, T("df_mnTool"), tool or "--", "page_tool" },
        { 4, T("df_mnCount"), dec(ha, 2) .. " ha", "page_count" },
        { 5, T("df_hitchR"), "", "page_dfhitchr" },
        { 6, T("touchStopped"), s.touchStopped and T("yes") or T("no"), "touchStopped" },
    }
    for _, t in ipairs(tiles) do
        local y0, y1 = M.MENU_L[t[1]][1], M.MENU_L[t[1]][2]
        f.txt(270, (y0 + y1) * 0.5, 22, t[2], c, nil, 330, true)
        f.rgt(800, (y0 + y1) * 0.5, 20, t[3], t[4] == "page_dfsc" and (auto and GRN or dim(self)) or c, 240, true)
        f.hot(146, y0, 818, y1, t[4])
    end
    local right = { { 84, 166, T("df_mGuide"), "", "page_gps" }, { 176, 244, T("df_motor"), "", "page_dfmotor" } }
    for _, t in ipairs(right) do
        f.txt(960, (t[1] + t[2]) * 0.5, 22, t[3], c, nil, 520, true)
        f.hot(836, t[1], 1512, t[2], t[5])
    end
    f.ctr(1436, 47, 17, T("df_config"), c, 140, true)
    f.hot(1360, 18, 1514, 76, "page_set")
    -- icônes du bas : raccourcis (nom écrit dessous), les autres grisées
    local icons = {
        { 356, 614, nil }, { 486, 614, "page_set", "df_mnSettings" }, { 616, 614, "page_dfhome", "df_homeShort" }, { 746, 614, "page_set", "df_config" }, { 880, 614, "page_rearcam_none" },
        { 220, 690, "page_home", "df_mnHome" }, { 356, 690, nil }, { 490, 690, "page_gps", "df_mGuide" }, { 620, 690, nil }, { 750, 690, nil },
        { 882, 690, nil }, { 1020, 690, nil }, { 1156, 690, "page_tool", "df_mnTool" }, { 1292, 690, nil }, { 1428, 690, nil },
        { 564, 764, nil }, { 694, 764, "page_set", "df_mnSettings" }, { 820, 764, nil }, { 944, 764, nil }, { 1074, 764, nil },
    }
    for _, ic in ipairs(icons) do
        local a = ic[3]
        if a == "page_rearcam_none" then a = nil end
        if a ~= nil then
            f.ctr(ic[1], ic[2] + 38, 11, T(ic[4]), c, 126, true)
            f.hot(ic[1] - 60, ic[2] - 34, ic[1] + 60, ic[2] + 34, a)
        else
            f.rect(ic[1] - 44, ic[2] - 32, 88, 64, offCol(self))
        end
    end
    M.chassis(self, d, f, ctx, v, "dfmenu")
end

-------------------------------------------------------------------------------
-- 12 Écran d'accueil : 4 vignettes (moteur, guidage, distributeurs, ComfortTip) ; appui = page d'accueil choisie
-------------------------------------------------------------------------------
M.HOMES = { { "as_df_motor", "df_motor", "motor" }, { "as_df_map", "df_mGuide", "guideMap" }, { "as_df_valve", "df_valves", "valve" }, { "as_df_ct", "df_ctName", "ct" } }
M.HOME_X = { { 174, 494 }, { 509, 828 }, { 843, 1163 }, { 1178, 1497 } }
function M.homeSel(self, d, ctx, v, Wp, Hp)
    local f = frame(self, ctx, Wp, Hp)
    f.img(0, 0, 1672, 941, "as_df_home" .. sfx(self))
    local cur = (self.settings or {}).dfHome or 1
    f.ctr(836, 108, 24, T("df_homeTitle"), WH, 1300, true)
    for i, h in ipairs(M.HOMES) do
        local x0, x1 = M.HOME_X[i][1], M.HOME_X[i][2]
        local w = x1 - x0
        local hh = w * 941 / 1672
        local y0 = 148 + (234 - hh) * 0.5
        if i == cur then f.rect(x0 - 6, 142, w + 12, 246, GRN) end
        f.rect(x0, 148, w, 234, WH)
        f.img(x0, y0, w, hh, h[1] .. sfx(self))
        f.ctr((x0 + x1) * 0.5, 412, 20, i .. ". " .. T(h[2]), i == cur and GRN or WH, w, true)
        f.hot(x0, 142, x1, 430, "dfhome_" .. i)
    end
    f.ctr(836, 764, 24, T("df_cancel"), WH, 600, true)
    f.hot(174, 728, 1497, 800, "page_dfmenu")
end

-------------------------------------------------------------------------------
-- pages du terminal sans écran iMonitor (outil, compteurs, guidage, réglages...) : dans la zone centrale
-------------------------------------------------------------------------------
-------------------------------------------------------------------------------
-- (06/11) page Courseplay seule, sans la carte, qui lance et coupe (comme FarmPilot)
-- page COURSEPLAY : état, parcours, réglages de Courseplay (véhicule ou parcours) en - / +, touches à droite
-------------------------------------------------------------------------------
M.cpGrp, M.cpPg = 1, 1
local function cpVal(st, fn)
    if st == nil or st[fn] == nil then return nil end
    local ok, r = pcall(st[fn], st)
    if ok then return r end
    return nil
end
function M.cpSettings(v, grp)
    local fn = grp == 2 and "getCourseGeneratorSettingsTable" or "getCpSettingsTable"
    local out = {}
    if v == nil or v[fn] == nil then return out end
    local ok, t = pcall(v[fn], v)
    if not ok or type(t) ~= "table" then return out end
    for _, st in ipairs(t) do
        if type(st) == "table" and st.getString ~= nil and st.setNextItem ~= nil and cpVal(st, "getIsVisible") ~= false then
            out[#out + 1] = st
        end
    end
    return out
end
M.CP_ROWS = 7
function M.cpPage(self, d, ctx, v)
    local ui = AS_Terminal.ui
    local C = ui.C
    local CENTER, RIGHT = RenderText.ALIGN_CENTER, RenderText.ALIGN_RIGHT
    local u, w = ctx.cx + 10, ctx.cw - 20
    local RH = 37
    local LX = u + 150
    local sb = ui.sideButton
    if not (ui.hasCp ~= nil and ui.hasCp(v)) then
        if ui.cpInstalled == nil or ui.cpInstalled() then ctx.text(u + 8, ctx.cy + 30, 15, T("cpMissing"), C.dim, nil, true) end
        return
    end
    local function call(fn) return cpVal(v, fn) end
    local function rowBox(i, rightW)
        local yy = ctx.cy + 8 + (i - 1) * RH
        ctx.rect(u, yy, w - (rightW or 0), RH - 4, C.box)
        return yy
    end
    local function label(yy, txt, col) ctx.text(u + 8, yy + 22, 13, txt, col or C.white, nil, nil, 200) end
    local active = call("getIsCpActive") == true
    local hasCourse = call("hasCpCourse") == true
    local state
    if active then state = T("cpActive")
    elseif not hasCourse then state = T("cpNoCourse")
    elseif call("getCanStartCp") == true then state = T("cpReady")
    else state = T("cpNotReady") end
    -- 1. état
    local yy = rowBox(1)
    label(yy, T("cpState"))
    ctx.text(LX + 60, yy + 22, 13, state, active and C.lamp or (hasCourse and C.white or C.amber), nil, true, w - 220)
    -- 2. parcours
    yy = rowBox(2)
    label(yy, T("cpCourse"))
    local course = call("getFieldWorkCourse")
    local nWp = course ~= nil and cpVal(course, "getNumberOfWaypoints") or nil
    local cname = (hasCourse and self.cpCourseName ~= nil) and self:cpCourseName(v, d) or nil
    local ctxt = hasCourse and ((cname ~= nil and cname ~= "-" and (cname .. "  -  ") or "") .. string.format(T("cpPoints"), nWp or 0)) or T("none")
    ctx.text(LX + 60, yy + 22, 13, ctxt, hasCourse and C.lamp or C.dim, nil, true, w - 220)
    -- 3. groupe de réglages < Véhicule / Parcours >
    yy = ctx.cy + 8 + 2 * RH
    ctx.rect(u, yy, LX - u - 6, RH - 4, C.box)
    ctx.rect(LX + 46, yy, (u + w - 54) - (LX + 46), RH - 4, C.box)
    label(yy, T("df_cpGrp"))
    ctx.button(LX, yy + 4, 40, 25, "dfcp_grp")
    ctx.text(LX + 20, yy + 22, 14, "<", C.white, CENTER, true)
    ctx.button(u + w - 48, yy + 4, 40, 25, "dfcp_grp")
    ctx.text(u + w - 28, yy + 22, 14, ">", C.white, CENTER, true)
    ctx.text((LX + 40 + u + w - 48) * 0.5, yy + 22, 13, M.cpGrp == 2 and T("cpCourse") or T("df_cpVeh"), C.lamp, CENTER, true, w - 260)
    -- 4... réglages de Courseplay (les siens : titre, valeur), - / +
    local list = M.cpSettings(v, M.cpGrp)
    local pages = math.max(1, math.ceil(#list / M.CP_ROWS))
    M.cpPg = math.max(1, math.min(pages, M.cpPg or 1))
    for r = 1, M.CP_ROWS do
        local i = (M.cpPg - 1) * M.CP_ROWS + r
        local st = list[i]
        if st == nil then break end
        local y2 = rowBox(3 + r, 108)
        local off = cpVal(st, "getIsDisabled") == true
        label(y2, tostring(cpVal(st, "getTitle") or cpVal(st, "getName") or "?"), off and C.dim or C.white)
        ctx.text(u + w - 116, y2 + 22, 13, tostring(cpVal(st, "getString") or "-"), off and C.dim or C.lamp, RIGHT, true, w - 330)
        if not off then
            ctx.button(u + w - 102, y2 + 4, 40, 25, "dfcp_m_" .. i)
            ctx.text(u + w - 82, y2 + 22, 13, "-", C.white, CENTER, true)
            ctx.button(u + w - 56, y2 + 4, 48, 25, "dfcp_p_" .. i)
            ctx.text(u + w - 32, y2 + 22, 13, "+", C.white, CENTER, true)
        end
    end
    if #list == 0 then ctx.text(u + 8, ctx.cy + 8 + 3 * RH + 22, 13, "-", C.dim) end
    -- pages des réglages
    if pages > 1 then
        yy = ctx.cy + 8 + (3 + M.CP_ROWS) * RH
        ctx.button(u, yy, 60, RH - 4, "dfcp_pg-")
        ctx.text(u + 30, yy + 22, 14, "<", C.white, CENTER, true)
        ctx.text(u + w * 0.5, yy + 22, 13, string.format(T("df_cpPage"), M.cpPg, pages), C.white, CENTER, true, w - 140)
        ctx.button(u + w - 60, yy, 60, RH - 4, "dfcp_pg+")
        ctx.text(u + w - 30, yy + 22, 14, ">", C.white, CENTER, true)
    end
    -- colonne de droite (comme la page FarmPilot)
    sb(ctx, 1, "cp_startStop", T("df_cpGoStop"), active, active and T("cpActive") or state)
    sb(ctx, 2, "cp_cgui", T("cpGenerate"), false)
    sb(ctx, 3, "cp_saves", T("cpLoadSave"), false)
    sb(ctx, 4, "cp_clear", T("cpClear"), false)
    sb(ctx, 5, "cp_menu", T("cpMenu"), false)
    sb(ctx, 6, "page_gps", T("df_cpMap"), false)
end
function M.cpAction(self, a)
    local v = (self.data or {}).vehicle
    if a == "dfcp_grp" then M.cpGrp = M.cpGrp == 2 and 1 or 2; M.cpPg = 1
    elseif a == "dfcp_pg-" then M.cpPg = math.max(1, (M.cpPg or 1) - 1)
    elseif a == "dfcp_pg+" then M.cpPg = (M.cpPg or 1) + 1
    else
        local i = tonumber(a:sub(8))
        local st = i ~= nil and M.cpSettings(v, M.cpGrp)[i] or nil
        if st ~= nil and cpVal(st, "getIsDisabled") ~= true then
            local ok, err = pcall(a:sub(6, 6) == "m" and st.setPreviousItem or st.setNextItem, st)
            if not ok then print("[AS_TerminalDeutz] ERREUR réglage Courseplay : " .. tostring(err)) end
        end
    end
    self.lastRead = -100000
end

local function subCtx(ctx, v, f, x0, y0, x1, y1)
    local cx, cy, xr, yb = f.PX(x0), f.PY(y0), f.PX(x1), f.PY(y1)
    return { text = ctx.text, measure = ctx.measure, rect = ctx.rect, button = ctx.button, hotspot = ctx.hotspot, image = ctx.image,
        cx = cx, cy = cy, cw = xr - 140 - cx - 6, ch = yb - cy, rx = xr - 140, sideY = cy - 16,
        X = ctx.X, Y = ctx.Y, sx = ctx.sx, sy = ctx.sy, rec = ctx.rec, v = v }
end
M.PAGE_OF = {}
function M.page(self, d, ctx, v, Wp, Hp, inside)
    local page = self.page
    local f = frame(self, ctx, Wp, Hp)
    -- guidage : la carte prend aussi la place de la mini-vue
    local full = page == "gps"
    f.img(0, 0, 1672, 941, "as_df_blank" .. sfx(self))
    local ctx2 = full and subCtx(ctx, v, f, 110, 6, 1545, 808) or subCtx(ctx, v, f, 506, 6, 1545, 808)
    local fn = self["page_" .. (M.PAGE_OF[page] or page)]
    if page == "dfcp" then fn = function(_, d2, c2, _, v2) return M.cpPage(self, d2, c2, v2) end end
    -- (06/11) pages du terminal (textes clairs) :
    -- fond sombre sous la zone en thème clair, sinon les textes posés hors des cases disparaissent sur le blanc
    if not M.isDark(self) then
        local C = AS_Terminal.ui.C
        f.rect(full and 108 or 502, 2, 1545 - (full and 108 or 502), 808, { C.screen[1], C.screen[2], C.screen[3], 1 })
    end
    if fn ~= nil then
        local ok, err = pcall(fn, self, d, ctx2, inside, v)
        if not ok then
            -- (06/11, page Carte de travail blanche en jeu) erreur d'une page : notée une fois, le cadre reste dessiné
            M.pageErr = M.pageErr or {}
            if not M.pageErr[page] then M.pageErr[page] = true; print("[AS_TerminalDeutz] ERREUR page " .. tostring(page) .. " : " .. tostring(err)) end
            f.ctr(1000, 400, 20, "ERREUR page " .. tostring(page), { 0.9, 0.3, 0.2, 1 }, 900, true)
        end
    end
    M.chassis(self, d, f, ctx, v, page == "gps" and "gpscourse" or page)
end

-- point d'entrée (drawPanel)
M.SCREENS = { dfmotor = "motor", dfhitchr = "hitchr", dfhitchf = "hitchf", dfvalve = "valve", dfrem = "rem", dfasm = "asm", dfct = "ct", set = "config", gps = "guideMap", dfsc = "scMap", dfmenu = "menu", dfhome = "homeSel" }
function M.screenFor(self)
    local p = self.page
    if p == "home" then return M[(M.HOMES[(self.settings or {}).dfHome or 1] or M.HOMES[1])[3]] or M.motor end
    local k = M.SCREENS[p]
    if k ~= nil then return M[k] end
    return M.page
end

-- appuis propres au Deutz ; le reste passe au terminal
if AS_Terminal ~= nil and AS_Terminal.doAction ~= nil and not M.hooked then
    M.hooked = true
    local orig = AS_Terminal.doAction
    AS_Terminal.doAction = function(self, a, ...)
        if type(a) == "string" then
            if a:sub(1, 4) == "dfm_" then return M.motorAction(self, a) end
            if a:sub(1, 5) == "dfct_" then return M.ctAction(self, a) end
            if a:sub(1, 5) == "dfcp_" then return M.cpAction(self, a) end
            if a:sub(1, 7) == "dfhome_" then
                local n = tonumber(a:sub(8)) or 1
                self.settings.dfHome = math.max(1, math.min(4, n))
                if self.saveSettings ~= nil then self:saveSettings() end
                self.page = "home"; self.lastRead = -100000
                return
            end
            if a == "dfsc_auto" then
                local v, SC = (self.data or {}).vehicle, AS_SectionControl
                if v ~= nil and SC ~= nil then SC:setCfg(v, "auto", (SC:cfg(v).auto or 0) == 1 and 0 or 1) end
                self.lastRead = -100000
                return
            end
            if a:sub(1, 6) == "dfcfg_" then
                if a == "dfcfg_up" then M.cfgSel = math.max(1, (M.cfgSel or 1) - 1)
                elseif a == "dfcfg_dn" then M.cfgSel = (M.cfgSel or 1) + 1
                else M.cfgSel = tonumber(a:sub(11)) or 1 end
                self.lastRead = -100000
                return
            end
            if a == "dfasm" then
                local v = (self.data or {}).vehicle
                if v ~= nil then M.asmOn[v] = M.asmOn[v] == false end
                self.lastRead = -100000
                return
            end
            if a:sub(1, 8) == "dfv_sel_" then
                M.vSel = tonumber(a:sub(9)) or 1
                self.remoteMenu = nil
                self.page = "dfrem"; self.lastRead = -100000
                return
            end
            if a == "dfTheme" then
                local s = self.settings
                s.dfTheme = ((s.dfTheme or 1) % 3) + 1
                if self.saveSettings ~= nil then self:saveSettings() end
                self.lastRead = -100000
                return
            end
        end
        return orig(self, a, ...)
    end
end
