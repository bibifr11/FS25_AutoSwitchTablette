-- AutoSwitch : terminal des tracteurs et ensileuses John Deere (G5 CommandCenter)
-- Fichier chargé par AutoSwitch.lua après Terminal.lua (et TerminalDeutz.lua, TerminalFendt.lua : pages Courseplay et
-- réglages des tronçons partagées).
--
-- (06/11) même méthode que le Deutz : les écrans HD (refaits d'après les vraies captures G5 et
-- CommandPRO), sans texte dans les images ; textes et valeurs écrits en direct (FR / EN / DE).
--   Cadre fixe (méthode blocs) : barre verte du haut, barre des 13 touches en bas, colonne Guidage à droite ;
--   chaque élément qui bouge (curseurs, interrupteurs, voyants, onglets) est un carré découpé, reposé par le code.
-- Repères en pixels des écrans 1672 x 941 ; fenêtres (menu, PdF, transmission, feux, tronçons, réglages) en pixels
-- de leur propre image (WIN).

AS_TerminalJohnDeere = {}
local M = AS_TerminalJohnDeere
M.MOD_NAME = g_currentModName

local WH = { 1, 1, 1, 1 }
local DK = { 0.07, 0.07, 0.05, 1 }
local GREY = { 0.40, 0.40, 0.36, 1 }
local JDG = { 0.094, 0.557, 0.031, 1 }        -- vert de la barre du haut
local YEL = { 1.00, 0.84, 0.00, 1 }
local OLIVE = { 0.286, 0.302, 0.075, 1 }       -- en-têtes des cases
local CREAM = { 0.961, 0.949, 0.898, 1 }
local RED = { 0.85, 0.12, 0.10, 1 }
local AMBER = { 0.95, 0.60, 0.05, 1 }
local OFF = { 0.96, 0.95, 0.90, 0.62 }          -- voile sur ce qui n'a pas d'équivalent dans le jeu
local KEYB, KEYL, KEYD = { 0.36, 0.36, 0.31, 1 }, { 0.95, 0.94, 0.90, 1 }, { 0.84, 0.82, 0.72, 1 }
local SIGCOL = { fix = { 0.30, 0.90, 0.20, 1 }, float = { 1.00, 0.60, 0.15, 1 }, gps = { 1.00, 0.80, 0.20, 1 }, lost = { 1.00, 0.30, 0.25, 1 } }
local function clamp01(t) return math.max(0, math.min(1, t or 0)) end
local function lin(c)
    if c <= 0.04045 then return c / 12.92 end
    return ((c + 0.055) / 1.055) ^ 2.4
end
-- (70b) textes agrandis : l'écran du jeu est bien plus petit qu'un vrai G5
function M.tsize(size)
    if size < 20 then return size * 1.25 elseif size < 30 then return size * 1.12 end
    return size
end
-- (70b) écran 3D : les fonds dessinés par le code sont des morceaux d'image
-- de leur vraie couleur (as_jd_c_rrggbb), éclairés comme les pages ; avant : 40 couleurs lumineuses (vert fluo)
M.SW = { as_jd_c_2a2a12 = true, as_jd_c_26261a = true, as_jd_c_333329 = true, as_jd_c_e8e6d6 = true, as_jd_c_0054ff = true, as_jd_c_0a0d0f = true, as_jd_c_0f940f = true, as_jd_c_121212 = true,
     as_jd_c_188e08 = true, as_jd_c_1a1a12 = true, as_jd_c_1f1f14 = true, as_jd_c_29331f = true,
     as_jd_c_333626 = true, as_jd_c_383838 = true, as_jd_c_40421a = true, as_jd_c_494d13 = true,
     as_jd_c_5c5c4f = true, as_jd_c_8c8c85 = true, as_jd_c_9400ff = true, as_jd_c_94948c = true,
     as_jd_c_d8d0b2 = true, as_jd_c_d91f1a = true, as_jd_c_dbdbd6 = true, as_jd_c_edede8 = true,
     as_jd_c_f0f0ed = true, as_jd_c_f2f0e6 = true, as_jd_c_f5efd3 = true, as_jd_c_f5f2e5 = true,
     as_jd_c_fafaf7 = true, as_jd_c_fcfcfa = true, as_jd_c_ffd600 = true, as_jd_c_ffffff = true, }
local function hex(c)
    local function b(x) return math.floor(math.max(0, math.min(1, x)) * 255 + 0.5) end
    return string.format("%02x%02x%02x", b(c[1]), b(c[2]), b(c[3]))
end
M.hex = hex

local function H() return AS_Terminal.MFH end
local function T(key) return H().T(key) end

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
        col = col or DK
        size = M.tsize(size)
        local c = col
        if ctx.rec == nil then
            -- (70b) grande fenêtre : le jeu éclaircit les couleurs des textes (noir -> gris clair) ; passées en linéaire
            -- comme les fonds, petits textes en gras
            c = { lin(col[1]), lin(col[2]), lin(col[3]), col[4] or 1 }
            bold = bold == true or size < 24
        end
        ctx.text(f.PX(x), f.PY(ymid + size * 0.36), f.PY(size), s, c, align or RenderText.ALIGN_LEFT, bold == true, maxW and f.PW(maxW) or nil)
        if ctx.rec ~= nil then
            -- (70b) écran 3D : textes clairs lumineux (sur bandeaux foncés), textes foncés ou de couleur = encre sur l'écran
            local t = ctx.rec.texts[#ctx.rec.texts]
            if t ~= nil then
                local mx, mn = math.max(col[1], col[2], col[3]), math.min(col[1], col[2], col[3])
                t.em = ((col[1] + col[2] + col[3]) / 3 >= 0.6 and mx - mn <= 0.15) and 1 or 0.12
                -- largeur donnée par la page : pas de recherche de la case (les touches en 3 morceaux la faussaient)
                if maxW ~= nil then t.noRoom = true end
            end
        end
    end
    function f.ctr(x, ymid, size, s, col, maxW, bold) f.txt(x, ymid, size, s, col, RenderText.ALIGN_CENTER, maxW, bold) end
    function f.rgt(x, ymid, size, s, col, maxW, bold) f.txt(x, ymid, size, s, col, RenderText.ALIGN_RIGHT, maxW, bold) end
    local hot = ctx.hotspot or ctx.button
    function f.hot(x0, y0, x1, y1, action) hot(f.PX(x0), f.PY(y0), f.PW(x1 - x0), f.PY(y1 - y0), action) end
    function f.rect(x, y, w, h, c)
        if ctx.rec ~= nil then
            if (c[4] or 1) < 0.99 then return end
            local sw = "as_jd_c_" .. hex(c)
            if M.SW[sw] then f.img(x, y, w, h, sw) return end
            if M.swMiss ~= nil then M.swMiss[sw] = true end
        end
        ctx.rect(f.PX(x), f.PY(y), f.PW(w), f.PY(h), c)
    end
    function f.box(x0, y0, x1, y1)
        if ctx.X == nil then return nil end
        return { x = ctx.X(f.PX(x0)), y = ctx.Y(f.PY(y1)), w = ctx.sx(f.PW(x1 - x0)), h = ctx.sy(f.PY(y1 - y0)) }
    end
    f.ctx = ctx
    return f
end

-- fenêtre posée au centre (menu, PdF, transmission, feux, tronçons, réglages) : repères de sa propre image
-- { x posé, y posé, échelle, x0 de la découpe, y0 de la découpe } (build_jd.py, windows.txt)
M.WIN = { menu = { 219, 92, 1234 / 1415, 130, 62 }, pto = { 203, 92, 1265 / 1672 }, trans = { 203, 92, 1265 / 1672 },
    lights = { 284, 92, 1104 / 1556 }, sc = { 284, 92, 1104 / 1556 }, set = { 279, 92, 1113 / 1568 } }
local function win(f, key)
    local w = M.WIN[key]
    local ox, oy, k, cx, cy = w[1], w[2], w[3], w[4] or 0, w[5] or 0
    local g = { k = k }
    local function X(x) return ox + (x - cx) * k end
    local function Y(y) return oy + (y - cy) * k end
    g.X, g.Y = X, Y
    function g.img(x, y, ww, hh, name) f.img(X(x), Y(y), ww * k, hh * k, name) end
    function g.txt(x, ym, size, s, col, align, maxW, bold) f.txt(X(x), Y(ym), size * k, s, col, align, maxW and maxW * k or nil, bold) end
    function g.ctr(x, ym, size, s, col, maxW, bold) g.txt(x, ym, size, s, col, RenderText.ALIGN_CENTER, maxW, bold) end
    function g.rgt(x, ym, size, s, col, maxW, bold) g.txt(x, ym, size, s, col, RenderText.ALIGN_RIGHT, maxW, bold) end
    function g.hot(x0, y0, x1, y1, a) f.hot(X(x0), Y(y0), X(x1), Y(y1), a) end
    function g.rect(x, y, ww, hh, c) f.rect(X(x), Y(y), ww * k, hh * k, c) end
    function g.off(x0, y0, x1, y1) g.rect(x0, y0, x1 - x0, y1 - y0, OFF) end
    return g
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
local function pctTxt(x) return string.format("%d %%", math.floor((x or 0) + 0.5)) end
local function hm(ms)
    local m = math.floor((ms or 0) / 60000)
    return string.format("%d:%02d", math.floor(m / 60), m % 60)
end
-- vitesse maxi du tracteur (échelle des vitesses mémorisées) et 2e vitesse mémorisée (partagée avec le Deutz)
local function vTop(v, d)
    local cc = v ~= nil and v.spec_drivable ~= nil and v.spec_drivable.cruiseControl or nil
    local top = cc ~= nil and tonumber(cc.maxSpeed) or nil
    if top == nil or top < 5 then top = d.maxSpeed end
    if top == nil or top < 5 then top = 50 end
    return top
end
local function mem2Of(v, d)
    local D = AS_TerminalDeutz
    return (D ~= nil and D.mem2 ~= nil and D.mem2[v]) or math.floor(vTop(v, d) * 0.5 + 0.5)
end
local function jobOf(d)
    local cnt = d.cnt
    if cnt == nil then return nil end
    if cnt.jobs ~= nil and cnt.jobs[cnt.active or 1] ~= nil then return cnt.jobs[cnt.active or 1] end
    return cnt.total
end
local function rtkSig(d)
    local G = AS_TerminalGps
    if G ~= nil and d.vehicle ~= nil and G.rtkSignal ~= nil then
        local ok, s = pcall(G.rtkSignal, G, d.vehicle)
        if ok and s ~= nil then return s end
    end
    return "gps"
end
local function satCount()
    local now = g_time or 0
    return math.max(15, math.min(22, math.floor(18.5 + 2.5 * math.sin(now / 97000) + 1.0 * math.sin(now / 23000) + 0.5)))
end
local function farmName(v)
    local ok, n = pcall(function()
        local fid = v:getOwnerFarmId()
        local fm = g_farmManager:getFarmById(fid)
        return fm ~= nil and fm.name or nil
    end)
    return (ok and n ~= nil and n ~= "") and tostring(n) or "--"
end
local function playerName()
    local ok, n = pcall(function()
        if g_currentMission ~= nil and g_currentMission.playerNickname ~= nil and g_currentMission.playerNickname ~= "" then return g_currentMission.playerNickname end
        if g_gameSettings ~= nil and g_gameSettings.getValue ~= nil then return g_gameSettings:getValue("nickname") end
        return nil
    end)
    return (ok and n ~= nil and n ~= "") and tostring(n) or "--"
end
local function fieldTxt(d)
    if d.field == nil then return T("outField") end
    return string.format(T("field"), d.field)
end
local function xteTxt(g)
    if g == nil or g.data == nil or not g.onLine or g.inTurn or g.xte == nil then return "--" end
    return string.format("%d cm", math.floor(math.abs(g.xte) * 100 + 0.5))
end

-- touche grise en relief dessinée (pages sans image : réglages, fenêtres, colonne des touches)
-- (70b) touche G5 dessinée en 3 morceaux d'image
-- (bouts arrondis gardés ronds, milieu étiré) : normale, allumée (barre verte), sans action (grisée)
local function key(f, x0, y0, x1, y1, label, act, on, sub, size, pfx)
    local h = y1 - y0
    -- pfx « kp » : mêmes touches, fond de la colonne de droite (241,239,213) au lieu du crème (70g)
    local st = (pfx or "k"):sub(2) .. (act == nil and "x" or (on and "o" or "n"))
    local cw = math.min(h * 0.5, (x1 - x0) * 0.5)
    f.img(x0, y0, cw, h, "as_jd_k" .. st .. "_l")
    f.img(x1 - cw, y0, cw, h, "as_jd_k" .. st .. "_r")
    if x1 - x0 - 2 * cw > 0.5 then f.img(x0 + cw - 1, y0, x1 - x0 - 2 * cw + 2, h, "as_jd_k" .. st .. "_m") end
    size = size or 18
    local col = act == nil and { 0.62, 0.61, 0.56, 1 } or DK
    local cy = y0 + h * 0.44
    if sub ~= nil and sub ~= "" then
        f.ctr((x0 + x1) * 0.5, y0 + h * 0.32, size, label or "", col, x1 - x0 - 24, true)
        f.ctr((x0 + x1) * 0.5, y0 + h * 0.62, size * 0.8, sub, act == nil and col or GREY, x1 - x0 - 24)
    else
        f.ctr((x0 + x1) * 0.5, cy, size, label or "", col, x1 - x0 - 24, true)
    end
    if act ~= nil then f.hot(x0, y0, x1, y1, act) end
end
-- case crème à en-tête olive (page tracteur, alertes)
local function module(f, x0, y0, x1, y1, title, hcol)
    f.rect(x0, y0, x1 - x0, y1 - y0, CREAM)
    f.rect(x0, y0, x1 - x0, 34, hcol or OLIVE)
    if title ~= nil then f.txt(x0 + 10, y0 + 17, 18, title, WH, nil, x1 - x0 - 20, true) end
end

-------------------------------------------------------------------------------
-- carte en direct
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
    if not ok and not M.loggedMap then M.loggedMap = true; print("[AS_Terminal] John Deere : ERREUR carte : " .. tostring(err)) end
end
-- caméra arrière (fenêtre seulement : l'écran 3D de la cabine n'a pas d'image de caméra)
local function camView(self, ctx, v, f, x0, y0, x1, y1)
    f.rect(x0, y0, x1 - x0, y1 - y0, { 0.07, 0.07, 0.07, 1 })
    f.hot(x0, y0, x1, y1, "rearcam")
    local ok = false
    if ctx.rec == nil and self.settings.rearCam ~= false and self.rearCamOverlay ~= nil then
        local ov = self:rearCamOverlay(v)
        if ov ~= nil then
            local P = self.REAR_CAM or { resX = 16, resY = 9 }
            local bw, bh = x1 - x0, y1 - y0
            local cw = bw
            local ch = cw * P.resY / P.resX
            if ch > bh then ch = bh; cw = ch * P.resX / P.resY end
            local cx, cy = x0 + (bw - cw) * 0.5, y0 + (bh - ch) * 0.5
            ctx.image(f.PX(cx), f.PY(cy), f.PW(cw), f.PY(ch), ov)
            ok = true
        end
    end
    if not ok then f.ctr((x0 + x1) * 0.5, (y0 + y1) * 0.5, 22, self.settings.rearCam == false and T("c_camOff") or T("jd_camNone"), WH, x1 - x0 - 20) end
end

-------------------------------------------------------------------------------
-- Cadre fixe : barre du haut, barre des 13 touches, colonne Guidage
-------------------------------------------------------------------------------
function M.alerts(self, d)
    local out = {}
    local s = self.settings or {}
    if d.fuel ~= nil and d.fuel * 100 < (s.fuelReserve or 10) then out[#out + 1] = { RED, string.format(T("jd_aFuel"), math.floor(d.fuel * 100 + 0.5)) } end
    if (d.temp or 0) > 100 then out[#out + 1] = { RED, string.format(T("jd_aTemp"), math.floor(d.temp + 0.5)) } end
    if d.def ~= nil and d.def < 0.1 then out[#out + 1] = { AMBER, string.format(T("jd_aDef"), math.floor(d.def * 100 + 0.5)) } end
    if (d.damage or 0) > 0.5 then out[#out + 1] = { AMBER, string.format(T("jd_aDamage"), math.floor(d.damage * 100 + 0.5)) } end
    if (d.slip or 0) > 25 then out[#out + 1] = { AMBER, string.format(T("jd_aSlip"), math.floor(d.slip + 0.5)) } end
    if rtkSig(d) == "lost" then out[#out + 1] = { RED, T("jd_aRtk") } end
    local m = d.mach
    if m ~= nil and m.tank ~= nil and m.tank.cap > 0 and m.tank.level / m.tank.cap > 0.9 then out[#out + 1] = { AMBER, T("jd_aTank") } end
    for _, t in ipairs(d.tools or {}) do
        local fl = t.fills ~= nil and t.fills[1] or nil
        if fl ~= nil and fl.cap > 0 and fl.level / fl.cap < 0.1 and t.on then out[#out + 1] = { AMBER, string.format(T("jd_aToolEmpty"), t.name) } end
    end
    return out
end

function M.topBar(self, d, f, title)
    f.txt(26, 42, 30, title or "", WH, nil, 800, true)
    f.rgt(1016, 42, 28, H().fmtClock(), WH, 190, true)
    -- (70e) maison à côté de l'horloge : retour à la page Tracteur du démarrage
    f.img(1040, 14, 56, 56, "as_jd_home")
    f.hot(1032, 0, 1100, 85, "jdhome")
    -- nuage « ! » : alertes ; satellite : signal RTK ; barres : satellites
    local n = #M.alerts(self, d)
    if n > 0 then
        f.rect(1160, 8, 30, 26, RED)
        f.ctr(1175, 21, 18, tostring(n), WH, 30, true)
    end
    f.hot(1100, 0, 1195, 85, "page_jdalert")
    local sg = rtkSig(d)
    f.ctr(1232, 76, 13, sg == "fix" and "RTK" or (sg == "float" and "FLOAT" or (sg == "lost" and "--" or "GPS")), SIGCOL[sg] or WH, 80, true)
    f.ctr(1325, 76, 13, satCount() .. " sat", WH, 90)
    f.hot(1398, 0, 1533, 85, "jdback")
    f.hot(1533, 0, 1670, 85, "jdnext")
    self.headerBox = f.box(0, 0, 1030, 85)
end

-- (70b) barre du bas reconstruite : 13 touches identiques
-- (as_jd_bk01..13, icônes reprises du cadre validé), écarts égaux
M.KX = {}
for i = 0, 13 do M.KX[i + 1] = 6 + i * 128 end
-- (70d, 06/11) touche de la page ouverte en vert, fonctions marche/arrêt en vert quand en
-- marche, appui visible (vert un instant), touche sans effet possible grisée (+ message si on appuie quand même)
-- { action, libellé, genre, page }
M.KEYS = {
    { "page_jdset", "jd_kSetup", "pg", "set" }, { "page_jdcount", "jd_kWork", "pg", "count" }, { "page_jdsc", "jd_kSection", "pg", "sc" },
    { "jdsc_auto", "jd_kSC", "sc" }, { "gps_steer", "jd_kAutoTrac", "steer" }, { "page_gps", "jd_kGuide", "pg", "guide" },
    { "gps_lane", "jd_kSwap", "lane" }, { "page_fp", "jd_kLine", "fp", nil, "FarmPilot" }, { "page_jdiso", "jd_kIso", "pg", "iso" },
    { "beeps", "jd_kSound", "beeps" }, { nil, "jd_kFlag", "off" }, { "help", "jd_kHelp", "act" },
    { "page_jdmenu", "jd_kMenu", "pg", "menu" } }
M.FLASH_MS = 400
local function vcall(v, fn, ...)
    if v == nil or type(v[fn]) ~= "function" then return nil end
    local ok, r = pcall(v[fn], v, ...)
    if ok then return r end
    return nil
end
-- (70e) Guidage et Ligne rapide ouvraient la même chose : Ligne rapide ouvre FarmPilot
local function fpOk(v)
    local F = AS_TerminalFp
    if F == nil or F.available == nil then return false end
    local ok, r = pcall(F.available, F, v)
    return ok and r == true
end
-- Courseplay : changement de voie (outils multiples) possible ?
local function laneOk(v)
    local lane = vcall(v, "getCpLaneOffsetSetting")
    if lane == nil then return false end
    if type(lane.getIsVisible) == "function" then
        local ok, vis = pcall(lane.getIsVisible, lane)
        if ok and vis == false then return false end
    end
    return true
end
-- état d'une touche : allumée, utilisable
function M.keyState(self, d, v, page, k)
    local g = d.gps or {}
    local st = k[3]
    if st == "pg" then
        local p = k[4]
        if p == "count" then return page == "count" or page == "jdcount2", true end
        if p == "guide" then return page == "guide" or page == "gps", true end
        return page == p, true
    elseif st == "sc" then
        local SC = AS_SectionControl
        return SC ~= nil and v ~= nil and (SC:cfg(v).auto or 0) == 1, SC ~= nil and v ~= nil
    elseif st == "steer" then return g.steer == "on" or g.active == true, true
    elseif st == "lane" then return false, laneOk(v)
    elseif st == "fp" then return page == "fp", fpOk(v)
    elseif st == "beeps" then return self.settings.beeps ~= false, true
    elseif st == "off" then return false, false   -- (70e) touche grisée, sans action
    end
    return false, true
end
function M.bottomBar(self, d, f, v, page)
    f.rect(0, 804, 1672, 137, { 0.149, 0.149, 0.102, 1 })
    local now = g_time or 0
    local fl = M.flash
    if fl ~= nil and now - fl.t > M.FLASH_MS then M.flash = nil; fl = nil end
    for i, k in ipairs(M.KEYS) do
        local x0, x1 = M.KX[i], M.KX[i + 1] - 4
        local on, usable = M.keyState(self, d, v, page, k)
        if fl ~= nil and fl.i == i and usable then on = true end
        -- (70f) touche engagée ou page
        -- ouverte = touche entière verte, icône blanche (gen_bar_on.py) ; impossible = grisée ; sinon crème
        local img = (i < 13 and on) and "as_jd_bk%02do" or (usable and "as_jd_bk%02d" or "as_jd_bk%02dg")
        f.img(x0, 810, x1 - x0, 124, string.format(img, i))
        local label = k[5] or T(k[2])
        -- (13/11) sans FarmPilot : la touche reprend son nom du vrai G5, grisée
        if k[3] == "fp" and AS_Terminal.ui ~= nil and AS_Terminal.ui.fpInstalled ~= nil and not AS_Terminal.ui.fpInstalled() then label = T(k[2]) end
        if i == 13 then
            -- Menu : touche verte ; page Menu ouverte = bande blanche sous le libellé
            if on then f.rect(x0 + 3, 931, x1 - x0 - 6, 3, WH) end
            f.ctr((x0 + x1) * 0.5, 918, 14, label, WH, x1 - x0 - 6, true)
        else
            f.ctr((x0 + x1) * 0.5, 918, 14, label, on and WH or (usable and DK or { 0.62, 0.61, 0.56, 1 }), x1 - x0 - 6, true)
        end
        if k[1] ~= nil then f.hot(x0, 806, x1, 941, "jdk_" .. i) end
    end
end

-- colonne de droite (Guidage + Courseplay), sur la carte, les relevages et les distributeurs
function M.rightCol(self, d, f, v)
    local g = d.gps or {}
    f.txt(1416, 113, 18, g.hasCp and "Courseplay" or T("jd_guide"), WH, nil, 240, true)
    local lbl, act, col = T("gps_course"), "gps_course", DK
    local state
    local active = g.active == true
    if g.data ~= nil then
        local lost = not active and AS_TerminalGps ~= nil and AS_TerminalGps.rtkLost ~= nil and AS_TerminalGps:rtkLost(v)
        lbl, act = active and T("cpStop") or T("cpGo"), "gps_steer"
        state = active and T("cpActive") or (lost and T("gps_noRtk") or (g.canStart and T("cpReady") or T("cpNotReady")))
        col = active and JDG or (lost and RED or DK)
    elseif g.hasCp then
        lbl, act = T("cpGenerate"), "cp_cgui"
        state = T("cpNoCourse")
    end
    f.ctr(1537, 213, 20, lbl, DK, 205, true)
    if active then f.rect(1432, 238, 210, 7, JDG) end
    f.hot(1428, 180, 1646, 248, act)
    local R = AS_TerminalCourses
    if g.data == nil and g.hasCp and R ~= nil then
        -- (70g, comme le Deutz) : touche sous Créer
        -- parcours ; la ligne d'état passe dessous, en petit
        local busy = R.job ~= nil and R.job.vehicle == v and not R.job.done
        key(f, 1425, 256, 1653, 334, T("cpFind"), "cp_find", busy, state, 17, "kp")
    elseif state ~= nil then f.ctr(1537, 272, 15, state, col, 225, true) end
    if g.data ~= nil and self.cpCourseName ~= nil then f.ctr(1537, 300, 14, self:cpCourseName(v, d) or "", GREY, 225) end
    f.ctr(1537, 352, 16, T("gps_shift") .. " " .. ((g.offset ~= nil and string.format("%+.2f m", g.offset)) or "0"), DK, 225, true)
    f.hot(1428, 376, 1646, 466, "gps_off0")
    f.hot(1428, 483, 1528, 576, "gps_shiftL"); f.hot(1548, 483, 1646, 576, "gps_shiftR")
    if g.offsetDisabled then f.rect(1428, 376, 218, 200, OFF) end
    -- bas : menu Courseplay, écart
    if g.hasCp then
        -- (70b) vraie touche sous ▶| / |◀
        key(f, 1425, 586, 1653, 656, "COURSEPLAY", "page_jdcp", self.page == "jdcp", nil, 19, "kp")
    end
    f.txt(1416, 692, 17, fieldTxt(d), WH, nil, 240, true)
    f.txt(1416, 735, 16, T("jd_xte"), GREY, nil, 120)
    f.rgt(1650, 735, 20, xteTxt(g), DK, 120, true)
    local j = jobOf(d)
    f.txt(1416, 775, 16, T("jd_area"), GREY, nil, 120)
    f.rgt(1650, 775, 20, j ~= nil and (dec(j.ha or 0, 2) .. " ha") or "--", DK, 130, true)
end

-- fin de chaque page : barres du cadre
local function chassis(self, d, f, v, page, title)
    M.topBar(self, d, f, title)
    M.bottomBar(self, d, f, v, page)
end

-------------------------------------------------------------------------------
-- 01 Guidage : carte en direct, barre d'outils, barre de guidage (écart), ronds de la carte, colonne Guidage
-------------------------------------------------------------------------------
M.RB = { { 83, 270, "page_jdsc", "jd_rbCover" }, { 213, 270, "gps_view", "jd_rbView" }, { 1330, 270, "gps_lane", "jd_rbLane" },
    { 83, 584, "gps_course", "jd_rbCourse" }, { 83, 718, "page_jdcp", "jd_rbCp" }, { 1331, 718, "gps_rec", "jd_rbRec" } }
-- (70b) parcours Courseplay trouvés pour ce champ : liste posée dans la carte, cases G5 (avant : liste du Deutz
-- par-dessus la barre d'outils)
function M.cpList(self, d, f, v)
    local R = AS_TerminalCourses
    if R == nil then return end
    pcall(R.auto, R, v, d)
    local r = R.results
    local busy = R.job ~= nil and R.job.vehicle == v and not R.job.done
    if (r == nil or r.vehicle ~= v) and not busy then return end
    local x0, x1, y0 = 182, 1238, 362
    local list = (r ~= nil and r.vehicle == v and r.msg == nil) and r.list or {}
    local n = math.min(#list, R.SHOWN or 6, 6)
    local h = 44 + math.max(1, n) * 58 + 10
    f.rect(x0 - 3, y0 - 3, x1 - x0 + 6, h + 6, { 0.20, 0.20, 0.16, 1 })
    if r == nil or r.vehicle ~= v then
        module(f, x0, y0, x1, y0 + h, "Courseplay")
        f.ctr((x0 + x1) * 0.5, y0 + 80, 20, T("cpFindBusy"), DK, x1 - x0 - 30)
        return
    end
    local fieldTxt = tostring(r.field or "-")
    if r.linkedTxt ~= nil then fieldTxt = fieldTxt .. " (+" .. r.linkedTxt .. ")" end
    module(f, x0, y0, x1, y0 + h, string.format(T("cpFindHead"), fieldTxt, r.width ~= nil and string.format("%.1f m", r.width) or "-"))
    if r.msg ~= nil or n == 0 then
        f.ctr((x0 + x1) * 0.5, y0 + 80, 20, r.msg or T("cpSavesNone"), AMBER, x1 - x0 - 30, true)
        return
    end
    for i = 1, n do
        local e = list[i]
        local yy = y0 + 44 + (i - 1) * 58
        local on = r.loaded == i
        f.rect(x0 + 8, yy, x1 - x0 - 16, 54, on and JDG or ((i % 2 == 0) and { 0.91, 0.90, 0.84, 1 } or WH))
        local col = on and WH or DK
        local label = (e.dir ~= nil and e.dir ~= "" and (e.dir .. "  -  ") or "") .. tostring(e.fname)
        f.txt(x0 + 24, yy + 27, 18, label, col, nil, 560, true)
        local right = string.format("%s   %s   %s", string.format(T("cpFindField"), e.fieldTxt or "-"),
            e.w ~= nil and string.format("%.1f m", e.w) or "-", e.h ~= nil and string.format(T("cpFindHl"), e.h) or "")
        f.rgt(x1 - 80, yy + 27, 15, right, on and WH or (e.ok and JDG or GREY), 380)
        if e.ok then f.rgt(x1 - 22, yy + 27, 18, "OK", on and WH or JDG, 50, true) end
        f.hot(x0 + 8, yy, x1 - 8, yy + 54, "cp_load" .. i)
    end
end
local function lightbar(f, g)
    local cx = 701
    local on = g.data ~= nil and g.onLine and not g.inTurn and g.xte ~= nil
    if not on then return end
    local x = g.xte
    local n = math.min(12, math.floor(math.abs(x) / 0.05 + 0.5))
    if n == 0 then f.rect(cx - 22, 165, 44, 40, JDG) return end
    local sgn = x > 0 and 1 or -1
    for i = 1, n do
        local xx = cx + sgn * (i - 1) * 46 + (sgn > 0 and 2 or -44)
        f.rect(xx, 165, 42, 40, i <= 3 and YEL or RED)
    end
end
function M.guide(self, d, ctx, v, Wp, Hp, inside)
    local G = AS_TerminalGps
    if G ~= nil and G.sub == "course" then return M.page(self, d, ctx, v, Wp, Hp, inside) end
    local f = frame(self, ctx, Wp, Hp)
    local g = d.gps or {}
    f.img(0, 0, 1672, 941, "as_jd_gps")
    f.rect(8, 209, 1388, 597, { 0.16, 0.20, 0.12, 1 })
    liveMap(self, d, ctx, v, f, 8, 209, 1396, 806, (G ~= nil and G.view) or "top")
    -- ronds de la carte (nom écrit dessous)
    for i, b in ipairs(M.RB) do
        local lw = (i == 1 or i == 2) and 122 or 160
        local lx = (b[1] < 700) and b[1] - 50 or b[1] + 50 - lw
        f.rect(lx, b[2] - 50, lw, 130, { 0.10, 0.10, 0.07, 1 })
        -- (13/11) rond Courseplay seulement si Courseplay est installé
        if b[3] ~= "page_jdcp" or AS_Terminal.ui == nil or AS_Terminal.ui.cpInstalled == nil or AS_Terminal.ui.cpInstalled() then
            f.img(lx + lw * 0.5 - 46, b[2] - 46, 92, 92, "as_jd_s_rb" .. i)
            f.hot(lx, b[2] - 50, lx + lw, b[2] + 80, b[3])
            f.ctr(lx + lw * 0.5, b[2] + 65, 15, T(b[4]), WH, lw - 8, true)
        end
    end
    if g.recording then f.rect(1290, 680, 80, 6, RED) end
    if g.hasCp and g.data == nil then
        local okL, errL = pcall(M.cpList, self, d, f, v)
        if not okL and not M.loggedList then M.loggedList = true; print("[AS_Terminal] John Deere : ERREUR liste des parcours : " .. tostring(errL)) end
    end

    -- barre d'outils : compteurs, (déplacer : pas dans le jeu), écart, zoom - / +
    local TB = { { 8, 286, "page_jdcount", "jd_tbWork" }, { 286, 571, nil, "jd_tbPan" }, { 855, 1133, "gps_zoomOut", "jd_tbZoomOut" }, { 1133, 1395, "gps_zoomIn", "jd_tbZoomIn" } }
    for _, b in ipairs(TB) do
        local cx = (b[1] + b[2]) * 0.5
        f.txt(cx + 34, 127, 16, T(b[4]), CREAM, nil, (b[2] - b[1]) * 0.5 - 40, true)
        if b[3] ~= nil then f.hot(b[1], 92, b[2], 160, b[3]) else f.rect(b[1] + 4, 94, b[2] - b[1] - 8, 64, { 0.29, 0.30, 0.08, 0.62 }) end
    end
    f.ctr(713, 127, 30, xteTxt(g), CREAM, 270, true)
    lightbar(f, g)
    M.rightCol(self, d, f, v)
    chassis(self, d, f, v, "guide", T("jd_guide"))
end

-------------------------------------------------------------------------------
-- 02 Menu : onglets (Machine, Système, Applications), 10 applications (nom écrit dessous), touches des autres pages
-------------------------------------------------------------------------------
M.MENU = { { 537, 265, "page_jdtrac", "jd_trac" }, { 756, 265, "page_jdhitchr", "jd_hitch" }, { 972, 265, "page_jdvalve", "jd_valves" },
    { 1193, 265, "page_jdpto", "jd_pto" }, { 1414, 265, "page_jdlight", "jd_lights" },
    { 537, 554, "page_jdcam", "jd_cam" }, { 756, 554, "page_jdiso", "jd_iso" }, { 972, 554, "page_jdsc", "jd_mSc" },
    { 1193, 554, "page_jdtrans", "jd_trans" }, { 1414, 554, "page_jdset", "jd_mSet" } }
function M.menu(self, d, ctx, v, Wp, Hp)
    local f = frame(self, ctx, Wp, Hp)
    f.img(0, 0, 1672, 941, "as_jd_menu")
    local w = win(f, "menu")
    w.txt(330, 100, 36, T("jd_kMenu"), WH, nil, 900, true)
    w.hot(1450, 70, 1540, 126, "jdback")
    w.hot(230, 75, 282, 127, "help")
    w.txt(160, 184, 21, T("jd_mnMachine"), DK, nil, 240, true); w.hot(134, 134, 400, 233, "page_jdtrac")
    w.txt(160, 286, 21, T("jd_mnSystem"), DK, nil, 240, true); w.hot(134, 237, 400, 335, "page_jdset")
    w.txt(160, 389, 21, T("jd_mnApps"), DK, nil, 240, true)
    for _, ic in ipairs(M.MENU) do
        w.hot(ic[1] - 90, ic[2] - 88, ic[1] + 90, ic[2] + 90, ic[3])
        w.ctr(ic[1], ic[2] + 115, 24, T(ic[4]), DK, 210, true)
    end
    -- autres pages (pas d'icône sur le vrai G5 : touches)
    local fp = d.mach ~= nil and d.mach.kind == "forage" and d.mach.obj == v
    local extra = { { "page_jdcount", "jd_count" }, { "page_jdcp", "Courseplay" }, { "page_jdalert", "jd_alerts" },
        fp and { "page_home", "jd_forage" } or { "page_jdhitchf", "jd_hitchF" } }
    for i, e in ipairs(extra) do
        local x0 = 445 + (i - 1) * 272
        local lab = e[2] == "Courseplay" and e[2] or T(e[2])
        local act = e[1]
        if act == "page_jdcp" and not ((d.gps or {}).hasCp) then act = nil end
        -- (13/11) sans Courseplay : pas de touche Courseplay
        if not (e[1] == "page_jdcp" and AS_Terminal.ui ~= nil and AS_Terminal.ui.cpInstalled ~= nil and not AS_Terminal.ui.cpInstalled()) then
            key(w, x0, 740, x0 + 252, 830, lab, act, false, nil, 21)
        end
    end
    chassis(self, d, f, v, "menu", T("jd_kMenu"))
end

-------------------------------------------------------------------------------
-- 03 Page tracteur (vraie « Tractor Run Page » G5) : cases construites par le code, icônes découpées
-------------------------------------------------------------------------------
M.SCV_COL = { { 0.06, 0.58, 0.06, 1 }, { 0.00, 0.33, 1.00, 1 }, { 0.22, 0.22, 0.22, 1 }, { 0.22, 0.22, 0.22, 1 }, { 0.58, 0.00, 1.00, 1 }, { 0.22, 0.22, 0.22, 1 } }
M.SCV_X = { { 253, 375 }, { 380, 500 }, { 505, 625 }, { 630, 750 }, { 755, 875 }, { 883, 1003 } }
M.ROMAN = { "I", "II", "III", "IV", "V", "VI" }
local function vgauge(f, x0, y0, x1, y1, t, col)
    f.rect(x0, y0, x1 - x0, y1 - y0, KEYB)
    f.rect(x0 + 2, y0 + 2, x1 - x0 - 4, y1 - y0 - 4, { 0.86, 0.86, 0.84, 1 })
    t = clamp01(t)
    if t > 0.005 then
        local h = (y1 - y0 - 4) * t
        f.rect(x0 + 2, y1 - 2 - h, x1 - x0 - 4, h, col or JDG)
    end
end
local function hbar(f, x0, y0, x1, y1, t, col)
    f.rect(x0, y0, x1 - x0, y1 - y0, KEYB)
    f.rect(x0 + 2, y0 + 2, x1 - x0 - 4, y1 - y0 - 4, { 0.86, 0.86, 0.84, 1 })
    t = clamp01(t)
    if t > 0.005 then f.rect(x0 + 2, y0 + 2, (x1 - x0 - 4) * t, y1 - y0 - 4, col or JDG) end
end
local function hitchBox(self, d, f, v, x0, y0, x1, y1, front)
    local hf, hr = H().caseHitches(d)
    local h = front and hf or hr
    local has = h ~= nil and h.object ~= nil
    module(f, x0, y0, x1, y1, T(front and "jd_hitchF" or "jd_hitchR"))
    f.img(x0 + 12, y0 + 50, 90, 90, "as_jd_t01")
    vgauge(f, x1 - 70, y0 + 50, x1 - 30, y1 - 60, has and (h.up or 0) or 0)
    f.ctr((x0 + x1 - 70) * 0.5, y1 - 90, 34, has and (H().hitchPct(h) .. " %") or "--", DK, x1 - x0 - 90, true)
    f.ctr((x0 + x1) * 0.5, y1 - 32, 15, has and (h.moveDown and T("df_lowered") or T("df_raised")) or T("empty"), GREY, x1 - x0 - 12)
    if self.hitchLocked ~= nil and self:hitchLocked(v, front) then f.img(x0 + 30, y0 + 160, 50, 50, "as_jd_t02") end
    f.hot(x0, y0 + 34, x1, y1, front and "hitch_f" or "hitch_r")
    f.hot(x0, y0, x1, y0 + 34, front and "page_jdhitchf" or "page_jdhitchr")
end
-- (70b) grille régulière : écart de 6 partout, colonnes
-- du bas alignées sur celles du haut, en-têtes tous de la même hauteur
M.TG = 6
M.TCOL = { { 8, 246 }, { 252, 372 }, { 378, 498 }, { 504, 624 }, { 630, 750 }, { 756, 876 }, { 882, 1002 }, { 1008, 1266 }, { 1272, 1664 } }
M.TROW = { 92, 440, 446, 800 }
function M.trac(self, d, ctx, v, Wp, Hp)
    local f = frame(self, ctx, Wp, Hp)
    f.img(0, 0, 1672, 941, "as_jd_blank")
    local g = d.gps or {}
    local C, R = M.TCOL, M.TROW
    local ty0, ty1, by0, by1 = R[1], R[2], R[3], R[4]
    -- fond des écarts : une seule couleur (avant : celle de l'image, inégale)
    f.rect(2, ty0 - 4, 1668, by1 - ty0 + 8, { 0.165, 0.165, 0.071, 1 })
    -- rangée du haut : relevage AR, distributeurs I à VI, vitesse, direction
    hitchBox(self, d, f, v, C[1][1], ty0, C[1][2], ty1, false)
    local rem = (v ~= nil and self.remoteFns ~= nil) and self:remoteFns(v) or {}
    for i = 1, 6 do
        local x0, x1 = C[i + 1][1], C[i + 1][2]
        local cx = (x0 + x1) * 0.5
        f.rect(x0, ty0, x1 - x0, ty1 - ty0, CREAM)
        f.rect(x0, ty0, x1 - x0, 34, M.SCV_COL[i])
        f.ctr(cx, ty0 + 17, 20, M.ROMAN[i], WH, x1 - x0 - 8, true)
        local fns = rem[i] or {}
        f.ctr(cx, ty0 + 58, 14, #fns > 0 and self:remoteShort(fns[1]) or "--", DK, x1 - x0 - 8, #fns > 0)
        local hy = (self.hydOf ~= nil and v ~= nil) and self:hydOf(v, i) or { flowP = 100, timer = 0 }
        vgauge(f, cx - 16, ty0 + 80, cx + 16, ty0 + 268, (hy.flowP or 100) / 100, { 0.55, 0.55, 0.52, 1 })
        f.ctr(cx, ty0 + 287, 15, pctTxt(hy.flowP or 100), DK, x1 - x0 - 8, true)
        f.img(cx - 44, ty0 + 304, 36, 36, "as_jd_t03")
        local tm = hy.timer or 0
        f.txt(cx - 2, ty0 + 322, 15, tm <= 0 and "--" or (tm >= (self.HYD_INF or 60) and T("jd_vInf") or (tm .. " s")), DK, nil, 56)
        f.hot(x0, ty0, x1, ty0 + 34, "jdv_sel_" .. i)
        f.hot(x0, ty0 + 34, x1, ty1, "rem_" .. i)
    end
    local vx0, vx1 = C[8][1], C[8][2]
    local vc = (vx0 + vx1) * 0.5
    module(f, vx0, ty0, vx1, ty1, T("jd_speed"))
    f.img(vx0 + 12, ty0 + 44, 64, 64, "as_jd_t14")
    local sv, su = spd(math.abs(d.speed or 0))
    f.ctr(vc, ty0 + 166, 64, dec(sv, 1), DK, vx1 - vx0 - 20, true)
    f.ctr(vc, ty0 + 221, 20, su, GREY, vx1 - vx0 - 20)
    f.img(vx0 + 12, ty0 + 258, 52, 52, "as_jd_t15")
    f.txt(vx0 + 76, ty0 + 284, 22, d.cruiseSpeed ~= nil and (dec(spd(d.cruiseSpeed), 1) .. " " .. su) or "--", (d.cruise or 0) > 1 and JDG or DK, nil, vx1 - vx0 - 86, true)
    f.hot(vx0, ty0, vx1, ty1, "page_jdtrans")
    -- direction : AutoTrac / Courseplay
    local ax0, ax1 = C[9][1], C[9][2]
    local ac = (ax0 + ax1) * 0.5
    module(f, ax0, ty0, ax1, ty1, "AutoTrac")
    local active = g.active == true or g.steer == "on"
    f.ctr(ac, ty0 + 98, 40, active and T("jd_on") or (g.data ~= nil and (g.canStart and T("cpReady") or T("cpNotReady")) or T("jd_off")), active and JDG or DK, ax1 - ax0 - 20, true)
    f.ctr(ac, ty0 + 168, 20, T("jd_xte") .. " : " .. xteTxt(g), DK, ax1 - ax0 - 20)
    f.ctr(ac, ty0 + 208, 17, (g.data ~= nil and self.cpCourseName ~= nil) and (self:cpCourseName(v, d) or "") or T("cpNoCourse"), GREY, ax1 - ax0 - 20)
    key(f, ax0 + 24, ty0 + 246, ax1 - 24, ty0 + 326, active and T("cpStop") or T("cpGo"), g.data ~= nil and "gps_steer" or "gps_course", active, nil, 22)
    -- rangée du bas (colonnes alignées sur celles du haut)
    local mid = by0 + 111
    local c1x0, c1x1 = C[1][1], C[1][2]
    module(f, c1x0, by0, c1x1, mid, T("jd_ptoR"))
    f.img(c1x0 + 8, by0 + 40, 64, 64, "as_jd_t07")
    f.txt(c1x0 + 82, by0 + 60, 24, d.ptoR and T("jd_on") or T("jd_off"), d.ptoR and JDG or DK, nil, c1x1 - c1x0 - 92, true)
    f.txt(c1x0 + 82, by0 + 92, 16, d.ptoR and d.ptoRpm ~= nil and (math.floor(d.ptoRpm + 0.5) .. " " .. T("df_rpm")) or "", GREY, nil, c1x1 - c1x0 - 92)
    f.hot(c1x0, by0, c1x1, mid, "page_jdpto")
    module(f, c1x0, mid + M.TG, c1x1, by1, T("jd_fuel"))
    f.img(c1x0 + 10, mid + 50, 70, 70, "as_jd_t06")
    f.ctr(c1x0 + 162, mid + 85, 40, d.fuel ~= nil and pctTxt(d.fuel * 100) or "--", (d.fuel ~= nil and d.fuel < 0.1) and RED or DK, 150, true)
    f.ctr((c1x0 + c1x1) * 0.5, mid + 160, 20, dec(d.fuelUse or 0, 1) .. " l/h", DK, c1x1 - c1x0 - 20)
    if d.def ~= nil then f.ctr((c1x0 + c1x1) * 0.5, mid + 200, 16, "AdBlue " .. pctTxt(d.def * 100), GREY, c1x1 - c1x0 - 20) end
    local tx0, tx1 = C[2][1], C[3][2]
    local tc = (tx0 + tx1) * 0.5
    module(f, tx0, by0, tx1, by1, T("jd_trans"))
    f.ctr(tc, by0 + 104, 54, d.cvt and "CVT" or tostring(d.gear or "N"), DK, tx1 - tx0 - 16, true)
    local mo = v ~= nil and v.spec_motorized ~= nil and v.spec_motorized.motor or nil
    local rev = (mo ~= nil and type(mo.currentDirection) == "number" and mo.currentDirection < 0) or (d.dir or 0) < 0
    f.ctr(tc, by0 + 184, 34, rev and "R" or "F", rev and AMBER or JDG, 100, true)
    f.ctr(tc, by0 + 244, 20, d.group ~= nil and tostring(d.group) or "", GREY, tx1 - tx0 - 16)
    f.ctr(tc, by0 + 304, 22, d.manual == true and "MANU" or "AUTO", DK, tx1 - tx0 - 16, true)
    f.hot(tx0, by0, tx1, by1, "page_jdtrans")
    local px0, px1 = C[4][1], C[5][2]
    local pmid = by0 + 235
    module(f, px0, by0, px1, pmid, T("jd_power"))
    f.img(px0 + 10, by0 + 44, 64, 64, "as_jd_t12")
    f.ctr(px0 + 172, by0 + 76, 34, pctTxt(clamp01(d.load or 0) * 100), DK, 150, true)
    hbar(f, px0 + 16, by0 + 144, px1 - 16, by0 + 184, clamp01(d.load or 0))
    module(f, px0, pmid + M.TG, px1, by1, T("jd_maxRpm"))
    f.img(px0 + 8, pmid + 48, 56, 56, "as_jd_t13")
    f.txt(px0 + 76, pmid + 76, 22, (d.rpm ~= nil and math.floor(d.rpm + 0.5) or "--") .. " / " .. (d.maxRpm ~= nil and math.floor(d.maxRpm + 0.5) or "--"), DK, nil, px1 - px0 - 86, true)
    hitchBox(self, d, f, v, C[6][1], by0, C[7][2], by1, true)
    local fx0, fx1 = C[8][1], C[8][2]
    module(f, fx0, by0, fx1, mid, T("jd_ptoF"))
    f.img(fx0 + 8, by0 + 40, 64, 64, "as_jd_t08")
    f.txt(fx0 + 82, by0 + 60, 24, d.ptoF and T("jd_on") or T("jd_off"), d.ptoF and JDG or DK, nil, fx1 - fx0 - 92, true)
    f.hot(fx0, by0, fx1, mid, "page_jdpto")
    module(f, fx0, mid + M.TG, fx1, by1, T("jd_slip"))
    f.img(fx0 + 10, mid + 49, 70, 70, "as_jd_t18")
    f.ctr(fx0 + 170, mid + 81, 36, d.slip ~= nil and pctTxt(d.slip) or "--", (d.slip or 0) > 25 and RED or DK, 150, true)
    f.img(fx0 + 10, mid + 143, 56, 56, "as_jd_t16")
    local awd = d.awd
    local tr = d.trans
    if awd == nil and type(tr) == "table" then awd = tr.awd end
    f.txt(fx0 + 80, mid + 171, 18, (awd == true and "4RM ON") or (awd == false and "4RM OFF") or "4RM", DK, nil, fx1 - fx0 - 90, true)
    f.txt(fx0 + 80, mid + 206, 15, (d.lockF and "AV " or "") .. (d.lockR and "AR" or ""), GREY, nil, fx1 - fx0 - 90)
    f.hot(fx0, mid + M.TG, fx1, by1, "diffMode")
    local mx0, mx1 = C[9][1], C[9][2]
    module(f, mx0, by0, mx1, by1, T("jd_map"))
    f.rect(mx0, by0 + 34, mx1 - mx0, by1 - by0 - 34, { 0.16, 0.20, 0.12, 1 })
    liveMap(self, d, ctx, v, f, mx0, by0 + 34, mx1, by1, "top")
    f.hot(mx0, by0, mx1, by1, "page_gps")
    chassis(self, d, f, v, "trac", T("jd_trac"))
end

-------------------------------------------------------------------------------
-- 04 / 05 Relevages AR et AV : limite haute, vitesse de descente (effets en jeu), vitesse de montée (pas dans le
-- jeu : grisée), position en direct (appui = lever / baisser) ; AR : régulation mixte et patinage, AV : flottement
-------------------------------------------------------------------------------
-- curseur vertical : un appui sur la glissière règle la valeur (pas de 5)
local function vSlider(f, x0, x1, y0, y1, lo, hi, step, val, act, spr, sw, sh)
    local t = (val - lo) / (hi - lo)
    local yc = y1 - (y1 - y0) * clamp01(t)
    f.img((x0 + x1) * 0.5 - sw * 0.5, yc - sh * 0.5, sw, sh, spr)
    local n = math.floor((hi - lo) / step + 0.5)
    for i = 0, n do
        local vv = lo + i * step
        local yy = y1 - (y1 - y0) * (i / n)
        local hh = (y1 - y0) / n
        f.hot(x0 - 40, yy - hh * 0.5, x1 + 40, yy + hh * 0.5, act .. "_" .. vv)
    end
end
local function hSlider(f, x0, x1, yc, lo, hi, step, val, act, spr, sw, sh)
    local t = (val - lo) / (hi - lo)
    local xc = x0 + (x1 - x0) * clamp01(t)
    f.img(xc - sw * 0.5, yc - sh * 0.5, sw, sh, spr)
    local n = math.floor((hi - lo) / step + 0.5)
    for i = 0, n do
        local vv = lo + i * step
        local xx = x0 + (x1 - x0) * (i / n)
        local ww = (x1 - x0) / n
        f.hot(xx - ww * 0.5, yc - 34, xx + ww * 0.5, yc + 34, act .. "_" .. vv)
    end
end
local function hitchPage(self, d, ctx, v, Wp, Hp, front)
    local f = frame(self, ctx, Wp, Hp)
    f.img(0, 0, 1672, 941, front and "as_jd_hitchf" or "as_jd_hitchr")
    local hf, hr = H().caseHitches(d)
    local h = front and hf or hr
    local has = h ~= nil and h.object ~= nil
    local up = has and clamp01(h.up or 0) or 0
    local hs = (self.hitchSetOf ~= nil and v ~= nil) and self:hitchSetOf(v, front) or { upper = 100, speed = 100, mix = 50, slip = 0, damp = 1 }
    local fr = front and "f" or "r"
    f.hot(24, 100, 322, 215, "page_jdhitchr"); f.hot(330, 100, 605, 215, "page_jdhitchf")
    -- outil attelé
    f.txt(640, 136, 26, has and (H().vehicleName ~= nil and H().vehicleName(h.object) or "") or T("empty"), DK, nil, 740, true)
    f.txt(640, 182, 20, has and (h.moveDown and T("df_lowered") or T("df_raised")) or "", GREY, nil, 740)
    -- en-têtes des 4 colonnes
    local HX = { { 30, 360 }, { 382, 703 }, { 726, 1040 }, { 1058, 1370 } }
    local HL = { "jd_hUpper", "jd_hDown", "jd_hUp", "jd_hPos" }
    for i, b in ipairs(HX) do f.txt(b[1] + 12, 257, 18, T(HL[i]), WH, nil, b[2] - b[1] - 24, true) end
    vSlider(f, 305, 328, 297, 557, 10, 100, 5, hs.upper, "jdhs_" .. fr .. "_upper", "as_jd_s_hdl1", 56, 33)
    f.ctr(150, 585, 24, pctTxt(hs.upper), DK, 200, true)
    vSlider(f, 588, 606, 312, 561, 10, 100, 5, hs.speed, "jdhs_" .. fr .. "_speed", "as_jd_s_hdl2", 52, 32)
    f.ctr(470, 585, 24, pctTxt(hs.speed), DK, 200, true)
    f.img(905, 422, 52, 32, "as_jd_s_hdl2")
    f.rect(728, 282, 310, 316, OFF)
    -- position réelle : levé = 100 %, en bas = 0 % ; appui = lever / baisser
    local yp = 586 - (586 - 297) * up
    f.img(1305, yp - 22, 48, 44, "as_jd_s_ptr")
    f.rgt(1296, yp, 20, has and (H().hitchPct(h) .. " %") or "--", DK, 120, true)
    f.hot(1060, 282, 1368, 600, front and "hitch_f" or "hitch_r")
    local locked = self.hitchLocked ~= nil and self:hitchLocked(v, front) or false
    f.ctr(1170, 575, 15, locked and T("fd_lockOn") or T("fd_lockOff"), locked and DK or RED, 200, true)
    f.hot(1070, 550, 1270, 600, front and "hlock_f" or "hlock_r")
    if front then
        -- flottement du relevage avant (gardé, pas d'équivalent dans le jeu)
        f.txt(42, 642, 18, T("jd_hFloat"), WH, nil, 600, true)
        local on = hs.damp == 1
        f.img(790, 680, 245, 94, on and "as_jd_s_ftog_on" or "as_jd_s_ftog_off")
        f.ctr(1180, 726, 22, on and T("jd_on") or T("jd_off"), on and JDG or DK, 160, true)
        f.hot(780, 670, 1045, 784, "jdhf_damp")
    else
        f.txt(42, 639, 18, T("jd_hMix"), WH, nil, 560, true)
        f.rgt(712, 639, 18, pctTxt(hs.mix), WH, 120, true)
        -- triangle bleu : charge du moteur (effort) ; poignée jaune : régulation mixte
        f.img(353 + 346 * clamp01(d.load or 0) - 20, 662, 40, 38, "as_jd_s_tri")
        hSlider(f, 353, 699, 744, 0, 100, 5, hs.mix, "jdhs_r_mix", "as_jd_s_hdlh", 44, 58)
        f.txt(752, 639, 18, T("jd_hSlip"), WH, nil, 420, true)
        f.rgt(1365, 639, 18, (d.slip ~= nil and pctTxt(d.slip) or "--") .. "  /  " .. pctTxt(hs.slip), WH, 220, true)
        hSlider(f, 941, 1354, 742, 0, 100, 5, hs.slip, "jdhs_r_slip", "as_jd_s_hdlg", 43, 56)
    end
    M.rightCol(self, d, f, v)
    chassis(self, d, f, v, front and "hitchf" or "hitchr", T(front and "jd_hitchF" or "jd_hitchR"))
end
function M.hitchr(self, d, ctx, v, Wp, Hp) return hitchPage(self, d, ctx, v, Wp, Hp, false) end
function M.hitchf(self, d, ctx, v, Wp, Hp) return hitchPage(self, d, ctx, v, Wp, Hp, true) end

-------------------------------------------------------------------------------
-- 06 Distributeurs I à VI (= Fonctions 1 à 6 du terminal) : onglet = distributeur ; mode Temporisation / Débit /
-- Fonctions (AV | AR | Les deux) ; vérin = appliquer ; ++ + - -- ; barre du bas = temporisation (appui = valeur)
-------------------------------------------------------------------------------
M.vSel, M.vFocus = 1, "flow"
M.VTAB = { { 185, 355 }, { 372, 542 }, { 558, 728 }, { 748, 918 }, { 935, 1105 }, { 1123, 1293 } }
local function frameRect(f, x0, y0, x1, y1, t, c)
    f.rect(x0, y0, x1 - x0, t, c); f.rect(x0, y1 - t, x1 - x0, t, c)
    f.rect(x0, y0, t, y1 - y0, c); f.rect(x1 - t, y0, t, y1 - y0, c)
end
function M.valve(self, d, ctx, v, Wp, Hp)
    local f = frame(self, ctx, Wp, Hp)
    f.img(0, 0, 1672, 941, "as_jd_valve")
    local rem = (v ~= nil and self.remoteFns ~= nil) and self:remoteFns(v) or {}
    local i = math.max(1, math.min(6, M.vSel or 1))
    for n, b in ipairs(M.VTAB) do
        local cx = (b[1] + b[2]) * 0.5
        local fns = rem[n] or {}
        f.ctr(cx, 140, 26, M.ROMAN[n], WH, b[2] - b[1] - 10, true)
        f.ctr(cx, 178, 14, #fns > 0 and self:remoteShort(fns[1]) or "--", WH, b[2] - b[1] - 14, #fns > 0)
        f.hot(b[1], 112, b[2], 200, "jdv_sel_" .. n)
    end
    frameRect(f, M.VTAB[i][1] - 10, 106, M.VTAB[i][2] + 10, 208, 7, YEL)
    local h = (self.hydOf ~= nil and v ~= nil) and self:hydOf(v, i) or { flowP = 100, timer = 0 }
    -- mode
    f.txt(64, 248, 18, T("jd_vMode"), WH, nil, 290, true)
    local FB = { timer = { 50, 268, 368, 390 }, flow = { 46, 400, 372, 540 }, fn = { 50, 553, 368, 680 } }
    local FL = { timer = "jd_vTimer", flow = "jd_vFlow", fn = "jd_vFns" }
    for k, b in pairs(FB) do
        f.ctr((b[1] + b[3]) * 0.5, b[4] - 16, 15, T(FL[k]), DK, b[3] - b[1] - 20, true)
        f.hot(b[1], b[2], b[3], b[4], "jdv_focus_" .. k)
    end
    local fb = FB[M.vFocus] or FB.flow
    frameRect(f, fb[1] - 4, fb[2] - 4, fb[3] + 4, fb[4] + 4, 6, YEL)
    -- case centrale
    local fns = rem[i] or {}
    f.txt(410, 248, 18, T("jd_vValve") .. " " .. M.ROMAN[i] .. (#fns > 0 and ("  -  " .. self:remoteShort(fns[1])) or ""), WH, nil, 920, true)
    if M.vFocus == "fn" then
        M.fnPanel(self, f, v, i, rem)
    else
        local isT = M.vFocus == "timer"
        -- jauge : débit
        f.rect(889, 297, 36, 288, { 0.86, 0.86, 0.84, 1 })
        local fh = 286 * clamp01((h.flowP or 100) / 100)
        f.rect(890, 584 - fh, 34, fh, { 0.58, 0.58, 0.55, 1 })
        local inf = self.HYD_INF or 60
        local tv = h.timer or 0
        local val = isT and (tv <= 0 and T("jd_vNoTimer") or (tv >= inf and T("jd_vInf") or (tv .. " s"))) or pctTxt(h.flowP or 100)
        f.ctr(1213, 449, 28, val, DK, 190, true)
        local acts = { { 278, 335, "jdv_pp" }, { 348, 405, "jdv_p" }, { 492, 548, "jdv_m" }, { 563, 620, "jdv_mm" } }
        for _, a in ipairs(acts) do f.hot(1110, a[1], 1315, a[2], a[3]) end
        -- fonctions du distributeur (appui sur le vérin = les appliquer)
        for k = 1, 3 do
            local fn = fns[k]
            f.txt(420, 300 + (k - 1) * 30, 15, fn ~= nil and (k .. ". " .. self:remoteLabel(fn)) or "", DK, nil, 310)
        end
        if #fns == 0 then f.txt(420, 300, 15, T("c_remoteNone"), GREY, nil, 310) end
        f.ctr(588, 560, 16, #fns > 0 and T("jd_vApply") or "", JDG, 320, true)
        f.hot(420, 380, 740, 590, #fns > 0 and ("rem_" .. i) or "jdv_focus_fn")
    end
    -- temporisation : barre du bas
    f.txt(410, 671, 18, T("jd_vTimer"), WH, nil, 900, true)
    local inf = self.HYD_INF or 60
    local tv = h.timer or 0
    local t = clamp01(tv / inf)
    if t > 0.005 then f.rect(596, 713, 712 * t, 52, YEL) end
    f.ctr(950, 739, 24, tv <= 0 and T("jd_vNoTimer") or (tv >= inf and T("jd_vHold") or (tv .. " s")), DK, 600, true)
    for k = 0, 12 do
        local vv = k * 5
        local xx = 594 + 712 * (k / 12)
        f.hot(xx - 30, 704, xx + 30, 774, "jdv_t_" .. vv)
    end
    M.rightCol(self, d, f, v)
    chassis(self, d, f, v, "valve", T("jd_valves"))
end
-- réglage des fonctions d'un distributeur : ses 3 cases, puis la liste (AV | AR | Les deux)
function M.fnPanel(self, f, v, i, rem)
    f.rect(400, 272, 948, 362, WH)
    local fns = rem[i] or {}
    local m = self.remoteMenu
    for k = 1, (self.REMOTE_SLOTS or 3) do
        local y = 286 + (k - 1) * 84
        local open = m ~= nil and m.i == i and m.k == k
        f.rect(412, y, 440, 70, open and JDG or KEYL)
        f.ctr(440, y + 35, 24, tostring(k), open and WH or GREY, 40, true)
        local fn = fns[k]
        f.txt(470, y + 35, 18, fn ~= nil and self:remoteLabel(fn) or ((k <= #fns + 1) and "+" or ""), open and WH or DK, nil, 370, fn ~= nil)
        if k <= #fns + 1 then f.hot(412, y, 852, y + 70, "rfn_" .. i .. "_" .. k) end
    end
    if #fns > 0 then
        key(f, 412, 548, 852, 624, T("c_apply"), "rem_" .. i, false, nil, 20)
    end
    if m ~= nil and m.i == i then
        local heads = { { T("c_colF"), "@f" }, { T("c_colR"), "@r" }, { T("c_colB"), "" } }
        local x0, y0, cw, rh = 868, 280, 156, 29
        local cur = fns[m.k] or "none"
        for col, hd in ipairs(heads) do
            local cx = x0 + (col - 1) * (cw + 4)
            f.rect(cx, y0, cw, rh, OLIVE)
            f.ctr(cx + cw * 0.5, y0 + rh * 0.5, 14, hd[1], WH, cw - 8, true)
            for j = 2, #self.REMOTE_FNS do
                local fn = self.REMOTE_FNS[j] .. hd[2]
                local ry = y0 + (j - 1) * rh + 1
                local on = cur == fn
                f.rect(cx, ry, cw, rh - 2, on and JDG or KEYL)
                f.txt(cx + 5, ry + rh * 0.5, 11, self:remoteLabel(fn, true), on and WH or DK, nil, cw - 8)
                f.hot(cx, ry, cx + cw, ry + rh - 2, "rsel_" .. m.i .. "_" .. m.k .. "_" .. fn)
            end
        end
        local ny = y0 + #self.REMOTE_FNS * rh + 2
        f.rect(x0, ny, cw * 3 + 8, rh - 2, cur == "none" and JDG or KEYL)
        f.ctr(x0 + (cw * 3 + 8) * 0.5, ny + rh * 0.5, 13, T("none"), cur == "none" and WH or DK, cw * 3)
        f.hot(x0, ny, x0 + cw * 3 + 8, ny + rh - 2, "rsel_" .. m.i .. "_" .. m.k .. "_none")
    else
        f.txt(870, 320, 13, T("fd_remHint1"), GREY, nil, 500)
        f.txt(870, 356, 13, T("fd_remHint2"), GREY, nil, 500)
    end
end

-------------------------------------------------------------------------------
-- fenêtre G5 dessinée (en-tête olive, X jaune) : alertes, réglages fins des tronçons
-------------------------------------------------------------------------------
local function g5Window(f, x0, y0, x1, y1, title, closeAct)
    f.rect(x0 - 3, y0 - 3, x1 - x0 + 6, y1 - y0 + 6, { 0.12, 0.12, 0.08, 1 })
    f.rect(x0, y0, x1 - x0, y1 - y0, { 0.98, 0.98, 0.97, 1 })
    f.rect(x0, y0, x1 - x0, 70, { 0.25, 0.26, 0.10, 1 })
    f.txt(x0 + 24, y0 + 35, 28, title, WH, nil, x1 - x0 - 180, true)
    f.rect(x1 - 120, y0 + 9, 108, 52, KEYB)
    f.rect(x1 - 118, y0 + 11, 104, 48, YEL)
    f.ctr(x1 - 66, y0 + 35, 32, "X", DK, 90, true)
    if closeAct ~= nil then f.hot(x1 - 124, y0 + 4, x1 - 8, y0 + 66, closeAct) end
end
-- ligne « libellé   [-] valeur [+] »
local function stepLine(f, x0, x1, y, label, val, aM, aP)
    f.txt(x0, y, 22, label, DK, nil, (x1 - x0) - 420)
    key(f, x1 - 400, y - 32, x1 - 300, y + 32, "-", aM, false, nil, 30)
    f.ctr(x1 - 200, y, 24, val, DK, 190, true)
    key(f, x1 - 100, y - 32, x1, y + 32, "+", aP, false, nil, 30)
end

-------------------------------------------------------------------------------
-- 08 Prise de force (CommandPRO « Custom Settings ») : AUTO PdF (marche sous / arrêt au-dessus d'une hauteur du
-- relevage AR), régime 1000 / 1000E, commande externe ; distributeurs : pas dans le jeu
-------------------------------------------------------------------------------
function M.pto(self, d, ctx, v, Wp, Hp)
    local f = frame(self, ctx, Wp, Hp)
    f.img(0, 0, 1672, 941, "as_jd_pto")
    local w = win(f, "pto")
    local ps = (self.ptoOf ~= nil and v ~= nil) and self:ptoOf(v) or { mode = 1, ext = 0, auto = 0, aon = 5, aoff = 20 }
    w.txt(600, 56, 36, T("jd_pto"), DK, nil, 880, true)
    w.hot(1500, 16, 1652, 104, "jdback")
    local st = (d.ptoR and (T("jd_ptoR") .. " " .. T("jd_on")) or (T("jd_ptoR") .. " " .. T("jd_off"))) .. "   |   " .. (d.ptoF and (T("jd_ptoF") .. " " .. T("jd_on")) or (T("jd_ptoF") .. " " .. T("jd_off")))
    w.ctr(836, 160, 26, st, (d.ptoR or d.ptoF) and JDG or GREY, 1500, true)
    -- AUTO PdF : seuils
    local function thr(cx, label, key0, val)
        w.ctr(cx, 222, 24, label, GREY, 600)
        w.ctr(cx - 110, 395, 46, "-", DK, 80, true); w.ctr(cx + 110, 395, 46, "+", DK, 80, true)
        w.ctr(cx, 395, 36, pctTxt(val), ps.auto == 1 and DK or GREY, 160, true)
        w.hot(cx - 160, 350, cx - 60, 440, "jdpto_" .. key0 .. "_-"); w.hot(cx + 60, 350, cx + 160, 440, "jdpto_" .. key0 .. "_+")
    end
    thr(645, T("jd_ptoOn"), "aon", ps.aon)
    thr(1447, T("jd_ptoOff"), "aoff", ps.aoff)
    -- régime : 1000 / 1000E (régime moteur réduit)
    w.ctr(1029, 470, 22, T("jd_ptoEco"), GREY, 500)
    w.ctr(1029, 640, 40, ps.mode == 2 and "1000E" or "1000", DK, 300, true)
    w.hot(900, 430, 1160, 680, "jdpto_mode")
    -- interrupteurs : AUTO PdF, commande externe, distributeurs (grisé)
    local TG = { { 168, 439, ps.auto == 1, "jdpto_auto", "jd_ptoAuto" }, { 782, 1051, ps.ext == 1, "jdpto_ext", "jd_ptoExt" }, { 1373, 1638, false, nil, "jd_ptoScv" } }
    for _, t in ipairs(TG) do
        w.img(t[1], 709, t[2] - t[1], 82, t[3] and "as_jd_s_tog_on" or "as_jd_s_tog_off")
        w.ctr((t[1] + t[2]) * 0.5, 680, 20, T(t[5]), DK, 360, true)
        if t[4] ~= nil then w.hot(t[1] - 10, 650, t[2] + 10, 800, t[4]) else w.off(t[1] - 4, 660, t[2] + 4, 800) end
    end
    w.ctr(706, 920, 16, T("jd_ptoReset"), GREY, 300)
    w.hot(660, 830, 752, 910, "jdpto_reset")
    chassis(self, d, f, v, "pto", T("jd_pto"))
end

-------------------------------------------------------------------------------
-- 09 Transmission (CommandPRO) : mode AUTO / MANU, vitesse, vitesses mémorisées 1 et 2 (point orange = en cours ;
-- appui = régulateur à cette vitesse, - / +), sens de marche
-------------------------------------------------------------------------------
function M.trans(self, d, ctx, v, Wp, Hp)
    local f = frame(self, ctx, Wp, Hp)
    f.img(0, 0, 1672, 941, "as_jd_trans")
    local w = win(f, "trans")
    w.txt(600, 58, 36, T("jd_trans"), WH, nil, 880, true)
    w.hot(1510, 18, 1655, 108, "jdback")
    -- liste du mode
    w.ctr(352, 330, 22, T("jd_trMode"), GREY, 400)
    local manual = d.manual == true
    local rows = { { 388, 486, "AUTO", not manual }, { 486, 581, "MANU", manual }, { 581, 679, (d.cvt and "CVT" or (T("jd_trGear") .. " " .. tostring(d.gear or "N"))), false } }
    for k, r in ipairs(rows) do
        w.rect(151, r[1] + 1, 403, r[2] - r[1] - 2, r[4] and { 0.20, 0.21, 0.15, 1 } or { 0.94, 0.94, 0.93, 1 })
        w.ctr(352, (r[1] + r[2]) * 0.5, 30, r[3], r[4] and WH or DK, 380, true)
        if k <= 2 and not r[4] then w.hot(151, r[1], 554, r[2], "diffMode") end
    end
    -- vitesse en direct
    local sv, su = spd(math.abs(d.speed or 0))
    w.rgt(1145, 310, 40, dec(sv, 1) .. " " .. su, DK, 180, true)
    -- vitesses mémorisées
    local c1 = d.cruiseSpeed or 0
    local c2 = mem2Of(v, d)
    local ccOn = (d.cruise or 0) > 1
    local cur2 = ccOn and math.abs(c1 - c2) < 0.5
    local function mem(y, kmh, act, lit)
        w.img(748, y - 23, 46, 46, lit and "as_jd_s_dot_or" or "as_jd_s_dot_gr")
        w.ctr(1065, y, 34, dec(spd(kmh), 1), DK, 130, true)
        w.ctr(1065, y + 40, 15, su, GREY, 130)
        w.ctr(975, y, 40, "-", DK, 50, true); w.ctr(1160, y, 40, "+", DK, 50, true)
        w.hot(950, y - 50, 1005, y + 50, act .. "m"); w.hot(1005, y - 50, 1125, y + 50, "jdtr_cc" .. act:sub(-1)); w.hot(1125, y - 50, 1190, y + 50, act .. "p")
    end
    mem(549, c2, "jdtr_c2", cur2)
    mem(788, c1, "jdtr_c1", ccOn and not cur2)
    -- sens de marche (indicateurs)
    local mo = v ~= nil and v.spec_motorized ~= nil and v.spec_motorized.motor or nil
    local rev = (mo ~= nil and type(mo.currentDirection) == "number" and mo.currentDirection < 0) or (d.dir or 0) < 0
    w.img(1271, 406, 314, 94, rev and "as_jd_s_tog_on" or "as_jd_s_tog_off")
    w.img(1271, 765, 314, 96, rev and "as_jd_s_tog_off" or "as_jd_s_tog_on")
    w.ctr(1428, 530, 18, T("jd_trRev"), rev and AMBER or GREY, 330, true)
    w.ctr(1428, 890, 18, T("jd_trFwd"), rev and GREY or JDG, 330, true)
    w.off(174, 815, 529, 891)
    chassis(self, d, f, v, "trans", T("jd_trans"))
end

-------------------------------------------------------------------------------
-- 10 Feux : boutons des feux (jaune = allumé), onglets à gauche = modes (route, champ, tout, rien, gyrophare, détresse)
-------------------------------------------------------------------------------
M.LBTN = { { 328, 143, 547, 237, "workF", 437, 256, "c" }, { 1048, 143, 1260, 237, "workR", 1154, 256, "c" }, { 1318, 293, 1517, 387, "workR", 1417, 276, "c" },
    { 1346, 413, 1442, 507, "workR", 1394, 524, "c" }, { 366, 476, 482, 575, "workF", 356, 525, "r" }, { 323, 598, 435, 695, "drive", 313, 646, "r" },
    { 1143, 733, 1260, 830, "high", 1201, 848, "c" }, { 468, 863, 602, 962, "drive", 612, 912, "l" } }
M.LNAME = { workF = "fd_lWorkF", workR = "fd_lWorkR", drive = "fd_lDrive", high = "fd_lHigh" }
M.LTAB = { { 112, 253, "jdl_road", "jd_lRoad" }, { 256, 391, "jdl_field", "jd_lField" }, { 394, 524, "l_mem1", "jd_lAll" },
    { 527, 656, "l_mem2", "jd_lNone" }, { 661, 794, "l_beacon", "jd_lBeacon" }, { 798, 971, "l_hazard", "jd_lHazard" } }
function M.light(self, d, ctx, v, Wp, Hp)
    local f = frame(self, ctx, Wp, Hp)
    f.img(0, 0, 1672, 941, "as_jd_lights")
    local w = win(f, "lights")
    local LO = function(k) return AS_Terminal.lightOn ~= nil and AS_Terminal:lightOn(d, k) or false end
    w.txt(330, 52, 34, T("jd_lights"), WH, nil, 950, true)
    w.hot(1420, 20, 1548, 100, "jdback")
    for i, b in ipairs(M.LBTN) do
        local on = LO(b[5])
        w.img(b[1], b[2], b[3] - b[1], b[4] - b[2], "as_jd_s_l" .. i .. (on and "_on" or "_off"))
        w.hot(b[1], b[2], b[3], b[4], "l_" .. b[5])
        local al = b[8] == "c" and RenderText.ALIGN_CENTER or (b[8] == "r" and RenderText.ALIGN_RIGHT or RenderText.ALIGN_LEFT)
        w.txt(b[6], b[7], 19, T(M.LNAME[b[5]]), DK, al, 240, true)
    end
    local l = d.lights or { mask = 0 }
    local mask = l.mask or 0
    local function bit(n) return math.floor(mask / 2 ^ n) % 2 == 1 end
    local st = { mask == 1, bit(1) and bit(2), bit(0) and bit(1) and bit(2) and l.beacon == true, mask == 0 and l.beacon ~= true, LO("beacon"), LO("hazard") }
    for i, t in ipairs(M.LTAB) do
        w.img(14, t[1], 212, t[2] - t[1], "as_jd_s_lt" .. i .. (st[i] and "_on" or "_off"))
        w.ctr(100, t[2] - 16, 15, T(t[4]), DK, 180, true)
        w.hot(14, t[1], 226, t[2], t[3])
    end
    w.off(771, 865, 1086, 959)
    chassis(self, d, f, v, "light", T("jd_lights"))
end

-------------------------------------------------------------------------------
-- 12 Coupure de tronçons : Section Control (AUTO), zone déjà faite, bord du champ, contrôle de rampe ;
-- crayon = recouvrements, curseurs = délais (fenêtres G5)
-------------------------------------------------------------------------------
-- fenêtre ouverte par-dessus la page (recouvrements / délais) : propre à chaque écran (M.nav().pop)
local function scTool(v)
    local SC = AS_SectionControl
    if SC == nil or v == nil then return nil, 0 end
    local ok, list = pcall(SC.tools, SC, v)
    if not ok or type(list) ~= "table" or #list == 0 then return nil, 0 end
    return list[1], #list
end
local function mtr(x)
    local u = H().unitsOf()
    if u ~= nil and u.imperial then return dec((x or 0) * 3.2808, 2) .. " ft" end
    return dec(x or 0, 2) .. " m"
end
function M.sc(self, d, ctx, v, Wp, Hp)
    local f = frame(self, ctx, Wp, Hp)
    -- (70d) interrupteurs, cases et voyant redessinés propres (gen_sc.py), leurs copies figées effacées du fond
    f.img(0, 0, 1672, 941, "as_jd_sc")
    local w = win(f, "sc")
    local SC = AS_SectionControl
    local c = (SC ~= nil and v ~= nil) and SC:cfg(v) or {}
    w.txt(545, 56, 32, T("jd_sc"), WH, nil, 840, true)
    w.hot(1415, 20, 1548, 104, "jdback")
    w.txt(32, 177, 20, "Section Control", DK, nil, 430, true)
    w.txt(494, 177, 20, T("fd_scDone"), DK, nil, 580, true)
    w.txt(1108, 177, 20, T("fd_scBorder"), DK, nil, 430, true)
    local auto = (c.auto or 0) == 1
    w.img(182, 268, 259, 87, auto and "as_jd_s_sct_on" or "as_jd_s_sct_off")
    w.ctr(311, 380, 18, auto and "AUTO" or T("mf_manual"), auto and JDG or GREY, 300, true)
    w.hot(170, 255, 455, 370, "jdsc_auto")
    local done = (c.done or 1) == 1
    w.img(714, 221, 259, 87, done and "as_jd_s_sct_on" or "as_jd_s_sct_off")
    w.ctr(843, 330, 16, done and T("fd_scCut") or T("fd_scNoCut"), DK, 300, true)
    w.hot(700, 210, 985, 320, "jdsc_done")
    w.txt(690, 386, 17, T("jd_scOverlap"), DK, nil, 380)
    w.hot(595, 345, 1080, 428, "jdsc_pop_ov")
    local bd = c.bd or 1
    w.img(1212, 221, 76, 76, bd == 1 and "as_jd_s_chk_on" or "as_jd_s_chk_off")
    w.txt(1290, 263, 19, T("fd_scBd1"), DK, nil, 250)
    w.hot(1205, 225, 1545, 300, "jdsc_bd1")
    w.img(1212, 325, 76, 76, bd == 2 and "as_jd_s_chk_on" or "as_jd_s_chk_off")
    w.txt(1290, 367, 19, T("fd_scBd2"), DK, nil, 250)
    w.hot(1205, 328, 1545, 405, "jdsc_bd2")
    -- outil, état des tronçons, rampe
    local boom = (c.boom or 1) == 1
    w.img(139, 610, 76, 76, boom and "as_jd_s_chkg_on" or "as_jd_s_chkg_off")
    w.ctr(174, 722, 16, T("jd_scBoom"), DK, 130, true)
    w.hot(110, 600, 240, 760, "jdsc_boom")
    local o, n = scTool(v)
    local nOn, nAll = 0, 0
    if SC ~= nil and v ~= nil then
        local ok, segs = pcall(SC.bar, SC, v)
        if ok and type(segs) == "table" then
            nAll = #segs
            for _, e in ipairs(segs) do if e.state == "on" then nOn = nOn + 1 end end
        end
    end
    w.img(282, 542, 88, 88, nOn > 0 and "as_jd_s_dot_gn" or "as_jd_s_dot_off")
    w.txt(365, 570, 22, o ~= nil and H().vehicleName(o) or T("mf_scNone"), DK, nil, 820, true)
    if nAll > 0 then w.rgt(1445, 570, 22, nOn .. " / " .. nAll, nOn > 0 and JDG or DK, 200, true) end
    w.txt(365, 612, 16, (auto and "AUTO" or T("mf_manual")) .. (n > 1 and ("   (" .. n .. ")") or ""), GREY, nil, 800)
    w.txt(420, 718, 17, T("fd_scOvIn") .. " : " .. pctTxt(c.ovIn), DK, nil, 400)
    w.hot(320, 672, 830, 770, "jdsc_pop_ov")
    w.txt(948, 718, 17, T("jd_scDelays") .. " : " .. dec(c.dOn or 0.2, 2) .. " / " .. dec(c.dOff or 0.2, 2) .. " s", DK, nil, 500)
    w.hot(845, 672, 1460, 770, "jdsc_pop_dl")
    local pop = M.nav().pop
    if pop == "ov" then
        g5Window(f, 330, 180, 1342, 760, T("jd_scOverlap"), "jdsc_pop_x")
        stepLine(f, 360, 1312, 300, T("fd_scOvIn"), pctTxt(c.ovIn), "jdsc_st_ovIn_-1", "jdsc_st_ovIn_1")
        stepLine(f, 360, 1312, 410, T("fd_scOvBd"), (bd == 2 and "50" or (bd == 3 and "--" or string.format("%d", math.floor((c.ovBd or 0) + 0.5)))) .. " %", "jdsc_st_ovBd_-1", "jdsc_st_ovBd_1")
        stepLine(f, 360, 1312, 520, T("fd_scDrive"), mtr(c.drive), "jdsc_st_drive_-1", "jdsc_st_drive_1")
        stepLine(f, 360, 1312, 630, T("fd_scTol"), mtr(c.tol), "jdsc_st_tol_-1", "jdsc_st_tol_1")
    elseif pop == "dl" then
        g5Window(f, 330, 240, 1342, 580, T("jd_scDelays"), "jdsc_pop_x")
        stepLine(f, 360, 1312, 370, T("fd_scDOn"), dec(c.dOn or 0.2, 2) .. " s", "jdsc_st_dOn_-1", "jdsc_st_dOn_1")
        stepLine(f, 360, 1312, 480, T("fd_scDOff"), dec(c.dOff or 0.2, 2) .. " s", "jdsc_st_dOff_-1", "jdsc_st_dOff_1")
    end
    chassis(self, d, f, v, "sc", T("jd_sc"))
end
function M.scAction(self, a)
    local SC = AS_SectionControl
    local v = (self.data or {}).vehicle
    local n = M.nav()
    if a == "jdsc_pop_ov" then n.pop = "ov"
    elseif a == "jdsc_pop_dl" then n.pop = "dl"
    elseif a == "jdsc_pop_x" then n.pop = nil
    elseif SC ~= nil and v ~= nil then
        local c = SC:cfg(v)
        if a == "jdsc_auto" then SC:setCfg(v, "auto", (c.auto or 0) == 1 and 0 or 1)
        elseif a == "jdsc_done" then SC:setCfg(v, "done", (c.done or 1) == 1 and 0 or 1)
        elseif a == "jdsc_boom" then SC:setCfg(v, "boom", (c.boom or 1) == 1 and 0 or 1)
        elseif a == "jdsc_bd1" then SC:setCfg(v, "bd", (c.bd or 1) == 1 and 3 or 1)
        elseif a == "jdsc_bd2" then SC:setCfg(v, "bd", (c.bd or 1) == 2 and 3 or 2)
        elseif a:sub(1, 8) == "jdsc_st_" and AS_TerminalFendt ~= nil and AS_TerminalFendt.scAction ~= nil then
            AS_TerminalFendt.scAction(self, "fdsc_st_" .. a:sub(9))
        end
    end
    self.lastRead = -100000
end

-------------------------------------------------------------------------------
-- 17 Réglages : onglets Terminal / Tablette / Accueil, liste des réglages (- / + ou CHANGER), touches du bas
-------------------------------------------------------------------------------
M.setTop, M.SET_ROWS = 1, 8
function M.set(self, d, ctx, v, Wp, Hp, inside)
    local f = frame(self, ctx, Wp, Hp)
    f.img(0, 0, 1672, 941, "as_jd_set")
    local w = win(f, "set")
    local items, tabPage, homePage = self:setItems(d, inside or false, v)
    local cur = tabPage and 2 or (homePage and 3 or 1)
    w.txt(450, 56, 32, T("jd_set"), WH, nil, 900, true)
    w.hot(1430, 20, 1545, 100, "jdback")
    -- (70b) reste jaune de l'onglet choisi de l'image d'origine (pointe à droite de « Général ») : effacé
    w.rect(242, 112, 16, 510, { 0.961, 0.937, 0.827, 1 })
    w.rect(251, 112, 3, 510, { 0.847, 0.816, 0.698, 1 })
    local TB = { { 112, 286, "jd_setMain" }, { 288, 452, "setTab" }, { 455, 622, "setHome" } }
    for i, t in ipairs(TB) do
        w.img(12, t[1], 230, t[2] - t[1], i == cur and "as_jd_s_st_on" or "as_jd_s_st_off")
        w.txt(28, (t[1] + t[2]) * 0.5, 22, T(t[3]), DK, nil, 160, true)
        w.hot(12, t[1], 242, t[2], "jdset_tab_" .. i)
    end
    local n = #items
    local pages = math.max(1, math.ceil(n / M.SET_ROWS))
    M.setTop = math.max(1, math.min(M.setTop or 1, (pages - 1) * M.SET_ROWS + 1))
    for r = 1, M.SET_ROWS do
        local i = M.setTop + r - 1
        local it = items[i]
        if it == nil then break end
        local y0 = 122 + (r - 1) * 90
        w.rect(258, y0, 1284, 86, (r % 2 == 0) and { 0.93, 0.93, 0.91, 1 } or { 0.99, 0.99, 0.98, 1 })
        if it[3] == nil and it[4] == nil and string.len(tostring(it[2] or "")) > 24 then
            -- ligne d'information (texte long) : nom puis texte dessous
            w.txt(280, y0 + 26, 22, it[1], DK, nil, 1240, true)
            w.txt(280, y0 + 62, 19, it[2], GREY, nil, 1240)
        else
            w.txt(280, y0 + 43, 22, it[1], DK, nil, 500)
            w.rgt(1170, y0 + 43, 21, it[2] or "", DK, 380, true)
        end
        if it[3] ~= nil then
            key(w, 1190, y0 + 10, 1350, y0 + 76, "-", it[3], false, nil, 34)
            key(w, 1370, y0 + 10, 1530, y0 + 76, "+", it[4], false, nil, 34)
        elseif it[4] ~= nil then
            key(w, 1190, y0 + 10, 1530, y0 + 76, T("change"), it[4], false, nil, 22)
        end
    end
    -- touches du bas : taille par défaut, (export : pas dans le jeu), position par défaut, page suivante
    w.txt(135, 917, 22, T("resetSize"), DK, nil, 280, true); w.hot(48, 873, 430, 962, "resetSize")
    w.off(468, 873, 772, 962)
    w.ctr(946, 917, 22, T("resetPos"), DK, 260, true); w.hot(808, 873, 1085, 962, "resetPos")
    w.txt(1220, 917, 22, T("jd_next") .. "  " .. (math.floor((M.setTop - 1) / M.SET_ROWS) + 1) .. " / " .. pages, DK, nil, 290, true)
    if pages > 1 then w.hot(1133, 873, 1520, 962, "jdset_more") else w.off(1133, 873, 1520, 962) end
    M.setN = n
    chassis(self, d, f, v, "set", T("jd_set"))
end

-------------------------------------------------------------------------------
-- pages du terminal dans une zone (outil ISOBUS, Courseplay, compteurs détaillés...) : leurs boutons de la colonne
-- de droite deviennent des touches G5 (capturés au lieu d'être dessinés)
-------------------------------------------------------------------------------
local function subCtx(ctx, v, f, x0, y0, x1, y1, cap)
    -- la page occupe x0..x1 ; sa colonne de boutons (rx) tombe juste après x1 : capturée, jamais dessinée
    local cx, cy, xr, yb = f.PX(x0), f.PY(y0), f.PX(x1), f.PY(y1)
    local c2 = { text = ctx.text, measure = ctx.measure, rect = ctx.rect, button = ctx.button, hotspot = ctx.hotspot, image = ctx.image,
        cx = cx, cy = cy, cw = xr - cx, ch = yb - cy, rx = xr, sideY = cy - 16,
        X = ctx.X, Y = ctx.Y, sx = ctx.sx, sy = ctx.sy, rec = ctx.rec, v = v }
    local rx = xr
    local b, t, r, h, im = ctx.button, ctx.text, ctx.rect, ctx.hotspot, ctx.image
    c2.button = function(x, y, w, hh, action, on, ...)
        if x >= rx then
            if cap ~= nil then cap[#cap + 1] = { action = action, on = on == true } end
            return
        end
        return b(x, y, w, hh, action, on, ...)
    end
    c2.text = function(x, y, size, s, col, align, bold, maxW, ...)
        if x >= rx then
            local k = cap ~= nil and cap[#cap] or nil
            if k ~= nil then if k.label == nil then k.label = s elseif k.state == nil then k.state = s end end
            return
        end
        return t(x, y, size, s, col, align, bold, maxW, ...)
    end
    c2.rect = function(x, y, w, hh, c, ...) if x >= rx then return end return r(x, y, w, hh, c, ...) end
    c2.hotspot = function(x, y, w, hh, action, ...) if x >= rx then return end return h(x, y, w, hh, action, ...) end
    c2.image = function(x, y, w, hh, ...) if x >= rx then return end return im(x, y, w, hh, ...) end
    return c2
end
local function runPage(self, d, ctx, v, f, page, x0, y0, x1, y1, cap)
    local fn = self["page_" .. page]
    if page == "jdcp" then
        local D = AS_TerminalDeutz
        fn = (D ~= nil and D.cpPage ~= nil) and function(_, d2, c2, _, v2) return D.cpPage(self, d2, c2, v2) end or nil
    end
    local C = AS_Terminal.ui.C
    f.rect(x0, y0, x1 - x0, y1 - y0, { C.screen[1], C.screen[2], C.screen[3], 1 })
    if fn == nil then return end
    local ctx2 = subCtx(ctx, v, f, x0, y0, x1, y1, cap)
    local ok, err = pcall(fn, self, d, ctx2, nil, v)
    if not ok then
        M.pageErr = M.pageErr or {}
        if not M.pageErr[page] then M.pageErr[page] = true; print("[AS_TerminalJohnDeere] ERREUR page " .. tostring(page) .. " : " .. tostring(err)) end
        f.ctr((x0 + x1) * 0.5, (y0 + y1) * 0.5, 20, "ERREUR page " .. tostring(page), RED, x1 - x0 - 20, true)
    end
end
-- touches capturées en colonne (dessinées)
local function softCol(f, cap, x0, x1, y0, y1)
    local n = math.max(6, #cap)
    local hh = math.min(96, (y1 - y0) / n)
    for i, k in ipairs(cap) do
        local yy = y0 + (i - 1) * hh
        if yy + hh > y1 + 1 then break end
        key(f, x0, yy + 4, x1, yy + hh - 4, k.label or "", k.action, k.on, k.state, 17)
    end
end
function M.page(self, d, ctx, v, Wp, Hp, inside)
    local page = self.page
    local f = frame(self, ctx, Wp, Hp)
    f.img(0, 0, 1672, 941, "as_jd_blank")
    local cap = {}
    local pg = page
    if pg == "jdcount2" then pg = "count" end
    runPage(self, d, ctx, v, f, pg, 10, 92, 1396, 806, cap)
    f.rect(1402, 92, 262, 714, CREAM)
    softCol(f, cap, 1410, 1656, 96, 802)
    local title = T("p_" .. tostring(page))
    if type(title) ~= "string" or title:find("vtpas_tm_", 1, true) ~= nil or title:find("Missing", 1, true) ~= nil then title = "" end
    chassis(self, d, f, v, page, (page == "jdcp" and "Courseplay") or (page == "gps" and T("jd_guide")) or title)
end

-------------------------------------------------------------------------------
-- 11 ISOBUS VT : mini-vue, opérateur / ferme / champ, décalage, cuve, écran de l'outil, 12 touches + < >
-------------------------------------------------------------------------------
M.ISOK = { { 1415, 1527 }, { 1545, 1656 } }
M.ISOY = { { 101, 186 }, { 198, 284 }, { 295, 381 }, { 394, 480 }, { 492, 578 }, { 589, 678 } }
function M.iso(self, d, ctx, v, Wp, Hp)
    local f = frame(self, ctx, Wp, Hp)
    local G = AS_TerminalGps
    f.img(0, 0, 1672, 941, "as_jd_iso")
    f.rect(8, 95, 536, 318, { 0.16, 0.20, 0.12, 1 })
    liveMap(self, d, ctx, v, f, 8, 95, 544, 413, (G ~= nil and G.view) or "top")
    f.img(442, 110, 92, 92, "as_jd_s_rb3"); f.hot(442, 110, 534, 202, "gps_lane")
    f.hot(8, 202, 544, 413, "page_gps")
    -- opérateur, ferme, champ
    f.txt(70, 512, 14, playerName(), DK, nil, 120, true)
    f.txt(84, 600, 14, farmName(v), DK, nil, 108, true)
    f.txt(90, 690, 14, d.field ~= nil and tostring(d.field) or "--", DK, nil, 100, true)
    -- décalage
    local g = d.gps or {}
    f.ctr(309, 456, 14, T("gps_shift") .. " " .. ((g.offset ~= nil and string.format("%+.1f", g.offset)) or "0"), WH, 210, true)
    f.hot(212, 501, 406, 580, "gps_off0"); f.hot(212, 606, 304, 694, "gps_shiftL"); f.hot(315, 606, 406, 694, "gps_shiftR")
    if g.offsetDisabled then f.rect(206, 495, 206, 205, OFF) end
    -- cuve du premier outil qui en a une
    local fl
    for _, t in ipairs(d.tools or {}) do if fl == nil and t.fills ~= nil and t.fills[1] ~= nil then fl = t.fills[1] end end
    local t = (fl ~= nil and fl.cap > 0) and clamp01(fl.level / fl.cap) or 0
    if t > 0.005 then f.rect(494, 703 - 176 * t, 22, 176 * t, JDG) end
    f.ctr(484, 770, 15, fl ~= nil and pctTxt(t * 100) or "--", DK, 110, true)
    -- écran de l'outil (page OUTIL du terminal) : ses touches capturées vont sur les 12 touches
    local cap = {}
    runPage(self, d, ctx, v, f, "tool", 553, 94, 1394, 803, cap)
    for i = 1, 12 do
        local col, row = (i - 1) % 2 + 1, math.floor((i - 1) / 2) + 1
        local x0, x1 = M.ISOK[col][1], M.ISOK[col][2]
        local y0, y1 = M.ISOY[row][1], M.ISOY[row][2]
        local k = cap[i]
        if k ~= nil then
            f.ctr((x0 + x1) * 0.5, y0 + (y1 - y0) * 0.40, 13, k.label or "", DK, x1 - x0 - 8, true)
            if k.state ~= nil then f.ctr((x0 + x1) * 0.5, y0 + (y1 - y0) * 0.70, 11, k.state, GREY, x1 - x0 - 8) end
            if k.on then f.rect(x0 + 6, y1 - 10, x1 - x0 - 12, 6, JDG) end
            f.hot(x0, y0, x1, y1, k.action)
        else
            f.rect(x0 + 2, y0 + 2, x1 - x0 - 4, y1 - y0 - 4, OFF)
        end
    end
    local nT = d.toolTabs ~= nil and #d.toolTabs or 0
    f.hot(1408, 713, 1533, 795, "jdtool_prev"); f.hot(1538, 713, 1661, 795, "jdtool_next")
    if nT < 2 then f.rect(1408, 713, 253, 82, OFF) end
    chassis(self, d, f, v, "iso", "ISOBUS VT")
end

-------------------------------------------------------------------------------
-- 13 Moniteur de travail (compteurs)
-------------------------------------------------------------------------------
-- lignes du moniteur : compteurs du travail (temps, carburant, distance au total et au travail), moyennes, moteur
function M.countRows(d, k)
    local ms, msW = k.ms or 0, k.msW or 0
    local h, hW = ms / 3600000, msW / 3600000
    local km, kmW = (k.dist or 0) / 1000, (k.distW or 0) / 1000
    local function sp(x) local a, u = spd(x); return dec(a, 1) .. " " .. u end
    return {
        { T("jd_cArea"), dec(k.ha or 0, 2) .. " ha" },
        { T("jd_cTime"), hm(ms) .. " h" },
        { T("jd_cTimeW"), hm(msW) .. " h" },
        { T("jd_cFuel"), dec(k.fuel or 0, 1) .. " l" },
        { T("jd_cFuelW"), dec(k.fuelW or 0, 1) .. " l" },
        { T("jd_cDist"), dec(km, 1) .. " km" },
        { T("jd_cDistW"), dec(kmW, 1) .. " km" },
        { T("jd_cAvgSpd"), sp(h > 0.01 and km / h or 0) },
        { T("jd_cWorkSpd"), sp(hW > 0.01 and kmW / hW or 0) },
        { T("jd_cRate"), dec(ms > 60000 and (k.ha or 0) / h or 0, 1) .. " ha/h" },
        { T("jd_cFuelHa"), ((k.ha or 0) > 0.01 and dec((k.fuel or 0) / k.ha, 1) or "0") .. " l/ha" },
        { T("jd_cAvgFuelH"), dec(h > 0.01 and (k.fuel or 0) / h or 0, 1) .. " l/h" },
        { T("jd_cFuelH"), dec(d.fuelUse or 0, 1) .. " l/h" },
        { T("m_load"), d.load ~= nil and pctTxt(d.load * 100) or "--" },
        { "AdBlue", d.def ~= nil and pctTxt(d.def * 100) or "--" } }
end
function M.count(self, d, ctx, v, Wp, Hp)
    local f = frame(self, ctx, Wp, Hp)
    f.img(0, 0, 1672, 941, "as_jd_count")
    local cnt = d.cnt or {}
    local k = jobOf(d) or { ha = 0, ms = 0, fuel = 0, dist = 0 }
    f.txt(20, 122, 20, T("jd_count"), WH, nil, 240, true)
    local L = { { 151, 247, T("jobN1"), "job1", cnt.active == 1 }, { 247, 368, T("jobN2"), "job2", cnt.active == 2 }, { 368, 492, T("total"), nil, false },
        { 492, 619, T("jd_cReset"), "reset", false }, { 619, 800, T("jd_cNext"), "jobnext", false } }
    for _, r in ipairs(L) do
        if r[5] then f.rect(10, r[1] + 4, 12, r[2] - r[1] - 8, YEL) end
        f.txt(34, (r[1] + r[2]) * 0.5, 22, r[3], (r[4] == nil and r[3] ~= T("total")) and GREY or DK, nil, 225, r[5])
        if r[4] ~= nil then f.hot(8, r[1], 268, r[2], r[4]) end
    end
    local name = cnt.active == 1 and T("jobN1") or (cnt.active == 2 and T("jobN2") or T("total"))
    f.txt(296, 122, 20, name, WH, nil, 760, true)
    -- (70e) vraie liste qui défile : toutes les valeurs du travail, 7 lignes visibles, ▲▼ par page de 7
    local rows = M.countRows(d, k)
    local n = #rows
    local top = math.max(1, math.min(M.cntTop or 1, math.max(1, n - 6)))
    M.cntTop = top
    local RY = { 151, 251, 348, 439, 533, 631, 725, 800 }
    for i = 1, 7 do
        local r = rows[top + i - 1]
        if r == nil then break end
        local ym = (RY[i] + RY[i + 1]) * 0.5
        f.txt(300, ym, 24, r[1], DK, nil, 400)
        f.rgt(995, ym, 28, r[2], DK, 330, true)
    end
    -- curseur : 3 morceaux (gen_count.py), longueur = part visible, place = première ligne affichée
    local T0, T1 = 216, 726
    local th = math.max(60, (T1 - T0) * math.min(1, 7 / math.max(7, n)))
    local ty = T0 + ((n > 7) and ((top - 1) / (n - 7)) or 0) * (T1 - T0 - th)
    f.img(1017, ty - 3, 51, 14, "as_jd_s_th_t")
    f.img(1017, ty + 11, 51, th - 22 + 6, "as_jd_s_th_m")
    f.img(1017, ty + th - 11, 51, 14, "as_jd_s_th_b")
    f.hot(1010, 157, 1072, 215, "jdcnt_up"); f.hot(1010, 729, 1072, 792, "jdcnt_dn")
    if ty > T0 + 4 then f.hot(1010, T0, 1072, ty, "jdcnt_up") end
    if ty + th < T1 - 4 then f.hot(1010, ty + th, 1072, T1, "jdcnt_dn") end
    -- champ
    f.txt(1104, 122, 20, T("jd_cField"), WH, nil, 260, true)
    local FR = { { 151, 233 }, { 233, 312 }, { 312, 388 }, { 388, 474 } }
    local frac = (d.fieldHa ~= nil and d.fieldHa > 0) and clamp01((k.ha or 0) / d.fieldHa) or nil
    local fv = { { fieldTxt(d), "" }, { T("fieldArea"), d.fieldHa ~= nil and (dec(d.fieldHa, 2) .. " ha") or "--" },
        { T("jd_cDone"), frac ~= nil and pctTxt(frac * 100) or "--" }, { T("width"), d.width ~= nil and (dec(d.width, 1) .. " m") or "--" } }
    for i, r in ipairs(FR) do
        f.txt(1104, r[1] + 22, 15, fv[i][1], GREY, nil, 255)
        f.rgt(1360, r[2] - 22, 20, fv[i][2], DK, 255, true)
    end
    -- moteur
    f.txt(1394, 122, 20, T("jd_cEngine"), WH, nil, 260, true)
    local mv = { { T("jd_cHours"), dec(d.opHours or 0, 1) .. " h" }, { T("jd_fuel"), d.fuel ~= nil and pctTxt(d.fuel * 100) or "--" },
        { T("jd_cFuelH"), dec(d.fuelUse or 0, 1) .. " l/h" }, { T("temp"), d.temp ~= nil and (math.floor(d.temp + 0.5) .. " °C") or "--" } }
    for i, r in ipairs(FR) do
        f.txt(1394, r[1] + 22, 15, mv[i][1], GREY, nil, 255)
        f.rgt(1650, r[2] - 22, 20, mv[i][2], DK, 255, true)
    end
    -- tâche
    f.txt(1104, 514, 20, T("jd_cTask"), WH, nil, 540, true)
    f.ctr(1225, 628, 18, T("jd_cNext"), DK, 210, true); f.hot(1112, 588, 1339, 668, "jobnext")
    f.ctr(1505, 640, 52, dec(k.ha or 0, 2), WH, 280, true)
    f.ctr(1505, 700, 22, "ha  -  " .. hm(k.ms) .. " h", { 0.8, 0.8, 0.78, 1 }, 280)
    f.ctr(1225, 730, 15, name, GREY, 210)
    chassis(self, d, f, v, "count", T("jd_count"))
end

-------------------------------------------------------------------------------
-- 14 Caméra : caméra arrière (appui = marche / arrêt), ferme / opérateur / champ, mini-carte, valeurs
-------------------------------------------------------------------------------
function M.cam(self, d, ctx, v, Wp, Hp)
    local f = frame(self, ctx, Wp, Hp)
    f.img(0, 0, 1672, 941, "as_jd_cam")
    camView(self, ctx, v, f, 9, 96, 1022, 798)
    f.txt(1046, 121, 18, T("jd_cFarm"), WH, nil, 260, true)
    f.txt(1140, 200, 18, farmName(v), DK, nil, 175, true)
    f.txt(1140, 303, 18, playerName(), DK, nil, 175, true)
    f.txt(1140, 411, 18, fieldTxt(d), DK, nil, 175, true)
    f.txt(1046, 502, 18, T("jd_map"), WH, nil, 260, true)
    f.rect(1041, 533, 276, 265, { 0.16, 0.20, 0.12, 1 })
    liveMap(self, d, ctx, v, f, 1041, 533, 1317, 798, "top")
    f.hot(1041, 533, 1317, 798, "page_gps")
    f.txt(1344, 121, 18, T("jd_cMachine"), WH, nil, 300, true)
    local hf, hr = H().caseHitches(d)
    local sv, su = spd(math.abs(d.speed or 0))
    local R = { { 148, 301, T("jd_speed"), dec(sv, 1) .. " " .. su }, { 301, 439, T("jd_cRpm"), d.rpm ~= nil and (math.floor(d.rpm + 0.5) .. " " .. T("df_rpm")) or "--" },
        { 439, 584, T("jd_fuel"), d.fuel ~= nil and pctTxt(d.fuel * 100) or "--" }, { 584, 800, T("jd_hitchR"), (hr ~= nil and hr.object ~= nil) and (H().hitchPct(hr) .. " %") or "--" } }
    for _, r in ipairs(R) do
        f.txt(1346, r[1] + 26, 16, r[3], GREY, nil, 300)
        f.rgt(1650, (r[1] + r[2]) * 0.5 + 14, 34, r[4], DK, 300, true)
    end
    chassis(self, d, f, v, "cam", T("jd_cam"))
end

-------------------------------------------------------------------------------
-- 19 Ensileuse (accueil de l'ensileuse automotrice) : ferme / opérateur / champ, AUTO, réglages, marche I / arrêt O,
-- vitesse, 11 touches sur la machine, caméra, débit, produit, remorque, charge
-------------------------------------------------------------------------------
M.FKEYS = { { 355, 133, 476, 256 }, { 355, 295, 476, 419 }, { 355, 454, 476, 584 }, { 355, 656, 476, 771 }, { 511, 656, 633, 771 },
    { 671, 656, 794, 771 }, { 831, 656, 953, 771 }, { 991, 656, 1112, 771 }, { 1129, 486, 1235, 586 }, { 1129, 601, 1235, 718 } }
function M.forage(self, d, ctx, v, Wp, Hp)
    local f = frame(self, ctx, Wp, Hp)
    f.img(0, 0, 1672, 941, "as_jd_forage")
    local m = d.mach or {}
    f.txt(124, 193, 18, farmName(v), DK, nil, 195, true)
    f.txt(124, 277, 18, playerName(), DK, nil, 195, true)
    f.txt(124, 348, 18, fieldTxt(d), DK, nil, 195, true)
    f.txt(22, 410, 18, T("jd_fHarvest"), WH, nil, 290, true)
    local working = m.on == true and m.header ~= nil and m.header.lowered == true
    f.img(28, 440, 137, 84, working and "as_jd_s_fA_on" or "as_jd_s_fA_off"); f.hot(28, 440, 165, 524, "page_jdcount")
    if m.rh ~= nil then f.hot(178, 440, 315, 524, "page_rh") else f.rect(178, 440, 137, 84, OFF) end
    local on = m.on == true
    f.img(28, 532, 137, 84, on and "as_jd_s_fI_on" or "as_jd_s_fI_off")
    f.img(178, 532, 137, 84, on and "as_jd_s_fO_off" or "as_jd_s_fO_on")
    f.hot(28, 532, 165, 616, on and "jd_none" or "on"); f.hot(178, 532, 315, 616, on and "on" or "jd_none")
    f.txt(22, 667, 18, T("jd_speed"), WH, nil, 290, true)
    local sv, su = spd(math.abs(d.speed or 0))
    f.ctr(166, 740, 46, dec(sv, 1) .. " " .. su, DK, 290, true)
    -- touches sur la machine (nom écrit dessus)
    local hl = m.header ~= nil and m.header.lowered
    local K = {
        { m.header ~= nil and "lift" or nil, T("m_header"), hl == true, hl and T("m_low") or T("m_high") },
        { m.pipe ~= nil and "pipe" or nil, T("m_pipe"), m.pipe == true, m.pipe and T("m_out") or T("m_in") },
        { "on", T("m_chopper"), on, on and T("on") or T("off") },
        { "page_jdcam", T("jd_cam"), false }, { "page_jdcount", T("jd_kWork"), false },
        { m.rh ~= nil and "page_rh" or nil, T("jd_fHarvest"), false }, { "page_gps", T("jd_guide"), false },
        { "l_workF", T("fd_lWorkF"), AS_Terminal:lightOn(d, "workF") }, { "l_beacon", T("jd_lBeacon"), AS_Terminal:lightOn(d, "beacon") },
        { m.canSwath and "m_swath" or "page_jdset", m.canSwath and T("m_swathOn") or T("jd_mSet"), m.swath == true } }
    for i, b in ipairs(M.FKEYS) do
        local k = K[i]
        f.ctr((b[1] + b[3]) * 0.5, b[2] + (b[4] - b[2]) * 0.40, 15, k[2] or "", DK, b[3] - b[1] - 8, true)
        if k[4] ~= nil then f.ctr((b[1] + b[3]) * 0.5, b[2] + (b[4] - b[2]) * 0.68, 12, k[4], GREY, b[3] - b[1] - 8) end
        if k[3] then f.rect(b[1] + 8, b[4] - 12, b[3] - b[1] - 16, 6, JDG) end
        if k[1] ~= nil then f.hot(b[1], b[2], b[3], b[4], k[1]) else f.rect(b[1], b[2], b[3] - b[1], b[4] - b[2], OFF) end
    end
    -- caméra (ou carte)
    f.txt(1276, 113, 18, T("jd_cam"), WH, nil, 370, true)
    camView(self, ctx, v, f, 1272, 149, 1653, 418)
    -- valeurs
    local function cell(x0, x1, y0, title, val, col)
        f.txt(x0 + 10, y0 + 18, 16, title, WH, nil, x1 - x0 - 20, true)
        f.ctr((x0 + x1) * 0.5, y0 + 100, 30, val, col or DK, x1 - x0 - 16, true)
    end
    local tgt = m.target ~= nil and m.target.cap > 0 and (m.target.level / m.target.cap) or nil
    local load = m.rh ~= nil and m.rh.load or ((d.load or 0) * 100)
    cell(1262, 1455, 442, T("m_tph"), m.tph ~= nil and (dec(m.tph, 1) .. " t/h") or "--")
    cell(1468, 1662, 442, T("m_crop"), m.crop or "--")
    cell(1262, 1455, 610, T("m_trailer"), tgt ~= nil and pctTxt(tgt * 100) or "--", (tgt or 0) > 0.9 and RED or nil)
    cell(1468, 1662, 610, T("m_load"), pctTxt(load), (load or 0) > 105 and RED or nil)
    chassis(self, d, f, v, "forage", m.name or T("jd_forage"))
end

-------------------------------------------------------------------------------
-- 16 Alertes : fenêtre G5 (comme 08 / 09) dessinée par le code
-------------------------------------------------------------------------------
function M.alert(self, d, ctx, v, Wp, Hp)
    local f = frame(self, ctx, Wp, Hp)
    f.img(0, 0, 1672, 941, "as_jd_blank")
    g5Window(f, 236, 110, 1436, 790, T("jd_alerts"), "jdback")
    local list = M.alerts(self, d)
    if #list == 0 then
        f.ctr(836, 420, 26, T("jd_aNone"), GREY, 1000, true)
    end
    for i, a in ipairs(list) do
        if i > 8 then break end
        local y = 200 + (i - 1) * 70
        f.rect(266, y, 1140, 62, (i % 2 == 0) and { 0.93, 0.93, 0.91, 1 } or WH)
        f.rect(280, y + 13, 36, 36, a[1])
        f.ctr(298, y + 31, 22, "!", WH, 30, true)
        f.txt(336, y + 31, 24, a[2], DK, nil, 1050, true)
    end
    chassis(self, d, f, v, "alert", T("jd_alerts"))
end

-------------------------------------------------------------------------------
-- point d'entrée (drawPanel)
-------------------------------------------------------------------------------
M.SCREENS = { gps = "guide", jdmenu = "menu", jdtrac = "trac", tractor = "trac", jdhitchr = "hitchr", jdhitchf = "hitchf",
    jdvalve = "valve", jdpto = "pto", jdtrans = "trans", jdlight = "light", jdiso = "iso", tool = "iso", jdsc = "sc",
    jdcount = "count", count = "count", jdcam = "cam", cam = "cam", jdset = "set", set = "set", jdalert = "alert" }
M.RUN = { "home", "gps", "jdhitchr", "jdvalve", "jdcount", "jdcam" }
-- (70e) chaque écran (grande fenêtre, tablette,
-- écrans du véhicule) a sa page : son historique, sa page précédente et sa fenêtre ouverte sont les siens. Avant,
-- un seul historique pour tous : la tablette et la fenêtre l'emmêlaient (← faisait des allers-retours)
M.navs = setmetatable({}, { __mode = "k" })
function M.nav()
    local key = M.scr or M
    local n = M.navs[key]
    if n == nil then n = { hist = {} }; M.navs[key] = n end
    return n
end
if AS_Terminal ~= nil and AS_Terminal.withTab ~= nil and not M.tabHooked then
    M.tabHooked = true
    local origW = AS_Terminal.withTab
    local unpackF = unpack or table.unpack
    AS_Terminal.withTab = function(self, tab, fn, ...)
        local keep = M.scr
        M.scr = tab
        local r = { origW(self, tab, fn, ...) }
        M.scr = keep
        return unpackF(r, 1, table.maxn(r))
    end
end
function M.isForage(self, d, v)
    local m = d ~= nil and d.mach or nil
    return m ~= nil and m.kind == "forage" and m.obj == v
end
-- (70b) accueil = page Tracteur ;
-- le guidage reste sur la touche Guidage de la barre du bas
function M.home(self, d, ctx, v, Wp, Hp, inside)
    if M.isForage(self, d, v) then return M.forage(self, d, ctx, v, Wp, Hp, inside) end
    return M.trac(self, d, ctx, v, Wp, Hp, inside)
end
function M.screenFor(self)
    local p = self.page
    -- historique (flèche « ← » de la barre du haut)
    local n = M.nav()
    if n.lastPage ~= p then
        if n.lastPage ~= nil and not n.goingBack then
            n.hist[#n.hist + 1] = n.lastPage
            if #n.hist > 20 then table.remove(n.hist, 1) end
        end
        n.goingBack = nil
        n.lastPage = p
        n.pop = nil
    end
    if p == "home" then return M.home end
    local k = M.SCREENS[p]
    if k ~= nil then return M[k] end
    return M.page
end

-- touche de la barre du bas : appui visible, touche impossible = message, sinon action habituelle
local function blink(txt)
    if txt ~= nil and g_currentMission ~= nil and g_currentMission.showBlinkingWarning ~= nil then
        pcall(g_currentMission.showBlinkingWarning, g_currentMission, txt, 2500)
    end
end
function M.keyAction(self, i)
    local k = M.KEYS[i]
    if k == nil then return end
    local d = self.data or {}
    local v = d.vehicle
    local _, usable = M.keyState(self, d, v, nil, k)
    self.lastRead = -100000
    if not usable then
        if k[3] == "lane" then blink(T("cpNoCourse"))
        elseif k[3] == "fp" and (AS_Terminal.ui == nil or AS_Terminal.ui.fpInstalled == nil or AS_Terminal.ui.fpInstalled()) then blink(T("fpMissing"))
        end
        return
    end
    M.flash = { i = i, t = g_time or 0 }
    local G = AS_TerminalGps
    if k[4] == "guide" and G ~= nil then G.sub = nil end
    return AS_Terminal.doAction(self, k[1])
end

-- appuis propres au John Deere ; le reste passe au terminal
if AS_Terminal ~= nil and AS_Terminal.doAction ~= nil and not M.hooked then
    M.hooked = true
    local orig = AS_Terminal.doAction
    AS_Terminal.doAction = function(self, a, ...)
        if type(a) == "string" and (a:sub(1, 2) == "jd" or a == "jd_none") then
            local d = self.data or {}
            local v = d.vehicle
            if a == "jd_none" then return end
            if a == "jdback" then
                local n = M.nav()
                local p = table.remove(n.hist)
                -- même page deux fois de suite dans l'historique : sautée
                while p ~= nil and p == self.page do p = table.remove(n.hist) end
                n.goingBack = true
                self.page = p or "home"
                self.lastRead = -100000
                return
            end
            if a == "jdhome" then
                if AS_TerminalGps ~= nil then AS_TerminalGps.sub = nil end
                self.page = "home"
                self.lastRead = -100000
                return
            end
            if a == "jdnext" then
                local idx = 0
                for i, p in ipairs(M.RUN) do if p == self.page then idx = i end end
                self.page = M.RUN[idx % #M.RUN + 1]
                self.lastRead = -100000
                return
            end
            if a:sub(1, 4) == "jdk_" then return M.keyAction(self, tonumber(a:sub(5)) or 0) end
            if a == "jdcnt_up" or a == "jdcnt_dn" then
                M.cntTop = math.max(1, (M.cntTop or 1) + (a == "jdcnt_dn" and 7 or -7))
                self.lastRead = -100000
                return
            end
            if a:sub(1, 5) == "jdsc_" then return M.scAction(self, a) end
            if a:sub(1, 5) == "jdhs_" and v ~= nil and self.hitchSetSet ~= nil then
                local fr, key, val = a:match("^jdhs_([fr])_(%a+)_(%d+)$")
                if fr ~= nil then self:hitchSetSet(v, fr == "f", key, tonumber(val)) end
                self.lastRead = -100000
                return
            end
            if a == "jdhf_damp" and v ~= nil and self.hitchSetOf ~= nil then
                local hs = self:hitchSetOf(v, true)
                self:hitchSetSet(v, true, "damp", hs.damp == 1 and 0 or 1)
                self.lastRead = -100000
                return
            end
            if a:sub(1, 4) == "jdv_" then
                if a:sub(1, 8) == "jdv_sel_" then
                    M.vSel = tonumber(a:sub(9)) or 1
                    self.remoteMenu = nil
                    self.page = "jdvalve"
                elseif a:sub(1, 10) == "jdv_focus_" then
                    M.vFocus = a:sub(11)
                    self.remoteMenu = nil
                elseif v ~= nil and self.hydOf ~= nil then
                    local i = math.max(1, math.min(6, M.vSel or 1))
                    local h = self:hydOf(v, i)
                    if a:sub(1, 6) == "jdv_t_" then
                        self:hydSet(v, i, "timer", math.max(0, math.min(self.HYD_INF or 60, tonumber(a:sub(7)) or 0)))
                    else
                        local isT = M.vFocus == "timer"
                        local st = ({ jdv_pp = isT and 10 or 10, jdv_p = isT and 1 or 5, jdv_m = isT and -1 or -5, jdv_mm = isT and -10 or -10 })[a] or 0
                        if isT then self:hydSet(v, i, "timer", math.max(0, math.min(self.HYD_INF or 60, (h.timer or 0) + st)))
                        else self:hydSet(v, i, "flowP", math.max(10, math.min(100, (h.flowP or 100) + st))) end
                    end
                end
                self.lastRead = -100000
                return
            end
            if a:sub(1, 6) == "jdpto_" and v ~= nil and self.ptoOf ~= nil then
                local ps = self:ptoOf(v)
                if a == "jdpto_mode" then self:ptoSet(v, "mode", ps.mode == 2 and 1 or 2)
                elseif a == "jdpto_auto" then self:ptoSet(v, "auto", ps.auto == 1 and 0 or 1)
                elseif a == "jdpto_ext" then self:ptoSet(v, "ext", ps.ext == 1 and 0 or 1)
                elseif a == "jdpto_reset" then
                    for k, key in ipairs(self.PTO_KEYS) do self:ptoSet(v, key, self.PTO_DEF[k]) end
                else
                    local key, dir = a:match("^jdpto_(%a+)_([%+%-])$")
                    if key ~= nil and ps[key] ~= nil then
                        local r = self.PTO_RANGE[key] or { 0, 100, 1 }
                        local stp = 5
                        self:ptoSet(v, key, math.max(r[1], math.min(r[2], ps[key] + (dir == "+" and stp or -stp))))
                    end
                end
                self.lastRead = -100000
                return
            end
            if a:sub(1, 5) == "jdtr_" then
                local D = AS_TerminalDeutz
                if D ~= nil and D.motorAction ~= nil then D.motorAction(self, "dfm_" .. a:sub(6)) end
                self.lastRead = -100000
                return
            end
            if a == "jdl_road" or a == "jdl_field" then
                if v ~= nil and v.setLightsTypesMask ~= nil then
                    local ok, err = pcall(v.setLightsTypesMask, v, a == "jdl_road" and 1 or 7)
                    if not ok then print("[AS_TerminalJohnDeere] ERREUR feux : " .. tostring(err)) end
                end
                self.lastRead = -100000
                return
            end
            if a:sub(1, 10) == "jdset_tab_" then
                local n = tonumber(a:sub(11)) or 1
                self.setSub = n == 2 and "tab" or (n == 3 and "home" or nil)
                M.setTop = 1
                return
            end
            if a == "jdset_more" then
                M.setTop = (M.setTop or 1) + M.SET_ROWS
                if M.setTop > (M.setN or 0) then M.setTop = 1 end
                return
            end
            if a == "jdtool_prev" or a == "jdtool_next" then
                local n = d.toolTabs ~= nil and #d.toolTabs or 0
                if n > 0 then
                    local cur = d.toolSel or 1
                    local nx = a == "jdtool_next" and (cur % n + 1) or ((cur - 2) % n + 1)
                    return orig(self, "tool_" .. nx, ...)
                end
                return
            end
        end
        return orig(self, a, ...)
    end
end
