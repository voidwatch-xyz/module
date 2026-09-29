-- Voidwatch reference module, feed schema vw.status/1. MIT licence.
--
-- The client makes no web requests. The module writes files into <write dir>/voidwatch/outbox and reads what the
-- upload script leaves in <write dir>/voidwatch/inbox:
--   outbox/status.json          the character state: every 2 s while someone watches, every 30 s otherwise
--   outbox/capture.png          a screenshot, when the last reply asked for one
--   outbox/pair-request.json    who wants a pairing code (only until the script has a token)
--   outbox/results.json         how the commands went
--   inbox/reply.json            the last answer to status: statusEvery, captureEvery, commands, settings
--   inbox/pair.json             the pairing code and link to show the player
--   inbox/commands.json         commands to run
-- Server-specific data (routes, supplies, tasks) comes from adapters: see /developers/new-server.

Voidwatch = { adapters = {}, actions = {} }

local MODULE = 'voidwatch-feed/0.3.0'
local ROOT = '/voidwatch'
local LOOP_MS = 1000                                    -- how often the module looks at the reply; writing a file is cheap
local SERVER = ''                                       -- set it, or let an adapter return server()

local statusEvent, lastShot, lastStatus, lastCommands, shownCode = nil, 0, 0, '', nil

local function write(path, text) pcall(g_resources.writeFileContents, ROOT .. path, text) end
local function read(path)
  if not g_resources.fileExists(ROOT .. path) then return nil end
  local ok, text = pcall(g_resources.readFileContents, ROOT .. path)
  return ok and text or nil
end
local function readJson(path)
  local text = read(path)
  if not text then return nil end
  local ok, value = pcall(json.decode, text)
  return ok and value or nil
end

local function say(text)
  if modules.game_textmessage and modules.game_textmessage.displayGameMessage then
    modules.game_textmessage.displayGameMessage('[Voidwatch] ' .. text)
  end
  g_logger.info('[Voidwatch] ' .. text)
end

-- asks every adapter for a field; the first one that answers wins
local function ask(field, ...)
  for _, a in ipairs(Voidwatch.adapters) do
    if a[field] then
      local ok, value = pcall(a[field], ...)
      if ok and value ~= nil then return value end
    end
  end
  return nil
end

local function state()
  local p = g_game.getLocalPlayer()
  if not p then return nil end
  local pos = p:getPosition()
  local skulls = {}
  for _, c in ipairs(g_map.getSpectators(pos, false)) do
    if c:isPlayer() and c ~= p and c:getSkull() ~= SkullNone then
      local colours = { [SkullWhite] = 'white', [SkullRed] = 'red', [SkullBlack] = 'black', [SkullYellow] = 'yellow',
                        [SkullGreen] = 'green', [SkullOrange] = 'orange' }
      if colours[c:getSkull()] then table.insert(skulls, { name = c:getName(), skull = colours[c:getSkull()] }) end
    end
  end
  return {
    schema = 'vw.status/1', module = MODULE, online = g_game.isOnline(),
    character = { name = p:getName(), vocation = ask('vocation'), level = p:getLevel(), exp = p:getExperience() },
    pos = { x = pos.x, y = pos.y, z = pos.z },
    cap = math.floor(p:getFreeCapacity()), stamina = p:getStamina(),
    expPerHour = ask('expPerHour'), route = ask('route'), routeOn = ask('routeOn'), label = ask('label'),
    routes = ask('routes') or {}, supplies = ask('supplies') or {}, tasks = ask('tasks') or {}, loot = ask('loot') or {},
    lootHours = ask('lootHours'), skulls = skulls, blessed = ask('blessed'), redemptionLeft = ask('redemptionLeft'),
  }
end

local function pairIfNeeded(s)
  local pair = readJson('/inbox/pair.json')
  if pair and pair.paired then return end
  write('/outbox/pair-request.json', json.encode({ character = s.character.name, server = ask('server') or SERVER, module = MODULE }))
  if pair and pair.code and pair.code ~= shownCode then
    shownCode = pair.code
    say('pairing code ' .. pair.code .. ', or open ' .. (pair.url or 'the website'))
  end
end

local function runCommands()
  local text = read('/inbox/commands.json')
  if not text or text == lastCommands then return end
  lastCommands = text
  local ok, list = pcall(json.decode, text)
  if not ok or type(list) ~= 'table' then return end
  local results = {}
  for _, c in ipairs(list) do
    local fn = Voidwatch.actions[c.action] or ask('action', c.action)
    local done, message = false, 'not supported on this client'
    if fn then
      local okRun, res, msg = pcall(fn, c.args or {})
      done, message = okRun and res ~= false, okRun and msg or tostring(res)
    end
    table.insert(results, { id = c.id, ok = done, message = message })
  end
  write('/outbox/results.json', json.encode(results))
end

local function tick()
  statusEvent = scheduleEvent(tick, LOOP_MS)
  if not g_game.isOnline() then return end
  local reply = readJson('/inbox/reply.json') or {}
  if g_clock.millis() - lastStatus >= (reply.statusEvery or 30) * 1000 or reply.statusEvery == nil then
    local s = state()
    if not s then return end
    lastStatus = g_clock.millis()
    pairIfNeeded(s)
    write('/outbox/status.json', json.encode(s))
  end
  local every = (reply.captureEvery or 60) * 1000
  if g_clock.millis() - lastShot >= every then
    lastShot = g_clock.millis()
    g_app.doScreenshot(ROOT .. '/outbox/capture.png')
  end
  runCommands()
end

-- actions every client can run without an adapter
Voidwatch.actions.capture = function() lastShot = 0; return true end
Voidwatch.actions.logout_in_pz = function()
  local p = g_game.getLocalPlayer()
  if p and p:isInProtectionZone() then g_game.safeLogout(); return true end
  return false, 'not in a protection zone'
end

function Voidwatch.init()
  g_resources.makeDir(ROOT)
  g_resources.makeDir(ROOT .. '/outbox')
  g_resources.makeDir(ROOT .. '/inbox')
  statusEvent = scheduleEvent(tick, 1000)
  -- the setup finds clients in the usual places; for any other place it needs this folder once
  scheduleEvent(function()
    local pair = readJson('/inbox/pair.json')
    if not pair then say('run the Voidwatch setup once. If it does not find this client, give it this folder: ' .. g_resources.getWriteDir() .. 'voidwatch') end
  end, 8000)
end

function Voidwatch.terminate()
  if statusEvent then removeEvent(statusEvent) end
  statusEvent = nil
end
