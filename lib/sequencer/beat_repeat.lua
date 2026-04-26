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
    function App:get_beat_repeat_length_for_column(x)
        if self.beat_repeat_mode == "one-handed" then
            local map = (self.beat_repeat_direction == "l<-r")
                and {
                    [13] = 8,
                    [14] = 4,
                    [15] = 2,
                    [16] = 1
                }
                or {
                    [13] = 1,
                    [14] = 2,
                    [15] = 4,
                    [16] = 8
                }
            return map[x]
        end
        if x >= 1 and x <= 16 then
            return (self.beat_repeat_direction == "l<-r") and (17 - x) or x
        end
        return nil
    end

    function App:get_beat_repeat_column_for_length(len)
        local rpt_len = tonumber(len) or 0
        if self.beat_repeat_mode == "one-handed" then
            local map = (self.beat_repeat_direction == "l<-r")
                and {
                    [1] = 16,
                    [2] = 15,
                    [4] = 14,
                    [8] = 13
                }
                or {
                    [1] = 13,
                    [2] = 14,
                    [4] = 15,
                    [8] = 16
                }
            return map[rpt_len]
        end
        if rpt_len >= 1 and rpt_len <= 16 then
            return (self.beat_repeat_direction == "l<-r") and (17 - rpt_len) or rpt_len
        end
        return nil
    end

    function App:reset_step_select_repeat()
        self.beat_repeat_select_start = nil
        self.beat_repeat_select_end = nil
        self.beat_repeat_select_armed = false
        self.beat_repeat_select_active = false
        self.beat_repeat_select_cycle = 0
    end

    function App:get_step_select_repeat_spec()
        local start_step = tonumber(self.beat_repeat_select_start)
        local end_step = tonumber(self.beat_repeat_select_end)
        if not start_step or not end_step then return nil end
        local direction = (end_step >= start_step) and 1 or -1
        local len = math.abs(end_step - start_step) + 1
        return start_step, end_step, direction, len
    end

    function App:get_step_select_repeat_target_step()
        local start_step, _, direction, len = self:get_step_select_repeat_spec()
        if not start_step then return nil end
        local idx = (tonumber(self.beat_repeat_select_cycle) or 0) % len
        return start_step + (idx * direction)
    end

    function App:get_step_select_repeat_cycle_for_step(step)
        local start_step, _, direction, len = self:get_step_select_repeat_spec()
        if not start_step then return 0 end
        local s = clamp(tonumber(step) or start_step, 1, cfg.NUM_STEPS)
        local idx = (direction == 1) and (s - start_step) or (start_step - s)
        if idx < 0 or idx >= len then return 0 end
        return idx
    end

    function App:is_step_select_repeat_hold_active()
        if self.mod_held[cfg.MOD.BEAT_RPT] then return true end
        local held = self.dynamic_row_held or {}
        local start_step = tonumber(self.beat_repeat_select_start)
        local end_step = tonumber(self.beat_repeat_select_end)
        if start_step and held[start_step] then return true end
        if end_step and held[end_step] then return true end
        return false
    end

    function App:clear_step_select_repeat_state()
        self.beat_repeat_len = 0
        self.beat_repeat_excluded = {}
        self:reset_step_select_repeat()
        self.dynamic_row_held = {}
    end

    function App:update_repeat_window()
        if self.beat_repeat_mode == "step-select" then
            local start_step, _, _, len = self:get_step_select_repeat_spec()
            if not start_step then
                self.beat_repeat_select_armed = false
                self.beat_repeat_select_active = false
                self.beat_repeat_select_cycle = 0
                return 0
            end

            local current_step = self:get_track_step(1)
            if not self.beat_repeat_select_active then
                if self.beat_repeat_select_armed and current_step == start_step then
                    self.beat_repeat_select_active = true
                    self.beat_repeat_select_armed = false
                    self.beat_repeat_select_cycle = 0
                else
                    return len
                end
            end

            local target_step = self:get_step_select_repeat_target_step()
            if target_step then
                for t = 1, cfg.NUM_TRACKS do
                    if not self.beat_repeat_excluded[t] then
                        self:set_track_counter_to_step(t, target_step)
                    end
                end
            end
            return len
        end

        local rpt_len = tonumber(self.beat_repeat_len) or 0
        if rpt_len > 0 then
            if self.beat_repeat_start == 0 then
                self.beat_repeat_start = 1
                self.beat_repeat_cycle = 0
                for t = 1, cfg.NUM_TRACKS do
                    self.beat_repeat_anchor[t] = tonumber(self.track_steps[t]) or 1
                end
            end
            for t = 1, cfg.NUM_TRACKS do
                if not self.beat_repeat_excluded[t] then
                    local anchor = tonumber(self.beat_repeat_anchor[t]) or (tonumber(self.track_steps[t]) or 1)
                    self.track_steps[t] = anchor + (self.beat_repeat_cycle % rpt_len)
                end
            end
        else
            self.beat_repeat_start = 0
            self.beat_repeat_cycle = 0
            self.beat_repeat_anchor = {}
        end
        return rpt_len
    end

end

return M
