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
    function App:invalidate_step_cache(track)
        if track then
            self.step_cache[track] = nil
            self.step_cache_meta[track] = nil
            self.step_cache_rev[track] = (self.step_cache_rev[track] or 0) + 1
            return
        end
        for t = 1, cfg.NUM_TRACKS do
            self.step_cache[t] = nil
            self.step_cache_meta[t] = nil
            self.step_cache_rev[t] = (self.step_cache_rev[t] or 0) + 1
        end
    end

    function App:normalize_arc_mode(mode)
        return clamp(tonumber(mode) or 1, 1, #ARC_VARIANCE_MODES)
    end

    function App:get_arc_mode_name(mode)
        return ARC_VARIANCE_MODES[self:normalize_arc_mode(mode)]
    end

    function App:get_arc_state(track)
        local tr = self:ensure_track_state(track)
        if not tr then return nil end
        if type(tr.arc) ~= "table" then tr.arc = {} end
        tr.arc.pulses = clamp(tonumber(tr.arc.pulses) or 0, 0, cfg.NUM_STEPS)
        tr.arc.rotation = math.floor(tonumber(tr.arc.rotation) or 1)
        tr.arc.variance = clamp(tonumber(tr.arc.variance) or 0, 0, 100)
        tr.arc.mode = self:normalize_arc_mode(tr.arc.mode)
        return tr.arc
    end

    function App:wrap_arc_index(v, len)
        if len <= 0 then return 1 end
        local idx = v % len
        if idx < 0 then idx = idx + len end
        return idx + 1
    end

    function App:is_beat_column(step)
        return step == 1 or step == 5 or step == 9 or step == 13
    end

    function App:get_arc_pattern(track)
        local tr = self:ensure_track_state(track)
        local arc_state = self:get_arc_state(track)
        if not tr or not arc_state then return {}, {}, {}, {} end

        local order = self:get_track_step_order(tr)
        local len = #order
        local active = {}
        local positions = {}
        local phase_positions = {}
        if len == 0 then return order, active, positions, phase_positions end

        local pulses = clamp(arc_state.pulses or 0, 0, len)
        if pulses <= 0 then
            for idx, step in ipairs(order) do positions[step] = idx end
            return order, active, positions, phase_positions
        end

        local base = {}
        for idx = 1, len do
            local prev = math.floor((((idx - 1) * pulses) - 1) / len)
            local curr = math.floor(((idx * pulses) - 1) / len)
            base[idx] = (curr > prev)
        end

        local rotation = (arc_state.rotation or 1) - 1
        for idx, step in ipairs(order) do
            local src_idx = self:wrap_arc_index((idx - 1) - rotation, len)
            positions[step] = idx
            phase_positions[step] = src_idx
            if base[src_idx] then active[step] = true end
        end

        return order, active, positions, phase_positions
    end

    function App:get_arc_random_value(track, pos)
        local x = math.sin((track * 131) + (pos * 17.17)) * 43758.5453
        return (x - math.floor(x)) * 2 - 1
    end

    function App:sample_arc_shape(shape, pos, len)
        if type(shape) ~= "table" or #shape == 0 then return 0 end
        if #shape == 1 or len <= 1 then return clamp(tonumber(shape[1]) or 0, -1, 1) end

        local t = (pos - 1) / math.max(1, len - 1)
        local scaled = t * (#shape - 1)
        local idx = math.floor(scaled) + 1
        local frac = scaled - math.floor(scaled)
        local a = clamp(tonumber(shape[idx]) or 0, -1, 1)
        local b = clamp(tonumber(shape[math.min(#shape, idx + 1)]) or a, -1, 1)
        return a + ((b - a) * frac)
    end

    function App:get_arc_wave_value(track, pos, len, mode)
        if len <= 1 then return 0 end

        local name = self:get_arc_mode_name(mode)
        local t = (pos - 1) / math.max(1, len - 1)

        if name == "triangle" then
            return 1 - (math.abs((t * 2) - 1) * 2)
        elseif name == "ramp down" then
            return 1 - (t * 2)
        elseif name == "ramp up" then
            return (t * 2) - 1
        elseif name == "random" then
            return self:get_arc_random_value(track, pos)
        elseif name == "cadence 1" then
            return self:sample_arc_shape(ARC_CADENCE_SHAPES[1], pos, len)
        elseif name == "cadence 2" then
            return self:sample_arc_shape(ARC_CADENCE_SHAPES[2], pos, len)
        elseif name == "cadence 3" then
            return self:sample_arc_shape(ARC_CADENCE_SHAPES[3], pos, len)
        elseif name == "cadence 4" then
            return self:sample_arc_shape(ARC_CADENCE_SHAPES[4], pos, len)
        end

        return 0
    end

    function App:get_arc_reference_step(track, order, step, tr)
        tr = tr or self:ensure_track_state(track)
        if not tr then return nil end

        local index_of = {}
        for idx, ordered_step in ipairs(order) do
            index_of[ordered_step] = idx
        end

        local target_idx = index_of[step] or 1
        local len = #order
        for distance = 0, len - 1 do
            local left = target_idx - distance
            if left >= 1 then
                local candidate = order[left]
                if tr.gates[candidate] then return candidate end
            end

            if distance > 0 then
                local right = target_idx + distance
                if right <= len then
                    local candidate = order[right]
                    if tr.gates[candidate] then return candidate end
                end
            end
        end

        return nil
    end

    function App:build_arc_step_cache(track, tr, tc)
        tr = tr or self:ensure_track_state(track)
        tc = tc or self.track_cfg[track]
        if not tr or not tc then return {} end
        local rev = self.step_cache_rev[track] or 0
        local meta = self.step_cache_meta[track]
        if meta and meta.rev == rev and meta.tc_type == tc.type and meta.start_step == tr.start_step and meta.end_step == tr.end_step then
            return self.step_cache[track] or {}
        end

        local arc_state = self:get_arc_state(track)
        local order, active, positions, phase_positions = self:get_arc_pattern(track)
        local cache = {}

        for s = 1, cfg.NUM_STEPS do
            if tr.gates[s] then
                cache[s] = {
                    source = "manual",
                    tie = tr.ties and tr.ties[s] or false,
                    vel = tr.vels[s],
                    pitch = tr.pitches[s]
                }
            end
        end

        for _, step in ipairs(order) do
            if active[step] and not cache[step] then
                local pos = phase_positions[step] or positions[step] or 1
                local len = #order
                local variance_amount = clamp(tonumber(arc_state.variance) or 0, 0, 100)
                local variance_depth = math.floor((variance_amount / 100) * 7 + 0.5)
                local wave = self:get_arc_wave_value(track, pos, len, arc_state.mode)
                local shift = math.floor((wave * variance_depth) + ((wave >= 0) and 0.5 or -0.5))
                local ref_step = self:get_arc_reference_step(track, order, step, tr)
                local default_vel = self:get_track_default_vel_level(track)

                if tc.type == "drum" then
                    local base_vel = ref_step and tr.vels[ref_step] or default_vel
                    cache[step] = {
                        source = "arc",
                        vel = clamp(base_vel + shift, 1, 15)
                    }
                elseif tc.type == "poly" then
                    local base_pitch = ref_step and tr.pitches[ref_step] or { 1 }
                    local chord = {}
                    if type(base_pitch) == "table" then
                        for i, degree in ipairs(base_pitch) do
                            chord[i] = clamp((tonumber(degree) or 1) + shift, 1, 16)
                        end
                    else
                        chord[1] = clamp((tonumber(base_pitch) or 1) + shift, 1, 16)
                    end
                    if #chord == 0 then chord[1] = 1 end
                    cache[step] = {
                        source = "arc",
                        vel = ref_step and tr.vels[ref_step] or default_vel,
                        pitch = chord
                    }
                else
                    local base_degree = ref_step and tr.pitches[ref_step] or 1
                    cache[step] = {
                        source = "arc",
                        vel = ref_step and tr.vels[ref_step] or default_vel,
                        pitch = clamp((tonumber(base_degree) or 1) + shift, 1, 16)
                    }
                end
            end
        end

        self.step_cache[track] = cache
        self.step_cache_meta[track] = {
            rev = rev,
            tc_type = tc.type,
            start_step = tr.start_step,
            end_step = tr.end_step,
        }
        return cache
    end

    function App:get_arc_step_data(track, step)
        return self:build_arc_step_cache(track)[step]
    end

    function App:step_has_playable_note(track, step)
        return self:get_arc_step_data(track, step) ~= nil
    end

end

return M
