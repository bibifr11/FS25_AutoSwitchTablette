-- AutoSwitch : coupure de tronçons (Section Control) du terminal Massey Ferguson (Datatronic 5)
-- Fichier chargé par AutoSwitch.lua après TerminalMassey.lua.
--
-- (04/11) SC AUTO coupe les tronçons de l'outil hors du champ et sur la zone déjà faite ;
-- SC MANU : le joueur coupe lui-même (touches du jeu), le terminal ne touche à rien.
-- Le jeu (spécialisation VariableWorkWidth) ne règle qu'un NOMBRE de tronçons actifs par côté, du centre vers
-- l'extérieur : seuls les tronçons extérieurs peuvent être coupés, jamais un tronçon du milieu, et sans tronçon
-- central le premier tronçon de chaque côté reste allumé.
-- Zone déjà faite : couverture propre au SC (seulement les tronçons réellement allumés), en mémoire, effacée quand on
-- efface la carte de la page Travail, ou après 6 h de jeu sans travailler (nouveau chantier).

AS_SectionControl = {}
local S = AS_SectionControl
S.ENABLED = true
S.TICK_MS = 100
S.AHEAD = 0.7          -- contrôle à 0,7 m devant la ligne de travail (m)
S.IDLE_RESET_H = 6     -- heures de jeu sans travailler : la couverture du SC repart à zéro
S.MAX_LOG = 25
S.state = setmetatable({}, { __mode = "k" })   -- outil -> état
S.timer = 0
S.logged = {}
S.nLog = 0
S.nCp = 0

-- (66d3) toujours écrit dans log.txt (comme les lignes [AS_Terminal] du terminal) : le filtre des logs d'AutoSwitch les coupait
local function log(fmt, ...) ((AS ~= nil and AS.rawPrint) or print)(string.format("[AS_Terminal] SC : " .. fmt, ...)) end
local function logOnce(key, fmt, ...)
    if S.logged[key] then return end
    S.logged[key] = true
    log(fmt, ...)
end
local function call(o, name, ...)
    local f = type(o) == "table" and o[name] or nil
    if f == nil then return nil end
    local ok, a, b, c = pcall(f, o, ...)
    if ok then return a, b, c end
    return nil
end
local function clamp(v, a, b) return math.max(a, math.min(b, v)) end

-- (05/11) Courseplay recalcule sa
-- largeur de travail ET son décalage d'outil à chaque changement de tronçons (fonction ajoutée à
-- VariableWorkWidth.updateSections) : un côté coupé = décalage de la moitié de ce qui est coupé, et le tracteur quitte
-- sa ligne. Un vrai SC ne déplace jamais le tracteur : les deux réglages Courseplay sont remis tels qu'avant après
-- chaque changement fait par le SC (les touches du joueur gardent le comportement de Courseplay).
local function cpKeep(o)
    local root = (o ~= nil and o.rootVehicle) or o
    local s = call(root, "getCpSettings")
    local g = call(root, "getCourseGeneratorSettings")
    local k = { off = s ~= nil and s.toolOffsetX or nil, ww = g ~= nil and g.workWidth or nil }
    if k.off ~= nil then k.offV = call(k.off, "getValue") end
    if k.ww ~= nil then k.wwV = call(k.ww, "getValue") end
    return k
end
local function cpRestore(k)
    local changed = false
    for _, e in ipairs({ { k.off, k.offV }, { k.ww, k.wwV } }) do
        local st, old = e[1], e[2]
        if st ~= nil and type(old) == "number" and st.setFloatValue ~= nil then
            local now = call(st, "getValue")
            if type(now) ~= "number" or math.abs(now - old) > 0.001 then
                pcall(st.setFloatValue, st, old, nil, true)
                changed = true
            end
        end
    end
    return changed
end
local function setSections(o, nL, nR)
    local k = cpKeep(o)
    local ok, err = pcall(o.setSectionsActive, o, nL, nR)
    if cpRestore(k) and S.nCp < 5 then
        S.nCp = S.nCp + 1
        log("Courseplay : largeur %s m et décalage %s m gardés (tronçons changés par le SC)", tostring(k.wwV), tostring(k.offV))
    end
    return ok, err
end

-------------------------------------------------------------------------------
-- Réglages (par modèle de tracteur, prefs « sc » du terminal)
-------------------------------------------------------------------------------
-- auto : 1 = SC AUTO ; done : 1 = coupe sur la zone déjà faite (menu SC, ligne 1 On / Off) ;
-- bd : bord du champ (menu SC, ligne 2) 1 = coupe dès que le tronçon sort (selon ovBd), 2 = quand la moitié sort, 3 = pas de bord ;
-- ovIn / ovBd : part du tronçon (%) sur zone faite / hors champ avant de le couper ;
-- drive : recouvrement dans le sens de marche (m, + = coupe plus tard) ; tol : tolérance du tronçon extérieur (m) ;
-- dOn / dOff : délais d'allumage / de coupure (s) ; boom : contrôle de rampe (affiché)
S.KEYS = { "auto", "done", "bd", "ovIn", "ovBd", "drive", "tol", "dOn", "dOff", "boom" }
S.DEF = { auto = 0, done = 1, bd = 1, ovIn = 50, ovBd = 0, drive = 0, tol = 0, dOn = 0.2, dOff = 0.2, boom = 1 }
S.STEPS = { ovIn = { 0, 100, 10 }, ovBd = { 0, 100, 10 }, drive = { -2, 2, 0.1 }, tol = { 0, 2, 0.1 }, dOn = { 0, 1, 0.05 }, dOff = { 0, 1, 0.05 } }

function S:cfg(v)
    local p = (v ~= nil and AS_Terminal ~= nil and AS_Terminal.vehPrefs ~= nil) and AS_Terminal:vehPrefs(v) or nil
    local str = p ~= nil and p.sc or ""
    local c = self.cfgCache
    if c ~= nil and c.str == str then return c.t end
    local t = {}
    for k, val in pairs(self.DEF) do t[k] = val end
    local i = 0
    for part in string.gmatch(str .. ",", "([^,]*),") do
        i = i + 1
        local key, n = self.KEYS[i], tonumber(part)
        if key ~= nil and n ~= nil then t[key] = n end
    end
    self.cfgCache = { str = str, t = t }
    return t
end

local function num(x)
    local r = math.floor(x * 100 + 0.5) / 100
    if r == math.floor(r) then return string.format("%d", r) end
    return (string.format("%.2f", r):gsub("0$", ""))
end

function S:setCfg(v, key, val)
    if v == nil or AS_Terminal == nil or AS_Terminal.vehPrefs == nil then return end
    local p = AS_Terminal:vehPrefs(v, true)
    if p == nil then return end
    local cur, out = self:cfg(v), {}
    for i, k in ipairs(self.KEYS) do out[i] = num(k == key and val or cur[k]) end
    p.sc = table.concat(out, ",")
    if AS_Terminal.saveSettings ~= nil then pcall(AS_Terminal.saveSettings, AS_Terminal) end
    log("%s = %s (%s)", key, num(val), p.sc)
    if key == "auto" and val == 0 then self:releaseAll(v) end
end

-- ◀ ▶ des réglages
function S:step(v, key, dir)
    local st = self.STEPS[key]
    if st == nil then return end
    local c = self:cfg(v)
    local n = (c[key] or 0) + dir * st[3]
    n = clamp(math.floor(n / st[3] + 0.5) * st[3], st[1], st[2])
    self:setCfg(v, key, n)
end

-------------------------------------------------------------------------------
-- Outils à tronçons
-------------------------------------------------------------------------------
function S:tools(v)
    local list = {}
    if v == nil then return list end
    local ch = call(v, "getChildVehicles")
    local all = type(ch) == "table" and ch or { v }
    for _, o in pairs(all) do
        local sp = type(o) == "table" and o.spec_variableWorkWidth or nil
        if sp ~= nil and sp.hasSections ~= false and type(sp.sectionsLeft) == "table" and type(sp.sectionsRight) == "table"
            and (#sp.sectionsLeft + #sp.sectionsRight) > 0 and o.setSectionsActive ~= nil then
            list[#list + 1] = o
        end
    end
    return list
end

function S:count(o)
    local sp = o ~= nil and o.spec_variableWorkWidth or nil
    if sp == nil then return 0 end
    return #(sp.sections or {})
end

local function isWorking(o)
    local ui = AS_Terminal ~= nil and AS_Terminal.ui or nil
    if ui ~= nil and ui.isWorking ~= nil then
        local ok, w = pcall(ui.isWorking, o)
        return ok and w == true
    end
    return call(o, "getIsLowered", false) ~= false and call(o, "getIsTurnedOn") ~= false
end

local function markers(o)
    if o.getAIMarkers == nil then return nil end
    local l, r = call(o, "getAIMarkers")
    if l == nil or r == nil or l == 0 or r == 0 then return nil end
    local okL, lx, _, lz = pcall(getWorldTranslation, l)
    local okR, rx, _, rz = pcall(getWorldTranslation, r)
    if not okL or not okR or lx == nil or rx == nil then return nil end
    if (lx - rx) ^ 2 + (lz - rz) ^ 2 < 0.25 then return nil end
    return lx, lz, rx, rz
end

-- géométrie des tronçons de chaque côté (du centre vers l'extérieur), mesurée sur l'outil déplié :
-- position du nœud de largeur maxi de chaque tronçon sur l'axe des marqueurs (sinon largeurs du XML)
function S:geometry(o, lx, lz, rx, rz)
    local sp = o.spec_variableWorkWidth
    local cx, cz = (lx + rx) * 0.5, (lz + rz) * 0.5
    local ux, uz = lx - cx, lz - cz
    local half = math.sqrt(ux * ux + uz * uz)
    if half < 0.1 then return nil end
    ux, uz = ux / half, uz / half
    local function build(list)
        local out, sum, n = {}, 0, 0
        for _, sec in ipairs(list) do
            local d
            if sec.maxWidthNode ~= nil and sec.maxWidthNode ~= 0 then
                local ok, x, _, z = pcall(getWorldTranslation, sec.maxWidthNode)
                if ok and x ~= nil then
                    local s = (x - cx) * ux + (z - cz) * uz
                    sum, n, d = sum + s, n + 1, math.abs(s)
                end
            end
            out[#out + 1] = { sec = sec, d = d, w = math.abs(tonumber(sec.widthAbs or sec.width) or 0) }
        end
        return out, sum, n
    end
    local L, sL, nL = build(sp.sectionsLeft)
    local R, sR, nR = build(sp.sectionsRight)
    local function finish(t)
        local wmax, allD = 0, true
        for _, e in ipairs(t) do
            if e.w > wmax then wmax = e.w end
            if e.d == nil or e.d < 0.05 then allD = false end
        end
        for _, e in ipairs(t) do e.edge = allD and e.d or (wmax > 0 and e.w / wmax * half or half) end
        table.sort(t, function(a, b) return a.edge < b.edge end)
        local prev = 0
        for _, e in ipairs(t) do e.inner = math.min(prev, e.edge); prev = e.edge end
    end
    finish(L); finish(R)
    -- côté « gauche » du jeu : du côté du marqueur gauche, sauf si les nœuds mesurés disent l'inverse
    local swap = (nL > 0 and sL < 0) or (nL == 0 and nR > 0 and sR > 0)
    return { L = L, R = R, sgL = swap and -1 or 1, half = half, measured = nL + nR > 0 }
end

-------------------------------------------------------------------------------
-- Champ et zone faite
-------------------------------------------------------------------------------
local function terrainY(x, z)
    if getTerrainHeightAtWorldPos ~= nil and g_terrainNode ~= nil then
        local ok, y = pcall(getTerrainHeightAtWorldPos, g_terrainNode, x, 0, z)
        if ok and y ~= nil then return y end
    end
    return 0
end
-- dans un champ (sol de champ) ? nil = on ne sait pas
function S.onField(x, z)
    if FSDensityMapUtil ~= nil and FSDensityMapUtil.getFieldDataAtWorldPosition ~= nil then
        local ok, on = pcall(FSDensityMapUtil.getFieldDataAtWorldPosition, x, terrainY(x, z), z)
        if ok and type(on) == "boolean" then
            logOnce("fieldA", "bord du champ : FSDensityMapUtil.getFieldDataAtWorldPosition")
            return on
        end
    end
    local m = g_currentMission
    local fgs = m ~= nil and m.fieldGroundSystem or nil
    if fgs ~= nil and fgs.getDensityMapData ~= nil and FieldDensityMap ~= nil and getDensityAtWorldPos ~= nil then
        local ok, mapId, first, n = pcall(fgs.getDensityMapData, fgs, FieldDensityMap.GROUND_TYPE)
        if ok and mapId ~= nil and first ~= nil and n ~= nil then
            local okD, val = pcall(getDensityAtWorldPos, mapId, x, terrainY(x, z), z)
            if okD and type(val) == "number" then
                logOnce("fieldB", "bord du champ : type de sol (fieldGroundSystem)")
                return math.floor(val / 2 ^ first) % (2 ^ n) ~= 0
            end
        end
    end
    logOnce("fieldC", "bord du champ : aucune méthode, seule la zone faite compte")
    return nil
end

local function newCov() return { cells = {}, n = 0, ov = {}, nov = 0, part = {}, opart = {} } end
S.newCov = newCov

-- petite case de 50 cm déjà faite (couverture du SC)
function S.covered(cov, x, z)
    local M = AS_TerminalMap
    if cov == nil or M == nil then return false end
    local c, sub = M.CELL or 2, M.SUB or 4
    local cx, cz = math.floor(x / c), math.floor(z / c)
    local k = (cx + 32768) * 65536 + (cz + 32768)
    local bits = cov.part[k]
    if bits == nil then return cov.cells[k] ~= nil end
    local i = clamp(math.floor((x - cx * c) / (c / sub)), 0, sub - 1)
    local j = clamp(math.floor((z - cz * c) / (c / sub)), 0, sub - 1)
    local b = 2 ^ (j * sub + i)
    return bits % (b + b) >= b
end

local function gameHours()
    local env = g_currentMission ~= nil and g_currentMission.environment or nil
    if env == nil then return (g_time or 0) / 3600000 end
    return (tonumber(env.currentDay) or 0) * 24 + (tonumber(env.dayTime) or 0) / 3600000
end

-------------------------------------------------------------------------------
-- Boucle
-------------------------------------------------------------------------------
function S:st(o)
    local st = self.state[o]
    if st == nil then st = { cov = newCov(), dist = 0, timer = { 0, 0 }, want = {} }; self.state[o] = st end
    return st
end

-- tronçons allumés d'un côté (liste triée du centre vers l'extérieur) ; nombre du jeu si pas d'état par tronçon
local function activeOf(e, idx, count)
    if type(e.sec.isActive) == "boolean" then return e.sec.isActive end
    return idx <= count
end

function S:releaseAll(v)
    for _, o in ipairs(self:tools(v)) do
        local st = self.state[o]
        local sp = o.spec_variableWorkWidth
        if st ~= nil and st.driven and sp ~= nil then
            setSections(o, sp.leftSideMax or #sp.sectionsLeft, sp.rightSideMax or #sp.sectionsRight)
            log("SC MANU : tous les tronçons rallumés (%s)", tostring(call(o, "getName") or "?"))
        end
        if st ~= nil then st.driven = false end
    end
end

-- un côté : nombre de tronçons voulus (le plus extérieur qui doit rester allumé)
function S:wantSide(t, sg, cx, cz, ux, uz, fx, fz, c, cov, isOn)
    local useBd = c.bd ~= 3 and not self.fieldBroken
    local useDone = c.done == 1
    local bdMax = c.bd == 2 and 0.5 or (c.ovBd or 0) / 100
    if not useBd and not useDone then return #t end
    local n = 0
    for idx, e in ipairs(t) do
        local outer = e.edge
        if idx == #t then outer = math.max(e.inner + 0.05, outer - (c.tol or 0)) end
        -- coupé : on regarde un peu plus loin pour rallumer ; allumé : recouvrement dans le sens de marche
        local ahead = self.AHEAD + (isOn[idx] and (c.drive or 0) or -(c.drive or 0))
        ahead = math.max(0.2, ahead)
        local nOut, nDone, nS = 0, 0, 0
        for _, f in ipairs({ 1 / 6, 0.5, 5 / 6 }) do
            local lat = sg * (e.inner + (outer - e.inner) * f)
            local x, z = cx + ux * lat + fx * ahead, cz + uz * lat + fz * ahead
            nS = nS + 1
            if useBd then
                local on = self.onField(x, z)
                if on == false then nOut = nOut + 1 end
            end
            if useDone and self.covered(cov, x, z) then nDone = nDone + 1 end
        end
        local off = (useBd and nOut / nS > bdMax) or (useDone and nDone / nS > (c.ovIn or 50) / 100)
        if not off then n = idx end
    end
    return n
end

function S:updateTool(v, o, c, dtMs, speed)
    local st = self:st(o)
    local sp = o.spec_variableWorkWidth
    local now = gameHours()
    local working = isWorking(o)
    local lx, lz, rx, rz = markers(o)
    if not working or lx == nil then
        st.prev, st.geo = nil, nil
        return
    end
    if st.lastWork ~= nil and now - st.lastWork > self.IDLE_RESET_H then
        st.cov = newCov(); log("couverture effacée (plus de %d h sans travailler)", self.IDLE_RESET_H)
    end
    st.lastWork = now
    if st.geo == nil then
        st.geo = self:geometry(o, lx, lz, rx, rz)
        if st.geo == nil then return end
        logOnce("geo" .. tostring(o), "%s : %d tronçons à gauche, %d à droite%s, bords %s | %s m (%s)", tostring(call(o, "getName") or "outil"),
            #st.geo.L, #st.geo.R, sp.hasCenter and " + centre" or "",
            table.concat((function() local r = {} for _, e in ipairs(st.geo.L) do r[#r + 1] = string.format("%.1f", e.edge) end return r end)(), " "),
            table.concat((function() local r = {} for _, e in ipairs(st.geo.R) do r[#r + 1] = string.format("%.1f", e.edge) end return r end)(), " "),
            st.geo.measured and "nœuds mesurés" or "largeurs du XML")
    end
    local g = st.geo
    local cx, cz = (lx + rx) * 0.5, (lz + rz) * 0.5
    local ux, uz = lx - cx, lz - cz
    local hl = math.sqrt(ux * ux + uz * uz)
    ux, uz = ux / hl, uz / hl
    -- sens de marche : perpendiculaire à la ligne des marqueurs, du côté de l'avant du tracteur
    local fx, fz = -uz, ux
    local okD, dx, _, dz = pcall(localDirectionToWorld, v.rootNode, 0, 0, 1)
    if okD and dx ~= nil and fx * dx + fz * dz < 0 then fx, fz = -fx, -fz end
    local back = v.movingDirection == -1 or (call(v, "getDrivingDirection") or 1) < 0
    if back then fx, fz = -fx, -fz end
    -- couverture : ligne des tronçons réellement allumés
    local function edgeOf(t, count)
        local e0 = 0
        for idx, e in ipairs(t) do if activeOf(e, idx, count) then e0 = math.max(e0, e.edge) end end
        return e0
    end
    local eL, eR = edgeOf(g.L, sp.leftSide or #g.L), edgeOf(g.R, sp.rightSide or #g.R)
    local ax, az = cx + ux * g.sgL * eL, cz + uz * g.sgL * eL
    local bx, bz = cx - ux * g.sgL * eR, cz - uz * g.sgL * eR
    st.dist = st.dist + math.abs(speed) / 3.6 * dtMs / 1000
    if st.prev ~= nil and AS_TerminalMap ~= nil and AS_TerminalMap.sweep ~= nil and (eL > 0 or eR > 0) then
        local ok, err = pcall(AS_TerminalMap.sweep, AS_TerminalMap, st.cov, st.prev, ax, az, bx, bz, st.dist)
        if not ok then logOnce("sweep", "ERREUR couverture : %s", tostring(err)) end
    end
    st.prev = { ax, az, bx, bz }
    -- SC AUTO : en marche avant seulement
    if c.auto ~= 1 or back or math.abs(speed) < 0.5 then return end
    local onL, onR = {}, {}
    for idx, e in ipairs(g.L) do onL[idx] = activeOf(e, idx, sp.leftSide or #g.L) end
    for idx, e in ipairs(g.R) do onR[idx] = activeOf(e, idx, sp.rightSide or #g.R) end
    local wL = self:wantSide(g.L, g.sgL, cx, cz, ux, uz, fx, fz, c, st.cov, onL)
    local wR = self:wantSide(g.R, -g.sgL, cx, cz, ux, uz, fx, fz, c, st.cov, onR)
    local minS = sp.minSideState or (sp.hasCenter and 0 or 1)
    wL = clamp(wL, math.min(minS, #g.L), #g.L)
    wR = clamp(wR, math.min(minS, #g.R), #g.R)
    -- délais : un changement doit durer dOn (rallumer) / dOff (couper) avant d'être appliqué
    local curL, curR = sp.leftSide or #g.L, sp.rightSide or #g.R
    local function settle(i, want, cur)
        if want == cur then st.timer[i] = 0; st.want[i] = nil; return cur end
        if st.want[i] ~= want then st.want[i] = want; st.timer[i] = 0 end
        st.timer[i] = st.timer[i] + dtMs / 1000
        local d = want > cur and (c.dOn or 0.2) or (c.dOff or 0.2)
        if st.timer[i] >= d then st.timer[i] = 0; st.want[i] = nil; return want end
        return cur
    end
    local nL, nR = settle(1, wL, curL), settle(2, wR, curR)
    if nL ~= curL or nR ~= curR then
        local ok, err = setSections(o, nL, nR)
        st.driven = true
        if not ok then logOnce("set", "ERREUR setSectionsActive : %s", tostring(err))
        elseif self.nLog < self.MAX_LOG then
            self.nLog = self.nLog + 1
            log("tronçons gauche %d/%d, droite %d/%d", nL, #g.L, nR, #g.R)
        end
    end
end

function S:update(dt)
    if not self.ENABLED or g_currentMission == nil then return end
    self.timer = self.timer + (dt or 0)
    if self.timer < self.TICK_MS then return end
    local dtMs = self.timer
    self.timer = 0
    local v = AS ~= nil and AS.shGetControlledVehicle ~= nil and AS.shGetControlledVehicle() or nil
    if v == nil or v.rootNode == nil then return end
    local tools = self:tools(v)
    if #tools == 0 then return end
    local c = self:cfg(v)
    local speed = call(v, "getLastSpeed") or 0
    -- bord du champ incohérent (le tracteur est dans un champ mais la méthode dit non) : bord ignoré
    if not self.fieldBroken and call(v, "getIsOnField") == true then
        local okT, x, _, z = pcall(getWorldTranslation, v.rootNode)
        if okT and x ~= nil and self.onField(x, z) == false then
            self.fieldBad = (self.fieldBad or 0) + 1
            if self.fieldBad >= 20 then self.fieldBroken = true; log("bord du champ incohérent : seule la zone faite compte") end
        else
            self.fieldBad = 0
        end
    end
    for _, o in ipairs(tools) do
        local ok, err = pcall(self.updateTool, self, v, o, c, dtMs, speed)
        if not ok then logOnce("upd", "ERREUR : %s", tostring(err)) end
    end
end

-- ligne de travail réduite aux tronçons allumés (carte de la page Travail), dans l'ordre marqueur gauche, droit
function S:activeLine(o, lx, lz, rx, rz)
    local sp = o ~= nil and o.spec_variableWorkWidth or nil
    if sp == nil or type(sp.sectionsLeft) ~= "table" or (#sp.sectionsLeft + #sp.sectionsRight) == 0 then return lx, lz, rx, rz end
    if (sp.leftSide or #sp.sectionsLeft) >= #sp.sectionsLeft and (sp.rightSide or #sp.sectionsRight) >= #sp.sectionsRight then return lx, lz, rx, rz end
    local st = self.state[o]
    local g = (st ~= nil and st.geo) or self:geometry(o, lx, lz, rx, rz)
    if g == nil then return lx, lz, rx, rz end
    local cx, cz = (lx + rx) * 0.5, (lz + rz) * 0.5
    local ux, uz = lx - cx, lz - cz
    local hl = math.sqrt(ux * ux + uz * uz)
    ux, uz = ux / hl, uz / hl
    local function edgeOf(t, count)
        local e0 = 0
        for idx, e in ipairs(t) do if activeOf(e, idx, count) then e0 = math.max(e0, e.edge) end end
        return e0
    end
    local eL, eR = edgeOf(g.L, sp.leftSide or #g.L), edgeOf(g.R, sp.rightSide or #g.R)
    local ePlus, eMinus = eL, eR                   -- côté du marqueur gauche, côté du marqueur droit
    if g.sgL < 0 then ePlus, eMinus = eR, eL end
    return cx + ux * ePlus, cz + uz * ePlus, cx - ux * eMinus, cz - uz * eMinus
end

-- (66e) tronçons de gauche à droite (vus du poste de conduite) pour la page Géométrie du terminal Massey :
-- largeur (m) et milieu (m, négatif à gauche) de chaque tronçon, largeur totale. Outil replié : largeurs du XML.
function S:layout(o)
    local sp = o ~= nil and o.spec_variableWorkWidth or nil
    if sp == nil or type(sp.sectionsLeft) ~= "table" or type(sp.sectionsRight) ~= "table" then return nil, 0 end
    local st = self.state[o]
    local g = st ~= nil and st.geo or nil
    if g == nil then
        local lx, lz, rx, rz = markers(o)
        if lx ~= nil then g = self:geometry(o, lx, lz, rx, rz) end
    end
    local Lt, Rt, total
    if g ~= nil then
        Lt, Rt = g.L, g.R
        if g.sgL < 0 then Lt, Rt = g.R, g.L end
        total = 2 * g.half
    else
        local function build(list)
            local t = {}
            for _, sec in ipairs(list) do t[#t + 1] = { edge = math.abs(tonumber(sec.widthAbs or sec.width) or 0) } end
            table.sort(t, function(a, b) return a.edge < b.edge end)
            local prev = 0
            for _, e in ipairs(t) do e.inner = math.min(prev, e.edge); prev = e.edge end
            return t
        end
        Lt, Rt = build(sp.sectionsLeft), build(sp.sectionsRight)
        total = (Lt[#Lt] ~= nil and Lt[#Lt].edge or 0) + (Rt[#Rt] ~= nil and Rt[#Rt].edge or 0)
    end
    -- tronçon central (ni à gauche ni à droite) : entre les premiers tronçons de chaque côté
    local nC = #(sp.sections or {}) - #sp.sectionsLeft - #sp.sectionsRight
    local c0 = 0
    if nC > 0 then
        for _, sec in ipairs(sp.sections) do
            if sec.isCenter then c0 = math.max(c0, math.abs(tonumber(sec.widthAbs or sec.width) or 0) * 0.5) end
        end
        local m = math.min(Lt[1] ~= nil and Lt[1].edge or 1, Rt[1] ~= nil and Rt[1].edge or 1)
        if c0 <= 0 or c0 >= m then c0 = m * 0.5 end
    end
    local out = {}
    for i = #Lt, 1, -1 do
        local e = Lt[i]; local a = math.max(e.inner, c0)
        out[#out + 1] = { w = math.max(0, e.edge - a), x = -(a + e.edge) * 0.5 }
    end
    if nC > 0 then out[#out + 1] = { w = 2 * c0, x = 0, center = true } end
    for i = 1, #Rt do
        local e = Rt[i]; local a = math.max(e.inner, c0)
        out[#out + 1] = { w = math.max(0, e.edge - a), x = (a + e.edge) * 0.5 }
    end
    return out, total
end

-- rampe des tronçons pour la carte du MF Guide : segments (monde) de gauche à droite, état
-- état : "on" (allumé, au travail), "ready" (allumé, outil pas au travail), "off" (coupé)
function S:bar(v)
    local out = {}
    for _, o in ipairs(self:tools(v)) do
        local lx, lz, rx, rz = markers(o)
        if lx ~= nil then
            local st = self:st(o)
            local g = st.geo or self:geometry(o, lx, lz, rx, rz)
            local sp = o.spec_variableWorkWidth
            if g ~= nil then
                local cx, cz = (lx + rx) * 0.5, (lz + rz) * 0.5
                local ux, uz = lx - cx, lz - cz
                local hl = math.sqrt(ux * ux + uz * uz)
                ux, uz = ux / hl, uz / hl
                local working = isWorking(o)
                local function add(t, sg, count)
                    for idx, e in ipairs(t) do
                        local a, b = sg * e.inner, sg * e.edge
                        local on = activeOf(e, idx, count)
                        out[#out + 1] = { x1 = cx + ux * a, z1 = cz + uz * a, x2 = cx + ux * b, z2 = cz + uz * b,
                            state = not on and "off" or (working and "on" or "ready") }
                    end
                end
                add(g.L, g.sgL, sp.leftSide or #g.L)
                add(g.R, -g.sgL, sp.rightSide or #g.R)
            end
        end
    end
    return out
end

-- carte de la page Travail effacée : la couverture du SC de ce tracteur aussi
if AS_TerminalMap ~= nil and AS_TerminalMap.clear ~= nil and not S.hookedClear then
    S.hookedClear = true
    local orig = AS_TerminalMap.clear
    AS_TerminalMap.clear = function(self2, v, job, ...)
        local r = orig(self2, v, job, ...)
        pcall(function()
            for _, o in ipairs(S:tools(v)) do local st = S.state[o]; if st ~= nil then st.cov = newCov(); st.prev = nil end end
            log("couverture effacée (carte de la page Travail effacée)")
        end)
        return r
    end
end

addModEventListener(S)
