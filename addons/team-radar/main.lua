-- Team radar, a Voidwatch addon, MIT licence. Shows the player's other characters and the guild mates who share their
-- position on the minimap. The website sends where they are with each status reply while this addon runs, every 5 s.
local STALE_MS = 20000
local CHECK_MS = 5000
local MAX_MARKS = 50
local GROUP_PX = 14
local COLORS = { own = '#f0c95f', guild = '#b48ef0' }

local minimap, marks, lastAt, timer, arranging = nil, {}, 0, nil, nil
local arrange, arrangeSoon

local function viewedFloor()
  local ok, cam = pcall(function() return minimap:getCameraPosition() end)
  return ok and cam and cam.z or 7
end

-- the full map is the same widget as the minimap, so only the minimap module knows which one the player sees
local function namesMode()
  local gm = modules.game_minimap
  local v = Addon.setting and Addon.setting(gm and gm.fullmapView == true and 'names_full' or 'names')
  return (v == 'off' or v == 'hover') and v or 'on'
end

local function floorText(m)
  if m.z == m.view then return '' end
  return m.z < m.view and (' +%d'):format(m.view - m.z) or (' -%d'):format(m.z - m.view)
end

local function screenPoint(m)
  local ok, p = pcall(function() return minimap:getTilePoint({ x = m.x, y = m.y, z = m.view }) end)
  return ok and type(p) == 'table' and p.x and p.x >= 0 and p or nil
end

local function overlaps(a, list)
  for _, b in ipairs(list) do
    if a.x < b.x + b.width and b.x < a.x + a.width and a.y < b.y + b.height and b.y < a.y + a.height then
      return true
    end
  end
  return false
end

-- the minimap's own buttons and texts, so that no name covers them
local function controls(ours)
  local out, r = {}, minimap:getRect()
  for _, c in ipairs(minimap:getChildren()) do
    if not ours[c] and c:isVisible() then
      local cr = c:getRect()
      if cr.width * cr.height < r.width * r.height / 2 then out[#out + 1] = cr end
    end
  end
  return out
end

local function inside(p)
  local r = minimap:getRect()
  return p.x >= r.x and p.y >= r.y and p.x < r.x + r.width and p.y < r.y + r.height
end

local function dotRect(m, p)
  local w, h = m.dot:getWidth(), m.dot:getHeight()
  return { x = p.x - math.floor(w / 2), y = p.y - math.floor(h / 2), width = w, height = h }
end

-- above the dot, below, right or left, inside the minimap and on no taken place; else nil and the first place
local function fit(m, p, text, taken, boxed)
  m.label:setTextOffset(boxed and { x = 4, y = 3 } or { x = 0, y = 0 })
  m.label:setPaddingRight(boxed and 4 or 0)
  m.label:setPaddingBottom(boxed and 2 or 0)
  m.label:setText(text)
  local r, w, h, half = minimap:getRect(), m.label:getWidth(), m.label:getHeight(), math.floor(m.dot:getWidth() / 2) + 4
  local cx, cy = p.x - math.floor(w / 2), p.y - math.floor(h / 2)
  local first
  for _, s in ipairs({ { cx, p.y - half - h }, { cx, p.y + half }, { p.x + half, cy }, { p.x - half - w, cy } }) do
    local rect = { x = math.max(r.x + 2, math.min(s[1], r.x + r.width - 2 - w)), width = w, height = h,
                   y = math.max(r.y + 2, math.min(s[2], r.y + r.height - 2 - h)) }
    first = first or rect
    if not overlaps(rect, taken) then return rect end
  end
  return nil, first
end

local function showAt(m, p, rect, boxed)
  m.label:setImageSource(boxed and Addon.dir .. 'box.png' or '')
  local dx, dy = rect.x + math.floor(rect.width / 2) - p.x, rect.y + math.floor(rect.height / 2) - p.y
  m.label:setMarginLeft(math.max(0, dx))
  m.label:setMarginRight(math.max(0, -dx))
  m.label:setMarginTop(math.max(0, dy))
  m.label:setMarginBottom(math.max(0, -dy))
  minimap:centerInPosition(m.label, { x = m.x, y = m.y, z = m.view })
  m.label:setVisible(true)
end

local function setCount(m, n)
  local file = Addon.dir .. (n > 9 and 'group-wide-' or n > 1 and 'group-' or 'dot-') .. m.kind .. '.png'
  if m.file ~= file then
    m.file = file
    m.dot:setImageSource(file)
    m.dot:resize(n > 9 and 21 or n > 1 and 15 or 11, n > 1 and 15 or 11)
  end
  m.dot:setText(n > 1 and tostring(n) or '')
end

local function showList(m, p)
  local all, rect, first = {}, nil, nil
  for _, o in ipairs(m.group or { m }) do all[#all + 1] = o.name .. floorText(o) end
  for n = #all, 1, -1 do
    local more = n < #all and ('\n%d more'):format(#all - n) or ''
    rect, first = fit(m, p, table.concat(all, '\n', 1, n) .. more, { dotRect(m, p) }, true)
    if rect then break end
  end
  showAt(m, p, rect or first, true)
  m.label:raise()
end

local function drop(name)
  local m = marks[name]
  if not m then return end
  m.dot:destroy()
  m.label:destroy()
  marks[name] = nil
end

-- a dark edge and a white ring around the colour, and the name in the outlined font of the names in the game view: both
-- stay visible on any map colour. The dot takes the mouse for the names on hover, but no click: a click on it still
-- reaches the minimap. Both stay under the minimap's own buttons, so a dot never takes a click from them.
local function make(name)
  local dot = g_ui.createWidget('UIWidget', minimap)
  dot:setFocusable(false)
  dot:resize(11, 11)
  dot:setFont('verdana-9px-bold')
  dot:setColor('#000000')
  dot:setTextAlign(AlignCenter)
  local label = g_ui.createWidget('UILabel', minimap)
  label:setPhantom(true)
  label:setFont('verdana-11px-rounded')
  label:setTextAutoResize(true)
  label:setImageBorder(4)
  label:lower()
  dot:lower()
  local m = { name = name, dot = dot, label = label }
  dot.onHoverChange = function(_, hovered)
    m.hovered = hovered
    if marks[name] == m then arrangeSoon() end
  end
  marks[name] = m
  return m
end

-- pinned to the floor in view, so a mark on another floor stays where it is and says which floor
local function place(m, z)
  m.view = z
  m.label:setColor(COLORS[m.kind])
  m.dot:setOpacity(m.z == z and 1 or 0.5)
  m.label:setOpacity(m.z == z and 1 or 0.7)
  minimap:centerInPosition(m.dot, { x = m.x, y = m.y, z = z })
end

-- marks close together on screen share one dot, led by an own character, then by name. Names go on own characters
-- first, then by name, and only on a dot of one. The names list of the dot under the mouse goes on top of all.
function arrange()
  if arranging then Addon.cancel(arranging) end
  arranging = nil
  local list, points, taken, leads, ours = {}, {}, {}, {}, {}
  for _, m in pairs(marks) do
    list[#list + 1] = m
    local p = screenPoint(m)
    points[m] = p and inside(p) and p or nil
    ours[m.dot], ours[m.label] = true, true
  end
  table.sort(list, function(a, b)
    if a.kind ~= b.kind then return a.kind == 'own' end
    return a.name < b.name
  end)
  for _, m in ipairs(list) do
    if not taken[m] then
      local p, group = points[m], { m }
      taken[m] = true
      for _, o in ipairs(list) do
        local q = points[o]
        if not taken[o] and p and q and math.abs(q.x - p.x) < GROUP_PX and math.abs(q.y - p.y) < GROUP_PX then
          group[#group + 1] = o
          taken[o] = true
        end
      end
      setCount(m, #group)
      for i, o in ipairs(group) do
        o.group = i == 1 and group or nil
        o.dot:setVisible(i == 1)
        o.label:setVisible(false)
        if i > 1 then o.hovered = false end
      end
      leads[#leads + 1] = m
    end
  end
  local busy = controls(ours)
  for _, m in ipairs(leads) do
    local p = points[m]
    if p then busy[#busy + 1] = dotRect(m, p) end
  end
  table.sort(leads, function(a, b)
    if a.hovered ~= b.hovered then return b.hovered == true end
    if a.kind ~= b.kind then return a.kind == 'own' end
    return a.name < b.name
  end)
  local mode = namesMode()
  for _, m in ipairs(leads) do
    local p = points[m]
    if p and m.hovered and mode ~= 'off' then
      showList(m, p)
    elseif p and mode == 'on' and #m.group == 1 then
      local rect = fit(m, p, m.name .. floorText(m), busy)
      if rect then
        showAt(m, p, rect)
        busy[#busy + 1] = rect
      end
    end
  end
end

function arrangeSoon()
  if not arranging then arranging = Addon.after(50, arrange) end
end

local lastReply
local function update(reply)
  if type(reply) ~= 'table' or type(reply.radar) ~= 'table' then return end
  lastReply = reply
  local guild = not (Addon.setting and Addon.setting('guild') == false)
  minimap = minimap or Addon.minimap()
  if not minimap then return end
  local z, seen = viewedFloor(), {}
  for i, r in ipairs(reply.radar) do
    if i > MAX_MARKS then break end
    local name, x, y, rz = type(r) == 'table' and tostring(r.name or '') or '', tonumber(r.x), tonumber(r.y), tonumber(r.z)
    if name ~= '' and x and y and rz and (guild or r.kind ~= 'guild') then
      seen[name] = true
      local m = marks[name] or make(name)
      m.x, m.y, m.z, m.kind = x, y, rz, r.kind == 'guild' and 'guild' or 'own'
      place(m, z)
    end
  end
  for name in pairs(marks) do
    if not seen[name] then drop(name) end
  end
  lastAt = g_clock.millis()
  arrange()
end

-- no reply for a while: the upload script stopped, so the marks are old
local function check()
  if g_clock.millis() - lastAt > STALE_MS then
    for name in pairs(marks) do drop(name) end
  end
  timer = Addon.after(CHECK_MS, check)
end

local function onCamera(_, pos)
  if not pos then return end
  for _, m in pairs(marks) do place(m, pos.z) end
  arrangeSoon()
end

local HANDLERS = { onCameraPositionChange = onCamera, onZoomChange = arrangeSoon, onGeometryChange = arrangeSoon }

function init()
  minimap = Addon.minimap()
  Addon.on('reply', update)
  Addon.on('settings', function() if lastReply then update(lastReply) end end)
  if minimap then connect(minimap, HANDLERS) end
  timer = Addon.after(CHECK_MS, check)
end

function terminate()
  if timer then Addon.cancel(timer) end
  if arranging then Addon.cancel(arranging) end
  for name in pairs(marks) do drop(name) end
  if minimap then disconnect(minimap, HANDLERS) end
end
