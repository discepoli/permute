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
local swing_profiles = include("lib/sequencer/swing_profiles")

local M = {}

function M.install(App)
    function App:get_track_swing_percent(_track)
        return clamp(tonumber(self.global_swing_percent) or 50, 25, 75)
    end

    function App:get_track_swing_profile_name(_track)
        local profile = self.global_swing_profile or "linear"
        if not ((swing_profiles.enabled or {})[profile]) then
            profile = "linear"
        end
        return profile
    end

    function App:get_track_swing_step_ticks(track, step_counter)
        local profile = self:get_track_swing_profile_name(track)
        local tables = swing_profiles.timings or {}
        local timing = tables[profile] or tables.mpc1000 or {}
        local p = self:get_track_swing_percent(track)
        local ts = math.max(tonumber(step_counter) or 1, 1)
        local idx = (ts % 16) + 1
        local ticks = cfg.MIDI_CLOCK_TICKS_PER_STEP

        if p == 50 or ts == 1 then
            return ticks
        end

        if p > 50 then
            local tpl = timing[p]
            if type(tpl) == "table" then
                ticks = tonumber(tpl[idx]) or ticks
            end
        else
            local mirrored = clamp(100 - p, 50, 75)
            local tpl = timing[mirrored]
            if type(tpl) == "table" then
                local mirrored_ticks = tonumber(tpl[idx]) or ticks
                ticks = (cfg.MIDI_CLOCK_TICKS_PER_STEP * 2) - mirrored_ticks
            end
        end

        return math.max(0.001, tonumber(ticks) or cfg.MIDI_CLOCK_TICKS_PER_STEP)
    end

    function App:get_transport_tick_delta()
        local ppqn = math.max(tonumber(self.transport_scheduler_ppqn) or 96, 24)
        return 24 / ppqn
    end

    function App:update_clock_tempo(bpm)
        local tempo = clamp(tonumber(bpm) or 120, 20, 300)
        self.tempo_bpm = tempo
        pcall(function() clock.tempo = tempo end)
    end

    function App:on_external_clock_pulse()
        local now = util.time() or 0
        local interval = nil
        if self.external_clock_last_time ~= nil then
            local dt = now - self.external_clock_last_time
            if dt > 0 and dt < 1 then
                interval = dt
                self.external_clock_display_interval = dt
                local input_ppqn = self:get_external_clock_input_ppqn()
                local instant_bpm = clamp(60 / (dt * input_ppqn), 20, 300)
                local smooth = clamp(tonumber(self.external_clock_smooth) or 0.25, 0.01, 1)
                local prev = tonumber(self.external_clock_bpm_estimate) or instant_bpm
                local blended = prev + ((instant_bpm - prev) * smooth)
                self.external_clock_bpm_estimate = blended
                local min_interval = math.max(tonumber(self.external_clock_tempo_update_interval) or 0.25, 0)
                local last_update = tonumber(self.external_clock_last_tempo_update)
                if not last_update or min_interval == 0 or (now - last_update) >= min_interval then
                    self.external_clock_last_tempo_update = now
                    if self.use_midi_clock and self.request_redraw then self:request_redraw() end
                end
            end
        end
        self.external_clock_last_time = now
        return interval
    end

    function App:get_external_clock_input_ppqn()
        return math.max(tonumber(self.external_clock_input_ppqn) or 24, 24)
    end

    function App:get_external_clock_pulse_delta()
        return 24 / self:get_external_clock_input_ppqn()
    end

    function App:get_external_clock_subdivisions()
        local input_ppqn = self:get_external_clock_input_ppqn()
        local target_ppqn = math.max(tonumber(self.external_clock_interpolation_ppqn) or input_ppqn, input_ppqn)
        return math.max(1, math.floor((target_ppqn / input_ppqn) + 0.5))
    end

    function App:cancel_external_clock_subtick_scheduler()
        self.external_clock_subtick_generation = (tonumber(self.external_clock_subtick_generation) or 0) + 1
        if self.external_clock_subtick_id then
            clock.cancel(self.external_clock_subtick_id)
            self.external_clock_subtick_id = nil
        end
    end

    function App:schedule_external_clock_subticks(interval)
        local subdivisions = self:get_external_clock_subdivisions()
        if subdivisions <= 1 then return end
        local pulse_interval = tonumber(interval) or 0
        if pulse_interval <= 0 or pulse_interval >= 1 then return end

        self:cancel_external_clock_subtick_scheduler()
        local generation = tonumber(self.external_clock_subtick_generation) or 0
        local sleep_time = pulse_interval / subdivisions
        local delta = self:get_external_clock_pulse_delta() / subdivisions
        local max_progress = self:get_external_clock_pulse_delta() - delta
        self.external_clock_subtick_id = clock.run(function()
            for _ = 1, subdivisions - 1 do
                clock.sleep(sleep_time)
                if generation ~= self.external_clock_subtick_generation then return end
                if not self.playing or not self.use_midi_clock then return end
                self.external_clock_subtick_progress = math.min(
                    (tonumber(self.external_clock_subtick_progress) or 0) + delta,
                    max_progress)
                self:run_internal_clock_iteration(delta)
            end
            if generation == self.external_clock_subtick_generation then
                self.external_clock_subtick_id = nil
            end
        end)
    end

    function App:advance_external_clock_pulse(interval)
        local subdivisions = self:get_external_clock_subdivisions()
        local pulse_delta = self:get_external_clock_pulse_delta()
        if subdivisions <= 1 then
            self:run_internal_clock_iteration(pulse_delta)
            return
        end

        self:cancel_external_clock_subtick_scheduler()
        local subtick_delta = pulse_delta / subdivisions
        local progress = clamp(tonumber(self.external_clock_subtick_progress) or 0, 0, pulse_delta - subtick_delta)
        self.external_clock_subtick_progress = 0
        self:run_internal_clock_iteration(math.max(subtick_delta, pulse_delta - progress))
        self:schedule_external_clock_subticks(interval)
    end

    function App:reset_external_clock_sync()
        self:cancel_external_clock_subtick_scheduler()
        self.external_clock_last_time = nil
        self.external_clock_bpm_estimate = nil
        if self.reset_external_clock_display_tempo then self:reset_external_clock_display_tempo() end
        self.external_clock_last_tempo_update = nil
        self.external_clock_last_screen_refresh_ms = 0
        self.external_clock_subtick_progress = 0
    end

    function App:ensure_transport_scheduler_running()
        if self.use_midi_clock then return end
        if self.transport_scheduler_id then return end
        self.transport_scheduler_id = clock.run(function()
            while self.playing do
                local ppqn = math.max(tonumber(self.transport_scheduler_ppqn) or 96, 24)
                clock.sync(1 / ppqn)
                self:run_internal_clock_iteration(self:get_transport_tick_delta())
            end
        end)
    end

    function App:is_reset_timing_next_beat()
        return self.reset_timing == "next beat"
    end

    function App:queue_meta_reset_on_next_beat()
        self.pending_meta_reset_on_beat = true
    end

    function App:queue_transport_align_on_next_beat()
        self.pending_transport_align_on_beat = true
        self.pending_meta_reset_on_beat = true
    end

    function App:trigger_transport_reset()
        if self:is_reset_timing_next_beat() then
            self:queue_transport_align_on_next_beat()
            self:flash_status("reset", "next beat", 0.35)
            return
        end

        self.pending_transport_align_on_beat = false
        self.pending_meta_reset_on_beat = false
        self:reset_tracks_to_start_positions()
        self:flash_status("reset", "now", 0.35)
    end

    function App:trigger_meta_reset()
        if self:is_reset_timing_next_beat() then
            self:queue_meta_reset_on_next_beat()
            self:flash_status("meta reset", "next beat", 0.35)
            return
        end

        self.pending_meta_reset_on_beat = false
        self:reset_transpose_meta_transport()
        self:flash_status("meta reset", "now", 0.35)
    end

    function App:apply_pending_resets_on_step_boundary()
        local aligned = false
        local meta_reset = false

        if self.pending_transport_align_on_beat then
            for t = 1, cfg.NUM_TRACKS do
                self.track_steps[t] = 1
                self.track_loop_count[t] = 1
                self.track_clock_phase[t] = 0
            end
            self.step = 1
            self.beat_repeat_start = 0
            self.beat_repeat_cycle = 0
            self.beat_repeat_anchor = {}
            self.beat_repeat_select_armed = false
            self.beat_repeat_select_active = false
            self.beat_repeat_select_cycle = 0
            self.pending_transport_align_on_beat = false
            aligned = true
        end

        if self.pending_meta_reset_on_beat then
            self:reset_transpose_meta_transport()
            self.pending_meta_reset_on_beat = false
            meta_reset = true
        end

        return aligned, meta_reset
    end

    function App:schedule_note_off(track, note, ch, delay_ticks, ports)
        self.active_note_offs[#self.active_note_offs + 1] = {
            track = track,
            note = note,
            ch = ch,
            ports = ports or self.midi_out_ports_snapshot,
            off_tick = self.transport_clock + math.max(1, tonumber(delay_ticks) or 1)
        }
    end

    function App:schedule_delayed_note_on(track, note, vel, ch, delay_ticks, duration_ticks, ports)
        self.active_scheduled_note_ons[#self.active_scheduled_note_ons + 1] = {
            track = track,
            note = note,
            vel = vel,
            ch = ch,
            ports = ports or self.midi_out_ports_snapshot,
            on_tick = self.transport_clock + math.max(0, tonumber(delay_ticks) or 0),
            duration = math.max(0.001, tonumber(duration_ticks) or cfg.MIDI_CLOCK_TICKS_PER_STEP),
        }
    end

    function App:clear_scheduled_note_events_for_track(track)
        self:clear_scheduled_note_offs_for_track(track)
        local events = self.active_scheduled_note_ons
        local write_idx = 1
        for read_idx = 1, #events do
            local ev = events[read_idx]
            if ev.track ~= track then
                events[write_idx] = ev
                write_idx = write_idx + 1
            end
        end
        for i = write_idx, #events do events[i] = nil end
    end

    function App:clear_scheduled_note_offs_for_track(track)
        local events = self.active_note_offs
        local write_idx = 1
        for read_idx = 1, #events do
            local ev = events[read_idx]
            if ev.track ~= track then
                events[write_idx] = ev
                write_idx = write_idx + 1
            end
        end
        for i = write_idx, #events do events[i] = nil end
    end

    function App:process_scheduled_note_ons()
        local events = self.active_scheduled_note_ons
        local w = 1
        for r = 1, #events do
            local ev = events[r]
            if self.transport_clock >= ev.on_tick then
                self:midi_note_on(ev.note, ev.vel, ev.ch, ev.ports)
                if self.trigger_crow then self:trigger_crow(ev.track, ev.note) end
                self:schedule_note_off(ev.track, ev.note, ev.ch, ev.duration, ev.ports)
                if type(self.last_notes) == "table" then
                    self.last_notes[ev.track] = { note = ev.note, ch = ev.ch, ports = ev.ports }
                end
            else
                events[w] = ev
                w = w + 1
            end
        end
        for i = w, #events do events[i] = nil end
    end

    function App:process_scheduled_note_offs()
        local events = self.active_note_offs
        local w = 1
        for r = 1, #events do
            local ev = events[r]
            if self.transport_clock >= ev.off_tick then
                self:midi_note_off(ev.note, 0, ev.ch, ev.ports)
            else
                events[w] = ev
                w = w + 1
            end
        end
        for i = w, #events do events[i] = nil end
    end

    function App:play_tracks(pulse_scale)
        local mode_scale, mode_root = self:get_mode_scale_and_root()
        local transpose_mode = self.transpose_mode
        local transpose_seq_degree = self:get_transpose_seq_current_degree()
        local scale = tonumber(pulse_scale) or 1
        local total_hits = 0
        for t = 1, cfg.NUM_TRACKS do
            local tr = self:ensure_track_state(t)
            local tc = self.track_cfg[t]
            local step_cache = self:build_arc_step_cache(t, tr, tc)
            local len = math.abs((tonumber(tr.end_step) or self:get_track_step_limit()) - (tonumber(tr.start_step) or 1)) + 1
            local mult = self.track_clock_mult[t]
            local div = self.track_clock_div[t]
            local ts = tonumber(self.track_steps[t]) or 1
            local swing_ticks = self:get_track_swing_step_ticks(t, ts)
            local swing_factor = cfg.MIDI_CLOCK_TICKS_PER_STEP / math.max(0.001, swing_ticks)
            local ratio = (mult / div) * scale * swing_factor
            self.track_clock_phase[t] = (tonumber(self.track_clock_phase[t]) or 0) + ratio
            local hits = math.floor(self.track_clock_phase[t] + 1e-9)
            if hits > 0 then
                self.track_clock_phase[t] = self.track_clock_phase[t] - hits
                if math.abs(self.track_clock_phase[t]) < 1e-9 then
                    self.track_clock_phase[t] = 0
                end
                total_hits = total_hits + hits
            end

            if hits > 0 and t == self.sel_track then
                self:request_aux_redraw()
            end

            for _ = 1, hits do
                if tc.type == "split" then
                    local sp = self:ensure_split_track_state(t)
                    local gate_idx = clamp(tonumber(self.split_gate_pos[t]) or 1, 1, cfg.SPLIT_NUM_GATES)
                    local gate_stage_playback = self:get_split_gate_stage_playback(tr, gate_idx, t)
                    local in_held_substep = gate_stage_playback == 3 and self.split_gate_hold_active[t]
                    local pitch_ctx = {
                        scale = mode_scale,
                        mode_root = mode_root,
                        transpose_mode = transpose_mode,
                        transpose_seq_degree = transpose_seq_degree,
                    }
                    local output_ports = self.midi_out_ports_snapshot
                    local function send_note_on(note, vel, ch)
                        self:midi_note_on(note, vel, ch, output_ports)
                        if self.clock_debug_log_note_on then
                            self:clock_debug_log_note_on(
                                t,
                                self.split_gate_pos[t],
                                note,
                                ch,
                                vel
                            )
                        end
                    end

                    if self.last_notes[t] and not in_held_substep and gate_stage_playback ~= 2 then
                        self:note_off_last_for_track(t)
                    end

                    self:play_split_track_hit(t, tr, tc, pitch_ctx, send_note_on, swing_ticks)

                    local ts = tonumber(self.track_steps[t]) or 1
                    if len > 0 and ts % len == 0 then
                        self:apply_track_evolving_randomization(t)
                        self.track_loop_count[t] = (tonumber(self.track_loop_count[t]) or 1) + 1
                    end
                    self.track_steps[t] = ts + 1
                else
                local st = self:get_track_step(t)
                if (self.follow_page_on_playhead or self.follow_page_on_playhead_aux_takeover or self.follow_page_on_playhead_aux)
                    and not self.mod_held[cfg.MOD.START]
                    and not self.mod_held[cfg.MOD.END_STEP] then
                    local desired_page = 1
                    if len > cfg.NUM_STEPS then
                        desired_page = self:track_step_to_page(st)
                    end
                    local changed = false
                    if self.follow_page_on_playhead and desired_page ~= self:get_track_playhead_page(t) then
                        self:set_track_playhead_page(t, desired_page)
                        changed = true
                    end
                    if self.follow_page_on_playhead_aux_takeover and desired_page ~= self:get_track_view_page(t) then
                        self:set_track_view_page(t, desired_page)
                        changed = true
                    end
                    if self.follow_page_on_playhead_aux and desired_page ~= self:get_track_aux_page(t) then
                        self:set_track_aux_page(t, desired_page)
                        changed = true
                    end
                    if changed then
                        self:request_redraw()
                        self:request_aux_redraw()
                    end
                end
                local gate_ticks = clamp(
                    tonumber(self.track_gate_ticks[t]) or
                    ((tc.type == "drum") and self.drum_gate_clocks or self.melody_gate_clocks), 1, 24)
                local has_fill = self.fill_active and self.fill_patterns[t][st]
                local step_data = step_cache[st]
                local ratio_allows = step_data and self:step_ratio_allows_play(t, st)
                local is_tie_step = step_data and step_data.source == "manual" and step_data.tie and ratio_allows
                local should_play = ((step_data and ratio_allows and (not is_tie_step or not self.last_notes[t])) or has_fill)
                local mute_recorded_once = (not has_fill) and step_data and step_data.source == "manual" and
                    self:consume_recorded_step_skip_once(t, st)
                local function send_note_on(note, vel, ch, ports)
                    self:midi_note_on(note, vel, ch, ports)
                    if self.clock_debug_log_note_on then
                        self:clock_debug_log_note_on(t, st, note, ch, vel)
                    end
                end

                if self.last_notes[t] and not is_tie_step then
                    self:note_off_last_for_track(t)
                end

                if not tr.muted and should_play and not mute_recorded_once then
                    local output_ports = self.midi_out_ports_snapshot
                    local note_len_ticks = gate_ticks
                    if step_data and step_data.source == "manual" and not step_data.tie and not has_fill then
                        local tied_ahead = self:count_manual_ties_ahead(st, tr, step_cache)
                        if tied_ahead > 0 then
                            note_len_ticks = gate_ticks + (tied_ahead * cfg.MIDI_CLOCK_TICKS_PER_STEP)
                        end
                    end
                    local vel
                    local pitch_ctx = {
                        scale = mode_scale,
                        mode_root = mode_root,
                        transpose_mode = transpose_mode,
                        transpose_seq_degree = transpose_seq_degree,
                    }

                    if has_fill and not step_data then
                        vel = self.fill_patterns[t][st].vel
                        if tc.type == "drum" then
                            local note = clamp(tc.note, 0, 127)
                            send_note_on(note, self:vel_to_midi(vel), tc.ch, output_ports)
                            self:trigger_crow(t, note)
                            self:schedule_note_off(t, note, tc.ch, note_len_ticks, output_ports)
                            self.last_notes[t] = { note = note, ch = tc.ch, ports = output_ports }
                        else
                            local note = self:get_pitch(t, self.fill_patterns[t][st].pitch, 0, pitch_ctx)
                            send_note_on(note, self:vel_to_midi(vel), tc.ch, output_ports)
                            self:trigger_crow(t, note)
                            self:schedule_note_off(t, note, tc.ch, note_len_ticks, output_ports)
                            self.last_notes[t] = { note = note, ch = tc.ch, ports = output_ports }
                        end
                    else
                        vel = step_data.vel
                        if tc.type == "drum" then
                            local note = clamp(tc.note, 0, 127)
                            send_note_on(note, self:vel_to_midi(vel), tc.ch, output_ports)
                            self:trigger_crow(t, note)
                            self:schedule_note_off(t, note, tc.ch, note_len_ticks, output_ports)
                            self.last_notes[t] = { note = note, ch = tc.ch, ports = output_ports }
                        elseif tc.type == "poly" then
                            local sp = self.spice[t] and self.spice[t][st]
                            local spice_offset = sp and sp.current or 0
                            local notes = {}
                            local chord = {}
                            for _, d in ipairs(step_data.pitch or {}) do
                                chord[#chord + 1] = self:get_pitch(t, d, spice_offset, pitch_ctx)
                            end
                            for _, note in ipairs(chord) do
                                send_note_on(note, self:vel_to_midi(vel), tc.ch, output_ports)
                                self:trigger_crow(t, note)
                                self:schedule_note_off(t, note, tc.ch, note_len_ticks, output_ports)
                                notes[#notes + 1] = { note = note, ch = tc.ch, ports = output_ports }
                            end
                            if #notes > 0 then
                                self.last_notes[t] = notes
                            end
                        else
                            local sp = self.spice[t] and self.spice[t][st]
                            local spice_offset = sp and sp.current or 0
                            local note = self:get_pitch(t, step_data.pitch, spice_offset, pitch_ctx)
                            send_note_on(note, self:vel_to_midi(vel), tc.ch, output_ports)
                            self:trigger_crow(t, note)
                            self:schedule_note_off(t, note, tc.ch, note_len_ticks, output_ports)
                            self.last_notes[t] = { note = note, ch = tc.ch, ports = output_ports }
                        end
                    end
                end

                local ts = tonumber(self.track_steps[t]) or 1
                if len > 0 and ts % len == 0 then
                    self:apply_track_evolving_randomization(t)
                    self.track_loop_count[t] = (tonumber(self.track_loop_count[t]) or 1) + 1
                end
                self.track_steps[t] = ts + 1

                local sp = self.spice[t] and self.spice[t][st]
                if sp and sp.amount ~= 0 and should_play and not tr.muted then
                    sp.current = (tonumber(sp.current) or 0) + (tonumber(sp.amount) or 0)
                    if sp.current > self.spice_accum_max then
                        sp.current = self.spice_accum_min
                    elseif sp.current < self.spice_accum_min then
                        sp.current = self.spice_accum_max
                    end
                end
                end
            end
        end
        return total_hits
    end

    function App:advance_clock(delta_ticks)
        local t_start
        if self.clock_debug_enabled then
            t_start = (util.time() or 0) * 1000
            self:clock_debug_on_tick_start(t_start)
        end

        local ticks = math.max(tonumber(delta_ticks) or 1, 0.0001)
        self.transport_clock = (tonumber(self.transport_clock) or 0) + ticks
        self.clock_ticks = (tonumber(self.clock_ticks) or 0) + ticks

        local step_boundary = false
        while self.clock_ticks >= cfg.MIDI_CLOCK_TICKS_PER_STEP do
            self.clock_ticks = self.clock_ticks - cfg.MIDI_CLOCK_TICKS_PER_STEP
            local _, meta_reset = self:apply_pending_resets_on_step_boundary()
            self:update_repeat_window()
            if not meta_reset then
                self:update_transpose_seq_clock()
            end
            step_boundary = true
            if self.clock_debug_enabled and self.clock_debug_count then
                self:clock_debug_count("boundaries", 1)
            end
        end

        local hits = self:play_tracks(ticks / cfg.MIDI_CLOCK_TICKS_PER_STEP)
        if self.clock_debug_enabled and self.clock_debug_count then
            self:clock_debug_count("track_hits", hits)
        end
        self:process_scheduled_note_ons()
        self:process_scheduled_note_offs()
        if hits > 0 and not step_boundary and self.request_main_grid_redraw then
            self:request_main_grid_redraw()
        end

        if step_boundary then
            if self.master_seq_len_enabled then
                self.master_seq_counter = (tonumber(self.master_seq_counter) or 0) + 1
                local max_len = clamp(tonumber(self.master_seq_len) or cfg.DEFAULT_MASTER_SEQ_LEN, 1, cfg.MAX_MASTER_SEQ_LEN)
                if self.master_seq_counter >= max_len then
                    self.master_seq_counter = 0
                    self:reset_tracks_to_start_positions()
                end
            end

            if self.beat_repeat_mode == "step-select" then
                if self.beat_repeat_select_active then
                    self.beat_repeat_select_cycle = (tonumber(self.beat_repeat_select_cycle) or 0) + 1
                end
            elseif self.beat_repeat_len > 0 then
                self.beat_repeat_cycle = self.beat_repeat_cycle + 1
            end
            self.step = self:get_track_step(1)
            self:request_redraw()
        end

        if self.clock_debug_enabled and t_start then
            local total = ((util.time() or 0) * 1000) - t_start
            self:clock_debug_on_tick_end(total)
            if self.clock_debug_maybe_write_rates then
                self:clock_debug_maybe_write_rates((util.time() or 0) * 1000)
            end
        end
    end

    function App:advance_clock_tick()
        self:advance_clock(1)
    end

    function App:tick()
        if not self.playing then return end
        for _ = 1, cfg.MIDI_CLOCK_TICKS_PER_STEP do
            self:advance_clock(1)
        end
    end

    function App:stop_all_notes()
        for _, data in pairs(self.last_notes) do
            if data.note then
                self:midi_note_off(data.note, 0, data.ch, data.ports)
            else
                for _, nd in ipairs(data) do
                    self:midi_note_off(nd.note, 0, nd.ch, nd.ports)
                end
            end
        end
        if type(self.midi_in_active_notes) == "table" then
            for _, by_channel in pairs(self.midi_in_active_notes) do
                if type(by_channel) == "table" then
                    for _, by_note in pairs(by_channel) do
                        if type(by_note) == "table" then
                            for _, nd in pairs(by_note) do
                                if nd and nd.note then
                                    self:midi_note_off(nd.note, 0, nd.ch, nd.ports)
                                end
                            end
                        end
                    end
                end
            end
        end
        self.last_notes = {}
        self.active_note_offs = {}
        self.active_scheduled_note_ons = {}
        self.midi_in_active_notes = {}
        self.midi_in_record_holds = {}
        self.midi_record_skip_once = {}
    end

    function App:start()
        if self.playing then return end
        self.playing = true
        self:reset_playheads()
        self:update_clock_tempo(self.tempo_bpm)
        self:reset_external_clock_sync()
        if self.clock_debug_enabled then
            self:clock_debug_reset_state()
            self:clock_debug_log(string.format("[%s] start mode=%s tempo=%s",
                os.date("%H:%M:%S"),
                self.use_midi_clock and "external" or "internal",
                tostring(self.tempo_bpm)))
        end

        if not self.use_midi_clock and self.send_midi_start_stop_out then
            self:midi_realtime_start()
        end

        if not self.use_midi_clock and self.send_midi_clock_out then
            if self.midi_clock_out_id then clock.cancel(self.midi_clock_out_id) end
            self.midi_clock_out_id = clock.run(function()
                while self.playing and not self.use_midi_clock and self.send_midi_clock_out do
                    clock.sync(1 / 24)
                    self:midi_realtime_clock()
                end
            end)
        end

        self:ensure_transport_scheduler_running()
        self:request_redraw()
        self:request_aux_redraw()
    end

    function App:run_internal_clock_iteration(delta_ticks)
        local ok, err = pcall(function()
            if delta_ticks ~= nil then
                self:advance_clock(delta_ticks)
            else
                self:advance_clock_tick()
            end
        end)
        if not ok then
            local line = string.format("[%s] transport error: %s", os.date("%H:%M:%S"), tostring(err))
            if self.clock_debug_enabled and self.clock_debug_log then
                self:clock_debug_log(line)
            end
            print(line)
        end
        return ok, err
    end

    function App:stop()
        self.playing = false
        if self.clock_debug_enabled then self:clock_debug_reset_state() end
        self:clear_realtime_row_holds()
        if not self.use_midi_clock and self.send_midi_start_stop_out then
            self:midi_realtime_stop()
        end
        if self.internal_clock_id then
            clock.cancel(self.internal_clock_id)
            self.internal_clock_id = nil
        end
        if self.transport_scheduler_id then
            clock.cancel(self.transport_scheduler_id)
            self.transport_scheduler_id = nil
        end
        if self.midi_clock_out_id then
            clock.cancel(self.midi_clock_out_id)
            self.midi_clock_out_id = nil
        end
        self:reset_external_clock_sync()
        self:stop_all_notes()
        self:request_redraw()
        self:request_aux_redraw()
    end

    function App:restart_transport_if_needed()
        if self.playing then
            self:stop()
            self:start()
        else
            if self.internal_clock_id then
                clock.cancel(self.internal_clock_id)
                self.internal_clock_id = nil
            end
            if self.transport_scheduler_id then
                clock.cancel(self.transport_scheduler_id)
                self.transport_scheduler_id = nil
            end
            if self.midi_clock_out_id then
                clock.cancel(self.midi_clock_out_id)
                self.midi_clock_out_id = nil
            end
        end
    end

end

return M
