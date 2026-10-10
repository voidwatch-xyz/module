-- Starts the Voidwatch module from the bot folder, bot/_voidwatch, once per client session. MIT licence.
-- voidwatch_start.lua in a bot config runs this in the bot's scope at every bot load. The module gets the client's
-- own scope, as a module from the modules folder would; the bot adapter gets the bot's scope, new at every load.
local HOME = '/bot/_voidwatch/voidwatch/'
local G = modules._G

local function field(otmod, key)
  return otmod:match('\n%s*' .. key .. ':%s*([^\n]-)%s*\r?\n')
end

if not G.VoidwatchBoot then
  local boot = {}
  function boot.start()
    local otmod = '\n' .. g_resources.readFileContents(HOME .. 'voidwatch.otmod') .. '\n'
    local env = G.setmetatable({}, { __index = G })
    G.modules.voidwatch = env
    boot.env = env
    for script in (field(otmod, 'scripts') or ''):gmatch('[%w_%-%.]+') do
      local file = script:gsub('%.lua$', '')
      local path = HOME .. file .. '.lua'
      local chunk = G.assert(G.loadstring(g_resources.readFileContents(path), '@' .. path))
      G.setfenv(chunk, env)
      chunk()
    end
    env.Voidwatch.init()
  end
  function boot.restart()
    local env = boot.env
    boot.env = nil
    if env and env.Voidwatch then G.pcall(env.Voidwatch.terminate) end
    if G.modules.voidwatch == env then G.modules.voidwatch = nil end
    boot.start()
  end
  G.VoidwatchBoot = boot
  local ok, err = G.pcall(boot.start)
  if not ok then warn('[Voidwatch] ' .. tostring(err)) end
end

local adapter = HOME .. 'bot/voidwatch_bot.lua'
if g_resources.fileExists(adapter) then
  local ok, err = pcall(function() assert(load(g_resources.readFileContents(adapter), '@' .. adapter))() end)
  if not ok then warn('[Voidwatch] bot adapter: ' .. tostring(err)) end
end
