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
    function App:export_undo_state()
        local snapshot = {
            tracks = {},
            fill_patterns = deep_copy_table(self.fill_patterns),
            ratios = deep_copy_table(self.ratios),
            spice = deep_copy_table(self.spice),
            track_cfg = self:export_track_cfg()
        }

        for t = 1, cfg.NUM_TRACKS do
            local tr = self:ensure_track_state(t)
            snapshot.tracks[t] = {
                gates = deep_copy_table(tr.gates or {}),
                ties = deep_copy_table(tr.ties or {}),
                vels = deep_copy_table(tr.vels or {}),
                pitches = deep_copy_table(tr.pitches or {})
            }
        end

        return snapshot
    end

    function App:import_undo_state(state)
        if type(state) ~= "table" then return end
        if type(state.track_cfg) == "table" then
            self:import_track_cfg(state.track_cfg, true)
        end

        if type(state.fill_patterns) == "table" then
            self.fill_patterns = deep_copy_table(state.fill_patterns)
        end
        if type(state.ratios) == "table" then
            self.ratios = deep_copy_table(state.ratios)
        end
        if type(state.spice) == "table" then
            self.spice = deep_copy_table(state.spice)
        end

        if type(state.tracks) == "table" then
            for t = 1, cfg.NUM_TRACKS do
                local tr = self:ensure_track_state(t)
                local src = state.tracks[t] or {}
                tr.gates = deep_copy_table(src.gates or {})
                tr.ties = deep_copy_table(src.ties or {})
                tr.vels = deep_copy_table(src.vels or {})
                tr.pitches = deep_copy_table(src.pitches or {})
                self:ensure_track_state(t)
            end
        end

        self:invalidate_step_cache()
        self:request_arc_redraw()
        self:request_redraw()
        self:request_aux_redraw()
    end

    function App:push_undo_state()
        if self.suspend_history then return end
        self.undo_stack[#self.undo_stack + 1] = self:export_undo_state()
        while #self.undo_stack > self.history_limit do
            table.remove(self.undo_stack, 1)
        end
        self.redo_stack = {}
    end

    function App:undo_last_action()
        if #self.undo_stack == 0 then return false end

        local previous = table.remove(self.undo_stack)
        self.redo_stack[#self.redo_stack + 1] = self:export_undo_state()
        while #self.redo_stack > self.history_limit do
            table.remove(self.redo_stack, 1)
        end

        self.suspend_history = true
        self:stop_all_notes()
        self:import_undo_state(previous)
        self.suspend_history = false
        self:request_redraw()
        self:request_aux_redraw()
        return true
    end

    function App:redo_last_action()
        if #self.redo_stack == 0 then return false end

        local next_state = table.remove(self.redo_stack)
        self.undo_stack[#self.undo_stack + 1] = self:export_undo_state()
        while #self.undo_stack > self.history_limit do
            table.remove(self.undo_stack, 1)
        end

        self.suspend_history = true
        self:stop_all_notes()
        self:import_undo_state(next_state)
        self.suspend_history = false
        self:request_redraw()
        self:request_aux_redraw()
        return true
    end

end

return M
