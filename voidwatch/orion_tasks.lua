-- Orion-OTS tasks adapter. Orion sends its task data as JSON on extended opcode 30: "refreshTrackerKills" and
-- "refreshTracker" while tasks run, "open" (every task, killed -1 when not taken) and "getMonsterInfo" (the
-- rewards per goal) when the tasks window opens, "refreshPoints" for the task points. The adapter wraps the client's
-- packet dispatcher, not the tasks module's own callback, so it cannot clash with a bot that taps that one. It
-- passes every packet on first and only reads.
-- Death redemption is an item of the task shop's "consum" page. The page arrives only when asked for, so the
-- adapter asks: every minute while redemption is off or unknown, every 10 minutes while it is on. The task points
-- come only with a claim or with the tasks window, so the adapter asks once per character, with the "open" request
-- that the window sends. Neither window opens.
local original, wrapper
local owner                                             -- the character the data below belongs to
local catalog, goals, active, fromTracker, known = {}, {}, {}, false, false
local points, week
local dr                                                -- { active = bool, left = buys left this week }
local log, lastError, poll = nil, nil, nil
local ASK_ON_MS, ASK_OFF_MS = 600000, 60000

local function me() return g_game.getCharacterName() end

local function onPacket(buffer)
  local ok, data = pcall(json.decode, buffer)
  if not ok or type(data) ~= 'table' or type(data.data) ~= 'table' then return end
  if owner ~= me() then
    owner, catalog, goals, active, fromTracker, known, points, week, dr = me(), {}, {}, {}, false, false, nil, nil, nil
  end
  local action, list = data.action, data.data
  if action == 'refreshTrackerKills' or action == 'refreshTracker' then
    local now = {}
    for _, e in pairs(list) do
      if type(e) == 'table' and e.name then
        now[tostring(e.name):lower()] = { name = tostring(e.name), have = tonumber(e.currentKills) or 0, want = tonumber(e.required) or 0 }
      end
    end
    active, fromTracker, known = now, true, true
  elseif action == 'open' then
    local now = {}
    for _, e in pairs(list) do
      if type(e) == 'table' and e.name then
        local key = tostring(e.name):lower()
        catalog[key] = { exp = tonumber(e.expReward), want = tonumber(e.required) }
        local killed = tonumber(e.killed)
        if killed and killed >= 0 then now[key] = { name = tostring(e.name), have = killed, want = tonumber(e.required) or 0 } end
      end
    end
    -- the tracker is the live count; the window list only stands in until the first tracker packet
    if not fromTracker then active, known = now, true end
  elseif action == 'getMonsterInfo' then
    for _, e in pairs(list) do
      if type(e) == 'table' and e.name and type(e.goals) == 'table' then
        local g = {}
        for kills, v in pairs(e.goals) do
          if tonumber(kills) and type(v) == 'table' then g[tonumber(kills)] = { exp = tonumber(v.exp), taskPoints = tonumber(v.taskPts) } end
        end
        goals[tostring(e.name):lower()] = g
      end
    end
  elseif action == 'shopCategoryData' and type(list.items) == 'table' then
    for _, it in pairs(list.items) do
      if type(it) == 'table' and it.key == 'redemption' then
        local desc = tostring(it.desc or '')
        -- "2/week left"; some labels come translated, then the weekly cap in the text minus this week's buys
        local left = tonumber(tostring(it.limitLabel or ''):match('(%d+)%s*/%s*week'))
        local cap = tonumber(desc:match('%((%d+)%s*/%s*week%)'))
        if not left and cap and tonumber(it.boughtThisWeek) then left = math.max(0, cap - tonumber(it.boughtThisWeek)) end
        dr = { active = it.owned == true or desc:upper():find('[ACTIVE', 1, true) ~= nil, left = left }
      end
    end
  elseif action == 'refreshPoints' then
    points = tonumber(list.taskPoints)
    local earned, cap = tonumber(list.weeklyEarned), tonumber(list.weeklyCap)
    week = (earned and cap) and { earned = earned, cap = cap } or nil
  end
end

local function send(action, data)
  local proto = g_game.isOnline() and g_game.getProtocolGame()
  if proto then proto:sendExtendedOpcode(30, json.encode({ action = action, data = data })) end
end

-- checked every minute, so a redemption that turns off is asked about again within a minute
local askedAt, openedFor
local function tick()
  if g_game.isOnline() and openedFor ~= me() then
    openedFor = me()
    pcall(send, 'open', {})
  end
  local wait = (owner == me() and dr and dr.active) and ASK_ON_MS or ASK_OFF_MS
  if g_game.isOnline() and (not askedAt or g_clock.millis() - askedAt >= wait) then
    askedAt = g_clock.millis()
    local ok, err = pcall(function()
      send('shopOpen', {})
      scheduleEvent(function() pcall(send, 'shopCategory', { page = 1, category = 'consum' }) end, 400)
    end)
    if not ok and log then log('orion-ots-tasks: ' .. tostring(err)) end
  end
  poll = scheduleEvent(tick, ASK_OFF_MS)
end

-- nil until Orion said which tasks run: an empty list then means none, which is how the website sees a task end
local function tasks()
  if owner ~= me() or not known then return nil end
  local out = {}
  for key, t in pairs(active) do
    local goal = goals[key] and goals[key][t.want]
    local whole = catalog[key] and catalog[key].want == t.want and catalog[key] or nil
    out[#out + 1] = { name = t.name, have = t.have, want = t.want,
                      exp = (goal and goal.exp) or (whole and whole.exp) or nil, taskPoints = goal and goal.taskPoints or nil }
  end
  table.sort(out, function(a, b) return a.name < b.name end)
  return out
end

local function tap()
  if wrapper or type(ProtocolGame) ~= 'table' or type(ProtocolGame.onExtendedOpcode) ~= 'function' then return end
  original = ProtocolGame.onExtendedOpcode
  local mine
  mine = function(self, opcode, buffer)
    local res = original(self, opcode, buffer)
    if opcode == 30 and wrapper == mine and type(buffer) == 'string' then
      local ok, err = pcall(onPacket, buffer)
      if not ok and tostring(err) ~= lastError and log then log('orion-ots-tasks: ' .. tostring(err)) end
      lastError = not ok and tostring(err) or lastError
    end
    return res
  end
  wrapper = mine
  ProtocolGame.onExtendedOpcode = mine
end

-- if someone wrapped the dispatcher after us, ours stays in their chain but only passes packets on from now
local function untap()
  if wrapper and type(ProtocolGame) == 'table' and ProtocolGame.onExtendedOpcode == wrapper then ProtocolGame.onExtendedOpcode = original end
  wrapper = nil
end

Voidwatch.register({
  id = 'orion-ots-tasks', name = 'Orion tasks', version = '3',
  match = { hosts = { 'orion-ots.pl' } },
  provides = { 'tasks', 'taskPoints', 'taskWeek', 'redemption', 'redemptionLeft' },
  fields = {
    tasks = tasks,
    taskPoints = function() return owner == me() and points or nil end,
    taskWeek = function() return owner == me() and week or nil end,
    redemption = function() if owner == me() and dr then return dr.active end end,
    redemptionLeft = function() if owner == me() and dr then return dr.left end end,
  },
  init = function(vw) log = vw.log; tap(); poll = scheduleEvent(tick, 10000) end,
  terminate = function()
    untap()
    if poll then removeEvent(poll) end
    poll = nil
  end,
})
