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
local swing_profiles = include("lib/sequencer/swing_profiles")

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

        for t = 1, cfg.NUM_TRACKS do
            if self.track_cfg[t] and self.track_cfg[t].type == "split" then
                self:ensure_split_track_state(t)
            end
        end

        if sync_params and params and params.set then
            local was_suspended = self.suspend_history
            self.suspend_history = true
            for t = 1, cfg.NUM_TRACKS do
                local tc = self.track_cfg[t]
                if tc then
                    local gid = "permute_track_" .. t
                    local type_idx = (tc.type == "drum") and 1 or ((tc.type == "mono") and 2 or ((tc.type == "poly") and 3 or 4))
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
                type = (type_idx == 4 and "split") or (type_idx == 3 and "poly") or (type_idx == 2 and "mono") or "drum",
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
            track_view_page = deep_copy_table(self.track_view_page),
            track_aux_page = deep_copy_table(self.track_aux_page),
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
            split_gate_pos = deep_copy_table(self.split_gate_pos),
            split_pitch_pos = deep_copy_table(self.split_pitch_pos),
            split_gate_substep = deep_copy_table(self.split_gate_substep),
            split_gate_hold_active = deep_copy_table(self.split_gate_hold_active),
            split_arc_pitch_pos = deep_copy_table(self.split_arc_pitch_pos),
            fill_patterns = deep_copy_table(self.fill_patterns),
            ratios = deep_copy_table(self.ratios),
            spice = deep_copy_table(self.spice),
            track_pattern_slots = deep_copy_table(self.track_pattern_slots),
            track_pattern_slot_active = deep_copy_table(self.track_pattern_slot_active),
            track_pattern_slot_highest = deep_copy_table(self.track_pattern_slot_highest),
            pattern_slot_dynamic_mode = self.pattern_slot_dynamic_mode,
            pattern_slot_switch_timing = self.pattern_slot_switch_timing,
            beat_repeat_len = self.beat_repeat_len,
            beat_repeat_mode = self.beat_repeat_mode,
            beat_repeat_direction = self.beat_repeat_direction,
            beat_repeat_excluded = deep_copy_table(self.beat_repeat_excluded),
            master_seq_len_enabled = self.master_seq_len_enabled,
            master_seq_len = self.master_seq_len,
            global_swing_percent = self.global_swing_percent,
            global_swing_profile = self.global_swing_profile,
            follow_page_on_playhead = self.follow_page_on_playhead,
            follow_page_on_playhead_aux_takeover = self.follow_page_on_playhead_aux_takeover,
            follow_page_on_playhead_aux = self.follow_page_on_playhead_aux,
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
            lpp_enabled = self.lpp_enabled,
            lpp_input_port = self.lpp_input_port,
            lpp_programmer_auto_enter = self.lpp_programmer_auto_enter,
            lpp_led_feedback = self.lpp_led_feedback,
            lpp_octave_min = self.lpp_octave_min,
            lpp_octave_max = self.lpp_octave_max,
            lpp_zone_octave = deep_copy_table(self.lpp_zone_octave),
            lpp_zone_track = deep_copy_table(self.lpp_zone_track),
            lpp_zone_melodic_colors = deep_copy_table(self.lpp_zone_melodic_colors),
            lpp_drum_page = self.lpp_drum_page,
            sel_track = self.sel_track,
            step = self.step
        }
    end

    function App:import_state(state)
        if type(state) ~= "table" then return end
        local track_step_limit = self:get_track_step_limit()

        if type(state.track_cfg) == "table" then
            self:import_track_cfg(state.track_cfg, false)
        end

        local deep_table_schema = {
            "tracks",
            "track_steps",
            "track_clock_div",
            "track_clock_mult",
            "track_transpose",
            "track_view_page",
            "track_aux_page",
            "track_rand_gate_prob",
            "track_rand_pitch_prob",
            "track_rand_pitch_span",
            "transpose_seq_steps",
            "transpose_seq_assign",
            "track_gate_ticks",
            "track_hold_tie_len_enabled",
            "split_gate_pos",
            "split_pitch_pos",
            "split_gate_substep",
            "split_gate_hold_active",
            "split_arc_pitch_pos",
            "fill_patterns",
            "ratios",
            "spice",
            "track_pattern_slots",
            "track_pattern_slot_active",
            "track_pattern_slot_highest",
            "beat_repeat_excluded",
            "lpp_zone_octave",
            "lpp_zone_track",
            "lpp_zone_melodic_colors",
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
        self.global_swing_percent = clamp(tonumber(state.global_swing_percent) or self.global_swing_percent or 50, 25, 75)
        local profile = state.global_swing_profile or self.global_swing_profile or "linear"
        if not ((swing_profiles.enabled or {})[profile]) then
            profile = "linear"
        end
        self.global_swing_profile = profile
        if state.follow_page_on_playhead ~= nil then
            self.follow_page_on_playhead = not not state.follow_page_on_playhead
        end
        if state.follow_page_on_playhead_aux_takeover ~= nil then
            self.follow_page_on_playhead_aux_takeover = not not state.follow_page_on_playhead_aux_takeover
        end
        if state.follow_page_on_playhead_aux ~= nil then
            self.follow_page_on_playhead_aux = not not state.follow_page_on_playhead_aux
        end
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
        if state.pattern_slot_dynamic_mode then
            self.pattern_slot_dynamic_mode = state.pattern_slot_dynamic_mode
        end
        if state.pattern_slot_switch_timing then
            self.pattern_slot_switch_timing = state.pattern_slot_switch_timing
        end
        if type(self.track_pattern_slot_dirty) ~= "table" then self.track_pattern_slot_dirty = {} end
        if type(self.pending_pattern_switches) ~= "table" then self.pending_pattern_switches = {} end
        for t = 1, cfg.NUM_TRACKS do
            self:init_track_pattern_slots(t)
            self.track_pattern_slot_dirty[t] = false
        end
        self.transpose_seq_clock_phase = 0
        self.scale_degree = clamp(tonumber(state.scale_degree) or self.scale_degree or 1, 1, 7)
        self.lpp_enabled = not not state.lpp_enabled
        self.lpp_input_port = clamp(tonumber(state.lpp_input_port) or self.lpp_input_port or 0, 0, 16)
        self.lpp_programmer_auto_enter = not not state.lpp_programmer_auto_enter
        if state.lpp_led_feedback ~= nil then self.lpp_led_feedback = not not state.lpp_led_feedback end
        self.lpp_octave_min = clamp(tonumber(state.lpp_octave_min) or self.lpp_octave_min or -4, -8, 0)
        self.lpp_octave_max = clamp(tonumber(state.lpp_octave_max) or self.lpp_octave_max or 4, 0, 8)
        self.lpp_drum_page = clamp(tonumber(state.lpp_drum_page) or self.lpp_drum_page or 1, 1, 2)
        self.sel_track = tonumber(state.sel_track)
        self.step = tonumber(state.step) or 1

        if type(self.lpp_zone_octave) ~= "table" then self.lpp_zone_octave = {} end
        if type(self.lpp_zone_track) ~= "table" then self.lpp_zone_track = {} end
        if type(self.lpp_zone_melodic_colors) ~= "table" then self.lpp_zone_melodic_colors = {} end
        for _, zone in ipairs({ "zone_b", "zone_c", "zone_d", "zone_e" }) do
            self.lpp_zone_octave[zone] = clamp(tonumber((self.lpp_zone_octave or {})[zone]) or 0, self.lpp_octave_min, self.lpp_octave_max)
            self.lpp_zone_track[zone] = clamp(tonumber((self.lpp_zone_track or {})[zone]) or self.lpp_zone_track[zone] or 1, 1, cfg.NUM_TRACKS)
            if type(self.lpp_zone_melodic_colors[zone]) ~= "table" then self.lpp_zone_melodic_colors[zone] = {} end
            self.lpp_zone_melodic_colors[zone].octave = clamp(
                tonumber((self.lpp_zone_melodic_colors[zone] or {}).octave) or 0,
                0, 127)
            self.lpp_zone_melodic_colors[zone].note = clamp(
                tonumber((self.lpp_zone_melodic_colors[zone] or {}).note) or 0,
                0, 127)
        end

        for t = 1, cfg.NUM_TRACKS do
            if not self.tracks[t] then
                self.tracks[t] = {
                    gates = {},
                    vels = {},
                    pitches = {},
                    muted = false,
                    solo = false,
                    start_step = 1,
                    end_step = math.min(cfg.NUM_STEPS, track_step_limit),
                    octave = 0
                }
            end
            if not self.track_steps[t] then self.track_steps[t] = 1 end
            if not self.track_clock_div[t] then self.track_clock_div[t] = 1 end
            if not self.track_clock_mult[t] then self.track_clock_mult[t] = 1 end
            if type(self.track_view_page) ~= "table" then self.track_view_page = {} end
            self.track_view_page[t] = self:set_track_view_page(t, self.track_view_page[t] or 1)
            if type(self.track_aux_page) ~= "table" then self.track_aux_page = {} end
            self.track_aux_page[t] = self:set_track_aux_page(t, self.track_aux_page[t] or self.track_view_page[t])
            self:set_track_playhead_page(t, self.track_view_page[t])
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
            if type(self.track_state_validated_step_limit) == "table" then
                self.track_state_validated_step_limit[t] = nil
            end
            self:ensure_track_state(t)
            if self:is_track_split(t) then
                self:ensure_split_track_state(t)
            end
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

end

return M
