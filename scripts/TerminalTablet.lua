-- AutoSwitch : tablette du terminal dans la cabine
-- Fichier chargé par AutoSwitch.lua (après Terminal.lua et TerminalMap.lua).

local L = AS.L

-------------------------------------------------------------------------------
-- v1.0.4.0 (étape 3) : une tablette 3D (objects/terminal/tablette.i3d) est posée dans
--   chaque véhicule à cabine, à droite du conducteur, calculée depuis la caméra
--   intérieure (tête du conducteur) : 32 cm devant, 45 cm à droite, 30 cm plus bas,
--   écran tourné vers la tête. (31/10) Écran 22 cm de large ; taille (50-150 %), position
--   (au cm) et inclinaison (par 5°) réglables dans la page Réglages, gardées par modèle.
--   En vue cabine, le terminal est dessiné sur l'écran de la tablette : ses 4 coins sont
--   projetés à l'écran à chaque image, le terminal suit donc les mouvements de tête.
--   Écran tactile : avec le curseur (Ctrl droit + Y, ou Interactive Control), on clique
--   directement les pages sur la tablette ; un clic hors bouton ouvre le grand terminal.
--   Vue extérieure : vitesse et rapport écrits en 3D sur l'écran (police du jeu).
-------------------------------------------------------------------------------
AS_TerminalTablet = {}
AS_TerminalTablet.ENABLED = true
AS_TerminalTablet.FILE = "objects/terminal/tablette.i3d"
-- (étape 37b) cadre d'origine remis ; cadre fin : 0.3241, 0.1891 avec le i3d de l'étape 37
AS_TerminalTablet.SW, AS_TerminalTablet.SH = 0.30, 0.17
AS_TerminalTablet.BASE = 0.22 / 0.30                             -- (31/10) tablette ramenée à 22 cm de large
-- (31/10 soir) écrans intégrés : éteints moteur coupé, démarrage de 5 s (logos + barre) au démarrage du moteur
AS_TerminalTablet.BOOT_MS = 5000
-- (31/10 soir) écrans réduits à zéro (Fendt 700 Gen7 : mode clair / sombre) : ignorés, accroche au-dessus, secours
AS_TerminalTablet.FIX_SCALE = true
AS_TerminalTablet.FWD, AS_TerminalTablet.RIGHT, AS_TerminalTablet.UP = 0.32, 0.45, -0.30   -- ancienne place (banc de test)
-- (31/10) deux emplacements au choix dans Réglages (avant, droite, haut depuis la tête, m) :
-- 1 = haut, à droite du montant ; 2 = bas, à gauche du montant (au-dessus du tableau de bord)
AS_TerminalTablet.PRESETS = { { 0.38, 0.49, -0.12 }, { 0.52, 0.24, -0.26 } }
AS_TerminalTablet.TEXT_MS = 250
AS_TerminalTablet.tablets = setmetatable({}, { __mode = "k" })   -- [véhicule] = { node, ... }
AS_TerminalTablet.textTimer = 0

local function log(fmt, ...)
    (AS.rawPrint or print)("[AS_TerminalTablet] " .. string.format(fmt, ...))
end

local function T(key) return L("vtpas_tm_" .. key) end

local function call(obj, name, ...)
    if obj == nil or type(obj[name]) ~= "function" then return nil end
    local ok, a, b, c, d = pcall(obj[name], obj, ...)
    if ok then return a, b, c, d end
    return nil
end

-------------------------------------------------------------------------------
-- Modèle 3D
-------------------------------------------------------------------------------
function AS_TerminalTablet:loadModel()
    if self.loading or self.template ~= nil then return end
    if g_i3DManager == nil or g_i3DManager.loadSharedI3DFileAsync == nil then return end
    self.loading = true
    local path = Utils.getFilename(self.FILE, AS_MOD_DIR)
    self.request = g_i3DManager:loadSharedI3DFileAsync(path, false, false, self.onModelLoaded, self, nil)
end

function AS_TerminalTablet:onModelLoaded(node, failedReason)
    self.loading = false
    if node == nil or node == 0 then
        log("ERREUR : tablette introuvable (%s)", tostring(failedReason))
        self.template = false
        return
    end
    local t = getChildAt(node, 0)
    if t == nil or t == 0 then t = node end
    unlink(t)
    self.template = t
    if node ~= t then delete(node) end
    log("modèle de la tablette chargé")
end

-------------------------------------------------------------------------------
-- Caméra intérieure : tête du conducteur
-------------------------------------------------------------------------------
local function insideCamera(v)
    local spec = v.spec_enterable
    if spec == nil or type(spec.cameras) ~= "table" then return nil end
    for _, cam in ipairs(spec.cameras) do
        if cam.isInside and (cam.rotateNode or cam.cameraPositionNode) ~= nil then return cam end
    end
    return nil
end

-- (31/10 soir) « Afficher sur : Écran du véhicule » : le terminal est posé sur l'écran d'origine
-- (37c) display : 1 tablette, 2 écran du véhicule, 3 les deux (écran du véhicule + tablette en plus).
-- forceTablet : pendant le placement / les réglages de la tablette en plus, on est en mode tablette
function AS_TerminalTablet:onVehicleScreen()
    if self.forceTablet then return false end
    local dsp = AS_Terminal ~= nil and AS_Terminal.settings ~= nil and AS_Terminal.settings.display or 1
    return dsp == 2 or dsp == 3
end

function AS_TerminalTablet:bothOn()
    return AS_Terminal ~= nil and AS_Terminal.settings ~= nil and AS_Terminal.settings.display == 3
end

-- appelle fn en mode tablette si l'écran est la tablette en plus
function AS_TerminalTablet:asTab(t, fn, ...)
    if t == nil or not t.asTablet then return fn(...) end
    local keep = self.forceTablet
    self.forceTablet = true
    local r = { pcall(fn, ...) }
    self.forceTablet = keep
    if not r[1] then error(r[2], 0) end
    return unpack(r, 2, table.maxn(r))
end

function AS_TerminalTablet:preset()
    local n = AS_Terminal ~= nil and AS_Terminal.settings ~= nil and AS_Terminal.settings.tabPreset or nil
    if n == nil or self.PRESETS[n] == nil then return nil end
    return n
end

-- réglages fins gardés par modèle ET par emplacement
local function modelKey(v)
    local file = tostring(v.configFileName or "?")
    file = file:match("([^/\\]+/[^/\\]+)$") or file
    if AS_TerminalTablet:onVehicleScreen() then return file .. "|veh" end
    return file .. "|tab" .. tostring(AS_TerminalTablet:preset() or "")
end

-- (31/10) la police 3D du jeu n'a pas les lettres accentuées : remplacées par la lettre simple
local ACCENTS = { ["à"]="a",["â"]="a",["ä"]="a",["á"]="a",["ç"]="c",["é"]="e",["è"]="e",["ê"]="e",["ë"]="e",
    ["î"]="i",["ï"]="i",["í"]="i",["ô"]="o",["ö"]="o",["ó"]="o",["ù"]="u",["û"]="u",["ü"]="u",["ú"]="u",["ÿ"]="y",
    ["À"]="A",["Â"]="A",["Ä"]="A",["Á"]="A",["Ç"]="C",["É"]="E",["È"]="E",["Ê"]="E",["Ë"]="E",["Î"]="I",["Ï"]="I",
    ["Ô"]="O",["Ö"]="O",["Ù"]="U",["Û"]="U",["Ü"]="U",["ß"]="ss",["œ"]="oe",["Œ"]="OE",["°"]="o",["’"]="'",["«"]='"',["»"]='"',
    -- (01/11) signes absents de la police 3D (affichés « ? » avant)
    ["×"]="x",["±"]="+-",["·"]="-",["–"]="-",["—"]="-",["…"]="...",["²"]="2",["³"]="3",["¹"]="1",["µ"]="u",["‘"]="'",["“"]='"',["”"]='"',["€"]="E",["≈"]="~",["→"]=">",["−"]="-",["←"]="<",["½"]="1/2" }
local function plain(str)
    if str == nil or not str:find("[\128-\255]") then return str end
    str = str:gsub("[\192-\255][\128-\191]*", function(ch) return ACCENTS[ch] or "?" end)
    return str
end
AS_TerminalTablet.plain = plain

AS_TerminalTablet.modelKeyOf = modelKey
-- (02/11) calage de l'écran du véhicule
-- par défaut, modèle par modèle (largeur / hauteur en %, décalage droite / haut en m), d'après les captures.
-- Un réglage fait à la main dans Réglages passe toujours devant.
-- (07/11) en plus : x / y / z = décalage droite / haut / avant (m), rz = rotation dans le plan de l'écran,
-- rx / ry = inclinaison haut-bas / gauche-droite (degrés) ; ceux-là s'AJOUTENT au réglage fait à la main
-- (sw / sh : remplacés par le réglage à la main). Seulement sur l'écran du véhicule.
AS_TerminalTablet.SCREEN_DEFAULTS = {
    ["magnumT4B/magnumT4B.xml"] = { sw = 104, sh = 103 },   -- 02/11 : bords de la vitre visibles en haut et à droite
    -- (07/11) écran PEINT (Datatronic sur le bras du montant droit) : le terminal se
    -- met sur la lampe d'écran, face à la tête, en 12" ; il dépassait du boîtier en bas à droite et couvrait les
    -- touches OK / retour / maison / menu ; la vitre est tournée de 2,5° (côté droit plus bas) -> calé dans la vitre
    ["series7S/series7S.xml"] = { sw = 96, sh = 88, y = 0.002, rz = -2.5 },
    -- (07/11) vitre d'origine visible sur 2 px en haut à droite = écran tourné d'environ 0,3°
    -- et 0,7 mm trop bas (mod FS25_claasAxion800)
    ["FS25_claasAxion800/axion800.xml"] = { rz = 0.3, y = 0.0007 },
}
function AS_TerminalTablet:screenDefault(v)
    local file = tostring(v ~= nil and v.configFileName or "?")
    file = file:match("([^/\\]+/[^/\\]+)$") or file
    return self.SCREEN_DEFAULTS[file]
end
-- calage par défaut du modèle, seulement quand le terminal est sur l'écran du véhicule
function AS_TerminalTablet:vehDefault(v)
    if not self:onVehicleScreen() then return nil end
    return self:screenDefault(v)
end
-- (01/11, étape 37) écrans en plus (2e, 3e) : gardés par modèle, quel que soit l'affichage choisi
local function extKey(v)
    local file = tostring(v.configFileName or "?")
    file = file:match("([^/\\]+/[^/\\]+)$") or file
    return file .. "|ext"
end
AS_TerminalTablet.extKeyOf = extKey

function AS_TerminalTablet:getOffset(v)
    local p = AS_Terminal.positions[modelKey(v)] or {}
    local d = self:vehDefault(v) or {}
    return (p.x or 0) + (d.x or 0), (p.y or 0) + (d.y or 0), (p.z or 0) + (d.z or 0)
end

-- taille (%) et inclinaison haut / bas, gauche / droite (degrés), gardées par modèle
function AS_TerminalTablet:getShape(v)
    local p = AS_Terminal.positions[modelKey(v)] or {}
    local d = self:vehDefault(v) or {}
    return p.s or 100, (p.rx or 0) + (d.rx or 0), (p.ry or 0) + (d.ry or 0)
end
-- rotation dans le plan de l'écran (réglage à la main + calage par défaut du modèle)
function AS_TerminalTablet:getRoll(v)
    local p = AS_Terminal.positions[modelKey(v)] or {}
    local d = self:vehDefault(v) or {}
    return (p.rz or 0) + (d.rz or 0)
end

function AS_TerminalTablet:getScale(v)
    local sz = self:getShape(v)
    return self.BASE * sz / 100
end

-- rotation du vecteur (x, y, z) autour de l'axe unitaire (ax, ay, az) (formule de Rodrigues)
local function rotate(x, y, z, ax, ay, az, deg)
    if deg == 0 then return x, y, z end
    local a = math.rad(deg)
    local c, sn = math.cos(a), math.sin(a)
    local d = (ax * x + ay * y + az * z) * (1 - c)
    local cx, cy, cz = ay * z - az * y, az * x - ax * z, ax * y - ay * x
    return x * c + cx * sn + ax * d, y * c + cy * sn + ay * d, z * c + cz * sn + az * d
end

-------------------------------------------------------------------------------
-- (31/10) place auto : repère les écrans de la cabine (affichages du jeu = dashboards,
-- et pièces nommées écran / moniteur / terminal...) et cherche, autour de l'emplacement
-- choisi, la place la plus proche qui n'en cache aucun vu depuis le siège.
-------------------------------------------------------------------------------
AS_TerminalTablet.AUTO_PLACE = true
AS_TerminalTablet.SCREEN_WORDS = { "screen", "display", "monitor", "terminal", "isobus", "gps", "ecran", "bildschirm", "tablet", "armrestdisplay" }
AS_TerminalTablet.AUTO_MARGIN = math.rad(9)   -- un écran autour du point repéré
AS_TerminalTablet.AUTO_MAX_SCREENS = 12        -- au-delà : repérage pas fiable

local function collectScreenNodes(v, out, skip)
    -- (31/10 soir) plus les affichages du tableau de bord (aiguilles, voyants) : bien trop nombreux (81 dans le Patriot)
    -- pièces du modèle nommées comme des écrans
    if getNumOfChildren == nil or getChildAt == nil or getName == nil then return end
    local count = 0
    local function walk(n, depth)
        if count > 6000 or depth > 14 or n == skip then return end
        count = count + 1
        local okN, name = pcall(getName, n)
        if okN and type(name) == "string" then
            local low = name:lower()
            for _, w in ipairs(AS_TerminalTablet.SCREEN_WORDS) do
                if low:find(w, 1, true) then out[#out + 1] = n break end
            end
        end
        local okC, nc = pcall(getNumOfChildren, n)
        if okC and type(nc) == "number" then
            for i = 0, nc - 1 do walk(getChildAt(n, i), depth + 1) end
        end
    end
    if v.rootNode ~= nil then walk(v.rootNode, 0) end
end

function AS_TerminalTablet:autoOffset(v, parent, hx, hy, hz, F, R, Uv, bf, br, bu, skip)
    local nodes = {}
    collectScreenNodes(v, nodes, skip)
    -- points des écrans vus depuis la tête : avant / droite / haut
    local pts = {}
    for _, n in ipairs(nodes) do
        local ok, x, y, z = pcall(localToLocal, n, parent, 0, 0, 0)
        if ok and x ~= nil then
            local dx, dy, dz = x - hx, y - hy, z - hz
            local f = dx * F[1] + dy * F[2] + dz * F[3]
            local r = dx * R[1] + dy * R[2] + dz * R[3]
            local u = dx * Uv[1] + dy * Uv[2] + dz * Uv[3]
            local dist = math.sqrt(f * f + r * r + u * u)
            if f > 0.1 and dist < 1.8 then
                pts[#pts + 1] = { math.atan2(r, f), math.atan2(u, math.sqrt(f * f + r * r)) }
            end
        end
    end
    if #pts == 0 then return nil end
    -- trop de pièces « écran » : repérage pas fiable, on ne bouge pas la tablette
    if #pts > self.AUTO_MAX_SCREENS then
        log("place auto %s : %d pièces « écran », repérage pas fiable, tablette laissée à sa place", tostring(v.getFullName ~= nil and v:getFullName() or "?"), #pts)
        return nil
    end
    local k = self:getScale(v)
    local hw, hh = self.SW * k * 0.5, self.SH * k * 0.5
    local function free(f, r, u)
        local d = math.sqrt(f * f + r * r + u * u)
        local az, el = math.atan2(r, f), math.atan2(u, math.sqrt(f * f + r * r))
        local haz, hel = math.atan(hw / d) + self.AUTO_MARGIN, math.atan(hh / d) + self.AUTO_MARGIN
        for _, p in ipairs(pts) do
            if math.abs(p[1] - az) < haz and math.abs(p[2] - el) < hel then return false end
        end
        return true
    end
    if free(bf, br, bu) then
        log("place auto %s : %d écran(s) repéré(s), place choisie libre", tostring(v.getFullName ~= nil and v:getFullName() or "?"), #pts)
        return nil
    end
    -- place libre la plus proche (pas de 4 cm, jusqu'à 40 cm)
    local best, bestD
    for dr = -0.40, 0.401, 0.04 do
        for du = -0.32, 0.321, 0.04 do
            for df = -0.12, 0.121, 0.06 do
                local d2 = dr * dr + du * du + df * df * 0.5
                if (bestD == nil or d2 < bestD) and bf + df > 0.2 and (br <= 0 or br + dr > 0.12) and free(bf + df, br + dr, bu + du) then
                    best, bestD = { math.floor(dr * 100 + 0.5) / 100 + 0, math.floor(du * 100 + 0.5) / 100 + 0, math.floor(df * 100 + 0.5) / 100 + 0 }, d2
                end
            end
        end
    end
    log("place auto %s : %d écran(s) repéré(s), décalage %s", tostring(v.getFullName ~= nil and v:getFullName() or "?"), #pts,
        best ~= nil and string.format("droite %+.0f cm, haut %+.0f cm, avant %+.0f cm", best[1] * 100, best[2] * 100, best[3] * 100) or "aucune place libre")
    return best
end

-- (31/10 soir) écrans d'origine du véhicule : vraies formes 3D (la pièce nommée comme un écran
-- ou les formes rangées dessous), devant le conducteur ; triés (sous les yeux et à droite d'abord).
AS_TerminalTablet.VEH_WORDS = { "screen", "display", "monitor", "terminal", "bildschirm", "ecran", "isobus",
    "cebis", "cemis", "cemos", "pro700", "pro1200", "afs", "fendtone", "commandcenter", "gen4", "g4display", "tablet", "navi", "gps" }
AS_TerminalTablet.VEH_SKIP = { "windscreen", "wiper", "sound", "glass", "light", "lamp", "needle", "pointer", "glow",
    "number", "num_", "digit", "symbol", "icon", "button", "switch", "mirror", "camera", "dark", "starting", "seat", "led",
    "starfire", "receiver", "antenna", "antenne", "dome" }
-- (31/10 soir) vraies proportions des écrans
-- (largeur / hauteur), mesurées sur les pages des textures du jeu (data/vehicles/*/shared/displays) :
-- Fendt ONE, Case / NH / Steyr, Claas CEBIS / CEMIS, Valtra = 16:10 ; Deutz iMonitor et John Deere
-- 4640 (G4) = 4:3 ; John Deere G5 ≈ 1,72 ; montants Case / Steyr = en hauteur. Le plus précis d'abord.
-- Écran inconnu : 16:10 (réglages largeur / hauteur par modèle en plus).
-- 3e valeur (01/11) : taille de la vitre par
-- rapport à la diagonale de la pièce (sa sphère englobante prend aussi le bord) ; Fendt One ≈ 12 pouces
AS_TerminalTablet.SCREEN_ASPECT = {
    { "fendtone", 1.60, 0.88 },
    { "apillarscreencaseih", 0.50 }, { "apillarscreensteyr", 0.63 },
    { "mainscreencnh", 1.60 }, { "mainscreensteyr", 1.60 }, { "mainscreencase", 1.60 }, { "mainscreennh", 1.60 },
    { "gpsscreen", 1.60 }, { "combinescreen", 1.60 },
    { "mainscreen_decal", 1.333 }, { "mainscreenstartscreen", 1.333 },      -- Deutz-Fahr iMonitor
    { "cebis", 1.60 }, { "cemis", 1.60 },
    { "g4display_mainpage", 1.333 }, { "g4display_gpspage", 1.333 },
    { "g5display_defaultpage", 1.72 },
    { "valtrasmarttouch", 1.65 },
}
AS_TerminalTablet.ASPECT_DEFAULT = 1.60
function AS_TerminalTablet:screenAspect(name)
    local nm = type(name) == "string" and name:lower() or ""
    for _, e in ipairs(self.SCREEN_ASPECT) do
        if nm:find(e[1], 1, true) then return e[2], true, e[3] or 1 end
    end
    return self.ASPECT_DEFAULT, false, 1
end
local function isShape(n)
    if getHasClassId == nil or ClassIds == nil or ClassIds.SHAPE == nil then return false end
    local ok, r = pcall(getHasClassId, n, ClassIds.SHAPE)
    return ok and r == true
end
-- (31/10 soir) vraiment visible : la pièce et tous ses parents jusqu'au véhicule
local function shownUpTo(n, top)
    local k = 0
    while n ~= nil and n ~= 0 and k < 40 do
        local okV, vis = pcall(getVisibility, n)
        if okV and vis == false then return false end
        if n == top then return true end
        local okP, p = pcall(getParent, n)
        if not okP then return true end
        n = p
        k = k + 1
    end
    return true
end
-- (31/10 soir) pièce chargée d'un autre fichier .i3d accroché au véhicule par un autre mod (realGPS : « pdaMap.i3d »)
function AS_TerminalTablet:fromOtherFile(n, v)
    local k = 0
    while n ~= nil and n ~= 0 and n ~= v.rootNode and k < 40 do
        local ok, nm = pcall(getName, n)
        if ok and type(nm) == "string" and nm:lower():sub(-4) == ".i3d" then return true end
        local okP, p = pcall(getParent, n)
        if not okP then return false end
        n, k = p, k + 1
    end
    return false
end

function AS_TerminalTablet:findVehicleScreens(v, parent, hx, hy, hz, F, R, Uv, skip)
    if getNumOfChildren == nil or getChildAt == nil or getName == nil or getShapeBoundingSphere == nil then return {} end
    local list, seen, count = {}, {}, 0
    local big = {}                                   -- pour le log : grandes formes devant, quel que soit leur nom
    local rej = {}                                   -- pour le log : pièces nommées écran mais de taille refusée
    local all = {}                                   -- (31/10 soir) toutes les formes des écrans, pour cacher l'image d'origine
    local function nameOf(n) local ok, nm = pcall(getName, n) return ok and type(nm) == "string" and nm or "" end
    local function skipName(low)
        for _, w in ipairs(self.VEH_SKIP) do if low:find(w, 1, true) then return true end end
        return false
    end
    local function measure(n)
        if seen[n] or not isShape(n) then return nil end
        seen[n] = true
        local okB, cx, cy, cz, rad = pcall(getShapeBoundingSphere, n)
        if not okB or rad == nil then return nil end
        local ok, x, y, z = pcall(localToLocal, n, parent, cx, cy, cz)
        if not ok or x == nil then return nil end
        -- rayon à l'échelle réelle de la pièce
        local okS, x1, y1, z1 = pcall(localToLocal, n, parent, cx + 1, cy, cz)
        local sc = 1
        if okS and x1 ~= nil then
            sc = math.sqrt((x1 - x) ^ 2 + (y1 - y) ^ 2 + (z1 - z) ^ 2)
            if sc > 0.01 and sc < 100 then rad = rad * sc end
        end
        local dx, dy, dz = x - hx, y - hy, z - hz
        local f = dx * F[1] + dy * F[2] + dz * F[3]
        local r = dx * R[1] + dy * R[2] + dz * R[3]
        local u = dx * Uv[1] + dy * Uv[2] + dz * Uv[3]
        local dist = math.sqrt(dx * dx + dy * dy + dz * dz)
        if f < 0.15 or dist > 1.6 then return nil end
        -- (31/10 soir) les écrans cachés comptent aussi (le jeu cache certains écrans tant que le moteur
        -- est coupé, ou selon la config) : ils passent juste après les écrans visibles
        return { x = x, y = y, z = z, lx = cx, ly = cy, lz = cz, rad = rad, node = n, f = f, r = r, u = u, dist = dist,
            name = nameOf(n), hidden = not shownUpTo(n, v.rootNode), collapsed = sc < 0.05 }
    end
    local zero = 0
    local function add(c)
        if c == nil then return end
        -- (31/10 soir) copie réduite à taille zéro (Fendt : copies claire / sombre, le mode sombre réduit
        -- l'une des deux) : jamais choisie, elle serait invisible ; elle reste dans « all » pour être cachée
        if c.rad < 0.05 or c.rad > 0.45 then
            if #rej < 12 and not c.collapsed then rej[#rej + 1] = c end
            return
        end
        if c.collapsed and self.FIX_SCALE then zero = zero + 1 return end
        local low = c.name:lower()
        -- (31/10 soir) plus de 30 cm au-dessus des yeux : antenne, gyrophare… jamais un écran (Fendt 207 V : écran du toit à +20)
        if c.u > 0.30 then
            if #rej < 12 then rej[#rej + 1] = c end
            return
        end
        -- (31/10 soir) l'image affichée sur l'écran (« …Display…_decal ») = la surface exacte de l'écran
        local surface = low:find("decal", 1, true) ~= nil
        -- (31/10 soir) le plus GRAND écran d'abord (rayon au carré) ; le combiné droit devant, derrière le
        -- volant, passe après ; un écran posé par un autre mod (realGPS…) en dernier
        local cluster = math.abs(c.r) < 0.15 and c.u < -0.25
        c.foreign = self:fromOtherFile(c.node, v)
        c.score = c.rad * c.rad * (surface and 4 or 1) * (c.r > 0 and 1.3 or 1) * (c.u > -0.05 and 0.7 or 1) / (0.5 + c.dist)
            * (c.hidden and 0.5 or 1) * (cluster and 0.5 or 1) * (c.foreign and 0.2 or 1)
        -- doublons au même endroit (versions « Dark », « MC », pièces d'un même écran) : on garde le meilleur
        for i, o in ipairs(list) do
            local d = math.sqrt((o.x - c.x) ^ 2 + (o.y - c.y) ^ 2 + (o.z - c.z) ^ 2)
            if d < 0.08 then
                if c.score > o.score then list[i] = c end
                return
            end
        end
        list[#list + 1] = c
    end
    local function shapesUnder(n, depth)
        if depth > 4 or n == skip then return end
        local low = nameOf(n):lower()
        local c = measure(n)
        if c ~= nil then
            all[#all + 1] = c
            if not skipName(low) then add(c) end
        end
        local okC, nc = pcall(getNumOfChildren, n)
        if okC and type(nc) == "number" then
            for i = 0, nc - 1 do shapesUnder(getChildAt(n, i), depth + 1) end
        end
    end
    local MAXN = 20000
    local function walk(n, depth)
        if n == nil or n == 0 or count > MAXN or depth > 24 or n == skip then return end
        count = count + 1
        local low = nameOf(n):lower()
        local word = false
        for _, w in ipairs(self.VEH_WORDS) do
            if low:find(w, 1, true) then word = true break end
        end
        local hit = word and not skipName(low)
        if hit then
            shapesUnder(n, 0)
        elseif word and low:find("decal", 1, true) and isShape(n) then
            -- variante d'un écran (« …DisplayDark_decal ») : pas un candidat, mais à cacher avec lui
            local c = measure(n)
            if c ~= nil then all[#all + 1] = c end
        elseif #big < 60 and isShape(n) then
            local c = measure(n)
            seen[n] = nil
            if c ~= nil and c.rad >= 0.08 and c.rad <= 0.4 then big[#big + 1] = c end
        end
        local okC, nc = pcall(getNumOfChildren, n)
        if okC and type(nc) == "number" then
            for i = 0, nc - 1 do walk(getChildAt(n, i), depth + 1) end
        end
    end
    -- (31/10 soir) écran PEINT dans la planche d'autocollants (MF 7S, NH FR 780) : pas de pièce à part ; Giants pose
    -- une lumière « interiorScreenLight » devant l'écran : le terminal se met là (taille 12 pouces, réglable)
    local function lights(n, depth)
        if n == nil or n == 0 or depth > 24 then return end
        local low = nameOf(n):lower()
        if low:find("interiorscreenlight", 1, true) then
            local ok, x, y, z = pcall(localToLocal, n, parent, 0, 0, 0)
            if ok and x ~= nil then
                local dx, dy, dz = x - hx, y - hy, z - hz
                local f = dx * F[1] + dy * F[2] + dz * F[3]
                local r = dx * R[1] + dy * R[2] + dz * R[3]
                local u = dx * Uv[1] + dy * Uv[2] + dz * Uv[3]
                local dist = math.sqrt(dx * dx + dy * dy + dz * dz)
                if f > 0.15 and dist < 1.4 and u <= 0.30 then
                    local okP, pn = pcall(getParent, n)
                    local c = { x = x, y = y, z = z, lx = 0, ly = 0, lz = 0, rad = 0.15, node = n, f = f, r = r, u = u, dist = dist,
                        name = nameOf(n), hidden = false, painted = true, anchorNode = okP and pn or nil }
                    c.score = 0.0225 * (r > 0 and 1.3 or 1) / (0.5 + dist) * 0.3
                    local dup = false
                    for _, o in ipairs(list) do
                        if math.sqrt((o.x - x) ^ 2 + (o.y - y) ^ 2 + (o.z - z) ^ 2) < 0.25 then dup = true break end
                    end
                    if not dup then list[#list + 1] = c end
                end
            end
        end
        local okC, nc = pcall(getNumOfChildren, n)
        if okC and type(nc) == "number" then
            for i = 0, nc - 1 do lights(getChildAt(n, i), depth + 1) end
        end
    end
    -- (31/10 soir) tout le véhicule : la pièce principale puis les autres composants
    local done = {}
    if v.rootNode ~= nil then walk(v.rootNode, 0); done[v.rootNode] = true end
    if type(v.components) == "table" then
        for _, comp in ipairs(v.components) do
            if comp.node ~= nil and not done[comp.node] then walk(comp.node, 0); done[comp.node] = true end
        end
    end
    if v.rootNode ~= nil then pcall(lights, v.rootNode, 0) end
    table.sort(list, function(a, b) return a.score > b.score end)
    list.all = all
    -- le log liste ce qui a été vu, pour corriger vite un mauvais choix
    local name = tostring(v.getFullName ~= nil and v:getFullName() or "?")
    if count > MAXN then log("recherche d'écran %s : arrêtée après %d pièces", name, MAXN) end
    if zero > 0 then log("recherche d'écran %s : %d copie(s) d'écran réduite(s) à zéro ignorée(s) (mode clair / sombre)", name, zero) end
    for i, c in ipairs(list) do
        if i > 8 then break end
        log("écran candidat %s #%d : %s (rayon %.0f cm, avant %.0f, droite %.0f, haut %.0f cm)%s%s%s", name, i, c.name, c.rad * 100, c.f * 100, c.r * 100, c.u * 100,
            c.hidden and " caché" or "", c.painted and " (écran peint, repère lumière)" or "", c.foreign and " (autre mod)" or "")
    end
    if #list == 0 then
        log("aucun écran nommé %s (%d pièces lues)", name, count)
        for i, c in ipairs(rej) do
            log("  pièce nommée écran refusée (taille) : %s (rayon %.0f cm, avant %.0f, droite %.0f, haut %.0f cm)", c.name, c.rad * 100, c.f * 100, c.r * 100, c.u * 100)
        end
        table.sort(big, function(a, b) return a.dist < b.dist end)
        for i, c in ipairs(big) do
            if i > 20 then break end
            log("  grande pièce devant : %s (rayon %.0f cm, avant %.0f, droite %.0f, haut %.0f cm)%s", c.name, c.rad * 100, c.f * 100, c.r * 100, c.u * 100, c.hidden and " caché" or "")
        end
    end
    return list
end

-- (31/10 soir) plan de l'écran d'origine. Si la pièce (ou son parent) est tournée dans le véhicule,
-- son axe le plus tourné vers le conducteur est la face de l'écran ; une pièce posée droite ne dit rien
-- de son plan : le terminal est alors tourné vers la tête (comme avant).
local function norm3(x, y, z)
    local l = math.sqrt(x * x + y * y + z * z)
    if l < 1e-6 then return 0, 0, 0 end
    return x / l, y / l, z / l
end
local function dot3(a, b) return a[1] * b[1] + a[2] * b[2] + a[3] * b[3] end
function AS_TerminalTablet:screenFrame(n, parent, d, F, R, U)
    local node = n
    for level = 0, 1 do
        if node == nil or node == 0 then break end
        local axes, straight = {}, true
        for i, a in ipairs({ { 1, 0, 0 }, { 0, 1, 0 }, { 0, 0, 1 } }) do
            local ok, x, y, z = pcall(localDirectionToLocal, node, parent, a[1], a[2], a[3])
            if not ok or x == nil then axes = nil break end
            x, y, z = norm3(x, y, z)
            axes[i] = { x, y, z }
            if math.max(math.abs(dot3(axes[i], F)), math.abs(dot3(axes[i], R)), math.abs(dot3(axes[i], U))) < 0.995 then straight = false end
        end
        if axes ~= nil and not straight then
            local bi, bd = 1, 0
            for i = 1, 3 do
                local k = math.abs(dot3(axes[i], d))
                if k > bd then bi, bd = i, k end
            end
            if bd >= 0.5 then
                local s = dot3(axes[bi], d) >= 0 and 1 or -1
                local nrm = { axes[bi][1] * s, axes[bi][2] * s, axes[bi][3] * s }
                -- (31/10 soir) haut de l'écran : l'autre axe le plus proche du haut VU PAR LE CONDUCTEUR (haut du
                -- véhicule rabattu perpendiculairement au regard) ; avant : vers l'avant pour un écran couché, d'où
                -- l'écran du toit du Fendt 207 V à l'envers
                local ud0 = dot3(U, d)
                local vx, vy, vz = norm3(U[1] - ud0 * d[1], U[2] - ud0 * d[2], U[3] - ud0 * d[3])
                local ref = (vx ~= 0 or vy ~= 0 or vz ~= 0) and { vx, vy, vz } or U
                local ui, ud = nil, -1
                for i = 1, 3 do
                    if i ~= bi then
                        local k = math.abs(dot3(axes[i], ref))
                        if k > ud then ui, ud = i, k end
                    end
                end
                local us = dot3(axes[ui], ref) >= 0 and 1 or -1
                local up = { axes[ui][1] * us, axes[ui][2] * us, axes[ui][3] * us }
                return nrm, up, level == 0 and "piece" or "parent", math.deg(math.acos(math.min(1, dot3(nrm, d))))
            end
        end
        local okP, p = pcall(getParent, node)
        node = okP and p or nil
    end
    return d, U, "tete", 0
end

-- (31/10 soir) pièce où accrocher le terminal : le parent de l'écran d'origine (accoudoir, siège ou cabine),
-- donc il suit l'écran. Jamais une pièce cachée (elle cacherait le terminal) : on remonte alors d'un cran.
local function isAncestorOf(a, n)
    local k = 0
    while n ~= nil and n ~= 0 and k < 40 do
        if n == a then return true end
        local ok, p = pcall(getParent, n)
        if not ok then return false end
        n = p
        k = k + 1
    end
    return false
end

local function effScale(n, ref)
    local ok0, x0, y0, z0 = pcall(localToLocal, n, ref, 0, 0, 0)
    local ok1, x1, y1, z1 = pcall(localToLocal, n, ref, 1, 0, 0)
    local ok2, x2, y2, z2 = pcall(localToLocal, n, ref, 0, 1, 0)
    if not ok0 or x0 == nil then return 1 end
    local s1 = (ok1 and x1 ~= nil) and math.sqrt((x1 - x0) ^ 2 + (y1 - y0) ^ 2 + (z1 - z0) ^ 2) or 1
    local s2 = (ok2 and x2 ~= nil) and math.sqrt((x2 - x0) ^ 2 + (y2 - y0) ^ 2 + (z2 - z0) ^ 2) or 1
    return math.min(s1, s2)
end
AS_TerminalTablet.effScale = effScale

-- (31/10 soir) pièces que le véhicule réduit ou agrandit par animation (Fendt 700 Gen7 / 900 Gen7 :
-- « darkMode » passe d'une copie de l'écran à l'autre en réduisant la copie inutile à zéro)
function AS_TerminalTablet:scaleAnimatedNodes(v)
    self.scaleSets = self.scaleSets or setmetatable({}, { __mode = "k" })
    local set = self.scaleSets[v]
    if set ~= nil then return set end
    set = {}
    local spec = v.spec_animatedVehicle
    if type(spec) == "table" and type(spec.animations) == "table" then
        for _, anim in pairs(spec.animations) do
            if type(anim) == "table" and type(anim.parts) == "table" then
                for _, part in pairs(anim.parts) do
                    if type(part) == "table" and part.node ~= nil then
                        local sc = part.startScale ~= nil or part.endScale ~= nil
                        if not sc and type(part.animationValues) == "table" then
                            for _, av in pairs(part.animationValues) do
                                local nm = type(av) == "table" and (av.name or av.attributeName or av.attribute) or nil
                                if type(nm) == "string" and nm:lower():find("scale", 1, true) then sc = true end
                            end
                        end
                        if sc then set[part.node] = true end
                    end
                end
            end
        end
    end
    self.scaleSets[v] = set
    return set
end

function AS_TerminalTablet:screenAnchor(v, n, parent, avoid)
    local animated = self:scaleAnimatedNodes(v)
    local okP, a = pcall(getParent, n)
    local k = 0
    while okP and a ~= nil and a ~= 0 and k < 30 do
        local usable = shownUpTo(a, v.rootNode) and (not self.FIX_SCALE or effScale(a, parent) > 0.05) and not (avoid ~= nil and avoid[a])
        if usable then
            -- jamais sous une pièce animée en taille : on remonte au-dessus de la plus haute
            local m, kk, top = a, 0, nil
            while m ~= nil and m ~= 0 and m ~= v.rootNode and m ~= parent and kk < 40 do
                if animated[m] then top = m end
                local okM, pm = pcall(getParent, m)
                if not okM then break end
                m, kk = pm, kk + 1
            end
            if top == nil or not self.FIX_SCALE then return a end
            a = top
        end
        if a == v.rootNode then break end
        okP, a = pcall(getParent, a)
        k = k + 1
    end
    return parent
end

-- (31/10 soir) ce qu'il faut cacher de l'écran d'origine : l'image choisie, ses copies (claire, sombre,
-- « MC »…) et tout ce qui est posé sur la vitre (chiffres, icônes, jauges du tableau de bord), par groupe
-- entier quand tout le groupe est sur la vitre. Jamais le boîtier (derrière la vitre ou plus grand que
-- l'écran), jamais une pièce qui porte l'écran choisi ou notre terminal.
function AS_TerminalTablet:buildHideList(v, tab, c, parent, anchor, nrm, src, sx, sy, sz, rect)
    local hide, inHide = {}, {}
    local R0 = math.max(0.08, c.rad * 0.7)
    local plane = src ~= "tete"
    local function nameLow(n) local ok, nm = pcall(getName, n) return ok and type(nm) == "string" and nm:lower() or "" end
    local function onGlass(x, y, z, rad, decal, collapsed, loose)
        local dx, dy, dz = x - sx, y - sy, z - sz
        local d = math.sqrt(dx * dx + dy * dy + dz * dz)
        -- pièce réduite à zéro (copie cachée par le mode clair / sombre, chiffre inutilisé) : jugée
        -- à sa place, comme une petite pièce (avant : rayon R0 autour du centre, les chiffres dans les coins restaient)
        if collapsed then rad, decal = 0, false end
        if decal and rad <= c.rad * 1.3 and d < R0 then return true end
        if rad > c.rad * 0.9 then return false end
        -- (31/10 soir) chiffres du tableau de bord dans les coins (Grégoire : « 850 » restait) : un peu plus large
        local reach = loose and 1.15 or 1.0
        if not plane then return (loose or rad <= c.rad * 0.5) and d <= c.rad * reach end
        local dep = dx * nrm[1] + dy * nrm[2] + dz * nrm[3]
        if dep < -0.004 or dep > 0.02 then return false end
        return math.sqrt(math.max(0, d * d - dep * dep)) <= c.rad * (loose and 1.15 or 1.05)
    end
    local memoS = {}
    local function shapeOk(n)
        if memoS[n] ~= nil then return memoS[n] end
        local r = false
        local okB, cx, cy, cz, rad = pcall(getShapeBoundingSphere, n)
        if okB and rad ~= nil then
            local ok, x, y, z = pcall(localToLocal, n, parent, cx, cy, cz)
            local okS, x1, y1, z1 = pcall(localToLocal, n, parent, cx + 1, cy, cz)
            if ok and x ~= nil then
                local sc = (okS and x1 ~= nil) and math.sqrt((x1 - x) ^ 2 + (y1 - y) ^ 2 + (z1 - z) ^ 2) or 1
                r = onGlass(x, y, z, (sc > 0.01 and sc < 100) and rad * sc or rad, nameLow(n):find("decal", 1, true) ~= nil, sc < 0.05)
            end
        end
        memoS[n] = r
        return r
    end
    local memoT = {}
    local function subtreeOk(r)
        if memoT[r] ~= nil then return memoT[r] end
        local count, ok = 0, true
        local function rec(n, depth)
            if not ok or n == nil or n == 0 then return end
            count = count + 1
            if count > 400 or depth > 12 or n == tab.node then ok = false return end
            if isShape(n) and not shapeOk(n) then ok = false return end
            local okC, nc = pcall(getNumOfChildren, n)
            if okC and type(nc) == "number" then
                for i = 0, nc - 1 do
                    local okA, ch = pcall(getChildAt, n, i)
                    if okA then rec(ch, depth + 1) end
                end
            end
        end
        rec(r, 0)
        memoT[r] = ok
        return ok
    end
    local function protect(n) return n == anchor or n == tab.node or isAncestorOf(n, c.node) or isAncestorOf(n, anchor) end
    local function addRoot(n)
        if n == nil or n == 0 or protect(n) then return end
        local r, k = n, 0
        while k < 8 do
            local okP, p = pcall(getParent, r)
            if not okP or p == nil or p == 0 or p == parent or p == v.rootNode or protect(p) or not subtreeOk(p) then break end
            r, k = p, k + 1
        end
        if not inHide[r] then inHide[r] = true hide[#hide + 1] = r end
    end
    -- l'image choisie elle-même
    inHide[c.node] = true
    hide[1] = c.node
    -- les pièces des écrans (copies, images posées dessus, contenu)
    for _, o in ipairs(tab.vehList ~= nil and tab.vehList.all or {}) do
        if o.node ~= c.node and not inHide[o.node] and isShape(o.node) and shapeOk(o.node) then addRoot(o.node) end
    end
    -- les affichages du tableau de bord du véhicule posés sur cet écran (chiffres, textes, voyants, jauges)
    local spec = v.spec_dashboard
    if type(spec) == "table" then
        local seen = {}
        local function dash(d)
            if type(d) ~= "table" then return end
            for _, f in ipairs({ "node", "numbers", "textNode" }) do
                local n = d[f]
                local okE, ex = false, false
                if n ~= nil and n ~= 0 and (type(n) == "number" or type(n) == "table") and not seen[n] then
                    okE, ex = pcall(entityExists, n)
                end
                if okE and ex then
                    seen[n] = true
                    local ok, x, y, z = pcall(localToLocal, n, parent, 0, 0, 0)
                    if ok and x ~= nil and not protect(n) then
                        local okG
                        if isShape(n) then okG = shapeOk(n) else okG = onGlass(x, y, z, 0, false, effScale(n, parent) < 0.05, true) end
                        if okG and subtreeOk(n) then addRoot(n) end
                    end
                end
            end
        end
        for _, key in ipairs({ "dashboards", "tickDashboards", "groupDashboards" }) do
            local l = spec[key]
            if type(l) == "table" then
                for _, d in pairs(l) do
                    if type(d) == "table" and d.node == nil and d.numbers == nil and d.textNode == nil then
                        for _, dd in pairs(d) do dash(dd) end
                    else
                        dash(d)
                    end
                end
            end
        end
    end
    -- (31/10 soir) « 100 », « 99 % » et la barre AdBlue restaient sur l'Axion : TOUT ce qui est petit
    -- et posé à plat sur la vitre, dans le rectangle de l'écran, est caché, quel que soit son nom, même s'il est
    -- éteint maintenant (le jeu allume ces chiffres au démarrage du moteur, ils sont alors recachés).
    -- Pour le log : ce qui reste visible sur la vitre ou la couvre (traits, cadres décoratifs).
    tab.vehLeft, tab.vehGlass = nil, 0
    if plane then
        local hidden = {}
        for _, n in ipairs(hide) do hidden[n] = true end
        local up = rect ~= nil and rect.up or nil
        local rgt = nil
        if up ~= nil then
            local ax, ay, az = norm3(up[2] * nrm[3] - up[3] * nrm[2], up[3] * nrm[1] - up[1] * nrm[3], up[1] * nrm[2] - up[2] * nrm[1])
            rgt = { ax, ay, az }
        end
        local left, count, glass = {}, 0, {}
        local function scan(n, depth, off)
            if n == nil or n == 0 or count > 20000 or depth > 24 or n == tab.node then return end
            count = count + 1
            if hidden[n] then return end
            local okV, vis = pcall(getVisibility, n)
            off = off or (okV and vis == false)
            if isShape(n) and n ~= c.node then
                local okB, cx, cy, cz, rad = pcall(getShapeBoundingSphere, n)
                if okB and rad ~= nil then
                    local ok, x, y, z = pcall(localToLocal, n, parent, cx, cy, cz)
                    local okS, x1, y1, z1 = pcall(localToLocal, n, parent, cx + 1, cy, cz)
                    if ok and x ~= nil then
                        local sc = (okS and x1 ~= nil) and math.sqrt((x1 - x) ^ 2 + (y1 - y) ^ 2 + (z1 - z) ^ 2) or 1
                        local r = (sc > 0.01 and sc < 100) and rad * sc or (sc <= 0.01 and 0 or rad)
                        local dx, dy, dz = x - sx, y - sy, z - sz
                        local d = math.sqrt(dx * dx + dy * dy + dz * dz)
                        local dep = dx * nrm[1] + dy * nrm[2] + dz * nrm[3]
                        local lat = math.sqrt(math.max(0, d * d - dep * dep))
                        local inside
                        if rgt ~= nil then
                            local pu = dx * up[1] + dy * up[2] + dz * up[3]
                            local pr = dx * rgt[1] + dy * rgt[2] + dz * rgt[3]
                            inside = math.abs(pr) <= rect.hw * 1.06 and math.abs(pu) <= rect.hh * 1.06
                        else
                            inside = lat <= c.rad * 1.05
                        end
                        -- (02/11, Magnum T4B) l'écran d'un autre mod (FS25_realGPS « plane ») collé à la vitre et centré
                        -- dépassait autour du terminal : caché aussi, même s'il est plus grand que l'écran
                        local overlay = r <= c.rad * 1.6 and math.abs(dep) <= 0.005 and lat <= 0.03
                        if ((r <= c.rad * 0.6 and dep >= -0.006 and dep <= 0.02 and inside) or overlay) and not protect(n) then
                            glass[#glass + 1] = n
                        elseif not off and #left < 15 and ((lat <= c.rad * 1.3 and dep > -0.01 and dep < 0.05) or (r > c.rad and d < r and nameLow(n):find("decal", 1, true))) then
                            local okN, nm = pcall(getName, n)
                            left[#left + 1] = string.format("%s (rayon %.0f cm, devant %.0f mm, à %.0f cm du centre)", okN and tostring(nm) or "?", r * 100, dep * 1000, lat * 100)
                        end
                    end
                end
            end
            local okC, nc = pcall(getNumOfChildren, n)
            if okC and type(nc) == "number" then
                for i = 0, nc - 1 do
                    local okA, ch = pcall(getChildAt, n, i)
                    if okA then scan(ch, depth + 1, off) end
                end
            end
        end
        local done = {}
        if v.rootNode ~= nil then scan(v.rootNode, 0, false) done[v.rootNode] = true end
        if type(v.components) == "table" then
            for _, comp in ipairs(v.components) do
                if comp.node ~= nil and not done[comp.node] then scan(comp.node, 0, false) done[comp.node] = true end
            end
        end
        local before = #hide
        for _, n in ipairs(glass) do addRoot(n) end
        tab.vehGlass = #hide - before
        tab.vehLeft = left
    end
    return hide
end

-- (31/10 soir) nouvelle recherche des pièces posées sur la vitre (chiffres allumés au démarrage du moteur)
function AS_TerminalTablet:rescanGlass(v, tab)
    local x = tab.vehCtx
    if x == nil or tab.veh ~= x.c or x.c == nil then return end
    local okC, sx, sy, sz = pcall(localToLocal, x.c.node, x.parent, x.c.lx or 0, x.c.ly or 0, x.c.lz or 0)
    if not okC or sx == nil then return end
    local before = #(tab.vehHide or {})
    local ok, hide = pcall(self.buildHideList, self, v, tab, x.c, x.parent, x.anchor, x.nrm, x.src, sx, sy, sz, x.rect)
    if not ok or type(hide) ~= "table" then
        log("ERREUR nouvelle recherche sur la vitre : %s", tostring(hide))
        return
    end
    tab.vehHide = hide
    if #hide > before then
        local names = {}
        for i = before + 1, math.min(#hide, before + 14) do
            local okM, nm = pcall(getName, hide[i])
            names[#names + 1] = okM and tostring(nm) or "?"
        end
        log("écran du véhicule %s : %d pièce(s) de plus cachée(s) sur la vitre : %s", tostring(call(v, "getFullName") or "?"), #hide - before, table.concat(names, ", "))
    end
    if self:screen3dOn() then self:hideOriginal(tab) end
end

-- boîtier, support et cadre de la tablette : cachés quand le terminal est sur l'écran du véhicule
-- (31/10 soir) pas de cadre sur les écrans intégrés, la page prend toute la place
function AS_TerminalTablet:setBodyVisible(tab, on)
    if tab.bodyVisible == on then return end
    tab.bodyVisible = on
    for _, name in ipairs({ "corps", "support", "cadre" }) do
        local okC, c = pcall(getChild, tab.node, name)
        if okC and c ~= nil and c ~= 0 then pcall(setVisibility, c, on) end
    end
end

-- (31/10 soir) logo de la marque du véhicule (celui du magasin, marques des mods comprises)
function AS_TerminalTablet:brandImage(v)
    if g_brandManager == nil then return nil end
    local idx = call(v, "getBrand")
    local b = nil
    if idx ~= nil then
        local ok, bb = pcall(g_brandManager.getBrandByIndex, g_brandManager, idx)
        if ok then b = bb end
    end
    if b == nil then b = v.brand end
    if type(b) ~= "table" or b.name == "NONE" or type(b.image) ~= "string" or b.image == "" then return nil end
    return b.image, b.title or b.name
end

-- matériau du logo de la marque : un par logo, partagé entre les véhicules de la même marque ;
-- posé sur la plaque du cadre de la tablette (« marque ») et sur l'écran de démarrage (« bootMarque »)
function AS_TerminalTablet:brandMaterial(v, node)
    local file, title = self:brandImage(v)
    if file == nil then return nil end
    self.logoMats = self.logoMats or {}
    local mat = self.logoMats[file]
    if mat ~= nil and mat ~= false and entityExists ~= nil and not entityExists(mat) then mat = nil end
    if mat == nil then
        mat = false
        if getMaterial ~= nil and setMaterialDiffuseMapFromFile ~= nil and setMaterial ~= nil then
            local okM, base = pcall(getMaterial, node, 0)
            if okM and base ~= nil and base ~= 0 then
                local okN, m = pcall(setMaterialDiffuseMapFromFile, base, file, true, true, false)
                if okN and m ~= nil and m ~= 0 then mat = m end
            end
        end
        self.logoMats[file] = mat
        log("logo de la marque %s : %s (%s)", tostring(title), file, mat and "chargé" or "ERREUR, pas de logo")
    end
    return mat or nil
end

-- (01/11) matériau d'une image du magasin (outil) : un par fichier, comme les logos
-- (07/11, 70i) images de l'écran 3D : le jeu écrit « albedo map alpha channel removed by
-- script » quand une image SANS transparence (DXT1) est posée à partir d'un matériau dont l'image d'origine en a une.
-- Chaque image part donc de la pièce modèle de même format : imgOpaque (images de objects/terminal/as_opaque.xml,
-- liste refaite par le script d'installation) ou imgAlpha (toutes les autres, logos et images du magasin compris)
function AS_TerminalTablet:isOpaqueFile(file)
    if self.opaqueSet == nil then
        self.opaqueSet = {}
        local n = 0
        local path = AS_MOD_DIR ~= nil and Utils.getFilename("objects/terminal/as_opaque.xml", AS_MOD_DIR) or nil
        if path ~= nil and fileExists ~= nil and fileExists(path) then
            local xml = loadXMLFile("asOpaque", path)
            if xml ~= nil and xml ~= 0 then
                while true do
                    local name = getXMLString(xml, string.format("images.o(%d)#n", n))
                    if name == nil then break end
                    self.opaqueSet[name] = true
                    n = n + 1
                end
                delete(xml)
            end
        end
        log("écran 3D : %d image(s) sans transparence (as_opaque.xml)", n)
    end
    local base = tostring(file or ""):match("([^/\\]+)%.%w+$")
    return base ~= nil and self.opaqueSet[base] == true
end

-- (perf 07/11) chaque image est lue sur le disque par le jeu, d'un bloc : 45 images d'un coup en montant dans
-- un John Deere, puis 10 s de gel sur une image du Fendt. Au plus LOAD_BUDGET_MS de chargement par image du jeu ;
-- les suivantes attendent la reconstruction suivante de l'écran (elles apparaissent en moins d'une seconde).
AS_TerminalTablet.LOAD_BUDGET_MS = 6
AS_TerminalTablet.LOAD_MAX = 4          -- sans chronomètre : 4 images par image du jeu
AS_TerminalTablet.LOAD_SLOW_MS = 200    -- image plus lente : écrite dans log.txt (nom et durée)

function AS_TerminalTablet:loadBudgetLeft()
    local frame = g_time or 0
    if self.loadFrame ~= frame then self.loadFrame, self.loadSpent, self.loadCount = frame, 0, 0 end
    if getTimeSec == nil then return self.loadCount < self.LOAD_MAX end
    return self.loadCount == 0 or self.loadSpent < self.LOAD_BUDGET_MS
end

function AS_TerminalTablet:fileMaterial(file, node, tab)
    self.fileMats = self.fileMats or {}
    local mat = self.fileMats[file]
    -- (03/11) le matériau a pu disparaître avec la tablette d'un autre véhicule : on le refait (« Unknown entity id »)
    if mat ~= nil and mat ~= false and entityExists ~= nil and not entityExists(mat) then mat = nil end
    if mat == nil then
        if not self:loadBudgetLeft() then
            self.loadWaiting = true
            return nil
        end
        local t0 = getTimeSec ~= nil and getTimeSec() or nil
        mat = false
        if getMaterial ~= nil and setMaterialDiffuseMapFromFile ~= nil and setMaterial ~= nil then
            -- (70i) départ : pièce modèle du même format que l'image (jamais la pièce elle-même, qui porte déjà une autre image)
            local src = node
            if tab ~= nil and tab.node ~= nil then
                local okT, t = pcall(getChild, tab.node, self:isOpaqueFile(file) and "imgOpaque" or "imgAlpha")
                if okT and t ~= nil and t ~= 0 then src = t end
            end
            local okM, base = pcall(getMaterial, src, 0)
            if okM and base ~= nil and base ~= 0 then
                local okN, m = pcall(setMaterialDiffuseMapFromFile, base, file, true, true, false)
                if okN and m ~= nil and m ~= 0 then mat = m end
            end
        end
        self.fileMats[file] = mat
        self.loadCount = (self.loadCount or 0) + 1
        if t0 ~= nil then
            local ms = (getTimeSec() - t0) * 1000
            self.loadSpent = (self.loadSpent or 0) + ms
            if ms >= self.LOAD_SLOW_MS then
                print(string.format("[AS_TerminalTablet] image lente à charger (%.0f ms) : %s", ms, tostring(file)))
            end
        end
        log("image du magasin %s : %s", file, mat and "chargée" or "ERREUR, pas d'image")
    end
    return mat or nil
end

-- montre (ou cache) un logo de marque sur la pièce « name » de la tablette
function AS_TerminalTablet:showBrand(v, tab, name, on)
    local okC, node = pcall(getChild, tab.node, name)
    if not okC or node == nil or node == 0 then return end
    local mat = on and self:brandMaterial(v, node) or nil
    tab.logoMat = tab.logoMat or {}
    if mat ~= nil and tab.logoMat[name] ~= mat then
        pcall(setMaterial, node, mat, 0)
        tab.logoMat[name] = mat
    end
    tab.logoOn = tab.logoOn or {}
    local vis = mat ~= nil
    if tab.logoOn[name] ~= vis then
        tab.logoOn[name] = vis
        pcall(setVisibility, node, vis)
    end
end

-- plaque du bas du cadre de la tablette (pas sur les écrans intégrés, qui n'ont plus de cadre)
function AS_TerminalTablet:setBrandLogo(v, tab, on)
    self:showBrand(v, tab, "marque", on)
end

local function childVis(tab, name, on)
    local okC, c = pcall(getChild, tab.node, name)
    if okC and c ~= nil and c ~= 0 then pcall(setVisibility, c, on) end
end

-- (31/10 soir) image de l'écran d'origine cachée tant que notre terminal est dessus.
-- Seules les pièces que nous avons cachées sont remises (le jeu garde la main sur les autres).
function AS_TerminalTablet:hideOriginal(tab)
    if tab == nil or tab.vehHide == nil then return end
    tab.origHidden = tab.origHidden or {}
    for _, n in ipairs(tab.vehHide) do
        if entityExists(n) then
            local okV, vis = pcall(getVisibility, n)
            if okV and vis then
                pcall(setVisibility, n, false)
                tab.origHidden[n] = true
            end
        end
    end
end

function AS_TerminalTablet:restoreOriginal(tab)
    if tab == nil or tab.origHidden == nil then return end
    for n in pairs(tab.origHidden) do
        if entityExists(n) then pcall(setVisibility, n, true) end
    end
    tab.origHidden = nil
end


-- place (ou replace) la tablette : position relative à la tête, écran vers la tête
function AS_TerminalTablet:place(v, tab)
    local cam = tab.cam
    local head = cam.rotateNode or cam.cameraPositionNode
    -- (31/10) accrochée à la cabine, pas à la caméra : avec la « suspension de caméra » du jeu,
    -- la caméra est reliée à un nœud qui ballote (siège) ; cameraBaseParentNode est son parent
    -- d'origine, fixe dans la cabine. La tablette suit donc le tracteur, pas la tête.
    local parent = cam.cameraBaseParentNode
    if parent == nil or parent == 0 or not entityExists(parent) then parent = getParent(head) end
    local hx, hy, hz = localToLocal(head, parent, 0, 0, 0)
    local fx, fy, fz = localDirectionToLocal(v.rootNode, parent, 0, 0, 1)
    local rx, ry, rz = localDirectionToLocal(v.rootNode, parent, -1, 0, 0)  -- droite du conducteur
    local ux, uy, uz = localDirectionToLocal(v.rootNode, parent, 0, 1, 0)
    local ox, oy, oz = self:getOffset(v)
    if tab.slot then ox, oy, oz = 0, 0, 0 end
    local bf, br, bu = self.FWD, self.RIGHT, self.UP
    local pr = self.PRESETS[self:preset() or 0]
    if pr ~= nil then bf, br, bu = pr[1], pr[2], pr[3] end
    -- (31/10) place auto : sans réglage à la main, on évite les écrans de la cabine
    if ox == 0 and oy == 0 and oz == 0 and self.AUTO_PLACE and not self:onVehicleScreen() and not tab.slot then
        local key = modelKey(v)
        if tab.autoKey ~= key then
            tab.autoKey = key
            local ok, a = pcall(self.autoOffset, self, v, parent, hx, hy, hz, { fx, fy, fz }, { rx, ry, rz }, { ux, uy, uz }, bf, br, bu, tab.node)
            tab.auto = ok and a or nil
            if not ok then log("ERREUR place auto : %s", tostring(a)) end
        end
        if tab.auto ~= nil then ox, oy, oz = tab.auto[1], tab.auto[2], tab.auto[3] end
    end
    local f, r, u = bf + oz, br + ox, bu + oy
    local x = hx + fx * f + rx * r + ux * u
    local y = hy + fy * f + ry * r + uy * u
    local z = hz + fz * f + rz * r + uz * u
    -- (31/10 soir) sur l'écran du véhicule : posé dans le plan de l'écran d'origine, à sa taille,
    -- et accroché à sa pièce (il suit l'accoudoir / le siège quand l'écran y est monté, sinon la cabine)
    local vehK, vehDir, vehUp, anchor = nil, nil, nil, parent
    self:restoreOriginal(tab)
    tab.vehHide = nil
    if self:onVehicleScreen() or tab.slot then
        local key = modelKey(v)
        if tab.vehKey ~= key or tab.vehList == nil then
            tab.vehKey = key
            tab.vehTime = g_time or 0
            local ok, list = pcall(self.findVehicleScreens, self, v, parent, hx, hy, hz, { fx, fy, fz }, { rx, ry, rz }, { ux, uy, uz }, tab.node)
            if not ok then log("ERREUR écran du véhicule : %s", tostring(list)) list = {} end
            tab.vehList = list
        end
        local p = AS_Terminal.positions[key]
        -- (étape 37) 2e / 3e écran : seulement l'écran choisi, sans réglages fins
        if tab.slot then p = { scr = tab.idxWant } end
        local idx = p ~= nil and p.scr or 1
        local off = idx == 0                     -- (31/10 soir) « aucun » choisi pour ce modèle : la tablette
        if idx == nil or idx < 1 or idx > #tab.vehList then idx = 1 end
        if off then idx = 0 end
        tab.vehIdx = #tab.vehList > 0 and idx or 0
        local chosen = tab.vehList[idx]
        local changed = chosen ~= tab.veh
        tab.veh = chosen
        if chosen == nil and changed then
            log("écran du véhicule %s : %s, tablette gardée", tostring(v.getFullName ~= nil and v:getFullName() or "?"), off and "aucun écran choisi pour ce modèle" or "aucun trouvé")
        end
        if chosen ~= nil then
            local c = chosen
            -- centre de l'écran maintenant (l'accoudoir a pu bouger depuis la recherche)
            local okC, sx, sy, sz = pcall(localToLocal, c.node, parent, c.lx or 0, c.ly or 0, c.lz or 0)
            if not okC or sx == nil then sx, sy, sz = c.x, c.y, c.z end
            local tx, ty, tz = norm3(hx - sx, hy - sy, hz - sz)
            local src, ang
            if (p ~= nil and p.ori == 2) or c.painted then
                local ud0 = ux * tx + uy * ty + uz * tz
                local vx, vy, vz = norm3(ux - ud0 * tx, uy - ud0 * ty, uz - ud0 * tz)
                vehDir, vehUp, src, ang = { tx, ty, tz }, { vx, vy, vz }, "tete", 0
            else
                vehDir, vehUp, src, ang = self:screenFrame(c.node, parent, { tx, ty, tz }, { fx, fy, fz }, { rx, ry, rz }, { ux, uy, uz })
            end
            -- 6 mm devant l'écran quand son plan est connu ; 2 cm quand le terminal est juste tourné vers la tête
            local gap = src == "tete" and 0.02 or 0.006
            local mx, my, mz = self:getOffset(v)
            if tab.slot then mx, my, mz = 0, 0, 0 end
            x = sx + vehDir[1] * gap + fx * mz + rx * mx + ux * my
            y = sy + vehDir[2] * gap + fy * mz + ry * mx + uy * my
            z = sz + vehDir[3] * gap + fz * mz + rz * mx + uz * my
            -- (31/10 soir) : la page REMPLIT l'écran, aux vraies
            -- proportions de l'écran (tableau SCREEN_ASPECT, 16:10 si inconnu) sur la diagonale donnée par le jeu,
            -- plus largeur / hauteur réglées pour ce modèle
            local dft = self:screenDefault(v) or {}
            local pw, ph = ((p ~= nil and p.sw) or dft.sw or 100) / 100, ((p ~= nil and p.sh) or dft.sh or 100) / 100
            local asp, known, fill = self:screenAspect(c.name)
            local dg = 1 / math.sqrt(1 + asp * asp)
            local wM, hM = c.rad * 2 * fill * asp * dg * pw, c.rad * 2 * fill * dg * ph
            vehK = math.max(0.3, math.min(2.5, wM / self.SW))
            tab.vehKy = math.max(0.3, math.min(2.5, hM / self.SH)) / vehK
            -- rectangle de l'écran (pour cacher ce qui est posé dessus), tourné comme le terminal
            local hUp = vehUp
            local rollH = tab.slot and 0 or self:getRoll(v)
            if rollH ~= 0 then
                local hx2, hy2, hz2 = rotate(vehUp[1], vehUp[2], vehUp[3], vehDir[1], vehDir[2], vehDir[3], rollH)
                hUp = { hx2, hy2, hz2 }
            end
            -- (01/11) pièces à cacher : sur toute la pièce de l'écran (pas seulement la vitre réduite)
            local rect = { up = hUp, hw = wM / fill / 2, hh = hM / fill / 2 }
            if c.painted and c.anchorNode ~= nil and shownUpTo(c.anchorNode, v.rootNode) then
                anchor = c.anchorNode
            else
                anchor = self:screenAnchor(v, c.node, parent, tab.avoid)
            end
            local okH, hide
            if c.painted then okH, hide = true, {} else
                okH, hide = pcall(self.buildHideList, self, v, tab, c, parent, anchor, vehDir, src, sx, sy, sz, rect)
            end
            -- (31/10 soir) les chiffres du tableau de bord peuvent n'apparaître qu'au démarrage du moteur :
            -- nouvelle recherche 3 s après la pose, puis après chaque démarrage (voir powerState)
            tab.vehCtx = (not c.painted) and { c = c, parent = parent, anchor = anchor, nrm = vehDir, src = src, rect = rect } or nil
            tab.vehRescanAt = tab.vehCtx ~= nil and { (g_time or 0) + 3000 } or nil
            if not okH then
                log("ERREUR pièces à cacher : %s", tostring(hide))
                hide = { c.node }
            end
            tab.vehHide = hide
            if changed or tab.vehSrc ~= src then
                tab.vehSrc = src
                local okN, an = pcall(getName, anchor)
                log("écran du véhicule %s : %d/%d %s (rayon %.0f cm%s), plan : %s (%.0f° avec la tête), format %.2f (%s), vitre %d %%, accroché à %s, %d image(s) d'origine cachée(s) dont %d petite(s) pièce(s) sur la vitre",
                    tostring(v.getFullName ~= nil and v:getFullName() or "?"), idx, #tab.vehList, c.name, c.rad * 100,
                    c.hidden and ", caché" or "", src == "tete" and "tourné vers la tête" or (src == "piece" and "axes de la pièce" or "axes de son parent"), ang or 0,
                    asp, known and "texture de l'écran" or "inconnu, 16:10", math.floor(fill * 100 + 0.5), okN and tostring(an) or "?", #tab.vehHide, tab.vehGlass or 0)
                local names = {}
                for i, n in ipairs(tab.vehHide) do
                    if i > 14 then names[#names + 1] = string.format("+%d", #tab.vehHide - 14) break end
                    local okM, nm = pcall(getName, n)
                    names[#names + 1] = okM and tostring(nm) or "?"
                end
                log("  cachés : %s", table.concat(names, ", "))
                for i, l in ipairs(tab.vehLeft or {}) do log("  restant sur la vitre #%d : %s", i, l) end
            end
        end
    else
        tab.vehKey, tab.veh, tab.vehList, tab.vehSrc = nil, nil, nil, nil
    end
    -- (étape 37) liste des écrans du véhicule pour les 2e / 3e écrans (aussi quand le principal est la tablette)
    if not tab.slot and not tab.asTablet then
        if self:onVehicleScreen() then
            tab.allScreens = tab.vehList
        else
            local key = extKey(v)
            local pe = AS_Terminal.positions[key]
            local wanted = pe ~= nil and ((pe.scr2 or 0) > 0 or (pe.scr3 or 0) > 0)
            if (tab.allKey ~= key or tab.allScreens == nil) and (wanted or self.scanAsked) then
                tab.allKey = key
                local ok, list = pcall(self.findVehicleScreens, self, v, parent, hx, hy, hz, { fx, fy, fz }, { rx, ry, rz }, { ux, uy, uz }, tab.node)
                tab.allScreens = ok and list or {}
            end
        end
    end
    if vehK == nil then tab.vehCtx, tab.vehRescanAt = nil, nil end
    self:setBodyVisible(tab, vehK == nil)
    self:setBrandLogo(v, tab, vehK == nil)
    tab.integrated = vehK ~= nil
    if not tab.integrated then
        tab.power, tab.bootUntil = nil, nil
        self:showBoot(v, tab, false)
    end
    -- écran (+Z de la tablette) tourné vers la tête (ou dans le plan de l'écran du véhicule), haut de la
    -- tablette vers le haut du véhicule, puis inclinaison réglée : gauche / droite autour de la verticale,
    -- haut / bas autour de l'axe droite
    local dx, dy, dz, upx, upy, upz
    if vehDir ~= nil then
        dx, dy, dz = vehDir[1], vehDir[2], vehDir[3]
        upx, upy, upz = vehUp[1], vehUp[2], vehUp[3]
    else
        dx, dy, dz = hx - x, hy - y, hz - z
        upx, upy, upz = ux, uy, uz
    end
    local _, tilt, turn = self:getShape(v)
    if tab.slot then tilt, turn = 0, 0 end
    -- (31/10 soir) rotation dans le plan de l'écran (réglée par modèle) : autour de la normale
    local roll = tab.slot and 0 or self:getRoll(v)
    if roll ~= 0 then
        local nx, ny, nz = norm3(dx, dy, dz)
        upx, upy, upz = rotate(upx, upy, upz, nx, ny, nz, roll)
    end
    dx, dy, dz = rotate(dx, dy, dz, ux, uy, uz, turn)
    upx, upy, upz = rotate(upx, upy, upz, ux, uy, uz, turn)
    local ax, ay, az = rotate(rx, ry, rz, ux, uy, uz, turn)
    upx, upy, upz = rotate(upx, upy, upz, ax, ay, az, tilt)
    dx, dy, dz = rotate(dx, dy, dz, ax, ay, az, tilt)
    local k = self:getScale(v)
    if tab.slot then k = self.BASE end
    if vehK ~= nil then k = vehK * k / self.BASE end
    local ky = (vehK ~= nil and tab.vehKy ~= nil) and tab.vehKy or 1
    -- tout est calculé dans le repère de la cabine ; s'il est accroché ailleurs, on passe dans le repère de la pièce
    local sA = 1
    if anchor ~= parent then
        local okA, lx, ly, lz = pcall(localToLocal, parent, anchor, x, y, z)
        local okD, ddx, ddy, ddz = pcall(localDirectionToLocal, parent, anchor, dx, dy, dz)
        local okU, uux, uuy, uuz = pcall(localDirectionToLocal, parent, anchor, upx, upy, upz)
        if okA and okD and okU and lx ~= nil and ddx ~= nil and uux ~= nil then
            x, y, z, dx, dy, dz, upx, upy, upz = lx, ly, lz, ddx, ddy, ddz, uux, uuy, uuz
            local o1, x0, y0, z0 = pcall(localToLocal, anchor, parent, 0, 0, 0)
            local o2, x1, y1, z1 = pcall(localToLocal, anchor, parent, 1, 0, 0)
            if o1 and o2 and x0 ~= nil and x1 ~= nil then
                local sc = math.sqrt((x1 - x0) ^ 2 + (y1 - y0) ^ 2 + (z1 - z0) ^ 2)
                if sc > 0.01 and sc < 100 then sA = sc end
            end
        else
            anchor = parent
        end
    end
    if getParent(tab.node) ~= anchor then link(anchor, tab.node) end
    tab.anchor = anchor
    setTranslation(tab.node, x, y, z)
    setDirection(tab.node, dx, dy, dz, upx, upy, upz)
    setScale(tab.node, k / sA, k * ky / sA, k / sA)
    tab.scale = k
    tab.parentNode = parent
    tab.expScale = vehK ~= nil and effScale(tab.node, parent) or nil
    if tab.vehHide ~= nil and self:screen3dOn() then self:hideOriginal(tab) end
    if not tab.slot and not tab.asTablet then self:syncExtras(v, tab) end
end

-- (01/11, étape 37) indices des écrans du véhicule déjà pris (principal, 2e, 3e), sauf « except »
function AS_TerminalTablet:usedScreens(v, except)
    local used = {}
    local tab = self.tablets[v]
    if tab ~= nil and tab.failed == nil and self:onVehicleScreen() and tab.veh ~= nil and except ~= 1 then used[tab.vehIdx or 0] = true end
    local pe = AS_Terminal.positions[extKey(v)]
    if pe ~= nil then
        if except ~= 2 and (pe.scr2 or 0) > 0 then used[pe.scr2] = true end
        if except ~= 3 and (pe.scr3 or 0) > 0 then used[pe.scr3] = true end
    end
    return used
end

-- (01/11, étape 37) 2e et 3e écrans : une page du terminal sur d'autres écrans du véhicule (choisis
-- dans les Réglages de l'écran principal), jamais sur un écran déjà pris. Chacun a sa propre page.
function AS_TerminalTablet:syncExtras(v, tab)
    tab.extra = tab.extra or {}
    local list = tab.allScreens or {}
    local pe = AS_Terminal.positions[extKey(v)]
    local mainIdx = (self:onVehicleScreen() and tab.veh ~= nil) and (tab.vehIdx or 0) or 0
    local taken = { [mainIdx] = true }
    for slot = 2, 3 do
        local idx = pe ~= nil and pe["scr" .. slot] or 0
        local want = nil
        if idx ~= nil and idx > 0 and idx <= #list and not taken[idx] then want = idx; taken[idx] = true end
        local ch = tab.extra[slot]
        if want == nil then
            if ch ~= nil then
                self:restoreOriginal(ch)
                if ch.node ~= nil and entityExists(ch.node) then pcall(delete, ch.node) end
                tab.extra[slot] = nil
            end
        elseif self.template ~= nil and self.template ~= false then
            if ch == nil or ch.node == nil or not entityExists(ch.node) then
                ch = { node = clone(self.template, false, false, false), cam = tab.cam, slot = slot, page = "home" }
                tab.extra[slot] = ch
            end
            ch.vehList, ch.vehKey, ch.idxWant = list, modelKey(v), want
            if ch.idxDone ~= want then ch.veh = nil; ch.idxDone = want end
            self:restoreOriginal(ch)
            local ok, err = pcall(self.place, self, v, ch)
            if not ok then log("ERREUR %de écran : %s", slot, tostring(err)) end
        end
    end
    -- (37c) « Les 2 » : l'écran du véhicule + la tablette
    local tb = tab.extra[4]
    if self:bothOn() and self.template ~= nil and self.template ~= false then
        if tb == nil or tb.node == nil or not entityExists(tb.node) then
            tb = { node = clone(self.template, false, false, false), cam = tab.cam, asTablet = true, page = "home" }
            tab.extra[4] = tb
        end
        self:restoreOriginal(tb)
        local ok, err = pcall(self.asTab, self, tb, self.place, self, v, tb)
        if not ok then log("ERREUR tablette en plus : %s", tostring(err)) end
    elseif tb ~= nil then
        self:restoreOriginal(tb)
        if tb.node ~= nil and entityExists(tb.node) then pcall(delete, tb.node) end
        tab.extra[4] = nil
    end
end

-- l'écran principal et ses écrans en plus
function AS_TerminalTablet:screensOf(tab)
    local out = { tab }
    if tab ~= nil and tab.extra ~= nil then
        for slot = 2, 4 do if tab.extra[slot] ~= nil then out[#out + 1] = tab.extra[slot] end end
    end
    return out
end

function AS_TerminalTablet:create(v)
    local cam = insideCamera(v)
    if cam == nil then
        self.tablets[v] = { failed = g_time or 0 }     -- pas de caméra intérieure : réessai dans 10 s
        return nil
    end
    local node = clone(self.template, false, false, false)
    local tab = { node = node, cam = cam }
    self.tablets[v] = tab
    local ok, err = pcall(self.place, self, v, tab)
    if not ok then
        log("ERREUR placement (%s) : %s", tostring(v.configFileName), tostring(err))
        pcall(delete, node)
        self.tablets[v] = { failed = g_time or 0 }
        return nil
    end
    -- texte 3D de l'écran (vue extérieure) : vitesse (police chiffres), rapport (police lettres)
    if CharacterLine ~= nil and g_materialManager ~= nil then
        local function line(name, fontName, n, size, color)
            local font = g_materialManager:getFontMaterial(fontName, v.customEnvironment)
            local ln = getChild(node, name)
            if font == nil or ln == nil or ln == 0 then return nil end
            local okL, cl = pcall(CharacterLine.new, ln, font, n)
            if not okL or cl == nil then return nil end
            pcall(cl.setSizeAndScale, cl, size, 1, 1)
            pcall(cl.setTextAlignment, cl, RenderText.ALIGN_CENTER)
            pcall(cl.setColor, cl, color, nil, 1)    -- pas de couleur « cachée » : sinon segments fantômes (31/10)
            return cl
        end
        tab.line1 = line("texte", "DIGIT", 3, 0.04, { 0.25, 0.95, 0.35, 1 })
        tab.line2 = line("texte2", "GENERIC", 6, 0.03, { 0.85, 0.90, 0.95, 1 })
    end
    log("tablette posée dans %s", tostring(call(v, "getFullName") or v.configFileName))
    return tab
end

-- (31/10 soir) pas de tablette dans les chargeuses, camions, voitures, engins forestiers...
-- (04/11) la tablette n'est QUE dans les tracteurs, moissonneuses, ensileuses et récolteuses
-- (le Kärcher l'avait) : liste des catégories ADMISES du magasin ; sans catégorie, le type du véhicule.
-- La grande fenêtre (Ctrl droit + T) reste dans tous les véhicules.
-- (04/11 10:28) + automoteurs de pulvérisation (sprayerVehicles)
AS_TerminalTablet.TABLET_CATS = { "tractor", "harvest", "combine", "sprayervehicle" }   -- tractorsS/M/L, harvesters, forageHarvesters, potato/beet/...Harvesting
function AS_TerminalTablet:noTabletFor(v)
    self.noTabMemo = self.noTabMemo or setmetatable({}, { __mode = "k" })
    local r = self.noTabMemo[v]
    if r ~= nil then return r end
    local cat = ""
    if g_storeManager ~= nil and v.configFileName ~= nil then
        local ok, item = pcall(g_storeManager.getItemByXMLFilename, g_storeManager, v.configFileName)
        if ok and item ~= nil and item.categoryName ~= nil then cat = tostring(item.categoryName):lower() end
    end
    local tn = tostring(v.typeName or ""):lower()
    r = true
    if cat ~= "" then
        for _, w in ipairs(self.TABLET_CATS) do
            if cat:find(w, 1, true) then r = false break end
        end
    elseif tn:find("tractor", 1, true) or tn:find("combine", 1, true) or tn:find("harvest", 1, true) or tn:find("sprayer", 1, true)
        or v.spec_combine ~= nil then
        r = false
    end
    self.noTabMemo[v] = r
    if r then log("pas de tablette dans %s (catégorie %s)", tostring(call(v, "getFullName") or v.configFileName), cat ~= "" and cat or (tn ~= "" and tn or "?")) end
    return r
end

function AS_TerminalTablet:get(v)
    if not self.ENABLED or not AS_Terminal.settings.tablet then return nil end
    if self:noTabletFor(v) then return nil end
    local tab = self.tablets[v]
    if tab ~= nil and tab.failed ~= nil then
        if (g_time or 0) - tab.failed < 10000 then return nil end
        self.tablets[v] = nil
        tab = nil
    end
    if tab ~= nil then
        if not entityExists(tab.node) then self.tablets[v] = nil; return nil end
        return tab
    end
    if self.template == nil then self:loadModel() return nil end
    if self.template == false then return nil end
    return self:create(v)
end

-- keepList : garder les écrans du véhicule déjà trouvés (réglages à la main, écran suivant)
function AS_TerminalTablet:replace(v, keepList)
    local tab = self.tablets[v]
    if tab == nil or tab.node == nil then return end
    tab.autoKey, tab.vehSrc = nil, nil
    if not keepList then tab.vehKey, tab.vehList = nil, nil end
    -- (37c) appelé depuis la tablette en plus (« Les 2 ») : l'écran principal reste dans son mode
    local keepF = self.forceTablet
    self.forceTablet = nil
    local ok, err = pcall(self.place, self, v, tab)
    self.forceTablet = keepF
    if not ok then log("ERREUR placement : %s", tostring(err)) end
end

function AS_TerminalTablet:removeAll()
    for v, tab in pairs(self.tablets) do
        for _, t in ipairs(self:screensOf(tab)) do
            self:restoreOriginal(t)
            if t.node ~= nil and entityExists(t.node) then pcall(delete, t.node) end
        end
    end
    self.tablets = setmetatable({}, { __mode = "k" })
end

-------------------------------------------------------------------------------
-- Écran : rectangle de l'écran projeté (vue cabine) ou texte 3D (vue extérieure)
-------------------------------------------------------------------------------
function AS_TerminalTablet:getScreenRect(v)
    local tab = self:get(v)
    if tab == nil then return nil end
    setVisibility(tab.node, true)
    local hw, hh = self.SW * 0.5, self.SH * 0.5      -- repère de la tablette : l'échelle y est déjà
    local minX, minY, maxX, maxY = 2, 2, -1, -1
    for _, c in ipairs({ { -hw, -hh }, { hw, -hh }, { hw, hh }, { -hw, hh } }) do
        local wx, wy, wz = localToWorld(tab.node, c[1], c[2], 0.003)
        local sx, sy, sz = project(wx, wy, wz)
        if sx == nil or sz == nil or sz > 1 or sz < 0 then return nil end
        minX, maxX = math.min(minX, sx), math.max(maxX, sx)
        minY, maxY = math.min(minY, sy), math.max(maxY, sy)
    end
    if minX < 0 or minY < 0 or maxX > 1 or maxY > 1 then return nil end
    if maxX - minX < 0.02 then return nil end
    return { x = minX, y = minY, w = maxX - minX, h = maxY - minY }
end

-------------------------------------------------------------------------------
-- (31/10) Écran 3D : le terminal est construit DANS l'écran de la tablette, comme les
-- compteurs des tracteurs. AS_Terminal:drawPanel(..., rec) note rectangles, textes et
-- boutons (unités du panneau 900 x 500) ; ici chaque rectangle devient un carré 3D lumineux
-- (couleur la plus proche de la palette du i3d), chaque texte une ligne de lettres 3D
-- (police du jeu). En perspective, caché par les montants, éclairé comme un écran.
-- Clics : les coins de chaque bouton sont projetés à l'écran au moment du clic.
-------------------------------------------------------------------------------
AS_TerminalTablet.PALETTE = {
    { 0.04, 0.05, 0.06 }, { 0.09, 0.10, 0.11 }, { 0.11, 0.13, 0.15 }, { 0.16, 0.19, 0.22 }, { 0.08, 0.095, 0.11 },
    { 0.20, 0.56, 0.84 }, { 0.36, 0.70, 0.95 }, { 1, 1, 1 }, { 0.62, 0.66, 0.70 }, { 0.40, 0.43, 0.46 },
    { 0.30, 0.90, 0.40 }, { 1.00, 0.70, 0.20 }, { 1.00, 0.28, 0.22 }, { 0.35, 0.60, 1.00 }, { 0.20, 0.45, 0.95 },
    { 0.95, 0.25, 0.25 }, { 0.07, 0.09, 0.08 }, { 0.13, 0.15, 0.14 }, { 1.00, 0.85, 0.20 }, { 0.55, 0.50, 0.30 },
    { 1.00, 0.55, 0.10 }, { 0.0, 0.0, 0.0 }, { 0.25, 0.27, 0.30 }, { 0.12, 0.30, 0.55 }, { 0.55, 0.15, 0.13 },
    -- (31/10 soir) thème clair
    { 0.93, 0.94, 0.95 }, { 0.80, 0.82, 0.85 }, { 0.85, 0.87, 0.90 }, { 0.78, 0.81, 0.85 }, { 0.0, 0.0, 0.0 }, { 0.16, 0.18, 0.20 }, { 0.34, 0.37, 0.40 }, { 0.10, 0.60, 0.20 }, { 0.85, 0.50, 0.00 },
    -- (31/10 soir) couleurs des marques (écran d'accueil)
    { 0.16, 0.21, 0.17 }, { 0.47, 0.69, 0.22 }, { 0.21, 0.49, 0.17 }, { 0.76, 0.08, 0.13 }, { 0.04, 0.30, 0.58 }, { 0.70, 0.78, 0.09 },
}
AS_TerminalTablet.SCREEN_MS = 250          -- (70m, petits PC) écran 3D reconstruit 4 fois par seconde (avant 5)
AS_TerminalTablet.MAX_RECTS = 1400         -- (01/11) 700 -> 1000 : mini-carte plus fine ; (étape 37) 1400, guidage plus fin
-- (31/10) chaque carré est posé une « couche » au-dessus des carrés qu'il recouvre vraiment ;
-- l'ancien écart (0,012 mm par carré) faisait clignoter le bandeau du haut (noir / bleu)
AS_TerminalTablet.Z0, AS_TerminalTablet.DZ = 0.0024, 0.0003
AS_TerminalTablet.Z_SPAN, AS_TerminalTablet.DZ_MIN = 0.006, 0.00003   -- (37c) profondeur totale des couches 6 mm au plus
AS_TerminalTablet.BLUE_DIM = 0.6
AS_TerminalTablet.screenTimer = 0

local palCache = {}
local palTheme = nil
local palBG1, palBG2, palBG3 = nil, nil, nil   -- (70k) fond déjà vu : pas de texte refait pour chaque carré
local function paletteIndex(r, g, b, a)
    a = a or 1
    -- fond de l'écran (selon le thème) : sert au mélange des couleurs transparentes
    local BG = AS_Terminal.ui ~= nil and AS_Terminal.ui.C.screen or { 0.04, 0.05, 0.06 }
    -- (31/10 soir) thème « Marque » : le fond change avec la marque, pas avec le réglage
    if BG[1] ~= palBG1 or BG[2] ~= palBG2 or BG[3] ~= palBG3 then
        palBG1, palBG2, palBG3 = BG[1], BG[2], BG[3]
        local th = string.format("%.2f|%.2f|%.2f", BG[1], BG[2], BG[3])
        if th ~= palTheme then palCache, palTheme = {}, th end
    end
    if a < 1 then
        r, g, b = r * a + BG[1] * (1 - a), g * a + BG[2] * (1 - a), b * a + BG[3] * (1 - a)
    end
    local key = string.format("%.2f|%.2f|%.2f", r, g, b)
    local hit = palCache[key]
    if hit ~= nil then return hit end
    local best, bd = 1, math.huge
    for i, c in ipairs(AS_TerminalTablet.PALETTE) do
        local d = (c[1] - r) ^ 2 + (c[2] - g) ^ 2 + (c[3] - b) ^ 2
        if d < bd then best, bd = i, d end
    end
    palCache[key] = best
    return best
end

AS_TerminalTablet.paletteIndex = paletteIndex

local function linC(c)
    if c <= 0.04045 then return c / 12.92 end
    return ((c + 0.055) / 1.055) ^ 2.4
end

-- unités du panneau -> repère de la tablette (m) : le panneau 900 x 500 remplit la largeur de l'écran
function AS_TerminalTablet:panelToLocal(u, vv)
    local k = math.min(self.SW / AS_Terminal.W, self.SH / AS_Terminal.H)
    local oy = (self.SH - AS_Terminal.H * k) * 0.5
    return -self.SW * 0.5 + u * k, self.SH * 0.5 - oy - vv * k, k
end

function AS_TerminalTablet:screenRoot(tab)
    if tab.scr ~= nil and entityExists(tab.scr) then return tab.scr end
    tab.scr = createTransformGroup("as_ecran3d")
    link(tab.node, tab.scr)
    tab.pools, tab.lines, tab.nst, tab.lastGeo = {}, {}, {}, nil
    tab.palette = getChild(tab.node, "palette")
    return tab.scr
end

function AS_TerminalTablet:quad(tab, idx, n)
    local pool = tab.pools[idx]
    if pool == nil then pool = {}; tab.pools[idx] = pool end
    local q = pool[n]
    if q == nil then
        local src = tab.palette ~= nil and tab.palette ~= 0 and getChildAt(tab.palette, idx - 1) or nil
        if src == nil or src == 0 then return nil end
        q = clone(src, false, false, false)
        link(tab.scr, q)
        setVisibility(q, true)
        pool[n] = q
    end
    return q
end

-- (01/11) texte de l'écran 3D : mesure exacte avec les données de la police (comme CharacterLine:setText)
AS_TerminalTablet.FIT_MIN = 0.62           -- on ne réduit pas un texte en dessous de 62 % de sa taille
AS_TerminalTablet.TEXT_GLOW = 0.15         -- thème clair : lumière propre des lettres (1 = comme un voyant)
AS_TerminalTablet.TEXT_DARK = 0.62         -- thème clair : couleurs des textes foncées (1 = inchangées)

function AS_TerminalTablet:font()
    if self.fontMat ~= nil then return self.fontMat or nil end
    if g_materialManager == nil then return nil end
    local ok, f = pcall(g_materialManager.getFontMaterial, g_materialManager, "GENERIC", nil)
    self.fontMat = (ok and f ~= nil) and f or false
    if f ~= nil and type(f.characters) == "table" then
        local miss = {}
        for _, c in ipairs({ "/", "%", ":", "+", "-", ".", ",", "(", ")", "?", "'", '"', "|", "<", ">", "~" }) do
            if not self:fontHas(f, c) then miss[#miss + 1] = c end
        end
        print(string.format("[AS_TerminalTablet] police 3D GENERIC : %d caractères, absents : %s", #f.characters,
            #miss > 0 and table.concat(miss, " ") or "aucun"))
    end
    return self.fontMat or nil
end

local fontInfos = setmetatable({}, { __mode = "k" })
local function fontInfo(font)
    if font == nil or type(font.characters) ~= "table" then return nil end
    local info = fontInfos[font]
    if info ~= nil then return info end
    info = { w = {}, wl = {} }
    local sx0, sy0 = font.spacingX or 0, font.spacingY or 0
    local c2c = font.charToCharSpace or 0.05
    local function adv(spX, spY, real)
        local ratio = (1 - spX * 2) / math.max(0.01, 1 - spY * 2)
        return ratio + c2c * (real > 0 and spX / real or 1)
    end
    for _, ch in ipairs(font.characters) do
        local val = ch.value
        if type(val) == "string" and val ~= "" then
            local a = adv(ch.spacingX or sx0, ch.spacingY or sy0, ch.realSpacingX or ch.spacingX or sx0)
            if info.w[val] == nil then info.w[val] = a end
            if info.wl[val:lower()] == nil then info.wl[val:lower()] = a end
        end
    end
    info.def = adv(sx0, sy0, sx0)
    fontInfos[font] = info
    return info
end

function AS_TerminalTablet:fontHas(font, c)
    local info = fontInfo(font)
    if info == nil then return true end
    return info.w[c] ~= nil or info.wl[c:lower()] ~= nil
end

-- largeur d'un caractère (pour une taille 1)
local function charAdv(info, c)
    if info == nil then return 0.62 end
    return info.w[c] or info.wl[c:lower()] or info.def
end

-- largeur du texte (taille 1), sans les espaces de tête (comme CharacterLine)
function AS_TerminalTablet:textWidth(font, str)
    local info = fontInfo(font)
    local s2 = str:gsub("^ +", "")
    local w = 0
    for i = 1, #s2 do w = w + charAdv(info, s2:sub(i, i)) end
    return w
end

-- coupe le texte pour tenir dans maxW (taille 1)
function AS_TerminalTablet:cutText(font, str, maxW)
    local info = fontInfo(font)
    local w, out = 0, {}
    for i = 1, #str do
        local c = str:sub(i, i)
        w = w + charAdv(info, c)
        if w > maxW then break end
        out[#out + 1] = c
    end
    return table.concat(out)
end

-- place disponible pour un texte (unités du panneau) : largeur maxi demandée (t[9]) et la plus petite
-- case (bouton, ligne, tuile) qui contient le texte, selon l'alignement
function AS_TerminalTablet:textRoom(rec, nr, t)
    local u, vv, size, align = t[1], t[2], t[3], t[8]
    local py = vv - size * 0.45
    -- cases possibles (une fois par écran) : ni images, ni petits carrés de la vue GPS
    local cand = rec.roomCand
    if cand == nil then
        cand = {}
        for i = 1, nr do
            local r = rec.rects[i]
            if r.img == nil and not r.low and r[3] >= 16 and r[4] >= 6 then cand[#cand + 1] = r end
        end
        rec.roomCand = cand
    end
    local best, bestA = nil, math.huge
    for i = 1, #cand do
        local r = cand[i]
        if r[4] >= size * 0.7 and r[2] <= py and py <= r[2] + r[4] and r[1] - 0.5 <= u and u <= r[1] + r[3] + 0.5 then
            local a = r[3] * r[4]
            if a < bestA then best, bestA = r, a end
        end
    end
    local avail = nil
    if best ~= nil then
        local x1, x2 = best[1], best[1] + best[3]
        if align == RenderText.ALIGN_RIGHT then avail = u - x1 - 3
        elseif align == RenderText.ALIGN_CENTER then avail = 2 * math.min(u - x1, x2 - u) - 6
        else avail = x2 - u - 3 end
        avail = math.max(avail, 6)
    end
    if t[9] ~= nil then avail = avail ~= nil and math.min(avail, t[9]) or t[9] end
    return avail
end

-- texte prêt pour l'écran 3D : lettres de la police, taille ajustée à sa case, couleur selon le fond
function AS_TerminalTablet:prepText(rec, nr, t, font, light, glow, dark)
    local str = plain(tostring(t[4]))
    -- (01/11) taille ajustée à la case (bouton, ligne) : la police 3D est plus large que celle du HUD
    local size = t[3]
    local avail = (t.noRoom and t[9]) or self:textRoom(rec, nr, t)
    if avail ~= nil then
        local w = self:textWidth(font, str) * size * 0.95
        if w > avail and w > 0 then
            local f = math.max(self.FIT_MIN, avail / w)
            size = size * f
            if w * f > avail + 0.5 then str = self:cutText(font, str, avail / (size * 0.95)) end
        end
    end
    local r, g, b, em = t[5], t[6], t[7], 1
    -- (70b) terminal John Deere : la page choisit la lumière de chaque texte (encre sur l'écran ou lumineux)
    if t.em ~= nil then return str, size, r, g, b, t.em end
    if light then
        -- (01/11) fond clair : les lettres lumineuses se délavent ; couleurs foncées, peu de lumière.
        -- Les textes clairs (posés sur un bandeau foncé) restent lumineux.
        local mx, mn = math.max(r, g, b), math.min(r, g, b)
        if (r + g + b) / 3 < 0.6 or mx - mn > 0.15 then
            if mx - mn > 0.15 then r, g, b = r * dark, g * dark, b * dark end
            em = glow
        end
    end
    return str, size, r, g, b, em
end

-- fond de l'écran clair (thème clair) ?
function AS_TerminalTablet:lightBg()
    local BG = AS_Terminal.ui ~= nil and AS_Terminal.ui.C ~= nil and AS_Terminal.ui.C.screen or nil
    return BG ~= nil and (BG[1] + BG[2] + BG[3]) / 3 > 0.5
end

function AS_TerminalTablet:textLook()
    local s = AS_Terminal.settings or {}
    return s.textGlow or self.TEXT_GLOW, s.textDark or self.TEXT_DARK
end

-- trait « / » : un carré de la palette, fin et penché, à la place exacte du caractère dans la ligne
function AS_TerminalTablet:drawSlashes(tab, font, str, u, vv, size, align, r, g, b, z)
    local info = fontInfo(font)
    local S = size * 0.95
    local lead = #(str:match("^ *"))
    local total = self:textWidth(font, str)
    local right
    if align == RenderText.ALIGN_RIGHT then right = u
    elseif align == RenderText.ALIGN_CENTER then right = u + total * S * 0.5
    else right = u + total * S end
    local idx = paletteIndex(r, g, b, 1)
    tab.slashPools = tab.slashPools or {}
    local pool = tab.slashPools[idx]
    if pool == nil then pool = {}; tab.slashPools[idx] = pool end
    -- largeur des caractères à droite de chaque position
    local after = 0
    for i = #str, lead + 1, -1 do
        local c = str:sub(i, i)
        local a = charAdv(info, c) * S
        if c == "/" then
            local cu, cv = right - after - a * 0.5, vv - S * 0.5
            local n = (tab.slashUsed[idx] or 0) + 1
            tab.slashUsed[idx] = n
            local q = pool[n]
            if q == nil then
                local src = tab.palette ~= nil and tab.palette ~= 0 and getChildAt(tab.palette, idx - 1) or nil
                if src == nil or src == 0 then return end
                q = clone(src, false, false, false)
                link(tab.scr, q)
                pool[n] = q
            end
            local x, y, k = self:panelToLocal(cu, cv)
            local w, h = math.max(0.9, S * 0.09) * k, S * 0.82 * k
            local th = -0.36
            local cs, sn = math.cos(th), math.sin(th)
            -- centre du carré (coin haut-gauche à l'origine, vers +X et -Y) après rotation
            local cx, cy = (w * 0.5) * cs - (-h * 0.5) * sn, (w * 0.5) * sn + (-h * 0.5) * cs
            setTranslation(q, x - cx, y - cy, z)
            setRotation(q, 0, 0, th)
            setScale(q, w, h, 1)
            setVisibility(q, true)
        end
        after = after + a
    end
end

function AS_TerminalTablet:textLine(tab, i, len)
    local ln = tab.lines[i]
    local need = math.max(8, math.ceil(len / 8) * 8)
    if ln ~= nil and ln.cap < need then
        if tab.nst ~= nil then tab.nst[ln.node] = nil end   -- (70k)
        pcall(delete, ln.node)
        ln = nil
    end
    if ln == nil then
        if CharacterLine == nil or g_materialManager == nil then return nil end
        local font = g_materialManager:getFontMaterial("GENERIC", nil)
        if font == nil then return nil end
        local node = createTransformGroup("as_texte3d")
        link(tab.scr, node)
        local ok, cl = pcall(CharacterLine.new, node, font, need)
        if not ok or cl == nil then pcall(delete, node) return nil end
        ln = { node = node, cl = cl, cap = need }
        tab.lines[i] = ln
    end
    return ln
end

-- (31/10 soir) image de l'écran d'accueil (machine, logo de la marque) : pièce texturée de la tablette,
-- rattachée à l'écran 3D (cachée avec lui), posée et mise à l'échelle comme un carré de couleur
-- (07/11, étape 70k) pièces de l'écran 3D : position, taille et visibilité envoyées au jeu seulement si elles
-- changent (avant : environ 600 appels à chaque reconstruction, 5 fois par seconde et par écran, page immobile ou non)
local function nodeSet(tab, n, x, y, z, w, h, keepVis)
    local st = tab.nst
    if st == nil then st = {}; tab.nst = st end
    local s = st[n]
    if s == nil then s = {}; st[n] = s end
    if s[1] ~= x or s[2] ~= y or s[3] ~= z then setTranslation(n, x, y, z); s[1], s[2], s[3] = x, y, z end
    if w ~= nil and (s[4] ~= w or s[5] ~= h) then setScale(n, w, h, 1); s[4], s[5] = w, h end
    if not keepVis and s[6] ~= true then setVisibility(n, true); s[6] = true end
end
local function nodeHide(tab, n)
    local st = tab.nst
    if st == nil then st = {}; tab.nst = st end
    local s = st[n]
    if s == nil then s = {}; st[n] = s end
    if s[6] ~= false then setVisibility(n, false); s[6] = false end
end

function AS_TerminalTablet:placeImage(v, tab, r, z)
    tab.imgNodes = tab.imgNodes or {}
    tab.imgShown = tab.imgShown or {}
    tab.imgUsed = tab.imgUsed or {}
    local name = r.img
    local n = tab.imgNodes[name]
    if n == nil then
        local okC, c = pcall(getChild, tab.node, name)
        if (not okC or c == nil or c == 0) and r.file ~= nil then
            -- (01/11) image d'un fichier (outil du magasin) : copie de la pièce du logo de la marque
            local tpl = tab.imgNodes.imgMarque
            if tpl == nil or tpl == false then
                local okT, cT = pcall(getChild, tab.node, "imgMarque")
                tpl = (okT and cT ~= nil and cT ~= 0) and cT or nil
            end
            if tpl ~= nil then
                local okK, cl = pcall(clone, tpl, false, false, false)
                if okK and cl ~= nil and cl ~= 0 then okC, c = true, cl end
            end
        end
        if not okC or c == nil or c == 0 then
            tab.imgNodes[name] = false
            if not self.loggedImg then self.loggedImg = true; log("image %s absente du modèle de la tablette", tostring(name)) end
            return
        end
        n = c
        link(tab.scr, n)
        tab.imgNodes[name] = n
    end
    if n == false then return end
    if name == "imgMarque" then
        local mat = self:brandMaterial(v, n)
        if mat == nil then return end
        if tab.imgMat ~= mat then pcall(setMaterial, n, mat, 0); tab.imgMat = mat end
    elseif r.file ~= nil then
        local mat = self:fileMaterial(r.file, n, tab)
        if mat == nil then return end
        tab.imgFile = tab.imgFile or {}
        if tab.imgFile[name] ~= mat then pcall(setMaterial, n, mat, 0); tab.imgFile[name] = mat end
    end
    local x, y, k = self:panelToLocal(r[1], r[2])
    nodeSet(tab, n, x, y, z, r[3] * k, r[4] * k, true)   -- (70k) visibilité : tab.imgShown, comme avant
    if not tab.imgShown[name] then setVisibility(n, true); tab.imgShown[name] = true end
    tab.imgUsed[name] = true
end

-- (01/11) trop de carrés : on retire d'abord les plus petits carrés « secondaires » (vue GPS),
-- jamais les boutons ni les cadres (avant : les derniers dessinés sautaient)
function AS_TerminalTablet:trimRects(rec)
    local n = #rec.rects
    if n <= self.MAX_RECTS then return end
    local low = {}
    for i, r in ipairs(rec.rects) do
        if r.low then low[#low + 1] = { i = i, a = r[3] * r[4] } end
    end
    table.sort(low, function(a, b) return a.a < b.a end)
    local drop, extra = {}, n - self.MAX_RECTS
    for j = 1, math.min(extra, #low) do drop[low[j].i] = true end
    local out = {}
    for i, r in ipairs(rec.rects) do if not drop[i] then out[#out + 1] = r end end
    rec.rects = out
    if not self.loggedTrim then
        self.loggedTrim = true
        print(string.format("[AS_TerminalTablet] écran 3D : %d carrés, %d retirés de la vue (limite %d)", n, n - #out, self.MAX_RECTS))
    end
end

function AS_TerminalTablet:syncScreen(v, tab, rec)
    self:screenRoot(tab)
    tab.imgUsed = {}
    local used = {}
    local z = self.Z0
    self:trimRects(rec)
    local nr = math.min(#rec.rects, self.MAX_RECTS)
    local layer, top = {}, 0
    -- (01/11) carrés rangés par cases de 60 unités : on ne compare qu'aux voisins (avant : à tous, lent à 500 carrés)
    local GS = 60
    local buckets, stamp = {}, {}
    -- (70k) mêmes carrés (places et tailles) qu'à la reconstruction précédente : mêmes couches, pas de recalcul
    local geo = tab.lastGeo
    local same = geo ~= nil and geo.n == nr
    if same then
        for i = 1, nr do
            local r, j = rec.rects[i], 4 * i
            if r[1] ~= geo[j - 3] or r[2] ~= geo[j - 2] or r[3] ~= geo[j - 1] or r[4] ~= geo[j] then same = false; break end
        end
    end
    if same then layer, top = geo.layer, geo.top end
    for i = 1, same and 0 or nr do
        local r = rec.rects[i]
        if r[3] > 0 and r[4] > 0 then
            -- couche = 1 + la plus haute couche des carrés déjà posés qu'il recouvre
            local x1, y1, x2, y2 = r[1], r[2], r[1] + r[3], r[2] + r[4]
            local l = 0
            local gx1, gx2 = math.floor(x1 / GS), math.floor((x2 - 1e-6) / GS)
            local gy1, gy2 = math.floor(y1 / GS), math.floor((y2 - 1e-6) / GS)
            for gx = gx1, gx2 do
                for gy = gy1, gy2 do
                    local b = buckets[gx * 4096 + gy]
                    if b ~= nil then
                        for k = 1, #b do
                            local j = b[k]
                            if stamp[j] ~= i then
                                stamp[j] = i
                                local lj = layer[j]
                                if lj > l then
                                    local o = rec.rects[j]
                                    if o[1] < x2 and o[1] + o[3] > x1 and o[2] < y2 and o[2] + o[4] > y1 then l = lj end
                                end
                            end
                        end
                    end
                end
            end
            l = l + 1
            layer[i] = l
            for gx = gx1, gx2 do
                for gy = gy1, gy2 do
                    local key = gx * 4096 + gy
                    local b = buckets[key]
                    if b == nil then b = {}; buckets[key] = b end
                    b[#b + 1] = i
                end
            end
            if l > top then top = l end
        end
    end
    if not same then
        geo = { n = nr, layer = layer, top = top }
        for i = 1, nr do
            local r, j = rec.rects[i], 4 * i
            geo[j - 3], geo[j - 2], geo[j - 1], geo[j] = r[1], r[2], r[3], r[4]
        end
        tab.lastGeo = geo
    end
    -- (01/11, 37c) couches tassées : avec le guidage fin il y a des centaines de couches ; à 0,3 mm l'une,
    -- les textes flottaient plusieurs cm devant l'écran et paraissaient décalés vus de biais
    local dz = math.max(self.DZ_MIN, math.min(self.DZ, self.Z_SPAN / (top + 1)))
    tab.dz = dz
    for i = 1, nr do
        local r = rec.rects[i]
        if r[3] > 0 and r[4] > 0 then
            local l = layer[i]
            z = self.Z0 + l * dz
            if r.img ~= nil then
                self:placeImage(v, tab, r, z)
            else
            local cr, cg, cb = r[5], r[6], r[7]
            -- (31/10) écran 3D : les fonds bleus (onglet / bouton actif, bandeau) sont lumineux en jeu
            -- et le texte blanc ne se lit plus ; on les fonce
            if cb > cr and cb > cg and cb > 0.6 then cr, cg, cb = cr * self.BLUE_DIM, cg * self.BLUE_DIM, cb * self.BLUE_DIM end
            local idx = paletteIndex(cr, cg, cb, r[8])
            used[idx] = (used[idx] or 0) + 1
            local q = self:quad(tab, idx, used[idx])
            if q ~= nil then
                local x, y, k = self:panelToLocal(r[1], r[2])
                nodeSet(tab, q, x, y, z, r[3] * k, r[4] * k)   -- (70k)
            end
            end
        end
    end
    -- (31/10 soir) images pas posées cette fois : cachées
    if tab.imgNodes ~= nil then
        for name, n in pairs(tab.imgNodes) do
            if tab.imgUsed == nil or not tab.imgUsed[name] then
                if tab.imgShown ~= nil and tab.imgShown[name] then pcall(setVisibility, n, false); tab.imgShown[name] = false end
            end
        end
    end
    tab.imgUsed = {}
    -- carrés en trop : cachés
    for idx, pool in pairs(tab.pools) do
        for n = (used[idx] or 0) + 1, #pool do nodeHide(tab, pool[n]) end   -- (70k)
    end
    -- textes
    z = self.Z0 + (top + 1) * dz
    tab.screenTop = top
    local nt = #rec.texts
    local font = self:font()
    local light = self:lightBg()
    local glow, dark = self:textLook()
    tab.slashUsed = {}
    for i = 1, nt do
        local t = rec.texts[i]
        local str, size, r, g, b, em = self:prepText(rec, nr, t, font, light, glow, dark)
        local ln = self:textLine(tab, i, utf8Strlen ~= nil and utf8Strlen(str) or #str)
        if ln ~= nil then
            local x, y, k = self:panelToLocal(t[1], t[2])
            nodeSet(tab, ln.node, x, y, z)   -- (70k)
            local key = str .. "|" .. size .. "|" .. r .. g .. b .. "|" .. em .. "|" .. tostring(t[8])
            if ln.key ~= key then
                ln.key = key
                pcall(ln.cl.setSizeAndScale, ln.cl, size * k * 0.95, 1, 1)
                pcall(ln.cl.setTextAlignment, ln.cl, t[8])
                pcall(ln.cl.setColor, ln.cl, { linC(r), linC(g), linC(b), 1 }, nil, em)
                pcall(ln.cl.setText, ln.cl, str)
            end
            -- « / » absent de la police : petit trait penché à sa place
            if str:find("/", 1, true) and not self:fontHas(font, "/") then
                self:drawSlashes(tab, font, str, t[1], t[2], size, t[8], r, g, b, z)
            end
        end
    end
    -- traits « / » en trop : cachés
    for idx, pool in pairs(tab.slashPools or {}) do
        for n = (tab.slashUsed[idx] or 0) + 1, #pool do setVisibility(pool[n], false) end
    end
    for i = nt + 1, #tab.lines do
        local ln = tab.lines[i]
        if ln ~= nil then nodeHide(tab, ln.node) end   -- (70k)
    end
    tab.boxes = rec.boxes
    tab.screenOn = true
end

-- (31/10 soir) écran intégré : éteint moteur coupé ; au démarrage du moteur, écran de démarrage de 5 s
-- (logo AutoSwitch, logo de la marque, barre de chargement) ; moteur déjà en marche quand on le voit : page directe
function AS_TerminalTablet:powerState(v, tab)
    local on = true
    if v.getIsMotorStarted ~= nil then
        local ok, r = pcall(v.getIsMotorStarted, v)
        if ok then on = r == true end
    end
    local now = g_time or 0
    if tab.power ~= nil and on and not tab.power then
        tab.bootUntil = now + self.BOOT_MS
        tab.bootStart = now
        -- (31/10 soir) chiffres du tableau de bord allumés par le jeu au démarrage : recherchés à nouveau
        if tab.vehCtx ~= nil then tab.vehRescanAt = { now + 1500, now + self.BOOT_MS + 2500 } end
        log("démarrage de l'écran : %s", tostring(call(v, "getFullName") or "?"))
    end
    tab.power = on
    if not on then
        tab.bootUntil = nil
        return "off"
    end
    if tab.bootUntil ~= nil and now < tab.bootUntil then return "boot" end
    -- (31/10 soir) fin du démarrage : l'écran s'ouvre sur l'accueil
    if tab.bootUntil ~= nil then if AS_Terminal.SHARED_PAGE then AS_Terminal.page = "home" else tab.page = "home" end end
    tab.bootUntil = nil
    return "on"
end

function AS_TerminalTablet:showBoot(v, tab, on)
    if tab.bootShown == on then return end
    tab.bootShown = on
    childVis(tab, "bootAS", on)
    self:showBrand(v, tab, "bootMarque", on)
end

function AS_TerminalTablet:drawPower(v, tab, state)
    if state == "off" then
        self:showBoot(v, tab, false)
        self:hideScreen(tab)
        tab.boxes = {}
        tab.screenOn = false
        return
    end
    -- démarrage : fond noir, logos, barre qui se remplit en 5 s
    local frac = math.max(0, math.min(1, ((g_time or 0) - (tab.bootStart or 0)) / self.BOOT_MS))
    local rec = { rects = {
            { 0, 0, AS_Terminal.W, AS_Terminal.H, 0, 0, 0, 1 },
            { 225, 395, 450, 12, 0.16, 0.19, 0.22, 1 },
            { 225, 395, 450 * frac, 12, 0.20, 0.56, 0.84, 1 },
        }, texts = { { 450, 440, 14, T("boot"), 0.62, 0.66, 0.70, RenderText ~= nil and RenderText.ALIGN_CENTER or 1 } }, boxes = {} }
    if tab.scr ~= nil and tab.screenHidden then setVisibility(tab.scr, true); tab.screenHidden = false end
    local ok, err = pcall(self.syncScreen, self, v, tab, rec)
    if not ok and not self.loggedScreenError then
        self.loggedScreenError = true
        log("ERREUR écran de démarrage : %s", tostring(err))
    end
    self:showBoot(v, tab, true)
end

function AS_TerminalTablet:hideScreen(tab)
    if tab ~= nil and tab.scr ~= nil and entityExists(tab.scr) then
        setVisibility(tab.scr, false)
        tab.screenHidden = true
    end
end

-- bouton du terminal 3D sous le curseur (nil si aucun), et le curseur est-il sur l'écran
function AS_TerminalTablet:hit(v, posX, posY)
    local main = self.tablets[v]
    if main == nil or main.failed ~= nil then return nil, false end
    -- (étape 37) écran principal puis 2e / 3e écrans : le premier écran sous le curseur répond
    local onAny = false
    for _, t in ipairs(self:screensOf(main)) do
        local a, on, head = self:hitOne(t, posX, posY)
        if a ~= nil or head then return a, true, head, t end
        onAny = onAny or on
    end
    return nil, onAny
end

function AS_TerminalTablet:hitOne(tab, posX, posY)
    if tab == nil or tab.boxes == nil or not tab.screenOn then return nil, false end
    local function proj(u, vv)
        local x, y = self:panelToLocal(u, vv)
        local wx, wy, wz = localToWorld(tab.node, x, y, self.Z0)
        local sx, sy, sz = project(wx, wy, wz)
        if sx == nil or sz == nil or sz < 0 or sz > 1 then return nil end
        return sx, sy
    end
    local function inside(u, vv, w, h)
        local pts = { { u, vv }, { u + w, vv }, { u + w, vv + h }, { u, vv + h } }
        local minX, minY, maxX, maxY = 2, 2, -1, -1
        for _, p in ipairs(pts) do
            local sx, sy = proj(p[1], p[2])
            if sx == nil then return false end
            minX, maxX = math.min(minX, sx), math.max(maxX, sx)
            minY, maxY = math.min(minY, sy), math.max(maxY, sy)
        end
        return posX >= minX and posX <= maxX and posY >= minY and posY <= maxY
    end
    for i = #tab.boxes, 1, -1 do
        local b = tab.boxes[i]
        if inside(b.u, b.v, b.w, b.h) then return b.action, true end
    end
    -- (31/10 soir) bandeau du haut (hors boutons) : ouvre la grande fenêtre
    if inside(14, 14, AS_Terminal.W - 28 - 200, 30) then return nil, true, true end
    return nil, inside(0, 0, AS_Terminal.W, AS_Terminal.H)
end

function AS_TerminalTablet:updateScreen(v, tab)
    local T = AS_Terminal
    -- données relues à chaque mise à jour de l'écran (le grand terminal peut être fermé)
    -- (70k) une seule lecture pour tous les écrans d'une même reconstruction (avant : une par écran)
    local d
    local cyc = self.cycleData
    if cyc ~= nil and cyc.v == v then
        d = cyc.d
    else
        local okR, dd = pcall(T.read, T, v)
        if not okR or dd == nil then return end
        d = dd
        self.cycleData = { v = v, d = d }
        T.data, T.lastRead = d, g_time
    end
    local rec = { rects = {}, texts = {}, boxes = {} }
    local inside = call(v, "getActiveCamera") ~= nil and v:getActiveCamera().isInside == true
    local ok, err = T:withTab(tab, T.drawPanel, T, d, v, inside, nil, rec)
    if not ok then
        if not self.loggedScreenError then
            self.loggedScreenError = true
            log("ERREUR écran 3D (page) : %s", tostring(err))
        end
        return
    end
    if tab.scr ~= nil and tab.screenHidden then setVisibility(tab.scr, true); tab.screenHidden = false end
    local ok2, err2 = pcall(self.syncScreen, self, v, tab, rec)
    if not ok2 and not self.loggedScreenError then
        self.loggedScreenError = true
        log("ERREUR écran 3D : %s", tostring(err2))
    end
end

function AS_TerminalTablet:screen3dOn()
    return AS_Terminal.settings.screen3d ~= false
end

function AS_TerminalTablet:updateText(v, d)
    local tab = self.tablets[v]
    if tab == nil or tab.node == nil then return end
    local s1, s2 = "", ""
    if d ~= nil then
        s1 = string.format("%d", math.floor(math.abs(d.speed or 0) + 0.5))
        local gear = tostring(d.gear or "")
        if d.group ~= nil and not d.cvt then gear = tostring(d.group) .. gear end
        s2 = gear
    end
    if tab.line1 ~= nil and tab.t1 ~= s1 then tab.t1 = s1; pcall(tab.line1.setText, tab.line1, plain(s1)) end
    if tab.line2 ~= nil and tab.t2 ~= s2 then tab.t2 = s2; pcall(tab.line2.setText, tab.line2, plain(s2)) end
end

function AS_TerminalTablet:update(dt)
    if not self.ENABLED or AS_Terminal == nil or g_currentMission == nil then return end
    if self.template == nil then self:loadModel() end
    -- (70l) retour en vue cabine : écran 3D refait tout de suite (il était figé en vue extérieure)
    do
        local cv = AS.shGetControlledVehicle ~= nil and AS.shGetControlledVehicle() or nil
        local insideNow = cv ~= nil and self:camInside(cv)
        if insideNow and self.wasOutside then self.textTimer = math.max(self.textTimer, self.SCREEN_MS) end
        self.wasOutside = cv ~= nil and not insideNow
    end
    -- (70k) un écran par image : les 2e / 3e écrans de la reconstruction en cours, aux images qui suivent
    local pend = self.pendScreens
    if pend ~= nil then
        self.pendScreens = nil
        local v0 = AS.shGetControlledVehicle ~= nil and AS.shGetControlledVehicle() or nil
        if v0 ~= nil and v0 == pend.v and self.tablets[v0] == pend.tab and self:screen3dOn() then
            local t = pend.list[pend.i]
            if pend.i < #pend.list then pend.i = pend.i + 1; self.pendScreens = pend end
            self.textTimer = self.textTimer + (dt or 0)
            if t ~= nil then self:asTab(t, self.updateOne, self, v0, t) end
            return
        end
    end
    self.textTimer = self.textTimer + (dt or 0)
    -- (perf 07/11) images en attente de chargement (budget dépassé) : écran refait dès l'image suivante
    if self.loadWaiting then self.loadWaiting = false; self.textTimer = math.max(self.textTimer, self.SCREEN_MS) end
    if self.textTimer < (self:screen3dOn() and self.SCREEN_MS or self.TEXT_MS) then return end
    self.textTimer = 0
    self.cycleData = nil   -- (70k) données relues pour cette reconstruction
    local v = AS.shGetControlledVehicle ~= nil and AS.shGetControlledVehicle() or nil
    -- (31/10 soir) véhicule quitté : son écran d'origine revient, notre page s'éteint
    if self.lastVehicle ~= nil and self.lastVehicle ~= v then
        local old0 = self.tablets[self.lastVehicle]
        if old0 ~= nil and old0.failed == nil then
            for _, old in ipairs(self:screensOf(old0)) do
                self:restoreOriginal(old)
                if old.vehHide ~= nil then self:hideScreen(old) end
                if old.bootShown then self:showBoot(self.lastVehicle, old, false) end
            end
        end
    end
    self.lastVehicle = v
    if v ~= nil and v.rootNode ~= nil then
        local tab = self:get(v)
        -- (31/10 soir) écran du véhicule pas trouvé (pièces pas encore prêtes) : nouvelle recherche toutes les 10 s, 6 fois
        if tab ~= nil and tab.node ~= nil and self:onVehicleScreen() and tab.vehList ~= nil and #tab.vehList == 0
            and (tab.vehTries or 0) < 6 and (g_time or 0) - (tab.vehTime or 0) > 10000 then
            tab.vehTries = (tab.vehTries or 0) + 1
            self:replace(v)
        end
        if tab ~= nil and self:screen3dOn() then
            if tab.t1 ~= "" or tab.t2 ~= "" then self:updateText(v, nil) end   -- anciens chiffres 3D effacés
            -- (étape 37) écran principal puis 2e / 3e écrans, chacun avec sa page
            -- (70k) écran principal maintenant, les autres aux images suivantes (avant : tous dans la même image)
            local list = self:screensOf(tab)
            self.pendScreens = #list > 1 and { v = v, tab = tab, list = list, i = 2 } or nil
            self:asTab(list[1], self.updateOne, self, v, list[1])
        elseif tab ~= nil then
            for _, t in ipairs(self:screensOf(tab)) do
                self:restoreOriginal(t)
                self:hideScreen(t)
            end
            local d = AS_Terminal.data
            if d == nil or d.vehicle ~= v then
                local ok, dd = pcall(AS_Terminal.read, AS_Terminal, v)
                d = ok and dd or nil
            end
            self:updateText(v, d)
        end
    end
end

-- (étape 37) un écran 3D : allumage, page, image d'origine cachée, raccrochage
-- (07/11, étape 70l) caméra du conducteur dans la cabine ?
function AS_TerminalTablet:camInside(v)
    local cam = call(v, "getActiveCamera")
    return cam ~= nil and cam.isInside == true
end

function AS_TerminalTablet:updateOne(v, t)
        -- (04/11) la tablette aussi : éteinte moteur coupé, démarrage de 5 s (comme l'écran de la machine)
        local state = self:powerState(v, t)
        if state ~= "on" then
            self:drawPower(v, t, state)
        else
            if t.bootShown then self:showBoot(v, t, false) end
            -- (70l) vue extérieure : l'écran déjà construit et affiché garde sa dernière image
            if not (t.screenOn and not t.screenHidden and not self:camInside(v)) then
                self:updateScreen(v, t)
            end
        end
        -- le jeu peut rallumer l'image d'origine (moteur démarré...) : recachée
        if t.vehHide ~= nil then self:hideOriginal(t) end
        if t.integrated and t.vehRescanAt ~= nil and t.vehRescanAt[1] ~= nil and (g_time or 0) >= t.vehRescanAt[1] then
            table.remove(t.vehRescanAt, 1)
            self:rescanGlass(v, t)
        end
        -- (31/10 soir) secours : la pièce qui porte le terminal a changé de taille (mode sombre d'un mod,
        -- animation...) : le terminal disparaîtrait, on le raccroche (5 fois au plus)
        if self.FIX_SCALE and t.integrated and t.expScale ~= nil and t.expScale > 0 and t.parentNode ~= nil
            and (g_time or 0) - (t.scaleCheck or 0) >= 1000 then
            t.scaleCheck = g_time or 0
            local s = effScale(t.node, t.parentNode)
            if (s < t.expScale * 0.5 or s > t.expScale * 2) and (t.rescues or 0) < 5 then
                t.rescues = (t.rescues or 0) + 1
                local okN, an = pcall(getName, t.anchor)
                log("écran du véhicule %s : la pièce %s qui porte le terminal a changé de taille (%.2f au lieu de %.2f), terminal raccroché",
                    tostring(v.getFullName ~= nil and v:getFullName() or "?"), okN and tostring(an) or "?", s, t.expScale)
                t.avoid = t.avoid or {}
                if t.anchor ~= nil then t.avoid[t.anchor] = true end
                self:restoreOriginal(t)
                self:replace(v)
            end
        end
end

function AS_TerminalTablet:loadMap()
    self:loadModel()
    if addConsoleCommand ~= nil then
        addConsoleCommand("asTmText", "Terminal 3D, thème clair : lumière des lettres (0 à 1) et teinte des couleurs (0,1 à 1). Ex. asTmText 0.15 0.62",
            "consoleText", self)
    end
end

-- (01/11) réglage en jeu de la lisibilité des textes de couleur sur fond clair (gardé dans terminal.xml)
function AS_TerminalTablet:consoleText(glow, dark)
    local s = AS_Terminal.settings
    local g, d = tonumber(glow), tonumber(dark)
    if g ~= nil then s.textGlow = math.max(0, math.min(1, g)) end
    if d ~= nil then s.textDark = math.max(0.1, math.min(1, d)) end
    if g ~= nil or d ~= nil then pcall(AS_Terminal.saveSettings, AS_Terminal) end
    local cg, cd = self:textLook()
    return string.format("Terminal 3D thème clair : lumière %.2f, teinte %.2f (défaut %.2f / %.2f)", cg, cd, self.TEXT_GLOW, self.TEXT_DARK)
end

function AS_TerminalTablet:deleteMap()
    if removeConsoleCommand ~= nil then pcall(removeConsoleCommand, "asTmText") end
    self:removeAll()
    if self.request ~= nil and g_i3DManager ~= nil then
        pcall(g_i3DManager.releaseSharedI3DFile, g_i3DManager, self.request)
        self.request = nil
    end
    if self.template then pcall(delete, self.template) end
    self.template, self.loading = nil, false
end

addModEventListener(AS_TerminalTablet)
