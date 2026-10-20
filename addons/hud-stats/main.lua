-- HUD stats, a Voidwatch addon, MIT licence. A Stats window beside the game: exp per hour, time to the next level,
-- damage, healing, mana and damage taken per second, and kills, each with a 15-minute graph. Records are kept per
-- character in the Voidwatch data folder.
local EXP_WINDOW = 15 * 60
local EXP_SAMPLE_GAP = 5
local HIT_WINDOW = 10
local KILLS_WINDOW = 60 * 60
local GRAPH_POINTS = 15 * 60
local MIN_DIVISOR = 60          -- a fresh window can only undershoot, never inflate
local RECORD_AFTER = 5 * 60     -- a quest reward right after login must not become an exp/h record
local RATE_WAIT = 6
local KILL_MEMORY = 10
local SAVE_EVERY = 30
local MAX_HITS = 2000
local SECTION_SPACING = 6
local THEMES = { r = '#ff5555', g = '#55ff55', b = '#5599ff', c = '#55ffff', m = '#ff55ff', y = '#ffdd55' }
local DEFAULT_THEME = '#ffdd55'
local DAMAGE_TAKEN = { 'You lose (%d+) hitpoints? due to', 'You lose (%d+) mana due to', 'You lose (%d+) mana blocking' }
local DAMAGE_DEALT = '^(.-) loses (%d+) hitpoints? due to your attack'
local RATE_REPLY = '[Ee]xp[%a ]-[Rr]ate%s*:?%s*x?([%d%.]+)'
local HELP = 'Section headers:\n  left click - collapse or expand the section\n  right click - show or hide its graph\n\n'
  .. 'Graphs button: all graphs on or off\nColour dots: the colour of the headers and the graph lines\n'
  .. 'Graph corners: the highest (top) and lowest (bottom) value shown'

local METRICS = {
  { key = 'exp', title = 'Exp/H' }, { key = 'raw', title = 'Raw Exp/H (x1)' }, { key = 'dps', title = 'DPS' },
  { key = 'hps', title = 'HPS' }, { key = 'mps', title = 'MPS' }, { key = 'drps', title = 'Dmg Received/s' },
}

local window, contents, graphsButton, box, saved, who, s
local rows, sections, graphs, headers = {}, {}, {}, {}
local value = {}
local extra = { expLeft = 0, eta = nil, killsPerHour = 0 }
local lastSaveAt, dirty = -math.huge, false

local function now() return g_clock.millis() / 1000 end

local function fmtBig(n)
  if n >= 1e9 then return ('%.2fB'):format(n / 1e9) end
  if n >= 1e6 then return ('%.2fM'):format(n / 1e6) end
  if n >= 1e3 then return ('%.1fK'):format(n / 1e3) end
  return tostring(math.floor(n))
end

local function fmtDuration(sec)
  if sec >= 86400 then return ('%dd %dh'):format(sec / 86400, (sec % 86400) / 3600) end
  if sec >= 3600 then return ('%dh %02dm'):format(sec / 3600, (sec % 3600) / 60) end
  return ('%dm %02ds'):format(sec / 60, sec % 60)
end

local function expForLevel(level)
  local skills = modules.game_skills
  if skills and skills.expForLevel then return skills.expForLevel(level) end
  return math.floor((50 * level * level * level) / 3 - 100 * level * level + (850 * level) / 3 - 200)
end

local function newSession()
  local hits = {}
  for _, m in ipairs(METRICS) do hits[m.key] = {} end
  return { samples = {}, hits = hits, max = {}, kills = {}, killsSession = 0, start = now(), rawCum = 0, pending = 0,
           attacked = {}, dealt = {}, deaths = {} }
end

local function setting(key) return Addon.setting and Addon.setting(key) end

-- TFS 1.x: 39 h and more give 150% to premium accounts, under 14 h 50%. Off by default: many servers differ.
local function staminaFactor()
  if setting('stamina') ~= true then return 1 end
  local p = g_game.getLocalPlayer()
  local st = p and p:getStamina() or 0
  if st <= 0 then return 1 end
  if st >= 2340 then return (p.isPremium and not p:isPremium()) and 1 or 1.5 end
  return st >= 840 and 1 or 0.5
end

local function multiplier() return (s.rate or 1) * staminaFactor() end

local function trim(list, cutoff)
  local drop = 0
  while list[drop + 1] and list[drop + 1][1] < cutoff do drop = drop + 1 end
  drop = math.max(drop, #list - MAX_HITS)
  if drop > 0 then
    for i = 1, #list - drop do list[i] = list[i + drop] end
    for i = #list - drop + 1, #list do list[i] = nil end
  end
end

local function addHit(key, amount)
  local list = s.hits[key]
  list[#list + 1] = { now(), amount }
  trim(list, now() - HIT_WINDOW)
end

local function forget(map, cutoff)
  for k, t in pairs(map) do
    if t < cutoff then map[k] = nil end
  end
end

local function creatureName(name) return (name or ''):lower():gsub('^an? ', ''):gsub('^the ', '') end

local function save(force)
  if not who or not saved then return end
  if not force and now() - lastSaveAt < SAVE_EVERY then
    dirty = true
    return
  end
  Addon.save(saved)
  lastSaveAt, dirty = now(), false
end

local function loadState()
  local t = Addon.load() or {}
  t.life = type(t.life) == 'table' and t.life or {}
  for _, m in ipairs(METRICS) do t.life[m.key] = tonumber(t.life[m.key]) or 0 end
  t.killsTotal = tonumber(t.killsTotal) or 0
  t.sections = type(t.sections) == 'table' and t.sections or {}
  local known = false
  for _, hex in pairs(THEMES) do known = known or hex == t.theme end
  t.theme = known and t.theme or DEFAULT_THEME
  t.graphs = t.graphs ~= false
  t.open = t.open ~= false
  saved = t
end

local function askRate()
  if setting('rate') ~= true then return end
  local cmd = tostring(setting('rateCommand') or ''):gsub('[\r\n]', ''):match('^%s*(.-)%s*$')
  if cmd == '' or #cmd > 40 or not g_game.isOnline() then return end
  g_game.talk(cmd)
  s.askedAt = now()
  s.awaitUntil = now() + RATE_WAIT
end

local function settlePending(rate)
  s.rawCum = s.rawCum + s.pending / ((rate or s.rate or 1) * staminaFactor())
  s.pending, s.awaitUntil = 0, nil
end


local function headerText(sec) return sec.show and ('-- ' .. sec.title .. ' --') or ('+ ' .. sec.title .. ' +') end

local function applySections()
  for _, sec in pairs(sections) do
    sec.header:setText(headerText(sec))
    for _, row in ipairs(sec.rows) do row:setVisible(sec.show) end
    if sec.graph then sec.graph.widget:setVisible(saved.graphs and sec.show and sec.graphShown) end
  end
  if graphsButton then graphsButton:setText(saved.graphs and 'Hide graphs' or 'Show graphs') end
end

local function contentHeight()
  local h = 4
  for _, child in ipairs(contents:getChildren()) do
    if child:isExplicitlyVisible() then h = h + child:getHeight() + child:getMarginTop() + child:getMarginBottom() end
  end
  return h
end

-- the size is set once before the window shows; later only a collapsed or opened section changes it
local function fit(first)
  local h = contentHeight()
  local full = not first and window:getHeight() >= window:getMaximumHeight()
  window:setContentMinimumHeight(math.min(60, h))
  window:setContentMaximumHeight(h)
  if first or full then window:setContentHeight(h) end
end

local function rememberSections()
  for key, sec in pairs(sections) do saved.sections[key] = { show = sec.show, graph = sec.graphShown } end
  save(true)
end

local function addSection(key, title)
  local label = g_ui.createWidget('HudStatsHeader', contents)
  label:setMarginTop(SECTION_SPACING)
  label:setColor(saved.theme)
  local sec = { key = key, title = title, header = label, rows = {}, show = true, graphShown = true }
  sections[key] = sec
  headers[#headers + 1] = label
  label.onClick = function()
    sec.show = not sec.show
    applySections()
    fit()
    rememberSections()
  end
  label.onMouseRelease = function(_, _, mouseButton)
    if mouseButton ~= (MouseRightButton or 2) then return false end
    sec.graphShown = not sec.graphShown
    applySections()
    fit()
    rememberSections()
    return true
  end
  return sec
end

local function addRow(sec, name)
  local row = g_ui.createWidget('HudStatsRow', contents)
  row.name:setText(name)
  sec.rows[#sec.rows + 1] = row
  return row.value
end

local function addGraph(sec)
  local g = g_ui.createWidget('HudStatsGraph', contents)
  g:setCapacity(GRAPH_POINTS)
  pcall(function() g:setShowLabels(false) end)
  g:setColor(saved.theme)
  g:addValue(0)
  local top = g_ui.createWidget('HudStatsGraphLabel', g)
  top:addAnchor(AnchorTop, 'parent', AnchorTop)
  top:addAnchor(AnchorRight, 'parent', AnchorRight)
  local low = g_ui.createWidget('HudStatsGraphLabel', g)
  low:addAnchor(AnchorBottom, 'parent', AnchorBottom)
  low:addAnchor(AnchorRight, 'parent', AnchorRight)
  sec.graph = { widget = g, ring = {}, head = 0, n = 0, sum = 0, count = 0, top = top, low = low }
  graphs[sec.key] = sec.graph
end

local function clearGraphs()
  for _, gr in pairs(graphs) do
    gr.widget:clear()
    gr.widget:addValue(0)
    gr.ring, gr.head, gr.n, gr.sum, gr.count = {}, 0, 0, 0, 0
    gr.top:setText('')
    gr.low:setText('')
  end
end

-- UIGraph draws one value per pixel column, so 15 minutes fit only as averages of a few seconds each
local function feed(key, v)
  local gr = graphs[key]
  local step = math.max(1, math.ceil(GRAPH_POINTS / math.max(60, gr.widget:getWidth() - 8)))
  gr.sum, gr.count = gr.sum + v, gr.count + 1
  if gr.count >= step then
    gr.widget:addValue(math.floor(gr.sum / gr.count + 0.5))
    gr.sum, gr.count = 0, 0
  end
  gr.head = gr.head % GRAPH_POINTS + 1
  gr.ring[gr.head] = v
  gr.n = math.min(gr.n + 1, GRAPH_POINTS)
  local lo, hi = v, v
  for i = 1, gr.n do
    local x = gr.ring[i]
    if x < lo then lo = x end
    if x > hi then hi = x end
  end
  gr.top:setText(fmtBig(hi))
  gr.low:setText(fmtBig(lo))
end

local function refresh()
  if not window then return end
  rows.lvlExp:setText(fmtBig(extra.expLeft))
  rows.lvlTime:setText(extra.eta and fmtDuration(extra.eta) or '-')
  local m = ('%.2f'):format(multiplier()):gsub('0+$', ''):gsub('%.$', '')
  sections.exp.title = 'Exp/H (x' .. m .. ')'
  sections.exp.header:setText(headerText(sections.exp))
  for _, metric in ipairs(METRICS) do
    local r = rows[metric.key]
    r.cur:setText(fmtBig(value[metric.key] or 0))
    r.ses:setText(fmtBig(s.max[metric.key] or 0))
    r.life:setText(fmtBig(saved.life[metric.key]))
  end
  rows.killTotal:setText(fmtBig(saved.killsTotal))
  rows.killSession:setText(tostring(s.killsSession))
  rows.killPerH:setText(tostring(math.floor(extra.killsPerHour + 0.5)))
end

local function setTheme(hex)
  saved.theme = hex
  for _, l in ipairs(headers) do l:setColor(hex) end
  for _, gr in pairs(graphs) do gr.widget:setColor(hex) end
  save(true)
end

local function resetSession()
  s = newSession()
  for _, m in ipairs(METRICS) do value[m.key] = 0 end
  extra.killsPerHour, extra.eta = 0, nil
  if window then
    clearGraphs()
    refresh()
  end
end

local function resetLifetime()
  for _, m in ipairs(METRICS) do saved.life[m.key] = 0 end
  saved.killsTotal = 0
  save(true)
  refresh()
end

local function confirmResetLifetime()
  if box and not box:isDestroyed() then
    box:raise()
    box:focus()
    return
  end
  local function close() if box then box:destroy() box = nil end end
  local function yes() resetLifetime() close() end
  box = displayGeneralBox('Reset lifetime stats', 'Clear the lifetime records of this character?\n(all values and the total kills)',
    { { text = 'Yes', callback = yes }, { text = 'No', callback = close } }, yes, close)
end

local function applyState()
  if not window then return end
  for key, sec in pairs(sections) do
    local st = saved.sections[key] or {}
    sec.show, sec.graphShown = st.show ~= false, st.graph ~= false
  end
  for _, l in ipairs(headers) do l:setColor(saved.theme) end
  for _, gr in pairs(graphs) do gr.widget:setColor(saved.theme) end
  applySections()
  fit()
  if saved.open and not window:isVisible() then window:open() elseif not saved.open and window:isVisible() then window:close() end
  refresh()
end

local function setOpen(open)
  local btn = Addon.button('Stats')
  if btn then btn:setOn(open) end
  if saved and saved.open ~= open then
    saved.open = open
    save(true)
  end
end

local function toggle()
  if window:isVisible() then window:close() else window:open() end
end

local function buildWindow()
  Addon.style('hudstats.otui')
  local gi = modules.game_interface
  local root = gi and gi.getRootPanel and gi.getRootPanel()
  local parent = root and root:recursiveGetChildById('leftPanel2') or (gi and gi.getLeftPanel and gi.getLeftPanel()) or rootWidget
  window = Addon.ui('HudStatsWindow', parent)
  if not window then return end
  contents = window:getChildById('contentsPanel')
  local lvl = addSection('lvl', 'Next Level')
  rows.lvlExp = addRow(lvl, 'Exp:')
  rows.lvlTime = addRow(lvl, 'Time:')
  for _, metric in ipairs(METRICS) do
    local sec = addSection(metric.key, metric.title)
    rows[metric.key] = { cur = addRow(sec, 'Current:'), ses = addRow(sec, 'Max session:'), life = addRow(sec, 'Max lifetime:') }
    addGraph(sec)
  end
  local kills = addSection('kills', 'Kills')
  rows.killTotal = addRow(kills, 'Total:')
  rows.killSession = addRow(kills, 'Session:')
  rows.killPerH = addRow(kills, 'Per H:')
  addGraph(kills)
  local buttons = g_ui.createWidget('HudStatsButtons', contents)
  graphsButton = buttons.graphs
  graphsButton.onClick = function()
    saved.graphs = not saved.graphs
    applySections()
    fit()
    save(true)
  end
  buttons.resetSession.onClick = resetSession
  buttons.resetLifetime.onClick = confirmResetLifetime
  local picker = g_ui.createWidget('HudStatsPicker', contents)
  for key, hex in pairs(THEMES) do
    local dot = picker.dots[key]
    dot:setImageSource(Addon.dir .. 'hud_color_dot.png')
    dot:setImageColor(hex)
    dot.onClick = function() setTheme(hex) end
  end
  picker.help:setTooltip(HELP)
  window.onOpen = function() setOpen(true) end
  window.onClose = function() setOpen(false) end
  pcall(function() window:setup() end)
  Addon.button('Stats', nil, toggle)
  applySections()
  fit(true)
end


local function recordKill()
  local list = s.kills
  list[#list + 1] = now()
  while list[1] and list[1] < now() - KILLS_WINDOW do table.remove(list, 1) end
  s.killsSession = s.killsSession + 1
  saved.killsTotal = saved.killsTotal + 1
  save(false)
end

local function attackedId()
  local t = g_game.getAttackingCreature and g_game.getAttackingCreature()
  return t and t:getId()
end

-- only what you kill: your target, or a creature your attacks hit in the last 10 s
local function onCreatureHealth(creature, percent)
  if percent > 0 or not s or not (creature.isMonster and creature:isMonster()) then return end
  local id, t = creature:getId(), now()
  if s.deaths[id] then return end
  s.deaths[id] = t
  local hit = s.dealt[creatureName(creature:getName())]
  if attackedId() == id or (s.attacked[id] and t - s.attacked[id] <= KILL_MEMORY) or (hit and t - hit <= KILL_MEMORY) then
    recordKill()
  end
end

local function onHealthChange(_, health, maxHealth)
  if not s then return end
  if s.lastHealth and s.lastMaxHealth == maxHealth and health > s.lastHealth then addHit('hps', health - s.lastHealth) end
  s.lastHealth, s.lastMaxHealth = health, maxHealth
end

local function onManaChange(_, mana, maxMana)
  if not s then return end
  if s.lastMana and s.lastMaxMana == maxMana and mana > s.lastMana then addHit('mps', mana - s.lastMana) end
  s.lastMana, s.lastMaxMana = mana, maxMana
end

local function onMessage(mode, text)
  if not s or type(text) ~= 'string' then return end
  for _, pattern in ipairs(DAMAGE_TAKEN) do
    local n = text:match(pattern)
    if n then return addHit('drps', tonumber(n)) end
  end
  local name, dmg = text:match(DAMAGE_DEALT)
  if dmg then
    addHit('dps', tonumber(dmg))
    s.dealt[creatureName(name)] = now()
    return
  end
  -- the rate counts only as the answer to our own question, never from a broadcast or a look
  if s.askedAt and now() - s.askedAt <= RATE_WAIT and not (MessageModes and mode == MessageModes.GamemasterBroadcast)
    and not text:find('^You see') then
    local rate = tonumber(text:match(RATE_REPLY) or '')
    if rate and rate > 0 and rate < 1e6 then
      s.rate, s.askedAt = rate, nil
      settlePending(rate)
      if window and window:isVisible() then refresh() end
    end
  end
end

local function windowRate(list)
  trim(list, now() - HIT_WINDOW)
  local sum = 0
  for _, hit in ipairs(list) do sum = sum + hit[2] end
  return sum / HIT_WINDOW
end

local function update()
  local player = g_game.getLocalPlayer()
  if not s or not saved or not player or not g_game.isOnline() or g_game.getCharacterName() ~= who then return end
  local expNow, level = player:getExperience(), player:getLevel()
  if expNow <= 0 or level <= 0 then return end
  local t = now()
  if s.lastLevel and level ~= s.lastLevel then askRate() end
  s.lastLevel = level
  local target = attackedId()
  if target then s.attacked[target] = t end
  forget(s.attacked, t - KILL_MEMORY)
  forget(s.dealt, t - KILL_MEMORY)
  forget(s.deaths, t - KILL_MEMORY)

  -- raw exp: each second's gain at the rate in force then, so a stage change never rescales old exp; while the
  -- answer after a level-up is on its way the gain waits
  if s.lastExp and expNow > s.lastExp then
    local delta = expNow - s.lastExp
    if s.awaitUntil and t < s.awaitUntil then
      s.pending = s.pending + delta
    else
      if s.awaitUntil then settlePending() end
      s.rawCum = s.rawCum + delta / multiplier()
    end
  end
  s.lastExp = expNow

  local samples = s.samples
  local last = samples[#samples]
  if not last or t - last[1] >= EXP_SAMPLE_GAP then samples[#samples + 1] = { t, expNow, s.rawCum } end
  while #samples > 2 and samples[1][1] < t - EXP_WINDOW do table.remove(samples, 1) end
  local first = samples[1]
  local dt, gained, rawGained = t - first[1], expNow - first[2], s.rawCum - first[3]
  if gained < 0 then
    s.samples = { { t, expNow, s.rawCum } }
    dt, gained, rawGained = 0, 0, 0
  end
  value.exp = gained / math.max(dt, MIN_DIVISOR) * 3600
  value.raw = (rawGained + s.pending / multiplier()) / math.max(dt, MIN_DIVISOR) * 3600
  for _, key in ipairs({ 'dps', 'hps', 'mps', 'drps' }) do value[key] = windowRate(s.hits[key]) end

  extra.expLeft = math.max(0, expForLevel(level + 1) - expNow)
  extra.eta = value.exp > 0 and (extra.expLeft / value.exp * 3600) or nil
  while s.kills[1] and s.kills[1] < t - KILLS_WINDOW do table.remove(s.kills, 1) end
  extra.killsPerHour = #s.kills / math.max(math.min(t - s.start, KILLS_WINDOW), MIN_DIVISOR) * 3600

  local record = false
  for _, metric in ipairs(METRICS) do
    local key, v = metric.key, value[metric.key]
    s.max[key] = math.max(s.max[key] or 0, v)
    local best = (key == 'exp' or key == 'raw') and (dt >= RECORD_AFTER and v or 0) or s.max[key]
    if best > saved.life[key] then
      saved.life[key] = best
      record = true
    end
  end
  if record or dirty then save(false) end

  if window and window:isVisible() then
    for _, metric in ipairs(METRICS) do feed(metric.key, value[metric.key]) end
    feed('kills', extra.killsPerHour)
    refresh()
  end
end

local function onLogin(name)
  who = name or g_game.getCharacterName()
  loadState()
  resetSession()
  applyState()
  Addon.after(3000, askRate)
end

function init()
  s = newSession()
  saved = { life = {}, killsTotal = 0, sections = {}, theme = DEFAULT_THEME, graphs = true, open = true }
  for _, m in ipairs(METRICS) do saved.life[m.key] = 0 end
  buildWindow()
  Addon.on('login', onLogin)
  Addon.on('logout', function() save(true) end)
  Addon.on('message', onMessage)
  Addon.connect(g_game, { onGameStart = function() if g_game.getCharacterName() == who then resetSession() end end })
  Addon.connect(LocalPlayer, { onHealthChange = onHealthChange, onManaChange = onManaChange })
  Addon.connect(Creature, { onHealthPercentChange = onCreatureHealth })
  Addon.every(1000, update)
  if g_game.isOnline() then onLogin(g_game.getCharacterName()) end
end

function terminate()
  save(true)
  if box then box:destroy() box = nil end
  window, contents, graphsButton, saved, who = nil, nil, nil, nil, nil
  rows, sections, graphs, headers = {}, {}, {}, {}
end
