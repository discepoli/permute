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

    function App:main_takeover_row_to_degree(y)
        local rows = self:get_main_takeover_note_rows()
        return clamp(rows - y + 1, 1, rows)
    end

    function App:aux_row_to_degree(y)
        return clamp(cfg.AUX_GRID_ROWS - y + 1, 1, cfg.AUX_GRID_ROWS)
    end

    function App:degree_to_aux_row(degree)
        local d = clamp(tonumber(degree) or 1, 1, cfg.AUX_GRID_ROWS)
        return cfg.AUX_GRID_ROWS - d + 1
    end

    function App:get_pitch(track, degree, extra_degrees, ctx)
        local scale = ctx and ctx.scale
        local mode_root = ctx and ctx.mode_root
        if not scale or mode_root == nil then
            scale, mode_root = self:get_mode_scale_and_root()
        end
        local base = cfg.DEFAULT_MELODIC_BASE_NOTE
        base = base + clamp(tonumber(self.key_root) or 0, 0, 11) + mode_root

        local track_transpose = clamp(tonumber(self.track_transpose[track]) or 0, -7, 8)
        local degree_transpose = 0
        local transpose_mode = (ctx and ctx.transpose_mode) or self.transpose_mode
        if transpose_mode == "scale degree" then
            degree_transpose = track_transpose
        else
            base = base + track_transpose
        end
        if self:is_transpose_seq_active_for_track(track) then
            degree_transpose = degree_transpose + ((ctx and ctx.transpose_seq_degree) or self:get_transpose_seq_current_degree())
        end

        local total_degree = degree + (extra_degrees or 0) + degree_transpose

        local oct = math.floor((total_degree - 1) / #scale)
        local idx = ((total_degree - 1) % #scale) + 1
        if idx < 1 then
            idx = idx + #scale
            oct = oct - 1
        end

        local note = base + scale[idx] + (oct * 12) + (self.tracks[track].octave * 12)
        return clamp(note, 0, 127)
    end

    function App:note_label(note)
        if musicutil and musicutil.note_num_to_name then
            return musicutil.note_num_to_name(clamp(note, 0, 127), true)
        end
        return tostring(note)
    end

end

return M
