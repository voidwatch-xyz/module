-- Orion-OTS autoloot adapter. Orion's autoloot prints what went into the bags, "Autoloot: 5x platinum coin, 7x gold
-- coin.", and the gold it sends straight to the bank, "Auto-loot: 200 gp trafilo do banku (+100 gp z talentu
-- Bogactwo)." The banked sum already holds the talent's part. While it runs, its count wins over the loot messages.
local vw
-- Orion's own notices come the same way; they are no items. 0.5.2 took every part without a count for one of them
local NOTICES = { 'brak miejsca', 'czesc lupu' }
local function notice(s)
  for _, n in ipairs(NOTICES) do if s:sub(1, #n) == n then return true end end
  return false
end

local function onTextMessage(mode, text)
  if not vw or type(text) ~= 'string' then return end
  local body = text:match('^Autoloot:%s*(.+)$')
  if body then
    for part in body:gsub('%.%s*$', ''):gmatch('[^,]+') do
      local p = part:gsub('^%s+', ''):gsub('%s+$', '')
      -- "5x platinum coin", or one item without a count, "fire sword". A notice books nothing and takes back an entry
      -- that 0.5.1 booked; the list's fill ("9/13 slotow") holds digits, which no name has
      local n, name = p:match('^(%d+)x%s+(.+)$')
      name = (name or p):lower()
      if notice(name) then
        if vw.dropLoot then vw.dropLoot(name) end
      elseif name:match("^%a[%a%s'%-]*$") then
        vw.addLoot(name, tonumber(n) or 1)
      end
    end
    return
  end
  local gp = tonumber(text:match('^Auto%-loot:%s*(%d+)%s*gp'))
  if gp then vw.addLoot('gold coin', gp) end
end

Voidwatch.register({
  id = 'orion-ots-autoloot', name = 'Orion autoloot', version = '3',
  match = { hosts = { 'orion-ots.pl' } },
  provides = { 'loot' },
  init = function(api)
    vw = api
    connect(g_game, { onTextMessage = onTextMessage })
  end,
  terminate = function()
    disconnect(g_game, { onTextMessage = onTextMessage })
    vw = nil
  end,
})
