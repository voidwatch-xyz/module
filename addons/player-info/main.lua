-- Player info, a Voidwatch addon, MIT licence. Other players' names show as "[RP 250] Name". The client never gets a
-- player's vocation, so each player that appears is looked at once; the look reply and chat give vocation and level.
local LOOK_MS = 1000
local FIRST_LOOK_MS = 300
local TTL_S = 300
local KEEP_S = 7 * 24 * 3600
local CACHE_MAX = 2000
local QUEUE_MAX = 20
local SWEEP_MS = 5000
local SAVE_MS = 60000
local MINE_MS = 3000

-- the vocation words of each server; all of them are matched, since no word means two vocations
local SERVERS = {
  default = { EK = { 'knight' }, RP = { 'paladin' }, MS = { 'sorcerer' }, ED = { 'druid' } },
  orion = { EK = { 'gladiator' }, RP = { 'sniper' }, MS = { 'wizard' }, ED = { 'priest' } },
}
local LOOK = '^You see (.-) %(Level (%d+)%)%. %a+ is an? ([%a ]+)%.'
local LOOK_NONE = '^You see (.-) %(Level (%d+)%)%. %a+ has no vocation'
local LOOK_ANY = '^You see (.-) ?[%.%(]'

local cache, world, dirty, savedAt, seq = {}, nil, false, 0, 0
local renamed = {}                                       -- creature id -> { c = creature, real = name }
local queue, queued, looked, lookTimer = {}, {}, {}, nil
local origGetName, hook, button, unknown = nil, nil, nil, {}
local baseS, baseMs = os.time(), g_clock.millis()

local function nowS() return baseS + math.floor((g_clock.millis() - baseMs) / 1000) end

local function on() return not (Addon.setting and Addon.setting('tags') == false) end
local function part(key) return not (Addon.setting and Addon.setting(key) == false) end
local function active() return on() and (part('vocation') or part('level')) end

local function familyOf(word)
  local low = word:lower()
  for _, words in pairs(SERVERS) do
    for tag, list in pairs(words) do
      for _, w in ipairs(list) do
        if low:find(w, 1, true) then return tag end
      end
    end
  end
  if not unknown[low] then
    unknown[low] = true
    Addon.log('unknown vocation: ' .. word)
  end
  return word:sub(1, 2):upper()
end

local function me() return g_game.getLocalPlayer() end

local function otherPlayer(c)
  local ok, yes = pcall(function() return c ~= me() and c:isPlayer() and not c:isLocalPlayer() end)
  return ok and yes
end

local function nameOf(c)
  local r = renamed[c:getId()]
  return r and r.real or c:getName()
end

local function spectators()
  local p, out = me(), {}
  if not p then return out end
  for _, c in ipairs(g_map.getSpectators(p:getPosition(), false) or {}) do
    if otherPlayer(c) then out[#out + 1] = c end
  end
  return out
end

-- the name hook: the client draws the tagged name, and every getName() still answers the real one, so Copy Name, VIP,
-- the battle list and the bot keep working
local function installHook()
  if hook then return end
  origGetName = Creature.getName
  hook = function(self)
    local r = renamed[self:getId()]
    if r then return r.real end
    return origGetName(self)
  end
  Creature.getName = hook
end

-- another script may have wrapped it after us: then ours stays in its chain and only passes through
local function removeHook()
  if not hook then return end
  if Creature.getName == hook then Creature.getName = origGetName end
  hook = nil
end

local function tagOf(name)
  local info = cache[name]
  if not info then return nil end
  local parts = {}
  if part('vocation') then parts[#parts + 1] = info.v or '?' end
  if part('level') then parts[#parts + 1] = tostring(info.l or '?') end
  if #parts == 0 then return nil end
  return '[' .. table.concat(parts, ' ') .. ']'
end

local function restore(id)
  local r = renamed[id]
  if not r then return end
  renamed[id] = nil
  pcall(function() if origGetName and origGetName(r.c) ~= r.real then r.c:setName(r.real) end end)
end

local function restoreAll()
  for id in pairs(renamed) do restore(id) end
end

local function show(c)
  local id, name = c:getId(), nameOf(c)
  local tag = active() and tagOf(name)
  if not tag then return restore(id) end
  installHook()
  local want = tag .. ' ' .. name
  renamed[id] = { c = c, real = name }
  if origGetName(c) ~= want then c:setName(want) end
end

local function showByName(name)
  for _, c in ipairs(spectators()) do
    if nameOf(c) == name then show(c) end
  end
end

local function remember(name, level, voc)
  local old = cache[name]
  seq = seq + 1
  cache[name] = { l = level or (old and old.l), v = voc, t = nowS(), s = seq }
  dirty = true
  local n = 0
  for _ in pairs(cache) do n = n + 1 end
  if n <= CACHE_MAX then return end
  local oldest = {}
  for k, e in pairs(cache) do oldest[#oldest + 1] = { k, e.t or 0, e.s or 0 } end
  table.sort(oldest, function(a, b) return a[2] < b[2] or (a[2] == b[2] and a[3] < b[3]) end)
  for i = 1, n - CACHE_MAX do cache[oldest[i][1]] = nil end
end

local function save()
  if not dirty or not world then return end
  local data = Addon.load()
  data.worlds = type(data.worlds) == 'table' and data.worlds or {}
  data.worlds[world] = cache
  if Addon.save(data) then dirty, savedAt = false, g_clock.millis() end
end

local function load()
  local w = g_game.getWorldName and g_game.getWorldName() or nil
  if not w or w == world then return end
  save()
  world, cache = w, {}
  local data = Addon.load()
  local edge = nowS() - KEEP_S
  for name, e in pairs(type(data.worlds) == 'table' and type(data.worlds[w]) == 'table' and data.worlds[w] or {}) do
    if type(e) == 'table' and tonumber(e.t) and tonumber(e.t) > edge then
      cache[name] = { l = tonumber(e.l), v = type(e.v) == 'string' and e.v or nil, t = tonumber(e.t) }
    end
  end
end

-- the creature is still on this floor, so a look at its square still means that player
local function here(c)
  local ok, yes = pcall(function()
    local p, mine = c:getPosition(), me() and me():getPosition()
    return not c:isRemoved() and p and mine and p.z == mine.z
  end)
  return ok and yes
end

local function lookNext()
  lookTimer = nil
  while #queue > 0 do
    local e = table.remove(queue, 1)
    queued[e.name] = nil
    if here(e.c) then
      looked[e.name] = g_clock.millis()
      g_game.look(e.c)
      break
    end
  end
  if #queue > 0 then lookTimer = Addon.after(LOOK_MS, lookNext) end
end

-- vBot's Check Players writes "\n250RP\nGuild" on the creature after its own look: read that, do not look again
local function fromVbot(c, name)
  local ok, text = pcall(function() return c:getText() end)
  if not ok or type(text) ~= 'string' or text == '' then return false end
  local level, voc = text:match('^\n(%d+)(%u%u)')
  if level and not (cache[name] and cache[name].v == voc and cache[name].l == tonumber(level)) then
    remember(name, tonumber(level), voc)
    show(c)
  end
  return true
end

local function want(c)
  if not active() then return end
  local name = nameOf(c)
  if fromVbot(c, name) then return end
  local info = cache[name]
  if info and nowS() - (info.t or 0) < TTL_S then return end
  if queued[name] or #queue >= QUEUE_MAX then return end
  queued[name] = true
  queue[#queue + 1] = { name = name, c = c }
  if not lookTimer then lookTimer = Addon.after(FIRST_LOOK_MS, lookNext) end
end

local function onAppear(c)
  if not otherPlayer(c) then return end
  show(c)
  want(c)
end

-- our own look replies leave the centre of the screen at once, so a loot line there is not pushed away
local function hideReply(text)
  Addon.after(0, function()
    local ok, label = pcall(function() return rootWidget:recursiveGetChildById('highCenterLabel') end)
    if ok and label and label:isVisible() and label:getText() == text then label:setVisible(false) end
  end)
end

local function onText(mode, text)
  if type(text) ~= 'string' or text:sub(1, 8) ~= 'You see ' or text:find('^You see yourself') then return end
  local name, level, voc = text:match(LOOK)
  if name then
    voc = familyOf(voc)
  else
    name, level = text:match(LOOK_NONE)
    voc = name and 'N' or nil
  end
  name = name or text:match(LOOK_ANY)
  if not name then return end
  local mine = looked[name] and g_clock.millis() - looked[name] < MINE_MS
  looked[name] = nil
  if voc then
    remember(name, tonumber(level), voc)
    showByName(name)
  elseif mine then
    remember(name, nil, nil)
  end
  if mine then hideReply(text) end
end

local function onTalk(name, level)
  if type(name) ~= 'string' or type(level) ~= 'number' or level <= 0 then return end
  local info = cache[name]
  if info and info.l ~= level then
    info.l, info.t, dirty = level, nowS(), true
    showByName(name)
  end
end

local function sweep()
  if not g_game.isOnline() then return end
  load()
  for _, c in ipairs(spectators()) do
    show(c)
    want(c)
  end
  if dirty and g_clock.millis() - savedAt >= SAVE_MS then save() end
end

local function apply()
  if active() then
    sweep()
  else
    restoreAll()
    removeHook()
    queue, queued = {}, {}
  end
  if button then pcall(function() button:setOn(on()) end) end
end

local function toggle()
  local ok = pcall(function() return Voidwatch.setAddonSetting('player-info', 'tags', not on()) end)
  if not ok then apply() end
end

function init()
  Addon.connect(Creature, { onAppear = onAppear })
  Addon.connect(g_game, { onTextMessage = onText, onTalk = onTalk })
  Addon.on('settings', apply)
  Addon.on('login', function() world = nil apply() end)
  Addon.on('logout', function()
    save()
    renamed, queue, queued, looked = {}, {}, {}, {}
  end)
  button = Addon.button('Tags on/off', 'playerinfo', toggle)
  Addon.every(SWEEP_MS, sweep)
  apply()
end

function terminate()
  restoreAll()
  removeHook()
  save()
end
