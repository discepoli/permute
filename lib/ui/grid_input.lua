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
    local MOD_ID_TO_NAME = {
        [TRACK_SELECT_MOD] = "track select",
        [cfg.MOD.MUTE] = "mute",
        [cfg.MOD.SOLO] = "solo",
        [cfg.MOD.START] = "start",
        [cfg.MOD.END_STEP] = "end",
        [cfg.MOD.RAND_NOTES] = "rand notes",
        [cfg.MOD.RAND_STEPS] = "rand steps",
        [cfg.MOD.TEMP] = "temp",
        [cfg.MOD.RATIOS] = "ratios",
        [cfg.MOD.SHIFT] = "shift",
        [cfg.MOD.OCTAVE] = "octave",
        [cfg.MOD.TRANSPOSE] = "transpose",
        [cfg.MOD.TAKEOVER] = "takeover",
        [cfg.MOD.CLEAR] = "clear",
        [cfg.MOD.SPICE] = "spice",
        [cfg.MOD.BEAT_RPT] = "beat rpt",
    }
    local MOD_NAME_TO_ID = {}
    for id, name in pairs(MOD_ID_TO_NAME) do
        MOD_NAME_TO_ID[name] = id
    end
    MOD_NAME_TO_ID["fill"] = cfg.MOD.TEMP

    function App:mod_name(id)
        if id == cfg.MOD.TEMP then return self:get_temp_button_label() end
        if MOD_ID_TO_NAME[id] then return MOD_ID_TO_NAME[id] end
        return "mod " .. tostring(id)
    end

    function App:get_active_mod_id()
        if self.last_mod_pressed and self.mod_held[self.last_mod_pressed] then
            return self.last_mod_pressed
        end
        if self.last_mod_pressed == cfg.MOD.TEMP then
            if self:is_temp_button_fill_mode() and self.fill_latched then return cfg.MOD.TEMP end
            if not self:is_temp_button_fill_mode() and self.temp_latched then return cfg.MOD.TEMP end
        end
        for k, v in pairs(self.mod_held) do
            if v then return k end
        end
        if self:is_temp_button_fill_mode() then
            if self.fill_latched then return cfg.MOD.TEMP end
        elseif self.temp_latched then
            return cfg.MOD.TEMP
        end
        return nil
    end

    function App:mod_active(mod)
        if mod == cfg.MOD.TEMP then
            if self:is_temp_button_fill_mode() then return self.mod_held[mod] or self.fill_latched end
            return self.mod_held[mod] or self.temp_latched
        end
        return self.mod_held[mod]
    end

    function App:any_mod_active()
        if next(self.mod_held) then return true end
        return self.temp_latched or self.fill_latched
    end

    function App:get_active_mod_name()
        local id = self:get_active_mod_id()
        if not id then return nil end
        return self:mod_name(id)
    end

    function App:flash_mod_applied(mod_id, value)
        local name = self:mod_name(mod_id)
        self.status_message = name
        self.status_value = value and tostring(value) or nil
        self.status_mod_id = mod_id
        self.status_message_invert = true
        self.status_message_until = (util.time() or 0) + 0.25
        self:request_redraw()
        local expires_at = self.status_message_until
        clock.run(function()
            clock.sleep(0.26)
            if self.status_message_until == expires_at then
                self.status_message = nil
                self.status_value = nil
                self.status_mod_id = nil
                self.status_message_invert = false
                self:request_redraw()
            end
        end)
    end

    function App:get_active_mod_value(mod_id)
        if not mod_id then return nil end
        if mod_id == cfg.MOD.OCTAVE and self.sel_track then
            return tostring(self.tracks[self.sel_track].octave)
        elseif mod_id == cfg.MOD.TRANSPOSE then
            if self.sel_track then
                return tostring(clamp(tonumber(self.track_transpose[self.sel_track]) or 0, -7, 8))
            end
            return "0"
        elseif mod_id == cfg.MOD.BEAT_RPT then
            if self.beat_repeat_mode == "step-select" then
                local start_step = tonumber(self.beat_repeat_select_start)
                local end_step = tonumber(self.beat_repeat_select_end)
                if start_step and end_step then
                    return tostring(start_step) .. "-" .. tostring(end_step)
                elseif start_step then
                    return tostring(start_step) .. "-?"
                end
            end
            return tostring(self.beat_repeat_len or 0)
        elseif mod_id == cfg.MOD.SPICE then
            return tostring(self.spice_pending_amount or 0)
        elseif mod_id == cfg.MOD.RATIOS then
            return self:get_ratio_label()
        elseif mod_id == cfg.MOD.START and self.sel_track then
            return tostring(self.tracks[self.sel_track].start_step)
        elseif mod_id == cfg.MOD.END_STEP and self.sel_track then
            return tostring(self.tracks[self.sel_track].end_step)
        elseif mod_id == cfg.MOD.TAKEOVER then
            if self.realtime_play_mode then return "play" end
            return self.takeover_mode and "on" or "off"
        end
        return nil
    end

    function App:mod_id_from_name(name)
        return MOD_NAME_TO_ID[name]
    end

    function App:mod_icon_state()
        return {
            track_selected = self.sel_track ~= nil,
            rand_notes_rolled = self.rand_notes_rolled,
            rand_steps_shuffled = self.rand_steps_shuffled,
            fill_applied = self.fill_applied,
            temp_button_mode = self.temp_button_mode
        }
    end

    function App:is_modifier_dynamic_row_active()
        if self.mod_held[cfg.MOD.OCTAVE] and self.sel_track then return true end
        if self.mod_held[cfg.MOD.TRANSPOSE] then return true end
        if self.mod_held[cfg.MOD.RAND_NOTES] or self.mod_held[cfg.MOD.RAND_STEPS] then return true end
        if self.mod_held[cfg.MOD.BEAT_RPT] then return true end
        if self.mod_held[cfg.MOD.SPICE] then return true end
        if self.mod_held[cfg.MOD.RATIOS] then return true end
        if self.mod_held[cfg.MOD.SHIFT] and self.mod_held[cfg.MOD.RATIOS] then return true end
        if self.speed_mode then return true end
        return false
    end

    function App:is_aux_grid_device(dev)
        local device = dev and dev.device
        return device
            and device.cols == cfg.AUX_GRID_COLS
            and device.rows == cfg.AUX_GRID_ROWS
    end

    function App:attach_grid_port(port)
        if not grid or not grid.connect then return nil end
        local dev = grid.connect(port)
        if dev then
            dev.key = function(x, y, z)
                self:handle_grid_key(port, x, y, z)
            end
        end
        self.grid_ports[port] = dev
        return dev
    end

    function App:get_connected_grid_devices()
        local connected = {}
        for _, dev in pairs(self.grid_ports or {}) do
            if dev and dev.device then
                connected[#connected + 1] = dev
            end
        end
        table.sort(connected, function(a, b)
            return (a.device.port or 0) < (b.device.port or 0)
        end)
        return connected
    end

    function App:refresh_grid_assignments()
        local connected = self:get_connected_grid_devices()
        local main = nil
        local aux = nil

        if #connected == 1 then
            main = connected[1]
        elseif #connected > 1 then
            if self:is_aux_grid_device(connected[1]) then
                main = connected[1]
            else
                for _, dev in ipairs(connected) do
                    if not self:is_aux_grid_device(dev) then
                        main = dev
                        break
                    end
                end

                if not main then
                    main = connected[1]
                end
            end

            for _, dev in ipairs(connected) do
                if dev ~= main and self:is_aux_grid_device(dev) then
                    aux = dev
                    break
                end
            end
        end

        local prev_aux_port = self.aux_grid_port
        self.main_grid_dev = main
        self.aux_grid_dev = aux
        self.main_grid_port = main and main.device and main.device.port or nil
        self.aux_grid_port = aux and aux.device and aux.device.port or nil
        if prev_aux_port ~= self.aux_grid_port then
            self.aux_led_prev = nil
        end
        self.grid_dev = self.main_grid_dev
    end

    function App:handle_grid_key(port, x, y, z)
        self:invalidate_step_cache()
        if port == self.aux_grid_port then
            self:handle_aux_grid_event(x, y, z)
            return
        end
        if port == self.main_grid_port then
            self:handle_main_grid_event(x, y, z)
        end
    end

    function App:apply_held_gate_span(track, anchor_step, target_step, preserve_step)
        local t = clamp(tonumber(track) or 1, 1, cfg.NUM_TRACKS)
        if not self.track_hold_tie_len_enabled[t] then return end
        local from_step = clamp(tonumber(anchor_step) or 1, 1, cfg.NUM_STEPS)
        local to_step = clamp(tonumber(target_step) or 1, 1, cfg.NUM_STEPS)
        if from_step == to_step then return end

        local tr = self:ensure_track_state(t)
        local tc = self.track_cfg[t]
        if not tr or not tc then return end

        local lo = math.min(from_step, to_step)
        local hi = math.max(from_step, to_step)
        local src_vel = clamp(tonumber(tr.vels[from_step]) or cfg.DEFAULT_VEL_LEVEL, 1, 15)
        local src_pitch = tr.pitches[from_step]

        for s = lo, hi do
            tr.gates[s] = true
            if not tr.ties then tr.ties = {} end
            tr.ties[s] = (s ~= from_step)
            if s ~= preserve_step then
                tr.vels[s] = src_vel
                if tc.type == "poly" then
                    if type(src_pitch) == "table" then
                        tr.pitches[s] = deep_copy_table(src_pitch)
                    else
                        tr.pitches[s] = { clamp(tonumber(src_pitch) or 1, 1, 16) }
                    end
                elseif tc.type ~= "drum" then
                    tr.pitches[s] = clamp(tonumber(src_pitch) or 1, 1, 16)
                end
            end
        end
        self:invalidate_step_cache(t)
    end

    function App:main_x_to_realtime_velocity(x)
        local norm = clamp(tonumber(x) or 1, 1, cfg.NUM_STEPS)
        local scaled = 1 + (((norm - 1) / math.max(1, cfg.NUM_STEPS - 1)) * 14)
        return clamp(math.floor(scaled + 0.5), 1, 15)
    end

    function App:clear_realtime_row_holds(track)
        if track then
            self.realtime_row_holds[track] = {}
            return
        end
        self.realtime_row_holds = {}
    end

    function App:get_realtime_target_step(track)
        local ts = tonumber(self.track_steps[track]) or 1
        local phase = clamp(tonumber(self.track_clock_phase[track]) or 0, 0, 0.999999)
        local counter = (phase >= 0.5) and ts or (ts - 1)
        return self:get_track_step_from_counter(track, counter)
    end

    function App:audition_realtime_tap(track, tc, velocity_level, degree)
        local output_ports = self:capture_midi_ports()
        local gate_ticks = clamp(
            tonumber(self.track_gate_ticks[track]) or
            ((tc.type == "drum") and self.drum_gate_clocks or self.melody_gate_clocks),
            1, 24)

        if tc.type == "drum" then
            local note = clamp(tc.note, 0, 127)
            self:midi_note_on(note, self:vel_to_midi(velocity_level), tc.ch, output_ports)
            self:trigger_crow(track, note)
            self:schedule_note_off(track, note, tc.ch, gate_ticks, output_ports)
            return
        end

        local note = self:get_pitch(track, degree, 0)
        self:midi_note_on(note, self:vel_to_midi(clamp(tonumber(velocity_level) or cfg.DEFAULT_VEL_LEVEL, 1, 15)), tc.ch,
            output_ports)
        self:trigger_crow(track, note)
        self:schedule_note_off(track, note, tc.ch, gate_ticks, output_ports)
    end

    function App:handle_realtime_play_event(track, x, z)
        if z ~= 1 and z ~= 0 then return end
        if not self.playing then return end

        local t = clamp(tonumber(track) or 1, 1, cfg.NUM_TRACKS)
        local step = self:get_realtime_target_step(t)
        local tr = self:ensure_track_state(t)
        local tc = self.track_cfg[t]
        if not tr or not tc or not step then return end

        if not self.realtime_row_holds[t] then self.realtime_row_holds[t] = {} end
        if z == 0 then
            self.realtime_row_holds[t][x] = nil
            return
        end

        self.sel_track = t
        self.realtime_row_holds[t][x] = true

        if tr.ties then tr.ties[step] = false end
        tr.gates[step] = true
        tr.vels[step] = self:get_track_default_vel_level(t)

        if tc.type == "drum" then
            local vel = self:main_x_to_realtime_velocity(x)
            tr.vels[step] = vel
            self:audition_realtime_tap(t, tc, vel, nil)
        elseif tc.type == "poly" then
            local chord = {}
            for held_x, is_on in pairs(self.realtime_row_holds[t]) do
                if is_on then
                    chord[#chord + 1] = clamp(tonumber(held_x) or 1, 1, 16)
                end
            end
            table.sort(chord)
            if #chord == 0 then chord[1] = clamp(tonumber(x) or 1, 1, 16) end
            tr.pitches[step] = chord
            self:audition_realtime_tap(t, tc, self:get_track_default_vel_level(t), clamp(tonumber(x) or 1, 1, 16))
        else
            local degree = clamp(tonumber(x) or 1, 1, 16)
            tr.pitches[step] = degree
            self:audition_realtime_tap(t, tc, self:get_track_default_vel_level(t), degree)
        end

        self:request_arc_redraw()
        self:request_redraw()
        self:request_aux_redraw()
    end

    function App:clear_temp_steps()
        for t, steps in pairs(self.temp_steps) do
            for s, _ in pairs(steps) do
                self.tracks[t].gates[s] = false
                self.tracks[t].vels[s] = self:get_track_default_vel_level(t)
                if self.track_cfg[t].type == "poly" then self.tracks[t].pitches[s] = { 1 } else self.tracks[t].pitches[s] = 1 end
            end
        end
        self.temp_steps = {}
        self:invalidate_step_cache()
    end

    function App:add_temp_step(track, step)
        if not self.temp_steps[track] then self.temp_steps[track] = {} end
        self.temp_steps[track][step] = true
    end

    function App:update_solo()
        local any_solo = false
        for t = 1, cfg.NUM_TRACKS do
            if self.tracks[t].solo then
                any_solo = true
                break
            end
        end
        for t = 1, cfg.NUM_TRACKS do
            if any_solo then self.tracks[t].muted = not self.tracks[t].solo else self.tracks[t].muted = false end
        end
    end

    function App:clear_track(t)
        for s = 1, cfg.NUM_STEPS do
            self.tracks[t].gates[s] = false
            if self.track_cfg[t].type == "poly" then self.tracks[t].pitches[s] = { 1 } else self.tracks[t].pitches[s] = 1 end
            self.tracks[t].vels[s] = self:get_track_default_vel_level(t)
        end
        self.fill_patterns[t] = {}
        self.ratios[t] = {}
        self.spice[t] = {}
        self.track_rand_gate_prob[t] = 0
        self.track_rand_pitch_prob[t] = 0
        self.track_rand_pitch_span[t] = 0
        self.tracks[t].arc = { pulses = 0, rotation = 1, variance = 0, mode = 1 }
        self:invalidate_step_cache(t)
    end

    function App:clear_all_tracks()
        for t = 1, cfg.NUM_TRACKS do self:clear_track(t) end
        self:reset_transpose_meta_sequence()
        self:invalidate_step_cache()
    end

    function App:clear_modifier_for_track(mod, t)
        if mod == cfg.MOD.MUTE then
            self.tracks[t].muted = false
        elseif mod == cfg.MOD.SOLO then
            self.tracks[t].solo = false
            self:update_solo()
        elseif mod == cfg.MOD.START then
            self.tracks[t].start_step = 1
        elseif mod == cfg.MOD.END_STEP then
            self.tracks[t].end_step = 16
        elseif mod == cfg.MOD.OCTAVE then
            self.tracks[t].octave = 0
        elseif mod == cfg.MOD.TRANSPOSE then
            self.track_transpose[t] = 0
        elseif mod == cfg.MOD.SPICE then
            self.spice[t] = {}
        elseif mod == cfg.MOD.TEMP and self:is_temp_button_fill_mode() then
            self.fill_patterns[t] = {}
        elseif mod == cfg.MOD.RATIOS then
            self.ratios[t] = {}
        elseif mod == cfg.MOD.RAND_STEPS then
            self.track_rand_gate_prob[t] = 0
        elseif mod == cfg.MOD.RAND_NOTES then
            self.track_rand_pitch_prob[t] = 0
            self.track_rand_pitch_span[t] = 0
        end
        self:invalidate_step_cache(t)
    end

    function App:clear_modifier_all_tracks(mod)
        for t = 1, cfg.NUM_TRACKS do
            self:clear_modifier_for_track(mod, t)
        end
        self:invalidate_step_cache()
    end

    function App:handle_aux_grid_event(x, y, z)
        if not self.aux_grid_dev then return end
        if x < 1 or x > cfg.NUM_STEPS or y < 1 or y > cfg.AUX_GRID_ROWS then return end

        local t = clamp(tonumber(self.sel_track) or 1, 1, cfg.NUM_TRACKS)
        self.sel_track = t

        local tr = self:ensure_track_state(t)
        local tc = self.track_cfg[t]
        local prev_held = self.held

        if z == 0 then
            if self.held and self.held.aux and self.held.t == t and self.held.s == x then
                self.held = nil
            end
            return
        end
        if z ~= 1 then return end

        local did_push = false
        local function ensure_push()
            if not did_push then
                self:push_undo_state()
                did_push = true
            end
        end

        local prev_held_time = self.held_time
        self.held_time = now_ms()
        self.held = { t = t, s = x, y = y, was_on = tr.gates[x], aux = true }
        if tr.ties then tr.ties[x] = false end

        local applied_mod = self:get_active_mod_id()
        local applied_value = nil
        if self.mod_held[cfg.MOD.MUTE] then
            tr.muted = not tr.muted
            applied_value = tr.muted and "on" or "off"
        elseif self.mod_held[cfg.MOD.SOLO] then
            tr.solo = not tr.solo
            self:update_solo()
            applied_value = tr.solo and "on" or "off"
        elseif self.mod_held[cfg.MOD.START] then
            tr.start_step = x
            self.track_steps[t] = 1
            applied_value = tostring(x)
        elseif self.mod_held[cfg.MOD.END_STEP] then
            tr.end_step = x
            applied_value = tostring(x)
        elseif self.mod_held[cfg.MOD.BEAT_RPT] then
            self.beat_repeat_excluded[t] = not self.beat_repeat_excluded[t]
            applied_value = self.beat_repeat_excluded[t] and "exclude" or "include"
        elseif self.mod_held[cfg.MOD.SPICE] and self.spice_pending_amount then
            ensure_push()
            if self:step_has_playable_note(t, x) then self.spice[t][x] = { amount = self.spice_pending_amount, current = 0 } end
            applied_value = tostring(self.spice_pending_amount)
        elseif self.mod_held[cfg.MOD.CLEAR] and self.mod_held[cfg.MOD.SHIFT] then
            ensure_push()
            self:clear_all_tracks()
            applied_value = "all"
        elseif self.mod_held[cfg.MOD.CLEAR] then
            ensure_push()
            self:clear_track(t)
            applied_value = "track"
        elseif self.mod_held[cfg.MOD.RATIOS] and tc.type == "drum" then
            ensure_push()
            tr.gates[x] = true
            tr.vels[x] = self:aux_row_to_vel_level(y)
            applied_value = self:apply_pending_ratio_to_step(t, x)
        elseif self.mod_held[cfg.MOD.RATIOS] and tc.type == "poly" then
            ensure_push()
            tr.pitches[x] = self:poly_toggle_aux_degree(t, self:poly_active_pitches(tr, x), self:aux_row_to_degree(y))
            tr.gates[x] = (#tr.pitches[x] > 0)
            if tr.gates[x] then
                tr.vels[x] = clamp(tonumber(tr.vels[x]) or self:get_track_default_vel_level(t), 1, 15)
                applied_value = self:apply_pending_ratio_to_step(t, x)
            else
                applied_value = "off"
            end
        elseif self.mod_held[cfg.MOD.RATIOS] then
            ensure_push()
            tr.gates[x] = true
            tr.vels[x] = clamp(tonumber(tr.vels[x]) or self:get_track_default_vel_level(t), 1, 15)
            tr.pitches[x] = self:aux_row_to_degree(y)
            applied_value = self:apply_pending_ratio_to_step(t, x)
        elseif self:mod_active(cfg.MOD.TEMP) and self:is_temp_button_fill_mode() then
            ensure_push()
            local fill_vel = self:aux_row_to_vel_level(y)
            local fill_pitch = self:aux_row_to_degree(y)
            if self.fill_patterns[t][x] then
                self.fill_patterns[t][x] = nil
                applied_value = "off"
            else
                local fp = tr.pitches[x] or 1
                if type(fp) == "table" then fp = fp[1] or 1 end
                self.fill_patterns[t][x] = {
                    vel = (tc.type == "drum") and fill_vel or self:get_track_default_vel_level(t),
                    pitch = (tc.type == "drum") and fp or fill_pitch
                }
                applied_value = (tc.type == "drum") and ("vel " .. tostring(fill_vel)) or ("deg " .. tostring(fill_pitch))
            end
        elseif self:mod_active(cfg.MOD.TEMP) then
            ensure_push()
            local degree = self:aux_row_to_degree(y)
            local level = self:aux_row_to_vel_level(y)
            local was_off = not tr.gates[x]
            if not tr.gates[x] then
                tr.gates[x] = true
                tr.vels[x] = self:get_track_default_vel_level(t)
                if tc.type == "poly" and type(tr.pitches[x]) ~= "table" then tr.pitches[x] = { 1 } end
            end

            if tc.type == "drum" then
                tr.vels[x] = level
                applied_value = "vel " .. tostring(level)
            elseif tc.type == "poly" then
                tr.pitches[x] = self:poly_toggle_aux_degree(t, self:poly_active_pitches(tr, x), degree)
                tr.gates[x] = (#tr.pitches[x] > 0)
                applied_value = "deg " .. tostring(degree)
            else
                tr.pitches[x] = degree
                tr.gates[x] = true
                applied_value = "deg " .. tostring(degree)
            end

            if was_off and tr.gates[x] then
                self:add_temp_step(t, x)
            end
        elseif self.mod_held[cfg.MOD.SPICE] and not self.spice_pending_amount then
            ensure_push()
            self.spice[t][x] = nil
            applied_value = "clear"
        elseif tc.type == "drum" then
            ensure_push()
            local next_vel = self:aux_row_to_vel_level(y)
            if tr.gates[x] and tr.vels[x] == next_vel then
                tr.gates[x] = false
                if tr.ties then tr.ties[x] = false end
            else
                tr.gates[x] = true
                tr.vels[x] = next_vel
            end
        elseif tc.type == "poly" then
            ensure_push()
            tr.pitches[x] = self:poly_toggle_aux_degree(t, self:poly_active_pitches(tr, x), self:aux_row_to_degree(y))
            tr.gates[x] = (#tr.pitches[x] > 0)
            if tr.gates[x] then
                tr.vels[x] = clamp(tonumber(tr.vels[x]) or self:get_track_default_vel_level(t), 1, 15)
            end
        else
            ensure_push()
            local next_degree = self:aux_row_to_degree(y)
            if tr.gates[x] and self:get_closest_aux_degree(t, tr.pitches[x]) == next_degree then
                tr.gates[x] = false
                if tr.ties then tr.ties[x] = false end
            else
                tr.gates[x] = true
                tr.vels[x] = clamp(tonumber(tr.vels[x]) or self:get_track_default_vel_level(t), 1, 15)
                tr.pitches[x] = next_degree
            end
        end

        if prev_held and prev_held.was_on and prev_held.aux and prev_held.t == t and prev_held.s ~= x and not self:any_mod_active()
            and ((now_ms() - (prev_held_time or 0)) >= self.HOLD_THRESHOLD) then
            self:apply_held_gate_span(t, prev_held.s, x, x)
        end

        if applied_mod then
            self:flash_mod_applied(applied_mod, applied_value or self:get_active_mod_value(applied_mod))
        end
        if not self.mod_held[cfg.MOD.SPICE] then self.spice_pending_amount = nil end
        self:request_arc_redraw()
        self:request_redraw()
        self:request_aux_redraw()
    end

    function App:route_main_grid_event(x, y, mod_row, dyn_row)
        if y == mod_row then return "mod" end
        if self.realtime_play_mode and self.playing then
            if y == dyn_row then return "dynamic" end
            local rt_track = self:row_to_track(y)
            if rt_track and rt_track >= 1 and rt_track <= cfg.NUM_TRACKS then
                return "realtime", rt_track
            end
        end
        if self.takeover_mode then
            if self.transpose_takeover_mode then return "transpose_takeover" end
            if y == dyn_row and self:is_modifier_dynamic_row_active() and not self:is_main_grid_128() then
                return "dynamic"
            end
            return "takeover"
        end
        if y == dyn_row then return "dynamic" end
        return "overview"
    end

    function App:handle_main_grid_event(x, y, z)
        local mod_row = self:get_main_mod_row()
        local dyn_row = self:get_main_dynamic_row()
        local takeover_rows = self:get_main_takeover_note_rows()
        local route, route_track = self:route_main_grid_event(x, y, mod_row, dyn_row)

        if route == "mod" then
            self:handle_mod_row(x, z)
            return
        elseif route == "dynamic" then
            self:handle_dynamic_row(x, z)
            return
        elseif route == "realtime" then
            self:handle_realtime_play_event(route_track, x, z)
            return
        elseif route == "transpose_takeover" then
            self:handle_transpose_takeover_event(x, y, z)
            return
        end

        if route == "takeover" then

            if y >= 1 and y <= takeover_rows then
                local t = self.sel_track or 1
                self.sel_track = t
                local tr = self.tracks[t]
                local tc = self.track_cfg[t]
                local prev_held = self.held

                if z == 1 then
                    local did_push = false
                    local function ensure_push()
                        if not did_push then
                            self:push_undo_state()
                            did_push = true
                        end
                    end
                    local prev_held_time = self.held_time
                    self.held_time = now_ms()
                    self.held = { t = t, s = x, y = y, was_on = tr.gates[x], aux = false }
                    if tr.ties then tr.ties[x] = false end

                    local applied_mod = self:get_active_mod_id()
                    local applied_value = nil

                    if self.mod_held[cfg.MOD.MUTE] then
                        tr.muted = not tr.muted
                        applied_value = tr.muted and "on" or "off"
                    elseif self.mod_held[cfg.MOD.SOLO] then
                        tr.solo = not tr.solo
                        self:update_solo()
                        applied_value = tr.solo and "on" or "off"
                    elseif self.mod_held[cfg.MOD.START] then
                        tr.start_step = x
                        self.track_steps[t] = 1
                        applied_value = tostring(x)
                    elseif self.mod_held[cfg.MOD.END_STEP] then
                        tr.end_step = x
                        applied_value = tostring(x)
                    elseif self.mod_held[cfg.MOD.BEAT_RPT] then
                        self.beat_repeat_excluded[t] = not self.beat_repeat_excluded[t]
                        applied_value = self.beat_repeat_excluded[t] and "exclude" or "include"
                    elseif self.mod_held[cfg.MOD.SPICE] and self.spice_pending_amount then
                        ensure_push()
                        if self:step_has_playable_note(t, x) then self.spice[t][x] = { amount = self.spice_pending_amount, current = 0 } end
                        applied_value = tostring(self.spice_pending_amount)
                    elseif self.mod_held[cfg.MOD.CLEAR] and self.mod_held[cfg.MOD.SHIFT] then
                        ensure_push()
                        self:clear_all_tracks()
                        applied_value = "all"
                    elseif self.mod_held[cfg.MOD.CLEAR] then
                        ensure_push()
                        self:clear_track(t)
                        applied_value = "track"
                    elseif self.mod_held[cfg.MOD.RATIOS] then
                        ensure_push()
                        local degree = self:main_takeover_row_to_degree(y)
                        local level = self:main_takeover_row_to_vel_level(y)
                        if tc.type == "drum" then
                            tr.gates[x] = true
                            tr.vels[x] = level
                        elseif tc.type == "poly" then
                            tr.pitches[x] = self:poly_toggle_pitch(self:poly_active_pitches(tr, x), degree)
                            tr.gates[x] = (#tr.pitches[x] > 0)
                            if tr.gates[x] then
                                tr.vels[x] = clamp(tonumber(tr.vels[x]) or self:get_track_default_vel_level(t), 1, 15)
                            end
                        else
                            tr.gates[x] = true
                            tr.pitches[x] = degree
                            tr.vels[x] = clamp(tonumber(tr.vels[x]) or self:get_track_default_vel_level(t), 1, 15)
                        end
                        if tr.gates[x] then
                            applied_value = self:apply_pending_ratio_to_step(t, x)
                        else
                            applied_value = "off"
                        end
                    elseif self:mod_active(cfg.MOD.TEMP) and self:is_temp_button_fill_mode() then
                        ensure_push()
                        local fill_vel = clamp(16 - y, 1, 15)
                        local fill_pitch = clamp(16 - y, 1, 16)
                        if self.fill_patterns[t][x] then
                            self.fill_patterns[t][x] = nil
                            applied_value = "off"
                        else
                            local fp = tr.pitches[x] or 1
                            if type(fp) == "table" then fp = fp[1] or 1 end
                            self.fill_patterns[t][x] = {
                                vel = (tc.type == "drum") and fill_vel or self:get_track_default_vel_level(t),
                                pitch = (tc.type == "drum") and fp or fill_pitch
                            }
                            applied_value = (tc.type == "drum") and ("vel " .. tostring(fill_vel)) or
                                ("deg " .. tostring(fill_pitch))
                        end
                    elseif self:mod_active(cfg.MOD.TEMP) then
                        ensure_push()
                        local degree = self:main_takeover_row_to_degree(y)
                        local level = self:main_takeover_row_to_vel_level(y)
                        local was_off = not tr.gates[x]
                        if not tr.gates[x] then
                            tr.gates[x] = true
                            tr.vels[x] = self:get_track_default_vel_level(t)
                            if tc.type == "poly" and type(tr.pitches[x]) ~= "table" then tr.pitches[x] = { 1 } end
                        end

                        if tc.type == "drum" then
                            tr.vels[x] = level
                            applied_value = "vel " .. tostring(level)
                        elseif tc.type == "poly" then
                            tr.pitches[x] = self:poly_toggle_pitch(self:poly_active_pitches(tr, x), degree)
                            tr.gates[x] = (#tr.pitches[x] > 0)
                            applied_value = "deg " .. tostring(degree)
                        else
                            tr.pitches[x] = degree
                            tr.gates[x] = true
                            applied_value = "deg " .. tostring(degree)
                        end

                        if was_off and tr.gates[x] then
                            self:add_temp_step(t, x)
                        end
                    elseif self.mod_held[cfg.MOD.SPICE] and not self.spice_pending_amount then
                        ensure_push()
                        self.spice[t][x] = nil
                        applied_value = "clear"
                    elseif tc.type == "drum" then
                        ensure_push()
                        local level = self:main_takeover_row_to_vel_level(y)
                        if y == dyn_row and not self:is_main_grid_128() then
                            if tr.gates[x] then
                                tr.gates[x] = false
                            else
                                tr.gates[x] = true
                                tr.vels[x] = self:get_track_default_vel_level(t)
                            end
                        else
                            if tr.gates[x] then
                                tr.vels[x] = level
                            else
                                tr.gates[x] = true
                                tr.vels[x] = level
                            end
                        end
                    else
                        ensure_push()
                        local degree = self:main_takeover_row_to_degree(y)
                        if tc.type == "poly" then
                            tr.pitches[x] = self:poly_toggle_pitch(self:poly_active_pitches(tr, x), degree)
                            tr.gates[x] = (#tr.pitches[x] > 0)
                        else
                            if tr.gates[x] and tr.pitches[x] == degree then
                                tr.gates[x] = false
                            else
                                tr.gates[x] = true
                                tr.pitches[x] = degree
                                tr.vels[x] = self:get_track_default_vel_level(t)
                            end
                        end
                    end
                    if prev_held and prev_held.was_on and not prev_held.aux and prev_held.t == t and prev_held.s ~= x and not self:any_mod_active()
                        and ((now_ms() - (prev_held_time or 0)) >= self.HOLD_THRESHOLD) then
                        self:apply_held_gate_span(t, prev_held.s, x, x)
                    end

                    if applied_mod then
                        self:flash_mod_applied(applied_mod, applied_value or self:get_active_mod_value(applied_mod))
                    end
                else
                    if self.held and self.held.t == t and self.held.s == x then
                        local hold_duration = now_ms() - self.held_time
                        if hold_duration < self.HOLD_THRESHOLD and self.held.was_on and self.held.y == dyn_row and not self:is_main_grid_128() then tr.gates[x] = false end
                    end
                    self.held = nil
                end

                if not self.mod_held[cfg.MOD.SPICE] then self.spice_pending_amount = nil end
                self:request_arc_redraw()
                self:request_redraw()
                self:request_aux_redraw()
            end
            return
        end

        if y == mod_row then
            self:handle_mod_row(x, z)
            return
        end

        if y == dyn_row then
            self:handle_dynamic_row(x, z)
            return
        end

        local t = self:row_to_track(y)
        if t and t >= 1 and t <= cfg.NUM_TRACKS then
            local prev_held = self.held
            if z == 1 then
                local did_push = false
                local function ensure_push()
                    if not did_push then
                        self:push_undo_state()
                        did_push = true
                    end
                end
                local prev_held_time = self.held_time
                self.held_time = now_ms()
                self.sel_track = t
                if self.mod_held[cfg.MOD.MUTE] then
                    self.tracks[t].muted = not self.tracks[t].muted
                elseif self.mod_held[cfg.MOD.SOLO] then
                    self.tracks[t].solo = not self.tracks[t].solo
                    self:update_solo()
                elseif self.mod_held[cfg.MOD.START] then
                    self.tracks[t].start_step = x
                    self.track_steps[t] = 1
                elseif self.mod_held[cfg.MOD.END_STEP] then
                    self.tracks[t].end_step = x
                elseif self.mod_held[cfg.MOD.BEAT_RPT] then
                    self.beat_repeat_excluded[t] = not self.beat_repeat_excluded[t]
                elseif self.mod_held[cfg.MOD.SPICE] and self.spice_pending_amount then
                    ensure_push()
                    if self:step_has_playable_note(t, x) then self.spice[t][x] = { amount = self.spice_pending_amount, current = 0 } end
                    self.sel_track = t
                elseif self.mod_held[cfg.MOD.CLEAR] and self.mod_held[cfg.MOD.SHIFT] then
                    ensure_push()
                    self:clear_all_tracks()
                elseif self.mod_held[cfg.MOD.CLEAR] then
                    ensure_push()
                    self:clear_track(t)
                    self.sel_track = t
                elseif self.mod_held[cfg.MOD.RATIOS] then
                    ensure_push()
                    if not self.tracks[t].gates[x] then
                        self.tracks[t].gates[x] = true
                        self.tracks[t].vels[x] = self:get_track_default_vel_level(t)
                        if self.track_cfg[t].type == "poly" and type(self.tracks[t].pitches[x]) ~= "table" then self.tracks[t].pitches[x] = { 1 } end
                    end
                    self:apply_pending_ratio_to_step(t, x)
                    self.sel_track = t
                elseif self:mod_active(cfg.MOD.TEMP) and self:is_temp_button_fill_mode() then
                    ensure_push()
                    if self.fill_patterns[t][x] then
                        self.fill_patterns[t][x] = nil
                    else
                        local fp = self.tracks[t].pitches[x] or 1
                        if type(fp) == "table" then fp = fp[1] or 1 end
                        self.fill_patterns[t][x] = { vel = self:get_track_default_vel_level(t), pitch = fp }
                    end
                    self.sel_track = t
                elseif self:mod_active(cfg.MOD.TEMP) then
                    ensure_push()
                    self.held = { t = t, s = x, y = y, was_on = self.tracks[t].gates[x], aux = false }
                    if self.tracks[t].ties then self.tracks[t].ties[x] = false end
                    if not self.tracks[t].gates[x] then
                        self.tracks[t].gates[x] = true
                        self.tracks[t].vels[x] = self:get_track_default_vel_level(t)
                        if self.track_cfg[t].type == "poly" and type(self.tracks[t].pitches[x]) ~= "table" then self.tracks[t].pitches[x] = { 1 } end
                        self:add_temp_step(t, x)
                    end
                elseif self.mod_held[cfg.MOD.SPICE] and not self.spice_pending_amount then
                    ensure_push()
                    self.spice[t][x] = nil
                    self.sel_track = t
                elseif self:any_mod_active() then
                    self.sel_track = t
                else
                    ensure_push()
                    self.held = { t = t, s = x, y = y, was_on = self.tracks[t].gates[x], aux = false }
                    if self.tracks[t].ties then self.tracks[t].ties[x] = false end
                    if not self.tracks[t].gates[x] then
                        self.tracks[t].gates[x] = true
                        self.tracks[t].vels[x] = self:get_track_default_vel_level(t)
                        if self.track_cfg[t].type == "poly" and type(self.tracks[t].pitches[x]) ~= "table" then self.tracks[t].pitches[x] = { 1 } end
                    end
                end
                if prev_held and prev_held.was_on and not prev_held.aux and prev_held.t == t and prev_held.s ~= x and not self:any_mod_active()
                    and ((now_ms() - (prev_held_time or 0)) >= self.HOLD_THRESHOLD) then
                    self:apply_held_gate_span(t, prev_held.s, x, x)
                end
                if self:any_mod_active() then
                    local mod_id = self:get_active_mod_id()
                    if mod_id then self:flash_mod_applied(mod_id) end
                end
            else
                if self.held and self.held.t == t and self.held.s == x then
                    local hold_duration = now_ms() - self.held_time
                    if hold_duration < self.HOLD_THRESHOLD and self.held.was_on then self.tracks[t].gates[x] = false end
                end
                self.held = nil
            end
            if not self.mod_held[cfg.MOD.SPICE] then self.spice_pending_amount = nil end
            self:request_arc_redraw()
            self:request_redraw()
            self:request_aux_redraw()
        end
    end

    function App:grid_event(x, y, z)
        self:invalidate_step_cache()
        self:handle_main_grid_event(x, y, z)
    end

end

return M
