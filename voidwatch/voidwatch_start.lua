-- Voidwatch start file, MIT licence. When Voidwatch sits in the bot folder, bot/_voidwatch/voidwatch, copy this file
-- into the folder of the bot config you use. The bot runs every .lua file there, and this one starts Voidwatch.
local boot = '/bot/_voidwatch/voidwatch/boot.lua'
if g_resources.fileExists(boot) then
  local ok, err = pcall(function() assert(load(g_resources.readFileContents(boot), '@' .. boot))() end)
  if not ok then warn('[Voidwatch] ' .. tostring(err)) end
else
  warn('[Voidwatch] ' .. boot .. ' is missing: copy the voidwatch folder into bot/_voidwatch')
end
