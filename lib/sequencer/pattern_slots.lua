local H = include("lib/core/util")
local cfg = H.cfg
local clamp = H.clamp
local deep_copy_table = H.deep_copy_table

local NUM_SLOTS = cfg.NUM_STEPS

local M = {}

local function slot_in_range(slot)
    return clamp(tonumber(slot) or 1, 1, NUM_SLOTS)
end

function M.install(App)
    function App:init_track_pattern_slots(t)
        t = clamp(tonumber(t) or 1, 1, cfg.NUM_TRACKS)
        if type(self.track_pattern_slots) ~= "table" then self.track_pattern_slots = {} end
        if type(self.track_pattern_slot_active) ~= "table" then self.track_pattern_slot_active = {} end
        if type(self.track_pattern_slot_dirty) ~= "table" then self.track_pattern_slot_dirty = {} end
        if type(self.track_pattern_slot_highest) ~= "table" then self.track_pattern_slot_highest = {} end
        if type(self.pending_pattern_switches) ~= "table" then self.pending_pattern_switches = {} end
        if type(self.track_pattern_slots[t]) ~= "table" then self.track_pattern_slots[t] = {} end
        self.track_pattern_slot_active[t] = clamp(tonumber(self.track_pattern_slot_active[t]) or 1, 1, NUM_SLOTS)
        self.track_pattern_slot_dirty[t] = not not self.track_pattern_slot_dirty[t]
        self.track_pattern_slot_highest[t] = clamp(tonumber(self.track_pattern_slot_highest[t]) or 0, 0, NUM_SLOTS)
    end

    function App:init_all_track_pattern_slots()
        for t = 1, cfg.NUM_TRACKS do
            self:init_track_pattern_slots(t)
        end
    end

    function App:is_pattern_slot_mode()
        return not not (self.mod_held and self.mod_held[cfg.MOD.TEMP] and not self.mod_held[cfg.MOD.SHIFT])
    end

    function App:is_shift_temp_mode()
        if self.mod_held and self.mod_held[cfg.MOD.TEMP] and self.mod_held[cfg.MOD.SHIFT] then
            return true
        end
        if self:is_temp_button_fill_mode() then
            return self.fill_latched
        end
        return self.temp_latched
    end

    function App:track_slot_is_filled(t, slot)
        t = clamp(tonumber(t) or 1, 1, cfg.NUM_TRACKS)
        slot = slot_in_range(slot)
        local slots = self.track_pattern_slots and self.track_pattern_slots[t]
        return type(slots) == "table" and type(slots[slot]) == "table"
    end

    function App:track_slot_highest_filled(t)
        t = clamp(tonumber(t) or 1, 1, cfg.NUM_TRACKS)
        self:init_track_pattern_slots(t)
        return clamp(tonumber(self.track_pattern_slot_highest[t]) or 0, 0, NUM_SLOTS)
    end

    function App:mark_track_pattern_dirty(t)
        t = clamp(tonumber(t) or 1, 1, cfg.NUM_TRACKS)
        self:init_track_pattern_slots(t)
        self.track_pattern_slot_dirty[t] = true
    end

    function App:export_track_snapshot(t)
        t = clamp(tonumber(t) or 1, 1, cfg.NUM_TRACKS)
        local tr = self:ensure_track_state(t)
        local tc = self.track_cfg[t]
        local track_step_limit = self:get_track_step_limit()
        local snap = {
            g = {},
            p = {},
            v = {},
            ti = {},
            r = {},
            sp = {},
            m = {
                start_step = self:clamp_track_step(tr.start_step, 1),
                end_step = self:clamp_track_step(tr.end_step, math.min(cfg.NUM_STEPS, track_step_limit)),
                octave = clamp(tonumber(tr.octave) or 0, -7, 8),
                clock_mult = clamp(tonumber(self.track_clock_mult[t]) or 1, 1, 8),
                clock_div = clamp(tonumber(self.track_clock_div[t]) or 1, 1, 64),
                arc = deep_copy_table(tr.arc or { pulses = 0, rotation = 1, variance = 0, mode = 1 }),
            },
            tt = clamp(tonumber(self.track_transpose[t]) or 0, -96, 96),
        }

        if tc and tc.type == "split" and type(tr.split) == "table" then
            snap.split = deep_copy_table(tr.split)
        end

        for s = 1, track_step_limit do
            if tr.gates[s] then
                snap.g[s] = 1
                snap.v[s] = clamp(tonumber(tr.vels[s]) or cfg.DEFAULT_VEL_LEVEL, 1, 15)
                if tr.ties and tr.ties[s] then snap.ti[s] = 1 end
                if tc.type == "poly" then
                    local pv = {}
                    for i, d in ipairs(tr.pitches[s] or {}) do pv[i] = d end
                    snap.p[s] = pv
                else
                    snap.p[s] = tr.pitches[s]
                end
            end
            if self.ratios[t] and self.ratios[t][s] then
                snap.r[s] = deep_copy_table(self.ratios[t][s])
            end
            if self.spice[t] and self.spice[t][s] then
                snap.sp[s] = deep_copy_table(self.spice[t][s])
            end
        end

        return snap
    end

    function App:blank_track_pattern_state(t)
        t = clamp(tonumber(t) or 1, 1, cfg.NUM_TRACKS)
        local tr = self:ensure_track_state(t)
        local tc = self.track_cfg[t]
        local track_step_limit = self:get_track_step_limit()

        self:note_off_last_for_track(t)
        for s = 1, track_step_limit do
            tr.gates[s] = false
            tr.ties[s] = false
            tr.vels[s] = self:get_track_default_vel_level(t)
            if tc.type == "poly" then
                tr.pitches[s] = { 1 }
            else
                tr.pitches[s] = 1
            end
        end

        tr.start_step = 1
        tr.end_step = cfg.NUM_STEPS
        tr.octave = 0
        tr.arc = { pulses = 0, rotation = 1, variance = 0, mode = 1 }
        self.track_clock_mult[t] = 1
        self.track_clock_div[t] = 1
        self.track_transpose[t] = 0
        self.ratios[t] = {}
        self.spice[t] = {}
        self.track_rand_gate_prob[t] = 0
        self.track_rand_pitch_prob[t] = 0
        self.track_rand_pitch_span[t] = 0

        if self:is_track_split(t) then
            tr.split = include("lib/sequencer/split").default_split_state()
            self:reset_split_cursors(t)
            self:clear_split_edit(t)
        end
    end

    function App:import_track_snapshot(t, snap)
        t = clamp(tonumber(t) or 1, 1, cfg.NUM_TRACKS)
        if type(snap) ~= "table" then
            self:blank_track_pattern_state(t)
            return
        end

        local tr = self:ensure_track_state(t)
        local tc = self.track_cfg[t]
        local track_step_limit = self:get_track_step_limit()

        self:note_off_last_for_track(t)
        self.ratios[t] = {}
        self.spice[t] = {}

        for s = 1, track_step_limit do
            tr.gates[s] = false
            tr.ties[s] = false
            tr.vels[s] = self:get_track_default_vel_level(t)
            if tc.type == "poly" then
                tr.pitches[s] = { 1 }
            else
                tr.pitches[s] = 1
            end
        end

        local sm = snap.m or {}
        tr.start_step = self:clamp_track_step(sm.start_step, 1)
        tr.end_step = self:clamp_track_step(sm.end_step, math.min(cfg.NUM_STEPS, track_step_limit))
        tr.octave = clamp(tonumber(sm.octave) or 0, -7, 8)
        tr.arc = deep_copy_table(sm.arc or { pulses = 0, rotation = 1, variance = 0, mode = 1 })
        self.track_clock_mult[t] = clamp(tonumber(sm.clock_mult) or 1, 1, 8)
        self.track_clock_div[t] = clamp(tonumber(sm.clock_div) or 1, 1, 64)
        self.track_transpose[t] = clamp(tonumber(snap.tt) or 0, -96, 96)

        if type(snap.split) == "table" and self:is_track_split(t) then
            tr.split = deep_copy_table(snap.split)
            self:ensure_split_track_state(t)
            self:reset_split_cursors(t)
        end

        local sg = snap.g or {}
        local sp = snap.p or {}
        local sv = snap.v or {}
        local sti = snap.ti or {}
        local sr = snap.r or {}
        local ssp = snap.sp or {}

        for step_key, _ in pairs(sg) do
            local s = tonumber(step_key)
            if s and s >= 1 and s <= track_step_limit then
                tr.gates[s] = true
                tr.vels[s] = clamp(tonumber(sv[s]) or cfg.DEFAULT_VEL_LEVEL, 1, 15)
                tr.ties[s] = not not sti[s]
                if tc.type == "poly" then
                    local pv = sp[s]
                    if type(pv) == "table" and #pv > 0 then
                        local cp = {}
                        for i, d in ipairs(pv) do
                            cp[i] = clamp(tonumber(d) or 1, cfg.MIN_SCALE_DEGREE, cfg.MAX_SCALE_DEGREE)
                        end
                        tr.pitches[s] = cp
                    end
                else
                    tr.pitches[s] = clamp(tonumber(sp[s]) or 1, cfg.MIN_SCALE_DEGREE, cfg.MAX_SCALE_DEGREE)
                end
            end
        end

        for step_key, val in pairs(sr) do
            local s = tonumber(step_key)
            if s and val then self.ratios[t][s] = deep_copy_table(val) end
        end
        for step_key, val in pairs(ssp) do
            local s = tonumber(step_key)
            if s and val then self.spice[t][s] = deep_copy_table(val) end
        end

        self:invalidate_step_cache(t)
    end

    function App:save_track_to_active_slot(t)
        t = clamp(tonumber(t) or 1, 1, cfg.NUM_TRACKS)
        self:init_track_pattern_slots(t)
        if not self.track_pattern_slot_dirty[t] then return end

        local slot = slot_in_range(self.track_pattern_slot_active[t])
        self.track_pattern_slots[t][slot] = self:export_track_snapshot(t)
        self.track_pattern_slot_dirty[t] = false
        if slot > (self.track_pattern_slot_highest[t] or 0) then
            self.track_pattern_slot_highest[t] = slot
        end
    end

    function App:clamp_track_playhead_to_bounds(t)
        t = clamp(tonumber(t) or 1, 1, cfg.NUM_TRACKS)
        local tr = self:ensure_track_state(t)
        local lo, hi = self:get_track_bounds(tr)
        local current = self:get_track_step(t)
        if current < lo then
            self.track_steps[t] = lo
        elseif current > hi then
            self.track_steps[t] = hi
        end
        if self:is_track_split(t) then
            local sp = self:ensure_split_track_state(t)
            local gate_lo, gate_hi = self:get_split_gate_bounds(tr)
            local pitch_lo, pitch_hi = self:get_split_pitch_bounds(tr)
            local gate_pos = clamp(tonumber(self.split_gate_pos[t]) or gate_lo, gate_lo, gate_hi)
            local pitch_pos = clamp(tonumber(self.split_pitch_pos[t]) or pitch_lo, pitch_lo, pitch_hi)
            self.split_gate_pos[t] = gate_pos
            self.split_pitch_pos[t] = pitch_pos
            self.split_gate_substep[t] = 0
            self.split_gate_hold_active[t] = false
        end
    end

    function App:reset_track_playhead_to_start(t)
        t = clamp(tonumber(t) or 1, 1, cfg.NUM_TRACKS)
        self.track_steps[t] = 1
        self.track_loop_count[t] = 1
        if self:is_track_split(t) then
            self:reset_split_cursors(t)
        end
    end

    function App:get_pattern_slot_switch_timing()
        local mode = self.pattern_slot_switch_timing or "immediate"
        if mode == "bar-end" or mode == "master-end" then return mode end
        return "immediate"
    end

    function App:get_pattern_slot_dynamic_mode()
        local mode = self.pattern_slot_dynamic_mode or "last"
        if mode == "all" or mode == "only" then return mode end
        return "last"
    end

    function App:resolve_dynamic_slot_for_track(t, col)
        t = clamp(tonumber(t) or 1, 1, cfg.NUM_TRACKS)
        col = slot_in_range(col)
        local dyn_mode = self:get_pattern_slot_dynamic_mode()
        if dyn_mode == "all" then
            return col
        elseif dyn_mode == "only" then
            if self:track_slot_is_filled(t, col) then return col end
            return nil
        end
        local highest = self:track_slot_highest_filled(t)
        if highest <= 0 then return col end
        return math.min(col, highest)
    end

    function App:apply_track_slot_switch(t, slot, reset_playhead)
        t = clamp(tonumber(t) or 1, 1, cfg.NUM_TRACKS)
        slot = slot_in_range(slot)
        local active = slot_in_range(self.track_pattern_slot_active[t])

        if slot == active then return end

        self:save_track_to_active_slot(t)
        self.track_pattern_slot_active[t] = slot

        local snap = self.track_pattern_slots[t] and self.track_pattern_slots[t][slot]
        self:import_track_snapshot(t, snap)
        self.track_pattern_slot_dirty[t] = false

        if reset_playhead then
            self:reset_track_playhead_to_start(t)
        else
            self:clamp_track_playhead_to_bounds(t)
        end

        self:request_redraw()
        self:request_aux_redraw()
        self:request_arc_redraw()
    end

    function App:request_track_slot_switch(t, slot)
        t = clamp(tonumber(t) or 1, 1, cfg.NUM_TRACKS)
        slot = slot_in_range(slot)
        self:init_track_pattern_slots(t)

        local active = slot_in_range(self.track_pattern_slot_active[t])
        if slot == active then return end

        local timing = self:get_pattern_slot_switch_timing()
        if timing == "master-end" and not self.master_seq_len_enabled then
            timing = "bar-end"
        end
        if timing == "immediate" then
            self:apply_track_slot_switch(t, slot, false)
            return
        end

        self:save_track_to_active_slot(t)
        self.pending_pattern_switches[t] = { slot = slot, timing = timing }
    end

    function App:request_dynamic_slot_switch(col)
        col = slot_in_range(col)
        for t = 1, cfg.NUM_TRACKS do
            local target = self:resolve_dynamic_slot_for_track(t, col)
            if target then
                self:request_track_slot_switch(t, target)
            end
        end
    end

    function App:on_track_pattern_loop_wrap(t)
        t = clamp(tonumber(t) or 1, 1, cfg.NUM_TRACKS)
        local pending = self.pending_pattern_switches and self.pending_pattern_switches[t]
        if type(pending) ~= "table" then return end
        if pending.timing ~= "bar-end" then return end

        self.pending_pattern_switches[t] = nil
        self:apply_track_slot_switch(t, pending.slot, true)
    end

    function App:apply_pending_master_pattern_switches()
        if type(self.pending_pattern_switches) ~= "table" then return end

        local any = false
        for t = 1, cfg.NUM_TRACKS do
            local pending = self.pending_pattern_switches[t]
            if type(pending) == "table" and pending.timing == "master-end" then
                any = true
                break
            end
        end
        if not any then return end

        for t = 1, cfg.NUM_TRACKS do
            local pending = self.pending_pattern_switches[t]
            if type(pending) == "table" and pending.timing == "master-end" then
                self.pending_pattern_switches[t] = nil
                self:apply_track_slot_switch(t, pending.slot, true)
            end
        end
    end
end

return M
