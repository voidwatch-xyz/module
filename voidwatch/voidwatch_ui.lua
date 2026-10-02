-- The Voidwatch window: a button in the client's top bar and a window that shows what this client does. The window
-- is built when the button is clicked and destroyed when it closes; only while it is open does it refresh, once a
-- second. It reads Voidwatch.view() and changes nothing but through the three actions of the core.
local SITE = 'https://voidwatch.xyz'
local COLOURS = { connected = '#4cd964', pairing = '#f5a623', waiting = '#f5a623', stopped = '#ff5b5b', off = '#ff5b5b', offline = '#777777' }
local button, dot, win, refs, shape, timer, styled, lastState, site

-- the folder this module sits in: a click runs outside the script, so paths are given in full
local function home()
  for _, dir in ipairs({ '/modules/voidwatch/', '/mods/voidwatch/' }) do
    if g_resources.fileExists(dir .. 'voidwatch.otui') then return dir end
  end
  return '/modules/voidwatch/'
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

local function make(style, parent, text)
  local w = g_ui.createWidget(style, parent)
  if text then w:setText(text) end
  return w
end

local function line(parent, key, tooltip)
  local w = make('VwLine', parent)
  w.key:setText(key)
  if tooltip then w:setTooltip(tooltip) end
  return w
end

local function buttons(parent, a, onA, b, onB)
  local w = make('VwButtons', parent)
  w.a:setText(a)
  w.a.onClick = function() pcall(onA) end
  if b then
    w.b:setText(b)
    w.b.onClick = function() pcall(onB) end
  else
    w.b:hide()
    w.a:removeAnchor(AnchorRight)
    w.a:addAnchor(AnchorRight, 'parent', AnchorRight)
    w.a:setMarginRight(0)
  end
  return w
end

local function stopButtons(parent)
  local w = buttons(parent, 'Stop this client', Voidwatch.stopHere, 'Stop all clients', Voidwatch.stopAll)
  w.b:setColor('#ff7a7a')
  return w
end

-- the parts that only change when the state does are built once; the numbers are filled in every second
local function build(v)
  local body = win.body
  body:destroyChildren()
  refs = { sources = {} }
  refs.who = make('VwWho', body)
  refs.state = make('VwState', body)
  if v.state == 'connected' then
    refs.upload = line(body, 'Upload script')
    refs.sending = line(body, 'Sending', 'The site sets the pace: faster while someone has the dashboard open.')
    refs.memory = line(body, 'Memory')
    refs.errors = line(body, 'Errors')
    stopButtons(body)
    make('VwSeparator', body)
    make('VwHead', body, 'Data sources')
    for i in ipairs(v.sources) do refs.sources[i] = make('VwSource', body) end
    make('VwSeparator', body)
    make('VwHead', body, 'Set on the dashboard')
    refs.captures = line(body, 'Screenshots')
    refs.supplies = line(body, 'Supplies')
    refs.commands = line(body, 'Commands')
    make('VwText', body, 'Change these on the Clients page on voidwatch.xyz.')
  elseif v.state == 'pairing' then
    refs.code = make('VwCode', body)
    refs.expires = line(body, 'Code expires')
    local row
    local copied = function(what, text, key, label)
      g_window.setClipboardText(text or '')
      refs.copied, refs.copiedAt = what, g_clock.millis()
      local b = row and row[key]
      if b then
        local colour = b:getColor()
        b:setText('Copied')
        b:setColor('#4cd964')
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
    refs.howto = make('VwText', body)
    make('VwSeparator', body)
    refs.upload = line(body, 'Upload script')
    refs.memory = line(body, 'Memory')
    stopButtons(body)
  elseif v.state == 'waiting' then
    make('VwText', body, 'The upload script has not answered yet. Run the Voidwatch setup once. If it does not find this '
      .. 'client, give it this folder: ' .. tostring(v.dir))
    refs.memory = line(body, 'Memory')
    stopButtons(body)
  elseif v.state == 'stopped' or v.state == 'off' then
    make('VwText', body, v.state == 'off' and 'Every client that shares this folder sends nothing until it starts again.'
      or 'This client sends nothing until it starts again. The game itself is not affected.')
    buttons(body, v.state == 'off' and 'Start all clients again' or 'Start again', Voidwatch.startAgain)
    make('VwSeparator', body)
    refs.memory = line(body, 'Memory')
    refs.errors = line(body, 'Errors')
  else
    make('VwText', body, 'Log in to see this client.')
  end
  for _, w in ipairs(body:getChildren()) do w:setWidth(body:getWidth()) end
end

local function fill(v)
  refs.who:setText((v.character or 'Not logged in') .. (v.server and (' - ' .. v.server) or ''))
  refs.state.dot:setBackgroundColor(COLOURS[v.state] or '#777777')
  refs.state.text:setColor(COLOURS[v.state] or '#dfdfdf')
  refs.state.text:setText(({
    connected = 'Connected to your Voidwatch account', pairing = 'Waiting for pairing', waiting = 'Waiting for the upload script',
    off = 'Stopped for all clients', offline = 'Not logged in',
  })[v.state] or ('Stopped: ' .. short(v.stopped, 40)))
  refs.state:setTooltip(v.state == 'stopped' and tostring(v.stopped) or '')
  if refs.upload then
    refs.upload.value:setText(v.replyS and ('answered ' .. ago(v.replyS)) or (v.answered and 'answers' or 'no answer yet'))
  end
  if refs.sending then
    refs.sending.value:setText(('status %s, %s'):format(every(v.statusEvery),
      v.captures and ('screenshot ' .. every(v.captureEvery)) or 'no screenshots'))
  end
  if refs.memory then refs.memory.value:setText(('Lua %d MB, client %s MB'):format(v.heapMB, tostring(v.clientMB or '?'))) end
  if refs.errors then
    refs.errors.value:setText(v.errors > 0 and (v.errors .. ', last: ' .. short(v.lastError, 26)) or 'none')
    refs.errors:setTooltip(v.lastError and tostring(v.lastError) or '')
  end
  for i, src in ipairs(v.sources) do
    local w = refs.sources[i]
    if w then
      w.dot:setBackgroundColor(src.on and COLOURS.connected or COLOURS.offline)
      w.name:setText(src.name)
      w.gives:setText(src.gives ~= '' and src.gives or '-')
      w:setHeight(14 + w.gives:getHeight())
    end
  end
  if refs.captures then
    refs.captures.value:setText(v.captures and 'on' or 'off')
    refs.supplies.value:setText(v.suppliesSource == 'bot' and "the bot's supply list" or 'the items you use')
    refs.commands.value:setText(v.commands and 'on' or 'not in this version')
  end
  if refs.code then
    refs.code:setText(v.code or '')
    local left = v.expiresAt and (v.expiresAt - os.time()) or nil
    refs.expires.value:setText(left and left > 0 and ('in %d:%02d'):format(math.floor(left / 60), left % 60) or 'now; a new code comes')
    refs.howto:setText((refs.copiedAt and g_clock.millis() - refs.copiedAt < 3000) and refs.copied
      or ('Open the link and sign in. ' .. tostring(v.character or 'This character') .. ' then joins your account.'))
  end
  if v.url then site = v.url:match('^(https?://[^/]+)') or site end
end

local function fit()
  local body = win.body
  if body:getLayout() then body:getLayout():update() end
  win:setHeight(win:getPaddingTop() + body:getHeight() + 40 + win:getPaddingBottom())
end

-- new rows get their width only after a frame, so a rebuilt window waits unseen until it is fitted to it
local function settle()
  win:setOpacity(0)
  addEvent(function()
    if not win then return end
    local ok, v = pcall(Voidwatch.view)
    if ok and type(v) == 'table' then
      build(v)
      fill(v)
    end
    fit()
    win:setOpacity(1)
  end)
end

local function refresh()
  if timer then removeEvent(timer) end
  timer = nil
  if not win then return end
  local ok, v = pcall(Voidwatch.view)
  if ok and type(v) == 'table' then
    local now = v.state .. '|' .. #v.sources
    if now ~= shape then
      shape = now
      build(v)
      fill(v)
      fit()
      settle()
    else
      fill(v)
      fit()
    end
  end
  timer = scheduleEvent(refresh, 1000)
end

local function close()
  if timer then removeEvent(timer) end
  timer, shape, refs = nil, nil, nil
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
  win.onEscape = close
  win.closeButton.onClick = close
  win.dashboardButton.onClick = function() g_platform.openUrl((site or SITE) .. '/dashboard') end
  local ok, v = pcall(Voidwatch.view)
  win.version:setText('v' .. tostring(ok and v.version or '?'))
  if button then button:setOn(true) end
  refresh()
  win:show()
  win:raise()
  win:focus()
end

local function toggle()
  if win then close() else open() end
end

local function changed()
  if not dot then return end
  local state = Voidwatch.state()
  if state ~= lastState then
    lastState = state
    if win then refresh() end
    dot:setBackgroundColor(COLOURS[state] or '#777777')
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
  end,
  terminate = function()
    close()
    if button then button:destroy() end
    button, dot, lastState = nil, nil, nil
  end,
  changed = changed,
  close = close,
  toggle = toggle,
}
