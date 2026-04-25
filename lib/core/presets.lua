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
    function App:is_menu_active()
        return (_menu and _menu.mode) and true or false
    end

    function App:preset_dir()
        return (_path.data or "/tmp/") .. "permute/"
    end

    function App:preset_path(number)
        return self:preset_dir() .. "pset-" .. tostring(number or 0) .. ".data"
    end

    function App:default_setup_path()
        return self:preset_dir() .. "default-setup.data"
    end

    function App:default_setup_param_ids()
        if param_setup and param_setup.default_setup_param_ids then
            return param_setup.default_setup_param_ids(cfg.NUM_TRACKS)
        end
        return {}
    end

    function App:export_track_cfg()
        return deep_copy_table(self.track_cfg)
    end

    function App:import_track_cfg(track_cfg, sync_params)
        if type(track_cfg) ~= "table" then return end

        for t = 1, cfg.NUM_TRACKS do
            local src = track_cfg[t]
            if src then
                if type(self.track_cfg[t]) ~= "table" then self.track_cfg[t] = {} end
                self.track_cfg[t].type = src.type or self.track_cfg[t].type
                self.track_cfg[t].ch = clamp(tonumber(src.ch) or self.track_cfg[t].ch or 1, 1, 16)
                self.track_cfg[t].note = clamp(tonumber(src.note) or self.track_cfg[t].note or 60, 0, 127)
            end
        end
        self:invalidate_aux_degree_cache()

        if sync_params and params and params.set then
            local was_suspended = self.suspend_history
            self.suspend_history = true
            for t = 1, cfg.NUM_TRACKS do
                local tc = self.track_cfg[t]
                if tc then
                    local gid = "permute_track_" .. t
                    local type_idx = (tc.type == "drum") and 1 or ((tc.type == "mono") and 2 or 3)
                    pcall(function() params:set(gid .. "_type", type_idx) end)
                    pcall(function() params:set(gid .. "_ch", clamp(tonumber(tc.ch) or 1, 1, 16)) end)
                    pcall(function() params:set(gid .. "_note", clamp(tonumber(tc.note) or 60, 0, 127)) end)
                    pcall(function() params:set(gid .. "_vel", self:get_track_default_midi_velocity(t)) end)
                end
            end
            self.suspend_history = was_suspended
        end
    end

    function App:sync_track_cfg_from_params()
        if not params or not params.get then return end

        local track_cfg = {}
        for t = 1, cfg.NUM_TRACKS do
            local gid = "permute_track_" .. t
            local type_idx = 1
            local ok_type, loaded_type = pcall(function() return params:get(gid .. "_type") end)
            if ok_type and loaded_type ~= nil then type_idx = tonumber(loaded_type) or 1 end
            track_cfg[t] = {
                type = (type_idx == 3 and "poly") or (type_idx == 2 and "mono") or "drum",
                ch = clamp(tonumber(params:get(gid .. "_ch")) or 1, 1, 16),
                note = clamp(tonumber(params:get(gid .. "_note")) or 60, 0, 127)
            }
            local ok_vel, loaded_vel = pcall(function() return params:get(gid .. "_vel") end)
            if ok_vel and loaded_vel ~= nil then
                self.track_default_vel[t] = clamp(tonumber(loaded_vel) or self:get_track_default_midi_velocity(t), 0, 127)
            end
        end

        self:import_track_cfg(track_cfg, false)
    end

    function App:capture_default_setup_values()
        local values = {}
        for _, id in ipairs(self:default_setup_param_ids()) do
            local ok, val = pcall(function() return params:get(id) end)
            if ok and val ~= nil then values[id] = val end
        end
        return values
    end

    function App:save_default_setup(show_feedback)
        if not tab or not tab.save then return false end
        ensure_dir(self:preset_dir())

        local values = self:capture_default_setup_values()

        tab.save({
            params = values,
            track_cfg = self:export_track_cfg()
        }, self:default_setup_path())
        if show_feedback then self:flash_status("default", "saved") end
        return true
    end

    function App:load_default_setup(show_feedback)
        if not tab or not tab.load then return false end
        local loaded = tab.load(self:default_setup_path())
        if type(loaded) ~= "table" then
            if show_feedback then self:flash_status("default", "missing") end
            return false
        end

        local values = loaded.params or loaded
        if type(values) ~= "table" then
            if show_feedback then self:flash_status("default", "invalid") end
            return false
        end

        self:stop_all_notes()
        local was_suspended = self.suspend_history
        self.suspend_history = true
        for _, id in ipairs(self:default_setup_param_ids()) do
            local val = values[id]
            if val ~= nil then
                pcall(function() params:set(id, val) end)
            end
        end
        if type(loaded.track_cfg) == "table" then
            self:import_track_cfg(loaded.track_cfg, true)
        else
            self:sync_track_cfg_from_params()
        end
        self.suspend_history = was_suspended
        self:invalidate_step_cache()
        self:invalidate_step_cache()
        self:request_redraw()
        self:request_aux_redraw()

        if show_feedback then self:flash_status("default", "loaded") end
        return true
    end

    function App:load_factory_default_setup(show_feedback)
        if type(self.factory_default_setup_values) ~= "table" then
            if show_feedback then self:flash_status("default", "missing") end
            return false
        end

        self:stop_all_notes()
        local was_suspended = self.suspend_history
        self.suspend_history = true
        for _, id in ipairs(self:default_setup_param_ids()) do
            local val = self.factory_default_setup_values[id]
            if val ~= nil then
                pcall(function() params:set(id, val) end)
            end
        end
        if type(self.factory_default_track_cfg) == "table" then
            self:import_track_cfg(self.factory_default_track_cfg, true)
        else
            self:sync_track_cfg_from_params()
        end
        self.suspend_history = was_suspended
        self:invalidate_step_cache()
        self:request_redraw()
        self:request_aux_redraw()

        if show_feedback then self:flash_status("default", "factory") end
        return true
    end

    function App:clear_default_setup(show_feedback)
        local removed = (os.remove(self:default_setup_path()) ~= nil)
        self:load_factory_default_setup(false)
        if show_feedback then self:flash_status("default", removed and "cleared" or "factory") end
        return true
    end

    function App:export_state()
        return {
            tracks = deep_copy_table(self.tracks),
            track_steps = deep_copy_table(self.track_steps),
            track_clock_div = deep_copy_table(self.track_clock_div),
            track_clock_mult = deep_copy_table(self.track_clock_mult),
            track_transpose = deep_copy_table(self.track_transpose),
            track_rand_gate_prob = deep_copy_table(self.track_rand_gate_prob),
            track_rand_pitch_prob = deep_copy_table(self.track_rand_pitch_prob),
            track_rand_pitch_span = deep_copy_table(self.track_rand_pitch_span),
            transpose_mode = self.transpose_mode,
            transpose_takeover_mode = self.transpose_takeover_mode,
            transpose_seq_enabled = self.transpose_seq_enabled,
            transpose_seq_steps = deep_copy_table(self.transpose_seq_steps),
            transpose_seq_selected_step = self.transpose_seq_selected_step,
            transpose_seq_assign = deep_copy_table(self.transpose_seq_assign),
            transpose_seq_clock_mult = self.transpose_seq_clock_mult,
            transpose_seq_clock_div = self.transpose_seq_clock_div,
            transpose_seq_step = self.transpose_seq_step,
            track_gate_ticks = deep_copy_table(self.track_gate_ticks),
            track_hold_tie_len_enabled = deep_copy_table(self.track_hold_tie_len_enabled),
            fill_patterns = deep_copy_table(self.fill_patterns),
            ratios = deep_copy_table(self.ratios),
            spice = deep_copy_table(self.spice),
            save_slots = deep_copy_table(self.save_slots),
            beat_repeat_len = self.beat_repeat_len,
            beat_repeat_mode = self.beat_repeat_mode,
            beat_repeat_direction = self.beat_repeat_direction,
            beat_repeat_excluded = deep_copy_table(self.beat_repeat_excluded),
            master_seq_len_enabled = self.master_seq_len_enabled,
            master_seq_len = self.master_seq_len,
            send_midi_clock_out = self.send_midi_clock_out,
            send_midi_start_stop_out = self.send_midi_start_stop_out,
            spice_accum_min = self.spice_accum_min,
            spice_accum_max = self.spice_accum_max,
            scale_type = self.scale_type,
            screen_orientation = self.screen_orientation,
            key_root = self.key_root,
            key_transpose = self.key_transpose,
            scale_degree = self.scale_degree,
            track_cfg = self:export_track_cfg(),
            sel_track = self.sel_track,
            step = self.step
        }
    end

    function App:import_state(state)
        if type(state) ~= "table" then return end

        if type(state.track_cfg) == "table" then
            self:import_track_cfg(state.track_cfg, false)
        end

        local deep_table_schema = {
            "tracks",
            "track_steps",
            "track_clock_div",
            "track_clock_mult",
            "track_transpose",
            "track_rand_gate_prob",
            "track_rand_pitch_prob",
            "track_rand_pitch_span",
            "transpose_seq_steps",
            "transpose_seq_assign",
            "track_gate_ticks",
            "track_hold_tie_len_enabled",
            "fill_patterns",
            "ratios",
            "spice",
            "save_slots",
            "beat_repeat_excluded",
        }
        for _, field in ipairs(deep_table_schema) do
            if type(state[field]) == "table" then
                self[field] = deep_copy_table(state[field])
            end
        end

        self.beat_repeat_len = tonumber(state.beat_repeat_len) or 0
        self.beat_repeat_mode = state.beat_repeat_mode or self.beat_repeat_mode
        self.beat_repeat_direction = (state.beat_repeat_direction == "l<-r") and "l<-r" or "l->r"
        if self.beat_repeat_mode == "step-select" then
            self.beat_repeat_len = 0
            self:reset_step_select_repeat()
        end
        self.master_seq_len_enabled = not not state.master_seq_len_enabled
        self.master_seq_len = clamp(tonumber(state.master_seq_len) or cfg.DEFAULT_MASTER_SEQ_LEN, 1, cfg.MAX_MASTER_SEQ_LEN)
        if state.send_midi_clock_out ~= nil then self.send_midi_clock_out = not not state.send_midi_clock_out end
        if state.send_midi_start_stop_out ~= nil then self.send_midi_start_stop_out = not not state.send_midi_start_stop_out end
        self:set_spice_accum_bounds(state.spice_accum_min, state.spice_accum_max)
        self.scale_type = state.scale_type or self.scale_type
        self.screen_orientation = (state.screen_orientation == "cw90") and "cw90" or "normal"
        self.key_root = clamp(tonumber(state.key_root) or self.key_root or 0, 0, 11)
        self.key_transpose = clamp(tonumber(state.key_transpose) or self.key_transpose or 0, -7, 8)
        self.transpose_mode = (state.transpose_mode == "scale degree") and "scale degree" or "semitone"
        self.transpose_takeover_mode = not not state.transpose_takeover_mode
        if state.transpose_seq_enabled ~= nil then
            self.transpose_seq_enabled = not not state.transpose_seq_enabled
        else
            self.transpose_seq_enabled = self.transpose_takeover_mode
        end
        self.transpose_seq_selected_step = clamp(tonumber(state.transpose_seq_selected_step) or self.transpose_seq_selected_step or 1, 1,
            cfg.NUM_STEPS)
        self.transpose_seq_clock_mult = clamp(tonumber(state.transpose_seq_clock_mult) or self.transpose_seq_clock_mult or 1, 1, 8)
        self.transpose_seq_clock_div = clamp(tonumber(state.transpose_seq_clock_div) or self.transpose_seq_clock_div or 4, 1, 64)
        self.transpose_seq_step = clamp(tonumber(state.transpose_seq_step) or self.transpose_seq_step or 1, 1, cfg.NUM_STEPS)
        self.transpose_seq_clock_phase = 0
        self.scale_degree = clamp(tonumber(state.scale_degree) or self.scale_degree or 1, 1, 7)
        self.sel_track = tonumber(state.sel_track)
        self.step = tonumber(state.step) or 1

        for t = 1, cfg.NUM_TRACKS do
            if not self.tracks[t] then
                self.tracks[t] = {
                    gates = {},
                    vels = {},
                    pitches = {},
                    muted = false,
                    solo = false,
                    start_step = 1,
                    end_step = cfg.NUM_STEPS,
                    octave = 0
                }
            end
            if not self.track_steps[t] then self.track_steps[t] = 1 end
            if not self.track_clock_div[t] then self.track_clock_div[t] = 1 end
            if not self.track_clock_mult[t] then self.track_clock_mult[t] = 1 end
            if not self.track_clock_phase[t] then self.track_clock_phase[t] = 0 end
            if not self.track_transpose[t] then self.track_transpose[t] = 0 end
            self.track_rand_gate_prob[t] = clamp(tonumber(self.track_rand_gate_prob[t]) or 0, 0, 1)
            self.track_rand_pitch_prob[t] = clamp(tonumber(self.track_rand_pitch_prob[t]) or 0, 0, 1)
            self.track_rand_pitch_span[t] = clamp(tonumber(self.track_rand_pitch_span[t]) or 0, 0, 15)
            if not self.track_gate_ticks[t] then
                self.track_gate_ticks[t] = (self.track_cfg[t].type == "drum") and self.drum_gate_clocks or
                    self.melody_gate_clocks
            end
            if self.transpose_seq_assign[t] == nil then
                self.transpose_seq_assign[t] = (self.track_cfg[t].type ~= "drum")
            end
            self.track_gate_ticks[t] = clamp(tonumber(self.track_gate_ticks[t]) or 1, 1, 24)
            if self.track_hold_tie_len_enabled[t] == nil then self.track_hold_tie_len_enabled[t] = true end
            self.track_hold_tie_len_enabled[t] = not not self.track_hold_tie_len_enabled[t]
            if not self.fill_patterns[t] then self.fill_patterns[t] = {} end
            if not self.ratios[t] then self.ratios[t] = {} end
            if not self.spice[t] then self.spice[t] = {} end
            if not self.track_loop_count[t] then self.track_loop_count[t] = 1 end
            self:ensure_track_state(t)
        end

        for s = 1, cfg.NUM_STEPS do
            local step = self.transpose_seq_steps[s]
            if type(step) ~= "table" then step = {} end
            self.transpose_seq_steps[s] = {
                active = not not step.active,
                degree = clamp(tonumber(step.degree) or 1, 1, 16)
            }
        end

        self:invalidate_aux_degree_cache()
        self:request_redraw()
        self:request_aux_redraw()
    end

    function App:save_preset(number)
        if not tab or not tab.save then return end
        ensure_dir(self:preset_dir())
        tab.save(self:export_state(), self:preset_path(number))
    end

    function App:load_preset(number)
        if not tab or not tab.load then return end
        local loaded = tab.load(self:preset_path(number))
        if type(loaded) == "table" then
            self:stop_all_notes()
            local was_suspended = self.suspend_history
            self.suspend_history = true
            self:import_state(loaded)
            if type(loaded.track_cfg) == "table" then
                self:import_track_cfg(loaded.track_cfg, true)
            else
                self:sync_track_cfg_from_params()
            end
            self.suspend_history = was_suspended
            self:invalidate_step_cache()
        end
    end

    function App:delete_preset(number)
        os.remove(self:preset_path(number))
    end

    function App:save_to_slot(slot)
        if slot < 1 or slot > 8 then return end
        local snap = { g = {}, p = {}, v = {}, r = {}, sp = {}, m = {}, key_transpose = self.key_transpose, tt = {} }
        for t = 1, cfg.NUM_TRACKS do
            local tr = self:ensure_track_state(t)
            local tc = self.track_cfg[t]
            snap.g[t] = {}
            snap.p[t] = {}
            snap.v[t] = {}
            snap.r[t] = {}
            snap.sp[t] = {}
            snap.tt[t] = clamp(tonumber(self.track_transpose[t]) or 0, -96, 96)
            snap.m[t] = {
                start_step = clamp(tonumber(tr.start_step) or 1, 1, cfg.NUM_STEPS),
                end_step = clamp(tonumber(tr.end_step) or cfg.NUM_STEPS, 1, cfg.NUM_STEPS),
                octave = clamp(tonumber(tr.octave) or 0, -7, 8),
                clock_mult = clamp(tonumber(self.track_clock_mult[t]) or 1, 1, 8),
                clock_div = clamp(tonumber(self.track_clock_div[t]) or 1, 1, 64),
                arc = deep_copy_table(tr.arc or { pulses = 0, rotation = 1, variance = 0, mode = 1 })
            }
            for s = 1, cfg.NUM_STEPS do
                if tr.gates[s] then
                    snap.g[t][s] = 1
                    snap.v[t][s] = clamp(tonumber(tr.vels[s]) or cfg.DEFAULT_VEL_LEVEL, 1, 15)
                    if tc.type == "poly" then
                        local pv = {}
                        for i, d in ipairs(tr.pitches[s]) do pv[i] = d end
                        snap.p[t][s] = pv
                    else
                        snap.p[t][s] = tr.pitches[s]
                    end
                end
                if self.ratios[t] and self.ratios[t][s] then
                    snap.r[t][s] = deep_copy_table(self.ratios[t][s])
                end
                if self.spice[t] and self.spice[t][s] then
                    snap.sp[t][s] = deep_copy_table(self.spice[t][s])
                end
            end
        end
        self.save_slots[slot] = snap
    end

    function App:load_from_slot(slot)
        if slot < 1 or slot > 8 then return end
        local snap = self.save_slots[slot]
        if not snap then return end
        for t = 1, cfg.NUM_TRACKS do
            local tr = self:ensure_track_state(t)
            local tc = self.track_cfg[t]
            self.ratios[t] = {}
            self.spice[t] = {}
            for s = 1, cfg.NUM_STEPS do
                tr.gates[s] = false
                tr.vels[s] = self:get_track_default_vel_level(t)
                if tc.type == "poly" then tr.pitches[s] = { 1 } else tr.pitches[s] = 1 end
            end
            local sg = snap.g[t] or {}
            local sp = snap.p[t] or {}
            local sv = snap.v[t] or {}
            local sr = snap.r[t] or {}
            local ssp = snap.sp[t] or {}
            local sm = snap.m[t] or {}
            tr.start_step = clamp(tonumber(sm.start_step) or tr.start_step or 1, 1, cfg.NUM_STEPS)
            tr.end_step = clamp(tonumber(sm.end_step) or tr.end_step or cfg.NUM_STEPS, 1, cfg.NUM_STEPS)
            tr.octave = clamp(tonumber(sm.octave) or tr.octave or 0, -7, 8)
            tr.arc = deep_copy_table(sm.arc or tr.arc or { pulses = 0, rotation = 1, variance = 0, mode = 1 })
            self.track_clock_mult[t] = clamp(tonumber(sm.clock_mult) or self.track_clock_mult[t] or 1, 1, 8)
            self.track_clock_div[t] = clamp(tonumber(sm.clock_div) or self.track_clock_div[t] or 1, 1, 64)
            self.track_transpose[t] = clamp(tonumber((snap.tt or {})[t]) or self.track_transpose[t] or 0, -96, 96)
            for s = 1, cfg.NUM_STEPS do
                if sg[s] then
                    tr.gates[s] = true
                    tr.vels[s] = clamp(tonumber(sv[s]) or cfg.DEFAULT_VEL_LEVEL, 1, 15)
                    if tc.type == "poly" then
                        local pv = sp[s]
                        if type(pv) == "table" and #pv > 0 then
                            local cp = {}
                            for i, d in ipairs(pv) do cp[i] = clamp(tonumber(d) or 1, 1, 16) end
                            tr.pitches[s] = cp
                        end
                    else
                        tr.pitches[s] = clamp(tonumber(sp[s]) or 1, 1, 16)
                    end
                end
                if sr[s] then self.ratios[t][s] = deep_copy_table(sr[s]) end
                if ssp[s] then self.spice[t][s] = deep_copy_table(ssp[s]) end
            end
        end
        self.key_transpose = clamp(tonumber(snap.key_transpose) or self.key_transpose or 0, -7, 8)
        self:invalidate_step_cache()
        self:request_arc_redraw()
        self:request_redraw()
        self:request_aux_redraw()
    end

end

return M
