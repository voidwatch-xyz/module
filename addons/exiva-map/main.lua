-- Exiva map, a Voidwatch addon, MIT licence. Draws a team exiva result on the minimap like the website does: the website
-- sends the area as rows of cells, and this addon lays a translucent fill and a sharp outline over those map squares.
-- A pointer at the edge of the game view shows the way to the area. Nothing is written to disk.
local SHOW_MS = 180000
local FADE_EVERY_MS = 10000
local OPEN_SQM = 1500
local MAX_SHOWN = 3
local MAX_PIECES = 1500
local FILL, EDGE = '#ffc40080', '#ffc400'
local ARROW_PALETTE = { { 0, 0, 0, 0 }, { 20, 16, 0, 230 }, { 255, 196, 0, 255 } }
local FONT, FONT_FALLBACK = 'voidwatch-13px', 'verdana-11px-antialised'
local ARROW, EDGE_GAP, PAD = 19, 4, 4

local band, bxor, rshift = bit.band, bit.bxor, bit.rshift
local schar, sbyte, concat, floor = string.char, string.byte, table.concat, math.floor
local shown, minimap, mapPanel, font, arrows = {}, nil, nil, nil, {}

-- a PNG with a 3-colour palette and transparency, in zlib "stored" blocks: small, and fast enough in plain Lua
local crcTable
local function crc32(s)
  if not crcTable then
    crcTable = {}
    for i = 0, 255 do
      local c = i
      for _ = 1, 8 do c = band(c, 1) == 1 and bxor(rshift(c, 1), 0xEDB88320) or rshift(c, 1) end
      crcTable[i] = c
    end
  end
  local crc = 0xFFFFFFFF
  for i = 1, #s do crc = bxor(crcTable[band(bxor(crc, sbyte(s, i)), 0xFF)], rshift(crc, 8)) end
  return bxor(crc, 0xFFFFFFFF)
end

local function u32(n)
  n = n % 4294967296
  return schar(floor(n / 16777216) % 256, floor(n / 65536) % 256, floor(n / 256) % 256, n % 256)
end

local function chunk(kind, data) return u32(#data) .. kind .. data .. u32(crc32(kind .. data)) end

local function adler32(s)
  local a, b, n, i = 1, 0, #s, 1
  while i <= n do
    local stop = math.min(i + 3999, n)
    for j = i, stop do
      a = a + sbyte(s, j)
      b = b + a
    end
    a, b, i = a % 65521, b % 65521, stop + 1
  end
  return b * 65536 + a
end

local function zlibStored(raw)
  local parts, n, pos = { schar(0x78, 0x01) }, #raw, 1
  repeat
    local len = math.min(65535, n - pos + 1)
    parts[#parts + 1] = schar(pos + len > n and 1 or 0, len % 256, floor(len / 256), (65535 - len) % 256, floor((65535 - len) / 256))
    parts[#parts + 1] = raw:sub(pos, pos + len - 1)
    pos = pos + len
  until pos > n
  parts[#parts + 1] = u32(adler32(raw))
  return concat(parts)
end

local function png(w, h, pixels, palette)
  local rows = {}
  for y = 0, h - 1 do rows[#rows + 1] = '\0' .. pixels:sub(y * w + 1, y * w + w) end
  local plte, trns = {}, {}
  for _, c in ipairs(palette) do
    plte[#plte + 1] = schar(c[1], c[2], c[3])
    trns[#trns + 1] = schar(c[4])
  end
  return '\137PNG\r\n\26\n' .. chunk('IHDR', u32(w) .. u32(h) .. schar(8, 3, 0, 0, 0)) .. chunk('PLTE', concat(plte))
    .. chunk('tRNS', concat(trns)) .. chunk('IDAT', zlibStored(concat(rows))) .. chunk('IEND', '')
end

local B64 = 'ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/'
local B64C = {}
for i = 1, 64 do B64C[i - 1] = B64:sub(i, i) end
local function base64(s)
  local out, n = {}, #s
  for i = 1, n, 3 do
    local a, b, c = sbyte(s, i, i + 2)
    local v = a * 65536 + (b or 0) * 256 + (c or 0)
    out[#out + 1] = B64C[floor(v / 262144) % 64] .. B64C[floor(v / 4096) % 64] .. (b and B64C[floor(v / 64) % 64] or '=') .. (c and B64C[v % 64] or '=')
  end
  return concat(out)
end

-- the area as pieces over the map squares: rows with the same run merge into one fill, and the outline runs along every
-- side of a cell that has no cell next to it. Squares are [first, last + 1), so pieces meet without gaps.
local function pieces(area)
  local step = tonumber(area.step) or 1
  local half, rows, order = floor(step / 2), {}, {}
  for _, r in ipairs(area.rows) do
    if not rows[r[1]] then rows[r[1]], order[#order + 1] = {}, r[1] end
    table.insert(rows[r[1]], { r[2] - half, r[3] - half + step })
  end
  table.sort(order)
  for _, y in ipairs(order) do table.sort(rows[y], function(a, b) return a[1] < b[1] end) end
  local function minus(a, b)
    local out = {}
    for _, r in ipairs(a) do
      local x = r[1]
      for _, q in ipairs(b or {}) do
        if q[2] > x and q[1] < r[2] then
          if q[1] > x then out[#out + 1] = { x, q[1] } end
          x = math.max(x, q[2])
        end
      end
      if x < r[2] then out[#out + 1] = { x, r[2] } end
    end
    return out
  end
  local fills, edges, open, sides = {}, {}, {}, {}
  local x0, x1, y0, y1 = math.huge, -math.huge, math.huge, -math.huge
  for _, y in ipairs(order) do
    local t, b, now = y - half, y - half + step, {}
    for _, r in ipairs(rows[y]) do
      local key = r[1] .. ':' .. r[2]
      local f = open[key]
      if f and f[4] == t then f[4] = b else f = { r[1], t, r[2], b }; fills[#fills + 1] = f end
      now[key] = f
      for _, x in ipairs({ r[1], r[2] }) do
        local e = sides[x]
        if e and e[4] == t then e[4] = b else e = { 'v', x, t, b }; edges[#edges + 1] = e; sides[x] = e end
      end
      x0, x1, y0, y1 = math.min(x0, r[1]), math.max(x1, r[2]), math.min(y0, t), math.max(y1, b)
    end
    open = now
    for _, seg in ipairs(minus(rows[y], rows[y - step])) do edges[#edges + 1] = { 'h', seg[1], seg[2], t } end
    for _, seg in ipairs(minus(rows[y], rows[y + step])) do edges[#edges + 1] = { 'h', seg[1], seg[2], b } end
  end
  return fills, edges, math.max(x1 - x0, y1 - y0)
end

local function viewedFloor()
  local ok, cam = pcall(function() return minimap:getCameraPosition() end)
  return ok and cam and cam.z or 7
end

-- each piece is pinned to the edges of map squares, so the minimap keeps it in place and in size at every zoom and move;
-- a floor change pins them again on the floor in view
local function place(s)
  local z = viewedFloor()
  for _, w in ipairs(s.pieces or {}) do w:destroy() end
  s.pieces = {}
  local function piece(color)
    local w = g_ui.createWidget('UIWidget', minimap)
    w:setPhantom(true)
    w:setFocusable(false)
    w:setBackgroundColor(color)
    pcall(function() minimap:moveChildToIndex(w, 1) end)
    s.pieces[#s.pieces + 1] = w
    return w
  end
  local function pin(w, edge, x, y, hooked) minimap:anchorPosition(w, edge, { x = x, y = y, z = z }, hooked) end
  local edges = #s.fills + #s.edges > MAX_PIECES and {} or s.edges
  for _, e in ipairs(edges) do
    local w = piece(EDGE)
    if e[1] == 'h' then
      w:setHeight(2)
      w:setMarginTop(-1)
      pin(w, AnchorLeft, e[2], e[4], AnchorLeft)
      pin(w, AnchorRight, e[3] - 1, e[4], AnchorRight)
      pin(w, AnchorTop, e[2], e[4], AnchorTop)
    else
      w:setWidth(2)
      w:setMarginLeft(-1)
      pin(w, AnchorLeft, e[2], e[3], AnchorLeft)
      pin(w, AnchorTop, e[2], e[3], AnchorTop)
      pin(w, AnchorBottom, e[2], e[4] - 1, AnchorBottom)
    end
  end
  for _, f in ipairs(s.fills) do
    local w = piece(FILL)
    pin(w, AnchorLeft, f[1], f[2], AnchorLeft)
    pin(w, AnchorRight, f[3] - 1, f[2], AnchorRight)
    pin(w, AnchorTop, f[1], f[2], AnchorTop)
    pin(w, AnchorBottom, f[1], f[4] - 1, AnchorBottom)
  end
  minimap:centerInPosition(s.label, { x = s.cx, y = s.cy, z = z })
end


-- the pointer: a framed box with the name, the distance and the floor, and an arrow at the edge of the game view
local function loadFont()
  if font then return font end
  font = FONT_FALLBACK
  pcall(function()
    if not g_fonts.fontExists(FONT) then g_fonts.importFont(Addon.dir .. FONT) end
    if g_fonts.fontExists(FONT) then font = FONT end
  end)
  return font
end

-- one arrow per direction, 0 = east and clockwise in steps of 45 degrees, with a dark edge
local function arrow(i)
  if arrows[i] then return arrows[i] end
  local a, c, r = i * math.pi / 4, (ARROW - 1) / 2, (ARROW - 1) / 2 * 0.95
  local ux, uy = math.cos(a), math.sin(a)
  local p = { { c + ux * r, c + uy * r }, { c - ux * r * 0.45 - uy * r * 0.85, c - uy * r * 0.45 + ux * r * 0.85 },
              { c - ux * r * 0.45 + uy * r * 0.85, c - uy * r * 0.45 - ux * r * 0.85 } }
  local function inside(x, y)
    local s1 = (p[2][1] - p[1][1]) * (y - p[1][2]) - (p[2][2] - p[1][2]) * (x - p[1][1])
    local s2 = (p[3][1] - p[2][1]) * (y - p[2][2]) - (p[3][2] - p[2][2]) * (x - p[2][1])
    local s3 = (p[1][1] - p[3][1]) * (y - p[3][2]) - (p[1][2] - p[3][2]) * (x - p[3][1])
    return (s1 >= 0 and s2 >= 0 and s3 >= 0) or (s1 <= 0 and s2 <= 0 and s3 <= 0)
  end
  local px = {}
  for y = 0, ARROW - 1 do
    for x = 0, ARROW - 1 do
      local on = inside(x, y)
      local edge = on and not (inside(x - 1, y) and inside(x + 1, y) and inside(x, y - 1) and inside(x, y + 1))
      px[#px + 1] = not on and '\0' or edge and '\1' or '\2'
    end
  end
  arrows[i] = base64(png(ARROW, ARROW, concat(px), ARROW_PALETTE))
  return arrows[i]
end

-- how far the area is from a position: to its nearest and its farthest corner, or 0 when the position is inside
local function reach(s, x, y)
  local near, far, step = math.huge, 0, s.step
  for _, r in ipairs(s.rows) do
    local x1, x2, y1, y2 = r[2] - step / 2, r[3] + step / 2, r[1] - step / 2, r[1] + step / 2
    local dx, dy = math.max(x1 - x, 0, x - x2), math.max(y1 - y, 0, y - y2)
    near = math.min(near, math.sqrt(dx * dx + dy * dy))
    for _, cx in ipairs({ x1, x2 }) do
      for _, cy in ipairs({ y1, y2 }) do far = math.max(far, math.sqrt((cx - x) ^ 2 + (cy - y) ^ 2)) end
    end
  end
  return near, far
end

local function floorText(s, z)
  if not s.zmin then return nil end
  if s.zmin ~= s.zmax then return ('floors %d-%d'):format(s.zmin, s.zmax) end
  local d = s.zmin - z
  if d == 0 then return 'same floor' end
  return ('%d floor%s %s'):format(math.abs(d), math.abs(d) == 1 and '' or 's', d > 0 and 'down' or 'up')
end

local function makePointer(s)
  local box = g_ui.createWidget('UIWidget', mapPanel)
  box:setPhantom(true)
  box:setFocusable(false)
  box:setBackgroundColor('#000000a6')
  box:setBorderWidth(1)
  box:setBorderColor('#ffc400')
  local lines = {}
  for i, color in ipairs({ '#ffd23c', '#ffffff' }) do
    local l = g_ui.createWidget('UILabel', mapPanel)
    l:setPhantom(true)
    l:setFont(loadFont())
    l:setColor(color)
    l:setTextAutoResize(true)
    lines[i] = l
  end
  local tip = g_ui.createWidget('UIWidget', mapPanel)
  tip:setPhantom(true)
  tip:setFocusable(false)
  tip:resize(ARROW, ARROW)
  s.box, s.lines, s.tip = box, lines, tip
end

local function at(w, x, y, origin)
  w:setPosition({ x = origin.x + floor(x), y = origin.y + floor(y) })
end

local function aim(s)
  local pl = g_game.getLocalPlayer()
  local pos = pl and pl:getPosition()
  if not mapPanel or not pos then return end
  if not s.box then makePointer(s) end
  local near, far = reach(s, pos.x, pos.y)
  local fl = floorText(s, pos.z)
  local dist = near == 0 and 'you are in the area' or s.open and ('%d+ sqm'):format(floor(near))
    or ('%d-%d sqm'):format(floor(near), math.ceil(far))
  s.lines[1]:setText(s.name)
  s.lines[2]:setText(fl and (dist .. ', ' .. fl) or dist)
  local tw = math.max(s.lines[1]:getWidth(), s.lines[2]:getWidth())
  local bw, bh = tw + PAD * 2, s.lines[1]:getHeight() + s.lines[2]:getHeight() + PAD * 2
  local rect = mapPanel:getRect()
  local w, h, origin = rect.width, rect.height, { x = rect.x, y = rect.y }
  local bx, by
  local dx, dy = s.cx - pos.x, s.cy - pos.y
  if near == 0 then
    s.tip:setVisible(false)
    bx, by = (w - bw) / 2, EDGE_GAP + (s.slot or 0) * (bh + 2)
  else
    if dx == 0 and dy == 0 then dy = -1 end
    local halfW, halfH = w / 2 - ARROW / 2 - EDGE_GAP, h / 2 - ARROW / 2 - EDGE_GAP
    local tx = dx ~= 0 and halfW / math.abs(dx) or math.huge
    local ty = dy ~= 0 and halfH / math.abs(dy) or math.huge
    local t = math.min(tx, ty)
    local ax, ay = w / 2 + dx * t, h / 2 + dy * t
    local i = floor((math.atan2(dy, dx) + math.pi / 8) / (math.pi / 4)) % 8
    if s.dir ~= i then s.tip:setImageSourceBase64(arrow(i)) s.dir = i end
    s.tip:setVisible(true)
    at(s.tip, ax - ARROW / 2, ay - ARROW / 2, origin)
    if tx <= ty then
      bx, by = dx > 0 and ax - ARROW / 2 - 2 - bw or ax + ARROW / 2 + 2, ay - bh / 2
    else
      bx, by = ax - bw / 2, dy > 0 and ay - ARROW / 2 - 2 - bh or ay + ARROW / 2 + 2
    end
    by = by + (s.slot or 0) * (bh + 2) * (dy > 0 and tx > ty and -1 or 1)
  end
  bx, by = math.max(EDGE_GAP, math.min(w - bw - EDGE_GAP, bx)), math.max(EDGE_GAP, math.min(h - bh - EDGE_GAP, by))
  s.box:resize(bw, bh)
  at(s.box, bx, by, origin)
  at(s.lines[1], bx + PAD, by + PAD, origin)
  at(s.lines[2], bx + PAD, by + PAD + s.lines[1]:getHeight(), origin)
end

local function aimAll()
  local slot = 0
  for _, s in pairs(shown) do
    s.slot = slot
    slot = slot + 1
    local ok, err = pcall(aim, s)
    if not ok then Addon.log('pointer: ' .. tostring(err)) end
  end
end

local function forget(key)
  local s = shown[key]
  if not s then return end
  if s.timer then Addon.cancel(s.timer) end
  for _, w in ipairs(s.pieces or {}) do w:destroy() end
  s.label:destroy()
  for _, w in ipairs({ s.box, s.tip, s.lines and s.lines[1], s.lines and s.lines[2] }) do w:destroy() end
  shown[key] = nil
end

local function fade(key)
  local s = shown[key]
  if not s then return end
  local age = g_clock.millis() - s.at
  if age >= SHOW_MS then return forget(key) end
  local opacity = 1 - 0.6 * age / SHOW_MS
  for _, w in ipairs(s.pieces or {}) do w:setOpacity(opacity) end
  s.label:setOpacity(opacity)
  for _, w in ipairs({ s.box, s.tip, s.lines and s.lines[1], s.lines and s.lines[2] }) do w:setOpacity(math.max(0.7, opacity)) end
  s.label:setText(s.name .. (age >= 60000 and (' · ' .. floor(age / 60000) .. ' min') or ''))
  s.timer = Addon.after(FADE_EVERY_MS, function() fade(key) end)
end

local function show(args)
  minimap = minimap or Addon.minimap()
  local area = type(args.area) == 'table' and args.area
  if not minimap or not area or type(area.rows) ~= 'table' or #area.rows == 0 then return end
  local key = tostring(args.target or '?'):lower()
  forget(key)
  local count, oldest = 0, nil
  for k, s in pairs(shown) do
    count = count + 1
    if not oldest or s.at < shown[oldest].at then oldest = k end
  end
  if count >= MAX_SHOWN then forget(oldest) end
  local started = g_clock.millis()
  local fills, edges, span = pieces(area)
  local label = g_ui.createWidget('UILabel', minimap)
  label:setPhantom(true)
  label:setColor('#ffd23c')
  label:setTextAutoResize(true)
  local s = { label = label, name = tostring(args.target or '?'), at = g_clock.millis(), fills = fills, edges = edges,
              cx = tonumber(args.x) or area.rows[1][2], cy = tonumber(args.y) or area.rows[1][1], rows = area.rows,
              step = tonumber(area.step) or 1, open = span > OPEN_SQM, zmin = tonumber(args.zmin), zmax = tonumber(args.zmax) }
  shown[key] = s
  place(s)
  aimAll()
  fade(key)
  Addon.log(('%s: %d fills, %d edges, %d ms'):format(s.name, #fills, #edges, g_clock.millis() - started))
end

local lastFloor
local function onCamera(_, pos)
  if not pos or pos.z == lastFloor then return end
  lastFloor = pos.z
  for _, s in pairs(shown) do place(s) end
end

function init()
  minimap = Addon.minimap()
  mapPanel = modules.game_interface and modules.game_interface.getMapPanel and modules.game_interface.getMapPanel()
  Addon.on('exiva', show)
  if minimap then connect(minimap, { onCameraPositionChange = onCamera }) end
  if LocalPlayer then connect(LocalPlayer, { onPositionChange = aimAll }) end
  if mapPanel then connect(mapPanel, { onGeometryChange = aimAll }) end
end

function terminate()
  for key in pairs(shown) do forget(key) end
  if minimap then disconnect(minimap, { onCameraPositionChange = onCamera }) end
  if LocalPlayer then disconnect(LocalPlayer, { onPositionChange = aimAll }) end
  if mapPanel then disconnect(mapPanel, { onGeometryChange = aimAll }) end
end
