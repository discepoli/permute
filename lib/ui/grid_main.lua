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
    function App:handle_mod_row(x, z)
        if x == cfg.MOD.TAKEOVER and z == 1 then
            if self.mod_held[TRACK_SELECT_MOD] then
                if not self.sel_track then self.sel_track = 1 end
                self.takeover_mode = true
                self.transpose_takeover_mode = not self.transpose_takeover_mode
                self.transpose_seq_enabled = self.transpose_takeover_mode
                self:flash_mod_applied(cfg.MOD.TAKEOVER, self.transpose_takeover_mode and "tr seq" or "takeover")
            elseif self.mod_held[cfg.MOD.SHIFT] then
                self.realtime_play_mode = not self.realtime_play_mode
                self:clear_realtime_row_holds()
                if self.realtime_play_mode then
                    self.takeover_mode = false
                    self.transpose_takeover_mode = false
                    self.transpose_seq_enabled = false
                end
                self:flash_mod_applied(cfg.MOD.TAKEOVER, self.realtime_play_mode and "play on" or "play off")
            else
                if not self.sel_track then self.sel_track = 1 end
                self.takeover_mode = not self.takeover_mode
                if not self.takeover_mode then self.transpose_takeover_mode = false end
                self:flash_mod_applied(cfg.MOD.TAKEOVER, self.takeover_mode and "on" or "off")
            end
            self:request_redraw()
            return
        end

        if z == 0 and self.mod_shortcut_consumed[x] then
            self.mod_shortcut_consumed[x] = nil
            self:request_redraw()
            return
        end

        if z == 1 then
            if x == cfg.MOD.SPICE and self.mod_held[cfg.MOD.SHIFT] then
                self.mod_shortcut_consumed[x] = true
                self:flash_mod_applied(cfg.MOD.SPICE, self:undo_last_action() and "undo" or "empty")
                self:request_redraw()
                return
            end

            if x == cfg.MOD.BEAT_RPT and self.mod_held[cfg.MOD.SHIFT] then
                self.mod_shortcut_consumed[x] = true
                self:flash_mod_applied(cfg.MOD.BEAT_RPT, self:redo_last_action() and "redo" or "empty")
                self:request_redraw()
                return
            end

            if x == cfg.MOD.TEMP then
                local now = now_ms()
                local use_fill = self:is_temp_button_fill_mode()
                local latched = use_fill and self.fill_latched or self.temp_latched

                if latched then
                    if use_fill then
                        self.fill_latched = false
                        self.fill_active = false
                        self.fill_applied = false
                    else
                        self.temp_latched = false
                        self:clear_temp_steps()
                    end
                    self.mod_held[x] = nil
                    self.last_mod_pressed = x
                    self:flash_mod_applied(x, "off")
                    self:request_redraw()
                    self:request_aux_redraw()
                    return
                end

                local last_tap = self.mod_last_tap_time[x] or 0
                if now - last_tap <= self.mod_double_tap_ms then
                    if use_fill then
                        self.fill_latched = true
                        self.fill_active = true
                        self.fill_applied = true
                    else
                        self.temp_latched = true
                        self.temp_steps = {}
                    end
                    self.mod_held[x] = nil
                    self.mod_last_tap_time[x] = 0
                    self.last_mod_pressed = x
                    self:flash_mod_applied(x, "latched")
                    self:request_redraw()
                    self:request_aux_redraw()
                    return
                end

                self.mod_last_tap_time[x] = now
            end

            if self.mod_held[cfg.MOD.CLEAR] and self.mod_held[cfg.MOD.SHIFT] then
                if x ~= cfg.MOD.CLEAR and x ~= cfg.MOD.SHIFT then
                    if x == cfg.MOD.SPICE or x == cfg.MOD.TEMP or x == cfg.MOD.RATIOS then
                        self:push_undo_state()
                    end
                    self:clear_modifier_all_tracks(x)
                end
            elseif self.mod_held[cfg.MOD.CLEAR] and self.sel_track then
                if x ~= cfg.MOD.CLEAR then
                    if x == cfg.MOD.SPICE or x == cfg.MOD.TEMP or x == cfg.MOD.RATIOS then
                        self:push_undo_state()
                    end
                    self:clear_modifier_for_track(x, self.sel_track)
                end
            end
            self.mod_held[x] = true
            self.last_mod_pressed = x
            if x == cfg.MOD.TEMP then self.temp_steps = {} end
            if x == cfg.MOD.RAND_NOTES then self.rand_notes_rolled = false end
            if x == cfg.MOD.RAND_STEPS then self.rand_steps_shuffled = false end
            if (x == cfg.MOD.START and self.mod_held[cfg.MOD.END_STEP]) or (x == cfg.MOD.END_STEP and self.mod_held[cfg.MOD.START]) then self.speed_mode = true end
            if x == cfg.MOD.TEMP and self:is_temp_button_fill_mode() then
                self.fill_active = true
                self.fill_applied = true
            end
            if x == cfg.MOD.TAKEOVER and self.sel_track then self.takeover_mode = true end
        else
            if x == cfg.MOD.TEMP and not self:is_temp_button_fill_mode() and self.temp_latched then
                self:request_redraw()
                return
            end
            if x == cfg.MOD.TEMP and self:is_temp_button_fill_mode() and self.fill_latched then
                self:request_redraw()
                return
            end

            self.mod_held[x] = nil
            if x == cfg.MOD.TEMP and not self:is_temp_button_fill_mode() then self:clear_temp_steps() end
            if x == cfg.MOD.START or x == cfg.MOD.END_STEP then self.speed_mode = false end
            if x == cfg.MOD.TAKEOVER and not self.takeover_mode then
                self.transpose_takeover_mode = false
            end
            if x == cfg.MOD.TEMP and self:is_temp_button_fill_mode() then
                self.fill_active = false
                self.fill_applied = self.fill_latched
            end
            if x == cfg.MOD.RAND_NOTES then self.rand_notes_rolled = false end
            if x == cfg.MOD.RAND_STEPS then self.rand_steps_shuffled = false end
            if x == cfg.MOD.BEAT_RPT then
                if self.beat_repeat_mode == "step-select" then
                    if not self:is_step_select_repeat_hold_active() then
                        self:clear_step_select_repeat_state()
                    end
                else
                    self.beat_repeat_len = 0
                    self.beat_repeat_excluded = {}
                    self:reset_step_select_repeat()
                    self.dynamic_row_held = {}
                end
            end
        end
        self:request_redraw()
        self:request_aux_redraw()
    end

    function App:handle_dynamic_row(x, z)
        self.dynamic_row_held = self.dynamic_row_held or {}
        if z == 0 then
            local start_step = tonumber(self.beat_repeat_select_start)
            local end_step = tonumber(self.beat_repeat_select_end)
            self.dynamic_row_held[x] = nil
            if self.beat_repeat_mode == "step-select" and (x == start_step or x == end_step) then
                if not self:is_step_select_repeat_hold_active() then
                    self:clear_step_select_repeat_state()
                end
            end
            self:request_redraw()
            self:request_aux_redraw()
            return
        end

        if z == 1 then
            self.dynamic_row_held[x] = true
            local should_push_undo = false
            if self.mod_held[cfg.MOD.SHIFT] and self.mod_held[cfg.MOD.RATIOS] then
                should_push_undo = x > 8
            elseif self.mod_held[cfg.MOD.RATIOS] then
                should_push_undo = true
            elseif self.held then
                should_push_undo = true
            end
            if should_push_undo then self:push_undo_state() end

            local applied_value = nil
            local applied_mod = self:get_active_mod_id()

            if self.mod_held[cfg.MOD.SHIFT] and self.mod_held[cfg.MOD.RATIOS] then
                if x <= 8 then
                    self:save_to_slot(x)
                    applied_value = "save " .. tostring(x)
                else
                    self:load_from_slot(x - 8)
                    applied_value = "load " .. tostring(x - 8)
                end
            elseif self.mod_held[cfg.MOD.SHIFT] and self.mod_held[cfg.MOD.RAND_STEPS] and self.sel_track then
                self.track_rand_gate_prob[self.sel_track] = self:rand_prob_from_column(x)
                applied_value = tostring(math.floor((self.track_rand_gate_prob[self.sel_track] * 100) + 0.5)) .. "%"
            elseif self.mod_held[cfg.MOD.SHIFT] and self.mod_held[cfg.MOD.RAND_NOTES] and self.sel_track then
                self.track_rand_pitch_prob[self.sel_track] = self:rand_prob_from_column(x)
                self.track_rand_pitch_span[self.sel_track] = x - 1
                applied_value = tostring(math.floor((self.track_rand_pitch_prob[self.sel_track] * 100) + 0.5)) ..
                    "%/" .. tostring(self.track_rand_pitch_span[self.sel_track])
            elseif self.mod_held[cfg.MOD.RATIOS] then
                if x <= 8 then
                    self:set_ratio_position(x)
                else
                    self:set_ratio_cycle(x - 8)
                end
                applied_value = self:get_ratio_label()
            elseif self.mod_held[cfg.MOD.OCTAVE] and self.sel_track then
                self.tracks[self.sel_track].octave = x - 8
                applied_value = tostring(self.tracks[self.sel_track].octave)
            elseif self.mod_held[cfg.MOD.TRANSPOSE] and self.sel_track then
                self.track_transpose[self.sel_track] = x - 8
                applied_value = tostring(self.track_transpose[self.sel_track])
            elseif self.mod_held[cfg.MOD.RAND_NOTES] and not self.mod_held[cfg.MOD.RAND_STEPS] and self.sel_track then
                self:apply_random_notes(self.sel_track, x)
                self.rand_notes_rolled = true
                applied_value = tostring(x)
            elseif self.mod_held[cfg.MOD.RAND_STEPS] and not self.mod_held[cfg.MOD.RAND_NOTES] and self.sel_track then
                self:apply_random_steps(self.sel_track, x)
                self.rand_steps_shuffled = true
                applied_value = tostring(x)
            elseif self.mod_held[cfg.MOD.RAND_NOTES] and self.mod_held[cfg.MOD.RAND_STEPS] and self.sel_track then
                self:apply_random_notes(self.sel_track, x)
                self:apply_random_steps(self.sel_track, x)
                self.rand_notes_rolled = true
                self.rand_steps_shuffled = true
                applied_value = tostring(x)
            elseif self.mod_held[cfg.MOD.BEAT_RPT] then
                if self.beat_repeat_mode == "step-select" then
                    local start_step = tonumber(self.beat_repeat_select_start)
                    local end_step = tonumber(self.beat_repeat_select_end)
                    local start_held = start_step and self.dynamic_row_held[start_step] or false
                    if start_step and start_held and x ~= start_step then
                        local next_end = x
                        local is_adjacent = math.abs(x - start_step) == 1
                        if is_adjacent and end_step == x then
                            next_end = start_step
                        end
                        self.beat_repeat_select_end = next_end
                        local _, _, _, len = self:get_step_select_repeat_spec()
                        self.beat_repeat_len = len or 0
                        if self.beat_repeat_select_active then
                            self.beat_repeat_select_cycle = self:get_step_select_repeat_cycle_for_step(self:get_track_step(1))
                            self.beat_repeat_select_armed = false
                        else
                            self.beat_repeat_select_armed = true
                            self.beat_repeat_select_active = false
                            self.beat_repeat_select_cycle = 0
                        end
                        applied_value = tostring(self.beat_repeat_select_start) .. "-" .. tostring(next_end)
                    elseif (self.beat_repeat_select_start == nil) or (self.beat_repeat_select_start and self.beat_repeat_select_end) then
                        self.beat_repeat_select_start = x
                        self.beat_repeat_select_end = nil
                        self.beat_repeat_select_armed = false
                        self.beat_repeat_select_active = false
                        self.beat_repeat_select_cycle = 0
                        self.beat_repeat_len = 0
                        applied_value = tostring(x) .. "-?"
                    else
                        self.beat_repeat_select_end = x
                        local _, _, _, len = self:get_step_select_repeat_spec()
                        self.beat_repeat_select_armed = true
                        self.beat_repeat_select_active = false
                        self.beat_repeat_select_cycle = 0
                        self.beat_repeat_len = len or 0
                        applied_value = tostring(self.beat_repeat_select_start) .. "-" .. tostring(x)
                    end
                else
                    local next_len = self:get_beat_repeat_length_for_column(x)
                    if next_len then
                        self.beat_repeat_len = (self.beat_repeat_len == next_len) and 0 or next_len
                        applied_value = tostring(self.beat_repeat_len)
                    end
                end
            elseif self.speed_mode then
                if self.sel_track then
                    local mult, div = self:get_speed_ratio_for_column(x)
                    self.track_clock_mult[self.sel_track] = mult
                    self.track_clock_div[self.sel_track] = div
                    applied_value = self:get_speed_ratio_label(mult, div)
                end
            elseif self.mod_held[cfg.MOD.SPICE] then
                self.spice_pending_amount = x - 8
                applied_value = tostring(self.spice_pending_amount)
            elseif self.held then
                local tr = self.tracks[self.held.t]
                if self.track_cfg[self.held.t].type == "drum" then
                    tr.vels[self.held.s] = x - 1
                elseif self.track_cfg[self.held.t].type == "poly" then
                    tr.pitches[self.held.s] = self:poly_toggle_pitch(self:poly_active_pitches(tr, self.held.s), x)
                    tr.gates[self.held.s] = (#tr.pitches[self.held.s] > 0)
                else
                    tr.pitches[self.held.s] = x
                end
            end
            if applied_mod and (applied_value or self:get_active_mod_value(applied_mod)) then
                self:flash_mod_applied(applied_mod, applied_value or self:get_active_mod_value(applied_mod))
            elseif applied_mod then
                self:flash_mod_applied(applied_mod)
            end
        end
        self:request_redraw()
        self:request_aux_redraw()
    end

    function App:is_main_grid_128()
        local dev = self.main_grid_dev
        local device = dev and dev.device
        return device and device.cols == 16 and device.rows == 8 or false
    end

    function App:get_main_mod_row()
        return self:is_main_grid_128() and 8 or cfg.MOD_ROW
    end

    function App:get_main_dynamic_row()
        return self:is_main_grid_128() and 7 or cfg.DYN_ROW
    end

    function App:get_main_overview_track_rows()
        return self:get_main_dynamic_row() - 1
    end

    function App:get_main_takeover_note_rows()
        return self:get_main_mod_row() - 1
    end

    function App:get_main_track_page_start()
        if not self:is_main_grid_128() then return 1 end
        local page_size = self:get_main_overview_track_rows()
        local selected = clamp(tonumber(self.sel_track) or 1, 1, cfg.NUM_TRACKS)
        local start = math.floor((selected - 1) / page_size) * page_size + 1
        return clamp(start, 1, math.max(1, cfg.NUM_TRACKS - page_size + 1))
    end

    function App:row_to_track(y)
        local visible_rows = self:get_main_overview_track_rows()
        if y < 1 or y > visible_rows then return nil end
        return self:get_main_track_page_start() + (visible_rows - y)
    end

    function App:track_to_row(t)
        local visible_rows = self:get_main_overview_track_rows()
        local page_start = self:get_main_track_page_start()
        local page_end = math.min(cfg.NUM_TRACKS, page_start + visible_rows - 1)
        if t < page_start or t > page_end then return nil end
        return visible_rows - (t - page_start)
    end

    function App:main_takeover_row_to_vel_level(y)
        local rows = self:get_main_takeover_note_rows()
        if rows <= 1 then return cfg.DEFAULT_VEL_LEVEL end
        local ratio = (rows - clamp(y, 1, rows)) / (rows - 1)
        return clamp(math.floor((ratio * 14) + 1 + 0.5), 1, 15)
    end

    function App:vel_level_to_main_takeover_row(level)
        local rows = self:get_main_takeover_note_rows()
        if rows <= 1 then return 1 end
        local stored = clamp(tonumber(level) or cfg.DEFAULT_VEL_LEVEL, 1, 15)
        return clamp(rows - math.floor(((stored - 1) * (rows - 1)) / 14 + 0.5), 1, rows)
    end

    function App:vel_to_midi(level)
        return clamp(level * 8 + 1, 1, 127)
    end

    function App:midi_to_vel_level(velocity)
        local midi_vel = clamp(tonumber(velocity) or self:vel_to_midi(cfg.DEFAULT_VEL_LEVEL), 0, 127)
        return clamp(math.floor(((midi_vel - 1) / 8) + 0.5), 1, 15)
    end

    function App:get_track_default_midi_velocity(track)
        local t = clamp(tonumber(track) or 1, 1, cfg.NUM_TRACKS)
        local fallback = self:vel_to_midi(cfg.DEFAULT_VEL_LEVEL)
        return clamp(tonumber((self.track_default_vel or {})[t]) or fallback, 0, 127)
    end

    function App:get_track_default_vel_level(track)
        return self:midi_to_vel_level(self:get_track_default_midi_velocity(track))
    end

    function App:draw_dynamic_row()
        local dyn_row = self:get_main_dynamic_row()
        if self.held and not self:any_mod_active() and not self.takeover_mode then
            local tr = self.tracks[self.held.t]
            if self.track_cfg[self.held.t].type == "drum" then
                local v = tr.vels[self.held.s]
                for x = 1, 16 do self:grid_led_main(x, dyn_row, (x - 1) <= v and 10 or 2) end
            else
                local p = tr.pitches[self.held.s]
                local scale = cfg.SCALES[self.scale_type] or cfg.SCALES.chromatic
                for x = 1, 16 do
                    local is_root = ((x - 1) % #scale) == 0
                    local is_on = false
                    if self.track_cfg[self.held.t].type == "poly" then is_on = self:poly_has_pitch(p, x) else is_on = (x == p) end
                    if is_on then
                        self:grid_led_main(x, dyn_row, 15)
                    elseif is_root then
                        self:grid_led_main(x, dyn_row, 5)
                    else
                        self:grid_led_main(x, dyn_row, 2)
                    end
                end
            end
            return
        end

        if self.mod_held[cfg.MOD.OCTAVE] and self.sel_track then
            local oct = self.tracks[self.sel_track].octave
            for x = 1, 16 do
                local o = x - 8
                if o == oct then
                    self:grid_led_main(x, dyn_row, 15)
                elseif x == 8 then
                    self:grid_led_main(x, dyn_row, 5)
                else
                    self:grid_led_main(x, dyn_row, 2)
                end
            end
            return
        end

        if self.mod_held[cfg.MOD.TRANSPOSE] then
            local trans = clamp(tonumber(self.track_transpose[self.sel_track or 1]) or 0, -7, 8)
            for x = 1, 16 do
                local o = x - 8
                if o == trans then
                    self:grid_led_main(x, dyn_row, 15)
                elseif x == 8 then
                    self:grid_led_main(x, dyn_row, 5)
                else
                    self:grid_led_main(x, dyn_row, 2)
                end
            end
            return
        end

        if self.mod_held[cfg.MOD.SHIFT] and self.mod_held[cfg.MOD.RAND_STEPS] and self.sel_track then
            local col = self:rand_column_from_prob(self.track_rand_gate_prob[self.sel_track])
            for x = 1, 16 do
                if x <= col then
                    self:grid_led_main(x, dyn_row, x == col and 15 or 10)
                else
                    self:grid_led_main(x, dyn_row, 2)
                end
            end
            return
        end

        if self.mod_held[cfg.MOD.SHIFT] and self.mod_held[cfg.MOD.RAND_NOTES] and self.sel_track then
            local col = clamp((tonumber(self.track_rand_pitch_span[self.sel_track]) or 0) + 1, 1, 16)
            for x = 1, 16 do
                if x <= col then
                    self:grid_led_main(x, dyn_row, x == col and 15 or 10)
                else
                    self:grid_led_main(x, dyn_row, 2)
                end
            end
            return
        end

        if self.mod_held[cfg.MOD.RAND_NOTES] or self.mod_held[cfg.MOD.RAND_STEPS] then
            for x = 1, 16 do self:grid_led_main(x, dyn_row, 2) end
            return
        end

        if self.mod_held[cfg.MOD.BEAT_RPT] then
            local rpt_len = tonumber(self.beat_repeat_len) or 0
            if self.beat_repeat_mode == "step-select" then
                local start_step = tonumber(self.beat_repeat_select_start)
                local end_step = tonumber(self.beat_repeat_select_end)
                local lo = nil
                local hi = nil
                if start_step and end_step then
                    lo = math.min(start_step, end_step)
                    hi = math.max(start_step, end_step)
                end
                local active_step = self.beat_repeat_select_active and self:get_step_select_repeat_target_step() or nil
                for x = 1, 16 do
                    local lv = 2
                    if lo and hi and x >= lo and x <= hi then lv = 6 end
                    if x == end_step then lv = 10 end
                    if x == start_step then lv = 15 end
                    if active_step and x == active_step then lv = 12 end
                    self:grid_led_main(x, dyn_row, lv)
                end
            elseif self.beat_repeat_mode == "one-handed" then
                for x = 1, 16 do self:grid_led_main(x, dyn_row, 1) end
                for _, col in ipairs({ 13, 14, 15, 16 }) do
                    self:grid_led_main(col, dyn_row, self:get_beat_repeat_column_for_length(rpt_len) == col and 10 or 3)
                end
            else
                for x = 1, 16 do
                    self:grid_led_main(x, dyn_row, self:get_beat_repeat_length_for_column(x) <= rpt_len and 10 or 2)
                end
            end
            return
        end

        if self.mod_held[cfg.MOD.SPICE] then
            local amt = self.spice_pending_amount or 0
            for x = 1, 16 do
                local center = 8
                local sel = amt + 8
                if amt ~= 0 then
                    if (amt > 0 and x >= center and x <= sel) or (amt < 0 and x <= center and x >= sel) then
                        self:grid_led_main(x, dyn_row, 10)
                    elseif x == center then
                        self:grid_led_main(x, dyn_row, 5)
                    else
                        self:grid_led_main(x, dyn_row, 2)
                    end
                else
                    if x == center then self:grid_led_main(x, dyn_row, 5) else self:grid_led_main(x, dyn_row, 2) end
                end
            end
            return
        end

        if self.mod_held[cfg.MOD.SHIFT] and self.mod_held[cfg.MOD.RATIOS] then
            for x = 1, 16 do
                if x <= 8 then
                    self:grid_led_main(x, dyn_row, self.save_slots[x] and 8 or 3)
                else
                    self:grid_led_main(x, dyn_row, self.save_slots[x - 8] and 12 or 2)
                end
            end
            return
        end

        if self.mod_held[cfg.MOD.RATIOS] then
            for x = 1, 16 do
                if x <= 8 then
                    if x <= self.ratio_pending_cycle then
                        self:grid_led_main(x, dyn_row, x == self.ratio_pending_position and 12 or 3)
                    else
                        self:grid_led_main(x, dyn_row, 1)
                    end
                else
                    local cycle = x - 8
                    self:grid_led_main(x, dyn_row, cycle == self.ratio_pending_cycle and 15 or 3)
                end
            end
            return
        end

        if self.speed_mode then
            local mult = self.sel_track and self.track_clock_mult[self.sel_track] or 1
            local div = self.sel_track and self.track_clock_div[self.sel_track] or 1
            local selected_col = self:get_speed_column_for_ratio(mult, div)
            for x = 1, 16 do
                local x_mult, x_div = self:get_speed_ratio_for_column(x)
                local lv = self:is_power_of_two_speed_ratio(x_mult, x_div) and 2 or 0
                if x == selected_col then lv = 12 end
                self:grid_led_main(x, dyn_row, lv)
            end
            return
        end
    end

    function App:draw_mod_row()
        local mod_row = self:get_main_mod_row()
        for x = 1, 16 do
            local lv = 0
            if self:mod_active(x) then
                lv = 15
            elseif x == cfg.MOD.TAKEOVER then
                lv = self.realtime_play_mode and 12 or (self.takeover_mode and 15 or 3)
            elseif x == cfg.MOD.BEAT_RPT then
                lv = (tonumber(self.beat_repeat_len) or 0) > 0 and 10 or 3
            elseif x == cfg.MOD.SHIFT or x == cfg.MOD.CLEAR then
                lv = 0
            elseif x ~= 5 then
                lv = 3
            end
            if lv > 0 then self:grid_led_main(x, mod_row, lv) end
        end
    end

    function App:draw_takeover()
        local tr = self:ensure_track_state(self.sel_track)
        local tc = self.track_cfg[self.sel_track]
        local step_cache = self:build_arc_step_cache(self.sel_track, tr, tc)
        local fills = self.fill_patterns[self.sel_track] or {}
        local current_step = self:get_track_step(self.sel_track)
        local takeover_rows = self:get_main_takeover_note_rows()

        local lo, hi = self:get_track_bounds(tr)

        if tc.type == "drum" then
            for s = 1, cfg.NUM_STEPS do
                local in_range = s >= lo and s <= hi
                local fill = fills[s]
                local step_data = step_cache[s]
                if in_range and self:is_beat_column(s) then
                    for row = 1, takeover_rows do
                        self:grid_led_main(s, row, 2)
                    end
                end
                if step_data then
                    local top_row = self:vel_level_to_main_takeover_row(step_data.vel)
                    local manual = step_data.source == "manual"
                    local lv = manual and ((s == current_step and self.playing) and 15 or 10)
                        or ((s == current_step and self.playing) and 11 or 7)
                    if not in_range then lv = math.floor(lv / 2) end
                    for row = top_row, takeover_rows do
                        self:grid_led_main(s, row, lv)
                    end
                elseif fill then
                    local row = self:vel_level_to_main_takeover_row(fill.vel)
                    local lv = (s == current_step and self.playing) and 12 or 6
                    if not in_range then lv = math.floor(lv / 2) end
                    self:grid_led_main(s, row, lv)
                    self:grid_led_main(s, takeover_rows, math.max((s == current_step and self.playing) and 4 or 1, 3))
                else
                    if s == current_step and self.playing then
                        self:grid_led_main(s, takeover_rows, 4)
                    elseif in_range then
                        self
                            :grid_led(s, takeover_rows, 1)
                    end
                end
            end
        else
            local scale = cfg.SCALES[self.scale_type] or cfg.SCALES.chromatic
            for s = 1, cfg.NUM_STEPS do
                local is_playhead = (s == current_step and self.playing)
                local in_range = s >= lo and s <= hi
                local fill = fills[s]
                local fill_degree = fill and clamp(tonumber(fill.pitch) or 1, 1, takeover_rows) or nil
                local step_data = step_cache[s]
                if (not self.realtime_play_mode) and in_range and self:is_beat_column(s) then
                    for row = 1, takeover_rows do
                        self:grid_led_main(s, row, 2)
                    end
                end
                for row = 1, takeover_rows do
                    local degree = self:main_takeover_row_to_degree(row)
                    local is_root = ((degree - 1) % #scale) == 0
                    local is_on = false
                    local is_fill = false
                    if step_data then
                        if tc.type == "poly" then
                            is_on = self:poly_has_pitch(step_data.pitch, degree)
                        else
                            is_on = clamp(
                                tonumber(step_data.pitch) or 1, 1, takeover_rows) == degree
                        end
                    elseif fill_degree then
                        is_fill = degree == fill_degree
                    end
                    if is_on then
                        local manual = step_data.source == "manual"
                        local lv = manual and (is_playhead and 15 or 12) or (is_playhead and 11 or 7)
                        if not in_range then lv = math.floor(lv / 2) end
                        self:grid_led_main(s, row, lv)
                    elseif is_fill then
                        local lv = is_playhead and 12 or 6
                        if not in_range then lv = math.floor(lv / 2) end
                        self:grid_led_main(s, row, lv)
                    elseif is_root and in_range then
                        self:grid_led_main(s, row, 2)
                    elseif is_playhead then
                        self:grid_led_main(s, row, 1)
                    end
                end
            end
        end

        self:grid_led_main(cfg.MOD.TAKEOVER, self:get_main_mod_row(), 15)
    end

    function App:redraw_main_grid()
        local dev = self.main_grid_dev
        if not dev then return end

        dev:all(0)
        if self.takeover_mode and self.sel_track then
            if self.transpose_takeover_mode then
                self:draw_transpose_takeover()
            else
                self:draw_takeover()
                if self:is_modifier_dynamic_row_active() and not self:is_main_grid_128() then
                    self:draw_dynamic_row()
                end
                self:draw_mod_row()
            end
        else
            local page_start = self:get_main_track_page_start()
            local page_end = math.min(cfg.NUM_TRACKS, page_start + self:get_main_overview_track_rows() - 1)
            for t = page_start, page_end do
                local y = self:track_to_row(t)
                local tr = self:ensure_track_state(t)
                local tc = self.track_cfg[t]
                local scale = cfg.SCALES[self.scale_type] or cfg.SCALES.chromatic
                local scale_len = math.max(1, #scale)
                local step_cache = self:build_arc_step_cache(t, tr, tc)
                local track_playhead = self:get_track_step(t)
                local lo, hi = self:get_track_bounds(tr)

                for s = 1, cfg.NUM_STEPS do
                    local lv = 0
                    local is_playhead = (s == track_playhead and self.playing)
                    local in_range = (s >= lo and s <= hi)
                    local step_data = step_cache[s]
                    local has_manual = tr.gates[s]
                    local has_arc = step_data and step_data.source == "arc"

                    if self.realtime_play_mode and tc.type ~= "drum" and (((s - 1) % scale_len) == 0) then
                        lv = 2
                    elseif (not self.realtime_play_mode) and (s == 1 or s == 5 or s == 9 or s == 13) then
                        lv = 2
                    end
                    if has_manual then
                        lv = 10
                    elseif has_arc then
                        lv = 6
                    end
                    if self.fill_patterns[t][s] then lv = math.max(lv, 5) end
                    if tr.muted then lv = math.floor(lv / 3) end

                    if (self.mod_held[cfg.MOD.MUTE] or self.mod_held[cfg.MOD.SOLO]) and s == 1 then lv = tr.muted and 2 or 10 end
                    if self.mod_held[cfg.MOD.START] and s == tr.start_step then lv = math.max(lv, 8) end
                    if self.mod_held[cfg.MOD.END_STEP] and s == tr.end_step then lv = math.max(lv, 8) end
                    if not in_range then lv = math.floor(lv / 2) end
                    if self.sel_track == t then lv = math.max(lv, 2) end
                    if self.spice[t][s] then lv = math.max(lv, 4) end

                    if is_playhead then
                        if in_range then lv = math.max(lv + 2, 6) else lv = math.max(lv, 3) end
                    end

                    if lv > 0 then dev:led(s, y, lv) end
                end
            end
            self:draw_dynamic_row()
            self:draw_mod_row()
        end

        dev:refresh()
    end

end

return M
