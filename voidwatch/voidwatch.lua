-- Voidwatch reference module, feed schema vw.status/1. MIT licence.
--
-- The client makes no web requests. Clients on one computer often share a write directory, so every character has
-- its own folder, <write dir>/voidwatch/<character>/. The module writes files there and the upload script answers:
--   outbox/status.json          the character state: every 2 s while someone watches, every 30 s otherwise
--   outbox/capture.png          a screenshot of the game view, when the last reply asked for one
--   outbox/pair-request.json    who wants a pairing code, until the character is paired
--   outbox/results.json         how the commands went
--   inbox/reply.json            the last answer to status: statusEvery, captureEvery, commands, settings
--   inbox/pair.json             the pairing code and link to show the player, or paired: true
--   inbox/commands.json         commands to run
-- Everything the stock client knows, the module reads itself. The rest comes from adapters (/developers/new-server):
--   Voidwatch.register(adapter)    a server adapter in this module, for example orion.lua; it runs only on its server
--   Voidwatch.attachBot(adapter)   the bot adapter, a script in the bot's config folder; it attaches every 10 s
-- A file named "off" in <write dir>/voidwatch stops the module in every client. In the console,
-- modules.voidwatch.Voidwatch.stop() stops this one and modules.voidwatch.Voidwatch.status() shows what it does;
-- modules.voidwatch.Voidwatch.installBot() and .removeBot() add or remove the bot adapter in the selected bot config,
-- and modules.voidwatch.Voidwatch.resetLoot() starts the loot counters over. After an update that adds a file,
-- run g_modules.discoverModules() before the reload: a reload keeps the file list the client read at its start.

Voidwatch = { actions = {} }

local MODULE = 'voidwatch-feed/0.5.1'
local ROOT = '/voidwatch'
local LOOP_MS = 1000                                    -- how often the module looks at the reply; writing a file is cheap
local SERVER = ''                                       -- set it, or let an adapter return the server field
local CAPTURES = true                                   -- the game view only: the whole window is larger than the API takes
local COMMANDS = false                                  -- stays off until commands have run for hours on a real client
local BOT_FRESH_MS = 30000                              -- bot data older than this is dropped: the bot reloaded or stopped
local LOOT_FLUSH_MS = 10000                             -- the loot file is written at most this often, and at logout
local LOOT_ITEMS = 200                                  -- the most items one loot source keeps, as the API takes
local SUPPLY_ITEMS = 60                                 -- the most supply chips the API takes
local COINS = { ['gold coin'] = 1, ['platinum coin'] = 100, ['crystal coin'] = 10000 }
local GUARD_EVERY = 5                                   -- loops between two memory checks
local GUARD_WINDOW = 120                                -- checks kept for the heap floor: 10 minutes
local GUARD_LUA_MB = 200                                -- growth of the heap floor since load that stops the module
local GUARD_PROCESS_MB = 1400                           -- process memory that stops the module
local MAX_ERRORS = 10                                   -- errors in a row that stop the module
local SETUP_HINT_MS = 20000                             -- no answer from the upload script this long after login

local SKULLS = { [SkullWhite or 3] = 'white', [SkullRed or 4] = 'red', [SkullBlack or 5] = 'black', [SkullYellow or 1] = 'yellow',
                 [SkullGreen or 2] = 'green', [SkullOrange or 6] = 'orange' }

-- the status fields an adapter may fill; anything else it returns is ignored
local FIELDS = { 'server', 'vocation', 'expPerHour', 'route', 'routeOn', 'label', 'routes', 'targetOn', 'botConfig',
                 'targetProfile', 'botProfile', 'supplies', 'tasks', 'taskPoints', 'taskWeek', 'loot', 'lootHours',
                 'lootSource', 'blessed', 'redemption', 'redemptionLeft' }

local alive, halted, loopEvent = false, nil, nil
local loops, errors, lastError, baseKB, heap = 0, 0, nil, 0, {}
local me = {}
local adapters, order = {}, {}                          -- id -> { def, running, off, errors, lastError }
local bot = nil                                         -- { def, at, errors, blockedUntil }
-- the character's loot since the last reset, per source: 'corpse' from the loot messages, or an adapter's id
local ledger, ledgerDirty, ledgerFlushAt = nil, false, 0
local prices = nil                                      -- { sell = { name = best price }, buy = { name = lowest price } }
local lastLeft = {}                                     -- name -> the count the last "Using one of N" line showed
-- name -> { n = what is carried now, consumed = true once a use made the count drop }: every bag, closed ones too
local carried, carriedDirty = {}, false

local function log(text) g_logger.info('[Voidwatch] ' .. text) end

local function say(text)
  pcall(function() modules.game_textmessage.displayGameMessage('[Voidwatch] ' .. text) end)
  log(text)
end

local function write(path, text)
  local ok, res = pcall(g_resources.writeFileContents, path, text)
  return ok and res ~= false
end

local function read(path)
  if not g_resources.fileExists(path) then return nil end
  local ok, text = pcall(g_resources.readFileContents, path)
  return ok and text or nil
end

local function readJson(path)
  local text = read(path)
  if not text then return nil end
  local ok, value = pcall(json.decode, text)
  return ok and type(value) == 'table' and value or nil
end

local function keyOf(name) return (name:lower():gsub('[^%w]+', '_')) end

local function mb(bytes) return math.floor(bytes / 1048576) end

-- some clients return an empty OS name; the client's own build target is the fallback
local function platform()
  for _, get in ipairs({ function() return g_platform.getOSName() end, function() return g_app.getOs() end }) do
    local ok, os = pcall(get)
    if ok and type(os) == 'string' and os ~= '' then return (os:gsub('^%l', string.upper)) end
  end
  return nil
end

local function features()
  local list = { 'status' }
  if CAPTURES then list[#list + 1] = 'captures' end
  if COMMANDS then list[#list + 1] = 'commands' end
  return list
end

-- the website finds the server from these: the login address, the world and the protocol version
local function origin()
  local okHost, host = pcall(g_settings.get, 'host')
  local okWorld, world = pcall(g_game.getWorldName)
  local okVersion, version = pcall(g_game.getClientVersion)
  return okHost and type(host) == 'string' and host ~= '' and host:sub(1, 200) or nil,
         okWorld and type(world) == 'string' and world ~= '' and world:sub(1, 60) or nil,
         okVersion and tonumber(version) or nil
end

local function addLoot(source, name, count)
  count = tonumber(count) or 0
  if not ledger or type(name) ~= 'string' or name == '' or count <= 0 then return end
  local items = ledger.sources[source] or {}
  ledger.sources[source] = items
  if not items[name] then
    local n = 0
    for _ in pairs(items) do n = n + 1 end
    if n >= LOOT_ITEMS then return end
  end
  items[name] = (items[name] or 0) + count
  ledgerDirty = true
end

local function newLedger() return { since = os.time(), onlineS = 0, sources = {}, used = {} } end

local function loadLedger()
  local t = readJson(me.dir .. '/loot.json')
  ledger = (t and type(t.sources) == 'table') and t or newLedger()
  ledger.onlineS = tonumber(ledger.onlineS) or 0
  if type(ledger.used) ~= 'table' then ledger.used = {} end
end

local function addUsed(name, n)
  if not ledger or name == '' or n <= 0 then return end
  local count = 0
  for _ in pairs(ledger.used) do count = count + 1 end
  if not ledger.used[name] and count >= LOOT_ITEMS then return end
  ledger.used[name] = (ledger.used[name] or 0) + n
  ledgerDirty = true
end

local function flushLedger(force)
  if not ledger or not me.dir or not (ledgerDirty or carriedDirty) then return end
  if not force and g_clock.millis() < ledgerFlushAt then return end
  ledgerFlushAt = g_clock.millis() + LOOT_FLUSH_MS
  if ledgerDirty then write(me.dir .. '/loot.json', json.encode(ledger)) end
  if carriedDirty and next(carried) then write(me.dir .. '/carried.json', json.encode(carried)) end
  ledgerDirty, carriedDirty = false, false
end

-- a count above one comes as a plural: "43 gold coins", "2 small rubies", "3 pieces of royal steel"
local function singular(word)
  if word:match('ies$') then return (word:gsub('ies$', 'y')) end
  if word:match('[sxz]es$') or word:match('[cs]hes$') then return (word:gsub('es$', '')) end
  if word:match('[^s]s$') then return (word:gsub('s$', '')) end
  return word
end

local function lootName(part)
  part = part:lower():gsub('^%s+', ''):gsub('%s+$', '')
  local n, rest = part:match('^(%d+)%s+(.+)$')
  if not n then return (part:gsub('^an?%s+', ''):gsub('^the%s+', '')), 1 end
  local head, tail = rest:match('^(.-)(%s+of%s+.+)$')
  if head then return (head:gsub('(%S+)$', singular)) .. tail, tonumber(n) end
  return (rest:gsub('(%S+)$', singular)), tonumber(n)
end

-- The game says how many you had before each use: "Using one of 100 great mana potions...", and for the last one
-- "Using the last great mana potion...". A count one lower than the line before means one was used; a rope or a
-- shovel never goes down, so tools never count. Like vBot's analyzer, the last use before a refill is not seen.
local function onUse(text)
  local n, plural = text:match('^Using one of (%d+) (.-)%.%.%.')
  local name, left
  if n then
    name, left = lootName(n .. ' ' .. plural)
  else
    name = text:match('^Using the last (.-)%.%.%.')
    if not name then return false end
    name, left = lootName(name), 1
  end
  local before = lastLeft[name]
  local c = carried[name] or {}
  if before and left < before and before - left <= 10 then addUsed(name, before - left); c.consumed = true end
  lastLeft[name] = (left > 1) and left or nil       -- the next line after the last one comes after a refill
  if left == 1 and before == 2 then addUsed(name, 1) end
  -- the line shows the count before the use: a supply has one less now, a rope or a probe the same
  c.n = c.consumed and math.max(0, left - 1) or left
  carried[name], carriedDirty = c, true
  return true
end

-- "Loot of a dragon: 2 dragon hams, 43 gold coins." is what the corpse held; every server sends it
local function onTextMessage(mode, text)
  if not alive or halted or not ledger or type(text) ~= 'string' then return end
  if onUse(text) then return end
  local body = text:match('^Loot of [^:]+:%s*(.+)$')
  if not body or body:lower():match('^nothing') then return end
  for part in body:gsub('%.%s*$', ''):gmatch('[^,]+') do
    local name, n = lootName(part)
    addLoot('corpse', name, n)
  end
end

-- the stock client hands every trade window's list to this event: { item, name, weight, buy price, sell price }
local function readPrices()
  local t = readJson(ROOT .. '/prices.json') or {}
  if type(t.sell) ~= 'table' and type(t.buy) ~= 'table' then t = { sell = t, buy = {} } end   -- the first files held sell prices only
  t.sell, t.buy = type(t.sell) == 'table' and t.sell or {}, type(t.buy) == 'table' and t.buy or {}
  return t
end

-- the stock client hands every trade window's list to this event: { item, name, weight, buy price, sell price }.
-- The best price wins: the highest an NPC pays, the lowest an NPC asks.
local function onOpenNpcTrade(items)
  if not alive or type(items) ~= 'table' then return end
  local all = readPrices()                              -- another client may have learned prices meanwhile
  local changed = false
  for _, it in pairs(items) do
    local name = type(it) == 'table' and type(it[2]) == 'string' and it[2]:lower()
    local buy, sell = name and tonumber(it[4]), name and tonumber(it[5])
    if sell and sell > 0 and (not tonumber(all.sell[name]) or sell > tonumber(all.sell[name])) then all.sell[name], changed = sell, true end
    if buy and buy > 0 and (not tonumber(all.buy[name]) or buy < tonumber(all.buy[name])) then all.buy[name], changed = buy, true end
  end
  prices = all
  if changed then write(ROOT .. '/prices.json', json.encode(all)) end
end

local function priceOf(name) return COINS[name] or (prices and tonumber(prices.sell[name])) or nil end
local function buyPriceOf(name) return prices and tonumber(prices.buy[name]) or nil end

local function provides(def, name)
  for _, v in ipairs(type(def.provides) == 'table' and def.provides or {}) do if v == name then return true end end
  return false
end

local function domainOf(host)
  return (tostring(host or ''):lower():gsub('^%a+://', ''):gsub('/.*$', ''):gsub(':%d+$', ''))
end

local function matches(def, host, world)
  local m = def.match
  if type(m) ~= 'table' then return true end
  local function any(list, test)
    if type(list) ~= 'table' then return true end
    for _, v in ipairs(list) do if test(tostring(v):lower()) then return true end end
    return false
  end
  local domain, w = domainOf(host), tostring(world or ''):lower()
  return any(m.hosts, function(h) return domain == h or domain:sub(-#h - 1) == '.' .. h end)
     and any(m.worlds, function(v) return v == w end)
end

-- one call into an adapter; MAX_ERRORS in a row turn that adapter off, and only that one
local function call(rec, name, fn, ...)
  local ok, res, extra = pcall(fn, ...)
  if ok then rec.errors = 0; return true, res, extra end
  rec.errors = rec.errors + 1
  if tostring(res) ~= rec.lastError then log(('adapter %s, %s: %s'):format(rec.def.id, name, tostring(res))) end
  rec.lastError = tostring(res)
  if rec.errors >= MAX_ERRORS and rec.def ~= (bot and bot.def) then
    rec.off = true
    if rec.running and rec.def.terminate then pcall(rec.def.terminate) end
    rec.running = false
    say(('adapter %s stopped after %d errors: %s'):format(rec.def.id, MAX_ERRORS, rec.lastError))
  end
  return false
end

local function stopAdapters()
  for _, id in ipairs(order) do
    local rec = adapters[id]
    if rec.running and rec.def.terminate then pcall(rec.def.terminate) end
    rec.running = false
  end
end

-- at every login: start the adapters for this server, stop the others
local function startAdapters()
  local host, world = origin()
  for _, id in ipairs(order) do
    local rec = adapters[id]
    local want = not rec.off and matches(rec.def, host, world)
    if want and not rec.running then
      rec.running = true
      local id = rec.def.id
      if rec.def.init then
        call(rec, 'init', rec.def.init, { log = log, say = say, addLoot = function(name, n) addLoot(id, name, n) end })
      end
    elseif not want and rec.running then
      if rec.def.terminate then pcall(rec.def.terminate) end
      rec.running = false
    end
  end
end

local function freshBot()
  if not bot or g_clock.millis() - bot.at > BOT_FRESH_MS then return nil end
  if bot.blockedUntil and g_clock.millis() < bot.blockedUntil then return nil end
  return bot
end

-- a running adapter that lists a field in `provides` owns it: an empty answer then means unknown, not "use the core's"
local function owned(name)
  for _, id in ipairs(order) do
    if adapters[id].running and provides(adapters[id].def, name) then return true end
  end
  return false
end

-- the first answer wins: the module's adapters first, then the bot
local function field(name)
  for _, id in ipairs(order) do
    local rec = adapters[id]
    local fn = rec.running and type(rec.def.fields) == 'table' and rec.def.fields[name]
    if fn then
      local ok, value = call(rec, name, fn)
      if ok and value ~= nil then return value end
    end
  end
  local b = freshBot()
  local fn = b and type(b.def.fields) == 'table' and b.def.fields[name]
  if fn then
    local ok, value = call(b, name, fn)
    if ok then
      if value ~= nil then return value end
    elseif b.errors >= MAX_ERRORS then
      b.blockedUntil, b.errors = g_clock.millis() + 60000, 0
      log('bot adapter paused for a minute after ' .. MAX_ERRORS .. ' errors: ' .. tostring(b.lastError))
    end
  end
  return nil
end

local function action(name)
  if Voidwatch.actions[name] then return Voidwatch.actions[name] end
  for _, id in ipairs(order) do
    local rec = adapters[id]
    if rec.running and type(rec.def.actions) == 'table' and rec.def.actions[name] then return rec.def.actions[name] end
  end
  local b = freshBot()
  return b and type(b.def.actions) == 'table' and b.def.actions[name] or nil
end

local function adapterStates()
  local states = {}
  for _, id in ipairs(order) do
    local rec = adapters[id]
    if rec.running or rec.off then states[#states + 1] = { id = id, version = tostring(rec.def.version or ''), on = rec.running } end
  end
  if bot then
    states[#states + 1] = { id = tostring(bot.def.id or 'bot'), version = tostring(bot.def.version or ''), on = freshBot() ~= nil }
  end
  return states
end

-- an adapter that counts loot (an autoloot, the bot) wins over the loot messages, which only say what a corpse held
local function lootState()
  if not ledger then return nil end
  local source = 'corpse'
  for _, id in ipairs(order) do
    local rec = adapters[id]
    if rec.running and provides(rec.def, 'loot') then source = id break end
  end
  local items = {}
  for name, count in pairs(ledger.sources[source] or {}) do
    items[#items + 1] = { name = name:sub(1, 60), count = count, sell = priceOf(name) }
  end
  table.sort(items, function(a, b) return a.name < b.name end)
  return #items > 0 and items or nil, source, math.floor(ledger.onlineS / 36) / 100
end

-- case 1: the bot's own supply list, with "have" from the game's last count where it has one; case 3, when the bot
-- has no list or the player turned it off: every item the "Using one of" lines named
local function supplyState(botRows, useBotList)
  if useBotList and type(botRows) == 'table' and #botRows > 0 then
    for _, r in ipairs(botRows) do
      local c = type(r) == 'table' and carried[tostring(r.name):lower()]
      if c and c.n then r.have = c.n end
    end
    return botRows, 'bot'
  end
  local rows = {}
  for name, c in pairs(carried) do
    if c.n then rows[#rows + 1] = { name = name:sub(1, 60), have = c.n } end
  end
  table.sort(rows, function(a, b) return a.name < b.name end)
  while #rows > SUPPLY_ITEMS do table.remove(rows) end
  return (#rows > 0 and rows or nil), (#rows > 0 and 'used' or nil)
end

local function usedState()
  if not ledger then return nil end
  local items = {}
  for name, count in pairs(ledger.used) do
    items[#items + 1] = { name = name:sub(1, 60), count = count, buy = buyPriceOf(name) }
  end
  table.sort(items, function(a, b) return a.name < b.name end)
  return #items > 0 and items or nil
end

-- the stock skills module keeps the exp per second on the player, the number its level bar tooltip shows per hour
local function stockExpPerHour(p)
  local ok, speed = pcall(function() return p.expSpeed end)
  if ok and type(speed) == 'number' and speed >= 0 then return math.floor(speed * 3600) end
  return nil
end

-- an empty list is left out: the API fills in its own default
local function list(value)
  if type(value) ~= 'table' or next(value) == nil then return nil end
  return value
end

-- some clients have no isInProtectionZone; the protection zone is then a bit of the player's states
local function inPz(p)
  if type(p.isInProtectionZone) == 'function' then
    local ok, v = pcall(p.isInProtectionZone, p)
    if ok and type(v) == 'boolean' then return v end
  end
  local ok, v = pcall(function() return bit.band(p:getStates(), (PlayerStates and PlayerStates.Pz) or 16384) > 0 end)
  if ok then return v end
  return nil
end

local function stockBlessed(p)
  if type(p.getBlessings) ~= 'function' then return nil end
  local ok, v = pcall(p.getBlessings, p)
  if ok and type(v) == 'number' then return v > 0 end
  return nil
end

local function outfitOf(p)
  local ok, o = pcall(function() return p:getOutfit() end)
  if not ok or type(o) ~= 'table' or not tonumber(o.type) then return nil end
  local n = function(v) return math.max(0, math.floor(tonumber(v) or 0)) end
  return { type = n(o.type), head = n(o.head), body = n(o.body), legs = n(o.legs), feet = n(o.feet), addons = n(o.addons) }
end

local function pzLocked(p)
  local ok, v = pcall(function() return bit.band(p:getStates(), (PlayerStates and PlayerStates.PzBlock) or 8192) > 0 end)
  if ok then return v end
  return nil
end

local function changed()
  if Voidwatch.ui and Voidwatch.ui.changed then pcall(Voidwatch.ui.changed) end
end

local function halt(why)
  halted = why
  stopAdapters()
  say('stopped: ' .. why .. '. Start it again in the Voidwatch window, or reload the module.')
  changed()
end

local function guard()
  local kb = collectgarbage('count')
  heap[#heap + 1] = kb
  if #heap > GUARD_WINDOW then table.remove(heap, 1) end
  local floor = kb
  for _, v in ipairs(heap) do if v < floor then floor = v end end
  local grown = math.floor((floor - baseKB) / 1024)
  if grown > GUARD_LUA_MB then return halt(('the Lua heap grew %d MB'):format(grown)) end
  local ok, bytes = pcall(g_platform.getMemoryUsage)
  if ok and type(bytes) == 'number' and mb(bytes) > GUARD_PROCESS_MB then
    return halt(('the client uses %d MB'):format(mb(bytes)))
  end
end

local function state(p)
  local level, exp = p:getLevel(), p:getExperience()
  if not level or level < 1 or not exp or exp < 0 then return nil end  -- right after a relog the server sends -1
  local pos = p:getPosition()
  if not pos then return nil end
  local skulls, players = {}, 0
  for _, c in ipairs(g_map.getSpectators(pos, false)) do
    if c:isPlayer() and c ~= p then
      players = players + 1
      if SKULLS[c:getSkull()] then
        local okQ, q = pcall(function() return c:getPosition() end)
        q = okQ and q or nil
        table.insert(skulls, { name = c:getName(), skull = SKULLS[c:getSkull()],
                               dist = q and math.min(100, math.max(math.abs(q.x - pos.x), math.abs(q.y - pos.y))) or nil })
      end
    end
  end

  local s = {
    schema = 'vw.status/1', module = MODULE, online = true,
    character = { name = p:getName(), level = level, exp = exp },
    pos = { x = pos.x, y = pos.y, z = pos.z },
    cap = math.max(0, math.floor(p:getFreeCapacity())),
    stamina = p.getStamina and math.max(0, math.min(2520, p:getStamina())) or nil,
    skulls = list(skulls), features = features(), playersInView = players, skull = SKULLS[p:getSkull()],
    pz = inPz(p), pzLock = pzLocked(p), outfit = outfitOf(p),
  }
  for _, name in ipairs(FIELDS) do
    if name ~= 'server' then
      local value = field(name)
      if type(value) == 'table' and name ~= 'tasks' then value = list(value) end
      if name == 'vocation' then s.character.vocation = value else s[name] = value end
    end
  end
  s.expPerHour = s.expPerHour or stockExpPerHour(p)
  if s.blessed == nil and not owned('blessed') then s.blessed = stockBlessed(p) end
  if s.loot == nil then
    local items, source, hours = lootState()
    s.loot, s.lootHours = items, s.lootHours or hours
    s.lootSource = items and source or nil
  end
  s.used = usedState()
  s.supplies, s.suppliesSource = supplyState(s.supplies, not (me.settings and me.settings.supplyList == false))
  s.adapters = list(adapterStates())
  return s
end

local function pairing(name)
  local pair = readJson(me.dir .. '/inbox/pair.json')
  me.answered = me.answered or pair ~= nil
  me.pair = pair
  if pair and pair.paired then
    if me.shownCode and not me.saidPaired then say(name .. ' is connected to your Voidwatch account.') end
    me.saidPaired = true
    return true
  end
  me.saidPaired = false
  if pair and pair.code and pair.code ~= me.shownCode then
    me.shownCode = pair.code
    say(('pairing code %s. Open %s to add %s to your account.'):format(pair.code, pair.url or 'voidwatch.xyz', name))
  elseif not me.answered and not me.hinted and g_clock.millis() - me.since > SETUP_HINT_MS then
    me.hinted = true
    say('the upload script did not answer. Run the Voidwatch setup once. If it does not find this client, give it '
        .. 'this folder: ' .. g_resources.getWriteDir() .. 'voidwatch')
  end
  return false
end

local function runCommands()
  local text = read(me.dir .. '/inbox/commands.json')
  if not text or text == me.lastCommands then return end
  me.lastCommands = text
  local ok, cmds = pcall(json.decode, text)
  if not ok or type(cmds) ~= 'table' then return end
  local results = {}
  for _, c in ipairs(cmds) do
    local fn = action(c.action)
    local done, message = false, 'not supported on this client'
    if fn then
      local okRun, res, msg = pcall(fn, c.args or {})
      done, message = okRun and res ~= false, okRun and msg or tostring(res)
    end
    table.insert(results, { id = c.id, ok = done, message = message })
  end
  write(me.dir .. '/outbox/results.json', json.encode(results))
end

local function step()
  if g_resources.fileExists(ROOT .. '/off') or not g_game.isOnline() then return end
  local p = g_game.getLocalPlayer()
  local name = p and p:getName()
  if not name or name == '' then return end
  if me.key ~= keyOf(name) then
    flushLedger(true)
    me = { key = keyOf(name), lastStatus = -math.huge, lastShot = -math.huge, since = g_clock.millis() }
    me.dir = ROOT .. '/' .. me.key
    for _, d in ipairs({ ROOT, me.dir, me.dir .. '/outbox', me.dir .. '/inbox' }) do pcall(g_resources.makeDir, d) end
    loadLedger()
    if not prices then prices = readPrices() end
    lastLeft = {}
    local saved = readJson(me.dir .. '/carried.json')
    carried, carriedDirty = type(saved) == 'table' and saved or {}, false
    startAdapters()
  end
  local now0 = g_clock.millis()
  if me.lastTick then
    ledger.onlineS = ledger.onlineS + math.min(10000, now0 - me.lastTick) / 1000
    ledgerDirty = true
  end
  me.lastTick = now0
  flushLedger(false)
  local paired = pairing(name)
  -- the reply carries the server time, so a new text means the upload script got an answer just now
  local replyText = paired and read(me.dir .. '/inbox/reply.json') or nil
  if replyText and replyText ~= me.replyText then me.replyText, me.replyAt = replyText, g_clock.millis() end
  local okReply, reply = pcall(json.decode, replyText or '{}')
  reply = okReply and type(reply) == 'table' and reply or {}
  me.reply = reply
  me.settings = type(reply.settings) == 'table' and reply.settings or {}
  local now = g_clock.millis()
  if now - me.lastStatus >= (tonumber(reply.statusEvery) or 30) * 1000 then
    local s = state(p)
    if s then
      me.lastStatus, me.last = now, s
      if not paired then
        local host, world, version = origin()
        write(me.dir .. '/outbox/pair-request.json', json.encode({ character = name, server = field('server') or SERVER,
          platform = platform(), module = MODULE, host = host, world = world, clientVersion = version }))
      end
      write(me.dir .. '/outbox/status.json', json.encode(s))
    end
  end
  if CAPTURES and paired and me.settings.captures ~= false and now - me.lastShot >= (tonumber(reply.captureEvery) or 60) * 1000 then
    me.lastShot = now
    g_app.doMapScreenshot(me.dir .. '/outbox/capture.png')
  end
  if COMMANDS and paired then runCommands() end
end

local function tick()
  loopEvent = nil
  if not alive or halted then return end
  loops = loops + 1
  if loops % GUARD_EVERY == 0 then
    guard()
    if halted then return end
  end
  local ok, err = pcall(step)
  if ok then
    errors = 0
  else
    errors = errors + 1
    if tostring(err) ~= lastError then log('error: ' .. tostring(err)) end
    lastError = tostring(err)
    if errors >= MAX_ERRORS then return halt(MAX_ERRORS .. ' errors in a row, the last one: ' .. lastError) end
  end
  changed()
  if alive then loopEvent = scheduleEvent(tick, LOOP_MS) end
end

-- actions every client can run without an adapter
Voidwatch.actions.capture = function() me.lastShot = -math.huge; return true end
Voidwatch.actions.logout_in_pz = function()
  local p = g_game.getLocalPlayer()
  if p and inPz(p) then g_game.safeLogout(); return true end
  return false, 'not in a protection zone'
end

-- a second register with the same id replaces the first, so a reloaded adapter file does not run twice
function Voidwatch.register(def)
  if type(def) ~= 'table' or type(def.id) ~= 'string' or def.id == '' then return false end
  local old = adapters[def.id]
  if old then
    if old.running and old.def.terminate then pcall(old.def.terminate) end
  else
    order[#order + 1] = def.id
  end
  adapters[def.id] = { def = def, running = false, off = false, errors = 0 }
  if alive and me.key then startAdapters() end
  return true
end

function Voidwatch.attachBot(def)
  if type(def) ~= 'table' then return false end
  if bot and bot.def == def then bot.at = g_clock.millis(); return true end
  bot = { def = def, at = g_clock.millis(), errors = 0 }
  return true
end

function Voidwatch.init()
  alive, halted, loops, errors, lastError, me, bot = true, nil, 0, 0, nil, {}, nil
  ledger, ledgerDirty, prices = nil, false, nil
  connect(g_game, { onTextMessage = onTextMessage, onOpenNpcTrade = onOpenNpcTrade })
  baseKB = collectgarbage('count')
  heap = { baseKB }
  loopEvent = scheduleEvent(tick, LOOP_MS)
  if Voidwatch.ui and Voidwatch.ui.init then pcall(Voidwatch.ui.init) end
  log(('%s loaded, Lua heap %d MB'):format(MODULE, math.floor(baseKB / 1024)))
end

function Voidwatch.terminate()
  alive = false
  if Voidwatch.ui and Voidwatch.ui.terminate then pcall(Voidwatch.ui.terminate) end
  stopAdapters()
  disconnect(g_game, { onTextMessage = onTextMessage, onOpenNpcTrade = onOpenNpcTrade })
  flushLedger(true)
  if loopEvent then removeEvent(loopEvent) end
  loopEvent = nil
end

local function botConfig()
  local ok, name = pcall(function() return modules.game_bot.contentsPanel.config:getCurrentOption().text end)
  return ok and type(name) == 'string' and name ~= '' and name or nil
end

-- console helpers, see the top of the file. The bot file goes in only when the player asks for it.
function Voidwatch.installBot()
  local config = botConfig()
  if not config then return say('no bot config is selected in the bot window.') end
  local src
  for _, path in ipairs({ '/modules/voidwatch/bot/voidwatch_bot.lua', '/mods/voidwatch/bot/voidwatch_bot.lua' }) do
    src = src or read(path)
  end
  if not src then return say('the bot adapter is missing from the module folder.') end
  if write('/bot/' .. config .. '/voidwatch_bot.lua', src) then
    say('bot adapter added to ' .. config .. '. Reload the bot, or log in again, to start it.')
  end
end

function Voidwatch.removeBot()
  local config = botConfig()
  if not config then return say('no bot config is selected in the bot window.') end
  pcall(g_resources.deleteFile, '/bot/' .. config .. '/voidwatch_bot.lua')
  bot = nil
  say('bot adapter removed from ' .. config .. '. Reload the bot to stop it.')
end

function Voidwatch.resetLoot()
  if not ledger then return say('log in first.') end
  ledger, ledgerDirty, lastLeft = newLedger(), true, {}
  flushLedger(true)
  say('loot and supply counters reset.')
end

function Voidwatch.stop()
  Voidwatch.terminate()
  say('stopped from the console. Reload the module to start it again.')
end

-- the window: what this client does now, read-only, and three actions
local GIVES = { { 'server', 'server' }, { 'blessed', 'blessings' }, { 'tasks', 'tasks' }, { 'taskPoints', 'task points' },
                { 'redemption', 'death redemption' }, { 'loot', 'the autoloot list' }, { 'route', 'route' }, { 'routeOn', 'cavebot' },
                { 'targetOn', 'targetbot' } }

local function gives(has)
  local out = {}
  for _, g in ipairs(GIVES) do if has(g[1]) then out[#out + 1] = g[2] end end
  return table.concat(out, ', ')
end

local function sources()
  local out = {}
  for _, id in ipairs(order) do
    local rec = adapters[id]
    if rec.running then
      out[#out + 1] = { name = tostring(rec.def.name or id), on = true, gives = gives(function(f) return provides(rec.def, f) end) }
    end
  end
  if bot then
    local f = type(bot.def.fields) == 'table' and bot.def.fields or {}
    local text = gives(function(name) return f[name] ~= nil and name ~= 'server' end)
    if me.last and me.last.suppliesSource == 'bot' then text = text .. (text ~= '' and ', ' or '') .. 'supply list' end
    out[#out + 1] = { name = 'Bot - ' .. tostring(me.last and me.last.botConfig or bot.def.id or 'bot'), on = freshBot() ~= nil, gives = text }
  end
  out[#out + 1] = { name = 'Client', on = true, gives = 'level, exp/h, loot and supplies from the game messages' }
  return out
end

local function stateOf()
  if g_resources.fileExists(ROOT .. '/off') then return 'off' end
  if halted then return 'stopped' end
  if not g_game.isOnline() then return 'offline' end
  if me.saidPaired then return 'connected' end
  return me.pair and me.pair.code and 'pairing' or 'waiting'
end
Voidwatch.state = stateOf

function Voidwatch.view()
  local now = g_clock.millis()
  local p = g_game.isOnline() and g_game.getLocalPlayer() or nil
  for _, id in ipairs(order) do
    if adapters[id].running and provides(adapters[id].def, 'server') and adapters[id].def.name then me.serverName = adapters[id].def.name break end
  end
  local okMem, bytes = pcall(g_platform.getMemoryUsage)
  local settings = me.settings or {}
  return {
    state = stateOf(), version = MODULE:match('/(.+)$') or MODULE, stopped = halted,
    character = p and p:getName() or nil, server = me.serverName or (g_game.getWorldName and g_game.getWorldName()) or nil,
    code = me.pair and me.pair.code or nil, url = me.pair and me.pair.url or nil, expiresAt = me.pair and tonumber(me.pair.expiresAt) or nil,
    answered = me.answered == true, replyS = me.replyAt and math.floor((now - me.replyAt) / 1000) or nil,
    statusEvery = tonumber(me.reply and me.reply.statusEvery), captureEvery = tonumber(me.reply and me.reply.captureEvery),
    captures = CAPTURES and settings.captures ~= false, supplyList = settings.supplyList ~= false,
    suppliesSource = me.last and me.last.suppliesSource or nil, commands = COMMANDS,
    heapMB = math.floor(collectgarbage('count') / 1024), clientMB = okMem and type(bytes) == 'number' and mb(bytes) or nil,
    errors = errors, lastError = lastError, sources = sources(), dir = g_resources.getWriteDir() .. 'voidwatch',
  }
end

function Voidwatch.stopHere()
  if not halted then halt('by you, in the Voidwatch window') end
end

-- the off file stops the module in every client that shares this folder
function Voidwatch.stopAll()
  write(ROOT .. '/off', 'stopped in the Voidwatch window\n')
  changed()
end

function Voidwatch.startAgain()
  if g_resources.fileExists(ROOT .. '/off') then pcall(g_resources.deleteFile, ROOT .. '/off') end
  if halted then
    halted, errors, lastError = nil, 0, nil
    baseKB = collectgarbage('count')
    heap = { baseKB }
    if me.key then startAdapters() end
    say('started again.')
  end
  if alive and not loopEvent then loopEvent = scheduleEvent(tick, LOOP_MS) end
  changed()
end

function Voidwatch.status()
  local ok, bytes = pcall(g_platform.getMemoryUsage)
  local line = ('%s alive=%s halted=%s off=%s character=%s paired=%s status %s s ago, heap %d MB (%+d), client %s MB, errors %d%s'):format(
    MODULE, tostring(alive), tostring(halted or 'no'), tostring(g_resources.fileExists(ROOT .. '/off')),
    tostring(me.key), tostring(me.saidPaired or false),
    me.lastStatus and me.lastStatus > -math.huge and math.floor((g_clock.millis() - me.lastStatus) / 1000) or '-',
    math.floor(collectgarbage('count') / 1024), math.floor((collectgarbage('count') - baseKB) / 1024),
    ok and type(bytes) == 'number' and mb(bytes) or '?', errors, lastError and (', last: ' .. lastError) or '')
  print(line)
  return line
end
