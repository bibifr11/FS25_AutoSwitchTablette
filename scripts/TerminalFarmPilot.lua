-- AutoSwitch : onglet FARMPILOT du terminal
-- Fichier chargé par AutoSwitch.lua (après Terminal.lua et TerminalGps.lua).

-------------------------------------------------------------------------------
-- Étape 36 (01/11) : onglet FarmPilot (pas AutoDrive) dans les tablettes : sélections de FarmPilot
-- directement dans la fenêtre de la tablette, HUD supprimé pour les tracteurs équipés ; à sa place une
-- icône cliquable qui ouvre le HUD d'édition de course ; option pour afficher / cacher le HUD pour les
-- joueurs qui préfèrent le conserver.
--   - page FARMPILOT (onglet du bas, seulement si FarmPilot est chargé et que le véhicule l'a) :
--     état, mode, cible, déchargement, remplissage (plusieurs produits), boucles, vitesses route / champ,
--     options automatiques, MARCHE / ARRÊT, CONTINUER, GARER, aide au champ, ÉDITER ROUTES, RÉGLAGES ;
--   - tout passe par les fonctions de FarmPilot (ADInputManager:onInputCall, AutoDriveHudInputEventEvent),
--     comme ses touches et son HUD : mêmes contrôles, mêmes messages, multijoueur compris ;
--   - HUD FarmPilot caché sur les véhicules qui ont le terminal (Réglages > HUD FarmPilot : Caché / Affiché) ;
--     à sa place, une petite icône FarmPilot ouvre le HUD en mode édition de routes ; la croix du HUD
--     (ou l'icône) le referme et coupe l'éditeur. Sur la carte du menu (ouvriers), le HUD reste normal.
-- Étape 36b (01/11) : icône plus grande, déplacée (à droite de l'écran, à mi-hauteur),
-- HUD ouvert de l'autre côté de l'icône :
--   - icône plus grande, à droite au milieu de l'écran par défaut, déplaçable en la faisant glisser
--     (place gardée dans modSettings/FS25_AutoSwitch/terminal_farmpilot.xml) ;
--   - le HUD d'édition s'ouvre à GAUCHE de l'icône (à droite seulement s'il n'y a pas la place) ;
--     sa place d'avant est remise à la fermeture (véhicules sans terminal).
-------------------------------------------------------------------------------
AS_TerminalFp = {}
local F = AS_TerminalFp

F.sub = nil                        -- nil = page principale ; "target", "unload", "fill" = liste à choisir
F.page = 1                         -- page de la liste
F.ROWS = 11                        -- lignes par colonne dans les listes (2 colonnes)
F.LIST_MS = 1000                   -- listes de FarmPilot relues au plus une fois par seconde
F.fold = { target = {}, unload = {} }   -- dossiers repliés (nom -> true)
F.edit = nil                       -- HUD d'édition ouvert par l'icône : { v = véhicule, hudWas = HUD affiché avant }
F.logged = {}

local function U() return AS_Terminal.ui end
local function T(k) return U().T(k) end
local function log(fmt, ...) print(string.format("[AS_Terminal] FarmPilot : " .. fmt, ...)) end
local function logOnce(key, fmt, ...)
    if F.logged[key] then return end
    F.logged[key] = true
    log(fmt, ...)
end
local function clamp(v, a, b) return math.max(a, math.min(b, v)) end
local function G(name) return U().adGlobal(name) end
local function AD() return G("AutoDrive") end
local function ctrl() return AS.shGetControlledVehicle ~= nil and AS.shGetControlledVehicle() or nil end

-- FarmPilot chargé et véhicule équipé
function F:available(v)
    return U().isFarmPilot() and v ~= nil and type(v.ad) == "table" and v.ad.stateModule ~= nil
end

-- lecture de l'état du véhicule (getters de FarmPilot)
local function st(v, name, ...)
    local s = v.ad.stateModule
    local fn = s ~= nil and s[name] or nil
    if type(fn) ~= "function" then return nil end
    local ok, r = pcall(fn, s, ...)
    if ok then return r end
    logOnce("st_" .. name, "ERREUR %s : %s", name, tostring(r))
    return nil
end

local function setting(name)
    local ad = AD()
    if ad == nil or ad.getSetting == nil then return nil end
    local ok, r = pcall(ad.getSetting, name)
    if ok then return r end
    return nil
end

-- commande comme la touche de FarmPilot
local function input(v, name)
    local adi = G("ADInputManager")
    if adi == nil or adi.onInputCall == nil then U().warn(T("fpMissing")) return false end
    local ok, err = pcall(adi.onInputCall, adi, v, name)
    if not ok then log("ERREUR %s : %s", name, tostring(err)) end
    return ok
end

-- choix comme dans les listes du HUD de FarmPilot (événement envoyé au serveur)
local function hudEvent(fn, v, value)
    local ev = G("AutoDriveHudInputEventEvent")
    if ev == nil or type(ev[fn]) ~= "function" then U().warn(T("fpMissing")) return false end
    local ok, err = pcall(ev[fn], ev, v, value)
    if not ok then log("ERREUR %s : %s", fn, tostring(err)) end
    return ok
end

-- nom du mode : texte de FarmPilot (celui de son HUD), sinon le nôtre
local MODE_KEYS = { "AD_MODE_DRIVETO", "AD_MODE_PICKUPANDDELIVER", "AD_MODE_DELIVERTO", "AD_MODE_LOAD", "AD_MODE_UNLOAD", "AD_MODE_BGA" }
function F:modeName(mode)
    local key = MODE_KEYS[mode or 0]
    if key == nil then return "-" end
    local i18n = G("g_i18n")
    if i18n ~= nil and i18n.getText ~= nil then
        local ok, t = pcall(i18n.getText, i18n, key)
        if ok and type(t) == "string" and t ~= "" and t ~= key and not t:find("Missing", 1, true) then return t end
    end
    return T("fpMode" .. mode)
end

function F:helperName(h)
    if h == 1 then return "Courseplay" elseif h == 2 then return "AIVE" elseif h == 3 then return T("g_IA") end
    return T("none")
end

-- tri naturel (« Champ 2 » avant « Champ 10 »), comme les listes de FarmPilot
local function natLess(a, b)
    a, b = string.lower(tostring(a)), string.lower(tostring(b))
    local pa, na = a:match("^(.-)%s*(%d+)$")
    local pb, nb = b:match("^(.-)%s*(%d+)$")
    if pa ~= nil and pb ~= nil and pa == pb and tonumber(na) ~= tonumber(nb) then return tonumber(na) < tonumber(nb) end
    return a < b
end

-- cibles de la carte, rangées par dossier (dossiers de FarmPilot si « utiliser les dossiers » est actif)
function F:markerGroups()
    local now = g_time or 0
    local c = self.mkCache
    if c ~= nil and now >= c.t and now - c.t < self.LIST_MS then return c.groups end
    local groups = {}
    local gm = G("ADGraphManager")
    if gm ~= nil and gm.getMapMarkers ~= nil then
        local ok, markers = pcall(gm.getMapMarkers, gm)
        if ok and type(markers) == "table" then
            local useFolders = setting("useFolders") == true
            local byName = {}
            for id, m in pairs(markers) do
                if type(m) == "table" and m.name ~= nil then
                    local gname = (useFolders and type(m.group) == "string" and m.group ~= "All") and m.group or ""
                    local g = byName[gname]
                    if g == nil then
                        g = { name = gname, entries = {} }
                        byName[gname] = g
                        groups[#groups + 1] = g
                    end
                    g.entries[#g.entries + 1] = { id = id, name = tostring(m.name) }
                end
            end
            for _, g in ipairs(groups) do table.sort(g.entries, function(a, b) return natLess(a.name, b.name) end) end
            table.sort(groups, function(a, b)
                if a.name == "" then return b.name ~= "" end
                if b.name == "" then return false end
                return natLess(a.name, b.name)
            end)
        end
    end
    self.mkCache = { t = now, groups = groups }
    return groups
end

-- produits que le train d'outils peut charger (même liste que FarmPilot)
function F:fillList(v)
    local now = g_time or 0
    local c = self.ftCache
    if c ~= nil and c.v == v and now >= c.t and now - c.t < self.LIST_MS then return c.list end
    local list = {}
    local ad = AD()
    if ad ~= nil and ad.getValidSupportedFillTypesALfirst ~= nil then
        local ok, l = pcall(ad.getValidSupportedFillTypesALfirst, v)
        if ok and type(l) == "table" then
            local skip, seen = {}, {}
            for _, f in ipairs(ad.ItemFilterList or {}) do skip[f] = true end
            for _, ft in ipairs(l) do
                if type(ft) == "number" and ft > 0 and not skip[ft] and not seen[ft] then
                    seen[ft] = true
                    list[#list + 1] = { id = ft, name = U().fillTypeTitle(ft) or tostring(ft) }
                end
            end
        end
    end
    table.sort(list, function(a, b) return natLess(a.name, b.name) end)
    self.ftCache = { t = now, v = v, list = list }
    return list
end

-- éléments de la liste affichée (dossiers + cibles, ou produits)
function F:items(v, kind)
    local items = {}
    if kind == "fill" then
        local sel = {}
        for _, ft in ipairs(st(v, "getSelectedFillTypes") or {}) do sel[ft] = true end
        local main = st(v, "getFillType")
        for _, e in ipairs(self:fillList(v)) do
            items[#items + 1] = { id = e.id, name = e.name, cur = e.id == main, mark = sel[e.id] == true }
        end
        return items
    end
    local cur = kind == "target" and st(v, "getFirstMarkerId") or st(v, "getSecondMarkerId")
    local fold = self.fold[kind] or {}
    for _, g in ipairs(self:markerGroups()) do
        if g.name ~= "" then items[#items + 1] = { folder = g.name, n = #g.entries, folded = fold[g.name] == true } end
        if g.name == "" or not fold[g.name] then
            for _, e in ipairs(g.entries) do items[#items + 1] = { id = e.id, name = e.name, cur = e.id == cur } end
        end
    end
    return items
end

-- ouverture d'une liste : dossiers repliés sauf celui de la cible choisie (si tout ne tient pas), page de la cible
function F:openList(v, kind)
    -- (étape 37) : menu sous la ligne
    self.sub = nil
    self.drop = kind
    self.dropTop = 1
    self.page = 1
    if kind ~= "fill" then
        local cur = kind == "target" and st(v, "getFirstMarkerId") or st(v, "getSecondMarkerId")
        local groups = self:markerGroups()
        local total = 0
        for _, g in ipairs(groups) do total = total + #g.entries + (g.name ~= "" and 1 or 0) end
        local fold = {}
        if total > self.ROWS * 2 then
            for _, g in ipairs(groups) do
                if g.name ~= "" then
                    local has = false
                    for _, e in ipairs(g.entries) do if e.id == cur then has = true end end
                    fold[g.name] = not has
                end
            end
        end
        self.fold[kind] = fold
    end
    for i, it in ipairs(self:items(v, kind)) do
        if it.cur then
            self.page = math.floor((i - 1) / (self.ROWS * 2)) + 1
            self.dropTop = math.max(1, i - 1)          -- élément choisi en 2e ligne du menu
            break
        end
    end
end

-- (étape 37) menu déroulant sous la ligne (y0) jusqu'au bas de la page
function F:drawDrop(ctx, v, kind, u, w, y0, y1)
    local ui = U()
    local C = ui.C
    local CENTER = RenderText.ALIGN_CENTER
    local items = self:items(v, kind)
    ctx.rect(u, y0, w, y1 - y0, C.boxHi)
    local RH2 = 27
    local sw = 60                                   -- colonne des flèches (et TOUT pour les produits)
    local lw = w - sw - 12
    local n = math.max(1, math.floor((y1 - y0 - 8) / RH2))
    local maxTop = math.max(1, #items - n + 1)
    self.dropTop = clamp(self.dropTop or 1, 1, maxTop)
    self.folderNames = {}
    for k = 1, n do
        local it = items[self.dropTop + k - 1]
        if it == nil then break end
        local x, yy = u + 4, y0 + 4 + (k - 1) * RH2
        if it.folder ~= nil then
            self.folderNames[#self.folderNames + 1] = it.folder
            ctx.button(x, yy, lw, RH2 - 3, "fp_fold_" .. #self.folderNames, false)
            ctx.text(x + 8, yy + 17, 12, string.format("%s %s (%d)", it.folded and "+" or "-", it.folder, it.n), C.amber, nil, true, lw - 16)
        else
            local boxW = kind == "fill" and 30 or 0
            local nameW = lw - (boxW > 0 and boxW + 4 or 0)
            ctx.button(x, yy, nameW, RH2 - 3, "fp_pick_" .. tostring(it.id), it.cur)
            ctx.text(x + 8, yy + 17, 12, it.name, C.white, nil, it.cur, nameW - 16)
            if boxW > 0 then
                ctx.button(x + lw - boxW, yy, boxW, RH2 - 3, "fp_mark_" .. tostring(it.id), it.mark)
                if it.mark then ctx.text(x + lw - boxW * 0.5, yy + 17, 12, "X", C.white, CENTER, true) end
            end
        end
    end
    if #items == 0 then
        ctx.text(u + lw * 0.5, y0 + 26, 13, kind == "fill" and T("fpNoFill") or T("fpNoTarget"), C.gray, CENTER, nil, lw - 20)
    end
    -- flèches haut / bas (triangles dessinés), position dans la liste, TOUT pour les produits
    local bx = u + w - sw - 4
    local function tri(cx, cy, up)
        for r = 0, 4 do
            local half = (up and r or (4 - r)) * 2 + 1
            ctx.rect(cx - half, cy - 5 + r * 2, half * 2, 2, (up and self.dropTop > 1 or (not up and self.dropTop < maxTop)) and C.white or C.dim)
        end
    end
    ctx.button(bx, y0 + 4, sw, 34, "fp_dUp", false)
    tri(bx + sw * 0.5, y0 + 21, true)
    ctx.button(bx, y1 - 38, sw, 34, "fp_dDn", false)
    tri(bx + sw * 0.5, y1 - 21, false)
    if #items > n then
        ctx.text(bx + sw * 0.5, y0 + 56, 10, string.format("%d-%d", self.dropTop, math.min(#items, self.dropTop + n - 1)), C.gray, CENTER, nil, sw - 4)
        ctx.text(bx + sw * 0.5, y0 + 70, 10, string.format("/ %d", #items), C.gray, CENTER, nil, sw - 4)
    end
    if kind == "fill" and #items > 0 and y1 - y0 > 130 then
        ctx.button(bx, y1 - 78, sw, 34, "fp_markAll", false)
        ctx.text(bx + sw * 0.5, y1 - 56, 10, T("fpAll"), C.white, CENTER, true, sw - 4)
    end
    self.dropRows = n
end

-------------------------------------------------------------------------------
-- Dessin de la page
-------------------------------------------------------------------------------
function F:drawPage(AS_T, d, ctx, v)
    if not self:available(v) then return false end
    if self.sub ~= nil then return self:drawList(AS_T, d, ctx, v) end
    local ui = U()
    local C = ui.C
    local CENTER, RIGHT = RenderText.ALIGN_CENTER, RenderText.ALIGN_RIGHT
    local u, w = ctx.cx + 10, ctx.cw - 20
    local mode = st(v, "getMode") or 1
    local active = st(v, "isActive") == true
    local needUnload = mode == 2 or mode == 4 or mode == 5
    local needFill = mode == 2 or mode == 4
    local RH = 37
    local LX = u + 150
    -- fond de ligne : les touches restent sur le fond plus sombre (bien visibles)
    local function rowBox(i, rightW)
        local yy = ctx.cy + 8 + (i - 1) * RH
        ctx.rect(u, yy, w - (rightW or 0), RH - 4, C.box)
        return yy
    end
    local function label(yy, txt) ctx.text(u + 8, yy + 22, 13, txt, C.white, nil, nil, 138) end

    -- 1. état et tâche en cours
    local yy = rowBox(1)
    label(yy, T("fpState"))
    ctx.text(LX, yy + 22, 13, active and T("fpRunning") or T("fpStopped"), active and C.lamp or C.gray, nil, true, 110)
    local task = active and st(v, "getCurrentLocalizedTaskInfo") or nil
    if type(task) == "string" and task ~= "" then
        ctx.text(u + w - 8, yy + 22, 11, task, C.gray, RIGHT, nil, w - 270)
    end

    -- 2. mode < >
    yy = ctx.cy + 8 + RH
    ctx.rect(u, yy, LX - u - 6, RH - 4, C.box)
    ctx.rect(LX + 46, yy, (u + w - 54) - (LX + 46), RH - 4, C.box)
    label(yy, T("fpModeL"))
    ctx.button(LX, yy + 4, 40, 25, "fp_modePrev")
    ctx.text(LX + 20, yy + 22, 14, "<", C.white, CENTER, true)
    ctx.button(u + w - 48, yy + 4, 40, 25, "fp_modeNext")
    ctx.text(u + w - 28, yy + 22, 14, ">", C.white, CENTER, true)
    local mx0, mx1 = LX + 40, u + w - 48
    ctx.text((mx0 + mx1) * 0.5, yy + 22, 13, self:modeName(mode), C.lamp, CENTER, true, mx1 - mx0 - 14)

    -- 3 à 5. listes (cible, déchargement, remplissage)
    -- (étape 37) champ à menu déroulant : un clic ouvre la liste sous la ligne (les lignes suivantes sont cachées)
    local dropY = nil
    local function listRow(i, lbl, value, on, kind)
        if dropY ~= nil then return end
        local y2 = rowBox(i)
        label(y2, lbl)
        if on then
            local open = self.drop == kind
            ctx.button(LX - 6, y2 + 3, u + w - LX, RH - 10, "fp_drop_" .. kind, open)
            ctx.text(LX, y2 + 22, 13, value, open and C.white or C.lamp, nil, true, u + w - LX - 40)
            -- flèche du menu
            local ax, ay = u + w - 26, y2 + 14
            for r = 0, 3 do
                local half = (open and r or (3 - r)) * 2 + 1
                ctx.rect(ax - half, ay + r * 2, half * 2, 2, C.white)
            end
            if open then dropY = y2 + RH - 4 end
        else
            ctx.text(LX, y2 + 22, 13, value, C.dim, nil, false, w - (LX - u) - 12)
            if self.drop == kind then self.drop = nil end
        end
    end
    local function nm(s) return (type(s) == "string" and s ~= "") and s or "-" end
    listRow(3, T("fpTarget"), nm(st(v, "getFirstMarkerName")), true, "target")
    listRow(4, T("fpUnload"), needUnload and nm(st(v, "getSecondMarkerName")) or "-", needUnload, "unload")
    local fillTxt = "-"
    if needFill then
        local main = st(v, "getFillType")
        local sel = st(v, "getSelectedFillTypes") or {}
        fillTxt = (main ~= nil and main > 0) and (ui.fillTypeTitle(main) or "-") or "-"
        if #sel > 1 then fillTxt = string.format("%s + %d", fillTxt, #sel - 1) end
    end
    listRow(5, T("fpFill"), fillTxt, needFill, "fill")
    if dropY ~= nil then
        self:drawDrop(ctx, v, self.drop, u, w, dropY + 2, ctx.cy + ctx.ch - 6)
    else

    -- 6 à 8. boucles et vitesses
    local function pmRow(i, lbl, value, minus, plus)
        local y2 = rowBox(i, 108)
        label(y2, lbl)
        ctx.text(u + w - 116, y2 + 22, 13, value, C.lamp, RIGHT, true, w - 276)
        ctx.button(u + w - 102, y2 + 4, 40, 25, minus)
        ctx.text(u + w - 82, y2 + 22, 13, "-", C.white, CENTER, true)
        ctx.button(u + w - 56, y2 + 4, 48, 25, plus)
        ctx.text(u + w - 32, y2 + 22, 13, "+", C.white, CENTER, true)
    end
    local loops = st(v, "getLoopCounter") or 0
    local done = st(v, "getLoopsDone") or 0
    pmRow(6, T("fpLoops"), loops > 0 and string.format("%d / %d", done, loops) or T("fpLoopsEndless"), "fp_loop-", "fp_loop+")
    pmRow(7, T("fpSpeed"), string.format("%d km/h", math.floor((st(v, "getSpeedLimit") or 0) + 0.5)), "fp_spd-", "fp_spd+")
    pmRow(8, T("fpFieldSpeed"), string.format("%d km/h", math.floor((st(v, "getFieldSpeedLimit") or 0) + 0.5)), "fp_fspd-", "fp_fspd+")

    -- 9. options (comme les boutons du HUD)
    local ad = AD() or {}
    local chips = {
        { "fp_autoPick", T("fpAutoPick"), st(v, "getAutomaticPickupTarget") == true, ad.automaticPickupTarget == true },
        { "fp_autoUnload", T("fpAutoUnload"), st(v, "getAutomaticUnloadTarget") == true, ad.automaticUnloadTarget == true },
        { "fp_byLevel", T("fpByLevel"), st(v, "getLoadByFillLevel") == true, true },
        { "fp_autoHelper", T("fpAutoHelper"), st(v, "getStartHelper") == true, true },
    }
    yy = ctx.cy + 8 + 8 * RH
    local cwid = (w - 3 * 6) / 4
    for i, c in ipairs(chips) do
        local x = u + (i - 1) * (cwid + 6)
        if c[4] then ctx.button(x, yy, cwid, RH - 4, c[1], c[3]) else ctx.rect(x, yy, cwid, RH - 4, C.box) end
        ctx.rect(x + 6, yy + 13, 8, 8, (c[3] and c[4]) and C.lamp or C.dim)
        ctx.text(x + cwid * 0.5 + 6, yy + 21, 11, c[2], c[4] and C.white or C.dim, CENTER, true, cwid - 26)
    end
    end

    -- colonne de droite
    local sb = ui.sideButton
    sb(ctx, 1, "fp_startStop", T("fpGo"), active, active and T("fpRunning") or T("fpStopped"))
    sb(ctx, 2, "fp_continue", T("fpContinue"), false)
    sb(ctx, 3, "fp_park", T("fpPark"), false)
    sb(ctx, 4, "fp_helper", T("fpHelper"), false, self:helperName(st(v, "getUsedHelper")))
    local ed = self:editing()
    sb(ctx, 5, "fp_edit", T("fpEdit"), ed, ed and T("fpEditOn") or nil)
    sb(ctx, 6, "fp_settings", T("fpSettings"), false)
    return true
end

function F:drawList(AS_T, d, ctx, v)
    local ui = U()
    local C = ui.C
    local CENTER, RIGHT = RenderText.ALIGN_CENTER, RenderText.ALIGN_RIGHT
    local kind = self.sub
    local u, w = ctx.cx + 10, ctx.cw - 20
    local items = self:items(v, kind)
    local per = self.ROWS * 2
    local pages = math.max(1, math.ceil(#items / per))
    self.page = clamp(self.page, 1, pages)
    -- titre et choix actuel
    local title, cur
    if kind == "target" then title, cur = T("fpTarget"), st(v, "getFirstMarkerName")
    elseif kind == "unload" then title, cur = T("fpUnload"), st(v, "getSecondMarkerName")
    else
        title = T("fpFill")
        local main = st(v, "getFillType")
        cur = (main ~= nil and main > 0) and ui.fillTypeTitle(main) or nil
    end
    ctx.rect(u, ctx.cy + 8, w, 28, C.box)
    ctx.text(u + 8, ctx.cy + 27, 13, title, C.white, nil, true, 150)
    if kind == "fill" then ctx.text(u + 166, ctx.cy + 27, 11, T("fpFillHint"), C.gray, nil, nil, w - 330) end
    ctx.text(u + w - 8, ctx.cy + 27, 12, (type(cur) == "string" and cur ~= "") and cur or "-", C.lamp, RIGHT, true, kind == "fill" and 150 or w - 170)
    -- éléments sur 2 colonnes
    local RH2 = 26
    local colW = (w - 8) / 2
    local y0 = ctx.cy + 42
    self.folderNames = {}
    local hasFolder = false
    for _, it in ipairs(items) do if it.folder ~= nil then hasFolder = true end end
    for k = 1, per do
        local idx = (self.page - 1) * per + k
        local it = items[idx]
        if it == nil then break end
        local col = math.floor((k - 1) / self.ROWS)
        local row = (k - 1) % self.ROWS
        local x = u + col * (colW + 8)
        local yy = y0 + row * RH2
        if it.folder ~= nil then
            self.folderNames[#self.folderNames + 1] = it.folder
            ctx.button(x, yy, colW, RH2 - 3, "fp_fold_" .. #self.folderNames, false)
            ctx.text(x + 8, yy + 17, 12, string.format("%s %s (%d)", it.folded and "+" or "-", it.folder, it.n), C.amber, nil, true, colW - 16)
        else
            local boxW = kind == "fill" and 30 or 0
            local nameW = colW - (boxW > 0 and boxW + 4 or 0)
            ctx.button(x, yy, nameW, RH2 - 3, "fp_pick_" .. tostring(it.id), it.cur)
            ctx.text(x + 8, yy + 17, 12, it.name, C.white, nil, it.cur, nameW - 16)
            if boxW > 0 then
                ctx.button(x + colW - boxW, yy, boxW, RH2 - 3, "fp_mark_" .. tostring(it.id), it.mark)
                if it.mark then ctx.text(x + colW - boxW * 0.5, yy + 17, 12, "X", C.white, CENTER, true) end
            end
        end
    end
    if #items == 0 then
        ctx.text(u + w * 0.5, y0 + 40, 13, kind == "fill" and T("fpNoFill") or T("fpNoTarget"), C.gray, CENTER, nil, w - 20)
    end
    -- colonne de droite : pages, dossiers / tout choisir, retour
    local sb = ui.sideButton
    sb(ctx, 1, "fp_pgUp", T("fpPgUp"), false, string.format("%d / %d", self.page, pages))
    sb(ctx, 2, "fp_pgDn", T("fpPgDn"), false)
    if kind == "fill" then
        if #items > 0 then sb(ctx, 3, "fp_markAll", T("fpAll"), false) end
    elseif hasFolder then
        sb(ctx, 3, "fp_foldAll", T("fpFoldAll"), false)
    end
    sb(ctx, 7, "fp_back", T("fpBack"), false)
    return true
end

-------------------------------------------------------------------------------
-- Commandes
-------------------------------------------------------------------------------
local INPUTS = {
    fp_startStop = "input_start_stop", fp_continue = "input_continue", fp_park = "input_parkVehicle",
    fp_helper = "input_toggleUsedHelper", fp_autoHelper = "input_startHelper",
    fp_autoPick = "input_toggleAutomaticPickupTarget", fp_autoUnload = "input_toggleAutomaticUnloadTarget",
    fp_byLevel = "input_toggleLoadByFillLevel", fp_modeNext = "input_silomode", fp_modePrev = "input_previousMode",
    ["fp_loop-"] = "input_decLoopCounter", ["fp_loop+"] = "input_incLoopCounter",
    ["fp_spd-"] = "input_decreaseSpeed", ["fp_spd+"] = "input_increaseSpeed",
    ["fp_fspd-"] = "input_decreaseFieldSpeed", ["fp_fspd+"] = "input_increaseFieldSpeed",
}

function F:action(AS_T, v, a)
    if not self:available(v) then U().warn(T("fpMissing")) return end
    if INPUTS[a] ~= nil then
        input(v, INPUTS[a])
    elseif a == "fp_settings" then
        if AS_T.isOpen then AS_T:setOpen(false) end
        input(v, "input_openGUI")
    elseif a == "fp_edit" then
        if not self:editing() and AS_T.isOpen then AS_T:setOpen(false) end
        self:toggleEdit(v)
    elseif a:sub(1, 8) == "fp_drop_" then
        -- (étape 37) menu déroulant : ouvert / refermé par un clic sur le champ
        local kind = a:sub(9)
        if self.drop == kind then self.drop = nil else self:openList(v, kind) end
    elseif a == "fp_dUp" then
        self.dropTop = math.max(1, (self.dropTop or 1) - math.max(1, (self.dropRows or 5) - 1))
    elseif a == "fp_dDn" then
        self.dropTop = (self.dropTop or 1) + math.max(1, (self.dropRows or 5) - 1)
    elseif a:sub(1, 8) == "fp_list_" then
        self:openList(v, a:sub(9))
    elseif a == "fp_back" then
        self.sub, self.drop = nil, nil
    elseif a == "fp_pgUp" then
        self.page = math.max(1, self.page - 1)
    elseif a == "fp_pgDn" then
        self.page = self.page + 1
    elseif a:sub(1, 8) == "fp_pick_" then
        local id = tonumber(a:sub(9))
        if id == nil then return end
        local kind = self.sub or self.drop
        if kind == "fill" then
            hudEvent("sendFillTypeEvent", v, id)
            log("produit : %s", tostring(U().fillTypeTitle(id)))
        else
            local gm = G("ADGraphManager")
            local okM, m = false, nil
            if gm ~= nil and gm.getMapMarkerById ~= nil then okM, m = pcall(gm.getMapMarkerById, gm, id) end
            if not okM or m == nil then return end
            hudEvent(kind == "unload" and "sendSecondMarkerEvent" or "sendFirstMarkerEvent", v, id)
            log("%s : %s", kind == "unload" and "déchargement" or "cible", tostring(m.name))
        end
        self.sub, self.drop = nil, nil
    elseif a:sub(1, 8) == "fp_mark_" then
        local id = tonumber(a:sub(9))
        if id ~= nil then hudEvent("sendToggleFillTypeSelectionEvent", v, id) end
    elseif a == "fp_markAll" then
        local main = st(v, "getFillType")
        if main == nil or main <= 0 then
            local l = self:fillList(v)
            main = l[1] ~= nil and l[1].id or nil
        end
        if main ~= nil then hudEvent("sendToggleAllFillTypeSelectionsEvent", v, main) end
    elseif a:sub(1, 8) == "fp_fold_" then
        local name = self.folderNames ~= nil and self.folderNames[tonumber(a:sub(9)) or 0] or nil
        local kind = self.sub or self.drop
        if name ~= nil and kind ~= nil then
            local f = self.fold[kind] or {}
            f[name] = not f[name]
            self.fold[kind] = f
        end
    elseif a == "fp_foldAll" and self.sub ~= nil then
        local f = self.fold[self.sub] or {}
        local anyOpen = false
        for _, g in ipairs(self:markerGroups()) do if g.name ~= "" and not f[g.name] then anyOpen = true end end
        for _, g in ipairs(self:markerGroups()) do if g.name ~= "" then f[g.name] = anyOpen end end
        self.fold[self.sub] = f
        self.page = 1
    end
end

-------------------------------------------------------------------------------
-- HUD de FarmPilot : caché sur les véhicules qui ont le terminal, icône d'édition à sa place
-------------------------------------------------------------------------------
function F:hudHidden(v)
    if v == nil or AS_Terminal.settings.fpHudHide == false then return false end
    if not self:available(v) then return false end
    return AS_Terminal:hasTerminal(v) == true
end

function F:editorOn()
    local ad = AD()
    if ad == nil or ad.isEditorModeEnabled == nil then return false end
    local ok, r = pcall(ad.isEditorModeEnabled)
    return ok and r == true
end

-- HUD d'édition ouvert (par l'icône, ou éditeur mis par la touche de FarmPilot)
function F:editing() return self.edit ~= nil or self:editorOn() end

-- HUD caché maintenant pour ce véhicule (pas sur la carte du menu des ouvriers)
function F:blockNow(vehicle)
    local ad = AD()
    if ad ~= nil and ad.aiFrameOpen then return false end
    local ok, hidden = pcall(self.hudHidden, self, vehicle)
    if not ok or not hidden then return false end
    return not self:editing()
end

function F:openEdit(v)
    local ad = AD()
    if ad == nil then U().warn(T("fpMissing")) return end
    self.edit = { v = v, hudWas = setting("showHUD") == true }
    if not self.edit.hudWas and ad.setSettingState ~= nil then pcall(ad.setSettingState, "showHUD", 2) end
    -- le HUD s'ouvre en mode normal (Conduite) ; l'éditeur reste sur son bouton du HUD
    if g_inputBinding ~= nil then g_inputBinding:setShowMouseCursor(true) end
    local okP, errP = pcall(self.placeHud, self, true)
    if not okP then log("ERREUR place du HUD : %s", tostring(errP)) end
    self.swallowT = g_time
    log("HUD d'édition des routes ouvert")
end

function F:closeEdit(v)
    local ad = AD()
    local e = self.edit
    self.edit = nil
    self.swallowT = g_time
    if ad == nil then return end
    if self:editorOn() then
        local cv = ctrl()
        local ev = v or (e ~= nil and e.v) or nil
        if cv ~= nil and cv == ev then
            input(cv, "input_debug")
        elseif ad.setEditorMode ~= nil and ad.EDITOR_OFF ~= nil then
            pcall(ad.setEditorMode, ad.EDITOR_OFF)
        end
    end
    if e ~= nil and e.hudWas == false and ad.setSettingState ~= nil then pcall(ad.setSettingState, "showHUD", 1) end
    -- (36b) HUD remis à sa place d'avant (celle des véhicules sans terminal)
    local hud = ad.Hud
    if e ~= nil and e.hudX ~= nil and hud ~= nil and type(hud.createHudAt) == "function" then
        pcall(hud.createHudAt, hud, e.hudX, e.hudY)
    end
    if g_inputBinding ~= nil and not AS_Terminal.touch and ctrl() == (v or (e ~= nil and e.v)) then
        g_inputBinding:setShowMouseCursor(false)
    end
    log("HUD d'édition des routes fermé")
end

-- (36b) HUD de FarmPilot posé à GAUCHE de l'icône, hauts alignés (à droite s'il n'y a pas la place)
function F:placeHud(remember)
    local ad = AD()
    local hud = ad ~= nil and ad.Hud or nil
    if hud == nil or type(hud.posX) ~= "number" or type(hud.posY) ~= "number" or type(hud.createHudAt) ~= "function" then return end
    if remember and self.edit ~= nil then self.edit.hudX, self.edit.hudY = hud.posX, hud.posY end
    local x, y, w, h = self:iconRect()
    local hw = hud.width or 0.2
    local topOff = ((hud.rowHeader or (hud.posY + (hud.height or 0.2))) + (hud.headerHeight or 0)) - hud.posY
    local gap = 0.006
    local nx = x - gap - hw
    if nx < 0 then nx = x + w + gap end
    hud:createHudAt(nx, (y + h) - topOff)
end

function F:toggleEdit(v)
    if self:editing() then self:closeEdit(v) else self:openEdit(v) end
end

function F:hookHud()
    if self.hooked then return true end
    if not U().isFarmPilot() then return false end
    local H = G("AutoDriveHud")
    if H == nil or type(H.drawHud) ~= "function" or type(H.mouseEvent) ~= "function" or type(H.toggleHud) ~= "function" then return false end
    self.hooked = true
    local origDraw, origMouse, origToggle, origOver = H.drawHud, H.mouseEvent, H.toggleHud, H.isMouseOverHud
    H.drawHud = function(hud, vehicle, ...)
        if F:blockNow(vehicle) then return end
        return origDraw(hud, vehicle, ...)
    end
    H.mouseEvent = function(hud, vehicle, posX, posY, ...)
        if F:blockNow(vehicle) or (F.swallowT ~= nil and F.swallowT == g_time) then return end
        -- (36b) appui, glisser ou clic sur l'icône : pas pour le HUD ni l'éditeur
        if F.press ~= nil or F:overIcon(posX, posY) then return end
        return origMouse(hud, vehicle, posX, posY, ...)
    end
    -- croix du HUD et touche « HUD » de FarmPilot : ouvre / ferme le HUD d'édition
    H.toggleHud = function(hud, vehicle, ...)
        local ad = AD()
        if ad ~= nil and ad.aiFrameOpen then return origToggle(hud, vehicle, ...) end
        local cv = vehicle or ctrl()
        local okB, hidden = pcall(F.hudHidden, F, cv)
        if okB and hidden then
            local ok, err = pcall(F.toggleEdit, F, cv)
            if not ok then log("ERREUR HUD d'édition : %s", tostring(err)) end
            return
        end
        return origToggle(hud, vehicle, ...)
    end
    if type(origOver) == "function" then
        H.isMouseOverHud = function(hud, x, y, ...)
            if F:blockNow(ctrl()) then return false end
            return origOver(hud, x, y, ...)
        end
    end
    log("HUD caché sur les véhicules avec le terminal (réglage « %s »)", T("fpHud"))
    return true
end

-- (36b) place de l'icône : la sienne (glissée par le joueur), sinon à droite au milieu de l'écran
F.ICON_H = 0.058                   -- hauteur de l'icône (part de l'écran, x échelle de l'interface)
local function posFile()
    local dir = (AS_Settings ~= nil and AS_Settings.MOD_DIR_NAME) or "FS25_AutoSwitch"
    return getUserProfileAppPath() .. "modSettings/" .. dir .. "/", "terminal_farmpilot.xml"
end

function F:loadIconPos()
    self.posLoaded = true
    local dir, name = posFile()
    if not fileExists(dir .. name) then return end
    local xml = loadXMLFile("asTerminalFp", dir .. name)
    if xml == nil or xml == 0 then return end
    local x, y = getXMLFloat(xml, "farmPilot.icon#x"), getXMLFloat(xml, "farmPilot.icon#y")
    if x ~= nil and y ~= nil then self.iconPos = { x = x, y = y } end
    delete(xml)
end

function F:saveIconPos()
    local dir, name = posFile()
    createFolder(getUserProfileAppPath() .. "modSettings/")
    createFolder(dir)
    local xml = createXMLFile("asTerminalFp", dir .. name, "farmPilot")
    if xml == nil or xml == 0 then return end
    if self.iconPos ~= nil then
        setXMLFloat(xml, "farmPilot.icon#x", self.iconPos.x)
        setXMLFloat(xml, "farmPilot.icon#y", self.iconPos.y)
    end
    saveXMLFile(xml)
    delete(xml)
end

function F:iconSize()
    local s = 1
    if g_gameSettings ~= nil and g_gameSettings.getValue ~= nil then s = g_gameSettings:getValue("uiScale") or 1 end
    local h = self.ICON_H * s
    return h * (g_screenHeight or 1080) / math.max(1, g_screenWidth or 1920), h
end

function F:iconRect()
    if not self.posLoaded then pcall(self.loadIconPos, self) end
    local w, h = self:iconSize()
    local p = self.iconPos
    local x, y = 1 - w - 0.02, 0.60
    if p ~= nil then x, y = p.x, p.y end
    return clamp(x, 0, 1 - w), clamp(y, 0, 1 - h), w, h
end

function F:overIcon(px, py)
    local b = self.iconBox
    if b == nil or type(px) ~= "number" or type(py) ~= "number" then return false end
    return px >= b.x and px <= b.x + b.w and py >= b.y and py <= b.y + b.h
end

function F:iconOverlay()
    if self.iconOv ~= nil then return self.iconOv end
    self.iconOv = false
    local ad = AD()
    local dir = ad ~= nil and ad.directory or nil
    if type(dir) == "string" and createImageOverlay ~= nil then
        local ok, ov = pcall(createImageOverlay, dir .. "icon_FarmPilot.dds")
        if ok and ov ~= nil and ov ~= 0 then self.iconOv = ov end
    end
    return self.iconOv
end

function F:drawIcon()
    self.iconBox = nil
    if not self.hooked then return end
    local v = ctrl()
    if v == nil or not self:hudHidden(v) then return end
    if g_gui ~= nil and g_gui.getIsGuiVisible ~= nil and g_gui:getIsGuiVisible() then return end
    local hud = g_currentMission ~= nil and g_currentMission.hud or nil
    if hud ~= nil and hud.getIsVisible ~= nil and not hud:getIsVisible() then return end
    local x, y, w, h = self:iconRect()
    self.iconBox = { x = x, y = y, w = w, h = h }
    local on = self:editing()
    local hov = self.hover == true
    if hov then drawFilledRect(x, y, w, h, 0.06, 0.07, 0.08, 0.95) else drawFilledRect(x, y, w, h, 0.01, 0.012, 0.015, 0.85) end
    local ov = self:iconOverlay()
    if ov then
        renderOverlay(ov, x + w * 0.08, y + h * 0.08, w * 0.84, h * 0.84)
    else
        setTextAlignment(RenderText.ALIGN_CENTER); setTextBold(true); setTextColor(1, 1, 1, 1)
        renderText(x + w * 0.5, y + h * 0.32, h * 0.4, "FP")
        setTextAlignment(RenderText.ALIGN_LEFT); setTextBold(false)
    end
    local r, g, b = 0.20, 0.22, 0.25
    if on then r, g, b = 0.05, 0.60, 0.12 elseif hov then r, g, b = 0.80, 0.80, 0.80 end
    local bx, by = 2 / math.max(1, g_screenWidth or 1920), 2 / math.max(1, g_screenHeight or 1080)
    drawFilledRect(x, y, w, by, r, g, b, 1)
    drawFilledRect(x, y + h - by, w, by, r, g, b, 1)
    drawFilledRect(x, y, bx, h, r, g, b, 1)
    drawFilledRect(x + w - bx, y, bx, h, r, g, b, 1)
    -- bulle au survol
    if hov then
        setTextBold(false); setTextColor(1, 1, 1, 1)
        local txt = on and T("fpIconClose") or T("fpIconOpen")
        local lang = g_languageShortName
        local hint = lang == "fr" and "glisser pour déplacer" or (lang == "de" and "Ziehen zum Verschieben" or "drag to move")
        local tw = getTextWidth ~= nil and getTextWidth(0.013, txt) or 0.15
        if x + w + 0.006 + tw <= 1 then
            setTextAlignment(RenderText.ALIGN_LEFT)
            renderText(x + w + 0.006, y + h * 0.55, 0.013, txt)
            setTextColor(0.75, 0.75, 0.75, 1)
            renderText(x + w + 0.006, y + h * 0.2, 0.011, hint)
        else
            setTextAlignment(RenderText.ALIGN_RIGHT)
            renderText(x - 0.006, y + h * 0.55, 0.013, txt)
            setTextColor(0.75, 0.75, 0.75, 1)
            renderText(x - 0.006, y + h * 0.2, 0.011, hint)
        end
        setTextAlignment(RenderText.ALIGN_LEFT); setTextColor(1, 1, 1, 1)
    end
end

-- (36b) clic = ouvre / ferme le HUD d'édition ; appui + glisser = déplace l'icône (place gardée)
function F:iconMouse(px, py, isDown, isUp, button)
    local b = self.iconBox
    if b == nil or g_inputBinding == nil or not g_inputBinding:getShowMouseCursor() then
        self.hover, self.press = false, nil
        return
    end
    local p = self.press
    if p ~= nil then
        self.hover = true
        local dx, dy = px - p.mx, py - p.my
        if not p.moved and (math.abs(dx) > 0.004 or math.abs(dy) > 0.007) then p.moved = true end
        if p.moved then
            local w, h = self:iconSize()
            self.iconPos = { x = clamp(p.ix + dx, 0, 1 - w), y = clamp(p.iy + dy, 0, 1 - h) }
        end
        if isUp and button == 1 then
            self.press = nil
            if p.moved then
                local okS, errS = pcall(self.saveIconPos, self)
                if not okS then log("ERREUR place de l'icône : %s", tostring(errS)) end
                if self.edit ~= nil then pcall(self.placeHud, self, false) end
                log("icône déplacée : %.3f / %.3f", self.iconPos.x, self.iconPos.y)
            else
                local v = ctrl()
                if v ~= nil then
                    local ok, err = pcall(self.toggleEdit, self, v)
                    if not ok then log("ERREUR icône : %s", tostring(err)) end
                end
            end
        end
        return
    end
    local inside = self:overIcon(px, py)
    self.hover = inside
    if inside and isDown and button == 1 then self.press = { mx = px, my = py, ix = b.x, iy = b.y } end
end

-- écouteur du jeu (icône, accroche du HUD, fermeture en quittant le véhicule)
local listener = {}
function listener:loadMap() end
function listener:update(dt)
    if not F.hooked and (g_time or 0) >= (F.hookNext or 0) then
        F.hookNext = (g_time or 0) + 5000
        local ok, err = pcall(F.hookHud, F)
        if not ok then logOnce("hook", "ERREUR accroche du HUD : %s", tostring(err)) end
    end
    -- (07/11) changement de véhicule : le HUD d'édition reste ouvert et suit le véhicule conduit ; il ne se ferme
    -- qu'avec sa croix, l'icône ou la touche HUD de FarmPilot
    if F.edit ~= nil then
        local cv = ctrl()
        if setting("showHUD") ~= true then
            -- fermé par la croix de FarmPilot sur un véhicule sans terminal : plus de HUD d'édition
            F.edit = nil
        elseif cv ~= nil and cv ~= F.edit.v then
            F.edit.v = cv
        end
    end
    if F.sub ~= nil and AS_Terminal.page ~= "fp" then F.sub = nil end
end
function listener:draw()
    local ok, err = pcall(F.drawIcon, F)
    if not ok then logOnce("icon", "ERREUR icône : %s", tostring(err)) end
end
function listener:mouseEvent(posX, posY, isDown, isUp, button)
    local ok, err = pcall(F.iconMouse, F, posX, posY, isDown, isUp, button)
    if not ok then logOnce("mouse", "ERREUR souris icône : %s", tostring(err)) end
end
function listener:deleteMap()
    if F.iconOv then pcall(delete, F.iconOv) end
    F.iconOv, F.edit, F.sub, F.iconBox, F.press = nil, nil, nil, nil, nil
    F.mkCache, F.ftCache = nil, nil
end
F.listener = listener

addModEventListener(listener)
