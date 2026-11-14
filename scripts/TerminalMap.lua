-- AutoSwitch : carte du terminal (page Travail) : couverture, recouvrement, lignes de guidage
-- Fichier chargé par AutoSwitch.lua (après Terminal.lua).

local L = AS.L

-------------------------------------------------------------------------------
-- v1.0.4.0 (étape 2) : carte de la page Travail, vue de dessus nord en haut.
--   Couverture : chaque outil au travail (baissé et en marche) marque les cases de 2 m
--   balayées entre ses marqueurs gauche et droit de l'IA. Une case déjà travaillée
--   repassée plus de 8 m plus loin = recouvrement (rouge). Une carte par véhicule et
--   par travail (1 / 2), gardée avec la partie (savegameX/autoSwitchTerminalMap.xml).
--   Lignes : parcours Courseplay du véhicule (getFieldWorkCourse), sinon le parcours de
--   l'aide à la direction ou de l'ouvrier IA du jeu. Rien n'est calculé par AutoSwitch.
--   Fond : image de la carte du jeu (option), bordure du champ (points du polygone).
-------------------------------------------------------------------------------
local renderOverlay = (AS ~= nil and AS.renderOverlay) or renderOverlay   -- (perf 07/11) voir Common.lua
AS_TerminalMap = {}
AS_TerminalMap.CELL = 2                  -- taille d'une case de couverture (m)
AS_TerminalMap.OVERLAP_DIST = 8          -- repassage plus loin que ça = recouvrement (m)
AS_TerminalMap.MAX_CELLS = 400000        -- par carte (≈ 160 ha), au-delà on n'ajoute plus
AS_TerminalMap.UPDATE_MS = 250
AS_TerminalMap.CACHE_MS = 250            -- dessin recalculé 4 fois par seconde
AS_TerminalMap.ZOOMS = { 25, 50, 100, 200, 400 }   -- demi-largeur de la vue (m)
AS_TerminalMap.SAVE_NAME = "autoSwitchTerminalMap.xml"

AS_TerminalMap.maps = {}                 -- [clé véhicule] = { dist, prev = {}, jobs = { carte1, carte2 } }
AS_TerminalMap.zoom = 2
AS_TerminalMap.mapImage = true
AS_TerminalMap.timer = 0
AS_TerminalMap.cache = nil
AS_TerminalMap.logged = {}

local function log(fmt, ...)
    (AS.rawPrint or print)("[AS_TerminalMap] " .. string.format(fmt, ...))
end
local function logOnce(key, fmt, ...)
    if AS_TerminalMap.logged[key] then return end
    AS_TerminalMap.logged[key] = true
    log(fmt, ...)
end

local function T(key) return L("vtpas_tm_" .. key) end

local function call(obj, name, ...)
    if obj == nil or type(obj[name]) ~= "function" then return nil end
    local ok, a, b, c, d = pcall(obj[name], obj, ...)
    if ok then return a, b, c, d end
    return nil
end

local function clamp(v, a, b) return math.max(a, math.min(b, v)) end

local function newMap() return { cells = {}, n = 0, ov = {}, nov = 0, part = {}, opart = {} } end

local function cellKey(cx, cz) return (cx + 32768) * 65536 + (cz + 32768) end

local function vehKey(v) return v.uniqueId or v end

-------------------------------------------------------------------------------
-- Enregistrement de la couverture
-------------------------------------------------------------------------------
function AS_TerminalMap:get(v)
    local k = vehKey(v)
    local m = self.maps[k]
    if m == nil then
        m = { dist = 0, prev = {}, jobs = { newMap(), newMap() } }
        self.maps[k] = m
    end
    return m
end

function AS_TerminalMap:current(v)
    local m = self:get(v)
    local cnt = AS_Terminal ~= nil and AS_Terminal:getCounter(v) or nil
    return m.jobs[cnt ~= nil and cnt.active or 1], m
end

local function isWorking(obj)
    -- (04/11) même règle que le terminal : baissé, en marche, et zones de travail du jeu actives (contact au sol)
    local ui = AS_Terminal ~= nil and AS_Terminal.ui or nil
    if ui ~= nil and ui.isWorking ~= nil then return ui.isWorking(obj) == true end
    local low = obj.getIsLowered ~= nil and call(obj, "getIsLowered", false) or nil
    local on = obj.getIsTurnedOn ~= nil and call(obj, "getIsTurnedOn") or nil
    if low == nil and on == nil then return false end
    return low ~= false and on ~= false
end

local function markers(obj)
    if obj.getAIMarkers == nil then return nil end
    local l, r = call(obj, "getAIMarkers")
    if l == nil or r == nil or l == 0 or r == 0 then return nil end
    local lx, _, lz = getWorldTranslation(l)
    local rx, _, rz = getWorldTranslation(r)
    if (lx - rx) ^ 2 + (lz - rz) ^ 2 < 0.25 then return nil end
    return lx, lz, rx, rz
end

-- case dont le centre est sous l'outil : couverte ; déjà couverte plus de 8 m avant : recouvrement
function AS_TerminalMap:markKey(map, k, dist)
    local s = map.cells[k]
    if s == nil then
        if map.n >= self.MAX_CELLS then return end
        map.cells[k] = dist
        map.n = map.n + 1
    elseif not map.ov[k] and dist - s > self.OVERLAP_DIST then
        map.ov[k] = true
        map.nov = map.nov + 1
    end
end

local function inTriangle(px, pz, ax, az, bx, bz, cx, cz)
    local d1 = (px - bx) * (az - bz) - (ax - bx) * (pz - bz)
    local d2 = (px - cx) * (bz - cz) - (bx - cx) * (pz - cz)
    local d3 = (px - ax) * (cz - az) - (cx - ax) * (pz - az)
    local neg = d1 < 0 or d2 < 0 or d3 < 0
    local pos = d1 > 0 or d2 > 0 or d3 > 0
    return not (neg and pos)
end

-- surface balayée par la ligne gauche -> droite de l'outil entre deux relevés :
-- les cases dont le centre est dans ce quadrilatère sont marquées (bords exacts, pas de
-- faux recouvrement entre deux passes jointives)
-- (01/11) chaque case de 2 m est découpée en 4 x 4 petites cases de 50 cm (un bit chacune) :
-- part[k] = petites cases travaillées d'une case pas entièrement faite (absent = case pleine si cells[k],
-- vide sinon) ; opart[k] = petites cases repassées (absent = ov[k] : toute la case, ou rien).
-- vis / visD : petites cases touchées pendant le passage en cours (moins de 8 m roulés), pour ne pas compter
-- comme repassage ce que l'outil vient de faire. Surface et recouvrement en ha : toujours d'après le centre.
AS_TerminalMap.SUB = 4
local SUB = 4
local FULL = 65535
local P2 = {}
for i = 0, 15 do P2[i] = 2 ^ i end
AS_TerminalMap.P2 = P2

function AS_TerminalMap:sweep(map, p, lx, lz, rx, rz, dist)
    local move = math.sqrt(((lx + rx) - (p[1] + p[3])) ^ 2 + ((lz + rz) - (p[2] + p[4])) ^ 2) * 0.5
    if move > 30 or move < 0.01 then return end          -- saut (téléportation) ou arrêt
    local c = self.CELL
    local sc = c / SUB
    local minX = math.min(p[1], p[3], lx, rx)
    local maxX = math.max(p[1], p[3], lx, rx)
    local minZ = math.min(p[2], p[4], lz, rz)
    local maxZ = math.max(p[2], p[4], lz, rz)
    if map.part == nil then map.part, map.opart = {}, {} end
    -- passage en cours : deux tables qui tournent tous les 8 m roulés
    if map.vis == nil or dist - map.visAt > self.OVERLAP_DIST or dist < map.visAt then
        map.visOld, map.visDOld = map.vis or {}, map.visD or {}
        map.vis, map.visD, map.visAt = {}, {}, dist
    end
    local cells, part, opart, ovs = map.cells, map.part, map.opart, map.ov
    local vis, visD, visO, visDO = map.vis, map.visD, map.visOld, map.visDOld
    local OD = self.OVERLAP_DIST
    local ax, az, bx, bz = p[1], p[2], p[3], p[4]
    for cx = math.floor(minX / c), math.floor(maxX / c) do
        local x0 = cx * c
        for cz = math.floor(minZ / c), math.floor(maxZ / c) do
            local z0 = cz * c
            local k = cellKey(cx, cz)
            local old, vm, ov0, nOld, nVis, nOv
            for j = 0, SUB - 1 do
                local z = z0 + (j + 0.5) * sc
                if z >= minZ and z <= maxZ then
                    for i = 0, SUB - 1 do
                        local x = x0 + (i + 0.5) * sc
                        if x >= minX and x <= maxX
                            and (inTriangle(x, z, ax, az, bx, bz, rx, rz) or inTriangle(x, z, ax, az, rx, rz, lx, lz)) then
                            if old == nil then
                                old = part[k] or (cells[k] ~= nil and FULL or 0)
                                local d = visD[k]
                                vm = vis[k]
                                if vm == nil then vm, d = visO[k], visDO[k] end
                                if vm == nil or dist - d > OD then vm = 0 end
                                ov0 = opart[k] or (ovs[k] and FULL or 0)
                                nOld, nVis, nOv = old, vm, ov0
                            end
                            local b = P2[j * SUB + i]
                            local b2 = b + b
                            if old % b2 < b then
                                nOld = nOld + b                       -- nouvelle petite case travaillée
                            elseif vm % b2 < b and ov0 % b2 < b then
                                nOv = nOv + b                         -- faite avant ce passage : repassée
                            end
                            if vm % b2 < b then nVis = nVis + b end
                        end
                    end
                end
            end
            if old ~= nil then
                vis[k], visD[k] = nVis, dist
                map.ver = (map.ver or 0) + 1
                -- rectangle englobant (cases), pour ne lire que là où il y a quelque chose
                if map.bx0 == nil then map.bx0, map.bx1, map.bz0, map.bz1 = cx, cx, cz, cz
                else
                    if cx < map.bx0 then map.bx0 = cx elseif cx > map.bx1 then map.bx1 = cx end
                    if cz < map.bz0 then map.bz0 = cz elseif cz > map.bz1 then map.bz1 = cz end
                end
                -- centre de la case sous l'outil : couverte (surface, recouvrement) comme avant
                local xc, zc = x0 + c * 0.5, z0 + c * 0.5
                if inTriangle(xc, zc, ax, az, bx, bz, rx, rz) or inTriangle(xc, zc, ax, az, rx, rz, lx, lz) then
                    self:markKey(map, k, dist)
                end
                if nOld ~= old or part[k] ~= nil then
                    if nOld == FULL and cells[k] ~= nil then part[k] = nil else part[k] = nOld end
                end
                if ovs[k] then
                    if nOv == FULL then opart[k] = nil else opart[k] = nOv end
                elseif nOv > 0 then
                    opart[k] = nOv
                end
            end
        end
    end
end

function AS_TerminalMap:updateVehicle(v, dtMs)
    local m = self:get(v)
    local speed = call(v, "getLastSpeed") or 0
    m.dist = m.dist + speed / 3.6 * dtMs / 1000
    local map = nil
    local ch = call(v, "getChildVehicles")
    local list = { v }
    if type(ch) == "table" then for _, o in pairs(ch) do if o ~= v then list[#list + 1] = o end end end
    local seen = {}
    for _, o in ipairs(list) do
        if type(o) == "table" and not seen[o] then
            seen[o] = true
            local lx, lz, rx, rz
            if isWorking(o) then lx, lz, rx, rz = markers(o) end
            -- (04/11) tronçons coupés (Section Control ou touches du jeu) : seule la largeur allumée est marquée
            if lx ~= nil and o.spec_variableWorkWidth ~= nil and AS_SectionControl ~= nil and AS_SectionControl.activeLine ~= nil then
                local okA, a1, a2, a3, a4 = pcall(AS_SectionControl.activeLine, AS_SectionControl, o, lx, lz, rx, rz)
                if okA and a1 ~= nil then lx, lz, rx, rz = a1, a2, a3, a4 end
            end
            if lx ~= nil then
                map = map or self:current(v)
                local p = m.prev[o]
                if p ~= nil then self:sweep(map, p, lx, lz, rx, rz, m.dist) end
                m.prev[o] = { lx, lz, rx, rz }
            else
                m.prev[o] = nil
            end
        end
    end
end

function AS_TerminalMap:update(dt)
    if AS_Terminal == nil or not AS_Terminal.ENABLED or g_currentMission == nil then return end
    self.timer = self.timer + (dt or 0)
    if self.timer < self.UPDATE_MS then return end
    local dtMs = self.timer
    self.timer = 0
    local vehicles = AS.getVehicles ~= nil and AS.getVehicles() or {}
    for _, v in pairs(vehicles) do
        if type(v) == "table" and v.spec_motorized ~= nil and v.rootNode ~= nil then
            local ok, err = pcall(self.updateVehicle, self, v, dtMs)
            if not ok then logOnce("upd", "ERREUR couverture : %s", tostring(err)) end
        end
    end
end

function AS_TerminalMap:clear(v, job)
    local m = self:get(v)
    m.jobs[job] = newMap()
    m.prev = {}
    self.cache = nil
end

-------------------------------------------------------------------------------
-- Lignes de guidage : Courseplay, sinon aide à la direction / ouvrier IA du jeu
-------------------------------------------------------------------------------
local function pointsOf(seg)
    local pts = {}
    local p = seg.positions or seg.points or seg.line
    if type(p) == "table" then
        if type(p[1]) == "number" then
            local stride = (#p % 3 == 0 and #p % 2 ~= 0) and 3 or 2
            for i = 1, #p - stride + 1, stride do
                pts[#pts + 1] = { p[i], stride == 3 and p[i + 2] or p[i + 1] }
            end
        else
            for _, q in ipairs(p) do
                if type(q) == "table" then
                    local x = q.x or q[1]
                    local z = q.z or (q[3] ~= nil and q[3]) or q[2]
                    if type(x) == "number" and type(z) == "number" then pts[#pts + 1] = { x, z } end
                end
            end
        end
    end
    if #pts == 0 and seg.startX ~= nil and seg.endX ~= nil then
        pts = { { seg.startX, seg.startZ }, { seg.endX, seg.endZ } }
    end
    return pts
end

local function keysOf(t)
    local k = {}
    for name, val in pairs(t) do
        if type(name) == "string" then k[#k + 1] = name .. ":" .. type(val) end
    end
    table.sort(k)
    return table.concat(k, " ")
end

-- parcours du jeu : liste de lignes { {x,z}, ... }
local function giantsLines(v)
    local course
    local st = v.spec_aiAutomaticSteering
    if st ~= nil and st.steeringFieldCourse ~= nil then course = st.steeringFieldCourse end
    if course == nil and v.spec_aiFieldWorker ~= nil and type(v.spec_aiFieldWorker.driveStrategies) == "table" then
        for _, s in ipairs(v.spec_aiFieldWorker.driveStrategies) do
            if s.aiFieldCourse ~= nil then course = s.aiFieldCourse.fieldCourse or s.aiFieldCourse break end
        end
    end
    if course == nil then return nil end
    local fc = course.fieldCourse or course
    local segs = fc.segments or course.segments
    if type(segs) ~= "table" then
        logOnce("segs", "parcours du jeu sans segments : %s", keysOf(course))
        return nil
    end
    local lines = {}
    for _, seg in ipairs(segs) do
        if type(seg) == "table" then
            local pts = pointsOf(seg)
            if #pts >= 2 then lines[#lines + 1] = pts end
        end
    end
    if #lines == 0 and #segs > 0 and type(segs[1]) == "table" then
        logOnce("seg1", "segment du jeu illisible : %s", keysOf(segs[1]))
    end
    return lines, course.currentSegmentIndex
end

-- parcours Courseplay : une ligne de points + index courant + distance au bout de rang
local function cpCourse(v)
    if v.getFieldWorkCourse == nil then return nil end
    local course = call(v, "getFieldWorkCourse")
    if course == nil then return nil end
    local n = call(course, "getNumberOfWaypoints") or 0
    if n < 2 then return nil end
    local cache = AS_TerminalMap.cpCache
    if cache == nil or cache.course ~= course or cache.n ~= n then
        local pts = {}
        for i = 1, n do
            local wp = call(course, "getWaypoint", i)
            if wp ~= nil and wp.x ~= nil and wp.z ~= nil then
                pts[#pts + 1] = { wp.x, wp.z, i = i, rowEnd = call(wp, "isRowEnd") == true }
            end
        end
        cache = { course = course, n = n, pts = pts }
        AS_TerminalMap.cpCache = cache
    end
    local cur = call(course, "getCurrentWaypointIx") or 1
    -- distance jusqu'à la fin du rang
    local toEnd
    local pts = cache.pts
    for j = 1, #pts do
        if pts[j].i >= cur then
            local d = 0
            local x, _, z = getWorldTranslation(v.rootNode)
            local px, pz = x, z
            for k = j, #pts do
                d = d + math.sqrt((pts[k][1] - px) ^ 2 + (pts[k][2] - pz) ^ 2)
                px, pz = pts[k][1], pts[k][2]
                if pts[k].rowEnd then toEnd = d break end
                if d > 2000 then break end
            end
            break
        end
    end
    local row
    local wp = call(course, "getWaypoint", cur)
    if wp ~= nil then row = call(wp, "getRowNumber") end
    return pts, cur, toEnd, row, call(course, "getWorkWidth")
end

-------------------------------------------------------------------------------
-- Bordure du champ et image de la carte
-------------------------------------------------------------------------------
AS_TerminalMap.borders = {}

local function fieldBorder(field)
    if field == nil then return nil end
    local b = AS_TerminalMap.borders[field]
    if b ~= nil then return b or nil end
    b = false
    local nodes = call(field, "getPolygonPoints") or field.polygonPoints
    if type(nodes) == "table" and #nodes >= 3 then
        b = {}
        for _, n in ipairs(nodes) do
            local ok, x, _, z = pcall(getWorldTranslation, n)
            if ok and x ~= nil then b[#b + 1] = { x, z } end
        end
        if #b < 3 then b = false end
    end
    AS_TerminalMap.borders[field] = b
    return b or nil
end
AS_TerminalMap.fieldBorder = fieldBorder   -- (01/11) aussi pour la vue GPS

function AS_TerminalMap:getMapImage()
    if self.mapOv ~= nil then return self.mapOv or nil, self.worldX, self.worldZ end
    self.mapOv = false
    local m = g_currentMission
    local hud = m ~= nil and m.hud or nil
    local im = hud ~= nil and (call(hud, "getIngameMap") or hud.ingameMap) or nil
    local file
    if im ~= nil and im.mapOverlay ~= nil then file = im.mapOverlay.filename end
    if file == nil and m ~= nil and m.missionInfo ~= nil and m.missionInfo.map ~= nil then
        file = m.missionInfo.map.mapImageFilename
    end
    self.worldX = (im ~= nil and im.worldSizeX) or (m ~= nil and m.terrainSize) or 2048
    self.worldZ = (im ~= nil and im.worldSizeZ) or (m ~= nil and m.terrainSize) or 2048
    -- l'image des cartes FS25 déborde du monde (décor autour) : le monde n'en occupe que le centre,
    -- comme dans IngameMap (moitié de l'image, décalée d'un quart)
    self.extScale = (im ~= nil and im.mapExtensionScaleFactor) or 0.5
    self.extOffX = (im ~= nil and im.mapExtensionOffsetX) or 0.25
    self.extOffZ = (im ~= nil and im.mapExtensionOffsetZ) or 0.25
    if file ~= nil and createImageOverlay ~= nil then
        local ok, ov = pcall(createImageOverlay, file)
        if ok and ov ~= nil and ov ~= 0 then self.mapOv = ov end
    end
    log("image de la carte : %s (%s), monde %s x %s m, échelle %s, décalage %s / %s", tostring(file),
        self.mapOv and "chargée" or "absente", tostring(self.worldX), tostring(self.worldZ),
        tostring(self.extScale), tostring(self.extOffX), tostring(self.extOffZ))
    return self.mapOv or nil, self.worldX, self.worldZ
end

function AS_TerminalMap:getArrow()
    if self.arrowOv == nil then
        self.arrowOv = false
        local ok, ov = pcall(createImageOverlay, Utils.getFilename("hud/as_tm_arrow.dds", AS_MOD_DIR))
        if ok and ov ~= nil and ov ~= 0 then self.arrowOv = ov end
    end
    return self.arrowOv or nil
end

-------------------------------------------------------------------------------
-- Calcul du dessin (cache) : couverture en bandes, bordure, lignes en pointillés
-------------------------------------------------------------------------------
local COL = {
    work   = { 0.20, 0.45, 0.95, 0.85 },
    over   = { 0.95, 0.25, 0.25, 0.90 },
    border = { 1.00, 1.00, 1.00, 0.80 },
    line   = { 1.00, 0.85, 0.20, 0.95 },
    lineDone = { 0.55, 0.50, 0.30, 0.70 },
    lineCur  = { 1.00, 0.55, 0.10, 1.00 },
    grid   = { 1.00, 1.00, 1.00, 0.06 },
}

function AS_TerminalMap:buildCache(v, mw, mh)
    local half = self.ZOOMS[self.zoom]
    local mpu = half * 2 / mw                              -- mètres par unité du panneau
    local vx, _, vz = getWorldTranslation(v.rootNode)
    local list = {}
    local function add(u, vv, w, h, c) list[#list + 1] = { u, vv, w, h, c } end
    local function toU(x, z) return mw * 0.5 + (x - vx) / mpu, mh * 0.5 + (z - vz) / mpu end
    local function inside(u, vv) return u >= 0 and u <= mw and vv >= 0 and vv <= mh end

    -- quadrillage tous les 10 / 50 m
    local gstep = half <= 50 and 10 or (half <= 200 and 50 or 100)
    local gx0 = math.floor((vx - half) / gstep) * gstep
    for gx = gx0, vx + half, gstep do
        local u = toU(gx, vz)
        if u >= 0 and u <= mw then add(u, 0, 0.6, mh, COL.grid) end
    end
    local halfZ = half * mh / mw
    local gz0 = math.floor((vz - halfZ) / gstep) * gstep
    for gz = gz0, vz + halfZ, gstep do
        local _, vv = toU(vx, gz)
        if vv >= 0 and vv <= mh then add(0, vv, mw, 0.6, COL.grid) end
    end

    -- couverture : bandes horizontales, une lecture de case par échantillon
    local map = self:current(v)
    if map.n > 0 then
        local c = self.CELL
        local band = math.max(2, c / mpu)                 -- hauteur d'une bande en unités
        local rows = math.ceil(mh / band)
        local sample = math.max(1.5, c / mpu)
        local cols = math.ceil(mw / sample)
        for r = 0, rows - 1 do
            local vv = r * band
            local z = vz + (vv + band * 0.5 - mh * 0.5) * mpu
            local cz = math.floor(z / c)
            local runState, runStart = 0, 0
            for col = 0, cols do
                local st = 0
                if col < cols then
                    local u = col * sample
                    local x = vx + (u + sample * 0.5 - mw * 0.5) * mpu
                    local k = cellKey(math.floor(x / c), cz)
                    if map.cells[k] ~= nil then st = map.ov[k] and 2 or 1 end
                end
                if st ~= runState then
                    if runState ~= 0 then
                        add(runStart * sample, vv, math.min(mw, col * sample) - runStart * sample, band + 0.4,
                            runState == 2 and COL.over or COL.work)
                    end
                    runState, runStart = st, col
                end
            end
        end
    end

    -- bordure du champ (points tous les 3 unités)
    local field
    if g_fieldManager ~= nil and g_fieldManager.getFieldAtWorldPosition ~= nil then
        local ok, f = pcall(g_fieldManager.getFieldAtWorldPosition, g_fieldManager, vx, vz)
        if ok then field = f end
    end
    local border = fieldBorder(field)
    local dots = 0
    local function dotted(pts, color, step, closed, colorFn)
        local n = #pts
        local last = closed and n or n - 1
        for i = 1, last do
            local a, b = pts[i], pts[i % n + 1]
            local u1, v1 = toU(a[1], a[2])
            local u2, v2 = toU(b[1], b[2])
            if not ((u1 < 0 and u2 < 0) or (u1 > mw and u2 > mw) or (v1 < 0 and v2 < 0) or (v1 > mh and v2 > mh)) then
                local len = math.sqrt((u2 - u1) ^ 2 + (v2 - v1) ^ 2)
                local k = math.max(1, math.floor(len / step))
                local col = colorFn ~= nil and colorFn(i) or color
                for j = 0, k - 1 do
                    local u, vv = u1 + (u2 - u1) * j / k, v1 + (v2 - v1) * j / k
                    if inside(u, vv) then
                        add(u - 0.8, vv - 0.8, 1.6, 1.6, col)
                        dots = dots + 1
                        if dots > 3000 then return end
                    end
                end
            end
        end
    end
    if border ~= nil then dotted(border, COL.border, 3, true) end

    -- lignes de guidage
    local info = {}
    local pts, cur, toEnd, row, cpWidth = cpCourse(v)
    if pts ~= nil then
        info.source = "CP"
        info.toEnd, info.row, info.width = toEnd, row, cpWidth
        dotted(pts, COL.line, 4, false, function(i)
            local idx = pts[i].i
            if idx < cur then return COL.lineDone end
            if idx <= cur + 1 then return COL.lineCur end
            return COL.line
        end)
    else
        local lines, curSeg = giantsLines(v)
        if lines ~= nil and #lines > 0 then
            info.source = "IA"
            for i, l in ipairs(lines) do
                dotted(l, i == curSeg and COL.lineCur or COL.line, 4, false)
            end
        end
    end

    -- cap du véhicule
    local dx, _, dz = localDirectionToWorld(v.rootNode, 0, 0, 1)
    info.heading = (math.deg(math.atan2(dx, -dz)) + 360) % 360
    info.rot = -math.atan2(dx, -dz)
    info.covered = map.n * self.CELL * self.CELL / 10000
    info.overlap = map.nov * self.CELL * self.CELL / 10000
    info.vx, info.vz, info.mpu = vx, vz, mpu
    self.cache = { t = g_time, v = v, list = list, info = info, zoom = self.zoom, mw = mw, mh = mh }
end

-------------------------------------------------------------------------------
-- Page Travail (remplace celle de Terminal.lua)
-------------------------------------------------------------------------------
function AS_Terminal:page_work(d, ctx, inside, v)
    local M = AS_TerminalMap
    local mx0, my0 = ctx.cx + 6, ctx.cy + 30
    local mw, mh = ctx.cw - 12, ctx.ch - 36
    local c = M.cache
    if c == nil or c.v ~= v or c.zoom ~= M.zoom or c.mw ~= mw or g_time - c.t >= M.CACHE_MS or g_time < c.t then
        local ok, err = pcall(M.buildCache, M, v, mw, mh)
        if not ok then logOnce("cache", "ERREUR carte : %s", tostring(err)) end
        c = M.cache
    end
    if c == nil then return end
    local info = c.info

    -- fond : image de la carte du jeu, découpée sur la vue
    ctx.rect(mx0, my0, mw, mh, { 0.07, 0.09, 0.08, 1 })
    if M.mapImage and ctx.rec == nil then
        local ov, wx, wz = M:getMapImage()
        if ov ~= nil and setOverlayUVs ~= nil then
            local halfW = info.mpu * mw * 0.5
            local halfH = info.mpu * mh * 0.5
            local es, eox, eoz = M.extScale or 0.5, M.extOffX or 0.25, M.extOffZ or 0.25
            local u0 = ((info.vx - halfW) / wx + 0.5) * es + eox
            local u1 = ((info.vx + halfW) / wx + 0.5) * es + eox
            local t0 = ((info.vz - halfH) / wz + 0.5) * es + eoz   -- haut de la vue (nord)
            local t1 = ((info.vz + halfH) / wz + 0.5) * es + eoz
            local v0, v1 = 1 - t1, 1 - t0                      -- v = 0 en bas de l'image
            setOverlayUVs(ov, u0, v0, u0, v1, u1, v0, u1, v1)
            setOverlayColor(ov, 1, 1, 1, 0.9)
            renderOverlay(ov, ctx.X(mx0), ctx.Y(my0 + mh), ctx.sx(mw), ctx.sy(mh))
        end
    end
    for _, r in ipairs(c.list) do
        local u, vv, w, h = r[1], r[2], r[3], r[4]
        if u < mw and vv < mh and w > 0 and h > 0 then
            ctx.rect(mx0 + u, my0 + vv, math.min(w, mw - u), math.min(h, mh - vv), r[5])
        end
    end
    -- (04/11) antennes RTK de la ferme sur la carte, avec leur distance ; hors de la vue : au bord, dans leur direction
    local rtk = M.drawRtk ~= nil and M:drawRtk(ctx, v, info, mx0, my0, mw, mh) or nil

    -- véhicule : flèche orientée (cap), au centre
    local ar = M:getArrow()
    local s = 22
    if ar ~= nil and ctx.rec == nil then
        local w, h = ctx.sx(s), ctx.sy(s)
        if setOverlayRotation ~= nil then setOverlayRotation(ar, info.rot, w * 0.5, h * 0.5) end
        setOverlayColor(ar, 1, 1, 1, 1)
        renderOverlay(ar, ctx.X(mx0 + mw * 0.5 - s * 0.5), ctx.Y(my0 + mh * 0.5 + s * 0.5), w, h)
    else
        ctx.rect(mx0 + mw * 0.5 - 4, my0 + mh * 0.5 - 4, 8, 8, { 1, 1, 1, 1 })
    end

    -- bandeau d'infos au-dessus de la carte
    -- (04/11) thème clair (Case) : fond blanc, les textes blancs / gris clair disparaissaient
    local light = AS_Terminal ~= nil and AS_Terminal.curTheme == 2
    local white, gray, blue, red = { 1, 1, 1, 1 }, { 0.62, 0.66, 0.70, 1 }, { 0.35, 0.60, 1.00, 1 }, { 1.00, 0.35, 0.30, 1 }
    local onMap = white
    if light then white, gray, blue, red = { 0.02, 0.02, 0.03, 1 }, { 0.20, 0.22, 0.25, 1 }, { 0.04, 0.30, 0.58, 1 }, { 0.80, 0.10, 0.08, 1 } end
    local y = ctx.cy + 20
    ctx.rect(ctx.cx + 6, ctx.cy + 4, 10, 10, { 0.20, 0.45, 0.95, 1 })
    ctx.text(ctx.cx + 20, y - 6, 11, T("covered"), gray)
    ctx.rect(ctx.cx + 90, ctx.cy + 4, 10, 10, { 0.95, 0.25, 0.25, 1 })
    ctx.text(ctx.cx + 104, y - 6, 11, T("overlap"), gray)
    ctx.text(ctx.cx + 180, y - 6, 12, d.field ~= nil and string.format(T("field"), d.field) or T("outField"), white, nil, true)
    ctx.text(ctx.cx + 180, y + 7, 11, string.format("%.2f ha  /  %.2f ha", info.covered, info.overlap), gray)
    ctx.text(ctx.cx + 330, y - 6, 11, T("heading"), gray)
    ctx.text(ctx.cx + 330, y + 7, 12, string.format("%d°", math.floor(info.heading + 0.5)), white, nil, true)
    local guideTxt = info.source ~= nil and ((AS_Terminal ~= nil and AS_Terminal.ui ~= nil and AS_Terminal.ui.T or T)("g_" .. info.source)) or T("none")
    ctx.text(ctx.cx + 395, y - 6, 11, T("b_guide"), gray)
    ctx.text(ctx.cx + 395, y + 7, 12, guideTxt, info.source ~= nil and blue or gray, nil, true)
    if info.toEnd ~= nil then
        ctx.text(ctx.cx + ctx.cw - 8, y - 6, 11, T("toEnd"), gray, RenderText.ALIGN_RIGHT)
        ctx.text(ctx.cx + ctx.cw - 8, y + 7, 13, string.format("%d m", math.floor(info.toEnd + 0.5)),
            info.toEnd < 20 and red or white, RenderText.ALIGN_RIGHT, true)
    end
    ctx.text(mx0 + 6, my0 + mh - 6, 10, string.format("%d m", M.ZOOMS[M.zoom] * 2), onMap)

    -- boutons de droite : zoom, image, effacer, nouveau
    -- (04/11) thème clair : boutons gris foncé (bleu Case si actif), écriture blanche (avant : gris clair sur blanc, invisibles en jeu)
    local bx, by = ctx.rx + 6, ctx.cy + 22
    local function rbtn(i, action, label, hot)
        local yy = by + (i - 1) * 40
        ctx.button(bx, yy, 128, 34, action, hot)
        if light then
            local hov = AS_Terminal.hover == action
            ctx.rect(bx, yy, 128, 34, hot and (hov and { 0.08, 0.38, 0.70, 1 } or { 0.04, 0.30, 0.58, 1 }) or (hov and { 0.30, 0.32, 0.36, 1 } or { 0.20, 0.21, 0.24, 1 }))
        end
        ctx.text(bx + 64, yy + 22, 11, label, { 1, 1, 1, 1 }, RenderText.ALIGN_CENTER, true)
    end
    rbtn(1, "zoomIn", T("zoomIn"))
    rbtn(2, "zoomOut", T("zoomOut"))
    rbtn(3, "mapImg", T("mapImg") .. " : " .. (M.mapImage and T("yes") or T("no")), M.mapImage)
    rbtn(4, "clearMap", T("clearMap"))
    rbtn(5, "newJob", T("newJob"))
    local ry = by + 5 * 40 + 6
    if info.row ~= nil then
        ctx.text(bx + 64, ry + 14, 11, string.format(T("row"), info.row), gray, RenderText.ALIGN_CENTER)
        ry = ry + 24
    end
    -- (04/11) case Distance : antennes RTK de la plus proche à la plus loin
    if rtk ~= nil then
        local n = math.min(#rtk, 3)
        local hh = 26 + math.max(1, n) * 17
        ctx.rect(bx, ry, 128, hh, light and { 0.20, 0.21, 0.24, 1 } or { 0.11, 0.13, 0.15, 1 })
        ctx.text(bx + 64, ry + 17, 11, T("rtkDist"), { 1, 1, 1, 1 }, RenderText.ALIGN_CENTER, true, 122)
        if n == 0 then
            ctx.text(bx + 64, ry + 37, 11, T("rtkNone"), { 1, 0.32, 0.26, 1 }, RenderText.ALIGN_CENTER, true, 122)
        end
        for i = 1, n do
            local e = rtk[i]
            local yy = ry + 20 + i * 17
            ctx.rect(bx + 10, yy - 9, 9, 9, e.col)
            ctx.text(bx + 26, yy, 11, "RTK " .. i, { 0.85, 0.88, 0.92, 1 }, nil, true)
            ctx.text(bx + 120, yy, 12, e.txt, e.col, RenderText.ALIGN_RIGHT, true)
        end
    end
end

-- (04/11) antennes RTK (Precision Farming) de la ferme du véhicule sur la carte TRAVAIL.
-- Couleur = signal qu'elles donneraient ici (vert RTK, orange FLOAT, jaune GPS, rouge hors de portée).
-- Renvoie la liste triée { d = m, txt, col } (nil si le module GPS manque)
function AS_TerminalMap:drawRtk(ctx, v, info, mx0, my0, mw, mh)
    local Gp = AS_TerminalGps
    if Gp == nil or Gp.rtkStations == nil or Gp.distTxt == nil then return nil end
    local farmId
    if v.getOwnerFarmId ~= nil then local okF, f = pcall(v.getOwnerFarmId, v); if okF then farmId = f end end
    local okL, list = pcall(Gp.rtkStations, Gp, farmId)
    if not okL or type(list) ~= "table" then return nil end
    local out = {}
    for _, st in ipairs(list) do
        local dd = math.sqrt((st.x - info.vx) ^ 2 + (st.z - info.vz) ^ 2)
        out[#out + 1] = { d = dd, x = st.x, z = st.z, txt = Gp.distTxt(dd), col = Gp.rtkColor(dd) }
    end
    table.sort(out, function(a, b) return a.d < b.d end)
    local cx, cy = mx0 + mw * 0.5, my0 + mh * 0.5
    local back = { 0, 0, 0, 0.62 }
    for i = #out, 1, -1 do
        local e = out[i]
        local du, dv = (e.x - info.vx) / info.mpu, (e.z - info.vz) / info.mpu
        -- bord de la vue : 16 à gauche / droite, 28 en haut (hauteur du pictogramme), 8 en bas
        local kx = du > 0 and (mw * 0.5 - 16) / du or du < 0 and (mw * 0.5 - 16) / -du or math.huge
        local ky = dv > 0 and (mh * 0.5 - 8) / dv or dv < 0 and (mh * 0.5 - 28) / -dv or math.huge
        local k0 = math.min(1, kx, ky)
        local edge = k0 < 1
        du, dv = du * k0, dv * k0
        local x, y = cx + du, cy + dv
        local k = edge and 0.75 or 1
        -- pictogramme : socle, mât, tête et ondes (fond sombre pour se voir sur l'image de la carte)
        ctx.rect(x - 13 * k, y - 25 * k, 26 * k, 28 * k, back)
        ctx.rect(x - 6 * k, y - 2 * k, 12 * k, 3 * k, { 0.85, 0.87, 0.90, 1 })
        ctx.rect(x - 1 * k, y - 15 * k, 2 * k, 13 * k, { 0.85, 0.87, 0.90, 1 })
        ctx.rect(x - 2.5 * k, y - 19 * k, 5 * k, 5 * k, e.col)
        ctx.rect(x - 7 * k, y - 20 * k, 2 * k, 7 * k, e.col)
        ctx.rect(x + 5 * k, y - 20 * k, 2 * k, 7 * k, e.col)
        ctx.rect(x - 11 * k, y - 22 * k, 2 * k, 11 * k, e.col)
        ctx.rect(x + 9 * k, y - 22 * k, 2 * k, 11 * k, e.col)
        -- distance à côté (à gauche si la station est près du bord droit)
        local tw = ctx.measure ~= nil and ctx.measure(11, e.txt) or #e.txt * 6
        local left = x + 16 + tw + 8 > mx0 + mw
        local tx = left and (x - 16 * k - tw - 6) or (x + 15 * k)
        ctx.rect(tx, y - 21 * k, tw + 8, 15, back)
        ctx.text(tx + 4, y - 21 * k + 11, 11, e.txt, e.col, nil, true)
    end
    return out
end

-- boutons de la carte, en plus de ceux du terminal
local baseAction = AS_Terminal.doAction
function AS_Terminal:doAction(a)
    local M = AS_TerminalMap
    local d = self.data
    if a == "zoomIn" then M.zoom = math.max(1, M.zoom - 1); M.cache = nil; return
    elseif a == "zoomOut" then M.zoom = math.min(#M.ZOOMS, M.zoom + 1); M.cache = nil; return
    elseif a == "mapImg" then M.mapImage = not M.mapImage; return
    elseif a == "clearMap" and d ~= nil then M:clear(d.vehicle, d.cnt.active); return
    elseif a == "newJob" and d ~= nil then
        M:clear(d.vehicle, d.cnt.active)
        baseAction(self, "reset")
        return
    elseif a == "reset" and d ~= nil then
        M:clear(d.vehicle, d.cnt.active)
    end
    return baseAction(self, a)
end

-------------------------------------------------------------------------------
-- Sauvegarde : cases par ligne, en plages « x0+longueur »
-------------------------------------------------------------------------------
local function savegamePath()
    local mi = g_currentMission ~= nil and g_currentMission.missionInfo or nil
    local dir = mi ~= nil and mi.savegameDirectory or nil
    if dir == nil or dir == "" then return nil end
    return dir .. "/" .. AS_TerminalMap.SAVE_NAME
end

local function encode(set)
    local rows = {}
    for k in pairs(set) do
        local cx, cz = math.floor(k / 65536) - 32768, k % 65536 - 32768
        local r = rows[cz]
        if r == nil then r = {}; rows[cz] = r end
        r[#r + 1] = cx
    end
    local zs = {}
    for z in pairs(rows) do zs[#zs + 1] = z end
    table.sort(zs)
    local out = {}
    for _, z in ipairs(zs) do
        local xs = rows[z]
        table.sort(xs)
        local parts = {}
        local s, prev = xs[1], xs[1]
        for i = 2, #xs + 1 do
            local x = xs[i]
            if x ~= prev + 1 then
                parts[#parts + 1] = string.format("%d+%d", s, prev - s + 1)
                s = x
            end
            prev = x
        end
        out[#out + 1] = z .. ":" .. table.concat(parts, ",")
    end
    return table.concat(out, ";")
end

local function decode(str, fn)
    if str == nil or str == "" then return end
    for row in str:gmatch("[^;]+") do
        local z, rest = row:match("^(-?%d+):(.*)$")
        if z ~= nil then
            z = tonumber(z)
            for a, n in rest:gmatch("(-?%d+)%+(%d+)") do
                a, n = tonumber(a), tonumber(n)
                for x = a, a + n - 1 do fn(cellKey(x, z)) end
            end
        end
    end
end

function AS_TerminalMap:growBB(map, k)
    local cx, cz = math.floor(k / 65536) - 32768, k % 65536 - 32768
    if map.bx0 == nil then map.bx0, map.bx1, map.bz0, map.bz1 = cx, cx, cz, cz return end
    if cx < map.bx0 then map.bx0 = cx elseif cx > map.bx1 then map.bx1 = cx end
    if cz < map.bz0 then map.bz0 = cz elseif cz > map.bz1 then map.bz1 = cz end
end

-- (01/11) petites cases : « z:x=masque,x=masque;... » (masque en hexadécimal)
local function encodeMask(set)
    local rows = {}
    for k, m in pairs(set) do
        local cx, cz = math.floor(k / 65536) - 32768, k % 65536 - 32768
        local r = rows[cz]
        if r == nil then r = {}; rows[cz] = r end
        r[#r + 1] = { cx, m }
    end
    local zs = {}
    for z in pairs(rows) do zs[#zs + 1] = z end
    table.sort(zs)
    local out = {}
    for _, z in ipairs(zs) do
        local xs = rows[z]
        table.sort(xs, function(a, b) return a[1] < b[1] end)
        local parts = {}
        for i, e in ipairs(xs) do parts[i] = string.format("%d=%x", e[1], e[2]) end
        out[#out + 1] = z .. ":" .. table.concat(parts, ",")
    end
    return table.concat(out, ";")
end

local function decodeMask(str, fn)
    if str == nil or str == "" then return end
    for row in str:gmatch("[^;]+") do
        local z, rest = row:match("^(-?%d+):(.*)$")
        if z ~= nil then
            z = tonumber(z)
            for x, m in rest:gmatch("(-?%d+)=(%x+)") do
                m = tonumber(m, 16)
                if m ~= nil and m >= 0 and m <= FULL then fn(cellKey(tonumber(x), z), m) end
            end
        end
    end
end

function AS_TerminalMap:save()
    local path = savegamePath()
    if path == nil then return end
    local xml = createXMLFile("asTerminalMap", path, "terminalMap")
    if xml == nil or xml == 0 then return end
    setXMLInt(xml, "terminalMap#cell", self.CELL)
    setXMLInt(xml, "terminalMap#zoom", self.zoom)
    setXMLBool(xml, "terminalMap#mapImage", self.mapImage)
    local i = 0
    for key, m in pairs(self.maps) do
        if type(key) == "string" then
            for j = 1, 2 do
                local map = m.jobs[j]
                if map.n > 0 then
                    local k = string.format("terminalMap.map(%d)", i)
                    setXMLString(xml, k .. "#vehicle", key)
                    setXMLInt(xml, k .. "#job", j)
                    setXMLString(xml, k .. ".cells", encode(map.cells))
                    if map.nov > 0 then setXMLString(xml, k .. ".overlap", encode(map.ov)) end
                    if map.part ~= nil and next(map.part) ~= nil then setXMLString(xml, k .. ".part", encodeMask(map.part)) end
                    if map.opart ~= nil and next(map.opart) ~= nil then setXMLString(xml, k .. ".overPart", encodeMask(map.opart)) end
                    i = i + 1
                end
            end
        end
    end
    saveXMLFile(xml)
    delete(xml)
end

function AS_TerminalMap:load()
    self.maps = {}
    local path = savegamePath()
    if path == nil or not fileExists(path) then return end
    local xml = loadXMLFile("asTerminalMap", path)
    if xml == nil or xml == 0 then return end
    if (getXMLInt(xml, "terminalMap#cell") or self.CELL) ~= self.CELL then delete(xml) return end
    self.zoom = clamp(getXMLInt(xml, "terminalMap#zoom") or self.zoom, 1, #self.ZOOMS)
    local b = getXMLBool(xml, "terminalMap#mapImage"); if b ~= nil then self.mapImage = b end
    local i, cells = 0, 0
    while true do
        local k = string.format("terminalMap.map(%d)", i)
        if not hasXMLProperty(xml, k) then break end
        local key = getXMLString(xml, k .. "#vehicle")
        local job = clamp(getXMLInt(xml, k .. "#job") or 1, 1, 2)
        if key ~= nil then
            local m = self.maps[key]
            if m == nil then m = { dist = 0, prev = {}, jobs = { newMap(), newMap() } }; self.maps[key] = m end
            local map = m.jobs[job]
            -- repère 0 : tout passage après rechargement compte comme repassage
            decode(getXMLString(xml, k .. ".cells"), function(c) if map.cells[c] == nil then map.cells[c] = -1000; map.n = map.n + 1 end end)
            decode(getXMLString(xml, k .. ".overlap"), function(c) if not map.ov[c] then map.ov[c] = true; map.nov = map.nov + 1 end end)
            decodeMask(getXMLString(xml, k .. ".part"), function(c, m) map.part[c] = m end)
            decodeMask(getXMLString(xml, k .. ".overPart"), function(c, m) map.opart[c] = m end)
            for c in pairs(map.cells) do self:growBB(map, c) end
            for c in pairs(map.part) do self:growBB(map, c) end
            cells = cells + map.n
        end
        i = i + 1
    end
    delete(xml)
    log("cartes de couverture chargées : %d (%d cases)", i, cells)
end

if FSCareerMissionInfo ~= nil and FSCareerMissionInfo.saveToXMLFile ~= nil then
    FSCareerMissionInfo.saveToXMLFile = Utils.appendedFunction(FSCareerMissionInfo.saveToXMLFile, function()
        local ok, err = pcall(AS_TerminalMap.save, AS_TerminalMap)
        if not ok then log("ERREUR sauvegarde : %s", tostring(err)) end
    end)
end

function AS_TerminalMap:loadMap()
    local ok, err = pcall(self.load, self)
    if not ok then log("ERREUR chargement : %s", tostring(err)) end
end

function AS_TerminalMap:deleteMap()
    self.maps, self.cache, self.cpCache, self.borders = {}, nil, nil, {}
    if self.mapOv then pcall(delete, self.mapOv) end
    if self.arrowOv then pcall(delete, self.arrowOv) end
    self.mapOv, self.arrowOv = nil, nil
end

addModEventListener(AS_TerminalMap)
