-- Voidwatch bot adapter, MIT licence. The Voidwatch module copies it into the bot's config folder when the player
-- turns it on; the bot loads every .lua file there. It hands the bot's state to the module every 10 s, and it changes
-- the bot only through the commands below. It works with the stock cavebot, vBot and presets built on them: each value
-- is read only where its function exists, and a missing one stays out of the status.
local VERSION = '5'

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
local ROLES = { 'hunt', 'refill', 'city', 'resp' }
local LEG = { hunt = 'hunting', refill = 'to_city', city = 'in_city', resp = 'to_resp' }
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
  local names, marks, roleAt, children = roleNames(), {}, {}, list:getChildren()
  for index, child in ipairs(children) do
    if child.action == 'label' then
      local v = tostring(child.value):lower()
      for _, role in ipairs(ROLES) do
        if names[role][v] then
          roleAt[index] = roleAt[index] or role
          marks[role] = marks[role] or index
        end
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
    for i = marks.city + 1, #children do
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
  for step = 0, #children - 1 do
    local role = roleAt[(at - 1 - step) % #children + 1]
    if role then spot.phase = LEG[role]; return spot end
  end
  return spot
end

local function currentRoute()
  local get = fn(CaveBot, 'getCurrentProfile')
  return (get and get()) or selected('cavebot_configs')
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

-- plans: a command that acts when the bot reaches a label of its route. The hooks wrap the bot's own label and goto
-- steps and its gotoLabel, so a plan never edits the route; without a running plan they only pass the step on. The
-- module keeps the plan on disk, so a bot reload does not lose it.
local PLAN_KEEP_S = 120
local plan, planLoaded = nil, false
local onLabel, onGoto

local function vw() return modules.voidwatch and modules.voidwatch.Voidwatch end

local function savePlan()
  local m = vw()
  if m and m.savePlan then pcall(m.savePlan, plan) end
end

local function waitMin()
  local m = vw()
  local ok, n = pcall(function() return m.planWait() end)
  return ok and tonumber(n) or 20
end

local function roleOf(value, names)
  local v = tostring(value):lower()
  for _, role in ipairs(ROLES) do
    if names[role][v] then return role end
  end
end

local function firstLabel(role)
  local names = roleNames()
  for _, child in ipairs(CaveBot.actionList:getChildren()) do
    if child.action == 'label' and roleOf(child.value, names) == role then return child end
  end
end

local function jump(role)
  local row = firstLabel(role)
  if not row then return false end
  CaveBot.actionList:focusChild(row)
  if type(vBot) == 'table' then vBot.lastLabel = row.value end
  return true
end

local function setStep(step, message)
  plan.step, plan.message, plan.deadline = step, message, os.time() + waitMin() * 60
  savePlan()
  return true, message
end

local function finish(state, message)
  plan.state, plan.step, plan.message, plan.ended, plan.deadline = state, nil, message, os.time(), nil
  savePlan()
  return true, message
end

local function hook(name, after)
  local a = type(CaveBot) == 'table' and type(CaveBot.Actions) == 'table' and CaveBot.Actions[name]
  if type(a) ~= 'table' or type(a.callback) ~= 'function' then return false end
  if not a.voidwatch then
    local original = a.callback
    a.callback = function(value, ...)
      local list = CaveBot.actionList
      local row = list and list:getFocusedChild()
      local at = row and list:getChildIndex(row)
      local result = original(value, ...)
      if result == true and plan and plan.state == 'running' then pcall(after, value, at) end
      return result
    end
    a.voidwatch = true
  end
  return true
end

-- a jump with gotolabel or a supply check skips the label step itself, so the jump is a hook too
local function hookJump()
  local go = fn(CaveBot, 'gotoLabel')
  if not go then return false end
  if CaveBot.voidwatchJump ~= go then
    local wrapped = function(label, ...)
      local result = go(label, ...)
      if result and plan and plan.state == 'running' then pcall(onLabel, label) end
      return result
    end
    CaveBot.gotoLabel, CaveBot.voidwatchJump = wrapped, wrapped
  end
  return true
end

local function hooked()
  local a, b, c = hook('label', onLabel), hook('goto', onGoto), hookJump()
  return a and b and c
end

local function routeFile(name) return '/bot/' .. tostring(config) .. '/cavebot_configs/' .. name .. '.cfg' end

local function routeHasCity(name)
  local ok, src = pcall(g_resources.readFileContents, routeFile(name))
  if not ok or type(src) ~= 'string' then return false end
  local names = roleNames().city
  for line in src:gmatch('[^\r\n]+') do
    local v = line:match('^label:(.+)$')
    if v and names[v:match('^%s*(.-)%s*$'):lower()] then return true end
  end
  return false
end

local function stopAfter(row)
  local list = CaveBot.actionList
  local children = list:getChildren()
  for i = (list:getChildIndex(row) or #children) + 1, #children do
    if children[i].action == 'goto' then
      plan.stopAt = i
      return setStep('depot', 'walking into the depot')
    end
  end
  return finish('failed', 'no step after the city label')
end

local function loadRoute()
  if not (plan and plan.state == 'running' and plan.step == 'switch') then return end
  if not g_resources.fileExists(routeFile(plan.route)) then return finish('failed', plan.route .. ' is gone') end
  CaveBot.setOff()
  storage._configs.cavebot_configs.selected = plan.route
  CaveBot.setOn()
  plan.routeAt = currentRoute()
  if plan.routeAt ~= plan.route then CaveBot.setOff(); return finish('failed', plan.route .. ' did not load') end
  if not jump('city') then CaveBot.setOff(); return finish('failed', plan.route .. ' has no city label') end
  finish('done', plan.route .. ' runs from city')
end

-- the old route stops before the new one loads, and the new one starts at its own city: no step of the old one runs
local function switchRoute()
  CaveBot.setOff()
  setStep('switch', 'loading ' .. plan.route)
  if type(schedule) == 'function' then schedule(300, loadRoute) else loadRoute() end
end

function onLabel(value, at)
  local role = roleOf(value, roleNames())
  if plan.step == 'hunt' and role == 'refill' then
    if plan.kind == 'refill' then return finish('done', 'on the way to the city') end
    return setStep('city', 'waiting for city')
  elseif plan.step == 'hunt' and role == 'hunt' then
    if not jump('refill') then return finish('failed', 'the route has no refill label') end
    if plan.kind == 'refill' then return finish('done', 'on the way to the city') end
    return setStep('city', 'waiting for city')
  elseif plan.step == 'city' and role == 'city' then
    if plan.kind == 'load_route' then return switchRoute() end
    local list = CaveBot.actionList
    return stopAfter(at and list:getChildByIndex(at) or list:getFocusedChild())
  end
end

function onGoto(_, at)
  if plan.step ~= 'depot' or at ~= plan.stopAt then return end
  CaveBot.setOff()
  finish('done', 'parked in the depot')
end

local function startPlan(kind, args, ctx)
  if not hooked() then return false, 'plans need vBot or the stock cavebot' end
  local where = whereInRoute()
  if where.missing then return false, 'the route misses labels: ' .. table.concat(where.missing, ', ') end
  local phase = where.phase
  local route = type(args) == 'table' and type(args.route) == 'string' and args.route or nil
  if kind == 'load_route' then
    if not route or not g_resources.fileExists(routeFile(route)) then return false, 'no route ' .. tostring(route) end
    if route == currentRoute() then return false, route .. ' is loaded already' end
    if not routeHasCity(route) then return false, route .. ' has no city label' end
  end
  if kind == 'refill' and (phase == 'to_city' or phase == 'in_city') then return true, 'on the way to the city already' end
  if kind == 'go_depot' and phase == 'parked' then return true, 'parked already' end
  if phase == 'stopped' or (kind == 'refill' and phase == 'parked') then return false, 'the cavebot is off' end
  plan = { id = type(ctx) == 'table' and tonumber(ctx.id) or nil, kind = kind, route = route, state = 'running', since = os.time(),
           routeAt = currentRoute() }
  if kind == 'load_route' and (phase == 'parked' or phase == 'in_city') then
    switchRoute()
    return true, 'loading ' .. route
  end
  if kind == 'go_depot' and phase == 'in_city' then
    local row = firstLabel('city')
    CaveBot.actionList:focusChild(row)
    return stopAfter(row)
  end
  if phase == 'to_city' then return setStep('city', 'waiting for city') end
  return setStep('hunt', 'waiting for hunt')
end

local function resume()
  if not hooked() then return false, 'plans need vBot or the stock cavebot' end
  local where = whereInRoute()
  if where.missing then return false, 'the route misses labels: ' .. table.concat(where.missing, ', ') end
  if where.phase ~= 'parked' then return false, onOff(CaveBot) and 'the cavebot runs already' or 'the character is not parked' end
  CaveBot.setOn()
  jump('city')
  return true, 'resumed at city'
end

local function cancelPlan()
  if not (plan and plan.state == 'running') then return false, 'no plan runs' end
  return finish('cancelled', 'cancelled')
end

local function watchPlan()
  if type(CaveBot) == 'table' then hooked() end
  if not planLoaded then
    local m = vw()
    local ok, saved = pcall(function() return m.loadPlan() end)
    if ok and saved ~= false then
      planLoaded, plan = true, type(saved) == 'table' and saved or nil
      if plan and plan.state == 'running' and plan.step == 'switch' then loadRoute() end
    end
  end
  if not plan then return end
  if plan.state ~= 'running' then
    if os.time() - (tonumber(plan.ended) or 0) > PLAN_KEEP_S then plan = nil; savePlan() end
    return
  end
  if plan.step ~= 'switch' and currentRoute() ~= plan.routeAt then return finish('taken_over', 'another route was loaded') end
  if os.time() > (tonumber(plan.deadline) or 0) then return finish('stuck', ('no %s within %d min'):format(tostring(plan.step), waitMin())) end
end

local function planState()
  if not plan then return nil end
  return { id = plan.id, kind = plan.kind, route = plan.route, state = plan.state, step = plan.step, message = plan.message,
           since = plan.since, ['until'] = plan.deadline, ended = plan.ended }
end

local adapter = {
  id = 'bot', version = VERSION,
  actions = {
    toggle_cavebot = function(args) return switch(CaveBot, 'cavebot', args.on) end,
    toggle_targetbot = function(args) return switch(TargetBot, 'targeting', args.on) end,
    reset_here = resetHere,
    refill = function(args, ctx) return startPlan('refill', args, ctx) end,
    go_depot = function(args, ctx) return startPlan('go_depot', args, ctx) end,
    load_route = function(args, ctx) return startPlan('load_route', args, ctx) end,
    resume = resume,
    cancel_plan = cancelPlan,
  },
  fields = {
    botConfig = function() return config end,
    routeOn = function() return onOff(CaveBot) end,
    route = currentRoute,
    routes = routes,
    label = label,
    phase = function() return whereInRoute().phase end,
    labelsMissing = function() return whereInRoute().missing end,
    plan = planState,
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
macro(1000, watchPlan)
macro(10000, attach)
