-------------------------------------------------------------------------------
-- AutoSwitch - Terminal : page OUTIL façon ISOBUS (étape 29, 01/11)
--   * un onglet par outil attelé (masses exclues), la machine elle-même d'abord
--     quand elle travaille (moissonneuse, ensileuse, automoteur) ;
--   * image du magasin de l'outil, état (baissé, en marche, déplié) ;
--   * tuiles de compteurs choisies selon l'outil (presse : balles, format, ficelle ;
--     semoir : semence, trémie, traceurs ; épandeur : dose, cuve, ha restants...) ;
--   * touches de droite propres à l'outil choisi, qui n'agissent QUE sur lui.
--   Toutes les commandes passent par les fonctions du jeu (celles de ses touches).
-------------------------------------------------------------------------------
AS_TerminalTools = {}
AS_TerminalTools.sel = setmetatable({}, { __mode = "k" })     -- [véhicule] = outil choisi (clic sur l'onglet)
AS_TerminalTools.shown = setmetatable({}, { __mode = "k" })   -- [véhicule] = outil affiché
AS_TerminalTools.counters = {}                                -- [uniqueId de l'outil] = { ha, ms, dist }
AS_TerminalTools.MAX_TABS = 5
AS_TerminalTools.MAX_KEYS = 7

local function log(fmt, ...)
    (AS.rawPrint or print)("[AS_TerminalTools] " .. string.format(fmt, ...))
end

local U = function() return AS_Terminal.ui end
local function call(o, name, ...) return U().call(o, name, ...) end
local function T(k) return U().T(k) end
local function clamp(v, a, b) return math.max(a, math.min(b, v)) end

local function cut(s, n)
    s = tostring(s or "")
    if n < 2 then return "" end
    if utf8Strlen ~= nil and utf8Substr ~= nil then
        if utf8Strlen(s) > n then return utf8Substr(s, 0, n - 1) .. "." end
        return s
    end
    if #s > n then return s:sub(1, n - 1) .. "." end
    return s
end

local function f1(x) return string.format("%.1f", x or 0) end
local function f2(x) return string.format("%.2f", x or 0) end
local function hm(ms)
    local m = math.floor((ms or 0) / 60000)
    return string.format("%d:%02d", math.floor(m / 60), m % 60)
end

-------------------------------------------------------------------------------
-- magasin : image, marque, catégorie
-------------------------------------------------------------------------------
local function storeItem(o)
    if g_storeManager == nil or o == nil or o.configFileName == nil then return nil end
    local ok, it = pcall(g_storeManager.getItemByXMLFilename, g_storeManager, o.configFileName)
    if ok and type(it) == "table" then return it end
    return nil
end

-- marque de l'outil : nom et logo (image du magasin des marques)
local function brandTitle(o, it)
    if g_brandManager == nil then return nil end
    local idx = (it ~= nil and it.brandIndex) or call(o, "getBrand")
    if idx == nil then return nil end
    local ok, b = pcall(g_brandManager.getBrandByIndex, g_brandManager, idx)
    if ok and type(b) == "table" and b.name ~= "NONE" then
        return b.title or b.name, (type(b.image) == "string" and b.image ~= "") and b.image or nil
    end
    return nil
end

-- icône du produit (semence, engrais...) : celle du HUD du jeu
local function fillIcon(ft)
    if ft == nil or g_fillTypeManager == nil then return nil end
    local f = g_fillTypeManager:getFillTypeByIndex(ft)
    local file = f ~= nil and f.hudOverlayFilename or nil
    return (type(file) == "string" and file ~= "") and file or nil
end

-- image du magasin d'un outil (aussi pour la case Outils de l'accueil)
function AS_TerminalTools.storeImage(o)
    local it = storeItem(o)
    if it ~= nil and type(it.imageFilename) == "string" and it.imageFilename ~= "" then return it.imageFilename end
    return nil
end

-- masses (avant, roues) : pas d'onglet
function AS_TerminalTools.isWeight(o)
    local it = storeItem(o)
    local cat = it ~= nil and tostring(it.categoryName or ""):lower() or ""
    if cat:find("weight", 1, true) then return true end
    local tn = tostring(o.typeName or (type(o.type) == "table" and o.type.name) or ""):lower()
    return tn:find("weight", 1, true) ~= nil
end

-------------------------------------------------------------------------------
-- type d'outil (ordre : du plus précis au plus général)
-------------------------------------------------------------------------------
local function kindOf(o)
    if o.spec_baler ~= nil then return "baler" end
    if o.spec_baleLoader ~= nil then return "baleLoader" end
    if o.spec_baleWrapper ~= nil then return "wrapper" end
    if o.spec_combine ~= nil then return "harvester" end
    if o.spec_cutter ~= nil then return "header" end
    if o.spec_forageWagon ~= nil then return "forageWagon" end
    if o.spec_mixerWagon ~= nil then return "mixer" end
    if o.spec_sowingMachine ~= nil then return "seeder" end
    if o.spec_sprayer ~= nil then return "sprayer" end
    if o.spec_mower ~= nil then return "mower" end
    if o.spec_tedder ~= nil then return "tedder" end
    if o.spec_windrower ~= nil then return "windrower" end
    if o.spec_plow ~= nil then return "plow" end
    if o.spec_cultivator ~= nil or o.spec_weeder ~= nil or o.spec_roller ~= nil or o.spec_mulcher ~= nil
        or o.spec_stonePicker ~= nil or o.spec_subsoiler ~= nil then return "soil" end
    if o.spec_trailer ~= nil or o.spec_dischargeable ~= nil then return "trailer" end
    return "generic"
end
AS_TerminalTools.kindOf = kindOf

-- nom du type affiché sur l'onglet
local function kindLabel(t)
    local k = t.kind
    if t.self then
        local mk = t.machKind
        if mk == "combine" or mk == "forage" or mk == "root" then return T("tk_" .. mk) end
        return T("tk_selfSprayer")
    end
    if k == "sprayer" then
        local cat = t.cat or ""
        if cat:find("sprayer", 1, true) then return T("tk_sprayer") end
        if cat:find("slurry", 1, true) then return T("tk_slurry") end
        return T("tk_spreader")
    end
    if k == "soil" then
        local o = t.o
        if o.spec_weeder ~= nil then return T("tk_weeder") end
        if o.spec_roller ~= nil then return T("tk_roller") end
        if o.spec_mulcher ~= nil then return T("tk_mulcher") end
        if o.spec_stonePicker ~= nil then return T("tk_stonePicker") end
        return T("tk_cultivator")
    end
    if k == "harvester" then return T("tk_root") end
    return T("tk_" .. k)
end
AS_TerminalTools.kindLabel = kindLabel   -- (66e) type d'outil de la page Géométrie des tronçons Massey

-------------------------------------------------------------------------------
-- compteurs propres à chaque outil (surface et heures au travail), gardés dans la partie
-------------------------------------------------------------------------------
local function toolKey(o) return o.uniqueId or o end

function AS_TerminalTools:counter(o)
    local k = toolKey(o)
    local c = self.counters[k]
    if c == nil then
        c = { ha = 0, ms = 0, dist = 0 }
        self.counters[k] = c
    end
    return c
end

-- appelé par AS_Terminal:updateCounters pour chaque véhicule moteur en marche
function AS_TerminalTools:count(v, dist, dtMs)
    local ui = U()
    for _, o in ipairs(ui.trainOf(v)) do
        if ui.isWorking(o) then
            local c = self:counter(o)
            c.ms = c.ms + dtMs
            if dist > 0 then
                c.dist = c.dist + dist
                local w = ui.workWidth(o)
                if w ~= nil and w > 0 then
                    c.ha = c.ha + w * dist / 10000
                    -- (04/11) graines semées : densité Precision Farming × surface travaillée
                    if o.spec_sowingMachine ~= nil then
                        local ok, sp = pcall(AS_TerminalTools.readSeedPF, o)
                        if ok and sp ~= nil and sp.supported and sp.perSqm ~= nil then c.seeds = (c.seeds or 0) + sp.perSqm * w * dist end
                    end
                end
            end
        end
    end
end

function AS_TerminalTools:saveCounters(xml)
    local i = 0
    for key, c in pairs(self.counters) do
        if type(key) == "string" then
            local k = string.format("terminal.tool(%d)", i)
            setXMLString(xml, k .. "#id", key)
            setXMLFloat(xml, k .. "#ha", c.ha)
            setXMLFloat(xml, k .. "#hours", c.ms / 3600000)
            setXMLFloat(xml, k .. "#km", c.dist / 1000)
            if c.seeds ~= nil then setXMLFloat(xml, k .. "#seeds", c.seeds) end
            i = i + 1
        end
    end
end

function AS_TerminalTools:loadCounters(xml)
    self.counters = {}
    local i = 0
    while true do
        local k = string.format("terminal.tool(%d)", i)
        if not hasXMLProperty(xml, k) then break end
        local id = getXMLString(xml, k .. "#id")
        if id ~= nil then
            self.counters[id] = { ha = getXMLFloat(xml, k .. "#ha") or 0, ms = (getXMLFloat(xml, k .. "#hours") or 0) * 3600000,
                dist = (getXMLFloat(xml, k .. "#km") or 0) * 1000, seeds = getXMLFloat(xml, k .. "#seeds") }
        end
        i = i + 1
    end
    return i
end

-------------------------------------------------------------------------------
-- lecture d'un outil
-------------------------------------------------------------------------------
local function fillOf(o, idx)
    if idx == nil then return nil end
    local cap = call(o, "getFillUnitCapacity", idx) or 0
    if cap <= 0 then return nil end
    local lvl = call(o, "getFillUnitFillLevel", idx) or 0
    local ft = call(o, "getFillUnitFillType", idx)
    return { level = lvl, cap = cap, ft = ft, idx = idx, frac = clamp(lvl / cap, 0, 1),
        title = lvl <= 0.5 and T("m_empty") or U().fillTypeTitle(ft) }
end

local function massPerLiter(ft)
    if ft == nil or g_fillTypeManager == nil then return nil end
    local f = g_fillTypeManager:getFillTypeByIndex(ft)
    return f ~= nil and tonumber(f.massPerLiter) or nil
end

-- consommables (ficelle, filet, film) : bobines dans le stock de l'outil
local function consumables(o)
    local sc = o.spec_consumable
    if sc == nil or type(sc.types) ~= "table" then return nil end
    local out = {}
    for _, ty in ipairs(sc.types) do
        if ty.fillUnitIndex ~= nil then
            local cap = call(o, "getFillUnitCapacity", ty.fillUnitIndex) or 0
            local lvl = call(o, "getFillUnitFillLevel", ty.fillUnitIndex) or 0
            if cap > 0 then
                local n = tostring(ty.typeName or ""):upper()
                local key = n:find("NET", 1, true) and "net" or ((n:find("FOIL", 1, true) or n:find("WRAP", 1, true) or n:find("FILM", 1, true)) and "film" or "twine")
                out[#out + 1] = { key = key, level = lvl, cap = cap }
            end
        end
    end
    return #out > 0 and out or nil
end

-- pannes d'Advanced Damage System sur l'outil : 2 = en panne, 1 = panne qui commence
-------------------------------------------------------------------------------
-- (04/11) Precision Farming : densité de semis, dose d'engrais, azote, pH
--   valeurs lues dans les spécialisations du mod (extendedSowingMachine,
--   extendedSprayer) ; les boutons AUTO / MANU / − / + appellent ses fonctions
--   (setSeedRateAutoMode, setManualSeedRate, setSprayAmountAutoMode,
--   setSprayAmountManualValue), qui envoient elles-mêmes leurs événements.
-------------------------------------------------------------------------------
local PFM = "FS25_precisionFarming"
local pfKey = {}
local pfMiss = setmetatable({}, { __mode = "k" })
local function pfGlobal(name)
    local v = AS ~= nil and AS.modGlobal ~= nil and AS.modGlobal(PFM, name) or nil
    if v ~= nil then return v end
    -- globales du jeu par leur nom (pas de rawget : l'environnement du mod passe par __index)
    if name == "g_precisionFarming" then return g_precisionFarming
    elseif name == "ExtendedSowingMachine" then return ExtendedSowingMachine
    elseif name == "ExtendedSprayer" then return ExtendedSprayer end
    return nil
end
local function pfSpec(o, name, className)
    if type(o) ~= "table" then return nil end
    local k = pfKey[name]
    if k ~= nil then return o[k] end
    local now = g_time or 0
    if pfMiss[o] ~= nil and now >= pfMiss[o] and now - pfMiss[o] < 5000 then return nil end
    local cls = pfGlobal(className)
    if type(cls) == "table" and type(cls.SPEC_TABLE_NAME) == "string" and type(o[cls.SPEC_TABLE_NAME]) == "table" then
        pfKey[name] = cls.SPEC_TABLE_NAME
        return o[cls.SPEC_TABLE_NAME]
    end
    local suf = "." .. name
    for kk, vv in pairs(o) do
        if type(kk) == "string" and type(vv) == "table" and kk:sub(1, 5) == "spec_" and kk:sub(-#suf) == suf then
            pfKey[name] = kk
            return vv
        end
    end
    pfMiss[o] = now
    return nil
end
AS_TerminalTools.pfSpec = pfSpec
local function pfCall(obj, fn, ...)
    if type(obj) ~= "table" or type(obj[fn]) ~= "function" then return nil end
    local ok, a, b = pcall(obj[fn], obj, ...)
    if ok then return a, b end
    return nil
end
local pfTexts = {}
local function pfText(key)
    if pfTexts[key] == nil then
        local s = false
        if g_i18n ~= nil and g_i18n.getText ~= nil then
            local ok, r = pcall(g_i18n.getText, g_i18n, key, PFM)
            if ok and type(r) == "string" and r ~= "" and not r:find("Missing", 1, true) and r ~= key then s = r end
        end
        pfTexts[key] = s
    end
    return pfTexts[key] or nil
end
-- unité de la densité de PF (son propre texte) -> graines par m² (nil si inconnue)
local function seedsPerSqm(rate, fmt)
    if type(rate) ~= "number" or type(fmt) ~= "string" then return nil end
    local u = fmt:gsub("%%[%-%d%.]*[sdfgi]", ""):lower()
    if u:find("kg", 1, true) or u:find("l/", 1, true) then return nil end
    local mul = 1
    if u:find("mio", 1, true) or u:find("mill", 1, true) then mul = 1000000
    elseif u:find("k", 1, true) or u:find("tsd", 1, true) or u:find("tausend", 1, true) or u:find("thousand", 1, true) or u:find("mille", 1, true) then mul = 1000 end
    if u:find("/ha", 1, true) or u:find(" ha", 1, true) then return rate * mul / 10000 end
    if u:find("m²", 1, true) or u:find("m2", 1, true) or u:find("/m", 1, true) then return rate * mul end
    return nil
end
local pfLogged = {}
local function pfLogOnce(key, fmt, ...)
    if pfLogged[key] then return end
    pfLogged[key] = true
    log(fmt, ...)
end

-- densité de semis : valeur, palier 1..3, conseillé, auto
local function readSeedPF(o)
    local es = pfSpec(o, "extendedSowingMachine", "ExtendedSowingMachine")
    local pf = pfGlobal("g_precisionFarming")
    if es == nil or type(pf) ~= "table" or pf.seedRateMap == nil then return nil end
    local srm = pf.seedRateMap
    local ss = o.spec_sowingMachine
    local fruit = type(ss.seeds) == "table" and ss.seeds[ss.currentSeed or 1] or nil
    local s = { auto = es.seedRateAutoMode == true, rec = es.seedRateRecommendation }
    s.supported = fruit ~= nil and pfCall(srm, "getIsFruitTypeSupported", fruit) == true
    if s.auto then
        s.idx = es.lastSeedRateIndex
        s.rate = es.lastSeedRate
        -- (04/11) à l'arrêt PF n'a pas encore de densité (0) : celle conseillée pour le sol, sinon standard
        if s.idx == nil or s.idx == 0 or s.rate == nil or s.rate == 0 then
            s.idx = s.rec or 2
            s.rate = pfCall(srm, "getSeedRateByFruitTypeAndIndex", fruit, s.idx)
        end
    else
        s.idx = es.manualSeedRate
        if s.idx ~= nil then s.rate = pfCall(srm, "getSeedRateByFruitTypeAndIndex", fruit, s.idx) end
    end
    local SM = pfGlobal("ExtendedSowingMachine")
    s.min = type(SM) == "table" and SM.MIN_SEED_RATE or 1
    s.max = type(SM) == "table" and SM.MAX_SEED_RATE or 3
    s.fmt = pfText("hudExtensionSowingMachine_seedRate")
    s.perSqm = seedsPerSqm(s.rate, s.fmt)
    pfLogOnce("seedFmt", "Precision Farming semis : texte « %s », densité %s (palier %s), graines/m² %s",
        tostring(s.fmt), tostring(s.rate), tostring(s.idx), tostring(s.perSqm))
    return s
end
AS_TerminalTools.readSeedPF = readSeedPF

-- dose de l'épandeur / pulvé / engrais du semoir
local function readSprayPF(o)
    local es = pfSpec(o, "extendedSprayer", "ExtendedSprayer")
    local pf = pfGlobal("g_precisionFarming")
    if es == nil or type(pf) ~= "table" then return nil end
    local p = { auto = es.sprayAmountAutoMode == true, canAuto = es.sprayAmountAutoModeChangeAllowed ~= false,
        man = es.sprayAmountManual or 0, manMin = es.sprayAmountManualMin or 0, manMax = es.sprayAmountManualMax or 0 }
    if es.isLiming then p.kind = "lime"
    elseif es.isSlurryTanker then p.kind = "slurry"
    elseif es.isManureSpreader then p.kind = "manure"
    elseif es.isFertilizing and es.isLiquidFertilizerSprayer then p.kind = "liquid"
    elseif es.isFertilizing then p.kind = "solid" end
    if p.kind == nil then return nil end
    -- produit (celui de la cuve, ou de la source qui alimente l'outil)
    local src, fui = o, call(o, "getSprayerFillUnitIndex") or (o.spec_sprayer ~= nil and o.spec_sprayer.fillUnitIndex) or 1
    local ESC = pfGlobal("ExtendedSprayer")
    if type(ESC) == "table" and ESC.getFillTypeSourceVehicle ~= nil then
        local ok, sv, si = pcall(ESC.getFillTypeSourceVehicle, o)
        if ok and sv ~= nil then src, fui = sv, si or fui end
    end
    local ft = call(src, "getFillUnitFillType", fui)
    if ft == nil or (FillType ~= nil and ft == FillType.UNKNOWN) then ft = call(src, "getFillUnitLastValidFillType", fui) end
    local mpl
    if ft ~= nil and g_fillTypeManager ~= nil then
        local f = g_fillTypeManager:getFillTypeByIndex(ft)
        if f ~= nil and tonumber(f.massPerLiter) ~= nil then
            mpl = f.massPerLiter / ((FillTypeManager ~= nil and FillTypeManager.MASS_SCALE) or 1)
        end
    end
    -- l/ha -> valeur affichée (comme le HUD de PF)
    local function conv(lpha)
        if lpha == nil then return nil end
        if p.kind == "solid" then return mpl ~= nil and lpha * mpl * 1000 or nil, "kg/ha", "%d"
        elseif p.kind == "liquid" then return lpha, "l/ha", "%d"
        elseif p.kind == "slurry" then return lpha / 1000, "m³/ha", "%.1f"
        else return mpl ~= nil and lpha * mpl or nil, "t/ha", "%.1f" end
    end
    p.real, p.unit, p.vfmt = conv(es.lastLitersPerHectar)
    local setL = es.lastLitersPerHectar
    -- (04/11) AUTO à l'arrêt : PF n'a pas encore de dose (0) -> celle qu'il faut pour l'objectif du sol
    if p.auto and (setL == nil or setL <= 0) then
        if p.kind == "lime" and es.pHMap ~= nil and (es.phActualValue or 0) ~= 0 and (es.phTargetValue or 0) ~= 0 then
            local ch = math.ceil(es.phTargetValue - es.phActualValue)
            setL = ch > 0 and (pfCall(es.pHMap, "getLimeUsageByStateChange", ch) or 0) or 0
        elseif p.kind ~= "lime" and es.nitrogenMap ~= nil and (es.nActualValue or 0) > 0 and (es.nTargetValue or 0) > 0 then
            local ch = math.ceil(es.nTargetValue - es.nActualValue)
            setL = ch > 0 and (pfCall(es.nitrogenMap, "getFertilizerUsageByStateChange", ch, ft) or 0) or 0
        end
    end
    if not p.auto then
        if p.kind == "lime" and es.pHMap ~= nil then setL = pfCall(es.pHMap, "getLimeUsageByStateChange", p.man) or setL
        elseif es.nitrogenMap ~= nil then setL = pfCall(es.nitrogenMap, "getFertilizerUsageByStateChange", p.man, ft) or setL end
    end
    p.set = conv(setL)
    -- sol : azote (kg N/ha) ou pH, actuel -> visé (seulement sur un champ)
    local onField = o.isOnField ~= false
    if p.kind == "lime" then
        local pm = es.pHMap
        if pm ~= nil and (es.phActualValue or 0) ~= 0 and (es.phTargetValue or 0) ~= 0 and onField then
            p.cur = pfCall(pm, "getPhValueFromInternalValue", es.phActualValue)
            p.goal = pfCall(pm, "getPhValueFromInternalValue", es.phTargetValue)
            if p.cur ~= nil and p.goal ~= nil then
                p.after = p.auto and p.goal or (p.cur + (pfCall(pm, "getPhValueFromChangedStates", p.man) or 0))
            end
        end
    else
        local nm = es.nitrogenMap
        if nm ~= nil and (es.nActualValue or 0) > 0 and (es.nTargetValue or 0) > 0 and onField and not es.isDoingMissionWork then
            local mx = nm.maxValue or math.huge
            p.cur = pfCall(nm, "getNitrogenValueFromInternalValue", clamp(es.nActualValue, 0, mx))
            p.goal = pfCall(nm, "getNitrogenValueFromInternalValue", clamp(es.nTargetValue, 0, mx))
            if p.cur ~= nil and p.goal ~= nil then
                p.after = p.auto and math.max(p.cur, p.goal) or (p.cur + (pfCall(nm, "getNitrogenFromChangedStates", p.man) or 0))
            end
        end
    end
    p.onField = onField
    if (es.lastTouchedSoilType or 0) ~= 0 and es.soilMap ~= nil then
        local st = pfCall(es.soilMap, "getSoilTypeByIndex", es.lastTouchedSoilType)
        if type(st) == "table" then p.soil = st.name end
    end
    return p
end
AS_TerminalTools.readSprayPF = readSprayPF

local function adsLevel(o)
    local ads = o.spec_AdvancedDamageSystem
    if ads == nil then return 0 end
    local lvl = 0
    if type(ads.components) == "table" then
        for _, st in pairs(ads.components) do
            if type(st) == "table" and st.defect == true then lvl = 2 end
        end
    end
    for _, b in pairs(type(ads.activeBreakdowns) == "table" and ads.activeBreakdowns or {}) do
        if type(b) == "table" and type(b.breakdownProgress) == "number" then
            if b.breakdownProgress >= 0.75 then lvl = 2 elseif b.breakdownProgress > 0 and lvl < 1 then lvl = 1 end
        end
    end
    return lvl
end

-- position par rapport au tracteur : AV / AR
local function sideOf(o, v)
    if o == v or o.rootNode == nil or v.rootNode == nil then return nil end
    local ok, _, _, z = pcall(localToLocal, o.rootNode, v.rootNode, 0, 0, 0)
    if not ok or z == nil then return nil end
    return z > 0 and "AV" or "AR", z
end

function AS_TerminalTools:readTool(v, d, o, isSelf)
    local ui = U()
    local it = storeItem(o)
    local t = { o = o, self = isSelf, kind = kindOf(o), name = ui.vehicleName(o) }
    t.cat = it ~= nil and tostring(it.categoryName or ""):lower() or ""
    t.img = it ~= nil and type(it.imageFilename) == "string" and it.imageFilename ~= "" and it.imageFilename or nil
    t.brand, t.brandImg = brandTitle(o, it)
    t.side, t.z = sideOf(o, v)
    if isSelf then
        t.machKind = d.mach ~= nil and d.mach.kind or nil
        if t.machKind == "spreader" then t.kind = "sprayer" end
    end
    t.width = ui.workWidth(o)
    -- baisser : par l'attelage (3 points) ou par l'outil lui-même (pick-up, pliage du milieu)
    t.lowered = ui.isLowered(o)
    t.ownLower = not ui.jointLowers(o) and ui.ownLowerKind(o) or nil
    t.canLower = t.lowered ~= nil and (ui.jointLowers(o) or t.ownLower ~= nil or (isSelf and o.spec_foldable ~= nil and o.spec_foldable.foldMiddleAnimTime ~= nil))
    t.on = ui.isTurnedOn(o)
    if t.on ~= nil and o.setIsTurnedOn == nil then t.on = nil end
    local sf = o.spec_foldable
    if sf ~= nil and sf.foldingParts ~= nil and #sf.foldingParts > 0 then t.unfolded = call(o, "getIsUnfolded") == true end
    t.working = ui.isWorking(o)
    t.cnt = self:counter(o)
    t.ads = adsLevel(o)
    -- relevage qui porte l'outil (pourcentage)
    for _, h in ipairs(d.hitches or {}) do
        if h.object == o then t.hitch = h end
    end
    -- réservoirs (tous, pour les alertes) ; le principal selon le type plus bas
    t.fills = {}
    local fus = call(o, "getFillUnits")
    if type(fus) == "table" then
        for i, fu in ipairs(fus) do
            if (fu.capacity or 0) > 0 and fu.showOnHud ~= false then
                local f = fillOf(o, i)
                if f ~= nil then t.fills[#t.fills + 1] = f end
            end
        end
    end
    t.cons = consumables(o)
    -- consommables retirés de la liste des réservoirs (ils ont leur tuile)
    if t.cons ~= nil and o.spec_consumable ~= nil then
        local skip = {}
        for _, ty in ipairs(o.spec_consumable.types or {}) do if ty.fillUnitIndex ~= nil then skip[ty.fillUnitIndex] = true end end
        local keep = {}
        for _, f in ipairs(t.fills) do if not skip[f.idx] then keep[#keep + 1] = f end end
        t.fills = keep
    end

    local k = t.kind
    if k == "baler" then
        local sb = o.spec_baler
        t.main = fillOf(o, sb.fillUnitIndex)
        local bt = type(sb.baleTypes) == "table" and sb.baleTypes[sb.currentBaleTypeIndex or 1] or nil
        local pre = type(sb.baleTypes) == "table" and sb.baleTypes[sb.preSelectedBaleTypeIndex or 1] or nil
        t.bale = bt
        t.balePre = pre ~= bt and pre or nil
        t.nBaleTypes = type(sb.baleTypes) == "table" and #sb.baleTypes or 0
        t.round = sb.isRoundBaler == true or (bt ~= nil and bt.isRoundBale == true)
        if sb.hasPlatform then t.autoDrop = sb.platformAutomaticDrop == true else t.autoDrop = sb.automaticDrop == true end
        t.canAutoToggle = sb.toggleableAutomaticDrop == true
        t.canEject = not sb.automaticDrop or (sb.hasPlatform == true and not sb.platformAutomaticDrop)
        local bc = o.spec_baleCounter
        if bc ~= nil then t.bales, t.balesTotal = bc.sessionCounter or 0, bc.lifetimeCounter or 0 end
    elseif k == "baleLoader" then
        local sl = o.spec_baleLoader
        t.main = fillOf(o, sl.fillUnitIndex)
        t.workPos = sl.isInWorkPosition == true
        t.emptying = sl.emptyState ~= nil and sl.emptyState ~= (BaleLoader ~= nil and BaleLoader.EMPTY_NONE or 1)
    elseif k == "wrapper" then
        local sw = o.spec_baleWrapper
        t.autoDrop = sw.automaticDrop == true
        t.canAutoToggle = sw.toggleableAutomaticDrop == true
        local st = sw.baleWrapperState or 0
        local BW = BaleWrapper
        t.wrapReady = BW ~= nil and BW.STATE_WRAPPER_FINSIHED ~= nil and st == BW.STATE_WRAPPER_FINSIHED
        t.wrapping = st ~= 0 and not t.wrapReady
    elseif k == "seeder" then
        local ss = o.spec_sowingMachine
        local idx = type(ss.seeds) == "table" and ss.seeds[ss.currentSeed or 1] or nil
        if idx ~= nil and g_fruitTypeManager ~= nil and g_fruitTypeManager.getFillTypeByFruitTypeIndex ~= nil then
            local ok, ft = pcall(g_fruitTypeManager.getFillTypeByFruitTypeIndex, g_fruitTypeManager, idx)
            if ok and type(ft) == "table" then
                t.seed = ft.title or ft.name
                t.seedIcon = (type(ft.hudOverlayFilename) == "string" and ft.hudOverlayFilename ~= "") and ft.hudOverlayFilename or nil
            end
        end
        t.nSeeds = type(ss.seeds) == "table" and #ss.seeds or 0
        local sidx = ss.fillUnitIndex or (o.getSowingMachineFillUnitIndex ~= nil and call(o, "getSowingMachineFillUnitIndex")) or nil
        t.main = fillOf(o, sidx)
        if o.spec_sprayer ~= nil then
            local fidx = call(o, "getSprayerFillUnitIndex") or o.spec_sprayer.fillUnitIndex
            if fidx ~= nil and fidx ~= sidx then t.fert = fillOf(o, fidx) end
            local okF, pf = pcall(readSprayPF, o)
            if okF then t.pfFert = pf elseif not self.loggedPF then self.loggedPF = true; log("ERREUR Precision Farming (engrais) : %s", tostring(pf)) end
        end
        local okS, ps = pcall(readSeedPF, o)
        if okS then t.pfSeed = ps elseif not self.loggedPF then self.loggedPF = true; log("ERREUR Precision Farming (semis) : %s", tostring(ps)) end
    elseif k == "sprayer" then
        local m
        if d.mach ~= nil and d.mach.obj == o and d.mach.kind == "spreader" then m = d.mach
        elseif AS_TerminalMachine ~= nil and AS_TerminalMachine.readSpreader ~= nil then
            m = {}
            local ok = pcall(AS_TerminalMachine.readSpreader, m, o)
            if not ok then m = nil end
        end
        if m ~= nil then
            t.main = m.fill ~= nil and fillOf(o, m.fill.idx or call(o, "getSprayerFillUnitIndex") or o.spec_sprayer.fillUnitIndex) or nil
            if t.main == nil and m.fill ~= nil then
                t.main = { level = m.fill.level, cap = m.fill.cap, ft = m.fill.ft, frac = clamp(m.fill.level / m.fill.cap, 0, 1), title = m.fill.title }
            end
            t.dose, t.doseKg, t.haLeft, t.solid = m.dose, m.doseKg, m.haLeft, m.solid
        end
        t.doubled = o.spec_sprayer.doubledAmountIsActive == true
        local okP, pf = pcall(readSprayPF, o)
        if okP then t.pf = pf elseif not self.loggedPF then self.loggedPF = true; log("ERREUR Precision Farming (dose) : %s", tostring(pf)) end
    elseif k == "forageWagon" or k == "mixer" or k == "trailer" or k == "harvester" then
        local best
        for _, f in ipairs(t.fills) do if best == nil or f.cap > best.cap then best = f end end
        t.main = best
        if t.main ~= nil then
            local mpl = massPerLiter(t.main.ft)
            if mpl ~= nil and t.main.level > 0 then t.mainT = t.main.level * mpl end
        end
    elseif k == "header" then
        if d.mach ~= nil and d.mach.crop ~= nil then t.crop = d.mach.crop end
    end
    -- mode de travail (faucheuse, outil de sol...)
    local wm = o.spec_workMode
    if wm ~= nil and (wm.stateMax or 0) > 1 and type(wm.workModes) == "table" then
        local mode = wm.workModes[wm.state or 1]
        t.mode = mode ~= nil and (mode.name or tostring(wm.state)) or tostring(wm.state)
    end
    local mw = o.spec_mower
    if mw ~= nil and mw.toggleWindrowDropEnableText ~= nil and mw.toggleWindrowDropDisableText ~= nil then
        t.swathGrouped = mw.useWindrowDropAreas == true
    end
    local rm = o.spec_ridgeMarker
    if rm ~= nil and (rm.numRigdeMarkers or 0) > 0 then t.markers = rm.ridgeMarkerState or 0 end
    local vw = o.spec_variableWorkWidth
    if vw ~= nil and o.getVariableWorkWidth ~= nil and type(vw.sectionsLeft) == "table" and type(vw.sectionsRight) == "table"
        and (#vw.sectionsLeft + #vw.sectionsRight) > 0 then
        local l, lm = call(o, "getVariableWorkWidth", true)
        local r, rmx = call(o, "getVariableWorkWidth", false)
        if l ~= nil and r ~= nil and (lm or 0) + (rmx or 0) > 0 then t.sections = clamp((l + r) / (lm + rmx), 0, 1) end
    end
    local sp = o.spec_plow
    if sp ~= nil then
        if sp.rotationPart ~= nil and sp.rotationPart.turnAnimation ~= nil then t.plowTurned = sp.rotationMax == true end
        t.plowLimit = sp.limitToField == true
        t.plowLimitForced = o.getPlowForceLimitToField ~= nil and call(o, "getPlowForceLimitToField") == true
    end
    -- benne, bâche
    if o.spec_trailer ~= nil and o.spec_dischargeable ~= nil and o.getDischargeState ~= nil then
        local spT = o.spec_trailer
        local tipSides = spT.tipSides or {}
        local s = tipSides[spT.preferedTipSideIndex or 1]
        t.tip = { state = call(o, "getDischargeState") or 0, side = s ~= nil and (s.name or "") or "", sides = #tipSides }
    end
    if o.spec_cover ~= nil and o.spec_cover.covers ~= nil and #o.spec_cover.covers > 0 then t.cover = (o.spec_cover.state or 0) ~= 0 end
    -- alertes : plein / vide / panne
    t.alerts = {}
    local function alert(txt, col) t.alerts[#t.alerts + 1] = { txt, col } end
    if t.ads >= 2 then alert(T("al_fault"), "red") elseif t.ads == 1 then alert(T("al_soon"), "amber") end
    local collect = k == "baleLoader" or k == "forageWagon" or k == "trailer" or k == "harvester" or k == "mixer"
    local spend = k == "seeder" or k == "sprayer"
    if t.main ~= nil then
        if collect and t.main.frac >= 0.98 then alert(T("al_full"), "red")
        elseif collect and t.main.frac >= 0.9 then alert(string.format("%s %d %%", T("tt_load"), math.floor(t.main.frac * 100 + 0.5)), "amber") end
        if spend and t.main.frac <= 0.02 then alert(string.format(T("al_emptyX"), k == "seeder" and T("tt_hopper") or T("tt_tank")), "red")
        elseif spend and t.main.frac < 0.1 then alert(string.format("%s %d %%", k == "seeder" and T("tt_hopper") or T("tt_tank"), math.floor(t.main.frac * 100 + 0.5)), "amber") end
    end
    if t.fert ~= nil and t.fert.frac <= 0.02 then alert(string.format(T("al_emptyX"), T("tt_fert")), "red") end
    for _, c in ipairs(t.cons or {}) do
        if c.level <= 0 then alert(string.format(T("al_emptyX"), T("tt_" .. c.key)), "red") end
    end
    return t
end

-- liste des onglets du véhicule (machine elle-même, puis de l'avant vers l'arrière), relue avec les données
function AS_TerminalTools:read(v, d)
    local ui = U()
    local list = {}
    local m = d.mach
    if m ~= nil and m.obj == v then list[#list + 1] = self:readTool(v, d, v, true) end
    local others = {}
    for _, o in ipairs(ui.trainOf(v)) do
        if o ~= v and not AS_TerminalTools.isWeight(o) then others[#others + 1] = self:readTool(v, d, o, false) end
    end
    table.sort(others, function(a, b) return (a.z or 0) > (b.z or 0) end)
    for _, t in ipairs(others) do list[#list + 1] = t end
    d.toolTabs = list
    -- outil affiché : celui choisi s'il est encore attelé, sinon celui qui travaille, sinon la machine, sinon le premier
    local pick
    local s = self.sel[v]
    for i, t in ipairs(list) do if t.o == s then pick = i end end
    if pick == nil then
        for i, t in ipairs(list) do if pick == nil and t.working then pick = i end end
        for i, t in ipairs(list) do if pick == nil and m ~= nil and t.o == m.obj then pick = i end end
        if pick == nil and #list > 0 then pick = 1 end
    end
    d.toolSel = pick
    self.shown[v] = pick ~= nil and list[pick].o or nil
end

-------------------------------------------------------------------------------
-- images : en 2D un calque par fichier, en 3D une pièce de la tablette (TerminalTablet)
-------------------------------------------------------------------------------
function AS_TerminalTools:overlay(file)
    if file == nil or createImageOverlay == nil then return nil end
    self.ovs = self.ovs or {}
    local ov = self.ovs[file]
    if ov == nil then
        ov = false
        local ok, o = pcall(createImageOverlay, file)
        if ok and o ~= nil and o ~= 0 then
            ov = o
            pcall(setOverlayColor, o, 1, 1, 1, 1)
        else
            log("image du magasin introuvable : %s", tostring(file))
        end
        self.ovs[file] = ov
    end
    return ov or nil
end

function AS_TerminalTools:deleteMap()
    for _, o in pairs(self.ovs or {}) do if o then pcall(delete, o) end end
    self.ovs = nil
    self.counters = {}
end

-------------------------------------------------------------------------------
-- tuiles et touches selon l'outil
-------------------------------------------------------------------------------
local function tArea(t, tl)
    tl[#tl + 1] = { T("tt_area"), f2(t.cnt.ha), "ha", reset = "t_cntReset", sub = t.cnt.ms > 60000 and
        string.format("%s ha/h", f1(t.cnt.ha / (t.cnt.ms / 3600000))) or nil }
end
-- 1254300 -> "1 254 300"
local function grouped(n)
    local s = string.format("%d", math.floor((n or 0) + 0.5))
    local out = s:reverse():gsub("(%d%d%d)", "%1 "):reverse()
    return (out:gsub("^ ", ""))
end
AS_TerminalTools.grouped = grouped
local function tHours(t, tl) tl[#tl + 1] = { T("tt_hours"), hm(t.cnt.ms), "h" } end
local function tWidth(t, tl)
    if t.width == nil then return end
    tl[#tl + 1] = { T("tt_width"), f1(t.width), "m", sub = t.sections ~= nil and string.format("%s %d %%", T("tt_sections"), math.floor(t.sections * 100 + 0.5)) or nil,
        frac = t.sections, col = t.sections ~= nil and t.sections < 0.999 and "amber" or nil }
end
local function tFill(tl, title, f, showT)
    if f == nil then return end
    local val = string.format("%d", math.floor(f.frac * 100 + 0.5))
    local sub = f.title
    if showT ~= nil then sub = string.format("%s  %s t", f.title, f1(showT))
    else sub = string.format("%s  %d l", f.title, math.floor(f.level + 0.5)) end
    tl[#tl + 1] = { title, val, "%", frac = f.frac, sub = sub }
end

function AS_TerminalTools:tiles(t)
    local tl, k = {}, t.kind
    if k == "baler" then
        if t.bales ~= nil then
            tl[#tl + 1] = { T("tt_bales"), tostring(t.bales), "", sub = string.format(T("tt_balesTotal"), t.balesTotal or 0), reset = "t_breset" }
        end
        if t.main ~= nil then tl[#tl + 1] = { T("tt_bale"), string.format("%d", math.floor(t.main.frac * 100 + 0.5)), "%", frac = t.main.frac, sub = t.main.title } end
        local b = t.bale
        if b ~= nil then
            -- carrée : longueur en grand, section en petit ; ronde : diamètre
            local val = t.round and string.format("Ø %s", f2(b.diameter)) or f2(b.length)
            local sub = (not t.round) and string.format("%d × %d cm", math.floor(b.width * 100 + 0.5), math.floor(b.height * 100 + 0.5)) or nil
            if t.balePre ~= nil then sub = string.format("-> %s m", t.round and f2(t.balePre.diameter) or f2(t.balePre.length)) end
            tl[#tl + 1] = { T("tt_format"), val, "m", sub = sub, col = t.balePre ~= nil and "amber" or nil }
        end
        tl[#tl + 1] = { T("tt_eject"), t.autoDrop and T("tt_auto") or T("tt_manual"), "", col = t.autoDrop and "lamp" or nil }
    elseif k == "baleLoader" then
        if t.main ~= nil then
            tl[#tl + 1] = { T("tt_bales"), string.format("%d / %d", math.floor(t.main.level + 0.5), math.floor(t.main.cap + 0.5)), "", frac = t.main.frac }
        end
        tl[#tl + 1] = { T("tt_pos"), t.workPos and T("tt_work") or T("tt_transport"), "", col = t.workPos and "lamp" or nil }
        tl[#tl + 1] = { T("tt_unload"), t.emptying and T("tt_running") or "-", "", col = t.emptying and "amber" or nil }
    elseif k == "wrapper" then
        tl[#tl + 1] = { T("tt_wrap"), t.wrapReady and T("tt_ready") or (t.wrapping and T("tt_running") or T("tt_waiting")), "",
            col = t.wrapReady and "lamp" or (t.wrapping and "amber" or nil) }
        tl[#tl + 1] = { T("tt_eject"), t.autoDrop and T("tt_auto") or T("tt_manual"), "", col = t.autoDrop and "lamp" or nil }
    elseif k == "seeder" then
        tl[#tl + 1] = { T("tt_seed"), t.seed or "-", "", icon = t.seedIcon }
        if t.pfSeed ~= nil and t.pfSeed.supported and t.pfSeed.perSqm ~= nil then
            tl[#tl + 1] = { T("pf_seeds"), grouped(t.cnt.seeds or 0), "", reset = "t_cntReset" }
        end
        tFill(tl, T("tt_hopper"), t.main)
        if t.fert ~= nil then tFill(tl, T("tt_fert"), t.fert) end
        if t.markers ~= nil then
            tl[#tl + 1] = { T("tt_markers"), t.markers == 0 and T("tt_mkOff") or (t.markers == 1 and T("tt_mkLeft") or T("tt_mkRight")), "",
                col = t.markers ~= 0 and "lamp" or nil }
        end
    elseif k == "sprayer" then
        if t.main ~= nil then
            tl[#tl + 1] = { T("tt_product"), t.main.title, "", icon = fillIcon(t.main.ft) }
            local mpl = t.solid and massPerLiter(t.main.ft) or nil
            tFill(tl, T("tt_tank"), t.main, mpl ~= nil and t.main.level * mpl or nil)
        end
        if t.dose ~= nil and t.pf == nil then
            local val = t.doseKg ~= nil and string.format("%d", math.floor(t.doseKg + 0.5)) or f1(t.dose)
            tl[#tl + 1] = { T("tt_dose"), val, t.doseKg ~= nil and "kg/ha" or "l/ha", sub = t.doubled and "× 2" or nil, col = t.doubled and "amber" or nil }
        end
        if t.haLeft ~= nil then tl[#tl + 1] = { T("tt_haLeft"), f1(t.haLeft), "ha" } end
    elseif k == "forageWagon" or k == "mixer" or k == "trailer" or k == "harvester" then
        tFill(tl, T("tt_load"), t.main, t.mainT)
        if t.tip ~= nil then
            tl[#tl + 1] = { T("tt_tip"), t.tip.state ~= 0 and T("tipOn") or T("tipOff"), "", sub = t.tip.sides > 1 and t.tip.side or nil,
                col = t.tip.state ~= 0 and "amber" or nil }
        end
        if t.cover ~= nil then tl[#tl + 1] = { T("tt_cover"), t.cover and T("coverIsOpen") or T("coverIsClosed"), "", col = t.cover and "lamp" or nil } end
    elseif k == "header" then
        tl[#tl + 1] = { T("tt_crop"), t.crop or "-", "" }
    elseif k == "plow" then
        if t.plowTurned ~= nil then tl[#tl + 1] = { T("tt_side"), t.plowTurned and T("tt_turned") or T("tt_normal"), "" } end
        tl[#tl + 1] = { T("tt_limit"), t.plowLimit and T("on") or T("off"), "", col = t.plowLimit and "lamp" or nil }
    end
    if t.swathGrouped ~= nil then tl[#tl + 1] = { T("tt_swath"), t.swathGrouped and T("tt_grouped") or T("tt_spread"), "" } end
    if t.mode ~= nil then tl[#tl + 1] = { T("tt_mode"), t.mode, "" } end
    for _, c in ipairs(t.cons or {}) do
        tl[#tl + 1] = { T("tt_" .. c.key), string.format("%d / %d", math.floor(c.level + 0.5), math.floor(c.cap + 0.5)), T("tt_rolls"),
            frac = c.level / c.cap, col = c.level <= 0 and "red" or nil }
    end
    -- toujours : largeur, surface, heures (compteurs de l'outil)
    if k ~= "trailer" and k ~= "mixer" and k ~= "baleLoader" and k ~= "wrapper" then tWidth(t, tl) end
    if k ~= "trailer" and k ~= "mixer" then tArea(t, tl) end
    tHours(t, tl)
    return tl
end

-- touches de droite : { action, libellé, allumée, état }
function AS_TerminalTools:keys(t)
    local ks, k = {}, t.kind
    local function add(a, label, on, state) ks[#ks + 1] = { a, label, on == true, state } end
    if t.canLower then
        add(t.self and "m_lift" or "t_lift", t.lowered and T("doRaise") or T("doLower"), t.lowered, t.lowered and T("lowered") or T("raised"))
    end
    if t.on ~= nil then add("t_on", t.on and T("doOff") or T("doOn"), t.on, t.on and T("on") or T("off")) end
    if t.unfolded ~= nil then add("t_fold", t.unfolded and T("doFold") or T("doUnfold"), t.unfolded, t.unfolded and T("unfolded") or T("folded")) end
    if k == "baler" then
        if t.canEject then add("t_bdrop", T("k_eject"), false, nil) end
        if t.canAutoToggle then add("t_bauto", T("k_ejectAuto"), t.autoDrop, t.autoDrop and T("tt_auto") or T("tt_manual")) end
        if t.nBaleTypes > 1 then
            local b = t.balePre or t.bale
            add("t_bsize", T("k_size"), false, b ~= nil and (t.round and string.format("Ø %s m", f2(b.diameter)) or string.format("%s m", f2(b.length))) or nil)
        end
        if t.bales ~= nil then add("t_breset", T("k_resetBales"), false, nil) end
    elseif k == "baleLoader" then
        add("t_blwork", T("tt_pos"), t.workPos, t.workPos and T("tt_work") or T("tt_transport"))
        add("t_blempty", T("k_unload"), t.emptying, nil)
    elseif k == "wrapper" then
        if t.canAutoToggle then add("t_wauto", T("k_ejectAuto"), t.autoDrop, t.autoDrop and T("tt_auto") or T("tt_manual")) end
        if t.wrapReady then add("t_wdrop", T("k_drop"), false, nil) end
    elseif k == "seeder" then
        if (t.nSeeds or 0) > 1 then add("t_seed", T("k_seed"), false, t.seed) end
        if t.markers ~= nil then add("t_ridge", T("k_markers"), t.markers ~= 0, t.markers == 0 and T("tt_mkOff") or (t.markers == 1 and T("tt_mkLeft") or T("tt_mkRight"))) end
    elseif k == "sprayer" then
        add("t_double", T("k_double"), t.doubled, t.doubled and T("on") or T("off"))
    elseif k == "plow" then
        if t.plowTurned ~= nil then add("t_turn", T("k_turn"), false, t.plowTurned and T("tt_turned") or T("tt_normal")) end
        if not t.plowLimitForced then add("t_plimit", T("k_limit"), t.plowLimit, t.plowLimit and T("on") or T("off")) end
    end
    if t.swathGrouped ~= nil then add("t_mdrop", T("k_swath"), t.swathGrouped, t.swathGrouped and T("tt_grouped") or T("tt_spread")) end
    if t.mode ~= nil then add("t_mode", T("k_mode"), false, t.mode) end
    if t.sections ~= nil then add("t_sect", T("k_sections"), t.sections < 0.999, string.format("%d %%", math.floor(t.sections * 100 + 0.5))) end
    if t.tip ~= nil then
        add("t_tip", t.tip.state ~= 0 and T("tipStop") or T("tipGo"), t.tip.state ~= 0, t.tip.state ~= 0 and T("tipOn") or T("tipOff"))
        if t.tip.sides > 1 then add("t_tipSide", T("tipSide"), false, t.tip.side) end
    end
    if t.cover ~= nil then add("t_cover", t.cover and T("coverClose") or T("coverOpen"), t.cover, t.cover and T("coverIsOpen") or T("coverIsClosed")) end
    return ks
end

-------------------------------------------------------------------------------
-- dessin de la page
-------------------------------------------------------------------------------
local function colOf(C, name)
    if name == nil then return C.white end
    return C[name] or C.white
end

local function tile(ctx, C, x, y, w, h, tl, idx)
    ctx.rect(x, y, w, h, C.box)
    if tl.icon ~= nil then
        ctx.image(x + w - 40, y + 18, 32, 32, ctx.rec == nil and AS_TerminalTools:overlay(tl.icon) or nil, "imgTuile" .. (idx or 1), tl.icon)
    end
    ctx.text(x + 8, y + 15, 11, tl[1], C.gray, nil, true)
    local val = tostring(tl[2] or "-")
    local vlen = utf8Strlen ~= nil and utf8Strlen(val) or #val
    local size = vlen > 14 and 13 or (vlen > 9 and 16 or 20)
    local unitW = (tl[3] ~= nil and tl[3] ~= "") and 34 or 0
    val = cut(val, math.floor((w - 16 - unitW) / (size * 0.62)))
    ctx.text(x + 8, y + 42, size, val, colOf(C, tl.col), nil, true)
    if unitW > 0 then ctx.text(x + w - 8, y + 42, 12, tl[3], C.gray, RenderText.ALIGN_RIGHT) end
    local rw = 0
    if tl.reset ~= nil then
        rw = 40
        ctx.button(x + w - 40, y + 3, 36, 17, tl.reset, false)
        ctx.text(x + w - 22, y + 15, 9, T("tt_reset"), C.white, RenderText.ALIGN_CENTER, true)
    end
    if tl.sub ~= nil then
        ctx.text(x + w - 8 - rw, y + 15, 10, cut(tl.sub, math.floor((w - 90 - rw) / 6)), C.gray, RenderText.ALIGN_RIGHT)
    end
    if tl.frac ~= nil then U().bar(ctx, x + 8, y + h - 11, w - 16, 6, tl.frac, colOf(C, tl.col ~= nil and tl.col or "blue")) end
end

-- onglets en haut du contenu
function AS_TerminalTools:drawTabs(AS_T, d, ctx)
    local C = U().C
    local list = d.toolTabs
    local n = math.min(#list, self.MAX_TABS)
    local gap = 4
    local tw = (ctx.cw - 12 - (n - 1) * gap) / n
    local y = ctx.cy + 6
    for i = 1, n do
        local t = list[i]
        local x = ctx.cx + 6 + (i - 1) * (tw + gap)
        local active = i == d.toolSel
        ctx.button(x, y, tw, 34, "tool_" .. i, active)
        if t.working then ctx.rect(x, y + 31, tw, 3, C.lamp) end
        local tx = x + 6
        if t.img ~= nil then
            ctx.image(x + 3, y + 2, 30, 30, ctx.rec == nil and self:overlay(t.img) or nil, "imgOnglet" .. i, t.img)
            tx = x + 37
        end
        local room = math.floor((x + tw - 4 - tx) / 6)
        ctx.text(tx, y + 14, 11, cut(kindLabel(t), room - (t.side ~= nil and 3 or 0)), C.white, nil, true)
        if t.side ~= nil then ctx.text(x + tw - 5, y + 14, 10, T("side" .. t.side), active and C.white or C.gray, RenderText.ALIGN_RIGHT, true) end
        ctx.text(tx, y + 28, 10, cut(t.name, room), active and C.white or C.gray)
    end
end

-- (01/11) Case IH : liste « Universal Terminal » à gauche (un outil par ligne, image + nom),
-- la page de l'outil choisi à droite, comme sur le vrai AFS Pro 1200
AS_TerminalTools.CASE_LIST_W = 150
function AS_TerminalTools:drawCaseList(AS_T, d, ctx)
    local C = U().C
    local list = d.toolTabs
    local n = math.min(#list, self.MAX_TABS)
    local x, w = ctx.cx + 4, self.CASE_LIST_W
    ctx.rect(x, ctx.cy + 4, w, ctx.ch - 8, C.box)
    ctx.rect(x, ctx.cy + 4, w, 24, C.boxHi)
    ctx.text(x + 8, ctx.cy + 21, 11, T("ut_title"), C.white, nil, true, w - 12)
    local eh = math.min(58, (ctx.ch - 40 - (n - 1) * 4) / math.max(1, n))
    for i = 1, n do
        local t = list[i]
        local y = ctx.cy + 32 + (i - 1) * (eh + 4)
        local active = i == d.toolSel
        ctx.button(x + 2, y, w - 4, eh, "tool_" .. i, active)
        if active then ctx.rect(x + w - 6, y + eh * 0.5 - 6, 6, 12, C.screen) end
        if t.working then ctx.rect(x + 2, y + eh - 3, w - 4, 3, C.lamp) end
        local tx = x + 8
        if t.img ~= nil then
            local s = math.min(40, eh - 8)
            ctx.image(x + 6, y + (eh - s) * 0.5, s, s, ctx.rec == nil and self:overlay(t.img) or nil, "imgOnglet" .. i, t.img)
            tx = x + 10 + s
        end
        local room = x + w - 8 - tx
        ctx.text(tx, y + eh * 0.5 - 2, 11, kindLabel(t), active and { 1, 1, 1, 1 } or C.white, nil, true, room)
        ctx.text(tx, y + eh * 0.5 + 12, 10, t.name, active and { 1, 1, 1, 1 } or C.gray, nil, nil, room)
    end
end

-- (02/11) tracteur Case IH : page Isobus comme le vrai Universal Terminal de l'AFS Pro (les photos 2, 5 et 12) :
-- liste des appareils ISOBUS à gauche (Tractor ECU, puis chaque outil, l'outil choisi en bleu avec son chevron),
-- écran de l'outil au centre sous un bandeau sombre à son nom, colonne de touches à droite avec ▲ / ▼
AS_TerminalTools.UT_LIST_W, AS_TerminalTools.UT_KEYS_W = 128, 90
AS_TerminalTools.keyOff = {}
local UT_BLUE, UT_DARK, UT_LIST, UT_CARD, UT_TXT, UT_KEY, UT_KEYS_BG = { 0.11, 0.33, 0.60, 1 }, { 0.22, 0.24, 0.27, 1 },
    { 0.89, 0.90, 0.91, 1 }, { 0.97, 0.97, 0.97, 1 }, { 0.10, 0.12, 0.15, 1 }, { 0.88, 0.89, 0.90, 1 }, { 0.30, 0.32, 0.35, 1 }
local function utTriangle(ctx, xc, y, up, col)
    for k = 0, 5 do
        local w = 2 + k * 2.4
        ctx.rect(xc - w * 0.5, y + (up and k or 5 - k) * 2, w, 2, col)
    end
end
function AS_TerminalTools:drawCaseUT(AS_T, d, ctx, v)
    local list = d.toolTabs
    local n = math.min(#list, self.MAX_TABS)
    local cx, cy, ch = ctx.cx, ctx.cy, ctx.ch
    local LW, KW = self.UT_LIST_W, self.UT_KEYS_W
    local rx = ctx.cx + ctx.cw - KW
    -- liste des appareils
    ctx.rect(cx, cy, LW, ch, UT_LIST)
    ctx.rect(cx + LW - 2, cy, 2, ch, { 0.75, 0.76, 0.78, 1 })
    local eh = math.min(54, (ch - 8 - n * 4) / (n + 1))
    local y = cy + 4
    -- Tractor ECU : le tracteur lui-même (image du magasin, nom, marque)
    ctx.rect(cx + 4, y, LW - 10, eh, UT_CARD)
    local vImg = v ~= nil and self.storeImage(v) or nil
    local tx = cx + 8
    if vImg ~= nil then
        local sz = math.min(40, eh - 8)
        ctx.image(cx + 6, y + (eh - sz) * 0.5, sz, sz, ctx.rec == nil and self:overlay(vImg) or nil, "imgUTtracteur", vImg)
        tx = cx + 10 + sz
    end
    local room = cx + LW - 10 - tx
    local vName = v ~= nil and U().vehicleName(v) or ""
    local vBrand = v ~= nil and select(1, brandTitle(v, storeItem(v))) or nil
    ctx.text(tx, y + 16, 9, cut(vName, math.floor(room / 5.5)), UT_TXT, nil, true, room)
    ctx.text(tx, y + 28, 8, "Tractor ECU", { 0.45, 0.47, 0.50, 1 }, nil, nil, room)
    if vBrand ~= nil and vBrand ~= "" then ctx.text(tx, y + 39, 8, vBrand, { 0.45, 0.47, 0.50, 1 }, nil, nil, room) end
    for i = 1, n do
        local t = list[i]
        y = cy + 4 + i * (eh + 4)
        local active = i == d.toolSel
        ctx.button(cx + 4, y, LW - 10, eh, "tool_" .. i, active)
        ctx.rect(cx + 4, y, LW - 10, eh, active and UT_BLUE or UT_CARD)
        if active then
            -- chevron du vrai terminal : l'entrée bleue pointe vers l'écran de l'outil
            for k = 0, 5 do ctx.rect(cx + LW - 6 + k * 4, y + k * (eh / 12), 4, eh - k * (eh / 6), UT_BLUE) end
        end
        if t.working then ctx.rect(cx + 4, y + eh - 3, LW - 10, 3, { 0.35, 0.80, 0.25, 1 }) end
        tx = cx + 8
        if t.img ~= nil then
            local sz = math.min(40, eh - 8)
            ctx.image(cx + 6, y + (eh - sz) * 0.5, sz, sz, ctx.rec == nil and self:overlay(t.img) or nil, "imgUT" .. i, t.img)
            tx = cx + 10 + sz
        end
        room = cx + LW - 10 - tx
        local col = active and { 1, 1, 1, 1 } or UT_TXT
        local col2 = active and { 0.85, 0.90, 1, 1 } or { 0.45, 0.47, 0.50, 1 }
        ctx.text(tx, y + 16, 9, cut(t.name, math.floor(room / 5.5)), col, nil, true, room)
        ctx.text(tx, y + 28, 8, kindLabel(t), col2, nil, nil, room)
        if t.brand ~= nil and t.brand ~= "" then ctx.text(tx, y + 39, 8, t.brand, col2, nil, nil, room) end
    end
    -- bandeau au nom de l'outil choisi, avec le nombre d'alertes
    local t = list[d.toolSel or 1]
    local mx = cx + LW + 22
    local mw = rx - 6 - mx
    ctx.rect(mx, cy, mw, 26, UT_DARK)
    if t ~= nil then
        ctx.text(mx + 8, cy + 18, 13, cut(t.name, math.floor((mw - 60) / 8)), { 1, 1, 1, 1 }, nil, true, mw - 60)
        if #t.alerts > 0 then
            ctx.rect(mx + mw - 44, cy + 6, 14, 14, { 0.95, 0.60, 0.10, 1 })
            ctx.text(mx + mw - 37, cy + 17, 10, "!", { 1, 1, 1, 1 }, RenderText.ALIGN_CENTER, true)
            ctx.text(mx + mw - 20, cy + 18, 12, tostring(#t.alerts), { 1, 1, 1, 1 }, RenderText.ALIGN_CENTER, true)
        end
    end
    -- colonne de touches à droite : ▲, touches de l'outil, ▼
    ctx.rect(rx, cy, KW, ch, UT_KEYS_BG)
    local ks = t ~= nil and self:keys(t) or {}
    local kh, kg = 42, 4
    local nVis = math.max(1, math.floor((ch - 40 + kg) / (kh + kg)))
    local off = self.keyOff[v] or 0
    if off > math.max(0, #ks - nVis) then off = math.max(0, #ks - nVis); self.keyOff[v] = off end
    local canUp, canDn = off > 0, off + nVis < #ks
    if canUp then ctx.button(rx, cy, KW, 20, "t_utup", false) end
    if canDn then ctx.button(rx, cy + ch - 20, KW, 20, "t_utdn", false) end
    utTriangle(ctx, rx + KW * 0.5, cy + 4, true, canUp and { 1, 1, 1, 1 } or { 0.5, 0.52, 0.55, 1 })
    utTriangle(ctx, rx + KW * 0.5, cy + ch - 16, false, canDn and { 1, 1, 1, 1 } or { 0.5, 0.52, 0.55, 1 })
    for j = 1, nVis do
        local kk = ks[off + j]
        if kk == nil then break end
        local ky = cy + 20 + (j - 1) * (kh + kg)
        ctx.button(rx + 6, ky, KW - 12, kh, kk[1], kk[3])
        ctx.rect(rx + 6, ky, KW - 12, kh, kk[3] and UT_BLUE or UT_KEY)
        local col = kk[3] and { 1, 1, 1, 1 } or UT_TXT
        ctx.text(rx + KW * 0.5, ky + (kk[4] ~= nil and 17 or 25), 9, kk[2], col, RenderText.ALIGN_CENTER, true, KW - 16)
        if kk[4] ~= nil then ctx.text(rx + KW * 0.5, ky + 33, 8, kk[4], kk[3] and { 0.85, 0.90, 1, 1 } or { 0.40, 0.42, 0.45, 1 }, RenderText.ALIGN_CENTER, nil, KW - 16) end
    end
    return mx, mw, cy + 26
end

-------------------------------------------------------------------------------
-- (04/11) cadres Precision Farming au-dessus des tuiles, à la manière des écrans
-- ISOBUS (Claas, Case) : dose avec − / + et AUTO / MANU, azote ou pH visé
-------------------------------------------------------------------------------
local PF_GREEN = { 0.35, 0.80, 0.25, 1 }
local function pfBtn(ctx, C, x, y, w, h, action, on, label, enabled)
    if enabled ~= false then ctx.button(x, y, w, h, action, on) end
    local bg = on and UT_BLUE or (ctx.caseUT and UT_KEY or { 0.24, 0.26, 0.30, 1 })
    ctx.rect(x, y, w, h, bg, enabled == false and 0.45 or 1)
    local col = on and { 1, 1, 1, 1 } or (ctx.caseUT and UT_TXT or C.white)
    if enabled == false then col = C.gray end
    local sz = h >= 26 and (label == "-" and 24 or 15) or 10
    ctx.text(x + w * 0.5, y + h * 0.5 + (label == "-" and 6 or 4), sz, label, col, RenderText.ALIGN_CENTER, true, w - 4)
end
local function pfModeKeys(ctx, C, x, y, w, auto, aAuto, aMan, canAuto)
    local bw = 46
    pfBtn(ctx, C, x + w - 2 * bw - 10, y + 4, bw, 18, aAuto, auto, T("pf_auto"), canAuto ~= false)
    pfBtn(ctx, C, x + w - bw - 6, y + 4, bw, 18, aMan, not auto, T("pf_manu"))
end
-- cadre « dose » : titre, AUTO / MANU, puis − valeur + ; sous-ligne en petit
local function pfDoseBox(ctx, C, x, y, w, h, title, val, unit, auto, acts, canAuto, canDn, canUp, sub, subCol)
    ctx.rect(x, y, w, h, C.box)
    ctx.text(x + 8, y + 15, 11, title, C.gray, nil, true, w - 120)
    pfModeKeys(ctx, C, x, y, w, auto, acts[1], acts[2], canAuto)
    local by, bs = y + 26, 28
    pfBtn(ctx, C, x + 8, by, bs, bs, acts[3], false, "-", not auto and canDn)   -- « - » : la police du jeu n'a pas « − »
    pfBtn(ctx, C, x + w - 8 - bs, by, bs, bs, acts[4], false, "+", not auto and canUp)
    local mid = x + w * 0.5
    local vs = tostring(val or "-")
    local unitW = (unit ~= nil and unit ~= "") and (#unit * 6 + 6) or 0
    ctx.text(mid - unitW * 0.5, by + 21, 20, vs, C.white, RenderText.ALIGN_CENTER, true, w - 2 * bs - 40 - unitW)
    if unitW > 0 then
        local vlen = utf8Strlen ~= nil and utf8Strlen(vs) or #vs
        ctx.text(mid - unitW * 0.5 + vlen * 6.4 + 4, by + 21, 11, unit, C.gray)
    end
    if auto then ctx.text(x + 8 + bs + 6, by + 10, 8, T("pf_auto"), PF_GREEN, nil, true) end
    if sub ~= nil then ctx.text(mid, y + h - 5, 9, cut(sub, math.floor((w - 16) / 5.2)), subCol or C.gray, RenderText.ALIGN_CENTER) end
end
local function fmtV(fmt, v)
    if v == nil then return "-" end
    if fmt == "%d" then return string.format("%d", math.floor(v + 0.5)) end
    return string.format(fmt or "%.1f", v)
end
-- azote / pH : actuel -> visé, barre (actuel gris, après passage bleu, repère vert = visé)
local function pfSoilBox(ctx, C, x, y, w, h, p)
    ctx.rect(x, y, w, h, C.box)
    local lime = p.kind == "lime"
    ctx.text(x + 8, y + 15, 11, lime and T("pf_ph") or T("pf_nitrogen"), C.gray, nil, true, w * 0.5)
    if p.soil ~= nil then ctx.text(x + w - 8, y + 15, 9, cut(p.soil, math.floor(w * 0.45 / 5.2)), C.gray, RenderText.ALIGN_RIGHT) end
    if p.cur == nil or p.goal == nil then
        ctx.text(x + w * 0.5, y + 36, 11, p.onField and "-" or T("pf_notOnField"), C.gray, RenderText.ALIGN_CENTER, true)
        return
    end
    local f = lime and "%.1f" or "%d"
    local u = lime and "" or " kg N/ha"
    local reached = p.cur >= p.goal - (lime and 0.05 or 1)
    local line = string.format("%s %s   ->   %s %s%s", T("pf_actual"), fmtV(f, p.cur), T("pf_target"), fmtV(f, p.goal), u)
    ctx.text(x + w * 0.5, y + 33, 12, reached and T("pf_reached") or line, reached and PF_GREEN or C.white, RenderText.ALIGN_CENTER, true, w - 16)
    local lo, hi
    if lime then lo, hi = 4, 8 else lo, hi = 0, math.max(p.goal, p.after or 0, p.cur) * 1.15 + 1 end
    local function fx(vv) return clamp((vv - lo) / (hi - lo), 0, 1) end
    local bx, bw, byy = x + 8, w - 16, y + h - 12
    ctx.rect(bx, byy, bw, 6, { 0.5, 0.52, 0.55, 0.35 })
    if p.after ~= nil and p.after > p.cur then ctx.rect(bx, byy, bw * fx(p.after), 6, C.blue) end
    ctx.rect(bx, byy, bw * fx(p.cur), 6, { 0.55, 0.57, 0.60, 1 })
    ctx.rect(bx + bw * fx(p.goal) - 1, byy - 3, 3, 12, PF_GREEN)
end
local RATE_KEYS = { "pf_low", "pf_std", "pf_high" }
-- semoir : densité de semis (3 paliers), engrais ; épandeur : dose + sol. Renvoie la hauteur prise.
function AS_TerminalTools:drawPF(ctx, C, t, x, y, w)
    local yy, gap = y, 6
    local s = t.kind == "seeder" and t.pfSeed or nil
    if s ~= nil then
        local val, unit = "-", ""
        if s.supported and s.rate ~= nil then
            if s.fmt ~= nil then
                local ok, str = pcall(string.format, s.fmt, s.rate)
                val = ok and str or tostring(s.rate)
            else
                val = string.format("%.1f", s.rate)
            end
        end
        local sub
        if not s.supported then sub = T("pf_na")
        else
            local cur = RATE_KEYS[s.idx or 0]
            sub = cur ~= nil and T(cur) or nil
            if s.rec ~= nil and RATE_KEYS[s.rec] ~= nil and not s.auto then
                sub = string.format("%s   ·   %s : %s", sub or "-", T("pf_reco"), T(RATE_KEYS[s.rec]))
            end
        end
        local h = s.supported and 78 or 70
        pfDoseBox(ctx, C, x, yy, w, h, T("pf_seedRate"), val, unit, s.auto, { "t_srAuto", "t_srMan", "t_srDn", "t_srUp" }, s.supported,
            (s.idx or 0) > (s.min or 1), (s.idx or 0) < (s.max or 3), sub, (s.rec ~= nil and s.idx == s.rec) and PF_GREEN or nil)
        -- paliers : 3 points sous la valeur
        if s.supported then
            for i = 1, 3 do
                local dx = x + w * 0.5 + (i - 2) * 16 - 4
                ctx.rect(dx, yy + 53, 8, 4, i <= (s.idx or 0) and C.blue or { 0.5, 0.52, 0.55, 0.5 })
                if s.rec == i and not s.auto then ctx.rect(dx, yy + 58, 8, 2, PF_GREEN) end
            end
        end
        yy = yy + h + gap
    end
    local p = (t.kind == "seeder" and t.pfFert) or (t.kind == "sprayer" and t.pf) or nil
    if p ~= nil then
        local h = 70
        local sub
        if t.working and p.real ~= nil then sub = string.format("%s : %s %s", T("pf_real"), fmtV(p.vfmt, p.real), p.unit) end
        local title = t.kind == "seeder" and T("pf_fertDose") or T("pf_dose")
        -- semoir : l'azote tient sur la sous-ligne
        if t.kind == "seeder" and p.cur ~= nil and p.goal ~= nil and p.kind ~= "lime" then
            local nl = string.format("N %d -> %d kg N/ha", math.floor(p.cur + 0.5), math.floor(p.goal + 0.5))
            sub = sub ~= nil and (sub .. "   ·   " .. nl) or nl
        end
        pfDoseBox(ctx, C, x, yy, w, h, title, fmtV(p.vfmt, p.set), p.unit, p.auto, { "t_pfAuto", "t_pfMan", "t_pfDn", "t_pfUp" }, p.canAuto,
            p.man > p.manMin, p.man < p.manMax, sub)
        yy = yy + h + gap
        if t.kind == "sprayer" then
            pfSoilBox(ctx, C, x, yy, w, 54, p)
            yy = yy + 54 + gap
        end
    end
    return yy - y
end

function AS_TerminalTools:draw(AS_T, d, ctx, v)
    local list = d.toolTabs
    if list == nil or #list == 0 then return false end
    local ui = U()
    local C = ui.C
    if AS_T.caseStyle and not ctx.caseInner then
        -- (02/11) le vrai Universal Terminal : liste, bandeau et touches, puis l'écran de l'outil au centre
        local mx, mw, my = self:drawCaseUT(AS_T, d, ctx, v)
        local c3 = {}
        for kk, vv in pairs(ctx) do c3[kk] = vv end
        c3.cx, c3.cw, c3.cy, c3.ch, c3.caseInner, c3.caseUT, c3.sideY = mx - 8, mw + 8, my - 38, ctx.cy + ctx.ch - my + 38, true, true, my
        return self:draw(AS_T, d, c3, v)
    end
    if not ctx.caseInner then self:drawTabs(AS_T, d, ctx) end
    local t = list[d.toolSel or 1]
    if t == nil then return true end
    -- moissonneuse, ensileuse, récolteuse : l'onglet machine existant, sous les onglets
    local mk = d.mach ~= nil and d.mach.obj == t.o and d.mach.kind or nil
    if mk ~= nil and mk ~= "spreader" and AS_TerminalMachine ~= nil then
        local c2 = {}
        for kk, vv in pairs(ctx) do c2[kk] = vv end
        c2.cy, c2.ch, c2.sideY = ctx.cy + 44, ctx.ch - 44, ctx.sideY or ctx.cy
        local ok, err = pcall(AS_TerminalMachine.draw, AS_TerminalMachine, AS_T, d, c2)
        if not ok and not self.loggedMach then self.loggedMach = true; log("ERREUR onglet machine : %s", tostring(err)) end
        return true
    end

    local x0, y0 = ctx.cx + 8, ctx.cy + 44
    -- image du magasin
    local iw = 156
    ctx.rect(x0, y0, iw, iw, C.screen)
    if t.img ~= nil then
        ctx.image(x0 + 3, y0 + 3, iw - 6, iw - 6, ctx.rec == nil and self:overlay(t.img) or nil, "imgOutil", t.img)
    else
        ctx.text(x0 + iw * 0.5, y0 + iw * 0.5 + 6, 16, kindLabel(t), C.dim, RenderText.ALIGN_CENTER, true)
    end
    -- états
    local chips = {}
    if t.canLower then chips[#chips + 1] = { t.lowered and T("lowered") or T("raised"), t.lowered == true } end
    if t.on ~= nil then chips[#chips + 1] = { t.on and T("on") or T("off"), t.on } end
    if t.unfolded ~= nil then chips[#chips + 1] = { t.unfolded and T("unfolded") or T("folded"), t.unfolded } end
    if t.working then chips[#chips + 1] = { T("tt_work"), true } end
    local cyy = y0 + iw + 6
    for i, c in ipairs(chips) do
        if i > 4 then break end
        local yy = cyy + (i - 1) * 26
        ctx.rect(x0, yy, iw, 22, C.box)
        ctx.rect(x0 + 6, yy + 7, 8, 8, c[2] and C.lamp or C.dim)
        ctx.text(x0 + 20, yy + 16, 12, c[1], c[2] and C.white or C.gray, nil, true)
    end
    -- relevage (3 points) : hauteur en bas à gauche
    local h = t.hitch
    if h ~= nil and h.own == nil and #chips < 4 then
        local yy = ctx.cy + ctx.ch - 30
        ctx.rect(x0, yy, iw, 26, C.box)
        ctx.text(x0 + 6, yy + 12, 10, string.format("%s %s", T("tt_hitch"), T("side" .. (h.front and "AV" or "AR"))), C.gray, nil, true, iw - 52)
        ctx.text(x0 + iw - 6, yy + 12, 10, string.format("%d %%", math.floor(h.up * 100 + 0.5)), C.white, RenderText.ALIGN_RIGHT, true)
        ui.bar(ctx, x0 + 6, yy + 16, iw - 12, 6, h.up, C.blue)
    end

    -- nom, marque, largeur
    local x1 = x0 + iw + 8
    local w1 = ctx.cx + ctx.cw - 8 - x1
    -- logo de la marque de l'outil à droite du nom (sinon son nom)
    local right = t.brand or ""
    local rw = #right * 7
    if ctx.caseUT then
        -- le nom est déjà dans le bandeau sombre du Universal Terminal
        rw = 0; right = ""; y0 = y0 - 20
    elseif t.brandImg ~= nil then
        rw = 48
        ctx.image(x1 + w1 - 44, y0, 44, 22, ctx.rec == nil and self:overlay(t.brandImg) or nil, "imgOutilMarque", t.brandImg)
    elseif right ~= "" then
        ctx.text(x1 + w1, y0 + 16, 12, right, C.gray, RenderText.ALIGN_RIGHT, true)
    end
    if not ctx.caseUT then ctx.text(x1, y0 + 16, 15, cut(t.name, math.floor((w1 - 8 - rw) / 9)), C.white, nil, true) end
    -- alertes
    local yT = y0 + 26
    if #t.alerts > 0 then
        local a = t.alerts[1]
        local parts = {}
        for _, x in ipairs(t.alerts) do parts[#parts + 1] = x[1] end
        local blink = a[2] == "red" and math.floor((g_time or 0) / 500) % 2 == 0
        ctx.rect(x1, yT, w1, 22, colOf(C, a[2]), blink and 0.95 or 0.75)
        ctx.text(x1 + w1 * 0.5, yT + 16, 13, cut(table.concat(parts, "  ·  "), math.floor(w1 / 8)), C.white, RenderText.ALIGN_CENTER, true)
        yT = yT + 26
    end
    -- (04/11) Precision Farming : densité de semis, dose, azote / pH
    local okPF, hPF = pcall(self.drawPF, self, ctx, C, t, x1, yT, w1)
    if okPF then yT = yT + (hPF or 0) elseif not self.loggedPFd then self.loggedPFd = true; log("ERREUR cadres Precision Farming : %s", tostring(hPF)) end
    -- tuiles (2 colonnes)
    local tl = self:tiles(t)
    local gap = 6
    local tw = (w1 - gap) / 2
    local th = 60
    local rows = math.floor((ctx.cy + ctx.ch - yT + gap) / (th + gap))
    for i, x in ipairs(tl) do
        local r, c = math.floor((i - 1) / 2), (i - 1) % 2
        if r >= rows then break end
        tile(ctx, C, x1 + c * (tw + gap), yT + r * (th + gap), tw, th, x, i)
    end
    -- touches de l'outil
    if not ctx.caseUT then
        local ks = self:keys(t)
        for i, kk in ipairs(ks) do
            if i > self.MAX_KEYS then break end
            ui.sideButton(ctx, i, kk[1], kk[2], kk[3], kk[4])
        end
    end
    return true
end

-------------------------------------------------------------------------------
-- commandes : sur l'outil affiché seulement
-------------------------------------------------------------------------------
-- classes du jeu (globales) par leur nom : pas de rawget(_G), l'environnement du mod passe par __index
local function spec(name)
    if name == "Foldable" then return Foldable elseif name == "Baler" then return Baler
    elseif name == "BaleCounter" then return BaleCounter elseif name == "BaleLoader" then return BaleLoader
    elseif name == "BaleWrapper" then return BaleWrapper elseif name == "Mower" then return Mower
    elseif name == "WorkMode" then return WorkMode elseif name == "SowingMachine" then return SowingMachine
    elseif name == "RidgeMarker" then return RidgeMarker elseif name == "Sprayer" then return Sprayer
    elseif name == "VariableWorkWidth" then return VariableWorkWidth elseif name == "Plow" then return Plow
    elseif name == "Dischargeable" then return Dischargeable elseif name == "Trailer" then return Trailer
    elseif name == "Cover" then return Cover end
    return nil
end

local function ev(specName, fn, o, input)
    local S = spec(specName)
    if S == nil or type(S[fn]) ~= "function" then log("%s.%s absent", specName, fn) return false end
    local ok, err = pcall(S[fn], o, "", input or 1, nil, false)
    if not ok then log("ERREUR %s.%s (%s) : %s", specName, fn, U().vehicleName(o), tostring(err)) end
    return ok
end

function AS_TerminalTools:liftOne(o)
    local ui = U()
    local down = ui.isLowered(o) ~= true
    local kind = not ui.jointLowers(o) and ui.ownLowerKind(o) or nil
    if kind == "pickup" then
        local ok, err = pcall(o.setPickupState, o, down)
        if not ok then log("ERREUR pick-up %s : %s", ui.vehicleName(o), tostring(err)) end
    elseif kind == "fold" then
        ev("Foldable", "actionEventFoldMiddle", o)
    else
        local av = call(o, "getAttacherVehicle")
        local idx = av ~= nil and call(av, "getAttacherJointIndexFromObject", o) or nil
        if idx ~= nil and av.handleLowerImplementByAttacherJointIndex ~= nil then
            -- (37c) attelage déjà dans la bonne position (outil à pliage du milieu resté « levé ») : on ne le rebouge pas
            local jd = av.spec_attacherJoints ~= nil and av.spec_attacherJoints.attacherJoints ~= nil and av.spec_attacherJoints.attacherJoints[idx] or nil
            if jd == nil or (jd.moveDown == true) ~= down then
                local ok, err = pcall(av.handleLowerImplementByAttacherJointIndex, av, idx, down)
                if not ok then log("ERREUR relevage %s : %s", ui.vehicleName(o), tostring(err)) end
            elseif ui.ownLowerKind(o) == "fold" then
                -- outil qui se baisse aussi par son pliage du milieu : c'est lui qui bouge
                ev("Foldable", "actionEventFoldMiddle", o)
            end
            log("outil %s : %s", ui.vehicleName(o), down and "baisser" or "lever")
        else
            ui.warn(T("noLift"))
        end
    end
end

function AS_TerminalTools:turnOnOne(o)
    local ui = U()
    local on = ui.isTurnedOn(o) ~= true
    if o.setIsTurnedOn == nil then ui.warn(T("noTurnOn")) return end
    if on and call(o, "getCanBeTurnedOn") == false then
        ui.warn(call(o, "getTurnedOnNotAllowedWarning") or T("noTurnOn"))
        return
    end
    if o.getCanToggleTurnedOn ~= nil and call(o, "getCanToggleTurnedOn") == false then ui.warn(T("noTurnOn")) return end
    local ok, err = pcall(o.setIsTurnedOn, o, on)
    if not ok then log("ERREUR marche %s : %s", ui.vehicleName(o), tostring(err)) end
end

function AS_TerminalTools:tipOne(o)
    local D = Dischargeable
    if o.getDischargeState == nil or D == nil then return end
    if (call(o, "getDischargeState") or 0) ~= 0 then
        if D.DISCHARGE_STATE_OFF ~= nil then pcall(o.setDischargeState, o, D.DISCHARGE_STATE_OFF) end
        return
    end
    local dn = call(o, "getCurrentDischargeNode")
    if dn ~= nil and call(o, "getCanDischargeToObject", dn) == true then ev("Dischargeable", "actionEventToggleDischarging", o) end
    if (call(o, "getDischargeState") or 0) == 0 then ev("Dischargeable", "actionEventToggleDischargeToGround", o) end
    if (call(o, "getDischargeState") or 0) == 0 then
        local w = call(o, "getDischargeNotAllowedWarning", call(o, "getCurrentDischargeNode"))
        U().warn(type(w) == "string" and w or T("tipNo"))
    end
end

-- action « t_* » ou « tool_<n> » venue d'un bouton du terminal
-- (04/11) Precision Farming : par les fonctions du mod (elles envoient leurs événements)
local function pfInvoke(o, cls, fn, ...)
    if type(o[fn]) == "function" then return pcall(o[fn], o, ...) end
    local C = pfGlobal(cls)
    if type(C) == "table" and type(C[fn]) == "function" then return pcall(C[fn], o, ...) end
    return false, "fonction absente : " .. fn
end
function AS_TerminalTools:pfSeedAction(o, a)
    local es = pfSpec(o, "extendedSowingMachine", "ExtendedSowingMachine")
    if es == nil then return end
    local ok, err
    if a == "t_srAuto" then ok, err = pfInvoke(o, "ExtendedSowingMachine", "setSeedRateAutoMode", true)
    elseif a == "t_srMan" then ok, err = pfInvoke(o, "ExtendedSowingMachine", "setSeedRateAutoMode", false)
    elseif not es.seedRateAutoMode then
        ok, err = pfInvoke(o, "ExtendedSowingMachine", "setManualSeedRate", (es.manualSeedRate or 2) + (a == "t_srUp" and 1 or -1))
    end
    if ok == false then log("ERREUR Precision Farming %s : %s", a, tostring(err)) end
end
function AS_TerminalTools:pfSprayAction(o, a)
    local es = pfSpec(o, "extendedSprayer", "ExtendedSprayer")
    if es == nil then return end
    local ok, err
    if a == "t_pfAuto" then ok, err = pfInvoke(o, "ExtendedSprayer", "setSprayAmountAutoMode", true)
    elseif a == "t_pfMan" then ok, err = pfInvoke(o, "ExtendedSprayer", "setSprayAmountAutoMode", false)
    elseif not es.sprayAmountAutoMode then
        ok, err = pfInvoke(o, "ExtendedSprayer", "setSprayAmountManualValue", (es.sprayAmountManual or 0) + (a == "t_pfUp" and 1 or -1))
    end
    if ok == false then log("ERREUR Precision Farming %s : %s", a, tostring(err)) end
end
function AS_TerminalTools:action(AS_T, v, a)
    local d = AS_T.data
    if a:sub(1, 5) == "tool_" then
        local i = tonumber(a:sub(6))
        local t = d ~= nil and d.toolTabs ~= nil and d.toolTabs[i] or nil
        if t ~= nil then self.sel[v] = t.o end
        self.keyOff[v] = 0
        AS_T.lastRead = -100000
        return
    end
    if a == "t_utup" then self.keyOff[v] = math.max(0, (self.keyOff[v] or 0) - 1) return end
    if a == "t_utdn" then self.keyOff[v] = (self.keyOff[v] or 0) + 1 return end
    local o = self.shown[v]
    if o == nil then return end
    local ui = U()
    if a == "t_lift" then self:liftOne(o)
    elseif a == "t_on" then self:turnOnOne(o)
    elseif a == "t_fold" then ev("Foldable", "actionEventFold", o)
    elseif a == "t_bdrop" then ev("Baler", "actionEventUnloading", o)
    elseif a == "t_bauto" then ev("Baler", "actionEventToggleAutomaticDrop", o)
    elseif a == "t_bsize" then ev("Baler", "actionEventToggleSize", o)
    elseif a == "t_breset" then ev("BaleCounter", "actionEventResetCounter", o)
    elseif a == "t_blwork" then ev("BaleLoader", "actionEventWorkTransport", o)
    elseif a == "t_blempty" then ev("BaleLoader", "actionEventEmpty", o)
    elseif a == "t_wauto" then ev("BaleWrapper", "actionEventToggleAutomaticDrop", o)
    elseif a == "t_wdrop" then ev("BaleWrapper", "actionEventEmpty", o)
    elseif a == "t_mdrop" then ev("Mower", "actionEventToggleDrop", o)
    elseif a == "t_mode" then ev("WorkMode", "actionEventWorkModeChange", o)
    elseif a == "t_seed" then ev("SowingMachine", "actionEventToggleSeedType", o)
    elseif a == "t_ridge" then ev("RidgeMarker", "actionEventToggleRidgeMarkers", o)
    elseif a == "t_double" then ev("Sprayer", "actionEventDoubledAmount", o)
    elseif a == "t_sect" then ev("VariableWorkWidth", "actionEventWorkWidthToggle", o)
    elseif a == "t_turn" then ev("Plow", "actionEventTurn", o)
    elseif a == "t_plimit" then ev("Plow", "actionEventLimitToField", o)
    elseif a == "t_tip" then self:tipOne(o)
    elseif a == "t_tipSide" then
        if not ev("Trailer", "actionEventToggleTipSide", o) and o.setPreferedTipSide ~= nil and o.spec_trailer ~= nil then
            local spT = o.spec_trailer
            pcall(o.setPreferedTipSide, o, ((spT.preferedTipSideIndex or 1) % math.max(1, #(spT.tipSides or {}))) + 1)
        end
    elseif a == "t_cover" then
        if not ev("Cover", "actionEventToggleCover", o) and o.setCoverState ~= nil then
            pcall(o.setCoverState, o, (o.spec_cover.state or 0) ~= 0 and 0 or 1)
        end
    elseif a == "t_srAuto" or a == "t_srMan" or a == "t_srDn" or a == "t_srUp" then
        self:pfSeedAction(o, a)
    elseif a == "t_pfAuto" or a == "t_pfMan" or a == "t_pfDn" or a == "t_pfUp" then
        self:pfSprayAction(o, a)
    elseif a == "t_cntReset" then
        local c = self:counter(o)
        c.ha, c.ms, c.dist = 0, 0, 0
        if c.seeds ~= nil then c.seeds = 0 end
    end
    log("%s : %s", a, ui.vehicleName(o))
    AS_T.lastRead = -100000
end
