-- Voidwatch bot adapter, MIT licence. The Voidwatch module copies it into the bot's config folder when the player
-- turns it on; the bot loads every .lua file there. It hands the bot's state to the module every 10 s, and it changes
-- the bot only through the commands below. It works with the stock cavebot, vBot and presets built on them: each value
-- is read only where its function exists, and a missing one stays out of the status.
local VERSION = '3'

local config = (function()
  local ok, name = pcall(function() return modules.game_bot.contentsPanel.config:getCurrentOption().text end)
  return ok and name or nil
end)()

local function fn(t, k) return type(t) == 'table' and type(t[k]) == 'function' and t[k] or nil end

-- the cavebot and targetbot keep the loaded profile in the same place in every stock config
local function selected(kind)
  local c = type(storage) == 'table' and type(storage._configs) == 'table' and storage._configs[kind]
  return type(c) == 'table' and c.selected or nil
end

local routeList = { at = nil, names = nil }
local function routes()
  if not config then return nil end
  if routeList.at and now - routeList.at < 60000 then return routeList.names end
  local names = {}
  local ok, files = pcall(g_resources.listDirectoryFiles, '/bot/' .. config .. '/cavebot_configs')
  for _, f in ipairs(ok and type(files) == 'table' and files or {}) do
    local n = tostring(f):match('^(.+)%.cfg$')
    if n then names[#names + 1] = n end
  end
  table.sort(names)
  routeList.at, routeList.names = now, names
  return names
end

-- vBot remembers the last label; the stock cavebot only has its waypoint list, so the label above the current row
local function label()
  local last = fn(CaveBot, 'lastReachedLabel')
  if last then
    local v = last()
    if v and v ~= '' then return v end
  end
  local list = type(CaveBot) == 'table' and CaveBot.actionList
  local cur = list and list:getFocusedChild()
  if not cur then return nil end
  for i = list:getChildIndex(cur), 1, -1 do
    local row = list:getChildByIndex(i)
    if row and row.action == 'label' then return row.value end
  end
  return nil
end

local function itemName(id)
  local ok, name = pcall(function()
    local m = g_things.getThingType(id, ThingCategoryItem):getMarketData()
    return m and m.name ~= '' and m.name or nil
  end)
  return ok and name or ('item ' .. id)
end

-- vBot's supply list: the bot buys up to max, so max is what it keeps in stock
local function supplies()
  local data = type(Supplies) == 'table' and fn(Supplies, 'getItemsData')
  if not data then return nil end
  local rows = {}
  for id, v in pairs(data()) do
    local n = tonumber(id)
    if n and #rows < 30 then
      rows[#rows + 1] = { name = itemName(n), have = player:getItemsCount(n) or 0, want = tonumber(v.max) or 0 }
    end
  end
  table.sort(rows, function(a, b) return a.name < b.name end)
  return rows
end

local function botProfile()
  if type(vBot) ~= 'table' then return nil end
  local ok, n = pcall(g_settings.getNumber, 'profile')
  return ok and type(n) == 'number' and n >= 1 and n <= 20 and n or nil
end

local function onOff(t)
  local isOn = fn(t, 'isOn')
  if isOn then return isOn() and true or false end
  return nil
end

-- where the character is in its route, from the label of each route part: the player names the labels, and each
-- role takes a comma list of names (Clients → Module on the website)
local ROLES = { 'refill', 'hunt', 'check', 'leave' }
local LEG = { refill = 'town', hunt = 'hunting', check = 'at_check', leave = 'leaving' }
local PARKED_SQM = 8

local function xyz(value)
  local x, y, z = tostring(value):match('^%s*(%d+)%s*,%s*(%d+)%s*,%s*(%d+)')
  return tonumber(x), tonumber(y), tonumber(z)
end

local function roleNames()
  local vw = modules.voidwatch and modules.voidwatch.Voidwatch
  local given = vw and vw.labelRoles and vw.labelRoles() or {}
  local out = {}
  for _, role in ipairs(ROLES) do
    out[role] = {}
    for name in tostring(type(given[role]) == 'string' and given[role] ~= '' and given[role] or role):gmatch('[^,]+') do
      out[role][name:match('^%s*(.-)%s*$'):lower()] = true
    end
  end
  return out
end

local spot = { at = -1 }
local function whereInRoute()
  if spot.at == now then return spot end
  spot = { at = now }
  local list = type(CaveBot) == 'table' and CaveBot.actionList
  if not list then return spot end
  local names, marks, children = roleNames(), {}, list:getChildren()
  for index, child in ipairs(children) do
    if child.action == 'label' then
      local v = tostring(child.value):lower()
      for role, set in pairs(names) do
        if set[v] and not marks[role] then marks[role] = index end
      end
    end
  end
  local missing = {}
  for _, role in ipairs(ROLES) do
    if not marks[role] then missing[#missing + 1] = role end
  end
  spot.missing = #missing > 0 and missing or nil
  if spot.missing then spot.phase = 'unknown'; return spot end
  if onOff(CaveBot) == false then
    local p = g_game.getLocalPlayer()
    local pos = p and p:getPosition()
    local okPz, pz = pcall(function() return p:hasState(PlayerStates.Pz) end)
    local near = false
    for i = marks.refill + 1, #children do
      if children[i].action == 'goto' then
        local x, y, z = xyz(children[i].value)
        near = pos and x and pos.z == z and math.max(math.abs(pos.x - x), math.abs(pos.y - y)) <= PARKED_SQM or false
        break
      end
    end
    spot.phase = (near or (okPz and pz)) and 'parked' or 'stopped'
    return spot
  end
  local cur = list:getFocusedChild()
  local at = cur and list:getChildIndex(cur)
  if not at then spot.phase = 'unknown'; return spot end
  local leg, legAt, last, lastAt = nil, 0, nil, 0
  for role, index in pairs(marks) do
    if index <= at and index > legAt then leg, legAt = role, index end
    if index > lastAt then last, lastAt = role, index end
  end
  spot.phase = LEG[leg or last]
  return spot
end

local function switch(t, name, on)
  if type(on) ~= 'boolean' then return false, 'on must be true or false' end
  local set = fn(t, on and 'setOn' or 'setOff')
  if not set then return false, name .. ' is not loaded' end
  set()
  return true, name .. (on and ' on' or ' off')
end

local function nearestGoto(list, me)
  local best, bestDist, bestIndex
  for index, child in ipairs(list:getChildren()) do
    if child.action == 'goto' then
      local x, y, z = tostring(child.value):match('^%s*(%d+)%s*,%s*(%d+)%s*,%s*(%d+)')
      x, y, z = tonumber(x), tonumber(y), tonumber(z)
      if z == me.z then
        local d = math.max(math.abs(x - me.x), math.abs(y - me.y))
        if not bestDist or d < bestDist then best, bestDist, bestIndex = child, d, index end
      end
    end
  end
  return best, bestDist, bestIndex
end

local function resetHere()
  local list = type(CaveBot) == 'table' and CaveBot.actionList
  if not list then return false, 'the cavebot is not loaded' end
  local best, dist, index = nearestGoto(list, g_game.getLocalPlayer():getPosition())
  if not best then return false, 'no waypoint on this floor' end
  list:focusChild(best)
  return true, ('waypoint %d, %d sqm away'):format(index, dist)
end

local adapter = {
  id = 'bot', version = VERSION,
  actions = {
    toggle_cavebot = function(args) return switch(CaveBot, 'cavebot', args.on) end,
    toggle_targetbot = function(args) return switch(TargetBot, 'targeting', args.on) end,
    reset_here = resetHere,
  },
  fields = {
    botConfig = function() return config end,
    routeOn = function() return onOff(CaveBot) end,
    route = function() local get = fn(CaveBot, 'getCurrentProfile'); return (get and get()) or selected('cavebot_configs') end,
    routes = routes,
    label = label,
    phase = function() return whereInRoute().phase end,
    labelsMissing = function() return whereInRoute().missing end,
    targetOn = function() return onOff(TargetBot) end,
    targetProfile = function() local get = fn(TargetBot, 'getCurrentProfile'); return (get and get()) or selected('targetbot_configs') end,
    botProfile = botProfile,
    supplies = supplies,
  },
}

local function attach()
  local vw = modules.voidwatch and modules.voidwatch.Voidwatch
  if vw and vw.attachBot then pcall(vw.attachBot, adapter) end
end
attach()
macro(10000, attach)
