-- permute
-- improvisational sequencer
-- 
-- plug and play.

local App = include("lib/app")

local app = nil

function init()
  app = App.new()
  app:init()
end

function redraw()
  if app then app:redraw_screen() end
end

function key(n, z)
  if app then app:key(n, z) end
end

function enc(n, d)
  if app then app:enc(n, d) end
end

function cleanup()
  if app then app:cleanup() end
end
