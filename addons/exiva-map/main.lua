-- Exiva map, a Voidwatch addon, MIT licence. Draws a team exiva result on the minimap like the website does: the website
-- sends the exact outline of the area, and this addon fills it and draws its edge. The player's own cast draws its own
-- answer at once, before the team's answers come. Thin lines show each caster's answer. A pointer at the edge of the
-- game view shows the way to the area. Nothing is written to disk.
local SHOW_MS = 30000
local FADE_EVERY_MS = 2000
local OPEN_SQM = 1500
local MAX_SHOWN = 3
local MAX_CASTS = 20
local STRIP_PX, ARC_PX, BIG_ARC_PX, MAX_SEGMENTS = 3, 12, 20, 400
local COLORS = { '#ffc400', '#33e0ff', '#ff8ae2' }
local KINDS = { 'strip', 'thin', 'edge', 'mark' }
local FONT = 'verdana-11px-antialised'
local ARROW, EDGE_GAP, PAD = 19, 4, 4
local CLOSE, FAR, OPEN_R = 100, 274, 100000
local ANGLE = { east = 0, ['south-east'] = 45, south = 90, ['south-west'] = 135, west = 180, ['north-west'] = 225, north = 270, ['north-east'] = 315 }

local band, bxor, rshift = bit.band, bit.bxor, bit.rshift
local schar, sbyte, concat, floor = string.char, string.byte, table.concat, math.floor
local shown, minimap, mapPanel, arrows, holder = {}, nil, nil, {}, nil
local pool = { strip = {}, thin = {}, edge = {}, mark = {} }


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

-- one answer's outline, as the server draws it: its two sides and its arcs, or the square next to the caster. Angles are
-- in degrees, clockwise from east, since y grows to the south.
local function outline(c)
  local x, y = tonumber(c.x), tonumber(c.y)
  if not x or not y then return nil end
  if c.band == 'beside' then
    local h = 3.5
    return { { 'l', x - h, y - h, x + h, y - h }, { 'l', x + h, y - h, x + h, y + h }, { 'l', x + h, y + h, x - h, y + h }, { 'l', x - h, y + h, x - h, y - h } }
  end
  local lo, hi, base = ({ close = 0, far = CLOSE, veryfar = FAR })[c.band], ({ close = CLOSE, far = FAR, veryfar = OPEN_R })[c.band], ANGLE[c.dir]
  if not lo or not base then return nil end
  local out = {}
  for _, a in ipairs({ base - 22.5, base + 22.5 }) do
    local r = math.rad(a)
    out[#out + 1] = { 'l', x + lo * math.cos(r), y + lo * math.sin(r), x + hi * math.cos(r), y + hi * math.sin(r) }
  end
  if lo > 0 then out[#out + 1] = { 'a', x, y, lo, base - 22.5, base + 22.5 } end
  out[#out + 1] = { 'a', x, y, hi, base - 22.5, base + 22.5 }
  return out
end

-- where a row crosses the outline, sorted: the area lies between the 1st and 2nd crossing, the 3rd and 4th, and so on
local function crossings(edges, y)
  local xs = {}
  for _, e in ipairs(edges) do
    if e[1] == 'l' then
      local x1, y1, x2, y2 = e[2], e[3], e[4], e[5]
      if (y1 <= y and y < y2) or (y2 <= y and y < y1) then xs[#xs + 1] = x1 + (y - y1) * (x2 - x1) / (y2 - y1) end
    else
      local cx, cy, r, a0, a1 = e[2], e[3], e[4], e[5], e[6]
      local dy = y - cy
      if math.abs(dy) < r then
        local dx = math.sqrt(r * r - dy * dy)
        for _, x in ipairs({ cx - dx, cx + dx }) do
          if (math.deg(math.atan2(dy, x - cx)) - a0) % 360 <= a1 - a0 then xs[#xs + 1] = x end
        end
      end
    end
  end
  table.sort(xs)
  return xs
end

local function within(a, a0, a1) return (a - a0) % 360 <= a1 - a0 end

-- how far the area is from a position: to its nearest and its farthest point, or 0 when the position is inside
local function reach(s, x, y)
  local left = 0
  for _, cx in ipairs(crossings(s.edges, y)) do if cx < x then left = left + 1 end end
  local near, far = left % 2 == 1 and 0 or math.huge, 0
  local function dist(px, py) return math.sqrt((px - x) ^ 2 + (py - y) ^ 2) end
  for _, e in ipairs(s.edges) do
    if e[1] == 'l' then
      local x1, y1, x2, y2 = e[2], e[3], e[4], e[5]
      local dx, dy = x2 - x1, y2 - y1
      local t = (dx == 0 and dy == 0) and 0 or math.max(0, math.min(1, ((x - x1) * dx + (y - y1) * dy) / (dx * dx + dy * dy)))
      near = math.min(near, dist(x1 + t * dx, y1 + t * dy))
      far = math.max(far, dist(x1, y1), dist(x2, y2))
    else
      local cx, cy, r, a0, a1 = e[2], e[3], e[4], e[5], e[6]
      local d, a = dist(cx, cy), math.deg(math.atan2(y - cy, x - cx))
      local ends = { { cx + r * math.cos(math.rad(a0)), cy + r * math.sin(math.rad(a0)) }, { cx + r * math.cos(math.rad(a1)), cy + r * math.sin(math.rad(a1)) } }
      near = math.min(near, within(a, a0, a1) and math.abs(d - r) or math.min(dist(ends[1][1], ends[1][2]), dist(ends[2][1], ends[2][2])))
      far = math.max(far, within(a + 180, a0, a1) and d + r or math.max(dist(ends[1][1], ends[1][2]), dist(ends[2][1], ends[2][2])))
    end
  end
  return near, far
end

local function colorOf(key)
  local h = 0
  for i = 1, #key do h = (h * 31 + sbyte(key, i)) % 4294967296 end
  local first = h % #COLORS
  for k = 0, #COLORS - 1 do
    local color, used = COLORS[(first + k) % #COLORS + 1], false
    for other, s in pairs(shown) do used = used or (other ~= key and s.color == color) end
    if not used then return color end
  end
  return COLORS[first + 1]
end

-- Every piece sits in one holder over the minimap, so the minimap keeps a single child for this addon however big the
-- area is: other modules that walk the minimap's children (a route editor raising its markers) stay fast, and a draw
-- needs no layout pass of the minimap. Creating a widget costs about 1 ms in the client, so a redraw keeps its widgets.
local function holderWidget()
  if holder then return holder end
  holder = g_ui.createWidget('UIWidget', minimap)
  holder:setPhantom(true)
  holder:setFocusable(false)
  holder:setClipping(true)
  holder:fill('parent')
  pcall(function() minimap:moveChildToIndex(holder, 1) end)
  return holder
end

local function take(used, kind, color, opacity)
  used[kind] = used[kind] + 1
  local list = pool[kind]
  local w = list[used[kind]]
  if not w then
    w = g_ui.createWidget('UIWidget', holderWidget())
    w:setPhantom(true)
    w:setFocusable(false)
    if kind == 'mark' then
      w:setBorderWidth(1)
      w:setBorderColor('#000000')
    end
    local below = 1
    for _, k in ipairs(KINDS) do
      if k == kind then break end
      below = below + #pool[k]
    end
    pcall(function() holder:moveChildToIndex(w, below) end)
    list[used[kind]] = w
  end
  w:setBackgroundColor(color)
  w:setOpacity(opacity)
  w:setVisible(true)
  return w
end

-- a segment cut to a rectangle (Liang-Barsky), or nil when it misses
local function clip(x1, y1, x2, y2, r)
  local t0, t1, dx, dy = 0, 1, x2 - x1, y2 - y1
  for _, pq in ipairs({ { -dx, x1 - r.x }, { dx, r.x + r.width - x1 }, { -dy, y1 - r.y }, { dy, r.y + r.height - y1 } }) do
    local p, q = pq[1], pq[2]
    if p == 0 then
      if q < 0 then return nil end
    else
      local t = q / p
      if p < 0 then
        if t > t1 then return nil elseif t > t0 then t0 = t end
      else
        if t < t0 then return nil elseif t < t1 then t1 = t end
      end
    end
  end
  return x1 + t0 * dx, y1 + t0 * dy, x1 + t1 * dx, y1 + t1 * dy
end

-- everything is drawn in screen pixels for the part in view: the fill as 3 px strips whose ends sit on the outline, every
-- straight edge as one rotated line and an arc as short lines. Each camera move, zoom or size change draws it again.
local function redraw()
  if not minimap then return end
  local used = { strip = 0, thin = 0, edge = 0, mark = 0 }
  do
    local cam, r = minimap:getCameraPosition(), minimap:getRect()
    local p0 = cam and minimap:getTilePoint({ x = cam.x, y = cam.y, z = cam.z })
    local p8 = cam and minimap:getTilePoint({ x = cam.x + 8, y = cam.y, z = cam.z })
    local scale = p0 and p8 and (p8.x - p0.x) / 8 or 0
    if next(shown) and scale > 0 then
      local function sx(x) return p0.x + (x - cam.x) * scale end
      local function sy(y) return p0.y + (y - cam.y) * scale end
      local arcPx = r.height > 400 and BIG_ARC_PX or ARC_PX
      local function line(kind, color, opacity, height, x1, y1, x2, y2)
        x1, y1, x2, y2 = clip(sx(x1), sy(y1), sx(x2), sy(y2), r)
        if not x1 then return end
        local len = math.sqrt((x2 - x1) ^ 2 + (y2 - y1) ^ 2)
        if len < 1 then return end
        local w = take(used, kind, color, opacity)
        w:setRect({ x = floor((x1 + x2) / 2 - len / 2 + 0.5), y = floor((y1 + y2) / 2 - height / 2 + 0.5), width = floor(len + 1.5), height = height })
        w:setRotation(math.deg(math.atan2(y2 - y1, x2 - x1)))
      end
      local function edge(kind, color, opacity, height, e)
        if e[1] == 'l' then return line(kind, color, opacity, height, e[2], e[3], e[4], e[5]) end
        local cx, cy, rr, a0, a1 = e[2], e[3], e[4], e[5], e[6]
        local px, py, pr = sx(cx), sy(cy), rr * scale
        local nx, ny = math.max(r.x, math.min(px, r.x + r.width)), math.max(r.y, math.min(py, r.y + r.height))
        local farX, farY = math.max(math.abs(px - r.x), math.abs(px - r.x - r.width)), math.max(math.abs(py - r.y), math.abs(py - r.y - r.height))
        if (nx - px) ^ 2 + (ny - py) ^ 2 > pr * pr or farX * farX + farY * farY < pr * pr then return end
        local k = math.max(2, math.min(MAX_SEGMENTS, math.ceil(pr * math.rad(a1 - a0) / arcPx)))
        for i = 0, k - 1 do
          local b0, b1 = math.rad(a0 + (a1 - a0) * i / k), math.rad(a0 + (a1 - a0) * (i + 1) / k)
          line(kind, color, opacity, height, cx + rr * math.cos(b0), cy + rr * math.sin(b0), cx + rr * math.cos(b1), cy + rr * math.sin(b1))
        end
      end
      for _, s in pairs(shown) do
        -- the fill: rows of 3 px; a row whose ends move less than a pixel joins the strip above it
        local group
        local function flush()
          if not group then return end
          for _, iv in ipairs(group.ends) do
            take(used, 'strip', s.color .. '80', s.opacity):setRect({ x = iv[1], y = group.y, width = iv[2] - iv[1], height = group.h })
          end
          group = nil
        end
        for py = r.y, r.y + r.height - 1, STRIP_PX do
          local h = math.min(STRIP_PX, r.y + r.height - py)
          local xs, ends = crossings(s.edges, cam.y + (py + h / 2 - p0.y) / scale), {}
          for i = 1, #xs - 1, 2 do
            local x1, x2 = floor(math.max(r.x, sx(xs[i])) + 0.5), floor(math.min(r.x + r.width, sx(xs[i + 1])) + 0.5)
            if x2 > x1 then ends[#ends + 1] = { x1, x2 } end
          end
          local same = group and #ends == #group.ends and #ends > 0
          for i = 1, same and #ends or 0 do
            same = same and math.abs(ends[i][1] - group.ends[i][1]) < 1 and math.abs(ends[i][2] - group.ends[i][2]) < 1
          end
          if same then
            group.h = group.h + h
          else
            flush()
            if #ends > 0 then group = { y = py, h = h, ends = ends } end
          end
        end
        flush()
        for _, g in ipairs(s.guides) do
          for _, e in ipairs(g) do
            if e[1] == 'l' or e[4] < OPEN_R then edge('thin', s.color .. '90', s.opacity, 1, e) end
          end
        end
        for _, e in ipairs(s.edges) do edge('edge', s.color, s.opacity, 2, e) end
        for _, p in ipairs(s.from) do
          local mx, my = sx(p[1]), sy(p[2])
          if mx >= r.x and mx <= r.x + r.width and my >= r.y and my <= r.y + r.height then
            take(used, 'mark', s.color, s.opacity):setRect({ x = floor(mx - 3), y = floor(my - 3), width = 7, height = 7 })
          end
        end
      end
    end
    for _, k in ipairs(KINDS) do
      for i = used[k] + 1, #pool[k] do pool[k][i]:setVisible(false) end
    end
  end
end

local function viewedFloor()
  local ok, cam = pcall(function() return minimap:getCameraPosition() end)
  return ok and cam and cam.z or 7
end

local function pinLabel(s) minimap:centerInPosition(s.label, { x = floor(s.cx + 0.5), y = floor(s.cy + 0.5), z = viewedFloor() }) end

-- the pointer: a framed box with the name, the distance and the floor, and an arrow at the edge of the game view

-- one arrow per direction and colour, 0 = east and clockwise in steps of 45 degrees, with a dark edge
local function arrow(i, color)
  local key = color .. i
  if arrows[key] then return arrows[key] end
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
  local palette = { { 0, 0, 0, 0 }, { 20, 16, 0, 230 }, { tonumber(color:sub(2, 3), 16), tonumber(color:sub(4, 5), 16), tonumber(color:sub(6, 7), 16), 255 } }
  arrows[key] = base64(png(ARROW, ARROW, concat(px), palette))
  return arrows[key]
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
  box:setBorderColor(s.color)
  local lines = {}
  for i, color in ipairs({ s.color, '#ffffff' }) do
    local l = g_ui.createWidget('UILabel', mapPanel)
    l:setPhantom(true)
    l:setFont(FONT)
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
    if s.dir ~= i then s.tip:setImageSourceBase64(arrow(i, s.color)) s.dir = i end
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
  s.label:destroy()
  for _, w in ipairs({ s.box, s.tip, s.lines and s.lines[1], s.lines and s.lines[2] }) do w:destroy() end
  shown[key] = nil
  redraw()
end

local function fade(key)
  local s = shown[key]
  if not s then return end
  local age = g_clock.millis() - s.at
  if age >= SHOW_MS then return forget(key) end
  s.opacity = 1 - 0.7 * age / SHOW_MS
  s.label:setOpacity(s.opacity)
  for _, w in ipairs({ s.box, s.tip, s.lines and s.lines[1], s.lines and s.lines[2] }) do w:setOpacity(math.max(0.7, s.opacity)) end
  s.label:setText(s.name)
  redraw()
  s.timer = Addon.after(FADE_EVERY_MS, function() fade(key) end)
end

local function show(args)
  minimap = minimap or Addon.minimap()
  local edges = type(args.shape) == 'table' and type(args.shape.edges) == 'table' and args.shape.edges
  if not minimap or not edges or #edges == 0 then return end
  local key = tostring(args.target or '?'):lower()
  local started = g_clock.millis()
  local s = shown[key]
  if not s then
    local count, oldest = 0, nil
    for k, o in pairs(shown) do
      count = count + 1
      if not oldest or o.at < shown[oldest].at then oldest = k end
    end
    if count >= MAX_SHOWN then forget(oldest) end
    local color = colorOf(key)
    local label = g_ui.createWidget('UILabel', minimap)
    label:setPhantom(true)
    label:setColor(color)
    label:setTextAutoResize(true)
    s = { label = label, color = color }
    shown[key] = s
  end
  if s.timer then Addon.cancel(s.timer) end
  s.name, s.at, s.edges, s.opacity = tostring(args.target or '?'), g_clock.millis(), edges, 1
  s.zmin, s.zmax = tonumber(args.zmin), tonumber(args.zmax)
  s.cx, s.cy = tonumber(args.x) or edges[1][2], tonumber(args.y) or edges[1][3]
  s.open = false
  for _, e in ipairs(edges) do s.open = s.open or (e[1] == 'a' and e[4] >= OPEN_R) end
  s.guides, s.from = {}, {}
  for i, c in ipairs(type(args.casts) == 'table' and args.casts or {}) do
    local g = i <= MAX_CASTS and type(c) == 'table' and outline(c)
    if g then
      s.guides[#s.guides + 1] = g
      s.from[#s.from + 1] = { tonumber(c.x), tonumber(c.y) }
    end
  end
  pinLabel(s)
  fade(key)
  aimAll()
  Addon.log(('%s: %d edges, %d guides, %d ms'):format(s.name, #edges, #s.guides, g_clock.millis() - started))
end

-- the player's own cast: its answer alone, until the team's answers make the area smaller
local MIDDLE = { beside = 0, close = CLOSE / 2, far = (CLOSE + FAR) / 2, veryfar = FAR + 300 }
local function cast(args)
  local edges = outline(args)
  if not edges then return end
  local z, level = tonumber(args.z), args.level
  local zmin, zmax
  if z and level == 'same' then zmin, zmax = z, z
  elseif z and level == 'higher' and z > 0 then zmin, zmax = 0, z - 1
  elseif z and level == 'lower' and z < 15 then zmin, zmax = z + 1, 15 end
  local a, d = math.rad(ANGLE[args.dir] or 0), MIDDLE[args.band] or 0
  show({ target = args.target, x = tonumber(args.x) + d * math.cos(a), y = tonumber(args.y) + d * math.sin(a), zmin = zmin, zmax = zmax, shape = { edges = edges } })
end

local lastFloor
local function onCamera(_, pos)
  if pos and pos.z ~= lastFloor then
    lastFloor = pos.z
    for _, s in pairs(shown) do pinLabel(s) end
  end
  if next(shown) then redraw() end
end

local function onChange() if next(shown) then redraw() end end

function init()
  minimap = Addon.minimap()
  mapPanel = modules.game_interface and modules.game_interface.getMapPanel and modules.game_interface.getMapPanel()
  Addon.on('exiva', show)
  Addon.on('exiva_cast', cast)
  if minimap then connect(minimap, { onCameraPositionChange = onCamera, onZoomChange = onChange, onGeometryChange = onChange }) end
  if LocalPlayer then connect(LocalPlayer, { onPositionChange = aimAll }) end
  if mapPanel then connect(mapPanel, { onGeometryChange = aimAll }) end
end

function terminate()
  for key in pairs(shown) do forget(key) end
  for _, k in ipairs(KINDS) do
    for _, w in ipairs(pool[k]) do w:destroy() end
    pool[k] = {}
  end
  if holder then holder:destroy() holder = nil end
  if minimap then disconnect(minimap, { onCameraPositionChange = onCamera, onZoomChange = onChange, onGeometryChange = onChange }) end
  if LocalPlayer then disconnect(LocalPlayer, { onPositionChange = aimAll }) end
  if mapPanel then disconnect(mapPanel, { onGeometryChange = aimAll }) end
end
