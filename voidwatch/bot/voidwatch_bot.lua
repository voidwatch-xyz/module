-- Voidwatch bot adapter, MIT licence. The Voidwatch module copies it into the bot's config folder when the player
-- turns it on; the bot loads every .lua file there. It hands the bot's state to the module every 10 s and changes
-- nothing in the bot. It works with the stock cavebot, vBot and presets built on them: each value is read only where
-- its function exists, and a missing one stays out of the status.
local VERSION = '1'

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

local adapter = {
  id = 'bot', version = VERSION,
  fields = {
    botConfig = function() return config end,
    routeOn = function() return onOff(CaveBot) end,
    route = function() local get = fn(CaveBot, 'getCurrentProfile'); return (get and get()) or selected('cavebot_configs') end,
    routes = routes,
    label = label,
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
