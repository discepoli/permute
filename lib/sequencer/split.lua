local H = include("lib/core/util")
local cfg = H.cfg
local clamp = H.clamp

local M = {}

M.GATE_COL_START = 1
M.GATE_COL_END = cfg.SPLIT_NUM_GATES or 8
M.PITCH_COL_START = (cfg.SPLIT_NUM_GATES or 8) + 1
M.PITCH_COL_END = (cfg.SPLIT_NUM_GATES or 8) * 2

M.PITCH_COLS = cfg.SPLIT_NUM_GATES or 8

M.GATE_STAGE_PLAYBACK = {
    TRIGGERED = 1,
    RATCHET = 2,
    HELD = 3,
}

M.GATE_STAGE_PLAYBACK_COL_START = 11
M.GATE_STAGE_PITCH_ADVANCE_COL_ON = 15
M.GATE_STAGE_PITCH_ADVANCE_COL_OFF = 16

M.TAKEOVER_GATE_PITCH_ADVANCE_OFF_ROW = 1
M.TAKEOVER_GATE_PITCH_ADVANCE_ON_ROW = 2
M.TAKEOVER_GATE_PLAYBACK_HELD_ROW = 4
M.TAKEOVER_GATE_PLAYBACK_RATCHET_ROW = 5
M.TAKEOVER_GATE_PLAYBACK_TRIGGERED_ROW = 6
M.TAKEOVER_GATE_CONTROL_END_ROW = 8

function M.takeover_row_to_playback(row)
    row = tonumber(row) or 0
    if row == M.TAKEOVER_GATE_PLAYBACK_TRIGGERED_ROW then return M.GATE_STAGE_PLAYBACK.TRIGGERED end
    if row == M.TAKEOVER_GATE_PLAYBACK_RATCHET_ROW then return M.GATE_STAGE_PLAYBACK.RATCHET end
    if row == M.TAKEOVER_GATE_PLAYBACK_HELD_ROW then return M.GATE_STAGE_PLAYBACK.HELD end
    return nil
end

function M.playback_to_takeover_row(playback)
    playback = clamp(tonumber(playback) or M.GATE_STAGE_PLAYBACK.TRIGGERED, 1, #cfg.SPLIT_GATE_STAGE_PLAYBACK)
    if playback == M.GATE_STAGE_PLAYBACK.TRIGGERED then return M.TAKEOVER_GATE_PLAYBACK_TRIGGERED_ROW end
    if playback == M.GATE_STAGE_PLAYBACK.RATCHET then return M.TAKEOVER_GATE_PLAYBACK_RATCHET_ROW end
    return M.TAKEOVER_GATE_PLAYBACK_HELD_ROW
end

function M.takeover_step_count_from_row(row, takeover_rows)
    row = tonumber(row) or 0
    takeover_rows = tonumber(takeover_rows) or 1
    if row <= M.TAKEOVER_GATE_CONTROL_END_ROW or row > takeover_rows then return nil end
    return takeover_rows - row + 1
end

function M.takeover_rows_for_step_count(step_count, takeover_rows)
    step_count = clamp(tonumber(step_count) or 1, 1, takeover_rows)
    takeover_rows = tonumber(takeover_rows) or 1
    return takeover_rows - step_count + 1, takeover_rows
end

function M.gate_stage_playback_col(mode)
    return M.GATE_STAGE_PLAYBACK_COL_START + clamp(tonumber(mode) or 1, 1, #cfg.SPLIT_GATE_STAGE_PLAYBACK) - 1
end

function M.migrate_legacy_gate_mode(mode)
    local m = clamp(tonumber(mode) or 2, 1, 5)
    if m == 5 then
        return M.GATE_STAGE_PLAYBACK.HELD, false
    elseif m == 3 then
        return M.GATE_STAGE_PLAYBACK.RATCHET, false
    elseif m == 4 then
        return M.GATE_STAGE_PLAYBACK.RATCHET, true
    end
    return M.GATE_STAGE_PLAYBACK.TRIGGERED, false
end

function M.default_split_state()
    local num = cfg.SPLIT_NUM_GATES or 8
    local sp = {
        gates = {},
        gate_stage_steps = {},
        gate_stage_playback = {},
        gate_stage_pitch_advance = {},
        pitches = {},
        gate_start = 1,
        gate_end = num,
        pitch_start = 1,
        pitch_end = num,
    }
    for i = 1, num do
        sp.gates[i] = false
        sp.gate_stage_steps[i] = 1
        sp.gate_stage_playback[i] = M.GATE_STAGE_PLAYBACK.TRIGGERED
        sp.gate_stage_pitch_advance[i] = true
        sp.pitches[i] = 1
    end
    return sp
end

function M.ensure_split_state(tr)
    if type(tr.split) ~= "table" then
        tr.split = M.default_split_state()
        return tr.split
    end

    local num = cfg.SPLIT_NUM_GATES or 8
    local sp = tr.split
    if type(sp.gates) ~= "table" then sp.gates = {} end
    if type(sp.pitches) ~= "table" then sp.pitches = {} end
    if type(sp.gate_stage_steps) ~= "table" then sp.gate_stage_steps = sp.durations or {} end
    if type(sp.gate_stage_playback) ~= "table" then sp.gate_stage_playback = sp.gate_modes or {} end
    if type(sp.gate_stage_pitch_advance) ~= "table" then sp.gate_stage_pitch_advance = {} end

    local legacy_mode = clamp(tonumber(sp.playback_mode) or 2, 1, 5)

    for i = 1, num do
        sp.gates[i] = not not sp.gates[i]
        sp.pitches[i] = clamp(tonumber(sp.pitches[i]) or 1, cfg.MIN_SCALE_DEGREE, cfg.MAX_SCALE_DEGREE)
        sp.gate_stage_steps[i] = clamp(tonumber(sp.gate_stage_steps[i]) or 1, 1, num)

        local playback = tonumber(sp.gate_stage_playback[i])
        local pitch_advance = sp.gate_stage_pitch_advance[i]
        if playback == nil then
            playback, pitch_advance = M.migrate_legacy_gate_mode(sp.gate_modes and sp.gate_modes[i] or legacy_mode)
        elseif pitch_advance == nil then
            pitch_advance = true
        end
        sp.gate_stage_playback[i] = clamp(playback, 1, #cfg.SPLIT_GATE_STAGE_PLAYBACK)
        sp.gate_stage_pitch_advance[i] = not not pitch_advance
    end

    sp.gate_start = clamp(tonumber(sp.gate_start) or 1, 1, num)
    sp.gate_end = clamp(tonumber(sp.gate_end) or num, 1, num)
    sp.pitch_start = clamp(tonumber(sp.pitch_start) or 1, 1, num)
    sp.pitch_end = clamp(tonumber(sp.pitch_end) or num, 1, num)
    if sp.gate_end < sp.gate_start then sp.gate_start, sp.gate_end = sp.gate_end, sp.gate_start end
    if sp.pitch_end < sp.pitch_start then sp.pitch_start, sp.pitch_end = sp.pitch_end, sp.pitch_start end

    sp.durations = nil
    sp.gate_modes = nil
    sp.playback_mode = nil
    return sp
end

function M.get_gate_stage_playback(sp, gate_idx)
    local num = cfg.SPLIT_NUM_GATES or 8
    local idx = clamp(tonumber(gate_idx) or 1, 1, num)
    return clamp(
        tonumber((sp.gate_stage_playback or {})[idx]) or M.GATE_STAGE_PLAYBACK.TRIGGERED,
        1,
        #cfg.SPLIT_GATE_STAGE_PLAYBACK
    )
end

function M.get_gate_stage_pitch_advance(sp, gate_idx)
    local num = cfg.SPLIT_NUM_GATES or 8
    local idx = clamp(tonumber(gate_idx) or 1, 1, num)
    local val = (sp.gate_stage_pitch_advance or {})[idx]
    if val == nil then return true end
    return not not val
end

function M.is_split_track_type(track_type)
    return track_type == "split"
end

function M.is_pitch_col(col)
    local c = tonumber(col) or 0
    return c >= M.PITCH_COL_START and c <= M.PITCH_COL_END
end

function M.is_gate_col(col)
    local c = tonumber(col) or 0
    return c >= M.GATE_COL_START and c <= M.GATE_COL_END
end

function M.col_to_pitch_index(col)
    if not M.is_pitch_col(col) then return nil end
    return col - M.PITCH_COL_START + 1
end

function M.col_to_gate_index(col)
    if not M.is_gate_col(col) then return nil end
    return col - M.GATE_COL_START + 1
end

function M.pitch_index_to_col(pitch_idx)
    return M.PITCH_COL_START + pitch_idx - 1
end

function M.gate_index_to_col(gate_idx)
    return M.GATE_COL_START + gate_idx - 1
end

function M.get_gate_bounds(sp, num)
    num = num or cfg.SPLIT_NUM_GATES or 8
    local lo = clamp(tonumber(sp.gate_start) or 1, 1, num)
    local hi = clamp(tonumber(sp.gate_end) or num, 1, num)
    if hi < lo then lo, hi = hi, lo end
    return lo, hi
end

function M.get_pitch_bounds(sp, num)
    num = num or cfg.SPLIT_NUM_GATES or 8
    local lo = clamp(tonumber(sp.pitch_start) or 1, 1, num)
    local hi = clamp(tonumber(sp.pitch_end) or num, 1, num)
    if hi < lo then lo, hi = hi, lo end
    return lo, hi
end

function M.advance_bound_pos(pos, lo, hi)
    local p = clamp(tonumber(pos) or lo, lo, hi)
    if p >= hi then return lo end
    return p + 1
end

function M.wrap_index(idx, len)
    local n = tonumber(len) or 1
    if n <= 0 then return 1 end
    local i = tonumber(idx) or 1
    return ((i - 1) % n) + 1
end

M.SPLIT_ARC_VARIANCE_WAVE_MODE = 1

function M.is_arc_only_gate(app, track, tr, sp, gate_idx)
    local idx = clamp(tonumber(gate_idx) or 1, 1, cfg.SPLIT_NUM_GATES or 8)
    if (sp.gates or {})[idx] then return false end
    return app:split_arc_gate_active(track, tr, sp, idx)
end

function M.get_arc_playback_preset_index(arc)
    local presets = cfg.ARC_SPLIT_PLAYBACK_PRESETS or {}
    return clamp(tonumber(arc and arc.mode) or 1, 1, math.max(1, #presets))
end

function M.get_arc_playback_preset(arc)
    local presets = cfg.ARC_SPLIT_PLAYBACK_PRESETS or {}
    return presets[M.get_arc_playback_preset_index(arc)] or presets[1]
end

function M.get_effective_gate_playback(app, track, tr, sp, gate_idx)
    if not M.is_arc_only_gate(app, track, tr, sp, gate_idx) then
        return M.get_gate_stage_playback(sp, gate_idx)
    end
    local preset = M.get_arc_playback_preset(app:get_arc_state(track))
    return clamp(
        tonumber(preset and preset.playback) or M.GATE_STAGE_PLAYBACK.TRIGGERED,
        1,
        #cfg.SPLIT_GATE_STAGE_PLAYBACK
    )
end

function M.get_effective_pitch_advance(app, track, tr, sp, gate_idx)
    if not M.is_arc_only_gate(app, track, tr, sp, gate_idx) then
        return M.get_gate_stage_pitch_advance(sp, gate_idx)
    end
    local preset = M.get_arc_playback_preset(app:get_arc_state(track))
    return not not (preset and preset.pitch_advance)
end

function M.get_effective_stage_steps(app, track, tr, sp, gate_idx)
    local num = cfg.SPLIT_NUM_GATES or 8
    local idx = clamp(tonumber(gate_idx) or 1, 1, num)
    local baseline = clamp(tonumber(sp.gate_stage_steps[idx]) or 1, 1, num)

    if not M.is_arc_only_gate(app, track, tr, sp, idx) then
        return baseline
    end

    local arc = app:get_arc_state(track)
    local variance = clamp(tonumber(arc and arc.variance) or 0, 0, 100)
    local amount = variance / 100
    local max_cap = num

    local order, _, positions, phase_positions = app:get_arc_pattern(track)
    local len = math.max(1, #order)
    local pos = clamp(tonumber(phase_positions[idx]) or positions[idx] or 1, 1, len)
    local wave = app:get_arc_wave_value(track, pos, len, M.SPLIT_ARC_VARIANCE_WAVE_MODE)
    local norm = (wave + 1) * 0.5
    local wave_target = 1 + norm * (max_cap - 1)
    local filled = baseline + amount * (wave_target - baseline)
    return clamp(math.floor(filled + 0.5), 1, max_cap)
end

function M.split_enable_gate(sp, gate_idx)
    local idx = clamp(tonumber(gate_idx) or 1, 1, cfg.SPLIT_NUM_GATES or 8)
    if sp.gate_stage_pitch_advance[idx] == nil then
        sp.gate_stage_pitch_advance[idx] = true
    end
    sp.gates[idx] = true
end

function M.reset_cursors(app, track, sp)
    local t = clamp(tonumber(track) or 1, 1, cfg.NUM_TRACKS)
    sp = sp or {}
    local gate_lo = clamp(tonumber(sp.gate_start) or 1, 1, cfg.SPLIT_NUM_GATES or 8)
    local pitch_lo = clamp(tonumber(sp.pitch_start) or 1, 1, cfg.SPLIT_NUM_GATES or 8)
    app.split_gate_pos[t] = gate_lo
    app.split_pitch_pos[t] = pitch_lo
    app.split_gate_substep[t] = 0
    app.split_gate_hold_active[t] = false
    app.split_arc_pitch_pos[t] = 1
end

function M.process_step(app, track, tr, tc, pitch_ctx)
    local t = clamp(tonumber(track) or 1, 1, cfg.NUM_TRACKS)
    local sp = M.ensure_split_state(tr)
    local num = cfg.SPLIT_NUM_GATES or 8
    local gate_lo, gate_hi = M.get_gate_bounds(sp, num)
    local pitch_lo, pitch_hi = M.get_pitch_bounds(sp, num)
    local gate_idx = clamp(tonumber(app.split_gate_pos[t]) or gate_lo, gate_lo, gate_hi)
    local pitch_idx = clamp(tonumber(app.split_pitch_pos[t]) or pitch_lo, pitch_lo, pitch_hi)
    local playback = M.get_effective_gate_playback(app, track, tr, sp, gate_idx)
    local pitch_advance_steps = M.get_effective_pitch_advance(app, track, tr, sp, gate_idx)
    local gate_live = app:split_gate_is_live(t, tr, sp, gate_idx)
    local ratio_allows = app:step_ratio_allows_play(t, gate_idx)
    local stage_steps = M.get_effective_stage_steps(app, track, tr, sp, gate_idx)
    local substep = clamp(tonumber(app.split_gate_substep[t]) or 0, 0, num)

    local sp_pitch = app.spice[t] and app.spice[t][pitch_idx]
    local spice_offset = sp_pitch and sp_pitch.current or 0

    local result = {
        should_play = false,
        advance_pitch_substep = false,
        advance_pitch_stage = false,
        advance_gate = false,
        note_len_ticks = cfg.MIDI_CLOCK_TICKS_PER_STEP,
        degree = sp.pitches[pitch_idx],
        spice_offset = spice_offset,
        gate_idx = gate_idx,
        pitch_idx = pitch_idx,
        gate_stage_playback = playback,
    }

    if not gate_live or not ratio_allows then
        app.split_gate_substep[t] = 0
        app.split_gate_hold_active[t] = false
        result.advance_gate = true
        result.advance_pitch_stage = true
        return result
    end

    if playback == M.GATE_STAGE_PLAYBACK.HELD then
        if not app.split_gate_hold_active[t] then
            result.should_play = true
            result.note_len_ticks = stage_steps * cfg.MIDI_CLOCK_TICKS_PER_STEP
            app.split_gate_hold_active[t] = true
        end
        substep = substep + 1
        if substep >= stage_steps then
            app.split_gate_substep[t] = 0
            app.split_gate_hold_active[t] = false
            result.advance_gate = true
            result.advance_pitch_stage = true
        else
            app.split_gate_substep[t] = substep
        end
        return result
    end

    if playback == M.GATE_STAGE_PLAYBACK.RATCHET then
        app.split_gate_substep[t] = 0
        app.split_gate_hold_active[t] = false
        result.ratchet_hits = stage_steps
        result.advance_gate = true
        result.advance_pitch_stage = true
        if pitch_advance_steps then
            result.ratchet_pitch_advance = true
        end
        return result
    end

    result.should_play = true
    result.note_len_ticks = cfg.MIDI_CLOCK_TICKS_PER_STEP

    if pitch_advance_steps then
        result.advance_pitch_substep = true
    end

    substep = substep + 1
    if substep >= stage_steps then
        app.split_gate_substep[t] = 0
        result.advance_gate = true
        result.advance_pitch_stage = true
    else
        app.split_gate_substep[t] = substep
    end

    return result
end

function M.play_ratchet_hits(app, track, tr, tc, pitch_ctx, result, step_ticks, send_note_on)
    local t = clamp(tonumber(track) or 1, 1, cfg.NUM_TRACKS)
    if tr.muted then return end

    local sp = M.ensure_split_state(tr)
    local pitch_lo, pitch_hi = M.get_pitch_bounds(sp)
    local n = clamp(tonumber(result.ratchet_hits) or 1, 1, cfg.SPLIT_NUM_GATES or 8)
    local step_len = math.max(0.001, tonumber(step_ticks) or cfg.MIDI_CLOCK_TICKS_PER_STEP)
    local hit_len = step_len / n
    local vel = app:vel_to_midi(app:get_track_default_vel_level(track))
    local ports = app.midi_out_ports_snapshot
    local pitch_pos = clamp(tonumber(app.split_pitch_pos[t]) or pitch_lo, pitch_lo, pitch_hi)

    for hit = 1, n do
        local pitch_idx = pitch_pos
        local sp_pitch = app.spice[t] and app.spice[t][pitch_idx]
        local spice_offset = sp_pitch and sp_pitch.current or 0
        local degree = sp.pitches[pitch_idx]
        local note = app:get_pitch(track, degree, spice_offset, pitch_ctx)
        local on_delay = (hit - 1) * hit_len

        if on_delay <= 1e-9 then
            send_note_on(note, vel, tc.ch)
            app:trigger_crow(track, note)
            app:schedule_note_off(track, note, tc.ch, hit_len, ports)
            app.last_notes[t] = { note = note, ch = tc.ch, ports = ports }
        else
            app:schedule_delayed_note_on(
                track,
                note,
                vel,
                tc.ch,
                on_delay,
                hit_len,
                ports
            )
        end

        if sp_pitch and sp_pitch.amount ~= 0 then
            sp_pitch.current = (tonumber(sp_pitch.current) or 0) + (tonumber(sp_pitch.amount) or 0)
            if sp_pitch.current > app.spice_accum_max then
                sp_pitch.current = app.spice_accum_min
            elseif sp_pitch.current < app.spice_accum_min then
                sp_pitch.current = app.spice_accum_max
            end
        end

        if result.ratchet_pitch_advance and hit < n then
            pitch_pos = M.advance_bound_pos(pitch_pos, pitch_lo, pitch_hi)
        end
    end

    if result.ratchet_pitch_advance then
        app.split_pitch_pos[t] = pitch_pos
    end
end

function M.advance_pitch_cursor(app, track, tr, sp)
    local t = clamp(tonumber(track) or 1, 1, cfg.NUM_TRACKS)
    sp = sp or M.ensure_split_state(tr)
    local pitch_lo, pitch_hi = M.get_pitch_bounds(sp)
    app.split_arc_pitch_pos[t] = 1
    app.split_pitch_pos[t] = M.advance_bound_pos(app.split_pitch_pos[t], pitch_lo, pitch_hi)
end

function M.advance_after_play(app, track, tr, result)
    local t = clamp(tonumber(track) or 1, 1, cfg.NUM_TRACKS)
    local sp = M.ensure_split_state(tr)
    local gate_lo, gate_hi = M.get_gate_bounds(sp)

    if result.advance_pitch_substep and result.should_play then
        M.advance_pitch_cursor(app, track, tr, sp)
    end

    if result.advance_gate then
        if result.advance_pitch_stage then
            M.advance_pitch_cursor(app, track, tr, sp)
        end
        app.split_gate_pos[t] = M.advance_bound_pos(app.split_gate_pos[t], gate_lo, gate_hi)
        app.split_gate_substep[t] = 0
        app.split_gate_hold_active[t] = false
    end
end

function M.install(App)
    function App:is_track_split(track)
        local t = clamp(tonumber(track) or tonumber(self.sel_track) or 1, 1, cfg.NUM_TRACKS)
        local tc = self.track_cfg[t]
        return tc and M.is_split_track_type(tc.type)
    end

    function App:ensure_split_track_state(track)
        local tr = self:ensure_track_state(track)
        if not tr then return nil end
        return M.ensure_split_state(tr)
    end

    function App:reset_split_cursors(track)
        if track then
            local tr = self.tracks[track]
            M.reset_cursors(self, track, tr and tr.split or nil)
            return
        end
        for t = 1, cfg.NUM_TRACKS do
            if self:is_track_split(t) then
                local tr = self.tracks[t]
                M.reset_cursors(self, t, tr and tr.split or nil)
            end
        end
    end

    function App:get_split_gate_bounds(tr)
        local sp = M.ensure_split_state(tr)
        return M.get_gate_bounds(sp)
    end

    function App:get_split_pitch_bounds(tr)
        local sp = M.ensure_split_state(tr)
        return M.get_pitch_bounds(sp)
    end

    function App:split_gate_is_live(track, tr, sp, gate_idx)
        sp = sp or M.ensure_split_state(tr)
        if sp.gates[gate_idx] then return true end
        if self.fill_active and type(self.fill_split_gates) == "table"
            and type(self.fill_split_gates[track]) == "table"
            and self.fill_split_gates[track][gate_idx] then
            return true
        end
        return self:split_arc_gate_active(track, tr, sp, gate_idx)
    end

    function App:clear_fill_split_gates()
        self.fill_split_gates = {}
    end

    function App:split_arc_gate_active(track, tr, sp, gate_idx)
        local arc = self:get_arc_state(track)
        if not arc or (tonumber(arc.pulses) or 0) <= 0 then return false end
        local _, active = self:get_arc_pattern(track)
        return not not active[gate_idx]
    end

    function App:get_split_gate_stage_playback(tr, gate_idx, track)
        local sp = M.ensure_split_state(tr)
        track = track or self.sel_track
        return M.get_effective_gate_playback(self, track, tr, sp, gate_idx)
    end

    function App:get_split_arc_playback_preset_name(track)
        track = track or self.sel_track
        local arc = self:get_arc_state(track)
        local preset = M.get_arc_playback_preset(arc)
        return (preset and preset.name) or "?"
    end

    function App:split_modifiers_active()
        return next(self.mod_held) ~= nil
    end

    function App:set_split_edit(track, region, index)
        local t = clamp(tonumber(track) or 1, 1, cfg.NUM_TRACKS)
        local idx = clamp(tonumber(index) or 1, 1, cfg.SPLIT_NUM_GATES)
        self.split_edit = { t = t, region = region, index = idx }
    end

    function App:clear_split_edit(track)
        if not self.split_edit then return end
        if track and self.split_edit.t ~= track then return end
        self.split_edit = nil
    end

    function App:get_split_edit(track)
        local edit = self.split_edit
        if type(edit) ~= "table" then return nil end
        local t = clamp(tonumber(track) or tonumber(self.sel_track) or 1, 1, cfg.NUM_TRACKS)
        if edit.t ~= t then return nil end
        return edit
    end

    function App:split_col_to_region(col)
        if M.is_pitch_col(col) then
            return "pitch", M.col_to_pitch_index(col)
        end
        if M.is_gate_col(col) then
            return "gate", M.col_to_gate_index(col)
        end
        return nil, nil
    end

    function App:get_split_effective_stage_steps(tr, sp, gate_idx)
        local t = clamp(tonumber(self.sel_track) or 1, 1, cfg.NUM_TRACKS)
        return M.get_effective_stage_steps(self, t, tr, sp, gate_idx)
    end

    function App:split_bound_marker_active(kind)
        if self.speed_mode then return false end
        if kind == "start" then
            return not not (self.mod_held[cfg.MOD.START] and not self.mod_held[cfg.MOD.END_STEP])
        end
        return not not (self.mod_held[cfg.MOD.END_STEP] and not self.mod_held[cfg.MOD.START])
    end

    function App:split_gate_bound_marker_level(gate_idx, sp, lv)
        sp = sp or {}
        local idx = clamp(tonumber(gate_idx) or 1, 1, cfg.SPLIT_NUM_GATES or 8)
        if self:split_bound_marker_active("start") and idx == clamp(tonumber(sp.gate_start) or 1, 1, cfg.SPLIT_NUM_GATES or 8) then
            return 15
        end
        if self:split_bound_marker_active("end") and idx == clamp(tonumber(sp.gate_end) or cfg.SPLIT_NUM_GATES or 8, 1, cfg.SPLIT_NUM_GATES or 8) then
            return 15
        end
        return lv
    end

    function App:split_pitch_bound_marker_level(pitch_idx, sp, lv)
        sp = sp or {}
        local idx = clamp(tonumber(pitch_idx) or 1, 1, cfg.SPLIT_NUM_GATES or 8)
        if self:split_bound_marker_active("start") and idx == clamp(tonumber(sp.pitch_start) or 1, 1, cfg.SPLIT_NUM_GATES or 8) then
            return 15
        end
        if self:split_bound_marker_active("end") and idx == clamp(tonumber(sp.pitch_end) or cfg.SPLIT_NUM_GATES or 8, 1, cfg.SPLIT_NUM_GATES or 8) then
            return 15
        end
        return lv
    end

    function App:add_temp_split_gate(track, gate_idx)
        local t = clamp(tonumber(track) or 1, 1, cfg.NUM_TRACKS)
        local idx = clamp(tonumber(gate_idx) or 1, 1, cfg.SPLIT_NUM_GATES)
        if type(self.temp_split_gates) ~= "table" then self.temp_split_gates = {} end
        if type(self.temp_split_gates[t]) ~= "table" then self.temp_split_gates[t] = {} end
        self.temp_split_gates[t][idx] = true
    end

    function App:clear_temp_split_gates()
        self.temp_split_gates = {}
    end

    function App:draw_split_takeover()
        local t = clamp(tonumber(self.sel_track) or 1, 1, cfg.NUM_TRACKS)
        local tr = self:ensure_track_state(t)
        local sp = self:ensure_split_track_state(t)
        local num = cfg.SPLIT_NUM_GATES or 8
        local gate_playhead = clamp(tonumber(self.split_gate_pos[t]) or 1, 1, num)
        local pitch_playhead = clamp(tonumber(self.split_pitch_pos[t]) or 1, 1, num)
        local pitch_rows = self:get_main_takeover_note_rows()
        local scale = cfg.SCALES[self.scale_type] or cfg.SCALES.chromatic
        local _, arc_active = self:get_arc_pattern(t)

        for gate_idx = 1, num do
            local col = gate_idx
            local manual_on = not not sp.gates[gate_idx]
            local arc_on = not manual_on and arc_active[gate_idx]
            local gate_on = manual_on or arc_on
            local capacity = clamp(tonumber(sp.gate_stage_steps[gate_idx]) or 1, 1, num)
            local stage_steps = manual_on and capacity or self:get_split_effective_stage_steps(tr, sp, gate_idx)
            local playback = manual_on
                and clamp(tonumber(sp.gate_stage_playback[gate_idx]) or 1, 1, #cfg.SPLIT_GATE_STAGE_PLAYBACK)
                or M.get_effective_gate_playback(self, t, tr, sp, gate_idx)
            local pitch_advance = manual_on
                and not not sp.gate_stage_pitch_advance[gate_idx]
                or M.get_effective_pitch_advance(self, t, tr, sp, gate_idx)
            local is_playhead = (gate_playhead == gate_idx and self.playing)
            local sel_lv = gate_on and 15 or 6
            local idle_lv = gate_on and 4 or 2

            self:grid_led_main(col, M.TAKEOVER_GATE_PITCH_ADVANCE_OFF_ROW, pitch_advance and idle_lv or sel_lv)
            self:grid_led_main(col, M.TAKEOVER_GATE_PITCH_ADVANCE_ON_ROW, pitch_advance and sel_lv or idle_lv)

            for _, mode_row in ipairs({
                { row = M.TAKEOVER_GATE_PLAYBACK_HELD_ROW, mode = M.GATE_STAGE_PLAYBACK.HELD },
                { row = M.TAKEOVER_GATE_PLAYBACK_RATCHET_ROW, mode = M.GATE_STAGE_PLAYBACK.RATCHET },
                { row = M.TAKEOVER_GATE_PLAYBACK_TRIGGERED_ROW, mode = M.GATE_STAGE_PLAYBACK.TRIGGERED },
            }) do
                local lv = (playback == mode_row.mode) and sel_lv or idle_lv
                self:grid_led_main(col, mode_row.row, lv)
            end

            if gate_on then
                local step_lo, step_hi = M.takeover_rows_for_step_count(
                    math.min(stage_steps, pitch_rows - M.TAKEOVER_GATE_CONTROL_END_ROW),
                    pitch_rows
                )
                for row = step_lo, step_hi do
                    local lv = is_playhead and 15 or 10
                    if arc_on then lv = is_playhead and 11 or 7 end
                    self:grid_led_main(col, row, lv)
                end
            end

            local marker_lv = self:split_gate_bound_marker_level(gate_idx, sp, 0)
            if marker_lv > 0 then
                self:grid_led_main(col, M.TAKEOVER_GATE_PITCH_ADVANCE_OFF_ROW, marker_lv)
            end
        end

        for pitch_idx = 1, num do
            local col = M.PITCH_COL_START + pitch_idx - 1
            local in_range = pitch_idx >= sp.pitch_start and pitch_idx <= sp.pitch_end
            local degree = clamp(tonumber(sp.pitches[pitch_idx]) or 1, cfg.MIN_SCALE_DEGREE, cfg.MAX_SCALE_DEGREE)
            local is_playhead = (pitch_playhead == pitch_idx and self.playing)

            for row = 1, pitch_rows do
                local row_degree = self:main_takeover_row_to_degree(row, t)
                local is_root = ((row_degree - 1) % #scale) == 0
                local lv = 0
                if row_degree == degree then
                    lv = is_playhead and 15 or 12
                    if not in_range then lv = math.floor(lv / 2) end
                elseif is_root and in_range then
                    lv = 2
                elseif is_playhead and in_range then
                    lv = 1
                end
                lv = self:split_pitch_bound_marker_level(pitch_idx, sp, lv)
                if lv > 0 then self:grid_led_main(col, row, lv) end
            end
        end
    end

    function App:handle_split_takeover_event(col, row, z)
        local t = clamp(tonumber(self.sel_track) or 1, 1, cfg.NUM_TRACKS)
        local tr = self:ensure_track_state(t)
        local sp = self:ensure_split_track_state(t)
        local num = cfg.SPLIT_NUM_GATES or 8
        local takeover_rows = self:get_main_takeover_note_rows()

        if z ~= 1 then return false end
        self:push_undo_state("grid_step_edit")

        if col >= M.GATE_COL_START and col <= M.GATE_COL_END then
            local gate_idx = col
            local step_count = M.takeover_step_count_from_row(row, takeover_rows)
            local playback = M.takeover_row_to_playback(row)
            if step_count then
                local new_steps = clamp(step_count, 1, num)
                if sp.gates[gate_idx] and sp.gate_stage_steps[gate_idx] == new_steps then
                    sp.gates[gate_idx] = false
                else
                    sp.gate_stage_steps[gate_idx] = new_steps
                    M.split_enable_gate(sp, gate_idx)
                end
            elseif playback then
                if sp.gates[gate_idx] and sp.gate_stage_playback[gate_idx] == playback then
                    sp.gates[gate_idx] = false
                else
                    sp.gate_stage_playback[gate_idx] = playback
                end
            elseif row == M.TAKEOVER_GATE_PITCH_ADVANCE_ON_ROW then
                if sp.gates[gate_idx] and sp.gate_stage_pitch_advance[gate_idx] then
                    sp.gates[gate_idx] = false
                else
                    sp.gate_stage_pitch_advance[gate_idx] = true
                end
            elseif row == M.TAKEOVER_GATE_PITCH_ADVANCE_OFF_ROW then
                if sp.gates[gate_idx] and not sp.gate_stage_pitch_advance[gate_idx] then
                    sp.gates[gate_idx] = false
                else
                    sp.gate_stage_pitch_advance[gate_idx] = false
                end
            end
            self:invalidate_step_cache(t)
            return true
        end

        if col >= M.PITCH_COL_START and col <= M.PITCH_COL_END and row >= 1 and row <= self:get_main_takeover_note_rows() then
            local pitch_idx = col - M.PITCH_COL_START + 1
            sp.pitches[pitch_idx] = self:main_takeover_row_to_degree(row, t)
            return true
        end

        return false
    end

    function App:handle_split_aux_event(x, y, z)
        local t = clamp(tonumber(self.sel_track) or 1, 1, cfg.NUM_TRACKS)
        local num = cfg.SPLIT_NUM_GATES or 8
        local rows = cfg.AUX_GRID_ROWS
        if x < 1 or x > cfg.NUM_STEPS or y < 1 or y > rows then return false end
        if z ~= 1 then return false end

        local sp = self:ensure_split_track_state(t)
        self:push_undo_state("grid_step_edit")

        if x <= num then
            local gate_idx = x
            local step_count = rows - y + 1
            if step_count >= 1 and step_count <= num then
                if sp.gates[gate_idx] and sp.gate_stage_steps[gate_idx] == step_count then
                    sp.gates[gate_idx] = false
                else
                    sp.gate_stage_steps[gate_idx] = step_count
                    M.split_enable_gate(sp, gate_idx)
                end
            end
            return true
        end

        if x >= M.PITCH_COL_START and x <= M.PITCH_COL_END then
            local pitch_idx = x - M.PITCH_COL_START + 1
            sp.pitches[pitch_idx] = self:aux_row_to_degree(y, t)
            return true
        end

        return false
    end

    function App:play_split_track_hit(track, tr, tc, pitch_ctx, send_note_on, step_ticks)
        local result = M.process_step(self, track, tr, tc, pitch_ctx)
        if result.ratchet_hits and result.ratchet_hits > 0 then
            M.play_ratchet_hits(self, track, tr, tc, pitch_ctx, result, step_ticks, send_note_on)
        elseif result.should_play and not tr.muted then
            local vel = self:get_track_default_vel_level(track)
            local note = self:get_pitch(track, result.degree, result.spice_offset or 0, pitch_ctx)
            send_note_on(note, self:vel_to_midi(vel), tc.ch)
            self:trigger_crow(track, note)
            self:schedule_note_off(
                track,
                note,
                tc.ch,
                result.note_len_ticks,
                self.midi_out_ports_snapshot
            )
            self.last_notes[track] = { note = note, ch = tc.ch, ports = self.midi_out_ports_snapshot }
        end

        local sp = result.should_play and self.spice[track] and self.spice[track][result.pitch_idx]
        if sp and sp.amount ~= 0 and result.should_play and not tr.muted then
            sp.current = (tonumber(sp.current) or 0) + (tonumber(sp.amount) or 0)
            if sp.current > self.spice_accum_max then
                sp.current = self.spice_accum_min
            elseif sp.current < self.spice_accum_min then
                sp.current = self.spice_accum_max
            end
        end

        M.advance_after_play(self, track, tr, result)
    end
end

return M
