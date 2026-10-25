--[[
  Slayers 2 (Project Slayers 2) — Quest Farm / Agrupamento / Combate
  Luau, single-file modular (secoes: CONFIG, LOG, UTIL, ENEMIES, MOVE, COMBAT, GATHER, QUEST, GUI, CORE)
  Usa so API padrao do Roblox + funcoes comuns de executor (todas checadas com fallback):
    gethui, fireproximityprompt, fireclickdetector, isnetworkowner, writefile/readfile/isfile
  NAO conhece remotes/paths internos do jogo. Tudo que depende do jogo esta marcado com  -- FILL:
  Nao rodei isso (sem Luau aqui) — teste em alt.
]]

if getgenv and getgenv().S2F_Cleanup then pcall(getgenv().S2F_Cleanup) end

local Players        = game:GetService("Players")
local RunService     = game:GetService("RunService")
local Workspace      = game:GetService("Workspace")
local PathfindingSvc = game:GetService("PathfindingService")
local UIS            = game:GetService("UserInputService")
local VIM            = game:GetService("VirtualInputManager")
local HttpService    = game:GetService("HttpService")
local lp             = Players.LocalPlayer

---------------------------------------------------------------------
-- CONFIG
---------------------------------------------------------------------
local SAVE_FILE = "Slayers2Farm.json"

local DEFAULT = {
  core   = { tick = 0.1 },
  scan   = { root = "Workspace", range = 120 },  -- FILL: se os mobs ficam numa pasta (ex.: Workspace.Mobs), ponha o caminho aqui (reduz custo do scan)
  quest  = {
    enabled = false, preset = "Krue - Bandits (Lv 1-6)",
    npc = "Krue", enemyPattern = "Bandit", killTarget = 3,
    repeatQuest = true, huntTimeout = 120, dialogWait = 2.0,
  },
  gather = {
    enabled = false, centerMode = "Frente do jogador", -- "Frente do jogador" | "Ponto fixo"
    fixed = { 0, 0, 0 }, hasFixed = false,
    radius = 12, distance = 10, maxEnemies = 10, interval = 0.2,
  },
  combat = {
    enabled = false, targetMode = "Mais proximo", -- "Mais proximo" | "Mais distante" | "Da quest atual"
    mode = "Individual",                           -- "Individual" | "Priorizar grupos"
    weapon = "(use o que esta equipado)",
    distance = 6, attackRange = 10, interval = 0.25, targetTimeout = 10,
    useM1 = true,
    -- FILL: keybinds/cooldowns reais de cada move (varia por respiracao/arma). Deixe desligado ate preencher.
    skills = {
      { enabled = false, key = "Z", cd = 8 },
      { enabled = false, key = "X", cd = 8 },
      { enabled = false, key = "C", cd = 10 },
      { enabled = false, key = "V", cd = 12 },
    },
  },
  move = { mode = "Automatica", leashEnabled = true, leashRadius = 150, anchor = { 0, 0, 0 }, hasAnchor = false },
  ui   = { toggleKey = "RightShift", scale = 1 },
}

local function deepcopy(t)
  if type(t) ~= "table" then return t end
  local o = {}
  for k, v in pairs(t) do o[k] = deepcopy(v) end
  return o
end
local function applyTable(dst, src)
  for k, v in pairs(src) do
    if type(v) == "table" and type(dst[k]) == "table" then applyTable(dst[k], v) else dst[k] = v end
  end
end
local CFG = deepcopy(DEFAULT)

-- Presets vindos de guias publicos (NPC e faixa de nivel). enemyPattern = chute pelo nome da quest — confira o nome real do mob no Explorer.
local PRESETS = {
  { name = "Krue - Bandits (Lv 1-6)",         npc = "Krue",    enemy = "Bandit", count = 3 },
  { name = "Krue - Mini Boss Zuko (Lv 7+)",   npc = "Krue",    enemy = "Zuko",   count = 1 },
  { name = "Wagwan - Guards (Lv 40+)",        npc = "Wagwan",  enemy = "Guard",  count = 5 },
  { name = "Goro - Demonios Lv 75 (75-100)",  npc = "Goro",    enemy = "Demon",  count = 5 },
  { name = "Tomoi - Lv 90 (90-105)",          npc = "Tomoi",   enemy = "",       count = 5 },
  { name = "Shiro - Lv 100",                  npc = "Shiro",   enemy = "",       count = 5 },
  { name = "Mitsu - Frost Demon Lv 105+",     npc = "Mitsu",   enemy = "Demon",  count = 5 },
  { name = "Personalizada",                   npc = "",        enemy = "",       count = 5 },
}

---------------------------------------------------------------------
-- LOG
---------------------------------------------------------------------
local Log = { lines = {}, dirty = true }
function Log.add(msg)
  table.insert(Log.lines, os.date("%H:%M:%S") .. "  " .. tostring(msg))
  if #Log.lines > 80 then table.remove(Log.lines, 1) end
  Log.dirty = true
end

---------------------------------------------------------------------
-- UTIL
---------------------------------------------------------------------
local function hrp() local c = lp.Character return c and c:FindFirstChild("HumanoidRootPart") end
local function hum() local c = lp.Character return c and c:FindFirstChildOfClass("Humanoid") end
local function alive() local h = hum() return h ~= nil and h.Health > 0 end
local function v3(t) return Vector3.new(t[1], t[2], t[3]) end
local function flat(a, b) return (Vector3.new(a.X, 0, a.Z) - Vector3.new(b.X, 0, b.Z)).Magnitude end

local function resolve(path)
  local cur = game
  for seg in tostring(path):gmatch("[^%.]+") do
    if seg ~= "game" then
      cur = cur:FindFirstChild(seg)
      if not cur then return nil end
    end
  end
  return cur
end

local function matchPattern(name)
  local p = CFG.quest.enemyPattern
  if p == "" then return true end
  return string.find(name:lower(), p:lower(), 1, true) ~= nil
end

local function tap(key)
  local ok, kc = pcall(function() return Enum.KeyCode[key] end)
  if not ok or not kc then return false end
  VIM:SendKeyEvent(true, kc, false, game)
  task.delay(0.05, function() VIM:SendKeyEvent(false, kc, false, game) end)
  return true
end
local function click()
  local cam = Workspace.CurrentCamera
  if not cam then return end
  local s = cam.ViewportSize
  VIM:SendMouseButtonEvent(s.X / 2, s.Y / 2, 0, true, game, 0)
  task.delay(0.04, function() VIM:SendMouseButtonEvent(s.X / 2, s.Y / 2, 0, false, game, 0) end)
end

---------------------------------------------------------------------
-- ENEMIES  (scan por Humanoid que nao e jogador; cache de 1s)
---------------------------------------------------------------------
local Enemies = { cache = {}, t = 0 }
function Enemies.refresh()
  if os.clock() - Enemies.t < 1 then return end
  Enemies.t = os.clock()
  local root = resolve(CFG.scan.root) or Workspace
  local out = {}
  for _, d in ipairs(root:GetDescendants()) do
    if d:IsA("Humanoid") then
      local m = d.Parent
      if m and m:IsA("Model") and m ~= lp.Character and not Players:GetPlayerFromCharacter(m) then out[#out + 1] = m end
    end
  end
  Enemies.cache = out
end
-- questOnly=true aplica o filtro de nome da quest. Modelos com ProximityPrompt (NPCs de quest/loja) sao ignorados.
function Enemies.list(questOnly)
  Enemies.refresh()
  local r = hrp()
  if not r then return {} end
  local res = {}
  for _, m in ipairs(Enemies.cache) do
    local h = m:FindFirstChildOfClass("Humanoid")
    local er = m:FindFirstChild("HumanoidRootPart")
    if h and er and h.Health > 0 and m:IsDescendantOf(Workspace) and not m:FindFirstChildWhichIsA("ProximityPrompt", true) then
      local d = (er.Position - r.Position).Magnitude
      if d <= CFG.scan.range and (not questOnly or matchPattern(m.Name)) then
        res[#res + 1] = { model = m, hum = h, root = er, dist = d }
      end
    end
  end
  return res
end

---------------------------------------------------------------------
-- MOVE  (um dono por vez; prioridade leash > combat > quest)
---------------------------------------------------------------------
local Move = { goal = nil, owner = nil, stop = 4, wps = nil, wi = 2, lastPlan = 0, lastPos = nil, lastPosT = 0, fails = 0 }
local PRIO = { quest = 1, combat = 2, leash = 3 }

function Move.Clear()
  Move.goal, Move.owner, Move.wps, Move.fails = nil, nil, nil, 0
  local h, r = hum(), hrp()
  if h and r then h:MoveTo(r.Position) end
end
function Move.Release(owner) if Move.owner == owner then Move.Clear() end end
function Move.Request(owner, pos, stop)
  if CFG.move.mode ~= "Automatica" then return false end -- modo manual: voce anda
  if Move.owner and Move.owner ~= owner and (PRIO[Move.owner] or 0) > (PRIO[owner] or 0) then return false end
  Move.owner, Move.stop = owner, stop or 4
  if not Move.goal or (Move.goal - pos).Magnitude > 3 then Move.goal = pos; Move.wps = nil end
  return true
end
function Move.Arrived()
  local r = hrp()
  return r ~= nil and Move.goal ~= nil and flat(r.Position, Move.goal) <= Move.stop + 1
end

function Move.Step()
  local goal = Move.goal
  if not goal then return end
  local r, h = hrp(), hum()
  if not r or not h or h.Health <= 0 then return end
  local now = os.clock()
  local d = flat(r.Position, goal)
  if d <= Move.stop then h:MoveTo(r.Position); Move.fails = 0; return end

  -- anti-trava: sem progresso em 1.5s => pula e replaneja; 4 falhas => aborta destino
  if not Move.lastPos or now - Move.lastPosT > 1.5 then
    if Move.lastPos and (r.Position - Move.lastPos).Magnitude < 1 then
      Move.fails += 1; h.Jump = true; Move.wps = nil
      if Move.fails >= 4 then Log.add("preso/sem caminho, destino abortado"); Move.Clear(); return end
    else
      Move.fails = 0
    end
    Move.lastPos, Move.lastPosT = r.Position, now
  end

  if d < 14 then h:MoveTo(goal); return end
  if not Move.wps and now - Move.lastPlan > 0.5 then
    Move.lastPlan = now
    local path = PathfindingSvc:CreatePath({ AgentRadius = 2, AgentHeight = 5, AgentCanJump = true })
    local ok = pcall(function() path:ComputeAsync(r.Position, goal) end)
    if ok and path.Status == Enum.PathStatus.Success then
      Move.wps, Move.wi = path:GetWaypoints(), 2
    else
      h:MoveTo(goal) -- sem caminho: tenta reto
      return
    end
  end
  local wp = Move.wps and Move.wps[Move.wi]
  if not wp then Move.wps = nil; return end
  if wp.Action == Enum.PathWaypointAction.Jump then h.Jump = true end
  h:MoveTo(wp.Position)
  if flat(wp.Position, r.Position) < 3 then Move.wi += 1 end
end

---------------------------------------------------------------------
-- COMBAT
---------------------------------------------------------------------
local Combat = { target = nil, since = 0, lastHp = 0, lastHpT = 0, lastAtk = 0, skillT = {}, blacklist = {}, tracked = setmetatable({}, { __mode = "k" }), kills = 0, onKill = {}, forced = false, status = "parado" }

function Combat.active() return CFG.combat.enabled or Combat.forced end

local function pickTarget()
  local list = Enemies.list(CFG.combat.targetMode == "Da quest atual")
  local now, cand = os.clock(), {}
  for _, e in ipairs(list) do
    if not Combat.blacklist[e.model] or Combat.blacklist[e.model] < now then cand[#cand + 1] = e end
  end
  if #cand == 0 then return nil end
  local best, bs
  for _, e in ipairs(cand) do
    local s
    if CFG.combat.targetMode == "Mais distante" then s = e.dist else s = -e.dist end
    if CFG.combat.mode == "Priorizar grupos" then
      local n = 0
      for _, o in ipairs(cand) do if (o.root.Position - e.root.Position).Magnitude <= 14 then n += 1 end end
      s = n * 1000 + s
    end
    if not bs or s > bs then best, bs = e, s end
  end
  return best
end

function Combat.Step()
  if not Combat.active() then Combat.status = "parado"; Move.Release("combat"); return end
  local r = hrp()
  if not r or not alive() then Combat.status = "sem personagem"; return end
  local now = os.clock()

  local t = Combat.target
  if t and (not t.model:IsDescendantOf(Workspace) or t.hum.Health <= 0) then t = nil end
  if t and now - Combat.since > CFG.combat.targetTimeout and now - Combat.lastHpT > CFG.combat.targetTimeout * 0.6 then
    Combat.blacklist[t.model] = now + 15; Log.add("alvo inalcancavel/sem dano, ignorando: " .. t.model.Name); t = nil
  end
  if not t then
    t = pickTarget()
    if t then
      Combat.since, Combat.lastHp, Combat.lastHpT = now, t.hum.Health, now
      if not Combat.tracked[t.model] then
        Combat.tracked[t.model] = true
        local m = t.model
        t.hum.Died:Connect(function()
          Combat.kills += 1
          for _, cb in ipairs(Combat.onKill) do pcall(cb, m) end
        end)
      end
      if not CFG.move.hasAnchor and Combat.forced then
        CFG.move.anchor = { t.root.Position.X, t.root.Position.Y, t.root.Position.Z }; CFG.move.hasAnchor = true
        Log.add("regiao da quest definida automaticamente")
      end
    end
  end
  Combat.target = t
  if not t then Combat.status = "sem alvo"; Move.Release("combat"); return end
  if t.hum.Health < Combat.lastHp - 0.01 then Combat.lastHpT = now end
  Combat.lastHp = t.hum.Health

  local d = (t.root.Position - r.Position).Magnitude
  Combat.status = "atacando " .. t.model.Name
  if d > CFG.combat.distance + 1.5 then
    Move.Request("combat", t.root.Position, CFG.combat.distance)
  else
    Move.Release("combat")
  end
  if d > CFG.combat.attackRange then return end -- fora do alcance configurado: nao ataca

  r.CFrame = CFrame.lookAt(r.Position, Vector3.new(t.root.Position.X, r.Position.Y, t.root.Position.Z))
  if now - Combat.lastAtk < CFG.combat.interval then return end
  Combat.lastAtk = now
  for i, s in ipairs(CFG.combat.skills) do
    if s.enabled and s.key ~= "" and now - (Combat.skillT[i] or 0) >= s.cd then
      if tap(s.key) then Combat.skillT[i] = now; return end
    end
  end
  if CFG.combat.useM1 then click() end
end

---------------------------------------------------------------------
-- GATHER  (puxa mobs pro ponto; so funciona onde voce tem network ownership)
---------------------------------------------------------------------
local Gather = { last = 0, offs = setmetatable({}, { __mode = "k" }), status = "parado", moved = 0, notOwned = 0 }

function Gather.Center()
  local r = hrp()
  if not r then return nil end
  if CFG.gather.centerMode == "Ponto fixo" and CFG.gather.hasFixed then return v3(CFG.gather.fixed) end
  return r.Position + r.CFrame.LookVector * CFG.gather.distance
end

function Gather.Step()
  if not CFG.gather.enabled then Gather.status = "parado"; return end
  local now = os.clock()
  if now - Gather.last < CFG.gather.interval then return end
  Gather.last = now
  local c = Gather.Center()
  if not c then return end
  local list = Enemies.list(true)
  table.sort(list, function(a, b) return a.dist < b.dist end)
  local moved, skipped = 0, 0
  for i = 1, math.min(#list, CFG.gather.maxEnemies) do
    local e = list[i]
    local p = e.root
    local owned = true
    if isnetworkowner then owned = isnetworkowner(p) end
    if p.Anchored or not owned then
      skipped += 1
    elseif flat(p.Position, c) > CFG.gather.radius then
      local off = Gather.offs[e.model]
      if not off then
        local a, rr = math.random() * math.pi * 2, math.sqrt(math.random()) * CFG.gather.radius * 0.8
        off = Vector3.new(math.cos(a) * rr, 0, math.sin(a) * rr)
        Gather.offs[e.model] = off
      end
      local tgt = c + off
      pcall(function()
        p.CFrame = CFrame.new(tgt.X, c.Y, tgt.Z)
        p.AssemblyLinearVelocity = Vector3.zero
      end)
      moved += 1
    end
  end
  Gather.moved, Gather.notOwned = moved, skipped
  Gather.status = ("%d puxados / %d sem ownership"):format(moved, skipped)
end

---------------------------------------------------------------------
-- QUEST  (maquina de estados: Idle > GoNpc > Accept > Hunt > TurnIn > GoNpc...)
---------------------------------------------------------------------
local Quest = { state = "Parado", kills = 0, done = 0, npc = nil, t = 0, huntStart = 0, rewards0 = nil, status = "parado" }

local function leaderstats()
  local out = {}
  local ls = lp:FindFirstChild("leaderstats")
  if ls then
    for _, v in ipairs(ls:GetChildren()) do
      if v:IsA("IntValue") or v:IsA("NumberValue") then out[v.Name] = v.Value end
    end
  end
  return out
end

local function findNpc(token)
  if Quest.npc and Quest.npc.Parent and Quest.npc.Name:lower():find(token:lower(), 1, true) then return Quest.npc end
  for _, d in ipairs(Workspace:GetDescendants()) do
    if d:IsA("Model") and d.Name:lower():find(token:lower(), 1, true) and d:FindFirstChild("HumanoidRootPart") and not Players:GetPlayerFromCharacter(d) then
      Quest.npc = d
      return d
    end
  end
end

-- Interacao generica. FILL: se o jogo usa dialogo com opcoes (aceitar/entregar) ou RemoteEvent proprio,
-- sobrescreva Hooks.AcceptQuest / Hooks.TurnIn (dumpe os remotes com um spy e chame aqui).
local function interact(npc)
  local pp = npc:FindFirstChildWhichIsA("ProximityPrompt", true)
  if pp and fireproximityprompt then fireproximityprompt(pp); return "prompt" end
  local cd = npc:FindFirstChildWhichIsA("ClickDetector", true)
  if cd and fireclickdetector then fireclickdetector(cd); return "clickdetector" end
  tap("E"); return "tecla E"
end
local Hooks = {
  AcceptQuest = function(npc) return interact(npc) end,
  TurnIn      = function(npc) return interact(npc) end,
}

local function applyPreset(name)
  for _, p in ipairs(PRESETS) do
    if p.name == name then
      CFG.quest.preset = name
      if name ~= "Personalizada" then
        CFG.quest.npc, CFG.quest.enemyPattern, CFG.quest.killTarget = p.npc, p.enemy, p.count
      end
      Quest.npc = nil
      return
    end
  end
end

function Quest.Start()
  Quest.kills, Quest.done, Quest.state, Quest.rewards0 = 0, 0, "GoNpc", leaderstats()
  Quest.t = 0
  Log.add("farm de quest iniciado: " .. CFG.quest.preset)
end
function Quest.Stop()
  Quest.state, Combat.forced = "Parado", false
  Move.Release("quest")
  Log.add("farm de quest parado")
end
table.insert(Combat.onKill, function(model)
  if Quest.state == "Hunt" and matchPattern(model.Name) then Quest.kills += 1 end
end)

function Quest.Rewards()
  if not Quest.rewards0 then return "n/d" end
  local now, parts = leaderstats(), {}
  for k, v in pairs(now) do
    local diff = v - (Quest.rewards0[k] or 0)
    if diff ~= 0 then parts[#parts + 1] = ("%s %+d"):format(k, diff) end
  end
  return #parts > 0 and table.concat(parts, ", ") or "n/d (jogo sem leaderstats ou sem mudanca)"
end

function Quest.Step()
  if not CFG.quest.enabled then
    if Quest.state ~= "Parado" then Quest.Stop() end
    Quest.status = "parado"; return
  end
  if Quest.state == "Parado" then Quest.Start() end
  if not alive() or not hrp() then return end
  local now = os.clock()
  local s = Quest.state
  Quest.status = s

  if s == "GoNpc" or s == "TurnInGo" then
    Combat.forced = false
    local npc = findNpc(CFG.quest.npc)
    if not npc then
      if now - Quest.t > 3 then Quest.t = now; Log.add("NPC '" .. CFG.quest.npc .. "' nao encontrado (precisa estar carregado/perto, ou ajuste o nome)") end
      return
    end
    Move.Request("quest", npc.HumanoidRootPart.Position, 5)
    if flat(hrp().Position, npc.HumanoidRootPart.Position) <= 8 then
      Move.Release("quest")
      Quest.state = (s == "GoNpc") and "Accept" or "TurnIn"
    end

  elseif s == "Accept" then
    local how = Hooks.AcceptQuest(Quest.npc)
    Log.add("aceitando quest (" .. tostring(how) .. ")")
    task.wait(CFG.quest.dialogWait)
    Quest.kills, Quest.huntStart, Quest.state = 0, now, "Hunt"

  elseif s == "Hunt" then
    Combat.forced = true
    if CFG.move.leashEnabled and CFG.move.hasAnchor and hrp() and flat(hrp().Position, v3(CFG.move.anchor)) > CFG.move.leashRadius then
      Log.add("longe demais da regiao, voltando")
      Move.Request("leash", v3(CFG.move.anchor), 10)
    elseif Move.owner == "leash" then
      if Move.Arrived() then Move.Release("leash") end
    end
    if Quest.kills >= CFG.quest.killTarget then
      Log.add(("meta atingida: %d/%d"):format(Quest.kills, CFG.quest.killTarget))
      Quest.state = "TurnInGo"
    elseif now - Quest.huntStart > CFG.quest.huntTimeout then
      Log.add("timeout da caca, indo entregar mesmo assim")
      Quest.state = "TurnInGo"
    end

  elseif s == "TurnIn" then
    local how = Hooks.TurnIn(Quest.npc)
    Log.add("entregando quest (" .. tostring(how) .. ")")
    task.wait(CFG.quest.dialogWait)
    Quest.done += 1
    if CFG.quest.repeatQuest then Quest.state = "GoNpc" else CFG.quest.enabled = false end
  end
end

---------------------------------------------------------------------
-- PANIC / GUARDA
---------------------------------------------------------------------
local UI = { refreshers = {} }
function UI.refreshAll() for _, f in ipairs(UI.refreshers) do pcall(f) end end

local function Panic(reason)
  CFG.quest.enabled, CFG.gather.enabled, CFG.combat.enabled = false, false, false
  Combat.forced, Combat.target = false, nil
  Quest.state = "Parado"
  Move.Clear()
  Log.add("PARADO: " .. (reason or "manual"))
  UI.refreshAll()
end

local function Guard()
  local r = hrp()
  if r and r.Position.Y < Workspace.FallenPartsDestroyHeight + 25 then Panic("queda detectada") end
end

---------------------------------------------------------------------
-- PERSISTENCIA
---------------------------------------------------------------------
local function saveCfg()
  if not writefile then Log.add("writefile indisponivel no executor"); return end
  local ok, err = pcall(function() writefile(SAVE_FILE, HttpService:JSONEncode(CFG)) end)
  Log.add(ok and "configuracoes salvas" or ("erro ao salvar: " .. tostring(err)))
end
local function loadCfg(silent)
  if not (isfile and readfile and isfile(SAVE_FILE)) then if not silent then Log.add("nenhum arquivo salvo") end return end
  local ok, data = pcall(function() return HttpService:JSONDecode(readfile(SAVE_FILE)) end)
  if ok and type(data) == "table" then
    applyTable(CFG, data)
    CFG.quest.enabled, CFG.gather.enabled, CFG.combat.enabled = false, false, false -- nada liga sozinho
    UI.refreshAll(); if not silent then Log.add("configuracoes carregadas") end
  else Log.add("arquivo de config invalido") end
end
local function resetCfg()
  applyTable(CFG, deepcopy(DEFAULT)); UI.refreshAll(); Log.add("valores padrao restaurados")
end

---------------------------------------------------------------------
-- GUI
---------------------------------------------------------------------
local C = {
  bg = Color3.fromRGB(22, 22, 28), panel = Color3.fromRGB(34, 34, 44), tab = Color3.fromRGB(44, 44, 58),
  tabOn = Color3.fromRGB(190, 55, 70), text = Color3.fromRGB(232, 232, 238), dim = Color3.fromRGB(150, 150, 165),
  on = Color3.fromRGB(50, 160, 90), off = Color3.fromRGB(90, 90, 105), stop = Color3.fromRGB(200, 40, 50),
}
local function mk(class, props, parent)
  local i = Instance.new(class)
  for k, v in pairs(props) do i[k] = v end
  i.Parent = parent
  return i
end
local function lbl(parent, text, size, pos, align)
  return mk("TextLabel", { BackgroundTransparency = 1, Text = text, Size = size, Position = pos or UDim2.new(), TextColor3 = C.text,
    Font = Enum.Font.Gotham, TextSize = 13, TextXAlignment = align or Enum.TextXAlignment.Left, TextTruncate = Enum.TextTruncate.AtEnd }, parent)
end

local okGp, guiParent = pcall(function() return (gethui and gethui()) or game:GetService("CoreGui") end)
if not okGp then guiParent = lp:WaitForChild("PlayerGui") end
local gui = mk("ScreenGui", { Name = "S2F_" .. HttpService:GenerateGUID(false):sub(1, 6), ResetOnSpawn = false, ZIndexBehavior = Enum.ZIndexBehavior.Sibling }, nil)
if not pcall(function() gui.Parent = guiParent end) then gui.Parent = lp:WaitForChild("PlayerGui") end

local main = mk("Frame", { AnchorPoint = Vector2.new(0.5, 0.5), Position = UDim2.fromScale(0.5, 0.5), Size = UDim2.fromScale(0.36, 0.7),
  BackgroundColor3 = C.bg, BorderSizePixel = 0, Active = true }, gui)
mk("UISizeConstraint", { MinSize = Vector2.new(340, 380), MaxSize = Vector2.new(560, 620) }, main)
mk("UICorner", { CornerRadius = UDim.new(0, 8) }, main)
local uiScale = mk("UIScale", { Scale = CFG.ui.scale }, main)

-- barra de titulo + arrastar
local title = mk("Frame", { Size = UDim2.new(1, 0, 0, 28), BackgroundColor3 = C.panel, BorderSizePixel = 0 }, main)
mk("UICorner", { CornerRadius = UDim.new(0, 8) }, title)
lbl(title, "Slayers 2 - Farm", UDim2.new(0.4, 0, 1, 0), UDim2.fromOffset(10, 0)).Font = Enum.Font.GothamBold
local ind = lbl(title, "", UDim2.new(0.6, -10, 1, 0), UDim2.new(0.4, 0, 0, 0), Enum.TextXAlignment.Right)
ind.RichText = true
do
  local drag, start, startPos
  title.InputBegan:Connect(function(i)
    if i.UserInputType == Enum.UserInputType.MouseButton1 or i.UserInputType == Enum.UserInputType.Touch then
      drag, start, startPos = true, i.Position, main.Position
    end
  end)
  UIS.InputChanged:Connect(function(i)
    if drag and (i.UserInputType == Enum.UserInputType.MouseMovement or i.UserInputType == Enum.UserInputType.Touch) then
      local d = i.Position - start
      main.Position = UDim2.new(startPos.X.Scale, startPos.X.Offset + d.X, startPos.Y.Scale, startPos.Y.Offset + d.Y)
    end
  end)
  UIS.InputEnded:Connect(function(i)
    if i.UserInputType == Enum.UserInputType.MouseButton1 or i.UserInputType == Enum.UserInputType.Touch then drag = false end
  end)
end

local tabBar = mk("Frame", { Position = UDim2.fromOffset(6, 32), Size = UDim2.new(1, -12, 0, 26), BackgroundTransparency = 1 }, main)
mk("UIListLayout", { FillDirection = Enum.FillDirection.Horizontal, Padding = UDim.new(0, 3), SortOrder = Enum.SortOrder.LayoutOrder }, tabBar)
local pageHost = mk("Frame", { Position = UDim2.fromOffset(6, 62), Size = UDim2.new(1, -12, 1, -62 - 96 - 36), BackgroundTransparency = 1, ClipsDescendants = true }, main)

-- log
local logBox = mk("ScrollingFrame", { AnchorPoint = Vector2.new(0, 1), Position = UDim2.new(0, 6, 1, -38), Size = UDim2.new(1, -12, 0, 90),
  BackgroundColor3 = C.panel, BorderSizePixel = 0, ScrollBarThickness = 4, AutomaticCanvasSize = Enum.AutomaticSize.Y, CanvasSize = UDim2.new() }, main)
local logLbl = mk("TextLabel", { BackgroundTransparency = 1, Size = UDim2.new(1, -8, 0, 0), AutomaticSize = Enum.AutomaticSize.Y, Position = UDim2.fromOffset(4, 2),
  Text = "", TextColor3 = C.dim, Font = Enum.Font.Code, TextSize = 11, TextWrapped = true, TextXAlignment = Enum.TextXAlignment.Left, TextYAlignment = Enum.TextYAlignment.Top }, logBox)

-- parar tudo
local stopBtn = mk("TextButton", { AnchorPoint = Vector2.new(0, 1), Position = UDim2.new(0, 6, 1, -6), Size = UDim2.new(1, -12, 0, 26), BackgroundColor3 = C.stop,
  Text = "PARAR TUDO", TextColor3 = Color3.new(1, 1, 1), Font = Enum.Font.GothamBold, TextSize = 14, BorderSizePixel = 0 }, main)
mk("UICorner", { CornerRadius = UDim.new(0, 6) }, stopBtn)
stopBtn.MouseButton1Click:Connect(function() Panic("botao parar tudo") end)

-- paginas
local pages, tabBtns = {}, {}
local function newPage(name)
  local p = mk("ScrollingFrame", { Size = UDim2.fromScale(1, 1), BackgroundTransparency = 1, BorderSizePixel = 0, ScrollBarThickness = 4,
    AutomaticCanvasSize = Enum.AutomaticSize.Y, CanvasSize = UDim2.new(), Visible = false }, pageHost)
  mk("UIListLayout", { Padding = UDim.new(0, 4), SortOrder = Enum.SortOrder.LayoutOrder }, p)
  pages[name] = p
  local b = mk("TextButton", { Size = UDim2.new(0.2, -3, 1, 0), BackgroundColor3 = C.tab, Text = name, TextColor3 = C.text, Font = Enum.Font.GothamMedium,
    TextSize = 11, BorderSizePixel = 0, TextScaled = false }, tabBar)
  mk("UICorner", { CornerRadius = UDim.new(0, 5) }, b)
  tabBtns[name] = b
  b.MouseButton1Click:Connect(function()
    for n, pg in pairs(pages) do pg.Visible = (n == name); tabBtns[n].BackgroundColor3 = (n == name) and C.tabOn or C.tab end
  end)
  return p
end

-- widgets
local function row(page, h)
  local r = mk("Frame", { Size = UDim2.new(1, -6, 0, h), BackgroundColor3 = C.panel, BorderSizePixel = 0 }, page)
  mk("UICorner", { CornerRadius = UDim.new(0, 5) }, r)
  return r
end
local function Info(page, getText)
  local r = row(page, 22)
  local l = lbl(r, "", UDim2.new(1, -12, 1, 0), UDim2.fromOffset(8, 0)); l.TextColor3 = C.dim
  UI.refreshers[#UI.refreshers + 1] = function() l.Text = getText() end
  UI.info = UI.info or {}; table.insert(UI.info, function() l.Text = getText() end)
end
local function Toggle(page, label, get, set)
  local r = row(page, 30)
  lbl(r, label, UDim2.new(1, -84, 1, 0), UDim2.fromOffset(8, 0))
  local b = mk("TextButton", { Size = UDim2.fromOffset(64, 22), Position = UDim2.new(1, -72, 0.5, -11), Font = Enum.Font.GothamBold, TextSize = 12,
    BorderSizePixel = 0, TextColor3 = C.text }, r)
  mk("UICorner", { CornerRadius = UDim.new(0, 5) }, b)
  local function rf() local v = get(); b.Text = v and "ON" or "OFF"; b.BackgroundColor3 = v and C.on or C.off end
  b.MouseButton1Click:Connect(function() set(not get()); UI.refreshAll() end)
  UI.refreshers[#UI.refreshers + 1] = rf; rf()
end
local function Button(page, text, cb)
  local b = mk("TextButton", { Size = UDim2.new(1, -6, 0, 28), BackgroundColor3 = C.tab, Text = text, TextColor3 = C.text, Font = Enum.Font.GothamMedium,
    TextSize = 13, BorderSizePixel = 0 }, page)
  mk("UICorner", { CornerRadius = UDim.new(0, 5) }, b)
  b.MouseButton1Click:Connect(function() cb(); UI.refreshAll() end)
end
local function TextBox(page, label, get, set)
  local r = row(page, 30)
  lbl(r, label, UDim2.new(0.5, -8, 1, 0), UDim2.fromOffset(8, 0))
  local t = mk("TextBox", { Size = UDim2.new(0.5, -12, 0, 22), Position = UDim2.new(0.5, 4, 0.5, -11), BackgroundColor3 = C.tab, TextColor3 = C.text,
    Font = Enum.Font.Gotham, TextSize = 12, ClearTextOnFocus = false, BorderSizePixel = 0, Text = "" }, r)
  mk("UICorner", { CornerRadius = UDim.new(0, 5) }, t)
  t.FocusLost:Connect(function() set(t.Text); UI.refreshAll() end)
  UI.refreshers[#UI.refreshers + 1] = function() t.Text = tostring(get()) end
  t.Text = tostring(get())
end
local function Slider(page, label, min, max, step, get, set, fmt)
  local r = row(page, 42)
  local l = lbl(r, "", UDim2.new(1, -12, 0, 18), UDim2.fromOffset(8, 2))
  local bar = mk("Frame", { Position = UDim2.new(0, 8, 0, 26), Size = UDim2.new(1, -16, 0, 8), BackgroundColor3 = C.tab, BorderSizePixel = 0 }, r)
  mk("UICorner", { CornerRadius = UDim.new(0, 4) }, bar)
  local fill = mk("Frame", { Size = UDim2.new(0, 0, 1, 0), BackgroundColor3 = C.tabOn, BorderSizePixel = 0 }, bar)
  mk("UICorner", { CornerRadius = UDim.new(0, 4) }, fill)
  local function rf()
    local v = get()
    l.Text = ("%s: %s"):format(label, fmt and fmt(v) or tostring(v))
    fill.Size = UDim2.new(math.clamp((v - min) / (max - min), 0, 1), 0, 1, 0)
  end
  local dragging = false
  local function fromX(x)
    local rel = math.clamp((x - bar.AbsolutePosition.X) / math.max(bar.AbsoluteSize.X, 1), 0, 1)
    set(math.floor((min + (max - min) * rel) / step + 0.5) * step); rf()
  end
  bar.InputBegan:Connect(function(i)
    if i.UserInputType == Enum.UserInputType.MouseButton1 or i.UserInputType == Enum.UserInputType.Touch then dragging = true; fromX(i.Position.X) end
  end)
  UIS.InputChanged:Connect(function(i)
    if dragging and (i.UserInputType == Enum.UserInputType.MouseMovement or i.UserInputType == Enum.UserInputType.Touch) then fromX(i.Position.X) end
  end)
  UIS.InputEnded:Connect(function(i)
    if i.UserInputType == Enum.UserInputType.MouseButton1 or i.UserInputType == Enum.UserInputType.Touch then dragging = false end
  end)
  UI.refreshers[#UI.refreshers + 1] = rf; rf()
end
local function Dropdown(page, label, options, get, set)
  local r = mk("Frame", { Size = UDim2.new(1, -6, 0, 0), AutomaticSize = Enum.AutomaticSize.Y, BackgroundColor3 = C.panel, BorderSizePixel = 0 }, page)
  mk("UICorner", { CornerRadius = UDim.new(0, 5) }, r)
  mk("UIListLayout", { SortOrder = Enum.SortOrder.LayoutOrder, Padding = UDim.new(0, 2) }, r)
  local head = mk("TextButton", { LayoutOrder = 1, Size = UDim2.new(1, 0, 0, 30), BackgroundTransparency = 1, Font = Enum.Font.Gotham, TextSize = 13,
    TextColor3 = C.text, TextXAlignment = Enum.TextXAlignment.Left, Text = "" }, r)
  mk("UIPadding", { PaddingLeft = UDim.new(0, 8) }, head)
  local box = mk("Frame", { LayoutOrder = 2, Size = UDim2.new(1, 0, 0, 0), AutomaticSize = Enum.AutomaticSize.Y, BackgroundTransparency = 1, Visible = false }, r)
  mk("UIListLayout", { Padding = UDim.new(0, 2) }, box)
  head.MouseButton1Click:Connect(function()
    box.Visible = not box.Visible
    if box.Visible then
      for _, c in ipairs(box:GetChildren()) do if c:IsA("TextButton") then c:Destroy() end end
      for _, o in ipairs(options) do
        local ob = mk("TextButton", { Size = UDim2.new(1, -12, 0, 24), BackgroundColor3 = C.tab, Text = o, TextColor3 = C.text, Font = Enum.Font.Gotham,
          TextSize = 12, BorderSizePixel = 0 }, box)
        ob.MouseButton1Click:Connect(function() set(o); box.Visible = false; UI.refreshAll() end)
      end
    end
  end)
  local function rf() head.Text = ("%s: %s  v"):format(label, tostring(get())) end
  UI.refreshers[#UI.refreshers + 1] = rf; rf()
end

local sec = function(v) return ("%.2fs"):format(v) end
local studs = function(v) return ("%d studs"):format(v) end
local presetNames = {}
for _, p in ipairs(PRESETS) do presetNames[#presetNames + 1] = p.name end

-- aba FARM
do
  local p = newPage("Farm")
  Toggle(p, "Farm de quests", function() return CFG.quest.enabled end, function(v) CFG.quest.enabled = v end)
  Dropdown(p, "Quest", presetNames, function() return CFG.quest.preset end, applyPreset)
  TextBox(p, "NPC (nome)", function() return CFG.quest.npc end, function(v) CFG.quest.npc = v; Quest.npc = nil end)
  TextBox(p, "Mob (filtro nome)", function() return CFG.quest.enemyPattern end, function(v) CFG.quest.enemyPattern = v end)
  Slider(p, "Meta de kills", 1, 30, 1, function() return CFG.quest.killTarget end, function(v) CFG.quest.killTarget = v end)
  Slider(p, "Timeout da caca", 30, 300, 10, function() return CFG.quest.huntTimeout end, function(v) CFG.quest.huntTimeout = v end, function(v) return v .. "s" end)
  Toggle(p, "Repetir quest ao concluir", function() return CFG.quest.repeatQuest end, function(v) CFG.quest.repeatQuest = v end)
  Info(p, function() return ("Estado: %s | kills %d/%d"):format(Quest.state, Quest.kills, CFG.quest.killTarget) end)
  Info(p, function() return ("Quests concluidas: %d | Total kills: %d"):format(Quest.done, Combat.kills) end)
  Info(p, function() return "Recompensas: " .. Quest.Rewards() end)
end
-- aba AGRUPAMENTO
do
  local p = newPage("Agrup.")
  Toggle(p, "Agrupar inimigos", function() return CFG.gather.enabled end, function(v) CFG.gather.enabled = v end)
  Dropdown(p, "Centro", { "Frente do jogador", "Ponto fixo" }, function() return CFG.gather.centerMode end, function(v) CFG.gather.centerMode = v end)
  Button(p, "Definir ponto fixo = minha posicao", function()
    local r = hrp(); if r then CFG.gather.fixed = { r.Position.X, r.Position.Y, r.Position.Z }; CFG.gather.hasFixed = true; Log.add("ponto de agrupamento definido") end
  end)
  Slider(p, "Raio de agrupamento", 3, 30, 1, function() return CFG.gather.radius end, function(v) CFG.gather.radius = v end, studs)
  Slider(p, "Distancia jogador-grupo", 3, 30, 1, function() return CFG.gather.distance end, function(v) CFG.gather.distance = v end, studs)
  Slider(p, "Max. inimigos", 1, 25, 1, function() return CFG.gather.maxEnemies end, function(v) CFG.gather.maxEnemies = v end)
  Slider(p, "Intervalo", 0.1, 1, 0.05, function() return CFG.gather.interval end, function(v) CFG.gather.interval = v end, sec)
  Slider(p, "Alcance do scan", 30, 300, 10, function() return CFG.scan.range end, function(v) CFG.scan.range = v end, studs)
  TextBox(p, "Pasta dos mobs", function() return CFG.scan.root end, function(v) CFG.scan.root = (v ~= "" and v or "Workspace") end)
  Info(p, function() return "Agrupamento: " .. Gather.status end)
end
-- aba COMBATE
do
  local p = newPage("Combate")
  Toggle(p, "Combate automatico", function() return CFG.combat.enabled end, function(v) CFG.combat.enabled = v end)
  -- FILL: lista real de armas/estilos que voce tem; so informativo, o script usa o que estiver equipado.
  Dropdown(p, "Alvo", { "Mais proximo", "Mais distante", "Da quest atual" }, function() return CFG.combat.targetMode end, function(v) CFG.combat.targetMode = v end)
  Dropdown(p, "Modo", { "Individual", "Priorizar grupos" }, function() return CFG.combat.mode end, function(v) CFG.combat.mode = v end)
  Slider(p, "Distancia de combate", 2, 25, 1, function() return CFG.combat.distance end, function(v) CFG.combat.distance = v end, studs)
  Slider(p, "Alcance do ataque (arma/skill)", 3, 40, 1, function() return CFG.combat.attackRange end, function(v) CFG.combat.attackRange = v end, studs)
  Slider(p, "Intervalo entre acoes", 0.1, 2, 0.05, function() return CFG.combat.interval end, function(v) CFG.combat.interval = v end, sec)
  Slider(p, "Timeout por alvo", 4, 30, 1, function() return CFG.combat.targetTimeout end, function(v) CFG.combat.targetTimeout = v end, function(v) return v .. "s" end)
  Toggle(p, "Ataque basico (clique)", function() return CFG.combat.useM1 end, function(v) CFG.combat.useM1 = v end)
  for i, s in ipairs(CFG.combat.skills) do
    Toggle(p, "Skill " .. i, function() return s.enabled end, function(v) s.enabled = v end)
    TextBox(p, "  tecla", function() return s.key end, function(v) s.key = v:upper() end)
    Slider(p, "  recarga", 0.5, 60, 0.5, function() return s.cd end, function(v) s.cd = v end, function(v) return v .. "s" end)
  end
  Info(p, function() return "Combate: " .. Combat.status end)
end
-- aba MOVIMENTACAO
do
  local p = newPage("Mov.")
  Dropdown(p, "Modo", { "Automatica", "Manual" }, function() return CFG.move.mode end, function(v) CFG.move.mode = v; Move.Clear() end)
  Toggle(p, "Voltar a regiao se afastar", function() return CFG.move.leashEnabled end, function(v) CFG.move.leashEnabled = v end)
  Slider(p, "Raio maximo da regiao", 30, 400, 10, function() return CFG.move.leashRadius end, function(v) CFG.move.leashRadius = v end, studs)
  Button(p, "Definir regiao da quest = minha posicao", function()
    local r = hrp(); if r then CFG.move.anchor = { r.Position.X, r.Position.Y, r.Position.Z }; CFG.move.hasAnchor = true; Log.add("regiao definida") end
  end)
  Info(p, function() return ("Movimento: dono=%s | destino=%s"):format(Move.owner or "-", Move.goal and "sim" or "nao") end)
end
-- aba CONFIGURACOES
do
  local p = newPage("Config.")
  Button(p, "Salvar configuracoes", saveCfg)
  Button(p, "Carregar configuracoes", function() loadCfg(false) end)
  Button(p, "Restaurar padrao", resetCfg)
  TextBox(p, "Tecla mostrar/ocultar", function() return CFG.ui.toggleKey end, function(v) CFG.ui.toggleKey = v end)
  Slider(p, "Escala da interface", 0.7, 1.4, 0.05, function() return CFG.ui.scale end, function(v) CFG.ui.scale = v; uiScale.Scale = v end)
  Slider(p, "Tick do loop", 0.05, 0.5, 0.05, function() return CFG.core.tick end, function(v) CFG.core.tick = v end, sec)
  Button(p, "Fechar e descarregar script", function() if getgenv then getgenv().S2F_Cleanup() end end)
end

pages["Farm"].Visible = true
tabBtns["Farm"].BackgroundColor3 = C.tabOn

local keyConn = UIS.InputBegan:Connect(function(i, gp)
  if not gp and i.KeyCode.Name == CFG.ui.toggleKey then main.Visible = not main.Visible end
end)

---------------------------------------------------------------------
-- CORE LOOP (um unico loop; modulos expoem Step)
---------------------------------------------------------------------
local running, errs = true, 0

task.spawn(function()
  while running do
    local ok, err = pcall(function()
      Quest.Step(); Gather.Step(); Combat.Step(); Move.Step(); Guard()
    end)
    if ok then errs = 0 else
      errs += 1; Log.add("erro: " .. tostring(err))
      if errs >= 5 then Panic("5 erros seguidos"); errs = 0 end
    end
    task.wait(CFG.core.tick)
  end
end)

-- UI refresh a 2 Hz (log + indicadores), separado do loop principal
task.spawn(function()
  local function dot(on) return on and '<font color="rgb(80,220,120)">●</font>' or '<font color="rgb(120,120,130)">●</font>' end
  while running do
    ind.Text = ("%s Quest  %s Agrup  %s Combate  %s Mov"):format(dot(CFG.quest.enabled), dot(CFG.gather.enabled), dot(Combat.active()), dot(Move.goal ~= nil))
    if UI.info then for _, f in ipairs(UI.info) do pcall(f) end end
    if Log.dirty then
      Log.dirty = false
      logLbl.Text = table.concat(Log.lines, "\n")
      logBox.CanvasPosition = Vector2.new(0, 1e6)
    end
    task.wait(0.5)
  end
end)

local function cleanup()
  running = false
  Panic("descarregado")
  keyConn:Disconnect()
  gui:Destroy()
end
if getgenv then getgenv().S2F_Cleanup = cleanup end

loadCfg(true)
Log.add("pronto. nada liga sozinho. Mobs: confira o nome real no Explorer e ajuste o filtro.")
