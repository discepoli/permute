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
    function App:rand_prob_from_column(x)
        local col = clamp(tonumber(x) or 1, 1, 16)
        return (col - 1) / 15
    end

    function App:rand_column_from_prob(prob)
        local p = clamp(tonumber(prob) or 0, 0, 1)
        return clamp(math.floor((p * 15) + 1 + 0.5), 1, 16)
    end

    function App:apply_track_evolving_randomization(track)
        local t = clamp(tonumber(track) or 1, 1, cfg.NUM_TRACKS)
        local tr = self:ensure_track_state(t)
        local tc = self.track_cfg[t]
        if not tr or not tc then return end

        local gate_prob = clamp(tonumber(self.track_rand_gate_prob[t]) or 0, 0, 1)
        if gate_prob > 0 then
            for s = 1, cfg.NUM_STEPS do
                if math.random() < gate_prob then
                    tr.gates[s] = not tr.gates[s]
                    if tr.ties then tr.ties[s] = false end
                    if tr.gates[s] and tc.type == "poly" and type(tr.pitches[s]) ~= "table" then
                        tr.pitches[s] = { 1 }
                    end
                end
            end
        end

        local pitch_prob = clamp(tonumber(self.track_rand_pitch_prob[t]) or 0, 0, 1)
        local pitch_span = clamp(tonumber(self.track_rand_pitch_span[t]) or 0, 0, 15)
        if pitch_prob <= 0 or pitch_span <= 0 then
            if gate_prob > 0 then self:invalidate_step_cache(t) end
            return
        end

        for s = 1, cfg.NUM_STEPS do
            if tr.gates[s] and math.random() < pitch_prob then
                local delta = math.random(1, pitch_span)
                if math.random(1, 2) == 1 then delta = -delta end
                if tc.type == "drum" then
                    tr.vels[s] = clamp((tonumber(tr.vels[s]) or self:get_track_default_vel_level(t)) + delta, 1, 15)
                elseif tc.type == "poly" then
                    local pv = tr.pitches[s]
                    if type(pv) ~= "table" then pv = { clamp(tonumber(pv) or 1, 1, 16) } end
                    for i = 1, #pv do
                        pv[i] = clamp((tonumber(pv[i]) or 1) + delta, 1, 16)
                    end
                    tr.pitches[s] = pv
                else
                    tr.pitches[s] = clamp((tonumber(tr.pitches[s]) or 1) + delta, 1, 16)
                end
            end
        end
        self:invalidate_step_cache(t)
    end

    function App:apply_random_notes(track, amount)
        local tr = self.tracks[track]
        local tc = self.track_cfg[track]
        local is_drum = (tc.type == "drum")
        local center_degree = 1
        for s = 1, cfg.NUM_STEPS do
            if tr.gates[s] then
                local shift = math.random(0, amount)
                if math.random(1, 2) == 1 then shift = -shift end
                if is_drum then
                    tr.vels[s] = clamp(self:get_track_default_vel_level(track) + shift, 1, 15)
                elseif tc.type == "poly" then
                    for i, _ in ipairs(tr.pitches[s]) do
                        local p_shift = math.random(0, amount)
                        if math.random(1, 2) == 1 then p_shift = -p_shift end
                        tr.pitches[s][i] = clamp(center_degree + p_shift, 1, 16)
                    end
                else
                    tr.pitches[s] = clamp(center_degree + shift, 1, 16)
                end
            end
        end
        self:invalidate_step_cache(track)
    end

    function App:apply_random_steps(track, density)
        local tr = self:ensure_track_state(track)
        local lo = math.min(tr.start_step, tr.end_step)
        local hi = math.max(tr.start_step, tr.end_step)
        local len = hi - lo + 1
        local fill_count = math.floor(len * density / 16)
        for s = lo, hi do tr.gates[s] = false end
        for _ = 1, fill_count do
            local s = math.random(lo, hi)
            tr.gates[s] = true
            tr.vels[s] = self:get_track_default_vel_level(track)
            if self.track_cfg[track].type == "poly" then
                if type(tr.pitches[s]) ~= "table" or #tr.pitches[s] == 0 then tr.pitches[s] = { 1 } end
            elseif tr.pitches[s] == 0 then
                tr.pitches[s] = 1
            end
        end
        self:invalidate_step_cache(track)
    end

end

return M
