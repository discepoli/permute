local cfg = include("lib/config")
local param_setup = include("lib/params")
local icons = include("lib/icons")
local musicutil = require("musicutil")

local M = {}

M.clamp = (util and util.clamp) or function(v, lo, hi)
    if v == nil then return lo end
    if v < lo then return lo end
    if v > hi then return hi end
    return v
end

function M.now_ms()
    return math.floor((util.time() or 0) * 1000)
end

function M.deep_copy_table(t)
    local out = {}
    for k, v in pairs(t) do
        if type(v) == "table" then
            out[k] = M.deep_copy_table(v)
        else
            out[k] = v
        end
    end
    return out
end

function M.ensure_dir(path)
    if util and util.make_dir then
        util.make_dir(path)
    else
        os.execute("mkdir -p '" .. path .. "'")
    end
end

M.SCALE_DEGREE_INDICES = {
    diatonic = { 1, 2, 3, 4, 5, 6, 7 },
    pentatonic = { 1, 2, 3, 4, 5 },
    lightbath = { 1, 2, 3, 4 }
}

M.ARC_VARIANCE_MODES = cfg.ARC_VARIANCE_MODES
M.ARC_CADENCE_SHAPES = cfg.ARC_CADENCE_SHAPES
M.ARC_DELTA_THRESHOLDS = cfg.ARC_DELTA_THRESHOLDS
M.TRACK_SELECT_MOD = cfg.TRACK_SELECT_MOD
M.cfg = cfg
M.param_setup = param_setup
M.icons = icons
M.musicutil = musicutil

return M
