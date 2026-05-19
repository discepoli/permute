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
    function App:get_transpose_seq_degree_for_row(layout_top, layout_bottom, y)
        local row = clamp(tonumber(y) or layout_bottom, layout_top, layout_bottom)
        return clamp((layout_bottom - row) + 1, 1, math.max(1, layout_bottom - layout_top + 1))
    end

    function App:get_transpose_seq_row_for_degree(layout_top, layout_bottom, degree)
        local d = clamp(tonumber(degree) or 1, 1, math.max(1, layout_bottom - layout_top + 1))
        return layout_bottom - d + 1
    end

    function App:get_scale_degree_index()
        if self.scale_type == "chromatic" then return 1 end
        local map = SCALE_DEGREE_INDICES[self.scale_type]
        if not map or #map == 0 then return 1 end
        local sel = clamp(tonumber(self.scale_degree) or 1, 1, #map)
        return map[sel]
    end

    function App:get_mode_scale_and_root()
        local scale = cfg.SCALES[self.scale_type] or cfg.SCALES.chromatic
        if self.scale_type == "chromatic" then return scale, 0 end
        local degree_idx = clamp(self:get_scale_degree_index(), 1, #scale)
        local root = scale[degree_idx]
        local mode = {}
        for i = 0, #scale - 1 do
            local idx = ((degree_idx + i - 1) % #scale) + 1
            local v = scale[idx] - root
            if v < 0 then v = v + 12 end
            mode[#mode + 1] = v
        end
        return mode, root
    end

    function App:get_scale_degree_span()
        local scale = cfg.SCALES[self.scale_type] or cfg.SCALES.chromatic
        return math.max(1, #scale)
    end

    function App:get_track_edit_octave_page(track)
        local t = clamp(tonumber(track) or tonumber(self.sel_track) or 1, 1, cfg.NUM_TRACKS)
        return clamp(tonumber((self.track_edit_octave_page or {})[t]) or 0, -7, 8)
    end

    function App:get_track_edit_degree_offset(track)
        return self:get_track_edit_octave_page(track) * self:get_scale_degree_span()
    end

    function App:get_track_visible_degree(track, local_degree)
        local d = clamp(tonumber(local_degree) or 1, 1, cfg.AUX_GRID_ROWS)
        return clamp(d + self:get_track_edit_degree_offset(track), cfg.MIN_SCALE_DEGREE, cfg.MAX_SCALE_DEGREE)
    end

    function App:main_takeover_row_to_degree(y, track)
        local rows = self:get_main_takeover_note_rows()
        local local_degree = clamp(rows - y + 1, 1, rows)
        local absolute_degree = local_degree + self:get_track_edit_degree_offset(track)
        return clamp(absolute_degree, cfg.MIN_SCALE_DEGREE, cfg.MAX_SCALE_DEGREE)
    end

    function App:aux_row_to_degree(y, track)
        local local_degree = clamp(cfg.AUX_GRID_ROWS - y + 1, 1, cfg.AUX_GRID_ROWS)
        local absolute_degree = local_degree + self:get_track_edit_degree_offset(track)
        return clamp(absolute_degree, cfg.MIN_SCALE_DEGREE, cfg.MAX_SCALE_DEGREE)
    end

    function App:degree_to_aux_row(degree)
        local d = clamp(tonumber(degree) or 1, 1, cfg.AUX_GRID_ROWS)
        return cfg.AUX_GRID_ROWS - d + 1
    end

    function App:get_visible_degree_window(track, surface)
        local t = clamp(tonumber(track) or tonumber(self.sel_track) or 1, 1, cfg.NUM_TRACKS)
        local min_degree
        local max_degree
        if surface == "takeover" then
            local rows = self:get_main_takeover_note_rows()
            min_degree = self:main_takeover_row_to_degree(rows, t)
            max_degree = self:main_takeover_row_to_degree(1, t)
        else
            min_degree = self:get_track_visible_degree(t, 1)
            max_degree = self:get_track_visible_degree(t, cfg.AUX_GRID_ROWS)
        end
        if min_degree > max_degree then
            min_degree, max_degree = max_degree, min_degree
        end
        return min_degree, max_degree
    end

    function App:get_active_scale_context(track, ctx)
        local scale = ctx and ctx.scale
        local mode_root = ctx and ctx.mode_root
        if not scale or mode_root == nil then
            scale, mode_root = self:get_mode_scale_and_root()
        end
        local t = tonumber(track)
        if t ~= nil then
            t = clamp(t, 1, cfg.NUM_TRACKS)
        end

        local base = ctx and ctx.base_note
        local degree_transpose = ctx and ctx.degree_transpose
        local track_octave = ctx and ctx.track_octave
        local transpose_mode = (ctx and ctx.transpose_mode) or self.transpose_mode

        if base == nil then
            base = cfg.DEFAULT_MELODIC_BASE_NOTE
            base = base + clamp(tonumber(self.key_root) or 0, 0, 11) + mode_root
        end
        if degree_transpose == nil then
            degree_transpose = 0
        end
        if track_octave == nil then
            local tr = (t and self.tracks) and self.tracks[t] or nil
            track_octave = tonumber(tr and tr.octave) or 0
        end

        if t ~= nil then
            local track_transpose = clamp(tonumber(self.track_transpose[t]) or 0, -7, 8)
            if transpose_mode == "scale degree" then
                degree_transpose = degree_transpose + track_transpose
            else
                base = base + track_transpose
            end

            if self:is_transpose_seq_active_for_track(t) then
                local seq_degree = (ctx and ctx.transpose_seq_degree)
                if seq_degree == nil then
                    seq_degree = self:get_transpose_seq_current_degree()
                end
                degree_transpose = degree_transpose + seq_degree
            end
        end

        return {
            scale = scale,
            mode_root = mode_root,
            base_note = base,
            degree_transpose = degree_transpose,
            track_octave = track_octave,
            transpose_mode = transpose_mode,
        }
    end

    function App:degree_to_note(track, degree, extra_degrees, ctx)
        local pitch_ctx = self:get_active_scale_context(track, ctx)
        local scale = pitch_ctx.scale
        local total_degree = (tonumber(degree) or 1) + (tonumber(extra_degrees) or 0) + pitch_ctx.degree_transpose

        local oct = math.floor((total_degree - 1) / #scale)
        local idx = ((total_degree - 1) % #scale) + 1
        if idx < 1 then
            idx = idx + #scale
            oct = oct - 1
        end

        local note = pitch_ctx.base_note + scale[idx] + (oct * 12) + (pitch_ctx.track_octave * 12)
        return clamp(note, 0, 127)
    end

    function App:get_pitch(track, degree, extra_degrees, ctx)
        return self:degree_to_note(track, degree, extra_degrees, ctx)
    end

    function App:note_to_nearest_degree(track, midi_note, ctx, degree_min, degree_max)
        local pitch_ctx = self:get_active_scale_context(track, ctx)
        local target_note = clamp(tonumber(midi_note) or 0, 0, 127)
        local lo = clamp(tonumber(degree_min) or cfg.MIN_SCALE_DEGREE, cfg.MIN_SCALE_DEGREE, cfg.MAX_SCALE_DEGREE)
        local hi = clamp(tonumber(degree_max) or cfg.MAX_SCALE_DEGREE, cfg.MIN_SCALE_DEGREE, cfg.MAX_SCALE_DEGREE)
        if lo > hi then lo, hi = hi, lo end

        local best_degree = lo
        local best_distance = 128
        for degree = lo, hi do
            local candidate = self:degree_to_note(track, degree, 0, pitch_ctx)
            local distance = math.abs(candidate - target_note)
            if distance < best_distance then
                best_distance = distance
                best_degree = degree
            end
        end
        return best_degree
    end

    function App:note_label(note)
        if musicutil and musicutil.note_num_to_name then
            return musicutil.note_num_to_name(clamp(note, 0, 127), true)
        end
        return tostring(note)
    end

end

return M
