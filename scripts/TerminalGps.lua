-- AutoSwitch : page GPS du terminal (guidage façon terminal réel, lié à Courseplay)
-- Fichier chargé par AutoSwitch.lua (après Terminal.lua, TerminalTools.lua et TerminalMap.lua).

-------------------------------------------------------------------------------
-- v1.0.4.0 (étape 30, 01/11) : partie GPS comme en réel, liée à Courseplay
--   Page GPS à la place de la page GUIDAGE :
--   - barre de guidage en haut (écart à la ligne en cm, LED, rang / tournière, système de la marque, RTK) ;
--   - vue en perspective derrière le tracteur (ou vue de dessus, cap en haut) : lignes du parcours
--     Courseplay, ligne en cours, couverture et recouvrement de la carte, bord du champ, tracteur et outils ;
--   - bandeau du bas : distance au demi-tour et son sens, avancement, surface restante, temps restant ;
--   - touches : DIRECTION (démarre / arrête Courseplay), DÉCALER (décalage outil de Courseplay), VUE, ZOOM,
--     PARCOURS (sous-page : réglages du parcours, voie multi-outils, enregistrer le bord du champ), MENU CP.
--   Rien n'est recalculé : les lignes, les rangs et les demi-tours viennent du parcours de Courseplay.
--   L'écart est calculé quand Courseplay conduit ET quand le chauffeur conduit lui-même (barre de guidage).
-------------------------------------------------------------------------------
AS_TerminalGps = {}
local G = AS_TerminalGps

G.SEARCH_MS = 1000               -- (70m) recherche complète de la ligne la plus proche (conduite manuelle), 1 fois par seconde (avant 2)
G.CACHE_MS = 100                 -- (70m, petits PC) dessin de la vue recalculé 10 fois par seconde au plus (avant 20)
G.FAR = 160                      -- profondeur de la vue (m)
G.LED_CM = 4                     -- une LED de la barre = 4 cm
G.COV_MAX = 1200                 -- (01/11) bandes de couverture au plus (grande fenêtre) ; (étape 37) 700 -> 1200
G.COV_MAX_3D = 820               -- ... sur l'écran 3D (limite 1400 carrés pour tout le terminal) ; (étape 37) 460 -> 820
G.view = "persp"                 -- "persp" (perspective derrière le tracteur) ou "top" (dessus, cap en haut)
G.zoom = 2
G.PERSP = {                      -- caméra : hauteur, recul derrière le tracteur, inclinaison (degrés)
    { h = 6, back = 16, pitch = 18 },
    { h = 11, back = 22, pitch = 24 },
    { h = 22, back = 34, pitch = 34 },
}
G.TOP = { 20, 40, 90 }           -- vue de dessus : demi-largeur (m)
G.sub = nil                      -- nil = écran de travail, "course" = sous-page PARCOURS
G.cache = setmetatable({}, { __mode = "k" })   -- parcours -> données lues une fois
G.state = setmetatable({}, { __mode = "k" })   -- véhicule -> ligne suivie
G.drawCache = nil
G.logged = {}

-- nom du système de guidage selon la marque (comme sur le vrai terminal)
G.NAMES = {
    JOHNDEERE = "AutoTrac", FENDT = "Fendt Guide", CASEIH = "AccuGuide", CASE = "AccuGuide",
    STEYR = "S-Guide", NEWHOLLAND = "IntelliSteer", CLAAS = "GPS PILOT", VALTRA = "Auto-Guide",
    CHALLENGER = "Auto-Guide", MASSEYFERGUSON = "MF Guide", DEUTZFAHR = "Agrosky", SAME = "Agrosky",
    LAMBORGHINI = "Agrosky",
}

local function U() return AS_Terminal.ui end
local function T(key) return U().T(key) end
local function call(obj, name, ...) return U().call(obj, name, ...) end
local function log(fmt, ...) print(string.format("[AS_Terminal] GPS : " .. fmt, ...)) end
local function logOnce(key, fmt, ...)
    if G.logged[key] then return end
    G.logged[key] = true
    log(fmt, ...)
end
local function clamp(v, a, b) return math.max(a, math.min(b, v)) end
-- (01/11) décalage affiché sans « -0.0 m »
local function fmtOff(o)
    o = o or 0
    if math.abs(o) < 0.05 then return "0.0 m" end
    return string.format("%+.1f m", o)
end

-------------------------------------------------------------------------------
-- Lecture du parcours Courseplay (une fois par parcours)
-------------------------------------------------------------------------------
local function courseData(course)
    local n = call(course, "getNumberOfWaypoints") or 0
    if n < 2 then return nil end
    local c = G.cache[course]
    if c ~= nil and c.n == n then return c end
    c = { n = n, x = {}, z = {}, row = {}, hl = {}, conn = {}, turn = {}, rowEnd = {}, cum = {}, toEnd = {}, turnsAfter = {}, maxRow = 0 }
    for i = 1, n do
        local wp = call(course, "getWaypoint", i)
        if wp == nil or wp.x == nil or wp.z == nil then return nil end
        c.x[i], c.z[i] = wp.x, wp.z
        local r = call(wp, "getRowNumber")
        if type(r) == "number" and r > 0 then
            c.row[i] = r
            if r > c.maxRow then c.maxRow = r end
        end
        local h = call(course, "getHeadlandNumber", i)
        if type(h) == "number" and h > 0 and c.row[i] == nil then c.hl[i] = h end
        c.conn[i] = call(wp, "isOnConnectingPath") == true
        c.rowEnd[i] = call(wp, "isRowEnd") == true
        c.turn[i] = call(course, "isTurnStartAtIx", i) == true or c.rowEnd[i]
    end
    -- distances cumulées, distance jusqu'au prochain demi-tour, demi-tours restants
    c.cum[1] = 0
    for i = 2, n do
        c.cum[i] = c.cum[i - 1] + math.sqrt((c.x[i] - c.x[i - 1]) ^ 2 + (c.z[i] - c.z[i - 1]) ^ 2)
    end
    c.length = c.cum[n]
    local nextTurn, turns = nil, 0
    for i = n, 1, -1 do
        if c.turn[i] then nextTurn = i; turns = turns + 1 end
        c.toEnd[i] = nextTurn ~= nil and (c.cum[nextTurn] - c.cum[i]) or nil
        c.turnsAfter[i] = turns
    end
    c.width = call(course, "getWorkWidth")
    c.nHl = call(course, "getNumberOfHeadlands")
    G.cache[course] = c
    logOnce("course" .. tostring(n), "parcours lu : %d points, %d rangs, largeur %s", n, c.maxRow, tostring(c.width))
    return c
end

-- point de guidage du véhicule et son cap
local function refPoint(v)
    local node = call(v, "getAIDirectionNode") or v.rootNode
    local x, _, z = getWorldTranslation(node)
    local dx, _, dz = localDirectionToWorld(node, 0, 0, 1)
    local l = math.sqrt(dx * dx + dz * dz)
    if l < 1e-6 then dx, dz = 0, 1 else dx, dz = dx / l, dz / l end
    return x, z, dx, dz
end

-- écart du point (x, z) au segment i -> i+1, décalé de « off » à droite du sens du parcours
-- retour : t (0..1 sur le segment), écart (m, + = à droite de la ligne dans le sens du véhicule), sens (1 / -1), longueur
local function segInfo(c, i, x, z, dx, dz, off)
    local ax, az, bx, bz = c.x[i], c.z[i], c.x[i + 1], c.z[i + 1]
    local sx, sz = bx - ax, bz - az
    local len = math.sqrt(sx * sx + sz * sz)
    if len < 0.05 then return nil end
    local ux, uz = sx / len, sz / len
    -- droite du sens du parcours = (-uz, ux) (sens de Courseplay : décalage + = à droite)
    ax, az = ax - uz * off, az + ux * off
    local t = ((x - ax) * ux + (z - az) * uz) / len
    local xte = (x - ax) * (-uz) + (z - az) * ux
    local along = ux * dx + uz * dz
    local sense = along >= 0 and 1 or -1
    return t, xte * sense, sense, len, along
end

local function isLine(c, i)
    return i >= 1 and i < c.n and not c.conn[i] and not c.turn[i]
end

-- ligne suivie en conduite manuelle : segment le plus proche, dans le sens du véhicule (± 30°)
local function search(c, x, z, dx, dz, off, prev)
    local best, bestScore = nil, math.huge
    local maxX = math.max(6, (c.width or 6) * 1.2)
    for i = 1, c.n - 1 do
        if isLine(c, i) and math.abs(c.x[i] - x) < 400 and math.abs(c.z[i] - z) < 400 then
            local t, xte, _, len, along = segInfo(c, i, x, z, dx, dz, off)
            if t ~= nil and math.abs(along) > 0.85 and t >= -2 / len and t <= 1 + 2 / len and math.abs(xte) < maxX then
                local score = math.abs(xte)
                if prev ~= nil and (c.row[i] or -1) == (c.row[prev] or -2) then score = score - 0.6 end
                if score < bestScore then best, bestScore = i, score end
            end
        end
    end
    return best
end

local function settingValue(st)
    if st == nil then return nil end
    local v = call(st, "getValue")
    return type(v) == "number" and v or nil
end

local function toolOffsetSetting(v)
    local s = call(v, "getCpSettings")
    return s ~= nil and s.toolOffsetX or nil
end

-------------------------------------------------------------------------------
-- Lecture (appelée par AS_Terminal:read)
-------------------------------------------------------------------------------
function G:read(v, d)
    local g = { system = self:systemName(v) }
    d.gps = g
    local ui = U()
    g.hasCp = ui.hasCp(v)
    if not g.hasCp then g.steer = "none" return end
    g.active = call(v, "getIsCpActive") == true
    local strategy = g.active and call(v, "getCpDriveStrategy") or nil
    local course = strategy ~= nil and strategy.fieldWorkCourse or nil
    if course == nil then course = call(v, "getFieldWorkCourse") end
    local offSt = toolOffsetSetting(v)
    g.offset = settingValue(offSt) or 0
    g.offsetDisabled = offSt ~= nil and call(offSt, "getIsDisabled") == true
    g.canStart = call(v, "getCanStartCp") == true
    g.recording = call(v, "getIsCpCourseRecorderActive") == true
    g.recPaused = g.recording and call(v, "getIsCpCourseRecorderPaused") == true
    local c = course ~= nil and courseData(course) or nil
    g.course = course
    g.data = c
    if c == nil then
        g.steer = g.active and "on" or "noLine"
        return
    end
    g.steer = g.active and "on" or (g.canStart and "ready" or "off")
    g.rows, g.nHl, g.width = c.maxRow, c.nHl, c.width
    local x, z, dx, dz = refPoint(v)
    local st = self.state[v]
    if st == nil or st.course ~= course then st = { course = course, t = -math.huge }; self.state[v] = st end
    local off = g.offset
    local i
    if g.active then
        local co, oz = call(course, "getOffset")
        off = type(co) == "number" and co or g.offset
        local ix = call(course, "getCurrentWaypointIx") or 1
        i = math.max(1, math.min(c.n - 1, ix - 1))
        -- Courseplay dans un demi-tour : parcours de demi-tour à la place du parcours du champ
        local cur = call(strategy, "getCurrentCourse")
        g.inTurn = cur ~= nil and cur ~= course
        st.i = i
    else
        local now = g_time or 0
        i = st.i
        -- on avance sur le même rang tant que le véhicule dépasse le bout du segment
        if i ~= nil and isLine(c, i) then
            local t = segInfo(c, i, x, z, dx, dz, off)
            local guard = 0
            while t ~= nil and t > 1 and guard < 20 and isLine(c, i + 1) do
                i = i + 1; guard = guard + 1
                t = segInfo(c, i, x, z, dx, dz, off)
            end
            while t ~= nil and t < 0 and guard < 40 and isLine(c, i - 1) do
                i = i - 1; guard = guard + 1
                t = segInfo(c, i, x, z, dx, dz, off)
            end
        end
        local far = false
        if i ~= nil then
            local t2, x2, _, _, al2 = segInfo(c, i, x, z, dx, dz, off)
            far = t2 == nil or math.abs(x2) > math.max(6, (c.width or 6) * 1.2) or math.abs(al2) < 0.85
        end
        if i == nil or far or now - st.t >= self.SEARCH_MS or now < st.t then
            st.t = now
            i = search(c, x, z, dx, dz, off, i)
        end
        st.i = i
    end
    if i == nil then g.onLine = false return end
    local t, xte, sense, len = segInfo(c, i, x, z, dx, dz, off)
    if t == nil then g.onLine = false return end
    g.onLine = true
    g.i, g.xte, g.sense = i, xte, sense
    g.off = off
    g.row = c.row[i]
    g.hl = c.hl[i]
    local tt = clamp(t, 0, 1)
    -- distance au demi-tour : dans le sens du parcours (Courseplay) ou dans le sens du véhicule
    if sense > 0 then
        local e = c.toEnd[i + 1]
        g.toTurn = e ~= nil and (len * (1 - tt) + e) or nil
        g.turnIx = e ~= nil and self:nextTurnIx(c, i + 1) or nil
    else
        -- à contre-sens du parcours : bout de la ligne en arrière
        local k, dist = i, len * tt
        while isLine(c, k - 1) do k = k - 1; dist = dist + (c.cum[k + 1] - c.cum[k]) end
        g.toTurn = dist
    end
    if g.turnIx ~= nil then g.turnLeft = self:turnIsLeft(c, g.turnIx) end
    local done = c.cum[i] + len * tt
    g.progress = c.length > 0 and clamp(done / c.length, 0, 1) or 0
    g.remaining = math.max(0, c.length - done)
    g.turnsLeft = c.turnsAfter[i + 1] or 0
    if g.active then
        local status = call(v, "getCpStatus")
        local txt = status ~= nil and call(status, "getTimeRemainingText") or nil
        if type(txt) == "string" and txt ~= "" then g.timeText = txt end
    end
    if g.timeText == nil and math.abs(d.speed or 0) > 3 then
        g.timeS = g.remaining / (math.abs(d.speed) / 3.6) + g.turnsLeft * 20
    end
end

function G:nextTurnIx(c, i)
    for k = i, c.n do if c.turn[k] then return k end end
    return nil
end

-- sens du demi-tour : vers où part la ligne suivante (à gauche ou à droite du rang)
function G:turnIsLeft(c, e)
    local k0 = math.max(1, e - 1)
    local ux, uz = c.x[e] - c.x[k0], c.z[e] - c.z[k0]
    local l = math.sqrt(ux * ux + uz * uz)
    if l < 0.05 then return nil end
    ux, uz = ux / l, uz / l
    for k = e + 1, math.min(c.n, e + 60) do
        if isLine(c, k) and not c.turn[k] then
            local wx, wz = c.x[k] - c.x[e], c.z[k] - c.z[e]
            local side = wx * (-uz) + wz * ux
            if math.abs(side) > 0.5 then return side < 0 end
        end
    end
    return nil
end

function G:systemName(v)
    local n = U().brandName ~= nil and U().brandName(v) or nil
    return (n ~= nil and self.NAMES[n]) or "AutoSwitch GPS"
end

-------------------------------------------------------------------------------
-- Vue : perspective derrière le tracteur ou dessus (cap en haut)
-------------------------------------------------------------------------------
local COL = {
    sky1 = { 0.07, 0.10, 0.16, 1 }, sky2 = { 0.12, 0.17, 0.25, 1 },
    ground = { 0.17, 0.20, 0.12, 1 }, groundMid = { 0.19, 0.22, 0.14, 1 }, groundFar = { 0.21, 0.24, 0.16, 1 },
    work = { 0.20, 0.58, 0.24, 1 }, over = { 0.85, 0.25, 0.20, 1 },
    line = { 0.62, 0.70, 0.78, 1 }, lineHl = { 0.85, 0.62, 0.20, 1 }, cur = { 0.25, 0.65, 1.00, 1 },
    border = { 0.95, 0.85, 0.35, 1 }, body = { 0.30, 0.55, 0.20, 1 }, tyre = { 0.05, 0.05, 0.05, 1 },
    cab = { 0.55, 0.70, 0.80, 1 }, toolOn = { 0.30, 0.85, 0.35, 1 }, toolOff = { 0.55, 0.57, 0.60, 1 },
}
G.COL = COL

local function cellKey(cx, cz) return (cx + 32768) * 65536 + (cz + 32768) end

-- caméra : renvoie project(lx, lz) -> u, v (unités du panneau), échelle (unités par mètre) ; nil = derrière
-- (04/11) rear : longueur (m) des outils derrière le tracteur ;
-- la vue recule (dessus : tracteur plus haut ; perspective : caméra plus loin) pour les montrer en entier
function G:camera(box, rear)
    rear = rear or 0
    if self.view == "top" then
        local half = self.TOP[clamp(self.zoom, 1, #self.TOP)]
        local s = box.w / (2 * half)
        local cu, cv = box.x + box.w * 0.5, box.y + box.h * 0.72
        if rear > 0 then cv = math.max(box.y + box.h * 0.38, math.min(cv, box.y + box.h - (rear + 1.5) * s)) end
        return function(lx, lz, _) return cu + lx * s, cv - lz * s, s end, { top = true, zMin = -(box.y + box.h - cv) / s, zMax = (cv - box.y) / s, s = s }
    end
    local p = self.PERSP[clamp(self.zoom, 1, #self.PERSP)]
    local pitch = math.rad(p.pitch)
    local sp, cp = math.sin(pitch), math.cos(pitch)
    local f = box.h * 0.95
    local cu = box.x + box.w * 0.5
    local horizon = box.y + box.h * 0.25   -- sous la barre de guidage
    local cv = horizon + f * sp / cp
    local H, B = p.h, p.back
    local function nearZ(Bk) return (1 - H * sp) / cp - Bk + 0.5 end
    local zMin = nearZ(B)
    -- (04/11) y : hauteur du point (m), pour dessiner le tracteur et les outils en volume
    local function proj(lx, lz, y)
        local zz = lz + B
        local hh = H - (y or 0)
        local fwd = hh * sp + zz * cp
        if fwd < 1 then return nil end
        local up = -hh * cp + zz * sp
        return cu + f * lx / fwd, cv - f * up / fwd, f / fwd
    end
    -- profondeur du bas de la vue (premier mètre visible)
    local function firstZ()
        local z0 = nearZ(B)
        for _ = 1, 60 do
            local _, vv = proj(0, z0)
            if vv ~= nil and vv <= box.y + box.h then break end
            z0 = z0 + 0.5
        end
        return z0
    end
    local z0 = firstZ()
    if rear > 0 and z0 > -(rear + 1.5) then
        B = math.min(p.back * 2.5, B + z0 + rear + 1.5)
        z0 = firstZ()
    end
    return proj, { horizon = horizon, zMin = z0, zMax = self.FAR, rear = rear }
end

-- position avant / arrière d'un outil dans le repère du tracteur (m)
function G.toolZ(t, toLocal)
    local node = t.o ~= nil and t.o.rootNode or nil
    if node ~= nil then
        local okP, wx, _, wz = pcall(getWorldTranslation, node)
        if okP and wx ~= nil then local _, lz = toLocal(wx, wz); return lz end
    end
    return t.z or -4
end

-- dessin de la vue dans une liste de carrés { u, v, w, h, couleur } (coordonnées du panneau)
function G:buildView(v, d, box, accent, lite)
    -- lite : écran 3D (700 carrés pour tout le terminal), moins de points
    local K = lite and 0.5 or 1
    local list = {}
    local function add(u, vv, w, h, c)
        if w <= 0 or h <= 0 then return end
        local u2, v2 = math.min(u + w, box.x + box.w), math.min(vv + h, box.y + box.h)
        u, vv = math.max(u, box.x), math.max(vv, box.y)
        if u2 > u and v2 > vv then list[#list + 1] = { u, vv, u2 - u, v2 - vv, c } end
    end
    local x, _, z = getWorldTranslation(v.rootNode)
    local dx, _, dz = localDirectionToWorld(v.rootNode, 0, 0, 1)
    local l = math.sqrt(dx * dx + dz * dz)
    if l < 1e-6 then dx, dz = 0, 1 else dx, dz = dx / l, dz / l end
    local rx, rz = -dz, dx              -- droite du véhicule
    local function toLocal(wx, wz)
        local ax, az = wx - x, wz - z
        return ax * rx + az * rz, ax * dx + az * dz
    end
    -- (04/11) longueur des outils derrière le tracteur (par pas de 2 m, pour que la vue ne bouge pas sans arrêt)
    local rear = 0
    for _, t in ipairs(d.toolTabs or {}) do
        if not t.self then
            local okG, q = pcall(G.toolGeom, t, toLocal)
            if okG and q ~= nil and q.cz < 0 then
                local yaw = q.yaw or 0
                local back = -(q.cz - q.L * 0.5 * math.abs(math.cos(yaw)) - q.W * 0.5 * math.abs(math.sin(yaw)))
                if back > rear then rear = back end
            end
        end
    end
    rear = rear > 0 and math.ceil(rear / 2) * 2 or 0
    local proj, cam = self:camera(box, rear)
    -- (04/11) repère de cette vue, pour poser d'autres dessins dessus (rampe des tronçons du MF Guide)
    self.lastView = { v = v, proj = proj, toLocal = toLocal, box = box }
    local function toWorld(lx, lz) return x + rx * lx + dx * lz, z + rz * lx + dz * lz end

    -- ciel et sol
    if cam.top then
        add(box.x, box.y, box.w, box.h, COL.ground)
    else
        local hz = cam.horizon
        add(box.x, box.y, box.w, (hz - box.y) * 0.5, COL.sky1)
        add(box.x, box.y + (hz - box.y) * 0.5, box.w, (hz - box.y) * 0.5 + 0.5, COL.sky2)
        local gh = box.y + box.h - hz
        add(box.x, hz, box.w, gh * 0.12 + 0.5, COL.groundFar)
        add(box.x, hz + gh * 0.12, box.w, gh * 0.18 + 0.5, COL.groundMid)
        add(box.x, hz + gh * 0.30, box.w, gh * 0.70 + 1, COL.ground)
    end

    -- couverture et recouvrement (carte de la page TRAVAIL), par bandes de profondeur.
    -- (01/11) lecture LISSÉE entre les cases de 2 m (comme une image agrandie) : les bords en biais
    -- deviennent des diagonales au lieu d'escaliers ; bandes fines (≈ 3-4 unités à l'écran partout)
    local M = AS_TerminalMap
    local map = M ~= nil and M.current ~= nil and M:current(v) or nil
    local nCov = 0
    -- (01/11) bandes de couverture recalculées seulement si le tracteur a bougé (25 cm, 0,5°) ou toutes les 0,5 s
    local cc = self.covCache ~= nil and self.covCache[lite] or nil   -- (70k) une par écran, comme la vue
    local nowC = g_time or 0
    local reuse = cc ~= nil and map ~= nil and cc.map == map and cc.view == self.view and cc.zoom == self.zoom and cc.rear == rear
        and cc.bw == box.w and cc.bx == box.x and cc.by == box.y and cc.lite == lite and nowC - cc.t < 1000 and nowC >= cc.t
        and (x - cc.x) ^ 2 + (z - cc.z) ^ 2 < 0.25 and dx * cc.dx + dz * cc.dz > 0.99985   -- (70m) 50 cm, 1°, 1 s (avant 25 cm, 0,5°, 0,5 s)
    if reuse then
        for _, r in ipairs(cc.rects) do list[#list + 1] = r end
        nCov = #cc.rects
        map = nil
    end
    local covStart = #list + 1
    if map ~= nil and map.n > 0 then
        local cell = M.CELL
        local cells, ovs = map.cells, map.ov
        -- (01/11) lecture à 50 cm : chaque case de 2 m garde ses 4 x 4 petites cases travaillées / repassées
        local SUB = M.SUB or 1
        local P2 = M.P2
        local parts, oparts = map.part or {}, map.opart or {}
        if P2 == nil then SUB = 1 end
        local sc = cell / SUB
        local floor = math.floor
        -- petite case n° bi de la case k : faite (0/1), repassée (0/1)
        local function subK(k, bi)
            local m = parts[k]
            local b
            if m ~= nil then
                b = P2[bi]
                if m % (b + b) < b then return 0, 0 end
            elseif cells[k] == nil then
                return 0, 0
            end
            local o = oparts[k]
            if o ~= nil then
                b = b or P2[bi]
                return 1, (o % (b + b) >= b) and 1 or 0
            end
            return 1, ovs[k] and 1 or 0
        end
        -- case de 2 m sans détail : état (0 rien, 1 fait, 2 repassé) ; avec détail : nil
        local function uni(k)
            if parts[k] ~= nil or oparts[k] ~= nil then return nil end
            if cells[k] == nil then return 0 end
            return ovs[k] and 2 or 1
        end
        -- état lissé au point (wx, wz) ; 2e valeur : true près d'une case avec détail de 50 cm
        local function st(wx, wz)
            local fx, fz = wx / sc - 0.5, wz / sc - 0.5
            local ix, iz = floor(fx), floor(fz)
            -- les 4 petites cases lues sont dans 1, 2 ou 4 cases de 2 m
            local cx, cz = floor(ix / SUB), floor(iz / SUB)
            local ia, ja = ix - cx * SUB, iz - cz * SUB
            local ex, ez = ia == SUB - 1, ja == SUB - 1
            local k = (cx + 32768) * 65536 + (cz + 32768)
            local s0
            if parts[k] == nil and oparts[k] == nil then
                if cells[k] == nil then s0 = 0 else s0 = ovs[k] and 2 or 1 end
                if not ex and not ez then return s0, false end
            end
            local kx = ex and k + 65536 or k
            local kz = ez and k + 1 or k
            local kxz = ex and kz + 65536 or kz
            local same = s0 ~= nil
            if same and ex then same = uni(kx) == s0 end
            if same and ez then same = uni(kz) == s0 end
            if same and ex and ez then same = uni(kxz) == s0 end
            if same then return s0, false end
            local det = s0 == nil or (ex and uni(kx) == nil) or (ez and uni(kz) == nil) or (ex and ez and uni(kxz) == nil)
            local ib = ex and 0 or ia + 1
            local jb = ez and 0 or ja + 1
            local tx, tz = fx - ix, fz - iz
            local c00, o00 = subK(k, ja * SUB + ia)
            local c10, o10 = subK(kx, ja * SUB + ib)
            local c01, o01 = subK(kz, jb * SUB + ia)
            local c11, o11 = subK(kxz, jb * SUB + ib)
            local nc = c00 + c10 + c01 + c11
            if nc == 0 then return 0, det end
            if nc < 4 and (c00 * (1 - tx) + c10 * tx) * (1 - tz) + (c01 * (1 - tx) + c11 * tx) * tz < 0.5 then return 0, det end
            local no = o00 + o10 + o01 + o11
            if no == 0 then return 1, det end
            if no == 4 then return 2, det end
            local bb = (o00 * (1 - tx) + o10 * tx) * (1 - tz) + (o01 * (1 - tx) + o11 * tx) * tz
            return bb >= 0.5 and 2 or 1, det
        end
        local BAND = 2.5                -- (étape 37) 4 -> 2,5 unités
        -- (01/11) trop de carrés : bandes plus hautes au prochain calcul (et de nouveau plus fines s'il y a de la place)
        local sKey = lite and "covScale3d" or "covScale"
        local bscale = self[sKey] or 1
        -- rectangle de la carte en mètres, 1 case de marge
        local WX0, WX1, WZ0, WZ1
        if map.bx0 ~= nil then
            WX0, WX1 = (map.bx0 - 1) * cell, (map.bx1 + 2) * cell
            WZ0, WZ1 = (map.bz0 - 1) * cell, (map.bz1 + 2) * cell
        end
        local maxCov = lite and self.COV_MAX_3D or self.COV_MAX
        -- (01/11) bandes au loin gardées tant que le tracteur a peu bougé pour elles (moins de 2 unités
        -- à l'écran, 1 s au plus) : les bandes sont toujours aux mêmes profondeurs devant le tracteur
        local bkey = tostring(map) .. "|" .. bscale .. "|" .. tostring(self.view) .. "|" .. tostring(self.zoom) .. "|" .. box.w .. "|" .. box.x .. "|" .. box.y
        self.bandCache = self.bandCache or {}
        local bc = self.bandCache[sKey]
        if bc == nil or bc.key ~= bkey then bc = { key = bkey, bands = {} }; self.bandCache[sKey] = bc end
        local bands = bc.bands
        local bi = 0
        local zc = cam.zMin
        local zEnd = math.min(cam.zMax, cam.top and cam.zMax or 120)
        -- par bande : un échantillon par case de 2 m (ou toutes les 3 unités à l'écran), tous les 50 cm
        -- près d'une case avec détail, puis bord affiné par dichotomie (à 1 unité près)
        local zm, v1, v2, half, bx0, bz0, smB
        local runState, runStart, prevX = 0, 0, nil
        local function sample(xq, stt)
            if stt ~= runState then
                local xb = xq
                if prevX ~= nil and xq <= half then
                    local lo, hi = prevX, xq
                    for _ = 1, 6 do
                        if (hi - lo) * smB < 0.7 then break end
                        local mid = (lo + hi) * 0.5
                        if st(bx0 + rx * mid, bz0 + rz * mid) == runState then lo = mid else hi = mid end
                    end
                    xb = (lo + hi) * 0.5
                end
                if runState ~= 0 then
                    local ua = proj(runStart, zm)
                    local ub = proj(xb, zm)
                    if ua ~= nil and ub ~= nil then
                        add(ua, v2, ub - ua, v1 - v2 + 0.4, runState == 2 and COL.over or COL.work)
                        nCov = nCov + 1
                    end
                end
                runState, runStart = stt, xb
            end
            prevX = xq
        end
        while zc < zEnd and nCov < maxCov do
            local s
            _, v1, s = proj(0, zc)
            if v1 == nil or s == nil then break end
            local dzs = math.max(0.25, BAND * bscale / s)
            _, v2 = proj(0, zc + dzs)
            if v2 == nil then break end
            zm = zc + dzs * 0.5
            local _, _, sm = proj(0, zm)
            sm = sm or s
            half = (box.w * 0.5) / sm + 2
            smB = sm
            bx0, bz0 = x + dx * zm, z + dz * zm
            local stepC = math.max(cell, 2 / sm)
            local fine = math.max(sc, 2 / sm)
            -- seulement la partie de la bande qui traverse le rectangle de la carte (+ 1 case)
            local ta, tb = -half, half
            if WX0 ~= nil then
                if math.abs(rx) > 1e-6 then
                    local t1, t2 = (WX0 - bx0) / rx, (WX1 - bx0) / rx
                    if t1 > t2 then t1, t2 = t2, t1 end
                    if t1 > ta then ta = t1 end
                    if t2 < tb then tb = t2 end
                elseif bx0 < WX0 or bx0 > WX1 then tb = ta - 1 end
                if math.abs(rz) > 1e-6 then
                    local t1, t2 = (WZ0 - bz0) / rz, (WZ1 - bz0) / rz
                    if t1 > t2 then t1, t2 = t2, t1 end
                    if t1 > ta then ta = t1 end
                    if t2 < tb then tb = t2 end
                elseif bz0 < WZ0 or bz0 > WZ1 then tb = ta - 1 end
            end
            bi = bi + 1
            local B = bands[bi]
            local reuse = false
            if B ~= nil and B.zm == zm and nowC >= B.t and nowC - B.t < 1000 then
                local dot = dx * B.dx + dz * B.dz
                local ang = dot >= 1 and 0 or math.sqrt(2 * (1 - dot))
                local ext = math.max(math.abs(zm), math.abs(ta), math.abs(tb))
                local err = (math.sqrt((x - B.x) ^ 2 + (z - B.z) ^ 2) + ang * ext) * sm
                reuse = err < 2
            end
            local n0b = #list
            if reuse then
                for _, r in ipairs(B.rects) do list[#list + 1] = r end
                nCov = nCov + #B.rects
            elseif ta <= tb then
                runState, runStart, prevX = 0, 0, nil
                local xs = ta
                local stt, det = st(bx0 + rx * xs, bz0 + rz * xs)
                if stt ~= runState then sample(xs, stt) else prevX = xs end
                while xs <= tb do
                    local xn = xs + stepC
                    local sn, dn = 0, false
                    if xn <= tb then sn, dn = st(bx0 + rx * xn, bz0 + rz * xn) end
                    -- deux bouts pareils mais une case avec détail tout près : peut-être une bande fine
                    -- (recouvrement de quelques dizaines de cm) entre les deux, on regarde tous les 50 cm
                    if (det or dn) and sn == stt and fine < stepC then
                        local xf = xs + fine
                        while xf < xn - fine * 0.5 do
                            if xf <= tb then
                                local sf = st(bx0 + rx * xf, bz0 + rz * xf)
                                if sf ~= runState then sample(xf, sf) else prevX = xf end
                            end
                            xf = xf + fine
                        end
                    end
                    if sn ~= runState then sample(xn, sn) else prevX = xn end
                    xs, det, stt = xn, dn, sn
                end
            end
            if not reuse then
                local rr = {}
                for i = n0b + 1, #list do rr[#rr + 1] = list[i] end
                bands[bi] = { zm = zm, x = x, z = z, dx = dx, dz = dz, t = nowC, rects = rr }
            end
            zc = zc + dzs
        end
        self.lastCov = nCov
        if zc < zEnd and nCov >= maxCov then
            self[sKey] = math.min(3, bscale * 1.25)
        elseif nCov < maxCov * 0.6 and bscale > 1 then
            self[sKey] = math.max(1, bscale / 1.1)
        end
        local rects = {}
        for i = covStart, #list do rects[#rects + 1] = list[i] end
        self.covCache = self.covCache or {}
        self.covCache[lite] = { map = map, view = self.view, zoom = self.zoom, rear = rear, bw = box.w, bx = box.x, by = box.y, lite = lite,
            t = nowC, x = x, z = z, dx = dx, dz = dz, rects = rects }
    end

    -- lignes : points espacés à l'écran, plus fins au loin
    local dots = 0
    local function segment(ax, az, bx, bz, col, thick, maxDots, dash)
        local la, za = toLocal(ax, az)
        local lb, zb = toLocal(bx, bz)
        local z0, z1 = cam.zMin, cam.zMax
        if (za < z0 and zb < z0) or (za > z1 and zb > z1) then return end
        -- coupe à la profondeur visible
        if za < z0 then local k = (z0 - za) / (zb - za); la, za = la + (lb - la) * k, z0 end
        if zb < z0 then local k = (z0 - zb) / (za - zb); lb, zb = lb + (la - lb) * k, z0 end
        if za > z1 then local k = (z1 - za) / (zb - za); la, za = la + (lb - la) * k, z1 end
        if zb > z1 then local k = (z1 - zb) / (za - zb); lb, zb = lb + (la - lb) * k, z1 end
        local ua, va, sa = proj(la, za)
        local ub, vb, sb = proj(lb, zb)
        if ua == nil or ub == nil then return end
        if (ua < box.x and ub < box.x) or (ua > box.x + box.w and ub > box.x + box.w) then return end
        local lenPx = math.sqrt((ub - ua) ^ 2 + (vb - va) ^ 2)
        local sz = clamp(thick * math.max(sa, sb), 1.0, thick * 14)
        local step = math.max(sz * 1.3, lite and 4 or 2.2)
        if dash then step = math.max(sz * 3, lite and 9 or 6) end
        local k = math.max(1, math.floor(lenPx / step))
        for j = 0, k do
            if dots >= maxDots then return end
            local f = j / k
            local s = sa + (sb - sa) * f
            local w = clamp(thick * s, 1.0, thick * 14)
            add(ua + (ub - ua) * f - w * 0.5, va + (vb - va) * f - w * 0.5, w, w, col)
            dots = dots + 1
        end
    end

    -- bord du champ
    local field
    if g_fieldManager ~= nil and g_fieldManager.getFieldAtWorldPosition ~= nil then
        local ok, f = pcall(g_fieldManager.getFieldAtWorldPosition, g_fieldManager, x, z)
        if ok then field = f end
    end
    local border = (M ~= nil and M.fieldBorder ~= nil) and M.fieldBorder(field) or nil
    if border ~= nil then
        local start = dots
        for i = 1, #border do
            local a, b = border[i], border[i % #border + 1]
            segment(a[1], a[2], b[1], b[2], COL.border, 0.18, start + 140 * K)
        end
    end

    -- lignes du parcours Courseplay (proches), ligne en cours par-dessus
    local g = d.gps
    local c = g ~= nil and g.data or nil
    if c ~= nil then
        local R2 = (self.FAR + 20) ^ 2
        local off = g.off or g.offset or 0
        -- lignes voisines d'abord (les plus proches sur le côté), en pointillés
        local cand = {}
        for i = 1, c.n - 1 do
            if not c.conn[i] and not c.turn[i] and (c.x[i] - x) ^ 2 + (c.z[i] - z) ^ 2 < R2 and (g.i == nil or c.row[i] == nil or c.row[i] ~= c.row[g.i]) then
                local lx, lz = toLocal((c.x[i] + c.x[i + 1]) * 0.5, (c.z[i] + c.z[i + 1]) * 0.5)
                if lz > cam.zMin - 10 then cand[#cand + 1] = { i, math.abs(lx) + math.max(0, lz) * 0.05 } end
            end
        end
        table.sort(cand, function(p, q) return p[2] < q[2] end)
        local start = dots
        for _, e in ipairs(cand) do
            local i = e[1]
            local sx, sz = c.x[i + 1] - c.x[i], c.z[i + 1] - c.z[i]
            local ln = math.sqrt(sx * sx + sz * sz)
            if ln > 0.05 then
                local ox, oz = -sz / ln * off, sx / ln * off
                segment(c.x[i] + ox, c.z[i] + oz, c.x[i + 1] + ox, c.z[i + 1] + oz, c.hl[i] ~= nil and COL.lineHl or COL.line, 0.10, start + 420 * K, true)
            end
            if dots >= start + 420 * K then break end
        end
        if g.i ~= nil then
            -- toute la ligne en cours (même rang), en couleur de la marque
            local a, b = g.i, g.i
            while isLine(c, a - 1) and (c.row[a - 1] == c.row[g.i]) and g.i - a < 200 do a = a - 1 end
            while isLine(c, b + 1) and (c.row[b + 1] == c.row[g.i]) and b - g.i < 200 do b = b + 1 end
            local s0 = dots
            for i = a, b do
                local sx, sz = c.x[i + 1] - c.x[i], c.z[i + 1] - c.z[i]
                local ln = math.sqrt(sx * sx + sz * sz)
                if ln > 0.05 then
                    local ox, oz = -sz / ln * off, sx / ln * off
                    segment(c.x[i] + ox, c.z[i] + oz, c.x[i + 1] + ox, c.z[i + 1] + oz, accent or COL.cur, 0.22, s0 + 160 * K)
                end
            end
        end
    end

    -- (04/11) tracteur et outils en volumes
    local okM, errM = pcall(self.drawMachines, self, v, d, proj, cam, add, toLocal, accent, lite)
    if not okM then logOnce("machines", "ERREUR dessin tracteur / outils : %s", tostring(errM)) end
    return list
end

-------------------------------------------------------------------------------
-- (04/11) tracteur et outils de la vue GPS, en volumes simples :
-- chaque pièce = une face arrière (verticale, vue de derrière) et un dessus, projetés par la caméra.
-- Perspective : pièces dessinées de la plus loin à la plus proche ; vue de dessus : de la plus basse à la plus haute.
-- Roues : vraies positions / rayons / largeurs du véhicule (spec_wheels) ; outil : vraie taille (size) et vraie position.
-------------------------------------------------------------------------------
local function sl(r, g, b)   -- couleur choisie en sRGB 0-255 -> valeur passée au jeu (il affiche ces couleurs éclaircies)
    local function f(c) c = c / 255; return c <= 0.04045 and c / 12.92 or ((c + 0.055) / 1.055) ^ 2.4 end
    return { f(r), f(g), f(b), 1 }
end
local function shade(c, k) return { math.min(1, c[1] * k), math.min(1, c[2] * k), math.min(1, c[3] * k), c[4] or 1 } end
local PAL = {
    tyre = sl(30, 30, 32), tyreTop = sl(50, 50, 53), lug = sl(66, 66, 70),
    glass = sl(36, 50, 64), glassHi = sl(96, 124, 146), frame = sl(20, 21, 23),
    chassis = sl(46, 48, 52), chassisTop = sl(68, 70, 75),
    steel = sl(150, 155, 160), steelDk = sl(98, 103, 110), steelTop = sl(186, 190, 195),
    beacon = sl(255, 148, 20), lamp = sl(255, 236, 168), tail = sl(215, 32, 26), blink = sl(255, 168, 30),
    paint = sl(140, 146, 154), paintTop = sl(176, 182, 190), paintDk = sl(100, 106, 114),
    tank = sl(236, 238, 240), tankDk = sl(196, 200, 205),
    work = sl(80, 214, 108), workDk = sl(48, 165, 78), mist = sl(170, 215, 255),
    load = sl(58, 50, 42), crop = sl(190, 156, 92),
}
G.PAL = PAL
-- (04/11) couleur de carrosserie du tracteur selon sa marque (sinon la couleur du terminal)
G.BODY = {
    CASEIH = sl(196, 22, 32), CASE = sl(196, 22, 32), STEYR = sl(200, 28, 30), NEWHOLLAND = sl(0, 78, 168),
    FENDT = sl(64, 128, 60), JOHNDEERE = sl(52, 124, 44), CLAAS = sl(150, 190, 24), DEUTZFAHR = sl(140, 196, 40),
    SAME = sl(200, 40, 30), LAMBORGHINI = sl(220, 220, 220), MASSEYFERGUSON = sl(196, 24, 28), VALTRA = sl(200, 200, 205),
    CHALLENGER = sl(230, 200, 30), KUBOTA = sl(232, 112, 24), MCCORMICK = sl(200, 30, 36), LINDNER = sl(140, 140, 140),
    ANTONIOCARRARO = sl(230, 120, 20), ZETOR = sl(200, 40, 40), KIOTI = sl(230, 110, 30), AGCO = sl(196, 24, 28),
}
-- longueur par défaut (m) quand l'outil n'a pas de taille
local DEF_LEN = { plow = 3.2, soil = 2.8, seeder = 2.6, sprayer = 3.0, mower = 1.8, tedder = 2.4, windrower = 3.6,
    baler = 5.2, baleLoader = 8, wrapper = 4, trailer = 7.5, forageWagon = 8.5, mixer = 6, header = 2.2, harvester = 7, generic = 2.2 }
local TRAILED = { trailer = true, forageWagon = true, mixer = true, baler = true, baleLoader = true, wrapper = true, harvester = true }

-- roues d'un véhicule dans le repère du tracteur : { x, z, r, w }
local function wheelsOf(o, toLocal, minR, maxN)
    local out = {}
    minR, maxN = minR or 0.15, maxN or 12
    local ws = o ~= nil and o.spec_wheels or nil
    if ws == nil or type(ws.wheels) ~= "table" then return out end
    for _, w in ipairs(ws.wheels) do
        local p = w.physics or w
        local n = w.repr or w.driveNode or w.node
        local r = p.radius or w.radius
        local wd = p.width or w.width
        if n ~= nil and n ~= 0 and type(r) == "number" and r > minR and r < 1.4 then
            local ok, x, _, z = pcall(getWorldTranslation, n)
            if ok and type(x) == "number" then
                local lx, lz = toLocal(x, z)
                out[#out + 1] = { x = lx, z = lz, r = r, w = (type(wd) == "number" and wd > 0.08 and wd < 1.3) and wd or r * 0.6 }
            end
        end
    end
    -- (04/11) semoir monograine : des dizaines de petites roues d'éléments ; on garde les plus grosses
    if #out > maxN then
        table.sort(out, function(a, b) return a.r > b.r end)
        for i = #out, maxN + 1, -1 do out[i] = nil end
    end
    return out
end
G.wheelsOf = wheelsOf

-- essieux du tracteur (arrière, avant) : z, rayon, largeur, voie (demi) ; valeurs moyennes si les roues ne se lisent pas
local function tractorGeom(v, toLocal)
    local g = { rz = 0, rr = 0.85, rw = 0.6, rt = 0.95, fz = 2.6, fr = 0.56, fw = 0.42, ft = 0.92 }
    local wl = wheelsOf(v, toLocal)
    if #wl < 3 then return g end
    local zmin, zmax = math.huge, -math.huge
    for _, w in ipairs(wl) do zmin = math.min(zmin, w.z); zmax = math.max(zmax, w.z) end
    if zmax - zmin < 1.2 then return g end
    local mid = (zmin + zmax) * 0.5
    local function axle(rear)
        local a, n = { z = 0, r = 0, w = 0, t = 0 }, 0
        for _, w in ipairs(wl) do
            if (w.z < mid) == rear then
                n = n + 1
                a.z = a.z + w.z; a.r = math.max(a.r, w.r); a.w = math.max(a.w, w.w); a.t = math.max(a.t, math.abs(w.x))
            end
        end
        if n == 0 then return nil end
        a.z = a.z / n
        return a
    end
    local a, b = axle(true), axle(false)
    if a == nil or b == nil or a.t < 0.4 or b.t < 0.4 then return g end
    g.rz, g.rr, g.rw, g.rt = a.z, clamp(a.r, 0.35, 1.2), clamp(a.w, 0.2, 1.0), clamp(a.t, 0.6, 1.8)
    g.fz, g.fr, g.fw, g.ft = b.z, clamp(b.r, 0.3, 1.1), clamp(b.w, 0.15, 0.9), clamp(b.t, 0.55, 1.8)
    return g
end
G.tractorGeom = tractorGeom

-- position et taille d'un outil : centre (cx, cz), arrière zb, avant zf, largeur affichée W, longueur L
local function toolGeom(t, toLocal)
    local o = t.o
    local size = o ~= nil and type(o.size) == "table" and o.size or nil
    local L = size ~= nil and tonumber(size.length) or nil
    if L == nil or L < 0.5 then L = DEF_LEN[t.kind] or 2.2 end
    L = clamp(L, 0.6, 18)
    local lo = size ~= nil and tonumber(size.lengthOffset) or 0
    local wo = size ~= nil and tonumber(size.widthOffset) or 0
    local cx, cz
    local node = o ~= nil and o.rootNode or nil
    if node ~= nil and localToWorld ~= nil then
        local ok, wx, _, wz = pcall(localToWorld, node, wo, 0, lo)
        if ok and type(wx) == "number" then cx, cz = toLocal(wx, wz) end
    end
    if cx == nil then cx, cz = 0, G.toolZ(t, toLocal) end
    local sw = size ~= nil and tonumber(size.width) or nil
    local W = t.width or 0
    if t.unfolded == false and sw ~= nil and sw > 0.5 then W = math.min(W > 0.2 and W or sw, sw) end
    if W <= 0.2 then W = (sw ~= nil and sw > 0.5) and sw or 2.5 end
    W = clamp(W, 0.6, 50)
    -- (04/11, semoir traîné en virage) angle de l'outil par rapport au tracteur (0 = dans l'axe)
    local yaw = 0
    if node ~= nil and localDirectionToWorld ~= nil and localToWorld ~= nil then
        local okD, tdx, _, tdz = pcall(localDirectionToWorld, node, 0, 0, 1)
        local okP, wx, _, wz = pcall(localToWorld, node, wo, 0, lo)
        if okD and okP and type(tdx) == "number" and type(wx) == "number" then
            local ax, az = toLocal(wx, wz)
            local bx, bz = toLocal(wx + tdx, wz + tdz)
            local ddx, ddz = bx - ax, bz - az
            if ddx * ddx + ddz * ddz > 1e-6 then yaw = math.atan2(ddx, ddz) end
        end
    end
    return { cx = cx, cz = cz, zb = cz - L * 0.5, zf = cz + L * 0.5, W = W, L = L, sw = sw, yaw = yaw }
end
G.toolGeom = toolGeom

-- (04/11) pièces d'un outil à son vrai angle (outil traîné en virage) : chaque face, donnée « dans l'axe » autour du centre
-- (cx, cz), est tournée et découpée en petits morceaux (les carrés de l'écran ne tournent pas)
function G.rotSet(base, cx, cz, yaw, lite)
    local function same(x, z) return x, z end
    if math.abs(yaw) < math.rad(2) then
        local S = {}
        for k, f in pairs(base) do S[k] = f end
        S.R = same
        return S
    end
    local c, s = math.cos(yaw), math.sin(yaw)
    local ac, as = math.abs(c), math.abs(s)
    local function R(x, z) local a, b = x - cx, z - cz; return cx + a * c + b * s, cz - a * s + b * c end
    local S = { R = R }
    local maxP = lite and 16 or 40
    function S.part(key, yt) local _, kz = R(cx, key); return base.part(kz, yt) end
    local function flat(fn, p, x0, x1, z0, z1, y, col)
        local w, l = x1 - x0, z1 - z0
        local tgt = math.max(0.35, math.min(w, l) * 0.6)
        local kx, kz = math.max(1, math.ceil(w / tgt)), math.max(1, math.ceil(l / tgt))
        while kx * kz > maxP do
            if kx >= kz then kx = math.max(1, math.floor(kx * 0.7)) else kz = math.max(1, math.floor(kz * 0.7)) end
        end
        local sx, sz = w / kx, l / kz
        local bx, bz = (sx * ac + sz * as) * 0.5, (sx * as + sz * ac) * 0.5
        for i = 1, kx do
            for j = 1, kz do
                local px, pz = R(x0 + (i - 0.5) * sx, z0 + (j - 0.5) * sz)
                fn(p, px - bx, px + bx, pz - bz, pz + bz, y, col)
            end
        end
    end
    function S.hf(p, x0, x1, z0, z1, y, col) flat(base.hf, p, x0, x1, z0, z1, y, col) end
    function S.tf(p, x0, x1, z0, z1, y, col) flat(base.tf, p, x0, x1, z0, z1, y, col) end
    function S.vf(p, x0, x1, z, y0, y1, col)
        local w = x1 - x0
        local k = clamp(math.ceil(w / 0.6), 1, lite and 8 or 24)
        local sx = w / k
        local hw = math.max(0.03, sx * ac * 0.5 + 0.02)
        for i = 1, k do
            local px, pz = R(x0 + (i - 0.5) * sx, z)
            base.vf(p, px - hw, px + hw, pz, y0, y1, col)
        end
    end
    function S.box(x0, x1, zb, zf, y0, y1, cTop, cBack, key)
        if x1 < x0 then x0, x1 = x1, x0 end
        local p = S.part(key or zb, y1)
        if cTop ~= nil then S.hf(p, x0, x1, zb, zf, y1, cTop) end
        if cBack ~= nil then S.vf(p, x0, x1, zb, y0, y1, cBack) end
        return p
    end
    function S.tyre(x, z, r, w) local px, pz = R(x, z); return base.tyre(px, pz, r, w) end
    return S
end

function G:drawMachines(v, d, proj, cam, add, toLocal, accent, lite)
    local P = {}
    -- key : ordre de dessin (perspective) = z le plus proche de la caméra ; yt : hauteur du dessus (vue de dessus)
    local function part(key, yt) local p = { key = key, yt = yt or 0, n = #P + 1 }; P[#P + 1] = p; return p end
    local function vf(p, x0, x1, z, y0, y1, c) p[#p + 1] = { 1, x0, x1, z, y0, y1, c } end      -- face arrière (verticale)
    local function hf(p, x0, x1, z0, z1, y, c) p[#p + 1] = { 2, x0, x1, z0, z1, y, c } end      -- dessus (z0 arrière, z1 avant)
    local function tf(p, x0, x1, z0, z1, y, c) p[#p + 1] = { 3, x0, x1, z0, z1, y, c } end      -- détail vu seulement de dessus
    local function box(x0, x1, zb, zf, y0, y1, cTop, cBack, key)
        if x1 < x0 then x0, x1 = x1, x0 end
        local p = part(key or zb, y1)
        if cTop ~= nil then hf(p, x0, x1, zb, zf, y1, cTop) end
        if cBack ~= nil then vf(p, x0, x1, zb, y0, y1, cBack) end
        return p
    end
    -- pneu : bande de roulement (dessus), flanc arrière arrondi, crampons en chevrons
    local function tyre(x, z, r, w)
        local x0, x1 = x - w * 0.5, x + w * 0.5
        local zb, zf = z - r * 0.55, z + r * 0.55
        local p = part(zb, 2 * r)
        hf(p, x0, x1, zb, zf, 2 * r, PAL.tyreTop)
        local ins = w * 0.14
        vf(p, x0, x1, zb, r * 0.24, r * 1.76, PAL.tyre)
        vf(p, x0 + ins, x1 - ins, zb, 0, 2 * r, PAL.tyre)
        local nL = lite and 4 or clamp(math.floor(r / 0.11), 4, 9)
        for k = 1, nL do
            local y = (k - 0.5) * 2 * r / nL
            if k % 2 == 0 then vf(p, x0 + ins, x, zb, y - 0.035, y + 0.035, PAL.lug)
            else vf(p, x, x1 - ins, zb, y - 0.035, y + 0.035, PAL.lug) end
        end
        if not lite then
            for k = 1, 4 do
                local zz = zb + (zf - zb) * (k - 0.5) / 4
                tf(p, x0, x1, zz - 0.04, zz + 0.04, 2 * r, PAL.lug)
            end
        end
        return p
    end

    -- ---------------------------------------------------------------- tracteur
    local g = tractorGeom(v, toLocal)
    local bn = U() ~= nil and U().brandName ~= nil and U().brandName(v) or nil
    local B = (bn ~= nil and self.BODY[bn]) or accent or COL.body
    local Bt, Bd = shade(B, 1.25), shade(B, 0.68)
    local rz, rr, rw, rt = g.rz, g.rr, g.rw, g.rt
    local fz, fr, fw, ft = g.fz, g.fr, g.fw, g.ft
    -- roues avant, garde-boue avant, châssis avant
    for sg = -1, 1, 2 do
        tyre(sg * ft, fz, fr, fw)
        box(sg * ft - fw * 0.5 - 0.03, sg * ft + fw * 0.5 + 0.03, fz - fr * 0.45, fz + fr * 0.45, 2 * fr + 0.03, 2 * fr + 0.1, Bt, Bd)
    end
    box(-0.42, 0.42, rz + 0.7, fz + fr * 0.9, 0.35, 0.9, PAL.chassisTop, PAL.chassis)
    -- capot, échappement, rétroviseurs
    local hw = clamp(rt - rw * 0.5 - 0.38, 0.32, 0.55)
    local cw = clamp(rt - rw * 0.5 - 0.1, 0.58, 0.95)
    local hood = box(-hw, hw, rz + 0.95, fz + fr * 0.95, 0.85, 1.85, Bt, B)
    tf(hood, -0.05, 0.05, rz + 1.0, fz + fr * 0.9, 1.851, Bd)
    box(hw - 0.17, hw - 0.07, rz + 1.08, rz + 1.18, 1.85, 3.45, PAL.frame, PAL.frame)
    for sg = -1, 1, 2 do
        box(sg * cw, sg * (cw + 0.36), rz + 0.78, rz + 0.84, 2.46, 2.52, PAL.frame, PAL.frame)
        box(sg * (cw + 0.28), sg * (cw + 0.42), rz + 0.78, rz + 0.84, 2.1, 2.66, PAL.frame, PAL.frame)
    end
    -- cabine : vitre arrière, montants, bas de caisse ; reflets
    local cab = part(rz - 0.55, 2.95)
    vf(cab, -cw, cw, rz - 0.55, 1.3, 1.5, B)
    vf(cab, -cw, cw, rz - 0.55, 1.5, 2.95, PAL.glass)
    if not lite then
        vf(cab, -cw + 0.2, -cw + 0.36, rz - 0.55, 2.15, 2.85, PAL.glassHi)
        vf(cab, -cw + 0.44, -cw + 0.5, rz - 0.55, 2.35, 2.85, PAL.glassHi)
    end
    vf(cab, -cw, -cw + 0.09, rz - 0.55, 1.3, 2.95, PAL.frame)
    vf(cab, cw - 0.09, cw, rz - 0.55, 1.3, 2.95, PAL.frame)
    -- toit, phares de travail, gyrophare (dessiné après le toit)
    local roof = box(-cw - 0.08, cw + 0.08, rz - 0.72, rz + 1.12, 2.95, 3.15, Bt, Bd)
    for _, lx in ipairs({ -cw + 0.12, -cw + 0.42, cw - 0.56, cw - 0.26 }) do vf(roof, lx, lx + 0.14, rz - 0.721, 3.0, 3.1, PAL.lamp) end
    box(-cw + 0.12, -cw + 0.34, rz - 0.3, rz - 0.08, 3.15, 3.4, PAL.beacon, shade(PAL.beacon, 0.8), rz - 0.75)
    -- garde-boue arrière avec feux (rouge + clignotant) ; pont arrière, prise de force
    for sg = -1, 1, 2 do
        local x0, x1 = sg * rt - rw * 0.5 - 0.05, sg * rt + rw * 0.5 + 0.05
        if x1 < x0 then x0, x1 = x1, x0 end
        tyre(sg * rt, rz, rr, rw)
        local fen = box(x0, x1, rz - rr * 0.8, rz + rr * 0.15, 2 * rr + 0.02, 2 * rr + 0.12, Bt, Bd)
        local xo = sg > 0 and x1 - 0.16 or x0
        vf(fen, xo, xo + 0.16, rz - rr * 0.8, 2 * rr - 0.14, 2 * rr + 0.02, PAL.tail)
        local xb = sg > 0 and x1 - 0.32 or x0 + 0.16
        vf(fen, xb, xb + 0.16, rz - rr * 0.8, 2 * rr - 0.14, 2 * rr + 0.02, PAL.blink)
    end
    local hz = rz - 0.75                 -- arrière du pont (attelage)
    local hous = box(-0.55, 0.55, hz, rz + 0.5, 0.5, 1.3, PAL.chassisTop, PAL.chassis)
    vf(hous, -0.07, 0.07, hz - 0.001, 0.62, 0.74, PAL.steel)
    local fh = fz + fr + 0.25           -- avant (relevage avant)

    -- ---------------------------------------------------------------- outils
    for _, t in ipairs(d.toolTabs or {}) do
        if not t.self then
            local okG, q = pcall(toolGeom, t, toLocal)
            if okG and q ~= nil then
                local A = { part = part, vf = vf, hf = hf, tf = tf, box = box, tyre = tyre }
                self:drawTool(t, q, g, hz, fh, self.rotSet(A, q.cx, q.cz, q.yaw or 0, lite), A, toLocal, lite)
            end
        end
    end

    -- ---------------------------------------------------------------- dessin
    if cam.top then
        table.sort(P, function(a, b) if a.yt ~= b.yt then return a.yt < b.yt end return a.n < b.n end)
    else
        table.sort(P, function(a, b) if a.key ~= b.key then return a.key > b.key end return a.n < b.n end)
    end
    local maxB = lite and 3 or 16
    for _, p in ipairs(P) do
        for _, f in ipairs(p) do
            local k = f[1]
            if cam.top then
                if k ~= 1 then
                    local u0, v0 = proj(f[2], f[5])
                    local u1, v1 = proj(f[3], f[4])
                    if u0 ~= nil and u1 ~= nil then
                        local w, h = math.max(1, u1 - u0), math.max(1, v1 - v0)
                        add(u0, v0, w, h, f[7])
                    end
                end
            elseif k == 1 then
                local ym = (f[5] + f[6]) * 0.5
                local ua = proj(f[2], f[4], ym)
                local ub = proj(f[3], f[4], ym)
                local _, vt = proj(f[2], f[4], f[6])
                local _, vb = proj(f[2], f[4], f[5])
                if ua ~= nil and ub ~= nil and vt ~= nil and vb ~= nil then
                    if ub - ua < 1 then local m = (ua + ub) * 0.5; ua, ub = m - 0.5, m + 0.5 end
                    if vb - vt < 1 then local m = (vt + vb) * 0.5; vt, vb = m - 0.5, m + 0.5 end
                    add(ua, vt, ub - ua, vb - vt, f[7])
                end
            elseif k == 2 then
                local x0, x1, z0, z1, y = f[2], f[3], f[4], f[5], f[6]
                local _, va = proj(0, z1, y)
                local _, vb = proj(0, z0, y)
                if va ~= nil and vb ~= nil and vb > va then
                    local nb = clamp(math.ceil((vb - va) / (lite and 8 or 4)), 1, maxB)
                    for i = 1, nb do
                        local za = z1 + (z0 - z1) * (i - 1) / nb
                        local zc = z1 + (z0 - z1) * i / nb
                        local zm = (za + zc) * 0.5
                        local ua = proj(x0, zm, y)
                        local ub = proj(x1, zm, y)
                        local _, v1 = proj(0, za, y)
                        local _, v2 = proj(0, zc, y)
                        if ua ~= nil and ub ~= nil and v1 ~= nil and v2 ~= nil then
                            add(ua, v1, math.max(1, ub - ua), math.max(1, v2 - v1 + 0.5), f[7])
                        end
                    end
                end
            end
        end
    end
end

-- un outil : dessiné selon son type (charrue, outil de sol, semoir, pulvé, faucheuse, faneuse, andaineur, presse, remorque...)
function G:drawTool(t, q, g, hz, fh, S, A, toLocal, lite)
    local part, vf, hf, tf, box, tyre = S.part, S.vf, S.hf, S.tf, S.box, S.tyre
    local kind = t.kind or "generic"
    local cx, cz, zb, zf, W, L = q.cx, q.cz, q.zb, q.zf, q.W, q.L
    local x0, x1 = cx - W * 0.5, cx + W * 0.5
    local front = cz > g.rz + 0.5
    local trailed = TRAILED[kind] == true or L > 5.5
    local working = t.working == true
    local yl = (t.lowered == false and not trailed) and 0.4 or 0       -- outil porté relevé
    local wk, wkD = working and PAL.work or PAL.steel, working and PAL.workDk or PAL.steelDk
    local folded = t.unfolded == false
    local wl = wheelsOf(t.o, toLocal, 0.28, 8)
    local fx, fzR = S.R(cx, zf)            -- avant de l'outil, à son vrai angle

    -- attelage : bras du relevage (porté) ou timon (traîné), jusqu'au tracteur
    if not front and fzR < hz - 0.05 then
        if trailed then
            -- timon : de l'avant de l'outil à l'attelage du tracteur, en petits morceaux (il peut être en biais)
            local ddx, ddz = -fx, hz - fzR
            local len = math.sqrt(ddx * ddx + ddz * ddz)
            local k = clamp(math.ceil(len / 0.4), 1, 12)
            for i = 1, k do
                local px, pz = fx + ddx * (i - 0.5) / k, fzR + ddz * (i - 0.5) / k
                A.box(px - 0.08, px + 0.08, pz - len / k * 0.5, pz + len / k * 0.5, 0.45, 0.58, PAL.steelDk, PAL.frame)
            end
        else
            box(-0.5, -0.41, zf, hz, 0.42 + yl, 0.52 + yl, PAL.steelDk, PAL.frame)
            box(0.41, 0.5, zf, hz, 0.42 + yl, 0.52 + yl, PAL.steelDk, PAL.frame)
            box(-0.05, 0.05, zf, hz, 1.0 + yl * 0.5, 1.08 + yl * 0.5, PAL.steelDk, PAL.frame)
        end
    elseif front and zb > fh then
        box(-0.5, -0.41, fh, zb, 0.42 + yl, 0.52 + yl, PAL.steelDk, PAL.frame)
        box(0.41, 0.5, fh, zb, 0.42 + yl, 0.52 + yl, PAL.steelDk, PAL.frame)
    end
    local function frameBox(a, b, za, zc, y0, y1, key) return box(a, b, za, zc, y0 + yl, y1 + yl, PAL.paintTop, PAL.paint, key) end
    local function headstock(z) box(cx - 0.35, cx + 0.35, z - 0.3, z, 0.4 + yl, 1.15 + yl, PAL.paintTop, PAL.paintDk) end

    if kind == "soil" then
        headstock(zf)
        frameBox(x0, x1, zf - 0.55, zf - 0.28, 0.55, 0.75)
        frameBox(x0, x1, cz - 0.1, cz + 0.1, 0.6, 0.75)
        local tines = part(cz - 0.12, 0.6 + yl)
        local n = clamp(math.floor(W / 0.4 + 0.5), 3, lite and 10 or 24)
        for i = 1, n do
            local xc = x0 + (i - 0.5) * W / n
            vf(tines, xc - 0.035, xc + 0.035, cz - 0.11, 0.02 + yl, 0.6 + yl, wkD)
        end
        frameBox(x0, x1, zb + 0.2, zb + 0.4, 0.58, 0.68)
        local rol = box(x0, x1, zb, zb + 0.6, yl, 0.55 + yl, working and PAL.work or PAL.steelTop, PAL.steelDk)
        vf(rol, x0, x1, zb - 0.001, 0.24 + yl, 0.29 + yl, PAL.frame)
    elseif kind == "plow" then
        headstock(zf)
        local n = clamp(math.floor(W / 0.42 + 0.5), 2, lite and 6 or 9)
        local dir = t.plowTurned and -1 or 1
        local lastX, lastZ
        for i = 1, n do
            local fr = n > 1 and (i - 1) / (n - 1) or 0
            local xc = cx + dir * (-W * 0.5 + (i - 0.5) * W / n)
            local zc = zf - 0.55 - fr * math.max(0.5, L - 1.2)
            frameBox(xc - W / (2 * n) - 0.02, xc + W / (2 * n) + 0.02, zc - 0.08, zc + 0.08, 0.8, 0.92)
            box(xc - 0.05, xc + 0.05, zc - 0.05, zc + 0.05, 0.5 + yl, 0.82 + yl, PAL.paintDk, PAL.paint)
            box(xc - 0.21, xc + 0.21, zc - 0.32, zc + 0.32, yl, 0.55 + yl, working and PAL.work or PAL.steelTop, working and PAL.workDk or PAL.steel)
            lastX, lastZ = xc, zc
        end
        if lastX ~= nil and #wl == 0 then tyre(lastX + dir * 0.4, math.max(zb + 0.35, lastZ - 0.2), 0.34, 0.24) end
    elseif kind == "seeder" then
        if not trailed then headstock(zf) end
        frameBox(x0, x1, zb + 0.42, zb + 0.72, 0.4, 0.58)
        local hx0, hx1 = x0 + 0.1, x1 - 0.1
        if W > 6.5 then hx0, hx1 = cx - 1.3, cx + 1.3 end
        -- (04/11) semoir traîné long (monograine, Valtra Momentum) : cuve au milieu derrière le timon, barre d'éléments derrière
        local hz0, hz1 = cz - 0.45, cz + 0.45
        if trailed then
            hz0, hz1 = zb + 1.6, math.max(zb + 2.4, math.min(zf - 1.0, zb + 4.4))
            frameBox(cx - 0.13, cx + 0.13, hz1, zf, 0.45, 0.62)
            frameBox(cx - 0.5, cx + 0.5, zb + 0.6, hz0, 0.5, 0.75)
        end
        local hop = box(hx0, hx1, hz0, hz1, 0.8 + yl, 1.85 + yl, PAL.paintTop, PAL.paint)
        tf(hop, hx0 + 0.08, hx1 - 0.08, hz0 + 0.15, hz1 - 0.15, 1.851 + yl, PAL.paintDk)
        if t.main ~= nil and (t.main.frac or 0) > 0.02 and not lite then
            vf(hop, hx0 + 0.15, hx0 + 0.3, hz0 - 0.001, 0.9 + yl, 0.9 + yl + 0.85 * clamp(t.main.frac, 0, 1), PAL.crop)
        end
        local cou = part(zb + 0.3, 0.38 + yl)
        local n = clamp(math.floor(W / 0.25 + 0.5), 4, lite and 12 or 32)
        for i = 1, n do
            local xc = x0 + (i - 0.5) * W / n
            vf(cou, xc - 0.03, xc + 0.03, zb + 0.32, yl, 0.4 + yl, wkD)
        end
        if t.markers ~= nil then
            box(x0 - 0.12, x0, cz - 0.1, cz + 0.1, 0.6 + yl, 1.9 + yl, PAL.paintDk, PAL.paint)
            box(x1, x1 + 0.12, cz - 0.1, cz + 0.1, 0.6 + yl, 1.9 + yl, PAL.paintDk, PAL.paint)
        end
    elseif kind == "sprayer" then
        local zt0, zt1 = cz - 0.55, cz + 0.55
        if trailed then zt0, zt1 = zb + 1.0, zf - 1.6; if zt1 < zt0 + 1 then zt1 = zt0 + 1 end end
        if not trailed then headstock(zf) end
        local tk = part(zt0, 1.95 + yl)
        hf(tk, cx - 0.85, cx + 0.85, zt0, zt1, 1.95 + yl, PAL.tank)
        vf(tk, cx - 0.85, cx + 0.85, zt0, 0.72 + yl, 1.84 + yl, PAL.tankDk)
        vf(tk, cx - 0.74, cx + 0.74, zt0, 0.6 + yl, 1.95 + yl, PAL.tankDk)
        frameBox(cx - 0.95, cx + 0.95, zb + 0.08, zb + 0.4, 0.4, 0.95)
        if folded or W <= 3.5 then
            box(cx - 1.08, cx - 0.92, zb + 0.05, zb + 0.35, 0.6 + yl, 2.6 + yl, PAL.steelTop, PAL.steel)
            box(cx + 0.92, cx + 1.08, zb + 0.05, zb + 0.35, 0.6 + yl, 2.6 + yl, PAL.steelTop, PAL.steel)
        else
            local bm = box(x0, x1, zb, zb + 0.18, 0.95 + yl, 1.12 + yl, PAL.steelTop, working and PAL.work or PAL.steel)
            local n = clamp(math.floor(W / 3 + 0.5), 2, 12)
            for i = 1, n - 1 do
                local xc = x0 + i * W / n
                vf(bm, xc - 0.04, xc + 0.04, zb - 0.001, 0.95 + yl, 1.12 + yl, PAL.frame)
            end
            if working and not lite then
                local m = clamp(math.floor(W / 1.5), 2, 24)
                for i = 1, m do
                    local xc = x0 + (i - 0.5) * W / m
                    vf(bm, xc - 0.05, xc + 0.05, zb - 0.002, 0.55 + yl, 0.95 + yl, PAL.mist)
                end
            end
        end
    elseif kind == "mower" then
        if not front and math.max(W, t.width or 0) >= 4.5 then
            frameBox(cx - 0.45, cx + 0.45, zb + 0.4, zf, 0.5, 1.25)
            if folded then
                box(cx - 1.4, cx - 1.08, cz - 0.6, cz + 0.6, 0.7, 2.9, PAL.paintTop, PAL.paint)
                box(cx + 1.08, cx + 1.4, cz - 0.6, cz + 0.6, 0.7, 2.9, PAL.paintTop, PAL.paint)
            else
                for sg = -1, 1, 2 do
                    local a, b = cx + sg * 0.35, cx + sg * W * 0.5
                    if b < a then a, b = b, a end
                    frameBox(a, b, zb + 0.55, zb + 0.7, 0.55, 0.65)
                    local bed = box(a, b, zb, zb + 1.3, yl, 0.42 + yl, PAL.paintTop, PAL.paint)
                    vf(bed, a, b, zb - 0.001, yl, 0.1 + yl, wkD)
                end
            end
        else
            if front then headstock(zf) end
            local bed = box(x0, x1, zb, zb + math.min(L, 1.4), yl, 0.42 + yl, PAL.paintTop, PAL.paint)
            vf(bed, x0, x1, zb - 0.001, yl, 0.1 + yl, wkD)
        end
    elseif kind == "tedder" or kind == "windrower" then
        local n = kind == "tedder" and clamp(math.floor(W / 1.45 + 0.5), 2, 12) or (W > 10 and 4 or W > 6.5 and 2 or 1)
        if folded then
            box(cx - 1.2, cx - 0.95, cz - 0.6, cz + 0.6, 0.5, 3.0, PAL.paintTop, PAL.paint)
            box(cx + 0.95, cx + 1.2, cz - 0.6, cz + 0.6, 0.5, 3.0, PAL.paintTop, PAL.paint)
        else
            frameBox(x0 + 0.2, x1 - 0.2, cz + 0.05, cz + 0.25, 0.75, 0.88)
            for i = 1, n do
                local xc = x0 + (i - 0.5) * W / n
                local r = math.min(kind == "tedder" and 0.75 or 1.7, W / n * 0.5 - 0.03)
                local rot = part(cz - r, 0.3 + yl)
                tf(rot, xc - r, xc + r, cz - 0.05, cz + 0.05, 0.3 + yl, wk)
                tf(rot, xc - 0.05, xc + 0.05, cz - r, cz + r, 0.3 + yl, wk)
                vf(rot, xc - r, xc + r, cz - r * 0.35, 0.02 + yl, 0.22 + yl, wkD)
                vf(rot, xc - 0.07, xc + 0.07, cz - r * 0.35 - 0.001, 0.22 + yl, 0.8 + yl, PAL.paintDk)
            end
        end
        if trailed or kind == "windrower" and W > 6.5 then
            frameBox(cx - 0.4, cx + 0.4, zb + 0.2, zf - 0.3, 0.5, 1.1)
        else
            headstock(zf)
        end
    elseif kind == "baler" then
        local ch = box(cx - 1.2, cx + 1.2, zb + 0.2, zf - 1.3, 0.55, 2.65, PAL.paintTop, PAL.paint)
        if not lite then
            vf(ch, cx - 1.0, cx + 1.0, zb + 0.199, 0.8, 2.42, PAL.paintDk)
            vf(ch, cx - 0.9, cx + 0.9, zb + 0.198, 0.9, 2.32, PAL.paint)
        end
        vf(ch, cx - 1.18, cx - 0.98, zb + 0.197, 0.62, 0.78, PAL.tail)
        vf(ch, cx + 0.98, cx + 1.18, zb + 0.197, 0.62, 0.78, PAL.tail)
        box(cx - 1.15, cx + 1.15, zf - 1.6, zf - 1.0, 0, 0.35, working and PAL.work or PAL.steelDk, PAL.frame)
        box(cx - 0.08, cx + 0.08, zf - 1.1, zf, 0.45, 0.6, PAL.steelDk, PAL.frame)
    elseif TRAILED[kind] then
        local bw = clamp((q.sw ~= nil and q.sw > 0.5) and q.sw or 2.55, 1.8, 3.0) * 0.5
        local top = kind == "forageWagon" and 3.6 or kind == "baleLoader" and 1.45 or kind == "mixer" and 2.8 or 2.7
        local b0, b1 = zb + 0.1, math.max(zb + 1.5, zf - 1.3)
        box(cx - bw + 0.3, cx + bw - 0.3, zb + 0.4, b1, 0.6, 1.0, PAL.chassisTop, PAL.chassis)
        local body = part(b0, top)
        hf(body, cx - bw, cx + bw, b0, b1, top, kind == "baleLoader" and PAL.paintTop or PAL.load)
        if kind ~= "baleLoader" then
            local fill = t.main ~= nil and clamp(t.main.frac or 0, 0, 1) or 0
            if fill > 0.04 then hf(body, cx - bw + 0.08, cx + bw - 0.08, b0 + 0.08, b1 - 0.08, top - 0.01, PAL.crop) end
            hf(body, cx - bw, cx + bw, b0, b0 + 0.08, top + 0.001, PAL.paintTop)
            hf(body, cx - bw, cx + bw, b1 - 0.08, b1, top + 0.001, PAL.paintTop)
            hf(body, cx - bw, cx - bw + 0.08, b0, b1, top + 0.001, PAL.paintTop)
            hf(body, cx + bw - 0.08, cx + bw, b0, b1, top + 0.001, PAL.paintTop)
        end
        vf(body, cx - bw, cx + bw, b0, 1.0, top, PAL.paint)
        vf(body, cx - bw, cx + bw, b0 - 0.001, 1.0, 1.12, PAL.paintDk)
        vf(body, cx - bw + 0.05, cx - bw + 0.28, b0 - 0.002, 1.04, 1.18, PAL.tail)
        vf(body, cx + bw - 0.28, cx + bw - 0.05, b0 - 0.002, 1.04, 1.18, PAL.tail)
        box(cx - 0.08, cx + 0.08, b1, zf, 0.45, 0.6, PAL.steelDk, PAL.frame)
    elseif kind == "header" then
        box(x0, x1, zb, zf, 0, 1.1, PAL.paintTop, PAL.paint)
        box(x0 + 0.2, x1 - 0.2, zb + 0.5, zb + 1.1, 1.1, 1.4, wk, wkD)
    else
        if not trailed then headstock(zf) end
        frameBox(x0, x1, zb, zf, 0.3, 0.9)
        local bar = part(zb - 0.01, 0.3 + yl)
        vf(bar, x0, x1, zb - 0.01, yl, 0.3 + yl, wkD)
    end

    -- roues de l'outil (vraies roues ; remorques sans roues lues : un tandem)
    if #wl > 0 then
        for _, w in ipairs(wl) do A.tyre(w.x, w.z, w.r, w.w) end
    elseif TRAILED[kind] and kind ~= "harvester" then
        local bw = clamp((q.sw ~= nil and q.sw > 0.5) and q.sw or 2.55, 1.8, 3.0) * 0.5
        local zw = kind == "baler" and cz or zb + math.min(2.2, L * 0.3)
        for sg = -1, 1, 2 do
            tyre(cx + sg * (bw - 0.2), zw - 0.6, 0.55, 0.45)
            if kind ~= "baler" then tyre(cx + sg * (bw - 0.2), zw + 0.6, 0.55, 0.45) end
        end
    end
end

-------------------------------------------------------------------------------
-- Page GPS
-------------------------------------------------------------------------------
local function fmtTime(sec)
    if sec == nil then return "-" end
    sec = math.max(0, sec)
    return string.format("%d:%02d", math.floor(sec / 3600), math.floor(sec % 3600 / 60))
end

-- flèche simple faite de carrés : pointe à gauche (left) ou à droite, centrée sur (u, vv)
local function chevron(ctx, u, vv, size, left, col)
    local cw = size * 0.25
    for j = 0, 3 do
        local h = size * (j + 1) / 4
        local uu = left and (u - size * 0.5 + j * cw) or (u + size * 0.5 - (j + 1) * cw)
        ctx.rect(uu, vv - h * 0.5, cw + 0.3, h, col)
    end
end

-- (03/11) signal RTK SIMULÉ (affichage seulement, le guidage ne change pas) :
-- stations RTK de Precision Farming (placeable type rtkStation : « Bâtiment / Abri avec station de base RTK ») de la
-- ferme du véhicule. Station à moins de fix m : RTK (vert, ± 2,5 cm, 5 barres) ; jusqu'à float m : FLOAT (orange,
-- ± 5 à 15 cm, 4 barres) ; plus loin ou sans station : GPS (orange, ± 30 cm, 3 barres).
-- (03/11) de 4 à 5 km : GPS jaune ; au-delà : ROUGE, 1 barre, DÉMARRER impossible depuis la tablette.
-- Sans aucune station : noStation = "pf" -> rouge seulement si Precision Farming est installé (sinon GPS jaune),
-- "red" -> toujours rouge, "gps" -> toujours jaune
G.RTK = { fix = 2000, float = 4000, gps = 5000, scanMs = 5000, noStation = "red" }   -- sans station : toujours rouge
local function pfLoaded()
    if g_modIsLoaded == nil then return false end
    for name, on in pairs(g_modIsLoaded) do
        if on == true and type(name) == "string" and name:lower():find("precisionfarming", 1, true) ~= nil then return true end
    end
    return false
end
local function isRtkStation(p)
    if type(p) ~= "table" then return false end
    local tn = type(p.typeName) == "string" and p.typeName:lower() or ""
    if tn:find("rtkstation", 1, true) ~= nil then return true end
    for k, val in pairs(p) do
        if type(k) == "string" and type(val) == "table" and k:sub(1, 5) == "spec_" and k:lower():find("rtkstation", 1, true) ~= nil then return true end
    end
    return false
end
function G:rtkStations(farmId)
    local now = g_time or 0
    local c = self.rtkCache
    if c ~= nil and c.farm == farmId and now >= c.t and now - c.t < self.RTK.scanMs then return c.list end
    local list = {}
    local ps = g_currentMission ~= nil and g_currentMission.placeableSystem or nil
    local all = ps ~= nil and (ps.placeables or ps.placeablesList) or nil
    if type(all) == "table" then
        for _, p in pairs(all) do
            local ok, yes = pcall(isRtkStation, p)
            if ok and yes and p.rootNode ~= nil then
                local owner = nil
                if p.getOwnerFarmId ~= nil then local okF, f = pcall(p.getOwnerFarmId, p); if okF then owner = f end end
                if farmId == nil or owner == nil or owner == farmId then
                    local okT, x, _, z = pcall(getWorldTranslation, p.rootNode)
                    if okT and x ~= nil then list[#list + 1] = { x = x, z = z } end
                end
            end
        end
    end
    self.rtkCache = { farm = farmId, t = now, list = list }
    return list
end
-- état du signal : "fix" / "float" / "gps" / "lost", précision (cm), barres allumées (sur 5), distance à la station (m ou nil)
function G:rtkSignal(v)
    local farmId
    if v ~= nil and v.getOwnerFarmId ~= nil then local ok, f = pcall(v.getOwnerFarmId, v); if ok then farmId = f end end
    local list = self:rtkStations(farmId)
    local best
    if v ~= nil and v.rootNode ~= nil and #list > 0 then
        local ok, x, _, z = pcall(getWorldTranslation, v.rootNode)
        if ok and x ~= nil then
            for _, st in ipairs(list) do
                local dd = math.sqrt((st.x - x) ^ 2 + (st.z - z) ^ 2)
                if best == nil or dd < best then best = dd end
            end
        end
    end
    local R = self.RTK
    if best ~= nil and best <= R.fix then return "fix", 2.5, 5, best end
    if best ~= nil and best <= R.float then return "float", 5 + 10 * (best - R.fix) / math.max(1, R.float - R.fix), 4, best end
    if best ~= nil and best <= (R.gps or R.float) then return "gps", 30, 3, best end
    if best == nil and (R.noStation == "gps" or (R.noStation ~= "red" and not pfLoaded())) then return "gps", 30, 3, nil end
    return "lost", nil, 1, best
end
-- (22:47) signal perdu (rouge) : la tablette refuse de démarrer le guidage
function G:rtkLost(v)
    local ok, sig = pcall(self.rtkSignal, self, v)
    return ok and sig == "lost"
end
local function decSep()
    local dec = ","
    if g_i18n ~= nil and g_i18n.getText ~= nil then
        local ok, t = pcall(g_i18n.getText, g_i18n, "vtpas_decimal")
        if ok and type(t) == "string" and #t == 1 then dec = t end
    end
    return dec
end
local function precTxt(cm)
    local s = cm >= 10 and string.format("%d cm", math.floor(cm + 0.5)) or string.format("%.1f cm", cm)
    return (s:gsub("%.", decSep()))
end
-- (04/11) distance d'une antenne RTK : km (ou miles selon les réglages du joueur), m en dessous de 1 km
function G.distTxt(m)
    local u = AS_Terminal ~= nil and AS_Terminal.unitsOf ~= nil and AS_Terminal.unitsOf() or nil
    local s
    if u ~= nil and u.imperial then
        local mi = m / 1609.344
        s = mi >= 0.1 and string.format("%.1f mi", mi) or string.format("%d ft", math.floor(m * 3.2808 + 0.5))
    else
        s = m >= 1000 and string.format("%.1f km", m / 1000) or string.format("%d m", math.floor(m / 10 + 0.5) * 10)
    end
    return (s:gsub("%.", decSep()))
end
-- couleur du signal que donnerait une antenne à cette distance (vert RTK, orange FLOAT, jaune GPS, rouge au-delà)
function G.rtkColor(m)
    local R = G.RTK
    if m <= R.fix then return { 0.35, 0.95, 0.40, 1 } end
    if m <= R.float then return { 1.00, 0.55, 0.12, 1 } end
    if m <= (R.gps or R.float) then return { 1.00, 0.86, 0.15, 1 } end
    return { 1.00, 0.32, 0.26, 1 }
end

function G:draw(AS_T, d, ctx, v)
    local ui = U()
    local C = ui.C
    local g = d.gps or {}
    if self.sub == "course" then return self:drawCourse(AS_T, d, ctx, v) end
    local st = AS_T:brandStyle(v)
    local accent = st ~= nil and st.acc or nil
    if accent ~= nil and accent[1] > 0.9 and accent[2] > 0.9 and accent[3] < 0.2 then accent = { 0.98, 0.85, 0.10, 1 } end
    local box = { x = ctx.cx + 2, y = ctx.cy + 2, w = ctx.cw - 4, h = ctx.ch - 4 }
    local now = g_time or 0
    -- (70k) une vue gardée pour la grande fenêtre et une pour l'écran 3D (affichés ensemble, ils se forçaient
    -- à tout recalculer à chaque image) ; drawCache = nil efface toujours les deux
    local lite = ctx.rec ~= nil
    local dcs = self.drawCache
    if type(dcs) ~= "table" or dcs.pair ~= true then dcs = { pair = true }; self.drawCache = dcs end
    local dc = dcs[lite]
    if dc == nil or dc.v ~= v or dc.view ~= self.view or dc.zoom ~= self.zoom or dc.bw ~= box.w or dc.lite ~= lite or now - dc.t >= self.CACHE_MS or now < dc.t then
        local ok, list = pcall(self.buildView, self, v, d, box, accent, lite)
        if not ok then logOnce("view", "ERREUR vue : %s", tostring(list)); list = {} end
        dc = { v = v, view = self.view, zoom = self.zoom, bw = box.w, lite = lite, t = now, list = list }
        dcs[lite] = dc
    end
    local n0 = ctx.rec ~= nil and #ctx.rec.rects or 0
    for _, r in ipairs(dc.list) do ctx.rect(r[1], r[2], r[3], r[4], r[5]) end
    -- (01/11) écran 3D : s'il y a trop de carrés, ceux de la vue partent avant les boutons
    if ctx.rec ~= nil then
        local rr = ctx.rec.rects
        for i = n0 + 1, #rr do rr[i].low = true end
    end
    -- (04/11) MF Guide du Massey : la carte seule, barre de guidage et touches = celles de son écran
    if ctx.mapOnly then return true end

    -- barre de guidage (haut) : système, LED, écart, rang, RTK
    local bx, by, bw = box.x + 4, box.y + 4, box.w - 8
    -- (03/11, en haut et en bas) le thème clair du Case rend C.white NOIR :
    -- sur les bandeaux noirs on écrit en vrai blanc / gris clair, quel que soit le thème
    local WH, GR, DM = { 1, 1, 1, 1 }, { 0.92, 0.94, 0.96, 1 }, { 0.62, 0.66, 0.70, 1 }
    local GN, AM, RD = { 0.35, 0.95, 0.40, 1 }, { 1, 0.78, 0.15, 1 }, { 1, 0.32, 0.26, 1 }   -- vert / orange / rouge vifs (lisibles sur noir)
    ctx.rect(bx, by, bw, 44, { 0, 0, 0, 1 }, 0.88)   -- (03/11) fond bien noir
    local steerCol = g.steer == "on" and GN or (g.steer == "ready" and WH or DM)
    -- (03/11) carte Case : compas et bouton vue sont posés sur la gauche du bandeau ;
    -- système, état et rang descendent SOUS le bandeau noir, sur une ligne, à droite de ces boutons
    local below = ctx.gpsTextsX ~= nil
    if not below then ctx.rect(bx + 6, by + 8, 10, 10, steerCol) end
    -- LED : 17 cases de 4 cm, allumées du côté où il faut braquer
    local nL, lw, gap = 8, 13, 3
    local cxL = bx + bw * 0.5
    -- (01/11) partie gauche de la barre : système (ligne 1), état et rang (ligne 2), sans chevauchement
    local leftW = (cxL - nL * (lw + gap) - 14) - (bx + 6)
    local stTxt = T("gps_st_" .. (g.steer or "none"))
    if not below then
        ctx.text(bx + 22, by + 17, 12, g.system or "GPS", WH, nil, true, leftW - 16)
        ctx.text(bx + 6, by + 35, 11, stTxt, g.steer == "on" and GN or GR, nil, true, leftW * 0.42)
    end
    local ledY = by + 6
    local lit = 0
    local xte = g.xte
    if g.onLine and xte ~= nil and not g.inTurn then lit = math.min(nL, math.floor(math.abs(xte) * 100 / self.LED_CM)) end
    local steerLeft = xte ~= nil and xte > 0
    for k = -nL, nL do
        local u = cxL + k * (lw + gap) - lw * 0.5
        local col = DM
        local a = math.abs(k)
        if g.onLine and not g.inTurn then
            if k == 0 then col = (lit <= 1) and GN or { 0.20, 0.35, 0.22, 1 }
            elseif (k < 0) == steerLeft and a <= lit then col = a <= 2 and GN or (a <= 5 and AM or RD) end
        end
        ctx.rect(u, ledY, lw, 12, col)
    end
    -- écart en cm (ou état) sous les LED
    local mid
    if not g.hasCp then mid = (U().cpInstalled == nil or U().cpInstalled()) and T("gps_noCp") or "--"
    elseif g.data == nil then mid = T("gps_noCourse")
    elseif g.inTurn then mid = T("gps_turning")
    elseif not g.onLine then mid = T("gps_noLine")
    elseif math.abs(xte) >= 1 then mid = string.format("%.1f m", math.abs(xte))
    else mid = string.format("%d cm", math.floor(math.abs(xte) * 100 + 0.5)) end
    local midCol = (g.onLine and not g.inTurn) and (lit <= 1 and GN or (lit <= 5 and AM or RD)) or WH
    ctx.text(cxL, by + 38, 15, mid, midCol, RenderText.ALIGN_CENTER, true, math.max(60, 2 * (bx + bw - 120 - cxL)))
    if g.onLine and not g.inTurn and lit > 1 then
        chevron(ctx, cxL + (steerLeft and -48 or 48), by + 32, 12, steerLeft, midCol)
    end
    -- rang / tournière à gauche des LED
    local rowTxt = "-"
    if g.row ~= nil then rowTxt = string.format(T("gps_row"), g.row, g.rows or g.row)
    elseif g.hl ~= nil then rowTxt = string.format(T("gps_hl"), g.hl) end
    if not below then
        ctx.text(cxL - nL * (lw + gap) - 14, by + 35, 12, rowTxt, WH, RenderText.ALIGN_RIGHT, true, leftW * 0.54)
    else
        -- ligne sous le bandeau : [■] système   état   rang, sur un fond noir juste à leur taille
        local sys = g.system or "GPS"
        local function mw(sz, t) return ctx.measure ~= nil and ctx.measure(sz, t) or #t * sz * 0.6 end
        local wSys, wSt, wRow = mw(12, sys), mw(12, stTxt), mw(12, rowTxt)
        local x0, y0, pad, sp = ctx.gpsTextsX, by + 46, 8, 18
        local wAll = pad + 14 + wSys + sp + wSt + sp + wRow + pad
        wAll = math.min(wAll, bx + bw - x0)
        ctx.rect(x0, y0, wAll, 24, { 0, 0, 0, 1 }, 0.88)
        ctx.rect(x0 + pad, y0 + 7, 10, 10, steerCol)
        local tx = x0 + pad + 14
        ctx.text(tx, y0 + 17, 12, sys, WH, nil, true); tx = tx + wSys + sp
        ctx.text(tx, y0 + 17, 12, stTxt, g.steer == "on" and GN or GR, nil, true); tx = tx + wSt + sp
        ctx.text(tx, y0 + 17, 12, rowTxt, WH, nil, true)
    end
    -- RTK à droite (affiché comme sur un vrai terminal)
    -- (03/11) satellites : oscillent lentement entre 15 et 22
    local sats = math.max(15, math.min(22, math.floor(18.5 + 2.5 * math.sin(now / 97000) + 1.0 * math.sin(now / 23000) + 0.5)))
    local rx = bx + bw - 6
    local okR, sig, prec, bars = pcall(self.rtkSignal, self, v)
    if not okR then sig, prec, bars = "gps", 30, 3 end
    local sigCol = sig == "fix" and GN or (sig == "lost" and RD or AM)
    local lab = (sig == "fix" or sig == "lost") and "RTK" or (sig == "float" and "FLOAT" or "GPS")
    local labW = 34
    if ctx.measure ~= nil then labW = math.max(34, ctx.measure(11, lab) + 10) end
    ctx.rect(rx - labW, by + 6, labW, 15, sigCol)
    ctx.text(rx - labW * 0.5, by + 18, 11, lab, { 0, 0, 0, 1 }, RenderText.ALIGN_CENTER, true)
    for k = 1, 5 do ctx.rect(rx - labW - 6 - (6 - k) * 6, by + 21 - k * 3, 4, k * 3, k <= bars and sigCol or DM) end
    if sig == "lost" then ctx.text(rx, by + 37, 10, T("gps_noRtk"), RD, RenderText.ALIGN_RIGHT, true, 150)
    else ctx.text(rx, by + 37, 10, string.format(T("gps_sat"), sats, precTxt(prec)), GR, RenderText.ALIGN_RIGHT, nil, 104) end

    -- bandeau du bas : demi-tour, avancement, reste, temps
    local fy = box.y + box.h - 30
    ctx.rect(bx, fy, bw, 26, { 0, 0, 0, 1 }, 0.88)   -- (03/11) fond bien noir sous le texte blanc
    local turnTxt
    if g.inTurn then turnTxt = T("gps_turning")
    elseif g.toTurn ~= nil then turnTxt = string.format(T("gps_toTurn"), math.floor(g.toTurn + 0.5))
    elseif g.data ~= nil then turnTxt = T("gps_end") else turnTxt = "-" end
    local near = g.toTurn ~= nil and g.toTurn < 20
    if g.turnLeft ~= nil and g.toTurn ~= nil then chevron(ctx, bx + 14, fy + 13, 12, g.turnLeft, near and AM or WH) end
    -- (01/11) trois zones : demi-tour (gauche), fait / reste (milieu), temps (droite), chacune tient dans sa part
    ctx.text(bx + 28, fy + 18, 12, turnTxt, near and AM or WH, nil, true, bw * 0.33 - 30)
    if g.progress ~= nil then
        local leftHa = d.fieldHa ~= nil and d.fieldHa * (1 - g.progress) or nil
        ctx.text(bx + bw * 0.505, fy + 18, 12, string.format(T("gps_done"), math.floor(g.progress * 100 + 0.5),
            leftHa ~= nil and string.format("%.2f ha", leftHa) or "-"), WH, RenderText.ALIGN_CENTER, true, bw * 0.33)
        local tTxt = g.timeText or (g.timeS ~= nil and fmtTime(g.timeS) or "-")
        ctx.text(bx + bw - 8, fy + 18, 12, string.format(T("gps_time"), tTxt), WH, RenderText.ALIGN_RIGHT, true, bw * 0.31 - 8)
    elseif g.hasCp and g.data == nil then
        ctx.text(bx + bw * 0.6, fy + 18, 12, T("gps_create"), AM, RenderText.ALIGN_CENTER, true, bw * 0.78)
    end
    -- échelle / vue
    ctx.text(box.x + box.w - 10, fy - 6, 10, self.view == "top" and string.format("%d m", self.TOP[self.zoom] * 2) or T("gps_v_persp"), GR, RenderText.ALIGN_RIGHT)
    -- (01/11) pas de parcours : les parcours enregistrés pour ce champ (et les champs liés), un clic charge
    if g.hasCp and g.data == nil and AS_TerminalCourses ~= nil then
        pcall(AS_TerminalCourses.auto, AS_TerminalCourses, v, d)
        local px, py = box.x + 16, by + 52
        local pw, ph = box.w - 32, fy - 8 - py
        if ph > 60 then
            ctx.rect(px, py, pw, ph, C.screen, 0.9)
            local okL, err = pcall(AS_TerminalCourses.drawList, AS_TerminalCourses, v, ctx, nil,
                { x = px + 6, y = py + 2, w = pw - 12, h = ph - 6 }, 6)
            if not okL then logOnce("listG", "ERREUR liste parcours (GUIDAGE) : %s", tostring(err)) end
        end
    end

    -- (02/11 soir) écran CARTE Case : la carte seule, les touches sont celles de l'image
    if ctx.noKeys then return true end
    -- touches de droite
    local sb = ui.sideButton
    sb(ctx, 1, "gps_steer", g.system or "GPS", g.steer == "on", T("gps_st_" .. (g.steer or "none")))
    -- décaler : deux demi-touches
    local kx, ky = ctx.rx + 6, ctx.cy + 22 + 46
    local offTxt = fmtOff(g.offset)
    ctx.button(kx, ky, 62, 40, "gps_shiftL")
    chevron(ctx, kx + 24, ky + 15, 12, true, g.offsetDisabled and C.dim or C.white)
    ctx.button(kx + 66, ky, 62, 40, "gps_shiftR")
    chevron(ctx, kx + 104, ky + 15, 12, false, g.offsetDisabled and C.dim or C.white)
    ctx.text(kx + 64, ky + 35, 10, T("gps_shift") .. " " .. offTxt, C.gray, RenderText.ALIGN_CENTER, nil, 124)
    sb(ctx, 3, "gps_view", T("gps_view"), false, T(self.view == "top" and "gps_v_top" or "gps_v_persp"))
    ky = ctx.cy + 22 + 3 * 46
    ctx.button(kx, ky, 62, 40, "gps_zoomOut")
    ctx.text(kx + 31, ky + 27, 16, "-", C.white, RenderText.ALIGN_CENTER, true)
    ctx.button(kx + 66, ky, 62, 40, "gps_zoomIn")
    ctx.text(kx + 97, ky + 27, 16, "+", C.white, RenderText.ALIGN_CENTER, true)
    ctx.text(kx + 64, ky + 12, 9, T("gps_zoom"), C.gray, RenderText.ALIGN_CENTER)
    sb(ctx, 5, "gps_course", T("gps_course"), self.sub == "course", g.data ~= nil and string.format(T("gps_rows"), g.rows or 0) or T("none"))
    sb(ctx, 6, "cp_menu", T("cpMenu"), false)
    return true
end

-- sous-page PARCOURS : réglages Courseplay, voie, décalage, enregistrement du bord du champ
function G:drawCourse(AS_T, d, ctx, v)
    local ui = U()
    local C = ui.C
    local g = d.gps or {}
    local u, w = ctx.cx + 10, ctx.cw - 20
    if not g.hasCp then
        if ui.cpInstalled == nil or ui.cpInstalled() then ctx.text(u + 8, ctx.cy + 30, 15, T("cpMissing"), C.dim, nil, true) end
        ui.sideButton(ctx, 7, "gps_back", T("gps_back"), false)
        return true
    end
    local function str(stt)
        if stt == nil or stt.getString == nil then return "-" end
        local ok, r = pcall(stt.getString, stt)
        return ok and tostring(r) or "-"
    end
    local cs = call(v, "getCourseGeneratorSettings")
    local lane = call(v, "getCpLaneOffsetSetting")
    local laneOk = lane ~= nil and call(lane, "getIsVisible") ~= false
    local state
    if g.active then state = T("cpActive")
    elseif g.data == nil then state = T("cpNoCourse")
    elseif g.canStart then state = T("cpReady")
    else state = T("cpNotReady") end
    local items = {
        { T("cpState"), state, g.active and C.lamp or (g.data ~= nil and C.white or C.amber) },
        { T("cpCourse"), g.data ~= nil and string.format(T("gps_courseInfo"), g.rows or 0, g.nHl or 0, g.data.length / 1000) or T("none") },
        { T("cpStart"), str(call(v, "getCpStartingPointSetting")), nil, nil, "cp_start" },
        { T("cpWidth"), cs ~= nil and str(cs.workWidth) or "-", nil, "cp_w-", "cp_w+" },
        { T("cpHeadlands"), cs ~= nil and str(cs.numberOfHeadlands) or "-", nil, "cp_h-", "cp_h+" },
        { T("gps_offset"), fmtOff(g.offset), g.offsetDisabled and C.dim or nil, "gps_shiftL", "gps_shiftR", zero = "gps_off0" },
    }
    if laneOk then items[#items + 1] = { T("gps_lane"), str(lane), nil, nil, "gps_lane" } end
    items[#items + 1] = { T("gps_rec"), g.recording and (g.recPaused and T("gps_recPaused") or T("gps_recOn")) or T("off"),
        g.recording and C.red or nil, g.recording and "gps_recPause" or nil, "gps_rec",
        labels = { g.recording and (g.recPaused and T("gps_recGo") or T("gps_recPause")) or nil, g.recording and T("gps_recStop") or T("gps_recStart") } }
    -- (01/11) lignes plus serrées (place pour la liste) ; chaque texte tient dans sa part de la ligne
    local RH = 30
    for i, it in ipairs(items) do
        local yy = ctx.cy + 8 + (i - 1) * RH
        ctx.rect(u, yy, w, RH - 3, C.box)
        ctx.text(u + 8, yy + 19, 13, it[1], C.white, nil, nil, w * 0.36)
        local hasBtn = it[4] ~= nil or it[5] ~= nil
        local off = hasBtn and (it.labels ~= nil and (it[4] ~= nil and 214 or 110) or (it.zero and 150 or 110)) or 8
        ctx.text(u + w - off, yy + 19, 13, it[2], it[3] or C.lamp, RenderText.ALIGN_RIGHT, true, w * 0.62 - off - 12)
        if it.labels ~= nil then
            if it[4] ~= nil then
                ctx.button(u + w - 206, yy + 3, 96, 21, it[4])
                ctx.text(u + w - 158, yy + 18, 11, it.labels[1], C.white, RenderText.ALIGN_CENTER, true, 90)
            end
            ctx.button(u + w - 102, yy + 3, 94, 21, it[5], g.recording)
            ctx.text(u + w - 55, yy + 18, 11, it.labels[2], C.white, RenderText.ALIGN_CENTER, true, 88)
        elseif it[4] ~= nil then
            if it.zero ~= nil then
                ctx.button(u + w - 144, yy + 3, 38, 21, it.zero)
                ctx.text(u + w - 125, yy + 18, 12, "0", C.white, RenderText.ALIGN_CENTER, true)
            end
            ctx.button(u + w - 102, yy + 3, 40, 21, it[4])
            ctx.text(u + w - 82, yy + 18, 13, "-", C.white, RenderText.ALIGN_CENTER, true)
            ctx.button(u + w - 56, yy + 3, 48, 21, it[5])
            ctx.text(u + w - 32, yy + 18, 13, "+", C.white, RenderText.ALIGN_CENTER, true)
        elseif it[5] ~= nil then
            ctx.button(u + w - 102, yy + 3, 94, 21, it[5])
            ctx.text(u + w - 55, yy + 18, 11, T("change"), C.white, RenderText.ALIGN_CENTER, true, 88)
        end
    end
    -- parcours enregistrés qui vont avec ce champ et cet outil (CHERCHER)
    if AS_TerminalCourses ~= nil then
        local ok, err = pcall(AS_TerminalCourses.drawList, AS_TerminalCourses, v, ctx, ctx.cy + 8 + #items * RH)
        if not ok then logOnce("list", "ERREUR liste parcours : %s", tostring(err)) end
    end
    local sb = ui.sideButton
    sb(ctx, 1, "cp_generate", T("cpGenerate"), false)
    sb(ctx, 2, "cp_clear", T("cpClear"), false)
    sb(ctx, 3, "cp_find", T("cpFind"), false)
    sb(ctx, 4, "cp_menu", T("cpMenu"), false)
    if ui.hasAd ~= nil and ui.hasAd(v) then sb(ctx, 5, "adStartStop", T("adStartStop"), d.guide == "AD", d.guide == "AD" and T("on") or T("off")) end
    sb(ctx, 7, "gps_back", T("gps_back"), false)
    return true
end

-------------------------------------------------------------------------------
-- Commandes
-------------------------------------------------------------------------------
function G:action(AS_T, v, a)
    local ui = U()
    local d = AS_T.data
    local g = d ~= nil and d.gps or {}
    if a == "gps_steer" then
        if not ui.hasCp(v) then ui.warn(T("cpMissing")) return end
        if not g.active and self:rtkLost(v) then   -- pas de signal RTK : démarrage impossible
            ui.warn(T("gps_noRtkStart")); log("démarrage refusé : pas de signal RTK")
            return
        end
        if g.active or g.canStart then
            AS_T:cmdCp(v, "startStop")
            log("direction %s (%s)", g.active and "désengagée" or "engagée", tostring(g.system))
        elseif g.data == nil then ui.warn(T("gps_noCourse"))
        else ui.warn(T("cpNotReady")) end
    elseif a == "gps_shiftL" or a == "gps_shiftR" or a == "gps_off0" then
        local st = toolOffsetSetting(v)
        if st == nil or call(st, "getIsDisabled") == true then ui.warn(T("gps_noShift")) return end
        if a == "gps_off0" then
            if st.setFloatValue ~= nil then pcall(st.setFloatValue, st, 0) end
        else
            local fn = a == "gps_shiftR" and st.setNextItem or st.setPreviousItem
            if fn ~= nil then pcall(fn, st) end
        end
        log("décalage outil : %s m", tostring(settingValue(st)))
        self.drawCache = nil
    elseif a == "gps_view" then
        self.view = self.view == "persp" and "top" or "persp"
        self.drawCache = nil
    elseif a == "gps_zoomIn" or a == "gps_zoomOut" then
        local n = self.view == "top" and #self.TOP or #self.PERSP
        -- zoom avant = caméra plus proche (perspective) ou moins de mètres (dessus)
        self.zoom = clamp(self.zoom + (a == "gps_zoomIn" and -1 or 1), 1, n)
        self.drawCache = nil
    elseif a == "gps_course" then self.sub = "course"
    elseif a == "gps_back" then self.sub = nil
    elseif a == "gps_lane" then
        local lane = call(v, "getCpLaneOffsetSetting")
        if lane ~= nil and lane.setNextItem ~= nil then pcall(lane.setNextItem, lane) end
    elseif a == "gps_rec" then
        if call(v, "getIsCpCourseRecorderActive") == true then
            local ok, err = pcall(v.cpStopCourseRecorder, v)
            log("enregistrement du bord : arrêté (%s)", ok and "ok" or tostring(err))
        elseif call(v, "getCanStartCpCourseRecorder") == true then
            local ok, err = pcall(v.cpStartCourseRecorder, v)
            log("enregistrement du bord : démarré (%s)", ok and "ok" or tostring(err))
        else
            ui.warn(T("gps_recNo"))
        end
    elseif a == "gps_recPause" then
        if v.toggleCpCourseRecorderPause ~= nil then pcall(v.toggleCpCourseRecorderPause, v) end
    end
    AS_T.lastRead = -100000
end
