-- Orion-OTS server adapter. It runs only in the Orion client, which the module knows by its login address.
-- Orion never sends the blessings to the client, so getBlessings() always reads 0. The server's text reply to
-- !bless is the one source: whoever says it, the player or a bot, the adapter reads the reply. It never says !bless
-- itself, because that buys. A death means a relog, so every login starts unknown.
local FAIL = { 'not enough', "don't have enough", 'do not have enough', 'cannot', "can't", 'you need' }
local blessed, owner

local function has(text, words)
  for _, w in ipairs(words) do if text:find(w, 1, true) then return true end end
  return false
end

local function onText(mode, text)
  if type(text) ~= 'string' then return end
  local low = text:lower()
  if not low:find('bless', 1, true) then return end
  owner, blessed = g_game.getCharacterName(), not has(low, FAIL)
end

local function onStart() owner, blessed = nil, nil end

Voidwatch.register({
  id = 'orion-ots', name = 'Orion-OTS', version = '3',
  match = { hosts = { 'orion-ots.pl' } },
  provides = { 'server', 'blessed' },
  fields = {
    server = function() return 'orion' end,
    blessed = function() if owner == g_game.getCharacterName() then return blessed end end,
  },
  init = function() connect(g_game, { onTextMessage = onText, onGameStart = onStart }) end,
  terminate = function() disconnect(g_game, { onTextMessage = onText, onGameStart = onStart }) end,
})
