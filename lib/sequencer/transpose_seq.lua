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
    function App:get_transpose_seq_layout()
        local mod_row = self:get_main_mod_row()
        local dyn_row = self:get_main_dynamic_row()
        if self:is_main_grid_128() then
            return {
                seq_top = 1,
                seq_bottom = 1,
                clock_row = 3,
                assign_row = 5,
                dyn_row = dyn_row,
                mod_row = mod_row
            }
        end
        return {
            seq_top = 1,
            seq_bottom = 8,
            clock_row = 11,
            assign_row = 13,
            dyn_row = dyn_row,
            mod_row = mod_row
        }
    end

    function App:get_transpose_seq_current_degree()
        local idx = clamp(tonumber(self.transpose_seq_step) or 1, 1, cfg.NUM_STEPS)
        local step = self.transpose_seq_steps[idx]
        if type(step) ~= "table" or not step.active then return 0 end
        return clamp((tonumber(step.degree) or 1) - 1, 0, 15)
    end

    function App:is_transpose_seq_active_for_track(track)
        return self.transpose_seq_enabled
            and self:is_track_melodic(track)
            and not not self.transpose_seq_assign[track]
    end

    function App:update_transpose_seq_clock()
        if not self.transpose_seq_enabled then return end
        local mult = clamp(tonumber(self.transpose_seq_clock_mult) or 1, 1, 8)
        local div = clamp(tonumber(self.transpose_seq_clock_div) or 4, 1, 64)
        self.transpose_seq_clock_phase = (tonumber(self.transpose_seq_clock_phase) or 0) + (mult / div)
        local hits = math.floor(self.transpose_seq_clock_phase)
        if hits > 0 then
            self.transpose_seq_clock_phase = self.transpose_seq_clock_phase - hits
            self.transpose_seq_step = ((clamp(tonumber(self.transpose_seq_step) or 1, 1, cfg.NUM_STEPS) - 1 + hits) % cfg.NUM_STEPS) +
                1
        end
    end

    function App:reset_transpose_meta_sequence()
        for s = 1, cfg.NUM_STEPS do
            self.transpose_seq_steps[s] = { active = false, degree = 1 }
        end
        for t = 1, cfg.NUM_TRACKS do
            self.transpose_seq_assign[t] = self:is_track_melodic(t)
        end
        self.transpose_seq_selected_step = 1
        self.transpose_seq_clock_mult = 1
        self.transpose_seq_clock_div = 4
        self.transpose_seq_clock_phase = 0
        self.transpose_seq_step = 1
        self.transpose_seq_step_held = {}
        self.transpose_seq_hold_start = nil
    end

    function App:apply_transpose_seq_hold_span(start_step, end_step)
        local a = clamp(tonumber(start_step) or 1, 1, cfg.NUM_STEPS)
        local b = clamp(tonumber(end_step) or a, 1, cfg.NUM_STEPS)
        local lo = math.min(a, b)
        local hi = math.max(a, b)
        local anchor = self.transpose_seq_steps[a] or { active = false, degree = 1 }
        local degree = clamp(tonumber(anchor.degree) or 1, 1, 16)
        for s = lo, hi do
            self.transpose_seq_steps[s] = { active = true, degree = degree }
        end
    end

    function App:draw_transpose_seq_dynamic_row(layout)
        local step_idx = clamp(tonumber(self.transpose_seq_selected_step) or 1, 1, cfg.NUM_STEPS)
        local step = self.transpose_seq_steps[step_idx] or { active = false, degree = 1 }
        local dyn_row = layout.dyn_row
        local max_degree = (layout.seq_bottom > layout.seq_top) and 8 or 16
        local selected_degree = clamp(tonumber(step.degree) or 1, 1, max_degree)
        for x = 1, 16 do
            local lv = 1
            if x <= max_degree then
                lv = (x == selected_degree) and 15 or 2
            end
            self:grid_led(x, dyn_row, lv)
        end
    end

    function App:draw_transpose_takeover()
        local layout = self:get_transpose_seq_layout()
        local seq_step = clamp(tonumber(self.transpose_seq_step) or 1, 1, cfg.NUM_STEPS)
        local selected_step = clamp(tonumber(self.transpose_seq_selected_step) or 1, 1, cfg.NUM_STEPS)
        local scale = cfg.SCALES[self.scale_type] or cfg.SCALES.chromatic
        local scale_len = math.max(1, #scale)

        if layout.seq_top == layout.seq_bottom then
            for s = 1, cfg.NUM_STEPS do
                if ((s - 1) % 4) == 0 then
                    self:grid_led(s, layout.seq_top, 1)
                end
            end
        else
            for s = 1, cfg.NUM_STEPS do
                for row = layout.seq_top, layout.seq_bottom do
                    local degree = self:get_transpose_seq_degree_for_row(layout.seq_top, layout.seq_bottom, row)
                    local lv = 0
                    if ((s - 1) % 4) == 0 then lv = math.max(lv, 1) end
                    if ((degree - 1) % scale_len) == 0 then lv = math.max(lv, 2) end
                    if lv > 0 then self:grid_led(s, row, lv) end
                end
            end
        end

        if layout.seq_top == layout.seq_bottom then
            for s = 1, cfg.NUM_STEPS do
                local data = self.transpose_seq_steps[s] or { active = false, degree = 1 }
                local lv = data.active and 8 or 2
                if s == selected_step then lv = math.max(lv, 12) end
                if s == seq_step and self.playing then lv = data.active and 15 or 6 end
                self:grid_led(s, layout.seq_top, lv)
            end
        else
            for s = 1, cfg.NUM_STEPS do
                local data = self.transpose_seq_steps[s] or { active = false, degree = 1 }
                if data.active then
                    local row = self:get_transpose_seq_row_for_degree(layout.seq_top, layout.seq_bottom, data.degree)
                    local lv = (s == selected_step) and 12 or 8
                    if s == seq_step and self.playing then lv = 15 end
                    self:grid_led(s, row, lv)
                elseif s == selected_step then
                    self:grid_led(s, layout.seq_bottom, 4)
                end

                if s == seq_step and self.playing and not data.active then
                    self:grid_led(s, layout.seq_bottom, 6)
                end
            end
        end

        local div_col = self:get_speed_column_for_ratio(self.transpose_seq_clock_mult, self.transpose_seq_clock_div)
        for x = 1, 16 do
            local mult, div = self:get_speed_ratio_for_column(x)
            local lv = self:is_power_of_two_speed_ratio(mult, div) and 2 or 0
            if x == div_col then lv = 12 end
            self:grid_led(x, layout.clock_row, lv)
        end

        for x = 1, 16 do
            if x <= cfg.NUM_TRACKS then
                local melodic = self:is_track_melodic(x)
                if not melodic then
                    self:grid_led(x, layout.assign_row, 1)
                else
                    local lv = self.transpose_seq_assign[x] and 10 or 2
                    if self.sel_track == x then
                        lv = self.transpose_seq_assign[x] and 15 or 4
                    end
                    self:grid_led(x, layout.assign_row, lv)
                end
            end
        end
        self:grid_led(16, layout.assign_row, self.pending_meta_reset_on_beat and 12 or 7)

        self:draw_transpose_seq_dynamic_row(layout)
        self:draw_mod_row()
    end

    function App:handle_transpose_takeover_event(x, y, z)
        local layout = self:get_transpose_seq_layout()
        if y == layout.mod_row then
            self:handle_mod_row(x, z)
            return
        end
        if y >= layout.seq_top and y <= layout.seq_bottom then
            if z == 0 then
                self.transpose_seq_step_held[x] = nil
                if self.transpose_seq_hold_start == x then self.transpose_seq_hold_start = nil end
                return
            end
        end
        if z ~= 1 then return end

        if y == layout.dyn_row then
            local step_idx = clamp(tonumber(self.transpose_seq_selected_step) or 1, 1, cfg.NUM_STEPS)
            local step = self.transpose_seq_steps[step_idx] or { active = false, degree = 1 }
            local max_degree = (layout.seq_bottom > layout.seq_top) and 8 or 16
            if x <= max_degree then
                step.active = true
                step.degree = clamp(x, 1, max_degree)
                self.transpose_seq_steps[step_idx] = step
            end
            self:request_redraw()
            return
        end

        if y >= layout.seq_top and y <= layout.seq_bottom then
            if self.mod_held[cfg.MOD.CLEAR] then
                if self.mod_held[cfg.MOD.SHIFT] then
                    self:reset_transpose_meta_sequence()
                else
                    local step = self.transpose_seq_steps[x] or { active = false, degree = 1 }
                    step.active = false
                    self.transpose_seq_steps[x] = step
                    self.transpose_seq_selected_step = x
                end
                self:request_redraw()
                return
            end

            self.transpose_seq_step_held[x] = true
            local step = self.transpose_seq_steps[x] or { active = false, degree = 1 }
            if self.transpose_seq_hold_start
                and self.transpose_seq_hold_start ~= x
                and self.transpose_seq_step_held[self.transpose_seq_hold_start] then
                self:apply_transpose_seq_hold_span(self.transpose_seq_hold_start, x)
                self.transpose_seq_selected_step = x
                self:request_redraw()
                return
            end
            self.transpose_seq_hold_start = x

            self.transpose_seq_selected_step = x
            if layout.seq_top == layout.seq_bottom then
                step.active = true
            else
                step.active = true
                step.degree = self:get_transpose_seq_degree_for_row(layout.seq_top, layout.seq_bottom, y)
            end
            self.transpose_seq_steps[x] = step
            self:request_redraw()
            return
        end

        if y == layout.clock_row then
            local mult, div = self:get_speed_ratio_for_column(x)
            self.transpose_seq_clock_mult = mult
            self.transpose_seq_clock_div = div
            self.transpose_seq_clock_phase = 0
            self:flash_status("meta clock", self:get_speed_ratio_label(mult, div), 0.35)
            self:request_redraw()
            return
        end

        if y == layout.assign_row and x == 16 then
            self:queue_meta_reset_on_next_beat()
            self:flash_status("meta reset", "next beat", 0.35)
            self:request_redraw()
            return
        end

        if y == layout.assign_row and x <= cfg.NUM_TRACKS then
            self.sel_track = x
            if self:is_track_melodic(x) then
                self.transpose_seq_assign[x] = not self.transpose_seq_assign[x]
            end
            self:request_redraw()
            self:request_aux_redraw()
            return
        end
    end

end

return M
