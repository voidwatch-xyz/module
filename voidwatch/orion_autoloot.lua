-- Orion-OTS autoloot adapter. Orion's autoloot prints what went into the bags, "Autoloot: 5x platinum coin, 7x gold
-- coin.", and the gold it sends straight to the bank, "Auto-loot: 200 gp trafilo do banku (+100 gp z talentu
-- Bogactwo)." The banked sum already holds the talent's part. While it runs, its count wins over the loot messages.
local vw

local function onTextMessage(mode, text)
  if not vw or type(text) ~= 'string' then return end
  local body = text:match('^Autoloot:%s*(.+)$')
  if body then
    for part in body:gsub('%.%s*$', ''):gmatch('[^,]+') do
      local p = part:gsub('^%s+', ''):gsub('%s+$', '')
      -- an item comes with its count, "5x platinum coin". Notices start the same way ("9/13 slotow", "brak miejsca w
      -- plecaku"); module 0.5.1 booked some of them as items, so a notice also takes its old entry back
      local n, name = p:match('^(%d+)x%s+(.+)$')
      if n and name:match("^%a[%a%s'%-]*$") then
        vw.addLoot(name:lower(), tonumber(n))
      elseif vw.dropLoot then
        vw.dropLoot(p:lower())
      end
    end
    return
  end
  local gp = tonumber(text:match('^Auto%-loot:%s*(%d+)%s*gp'))
  if gp then vw.addLoot('gold coin', gp) end
end

Voidwatch.register({
  id = 'orion-ots-autoloot', name = 'Orion autoloot', version = '2',
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
