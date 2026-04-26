local H = include("lib/core/util")
local cfg = H.cfg
local param_setup = H.param_setup
local icons = H.icons
local musicutil = H.musicutil
local clamp = H.clamp
local now_ms = H.now_ms
local deep_copy_table = H.deep_copy_table
local ensure_dir = H.ensure_dir
local SCALE_DEGREE_INDICES = H.SCALE_DEGREE_INDICES
local ARC_VARIANCE_MODES = H.ARC_VARIANCE_MODES
local ARC_CADENCE_SHAPES = H.ARC_CADENCE_SHAPES
local ARC_DELTA_THRESHOLDS = H.ARC_DELTA_THRESHOLDS
local TRACK_SELECT_MOD = H.TRACK_SELECT_MOD

local M = {}

function M.install(App)
    function App:set_spice_accum_bounds(min_v, max_v)
        local lo = clamp(tonumber(min_v) or cfg.SPICE_MIN, -127, 127)
        local hi = clamp(tonumber(max_v) or cfg.SPICE_MAX, -127, 127)
        if lo > hi then lo, hi = hi, lo end
        self.spice_accum_min = lo
        self.spice_accum_max = hi
    end

end

return M
