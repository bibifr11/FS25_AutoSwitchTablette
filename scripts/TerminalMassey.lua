-- AutoSwitch : terminal des tracteurs Massey Ferguson (Datatronic 5, version bleue 2024)
-- Fichier chargé par AutoSwitch.lua après Terminal.lua.
--
-- (04/11) même méthode que le Case et le Claas : les écrans HD (refaits d'après les vidéos MF),
-- intégrés tels quels, sans texte dans les images ; tous les textes et valeurs sont écrits en direct (FR / EN / DE).
--   Bloc 1 = barre du haut de son accueil 01 (fixe sur toutes les pages, avec la flèche retour hors accueil).
--   Accueil 01 : relevages AV / AR (jauges), prises de force (tr/min), F1-F3, distributeurs FV1 FV2 V1-V4.
--   Menu 04 (bouton ☰) : chaque case ouvre sa page ; Compteurs 06, Accessoires 12, Paramètres 07, Options 08,
--   Infos 13 = les écrans ; les autres pages du terminal (outil / Isobus, guidage, carte, FarmPilot, réglages...)
--   sont dessinées sur le fond bleu du Datatronic.
-- Repères en pixels des écrans 1672 x 941.

AS_TerminalMassey = {}
local M = AS_TerminalMassey
M.MOD_NAME = g_currentModName

local WH = { 1, 1, 1, 1 }
local DK = { 0.09, 0.11, 0.15, 1 }
local GREEN = { 0.40, 0.80, 0.16, 1 }
local CYAN = { 0.0, 0.925, 0.99, 1 }
local DIM = { 0.80, 0.84, 0.90, 1 }
local CARD = { 0.93, 0.94, 0.95, 1 }

-- pages Massey et page d'où l'on vient (flèche retour)
M.BACK = { mfmenu = "home", mfacc = "mfmenu", mfset = "mfacc", mflic = "mfacc", mfinfo = "mfacc" }
for i = 1, 7 do M.BACK["mfw" .. i] = "home"; M.BACK["mfgw" .. i] = "gps" end
-- retour qui n'est pas une page (sous-page PARCOURS du MF Guide)
M.BACKACT = { gpscourse = "gps_back" }

local function H() return AS_Terminal.MFH end
local function T(key) return H().T(key) end

-- fonctions de dessin à l'échelle des écrans
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
    -- texte : y = milieu de la ligne
    function f.txt(x, ymid, size, s, col, align, maxW, bold)
        ctx.text(f.PX(x), f.PY(ymid + size * 0.36), f.PY(size), s, col or WH, align or RenderText.ALIGN_LEFT, bold == true, maxW and f.PW(maxW) or nil)
    end
    function f.ctr(x, ymid, size, s, col, maxW, bold) f.txt(x, ymid, size, s, col, RenderText.ALIGN_CENTER, maxW, bold) end
    function f.rgt(x, ymid, size, s, col, maxW, bold) f.txt(x, ymid, size, s, col, RenderText.ALIGN_RIGHT, maxW, bold) end
    local hot = ctx.hotspot or ctx.button
    function f.hot(x0, y0, x1, y1, action) hot(f.PX(x0), f.PY(y0), f.PW(x1 - x0), f.PY(y1 - y0), action) end
    function f.rect(x, y, w, h, c) ctx.rect(f.PX(x), f.PY(y), f.PW(w), f.PY(h), c) end
    -- largeur d'un texte, en pixels de l'image
    function f.measure(size, s)
        if ctx.measure ~= nil then
            local ok, w = pcall(ctx.measure, f.PY(size), s)
            if ok and w ~= nil then return w / kx end
        end
        return #tostring(s) * size * 0.5
    end
    -- zone écran (pour glisser la fenêtre / ouvrir la grande fenêtre depuis la tablette), comme le Case
    function f.box(x0, y0, x1, y1)
        if ctx.X == nil then return nil end
        return { x = ctx.X(f.PX(x0)), y = ctx.Y(f.PY(y1)), w = ctx.sx(f.PW(x1 - x0)), h = ctx.sy(f.PY(y1 - y0)) }
    end
    return f
end

-- virgule décimale (comme les écrans), point en anglais
local function dec(v, n)
    local s = string.format("%." .. (n or 2) .. "f", v or 0)
    if g_languageShortName ~= "en" then s = s:gsub("%.", ",") end
    return s
end

-- date du jeu jj.mm.aaaa (sep = . ou /) : jour de la période, mois de la période (période 1 = mars), année
local function gameDate(sep)
    local env = g_currentMission ~= nil and g_currentMission.environment or nil
    if env == nil then return "--" end
    local per = tonumber(env.currentPeriod) or 1
    local month = ((per + 1) % 12) + 1
    local day = tonumber(env.currentDayInPeriod) or 1
    local year = 2023 + (tonumber(env.currentYear) or 1)
    return string.format("%02d%s%02d%s%04d", day, sep, month, sep, year)
end

local function i18n(name, ...)
    local fn = g_i18n ~= nil and g_i18n[name] or nil
    if fn == nil then return nil end
    local ok, r = pcall(fn, g_i18n, ...)
    if ok then return r end
    return nil
end

local LANGS = { fr = "Français", en = "English", de = "Deutsch", it = "Italiano", es = "Español", pl = "Polski", nl = "Nederlands",
    cz = "Čeština", cs = "Čeština", pt = "Português", br = "Português (BR)", ru = "Русский", hu = "Magyar", ro = "Română", tr = "Türkçe",
    da = "Dansk", sv = "Svenska", no = "Norsk", fi = "Suomi", uk = "Українська", jp = "日本語", kr = "한국어", ct = "中文", cn = "中文" }

-------------------------------------------------------------------------------
-- Bloc 1 : barre du haut (fixe)
-------------------------------------------------------------------------------
-- (04/11 nuit) nom long (plus de 20 lettres) : sans la marque, sinon la tablette le coupe (« Kverneland Optima R »)
function M.toolName(d)
    for _, t in ipairs(d.tools or {}) do
        if t.name ~= nil and t.name ~= "" then
            local n = t.name
            local len = (utf8 ~= nil and utf8.len ~= nil and utf8.len(n)) or #n
            if len > 20 then
                local rest = n:match("^%S+%s+(.+)$")
                if rest ~= nil then n = rest end
            end
            return n
        end
    end
    return T("mf_temporary")
end

function M.topBar(self, d, f, page)
    local home = page == "home"
    f.img(0, 0, 1672, 100, home and "as_mf_top_home" or "as_mf_top_page")
    local u = H().unitsOf()
    f.txt(135, 45, 44, gameDate("."), WH, nil, 300)
    f.ctr(695, 47, 44, H().fmtClock(), WH, 120)
    local tmp = d.tempOut
    local tStr = "--"
    if tmp ~= nil then tStr = string.format("%d %s", math.floor((u and u.degC(tmp) or tmp) + 0.5), u and u.temp or "°C") end
    f.txt(903, 46, 44, tStr, WH, nil, 115)
    -- nom (outil attelé) entre le séparateur et la flèche ▾ de l'image
    f.ctr(1357, 34, 36, M.toolName(d), WH, 340)
    if home then
        -- alerte (icône transmission) : rouge sous la réserve de carburant
        local low = d.fuel ~= nil and d.fuel * 100 < (self.settings.fuelReserve or 10)
        if low then f.img(507, 12, 91, 76, "as_mf_alert_red") end
        f.hot(503, 6, 602, 94, "page_tractor")
    else
        -- (04/11 21:31) réglages Courseplay ouverts par la case Courseplay du menu : retour au menu
        local back = (page == "gpscourse" and M.cpFromMenu) and "mfcp_back" or M.BACKACT[page]
        f.hot(0, 0, 112, 98, back or ("page_" .. (M.BACK[page] or "mfmenu")))
    end
    f.hot(770, 0, 885, 98, "page_home")
    f.hot(1075, 0, 1575, 98, "page_tool")   -- icône outil + nom
    f.hot(1585, 0, 1672, 98, page == "mfmenu" and "page_home" or "page_mfmenu")
    self.headerBox = f.box(120, 0, 480, 90)
end

-------------------------------------------------------------------------------
-- Bloc 2 : cadre fixe (06/11 : chaque icône découpée en carré, cadre reconstruit en blocs)
-- colonne d'onglets de droite : même panneau au même endroit sur toutes les pages à onglets (dans l'image) ;
-- chaque icône = un sprite de même taille, l'onglet de la page ouverte allumé par le code
-------------------------------------------------------------------------------
M.RAIL_X, M.RAIL_W, M.RAIL_Y0, M.RAIL_DY, M.RAIL_H = 1519, 148, 104, 130, 129
function M.rail(f, tabs)
    local cx = M.RAIL_X + M.RAIL_W * 0.5
    for k, t in ipairs(tabs) do
        local y0 = M.RAIL_Y0 + M.RAIL_DY * (k - 1)
        if t.on then f.img(M.RAIL_X, y0, M.RAIL_W, M.RAIL_H, "as_mf_tab_on") end
        local cy = y0 + M.RAIL_H * 0.5 - (t.txt ~= nil and 14 or 0)
        f.img(cx - 64, cy - 64, 128, 128, "as_mf_ti_" .. t.icon)
        if t.txt ~= nil then f.ctr(cx, y0 + M.RAIL_H - 22, 30, t.txt, WH, M.RAIL_W - 16, true) end
        if t.act ~= nil then f.hot(M.RAIL_X, y0, M.RAIL_X + M.RAIL_W, y0 + M.RAIL_H, t.act) end
    end
end
-- colonne de gauche (7 cases de widgets) : même panneau sur l'accueil (01 et 11) et le choix (10), « + » dessiné ici
M.LS_Y0, M.LS_DY, M.LS_CX = 166.5, 113.7, 67
function M.slotY(i) return M.LS_Y0 + M.LS_DY * (i - 1) end
function M.plus(f, c) f.img(M.LS_CX - 32, c - 32, 64, 64, "as_mf_plus") end

-------------------------------------------------------------------------------
-- Accueil 01
-------------------------------------------------------------------------------
-- jauge de relevage : intérieur vidé dans l'image, remplissage en direct = hauteur (levé = plein, 100 %)
local function gauge(f, x, y0, y1, h)
    local fr = (h ~= nil and h.object ~= nil) and math.max(0, math.min(1, h.up or 0)) or 0
    local hh = (y1 - y0) * fr
    if hh > 0.5 then f.rect(x, y1 - hh, 0, hh, CYAN) end
end

-- deux mises en page, comme le vrai terminal : sans widget (écran 01) et avec widgets (écran 11, centre décalé à droite)
M.L01 = {
    img = "as_mf_p_home", gF = { 201, 245, 265, 569 }, gR = { 1544, 1590, 263, 561 }, pctF = { 232, 623 }, pctR = { 1567, 623 },
    hotF = { 140, 130, 275, 580 }, hotR = { 1490, 110, 1630, 580 }, ptoF = { 596, 476, 507 }, ptoR = { 1353, 476, 507 },
    hotPF = { 455, 450, 560, 530 }, hotPR = { 1210, 450, 1315, 530 }, wheel = { 455, 145, 545, 235 },
    fx = { 745, 900, 1055 }, fy = 583, vHead = 729, vLab = 874, vTop = 703, vBot = 905,
    valves = { { 183, 350 }, { 363, 531 }, { 688, 845 }, { 858, 1017 }, { 1028, 1185 }, { 1197, 1353 } },
    slotW = 128,
}
M.L11 = {
    img = "as_mf_p_home_w", gF = { 394, 437, 254, 548 }, gR = { 1425, 1474, 251, 545 }, pctF = { 427, 607 }, pctR = { 1460, 607 },
    hotF = { 335, 120, 470, 580 }, hotR = { 1380, 120, 1515, 580 }, ptoF = { 642, 462, 490 }, ptoR = { 1322, 452, 482 },
    hotPF = { 510, 435, 605, 510 }, hotPR = { 1190, 435, 1288, 505 }, wheel = { 500, 140, 578, 215 },
    fx = { 789, 931, 1074 }, fy = 558, vHead = 709, vLab = 849, vTop = 683, vBot = 877,
    valves = { { 367, 540 }, { 553, 727 }, { 755, 929 }, { 946, 1120 }, { 1139, 1313 }, { 1327, 1500 } },
    slotW = 322,
}
-- libellé d'une case de distributeur : nom de sa 1re fonction (côté AV / AR en 2e ligne), sinon « Distrib. 01 »
-- (la police 3D de la tablette est large : « Entraînement AV » sur une ligne était coupé)
function M.valveLabel(self, f, cx, y, w, fns, va)
    if #fns == 0 then f.ctr(cx, y, 26, string.format(T(va[2]), va[3]), WH, w); return end
    local full = self:remoteShort(fns[1])
    local name = self:remoteShort((fns[1]:gsub("@[fr]$", "")))
    if name ~= full and #full > #name + 1 then
        f.ctr(cx, y - 13, 24, name, WH, w)
        f.ctr(cx, y + 15, 22, full:sub(#name + 2), WH, w)
    else
        f.ctr(cx, y, 26, full, WH, w)
    end
end
-- nom, libellé par défaut, n°, fonction (05/11 : V1-V4 = Fonctions 1-4, FV1 / FV2 = fonctions 5 / 6)
M.VALVES = { { "FV1", "mf_valveF", 1, 5 }, { "FV2", "mf_valveF", 2, 6 }, { "V1", "mf_valve", 1, 1 }, { "V2", "mf_valve", 2, 2 },
    { "V3", "mf_valve", 3, 3 }, { "V4", "mf_valve", 4, 4 } }

-------------------------------------------------------------------------------
-- Widgets (écrans 10 et 11) : 7 cases à gauche, 23 widgets, réglés par modèle de tracteur (prefs « mfw »)
-------------------------------------------------------------------------------
M.W_SLOTS, M.W_COUNT = 7, 23
local function vehOf(self, d)
    return self.panel ~= nil and self.panel.vehicle or (d ~= nil and d.vehicle or nil)
end
function M.widgetsOf(self, v, key)
    local p = self:vehPrefs(v)
    local w = {}
    for i = 1, M.W_SLOTS do w[i] = 0 end
    local str = p ~= nil and p[key or "mfw"] or nil
    if str ~= nil then
        local i = 0
        for x in string.gmatch(str .. ",", "([^,]*),") do
            i = i + 1
            if i <= M.W_SLOTS then w[i] = math.max(0, math.min(M.W_COUNT, tonumber(x) or 0)) end
        end
    end
    return w
end
local function anyWidget(w) for i = 1, M.W_SLOTS do if (w[i] or 0) > 0 then return true end end return false end
-- choix d'un widget pour la case ouverte : un 2e appui sur le même le retire ; un widget n'est que dans une case
-- (04/11) pages « mfwN » = accueil (prefs mfw), « mfgwN » = les 7 « + » du MF Guide (prefs mfg)
local function wslot(page)
    if type(page) ~= "string" then return nil end
    local n = page:match("^mfw(%d)$")
    if n ~= nil then return tonumber(n), "mfw", "home" end
    n = page:match("^mfgw(%d)$")
    if n ~= nil then return tonumber(n), "mfg", "gps" end
    return nil
end
function M.widgetAction(self, a)
    local d = self.data
    local v = vehOf(self, d)
    local slot, key, back = wslot(self.page)
    local k = tonumber(a:sub(5) or "")
    if v == nil or slot == nil or k == nil then return end
    local w = M.widgetsOf(self, v, key)
    if w[slot] == k then w[slot] = 0 else
        for i = 1, M.W_SLOTS do if w[i] == k then w[i] = 0 end end
        w[slot] = k
    end
    local p = self:vehPrefs(v, true)
    p[key] = table.concat(w, ",")
    if self.saveSettings ~= nil then pcall(self.saveSettings, self) end
    self.page = back
end
-- valeur et unité d'un widget
local function hm(ms)
    local m = math.floor((ms or 0) / 60000)
    return string.format("%d:%02d", math.floor(m / 60), m % 60)
end
function M.widgetValue(self, d, k)
    local u = H().unitsOf()
    local cnt = d.cnt or {}
    local job = (cnt.jobs or {})[cnt.active or 1] or {}
    local tot = cnt.total or {}
    local hf, hr = H().caseHitches(d)
    local rpmU = T("cl_rpm")
    local spd = u and u.speed or "km/h"
    local function kmh(x) return u and u.kmh(x) or x end
    local function hp(h) return (h ~= nil and h.object ~= nil) and H().hitchPct(h) or "N", (h ~= nil and h.object ~= nil) and "%" or "" end
    local pto = math.floor((d.ptoRpm or 0) + 0.5)
    local hh = (job.ms or 0) / 3600000
    if k == 1 then return (d.anyOn and d.anyLowered) and T("on") or T("off"), ""
    elseif k == 4 then return string.format("%d", math.floor((d.load or 0) * 100 + 0.5)), "%"
    elseif k == 5 then return string.format("%d", math.floor((d.rpm or 0) + 0.5)), rpmU
    elseif k == 6 then return tostring(d.ptoF and pto or 0), rpmU
    elseif k == 7 then return tostring(d.ptoR and pto or 0), rpmU
    elseif k == 8 then return d.slip ~= nil and string.format("%d", math.floor(d.slip + 0.5)) or "-", "%"
    elseif k == 9 then return dec(kmh(math.abs(d.speed or 0)), 1), spd
    elseif k == 10 then return (d.cruise ~= nil and d.cruise ~= 0) and dec(kmh(d.cruiseSpeed or 0), 1) or "-", spd
    elseif k == 11 then return d.workSpeed ~= nil and dec(kmh(d.workSpeed), 1) or "-", spd
    elseif k == 12 then return d.guide ~= nil and T("on") or T("off"), ""
    elseif k == 14 then return hm(job.ms), "h"
    elseif k == 15 then return hm(tot.ms), "h"
    elseif k == 16 then return dec(u and u.ha(job.ha or 0) or (job.ha or 0)), u and u.area or "ha"
    elseif k == 17 then return dec(hh > 0.01 and (u and u.ha(job.ha or 0) or (job.ha or 0)) / hh or 0), (u and u.area or "ha") .. "/h"
    elseif k == 18 then return dec(d.fuelUse or 0, 1), (u and u.vol or "L") .. "/h"
    elseif k == 19 then return dec((job.ha or 0) > 0.01 and (job.fuel or 0) / job.ha or 0, 1), (u and u.vol or "L") .. "/" .. (u and u.area or "ha")
    elseif k == 20 then return tostring(cnt.active or 1), ""
    elseif k == 21 then return hp(hf)
    elseif k == 22 then return hp(hr)
    end
    return "-", ""   -- A, B (mémoires moteur), demi-tour, contrôle d'effort : pas de donnée dans le jeu
end

function M.home(self, d, ctx, v, Wp, Hp)
    local f = frame(self, ctx, Wp, Hp)
    local wl = M.widgetsOf(self, v)
    local L = anyWidget(wl) and M.L11 or M.L01
    f.img(0, 0, 1672, 941, L.img)
    M.topBar(self, d, f, "home")
    local hf, hr = H().caseHitches(d)
    -- jauges (relevage AV à gauche, AR à droite)
    local function g(r, h)
        local fr = (h ~= nil and h.object ~= nil) and math.max(0, math.min(1, h.up or 0)) or 0
        local hh = (r[4] - r[3]) * fr
        if hh > 0.5 then f.rect(r[1], r[4] - hh, r[2] - r[1], hh, CYAN) end
    end
    g(L.gF, hf)
    g(L.gR, hr)
    f.ctr(L.pctF[1], L.pctF[2], 40, H().hitchPct(hf) .. ((hf ~= nil and hf.object ~= nil) and " %" or ""), WH, 120, true)
    f.ctr(L.pctR[1], L.pctR[2], 40, H().hitchPct(hr) .. ((hr ~= nil and hr.object ~= nil) and " %" or ""), WH, 120, true)
    f.hot(L.hotF[1], L.hotF[2], L.hotF[3], L.hotF[4], "hitch_f")
    f.hot(L.hotR[1], L.hotR[2], L.hotR[3], L.hotR[4], "hitch_r")
    -- prises de force AV / AR (tr/min de la prise de force quand un outil entraîné tourne)
    local rpm = math.floor((d.ptoRpm or 0) + 0.5)
    f.ctr(L.ptoF[1], L.ptoF[2], 34, tostring(d.ptoF and rpm or 0), WH, 80)
    f.ctr(L.ptoF[1], L.ptoF[3], 30, T("cl_rpm"), WH, 90)
    f.ctr(L.ptoR[1], L.ptoR[2], 34, tostring(d.ptoR and rpm or 0), WH, 80)
    f.ctr(L.ptoR[1], L.ptoR[3], 30, T("cl_rpm"), WH, 90)
    f.hot(L.hotPF[1], L.hotPF[2], L.hotPF[3], L.hotPF[4], "on")
    f.hot(L.hotPR[1], L.hotPR[2], L.hotPR[3], L.hotPR[4], "on")
    -- volant = guidage
    f.hot(L.wheel[1], L.wheel[2], L.wheel[3], L.wheel[4], "guide")
    -- touches F1 F2 F3
    for i, x in ipairs(L.fx) do f.ctr(x, L.fy, 30, "F" .. i, WH, 90, true) end
    -- distributeurs : chaque case = sa fonction (fonction + état voulu, comme le Case), réglée sur la page Distributeurs ;
    -- (05/11) la case porte le nom de sa fonction ; sans fonction, un appui ouvre
    -- son réglage (FV1 sans fonction = relevage AV, comme avant)
    local rem = (v ~= nil and self.remoteFns ~= nil) and self:remoteFns(v) or {}
    for i, va in ipairs(M.VALVES) do
        local x0, x1 = L.valves[i][1], L.valves[i][2]
        local cx = (x0 + x1) * 0.5
        local fns = rem[va[4]] or {}
        f.ctr(cx, L.vHead, 34, va[1], DK, x1 - x0 - 16)
        -- (police 3D de la tablette plus large : libellés courts, taille 26, toute la largeur de la case)
        M.valveLabel(self, f, cx, L.vLab, x1 - x0 - 6, fns, va)
        local act
        if #fns > 0 then act = "rem_" .. va[4]
        elseif va[1] == "FV1" then act = "hitch_f"
        else act = "mfv_open_" .. i end
        f.hot(x0, L.vTop, x1, L.vBot, act)
    end
    -- colonne de gauche : widgets choisis ; un appui ouvre le choix (écran 10)
    for i = 1, M.W_SLOTS do
        local c = M.slotY(i)
        local k = wl[i] or 0
        if k > 0 then
            f.img(12, c - 55, 311, 111, "as_mf_wbox")
            f.img(35, c - 36, 72, 72, string.format("as_mf_wi_%02d", k))
            local val, unit = M.widgetValue(self, d, k)
            -- unité collée à la valeur (écran 11) ; si la case est trop courte (tablette), en bas à droite
            local wv = f.measure(52, val)
            local wu = (unit ~= nil and unit ~= "") and f.measure(24, unit) or 0
            if wu == 0 or 143 + wv + 6 + wu <= 310 then
                f.txt(143, c - 2, 52, val, WH, nil, 166)
                if wu > 0 then f.txt(143 + wv + 6, c + 14, 24, unit, WH, nil, 310 - (143 + wv + 6)) end
            else
                f.txt(143, c - 8, 52, val, WH, nil, 166)
                f.rgt(310, c + 36, 24, unit, WH, 120)
            end
        else
            M.plus(f, c)   -- case vide : « + » (bloc), au même endroit sur 01, 11 et 10
        end
        f.hot(0, c - 55, L.slotW, c + 55, "page_mfw" .. i)
    end
end

-- choix du widget d'une case (écran 10)
M.WX = { { 355, 505 }, { 533, 683 }, { 711, 862 }, { 889, 1040 }, { 1067, 1218 }, { 1246, 1397 } }
M.WY = { { 143, 274 }, { 302, 433 }, { 461, 592 }, { 620, 751 } }
function M.wid(self, d, ctx, v, Wp, Hp)
    local f = frame(self, ctx, Wp, Hp)
    local page = self.page
    local slot, key, back = wslot(page)
    slot = slot or 1
    local pre = key == "mfg" and "mfgw" or "mfw"
    f.img(0, 0, 1672, 941, "as_mf_p_wid")
    M.topBar(self, d, f, page)
    local wl = M.widgetsOf(self, v, key)
    for i = 1, M.W_SLOTS do
        local c = M.slotY(i)
        if i == slot then f.img(M.LS_CX - 58, c - 54, 116, 108, "as_mf_tab_on") end
        M.plus(f, c)
        f.hot(0, c - 56, 135, c + 56, "page_" .. pre .. i)
    end
    local k = 0
    for _, ry in ipairs(M.WY) do
        for _, rx in ipairs(M.WX) do
            k = k + 1
            if k <= M.W_COUNT then
                if wl[slot] == k then   -- widget de cette case : cadre vert (2e appui = retirer)
                    local t = 6
                    f.rect(rx[1] - 2, ry[1] - 2, rx[2] - rx[1] + 4, t, GREEN)
                    f.rect(rx[1] - 2, ry[2] - t + 2, rx[2] - rx[1] + 4, t, GREEN)
                    f.rect(rx[1] - 2, ry[1] - 2, t, ry[2] - ry[1] + 4, GREEN)
                    f.rect(rx[2] - t + 2, ry[1] - 2, t, ry[2] - ry[1] + 4, GREEN)
                end
                f.hot(rx[1], ry[1], rx[2], ry[2], "mfw_" .. k)
            end
        end
    end
    M.rail(f, { { icon = "tractor", on = true, act = "page_" .. (back or "home") } })
end

-------------------------------------------------------------------------------
-- Menu 04
-------------------------------------------------------------------------------
M.MENU_COLS = { { 382, 552 }, { 578, 748 }, { 772, 942 }, { 966, 1138 }, { 1162, 1335 }, { 1360, 1535 } }
M.MENU_ROWS = { { 180, 345 }, { 367, 533 }, { 555, 720 } }
-- actions des cases (ligne, colonne) ; nil = pas de fonction dans le jeu
M.MENU_ACT = {
    { "page_tractor", "page_tractor", "page_mfhitch", "page_mfvalve", "page_tool", "page_fp" },   -- (05/11) Hydraulique = distributeurs
    { "page_mfhitch", "page_tractor", "guide", "page_mfsc", "page_count", "page_mftask" },   -- Dual Control = relevages AV / AR, MF Guide = guidage, SC = réglages SC (écran 24), Isobus = tâches (28-29)
    { "page_mfcam", "page_mfvalve", "page_tool", "page_mflight", nil, nil },   -- Caméra = caméra arrière ; Éclairage = page des feux (05/11) ; Climat et Radio : rien dans le jeu (case grisée)
}
-- (04/11) icônes réduites dans l'image, nom écrit sous chaque case
M.MENU_LBL = {
    { "mf_mEngine", "mf_mTrans", "mf_mHitch", "mf_mHyd", "mf_mPto", "mf_mFp" },
    { "mf_mDual", "mf_m4wd", "mf_mGuide", "mf_mSc", "mf_mCount", "mf_mIsobus" },
    { "mf_mCam", "mf_mJoy", "mf_mTool", "mf_mLight", "mf_mClim", "mf_mRadio" },
}
-- colonne de gauche : tracteur, Courseplay (04/11 21:31, case ajoutée dans le trou), accessoires et réglages
M.MENU_LEFT = { { 127, 180, 310, 357, "page_tractor", "mf_mTractor" }, { 127, 367, 310, 533, "mfcp", "mf_mCp" },
    { 127, 547, 310, 720, "page_mfacc", "mf_mSet" } }
function M.menu(self, d, ctx, v, Wp, Hp)
    local f = frame(self, ctx, Wp, Hp)
    f.img(0, 0, 1672, 941, "as_mf_p_menu")
    M.topBar(self, d, f, "mfmenu")
    local fpOk = AS_TerminalFp ~= nil and AS_TerminalFp.available ~= nil and AS_TerminalFp:available(v) == true
    for r, row in ipairs(M.MENU_ROWS) do
        for c, col in ipairs(M.MENU_COLS) do
            local a = M.MENU_ACT[r][c]
            if a == "page_fp" and not fpOk then a = nil end
            -- (13/11) case FarmPilot sans FarmPilot installé : case vide (icône cachée, pas de nom)
            local gone = M.MENU_ACT[r][c] == "page_fp" and AS_Terminal.ui ~= nil and AS_Terminal.ui.fpInstalled ~= nil and not AS_Terminal.ui.fpInstalled()
            if a ~= nil then f.hot(col[1], row[1], col[2], row[2], a)
            else ctx.rect(f.PX(col[1] + 3), f.PY(row[1] + 3), f.PW(col[2] - col[1] - 6), f.PY(row[2] - row[1] - 6), { 0.02, 0.05, 0.12, 1 }, gone and 1 or 0.55) end
            if not gone then f.ctr((col[1] + col[2]) * 0.5, row[2] - 25, 26, T(M.MENU_LBL[r][c]), a ~= nil and WH or { 0.55, 0.60, 0.68, 1 }, col[2] - col[1] - 14) end
        end
    end
    for _, e in ipairs(M.MENU_LEFT) do
        -- (13/11) case Courseplay seulement si Courseplay est installé
        if e[5] ~= "mfcp" or AS_Terminal.ui == nil or AS_Terminal.ui.cpInstalled == nil or AS_Terminal.ui.cpInstalled() then
            f.hot(e[1], e[2], e[3], e[4], e[5])
            f.ctr((e[1] + e[3]) * 0.5, e[4] - 25, 26, T(e[6]), WH, e[3] - e[1] - 14)
        end
    end
    f.txt(92, 795, 27, T("mf_memory"), WH, nil, 235, true)
    f.txt(337, 792, 40, "14%", GREEN, nil, 110, true)
end

-------------------------------------------------------------------------------
-- Compteurs 06
-------------------------------------------------------------------------------
M.CNT_ROWS = { 452, 543, 633, 721, 812 }
local function field(f, x0, x1, y, val, unit)
    -- valeur à gauche, unité à droite : chacune sa part de la case (sinon elles se touchent sur la tablette)
    f.txt(x0 + 12, y, 40, val, WH, nil, x1 - x0 - 24 - 95)
    if unit ~= nil and unit ~= "" then f.rgt(x1 - 12, y, 32, unit, WH, 85) end
end
function M.count(self, d, ctx, v, Wp, Hp)
    local f = frame(self, ctx, Wp, Hp)
    f.img(0, 0, 1672, 941, "as_mf_p_count")
    M.topBar(self, d, f, "count")
    local u = H().unitsOf()
    local c = d.cnt
    local job = c.jobs[c.active] or c.jobs[1]
    local tot = c.total
    f.txt(172, 165, 40, gameDate("/"), WH, nil, 235)
    f.txt(422, 165, 44, H().fmtClock(), WH, nil, 110)
    f.ctr(607, 192, 24, T("mf_reset"), WH, 105, true)
    f.hot(548, 105, 665, 222, "reset")
    -- largeur de travail de l'outil attelé
    local w = 0
    for _, t in ipairs(d.tools or {}) do if (t.width or 0) > w then w = t.width end end
    f.ctr(258, 358, 42, dec(w), WH, 120)
    f.ctr(364, 358, 34, "m", WH, 40)
    f.rgt(905, 368, 38, T("mf_work"), WH, 260)
    f.rgt(1440, 368, 38, T("mf_total"), WH, 260)
    -- onglets : compteurs (page ouverte) ; numéro du compteur, clic = l'autre compteur
    M.rail(f, { { icon = "cnt", on = true }, { icon = "gauge", txt = tostring(c.active or 1), act = (c.active or 1) == 1 and "job2" or "job1" } })
    local function h(ms) return (ms or 0) / 3600000 end
    local function minutes(ms) return tostring(math.floor((ms or 0) / 60000)) end
    local area = u and u.area or "ha"
    local vol = u and u.vol or "L"
    local spd = u and u.speed or "km/h"
    local function ha(x) return u and u.ha(x) or x end
    local function l(x) return u and u.l(x) or x end
    local function kmh(x) return u and u.kmh(x) or x end
    local R = M.CNT_ROWS
    -- Travail : temps, distance au travail, surface, carburant, temps prise de force (pas compté)
    field(f, 182, 455, R[1], minutes(job.ms), "min")
    field(f, 182, 455, R[2], tostring(math.floor(job.distW or 0)), "m")
    field(f, 182, 455, R[3], dec(ha(job.ha or 0)), area)
    field(f, 182, 455, R[4], dec(l(job.fuel or 0), 1), vol)
    field(f, 182, 455, R[5], "-", "min")
    local hh = h(job.ms)
    field(f, 680, 943, R[1], dec(hh > 0.01 and ha(job.ha or 0) / hh or 0), area .. "/h")
    field(f, 680, 943, R[2], dec(hh > 0.01 and l(job.fuel or 0) / hh or 0, 1), vol .. "/h")
    field(f, 680, 943, R[3], dec((job.ha or 0) > 0.01 and (u and u.lha(job.fuel / job.ha) or job.fuel / job.ha) or 0, 1), vol .. "/" .. area)
    field(f, 680, 943, R[4], dec(hh > 0.01 and kmh((job.dist or 0) / 1000 / hh) or 0, 1), spd)
    f.txt(692, R[5], 40, tostring(c.active or 1), WH, nil, 150)
    f.hot(862, 775, 943, 850, (c.active or 1) == 1 and "job2" or "job1")
    -- Total : temps, distance, carburant, vitesse moyenne, coût du carburant
    local th = h(tot.ms)
    field(f, 1185, 1455, R[1], minutes(tot.ms), "min")
    field(f, 1185, 1455, R[2], tostring(math.floor(tot.dist or 0)), "m")
    field(f, 1185, 1455, R[3], dec(l(tot.fuel or 0), 1), vol)
    field(f, 1185, 1455, R[4], dec(th > 0.01 and kmh((tot.dist or 0) / 1000 / th) or 0, 1), spd)
    local price = nil
    local eco = g_currentMission ~= nil and g_currentMission.economyManager or nil
    if eco ~= nil and FillType ~= nil and FillType.DIESEL ~= nil then
        for _, fn in ipairs({ "getCostPerLiter", "getPricePerLiter" }) do
            if price == nil and eco[fn] ~= nil then
                local ok, p = pcall(eco[fn], eco, FillType.DIESEL, false)
                if ok and type(p) == "number" then price = p end
            end
        end
    end
    field(f, 1185, 1455, R[5], tostring(math.floor((tot.fuel or 0) * (price or 0) + 0.5)), i18n("getCurrencySymbol", true) or "€")
end

-------------------------------------------------------------------------------
-- Accessoires 12, Paramètres 07, Options 08, Infos 13
-------------------------------------------------------------------------------
function M.acc(self, d, ctx, v, Wp, Hp)
    local f = frame(self, ctx, Wp, Hp)
    f.img(0, 0, 1672, 941, "as_mf_p_acc")
    M.topBar(self, d, f, "mfacc")
    f.ctr(840, 157, 44, T("mf_accTitle"), WH, 700)
    f.hot(847, 372, 1075, 608, "page_mfset")
    f.hot(1096, 372, 1324, 608, "page_set")
end

-- onglets Paramètres / Options / Infos : mêmes sprites aux mêmes places, celui de la page ouverte allumé
local function tabs(f, page)
    M.rail(f, { { icon = "set", act = "page_mfset", on = page == "mfset" }, { icon = "lock", act = "page_mflic", on = page == "mflic" },
        { icon = "info", act = "page_mfinfo", on = page == "mfinfo" } })
end

function M.set(self, d, ctx, v, Wp, Hp)
    local f = frame(self, ctx, Wp, Hp)
    f.img(0, 0, 1672, 941, "as_mf_p_set")
    M.topBar(self, d, f, "mfset")
    local u = H().unitsOf()
    f.ctr(187, 180, 40, T("mf_metric"), WH, 240)
    f.ctr(447, 180, 40, T("mf_imperial"), WH, 230)
    f.ctr(700, 180, 40, "US", WH, 120)
    local dist = u ~= nil and u.imperial and "ft" or "m"
    local L = { { 240, 290, u and u.vol or "L" }, { 240, 385, u and u.area or "ha" }, { 240, 480, "Pa" }, { 240, 577, u and u.temp or "°C" },
        { 555, 290, "kg" }, { 555, 385, dist }, { 555, 480, "N" } }
    for _, e in ipairs(L) do f.txt(e[1], e[2], 40, e[3], WH, nil, 95) end
    f.txt(242, 815, 40, LANGS[g_languageShortName or ""] or tostring(g_languageShortName or "-"), WH, nil, 320)
    f.txt(1038, 172, 44, gameDate("/"), WH, nil, 240)
    f.txt(1038, 276, 44, H().fmtClock(), WH, nil, 200)
    f.txt(1038, 378, 44, "30 %", WH, nil, 120)
    f.txt(1038, 657, 44, "100 %", WH, nil, 120)
    -- (touche OK décalée de 30 à gauche : hors de la colonne d'onglets)
    f.ctr(1433, 820, 40, "OK", WH, 120, true)
    f.hot(1362, 772, 1505, 865, "page_mfacc")
    tabs(f, "mfset")
end

M.LIC = { { 205, 215, "Section Control" }, { 208, 328, "Task Doc Pro" }, { 213, 442, "VRC" }, { 218, 555, "Wayline Assistant" },
    { 960, 322, "TIM" }, { 962, 432, "AutoTurn" }, { 965, 545, "AutoHeadland" }, { 970, 657, "E-Loader" } }
function M.lic(self, d, ctx, v, Wp, Hp)
    local f = frame(self, ctx, Wp, Hp)
    f.img(0, 0, 1672, 941, "as_mf_p_lic")
    M.topBar(self, d, f, "mflic")
    for _, e in ipairs(M.LIC) do f.txt(e[1], e[2], 46, e[3], WH, nil, e[1] < 900 and 440 or 410) end
    f.txt(972, 770, 44, T("mf_radio"), WH, nil, 410)
    f.ctr(1210, 157, 40, T("mf_serial"), WH, 350)
    f.ctr(1215, 202, 40, "2414284AF", WH, 330)
    tabs(f, "mflic")
end

local function modVersion()
    if g_modManager ~= nil and M.MOD_NAME ~= nil then
        local ok, m = pcall(g_modManager.getModByName, g_modManager, M.MOD_NAME)
        if ok and m ~= nil and m.version ~= nil then return tostring(m.version) end
    end
    return "-"
end
function M.info(self, d, ctx, v, Wp, Hp)
    local f = frame(self, ctx, Wp, Hp)
    f.img(0, 0, 1672, 941, "as_mf_p_info")
    M.topBar(self, d, f, "mfinfo")
    local L = { { 52, 152, T("mf_app"), true }, { 52, 188, "AutoSwitch " .. modVersion() }, { 52, 291, "BSP", true }, { 52, 328, "nt03_230330_193739" },
        { 52, 430, "Kernel", true }, { 52, 464, "3.0.35" }, { 52, 498, "Thu Mar 30 19:37:22 CEST 2023" },
        { 908, 152, T("mf_rev"), true }, { 908, 188, "f69ab17" }, { 908, 287, T("mf_machine"), true }, { 908, 323, "nt0x-vm" },
        { 908, 430, T("mf_builtOn"), true }, { 908, 464, "Thu, 25 Jan 2024 15:38:05 GMT" } }
    for _, e in ipairs(L) do f.txt(e[1], e[2], 34, e[3], WH, nil, 560, e[4]) end
    f.ctr(164, 852, 44, T("mf_resetBtn"), WH, 220)
    tabs(f, "mfinfo")
end

-------------------------------------------------------------------------------
-- Pages du terminal (outil, guidage, carte, compteurs, FarmPilot, réglages, info) sur le fond bleu du Datatronic ;
-- relevage AR / AV et Fonctions (distributeurs) = cases du Case, posées sur un panneau clair
-------------------------------------------------------------------------------
local function subCtx(ctx, v, f, x0, y0, x1, y1, full)
    local cx, cy, xr, yb = f.PX(x0), f.PY(y0), f.PX(x1), f.PY(y1)
    local rx = full and xr or (xr - 140)
    return { text = ctx.text, measure = ctx.measure, rect = ctx.rect, button = ctx.button, hotspot = ctx.hotspot, image = ctx.image,
        cx = cx, cy = cy, cw = full and (xr - cx) or (rx - cx - 6), ch = yb - cy, rx = rx, sideY = cy - 16,
        X = ctx.X, Y = ctx.Y, sx = ctx.sx, sy = ctx.sy, rec = ctx.rec, v = v }
end

function M.page(self, d, ctx, v, Wp, Hp, inside)
    local f = frame(self, ctx, Wp, Hp)
    local page = self.page
    f.img(0, 0, 1672, 941, "as_mf_p_blank")
    if page == "mfhitch" or page == "mfhitchf" or page == "mfrem" then
        f.rect(380, 230, 1072, 600, CARD)
        local hot = ctx.hotspot or ctx.button
        if page == "mfrem" then self:caseRemotesSub(d, ctx, v, f.PX, f.PY, f.PW, hot, f.img)
        else self:caseHitchSub(d, ctx, v, f.PX, f.PY, f.PW, hot, page == "mfhitchf") end
    else
        local ctx2 = subCtx(ctx, v, f, 24, 112, 1650, 925, page == "gps")
        local fn = self["page_" .. page]
        if fn ~= nil then
            local ok, err = pcall(fn, self, d, ctx2, inside, v)
            if not ok then error(err) end
        end
    end
    M.topBar(self, d, f, page)
end

-------------------------------------------------------------------------------
-- MF Guide (les écrans 16 et 23) : barre d'outils, barre de couleurs, carte en direct, colonne de droite.
-- Textes et valeurs écrits en direct ; variantes d'images : flèche rouge (côté où braquer), volant vert (guidage
-- engagé), antenne SBAS (signal GPS seul, écran 27) à la place des stations NTRIP.
-------------------------------------------------------------------------------
M.gview = "top"   -- vue de dessus comme le vrai terminal ; la case champ passe en perspective
M.GW_Y = { 167, 274, 384, 492, 601, 711, 822 }   -- milieu des 7 « + » de la colonne de gauche
M.BAR = { x0 = 638, x1 = 1035, y = 116, h = 22, n = 8 }
M.SIG = { { 1370, 78 }, { 1387, 68 }, { 1403, 57 }, { 1419, 45 }, { 1436, 32 } }   -- barres du signal (x, haut), bas à 87
local SIGCOL = { fix = { 0.33, 0.82, 0.12, 1 }, float = { 1.00, 0.55, 0.12, 1 }, gps = { 1.00, 0.86, 0.15, 1 }, lost = { 1.00, 0.24, 0.20, 1 } }
local SIGOFF = { 0.24, 0.29, 0.38, 1 }

-- écart à la ligne : « 1,62 m » (ou ft), « -- » sans ligne
local function xteTxt(g)
    if g.data == nil or not g.onLine or g.inTurn or g.xte == nil then return "--" end
    local m = math.abs(g.xte)
    local u = H().unitsOf()
    if u ~= nil and u.imperial then
        local ft = m * 3.2808
        return dec(ft, ft < 10 and 2 or 1) .. " ft"
    end
    return dec(m, m < 10 and 2 or 1) .. " m"
end

function M.guideAction(self, a)
    local G = AS_TerminalGps
    if G == nil then return end
    if a == "mfg_view" then
        M.gview = M.gview == "top" and "persp" or "top"
    elseif a == "mfg_zoom" then
        -- loupe : rapproche à chaque appui, puis revient à la vue la plus large
        local n = M.gview == "top" and #G.TOP or #G.PERSP
        local z = math.min(n, G.zoom or 2) - 1
        if z < 1 then z = n end
        G.zoom = z
    end
    G.drawCache = nil
    self.lastRead = -100000
end

-- rampe des tronçons : petits carrés le long de chaque tronçon (comme les écrans 25 et 27)
local BAR_COL = { on = { 0.33, 0.82, 0.12, 1 }, ready = { 1.00, 0.86, 0.15, 1 }, off = { 0.95, 0.96, 0.97, 1 } }
function M.drawBar(ctx, f, lv, segs)
    local sz, gap, o = f.PW(11), f.PW(4), f.PW(2)
    local b = lv.box
    for _, s in ipairs(segs) do
        local a1, c1 = lv.toLocal(s.x1, s.z1)
        local a2, c2 = lv.toLocal(s.x2, s.z2)
        local u1, w1 = lv.proj(a1, c1, 0)
        local u2, w2 = lv.proj(a2, c2, 0)
        if u1 ~= nil and u2 ~= nil then
            local len = math.sqrt((u2 - u1) ^ 2 + (w2 - w1) ^ 2)
            local n = math.max(1, math.floor(len / (sz + gap) + 0.5))
            local col = BAR_COL[s.state] or BAR_COL.off
            for i = 0, n - 1 do
                local t = (i + 0.5) / n
                local uu, ww = u1 + (u2 - u1) * t, w1 + (w2 - w1) * t
                if uu > b.x + sz and uu < b.x + b.w - sz and ww > b.y + sz and ww < b.y + b.h - sz then
                    ctx.rect(uu - sz * 0.5 - o, ww - sz * 0.5 - o, sz + 2 * o, sz + 2 * o, { 0.02, 0.02, 0.03, 1 })
                    ctx.rect(uu - sz * 0.5, ww - sz * 0.5, sz, sz, col)
                end
            end
        end
    end
    return #segs
end

-- menu SC (écran 25) : Auto / Manuel, zone faite On / Off, bord du champ
function M.scAction(self, a)
    if a == "mfsc_menu" then M.scMenu = not M.scMenu; return end
    local SC = AS_SectionControl
    local v = vehOf(self, self.data)
    if SC == nil or v == nil then return end
    if a == "mfsc_auto" then SC:setCfg(v, "auto", 1)
    elseif a == "mfsc_manu" then SC:setCfg(v, "auto", 0)
    elseif a == "mfsc_done1" then SC:setCfg(v, "done", 1)
    elseif a == "mfsc_done0" then SC:setCfg(v, "done", 0)
    elseif a == "mfsc_tool" then M.scToolIx = (M.scToolIx or 1) + 1; M.scSec = 1
    elseif a == "mfsc_boom1" then SC:setCfg(v, "boom", 1)
    elseif a == "mfsc_boom0" then SC:setCfg(v, "boom", 0)
    elseif a:sub(1, 8) == "mfsc_st_" then
        -- ◀ ▶ de l'écran 24 ; le % du bord passe la case du bord sur « dès qu'il sort » (la case « moitié » = 50 %)
        local key, dir = a:match("^mfsc_st_(%a+)_(%-?%d)$")
        if key ~= nil then
            if key == "ovBd" then
                local c = SC:cfg(v)
                if c.bd ~= 1 then
                    if c.bd == 2 then SC:setCfg(v, "ovBd", 50) end
                    SC:setCfg(v, "bd", 1)
                end
            end
            SC:step(v, key, tonumber(dir))
        end
    else
        local n = tonumber(a:match("^mfsc_bd(%d)$") or "")
        if n ~= nil and n >= 1 and n <= 3 then SC:setCfg(v, "bd", n) end
    end
    self.lastRead = -100000
end

function M.guide(self, d, ctx, v, Wp, Hp, inside)
    local f = frame(self, ctx, Wp, Hp)
    local G = AS_TerminalGps
    -- sous-page PARCOURS (réglages Courseplay, enregistrement du bord, parcours enregistrés) : fond bleu du Datatronic
    if G ~= nil and G.sub == "course" then
        f.img(0, 0, 1672, 941, "as_mf_p_blank")
        local ctx2 = subCtx(ctx, v, f, 24, 112, 1650, 925, false)
        local ok, err = pcall(self.page_gps, self, d, ctx2, inside, v)
        if not ok then error(err) end
        M.topBar(self, d, f, "gpscourse")
        return
    end
    local g = d.gps or {}
    f.img(0, 0, 1672, 941, "as_mf_p_guide")
    -- carte en direct (vue du terminal, sans sa barre de guidage ni ses touches)
    if G ~= nil and v ~= nil then
        local cx, cy = f.PX(108), f.PY(100)
        local ctx2 = { text = ctx.text, measure = ctx.measure, rect = ctx.rect, button = ctx.button, hotspot = ctx.hotspot, image = ctx.image,
            cx = cx, cy = cy, cw = f.PX(1672) - cx, ch = f.PY(941) - cy, rx = f.PX(1672), sideY = cy,
            X = ctx.X, Y = ctx.Y, sx = ctx.sx, sy = ctx.sy, rec = ctx.rec, v = v, noKeys = true, mapOnly = true }
        local view = G.view
        G.view = M.gview
        local ok, err = pcall(G.draw, G, self, d, ctx2, v)
        G.view = view
        if not ok and not M.loggedMap then M.loggedMap = true; print("[AS_Terminal] Massey : ERREUR carte MF Guide : " .. tostring(err)) end
    end
    -- rampe des tronçons (Section Control) à la ligne de travail de l'outil : vert allumé, jaune prêt, blanc coupé
    local SC = AS_SectionControl
    local scc = (SC ~= nil and v ~= nil) and SC:cfg(v) or nil
    local scAuto = scc ~= nil and scc.auto == 1
    if SC ~= nil and G ~= nil and G.lastView ~= nil and G.lastView.v == v then
        local okB, n = pcall(M.drawBar, ctx, f, G.lastView, SC:bar(v))
        if not okB and not M.loggedBar then M.loggedBar = true; print("[AS_Terminal] Massey : ERREUR rampe SC : " .. tostring(n)) end
    end
    -- barre de couleurs, posée sur la carte (04/11 : colonne de droite retirée)
    f.img(620, 109, 436, 36, "as_mf_g_bar")
    -- les 7 « + » de gauche : widgets au choix (comme l'accueil), un appui ouvre le choix
    local gw = M.widgetsOf(self, v, "mfg")
    for i, c in ipairs(M.GW_Y) do
        local k = gw[i] or 0
        if k > 0 then
            f.img(0, c - 54, 106, 108, "as_mf_g_wslot")
            f.img(33, c - 50, 40, 40, string.format("as_mf_wi_%02d", k))
            local val, unit = M.widgetValue(self, d, k)
            f.ctr(53, c + 12, 28, val, WH, 100, true)
            if unit ~= nil and unit ~= "" then f.ctr(53, c + 38, 18, unit, WH, 100) end
        end
        f.hot(0, c - 54, 106, c + 54, "page_mfgw" .. i)
    end
    -- barre de couleurs : sur une ligne, seules les cases du côté où braquer restent allumées (4 cm par case)
    local B = M.BAR
    local onLine = g.data ~= nil and g.onLine and not g.inTurn and g.xte ~= nil
    local lit, steerLeft = 0, false
    if onLine then
        local cm = (G ~= nil and G.LED_CM) or 4
        lit = math.min(B.n, math.floor(math.abs(g.xte) * 100 / cm))
        steerLeft = g.xte > 0
        local cw = (B.x1 - B.x0) / (2 * B.n + 1)
        for k = -B.n, B.n do
            local a = math.abs(k)
            local on = (k == 0 and lit <= 1) or (k ~= 0 and (k < 0) == steerLeft and a <= lit)
            if not on then
                ctx.rect(f.PX(B.x0 + (k + B.n) * cw), f.PY(B.y), f.PW(cw), f.PY(B.h), { 0.02, 0.03, 0.05, 1 }, 0.72)
            end
        end
    end
    -- flèches : rouge du côté où braquer, hors de la zone verte
    if onLine and lit > 2 then
        if steerLeft then f.img(590, 0, 126, 100, "as_mf_g_arrl_red") else f.img(908, 0, 128, 100, "as_mf_g_arrr_red") end
    end
    -- volant : vert quand le guidage conduit
    if g.steer == "on" then f.img(1474, 0, 190, 100, "as_mf_g_steer_on") end
    -- signal : NTRIP (stations RTK) ou SBAS (GPS seul), barres en direct
    local sig, bars = "gps", 3
    if G ~= nil then
        local okR, s1, _, b1 = pcall(G.rtkSignal, G, v)
        if okR and s1 ~= nil then sig, bars = s1, b1 or 1 end
    end
    if sig == "gps" then f.img(1262, 4, 124, 92, "as_mf_g_sbas") end
    local sc = SIGCOL[sig] or SIGCOL.gps
    for k, b in ipairs(M.SIG) do f.rect(b[1], b[2], 9, 87 - b[2], k <= bars and sc or SIGOFF) end
    f.txt(1175, 26, 34, "3G", WH, nil, 60, true)
    f.txt(1175, 74, 34, sig == "gps" and "SBAS" or "NTRIP", sig == "lost" and sc or WH, nil, 112, true)
    -- Section Control : AUTO (icône de l'écran 27) ou MANU (icône barrée de l'écran 16) ; menu SC de l'écran 25
    if scAuto then f.img(264, 0, 145, 100, "as_mf_g_sc_auto") end
    f.txt(292, 19, 22, "SC", WH, nil, 34, true)
    f.ctr(334, 75, 32, scAuto and "AUTO" or "MANU", WH, 112, true)
    if M.scMenu and scc ~= nil then
        f.img(312, 166, 574, 124, scc.done == 1 and "as_mf_g_sc_r1_on" or "as_mf_g_sc_r1_off")
        f.img(312, 290, 574, 142, "as_mf_g_sc_r2_" .. (({ "a", "b", "c" })[scc.bd] or "a"))
        f.img(312, 432, 574, 148, scAuto and "as_mf_g_sc_r3_auto" or "as_mf_g_sc_r3_manu")
        f.ctr(533, 225, 44, "On", WH, 115)
        f.ctr(662, 225, 44, "Off", WH, 115)
        f.ctr(565, 507, 44, T("mf_auto"), WH, 180)
        f.ctr(755, 507, 44, T("mf_manual"), WH, 155)
        f.hot(470, 172, 597, 278, "mfsc_done1")
        f.hot(597, 172, 728, 278, "mfsc_done0")
        f.hot(469, 330, 592, 423, "mfsc_bd1")
        f.hot(603, 330, 727, 423, "mfsc_bd2")
        f.hot(740, 330, 866, 423, "mfsc_bd3")
        f.hot(468, 458, 663, 556, "mfsc_auto")
        f.hot(671, 458, 840, 556, "mfsc_manu")
        f.hot(736, 170, 870, 282, "page_mfsc")   -- (66e) case SC de la ligne 1 : réglages SC (écran 24)
    end
    f.ctr(542, 48, 48, tostring(g.row or 0), WH, 70)
    f.ctr(811, 48, 44, xteTxt(g), WH, 166)
    -- touches
    f.hot(0, 0, 112, 98, "page_" .. (M.BACK.gps or "mfmenu"))
    f.hot(120, 8, 258, 92, "page_mftask")   -- (04/11 nuit) document = tâche en cours, comme le vrai MF Guide
    f.hot(268, 8, 405, 92, "mfsc_menu")
    f.hot(593, 8, 712, 92, "gps_shiftL")
    f.hot(912, 8, 1033, 92, "gps_shiftR")
    f.hot(1047, 8, 1150, 92, "mfg_view")
    f.hot(1478, 4, 1660, 96, "gps_steer")
    self.headerBox = f.box(417, 0, 580, 98)
end

-- (04/11) menu Courseplay à part : case Courseplay du menu = réglages de ligne (sous-page PARCOURS)
function M.cpAction(self, a)
    local G = AS_TerminalGps
    if a == "mfcp" then
        if G ~= nil then G.sub = "course" end
        M.cpFromMenu = true
        self.page = "gps"
    else
        if G ~= nil then G.sub = nil end
        M.cpFromMenu = nil
        self.page = "mfmenu"
    end
    self.lastRead = -100000
end

-------------------------------------------------------------------------------
-- Réglages SC (écran 24) et géométrie des tronçons (écran 26) : les écrans, textes et valeurs en direct
-------------------------------------------------------------------------------
M.BACK.mfsc = "mfmenu"                 -- menu, ou MF Guide quand on vient du menu SC de la carte
M.BACKACT.mfscg = "mfscg_cancel"       -- écran 26 : la flèche retour = X (rien n'est gardé)
M.scToolIx = 1
local function scTool(self, v)
    local SC = AS_SectionControl
    if SC == nil or v == nil then return nil, 0 end
    local list = SC:tools(v)
    if #list == 0 then return nil, 0 end
    local i = ((M.scToolIx or 1) - 1) % #list + 1
    M.scToolIx = i
    return list[i], #list
end
local function objName(o)
    local ui = AS_Terminal ~= nil and AS_Terminal.ui or nil
    if ui ~= nil and ui.vehicleName ~= nil then
        local ok, n = pcall(ui.vehicleName, o)
        if ok and n ~= nil and n ~= "" then return n end
    end
    if o ~= nil and o.getFullName ~= nil then
        local ok, n = pcall(o.getFullName, o)
        if ok and n ~= nil then return n end
    end
    return "--"
end
-- « PULVÉ » -> « Pulvé » (comme son écran : « Fertilizer »)
local function cap(s)
    local first, rest = tostring(s):match("^([%z\1-\127\194-\244][\128-\191]*)(.*)$")
    if first == nil then return s end
    rest = rest:lower():gsub("\195([\128-\158])", function(ch)
        local b = ch:byte()
        if b == 151 then return nil end
        return "\195" .. string.char(b + 32)
    end)
    return first .. rest
end
local function toolKind(d, o)
    local TT = AS_TerminalTools
    if TT == nil or TT.kindLabel == nil then return "--" end
    local t
    for _, e in ipairs(d.tools or {}) do if e.o == o then t = e end end
    if t == nil and TT.kindOf ~= nil then
        local ok, k = pcall(TT.kindOf, o)
        t = { o = o, kind = ok and k or "generic", cat = "" }
    end
    local ok, k = pcall(TT.kindLabel, t)
    if ok and k ~= nil then return cap(k) end
    return "--"
end
local function meters(x, n)
    local u = H().unitsOf()
    if u ~= nil and u.imperial then return dec(x * 3.2808, n), "ft" end
    return dec(x, n), "m"
end

-- ◀ ▶ de l'écran 24 : réglage, ◀ x0 x1, ▶ x0 x1, y0 y1
M.SCSET_ST = { { "ovIn", 766, 834, 1018, 1072, 222, 316 }, { "ovBd", 1192, 1260, 1448, 1502, 222, 316 },
    { "drive", 766, 836, 1022, 1072, 414, 506 }, { "tol", 1192, 1264, 1450, 1502, 414, 506 } }
function M.scset(self, d, ctx, v, Wp, Hp)
    local f = frame(self, ctx, Wp, Hp)
    f.img(0, 0, 1672, 941, "as_mf_p_scset")
    M.topBar(self, d, f, "mfsc")
    local SC = AS_SectionControl
    local c = (SC ~= nil and v ~= nil) and SC:cfg(v) or {}
    local o = scTool(self, v)
    -- états : SC Auto / Manuel, bord du champ (dès qu'il sort / moitié / pas de bord), contrôle de rampe
    f.img(203, 511, 435, 102, c.auto == 1 and "as_mf_s24_sc_auto" or "as_mf_s24_sc_manu")
    f.img(206, 633, 431, 123, "as_mf_s24_bd_" .. (({ "a", "b", "c" })[c.bd or 1] or "a"))
    f.img(1106, 587, 405, 104, (c.boom or 1) == 1 and "as_mf_s24_bm_auto" or "as_mf_s24_bm_manu")
    f.txt(40, 138, 38, T("mf_scSelImpl"), WH, nil, 590, true)
    f.txt(64, 225, 42, o ~= nil and objName(o) or T("mf_scNone"), WH, nil, 505)
    f.txt(40, 355, 38, T("mf_scBoom"), WH, nil, 590, true)
    f.txt(64, 442, 42, o ~= nil and objName(o) or "--", WH, nil, 505)
    f.ctr(314, 562, 40, T("mf_auto"), WH, 190)
    f.ctr(529, 562, 40, T("mf_manual"), WH, 190)
    f.txt(680, 136, 38, T("mf_scOverlap"), WH, nil, 820, true)
    f.ctr(926, 194, 30, T("mf_scInField"), WH, 330, true)
    f.ctr(1354, 194, 30, T("mf_scBoundary"), WH, 330, true)
    f.ctr(928, 386, 30, T("mf_scDrive"), WH, 400, true)
    f.ctr(1356, 361, 30, T("mf_scTol1"), WH, 330, true)
    f.ctr(1356, 389, 30, T("mf_scTol2"), WH, 330, true)
    f.ctr(1306, 560, 30, T("mf_scBoomCtl"), WH, 400, true)
    f.ctr(1209, 639, 44, T("mf_auto"), WH, 180)
    f.ctr(1409, 639, 44, T("mf_manual"), WH, 180)
    local function pct(x) return string.format("%d", math.floor((x or 0) + 0.5)) end
    f.txt(866, 268, 48, pct(c.ovIn), WH, nil, 100)
    f.ctr(988, 268, 40, "%", WH, 40)
    f.txt(1292, 268, 48, c.bd == 2 and "50" or (c.bd == 3 and "--" or pct(c.ovBd)), WH, nil, 100)
    f.ctr(1416, 268, 40, "%", WH, 40)
    local dv, du = meters(c.drive or 0, 2)
    f.txt(850, 460, 46, dv, WH, nil, 128)
    f.ctr(996, 460, 40, du, WH, 40)
    local tv, tu = meters(c.tol or 0, 2)
    f.txt(1278, 460, 46, tv, WH, nil, 130)
    f.ctr(1426, 460, 40, tu, WH, 40)
    f.ctr(857, 785, 44, (o ~= nil and SC ~= nil) and tostring(SC:count(o)) or "0", WH, 140)
    -- touches
    if o ~= nil then
        f.hot(36, 183, 633, 268, "mfsc_tool")
        f.hot(36, 399, 633, 485, "mfsc_tool")
    end
    f.hot(207, 515, 421, 609, "mfsc_auto")
    f.hot(424, 517, 634, 607, "mfsc_manu")
    f.hot(210, 637, 337, 752, "mfsc_bd1")
    f.hot(361, 637, 485, 752, "mfsc_bd2")
    f.hot(508, 637, 633, 752, "mfsc_bd3")
    f.hot(206, 784, 334, 906, "page_work")    -- champ + roue dentée : carte Travail (zone faite, effacer)
    for _, e in ipairs(M.SCSET_ST) do
        f.hot(e[2], e[6], e[3], e[7], "mfsc_st_" .. e[1] .. "_-1")
        f.hot(e[4], e[6], e[5], e[7], "mfsc_st_" .. e[1] .. "_1")
    end
    f.hot(1110, 591, 1309, 687, "mfsc_boom1")
    f.hot(1311, 593, 1507, 685, "mfsc_boom0")
    f.hot(984, 604, 1086, 704, "page_mfscg")   -- clé
    M.rail(f, { { icon = "sc", on = true }, { icon = "geo", act = "page_mfscg" } })   -- onglets SC (ouvert) / géométrie
end

M.SCG_BTN = { { 146, 251 }, { 259, 365 }, { 374, 483 }, { 491, 602 }, { 611, 722 }, { 730, 842 }, { 850, 963 }, { 971, 1083 },
    { 1091, 1204 }, { 1212, 1319 }, { 1327, 1431 }, { 1439, 1542 } }
function M.scgeo(self, d, ctx, v, Wp, Hp)
    local f = frame(self, ctx, Wp, Hp)
    f.img(0, 0, 1672, 941, "as_mf_p_scgeo")
    M.topBar(self, d, f, "mfscg")
    local SC = AS_SectionControl
    local o = scTool(self, v)
    local secs, total = nil, 0
    if o ~= nil and SC ~= nil and SC.layout ~= nil then
        local ok, a, b = pcall(SC.layout, SC, o)
        if ok then secs, total = a, b or 0 end
    end
    secs = secs or {}
    local n = #secs
    M.scN = n
    local sel = math.max(1, math.min(math.max(n, 1), M.scSec or 1))
    M.scSec = sel
    local s = secs[sel]
    local u = H().unitsOf()
    local imp = u ~= nil and u.imperial
    local function m1(x)
        x = x * (imp and 3.2808 or 1)
        local r = math.floor(x * 10 + 0.5) / 10
        if r == math.floor(r) then return string.format("%d", r) end
        return dec(r, 1)
    end
    f.txt(64, 189, 44, n > 0 and string.format(T("mf_scSection"), sel) or T("mf_scNone"), WH, nil, 450)
    f.ctr(223, 305, 42, T("mf_scWidth"), WH, 420)
    f.ctr(241, 369, 44, s ~= nil and (m1(s.w) .. "/" .. m1(total) .. (imp and " ft" or " m")) or "--", WH, 330)
    f.ctr(204, 469, 42, T("mf_scInfo"), WH, 390)
    f.ctr(216, 536, 44, tostring(n), WH, 160)
    -- cases des tronçons, 12 par page ; cadre rouge = tronçon choisi ; cases en trop assombries
    local page0 = math.floor((sel - 1) / 12) * 12
    for i, bx in ipairs(M.SCG_BTN) do
        local k = page0 + i
        if k <= n then
            if k == sel then f.img(bx[1], 620, bx[2] - bx[1], 104, "as_mf_s26_btn_sel") end
            f.ctr((bx[1] + bx[2]) * 0.5, 672, 44, tostring(k), WH, bx[2] - bx[1] - 12)
            f.hot(bx[1], 620, bx[2], 724, "mfscg_sel_" .. k)
        else
            ctx.rect(f.PX(bx[1]), f.PY(620), f.PW(bx[2] - bx[1]), f.PY(104), { 0.02, 0.05, 0.12, 1 }, 0.5)
        end
    end
    f.txt(80, 824, 42, T("mf_scType"), WH, nil, 340)
    f.ctr(678, 825, 44, o ~= nil and toolKind(d, o) or "--", WH, 460)
    -- délais d'allumage / de coupure : défaut et réglé (modifié ici, gardé par OK)
    local c = (SC ~= nil and v ~= nil) and SC:cfg(v) or {}
    local e = M.scEdit or {}
    local DEF = SC ~= nil and SC.DEF or { dOn = 0.2, dOff = 0.2 }
    local rows = { { 138, 200, 203, DEF.dOn, e.dOn or c.dOn or DEF.dOn, "dOn", 166, 240 },
        { 282, 340, 348, DEF.dOff, e.dOff or c.dOff or DEF.dOff, "dOff", 311, 386 } }
    for _, r in ipairs(rows) do
        f.ctr(1165, r[1], 40, T("mf_scDefault"), WH, 220)
        f.ctr(1154, r[2], 44, dec(r[4], 2), WH, 120)
        f.ctr(1244, r[2], 32, "s", WH, 30)
        f.ctr(1504, r[1], 40, T("mf_scAdjusted"), WH, 230)
        -- (05/11) case réglée = [ - valeur + ] :
        -- boutons visibles aux deux bouts ; moitié gauche = moins, moitié droite = plus (inchangé)
        local by0, bh = r[7] + 6, r[8] - r[7] - 12
        f.img(1397, by0, 56, bh, "as_mf_btn_pm")
        f.img(1565, by0, 56, bh, "as_mf_btn_pm")
        f.ctr(1425, by0 + bh * 0.5, 50, "-", WH, 40, true)
        f.ctr(1593, by0 + bh * 0.5, 50, "+", WH, 40, true)
        f.ctr(1496, r[3], 40, dec(r[5], 2), WH, 84)
        f.ctr(1549, r[3] + 4, 26, "s", WH, 18)
        f.hot(1391, r[7], 1509, r[8], "mfscg_" .. r[6] .. "_-1")
        f.hot(1509, r[7], 1627, r[8], "mfscg_" .. r[6] .. "_1")
    end
    -- décalage de l'outil (guidage), flèche du côté du décalage
    local off = (d.gps ~= nil and tonumber(d.gps.offset)) or 0
    if off > 0.05 then f.img(1432, 438, 72, 62, "as_mf_s26_arr_r") end
    f.ctr(1468, 524, 40, (meters(math.abs(off), 1)), WH, 130)
    -- (05/11) décalage : - = vers la gauche, + = vers la droite (réglage de décalage outil de Courseplay) ; la case = zéro
    f.img(1296, 444, 88, 88, "as_mf_btn_pm2")
    f.img(1552, 444, 88, 88, "as_mf_btn_pm2")
    f.ctr(1340, 488, 60, "-", WH, 60, true)
    f.ctr(1596, 488, 60, "+", WH, 60, true)
    f.hot(1290, 438, 1392, 538, "gps_shiftL")
    f.hot(1546, 438, 1648, 538, "gps_shiftR")
    f.hot(1398, 418, 1540, 555, "gps_off0")
    f.ctr(1571, 831, 52, "OK", WH, 120, true)
    f.hot(38, 143, 576, 235, "mfscg_next")
    f.hot(32, 620, 138, 724, "mfscg_prev")
    f.hot(1550, 620, 1651, 724, "mfscg_next")
    f.hot(1343, 769, 1476, 877, "mfscg_cancel")
    f.hot(1503, 769, 1640, 893, "mfscg_ok")
end

function M.scgAction(self, a)
    local SC = AS_SectionControl
    local v = vehOf(self, self.data)
    local n = math.max(1, M.scN or 1)
    if a == "mfscg_ok" then
        if SC ~= nil and v ~= nil and M.scEdit ~= nil then
            local c = SC:cfg(v)
            for _, key in ipairs({ "dOn", "dOff" }) do
                if M.scEdit[key] ~= nil and M.scEdit[key] ~= c[key] then SC:setCfg(v, key, M.scEdit[key]) end
            end
        end
        M.scEdit = nil
        self.page = "mfsc"
    elseif a == "mfscg_cancel" then
        M.scEdit = nil
        self.page = "mfsc"
    elseif a == "mfscg_next" then M.scSec = (M.scSec or 1) % n + 1
    elseif a == "mfscg_prev" then M.scSec = ((M.scSec or 1) - 2) % n + 1
    elseif a:sub(1, 10) == "mfscg_sel_" then M.scSec = tonumber(a:sub(11)) or 1
    elseif SC ~= nil and v ~= nil then
        local key, dir = a:match("^mfscg_(d%a+)_(%-?%d)$")
        local st = key ~= nil and SC.STEPS[key] or nil
        if st ~= nil then
            M.scEdit = M.scEdit or {}
            local cur = M.scEdit[key] or SC:cfg(v)[key] or 0
            local nv = math.floor((cur + tonumber(dir) * st[3]) / st[3] + 0.5) * st[3]
            M.scEdit[key] = math.max(st[1], math.min(st[2], nv))
        end
    end
    self.lastRead = -100000
end

-------------------------------------------------------------------------------
-- (04/11 nuit) Tâches 28 / 29 : Task Controller du Datatronic, sur les 2 compteurs de tâche du terminal
--   menu ☰ > Isobus ; document = Compteurs 06 ; bouton arbre = vue liste (28) / vue arbre (29)
--   Tâche ▾ = tâche suivante (1 / 2) ; dossier = nouvelle tâche (compteurs à zéro, avec confirmation)
--   TC On / Off : Off = la tâche ne compte plus ; pause / enregistrement ; filtre On = la tâche ne compte
--   que sur son champ ; Champ ▾ = champ où est le tracteur (2e appui = aucun) ; N/A ▾ = produit de l'outil
--   (nuage et USB retirés de l'image : pas de fonction dans le jeu)
-------------------------------------------------------------------------------
M.BACK.mftask = "mfmenu"
M.tkView = "list"
M.tkPop = nil        -- nil, "new" ou 1-4 (bouton i de la vue arbre)

local function tkJob(d)
    local c = d.cnt or {}
    return (c.jobs or {})[c.active or 1] or {}, c.total or {}, c
end
local function hms(ms)
    local s = math.floor((ms or 0) / 1000)
    return string.format("%dh %dmin %ds", math.floor(s / 3600), math.floor(s / 60) % 60, s % 60)
end
local function distTxt(m)
    m = math.max(0, m or 0)
    local u = H().unitsOf()
    if u ~= nil and u.imperial then
        local ft = m * 3.2808
        if ft < 5280 then return string.format("%d ft", math.floor(ft + 0.5)) end
        return dec(ft / 5280, 2) .. " mi"
    end
    if m < 1000 then return string.format("%d m", math.floor(m + 0.5)) end
    return dec(m / 1000, 2) .. " km"
end
local function fuelTxt(l)
    local u = H().unitsOf()
    return dec(u and u.l(math.max(0, l or 0)) or math.max(0, l or 0), 1) .. " " .. (u and u.vol or "L")
end
local function areaTxt(ha)
    local u = H().unitsOf()
    return dec(u and u.ha(ha or 0) or (ha or 0), 2) .. " " .. (u and u.area or "ha")
end
local function pairTxt(a, b, fn) return fn(a) .. " / " .. fn(math.max(0, b)) end

-- compteurs de la vue liste : nom, valeur
M.TK_ROWS = {
    { "mf_tkFuelW", function(j, t) return pairTxt(j.fuelW or 0, (j.fuel or 0) - (j.fuelW or 0), fuelTxt) end },
    { "mf_tkFuel", function(j, t) return fuelTxt(j.fuel) end },
    { "mf_tkTime", function(j, t) return pairTxt(j.msW or 0, (j.ms or 0) - (j.msW or 0), hms) end },
    { "mf_tkTimeL", function(j, t) return pairTxt(t.msW or 0, (t.ms or 0) - (t.msW or 0), hms) end },
    { "mf_tkDist", function(j, t) return pairTxt(j.distW or 0, (j.dist or 0) - (j.distW or 0), distTxt) end },
    { "mf_tkDistL", function(j, t) return pairTxt(t.distW or 0, (t.dist or 0) - (t.distW or 0), distTxt) end },
    { "mf_tkArea", function(j, t) return areaTxt(j.ha) end },
}
-- repères de l'écran 28 (nom, valeur, x) et 29
M.TK_LIST = { { 342, 372, 328 }, { 424, 453, 330 }, { 500, 531, 333 }, { 578, 609, 337 }, { 656, 687, 337 }, { 737, 767, 340 }, { 815, 848, 343 } }
M.TK_TREE = { { 700, 729, 328 }, { 776, 808, 327 } }
M.TK_I = { { 758, 318, 855, 387 }, { 758, 390, 855, 460 }, { 758, 463, 855, 533 }, { 758, 537, 855, 607 } }

local function safe(fn, ...)
    if fn == nil then return nil end
    local ok, r = pcall(fn, ...)
    if ok then return r end
    return nil
end
local function farmName(id)
    if id == nil or id == 0 or g_farmManager == nil then return nil end
    local farm = safe(g_farmManager.getFarmById, g_farmManager, id)
    return farm ~= nil and farm.name or nil, farm
end
local function npcTitle(npc)
    if npc == nil then return nil end
    return npc.title or npc.name
end
local function fieldByNumber(n)
    local U = AS_Terminal.ui
    local fm = g_fieldManager
    if n == nil or fm == nil or U == nil then return nil end
    local list = (fm.getFields ~= nil and safe(fm.getFields, fm)) or fm.fields or {}
    for _, f in pairs(list) do
        if type(f) == "table" and U.fieldNumber(f) == n then return f end
    end
    return nil
end
local tkProbe = nil
local function cropOf(f)
    if f == nil or FieldState == nil or FieldState.new == nil or f.posX == nil then return nil end
    if tkProbe == nil then tkProbe = safe(FieldState.new) end
    if tkProbe == nil or not pcall(tkProbe.update, tkProbe, f.posX, f.posZ) then return nil end
    local idx = tkProbe.fruitTypeIndex
    if idx == nil or idx == 0 or (FruitType ~= nil and idx == FruitType.UNKNOWN) or g_fruitTypeManager == nil then return nil end
    local fr = safe(g_fruitTypeManager.getFruitTypeByIndex, g_fruitTypeManager, idx)
    if fr == nil then return nil end
    return (fr.fillType ~= nil and fr.fillType.title) or fr.name
end

-- tout ce que montre la vue arbre (relu avec les données du terminal, pas à chaque image)
function M.tkInfo(self, d, v)
    if M.tkD == d and M.tkI ~= nil then return M.tkI end
    local job = tkJob(d)
    local I = {}
    I.n = job.field or d.field
    local fld = job.field ~= nil and fieldByNumber(job.field) or nil
    if fld == nil and job.field == nil and v ~= nil and v.rootNode ~= nil and AS_Terminal.ui ~= nil then
        local x, _, z = getWorldTranslation(v.rootNode)
        fld = AS_Terminal.ui.fieldAt(x, z)
    end
    I.ha = fld ~= nil and tonumber(fld.areaHa) or nil
    I.crop = cropOf(fld)
    -- propriétaire du champ : ferme, sinon le voisin (PNJ) qui le possède
    local fl = fld ~= nil and fld.farmland or nil
    if fl ~= nil then
        local owner = g_farmlandManager ~= nil and safe(g_farmlandManager.getFarmlandOwner, g_farmlandManager, fl.id) or nil
        I.owner = farmName(owner)
        if I.owner == nil and g_npcManager ~= nil and fl.npcIndex ~= nil then
            I.owner = npcTitle(safe(g_npcManager.getNPCByIndex, g_npcManager, fl.npcIndex))
        end
    end
    -- client : contrat en cours sur le champ
    local ms = fld ~= nil and fld.currentMission or nil
    if ms == nil and fld ~= nil and g_missionManager ~= nil and fld.posX ~= nil then
        ms = safe(g_missionManager.getMissionAtWorldPosition, g_missionManager, fld.posX, fld.posZ)
    end
    if ms ~= nil then
        I.client = npcTitle(safe(ms.getNPC, ms)) or safe(ms.getTitle, ms)
        I.mTitle = safe(ms.getTitle, ms)
        I.mReward = tonumber(safe(ms.getReward, ms) or ms.reward)
        I.mDone = tonumber(safe(ms.getCompletion, ms))
    end
    -- ferme et conducteur du tracteur
    local fid = v ~= nil and safe(v.getOwnerFarmId, v) or nil
    I.farm, I.farmObj = farmName(fid)
    local drv = v ~= nil and safe(v.getControllerName, v) or nil
    if (drv == nil or drv == "") and g_currentMission ~= nil then drv = g_currentMission.playerNickname end
    I.driver = (drv ~= nil and drv ~= "") and drv or nil
    -- produit de l'outil (semence, engrais...) : 1er remplissage qui n'est pas vide
    for _, t in ipairs(d.tools or {}) do
        for _, fu in ipairs(t.fills or {}) do
            if I.product == nil and (fu.level or 0) > 0.5 and fu.title ~= nil then I.product = fu.title end
        end
    end
    M.tkD, M.tkI = d, I
    return I
end

local POP_EDGE = { 0.20, 0.42, 0.75, 1 }
local POP_BG = { 0.04, 0.10, 0.23, 1 }
local RED = { 0.86, 0.16, 0.30, 1 }
local function popup(f, title, lines)
    -- par-dessus TC, filtre, champ et produit (leurs textes ne sont pas écrits pendant ce temps)
    f.rect(968, 128, 538, 616, POP_EDGE)
    f.rect(972, 132, 530, 608, POP_BG)
    f.ctr(1237, 205, 42, title, WH, 500, true)
    for i, s in ipairs(lines) do f.ctr(1237, 205 + i * 85, 34, s, DIM, 510) end
end

function M.task(self, d, ctx, v, Wp, Hp)
    local f = frame(self, ctx, Wp, Hp)
    local tree = M.tkView == "tree"
    f.img(0, 0, 1672, 941, tree and "as_mf_p_tasktree" or "as_mf_p_task")
    M.topBar(self, d, f, "mftask")
    -- onglet tâches (ouvert) : un appui = nouvelle tâche (pas sous une fenêtre ouverte)
    M.rail(f, { { icon = "folder", on = true, act = M.tkPop == nil and "mftk_new" or nil } })
    local job, tot, c = tkJob(d)
    local I = M.tkInfo(self, d, v)
    -- gauche : tâche, compteurs (liste) ou champ / ferme / client / ferme / conducteur / tracteur (arbre)
    f.txt(175, 164, 50, string.format(T("mf_tkTask"), c.active or 1), WH, nil, 520)
    local function counter(r, k)
        local row = M.TK_ROWS[k]
        f.txt(r[3], r[1], 24, T(row[1]), WH, nil, 790 - r[3])
        f.txt(r[3], r[2], 30, row[2](job, tot), WH, nil, 790 - r[3])
    end
    if tree then
        f.ctr(484, 274, 36, I.n ~= nil and string.format(T("mf_tkFieldN"), tostring(I.n)) or T("mf_tkNoField"), WH, 470)
        f.ctr(518, 348, 34, I.owner or T("mf_tkForSale"), WH, 420)
        f.ctr(518, 421, 34, I.client or T("mf_tkNoContract"), WH, 420)
        f.ctr(492, 493, 34, I.farm or "--", WH, 470)
        f.ctr(501, 566, 34, I.driver or "--", WH, 470)
        f.ctr(507, 641, 36, d.name or "--", WH, 470)
        for k, r in ipairs(M.TK_TREE) do counter(r, k) end
        for i, b in ipairs(M.TK_I) do f.hot(b[1], b[2], b[3], b[4], "mftk_i" .. i) end
    else
        f.ctr(488, 279, 36, d.name or "--", WH, 500)
        for k, r in ipairs(M.TK_LIST) do counter(r, k) end
    end
    f.hot(40, 110, 140, 215, "page_count")
    f.hot(160, 122, 773, 203, "mftk_task")
    f.hot(798, 116, 920, 241, "mftk_view")
    -- droite : TC, filtre, champ, produit, pause / enregistrement (cachés sous une fenêtre ouverte)
    local tcOn = c.tc ~= false
    f.img(1104, 140, 350, 108, tcOn and "as_mf_s28_tc_on" or "as_mf_s28_tc_off")
    f.img(1107, 347, 347, 107, job.flt and "as_mf_s28_flt_on" or "as_mf_s28_flt_off")
    f.img(1096, 763, 323, 109, (not tcOn) and "as_mf_s28_rec_off" or (c.pause and "as_mf_s28_rec_pause" or "as_mf_s28_rec_rec"))
    if M.tkPop == nil then
        f.ctr(1043, 194, 52, "TC", WH, 90, true)
        f.ctr(1191, 194, 44, "On", WH, 150)
        f.ctr(1364, 194, 44, "Off", WH, 150)
        f.ctr(1195, 401, 44, "On", WH, 150)
        f.ctr(1366, 401, 44, "Off", WH, 150)
        f.txt(1025, 511, 40, job.field ~= nil and string.format(T("mf_tkFieldN"), tostring(job.field)) or T("mf_tkField"), WH, nil, 370)
        f.txt(1028, 607, 40, I.product or "N/A", WH, nil, 370)
        f.hot(1106, 142, 1277, 246, "mftk_tc1")
        f.hot(1278, 142, 1452, 246, "mftk_tc0")
        f.hot(1109, 349, 1282, 452, "mftk_flt1")
        f.hot(1283, 349, 1452, 452, "mftk_flt0")
        f.hot(1006, 472, 1452, 552, "mftk_field")
        f.hot(1098, 765, 1257, 870, "mftk_pause")
        f.hot(1258, 765, 1417, 870, "mftk_rec")
        return
    end
    -- fenêtre : nouvelle tâche (X / OK) ou infos du bouton i
    if M.tkPop == "new" then
        popup(f, T("mf_tkNew"), { string.format(T("mf_tkNewQ"), c.active or 1) })
        f.hot(968, 128, 1506, 744, "mftk_close")
        f.rect(1010, 590, 210, 120, RED)
        f.rect(1254, 590, 210, 120, GREEN)
        f.ctr(1115, 650, 56, "X", WH, 120, true)
        f.ctr(1359, 650, 52, "OK", WH, 140, true)
        f.hot(1010, 590, 1220, 710, "mftk_close")
        f.hot(1254, 590, 1464, 710, "mftk_newok")
        return
    end
    local money = function(x)
        local s = i18n("formatMoney", x, 0, true, true)
        return s or string.format("%d", math.floor(x + 0.5))
    end
    local k = M.tkPop
    local title, lines = "", {}
    if k == 1 then
        title = I.n ~= nil and string.format(T("mf_tkFieldN"), tostring(I.n)) or T("mf_tkNoField")
        if I.ha ~= nil then lines[#lines + 1] = string.format(T("mf_tkAreaV"), areaTxt(I.ha)) end
        lines[#lines + 1] = string.format(T("mf_tkOwner"), I.owner or T("mf_tkForSale"))
        if I.crop ~= nil then lines[#lines + 1] = string.format(T("mf_tkCrop"), I.crop) end
    elseif k == 2 then
        title = I.client or T("mf_tkNoContract")
        if I.mTitle ~= nil and I.mTitle ~= title then lines[#lines + 1] = I.mTitle end
        if I.mReward ~= nil then lines[#lines + 1] = string.format(T("mf_tkReward"), money(I.mReward)) end
        if I.mDone ~= nil then lines[#lines + 1] = string.format(T("mf_tkProgress"), math.floor(I.mDone * 100 + 0.5)) end
    elseif k == 3 then
        title = I.farm or "--"
        if I.farmObj ~= nil and I.farmObj.money ~= nil then lines[#lines + 1] = string.format(T("mf_tkMoney"), money(I.farmObj.money)) end
    else
        title = string.format(T("mf_tkDriver"), I.driver or "--")
        lines[#lines + 1] = string.format(T("mf_tkDriving"), d.name or "--")
        local st = (not tcOn) and "mf_tkTcOff" or (c.pause and "mf_tkPaused" or "mf_tkRec")
        lines[#lines + 1] = string.format(T(st), c.active or 1)
    end
    popup(f, title, lines)
    f.hot(968, 128, 1506, 744, "mftk_close")
end

function M.tkAction(self, a)
    local d = self.data
    if d == nil or d.cnt == nil then return end
    local c = d.cnt
    local job = c.jobs[c.active or 1]
    if a == "mftk_view" then M.tkView = M.tkView == "tree" and "list" or "tree"; M.tkPop = nil
    elseif a == "mftk_task" then c.active = 3 - (c.active or 1); c.fldAt = nil; M.tkPop = nil
    elseif a == "mftk_tc1" then c.tc = true
    elseif a == "mftk_tc0" then c.tc = false
    elseif a == "mftk_pause" then if c.tc ~= false then c.pause = true end
    elseif a == "mftk_rec" then c.tc = true; c.pause = false
    elseif a == "mftk_flt1" and job ~= nil then job.flt = true; c.fldAt = nil
    elseif a == "mftk_flt0" and job ~= nil then job.flt = false
    elseif a == "mftk_field" and job ~= nil then
        if d.field ~= nil and d.field ~= job.field then job.field = d.field else job.field = nil end
        c.fldAt = nil
    elseif a == "mftk_new" then M.tkPop = "new"
    elseif a == "mftk_newok" then M.tkPop = nil; return self:doAction("reset")
    elseif a == "mftk_close" then M.tkPop = nil
    else
        local i = tonumber(a:match("^mftk_i(%d)$") or "")
        if i ~= nil then if M.tkPop == i then M.tkPop = nil else M.tkPop = i end end
    end
    M.tkD = nil
end

-------------------------------------------------------------------------------
-- (04/11 nuit) Caméra (case du menu) : caméra arrière du terminal (comme le Case), en grand sur le fond bleu ;
-- image vivante dans la grande fenêtre (l'écran 3D de la cabine reste noir) ; toucher = marche / arrêt
-------------------------------------------------------------------------------
M.BACK.mfcam = "mfmenu"
function M.cam(self, d, ctx, v, Wp, Hp)
    local f = frame(self, ctx, Wp, Hp)
    f.img(0, 0, 1672, 941, "as_mf_p_blank")
    M.topBar(self, d, f, "mfcam")
    local bx, by, bw, bh = 40, 122, 1592, 792
    f.rect(bx, by, bw, bh, { 0, 0, 0, 1 })
    local P = self.REAR_CAM or { resX = 16, resY = 9 }
    local cw = bw - 20
    local ch = cw * P.resY / P.resX
    if ch > bh - 20 then ch = bh - 20; cw = ch * P.resX / P.resY end
    local cx, cy = bx + (bw - cw) * 0.5, by + (bh - ch) * 0.5
    if ctx.rec ~= nil then
        f.ctr(bx + bw * 0.5, by + bh * 0.5, 40, T("mf_camBig"), DIM, bw - 80)
        return
    end
    f.hot(bx, by, bx + bw, by + bh, "rearcam")
    if self.settings.rearCam ~= false then
        local ov = self.rearCamOverlay ~= nil and self:rearCamOverlay(v) or nil
        if ov ~= nil then ctx.image(f.PX(cx), f.PY(cy), f.PW(cw), f.PY(ch), ov) end
    else
        f.ctr(bx + bw * 0.5, by + bh * 0.5, 40, T("c_camOff"), WH, bw - 80)
    end
end

-------------------------------------------------------------------------------
-- (05/11) page Éclairage (case du menu) :
-- le tracteur vu de dessus de l'accueil Case, détouré sur le fond bleu (as_mf_light_tractor, mf/build_light.py),
-- les boutons de feux 1 à 8 et le gyrophare aux mêmes places et dans le même ordre que sur le Case
-- (AS_Terminal.HOME_LAMPS) ; Mem 1 = tout allumer, Mem 2 = tout éteindre.
-------------------------------------------------------------------------------
M.BACK.mflight = "mfmenu"
M.LT_X, M.LT_Y, M.LT_S = 98, 232, 1.6          -- coin haut gauche du tracteur sur la page et échelle
M.LT_CROP = { 345 + 54 + 30, 94 + 226 + 32 }   -- coin du recadrage en pixels de l'accueil Case (bloc 4 à 345,94 ; cadre 54,226 ; recadré 30,32)
M.LT_W, M.LT_H = 922, 428
M.LT_MEM = { { 1176, 120, 1396, 212, "l_mem1", "Mem 1" }, { 1412, 120, 1632, 212, "l_mem2", "Mem 2" } }
function M.ltBox(l)
    local s, c = M.LT_S, M.LT_CROP
    return M.LT_X + (l[3] - c[1]) * s, M.LT_Y + (l[4] - c[2]) * s, (l[5] - l[3]) * s, (l[6] - l[4]) * s
end
function M.light(self, d, ctx, v, Wp, Hp)
    local f = frame(self, ctx, Wp, Hp)
    f.img(0, 0, 1672, 941, "as_mf_p_blank")
    M.topBar(self, d, f, "mflight")
    f.txt(40, 160, 38, T("mf_lTitle"), WH, nil, 700, true)
    f.img(M.LT_X, M.LT_Y, M.LT_W * M.LT_S, M.LT_H * M.LT_S, "as_mf_light_tractor")
    for _, l in ipairs(AS_Terminal.HOME_LAMPS or {}) do
        local x, y, w, h = M.ltBox(l)
        local on = AS_Terminal.lightOn ~= nil and AS_Terminal:lightOn(d, l[2]) or false
        local n = l[2] == "beacon" and "beacon" or l[1]
        f.img(x, y, w, h, "as_case_lamp_" .. n .. (on and "_on" or "_off"))
        f.hot(x, y, x + w, y + h, "l_" .. l[2])
    end
    for _, b in ipairs(M.LT_MEM) do
        f.img(b[1], b[2], b[3] - b[1], b[4] - b[2], "as_mf_light_mem")
        f.ctr((b[1] + b[3]) * 0.5, (b[2] + b[4]) * 0.5, 40, b[6], WH, b[3] - b[1] - 30)
        f.hot(b[1], b[2], b[3], b[4], b[5])
    end
end

-------------------------------------------------------------------------------
-- (05/11) page Distributeurs
-- (cases Joystick et Hydraulique du menu, ou appui sur une case sans fonction de l'accueil) : les 6 cases de son
-- accueil (as_mf_vt_N, mf/build_valves.py) ; la case choisie (cadre rouge) montre ses fonctions (jusqu'à 3,
-- fonction + état voulu) ; une case touchée ouvre la liste AV | AR | Les deux (mêmes fonctions que le Case) ;
-- APPLIQUER = l'appui sur la case de l'accueil.
-------------------------------------------------------------------------------
M.BACK.mfvalve = "mfmenu"
M.vSel = 3
M.VT_X, M.VT_Y, M.VT_W, M.VT_H = { 288, 474, 660, 846, 1032, 1218 }, 118, 166, 202
M.VS_X, M.VS_W, M.VS_H, M.VS_Y = 60, 1100, 96, { 410, 522, 634 }
M.VOK = { 1220, 410, 1600, 506 }
local SLATE = { 0.25, 0.35, 0.52, 1 }
local VHEAD = { 0.07, 0.16, 0.32, 1 }
local VBACK = { 0.03, 0.08, 0.18, 1 }
local VGREEN = { 0.30, 0.70, 0.02, 1 }
function M.valve(self, d, ctx, v, Wp, Hp)
    local f = frame(self, ctx, Wp, Hp)
    f.img(0, 0, 1672, 941, "as_mf_p_blank")
    M.topBar(self, d, f, "mfvalve")
    local sel = math.max(1, math.min(#M.VALVES, M.vSel or 3))
    M.vSel = sel
    local va = M.VALVES[sel]
    local idx = va[4]
    local rem = (v ~= nil and self.remoteFns ~= nil) and self:remoteFns(v) or {}
    local fns = rem[idx] or {}
    local m = self.remoteMenu
    local menu = m ~= nil and m.i == idx and m.k >= 1 and m.k <= (self.REMOTE_SLOTS or 3)
    if not menu then self.remoteMenu = nil end
    -- les 6 cases (textes seulement sans la liste : les textes passent toujours par-dessus les images)
    for i, t in ipairs(M.VALVES) do
        local x = M.VT_X[i]
        if i == sel then
            f.rect(x - 7, M.VT_Y - 7, M.VT_W + 14, 6, RED); f.rect(x - 7, M.VT_Y + M.VT_H + 1, M.VT_W + 14, 6, RED)
            f.rect(x - 7, M.VT_Y - 1, 6, M.VT_H + 2, RED); f.rect(x + M.VT_W + 1, M.VT_Y - 1, 6, M.VT_H + 2, RED)
        end
        f.img(x, M.VT_Y, M.VT_W, M.VT_H, "as_mf_vt_" .. i)
        f.hot(x, M.VT_Y, x + M.VT_W, M.VT_Y + M.VT_H, "mfv_sel_" .. i)
        if not menu then
            local tf = rem[t[4]] or {}
            f.ctr(x + M.VT_W * 0.5, M.VT_Y + 27, 34, t[1], DK, M.VT_W - 16)
            M.valveLabel(self, f, x + M.VT_W * 0.5, M.VT_Y + 170, M.VT_W - 6, tf, t)
        end
    end
    -- fonctions de la case choisie
    if not menu then f.txt(M.VS_X, 372, 36, va[1] .. "  |  " .. T("mf_vFns"), WH, nil, 1100, true) end
    for k = 1, self.REMOTE_SLOTS or 3 do
        local y = M.VS_Y[k]
        local fn = fns[k]
        if fn ~= nil or k == #fns + 1 then
            f.img(M.VS_X, y, M.VS_W, M.VS_H, fn ~= nil and "as_mf_vslot" or "as_mf_vslot_e")
            f.hot(M.VS_X, y, M.VS_X + M.VS_W, y + M.VS_H, "rfn_" .. idx .. "_" .. k)
            if not menu then
                if fn ~= nil then f.ctr(M.VS_X + M.VS_W * 0.5, y + M.VS_H * 0.5, 40, self:remoteLabel(fn), WH, M.VS_W - 60)
                else f.ctr(M.VS_X + M.VS_W * 0.5, y + M.VS_H * 0.5, 60, "+", WH, 80, true) end
            end
        end
    end
    if #fns > 0 then
        f.img(M.VOK[1], M.VOK[2], M.VOK[3] - M.VOK[1], M.VOK[4] - M.VOK[2], "as_mf_btn_ok")
        f.hot(M.VOK[1], M.VOK[2], M.VOK[3], M.VOK[4], "rem_" .. idx)
        if not menu then f.ctr((M.VOK[1] + M.VOK[3]) * 0.5, (M.VOK[2] + M.VOK[4]) * 0.5, 40, T("c_apply"), WH, M.VOK[3] - M.VOK[1] - 30, true) end
    end
    if not menu then
        f.txt(M.VS_X, 790, 30, (va[1] == "FV1" and #fns == 0) and T("mf_vFv1Def") or T("mf_vHelp"), DIM, nil, 1540)
        return
    end
    -- liste : AV | AR | Les deux, Aucun en bas
    local curFn = fns[m.k] or "none"
    local x0, y0, cw, cg, rh = 40, 114, 524, 10, 64
    local nR = #self.REMOTE_FNS - 1
    local tw = cw * 3 + cg * 2
    f.rect(x0 - 8, y0 - 8, tw + 16, rh * (nR + 2) + 16, VBACK)
    local heads = { { T("c_colF"), "@f" }, { T("c_colR"), "@r" }, { T("c_colB"), "" } }
    for c, hd in ipairs(heads) do
        local cx = x0 + (c - 1) * (cw + cg)
        f.rect(cx, y0, cw, rh - 3, VHEAD)
        f.ctr(cx + cw * 0.5, y0 + rh * 0.5, 32, hd[1], WH, cw - 20, true)
        for j = 2, #self.REMOTE_FNS do
            local fn = self.REMOTE_FNS[j] .. hd[2]
            local ry = y0 + (j - 1) * rh
            f.rect(cx, ry, cw, rh - 3, curFn == fn and VGREEN or SLATE)
            f.hot(cx, ry, cx + cw, ry + rh, "rsel_" .. idx .. "_" .. m.k .. "_" .. fn)
            f.txt(cx + 16, ry + rh * 0.5, 30, self:remoteLabel(fn, true), WH, nil, cw - 30)
        end
    end
    local ny = y0 + (nR + 1) * rh
    f.rect(x0, ny, tw, rh - 3, curFn == "none" and VGREEN or SLATE)
    f.hot(x0, ny, x0 + tw, ny + rh, "rsel_" .. idx .. "_" .. m.k .. "_none")
    f.ctr(x0 + tw * 0.5, ny + rh * 0.5, 30, T("none"), WH, tw - 40)
end

-- point d'entrée (drawPanel)
function M.screenFor(self)
    local p = self.page
    if p == "home" then return M.home end
    if p == "mfmenu" then return M.menu end
    if p == "count" then return M.count end
    if p == "gps" then return M.guide end
    if p == "mfacc" then return M.acc end
    if p == "mfset" then return M.set end
    if p == "mflic" then return M.lic end
    if p == "mfinfo" then return M.info end
    if p == "mfsc" then return M.scset end
    if p == "mfscg" then return M.scgeo end
    if p == "mftask" then return M.task end
    if p == "mfcam" then return M.cam end
    if p == "mflight" then return M.light end
    if p == "mfvalve" then return M.valve end
    if type(p) == "string" and (p:match("^mfw%d$") or p:match("^mfgw%d$")) then return M.wid end
    return M.page
end

-- (04/11) appuis « mfw_<n> » (choix d'un widget) ; le reste passe au terminal
if AS_Terminal ~= nil and AS_Terminal.doAction ~= nil and not M.hooked then
    M.hooked = true
    local orig = AS_Terminal.doAction
    AS_Terminal.doAction = function(self, a, ...)
        if type(a) == "string" and a:sub(1, 4) == "mfw_" then return M.widgetAction(self, a) end
        if a == "mfg_zoom" or a == "mfg_view" then return M.guideAction(self, a) end
        if a == "mfcp" or a == "mfcp_back" then return M.cpAction(self, a) end
        if a == "guide" and self.page == "mfmenu" then M.cpFromMenu = nil; if AS_TerminalGps ~= nil then AS_TerminalGps.sub = nil end end
        if type(a) == "string" and a:sub(1, 5) == "mfsc_" then return M.scAction(self, a) end
        if type(a) == "string" and a:sub(1, 6) == "mfscg_" then return M.scgAction(self, a) end
        if type(a) == "string" and a:sub(1, 5) == "mftk_" then return M.tkAction(self, a) end
        if type(a) == "string" and (a:sub(1, 8) == "mfv_sel_" or a:sub(1, 9) == "mfv_open_") then
            local open = a:sub(1, 9) == "mfv_open_"
            M.vSel = tonumber(a:match("(%d+)$")) or M.vSel
            self.remoteMenu = nil
            if open then
                M.BACK.mfvalve = self.page == "home" and "home" or "mfmenu"
                self.page = "mfvalve"
            end
            self.lastRead = -100000
            return
        end
        if a == "page_mfvalve" and self.page ~= "mfvalve" then M.BACK.mfvalve = self.page == "home" and "home" or "mfmenu"; self.remoteMenu = nil end
        if a == "page_mftask" then
            M.tkPop = nil
            if self.page ~= "count" then M.BACK.mftask = self.page == "gps" and "gps" or "mfmenu" end
        end
        if a == "page_mfsc" and self.page ~= "mfscg" and self.page ~= "mfsc" then
            M.BACK.mfsc = self.page == "gps" and "gps" or "mfmenu"
            M.scMenu = false
        end
        if a == "page_mfscg" then M.scEdit = nil end
        return orig(self, a, ...)
    end
end
