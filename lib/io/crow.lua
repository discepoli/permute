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
    function App:trigger_crow(track, note)
        if not self.crow_enabled then return end
        local function out(idx)
            if not idx or idx < 1 or idx > 2 then return end
            local volts = (note - 60) / 12
            pcall(function()
                crow.output[idx].volts = volts
                crow.output[idx].action = "{to(5,0),to(0,0.01)}"
                crow.output[idx]()
            end)
        end
        if track == self.crow_track_1 then out(1) end
        if track == self.crow_track_2 then out(2) end
    end

end

return M
