-- Team radar, a Voidwatch addon, MIT licence. Shows the player's other characters and the guild mates who share their
-- position on the minimap. The website sends where they are with each status reply while this addon runs, every 5 s.
local STALE_MS = 20000
local CHECK_MS = 5000
local MAX_MARKS = 50
local COLORS = { own = '#f0c95f', guild = '#b48ef0' }

local minimap, marks, lastAt, timer = nil, {}, 0, nil

local function viewedFloor()
  local ok, cam = pcall(function() return minimap:getCameraPosition() end)
  return ok and cam and cam.z or 7
end

local function drop(name)
  local m = marks[name]
  if not m then return end
  m.dot:destroy()
  m.label:destroy()
  marks[name] = nil
end

local function make(name)
  local dot = g_ui.createWidget('UIWidget', minimap)
  dot:setPhantom(true)
  dot:setFocusable(false)
  dot:resize(7, 7)
  dot:setBorderWidth(1)
  dot:setBorderColor('#000000')
  local label = g_ui.createWidget('UILabel', minimap)
  label:setPhantom(true)
  label:setTextAutoResize(true)
  label:setMarginBottom(12)
  marks[name] = { name = name, dot = dot, label = label }
  return marks[name]
end

-- pinned to the floor in view, so a mark on another floor stays where it is and says which floor
local function place(m, z)
  local color = COLORS[m.kind]
  m.dot:setBackgroundColor(color)
  m.label:setColor(color)
  m.label:setText(m.z == z and m.name or ('%s (floor %d)'):format(m.name, m.z))
  m.dot:setOpacity(m.z == z and 1 or 0.5)
  m.label:setOpacity(m.z == z and 1 or 0.6)
  minimap:centerInPosition(m.dot, { x = m.x, y = m.y, z = z })
  minimap:centerInPosition(m.label, { x = m.x, y = m.y, z = z })
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
end

-- no reply for a while: the upload script stopped, so the marks are old
local function check()
  if g_clock.millis() - lastAt > STALE_MS then
    for name in pairs(marks) do drop(name) end
  end
  timer = Addon.after(CHECK_MS, check)
end

local lastFloor
local function onCamera(_, pos)
  if not pos or pos.z == lastFloor then return end
  lastFloor = pos.z
  for _, m in pairs(marks) do place(m, pos.z) end
end

function init()
  minimap = Addon.minimap()
  Addon.on('reply', update)
  Addon.on('settings', function() if lastReply then update(lastReply) end end)
  if minimap then connect(minimap, { onCameraPositionChange = onCamera }) end
  timer = Addon.after(CHECK_MS, check)
end

function terminate()
  if timer then Addon.cancel(timer) end
  for name in pairs(marks) do drop(name) end
  if minimap then disconnect(minimap, { onCameraPositionChange = onCamera }) end
end
