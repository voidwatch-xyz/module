-- The Voidwatch window: a button in the client's top bar and a window that shows what this client does. The window
-- is built when the button is clicked and destroyed when it closes; only while it is open does it refresh, once a
-- second. It reads Voidwatch.view() and changes nothing but through the actions of the core.
local SITE = 'https://voidwatch.xyz'
local COLOURS = { connected = '#4cd964', pairing = '#f5a623', waiting = '#f5a623', stopped = '#ff5b5b', off = '#ff5b5b', offline = '#777777' }
local GREEN, YELLOW, RED, GREY, FAINT = '#4cd964', '#f5a623', '#ff6b6b', '#777777', '#6f6f6f'
local TABS = { { 'main', 'Main' }, { 'addons', 'Addons' }, { 'settings', 'Settings' } }
local SEND = {
  { 'captures', 'Send screenshots', 'Off: the live view shows the numbers only.' },
  { 'minimap', 'Send my minimap automatically', 'The upload script sends the map files of your client when they change. The website adds them into your own map.' },
  { 'supplyList', "Use the bot's supply list", 'Off: the supply chips show every item from the game\'s "Using one of" lines.' },
  { 'commands', 'Allow commands', 'Off: the client ignores commands from the website.' },
}
local TEAM = {
  { 'exiva', 'Team exiva', 'This character casts exiva when you or your guild ask. Its own exiva in the game starts a team exiva.' },
  { 'exivaShowAll', 'Show every team exiva result', 'Off: only the character that cast first shows the result.' },
  { 'chat', 'Sync private messages', 'Off: private chats stay in the game client.' },
}
local ROLES = { 'hunt', 'refill', 'city', 'resp' }
local WIDTH, HEIGHT, MIN_HEIGHT, SCREEN_GAP, SPACING = 760, 370, 340, 60, 3
local button, dot, win, timer, styled, lastState, site
local pages, tabButtons, shapes, refs = {}, {}, {}, {}
local current = 'main'                                 -- the open tab, kept while the client runs
local detail = nil                                     -- the addon the Addons tab shows
local listScroll = nil                                 -- the addon list's scroll position, put back after a rebuild
local subtab = 'about'                                 -- the part of the addon details that shows
local picIndex = {}                                    -- addon id -> the picture its details show
local form = nil                                       -- the Settings tab while the player edits it
local syncing = false
local render

-- a click that rebuilds a page waits for the next frame: the clicked widget must not go away inside its own event
local function later() addEvent(function() pcall(render) end) end

-- the folder this module sits in: a click runs outside the script, so paths are given in full
local function home()
  for _, dir in ipairs({ Voidwatch.home, '/modules/voidwatch/', '/mods/voidwatch/' }) do
    if dir and g_resources.fileExists(dir .. 'voidwatch.otui') then return dir end
  end
  return Voidwatch.home or '/modules/voidwatch/'
end

local function ago(s)
  if s < 60 then return s .. ' s ago' end
  return math.floor(s / 60) .. ' min ago'
end

local function every(s)
  if not s then return '?' end
  if s < 60 then return s .. ' s' end
  return math.floor(s / 60) .. ' min'
end

local function short(text, n)
  text = tostring(text or '')
  return #text > n and (text:sub(1, n - 3) .. '...') or text
end

local function vnum(v)
  local a, b, c = tostring(v or ''):match('^(%d+)%.(%d+)%.(%d+)')
  return a and (tonumber(a) * 1000000 + tonumber(b) * 1000 + tonumber(c)) or 0
end

local function make(style, parent, text)
  local w = g_ui.createWidget(style, parent)
  if text then w:setText(text) end
  return w
end

local function click(w, fn)
  w.onClick = function() pcall(fn); later() end
end

local function line(parent, key, tooltip)
  local w = make('VwLine', parent)
  w.key:setText(key)
  if tooltip then w:setTooltip(tooltip) end
  return w
end

local function kv(parent, key, tooltip)
  local w = make('VwKV', parent)
  w.key:setText(key)
  if tooltip then w:setTooltip(tooltip) end
  return w
end

local function buttons(parent, a, onA, b, onB)
  local w = make('VwButtons', parent)
  w.a:setText(a)
  click(w.a, onA)
  if b then
    w.b:setText(b)
    click(w.b, onB)
  else
    w.b:hide()
    w.a:removeAnchor(AnchorRight)
    w.a:addAnchor(AnchorRight, 'parent', AnchorRight)
    w.a:setMarginRight(0)
  end
  return w
end

local function contentHeight(body)
  local h, n = body:getPaddingTop() + body:getPaddingBottom(), 0
  for _, w in ipairs(body:getChildren()) do
    if w:isExplicitlyVisible() then
      h, n = h + w:getHeight() + w:getMarginTop() + w:getMarginBottom(), n + 1
    end
  end
  return h + math.max(0, n - 1) * SPACING
end

-- a list shows its scroll bar only while its rows are taller than the list
local function scrollIfNeeded(body, scroll)
  if not (body and scroll) or body:isDestroyed() then return end
  local scrolls = contentHeight(body) > body:getHeight()
  if scroll:isVisible() ~= scrolls then
    scroll:setVisible(scrolls)
    body:setMarginRight(scrolls and (scroll:getWidth() + 4) or 0)
  end
end

local function fitWidths(panel)
  for _, w in ipairs(panel:getChildren()) do w:setWidth(panel:getWidth() - w:getMarginLeft() - w:getMarginRight()) end
end

-- header and update bar -------------------------------------------------------------------------------------------

local STATE_TEXT = { connected = 'Connected to your Voidwatch account', pairing = 'Waiting for pairing', waiting = 'Waiting for the upload script',
                     off = 'Stopped for all clients', offline = 'Not logged in' }

local function fillHeader(v)
  local head = win.top.head
  head.name:setText(v.character or 'Not logged in')
  head.server:setText(v.server or '')
  head.stateDot:setBackgroundColor(COLOURS[v.state] or GREY)
  head.stateText:setColor(COLOURS[v.state] or '#dfdfdf')
  head.stateText:setText(STATE_TEXT[v.state] or ('Stopped: ' .. short(v.stopped, 50)))
  head.stateText:setTooltip(v.state == 'stopped' and tostring(v.stopped) or '')
end

-- only when there is something to do: Update, Reload, an update by hand, one under way, or a failed one
local function barOf(u)
  if not u then return nil end
  if u.asked then return 'Updating Voidwatch. The upload script downloads the new version.' end
  if u.needsReload then return 'The files are version ' .. tostring(u.files) .. '.', 'Reload', Voidwatch.reloadFiles end
  if u.canUpdate then return 'Version ' .. tostring(u.latest) .. ' is out.', 'Update', Voidwatch.update end
  if u.byHand then return 'Version ' .. tostring(u.latest) .. ' is out. Update it by hand from voidwatch.xyz.' end
  if u.error then return 'The update failed: ' .. short(u.error, 80) end
end

-- in the footer beside the version, so the window never has to make room for it
local function fillBar(v)
  local link = win.update
  local text, label, action = barOf(v.update)
  link:setVisible(text ~= nil)
  if text then
    local u = v.update
    link:setText(label and (label .. ' to ' .. tostring(u.needsReload and u.files or u.latest)) or (u.asked and 'Updating...' or u.byHand and
      ('Version ' .. tostring(u.latest) .. ' is out') or 'The update failed'))
    link:setColor(u.error and not label and RED or '#ffdd55')
    link:setTooltip(text)
    link.line:setVisible(label ~= nil)
    link.onClick = label and function() pcall(action); later() end or nil
  end
  local u = v.update
  local back = u and u.canRollback and not u.asked
  win.rollback:setVisible(back and true or false)
  if back then win.rollback:setText('Roll back to ' .. tostring(u.backup)) end
end

-- the number of installed addons, in yellow beside the tab's name, over spaces that make room for it
local function setBadge(n)
  local tab = tabButtons.addons
  if not tab or tab.vwCount == n then return end
  tab.vwCount = n
  if not tab.vwBadge then
    local b = g_ui.createWidget('Label', tab)
    b:setColor('#ffdd55')
    b:setPhantom(true)
    b:setTextAutoResize(true)
    b:addAnchor(AnchorRight, 'parent', AnchorRight)
    b:addAnchor(AnchorVerticalCenter, 'parent', AnchorVerticalCenter)
    b:setMarginRight(tab:getPaddingRight() + 3)
    tab.vwBadge = b
  end
  tab.vwBadge:setText(n > 0 and tostring(n) or '')
  tab:setText(n > 0 and ('Addons' .. string.rep(' ', #tostring(n) + 4)) or 'Addons')
  tab:setWidth(tab:getTextSize().width + tab:getPaddingLeft() + tab:getPaddingRight())
end

-- Main tab --------------------------------------------------------------------------------------------------------

local PHASES = { hunting = 'hunting', to_city = 'to city', in_city = 'in city', to_resp = 'to resp', parked = 'parked',
                 stopped = 'stopped', unknown = 'no route labels', town = 'in town', at_check = 'at check', leaving = 'leaving' }

local PLAN_KINDS = { refill = 'Force refill', go_depot = 'Stop in depot', load_route = 'Switch route' }
local PLAN_ENDS = { done = 'done', stuck = 'stuck', cancelled = 'cancelled', taken_over = 'taken over', failed = 'failed' }

local function planText(pl)
  local what = (PLAN_KINDS[pl.kind] or tostring(pl.kind)) .. (pl.route and (' to ' .. short(pl.route, 14)) or '')
  if pl.state ~= 'running' then return (PLAN_ENDS[pl.state] or tostring(pl.state)) .. ': ' .. short(pl.message, 30) end
  local left = tonumber(pl['until']) and math.max(0, math.ceil((pl['until'] - os.time()) / 60))
  return what .. ' - ' .. tostring(pl.message or '') .. (left and (' (' .. left .. ' min left)') or '')
end

local function mainShape(v)
  return table.concat({ v.state, #v.sources, tostring(v.plan and v.plan.state == 'running') }, '|')
end

local function resetButton(b, r)
  local label = b:getText()
  b.onClick = function()
    -- a second click within 3 s confirms: the counters of this session are gone after it
    if r.resetAsked and g_clock.millis() - r.resetAsked < 3000 then
      r.resetAsked = nil
      b:setText(label)
      pcall(Voidwatch.resetLoot)
    else
      r.resetAsked = g_clock.millis()
      b:setText('Click again to reset')
      scheduleEvent(function()
        if not b:isDestroyed() and r.resetAsked then
          r.resetAsked = nil
          b:setText(label)
        end
      end, 3000)
    end
  end
end

local function buildConnected(page, v, r)
  local m = make('VwMainConnected', page)
  local rows = m.client.rows
  r.upload = kv(rows, 'Upload script')
  r.sending = kv(rows, 'Sending', 'The site sets the pace: faster while someone has the dashboard open.')
  r.route = kv(rows, 'Route', 'Where the character is in its route, from the route labels hunt, refill, city and resp.')
  r.route.info:setImageSource(home() .. 'voidwatch_info')
  r.plan = kv(rows, 'Plan', 'A command that waits for a label of the route: force refill, stop in depot or switch route.')
  if v.plan and v.plan.state == 'running' then buttons(rows, 'Cancel the plan', Voidwatch.cancelPlan) end
  r.memory = kv(rows, 'Memory')
  r.errors = kv(rows, 'Errors')
  r.sourceRows, r.sourceScroll = m.sources.rows, m.sources.scroll
  for i in ipairs(v.sources) do r.sources[i] = make('VwSourceLine', m.sources.rows) end
  resetButton(m.client.reset, r)
  m.client.stop.a:setText('Stop this client')
  m.client.stop.b:setText('Stop all clients')
  m.client.stop.b:setColor('#ff8a8a')
  click(m.client.stop.a, Voidwatch.stopHere)
  click(m.client.stop.b, Voidwatch.stopAll)
  r.lists = { rows, m.sources.rows }
end

local function buildOther(page, v, r)
  local o = make('VwMainOther', page)
  local body = o.card.body
  r.lists = { body }
  r.sourceRows, r.sourceScroll = body, o.card.scroll
  if v.state == 'pairing' then
    r.code = make('VwCode', body)
    r.expires = line(body, 'Code expires')
    local row
    local copied = function(what, text, key, label)
      g_window.setClipboardText(text or '')
      r.copied, r.copiedAt = what, g_clock.millis()
      local b = row and row[key]
      if b then
        local colour = b:getColor()
        b:setText('Copied')
        b:setColor(GREEN)
        scheduleEvent(function()
          if not b:isDestroyed() then
            b:setText(label)
            b:setColor(colour)
          end
        end, 2000)
      end
    end
    row = buttons(body, 'Copy code', function() copied('Code copied.', v.code, 'a', 'Copy code') end,
      'Copy link', function() copied('Link copied.', v.url, 'b', 'Copy link') end)
    buttons(body, 'Open the link', function() if v.url then g_platform.openUrl(v.url) end end)
    r.howto = make('VwText', body)
    make('VwSeparator', body)
    r.upload = line(body, 'Upload script')
    r.memory = line(body, 'Memory')
    buttons(body, 'Stop this client', Voidwatch.stopHere, 'Stop all clients', Voidwatch.stopAll)
  elseif v.state == 'waiting' then
    make('VwText', body, 'The upload script has not answered yet. Run the Voidwatch setup once. If it does not find this '
      .. 'client, give it this folder: ' .. tostring(v.dir))
    r.memory = line(body, 'Memory')
    buttons(body, 'Stop this client', Voidwatch.stopHere, 'Stop all clients', Voidwatch.stopAll)
  elseif v.state == 'stopped' or v.state == 'off' then
    make('VwText', body, v.state == 'off' and 'Every client that shares this folder sends nothing until it starts again.'
      or 'This client sends nothing until it starts again. The game itself is not affected.')
    buttons(body, v.state == 'off' and 'Start all clients again' or 'Start again', Voidwatch.startAgain)
    make('VwSeparator', body)
    r.memory = line(body, 'Memory')
    r.errors = line(body, 'Errors')
  else
    make('VwText', body, 'Log in to see this client.')
  end
end

local function buildMain(page, v)
  page:destroyChildren()
  local r = { sources = {} }
  refs.main = r
  if v.state == 'connected' then buildConnected(page, v, r) else buildOther(page, v, r) end
end

local function fillMain(v)
  local r = refs.main
  if not r then return end
  for _, list in ipairs(r.lists or {}) do fitWidths(list) end
  if r.upload then
    r.upload.value:setText(v.replyS and ('answered ' .. ago(v.replyS)) or (v.answered and 'answers' or 'no answer yet'))
  end
  if r.sending then
    r.sending.value:setText(('status %s, %s'):format(every(v.statusEvery),
      v.captures and ('screenshot ' .. every(v.captureEvery)) or 'no screenshots'))
  end
  if r.route then
    local missing = v.phase == 'unknown' and v.labelsMissing
    local phase = v.phase and not missing and PHASES[v.phase] or nil
    local name = v.routeName and short(v.routeName, 26) or nil
    r.route.value:setText(name and phase and (name .. ' - ' .. phase) or name or phase or 'no bot data')
    r.route.info:setVisible(missing and true or false)
    r.route.info:setTooltip(missing and ('Labels missing: ' .. table.concat(v.labelsMissing, ', ')) or '')
  end
  if r.plan then
    r.plan.value:setText(v.plan and short(planText(v.plan), 40) or 'none')
    r.plan:setTooltip(v.plan and planText(v.plan) or 'A command that waits for a label of the route: force refill, stop in depot or switch route.')
  end
  if r.memory then r.memory.value:setText(('Lua %d MB, client %s MB'):format(v.heapMB, tostring(v.clientMB or '?'))) end
  if r.errors then
    r.errors.value:setText(v.errors > 0 and (v.errors .. ', last: ' .. short(v.lastError, 30)) or 'none')
    r.errors:setTooltip(v.lastError and tostring(v.lastError) or '')
  end
  for i, src in ipairs(v.sources) do
    local w = r.sources[i]
    if w then
      w.dot:setBackgroundColor(src.on and GREEN or GREY)
      local gives = src.gives ~= '' and src.gives or '-'
      w.name:setText(short(src.name, 17))
      w.gives:setText(short(gives, math.max(8, math.floor((w:getWidth() - 117) / 6))))
      w:setTooltip(src.name .. ': ' .. gives)
    end
  end
  if r.code then
    r.code:setText(v.code or '')
    local left = v.expiresAt and (v.expiresAt - os.time()) or nil
    r.expires.value:setText(left and left > 0 and ('in %d:%02d'):format(math.floor(left / 60), left % 60) or 'now; a new code comes')
    r.howto:setText((r.copiedAt and g_clock.millis() - r.copiedAt < 3000) and r.copied
      or ('Open the link and sign in. ' .. tostring(v.character or 'This character') .. ' then joins your account.'))
  end
  scrollIfNeeded(r.sourceRows, r.sourceScroll)
end

-- Addons tab ------------------------------------------------------------------------------------------------------

-- the release's addons with their text, then any the folder has that the release no longer lists
local function addonList(v)
  local out, byId = {}, {}
  for _, a in ipairs(v.addonCatalog or {}) do
    if type(a) == 'table' and type(a.id) == 'string' and not byId[a.id] then
      local e = { id = a.id, name = tostring(a.name or a.id), about = tostring(a.about or ''), points = type(a.points) == 'table' and a.points or {},
                  plan = a.plan, size = tonumber(a.size), latest = a.version, pictures = type(a.pictures) == 'table' and a.pictures or {} }
      byId[a.id] = e
      out[#out + 1] = e
    end
  end
  for _, st in ipairs(v.addons or {}) do
    local e = byId[st.id]
    if not e then
      e = { id = st.id, name = st.id, about = '', points = {}, pictures = {} }
      byId[st.id] = e
      out[#out + 1] = e
    end
    e.st = st
    -- the addon's own addon.json fills what the website does not send
    local info = type(st.info) == 'table' and st.info or {}
    if e.name == e.id and type(info.name) == 'string' then e.name = info.name end
    if e.about == '' and type(info.about) == 'string' then e.about = info.about end
    if #e.points == 0 and type(info.points) == 'table' then e.points = info.points end
    if not e.plan and type(info.plan) == 'string' then e.plan = info.plan end
  end
  for _, e in ipairs(out) do
    e.newer = e.st and e.st.version and e.latest and vnum(e.latest) > vnum(e.st.version) or false
  end
  return out, byId
end

local function addonState(v, e)
  local st = e.st
  if not st then return 'not installed', GREY end
  if v.addonsOff then return 'stopped for all clients', RED end
  if st.here == false then return 'off for this character', FAINT end
  if st.on then return 'runs, ' .. tostring(st.version), GREEN end
  if st.broken then
    if (st.errors or 0) >= 10 then return 'stopped: ' .. st.errors .. ' errors', RED end
    return 'does not load', RED
  end
  if st.error == 'installing' then return 'installing', YELLOW end
  if st.error == 'the download failed' then return 'the download failed', RED end
  return 'stopped', RED
end

-- the addon the details show: the chosen one while it is listed, else the first installed, else the first offered
local function selected(list, byId)
  if detail and byId[detail] then return byId[detail] end
  for _, e in ipairs(list) do if e.st then return e end end
  return list[1]
end

local function addonsShape(v)
  local list, byId = addonList(v)
  local sel = selected(list, byId)
  local parts = { sel and sel.id or '-', tostring(v.addonsOff) }
  for _, e in ipairs(list) do
    local st = e.st or {}
    parts[#parts + 1] = table.concat({ e.id, tostring(e.st ~= nil), tostring(st.here), tostring(st.on), tostring(st.broken), tostring(st.canOpen),
      tostring(e.newer), tostring(#(st.log or {})), tostring(st.error), tostring(st.version), tostring(#e.about), tostring(#(st.settings or {})),
      tostring(#Voidwatch.pictureFiles(e.id)) }, ':')
  end
  return table.concat(parts, '|')
end

local function buildItems(a, v, list, sel)
  local items = a.list.items
  items:destroyChildren()
  local offered = 0
  for _, e in ipairs(list) do
    if e.st then
      local item = make('VwAddonItem', items)
      item.name:setText(e.name)
      item.summary:setText(short(e.about:match('^(.-)[:%.]') or e.about, 22))
      local text, colour = addonState(v, e)
      item.state:setText(text)
      item.state:setColor(colour)
      item.badge:setVisible(e.newer)
      if e.newer then
        item.badge:setText(tostring(e.latest))
        item.badge:setTooltip('A newer version. It comes with the module update.')
      end
      item.here:setChecked(e.st.here ~= false)
      item.here:setEnabled(not v.addonsOff)
      item.here:setTooltip('On for this character')
      item.here.onCheckChange = function(_, on) pcall(Voidwatch.setAddonHere, e.id, on); later() end
      if e == sel then
        item:setBackgroundColor('#ffffff17')
        item:setBorderWidth(1)
        item:setBorderColor('#ffffff21')
      end
      item.onClick = function() detail = e.id; later() end
    end
  end
  for _, e in ipairs(list) do
    if not e.st then
      if offered == 0 then make('VwSub', items, 'Available') end
      offered = offered + 1
      local row = make('VwAddonOffer', items)
      row.name:setText(e.name)
      if e == sel then row:setBackgroundColor('#ffffff17') end
      row.onClick = function() detail = e.id; later() end
      click(row.install, function() Voidwatch.installAddon(e.id) end)
    end
  end
  if #list == 0 then make('VwText', items, 'No addons yet.') end
  a.list.stopAll:setText(v.addonsOff and 'Start all addons' or 'Stop all addons')
  click(a.list.stopAll, v.addonsOff and Voidwatch.startAddons or Voidwatch.stopAddons)
  a.list.website.onClick = function() g_platform.openUrl((site or SITE) .. '/dashboard/addons') end
end

-- the website's caption for one picture file, matched by its name
local function captionOf(e, file)
  for _, p in ipairs(e.pictures or {}) do
    if type(p) == 'table' and tostring(p.src or ''):sub(-#file - 1) == '/' .. file then return tostring(p.caption or '') end
  end
  return ''
end

local function openPicture(e, files, i)
  if refs.picWin and not refs.picWin:isDestroyed() then refs.picWin:destroy() end
  local w = g_ui.createWidget('VwPictureWindow', rootWidget)
  refs.picWin = w
  w:setText(e.name)
  local function show(k)
    i = (k - 1) % #files + 1
    w.frame.img:setImageSource(Voidwatch.picturePath(e.id, files[i]))
    w.caption:setText(captionOf(e, files[i]))
    w.count:setText(i .. ' / ' .. #files)
  end
  for key, step in pairs({ prev = -1, next = 1 }) do
    w.frame[key]:setText(step < 0 and '<' or '>')
    w.frame[key]:setVisible(#files > 1)
    w.frame[key].onClick = function() show(i + step) end
  end
  w.closeButton.onClick = function() w:destroy() end
  w.onEscape = function() w:destroy() end
  show(i)
  w:show()
  w:raise()
  w:focus()
end

-- the picture beside the details, changed in place so the page does not draw again
local function showPicture(d, e, files)
  local has = #files > 0
  local i = math.min(math.max(1, picIndex[e.id] or 1), math.max(1, #files))
  d.pic.img:setVisible(has)
  d.pic.icon:setVisible(not has)
  d.pic.picText:setVisible(not has)
  d.pic.picCount:setText(has and (i .. ' / ' .. #files) or '0 / 0')
  if has then
    d.pic.img:setImageSource(Voidwatch.picturePath(e.id, files[i]))
    d.pic.img:setTooltip(captionOf(e, files[i]))
    d.pic.img.onClick = function() openPicture(e, files, i) end
  end
  for key, step in pairs({ prev = -1, next = 1 }) do
    d.pic[key]:setText(step < 0 and '<' or '>')
    d.pic[key]:setVisible(#files > 1)
    d.pic[key].onClick = function()
      picIndex[e.id] = (i - 1 + step) % #files + 1
      showPicture(d, e, files)
    end
  end
end

local function showSub(d)
  local keys = {}
  for _, tab in ipairs(d.subtabs.tabs or {}) do keys[tab.vwKey] = true end
  if not keys[subtab] then subtab = 'about' end
  d.sub.points:setVisible(subtab == 'about')
  d.sub.settings:setVisible(subtab == 'settings')
  d.sub.log:setVisible(subtab == 'errors' and d.sub.log:getChildCount() > 0)
  d.sub.none:setVisible(subtab == 'errors' and d.sub.log:getChildCount() == 0)
end

local function settingControls(panel, e, list)
  for _, s in ipairs(list) do
    if s.type == 'bool' then
      local box = make('VwCheck', panel, s.label)
      box:setChecked(s.value == true)
      box.onCheckChange = function(_, on) pcall(Voidwatch.setAddonSetting, e.id, s.key, on) end
    elseif s.type == 'number' then
      local row = make('VwNumber', panel)
      row.key:setText(s.label)
      row.unit:setText('')
      pcall(function()
        row.value:setMinimum(s.min or 0)
        row.value:setMaximum(s.max or 1000000)
        row.value:setValue(tonumber(s.value) or s.min or 0)
      end)
      row.value.onValueChange = function(_, n) pcall(Voidwatch.setAddonSetting, e.id, s.key, tonumber(n)) end
    elseif s.type == 'choice' then
      local row = make('VwChoice', panel)
      row.key:setText(s.label)
      pcall(function()
        for _, o in ipairs(s.options or {}) do row.value:addOption(tostring(o)) end
        row.value:setCurrentOption(tostring(s.value))
      end)
      row.value.onOptionChange = function(_, text) pcall(Voidwatch.setAddonSetting, e.id, s.key, text) end
    elseif s.type == 'text' then
      local row = make('VwTextSetting', panel)
      row.key:setText(s.label)
      row.value:setMaxLength(s.maxLength or 40)
      row.value:setText(tostring(s.value or ''))
      row.value.onTextChange = function(_, text) pcall(Voidwatch.setAddonSetting, e.id, s.key, text) end
    end
  end
end

local function buildDetail(a, v, e)
  local card = a.detail
  card:destroyChildren()
  if not e then
    make('VwText', card, 'No addons yet. They come with the module updates.')
    return
  end
  local d = make('VwAddonDetail', card)
  d.pic.icon:setImageSource(home() .. 'voidwatch_picture')
  local st = e.st
  d.name:setText(e.name)
  local text, colour = addonState(v, e)
  d.state:setText(text)
  d.state:setColor(colour)
  d.about:setText(e.about ~= '' and e.about or 'No description yet.')
  local meta = {}
  if e.plan then meta[#meta + 1] = (tostring(e.plan):gsub('^%l', string.upper)) .. ' plan' end
  if e.size then meta[#meta + 1] = math.max(1, math.floor(e.size / 1024 + 0.5)) .. ' KB' end
  if st then meta[#meta + 1] = st.here == false and 'off for this character' or 'on for this character' end
  if e.newer then meta[#meta + 1] = 'version ' .. tostring(e.latest) .. ' comes with the module update' end
  d.meta:setText(table.concat(meta, '  -  '))
  local actions = {}
  if not st then
    actions[#actions + 1] = { 'Install', function() Voidwatch.installAddon(e.id) end }
  elseif st.here ~= false then
    local function restart()
      local ok = Voidwatch.reloadAddon(e.id)
      pcall(function() modules.game_textmessage.displayGameMessage('[Voidwatch] ' .. e.name .. (ok and ' reloaded.' or ' did not start: see Errors.')) end)
    end
    if st.broken then
      actions[#actions + 1] = { 'Start again', restart }
    elseif st.on then
      actions[#actions + 1] = { 'Reload', restart }
    end
    if st.canOpen then
      local label = st.openLabel and #st.openLabel <= 14 and st.openLabel or 'Open window'
      actions[#actions + 1] = { label, function() Voidwatch.openAddon(e.id) end }
    end
  end
  for i, key in ipairs({ 'a', 'b' }) do
    local b, act = d.bar[key], actions[i]
    b:setVisible(act ~= nil)
    if act then
      b:setText(act[1])
      click(b, act[2])
    end
  end
  d.bar.remove:setVisible(st ~= nil)
  click(d.bar.remove, function() Voidwatch.removeAddon(e.id) end)
  -- the folder's picture files; the website lists the ones it has, and the upload script brings the missing ones
  if #e.pictures > 0 then pcall(Voidwatch.wantPictures, e.id, e.pictures) end
  showPicture(d, e, Voidwatch.pictureFiles(e.id))
  for i, p in ipairs(e.points) do
    local w = make('VwPoint', i % 2 == 1 and d.sub.points.colA or d.sub.points.colB)
    w.vwText = tostring(p)
    w:setTooltip(w.vwText)
  end
  local settings = st and st.settings or {}
  settingControls(d.sub.settings, e, settings)
  local log = st and st.log or {}
  for _, item in ipairs(log) do
    local l = make('VwLogLine', d.sub.log, os.date('%H:%M:%S', item.at) .. '   ' .. short(item.text, 90))
    l:setTooltip(tostring(item.text))
  end
  d.sub.none:setText('No errors since the addon started.')
  local tabs = { { 'about', 'About' } }
  if #settings > 0 then tabs[#tabs + 1] = { 'settings', 'Settings' } end
  if st then tabs[#tabs + 1] = { 'errors', 'Errors ' .. #log } end
  for _, t in ipairs(tabs) do
    local tab = d.subtabs:addTab(t[2], g_ui.createWidget('UIWidget'))
    tab.vwKey = t[1]
    if t[1] == subtab then d.subtabs:selectTab(tab) end
  end
  d.subtabs.onTabChange = function(_, tab)
    subtab = tab.vwKey or 'about'
    showSub(d)
  end
  showSub(d)
  refs.detail = d
end

local function buildAddons(page, v)
  local a = refs.addonsPage
  local list, byId = addonList(v)
  local sel = selected(list, byId)
  detail = sel and sel.id or nil
  local at = tonumber(a.list.itemsScroll:getValue()) or 0
  listScroll = at > 0 and { value = at, fills = 0 } or nil
  buildItems(a, v, list, sel)
  buildDetail(a, v, sel)
end

-- the two columns of points get their width from the card, and each point is cut to it
local function fillAddons()
  local a = refs.addonsPage
  if not a then return end
  fitWidths(a.list.items)
  scrollIfNeeded(a.list.items, a.list.itemsScroll)
  -- the rebuilt list is laid out only after the first fill, so its old position fits from the second one on
  if listScroll then
    local bar = a.list.itemsScroll
    listScroll.fills = listScroll.fills + 1
    if listScroll.fills >= 2 and bar:getMaximum() > 0 then
      bar:setValue(math.min(listScroll.value, bar:getMaximum()))
      listScroll = nil
    elseif listScroll.fills >= 4 then
      listScroll = nil
    end
  end
  local d = refs.detail
  if not d or d:isDestroyed() then return end
  local colW = math.floor((a.detail:getWidth() - a.detail:getPaddingLeft() - a.detail:getPaddingRight() - 14) / 2)
  if colW <= 0 then return end
  for _, col in ipairs({ d.sub.points.colA, d.sub.points.colB }) do
    for _, w in ipairs(col:getChildren()) do
      w:setWidth(colW)
      w.text:setWidth(colW - 10)
      w.text:setText(short(w.vwText, math.floor((colW - 10) / 6)))
    end
  end
  fitWidths(d.sub.settings)
end

-- Settings tab ----------------------------------------------------------------------------------------------------

local function formFrom(v)
  local f = { values = {}, changed = {} }
  for k, val in pairs(v.settings or {}) do f.values[k] = val end
  local labels = {}
  for _, role in ipairs(ROLES) do labels[role] = type(f.values.labels) == 'table' and f.values.labels[role] or '' end
  f.values.labels = labels
  return f
end

local function dirty() return form ~= nil and next(form.changed) ~= nil end

local function syncForm()
  local r = refs.settings
  if not (r and form) then return end
  syncing = true
  for key, box in pairs(r.checks) do box:setChecked(form.values[key] == true) end
  pcall(function() r.wait.value:setValue(tonumber(form.values.planWait) or 20) end)
  for role, edit in pairs(r.labels) do
    if edit:getText() ~= form.values.labels[role] then edit:setText(form.values.labels[role] or '') end
  end
  syncing = false
end

local function setValue(key, value)
  if syncing or not form then return end
  form.values[key] = value
  form.changed[key] = true
  render()
end

local function settingsShape(v)
  return v.state == 'connected' and 'form' or 'unpaired'
end

-- the form is built once with the window; only whether it shows changes with the state
local function makeSettings(page)
  local s = make('VwSettingsPage', page)
  local r = { root = s, checks = {}, labels = {} }
  for _, group in ipairs({ { SEND, s.send.rows }, { TEAM, s.team.rows } }) do
    for _, item in ipairs(group[1]) do
      local key = item[1]
      local box = make('VwCheck', group[2], item[2])
      box:setTooltip(item[3])
      box.onCheckChange = function(_, on) setValue(key, on) end
      r.checks[key] = box
    end
  end
  r.wait = make('VwNumber', s.team.rows)
  r.wait:setMarginTop(2)
  r.wait.key:setText('Plan wait limit')
  r.wait.unit:setText('minutes')
  r.wait:setTooltip('A plan step that waits longer stops as stuck. A big respawn with a long hunt loop may need more.')
  r.wait.value.onValueChange = function(_, n) setValue('planWait', tonumber(n)) end
  r.fields = {}
  local hint = 'The label names your routes use for each part, as a comma list. Empty: the standard name.'
  s.labels.title:setTooltip(hint)
  for _, role in ipairs(ROLES) do
    local f = make('VwLabelField', s.labels.row)
    f.key:setText(role)
    f:setTooltip(hint)
    f.edit.onTextChange = function(_, text)
      if syncing or not form then return end
      form.values.labels[role] = text
      setValue('labels', form.values.labels)
    end
    r.labels[role] = f.edit
    r.fields[#r.fields + 1] = f
  end
  s.bottom.save.onClick = function()
    if not form then return end
    local out = {}
    for k in pairs(form.changed) do out[k] = form.values[k] end
    if Voidwatch.saveSettings(out) then form.changed = {} end
    render()
  end
  s.bottom.undo.onClick = function()
    local ok, now = pcall(Voidwatch.view)
    if ok and type(now) == 'table' then form = formFrom(now) end
    syncForm()
    render()
  end
  refs.settings = r
end

local function buildSettings(page, v)
  local r = refs.settings
  local on = v.state == 'connected'
  for _, id in ipairs({ 'send', 'team', 'labels', 'bottom' }) do r.root[id]:setVisible(on) end
  r.root.unpaired:setVisible(not on)
  if on and not dirty() then form = formFrom(v) end
  if not on then form = nil end
  syncForm()
end

local function fillSettings(v)
  local r = refs.settings
  if not (r and form) then return end
  for _, rows in ipairs({ r.root.send.rows, r.root.team.rows }) do fitWidths(rows) end
  local fieldW = math.max(60, math.floor((r.root.labels.row:getWidth() - 3 * 12) / 4))
  for _, f in ipairs(r.fields) do f:setWidth(fieldW) end
  if not dirty() then
    form = formFrom(v)
    syncForm()
  end
  local status = r.root.bottom.status
  r.root.bottom.save:setEnabled(dirty())
  r.root.bottom.undo:setEnabled(dirty())
  local saved = v.settingsSaved
  local text, colour, tip = 'The same settings as the Clients page on voidwatch.xyz', FAINT, 'Save sends a change to the website.'
  if dirty() then
    text = 'Changes not saved yet'
  elseif v.settingsPending then
    text, colour, tip = 'Saving on voidwatch.xyz...', YELLOW, 'The upload script sends it with the next status, within 30 seconds. This client uses it already.'
  elseif saved and saved.ok then
    text, colour = 'Saved on voidwatch.xyz ' .. ago(saved.ago or 0), GREEN
  elseif saved then
    text, colour, tip = 'Not saved: ' .. short(saved.error, 60), RED, tostring(saved.error or '')
  end
  status.dot:setVisible(colour ~= FAINT)
  status.dot:setBackgroundColor(colour)
  status.text:setColor(colour)
  status.text:setText(text)
  status:setTooltip(tip)
end

-- pages -----------------------------------------------------------------------------------------------------------

local SHAPE = { main = mainShape, addons = addonsShape, settings = settingsShape }
local BUILD = { main = buildMain, addons = buildAddons, settings = buildSettings }
local FILL = { main = fillMain, addons = fillAddons, settings = fillSettings }

-- new rows get their width only after a frame, so a rebuilt page waits unseen until it is filled again at that width
local function settle(key)
  local page = pages[key]
  page:setOpacity(0)
  addEvent(function()
    if not win or page:isDestroyed() then return end
    local ok, v = pcall(Voidwatch.view)
    if ok and type(v) == 'table' then FILL[key](v) end
    page:setOpacity(1)
  end)
end

local function show()
  for key, page in pairs(pages) do page:setVisible(key == current) end
end

-- every tab stays built and filled, so a tab change only shows another page
function render()
  if not win then return end
  local ok, v = pcall(Voidwatch.view)
  if not ok or type(v) ~= 'table' then return end
  if v.url then site = v.url:match('^(https?://[^/]+)') or site end
  fillHeader(v)
  fillBar(v)
  setBadge(#(v.addons or {}))
  for _, t in ipairs(TABS) do
    local key = t[1]
    local shape = SHAPE[key](v)
    if shape ~= shapes[key] then
      shapes[key] = shape
      BUILD[key](pages[key], v)
      FILL[key](v)
      settle(key)
    else
      FILL[key](v)
    end
  end
end

local function refresh()
  if timer then removeEvent(timer) end
  timer = nil
  if not win then return end
  pcall(render)
  timer = scheduleEvent(refresh, 1000)
end

local function close()
  if timer then removeEvent(timer) end
  if refs.picWin and not refs.picWin:isDestroyed() then refs.picWin:destroy() end
  timer, refs, shapes, pages, tabButtons, form = nil, {}, {}, {}, {}, nil
  if win then win:destroy() end
  win = nil
  if button then button:setOn(false) end
end

local function open()
  if not styled then
    g_ui.importStyle(home() .. 'voidwatch.otui')
    styled = true
  end
  win = g_ui.createWidget('VoidwatchWindow', rootWidget)
  win:setOpacity(0)
  -- one size from the start, never changed while the window is open
  win:setSize({ width = WIDTH, height = math.max(MIN_HEIGHT, math.min(HEIGHT, rootWidget:getHeight() - SCREEN_GAP)) })
  win.onEscape = close
  win.closeButton.onClick = close
  win.dashboardButton.onClick = function() g_platform.openUrl((site or SITE) .. '/dashboard') end
  win.rollback.onClick = function() pcall(Voidwatch.rollback); later() end
  -- the pages stay in the content panel and only change visibility; the tab bar moves no panels
  for _, t in ipairs(TABS) do
    pages[t[1]] = g_ui.createWidget('VwPage', win.content)
    local tab = win.tabs:addTab(t[2], g_ui.createWidget('UIWidget'))
    tab.vwKey = t[1]
    tabButtons[t[1]] = tab
  end
  refs.addonsPage = make('VwAddonsPage', pages.addons)
  makeSettings(pages.settings)
  win.tabs:selectTab(tabButtons[current])
  win.tabs.onTabChange = function(_, tab)
    current = tab.vwKey or 'main'
    show()
  end
  local ok, v = pcall(Voidwatch.view)
  win.version:setText('v' .. tostring(ok and v.version or '?'))
  if button then button:setOn(true) end
  refresh()
  win:show()
  win:raise()
  win:focus()
  -- unseen for one frame, until every page is filled again at its width
  addEvent(function()
    if not win then return end
    pcall(render)
    show()
    win:setOpacity(1)
  end)
end

local function toggle()
  if win then close() else open() end
end

local function changed()
  if not dot then return end
  local state = Voidwatch.state()
  if state ~= lastState then
    lastState = state
    if win then pcall(render) end
    dot:setBackgroundColor(COLOURS[state] or GREY)
    button:setTooltip('Voidwatch: ' .. (({ connected = 'connected', pairing = 'waiting for pairing', waiting = 'waiting for the upload script',
      stopped = 'stopped', off = 'stopped for all clients', offline = 'not logged in' })[state] or state))
  end
end

Voidwatch.ui = {
  init = function()
    local tm = modules.client_topmenu
    if not tm or not tm.addRightGameToggleButton then return end
    button = tm.addRightGameToggleButton('voidwatchButton', 'Voidwatch', home() .. 'voidwatch_button', toggle, false, 900)
    button:setOn(false)
    dot = g_ui.createWidget('UIWidget', button)
    dot:setSize({ width = 6, height = 6 })
    dot:addAnchor(AnchorRight, 'parent', AnchorRight)
    dot:addAnchor(AnchorBottom, 'parent', AnchorBottom)
    dot:setMarginRight(2)
    dot:setMarginBottom(2)
    dot:setBorderWidth(1)
    dot:setBorderColor('#000000')
    dot:setPhantom(true)
    lastState = nil
    changed()
    local ok, again = pcall(g_settings.getBoolean, 'voidwatch-reopen')
    if ok and again then
      pcall(g_settings.remove, 'voidwatch-reopen')
      open()
    end
  end,
  terminate = function()
    close()
    if button then button:destroy() end
    button, dot, lastState = nil, nil, nil
  end,
  changed = changed,
  close = close,
  toggle = toggle,
  isOpen = function() return win ~= nil end,
}
