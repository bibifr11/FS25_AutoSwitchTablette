-------------------------------------------------------------------------------
-- AutoSwitch - Terminal : CHERCHER UN TRAVAIL (31/10, 01/11)
--   Parcours Courseplay enregistrés (menu Courseplay > Parcours) dont les points
--   sont dans le champ où l'on est (ou le plus proche à moins de 150 m), triés
--   selon la largeur de l'outil attelé. Un clic charge le parcours par la fonction
--   « Charger » de Courseplay lui-même (vehicle:appendLoadedCpCourse).
--   (01/11) aussi les champs LIÉS : champ agrandi (la terre travaillée continue sans coupure
--   du bord de ce champ jusqu'au champ voisin) ou champ couvert avec celui-ci par un même
--   parcours enregistré (ex. « Champ 52_53 ») ; pour eux, seulement à la largeur de l'outil.
--   Fichiers lus une fois (cache), petit à petit sur la page GUIDAGE (pas d'à-coup).
-------------------------------------------------------------------------------
AS_TerminalCourses = {}
AS_TerminalCourses.MAX_FILES = 400        -- garde-fou : fichiers lus par recherche
AS_TerminalCourses.SAMPLES = 12           -- points de parcours testés par fichier
AS_TerminalCourses.SHOWN = 5
AS_TerminalCourses.FILES_PER_STEP = 6     -- recherche automatique : fichiers lus par image
AS_TerminalCourses.LINK_STEP = 10         -- champ agrandi : un rayon tous les 10 m de bord
AS_TerminalCourses.LINK_RAY = 40          -- ... testé jusqu'à 40 m vers l'extérieur
AS_TerminalCourses.LINK_DS = 2.5          -- ... par pas de 2,5 m
AS_TerminalCourses.LINK_TTL = 300000      -- liens gardés 5 min
AS_TerminalCourses.results = nil         -- { vehicle, field, width, list = { { file, dir, name, w, h, ok, fieldTxt } } }
AS_TerminalCourses.cache = {}             -- [chemin] = { w, h, name, nWp, pts = { {x, z} } }
AS_TerminalCourses.links = {}             -- [champ] = { t, list = { champ, ... } }
AS_TerminalCourses.job = nil

local function log(fmt, ...)
    (AS.rawPrint or print)("[AS_TerminalCourses] " .. string.format(fmt, ...))
end

local function U() return AS_Terminal.ui end

-- même champ : même objet, ou même parcelle (un champ découpé en plusieurs morceaux)
local function sameField(a, b)
    if a == nil or b == nil then return false end
    if a == b then return true end
    local fa, fb = a.farmland, b.farmland
    return fa ~= nil and fb ~= nil and fa.id ~= nil and fa.id == fb.id
end
AS_TerminalCourses.sameField = sameField

-- champ sous le véhicule, sinon le plus proche (anneaux de 15 m jusqu'à 150 m)
function AS_TerminalCourses:nearField(v)
    local x, _, z = getWorldTranslation(v.rootNode)
    local f = U().fieldAt(x, z)
    if f ~= nil then return f end
    for r = 15, 150, 15 do
        for k = 0, 15 do
            local a = k / 16 * 2 * math.pi
            f = U().fieldAt(x + math.cos(a) * r, z + math.sin(a) * r)
            if f ~= nil then return f end
        end
    end
    return nil
end

-- largeur de travail de ce qui est attelé (ou de la coupe de la machine)
local function toolWidth(d)
    local w = 0
    if d ~= nil and d.mach ~= nil and d.mach.header ~= nil and d.mach.header.width ~= nil then w = d.mach.header.width end
    if d ~= nil and d.mach ~= nil and d.mach.width ~= nil and d.mach.width > w then w = d.mach.width end
    for _, t in ipairs(d ~= nil and d.tools or {}) do
        if (t.width or 0) > w then w = t.width end
    end
    return w > 0 and w or nil
end
AS_TerminalCourses.toolWidth = toolWidth

-- tous les fichiers de parcours, avec le dossier qui les contient (« Moisso 6M »...)
local function collect(dir, parentName, out, depth)
    if dir == nil or depth > 5 or #out >= AS_TerminalCourses.MAX_FILES then return end
    pcall(dir.refresh, dir)
    local okF, files = pcall(dir.getFiles, dir)
    if okF and type(files) == "table" then
        for _, f in ipairs(files) do
            if #out >= AS_TerminalCourses.MAX_FILES then return end
            out[#out + 1] = { file = f, dir = parentName }
        end
    end
    local okD, dirs = pcall(dir.getDirectories, dir)
    if okD and type(dirs) == "table" then
        for _, sub in ipairs(dirs) do
            local okN, n = pcall(sub.getName, sub)
            collect(sub, okN and n or parentName, out, depth + 1)
        end
    end
end

-- lit la largeur, les tournières et un échantillon de points répartis sur tout le parcours
local function readCourse(path)
    if path == nil or not fileExists(path) then return nil end
    local xml = loadXMLFile("asCpCourse", path)
    if xml == nil or xml == 0 then return nil end
    local base = "Courses.Course(0)"
    local info = nil
    if hasXMLProperty(xml, base) then
        info = { w = getXMLFloat(xml, base .. "#workWidth"), h = getXMLInt(xml, base .. "#numHeadlands"),
            name = getXMLString(xml, base .. "#name"), pts = {} }
        -- nombre de points (par pas de 64 puis 1), pour répartir l'échantillon sur tout le parcours
        local n = 0
        while hasXMLProperty(xml, string.format("%s.wp(%d)", base, n + 64)) do n = n + 64 end
        while hasXMLProperty(xml, string.format("%s.wp(%d)", base, n)) do n = n + 1 end
        info.nWp = n
        if n > 0 then
            local step = math.max(1, math.floor(n / AS_TerminalCourses.SAMPLES))
            for i = 0, n - 1, step do
                local pos = getXMLString(xml, string.format("%s.wp(%d)#position", base, i))
                if pos ~= nil then
                    local x, _, z = pos:match("^%s*(%S+)%s+(%S+)%s+(%S+)")
                    x, z = tonumber(x), tonumber(z)
                    if x ~= nil and z ~= nil then info.pts[#info.pts + 1] = { x, z } end
                end
                if #info.pts >= AS_TerminalCourses.SAMPLES then break end
            end
        end
    end
    delete(xml)
    return info
end

-- terre de champ (labourée, semée...) à cet endroit ?
local function groundAt(x, z)
    if FSDensityMapUtil == nil or FSDensityMapUtil.getFieldDataAtWorldPosition == nil then return nil end
    local y = 0
    if getTerrainHeightAtWorldPos ~= nil and g_currentMission ~= nil and g_currentMission.terrainRootNode ~= nil then
        local okY, yy = pcall(getTerrainHeightAtWorldPos, g_currentMission.terrainRootNode, x, 0, z)
        if okY and yy ~= nil then y = yy end
    end
    local ok, on = pcall(FSDensityMapUtil.getFieldDataAtWorldPosition, x, y, z)
    if not ok then return nil end
    return on == true
end
AS_TerminalCourses.groundAt = groundAt

-- (01/11) champs agrandis : depuis le bord de ce champ, des rayons vers l'extérieur ; si la terre
-- de champ continue sans coupure jusqu'à un autre champ, les deux ne font plus qu'un
function AS_TerminalCourses:linkedByGround(field)
    local now = g_time or 0
    local c = self.links[field]
    if c ~= nil and now - c.t < self.LINK_TTL and now >= c.t then return c.list, c.rays end
    local list, rays = {}, 0
    local border = AS_TerminalMap ~= nil and AS_TerminalMap.fieldBorder ~= nil and AS_TerminalMap.fieldBorder(field) or nil
    if border ~= nil and #border >= 3 and groundAt(border[1][1], border[1][2]) ~= nil then
        local ui = U()
        -- sens du polygone (aire signée) : la normale extérieure est à droite ou à gauche des segments
        local area = 0
        for i = 1, #border do
            local a, b = border[i], border[i % #border + 1]
            area = area + a[1] * b[2] - b[1] * a[2]
        end
        local sgn = area > 0 and 1 or -1
        local hits = {}
        for i = 1, #border do
            local a, b = border[i], border[i % #border + 1]
            local dx, dz = b[1] - a[1], b[2] - a[2]
            local len = math.sqrt(dx * dx + dz * dz)
            if len > 0.5 then
                dx, dz = dx / len, dz / len
                local nx, nz = dz * sgn, -dx * sgn
                local nRay = math.max(1, math.floor(len / self.LINK_STEP))
                for k = 0, nRay - 1 do
                    local t = (k + 0.5) / nRay * len
                    local px, pz = a[1] + dx * t, a[2] + dz * t
                    rays = rays + 1
                    local dist = self.LINK_DS
                    while dist <= self.LINK_RAY do
                        local qx, qz = px + nx * dist, pz + nz * dist
                        if groundAt(qx, qz) ~= true then break end
                        local f = ui.fieldAt(qx, qz)
                        if f ~= nil and not sameField(f, field) then
                            hits[f] = (hits[f] or 0) + 1
                            break
                        end
                        dist = dist + self.LINK_DS
                    end
                end
            end
        end
        for f, n in pairs(hits) do
            if n >= 2 then list[#list + 1] = f end
        end
        table.sort(list, function(x, y) return (tonumber(ui.fieldNumber(x)) or 0) < (tonumber(ui.fieldNumber(y)) or 0) end)
        local nums = {}
        for _, f in ipairs(list) do nums[#nums + 1] = tostring(ui.fieldNumber(f)) end
        log("champ %s : %d rayons depuis le bord, champ(s) agrandi(s) avec lui : %s", tostring(ui.fieldNumber(field)), rays,
            #nums > 0 and table.concat(nums, ", ") or "aucun")
    end
    self.links[field] = { t = now, list = list, rays = rays }
    return list, rays
end

-- début d'une recherche : liste des fichiers (lus ensuite, depuis le cache si possible)
function AS_TerminalCourses:startJob(v, d, auto)
    local field = self:nearField(v)
    local job = { vehicle = v, field = field, width = toolWidth(d), auto = auto, files = {}, i = 0, t = g_time or 0 }
    self.job = job
    if field == nil then job.msg = "cpFindNoField"; job.done = true; return job end
    local cp = U().cpGlobal("g_Courseplay")
    local storage = cp ~= nil and cp.courseStorage or nil
    if storage == nil or storage.getRootDirectory == nil then
        job.msg = "cpFindNoCp"; job.done = true
        log("recherche : stockage des parcours Courseplay introuvable (g_Courseplay %s)", tostring(cp))
        return job
    end
    local okR, root = pcall(storage.getRootDirectory, storage)
    if okR and root ~= nil then collect(root, "", job.files, 0) end
    return job
end

-- lit jusqu'à n fichiers (ceux déjà en cache ne comptent presque pas)
function AS_TerminalCourses:stepJob(job, n)
    local budget = n or math.huge
    while job.i < #job.files and budget > 0 do
        job.i = job.i + 1
        local e = job.files[job.i]
        local okP, path = pcall(e.file.getFullPath, e.file)
        e.path = okP and path or nil
        local info = e.path ~= nil and self.cache[e.path] or nil
        if info == nil and e.path ~= nil then
            local okI, r = pcall(readCourse, e.path)
            info = okI and r or false
            self.cache[e.path] = info
            budget = budget - 1
        else
            budget = budget - 0.05
        end
        e.info = info or nil
    end
    if job.i >= #job.files then job.done = true end
    return job.done
end

-- classement : ce champ, champs agrandis, champs couverts avec lui par un même parcours
function AS_TerminalCourses:finish(job)
    local ui = U()
    local res = { vehicle = job.vehicle, list = {}, done = true, auto = job.auto, width = job.width, t = g_time or 0 }
    self.results = res
    if job.msg ~= nil then
        res.msg = ui.T(job.msg)
        if job.msg == "cpFindNoField" then log("recherche : aucun champ à moins de 150 m") end
        return res
    end
    local field = job.field
    res.fieldObj = field
    res.field = ui.fieldNumber(field)
    local tw = job.width
    -- champs des points de chaque parcours
    local linked = {}
    local ground = self:linkedByGround(field)
    for _, f in ipairs(ground) do linked[f] = "ground" end
    for _, e in ipairs(job.files) do
        local info = e.info
        if info ~= nil and info.pts ~= nil then
            local by, nIn, tested = {}, 0, 0
            for _, p in ipairs(info.pts) do
                tested = tested + 1
                local f = ui.fieldAt(p[1], p[2])
                if f ~= nil then
                    if sameField(f, field) then nIn = nIn + 1
                    else by[f] = (by[f] or 0) + 1 end
                end
            end
            e.by, e.nIn, e.tested = by, nIn, tested
            -- un même parcours couvre ce champ et un autre : ils sont liés
            if tested > 0 and nIn / tested >= 0.2 then
                for f, k in pairs(by) do
                    if k / tested >= 0.2 and linked[f] == nil then linked[f] = "course" end
                end
            end
        end
    end
    local names = {}
    for f, how in pairs(linked) do names[#names + 1] = { n = tonumber(ui.fieldNumber(f)) or 0, how = how } end
    table.sort(names, function(a, b) return a.n < b.n end)
    local nums = {}
    for _, x in ipairs(names) do nums[#nums + 1] = tostring(x.n) end
    res.linkedTxt = #nums > 0 and table.concat(nums, "+") or nil
    for _, e in ipairs(job.files) do
        local info = e.info
        if info ~= nil and e.tested ~= nil and e.tested > 0 then
            local share = e.nIn / e.tested
            local lk, fl = 0, {}
            for f, k in pairs(e.by) do
                if linked[f] ~= nil then lk = lk + k; fl[#fl + 1] = tonumber(ui.fieldNumber(f)) or 0 end
            end
            local diff = (tw ~= nil and info.w ~= nil) and math.abs(info.w - tw) or 99
            local ok = tw ~= nil and info.w ~= nil and diff <= math.max(0.3, tw * 0.1)
            local mine = share >= 0.5
            local other = not mine and lk > 0 and (e.nIn + lk) / e.tested >= 0.5
            if mine or (other and ok) then
                table.sort(fl)
                local fs = {}
                if e.nIn > 0 then fs[#fs + 1] = tostring(res.field) end
                for _, n in ipairs(fl) do
                    if tostring(n) ~= fs[#fs] then fs[#fs + 1] = tostring(n) end
                end
                local okN, fname = pcall(e.file.getName, e.file)
                res.list[#res.list + 1] = { file = e.file, dir = e.dir, fname = okN and fname or (info.name or "?"),
                    w = info.w, h = info.h, diff = diff, ok = ok, mine = mine, fieldTxt = table.concat(fs, "+") }
            end
        end
    end
    -- d'abord la bonne largeur, puis ce champ avant les champs liés, puis le nom
    table.sort(res.list, function(a, b)
        if a.ok ~= b.ok then return a.ok end
        if a.mine ~= b.mine then return a.mine end
        if a.diff ~= b.diff then return a.diff < b.diff end
        return tostring(a.dir) .. tostring(a.fname) < tostring(b.dir) .. tostring(b.fname)
    end)
    local nMine = 0
    for _, e in ipairs(res.list) do if e.mine then nMine = nMine + 1 end end
    log("champ %s (liés : %s), outil %s m : %d fichier(s), %d parcours (%d de ce champ, %d de champs liés)%s",
        tostring(res.field), res.linkedTxt or "aucun", tw ~= nil and string.format("%.1f", tw) or "?", #job.files,
        #res.list, nMine, #res.list - nMine, job.auto and " [auto]" or "")
    if #res.list == 0 then res.msg = ui.T("cpFindNone") end
    return res
end

-- bouton CHERCHER : tout de suite
function AS_TerminalCourses:find(v, d)
    local job = self:startJob(v, d, false)
    self:stepJob(job)
    self.job = nil
    return self:finish(job)
end

-- (01/11) page GUIDAGE sans parcours : recherche automatique, quelques fichiers par image ;
-- relancée quand le champ, le véhicule ou la largeur de l'outil change
function AS_TerminalCourses:auto(v, d)
    local job = self.job
    if job ~= nil and job.vehicle == v and not job.done then
        if self:stepJob(job, self.FILES_PER_STEP) then
            self.job = nil
            self:finish(job)
        end
        return
    end
    local r = self.results
    local now = g_time or 0
    if r ~= nil and r.vehicle == v then
        -- contrôle peu coûteux toutes les 4 s : même champ, même outil ? (relu au plus tard après 1 min)
        local last = r.check or r.t or 0
        if now - last < 4000 and now >= last then return end
        r.check = now
        local f = self:nearField(v)
        local tw = toolWidth(d)
        local sameW = (tw == nil and r.width == nil) or (tw ~= nil and r.width ~= nil and math.abs(tw - r.width) < 0.05)
        if f == r.fieldObj and sameW and now - (r.t or 0) < 60000 and now >= (r.t or 0) then return end
    end
    self:startJob(v, d, true)
end

function AS_TerminalCourses:load(v, i)
    local r = self.results
    if r == nil or r.vehicle ~= v or i == nil or r.list[i] == nil then return end
    local e = r.list[i]
    if v.appendLoadedCpCourse == nil then U().warn(U().T("cpMissing")) return end
    local ok, res = pcall(v.appendLoadedCpCourse, v, e.file)
    if ok and res ~= false then
        r.loaded = i
        log("parcours chargé : %s / %s", tostring(e.dir), tostring(e.fname))
    else
        U().warn(U().T("cpFindLoadErr"))
        log("ERREUR chargement %s / %s : %s", tostring(e.dir), tostring(e.fname), tostring(res))
    end
end

-- (03/11) CHARGER SAUVEGARDE sous CHERCHER TRAVAIL : tous les parcours Courseplay
-- sauvegardés (dossier par dossier, par nom) ; largeur et tournières lues seulement pour les lignes affichées
function AS_TerminalCourses:savedList(v)
    local sv = self.saved
    local now = g_time or 0
    if sv ~= nil and sv.vehicle == v and now >= sv.t and now - sv.t < 10000 then return sv end
    sv = { vehicle = v, t = now, list = {} }
    self.saved = sv
    local cp = U().cpGlobal("g_Courseplay")
    local storage = cp ~= nil and cp.courseStorage or nil
    if storage == nil or storage.getRootDirectory == nil then sv.msg = "cpFindNoCp" return sv end
    local okR, root = pcall(storage.getRootDirectory, storage)
    local files = {}
    if okR and root ~= nil then collect(root, "", files, 0) end
    for _, e in ipairs(files) do
        local okN, n = pcall(e.file.getName, e.file)
        e.fname = okN and tostring(n) or "?"
        sv.list[#sv.list + 1] = e
    end
    table.sort(sv.list, function(a, b)
        local da, db = tostring(a.dir or ""):lower(), tostring(b.dir or ""):lower()
        if da ~= db then return da < db end
        return a.fname:lower() < b.fname:lower()
    end)
    if #sv.list == 0 then sv.msg = "cpSavesNone" end
    return sv
end
function AS_TerminalCourses:savedInfo(e)
    if e.info ~= nil then return e.info or nil end
    local okP, path = pcall(e.file.getFullPath, e.file)
    path = okP and path or nil
    local info = path ~= nil and self.cache[path] or nil
    if info == nil and path ~= nil then
        local okI, r = pcall(readCourse, path)
        info = okI and r or false
        self.cache[path] = info
    end
    e.info = info or false
    return info or nil
end
function AS_TerminalCourses:loadSaved(v, i)
    local sv = self.saved
    if sv == nil or sv.vehicle ~= v or sv.list[i] == nil then return false end
    local e = sv.list[i]
    if v.appendLoadedCpCourse == nil then U().warn(U().T("cpMissing")) return false end
    local ok, res = pcall(v.appendLoadedCpCourse, v, e.file)
    if ok and res ~= false then
        log("parcours sauvegardé chargé : %s / %s", tostring(e.dir), tostring(e.fname))
        return true
    end
    U().warn(U().T("cpFindLoadErr"))
    log("ERREUR chargement %s / %s : %s", tostring(e.dir), tostring(e.fname), tostring(res))
    return false
end

-- liste des parcours proposés ; box = { x, y, w, h } (page GUIDAGE) ou sous les réglages (PARCOURS)
function AS_TerminalCourses:drawList(v, ctx, y0, box, maxRows)
    local r = self.results
    local ui = U()
    local T, C = ui.T, ui.C
    local u, w = ctx.cx + 10, ctx.cw - 20
    local bottom = ctx.cy + ctx.ch
    if box ~= nil then u, w, y0, bottom = box.x, box.w, box.y, box.y + box.h end
    if r == nil or r.vehicle ~= v then
        if self.job ~= nil and self.job.vehicle == v and not self.job.done then
            ctx.text(u + 8, y0 + 14, 12, T("cpFindBusy"), C.gray, nil, true, w - 16)
        end
        return 0
    end
    local fieldTxt = tostring(r.field or "-")
    if r.linkedTxt ~= nil then fieldTxt = fieldTxt .. " (+" .. r.linkedTxt .. ")" end
    local head = string.format(T("cpFindHead"), fieldTxt, r.width ~= nil and string.format("%.1f m", r.width) or "-")
    ctx.text(u + 8, y0 + 12, 12, head, C.gray, nil, true, w - 16)
    if r.msg ~= nil then
        ctx.text(u + 8, y0 + 36, 13, r.msg, C.amber, nil, true, w - 16)
        return 0
    end
    local rowsFit = math.max(1, math.floor((bottom - (y0 + 18)) / 26))
    local n = 0
    for i, e in ipairs(r.list) do
        if i > math.min(maxRows or self.SHOWN, rowsFit) then break end
        local yy = y0 + 18 + (i - 1) * 26
        ctx.button(u, yy, w, 23, "cp_load" .. i, r.loaded == i)
        local label = (e.dir ~= nil and e.dir ~= "" and (e.dir .. "  -  ") or "") .. tostring(e.fname)
        ctx.text(u + 8, yy + 16, 12, label, C.white, nil, true, w * 0.62 - 56)
        local right = string.format("%s   %s   %s", string.format(T("cpFindField"), e.fieldTxt or "-"),
            e.w ~= nil and string.format("%.1f m", e.w) or "-", e.h ~= nil and string.format(T("cpFindHl"), e.h) or "")
        ctx.text(u + w - 34, yy + 16, 12, right, e.ok and C.lamp or C.gray, RenderText.ALIGN_RIGHT, true, w * 0.38)
        if e.ok then ctx.text(u + w - 8, yy + 16, 12, "OK", C.lamp, RenderText.ALIGN_RIGHT, true) end
        n = n + 1
    end
    return n
end
