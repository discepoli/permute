local cfg = include("lib/config")
local param_setup = include("lib/params")
local icons = include("lib/icons")
local musicutil = require("musicutil")

local App = {}
App.__index = App

local function clamp(v, lo, hi)
    if v == nil then return lo end
    if v < lo then return lo end
    if v > hi then return hi end
    return v
end

local function now_ms()
    return math.floor((util.time() or 0) * 1000)
end

local function deep_copy_table(t)
    local out = {}
    for k, v in pairs(t) do
        if type(v) == "table" then
            out[k] = deep_copy_table(v)
        else
            out[k] = v
        end
    end
    return out
end

local function ensure_dir(path)
    if util and util.make_dir then
        util.make_dir(path)
    else
        os.execute("mkdir -p '" .. path .. "'")
    end
end

local SCALE_DEGREE_INDICES = {
    diatonic = { 1, 2, 3, 4, 5, 6, 7 },
    pentatonic = { 1, 2, 3, 4, 5 },
    lightbath = { 1, 2, 3, 4 }
}

local ARC_VARIANCE_MODES = {
    "triangle",
    "ramp down",
    "ramp up",
    "random",
    "cadence 1",
    "cadence 2",
    "cadence 3",
    "cadence 4"
}

local ARC_CADENCE_SHAPES = {
    { -1,    -0.33, 0.33,  1 },
    { -1,    -0.66, -0.33, 1 },
    { -0.66, 0.33,  0.66,  -1, -0.66, 0.33 },
    { -0.33, 0.33,  0.33,  -1, -0.66, -0.33 }
}

local ARC_DELTA_THRESHOLDS = {
    [1] = 8,
    [2] = 12,
    [3] = 2,
    [4] = 16
}

function App.new()
    local self = setmetatable({}, App)

    self.tempo_bpm = cfg.DEFAULT_TEMPO_BPM
    self.use_midi_clock = true
    self.send_midi_clock_out = true
    self.send_midi_start_stop_out = true
    self.scale_type = "diatonic"
    self.key_root = 0
    self.key_transpose = 0
    self.scale_degree = 1

    self.melody_gate_clocks = 5
    self.drum_gate_clocks = 1
    self.track_cfg = deep_copy_table(cfg.TRACK_CFG)

    self.tracks = {}
    self.step = 1
    self.playing = false
    self.held = nil
    self.held_time = 0
    self.HOLD_THRESHOLD = 150

    self.last_notes = {}
    self.clock_ticks = 0
    self.transport_clock = 0
    self.active_note_offs = {}

    self.last_redraw_time = 0
    self.redraw_min_ms = 20
    self.redraw_deferred = false
    self.screen_orientation = "normal"

    self.track_steps = {}
    self.track_clock_div = {}
    self.track_clock_mult = {}
    self.track_clock_phase = {}
    self.track_loop_count = {}

    self.mod_held = {}
    self.mod_last_tap_time = {}
    self.mod_shortcut_consumed = {}
    self.sel_track = 1
    self.temp_steps = {}
    self.temp_latched = false
    self.fill_latched = false
    self.temp_button_mode = "temp"
    self.mod_double_tap_ms = 250
    self.takeover_mode = false
    self.realtime_play_mode = false
    self.realtime_row_holds = {}
    self.beat_repeat_len = 0
    self.beat_repeat_mode = "full-row"
    self.beat_repeat_direction = "l->r"
    self.beat_repeat_excluded = {}
    self.beat_repeat_select_start = nil
    self.beat_repeat_select_end = nil
    self.beat_repeat_select_armed = false
    self.beat_repeat_select_active = false
    self.beat_repeat_select_cycle = 0
    self.speed_mode = false
    self.save_slots = {}
    self.fill_patterns = {}
    self.ratios = {}
    self.fill_active = false
    self.ratio_pending_cycle = 4
    self.ratio_pending_position = 1
    self.spice = {}
    self.spice_pending_amount = nil
    self.spice_accum_min = cfg.SPICE_MIN
    self.spice_accum_max = cfg.SPICE_MAX
    self.track_transpose = {}
    self.track_default_vel = {}
    self.track_gate_ticks = {}
    self.undo_stack = {}
    self.redo_stack = {}
    self.history_limit = 5
    self.suspend_history = false

    self.master_seq_len_enabled = false
    self.master_seq_len = cfg.DEFAULT_MASTER_SEQ_LEN
    self.master_seq_counter = 0

    self.last_mod_pressed = nil
    self.status_message = nil
    self.status_value = nil
    self.status_mod_id = nil
    self.status_message_until = 0
    self.status_message_invert = false
    self.rand_notes_rolled = false
    self.rand_steps_shuffled = false
    self.fill_applied = false

    self.beat_repeat_start = 0
    self.beat_repeat_cycle = 0
    self.beat_repeat_anchor = {}

    self.screen_dirty = true
    self.grid_dirty = true
    self.arc_dirty = true
    self.grid_timer = nil
    self.internal_clock_id = nil
    self.arc_dev = nil
    self.arc_delta_accum = { 0, 0, 0, 0 }
    self.arc_delta_thresholds = deep_copy_table(ARC_DELTA_THRESHOLDS)
    self.arc_last_history_at = 0

    self.grid_dev = nil
    self.main_grid_dev = nil
    self.aux_grid_dev = nil
    self.grid_ports = {}
    self.main_grid_port = nil
    self.aux_grid_port = nil
    self.midi_dev = nil
    self.midi_devs = {}
    self.midi_port_slots = { 1, 0, 0, 0 }
    self.midi_out_ports = { 1 }
    self.midi_active_ports = { [1] = true }
    self.midi_clock_in_port = nil

    self.crow_enabled = false
    self.crow_track_1 = 0
    self.crow_track_2 = 0

    for t = 1, cfg.NUM_TRACKS do
        self.tracks[t] = {
            gates = {},
            ties = {},
            vels = {},
            pitches = {},
            muted = false,
            solo = false,
            start_step = 1,
            end_step = cfg.NUM_STEPS,
            octave = 0,
            arc = {
                pulses = 0,
                rotation = 1,
                variance = 0,
                mode = 1
            }
        }
        for s = 1, cfg.NUM_STEPS do
            self.tracks[t].gates[s] = false
            self.tracks[t].ties[s] = false
            self.tracks[t].vels[s] = cfg.DEFAULT_VEL_LEVEL
            if self.track_cfg[t].type == "poly" then
                self.tracks[t].pitches[s] = { 1 }
            else
                self.tracks[t].pitches[s] = 1
            end
        end

        self.track_steps[t] = 1
        self.track_clock_div[t] = 1
        self.track_clock_mult[t] = 1
        self.track_clock_phase[t] = 0
        self.track_loop_count[t] = 1
        self.fill_patterns[t] = {}
        self.ratios[t] = {}
        self.spice[t] = {}
        self.track_transpose[t] = 0
        self.track_default_vel[t] = self:vel_to_midi(cfg.DEFAULT_VEL_LEVEL)
        self.track_gate_ticks[t] = (self.track_cfg[t].type == "drum") and self.drum_gate_clocks or
            self.melody_gate_clocks
    end

    return self
end

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
    local ids = {
        "permute_scale",
        "permute_key",
        "permute_scale_degree",
        "permute_tempo",
        "permute_master_len_enabled",
        "permute_master_len",
        "permute_ext_clock",
        "permute_send_clock_out",
        "permute_send_start_stop_out",
        "permute_midi_out",
        "permute_midi_out_2",
        "permute_midi_out_3",
        "permute_midi_out_4",
        "permute_melody_gate_ticks",
        "permute_drum_gate_ticks",
        "permute_spice_accum_min",
        "permute_spice_accum_max",
        "permute_crow_enabled",
        "permute_crow_track_1",
        "permute_crow_track_2",
        "permute_redraw_fps",
        "permute_screen_orientation",
        "permute_beat_repeat_mode",
        "permute_beat_repeat_direction",
        "permute_temp_button_mode",
        "permute_arc_k1_threshold",
        "permute_arc_k2_threshold",
        "permute_arc_k3_threshold",
        "permute_arc_k4_threshold"
    }

    for t = 1, cfg.NUM_TRACKS do
        local gid = "permute_track_" .. t
        ids[#ids + 1] = gid .. "_type"
        ids[#ids + 1] = gid .. "_ch"
        ids[#ids + 1] = gid .. "_note"
        ids[#ids + 1] = gid .. "_vel"
        ids[#ids + 1] = gid .. "_len"
    end

    return ids
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

function App:get_selected_midi_ports()
    local ports = {}
    local seen = {}
    for _, port in ipairs(self.midi_port_slots or {}) do
        local midi_port = clamp(tonumber(port) or 0, 0, 16)
        if midi_port > 0 and not seen[midi_port] then
            ports[#ports + 1] = midi_port
            seen[midi_port] = true
        end
    end
    return ports
end

function App:capture_midi_ports(ports)
    if type(ports) == "table" then return deep_copy_table(ports) end
    return self:get_selected_midi_ports()
end

function App:get_beat_repeat_length_for_column(x)
    if self.beat_repeat_mode == "one-handed" then
        local map = (self.beat_repeat_direction == "l<-r")
            and {
                [13] = 8,
                [14] = 4,
                [15] = 2,
                [16] = 1
            }
            or {
                [13] = 1,
                [14] = 2,
                [15] = 4,
                [16] = 8
            }
        return map[x]
    end
    if x >= 1 and x <= 16 then
        return (self.beat_repeat_direction == "l<-r") and (17 - x) or x
    end
    return nil
end

function App:get_beat_repeat_column_for_length(len)
    local rpt_len = tonumber(len) or 0
    if self.beat_repeat_mode == "one-handed" then
        local map = (self.beat_repeat_direction == "l<-r")
            and {
                [1] = 16,
                [2] = 15,
                [4] = 14,
                [8] = 13
            }
            or {
                [1] = 13,
                [2] = 14,
                [4] = 15,
                [8] = 16
            }
        return map[rpt_len]
    end
    if rpt_len >= 1 and rpt_len <= 16 then
        return (self.beat_repeat_direction == "l<-r") and (17 - rpt_len) or rpt_len
    end
    return nil
end

function App:reset_step_select_repeat()
    self.beat_repeat_select_start = nil
    self.beat_repeat_select_end = nil
    self.beat_repeat_select_armed = false
    self.beat_repeat_select_active = false
    self.beat_repeat_select_cycle = 0
end

function App:get_step_select_repeat_spec()
    local start_step = tonumber(self.beat_repeat_select_start)
    local end_step = tonumber(self.beat_repeat_select_end)
    if not start_step or not end_step then return nil end
    local direction = (end_step >= start_step) and 1 or -1
    local len = math.abs(end_step - start_step) + 1
    return start_step, end_step, direction, len
end

function App:get_step_select_repeat_target_step()
    local start_step, _, direction, len = self:get_step_select_repeat_spec()
    if not start_step then return nil end
    local idx = (tonumber(self.beat_repeat_select_cycle) or 0) % len
    return start_step + (idx * direction)
end

function App:get_step_select_repeat_cycle_for_step(step)
    local start_step, _, direction, len = self:get_step_select_repeat_spec()
    if not start_step then return 0 end
    local s = clamp(tonumber(step) or start_step, 1, cfg.NUM_STEPS)
    local idx = (direction == 1) and (s - start_step) or (start_step - s)
    if idx < 0 or idx >= len then return 0 end
    return idx
end

function App:is_step_select_repeat_hold_active()
    if self.mod_held[cfg.MOD.BEAT_RPT] then return true end
    local held = self.dynamic_row_held or {}
    local start_step = tonumber(self.beat_repeat_select_start)
    local end_step = tonumber(self.beat_repeat_select_end)
    if start_step and held[start_step] then return true end
    if end_step and held[end_step] then return true end
    return false
end

function App:clear_step_select_repeat_state()
    self.beat_repeat_len = 0
    self.beat_repeat_excluded = {}
    self:reset_step_select_repeat()
    self.dynamic_row_held = {}
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

function App:for_each_midi_device(ports, fn)
    local selected_ports = self:capture_midi_ports(ports)
    for _, port in ipairs(selected_ports) do
        local dev = self.midi_devs[port]
        if dev then
            fn(dev, port)
        end
    end
    return selected_ports
end

function App:set_spice_accum_bounds(min_v, max_v)
    local lo = clamp(tonumber(min_v) or cfg.SPICE_MIN, -127, 127)
    local hi = clamp(tonumber(max_v) or cfg.SPICE_MAX, -127, 127)
    if lo > hi then lo, hi = hi, lo end
    self.spice_accum_min = lo
    self.spice_accum_max = hi
end

function App:get_screen_rotation_quadrants()
    return 0
end

function App:get_active_screen_orientation()
    local mode = self.screen_orientation or "normal"
    if params and params.get then
        local ok, idx = pcall(function() return params:get("permute_screen_orientation") end)
        if ok then
            mode = (tonumber(idx) == 2) and "cw90" or "normal"
        end
    end
    return mode
end

function App:is_screen_rotated_90()
    return false
end

function App:get_screen_canvas_size()
    return 128, 64
end

function App:apply_screen_transform()
    return
end

function App:reset_screen_transform()
    return
end

function App:capture_default_setup_values()
    local values = {}
    for _, id in ipairs(self:default_setup_param_ids()) do
        local ok, val = pcall(function() return params:get(id) end)
        if ok and val ~= nil then values[id] = val end
    end
    return values
end

function App:flash_status(label, value, duration)
    self.status_message = tostring(label or "")
    self.status_value = value and tostring(value) or nil
    self.status_mod_id = nil
    self.status_message_invert = true
    self.status_message_until = (util.time() or 0) + (duration or 0.4)
    self:request_redraw()
    local expires_at = self.status_message_until
    clock.run(function()
        clock.sleep((duration or 0.4) + 0.01)
        if self.status_message_until == expires_at then
            self.status_message = nil
            self.status_value = nil
            self.status_mod_id = nil
            self.status_message_invert = false
            self:request_redraw()
        end
    end)
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
    self:request_redraw()

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
    self:request_redraw()

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
        track_gate_ticks = deep_copy_table(self.track_gate_ticks),
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

    if type(state.tracks) == "table" then self.tracks = deep_copy_table(state.tracks) end
    if type(state.track_steps) == "table" then self.track_steps = deep_copy_table(state.track_steps) end
    if type(state.track_clock_div) == "table" then self.track_clock_div = deep_copy_table(state.track_clock_div) end
    if type(state.track_clock_mult) == "table" then self.track_clock_mult = deep_copy_table(state.track_clock_mult) end
    if type(state.track_transpose) == "table" then self.track_transpose = deep_copy_table(state.track_transpose) end
    if type(state.track_gate_ticks) == "table" then self.track_gate_ticks = deep_copy_table(state.track_gate_ticks) end
    if type(state.fill_patterns) == "table" then self.fill_patterns = deep_copy_table(state.fill_patterns) end
    if type(state.ratios) == "table" then self.ratios = deep_copy_table(state.ratios) end
    if type(state.spice) == "table" then self.spice = deep_copy_table(state.spice) end
    if type(state.save_slots) == "table" then self.save_slots = deep_copy_table(state.save_slots) end
    if type(state.beat_repeat_excluded) == "table" then
        self.beat_repeat_excluded = deep_copy_table(state
            .beat_repeat_excluded)
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
        if not self.track_gate_ticks[t] then
            self.track_gate_ticks[t] = (self.track_cfg[t].type == "drum") and self.drum_gate_clocks or
                self.melody_gate_clocks
        end
        self.track_gate_ticks[t] = clamp(tonumber(self.track_gate_ticks[t]) or 1, 1, 24)
        if not self.fill_patterns[t] then self.fill_patterns[t] = {} end
        if not self.ratios[t] then self.ratios[t] = {} end
        if not self.spice[t] then self.spice[t] = {} end
        if not self.track_loop_count[t] then self.track_loop_count[t] = 1 end
        self:ensure_track_state(t)
    end

    self:request_redraw()
end

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

    self:request_arc_redraw()
    self:request_redraw()
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
    return true
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
    end
end

function App:delete_preset(number)
    os.remove(self:preset_path(number))
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
    for t = 1, cfg.NUM_TRACKS do
        self.track_steps[t] = 1
        self.track_clock_phase[t] = 0
        self.track_loop_count[t] = 1
    end
    self:request_redraw()
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

            if tc.type == "drum" then
                local base_vel = ref_step and tr.vels[ref_step] or cfg.DEFAULT_VEL_LEVEL
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
                    vel = ref_step and tr.vels[ref_step] or cfg.DEFAULT_VEL_LEVEL,
                    pitch = chord
                }
            else
                local base_degree = ref_step and tr.pitches[ref_step] or 1
                cache[step] = {
                    source = "arc",
                    vel = ref_step and tr.vels[ref_step] or cfg.DEFAULT_VEL_LEVEL,
                    pitch = clamp((tonumber(base_degree) or 1) + shift, 1, 16)
                }
            end
        end
    end

    return cache
end

function App:get_arc_step_data(track, step)
    return self:build_arc_step_cache(track)[step]
end

function App:is_temp_button_fill_mode()
    return self.temp_button_mode == "fill"
end

function App:get_temp_button_label()
    return self:is_temp_button_fill_mode() and "fill" or "temp"
end

function App:get_ratio_label()
    return tostring(clamp(tonumber(self.ratio_pending_position) or 1, 1, self.ratio_pending_cycle or 1))
        .. "/" .. tostring(self.ratio_pending_cycle or 1)
end

function App:set_ratio_cycle(cycle)
    self.ratio_pending_cycle = clamp(tonumber(cycle) or 1, 1, 8)
    self.ratio_pending_position = clamp(tonumber(self.ratio_pending_position) or 1, 1, self.ratio_pending_cycle)
end

function App:set_ratio_position(pos)
    self.ratio_pending_position = clamp(tonumber(pos) or 1, 1, self.ratio_pending_cycle or 1)
end

function App:apply_pending_ratio_to_step(track, step)
    if not self.ratios[track] then self.ratios[track] = {} end

    self.ratios[track][step] = {
        cycle = self.ratio_pending_cycle,
        position = clamp(tonumber(self.ratio_pending_position) or 1, 1, self.ratio_pending_cycle or 1)
    }
    return self:get_ratio_label()
end

function App:step_ratio_allows_play(track, step)
    local data = self.ratios[track] and self.ratios[track][step]
    if type(data) ~= "table" then return true end
    local cycle = clamp(tonumber(data.cycle) or 1, 1, 8)
    local loop_index = ((clamp(tonumber(self.track_loop_count[track]) or 1, 1, 999999) - 1) % cycle) + 1
    return loop_index == clamp(tonumber(data.position) or 1, 1, cycle)
end

function App:mod_name(id)
    if id == 5 then return "track select" end
    if id == cfg.MOD.MUTE then return "mute" end
    if id == cfg.MOD.SOLO then return "solo" end
    if id == cfg.MOD.START then return "start" end
    if id == cfg.MOD.END_STEP then return "end" end
    if id == cfg.MOD.RAND_NOTES then return "rand notes" end
    if id == cfg.MOD.RAND_STEPS then return "rand steps" end
    if id == cfg.MOD.TEMP then return self:get_temp_button_label() end
    if id == cfg.MOD.RATIOS then return "ratios" end
    if id == cfg.MOD.SHIFT then return "shift" end
    if id == cfg.MOD.OCTAVE then return "octave" end
    if id == cfg.MOD.TRANSPOSE then return "transpose" end
    if id == cfg.MOD.TAKEOVER then return "takeover" end
    if id == cfg.MOD.CLEAR then return "clear" end
    if id == cfg.MOD.SPICE then return "spice" end
    if id == cfg.MOD.BEAT_RPT then return "beat rpt" end
    return "mod " .. tostring(id)
end

function App:get_active_mod_id()
    if self.last_mod_pressed and self.mod_held[self.last_mod_pressed] then
        return self.last_mod_pressed
    end
    if self.last_mod_pressed == cfg.MOD.TEMP then
        if self:is_temp_button_fill_mode() and self.fill_latched then return cfg.MOD.TEMP end
        if not self:is_temp_button_fill_mode() and self.temp_latched then return cfg.MOD.TEMP end
    end
    for k, v in pairs(self.mod_held) do
        if v then return k end
    end
    if self:is_temp_button_fill_mode() then
        if self.fill_latched then return cfg.MOD.TEMP end
    elseif self.temp_latched then
        return cfg.MOD.TEMP
    end
    return nil
end

function App:mod_active(mod)
    if mod == cfg.MOD.TEMP then
        if self:is_temp_button_fill_mode() then return self.mod_held[mod] or self.fill_latched end
        return self.mod_held[mod] or self.temp_latched
    end
    return self.mod_held[mod]
end

function App:any_mod_active()
    if next(self.mod_held) then return true end
    return self.temp_latched or self.fill_latched
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

function App:get_active_mod_name()
    local id = self:get_active_mod_id()
    if not id then return nil end
    return self:mod_name(id)
end

function App:flash_mod_applied(mod_id, value)
    local name = self:mod_name(mod_id)
    self.status_message = name
    self.status_value = value and tostring(value) or nil
    self.status_mod_id = mod_id
    self.status_message_invert = true
    self.status_message_until = (util.time() or 0) + 0.25
    self:request_redraw()
    local expires_at = self.status_message_until
    clock.run(function()
        clock.sleep(0.26)
        if self.status_message_until == expires_at then
            self.status_message = nil
            self.status_value = nil
            self.status_mod_id = nil
            self.status_message_invert = false
            self:request_redraw()
        end
    end)
end

function App:get_active_mod_value(mod_id)
    if not mod_id then return nil end
    if mod_id == cfg.MOD.OCTAVE and self.sel_track then
        return tostring(self.tracks[self.sel_track].octave)
    elseif mod_id == cfg.MOD.TRANSPOSE then
        if self.sel_track then
            return tostring(clamp(tonumber(self.track_transpose[self.sel_track]) or 0, -7, 8))
        end
        return "0"
    elseif mod_id == cfg.MOD.BEAT_RPT then
        if self.beat_repeat_mode == "step-select" then
            local start_step = tonumber(self.beat_repeat_select_start)
            local end_step = tonumber(self.beat_repeat_select_end)
            if start_step and end_step then
                return tostring(start_step) .. "-" .. tostring(end_step)
            elseif start_step then
                return tostring(start_step) .. "-?"
            end
        end
        return tostring(self.beat_repeat_len or 0)
    elseif mod_id == cfg.MOD.SPICE then
        return tostring(self.spice_pending_amount or 0)
    elseif mod_id == cfg.MOD.RATIOS then
        return self:get_ratio_label()
    elseif mod_id == cfg.MOD.START and self.sel_track then
        return tostring(self.tracks[self.sel_track].start_step)
    elseif mod_id == cfg.MOD.END_STEP and self.sel_track then
        return tostring(self.tracks[self.sel_track].end_step)
    elseif mod_id == cfg.MOD.TAKEOVER then
        if self.realtime_play_mode then return "play" end
        return self.takeover_mode and "on" or "off"
    end
    return nil
end

function App:draw_big_center_text(line1, line2, invert)
    local w, h = self:get_screen_canvas_size()
    if invert then
        screen.level(15)
        screen.rect(0, 0, w, h)
        screen.fill()
        screen.level(0)
    else
        screen.level(15)
    end

    local sizes = { 18, 16, 14, 12 }
    local picked = 12
    for _, s in ipairs(sizes) do
        screen.font_size(s)
        local w1 = screen.text_extents(line1 or "")
        local w2 = line2 and screen.text_extents(line2) or 0
        if math.max(w1, w2) <= (w - 4) then
            picked = s
            break
        end
    end

    screen.font_size(picked)
    if line2 and line2 ~= "" then
        local y1 = (h > 64) and 44 or 26
        local y2 = (h > 64) and 80 or 50
        local w1 = screen.text_extents(line1)
        local w2 = screen.text_extents(line2)
        screen.move(math.floor((w - w1) / 2), y1)
        screen.text(line1)
        screen.move(math.floor((w - w2) / 2), y2)
        screen.text(line2)
    else
        local y = math.floor(h * 0.55)
        local tw = screen.text_extents(line1)
        screen.move(math.floor((w - tw) / 2), y)
        screen.text(line1)
    end
    screen.font_size(8)
end

function App:mod_id_from_name(name)
    if name == "track select" then return 5 end
    if name == "mute" then return cfg.MOD.MUTE end
    if name == "solo" then return cfg.MOD.SOLO end
    if name == "start" then return cfg.MOD.START end
    if name == "end" then return cfg.MOD.END_STEP end
    if name == "rand notes" then return cfg.MOD.RAND_NOTES end
    if name == "rand steps" then return cfg.MOD.RAND_STEPS end
    if name == "temp" then return cfg.MOD.TEMP end
    if name == "fill" then return cfg.MOD.TEMP end
    if name == "ratios" then return cfg.MOD.RATIOS end
    if name == "shift" then return cfg.MOD.SHIFT end
    if name == "octave" then return cfg.MOD.OCTAVE end
    if name == "transpose" then return cfg.MOD.TRANSPOSE end
    if name == "takeover" then return cfg.MOD.TAKEOVER end
    if name == "clear" then return cfg.MOD.CLEAR end
    if name == "spice" then return cfg.MOD.SPICE end
    if name == "beat rpt" then return cfg.MOD.BEAT_RPT end
    return nil
end

function App:mod_icon_state()
    return {
        track_selected = self.sel_track ~= nil,
        rand_notes_rolled = self.rand_notes_rolled,
        rand_steps_shuffled = self.rand_steps_shuffled,
        fill_applied = self.fill_applied,
        temp_button_mode = self.temp_button_mode
    }
end

function App:get_mod_screen_override()
    if self.speed_mode and self.mod_held[cfg.MOD.START] and self.mod_held[cfg.MOD.END_STEP] then
        return "clock_rate", "clock rate", nil
    end
    if self.mod_held[cfg.MOD.RAND_NOTES] and self.mod_held[cfg.MOD.RAND_STEPS] then
        return "random_sequence", "random sequence", nil
    end
    return nil, nil, nil
end

function App:draw_special_icon_screen(name, label, value, invert)
    if not name then return false end
    local w, h = self:get_screen_canvas_size()

    local fg = invert and 0 or 15
    local dim = invert and 4 or 6

    if invert then
        screen.level(15)
        screen.rect(0, 0, w, h)
        screen.fill()
    end

    local icon_cx = math.floor(w / 2)
    local icon_cy = (h > 64) and 34 or 24
    local drew = icons.draw_special(name, icon_cx, icon_cy, fg, dim, self:mod_icon_state())
    if not drew then return false end

    screen.level(fg)
    screen.font_size(8)

    if value and value ~= "" then
        local title = label or ""
        local val = tostring(value)
        local tw = screen.text_extents(title)
        local vw = screen.text_extents(val)
        local y1 = h - 14
        local y2 = h - 5
        screen.move(math.floor((w - tw) / 2), y1)
        screen.text(title)
        screen.move(math.floor((w - vw) / 2), y2)
        screen.text(val)
    else
        local text = label or ""
        local tw = screen.text_extents(text)
        screen.move(math.floor((w - tw) / 2), h - 10)
        screen.text(text)
    end

    return true
end

function App:draw_mod_icon_screen(mod_id, label, value, invert)
    if not mod_id then return false end
    local w, h = self:get_screen_canvas_size()

    local fg = invert and 0 or 15
    local dim = invert and 4 or 6

    if invert then
        screen.level(15)
        screen.rect(0, 0, w, h)
        screen.fill()
    end

    local icon_cx = math.floor(w / 2)
    local icon_cy = (h > 64) and 34 or 24
    local drew = icons.draw(mod_id, icon_cx, icon_cy, fg, dim, self:mod_icon_state())
    if not drew then return false end

    screen.level(fg)
    screen.font_size(8)

    if value and value ~= "" then
        local title = label or ""
        local val = tostring(value)
        local tw = screen.text_extents(title)
        local vw = screen.text_extents(val)
        local y1 = h - 14
        local y2 = h - 5
        screen.move(math.floor((w - tw) / 2), y1)
        screen.text(title)
        screen.move(math.floor((w - vw) / 2), y2)
        screen.text(val)
    else
        local text = label or ""
        local tw = screen.text_extents(text)
        screen.move(math.floor((w - tw) / 2), h - 10)
        screen.text(text)
    end

    return true
end

function App:is_modifier_dynamic_row_active()
    if self.mod_held[cfg.MOD.OCTAVE] and self.sel_track then return true end
    if self.mod_held[cfg.MOD.TRANSPOSE] then return true end
    if self.mod_held[cfg.MOD.RAND_NOTES] or self.mod_held[cfg.MOD.RAND_STEPS] then return true end
    if self.mod_held[cfg.MOD.BEAT_RPT] then return true end
    if self.mod_held[cfg.MOD.SPICE] then return true end
    if self.mod_held[cfg.MOD.RATIOS] then return true end
    if self.mod_held[cfg.MOD.SHIFT] and self.mod_held[cfg.MOD.RATIOS] then return true end
    if self.speed_mode then return true end
    return false
end

function App:handle_mod_row(x, z)
    if x == cfg.MOD.TAKEOVER and z == 1 then
        if self.mod_held[cfg.MOD.SHIFT] then
            self.realtime_play_mode = not self.realtime_play_mode
            self:clear_realtime_row_holds()
            if self.realtime_play_mode then
                self.takeover_mode = false
            end
            self:flash_mod_applied(cfg.MOD.TAKEOVER, self.realtime_play_mode and "play on" or "play off")
        else
            if not self.sel_track then self.sel_track = 1 end
            self.takeover_mode = not self.takeover_mode
            self:flash_mod_applied(cfg.MOD.TAKEOVER, self.takeover_mode and "on" or "off")
        end
        self:request_redraw()
        return
    end

    if z == 0 and self.mod_shortcut_consumed[x] then
        self.mod_shortcut_consumed[x] = nil
        self:request_redraw()
        return
    end

    if z == 1 then
        if x == cfg.MOD.SPICE and self.mod_held[cfg.MOD.SHIFT] then
            self.mod_shortcut_consumed[x] = true
            self:flash_mod_applied(cfg.MOD.SPICE, self:undo_last_action() and "undo" or "empty")
            self:request_redraw()
            return
        end

        if x == cfg.MOD.BEAT_RPT and self.mod_held[cfg.MOD.SHIFT] then
            self.mod_shortcut_consumed[x] = true
            self:flash_mod_applied(cfg.MOD.BEAT_RPT, self:redo_last_action() and "redo" or "empty")
            self:request_redraw()
            return
        end

        if x == cfg.MOD.TEMP then
            local now = now_ms()
            local use_fill = self:is_temp_button_fill_mode()
            local latched = use_fill and self.fill_latched or self.temp_latched

            if latched then
                if use_fill then
                    self.fill_latched = false
                    self.fill_active = false
                    self.fill_applied = false
                else
                    self.temp_latched = false
                    self:clear_temp_steps()
                end
                self.mod_held[x] = nil
                self.last_mod_pressed = x
                self:flash_mod_applied(x, "off")
                self:request_redraw()
                return
            end

            local last_tap = self.mod_last_tap_time[x] or 0
            if now - last_tap <= self.mod_double_tap_ms then
                if use_fill then
                    self.fill_latched = true
                    self.fill_active = true
                    self.fill_applied = true
                else
                    self.temp_latched = true
                    self.temp_steps = {}
                end
                self.mod_held[x] = nil
                self.mod_last_tap_time[x] = 0
                self.last_mod_pressed = x
                self:flash_mod_applied(x, "latched")
                self:request_redraw()
                return
            end

            self.mod_last_tap_time[x] = now
        end

        if self.mod_held[cfg.MOD.CLEAR] and self.mod_held[cfg.MOD.SHIFT] then
            if x ~= cfg.MOD.CLEAR and x ~= cfg.MOD.SHIFT then
                if x == cfg.MOD.SPICE or x == cfg.MOD.TEMP or x == cfg.MOD.RATIOS then
                    self:push_undo_state()
                end
                self:clear_modifier_all_tracks(x)
            end
        elseif self.mod_held[cfg.MOD.CLEAR] and self.sel_track then
            if x ~= cfg.MOD.CLEAR then
                if x == cfg.MOD.SPICE or x == cfg.MOD.TEMP or x == cfg.MOD.RATIOS then
                    self:push_undo_state()
                end
                self:clear_modifier_for_track(x, self.sel_track)
            end
        end
        self.mod_held[x] = true
        self.last_mod_pressed = x
        if x == cfg.MOD.TEMP then self.temp_steps = {} end
        if x == cfg.MOD.RAND_NOTES then self.rand_notes_rolled = false end
        if x == cfg.MOD.RAND_STEPS then self.rand_steps_shuffled = false end
        if (x == cfg.MOD.START and self.mod_held[cfg.MOD.END_STEP]) or (x == cfg.MOD.END_STEP and self.mod_held[cfg.MOD.START]) then self.speed_mode = true end
        if x == cfg.MOD.TEMP and self:is_temp_button_fill_mode() then
            self.fill_active = true
            self.fill_applied = true
        end
        if x == cfg.MOD.TAKEOVER and self.sel_track then self.takeover_mode = true end
    else
        if x == cfg.MOD.TEMP and not self:is_temp_button_fill_mode() and self.temp_latched then
            self:request_redraw()
            return
        end
        if x == cfg.MOD.TEMP and self:is_temp_button_fill_mode() and self.fill_latched then
            self:request_redraw()
            return
        end

        self.mod_held[x] = nil
        if x == cfg.MOD.TEMP and not self:is_temp_button_fill_mode() then self:clear_temp_steps() end
        if x == cfg.MOD.START or x == cfg.MOD.END_STEP then self.speed_mode = false end
        if x == cfg.MOD.TEMP and self:is_temp_button_fill_mode() then
            self.fill_active = false
            self.fill_applied = self.fill_latched
        end
        if x == cfg.MOD.RAND_NOTES then self.rand_notes_rolled = false end
        if x == cfg.MOD.RAND_STEPS then self.rand_steps_shuffled = false end
        if x == cfg.MOD.BEAT_RPT then
            if self.beat_repeat_mode == "step-select" then
                if not self:is_step_select_repeat_hold_active() then
                    self:clear_step_select_repeat_state()
                end
            else
                self.beat_repeat_len = 0
                self.beat_repeat_excluded = {}
                self:reset_step_select_repeat()
                self.dynamic_row_held = {}
            end
        end
    end
    self:request_redraw()
end

function App:handle_dynamic_row(x, z)
    self.dynamic_row_held = self.dynamic_row_held or {}
    if z == 0 then
        local start_step = tonumber(self.beat_repeat_select_start)
        local end_step = tonumber(self.beat_repeat_select_end)
        self.dynamic_row_held[x] = nil
        if self.beat_repeat_mode == "step-select" and (x == start_step or x == end_step) then
            if not self:is_step_select_repeat_hold_active() then
                self:clear_step_select_repeat_state()
            end
        end
        self:request_redraw()
        return
    end

    if z == 1 then
        self.dynamic_row_held[x] = true
        local should_push_undo = false
        if self.mod_held[cfg.MOD.SHIFT] and self.mod_held[cfg.MOD.RATIOS] then
            should_push_undo = x > 8
        elseif self.mod_held[cfg.MOD.RATIOS] then
            should_push_undo = true
        elseif self.held then
            should_push_undo = true
        end
        if should_push_undo then self:push_undo_state() end

        local applied_value = nil
        local applied_mod = self:get_active_mod_id()

        if self.mod_held[cfg.MOD.SHIFT] and self.mod_held[cfg.MOD.RATIOS] then
            if x <= 8 then
                self:save_to_slot(x)
                applied_value = "save " .. tostring(x)
            else
                self:load_from_slot(x - 8)
                applied_value = "load " .. tostring(x - 8)
            end
        elseif self.mod_held[cfg.MOD.RATIOS] then
            if x <= 8 then
                self:set_ratio_position(x)
            else
                self:set_ratio_cycle(x - 8)
            end
            applied_value = self:get_ratio_label()
        elseif self.mod_held[cfg.MOD.OCTAVE] and self.sel_track then
            self.tracks[self.sel_track].octave = x - 8
            applied_value = tostring(self.tracks[self.sel_track].octave)
        elseif self.mod_held[cfg.MOD.TRANSPOSE] and self.sel_track then
            self.track_transpose[self.sel_track] = x - 8
            applied_value = tostring(self.track_transpose[self.sel_track])
        elseif self.mod_held[cfg.MOD.RAND_NOTES] and not self.mod_held[cfg.MOD.RAND_STEPS] and self.sel_track then
            self:apply_random_notes(self.sel_track, x)
            self.rand_notes_rolled = true
            applied_value = tostring(x)
        elseif self.mod_held[cfg.MOD.RAND_STEPS] and not self.mod_held[cfg.MOD.RAND_NOTES] and self.sel_track then
            self:apply_random_steps(self.sel_track, x)
            self.rand_steps_shuffled = true
            applied_value = tostring(x)
        elseif self.mod_held[cfg.MOD.RAND_NOTES] and self.mod_held[cfg.MOD.RAND_STEPS] and self.sel_track then
            self:apply_random_notes(self.sel_track, x)
            self:apply_random_steps(self.sel_track, x)
            self.rand_notes_rolled = true
            self.rand_steps_shuffled = true
            applied_value = tostring(x)
        elseif self.mod_held[cfg.MOD.BEAT_RPT] then
            if self.beat_repeat_mode == "step-select" then
                local start_step = tonumber(self.beat_repeat_select_start)
                local end_step = tonumber(self.beat_repeat_select_end)
                local start_held = start_step and self.dynamic_row_held[start_step] or false
                if start_step and start_held and x ~= start_step then
                    local next_end = x
                    local is_adjacent = math.abs(x - start_step) == 1
                    if is_adjacent and end_step == x then
                        next_end = start_step
                    end
                    self.beat_repeat_select_end = next_end
                    local _, _, _, len = self:get_step_select_repeat_spec()
                    self.beat_repeat_len = len or 0
                    if self.beat_repeat_select_active then
                        self.beat_repeat_select_cycle = self:get_step_select_repeat_cycle_for_step(self:get_track_step(1))
                        self.beat_repeat_select_armed = false
                    else
                        self.beat_repeat_select_armed = true
                        self.beat_repeat_select_active = false
                        self.beat_repeat_select_cycle = 0
                    end
                    applied_value = tostring(self.beat_repeat_select_start) .. "-" .. tostring(next_end)
                elseif (self.beat_repeat_select_start == nil) or (self.beat_repeat_select_start and self.beat_repeat_select_end) then
                    self.beat_repeat_select_start = x
                    self.beat_repeat_select_end = nil
                    self.beat_repeat_select_armed = false
                    self.beat_repeat_select_active = false
                    self.beat_repeat_select_cycle = 0
                    self.beat_repeat_len = 0
                    applied_value = tostring(x) .. "-?"
                else
                    self.beat_repeat_select_end = x
                    local _, _, _, len = self:get_step_select_repeat_spec()
                    self.beat_repeat_select_armed = true
                    self.beat_repeat_select_active = false
                    self.beat_repeat_select_cycle = 0
                    self.beat_repeat_len = len or 0
                    applied_value = tostring(self.beat_repeat_select_start) .. "-" .. tostring(x)
                end
            else
                local next_len = self:get_beat_repeat_length_for_column(x)
                if next_len then
                    self.beat_repeat_len = (self.beat_repeat_len == next_len) and 0 or next_len
                    applied_value = tostring(self.beat_repeat_len)
                end
            end
        elseif self.speed_mode then
            if self.sel_track then
                local center = 8
                if x == center then
                    self.track_clock_mult[self.sel_track] = 1
                    self.track_clock_div[self.sel_track] = 1
                    applied_value = "1/1"
                elseif x < center then
                    self.track_clock_mult[self.sel_track] = center - x + 1
                    self.track_clock_div[self.sel_track] = 1
                    applied_value = tostring(self.track_clock_mult[self.sel_track]) .. "/1"
                else
                    self.track_clock_mult[self.sel_track] = 1
                    self.track_clock_div[self.sel_track] = x - center + 1
                    applied_value = "1/" .. tostring(self.track_clock_div[self.sel_track])
                end
            end
        elseif self.mod_held[cfg.MOD.SPICE] then
            self.spice_pending_amount = x - 8
            applied_value = tostring(self.spice_pending_amount)
        elseif self.held then
            local tr = self.tracks[self.held.t]
            if self.track_cfg[self.held.t].type == "drum" then
                tr.vels[self.held.s] = x - 1
            elseif self.track_cfg[self.held.t].type == "poly" then
                tr.pitches[self.held.s] = self:poly_toggle_pitch(self:poly_active_pitches(tr, self.held.s), x)
                tr.gates[self.held.s] = (#tr.pitches[self.held.s] > 0)
            else
                tr.pitches[self.held.s] = x
            end
        end
        if applied_mod and (applied_value or self:get_active_mod_value(applied_mod)) then
            self:flash_mod_applied(applied_mod, applied_value or self:get_active_mod_value(applied_mod))
        elseif applied_mod then
            self:flash_mod_applied(applied_mod)
        end
    end
    self:request_redraw()
end

function App:is_main_grid_128()
    local dev = self.main_grid_dev
    local device = dev and dev.device
    return device and device.cols == 16 and device.rows == 8 or false
end

function App:get_main_mod_row()
    return self:is_main_grid_128() and 8 or cfg.MOD_ROW
end

function App:get_main_dynamic_row()
    return self:is_main_grid_128() and 7 or cfg.DYN_ROW
end

function App:get_main_overview_track_rows()
    return self:get_main_dynamic_row() - 1
end

function App:get_main_takeover_note_rows()
    return self:get_main_mod_row() - 1
end

function App:get_main_track_page_start()
    if not self:is_main_grid_128() then return 1 end
    local page_size = self:get_main_overview_track_rows()
    local selected = clamp(tonumber(self.sel_track) or 1, 1, cfg.NUM_TRACKS)
    local start = math.floor((selected - 1) / page_size) * page_size + 1
    return clamp(start, 1, math.max(1, cfg.NUM_TRACKS - page_size + 1))
end

function App:row_to_track(y)
    local visible_rows = self:get_main_overview_track_rows()
    if y < 1 or y > visible_rows then return nil end
    return self:get_main_track_page_start() + (visible_rows - y)
end

function App:track_to_row(t)
    local visible_rows = self:get_main_overview_track_rows()
    local page_start = self:get_main_track_page_start()
    local page_end = math.min(cfg.NUM_TRACKS, page_start + visible_rows - 1)
    if t < page_start or t > page_end then return nil end
    return visible_rows - (t - page_start)
end

function App:main_takeover_row_to_degree(y)
    local rows = self:get_main_takeover_note_rows()
    return clamp(rows - y + 1, 1, rows)
end

function App:main_takeover_row_to_vel_level(y)
    local rows = self:get_main_takeover_note_rows()
    if rows <= 1 then return cfg.DEFAULT_VEL_LEVEL end
    local ratio = (rows - clamp(y, 1, rows)) / (rows - 1)
    return clamp(math.floor((ratio * 14) + 1 + 0.5), 1, 15)
end

function App:vel_level_to_main_takeover_row(level)
    local rows = self:get_main_takeover_note_rows()
    if rows <= 1 then return 1 end
    local stored = clamp(tonumber(level) or cfg.DEFAULT_VEL_LEVEL, 1, 15)
    return clamp(rows - math.floor(((stored - 1) * (rows - 1)) / 14 + 0.5), 1, rows)
end

function App:vel_to_midi(level)
    return clamp(level * 8 + 1, 1, 127)
end

function App:midi_to_vel_level(velocity)
    local midi_vel = clamp(tonumber(velocity) or self:vel_to_midi(cfg.DEFAULT_VEL_LEVEL), 0, 127)
    return clamp(math.floor(((midi_vel - 1) / 8) + 0.5), 1, 15)
end

function App:get_track_default_midi_velocity(track)
    local t = clamp(tonumber(track) or 1, 1, cfg.NUM_TRACKS)
    local fallback = self:vel_to_midi(cfg.DEFAULT_VEL_LEVEL)
    return clamp(tonumber((self.track_default_vel or {})[t]) or fallback, 0, 127)
end

function App:get_track_default_vel_level(track)
    return self:midi_to_vel_level(self:get_track_default_midi_velocity(track))
end

function App:is_aux_grid_device(dev)
    local device = dev and dev.device
    return device
        and device.cols == cfg.AUX_GRID_COLS
        and device.rows == cfg.AUX_GRID_ROWS
end

function App:attach_grid_port(port)
    if not grid or not grid.connect then return nil end
    local dev = grid.connect(port)
    if dev then
        dev.key = function(x, y, z)
            self:handle_grid_key(port, x, y, z)
        end
    end
    self.grid_ports[port] = dev
    return dev
end

function App:get_connected_grid_devices()
    local connected = {}
    for _, dev in pairs(self.grid_ports or {}) do
        if dev and dev.device then
            connected[#connected + 1] = dev
        end
    end
    table.sort(connected, function(a, b)
        return (a.device.port or 0) < (b.device.port or 0)
    end)
    return connected
end

function App:refresh_grid_assignments()
    local connected = self:get_connected_grid_devices()
    local main = nil
    local aux = nil

    if #connected == 1 then
        main = connected[1]
    elseif #connected > 1 then
        if self:is_aux_grid_device(connected[1]) then
            main = connected[1]
        else
            for _, dev in ipairs(connected) do
                if not self:is_aux_grid_device(dev) then
                    main = dev
                    break
                end
            end

            if not main then
                main = connected[1]
            end
        end

        for _, dev in ipairs(connected) do
            if dev ~= main and self:is_aux_grid_device(dev) then
                aux = dev
                break
            end
        end
    end

    self.main_grid_dev = main
    self.aux_grid_dev = aux
    self.main_grid_port = main and main.device and main.device.port or nil
    self.aux_grid_port = aux and aux.device and aux.device.port or nil
    self.grid_dev = self.main_grid_dev
end

function App:handle_grid_key(port, x, y, z)
    if port == self.aux_grid_port then
        self:handle_aux_grid_event(x, y, z)
        return
    end
    if port == self.main_grid_port then
        self:handle_main_grid_event(x, y, z)
    end
end

function App:aux_row_to_degree(y)
    return clamp(cfg.AUX_GRID_ROWS - y + 1, 1, cfg.AUX_GRID_ROWS)
end

function App:degree_to_aux_row(degree)
    local d = clamp(tonumber(degree) or 1, 1, cfg.AUX_GRID_ROWS)
    return cfg.AUX_GRID_ROWS - d + 1
end

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
            if self:get_closest_aux_degree(track, stored_degree) == degree then
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

function App:apply_held_gate_span(track, anchor_step, target_step, preserve_step)
    local t = clamp(tonumber(track) or 1, 1, cfg.NUM_TRACKS)
    local from_step = clamp(tonumber(anchor_step) or 1, 1, cfg.NUM_STEPS)
    local to_step = clamp(tonumber(target_step) or 1, 1, cfg.NUM_STEPS)
    if from_step == to_step then return end

    local tr = self:ensure_track_state(t)
    local tc = self.track_cfg[t]
    if not tr or not tc then return end

    local lo = math.min(from_step, to_step)
    local hi = math.max(from_step, to_step)
    local src_vel = clamp(tonumber(tr.vels[from_step]) or cfg.DEFAULT_VEL_LEVEL, 1, 15)
    local src_pitch = tr.pitches[from_step]

    for s = lo, hi do
        tr.gates[s] = true
        if not tr.ties then tr.ties = {} end
        tr.ties[s] = (s ~= from_step)
        if s ~= preserve_step then
            tr.vels[s] = src_vel
            if tc.type == "poly" then
                if type(src_pitch) == "table" then
                    tr.pitches[s] = deep_copy_table(src_pitch)
                else
                    tr.pitches[s] = { clamp(tonumber(src_pitch) or 1, 1, 16) }
                end
            elseif tc.type ~= "drum" then
                tr.pitches[s] = clamp(tonumber(src_pitch) or 1, 1, 16)
            end
        end
    end
end

function App:get_pitch(track, degree, extra_degrees)
    local scale, mode_root = self:get_mode_scale_and_root()
    local base = cfg.DEFAULT_MELODIC_BASE_NOTE
    base = base + clamp(tonumber(self.key_root) or 0, 0, 11) + mode_root +
        clamp(tonumber(self.track_transpose[track]) or 0, -7, 8)

    local total_degree = degree + (extra_degrees or 0)

    local oct = math.floor((total_degree - 1) / #scale)
    local idx = ((total_degree - 1) % #scale) + 1
    if idx < 1 then
        idx = idx + #scale
        oct = oct - 1
    end

    local note = base + scale[idx] + (oct * 12) + (self.tracks[track].octave * 12)
    return clamp(note, 0, 127)
end

function App:count_manual_ties_ahead(step, tr, step_cache)
    if type(step_cache) ~= "table" then return 0 end
    local order = self:get_track_step_order(tr)
    local idx_of = {}
    for i, ordered_step in ipairs(order) do
        idx_of[ordered_step] = i
    end
    local idx = idx_of[step]
    if not idx then return 0 end

    local tied = 0
    for i = idx + 1, #order do
        local next_step = order[i]
        local next_data = step_cache[next_step]
        if next_data and next_data.source == "manual" and next_data.tie then
            tied = tied + 1
        else
            break
        end
    end
    return tied
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
    self.track_clock_div[t] = clamp(tonumber(self.track_clock_div[t]) or 1, 1, 16)
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
    elseif old_type == "drum" and new_type ~= "drum" then
        self.track_gate_ticks[track] = clamp(tonumber(self.melody_gate_clocks) or 1, 1, 24)
    end

    self:ensure_track_state(track)
    self:request_redraw()
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

function App:main_x_to_realtime_velocity(x)
    local norm = clamp(tonumber(x) or 1, 1, cfg.NUM_STEPS)
    local scaled = 1 + (((norm - 1) / math.max(1, cfg.NUM_STEPS - 1)) * 14)
    return clamp(math.floor(scaled + 0.5), 1, 15)
end

function App:clear_realtime_row_holds(track)
    if track then
        self.realtime_row_holds[track] = {}
        return
    end
    self.realtime_row_holds = {}
end

function App:get_realtime_target_step(track)
    local ts = tonumber(self.track_steps[track]) or 1
    local phase = clamp(tonumber(self.track_clock_phase[track]) or 0, 0, 0.999999)
    local counter = (phase >= 0.5) and ts or (ts - 1)
    return self:get_track_step_from_counter(track, counter)
end

function App:audition_realtime_tap(track, tc, velocity_level, degree)
    local output_ports = self:capture_midi_ports()
    local gate_ticks = clamp(
        tonumber(self.track_gate_ticks[track]) or
        ((tc.type == "drum") and self.drum_gate_clocks or self.melody_gate_clocks),
        1, 24)

    if tc.type == "drum" then
        local note = clamp(tc.note, 0, 127)
        self:midi_note_on(note, self:vel_to_midi(velocity_level), tc.ch, output_ports)
        self:trigger_crow(track, note)
        self:schedule_note_off(track, note, tc.ch, gate_ticks, output_ports)
        return
    end

    local note = self:get_pitch(track, degree, 0)
    self:midi_note_on(note, self:vel_to_midi(clamp(tonumber(velocity_level) or cfg.DEFAULT_VEL_LEVEL, 1, 15)), tc.ch,
        output_ports)
    self:trigger_crow(track, note)
    self:schedule_note_off(track, note, tc.ch, gate_ticks, output_ports)
end

function App:handle_realtime_play_event(track, x, z)
    if z ~= 1 and z ~= 0 then return end
    if not self.playing then return end

    local t = clamp(tonumber(track) or 1, 1, cfg.NUM_TRACKS)
    local step = self:get_realtime_target_step(t)
    local tr = self:ensure_track_state(t)
    local tc = self.track_cfg[t]
    if not tr or not tc or not step then return end

    if not self.realtime_row_holds[t] then self.realtime_row_holds[t] = {} end
    if z == 0 then
        self.realtime_row_holds[t][x] = nil
        return
    end

    self.sel_track = t
    self.realtime_row_holds[t][x] = true

    if tr.ties then tr.ties[step] = false end
    tr.gates[step] = true
    tr.vels[step] = self:get_track_default_vel_level(t)

    if tc.type == "drum" then
        local vel = self:main_x_to_realtime_velocity(x)
        tr.vels[step] = vel
        self:audition_realtime_tap(t, tc, vel, nil)
    elseif tc.type == "poly" then
        local chord = {}
        for held_x, is_on in pairs(self.realtime_row_holds[t]) do
            if is_on then
                chord[#chord + 1] = clamp(tonumber(held_x) or 1, 1, 16)
            end
        end
        table.sort(chord)
        if #chord == 0 then chord[1] = clamp(tonumber(x) or 1, 1, 16) end
        tr.pitches[step] = chord
        self:audition_realtime_tap(t, tc, self:get_track_default_vel_level(t), clamp(tonumber(x) or 1, 1, 16))
    else
        local degree = clamp(tonumber(x) or 1, 1, 16)
        tr.pitches[step] = degree
        self:audition_realtime_tap(t, tc, self:get_track_default_vel_level(t), degree)
    end

    self:request_arc_redraw()
    self:request_redraw()
end

function App:midi_note_on(note, vel, ch, ports)
    self:for_each_midi_device(ports, function(dev)
        dev:note_on(note, vel, ch)
    end)
end

function App:midi_note_off(note, vel, ch, ports)
    self:for_each_midi_device(ports, function(dev)
        dev:note_off(note, vel, ch)
    end)
end

function App:midi_realtime_clock(ports)
    self:for_each_midi_device(ports, function(dev)
        pcall(function() dev:clock() end)
    end)
end

function App:midi_realtime_start(ports)
    self:for_each_midi_device(ports, function(dev)
        pcall(function() dev:start() end)
    end)
end

function App:midi_realtime_stop(ports)
    self:for_each_midi_device(ports, function(dev)
        pcall(function() dev:stop() end)
    end)
end

function App:trigger_crow(track, note)
    if not self.crow_enabled then return end
    local function out(idx)
        if not idx or idx < 1 or idx > 2 then return end
        local volts = (note - 60) / 12
        pcall(function()
            crow.output[idx].volts = volts
            crow.output[idx].action = "{to(5,0),to(0,0.01)}"
            crow.output[idx]()
        end)
    end
    if track == self.crow_track_1 then out(1) end
    if track == self.crow_track_2 then out(2) end
end

function App:schedule_note_off(track, note, ch, delay_ticks, ports)
    self.active_note_offs[#self.active_note_offs + 1] = {
        track = track,
        note = note,
        ch = ch,
        ports = self:capture_midi_ports(ports),
        off_tick = self.transport_clock + math.max(1, tonumber(delay_ticks) or 1)
    }
end

function App:clear_scheduled_note_offs_for_track(track)
    local i = 1
    while i <= #self.active_note_offs do
        if self.active_note_offs[i].track == track then
            table.remove(self.active_note_offs, i)
        else
            i = i + 1
        end
    end
end

function App:process_scheduled_note_offs()
    local i = 1
    while i <= #self.active_note_offs do
        local ev = self.active_note_offs[i]
        if self.transport_clock >= ev.off_tick then
            self:midi_note_off(ev.note, 0, ev.ch, ev.ports)
            table.remove(self.active_note_offs, i)
        else
            i = i + 1
        end
    end
end

function App:note_off_last_for_track(track)
    local prev = self.last_notes[track]
    if not prev then return end
    if prev.note then
        self:midi_note_off(prev.note, 0, prev.ch, prev.ports)
    else
        for _, nd in ipairs(prev) do
            self:midi_note_off(nd.note, 0, nd.ch, nd.ports)
        end
    end
    self.last_notes[track] = nil
    self:clear_scheduled_note_offs_for_track(track)
end

function App:play_tracks(pulse_scale)
    local scale = tonumber(pulse_scale) or 1
    for t = 1, cfg.NUM_TRACKS do
        local tr = self:ensure_track_state(t)
        local tc = self.track_cfg[t]
        local step_cache = self:build_arc_step_cache(t, tr, tc)
        local len = math.abs((tonumber(tr.end_step) or cfg.NUM_STEPS) - (tonumber(tr.start_step) or 1)) + 1
        local mult = self.track_clock_mult[t]
        local div = self.track_clock_div[t]
        local ratio = (mult / div) * scale
        self.track_clock_phase[t] = (tonumber(self.track_clock_phase[t]) or 0) + ratio
        local hits = math.floor(self.track_clock_phase[t])
        if hits > 0 then
            self.track_clock_phase[t] = self.track_clock_phase[t] - hits
        end

        for _ = 1, hits do
            local st = self:get_track_step(t)
            local gate_ticks = clamp(
                tonumber(self.track_gate_ticks[t]) or
                ((tc.type == "drum") and self.drum_gate_clocks or self.melody_gate_clocks), 1, 24)
            local has_fill = self.fill_active and self.fill_patterns[t][st]
            local step_data = step_cache[st]
            local ratio_allows = step_data and self:step_ratio_allows_play(t, st)
            local is_tie_step = step_data and step_data.source == "manual" and step_data.tie and ratio_allows
            local should_play = ((step_data and ratio_allows and (not is_tie_step or not self.last_notes[t])) or has_fill)

            if self.last_notes[t] and not is_tie_step then
                self:note_off_last_for_track(t)
            end

            if not tr.muted and should_play then
                local output_ports = self:capture_midi_ports()
                local note_len_ticks = gate_ticks
                if step_data and step_data.source == "manual" and not step_data.tie and not has_fill then
                    local tied_ahead = self:count_manual_ties_ahead(st, tr, step_cache)
                    if tied_ahead > 0 then
                        note_len_ticks = gate_ticks + (tied_ahead * cfg.MIDI_CLOCK_TICKS_PER_STEP)
                    end
                end
                local vel
                if has_fill and not step_data then
                    vel = self.fill_patterns[t][st].vel
                    if tc.type == "drum" then
                        local note = clamp(tc.note, 0, 127)
                        self:midi_note_on(note, self:vel_to_midi(vel), tc.ch, output_ports)
                        self:trigger_crow(t, note)
                        self:schedule_note_off(t, note, tc.ch, note_len_ticks, output_ports)
                        self.last_notes[t] = { note = note, ch = tc.ch, ports = output_ports }
                    else
                        local note = self:get_pitch(t, self.fill_patterns[t][st].pitch, 0)
                        self:midi_note_on(note, self:vel_to_midi(vel), tc.ch, output_ports)
                        self:trigger_crow(t, note)
                        self:schedule_note_off(t, note, tc.ch, note_len_ticks, output_ports)
                        self.last_notes[t] = { note = note, ch = tc.ch, ports = output_ports }
                    end
                else
                    vel = step_data.vel
                    if tc.type == "drum" then
                        local note = clamp(tc.note, 0, 127)
                        self:midi_note_on(note, self:vel_to_midi(vel), tc.ch, output_ports)
                        self:trigger_crow(t, note)
                        self:schedule_note_off(t, note, tc.ch, note_len_ticks, output_ports)
                        self.last_notes[t] = { note = note, ch = tc.ch, ports = output_ports }
                    elseif tc.type == "poly" then
                        local sp = self.spice[t] and self.spice[t][st]
                        local spice_offset = sp and sp.current or 0
                        local notes = {}
                        local chord = {}
                        for _, d in ipairs(step_data.pitch or {}) do
                            chord[#chord + 1] = self:get_pitch(t, d, spice_offset)
                        end
                        for _, note in ipairs(chord) do
                            self:midi_note_on(note, self:vel_to_midi(vel), tc.ch, output_ports)
                            self:trigger_crow(t, note)
                            self:schedule_note_off(t, note, tc.ch, note_len_ticks, output_ports)
                            notes[#notes + 1] = { note = note, ch = tc.ch, ports = output_ports }
                        end
                        if #notes > 0 then
                            self.last_notes[t] = notes
                        end
                    else
                        local sp = self.spice[t] and self.spice[t][st]
                        local spice_offset = sp and sp.current or 0
                        local note = self:get_pitch(t, step_data.pitch, spice_offset)
                        self:midi_note_on(note, self:vel_to_midi(vel), tc.ch, output_ports)
                        self:trigger_crow(t, note)
                        self:schedule_note_off(t, note, tc.ch, note_len_ticks, output_ports)
                        self.last_notes[t] = { note = note, ch = tc.ch, ports = output_ports }
                    end
                end
            end

            local ts = tonumber(self.track_steps[t]) or 1
            if len > 0 and ts % len == 0 then
                self.track_loop_count[t] = (tonumber(self.track_loop_count[t]) or 1) + 1
            end
            self.track_steps[t] = ts + 1

            local sp = self.spice[t] and self.spice[t][st]
            if sp and sp.amount ~= 0 then
                sp.current = (tonumber(sp.current) or 0) + (tonumber(sp.amount) or 0)
                if sp.current > self.spice_accum_max then
                    sp.current = self.spice_accum_min
                elseif sp.current < self.spice_accum_min then
                    sp.current = self.spice_accum_max
                end
            end
        end
    end
end

function App:update_repeat_window()
    if self.beat_repeat_mode == "step-select" then
        local start_step, _, _, len = self:get_step_select_repeat_spec()
        if not start_step then
            self.beat_repeat_select_armed = false
            self.beat_repeat_select_active = false
            self.beat_repeat_select_cycle = 0
            return 0
        end

        local current_step = self:get_track_step(1)
        if not self.beat_repeat_select_active then
            if self.beat_repeat_select_armed and current_step == start_step then
                self.beat_repeat_select_active = true
                self.beat_repeat_select_armed = false
                self.beat_repeat_select_cycle = 0
            else
                return len
            end
        end

        local target_step = self:get_step_select_repeat_target_step()
        if target_step then
            for t = 1, cfg.NUM_TRACKS do
                if not self.beat_repeat_excluded[t] then
                    self:set_track_counter_to_step(t, target_step)
                end
            end
        end
        return len
    end

    local rpt_len = tonumber(self.beat_repeat_len) or 0
    if rpt_len > 0 then
        if self.beat_repeat_start == 0 then
            self.beat_repeat_start = 1
            self.beat_repeat_cycle = 0
            for t = 1, cfg.NUM_TRACKS do
                self.beat_repeat_anchor[t] = tonumber(self.track_steps[t]) or 1
            end
        end
        for t = 1, cfg.NUM_TRACKS do
            if not self.beat_repeat_excluded[t] then
                local anchor = tonumber(self.beat_repeat_anchor[t]) or (tonumber(self.track_steps[t]) or 1)
                self.track_steps[t] = anchor + (self.beat_repeat_cycle % rpt_len)
            end
        end
    else
        self.beat_repeat_start = 0
        self.beat_repeat_cycle = 0
        self.beat_repeat_anchor = {}
    end
    return rpt_len
end

function App:reset_tracks_to_start_positions()
    for t = 1, cfg.NUM_TRACKS do
        self.track_steps[t] = 1
        self.track_loop_count[t] = 1
    end
    self.step = 1
    self.beat_repeat_start = 0
    self.beat_repeat_cycle = 0
    self.beat_repeat_anchor = {}
    self.beat_repeat_select_armed = false
    self.beat_repeat_select_active = false
    self.beat_repeat_select_cycle = 0
end

function App:advance_clock_tick()
    if not self.use_midi_clock and self.send_midi_clock_out and self.playing then
        self:midi_realtime_clock()
    end

    self.transport_clock = self.transport_clock + 1
    self.clock_ticks = self.clock_ticks + 1

    local step_boundary = false
    if self.clock_ticks >= cfg.MIDI_CLOCK_TICKS_PER_STEP then
        self.clock_ticks = self.clock_ticks - cfg.MIDI_CLOCK_TICKS_PER_STEP
        self:update_repeat_window()
        step_boundary = true
    end

    self:play_tracks(1 / cfg.MIDI_CLOCK_TICKS_PER_STEP)
    self:process_scheduled_note_offs()
    self.grid_dirty = true

    if step_boundary then
        if self.master_seq_len_enabled then
            self.master_seq_counter = (tonumber(self.master_seq_counter) or 0) + 1
            local max_len = clamp(tonumber(self.master_seq_len) or cfg.DEFAULT_MASTER_SEQ_LEN, 1, cfg.MAX_MASTER_SEQ_LEN)
            if self.master_seq_counter >= max_len then
                self.master_seq_counter = 0
                self:reset_tracks_to_start_positions()
            end
        end

        if self.beat_repeat_mode == "step-select" then
            if self.beat_repeat_select_active then
                self.beat_repeat_select_cycle = (tonumber(self.beat_repeat_select_cycle) or 0) + 1
            end
        elseif self.beat_repeat_len > 0 then
            self.beat_repeat_cycle = self.beat_repeat_cycle + 1
        end
        self.step = self:get_track_step(1)
        self:request_redraw()
    end
end

function App:tick()
    if not self.playing then return end
    for _ = 1, cfg.MIDI_CLOCK_TICKS_PER_STEP do
        self:advance_clock_tick()
    end
end

function App:stop_all_notes()
    for _, data in pairs(self.last_notes) do
        if data.note then
            self:midi_note_off(data.note, 0, data.ch, data.ports)
        else
            for _, nd in ipairs(data) do
                self:midi_note_off(nd.note, 0, nd.ch, nd.ports)
            end
        end
    end
    self.last_notes = {}
    self.active_note_offs = {}
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
            clock_div = clamp(tonumber(self.track_clock_div[t]) or 1, 1, 16),
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
        self.track_clock_div[t] = clamp(tonumber(sm.clock_div) or self.track_clock_div[t] or 1, 1, 16)
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
    self:request_arc_redraw()
    self:request_redraw()
end

function App:clear_temp_steps()
    for t, steps in pairs(self.temp_steps) do
        for s, _ in pairs(steps) do
            self.tracks[t].gates[s] = false
            self.tracks[t].vels[s] = self:get_track_default_vel_level(t)
            if self.track_cfg[t].type == "poly" then self.tracks[t].pitches[s] = { 1 } else self.tracks[t].pitches[s] = 1 end
        end
    end
    self.temp_steps = {}
end

function App:add_temp_step(track, step)
    if not self.temp_steps[track] then self.temp_steps[track] = {} end
    self.temp_steps[track][step] = true
end

function App:update_solo()
    local any_solo = false
    for t = 1, cfg.NUM_TRACKS do
        if self.tracks[t].solo then
            any_solo = true
            break
        end
    end
    for t = 1, cfg.NUM_TRACKS do
        if any_solo then self.tracks[t].muted = not self.tracks[t].solo else self.tracks[t].muted = false end
    end
end

function App:clear_track(t)
    for s = 1, cfg.NUM_STEPS do
        self.tracks[t].gates[s] = false
        if self.track_cfg[t].type == "poly" then self.tracks[t].pitches[s] = { 1 } else self.tracks[t].pitches[s] = 1 end
        self.tracks[t].vels[s] = self:get_track_default_vel_level(t)
    end
    self.fill_patterns[t] = {}
    self.ratios[t] = {}
    self.spice[t] = {}
    self.tracks[t].arc = { pulses = 0, rotation = 1, variance = 0, mode = 1 }
end

function App:clear_all_tracks()
    for t = 1, cfg.NUM_TRACKS do self:clear_track(t) end
end

function App:clear_modifier_for_track(mod, t)
    if mod == cfg.MOD.MUTE then
        self.tracks[t].muted = false
    elseif mod == cfg.MOD.SOLO then
        self.tracks[t].solo = false
        self:update_solo()
    elseif mod == cfg.MOD.START then
        self.tracks[t].start_step = 1
    elseif mod == cfg.MOD.END_STEP then
        self.tracks[t].end_step = 16
    elseif mod == cfg.MOD.OCTAVE then
        self.tracks[t].octave = 0
    elseif mod == cfg.MOD.TRANSPOSE then
        self.track_transpose[t] = 0
    elseif mod == cfg.MOD.SPICE then
        self.spice[t] = {}
    elseif mod == cfg.MOD.TEMP and self:is_temp_button_fill_mode() then
        self.fill_patterns[t] = {}
    elseif mod == cfg.MOD.RATIOS then
        self.ratios[t] = {}
    end
end

function App:clear_modifier_all_tracks(mod)
    for t = 1, cfg.NUM_TRACKS do
        self:clear_modifier_for_track(mod, t)
    end
end

function App:draw_dynamic_row()
    local dyn_row = self:get_main_dynamic_row()
    if self.held and not self:any_mod_active() and not self.takeover_mode then
        local tr = self.tracks[self.held.t]
        if self.track_cfg[self.held.t].type == "drum" then
            local v = tr.vels[self.held.s]
            for x = 1, 16 do self:grid_led(x, dyn_row, (x - 1) <= v and 10 or 2) end
        else
            local p = tr.pitches[self.held.s]
            local scale = cfg.SCALES[self.scale_type] or cfg.SCALES.chromatic
            for x = 1, 16 do
                local is_root = ((x - 1) % #scale) == 0
                local is_on = false
                if self.track_cfg[self.held.t].type == "poly" then is_on = self:poly_has_pitch(p, x) else is_on = (x == p) end
                if is_on then
                    self:grid_led(x, dyn_row, 15)
                elseif is_root then
                    self:grid_led(x, dyn_row, 5)
                else
                    self:grid_led(x, dyn_row, 2)
                end
            end
        end
        return
    end

    if self.mod_held[cfg.MOD.OCTAVE] and self.sel_track then
        local oct = self.tracks[self.sel_track].octave
        for x = 1, 16 do
            local o = x - 8
            if o == oct then
                self:grid_led(x, dyn_row, 15)
            elseif x == 8 then
                self:grid_led(x, dyn_row, 5)
            else
                self:grid_led(x, dyn_row, 2)
            end
        end
        return
    end

    if self.mod_held[cfg.MOD.TRANSPOSE] then
        local trans = clamp(tonumber(self.track_transpose[self.sel_track or 1]) or 0, -7, 8)
        for x = 1, 16 do
            local o = x - 8
            if o == trans then
                self:grid_led(x, dyn_row, 15)
            elseif x == 8 then
                self:grid_led(x, dyn_row, 5)
            else
                self:grid_led(x, dyn_row, 2)
            end
        end
        return
    end

    if self.mod_held[cfg.MOD.RAND_NOTES] or self.mod_held[cfg.MOD.RAND_STEPS] then
        for x = 1, 16 do self:grid_led(x, dyn_row, 2) end
        return
    end

    if self.mod_held[cfg.MOD.BEAT_RPT] then
        local rpt_len = tonumber(self.beat_repeat_len) or 0
        if self.beat_repeat_mode == "step-select" then
            local start_step = tonumber(self.beat_repeat_select_start)
            local end_step = tonumber(self.beat_repeat_select_end)
            local lo = nil
            local hi = nil
            if start_step and end_step then
                lo = math.min(start_step, end_step)
                hi = math.max(start_step, end_step)
            end
            local active_step = self.beat_repeat_select_active and self:get_step_select_repeat_target_step() or nil
            for x = 1, 16 do
                local lv = 2
                if lo and hi and x >= lo and x <= hi then lv = 6 end
                if x == end_step then lv = 10 end
                if x == start_step then lv = 15 end
                if active_step and x == active_step then lv = 12 end
                self:grid_led(x, dyn_row, lv)
            end
        elseif self.beat_repeat_mode == "one-handed" then
            for x = 1, 16 do self:grid_led(x, dyn_row, 1) end
            for _, col in ipairs({ 13, 14, 15, 16 }) do
                self:grid_led(col, dyn_row, self:get_beat_repeat_column_for_length(rpt_len) == col and 10 or 3)
            end
        else
            for x = 1, 16 do
                self:grid_led(x, dyn_row, self:get_beat_repeat_length_for_column(x) <= rpt_len and 10 or 2)
            end
        end
        return
    end

    if self.mod_held[cfg.MOD.SPICE] then
        local amt = self.spice_pending_amount or 0
        for x = 1, 16 do
            local center = 8
            local sel = amt + 8
            if amt ~= 0 then
                if (amt > 0 and x >= center and x <= sel) or (amt < 0 and x <= center and x >= sel) then
                    self:grid_led(x, dyn_row, 10)
                elseif x == center then
                    self:grid_led(x, dyn_row, 5)
                else
                    self:grid_led(x, dyn_row, 2)
                end
            else
                if x == center then self:grid_led(x, dyn_row, 5) else self:grid_led(x, dyn_row, 2) end
            end
        end
        return
    end

    if self.mod_held[cfg.MOD.SHIFT] and self.mod_held[cfg.MOD.RATIOS] then
        for x = 1, 16 do
            if x <= 8 then
                self:grid_led(x, dyn_row, self.save_slots[x] and 8 or 3)
            else
                self:grid_led(x, dyn_row, self.save_slots[x - 8] and 12 or 2)
            end
        end
        return
    end

    if self.mod_held[cfg.MOD.RATIOS] then
        for x = 1, 16 do
            if x <= 8 then
                if x <= self.ratio_pending_cycle then
                    self:grid_led(x, dyn_row, x == self.ratio_pending_position and 12 or 3)
                else
                    self:grid_led(x, dyn_row, 1)
                end
            else
                local cycle = x - 8
                self:grid_led(x, dyn_row, cycle == self.ratio_pending_cycle and 15 or 3)
            end
        end
        return
    end

    if self.speed_mode then
        local center = 8
        local mult = self.sel_track and self.track_clock_mult[self.sel_track] or 1
        local div = self.sel_track and self.track_clock_div[self.sel_track] or 1
        for x = 1, 16 do
            if x == center then
                self:grid_led(x, dyn_row, 15)
            elseif x < center then
                local m = center - x + 1
                self:grid_led(x, dyn_row, (self.sel_track and div == 1 and mult == m) and 12 or 3)
            else
                local d = x - center + 1
                self:grid_led(x, dyn_row, (self.sel_track and mult == 1 and div == d) and 12 or 3)
            end
        end
        return
    end
end

function App:draw_mod_row()
    local mod_row = self:get_main_mod_row()
    for x = 1, 16 do
        local lv = 0
        if self:mod_active(x) then
            lv = 15
        elseif x == cfg.MOD.TAKEOVER then
            lv = self.realtime_play_mode and 12 or (self.takeover_mode and 15 or 3)
        elseif x == cfg.MOD.BEAT_RPT then
            lv = (tonumber(self.beat_repeat_len) or 0) > 0 and 10 or 3
        elseif x == cfg.MOD.SHIFT or x == cfg.MOD.CLEAR then
            lv = 0
        elseif x ~= 5 then
            lv = 3
        end
        if lv > 0 then self:grid_led(x, mod_row, lv) end
    end
end

function App:draw_takeover()
    local tr = self:ensure_track_state(self.sel_track)
    local tc = self.track_cfg[self.sel_track]
    local step_cache = self:build_arc_step_cache(self.sel_track, tr, tc)
    local fills = self.fill_patterns[self.sel_track] or {}
    local current_step = self:get_track_step(self.sel_track)
    local takeover_rows = self:get_main_takeover_note_rows()

    local lo, hi = self:get_track_bounds(tr)

    if tc.type == "drum" then
        for s = 1, cfg.NUM_STEPS do
            local in_range = s >= lo and s <= hi
            local fill = fills[s]
            local step_data = step_cache[s]
            if in_range and self:is_beat_column(s) then
                for row = 1, takeover_rows do
                    self:grid_led(s, row, 2)
                end
            end
            if step_data then
                local top_row = self:vel_level_to_main_takeover_row(step_data.vel)
                local manual = step_data.source == "manual"
                local lv = manual and ((s == current_step and self.playing) and 15 or 10)
                    or ((s == current_step and self.playing) and 11 or 7)
                if not in_range then lv = math.floor(lv / 2) end
                for row = top_row, takeover_rows do
                    self:grid_led(s, row, lv)
                end
            elseif fill then
                local row = self:vel_level_to_main_takeover_row(fill.vel)
                local lv = (s == current_step and self.playing) and 12 or 6
                if not in_range then lv = math.floor(lv / 2) end
                self:grid_led(s, row, lv)
                self:grid_led(s, takeover_rows, math.max((s == current_step and self.playing) and 4 or 1, 3))
            else
                if s == current_step and self.playing then
                    self:grid_led(s, takeover_rows, 4)
                elseif in_range then
                    self
                        :grid_led(s, takeover_rows, 1)
                end
            end
        end
    else
        local scale = cfg.SCALES[self.scale_type] or cfg.SCALES.chromatic
        for s = 1, cfg.NUM_STEPS do
            local is_playhead = (s == current_step and self.playing)
            local in_range = s >= lo and s <= hi
            local fill = fills[s]
            local fill_degree = fill and clamp(tonumber(fill.pitch) or 1, 1, takeover_rows) or nil
            local step_data = step_cache[s]
            if (not self.realtime_play_mode) and in_range and self:is_beat_column(s) then
                for row = 1, takeover_rows do
                    self:grid_led(s, row, 2)
                end
            end
            for row = 1, takeover_rows do
                local degree = self:main_takeover_row_to_degree(row)
                local is_root = ((degree - 1) % #scale) == 0
                local is_on = false
                local is_fill = false
                if step_data then
                    if tc.type == "poly" then
                        is_on = self:poly_has_pitch(step_data.pitch, degree)
                    else
                        is_on = clamp(
                            tonumber(step_data.pitch) or 1, 1, takeover_rows) == degree
                    end
                elseif fill_degree then
                    is_fill = degree == fill_degree
                end
                if is_on then
                    local manual = step_data.source == "manual"
                    local lv = manual and (is_playhead and 15 or 12) or (is_playhead and 11 or 7)
                    if not in_range then lv = math.floor(lv / 2) end
                    self:grid_led(s, row, lv)
                elseif is_fill then
                    local lv = is_playhead and 12 or 6
                    if not in_range then lv = math.floor(lv / 2) end
                    self:grid_led(s, row, lv)
                elseif is_root and in_range then
                    self:grid_led(s, row, 2)
                elseif is_playhead then
                    self:grid_led(s, row, 1)
                end
            end
        end
    end

    self:grid_led(cfg.MOD.TAKEOVER, self:get_main_mod_row(), 15)
end

function App:redraw_main_grid()
    local dev = self.main_grid_dev
    if not dev then return end

    dev:all(0)
    if self.takeover_mode and self.sel_track then
        self:draw_takeover()
        if self:is_modifier_dynamic_row_active() and not self:is_main_grid_128() then
            self:draw_dynamic_row()
        end
        self:draw_mod_row()
    else
        local page_start = self:get_main_track_page_start()
        local page_end = math.min(cfg.NUM_TRACKS, page_start + self:get_main_overview_track_rows() - 1)
        for t = page_start, page_end do
            local y = self:track_to_row(t)
            local tr = self:ensure_track_state(t)
            local tc = self.track_cfg[t]
            local scale = cfg.SCALES[self.scale_type] or cfg.SCALES.chromatic
            local scale_len = math.max(1, #scale)
            local step_cache = self:build_arc_step_cache(t, tr, tc)
            local track_playhead = self:get_track_step(t)
            local lo, hi = self:get_track_bounds(tr)
            local in_range_fn = function(s)
                return s >= lo and s <= hi
            end

            for s = 1, cfg.NUM_STEPS do
                local lv = 0
                local is_playhead = (s == track_playhead and self.playing)
                local in_range = in_range_fn(s)
                local step_data = step_cache[s]
                local has_manual = tr.gates[s]
                local has_arc = step_data and step_data.source == "arc"

                if self.realtime_play_mode and tc.type ~= "drum" and (((s - 1) % scale_len) == 0) then
                    lv = 2
                elseif (not self.realtime_play_mode) and (s == 1 or s == 5 or s == 9 or s == 13) then
                    lv = 2
                end
                if has_manual then
                    lv = 10
                elseif has_arc then
                    lv = 6
                end
                if self.fill_patterns[t][s] then lv = math.max(lv, 5) end
                if tr.muted then lv = math.floor(lv / 3) end

                if (self.mod_held[cfg.MOD.MUTE] or self.mod_held[cfg.MOD.SOLO]) and s == 1 then lv = tr.muted and 2 or 10 end
                if self.mod_held[cfg.MOD.START] and s == tr.start_step then lv = math.max(lv, 8) end
                if self.mod_held[cfg.MOD.END_STEP] and s == tr.end_step then lv = math.max(lv, 8) end
                if not in_range then lv = math.floor(lv / 2) end
                if self.sel_track == t then lv = math.max(lv, 2) end
                if self.spice[t][s] then lv = math.max(lv, 4) end

                if is_playhead then
                    if in_range then lv = math.max(lv + 2, 6) else lv = math.max(lv, 3) end
                end

                if lv > 0 then dev:led(s, y, lv) end
            end
        end
        self:draw_dynamic_row()
        self:draw_mod_row()
    end

    dev:refresh()
end

function App:redraw_aux_grid()
    local dev = self.aux_grid_dev
    if not dev then return end

    dev:all(0)

    if not self.sel_track then
        dev:refresh()
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
                    self:grid_led(dev, s, row, 2)
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
                    self:grid_led(dev, s, row, lv)
                end
            elseif in_range or is_playhead then
                self:grid_led(dev, s, cfg.AUX_GRID_ROWS, is_playhead and 2 or 1)
            end
        end
    else
        for s = 1, cfg.NUM_STEPS do
            local in_range = s >= lo and s <= hi
            local is_playhead = (s == current_step and self.playing)
            local fill = fills[s]
            local fill_degree = fill and self:get_closest_aux_degree(t, fill.pitch) or nil
            local fill_above = fill and self:is_aux_degree_above_visible_octave(t, fill.pitch) or false
            local step_data = step_cache[s]

            if (not self.realtime_play_mode) and in_range and self:is_beat_column(s) then
                for row = 1, cfg.AUX_GRID_ROWS do
                    self:grid_led(dev, s, row, 2)
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
                            if self:get_closest_aux_degree(t, stored_degree) == degree then
                                is_on = true
                                is_above = self:is_aux_degree_above_visible_octave(t, stored_degree)
                                break
                            end
                        end
                    else
                        is_on = self:get_closest_aux_degree(t, step_data.pitch) == degree
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
                    self:grid_led(dev, s, row, lv)
                elseif is_fill then
                    local lv = is_above and ((is_playhead and 6) or 4) or ((is_playhead and 10) or 6)
                    if not in_range then lv = math.max(1, math.floor(lv / 2)) end
                    self:grid_led(dev, s, row, lv)
                elseif is_root and in_range then
                    self:grid_led(dev, s, row, 2)
                elseif is_playhead and in_range then
                    self:grid_led(dev, s, row, 1)
                end
            end
        end
    end

    dev:refresh()
end

function App:redraw_grid(force)
    if not self.main_grid_dev and not self.aux_grid_dev then return end
    if not force then
        local now = now_ms()
        if self.playing and self.use_midi_clock and (now - (self.last_redraw_time or 0) < self.redraw_min_ms) then
            self.redraw_deferred = true
            return
        end
    end

    self:redraw_main_grid()
    self:redraw_aux_grid()
    self.last_redraw_time = now_ms()
    self.redraw_deferred = false
end

function App:get_arc_led_index(pos, len)
    if len <= 0 then return 1 end
    return clamp(math.floor(((pos - 1) * 64) / len) + 1, 1, 64)
end

function App:redraw_arc()
    local dev = self.arc_dev
    if not dev then return end

    dev:all(0)

    if not self.sel_track then
        dev:refresh()
        return
    end

    local t = clamp(tonumber(self.sel_track) or 1, 1, cfg.NUM_TRACKS)
    local tr = self:ensure_track_state(t)
    local arc_state = self:get_arc_state(t)
    local order, active = self:get_arc_pattern(t)
    local len = #order

    if len > 0 then
        for idx, step in ipairs(order) do
            local led = self:get_arc_led_index(idx, len)
            dev:led(1, led, active[step] and 12 or 3)
            dev:led(2, led, 3)
        end

        local rotation_led = self:get_arc_led_index(self:wrap_arc_index((arc_state.rotation or 1) - 1, len), len)
        dev:led(2, rotation_led, 15)
    end

    local variance_fill = clamp(math.floor(((arc_state.variance or 0) / 100) * 64 + 0.5), 0, 64)
    for led = 1, 64 do
        dev:led(3, led, led <= variance_fill and 12 or 2)
    end

    local modes = #ARC_VARIANCE_MODES
    for idx = 1, modes do
        local start_led = math.floor(((idx - 1) * 64) / modes) + 1
        local end_led = math.floor((idx * 64) / modes)
        local level = (idx == arc_state.mode) and 12 or 3
        for led = start_led, end_led do
            dev:led(4, led, level)
        end
    end

    dev:refresh()
end

function App:begin_arc_history_snapshot()
    local now = now_ms()
    if now - (self.arc_last_history_at or 0) > 0.25 * 1000 then
        self:push_undo_state()
        self.arc_last_history_at = now
    end
end

function App:consume_arc_delta(knob, delta, threshold)
    local accum = (self.arc_delta_accum[knob] or 0) + delta
    local steps = 0

    while math.abs(accum) >= threshold do
        if accum > 0 then
            steps = steps + 1
            accum = accum - threshold
        else
            steps = steps - 1
            accum = accum + threshold
        end
    end

    self.arc_delta_accum[knob] = accum
    return steps
end

function App:handle_arc_delta(n, d)
    if n < 1 or n > 4 or d == 0 then return end
    if not self.sel_track then self.sel_track = 1 end

    local t = clamp(tonumber(self.sel_track) or 1, 1, cfg.NUM_TRACKS)
    local tr = self:ensure_track_state(t)
    local arc_state = self:get_arc_state(t)
    if not tr or not arc_state then return end

    local span_len = #self:get_track_step_order(tr)
    local changed = false
    local label = nil
    local value = nil

    if n == 1 then
        local steps = self:consume_arc_delta(n, d, self.arc_delta_thresholds[1] or ARC_DELTA_THRESHOLDS[1])
        if steps ~= 0 then
            self:begin_arc_history_snapshot()
            local next_pulses = clamp((arc_state.pulses or 0) + steps, 0, span_len)
            if next_pulses ~= arc_state.pulses then
                arc_state.pulses = next_pulses
                changed = true
                label = "arc pulses"
                value = tostring(next_pulses)
            end
        end
    elseif n == 2 then
        local steps = self:consume_arc_delta(n, d, self.arc_delta_thresholds[2] or ARC_DELTA_THRESHOLDS[2])
        if steps ~= 0 then
            self:begin_arc_history_snapshot()
            arc_state.rotation = math.floor((arc_state.rotation or 1) + steps)
            changed = true
            label = "arc rotate"
            value = tostring(self:wrap_arc_index((arc_state.rotation or 1) - 1, math.max(1, span_len)))
        end
    elseif n == 3 then
        local steps = self:consume_arc_delta(n, d, self.arc_delta_thresholds[3] or ARC_DELTA_THRESHOLDS[3])
        if steps ~= 0 then
            self:begin_arc_history_snapshot()
            local next_variance = clamp((arc_state.variance or 0) + steps, 0, 100)
            if next_variance ~= arc_state.variance then
                arc_state.variance = next_variance
                changed = true
                label = "arc variance"
                value = tostring(next_variance) .. "%"
            end
        end
    elseif n == 4 then
        local steps = self:consume_arc_delta(n, d, self.arc_delta_thresholds[4] or ARC_DELTA_THRESHOLDS[4])
        if steps ~= 0 then
            self:begin_arc_history_snapshot()
            local next_mode = clamp((arc_state.mode or 1) + steps, 1, #ARC_VARIANCE_MODES)
            if next_mode ~= arc_state.mode then
                arc_state.mode = next_mode
                changed = true
                label = "arc mode"
                value = self:get_arc_mode_name(next_mode)
            end
        end
    end

    if changed then
        if label and value then self:flash_status(label, value, 0.3) end
        self:request_arc_redraw()
        self:request_redraw()
    end
end

function App:connect_arc()
    if not arc or not arc.connect then return end
    local dev = arc.connect()
    if not dev then return end
    self.arc_dev = dev
    dev.delta = function(n, d)
        self:handle_arc_delta(n, d)
    end
    self:request_arc_redraw()
end

function App:grid_led(a, b, c, d)
    local dev = self.main_grid_dev
    local x = a
    local y = b
    local l = c

    if d ~= nil then
        dev = a
        x = b
        y = c
        l = d
    end

    if dev then dev:led(x, y, l) end
end

function App:request_arc_redraw()
    self.arc_dirty = true
end

function App:request_redraw()
    self.screen_dirty = true
    self.grid_dirty = true
    if not self.playing then self.arc_dirty = true end
    if not self:is_menu_active() then
        redraw()
    end
end

function App:note_label(note)
    if musicutil and musicutil.note_num_to_name then
        return musicutil.note_num_to_name(clamp(note, 0, 127), true)
    end
    return tostring(note)
end

function App:apply_screen_update()
    screen.update()
end

function App:redraw_screen_cw90(now, active_mod_name)
    local live_main = self.realtime_play_mode
    if live_main then
        screen.level(15)
        screen.rect(0, 0, 128, 64)
        screen.fill()
    end

    local fg = live_main and 0 or 15
    local dim = live_main and 4 or 6
    screen.font_size(8)
    local col = 7
    local top_pad = 3
    local function row(text, level)
        local str = text or ""
        screen.level(live_main and 0 or (level or 15))
        screen.text_rotate(col, top_pad, str, 90)
        col = col + 10
    end

    local function draw_rotated_icon(draw_fn)
        if not draw_fn then return end
        if screen.save and screen.restore and screen.translate and screen.rotate then
            screen.save()
            screen.translate(108, 32)
            screen.rotate(math.rad(90))
            draw_fn(0, 0)
            screen.restore()
        else
            draw_fn(108, 32)
        end
    end

    local title = self.realtime_play_mode and "permute - live (cw90)" or "permute - cw90"
    row(title, 15)

    if self.status_message then
        local override_name, _, _ = self:get_mod_screen_override()
        if override_name then
            draw_rotated_icon(function(cx, cy)
                icons.draw_special(override_name, cx, cy, fg, dim, self:mod_icon_state())
            end)
        else
            local mod_id = self.status_mod_id or self:mod_id_from_name(self.status_message)
            if mod_id then
                draw_rotated_icon(function(cx, cy)
                    icons.draw(mod_id, cx, cy, fg, dim, self:mod_icon_state())
                end)
            end
        end
        row("status: " .. tostring(self.status_message), 12)
        if self.status_value then row("value: " .. tostring(self.status_value), 10) end
    elseif active_mod_name then
        local active_mod_id = self:get_active_mod_id()
        local mod_value = self:get_active_mod_value(active_mod_id)
        if active_mod_id then
            draw_rotated_icon(function(cx, cy)
                icons.draw(active_mod_id, cx, cy, fg, dim, self:mod_icon_state())
            end)
        end
        row("mod: " .. tostring(active_mod_name), 12)
        if mod_value ~= nil then row("value: " .. tostring(mod_value), 10) end
    elseif self.held then
        local t = self.held.t
        local s = self.held.s
        local tr = self.tracks[t]
        local tc = self.track_cfg[t]
        row("hold T" .. tostring(t) .. " S" .. tostring(s), 12)
        row("ch: " .. tostring(tc.ch), 10)
        if tc.type == "drum" then
            row("vel: " .. tostring(tr.vels[s]), 10)
        elseif tc.type == "poly" then
            local labels = {}
            for _, d in ipairs(tr.pitches[s]) do
                local n = self:get_pitch(t, d, 0)
                labels[#labels + 1] = self:note_label(n)
            end
            row("notes:", 10)
            row(table.concat(labels, " "), 10)
        else
            local degree = tr.pitches[s]
            local n = self:get_pitch(t, degree, 0)
            row("pitch: " .. tostring(degree), 10)
            row(self:note_label(n), 10)
        end
    else
        row("state: " .. (self.playing and "playing" or "stopped"), 10)
        row("tempo: " .. string.format("%d", self.tempo_bpm), 10)
        row("scale: " .. tostring(self.scale_type), 10)
        local sel = self.sel_track and tostring(self.sel_track) or "-"
        row("track: " .. sel, 10)
        row("clock: " .. (self.use_midi_clock and "midi" or "internal"), 10)
    end
end

function App:redraw_screen()
    if self:is_menu_active() then
        self:reset_screen_transform()
        return
    end
    self:apply_screen_transform()
    local screen_orientation = self:get_active_screen_orientation()
    self.screen_orientation = screen_orientation
    local now = util.time() or 0
    local active_mod_name = self:get_active_mod_name()
    local w, h = self:get_screen_canvas_size()

    if self.status_message and now > self.status_message_until then
        self.status_message = nil
        self.status_value = nil
        self.status_mod_id = nil
        self.status_message_invert = false
    end

    screen.clear()
    if screen_orientation == "cw90" then
        self:redraw_screen_cw90(now, active_mod_name)
        self:apply_screen_update()
        self.screen_dirty = false
        return
    end

    if self.status_message then
        local override_name, override_label, _ = self:get_mod_screen_override()
        if override_name then
            if not self:draw_special_icon_screen(override_name, override_label, self.status_value, self.status_message_invert) then
                self:draw_big_center_text(override_label, self.status_value, self.status_message_invert)
            end
            self:apply_screen_update()
            self.screen_dirty = false
            return
        end

        local mod_id = self.status_mod_id or self:mod_id_from_name(self.status_message)
        if not self:draw_mod_icon_screen(mod_id, self.status_message, self.status_value, self.status_message_invert) then
            self:draw_big_center_text(self.status_message, self.status_value, self.status_message_invert)
        end
    elseif active_mod_name then
        local override_name, override_label, override_value = self:get_mod_screen_override()
        if override_name then
            if not self:draw_special_icon_screen(override_name, override_label, override_value, false) then
                self:draw_big_center_text(override_label, override_value, false)
            end
            self:apply_screen_update()
            self.screen_dirty = false
            return
        end

        local active_mod_id = self:get_active_mod_id()
        local mod_value = self:get_active_mod_value(active_mod_id)
        if not self:draw_mod_icon_screen(active_mod_id, active_mod_name, mod_value, false) then
            self:draw_big_center_text(active_mod_name, mod_value, false)
        end
    elseif self.held then
        local t = self.held.t
        local s = self.held.s
        local tr = self.tracks[t]
        local tc = self.track_cfg[t]
        screen.level(15)
        screen.move(0, 12)
        screen.text("hold T" .. tostring(t) .. " S" .. tostring(s))
        screen.level(10)
        screen.move(0, 22)
        screen.text("midi ch: " .. tostring(tc.ch))
        if tc.type == "drum" then
            screen.level(12)
            screen.move(0, 32)
            screen.text("velocity: " .. tostring(tr.vels[s]))
        elseif tc.type == "poly" then
            local labels = {}
            for _, d in ipairs(tr.pitches[s]) do
                local n = self:get_pitch(t, d, 0)
                labels[#labels + 1] = self:note_label(n)
            end
            screen.level(12)
            screen.move(0, 32)
            screen.text("notes:")
            screen.move(0, 46)
            screen.text(table.concat(labels, " "))
        else
            local degree = tr.pitches[s]
            local n = self:get_pitch(t, degree, 0)
            screen.level(12)
            screen.move(0, 32)
            screen.text("pitch: " .. tostring(degree))
            screen.move(0, 46)
            screen.text(self:note_label(n))
        end
    else
        local live_main = self.realtime_play_mode
        if live_main then
            screen.level(15)
            screen.rect(0, 0, w, h)
            screen.fill()
            screen.level(0)
        else
            screen.level(15)
        end
        if self.screen_orientation == "cw90" then
            local y1, y2, y3, y4, y5, y6 = 10, 20, 30, 40, 50, 60
            screen.move(0, y1)
            screen.text(self.realtime_play_mode and "permute - live" or "permute")
            screen.level(live_main and 0 or 10)
            screen.move(0, y2)
            screen.text("state: " .. (self.playing and "playing" or "stopped"))
            screen.move(0, y3)
            screen.text("tempo: " .. string.format("%d", self.tempo_bpm))
            screen.move(0, y4)
            screen.text("scale: " .. self.scale_type)
            screen.move(0, y5)
            local sel = self.sel_track and tostring(self.sel_track) or "-"
            screen.text("track: " .. sel)
            screen.move(0, y6)
            screen.text("clock: " .. (self.use_midi_clock and "midi" or "internal"))
        else
            local y1, y2, y3, y4, y5 = 12, 24, 34, 44, 54
            screen.move(0, y1)
            screen.text(self.realtime_play_mode and "permute - live" or "permute")

            screen.level(live_main and 0 or 10)
            screen.move(0, y2)
            screen.text("state: " .. (self.playing and "playing" or "stopped"))

            screen.move(0, y3)
            screen.text("tempo: " .. string.format("%d", self.tempo_bpm) .. "  scale: " .. self.scale_type)

            screen.move(0, y4)
            local sel = self.sel_track and tostring(self.sel_track) or "-"
            screen.text("track: " .. sel)

            screen.move(0, y5)
            screen.text("clock: " .. (self.use_midi_clock and "midi" or "internal"))
        end
    end

    self:apply_screen_update()
    self.screen_dirty = false
end

function App:handle_aux_grid_event(x, y, z)
    if not self.aux_grid_dev then return end
    if x < 1 or x > cfg.NUM_STEPS or y < 1 or y > cfg.AUX_GRID_ROWS then return end

    local t = clamp(tonumber(self.sel_track) or 1, 1, cfg.NUM_TRACKS)
    self.sel_track = t

    local tr = self:ensure_track_state(t)
    local tc = self.track_cfg[t]
    local prev_held = self.held

    if z == 0 then
        if self.held and self.held.aux and self.held.t == t and self.held.s == x then
            self.held = nil
        end
        return
    end
    if z ~= 1 then return end

    local did_push = false
    local function ensure_push()
        if not did_push then
            self:push_undo_state()
            did_push = true
        end
    end

    self.held_time = now_ms()
    self.held = { t = t, s = x, y = y, was_on = tr.gates[x], aux = true }
    if tr.ties then tr.ties[x] = false end

    local applied_mod = self:get_active_mod_id()
    local applied_value = nil
    if self.mod_held[cfg.MOD.MUTE] then
        tr.muted = not tr.muted
        applied_value = tr.muted and "on" or "off"
    elseif self.mod_held[cfg.MOD.SOLO] then
        tr.solo = not tr.solo
        self:update_solo()
        applied_value = tr.solo and "on" or "off"
    elseif self.mod_held[cfg.MOD.START] then
        tr.start_step = x
        self.track_steps[t] = 1
        applied_value = tostring(x)
    elseif self.mod_held[cfg.MOD.END_STEP] then
        tr.end_step = x
        applied_value = tostring(x)
    elseif self.mod_held[cfg.MOD.BEAT_RPT] then
        self.beat_repeat_excluded[t] = not self.beat_repeat_excluded[t]
        applied_value = self.beat_repeat_excluded[t] and "exclude" or "include"
    elseif self.mod_held[cfg.MOD.SPICE] and self.spice_pending_amount then
        ensure_push()
        if tr.gates[x] then self.spice[t][x] = { amount = self.spice_pending_amount, current = 0 } end
        applied_value = tostring(self.spice_pending_amount)
    elseif self.mod_held[cfg.MOD.CLEAR] and self.mod_held[cfg.MOD.SHIFT] then
        ensure_push()
        self:clear_all_tracks()
        applied_value = "all"
    elseif self.mod_held[cfg.MOD.CLEAR] then
        ensure_push()
        self:clear_track(t)
        applied_value = "track"
    elseif self.mod_held[cfg.MOD.RATIOS] and tc.type == "drum" then
        ensure_push()
        tr.gates[x] = true
        tr.vels[x] = self:aux_row_to_vel_level(y)
        applied_value = self:apply_pending_ratio_to_step(t, x)
    elseif self.mod_held[cfg.MOD.RATIOS] and tc.type == "poly" then
        ensure_push()
        tr.pitches[x] = self:poly_toggle_aux_degree(t, self:poly_active_pitches(tr, x), self:aux_row_to_degree(y))
        tr.gates[x] = (#tr.pitches[x] > 0)
        if tr.gates[x] then
            tr.vels[x] = clamp(tonumber(tr.vels[x]) or self:get_track_default_vel_level(t), 1, 15)
            applied_value = self:apply_pending_ratio_to_step(t, x)
        else
            applied_value = "off"
        end
    elseif self.mod_held[cfg.MOD.RATIOS] then
        ensure_push()
        tr.gates[x] = true
        tr.vels[x] = clamp(tonumber(tr.vels[x]) or self:get_track_default_vel_level(t), 1, 15)
        tr.pitches[x] = self:aux_row_to_degree(y)
        applied_value = self:apply_pending_ratio_to_step(t, x)
    elseif self:mod_active(cfg.MOD.TEMP) and self:is_temp_button_fill_mode() then
        ensure_push()
        local fill_vel = self:aux_row_to_vel_level(y)
        local fill_pitch = self:aux_row_to_degree(y)
        if self.fill_patterns[t][x] then
            self.fill_patterns[t][x] = nil
            applied_value = "off"
        else
            local fp = tr.pitches[x] or 1
            if type(fp) == "table" then fp = fp[1] or 1 end
            self.fill_patterns[t][x] = {
                vel = (tc.type == "drum") and fill_vel or self:get_track_default_vel_level(t),
                pitch = (tc.type == "drum") and fp or fill_pitch
            }
            applied_value = (tc.type == "drum") and ("vel " .. tostring(fill_vel)) or ("deg " .. tostring(fill_pitch))
        end
    elseif self:mod_active(cfg.MOD.TEMP) then
        ensure_push()
        local degree = self:aux_row_to_degree(y)
        local level = self:aux_row_to_vel_level(y)
        local was_off = not tr.gates[x]
        if not tr.gates[x] then
            tr.gates[x] = true
            tr.vels[x] = self:get_track_default_vel_level(t)
            if tc.type == "poly" and type(tr.pitches[x]) ~= "table" then tr.pitches[x] = { 1 } end
        end

        if tc.type == "drum" then
            tr.vels[x] = level
            applied_value = "vel " .. tostring(level)
        elseif tc.type == "poly" then
            tr.pitches[x] = self:poly_toggle_aux_degree(t, self:poly_active_pitches(tr, x), degree)
            tr.gates[x] = (#tr.pitches[x] > 0)
            applied_value = "deg " .. tostring(degree)
        else
            tr.pitches[x] = degree
            tr.gates[x] = true
            applied_value = "deg " .. tostring(degree)
        end

        if was_off and tr.gates[x] then
            self:add_temp_step(t, x)
        end
    elseif self.mod_held[cfg.MOD.SPICE] and not self.spice_pending_amount then
        ensure_push()
        self.spice[t][x] = nil
        applied_value = "clear"
    elseif tc.type == "drum" then
        ensure_push()
        local next_vel = self:aux_row_to_vel_level(y)
        if tr.gates[x] and tr.vels[x] == next_vel then
            tr.gates[x] = false
            if tr.ties then tr.ties[x] = false end
        else
            tr.gates[x] = true
            tr.vels[x] = next_vel
        end
    elseif tc.type == "poly" then
        ensure_push()
        tr.pitches[x] = self:poly_toggle_aux_degree(t, self:poly_active_pitches(tr, x), self:aux_row_to_degree(y))
        tr.gates[x] = (#tr.pitches[x] > 0)
        if tr.gates[x] then
            tr.vels[x] = clamp(tonumber(tr.vels[x]) or self:get_track_default_vel_level(t), 1, 15)
        end
    else
        ensure_push()
        local next_degree = self:aux_row_to_degree(y)
        if tr.gates[x] and self:get_closest_aux_degree(t, tr.pitches[x]) == next_degree then
            tr.gates[x] = false
            if tr.ties then tr.ties[x] = false end
        else
            tr.gates[x] = true
            tr.vels[x] = clamp(tonumber(tr.vels[x]) or self:get_track_default_vel_level(t), 1, 15)
            tr.pitches[x] = next_degree
        end
    end

    if prev_held and prev_held.aux and prev_held.t == t and prev_held.s ~= x and not self:any_mod_active() then
        self:apply_held_gate_span(t, prev_held.s, x, x)
    end

    if applied_mod then
        self:flash_mod_applied(applied_mod, applied_value or self:get_active_mod_value(applied_mod))
    end
    if not self.mod_held[cfg.MOD.SPICE] then self.spice_pending_amount = nil end
    self:request_arc_redraw()
    self:request_redraw()
end

function App:handle_main_grid_event(x, y, z)
    local mod_row = self:get_main_mod_row()
    local dyn_row = self:get_main_dynamic_row()
    local takeover_rows = self:get_main_takeover_note_rows()

    if self.realtime_play_mode and self.playing then
        if y == mod_row then
            self:handle_mod_row(x, z)
            return
        end

        if y == dyn_row then
            self:handle_dynamic_row(x, z)
            return
        end

        local rt_track = self:row_to_track(y)
        if rt_track and rt_track >= 1 and rt_track <= cfg.NUM_TRACKS then
            self:handle_realtime_play_event(rt_track, x, z)
            return
        end
    end

    if self.takeover_mode then
        if y == mod_row then
            self:handle_mod_row(x, z)
            return
        end

        if y == dyn_row and self:is_modifier_dynamic_row_active() and not self:is_main_grid_128() then
            self:handle_dynamic_row(x, z)
            return
        end

        if y >= 1 and y <= takeover_rows then
            local t = self.sel_track or 1
            self.sel_track = t
            local tr = self.tracks[t]
            local tc = self.track_cfg[t]
            local prev_held = self.held

            if z == 1 then
                local did_push = false
                local function ensure_push()
                    if not did_push then
                        self:push_undo_state()
                        did_push = true
                    end
                end
                self.held_time = now_ms()
                self.held = { t = t, s = x, y = y, was_on = tr.gates[x], aux = false }
                if tr.ties then tr.ties[x] = false end

                local applied_mod = self:get_active_mod_id()
                local applied_value = nil

                if self.mod_held[cfg.MOD.MUTE] then
                    tr.muted = not tr.muted
                    applied_value = tr.muted and "on" or "off"
                elseif self.mod_held[cfg.MOD.SOLO] then
                    tr.solo = not tr.solo
                    self:update_solo()
                    applied_value = tr.solo and "on" or "off"
                elseif self.mod_held[cfg.MOD.START] then
                    tr.start_step = x
                    self.track_steps[t] = 1
                    applied_value = tostring(x)
                elseif self.mod_held[cfg.MOD.END_STEP] then
                    tr.end_step = x
                    applied_value = tostring(x)
                elseif self.mod_held[cfg.MOD.BEAT_RPT] then
                    self.beat_repeat_excluded[t] = not self.beat_repeat_excluded[t]
                    applied_value = self.beat_repeat_excluded[t] and "exclude" or "include"
                elseif self.mod_held[cfg.MOD.SPICE] and self.spice_pending_amount then
                    ensure_push()
                    if tr.gates[x] then self.spice[t][x] = { amount = self.spice_pending_amount, current = 0 } end
                    applied_value = tostring(self.spice_pending_amount)
                elseif self.mod_held[cfg.MOD.CLEAR] and self.mod_held[cfg.MOD.SHIFT] then
                    ensure_push()
                    self:clear_all_tracks()
                    applied_value = "all"
                elseif self.mod_held[cfg.MOD.CLEAR] then
                    ensure_push()
                    self:clear_track(t)
                    applied_value = "track"
                elseif self.mod_held[cfg.MOD.RATIOS] then
                    ensure_push()
                    local degree = self:main_takeover_row_to_degree(y)
                    local level = self:main_takeover_row_to_vel_level(y)
                    if tc.type == "drum" then
                        tr.gates[x] = true
                        tr.vels[x] = level
                    elseif tc.type == "poly" then
                        tr.pitches[x] = self:poly_toggle_pitch(self:poly_active_pitches(tr, x), degree)
                        tr.gates[x] = (#tr.pitches[x] > 0)
                        if tr.gates[x] then
                            tr.vels[x] = clamp(tonumber(tr.vels[x]) or self:get_track_default_vel_level(t), 1, 15)
                        end
                    else
                        tr.gates[x] = true
                        tr.pitches[x] = degree
                        tr.vels[x] = clamp(tonumber(tr.vels[x]) or self:get_track_default_vel_level(t), 1, 15)
                    end
                    if tr.gates[x] then
                        applied_value = self:apply_pending_ratio_to_step(t, x)
                    else
                        applied_value = "off"
                    end
                elseif self:mod_active(cfg.MOD.TEMP) and self:is_temp_button_fill_mode() then
                    ensure_push()
                    local fill_vel = clamp(16 - y, 1, 15)
                    local fill_pitch = clamp(16 - y, 1, 16)
                    if self.fill_patterns[t][x] then
                        self.fill_patterns[t][x] = nil
                        applied_value = "off"
                    else
                        local fp = tr.pitches[x] or 1
                        if type(fp) == "table" then fp = fp[1] or 1 end
                        self.fill_patterns[t][x] = {
                            vel = (tc.type == "drum") and fill_vel or self:get_track_default_vel_level(t),
                            pitch = (tc.type == "drum") and fp or fill_pitch
                        }
                        applied_value = (tc.type == "drum") and ("vel " .. tostring(fill_vel)) or
                            ("deg " .. tostring(fill_pitch))
                    end
                elseif self:mod_active(cfg.MOD.TEMP) then
                    ensure_push()
                    local degree = self:main_takeover_row_to_degree(y)
                    local level = self:main_takeover_row_to_vel_level(y)
                    local was_off = not tr.gates[x]
                    if not tr.gates[x] then
                        tr.gates[x] = true
                        tr.vels[x] = self:get_track_default_vel_level(t)
                        if tc.type == "poly" and type(tr.pitches[x]) ~= "table" then tr.pitches[x] = { 1 } end
                    end

                    if tc.type == "drum" then
                        tr.vels[x] = level
                        applied_value = "vel " .. tostring(level)
                    elseif tc.type == "poly" then
                        tr.pitches[x] = self:poly_toggle_pitch(self:poly_active_pitches(tr, x), degree)
                        tr.gates[x] = (#tr.pitches[x] > 0)
                        applied_value = "deg " .. tostring(degree)
                    else
                        tr.pitches[x] = degree
                        tr.gates[x] = true
                        applied_value = "deg " .. tostring(degree)
                    end

                    if was_off and tr.gates[x] then
                        self:add_temp_step(t, x)
                    end
                elseif self.mod_held[cfg.MOD.SPICE] and not self.spice_pending_amount then
                    ensure_push()
                    self.spice[t][x] = nil
                    applied_value = "clear"
                elseif tc.type == "drum" then
                    ensure_push()
                    local level = self:main_takeover_row_to_vel_level(y)
                    if y == dyn_row and not self:is_main_grid_128() then
                        if tr.gates[x] then
                            tr.gates[x] = false
                        else
                            tr.gates[x] = true
                            tr.vels[x] = self:get_track_default_vel_level(t)
                        end
                    else
                        if tr.gates[x] then
                            tr.vels[x] = level
                        else
                            tr.gates[x] = true
                            tr.vels[x] = level
                        end
                    end
                else
                    ensure_push()
                    local degree = self:main_takeover_row_to_degree(y)
                    if tc.type == "poly" then
                        tr.pitches[x] = self:poly_toggle_pitch(self:poly_active_pitches(tr, x), degree)
                        tr.gates[x] = (#tr.pitches[x] > 0)
                    else
                        if tr.gates[x] and tr.pitches[x] == degree then
                            tr.gates[x] = false
                        else
                            tr.gates[x] = true
                            tr.pitches[x] = degree
                            tr.vels[x] = self:get_track_default_vel_level(t)
                        end
                    end
                end
                if prev_held and not prev_held.aux and prev_held.t == t and prev_held.s ~= x and not self:any_mod_active() then
                    self:apply_held_gate_span(t, prev_held.s, x, x)
                end

                if applied_mod then
                    self:flash_mod_applied(applied_mod, applied_value or self:get_active_mod_value(applied_mod))
                end
            else
                if self.held and self.held.t == t and self.held.s == x then
                    local hold_duration = now_ms() - self.held_time
                    if hold_duration < self.HOLD_THRESHOLD and self.held.was_on and self.held.y == dyn_row and not self:is_main_grid_128() then tr.gates[x] = false end
                end
                self.held = nil
            end

            if not self.mod_held[cfg.MOD.SPICE] then self.spice_pending_amount = nil end
            self:request_arc_redraw()
            self:request_redraw()
        end
        return
    end

    if y == mod_row then
        self:handle_mod_row(x, z)
        return
    end

    if y == dyn_row then
        self:handle_dynamic_row(x, z)
        return
    end

    local t = self:row_to_track(y)
    if t and t >= 1 and t <= cfg.NUM_TRACKS then
        local prev_held = self.held
        if z == 1 then
            local did_push = false
            local function ensure_push()
                if not did_push then
                    self:push_undo_state()
                    did_push = true
                end
            end
            self.held_time = now_ms()
            self.sel_track = t
            if self.mod_held[cfg.MOD.MUTE] then
                self.tracks[t].muted = not self.tracks[t].muted
            elseif self.mod_held[cfg.MOD.SOLO] then
                self.tracks[t].solo = not self.tracks[t].solo
                self:update_solo()
            elseif self.mod_held[cfg.MOD.START] then
                self.tracks[t].start_step = x
                self.track_steps[t] = 1
            elseif self.mod_held[cfg.MOD.END_STEP] then
                self.tracks[t].end_step = x
            elseif self.mod_held[cfg.MOD.BEAT_RPT] then
                self.beat_repeat_excluded[t] = not self.beat_repeat_excluded[t]
            elseif self.mod_held[cfg.MOD.SPICE] and self.spice_pending_amount then
                ensure_push()
                if self.tracks[t].gates[x] then self.spice[t][x] = { amount = self.spice_pending_amount, current = 0 } end
                self.sel_track = t
            elseif self.mod_held[cfg.MOD.CLEAR] and self.mod_held[cfg.MOD.SHIFT] then
                ensure_push()
                self:clear_all_tracks()
            elseif self.mod_held[cfg.MOD.CLEAR] then
                ensure_push()
                self:clear_track(t)
                self.sel_track = t
            elseif self.mod_held[cfg.MOD.RATIOS] then
                ensure_push()
                if not self.tracks[t].gates[x] then
                    self.tracks[t].gates[x] = true
                    self.tracks[t].vels[x] = self:get_track_default_vel_level(t)
                    if self.track_cfg[t].type == "poly" and type(self.tracks[t].pitches[x]) ~= "table" then self.tracks[t].pitches[x] = { 1 } end
                end
                self:apply_pending_ratio_to_step(t, x)
                self.sel_track = t
            elseif self:mod_active(cfg.MOD.TEMP) and self:is_temp_button_fill_mode() then
                ensure_push()
                if self.fill_patterns[t][x] then
                    self.fill_patterns[t][x] = nil
                else
                    local fp = self.tracks[t].pitches[x] or 1
                    if type(fp) == "table" then fp = fp[1] or 1 end
                    self.fill_patterns[t][x] = { vel = self:get_track_default_vel_level(t), pitch = fp }
                end
                self.sel_track = t
            elseif self:mod_active(cfg.MOD.TEMP) then
                ensure_push()
                self.held = { t = t, s = x, y = y, was_on = self.tracks[t].gates[x], aux = false }
                if self.tracks[t].ties then self.tracks[t].ties[x] = false end
                if not self.tracks[t].gates[x] then
                    self.tracks[t].gates[x] = true
                    self.tracks[t].vels[x] = self:get_track_default_vel_level(t)
                    if self.track_cfg[t].type == "poly" and type(self.tracks[t].pitches[x]) ~= "table" then self.tracks[t].pitches[x] = { 1 } end
                    self:add_temp_step(t, x)
                end
            elseif self.mod_held[cfg.MOD.SPICE] and not self.spice_pending_amount then
                ensure_push()
                self.spice[t][x] = nil
                self.sel_track = t
            elseif self:any_mod_active() then
                self.sel_track = t
            else
                ensure_push()
                self.held = { t = t, s = x, y = y, was_on = self.tracks[t].gates[x], aux = false }
                if self.tracks[t].ties then self.tracks[t].ties[x] = false end
                if not self.tracks[t].gates[x] then
                    self.tracks[t].gates[x] = true
                    self.tracks[t].vels[x] = self:get_track_default_vel_level(t)
                    if self.track_cfg[t].type == "poly" and type(self.tracks[t].pitches[x]) ~= "table" then self.tracks[t].pitches[x] = { 1 } end
                end
            end
            if prev_held and not prev_held.aux and prev_held.t == t and prev_held.s ~= x and not self:any_mod_active() then
                self:apply_held_gate_span(t, prev_held.s, x, x)
            end
            if self:any_mod_active() then
                local mod_id = self:get_active_mod_id()
                if mod_id then self:flash_mod_applied(mod_id) end
            end
        else
            if self.held and self.held.t == t and self.held.s == x then
                local hold_duration = now_ms() - self.held_time
                if hold_duration < self.HOLD_THRESHOLD and self.held.was_on then self.tracks[t].gates[x] = false end
            end
            self.held = nil
        end
        if not self.mod_held[cfg.MOD.SPICE] then self.spice_pending_amount = nil end
        self:request_arc_redraw()
        self:request_redraw()
    end
end

function App:grid_event(x, y, z)
    self:handle_main_grid_event(x, y, z)
end

function App:handle_midi_message(data, source_port)
    local status = data[1] or 0
    local is_realtime = (status == 248) or (status == 250) or (status == 251) or (status == 252)

    if is_realtime and source_port then
        if not self.midi_clock_in_port then
            self.midi_clock_in_port = source_port
        elseif self.midi_clock_in_port ~= source_port then
            return
        end
    end

    if status == 248 then
        if self.use_midi_clock and self.playing then
            self:advance_clock_tick()
            if self.redraw_deferred then
                local now = now_ms()
                if now - (self.last_redraw_time or 0) >= self.redraw_min_ms then self:redraw_grid(true) end
            end
        end
        return
    elseif status == 250 then
        self:reset_playheads()
        self.playing = true
        self:tick()
        self:request_redraw()
        return
    elseif status == 251 then
        self.playing = true
        self:request_redraw()
        return
    elseif status == 252 then
        self.playing = false
        self:clear_realtime_row_holds()
        self:stop_all_notes()
        self:request_redraw()
        return
    end

    local msg = midi.to_msg(data)
    local t = msg and msg.type
    if t == "start" then
        self:reset_playheads()
        self.playing = true
        self:tick()
        self:request_redraw()
    elseif t == "continue" then
        self.playing = true
        self:request_redraw()
    elseif t == "stop" then
        self.playing = false
        self:clear_realtime_row_holds()
        self:stop_all_notes()
        self:request_redraw()
    end
end

function App:start()
    if self.playing then return end
    self.playing = true
    self:reset_playheads()

    if not self.use_midi_clock and self.send_midi_start_stop_out then
        self:midi_realtime_start()
    end

    if not self.use_midi_clock then
        if self.internal_clock_id then clock.cancel(self.internal_clock_id) end
        self.internal_clock_id = clock.run(function()
            while self.playing and not self.use_midi_clock do
                clock.sync(1 / 24)
                self:advance_clock_tick()
            end
        end)
    end
    self:request_redraw()
end

function App:stop()
    self.playing = false
    self:clear_realtime_row_holds()
    if not self.use_midi_clock and self.send_midi_start_stop_out then
        self:midi_realtime_stop()
    end
    if self.internal_clock_id then
        clock.cancel(self.internal_clock_id)
        self.internal_clock_id = nil
    end
    self:stop_all_notes()
    self:request_redraw()
end

function App:restart_transport_if_needed()
    if self.playing then
        self:stop()
        self:start()
    else
        if self.internal_clock_id then
            clock.cancel(self.internal_clock_id)
            self.internal_clock_id = nil
        end
    end
end

function App:redraw_rate(fps)
    local rate = math.max(10, math.min(60, fps or 30))
    self.redraw_min_ms = math.floor(1000 / rate)
    if self.grid_timer then self.grid_timer.time = 1 / rate end
end

function App:connect_midi_from_params()
    local slots = { 1, 0, 0, 0 }

    if params and params.get then
        local ok1, port1 = pcall(function() return params:get("permute_midi_out") end)
        if ok1 and port1 ~= nil then slots[1] = clamp(tonumber(port1) or 1, 1, 16) end

        for slot = 2, 4 do
            local id = "permute_midi_out_" .. slot
            local ok, port = pcall(function() return params:get(id) end)
            if ok and port ~= nil then
                slots[slot] = clamp((tonumber(port) or 1) - 1, 0, 16)
            end
        end
    end

    self.midi_port_slots = slots
    self.midi_out_ports = self:get_selected_midi_ports()
    self.midi_active_ports = {}
    self.midi_clock_in_port = nil

    for _, port in ipairs(self.midi_out_ports) do
        local port_id = port
        self.midi_active_ports[port_id] = true
        if not self.midi_devs[port_id] then
            local dev = midi.connect(port_id)
            self.midi_devs[port_id] = dev
            if dev then
                dev.event = function(data)
                    if self.midi_active_ports[port_id] then
                        self:handle_midi_message(data, port_id)
                    end
                end
            end
        end
    end

    self.midi_dev = self.midi_devs[self.midi_out_ports[1]]
end

function App:key(n, z)
    if z == 0 then return end
    if n == 2 then
        if self.playing then self:stop() else self:start() end
    elseif n == 3 then
        params:set("permute_ext_clock", self.use_midi_clock and 1 or 2)
    end
end

function App:enc(n, d)
    if n == 2 then
        params:delta("permute_tempo", d)
    elseif n == 3 then
        self.sel_track = clamp((self.sel_track or 1) + d, 1, cfg.NUM_TRACKS)
        self:request_arc_redraw()
        self:request_redraw()
    end
end

function App:init()
    for port = 1, 4 do
        self:attach_grid_port(port)
    end
    self:refresh_grid_assignments()
    self:connect_arc()

    if grid then
        grid.add = function(new_grid)
            if new_grid and new_grid.port then
                self:attach_grid_port(new_grid.port)
                self:refresh_grid_assignments()
                self:request_redraw()
            end
        end

        grid.remove = function(old_grid)
            if old_grid and old_grid.port then
                self.grid_ports[old_grid.port] = nil
                self:refresh_grid_assignments()
                self:request_redraw()
            end
        end
    end

    if arc then
        arc.add = function()
            self:connect_arc()
            self:request_redraw()
        end

        arc.remove = function()
            self.arc_dev = nil
        end
    end

    param_setup.setup(self)
    self:connect_midi_from_params()
    self.factory_default_setup_values = self:capture_default_setup_values()
    self.factory_default_track_cfg = self:export_track_cfg()
    self:load_default_setup(false)

    self.grid_timer = metro.init(function()
        if self.grid_dirty then
            self:redraw_grid()
            self.grid_dirty = false
        end
        if self.arc_dirty then
            self:redraw_arc()
            self.arc_dirty = false
        end
    end, 1 / 30, -1)
    self.grid_timer:start()

    self:request_redraw()
end

function App:cleanup()
    self:stop()
    self:reset_screen_transform()
    if self.grid_timer then self.grid_timer:stop() end
    if self.arc_dev then
        self.arc_dev:all(0)
        self.arc_dev:refresh()
    end
end

return App
