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
    function App:is_track_melodic(track)
        local tc = self.track_cfg[track]
        return tc and tc.type ~= "drum"
    end

    function App:set_track_counter_to_step(track, step)
        local tr = self:ensure_track_state(track)
        local lo, hi, reverse = self:get_track_bounds(tr)
        local target = clamp(tonumber(step) or lo, lo, hi)
        local len = hi - lo + 1
        local pos = reverse and (hi - target) or (target - lo)
        local current = tonumber(self.track_steps[track]) or 1
        local base = math.floor((current - 1) / len) * len
        self.track_steps[track] = base + pos + 1
    end

    function App:reset_playheads()
        self.step = 1
        self.master_seq_counter = 0
        self.clock_ticks = 0
        self.transport_clock = 0
        self.active_note_offs = {}
        self.beat_repeat_start = 0
        self.beat_repeat_cycle = 0
        self.beat_repeat_anchor = {}
        self.beat_repeat_select_armed = false
        self.beat_repeat_select_active = false
        self.beat_repeat_select_cycle = 0
        self.transpose_seq_clock_phase = 0
        self.transpose_seq_step = 1
        for t = 1, cfg.NUM_TRACKS do
            self.track_steps[t] = 1
            self.track_clock_phase[t] = 0
            self.track_loop_count[t] = 1
        end
        self:request_redraw()
        self:request_aux_redraw()
    end

    function App:get_track_bounds(tr)
        local reverse = tr.end_step < tr.start_step
        local lo = reverse and tr.end_step or tr.start_step
        local hi = reverse and tr.start_step or tr.end_step
        return lo, hi, reverse
    end

    function App:get_track_step_order(tr)
        local lo, hi, reverse = self:get_track_bounds(tr)
        local steps = {}
        if reverse then
            for s = hi, lo, -1 do
                steps[#steps + 1] = s
            end
        else
            for s = lo, hi do
                steps[#steps + 1] = s
            end
        end
        return steps
    end

    function App:ensure_track_state(t)
        local tr = self.tracks[t]
        local tc = self.track_cfg[t]
        if not tr then return nil end

        tr.start_step = clamp(tonumber(tr.start_step) or 1, 1, cfg.NUM_STEPS)
        tr.end_step = clamp(tonumber(tr.end_step) or cfg.NUM_STEPS, 1, cfg.NUM_STEPS)
        tr.octave = tonumber(tr.octave) or 0
        tr.muted = not not tr.muted
        tr.solo = not not tr.solo

        if not tr.gates then tr.gates = {} end
        if not tr.ties then tr.ties = {} end
        if not tr.vels then tr.vels = {} end
        if not tr.pitches then tr.pitches = {} end
        if type(tr.arc) ~= "table" then tr.arc = {} end
        tr.arc.pulses = clamp(tonumber(tr.arc.pulses) or 0, 0, cfg.NUM_STEPS)
        tr.arc.rotation = math.floor(tonumber(tr.arc.rotation) or 1)
        tr.arc.variance = clamp(tonumber(tr.arc.variance) or 0, 0, 100)
        tr.arc.mode = self:normalize_arc_mode(tr.arc.mode)
        if not self.ratios[t] then self.ratios[t] = {} end
        if not self.spice[t] then self.spice[t] = {} end
        if not self.track_steps[t] then self.track_steps[t] = 1 end
        if not self.track_loop_count[t] then self.track_loop_count[t] = 1 end
        self.track_clock_mult[t] = clamp(tonumber(self.track_clock_mult[t]) or 1, 1, 8)
        self.track_clock_div[t] = clamp(tonumber(self.track_clock_div[t]) or 1, 1, 64)
        if self.track_clock_phase[t] == nil then self.track_clock_phase[t] = 0 end

        for s = 1, cfg.NUM_STEPS do
            if tr.gates[s] == nil then tr.gates[s] = false end
            if tr.ties[s] == nil then tr.ties[s] = false end
            if not tr.gates[s] then tr.ties[s] = false end
            tr.vels[s] = clamp(tonumber(tr.vels[s]) or cfg.DEFAULT_VEL_LEVEL, 1, 15)
            if tc and tc.type == "poly" then
                local pv = tr.pitches[s]
                if type(pv) ~= "table" then
                    pv = { clamp(tonumber(pv) or 1, 1, 16) }
                end
                local clean = {}
                local seen = {}
                for _, d in ipairs(pv) do
                    local di = clamp(tonumber(d) or 1, 1, 16)
                    if not seen[di] then
                        clean[#clean + 1] = di
                        seen[di] = true
                    end
                end
                if #clean == 0 then clean[1] = 1 end
                tr.pitches[s] = clean
            else
                tr.pitches[s] = clamp(tonumber(tr.pitches[s]) or 1, 1, 16)
            end
        end

        return tr
    end

    function App:set_track_type(t, new_type)
        if t == nil then return end
        local track = tonumber(t)
        if not track or track < 1 or track > cfg.NUM_TRACKS then return end
        if new_type ~= "drum" and new_type ~= "mono" and new_type ~= "poly" then return end

        local tc = self.track_cfg[track]
        if not tc or tc.type == new_type then return end

        self:push_undo_state()

        local old_type = tc.type
        local tr = self:ensure_track_state(track)
        if not tr then return end

        self:note_off_last_for_track(track)

        for s = 1, cfg.NUM_STEPS do
            local pv = tr.pitches[s]
            if new_type == "poly" then
                if type(pv) ~= "table" then
                    tr.pitches[s] = { clamp(tonumber(pv) or 1, 1, 16) }
                end
            else
                if type(pv) == "table" then
                    tr.pitches[s] = clamp(tonumber(pv[1]) or 1, 1, 16)
                else
                    tr.pitches[s] = clamp(tonumber(pv) or 1, 1, 16)
                end
            end
        end

        tc.type = new_type

        if old_type ~= "drum" and new_type == "drum" then
            self.track_gate_ticks[track] = clamp(tonumber(self.drum_gate_clocks) or 1, 1, 24)
            self.transpose_seq_assign[track] = false
        elseif old_type == "drum" and new_type ~= "drum" then
            self.track_gate_ticks[track] = clamp(tonumber(self.melody_gate_clocks) or 1, 1, 24)
            if self.transpose_seq_assign[track] == nil then
                self.transpose_seq_assign[track] = true
            end
        end

        self:ensure_track_state(track)
        self:invalidate_step_cache(track)
        self:invalidate_aux_degree_cache(track)
        self:request_redraw()
        self:request_aux_redraw()
    end

    function App:get_track_step(t)
        return self:get_track_step_from_counter(t, self.track_steps[t])
    end

    function App:get_track_step_from_counter(t, counter)
        local tr = self:ensure_track_state(t)
        local lo, hi, reverse = self:get_track_bounds(tr)
        local len = hi - lo + 1
        local ts = tonumber(counter) or 1
        local pos = ((ts - 1) % len)
        if reverse then
            return hi - pos
        end
        return lo + pos
    end

end

return M
