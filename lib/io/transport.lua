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
    function App:queue_meta_reset_on_next_beat()
        self.pending_meta_reset_on_beat = true
    end

    function App:queue_transport_align_on_next_beat()
        self.pending_transport_align_on_beat = true
        self.pending_meta_reset_on_beat = true
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
            self.transpose_seq_step = 1
            self.transpose_seq_clock_phase = 0
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
        for t = 1, cfg.NUM_TRACKS do
            local tr = self:ensure_track_state(t)
            local tc = self.track_cfg[t]
            local step_cache = self:build_arc_step_cache(t, tr, tc)
            local len = math.abs((tonumber(tr.end_step) or cfg.NUM_STEPS) - (tonumber(tr.start_step) or 1)) + 1
            local mult = self.track_clock_mult[t]
            local div = self.track_clock_div[t]
            local ratio = (mult / div) * scale
            self.track_clock_phase[t] = (tonumber(self.track_clock_phase[t]) or 0) + ratio
            local hits = math.floor(self.track_clock_phase[t])
            if hits > 0 then
                self.track_clock_phase[t] = self.track_clock_phase[t] - hits
            end

            if hits > 0 and t == self.sel_track then
                self:request_aux_redraw()
            end

            for _ = 1, hits do
                local st = self:get_track_step(t)
                local gate_ticks = clamp(
                    tonumber(self.track_gate_ticks[t]) or
                    ((tc.type == "drum") and self.drum_gate_clocks or self.melody_gate_clocks), 1, 24)
                local has_fill = self.fill_active and self.fill_patterns[t][st]
                local step_data = step_cache[st]
                local ratio_allows = step_data and self:step_ratio_allows_play(t, st)
                local is_tie_step = step_data and step_data.source == "manual" and step_data.tie and ratio_allows
                local should_play = ((step_data and ratio_allows and (not is_tie_step or not self.last_notes[t])) or has_fill)

                if self.last_notes[t] and not is_tie_step then
                    self:note_off_last_for_track(t)
                end

                if not tr.muted and should_play then
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
                            self:midi_note_on(note, self:vel_to_midi(vel), tc.ch, output_ports)
                            self:trigger_crow(t, note)
                            self:schedule_note_off(t, note, tc.ch, note_len_ticks, output_ports)
                            self.last_notes[t] = { note = note, ch = tc.ch, ports = output_ports }
                        else
                            local note = self:get_pitch(t, self.fill_patterns[t][st].pitch, 0, pitch_ctx)
                            self:midi_note_on(note, self:vel_to_midi(vel), tc.ch, output_ports)
                            self:trigger_crow(t, note)
                            self:schedule_note_off(t, note, tc.ch, note_len_ticks, output_ports)
                            self.last_notes[t] = { note = note, ch = tc.ch, ports = output_ports }
                        end
                    else
                        vel = step_data.vel
                        if tc.type == "drum" then
                            local note = clamp(tc.note, 0, 127)
                            self:midi_note_on(note, self:vel_to_midi(vel), tc.ch, output_ports)
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
                                self:midi_note_on(note, self:vel_to_midi(vel), tc.ch, output_ports)
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
                            self:midi_note_on(note, self:vel_to_midi(vel), tc.ch, output_ports)
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

    function App:advance_clock_tick()
        local t_start
        if self.clock_debug_enabled then
            t_start = (util.time() or 0) * 1000
            self:clock_debug_on_tick_start(t_start)
        end

        self.transport_clock = self.transport_clock + 1
        self.clock_ticks = self.clock_ticks + 1

        local step_boundary = false
        if self.clock_ticks >= cfg.MIDI_CLOCK_TICKS_PER_STEP then
            self.clock_ticks = self.clock_ticks - cfg.MIDI_CLOCK_TICKS_PER_STEP
            local _, meta_reset = self:apply_pending_resets_on_step_boundary()
            self:update_repeat_window()
            if not meta_reset then
                self:update_transpose_seq_clock()
            end
            step_boundary = true
        end

        self:play_tracks(1 / cfg.MIDI_CLOCK_TICKS_PER_STEP)
        self:process_scheduled_note_offs()
        self.grid_dirty = true

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
        end
    end

    function App:tick()
        if not self.playing then return end
        for _ = 1, cfg.MIDI_CLOCK_TICKS_PER_STEP do
            self:advance_clock_tick()
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
        self.last_notes = {}
        self.active_note_offs = {}
    end

    function App:start()
        if self.playing then return end
        self.playing = true
        self:reset_playheads()
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

        if not self.use_midi_clock then
            if self.internal_clock_id then clock.cancel(self.internal_clock_id) end
            self.internal_clock_id = clock.run(function()
                while self.playing and not self.use_midi_clock do
                    clock.sync(1 / 24)
                    self:run_internal_clock_iteration()
                end
            end)
        end
        self:request_redraw()
        self:request_aux_redraw()
    end

    function App:run_internal_clock_iteration()
        local ok, err = pcall(function()
            self:advance_clock_tick()
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
        if self.midi_clock_out_id then
            clock.cancel(self.midi_clock_out_id)
            self.midi_clock_out_id = nil
        end
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
            if self.midi_clock_out_id then
                clock.cancel(self.midi_clock_out_id)
                self.midi_clock_out_id = nil
            end
        end
    end

end

return M
