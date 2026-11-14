-- AutoSwitch : terminal des tracteurs Fendt (FendtONE onboard, thème clair)
-- Fichier chargé par AutoSwitch.lua après Terminal.lua.
--
-- (05/11) même méthode que le Massey : les écrans HD (refaits d'après les vidéos
-- « Fendt erklärt FendtONE onboard »), intégrés tels quels ; titres et valeurs écrits en direct (FR / EN / DE).
--   Châssis fixe = bandeau vert du haut et barre sombre du bas de son accueil 01.
--   Accueil = 2 pages de 6 tuiles (01, 02) ; ⇆ de la barre du bas = page suivante.
--   ☰ = Launchpad (03) : chaque icône ouvre sa page ; pages = les écrans 04 à 14, réduits entre les deux barres.
-- Repères en pixels des écrans 1672 x 941 (accueil) ; pages : pixels de l'écran, avant réduction.

AS_TerminalFendt = {}
local M = AS_TerminalFendt
M.MOD_NAME = g_currentModName

local WH = { 1, 1, 1, 1 }
local DK = { 0.13, 0.14, 0.15, 1 }
local GREY = { 0.42, 0.44, 0.47, 1 }
local GREEN = { 0.40, 0.66, 0.10, 1 }
local CARD = { 0.93, 0.94, 0.95, 1 }
local TRACK = { 0.70, 0.73, 0.78, 1 }
local FILL = { 0.17, 0.19, 0.22, 1 }
local BOXC = { 0.36, 0.38, 0.42, 1 }
local OFF = { 0.97, 0.98, 0.99, 0.62 }
local GRN = { 0.47, 0.76, 0.12, 1 }
local function clamp01(t) return math.max(0, math.min(1, t or 0)) end
-- vitesse maxi du tracteur (pour l'échelle des barres de vitesse)
local function vTop(v, d)
    local cc = v ~= nil and v.spec_drivable ~= nil and v.spec_drivable.cruiseControl or nil
    local top = cc ~= nil and tonumber(cc.maxSpeed) or nil
    if top == nil or top < 5 then top = d.maxSpeed end
    if top == nil or top < 5 then top = 50 end
    return top
end
M.mem2 = {}
local function mem2Of(v, d) return M.mem2[v] or math.floor(vTop(v, d) * 0.5 + 0.5) end

-- géométrie des pages (build_fd.py) : bandeau 0..74, barre du bas 866..941, page réduite de S, centrée
M.TOP, M.BOT = 74, 866
M.S = (M.BOT - M.TOP) / (941 - M.TOP)
M.OX = (1672 - 1672 * M.S) / 2

-- page d'où l'on vient (X / flèche retour)
M.BACK = { fdlaunch = "home", fdhitchset = "fdhitchr", fdrem = "fdvalve", fdcomp = "fdcomplist", fdtms = "fdmotor" }
M.homePage = 1

local function H() return AS_Terminal.MFH end
local function T(key) return H().T(key) end

-- dessin : accueil = pixels de l'image ; page (pg = true) = pixels de son écran, réduits entre les barres
local function frame(self, ctx, Wp, Hp, pg)
    local kx, ky = Wp / self.HOME_W, Hp / self.HOME_H
    local s = pg and M.S or 1
    local ox = pg and M.OX or 0
    local oy = pg and (M.TOP - M.TOP * M.S) or 0
    local f = {}
    function f.PX(x) return (ox + x * s) * kx end
    function f.PY(y) return (oy + y * s) * ky end
    function f.PW(w) return w * s * kx end
    function f.PH(h) return h * s * ky end
    function f.img(x, y, w, h, name)
        local file = H().caseImg(name)
        ctx.image(f.PX(x), f.PY(y), f.PW(w), f.PH(h), ctx.rec == nil and AS_TerminalTools ~= nil and AS_TerminalTools:overlay(file) or nil, "img_" .. name, file)
    end
    function f.txt(x, ymid, size, str, col, align, maxW, bold)
        ctx.text(f.PX(x), f.PY(ymid + size * 0.36), f.PH(size), str, col or DK, align or RenderText.ALIGN_LEFT, bold == true, maxW and f.PW(maxW) or nil)
    end
    function f.ctr(x, ymid, size, str, col, maxW, bold) f.txt(x, ymid, size, str, col, RenderText.ALIGN_CENTER, maxW, bold) end
    function f.rgt(x, ymid, size, str, col, maxW, bold) f.txt(x, ymid, size, str, col, RenderText.ALIGN_RIGHT, maxW, bold) end
    local hot = ctx.hotspot or ctx.button
    function f.hot(x0, y0, x1, y1, action) hot(f.PX(x0), f.PY(y0), f.PW(x1 - x0), f.PH(y1 - y0), action) end
    function f.rect(x, y, w, h, c)
        -- (05/11) écran 3D de la cabine : pas de transparence (un voile devient un carré plein)
        if ctx.rec ~= nil and (c[4] or 1) < 0.99 then return end
        ctx.rect(f.PX(x), f.PY(y), f.PW(w), f.PH(h), c)
    end
    function f.box(x0, y0, x1, y1)
        if ctx.X == nil then return nil end
        return { x = ctx.X(f.PX(x0)), y = ctx.Y(f.PY(y1)), w = ctx.sx(f.PW(x1 - x0)), h = ctx.sy(f.PH(y1 - y0)) }
    end
    return f
end

local function dec(v, n)
    local s = string.format("%." .. (n or 1) .. "f", v or 0)
    if g_languageShortName ~= "en" then s = s:gsub("%.", ",") end
    return s
end
local function hm(ms)
    local m = math.floor((ms or 0) / 60000)
    return string.format("%d:%02d", math.floor(m / 60), m % 60)
end
local function pct(h) return (h ~= nil and h.object ~= nil) and (H().hitchPct(h) .. " %") or "--" end

-------------------------------------------------------------------------------
-- Châssis : bandeau du haut et barre du bas (fixes)
-------------------------------------------------------------------------------
function M.topBar(self, d, f, page)
    -- icônes de son bandeau : antenne = guidage, joystick = distributeurs, tracteur = moteur, écran = outil (Isobus),
    -- lecture = FarmPilot, FENDT = accueil, profil = réglages du terminal, ☰ = Launchpad
    f.hot(275, 0, 345, 72, "guide")
    f.hot(355, 0, 420, 72, "page_fdvalve")
    f.hot(430, 0, 510, 72, "page_fdmotor")
    f.hot(515, 0, 595, 72, "page_tool")
    local fpOk = AS_TerminalFp ~= nil and AS_TerminalFp.available ~= nil and AS_TerminalFp:available(f.v) == true
    if fpOk then f.hot(605, 0, 675, 72, "page_fp") end
    f.hot(715, 0, 965, 72, "page_home")
    f.hot(1190, 0, 1270, 72, "page_set")
    f.hot(1540, 0, 1672, 72, page == "fdlaunch" and "page_home" or "page_fdlaunch")
    -- haut-parleur = bips du terminal (trait rouge dessous quand coupés) ; téléphone = réglages du terminal
    f.hot(90, 0, 170, 72, "beeps")
    if self.settings ~= nil and self.settings.beeps == false then f.rect(100, 62, 60, 6, { 0.85, 0.12, 0.10, 1 }) end
    f.hot(1030, 0, 1110, 72, "page_set")
    self.headerBox = f.box(0, 0, 250, 72)
end

-- barre du bas : valeur à droite de chaque icône (prises de force AV / AR, conso, vitesse, régime, température, 4RM)
M.BOT_X = { 100, 258, 405, 555, 692, 860, 1022 }
function M.bottomBar(self, d, f, home)
    local y = 903
    local rpm = math.floor((d.ptoRpm or 0) + 0.5)
    local vals = {
        tostring(d.ptoF and rpm or 0),
        tostring(d.ptoR and rpm or 0),
        dec(d.fuelUse or 0, 1),
        dec(math.abs(d.speed or 0), 1),
        tostring(math.floor((d.rpm or 0) + 0.5)),
        d.temp ~= nil and string.format("%d°", math.floor(d.temp + 0.5)) or "--",
        d.awd == false and "2RM" or "4RM",
    }
    for i, x in ipairs(M.BOT_X) do f.txt(x, y, 28, vals[i], WH, nil, (M.BOT_X[i + 1] or 1180) - x - 40) end
    -- chaque icône ouvre sa page (05/11)
    f.hot(30, 868, 300, 941, "page_fdpto")
    f.hot(330, 868, 470, 941, "page_fdcomplist")
    f.hot(480, 868, 620, 941, "page_fdmotor")
    f.hot(620, 868, 760, 941, "page_fdtms")
    f.hot(950, 868, 1060, 941, "diffMode")
    f.hot(1290, 868, 1400, 941, "page_tool")
    f.hot(1440, 868, 1560, 941, home and "fd_page" or "page_home")
end

-------------------------------------------------------------------------------
-- Accueil page 1 (écran 01) : relevage AV, moteur & transmission, relevage AR, éclairage, distributeurs, accès rapide 1
-------------------------------------------------------------------------------
function M.qaLabels(f, list)
    for _, q in ipairs(list) do
        f.hot(q[1], q[2], q[3], q[4], q[5])
        f.ctr((q[1] + q[3]) * 0.5, q[4] - 13, 15, T(q[6]), DK, q[3] - q[1] - 10)
    end
end
M.HL_ICONS = { { 170, 531 }, { 236, 531 }, { 301, 531 }, { 367, 531 }, { 434, 531 } }   -- phares de la tuile Éclairage
M.HL_FN = { "workF", "workF", "beacon", "workR", "workR" }
M.HL_NAME = { "fd_lWorkF", "fd_lWorkF", "fd_lBeacon", "fd_lWorkR", "fd_lWorkR" }
M.HL_GROUP = { { 203, 126, "fd_lWorkF" }, { 301, 62, "fd_lBeacon" }, { 400, 126, "fd_lWorkR" } }   -- (x, largeur, nom)
function M.home1(self, d, ctx, v, Wp, Hp)
    local f = frame(self, ctx, Wp, Hp)
    f.v = v
    f.img(0, 0, 1672, 941, "as_fd_home1")
    local hf, hr = H().caseHitches(d)
    -- les tuiles d'abord (un appui ouvre la page), les touches de la tuile par-dessus
    f.hot(10, 84, 553, 452, "page_fdhitchf")
    f.hot(563, 84, 1108, 452, "page_fdmotor")
    f.hot(1120, 84, 1662, 452, "page_fdhitchr")
    f.hot(10, 462, 553, 855, "page_fdlight")
    f.hot(563, 462, 1108, 855, "page_fdvalve")
    -- titres des tuiles
    f.txt(62, 112, 24, T("fd_hitchF"), DK, nil, 420)
    f.txt(625, 112, 24, T("fd_motor"), DK, nil, 400)
    f.txt(1185, 112, 24, T("fd_hitchR"), DK, nil, 400)
    f.txt(60, 488, 24, T("fd_light"), DK, nil, 450)
    f.txt(620, 488, 24, T("fd_valves"), DK, nil, 420)
    f.txt(1185, 488, 24, T("fd_quick") .. " 1", DK, nil, 420)
    -- relevages : jauge à 10 segments, petite barre et % en direct ; cadenas = verrou
    local function hitchTile(h, front)
        local has = h ~= nil and h.object ~= nil
        local up = has and clamp01(h.up or 0) or 0
        local n = has and math.floor(up * 10 + 0.5) or 0
        if n > 0 then f.img(front and 112 or 1414, 150, 144, 270, string.format("as_fd_arc%s_%d", front and "F" or "R", n)) end
        local x0, x1 = front and 351 or 1145, front and 466 or 1240
        f.rect(x0, 197, x1 - x0, 8, TRACK)
        if has and up > 0.01 then f.rect(x0, 197, (x1 - x0) * up, 8, FILL) end
        if front then f.rgt(545, 200, 28, pct(h), DK, 90, true) else f.txt(1255, 200, 28, pct(h), DK, nil, 140, true) end
        local locked = self.hitchLocked ~= nil and self:hitchLocked(v, front) or false
        local lx = front and 519 or 1631
        f.rgt(front and 548 or 1660, 150, 15, locked and T("fd_lockOn") or T("fd_lockOff"), locked and DK or { 0.75, 0.1, 0.1, 1 }, 170)
        f.hot(lx - 40, 88, lx + 40, 160, front and "hlock_f" or "hlock_r")
        local act = front and "hitch_f" or "hitch_r"
        f.hot(x0 - 20, 150, x0 + (x1 - x0) + 20, 230, act)
        local bx = front and 390 or 1192
        f.hot(bx - 50, 370, bx + 50, 440, act)
        f.ctr(bx, 455 - 10, 15, has and T(up > 0.5 and "fd_hDown" or "fd_hUp") or T("empty"), DK, 200)
    end
    hitchTile(hf, true)
    hitchTile(hr, false)
    f.txt(1205, 338, 26, d.slip ~= nil and string.format("%d %%", math.floor(d.slip + 0.5)) or "--", DK, nil, 140)
    -- moteur : vitesse au centre, mémoires de vitesse 1 / 2 (touchables), régime et régime maxi, AUTO, l/h, régulateur
    f.ctr(835, 205, 46, dec(math.abs(d.speed or 0), 1), DK, 140, true)
    f.ctr(835, 252, 20, "km/h", GREY, 100)
    f.ctr(648, 238, 22, d.cruiseSpeed ~= nil and dec(d.cruiseSpeed, 1) or "--", DK, 120)
    f.ctr(1022, 238, 22, dec(mem2Of(v, d), 1), DK, 120)
    f.hot(590, 140, 710, 255, "fdm_cc1"); f.hot(960, 140, 1085, 255, "fdm_cc2")
    f.ctr(710, 352, 22, tostring(math.floor((d.rpm or 0) + 0.5)), DK, 120)
    f.ctr(962, 352, 22, d.maxRpm ~= nil and tostring(math.floor(d.maxRpm + 0.5)) or "--", DK, 120)
    f.txt(625, 411, 20, d.manual == true and "MAN" or "AUTO", DK, nil, 90)
    f.txt(785, 411, 22, dec(d.fuelUse or 0, 1) .. " l/h", DK, nil, 120)
    f.txt(960, 411, 22, d.cruiseSpeed ~= nil and (dec(d.cruiseSpeed, 1) .. " km/h") or "--", DK, nil, 140)
    -- éclairage : phares allumés en vert, chacun touchable, nom dessous
    for i, p in ipairs(M.HL_ICONS) do
        local on = AS_Terminal.lightOn ~= nil and AS_Terminal:lightOn(d, M.HL_FN[i]) or false
        if on then f.img(p[1] - 26, p[2] - 20, 52, 40, "as_fd_hl_on") end
        f.hot(p[1] - 32, p[2] - 28, p[1] + 32, p[2] + 40, "l_" .. M.HL_FN[i])
    end
    for _, g in ipairs(M.HL_GROUP) do f.ctr(g[1], 531 + 36, 14, T(g[3]), DK, g[2]) end
    -- distributeurs : nom de la fonction sous chaque cadenas ; appui = la fonction (sans fonction : son réglage)
    local rem = (v ~= nil and self.remoteFns ~= nil) and self:remoteFns(v) or {}
    local VX = { { 636, 610 }, { 770, 610 }, { 900, 610 }, { 1036, 610 }, { 636, 780 }, { 900, 780 }, { 1038, 780 } }
    local N = self.REMOTE_N or 6
    for i, p in ipairs(VX) do
        local fns = rem[i] or {}
        if i <= N then
            f.ctr(p[1], p[2], 15, #fns > 0 and self:remoteShort(fns[1]) or (T("fd_valve") .. " " .. i), #fns > 0 and DK or GREY, 128)
            f.hot(p[1] - 64, p[2] - 95, p[1] + 64, p[2] + 18, #fns > 0 and ("rem_" .. i) or ("fdv_sel_" .. i))
        else
            M.off(f, p[1] - 64, p[2] - 95, p[1] + 64, p[2] + 18)
        end
    end
    -- accès rapide 1 : relevages et entraînements
    -- (05/11) nom écrit sous chaque bouton
    local QA = { { 1137, 532, 1300, 622, "page_fdpto", "fd_pto" }, { 1310, 532, 1473, 622, "on", "fd_qaOn" }, { 1484, 532, 1648, 622, "fold", "fd_qaFold" },
        { 1137, 636, 1300, 726, "hitch_r", "fd_hitchR" }, { 1310, 636, 1473, 726, "lift_dn", "fd_qaDown" }, { 1484, 636, 1648, 726, "lift_up", "fd_qaUp" },
        { 1137, 740, 1300, 834, "hitch_f", "fd_hitchF" }, { 1310, 740, 1473, 834, "page_fdhitchset", "fd_settings" }, { 1484, 740, 1648, 834, "rearcam_fd", "fd_qaCam" } }
    M.qaLabels(f, QA)
    M.topBar(self, d, f, "home")
    M.bottomBar(self, d, f, true)
end

-------------------------------------------------------------------------------
-- Accueil page 2 (écran 02) : Fendt TI, climatisation, joystick, champ, gestion d'outil, accès rapide 2
-------------------------------------------------------------------------------
function M.home2(self, d, ctx, v, Wp, Hp)
    local f = frame(self, ctx, Wp, Hp)
    f.v = v
    f.img(0, 0, 1672, 941, "as_fd_home2")
    local fpOk = AS_TerminalFp ~= nil and AS_TerminalFp.available ~= nil and AS_TerminalFp:available(v) == true
    -- les tuiles d'abord, les touches par-dessus
    f.hot(10, 84, 553, 477, "page_fdti")
    f.hot(1120, 84, 1662, 477, "page_fdvalve")
    f.hot(10, 487, 553, 860, "guide")
    f.hot(563, 487, 1108, 860, "page_tool")
    f.txt(85, 112, 24, "Fendt TI", DK, nil, 400)
    f.txt(630, 112, 24, T("fd_clim"), DK, nil, 220)
    f.txt(1195, 112, 24, T("fd_joy"), DK, nil, 400)
    f.txt(640, 515, 24, T("fd_tools"), DK, nil, 460)
    f.txt(1185, 518, 24, T("fd_quick") .. " 2", DK, nil, 420)
    -- (05/11) Fendt TI = les 4 touches GO / END du joystick, de chaque côté de l'image ; tuile = réglage
    local tiF = M.tiFns(self, v)
    M.tiKey(self, f, 36, 176, 140, 120, 1, tiF[1]); M.tiKey(self, f, 36, 318, 140, 120, 2, tiF[2])
    M.tiKey(self, f, 392, 176, 140, 120, 3, tiF[3]); M.tiKey(self, f, 392, 318, 140, 120, 4, tiF[4])
    f.ctr(282, 452, 15, T("fd_tiTile"), GREY, 500)
    -- climatisation : seule la température extérieure existe dans le jeu
    f.txt(895, 114, 20, "Off", DK, nil, 60)
    local u = H().unitsOf()
    local t = d.tempOut
    f.txt(1000, 114, 20, t ~= nil and string.format("%d %s", math.floor((u and u.degC(t) or t) + 0.5), u and u.temp or "°C") or "--", DK, nil, 60)
    M.off(f, 566, 140, 1105, 474)
    -- joystick : affectations = fonctions des distributeurs (réglage) ; - / + sans objet
    f.ctr(1390, 440, 15, T("fd_valves") .. " : " .. T("fd_settings"), GREY, 340)
    M.off(f, 1135, 420, 1215, 470); M.off(f, 1568, 420, 1650, 470)
    -- champ : n° et surface ; liste et + = parcours, engrenage = demi-tour, repère = guidage
    local job = d.cnt ~= nil and d.cnt.jobs ~= nil and d.cnt.jobs[d.cnt.active] or nil
    f.txt(100, 585, 24, d.field ~= nil and (T("fd_field") .. " " .. tostring(d.field)) or T("fd_noField"), DK, nil, 300)
    if d.fieldHa ~= nil then f.txt(60, 650, 24, dec(d.fieldHa, 2) .. " ha", DK, nil, 300) end
    if job ~= nil then f.txt(60, 700, 22, dec(job.ha or 0, 2) .. " ha  " .. T("fd_done"), DK, nil, 420) end
    f.hot(25, 555, 100, 615, "fdg_course"); f.hot(430, 546, 547, 630, "fdg_course"); f.hot(25, 773, 148, 852, "page_fdturn")
    f.ctr(488, 645, 14, T("fd_gNew"), DK, 150); f.txt(158, 812, 16, T("fd_gTurn"), DK, nil, 200)
    -- gestion d'outil : nombre d'outils, largeur, nom
    local w = d.width
    local nT = 0
    for _, tt in ipairs(d.tools or {}) do if tt.object ~= v then nT = nT + 1 end end
    f.txt(675, 595, 24, tostring(nT), DK, nil, 140)
    f.txt(935, 595, 18, w ~= nil and (dec(w, 2) .. " m") or "--", DK, nil, 140)
    f.txt(935, 700, 24, w ~= nil and (dec(w, 2) .. " m") or "--", DK, nil, 140)
    local tn = (d.tools ~= nil and d.tools[1] ~= nil) and d.tools[1].name or T("fd_noTool")
    f.txt(675, 700, 18, tn, DK, nil, 150)
    -- accès rapide 2
    local QB = { { 1306, 553, 1472, 650, "hitch_r", "fd_hitchR" }, { 1137, 665, 1302, 755, "l_workF", "fd_qaWorkF" }, { 1308, 665, 1472, 755, "l_beacon", "fd_qaBeacon" },
        { 1480, 665, 1645, 755, "l_workR", "fd_qaWorkR" }, { 1137, 768, 1302, 855, "l_drive", "fd_qaDrive" }, { 1308, 768, 1472, 855, "diffMode", "fd_qaDiff" },
        { 1480, 768, 1645, 855, "page_fdvalve", "fd_valves" } }
    M.qaLabels(f, QB)
    M.topBar(self, d, f, "home")
    M.bottomBar(self, d, f, true)
end

function M.home(self, d, ctx, v, Wp, Hp)
    if M.homePage == 2 then return M.home2(self, d, ctx, v, Wp, Hp) end
    return M.home1(self, d, ctx, v, Wp, Hp)
end

-------------------------------------------------------------------------------
-- Pages (écrans 03 à 14) : châssis + son écran réduit ; f = page, fh = châssis
-------------------------------------------------------------------------------
local function pageBase(self, d, ctx, v, Wp, Hp, img, page, title)
    local fh = frame(self, ctx, Wp, Hp)
    fh.v = v
    fh.img(0, 0, 1672, 941, img)
    local f = frame(self, ctx, Wp, Hp, true)
    f.v = v
    if title ~= nil then f.txt(85, 112, 30, title, DK, nil, 900) end
    return f, fh
end
local function pageEnd(self, d, fh, page)
    M.topBar(self, d, fh, page)
    M.bottomBar(self, d, fh, false)
end
local function back(page) return "page_" .. (M.BACK[page] or "home") end

-- Launchpad (03) : grille 5 x 5 de son écran ; nil = pas de fonction dans le jeu (case grisée)
M.LP_X = { 225, 530, 835, 1138, 1445 }
M.LP_Y = { 170, 333, 490, 655, 818 }
M.LP_ACT = {
    { "page_fdhitchf", "page_fdmotor", "page_fdvalve", "page_fdti", "page_fdhitchr" },
    { "page_fdlight", nil, nil, nil, nil },
    { nil, nil, nil, "page_fdtms", "guide" },
    { "page_count", "page_tool", "page_fdcomplist", "page_set", "page_tool" },
    { "page_tractor", "page_fdsc", "rearcam_fd" },
}
M.LP_NAME = {
    { "fd_hitchF", "fd_motor", "fd_valves", "fd_lpTi", "fd_hitchR" },
    { "fd_light", "fd_lpTerm", "fd_lpSusp", "fd_lpGripPro", "fd_lpGrip" },
    { "fd_clim", "fd_lpMedia", "fd_lpPhone", "fd_lpTms", "fd_lpGuide" },
    { "fd_lpCount", "fd_lpUt", "fd_comp", "fd_settings", "fd_lpTools" },
    { "fd_lpService", "fd_lpSc", "fd_qaCam" },
}
function M.launch(self, d, ctx, v, Wp, Hp)
    local f, fh = pageBase(self, d, ctx, v, Wp, Hp, "as_fd_launch", "fdlaunch", nil)
    local fpOk = AS_TerminalFp ~= nil and AS_TerminalFp.available ~= nil and AS_TerminalFp:available(v) == true
    for r, row in ipairs(M.LP_ACT) do
        for c = 1, 5 do
            local a = row[c]
            if a == "page_fp" and not fpOk then a = nil end
            local x, y = M.LP_X[c], M.LP_Y[r]
            if a ~= nil then f.hot(x - 120, y - 75, x + 120, y + 75, a)
            elseif r < 5 or c <= 3 then f.rect(x - 85, y - 68, 170, 136, { 0.14, 0.16, 0.19, 0.62 }) end
            -- (05/11) noms sous les icônes, comme les autres terminaux
            local nm = M.LP_NAME[r] ~= nil and M.LP_NAME[r][c] or nil
            if nm ~= nil then f.ctr(x, y + 72, 17, T(nm), a ~= nil and WH or { 0.55, 0.58, 0.62, 1 }, 290) end
        end
    end
    -- (05/11) la case libre : les deux
    local y5 = M.LP_Y[5]
    local uiI = AS_Terminal.ui
    local inst = { cp = uiI == nil or uiI.cpInstalled == nil or uiI.cpInstalled(), fp = uiI == nil or uiI.fpInstalled == nil or uiI.fpInstalled() }
    for _, e in ipairs({ { 1063, "cp", "Courseplay", inst.cp and "fd_cp" or nil }, { 1213, "fp", "FarmPilot", fpOk and "page_fp" or nil } }) do
        -- (13/11) mod pas installé : case vide, sans icône ni nom
        if inst[e[2]] then
            f.img(e[1] - 48, y5 - 66, 96, 96, "as_fd_gi_" .. e[2] .. "_w")
            f.ctr(e[1], y5 + 72, 17, e[3], e[4] ~= nil and WH or { 0.55, 0.58, 0.62, 1 }, 146)
        end
        if e[4] ~= nil then f.hot(e[1] - 74, y5 - 75, e[1] + 74, y5 + 90, e[4])
        else f.rect(e[1] - 70, y5 - 68, 140, 136, { 0.14, 0.16, 0.19, 0.62 }) end
    end
    f.hot(1490, 780, 1640, 920, "page_home")
    pageEnd(self, d, fh, "fdlaunch")
end

-- (05/11) barres et cases de valeur en direct ;
-- chaque bouton des écrans agit, ou est grisé quand le jeu n'a pas la fonction
function M.slider(f, x0, x1, y0, y1, t, label)
    t = clamp01(t)
    f.rect(x0, y0, x1 - x0, y1 - y0, TRACK)
    local xe = x0 + (x1 - x0) * t
    if xe > x0 + 1 then f.rect(x0, y0, xe - x0, y1 - y0, FILL) end
    local bw = 90
    local bx = math.max(x0, math.min(x1 - bw, xe - bw * 0.5))
    f.rect(bx, y1 + 10, bw, 36, BOXC)
    f.ctr(bx + bw * 0.5, y1 + 28, 22, label, WH, bw - 8, true)
end
-- curseur touchable : n cases le long de la barre
function M.sliderHot(f, x0, x1, y0, y1, prefix, n)
    n = n or 20
    local w = (x1 - x0) / n
    for k = 1, n do f.hot(x0 + (k - 1) * w, y0 - 22, x0 + k * w, y1 + 22, prefix .. k) end
end
function M.off(f, x0, y0, x1, y1) f.rect(x0, y0, x1 - x0, y1 - y0, OFF) end

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
    if a == "fdm_cc1" then M.setCruise(self, v, cur, true)
    elseif a == "fdm_cc2" then M.setCruise(self, v, mem2Of(v, d), true)
    elseif a == "fdm_up" then M.setCruise(self, v, math.min(top, cur + 1), false)
    elseif a == "fdm_dn" then M.setCruise(self, v, cur - 1, false)
    else
        local w, k = a:match("^fdm_s(%d)_(%d+)$")
        k = tonumber(k)
        if k ~= nil then
            local kmh = math.max(1, math.floor(top * k / 20 + 0.5))
            if w == "1" then M.setCruise(self, v, kmh, false) else M.mem2[v] = kmh end
        end
    end
    self.lastRead = -100000
end
-- rangée du haut (écrans 04 et 05) : mémoires de vitesse, de régime, MEMO, TMS, AUTO
local function motorRow(self, d, f, v, tmsPage)
    f.ctr(113, 300, 24, d.cruiseSpeed ~= nil and dec(d.cruiseSpeed, 1) or "--", DK, 110)
    f.ctr(230, 300, 24, dec(mem2Of(v, d), 1), DK, 110)
    f.hot(58, 157, 170, 354, "fdm_cc1"); f.hot(175, 157, 287, 354, "fdm_cc2")
    -- mémoires de régime : pas de régime à mémoriser dans le jeu
    M.off(f, 300, 160, 560, 352)
    f.hot(580, 157, 694, 354, "fdm_up"); f.hot(694, 157, 808, 354, "fdm_dn")
    f.hot(818, 157, 1054, 354, tmsPage and "page_fdmotor" or "page_fdtms")
    -- AUTO = boîte automatique (vert) ou manuelle (grisé), réglage du jeu
    if d.manual == true then M.off(f, 1062, 160, 1232, 352) end
end

-- Moteur & transmission (04)
function M.motor(self, d, ctx, v, Wp, Hp)
    local f, fh = pageBase(self, d, ctx, v, Wp, Hp, "as_fd_motor", "fdmotor", T("fd_motor"))
    motorRow(self, d, f, v, false)
    local top = vTop(v, d)
    M.slider(f, 183, 1455, 447, 466, (d.cruiseSpeed or 0) / top, d.cruiseSpeed ~= nil and dec(d.cruiseSpeed, 1) or "--")
    M.slider(f, 183, 1456, 589, 607, mem2Of(v, d) / top, dec(mem2Of(v, d), 1))
    M.sliderHot(f, 183, 1455, 447, 466, "fdm_s1_"); M.sliderHot(f, 183, 1456, 589, 607, "fdm_s2_")
    f.txt(1300, 380, 22, "km/h", GREY, nil, 120)
    f.hot(1502, 96, 1652, 222, "page_home")
    f.hot(1502, 390, 1652, 512, "page_fdtms")
    f.hot(1502, 800, 1652, 916, "page_home")
    M.off(f, 1385, 95, 1480, 145)
    pageEnd(self, d, fh, "fdmotor")
end

-- TMS (05)
function M.tms(self, d, ctx, v, Wp, Hp)
    local f, fh = pageBase(self, d, ctx, v, Wp, Hp, "as_fd_tms", "fdtms", "TMS")
    motorRow(self, d, f, v, true)
    f.ctr(735, 497, 22, "1200", WH, 90, true)
    f.ctr(1062, 497, 22, d.maxRpm ~= nil and tostring(math.floor(d.maxRpm + 0.5)) or "--", WH, 90, true)
    f.hot(30, 400, 260, 500, "page_fdmotor")
    -- rangée du bas : seul le mode en vert (TMS) existe dans le jeu
    for _, x in ipairs({ 703, 867, 1206, 1381 }) do M.off(f, x - 75, 770, x + 75, 885) end
    M.off(f, 1380, 95, 1580, 145)
    f.hot(1498, 96, 1652, 222, "page_home")
    f.hot(1502, 390, 1652, 512, "page_fdmotor")
    f.hot(1502, 800, 1652, 916, back("fdtms"))
    pageEnd(self, d, fh, "fdtms")
end

-- Relevages AR (06) et AV (08)
M.HBAR_R = { { 159, 826, 210, 225 }, { 159, 826, 356, 372 }, { 159, 826, 503, 520 }, { 160, 826, 652, 669 } }
M.HBAR_F = { { 686, 1326, 218, 236 }, { 686, 1326, 365, 383 }, { 686, 1326, 510, 529 } }
local function hitchPage(self, d, ctx, v, Wp, Hp, front)
    local page = front and "fdhitchf" or "fdhitchr"
    local f, fh = pageBase(self, d, ctx, v, Wp, Hp, front and "as_fd_hitchf" or "as_fd_hitchr", page, T(front and "fd_hitchF" or "fd_hitchR"))
    local hf, hr = H().caseHitches(d)
    local h = front and hf or hr
    local has = h ~= nil and h.object ~= nil
    local up = has and math.floor((h.up or 0) * 100 + 0.5) or 0
    local name = has and (H().vehicleName ~= nil and H().vehicleName(h.object) or "") or T("empty")
    local locked = self.hitchLocked ~= nil and self:hitchLocked(v, front) or false
    local act = front and "hitch_f" or "hitch_r"
    -- barre 1 = position réelle ; 2 = limite haute ; 3 = position de travail ; 4 (AR) = vitesse de descente
    local B = front and M.HBAR_F or M.HBAR_R
    local vals = { has and up or 0, 100, 0, 100 }
    for i, b in ipairs(B) do
        M.slider(f, b[1], b[2], b[3], b[4], vals[i] / 100, (has or i > 1) and tostring(vals[i]) or "--")
    end
    f.hot(B[1][1], B[1][3] - 30, B[1][2], B[1][4] + 30, act)
    if front then
        f.ctr(330, 150, 34, pct(h), DK, 200, true)
        f.txt(560, 660, 26, name, DK, nil, 700)
        f.hot(220, 350, 450, 600, act)
        for _, x in ipairs({ 116, 276, 444 }) do M.off(f, x - 76, 795, x + 76, 900) end
    else
        f.ctr(1250, 160, 34, pct(h), DK, 200, true)
        f.txt(60, 760, 26, name, DK, nil, 800)
        f.hot(980, 370, 1210, 610, act)
        for _, x in ipairs({ 122, 288, 455, 621, 788, 954, 1120 }) do M.off(f, x - 76, 790, x + 76, 895) end
    end
    -- verrou (cadenas vert ouvert = actif dans l'image) : texte d'état sous la case
    f.ctr(1568, 236, 18, locked and T("fd_lockOn") or T("fd_lockOff"), locked and DK or { 0.75, 0.1, 0.1, 1 }, 170)
    f.hot(1486, 106, 1650, 220, front and "hlock_f" or "hlock_r")
    M.off(f, 1486, 255, 1650, 372)   -- PRIO : pas dans le jeu
    f.hot(1486, 400, 1650, 516, act)
    f.hot(1486, 546, 1650, 662, "page_fdhitchset")
    f.hot(1488, 786, 1648, 914, "page_home")
    pageEnd(self, d, fh, page)
end
function M.hitchr(self, d, ctx, v, Wp, Hp) return hitchPage(self, d, ctx, v, Wp, Hp, false) end
function M.hitchf(self, d, ctx, v, Wp, Hp) return hitchPage(self, d, ctx, v, Wp, Hp, true) end

-- Réglages du relevage (07) : position en direct, bouton vert = lever / baisser
function M.hitchset(self, d, ctx, v, Wp, Hp)
    local front = M.BACK.fdhitchset == "fdhitchf"
    local f, fh = pageBase(self, d, ctx, v, Wp, Hp, "as_fd_hitchset", "fdhitchset", T(front and "fd_hitchF" or "fd_hitchR") .. "  |  " .. T("fd_settings"))
    local hf, hr = H().caseHitches(d)
    local h = front and hf or hr
    local has = h ~= nil and h.object ~= nil
    local up = has and math.floor((h.up or 0) * 100 + 0.5) or 0
    M.slider(f, 202, 800, 394, 412, up / 100, has and tostring(up) or "--")
    f.txt(40, 560, 26, T("fd_hitchHelp"), DK, nil, 1400)
    f.hot(33, 343, 184, 464, front and "hitch_f" or "hitch_r")
    f.hot(202, 360, 800, 450, front and "hitch_f" or "hitch_r")
    for _, x in ipairs({ 254, 413, 573, 733 }) do M.off(f, x - 72, 172, x + 72, 278) end
    f.hot(1490, 795, 1645, 912, back("fdhitchset"))
    pageEnd(self, d, fh, "fdhitchset")
end

-- Distributeurs (09) : 7 distributeurs de son écran ; 1 à 6 = Fonctions 1 à 6 (comme le Massey) ;
-- appui = la fonction ; une case sans fonction ouvre son réglage ; bouton de droite = réglage
M.VALVE_X = { { 49, 213 }, { 234, 396 }, { 415, 576 }, { 594, 757 }, { 776, 941 }, nil, { 1104, 1267 }, { 1285, 1447 } }
M.VCOL = { { 0.98, 0.84, 0.05, 1 }, { 0.10, 0.45, 0.85, 1 }, { 0.85, 0.12, 0.15, 1 }, { 0.30, 0.66, 0.10, 1 }, { 0.85, 0.20, 0.15, 1 }, { 0.58, 0.25, 0.75, 1 } }
M.vSel = 1
function M.valve(self, d, ctx, v, Wp, Hp)
    local f, fh = pageBase(self, d, ctx, v, Wp, Hp, "as_fd_valve", "fdvalve", T("fd_valves"))
    local rem = (v ~= nil and self.remoteFns ~= nil) and self:remoteFns(v) or {}
    local n = 0
    for i = 1, 8 do
        local b = M.VALVE_X[i]
        if b ~= nil then
            n = n + 1
            local fns = rem[n] or {}
            local cx = (b[1] + b[2]) * 0.5
            f.ctr(cx, 285, 18, #fns > 0 and self:remoteShort(fns[1]) or (T("fd_valve") .. " " .. n), DK, b[2] - b[1] - 8)
            if n == (M.vSel or 1) then f.rect(b[1] + 4, 340, b[2] - b[1] - 8, 8, GRN) end
            if n <= (self.REMOTE_N or 6) then f.hot(b[1], 160, b[2], 350, #fns > 0 and ("rem_" .. n) or ("fdv_sel_" .. n))
            else M.off(f, b[1], 160, b[2], 350) end
        end
    end
    -- débit / temporisation / L / PRIO : réglages hydrauliques absents du jeu
    M.off(f, 40, 380, 1460, 760); M.off(f, 990, 770, 1300, 905)
    f.hot(1490, 255, 1650, 377, "fdv_sel_" .. (M.vSel or 1))
    M.off(f, 1490, 395, 1650, 515)
    f.hot(1490, 652, 1650, 774, "on")
    f.hot(1490, 797, 1650, 912, "page_home")
    pageEnd(self, d, fh, "fdvalve")
end

-- réglage des fonctions des distributeurs, style Fendt (fond clair, cartes blanches, choix en vert ; rien du Case)
function M.rem(self, d, ctx, v, Wp, Hp)
    local f, fh = pageBase(self, d, ctx, v, Wp, Hp, "as_fd_blank", "fdrem", T("fd_valves") .. "  |  " .. T("fd_settings"))
    local rem = (v ~= nil and self.remoteFns ~= nil) and self:remoteFns(v) or {}
    local N = self.REMOTE_N or 6
    local i = math.max(1, math.min(N, M.vSel or 1))
    -- onglets Fonction 1 à 6 (bandeau de couleur de l'écran 09)
    for k = 1, N do
        local x = 40 + (k - 1) * 238
        local sel = k == i
        f.rect(x, 150, 226, 92, sel and GRN or WH)
        f.rect(x, 150, 226, 9, M.VCOL[k] or GREY)
        f.ctr(x + 113, 202, 22, T("fd_valve") .. " " .. k, sel and WH or DK, 210, true)
        f.hot(x, 150, x + 226, 242, "fdv_sel_" .. k)
    end
    -- les 3 fonctions de ce distributeur
    local fns = rem[i] or {}
    local m = self.remoteMenu
    for k = 1, (self.REMOTE_SLOTS or 3) do
        local y = 280 + (k - 1) * 112
        local open = m ~= nil and m.i == i and m.k == k
        f.rect(40, y, 840, 92, open and GRN or WH)
        f.ctr(90, y + 46, 30, tostring(k), open and WH or GREY, 60, true)
        local fn = fns[k]
        local txt = fn ~= nil and self:remoteLabel(fn) or ((k <= #fns + 1) and "+" or "")
        f.txt(150, y + 46, 24, txt, open and WH or DK, nil, 710, fn ~= nil)
        if k <= #fns + 1 then f.hot(40, y, 880, y + 92, "rfn_" .. i .. "_" .. k) end
    end
    -- APPLIQUER = comme un appui sur le distributeur
    if #fns > 0 then
        f.rect(40, 640, 420, 92, GRN)
        f.ctr(250, 686, 26, T("c_apply"), WH, 400, true)
        f.hot(40, 640, 460, 732, "rem_" .. i)
    end
    -- liste des fonctions (AV | AR | Les deux) quand une case est ouverte ; sinon, ce qu'il faut faire
    if m == nil or m.i ~= i then
        f.txt(920, 330, 20, T("fd_remHint1"), GREY, nil, 700)
        f.txt(920, 372, 20, T("fd_remHint2"), GREY, nil, 700)
    end
    if m ~= nil and m.i == i then
        local heads = { { T("c_colF"), "@f" }, { T("c_colR"), "@r" }, { T("c_colB"), "" } }
        local x0, y0, cw, rh = 900, 262, 190, 48
        local cur = fns[m.k] or "none"
        for c, hd in ipairs(heads) do
            local cx = x0 + (c - 1) * (cw + 6)
            f.rect(cx, y0, cw, rh, { 0.25, 0.28, 0.31, 1 })
            f.ctr(cx + cw * 0.5, y0 + rh * 0.5, 20, hd[1], WH, cw - 10, true)
            for j = 2, #self.REMOTE_FNS do
                local fn = self.REMOTE_FNS[j] .. hd[2]
                local ry = y0 + (j - 1) * rh + 2
                local on = cur == fn
                f.rect(cx, ry, cw, rh - 3, on and GRN or WH)
                f.txt(cx + 8, ry + rh * 0.5, 15, self:remoteLabel(fn, true), on and WH or DK, nil, cw - 12)
                f.hot(cx, ry, cx + cw, ry + rh - 3, "rsel_" .. m.i .. "_" .. m.k .. "_" .. fn)
            end
        end
        local ny = y0 + #self.REMOTE_FNS * rh + 4
        f.rect(x0, ny, cw * 3 + 12, rh - 3, cur == "none" and GRN or WH)
        f.ctr(x0 + (cw * 3 + 12) * 0.5, ny + rh * 0.5, 18, T("none"), cur == "none" and WH or DK, cw * 3)
        f.hot(x0, ny, x0 + cw * 3 + 12, ny + rh - 3, "rsel_" .. m.i .. "_" .. m.k .. "_none")
    end
    f.hot(1490, 797, 1650, 912, back("fdrem"))
    f.img(1500, 805, 140, 100, "as_fd_back")
    pageEnd(self, d, fh, "fdrem")
end

-- Éclairage (10) : ses 8 phares ; allumé = rond vert
M.LAMPS = { { 566, 241, "workF", "fd_lWorkF" }, { 702, 241, "workF", "fd_lWorkF" }, { 841, 206, "beacon", "fd_lBeacon" },
    { 978, 241, "workR", "fd_lWorkR" }, { 1113, 241, "workR", "fd_lWorkR" }, { 679, 473, "high", "fd_lHigh" },
    { 1071, 429, "workR", "fd_lWorkR" }, { 258, 641, "drive", "fd_lDrive" } }
function M.light(self, d, ctx, v, Wp, Hp)
    local f, fh = pageBase(self, d, ctx, v, Wp, Hp, "as_fd_light", "fdlight", T("fd_light"))
    -- (05/11) codes en vert, pleins phares en bleu ; nom sous chaque phare
    for i, l in ipairs(M.LAMPS) do
        local on = AS_Terminal.lightOn ~= nil and AS_Terminal:lightOn(d, l[3]) or false
        if on then f.img(l[1] - 64, l[2] - 64, 128, 128, "as_fd_lamp" .. i .. "_on") end
        f.hot(l[1] - 62, l[2] - 62, l[1] + 62, l[2] + 62, "l_" .. l[3])
        -- une étiquette par paire (1-2 travail AV, 4-5 travail AR), centrée sous la paire
        if i ~= 2 and i ~= 5 then
            local lx = (i == 1 or i == 4) and (l[1] + M.LAMPS[i + 1][1]) * 0.5 or l[1]
            local lw = (i == 1 or i == 4) and 240 or 170
            f.rect(lx - lw * 0.5, l[2] + 68, lw, 30, { 1, 1, 1, 1 })
            f.ctr(lx, l[2] + 83, 18, T(l[4]), DK, lw - 6)
        end
    end
    f.hot(1490, 96, 1650, 216, "l_mem1")
    f.hot(1490, 240, 1650, 360, "l_mem2")
    f.ctr(1570, 226, 15, T("fd_lMem1"), DK, 160)
    f.ctr(1570, 370, 15, T("fd_lMem2"), DK, 160)
    -- sauvegarde de mémoire et « coming home » : pas dans le jeu
    M.off(f, 1490, 384, 1650, 504); M.off(f, 1490, 528, 1650, 648)
    f.hot(1490, 795, 1650, 915, "page_home")
    pageEnd(self, d, fh, "fdlight")
end

-- Prise de force (11) : 4 boutons = AV marche / arrêt, AR marche / arrêt (le jeu n'a pas de régimes 540 / 1000)
function M.pto(self, d, ctx, v, Wp, Hp)
    local f, fh = pageBase(self, d, ctx, v, Wp, Hp, "as_fd_pto", "fdpto", nil)
    f.txt(480, 266, 28, T("fd_pto"), DK, nil, 760)
    f.ctr(836, 360, 26, T("fd_ptoAsk"), DK, 760)
    local B = { { 504, 660 }, { 678, 834 }, { 851, 1007 }, { 1024, 1180 } }
    local L = { T("fd_front") .. " " .. T("fd_on"), T("fd_front") .. " " .. T("fd_off"), T("fd_rear") .. " " .. T("fd_on"), T("fd_rear") .. " " .. T("fd_off") }
    for i, b in ipairs(B) do
        f.ctr((b[1] + b[2]) * 0.5, 528, 20, L[i], DK, b[2] - b[1] - 10, true)
        f.hot(b[1], 436, b[2], 550, "on")
    end
    f.hot(426, 614, 556, 724, "page_home")
    f.hot(0, 0, 400, 941, "page_home"); f.hot(1270, 0, 1672, 941, "page_home")
    pageEnd(self, d, fh, "fdpto")
end

-- Ordinateur de bord (12) : travail en cours ; Liste (13) : travail 1, travail 2, total
M.CMP_X = { 137, 298, 469, 644, 814, 987, 1164, 1336 }
function M.comp(self, d, ctx, v, Wp, Hp)
    local f, fh = pageBase(self, d, ctx, v, Wp, Hp, "as_fd_comp", "fdcomp", T("fd_comp"))
    local cnt = d.cnt or {}
    local k = (cnt.jobs ~= nil and cnt.jobs[cnt.active]) or cnt.total or { ha = 0, ms = 0, fuel = 0, dist = 0 }
    local name = cnt.active == 1 and T("jobN1") or (cnt.active == 2 and T("jobN2") or T("total"))
    f.txt(290, 222, 32, name, DK, nil, 980, true)
    local rate = (k.ms or 0) > 60000 and (k.ha / (k.ms / 3600000)) or 0
    local vals = {
        { dec(rate, 1), "ha/h" }, { dec(k.fuel or 0, 1), "l" }, { dec(k.ha or 0, 2), "ha" }, { dec((k.dist or 0) / 1000, 1), "km" },
        { (k.ha or 0) > 0.01 and dec(k.fuel / k.ha, 1) or "0", "l/ha" }, { dec(d.fuelUse or 0, 1), "l/h" }, { hm(k.ms), "h" },
        { d.width ~= nil and dec(d.width, 2) or "--", "m" } }
    for i, x in ipairs(M.CMP_X) do
        f.ctr(x, 470, 26, vals[i][1], DK, 150, true)
        f.ctr(x, 505, 18, vals[i][2], GREY, 150)
    end
    local tn = (d.tools ~= nil and d.tools[1] ~= nil) and d.tools[1].name or T("fd_tractor")
    f.txt(234, 764, 34, tn, DK, nil, 520)
    -- + / - / x de gauche : travail 1, travail 2, remise à zéro (nom dessous) ; groupe de droite sans objet
    local L3 = { { 355, 450, "job1", "jobN1" }, { 453, 552, "job2", "jobN2" }, { 554, 654, "reset", "fd_cReset" } }
    for _, b in ipairs(L3) do
        f.hot(b[1], 588, b[2], 675, b[3])
        f.ctr((b[1] + b[2]) * 0.5, 692, 14, T(b[4]), DK, b[2] - b[1] - 6)
    end
    if cnt.active == 1 or cnt.active == 2 then
        local b = L3[cnt.active]
        f.rect(b[1] + 8, 676, b[2] - b[1] - 16, 5, GRN)
    end
    M.off(f, 936, 584, 1230, 678)
    M.off(f, 1298, 172, 1428, 280)                       -- nom du travail : pas de clavier
    M.off(f, 1482, 98, 1561, 210)                        -- pause : les compteurs tournent toujours
    M.off(f, 1482, 238, 1648, 346)                       -- tracteur / outil
    M.off(f, 1090, 834, 1292, 882)
    f.hot(1482, 368, 1648, 474, "reset"); f.ctr(1565, 486, 13, T("fd_cReset"), DK, 170)
    f.hot(1482, 492, 1648, 606, "jobnext"); f.hot(1482, 624, 1648, 740, "jobnext")
    f.hot(65, 752, 200, 880, "page_tractor"); f.hot(262, 820, 550, 892, "page_tool"); f.hot(785, 824, 855, 890, "page_tool")
    f.hot(1482, 770, 1648, 890, back("fdcomp"))
    pageEnd(self, d, fh, "fdcomp")
end
M.CL_Y = { 247, 313, 380, 441, 503, 565, 629, 692, 755, 818 }
function M.complist(self, d, ctx, v, Wp, Hp)
    local f, fh = pageBase(self, d, ctx, v, Wp, Hp, "as_fd_complist", "fdcomplist", T("fd_comp"))
    f.txt(283, 178, 28, T("fd_comp"), DK, nil, 600, true)
    local rows = { { T("jobN1"), "fd_job1" }, { T("jobN2"), "fd_job2" }, { T("total"), "fd_jobT" } }
    for i, y in ipairs(M.CL_Y) do
        local r = rows[i]
        if r ~= nil then
            f.txt(283, y, 30, r[1], DK, nil, 1100, (d.cnt ~= nil and d.cnt.active == i))
            f.hot(24, y - 30, 1500, y + 30, r[2])
        end
    end
    M.off(f, 1395, 150, 1520, 240); M.off(f, 1525, 150, 1650, 240)
    f.hot(1516, 796, 1645, 905, "page_home")
    pageEnd(self, d, fh, "fdcomplist")
end

-- Caméra (launchpad) : caméra arrière en grand sur fond noir ; toucher = marche / arrêt
function M.cam(self, d, ctx, v, Wp, Hp)
    local f, fh = pageBase(self, d, ctx, v, Wp, Hp, "as_fd_blank", "fdcam", nil)
    local bx, by, bw, bh = 20, 84, 1632, 774
    fh.rect(bx, by, bw, bh, { 0, 0, 0, 1 })
    if ctx.rec == nil then
        local P = self.REAR_CAM or { resX = 16, resY = 9 }
        local cw = bw - 20
        local ch = cw * P.resY / P.resX
        if ch > bh - 20 then ch = bh - 20; cw = ch * P.resX / P.resY end
        local cx, cy = bx + (bw - cw) * 0.5, by + (bh - ch) * 0.5
        fh.hot(bx, by, bx + bw, by + bh, "rearcam")
        if self.settings.rearCam ~= false and self.rearCamOverlay ~= nil then
            local ov = self:rearCamOverlay(v)
            if ov ~= nil then ctx.image(fh.PX(cx), fh.PY(cy), fh.PW(cw), fh.PH(ch), ov) end
        else
            fh.ctr(bx + bw * 0.5, by + bh * 0.5, 26, T("c_camOff"), WH, bw - 40)
        end
    end
    pageEnd(self, d, fh, "fdcam")
end

-- pages du terminal sans écran Fendt (outil / Isobus, guidage, réglages, compteurs, FarmPilot...) : sur une page claire
local function subCtx(ctx, v, f, x0, y0, x1, y1, full)
    local cx, cy, xr, yb = f.PX(x0), f.PY(y0), f.PX(x1), f.PY(y1)
    local rx = full and xr or (xr - 140)
    return { text = ctx.text, measure = ctx.measure, rect = ctx.rect, button = ctx.button, hotspot = ctx.hotspot, image = ctx.image,
        cx = cx, cy = cy, cw = full and (xr - cx) or (rx - cx - 6), ch = yb - cy, rx = rx, sideY = cy - 16,
        X = ctx.X, Y = ctx.Y, sx = ctx.sx, sy = ctx.sy, rec = ctx.rec, v = v }
end
function M.page(self, d, ctx, v, Wp, Hp, inside)
    local page = self.page
    local f, fh = pageBase(self, d, ctx, v, Wp, Hp, "as_fd_blank", page, nil)
    local ctx2 = subCtx(ctx, v, fh, 20, 84, 1652, 858, false)
    local fn = self["page_" .. page]
    if fn ~= nil then
        local ok, err = pcall(fn, self, d, ctx2, inside, v)
        if not ok then error(err) end
    end
    pageEnd(self, d, fh, page)
end


-------------------------------------------------------------------------------
-- Fendt Guide (écran 14) : carte en direct sous ses boutons ; réglages du demi-tour (écran 15)
-------------------------------------------------------------------------------
M.gview = "top"
local SIGCOL = { fix = { 0.33, 0.82, 0.12, 1 }, float = { 1.00, 0.55, 0.12, 1 }, gps = { 1.00, 0.70, 0.10, 1 }, lost = { 0.90, 0.15, 0.12, 1 } }
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
-- carte du terminal dans un cadre (pixels de son écran), vue au choix
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
    if not ok and not M.loggedMap then M.loggedMap = true; print("[AS_Terminal] Fendt : ERREUR carte Fendt Guide : " .. tostring(err)) end
end

function M.guide(self, d, ctx, v, Wp, Hp, inside)
    local G = AS_TerminalGps
    if G ~= nil and G.sub == "course" then return M.page(self, d, ctx, v, Wp, Hp, inside) end
    local g = d.gps or {}
    local fh = frame(self, ctx, Wp, Hp); fh.v = v
    local f = frame(self, ctx, Wp, Hp, true); f.v = v
    -- la carte d'abord, puis son écran (vert de la carte transparent) par-dessus
    fh.rect(0, 74, 1672, 792, { 0.76, 0.92, 0.53, 1 })
    liveMap(self, d, ctx, v, f, 14, 150, 1658, 826, M.gview)
    fh.img(0, 0, 1672, 941, "as_fd_guide")
    -- rampe des tronçons (Section Control) sur la carte, comme le Massey : vert allumé, jaune prêt, blanc coupé
    local SC = AS_SectionControl
    if SC ~= nil and G ~= nil and G.lastView ~= nil and G.lastView.v == v and AS_TerminalMassey ~= nil and AS_TerminalMassey.drawBar ~= nil then
        local okB, errB = pcall(function() return AS_TerminalMassey.drawBar(ctx, f, G.lastView, SC:bar(v)) end)
        if not okB and not M.loggedBar then M.loggedBar = true; print("[AS_Terminal] Fendt : ERREUR rampe SC : " .. tostring(errB)) end
    end
    -- barre de guidage : segment sombre du côté où braquer (pleine à 50 cm)
    local onLine = g.data ~= nil and g.onLine and not g.inTurn and g.xte ~= nil
    local BX0, BX1, BY0, BY1 = 441, 1252, 207, 233
    local mid = (BX0 + BX1) * 0.5
    if onLine then
        local k = math.min(1, math.abs(g.xte) / 0.5)
        local len = math.max(6, k * (BX1 - BX0) * 0.5)
        if g.xte > 0 then f.rect(mid - len, BY0, len, BY1 - BY0, { 0.08, 0.11, 0.13, 1 })
        else f.rect(mid, BY0, len, BY1 - BY0, { 0.08, 0.11, 0.13, 1 }) end
    end
    f.rect(mid - 2, BY0 - 4, 4, BY1 - BY0 + 8, { 0.40, 0.66, 0.10, 1 })
    -- case du haut : n° de ligne et écart
    f.ctr(844, 173, 22, (g.row ~= nil and g.row > 0 and (tostring(g.row) .. "  ") or "") .. xteTxt(g), DK, 136, true)
    -- volant : trait vert quand le guidage conduit ; RTK à côté (rouge sans station)
    if g.steer == "on" or g.active then f.rect(812, 138, 64, 6, { 0.40, 0.66, 0.10, 1 }) end
    local sig = "gps"
    if G ~= nil then
        local okR, s1 = pcall(G.rtkSignal, G, v)
        if okR and s1 ~= nil then sig = s1 end
    end
    f.txt(900, 115, 24, sig == "gps" and "GPS" or "RTK", SIGCOL[sig] or SIGCOL.gps, nil, 90, true)
    -- (05/11) les touches sont
    -- retirées de l'image ; touches dessinées ici : icône nette + nom écrit dedans, une action par touche
    local fpOk = AS_TerminalFp ~= nil and AS_TerminalFp.available ~= nil and AS_TerminalFp:available(v) == true
    local scc = (SC ~= nil and v ~= nil) and SC:cfg(v) or nil
    local scAuto = scc ~= nil and scc.auto == 1
    local steering = g.steer == "on" or g.active == true
    local B = M.gbtn
    B(f, 30, 165, 170, 265, "steer", T("fd_gSteer"), "gps_steer", steering and "on" or nil)
    B(f, 30, 277, 170, 377, "turn", T("fd_gTurn"), "page_fdturn")
    -- (13/11) touches Courseplay / FarmPilot seulement si le mod est installé
    local uiI = AS_Terminal.ui
    local cpInst = uiI == nil or uiI.cpInstalled == nil or uiI.cpInstalled()
    if cpInst then B(f, 30, 389, 170, 489, "cp", "Courseplay", "fdg_course") end
    if uiI == nil or uiI.fpInstalled == nil or uiI.fpInstalled() then B(f, 30, 501, 170, 601, "fp", "FarmPilot", "page_fp", not fpOk and "off" or nil) end
    B(f, 30, 613, 170, 713, "sc", scAuto and "SC AUTO" or "SC MANU", "page_fdsc", scAuto and "on" or nil)
    if cpInst then   -- (13/11) parcours = Courseplay
        B(f, 1502, 165, 1642, 265, "make", T("fd_gMake"), "cp_generate")
        B(f, 1502, 277, 1642, 377, "start", T("fd_gStart"), "cp_start")
        B(f, 1502, 389, 1642, 489, "clear", T("fd_gClear"), "cp_clear")
    end
    B(f, 1502, 501, 1642, 601, g.recording and "stop" or "rec", g.recording and T("fd_gStop") or T("fd_gRec"), "gps_rec")
    B(f, 1502, 613, 1642, 713, "pause", g.recPaused and T("fd_gResume") or T("fd_gPause"), "gps_recPause",
        (not g.recording) and "off" or (g.recPaused and "on" or nil))
    -- barre d'outils du bas : zoom, vue, retour
    B(f, 30, 838, 250, 912, "zin", T("fd_gZin"), "fdg_zin")
    B(f, 262, 838, 482, 912, "zout", T("fd_gZout"), "fdg_zout")
    B(f, 494, 838, 714, 912, M.gview == "persp" and "v3d" or "v2d", M.gview == "persp" and T("fd_gV3d") or T("fd_gV2d"), "fdg_view")
    B(f, 1422, 838, 1642, 912, "back", T("fd_gBack"), "page_home")
    -- bandeau d'infos : champ à gauche, état de Courseplay à droite ; volant = direction
    f.hot(812, 90, 876, 140, "gps_steer")
    local fld = d.field ~= nil and (T("fd_field") .. " " .. tostring(d.field) .. (d.fieldHa ~= nil and ("   " .. dec(d.fieldHa, 2) .. " ha") or "")) or T("fd_noField")
    f.txt(40, 115, 22, fld, DK, nil, 600, true)
    local cpTxt = g.active and T("fd_gCpOn") or (g.data ~= nil and T("fd_gCpReady") or T("fd_gCpNone"))
    f.rgt(1640, 115, 22, cpTxt, g.active and { 0.30, 0.55, 0.08, 1 } or DK, 560, true)
    M.topBar(self, d, fh, "gps")
    M.bottomBar(self, d, fh, false)
end

-- touche du Guide : cadre, fond (vert = actif, gris = absent du jeu), icône et nom ; haute = icône dessus, basse = à gauche
local BTN_BG, BTN_BD, BTN_OFF = { 0.95, 0.96, 0.97, 1 }, { 0.62, 0.66, 0.70, 1 }, { 0.83, 0.85, 0.87, 1 }
function M.gbtn(f, x0, y0, x1, y1, icon, label, action, st)
    local on, off = st == "on", st == "off"
    f.rect(x0, y0, x1 - x0, y1 - y0, BTN_BD)
    f.rect(x0 + 2, y0 + 2, x1 - x0 - 4, y1 - y0 - 4, on and GRN or (off and BTN_OFF or BTN_BG))
    local tc = on and WH or (off and { 0.55, 0.58, 0.62, 1 } or DK)
    local spr = "as_fd_gi_" .. icon .. (on and "_w" or "_d")
    local h = y1 - y0
    if h >= 90 then
        f.img((x0 + x1) * 0.5 - 30, y0 + 8, 60, 60, spr)
        f.ctr((x0 + x1) * 0.5, y1 - 17, 15, label, tc, x1 - x0 - 8, true)
    else
        local sz = h - 18
        f.img(x0 + 10, y0 + 9, sz, sz, spr)
        f.txt(x0 + 20 + sz, (y0 + y1) * 0.5, 18, label, tc, nil, x1 - x0 - sz - 28, true)
    end
    if not off then f.hot(x0, y0, x1, y1, action) end
end

-- réglages de Courseplay (motif, tournières, lignes sautées) : lecture / valeur suivante
local function cpSettings(v)
    if v == nil or v.getCourseGeneratorSettings == nil then return nil end
    local ok, cs = pcall(v.getCourseGeneratorSettings, v)
    return ok and cs or nil
end
local function stStr(st)
    if st == nil or st.getString == nil then return "--" end
    local ok, r = pcall(st.getString, st)
    return ok and tostring(r) or "--"
end
local function stNum(st)
    if st == nil or st.getValue == nil then return nil end
    local ok, r = pcall(st.getValue, st)
    return ok and tonumber(r) or nil
end
M.CP_KEYS = { fdt_mode = "centerMode", fdt_head = "numberOfHeadlands", fdt_skip = "rowsToSkip" }
function M.turnAction(self, a)
    local cs = cpSettings(self.data ~= nil and self.data.vehicle or nil)
    local st = cs ~= nil and cs[M.CP_KEYS[a]] or nil
    if st ~= nil and st.setNextItem ~= nil then
        pcall(st.setNextItem, st)
        print("[AS_Terminal] Fendt : demi-tour, " .. M.CP_KEYS[a] .. " = " .. stStr(st))
    elseif AS_Terminal.ui ~= nil and AS_Terminal.ui.warn ~= nil then
        AS_Terminal.ui.warn(T("cpMissing"))
    end
    if AS_TerminalGps ~= nil then AS_TerminalGps.drawCache = nil end
    self.lastRead = -100000
end
function M.order(n)
    local t, step = {}, (n or 0) + 1
    for i = 0, 5 do t[#t + 1] = tostring(i * step) end
    return table.concat(t, ", ") .. ", ..."
end
function M.turn(self, d, ctx, v, Wp, Hp, inside)
    local g = d.gps or {}
    local fh = frame(self, ctx, Wp, Hp); fh.v = v
    local f = frame(self, ctx, Wp, Hp, true); f.v = v
    fh.rect(0, 74, 1672, 792, { 0.76, 0.92, 0.53, 1 })
    liveMap(self, d, ctx, v, f, 972, 284, 1428, 748, "top")
    fh.img(0, 0, 1672, 941, "as_fd_turn")
    local cs = cpSettings(v)
    f.txt(75, 115, 28, T("fd_turnSet"), DK, nil, 900, true)
    f.txt(30, 304, 24, T("fd_turnMode"), DK, nil, 560)
    f.txt(30, 491, 24, T("fd_pattern"), DK, nil, 900)
    f.txt(93, 636, 24, T("fd_heads") .. "   |   " .. T("fd_skip"), DK, nil, 680)
    f.txt(93, 763, 24, T("fd_order"), DK, nil, 600)
    f.txt(118, 555, 30, cs ~= nil and stStr(cs.centerMode) or "--", DK, nil, 760)
    f.ctr(187, 688, 30, cs ~= nil and stStr(cs.numberOfHeadlands) or "--", DK, 170)
    f.ctr(366, 688, 30, cs ~= nil and stStr(cs.rowsToSkip) or "--", DK, 150)
    f.txt(93, 802, 28, M.order(cs ~= nil and stNum(cs.rowsToSkip) or 0), DK, nil, 820)
    -- AUTO = Courseplay conduit (demi-tours compris), MAN = à la main ; trait vert sous le mode en cours
    if g.active then f.rect(110, 438, 130, 6, { 0.40, 0.66, 0.10, 1 }) else f.rect(279, 438, 130, 6, { 0.40, 0.66, 0.10, 1 }) end
    f.hot(95, 338, 254, 447, g.active and "fdt_none" or "gps_steer")
    f.hot(264, 338, 422, 447, g.active and "gps_steer" or "fdt_none")
    f.hot(636, 338, 792, 447, "cp_generate")
    f.hot(93, 522, 948, 588, "fdt_mode")
    f.hot(93, 655, 282, 720, "fdt_head")
    f.hot(288, 655, 447, 720, "fdt_skip")
    f.hot(30, 150, 160, 270, "fdg_course"); f.hot(168, 150, 298, 270, "fdg_course"); f.hot(305, 150, 435, 270, "fdg_course")
    f.ctr(714, 462, 15, T("fd_gMake"), DK, 170)
    f.hot(1483, 100, 1645, 210, "page_tool"); f.ctr(1564, 222, 15, T("fd_qaTool"), DK, 170)
    -- capteurs de rang, largeur de motif, 2e calcul : pas dans le jeu
    M.off(f, 1483, 240, 1645, 346); M.off(f, 1483, 378, 1645, 486); M.off(f, 802, 338, 957, 447); M.off(f, 790, 622, 948, 725)
    f.hot(1488, 728, 1648, 838, "page_gps")
    M.topBar(self, d, fh, "fdturn")
    M.bottomBar(self, d, fh, false)
end

-------------------------------------------------------------------------------
-- (05/11) réglages SC en style Fendt :
-- mêmes réglages que le Massey (AS_SectionControl), cartes blanches, choix en vert
-------------------------------------------------------------------------------
local CHO = { 0.88, 0.90, 0.92, 1 }
local TEAL = { 0.29, 0.62, 0.55, 1 }
M.scToolIx = 1
local function scToolOf(v)
    local SC = AS_SectionControl
    if SC == nil or v == nil then return nil, 0 end
    local list = SC:tools(v)
    if #list == 0 then return nil, 0 end
    local i = ((M.scToolIx or 1) - 1) % #list + 1
    M.scToolIx = i
    return list[i], #list
end
local function mtr(x)
    local u = H().unitsOf()
    if u ~= nil and u.imperial then return dec((x or 0) * 3.2808, 2) .. " ft" end
    return dec(x or 0, 2) .. " m"
end
local function pctS(x) return string.format("%d", math.floor((x or 0) + 0.5)) end
-- une carte : titre gris, puis ses choix côte à côte (vert = choisi)
local function choiceRow(f, x0, y0, w, label, opts, cur)
    f.rect(x0, y0, w, 104, WH)
    f.txt(x0 + 16, y0 + 20, 17, label, GREY, nil, w - 32, true)
    local n = #opts
    local cw = (w - 32 - (n - 1) * 8) / n
    for k, o in ipairs(opts) do
        local x = x0 + 16 + (k - 1) * (cw + 8)
        local sel = o[1] == cur
        f.rect(x, y0 + 36, cw, 58, sel and GRN or CHO)
        f.ctr(x + cw * 0.5, y0 + 65, 17, o[2], sel and WH or DK, cw - 10, true)
        f.hot(x, y0 + 36, x + cw, y0 + 94, o[3])
    end
end
-- une carte : titre, puis [ - ]  valeur  [ + ]
local function stepRow(f, x0, y0, w, label, val, key)
    f.rect(x0, y0, w, 104, WH)
    f.txt(x0 + 16, y0 + 20, 17, label, GREY, nil, w - 32, true)
    f.rect(x0 + 16, y0 + 36, 96, 58, CHO); f.ctr(x0 + 64, y0 + 65, 34, "-", DK, 80, true)
    f.ctr(x0 + w * 0.5, y0 + 65, 26, val, DK, w - 250, true)
    f.rect(x0 + w - 112, y0 + 36, 96, 58, CHO); f.ctr(x0 + w - 64, y0 + 65, 34, "+", DK, 80, true)
    f.hot(x0 + 10, y0 + 30, x0 + 118, y0 + 100, "fdsc_st_" .. key .. "_-1")
    f.hot(x0 + w - 118, y0 + 30, x0 + w - 10, y0 + 100, "fdsc_st_" .. key .. "_1")
end
function M.sc(self, d, ctx, v, Wp, Hp)
    local f, fh = pageBase(self, d, ctx, v, Wp, Hp, "as_fd_blank", "fdsc", "Section Control")
    local SC = AS_SectionControl
    local c = (SC ~= nil and v ~= nil) and SC:cfg(v) or {}
    local o, nTools = scToolOf(v)
    -- gauche : outil (appui = outil suivant), SC Auto / Manuel, zone faite, bord du champ, contrôle de rampe
    local L, LW = 40, 790
    f.rect(L, 150, LW, 104, WH)
    f.txt(L + 16, 170, 17, T("fd_scTool") .. (nTools > 1 and ("  (" .. T("fd_scNext") .. ")") or ""), GREY, nil, LW - 32, true)
    f.txt(L + 16, 218, 24, o ~= nil and H().vehicleName(o) or T("mf_scNone"), DK, nil, LW - 240, o ~= nil)
    if o ~= nil and SC ~= nil then f.rgt(L + LW - 16, 218, 22, string.format(T("fd_scSections"), SC:count(o)), DK, 210) end
    if nTools > 1 then f.hot(L, 150, L + LW, 254, "fdsc_tool") end
    choiceRow(f, L, 268, LW, "Section Control", { { 1, T("mf_auto"), "fdsc_auto" }, { 0, T("mf_manual"), "fdsc_manu" } }, c.auto)
    choiceRow(f, L, 386, LW, T("fd_scDone"), { { 1, T("fd_scCut"), "fdsc_done1" }, { 0, T("fd_scNoCut"), "fdsc_done0" } }, c.done)
    choiceRow(f, L, 504, LW, T("fd_scBorder"), { { 1, T("fd_scBd1"), "fdsc_bd1" }, { 2, T("fd_scBd2"), "fdsc_bd2" }, { 3, T("fd_scBd3"), "fdsc_bd3" } }, c.bd)
    choiceRow(f, L, 622, LW, T("fd_scBoom"), { { 1, T("mf_auto"), "fdsc_boom1" }, { 0, T("mf_manual"), "fdsc_boom0" } }, c.boom)
    -- carte Travail : zone faite affichée / effacée
    f.rect(L, 742, 386, 92, GRN)
    f.ctr(L + 193, 788, 20, T("fd_scMap"), WH, 370, true)
    f.hot(L, 742, L + 386, 834, "page_work")
    -- droite : recouvrements, sens de marche, tolérance, délais
    local R, RW = 850, 620
    stepRow(f, R, 150, RW, T("fd_scOvIn"), pctS(c.ovIn) .. " %", "ovIn")
    stepRow(f, R, 264, RW, T("fd_scOvBd"), (c.bd == 2 and "50" or (c.bd == 3 and "--" or pctS(c.ovBd))) .. " %", "ovBd")
    stepRow(f, R, 378, RW, T("fd_scDrive"), mtr(c.drive), "drive")
    stepRow(f, R, 492, RW, T("fd_scTol"), mtr(c.tol), "tol")
    stepRow(f, R, 606, RW, T("fd_scDOn"), dec(c.dOn or 0.2, 2) .. " s", "dOn")
    stepRow(f, R, 720, RW, T("fd_scDOff"), dec(c.dOff or 0.2, 2) .. " s", "dOff")
    f.hot(1490, 797, 1650, 912, back("fdsc"))
    f.img(1500, 805, 140, 100, "as_fd_back")
    pageEnd(self, d, fh, "fdsc")
end
function M.scAction(self, a)
    local SC = AS_SectionControl
    local v = (self.data or {}).vehicle
    if SC == nil or v == nil then return end
    if a == "fdsc_auto" then SC:setCfg(v, "auto", 1)
    elseif a == "fdsc_manu" then SC:setCfg(v, "auto", 0)
    elseif a == "fdsc_done1" then SC:setCfg(v, "done", 1)
    elseif a == "fdsc_done0" then SC:setCfg(v, "done", 0)
    elseif a == "fdsc_boom1" then SC:setCfg(v, "boom", 1)
    elseif a == "fdsc_boom0" then SC:setCfg(v, "boom", 0)
    elseif a == "fdsc_tool" then M.scToolIx = (M.scToolIx or 1) + 1
    elseif a:sub(1, 8) == "fdsc_st_" then
        -- comme le Massey : régler le % du bord passe le bord sur « dès qu'il sort » (« à moitié » = 50 %)
        local key, dir = a:match("^fdsc_st_(%a+)_(%-?%d)$")
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
        local n = tonumber(a:match("^fdsc_bd(%d)$") or "")
        if n ~= nil and n >= 1 and n <= 3 then SC:setCfg(v, "bd", n) end
    end
    self.lastRead = -100000
end

-------------------------------------------------------------------------------
-- (05/11) Fendt TI = joystick de droite, 4 boutons GO GO END END
-- 4 touches ; chacune joue jusqu'à 3 fonctions avec leur état (liste des distributeurs), telles quelles, sans bascule.
-- Par défaut : GO = baisser puis allumer, END = éteindre puis lever ; touches 1 = arrière, touches 2 = avant
-------------------------------------------------------------------------------
M.TI_NAME = { "GO 1", "END 1", "GO 2", "END 2" }
M.TI_DEF = { { "lift_dn@r", "on_on@r" }, { "on_off@r", "lift_up@r" }, { "lift_dn@f", "on_on@f" }, { "on_off@f", "lift_up@f" } }
M.tiSel = 1
local TI_OK
function M.tiFns(self, v)
    if TI_OK == nil then
        TI_OK = {}
        for _, fn in ipairs(self.REMOTE_FNS or {}) do TI_OK[fn] = true end
    end
    local p = (v ~= nil and self.vehPrefs ~= nil) and self:vehPrefs(v) or nil
    local out = {}
    if p == nil or p.ti == nil then
        for i = 1, 4 do
            out[i] = {}
            for k, fn in ipairs(M.TI_DEF[i]) do out[i][k] = fn end
        end
        return out
    end
    local i = 0
    for w in string.gmatch(p.ti .. ",", "([^,]*),") do
        i = i + 1
        if i <= 4 then
            out[i] = {}
            for fn in string.gmatch(w, "[^+]+") do
                local b, sd = fn:match("^([%a_]+)(.*)$")
                if b ~= nil and b ~= "none" and TI_OK[b] and (sd == "" or sd == "@f" or sd == "@r") and #out[i] < (self.REMOTE_SLOTS or 3) then
                    out[i][#out[i] + 1] = fn
                end
            end
        end
    end
    for k = 1, 4 do out[k] = out[k] or {} end
    return out
end
function M.tiStore(self, v, t)
    local parts = {}
    for i = 1, 4 do parts[i] = table.concat(t[i] or {}, "+") end
    local p = self:vehPrefs(v, true)
    p.ti = table.concat(parts, ",")
    self:saveSettings()
end
function M.tiAction(self, a)
    local v = (self.data or {}).vehicle
    if v == nil then return end
    local t = M.tiFns(self, v)
    local n = tonumber(a:match("^fdti_run_(%d)$") or "")
    if n ~= nil then
        local fns = t[n] or {}
        if #fns == 0 then
            local ui = AS_Terminal.ui
            if ui ~= nil and ui.warn ~= nil then ui.warn(T("c_remoteNone")) end
        elseif self.fnsRun ~= nil then
            self:fnsRun(v, fns, M.TI_NAME[n])
        end
        M.tiLast = { n = n, at = g_time or 0 }
    elseif a:sub(1, 9) == "fdti_sel_" then
        M.tiSel = math.max(1, math.min(4, tonumber(a:sub(10)) or 1)); M.tiMenu = nil
    elseif a:sub(1, 10) == "fdti_slot_" then
        local k = tonumber(a:sub(11)) or 1
        M.tiMenu = M.tiMenu ~= k and k or nil
    elseif a:sub(1, 9) == "fdti_set_" then
        local k, fn = a:match("^fdti_set_(%d)_([%a_@]+)$")
        k = tonumber(k)
        if k ~= nil and fn ~= nil then
            local fns = t[M.tiSel or 1]
            if fn == "none" then
                if fns[k] ~= nil then table.remove(fns, k) end
            elseif k <= #fns then fns[k] = fn
            elseif #fns < (self.REMOTE_SLOTS or 3) then fns[#fns + 1] = fn end
            M.tiStore(self, v, t)
        end
        M.tiMenu = nil
    elseif a == "fdti_def" then
        local i = M.tiSel or 1
        t[i] = {}
        for k, fn in ipairs(M.TI_DEF[i]) do t[i][k] = fn end
        M.tiStore(self, v, t)
        M.tiMenu = nil
    end
    self.lastRead = -100000
end
-- touche GO / END (turquoise comme son joystick) ; flash clair juste après l'appui
function M.tiKey(self, f, x, y, w, h, n, fns, big)
    local flash = M.tiLast ~= nil and M.tiLast.n == n and (g_time or 0) - M.tiLast.at < 1200
    f.rect(x, y, w, h, flash and { 0.58, 0.86, 0.79, 1 } or TEAL)
    if big then
        f.ctr(x + w * 0.5, y + 52, 42, M.TI_NAME[n], WH, w - 20, true)
        for k = 1, 3 do
            if fns[k] ~= nil then f.ctr(x + w * 0.5, y + 108 + (k - 1) * 36, 15, self:remoteLabel(fns[k]), WH, w - 16) end
        end
        if #fns == 0 then f.ctr(x + w * 0.5, y + 140, 15, T("none"), WH, w - 16) end
    else
        f.ctr(x + w * 0.5, y + h * 0.5, 26, M.TI_NAME[n], WH, w - 12, true)
    end
    f.hot(x, y, x + w, y + h, "fdti_run_" .. n)
end
function M.ti(self, d, ctx, v, Wp, Hp)
    local f, fh = pageBase(self, d, ctx, v, Wp, Hp, "as_fd_blank", "fdti", "Fendt TI")
    local t = M.tiFns(self, v)
    local sel = math.max(1, math.min(4, M.tiSel or 1))
    local menu = M.tiMenu
    local fns = t[sel] or {}
    if menu == nil then
        -- le joystick : GO en haut, END en bas ; cadre vert = touche en réglage à droite
        f.rect(40, 150, 650, 560, { 0.22, 0.23, 0.25, 1 })
        local P = { { 70, 176 }, { 70, 444 }, { 380, 176 }, { 380, 444 } }
        for n = 1, 4 do
            local x, y = P[n][1], P[n][2]
            if n == sel then f.rect(x - 7, y - 7, 294, 254, GRN) end
            M.tiKey(self, f, x, y, 280, 240, n, t[n] or {}, true)
        end
        f.txt(40, 742, 18, T("fd_tiHint1"), GREY, nil, 650)
        f.txt(40, 780, 18, T("fd_tiHint2"), GREY, nil, 650)
    else
        -- liste des fonctions (AV | AR | Les deux) pour la ligne ouverte
        local heads = { { T("c_colF"), "@f" }, { T("c_colR"), "@r" }, { T("c_colB"), "" } }
        local x0, y0, cw, rh = 40, 150, 208, 48
        local cur = fns[menu] or "none"
        for c2, hd in ipairs(heads) do
            local cx = x0 + (c2 - 1) * (cw + 6)
            f.rect(cx, y0, cw, rh, { 0.25, 0.28, 0.31, 1 })
            f.ctr(cx + cw * 0.5, y0 + rh * 0.5, 20, hd[1], WH, cw - 10, true)
            for j = 2, #self.REMOTE_FNS do
                local fn = self.REMOTE_FNS[j] .. hd[2]
                local ry = y0 + (j - 1) * rh + 2
                local on = cur == fn
                f.rect(cx, ry, cw, rh - 3, on and GRN or WH)
                f.txt(cx + 8, ry + rh * 0.5, 15, self:remoteLabel(fn, true), on and WH or DK, nil, cw - 12)
                f.hot(cx, ry, cx + cw, ry + rh - 3, "fdti_set_" .. menu .. "_" .. fn)
            end
        end
        local ny = y0 + #self.REMOTE_FNS * rh + 4
        f.rect(x0, ny, cw * 3 + 12, rh - 3, cur == "none" and GRN or WH)
        f.ctr(x0 + (cw * 3 + 12) * 0.5, ny + rh * 0.5, 18, T("none"), cur == "none" and WH or DK, cw * 3)
        f.hot(x0, ny, x0 + cw * 3 + 12, ny + rh - 3, "fdti_set_" .. menu .. "_none")
    end
    -- droite : la touche choisie, ses 3 lignes, par défaut / essayer
    local R = 720
    for n = 1, 4 do
        local x = R + (n - 1) * 190
        local s = n == sel
        f.rect(x, 150, 180, 80, s and GRN or WH)
        f.rect(x, 150, 180, 8, TEAL)
        f.ctr(x + 90, 194, 24, M.TI_NAME[n], s and WH or DK, 170, true)
        f.hot(x, 150, x + 180, 230, "fdti_sel_" .. n)
    end
    for k = 1, (self.REMOTE_SLOTS or 3) do
        local y = 252 + (k - 1) * 102
        local open = menu == k
        f.rect(R, y, 750, 88, open and GRN or WH)
        f.ctr(R + 46, y + 44, 30, tostring(k), open and WH or GREY, 60, true)
        local fn = fns[k]
        local txt = fn ~= nil and self:remoteLabel(fn) or ((k <= #fns + 1) and "+" or "")
        f.txt(R + 100, y + 44, 24, txt, open and WH or DK, nil, 630, fn ~= nil)
        if k <= #fns + 1 then f.hot(R, y, R + 750, y + 88, "fdti_slot_" .. k) end
    end
    f.rect(R, 576, 365, 84, WH)
    f.ctr(R + 182, 618, 20, T("fd_tiDef"), DK, 350, true)
    f.hot(R, 576, R + 365, 660, "fdti_def")
    f.rect(R + 385, 576, 365, 84, GRN)
    f.ctr(R + 567, 618, 20, T("fd_tiTry") .. " " .. M.TI_NAME[sel], WH, 350, true)
    f.hot(R + 385, 576, R + 750, 660, "fdti_run_" .. sel)
    f.txt(R, 700, 18, T("fd_remHint1"), GREY, nil, 750)
    f.hot(1490, 797, 1650, 912, back("fdti"))
    f.img(1500, 805, 140, 100, "as_fd_back")
    pageEnd(self, d, fh, "fdti")
end

-- point d'entrée (drawPanel)
M.SCREENS = { fdlaunch = "launch", fdmotor = "motor", fdtms = "tms", fdhitchr = "hitchr", fdhitchf = "hitchf", fdhitchset = "hitchset",
    fdvalve = "valve", fdrem = "rem", fdlight = "light", fdpto = "pto", fdcomp = "comp", fdcomplist = "complist", fdcam = "cam", fdturn = "turn",
    fdsc = "sc", fdti = "ti" }
function M.screenFor(self)
    local p = self.page
    if p == "home" then return M.home end
    if p == "cam" then return M.cam end
    if p == "gps" then return M.guide end
    local k = M.SCREENS[p]
    if k ~= nil then return M[k] end
    return M.page
end

-- appuis propres au Fendt ; le reste passe au terminal
if AS_Terminal ~= nil and AS_Terminal.doAction ~= nil and not M.hooked then
    M.hooked = true
    local orig = AS_Terminal.doAction
    AS_Terminal.doAction = function(self, a, ...)
        if a == "fd_page" then
            M.homePage = M.homePage == 2 and 1 or 2
            self.lastRead = -100000
            return
        end
        if a == "fd_job1" or a == "fd_job2" or a == "fd_jobT" then
            local r = nil
            if a == "fd_job1" then r = orig(self, "job1", ...) elseif a == "fd_job2" then r = orig(self, "job2", ...) end
            self.page = "fdcomp"
            self.lastRead = -100000
            return r
        end
        if a:sub(1, 4) == "fdm_" then return M.motorAction(self, a) end
        if a:sub(1, 5) == "fdsc_" then return M.scAction(self, a) end
        if a:sub(1, 5) == "fdti_" then return M.tiAction(self, a) end
        if a == "page_fdsc" and self.page ~= "fdsc" then M.BACK.fdsc = self.page == "gps" and "gps" or (self.page == "home" and "home" or "fdlaunch") end
        if a == "page_fdti" and self.page ~= "fdti" then M.BACK.fdti = self.page == "home" and "home" or "fdlaunch"; M.tiMenu = nil end
        -- (05/11) réglages Courseplay du Guide,
        -- ouverts depuis le Launchpad : la flèche retour y revient
        if a == "fd_cp" then
            local G = AS_TerminalGps
            if G ~= nil then G.sub = "course" end
            M.cpFrom = self.page
            self.page = "gps"; self.lastRead = -100000
            return
        end
        if a == "gps_back" and M.cpFrom ~= nil then
            local p = M.cpFrom
            M.cpFrom = nil
            local r = orig(self, a, ...)
            self.page = p; self.lastRead = -100000
            return r
        end
        if a:sub(1, 8) == "fdv_sel_" then
            M.vSel = tonumber(a:sub(9)) or 1
            self.remoteMenu = nil
            if self.page ~= "fdrem" then M.BACK.fdrem = self.page == "home" and "home" or "fdvalve" end
            self.page = "fdrem"; self.lastRead = -100000
            return
        end
        if a == "fdt_none" then return end
        if a == "fdt_mode" or a == "fdt_head" or a == "fdt_skip" then return M.turnAction(self, a) end
        if a:sub(1, 4) == "fdg_" then
            local G = AS_TerminalGps
            if G ~= nil then
                if a == "fdg_3d" then M.gview = "persp"
                elseif a == "fdg_2d" then M.gview = "top"
                elseif a == "fdg_view" then M.gview = M.gview == "top" and "persp" or "top"
                elseif a == "fdg_zin" or a == "fdg_zout" then
                    local n = M.gview == "top" and #G.TOP or #G.PERSP
                    G.zoom = math.max(1, math.min(n, (G.zoom or 2) + (a == "fdg_zin" and -1 or 1)))
                elseif a == "fdg_course" then G.sub = "course"; self.page = "gps"; M.cpFrom = nil end
                G.drawCache = nil
            end
            self.lastRead = -100000
            return
        end
        if a == "rearcam_fd" then self.page = "fdcam"; self.lastRead = -100000; return end
        if a == "page_fdhitchset" and (self.page == "fdhitchf" or self.page == "fdhitchr") then M.BACK.fdhitchset = self.page end
        if a == "page_home" then M.homePage = M.homePage or 1 end
        return orig(self, a, ...)
    end
end
