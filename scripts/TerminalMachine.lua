-------------------------------------------------------------------------------
-- AutoSwitch - Terminal : onglet OUTIL selon la machine (31/10)
--   épandeur / pulvé / semoir, moissonneuse, ensileuse, récolteuse (betteraves,
--   pommes de terre, coton...). Infos du jeu + Realistic Harvesting (RHM_Api,
--   interface publique en lecture seule) quand il est chargé.
-------------------------------------------------------------------------------
AS_TerminalMachine = {}
AS_TerminalMachine.hist = setmetatable({}, { __mode = "k" })   -- [objet] = { t, level } (débit hors RH)

local function log(fmt, ...)
    (AS.rawPrint or print)("[AS_TerminalMachine] " .. string.format(fmt, ...))
end

local U = function() return AS_Terminal.ui end

local function call(obj, name, ...)
    return U().call(obj, name, ...)
end

-- Realistic Harvesting : globale RHM_Api (posée par le mod dans l'environnement global)
local function rhm()
    local api = rawget(_G, "RHM_Api") or rawget(_G, "RHM_API")
    if api == nil and AS ~= nil and AS.modGlobal ~= nil then
        local ok, g = pcall(AS.modGlobal, "FS25_RealisticHarvesting", "RHM_Api")
        if ok then api = g end
    end
    return type(api) == "table" and api or nil
end
AS_TerminalMachine.rhm = rhm

local function rcall(api, name, ...)
    if api == nil or type(api[name]) ~= "function" then return nil end
    local ok, a, b, c = pcall(api[name], ...)
    if ok then return a, b, c end
    return nil
end

-------------------------------------------------------------------------------
-- type de machine
-------------------------------------------------------------------------------
local ROOT_WORDS = { "POTATO", "BEET", "CARROT", "PARSNIP", "ONION", "GARLIC", "SPINACH", "GREENBEAN", "GREEN_BEAN",
    "SUGARCANE", "CABBAGE", "PEA", "COTTON", "GRAPE", "OLIVE", "LETTUCE", "RED" }

local function storeCategory(o)
    if g_storeManager == nil or o.configFileName == nil then return "" end
    local ok, item = pcall(g_storeManager.getItemByXMLFilename, g_storeManager, o.configFileName)
    if ok and item ~= nil and item.categoryName ~= nil then return tostring(item.categoryName):lower() end
    return ""
end

local function harvesterKind(o)
    local cat = storeCategory(o)
    local typeName = tostring(o.typeName or (o.type and o.type.name) or ""):lower()
    if cat:find("forage") or typeName:find("forage") or o.spec_forageHarvester ~= nil then return "forage" end
    if cat == "combines" or cat == "combinevehicles" or cat == "harvesters" then return "combine" end
    if cat:find("beet") or cat:find("potato") or cat:find("vegetable") or cat:find("cotton") or cat:find("sugarcane")
        or cat:find("grape") or cat:find("olive") or cat:find("pea") or cat:find("greenbean") or cat:find("spinach")
        or o.spec_fruitPreparer ~= nil then return "root" end
    -- sinon : d'après ce que la trémie accepte
    local sc = o.spec_combine
    local fu = sc ~= nil and sc.fillUnitIndex ~= nil and call(o, "getFillUnitSupportedFillTypes", sc.fillUnitIndex) or nil
    if type(fu) == "table" and g_fillTypeManager ~= nil then
        for ft, ok in pairs(fu) do
            if ok then
                local f = g_fillTypeManager:getFillTypeByIndex(ft)
                local n = f ~= nil and tostring(f.name or ""):upper() or ""
                for _, w in ipairs(ROOT_WORDS) do
                    if n:find(w, 1, true) and n ~= "WHEAT" then return "root" end
                end
            end
        end
    end
    return "combine"
end

-- machine « qui récolte » du train (la machine elle-même ou une récolteuse traînée), sinon épandeur
function AS_TerminalMachine:detect(v, train)
    for _, o in ipairs(train) do
        if o.spec_combine ~= nil then
            local k = harvesterKind(o)
            local api = rhm()
            local mt = api ~= nil and rcall(api, "getMachineType", o) or nil
            if mt == "forage" then k = "forage" elseif mt == "root" or mt == "cotton" or mt == "grape" or mt == "olive" then k = "root"
            elseif mt == "grain" then k = "combine" end
            return k, o
        end
    end
    -- outil attelé d'abord, puis le véhicule lui-même (pulvé / épandeur automoteur)
    for _, o in ipairs(train) do
        if o ~= v and o.spec_sprayer ~= nil then return "spreader", o end
    end
    if v.spec_sprayer ~= nil then return "spreader", v end
    return nil
end

-------------------------------------------------------------------------------
-- lecture
-------------------------------------------------------------------------------
local function fillInfo(o, idx)
    if idx == nil then return nil end
    local cap = call(o, "getFillUnitCapacity", idx) or 0
    if cap <= 0 then return nil end
    local lvl = call(o, "getFillUnitFillLevel", idx) or 0
    local ft = call(o, "getFillUnitFillType", idx)
    return { level = lvl, cap = cap, ft = ft, title = U().fillTypeTitle(ft) }
end

local function massPerLiter(ft)
    if ft == nil or g_fillTypeManager == nil then return nil end
    local f = g_fillTypeManager:getFillTypeByIndex(ft)
    return f ~= nil and tonumber(f.massPerLiter) or nil     -- tonnes par litre
end

-- débit mesuré sur la trémie (l/h), lissé, quand Realistic Harvesting n'est pas là
function AS_TerminalMachine:rate(o, lvl)
    local now = g_time or 0
    local h = self.hist[o]
    if h == nil or lvl < h.level - 1 then
        self.hist[o] = { t = now, level = lvl, lph = 0 }
        return 0
    end
    local dt = now - h.t
    if dt >= 2000 then
        local lph = (lvl - h.level) / dt * 3600000
        h.lph = h.lph * 0.5 + math.max(0, lph) * 0.5
        h.t, h.level = now, lvl
    end
    return h.lph
end

-- objet sous la goulotte (remorque) : remplissage
local function dischargeTarget(o)
    local dn = call(o, "getCurrentDischargeNode")
    if type(dn) ~= "table" then return nil, nil end
    local side
    if dn.node ~= nil and o.rootNode ~= nil then
        local ok, x = pcall(localToLocal, dn.node, o.rootNode, 0, 0, 0)
        if ok and x ~= nil and math.abs(x) > 0.8 then side = x > 0 and "L" or "R" end
    end
    local obj, idx = dn.dischargeObject, dn.dischargeFillUnitIndex
    if type(obj) ~= "table" or idx == nil then return nil, side end
    local cap = call(obj, "getFillUnitCapacity", idx) or 0
    if cap <= 0 then return nil, side end
    return { level = call(obj, "getFillUnitFillLevel", idx) or 0, cap = cap, name = U().vehicleName(obj) }, side
end

local function pipeState(o)
    local sp = o.spec_pipe
    if sp == nil or sp.numStates == nil or sp.numStates < 2 then return nil end
    return (sp.targetState or sp.currentState or 1) ~= 1
end

-- épandeur : produit, cuve, dose (l/ha ou kg/ha), largeur, surface restante
local function readSpreader(m, o)
    local sp = o.spec_sprayer
    m.selfProp = o.spec_motorized ~= nil
    local idx = call(o, "getSprayerFillUnitIndex") or (sp ~= nil and sp.fillUnitIndex) or 1
    m.fill = fillInfo(o, idx)
    m.width = U().workWidth(o)
    m.on = U().isTurnedOn(o)
    m.lowered = U().isLowered(o)
    local ft = m.fill ~= nil and m.fill.ft or nil
    if ft ~= nil and o.getSprayerUsage ~= nil then
        -- litres sur 1 s à la vitesse de travail, rapportés à la surface couverte pendant cette seconde
        local lps = call(o, "getSprayerUsage", ft, 1000)
        local speed = tonumber(o.speedLimit) or 10
        local w = m.width or call(o, "getWorkingWidth") or nil
        if lps ~= nil and lps > 0 and w ~= nil and w > 0 and speed > 0 then
            local m2 = speed / 3.6 * w
            m.dose = lps / m2 * 10000
            local mpl = massPerLiter(ft)
            m.solid = false
            local f = g_fillTypeManager ~= nil and g_fillTypeManager:getFillTypeByIndex(ft) or nil
            if f ~= nil and f.name ~= nil then
                local n = tostring(f.name):upper()
                m.solid = n == "FERTILIZER" or n == "LIME" or n == "MANURE" or n == "SEEDS" or n == "COMPOST" or n == "DIGESTATE_SOLID"
            end
            if m.solid and mpl ~= nil then m.doseKg = m.dose * mpl * 1000 end
            if m.fill ~= nil and m.dose > 0 then m.haLeft = m.fill.level / m.dose end
        end
    end
end

-- (01/11) partagé avec la page OUTIL (TerminalTools.lua) : épandeur attelé qui n'est pas la machine principale
AS_TerminalMachine.readSpreader = readSpreader

local function readHarvester(m, o, kind)
    local sc = o.spec_combine
    m.on = U().isTurnedOn(o)
    m.tank = sc ~= nil and fillInfo(o, sc.fillUnitIndex) or nil
    -- ensileuse : réservoir tampon, pas une trémie
    if kind == "forage" and m.tank ~= nil and m.tank.cap < 2000 then m.tank = nil end
    -- coupe / bec / pick-up : premier outil du train qui coupe
    for _, c in ipairs(U().trainOf(o)) do
        if c ~= o and c.spec_cutter ~= nil then
            m.header = { name = U().vehicleName(c), width = U().workWidth(c), lowered = U().isLowered(c), on = U().isTurnedOn(c) }
            break
        end
    end
    if m.header == nil and o.spec_cutter ~= nil then
        m.header = { name = U().vehicleName(o), width = U().workWidth(o), lowered = U().isLowered(o) }
    end
    m.pipe = pipeState(o)
    m.target, m.side = dischargeTarget(o)
    -- (31/10 soir) écran d'accueil : andain / broyeur, pannes d'Advanced Damage System
    if sc ~= nil and sc.isSwathActive ~= nil then
        m.swath = sc.isSwathActive == true
        m.canSwath = o.setIsSwathActive ~= nil
    end
    local ads = o.spec_AdvancedDamageSystem
    if ads ~= nil and type(ads.components) == "table" then
        -- 2 = en panne (pièce défectueuse ou panne avancée), 1 = panne qui commence, 0 = bon
        local function lvl(id)
            local st = ads.components[id]
            if type(st) ~= "table" then return nil end
            local p = 0
            for _, b in pairs(ads.activeBreakdowns or {}) do
                if type(b) == "table" and b.componentId == id and type(b.breakdownProgress) == "number" then p = math.max(p, b.breakdownProgress) end
            end
            if st.defect == true or p >= 0.75 then return 2 end
            if p > 0 then return 1 end
            return 0
        end
        m.ads = { thresh = lvl("threshingSeparationUnit"), drive = lvl("harvestDrive"), auger = lvl("unloadingAuger"),
            chop = lvl("forageChoppingUnit"), discharge = lvl("forageDischargeUnit") }
    end
    if m.tank ~= nil then
        m.lph = AS_TerminalMachine:rate(o, m.tank.level)
        local mpl = massPerLiter(m.tank.ft)
        if mpl ~= nil then m.tph = m.lph * mpl end
    end
    -- produit récolté
    if sc ~= nil and sc.lastValidInputFruitType ~= nil and g_fruitTypeManager ~= nil then
        local fruit = g_fruitTypeManager:getFruitTypeByIndex(sc.lastValidInputFruitType)
        local ft = fruit ~= nil and (fruit.fillType ~= nil and fruit.fillType.index or nil) or nil
        if ft ~= nil then m.crop = U().fillTypeTitle(ft) end
    end
    if m.crop == nil and m.tank ~= nil and m.tank.level > 0 then m.crop = m.tank.title end

    -- Realistic Harvesting
    local api = rhm()
    if api ~= nil and rcall(api, "isRHMActive", o) then
        local r = {}
        local t = rcall(api, "getTelemetry", o) or {}
        r.load = rcall(api, "getEngineLoad", o) or t.load
        r.targetLoad = rcall(api, "getTargetEngineLoad", o)
        r.tph = rcall(api, "getTonPerHour", o) or t.tonPerHour
        r.yield = rcall(api, "getYield", o) or t.yield
        if (r.yield or 0) <= 0 then r.yield = rcall(api, "getLastValidYield", o) end
        r.hph = rcall(api, "getHectaresPerHour", o) or t.hectaresPerHour
        r.fuel = rcall(api, "getCombineFuelRate", o)
        r.moisture = rcall(api, "getMoisture", o) or t.moisture
        r.moistureLimit = rcall(api, "getMoistureLimit", o)
        r.moistureHigh = rcall(api, "isMoistureExceeded", o) == true
        r.weed = rcall(api, "getWeedRatio", o) or t.weedRatio
        r.loss = rcall(api, "getTotalCropLoss", o) or t.cropLoss
        r.lossOver = rcall(api, "getOverloadLoss", o)
        r.lossMoist = rcall(api, "getMoistureLoss", o)
        r.lossSet = rcall(api, "getSettingsLoss", o)
        r.lossWear = rcall(api, "getWearLoss", o)
        r.lossSlope = rcall(api, "getSlopeLoss", o)
        r.speed = rcall(api, "getRecommendedSpeed", o) or t.recommendedSpeed
        r.eff = rcall(api, "getSettingsEfficiency", o)
        r.mode = rcall(api, "getSettingsMode", o)
        r.settings = rcall(api, "getSettings", o)
        r.optimal = rcall(api, "getOptimalSettings", o)
        if kind == "forage" then
            r.fresh = rcall(api, "getFreshMatterThroughput", o)
            r.pickup = rcall(api, "isPickupActive", o)
            r.power = rcall(api, "getForagePowerBreakdown", o)
        end
        m.rh = r
        if r.tph ~= nil and r.tph > 0 then m.tph = r.tph end
    end
    -- temps avant trémie pleine
    if m.tank ~= nil and (m.lph or 0) > 50 then
        m.minToFull = (m.tank.cap - m.tank.level) / m.lph * 60
    elseif m.tank ~= nil and m.tph ~= nil and m.tph > 0 then
        local mpl = massPerLiter(m.tank.ft)
        if mpl ~= nil and mpl > 0 then m.minToFull = (m.tank.cap - m.tank.level) * mpl / m.tph * 60 end
    end
end

function AS_TerminalMachine:read(v, d)
    local train = U().trainOf(v)
    local kind, o = self:detect(v, train)
    if kind == nil then d.mach = nil return end
    local m = { kind = kind, obj = o, name = U().vehicleName(o) }
    if kind == "spreader" then readSpreader(m, o) else readHarvester(m, o, kind) end
    d.mach = m
end

-------------------------------------------------------------------------------
-- commandes
-------------------------------------------------------------------------------
function AS_TerminalMachine:cmdPipe(v)
    local d = AS_Terminal.data
    local o = d ~= nil and d.mach ~= nil and d.mach.obj or nil
    if o == nil or o.spec_pipe == nil then
        for _, x in ipairs(U().trainOf(v)) do if x.spec_pipe ~= nil then o = x break end end
    end
    if o == nil or o.spec_pipe == nil then U().warn(U().T("noPipe")) return end
    local sp = o.spec_pipe
    local target = (sp.targetState or 1) == 1 and 2 or 1
    if o.getIsPipeStateChangeAllowed ~= nil and call(o, "getIsPipeStateChangeAllowed", target) == false then
        U().warn(U().T("noPipe"))
        return
    end
    if o.setPipeState ~= nil then pcall(o.setPipeState, o, target) end
end

-- (31/10 soir) andain / broyeur (touche du jeu)
function AS_TerminalMachine:cmdSwath(v)
    local d = AS_Terminal.data
    local o = d ~= nil and d.mach ~= nil and d.mach.obj or nil
    if o == nil or o.spec_combine == nil or o.setIsSwathActive == nil then U().warn(U().T("noSwath")) return end
    local on = o.spec_combine.isSwathActive == true
    local ok, err = pcall(o.setIsSwathActive, o, not on)
    if not ok then log("ERREUR andain : %s", tostring(err)) else log("andain : %s", on and "broyeur" or "andain") end
    AS_Terminal.lastRead = -100000
end

-- automoteur : rampes baissées / levées (position intermédiaire du pliage, touche du jeu)
function AS_TerminalMachine:cmdSelfLift(v)
    local fn = Foldable ~= nil and Foldable.actionEventFoldMiddle or nil
    if fn == nil or v.spec_foldable == nil then return end
    local ok, err = pcall(fn, v, "", 1, nil, false)
    if not ok then log("ERREUR rampes : %s", tostring(err)) end
end

-------------------------------------------------------------------------------
-- affichage
-------------------------------------------------------------------------------
local function f1(x, unit) if x == nil then return "-" end return string.format("%.1f %s", x, unit) end
local function f0(x, unit) if x == nil then return "-" end return string.format("%d %s", math.floor(x + 0.5), unit) end
local function pct(x) if x == nil then return "-" end return string.format("%.1f %%", x) end

local function o_unf(m)
    local o = m.obj
    if o == nil or o.spec_foldable == nil or o.spec_foldable.foldingParts == nil or #o.spec_foldable.foldingParts == 0 then return nil end
    return call(o, "getIsUnfolded") == true
end

local PARAMS = { "rotor", "feeder", "fan", "upperSieve", "lowerSieve" }

function AS_TerminalMachine:draw(AS_T, d, ctx)
    local ui = U()
    local T, C, row, bar = ui.T, ui.C, ui.row, ui.bar
    local m = d.mach
    local half = (ctx.cw - 30) / 2
    local L, R = {}, {}
    if m.kind == "spreader" then
        if m.lowered ~= nil then
            ui.sideButton(ctx, 1, m.selfProp and "m_lift" or "lift", m.lowered and T("doRaise") or T("doLower"), m.lowered == true,
                m.lowered and T("lowered") or T("raised"))
        end
        ui.sideButton(ctx, 2, "on", m.on and T("doOff") or T("doOn"), m.on == true, m.on and T("on") or T("off"))
        if o_unf(m) ~= nil then
            local open = o_unf(m)
            ui.sideButton(ctx, 3, "fold", open and T("doFold") or T("doUnfold"), open, open and T("unfolded") or T("folded"))
        end
        L[#L + 1] = { T("m_machine"), m.name }
        L[#L + 1] = { T("m_product"), m.fill ~= nil and m.fill.title or "-" }
        L[#L + 1] = { T("m_tank"), m.fill ~= nil and string.format("%d %%  (%s)", math.floor(m.fill.level / m.fill.cap * 100 + 0.5),
            m.solid and f1(m.fill.level * (massPerLiter(m.fill.ft) or 0), "t") or f0(m.fill.level, "l")) or "-",
            (m.fill ~= nil and m.fill.level / m.fill.cap < 0.1) and C.red or nil }
        L[#L + 1] = { T("m_dose"), m.doseKg ~= nil and f0(m.doseKg, "kg/ha") or f1(m.dose, "l/ha") }
        L[#L + 1] = { T("m_width"), f1(m.width, "m") }
        L[#L + 1] = { T("m_haLeft"), f1(m.haLeft, "ha") }
        L[#L + 1] = { T("m_state"), m.on and T("on") or T("off"), m.on and C.lamp or C.dim }
        for i, r in ipairs(L) do row(ctx, i, r[1], r[2], r[3], 0, ctx.cw - 20) end
        if m.fill ~= nil then
            bar(ctx, ctx.cx + 10, ctx.cy + 12 + #L * 27 + 6, ctx.cw - 20, 16, m.fill.level / m.fill.cap, C.blue)
        end
        return
    end

    -- moissonneuse, ensileuse, récolteuse
    if AS_T ~= nil and AS_T.harvestSelf then ctx.bigRows = true end
    local hl = m.header ~= nil and m.header.lowered
    ui.sideButton(ctx, 1, "lift", hl and T("doRaise") or T("doLower"), hl == true,
        m.kind == "forage" and T("m_header") or T("m_cutter"))
    ui.sideButton(ctx, 2, "on", m.on and T("doOff") or T("doOn"), m.on == true,
        m.kind == "forage" and T("m_chopper") or T("m_thresher"))
    if m.pipe ~= nil then
        ui.sideButton(ctx, 3, "pipe", m.pipe and T("m_pipeIn") or T("m_pipeOut"), m.pipe == true, T("m_pipe"))
    end
    if m.rh ~= nil then ui.sideButton(ctx, 4, "page_rh", T("rhPage"), false) end

    L[#L + 1] = { T("m_crop"), m.crop or "-" }
    if m.tank ~= nil then
        local p = m.tank.level / m.tank.cap
        L[#L + 1] = { T(m.kind == "combine" and "m_grainTank" or "m_tank"), string.format("%d %%  (%s)", math.floor(p * 100 + 0.5), f0(m.tank.level, "l")),
            p > 0.9 and C.red or (p > 0.75 and C.amber or nil) }
        L[#L + 1] = { T("m_toFull"), m.minToFull ~= nil and m.minToFull < 600 and f0(m.minToFull, "min") or "-" }
    end
    if m.header ~= nil then
        L[#L + 1] = { m.kind == "forage" and T("m_header") or T("m_cutter"),
            string.format("%s  %s", f1(m.header.width, "m"), m.header.lowered and T("m_low") or T("m_high")) }
    end
    L[#L + 1] = { T("m_tph"), f1(m.tph, "t/h") }
    if m.pipe ~= nil then
        local s = m.pipe and T("m_out") or T("m_in")
        if m.side ~= nil then s = s .. "  " .. (m.side == "L" and T("m_left") or T("m_right")) end
        L[#L + 1] = { T("m_pipe"), s }
    end
    if m.target ~= nil then
        local p = m.target.level / m.target.cap
        L[#L + 1] = { T("m_trailer"), string.format("%d %%", math.floor(p * 100 + 0.5)), p > 0.9 and C.red or C.lamp }
    end

    local r = m.rh
    if r ~= nil then
        R[#R + 1] = { T("m_load"), r.load ~= nil and string.format("%d %%%s", math.floor(r.load + 0.5),
            r.targetLoad ~= nil and string.format(" / %d", math.floor(r.targetLoad + 0.5)) or "") or "-",
            (r.load or 0) > 105 and C.red or nil }
        if m.kind == "forage" then
            R[#R + 1] = { T("m_fresh"), f1(r.fresh or r.tph, "t/h") }
            if type(r.power) == "table" then
                R[#R + 1] = { T("m_power"), string.format("%d / %d / %d ch", math.floor((r.power.feedPower or 0) + 0.5),
                    math.floor((r.power.drumPower or 0) + 0.5), math.floor((r.power.blowerPower or 0) + 0.5)) }
            end
            if r.pickup ~= nil then R[#R + 1] = { T("m_frontTool"), r.pickup and T("m_pickup") or T("m_header") } end
        else
            R[#R + 1] = { T("m_yield"), f1(r.yield, "t/ha") }
        end
        R[#R + 1] = { T("m_hph"), f1(r.hph, "ha/h") }
        R[#R + 1] = { T("m_speed"), f1(r.speed, "km/h"), C.lamp }
        if r.fuel ~= nil and r.fuel > 0 then R[#R + 1] = { T("m_fuel"), f1(r.fuel, "l/h") } end
        if r.moisture ~= nil and r.moisture > 0 then
            R[#R + 1] = { T("m_moist"), string.format("%.1f %%%s", r.moisture, r.moistureLimit ~= nil and string.format(" (max %.0f)", r.moistureLimit) or ""),
                r.moistureHigh and C.red or nil }
        end
        if r.weed ~= nil then R[#R + 1] = { T("m_weed"), string.format("%d %%", math.floor(r.weed * 100 + 0.5)) } end
        R[#R + 1] = { T("m_loss"), pct(r.loss), (r.loss or 0) > 3 and C.red or ((r.loss or 0) > 1 and C.amber or nil) }
        local parts = {}
        local function add(k, x) if x ~= nil and x >= 0.05 then parts[#parts + 1] = string.format("%s %.1f", T(k), x) end end
        add("m_lOver", r.lossOver); add("m_lMoist", r.lossMoist); add("m_lSet", r.lossSet); add("m_lWear", r.lossWear); add("m_lSlope", r.lossSlope)
        if #parts > 0 then R[#R + 1] = { "  " .. T("m_lossWhy"), table.concat(parts, "  ") } end
        if r.eff ~= nil then
            R[#R + 1] = { T("m_eff"), string.format("%d %%%s", math.floor(r.eff * 100 + 0.5), r.mode ~= nil and ("  " .. tostring(r.mode)) or ""),
                r.eff < 0.8 and C.amber or C.lamp }
        end
        if type(r.settings) == "table" then
            R.firstSet = #R + 1
            for _, k in ipairs(PARAMS) do
                local cur = r.settings[k]
                if type(cur) == "number" then
                    local opt = type(r.optimal) == "table" and r.optimal[k] or nil
                    local os
                    if type(opt) == "number" then os = string.format("%d", math.floor(opt + 0.5))
                    elseif type(opt) == "table" then
                        local a, b = opt.min or opt[1], opt.max or opt[2]
                        if type(a) == "number" and type(b) == "number" then os = string.format("%d-%d", math.floor(a + 0.5), math.floor(b + 0.5))
                        elseif type(opt.value or opt.optimal) == "number" then os = string.format("%d", math.floor((opt.value or opt.optimal) + 0.5)) end
                    end
                    R[#R + 1] = { T("m_s_" .. k), os ~= nil and string.format("%d  (%s)", math.floor(cur + 0.5), os) or string.format("%d", math.floor(cur + 0.5)) }
                end
            end
        end
    else
        R[#R + 1] = { T("m_noRh"), "", C.dim }
    end

    local maxRows = math.floor((ctx.ch - 14) / 27)
    -- colonne de droite trop longue : la fin (réglages) passe sous la colonne de gauche
    if #R > maxRows then
        local room = maxRows - #L - 1
        local first = R.firstSet or (#R - room + 1)
        if #R - first + 1 > room then first = #R - room + 1 end
        local take = #R - first + 1
        if take > 0 and room > 0 then
            local start = first
            L[#L + 1] = { "", "" }
            for k = start, #R do L[#L + 1] = R[k] end
            for k = #R, start, -1 do R[k] = nil end
        end
    end
    for i, x in ipairs(L) do if i <= maxRows and (x[1] ~= "" or x[2] ~= "") then row(ctx, i, x[1], x[2], x[3], 0, half) end end
    for i, x in ipairs(R) do if i <= maxRows then row(ctx, i, x[1], x[2], x[3], half + 10, half) end end
end

-------------------------------------------------------------------------------
-- (31/10) page RÉGLAGES RÉCOLTE : la console de Realistic Harvesting sur le terminal.
-- Tout passe par Realistic Harvesting lui-même : pas de calcul refait ici.
--   valeurs affichées : RHM_UnitConverter.formatSetting ; optimal : RHM_Api.getOptimalSettings ;
--   - / + : RHMCombineCalibrationGUI.stepParameter (même pas que sa console, réseau compris) ;
--   AUTO-CALIB / CHARGER / SAUVEGARDER / USINE : fonctions de sa mémoire de réglages.
-------------------------------------------------------------------------------
local function rhGlobal(name)
    local g = rawget(_G, name)
    if g == nil and AS ~= nil and AS.modGlobal ~= nil then
        local ok, r = pcall(AS.modGlobal, "FS25_RealisticHarvesting", name)
        if ok then g = r end
    end
    return g
end

local function rhText(key, fallback)
    if g_i18n ~= nil and g_i18n.hasText ~= nil and g_i18n:hasText(key) then return g_i18n:getText(key) end
    return fallback
end

-- combine, mémoire de réglages, type de machine, niveau (Tier)
function AS_TerminalMachine:rhContext(v)
    local api = rhm()
    if api == nil then return nil end
    local o = rcall(api, "findCombine", v)
    if o == nil or o.spec_rhm_Combine == nil or o.spec_rhm_Combine.combineMemory == nil then return nil end
    local spec = o.spec_rhm_Combine
    return { api = api, o = o, mem = spec.combineMemory, mt = spec.machineType or spec.combineMemory.machineType or "grain",
        tier = rcall(api, "getPackageLevel", o) or spec.packageLevel or 1 }
end

function AS_TerminalMachine:rhParams(c)
    local db = rhGlobal("RHM_CombineSettingsDatabase")
    local list
    if db ~= nil and db.getParamsForMachineType ~= nil then
        local ok, l = pcall(db.getParamsForMachineType, db, c.mt)
        if ok and type(l) == "table" then list = l end
    end
    list = list or PARAMS
    local out = {}
    for _, p in ipairs(list) do
        local key = "rhm_ui_" .. p
        if db ~= nil and db.getParamLabel ~= nil then
            local ok, k = pcall(db.getParamLabel, db, c.mt, p)
            if ok and type(k) == "string" then key = k end
        end
        out[#out + 1] = { p = p, label = rhText(key, U().T("m_s_" .. p)) }
    end
    out[#out + 1] = { p = "targetEngineLoad", label = rhText("rhm_ui_target_load", U().T("m_targetLoad")) }
    return out
end

function AS_TerminalMachine:rhAction(v, a)
    local c = self:rhContext(v)
    if c == nil then U().warn(U().T("rhNone")) return end
    local mem = c.mem
    if a == "rh_menu" then
        local mgr = rhGlobal("g_realisticHarvestManager")
        if mgr ~= nil and mgr.toggleMenu ~= nil then
            AS_Terminal:setOpen(false)
            pcall(mgr.toggleMenu, mgr, c.o)
        end
    elseif a == "rh_auto" then
        if c.tier >= 4 and mem.requestAutoSettings ~= nil then pcall(mem.requestAutoSettings, mem) end
    elseif a == "rh_load" then
        if c.tier >= 2 and mem.loadUserPreset ~= nil then
            local ok, res = pcall(mem.loadUserPreset, mem)
            if not ok or res == false then U().warn(U().T("rhNoPreset")) end
        end
    elseif a == "rh_save" then
        if c.tier >= 2 and mem.saveCurrentProfile ~= nil then pcall(mem.saveCurrentProfile, mem, mem.currentCrop) end
    elseif a == "rh_reset" then
        if mem.requestResetSettings ~= nil then pcall(mem.requestResetSettings, mem) end
    else
        -- rh_-_<param> / rh_+_<param>
        local dir, p = a:match("^rh_([%+%-])_(.+)$")
        if dir == nil then return end
        local mgr = rhGlobal("g_realisticHarvestManager")
        local gui = mgr ~= nil and mgr.calibrationGUI or nil
        local step = gui ~= nil and gui.stepParameter or nil
        if step ~= nil then
            local ok, err = pcall(step, { activeVehicle = c.o }, p, dir == "+" and 1 or -1, false)
            if not ok then log("ERREUR réglage %s : %s", p, tostring(err)) end
        elseif mem.updateSetting ~= nil then
            local cur = mem.currentSettings ~= nil and mem.currentSettings[p] or 50
            pcall(mem.updateSetting, mem, p, math.max(0, math.min(100, cur + (dir == "+" and 1 or -1))))
        end
    end
end

function AS_TerminalMachine:drawRh(d, ctx)
    local ui = U()
    local T, C = ui.T, ui.C
    local v = d.vehicle
    ui.sideButton(ctx, 1, "rh_menu", T("rhMenu"), false)
    ui.sideButton(ctx, 2, "page_tool", T("back"), false)
    local u, w = ctx.cx + 10, ctx.cw - 20
    local c = v ~= nil and self:rhContext(v) or nil
    if c == nil then
        ctx.text(u + 8, ctx.cy + 30, 14, T("rhNone"), C.dim, nil, true)
        return
    end
    local api, o, mem = c.api, c.o, c.mem
    -- en-tête : niveau, culture, charge, efficacité, perte
    local crop = rcall(api, "getCurrentCrop", o) or mem.currentCrop or "-"
    local ft = g_fillTypeManager ~= nil and g_fillTypeManager.getFillTypeByName ~= nil and g_fillTypeManager:getFillTypeByName(tostring(crop)) or nil
    if ft ~= nil and ft.title ~= nil then crop = ft.title end
    local load = rcall(api, "getEngineLoad", o)
    local eff = rcall(api, "getSettingsEfficiency", o)
    local loss = rcall(api, "getTotalCropLoss", o)
    local cells = {
        { "Tier " .. tostring(c.tier), tostring(crop) },
        { T("m_load"), load ~= nil and string.format("%d %%", math.floor(load + 0.5)) or "-" },
        { T("m_eff"), eff ~= nil and string.format("%.1f %%", eff * 100) or "-" },
        { T("m_loss"), loss ~= nil and string.format("%.1f %%", loss) or "-" },
    }
    local cwid = (w - 30) / 4
    for i, cell in ipairs(cells) do
        local xx = u + (i - 1) * (cwid + 10)
        ctx.rect(xx, ctx.cy + 10, cwid, 40, C.box)
        ctx.text(xx + cwid * 0.5, ctx.cy + 25, 11, cell[1], C.gray, RenderText.ALIGN_CENTER, true, cwid - 8)
        ctx.text(xx + cwid * 0.5, ctx.cy + 43, 14, cell[2], C.lamp, RenderText.ALIGN_CENTER, true, cwid - 8)
    end
    -- réglages
    local conv = rhGlobal("RHM_UnitConverter")
    local opt = rcall(api, "getOptimalSettings", o)
    local cur = mem.currentSettings or {}
    local yy = ctx.cy + 58
    local rowH = 31
    for _, it in ipairs(self:rhParams(c)) do
        local p = it.p
        local val = tonumber(cur[p]) or 0
        local shown
        if p == "targetEngineLoad" then shown = string.format("%d %%", math.floor(val + 0.5))
        elseif conv ~= nil and conv.formatSetting ~= nil then
            local ok, s = pcall(conv.formatSetting, p, val, c.mt)
            shown = ok and tostring(s) or string.format("%d %%", val)
        else shown = string.format("%d %%", val) end
        local o2 = type(opt) == "table" and type(opt[p]) == "table" and opt[p] or nil
        local optimal = o2 ~= nil and tonumber(o2.optimal) or nil
        local tol = o2 ~= nil and tonumber(o2.tolerance) or 5
        local status, scol = "", C.gray
        if c.tier >= 2 and optimal ~= nil and p ~= "targetEngineLoad" then
            if math.abs(val - optimal) <= tol then status, scol = rhText("rhm_ui_status_optimal", "OPTIMAL"), C.lamp
            else
                status = val < optimal and rhText("rhm_ui_status_low", "LOW") or rhText("rhm_ui_status_high", "HIGH")
                scol = (math.abs(val - optimal) - tol > 20) and C.red or C.amber
            end
        end
        ctx.rect(u, yy, w, rowH - 4, C.box)
        -- (01/11) libellé, valeur et état chacun dans sa part de la ligne (plus de chevauchement)
        local vw = math.min(ctx.measure ~= nil and ctx.measure(13, shown) or 70, 110)
        ctx.text(u + 8, yy + 18, 12, it.label, C.white, nil, nil, math.max(40, 230 - vw - 8 - 14))
        ctx.text(u + 230, yy + 18, 13, shown, C.lamp, RenderText.ALIGN_RIGHT, true, 110)
        if status ~= "" then ctx.text(u + 240, yy + 18, 11, status, scol, nil, true, 84) end
        -- barre 0..100 avec la zone optimale
        local bx, bw = u + 330, w - 330 - 100
        ctx.rect(bx, yy + 9, bw, 9, C.screen)
        if c.tier >= 2 and optimal ~= nil and p ~= "targetEngineLoad" then
            local a0 = math.max(0, optimal - tol) / 100
            local a1 = math.min(100, optimal + tol) / 100
            ctx.rect(bx + bw * a0, yy + 9, bw * (a1 - a0), 9, C.boxHi)
        end
        local frac = p == "targetEngineLoad" and (val - 70) / 30 or val / 100
        frac = math.max(0, math.min(1, frac))
        ctx.rect(bx, yy + 11, bw * frac, 5, scol == C.gray and C.blue or scol)
        ctx.rect(bx + bw * frac - 2, yy + 6, 4, 15, C.white)
        ctx.button(u + w - 92, yy + 2, 40, rowH - 8, "rh_-_" .. p)
        ctx.text(u + w - 72, yy + 18, 13, "-", C.white, RenderText.ALIGN_CENTER, true)
        ctx.button(u + w - 46, yy + 2, 40, rowH - 8, "rh_+_" .. p)
        ctx.text(u + w - 26, yy + 18, 13, "+", C.white, RenderText.ALIGN_CENTER, true)
        yy = yy + rowH
    end
    -- boutons du bas
    local btns = {}
    if c.tier >= 4 then btns[#btns + 1] = { "rh_auto", T("rhAuto") } end
    if c.tier >= 2 then
        btns[#btns + 1] = { "rh_load", T("rhLoad") }
        btns[#btns + 1] = { "rh_save", T("rhSave") }
    end
    btns[#btns + 1] = { "rh_reset", T("rhReset") }
    local bw2 = (w - (#btns - 1) * 8) / #btns
    local by = math.min(yy + 4, ctx.cy + ctx.ch - 30)
    for i, b in ipairs(btns) do
        local xx = u + (i - 1) * (bw2 + 8)
        ctx.button(xx, by, bw2, 26, b[1], b[1] == "rh_auto")
        ctx.text(xx + bw2 * 0.5, by + 17, 11, b[2], C.white, RenderText.ALIGN_CENTER, true)
    end
end

-- page « rh » du terminal
function AS_Terminal:page_rh(d, ctx)
    local ok, err = pcall(AS_TerminalMachine.drawRh, AS_TerminalMachine, d, ctx)
    if not ok and not self.loggedRh then self.loggedRh = true; log("ERREUR page réglages récolte : %s", tostring(err)) end
end

-- (01/11) écran RÉGLAGES de la moissonneuse Case : valeur affichée, état et libellé d'un réglage RH
function AS_TerminalMachine:rhSettingInfo(v)
    local c = v ~= nil and self:rhContext(v) or nil
    if c == nil then return nil end
    local conv = rhGlobal("RHM_UnitConverter")
    local opt = rcall(c.api, "getOptimalSettings", c.o)
    local cur = c.mem.currentSettings or {}
    local out = { tier = c.tier, list = {} }
    for _, it in ipairs(self:rhParams(c)) do
        local p = it.p
        local val = tonumber(cur[p]) or 0
        local shown
        if p == "targetEngineLoad" then shown = string.format("%d %%", math.floor(val + 0.5))
        elseif conv ~= nil and conv.formatSetting ~= nil then
            local ok, s = pcall(conv.formatSetting, p, val, c.mt)
            shown = ok and tostring(s) or string.format("%d %%", val)
        else shown = string.format("%d %%", val) end
        local o2 = type(opt) == "table" and type(opt[p]) == "table" and opt[p] or nil
        local optimal = o2 ~= nil and tonumber(o2.optimal) or nil
        local tol = o2 ~= nil and tonumber(o2.tolerance) or 5
        local state = nil
        if c.tier >= 2 and optimal ~= nil and p ~= "targetEngineLoad" then
            if math.abs(val - optimal) <= tol then state = "ok"
            elseif math.abs(val - optimal) - tol > 20 then state = "bad" else state = "warn" end
        end
        local e = { p = p, label = it.label, shown = shown, val = val, optimal = optimal, tol = tol, state = state,
            status = state == "ok" and rhText("rhm_ui_status_optimal", "OPTIMAL")
                or (state ~= nil and (val < optimal and rhText("rhm_ui_status_low", "LOW") or rhText("rhm_ui_status_high", "HIGH")) or "") }
        out.list[#out.list + 1] = e
        out[p] = e
    end
    return out
end
