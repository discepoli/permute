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
    function App:aux_row_to_vel_level(y)
        return clamp(17 - (y * 2), 1, 15)
    end

    function App:vel_level_to_aux_row(level)
        local stored = clamp(tonumber(level) or cfg.DEFAULT_VEL_LEVEL, 1, 15)
        return clamp(cfg.AUX_GRID_ROWS - math.floor((stored - 1) / 2), 1, cfg.AUX_GRID_ROWS)
    end

    function App:is_aux_degree_above_visible_octave(track, stored_degree)
        return self:get_pitch(track, clamp(tonumber(stored_degree) or 1, 1, 16), 0)
            > self:get_pitch(track, cfg.AUX_GRID_ROWS, 0)
    end

    function App:get_closest_aux_degree(track, stored_degree)
        local target = self:get_pitch(track, clamp(tonumber(stored_degree) or 1, 1, 16), 0)
        local best_degree = 1
        local best_distance = nil

        for degree = 1, cfg.AUX_GRID_ROWS do
            local distance = math.abs(self:get_pitch(track, degree, 0) - target)
            if best_distance == nil or distance < best_distance then
                best_distance = distance
                best_degree = degree
            end
        end

        return best_degree
    end

    function App:invalidate_aux_degree_cache(track)
        if track ~= nil then
            if self.aux_degree_cache then self.aux_degree_cache[track] = nil end
            return
        end
        self.aux_degree_cache = {}
    end

    function App:get_aux_degree_cache_key(track)
        local tr = self.tracks and self.tracks[track]
        local track_octave = tr and tr.octave or 0
        local track_transpose = (self.track_transpose and self.track_transpose[track]) or 0
        local seq_degree = 0
        if self.is_transpose_seq_active_for_track and self:is_transpose_seq_active_for_track(track) then
            seq_degree = self:get_transpose_seq_current_degree()
        end
        return table.concat({
            tostring(self.scale_type),
            tostring(self.scale_degree),
            tostring(self.key_root),
            tostring(self.transpose_mode),
            tostring(track_transpose),
            tostring(track_octave),
            tostring(seq_degree),
        }, "|")
    end

    function App:get_closest_aux_degree_cached(track, stored_degree)
        local t = clamp(tonumber(track) or 1, 1, cfg.NUM_TRACKS)
        local sd = clamp(tonumber(stored_degree) or 1, 1, 16)
        if type(self.aux_degree_cache) ~= "table" then
            self.aux_degree_cache = {}
        end

        local key = self:get_aux_degree_cache_key(t)
        local entry = self.aux_degree_cache[t]
        if type(entry) ~= "table" or entry.key ~= key then
            entry = { key = key, values = {} }
            self.aux_degree_cache[t] = entry
        end

        local hit = entry.values[sd]
        if hit then return hit end
        local v = self:get_closest_aux_degree(t, sd)
        entry.values[sd] = v
        return v
    end

    function App:new_aux_led_buffer(dev)
        local cols = (dev and dev.cols) or cfg.NUM_STEPS
        local rows = (dev and dev.rows) or cfg.AUX_GRID_ROWS
        local buf = {}
        for x = 1, cols do
            buf[x] = {}
            for y = 1, rows do
                buf[x][y] = 0
            end
        end
        return buf
    end

    function App:aux_buf_led(buf, x, y, level)
        if type(buf) ~= "table" then return end
        local col = buf[x]
        if not col then return end
        if col[y] == nil then return end
        col[y] = clamp(tonumber(level) or 0, 0, 15)
    end

    function App:flush_aux_led_buffer(dev, next_buf)
        if not dev then return end
        local prev = self.aux_led_prev
        local cols = (dev and dev.cols) or cfg.NUM_STEPS
        local rows = (dev and dev.rows) or cfg.AUX_GRID_ROWS

        for x = 1, cols do
            local next_col = next_buf[x] or {}
            local prev_col = prev and prev[x] or nil
            for y = 1, rows do
                local nv = next_col[y] or 0
                local pv = (prev_col and prev_col[y]) or 0
                if nv ~= pv then
                    dev:led(x, y, nv)
                end
            end
        end

        self.aux_led_prev = next_buf
        dev:refresh()
    end

    function App:poly_has_pitch(pv, degree)
        if type(pv) ~= "table" then return false end
        for _, d in ipairs(pv) do
            if d == degree then return true end
        end
        return false
    end

    function App:poly_toggle_pitch(pv, degree)
        local out = {}
        local found = false
        if type(pv) == "table" then
            for _, d in ipairs(pv) do
                if d == degree then
                    found = true
                else
                    out[#out + 1] = d
                end
            end
        end
        if not found then out[#out + 1] = degree end
        return out
    end

    function App:poly_toggle_aux_degree(track, pv, degree)
        local out = {}
        local found = false

        if type(pv) == "table" then
            for _, stored_degree in ipairs(pv) do
                if self:get_closest_aux_degree_cached(track, stored_degree) == degree then
                    found = true
                else
                    out[#out + 1] = stored_degree
                end
            end
        end

        if not found then out[#out + 1] = degree end
        return out
    end

    function App:poly_active_pitches(tr, s)
        if tr.gates[s] and type(tr.pitches[s]) == "table" then return tr.pitches[s] end
        return {}
    end

    function App:redraw_aux_grid()
        local dev = self.aux_grid_dev
        if not dev then
            self.aux_led_prev = nil
            return
        end
        local next_buf = self:new_aux_led_buffer(dev)

        if not self.sel_track then
            self:flush_aux_led_buffer(dev, next_buf)
            return
        end

        local t = clamp(tonumber(self.sel_track) or 1, 1, cfg.NUM_TRACKS)
        local tr = self:ensure_track_state(t)
        local tc = self.track_cfg[t]
        local step_cache = self:build_arc_step_cache(t, tr, tc)
        local fills = self.fill_patterns[t] or {}
        local current_step = self:get_track_step(t)
        local lo, hi = self:get_track_bounds(tr)
        local scale = cfg.SCALES[self.scale_type] or cfg.SCALES.chromatic

        if tc.type == "drum" then
            for s = 1, cfg.NUM_STEPS do
                local in_range = s >= lo and s <= hi
                local is_playhead = (s == current_step and self.playing)
                local fill = fills[s]
                local step_data = step_cache[s]
                local top_row = nil
                local lv = 0

                if in_range and self:is_beat_column(s) then
                    for row = 1, cfg.AUX_GRID_ROWS do
                        self:aux_buf_led(next_buf, s, row, 2)
                    end
                end

                if step_data then
                    top_row = self:vel_level_to_aux_row(step_data.vel)
                    lv = (step_data.source == "manual") and (is_playhead and 15 or 12) or (is_playhead and 10 or 7)
                elseif fill then
                    top_row = self:vel_level_to_aux_row(fill.vel)
                    lv = is_playhead and 10 or 6
                end

                if top_row then
                    if not in_range then lv = math.max(1, math.floor(lv / 2)) end
                    for row = top_row, cfg.AUX_GRID_ROWS do
                        self:aux_buf_led(next_buf, s, row, lv)
                    end
                elseif in_range or is_playhead then
                    self:aux_buf_led(next_buf, s, cfg.AUX_GRID_ROWS, is_playhead and 2 or 1)
                end
            end
        else
            for s = 1, cfg.NUM_STEPS do
                local in_range = s >= lo and s <= hi
                local is_playhead = (s == current_step and self.playing)
                local fill = fills[s]
                local fill_degree = fill and self:get_closest_aux_degree_cached(t, fill.pitch) or nil
                local fill_above = fill and self:is_aux_degree_above_visible_octave(t, fill.pitch) or false
                local step_data = step_cache[s]

                if (not self.realtime_play_mode) and in_range and self:is_beat_column(s) then
                    for row = 1, cfg.AUX_GRID_ROWS do
                        self:aux_buf_led(next_buf, s, row, 2)
                    end
                end

                for degree = 1, cfg.AUX_GRID_ROWS do
                    local row = self:degree_to_aux_row(degree)
                    local is_root = ((degree - 1) % #scale) == 0
                    local is_on = false
                    local is_fill = false
                    local is_above = false

                    if step_data then
                        if tc.type == "poly" then
                            for _, stored_degree in ipairs(step_data.pitch or {}) do
                                if self:get_closest_aux_degree_cached(t, stored_degree) == degree then
                                    is_on = true
                                    is_above = self:is_aux_degree_above_visible_octave(t, stored_degree)
                                    break
                                end
                            end
                        else
                            is_on = self:get_closest_aux_degree_cached(t, step_data.pitch) == degree
                            if is_on then
                                is_above = self:is_aux_degree_above_visible_octave(t, step_data.pitch)
                            end
                        end
                    elseif fill_degree then
                        is_fill = degree == fill_degree
                        is_above = fill_above
                    end

                    if is_on then
                        local manual = step_data.source == "manual"
                        local lv = is_above
                            and (manual and ((is_playhead and 7) or 5) or ((is_playhead and 5) or 4))
                            or (manual and ((is_playhead and 15) or 12) or ((is_playhead and 10) or 7))
                        if not in_range then lv = math.max(1, math.floor(lv / 2)) end
                        self:aux_buf_led(next_buf, s, row, lv)
                    elseif is_fill then
                        local lv = is_above and ((is_playhead and 6) or 4) or ((is_playhead and 10) or 6)
                        if not in_range then lv = math.max(1, math.floor(lv / 2)) end
                        self:aux_buf_led(next_buf, s, row, lv)
                    elseif is_root and in_range then
                        self:aux_buf_led(next_buf, s, row, 2)
                    elseif is_playhead and in_range then
                        self:aux_buf_led(next_buf, s, row, 1)
                    end
                end
            end
        end

        self:flush_aux_led_buffer(dev, next_buf)
    end

end

return M
