-- AutoSwitch : terminal de bord (Ctrl droit + T), comme les terminaux des vrais tracteurs
-- Fichier chargé par AutoSwitch.lua (après Common.lua).

local L = AS.L

-------------------------------------------------------------------------------
-- v1.0.4.0 (étape 1) : grand panneau du terminal.
--   Ctrl droit + T : afficher / masquer. Ctrl droit + Y : mode tactile (curseur),
--   le curseur d'Interactive Control ou d'une autre fenêtre marche aussi.
--   Colonne de gauche toujours visible : lieu, vitesse, couverture, consommation,
--   heures de travail. Barre du bas : état du relevage, des outils, du guidage, et
--   les pages Tracteur, Outil, Travail, Compteurs ; Réglages par le bouton du haut.
--   Position et taille sauvées par modèle de véhicule et par vue (cabine / dehors) :
--   en mode tactile, on attrape le bandeau bleu pour le déplacer.
--   Compteurs par véhicule (travail 1, travail 2, total) : hectares, temps moteur,
--   carburant, distance ; gardés avec la partie (savegameX/autoSwitchTerminal.xml).
--   Hectares = distance parcourue outil au travail x largeur de travail (marqueurs
--   de l'IA de l'outil), comme sur un vrai terminal.
-- v1.0.4.0 (étape 4) : commandes. ARRÊT coupe l'aide qui conduit (Courseplay, ouvrier IA,
--   AutoDrive), sinon le régulateur et les machines ; RELEVAGE, MARCHE (prise de force)
--   et pliage (page Outil) pour tout le train d'outils ; GUIDAGE ouvre la page Courseplay
--   (démarrer / arrêter, créer ou effacer le parcours du champ, point de départ, largeur,
--   tournières, menu de CP). Tout passe par les fonctions du jeu, de CP et d'AutoDrive.
-------------------------------------------------------------------------------
local renderOverlay = (AS ~= nil and AS.renderOverlay) or renderOverlay   -- (perf 07/11) voir Common.lua
AS_Terminal = {}
AS_Terminal.ENABLED   = true
-- (01/11, étape 37b) mise en page : l'ancienne est gardée ;
-- les nouveautés de l'étape 37 restent derrière ces interrupteurs
AS_Terminal.BIG_TEXT = false      -- textes agrandis (x1,3)
AS_Terminal.SHORT_TABS = false    -- barre du bas réduite avec PLUS
AS_Terminal.THIN_FRAME = false    -- cadre fin en tranches (grande fenêtre ; la tablette suit le i3d)
AS_Terminal.W, AS_Terminal.H = 900, 500   -- taille du panneau en pixels (écran 1080p, taille 100 %)
AS_Terminal.REFRESH_MS = 200               -- (70m, petits PC) données relues 5 fois par seconde, panneau affiché (avant 10)
AS_Terminal.COUNT_MS   = 250               -- compteurs mis à jour 4 fois par seconde
AS_Terminal.SAVE_NAME  = "autoSwitchTerminal.xml"
AS_Terminal.SET_NAME   = "terminal.xml"
-- (31/10 soir) ACCUEIL en premier (style FendtONE), TRACTEUR devient INFO
AS_Terminal.PAGES = { "home", "tractor", "tool", "work", "gps", "fp", "count", "set" }   -- (01/11) "fp" = FarmPilot (si présent)   -- (01/11) page GPS à la place de la page Courseplay

AS_Terminal.isOpen  = false
AS_Terminal.touch   = false
AS_Terminal.page    = "home"
AS_Terminal.data    = nil
AS_Terminal.lastRead = -100000
AS_Terminal.boxes   = {}
AS_Terminal.settings = { size = 70, show = 1, touchStopped = false, beeps = true, cpHudBlock = true, fpHudHide = true, fuelReserve = 10, tablet = true, screen3d = true, tabPreset = 1, theme = 3, display = 1, rearCam = true }
AS_Terminal.positions = {}                 -- ["fichier du véhicule|cab"] = { x, y }
AS_Terminal.counters = {}                  -- [uniqueId] = { active = 1, jobs = { {...}, {...} }, total = {...} }
AS_Terminal.countTimer = 0
AS_Terminal.alarm = {}

local function log(fmt, ...)
    (AS.rawPrint or print)("[AS_Terminal] " .. string.format(fmt, ...))
end

-- (01/11, étape 36) FarmPilot (version modifiée d'AutoDrive) : mêmes fonctions, son nom affiché
local function isFarmPilot()
    return g_modIsLoaded ~= nil and g_modIsLoaded["FS25_FarmPilot"] == true
end
local FP_KEYS = { g_AD = "g_FP", adStartStop = "fpStartStop" }
local function T(key)
    if FP_KEYS[key] ~= nil and isFarmPilot() then key = FP_KEYS[key] end
    return L("vtpas_tm_" .. key)
end
-- globales de FarmPilot (ou d'AutoDrive)
local function adGlobal(name)
    if isFarmPilot() then
        local g = AS.modGlobal("FS25_FarmPilot", name)
        if g ~= nil then return g end
    end
    return AS.modGlobal("FS25_AutoDrive", name)
end

-- (31/10) drawFilledRect et les overlays prennent des couleurs linéaires : les couleurs d'écran
-- (sRGB) de la palette sont converties, sinon les gris foncés sortent délavés (gris clair)
local function lin(c)
    if c <= 0.04045 then return c / 12.92 end
    return ((c + 0.055) / 1.055) ^ 2.4
end
AS_Terminal.lin = lin

local function call(obj, name, ...)
    if obj == nil or type(obj[name]) ~= "function" then return nil end
    local ok, a, b, c, d = pcall(obj[name], obj, ...)
    if ok then return a, b, c, d end
    return nil
end

local function clamp(v, a, b) return math.max(a, math.min(b, v)) end

local function uiScale()
    local s = 1
    if g_gameSettings ~= nil and g_gameSettings.getValue ~= nil then
        local ok, v = pcall(g_gameSettings.getValue, g_gameSettings, "uiScale")
        if ok and type(v) == "number" and v > 0 then s = v end
    end
    return s
end

-- (01/11) distW : distance parcourue au travail (outil baissé et en marche)
-- (04/11 nuit) msW / fuelW : temps et carburant au travail (page Tâches du Massey : au travail / hors travail)
local function newCounter() return { ha = 0, ms = 0, fuel = 0, dist = 0, distW = 0, msW = 0, fuelW = 0 } end

-------------------------------------------------------------------------------
-- Lecture du véhicule
-------------------------------------------------------------------------------

-- tous les objets du train (tracteur + outils), sans doublon
local function trainOf(vehicle)
    local list, seen = { vehicle }, { [vehicle] = true }
    local ch = vehicle.getChildVehicles ~= nil and call(vehicle, "getChildVehicles") or nil
    if type(ch) == "table" then
        for _, v in pairs(ch) do
            if type(v) == "table" and not seen[v] then seen[v] = true; list[#list + 1] = v end
        end
    end
    return list
end

-- largeur de travail d'un outil : écart entre ses marqueurs gauche / droite de l'IA
local function workWidth(obj)
    if obj.getAIMarkers == nil then return nil end
    local l, r = call(obj, "getAIMarkers")
    if l == nil or r == nil or l == 0 or r == 0 then return nil end
    local ok, x1, _, z1 = pcall(getWorldTranslation, l)
    local ok2, x2, _, z2 = pcall(getWorldTranslation, r)
    if not ok or not ok2 then return nil end
    local w = math.sqrt((x1 - x2) ^ 2 + (z1 - z2) ^ 2)
    if w < 0.5 then return nil end
    return w
end

local function isLowered(obj)
    if obj.getIsLowered == nil then return nil end
    return call(obj, "getIsLowered", false) == true
end

local function isTurnedOn(obj)
    if obj.getIsTurnedOn == nil then return nil end
    return call(obj, "getIsTurnedOn") == true
end

-- (04/11) le jeu dit « baissé » pour un semoir traîné
-- ou posé sur une herse même relevé : on demande aussi au jeu si ses zones de travail travaillent vraiment
-- (contact au sol par ses capteurs, en marche...). nil = outil sans zone de travail
local function workAreasActive(obj)
    local wa = obj.spec_workArea
    if wa == nil or type(wa.workAreas) ~= "table" or #wa.workAreas == 0 or obj.getIsWorkAreaActive == nil then return nil end
    local tried = false
    for _, a in ipairs(wa.workAreas) do
        local ok, act = pcall(obj.getIsWorkAreaActive, obj, a)
        if ok then
            tried = true
            if act == true then return true end
        end
    end
    if not tried then return nil end
    return false
end

-- (04/11) pulvé, épandeur, tonne : au travail seulement quand il est en marche (il pulvérise), baissé ou non ;
-- pas les semoirs (avec engrais) ni les outils de sol (injecteurs), qui doivent être baissés
local function sprayOnly(obj)
    return obj.spec_sprayer ~= nil and obj.spec_sowingMachine == nil and obj.spec_cultivator == nil and obj.spec_plow == nil
end

-- outil au travail : baissé (outil qui se baisse) et en marche (outil qui s'allume), et zones de travail actives
local function isWorking(obj)
    local low, on = isLowered(obj), isTurnedOn(obj)
    if on ~= nil and sprayOnly(obj) then
        if not on then return false end
        return workAreasActive(obj) ~= false
    end
    if low == nil and on == nil then return false end
    if low == false or on == false then return false end
    if workAreasActive(obj) == false then return false end
    return true
end

local function fillPercent(obj, ftIndex)
    local idx = call(obj, "getConsumerFillUnitIndex", ftIndex)
    if idx == nil then return nil end
    local cap = call(obj, "getFillUnitCapacity", idx) or 0
    if cap <= 0 then return nil end
    local lvl = call(obj, "getFillUnitFillLevel", idx) or 0
    return lvl / cap, lvl
end

local function fillTypeTitle(index)
    if index == nil or g_fillTypeManager == nil then return "" end
    local ft = g_fillTypeManager:getFillTypeByIndex(index)
    return ft ~= nil and (ft.title or ft.name) or ""
end

-- (31/10) outil qui se baisse lui-même (attelé au timon / à la chape) : pick-up de presse,
-- autochargeuse, andaineur... (Pickup) ou outil traîné qui se baisse par son pliage du milieu
local function ownLowerKind(o)
    if o == nil then return nil end
    if o.spec_pickup ~= nil and o.setPickupState ~= nil then return "pickup" end
    local f = o.spec_foldable
    if f ~= nil and f.foldMiddleAnimTime ~= nil and f.hasFoldingParts and o.getIsFoldMiddleAllowed ~= nil then return "fold" end
    return nil
end

-- l'attelage qui porte l'outil le baisse-t-il (3 points) ?
local function jointLowers(o)
    local av = o.getAttacherVehicle ~= nil and call(o, "getAttacherVehicle") or nil
    if av == nil or av.spec_attacherJoints == nil then return false end
    local idx = call(av, "getAttacherJointIndexFromObject", o)
    local jd = idx ~= nil and av.spec_attacherJoints.attacherJoints ~= nil and av.spec_attacherJoints.attacherJoints[idx] or nil
    if jd == nil or jd.allowsLowering ~= true then return false end
    local ok, allows = pcall(o.getAllowsLowering, o)
    return o.getAllowsLowering == nil or (ok and allows == true)
end

-- relevages du tracteur : avant / arrière, position 0 (baissé) à 1 (levé)
local function hitches(vehicle)
    local out = {}
    local spec = vehicle.spec_attacherJoints
    if spec == nil or spec.attachedImplements == nil then return out end
    for _, impl in pairs(spec.attachedImplements) do
        local jd = spec.attacherJoints ~= nil and spec.attacherJoints[impl.jointDescIndex] or nil
        if jd ~= nil and jd.moveAlpha ~= nil and jd.upperAlpha ~= nil and jd.lowerAlpha ~= nil
            and jd.jointTransform ~= nil then
            local _, _, z = localToLocal(jd.jointTransform, vehicle.rootNode, 0, 0, 0)
            local range = jd.lowerAlpha - jd.upperAlpha
            local up = math.abs(range) > 0.0001 and clamp((jd.lowerAlpha - jd.moveAlpha) / range, 0, 1) or 0
            local h = { front = z > 0, up = up, moveDown = jd.moveDown == true, object = impl.object }
            -- (31/10) attelage qui ne baisse pas (timon) : on montre le relevage de l'outil lui-même
            local kind = jd.allowsLowering ~= true and ownLowerKind(impl.object) or nil
            if kind ~= nil then
                h.own = kind
                h.moveDown = isLowered(impl.object) == true
                h.up = h.moveDown and 0 or 1
            end
            out[#out + 1] = h
        elseif jd ~= nil and jd.jointTransform ~= nil and ownLowerKind(impl.object) ~= nil then
            local _, _, z = localToLocal(jd.jointTransform, vehicle.rootNode, 0, 0, 0)
            local low = isLowered(impl.object) == true
            out[#out + 1] = { front = z > 0, up = low and 0 or 1, moveDown = low, object = impl.object, own = ownLowerKind(impl.object) }
        end
    end
    return out
end

local function vehicleName(v)
    local n = call(v, "getFullName") or call(v, "getName")
    return tostring(n or "?")
end

local function fieldAt(x, z)
    if g_fieldManager ~= nil and g_fieldManager.getFieldAtWorldPosition ~= nil then
        local ok, f = pcall(g_fieldManager.getFieldAtWorldPosition, g_fieldManager, x, z)
        if ok and f ~= nil then return f end
    end
    -- (31/10) FS25 : pas de getFieldAtWorldPosition, on passe par la parcelle (comme AS_Champs)
    if g_farmlandManager ~= nil and g_farmlandManager.getFarmlandAtWorldPosition ~= nil then
        local ok, fl = pcall(g_farmlandManager.getFarmlandAtWorldPosition, g_farmlandManager, x, z)
        if ok and fl ~= nil and fl.field ~= nil then return fl.field end
    end
    return nil
end

local function fieldNumber(f)
    if f == nil then return nil end
    local id = call(f, "getId")
    if type(id) ~= "number" and f.farmland ~= nil and type(f.farmland.id) == "number" then id = f.farmland.id end
    if id == nil then id = f.fieldId end
    return id
end

local function guidance(v)
    if AS.isCourseplayActive ~= nil then
        local ok, cp = pcall(AS.isCourseplayActive, v)
        if ok and cp then return "CP" end
    end
    if AS.isAutoDriveActive ~= nil then
        local ok, ad = pcall(AS.isAutoDriveActive, v)
        if ok and ad then return "AD" end
    end
    if call(v, "getIsAIActive") == true then return "IA" end
    return nil
end

-- (03/11) attelage (avant = true) qui porte l'outil o : on remonte la chaîne jusqu'au 1er outil attelé au tracteur
local function hitchSideOf(v, o)
    local p, guard = o, 0
    while guard < 8 do
        local av = call(p, "getAttacherVehicle")
        if av == nil or av == v then break end
        p = av; guard = guard + 1
    end
    for _, h in ipairs(hitches(v)) do if h.object == p then return h.front end end
    return false
end
-- (03/11) fonctions AV / AR / les deux : self.cmdSide limite une commande aux outils d'un côté
-- (true = AV, false = AR, nil = tous)
local function onSide(self, v, o)
    local sd = self.cmdSide
    if sd == nil then return true end
    if o == v then return false end
    return hitchSideOf(v, o) == sd
end

-- toutes les valeurs affichées, relues REFRESH_MS
function AS_Terminal:read(v)
    local d = { vehicle = v, name = vehicleName(v) }
    d.speed = call(v, "getLastSpeed") or 0
    local x, _, z = getWorldTranslation(v.rootNode)
    local f = fieldAt(x, z)
    d.field = fieldNumber(f)
    d.fieldHa = f ~= nil and tonumber(f.areaHa) or nil

    local spec = v.spec_motorized
    local motor = call(v, "getMotor")
    d.motorOn = call(v, "getIsMotorStarted") == true
    if motor ~= nil then
        d.rpm = call(motor, "getLastModulatedMotorRpm") or call(motor, "getLastMotorRpm")
        d.maxRpm = call(motor, "getMaxRpm")
        local g, available = call(motor, "getGearInfoToDisplay")
        d.gear = g or call(motor, "getGearToDisplay", false) or "N"
        if motor.gearGroups ~= nil and motor.activeGearGroupIndex ~= nil then
            local gg = motor.gearGroups[motor.activeGearGroupIndex]
            if gg ~= nil and gg.name ~= nil then d.group = gg.name end
        end
        d.cvt = available == false or (motor.forwardGears == nil and motor.backwardGears == nil)
        d.dir = call(v, "getDrivingDirection") or 0
    end
    d.load = call(v, "getMotorLoadPercentage")
    if spec ~= nil then
        d.fuelUse = spec.lastFuelUsage or 0
        d.temp = spec.motorTemperature ~= nil and spec.motorTemperature.value or nil
    end
    if FillType ~= nil then
        d.fuel, d.fuelL = fillPercent(v, FillType.DIESEL)
        if d.fuel == nil and FillType.ELECTRICCHARGE ~= nil then d.fuel, d.fuelL = fillPercent(v, FillType.ELECTRICCHARGE) end
        if d.fuel == nil and FillType.METHANE ~= nil then d.fuel, d.fuelL = fillPercent(v, FillType.METHANE) end
        if FillType.DEF ~= nil then d.def = fillPercent(v, FillType.DEF) end
    end
    d.cruise = call(v, "getCruiseControlState")
    d.cruiseSpeed = call(v, "getCruiseControlSpeed")
    d.opHours = (call(v, "getOperatingTime") or 0) / 3600000
    d.damage = call(v, "getDamageAmount")
    d.dirt = call(v, "getDirtAmount")
    d.guide = guidance(v)
    -- (31/10 soir) écran d'accueil : feux, vitesse maxi
    local spl = v.spec_lights
    if spl ~= nil then
        local mask = call(v, "getLightsTypesMask") or spl.lightsTypesMask or 0
        local beacon = call(v, "getBeaconLightsVisibility")
        if beacon == nil then beacon = spl.beaconLightsActive end
        d.lights = { mask = mask, beacon = beacon == true, turn = call(v, "getTurnLightState") or spl.turnLightState or 0 }
    end
    if motor ~= nil then
        local ms = call(motor, "getMaximumForwardSpeed")
        if type(ms) == "number" and ms > 1 then d.maxSpeed = ms * 3.6 end
        -- (02/11 soir) vitesse de travail = limite de vitesse des outils attelés (case R2 de l'accueil Case)
        local okW, ws = pcall(v.getSpeedLimit, v, true)
        if okW and type(ws) == "number" and ws > 0 and ws < 500 then d.workSpeed = ws end
    end

    -- AutoSwitch : transmission, blocages, mode, patinage, usure des pneus
    if AS.drivenAxle ~= nil then
        local ok, t = pcall(AS.drivenAxle, v)
        if ok then d.trans = t end
    end
    local is = v.vData ~= nil and v.vData.is or nil
    if is ~= nil and AS.isLockedValue ~= nil then
        d.lockF = AS.isLockedValue(is[1])
        d.lockR = AS.isLockedValue(is[2])
        if type(is[3]) == "number" then d.awd = is[3] ~= 0 end   -- Enhanced Vehicle : 0 = 4x2
    end
    if AS_Diff ~= nil and AS_Diff.isManual ~= nil and not AS_Diff.disabled then
        local ok, m = pcall(AS_Diff.isManual, v)
        if ok then d.manual = m end
    end
    if AS.getMaxSlipPercent ~= nil then
        local ok, s = pcall(AS.getMaxSlipPercent, v)
        if ok then d.slip = s end
    end
    if AS_TireLife ~= nil and AS_TireLife.getCornerWear ~= nil and not AS_TireLife.disabled then
        local ok, cw = pcall(AS_TireLife.getCornerWear, AS_TireLife, v)
        if ok then d.wear = cw end
    end

    -- outils
    d.hitches = hitches(v)
    d.tools = {}
    d.anyLowered, d.anyOn, d.anyLowerable, d.anyTurnable = false, false, false, false
    for _, o in ipairs(trainOf(v)) do
        -- (01/11) masses : pas des outils
        if o ~= v and not (AS_TerminalTools ~= nil and AS_TerminalTools.isWeight(o)) then
            local t = { name = vehicleName(o), lowered = isLowered(o), on = isTurnedOn(o), width = workWidth(o), working = isWorking(o) }
            if AS_TerminalTools ~= nil then t.img = AS_TerminalTools.storeImage(o) end
            if o.getIsUnfolded ~= nil and o.spec_foldable ~= nil and o.spec_foldable.foldingParts ~= nil
                and #o.spec_foldable.foldingParts > 0 then
                t.unfolded = call(o, "getIsUnfolded") == true
            end
            t.fills = {}
            local fus = call(o, "getFillUnits")
            if type(fus) == "table" then
                for i, fu in ipairs(fus) do
                    if (fu.capacity or 0) > 0 and fu.showOnHud ~= false and #t.fills < 2 then
                        -- (31/10) vide : « Vide » au lieu du type inconnu
                        local title = (fu.fillLevel or 0) <= 0.5 and T("m_empty") or fillTypeTitle(fu.fillType)
                        t.fills[#t.fills + 1] = { level = fu.fillLevel or 0, cap = fu.capacity, title = title }
                    end
                end
            end
            -- (31/10) benne : état du déchargement et côté ; bâche
            if o.spec_trailer ~= nil and o.spec_dischargeable ~= nil and o.getDischargeState ~= nil then
                local spT = o.spec_trailer
                local tipSides = spT.tipSides or {}
                local side = tipSides[spT.preferedTipSideIndex or 1]
                t.tip = { state = call(o, "getDischargeState") or 0, side = side ~= nil and (side.name or "") or "",
                    sides = #tipSides }
                d.anyTip = true
                if t.tip.state ~= 0 then d.tipping = true end
                if t.tip.sides > 1 then d.anyTipSide = true; d.tipSideName = t.tip.side end
            end
            if o.spec_cover ~= nil and o.spec_cover.covers ~= nil and #o.spec_cover.covers > 0 then
                t.cover = (o.spec_cover.state or 0) ~= 0
                d.anyCover = true
                if t.cover then d.coverOpen = true end
            end
            if t.lowered ~= nil then d.anyLowerable = true; if t.lowered then d.anyLowered = true end end
            if t.on ~= nil then d.anyTurnable = true; if t.on then d.anyOn = true end end
            d.tools[#d.tools + 1] = t
        end
    end
    -- moissonneuse, ensileuse : la machine elle-même travaille
    local own = { lowered = isLowered(v), on = isTurnedOn(v) }
    if own.on ~= nil then d.anyTurnable = true; if own.on then d.anyOn = true end end

    -- (31/10) machine : épandeur, moissonneuse, ensileuse, récolteuse (+ Realistic Harvesting)
    if AS_TerminalMachine ~= nil then
        local ok, err = pcall(AS_TerminalMachine.read, AS_TerminalMachine, v, d)
        if not ok then
            d.mach = nil
            if not self.loggedMachError then self.loggedMachError = true; log("ERREUR machine : %s", tostring(err)) end
        end
    end

    -- compteurs du véhicule
    -- (02/11 soir) PERF1 Case : température extérieure, prises de force (outil à prise de force attelé et en marche)
    local env = g_currentMission ~= nil and g_currentMission.environment or nil
    local wth = env ~= nil and env.weather or nil
    if wth ~= nil and wth.getCurrentTemperature ~= nil then
        local okT, tOut = pcall(wth.getCurrentTemperature, wth)
        if okT and type(tOut) == "number" then d.tempOut = tOut end
    end
    if motor ~= nil and d.rpm ~= nil then
        local ratio = motor.ptoMotorRpmRatio
        if type(ratio) ~= "number" or ratio <= 0 then ratio = 4 end
        d.ptoRpm = d.rpm / ratio
    end
    d.ptoR, d.ptoF = false, false
    for _, o in ipairs(trainOf(v)) do
        if o ~= v and o.spec_powerConsumer ~= nil and isTurnedOn(o) then
            local front = false
            for _, h in ipairs(d.hitches or {}) do if h.object == o and h.front then front = true end end
            if front then d.ptoF = true else d.ptoR = true end
        end
    end
    d.cnt = self:getCounter(v)
    -- (01/11) page OUTIL façon ISOBUS : un onglet par outil (TerminalTools.lua)
    d.toolTabs = nil
    if AS_TerminalTools ~= nil then
        local okT, errT = pcall(AS_TerminalTools.read, AS_TerminalTools, v, d)
        if not okT then
            d.toolTabs = nil
            if not self.loggedToolsError then self.loggedToolsError = true; log("ERREUR outils : %s", tostring(errT)) end
        end
    end
    -- (01/11) page GPS : ligne suivie, écart, demi-tour, avancement (TerminalGps.lua, parcours Courseplay)
    d.gps = nil
    if AS_TerminalGps ~= nil then
        local okG, errG = pcall(AS_TerminalGps.read, AS_TerminalGps, v, d)
        if not okG then
            d.gps = nil
            if not self.loggedGpsError then self.loggedGpsError = true; log("ERREUR GPS : %s", tostring(errG)) end
        end
    end
    return d
end

-------------------------------------------------------------------------------
-- Compteurs
-------------------------------------------------------------------------------
local function counterKey(v)
    return v.uniqueId or v
end

function AS_Terminal:getCounter(v)
    local key = counterKey(v)
    local c = self.counters[key]
    if c == nil then
        c = { active = 1, jobs = { newCounter(), newCounter() }, total = newCounter() }
        self.counters[key] = c
    end
    return c
end

-- largeur travaillée en ce moment (la plus large des machines au travail du train)
local function currentWorkWidth(v)
    local w = 0
    for _, o in ipairs(trainOf(v)) do
        if isWorking(o) then
            local ww = workWidth(o)
            if ww ~= nil and ww > w then w = ww end
        end
    end
    return w
end

function AS_Terminal:updateCounters(dtMs)
    local vehicles = AS.getVehicles ~= nil and AS.getVehicles() or {}
    for _, v in pairs(vehicles) do
        if type(v) == "table" and v.spec_motorized ~= nil and v.rootNode ~= nil
            and call(v, "getIsMotorStarted") == true then
            local c = self:getCounter(v)
            local speed = call(v, "getLastSpeed") or 0          -- km/h
            local dist = speed > 0.5 and speed / 3.6 * dtMs / 1000 or 0
            local fuel = (v.spec_motorized.lastFuelUsage or 0) * dtMs / 3600000
            local ha, distW = 0, 0
            if dist > 0 then
                local ok, w = pcall(currentWorkWidth, v)
                if ok and w > 0 then ha = w * dist / 10000; distW = dist end
            end
            -- (04/11 nuit) tâche : TC coupé ou tâche en pause = la tâche ne compte pas (le total compte toujours) ;
            -- filtre champ = la tâche ne compte que sur son champ (champ relu chaque seconde)
            local job = c.jobs[c.active]
            local rec = c.tc ~= false and c.pause ~= true
            if rec and job.flt and job.field ~= nil then
                c.fldT = (c.fldT or 0) + dtMs
                if c.fldAt == nil or c.fldT >= 1000 then
                    c.fldT = 0
                    local x, _, z = getWorldTranslation(v.rootNode)
                    c.fldAt = fieldNumber(fieldAt(x, z)) or false
                end
                rec = c.fldAt == job.field
            end
            local work = distW > 0
            for _, k in ipairs(rec and { job, c.total } or { c.total }) do
                k.ms = k.ms + dtMs
                k.dist = k.dist + dist
                k.distW = (k.distW or 0) + distW
                k.fuel = k.fuel + fuel
                k.ha = k.ha + ha
                if work then k.msW = (k.msW or 0) + dtMs; k.fuelW = (k.fuelW or 0) + fuel end
            end
            -- (01/11) compteurs de chaque outil (page OUTIL)
            if AS_TerminalTools ~= nil then
                local okT, errT = pcall(AS_TerminalTools.count, AS_TerminalTools, v, dist, dtMs)
                if not okT and not self.loggedToolCount then self.loggedToolCount = true; log("ERREUR compteurs outils : %s", tostring(errT)) end
            end
        end
    end
end

-------------------------------------------------------------------------------
-- Réglages et positions (modSettings/FS25_AutoSwitch/terminal.xml)
-------------------------------------------------------------------------------
local function settingsPath()
    local dir = (AS_Settings ~= nil and AS_Settings.MOD_DIR_NAME) or "FS25_AutoSwitch"
    return getUserProfileAppPath() .. "modSettings/" .. dir .. "/", AS_Terminal.SET_NAME
end

function AS_Terminal:loadSettings()
    local dir, name = settingsPath()
    local path = dir .. name
    if not fileExists(path) then return end
    local xml = loadXMLFile("asTerminal", path)
    if xml == nil or xml == 0 then return end
    local s = self.settings
    s.size = clamp(getXMLInt(xml, "terminal.settings#size") or s.size, 40, 150)
    s.show = clamp(getXMLInt(xml, "terminal.settings#show") or s.show, 1, 3)
    local b = getXMLBool(xml, "terminal.settings#touchStopped3"); if b ~= nil then s.touchStopped = b end
    b = getXMLBool(xml, "terminal.settings#beeps"); if b ~= nil then s.beeps = b end
    b = getXMLBool(xml, "terminal.settings#cpHudBlock"); if b ~= nil then s.cpHudBlock = b end
    b = getXMLBool(xml, "terminal.settings#fpHudHide"); if b ~= nil then s.fpHudHide = b end
    b = getXMLBool(xml, "terminal.settings#tablet"); if b ~= nil then s.tablet = b end
    b = getXMLBool(xml, "terminal.settings#screen3d"); if b ~= nil then s.screen3d = b end
    b = getXMLBool(xml, "terminal.settings#rearCam"); if b ~= nil then s.rearCam = b end
    s.tabPreset = clamp(getXMLInt(xml, "terminal.settings#tabPreset2") or s.tabPreset, 1, 2)
    s.theme = clamp(getXMLInt(xml, "terminal.settings#theme") or s.theme, 1, 3)
    -- (31/10 soir) thème « Marque » (écran de chaque marque) : choisi une fois pour tous
    if getXMLInt(xml, "terminal.settings#themeV") == nil then s.theme = 3 end
    s.display = clamp(getXMLInt(xml, "terminal.settings#display") or s.display, 1, 3)
    if AS_Terminal.applyTheme ~= nil then AS_Terminal:applyTheme(s.theme) end
    s.fuelReserve = clamp(getXMLInt(xml, "terminal.settings#fuelReserve") or s.fuelReserve, 0, 50)
    s.dfTheme = clamp(getXMLInt(xml, "terminal.settings#dfTheme") or s.dfTheme or 1, 1, 3)   -- (06/11) iMonitor Deutz : Auto / Clair / Sombre
    s.dfHome = clamp(getXMLInt(xml, "terminal.settings#dfHome") or s.dfHome or 1, 1, 4)      -- (06/11) iMonitor : écran d'accueil
    local cc = getXMLString(xml, "terminal.settings#caseCol")   -- (06/11) colonne de gauche Case / Steyr / NH
    if cc ~= nil then s.caseCol = cc; self.colCache = nil end
    -- (01/11) écran 3D, thème clair : lumière et teinte des textes (commande console asTmText)
    local tg, td = getXMLFloat(xml, "terminal.settings#textGlow"), getXMLFloat(xml, "terminal.settings#textDark")
    if tg ~= nil then s.textGlow = clamp(tg, 0, 1) end
    if td ~= nil then s.textDark = clamp(td, 0.1, 1) end
    local i = 0
    while true do
        local k = string.format("terminal.positions.pos(%d)", i)
        if not hasXMLProperty(xml, k) then break end
        local key = getXMLString(xml, k .. "#key")
        local x, y = getXMLFloat(xml, k .. "#x"), getXMLFloat(xml, k .. "#y")
        if key ~= nil and x ~= nil and y ~= nil then
            self.positions[key] = { x = x, y = y, z = getXMLFloat(xml, k .. "#z"), name = getXMLString(xml, k .. "#name"),
                s = getXMLInt(xml, k .. "#s"), rx = getXMLInt(xml, k .. "#rx"), ry = getXMLInt(xml, k .. "#ry"), scr = getXMLInt(xml, k .. "#scr"), scr2 = getXMLInt(xml, k .. "#scr2"), scr3 = getXMLInt(xml, k .. "#scr3"), ori = getXMLInt(xml, k .. "#ori"),
                sw = getXMLInt(xml, k .. "#sw"), sh = getXMLInt(xml, k .. "#sh"), rz = getXMLInt(xml, k .. "#rz"),
                tiles = getXMLString(xml, k .. "#tiles"),
                lockF = getXMLInt(xml, k .. "#lockF"), lockR = getXMLInt(xml, k .. "#lockR"), rem = getXMLString(xml, k .. "#rem"), hyd = getXMLString(xml, k .. "#hyd"), hset = getXMLString(xml, k .. "#hset"), pto = getXMLString(xml, k .. "#pto"), qa = getXMLString(xml, k .. "#qa"), fk = getXMLString(xml, k .. "#fk"), mfw = getXMLString(xml, k .. "#mfw"), sc = getXMLString(xml, k .. "#sc") }
        end
        i = i + 1
    end
    delete(xml)
end

function AS_Terminal:saveSettings()
    local dir, name = settingsPath()
    createFolder(getUserProfileAppPath() .. "modSettings/")
    createFolder(dir)
    local xml = createXMLFile("asTerminal", dir .. name, "terminal")
    if xml == nil or xml == 0 then return end
    local s = self.settings
    setXMLInt(xml, "terminal.settings#size", s.size)
    setXMLInt(xml, "terminal.settings#show", s.show)
    setXMLBool(xml, "terminal.settings#touchStopped3", s.touchStopped)
    setXMLBool(xml, "terminal.settings#beeps", s.beeps)
    setXMLBool(xml, "terminal.settings#cpHudBlock", s.cpHudBlock ~= false)
    setXMLBool(xml, "terminal.settings#fpHudHide", s.fpHudHide ~= false)
    setXMLBool(xml, "terminal.settings#tablet", s.tablet)
    setXMLBool(xml, "terminal.settings#screen3d", s.screen3d)
    setXMLBool(xml, "terminal.settings#rearCam", s.rearCam ~= false)
    setXMLInt(xml, "terminal.settings#tabPreset2", s.tabPreset or 1)
    setXMLInt(xml, "terminal.settings#theme", s.theme or 3)
    setXMLInt(xml, "terminal.settings#themeV", 2)
    setXMLInt(xml, "terminal.settings#display", s.display or 1)
    setXMLInt(xml, "terminal.settings#fuelReserve", s.fuelReserve)
    setXMLInt(xml, "terminal.settings#dfTheme", s.dfTheme or 1)
    setXMLInt(xml, "terminal.settings#dfHome", s.dfHome or 1)
    if s.caseCol ~= nil then setXMLString(xml, "terminal.settings#caseCol", s.caseCol) end
    if s.textGlow ~= nil then setXMLFloat(xml, "terminal.settings#textGlow", s.textGlow) end
    if s.textDark ~= nil then setXMLFloat(xml, "terminal.settings#textDark", s.textDark) end
    local keys = {}
    for k in pairs(self.positions) do keys[#keys + 1] = k end
    table.sort(keys)
    for i, k in ipairs(keys) do
        local p = self.positions[k]
        local key = string.format("terminal.positions.pos(%d)", i - 1)
        setXMLString(xml, key .. "#key", k)
        if p.name ~= nil then setXMLString(xml, key .. "#name", p.name) end
        setXMLFloat(xml, key .. "#x", p.x)
        setXMLFloat(xml, key .. "#y", p.y)
        if p.z ~= nil then setXMLFloat(xml, key .. "#z", p.z) end
        if p.s ~= nil then setXMLInt(xml, key .. "#s", p.s) end
        if p.rx ~= nil then setXMLInt(xml, key .. "#rx", p.rx) end
        if p.ry ~= nil then setXMLInt(xml, key .. "#ry", p.ry) end
        if p.scr ~= nil then setXMLInt(xml, key .. "#scr", p.scr) end
        if p.scr2 ~= nil then setXMLInt(xml, key .. "#scr2", p.scr2) end
        if p.scr3 ~= nil then setXMLInt(xml, key .. "#scr3", p.scr3) end
        if p.ori ~= nil then setXMLInt(xml, key .. "#ori", p.ori) end
        if p.sw ~= nil then setXMLInt(xml, key .. "#sw", p.sw) end
        if p.sh ~= nil then setXMLInt(xml, key .. "#sh", p.sh) end
        if p.rz ~= nil then setXMLInt(xml, key .. "#rz", p.rz) end
        if p.tiles ~= nil then setXMLString(xml, key .. "#tiles", p.tiles) end
        if p.lockF ~= nil then setXMLInt(xml, key .. "#lockF", p.lockF) end
        if p.lockR ~= nil then setXMLInt(xml, key .. "#lockR", p.lockR) end
        if p.rem ~= nil then setXMLString(xml, key .. "#rem", p.rem) end
        if p.hyd ~= nil then setXMLString(xml, key .. "#hyd", p.hyd) end
        if p.hset ~= nil then setXMLString(xml, key .. "#hset", p.hset) end
        if p.pto ~= nil then setXMLString(xml, key .. "#pto", p.pto) end
        if p.qa ~= nil then setXMLString(xml, key .. "#qa", p.qa) end
        if p.fk ~= nil then setXMLString(xml, key .. "#fk", p.fk) end
        if p.mfw ~= nil then setXMLString(xml, key .. "#mfw", p.mfw) end   -- (04/11) widgets du Datatronic 5 (Massey)
        if p.sc ~= nil then setXMLString(xml, key .. "#sc", p.sc) end     -- (04/11) Section Control du Datatronic 5 (SectionControl.lua)
    end
    saveXMLFile(xml)
    delete(xml)
end

-------------------------------------------------------------------------------
-- Compteurs gardés avec la partie (savegameX/autoSwitchTerminal.xml)
-------------------------------------------------------------------------------
local function savegamePath()
    local mi = g_currentMission ~= nil and g_currentMission.missionInfo or nil
    local dir = mi ~= nil and mi.savegameDirectory or nil
    if dir == nil or dir == "" then return nil end
    return dir .. "/" .. AS_Terminal.SAVE_NAME
end

local function writeCounter(xml, key, c)
    setXMLFloat(xml, key .. "#ha", c.ha)
    setXMLFloat(xml, key .. "#hours", c.ms / 3600000)
    setXMLFloat(xml, key .. "#fuel", c.fuel)
    setXMLFloat(xml, key .. "#km", c.dist / 1000)
    setXMLFloat(xml, key .. "#kmW", (c.distW or 0) / 1000)
    setXMLFloat(xml, key .. "#hoursW", (c.msW or 0) / 3600000)
    setXMLFloat(xml, key .. "#fuelW", c.fuelW or 0)
    if c.field ~= nil then setXMLInt(xml, key .. "#field", c.field) end
    if c.flt then setXMLBool(xml, key .. "#filter", true) end
end

local function readCounter(xml, key)
    local c = newCounter()
    c.ha = getXMLFloat(xml, key .. "#ha") or 0
    c.ms = (getXMLFloat(xml, key .. "#hours") or 0) * 3600000
    c.fuel = getXMLFloat(xml, key .. "#fuel") or 0
    c.dist = (getXMLFloat(xml, key .. "#km") or 0) * 1000
    c.distW = (getXMLFloat(xml, key .. "#kmW") or 0) * 1000
    c.msW = (getXMLFloat(xml, key .. "#hoursW") or 0) * 3600000
    c.fuelW = getXMLFloat(xml, key .. "#fuelW") or 0
    c.field = getXMLInt(xml, key .. "#field")
    c.flt = getXMLBool(xml, key .. "#filter") == true
    return c
end

function AS_Terminal:saveCounters()
    local path = savegamePath()
    if path == nil then return end
    local xml = createXMLFile("asTerminalCnt", path, "terminal")
    if xml == nil or xml == 0 then return end
    local i = 0
    for key, c in pairs(self.counters) do
        if type(key) == "string" then
            local k = string.format("terminal.vehicle(%d)", i)
            setXMLString(xml, k .. "#id", key)
            setXMLInt(xml, k .. "#active", c.active)
            if c.tc == false then setXMLBool(xml, k .. "#tc", false) end
            if c.pause then setXMLBool(xml, k .. "#pause", true) end
            writeCounter(xml, k .. ".job1", c.jobs[1])
            writeCounter(xml, k .. ".job2", c.jobs[2])
            writeCounter(xml, k .. ".total", c.total)
            i = i + 1
        end
    end
    if AS_TerminalTools ~= nil then
        local okT, errT = pcall(AS_TerminalTools.saveCounters, AS_TerminalTools, xml)
        if not okT then log("ERREUR sauvegarde compteurs outils : %s", tostring(errT)) end
    end
    saveXMLFile(xml)
    delete(xml)
end

function AS_Terminal:loadCounters()
    self.counters = {}
    local path = savegamePath()
    if path == nil or not fileExists(path) then return end
    local xml = loadXMLFile("asTerminalCnt", path)
    if xml == nil or xml == 0 then return end
    local i = 0
    while true do
        local k = string.format("terminal.vehicle(%d)", i)
        if not hasXMLProperty(xml, k) then break end
        local id = getXMLString(xml, k .. "#id")
        if id ~= nil then
            self.counters[id] = { active = clamp(getXMLInt(xml, k .. "#active") or 1, 1, 2),
                jobs = { readCounter(xml, k .. ".job1"), readCounter(xml, k .. ".job2") },
                total = readCounter(xml, k .. ".total"),
                tc = getXMLBool(xml, k .. "#tc") ~= false, pause = getXMLBool(xml, k .. "#pause") == true }
        end
        i = i + 1
    end
    local nT = 0
    if AS_TerminalTools ~= nil then
        local okT, r = pcall(AS_TerminalTools.loadCounters, AS_TerminalTools, xml)
        if okT then nT = r or 0 else log("ERREUR compteurs outils : %s", tostring(r)) end
    end
    delete(xml)
    log("compteurs chargés pour %d véhicule(s), %d outil(s)", i, nT)
end

if FSCareerMissionInfo ~= nil and FSCareerMissionInfo.saveToXMLFile ~= nil then
    FSCareerMissionInfo.saveToXMLFile = Utils.appendedFunction(FSCareerMissionInfo.saveToXMLFile, function()
        local ok, err = pcall(AS_Terminal.saveCounters, AS_Terminal)
        if not ok then log("ERREUR sauvegarde : %s", tostring(err)) end
    end)
end

-------------------------------------------------------------------------------
-- Vue (cabine / dehors) et position du panneau
-------------------------------------------------------------------------------
local function isInsideView(v)
    local cam = call(v, "getActiveCamera")
    return cam ~= nil and cam.isInside == true
end

local function posKey(v, inside)
    local file = tostring(v.configFileName or vehicleName(v))
    file = file:match("([^/\\]+/[^/\\]+)$") or file
    return file .. (inside and "|cab" or "|out")
end

function AS_Terminal:defaultPos(inside, w, h)
    if inside then return 0.03, 0.36 end
    return 0.01, 0.97 - h - 0.06
end

function AS_Terminal:getPos(v, inside, w, h)
    local p = self.positions[posKey(v, inside)]
    local x, y
    if p ~= nil then x, y = p.x, p.y else x, y = self:defaultPos(inside, w, h) end
    return clamp(x, 0, math.max(0, 1 - w)), clamp(y, 0, math.max(0, 1 - h))
end

-------------------------------------------------------------------------------
-- Dessin
-------------------------------------------------------------------------------
local C = {
    bezel   = { 0.09, 0.10, 0.11, 0.97 },
    screen  = { 0.04, 0.05, 0.06, 0.96 },
    box     = { 0.11, 0.13, 0.15, 1 },
    boxHi   = { 0.16, 0.19, 0.22, 1 },
    green   = { 0.20, 0.56, 0.84, 1 },     -- bleu ciel (bandeaux, onglet actif)
    greenHi = { 0.36, 0.70, 0.95, 1 },
    white   = { 1, 1, 1, 1 },
    gray    = { 0.62, 0.66, 0.70, 1 },
    dim     = { 0.40, 0.43, 0.46, 1 },
    lamp    = { 0.30, 0.90, 0.40, 1 },
    amber   = { 1.00, 0.70, 0.20, 1 },
    red     = { 1.00, 0.28, 0.22, 1 },
    blue    = { 0.35, 0.60, 1.00, 1 },
}
-- (31/10 soir) thèmes : seuls les fonds et l'écriture changent
local THEMES = {
    { bezel = { 0.09, 0.10, 0.11, 0.97 }, screen = { 0.04, 0.05, 0.06, 0.96 }, box = { 0.11, 0.13, 0.15, 1 },
      boxHi = { 0.16, 0.19, 0.22, 1 }, white = { 1, 1, 1, 1 }, gray = { 0.62, 0.66, 0.70, 1 }, dim = { 0.40, 0.43, 0.46, 1 },
      lamp = { 0.30, 0.90, 0.40, 1 }, amber = { 1.00, 0.70, 0.20, 1 } },
    { bezel = { 0.80, 0.82, 0.85, 0.97 }, screen = { 0.93, 0.94, 0.95, 0.96 }, box = { 0.85, 0.87, 0.90, 1 },
      boxHi = { 0.78, 0.81, 0.85, 1 }, white = { 0.0, 0.0, 0.0, 1 }, gray = { 0.16, 0.18, 0.20, 1 }, dim = { 0.34, 0.37, 0.40, 1 },
      lamp = { 0.10, 0.60, 0.20, 1 }, amber = { 0.85, 0.50, 0.0, 1 } },
}
-- (01/11) Case IH : bleu du vrai terminal ; (02/11) habillage AFS Pro 1200 (fond gris, barres gris foncé)
local BLUE_CASE = { 0.04, 0.30, 0.58, 1 }
local CASE_BG = { 0.44, 0.45, 0.47, 1 }
local CASE_BAR = { 0.15, 0.16, 0.18, 1 }
local CASE_SEP = { 0.36, 0.37, 0.40, 1 }
local CASE_CLOCK = { 0.06, 0.06, 0.07, 1 }
local CASE_TAB = { 0.22, 0.23, 0.26, 1 }
local CASE_TAB_ON = { 0.30, 0.32, 0.36, 1 }
local CASE_TAB_LINE = { 0.12, 0.55, 0.95, 1 }
local CASE_TAB_IMG_LINE = { 0.0, 0.53, 0.99, 1 }   -- trait bleu des onglets des images
local CASE_CARD = { 0.97, 0.97, 0.97, 1 }
local CASE_BAND = { 0.80, 0.81, 0.83, 1 }
-- (03/11) New Holland = le terminal Case, avec le tracteur des images en bleu NH (as_nh_*)
-- (03/11, méthode 4 blocs) le tracteur rouge est dans les blocs 2 (patinage) et dans les blocs 4 PERF2 (caméra) ;
-- une copie bleue as_nh_<nom> absente = image Case gardée
AS_Terminal.NH_SWAP = { as_case_b4_home = "as_nh_b4_home", as_case_trblank = "as_nh_trblank", as_case_b2a = "as_nh_b2a", as_case_b2b = "as_nh_b2b", as_case_b4_p2 = "as_nh_b4_p2", as_case_b4_map = "as_nh_b4_map", as_case_c_slip = "as_nh_c_slip" }
local nhFileOk = {}
local function caseImg(name)
    if AS_Terminal.nhSkin and AS_Terminal.NH_SWAP[name] ~= nil then
        local alt = AS_Terminal.NH_SWAP[name]
        if nhFileOk[alt] == nil then   -- copie bleue absente : on garde l'image Case
            local pth = AS_MOD_DIR ~= nil and Utils.getFilename("objects/terminal/" .. alt .. ".dds", AS_MOD_DIR) or nil
            nhFileOk[alt] = pth ~= nil and fileExists ~= nil and fileExists(pth) == true
        end
        if nhFileOk[alt] then name = alt end
    end
    local f = "objects/terminal/" .. name .. ".dds"
    return AS_MOD_DIR ~= nil and Utils.getFilename(f, AS_MOD_DIR) or f
end
local function applyTheme(i)
    AS_Terminal.curTheme = THEMES[i] ~= nil and i or 1
    local th = THEMES[i] or THEMES[1]
    for k, c in pairs(th) do
        local dst = C[k]
        for j = 1, 4 do dst[j] = c[j] end
    end
end
AS_Terminal.applyTheme = function(_, i) applyTheme(i) end

local function fmt1(v) return v ~= nil and string.format("%.1f", v) or "-" end
local function fmtPct(v) return v ~= nil and string.format("%d %%", math.floor(v * 100 + 0.5)) or "-" end
local function fmtHM(ms)
    local m = math.floor((ms or 0) / 60000)
    return string.format("%d:%02d", math.floor(m / 60), m % 60)
end
local function fmtClock()
    local env = g_currentMission ~= nil and g_currentMission.environment or nil
    local t = env ~= nil and env.dayTime or 0
    local m = math.floor(t / 60000)
    return string.format("%02d:%02d", math.floor(m / 60) % 24, m % 60)
end

-- (01/11, étape 37) chaque écran a sa page : la grande fenêtre garde self.page, chaque écran 3D
-- (tablette, écrans du véhicule) la sienne (tab.page) ; on prend la page de l'écran le temps de le dessiner
-- ou d'exécuter un clic, puis la page de la grande fenêtre revient
local unpackF = unpack or table.unpack
function AS_Terminal:withTab(tab, fn, ...)
    if tab == nil then return pcall(fn, ...) end
    -- banc d'essai : SHARED_PAGE = une seule page pour tous les écrans (anciens essais)
    -- (37c) tablette en plus du mode « Les 2 » : ses réglages sont ceux de la tablette
    local TT = AS_TerminalTablet
    local keepF = TT ~= nil and TT.forceTablet or nil
    if self.SHARED_PAGE then
        local ss = self.curSlot
        self.curSlot = tab.slot
        if TT ~= nil and tab.asTablet then TT.forceTablet = true end
        local r = { pcall(fn, ...) }
        if TT ~= nil then TT.forceTablet = keepF end
        self.curSlot = ss
        return unpackF(r, 1, table.maxn(r))
    end
    local sp, sm, ss = self.page, self.moreOpen, self.curSlot
    self.page, self.moreOpen, self.curSlot = tab.page or "home", tab.moreOpen, tab.slot
    if TT ~= nil and tab.asTablet then TT.forceTablet = true end
    local r = { pcall(fn, ...) }
    if TT ~= nil then TT.forceTablet = keepF end
    tab.page, tab.moreOpen = self.page, self.moreOpen
    self.page, self.moreOpen, self.curSlot = sp, sm, ss
    return unpackF(r, 1, table.maxn(r))
end

-- (70b, 06/11) Échap / menu du jeu : la grande fenêtre ouverte doit le rester au retour ; état de la grande fenêtre retenu quand un menu du jeu s'ouvre, remis au retour
function AS_Terminal:keepOpenThroughGui(guiOn)
    if guiOn then
        if self.guiKeepOpen == nil then self.guiKeepOpen = self.isOpen or self.openNoGui == true end
        return
    end
    if self.guiKeepOpen ~= nil then
        if self.guiKeepOpen and not self.isOpen then
            self.isOpen = true
            log("grande fenêtre rouverte au retour du menu du jeu")
        end
        self.guiKeepOpen = nil
    end
    self.openNoGui = self.isOpen
end
if Gui ~= nil and type(Gui.showGui) == "function" and Utils ~= nil and Utils.prependedFunction ~= nil then
    Gui.showGui = Utils.prependedFunction(Gui.showGui, function(gui, name)
        if name ~= nil and name ~= "" then pcall(AS_Terminal.keepOpenThroughGui, AS_Terminal, true) end
    end)
end

function AS_Terminal:draw()
    self.boxes = {}
    self.panel = nil
    self.panel3d = nil
    if not self.ENABLED or g_currentMission == nil then return end
    local guiOn = g_gui ~= nil and g_gui.getIsGuiVisible ~= nil and g_gui:getIsGuiVisible() == true
    self:keepOpenThroughGui(guiOn)
    if guiOn then return end
    local v = AS.shGetControlledVehicle ~= nil and AS.shGetControlledVehicle() or nil
    if v == nil or v.rootNode == nil then return end
    local inside = isInsideView(v)
    -- (étape 3) vue cabine, grand terminal fermé : le terminal est dessiné sur la tablette
    local screen = nil
    if not self.isOpen then
        if not inside or AS_TerminalTablet == nil then return end
        -- (31/10) écran 3D : le terminal est construit dans la tablette (TerminalTablet), rien à dessiner ici
        if AS_TerminalTablet:screen3dOn() then
            self.panel3d = v
            return
        end
        local okT, r = pcall(AS_TerminalTablet.getScreenRect, AS_TerminalTablet, v)
        if not okT or r == nil then return end
        screen = r
    else
        -- (37c) grande fenêtre ouverte : les écrans 3D restent cliquables en dehors d'elle
        if inside and AS_TerminalTablet ~= nil and AS_TerminalTablet:screen3dOn() then self.panel3d = v end
        local show = self.settings.show
        if (show == 2 and not inside) or (show == 3 and inside) then return end
    end
    if g_time - self.lastRead >= self.REFRESH_MS or self.data == nil or self.data.vehicle ~= v then
        self.lastRead = g_time
        local ok, d = pcall(self.read, self, v)
        if ok then
            self.data = d
        elseif not self.loggedError then
            self.loggedError = true
            log("erreur de lecture : %s", tostring(d))
        end
    end
    if self.data == nil then return end
    local tabObj = (screen ~= nil and AS_TerminalTablet ~= nil) and AS_TerminalTablet.tablets[v] or nil
    if tabObj ~= nil and tabObj.failed ~= nil then tabObj = nil end
    local ok, err = self:withTab(tabObj, self.drawPanel, self, self.data, v, inside, screen)
    if not ok and not self.loggedDrawError then
        self.loggedDrawError = true
        log("erreur d'affichage : %s", tostring(err))
    end
    setTextAlignment(RenderText.ALIGN_LEFT)
    setTextBold(false)
    setTextColor(1, 1, 1, 1)
end

-- rec ~= nil (écran 3D de la tablette) : rien n'est dessiné à l'écran, les rectangles, textes
-- et boutons sont notés dans rec en unités du panneau (900 x 500), pour être construits en 3D
-- cadre de la grande fenêtre : image 1774 x 1067, trou de 1506 x 853 au centre
AS_Terminal.FRAME_W, AS_Terminal.FRAME_H = 1774 / 1506, 1067 / 853
-- (01/11, étape 37) cadre plus fin : l'image est découpée en tranches (fractions de l'image, depuis
-- le haut-gauche) ; les tranches « true » gardent leurs proportions à f (coins, logo, plaque, grilles),
-- les autres (barres bleues) s'étirent pour faire le tour. Même découpe que le maillage du i3d.
AS_Terminal.FRAME_SLICES = { f = 0.55,
    u = { { 0.0000, 0.0755, true }, { 0.0755, 0.1400, true }, { 0.1400, 0.2250, false }, { 0.2250, 0.3400, true }, { 0.3400, 0.6600, true }, { 0.6600, 0.7750, true }, { 0.7750, 0.8600, false }, { 0.8600, 0.9245, true }, { 0.9245, 1.0000, true } },
    v = { { 0.0000, 0.1003, true }, { 0.1003, 0.1800, true }, { 0.1800, 0.8200, false }, { 0.8200, 0.8997, true }, { 0.8997, 1.0000, true } },
    hu = { 0.0755, 0.9245 }, hv = { 0.1003, 0.8997 } }
-- positions des bords des tranches sur un axe : trou du cadre = hole (unités quelconques)
local function frameAxis(segs, h0, h1, hole, f)
    local uni, st = 0, 0
    for _, s in ipairs(segs) do if s[3] then uni = uni + s[2] - s[1] else st = st + s[2] - s[1] end end
    local L0 = hole / (h1 - h0)                       -- longueur du cadre d'origine pour ce trou
    local bord = 0
    for _, s in ipairs(segs) do if s[2] <= h0 or s[1] >= h1 then bord = bord + s[2] - s[1] end end
    local L = hole + f * bord * L0                    -- nouveau cadre : bords uniformes réduits à f
    local k = (L - f * uni * L0) / (st * L0)
    local pos = { 0 }
    for i, s in ipairs(segs) do pos[i + 1] = pos[i] + (s[2] - s[1]) * L0 * (s[3] and f or k) end
    return pos, L
end
AS_Terminal.frameAxis = frameAxis
-- tranches de la grande fenêtre autour d'un panneau de W x H (écran) : { x, y, w, h, u0, v0, u1, v1 } depuis le haut-gauche du cadre
function AS_Terminal:frameCells(W, H)
    local S = self.FRAME_SLICES
    local px, LW = frameAxis(S.u, S.hu[1], S.hu[2], W, S.f)
    local py, LH = frameAxis(S.v, S.hv[1], S.hv[2], H, S.f)
    local cells = {}
    for i, cu in ipairs(S.u) do
        for j, cv in ipairs(S.v) do
            local inHole = cu[1] >= S.hu[1] and cu[2] <= S.hu[2] and cv[1] >= S.hv[1] and cv[2] <= S.hv[2]
            if not inHole then
                cells[#cells + 1] = { px[i], py[j], px[i + 1] - px[i], py[j + 1] - py[j], cu[1], cv[1], cu[2], cv[2], key = i .. "_" .. j }
            end
        end
    end
    return cells, LW, LH, px, py
end
function AS_Terminal:frameOverlay()
    if self.frameOv == nil then
        self.frameOv = false
        if createImageOverlay ~= nil and AS_MOD_DIR ~= nil then
            local ok, ov = pcall(createImageOverlay, Utils.getFilename("objects/terminal/as_cadre_diffuse.dds", AS_MOD_DIR))
            if ok and ov ~= nil and ov ~= 0 then
                self.frameOv = ov
                pcall(setOverlayColor, ov, 1, 1, 1, 1)
            else
                log("cadre de la grande fenêtre introuvable")
            end
        end
    end
    return self.frameOv or nil
end

-- (04/11) logo AutoSwitch de l'écran de démarrage, en image 2D (grande fenêtre)
function AS_Terminal:logoOverlay()
    if self.logoOv == nil then
        self.logoOv = false
        if createImageOverlay ~= nil and AS_MOD_DIR ~= nil then
            local ok, ov = pcall(createImageOverlay, Utils.getFilename("objects/terminal/as_logo_as.dds", AS_MOD_DIR))
            if ok and ov ~= nil and ov ~= 0 then
                self.logoOv = ov
                pcall(setOverlayColor, ov, 1, 1, 1, 1)
            end
        end
    end
    return self.logoOv or nil
end

-- (31/10 soir) logo de la marque (celui du magasin) en image 2D, un par fichier
function AS_Terminal:brandOverlay(v)
    if v == nil or AS_TerminalTablet == nil or AS_TerminalTablet.brandImage == nil or createImageOverlay == nil then return nil end
    local file = AS_TerminalTablet:brandImage(v)
    if file == nil then return nil end
    self.brandOvs = self.brandOvs or {}
    local ov = self.brandOvs[file]
    if ov == nil then
        ov = false
        local ok, o = pcall(createImageOverlay, file)
        if ok and o ~= nil and o ~= 0 then
            ov = o
            pcall(setOverlayColor, o, 1, 1, 1, 1)
        else
            log("logo de la marque introuvable : %s", tostring(file))
        end
        self.brandOvs[file] = ov
    end
    return ov or nil
end

-- (07/11, étape 70h) clic refusé en roulant (réglage « Tactile seulement
-- à l'arrêt ») : message au milieu de l'écran pendant 2,5 s, sur toutes les marques (grande fenêtre, tablette,
-- écrans 3D) ; avant, rien ne disait pourquoi la tablette ne répondait plus
AS_Terminal.NOTICE_MS = 2500
function AS_Terminal:touchNotice()
    self.touchNoticeUntil = (g_time or 0) + self.NOTICE_MS
    if AS_TerminalTablet ~= nil then AS_TerminalTablet.textTimer = AS_TerminalTablet.SCREEN_MS end   -- écran 3D tout de suite
end
-- bandeau du message (unités du panneau) : x, y, largeur, hauteur
function AS_Terminal:noticeGeom(W, H)
    local bw, bh = math.min(640, W - 60), 124
    return (W - bw) * 0.5, (H - bh) * 0.5, bw, bh
end
function AS_Terminal:drawTouchNotice(f)
    local W, H = f.W, f.H
    local x, y, bw, bh = self:noticeGeom(W, H)
    local YEL, DARK = { 1, 214 / 255, 0, 1 }, { 18 / 255, 18 / 255, 18 / 255, 1 }
    if f.rec ~= nil then
        -- écran 3D : pièces de couleur éclairées comme l'écran (pas de carré lumineux fluo)
        f.image(x - 5, y - 5, bw + 10, bh + 10, nil, "img_as_jd_c_ffd600", caseImg("as_jd_c_ffd600"))
        f.image(x, y, bw, bh, nil, "img_as_jd_c_121212", caseImg("as_jd_c_121212"))
    else
        f.rect(x - 5, y - 5, bw + 10, bh + 10, YEL)
        f.rect(x, y, bw, bh, DARK)
    end
    local n0 = f.rec ~= nil and #f.rec.texts or 0
    self.noticeDrawing = true
    f.text(W * 0.5, y + 54, 24, T("touchLocked"), { 1, 1, 1, 1 }, RenderText.ALIGN_CENTER, true, bw - 30)
    f.text(W * 0.5, y + 96, 16, T("touchLockedHow"), YEL, RenderText.ALIGN_CENTER, true, bw - 30)
    self.noticeDrawing = nil
    if f.rec ~= nil then
        for i = n0 + 1, #f.rec.texts do
            local t = f.rec.texts[i]
            t.em, t.noRoom = 1, true     -- lettres lumineuses sur le bandeau foncé, largeur donnée ici
        end
    end
end
-- dessin de l'écran (toutes les marques), puis le message par-dessus
function AS_Terminal:drawPanel(d, v, inside, screen, rec)
    self.noticeFns, self.noticeBox, self.noticeDrawing = nil, nil, nil
    local on = self.touchNoticeUntil ~= nil and (g_time or 0) < self.touchNoticeUntil
    if on then
        local x, y, bw, bh = self:noticeGeom(self.W, self.H)
        self.noticeBox = { x - 6, y - 6, x + bw + 6, y + bh + 6 }
    end
    local okB, errB = pcall(self.drawPanelBody, self, d, v, inside, screen, rec)
    self.noticeBox = nil
    if not okB then self.noticeFns = nil; error(errB, 0) end
    local f = self.noticeFns
    self.noticeFns = nil
    if f ~= nil and on then
        local okN, errN = pcall(self.drawTouchNotice, self, f)
        if not okN and not self.loggedNotice then self.loggedNotice = true; log("ERREUR message tactile : %s", tostring(errN)) end
    end
end

-- (07/11, étape 70k) la grande fenêtre est redessinée à chaque image : les
-- mesures de texte du jeu (getTextWidth) sont gardées en mémoire (même texte, même taille, même gras, même place :
-- même résultat) ; vidée au-delà de 3000 textes différents
AS_Terminal.fitCache, AS_Terminal.fitN = {}, 0
function AS_Terminal:fitMemo(key, val)
    if self.fitN >= 3000 then self.fitCache, self.fitN = {}, 0 end
    self.fitCache[key] = val
    self.fitN = self.fitN + 1
    return val
end

function AS_Terminal:drawPanelBody(d, v, inside, screen, rec)
    -- dessin précédent interrompu par une erreur : couleurs des boutons remises
    if self.greenBackup ~= nil then
        for j = 1, 4 do C.green[j], C.greenHi[j] = self.greenBackup[1][j], self.greenBackup[2][j] end
        self.greenBackup = nil
    end
    -- (31/10 soir) thème « Marque » : clair ou sombre comme le vrai terminal de la marque
    if (self.settings.theme or 3) == 3 then
        local th = self:brandStyle(v).theme or 1
        if self.curTheme ~= th then applyTheme(th) end
    end
    local k = self.settings.size / 100 * uiScale()
    local aspect = (g_screenWidth or 1920) / math.max(1, g_screenHeight or 1080)
    -- sur la tablette : le terminal remplit l'écran projeté (largeur), centré en hauteur
    if screen ~= nil then k = math.min(screen.w * aspect * 1080 / self.W, screen.h * 1080 / self.H) end
    local function sy(u) return u * k / 1080 end
    local function sx(u) return sy(u) / aspect end
    local W, H = sx(self.W), sy(self.H)
    local x0, y0
    if screen ~= nil then
        x0, y0 = screen.x + (screen.w - W) * 0.5, screen.y + (screen.h - H) * 0.5
    else
        x0, y0 = self:getPos(v, inside, W, H)
        if self.dragging and self.dragPos ~= nil then x0, y0 = self.dragPos.x, self.dragPos.y end
    end
    if rec == nil then
        self.panel = { x = x0, y = y0, w = W, h = H, inside = inside, vehicle = v, onTablet = screen ~= nil }
    end
    local top = y0 + H
    -- coordonnées du panneau en pixels depuis le coin haut-gauche
    local function X(u) return x0 + sx(u) end
    local function Y(u) return top - sy(u) end
    local boxes2d = {}
    -- (70k) mêmes cases rangées par carrés de 60 unités : la place d'un texte se cherche parmi ses voisins
    local grid2d = {}
    -- (70k) état du texte déjà envoyé au jeu pendant ce dessin (grande fenêtre) : gras connu dès le départ
    local tA, tB, tR, tG, tBl, tAl = nil, nil, nil, nil, nil, nil
    if rec == nil then setTextBold(false); tB = false end
    local function rect(u, vv, w, h, c, a)
        if rec ~= nil then
            rec.rects[#rec.rects + 1] = { u, vv, w, h, c[1], c[2], c[3], a or c[4] }
            return
        end
        drawFilledRect(X(u), Y(vv + h), sx(w), sy(h), lin(c[1]), lin(c[2]), lin(c[3]), a or c[4])
        if w >= 16 and h >= 6 then
            local r = { u, vv, w, h }
            boxes2d[#boxes2d + 1] = r
            for gx = math.floor((u - 0.5) / 60), math.floor((u + w + 0.5) / 60) do
                for gy = math.floor(vv / 60), math.floor((vv + h) / 60) do
                    local gk = gx * 4096 + gy
                    local gb = grid2d[gk]
                    if gb == nil then gb = {}; grid2d[gk] = gb end
                    gb[#gb + 1] = r
                end
            end
        end
    end
    -- (01/11, étape 37) grande fenêtre : place d'un texte dans la plus petite case qui le contient
    -- (même règle que l'écran 3D), pour que les textes agrandis ne débordent pas
    local function room2d(u, vv, size, align)
        local py = vv - size * 0.45
        local best, bestA = nil, math.huge
        local cell = grid2d[math.floor(u / 60) * 4096 + math.floor(py / 60)]
        if cell == nil then return nil end
        for i = 1, #cell do
            local r = cell[i]
            if r[4] >= size * 0.7 and r[2] <= py and py <= r[2] + r[4] and r[1] - 0.5 <= u and u <= r[1] + r[3] + 0.5 then
                local a = r[3] * r[4]
                if a < bestA then best, bestA = r, a end
            end
        end
        if best == nil then return nil end
        local x1, x2 = best[1], best[1] + best[3]
        local avail
        if align == RenderText.ALIGN_RIGHT then avail = u - x1 - 3
        elseif align == RenderText.ALIGN_CENTER then avail = 2 * math.min(u - x1, x2 - u) - 6
        else avail = x2 - u - 3 end
        return math.max(avail, 6)
    end
    -- (01/11, étape 37) lisibilité : textes agrandis (petits textes x1,3, titres x1,1) ;
    -- un texte trop large pour sa case est ensuite réduit (62 % au plus) comme avant
    local function TS(size)
        if not AS_Terminal.BIG_TEXT then return size end
        if size <= 13 then return size * 1.3 elseif size <= 16 then return size * 1.2 end
        return size * 1.1
    end
    self.TS = TS
    -- (01/11) largeur d'un texte en unités du panneau (police 3D sur l'écran du véhicule, sinon celle du HUD)
    local function measure(size, s)
        size = TS(size)
        s = tostring(s or "")
        if rec ~= nil then
            local TT = AS_TerminalTablet
            if TT ~= nil and TT.textWidth ~= nil and TT.font ~= nil then
                local okW, w = pcall(TT.textWidth, TT, TT:font(), TT.plain(s))
                if okW and w ~= nil then return w * size * 0.95 end
            end
            return #s * size * 0.62
        end
        if getTextWidth ~= nil then
            -- (70k) mesure gardée en mémoire
            local ts = sy(size)
            local key = (tB and "B" or "N") .. ts .. "|" .. s
            local w = self.fitCache[key]
            if w == nil then w = self:fitMemo(key, getTextWidth(ts, s)) end
            return w / math.max(1e-9, sx(1))
        end
        return #s * size * 0.5
    end
    -- (01/11) maxW : largeur maxi (unités du panneau) ; le texte est réduit (62 % au plus) puis coupé
    local function text(u, vv, size, s, c, align, bold, maxW)
        -- (70h) message « tactile bloqué » affiché : textes de la page sous le bandeau effacés (les lettres
        -- passent au-dessus des fonds, en 2D comme en 3D) ; texte vide plutôt que rien (les pages retouchent le dernier)
        local nb = self.noticeBox
        if nb ~= nil and not self.noticeDrawing and s ~= nil and s ~= "" then
            local tw, ts = measure(size, s), TS(size)
            if maxW ~= nil and tw > maxW then tw = maxW end
            local x1 = u
            if align == RenderText.ALIGN_RIGHT then x1 = u - tw elseif align == RenderText.ALIGN_CENTER then x1 = u - tw * 0.5 end
            if x1 < nb[3] and x1 + tw > nb[1] and vv - ts * 0.85 < nb[4] and vv + ts * 0.25 > nb[2] then s = "" end
        end
        size = TS(size)
        if rec ~= nil then
            c = c or C.white
            rec.texts[#rec.texts + 1] = { u, vv, size, tostring(s), c[1], c[2], c[3], align or RenderText.ALIGN_LEFT, maxW }
            return
        end
        -- (70k) alignement, gras et couleur envoyés au jeu seulement s'ils changent (tous les textes passent ici)
        local a0 = align or RenderText.ALIGN_LEFT
        if a0 ~= tA then setTextAlignment(a0); tA = a0 end
        c = c or C.white
        -- (étape 37) thème clair dans la grande fenêtre : textes délavés en jeu (gris presque invisibles) ;
        -- couleurs passées en linéaire (plus foncées) et petits textes en gras pour le contraste
        local bb, cr, cg, cb2, ca
        if self.curTheme == 2 then
            bb, cr, cg, cb2, ca = bold == true or size < 16, lin(c[1]), lin(c[2]), lin(c[3]), c[4]
        else
            bb, cr, cg, cb2, ca = bold == true, c[1], c[2], c[3], c[4]
        end
        if bb ~= tB then setTextBold(bb); tB = bb end
        if cr ~= tR or cg ~= tG or cb2 ~= tBl or ca ~= tAl then setTextColor(cr, cg, cb2, ca); tR, tG, tBl, tAl = cr, cg, cb2, ca end
        s = tostring(s)
        local ts = sy(size)
        local room = room2d(u, vv, size, align)
        if room ~= nil then maxW = maxW ~= nil and math.min(maxW, room) or room end
        if maxW ~= nil and getTextWidth ~= nil then
            local wMax = sx(maxW)
            -- (70k) texte ajusté à sa place gardé en mémoire (même texte, taille, gras et place : même résultat)
            local key = (bb and "b" or "n") .. ts .. "|" .. wMax .. "|" .. s
            local fit = self.fitCache[key]
            if fit == nil then
                local w = getTextWidth(ts, s)
                if w > wMax and w > 0 then
                    ts = ts * math.max(0.62, wMax / w)
                    while #s > 1 and getTextWidth(ts, s) > wMax do
                        local n0 = #s
                        s = s:gsub("[%z\1-\127\194-\244][\128-\191]*$", "")
                        if #s >= n0 then s = s:sub(1, n0 - 1) end
                    end
                end
                fit = self:fitMemo(key, { ts, s })
            end
            ts, s = fit[1], fit[2]
        end
        renderText(X(u), Y(vv), ts, s)
    end
    local function button(u, vv, w, h, action, hot)
        local b = { x = X(u), y = Y(vv + h), w = sx(w), h = sy(h), action = action }
        if rec ~= nil then
            b = { u = u, v = vv, w = w, h = h, action = action }
            rec.boxes[#rec.boxes + 1] = b
        else
            self.boxes[#self.boxes + 1] = b
        end
        local hover = self.hover == action
        rect(u, vv, w, h, hot and (hover and C.greenHi or C.green) or (hover and C.boxHi or C.box))
        return b
    end
    -- (31/10 soir) zone cliquable sans dessin (voyants de l'image du véhicule)
    local function hotspot(u, vv, w, h, action)
        if rec ~= nil then
            rec.boxes[#rec.boxes + 1] = { u = u, v = vv, w = w, h = h, action = action }
        else
            self.boxes[#self.boxes + 1] = { x = X(u), y = Y(vv + h), w = sx(w), h = sy(h), action = action }
        end
    end
    -- (31/10 soir) image : en 2D un calque, en 3D une pièce texturée de la tablette (nom), posée
    -- à son rang parmi les carrés (ceux dessinés avant sont dessous, ceux d'après dessus)
    -- (01/11) file : image d'un fichier (magasin), en 3D sur une copie de la pièce du logo
    local function image(u, vv, w, h, ov, name, file)
        if rec ~= nil then
            -- (02/11) écran 3D : une pièce par image ; la même icône dessinée
            -- plusieurs fois (boutons des feux, cases) prenait la même pièce et n'apparaissait qu'une fois
            if file ~= nil and name ~= nil then
                rec.imgCount = rec.imgCount or {}
                local n = (rec.imgCount[name] or 0) + 1
                rec.imgCount[name] = n
                if n > 1 then name = name .. "#" .. n end
            end
            rec.rects[#rec.rects + 1] = { u, vv, w, h, 0, 0, 0, 1, img = name, file = file }
            return
        end
        if ov ~= nil then renderOverlay(ov, X(u), Y(vv + h), sx(w), sy(h)) end
    end

    -- cadre et écran
    local Wp, Hp = self.W, self.H
    if rec == nil then
        -- (31/10) grande fenêtre : cadre AutoSwitch autour (le trou du cadre = le panneau)
        local fr = screen == nil and self:frameOverlay() or nil
        if fr ~= nil then
            if not AS_Terminal.THIN_FRAME then
                -- cadre d'avant l'étape 37
                local fw, fh = W * self.FRAME_W, H * self.FRAME_H
                renderOverlay(fr, x0 - (fw - W) * 0.5, y0 - (fh - H) * 0.5, fw, fh)
                local lo = self:brandOverlay(v)
                if lo ~= nil then
                    local lh = fh * 0.064
                    local lw = 2 * lh / aspect
                    local cy = y0 - (fh - H) * 0.5 + fh * (1 - 0.9375)
                    renderOverlay(lo, x0 + W * 0.5 - lw * 0.5, cy - lh * 0.5, lw, lh)
                end
            else
            -- (étape 37) cadre plus fin, dessiné en tranches (unités : pixels écran en hauteur)
            local cells, LW, LH, px, py = self:frameCells(W * aspect, H)
            local fx0, ftop = x0 - (LW / aspect - W) * 0.5, y0 + H + (LH - H) * 0.5
            self.frameCellOvs = self.frameCellOvs or {}
            for _, c in ipairs(cells) do
                local ov = self.frameCellOvs[c.key]
                if ov == nil then
                    ov = false
                    local okO, o = pcall(createImageOverlay, Utils.getFilename("objects/terminal/as_cadre_diffuse.dds", AS_MOD_DIR))
                    if okO and o ~= nil and o ~= 0 then
                        ov = o
                        pcall(setOverlayColor, o, 1, 1, 1, 1)
                        -- coins : bas-gauche, haut-gauche, bas-droite, haut-droite (v de l'image : 0 en haut)
                        pcall(setOverlayUVs, o, c[5], 1 - c[8], c[5], 1 - c[6], c[7], 1 - c[8], c[7], 1 - c[6])
                    end
                    self.frameCellOvs[c.key] = ov
                end
                if ov then renderOverlay(ov, fx0 + c[1] / aspect, ftop - c[2] - c[4], c[3] / aspect, c[4]) end
            end
            -- (31/10 soir) logo de la marque du véhicule dans la plaque du bas du cadre
            -- (plaque au centre, à 93,75 % de la hauteur de l'image depuis le haut ; logos du jeu en 2:1)
            local lo = self:brandOverlay(v)
            if lo ~= nil then
                local S = self.FRAME_SLICES
                local j = #S.v
                local cv = S.v[j]
                local cy = ftop - (py[j] + (0.9375 - cv[1]) / (cv[2] - cv[1]) * (py[j + 1] - py[j]))
                local lh = (py[j + 1] - py[j]) / (cv[2] - cv[1]) * 0.064
                local lw = 2 * lh / aspect
                renderOverlay(lo, x0 + W * 0.5 - lw * 0.5, cy - lh * 0.5, lw, lh)
            end
            end
            drawFilledRect(x0, y0, W, H, lin(C.bezel[1]), lin(C.bezel[2]), lin(C.bezel[3]), 1)
        else
            AS_drawPanelBg(x0, y0, W, H, sy(1), sy, sx, C.bezel[4])
        end
    end
    -- (04/11) grande fenêtre (Ctrl droit + T) : comme l'écran de la machine, éteinte moteur coupé et
    -- écran de démarrage de 5 s (logo AutoSwitch, logo de la marque, barre) quand le moteur démarre
    if rec == nil and screen == nil and AS_TerminalTablet ~= nil and AS_TerminalTablet.powerState ~= nil then
        self.bigPower = self.bigPower or setmetatable({}, { __mode = "k" })
        local st = self.bigPower[v]
        if st == nil then st = {}; self.bigPower[v] = st end
        local okP, ps = pcall(AS_TerminalTablet.powerState, AS_TerminalTablet, v, st)
        -- (04/11) la grande fenêtre suit le démarrage de l'écran de la
        -- machine / tablette quand il y en a un : ouverte après le démarrage du moteur, elle sautait le chargement
        local tb = AS_TerminalTablet.tablets ~= nil and AS_TerminalTablet.tablets[v] or nil
        if okP and ps ~= "off" and type(tb) == "table" and tb.power == true and tb.bootUntil ~= nil and (g_time or 0) < tb.bootUntil then
            ps = "boot"
            st.bootStart = tb.bootStart
            st.bootUntil = tb.bootUntil
        end
        if okP and ps ~= "on" then
            rect(10, 10, Wp - 20, Hp - 20, { 0, 0, 0, 1 })
            if ps == "boot" then
                local frac = math.max(0, math.min(1, ((g_time or 0) - (st.bootStart or 0)) / (AS_TerminalTablet.BOOT_MS or 5000)))
                local lo = self:logoOverlay()
                if lo ~= nil then renderOverlay(lo, X(450 - 180), Y(215), sx(360), sy(90)) end
                local bo = self:brandOverlay(v)
                if bo ~= nil then renderOverlay(bo, X(450 - 70), Y(335), sx(140), sy(70)) end
                rect(225, 395, 450, 12, { 0.16, 0.19, 0.22, 1 })
                if frac > 0 then rect(225, 395, 450 * frac, 12, { 0.20, 0.56, 0.84, 1 }) end
                text(450, 440, 14, T("boot"), { 0.62, 0.66, 0.70, 1 }, RenderText.ALIGN_CENTER)
            end
            self.boxes = {}
            return
        end
    end
    rect(10, 10, Wp - 20, AS_Terminal.SHORT_TABS and Hp - 20 or Hp - 34, C.screen)
    self.noticeFns = { rect = rect, text = text, image = image, rec = rec, W = Wp, H = Hp }   -- (70h) écran allumé : message possible

    -- bandeau du haut (bleu ciel) : page, heure, mode, réglages, pages, fermer
    -- (31/10 soir) accueil : bandeau aux couleurs de la marque, son logo au milieu
    local home = self.page == "home"
    -- (31/10 soir) thème « Marque » : couleurs de la marque sur TOUTES les pages, pas seulement l'accueil
    local brandTheme = (self.settings.theme or 3) == 3
    local st = brandTheme and self:brandStyle(v) or nil
    local hdrTxt = (st ~= nil and st.darkText) and { 0, 0, 0, 1 } or { 1, 1, 1, 1 }
    -- boutons et onglet actifs aux couleurs de la marque (remis à la fin du dessin)
    local saveG, saveGH = nil, nil
    if st ~= nil and (st.btn or st.hdr) ~= nil and not st.darkText then
        local b = st.btn or st.hdr
        saveG, saveGH = { C.green[1], C.green[2], C.green[3], C.green[4] }, { C.greenHi[1], C.greenHi[2], C.greenHi[3], C.greenHi[4] }
        self.greenBackup = { saveG, saveGH }
        C.green[1], C.green[2], C.green[3], C.green[4] = b[1], b[2], b[3], 1
        C.greenHi[1], C.greenHi[2], C.greenHi[3], C.greenHi[4] = math.min(1, b[1] * 1.25 + 0.05), math.min(1, b[2] * 1.25 + 0.05), math.min(1, b[3] * 1.25 + 0.05), 1
    end
    -- (01/11, 37c) moissonneuse, ensileuse, récolteuse automotrices : l'onglet OUTIL devient MACHINE,
    -- sans colonne de gauche, textes plus grands
    local harvestSelf = d.mach ~= nil and d.mach.kind ~= "spreader" and d.mach.obj == v
    self.harvestSelf = harvestSelf
    local function pageTitle(pg) if pg == "tool" and harvestSelf then return T("p_harvest") end return T("p_" .. pg) end
    -- (02/11) Case IH : habillage du vrai AFS Pro 1200 :
    -- fond gris, barre du haut gris foncé à icônes, onglets du bas gris foncé, cases et fenêtres blanches
    local caseUI = st ~= nil and st.layout == "case"
    self.caseUI = caseUI
    AS_Terminal.nhSkin = caseUI and st.nh == true
    local mode
    if d.guide ~= nil then mode = T("g_" .. d.guide) elseif d.manual == true then mode = T("manual") else mode = T("auto") end
    -- (02/11) moissonneuse Case : l'écran entier = l'image 1 (accueil et MACHINE)
    if caseUI and harvestSelf and d.mach ~= nil and d.mach.kind == "combine" and (self.page == "home" or self.page == "tool") then
        local okS, errS = pcall(self.caseCombScreen, self, d, { text = text, measure = measure, rect = rect, button = button, hotspot = hotspot,
            image = image, rec = rec, X = X, Y = Y, sx = sx, sy = sy }, v, Wp, Hp)
        if okS then
            if saveG ~= nil then
                for j = 1, 4 do C.green[j], C.greenHi[j] = saveG[j], saveGH[j] end
                self.greenBackup = nil
            end
            return
        end
        if not self.loggedCmbScreen then self.loggedCmbScreen = true; log("ERREUR écran moissonneuse Case : %s", tostring(errS)) end
    end
    -- (02/11) tracteur Case : l'accueil entier = son écran « Tractor | Lights »
    -- (03/11) New Holland = l'accueil du CASE (onglets du bas, colonne de droite,
    -- feux), tracteur bleu (as_nh_b4_home) ; son ancienne image d'accueil NH n'est plus utilisée
    local nhHome = false
    local trPage = caseUI and not harvestSelf and (home and (nhHome and self.nhHomeScreen or self.caseHomeScreen) or (self.page == "tractor" and self.casePerf1Screen)
        or (self.page == "count" and self.casePerf2Screen) or (self.page == "cam" and self.caseCamScreen) or (self.page == "gps" and AS_TerminalGps ~= nil and self.caseMapScreen) or self.caseTractorPage) or nil
    if trPage then
        self.caseStyle = caseUI
        self.colPending = nil
        local okS, errS = pcall(trPage, self, d, { text = text, measure = measure, rect = rect, button = button, hotspot = hotspot,
            image = image, rec = rec, X = X, Y = Y, sx = sx, sy = sy }, v, Wp, Hp, inside, pageTitle(self.page))
        if okS and self.colPending ~= nil and self.colMenu ~= nil then   -- (06/11) liste de la colonne de gauche, par-dessus la page
            local okM, errM = pcall(self.caseColMenu, self, self.colPending)
            if not okM and not self.loggedColMenu then self.loggedColMenu = true; log("ERREUR liste colonne : %s", tostring(errM)) end
        end
        self.colPending = nil
        if okS then
            if saveG ~= nil then
                for j = 1, 4 do C.green[j], C.greenHi[j] = saveG[j], saveGH[j] end
                self.greenBackup = nil
            end
            return
        end
        if not self.loggedHomeError then self.loggedHomeError = true; log("ERREUR écran tracteur Case : %s", tostring(errS)) end
    end
    -- (06/11) John Deere : son G5 CommandCenter (TerminalJohnDeere.lua) sur les tracteurs et les ensileuses ;
    -- pages « jd... » réservées au John Deere
    local jdUI = st ~= nil and st.jd5 == true and AS_TerminalJohnDeere ~= nil and AS_TerminalJohnDeere.screenFor ~= nil
        and (not harvestSelf or (d.mach ~= nil and d.mach.kind == "forage"))
    if not jdUI and type(self.page) == "string" and self.page:sub(1, 2) == "jd" then self.page = "home" end
    if jdUI then
        self.caseStyle = false
        if type(self.page) == "string" then
            local p2 = self.page:sub(1, 2)
            if p2 == "cl" or p2 == "mf" or p2 == "fd" or p2 == "df" then self.page = "home" end
        end
        local fnJ = AS_TerminalJohnDeere.screenFor(self)
        local okJ, errJ = pcall(fnJ, self, d, { text = text, measure = measure, rect = rect, button = button, hotspot = hotspot,
            image = image, rec = rec, X = X, Y = Y, sx = sx, sy = sy }, v, Wp, Hp, inside)
        if okJ then
            if saveG ~= nil then
                for j = 1, 4 do C.green[j], C.greenHi[j] = saveG[j], saveGH[j] end
                self.greenBackup = nil
            end
            return
        end
        if not self.loggedJdError then self.loggedJdError = true; log("ERREUR écran John Deere : %s", tostring(errJ)) end
    end
    -- (06/11) tracteur Deutz-Fahr : son iMonitor (TerminalDeutz.lua) ; pages « df... » réservées au Deutz
    local dfUI = st ~= nil and st.df == true and not harvestSelf and AS_TerminalDeutz ~= nil and AS_TerminalDeutz.screenFor ~= nil
    if not dfUI and type(self.page) == "string" and self.page:sub(1, 2) == "df" then self.page = "home" end
    if dfUI then
        self.caseStyle = false
        if type(self.page) == "string" and (self.page:sub(1, 2) == "cl" or self.page:sub(1, 2) == "mf" or self.page:sub(1, 2) == "fd") then self.page = "home" end
        local fnD = AS_TerminalDeutz.screenFor(self)
        local okD, errD = pcall(fnD, self, d, { text = text, measure = measure, rect = rect, button = button, hotspot = hotspot,
            image = image, rec = rec, X = X, Y = Y, sx = sx, sy = sy }, v, Wp, Hp, inside)
        if okD then
            if saveG ~= nil then
                for j = 1, 4 do C.green[j], C.greenHi[j] = saveG[j], saveGH[j] end
                self.greenBackup = nil
            end
            return
        end
        if not self.loggedDfError then self.loggedDfError = true; log("ERREUR écran Deutz : %s", tostring(errD)) end
    end
    -- (05/11) tracteur Fendt : son FendtONE (TerminalFendt.lua) ; pages « fd... » réservées au Fendt
    local fdUI = st ~= nil and st.fd == true and not harvestSelf and AS_TerminalFendt ~= nil and AS_TerminalFendt.screenFor ~= nil
    if not fdUI and type(self.page) == "string" and self.page:sub(1, 2) == "fd" then self.page = "home" end
    if fdUI then
        self.caseStyle = false
        if type(self.page) == "string" and (self.page:sub(1, 2) == "cl" or self.page:sub(1, 2) == "mf") then self.page = "home" end
        local fnF = AS_TerminalFendt.screenFor(self)
        local okF, errF = pcall(fnF, self, d, { text = text, measure = measure, rect = rect, button = button, hotspot = hotspot,
            image = image, rec = rec, X = X, Y = Y, sx = sx, sy = sy }, v, Wp, Hp, inside)
        if okF then
            if saveG ~= nil then
                for j = 1, 4 do C.green[j], C.greenHi[j] = saveG[j], saveGH[j] end
                self.greenBackup = nil
            end
            return
        end
        if not self.loggedFdError then self.loggedFdError = true; log("ERREUR écran Fendt : %s", tostring(errF)) end
    end
    -- (04/11) tracteur Massey Ferguson : son Datatronic 5 (TerminalMassey.lua) ; pages « mf... » réservées au Massey
    local mfUI = st ~= nil and st.mf == true and not harvestSelf and AS_TerminalMassey ~= nil and AS_TerminalMassey.screenFor ~= nil
    if not mfUI and type(self.page) == "string" and self.page:sub(1, 2) == "mf" then self.page = "home" end
    if mfUI then
        self.caseStyle = false
        if type(self.page) == "string" and self.page:sub(1, 2) == "cl" then self.page = "home" end
        local fnM = AS_TerminalMassey.screenFor(self)
        local okM, errM = pcall(fnM, self, d, { text = text, measure = measure, rect = rect, button = button, hotspot = hotspot,
            image = image, rec = rec, X = X, Y = Y, sx = sx, sy = sy }, v, Wp, Hp, inside)
        if okM then
            if saveG ~= nil then
                for j = 1, 4 do C.green[j], C.greenHi[j] = saveG[j], saveGH[j] end
                self.greenBackup = nil
            end
            return
        end
        if not self.loggedMfError then self.loggedMfError = true; log("ERREUR écran Massey : %s", tostring(errM)) end
    end
    -- (04/11) tracteur Claas : son terminal CEBIS + CEMIS (châssis de l'écran 02)
    local claasUI = st ~= nil and st.claas == true and not harvestSelf
    if claasUI then
        self.caseStyle = false
        if not d.motorOn then self:claasSetView(v, nil) end
        local fnC = self:claasScreenFor(v)
        local okC, errC = pcall(fnC, self, d, { text = text, measure = measure, rect = rect, button = button, hotspot = hotspot,
            image = image, rec = rec, X = X, Y = Y, sx = sx, sy = sy }, v, Wp, Hp, inside, pageTitle(self.page))
        if okC then
            if saveG ~= nil then
                for j = 1, 4 do C.green[j], C.greenHi[j] = saveG[j], saveGH[j] end
                self.greenBackup = nil
            end
            return
        end
        if not self.loggedClaasError then self.loggedClaasError = true; log("ERREUR écran Claas : %s", tostring(errC)) end
    end
    if caseUI then
        local WH = { 1, 1, 1, 1 }
        rect(10, 10, Wp - 20, AS_Terminal.SHORT_TABS and Hp - 20 or Hp - 34, CASE_BG)
        rect(10, 10, Wp - 20, 36, CASE_BAR)
        self.headerBox = { x = X(14), y = Y(44), w = sx(Wp - 28 - 200), h = sy(30) }
        -- STOP, alerte, info (à gauche, comme le vrai)
        hotspot(16, 13, 30, 30, "stop")
        image(16, 13, 30, 30, rec == nil and AS_TerminalTools ~= nil and AS_TerminalTools:overlay(caseImg("as_case_stop")) or nil, "img_as_case_stop", caseImg("as_case_stop"))
        text(31, 32, 8, "STOP", WH, RenderText.ALIGN_CENTER, true, 26)
        hotspot(54, 13, 30, 30, "page_tractor")
        image(55, 14, 28, 28, rec == nil and AS_TerminalTools ~= nil and AS_TerminalTools:overlay(caseImg("as_case_warn")) or nil, "img_as_case_warn", caseImg("as_case_warn"))
        hotspot(92, 13, 30, 30, "page_tractor")
        image(93, 14, 28, 28, rec == nil and AS_TerminalTools ~= nil and AS_TerminalTools:overlay(caseImg("as_case_info")) or nil, "img_as_case_info", caseImg("as_case_info"))
        rect(130, 14, 1, 28, CASE_SEP)
        text(140, 34, 14, pageTitle(self.page), WH, nil, true, 200)
        -- l'heure dans sa case sombre, au milieu
        rect(Wp * 0.5 - 52, 14, 104, 28, CASE_SEP)
        rect(Wp * 0.5 - 51, 15, 102, 26, CASE_CLOCK)
        text(Wp * 0.5, 35, 17, fmtClock(), WH, RenderText.ALIGN_CENTER, true, 96)
        -- à droite : mode (bouton bleu comme AUTO), réglages, pages, fermer
        rect(Wp - 300, 14, 1, 28, CASE_SEP)
        rect(Wp - 290, 15, 96, 26, BLUE_CASE)
        text(Wp - 242, 33, 12, mode, WH, RenderText.ALIGN_CENTER, true, 90)
        hotspot(Wp - 186, 13, 36, 30, "page_set")
        if self.page == "set" then rect(Wp - 186, 13, 36, 30, BLUE_CASE) end
        image(Wp - 183, 15, 30, 26, rec == nil and AS_TerminalTools ~= nil and AS_TerminalTools:overlay(caseImg("as_case_w_settings")) or nil, "img_as_case_w_settings", caseImg("as_case_w_settings"))
        hotspot(Wp - 144, 13, 34, 30, "prev")
        text(Wp - 127, 35, 17, "<", WH, RenderText.ALIGN_CENTER, true)
        hotspot(Wp - 106, 13, 34, 30, "next")
        text(Wp - 89, 35, 17, ">", WH, RenderText.ALIGN_CENTER, true)
        rect(Wp - 66, 14, 1, 28, CASE_SEP)
        hotspot(Wp - 60, 13, 40, 30, "close")
        text(Wp - 40, 36, 18, "X", WH, RenderText.ALIGN_CENTER, true)
    else
    rect(14, 14, Wp - 28, 30, st ~= nil and st.hdr or C.green)
    self.headerBox = { x = X(14), y = Y(44), w = sx(Wp - 28 - 200), h = sy(30) }
    text(24, 36, 17, pageTitle(self.page), hdrTxt, nil, true, (self.touch and AS_Terminal.SHORT_TABS) and 166 or 270)
    rect(300, 18, 70, 22, C.screen, 0.55)
    text(335, 35, 14, fmtClock(), C.white, RenderText.ALIGN_CENTER, true)
    local mx = st ~= nil and 510 or 376
    rect(mx, 18, 170, 22, C.screen, 0.55)
    text(mx + 85, 35, 13, mode, C.white, RenderText.ALIGN_CENTER, true)
    if st ~= nil then
        -- logo de la marque (boîte 2:1 comme les logos du jeu) entre l'heure et le mode
        image(410, 15, 56, 28, rec == nil and self:brandOverlay(v) or nil, "imgMarque")
    end
    button(Wp - 210, 17, 60, 24, "page_set", self.page == "set")
    text(Wp - 180, 35, 12, T("b_set"), C.white, RenderText.ALIGN_CENTER, true)
    button(Wp - 144, 17, 34, 24, "prev")
    text(Wp - 127, 35, 15, "<", C.white, RenderText.ALIGN_CENTER, true)
    button(Wp - 106, 17, 34, 24, "next")
    text(Wp - 89, 35, 15, ">", C.white, RenderText.ALIGN_CENTER, true)
    button(Wp - 64, 17, 44, 24, "close")
    text(Wp - 42, 35, 15, "X", C.red, RenderText.ALIGN_CENTER, true)
    end

    if home then
        local ctx = { text = text, measure = measure, rect = rect, button = button, hotspot = hotspot, image = image, cx = 14, cy = 50,
            cw = Wp - 28, ch = Hp - 50 - 96, X = X, Y = Y, sx = sx, sy = sy, rec = rec, style = st }
        local okH, errH = pcall(self.page_home, self, d, ctx, inside, v)
        if not okH and not self.loggedHomeError then
            self.loggedHomeError = true
            log("ERREUR écran d'accueil : %s", tostring(errH))
        end
    end
    -- colonne de gauche : lieu, vitesse, couverture, consommation, heures
    local job = d.cnt.jobs[d.cnt.active]
    local fuelLow = d.fuel ~= nil and d.fuel * 100 < self.settings.fuelReserve
    local blink = math.floor((g_time or 0) / 500) % 2 == 0
    local col = {
        { T("loc"), d.field ~= nil and string.format(T("field"), d.field) or "-", "",
            d.fieldHa ~= nil and string.format("%.2f ha", d.fieldHa) or nil },
        { T("speed"), string.format("%d", math.floor(math.abs(d.speed) + 0.5)), "km/h" },
        { T("cover"), string.format("%.2f", job.ha), "ha", string.format(T("job"), d.cnt.active) },
        { T("cons"), fmt1(d.fuelUse), "l/h", job.ha > 0.01 and string.format("%.1f l/ha", job.fuel / job.ha) or nil, fuel = true },
        { T("hours"), fmtHM(job.ms), "h" },
    }
    -- (01/11) page OUTIL : vitesse, distance, distance au travail, surface, l/h
    if self.page == "tool" or self.page == "gps" then
        col = {
            { T("speed"), string.format("%d", math.floor(math.abs(d.speed) + 0.5)), "km/h" },
            { T("c_dist"), string.format("%.2f", (job.dist or 0) / 1000), "km", string.format(T("job"), d.cnt.active) },
            { T("c_distW"), string.format("%.2f", (job.distW or 0) / 1000), "km",
                (job.dist or 0) > 50 and string.format("%d %%", math.floor((job.distW or 0) / job.dist * 100 + 0.5)) or nil },
            { T("c_area"), string.format("%.2f", job.ha), "ha", job.ms > 60000 and string.format("%.2f ha/h", job.ha / (job.ms / 3600000)) or nil },
            { T("cons"), fmt1(d.fuelUse), "l/h", job.ha > 0.01 and string.format("%.1f l/ha", job.fuel / job.ha) or nil, fuel = true },
        }
    end
    -- (01/11, étape 37b) GUIDAGE et FARMPILOT : pas de colonne de gauche, la page prend toute la largeur
    local noLeft = self.page == "gps" or self.page == "fp" or (self.page == "tool" and harvestSelf)
    -- (01/11) Case IH : la colonne de cases du vrai terminal, sur toutes les pages
    local caseCol = st ~= nil and st.layout == "case" and not home
    self.caseStyle = st ~= nil and st.layout == "case"
    -- (01/11 soir) moissonneuse Case, page MACHINE : comme le modèle, colonne plus large, pas de touches à droite
    local caseComb = caseCol and self.page == "tool" and harvestSelf and d.mach ~= nil and d.mach.kind == "combine"
    if caseCol then
        local okK, errK = pcall(self.caseColumn, self, { rect = rect, text = text, image = image, rec = rec, measure = measure },
            d, self.page, 14, 50, caseComb and 158 or 128, Hp - 50 - 96)
        if not okK and not self.loggedCaseCol then self.loggedCaseCol = true; log("ERREUR colonne Case : %s", tostring(errK)) end
    end
    for i, c in ipairs(col) do
        if home or noLeft or caseCol then break end
        local yy = 50 + (i - 1) * 71
        rect(14, yy, 124, 67, C.box)
        if not AS_Terminal.BIG_TEXT then
            -- mise en page d'avant l'étape 37
            text(20, yy + 15, 12, c[1], C.gray, nil, true)
            local valCol0 = C.white
            if c.fuel and fuelLow then valCol0 = blink and C.red or C.white end
            text(20, yy + 43, (i == 1 and self.page ~= "tool" and self.page ~= "gps") and 15 or 24, c[2], valCol0, nil, true)
            text(132, yy + 43, 11, c[3], C.gray, RenderText.ALIGN_RIGHT)
            if c[4] ~= nil then text(20, yy + 60, 11, c[4], C.gray) end
        else
        -- (étape 37) unité à droite de la valeur agrandie ; si elle ne tient pas, en bas à droite
        local unitW = (c[3] ~= nil and c[3] ~= "") and measure(11, c[3]) + 6 or 0
        local vSize = (i == 1 and self.page ~= "tool" and self.page ~= "gps") and 15 or 24
        local unitOnValue = unitW == 0 or measure(vSize, c[2]) + unitW <= 112
        text(20, yy + 16, 12, c[1], C.gray, nil, true, 112)
        local valCol = C.white
        if c.fuel and fuelLow then valCol = blink and C.red or C.white end
        text(20, yy + 44, vSize, c[2], valCol, nil, true, unitOnValue and 112 - unitW or 112)
        if unitW > 0 then text(132, unitOnValue and yy + 44 or yy + 61, 11, c[3], C.gray, RenderText.ALIGN_RIGHT) end
        if c[4] ~= nil then text(20, yy + 61, 11, c[4], C.gray, nil, nil, unitOnValue and 112 or 112 - unitW) end
        end
    end

    -- contenu de la page
    local cx, cy, cw, ch = 146, 50, Wp - 146 - 160, Hp - 50 - 96
    if noLeft then cx, cw = 14, Wp - 14 - 160 end
    if caseCol then cx, cw = 146, Wp - 146 - 160 end
    if caseComb then cx, cw = 176, Wp - 14 - 176 end
    if not home then
    rect(cx, cy, cw, ch, caseUI and CASE_CARD or C.box, caseUI and 1 or 0.55)
    local rx = Wp - 154
    if caseUI and not caseComb then
        rect(rx, cy, 140, ch, CASE_BAND)
        text(rx + 6, cy + 14, 12, pageTitle(self.page), { 0.10, 0.12, 0.15, 1 }, nil, true)
    elseif not caseComb then
        rect(rx, cy, 140, ch, C.box, 0.55)
        text(rx + 6, cy + 14, 12, pageTitle(self.page), C.gray, nil, true)
    end
    local ctx = { text = text, measure = measure, rect = rect, button = button, hotspot = hotspot, image = image, cx = cx, cy = cy, cw = cw, ch = ch, rx = rx,
        X = X, Y = Y, sx = sx, sy = sy, rec = rec, v = v }
    local fn = self["page_" .. self.page]
    if fn ~= nil then fn(self, d, ctx, inside, v) end
    end

    -- barre du bas : états et pages
    -- (01/11, étape 37) lisibilité : 5 ou 6 onglets plus larges ; RELEVAGE, INFO, TRAVAIL et
    -- COMPTEURS passent dans « PLUS », qui remplace la barre par ces onglets (RETOUR pour revenir)
    local by = Hp - 94
    local liftTab = { "lift", T("b_lift"), not d.anyLowerable and "-" or (d.anyLowered and T("lowered") or T("raised")), d.anyLowered and C.lamp or C.dim }
    local MORE = { tractor = true, work = true, count = true }
    local tabs
    if not AS_Terminal.SHORT_TABS then
        -- barre d'avant l'étape 37 : tous les onglets
        self.moreOpen = nil
        tabs = {
            { "stop",    (d.guide ~= nil or d.anyOn) and T("b_stop") or T("b_on"),  d.guide ~= nil and T("g_" .. d.guide) or (d.anyOn and T("on") or T("off")), (d.guide ~= nil or d.anyOn) and C.lamp or C.dim },
            liftTab,
            { "guide",   T("b_guide"), d.guide ~= nil and T("g_" .. d.guide) or T("none"), d.guide ~= nil and C.blue or C.dim },
            { "page_home",    T("p_home") },
            { "page_tractor", T("p_tractor") },
            { "page_tool",    pageTitle("tool") },
            { "page_work",    T("p_work") },
            { "page_count",   T("p_count") },
        }
        if AS_TerminalFp ~= nil and AS_TerminalFp:available(v) then
            local okR, running = pcall(function() return v.ad.stateModule:isActive() end)
            table.insert(tabs, 4, { "page_fp", T("p_fp"), (okR and running) and T("fpRunning") or T("fpStopped"), (okR and running) and C.lamp or C.dim })
        end
    elseif self.moreOpen then
        tabs = {
            liftTab,
            { "page_tractor", T("p_tractor") },
            { "page_work",    T("p_work") },
            { "page_count",   T("p_count") },
            { "more",         T("b_back") },
        }
    else
        local onMore = MORE[self.page] == true
        tabs = {
            { "stop",    (d.guide ~= nil or d.anyOn) and T("b_stop") or T("b_on"),  d.guide ~= nil and T("g_" .. d.guide) or (d.anyOn and T("on") or T("off")), (d.guide ~= nil or d.anyOn) and C.lamp or C.dim },
            -- (31/10) MARCHE retiré de la barre du bas : il est dans l'onglet OUTIL
            { "guide",   T("b_guide"), d.guide ~= nil and T("g_" .. d.guide) or T("none"), d.guide ~= nil and C.blue or C.dim },
            { "page_home",    T("p_home") },
            { "page_tool",    pageTitle("tool") },
            { "more",    T("b_more"), onMore and pageTitle(self.page) or (d.anyLowered and T("lowered") or nil), (onMore or d.anyLowered) and C.lamp or C.dim, active = onMore },
        }
        -- (01/11, étape 36) onglet FARMPILOT après GUIDAGE, seulement si le véhicule a FarmPilot
        if AS_TerminalFp ~= nil and AS_TerminalFp:available(v) then
            local okR, running = pcall(function() return v.ad.stateModule:isActive() end)
            table.insert(tabs, 3, { "page_fp", T("p_fp"), (okR and running) and T("fpRunning") or T("fpStopped"), (okR and running) and C.lamp or C.dim })
        end
    end
    local tw = (Wp - 28) / #tabs
    local tabH = AS_Terminal.SHORT_TABS and 66 or 52
    if caseUI then rect(10, by - 4, Wp - 20, tabH + 8, CASE_BAR) end
    for i, t in ipairs(tabs) do
        local u = 14 + (i - 1) * tw
        local pageTab = t[1]:sub(1, 5) == "page_"
        local active = t.active or (pageTab and ("page_" .. self.page) == t[1]) or (t[1] == "guide" and (self.page == "gps" or self.page == "cp"))
        if caseUI then
            -- Case : onglets gris foncé, trait bleu au-dessus de l'onglet actif, textes blancs
            local WH, LG = { 1, 1, 1, 1 }, { 0.72, 0.74, 0.77, 1 }
            hotspot(u + 1, by, tw - 2, tabH, t[1])
            rect(u + 1, by, tw - 2, tabH, active and CASE_TAB_ON or CASE_TAB)
            if active then rect(u + 1, by, tw - 2, 4, CASE_TAB_LINE) end
            text(u + tw * 0.5, by + (t[3] ~= nil and 24 or 32), 12, t[2], WH, RenderText.ALIGN_CENTER, true, tw - 10)
            if t[3] ~= nil then
                rect(u + 8, by + 35, 8, 8, t[4] == C.dim and LG or t[4])
                text(u + tw * 0.5 + 6, by + 44, 10, t[3], LG, RenderText.ALIGN_CENTER, nil, tw - 30)
            end
        elseif not AS_Terminal.SHORT_TABS then
            button(u + 1, by, tw - 2, tabH, t[1], active)
            text(u + tw * 0.5, by + 22, 12, t[2], C.white, RenderText.ALIGN_CENTER, true)
            if t[3] ~= nil then
                rect(u + 8, by + 34, 8, 8, t[4])
                text(u + tw * 0.5 + 6, by + 43, 10, t[3], active and C.white or C.gray, RenderText.ALIGN_CENTER)
            end
        elseif t[3] ~= nil then
            button(u + 1, by, tw - 2, tabH, t[1], active)
            text(u + tw * 0.5, by + 26, 13, t[2], C.white, RenderText.ALIGN_CENTER, true, tw - 10)
            rect(u + 8, by + 40, 12, 12, t[4])
            text(u + tw * 0.5 + 8, by + 54, 11, t[3], active and C.white or C.gray, RenderText.ALIGN_CENTER, nil, tw - 34)
        else
            button(u + 1, by, tw - 2, tabH, t[1], active)
            text(u + tw * 0.5, by + 40, 13, t[2], C.white, RenderText.ALIGN_CENTER, true, tw - 10)
        end
    end
    -- (étape 37) « A U T O S W I T C H » retiré du bas (le cadre porte déjà le logo) ; TACTILE dans le bandeau
    if not AS_Terminal.SHORT_TABS then
        text(Wp * 0.5, Hp - 14, 10, "A U T O S W I T C H", C.dim, RenderText.ALIGN_CENTER, true)
        if self.touch then
            rect(Wp - 110, Hp - 26, 96, 14, C.green, 0.8)
            text(Wp - 62, Hp - 15, 10, T("touch"), C.white, RenderText.ALIGN_CENTER, true)
        end
    elseif self.touch then
        rect(196, 19, 96, 20, C.screen, 0.55)
        text(244, 34, 10, T("touch"), C.amber, RenderText.ALIGN_CENTER, true, 92)
    end
    if saveG ~= nil then
        for j = 1, 4 do C.green[j], C.greenHi[j] = saveG[j], saveGH[j] end
        self.greenBackup = nil
    end
end

-------------------------------------------------------------------------------
-- Commandes (étape 4) : on passe toujours par les fonctions du jeu, de Courseplay
-- ou d'AutoDrive (mêmes contrôles et mêmes messages que leurs touches, multijoueur compris)
-------------------------------------------------------------------------------
-- (13/11) cpInstalled / fpInstalled : Courseplay ou FarmPilot pas installés = rien d'eux dans les tablettes
-- (ni bouton, ni page, ni message « absent ») ; ils sont conseillés dans la description du mod
local cpInst = nil
local function cpInstalled()
    if cpInst ~= nil then return cpInst end
    local found = false
    if g_modIsLoaded ~= nil then
        for n, on in pairs(g_modIsLoaded) do
            if on == true and type(n) == "string" and n:lower():find("courseplay", 1, true) then found = true break end
        end
    end
    if g_currentMission ~= nil then cpInst = found end   -- tous les mods sont chargés : on garde la réponse
    return found
end
local function fpInstalled()
    return isFarmPilot()
end
local CP_ACTS = { page_cp = true, page_dfcp = true, page_jdcp = true, mfcp = true, mfcp_back = true, fd_cp = true, fdg_course = true }
local function hiddenAction(a)
    if type(a) ~= "string" then return false end
    if (CP_ACTS[a] or a:sub(1, 3) == "cp_") and not cpInstalled() then return true end
    if a == "page_fp" and not fpInstalled() then return true end
    return false
end

local function warn(txt)
    -- (13/11) pas de message « Courseplay / FarmPilot absent » quand le mod n'est pas installé
    if txt ~= nil and ((txt == T("cpMissing") and not cpInstalled()) or (txt == T("fpMissing") and not fpInstalled())) then return end
    if txt ~= nil and g_currentMission ~= nil and g_currentMission.showBlinkingWarning ~= nil then
        pcall(g_currentMission.showBlinkingWarning, g_currentMission, txt, 2500)
    end
end

-- Courseplay : nom du mod variable (FS25_Courseplay, copie renommée...), on cherche la globale
local cpModName
local function cpGlobal(name)
    if cpModName ~= nil then return AS.modGlobal(cpModName, name) end
    local found = AS.modGlobal("FS25_Courseplay", name)
    if found ~= nil then cpModName = "FS25_Courseplay" return found end
    if g_modManager ~= nil and g_modManager.getActiveMods ~= nil then
        local ok, mods = pcall(g_modManager.getActiveMods, g_modManager)
        if ok and type(mods) == "table" then
            for _, m in ipairs(mods) do
                local n = m.modName
                if type(n) == "string" and n:lower():find("courseplay", 1, true) then
                    found = AS.modGlobal(n, name)
                    if found ~= nil then cpModName = n return found end
                end
            end
        end
    end
    return nil
end

local function hasCp(v)
    return v ~= nil and v.getCpStartingPointSetting ~= nil and v.cpStartStopDriver ~= nil
end

local function hasAd(v)
    return v ~= nil and v.ad ~= nil and v.ad.stateModule ~= nil
end

-- relevage : tous les outils baissés -> relevés, sinon tout baisser (comme « tout baisser » du jeu,
-- mais outil par outil pour que chaque attelage garde ses propres limites)
-- (03/11) même verrouillés, la flèche n'en commandait qu'un (faucheuse papillon AR + frontale AV)
-- un outil = ce que fait la touche « baisser » du jeu : l'attelage 3 points ET le pliage du milieu (faucheuse
-- papillon, déchaumeur...) ensemble. Avant, un outil à pliage du milieu porté par un 3 points ne recevait que
-- l'attelage : la faucheuse restait baissée. Chaque outil est noté dans le log.
local function lowerOne(o, down)
    local own, jl, was = ownLowerKind(o), jointLowers(o), isLowered(o)
    local did = {}
    if own == "pickup" and not jl then
        local ok, err = pcall(o.setPickupState, o, down)
        did[#did + 1] = ok and "pick-up" or ("ERREUR pick-up " .. tostring(err))
    else
        if jl or own == nil then
            local av = call(o, "getAttacherVehicle")
            local idx = av ~= nil and call(av, "getAttacherJointIndexFromObject", o) or nil
            if idx ~= nil and av.handleLowerImplementByAttacherJointIndex ~= nil then
                local ok, err = pcall(av.handleLowerImplementByAttacherJointIndex, av, idx, down)
                did[#did + 1] = ok and "attelage" or ("ERREUR attelage " .. tostring(err))
            end
        end
        if own == "fold" and was ~= down and Foldable ~= nil and Foldable.actionEventFoldMiddle ~= nil then
            local ok, err = pcall(Foldable.actionEventFoldMiddle, o, "", 1, nil, false)
            did[#did + 1] = ok and "pliage du milieu" or ("ERREUR pliage " .. tostring(err))
        elseif own == "fold" then
            did[#did + 1] = "pliage déjà bon"
        end
    end
    return did, own, jl, was
end
function AS_Terminal:cmdLift(v, down)
    if down == nil then
        -- (03/11) le sens se décide sur les attelages ACTIFS : un actif encore levé → on baisse, sinon on lève
        down = false
        for _, o in ipairs(trainOf(v)) do
            if o ~= v and isLowered(o) == false and self:hitchLocked(v, hitchSideOf(v, o)) then down = true end
        end
    end
    local n, nLock = 0, 0
    for _, o in ipairs(trainOf(v)) do
        if o ~= v and isLowered(o) ~= nil and onSide(self, v, o) then
            local front = hitchSideOf(v, o)
            if self.cmdSide == nil and not self:hitchLocked(v, front) then
                -- (03/11) attelage déverrouillé = non actif : la flèche générale l'ignore
                nLock = nLock + 1
                log("flèche %s : %s (%s) non actif, ignoré", down and "baisser" or "lever", vehicleName(o), front and "AV" or "AR")
            else
                local did, own, jl, was = lowerOne(o, down)
                if #did > 0 then n = n + 1 end
                log("flèche %s : %s (%s, %s, attelage %s, était %s) : %s", down and "baisser" or "lever", vehicleName(o), front and "AV" or "AR",
                    tostring(own or "3 points"), jl and "oui" or "non", was and "baissé" or "levé", #did > 0 and table.concat(did, " + ") or "rien")
            end
        end
    end
    if n == 0 then warn(nLock > 0 and T("c_lockedWarn") or T("noLift")) end
end

-- (31/10 soir) un seul attelage (cadre Relevage AV ou AR) : baisse / lève l'outil qui y est
function AS_Terminal:cmdHitch(v, front)
    local pick
    for _, h in ipairs(hitches(v)) do
        if h.front == front and h.object ~= nil then
            if pick == nil or (h.own ~= nil and pick.own == nil) then pick = h end
        end
    end
    if pick == nil then warn(T("noLift")) return end
    local o = pick.object
    -- baissé = attelage baissé OU outil baissé (pliage du milieu) ; on fait alors tout remonter, sinon tout baisser
    local down = not (pick.moveDown == true or isLowered(o) == true)
    local did, own, jl, was = lowerOne(o, down)
    if #did == 0 then warn(T("noLift")) end
    log("relevage %s : %s -> %s (%s, attelage %s, était %s) : %s", front and "AV" or "AR", vehicleName(o), down and "baisser" or "lever",
        tostring(own or "3 points"), jl and "oui" or "non", was and "baissé" or "levé", #did > 0 and table.concat(did, " + ") or "rien")
end

-- marche / arrêt des machines (prise de force) : tracteur d'abord (moissonneuse), puis outils
function AS_Terminal:cmdTurnOn(v, on)
    if on == nil then
        on = true
        for _, o in ipairs(trainOf(v)) do if isTurnedOn(o) == true then on = false end end
    end
    local n = 0
    for _, o in ipairs(trainOf(v)) do
        if o.setIsTurnedOn ~= nil and isTurnedOn(o) ~= nil and isTurnedOn(o) ~= on and onSide(self, v, o) then
            if on and call(o, "getCanBeTurnedOn") == false then
                warn(call(o, "getTurnedOnNotAllowedWarning"))
            elseif o.getCanToggleTurnedOn == nil or call(o, "getCanToggleTurnedOn") ~= false then
                if pcall(o.setIsTurnedOn, o, on) then n = n + 1 end
            end
        end
    end
    return n
end

-- pliage : s'il reste un outil déplié on replie, sinon on déplie tout (fonction de la touche du jeu)
function AS_Terminal:cmdFold(v, open)   -- open = nil : bascule ; true : déplier ; false : plier
    local list, anyOpen = {}, false
    for _, o in ipairs(trainOf(v)) do
        local sp = o.spec_foldable
        -- (31/10) automoteurs (pulvé, épandeur) : les rampes font partie du véhicule
        local selfTool = o == v and (o.spec_sprayer ~= nil)
        if (o ~= v or selfTool) and sp ~= nil and sp.foldingParts ~= nil and #sp.foldingParts > 0 and onSide(self, v, o) then
            local open = call(o, "getIsUnfolded") == true
            list[#list + 1] = { o = o, open = open }
            if open then anyOpen = true end
        end
    end
    if #list == 0 then warn(T("noFold")) return end
    local fn = Foldable ~= nil and Foldable.actionEventFold or nil
    if open == nil then open = not anyOpen end
    for _, e in ipairs(list) do
        if e.open ~= open and fn ~= nil then
            local ok, err = pcall(fn, e.o)
            if not ok then log("ERREUR pliage %s : %s", vehicleName(e.o), tostring(err)) end
        end
    end
end

-- (31/10) benne : en cours -> arrêt ; sinon dans ce qui est dessous (remorque, silo) si possible, sinon au sol
-- (mêmes fonctions que les touches du jeu)
function AS_Terminal:cmdTip(v, start)   -- start = nil : bascule ; true : benner ; false : arrêter
    local list, any = {}, false
    for _, o in ipairs(trainOf(v)) do
        if o ~= v and o.spec_trailer ~= nil and o.spec_dischargeable ~= nil and o.getDischargeState ~= nil and onSide(self, v, o) then
            list[#list + 1] = o
            if (call(o, "getDischargeState") or 0) ~= 0 then any = true end
        end
    end
    if #list == 0 then return end
    local D = Dischargeable
    local doStop = (start == nil) and any or (not start)
    for _, o in ipairs(list) do
        if doStop then
            if D ~= nil and D.DISCHARGE_STATE_OFF ~= nil then pcall(o.setDischargeState, o, D.DISCHARGE_STATE_OFF) end
        elseif (call(o, "getDischargeState") or 0) == 0 then
            local ok = false
            if D ~= nil and D.actionEventToggleDischarging ~= nil then
                local dn = call(o, "getCurrentDischargeNode")
                if dn ~= nil and call(o, "getCanDischargeToObject", dn) == true then
                    ok = pcall(D.actionEventToggleDischarging, o, "", 1, nil, false)
                end
            end
            if (call(o, "getDischargeState") or 0) == 0 and D ~= nil and D.actionEventToggleDischargeToGround ~= nil then
                ok = pcall(D.actionEventToggleDischargeToGround, o, "", 1, nil, false)
            end
            if (call(o, "getDischargeState") or 0) == 0 then
                local w = call(o, "getDischargeNotAllowedWarning", call(o, "getCurrentDischargeNode"))
                warn(type(w) == "string" and w or T("tipNo"))
            end
        end
    end
end

function AS_Terminal:cmdTipSide(v)
    for _, o in ipairs(trainOf(v)) do
        local spT = o.spec_trailer
        if o ~= v and spT ~= nil and spT.tipSides ~= nil and #spT.tipSides > 1 then
            if Trailer ~= nil and Trailer.actionEventToggleTipSide ~= nil then
                pcall(Trailer.actionEventToggleTipSide, o, "", 1, nil, false)
            elseif o.setPreferedTipSide ~= nil then
                pcall(o.setPreferedTipSide, o, ((spT.preferedTipSideIndex or 1) % #spT.tipSides) + 1)
            end
        end
    end
end

function AS_Terminal:cmdCover(v, open)   -- open = nil : bascule ; true : ouvrir ; false : fermer
    local list, anyOpen = {}, false
    for _, o in ipairs(trainOf(v)) do
        local sc = o.spec_cover
        if o ~= v and sc ~= nil and sc.covers ~= nil and #sc.covers > 0 and onSide(self, v, o) then
            list[#list + 1] = o
            if (sc.state or 0) ~= 0 then anyOpen = true end
        end
    end
    if open == nil then open = not anyOpen end
    for _, o in ipairs(list) do
        local isOpen = (o.spec_cover.state or 0) ~= 0
        if isOpen ~= open then
            if Cover ~= nil and Cover.actionEventToggleCover ~= nil then
                pcall(Cover.actionEventToggleCover, o, "", 1, nil, false)
            elseif o.setCoverState ~= nil then
                pcall(o.setCoverState, o, open and 1 or 0)
            end
        end
    end
end

-- arrêt : coupe l'aide qui conduit (Courseplay, ouvrier IA, AutoDrive) ;
-- sans aide : régulateur coupé et machines arrêtées
function AS_Terminal:cmdStop(v)
    -- (03/11) STOP (rouge) = tout arrêter d'un coup : ouvrier IA / Courseplay / autoguidage, AutoDrive / FarmPilot,
    -- régulateur, outils (plus de bascule marche / arrêt). Ordre : tâche IA (Courseplay et l'ouvrier du jeu passent par là),
    -- puis Courseplay s'il tourne encore, puis AutoDrive / FarmPilot (seulement s'il est actif : sa touche est une bascule)
    local n = 0
    if call(v, "getIsAIActive") == true and v.stopCurrentAIJob ~= nil and AIMessageSuccessStoppedByUser ~= nil then
        if pcall(v.stopCurrentAIJob, v, AIMessageSuccessStoppedByUser.new()) then n = n + 1 end
    end
    if call(v, "getIsCpActive") == true and v.cpStartStopDriver ~= nil then
        if pcall(v.cpStartStopDriver, v, true) then n = n + 1 end
    end
    if AS.isAutoDriveActive ~= nil then
        local okA, ad = pcall(AS.isAutoDriveActive, v)
        if okA and ad then
            local adi = adGlobal("ADInputManager")
            if adi ~= nil and adi.onInputCall ~= nil and pcall(adi.onInputCall, adi, v, "input_start_stop") then n = n + 1 end
        end
    end
    if v.setCruiseControlState ~= nil and Drivable ~= nil and Drivable.CRUISECONTROL_STATE_OFF ~= nil then
        local sd = v.spec_drivable
        if sd == nil or sd.cruiseControl == nil or sd.cruiseControl.state ~= Drivable.CRUISECONTROL_STATE_OFF then
            if pcall(v.setCruiseControlState, v, Drivable.CRUISECONTROL_STATE_OFF) then n = n + 1 end
        end
    end
    n = n + self:cmdTurnOn(v, false)
    log("STOP : %d arrêt(s)", n)
end

-- Courseplay : démarrer / arrêter (comme sa touche), créer le parcours du champ, réglages
function AS_Terminal:cmdCp(v, what)
    if not hasCp(v) then warn(T("cpMissing")) return end
    if what == "startStop" then
        local ok, err = pcall(v.cpStartStopDriver, v, true)
        log("Courseplay marche/arrêt : %s", ok and "ok" or ("ERREUR " .. tostring(err)))
    elseif what == "generate" then
        if call(v, "getCanStartCpFieldWork") ~= true then warn(T("cpNoField")) return end
        local cgi = cpGlobal("CourseGeneratorInterface")
        if cgi == nil then warn(T("cpMissing")) return end
        local ok, err = pcall(function() cgi():generateDefaultCourse(v) end)
        if not ok then log("ERREUR parcours Courseplay : %s", tostring(err)) end
    elseif what == "clear" then
        local ok, err = pcall(v.resetCpCoursesFromGui, v)
        if not ok then log("ERREUR effacer parcours : %s", tostring(err)) end
    elseif what == "start" then
        local st = call(v, "getCpStartingPointSetting")
        if st ~= nil then pcall(st.setNextItem, st) end
    elseif what == "manager" then
        -- (03/11) CHARGER SAUVEGARDE = son gestionnaire des courses
        local gu = cpGlobal("CpGuiUtil")
        local fn = gu ~= nil and gu.openCourseManagerGui or nil
        if fn ~= nil then
            if self.isOpen then self:setOpen(false) end
            local ok, err = pcall(fn, v)
            if not ok then log("ERREUR gestionnaire des courses Courseplay : %s", tostring(err)) end
        else
            warn(T("cpMissing"))
            log("gestionnaire des courses Courseplay introuvable (CpGuiUtil %s)", tostring(gu))
        end
    elseif what == "cgui" then
        -- (03/11) CRÉER PARCOURS = le menu classique de Courseplay (générateur de parcours s'il existe, sinon réglages)
        local gu = cpGlobal("CpGuiUtil")
        local fn = gu ~= nil and (gu.openCourseGeneratorGui or gu.openVehicleSettingsGui) or nil
        if fn ~= nil then
            if self.isOpen then self:setOpen(false) end
            local ok, err = pcall(fn, v)
            if not ok then log("ERREUR générateur Courseplay : %s", tostring(err)) end
        else
            log("menu Courseplay introuvable (CpGuiUtil %s)", tostring(gu))
        end
    elseif what == "save" then
        -- (03/11) enregistrer le parcours chargé dans le dossier Courseplay sous le nom du champ (« Champ 58 - 9 m »)
        if call(v, "hasCpCourse") ~= true then warn(T("c_cpNoCourseSave")) return end
        local cp = cpGlobal("g_Courseplay")
        local storage = cp ~= nil and cp.courseStorage or nil
        local okR, root = pcall(function() return storage:getRootDirectory() end)
        if not okR or root == nil or v.saveCpCourses == nil then warn(T("c_cpSaveErr")) log("enregistrement : stockage Courseplay introuvable") return end
        local name = self:cpCourseName(v, self.data or {})
        local file
        if root.addFile ~= nil then
            local okA, f = pcall(root.addFile, root, name)
            if okA and type(f) == "table" then file = f end
        end
        if file == nil then
            local okF, files = pcall(root.getFiles, root)
            if okF and type(files) == "table" then
                for _, f in ipairs(files) do
                    local okN, n = pcall(f.getName, f)
                    if okN and n == name then file = f end
                end
            end
        end
        if file == nil then warn(T("c_cpSaveErr")) log("enregistrement : fichier « %s » impossible", name) return end
        local ok, err = pcall(v.saveCpCourses, v, file, name)
        if ok then
            warn(string.format(T("c_cpSaved"), name)); log("parcours enregistré : %s", name)
            pcall(function() root:refresh() end)
            if AS_TerminalCourses ~= nil then AS_TerminalCourses.results = nil end
        else
            warn(T("c_cpSaveErr")); log("ERREUR enregistrement « %s » : %s", name, tostring(err))
        end
    elseif what == "menu" then
        local gu = cpGlobal("CpGuiUtil")
        if gu ~= nil and gu.openVehicleSettingsGui ~= nil then
            if self.isOpen then self:setOpen(false) end
            local ok, err = pcall(gu.openVehicleSettingsGui, v)
            if not ok then log("ERREUR menu Courseplay : %s", tostring(err)) end
        else
            log("menu Courseplay introuvable (CpGuiUtil %s)", tostring(gu))
        end
    else
        -- largeur (w-/w+) et tournières (h-/h+) du générateur de parcours
        local cs = call(v, "getCourseGeneratorSettings")
        local st = cs ~= nil and (what:sub(1, 1) == "w" and cs.workWidth or cs.numberOfHeadlands) or nil
        if st ~= nil then
            local fn = what:sub(2, 2) == "+" and st.setNextItem or st.setPreviousItem
            if fn ~= nil then pcall(fn, st) end
        end
    end
end

function AS_Terminal:cmdAd(v)
    if not hasAd(v) then return end
    local adi = adGlobal("ADInputManager")
    if adi ~= nil and adi.onInputCall ~= nil then pcall(adi.onInputCall, adi, v, "input_start_stop") end
end

-- ligne « libellé ............ valeur » d'une page
local function row(ctx, i, label, value, col, colX, colW)
    local u = ctx.cx + 10 + (colX or 0)
    local w = colW or (ctx.cw - 20)
    local yy = ctx.cy + 12 + (i - 1) * 27
    ctx.rect(u, yy, w, 24, C.box)
    -- (37c) page MACHINE des automoteurs : textes plus grands
    local ls, vs, ty = 13, 14, 17
    if ctx.bigRows then ls, vs, ty = 15, 17, 18 end
    -- (01/11) la valeur garde sa place, le libellé se réduit avant de la toucher
    local vw = math.min(ctx.measure ~= nil and ctx.measure(vs, value) or 0, w * 0.62)
    ctx.text(u + 8, yy + ty, ls, label, ctx.bigRows and C.white or C.gray, nil, nil, math.max(30, w - 16 - vw - 10))
    ctx.text(u + w - 8, yy + ty, vs, value, col or C.white, RenderText.ALIGN_RIGHT, true, w * 0.62)
end

local function bar(ctx, u, yy, w, h, frac, col)
    ctx.rect(u, yy, w, h, C.screen)
    if frac ~= nil and frac > 0 then ctx.rect(u, yy, w * clamp(frac, 0, 1), h, col or C.lamp) end
end

-- page Tracteur
function AS_Terminal:page_tractor(d, ctx)
    -- (01/11) Case IH : grille de performances du vrai terminal
    if self.caseStyle and AS_Terminal.caseInfo ~= nil then
        local okC, errC = pcall(AS_Terminal.caseInfo, self, d, ctx)
        if okC then return end
        if not self.loggedCaseInfo then self.loggedCaseInfo = true; log("ERREUR INFO Case : %s", tostring(errC)) end
    end
    local half = (ctx.cw - 30) / 2
    local gear = tostring(d.gear or "N")
    if d.group ~= nil and not d.cvt then gear = tostring(d.group) .. " " .. gear end
    if d.cvt then gear = (d.dir or 0) < 0 and "R" or ((d.dir or 0) > 0 and "D" or "N") end
    local cruise = (d.cruise ~= nil and d.cruise ~= 0) and string.format("%d km/h", math.floor((d.cruiseSpeed or 0) + 0.5)) or T("off")
    local left = {
        { T("motor"), d.motorOn and T("on") or T("off"), d.motorOn and C.lamp or C.dim },
        { T("rpm"), d.rpm ~= nil and string.format("%d %s", math.floor(d.rpm + 0.5), T("u_rpm")) or "-" },
        { T("loadP"), d.load ~= nil and fmtPct(d.load) or "-" },
        { T("gear"), d.cvt and ("CVT  " .. gear) or gear },
        { T("cruise"), cruise },
        { T("temp"), d.temp ~= nil and string.format("%d °C", math.floor(d.temp + 0.5)) or "-",
            (d.temp or 0) > 100 and C.red or nil },
        { T("fuel"), d.fuel ~= nil and string.format("%s  (%d l)", fmtPct(d.fuel), math.floor((d.fuelL or 0) + 0.5)) or "-",
            (d.fuel ~= nil and d.fuel * 100 < self.settings.fuelReserve) and C.red or nil },
        { "AdBlue", fmtPct(d.def) },
    }
    for i, r in ipairs(left) do row(ctx, i, r[1], r[2], r[3], 0, half) end
    local drive = d.trans == "4x4" and "4x4" or (d.trans ~= nil and "4x2" or "-")
    if d.awd ~= nil then drive = d.awd and "4x4" or "4x2" end
    local function lockTxt(b) if b == nil then return "-" end return b and T("locked") or T("free") end
    local wear = "-"
    if type(d.wear) == "table" then
        local parts = {}
        for _, kk in ipairs({ "fl", "fr", "rl", "rr" }) do
            if d.wear[kk] ~= nil then parts[#parts + 1] = string.format("%d", math.floor(d.wear[kk] * 100 + 0.5)) end
        end
        if #parts > 0 then wear = table.concat(parts, " / ") .. " %" end
    end
    local right = {
        { T("mode"), d.manual == true and T("manual") or T("auto") },
        { T("drive"), drive },
        { T("lockF"), lockTxt(d.lockF), d.lockF and C.amber or nil },
        { T("lockR"), lockTxt(d.lockR), d.lockR and C.amber or nil },
        { T("slip"), d.slip ~= nil and string.format("%d %%", math.floor(d.slip + 0.5)) or "-",
            (d.slip or 0) > 25 and C.red or nil },
        { T("wear"), wear },
        { T("damage"), fmtPct(d.damage) },
        { T("opHours"), string.format("%.1f h", d.opHours or 0) },
    }
    for i, r in ipairs(right) do row(ctx, i, r[1], r[2], r[3], half + 10, half) end
end

-------------------------------------------------------------------------------
-- (31/10 soir) écran d'accueil à la façon du vrai terminal de chaque marque :
--   Fendt (FendtONE) : fond clair, bandeau olive, logo au milieu, 6 cases en 3 x 2, bande d'infos
--   Case IH / New Holland / Steyr (AFS Pro, IntelliView) : fond noir, grille de 4 x 2 cases de valeurs
--   John Deere (CommandCenter G5) : fond sombre, modules, touches de raccourci en bas
--   Deutz-Fahr / Same / Lamborghini (iMonitor) : tableau de bord à gauche, vue principale à droite
--   Claas (CEBIS) / Valtra (SmartTouch) : image de la machine au centre, valeurs autour
--   autres marques : grille, aux couleurs de la marque
-- Image plate de la machine (tracteur, moissonneuse, ensileuse) dessinée par nous d'après l'écran
-- Fendt (tracteur, moissonneuse et ensileuse dessinés) ; voyants des feux verts quand allumés, cliquables.
-------------------------------------------------------------------------------
local RED = { 0.76, 0.08, 0.13, 1 }
local REDL = { 0.95, 0.25, 0.25, 1 }
local GREEN_D = { 0.21, 0.49, 0.17, 1 }
local GREEN_L = { 0.47, 0.69, 0.22, 1 }
local BLUE_NH = { 0.04, 0.30, 0.58, 1 }
local YELLOW_JD = { 1.00, 0.85, 0.20, 1 }
local ORANGE = { 1.00, 0.55, 0.10, 1 }
local YELLOW = { 1.00, 0.70, 0.20, 1 }
local ANTHRA = { 0.16, 0.19, 0.22, 1 }
-- layout : fendt / grid / jd / center ; theme : 1 sombre, 2 clair (thème « Marque » des réglages)
AS_Terminal.BRAND_STYLE = {
    -- (05/11) tracteurs Fendt : son FendtONE (TerminalFendt.lua) ; moissonneuses / ensileuses : ancien écran
    FENDT = { layout = "fendt", theme = 2, hdr = { 0.16, 0.21, 0.17, 1 }, acc = GREEN_L, btn = GREEN_L, fd = true },
    -- (06/11) tracteurs et ensileuses John Deere : son G5 CommandCenter (TerminalJohnDeere.lua) ; moissonneuses : ancien écran
    JOHNDEERE = { layout = "jd", theme = 1, hdr = GREEN_D, acc = YELLOW_JD, jd5 = true },
    -- (01/11) Case IH / Steyr : accueil du terminal AFS Pro 1200 (écran clair, bandeau anthracite, boutons bleus)
    CASEIH = { layout = "case", theme = 2, hdr = { 0.20, 0.22, 0.25, 1 }, acc = BLUE_CASE, btn = BLUE_CASE },
    CASE = { layout = "case", theme = 2, hdr = { 0.20, 0.22, 0.25, 1 }, acc = BLUE_CASE, btn = BLUE_CASE },
    STEYR = { layout = "case", theme = 2, hdr = { 0.20, 0.22, 0.25, 1 }, acc = BLUE_CASE, btn = BLUE_CASE },
    -- (03/11) New Holland IntelliView 12 = même logiciel que l'AFS Pro 1200 : tout comme le Case, sauf l'accueil (l'image)
    NEWHOLLAND = { layout = "case", theme = 2, hdr = { 0.20, 0.22, 0.25, 1 }, acc = BLUE_NH, btn = BLUE_NH, nh = true },
    LANDINI = { layout = "grid", theme = 1, hdr = BLUE_NH, acc = { 0.35, 0.60, 1.00, 1 } },
    -- (04/11) tracteurs Claas : terminal CEBIS + CEMIS (claasScreenFor) ; moissonneuses : ancien écran
    CLAAS = { layout = "center", theme = 2, hdr = ANTHRA, acc = { 0.70, 0.78, 0.09, 1 }, btn = GREEN_D, claas = true },
    VALTRA = { layout = "center", theme = 1, hdr = RED, acc = REDL },
    -- (04/11) tracteurs Massey Ferguson : son Datatronic 5 bleu (TerminalMassey.lua) ; autres machines : ancien écran
    MASSEYFERGUSON = { layout = "grid", theme = 1, hdr = RED, acc = REDL, mf = true },
    MCCORMICK = { layout = "grid", theme = 1, hdr = RED, acc = REDL },
    ZETOR = { layout = "grid", theme = 1, hdr = RED, acc = REDL },
    MAHINDRA = { layout = "grid", theme = 1, hdr = RED, acc = REDL },
    VERSATILE = { layout = "grid", theme = 1, hdr = RED, acc = REDL },
    -- (06/11) tracteurs Deutz-Fahr / Same / Lamborghini : iMonitor SDF (TerminalDeutz.lua) ; autres machines : ancien écran
    DEUTZFAHR = { layout = "df", theme = 1, hdr = GREEN_D, acc = GREEN_L, df = true },
    SAME = { layout = "df", theme = 1, hdr = GREEN_D, acc = GREEN_L, df = true },
    LAMBORGHINI = { layout = "df", theme = 1, hdr = ANTHRA, acc = GREEN_L, df = true },
    KRONE = { layout = "grid", theme = 1, hdr = GREEN_D, acc = GREEN_L },
    LINDNER = { layout = "grid", theme = 1, hdr = GREEN_D, acc = GREEN_L },
    KUBOTA = { layout = "grid", theme = 1, hdr = ORANGE, acc = ORANGE },
    KIOTI = { layout = "grid", theme = 1, hdr = ORANGE, acc = ORANGE },
    JCB = { layout = "grid", theme = 1, hdr = YELLOW, acc = YELLOW, darkText = true },
    CHALLENGER = { layout = "grid", theme = 1, hdr = YELLOW, acc = YELLOW, darkText = true },
}
AS_Terminal.DEFAULT_STYLE = { layout = "fendt", theme = nil, hdr = nil, acc = nil }

local function brandName(v)
    if g_brandManager == nil or v == nil then return nil end
    local idx = call(v, "getBrand")
    local b = nil
    if idx ~= nil then
        local ok, bb = pcall(g_brandManager.getBrandByIndex, g_brandManager, idx)
        if ok then b = bb end
    end
    if b == nil then b = v.brand end
    if type(b) ~= "table" or type(b.name) ~= "string" then return nil end
    return (b.name:upper():gsub("[^%w]", ""))
end
AS_Terminal.brandName = function(_, v) return brandName(v) end

function AS_Terminal:brandStyle(v)
    local n = brandName(v)
    local st = n ~= nil and self.BRAND_STYLE[n] or nil
    if st == nil then
        return { layout = "fendt", theme = nil, hdr = C.green, acc = C.green, name = n }
    end
    return st
end

-- image plate de la machine et position de ses voyants (fractions de l'image 512 x 256)
AS_Terminal.VEH_IMAGES = {
    tracteur = { file = "objects/terminal/as_veh_tracteur.dds", node = "imgTracteur", lamps = { { "high", 0.2183, 0.4379 }, { "drive", 0.2674, 0.5421 }, { "workF", 0.5104, 0.1140 }, { "workF", 0.5017, 0.2933 }, { "beacon", 0.6232, 0.0828 }, { "workR", 0.7389, 0.1140 }, { "workR", 0.7967, 0.4669 } } },
    moissonneuse = { file = "objects/terminal/as_veh_moissonneuse.dds", node = "imgMoissonneuse", lamps = { { "workF", 0.1532, 0.2580 }, { "workF", 0.2295, 0.2467 }, { "beacon", 0.3116, 0.2184 }, { "high", 0.1928, 0.3995 }, { "drive", 0.1815, 0.5579 }, { "workR", 0.8519, 0.3542 }, { "workR", 0.8830, 0.7050 } },
        -- zones transparentes du dessin (fractions x0, y0, x1, y1) : la couleur derrière montre l'état
        parts = { tank = { 0.3710, 0.2083, 0.4559, 0.3124 }, drums = { 0.3037, 0.4753, 0.4644, 0.6552 },
            box = { 0.4728, 0.3610, 0.8293, 0.5670 }, fan = { 0.3840, 0.6575, 0.7014, 0.7865 },
            swath = { 0.7987, 0.5704, 0.8389, 0.6530 } } },
    ensileuse = { file = "objects/terminal/as_veh_ensileuse.dds", node = "imgEnsileuse", lamps = { { "workF", 0.2407, 0.2063 }, { "workF", 0.3081, 0.1924 }, { "beacon", 0.3693, 0.1247 }, { "high", 0.2673, 0.3655 }, { "drive", 0.2713, 0.4798 }, { "workR", 0.6919, 0.3247 }, { "workR", 0.7123, 0.5452 }, { "i_header", 0.1338, 0.8594 }, { "i_rollers", 0.2803, 0.8594 }, { "i_cutter", 0.4268, 0.8594 }, { "i_cracker", 0.5732, 0.8594 }, { "i_blower", 0.7197, 0.8594 }, { "i_spout", 0.8662, 0.8594 } } },
}
-- (31/10 soir) catégorie du magasin : l'image du tracteur seulement pour les tracteurs (pas d'image sur un
-- automoteur, un télescopique, une chargeuse… tant que ces types n'ont pas leur dessin)
local function storeCat(v)
    if g_storeManager == nil or v.configFileName == nil then return "" end
    local ok, item = pcall(g_storeManager.getItemByXMLFilename, g_storeManager, v.configFileName)
    if ok and item ~= nil and item.categoryName ~= nil then return tostring(item.categoryName):lower() end
    return ""
end
local function vehImageKind(v, d)
    local m = d.mach
    if m ~= nil and m.obj == v then
        if m.kind == "forage" then return "ensileuse" end
        if m.kind == "combine" then return "moissonneuse" end
        if m.kind == "root" then return nil end
    end
    if v.spec_combine ~= nil then return "moissonneuse" end
    local cat = storeCat(v)
    if cat:find("tractor", 1, true) then return "tracteur" end
    if cat == "" and tostring(v.typeName or ""):lower():find("tractor", 1, true) then return "tracteur" end
    return nil
end
AS_Terminal.vehImageKind = function(_, v, d) return vehImageKind(v, d) end

function AS_Terminal:vehOverlay(kind)
    self.vehOvs = self.vehOvs or {}
    local ov = self.vehOvs[kind]
    if ov == nil then
        ov = false
        local img = kind ~= nil and self.VEH_IMAGES[kind] or nil
        if img ~= nil and createImageOverlay ~= nil and AS_MOD_DIR ~= nil then
            local ok, o = pcall(createImageOverlay, Utils.getFilename(img.file, AS_MOD_DIR))
            if ok and o ~= nil and o ~= 0 then
                ov = o
                pcall(setOverlayColor, o, 1, 1, 1, 1)
            else
                log("image %s introuvable", img.file)
            end
        end
        self.vehOvs[kind] = ov
    end
    return ov or nil
end

-- feux : bit du type de feu du jeu (0 route, 1 travail arrière, 2 travail avant, 3 pleins phares)
local LIGHT_BIT = { drive = 0, workR = 1, workF = 2, high = 3 }
local function lightOn(d, what)
    local l = d.lights
    if l == nil then return false end
    if what == "beacon" then return l.beacon == true end
    if what == "hazard" then return Lights ~= nil and Lights.TURNLIGHT_HAZARD ~= nil and l.turn == Lights.TURNLIGHT_HAZARD end
    local b = LIGHT_BIT[what]
    return b ~= nil and math.floor((l.mask or 0) / 2 ^ b) % 2 == 1
end
AS_Terminal.lightOn = function(_, d, what) return lightOn(d, what) end

local function cut(s, n)
    s = tostring(s or "")
    local len = utf8Strlen ~= nil and utf8Strlen(s) or #s
    if len <= n then return s end
    if utf8Substr ~= nil then return utf8Substr(s, 0, n - 1) .. "." end
    return s:sub(1, n - 1) .. "."
end

-- cases (« widgets ») communes aux mises en page -----------------------------
local W = {}
function W.tile(ctx, x0, y0, w, h, title, action)
    if action ~= nil then ctx.button(x0, y0, w, h, action, false) else ctx.rect(x0, y0, w, h, C.box) end
    if title ~= nil then
        ctx.rect(x0 + 8, y0 + 7, 4, 13, ctx.acc)
        ctx.text(x0 + 18, y0 + 18, 12, title, C.gray, nil, true)
    end
end

function W.hitch(ctx, d, x0, y0, w, h, front)
    local pick
    for _, hh in ipairs(d.hitches or {}) do
        if hh.front == front then
            if front then
                if pick == nil or (hh.own ~= nil and pick.object == nil) then pick = hh end
            elseif pick == nil or (hh.own ~= nil and pick.own == nil) then pick = hh end
        end
    end
    -- (31/10 soir) moissonneuse / ensileuse : COUPE (ou BEC, PICK-UP) devant, RÉCOLTE derrière, au lieu des relevages
    -- inutiles ; automoteur (pulvé, épandeur) sans relevage de ce côté : rampe devant, cuve derrière
    local m = d.mach
    if m ~= nil and ctx.v ~= nil and m.obj == ctx.v then
        if m.kind == "combine" or m.kind == "forage" or m.kind == "root" then
            if front then return W.header(ctx, d, m, x0, y0, w, h) end
            return W.harvest(ctx, d, m, x0, y0, w, h)
        end
        if m.kind == "spreader" and pick == nil then
            if front then return W.boom(ctx, d, m, x0, y0, w, h) end
            return W.tank(ctx, d, m, x0, y0, w, h)
        end
    end
    local label = front and T("hitchF") or T("hitchR")
    W.tile(ctx, x0, y0, w, h, label, pick ~= nil and pick.object ~= nil and (front and "hitch_f" or "hitch_r") or nil)
    if pick == nil then
        ctx.text(x0 + w * 0.5, y0 + h * 0.5 + 10, 15, T("empty"), C.dim, RenderText.ALIGN_CENTER, true)
        return
    end
    ctx.text(x0 + w - 10, y0 + 18, 12, pick.moveDown and T("lowered") or T("raised"),
        pick.moveDown and C.lamp or C.white, RenderText.ALIGN_RIGHT, true)
    local f = clamp(pick.up or 0, 0, 1)
    -- jauge verticale de hauteur (comme le cadran du FendtONE : 0 en bas)
    local gx, gy, gh = x0 + 14, y0 + 30, h - 42
    ctx.rect(gx, gy, 20, gh, C.screen)
    if f > 0 then ctx.rect(gx, gy + gh * (1 - f), 20, gh * f, ctx.acc) end
    local tx = x0 + 46
    ctx.text(tx, y0 + 64, 26, string.format("%d %%", math.floor(f * 100 + 0.5)), C.white, nil, true)
    ctx.text(tx, y0 + 80, 10, pick.own == "pickup" and T("hitchPickup") or (pick.own ~= nil and T("hitchTool") or T("height")), C.gray)
    if pick.object ~= nil then
        local n = math.max(8, math.floor((w - 56) / 7.5))
        ctx.text(tx, y0 + 104, 12, cut(vehicleName(pick.object), n), C.white, nil, true)
        local on = isTurnedOn(pick.object)
        if on ~= nil then
            ctx.rect(tx, y0 + 115, 8, 8, on and C.lamp or C.dim)
            ctx.text(tx + 14, y0 + 124, 11, on and T("on") or T("off"), on and C.white or C.gray)
        end
        if h >= 150 then ctx.text(tx, y0 + h - 10, 10, pick.moveDown and T("doRaise") or T("doLower"), C.dim) end
    end
end

local function line(ctx, x0, yy, w, label, value, col)
    ctx.text(x0 + 12, yy, 11, label, C.gray)
    ctx.text(x0 + w - 12, yy, 12, value, col or C.white, RenderText.ALIGN_RIGHT, true)
end

-- (31/10 soir) coupe / bec / pick-up de la moissonneuse ou de l'ensileuse
function W.header(ctx, d, m, x0, y0, w, h)
    local hd = m.header
    local title = T("h_cut")
    if m.kind == "forage" then title = (m.rh ~= nil and m.rh.pickup) and T("h_pickup") or T("h_bec") end
    W.tile(ctx, x0, y0, w, h, title, hd ~= nil and "lift" or nil)
    if hd == nil then
        ctx.text(x0 + w * 0.5, y0 + h * 0.5 + 10, 13, T("noHeader"), C.dim, RenderText.ALIGN_CENTER, true)
        return
    end
    if hd.lowered ~= nil then
        ctx.text(x0 + w - 10, y0 + 18, 12, hd.lowered and T("lowered") or T("raised"), hd.lowered and C.lamp or C.white, RenderText.ALIGN_RIGHT, true)
    end
    ctx.text(x0 + 12, y0 + 46, 13, cut(hd.name, math.max(8, math.floor((w - 24) / 7.5))), C.white, nil, true)
    if hd.width ~= nil and hd.width > 0 then
        ctx.text(x0 + 12, y0 + 76, 24, string.format("%.1f m", hd.width), C.white, nil, true)
    end
    local on = hd.on
    if on ~= nil then
        ctx.rect(x0 + 12, y0 + 92, 8, 8, on and C.lamp or C.dim)
        ctx.text(x0 + 26, y0 + 101, 11, on and T("on") or T("off"), on and C.white or C.gray)
    end
    if h >= 150 then ctx.text(x0 + 12, y0 + h - 10, 10, hd.lowered and T("doRaise") or T("doLower"), C.dim) end
end

-- (31/10 soir) récolte : trémie (moissonneuse) ou remorque d'à côté (ensileuse), débit, rendement, pertes
function W.harvest(ctx, d, m, x0, y0, w, h)
    W.tile(ctx, x0, y0, w, h, T("h_harvest"), "page_tool")
    local yy = y0 + 40
    local f, lbl
    if m.tank ~= nil and m.tank.cap > 0 then
        f, lbl = m.tank.level / m.tank.cap, T("m_grainTank")
    elseif m.target ~= nil and m.target.cap ~= nil and m.target.cap > 0 then
        f, lbl = m.target.level / m.target.cap, T("m_trailer")
    end
    if f ~= nil then
        f = clamp(f, 0, 1)
        local col = f >= 0.95 and C.red or (f >= 0.8 and C.amber or C.lamp)
        ctx.text(x0 + 12, yy, 11, lbl, C.gray)
        ctx.text(x0 + w - 12, yy + 4, 22, string.format("%d %%", math.floor(f * 100 + 0.5)), col, RenderText.ALIGN_RIGHT, true)
        bar(ctx, x0 + 12, yy + 10, w - 24 - 70, 6, f, col)
        if m.tank ~= nil and m.tph ~= nil and m.tank.level > 0 and m.lph ~= nil and m.lph > 0 then
            ctx.text(x0 + 12, yy + 28, 10, string.format("%.1f t", m.tank.level * (m.tph / m.lph)), C.white, nil, true)
        end
        yy = yy + 44
    else
        ctx.text(x0 + 12, yy, 12, T("m_noTarget"), C.dim)
        yy = yy + 24
    end
    local r = m.rh
    local tph = (r ~= nil and r.tph) or m.tph
    if tph ~= nil and tph > 0 and yy < y0 + h - 8 then line(ctx, x0, yy, w, T("m_tph"), string.format("%.1f t/h", tph)); yy = yy + 18 end
    if r ~= nil and r.yield ~= nil and r.yield > 0 and yy < y0 + h - 8 then line(ctx, x0, yy, w, T("m_yield"), string.format("%.1f t/ha", r.yield)); yy = yy + 18 end
    if m.minToFull ~= nil and m.minToFull > 0 and m.minToFull < 600 and yy < y0 + h - 8 then
        line(ctx, x0, yy, w, T("m_toFull"), string.format("%d min", math.floor(m.minToFull + 0.5)), m.minToFull < 3 and C.amber or C.white); yy = yy + 18
    end
    if r ~= nil and r.loss ~= nil and yy < y0 + h - 8 then
        line(ctx, x0, yy, w, T("m_loss"), string.format("%.1f %%", r.loss), r.loss > 3 and C.amber or C.white); yy = yy + 18
    end
end

-- (31/10 soir) automoteur : rampe (largeur, en travail) et cuve (niveau, dose, surface restante)
function W.boom(ctx, d, m, x0, y0, w, h)
    W.tile(ctx, x0, y0, w, h, T("h_boom"), "page_tool")
    if m.lowered ~= nil then
        ctx.text(x0 + w - 10, y0 + 18, 12, m.lowered and T("lowered") or T("raised"), m.lowered and C.lamp or C.white, RenderText.ALIGN_RIGHT, true)
    end
    if m.width ~= nil and m.width > 0 then ctx.text(x0 + 12, y0 + 64, 26, string.format("%.0f m", m.width), C.white, nil, true) end
    if m.on ~= nil then
        ctx.rect(x0 + 12, y0 + 82, 8, 8, m.on and C.lamp or C.dim)
        ctx.text(x0 + 26, y0 + 91, 11, m.on and T("on") or T("off"), m.on and C.white or C.gray)
    end
end
function W.tank(ctx, d, m, x0, y0, w, h)
    W.tile(ctx, x0, y0, w, h, T("h_tank"), "page_tool")
    local fl = m.fill
    if fl == nil then ctx.text(x0 + w * 0.5, y0 + h * 0.5 + 10, 13, "-", C.dim, RenderText.ALIGN_CENTER, true) return end
    local f = clamp(fl.cap > 0 and fl.level / fl.cap or 0, 0, 1)
    local col = f <= 0.1 and C.red or (f <= 0.25 and C.amber or C.lamp)
    ctx.text(x0 + 12, y0 + 40, 11, cut(fl.title or "", math.floor((w - 90) / 6.5)), C.gray)
    ctx.text(x0 + w - 12, y0 + 44, 22, string.format("%d %%", math.floor(f * 100 + 0.5)), col, RenderText.ALIGN_RIGHT, true)
    bar(ctx, x0 + 12, y0 + 50, w - 24 - 70, 6, f, col)
    local yy = y0 + 84
    if m.doseKg ~= nil then line(ctx, x0, yy, w, T("m_dose"), string.format("%.0f kg/ha", m.doseKg)); yy = yy + 18
    elseif m.dose ~= nil then line(ctx, x0, yy, w, T("m_dose"), string.format("%.0f l/ha", m.dose)); yy = yy + 18 end
    if m.haLeft ~= nil and yy < y0 + h - 8 then line(ctx, x0, yy, w, T("m_haLeft"), string.format("%.1f ha", m.haLeft)) end
end

-- cadran de vitesse en segments (carrés : marche aussi sur l'écran 3D)
function W.dial(ctx, d, cx, cy, R)
    local maxV = d.maxSpeed or 50
    local spd = math.abs(d.speed or 0)
    local frac = clamp(spd / math.max(1, maxV), 0, 1)
    local N = R >= 60 and 31 or 25
    local sq = R >= 60 and 8 or 7
    for i = 0, N - 1 do
        local a = math.rad(135 + 270 * i / (N - 1))
        local lit = (i + 0.5) / N <= frac and spd > 0.5
        ctx.rect(cx + R * math.cos(a) - sq * 0.5, cy + R * math.sin(a) - sq * 0.5, sq, sq, lit and ctx.acc or C.boxHi)
    end
    ctx.text(cx, cy + 9, R >= 60 and 32 or 26, string.format("%d", math.floor(spd + 0.5)), C.white, RenderText.ALIGN_CENTER, true)
    ctx.text(cx, cy + 25, 10, "km/h", C.gray, RenderText.ALIGN_CENTER)
    local gear = tostring(d.gear or "N")
    if d.group ~= nil and not d.cvt then gear = tostring(d.group) .. " " .. gear end
    if d.cvt then gear = (d.dir or 0) < 0 and "R" or ((d.dir or 0) > 0 and "D" or "N") end
    ctx.text(cx, cy + R + 4, 13, (d.cvt and "CVT  " or "") .. gear, C.white, RenderText.ALIGN_CENTER, true)
end

function W.gauges(ctx, d, rx, y0, rw, n, self)
    local fuelLow = d.fuel ~= nil and d.fuel * 100 < self.settings.fuelReserve
    local cruise = (d.cruise ~= nil and d.cruise ~= 0) and string.format("%d km/h", math.floor((d.cruiseSpeed or 0) + 0.5)) or T("off")
    local list = {
        { T("rpm"), d.rpm ~= nil and string.format("%d", math.floor(d.rpm + 0.5)) or "-",
            (d.rpm ~= nil and d.maxRpm ~= nil and d.maxRpm > 0) and d.rpm / d.maxRpm or 0 },
        { T("loadP"), d.load ~= nil and fmtPct(d.load) or "-", d.load or 0 },
        { T("fuel"), fmtPct(d.fuel), d.fuel or 0, fuelLow and C.red or nil },
        { "AdBlue", fmtPct(d.def), d.def or 0 },
        { T("cruise"), cruise, nil },
    }
    for i, g in ipairs(list) do
        if i > (n or 5) then break end
        local yy = y0 + (i - 1) * 27
        ctx.text(rx, yy + 10, 10, g[1], C.gray)
        ctx.text(rx + rw, yy + 10, 12, g[2], g[4] or C.white, RenderText.ALIGN_RIGHT, true)
        bar(ctx, rx, yy + 14, rw, 6, g[3], g[4] or ctx.acc)
    end
end

-- (01/11) case moteur à toutes les tailles : cadran + jauges côte à côte (large), l'un sur l'autre (haute),
-- jauges seules (étroite)
function W.engine(ctx, d, x0, y0, w, h, self)
    W.tile(ctx, x0, y0, w, h, T("h_engine"), "page_tractor")
    if w >= 250 and h >= 140 then
        local dy = h >= 250 and math.floor((h - 160) * 0.5) or 0
        W.dial(ctx, d, x0 + 76, y0 + 90 + dy, 50)
        W.gauges(ctx, d, x0 + 150, y0 + 26 + dy, w - 160, 5, self)
    elseif h >= 300 then
        W.dial(ctx, d, x0 + w * 0.5, y0 + 86, 50)
        W.gauges(ctx, d, x0 + 12, y0 + 180, w - 24, 5, self)
    else
        W.gauges(ctx, d, x0 + 12, y0 + 26, w - 24, h >= 150 and 5 or math.max(1, math.floor((h - 30) / 27)), self)
    end
end

-- éclairage : image plate de la machine (2:1), voyants verts quand allumés, cliquables
-- (31/10 soir) icônes de fonctions de l'ensileuse (sous la machine) : une seule mise en marche
-- (le battage), sauf le bec (sa propre marche) et la goulotte (sortie) ; rouge = panne ADS
local ICON_ACTION = { i_header = "on", i_rollers = "on", i_cutter = "on", i_cracker = "on", i_blower = "on", i_spout = "pipe" }
local function faultCol(l, base)
    if l == 2 then return C.red end
    if l == 1 then return C.amber end
    return base
end
local function iconCol(d, name, OFF)
    local m = d.mach
    if m == nil then return OFF end
    local a = m.ads or {}
    if name == "i_header" then return (m.header ~= nil and m.header.on) and C.lamp or OFF end
    if name == "i_spout" then return faultCol(a.discharge == 2 and 2 or nil, m.pipe and C.lamp or OFF) end
    if name == "i_blower" then return faultCol(a.discharge, m.on and C.lamp or OFF) end
    return faultCol(a.chop, m.on and C.lamp or OFF)
end

function W.lights(ctx, d, v, x0, y0, w, h, self, noTitle)
    local kind = vehImageKind(v, d)
    W.tile(ctx, x0, y0, w, h, not noTitle and ((kind == "tracteur" or kind == nil) and T("h_light") or T("h_machine")) or nil, nil)
    local img = kind ~= nil and self.VEH_IMAGES[kind] or nil
    local top = noTitle and 8 or 22
    if img == nil then
        -- (31/10 soir) pas de dessin pour ce type de véhicule : les feux en boutons (vert = allumé)
        local L = { { "drive", T("l_drive") }, { "high", T("l_high") }, { "workF", T("l_workF") },
            { "workR", T("l_workR") }, { "beacon", T("l_beacon") }, { "hazard", T("l_hazard") } }
        local cols = w >= 300 and 3 or 2
        local rowsN = math.ceil(#L / cols)
        local bw = (w - 16 - (cols - 1) * 6) / cols
        local bh = math.max(18, math.min(34, (h - top - 10 - (rowsN - 1) * 6) / rowsN))
        for i, l in ipairs(L) do
            local bx = x0 + 8 + ((i - 1) % cols) * (bw + 6)
            local byy = y0 + top + 4 + math.floor((i - 1) / cols) * (bh + 6)
            local on = lightOn(d, l[1])
            ctx.button(bx, byy, bw, bh, "l_" .. l[1], false)
            ctx.rect(bx + 6, byy + bh * 0.5 - 4, 8, 8, on and C.lamp or C.dim)
            ctx.text(bx + bw * 0.5 + 6, byy + bh * 0.5 + 5, 11, cut(l[2], math.floor((bw - 22) / 6.5)), on and C.lamp or C.white, RenderText.ALIGN_CENTER, true)
        end
        return x0 + 4, y0 + top, w - 8, h - top - 4
    end
    local iw = math.min(w - 16, (h - top - 4) * 2)
    local ih = iw / 2
    local iu, iv = x0 + (w - iw) * 0.5, y0 + top + (h - top - 4 - ih) * 0.5
    local R0 = 17 / 512 * iw                 -- rayon de la bulle d'un voyant
    local ri = R0 / 1.42                     -- carré de couleur : tient dans le trou de la bulle
    local OFF = { 0.93, 0.94, 0.95, 1 }
    local m = d.mach
    for _, l in ipairs(img.lamps) do
        local lu, lv = iu + l[2] * iw, iv + l[3] * ih
        local col
        if l[1]:sub(1, 2) == "i_" then col = iconCol(d, l[1], OFF) else col = lightOn(d, l[1]) and C.lamp or OFF end
        -- croix épaisse plutôt qu'un carré : remplit le trou rond sans dépasser de l'anneau blanc
        ctx.rect(lu - ri, lv - ri * 0.71, ri * 2, ri * 1.42, col)
        ctx.rect(lu - ri * 0.71, lv - ri, ri * 1.42, ri * 2, col)
    end
    -- moissonneuse : batteurs, secoueurs, soufflerie (une seule mise en marche), andain ; rouge = panne ADS
    local P = img.parts
    local function zone(z, col)
        if z == nil or col == nil then return end
        ctx.rect(iu + z[1] * iw, iv + z[2] * ih, (z[3] - z[1]) * iw, (z[4] - z[2]) * ih, col)
    end
    if P ~= nil and m ~= nil then
        local a = m.ads or {}
        local run = m.on and C.lamp or nil
        zone(P.drums, faultCol(a.thresh, run))
        zone(P.box, faultCol(a.thresh, run))
        local fanOn = m.on
        if m.rh ~= nil and type(m.rh.settings) == "table" and type(m.rh.settings.fan) == "number" then fanOn = m.on and m.rh.settings.fan > 0 end
        zone(P.fan, faultCol(a.thresh, fanOn and C.lamp or nil))
        if m.swath then zone(P.swath, C.lamp) end
    end
    ctx.image(iu, iv, iw, ih, ctx.rec == nil and self:vehOverlay(kind) or nil, img.node)
    for _, l in ipairs(img.lamps) do
        local lu, lv = iu + l[2] * iw, iv + l[3] * ih
        local act = l[1]:sub(1, 2) == "i_" and ICON_ACTION[l[1]] or ("l_" .. l[1])
        ctx.hotspot(lu - R0, lv - R0, R0 * 2, R0 * 2, act)
        -- nom de la fonction sous l'icône (image assez grande)
        if l[1]:sub(1, 2) == "i_" and iw >= 300 then
            ctx.text(lu, lv + R0 + 9, 8, T("ic_" .. l[1]:sub(3)), C.gray, RenderText.ALIGN_CENTER, true)
        end
    end
    if P ~= nil and m ~= nil then
        -- trémie : le cadre se remplit, % écrit dedans
        if m.tank ~= nil and P.tank ~= nil then
            local z = P.tank
            local tu, tv, tw, th = iu + z[1] * iw, iv + z[2] * ih, (z[3] - z[1]) * iw, (z[4] - z[2]) * ih
            local f = clamp(m.tank.cap > 0 and m.tank.level / m.tank.cap or 0, 0, 1)
            ctx.rect(tu, tv, tw, th, C.screen)
            if f > 0 then ctx.rect(tu, tv + th * (1 - f), tw, th * f, f >= 0.95 and C.red or (f >= 0.8 and C.amber or C.lamp)) end
            ctx.text(tu + tw * 0.5, tv + th * 0.5 + 4, math.max(8, math.min(13, th * 0.45)), string.format("%d %%", math.floor(f * 100 + 0.5)),
                C.white, RenderText.ALIGN_CENTER, true)
            ctx.hotspot(tu, tv, tw, th, "page_tool")
        end
        -- andain / broyeur : écrit à côté de la croix, clic = bascule
        if P.swath ~= nil and m.swath ~= nil then
            local z = P.swath
            local su, sv, sw, sh = iu + z[1] * iw, iv + z[2] * ih, (z[3] - z[1]) * iw, (z[4] - z[2]) * ih
            local lab, lc = m.swath and T("m_swathOn") or T("m_chopOn"), m.swath and C.lamp or C.gray
            if not noTitle then
                -- dans la barre de titre de la tuile (à droite), lisible même sur une petite image
                ctx.text(x0 + w - 10, y0 + 18, 11, lab, lc, RenderText.ALIGN_RIGHT, true)
                if m.canSwath then ctx.hotspot(x0 + w - 90, y0 + 4, 86, 18, "m_swath") end
            else
                -- grande image : à gauche de la croix, entre secoueurs et soufflerie
                ctx.text(su - 4, sv + sh * 0.5 + 4, 9, lab, lc, RenderText.ALIGN_RIGHT, true)
            end
            if m.canSwath then ctx.hotspot(su - 4, sv - 4, sw + 8, sh + 8, "m_swath") end
        end
        -- batteurs et soufflerie : clic = marche / arrêt du battage ; réglages de Realistic Harvesting écrits
        if P.drums ~= nil then
            local z = P.drums
            ctx.hotspot(iu + z[1] * iw, iv + z[2] * ih, (z[3] - z[1]) * iw, (z[4] - z[2]) * ih, "on")
        end
        local st = m.rh ~= nil and m.rh.settings or nil
        if type(st) == "table" and iw >= 250 then
            if type(st.fan) == "number" and P.fan ~= nil then
                ctx.text(iu + (P.fan[1] + P.fan[3]) * 0.5 * iw, iv + P.fan[4] * ih + 9, 8,
                    string.format("%s %d", T("m_fanShort"), math.floor(st.fan + 0.5)), C.white, RenderText.ALIGN_CENTER, true)
            end
            if type(st.rotor) == "number" and P.drums ~= nil then
                ctx.text(iu + (P.drums[1] + P.drums[3]) * 0.5 * iw, iv + P.drums[2] * ih - 3, 8,
                    string.format("%s %d", T("m_rotorShort"), math.floor(st.rotor + 0.5)), C.white, RenderText.ALIGN_CENTER, true)
            end
        end
    end
    return iu, iv, iw, ih
end

function W.tools(ctx, d, x0, y0, w, h)
    W.tile(ctx, x0, y0, w, h, T("h_tools"), "page_tool")
    if #d.tools == 0 then
        ctx.text(x0 + w * 0.5, y0 + h * 0.5 + 10, 14, T("noTool"), C.dim, RenderText.ALIGN_CENTER, true)
        return
    end
    local n = math.max(1, math.floor((h - 26) / 44))
    for i, t in ipairs(d.tools) do
        if i > n then break end
        local yy = y0 + 26 + (i - 1) * 44
        -- (01/11) petite image du magasin de l'outil, barre verte s'il travaille
        local tx0 = x0 + 10
        if t.img ~= nil and AS_TerminalTools ~= nil then
            ctx.image(x0 + 8, yy - 2, 40, 40, ctx.rec == nil and AS_TerminalTools:overlay(t.img) or nil, "imgAccOutil" .. i, t.img)
            tx0 = x0 + 52
        end
        if t.working then ctx.rect(x0 + 2, yy, 3, 36, C.lamp) end
        local x0s = x0
        x0 = tx0 - 10
        w = w - (tx0 - x0s - 10)
        ctx.text(x0 + 10, yy + 12, 12, cut(t.name, math.floor((w - 20) / 7.5)), C.white, nil, true)
        local sts = {}
        if t.lowered ~= nil then sts[#sts + 1] = { t.lowered and T("lowered") or T("raised"), t.lowered } end
        if t.on ~= nil then sts[#sts + 1] = { t.on and T("on") or T("off"), t.on } end
        if t.unfolded ~= nil then sts[#sts + 1] = { t.unfolded and T("unfolded") or T("folded"), t.unfolded } end
        local sw = math.min(90, (w - 20) / math.max(1, #sts))
        for j, s in ipairs(sts) do
            local sxu = x0 + 10 + (j - 1) * sw
            ctx.rect(sxu, yy + 18, 7, 7, s[2] and C.lamp or C.dim)
            ctx.text(sxu + 11, yy + 26, 10, cut(s[1], math.floor((sw - 14) / 6)), s[2] and C.white or C.gray)
        end
        local f = t.fills[1]
        if f ~= nil then bar(ctx, x0 + 10, yy + 31, w - 20, 5, f.cap > 0 and f.level / f.cap or 0, C.amber) end
        w = w + (x0 - x0s)
        x0 = x0s
    end
end



local function quickList(d)
    return {
        { "diffMode", d.manual == true and T("manual") or T("auto"), d.manual == true },
        { "guide", d.guide ~= nil and T("g_" .. d.guide) or T("b_guide"), d.guide ~= nil },
        { "stop", T("b_stop"), false },
        { "lift", T("b_lift"), d.anyLowered == true },
        { "on", T("b_on"), d.anyOn == true },
        { "l_hazard", T("l_hazard"), lightOn(d, "hazard") },
    }
end

local function chips(ctx, d, x0, yy, step)
    local drive = d.trans == "4x4" and "4x4" or (d.trans ~= nil and "4x2" or nil)
    if d.awd ~= nil then drive = d.awd and "4x4" or "4x2" end
    local list = { { drive or "-", drive == "4x4" }, { T("lockF"), d.lockF == true }, { T("lockR"), d.lockR == true } }
    for i, c in ipairs(list) do
        local cxu = x0 + (i - 1) * step
        ctx.rect(cxu, yy, 8, 8, c[2] and C.lamp or C.dim)
        ctx.text(cxu + 12, yy + 9, 10, c[1], c[2] and C.white or C.gray, nil, nil, step - 16)
    end
end

function W.quick(ctx, d, x0, y0, w, h, cols)
    W.tile(ctx, x0, y0, w, h, T("h_quick"), nil)
    cols = cols or 3
    local q = quickList(d)
    local rowsN = math.ceil(#q / cols)
    local bw = (w - 16 - (cols - 1) * 6) / cols
    local bh = math.min(36, (h - 26 - 30 - (rowsN - 1) * 6) / rowsN)
    for i, b in ipairs(q) do
        local bx = x0 + 8 + ((i - 1) % cols) * (bw + 6)
        local byy = y0 + 26 + math.floor((i - 1) / cols) * (bh + 6)
        ctx.button(bx, byy, bw, bh, b[1], b[3])
        ctx.text(bx + bw * 0.5, byy + bh * 0.5 + 5, 11, cut(b[2], math.floor(bw / 7)), C.white, RenderText.ALIGN_CENTER, true)
    end
    chips(ctx, d, x0 + 10, y0 + h - 22, (w - 20) / 3)
end

-- valeur seule, en grand (cases des grilles Case IH / New Holland)
function W.value(ctx, x0, y0, w, h, title, value, unit, frac, col)
    W.tile(ctx, x0, y0, w, h, title, nil)
    ctx.text(x0 + w * 0.5, y0 + h * 0.5 + 12, 30, value, col or C.white, RenderText.ALIGN_CENTER, true)
    if unit ~= nil then ctx.text(x0 + w * 0.5, y0 + h * 0.5 + 30, 11, unit, C.gray, RenderText.ALIGN_CENTER) end
    if frac ~= nil then bar(ctx, x0 + 12, y0 + h - 16, w - 24, 6, frac, col or ctx.acc) end
end

function W.info(ctx, d, x0, y0, w)
    local job = d.cnt.jobs[d.cnt.active]
    ctx.rect(x0, y0, w, 24, C.box)
    local info = {
        d.field ~= nil and string.format(T("field"), d.field) or (T("loc") .. " -"),
        string.format("%.2f ha", job.ha),
        string.format("%s l/h", fmt1(d.fuelUse)),
        string.format("%s %s h", T("hours"), fmtHM(job.ms)),
        string.format("%s %.1f h", T("opHours"), d.opHours or 0),
    }
    for i, s in ipairs(info) do
        ctx.text(x0 + (i - 0.5) * w / #info, y0 + 17, 11, s, C.white, RenderText.ALIGN_CENTER, true, w / #info - 6)
    end
end

-- (01/11) Claas CEBIS / Valtra SmartTouch : la machine au centre, accès rapide et premier outil dessous
function W.center(ctx, d, v, x0, y0, w, h, self)
    ctx.rect(x0, y0, w, h, C.box)
    local imgH = math.max(80, h - 88)
    W.lights(ctx, d, v, x0 + 4, y0 + 4, w - 8, imgH, self, true)
    local q = quickList(d)
    local bw = (w - 8 - 5 * 4) / 6
    local by = y0 + imgH + 10
    for i, b in ipairs(q) do
        local bx = x0 + 4 + (i - 1) * (bw + 4)
        ctx.button(bx, by, bw, 34, b[1], b[3])
        ctx.text(bx + bw * 0.5, by + 22, 10, cut(b[2], math.floor(bw / 6.5)), C.white, RenderText.ALIGN_CENTER, true)
    end
    local ty = by + 56
    local t = d.tools[1]
    ctx.text(x0 + 12, ty, 12, t ~= nil and cut(t.name, math.floor((w - 180) / 7.5)) or T("noTool"), t ~= nil and C.white or C.dim, nil, true)
    if t ~= nil then
        ctx.hotspot(x0 + 4, ty - 16, w - 8, 34, "page_tool")
        local f = t.fills[1]
        if f ~= nil then bar(ctx, x0 + 12, ty + 6, w - 24, 5, f.cap > 0 and f.level / f.cap or 0, C.amber) end
    end
    chips(ctx, d, x0 + w - 160, ty - 8, 52)
end

-- (01/11) accueil en tuiles adaptables -----------------------------------------
-- 1. inventaire : chaque tuile du catalogue a une condition (le véhicule a ceci) et une priorité ;
-- 2. placement : la marque donne la grille et la place préférée de chaque tuile ; une tuile absente
--    libère sa case, que les tuiles « extensibles » (image et feux d'abord) viennent occuper ;
-- 3. arrangement par marque : FendtONE 3 x 2, Case IH / New Holland 4 x 2, John Deere (touches en bas),
--    Deutz-Fahr (tableau de bord à gauche), Claas / Valtra (machine au centre) ;
-- 4. cas particuliers par modèle : table HOME_RULES (dans le code) et réglage Paramètres > ACCUEIL
--    (Auto / Toujours / Jamais pour chaque tuile, gardé par modèle).

-- côté avant / arrière : outil attelé (relevage) ou, sur une machine, coupe / récolte, rampe / cuve
local function sideTile(d, v, front)
    local m = d.mach
    if m ~= nil and m.obj == v then
        if m.kind == "combine" or m.kind == "forage" or m.kind == "root" then return true end
    end
    local pick = false
    for _, hh in ipairs(d.hitches or {}) do
        if hh.front == front and hh.object ~= nil then pick = true end
    end
    if pick then return true end
    return m ~= nil and m.obj == v and m.kind == "spreader"
end

-- catalogue : id, priorité (1 = la plus haute), condition, dessin
local TILES = {
    engine = { prio = 1, cond = function(d, v) return v.spec_motorized ~= nil or d.rpm ~= nil end,
        draw = function(self, ctx, d, v, x, y, w, h) W.engine(ctx, d, x, y, w, h, self) end },
    lights = { prio = 2, cond = function(d, v) return v.spec_lights ~= nil or vehImageKind(v, d) ~= nil end,
        draw = function(self, ctx, d, v, x, y, w, h) W.lights(ctx, d, v, x, y, w, h, self) end },
    quick = { prio = 3, cond = function() return true end,
        draw = function(self, ctx, d, v, x, y, w, h) W.quick(ctx, d, x, y, w, h, w >= 500 and 6 or (w >= 250 and 3 or 2)) end },
    hitchF = { prio = 4, cond = function(d, v) return sideTile(d, v, true) end,
        draw = function(self, ctx, d, v, x, y, w, h) W.hitch(ctx, d, x, y, w, h, true) end },
    hitchR = { prio = 5, cond = function(d, v) return sideTile(d, v, false) end,
        draw = function(self, ctx, d, v, x, y, w, h) W.hitch(ctx, d, x, y, w, h, false) end },
    tools = { prio = 6, cond = function(d, v) return #(d.tools or {}) > 0 end,
        draw = function(self, ctx, d, v, x, y, w, h) W.tools(ctx, d, x, y, w, h) end },
    speed = { prio = 7, cond = function() return true end,
        draw = function(self, ctx, d, v, x, y, w, h)
            W.tile(ctx, x, y, w, h, T("speed"), "page_tractor")
            W.dial(ctx, d, x + w * 0.5, y + math.min(h * 0.54, 86), math.min(52, (math.min(w, h) - 50) * 0.5))
        end },
    -- Claas / Valtra : la machine au centre, accès rapide et premier outil dessous
    center = { prio = 2, cond = function() return true end,
        draw = function(self, ctx, d, v, x, y, w, h) W.center(ctx, d, v, x, y, w, h, self) end },
}
AS_Terminal.HOME_TILES = TILES
AS_Terminal.HOME_ORDER = { "engine", "lights", "center", "quick", "hitchF", "hitchR", "tools", "speed" }

-- arrangement de chaque marque : largeurs des colonnes, hauteurs des lignes, écarts, place préférée
-- { colonne, ligne, nb colonnes, nb lignes } et ordre des tuiles qui s'étendent dans les cases libres
local ARR = {
    fendt = { cols = { 286, 286, 286 }, rows = { 160, 160 }, gx = 7, gy = 4,
        pref = { hitchF = { 1, 1 }, engine = { 2, 1 }, hitchR = { 3, 1 }, lights = { 1, 2 }, tools = { 2, 2 }, quick = { 3, 2 } },
        grow = { "lights", "tools", "engine", "quick", "hitchF", "hitchR" } },
    grid = { cols = { 215, 215, 215, 215 }, rows = { 160, 160 }, gx = 4, gy = 4,
        pref = { speed = { 1, 1 }, engine = { 2, 1 }, hitchF = { 3, 1 }, hitchR = { 4, 1 }, lights = { 1, 2, 2, 1 }, tools = { 3, 2 }, quick = { 4, 2 } },
        grow = { "lights", "tools", "engine", "quick", "speed", "hitchF", "hitchR" } },
    jd = { cols = { 212, 212, 215, 215 }, rows = { 150, 132 }, gx = 6, gy = 6, keys = true,
        pref = { engine = { 1, 1, 2, 1 }, hitchF = { 3, 1 }, hitchR = { 4, 1 }, lights = { 1, 2, 2, 1 }, tools = { 3, 2, 2, 1 } },
        grow = { "lights", "tools", "engine", "hitchF", "hitchR" } },
    df = { cols = { 200, 330, 330 }, rows = { 160, 160 }, gx = 6, gy = 4, tall = true,
        pref = { engine = { 1, 1, 1, 2 }, hitchF = { 2, 1 }, hitchR = { 3, 1 }, lights = { 2, 2 }, quick = { 3, 2 } },
        grow = { "lights", "quick", "tools", "hitchF", "hitchR" } },
    center = { cols = { 200, 460, 200 }, rows = { 160, 160 }, gx = 6, gy = 4, noLights = true,
        pref = { hitchF = { 1, 1 }, speed = { 1, 2 }, center = { 2, 1, 1, 2 }, hitchR = { 3, 1 }, engine = { 3, 2 } },
        grow = { "center", "speed", "engine", "hitchF", "hitchR" } },
}
AS_Terminal.HOME_ARR = ARR
AS_Terminal.LAYOUTS = ARR

-- cas particuliers par modèle (dans le code) : motif du fichier du véhicule -> { id = 1 toujours / 2 jamais }
-- ou { id = { col, ligne, nbCol, nbLig } } pour déplacer une tuile. Remplie au fur et à mesure.
AS_Terminal.HOME_RULES = {
    -- exemple : ["fendt/vario200v/"] = { hitchF = 2 },
}

-- réglage gardé par modèle (Paramètres > ACCUEIL) : « hitchF=2,tools=1 »
local function parseTiles(s)
    local t = {}
    if type(s) ~= "string" then return t end
    for id, val in s:gmatch("(%w+)=(%d)") do t[id] = tonumber(val) end
    return t
end
local function writeTiles(t)
    local keys = {}
    for id, val in pairs(t) do if val ~= 0 then keys[#keys + 1] = id .. "=" .. val end end
    table.sort(keys)
    return #keys > 0 and table.concat(keys, ",") or nil
end
AS_Terminal.parseTiles, AS_Terminal.writeTiles = parseTiles, writeTiles

local function homeKey(v)
    if AS_TerminalTablet ~= nil and AS_TerminalTablet.modelKeyOf ~= nil then return AS_TerminalTablet.modelKeyOf(v) end
    return tostring(v.configFileName or "?")
end

function AS_Terminal:homeOverrides(v)
    local o = {}
    local cfg = tostring(v.configFileName or ""):lower()
    for pat, rule in pairs(self.HOME_RULES) do
        if cfg:find(pat:lower(), 1, true) then for id, val in pairs(rule) do o[id] = val end end
    end
    local p = self.positions[homeKey(v)]
    if p ~= nil and p.tiles ~= nil then for id, val in pairs(parseTiles(p.tiles)) do o[id] = val end end
    return o
end

-- poids : envie de grandir d'une tuile (image et feux d'abord), plus grande taille permise (colonnes, lignes)
local GROW = { lights = 10, center = 8, tools = 4, engine = 3, quick = 1, speed = 1, hitchF = 1, hitchR = 1 }
local MAXSPAN = { lights = { 2, 2 }, center = { 2, 2 }, tools = { 2, 2 }, engine = { 2, 2 }, quick = { 3, 2 }, speed = { 1, 2 },
    hitchF = { 2, 2 }, hitchR = { 2, 2 } }

-- placement : recherche de la meilleure grille (toutes les cases remplies, tuiles près de leur place
-- préférée, image et feux le plus grand possible). Gardé tant que les tuiles du véhicule ne changent pas.
-- Renvoie { { id, x, y, w, h }, ... } en unités du panneau.
function AS_Terminal:homePlan(d, v, arr, overrides, arrName)
    local nc, nr = #arr.cols, #arr.rows
    -- tuiles du véhicule (inventaire)
    local list = {}
    for _, id in ipairs(self.HOME_ORDER) do
        local t = TILES[id]
        local ov = overrides[id]
        local wanted = arr.pref[id] ~= nil or id == "tools"
        if id == "lights" and arr.noLights then wanted = false end
        if id == "quick" and arr.keys then wanted = false end
        local show = wanted and t.cond(d, v)
        if ov == 1 then show = wanted end
        if ov == 2 then show = false end
        if type(ov) == "table" then show = true end
        if show then
            list[#list + 1] = { id = id, prio = t.prio, pref = type(ov) == "table" and nil or arr.pref[id], fixed = type(ov) == "table" and ov or nil }
        end
    end
    table.sort(list, function(a, b) return a.prio < b.prio end)
    local ids = {}
    for _, e in ipairs(list) do ids[#ids + 1] = e.id .. (e.fixed ~= nil and table.concat(e.fixed, ".") or "") end
    local key = tostring(arrName) .. "|" .. table.concat(ids, ",")
    self.homeCache = self.homeCache or {}
    local cached = self.homeCache[key]
    if cached == nil then
        cached = self:homeSearch(arr, list)
        self.homeCache[key] = cached
        log("accueil %s : %s", tostring(arrName), table.concat(ids, ", "))
    end
    -- en unités du panneau
    local X0, Y0 = 14, 50
    local cx, cy = {}, {}
    local acc = X0
    for i, w in ipairs(arr.cols) do cx[i] = acc; acc = acc + w + arr.gx end
    acc = Y0
    for j, h in ipairs(arr.rows) do cy[j] = acc; acc = acc + h + arr.gy end
    local out = {}
    for _, q in ipairs(cached) do
        local x, y = cx[q.c], cy[q.r]
        out[#out + 1] = { id = q.id, x = x, y = y, w = cx[q.c + q.w - 1] + arr.cols[q.c + q.w - 1] - x,
            h = cy[q.r + q.h - 1] + arr.rows[q.r + q.h - 1] - y, c = q.c, r = q.r, cw = q.w, rh = q.h }
    end
    return out
end

function AS_Terminal:homeSearch(arr, list)
    local nc, nr = #arr.cols, #arr.rows
    local occ = {}
    for c = 1, nc do occ[c] = {} end
    -- rectangles possibles de chaque tuile, et leur coût
    local cands = {}
    for k, e in ipairs(list) do
        local cs = {}
        if e.fixed ~= nil then
            local f = e.fixed
            cs[1] = { c = f[1], r = f[2], w = f[3] or 1, h = f[4] or 1, cost = 0 }
        else
            local mx = MAXSPAN[e.id] or { 1, 1 }
            local p = e.pref
            local natural = p ~= nil and (p[3] or 1) * (p[4] or 1) or 1
            for w = 1, math.min(mx[1], nc) do
                for h = 1, math.min(mx[2], nr) do
                    for c = 1, nc - w + 1 do
                        for r = 1, nr - h + 1 do
                            local cost = 0
                            if p ~= nil then
                                local dx = (p[1] >= c and p[1] <= c + w - 1) and 0 or math.min(math.abs(p[1] - c), math.abs(p[1] - (c + w - 1)))
                                local dy = (p[2] >= r and p[2] <= r + h - 1) and 0 or math.min(math.abs(p[2] - r), math.abs(p[2] - (r + h - 1)))
                                cost = cost + 6 * (dx + dy)
                            end
                            local cells = w * h
                            cost = cost - (GROW[e.id] or 1) * (cells - natural)
                            -- la forme de la marque (moteur haut chez Deutz, larges chez John Deere) est gardée
                            if p ~= nil and (w < (p[3] or 1) or h < (p[4] or 1)) then cost = cost + 500 end
                            cs[#cs + 1] = { c = c, r = r, w = w, h = h, cost = cost }
                        end
                    end
                end
            end
            table.sort(cs, function(a, b) return a.cost < b.cost end)
        end
        cands[k] = cs
    end
    local total = nc * nr
    local best, bestCost = {}, math.huge
    local cur = {}
    local nodes = 0
    local function free(q)
        if q.c < 1 or q.r < 1 or q.c + q.w - 1 > nc or q.r + q.h - 1 > nr then return false end
        for i = q.c, q.c + q.w - 1 do for j = q.r, q.r + q.h - 1 do if occ[i][j] ~= nil then return false end end end
        return true
    end
    local function mark(q, id)
        for i = q.c, q.c + q.w - 1 do for j = q.r, q.r + q.h - 1 do occ[i][j] = id end end
    end
    -- meilleur gain encore possible (pour couper les branches)
    local bound = {}
    bound[#list + 1] = 0
    for k = #list, 1, -1 do bound[k] = bound[k + 1] + (cands[k][1] ~= nil and math.min(0, cands[k][1].cost) or 0) end
    local function rec(k, cost, filled)
        nodes = nodes + 1
        if nodes > 200000 then return end
        if cost + bound[k] >= bestCost then return end
        if k > #list then
            local c2 = cost + 50 * (total - filled)
            if c2 < bestCost then
                bestCost = c2
                best = {}
                for i, q in ipairs(cur) do best[i] = q end
            end
            return
        end
        local e = list[k]
        for _, q in ipairs(cands[k]) do
            if free(q) then
                mark(q, e.id)
                cur[#cur + 1] = { id = e.id, c = q.c, r = q.r, w = q.w, h = q.h }
                rec(k + 1, cost + q.cost, filled + q.w * q.h)
                cur[#cur] = nil
                mark(q, nil)
            end
        end
        -- tuile laissée de côté (plus de place)
        rec(k + 1, cost + 100 * (10 - e.prio), filled)
    end
    rec(1, 0, 0)
    -- cases restées vides
    for _, q in ipairs(best) do mark(q, q.id) end
    for c = 1, nc do
        for r = 1, nr do
            if occ[c][r] == nil then best[#best + 1] = { id = "empty", c = c, r = r, w = 1, h = 1 } end
        end
    end
    return best
end

function AS_Terminal:page_home(d, ctx, inside, v)
    ctx.v = v
    local st = ctx.style or self:brandStyle(v)
    ctx.acc = st.acc or C.green
    if st.layout == "case" then
        local okC, errC = pcall(W.caseHome, ctx, d, v, self)
        if okC then return end
        if not self.loggedCase then self.loggedCase = true; log("ERREUR accueil Case : %s", tostring(errC)) end
    end
    local arr = ARR[st.layout or "fendt"] or ARR.fendt
    local plan = self:homePlan(d, v, arr, self:homeOverrides(v), st.layout or "fendt")
    self.homeLast = plan
    for _, p in ipairs(plan) do
        if p.id == "empty" then
            ctx.rect(p.x, p.y, p.w, p.h, C.box, 0.5)
        else
            local ok, err = pcall(TILES[p.id].draw, self, ctx, d, v, p.x, p.y, p.w, p.h)
            if not ok and not self.loggedTile then self.loggedTile = true; log("ERREUR tuile %s : %s", p.id, tostring(err)) end
        end
    end
    -- John Deere : touches de raccourci en bas
    if arr.keys then
        local q = quickList(d)
        local bw = (872 - 5 * 5) / 6
        for i, b in ipairs(q) do
            local bx = 14 + (i - 1) * (bw + 5)
            ctx.button(bx, 343, bw, 31, b[1], b[3])
            ctx.text(bx + bw * 0.5, 363, 11, cut(b[2], 16), C.white, RenderText.ALIGN_CENTER, true)
        end
    end
    W.info(ctx, d, 14, 378, 872)
end

-------------------------------------------------------------------------------
-- (01/11) accueil Case IH façon AFS Pro 1200 : colonne de cases à gauche, fenêtre
-- « Tracteur | Éclairage » au centre (tracteur vu de dessus, feux numérotés cliquables),
-- menu bleu à droite. Images redessinées : objects/terminal/as_case_*.dds (draw_case.py)
-------------------------------------------------------------------------------
local function caseIcon(ctx, x, y, s, name)
    local file = caseImg(name)
    ctx.image(x, y, s, s, ctx.rec == nil and AS_TerminalTools ~= nil and AS_TerminalTools:overlay(file) or nil, "img_" .. name, file)
end
-- (02/11 soir) les valeurs écrites sur
-- les écrans Case le sont avec la police Case (scripts/CaseFont.lua + objects/terminal/font/f_<jeu>_<code>.dds, une petite
-- image par caractère ; jeu = dk sombre, bl bleu, wh blanc, rd rouge). yBase = ligne de base (pixels du panneau),
-- hDig = hauteur voulue des chiffres / capitales, maxW = largeur maxi (le texte est réduit s'il dépasse).
local function utf8codes(str)
    local codes = {}
    local i, n = 1, #str
    while i <= n do
        local c = str:byte(i)
        if c >= 0xC0 and c < 0xE0 and i < n then c = (c - 0xC0) * 64 + (str:byte(i + 1) - 0x80); i = i + 2
        elseif c >= 0xE0 then c = 63; i = i + (c >= 0xF0 and 4 or 3)
        else i = i + 1 end
        codes[#codes + 1] = c
    end
    return codes
end
local function caseWrite(ctx, x, yBase, hDig, str, set, align, maxW)
    local F = AS_CaseFont
    if F == nil or str == nil then return 0 end
    if F.setCodes == nil then   -- caractères existant dans chaque jeu de couleur (les autres : jeu sombre)
        F.setCodes = {}
        for nm, chars in pairs(F.sets) do
            if chars ~= "all" then
                F.setCodes[nm] = {}
                for _, c in ipairs(utf8codes(chars)) do F.setCodes[nm][c] = true end
            end
        end
    end
    local k = hDig / (F.dig * F.cell)
    local codes = utf8codes(tostring(str))
    local w = 0
    for i, c in ipairs(codes) do
        if F.adv[c] == nil then codes[i] = 63; c = 63 end
        w = w + (F.adv[c] or 0.5) * F.cell * k
    end
    if maxW ~= nil and w > maxW and w > 0 then k = k * maxW / w; w = maxW end
    if align == RenderText.ALIGN_CENTER then x = x - w * 0.5 elseif align == RenderText.ALIGN_RIGHT then x = x - w end
    local cell = F.cell * k
    local y = yBase - F.base * cell
    local only = F.setCodes[set]
    for _, c in ipairs(codes) do
        if c ~= 32 then
            local name = string.format("f_%s_%03d", (only ~= nil and not only[c]) and "dk" or set, c)
            local file = caseImg("font/" .. name)
            ctx.image(x - F.pad * cell, y, cell, cell, ctx.rec == nil and AS_TerminalTools ~= nil and AS_TerminalTools:overlay(file) or nil, "g_" .. name, file)
        end
        x = x + (F.adv[c] or 0.5) * cell
    end
    return w
end
AS_Terminal.caseWrite = caseWrite
-- (02/11 soir) barre du haut des écrans : la flèche de relevage est vivante (flèche haut quand un outil
-- est baissé : clic = tout relever ; flèche bas sinon : clic = tout baisser) et le satellite alterne rouge « 0 »
-- (pas de guidage) / vert (signal valide). Sprites découpés dans les images ; arrowCx / satCx = centres (pixels image).
local function caseTopBar(ctx, d, PX, PY, PW, arrowCx, satCx)
    local hot = ctx.hotspot or ctx.button
    -- (03/11) flèche = l'état : grise vers le bas quand les outils sont baissés, grise vers le haut quand ils sont
    -- relevés ; verte dans le sens du mouvement pendant que le relevage bouge. Clic = tout relever si baissé, sinon tout baisser
    local up = d.anyLowered == true
    local moving, movingDown = false, false
    for _, h in ipairs(d.hitches or {}) do
        if h.object ~= nil and h.own == nil and h.up ~= nil and h.up > 0.03 and h.up < 0.97 then moving = true; movingDown = h.moveDown == true end
    end
    local file = caseImg(moving and (movingDown and "as_case_arr_dn" or "as_case_arr_up2") or (up and "as_case_arr_dn2" or "as_case_arr_up"))
    ctx.image(PX(arrowCx - 24), PY(0), PW(48), PY(96), ctx.rec == nil and AS_TerminalTools ~= nil and AS_TerminalTools:overlay(file) or nil, "img_case_arr", file)
    hot(PX(arrowCx - 28), PY(4), PW(56), PY(78), up and "lift_up" or "lift_dn")
    -- (03/11) satellite rouge tout le temps, vert seulement dans un champ
    local okGps = d.field ~= nil
    local fs = caseImg(okGps and "as_case_sat_green" or "as_case_sat_red")
    ctx.image(PX(satCx - 50), PY(-8), PW(100), PY(100), ctx.rec == nil and AS_TerminalTools ~= nil and AS_TerminalTools:overlay(fs) or nil, "img_case_sat", fs)
    hot(PX(satCx - 48), PY(4), PW(96), PY(78), "guide")
    -- (03/11) relevage verrouillé : cadenas sur la flèche
    if d.vehicle ~= nil and AS_Terminal.hitchLocked ~= nil and (not AS_Terminal:hitchLocked(d.vehicle, true) or not AS_Terminal:hitchLocked(d.vehicle, false)) then   -- (21:00) cadenas = un attelage NON actif
        local fl = caseImg("as_case_lock")
        ctx.image(PX(arrowCx + 2), PY(40), PW(42), PY(42), ctx.rec == nil and AS_TerminalTools ~= nil and AS_TerminalTools:overlay(fl) or nil, "img_case_lock", fl)
    end
end
-- bouton de feu de l'image gardé tel quel : allumé = cadre bleu (orange
-- pour le gyrophare) autour, plus un voile léger sur l'écran 2D
local function caseLampFrame(ctx, x, y, w, h, col)
    local t = math.max(2, h * 0.07)
    ctx.rect(x, y, w, t, col); ctx.rect(x, y + h - t, w, t, col)
    ctx.rect(x, y, t, h, col); ctx.rect(x + w - t, y, t, h, col)
    if ctx.rec == nil then ctx.rect(x + t, y + t, w - 2 * t, h - 2 * t, col, 0.30) end
end
AS_Terminal.CASE_LAMPS = {
    -- n°, feu, position (fraction de l'image 512 x 256)
    -- (01/11) placés sur les repères de l'image de tracteur
    { 1, "drive", 0.398, 0.472 }, { 2, "high", 0.142, 0.368 },
    { 3, "workF", 0.583, 0.147 }, { 3, "workF", 0.592, 0.777 },
    { 4, "workR", 0.799, 0.109 }, { 4, "workR", 0.799, 0.811 },
    { 5, "beacon", 0.712, 0.494 }, { 6, "hazard", 0.349, 0.094 }, { 6, "hazard", 0.349, 0.821 },
}
-- (01/11) moissonneuse Case : l'image vue de dessus, feux et gyrophares posés dessus
AS_Terminal.CASE_LAMPS_COMBINE = {
    { 1, "drive", 0.184, 0.50 }, { 2, "high", 0.379, 0.439 },
    { 3, "workF", 0.237, 0.117 }, { 3, "workF", 0.237, 0.884 },
    { 4, "workR", 0.76, 0.322 }, { 4, "workR", 0.76, 0.674 },
    { 5, "beacon", 0.299, 0.293 }, { 5, "beacon", 0.307, 0.589 },
    { 6, "hazard", 0.662, 0.166 }, { 6, "hazard", 0.662, 0.859 },
}
function W.caseCell(ctx, x, y, w, h, icon, title, value, unit, col)
    ctx.rect(x, y, w, h, CASE_CARD)
    local s = math.min(h - 8, 30)
    caseIcon(ctx, x + 5, y + (h - s) * 0.5, s, icon)
    local tx = x + s + 12
    ctx.text(tx, y + 13, 10, title, C.gray, nil, true, w - s - 16)
    ctx.text(tx, y + h - 6, h >= 48 and 20 or 16, value, col or C.white, nil, true, w - s - 16 - (unit ~= nil and 34 or 0))
    if unit ~= nil then ctx.text(x + w - 6, y + h - 6, 11, unit, C.gray, RenderText.ALIGN_RIGHT) end
end
-- cases de la colonne de gauche des Case (accueil et autres pages)
AS_Terminal.CASE_CELLS = {
    home = { "power", "slip", "hitchF", "hitchR", "xte", "fuelEco", "workRate", "fuelRate" },
    gps = { "power", "fuelRate", "slip", "speed", "area", "xte" },
    other = { "speed", "power", "slip", "fuelRate", "fuelEco", "workRate", "xte", "area" },
    combine = { "speed", "tank", "power", "fuelRate", "workRate", "area" },
    homeCombine = { "power", "speed", "tank", "fuelRate", "fuelEco", "workRate", "area", "xte" },
}
function W.caseCells(d, which)
    local job = d.cnt.jobs[d.cnt.active]
    local hf, hr
    for _, h in ipairs(d.hitches or {}) do
        if h.object ~= nil then if h.front then hf = hf or h else hr = hr or h end end
    end
    local function hitchVal(h)
        if h == nil then return "-", nil end
        return h.moveDown and T("lowered") or T("raised"), string.format("%d %%", math.floor((h.up or 0) * 100 + 0.5))
    end
    local g = d.gps
    local all = {
        power = { "as_case_d_engine", T("c_power"), d.load ~= nil and string.format("%d", math.floor(d.load * 100 + 0.5)) or "-", "%" },
        slip = { "as_case_d_slip", T("slip"), d.slip ~= nil and string.format("%d", math.floor(d.slip + 0.5)) or "-", "%", (d.slip or 0) > 25 and C.red or nil },
        xte = { "as_case_d_xte", T("c_xte"), (g ~= nil and g.onLine and g.xte ~= nil) and string.format("%.1f", math.abs(g.xte) * 100) or "--.-", "cm" },
        fuelEco = { "as_case_d_fueleco", T("c_fuelEco"), job.ha > 0.01 and string.format("%.1f", job.fuel / job.ha) or "0.0", "l/ha" },
        workRate = { "as_case_d_work", T("c_workRate"), job.ms > 60000 and string.format("%.1f", job.ha / (job.ms / 3600000)) or "0.0", "ha/h" },
        fuelRate = { "as_case_d_fuelrate", T("c_fuelRate"), fmt1(d.fuelUse), "l/h" },
        speed = { "as_case_d_speed", T("speed"), string.format("%.1f", math.abs(d.speed or 0)), "km/h" },
        area = { "as_case_d_area", T("c_area"), string.format("%.2f", job.ha), "ha" },
    }
    local mt = d.mach ~= nil and d.mach.tank or nil
    local tp = mt ~= nil and mt.cap > 0 and mt.level / mt.cap or nil
    all.tank = { "as_case_d_area", T("m_grainTank"), tp ~= nil and string.format("%d", math.floor(tp * 100 + 0.5)) or "-", "%",
        tp ~= nil and (tp > 0.9 and C.red or (tp > 0.75 and C.amber or nil)) or nil }
    all.hitchF = { "as_case_d_hitch", T("hitchF"), hitchVal(hf) }
    all.hitchR = { "as_case_d_hitch", T("hitchR"), hitchVal(hr) }
    local a, b = hitchVal(hf); all.hitchF[3], all.hitchF[4] = a, b
    a, b = hitchVal(hr); all.hitchR[3], all.hitchR[4] = a, b
    local out = {}
    for _, k in ipairs(AS_Terminal.CASE_CELLS[which] or AS_Terminal.CASE_CELLS.other) do out[#out + 1] = all[k] end
    return out
end
-- colonne de gauche des Case sur les autres pages (comme le vrai terminal : toujours affichée)
function AS_Terminal:caseColumn(ctx, d, page, x0, y0, w, H)
    local which = page == "gps" and "gps" or "other"
    if page == "tool" and self.harvestSelf and d.mach ~= nil and d.mach.kind == "combine" then
        -- (01/11) moissonneuse : la colonne de gauche du vrai terminal (l'image), valeurs réelles dessus
        return self:caseCombColumn(ctx, d, x0, y0, w, H)
    end
    local cells = W.caseCells(d, which)
    local gap = 4
    local ch = (H - gap * (#cells - 1)) / #cells
    for i, c in ipairs(cells) do
        W.caseCell(ctx, x0, y0 + (i - 1) * (ch + gap), w, ch, c[1], c[2], c[3], c[4], c[5])
    end
end

-- colonne de gauche de la moissonneuse Case, comme le modèle
function AS_Terminal:caseCombColumn(ctx, d, x0, y0, w, H)
    local IW, IH = 804, 1956
    local ih = math.min(H, w * IH / IW)
    local iw = math.min(w, ih * IW / IH * 1.10)   -- au plus 10 % plus large, comme la colonne du modèle
    local ix, iy = x0 + (w - iw) * 0.5, y0 + (H - ih) * 0.5
    local k, ky = iw / IW, ih / IH
    local file = caseImg("as_case_combcol")
    ctx.image(ix, iy, iw, ih, ctx.rec == nil and AS_TerminalTools ~= nil and AS_TerminalTools:overlay(file) or nil, "img_as_case_combcol", file)
    local DK, BL, GR = { 0.10, 0.12, 0.15, 1 }, BLUE_CASE, { 0.40, 0.42, 0.45, 1 }
    local function tx(x, y, size, str, col, align, maxW)
        ctx.text(ix + x * k, iy + y * ky, size, str, col or DK, align, true, maxW ~= nil and maxW * k or nil)
    end
    local m = d.mach
    -- vitesse (grande, bleue), km/h dessous, régulateur sous le compteur, rapport dans l'engrenage
    tx(270, 150, 22, string.format("%.1f", math.abs(d.speed or 0)), BL, nil, 300)
    tx(272, 215, 9, "km/h", GR, nil, 200)
    if d.cruise ~= nil and d.cruise ~= 0 and d.cruiseSpeed ~= nil then
        tx(115, 228, 10, string.format("%.1f", d.cruiseSpeed), DK, RenderText.ALIGN_CENTER, 200)
    end
    tx(675, 150, 16, tostring(d.gear or "N"), DK, RenderText.ALIGN_CENTER, 120)
    -- trémie : % dans l'entonnoir jaune
    local tp = m ~= nil and m.tank ~= nil and m.tank.cap > 0 and m.tank.level / m.tank.cap or nil
    tx(418, 362, 13, tp ~= nil and string.format("%d%%", math.floor(tp * 100 + 0.5)) or "-", DK, RenderText.ALIGN_CENTER, 300)
    -- carburant et AdBlue : les traits se remplissent en bleu du bas vers le haut
    local function gauge(x1, x2, f)
        if f == nil then return end
        f = math.max(0, math.min(1, f))
        local col = f < 0.1 and C.red or BL
        local n = 21
        for i = 0, n - 1 do
            local yy = 1099 - i * 18.3
            if (i + 1) / n <= f + 0.5 / n then ctx.rect(ix + x1 * k, iy + (yy - 7) * ky, (x2 - x1) * k, 12 * ky, col) end
        end
    end
    gauge(50, 162, d.fuel)
    gauge(208, 320, d.def)
    -- pente sous l'icône de pente (grand, bleu)
    local v = d.vehicle
    local slope
    if v ~= nil and v.rootNode ~= nil and localDirectionToWorld ~= nil then
        local ok, dx, dy, dz = pcall(localDirectionToWorld, v.rootNode, 0, 0, 1)
        if ok and dx ~= nil then
            local hz = math.sqrt(dx * dx + dz * dz)
            if hz > 0.01 then slope = math.abs(dy) / hz * 100 end
        end
    end
    tx(440, 1090, 18, slope ~= nil and string.format("%d%%", math.floor(slope + 0.5)) or "-", BL, RenderText.ALIGN_CENTER, 300)
    -- éparpilleur / andain, température moteur, température extérieure : titre petit, valeur grande
    local function cell(y, title, val, unit)
        tx(285, y, 9, title, DK, nil, 500)
        tx(285, y + 105, 16, val, DK, nil, 400)
        if unit ~= nil and val ~= "-" then
            local vw = ctx.measure ~= nil and ctx.measure(16, val) or 40
            ctx.text(ix + 285 * k + vw + 4, iy + (y + 105) * ky, 10, unit, DK, nil, true)
        end
    end
    cell(1330, T("c_spreader"), m ~= nil and m.swath ~= nil and (m.swath and T("m_swathOn") or T("m_chopOn")) or "-")
    cell(1560, T("c_coolant"), d.temp ~= nil and tostring(math.floor(d.temp + 0.5)) or "-", "°C")
    local tOut
    local env = g_currentMission ~= nil and g_currentMission.environment or nil
    local wth = env ~= nil and env.weather or nil
    if wth ~= nil and wth.getCurrentTemperature ~= nil then
        local ok, t = pcall(wth.getCurrentTemperature, wth)
        if ok and type(t) == "number" then tOut = t end
    end
    cell(1792, T("c_tempOut"), tOut ~= nil and tostring(math.floor(tOut + 0.5)) or "-", "°C")
end

function W.caseHome(ctx, d, v, self)
    local x0, y0, H = 14, 50, 326
    -- colonne de gauche : 8 cases (moissonneuse : trémie au lieu des relevages)
    local cells = W.caseCells(d, (self.harvestSelf and d.mach ~= nil and d.mach.kind == "combine") and "homeCombine" or "home")
    local cw, gap = 168, 4
    local ch = (H - gap * (#cells - 1)) / #cells
    for i, c in ipairs(cells) do
        W.caseCell(ctx, x0, y0 + (i - 1) * (ch + gap), cw, ch, c[1], c[2], c[3], c[4], c[5])
    end
    -- menu de droite (boutons bleus)
    local mx, mw = 886 - 150, 150
    local menu = {
        { "page_tractor", "as_case_w_info", T("p_tractor") },
        { "page_tool", "as_case_w_tool", self.harvestSelf and T("p_harvest") or T("p_tool") },
        { "guide", "as_case_w_guide", T("b_guide") },
        { "page_work", "as_case_w_count", T("p_work") },
        { "page_set", "as_case_w_settings", T("c_settings") },
    }
    local mh = (H - gap * (#menu - 1)) / #menu
    for i, m in ipairs(menu) do
        local by = y0 + (i - 1) * (mh + gap)
        ctx.button(mx, by, mw, mh, m[1], true)
        caseIcon(ctx, mx + mw * 0.5 - 17, by + 5, 34, m[2])
        ctx.text(mx + mw * 0.5, by + mh - 7, 11, m[3], { 1, 1, 1, 1 }, RenderText.ALIGN_CENTER, true, mw - 8)
    end
    -- fenêtre du centre : Tracteur | Éclairage
    local px, pw = x0 + cw + 6, mx - (x0 + cw + 6) - 6
    ctx.rect(px, y0, pw, H, CASE_CARD)
    ctx.rect(px, y0, pw, 28, CASE_BAND)
    local comb = self.harvestSelf and d.mach ~= nil and d.mach.kind == "combine"
    local img = comb and "as_case_moissonneuse" or "as_case_tracteur"
    ctx.text(px + pw * 0.5, y0 + 19, 14, (comb and T("m_machine") or T("c_tractor")) .. "  |  " .. T("l_title"), C.white, RenderText.ALIGN_CENTER, true, pw - 20)
    local iw = math.min(pw - 24, (H - 44) * 2)
    local ih = iw / 2
    local iu, iv = px + (pw - iw) * 0.5, y0 + 34 + (H - 40 - ih) * 0.5
    ctx.rect(iu - 7, iv - 7, iw + 14, ih + 14, CASE_BAND)
    ctx.rect(iu - 6, iv - 6, iw + 12, ih + 12, CASE_CARD)
    ctx.image(iu, iv, iw, ih, ctx.rec == nil and AS_TerminalTools ~= nil and AS_TerminalTools:overlay(caseImg(img)) or nil,
        "img_" .. img, caseImg(img))
    local bs = comb and math.max(22, math.min(34, iw * 0.062)) or math.max(24, math.min(46, iw * 0.088))
    for _, l in ipairs(comb and self.CASE_LAMPS_COMBINE or self.CASE_LAMPS) do
        local on = lightOn(d, l[2])
        local bx, by = iu + l[3] * iw - bs * 0.5, iv + l[4] * ih - bs * 0.5
        ctx.button(bx - 2, by - 2, bs + 4, bs + 4, "l_" .. l[2], on)
        -- (01/11) éteint = fond blanc icône bleue ; allumé = fond bleu icône blanche
        -- (01/11) gyrophare : blanc/orange éteint, orange/blanc allumé
        local accent = l[2] == "beacon" and { 0.94, 0.47, 0.0, 1 } or BLUE_CASE
        ctx.rect(bx, by, bs, bs, on and accent or { 1, 1, 1, 1 })
        caseIcon(ctx, bx + bs * 0.30, by + bs * 0.26, bs * 0.66, (l[2] == "beacon" and "as_case_beacon_" or (l[2] == "hazard" and "as_case_hazard_" or "as_case_lamp_")) .. (on and "w" or (l[2] == "beacon" and "o" or "b")))
        ctx.text(bx + 3, by + 12, 11, tostring(l[1]), on and { 1, 1, 1, 1 } or accent, nil, true)
    end
    W.info(ctx, d, 14, 378, 872)
end

-- (01/11) INFO des Case IH : grille de performances (3 colonnes de cases icône + valeur)
function AS_Terminal:caseInfoCells(d)
    local gear = tostring(d.gear or "N")
    if d.group ~= nil and not d.cvt then gear = tostring(d.group) .. " " .. gear end
    if d.cvt then gear = "CVT " .. ((d.dir or 0) < 0 and "R" or ((d.dir or 0) > 0 and "D" or "N")) end
    local hf, hr
    for _, h in ipairs(d.hitches or {}) do
        if h.object ~= nil then if h.front then hf = hf or h else hr = hr or h end end
    end
    local function hpos(h) return h ~= nil and string.format("%d", math.floor((h.up or 0) * 100 + 0.5)) or "-" end
    local drive = d.trans == "4x4" and "4x4" or (d.trans ~= nil and "4x2" or "-")
    if d.awd ~= nil then drive = d.awd and "4x4" or "4x2" end
    local function lockTxt(b) if b == nil then return "-" end return b and T("locked") or T("free") end
    local wear = "-"
    if type(d.wear) == "table" then
        local m = 0
        for _, kk in ipairs({ "fl", "fr", "rl", "rr" }) do if d.wear[kk] ~= nil then m = math.max(m, d.wear[kk]) end end
        wear = string.format("%d", math.floor(m * 100 + 0.5))
    end
    local cells = {
        { "as_case_d_engine", T("c_power"), d.load ~= nil and string.format("%d", math.floor(d.load * 100 + 0.5)) or "-", "%" },
        { "as_case_d_fuel", T("fuel"), d.fuelL ~= nil and string.format("%d", math.floor(d.fuelL + 0.5)) or "-", "l",
            (d.fuel ~= nil and d.fuel * 100 < self.settings.fuelReserve) and C.red or nil },
        { "as_case_d_hours", T("opHours"), string.format("%.1f", d.opHours or 0), "h" },
        { "as_case_d_engine", T("rpm"), d.rpm ~= nil and string.format("%d", math.floor(d.rpm + 0.5)) or "-", T("u_rpm") },
        { "as_case_d_fuelrate", T("c_fuelRate"), fmt1(d.fuelUse), "l/h" },
        { "as_case_d_temp", T("temp"), d.temp ~= nil and string.format("%d", math.floor(d.temp + 0.5)) or "-", "°C", (d.temp or 0) > 100 and C.red or nil },
        { "as_case_d_hitch", T("hitchR"), hpos(hr), "%" },
        { "as_case_d_hitch", T("hitchF"), hpos(hf), "%" },
        { "as_case_d_def", "AdBlue", d.def ~= nil and string.format("%d", math.floor(d.def * 100 + 0.5)) or "-", "%" },
        { "as_case_d_gear", T("gear"), gear, nil },
        { "as_case_d_speed", T("cruise"), (d.cruise ~= nil and d.cruise ~= 0) and string.format("%d", math.floor((d.cruiseSpeed or 0) + 0.5)) or T("off"),
            (d.cruise ~= nil and d.cruise ~= 0) and "km/h" or nil },
        { "as_case_d_slip", T("slip"), d.slip ~= nil and string.format("%d", math.floor(d.slip + 0.5)) or "-", "%", (d.slip or 0) > 25 and C.red or nil },
        { "as_case_d_gear", T("drive"), drive, nil },
        { "as_case_d_lock", T("lockF"), lockTxt(d.lockF), nil, d.lockF and C.amber or nil },
        { "as_case_d_lock", T("lockR"), lockTxt(d.lockR), nil, d.lockR and C.amber or nil },
        { "as_case_d_work", T("mode"), d.manual == true and T("manual") or T("auto"), nil },
        { "as_case_d_slip", T("c_tyres"), wear, "%" },
        { "as_case_d_wrench", T("damage"), d.damage ~= nil and string.format("%d", math.floor(d.damage * 100 + 0.5)) or "-", "%" },
    }
    return cells
end
function AS_Terminal:caseInfo(d, ctx)
    local cells = self:caseInfoCells(d)
    local cols, gap = 3, 6
    local rows = math.ceil(#cells / cols)
    local x0, y0 = ctx.cx + 8, ctx.cy + 8
    local w = (ctx.cw - 16 - gap * (cols - 1)) / cols
    local h = (ctx.ch - 16 - gap * (rows - 1)) / rows
    for i, c in ipairs(cells) do
        local col, row_ = (i - 1) % cols, math.floor((i - 1) / cols)
        W.caseCell(ctx, x0 + col * (w + gap), y0 + row_ * (h + gap), w, h, c[1], c[2], c[3], c[4], c[5])
    end
end

-- (31/10 soir) feux depuis l'accueil : mêmes fonctions du jeu que les touches (multijoueur compris)
function AS_Terminal:cmdLight(v, what)
    if v.spec_lights == nil then warn(T("noLights")) return end
    -- état relu sur le véhicule (deux clics rapprochés : la page n'est peut-être pas encore relue)
    local spl = v.spec_lights
    local beacon = call(v, "getBeaconLightsVisibility")
    if beacon == nil then beacon = spl.beaconLightsActive end
    local d = { lights = { mask = call(v, "getLightsTypesMask") or spl.lightsTypesMask or 0, beacon = beacon == true,
        turn = call(v, "getTurnLightState") or spl.turnLightState or 0 } }
    local on = lightOn(d, what)
    local ok, err = true, nil
    if what == "mem1" or what == "mem2" then
        -- (02/11 soir) Mem 1 / Mem 2 de l'écran « Tractor | Lights » : tout allumé (route + travail + gyrophare) / tout éteint
        local all = 2 ^ LIGHT_BIT.drive + 2 ^ LIGHT_BIT.workF + 2 ^ LIGHT_BIT.workR
        ok, err = pcall(v.setLightsTypesMask, v, what == "mem1" and all or 0)
        if ok then ok, err = pcall(v.setBeaconLightsVisibility, v, what == "mem1") end
        on = what == "mem2"
    elseif what == "beacon" then
        ok, err = pcall(v.setBeaconLightsVisibility, v, not on)
    elseif what == "hazard" then
        if Lights == nil or Lights.TURNLIGHT_HAZARD == nil then return end
        ok, err = pcall(v.setTurnLightState, v, on and Lights.TURNLIGHT_OFF or Lights.TURNLIGHT_HAZARD)
    else
        local b = LIGHT_BIT[what]
        if b == nil then return end
        local mask = d.lights.mask
        mask = on and (mask - 2 ^ b) or (mask + 2 ^ b)
        -- pleins phares : avec les feux de route
        if what == "high" and not on and math.floor(mask / 2 ^ LIGHT_BIT.drive) % 2 == 0 then mask = mask + 2 ^ LIGHT_BIT.drive end
        ok, err = pcall(v.setLightsTypesMask, v, mask)
    end
    if not ok then log("ERREUR feux %s : %s", tostring(what), tostring(err)) end
    log("feux %s : %s", tostring(what), on and "éteint" or "allumé")
    self.lastRead = -100000
end

-- page Outil : relevages avant / arrière (jauge), outils attelés
-- gros bouton de la colonne de droite (n = rang), allumé si « on »
local function sideButton(ctx, n, action, label, on, state)
    local bx, by = ctx.rx + 6, (ctx.sideY or ctx.cy) + 22 + (n - 1) * 46
    ctx.button(bx, by, 128, 40, action, on)
    ctx.text(bx + 64, by + (state ~= nil and 17 or 25), 12, label, C.white, RenderText.ALIGN_CENTER, true, 120)
    if state ~= nil then ctx.text(bx + 64, by + 33, 10, state, on and C.white or C.gray, RenderText.ALIGN_CENTER, nil, 120) end
end


-- (01/11) moissonneuse Case IH : page RÉGLAGES comme le vrai AFS Pro (schéma de la machine,
-- réglages Realistic Harvesting sur le schéma, pertes en bas). Seules les vraies valeurs sont montrées.
AS_Terminal.CC_W, AS_Terminal.CC_H = 989, 387
AS_Terminal.CC_BOX = {   -- étiquettes de l'image (pixels de l'image 989 x 387)
    load = { 336, 8, 587, 44 }, rotor = { 176, 74, 312, 112 }, C = { 255, 197, 358, 233 }, D = { 453, 197, 556, 233 },
    upperSieve = { 628, 202, 735, 239 }, swath = { 820, 219, 958, 256 }, feeder = { 13, 289, 147, 326 },
    lowerSieve = { 604, 293, 720, 330 }, fan = { 253, 341, 390, 379 }, rpm = { 70, 341, 198, 377 }, pipe = { 835, 312, 971, 350 },
    yield = { 836, 4, 989, 41 }, tph = { 836, 49, 989, 86 }, moist = { 836, 94, 989, 131 },
}
AS_Terminal.ccSel = nil
-- entonnoirs de pertes (pixels de l'image 989 x 178) : { y, x gauche, x droit }
AS_Terminal.LOSS_W, AS_Terminal.LOSS_H = 2172, 360
AS_Terminal.LOSS_FUNNELS = {
    { {16,172,569}, {20,176,565}, {24,180,562}, {28,184,558}, {32,188,554}, {36,192,550}, {40,196,546}, {44,200,542}, {48,204,538}, {52,208,534}, {56,212,531}, {60,216,527}, {64,220,523}, {68,223,520}, {72,227,516}, {76,231,513}, {80,234,509}, {84,238,506}, {88,241,502}, {92,245,499}, {96,248,496}, {100,251,493}, {104,255,490}, {108,258,486}, {112,261,484}, {116,264,481}, {120,267,478}, {124,270,475}, {128,273,472}, {132,275,470}, {136,278,467}, {140,281,465}, {144,283,462}, {148,285,460}, {152,288,458}, {156,290,456}, {160,292,453}, {164,294,451}, {168,296,449}, {172,298,447}, {176,300,446}, {180,302,444}, {184,304,442}, {188,306,440}, {192,307,439}, {196,309,437}, {200,311,436}, {204,312,434}, {208,314,433}, {212,315,431}, {216,316,430}, {220,317,429}, {224,319,428}, {228,320,427}, {232,321,426}, {236,322,424}, {240,323,424}, {244,324,423}, {248,325,422}, {252,326,421}, {256,326,420}, {260,327,420}, {264,328,419}, {268,328,419}, {272,329,418}, {276,329,418}, {280,330,417}, {284,330,417}, {288,330,416}, {292,331,416}, {296,331,416}, {300,331,416}, {304,331,416}, {308,331,416}, {312,331,416}, {316,332,416}, {320,332,416}, {324,332,416}, {328,332,416}, {332,332,416} },
    { {16,866,1263}, {20,870,1259}, {24,874,1256}, {28,878,1252}, {32,882,1248}, {36,886,1244}, {40,890,1240}, {44,894,1236}, {48,898,1232}, {52,902,1228}, {56,906,1225}, {60,910,1221}, {64,914,1217}, {68,917,1214}, {72,921,1210}, {76,925,1207}, {80,928,1203}, {84,932,1200}, {88,935,1196}, {92,939,1193}, {96,942,1190}, {100,945,1187}, {104,949,1184}, {108,952,1180}, {112,955,1178}, {116,958,1175}, {120,961,1172}, {124,964,1169}, {128,967,1166}, {132,969,1164}, {136,972,1161}, {140,975,1159}, {144,977,1156}, {148,979,1154}, {152,982,1152}, {156,984,1150}, {160,986,1147}, {164,988,1145}, {168,990,1143}, {172,992,1141}, {176,994,1140}, {180,996,1138}, {184,998,1136}, {188,1000,1134}, {192,1001,1133}, {196,1003,1131}, {200,1005,1130}, {204,1006,1128}, {208,1008,1127}, {212,1009,1125}, {216,1010,1124}, {220,1011,1123}, {224,1013,1122}, {228,1014,1121}, {232,1015,1120}, {236,1016,1118}, {240,1017,1118}, {244,1018,1117}, {248,1019,1116}, {252,1020,1115}, {256,1020,1114}, {260,1021,1114}, {264,1022,1113}, {268,1022,1113}, {272,1023,1112}, {276,1023,1112}, {280,1024,1111}, {284,1024,1111}, {288,1024,1110}, {292,1025,1110}, {296,1025,1110}, {300,1025,1110}, {304,1025,1110}, {308,1025,1110}, {312,1025,1110}, {316,1026,1110}, {320,1026,1110}, {324,1026,1110}, {328,1026,1110}, {332,1026,1110} },
    { {16,1562,1938}, {20,1566,1934}, {24,1570,1930}, {28,1574,1926}, {32,1578,1922}, {36,1582,1919}, {40,1586,1915}, {44,1589,1911}, {48,1593,1907}, {52,1597,1904}, {56,1600,1900}, {60,1604,1897}, {64,1608,1893}, {68,1611,1889}, {72,1615,1886}, {76,1618,1883}, {80,1622,1879}, {84,1625,1876}, {88,1629,1872}, {92,1632,1869}, {96,1635,1866}, {100,1638,1864}, {104,1641,1860}, {108,1644,1857}, {112,1647,1854}, {116,1649,1852}, {120,1652,1849}, {124,1655,1846}, {128,1657,1844}, {132,1660,1841}, {136,1662,1839}, {140,1665,1836}, {144,1667,1834}, {148,1669,1832}, {152,1671,1830}, {156,1673,1828}, {160,1675,1826}, {164,1677,1824}, {168,1679,1822}, {172,1681,1820}, {176,1683,1818}, {180,1685,1816}, {184,1686,1815}, {188,1688,1813}, {192,1690,1812}, {196,1691,1810}, {200,1693,1809}, {204,1694,1808}, {208,1695,1806}, {212,1697,1805}, {216,1698,1803}, {220,1699,1802}, {224,1700,1801}, {228,1701,1800}, {232,1702,1799}, {236,1703,1798}, {240,1704,1797}, {244,1705,1796}, {248,1706,1796}, {252,1707,1795}, {256,1708,1794}, {260,1708,1794}, {264,1709,1793}, {268,1709,1792}, {272,1710,1792}, {276,1711,1791}, {280,1711,1791}, {284,1711,1790}, {288,1712,1790}, {292,1712,1790}, {296,1712,1790}, {300,1712,1789}, {304,1713,1789}, {308,1713,1789}, {312,1713,1789}, {316,1713,1789}, {320,1713,1789}, {324,1713,1789}, {328,1713,1789}, {332,1713,1789} },
}
local CC_DARK = { 0.10, 0.12, 0.15, 1 }
local CC_WHITE = { 1, 1, 1, 1 }
local CC_STATE = { ok = { 0.15, 0.65, 0.25, 1 }, warn = { 0.95, 0.65, 0.05, 1 }, bad = { 0.90, 0.20, 0.15, 1 } }
function AS_Terminal:caseCombine(d, ctx, v)
    -- (01/11 soir) la page reprend exactement le modèle : schéma et
    -- entonnoirs sur toute la largeur, pas de colonne de touches à droite, cases blanches à bord bleu,
    -- uniquement des valeurs. Un clic sur une case de réglage ouvre une fenêtre - / + par-dessus.
    local m = d.mach
    local r = m.rh
    local X0, Y0, WW, HH = ctx.cx + 4, ctx.cy + 4, ctx.cw - 8, ctx.ch - 8
    local GAP = 6
    local wN = math.min(WW, (HH - GAP) / (self.CC_H / self.CC_W + self.LOSS_H / self.LOSS_W))
    local ih = wN * self.CC_H / self.CC_W
    local w = math.min(WW, wN * 1.12)   -- comme le modèle : le schéma remplit la largeur (au plus 12 % plus large)
    local x0, y0 = X0 + (WW - w) * 0.5, Y0
    ctx.rect(X0, Y0, WW, ih, CC_WHITE)
    local file = caseImg("as_case_combine")
    ctx.image(x0, y0, w, ih, ctx.rec == nil and AS_TerminalTools ~= nil and AS_TerminalTools:overlay(file) or nil, "img_as_case_combine", file)
    local sx, sy = w / self.CC_W, ih / self.CC_H
    local function box(k)
        local b = self.CC_BOX[k]
        return x0 + b[1] * sx, y0 + b[2] * sy, (b[3] - b[1]) * sx, (b[4] - b[2]) * sy
    end
    local hot = ctx.hotspot or ctx.button
    local info = (AS_TerminalMachine ~= nil and AS_TerminalMachine.rhSettingInfo ~= nil) and AS_TerminalMachine:rhSettingInfo(v) or nil
    if info == nil or info[self.ccSel or ""] == nil then self.ccSel = nil end
    -- case du schéma (déjà dessinée dans l'image) : texte noir gras centré ; choisie = bord bleu épais
    local function label(k, txt, action, sel)
        local x, y, bw, bh = box(k)
        if action ~= nil then hot(x, y, bw, bh, action) end
        if sel then
            local t = 2.5
            ctx.rect(x - 1, y - 1, bw + 2, t, BLUE_CASE); ctx.rect(x - 1, y + bh - t + 1, bw + 2, t, BLUE_CASE)
            ctx.rect(x - 1, y - 1, t, bh + 2, BLUE_CASE); ctx.rect(x + bw - t + 1, y - 1, t, bh + 2, BLUE_CASE)
        end
        ctx.text(x + bw * 0.5, y + bh * 0.5 + bh * 0.25, math.max(10, bh * 0.68), txt, CC_DARK, RenderText.ALIGN_CENTER, true, bw - 8)
    end
    local function plain(k, txt)
        local x, y, bw, bh = box(k)
        ctx.text(x + bw * 0.5, y + bh * 0.5 + bh * 0.25, math.max(10, bh * 0.68), txt, CC_DARK, RenderText.ALIGN_CENTER, true, bw - 6)
    end
    -- bouton rond en haut à gauche : page complète Realistic Harvesting
    if r ~= nil then hot(x0 + 14 * sx, y0 + 18 * sy, 64 * sx, 64 * sy, "page_rh") end
    -- charge moteur (barre du haut) : remplie à la vraie valeur, % au milieu
    local load = r ~= nil and r.load or (d.load ~= nil and d.load * 100 or nil)
    do
        local x, y, bw, bh = box("load")
        ctx.rect(x + 2, y + 2, bw - 4, bh - 4, CC_WHITE)
        local f = math.max(0, math.min(1, (load or 0) / 100))
        ctx.rect(x + 2, y + 2, (bw - 4) * f, bh - 4, (load or 0) > 105 and CC_STATE.bad or BLUE_CASE)
        ctx.text(x + bw * 0.5, y + bh * 0.5 + bh * 0.25, math.max(10, bh * 0.62), load ~= nil and string.format("%d%%", math.floor(load + 0.5)) or "-",
            f >= 0.56 and CC_WHITE or CC_DARK, RenderText.ALIGN_CENTER, true, bw * 0.4)
    end
    -- rendement, débit, humidité (en haut à droite)
    plain("yield", r ~= nil and r.yield ~= nil and string.format("%.1f t/ha", r.yield) or "- t/ha")
    plain("tph", m.tph ~= nil and string.format("%.1f t/h", m.tph) or "- t/h")
    plain("moist", r ~= nil and r.moisture ~= nil and r.moisture > 0 and string.format("%.1f%%", r.moisture) or "- %")
    label("rpm", d.rpm ~= nil and string.format("%d RPM", math.floor(d.rpm + 0.5)) or "-")
    -- goulotte de vidange (cliquable)
    if m.pipe ~= nil then label("pipe", m.pipe and T("m_out") or T("m_in"), "pipe", false) else label("pipe", "-") end
    -- réglages RH sur leur case ; charge visée dans la case C ; culture dans la case D
    local used = {}
    local free = { "C", "D" }
    if info ~= nil then
        for _, e in ipairs(info.list) do
            local k = self.CC_BOX[e.p] ~= nil and e.p or nil
            if k == nil and #free > 0 then k = table.remove(free, 1) end
            if k ~= nil then
                used[k] = true
                label(k, e.shown, "cc_sel_" .. e.p, self.ccSel == e.p)
            end
        end
    end
    for _, k in ipairs({ "rotor", "feeder", "fan", "upperSieve", "lowerSieve" }) do
        if not used[k] then label(k, "-") end
    end
    if #free > 0 then label(table.remove(free, 1), m.crop or "-") end
    if #free > 0 then
        local p = m.tank ~= nil and m.tank.cap > 0 and m.tank.level / m.tank.cap or nil
        label(table.remove(free, 1), p ~= nil and string.format("%d%%", math.floor(p * 100 + 0.5)) or "-")
    end
    -- broyeur / andain (cliquable)
    if m.swath ~= nil then label("swath", m.swath and T("m_swathOn") or T("m_chopOn"), m.canSwath and "m_swath" or nil, false)
    else label("swath", "-") end

    -- bas : les entonnoirs de pertes du vrai terminal, remplis à la vraie perte
    local yb = y0 + ih + GAP
    local hb = Y0 + HH - yb
    local lwN = math.min(wN, hb * self.LOSS_W / self.LOSS_H)
    local lh = lwN * self.LOSS_H / self.LOSS_W
    local lw = math.min(w, lwN * 1.12)
    local lx, ly = x0 + (w - lw) * 0.5, yb + (hb - lh) * 0.5
    ctx.rect(X0, yb, WW, hb, CC_WHITE)
    local lfile = caseImg("as_case_losses")
    ctx.image(lx, ly, lw, lh, ctx.rec == nil and AS_TerminalTools ~= nil and AS_TerminalTools:overlay(lfile) or nil, "img_as_case_losses", lfile)
    local lsx, lsy = lw / self.LOSS_W, lh / self.LOSS_H
    local LINE = { 0.08, 0.08, 0.08, 1 }
    if r ~= nil then
        local function lossCol(x)
            return (x or 0) >= 2 and CC_STATE.bad or ((x or 0) >= 1 and CC_STATE.warn or CC_STATE.ok)
        end
        local function rowAt(rows, y)
            local best = rows[1]
            for _, rw in ipairs(rows) do if math.abs(rw[1] - y) < math.abs(best[1] - y) then best = rw end end
            return best
        end
        -- entonnoir : moitié gauche / droite (ou entier), rempli du bas jusqu'à la perte (3 % = plein)
        local function funnel(rows, half, val)
            local f = math.max(0, math.min(1, (tonumber(val) or 0) / 3))
            if f <= 0 then return end
            local top, bot = rows[1][1] - 2, rows[#rows][1] + 2
            local yFill = bot - f * (bot - top)
            local col = lossCol(val)
            for _, rw in ipairs(rows) do
                local ya, yz = rw[1] - 2, rw[1] + 2
                if yz > yFill then
                    local xl, xr = rw[2] + 3, rw[3] - 3
                    local mid = (rw[2] + rw[3]) * 0.5
                    if half == "L" then xr = mid - 4 elseif half == "R" then xl = mid + 4 end
                    local y1 = math.max(ya, yFill)
                    ctx.rect(lx + xl * lsx, ly + y1 * lsy, (xr - xl) * lsx, (yz - y1) * lsy + 0.5, col)
                end
            end
            -- traits du dessin remis par-dessus le remplissage
            for _, yl in ipairs({ 48, 97, 162, 227 }) do
                if yl > yFill then
                    local rw = rowAt(rows, yl)
                    local xl, xr = rw[2], rw[3]
                    local mid = (xl + xr) * 0.5
                    if half == "L" then xr = mid elseif half == "R" then xl = mid end
                    ctx.rect(lx + xl * lsx, ly + (yl - 1.5) * lsy, (xr - xl) * lsx, 3 * lsy, LINE)
                end
            end
            if half ~= nil then
                local mid = (rows[#rows][2] + rows[#rows][3]) * 0.5
                ctx.rect(lx + (mid - 4) * lsx, ly + math.max(top, yFill) * lsy, 8 * lsx, (bot - math.max(top, yFill)) * lsy, LINE)
            end
        end
        local F = self.LOSS_FUNNELS
        funnel(F[1], "L", r.lossOver); funnel(F[1], "R", r.lossMoist)
        funnel(F[2], "L", r.lossSet); funnel(F[2], "R", r.lossWear)
        funnel(F[3], nil, r.lossSlope)
        -- jauge de droite : pertes totales, un repère qui monte avec la perte (5 % = en haut)
        local tf = math.max(0, math.min(1, (r.loss or 0) / 5))
        local gh = 40
        local yc = 338 - gh * 0.5 - tf * (288 - gh)
        ctx.rect(lx + 1990 * lsx, ly + (yc - gh * 0.5) * lsy, 52 * lsx, gh * lsy, lossCol((r.loss or 0) * 0.6))
    else
        ctx.text(X0 + WW * 0.5, yb + 22, 12, T("m_noRh"), CC_DARK, RenderText.ALIGN_CENTER, true, WW - 16)
    end
    -- fenêtre de réglage (case choisie) : nom, valeur, état, - / +, fermer
    local e = info ~= nil and self.ccSel ~= nil and info[self.ccSel] or nil
    if e ~= nil then
        local pw, ph = 210, 112
        local px, py = x0 + (w - pw) * 0.5, y0 + (ih - ph) * 0.5
        ctx.button(px, py, pw, ph, "cc_none")
        ctx.rect(px, py, pw, ph, BLUE_CASE)
        ctx.rect(px + 2.5, py + 2.5, pw - 5, ph - 5, CC_WHITE)
        ctx.text(px + pw * 0.5, py + 20, 11, e.label, CC_DARK, RenderText.ALIGN_CENTER, true, pw - 44)
        ctx.text(px + pw * 0.5, py + 44, 18, e.shown, BLUE_CASE, RenderText.ALIGN_CENTER, true, pw - 20)
        if e.status ~= "" then ctx.text(px + pw * 0.5, py + 60, 10, e.status, CC_STATE[e.state] or CC_DARK, RenderText.ALIGN_CENTER, true, pw - 20) end
        ctx.button(px + pw - 30, py + 6, 24, 22, "cc_close")
        ctx.rect(px + pw - 30, py + 6, 24, 22, CC_WHITE)
        ctx.text(px + pw - 18, py + 23, 14, "X", CC_DARK, RenderText.ALIGN_CENTER, true)
        local bh2, bw2 = 34, (pw - 18) * 0.5
        local byb = py + ph - bh2 - 6
        ctx.button(px + 6, byb, bw2, bh2, "rh_-_" .. e.p)
        ctx.rect(px + 6, byb, bw2, bh2, BLUE_CASE)
        ctx.text(px + 6 + bw2 * 0.5, byb + bh2 * 0.5 + 8, 22, "-", CC_WHITE, RenderText.ALIGN_CENTER, true)
        ctx.button(px + 12 + bw2, byb, bw2, bh2, "rh_+_" .. e.p)
        ctx.rect(px + 12 + bw2, byb, bw2, bh2, BLUE_CASE)
        ctx.text(px + 12 + bw2 * 1.5, byb + bh2 * 0.5 + 8, 22, "+", CC_WHITE, RenderText.ALIGN_CENTER, true)
    end
end

-- (02/11) Moissonneuse Case IH : l'écran ENTIER est l'image 1 (barre du haut, colonne, schéma, entonnoirs, barre du bas),
-- nettoyée de ses chiffres ; seules les vraies valeurs sont écrites par-dessus, aux places de l'image.
AS_Terminal.CMB_W, AS_Terminal.CMB_H = 1290, 733
AS_Terminal.CMB_BOX = {   -- cases de valeurs de l'image (pixels de l'image 1290 x 733)
    rotor = { 461, 163, 591, 199 }, C = { 541, 284, 666, 320 }, D = { 739, 284, 840, 320 }, upperSieve = { 914, 291, 1020, 327 },
    swath = { 1106, 307, 1241, 343 }, feeder = { 300, 377, 431, 413 }, lowerSieve = { 888, 380, 1004, 418 },
    pipe = { 1129, 399, 1269, 436 }, fan = { 538, 432, 672, 468 },
}
AS_Terminal.CMB_COL = { 6, 82, 270, 714 }          -- colonne de gauche (image 804 x 1956 collée là)
AS_Terminal.CMB_FUN = { 290, 486, 0.455 }          -- entonnoirs (image 2172 x 360 collée là, échelle)
-- touches de l'image : barre du haut et onglets du bas
AS_Terminal.CMB_HOT = {
    { 22, 10, 84, 70, "stop" }, { 98, 10, 160, 70, "page_tractor" }, { 176, 10, 238, 70, "page_tractor" },
    { 258, 10, 328, 72, "lift" }, { 352, 10, 432, 72, "guide" }, { 560, 10, 616, 70, "page_home" }, { 838, 10, 890, 70, "close" },
    { 297, 97, 363, 163, "page_rh" },
}
AS_Terminal.CMB_TABS = { { 284, 380 }, { 382, 478 }, { 480, 576 }, { 578, 672 }, { 674, 768 }, { 770, 866 }, { 868, 964 } }
-- (02/11) onglets du bas des images : nos pages,
-- avec leur nom écrit dessus et un trait bleu sur la page ouverte
function AS_Terminal:caseImgTabs(ctx, d, v, tabs, y0, y1, PX, PY, PW, opt)
    local hot = ctx.hotspot or ctx.button
    -- (02/11 soir, image telle quelle) opt.noLabel = les noms RUN 1..7 de l'image restent,
    -- seul le trait bleu de l'onglet ouvert est dessiné, à la place et à la couleur de celui de l'image
    local noLabel = opt ~= nil and opt.noLabel
    local lineY0, lineY1 = opt ~= nil and opt.line ~= nil and opt.line[1] or nil, opt ~= nil and opt.line ~= nil and opt.line[2] or nil
    -- (02/11) les onglets du vrai terminal (la photo PERF2) : PERF1, PERF2, Carte, Relevage, Caméra, GPS, Isobus
    local fp = AS_TerminalFp ~= nil and AS_TerminalFp:available(v)
    -- (03/11) « Carte » devient « GPS » (carte + colonne Courseplay) ; l'ancien onglet GPS = icône FarmPilot
    -- quand FarmPilot tourne sur ce tracteur, sinon rien
    local list = {
        { "page_tractor", "PERF1" }, { "page_count", "PERF2" }, { "guide", "GPS" }, { "page_hitch", T("c_tabHitch") },
        { "page_cam", T("c_tabCam") }, { fp and "page_fp" or false, fp and "FarmPilot" or "" }, { "page_tool", "Isobus" },   -- (03/11 21:05) Caméra = page caméra en grand -- (03/11) onglet 6 = FarmPilot (nom écrit) quand il tourne, sinon vide
    }
    for i, tb in ipairs(tabs) do
        local e = list[i]
        if e == nil then break end
        local x, w = PX(tb[1]), PW(tb[2] - tb[1])
        local y, h = PY(y0), PY(y1 - y0)
        if e[1] ~= false then
            hot(x, y, w, h, e[1])
            -- (03/11 soir) Relevage = sous-page « Relevage AR / AV » de l'accueil
            local hitchSub = self.page == "home" and (self.homeSub == "hitch_r" or self.homeSub == "hitch_f")
            local active
            if e[1] == "page_hitch" then active = hitchSub
            elseif e[1] == "page_home" then active = self.page == "home" and not hitchSub
            else active = ("page_" .. self.page) == e[1] or (e[1] == "guide" and (self.page == "gps" or self.page == "cp")) end
            if active then
                if opt ~= nil and opt.lineImg ~= nil then
                    -- (03/11) le trait = morceau de l'image (onglet RUN 3), pas un rectangle
                    local fi = caseImg(opt.lineImg)
                    ctx.image(x, PY(lineY0), w, PY(lineY1 - lineY0), ctx.rec == nil and AS_TerminalTools ~= nil and AS_TerminalTools:overlay(fi) or nil, "img_" .. opt.lineImg, fi)
                elseif lineY0 ~= nil then ctx.rect(x, PY(lineY0), w - PW(5), PY(lineY1 - lineY0), CASE_TAB_IMG_LINE)
                else ctx.rect(x + 2, y + 2, w - 4, 3, CASE_TAB_LINE) end
            end
            -- (03/11) l'icône FarmPilot était encore dessinée : onglet 6 = le nom écrit, rien d'autre
            if opt ~= nil and opt.caseFont then   -- (03/11 soir) nom en direct, police Case
                if e[2] ~= "" then caseWrite(ctx, x + w * 0.5, PY(opt.caseFont), PY(26), e[2], "wh", RenderText.ALIGN_CENTER, w - PW(12)) end
            elseif not noLabel then ctx.text(x + w * 0.5, y + h * 0.5 + 5, 11, e[2], { 1, 1, 1, 1 }, RenderText.ALIGN_CENTER, true, w - 6) end
        end
    end
end
function AS_Terminal:caseCombScreen(d, ctx, v, Wp, Hp)
    local IW, IH = self.CMB_W, self.CMB_H
    local kx, ky = Wp / IW, Hp / IH
    local function PX(x) return x * kx end
    local function PY(y) return y * ky end
    local function PW(w) return w * kx end
    local file = caseImg("as_case_cmbscreen")
    ctx.image(0, 0, Wp, Hp, ctx.rec == nil and AS_TerminalTools ~= nil and AS_TerminalTools:overlay(file) or nil, "img_as_case_cmbscreen", file)
    self.headerBox = { x = ctx.X(0), y = ctx.Y(PY(76)), w = ctx.sx(PX(240)), h = ctx.sy(PY(76)) }
    local DK, WH, BL = { 0.10, 0.12, 0.15, 1 }, { 1, 1, 1, 1 }, BLUE_CASE
    local BAR = { 0.0, 0.42, 0.75, 1 }
    local m = d.mach
    local r = m.rh
    local hot = ctx.hotspot or ctx.button
    for _, h in ipairs(self.CMB_HOT) do
        if h[5] ~= "page_fp" or (AS_TerminalFp ~= nil and AS_TerminalFp:available(v)) then
            hot(PX(h[1]), PY(h[2]), PW(h[3] - h[1]), PY(h[4] - h[2]), h[5])
        end
    end
    self:caseImgTabs(ctx, d, v, self.CMB_TABS, 668, 716, PX, PY, PW)
    -- heure
    ctx.text(PX(762), PY(52), 20, fmtClock(), WH, RenderText.ALIGN_CENTER, true, PX(140))
    -- colonne de gauche (mêmes places que sur l'image)
    do
        local c = self.CMB_COL
        local cx, cy = PX(c[1]), PY(c[2])
        local k, kk = PX(c[3] - c[1]) / 804, PY(c[4] - c[2]) / 1956
        local function tx(x, y, size, str, col, align, maxW)
            ctx.text(cx + x * k, cy + y * kk, size, str, col or DK, align, true, maxW ~= nil and maxW * k or nil)
        end
        tx(270, 160, 22, string.format("%.1f", math.abs(d.speed or 0)), BL, nil, 300)
        tx(272, 222, 9, "km/h", { 0.40, 0.42, 0.45, 1 }, nil, 200)
        if d.cruise ~= nil and d.cruise ~= 0 and d.cruiseSpeed ~= nil then
            tx(115, 232, 10, string.format("%.1f", d.cruiseSpeed), DK, RenderText.ALIGN_CENTER, 200)
        end
        tx(675, 158, 16, tostring(d.gear or "N"), DK, RenderText.ALIGN_CENTER, 120)
        local tp = m.tank ~= nil and m.tank.cap > 0 and m.tank.level / m.tank.cap or nil
        tx(418, 368, 13, tp ~= nil and string.format("%d%%", math.floor(tp * 100 + 0.5)) or "-", DK, RenderText.ALIGN_CENTER, 300)
        local function gauge(x1, x2, f)
            if f == nil then return end
            f = math.max(0, math.min(1, f))
            local col = f < 0.1 and C.red or BAR
            local n = 21
            for i = 0, n - 1 do
                local yy = 1099 - i * 18.3
                if (i + 1) / n <= f + 0.5 / n then ctx.rect(cx + x1 * k, cy + (yy - 7) * kk, (x2 - x1) * k, 12 * kk, col) end
            end
        end
        gauge(50, 162, d.fuel)
        gauge(208, 320, d.def)
        local slope
        if v ~= nil and v.rootNode ~= nil and localDirectionToWorld ~= nil then
            local ok, dx, dy, dz = pcall(localDirectionToWorld, v.rootNode, 0, 0, 1)
            if ok and dx ~= nil then
                local hz = math.sqrt(dx * dx + dz * dz)
                if hz > 0.01 then slope = math.abs(dy) / hz * 100 end
            end
        end
        tx(440, 1095, 18, slope ~= nil and string.format("%d%%", math.floor(slope + 0.5)) or "-", BL, RenderText.ALIGN_CENTER, 300)
        local function cell(y, title, val, unit)
            tx(285, y, 9, title, DK, nil, 500)
            tx(285, y + 105, 17, val, DK, nil, 400)
            if unit ~= nil and val ~= "-" then
                local vw = ctx.measure ~= nil and ctx.measure(17, val) or 40
                ctx.text(cx + 285 * k + vw + 4, cy + (y + 105) * kk, 10, unit, DK, nil, true)
            end
        end
        cell(1330, T("c_spreader"), m.swath ~= nil and (m.swath and T("m_swathOn") or T("m_chopOn")) or "-")
        cell(1560, T("c_coolant"), d.temp ~= nil and tostring(math.floor(d.temp + 0.5)) or "-", "°C")
        local tOut
        local env = g_currentMission ~= nil and g_currentMission.environment or nil
        local wth = env ~= nil and env.weather or nil
        if wth ~= nil and wth.getCurrentTemperature ~= nil then
            local ok, t = pcall(wth.getCurrentTemperature, wth)
            if ok and type(t) == "number" then tOut = t end
        end
        cell(1792, T("c_tempOut"), tOut ~= nil and tostring(math.floor(tOut + 0.5)) or "-", "°C")
    end
    -- schéma : charge, rendement, débit, humidité, régime, réglages RH dans leurs cases
    local load = r ~= nil and r.load or (d.load ~= nil and d.load * 100 or nil)
    do
        local f = math.max(0, math.min(1, (load or 0) / 100))
        ctx.rect(PX(625), PY(100), PX(242) * f, PY(30), (load or 0) > 105 and CC_STATE.bad or BAR)
        ctx.text(PX(746), PY(124), 15, load ~= nil and string.format("%d%%", math.floor(load + 0.5)) or "-", f >= 0.56 and WH or DK, RenderText.ALIGN_CENTER, true, PX(100))
    end
    ctx.text(PX(1190), PY(122), 15, r ~= nil and r.yield ~= nil and string.format("%.1f t/ha", r.yield) or "- t/ha", DK, RenderText.ALIGN_CENTER, true, PX(140))
    ctx.text(PX(1190), PY(166), 15, m.tph ~= nil and string.format("%.1f t/h", m.tph) or "- t/h", DK, RenderText.ALIGN_CENTER, true, PX(140))
    ctx.text(PX(1190), PY(212), 15, r ~= nil and r.moisture ~= nil and r.moisture > 0 and string.format("%.1f%%", r.moisture) or "- %", DK, RenderText.ALIGN_CENTER, true, PX(140))
    ctx.text(PX(357), PY(456), 15, d.rpm ~= nil and string.format("%d RPM", math.floor(d.rpm + 0.5)) or "-", DK, nil, true, PX(125))
    local info = (AS_TerminalMachine ~= nil and AS_TerminalMachine.rhSettingInfo ~= nil) and AS_TerminalMachine:rhSettingInfo(v) or nil
    if info == nil or info[self.ccSel or ""] == nil then self.ccSel = nil end
    local function box(k)
        local b = self.CMB_BOX[k]
        return PX(b[1]), PY(b[2]), PX(b[3] - b[1]), PY(b[4] - b[2])
    end
    local function label(k, txt, action, sel)
        local x, y, bw, bh = box(k)
        if action ~= nil then hot(x, y, bw, bh, action) end
        if sel then
            local t = 2.5
            ctx.rect(x, y, bw, t, BL); ctx.rect(x, y + bh - t, bw, t, BL)
            ctx.rect(x, y, t, bh, BL); ctx.rect(x + bw - t, y, t, bh, BL)
        end
        ctx.text(x + bw * 0.5, y + bh * 0.5 + bh * 0.25, math.max(10, bh * 0.62), txt, DK, RenderText.ALIGN_CENTER, true, bw - 8)
    end
    local used, free = {}, { "C", "D" }
    if info ~= nil then
        for _, e in ipairs(info.list) do
            local k = self.CMB_BOX[e.p] ~= nil and e.p or nil
            if k == nil and #free > 0 then k = table.remove(free, 1) end
            if k ~= nil then used[k] = true; label(k, e.shown, "cc_sel_" .. e.p, self.ccSel == e.p) end
        end
    end
    for _, k in ipairs({ "rotor", "feeder", "fan", "upperSieve", "lowerSieve" }) do if not used[k] then label(k, "-") end end
    if #free > 0 then label(table.remove(free, 1), m.crop or "-") end
    for _, k in ipairs(free) do label(k, "-") end
    if m.swath ~= nil then label("swath", m.swath and T("m_swathOn") or T("m_chopOn"), m.canSwath and "m_swath" or nil, false) else label("swath", "-") end
    if m.pipe ~= nil then label("pipe", m.pipe and T("m_out") or T("m_in"), "pipe", false) else label("pipe", "-") end
    -- entonnoirs : vraie perte (3 % = plein), jauge totale (5 % = en haut)
    if r ~= nil then
        local F0 = self.CMB_FUN
        local lx, ly, ls = PX(F0[1]), PY(F0[2]), F0[3]
        local lsx, lsy = ls * kx, ls * ky
        local LINE = { 0.08, 0.08, 0.08, 1 }
        local function lossCol(x) return (x or 0) >= 2 and CC_STATE.bad or ((x or 0) >= 1 and CC_STATE.warn or CC_STATE.ok) end
        local function rowAt(rows, y)
            local best = rows[1]
            for _, rw in ipairs(rows) do if math.abs(rw[1] - y) < math.abs(best[1] - y) then best = rw end end
            return best
        end
        local function funnel(rows, half, val)
            local f = math.max(0, math.min(1, (tonumber(val) or 0) / 3))
            if f <= 0 then return end
            local top, bot = rows[1][1] - 2, rows[#rows][1] + 2
            local yFill = bot - f * (bot - top)
            local col = lossCol(val)
            for _, rw in ipairs(rows) do
                local ya, yz = rw[1] - 2, rw[1] + 2
                if yz > yFill then
                    local xl, xr = rw[2] + 3, rw[3] - 3
                    local mid = (rw[2] + rw[3]) * 0.5
                    if half == "L" then xr = mid - 4 elseif half == "R" then xl = mid + 4 end
                    local y1 = math.max(ya, yFill)
                    ctx.rect(lx + xl * lsx, ly + y1 * lsy, (xr - xl) * lsx, (yz - y1) * lsy + 0.5, col)
                end
            end
            for _, yl in ipairs({ 48, 97, 162, 227 }) do
                if yl > yFill then
                    local rw = rowAt(rows, yl)
                    local xl, xr = rw[2], rw[3]
                    local mid = (xl + xr) * 0.5
                    if half == "L" then xr = mid elseif half == "R" then xl = mid end
                    ctx.rect(lx + xl * lsx, ly + (yl - 1.5) * lsy, (xr - xl) * lsx, 3 * lsy, LINE)
                end
            end
            if half ~= nil then
                local mid = (rows[#rows][2] + rows[#rows][3]) * 0.5
                ctx.rect(lx + (mid - 4) * lsx, ly + math.max(top, yFill) * lsy, 8 * lsx, (bot - math.max(top, yFill)) * lsy, LINE)
            end
        end
        local F = self.LOSS_FUNNELS
        funnel(F[1], "L", r.lossOver); funnel(F[1], "R", r.lossMoist)
        funnel(F[2], "L", r.lossSet); funnel(F[2], "R", r.lossWear)
        funnel(F[3], nil, r.lossSlope)
        local tf = math.max(0, math.min(1, (r.loss or 0) / 5))
        local gh = 40
        local yc = 338 - gh * 0.5 - tf * (288 - gh)
        ctx.rect(lx + 1990 * lsx, ly + (yc - gh * 0.5) * lsy, 52 * lsx, gh * lsy, lossCol((r.loss or 0) * 0.6))
    end
    -- fenêtre de réglage (case choisie) : nom, valeur, état, - / +, fermer
    local e = info ~= nil and self.ccSel ~= nil and info[self.ccSel] or nil
    if e ~= nil then
        local pw, ph = 210, 112
        local px, py = PX(782) - pw * 0.5, PY(280) - ph * 0.5
        ctx.button(px, py, pw, ph, "cc_none")
        ctx.rect(px, py, pw, ph, BL)
        ctx.rect(px + 2.5, py + 2.5, pw - 5, ph - 5, CC_WHITE)
        ctx.text(px + pw * 0.5, py + 20, 11, e.label, DK, RenderText.ALIGN_CENTER, true, pw - 44)
        ctx.text(px + pw * 0.5, py + 44, 18, e.shown, BL, RenderText.ALIGN_CENTER, true, pw - 20)
        if e.status ~= "" then ctx.text(px + pw * 0.5, py + 60, 10, e.status, CC_STATE[e.state] or DK, RenderText.ALIGN_CENTER, true, pw - 20) end
        ctx.button(px + pw - 30, py + 6, 24, 22, "cc_close")
        ctx.rect(px + pw - 30, py + 6, 24, 22, CC_WHITE)
        ctx.text(px + pw - 18, py + 23, 14, "X", DK, RenderText.ALIGN_CENTER, true)
        local bh2, bw2 = 34, (pw - 18) * 0.5
        local byb = py + ph - bh2 - 6
        ctx.button(px + 6, byb, bw2, bh2, "rh_-_" .. e.p)
        ctx.rect(px + 6, byb, bw2, bh2, BL)
        ctx.text(px + 6 + bw2 * 0.5, byb + bh2 * 0.5 + 8, 22, "-", WH, RenderText.ALIGN_CENTER, true)
        ctx.button(px + 12 + bw2, byb, bw2, bh2, "rh_+_" .. e.p)
        ctx.rect(px + 12 + bw2, byb, bw2, bh2, BL)
        ctx.text(px + 12 + bw2 * 1.5, byb + bh2 * 0.5 + 8, 22, "+", WH, RenderText.ALIGN_CENTER, true)
    end
end

-- (02/11) Tracteur Case IH, accueil, identique au réel : l'écran ENTIER est l'image « Tractor | Lights » (AFS Pro 1200), nettoyée de ses
-- chiffres ; les vraies valeurs sont écrites dessus, et les boutons de feux (1 à 7) commandent les feux.
AS_Terminal.TR_W, AS_Terminal.TR_H = 1240, 490
AS_Terminal.TR_X0, AS_Terminal.TR_X1 = 228, 1008   -- l'écran lui-même dans l'image (bandes noires autour)
AS_Terminal.TR_LAMPS = {   -- n°, feu, case du bouton sur l'image (pixels)
    { 1, "drive", 574, 267, 611, 304 }, { 2, "workF", 672, 191, 708, 228 }, { 3, "workR", 672, 345, 709, 381 },
    { 4, "workR", 777, 191, 813, 228 }, { 4, "workR", 776, 345, 813, 381 },
    { 5, "workF", 555, 176, 593, 213 }, { 5, "workF", 555, 357, 593, 394 },
    { 6, "high", 446, 234, 484, 271 }, { 7, "beacon", 728, 271, 764, 312 },
}
AS_Terminal.TR_HOT = {
    { 240, 8, 274, 44, "stop" }, { 276, 8, 308, 44, "page_tractor" }, { 312, 8, 344, 44, "page_tractor" },
    { 362, 6, 392, 46, "lift" }, { 398, 6, 456, 46, "guide" }, { 582, 8, 616, 44, "page_home" },
    { 752, 8, 790, 44, "page_tractor" }, { 808, 8, 848, 44, "page_count" }, { 872, 8, 914, 44, "page_work" },
    { 404, 58, 456, 84, "page_set" }, { 972, 56, 1000, 84, "close" },
    { 922, 92, 1008, 150, "page_set" }, { 922, 225, 1008, 295, "page_home" }, { 922, 295, 1008, 360, "page_tool" }, { 922, 360, 1008, 430, "page_work" },
}
AS_Terminal.TR_TABS = { { 390, 451 }, { 452, 513 }, { 514, 575 }, { 576, 637 }, { 638, 699 }, { 700, 761 }, { 762, 823 } }
function AS_Terminal:caseTractorScreen(d, ctx, v, Wp, Hp)
    local PX, PY, PW = self:caseTrFrame(d, ctx, v, Wp, Hp, "as_case_trscreen")
    local WH = { 1, 1, 1, 1 }
    local hot = ctx.hotspot or ctx.button
    -- feux : allumé = bouton bleu, icône et numéro blancs (éteint = le bouton de l'image)
    for _, l in ipairs(self.TR_LAMPS) do
        local x, y, w, h = PX(l[3]), PY(l[4]), PW(l[5] - l[3]), PY(l[6] - l[4])
        hot(x, y, w, h, "l_" .. l[2])
        local on = lightOn(d, l[2])
        if l[2] == "beacon" then
            -- (02/11) le 7 = gyrophare : blanc / icône orange éteint, orange / icône blanche allumé
            local OR = { 0.94, 0.47, 0.0, 1 }
            ctx.rect(x, y, w, h, on and OR or WH)
            local s = math.min(w, h) * 0.66
            caseIcon(ctx, x + w * 0.5 - s * 0.5 + w * 0.08, y + h * 0.5 - s * 0.5 + h * 0.08, s, on and "as_case_beacon_w" or "as_case_beacon_o")
            ctx.text(x + 3, y + 11, 10, tostring(l[1]), on and WH or OR, nil, true)
        elseif on then
            ctx.rect(x, y, w, h, BLUE_CASE)
            local s = math.min(w, h) * 0.66
            caseIcon(ctx, x + w * 0.5 - s * 0.5 + w * 0.08, y + h * 0.5 - s * 0.5 + h * 0.08, s, "as_case_lamp_w")
            ctx.text(x + 3, y + 11, 10, tostring(l[1]), WH, nil, true)
        end
    end
end

-- (02/11 soir) accueil du tracteur Case = l'écran « Tractor | Lights »
-- (1672 x 941) en entier ; boutons découpés : chaque feu a son icône blanche (as_case_hb_*) posée sur fond bleu quand
-- il est allumé (orange pour le gyrophare) ; l'image elle-même montre l'état éteint.
AS_Terminal.HOME_W, AS_Terminal.HOME_H = 1672, 941
-- (03/11) numéros des boutons, de gauche à droite : haut 1 2 7 4 / milieu 3 6 / bas 8 2 G 5
-- (G = gyrophare, 8 vert = pleins phares) ; le feu commandé reste celui de la position du bouton
AS_Terminal.HOME_LAMPS = {   -- n°, feu, case du bouton (pixels de l'image), icône blanche
    -- (03/11) bouton 1 = pleins phares, bouton 8 = feux de route
    { "1", "high", 441, 475, 535, 554, "as_case_hb_1" }, { "3", "workF", 806, 524, 897, 603, "as_case_hb_2" },
    { "5", "workR", 1107, 669, 1197, 751, "as_case_hb_3" }, { "4", "workR", 1109, 380, 1203, 458, "as_case_hb_4" },
    { "2", "workF", 765, 376, 858, 454, "as_case_hb_5" }, { "6", "workR", 1124, 525, 1215, 604, "as_case_hb_6a" },
    { "2", "workF", 768, 669, 860, 751, "as_case_hb_6b" }, { "7", "workF", 967, 364, 1061, 444, "as_case_hb_7" },
    { "", "beacon", 967, 685, 1060, 769, "as_case_hb_0" }, { "8", "drive", 442, 572, 537, 653, "as_case_hb_r" },
}
AS_Terminal.HOME_HOT = {     -- touches de l'image : barre du haut (grille = accueil), Menu, Mem 1 / Mem 2, X, colonne de droite, « ... »
    { 18, 6, 95, 80, "stop" }, { 105, 6, 180, 80, "page_tractor" }, { 190, 6, 275, 80, "page_tractor" },
    { 690, 6, 755, 80, "page_home" },
    { 1170, 6, 1250, 80, "page_tractor" }, { 1280, 6, 1360, 80, "page_set" }, { 1400, 6, 1490, 80, "page_work" }, { 1530, 6, 1665, 80, "guide" },
    { 356, 105, 505, 160, "page_set" }, { 1590, 100, 1660, 160, "close" },
    { 395, 236, 619, 289, "l_mem1" }, { 622, 236, 847, 289, "l_mem2" },
    { 1461, 170, 1667, 300, "page_home" }, { 1461, 305, 1667, 396, "page_set" }, { 1461, 430, 1667, 529, "page_tool" },
    -- (02/11) les 2 relevages ramènent à la page Outil ; les « ? » ouvrent le menu aide du jeu
    { 1461, 555, 1667, 641, "page_tool" }, { 1461, 675, 1667, 772, "page_tool" },
    { 890, 236, 926, 284, "help" }, { 1336, 328, 1374, 378, "help" },
    { 128, 862, 300, 905, "page_work" },
}
AS_Terminal.HOME_TABS = { { 344, 499 }, { 499, 652 }, { 652, 807 }, { 807, 962 }, { 962, 1120 }, { 1120, 1281 }, { 1281, 1443 } }


-- (03/11) tracteur New Holland, accueil = l'image
-- IntelliView 12 « Tractor | Lights » (1672 x 941) en entier, chiffres effacés (as_nh_home) et réécrits avec la police Case ;
-- feux 1 à 8 et Front Hood / High Mount cliquables (cadre bleu quand allumé, comme le Case).
AS_Terminal.NH_LAMPS = {   -- n°, feu, case du bouton (pixels de l'image)
    { "6", "drive", 445, 402, 540, 485 }, { "6", "drive", 445, 522, 540, 608 },
    { "5", "workF", 768, 280, 868, 365 }, { "5", "workF", 770, 612, 868, 697 },
    { "1", "workF", 808, 450, 905, 535 }, { "2", "workF", 958, 278, 1052, 362 }, { "3", "workF", 965, 620, 1062, 705 },
    { "8", "workR", 1084, 293, 1180, 380 }, { "8", "workR", 1098, 605, 1194, 690 },
    { "4", "workR", 1210, 322, 1306, 408 }, { "4", "workR", 1220, 590, 1316, 675 }, { "7", "workR", 1133, 450, 1228, 535 },
    { "", "drive", 384, 778, 735, 826 }, { "", "high", 737, 778, 1071, 826 },
}
AS_Terminal.NH_HOT = {
    { 22, 8, 92, 78, "stop" }, { 115, 8, 188, 78, "page_tractor" }, { 210, 8, 284, 78, "page_tractor" },
    { 730, 8, 792, 78, "page_home" }, { 1243, 8, 1313, 78, "page_tractor" }, { 1343, 8, 1418, 78, "page_work" },
    { 1448, 8, 1530, 78, "page_tool" }, { 1545, 6, 1668, 80, "guide" },
    { 366, 102, 512, 156, "page_set" }, { 1590, 100, 1662, 158, "close" },
    { 1485, 165, 1668, 197, "page_set" }, { 1485, 200, 1668, 342, "page_tool" }, { 1485, 345, 1668, 490, "page_home" },
    { 1485, 494, 1668, 640, "page_set" },
}
AS_Terminal.NH_TABS = {   -- onglets de l'image : Main, RUN 1, RUN 2, Map, RUN 4, Cam, RUN 6, RUN 7, alertes, réglages
    { 357, 492, "page_home" }, { 497, 632, "page_tractor" }, { 637, 772, "page_count" }, { 777, 912, "guide" },
    { 916, 1050, "page_work" }, { 1056, 1190, "page_cam" }, { 1195, 1330, "gps" }, { 1335, 1470, "page_tool" },
    { 1480, 1572, "page_tractor" }, { 1575, 1666, "page_set" },
}
function AS_Terminal:nhHomeScreen(d, ctx, v, Wp, Hp)
    local kx, ky = Wp / self.HOME_W, Hp / self.HOME_H
    local function PX(x) return x * kx end
    local function PY(y) return y * ky end
    local function PW(w) return w * kx end
    local function img(x, y, w, h, name)
        local f = caseImg(name)
        ctx.image(PX(x), PY(y), PW(w), PY(h), ctx.rec == nil and AS_TerminalTools ~= nil and AS_TerminalTools:overlay(f) or nil, "img_" .. name, f)
    end
    img(0, 0, self.HOME_W, self.HOME_H, "as_nh_home")
    self.headerBox = { x = ctx.X(PX(520)), y = ctx.Y(PY(90)), w = ctx.sx(PX(1000)), h = ctx.sy(PY(80)) }
    local hot = ctx.hotspot or ctx.button
    for _, h in ipairs(self.NH_HOT) do hot(PX(h[1]), PY(h[2]), PW(h[3] - h[1]), PY(h[4] - h[2]), h[5]) end
    -- onglets : trait bleu sur l'onglet ouvert (accueil = Main)
    local fp = AS_TerminalFp ~= nil and AS_TerminalFp:available(v)
    for i, tb in ipairs(self.NH_TABS) do
        local act = tb[3]
        if act == "gps" then act = fp and "page_fp" or "guide" end
        hot(PX(tb[1]), PY(862), PW(tb[2] - tb[1]), PY(935 - 862), act)
        if i == 1 then   -- trait = sprite de l'image, pas un rectangle
            local fi = caseImg("as_case_tab_line")
            ctx.image(PX(tb[1]), PY(858), PW(tb[2] - tb[1]), PY(20), ctx.rec == nil and AS_TerminalTools ~= nil and AS_TerminalTools:overlay(fi) or nil, "img_as_case_tab_line", fi)
        end
    end
    caseWrite(ctx, PX(998), PY(58), PY(34), fmtClock(), "wh", RenderText.ALIGN_CENTER, PW(104))
    -- feux : allumé = cadre bleu autour du bouton de l'image
    for _, l in ipairs(self.NH_LAMPS) do
        local x, y, w, h = PX(l[3]), PY(l[4]), PW(l[5] - l[3]), PY(l[6] - l[4])
        hot(x, y, w, h, "l_" .. l[2])
        if lightOn(d, l[2]) then caseLampFrame(ctx, x, y, w, h, BLUE_CASE) end
    end
    -- barre du haut vivante, même règle que le Case : flèche grise vers le bas = outils baissés, grise vers
    -- le haut = relevés, VERTE dans le sens du mouvement pendant que le relevage bouge ; clic = tout relever si baissé,
    -- sinon tout baisser ; cadenas si un relevage est verrouillé. Satellite rouge, vert seulement dans un champ.
    local up = d.anyLowered == true
    local moving, movingDown = false, false
    for _, h in ipairs(d.hitches or {}) do
        if h.object ~= nil and h.own == nil and h.up ~= nil and h.up > 0.03 and h.up < 0.97 then moving = true; movingDown = h.moveDown == true end
    end
    img(318, 8, 64, 72, moving and (movingDown and "as_nh_arr_dn" or "as_nh_arr_up2") or (up and "as_nh_arr_dn2" or "as_nh_arr_up"))
    hot(PX(318), PY(8), PW(64), PY(72), up and "lift_up" or "lift_dn")
    if d.vehicle ~= nil and AS_Terminal.hitchLocked ~= nil and (not AS_Terminal:hitchLocked(d.vehicle, true) or not AS_Terminal:hitchLocked(d.vehicle, false)) then   -- (21:00) cadenas = un attelage NON actif
        img(352, 42, 36, 36, "as_case_lock")
    end
    if d.field ~= nil then img(420, 6, 112, 76, "as_nh_sat_green") end
    hot(PX(420), PY(6), PW(112), PY(76), "guide")
    -- tracteur selon le sens dans la jauge de gauche (comme le Case)
    local mv = math.abs(d.speed or 0) >= 0.3 and ((d.dir or 0) < 0 and "rev" or "fwd") or "park"
    img(37, 520, 78, 78, "as_case_tr_" .. mv)
    -- colonne de gauche : F3 vitesse maxi, F2 vitesse de travail, F1 régulateur, rapport (R10), vitesse, consommation
    local function sp(vv) return vv ~= nil and string.format("%.1f", vv) or "--.-" end
    local cruiseOn = d.cruise ~= nil and d.cruise ~= 0
    caseWrite(ctx, PX(225), PY(521), PY(29), sp(d.maxSpeed), "dk", RenderText.ALIGN_CENTER, PX(100))
    caseWrite(ctx, PX(225), PY(614), PY(29), sp(d.workSpeed), "bl", RenderText.ALIGN_CENTER, PX(100))
    caseWrite(ctx, PX(225), PY(709), PY(29), cruiseOn and sp(d.cruiseSpeed) or "--.-", cruiseOn and "bl" or "dk", RenderText.ALIGN_CENTER, PX(100))
    local gear = tostring(d.gear or "N")
    if d.cvt then gear = (d.dir or 0) < 0 and "R" or ((d.dir or 0) > 0 and "D" or "N") end
    caseWrite(ctx, PX(76), PY(718), PY(22), gear, "dk", RenderText.ALIGN_CENTER, PX(64))
    caseWrite(ctx, PX(246), PY(809), PY(39), string.format("%.2f", math.abs(d.speed or 0)), "bl", RenderText.ALIGN_RIGHT, PX(104))
    local fuelLow = d.fuel ~= nil and d.fuel * 100 < self.settings.fuelReserve
    caseWrite(ctx, PX(230), PY(405), PY(36), fmt1(d.fuelUse), fuelLow and "rd" or "dk", RenderText.ALIGN_RIGHT, PX(80))
end

-- colonne de gauche de l'écran tracteur : titre centré, valeur à gauche, unité à droite (comme l'image)
function AS_Terminal:caseTrLeft(d, ctx, PX, PY)
    local DK, GR = { 0.10, 0.12, 0.15, 1 }, { 0.30, 0.32, 0.35, 1 }
    local job = d.cnt.jobs[d.cnt.active]
    local g = d.gps
    local function cell(y, title, val, unit, col)
        ctx.text(PX(330), PY(y + 13), 10, title, GR, RenderText.ALIGN_CENTER, true, 118)
        ctx.text(PX(282), PY(y + 44), 24, val, col or DK, nil, true, 76)
        if unit ~= nil then ctx.text(PX(378), PY(y + 42), 11, unit, DK, RenderText.ALIGN_RIGHT, true, 36) end
    end
    cell(63, T("c_power"), d.load ~= nil and string.format("%d", math.floor(d.load * 100 + 0.5)) or "-", "%")
    cell(116, T("slip"), d.slip ~= nil and string.format("%d", math.floor(d.slip + 0.5)) or "-", "%", (d.slip or 0) > 25 and C.red or nil)
    cell(274, T("c_xte"), (g ~= nil and g.onLine and g.xte ~= nil) and string.format("%.1f", math.abs(g.xte) * 100) or "--.-", "cm")
    cell(379, T("c_workRate"), job.ms > 60000 and string.format("%.1f", job.ha / (job.ms / 3600000)) or "0.0", "ha/h")
    local fuelLow = d.fuel ~= nil and d.fuel * 100 < self.settings.fuelReserve
    cell(433, T("c_fuelRate"), fmt1(d.fuelUse), "l/h", fuelLow and C.red or nil)
    ctx.text(PX(242), PY(344), 10, T("c_fuelEco"), GR, nil, true, 124)
    ctx.text(PX(242), PY(370), 24, job.ha > 0.01 and string.format("%.1f", job.fuel / job.ha) or "0.0", DK, nil, true, 70)
    ctx.text(PX(350), PY(368), 11, "l/ha", DK, RenderText.ALIGN_RIGHT, true, 46)
    -- relevages : position dans les deux cases B1 / B2 (avant, arrière)
    local hf, hr
    for _, h in ipairs(d.hitches or {}) do
        if h.object ~= nil then if h.front then hf = hf or h else hr = hr or h end end
    end
    local function hpos(h) return h ~= nil and string.format("%d", math.floor((h.up or 0) * 100 + 0.5)) or "N" end
    ctx.text(PX(322), PY(184), 12, hpos(hf), DK, RenderText.ALIGN_CENTER, true, 30)
    ctx.text(PX(364), PY(184), 12, hpos(hr), DK, RenderText.ALIGN_CENTER, true, 30)
end

-- image de fond, barre du haut, onglets et colonne de gauche de l'écran tracteur (mêmes touches sur toutes les pages)
function AS_Terminal:caseTrFrame(d, ctx, v, Wp, Hp, img)
    local kx, ky = Wp / (self.TR_X1 - self.TR_X0), Hp / self.TR_H
    local function PX(x) return (x - self.TR_X0) * kx end
    local function PY(y) return y * ky end
    local function PW(w) return w * kx end
    local file = caseImg(img)
    ctx.image(0, 0, Wp, Hp, ctx.rec == nil and AS_TerminalTools ~= nil and AS_TerminalTools:overlay(file) or nil, "img_" .. img, file)
    self.headerBox = { x = ctx.X(0), y = ctx.Y(PY(50)), w = ctx.sx(PX(400)), h = ctx.sy(PY(50)) }
    local hot = ctx.hotspot or ctx.button
    for _, h in ipairs(self.TR_HOT) do
        if h[5] ~= "page_fp" or (AS_TerminalFp ~= nil and AS_TerminalFp:available(v)) then
            hot(PX(h[1]), PY(h[2]), PW(h[3] - h[1]), PY(h[4] - h[2]), h[5])
        end
    end
    self:caseImgTabs(ctx, d, v, self.TR_TABS, 452, 490, PX, PY, PW)
    ctx.text(PX(657), PY(33), 16, fmtClock(), { 1, 1, 1, 1 }, RenderText.ALIGN_CENTER, true, 90)
    self:caseTrLeft(d, ctx, PX, PY)
    return PX, PY, PW
end

-- (02/11 soir) PERF1 = l'écran 02 (1672 x 941) tel quel : 18 cases (titre + unité dans l'image), le mod
-- n'écrit que les nombres, avec sa police, calés à droite là où l'image avait les siens ; colonne de gauche idem.
AS_Terminal.P1_HOT = {
    { 20, 6, 95, 80, "stop" }, { 120, 6, 200, 80, "page_set" }, { 225, 6, 295, 80, "page_tractor" },
    { 720, 6, 780, 80, "page_home" }, { 1205, 6, 1275, 80, "page_tractor" }, { 1310, 6, 1385, 80, "page_set" },
    { 1420, 6, 1490, 80, "page_work" }, { 1520, 6, 1665, 80, "guide" }, { 1322, 846, 1445, 935, "page_set" }, { 1590, 90, 1660, 150, "close" },
}
AS_Terminal.P1_TABS = { { 342, 482 }, { 482, 622 }, { 622, 762 }, { 762, 902 }, { 902, 1042 }, { 1042, 1182 }, { 1182, 1322 } }
AS_Terminal.P1_CARDS = {   -- bord droit du nombre, bord gauche de l'unité (pixels de l'image), par rangée
    { { 555, 611 }, { 1013, 1063 }, { 1486, 1540 } }, { { 555, 607 }, { 1007, 1063 }, { 1422, 1468 } }, { { 566, 618 }, { 986, 1034 }, { 1430, 1482 } },
    { { 581, 627 }, { 990, 1035 }, { 1433, 1487 } }, { { 560, 639 }, { 978, 1041 }, { 1425, 1503 } }, { { 608, 644 }, { 992, 1065 }, { 1431, 1514 } },
}
AS_Terminal.P1_BASE = { 228, 336, 440, 541, 644, 753 }
AS_Terminal.P1_X0 = { 373, 789, 1212 }
-- valeurs des 18 cases (ordre de l'image) : celles que le jeu n'a pas (pressions, températures de boîte et d'AdBlue,
-- frein à air, tension) sont déduites de l'état du moteur, comme sur un vrai tableau de bord
function AS_Terminal:casePerf1Values(d, u)
    local on = d.motorOn
    local rpmK = 0
    if on and d.rpm ~= nil and d.maxRpm ~= nil and d.maxRpm > 900 then rpmK = math.max(0, math.min(1, (d.rpm - 800) / (d.maxRpm - 800))) end
    local tOut = d.tempOut or 15
    local hf, hr
    for _, h in ipairs(d.hitches or {}) do
        if h.object ~= nil then if h.front then hf = hf or h else hr = hr or h end end
    end
    local function hpos(h) return h ~= nil and string.format("%d", math.floor((h.up or 0) * 100 + 0.5)) or "0" end
    local function i0(x) return x ~= nil and string.format("%d", math.floor(x + 0.5)) or "0" end
    local function f1(x) return x ~= nil and string.format("%.1f", x) or "0.0" end
    -- (étape 61) valeurs converties selon les réglages du joueur (gallons, Fahrenheit) quand les unités sont en direct
    local function tC(x) return (u ~= nil and x ~= nil) and u.degC(x) or x end
    local function vL(x) return (u ~= nil and x ~= nil) and u.l(x) or x end
    local pto = d.ptoRpm or 0
    return {
        i0((d.load or 0) * 100), i0(vL(d.fuelL)), f1(d.opHours),
        f1(on and (1.5 + 3.0 * rpmK) or 0), f1(vL(d.fuelUse)), i0(tC(tOut + (on and 6 or 0))),
        i0(tC(d.temp)), hpos(hr), i0((d.def or 0) * 100),
        i0(tC(on and ((d.temp or tOut) - 8) or tOut)), hpos(hf), i0(tC(tOut + (on and 12 or 0))),
        i0(on and (16 + 4 * rpmK) or 0), i0(d.slip), f1(on and 7.8 or 0),
        f1(on and 14.1 or 12.4), i0(d.ptoR and pto or 0), i0(d.ptoF and pto or 0),
    }
end

-- (02/11) PERF1 = page INFO : la grille du vrai terminal (la photo),
-- 18 cases avec nos valeurs (pixels de l'écran recadré 780 x 490)
AS_Terminal.PERF1_CARDS = { { 190, 91, 370, 140 }, { 385, 91, 565, 140 }, { 576, 91, 757, 140 }, { 190, 149, 370, 198 }, { 385, 149, 565, 198 }, { 576, 149, 757, 198 },
    { 190, 208, 370, 257 }, { 385, 208, 565, 257 }, { 576, 208, 757, 257 }, { 190, 267, 370, 315 }, { 385, 267, 565, 315 }, { 576, 267, 757, 315 },
    { 190, 325, 370, 374 }, { 385, 325, 565, 374 }, { 576, 325, 757, 374 }, { 190, 384, 370, 433 }, { 385, 384, 565, 433 }, { 576, 384, 757, 433 } }
function AS_Terminal:caseTractorPerf1(d, ctx, v, Wp, Hp)
    local PX, PY, PW = self:caseTrFrame(d, ctx, v, Wp, Hp, "as_case_perf1")
    local DK, GR = { 0.10, 0.12, 0.15, 1 }, { 0.30, 0.32, 0.35, 1 }
    local hot = ctx.hotspot or ctx.button
    hot(PX(980), PY(56), PW(28), PY(28), "close")
    local cells = self:caseInfoCells(d)
    for i, c in ipairs(self.PERF1_CARDS) do
        local e = cells[i]
        if e == nil then break end
        local x0, y0, x1, y1 = PX(c[1] + self.TR_X0), PY(c[2]), PX(c[3] + self.TR_X0), PY(c[4])
        local tx0 = x0 + PW(50)
        ctx.text((tx0 + x1) * 0.5, y0 + 13, 9, e[2], GR, RenderText.ALIGN_CENTER, true, x1 - tx0 - 4)
        ctx.text((tx0 + x1) * 0.5 - (e[4] ~= nil and 10 or 0), y1 - 8, 19, e[3], e[5] or DK, RenderText.ALIGN_CENTER, true, x1 - tx0 - 40)
        if e[4] ~= nil then ctx.text(x1 - 6, y1 - 9, 10, e[4], DK, RenderText.ALIGN_RIGHT, true, 40) end
    end
end

-- (02/11 soir) CARTE = l'écran 13 (1774 x 887) : cadre de l'image (barre du haut, colonne de gauche, barre
-- d'outils de droite, onglets) et NOTRE carte vivante (page GPS, sans ses touches) dans la zone de la carte ; les 5 boutons
-- flottants de l'image sont redessinés par-dessus (découpés), le cap est écrit dans la boussole.
AS_Terminal.MAP_W, AS_Terminal.MAP_H = 1774, 887
AS_Terminal.MAP_BOX = { 356, 93, 1432, 788 }   -- (03/11) carte réduite : colonne Courseplay à droite
AS_Terminal.MAP_HOT = {
    { 25, 6, 100, 80, "stop" }, { 120, 6, 195, 80, "page_set" }, { 225, 6, 300, 80, "page_tractor" },
    { 755, 6, 820, 80, "page_home" }, { 1305, 6, 1375, 80, "page_tractor" }, { 1415, 6, 1500, 80, "page_set" },
    { 1530, 6, 1605, 80, "page_work" }, { 1615, 6, 1770, 80, "guide" },
}
AS_Terminal.MAP_TABS = { { 356, 499 }, { 504, 645 }, { 649, 790 }, { 793, 933 }, { 937, 1076 }, { 1080, 1219 }, { 1223, 1361 } }
AS_Terminal.MAP_BTN = {   -- (03/11) gauche de la carte : compas (degrés), vue, +, - ; image, case (pixels), commande
    { "as_case_mb_compass", 372, 103, 461, 206, nil }, { "as_case_mb_target", 478, 103, 555, 186, "gps_view" },
    { "as_case_mb_plus", 372, 219, 459, 306, "gps_zoomIn" }, { "as_case_mb_minus", 372, 320, 459, 407, "gps_zoomOut" },
}

-- (02/11 soir) PERF2 = l'écran 08 (1672 x 941) tel quel : 6 cases du centre (heures, débit moyen, carburant du
-- compteur, carburant total, l/ha, durée) + colonne de gauche (charge, patinage, relevages, écart GPS, l/ha, ha/h, l/h instantanés),
-- écrits avec sa police là où l'image avait ses nombres. Engrenage de « Conso. moy. carburant » = remise à zéro du compteur,
-- engrenage de « Conso carburant » (gauche) = autre compteur. Le panneau de droite (débits, tempo, caméra) reste l'image.
AS_Terminal.P2_HOT = {
    { 27, 6, 100, 80, "stop" }, { 120, 6, 187, 80, "page_set" }, { 213, 6, 280, 80, "page_tractor" },
    { 747, 6, 813, 80, "page_home" }, { 1253, 6, 1320, 80, "page_tractor" }, { 1360, 6, 1427, 80, "page_set" },
    { 1467, 6, 1533, 80, "page_work" }, { 1547, 6, 1667, 80, "guide" },
    { 796, 634, 858, 692, "reset" }, { 280, 632, 336, 684, "jobnext" },
}
AS_Terminal.P2_TABS = { { 353, 477 }, { 479, 602 }, { 604, 726 }, { 727, 850 }, { 852, 975 }, { 977, 1100 }, { 1102, 1228 } }
local function fr1(x) return (string.format("%.1f", x or 0):gsub("%%.", ",")) end

-- (03/11 soir) étape 61 : plus AUCUN texte dans
-- les images, noms ET unités écrits en direct ; unités et valeurs selon les réglages du jeu (miles / Fahrenheit /
-- acres). Tout est protégé : si une fonction du jeu manque, on reste en métrique. LIVE_TEXT = true quand les images
-- sans texte sont en place (sinon les unités des images restent et les valeurs restent métriques).
AS_Terminal.LIVE_TEXT = true   -- (03/11 21:00) images sans texte en place
local function i18n(name, ...)
    local f = g_i18n ~= nil and g_i18n[name] or nil
    if f == nil then return nil end
    local ok, r = pcall(f, g_i18n, ...)
    if ok then return r end
    return nil
end
local function i18nNum(name, x)
    local r = i18n(name, x)
    if type(r) == "number" then return r end
    return x
end
local function unitsOf()
    if not AS_Terminal.LIVE_TEXT then return nil end
    local u = {}
    u.speed = i18n("getSpeedMeasuringUnit") or "km/h"
    u.temp = i18n("getTemperatureUnit") or "°C"
    u.vol = i18n("getFluidUnit", false) or i18n("getVolumeUnit", false) or "L"
    if u.vol == "l" then u.vol = "L" end
    u.area = i18n("getAreaUnit", false) or "ha"
    local dist = i18n("getMeasuringUnit", false) or "m"
    -- (04/11) en métrique, « -60 in » s'affichait : n'est impérial QUE ce qui l'est vraiment
    -- (pieds / yards, ou vitesse en mph), pas tout ce qui diffère de « m » (texte traduit, nom long...)
    local dl, sl = tostring(dist):lower(), tostring(u.speed):lower()
    u.imperial = dl == "ft" or dl == "yd" or dl:find("feet", 1, true) ~= nil or dl:find("foot", 1, true) ~= nil
        or dl:find("fuß", 1, true) ~= nil or dl:find("pied", 1, true) ~= nil or sl:find("mph", 1, true) ~= nil
    if not AS_Terminal.unitsLogged then
        AS_Terminal.unitsLogged = true
        log("unités du joueur : distance « %s », vitesse « %s » -> %s", tostring(dist), tostring(u.speed), u.imperial and "impérial" or "métrique")
    end
    u.cm = u.imperial and "in" or "cm"
    u.kmh = function(x) return i18nNum("getSpeed", x) end
    u.degC = function(x) return i18nNum("getTemperature", x) end
    u.l = function(x) local r = i18n("getFluid", x); if type(r) == "number" then return r end return i18nNum("getVolume", x) end
    u.ha = function(x) return i18nNum("getArea", x) end
    u.cmv = function(x) return u.imperial and x * 0.3937 or x end
    u.lha = function(x) local a = u.ha(1); return a > 0 and u.l(x) / a or x end   -- l/ha -> gal/ac
    return u
end
AS_Terminal.unitsOf = unitsOf
-- nom d'une case écrit en direct (centré ou aligné à gauche), police Case
local function liveLabel(ctx, PX, PY, PW, x, base, h, key, set, maxW, left)
    caseWrite(ctx, PX(x), PY(base), PY(h), T(key), set or "dk", left and RenderText.ALIGN_LEFT or RenderText.ALIGN_CENTER, PW(maxW))
end

-- ===================================================================================================================
-- (03/11) MÉTHODE 4 BLOCS. Bloc 1 (barre du haut) et bloc 3 (onglets) = châssis fixe pris sur l'écran 05 ;
-- bloc 2 (colonne de gauche) = type A (boîte tracteur, base = écran 02) ou type B (cases, base = écran 08) ; bloc 4 (centre)
-- = une image par page, toujours posée au même endroit (345,94 - 1669,853). Les valeurs sont écrites avec sa police,
-- les icônes qui changent sont les icônes découpées (sprites). Repères en pixels de l'écran 1672 x 941.
-- ===================================================================================================================
AS_Terminal.B4 = { 345, 94, 1324, 759 }
AS_Terminal.CHASSIS_HOT = {   -- bloc 1 : STOP, alerte, info, grille = accueil, compteur, réglages, outil, GPS ; cloche = réglages
    { 18, 6, 95, 80, "stop" }, { 105, 6, 180, 80, "page_tractor" }, { 190, 6, 275, 80, "page_tractor" },
    { 690, 6, 755, 80, "page_home" }, { 1170, 6, 1250, 80, "page_tractor" }, { 1280, 6, 1360, 80, "page_set" },
    { 1400, 6, 1490, 80, "page_work" }, { 1530, 6, 1665, 80, "guide" }, { 1580, 858, 1662, 934, "page_set" },
}
-- type de bloc 2 par page = celui de l'écran qui lui correspond (02, 05, 13 = A ; 07, 08, 12 = B)
AS_Terminal.B2_TYPE = { count = "B", fp = "B", tool = "B" }
AS_Terminal.B2A_LAMPS = { { 45, "drive" }, { 97, "workF" }, { 150, "workR" }, { 202, "beacon" } }   -- x du centre (bloc 2), feu
AS_Terminal.B2B_LAMPS = { { 52, "drive", "bleu" }, { 131, "workF", "jaune" }, { 208, "workR", "jaune" }, { 286, "beacon", "rouge" } }
local BLUE_GAUGE = { 0.0, 0.47, 0.85, 1 }
local B4_WHITE = { 1, 1, 1, 1 }
local CASE_BTN_DK = { 0.30, 0.32, 0.36, 1 }
local CASE_GAUGE_BG = { 0.82, 0.83, 0.85, 1 }

local function caseHitches(d)
    local hf, hr
    for _, h in ipairs(d.hitches or {}) do
        -- un outil qui se baisse lui-même passe avant un 3 points vide
        if h.front then
            if hf == nil or (h.own ~= nil and hf.object == nil) then hf = h end
        elseif hr == nil or (h.own ~= nil and hr.own == nil) then hr = h end
    end
    return hf, hr
end
-- (04/11) hauteur du relevage : levé = 100 %, en bas = 0 % (comme AUTO PdF)
local function hitchPct(h) return (h ~= nil and h.object ~= nil) and string.format("%d", math.floor((h.up or 0) * 100 + 0.5)) or "N" end
-- (03/11) réglages gardés par modèle de tracteur : verrous des relevages AV / AR, fonctions des 4 télécommandes
function AS_Terminal:vehPrefs(v, create)
    if v == nil then return nil end
    local key = (AS_TerminalTablet ~= nil and AS_TerminalTablet.modelKeyOf ~= nil) and AS_TerminalTablet.modelKeyOf(v) or posKey(v, false)
    local p = self.positions[key]
    if p == nil and create then p = { x = 0, y = 0, z = 0, name = vehicleName(v) }; self.positions[key] = p end
    return p
end
-- (03/11) Verrouillé = actif, Déverrouillé = non actif : si actif, la flèche de levée générale du bloc 1
-- l'actionne ; si l'un des deux est inactif, la flèche ne marche que pour l'autre. Défaut = actif.
function AS_Terminal:hitchLocked(v, front)
    local p = self:vehPrefs(v)
    -- (03/11 21:39) lu séparément : avec « front and p.lockF or p.lockR », un AV jamais réglé (nil) prenait la valeur de l'AR
    local val
    if p ~= nil then if front then val = p.lockF else val = p.lockR end end
    return val ~= 0
end
-- (03/11) chaque case = une fonction ET l'état voulu (ex. relevage Levé + entraînement Allumé) ; le bouton de la télécommande met tout dans ces états d'un coup
-- (plus de bascule ni de ▲ / ▼ : on sait toujours ce qui va se passer)
AS_Terminal.REMOTE_FNS = { "none", "lift_up", "lift_dn", "on_on", "on_off", "fold_in", "fold_out", "tip_on", "tip_off", "cover_close", "cover_open" }
AS_Terminal.REMOTE_COL = { "vert", "bleu", "jaune", "rouge" }   -- (03/11) l'ordre des mini-manettes
AS_Terminal.REMOTE_SLOTS = 3                                      -- jusqu'à 3 fonctions par bouton
AS_Terminal.REMOTE_OLD = { lift = "lift_dn", on = "on_on", fold = "fold_out", tipper = "tip_on", cover = "cover_open" }   -- réglages d'avant (sans état)
local REMOTE_OK = {}
for _, f in ipairs(AS_Terminal.REMOTE_FNS) do REMOTE_OK[f] = true end
-- fonctions de chaque télécommande : { { "lift_dn", "on_on" }, {}, {}, {} } ; gardé "lift_dn+on_on,,," dans rem
-- (05/11) 6 fonctions : 1 à 4 = Fonctions du Case / NH / Claas et V1 à V4 du Massey ; 5, 6 = FV1, FV2 du Massey
AS_Terminal.REMOTE_N = 6
function AS_Terminal:remoteFns(v)
    local out = {}
    for i = 1, self.REMOTE_N do out[i] = {} end
    local p = self:vehPrefs(v)
    if p ~= nil and p.rem ~= nil then
        local i = 0
        for w in string.gmatch(p.rem .. ",", "([^,]*),") do
            i = i + 1
            if i <= self.REMOTE_N then
                for f in string.gmatch(w, "[^+]+") do
                    local b, sd = f:match("^([%a_]+)@([fr])$")   -- (22:18) « lift_dn@f » = AV, « @r » = AR, sans = les deux
                    b = b or f
                    b = self.REMOTE_OLD[b] or b
                    if b ~= "none" and REMOTE_OK[b] and #out[i] < self.REMOTE_SLOTS then out[i][#out[i] + 1] = sd ~= nil and (b .. "@" .. sd) or b end
                end
            end
        end
    end
    return out
end
function AS_Terminal:remoteStore(v, rem)
    local parts = {}
    for i = 1, self.REMOTE_N do parts[i] = table.concat(rem[i] or {}, "+") end
    -- (05/11) cases vides en fin retirées : « a,b,c,d » comme avant tant que FV1 / FV2 sont vides
    while #parts > 4 and parts[#parts] == "" do parts[#parts] = nil end
    local p = self:vehPrefs(v, true)
    p.rem = table.concat(parts, ",")
    self:saveSettings()
end
-- (03/11) comme un vrai distributeur :
-- appui = les états choisis ; si tout y est déjà, appui = l'inverse (Levé <-> Baissé, Allumé <-> Éteint, ...)
AS_Terminal.REMOTE_INV = { lift_up = "lift_dn", lift_dn = "lift_up", on_on = "on_off", on_off = "on_on", fold_in = "fold_out", fold_out = "fold_in",
    tip_on = "tip_off", tip_off = "tip_on", cover_close = "cover_open", cover_open = "cover_close" }
local remoteAny
-- « lift_dn@f » -> "lift_dn", true (AV) ; « @r » -> false (AR) ; sans suffixe -> nil (les deux)
local function remoteSplit(fn)
    local b, sd = fn:match("^([%a_]+)@([fr])$")
    if b == nil then return fn, nil end
    return b, sd == "f"
end
local function remoteInv(fn)
    local b, sd = remoteSplit(fn)
    local ib = AS_Terminal.REMOTE_INV[b] or b
    if sd == nil then return ib end
    return ib .. (sd and "@f" or "@r")
end
-- la télécommande est-elle sur ses états choisis (true) ou sur l'inverse (false) ? l'état réel d'abord ; si un outil
-- ne suit pas (ne s'éteint pas…), le dernier appui décide, pour que l'appui suivant fasse bien l'autre côté
function AS_Terminal:remoteSide(v, i, fns, d)
    if d == nil or #fns == 0 then return false end
    local _, pre = remoteAny(fns, d, v)
    if pre then return true end
    local inv = {}
    for k, fn in ipairs(fns) do inv[k] = remoteInv(fn) end
    local _, post = remoteAny(inv, d, v)
    if post then return false end
    local m = self.remoteLast ~= nil and self.remoteLast[i] or nil
    return m ~= nil and m.v == v and m.pre == true
end
-- (04/11) CEBIS connect : réglages des distributeurs (Fonction 1-4), par modèle de véhicule,
-- gardés dans hyd = "débit-,débit+,réponse-,réponse+,tempo,priorité,aile,verrou,manette;..." (4 blocs)
-- effets en jeu : verrou = la fonction ne part pas ; temps de réponse = délai avant d'agir (+ : vers les états choisis,
-- - : retour) ; commande temporisée 1-59 s = retour tout seul après ce temps (0 et infini = reste). Débit, priorité,
-- commandes d'aile : réglages affichés et gardés (pas d'équivalent dans le jeu) ; manette = n° de touche (étape touches)
AS_Terminal.HYD_KEYS = { "flowM", "flowP", "respM", "respP", "timer", "prio", "fender", "lock", "lever" }
AS_Terminal.HYD_DEF = { 100, 100, 0, 0, 0, 0, 0, 0, 0 }
AS_Terminal.HYD_RANGE = { flowM = { 10, 100, 5 }, flowP = { 10, 100, 5 }, respM = { 0, 5, 0.25 }, respP = { 0, 5, 0.25 }, timer = { 0, 60, 1 } }
AS_Terminal.HYD_INF = 60            -- tempo 60 = infini
AS_Terminal.hydQ = {}
function AS_Terminal:hydOf(v, i)
    local p = self:vehPrefs(v)
    local blk
    if p ~= nil and p.hyd ~= nil then
        local n = 0
        for w in string.gmatch(p.hyd .. ";", "([^;]*);") do n = n + 1; if n == i then blk = w end end
    end
    local vals = {}
    if blk ~= nil then for x in string.gmatch(blk .. ",", "([^,]*),") do vals[#vals + 1] = tonumber(x) or false end end
    local out = {}
    for k, key in ipairs(self.HYD_KEYS) do
        local x = vals[k]
        if x == nil or x == false then x = self.HYD_DEF[k] end
        out[key] = x
    end
    if vals[9] == nil or vals[9] == false then out.lever = i end
    return out
end
function AS_Terminal:hydSet(v, i, key, val)
    if v == nil then return end
    local all = {}
    -- (06/11) John Deere : 6 distributeurs réglables
    local nH = math.max(4, self.REMOTE_N or 4, i)
    for j = 1, nH do all[j] = self:hydOf(v, j) end
    all[i][key] = val
    local parts = {}
    for j = 1, nH do
        local t = {}
        for k, kk in ipairs(self.HYD_KEYS) do t[k] = tostring(all[j][kk]) end
        parts[j] = table.concat(t, ",")
    end
    local p = self:vehPrefs(v, true)
    p.hyd = table.concat(parts, ";")
    self:saveSettings()
end
-- retour temporisé en attente sur ce distributeur : secondes restantes (nil sinon)
function AS_Terminal:hydLeft(v, i)
    for _, q in ipairs(self.hydQ) do
        if q.v == v and q.i == i and q.kind == "back" then return math.max(0, math.ceil((q.at - (g_time or 0)) / 1000)) end
    end
    return nil
end
function AS_Terminal:hydTick()
    local now = g_time or 0
    for k = #self.hydQ, 1, -1 do
        local q = self.hydQ[k]
        if now >= q.at then
            table.remove(self.hydQ, k)
            local ok, err = pcall(function()
                if q.v == nil or q.v.isDeleted then return end
                local h = self:hydOf(q.v, q.i)
                if h.lock == 1 then return end
                self:remoteRunNow(q.v, q.i)
                if q.kind == "run" and not q.inPlace and h.timer >= 1 and h.timer <= 59 then
                    self.hydQ[#self.hydQ + 1] = { v = q.v, i = q.i, at = (g_time or 0) + h.timer * 1000, kind = "back" }
                end
            end)
            if not ok then log("ERREUR distributeur %d : %s", q.i or 0, tostring(err)) end
            self.lastRead = -100000
        end
    end
end
function AS_Terminal:remoteRun(v, i)
    local h = self:hydOf(v, i)
    if h.lock == 1 then warn(T("cl_h_lockedMsg")); return end
    local fns = self:remoteFns(v)[i] or {}
    local okR, d = pcall(self.read, self, v)
    if not okR or d == nil then d = self.data end
    local inPlace = #fns > 0 and self:remoteSide(v, i, fns, d)
    -- un appui à la main annule ce qui attend encore sur ce distributeur (délai, retour temporisé)
    for k = #self.hydQ, 1, -1 do local q = self.hydQ[k]; if q.v == v and q.i == i then table.remove(self.hydQ, k) end end
    local delay = (inPlace and h.respM or h.respP) or 0
    if #fns > 0 and delay > 0 then
        self.hydQ[#self.hydQ + 1] = { v = v, i = i, at = (g_time or 0) + delay * 1000, kind = "run", inPlace = inPlace }
        return
    end
    self:remoteRunNow(v, i)
    if #fns > 0 and not inPlace and h.timer >= 1 and h.timer <= 59 then
        self.hydQ[#self.hydQ + 1] = { v = v, i = i, at = (g_time or 0) + h.timer * 1000, kind = "back" }
    end
end
function AS_Terminal:remoteRunNow(v, i)
    local fns = self:remoteFns(v)[i] or {}
    if #fns == 0 then warn(T("c_remoteNone")) end
    local okR, d = pcall(self.read, self, v)
    if not okR or d == nil then d = self.data end
    local inPlace = self:remoteSide(v, i, fns, d)
    self.remoteLast = self.remoteLast or {}
    self.remoteLast[i] = { v = v, pre = not inPlace }
    for _, fn0 in ipairs(fns) do self:fnRun(v, inPlace and remoteInv(fn0) or fn0, i) end
end
-- une fonction avec son état voulu (« lift_dn@r » …) ; (05/11) partagé avec les touches GO / END du Fendt TI
function AS_Terminal:fnRun(v, fn0, i)
    local fn, side = remoteSplit(fn0)
    self.cmdSide = side   -- (22:18) AV / AR : seulement les outils de ce côté (verrou ignoré) ; les deux : comme la flèche
    local ok, err = pcall(function()
        if fn == "lift_up" or fn == "lift_dn" then self:cmdLift(v, fn == "lift_dn")
        elseif fn == "on_on" or fn == "on_off" then
            local any = false
            for _, o in ipairs(trainOf(v)) do if o.setIsTurnedOn ~= nil and isTurnedOn(o) ~= nil and onSide(self, v, o) then any = true end end
            if not any then warn(T("noTurnOn")) else self:cmdTurnOn(v, fn == "on_on") end
        elseif fn == "fold_in" or fn == "fold_out" then self:cmdFold(v, fn == "fold_out")
        elseif fn == "tip_on" or fn == "tip_off" then self:cmdTip(v, fn == "tip_on")
        elseif fn == "cover_open" or fn == "cover_close" then self:cmdCover(v, fn == "cover_open") end
    end)
    self.cmdSide = nil
    if not ok then log("ERREUR fonction %s (%s) : %s", tostring(i), tostring(fn0), tostring(err)) end
end
-- suite jouée telle quelle, sans bascule (touches GO / END du Fendt TI)
function AS_Terminal:fnsRun(v, fns, tag)
    for _, fn0 in ipairs(fns or {}) do self:fnRun(v, fn0, tag) end
end
local function remoteLabel(fn, noSide)   -- « Relevage AV : Levé », écrit en direct (FR / EN / DE)
    if fn == nil or fn == "none" then return T("none") end
    local b, sd = remoteSplit(fn)
    local full = T("c_rs_" .. b)
    if noSide then return full end
    local tag = sd == nil and T("c_sideB") or (sd and T("c_sideF") or T("c_sideR"))
    local a, st = full:match("^(.-)%s*:%s*(.+)$")
    if a == nil then return full .. " " .. tag end
    return a .. " " .. tag .. " : " .. st
end
AS_Terminal.remoteLabel = function(_, fn, noSide) return remoteLabel(fn, noSide) end
-- (05/11) nom court pour une case de distributeur : « Relevage AR », « Pliage » (sans l'état ; côté seulement si AV ou AR)
AS_Terminal.remoteShort = function(_, fn)
    if fn == nil or fn == "none" then return T("none") end
    local b, sd = remoteSplit(fn)
    local full = T("c_rs_" .. b)
    local a = full:match("^(.-)%s*:%s*.+$") or full
    if sd == nil then return a end
    return a .. " " .. (sd and T("c_sideF") or T("c_sideR"))
end
-- état d'une fonction d'un seul côté, lu sur les outils de ce côté : disponible ?, tout dans l'état voulu ?
local function sideMatch(v, b, sd)
    local avail, all = false, true
    for _, o in ipairs(trainOf(v)) do
        if o ~= v and hitchSideOf(v, o) == sd then
            local cur
            if b == "lift_up" or b == "lift_dn" then
                local l = isLowered(o); if l ~= nil then cur = (l == (b == "lift_dn")) end
            elseif b == "on_on" or b == "on_off" then
                local t = isTurnedOn(o); if t ~= nil and o.setIsTurnedOn ~= nil then cur = (t == (b == "on_on")) end
            elseif b == "fold_in" or b == "fold_out" then
                local sp = o.spec_foldable
                if sp ~= nil and sp.foldingParts ~= nil and #sp.foldingParts > 0 then cur = ((call(o, "getIsUnfolded") == true) == (b == "fold_out")) end
            elseif b == "tip_on" or b == "tip_off" then
                if o.spec_trailer ~= nil and o.spec_dischargeable ~= nil and o.getDischargeState ~= nil then
                    cur = (((call(o, "getDischargeState") or 0) ~= 0) == (b == "tip_on"))
                end
            elseif b == "cover_open" or b == "cover_close" then
                local sc = o.spec_cover
                if sc ~= nil and sc.covers ~= nil and #sc.covers > 0 then cur = (((sc.state or 0) ~= 0) == (b == "cover_open")) end
            end
            if cur ~= nil then avail = true; if not cur then all = false end end
        end
    end
    return avail, avail and all
end
local function remoteMatch(fn, d, v)   -- outil disponible ?, déjà dans l'état voulu ?
    local b, sd = remoteSplit(fn)
    if sd ~= nil then
        v = v or d.vehicle
        if v == nil then return false, false end
        return sideMatch(v, b, sd)
    end
    fn = b
    local anyFold, anyOpen = false, false
    for _, t in ipairs(d.tools or {}) do if t.unfolded ~= nil then anyFold = true; if t.unfolded then anyOpen = true end end end
    if fn == "lift_up" or fn == "lift_dn" then return d.anyLowerable == true, (d.anyLowered == true) == (fn == "lift_dn")
    elseif fn == "on_on" or fn == "on_off" then return d.anyTurnable == true, (d.anyOn == true) == (fn == "on_on")
    elseif fn == "fold_in" or fn == "fold_out" then return anyFold, anyOpen == (fn == "fold_out")
    elseif fn == "tip_on" or fn == "tip_off" then return d.anyTip == true, (d.tipping == true) == (fn == "tip_on")
    elseif fn == "cover_open" or fn == "cover_close" then return d.anyCover == true, (d.coverOpen == true) == (fn == "cover_open") end
    return false, false
end
remoteAny = function(fns, d, v)   -- un outil disponible ?, tout est-il déjà dans l'état voulu (point allumé) ?
    local avail, all = false, #fns > 0
    for _, fn in ipairs(fns) do
        local av, ok = remoteMatch(fn, d, v)
        if av then avail = true end
        if not (av and ok) then all = false end
    end
    return avail, all
end
-- repères du bloc 4 d'un écran ramenés dans le bloc 4 du châssis ; box = { x0, y0, x1, y1 } dans l'écran
local function b4Map(box)
    local kx, ky = 1324 / (box[3] - box[1]), 759 / (box[4] - box[2])
    return function(x) return 345 + (x - box[1]) * kx end, function(y) return 94 + (y - box[2]) * ky end, kx, ky
end

-- châssis commun : image 05 vidée (barre du haut + onglets), touches du bloc 1, onglets, heure, flèche relevage,
-- satellite, puis le bloc 2 du type demandé avec ses valeurs vivantes
function AS_Terminal:caseChassis(d, ctx, v, Wp, Hp, b2)
    local kx, ky = Wp / self.HOME_W, Hp / self.HOME_H
    local function PX(x) return x * kx end
    local function PY(y) return y * ky end
    local function PW(w) return w * kx end
    local function img(x, y, w, h, name)
        local f = caseImg(name)
        ctx.image(PX(x), PY(y), PW(w), PY(h), ctx.rec == nil and AS_TerminalTools ~= nil and AS_TerminalTools:overlay(f) or nil, "img_" .. name, f)
    end
    img(0, 0, self.HOME_W, self.HOME_H, "as_case_chassis")
    self.headerBox = { x = ctx.X(PX(520)), y = ctx.Y(PY(0)), w = ctx.sx(PX(360)), h = ctx.sy(PY(88)) }
    local hot = ctx.hotspot or ctx.button
    for _, h in ipairs(self.CHASSIS_HOT) do hot(PX(h[1]), PY(h[2]), PW(h[3] - h[1]), PY(h[4] - h[2]), h[5]) end
    self:caseImgTabs(ctx, d, v, self.HOME_TABS, 856, 936, PX, PY, PW, { noLabel = true, caseFont = 902, line = { 856, 876 }, lineImg = "as_case_tab_line" })
    caseWrite(ctx, PX(961), PY(59), PY(32), fmtClock(), "wh", RenderText.ALIGN_CENTER, PW(130))
    caseTopBar(ctx, d, PX, PY, PW, 336, 453)
    if self.COL_STACK then   -- (06/11) pile de cases choisies, la même sur toutes les pages
        self:caseColStack(d, ctx, PX, PY, PW, hot, img)
    else
        img(0, 93, 337, 847, b2 == "B" and "as_case_b2b" or "as_case_b2a")
        if b2 == "B" then self:caseB2B(d, ctx, PX, PY, PW, hot, img) else self:caseB2A(d, ctx, PX, PY, PW, hot, img) end
    end
    return PX, PY, PW, img, hot
end

-- bloc 2 type A (l'écran 02) : boîte P / tracteur avance / recule, rapport, F3 vitesse maxi, F2 vitesse de travail,
-- F1 régulateur, jauge de vitesse, vitesse, puissance, patinage, B1 / B2 (relevages avant / arrière), 4 feux
function AS_Terminal:caseB2A(d, ctx, PX, PY, PW, hot, img)
    local function Y(y) return 93 + y end
    local CE, RI = RenderText.ALIGN_CENTER, RenderText.ALIGN_RIGHT
    local mv = math.abs(d.speed or 0) >= 0.3 and ((d.dir or 0) < 0 and "rev" or "fwd") or nil
    img(28, Y(87), 88, 176, mv ~= nil and ("as_case_b2_" .. mv) or "as_case_b2_P")
    local gear = tostring(d.gear or "N")
    if d.cvt then gear = (d.dir or 0) < 0 and "R" or ((d.dir or 0) > 0 and "D" or "N") end
    caseWrite(ctx, PX(71), PY(Y(314)), PY(30), gear, "dk", CE, PX(80))
    local u = unitsOf()
    local function sp(vv) return vv ~= nil and string.format("%.1f", u and u.kmh(vv) or vv) or "--.-" end
    local cruiseOn = d.cruise ~= nil and d.cruise ~= 0
    if u ~= nil then   -- (étape 61) noms et unités en direct
        liveLabel(ctx, PX, PY, PW, 205, Y(452), 20, "c_power", "dk", 190)
        liveLabel(ctx, PX, PY, PW, 205, Y(550), 20, "c_slip", "dk", 190)
        caseWrite(ctx, PX(262), PY(Y(401)), PY(22), u.speed, "dk", RenderText.ALIGN_LEFT, PX(70))   -- (les « % » sont restés dans l'image)
    end
    caseWrite(ctx, PX(213), PY(Y(104)), PY(34), sp(d.maxSpeed), "dk", CE, PX(100))
    caseWrite(ctx, PX(213), PY(Y(194)), PY(34), sp(d.workSpeed), "dk", CE, PX(100))
    caseWrite(ctx, PX(215), PY(Y(291)), PY(30), cruiseOn and sp(d.cruiseSpeed) or "--.-", cruiseOn and "bl" or "dk", CE, PX(90))
    local fr = math.max(0, math.min(1, math.abs(d.speed or 0) / math.max(1, d.maxSpeed or 50)))
    if fr > 0.01 then ctx.rect(PX(291), PY(Y(318 - 291 * fr)), PW(19), PY(291 * fr), BLUE_GAUGE) end
    caseWrite(ctx, PX(252), PY(Y(401)), PY(46), string.format("%.2f", u and u.kmh(math.abs(d.speed or 0)) or math.abs(d.speed or 0)), "bl", RI, PX(120))
    caseWrite(ctx, PX(181), PY(Y(499)), PY(38), string.format("%d", math.floor((d.load or 0) * 100 + 0.5)), "dk", CE, PX(70))
    local slip = d.slip ~= nil and string.format("%d", math.floor(d.slip + 0.5)) or "0"
    caseWrite(ctx, PX(181), PY(Y(599)), PY(38), slip, (d.slip or 0) > 25 and "rd" or "dk", CE, PX(70))
    local hf, hr = caseHitches(d)
    caseWrite(ctx, PX(208), PY(Y(658)), PY(28), hitchPct(hf), "dk", CE, PX(44))
    caseWrite(ctx, PX(290), PY(Y(658)), PY(28), hitchPct(hr), "dk", CE, PX(44))
    hot(PX(175), PY(Y(622)), PW(65), PY(88), "hitch_f")
    hot(PX(258), PY(Y(622)), PW(64), PY(88), "hitch_r")
    -- (03/11) les 4 boutons = 4 télécommandes : point rouge / bleu / jaune / vert quand la fonction est active,
    -- « N » écrit seulement sans fonction
    local rem = self:remoteFns(d.vehicle)
    for i, l in ipairs(self.B2A_LAMPS) do
        local active = self:remoteSide(d.vehicle, i, rem[i], d)
        if #rem[i] == 0 then caseWrite(ctx, PX(l[1]), PY(Y(760)), PY(30), "N", "dk", CE, PX(40))
        end
        img(l[1] - 34, Y(768), 68, 68, "as_case_la_" .. self.REMOTE_COL[i] .. (active and "" or "_d"))
        hot(PX(l[1] - 24), PY(Y(726)), PW(48), PY(116), "rem_" .. i)
    end
end

-- bloc 2 type B (l'écran 08) : puissance moteur, patinage, B1 / B2, 4 feux, écart de guidage, conso l/ha (engrenage =
-- autre compteur), débit ha/h, consommation L/h
function AS_Terminal:caseB2B(d, ctx, PX, PY, PW, hot, img)
    local function Y(y) return 93 + y end
    local CE, RI = RenderText.ALIGN_CENTER, RenderText.ALIGN_RIGHT
    local u = unitsOf()
    if u ~= nil then   -- (étape 61) noms et unités en direct
        liveLabel(ctx, PX, PY, PW, 217, Y(44), 22, "c_power", "dk", 210)
        liveLabel(ctx, PX, PY, PW, 192, Y(143), 22, "c_slip", "dk", 120)
        liveLabel(ctx, PX, PY, PW, 211, Y(455), 22, "c_xte", "dk", 226)
        liveLabel(ctx, PX, PY, PW, 200, Y(548), 22, "c_fuelEco", "dk", 190)
        liveLabel(ctx, PX, PY, PW, 187, Y(633), 22, "c_workRate", "dk", 180)
        liveLabel(ctx, PX, PY, PW, 210, Y(724), 22, "c_fuelRate", "dk", 180)
        local L = RenderText.ALIGN_LEFT
        caseWrite(ctx, PX(243), PY(Y(94)), PY(24), "%", "dk", L, PX(40))
        caseWrite(ctx, PX(243), PY(Y(194)), PY(24), "%", "dk", L, PX(40))
        caseWrite(ctx, PX(232), PY(Y(497)), PY(26), u.cm, "dk", L, PX(60))
        caseWrite(ctx, PX(205), PY(Y(592)), PY(26), u.vol .. "/" .. u.area, "dk", L, PX(90))
        caseWrite(ctx, PX(205), PY(Y(679)), PY(26), u.area .. "/h", "dk", L, PX(70))
        caseWrite(ctx, PX(215), PY(Y(769)), PY(26), u.vol .. "/h", "dk", L, PX(70))
    end
    caseWrite(ctx, PX(181), PY(Y(94)), PY(40), string.format("%d", math.floor((d.load or 0) * 100 + 0.5)), "dk", CE, PX(70))
    local slip = d.slip ~= nil and string.format("%d", math.floor(d.slip + 0.5)) or "0"
    caseWrite(ctx, PX(181), PY(Y(194)), PY(40), slip, (d.slip or 0) > 25 and "rd" or "dk", CE, PX(70))
    local hf, hr = caseHitches(d)
    caseWrite(ctx, PX(197), PY(Y(264)), PY(28), hitchPct(hf), "dk", CE, PX(48))
    caseWrite(ctx, PX(285), PY(Y(264)), PY(28), hitchPct(hr), "dk", CE, PX(48))
    if u ~= nil then   -- (étape 61) B1 / B2 écrits sous les barres (enlevés de l'image)
        caseWrite(ctx, PX(197), PY(Y(298)), PY(18), "B1", "dk", CE, PX(48))
        caseWrite(ctx, PX(285), PY(Y(298)), PY(18), "B2", "dk", CE, PX(48))
    end
    hot(PX(162), PY(Y(228)), PW(70), PY(72), "hitch_f")
    hot(PX(252), PY(Y(228)), PW(70), PY(72), "hitch_r")
    local rem = self:remoteFns(d.vehicle)
    for i, l in ipairs(self.B2B_LAMPS) do
        local active = self:remoteSide(d.vehicle, i, rem[i], d)
        if #rem[i] == 0 then caseWrite(ctx, PX(l[1]), PY(Y(350)), PY(26), "N", "dk", CE, PX(40))
        end
        img(l[1] - 28, Y(352), 56, 56, "as_case_lb_" .. self.REMOTE_COL[i] .. (active and "" or "_d"))
        hot(PX(l[1] - 30), PY(Y(322)), PW(60), PY(90), "rem_" .. i)
    end
    local g = d.gps
    local xte = (g ~= nil and g.onLine and g.xte ~= nil) and string.format("%+d", math.floor((u and u.cmv(g.xte * 100) or g.xte * 100) + 0.5)) or "--"
    caseWrite(ctx, PX(222), PY(Y(497)), PY(38), xte, "dk", RI, PX(130))
    local width = 0
    for _, t in ipairs(d.tools or {}) do
        if (t.working or t.lowered) and type(t.width) == "number" and t.width > width then width = t.width end
    end
    local rate = math.abs(d.speed or 0) * width / 10   -- ha/h instantané
    local eco = rate > 0.05 and (d.fuelUse or 0) / rate or 0
    caseWrite(ctx, PX(197), PY(Y(592)), PY(38), rate > 0.05 and fr1(u and u.lha(eco) or eco) or "0,0", "dk", RI, PX(76))
    hot(PX(278), PY(Y(515)), PW(46), PY(50), "jobnext")
    caseWrite(ctx, PX(197), PY(Y(679)), PY(38), fr1(u and u.ha(rate) or rate), "dk", RI, PX(76))
    local fuelLow = d.fuel ~= nil and d.fuel * 100 < self.settings.fuelReserve
    caseWrite(ctx, PX(207), PY(Y(769)), PY(40), fr1(u and u.l(d.fuelUse or 0) or d.fuelUse), fuelLow and "rd" or "dk", RI, PX(76))
end

-- ===================================================================================================================
-- (06/11) colonne A au choix du joueur, la même pour toutes les pages ; limite = la hauteur disponible (pas un nombre
-- de cases), de haut en bas
-- Bloc 2 = pile de cases, la même sur toutes les pages : chaque case est découpée dans les images (colonnes A et B,
-- cases de PERF1), garde sa hauteur, et ses valeurs sont écrites en direct. Toucher une case (hors de ses boutons) =
-- liste des cases qui tiennent à sa place ; « + » dans la place libre en bas = ajouter. Choix gardé dans les réglages
-- (tous les Case, Steyr et New Holland). AS_Terminal.COL_STACK = false : retour aux colonnes A / B par page.
-- ===================================================================================================================
AS_Terminal.COL_STACK = true
AS_Terminal.COL_TOP, AS_Terminal.COL_BOTTOM, AS_Terminal.COL_GAP = 10.75, 836, 2.5   -- pixels du bloc 2 (337 x 847, y 93 .. 940)
AS_Terminal.COL_DEFAULT = { "gears", "power", "slip", "hitch", "remotes" }          -- = sa colonne A d'aujourd'hui
AS_Terminal.COL_ORDER = { "gears", "power", "slip", "hitch", "remotes", "xte", "fuelEco", "workRate", "fuelRate",
    "p2", "p3", "p4", "p6", "p7", "p9", "p10", "p12", "p13", "p15", "p16", "p17", "p18" }
-- x, w, h : sprite (pixels du bloc 2) ; bh : hauteur de la case dans la pile ; oy : place de la case dans l'image
AS_Terminal.COL_ITEMS = {
    gears = { img = "as_case_c_gears", x = 6.58, w = 326.47, h = 413.57, bh = 412.75, oy = 10.75, label = "c_colGears" },
    power = { img = "as_case_c_power", x = 6.58, w = 326.47, h = 95.95, bh = 94.29, oy = 426.81, label = "c_power" },
    slip = { img = "as_case_c_slip", x = 6.58, w = 326.47, h = 92.64, bh = 91.81, oy = 524.41, label = "c_slip" },
    hitch = { img = "as_case_c_hitch", x = 6.58, w = 326.47, h = 102.57, bh = 102.57, oy = 617.88, label = "c_colHitch" },
    remotes = { img = "as_case_c_remotes", x = 6.58, w = 326.47, h = 112.49, bh = 112.49, oy = 722.93, label = "c_rcRemotes" },
    xte = { img = "as_case_c_xte", x = 7.24, w = 323.84, h = 92.64, bh = 90.99, oy = 421.02, label = "c_xte" },
    fuelEco = { img = "as_case_c_fuelEco", x = 7.24, w = 323.84, h = 86.02, bh = 85.20, oy = 512.83, label = "c_fuelEco" },
    workRate = { img = "as_case_c_workRate", x = 7.24, w = 323.84, h = 89.33, bh = 88.50, oy = 599.68, label = "c_workRate" },
    fuelRate = { img = "as_case_c_fuelRate", x = 7.24, w = 323.84, h = 102.57, bh = 100.08, oy = 689.01, label = "c_fuelRate" },
    p2 = { img = "as_case_c_p2", x = 7.53, w = 320.00, h = 85.33, bh = 85.33, oy = 0.00, label = "c_fuelLevel", p1 = 2 },
    p3 = { img = "as_case_c_p3", x = 7.62, w = 320.00, h = 80.00, bh = 80.00, oy = 0.00, label = "c_engineHours", p1 = 3 },
    p4 = { img = "as_case_c_p4", x = 7.51, w = 320.00, h = 77.33, bh = 77.33, oy = 0.00, label = "c_oilPress", p1 = 4 },
    p6 = { img = "as_case_c_p6", x = 7.62, w = 320.00, h = 69.33, bh = 69.33, oy = 0.00, label = "c_intakeTemp", p1 = 6 },
    p7 = { img = "as_case_c_p7", x = 7.51, w = 320.00, h = 77.33, bh = 77.33, oy = 0.00, label = "c_coolant", p1 = 7 },
    p9 = { img = "as_case_c_p9", x = 7.62, w = 320.00, h = 69.33, bh = 69.33, oy = 0.00, label = "c_defLevel", p1 = 9 },
    p10 = { img = "as_case_c_p10", x = 7.51, w = 320.00, h = 77.33, bh = 77.33, oy = 0.00, label = "c_transTemp", p1 = 10 },
    p12 = { img = "as_case_c_p12", x = 7.62, w = 320.00, h = 69.33, bh = 69.33, oy = 0.00, label = "c_defTemp", p1 = 12 },
    p13 = { img = "as_case_c_p13", x = 7.51, w = 320.00, h = 80.00, bh = 80.00, oy = 0.00, label = "c_transPress", p1 = 13 },
    p15 = { img = "as_case_c_p15", x = 7.62, w = 320.00, h = 72.00, bh = 72.00, oy = 0.00, label = "c_airBrake", p1 = 15 },
    p16 = { img = "as_case_c_p16", x = 7.51, w = 320.00, h = 82.67, bh = 82.67, oy = 0.00, label = "c_voltage", p1 = 16 },
    p17 = { img = "as_case_c_p17", x = 7.53, w = 320.00, h = 82.67, bh = 82.67, oy = 0.00, label = "c_ptoR", p1 = 17 },
    p18 = { img = "as_case_c_p18", x = 7.62, w = 320.00, h = 74.67, bh = 74.67, oy = 0.00, label = "c_ptoF", p1 = 18 },
}
AS_Terminal.COL_UNITS = { "%", "vol", "h", "bar", "vol/h", "temp", "temp", "%", "%", "temp", "%", "temp", "bar", "%", "bar", "V", "RPM", "RPM" }

-- liste des cases de la pile (réglage), nettoyée : cases connues, sans doublon, et qui tiennent dans la hauteur
function AS_Terminal:caseColList()
    local s = self.settings
    if self.colCache ~= nil and self.colCache.src == s.caseCol then return self.colCache.list end
    local list, seen, y = {}, {}, self.COL_TOP
    local src = s.caseCol
    local keys = {}
    if type(src) == "string" and src ~= "" then
        for k in src:gmatch("[^,]+") do keys[#keys + 1] = k end
    elseif src == nil then keys = self.COL_DEFAULT end
    for _, k in ipairs(keys) do
        local it = self.COL_ITEMS[k]
        if it ~= nil and not seen[k] and y + it.bh <= self.COL_BOTTOM + 0.5 then
            list[#list + 1] = k; seen[k] = true; y = y + it.bh + self.COL_GAP
        end
    end
    self.colCache = { src = s.caseCol, list = list }
    return list
end
-- place libre sous la pile (pixels du bloc 2)
function AS_Terminal:caseColFree(list)
    local y = self.COL_TOP
    for i, k in ipairs(list) do y = y + (i > 1 and self.COL_GAP or 0) + self.COL_ITEMS[k].bh end
    return self.COL_BOTTOM - y, y     -- place sous la dernière case, bas de la dernière case
end
function AS_Terminal:caseColMinH()
    local m = math.huge
    for _, it in pairs(self.COL_ITEMS) do m = math.min(m, it.bh) end
    return m
end

-- dessin de chaque case : mêmes repères que dans l'image (Y = place d'origine + décalage dy)
local COL_DRAW = {}
COL_DRAW.gears = function(self, d, ctx, PX, PY, PW, hot, img, dy)
    local function Y(y) return 93 + y + dy end
    local CE, RI = RenderText.ALIGN_CENTER, RenderText.ALIGN_RIGHT
    local mv = math.abs(d.speed or 0) >= 0.3 and ((d.dir or 0) < 0 and "rev" or "fwd") or nil
    img(28, Y(87), 88, 176, mv ~= nil and ("as_case_b2_" .. mv) or "as_case_b2_P")
    local gear = tostring(d.gear or "N")
    if d.cvt then gear = (d.dir or 0) < 0 and "R" or ((d.dir or 0) > 0 and "D" or "N") end
    caseWrite(ctx, PX(71), PY(Y(314)), PY(30), gear, "dk", CE, PX(80))
    local u = unitsOf()
    local function sp(vv) return vv ~= nil and string.format("%.1f", u and u.kmh(vv) or vv) or "--.-" end
    local cruiseOn = d.cruise ~= nil and d.cruise ~= 0
    if u ~= nil then caseWrite(ctx, PX(262), PY(Y(401)), PY(22), u.speed, "dk", RenderText.ALIGN_LEFT, PX(70)) end
    caseWrite(ctx, PX(213), PY(Y(104)), PY(34), sp(d.maxSpeed), "dk", CE, PX(100))
    caseWrite(ctx, PX(213), PY(Y(194)), PY(34), sp(d.workSpeed), "dk", CE, PX(100))
    caseWrite(ctx, PX(215), PY(Y(291)), PY(30), cruiseOn and sp(d.cruiseSpeed) or "--.-", cruiseOn and "bl" or "dk", CE, PX(90))
    local fr = math.max(0, math.min(1, math.abs(d.speed or 0) / math.max(1, d.maxSpeed or 50)))
    if fr > 0.01 then ctx.rect(PX(291), PY(Y(318 - 291 * fr)), PW(19), PY(291 * fr), BLUE_GAUGE) end
    caseWrite(ctx, PX(252), PY(Y(401)), PY(46), string.format("%.2f", u and u.kmh(math.abs(d.speed or 0)) or math.abs(d.speed or 0)), "bl", RI, PX(120))
end
COL_DRAW.power = function(self, d, ctx, PX, PY, PW, hot, img, dy)
    local function Y(y) return 93 + y + dy end
    if unitsOf() ~= nil then liveLabel(ctx, PX, PY, PW, 205, Y(452), 20, "c_power", "dk", 190) end
    caseWrite(ctx, PX(181), PY(Y(499)), PY(38), string.format("%d", math.floor((d.load or 0) * 100 + 0.5)), "dk", RenderText.ALIGN_CENTER, PX(70))
end
COL_DRAW.slip = function(self, d, ctx, PX, PY, PW, hot, img, dy)
    local function Y(y) return 93 + y + dy end
    if unitsOf() ~= nil then liveLabel(ctx, PX, PY, PW, 205, Y(550), 20, "c_slip", "dk", 190) end
    local slip = d.slip ~= nil and string.format("%d", math.floor(d.slip + 0.5)) or "0"
    caseWrite(ctx, PX(181), PY(Y(599)), PY(38), slip, (d.slip or 0) > 25 and "rd" or "dk", RenderText.ALIGN_CENTER, PX(70))
end
COL_DRAW.hitch = function(self, d, ctx, PX, PY, PW, hot, img, dy)
    local function Y(y) return 93 + y + dy end
    local hf, hr = caseHitches(d)
    caseWrite(ctx, PX(208), PY(Y(658)), PY(28), hitchPct(hf), "dk", RenderText.ALIGN_CENTER, PX(44))
    caseWrite(ctx, PX(290), PY(Y(658)), PY(28), hitchPct(hr), "dk", RenderText.ALIGN_CENTER, PX(44))
    hot(PX(175), PY(Y(622)), PW(65), PY(88), "hitch_f")
    hot(PX(258), PY(Y(622)), PW(64), PY(88), "hitch_r")
end
COL_DRAW.remotes = function(self, d, ctx, PX, PY, PW, hot, img, dy)
    local function Y(y) return 93 + y + dy end
    local rem = self:remoteFns(d.vehicle)
    for i, l in ipairs(self.B2A_LAMPS) do
        local active = self:remoteSide(d.vehicle, i, rem[i], d)
        if #rem[i] == 0 then caseWrite(ctx, PX(l[1]), PY(Y(760)), PY(30), "N", "dk", RenderText.ALIGN_CENTER, PX(40)) end
        img(l[1] - 34, Y(768), 68, 68, "as_case_la_" .. self.REMOTE_COL[i] .. (active and "" or "_d"))
        hot(PX(l[1] - 24), PY(Y(726)), PW(48), PY(math.min(116, 835.42 - 726)), "rem_" .. i)
    end
end
COL_DRAW.xte = function(self, d, ctx, PX, PY, PW, hot, img, dy)
    local function Y(y) return 93 + y + dy end
    local u = unitsOf()
    if u ~= nil then
        liveLabel(ctx, PX, PY, PW, 211, Y(455), 22, "c_xte", "dk", 226)
        caseWrite(ctx, PX(232), PY(Y(497)), PY(26), u.cm, "dk", RenderText.ALIGN_LEFT, PX(60))
    end
    local g = d.gps
    local xte = (g ~= nil and g.onLine and g.xte ~= nil) and string.format("%+d", math.floor((u and u.cmv(g.xte * 100) or g.xte * 100) + 0.5)) or "--"
    caseWrite(ctx, PX(222), PY(Y(497)), PY(38), xte, "dk", RenderText.ALIGN_RIGHT, PX(130))
end
local function colRate(d)
    local width = 0
    for _, t in ipairs(d.tools or {}) do
        if (t.working or t.lowered) and type(t.width) == "number" and t.width > width then width = t.width end
    end
    return math.abs(d.speed or 0) * width / 10   -- ha/h instantané
end
COL_DRAW.fuelEco = function(self, d, ctx, PX, PY, PW, hot, img, dy)
    local function Y(y) return 93 + y + dy end
    local u = unitsOf()
    if u ~= nil then
        liveLabel(ctx, PX, PY, PW, 200, Y(548), 22, "c_fuelEco", "dk", 190)
        caseWrite(ctx, PX(205), PY(Y(592)), PY(26), u.vol .. "/" .. u.area, "dk", RenderText.ALIGN_LEFT, PX(90))
    end
    local rate = colRate(d)
    local eco = rate > 0.05 and (d.fuelUse or 0) / rate or 0
    caseWrite(ctx, PX(197), PY(Y(592)), PY(38), rate > 0.05 and fr1(u and u.lha(eco) or eco) or "0,0", "dk", RenderText.ALIGN_RIGHT, PX(76))
end
COL_DRAW.workRate = function(self, d, ctx, PX, PY, PW, hot, img, dy)
    local function Y(y) return 93 + y + dy end
    local u = unitsOf()
    if u ~= nil then
        liveLabel(ctx, PX, PY, PW, 187, Y(633), 22, "c_workRate", "dk", 180)
        caseWrite(ctx, PX(205), PY(Y(679)), PY(26), u.area .. "/h", "dk", RenderText.ALIGN_LEFT, PX(70))
    end
    local rate = colRate(d)
    caseWrite(ctx, PX(197), PY(Y(679)), PY(38), fr1(u and u.ha(rate) or rate), "dk", RenderText.ALIGN_RIGHT, PX(76))
end
COL_DRAW.fuelRate = function(self, d, ctx, PX, PY, PW, hot, img, dy)
    local function Y(y) return 93 + y + dy end
    local u = unitsOf()
    if u ~= nil then
        liveLabel(ctx, PX, PY, PW, 210, Y(724), 22, "c_fuelRate", "dk", 180)
        caseWrite(ctx, PX(215), PY(Y(769)), PY(26), u.vol .. "/h", "dk", RenderText.ALIGN_LEFT, PX(70))
    end
    local fuelLow = d.fuel ~= nil and d.fuel * 100 < self.settings.fuelReserve
    caseWrite(ctx, PX(207), PY(Y(769)), PY(40), fr1(u and u.l(d.fuelUse or 0) or d.fuelUse), fuelLow and "rd" or "dk", RenderText.ALIGN_RIGHT, PX(76))
end
-- cases de PERF1 : nom en haut, nombre et unité dessous (mêmes proportions que dans PERF1)
local function colP1(self, d, ctx, PX, PY, PW, hot, img, dy, y, it, vals)
    local u = unitsOf()
    local i = it.p1
    local top = 93 + y
    local set = "dk"
    if (i == 2 and d.fuel ~= nil and d.fuel * 100 < self.settings.fuelReserve) or (i == 7 and (d.temp or 0) > 100) then set = "rd" end
    local x0, w, h = it.x, it.w, it.bh
    caseWrite(ctx, PX(x0 + w * 0.62), PY(top + h * 0.36), PY(18), T(it.label), "dk", RenderText.ALIGN_CENTER, PW(w * 0.6))
    caseWrite(ctx, PX(x0 + w * 0.70), PY(top + h * 0.80), PY(28), vals ~= nil and vals[i] or "--", set, RenderText.ALIGN_RIGHT, PW(w * 0.42))
    if u ~= nil then
        local un = self.COL_UNITS[i]
        un = (un == "vol" and u.vol) or (un == "vol/h" and (u.vol .. "/h")) or (un == "temp" and u.temp) or un
        caseWrite(ctx, PX(x0 + w * 0.73), PY(top + h * 0.80), PY(22), un, set, RenderText.ALIGN_LEFT, PW(w * 0.24))
    end
end

-- zones « toucher = choisir la case » : hors des boutons de la case (pixels du bloc 2, x0, x1)
local COL_PICK = { hitch = { 0, 170 }, remotes = { 232, 337 } }

function AS_Terminal:caseColStack(d, ctx, PX, PY, PW, hot, img)
    img(0, 93, 337, 847, "as_case_c_bg")
    local list = self:caseColList()
    local y = self.COL_TOP
    local vals = nil
    for _, k in ipairs(list) do
        if self.COL_ITEMS[k].p1 ~= nil then vals = self:casePerf1Values(d, unitsOf()); break end
    end
    for i, k in ipairs(list) do
        local it = self.COL_ITEMS[k]
        local pk = COL_PICK[k] or { 0, 337 }
        hot(PX(pk[1]), PY(93 + y), PW(pk[2] - pk[1]), PY(it.bh), "colc_" .. i)   -- avant ses boutons : les boutons gagnent
        img(it.x, 93 + y, it.w, it.h, it.img)
        if self.colMenu ~= nil and self.colMenu.i == i then
            ctx.rect(PX(it.x + 2), PY(93 + y + 1), PW(it.w - 4), PY(3), BLUE_CASE)
            ctx.rect(PX(it.x + 2), PY(93 + y + it.bh - 4), PW(it.w - 4), PY(3), BLUE_CASE)
        end
        local f = COL_DRAW[k]
        if f ~= nil then f(self, d, ctx, PX, PY, PW, hot, img, y - it.oy)
        elseif it.p1 ~= nil then colP1(self, d, ctx, PX, PY, PW, hot, img, y - it.oy, y, it, vals) end
        y = y + it.bh + self.COL_GAP
    end
    -- place libre : « + » si une case y tient encore
    local free = self.COL_BOTTOM - y
    if free >= self:caseColMinH() - 0.5 then
        local n = #list + 1
        local on = self.colMenu ~= nil and self.colMenu.i == n
        local bh = math.min(free - 1, 84)   -- une case vide avec « + », de la taille d'une petite case
        ctx.rect(PX(9), PY(93 + y), PW(320), PY(bh), on and BLUE_CASE or CASE_BTN_DK)
        caseWrite(ctx, PX(169), PY(93 + y + bh * 0.5 + 16), PY(44), "+", "wh", RenderText.ALIGN_CENTER, PW(60))
        hot(PX(9), PY(93 + y), PW(320), PY(bh), "colc_" .. n)
    end
    self.colPending = { d = d, ctx = ctx, PX = PX, PY = PY, PW = PW, hot = hot }
end

-- liste déroulante de la case i (posée après la page, par-dessus le bloc 4) : les cases qui tiennent à sa place
function AS_Terminal:caseColMenu(cp)
    local m = self.colMenu
    if m == nil then return end
    local ctx, PX, PY, PW, hot = cp.ctx, cp.PX, cp.PY, cp.PW, cp.hot
    local list = self:caseColList()
    local free = self:caseColFree(list)
    local cur = list[m.i]
    -- place pour la case choisie : la sienne + la place libre (un ajout prend aussi l'écart entre deux cases)
    local room = cur ~= nil and (free + self.COL_ITEMS[cur].bh) or (free - (#list > 0 and self.COL_GAP or 0))
    local cand = {}
    local used = {}
    for _, k in ipairs(list) do used[k] = true end
    for _, k in ipairs(self.COL_ORDER) do
        local it = self.COL_ITEMS[k]
        if k == cur or (not used[k] and it.bh <= room + 0.5) then cand[#cand + 1] = k end
    end
    local rh, cw, cg = 38, 330, 6
    local perCol = math.ceil(#cand / 2)
    local x0 = 350
    local top = 100
    local rowsH = rh * (perCol + 1) + (cur ~= nil and rh or 0)
    ctx.rect(PX(x0 - 3), PY(top - 3), PW(cw * 2 + cg + 6), PY(rowsH + 6), CASE_BTN_DK)
    ctx.rect(PX(x0), PY(top), PW(cw * 2 + cg), PY(rh), BLUE_CASE)
    caseWrite(ctx, PX(x0 + cw + cg * 0.5), PY(top + rh * 0.5 + 9), PY(22), T("c_colTitle"), "wh", RenderText.ALIGN_CENTER, PW(cw * 2 - 20))
    for j, k in ipairs(cand) do
        local c = j <= perCol and 0 or 1
        local r = j <= perCol and j or (j - perCol)
        local cx, ry = x0 + c * (cw + cg), top + r * rh
        local on = k == cur
        ctx.rect(PX(cx), PY(ry), PW(cw), PY(rh), on and BLUE_CASE or CASE_CARD)
        ctx.rect(PX(cx), PY(ry), PW(cw), PY(1), CASE_BG)
        hot(PX(cx), PY(ry), PW(cw), PY(rh), "cols_" .. m.i .. "_" .. k)
        caseWrite(ctx, PX(cx + 12), PY(ry + rh * 0.5 + 8), PY(20), T(self.COL_ITEMS[k].label), on and "wh" or "dk", nil, PW(cw - 24))
    end
    if cur ~= nil then
        local ny = top + (perCol + 1) * rh
        ctx.rect(PX(x0), PY(ny), PW(cw * 2 + cg), PY(rh), CASE_CARD)
        ctx.rect(PX(x0), PY(ny), PW(cw * 2 + cg), PY(1), CASE_BG)
        hot(PX(x0), PY(ny), PW(cw * 2 + cg), PY(rh), "cols_" .. m.i .. "_none")
        caseWrite(ctx, PX(x0 + cw + cg * 0.5), PY(ny + rh * 0.5 + 8), PY(20), T("none"), "dk", RenderText.ALIGN_CENTER, PW(cw * 2 - 20))
    end
end

-- choix dans la liste : remplace la case i, l'ajoute en bas, ou l'enlève (« Aucun ») ; refusé s'il ne tient pas
function AS_Terminal:caseColSet(i, key)
    local list = {}
    for _, k in ipairs(self:caseColList()) do list[#list + 1] = k end
    if key == "none" then
        if list[i] ~= nil then table.remove(list, i) end
    else
        local it = self.COL_ITEMS[key]
        if it == nil then return false end
        for j, k in ipairs(list) do if k == key and j ~= i then return false end end
        if i <= #list then list[i] = key else list[#list + 1] = key end
        if self:caseColFree(list) < -0.5 then return false end
    end
    self.settings.caseCol = table.concat(list, ",")
    self.colCache = nil
    if self.saveSettings ~= nil then self:saveSettings() end
    return true
end

-- sous-fenêtre (repères écran) pour les pages dessinées : même géométrie que l'ancien caseTractorPage
local function caseSubCtx(ctx, v, PX, PY, x0, y0, x1, y1, full)
    local cx, cy, xr, yb = PX(x0), PY(y0), PX(x1), PY(y1)
    local rx = full and xr or (xr - 140)
    return { text = ctx.text, measure = ctx.measure, rect = ctx.rect, button = ctx.button, hotspot = ctx.hotspot, image = ctx.image,
        cx = cx, cy = cy, cw = full and (xr - cx) or (rx - cx - 6), ch = yb - cy, rx = rx, sideY = cy - 16,
        X = ctx.X, Y = ctx.Y, sx = ctx.sx, sy = ctx.sy, rec = ctx.rec, v = v }
end

-- ACCUEIL = châssis + bloc 2 type A + bloc 4 « Tractor | Lights » de l'écran 05. (03/11) La colonne de droite du
-- bloc 4 (Lights, Configurable Controls, Remotes, Rear Hitch, Front Hitch) change SEULEMENT le bloc 4 ; Lights = retour.
-- (03/11 soir) sprites des boutons de la colonne de droite (châssis : x, y, w, h), découpés dans l'image 05
AS_Terminal.HOME_SUB_SPRITES = { lights = { 1461, 168, 208, 136 }, cc = { 1461, 302, 208, 128 }, remotes = { 1461, 430, 208, 120 },
    hitch_r = { 1461, 550, 208, 124 }, hitch_f = { 1461, 674, 208, 124 } }
AS_Terminal.HOME_SUBS = { { "lights", 1461, 170, 1667, 301, "c_rcLights" }, { "cc", 1461, 305, 1667, 429, "c_rcCc" },
    { "remotes", 1461, 434, 1667, 549, "c_rcRemotes" }, { "hitch_r", 1461, 554, 1667, 671, "hitchR" }, { "hitch_f", 1461, 676, 1667, 790, "hitchF" } }
AS_Terminal.HOME_HOT4 = {   -- touches du bloc 4 de l'accueil : Menu, X, Mem 1 / Mem 2, « ? » = aide du jeu
    { 356, 105, 505, 160, "page_set" }, { 1590, 100, 1660, 160, "close" },
    { 395, 236, 619, 289, "l_mem1" }, { 622, 236, 847, 289, "l_mem2" }, { 890, 236, 926, 284, "help" }, { 1336, 328, 1374, 378, "help" },
}
function AS_Terminal:caseHomeScreen(d, ctx, v, Wp, Hp, inside)
    local PX, PY, PW, img, hot = self:caseChassis(d, ctx, v, Wp, Hp, "A")
    local sub = self.homeSub or "lights"
    local lights = sub == "lights"
    img(345, 94, 1324, 759, lights and "as_case_b4_home" or "as_case_b4_sub")
    for i, h in ipairs(self.HOME_HOT4) do
        if i <= 2 or lights then hot(PX(h[1]), PY(h[2]), PW(h[3] - h[1]), PY(h[4] - h[2]), h[5]) end
    end
    local title = T("c_rcLights")
    -- (03/11 soir) les 10 icônes SANS texte : boîte blanche = sélectionné, bleue = les autres ;
    -- le nom est écrit en direct dans la bande du bas, dans la langue du jeu (FR / EN / DE)
    for _, s in ipairs(self.HOME_SUBS) do
        local x, y, w, h = PX(s[2]), PY(s[3]), PW(s[4] - s[2]), PY(s[5] - s[3])
        hot(x, y, w, h, "hsub_" .. s[1])
        local sp = self.HOME_SUB_SPRITES[s[1]]
        local on = s[1] == sub
        img(sp[1], sp[2], sp[3], sp[4], "as_case_rc_" .. s[1] .. (on and "_w" or "_b"))
        local label = T(s[6])
        caseWrite(ctx, PX(sp[1] + sp[3] * 0.5), PY(sp[2] + sp[4] - 9), PY(19), label, on and "dk" or "wh", RenderText.ALIGN_CENTER, PW(sp[3] - 14))
        if on then title = label end
    end
    if AS_Terminal.LIVE_TEXT then   -- (étape 61) son bouton « Menu » sans texte posé sur celui de l'image, nom en direct
        img(355, 104, 152, 57, "as_case_menu_btn")
        caseWrite(ctx, PX(438), PY(141), PY(20), T("c_menu"), "wh", RenderText.ALIGN_CENTER, PW(90))
    end
    -- titre « Tracteur | Feux » écrit en direct (plus de texte dans l'image)
    caseWrite(ctx, PX(1007), PY(142), PY(32), T("c_tractor") .. " | " .. title, "dk", RenderText.ALIGN_CENTER, PW(700))
    if lights then
        -- (03/11) feux : les boutons (icône noire = éteint, bleue = allumé ; gyrophare gris / orange),
        -- posés sur ceux de l'image ; pleins phares = son bouton 8 (vert)
        local OR = { 0.94, 0.47, 0.0, 1 }
        for _, l in ipairs(self.HOME_LAMPS) do
            local x, y, w, h = PX(l[3]), PY(l[4]), PW(l[5] - l[3]), PY(l[6] - l[4])
            hot(x, y, w, h, "l_" .. l[2])
            local on = lightOn(d, l[2])
            if AS_Terminal.LIVE_TEXT then
                local n = l[2] == "beacon" and "beacon" or l[1]
                img(l[3], l[4], l[5] - l[3], l[6] - l[4], "as_case_lamp_" .. n .. (on and "_on" or "_off"))
            elseif on then caseLampFrame(ctx, x, y, w, h, l[2] == "beacon" and OR or BLUE_CASE) end
        end
        return
    end
    if sub == "hitch_r" or sub == "hitch_f" then self:caseHitchSub(d, ctx, v, PX, PY, PW, hot, sub == "hitch_f")
    elseif sub == "remotes" then self:caseRemotesSub(d, ctx, v, PX, PY, PW, hot, img)
    else
        local ctx2 = caseSubCtx(ctx, v, PX, PY, 385, 240, 1443, 820, false)
        self:page_set(d, ctx2, inside, v)
    end
end

-- bouton bleu du terminal (fond, touche, texte blanc avec sa police)
local function caseBtn(ctx, hot, PX, PY, PW, x, y, w, h, label, act, on)
    ctx.rect(PX(x), PY(y), PW(w), PY(h), on and BLUE_CASE or CASE_BTN_DK)
    hot(PX(x), PY(y), PW(w), PY(h), act)
    caseWrite(ctx, PX(x + w * 0.5), PY(y + h * 0.5 + 11), PY(28), label, "wh", RenderText.ALIGN_CENTER, PW(w - 24))
end

-- Rear Hitch / Front Hitch : outil attelé, état, jauge de position, lever / baisser cet attelage, tout relever / baisser
function AS_Terminal:caseHitchSub(d, ctx, v, PX, PY, PW, hot, front)
    local hf, hr = caseHitches(d)
    local h = front and hf or hr
    local has = h ~= nil and h.object ~= nil
    local CE = RenderText.ALIGN_CENTER
    caseWrite(ctx, PX(903), PY(305), PY(34), has and vehicleName(h.object) or T("empty"), "dk", CE, PW(1000))
    if has then
        caseWrite(ctx, PX(903), PY(365), PY(30), h.moveDown and T("lowered") or T("raised"), "dk", CE, PW(600))
    end
    local gx, gy, gw, gh = 470, 420, 70, 360
    ctx.rect(PX(gx), PY(gy), PW(gw), PY(gh), CASE_GAUGE_BG)
    local fr = has and (h.up or 0) or 0
    if fr > 0.01 then ctx.rect(PX(gx), PY(gy + gh * (1 - fr)), PW(gw), PY(gh * fr), BLUE_GAUGE) end
    caseWrite(ctx, PX(600), PY(640), PY(96), hitchPct(h) .. (has and " %" or ""), "dk", nil, PW(360))
    if has then caseBtn(ctx, hot, PX, PY, PW, 980, 430, 420, 100, h.moveDown and T("doRaise") or T("doLower"), front and "hitch_f" or "hitch_r", true) end
    caseBtn(ctx, hot, PX, PY, PW, 980, 560, 420, 90, T("c_liftAll"), "lift_up", false)
    caseBtn(ctx, hot, PX, PY, PW, 980, 670, 420, 90, T("c_lowerAll"), "lift_dn", false)
    -- (03/11) verrouillage : verrouillé = rien ne baisse cet attelage, cadenas sur la flèche du bloc 1
    local locked = self:hitchLocked(v, front)
    caseWrite(ctx, PX(903), PY(405), PY(28), locked and T("c_locked") or T("c_unlockedSt"), locked and "dk" or "rd", CE, PW(600))
    caseWrite(ctx, PX(760), PY(445), PY(20), T("c_lockHint"), "dk", CE, PW(420))
    caseBtn(ctx, hot, PX, PY, PW, 600, 690, 340, 80, locked and T("c_unlock") or T("c_lock"), front and "hlock_f" or "hlock_r", locked)
end

-- (03/11) Remotes : les 4 télécommandes (boutons N du bloc 2). Chaque télécommande reçoit une fonction au choix
-- (relevage, entraînement, pliage, benne, bâche, aucune), gardée par modèle ; clic sur le bouton N = la fonction
function AS_Terminal:caseRemotesSub(d, ctx, v, PX, PY, PW, hot, img)
    -- (03/11) chaque case = fonction + état voulu, choisis dans le menu déroulant ;
    -- APPLIQUER (ou le bouton de la colonne de gauche) met tout dans ces états ; point allumé = déjà en place
    local rem = self:remoteFns(v)
    local y = 262
    local sw, sh, gap = 215, 50, 10
    for i = 1, 4 do
        local fns = rem[i]
        local inPlace = self:remoteSide(v, i, fns, d)
        ctx.rect(PX(400), PY(y), PW(1010), PY(118), CASE_CARD)
        if self.remoteIcon ~= nil then self.remoteIcon(img, 408, y + 4, i, inPlace)
        else img(408, y + 22, 74, 74, "as_case_la_" .. self.REMOTE_COL[i] .. (inPlace and "" or "_d")) end
        caseWrite(ctx, PX(495), PY(y + 44), PY(26), T("c_remote") .. " " .. i, "dk", nil, PW(300))   -- (22:18) « Fonction N »
        for k = 1, self.REMOTE_SLOTS do
            local fn = fns[k]
            local x = 495 + (k - 1) * (sw + gap)
            ctx.rect(PX(x), PY(y + 60), PW(sw), PY(sh), fn ~= nil and BLUE_CASE or CASE_BTN_DK)
            hot(PX(x), PY(y + 60), PW(sw), PY(sh), "rfn_" .. i .. "_" .. k)
            if fn ~= nil then   -- 2 lignes lisibles : la fonction, puis l'état voulu en gros
                local full = remoteLabel(fn)
                local a, b = full:match("^(.-)%s*:%s*(.+)$")
                caseWrite(ctx, PX(x + sw * 0.5), PY(y + 60 + 19), PY(17), a or full, "wh", RenderText.ALIGN_CENTER, PW(sw - 14))
                caseWrite(ctx, PX(x + sw * 0.5), PY(y + 60 + 43), PY(22), b or "", "wh", RenderText.ALIGN_CENTER, PW(sw - 14))
            elseif k <= #fns + 1 then
                caseWrite(ctx, PX(x + sw * 0.5), PY(y + 60 + sh * 0.5 + 9), PY(24), "+", "wh", RenderText.ALIGN_CENTER, PW(sw - 14))
            end
        end
        if #fns > 0 then
            ctx.rect(PX(1180), PY(y + 60), PW(215), PY(sh), BLUE_CASE)
            hot(PX(1180), PY(y + 60), PW(215), PY(sh), "rem_" .. i)
            caseWrite(ctx, PX(1287), PY(y + 60 + sh * 0.5 + 10), PY(24), T("c_apply"), "wh", RenderText.ALIGN_CENTER, PW(195))
        end
        y = y + 130
    end
    -- (03/11) menus déroulants par choix : la case touchée ouvre la liste (fonction : état)
    local m = self.remoteMenu
    if m ~= nil and m.i >= 1 and m.i <= 4 and m.k >= 1 and m.k <= self.REMOTE_SLOTS then
        local fns = rem[m.i]
        local x = 495 + (m.k - 1) * (sw + gap)
        local rowY = 262 + (m.i - 1) * 130
        -- (03/11) 3 colonnes AV | AR | Les deux : un toucher choisit l'outil (côté) ET l'état
        local rh, cw, cg = 36, 270, 6
        local rows = #self.REMOTE_FNS - 1                          -- sans « Aucun », en bas sur toute la largeur
        local tw = cw * 3 + cg * 2
        local th = rh * (rows + 2)                                 -- en-têtes + fonctions + Aucun
        x = math.max(352, math.min(x, 1662 - tw))
        local top = rowY + 60 + sh                                 -- sous la case si elle tient,
        if top + th > 846 then
            top = rowY + 60 - th                                   -- sinon au-dessus,
            if top < 100 then top = 846 - th end                   -- sinon calée en bas de l'écran
        end
        ctx.rect(PX(x - 3), PY(top - 3), PW(tw + 6), PY(th + 6), CASE_BTN_DK)
        local heads = { { T("c_colF"), "@f" }, { T("c_colR"), "@r" }, { T("c_colB"), "" } }
        local curFn = fns[m.k] or "none"
        for c, hd in ipairs(heads) do
            local cx = x + (c - 1) * (cw + cg)
            ctx.rect(PX(cx), PY(top), PW(cw), PY(rh), BLUE_CASE)
            caseWrite(ctx, PX(cx + cw * 0.5), PY(top + rh * 0.5 + 9), PY(22), hd[1], "wh", RenderText.ALIGN_CENTER, PW(cw - 16))
            for j = 2, #self.REMOTE_FNS do
                local base = self.REMOTE_FNS[j]
                local fn = base .. hd[2]
                local ry = top + (j - 1) * rh
                local cur = curFn == fn
                ctx.rect(PX(cx), PY(ry), PW(cw), PY(rh), cur and BLUE_CASE or CASE_CARD)
                if j > 2 and not cur then ctx.rect(PX(cx), PY(ry), PW(cw), PY(1), CASE_BG) end
                hot(PX(cx), PY(ry), PW(cw), PY(rh), "rsel_" .. m.i .. "_" .. m.k .. "_" .. fn)
                caseWrite(ctx, PX(cx + 10), PY(ry + rh * 0.5 + 8), PY(20), remoteLabel(fn, true), cur and "wh" or "dk", nil, PW(cw - 20))
            end
        end
        local ny = top + (rows + 1) * rh
        ctx.rect(PX(x), PY(ny), PW(tw), PY(rh), curFn == "none" and BLUE_CASE or CASE_CARD)
        ctx.rect(PX(x), PY(ny), PW(tw), PY(1), CASE_BG)
        hot(PX(x), PY(ny), PW(tw), PY(rh), "rsel_" .. m.i .. "_" .. m.k .. "_none")
        caseWrite(ctx, PX(x + tw * 0.5), PY(ny + rh * 0.5 + 8), PY(20), T("none"), curFn == "none" and "wh" or "dk", RenderText.ALIGN_CENTER, PW(tw - 20))
    end
end

-- PERF1 = châssis + bloc 2 type A + bloc 4 de l'écran 02 (18 cases : titre et unité dans l'image, nombres écrits)
AS_Terminal.P1_BOX = { 344, 90, 1670, 840 }
function AS_Terminal:casePerf1Screen(d, ctx, v, Wp, Hp)
    local PX, PY, PW, img, hot = self:caseChassis(d, ctx, v, Wp, Hp, "A")
    img(345, 94, 1324, 759, "as_case_b4_p1")
    local RX, RY, rkx, rky = b4Map(self.P1_BOX)
    hot(PX(RX(1590)), PY(RY(90)), PW(70 * rkx), PY(60 * rky), "close")
    local u = unitsOf()
    local vals = self:casePerf1Values(d, u)
    local fuelLow = d.fuel ~= nil and d.fuel * 100 < self.settings.fuelReserve
    local units = u and { "%", u.vol, "h", "bar", u.vol .. "/h", u.temp, u.temp, "%", "%", u.temp, "%", u.temp, "bar", "%", "bar", "V", "RPM", "RPM" } or nil
    for r, row in ipairs(self.P1_CARDS) do
        for c, card in ipairs(row) do
            local i = (r - 1) * 3 + c
            local set = "dk"
            if (i == 2 and fuelLow) or (i == 7 and (d.temp or 0) > 100) or (i == 14 and (d.slip or 0) > 25) then set = "rd" end
            caseWrite(ctx, PX(RX(card[1])), PY(RY(self.P1_BASE[r])), PY(33 * rky), vals[i], set, RenderText.ALIGN_RIGHT, PW((card[1] - self.P1_X0[c] - 98) * rkx))
            if units ~= nil then   -- (étape 61) nom en haut de la case, unité à droite du nombre, en direct
                caseWrite(ctx, PX(RX(card[2])), PY(RY(self.P1_BASE[r])), PY(28 * rky), units[i], set, RenderText.ALIGN_LEFT, PW(110 * rkx))
                caseWrite(ctx, PX(RX(self.P1_LABEL_X[c])), PY(RY(self.P1_BASE[r] - 50)), PY(26 * rky), T(self.P1_KEYS[i]), "dk", RenderText.ALIGN_CENTER, PW(270 * rkx))
            end
        end
    end
end
AS_Terminal.P1_LABEL_X = { 609, 1026, 1466 }   -- centre du nom de chaque colonne (pixels de l'écran 02)
AS_Terminal.P1_KEYS = { "c_power", "c_fuelLevel", "c_engineHours", "c_oilPress", "c_fuelRate", "c_intakeTemp", "c_coolant", "c_hitchRPos", "c_defLevel",
    "c_transTemp", "c_hitchFPos", "c_defTemp", "c_transPress", "c_slip", "c_airBrake", "c_voltage", "c_ptoR", "c_ptoF" }

-- PERF2 = châssis + bloc 2 type B + bloc 4 de l'écran 08 (6 cases du centre ; engrenage = remise à zéro du compteur)
AS_Terminal.P2_BOX = { 352, 93, 1666, 832 }
function AS_Terminal:casePerf2Screen(d, ctx, v, Wp, Hp)
    local PX, PY, PW, img, hot = self:caseChassis(d, ctx, v, Wp, Hp, "B")
    img(345, 94, 1324, 759, "as_case_b4_p2")
    local RX, RY, rkx, rky = b4Map(self.P2_BOX)
    hot(PX(RX(796)), PY(RY(634)), PW(62 * rkx), PY(58 * rky), "reset")
    local c = d.cnt
    local job = c.jobs[c.active]
    local hpH = job.ms > 60000 and job.ha / (job.ms / 3600000) or 0
    local m = math.floor((job.ms or 0) / 60000)
    local R = RenderText.ALIGN_RIGHT
    local function W(x, y, str, maxW) caseWrite(ctx, PX(RX(x)), PY(RY(y)), PY(41 * rky), str, "dk", R, PW(maxW * rkx)) end
    local u = unitsOf()
    W(642, 192, fr1(d.opHours), 150)
    W(582, 314, fr1(u and u.ha(hpH) or hpH), 100)
    W(642, 437, fr1(u and u.l(job.fuel or 0) or job.fuel), 160)
    W(632, 556, fr1(u and u.l(c.total.fuel or 0) or c.total.fuel), 150)
    local eco = job.ha > 0.01 and job.fuel / job.ha or 0
    W(582, 680, job.ha > 0.01 and fr1(u and u.lha(eco) or eco) or "0,0", 100)
    W(535, 800, string.format("%d", math.floor(m / 60)), 52)
    W(646, 800, string.format("%02d", m % 60), 72)
    if u ~= nil then   -- (étape 61) noms et unités en direct (pixels de l'écran 08)
        local L = RenderText.ALIGN_LEFT
        local function UN(x, y, str) caseWrite(ctx, PX(RX(x)), PY(RY(y)), PY(30 * rky), str, "dk", L, PW(110 * rkx)) end
        UN(660, 192, "h"); UN(598, 314, u.area .. "/h"); UN(660, 437, u.vol); UN(650, 556, u.vol); UN(598, 680, u.vol .. "/" .. u.area)
        UN(548, 800, "h"); UN(662, 800, "min")
        local keys = { "c_engineHours", "c_workRateAvg", "c_fuelUsed", "c_fuelUsedWork", "c_fuelAvg", "c_workTime" }
        local bases = { 131, 255, 381, 505, 626, 750 }
        for i, k in ipairs(keys) do caseWrite(ctx, PX(RX(486)), PY(RY(bases[i])), PY(26 * rky), T(k), "dk", L, PW(430 * rkx)) end
        caseWrite(ctx, PX(RX(1042)), PY(RY(141)), PY(26 * rky), T("c_flowRetract"), "dk", L, PW(300 * rkx))
        caseWrite(ctx, PX(RX(1042)), PY(RY(248)), PY(26 * rky), T("c_flowExtend"), "dk", L, PW(300 * rkx))
        caseWrite(ctx, PX(RX(1400)), PY(RY(141)), PY(26 * rky), T("c_engineMode"), "dk", L, PW(175 * rkx))
        caseWrite(ctx, PX(RX(1400)), PY(RY(248)), PY(26 * rky), T("c_timer"), "dk", L, PW(175 * rkx))
        -- curseurs (0 … 100), interrupteurs OFF, et panneau du milieu : nombre d'outils, relevages AR / AV, rapport
        local function S(x, y, h, str, set, al, mw) caseWrite(ctx, PX(RX(x)), PY(RY(y)), PY(h * rky), str, set or "dk", al or L, PW((mw or 120) * rkx)) end
        S(1122, 185, 28, "0"); S(1260, 213, 20, "100"); S(1122, 290, 28, "0"); S(1260, 318, 20, "100")
        -- OFF centré dans la partie sombre de l'interrupteur
        S(1460, 188, 24, "OFF", "wh", RenderText.ALIGN_CENTER, 70); S(1460, 293, 24, "OFF", "wh", RenderText.ALIGN_CENTER, 70)
        local nTools = 0
        for _, t in ipairs(d.tools or {}) do if t.object ~= v then nTools = nTools + 1 end end
        local hf, hr = caseHitches(d)
        S(1087, 410, 40, string.format("%d", nTools), "dk", L, 60)
        S(1440, 366, 24, hitchPct(hr) .. (hr ~= nil and hr.object ~= nil and " %" or ""), "dk", RenderText.ALIGN_RIGHT, 160)
        S(1157, 441, 24, hitchPct(hf) .. (hf ~= nil and hf.object ~= nil and " %" or ""), "dk", L, 160)
        local gear = tostring(d.gear or "N")
        if d.cvt then gear = (d.dir or 0) < 0 and "R" or ((d.dir or 0) > 0 and "D" or "N") end
        S(1617, 410, 40, gear, "dk", L, 60)
    end
    -- (03/11 soir) caméra arrière vivante dans la case caméra, fenêtre 2D seulement
    -- (l'écran 3D de la cabine garde la photo) ; toucher l'image = marche / arrêt (réglage gardé)
    local CB = self.P2_CAM
    local cx, cy, cw, ch = PX(RX(CB[1])), PY(RY(CB[2])), PW((CB[3] - CB[1]) * rkx), PY((CB[4] - CB[2]) * rky)
    -- (03/11) plus de photo : noir, puis la caméra dessus
    ctx.rect(cx, cy, cw, ch, { 0, 0, 0, 1 })
    if ctx.rec == nil then
        hot(cx, cy, cw, ch, "rearcam")
        if self.settings.rearCam ~= false then
            local ov = self:rearCamOverlay(v)
            if ov ~= nil then ctx.image(cx, cy, cw, ch, ov) end
        else
            caseWrite(ctx, cx + cw * 0.5, cy + ch - PY(14), PY(22), T("c_camOff"), "wh", RenderText.ALIGN_CENTER, cw - PW(20))
        end
    end
end
AS_Terminal.P2_CAM = { 953, 471, 1600, 827 }   -- la photo de la case caméra dans l'écran 08

-- (03/11) onglet Caméra = page caméra arrière en grand :
-- tout le bloc 4 en noir, l'image de la caméra dessus (16:9) dès qu'elle marche ; toucher = marche / arrêt
function AS_Terminal:caseCamScreen(d, ctx, v, Wp, Hp)
    local PX, PY, PW, img, hot = self:caseChassis(d, ctx, v, Wp, Hp, "B")
    local bx, by, bw, bh = 345, 94, 1324, 759
    ctx.rect(PX(bx), PY(by), PW(bw), PY(bh), { 0, 0, 0, 1 })
    local P = self.REAR_CAM
    local cw = bw - 20
    local ch = cw * P.resY / P.resX
    if ch > bh - 20 then ch = bh - 20; cw = ch * P.resX / P.resY end
    local cx, cy = bx + (bw - cw) * 0.5, by + (bh - ch) * 0.5
    if ctx.rec ~= nil then return end
    hot(PX(bx), PY(by), PW(bw), PY(bh), "rearcam")
    if self.settings.rearCam ~= false then
        local ov = self:rearCamOverlay(v)
        if ov ~= nil then ctx.image(PX(cx), PY(cy), PW(cw), PY(ch), ov) end
    else
        caseWrite(ctx, PX(bx + bw * 0.5), PY(by + bh * 0.5 + 12), PY(26), T("c_camOff"), "wh", RenderText.ALIGN_CENTER, PW(bw - 40))
    end
end

-- Caméra arrière = 2e caméra du jeu accrochée au tracteur (haut de l'arrière, regard vers le bas), rendue dans un
-- calque (createRenderOverlay) rafraîchi seulement pendant que la page PERF2 est affichée ; libérée 2 s après.
-- Réglable en jeu : console asRearCam (x y z pitch yaw fov, ex. « asRearCam pitch -30 », « asRearCam yaw 180 »).
-- (03/11) caméra : résolution et niveau graphique réduits :
-- effets déjà tous coupés (ombres, bloom, flou, SSAO, atmosphère) ; résolution 320x180, vue 150 m, 15 images/s
-- (03/11) encore moins de détails : 256x144, vue 70 m, 10 images/s
AS_Terminal.REAR_CAM = { x = 0, y = -0.35, z = 0.4, pitch = -22, yaw = 0, fov = 72, resX = 256, resY = 144, far = 70, fps = 10 }
function AS_Terminal:rearCamOverlay(v)
    if createRenderOverlay == nil or createCamera == nil or getRootNode == nil or v == nil or v.rootNode == nil or self.rearCamFailed then return nil end
    local rc = self.rearCam
    if rc ~= nil and rc.vehicle ~= v then self:rearCamDelete(); rc = nil end
    if rc == nil then
        rc = { vehicle = v }
        local P = self.REAR_CAM
        local ok, err = pcall(function()
            local cam = createCamera("asRearCam", math.rad(P.fov), 0.3, P.far or 150)
            link(v.rootNode, cam)
            local size = v.size or {}
            local zRear = (size.lengthOffset or 0) - (size.length or 5) * 0.5
            local yTop = (size.heightOffset or 0) + (size.height or 3)
            setTranslation(cam, P.x, yTop + P.y, zRear + P.z)
            setRotation(cam, math.rad(P.pitch), math.rad(P.yaw), 0)
            rc.camera = cam
            -- (03/11) signature FS25 de RenderElement.lua :
            -- scène, caméra, ratio, largeur, hauteur, alpha, masque formes, masque lumières, ombres, bloom,
            -- profondeur de champ, SSAO, shaders asynchrones, qualité d'atmosphère
            local atmo = (AtmosphereQuality ~= nil and AtmosphereQuality.OFF) or 0
            rc.overlay = createRenderOverlay(getRootNode(), cam, P.resX / P.resY, P.resX, P.resY, true, 4294967295, 4294967295, false, 0, false, 0, false, atmo)
        end)
        if not ok or rc.overlay == nil or rc.overlay == 0 then
            log("caméra arrière impossible : %s", tostring(err))
            self.rearCam = rc; self:rearCamDelete()
            self.rearCamFailed = true
            return nil
        end
        self.rearCam = rc
        log("caméra arrière créée (%s)", tostring(vehicleName(v)))
    end
    rc.lastUse = g_time or 0
    -- rendu de la 2e caméra seulement P.fps fois par seconde (le calque garde la dernière image entre deux)
    local now = g_time or 0
    if rc.lastRender == nil or now - rc.lastRender >= 1000 / math.max(1, self.REAR_CAM.fps or 10) - 5 then   -- - 5 ms : tolérance pour tenir le rythme à 60 images/s
        rc.lastRender = now
        pcall(updateRenderOverlay, rc.overlay)
    end
    return rc.overlay
end
function AS_Terminal:rearCamDelete()
    local rc = self.rearCam
    if rc == nil then return end
    self.rearCam = nil
    if rc.overlay ~= nil and rc.overlay ~= 0 then pcall(delete, rc.overlay) end
    if rc.camera ~= nil and rc.camera ~= 0 and (entityExists == nil or entityExists(rc.camera)) then pcall(delete, rc.camera) end
end
function AS_Terminal:consoleRearCam(key, val)
    local P = self.REAR_CAM
    if key ~= nil and P[key] ~= nil and tonumber(val) ~= nil then
        P[key] = tonumber(val)
        self:rearCamDelete(); self.rearCamFailed = nil
    end
    return string.format("asRearCam : x %.2f y %.2f z %.2f pitch %.0f yaw %.0f fov %.0f resX %d resY %d far %d fps %d (y, z : depuis le haut de l'arrière du tracteur)",
        P.x, P.y, P.z, P.pitch, P.yaw, P.fov, P.resX, P.resY, P.far or 150, P.fps or 15)
end

-- CARTE = châssis + bloc 2 type A + bloc 4 de l'écran 13 (notre carte dans le cadre, boutons flottants, barre de droite)
AS_Terminal.MAP_B4 = { 341, 90, 1771, 792 }   -- bloc 4 dans l'écran 13 (1774 x 887)
function AS_Terminal:caseMapScreen(d, ctx, v, Wp, Hp, inside)
    local PX, PY, PW, img, hot = self:caseChassis(d, ctx, v, Wp, Hp, "A")
    img(345, 94, 1324, 759, "as_case_b4_map")
    local RX, RY, rkx, rky = b4Map(self.MAP_B4)
    for i, h in ipairs(self.MAP_HOT) do
        if i > 8 then hot(PX(RX(h[1])), PY(RY(h[2])), PW((h[3] - h[1]) * rkx), PY((h[4] - h[2]) * rky), h[5]) end
    end
    local B = self.MAP_BOX
    local cx, cy, cw, ch = PX(RX(B[1])), PY(RY(B[2])), PW((B[3] - B[1]) * rkx), PY((B[4] - B[2]) * rky)
    local ctx2 = { text = ctx.text, measure = ctx.measure, rect = ctx.rect, button = ctx.button, hotspot = ctx.hotspot, image = ctx.image,
        cx = cx, cy = cy, cw = cw, ch = ch, rx = cx + cw, sideY = cy, X = ctx.X, Y = ctx.Y, sx = ctx.sx, sy = ctx.sy, rec = ctx.rec, v = v, noKeys = true,
        gpsTextsX = PX(RX(self.MAP_BTN[2][4] + 12)) }   -- (03/11 22:11) textes système / état / rang sous le bandeau, après le bouton vue
    self:page_gps(d, ctx2, inside, v)
    self:caseCpColumn(d, ctx, v, PX, PY, PW, hot)
    for _, b in ipairs(self.MAP_BTN) do
        local w, h = (b[4] - b[2]) * rkx, (b[5] - b[3]) * rky
        local sq = math.max(w, h)
        local mx, my = RX((b[2] + b[4]) * 0.5), RY((b[3] + b[5]) * 0.5)
        local fb = caseImg(b[1])
        ctx.image(PX(mx - sq * 0.5), PY(my - sq * 0.5), PW(sq), PY(sq), ctx.rec == nil and AS_TerminalTools ~= nil and AS_TerminalTools:overlay(fb) or nil, "img_" .. b[1], fb)
        if b[6] ~= nil then hot(PX(RX(b[2])), PY(RY(b[3])), PW(w), PY(h), b[6]) end
    end
    local hd = "-"
    if v ~= nil and v.rootNode ~= nil then
        local okD, dx, _, dz = pcall(localDirectionToWorld, v.rootNode, 0, 0, 1)
        if okD and dx ~= nil then hd = string.format("%.1f°", (math.deg(math.atan2(dx, dz)) + 360) % 360) end
    end
    caseWrite(ctx, PX(RX(416)), PY(RY(197)), PY(17 * rky), hd, "wh", RenderText.ALIGN_CENTER, PW(64 * rkx))
end

-- (03/11) colonne Courseplay à droite de la carte (à la place de la barre d'outils de l'écran 13).
-- Parcours chargé : DÉMARRER / ARRÊTER, point de départ, enregistrer sous le nom du champ, décalage outil, réinitialiser.
-- Sans parcours : créer (menu classique Courseplay), chercher le travail du champ le plus proche, largeur de travail.
local CP_COL_BG = { 0.027, 0.075, 0.122, 1 }
local CP_BTN = { 0.10, 0.17, 0.26, 1 }
local CP_GREEN = { 0.05, 0.55, 0.22, 1 }
local CP_RED = { 0.70, 0.12, 0.10, 1 }
function AS_Terminal:cpCourseName(v, d)
    local w = AS_TerminalCourses ~= nil and AS_TerminalCourses.toolWidth ~= nil and AS_TerminalCourses.toolWidth(d) or nil
    local base = d.field ~= nil and string.format(T("field"), d.field) or vehicleName(v)
    if w ~= nil then return string.format("%s - %s m", base, (string.format("%.1f", w):gsub("%%.0$", ""))) end
    return base
end
function AS_Terminal:caseCpColumn(d, ctx, v, PX, PY, PW, hot)
    -- (03/11 soir) boutons arrondis comme ceux de la colonne
    -- de droite de son accueil (dégradé teal), vert / rouge pour DÉMARRER / ARRÊTER, boîtes sombres pour les valeurs
    local X0, W = 1357, 312
    ctx.rect(PX(X0), PY(94), PW(W), PY(759), CP_COL_BG)
    if not cpInstalled() then return end   -- (13/11) sans Courseplay : colonne vide
    local g = d.gps or {}
    local cxm = X0 + W * 0.5
    local M = 18
    local function sprite(x, y, w, h, name)
        local f = caseImg(name)
        ctx.image(PX(x), PY(y), PW(w), PY(h), ctx.rec == nil and AS_TerminalTools ~= nil and AS_TerminalTools:overlay(f) or nil, "img_" .. name, f)
    end
    local function btn(y, h, label, act, kind, x, w, size)
        x, w = x or (X0 + M), w or (W - 2 * M)
        sprite(x, y, w, h, "as_case_btn_" .. (kind or "teal"))
        if act ~= nil then hot(PX(x), PY(y), PW(w), PY(h), act) end
        caseWrite(ctx, PX(x + w * 0.5), PY(y + h * 0.5 + (size or 26) * 0.38), PY(size or 26), label, "wh", RenderText.ALIGN_CENTER, PW(w - 20))
    end
    local function lbl(y, txt, size, set) caseWrite(ctx, PX(cxm), PY(y), PY(size or 20), txt, set or "wh", RenderText.ALIGN_CENTER, PW(W - 24)) end
    -- en-tête
    lbl(134, "COURSEPLAY", 24)
    ctx.rect(PX(X0 + M), PY(146), PW(W - 2 * M), PY(3), { 0.01, 0.49, 0.65, 1 })
    if g.hasCp ~= true then lbl(320, T("cpMissing"), 20) return end
    local sw = 62                                   -- trois cases : [-] valeur [+]
    local mw = W - 2 * M - 2 * (sw + 10)
    local function trio(y, h, left, mid, right, actL, actR)
        btn(y, h, left, actL, "teal", X0 + M, sw, 30)
        btn(y, h, mid, nil, "dark", X0 + M + sw + 10, mw, 24)
        btn(y, h, right, actR, "teal", X0 + M + sw + 10 + mw + 10, sw, 30)
    end
    if g.data ~= nil then
        local active = g.active == true
        local lost = not active and AS_TerminalGps ~= nil and AS_TerminalGps.rtkLost ~= nil and AS_TerminalGps:rtkLost(v)
        btn(170, 66, active and T("cpStop") or T("cpGo"), "gps_steer", active and "red" or (lost and "dark" or "green"), nil, nil, 28)   -- (22:47) sombre = pas de RTK
        lbl(276, T("cpStart"), 19)
        local st = call(v, "getCpStartingPointSetting")
        local okS, sv = pcall(function() return st:getString() end)
        btn(286, 54, okS and tostring(sv) or "-", "cp_start", "teal", nil, nil, 24)
        lbl(382, T("c_cpSave"), 19)
        btn(392, 54, self:cpCourseName(v, d), "cp_save", "teal", nil, nil, 24)
        lbl(488, T("gps_offset"), 19)
        trio(498, 54, "-", g.offset ~= nil and (string.format("%+.2f m", g.offset):gsub("%%.", ",")) or "-", "+", "gps_shiftL", "gps_shiftR")
        hot(PX(X0 + M + sw + 10), PY(498), PW(mw), PY(54), "gps_off0")   -- la valeur : remise à zéro
        btn(600, 58, T("c_cpReset"), "cp_clear", "dark", nil, nil, 24)
        local state = active and T("cpActive") or (lost and T("gps_noRtk") or (g.canStart and T("cpReady") or T("cpNotReady")))
        lbl(720, state, 22)
        if g.rows ~= nil then lbl(758, string.format(T("gps_courseInfo"), g.rows or 0, g.nHl or 0, (g.data.length or 0) / 1000), 17) end
    else
        btn(170, 66, T("cpGenerate"), "cp_cgui", "green", nil, nil, 26)
        btn(256, 66, T("cpFind"), "cp_find", "teal", nil, nil, 26)
        -- (03/11) sous CHERCHER TRAVAIL : CHARGER SAUVEGARDE ; (22:42) = ouvre DIRECTEMENT le
        -- gestionnaire des courses de Courseplay (sa liste de dossiers et de parcours)
        btn(342, 66, T("cpLoadSave"), "cp_saves", "teal", nil, nil, 24)
        lbl(468, T("cpWidth"), 19)
        local cs = call(v, "getCourseGeneratorSettings")
        local okW, wv = pcall(function() return cs.workWidth:getString() end)
        trio(478, 54, "-", okW and tostring(wv) or "-", "+", "cp_w-", "cp_w+")
        lbl(720, T("cpNoCourse"), 22)
    end
end

-- autres pages (Relevage, Réglages, GPS FarmPilot, Courseplay, ...) : châssis + bloc 4 vide (carte blanche, titre) avec
-- l'ancien contenu dessiné dedans, en attendant les écrans ; Isobus = cadre UT de l'écran 12 + contenu vivant
function AS_Terminal:caseTractorPage(d, ctx, v, Wp, Hp, inside, title)
    local PX, PY, PW, img, hot = self:caseChassis(d, ctx, v, Wp, Hp, self.B2_TYPE[self.page] or "A")
    local isUT = self.page == "tool"
    local ctx2
    if isUT then
        img(345, 94, 1324, 759, "as_case_b4_ut")
        ctx2 = caseSubCtx(ctx, v, PX, PY, 345, 150, 1669, 853, true)
    else
        ctx.rect(PX(345), PY(94), PW(1324), PY(759), CASE_BG)
        ctx.rect(PX(365), PY(114), PW(1284), PY(719), B4_WHITE)
        caseWrite(ctx, PX(1007), PY(160), PY(30), title or "", "dk", RenderText.ALIGN_CENTER, PW(900))
        ctx2 = caseSubCtx(ctx, v, PX, PY, 385, 190, 1639, 823, false)
    end
    local fn = self["page_" .. self.page]
    if fn ~= nil then fn(self, d, ctx2, inside, v) end
end

-- ===================================================================================================================
-- (04/11) TERMINAL CLAAS : CEBIS + CEMIS en UN seul terminal, châssis clair de l'écran 02 (barre du haut,
-- colonne de droite, barre du bas), centre (1400 x 750 à 0,86) par page. Démarrage : écran de chargement puis écran de
-- choix (logo CLAAS, On Road / On Field, choix libre). Textes effacés des images et écrits en direct.
-- Repères en pixels de l'écran 1672 x 941 (comme le Case).
-- ===================================================================================================================
AS_Terminal.CLAAS_CELLS = { { 88, 200, "page_tractor", "cl_transmission" }, { 200, 306, "cl_hitchpage", "cl_hitch" }, { 306, 407, "cl_hydpage", "cl_hydraulic" },
    { 407, 505, "page_cp", "cl_csm" }, { 505, 606, "page_fp", "cl_steering" }, { 606, 712, "page_tool", "cl_tasks" }, { 712, 836, "page_count", "cl_counters" } }
AS_Terminal.CLAAS_LABEL_Y = { 170, 281, 381, 478, 579, 687, 798 }
local CL_DK = { 0.10, 0.10, 0.10, 1 }
local CL_WH = { 0.92, 0.92, 0.92, 1 }
local CL_GREEN = { 0.77, 0.85, 0.02, 1 }
local CL_GREEN_TXT = { 0.62, 0.74, 0.0, 1 }
local CL_BG = { 0.925, 0.925, 0.93, 1 }
local CL_BAR_GREY = { 0.62, 0.62, 0.63, 1 }
local CL_BAR_BLACK = { 0.13, 0.13, 0.13, 1 }
AS_Terminal.claasViews = setmetatable({}, { __mode = "k" })

-- vue choisie (nil = écran de choix) ; remise à nil moteur coupé : au démarrage suivant, chargement puis choix
function AS_Terminal:claasView(v)
    return v ~= nil and self.claasViews[v] or nil
end
function AS_Terminal:claasSetView(v, view)
    if v ~= nil then self.claasViews[v] = view end
end

-- textes : y = milieu de la ligne (comme mes aperçus), converti en ligne de base
local function clText(ctx, PX, PY, PW, x, ymid, size, s, col, align, maxW)
    ctx.text(PX(x), PY(ymid + size * 0.36), PY(size), s, col or CL_DK, align or RenderText.ALIGN_LEFT, true, maxW and PW(maxW) or nil)
end

function AS_Terminal:claasChassis(d, ctx, v, Wp, Hp, sel, title, view)
    local kx, ky = Wp / self.HOME_W, Hp / self.HOME_H
    local function PX(x) return x * kx end
    local function PY(y) return y * ky end
    local function PW(w) return w * kx end
    local function img(x, y, w, h, name)
        local f = caseImg(name)
        ctx.image(PX(x), PY(y), PW(w), PY(h), ctx.rec == nil and AS_TerminalTools ~= nil and AS_TerminalTools:overlay(f) or nil, "img_" .. name, f)
    end
    local hot = ctx.hotspot or ctx.button
    img(0, 0, self.HOME_W, self.HOME_H, "as_claas_chassis")
    self.headerBox = { x = ctx.X(PX(110)), y = ctx.Y(PY(0)), w = ctx.sx(PX(400)), h = ctx.sy(PY(86)) }
    -- barre du haut : grille = écran de choix, icône + titre, flèche = autre vue, menu = réglages
    hot(PX(10), PY(6), PW(92), PY(76), "cl_choice")
    img(130, 16, 80, 58, view == "road" and "as_claas_ico_road" or "as_claas_ico_field")
    clText(ctx, PX, PY, PW, 235, 43, 38, title or "", CL_DK, nil, 215)
    hot(PX(440), PY(6), PW(76), PY(76), "cl_toggle")
    -- (04/11) antenne : rouge hors champ (pas de réseau), verte dans un champ ; clic = Guidage
    img(565, 4, 110, 78, d.field ~= nil and "as_claas_ant_on" or "as_claas_ant_off")
    if cpInstalled() then hot(PX(560), PY(4), PW(120), PY(80), "page_cp") end
    hot(PX(1575), PY(6), PW(92), PY(76), "page_set")
    -- colonne de droite : la case active en vert, noms écrits en direct
    -- (04/11) Direction = « FarmPilot » quand il est là, sinon case vide (sans icône ni clic)
    local fpOk = AS_TerminalFp ~= nil and AS_TerminalFp.available ~= nil and AS_TerminalFp:available(v) == true
    for k, c in ipairs(self.CLAAS_CELLS) do
        local label = T(c[4])
        if c[3] == "page_fp" then label = "FarmPilot" end
        if (c[3] == "page_fp" and not fpOk) or (c[3] == "page_cp" and not cpInstalled()) then
            img(1404, c[1] + 3, 264, c[2] - c[1] - 5, "as_claas_col5_off")   -- fond de la case, sans icône
        else
            hot(PX(1402), PY(c[1]), PW(268), PY(c[2] - c[1]), c[3])
            if k == sel then img(1402, c[1] + 2, 268, c[2] - c[1] - 3, "as_claas_col" .. k .. "_on") end
            clText(ctx, PX, PY, PW, 1536, self.CLAAS_LABEL_Y[k], 30, label, CL_DK, RenderText.ALIGN_CENTER, 250)
        end
    end
    -- barre du bas : heure, mode, vitesse, régime / régime maxi ; compteur = page INFO
    local u = unitsOf()
    local env = g_currentMission ~= nil and g_currentMission.environment or nil
    clText(ctx, PX, PY, PW, 30, 868, 36, fmtClock(), CL_WH)
    if env ~= nil and env.currentDay ~= nil then clText(ctx, PX, PY, PW, 30, 910, 28, string.format(T("cl_day"), env.currentDay), CL_WH, nil, 165) end
    local mode
    if d.guide ~= nil then mode = T("g_" .. d.guide) elseif d.manual == true then mode = T("manual") else mode = T("auto") end
    clText(ctx, PX, PY, PW, 660, 890, 32, mode, CL_GREEN, RenderText.ALIGN_CENTER, 150)
    -- (04/11) AUTO / MANUEL = différentiels et 4 roues motrices gérés par AutoSwitch ou à la main ; clic = bascule
    if d.guide == nil then hot(PX(598), PY(850), PW(162), PY(80), "cl_diffmode") end
    -- (04/11) accès rapides CEBIS : 4 cases dans la zone libre, entre l'heure et AUTO (flèches retirées)
    self:claasQuickBar(ctx, v, PX, PY, PW, img, hot)
    local spd = math.abs(d.speed or 0)
    clText(ctx, PX, PY, PW, 1080, 890, 50, string.format("%.1f", u and u.kmh(spd) or spd), CL_WH, RenderText.ALIGN_RIGHT)
    clText(ctx, PX, PY, PW, 1092, 892, 28, u and u.speed or "km/h", CL_WH)
    clText(ctx, PX, PY, PW, 1305, 866, 28, string.format("%d %s", math.floor((d.rpm or 0) + 0.5), T("cl_rpm")), CL_WH, nil, 240)
    clText(ctx, PX, PY, PW, 1305, 910, 28, string.format("%d %s", math.floor((d.maxRpm or 0) + 0.5), T("cl_rpm")), CL_WH, nil, 240)
    hot(PX(1560), PY(845), PW(105), PY(90), "page_tractor")
    return PX, PY, PW, img, hot
end

-- écran de choix : logo CLAAS, On Road / On Field
function AS_Terminal:claasChoiceScreen(d, ctx, v, Wp, Hp)
    local kx, ky = Wp / self.HOME_W, Hp / self.HOME_H
    local function PX(x) return x * kx end
    local function PY(y) return y * ky end
    local function PW(w) return w * kx end
    local f = caseImg("as_claas_choice")
    ctx.image(0, 0, Wp, Hp, ctx.rec == nil and AS_TerminalTools ~= nil and AS_TerminalTools:overlay(f) or nil, "img_as_claas_choice", f)
    local hot = ctx.hotspot or ctx.button
    hot(PX(236), PY(420), PW(560), PY(360), "cl_road")
    hot(PX(876), PY(420), PW(560), PY(360), "cl_field")
    clText(ctx, PX, PY, PW, 516, 710, 54, T("cl_onRoad"), CL_DK, RenderText.ALIGN_CENTER, 520)
    clText(ctx, PX, PY, PW, 1156, 710, 54, T("cl_onField"), CL_DK, RenderText.ALIGN_CENTER, 520)
end

-- On Field (l'écran 02) : silhouette, relevages AV / AR, 6 distributeurs, infos travail, vitesse, touches F
-- (04/11) barres du compte-tours de On Field (x, y, l, h écran) et étiquettes de l'échelle
AS_Terminal.CLAAS_RPM_BARS = { { 1007, 409, 43, 90 }, { 1023, 404, 40, 90 }, { 1039, 399, 37, 91 }, { 1055, 395, 34, 92 }, { 1071, 392, 32, 92 }, { 1088, 389, 28, 92 }, { 1105, 387, 25, 92 }, { 1121, 386, 22, 91 }, { 1138, 385, 19, 91 }, { 1155, 385, 16, 91 }, { 1171, 385, 17, 91 }, { 1185, 385, 19, 91 }, { 1199, 386, 22, 92 }, { 1212, 388, 26, 91 }, { 1226, 390, 28, 91 }, { 1239, 393, 32, 91 }, { 1253, 396, 34, 91 }, { 1266, 400, 38, 91 }, { 1279, 405, 41, 90 }, { 1292, 410, 44, 89 } }
AS_Terminal.CLAAS_RPM_LABS = { { 994, 382 }, { 1052, 364 }, { 1111, 353 }, { 1171, 350 }, { 1232, 354 }, { 1291, 365 }, { 1349, 382 } }
function AS_Terminal:claasFieldScreen(d, ctx, v, Wp, Hp)
    local PX, PY, PW, img, hot = self:claasChassis(d, ctx, v, Wp, Hp, 0, T("cl_onField"), "field")
    img(0, 86, 1400, 750, "as_claas_b4_field")
    local u = unitsOf()
    clText(ctx, PX, PY, PW, 130, 132, 28, string.format("%s %d %%", T("cl_load"), math.floor((d.load or 0) * 100 + 0.5)), CL_DK, nil, 420)
    clText(ctx, PX, PY, PW, 130, 172, 28, string.format("%s %d %%", T("cl_slip"), math.floor((d.slip or 0) + 0.5)), CL_DK, nil, 420)
    clText(ctx, PX, PY, PW, 748, 194, 28, string.format("%d %s", math.floor((d.rpm or 0) + 0.5), T("cl_rpm")), CL_DK, RenderText.ALIGN_CENTER, 200)
    -- relevages : barre gauche = avant, droite = arrière (le tracteur regarde à gauche) ; vert = hauteur (levé = 100 %, en bas = 0 %)
    local hf, hr = caseHitches(d)
    local function bar(x, h)
        ctx.rect(PX(x), PY(220), PW(42), PY(237), CL_BAR_GREY)
        if h ~= nil and h.object ~= nil then
            local fr = math.max(0, math.min(1, h.up or 0))
            if fr > 0.01 then ctx.rect(PX(x), PY(220 + 237 * (1 - fr)), PW(42), PY(237 * fr), CL_GREEN) end
        end
    end
    bar(54, hf); bar(852, hr)
    clText(ctx, PX, PY, PW, 75, 486, 28, hitchPct(hf) == "N" and "N" or (hitchPct(hf) .. " %"), CL_DK, RenderText.ALIGN_CENTER, 90)
    clText(ctx, PX, PY, PW, 870, 486, 28, hitchPct(hr) == "N" and "N" or (hitchPct(hr) .. " %"), CL_DK, RenderText.ALIGN_CENTER, 90)
    hot(PX(40), PY(210), PW(160), PY(260), "hitch_f")
    hot(PX(780), PY(210), PW(130), PY(260), "hitch_r")
    -- (04/11) vérins sous le tracteur : jaune = relevage AV, blanc = relevage AR,
    -- bleu / orange / vert / violet = Fonction 1 / 2 / 3 / 4 (même icône dans la page Hydraulique)
    local rem = self:remoteFns(d.vehicle)
    local XS = { 113, 238, 402, 506, 622, 745 }
    for k, x in ipairs(XS) do
        ctx.rect(PX(x), PY(652), PW(44), PY(126), CL_BAR_BLACK)
        if k <= 2 then
            local h = k == 1 and hf or hr
            if h ~= nil and h.object ~= nil then
                local fr = math.max(0, math.min(1, h.up or 0))
                if fr > 0.01 then ctx.rect(PX(x + 3), PY(655 + 120 * (1 - fr)), PW(38), PY(120 * fr), CL_GREEN) end
            end
            hot(PX(x - 12), PY(528), PW(68), PY(254), k == 1 and "hitch_f" or "hitch_r")
            if h == nil or h.object == nil then clText(ctx, PX, PY, PW, x + 22, 610, 34, "N", CL_DK, RenderText.ALIGN_CENTER) end
        else
            local i = k - 2
            local has = rem[i] ~= nil and #rem[i] > 0
            if has and self:remoteSide(d.vehicle, i, rem[i], d) then ctx.rect(PX(x + 3), PY(655), PW(38), PY(120), CL_GREEN) end
            if has then hot(PX(x - 10), PY(648), PW(64), PY(134), "rem_" .. i)
            else clText(ctx, PX, PY, PW, x + 22, 610, 34, "N", CL_DK, RenderText.ALIGN_CENTER) end   -- (04/11) N = pas de fonction
            -- clic sur le vérin de couleur = page Hydraulique (fonctions), comme le Case
            hot(PX(x - 12), PY(528), PW(68), PY(110), "cl_remotes")
        end
    end
    -- infos travail (colonne du milieu)
    local job = d.cnt ~= nil and d.cnt.jobs[d.cnt.active] or nil
    local ha = job ~= nil and job.ha or 0
    clText(ctx, PX, PY, PW, 1050, 122, 32, string.format("%.2f %s", u and u.ha(ha) or ha, u and u.area or "ha"), CL_DK, nil, 330)
    clText(ctx, PX, PY, PW, 1050, 182, 32, string.format("%d %s", math.floor(u and u.l(d.fuelL or 0) or (d.fuelL or 0)), u and u.vol or "L"), CL_DK, nil, 330)
    clText(ctx, PX, PY, PW, 1050, 238, 32, string.format("%.1f %s/h", u and u.l(d.fuelUse or 0) or (d.fuelUse or 0), u and u.vol or "L"), CL_DK, nil, 330)
    clText(ctx, PX, PY, PW, 1050, 296, 32, tostring(d.name or "CLAAS"), CL_DK, nil, 330)
    -- (04/11) compte-tours noir : les barres vertes montent avec le régime (20 barres, échelle x100 tr/min)
    local top = math.max(2400, math.ceil((d.maxRpm or 0) / 400) * 400)
    local rpm = d.motorOn ~= false and (d.rpm or 0) or 0
    local nOn = math.floor(math.max(0, math.min(1, rpm / top)) * #self.CLAAS_RPM_BARS + 0.5)
    for k = 1, nOn do
        local b = self.CLAAS_RPM_BARS[k]
        img(b[1], b[2], b[3], b[4], string.format("as_claas_rpm%02d", k))
    end
    for i, l in ipairs(self.CLAAS_RPM_LABS) do
        clText(ctx, PX, PY, PW, l[1], l[2], 24, tostring(math.floor(top / 600 * (i - 1) + 0.5)), CL_DK, RenderText.ALIGN_CENTER)
    end
    local spd = math.abs(d.speed or 0)
    clText(ctx, PX, PY, PW, 1275, 520, 46, string.format("%.1f", u and u.kmh(spd) or spd), CL_GREEN_TXT, RenderText.ALIGN_RIGHT)
    -- (04/11) lapin ou tortue selon la vitesse (tortue jusqu'à 15 km/h)
    img(1049, 519, 48, 48, spd > 15 and "as_claas_hare" or "as_claas_turtle")
    local cs = (d.cruise ~= nil and d.cruise ~= 0) and d.cruiseSpeed or d.workSpeed
    clText(ctx, PX, PY, PW, 1275, 575, 46, cs ~= nil and string.format("%.1f", u and u.kmh(cs) or cs) or "--.-", { 0.24, 0.12, 0.12, 1 }, RenderText.ALIGN_RIGHT)
end

-- On Road (l'écran 01) : vitesse, régime, carburant, AdBlue, température, infos, régulateur, touches F
function AS_Terminal:claasRoadScreen(d, ctx, v, Wp, Hp)
    local PX, PY, PW, img, hot = self:claasChassis(d, ctx, v, Wp, Hp, 0, T("cl_onRoad"), "road")
    img(0, 86, 1400, 750, "as_claas_b4_road")
    local u = unitsOf()
    local sx, sy = 1400 / 1335, 750 / 719
    local function Q(x, y) return x * sx, 86 + (y - 93) * sy end
    local function tq(x, y, size, s, col, align, maxW) local a, b = Q(x, y); clText(ctx, PX, PY, PW, a, b, size, s, col, align, maxW) end
    local WHT = { 1, 1, 1, 1 }
    local C0 = RenderText.ALIGN_CENTER
    for _, s in ipairs({ { 171, 257, "0" }, { 245, 188, "10" }, { 353, 141, "20" }, { 471, 126, "30" }, { 584, 138, "40" }, { 681, 185, "50" }, { 758, 257, "60" } }) do tq(s[1], s[2], 26, s[3], CL_DK, C0) end
    local spd = math.abs(d.speed or 0)
    tq(460, 368, 78, string.format("%.1f", u and u.kmh(spd) or spd), WHT, C0)
    tq(460, 425, 28, u and u.speed or "km/h", WHT, C0)
    tq(203, 460, 46, string.format("%d", math.floor((d.rpm or 0) + 0.5)), WHT, C0)
    tq(203, 512, 24, T("cl_rpm"), WHT, C0)
    for k, val in ipairs({ 6, 8, 10, 12, 14, 16, 18, 20, 22, 24 }) do
        local ang = math.rad(225 - (k - 1) * 270 / 9)
        tq(200 + 108 * math.cos(ang), 438 - 108 * math.sin(ang), 20, tostring(val), WHT, C0)
    end
    tq(712, 460, 50, string.format("%d", math.floor((d.fuel or 0) * 100 + 0.5)), WHT, C0)
    tq(712, 510, 28, "%", WHT, C0)
    tq(350, 715, 32, d.def ~= nil and string.format("%d %%", math.floor(d.def * 100 + 0.5)) or "-", WHT, C0)
    local tC = d.temp ~= nil and (u and u.degC(d.temp) or d.temp) or nil
    tq(575, 715, 32, tC ~= nil and string.format("%d %s", math.floor(tC + 0.5), u and u.temp or "°C") or "-", WHT, C0)
    local job = d.cnt ~= nil and d.cnt.jobs[d.cnt.active] or nil
    -- (04/11) valeurs selon les icônes, comme On Field : surface travaillée, carburant, consommation, véhicule
    -- (avant : charge moteur, distance et rapport, repris des textes de l'image)
    local ha = job ~= nil and job.ha or 0
    tq(1020, 135, 30, string.format("%.2f %s", u and u.ha(ha) or ha, u and u.area or "ha"), CL_DK, nil, 330)
    tq(1020, 203, 30, string.format("%d %s", math.floor(u and u.l(d.fuelL or 0) or (d.fuelL or 0)), u and u.vol or "L"), CL_DK, nil, 330)
    tq(1020, 270, 30, string.format("%.1f %s/h", u and u.l(d.fuelUse or 0) or (d.fuelUse or 0), u and u.vol or "L"), CL_DK, nil, 330)
    tq(1020, 332, 30, tostring(d.name or "CLAAS"), CL_DK, nil, 330)
    for _, s in ipairs({ { 929, 437, "5" }, { 980, 412, "10" }, { 1040, 402, "15" }, { 1104, 394, "20" }, { 1171, 402, "40" }, { 1231, 416, "50" }, { 1290, 438, "60" } }) do tq(s[1], s[2], 22, s[3], CL_DK, C0) end
    local cs = (d.cruise ~= nil and d.cruise ~= 0) and d.cruiseSpeed or nil
    tq(1180, 550, 50, cs ~= nil and string.format("%.1f", u and u.kmh(cs) or cs) or "--.-", CL_DK, RenderText.ALIGN_RIGHT)
    tq(1195, 553, 28, u and u.speed or "km/h", CL_DK)
    for i = 1, 6 do tq(918, 610 + (i - 1) * 32, 24, "F" .. i, CL_DK) end
end

-- autres pages : châssis Claas, page habituelle dans le centre (en attendant les images Claas)
function AS_Terminal:claasPage(d, ctx, v, Wp, Hp, inside, title)
    local sel = ({ tractor = 1, clhitch = 2, clhyd = 3, work = 3, cp = 4, gps = 5, fp = 5, tool = 6, count = 7 })[self.page]
    local PX, PY, PW = self:claasChassis(d, ctx, v, Wp, Hp, sel, title, self:claasView(v) or "field")
    ctx.rect(PX(0), PY(86), PW(1400), PY(750), CL_BG)
    -- (04/11) page Outil / Isobus : sa colonne de touches (Baisser, Marche, Replier...) reste DANS la zone
    -- blanche, à droite ; en pleine largeur elle tombait sur la colonne Claas (Transmission, Attelage, Hydraulique)
    local ctx2 = caseSubCtx(ctx, v, PX, PY, 20, 100, 1385, 825, self.page == "gps")
    local fn = self["page_" .. self.page]
    -- (04/11) FarmPilot sur le blanc Claas : couleurs du thème clair (textes foncés),
    -- avec un thème sombre choisi, ses textes blancs / gris clair / vert pâle ne se lisaient pas
    local th0 = (self.page == "fp" and self.curTheme ~= 2) and (self.curTheme or 1) or nil
    if th0 ~= nil then applyTheme(2) end
    local ok, err = true, nil
    if fn ~= nil then ok, err = pcall(fn, self, d, ctx2, inside, v) end
    if th0 ~= nil then applyTheme(th0) end
    if not ok then error(err) end
end

-- (04/11) HYDRAULIQUE comme CEBIS connect (vidéo #12) : à gauche le tableau des 4 distributeurs
-- (Fonction 1-4 aux couleurs de On Field), à droite les réglages du distributeur choisi (fonctions, débit, temps de
-- réponse, commande temporisée, priorité / commandes d'aile / verrou) ; un cadran touché ouvre son réglage (+ / -, OK, X).
-- Icônes et cadrans relevés sur la vidéo, textes écrits en direct (FR / EN / DE).
local CLH_PANEL = { 0.902, 0.890, 0.906, 1 }
local CLH_HEAD = { 0.804, 0.780, 0.800, 1 }
local CLH_LINE = { 0.78, 0.765, 0.78, 1 }
local CLH_GREY = { 0.58, 0.56, 0.58, 1 }
local CLH_BLUE = { 0.23, 0.47, 0.64, 1 }
local CLH_SLOT = { 0.75, 0.735, 0.75, 1 }
AS_Terminal.CLH_COLX = { 256, 380, 504, 628 }               -- colonnes du tableau (124 de large)
AS_Terminal.CLH_ROWS = { 470, 540, 622, 692, 764, 834 }     -- bas des lignes : icônes, compteurs, manette, priorité, aile, verrou
AS_Terminal.CLH_DIALS = { flowM = "as_clh_dflow_m", flowP = "as_clh_dflow_p", respM = "as_clh_dresp_m", respP = "as_clh_dresp_p", timer = "as_clh_dtime" }
local function hydFmt(key, val)
    if key == "timer" then
        if val >= AS_Terminal.HYD_INF then return nil end   -- infini : symbole dessiné à la place
        return tostring(math.floor(val + 0.5))
    end
    if key == "respM" or key == "respP" then return string.format("%.2f", val) end
    return tostring(math.floor(val + 0.5))
end
local function hydFill(key, val)
    if key == "timer" then
        if val >= AS_Terminal.HYD_INF then return 20 end
        return math.floor(math.max(0, math.min(1, val / 59)) * 20 + 0.5)
    end
    local r = AS_Terminal.HYD_RANGE[key]
    return math.floor(math.max(0, math.min(1, (val - r[1]) / (r[2] - r[1]))) * 20 + 0.5)
end
function AS_Terminal:claasHydPage(d, ctx, v, Wp, Hp, inside)
    local PX, PY, PW, img, hot = self:claasChassis(d, ctx, v, Wp, Hp, 3, T("cl_hydraulic"), self:claasView(v) or "field")
    local C0 = RenderText.ALIGN_CENTER
    ctx.rect(PX(0), PY(86), PW(1400), PY(750), CLH_PANEL)
    local sel = math.max(1, math.min(4, self.hydSel or 1))
    local rem = self:remoteFns(v)
    local hs = {}
    for i = 1, 4 do hs[i] = self:hydOf(v, i) end
    local function ctr(name, cx, cy, w, h) img(cx - w * 0.5, cy - h * 0.5, w, h, name) end
    -- ===== tableau des distributeurs (gauche) =====
    ctx.rect(PX(8), PY(92), PW(744), PY(58), CLH_HEAD)
    img(16, 94, 70, 54, "as_clh_head")
    clText(ctx, PX, PY, PW, 100, 121, 32, T("cl_h_title"), CL_DK, nil, 640)
    ctx.rect(PX(8), PY(152), PW(744), PY(44), CLH_HEAD)
    clText(ctx, PX, PY, PW, 18, 174, 28, T("cl_h_sub"), CL_DK, nil, 720)
    -- menu des fonctions ouvert : il prend la place du tableau (les textes du jeu passent au-dessus des images)
    local m = self.remoteMenu
    local menuOpen = m ~= nil and m.i >= 1 and m.i <= 4 and m.k >= 1 and m.k <= self.REMOTE_SLOTS
    if not menuOpen then
    local R = self.CLH_ROWS
    local labels = { false, T("cl_h_counter"), T("cl_h_assign"), T("cl_h_prio"), T("cl_h_fender"), T("cl_h_lock") }
    for r = 1, 6 do
        local y0 = r == 1 and 198 or R[r - 1]
        if r < 6 then ctx.rect(PX(8), PY(R[r] - 1), PW(744), PY(2), CLH_LINE) end
        if labels[r] then clText(ctx, PX, PY, PW, 18, (y0 + R[r]) * 0.5, 26, labels[r], CL_DK, nil, 232) end
    end
    for i, x in ipairs(self.CLH_COLX) do
        local cx = x + 62
        local h = hs[i]
        local fns = rem[i] or {}
        local inPlace = #fns > 0 and self:remoteSide(v, i, fns, d)
        img(cx - 31, 206, 62, 104, "as_claas_fn" .. i .. (inPlace and "" or "_d"))
        -- état : trait - verrou - trait quand verrouillé (comme CEBIS), sinon le vérin de On Field (vert = en place, N = rien)
        if h.lock == 1 then
            ctx.rect(PX(cx - 1), PY(322), PW(3), PY(42), CL_DK)
            ctr("as_clh_lockfill", cx, 390, 42, 46)
            ctx.rect(PX(cx - 1), PY(416), PW(3), PY(42), CL_DK)
        else
            ctx.rect(PX(cx - 20), PY(328), PW(40), PY(124), CL_BAR_BLACK)
            if inPlace then ctx.rect(PX(cx - 17), PY(331), PW(34), PY(118), CL_GREEN) end
            if #fns == 0 then clText(ctx, PX, PY, PW, cx, 390, 34, "N", CL_WH, C0) end
        end
        hot(PX(x), PY(198), PW(124), PY(122), "hyd_sel_" .. i)
        -- touché sur le vérin = la fonction part (comme On Field)
        hot(PX(x), PY(320), PW(124), PY(150), #fns > 0 and ("rem_" .. i) or ("hyd_sel_" .. i))
        -- compteur : la tempo (infini = symbole) ; retour en attente : secondes restantes en vert
        local left = self:hydLeft(v, i)
        if left ~= nil then clText(ctx, PX, PY, PW, cx, 505, 32, tostring(left), CL_GREEN_TXT, C0)
        elseif h.timer >= self.HYD_INF then ctr("as_clh_inf", cx, 505, 50, 30)
        else clText(ctx, PX, PY, PW, cx, 505, 32, tostring(math.floor(h.timer + 0.5)), CL_DK, C0) end
        -- manette : n° écrit en direct ; touché = suivante (1-4 puis aucune)
        ctr("as_clh_lever", cx, 584, 66, 44)
        if h.lever >= 1 then clText(ctx, PX, PY, PW, cx + 36, 560, 22, tostring(h.lever), CL_DK, C0) end
        ctr(h.prio == 1 and "as_clh_star_g" or "as_clh_star", cx, 657, 50, 50)
        ctr(h.fender == 1 and "as_clh_fender_g" or "as_clh_fender", cx, 728, 72, 53)
        ctr(h.lock == 1 and "as_clh_lock_g" or "as_clh_lock", cx, 799, 43, 54)
        hot(PX(x), PY(470), PW(124), PY(70), "hyd_sel_" .. i)
        hot(PX(x), PY(540), PW(124), PY(82), "hyd_lev_" .. i)
        hot(PX(x), PY(622), PW(124), PY(212), "hyd_sel_" .. i)
    end
    local sx = self.CLH_COLX[sel]                            -- colonne choisie : cadre vert
    ctx.rect(PX(sx + 2), PY(198), PW(4), PY(636), CL_GREEN); ctx.rect(PX(sx + 118), PY(198), PW(4), PY(636), CL_GREEN)
    ctx.rect(PX(sx + 2), PY(198), PW(120), PY(4), CL_GREEN); ctx.rect(PX(sx + 2), PY(830), PW(120), PY(4), CL_GREEN)
    end
    -- ===== distributeur choisi (droite) =====
    local h = hs[sel]
    local RX, RW = 768, 626
    ctx.rect(PX(RX), PY(92), PW(RW), PY(58), CLH_HEAD)
    local dlg = self.hydDlg
    if dlg ~= nil and dlg.i ~= sel then dlg = nil; self.hydDlg = nil end
    if dlg == nil then
        img(RX + 10, 106, 72, 30, "as_clh_valve")
        clText(ctx, PX, PY, PW, RX + 96, 121, 32, T("c_remote") .. " " .. sel, CL_DK, nil, RW - 110)
        -- 4 parties, 3 visibles : flèches haut / bas comme CEBIS
        local scroll = math.max(0, math.min(1, self.hydScroll or 0))
        if scroll > 0 then ctr("as_clh_up", RX + RW * 0.5, 161, 24, 20); hot(PX(RX), PY(152), PW(RW), PY(18), "hyd_up") end
        if scroll < 1 then ctr("as_clh_dn", RX + RW * 0.5, 827, 24, 20); hot(PX(RX), PY(818), PW(RW), PY(18), "hyd_dn") end
        local heads = { T("cl_h_fns"), T("cl_h_flow"), T("cl_h_resp"), T("cl_h_adjust") }
        for n = 1, 3 do
            local s = n + scroll
            local y = 170 + (n - 1) * 216
            ctx.rect(PX(RX), PY(y), PW(RW), PY(40), CLH_HEAD)
            clText(ctx, PX, PY, PW, RX + 12, y + 20, 28, heads[s], CL_DK, nil, RW - 24)
            local cy = y + 40 + 88                            -- milieu de la partie (176 de haut)
            local function dial(cx, key)
                local val = h[key]
                img(cx - 80, cy - 80, 160, 160, "as_clh_dial")
                img(cx - 80, cy - 80, 160, 160, string.format("as_clh_dial%02d", hydFill(key, val)))
                img(cx - 34, cy - 58, 69, 67, self.CLH_DIALS[key])
                local txt = hydFmt(key, val)
                if txt ~= nil then
                    clText(ctx, PX, PY, PW, cx, cy + 25, 34, txt, CL_DK, C0)
                    clText(ctx, PX, PY, PW, cx, cy + 52, 20, (key == "flowM" or key == "flowP") and "%" or "s", CL_DK, C0)
                else ctr("as_clh_inf_g", cx, cy + 30, 50, 30) end
                hot(PX(cx - 80), PY(cy - 80), PW(160), PY(160), "hyd_dlg_" .. key)
            end
            if s == 1 then                                    -- fonctions du distributeur (menu : AV | AR | Les deux)
                local fns = rem[sel] or {}
                for k = 1, self.REMOTE_SLOTS do
                    local fy = y + 50 + (k - 1) * 56
                    local fn = fns[k]
                    if fn ~= nil or k <= #fns + 1 then
                        ctx.rect(PX(RX + 10), PY(fy), PW(RW - 20), PY(48), fn ~= nil and CL_GREEN or CLH_SLOT)
                        hot(PX(RX + 10), PY(fy), PW(RW - 20), PY(48), "rfn_" .. sel .. "_" .. k)
                        clText(ctx, PX, PY, PW, RX + RW * 0.5, fy + 24, fn ~= nil and 24 or 34, fn ~= nil and remoteLabel(fn) or "+", CL_DK, C0, RW - 40)
                    end
                end
            elseif s == 2 then
                dial(RX + 100, "flowM"); dial(RX + 290, "flowP")
            elseif s == 3 then
                dial(RX + 100, "respM"); dial(RX + 290, "respP"); dial(RX + 480, "timer")
            else
                for k, b in ipairs({ { "prio", "as_clh_star", 50, 50 }, { "fender", "as_clh_fender", 72, 53 }, { "lock", "as_clh_lock", 43, 54 } }) do
                    local cx = RX + 100 + (k - 1) * 190
                    img(cx - 80, cy - 80, 160, 160, h[b[1]] == 1 and "as_clh_btn_on" or "as_clh_btn_off")
                    ctr(b[2], cx, cy, b[3] * 1.2, b[4] * 1.2)
                    hot(PX(cx - 80), PY(cy - 80), PW(160), PY(160), "hyd_tg_" .. b[1])
                end
            end
        end
    else
        -- réglage d'une valeur : cadran, valeur gardée (noir) et nouvelle (bleu), MIN / MAX, + / -, OK et X
        local key = dlg.key
        local r = self.HYD_RANGE[key]
        img(RX + 10, 94, 56, 54, self.CLH_DIALS[key])
        clText(ctx, PX, PY, PW, RX + 76, 121, 30, T("cl_h_" .. key), CL_DK, nil, RW - 150)
        img(RX + RW - 54, 100, 42, 42, "as_clh_x")
        hot(PX(RX + RW - 70), PY(92), PW(70), PY(58), "hyd_cancel")
        local cx, cy = RX + 230, 400
        img(cx - 160, cy - 160, 320, 320, "as_clh_dial")
        img(cx - 160, cy - 160, 320, 320, string.format("as_clh_dial%02d", hydFill(key, dlg.val)))
        local t0, t1 = hydFmt(key, h[key]), hydFmt(key, dlg.val)
        if t0 ~= nil then clText(ctx, PX, PY, PW, cx, cy - 22, 72, t0, CL_DK, C0) else ctr("as_clh_inf", cx, cy - 22, 100, 60) end
        if t1 ~= nil then clText(ctx, PX, PY, PW, cx, cy + 46, 46, t1, CLH_BLUE, C0) else ctr("as_clh_inf_g", cx, cy + 46, 70, 42) end
        clText(ctx, PX, PY, PW, cx, cy + 112, 30, (key == "flowM" or key == "flowP") and "%" or "s", CL_DK, C0)
        clText(ctx, PX, PY, PW, cx - 120, cy + 192, 32, hydFmt(key, r[1]) or "", CL_DK, C0)
        clText(ctx, PX, PY, PW, cx + 120, cy + 192, 32, key == "timer" and "59" or (hydFmt(key, r[2]) or ""), CL_DK, C0)
        clText(ctx, PX, PY, PW, cx - 120, cy + 242, 30, "MIN", CLH_GREY, C0)
        clText(ctx, PX, PY, PW, cx + 120, cy + 242, 30, "MAX", CLH_GREY, C0)
        -- colonne + / - à droite, OK en bas
        local bx = RX + 470
        ctx.rect(PX(bx), PY(152), PW(2), PY(684), CLH_LINE)
        ctx.rect(PX(bx), PY(493), PW(RW - 470), PY(2), CLH_LINE)
        ctx.rect(PX(RX), PY(700), PW(470), PY(2), CLH_LINE)
        local px = bx + (RW - 470) * 0.5
        ctx.rect(PX(px - 32), PY(320), PW(64), PY(5), CL_DK); ctx.rect(PX(px - 2.5), PY(290), PW(5), PY(64), CL_DK)
        ctx.rect(PX(px - 32), PY(662), PW(64), PY(5), CL_DK)
        hot(PX(bx), PY(152), PW(RW - 470), PY(341), "hyd_plus")
        hot(PX(bx), PY(495), PW(RW - 470), PY(341), "hyd_minus")
        ctr("as_clh_ok", RX + 235, 768, 91, 66)
        hot(PX(RX), PY(702), PW(470), PY(134), "hyd_ok")
    end
    -- menu des fonctions (case touchée à droite) : posé sur le tableau, 3 colonnes AV | AR | Les deux, Aucun en bas
    if menuOpen then
        local fns = rem[m.i] or {}
        local curFn = fns[m.k] or "none"
        local x0, y0, cw, rh = 12, 200, 244, 48
        local nRows = #self.REMOTE_FNS - 1
        local tw = cw * 3 + 8
        ctx.rect(PX(x0 - 4), PY(y0 - 4), PW(tw + 8), PY(rh * (nRows + 2) + 8), CL_BAR_BLACK)
        local heads = { { T("c_colF"), "@f" }, { T("c_colR"), "@r" }, { T("c_colB"), "" } }
        for c, hd in ipairs(heads) do
            local mx = x0 + (c - 1) * (cw + 4)
            ctx.rect(PX(mx), PY(y0), PW(cw), PY(rh), CLH_HEAD)
            clText(ctx, PX, PY, PW, mx + cw * 0.5, y0 + rh * 0.5, 24, hd[1], CL_DK, C0, cw - 12)
            for j = 2, #self.REMOTE_FNS do
                local fn = self.REMOTE_FNS[j] .. hd[2]
                local ry = y0 + (j - 1) * rh
                ctx.rect(PX(mx), PY(ry + 1), PW(cw), PY(rh - 1), curFn == fn and CL_GREEN or CLH_PANEL)
                hot(PX(mx), PY(ry), PW(cw), PY(rh), "rsel_" .. m.i .. "_" .. m.k .. "_" .. fn)
                clText(ctx, PX, PY, PW, mx + 10, ry + rh * 0.5, 21, remoteLabel(fn, true), CL_DK, nil, cw - 20)
            end
        end
        local ny = y0 + (nRows + 1) * rh
        ctx.rect(PX(x0), PY(ny + 1), PW(tw), PY(rh - 1), curFn == "none" and CL_GREEN or CLH_PANEL)
        hot(PX(x0), PY(ny), PW(tw), PY(rh), "rsel_" .. m.i .. "_" .. m.k .. "_none")
        clText(ctx, PX, PY, PW, x0 + tw * 0.5, ny + rh * 0.5, 22, T("none"), CL_DK, C0, tw - 20)
    end
end

-- (04/11) ATTELAGE comme CEBIS connect (vidéo #8) : réglages du relevage (verrou, limite de
-- hauteur, vitesse de descente, régulation mixte, amortissement, patinage, contrôle d'effort) et, à l'arrière, les
-- stabilisateurs (mode flottant / centré / automatique, centrage). À droite : l'état du relevage et ses boutons, ou le
-- réglage touché. Effets en jeu : verrou (celui d'avant), limite de hauteur et vitesse de descente (relevages du
-- tracteur conduit) ; les autres réglages sont affichés et gardés (pas d'équivalent dans le jeu).
AS_Terminal.HIT_KEYS = { "upper", "speed", "mix", "damp", "slip", "draft", "stab", "centre" }
AS_Terminal.HIT_DEF = { 100, 100, 50, 1, 0, 0, 1, 20 }
AS_Terminal.HIT_RANGE = { upper = { 10, 100, 5 }, speed = { 10, 100, 5 }, mix = { 0, 100, 5 }, slip = { 0, 100, 5 }, draft = { 0, 100, 5 }, centre = { 0, 100, 2 } }
AS_Terminal.HIT_ICON = { upper = "as_clt_upper", speed = "as_clt_speed", mix = "as_clt_mix", slip = "as_clt_slip", draft = "as_clt_draft", centre = "as_clt_centre" }
-- réglages d'un relevage (front = avant), gardés dans hset = "arrière;avant"
function AS_Terminal:hitchSetOf(v, front)
    local p = self:vehPrefs(v)
    local blk
    if p ~= nil and p.hset ~= nil then
        local n = 0
        for w in string.gmatch(p.hset .. ";", "([^;]*);") do n = n + 1; if n == (front and 2 or 1) then blk = w end end
    end
    local vals = {}
    if blk ~= nil then for x in string.gmatch(blk .. ",", "([^,]*),") do vals[#vals + 1] = tonumber(x) or false end end
    local out = {}
    for k, key in ipairs(self.HIT_KEYS) do
        local x = vals[k]
        if x == nil or x == false then x = self.HIT_DEF[k] end
        out[key] = x
    end
    return out
end
function AS_Terminal:hitchSetSet(v, front, key, val)
    if v == nil then return end
    local parts = {}
    for j = 1, 2 do
        local t = self:hitchSetOf(v, j == 2)
        if (j == 2) == (front == true) then t[key] = val end
        local o = {}
        for k, kk in ipairs(self.HIT_KEYS) do o[k] = tostring(t[kk]) end
        parts[j] = table.concat(o, ",")
    end
    local p = self:vehPrefs(v, true)
    p.hset = table.concat(parts, ";")
    self:saveSettings()
end
-- limite de hauteur et vitesse de descente sur les relevages du tracteur conduit (rien tant qu'aucun réglage n'est fait)
function AS_Terminal:hitchApply(v)
    local spec = v ~= nil and v.spec_attacherJoints or nil
    if spec == nil or spec.attachedImplements == nil or spec.attacherJoints == nil then return end
    local p = self:vehPrefs(v)
    if p == nil or p.hset == nil then return end
    for _, impl in pairs(spec.attachedImplements) do
        local jd = spec.attacherJoints[impl.jointDescIndex]
        if jd ~= nil and jd.allowsLowering == true and jd.upperAlpha ~= nil and jd.lowerAlpha ~= nil and jd.jointTransform ~= nil then
            local _, _, z = localToLocal(jd.jointTransform, v.rootNode, 0, 0, 0)
            local hs = self:hitchSetOf(v, z > 0)
            if jd.asObj ~= nil or hs.upper < 100 or hs.speed < 100 then
                if jd.asObj ~= impl.object then         -- nouvel outil : valeurs du jeu relues (calculées à l'attelage)
                    jd.asObj = impl.object
                    jd.asUpper0 = jd.upperAlpha
                    jd.asMove0 = jd.moveTime
                end
                local lim = math.max(10, math.min(100, hs.upper)) / 100
                jd.upperAlpha = jd.asUpper0 + (jd.lowerAlpha - jd.asUpper0) * (1 - lim)
                if type(jd.asMove0) == "number" and jd.asMove0 > 0 then
                    local sp = math.max(10, math.min(100, hs.speed)) / 100
                    jd.moveTime = jd.moveDown and jd.asMove0 / sp or jd.asMove0
                end
            end
        end
    end
end
local function hitFmt(val) return tostring(math.floor(val + 0.5)) end
local function hitFill(key, val)
    local r = AS_Terminal.HIT_RANGE[key]
    return math.floor(math.max(0, math.min(1, (val - r[1]) / (r[2] - r[1]))) * 20 + 0.5)
end
AS_Terminal.CLAAS_HITCH_TABS = { { "hitch_r", "c_colR" }, { "hitch_f", "c_colF" }, { "pto", "cl_p_tab" } }
function AS_Terminal:claasHitchTabs(ctx, PX, PY, PW, hot, sub)   -- AR | AV | PdF en haut à droite du tableau
    for i, t in ipairs(self.CLAAS_HITCH_TABS) do
        local x = 458 + (i - 1) * 98
        ctx.rect(PX(x), PY(98), PW(92), PY(46), t[1] == sub and CL_GREEN or CLH_SLOT)
        hot(PX(x), PY(98), PW(92), PY(46), "clh_" .. t[1])
        clText(ctx, PX, PY, PW, x + 46, 121, 28, T(t[2]), CL_DK, RenderText.ALIGN_CENTER, 86)
    end
end
function AS_Terminal:claasHitchPage(d, ctx, v, Wp, Hp, inside)
    if self.claasHitchSub == "pto" then return self:claasPtoPage(d, ctx, v, Wp, Hp, inside) end
    local PX, PY, PW, img, hot = self:claasChassis(d, ctx, v, Wp, Hp, 2, T("cl_hitch"), self:claasView(v) or "field")
    local C0 = RenderText.ALIGN_CENTER
    ctx.rect(PX(0), PY(86), PW(1400), PY(750), CLH_PANEL)
    local sub = self.claasHitchSub == "hitch_f" and "hitch_f" or "hitch_r"
    local front = sub == "hitch_f"
    local hs = self:hitchSetOf(v, front)
    local function ctr(name, cx, cy, w, h) img(cx - w * 0.5, cy - h * 0.5, w, h, name) end
    local dlg = self.hitDlg
    if dlg ~= nil and dlg.front ~= front then dlg = nil; self.hitDlg = nil end
    -- ===== réglages (gauche) =====
    ctx.rect(PX(8), PY(92), PW(744), PY(58), CLH_HEAD)
    img(16, 94, 70, 54, "as_clt_head")
    clText(ctx, PX, PY, PW, 100, 121, 32, T(front and "cl_t_title_f" or "cl_t_title_r"), CL_DK, nil, 345)
    self:claasHitchTabs(ctx, PX, PY, PW, hot, sub)
    ctx.rect(PX(8), PY(152), PW(744), PY(44), CLH_HEAD)
    clText(ctx, PX, PY, PW, 18, 174, 28, T("cl_t_sub"), CL_DK, nil, 720)
    local function dial(cx, cy, key)
        local val = hs[key]
        img(cx - 78, cy - 78, 156, 156, "as_clh_dial")
        img(cx - 78, cy - 78, 156, 156, string.format("as_clh_dial%02d", hitFill(key, val)))
        img(cx - 36, cy - 60, 72, 66, self.HIT_ICON[key])
        clText(ctx, PX, PY, PW, cx, cy + 24, 34, hitFmt(val), CL_DK, C0)
        clText(ctx, PX, PY, PW, cx, cy + 50, 20, "%", CL_DK, C0)
        if dlg ~= nil and dlg.key == key then          -- réglage ouvert : cadre vert, comme CEBIS
            ctx.rect(PX(cx - 88), PY(cy - 88), PW(176), PY(4), CL_GREEN); ctx.rect(PX(cx - 88), PY(cy + 84), PW(176), PY(4), CL_GREEN)
            ctx.rect(PX(cx - 88), PY(cy - 88), PW(4), PY(176), CL_GREEN); ctx.rect(PX(cx + 84), PY(cy - 88), PW(4), PY(176), CL_GREEN)
        end
        hot(PX(cx - 80), PY(cy - 80), PW(160), PY(160), "hit_dlg_" .. key)
    end
    local function btn(cx, cy, on, icon, w, h, action)
        img(cx - 78, cy - 78, 156, 156, on and "as_clh_btn_on" or "as_clh_btn_off")
        ctr(icon, cx, cy, w, h)
        hot(PX(cx - 80), PY(cy - 80), PW(160), PY(160), action)
    end
    local locked = self:hitchLocked(v, front)
    btn(98, 286, locked, "as_clt_lock", 92, 78, front and "hlock_f" or "hlock_r")
    dial(278, 286, "upper"); dial(458, 286, "speed"); dial(638, 286, "mix")
    btn(98, 466, hs.damp == 1, "as_clt_damp", 92, 78, "hit_tg_damp")
    dial(278, 466, "slip"); dial(458, 466, "draft")
    if not front then
        ctx.rect(PX(8), PY(552), PW(744), PY(44), CLH_HEAD)
        clText(ctx, PX, PY, PW, 18, 574, 28, T("cl_t_stab"), CL_DK, nil, 720)
        -- mode : moitié haute = flottant, moitié basse = centré ; automatique (A) : flottant baissé, centré levé
        local hf, hr = caseHitches(d)
        local mode = hs.stab
        local eff = mode
        if mode == 3 then eff = (hr ~= nil and hr.moveDown == true) and 1 or 2 end
        local cx, cy = 98, 700
        img(cx - 78, cy - 78, 156, 156, eff == 1 and "as_clt_stab_top" or "as_clt_stab_bot")
        ctr("as_clt_sfloat", cx, cy - 36, 52, 57)
        ctr("as_clt_centred", cx, cy + 36, 60, 42)
        if mode == 3 then img(cx + 62, cy - 92, 26, 26, "as_clt_badge") end
        hot(PX(cx - 80), PY(cy - 80), PW(160), PY(160), "hit_stab")
        dial(278, 700, "centre")
    end
    -- ===== droite : état du relevage, ou le réglage touché =====
    local RX, RW = 768, 626
    ctx.rect(PX(RX), PY(92), PW(RW), PY(58), CLH_HEAD)
    if dlg == nil then
        local hf, hr = caseHitches(d)
        local h = front and hf or hr
        local has = h ~= nil and h.object ~= nil
        img(RX + 10, 94, 70, 54, "as_clt_head")
        clText(ctx, PX, PY, PW, RX + 96, 121, 30, has and vehicleName(h.object) or T("empty"), CL_DK, nil, RW - 110)
        -- jauge comme On Field : barre noire, vert = hauteur
        ctx.rect(PX(RX + 40), PY(190), PW(70), PY(360), CL_BAR_BLACK)
        local fr = has and math.max(0, math.min(1, h.up or 0)) or 0
        if fr > 0.01 then ctx.rect(PX(RX + 45), PY(195 + 350 * (1 - fr)), PW(60), PY(350 * fr), CL_GREEN) end
        clText(ctx, PX, PY, PW, RX + 140, 330, 72, has and (hitchPct(h) .. " %") or "N", CL_DK, nil, 300)
        if has then clText(ctx, PX, PY, PW, RX + 140, 410, 34, h.moveDown and T("lowered") or T("raised"), CL_DK, nil, 460) end
        clText(ctx, PX, PY, PW, RX + 140, 470, 26, locked and T("c_locked") or T("c_unlockedSt"), locked and CL_DK or { 0.75, 0.10, 0.10, 1 }, nil, 470)
        local function button(y, label, action, on)
            ctx.rect(PX(RX + 20), PY(y), PW(RW - 40), PY(70), on and CL_GREEN or CLH_SLOT)
            hot(PX(RX + 20), PY(y), PW(RW - 40), PY(70), action)
            clText(ctx, PX, PY, PW, RX + RW * 0.5, y + 35, 30, label, CL_DK, C0, RW - 60)
        end
        if has then button(584, h.moveDown and T("doRaise") or T("doLower"), front and "hitch_f" or "hitch_r", true) end
        button(668, T("c_liftAll"), "lift_up", false)
        button(752, T("c_lowerAll"), "lift_dn", false)
    elseif dlg.key == "stab" then
        -- mode des stabilisateurs : liste, coche sur le mode gardé
        img(RX + 10, 94, 70, 51, "as_clt_stabhead")
        clText(ctx, PX, PY, PW, RX + 96, 121, 30, T("cl_t_mode"), CL_DK, nil, RW - 170)
        img(RX + RW - 54, 100, 42, 42, "as_clh_x")
        hot(PX(RX + RW - 70), PY(92), PW(70), PY(58), "hit_cancel")
        ctx.rect(PX(RX), PY(472), PW(RW), PY(44), CLH_HEAD)
        clText(ctx, PX, PY, PW, RX + 12, 494, 28, T("cl_t_confirm"), CL_DK, nil, RW - 24)
        local rows = { { 1, "as_clt_float", 70, 68, "cl_t_float" }, { 2, "as_clt_centred", 74, 51, "cl_t_centred" }, { 3, "as_clt_auto", 61, 58, "cl_t_autom" } }
        for k, r in ipairs(rows) do
            local y = 520 + (k - 1) * 104
            local cur = hs.stab == r[1]
            if k > 1 then ctx.rect(PX(RX), PY(y - 1), PW(RW), PY(2), CLH_LINE) end
            ctr(r[2], RX + 56, y + 52, r[3], r[4])
            clText(ctx, PX, PY, PW, RX + 112, y + 52, 32, T(r[5]), CL_DK, nil, RW - 200)
            if cur then
                ctr("as_clt_check", RX + RW - 50, y + 52, 40, 34)
                ctx.rect(PX(RX + 2), PY(y + 2), PW(RW - 4), PY(4), CL_GREEN); ctx.rect(PX(RX + 2), PY(y + 98), PW(RW - 4), PY(4), CL_GREEN)
                ctx.rect(PX(RX + 2), PY(y + 2), PW(4), PY(100), CL_GREEN); ctx.rect(PX(RX + RW - 6), PY(y + 2), PW(4), PY(100), CL_GREEN)
            end
            hot(PX(RX), PY(y), PW(RW), PY(104), "hit_stab_" .. r[1])
        end
    else
        -- réglage d'une valeur : comme la page Hydraulique (gardée en noir, nouvelle en bleu, MIN / MAX, + / -, OK, X)
        local key = dlg.key
        local r = self.HIT_RANGE[key]
        img(RX + 10, 94, 60, 55, self.HIT_ICON[key])
        clText(ctx, PX, PY, PW, RX + 80, 121, 30, T("cl_t_" .. key), CL_DK, nil, RW - 150)
        img(RX + RW - 54, 100, 42, 42, "as_clh_x")
        hot(PX(RX + RW - 70), PY(92), PW(70), PY(58), "hit_cancel")
        local cx, cy = RX + 230, 400
        img(cx - 160, cy - 160, 320, 320, "as_clh_dial")
        img(cx - 160, cy - 160, 320, 320, string.format("as_clh_dial%02d", hitFill(key, dlg.val)))
        clText(ctx, PX, PY, PW, cx, cy - 22, 72, hitFmt(hs[key]), CL_DK, C0)
        clText(ctx, PX, PY, PW, cx, cy + 46, 46, hitFmt(dlg.val), CLH_BLUE, C0)
        clText(ctx, PX, PY, PW, cx, cy + 112, 30, "%", CL_DK, C0)
        clText(ctx, PX, PY, PW, cx - 120, cy + 192, 32, hitFmt(r[1]), CL_DK, C0)
        clText(ctx, PX, PY, PW, cx + 120, cy + 192, 32, hitFmt(r[2]), CL_DK, C0)
        clText(ctx, PX, PY, PW, cx - 120, cy + 242, 30, "MIN", CLH_GREY, C0)
        clText(ctx, PX, PY, PW, cx + 120, cy + 242, 30, "MAX", CLH_GREY, C0)
        local bx = RX + 470
        ctx.rect(PX(bx), PY(152), PW(2), PY(684), CLH_LINE)
        ctx.rect(PX(bx), PY(493), PW(RW - 470), PY(2), CLH_LINE)
        ctx.rect(PX(RX), PY(700), PW(470), PY(2), CLH_LINE)
        local px = bx + (RW - 470) * 0.5
        ctx.rect(PX(px - 32), PY(320), PW(64), PY(5), CL_DK); ctx.rect(PX(px - 2.5), PY(290), PW(5), PY(64), CL_DK)
        ctx.rect(PX(px - 32), PY(662), PW(64), PY(5), CL_DK)
        hot(PX(bx), PY(152), PW(RW - 470), PY(341), "hit_plus")
        hot(PX(bx), PY(495), PW(RW - 470), PY(341), "hit_minus")
        ctr("as_clh_ok", RX + 235, 768, 91, 66)
        hot(PX(RX), PY(702), PW(470), PY(134), "hit_ok")
    end
end

-- (04/11) PRISE DE FORCE comme CEBIS connect (vidéo #9) : 1000 / 1000E, commande externe,
-- AUTO PdF (seuils de coupure et de remise en marche, en % de hauteur du relevage arrière). Effets en jeu : 1000E =
-- régime moteur demandé par la prise de force x 0,8 ; AUTO PdF = outils arrière arrêtés quand le relevage monte au-dessus
-- du seuil de coupure, remis en marche (ceux que l'AUTO a arrêtés) sous le seuil d'enclenchement. Commande externe : gardée.
AS_Terminal.PTO_KEYS = { "mode", "ext", "auto", "aon", "aoff" }
AS_Terminal.PTO_DEF = { 1, 0, 0, 5, 20 }
AS_Terminal.PTO_RANGE = { aon = { 0, 100, 1 }, aoff = { 0, 100, 1 } }
AS_Terminal.PTO_ICON = { aon = "as_clp_on", aoff = "as_clp_off" }
AS_Terminal.ptoAuto = setmetatable({}, { __mode = "k" })
function AS_Terminal:ptoOf(v)
    local p = self:vehPrefs(v)
    local vals = {}
    if p ~= nil and p.pto ~= nil then for x in string.gmatch(p.pto .. ",", "([^,]*),") do vals[#vals + 1] = tonumber(x) or false end end
    local out = {}
    for k, key in ipairs(self.PTO_KEYS) do
        local x = vals[k]
        if x == nil or x == false then x = self.PTO_DEF[k] end
        out[key] = x
    end
    return out
end
function AS_Terminal:ptoSet(v, key, val)
    if v == nil then return end
    local t = self:ptoOf(v)
    t[key] = val
    local o = {}
    for k, kk in ipairs(self.PTO_KEYS) do o[k] = tostring(t[kk]) end
    local p = self:vehPrefs(v, true)
    p.pto = table.concat(o, ",")
    self:saveSettings()
end
-- outils arrière qui tournent ? (nil = aucun outil arrière qui se met en marche)
local function ptoRearOn(v)
    local any, on = false, false
    for _, o in ipairs(trainOf(v)) do
        if o ~= v and o.setIsTurnedOn ~= nil and isTurnedOn(o) ~= nil and hitchSideOf(v, o) == false then
            any = true
            if isTurnedOn(o) == true then on = true end
        end
    end
    if not any then return nil end
    return on
end
function AS_Terminal:ptoApply(v)
    local p = self:vehPrefs(v)
    if p == nil or p.pto == nil then return end
    local ps = self:ptoOf(v)
    local mo = v.spec_motorized ~= nil and v.spec_motorized.motor or nil
    if mo ~= nil and type(mo.ptoMotorRpmRatio) == "number" then
        if mo.asPto0 == nil then mo.asPto0 = mo.ptoMotorRpmRatio end
        mo.ptoMotorRpmRatio = ps.mode == 2 and mo.asPto0 * 0.8 or mo.asPto0
    end
    if ps.auto ~= 1 then self.ptoAuto[v] = nil; return end
    local rear
    for _, h in ipairs(hitches(v)) do if not h.front and h.object ~= nil and h.own == nil then rear = h end end
    if rear == nil then return end
    local hpct = (rear.up or 0) * 100
    local aon = math.min(ps.aon, ps.aoff - 1)          -- seuils croisés : pas de marche / arrêt en boucle
    local onNow = ptoRearOn(v)
    if onNow == nil then return end
    -- seulement au passage d'un seuil : une PdF remise en marche à la main relevage levé reste en marche
    local st = self.ptoAuto[v]
    if st == nil then st = { last = hpct }; self.ptoAuto[v] = st end
    if st.last <= ps.aoff and hpct > ps.aoff and onNow then
        self.cmdSide = false; pcall(self.cmdTurnOn, self, v, false); self.cmdSide = nil
        st.off = true
    elseif st.last >= aon and hpct < aon and st.off then
        if not onNow then self.cmdSide = false; pcall(self.cmdTurnOn, self, v, true); self.cmdSide = nil end
        st.off = nil
    end
    st.last = hpct
end
function AS_Terminal:claasPtoPage(d, ctx, v, Wp, Hp, inside)
    local PX, PY, PW, img, hot = self:claasChassis(d, ctx, v, Wp, Hp, 2, T("cl_hitch"), self:claasView(v) or "field")
    local C0 = RenderText.ALIGN_CENTER
    ctx.rect(PX(0), PY(86), PW(1400), PY(750), CLH_PANEL)
    local ps = self:ptoOf(v)
    local function ctr(name, cx, cy, w, h) img(cx - w * 0.5, cy - h * 0.5, w, h, name) end
    local dlg = self.ptoDlg
    -- ===== réglages (gauche) =====
    ctx.rect(PX(8), PY(92), PW(744), PY(58), CLH_HEAD)
    img(16, 98, 76, 47, "as_clp_head")
    clText(ctx, PX, PY, PW, 104, 121, 32, T("cl_p_title"), CL_DK, nil, 340)
    self:claasHitchTabs(ctx, PX, PY, PW, hot, "pto")
    ctx.rect(PX(8), PY(152), PW(744), PY(44), CLH_HEAD)
    clText(ctx, PX, PY, PW, 18, 174, 28, T("cl_p_sub"), CL_DK, nil, 720)
    local function btn(cx, cy, on, action)
        img(cx - 78, cy - 78, 156, 156, on and "as_clh_btn_on" or "as_clh_btn_off")
        hot(PX(cx - 80), PY(cy - 80), PW(160), PY(160), action)
    end
    btn(98, 286, ps.mode == 1, "pto_mode_1"); ctr("as_clp_pto", 98, 274, 66, 40); clText(ctx, PX, PY, PW, 98, 312, 20, "1000", CL_DK, C0)
    btn(278, 286, ps.mode == 2, "pto_mode_2"); ctr("as_clp_pto", 278, 274, 66, 40); clText(ctx, PX, PY, PW, 278, 312, 20, "1000E", CL_DK, C0)
    btn(458, 286, ps.ext == 1, "pto_tg_ext"); ctr("as_clp_ext", 458, 286, 74, 67)
    ctx.rect(PX(8), PY(386), PW(744), PY(44), CLH_HEAD)
    clText(ctx, PX, PY, PW, 18, 408, 28, T("cl_p_set"), CL_DK, nil, 720)
    btn(98, 520, ps.auto == 1, "pto_tg_auto"); ctr("as_clp_pto", 98, 506, 66, 40); clText(ctx, PX, PY, PW, 98, 546, 22, "AUTO", CL_DK, C0)
    for k, key in ipairs({ "aon", "aoff" }) do
        local cx, cy = 98 + k * 180, 520
        local val = ps[key]
        local r = self.PTO_RANGE[key]
        img(cx - 78, cy - 78, 156, 156, "as_clh_dial")
        img(cx - 78, cy - 78, 156, 156, string.format("as_clh_dial%02d", math.floor(math.max(0, math.min(1, (val - r[1]) / (r[2] - r[1]))) * 20 + 0.5)))
        img(cx - 40, cy - 62, 80, 68, self.PTO_ICON[key])
        clText(ctx, PX, PY, PW, cx, cy + 24, 34, tostring(math.floor(val + 0.5)), CL_DK, C0)
        clText(ctx, PX, PY, PW, cx, cy + 50, 20, "%", CL_DK, C0)
        if dlg ~= nil and dlg.key == key then
            ctx.rect(PX(cx - 88), PY(cy - 88), PW(176), PY(4), CL_GREEN); ctx.rect(PX(cx - 88), PY(cy + 84), PW(176), PY(4), CL_GREEN)
            ctx.rect(PX(cx - 88), PY(cy - 88), PW(4), PY(176), CL_GREEN); ctx.rect(PX(cx + 84), PY(cy - 88), PW(4), PY(176), CL_GREEN)
        end
        hot(PX(cx - 80), PY(cy - 80), PW(160), PY(160), "pto_dlg_" .. key)
    end
    -- ===== droite : état, ou le réglage touché =====
    local RX, RW = 768, 626
    ctx.rect(PX(RX), PY(92), PW(RW), PY(58), CLH_HEAD)
    if dlg == nil then
        img(RX + 10, 98, 76, 47, "as_clp_head")
        local on = ptoRearOn(v)
        clText(ctx, PX, PY, PW, RX + 100, 121, 30, on == nil and T("cl_p_none") or (on and T("cl_p_running") or T("cl_p_stopped")), CL_DK, nil, RW - 120)
        local lines = {
            { T("cl_p_mode"), ps.mode == 2 and "1000E" or "1000" },
            { T("cl_rpm"), string.format("%d", math.floor((d.rpm or 0) + 0.5)) },
            { "AUTO", ps.auto == 1 and string.format(T("cl_p_autoTxt"), math.floor(ps.aoff + 0.5), math.floor(math.min(ps.aon, ps.aoff - 1) + 0.5)) or T("cl_p_autoOff") },
        }
        for k, l in ipairs(lines) do
            local y = 200 + (k - 1) * 90
            clText(ctx, PX, PY, PW, RX + 20, y, 26, l[1], CLH_GREY, nil, RW - 40)
            clText(ctx, PX, PY, PW, RX + 20, y + 36, 32, l[2], CL_DK, nil, RW - 40)
        end
        if on ~= nil then
            ctx.rect(PX(RX + 20), PY(700), PW(RW - 40), PY(80), on and CL_GREEN or CLH_SLOT)
            hot(PX(RX + 20), PY(700), PW(RW - 40), PY(80), "pto_run")
            clText(ctx, PX, PY, PW, RX + RW * 0.5, 740, 32, on and T("cl_p_doStop") or T("cl_p_doRun"), CL_DK, C0, RW - 60)
        end
    else
        local key = dlg.key
        local r = self.PTO_RANGE[key]
        local function fill(x) return math.floor(math.max(0, math.min(1, (x - r[1]) / (r[2] - r[1]))) * 20 + 0.5) end
        img(RX + 10, 94, 64, 54, self.PTO_ICON[key])
        clText(ctx, PX, PY, PW, RX + 84, 121, 30, T("cl_p_" .. key), CL_DK, nil, RW - 154)
        img(RX + RW - 54, 100, 42, 42, "as_clh_x")
        hot(PX(RX + RW - 70), PY(92), PW(70), PY(58), "pto_cancel")
        local cx, cy = RX + 230, 400
        img(cx - 160, cy - 160, 320, 320, "as_clh_dial")
        img(cx - 160, cy - 160, 320, 320, string.format("as_clh_dial%02d", fill(dlg.val)))
        clText(ctx, PX, PY, PW, cx, cy - 22, 72, tostring(math.floor(ps[key] + 0.5)), CL_DK, C0)
        clText(ctx, PX, PY, PW, cx, cy + 46, 46, tostring(math.floor(dlg.val + 0.5)), CLH_BLUE, C0)
        clText(ctx, PX, PY, PW, cx, cy + 112, 30, "%", CL_DK, C0)
        clText(ctx, PX, PY, PW, cx - 120, cy + 192, 32, tostring(r[1]), CL_DK, C0)
        clText(ctx, PX, PY, PW, cx + 120, cy + 192, 32, tostring(r[2]), CL_DK, C0)
        clText(ctx, PX, PY, PW, cx - 120, cy + 242, 30, "MIN", CLH_GREY, C0)
        clText(ctx, PX, PY, PW, cx + 120, cy + 242, 30, "MAX", CLH_GREY, C0)
        local bx = RX + 470
        ctx.rect(PX(bx), PY(152), PW(2), PY(684), CLH_LINE)
        ctx.rect(PX(bx), PY(493), PW(RW - 470), PY(2), CLH_LINE)
        ctx.rect(PX(RX), PY(700), PW(470), PY(2), CLH_LINE)
        local px = bx + (RW - 470) * 0.5
        ctx.rect(PX(px - 32), PY(320), PW(64), PY(5), CL_DK); ctx.rect(PX(px - 2.5), PY(290), PW(5), PY(64), CL_DK)
        ctx.rect(PX(px - 32), PY(662), PW(64), PY(5), CL_DK)
        hot(PX(bx), PY(152), PW(RW - 470), PY(341), "pto_plus")
        hot(PX(bx), PY(495), PW(RW - 470), PY(341), "pto_minus")
        ctr("as_clh_ok", RX + 235, 768, 91, 66)
        hot(PX(RX), PY(702), PW(470), PY(134), "pto_ok")
    end
end

-- (04/11) ACCÈS RAPIDES comme CEBIS connect (vidéo #2) : 4 cases (3 au départ) dans la zone libre de la
-- barre du bas ; chaque case reçoit une fonction (page Configuration des accès rapides : case vide touchée, ou Réglages).
-- Fonctions : basculement AUTO / MANUEL, éclairage (tout allumer / éteindre), nouvelle tâche (compteur remis à zéro),
-- ligne droite (page Guidage), distributeurs (page Hydraulique), prise de force (onglet PdF), Fonction 1 à 4.
AS_Terminal.QA_SLOTS = 4   -- (04/11) 4 cases, flèches retirées de la barre
AS_Terminal.QA_FNS = {
    { "auto", "as_clq_auto", 64, 62 }, { "light", "as_clq_light", 64, 49 }, { "task", "as_clq_task", 46, 56 },
    { "line", "as_clq_line", 64, 58 }, { "hyd", "as_clq_hyd", 72, 32 }, { "pto", "as_clp_pto", 66, 40 },
    { "fn1", "as_claas_fn1", 30, 50 }, { "fn2", "as_claas_fn2", 30, 50 }, { "fn3", "as_claas_fn3", 30, 50 }, { "fn4", "as_claas_fn4", 30, 50 },
}
local QA_BY = {}
for _, f in ipairs(AS_Terminal.QA_FNS) do QA_BY[f[1]] = f end
local function qaLabel(id)
    local n = id:match("^fn(%d)$")
    if n ~= nil then return T("c_remote") .. " " .. n end
    return T("cl_q_" .. id)
end
function AS_Terminal:qaOf(v)
    local p = self:vehPrefs(v)
    local out = {}
    if p == nil or p.qa == nil then return { "auto", "fn1", "light" } end   -- par défaut (4e case libre)
    if p ~= nil and p.qa ~= nil then
        local i = 0
        for w in string.gmatch(p.qa .. ",", "([^,]*),") do
            i = i + 1
            if i <= self.QA_SLOTS and QA_BY[w] ~= nil then out[i] = w end
        end
    end
    return out
end
function AS_Terminal:qaSet(v, k, id)
    if v == nil or k < 1 or k > self.QA_SLOTS then return end
    local cur = self:qaOf(v)
    cur[k] = QA_BY[id] ~= nil and id or nil
    local parts = {}
    for i = 1, self.QA_SLOTS do parts[i] = cur[i] or "" end
    local p = self:vehPrefs(v, true)
    p.qa = table.concat(parts, ",")
    self:saveSettings()
end
function AS_Terminal:qaRun(v, id)
    if id == "light" then
        local spl = v ~= nil and v.spec_lights or nil
        if spl == nil then warn(T("noLights")) return end
        local mask = call(v, "getLightsTypesMask") or spl.lightsTypesMask or 0
        local work = math.floor(mask / 2 ^ LIGHT_BIT.workF) % 2 == 1 or math.floor(mask / 2 ^ LIGHT_BIT.workR) % 2 == 1
        self:cmdLight(v, work and "mem2" or "mem1")
    elseif id == "task" then self:doAction("reset")
    elseif id == "line" then self:doAction("page_cp")
    elseif id == "hyd" then self:doAction("cl_hydpage")
    elseif id == "auto" then self:doAction("cl_diffmode")
    elseif id == "pto" then self.page = "clhitch"; self.claasHitchSub = "pto"; self.hitDlg = nil; self.ptoDlg = nil
    elseif id:match("^fn%d$") then self:doAction("rem_" .. id:sub(3)) end
end
-- cases de la barre du bas (dessinées par le châssis Claas, icônes blanches)
function AS_Terminal:claasQuickBar(ctx, v, PX, PY, PW, img, hot)
    local qa = self:qaOf(v)
    for k = 1, self.QA_SLOTS do
        local cx = 260 + (k - 1) * 95
        local id = qa[k]
        local f = id ~= nil and QA_BY[id] or nil
        if f ~= nil then
            local name = f[2]:sub(1, 9) == "as_claas_" and f[2] or (f[2] .. "_w")
            local s = f[2]:sub(1, 9) == "as_claas_" and 1.4 or 0.9
            img(cx - f[3] * s * 0.5, 890 - f[4] * s * 0.5, f[3] * s, f[4] * s, name)
        else
            clText(ctx, PX, PY, PW, cx, 890, 28, "--", { 0.55, 0.55, 0.56, 1 }, RenderText.ALIGN_CENTER)
        end
        hot(PX(cx - 35), PY(848), PW(70), PY(86), "qa_" .. k)
    end
end
function AS_Terminal:claasQuickPage(d, ctx, v, Wp, Hp, inside)
    local PX, PY, PW, img, hot = self:claasChassis(d, ctx, v, Wp, Hp, 0, T("cl_q_short"), self:claasView(v) or "field")
    local C0 = RenderText.ALIGN_CENTER
    ctx.rect(PX(0), PY(86), PW(1400), PY(750), CLH_PANEL)
    local qa = self:qaOf(v)
    local sel = math.max(1, math.min(self.QA_SLOTS, self.qaSel or 1))
    local function ctr(name, cx, cy, w, h) img(cx - w * 0.5, cy - h * 0.5, w, h, name) end
    local function frame(x, y, w, h)
        ctx.rect(PX(x), PY(y), PW(w), PY(4), CL_GREEN); ctx.rect(PX(x), PY(y + h - 4), PW(w), PY(4), CL_GREEN)
        ctx.rect(PX(x), PY(y), PW(4), PY(h), CL_GREEN); ctx.rect(PX(x + w - 4), PY(y), PW(4), PY(h), CL_GREEN)
    end
    -- gauche : les 4 cases
    ctx.rect(PX(8), PY(92), PW(744), PY(58), CLH_HEAD)
    img(16, 94, 66, 56, "as_clq_head")
    clText(ctx, PX, PY, PW, 100, 121, 32, T("cl_q_title"), CL_DK, nil, 640)
    ctx.rect(PX(8), PY(152), PW(744), PY(44), CLH_HEAD)
    clText(ctx, PX, PY, PW, 18, 174, 28, T("cl_q_setup"), CL_DK, nil, 720)
    for k = 1, self.QA_SLOTS do
        local y = 198 + (k - 1) * 104
        if k > 1 then ctx.rect(PX(8), PY(y - 1), PW(744), PY(2), CLH_LINE) end
        clText(ctx, PX, PY, PW, 22, y + 52, 30, string.format(T("cl_q_slot"), k), CL_DK, nil, 200)
        local f = qa[k] ~= nil and QA_BY[qa[k]] or nil
        if f ~= nil then
            ctr(f[2], 280, y + 52, f[3], f[4])
            clText(ctx, PX, PY, PW, 340, y + 52, 28, qaLabel(f[1]), CL_DK, nil, 400)
        else clText(ctx, PX, PY, PW, 340, y + 52, 28, "--", CL_DK) end
        if k == sel then frame(8, y, 744, 104) end
        hot(PX(8), PY(y), PW(744), PY(104), "qa_sel_" .. k)
    end
    -- droite : les fonctions (coche verte = celle de la case choisie)
    local RX, RW = 768, 626
    ctx.rect(PX(RX), PY(92), PW(RW), PY(58), CLH_HEAD)
    img(RX + 10, 94, 66, 56, "as_clq_head")
    clText(ctx, PX, PY, PW, RX + 96, 121, 30, T("cl_q_setup"), CL_DK, nil, RW - 110)
    local rows = {}
    for _, f in ipairs(self.QA_FNS) do rows[#rows + 1] = f end
    rows[#rows + 1] = { "none" }
    for k, f in ipairs(rows) do
        local y = 152 + (k - 1) * 62
        if k > 1 then ctx.rect(PX(RX), PY(y - 1), PW(RW), PY(2), CLH_LINE) end
        if f[2] ~= nil then ctr(f[2], RX + 52, y + 31, f[3] * 0.8, f[4] * 0.8) end
        clText(ctx, PX, PY, PW, RX + 104, y + 31, 26, f[1] == "none" and "--" or qaLabel(f[1]), CL_DK, nil, RW - 120)
        if (qa[sel] or "none") == f[1] then frame(RX, y, RW, 62) end
        hot(PX(RX), PY(y), PW(RW), PY(62), "qa_set_" .. f[1])
    end
end

-- (04/11) TOUCHES DE FONCTION comme CEBIS connect (vidéo #3) : les 4 touches de l'accoudoir,
-- chacune affectée à un distributeur (Fonction 1 à 4, ou aucune). Page Aperçu (accoudoir + tuiles de couleur,
-- touche choisie encadrée en vert) et Affectation des touches F (information + liste des fonctions).
-- En jeu : actions AS_FKEY1 à 4 (Ctrl droit + 1 à 4 par défaut) = la Fonction affectée, comme son bouton.
AS_Terminal.FK_KEYS = 4
function AS_Terminal:fkOf(v)
    local out = { 1, 2, 3, 4 }
    local p = self:vehPrefs(v)
    if p ~= nil and p.fk ~= nil then
        local i = 0
        for w in string.gmatch(p.fk .. ",", "([^,]*),") do
            i = i + 1
            local n = tonumber(w)
            if i <= self.FK_KEYS and n ~= nil and n >= 0 and n <= 4 then out[i] = math.floor(n) end
        end
    end
    return out
end
function AS_Terminal:fkSet(v, k, n)
    if v == nil or k < 1 or k > self.FK_KEYS then return end
    local cur = self:fkOf(v)
    cur[k] = (n ~= nil and n >= 0 and n <= 4) and n or 0
    local p = self:vehPrefs(v, true)
    p.fk = table.concat(cur, ",")
    self:saveSettings()
end
local function fkLabel(n)
    if n == nil or n < 1 then return "--" end
    return T("c_remote") .. " " .. n .. " (" .. T("cl_k_c" .. n) .. ")"
end
local CLK_ROW = { 0.941, 0.918, 0.937, 1 }      -- rangée des onglets / information (relevé vidéo)
local CLK_SLOT = { 0.859, 0.843, 0.855, 1 }     -- cadre clair autour d'une tuile
local CLK_SLOTB = { 0.70, 0.69, 0.71, 1 }       -- son liseré
function AS_Terminal:claasFkTile(ctx, PX, PY, PW, img, n, x, y, s)
    if n == nil or n < 1 then return end
    img(x, y, s, s, "as_clk_t" .. n)
    clText(ctx, PX, PY, PW, x + s * 0.80, y + s * 0.17, math.floor(s * 0.30 + 0.5), tostring(n), CL_DK, RenderText.ALIGN_CENTER)
end
function AS_Terminal:claasFkPage(d, ctx, v, Wp, Hp, inside)
    local PX, PY, PW, img, hot = self:claasChassis(d, ctx, v, Wp, Hp, 0, T("cl_k_short"), self:claasView(v) or "field")
    ctx.rect(PX(0), PY(86), PW(1400), PY(750), CLH_PANEL)
    local fk = self:fkOf(v)
    local sel = math.max(1, math.min(self.FK_KEYS, self.fkSel or 1))
    local function ctr(name, cx, cy, w, h) img(cx - w * 0.5, cy - h * 0.5, w, h, name) end
    local function frame(x, y, w, h, col, t)
        t = t or 4
        ctx.rect(PX(x), PY(y), PW(w), PY(t), col); ctx.rect(PX(x), PY(y + h - t), PW(w), PY(t), col)
        ctx.rect(PX(x), PY(y), PW(t), PY(h), col); ctx.rect(PX(x + w - t), PY(y), PW(t), PY(h), col)
    end
    local k0 = 0.88                                   -- vidéo 1920 x 1080 ramenée au terminal
    local function VX(x) return 8 + (x - 207) * k0 end
    local function VY(y) return 86 + (y - 112) * k0 end
    -- gauche : Touches de fonction / Aperçu
    ctx.rect(PX(8), PY(92), PW(744), PY(58), CLH_HEAD)
    img(16, 94, 66, 56, "as_clk_head")
    clText(ctx, PX, PY, PW, 100, 121, 32, T("cl_k_title"), CL_DK, nil, 640)
    ctx.rect(PX(8), PY(152), PW(744), PY(44), CLH_HEAD)
    clText(ctx, PX, PY, PW, 18, 174, 28, T("cl_k_over"), CL_DK, nil, 720)
    ctx.rect(PX(8), PY(196), PW(744), PY(110), CLK_ROW)
    frame(18, 200, 102, 102, CL_GREEN)
    ctr("as_clk_arm", 69, 251, 83, 79)
    img(VX(240), VY(565), 796 * k0, 365 * k0, "as_clk_rest")
    local TS, FR = 81 * k0, 14 * k0
    for k = 1, self.FK_KEYS do
        local tx, ty = VX(484 + 134.7 * (k - 1)), VY(468 + 13.7 * (k - 1))
        local fx, fy, fs = tx - FR, ty - FR, TS + 2 * FR
        ctx.rect(PX(fx), PY(fy), PW(fs), PY(fs), CLK_SLOT)
        if k == sel then frame(fx, fy, fs, fs, CL_GREEN, 4) else frame(fx, fy, fs, fs, CLK_SLOTB, 2) end
        if fk[k] > 0 then self:claasFkTile(ctx, PX, PY, PW, img, fk[k], tx, ty, TS)
        else clText(ctx, PX, PY, PW, tx + TS * 0.5, ty + TS * 0.5, 28, "--", CL_DK, RenderText.ALIGN_CENTER) end
        hot(PX(fx), PY(fy), PW(fs), PY(VY(770) - fy), "fk_sel_" .. k)
    end
    -- droite : Affectation des touches F
    local RX, RW = 768, 626
    local function RV(x) return RX + (x - 1150) * 0.94 end
    ctx.rect(PX(RX), PY(92), PW(RW), PY(58), CLH_HEAD)
    img(RX + 10, 94, 66, 56, "as_clk_head")
    clText(ctx, PX, PY, PW, RX + 96, 121, 30, T("cl_k_assign"), CL_DK, nil, RW - 110)
    ctx.rect(PX(RX), PY(152), PW(RW), PY(44), CLH_HEAD)
    clText(ctx, PX, PY, PW, RX + 12, 174, 28, T("cl_k_info"), CL_DK, nil, RW - 24)
    ctx.rect(PX(RX), PY(196), PW(RW), PY(114), CLK_ROW)
    ctr("as_clk_arm", RV(1216), VY(305), 83, 79)
    ctr("as_clk_armA", RV(1353), VY(298), 76, 56)
    ctr("as_clk_arrow", RV(1487), VY(310), 62, 42)
    if fk[sel] > 0 then self:claasFkTile(ctx, PX, PY, PW, img, fk[sel], RV(1758) - TS * 0.5, VY(310) - TS * 0.5, TS)
    else clText(ctx, PX, PY, PW, RV(1758), VY(310), 28, "--", CL_DK, RenderText.ALIGN_CENTER) end
    ctx.rect(PX(RX), PY(310), PW(RW), PY(46), CLH_HEAD)
    clText(ctx, PX, PY, PW, RX + 12, 333, 28, T("cl_k_fns"), CL_DK, nil, RW - 24)
    for k = 1, 5 do
        local n = k <= 4 and k or 0
        local y = 356 + (k - 1) * 96
        if k > 1 then ctx.rect(PX(RX), PY(y - 1), PW(RW), PY(2), CLH_LINE) end
        if n > 0 then self:claasFkTile(ctx, PX, PY, PW, img, n, RX + 22, y + 48 - TS * 0.5, TS) end
        clText(ctx, PX, PY, PW, RX + 124, y + 48, 28, fkLabel(n), CL_DK, nil, RW - 140)
        if fk[sel] == n then frame(RX, y, RW, 96, CL_GREEN) end
        hot(PX(RX), PY(y), PW(RW), PY(96), "fk_set_" .. n)
    end
end
-- touche de l'accoudoir (action AS_FKEY1 à 4) : la Fonction affectée, comme son bouton
function AS_Terminal.onFKey(_, actionName, inputValue, callbackState)
    local self = AS_Terminal
    local k = tonumber(callbackState) or tonumber(tostring(actionName or ""):match("(%d)$") or "")
    local v = AS.shGetControlledVehicle ~= nil and AS.shGetControlledVehicle() or nil
    if k == nil or v == nil then return end
    local n = self:fkOf(v)[k]
    if n == nil or n < 1 then warn(string.format(T("cl_k_noneMsg"), k)) return end
    self:remoteRun(v, n)
    self.lastRead = -100000
end

-- (04/11) GUIDAGE = Courseplay intégré comme le Case (carte en direct + colonne Courseplay),
-- mais tenu dans la zone blanche (0,86 - 1400,836) : rien ne déborde sur la colonne de droite
function AS_Terminal:claasGuidePage(d, ctx, v, Wp, Hp, inside, title)
    local PX, PY, PW, img, hot = self:claasChassis(d, ctx, v, Wp, Hp, 4, T("cl_csm"), self:claasView(v) or "field")
    ctx.rect(PX(0), PY(86), PW(1400), PY(750), CL_BG)
    local k = 750 / 759                        -- colonne Courseplay du Case (1357,94 - 1669,853) ramenée à droite de la zone
    local colX = 1400 - 312 * k
    -- carte (même dessin que le Case, sans ses touches)
    local cx, cy, cw, ch = PX(8), PY(94), PW(colX - 16), PY(734)
    local ctx2 = { text = ctx.text, measure = ctx.measure, rect = ctx.rect, button = ctx.button, hotspot = ctx.hotspot, image = ctx.image,
        cx = cx, cy = cy, cw = cw, ch = ch, rx = cx + cw, sideY = cy, X = ctx.X, Y = ctx.Y, sx = ctx.sx, sy = ctx.sy, rec = ctx.rec, v = v, noKeys = true,
        gpsTextsX = cx + PW(12) }
    if AS_TerminalGps ~= nil then self:page_gps(d, ctx2, inside, v) end
    -- colonne Courseplay : échelle pure + décalage (les fonctions du Case se servent de PY aussi pour les hauteurs)
    local ox, oy = PX(colX - 1357 * k), PY(86 - 94 * k)
    local function QX(x) return PX(x * k) end
    local function QY(y) return PY(y * k) end
    local function QW(w) return PW(w * k) end
    local base, hotB = ctx, hot
    local hot2 = function(x, y, w, h, a) return hotB(x + ox, y + oy, w, h, a) end
    local c3 = setmetatable({
        rect = function(x, y, ...) return base.rect(x + ox, y + oy, ...) end,
        image = function(x, y, ...) return base.image(x + ox, y + oy, ...) end,
        text = function(x, y, ...) return base.text(x + ox, y + oy, ...) end,
        hotspot = hot2,
        button = base.button ~= nil and function(x, y, ...) return base.button(x + ox, y + oy, ...) end or nil,
    }, { __index = base })
    self:caseCpColumn(d, c3, v, QX, QY, QW, hot2)
end

-- point d'entrée (drawPanel) : renvoie la fonction de l'écran à dessiner
function AS_Terminal:claasScreenFor(v)
    if self.page == "home" then
        local view = self:claasView(v)
        if view == "road" then return self.claasRoadScreen elseif view == "field" then return self.claasFieldScreen end
        return self.claasChoiceScreen
    end
    if self.page == "clhyd" then return self.claasHydPage end
    if self.page == "clhitch" then return self.claasHitchPage end
    if self.page == "cp" then return self.claasGuidePage end
    if self.page == "clqa" then return self.claasQuickPage end
    if self.page == "clfk" then return self.claasFkPage end
    return self.claasPage
end

-- (ancienne page COMPTEURS dessinée, gardée pour mémoire)
AS_Terminal.PERF2_CARDS = { { 178, 56, 478, 118 }, { 178, 122, 478, 184 }, { 178, 188, 478, 250 }, { 178, 254, 478, 316 }, { 178, 320, 478, 382 }, { 178, 386, 478, 448 } }
function AS_Terminal:caseTractorPerf2(d, ctx, v, Wp, Hp)
    local PX, PY, PW = self:caseTrFrame(d, ctx, v, Wp, Hp, "as_case_perf2")
    local DK, GR, WH = { 0.10, 0.12, 0.15, 1 }, { 0.30, 0.32, 0.35, 1 }, { 1, 1, 1, 1 }
    local hot = ctx.hotspot or ctx.button
    local c = d.cnt
    local job = c.jobs[c.active]
    local hpH = job.ms > 60000 and job.ha / (job.ms / 3600000) or nil
    local m = math.floor((job.ms or 0) / 60000)
    local vals = {
        { T("c_p2_hours"), string.format("%.1f", d.opHours or 0), "h" },
        { T("c_p2_rate"), hpH ~= nil and string.format("%.1f", hpH) or "0.0", "ha/h" },
        { T("c_p2_fuel"), string.format("%.1f", job.fuel or 0), "L" },
        { T("c_p2_fuelWork"), string.format("%.1f", c.total.fuel or 0), "L" },
        { T("c_p2_fuelAvg"), job.ha > 0.01 and string.format("%.1f", job.fuel / job.ha) or "0.0", "l/ha" },
        { T("c_p2_time"), string.format("%d h %02d", math.floor(m / 60), m % 60), "min" },
    }
    for i, cd in ipairs(self.PERF2_CARDS) do
        local e = vals[i]
        local x0, y0, x1, y1 = PX(cd[1] + self.TR_X0), PY(cd[2]), PX(cd[3] + self.TR_X0), PY(cd[4])
        local tx0 = x0 + PW(56)
        ctx.text(tx0, y0 + 17, 11, e[1], GR, nil, true, x1 - tx0 - 6)
        ctx.text(tx0, y1 - 9, 24, e[2], DK, nil, true, x1 - tx0 - 50)
        local vw = ctx.measure ~= nil and ctx.measure(24, e[2]) or 60
        ctx.text(tx0 + vw + 6, y1 - 9, 12, e[3], DK, nil, true, 44)
    end
    -- droite : tableau des compteurs (Travail 1 / Travail 2 / Total), clic sur une colonne = compteur actif
    local rx0, rx1 = PX(484 + self.TR_X0), PX(776 + self.TR_X0)
    local ty0 = PY(56)
    local cols = { { T("useJob1"), c.jobs[1], 1 }, { T("useJob2"), c.jobs[2], 2 }, { T("total"), c.total } }
    local lw = PW(84)
    local cw = (rx1 - rx0 - lw - 8) / 3
    ctx.text(rx0 + 6, ty0 + 18, 11, T("p_count"), GR, nil, true, lw)
    for j, col in ipairs(cols) do
        local x = rx0 + 4 + lw + (j - 1) * cw
        local act = col[3] ~= nil and col[3] == c.active
        if col[3] ~= nil then hot(x, ty0 + 4, cw - 2, PY(300) - ty0 - 8, "job" .. col[3]) end
        if act then ctx.rect(x, ty0 + 4, cw - 2, PY(300) - ty0 - 8, { 0.88, 0.92, 0.97, 1 }) end
        ctx.text(x + cw * 0.5, ty0 + 18, 10, col[1], act and BLUE_CASE or DK, RenderText.ALIGN_CENTER, true, cw - 4)
    end
    local lines = {
        { T("cover"), function(k) return string.format("%.2f", k.ha or 0) end, "ha" },
        { T("fuel"), function(k) return string.format("%.1f", k.fuel or 0) end, "l" },
        { T("dist"), function(k) return string.format("%.1f", k.km or 0) end, "km" },
        { T("hours"), function(k) return fmtHM(k.ms) end, "h" },
    }
    local lh = (PY(300) - ty0 - 30) / #lines
    for i, ln in ipairs(lines) do
        local y = ty0 + 26 + i * lh
        ctx.text(rx0 + 6, y, 10, ln[1], GR, nil, true, lw - 4)
        for j, col in ipairs(cols) do
            local x = rx0 + 4 + lw + (j - 1) * cw
            ctx.text(x + cw - 20, y, 14, ln[2](col[2]), DK, RenderText.ALIGN_RIGHT, true, cw - 26)
            ctx.text(x + cw - 4, y, 9, ln[3], GR, RenderText.ALIGN_RIGHT, true, 16)
        end
    end
    -- bas droite : remise à zéro du compteur actif
    local by0, by1 = PY(306), PY(448)
    ctx.text((rx0 + rx1) * 0.5, by0 + 24, 11, string.format(T("job"), c.active), GR, RenderText.ALIGN_CENTER, true, rx1 - rx0 - 8)
    local bw, bh = math.min(180, rx1 - rx0 - 20), 36
    local bx, by = (rx0 + rx1) * 0.5 - bw * 0.5, by1 - bh - 12
    ctx.button(bx, by, bw, bh, "reset")
    ctx.rect(bx, by, bw, bh, BLUE_CASE)
    ctx.text(bx + bw * 0.5, by + bh * 0.5 + 5, 12, T("resetJob"), WH, RenderText.ALIGN_CENTER, true, bw - 8)
end


function AS_Terminal:page_tool(d, ctx, inside, v)
    -- (01/11) moissonneuse Case IH : page RÉGLAGES façon AFS Pro
    if self.caseStyle and self.harvestSelf and d.mach ~= nil and d.mach.kind == "combine" then
        local okC, errC = pcall(self.caseCombine, self, d, ctx, v or d.vehicle)
        if okC then return end
        if not self.loggedCaseComb then self.loggedCaseComb = true; log("ERREUR page moissonneuse Case : %s", tostring(errC)) end
    end
    -- (01/11) page façon ISOBUS : un onglet par outil, image du magasin, tuiles et touches de l'outil choisi
    if AS_TerminalTools ~= nil and d.toolTabs ~= nil and #d.toolTabs > 0 then
        local okT, r = pcall(AS_TerminalTools.draw, AS_TerminalTools, self, d, ctx, v or d.vehicle)
        if okT and r then return end
        if not okT and not self.loggedToolsDraw then self.loggedToolsDraw = true; log("ERREUR page outils : %s", tostring(r)) end
    end
    if d.mach ~= nil and AS_TerminalMachine ~= nil then
        local ok, err = pcall(AS_TerminalMachine.draw, AS_TerminalMachine, self, d, ctx)
        if ok then return end
        if not self.loggedMachDraw then self.loggedMachDraw = true; log("ERREUR onglet machine : %s", tostring(err)) end
    end
    -- commandes des outils
    local anyFold, anyOpen = false, false
    for _, t in ipairs(d.tools) do
        if t.unfolded ~= nil then anyFold = true; if t.unfolded then anyOpen = true end end
    end
    if d.anyLowerable then
        sideButton(ctx, 1, "lift", d.anyLowered and T("doRaise") or T("doLower"), d.anyLowered,
            d.anyLowered and T("lowered") or T("raised"))
    end
    if d.anyTurnable then
        sideButton(ctx, 2, "on", d.anyOn and T("doOff") or T("doOn"), d.anyOn, d.anyOn and T("on") or T("off"))
    end
    if anyFold then
        sideButton(ctx, 3, "fold", anyOpen and T("doFold") or T("doUnfold"), anyOpen,
            anyOpen and T("unfolded") or T("folded"))
    end
    -- (31/10) benne et bâche
    local n = 4
    if d.anyTip then
        sideButton(ctx, n, "tipper", d.tipping and T("tipStop") or T("tipGo"), d.tipping == true, d.tipping and T("tipOn") or T("tipOff"))
        n = n + 1
        if d.anyTipSide then
            sideButton(ctx, n, "tipSide", T("tipSide"), false, d.tipSideName or "")
            n = n + 1
        end
    end
    if d.anyCover then
        sideButton(ctx, n, "cover", d.coverOpen and T("coverClose") or T("coverOpen"), d.coverOpen == true,
            d.coverOpen and T("coverIsOpen") or T("coverIsClosed"))
    end
    local u = ctx.cx + 10
    local yy = ctx.cy + 12
    local front, rear
    for _, h in ipairs(d.hitches) do
        -- un outil qui se baisse lui-même passe avant un 3 points vide
        if h.front then
            if front == nil or (h.own ~= nil and front.object == nil) then front = h end
        elseif rear == nil or (h.own ~= nil and rear.own == nil) then rear = h end
    end
    local function hitch(label, h, uu, action)
        -- (31/10 soir) cadre cliquable : baisse / lève seulement cet attelage
        if h ~= nil and h.object ~= nil then ctx.button(uu, yy, 190, 64, action, false) else ctx.rect(uu, yy, 190, 64, C.box) end
        ctx.text(uu + 8, yy + 16, 12, label, C.gray, nil, true)
        if h == nil then
            ctx.text(uu + 8, yy + 44, 15, T("empty"), C.dim, nil, true)
            return
        end
        ctx.text(uu + 182, yy + 16, 12, h.moveDown and T("lowered") or T("raised"),
            h.moveDown and C.lamp or C.white, RenderText.ALIGN_RIGHT, true)
        bar(ctx, uu + 8, yy + 26, 174, 14, h.up, C.blue)
        if h.own ~= nil then
            ctx.text(uu + 8, yy + 58, 12, h.own == "pickup" and T("hitchPickup") or T("hitchTool"), C.white)
        else
            ctx.text(uu + 8, yy + 58, 12, string.format("%s %d %%", T("height"), math.floor(h.up * 100 + 0.5)), C.white)
        end
    end
    hitch(T("hitchF"), front, u, "hitch_f")
    hitch(T("hitchR"), rear, u + 200, "hitch_r")
    yy = yy + 74
    if #d.tools == 0 then
        ctx.text(u + 8, yy + 20, 15, T("noTool"), C.dim, nil, true)
        return
    end
    for i, t in ipairs(d.tools) do
        if i > 3 then break end
        local h = 78
        ctx.rect(u, yy, ctx.cw - 20, h - 6, C.box)
        ctx.text(u + 8, yy + 17, 14, t.name, C.white, nil, true)
        if t.width ~= nil then ctx.text(u + ctx.cw - 28, yy + 17, 13, string.format("%.1f m", t.width), C.gray, RenderText.ALIGN_RIGHT, true) end
        local states = {}
        if t.lowered ~= nil then states[#states + 1] = { t.lowered and T("lowered") or T("raised"), t.lowered } end
        if t.unfolded ~= nil then states[#states + 1] = { t.unfolded and T("unfolded") or T("folded"), t.unfolded } end
        if t.on ~= nil then states[#states + 1] = { t.on and T("on") or T("off"), t.on } end
        if t.tip ~= nil then states[#states + 1] = { t.tip.state ~= 0 and T("tipOn") or T("tipOff"), t.tip.state ~= 0 } end
        if t.cover ~= nil then states[#states + 1] = { t.cover and T("coverIsOpen") or T("coverIsClosed"), t.cover } end
        for j, s in ipairs(states) do
            local sxu = u + 8 + (j - 1) * 120
            ctx.rect(sxu, yy + 26, 8, 8, s[2] and C.lamp or C.dim)
            ctx.text(sxu + 14, yy + 35, 12, s[1], s[2] and C.white or C.gray)
        end
        for j, f in ipairs(t.fills) do
            local fy = yy + 44 + (j - 1) * 14
            bar(ctx, u + 8, fy, 200, 10, f.cap > 0 and f.level / f.cap or 0, C.amber)
            ctx.text(u + 216, fy + 10, 11, string.format("%s  %d / %d", f.title, math.floor(f.level + 0.5), math.floor(f.cap + 0.5)), C.gray)
        end
        yy = yy + h
    end
end

-- page Travail : champ, culture, couverture, guidage (carte : étape 2)
function AS_Terminal:page_work(d, ctx)
    local job = d.cnt.jobs[d.cnt.active]
    local hpH = job.ms > 60000 and job.ha / (job.ms / 3600000) or nil
    local rows = {
        { T("loc"), d.field ~= nil and string.format(T("field"), d.field) or T("outField") },
        { T("fieldArea"), d.fieldHa ~= nil and string.format("%.2f ha", d.fieldHa) or "-" },
        { T("cover"), string.format("%.2f ha", job.ha) },
        { T("rate"), hpH ~= nil and string.format("%.2f ha/h", hpH) or "-" },
        { T("width"), (function()
            local w = 0
            for _, t in ipairs(d.tools) do if (t.width or 0) > w then w = t.width end end
            return w > 0 and string.format("%.1f m", w) or "-"
        end)() },
        { T("b_guide"), d.guide ~= nil and T("g_" .. d.guide) or T("none"), d.guide ~= nil and C.blue or nil },
    }
    for i, r in ipairs(rows) do row(ctx, i, r[1], r[2], r[3]) end
    ctx.text(ctx.cx + ctx.cw * 0.5, ctx.cy + ctx.ch - 20, 12, T("mapSoon"), C.dim, RenderText.ALIGN_CENTER)
end

-- page Compteurs : travail 1, travail 2, total ; remise à zéro, travail actif
-- page Courseplay : état, parcours, réglages du parcours, marche / arrêt (fonctions de Courseplay)
function AS_Terminal:page_cp(d, ctx, inside, v)
    local u, w = ctx.cx + 10, ctx.cw - 20
    if not hasCp(v) then
        if cpInstalled() then ctx.text(u + 8, ctx.cy + 30, 15, T("cpMissing"), C.dim, nil, true) end
        if hasAd(v) then sideButton(ctx, 1, "adStartStop", T("adStartStop"), d.guide == "AD", d.guide == "AD" and T("on") or T("off")) end
        return
    end
    local active = call(v, "getIsCpActive") == true
    local course = call(v, "getFieldWorkCourse")
    local nWp = course ~= nil and call(course, "getNumberOfWaypoints") or nil
    local hasCourse = call(v, "hasCpCourse") == true
    local state
    if active then state = T("cpActive")
    elseif not hasCourse then state = T("cpNoCourse")
    elseif call(v, "getCanStartCp") == true then state = T("cpReady")
    else state = T("cpNotReady") end
    local function str(st)
        if st == nil or st.getString == nil then return "-" end
        local ok, r = pcall(st.getString, st)
        return ok and tostring(r) or "-"
    end
    local cs = call(v, "getCourseGeneratorSettings")
    local items = {
        { T("cpState"), state, active and C.lamp or (hasCourse and C.white or C.amber) },
        { T("cpCourse"), hasCourse and string.format(T("cpPoints"), nWp or 0) or T("none") },
        { T("cpStart"), str(call(v, "getCpStartingPointSetting")), nil, nil, "cp_start" },
        { T("cpWidth"), cs ~= nil and str(cs.workWidth) or "-", nil, "cp_w-", "cp_w+" },
        { T("cpHeadlands"), cs ~= nil and str(cs.numberOfHeadlands) or "-", nil, "cp_h-", "cp_h+" },
    }
    for i, it in ipairs(items) do
        local yy = ctx.cy + 12 + (i - 1) * 34
        ctx.rect(u, yy, w, 30, C.box)
        ctx.text(u + 8, yy + 20, 13, it[1], C.white)
        local hasBtn = it[4] ~= nil or it[5] ~= nil
        ctx.text(u + w - (hasBtn and 110 or 8), yy + 20, 13, it[2], it[3] or C.lamp, RenderText.ALIGN_RIGHT, true)
        if it[4] ~= nil then
            ctx.button(u + w - 102, yy + 4, 40, 22, it[4])
            ctx.text(u + w - 82, yy + 20, 13, "-", C.white, RenderText.ALIGN_CENTER, true)
            ctx.button(u + w - 56, yy + 4, 48, 22, it[5])
            ctx.text(u + w - 32, yy + 20, 13, "+", C.white, RenderText.ALIGN_CENTER, true)
        elseif it[5] ~= nil then
            ctx.button(u + w - 102, yy + 4, 94, 22, it[5])
            ctx.text(u + w - 55, yy + 20, 11, T("change"), C.white, RenderText.ALIGN_CENTER, true)
        end
    end
    ctx.text(u + 8, ctx.cy + 12 + #items * 34 + 18, 11, T("cpHint"), C.gray)
    -- (31/10) parcours enregistrés qui vont avec ce champ et cet outil (CHERCHER UN TRAVAIL)
    if AS_TerminalCourses ~= nil then
        local ok, err = pcall(AS_TerminalCourses.drawList, AS_TerminalCourses, v, ctx, ctx.cy + 12 + #items * 34 + 30)
        if not ok and not self.loggedCourses then self.loggedCourses = true; log("ERREUR liste parcours : %s", tostring(err)) end
    end
    sideButton(ctx, 1, "cp_startStop", active and T("cpStop") or T("cpGo"), active)
    sideButton(ctx, 2, "cp_generate", T("cpGenerate"), false)
    sideButton(ctx, 3, "cp_clear", T("cpClear"), false)
    sideButton(ctx, 4, "cp_menu", T("cpMenu"), false)
    if hasAd(v) then sideButton(ctx, 5, "adStartStop", T("adStartStop"), d.guide == "AD", d.guide == "AD" and T("on") or T("off")) end
    if AS_TerminalCourses ~= nil then sideButton(ctx, hasAd(v) and 6 or 5, "cp_find", T("cpFind"), false) end
end

-- (01/11) page GPS : écran de travail façon terminal réel (TerminalGps.lua) ; page Courseplay en secours
function AS_Terminal:page_gps(d, ctx, inside, v)
    if AS_TerminalGps ~= nil then
        local okG, r = pcall(AS_TerminalGps.draw, AS_TerminalGps, self, d, ctx, v or d.vehicle)
        if okG and r then return end
        if not okG and not self.loggedGpsDraw then self.loggedGpsDraw = true; log("ERREUR page GPS : %s", tostring(r)) end
    end
    return self:page_cp(d, ctx, inside, v)
end

-- (01/11, étape 36) page FarmPilot (TerminalFarmPilot.lua)
function AS_Terminal:page_fp(d, ctx, inside, v)
    if AS_TerminalFp ~= nil then
        local okF, r = pcall(AS_TerminalFp.drawPage, AS_TerminalFp, self, d, ctx, v or d.vehicle)
        if okF and r then return end
        if not okF and not self.loggedFpDraw then self.loggedFpDraw = true; log("ERREUR page FarmPilot : %s", tostring(r)) end
    end
    if fpInstalled() then ctx.text(ctx.cx + ctx.cw * 0.5, ctx.cy + 60, 13, T("fpMissing"), C.gray, RenderText.ALIGN_CENTER, nil, ctx.cw - 20) end
end

function AS_Terminal:page_count(d, ctx)
    -- (01/11) Case IH : grandes cases du vrai terminal (page PERF2) pour le travail en cours
    if self.caseStyle then
        local k = d.cnt.jobs[d.cnt.active] or d.cnt.total
        local cells = {
            { "as_case_d_hours", T("opHours"), string.format("%.1f", d.opHours or 0), "h" },
            { "as_case_d_work", T("c_workRate"), k.ms > 60000 and string.format("%.1f", k.ha / (k.ms / 3600000)) or "0.0", "ha/h" },
            { "as_case_d_fuel", T("fuelUsed"), string.format("%.1f", k.fuel), "l" },
            { "as_case_d_area", T("cover"), string.format("%.2f", k.ha), "ha" },
            { "as_case_d_fueleco", T("c_fuelEco"), k.ha > 0.01 and string.format("%.1f", k.fuel / k.ha) or "0.0", "l/ha" },
            { "as_case_d_hours", T("hours"), fmtHM(k.ms), "h" },
            { "as_case_d_speed", T("dist"), string.format("%.1f", k.dist / 1000), "km" },
            { "as_case_d_fuelrate", T("c_fuelRate"), fmt1(d.fuelUse), "l/h" },
        }
        ctx.rect(ctx.cx + 8, ctx.cy + 8, ctx.cw - 16, 24, C.boxHi)
        ctx.text(ctx.cx + ctx.cw * 0.5, ctx.cy + 25, 13, d.cnt.active == 1 and T("jobN1") or (d.cnt.active == 2 and T("jobN2") or T("total")),
            C.white, RenderText.ALIGN_CENTER, true)
        local cols, gap = 2, 6
        local rows = math.ceil(#cells / cols)
        local w = (ctx.cw - 16 - gap) / cols
        local h = (ctx.ch - 44 - gap * (rows - 1)) / rows
        for i, c in ipairs(cells) do
            local col, r = (i - 1) % cols, math.floor((i - 1) / cols)
            W.caseCell(ctx, ctx.cx + 8 + col * (w + gap), ctx.cy + 38 + r * (h + gap), w, h, c[1], c[2], c[3], c[4], c[5])
        end
        local bx, by = ctx.rx + 6, ctx.cy + 22
        local function rbtn(i, action, label, hot)
            ctx.button(bx, by + (i - 1) * 40, 128, 34, action, hot)
            ctx.text(bx + 64, by + (i - 1) * 40 + 22, 11, label, C.white, RenderText.ALIGN_CENTER, true)
        end
        rbtn(1, "job1", T("useJob1"), d.cnt.active == 1)
        rbtn(2, "job2", T("useJob2"), d.cnt.active == 2)
        rbtn(3, "reset", T("resetJob"))
        return
    end
    local cols = { { T("jobN1"), d.cnt.jobs[1], 1 }, { T("jobN2"), d.cnt.jobs[2], 2 }, { T("total"), d.cnt.total } }
    local w = (ctx.cw - 40) / 3
    for i, c in ipairs(cols) do
        local u = ctx.cx + 10 + (i - 1) * (w + 10)
        local active = c[3] ~= nil and c[3] == d.cnt.active
        ctx.rect(u, ctx.cy + 12, w, 26, active and C.green or C.box)
        ctx.text(u + w * 0.5, ctx.cy + 30, 13, c[1], C.white, RenderText.ALIGN_CENTER, true)
        local k = c[2]
        local lines = {
            { T("cover"), string.format("%.2f ha", k.ha) },
            { T("hours"), fmtHM(k.ms) .. " h" },
            { T("fuelUsed"), string.format("%.0f l", k.fuel) },
            { T("dist"), string.format("%.1f km", k.dist / 1000) },
            { "l/ha", k.ha > 0.01 and string.format("%.1f", k.fuel / k.ha) or "-" },
            { "ha/h", k.ms > 60000 and string.format("%.2f", k.ha / (k.ms / 3600000)) or "-" },
        }
        for j, l in ipairs(lines) do
            local yy = ctx.cy + 44 + (j - 1) * 27
            ctx.rect(u, yy, w, 24, C.box)
            ctx.text(u + 6, yy + 17, 12, l[1], C.gray, nil, nil, w * 0.56)
            ctx.text(u + w - 6, yy + 17, 13, l[2], C.white, RenderText.ALIGN_RIGHT, true, w * 0.40)
        end
    end
    -- boutons de la colonne de droite
    local bx, by = ctx.rx + 6, ctx.cy + 22
    local function rbtn(i, action, label, hot)
        ctx.button(bx, by + (i - 1) * 40, 128, 34, action, hot)
        ctx.text(bx + 64, by + (i - 1) * 40 + 22, 11, label, C.white, RenderText.ALIGN_CENTER, true)
    end
    rbtn(1, "job1", T("useJob1"), d.cnt.active == 1)
    rbtn(2, "job2", T("useJob2"), d.cnt.active == 2)
    rbtn(3, "reset", T("resetJob"))
end

-- page Réglages
-- (06/11) lignes de réglage (libellé, valeur, action -, action + ou changer), aussi pour l'iMonitor Deutz
function AS_Terminal:setItems(d, inside, v)
    local s = self.settings
    local showTxt = ({ T("showBoth"), T("showCab"), T("showOut") })[s.show]
    local items = {
        { T("size"), string.format("%d %%", s.size), "size-", "size+" },
        { T("show"), showTxt, nil, "show" },
        { T("touchStopped"), s.touchStopped and T("yes") or T("no"), nil, "touchStopped" },
        { T("cpHudBlock"), s.cpHudBlock ~= false and T("yes") or T("no"), nil, "cpHudBlock" },
        { T("beeps"), s.beeps and T("yes") or T("no"), nil, "beeps" },
        { T("theme"), (s.theme or 3) == 3 and T("themeBrand") or ((s.theme or 1) == 2 and T("themeLight") or T("themeDark")), nil, "theme" },
        { T("reserve"), string.format("%d %%", s.fuelReserve), "res-", "res+" },
        { T("move"), T("moveHow") },
        { T("savedFor"), string.format("%s - %s", d.name, inside and T("cab") or T("out")) },
        { T("tablet"), s.tablet and T("yes") or T("no"), nil, "tablet" },
    }
    -- (01/11, étape 36) HUD FarmPilot caché (icône d'édition) ou affiché, sur les véhicules avec le terminal
    if isFarmPilot() then table.insert(items, 5, { T("fpHud"), s.fpHudHide ~= false and T("fpHudHidden") or T("fpHudShown"), nil, "fpHudHide" }) end
    -- (04/11) Claas : configuration des accès rapides de la barre du bas
    do
        local okB, bs = pcall(self.brandStyle, self, v)
        if okB and type(bs) == "table" and bs.claas then items[#items + 1] = { T("cl_q_title"), T("cl_q_open"), nil, "cl_qa" }; items[#items + 1] = { T("cl_k_title"), T("cl_k_open"), nil, "cl_fk" } end
        -- (06/11) iMonitor Deutz : thème clair le jour, sombre la nuit, ou au choix
        if okB and type(bs) == "table" and bs.df then items[#items + 1] = { T("df_theme"), ({ T("df_themeAuto"), T("df_themeLight"), T("df_themeDark") })[s.dfTheme or 1], nil, "dfTheme" } end
    end
    -- (31/10) réglages de la tablette sur leur propre page (bouton TABLETTE)
    local tabPage = self.setSub == "tab"
    if tabPage then items = { { T("tablet"), s.tablet and T("yes") or T("no"), nil, "tablet" } } end
    -- (01/11) tuiles de l'accueil pour ce modèle : Auto (selon le véhicule), Toujours, Jamais
    local homePage = self.setSub == "home"
    if homePage then
        items = { { T("hmFor"), cut(d.name, 30) } }
        local st = self:brandStyle(v)
        local arr = self.HOME_ARR[st.layout or "fendt"] or self.HOME_ARR.fendt
        local ov = self:homeOverrides(v)
        local shown = {}
        for _, p in ipairs(self.homeLast or {}) do shown[p.id] = true end
        for _, id in ipairs(self.HOME_ORDER) do
            local inArr = arr.pref[id] ~= nil or id == "tools"
            if id == "lights" and arr.noLights then inArr = false end
            if id == "quick" and arr.keys then inArr = false end
            if inArr then
                local val = ov[id]
                local txt
                if val == 1 then txt = T("hmAlways") elseif val == 2 then txt = T("hmNever")
                else txt = string.format("%s (%s)", T("hmAuto"), shown[id] and T("hmShown") or T("hmHidden")) end
                items[#items + 1] = { T("hm_" .. id), txt, nil, "hm_" .. id }
            end
        end
    end
    -- réglage de la place de la tablette (cm), gardé par modèle
    if tabPage and s.tablet and AS_TerminalTablet ~= nil then
        local ox, oy, oz = AS_TerminalTablet:getOffset(v)
        local function cm(m) return string.format("%+d cm", math.floor(m * 100 + 0.5)) end
        local ts, tp, tr = AS_TerminalTablet:getShape(v)
        items[#items + 1] = { T("tab3d"), s.screen3d ~= false and T("yes") or T("no"), nil, "screen3d" }
        items[#items + 1] = { T("display"), (s.display or 1) == 3 and T("dispBoth") or ((s.display or 1) == 2 and T("dispVehicle") or T("dispTablet")), nil, "display" }
        -- (01/11, étape 37) 2e et 3e écrans du véhicule, choisis seulement depuis l'écran principal
        -- (ou la grande fenêtre), jamais sur un écran déjà pris ; chacun garde sa propre page
        if self.curSlot == nil and s.screen3d ~= false then
            local tb = AS_TerminalTablet.tablets[v]
            local nAll = tb ~= nil and tb.allScreens ~= nil and #tb.allScreens or nil
            local pe = self.positions[AS_TerminalTablet.extKeyOf(v)]
            for slot = 2, 3 do
                local cur = pe ~= nil and pe["scr" .. slot] or 0
                local val
                if cur ~= nil and cur > 0 then val = nAll ~= nil and string.format("%d / %d", cur, nAll) or tostring(cur)
                elseif nAll == 0 then val = T("vehNone") else val = T("extOff") end
                items[#items + 1] = { T("ext" .. slot), val, nil, "ext" .. slot }
            end
        end
        if (s.display or 1) ~= 1 then  -- (01/11) aussi en « Les 2 »
            local tb = AS_TerminalTablet.tablets[v]
            local n = tb ~= nil and tb.vehList ~= nil and #tb.vehList or 0
            local cur = tb ~= nil and tb.vehIdx or 0
            items[#items + 1] = { T("vehScreen"), n > 0 and (cur > 0 and string.format("%d / %d", cur, n) or T("vehOff")) or T("vehNone"), nil, "vehNext" }
            -- (31/10 soir) plan du terminal : celui de l'écran d'origine, ou tourné vers la tête
            if n > 0 and cur > 0 then
                local pp = AS_Terminal.positions[AS_TerminalTablet.modelKeyOf(v)]
                items[#items + 1] = { T("vehOri"), (pp ~= nil and pp.ori == 2) and T("oriHead") or T("oriPart"), nil, "vehOri" }
                -- (31/10 soir) largeur, hauteur et rotation de la page sur l'écran, gardées par modèle
                local dft = (AS_TerminalTablet ~= nil and AS_TerminalTablet.screenDefault ~= nil) and AS_TerminalTablet:screenDefault(v) or nil
                dft = dft or {}
                items[#items + 1] = { T("vehW"), string.format("%d %%", (pp ~= nil and pp.sw) or dft.sw or 100), "vw-", "vw+" }
                items[#items + 1] = { T("vehH"), string.format("%d %%", (pp ~= nil and pp.sh) or dft.sh or 100), "vh-", "vh+" }
                items[#items + 1] = { T("vehRot"), string.format("%+d°", pp ~= nil and pp.rz or 0), "vr-", "vr+" }
            end
        end
        if (s.display or 1) ~= 2 then
            items[#items + 1] = { T("tabPlace"), (s.tabPreset or 1) == 2 and T("tabLow") or T("tabHigh"), nil, "tabPreset" }
        end
        items[#items + 1] = { T("tabS"), string.format("%d %%", ts), "ts-", "ts+" }
        items[#items + 1] = { T("tabX"), cm(ox), "tx-", "tx+" }
        items[#items + 1] = { T("tabY"), cm(oy), "ty-", "ty+" }
        items[#items + 1] = { T("tabZ"), cm(oz), "tz-", "tz+" }
        items[#items + 1] = { T("tabP"), string.format("%+d°", tp), "tp-", "tp+" }
        items[#items + 1] = { T("tabR"), string.format("%+d°", tr), "tr-", "tr+" }
    end
    return items, tabPage, homePage
end
function AS_Terminal:page_set(d, ctx, inside, v)
    local items, tabPage, homePage = self:setItems(d, inside, v)
    -- (31/10) lignes resserrées quand il y en a beaucoup (réglages de la tablette)
    local rh = math.min(30, math.floor((ctx.ch - 14) / #items))
    local bh = rh - 6
    local ty = math.floor(bh * 0.5 + 6)
    for i, it in ipairs(items) do
        local u = ctx.cx + 10
        local w = ctx.cw - 20
        local yy = ctx.cy + 10 + (i - 1) * rh
        ctx.rect(u, yy, w, rh - 3, C.box)
        ctx.text(u + 8, yy + ty + 2, 13, it[1], C.white)
        local valX = u + w - (it[4] ~= nil and 110 or 8)
        -- (01/11) valeur limitée à la place laissée par le libellé (écran 3D : plus de chevauchement)
        local labW = ctx.measure ~= nil and ctx.measure(13, it[1]) or 0
        ctx.text(valX, yy + ty + 2, 13, it[2], C.lamp, RenderText.ALIGN_RIGHT, true, math.max(60, valX - (u + 8 + labW + 14)))
        if it[3] ~= nil then
            ctx.button(u + w - 102, yy + 2, 40, bh, it[3])
            ctx.text(u + w - 82, yy + ty + 2, 13, "-", C.white, RenderText.ALIGN_CENTER, true)
            ctx.button(u + w - 56, yy + 2, 48, bh, it[4])
            ctx.text(u + w - 32, yy + ty + 2, 13, "+", C.white, RenderText.ALIGN_CENTER, true)
        elseif it[4] ~= nil then
            ctx.button(u + w - 102, yy + 2, 94, bh, it[4])
            ctx.text(u + w - 55, yy + ty + 1, 11, T("change"), C.white, RenderText.ALIGN_CENTER, true)
        end
    end
    local bx, by = ctx.rx + 6, ctx.cy + 22
    ctx.button(bx, by, 128, 34, "resetPos")
    ctx.text(bx + 64, by + 22, 11, T("resetPos"), C.white, RenderText.ALIGN_CENTER, true)
    ctx.button(bx, by + 40, 128, 34, "resetSize")
    ctx.text(bx + 64, by + 62, 11, T("resetSize"), C.white, RenderText.ALIGN_CENTER, true)
    ctx.button(bx, by + 80, 128, 34, "setSub", tabPage)
    ctx.text(bx + 64, by + 102, 11, tabPage and T("setMain") or T("setTab"), C.white, RenderText.ALIGN_CENTER, true)
    ctx.button(bx, by + 120, 128, 34, "setHome", homePage)
    ctx.text(bx + 64, by + 142, 11, homePage and T("setMain") or T("setHome"), C.white, RenderText.ALIGN_CENTER, true)
    ctx.button(bx, by + 160, 128, 34, "page_tractor")
    ctx.text(bx + 64, by + 182, 11, T("back"), C.white, RenderText.ALIGN_CENTER, true)
end

-------------------------------------------------------------------------------
-- Alarmes (réserve de carburant)
-------------------------------------------------------------------------------
local function beep()
    if not AS_Terminal.settings.beeps then return end
    local sp = g_gui ~= nil and g_gui.guiSoundPlayer or nil
    if sp ~= nil and sp.playSample ~= nil and GuiSoundPlayer ~= nil and GuiSoundPlayer.SOUND_SAMPLES ~= nil then
        pcall(sp.playSample, sp, GuiSoundPlayer.SOUND_SAMPLES.ERROR or GuiSoundPlayer.SOUND_SAMPLES.CLICK)
    end
end

function AS_Terminal:checkAlarms()
    local d = self.data
    if d == nil or d.fuel == nil then return end
    local key = counterKey(d.vehicle)
    local low = d.fuel * 100 < self.settings.fuelReserve
    if low and not self.alarm[key] then
        self.alarm[key] = true
        beep()
        if AS.showTimedNotification ~= nil and FSBaseMission ~= nil then
            pcall(AS.showTimedNotification, "alert", FSBaseMission.INGAME_NOTIFICATION_CRITICAL,
                string.format(T("fuelLow"), d.name, math.floor(d.fuel * 100 + 0.5)))
        end
    elseif not low and d.fuel * 100 > self.settings.fuelReserve + 2 then
        self.alarm[key] = nil
    end
end

-------------------------------------------------------------------------------
-- Souris : boutons et déplacement par le bandeau bleu
-------------------------------------------------------------------------------
local function inBox(b, px, py_)
    return b ~= nil and px >= b.x and px <= b.x + b.w and py_ >= b.y and py_ <= b.y + b.h
end

-- (06/11) haut du cadre AutoSwitch (logo) : poignée de la grande fenêtre
function AS_Terminal:bezelBox()
    local p = self.panel
    if p == nil or p.onTablet or p.w == nil then return nil end
    local fw, fh = AS_Terminal.FRAME_W or 1, AS_Terminal.FRAME_H or 1
    return { x = p.x - p.w * (fw - 1) * 0.5, y = p.y + p.h, w = p.w * fw, h = math.max(p.h * (fh - 1) * 0.5, 0.01) }
end

function AS_Terminal:pageStep(step)
    local idx = 1
    for i, p in ipairs(self.PAGES) do if p == self.page then idx = i end end
    idx = (idx - 1 + step) % #self.PAGES + 1
    -- (01/11) page FarmPilot sautée si le véhicule ne l'a pas
    if self.PAGES[idx] == "fp" then
        local v = self.data ~= nil and self.data.vehicle or nil
        if AS_TerminalFp == nil or not AS_TerminalFp:available(v) then idx = (idx - 1 + step) % #self.PAGES + 1 end
    end
    self.page = self.PAGES[idx]
end

function AS_Terminal:doAction(a)
    if hiddenAction(a) then return end   -- (13/11) bouton d'un mod pas installé (plus dessiné)
    local d = self.data
    local s = self.settings
    if self.remoteMenu ~= nil and a:sub(1, 5) ~= "rsel_" and a:sub(1, 4) ~= "rfn_" then self.remoteMenu = nil end
    if self.colMenu ~= nil and a:sub(1, 5) ~= "colc_" and a:sub(1, 5) ~= "cols_" then self.colMenu = nil end
    -- (étape 37) PLUS : la barre du bas montre RELEVAGE, INFO, TRAVAIL, COMPTEURS ; un choix de page la referme
    if a == "more" then
        self.moreOpen = not self.moreOpen
        return
    end
    if a:sub(1, 5) == "page_" then self.moreOpen = nil end
    if a == "page_hitch" then   -- (03/11 soir) onglet Relevage = accueil sur « Relevage AR »
        self.page = "home"; self.homeSub = "hitch_r"
    elseif a:sub(1, 5) == "page_" then
        local p = a:sub(6)
        self.page = (p == "set" and self.page == "set") and "home" or p
        if self.page == "home" then self.homeSub = "lights" end   -- (03/11) accueil = retour sur Lights
    elseif a == "cl_diffmode" then
        if AS_Diff ~= nil and AS_Diff.onModeAction ~= nil then AS_Diff:onModeAction() end
    elseif a == "cl_hitchpage" then self.page = "clhitch"; self.hitDlg = nil   -- (04/11) Claas : page Attelage
    elseif a:sub(1, 4) == "clh_" then self.claasHitchSub = a:sub(5); self.hitDlg = nil; self.ptoDlg = nil
    elseif a:sub(1, 3) == "fk_" or a == "cl_fk" then
        -- (04/11) touches de fonction CEBIS : choix de la touche, choix de sa Fonction
        local v = self.panel ~= nil and self.panel.vehicle or (d ~= nil and d.vehicle or nil)
        if a == "cl_fk" then self.page = "clfk"
        elseif a:sub(1, 7) == "fk_sel_" then self.fkSel = tonumber(a:sub(8)) or 1
        elseif a:sub(1, 7) == "fk_set_" then self:fkSet(v, math.max(1, math.min(self.FK_KEYS, self.fkSel or 1)), tonumber(a:sub(8)) or 0) end
    elseif a:sub(1, 3) == "qa_" or a == "cl_qa" then
        -- (04/11) accès rapides CEBIS : case de la barre (vide = configuration), choix de la case, choix de la fonction
        local v = self.panel ~= nil and self.panel.vehicle or (d ~= nil and d.vehicle or nil)
        local k = tonumber(a:match("^qa_(%d)$") or "")
        if a == "cl_qa" then self.page = "clqa"
        elseif k ~= nil then
            local id = self:qaOf(v)[k]
            if id == nil then self.page = "clqa"; self.qaSel = k else self:qaRun(v, id) end
        elseif a:sub(1, 7) == "qa_sel_" then self.qaSel = tonumber(a:sub(8)) or 1
        elseif a:sub(1, 7) == "qa_set_" then self:qaSet(v, math.max(1, math.min(self.QA_SLOTS, self.qaSel or 1)), a:sub(8)) end
    elseif a:sub(1, 4) == "pto_" and (self.panel ~= nil or d ~= nil) then
        -- (04/11) Prise de force CEBIS : 1000 / 1000E, commande externe, AUTO PdF et ses seuils, marche / arrêt arrière
        local v = self.panel ~= nil and self.panel.vehicle or d.vehicle
        if a == "pto_mode_1" or a == "pto_mode_2" then self:ptoSet(v, "mode", a == "pto_mode_2" and 2 or 1)
        elseif a == "pto_tg_ext" or a == "pto_tg_auto" then
            local key = a:sub(8)
            local ps = self:ptoOf(v)
            self:ptoSet(v, key, ps[key] == 1 and 0 or 1)
        elseif a:sub(1, 8) == "pto_dlg_" then
            local key = a:sub(9)
            if self.PTO_RANGE[key] ~= nil then self.ptoDlg = { key = key, val = self:ptoOf(v)[key] } end
        elseif (a == "pto_plus" or a == "pto_minus") and self.ptoDlg ~= nil then
            local g = self.ptoDlg
            local r = self.PTO_RANGE[g.key]
            g.val = math.max(r[1], math.min(r[2], g.val + (a == "pto_plus" and r[3] or -r[3])))
        elseif a == "pto_ok" and self.ptoDlg ~= nil then
            self:ptoSet(v, self.ptoDlg.key, self.ptoDlg.val)
            self.ptoDlg = nil
        elseif a == "pto_cancel" then self.ptoDlg = nil
        elseif a == "pto_run" then
            self.cmdSide = false
            local ok = pcall(self.cmdTurnOn, self, v)
            self.cmdSide = nil
            self.ptoAuto[v] = nil
            self.lastRead = -100000
        end
    elseif a:sub(1, 4) == "hit_" and (self.panel ~= nil or d ~= nil) then
        -- (04/11) Attelage CEBIS : amortissement, mode des stabilisateurs, réglage des cadrans
        local v = self.panel ~= nil and self.panel.vehicle or d.vehicle
        local front = self.claasHitchSub == "hitch_f"
        if a == "hit_tg_damp" then
            local hs = self:hitchSetOf(v, front)
            self:hitchSetSet(v, front, "damp", hs.damp == 1 and 0 or 1)
        elseif a == "hit_stab" then
            if self.hitDlg ~= nil and self.hitDlg.key == "stab" then self.hitDlg = nil else self.hitDlg = { front = front, key = "stab" } end
        elseif a:sub(1, 9) == "hit_stab_" then
            local n = tonumber(a:sub(10))
            if n ~= nil and n >= 1 and n <= 3 then self:hitchSetSet(v, front, "stab", n) end
            self.hitDlg = nil
        elseif a:sub(1, 8) == "hit_dlg_" then
            local key = a:sub(9)
            if self.HIT_RANGE[key] ~= nil then self.hitDlg = { front = front, key = key, val = self:hitchSetOf(v, front)[key] } end
        elseif (a == "hit_plus" or a == "hit_minus") and self.hitDlg ~= nil and self.hitDlg.val ~= nil then
            local g = self.hitDlg
            local r = self.HIT_RANGE[g.key]
            g.val = math.max(r[1], math.min(r[2], g.val + (a == "hit_plus" and r[3] or -r[3])))
        elseif a == "hit_ok" and self.hitDlg ~= nil and self.hitDlg.val ~= nil then
            self:hitchSetSet(v, self.hitDlg.front, self.hitDlg.key, self.hitDlg.val)
            self.hitDlg = nil
        elseif a == "hit_cancel" then self.hitDlg = nil end
    elseif a == "cl_remotes" or a == "cl_hydpage" then self.page = "clhyd"; self.hydDlg = nil
    elseif a:sub(1, 4) == "hyd_" and (self.panel ~= nil or d ~= nil) then
        -- (04/11) Hydraulique CEBIS : choix du distributeur, manette, priorité / aile / verrou, réglage des cadrans
        local v = self.panel ~= nil and self.panel.vehicle or d.vehicle
        local sel = math.max(1, math.min(4, self.hydSel or 1))
        local n = tonumber(a:match("_(%d+)$") or "")
        if a:sub(1, 8) == "hyd_sel_" and n ~= nil then
            self.hydSel = n
        elseif a:sub(1, 8) == "hyd_lev_" and n ~= nil then
            self.hydSel = n
            local h = self:hydOf(v, n)
            self:hydSet(v, n, "lever", (h.lever + 1) % 5)
        elseif a == "hyd_up" then self.hydScroll = 0
        elseif a == "hyd_dn" then self.hydScroll = 1
        elseif a:sub(1, 7) == "hyd_tg_" then
            local key = a:sub(8)
            local h = self:hydOf(v, sel)
            if h[key] ~= nil then self:hydSet(v, sel, key, h[key] == 1 and 0 or 1) end
        elseif a:sub(1, 8) == "hyd_dlg_" then
            local key = a:sub(9)
            if self.HYD_RANGE[key] ~= nil then self.hydDlg = { i = sel, key = key, val = self:hydOf(v, sel)[key] } end
        elseif (a == "hyd_plus" or a == "hyd_minus") and self.hydDlg ~= nil then
            local g = self.hydDlg
            local r = self.HYD_RANGE[g.key]
            g.val = math.max(r[1], math.min(r[2], g.val + (a == "hyd_plus" and r[3] or -r[3])))
        elseif a == "hyd_ok" and self.hydDlg ~= nil then
            self:hydSet(v, self.hydDlg.i, self.hydDlg.key, self.hydDlg.val)
            self.hydDlg = nil
        elseif a == "hyd_cancel" then self.hydDlg = nil end
    elseif (a == "cl_road" or a == "cl_field" or a == "cl_choice" or a == "cl_toggle") and (self.panel ~= nil or d ~= nil) then
        -- (04/11) Claas : écran de choix, On Road / On Field, flèche = autre vue
        -- (64c) clic sur la tablette, grande fenêtre fermée : pas de self.panel, véhicule des données lues
        local v = self.panel ~= nil and self.panel.vehicle or d.vehicle
        local view = a == "cl_road" and "road" or (a == "cl_field" and "field" or nil)
        if a == "cl_toggle" then view = self:claasView(v) == "road" and "field" or "road" end
        self:claasSetView(v, view)
        self.page = "home"
    elseif a:sub(1, 5) == "hsub_" then self.homeSub = a:sub(6)    -- (03/11) colonne de droite de l'accueil : seul le bloc 4 change
    elseif a == "prev" then self:pageStep(-1)
    elseif a == "next" then self:pageStep(1)
    elseif a == "close" then self:setOpen(false)
    elseif a == "job1" and d ~= nil then d.cnt.active = 1
    elseif a == "job2" and d ~= nil then d.cnt.active = 2
    elseif a == "jobnext" and d ~= nil then d.cnt.active = 3 - d.cnt.active   -- (02/11 soir) PERF2 Case : engrenage = autre compteur
    elseif a == "reset" and d ~= nil then
        -- (04/11 nuit) nouvelle tâche : compteurs à zéro, la tâche garde son champ et son filtre
        local old = d.cnt.jobs[d.cnt.active] or {}
        local n = newCounter(); n.field, n.flt = old.field, old.flt
        d.cnt.jobs[d.cnt.active] = n
    elseif a == "rearcam" then s.rearCam = (s.rearCam == false); self:saveSettings()   -- (03/11 soir) caméra arrière marche / arrêt
    elseif a == "size-" then s.size = clamp(s.size - 5, 40, 150); self:saveSettings()
    elseif a == "size+" then s.size = clamp(s.size + 5, 40, 150); self:saveSettings()
    elseif a == "res-" then s.fuelReserve = clamp(s.fuelReserve - 5, 0, 50); self:saveSettings()
    elseif a == "res+" then s.fuelReserve = clamp(s.fuelReserve + 5, 0, 50); self:saveSettings()
    elseif a == "show" then s.show = s.show % 3 + 1; self:saveSettings()
    elseif a == "touchStopped" then s.touchStopped = not s.touchStopped; self:saveSettings()
    elseif a == "beeps" then s.beeps = not s.beeps; self:saveSettings()
    elseif a == "cpHudBlock" then s.cpHudBlock = s.cpHudBlock == false; self:saveSettings()
    elseif a == "fpHudHide" then
        s.fpHudHide = s.fpHudHide == false
        self:saveSettings()
        if not s.fpHudHide and AS_TerminalFp ~= nil and AS_TerminalFp.edit ~= nil then AS_TerminalFp.edit = nil end
    elseif a == "theme" then
        s.theme = (s.theme or 3) % 3 + 1
        applyTheme(s.theme)
        self:saveSettings()
        if AS_TerminalTablet ~= nil then AS_TerminalTablet.textTimer = AS_TerminalTablet.SCREEN_MS end
    elseif a == "resetPos" and self.panel ~= nil then
        self.positions[posKey(self.panel.vehicle, self.panel.inside)] = nil
        self:saveSettings()
    elseif a == "resetSize" then s.size = 70; self:saveSettings()
    elseif a == "setSub" then
        self.setSub = self.setSub ~= "tab" and "tab" or nil
    elseif a == "setHome" then
        self.setSub = self.setSub ~= "home" and "home" or nil
    elseif a:sub(1, 3) == "hm_" and self.panel ~= nil then
        -- (01/11) tuile de l'accueil : Auto -> Toujours -> Jamais -> Auto, gardé par modèle
        local v = self.panel.vehicle
        local id = a:sub(4)
        local key = AS_TerminalTablet ~= nil and AS_TerminalTablet.modelKeyOf(v) or tostring(v.configFileName)
        local p = self.positions[key] or { x = 0, y = 0, z = 0, name = vehicleName(v) }
        local t = self.parseTiles(p.tiles)
        t[id] = ((t[id] or 0) + 1) % 3
        p.tiles = self.writeTiles(t)
        self.positions[key] = p
        self.homeCache = nil
        self:saveSettings()
    elseif a == "display" then
        s.display = (s.display or 1) % 3 + 1
        self:saveSettings()
        if AS_TerminalTablet ~= nil and self.panel ~= nil then AS_TerminalTablet:replace(self.panel.vehicle) end
    elseif (a == "ext2" or a == "ext3") and self.panel ~= nil and AS_TerminalTablet ~= nil then
        -- (01/11, étape 37) écran suivant pour le 2e / 3e écran : seulement les écrans libres, puis aucun
        local v = self.panel.vehicle
        local slot = tonumber(a:sub(4))
        local tb = AS_TerminalTablet.tablets[v]
        if tb ~= nil and tb.failed == nil then
            if tb.allScreens == nil then
                AS_TerminalTablet.scanAsked = true
                AS_TerminalTablet:replace(v, true)
            end
            local n = tb.allScreens ~= nil and #tb.allScreens or 0
            local key = AS_TerminalTablet.extKeyOf(v)
            local p = self.positions[key] or { x = 0, y = 0, name = vehicleName(v) }
            local used = AS_TerminalTablet:usedScreens(v, slot)
            local cur = p["scr" .. slot] or 0
            local nxt = cur
            for _ = 1, n + 1 do
                nxt = (nxt + 1) % (n + 1)
                if nxt == 0 or not used[nxt] then break end
            end
            p["scr" .. slot] = n > 0 and nxt or 0
            self.positions[key] = p
            self:saveSettings()
            AS_TerminalTablet:replace(v, true)
        end
    elseif a == "vehNext" and self.panel ~= nil and AS_TerminalTablet ~= nil then
        -- (31/10 soir) écran du véhicule suivant (cabines à plusieurs écrans), gardé par modèle
        local v = self.panel.vehicle
        local tb = AS_TerminalTablet.tablets[v]
        if tb ~= nil and tb.vehList ~= nil and #tb.vehList > 0 then
            local key = AS_TerminalTablet.modelKeyOf(v)
            local p = self.positions[key] or { x = 0, y = 0, z = 0, name = vehicleName(v) }
            -- 1 … n, puis 0 = aucun (tablette pour ce modèle), puis 1 ; (étape 37) sans les écrans pris par le 2e / 3e
            local used = AS_TerminalTablet:usedScreens(v, 1)
            local nxt = tb.vehIdx or 1
            for _ = 1, #tb.vehList + 1 do
                nxt = (nxt + 1) % (#tb.vehList + 1)
                if nxt == 0 or not used[nxt] then break end
            end
            p.scr = nxt
            self.positions[key] = p
            self:saveSettings()
            AS_TerminalTablet:replace(v, true)
        end
    elseif a == "vehOri" and self.panel ~= nil and AS_TerminalTablet ~= nil then
        -- (31/10 soir) dans le plan de l'écran d'origine (1) ou tourné vers la tête (2), gardé par modèle
        local v = self.panel.vehicle
        local key = AS_TerminalTablet.modelKeyOf(v)
        local p = self.positions[key] or { x = 0, y = 0, z = 0, name = vehicleName(v) }
        p.ori = (p.ori or 1) % 2 + 1
        self.positions[key] = p
        self:saveSettings()
        AS_TerminalTablet:replace(v, true)
    elseif a:match("^v[whr][%+%-]$") ~= nil and self.panel ~= nil and AS_TerminalTablet ~= nil then
        -- (31/10 soir) largeur / hauteur (60 à 140 %, par 2 %) et rotation (±20°, par 1°) de la page sur l'écran du véhicule
        local v = self.panel.vehicle
        local key = AS_TerminalTablet.modelKeyOf(v)
        local p = self.positions[key] or { x = 0, y = 0, z = 0, name = vehicleName(v) }
        local plus = a:sub(3, 3) == "+"
        local axis = a:sub(2, 2)
        local dft = AS_TerminalTablet.screenDefault ~= nil and AS_TerminalTablet:screenDefault(v) or nil
        if dft ~= nil then p.sw, p.sh = p.sw or dft.sw, p.sh or dft.sh end
        if axis == "w" then p.sw = math.max(60, math.min(140, (p.sw or 100) + (plus and 2 or -2)))
        elseif axis == "h" then p.sh = math.max(60, math.min(140, (p.sh or 100) + (plus and 2 or -2)))
        else p.rz = math.max(-20, math.min(20, (p.rz or 0) + (plus and 1 or -1))) end
        self.positions[key] = p
        self:saveSettings()
        AS_TerminalTablet:replace(v, true)
    elseif a == "tabPreset" then
        s.tabPreset = (s.tabPreset or 1) % 2 + 1
        self:saveSettings()
        if AS_TerminalTablet ~= nil and self.panel ~= nil then AS_TerminalTablet:replace(self.panel.vehicle) end
    elseif a == "screen3d" then
        s.screen3d = s.screen3d == false
        self:saveSettings()
    elseif a == "tablet" then
        s.tablet = not s.tablet
        if not s.tablet and AS_TerminalTablet ~= nil then AS_TerminalTablet:removeAll() end
        self:saveSettings()
    elseif a:match("^t[sxyzpr][%+%-]$") ~= nil and self.panel ~= nil and AS_TerminalTablet ~= nil then
        -- tx / ty / tz : position (1 cm), ts : taille, tp / tr : inclinaison
        local v = self.panel.vehicle
        local key = AS_TerminalTablet.modelKeyOf(v)
        local p = self.positions[key] or { x = 0, y = 0, z = 0, name = vehicleName(v) }
        local plus = a:sub(3, 3) == "+"
        local axis = a:sub(2, 2)
        if axis == "s" then
            -- taille : 50 à 150 % de la tablette de base (22 x 13 cm), par 5 %
            p.s = math.max(50, math.min(150, (p.s or 100) + (plus and 5 or -5)))
        elseif axis == "p" or axis == "r" then
            -- inclinaison haut / bas (p) et gauche / droite (r), par 5°
            local k = axis == "p" and "rx" or "ry"
            p[k] = math.max(-45, math.min(45, (p[k] or 0) + (plus and 5 or -5)))
        else
            -- position au centimètre
            p[axis] = math.max(-0.6, math.min(0.6, (p[axis] or 0) + (plus and 0.01 or -0.01)))
        end
        self.positions[key] = p
        AS_TerminalTablet:replace(v, true)
        self:saveSettings()
    end
    -- commandes du véhicule (étape 4)
    local v = self.panel ~= nil and self.panel.vehicle or (d ~= nil and d.vehicle or nil)
    if v == nil then return end
    if a == "stop" then self:cmdStop(v)
    elseif a == "hlock_f" or a == "hlock_r" then   -- (03/11) verrou du relevage AV / AR
        local p = self:vehPrefs(v, true)
        local f = a == "hlock_f" and "lockF" or "lockR"
        p[f] = (p[f] == 0) and 1 or 0   -- (21:00) 0 = déverrouillé (non actif), sinon actif
        self:saveSettings()
    elseif a:sub(1, 5) == "colc_" then   -- (06/11) case i de la colonne de gauche (ou « + ») : ouvre / ferme sa liste
        local i = tonumber(a:sub(6)) or 1
        if self.colMenu ~= nil and self.colMenu.i == i then self.colMenu = nil else self.colMenu = { i = i } end
    elseif a:sub(1, 5) == "cols_" then   -- choix dans la liste (Aucun = case enlevée, les suivantes remontent)
        local i, key = a:match("^cols_(%d+)_([%w]+)$")
        if i ~= nil then self:caseColSet(tonumber(i), key) end
        self.colMenu = nil
    elseif a:sub(1, 4) == "rfn_" then   -- (03/11) case k de la télécommande i : ouvre / ferme son menu déroulant
        local i, k = a:match("^rfn_(%d+)_(%d+)$")
        i, k = tonumber(i) or 1, tonumber(k) or 1
        local m = self.remoteMenu
        if m ~= nil and m.i == i and m.k == k then self.remoteMenu = nil else self.remoteMenu = { i = i, k = k } end
    elseif a:sub(1, 5) == "rsel_" then   -- choix dans le menu déroulant (Aucun = case libérée)
        local i, k, fn = a:match("^rsel_(%d+)_(%d+)_([%a_@]+)$")
        i, k = tonumber(i) or 1, tonumber(k) or 1
        local rem = self:remoteFns(v)
        local fns = rem[i]
        if fn == "none" then
            if fns[k] ~= nil then table.remove(fns, k) end
        elseif k <= #fns then fns[k] = fn
        elseif #fns < self.REMOTE_SLOTS then fns[#fns + 1] = fn end
        self.remoteMenu = nil
        self:remoteStore(v, rem)
    elseif a:sub(1, 4) == "rem_" then   -- bouton de la télécommande (colonne de gauche ou APPLIQUER) = ses états voulus
        self:remoteRun(v, tonumber(a:sub(5)) or 1)
        self.lastRead = -100000   -- l'état affiché (point, cases) suit tout de suite
    elseif a == "lift" then self:cmdLift(v)
    elseif a == "lift_up" then self:cmdLift(v, false)   -- (02/11 soir) flèche haut = tout relever
    elseif a == "lift_dn" then self:cmdLift(v, true)    -- flèche bas = tout baisser
    elseif a == "hitch_f" or a == "hitch_r" then self:cmdHitch(v, a == "hitch_f")
    elseif a == "on" then if self:cmdTurnOn(v) == 0 then warn(T("noTurnOn")) end
    elseif a == "fold" then self:cmdFold(v)
    elseif a == "help" then
        -- (02/11) « ? » = menu aide du jeu (page Aide du menu en jeu)
        local okH, errH = pcall(function()
            if g_gui ~= nil and g_gui.showGui ~= nil then g_gui:showGui("InGameMenu") end
            if g_inGameMenu ~= nil and g_inGameMenu.goToPage ~= nil and g_inGameMenu.pageHelpLine ~= nil then g_inGameMenu:goToPage(g_inGameMenu.pageHelpLine) end
        end)
        if not okH then log("ERREUR menu aide : %s", tostring(errH)) end
    elseif a == "guide" then
        -- (01/11) GUIDAGE ouvre la page GPS (écran de travail), la page Courseplay sert de secours
        self.page = AS_TerminalGps ~= nil and "gps" or "cp"
        if AS_TerminalGps ~= nil then AS_TerminalGps.sub = nil end
    elseif a:sub(1, 4) == "gps_" then
        if AS_TerminalGps ~= nil then
            local okG, errG = pcall(AS_TerminalGps.action, AS_TerminalGps, self, v, a)
            if not okG then log("ERREUR commande GPS %s : %s", a, tostring(errG)) end
        end
    elseif a:sub(1, 2) == "l_" then self:cmdLight(v, a:sub(3))
    elseif a == "diffMode" then if AS_Diff ~= nil and AS_Diff.onModeAction ~= nil then AS_Diff:onModeAction(); self.lastRead = -100000 end
    elseif a == "adStartStop" then self:cmdAd(v)
    elseif a:sub(1, 3) == "fp_" then
        if AS_TerminalFp ~= nil then
            local okF, errF = pcall(AS_TerminalFp.action, AS_TerminalFp, self, v, a)
            if not okF then log("ERREUR commande FarmPilot %s : %s", a, tostring(errF)) end
        end
    elseif a:sub(1, 3) == "rh_" then if AS_TerminalMachine ~= nil then AS_TerminalMachine:rhAction(v, a) end
    elseif a:sub(1, 7) == "cc_sel_" then local p = a:sub(8); self.ccSel = (p ~= self.ccSel) and p or nil
    elseif a == "cc_close" then self.ccSel = nil
    elseif a == "cc_none" then
    elseif a == "tipper" then self:cmdTip(v)
    elseif a == "tipSide" then self:cmdTipSide(v)
    elseif a == "cover" then self:cmdCover(v)
    elseif a == "m_lift" then if AS_TerminalMachine ~= nil then AS_TerminalMachine:cmdSelfLift(v) end
    elseif a == "pipe" then if AS_TerminalMachine ~= nil then AS_TerminalMachine:cmdPipe(v) end
    elseif a == "m_swath" then if AS_TerminalMachine ~= nil and AS_TerminalMachine.cmdSwath ~= nil then AS_TerminalMachine:cmdSwath(v) end
    elseif a:sub(1, 2) == "t_" or a:sub(1, 5) == "tool_" then
        if AS_TerminalTools ~= nil then
            local okT, errT = pcall(AS_TerminalTools.action, AS_TerminalTools, self, v, a)
            if not okT then log("ERREUR commande outil %s : %s", a, tostring(errT)) end
        end
    elseif a == "cp_find" then if AS_TerminalCourses ~= nil then AS_TerminalCourses:find(v, d) end
    elseif a == "cp_saves" then self:cmdCp(v, "manager")   -- (03/11 22:42) gestionnaire des courses de Courseplay
    elseif a:sub(1, 7) == "cp_load" then if AS_TerminalCourses ~= nil then AS_TerminalCourses:load(v, tonumber(a:sub(8))) end
    elseif a:sub(1, 3) == "cp_" then self:cmdCp(v, a:sub(4))
    end
end

function AS_Terminal:mouseEvent(posX, posY, isDown, isUp, button)
    -- (01/11) molette de la souris : fait défiler le menu déroulant FarmPilot ouvert
    if isDown and AS_TerminalFp ~= nil and AS_TerminalFp.drop ~= nil
        and (button == (Input.MOUSE_BUTTON_WHEEL_UP or 4) or button == (Input.MOUSE_BUTTON_WHEEL_DOWN or 5))
        and (self.panel ~= nil or self.panel3d ~= nil)
        and g_inputBinding ~= nil and g_inputBinding.getShowMouseCursor ~= nil and g_inputBinding:getShowMouseCursor() == true then
        local step = button == (Input.MOUSE_BUTTON_WHEEL_UP or 4) and -1 or 1
        AS_TerminalFp.dropTop = math.max(1, (AS_TerminalFp.dropTop or 1) + step)
        if AS_TerminalTablet ~= nil then AS_TerminalTablet.textTimer = AS_TerminalTablet.SCREEN_MS end
        return
    end
    -- (31/10) écran 3D de la tablette : clic projeté sur les boutons construits en 3D
    local bigOpen = self.panel ~= nil and not self.panel.onTablet
    if self.panel3d ~= nil and AS_TerminalTablet ~= nil and (self.panel == nil
        or (bigOpen and isDown and not self.dragging and not inBox(self.panel, posX, posY) and not inBox(self:bezelBox(), posX, posY))) then
        if not (isDown and button == Input.MOUSE_BUTTON_LEFT) then return end
        local keepPanel = self.panel
        if g_inputBinding == nil or g_inputBinding.getShowMouseCursor == nil
            or g_inputBinding:getShowMouseCursor() ~= true then return end
        if self.settings.touchStopped and self.data ~= nil and math.abs(self.data.speed or 0) > 1 then
            log("clic tablette ignoré : tactile seulement à l'arrêt (%.1f km/h)", self.data.speed or 0); self:touchNotice()
            return
        end
        local okH, action, onScreen, onHeader, hitTab = pcall(AS_TerminalTablet.hit, AS_TerminalTablet, self.panel3d, posX, posY)
        if not okH then log("ERREUR clic tablette : %s", tostring(action)) return end
        if action ~= nil or onScreen then
            log("clic tablette page %s : %s", tostring(self.page), tostring(action or "écran"))
        end
        if action ~= nil then
            self.panel = { vehicle = self.panel3d, inside = true, onTablet = true }
            local ok, err = self:withTab(hitTab, self.doAction, self, action)
            if not ok then log("ERREUR bouton %s : %s", tostring(action), tostring(err)) end
            self.panel = keepPanel
            AS_TerminalTablet.textTimer = AS_TerminalTablet.SCREEN_MS     -- écran 3D mis à jour tout de suite
        elseif onHeader then
            -- (31/10 soir) seul le bandeau du haut ouvre la grande fenêtre (ou Ctrl droit + T)
            self:setOpen(true)
        end
        return
    end
    if self.panel == nil then
        self.dragging = false
        return
    end
    if g_inputBinding == nil or g_inputBinding.getShowMouseCursor == nil
        or g_inputBinding:getShowMouseCursor() ~= true then
        self.dragging, self.hover = false, nil
        return
    end
    local p = self.panel
    if self.dragging then
        self.dragPos = { x = clamp(posX - self.dragDX, 0, 1 - p.w), y = clamp(posY - self.dragDY, 0, 1 - p.h) }
        if isUp then
            self.dragging = false
            local v = p.vehicle
            self.positions[posKey(v, p.inside)] = { x = self.dragPos.x, y = self.dragPos.y, name = vehicleName(v) }
            self.dragPos = nil
            self:saveSettings()
        end
        return
    end
    self.hover = nil
    -- (étape 37) la case dessinée en dernier (au-dessus) gagne, comme sur l'écran 3D
    for i = #self.boxes, 1, -1 do
        local b = self.boxes[i]
        if inBox(b, posX, posY) then self.hover = b.action break end
    end
    if not (isDown and button == Input.MOUSE_BUTTON_LEFT) then return end
    if not inBox(p, posX, posY) then
        if inBox(self:bezelBox(), posX, posY) then
            self.dragging = true
            self.dragDX, self.dragDY = posX - p.x, posY - p.y
            self.dragPos = { x = p.x, y = p.y }
        end
        return
    end
    -- (réglage) écran tactile seulement à l'arrêt
    if self.settings.touchStopped and self.data ~= nil and math.abs(self.data.speed or 0) > 1 then
        log("clic ignoré : tactile seulement à l'arrêt (%.1f km/h)", self.data.speed or 0); self:touchNotice()
        return
    end
    log("clic fenêtre page %s : %s", tostring(self.page), tostring(self.hover or "aucun bouton"))
    if self.hover ~= nil then
        local tabObj = (p.onTablet and AS_TerminalTablet ~= nil) and AS_TerminalTablet.tablets[p.vehicle] or nil
        if tabObj ~= nil and tabObj.failed ~= nil then tabObj = nil end
        local ok, err = self:withTab(tabObj, self.doAction, self, self.hover)
        if not ok then log("ERREUR bouton %s : %s", tostring(self.hover), tostring(err)) end
        self.lastRead = -100000
        if AS_TerminalTablet ~= nil then AS_TerminalTablet.textTimer = AS_TerminalTablet.SCREEN_MS end   -- (70m) écran 3D aussi, tout de suite
        return
    end
    if p.onTablet then
        if inBox(self.headerBox, posX, posY) then self:setOpen(true) end
        return
    end
    if inBox(self.headerBox, posX, posY) then
        self.dragging = true
        self.dragDX, self.dragDY = posX - p.x, posY - p.y
        self.dragPos = { x = p.x, y = p.y }
    end
end

-------------------------------------------------------------------------------
-- Touches : Ctrl droit + T (afficher), Ctrl droit + Y (mode tactile)
-------------------------------------------------------------------------------
function AS_Terminal:setTouch(on)
    if on == self.touch then return end
    self.touch = on
    if g_inputBinding == nil or g_inputBinding.setShowMouseCursor == nil then return end
    if on then
        self.cursorBefore = g_inputBinding.getShowMouseCursor ~= nil and g_inputBinding:getShowMouseCursor() == true
        if not self.cursorBefore then pcall(g_inputBinding.setShowMouseCursor, g_inputBinding, true) end
    elseif self.cursorBefore == false then
        pcall(g_inputBinding.setShowMouseCursor, g_inputBinding, false)
    end
end

function AS_Terminal:setOpen(open)
    if open == self.isOpen then return end
    if not open and debug ~= nil and debug.getinfo ~= nil then
        local okI, inf = pcall(debug.getinfo, 2, "Sl")
        if okI and inf ~= nil then log("grande fenêtre fermée (%s:%s)", tostring(inf.short_src), tostring(inf.currentline)) end
    end
    self.isOpen = open
    self.data, self.hover, self.dragging = nil, nil, false
    if not open then self:setTouch(false) end
end

function AS_Terminal.onToggle()
    AS_Terminal:setOpen(not AS_Terminal.isOpen)
end

function AS_Terminal.onTouch()
    -- terminal sur la tablette (vue cabine) : le curseur suffit, on touche l'écran de la tablette
    local onTablet = (AS_Terminal.panel ~= nil and AS_Terminal.panel.onTablet) or AS_Terminal.panel3d ~= nil
    if not AS_Terminal.isOpen and not onTablet then AS_Terminal:setOpen(true) end
    AS_Terminal:setTouch(not AS_Terminal.touch)
end

local function registerKeys()
    if InputAction == nil then return end
    for _, a in ipairs({ { "AS_TERMINAL", AS_Terminal.onToggle }, { "AS_TERMINAL_TOUCH", AS_Terminal.onTouch } }) do
        if InputAction[a[1]] ~= nil then
            local _, id = g_inputBinding:registerActionEvent(InputAction[a[1]], AS_Terminal, a[2], false, true, false, true)
            if id ~= nil then
                g_inputBinding:setActionEventText(id, L("input_" .. a[1]))
                g_inputBinding:setActionEventTextVisibility(id, false)
            end
        end
    end
    -- (04/11) touches de fonction de l'accoudoir (Claas CEBIS) : Fonction affectée
    for k = 1, AS_Terminal.FK_KEYS do
        local name = "AS_FKEY" .. k
        if InputAction[name] ~= nil then
            local _, id = g_inputBinding:registerActionEvent(InputAction[name], AS_Terminal, AS_Terminal.onFKey, false, true, false, true, k)
            if id ~= nil then
                g_inputBinding:setActionEventText(id, L("input_" .. name))
                g_inputBinding:setActionEventTextVisibility(id, false)
            end
        end
    end
end

if Drivable ~= nil and Drivable.onRegisterActionEvents ~= nil then
    Drivable.onRegisterActionEvents = Utils.appendedFunction(Drivable.onRegisterActionEvents, function(self, isActiveForInput, isActiveForInputIgnoreSelection)
        if not self.isClient or not isActiveForInputIgnoreSelection then return end
        registerKeys()
    end)
end

-------------------------------------------------------------------------------
-- Cycle de vie
-------------------------------------------------------------------------------
-------------------------------------------------------------------------------
-- (01/11) cadre Courseplay (HUD jaune) bloqué sur les véhicules qui ont le terminal AutoSwitch
-- (réglage « Bloquer le cadre Courseplay ») : le clic droit n'affiche que la souris (pour toucher
-- la tablette), la touche du cadre est sans effet, et le cadre ne se rouvre pas en montant.
-- Le grand menu Courseplay (bouton MENU COURSEPLAY du terminal) reste.
-------------------------------------------------------------------------------
-- (01/11) véhicule équipé du terminal AutoSwitch (tablette ou écran du véhicule)
function AS_Terminal:hasTerminal(v)
    if not self.ENABLED or v == nil then return false end
    local tb = AS_TerminalTablet
    if tb == nil or not tb.ENABLED or not self.settings.tablet or tb.template == false then return false end
    local ok, no = pcall(tb.noTabletFor, tb, v)
    return ok and no == false
end

function AS_Terminal:cpHudBlocked(v)
    if not self.ENABLED or self.settings.cpHudBlock == false then return false end
    if v == nil or v.spec_cpHud == nil or v.spec_cpHud.hud == nil then return false end
    return self:hasTerminal(v)
end

local function closeCpHud(v)
    local hud = v.spec_cpHud ~= nil and v.spec_cpHud.hud or nil
    if hud ~= nil and hud.getIsOpen ~= nil and hud:getIsOpen() then hud:openClose(false) end
end

-- clic droit sur un véhicule bloqué : souris affichée / cachée, sans le cadre
function AS_Terminal:cpMouseOnly(v, inputValue)
    if g_inputBinding == nil then return end
    local cu = cpGlobal("CpUtil")
    if cu ~= nil and cu.getCurrentVehicle ~= nil and v ~= cu.getCurrentVehicle() then return end
    -- AutoDrive : son éditeur garde la souris (comme Courseplay)
    local gcp = cpGlobal("g_Courseplay")
    if inputValue ~= nil and gcp ~= nil and gcp.autoDrive ~= nil and gcp.autoDrive.getSetting ~= nil then
        local okA, shown = pcall(gcp.autoDrive.getSetting, "showHUD")
        local hiddenFp = AS_TerminalFp ~= nil and AS_TerminalFp:blockNow(v)
        if okA and shown and not hiddenFp and g_inputBinding:getShowMouseCursor() then return end
    end
    local show = not g_inputBinding:getShowMouseCursor()
    g_inputBinding:setShowMouseCursor(show)
    local gu = cpGlobal("CpGuiUtil")
    if gu ~= nil and gu.setCameraRotation ~= nil then
        pcall(gu.setCameraRotation, v, not show, v.spec_cpHud.savedCameraRotatableInfo)
    end
    closeCpHud(v)
end

function AS_Terminal:hookCpHud()
    if self.cpHudHooked then return end
    local H = cpGlobal("CpHud")
    if H == nil or type(H.actionEventMouse) ~= "function" or type(H.openClose) ~= "function" then return end
    self.cpHudHooked = true
    local term = self
    local origMouse, origOpen, origEnter = H.actionEventMouse, H.openClose, H.onEnterVehicle
    H.actionEventMouse = function(v, actionName, inputValue, ...)
        local okB, blocked = pcall(term.cpHudBlocked, term, v)
        if okB and blocked then
            local ok, err = pcall(term.cpMouseOnly, term, v, inputValue)
            if ok then return end
            log("ERREUR souris (cadre Courseplay bloqué) : %s", tostring(err))
        end
        return origMouse(v, actionName, inputValue, ...)
    end
    H.openClose = function(v, ...)
        local okB, blocked = pcall(term.cpHudBlocked, term, v)
        if okB and blocked then
            pcall(closeCpHud, v)
            warn(T("cpHudBlocked"))
            return
        end
        return origOpen(v, ...)
    end
    if type(origEnter) == "function" then
        H.onEnterVehicle = function(v, ...)
            origEnter(v, ...)
            local okB, blocked = pcall(term.cpHudBlocked, term, v)
            if okB and blocked then pcall(closeCpHud, v) end
        end
    end
    -- touches déjà posées (on était déjà dans un véhicule) : reposées avec les nouvelles fonctions
    local v = AS.shGetControlledVehicle ~= nil and AS.shGetControlledVehicle() or nil
    if v ~= nil and v.requestActionEventUpdate ~= nil then pcall(v.requestActionEventUpdate, v) end
    log("cadre Courseplay : bloqué sur les véhicules avec le terminal (réglage « %s »)", T("cpHudBlock"))
end

function AS_Terminal:loadMap()
    pcall(self.hookCpHud, self)
    local ok, err = pcall(self.loadSettings, self)
    if not ok then log("ERREUR réglages : %s", tostring(err)) end
    ok, err = pcall(self.loadCounters, self)
    if not ok then log("ERREUR compteurs : %s", tostring(err)) end
    print("[AS_Terminal] terminal accroché (Ctrl droit + T, tactile Ctrl droit + Y)")
end

function AS_Terminal:update(dt)
    if not self.ENABLED or g_currentMission == nil then return end
    pcall(self.keepOpenThroughGui, self, g_gui ~= nil and g_gui.getIsGuiVisible ~= nil and g_gui:getIsGuiVisible() == true)
    -- (01/11) cadre Courseplay : accroché dès que Courseplay est là ; refermé s'il s'ouvre quand même
    if not self.cpHudHooked and (g_time or 0) >= (self.cpHookNext or 0) then
        self.cpHookNext = (g_time or 0) + 5000
        pcall(self.hookCpHud, self)
    end
    do
        local cv = AS.shGetControlledVehicle ~= nil and AS.shGetControlledVehicle() or nil
        if cv ~= nil and cv.spec_cpHud ~= nil and self.settings.cpHudBlock ~= false then
            local hud = cv.spec_cpHud.hud
            if hud ~= nil and hud.getIsOpen ~= nil and hud:getIsOpen() and self:cpHudBlocked(cv) then
                pcall(closeCpHud, cv)
            end
        end
    end
    self.countTimer = self.countTimer + (dt or 0)
    if self.countTimer >= self.COUNT_MS then
        local ok, err = pcall(self.updateCounters, self, self.countTimer)
        if not ok and not self.loggedCountError then
            self.loggedCountError = true
            log("ERREUR compteurs : %s", tostring(err))
        end
        self.countTimer = 0
    end
    if #self.hydQ > 0 then pcall(self.hydTick, self) end
    do   -- (04/11) Attelage CEBIS : limite de hauteur et vitesse de descente du tracteur conduit
        local cvh = AS.shGetControlledVehicle ~= nil and AS.shGetControlledVehicle() or nil
        if cvh ~= nil then pcall(self.hitchApply, self, cvh); pcall(self.ptoApply, self, cvh) end
    end   -- (04/11) délais et retours temporisés des distributeurs
    -- caméra arrière plus affichée depuis 2 s (autre page, fenêtre fermée) : libérée (plus de 2e rendu)
    if self.rearCam ~= nil and (g_time or 0) - (self.rearCam.lastUse or 0) > 2000 then self:rearCamDelete() end
    if self.isOpen then
        local v = AS.shGetControlledVehicle ~= nil and AS.shGetControlledVehicle() or nil
        -- à pied : le terminal se range (il revient en remontant dans un véhicule)
        if v == nil and self.touch then self:setTouch(false) end
        pcall(self.checkAlarms, self)
    end
end

function AS_Terminal:deleteMap()
    self:rearCamDelete()
    if self.frameOv then pcall(delete, self.frameOv) end
    self.frameOv = nil
    for _, o in pairs(self.frameCellOvs or {}) do if o then pcall(delete, o) end end
    self.frameCellOvs = nil
    for _, o in pairs(self.brandOvs or {}) do if o then pcall(delete, o) end end
    self.brandOvs = nil
    if AS_TerminalTools ~= nil then pcall(AS_TerminalTools.deleteMap, AS_TerminalTools) end
    self.isOpen, self.touch, self.data = false, false, nil
    self.counters, self.alarm, self.boxes = {}, {}, {}
end

-- (31/10) outils partagés avec l'onglet machine (TerminalMachine.lua)
AS_Terminal.ui = { call = call, T = T, C = C, row = row, bar = bar, sideButton = sideButton, trainOf = trainOf,
    workWidth = workWidth, isLowered = isLowered, isTurnedOn = isTurnedOn, fillTypeTitle = fillTypeTitle,
    vehicleName = vehicleName, warn = warn, cpGlobal = cpGlobal, hasCp = hasCp, fieldAt = fieldAt, fieldNumber = fieldNumber,
    isWorking = isWorking, ownLowerKind = ownLowerKind, jointLowers = jointLowers, hitches = hitches,
    brandName = brandName, hasAd = hasAd, isFarmPilot = isFarmPilot, adGlobal = adGlobal,
    cpInstalled = cpInstalled, fpInstalled = fpInstalled }

if addConsoleCommand ~= nil then
    addConsoleCommand("asRearCam", "Terminal : caméra arrière (x y z pitch yaw fov <valeur>)", "consoleRearCam", AS_Terminal)
end
addModEventListener(AS_Terminal)

-- (04/11) aides du terminal pour TerminalMassey.lua (fonctions locales de ce fichier)
AS_Terminal.MFH = { T = T, caseImg = caseImg, fmtClock = fmtClock, unitsOf = unitsOf, caseHitches = caseHitches, hitchPct = hitchPct,
    vehicleName = vehicleName }
