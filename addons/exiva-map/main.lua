-- Exiva map, a Voidwatch addon, MIT licence. Draws a team exiva result on the minimap: the website sends the finished
-- area as rows of cells, and this addon paints them into one small image in memory, laid over the minimap where the
-- area is. Nothing is written to disk.
local SHOW_MS = 180000
local FADE_EVERY_MS = 10000
local MAX_SIDE = 256
local OUTLINE_SQM = 1500
local MAX_SHOWN = 3
local PALETTE = { { 0, 0, 0, 0 }, { 255, 196, 0, 105 }, { 255, 214, 70, 235 } }

local band, bxor, rshift = bit.band, bit.bxor, bit.rshift
local schar, sbyte, concat, floor = string.char, string.byte, table.concat, math.floor
local shown, minimap = {}, nil

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

local function png(w, h, pixels)
  local rows = {}
  for y = 0, h - 1 do rows[#rows + 1] = '\0' .. pixels:sub(y * w + 1, y * w + w) end
  local plte, trns = {}, {}
  for _, c in ipairs(PALETTE) do
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

-- the rows as an image: one pixel per cell, or per square of cells for a big area; the pixels at the edge are brighter,
-- and an area wider than OUTLINE_SQM keeps only its edge, so it does not cover the map
local function paint(area)
  local step = tonumber(area.step) or 1
  local minx, maxx, miny, maxy = math.huge, -math.huge, math.huge, -math.huge
  for _, r in ipairs(area.rows) do
    minx, maxx = math.min(minx, r[2]), math.max(maxx, r[3])
    miny, maxy = math.min(miny, r[1]), math.max(maxy, r[1])
  end
  local cols, lines = floor((maxx - minx) / step) + 1, floor((maxy - miny) / step) + 1
  local k = math.max(1, math.ceil(math.max(cols, lines) / MAX_SIDE))
  local outline = math.max(cols, lines) * step > OUTLINE_SQM
  local w, h = math.ceil(cols / k), math.ceil(lines / k)
  local grid = {}
  for _, r in ipairs(area.rows) do
    local y = floor((r[1] - miny) / step / k)
    for x = r[2], r[3], step do grid[y * w + floor((x - minx) / step / k)] = true end
  end
  local px = {}
  for y = 0, h - 1 do
    for x = 0, w - 1 do
      local i = y * w + x
      if not grid[i] then
        px[#px + 1] = '\0'
      else
        local edge = x == 0 or y == 0 or x == w - 1 or y == h - 1 or not grid[i - 1] or not grid[i + 1] or not grid[i - w] or not grid[i + w]
        px[#px + 1] = edge and '\2' or outline and '\0' or '\1'
      end
    end
  end
  return { data = png(w, h, concat(px)), w = w, h = h, sqm = step * k, x0 = minx - step / 2, y0 = miny - step / 2 }
end

local function viewedFloor()
  local ok, cam = pcall(function() return minimap:getCameraPosition() end)
  return ok and cam and cam.z or 7
end

-- the image sits where its area is; its size follows the zoom of the minimap
local function place(s)
  local z, scale = viewedFloor(), minimap:getScale()
  s.image:resize(math.max(1, floor(s.w * s.sqm * scale + 0.5)), math.max(1, floor(s.h * s.sqm * scale + 0.5)))
  minimap:centerInPosition(s.image, { x = floor(s.x0 + s.w * s.sqm / 2), y = floor(s.y0 + s.h * s.sqm / 2), z = z })
  minimap:centerInPosition(s.label, { x = s.cx, y = s.cy, z = z })
end

local function forget(key)
  local s = shown[key]
  if not s then return end
  if s.timer then Addon.cancel(s.timer) end
  s.image:destroy()
  s.label:destroy()
  shown[key] = nil
end

local function fade(key)
  local s = shown[key]
  if not s then return end
  local age = g_clock.millis() - s.at
  if age >= SHOW_MS then return forget(key) end
  local opacity = 1 - 0.6 * age / SHOW_MS
  s.image:setOpacity(opacity)
  s.label:setOpacity(opacity)
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
  local img = paint(area)
  local image = g_ui.createWidget('UIWidget', minimap)
  image:setPhantom(true)
  image:setFocusable(false)
  pcall(function() minimap:moveChildToIndex(image, 1) end)
  image:setImageSourceBase64(base64(img.data))
  pcall(function() image:setImageSmooth(false) end)
  local label = g_ui.createWidget('UILabel', minimap)
  label:setPhantom(true)
  label:setColor('#ffd23c')
  label:setTextAutoResize(true)
  local s = { image = image, label = label, name = tostring(args.target or '?'), at = g_clock.millis(), x0 = img.x0, y0 = img.y0,
              w = img.w, h = img.h, sqm = img.sqm, cx = tonumber(args.x) or floor(img.x0), cy = tonumber(args.y) or floor(img.y0) }
  shown[key] = s
  place(s)
  fade(key)
  Addon.log(('%s: %dx%d px, %d bytes, %d ms'):format(s.name, img.w, img.h, #img.data, g_clock.millis() - started))
end

local function onZoom()
  for _, s in pairs(shown) do place(s) end
end

local lastFloor
local function onCamera(_, pos)
  if not pos or pos.z == lastFloor then return end
  lastFloor = pos.z
  onZoom()
end

function init()
  minimap = Addon.minimap()
  Addon.on('exiva', show)
  if minimap then connect(minimap, { onZoomChange = onZoom, onCameraPositionChange = onCamera }) end
end

function terminate()
  for key in pairs(shown) do forget(key) end
  if minimap then disconnect(minimap, { onZoomChange = onZoom, onCameraPositionChange = onCamera }) end
end
