local cfg = include("lib/config")
local musicutil = require("musicutil")

local M = {}

local SCALE_NAMES = { "chromatic", "diatonic", "pentatonic", "lightbath" }
local TRACK_TYPES = { "drum", "mono", "poly" }
local BEAT_REPEAT_MODES = { "full-row", "one-handed", "step-select" }
local TRANSPOSE_MODES = { "semitone", "scale degree" }
local RESET_TIMING_OPTIONS = { "instant", "next beat" }
local SCALE_DEGREE_LABELS = {
    diatonic = { "I", "ii", "iii", "IV", "V", "vi", "vii" },
    pentatonic = { "I", "ii", "iii", "V", "vi" },
    lightbath = { "I", "ii", "V", "vi" }
}

local DEFAULT_SETUP_BASE_IDS = {
    "permute_scale",
    "permute_key",
    "permute_scale_degree",
    "permute_tempo",
    "permute_master_len_enabled",
    "permute_master_len",
    "permute_reset_timing",
    "permute_ext_clock",
    "permute_send_clock_out",
    "permute_send_start_stop_out",
    "permute_clock_debug",
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
    "permute_transpose_mode",
    "permute_beat_repeat_mode",
    "permute_beat_repeat_direction",
    "permute_temp_button_mode",
    "permute_arc_k1_threshold",
    "permute_arc_k2_threshold",
    "permute_arc_k3_threshold",
    "permute_arc_k4_threshold",
}

local clamp = util.clamp

local function midi_port_options(include_off)
    local out = {}
    local idx = 1
    if include_off then
        out[idx] = "off"
        idx = idx + 1
    end
    for i = 1, 16 do
        out[idx] = tostring(i)
        idx = idx + 1
    end
    return out
end

local function scale_degree_label(scale_type, idx)
    if scale_type == "chromatic" then return "-" end
    local labels = SCALE_DEGREE_LABELS[scale_type] or SCALE_DEGREE_LABELS.diatonic
    return labels[clamp(idx, 1, #labels)] or labels[1]
end

function M.setup(app)
    local prev_action_write = params.action_write
    local prev_action_read = params.action_read
    local prev_action_delete = params.action_delete

    params:add_group("permute_seq", "permute", 38)

    params:add_option("permute_scale", "scale", SCALE_NAMES, 2)
    params:set_action("permute_scale", function(v)
        app.scale_type = SCALE_NAMES[v] or "diatonic"
        local labels = SCALE_DEGREE_LABELS[app.scale_type]
        if labels then
            app.scale_degree = clamp(tonumber(app.scale_degree) or 1, 1, #labels)
        else
            app.scale_degree = 1
        end
        app:invalidate_aux_degree_cache()
        app:request_redraw()
        app:request_aux_redraw()
    end)

    params:add_number("permute_key", "key", 0, 11, 0, function(param)
        local note = (param:get() % 12) + 60
        local name = musicutil.note_num_to_name(note, true)
        return string.gsub(name, "%d", "")
    end)
    params:set_action("permute_key", function(v)
        app.key_root = v
        app:request_redraw()
        app:request_aux_redraw()
    end)

    params:add_number("permute_scale_degree", "scale degree", 1, 7, 1, function(param)
        return scale_degree_label(app.scale_type, param:get())
    end)
    params:set_action("permute_scale_degree", function(v)
        if app.scale_type ~= "chromatic" then
            local labels = SCALE_DEGREE_LABELS[app.scale_type] or SCALE_DEGREE_LABELS.diatonic
            app.scale_degree = clamp(tonumber(v) or 1, 1, #labels)
            app:invalidate_aux_degree_cache()
            app:request_redraw()
            app:request_aux_redraw()
        end
    end)

    params:add_number("permute_tempo", "tempo", 30, 300, cfg.DEFAULT_TEMPO_BPM)
    params:set_action("permute_tempo", function(v)
        app.tempo_bpm = v
        params:set("clock_tempo", v)
        app:request_redraw()
    end)

    params:add_option("permute_master_len_enabled", "master length", { "off", "on" }, 1)
    params:set_action("permute_master_len_enabled", function(v)
        app.master_seq_len_enabled = (v == 2)
        app:reset_playheads()
    end)

    params:add_number("permute_master_len", "master length steps", 1, cfg.MAX_MASTER_SEQ_LEN, cfg.DEFAULT_MASTER_SEQ_LEN)
    params:set_action("permute_master_len", function(v)
        app.master_seq_len = clamp(tonumber(v) or cfg.DEFAULT_MASTER_SEQ_LEN, 1, cfg.MAX_MASTER_SEQ_LEN)
        app.master_seq_counter = 0
    end)

    params:add_option("permute_reset_timing", "reset timing", RESET_TIMING_OPTIONS, 1)
    params:set_action("permute_reset_timing", function(v)
        app.reset_timing = RESET_TIMING_OPTIONS[v] or "instant"
        if app.reset_timing ~= "next beat" then
            app.pending_transport_align_on_beat = false
            app.pending_meta_reset_on_beat = false
        end
        app:request_redraw()
    end)

    params:add_option("permute_ext_clock", "external midi clock", { "off", "on" }, 1)
    params:set_action("permute_ext_clock", function(v)
        app.use_midi_clock = (v == 2)
        app:restart_transport_if_needed()
        app:request_redraw()
        if app.clock_debug_enabled and app.clock_debug_log then
            app:clock_debug_log(string.format("[%s] mode changed -> %s",
                os.date("%H:%M:%S"),
                app.use_midi_clock and "external" or "internal"))
        end
    end)

    params:add_option("permute_send_clock_out", "send midi clock out", { "off", "on" }, 2)
    params:set_action("permute_send_clock_out", function(v)
        app.send_midi_clock_out = (v == 2)
    end)

    params:add_option("permute_send_start_stop_out", "send midi start/stop out", { "off", "on" }, 2)
    params:set_action("permute_send_start_stop_out", function(v)
        app.send_midi_start_stop_out = (v == 2)
    end)

    params:add_option("permute_clock_debug", "clock debug", { "off", "on" }, 1)
    params:set_action("permute_clock_debug", function(v)
        app:set_clock_debug_enabled(v == 2)
    end)

    params:add_option("permute_midi_out", "midi out port", midi_port_options(), 1)
    params:set_action("permute_midi_out", function(v)
        app:connect_midi_from_params()
    end)

    params:add_option("permute_midi_out_2", "midi out port 2", midi_port_options(true), 1)
    params:set_action("permute_midi_out_2", function()
        app:connect_midi_from_params()
    end)

    params:add_option("permute_midi_out_3", "midi out port 3", midi_port_options(true), 1)
    params:set_action("permute_midi_out_3", function()
        app:connect_midi_from_params()
    end)

    params:add_option("permute_midi_out_4", "midi out port 4", midi_port_options(true), 1)
    params:set_action("permute_midi_out_4", function()
        app:connect_midi_from_params()
    end)

    params:add_number("permute_melody_gate_ticks", "melody gate ticks", 1, 24, 5)
    params:set_action("permute_melody_gate_ticks", function(v)
        app.melody_gate_clocks = v
        for t = 1, cfg.NUM_TRACKS do
            if app.track_cfg[t].type ~= "drum" then
                app.track_gate_ticks[t] = clamp(tonumber(v) or 1, 1, 24)
            end
        end
    end)

    params:add_number("permute_drum_gate_ticks", "drum gate ticks", 1, 12, 1)
    params:set_action("permute_drum_gate_ticks", function(v)
        app.drum_gate_clocks = v
        for t = 1, cfg.NUM_TRACKS do
            if app.track_cfg[t].type == "drum" then
                app.track_gate_ticks[t] = clamp(tonumber(v) or 1, 1, 24)
            end
        end
    end)

    params:add_number("permute_spice_accum_min", "spice accum min", -127, 127, cfg.SPICE_MIN)
    params:set_action("permute_spice_accum_min", function(v)
        local max_v = params:get("permute_spice_accum_max")
        if v > max_v then
            params:set("permute_spice_accum_max", v)
            return
        end
        app:set_spice_accum_bounds(v, max_v)
    end)

    params:add_number("permute_spice_accum_max", "spice accum max", -127, 127, cfg.SPICE_MAX)
    params:set_action("permute_spice_accum_max", function(v)
        local min_v = params:get("permute_spice_accum_min")
        if v < min_v then
            params:set("permute_spice_accum_min", v)
            return
        end
        app:set_spice_accum_bounds(min_v, v)
    end)

    params:add_option("permute_crow_enabled", "crow enabled", { "off", "on" }, 1)
    params:set_action("permute_crow_enabled", function(v)
        app.crow_enabled = (v == 2)
    end)

    params:add_number("permute_crow_track_1", "crow out1 track", 0, cfg.NUM_TRACKS, 0)
    params:set_action("permute_crow_track_1", function(v)
        app.crow_track_1 = v
    end)

    params:add_number("permute_crow_track_2", "crow out2 track", 0, cfg.NUM_TRACKS, 0)
    params:set_action("permute_crow_track_2", function(v)
        app.crow_track_2 = v
    end)

    params:add_number("permute_redraw_fps", "redraw fps", 10, 60, 30)
    params:set_action("permute_redraw_fps", function(v)
        app:redraw_rate(v)
    end)

    params:add_option("permute_screen_orientation", "screen orientation", { "normal", "cw90" }, 1)
    params:set_action("permute_screen_orientation", function(v)
        local opts = { "normal", "cw90" }
        app.screen_orientation = opts[v] or "normal"
        app:request_redraw()
    end)

    params:add_option("permute_beat_repeat_mode", "b. repeat mode", BEAT_REPEAT_MODES, 1)
    params:set_action("permute_beat_repeat_mode", function(v)
        app.beat_repeat_mode = BEAT_REPEAT_MODES[v] or BEAT_REPEAT_MODES[1]
        app.beat_repeat_len = 0
        app.beat_repeat_excluded = {}
        if app.reset_step_select_repeat then app:reset_step_select_repeat() end
        app:request_redraw()
        app:request_aux_redraw()
    end)

    params:add_option("permute_beat_repeat_direction", "b. repeat direction", { "l->r", "l<-r" }, 1)
    params:set_action("permute_beat_repeat_direction", function(v)
        app.beat_repeat_direction = (v == 2) and "l<-r" or "l->r"
        app:request_redraw()
        app:request_aux_redraw()
    end)

    params:add_option("permute_transpose_mode", "transpose mode", TRANSPOSE_MODES, 1)
    params:set_action("permute_transpose_mode", function(v)
        app.transpose_mode = TRANSPOSE_MODES[v] or TRANSPOSE_MODES[1]
        app:request_redraw()
        app:request_aux_redraw()
    end)

    params:add_option("permute_temp_button_mode", "temp button mode", { "temp", "fill" }, 1)
    params:set_action("permute_temp_button_mode", function(v)
        app.temp_button_mode = (v == 2) and "fill" or "temp"
        app.temp_latched = false
        app.fill_latched = false
        app.fill_active = false
        app.fill_applied = false
        app.temp_steps = {}
        app:request_redraw()
        app:request_aux_redraw()
    end)

    params:add_number("permute_arc_k1_threshold", "arc k1 threshold", 1, 32, 8)
    params:set_action("permute_arc_k1_threshold", function(v)
        app.arc_delta_thresholds[1] = clamp(tonumber(v) or 8, 1, 32)
    end)

    params:add_number("permute_arc_k2_threshold", "arc k2 threshold", 1, 32, 12)
    params:set_action("permute_arc_k2_threshold", function(v)
        app.arc_delta_thresholds[2] = clamp(tonumber(v) or 12, 1, 32)
    end)

    params:add_number("permute_arc_k3_threshold", "arc k3 threshold", 1, 32, 2)
    params:set_action("permute_arc_k3_threshold", function(v)
        app.arc_delta_thresholds[3] = clamp(tonumber(v) or 2, 1, 32)
    end)

    params:add_number("permute_arc_k4_threshold", "arc k4 threshold", 1, 32, 16)
    params:set_action("permute_arc_k4_threshold", function(v)
        app.arc_delta_thresholds[4] = clamp(tonumber(v) or 16, 1, 32)
    end)

    params:add_trigger("permute_panic", "panic")
    params:set_action("permute_panic", function()
        app:stop_all_notes()
    end)

    params:add_trigger("permute_start", "start")
    params:set_action("permute_start", function() app:start() end)

    params:add_trigger("permute_stop", "stop")
    params:set_action("permute_stop", function() app:stop() end)

    params:add_trigger("permute_save_default", "save as default")
    params:set_action("permute_save_default", function()
        app:save_default_setup(true)
    end)

    params:add_trigger("permute_reload_default", "reload default")
    params:set_action("permute_reload_default", function()
        app:load_default_setup(true)
    end)

    params:add_trigger("permute_clear_default", "clear default (factory)")
    params:set_action("permute_clear_default", function()
        app:clear_default_setup(true)
    end)

    for t = 1, cfg.NUM_TRACKS do
        local track = t
        local tc = app.track_cfg[track]
        local gid = "permute_track_" .. track

        params:add_group(gid, "track " .. track .. " config", 6)

        local type_idx = 1
        for i, v in ipairs(TRACK_TYPES) do
            if v == tc.type then
                type_idx = i
                break
            end
        end

        params:add_option(gid .. "_type", "track type", TRACK_TYPES, type_idx)
        params:set_action(gid .. "_type", function(v)
            local current_tc = app.track_cfg[track]
            local next_type = TRACK_TYPES[v] or (current_tc and current_tc.type) or tc.type
            app:set_track_type(track, next_type)
        end)

        params:add_number(gid .. "_ch", "midi channel", 1, 16, tc.ch)
        params:set_action(gid .. "_ch", function(v)
            local current_tc = app.track_cfg[track]
            if not current_tc then return end
            local next_ch = clamp(tonumber(v) or current_tc.ch, 1, 16)
            if app.push_undo_state and current_tc.ch ~= next_ch then app:push_undo_state() end
            current_tc.ch = next_ch
        end)

        params:add_number(gid .. "_note", "base note", 0, 127, tc.note)
        params:set_action(gid .. "_note", function(v)
            local current_tc = app.track_cfg[track]
            if not current_tc then return end
            local next_note = clamp(tonumber(v) or current_tc.note, 0, 127)
            if app.push_undo_state and current_tc.note ~= next_note then app:push_undo_state() end
            current_tc.note = next_note
        end)

        params:add_number(gid .. "_vel", "default velocity", 0, 127, app:get_track_default_midi_velocity(track))
        params:set_action(gid .. "_vel", function(v)
            local next_vel = clamp(tonumber(v) or app:get_track_default_midi_velocity(track), 0, 127)
            if app.push_undo_state and app.track_default_vel and app.track_default_vel[track] ~= next_vel then app:push_undo_state() end
            app.track_default_vel[track] = next_vel
        end)

        params:add_number(gid .. "_len", "default note length", 1, 24, app.track_gate_ticks[track])
        params:set_action(gid .. "_len", function(v)
            local next_len = clamp(tonumber(v) or app.track_gate_ticks[track] or 1, 1, 24)
            if app.push_undo_state and app.track_gate_ticks[track] ~= next_len then app:push_undo_state() end
            app.track_gate_ticks[track] = next_len
        end)

        params:add_option(gid .. "_hold_tie_len", "hold tie length", { "off", "on" }, app.track_hold_tie_len_enabled[track] and 2 or 1)
        params:set_action(gid .. "_hold_tie_len", function(v)
            app.track_hold_tie_len_enabled[track] = (v == 2)
        end)
    end

    params.action_write = function(filename, name, number)
        if prev_action_write then prev_action_write(filename, name, number) end
        app:save_preset(number)
    end

    params.action_read = function(filename, silent, number)
        if prev_action_read then prev_action_read(filename, silent, number) end
        app:load_preset(number)
    end

    params.action_delete = function(filename, name, number)
        if prev_action_delete then prev_action_delete(filename, name, number) end
        app:delete_preset(number)
    end

    params:set("permute_tempo", cfg.DEFAULT_TEMPO_BPM)
    params:bang()
end

function M.default_setup_param_ids(num_tracks)
    local ids = {}
    for i = 1, #DEFAULT_SETUP_BASE_IDS do
        ids[#ids + 1] = DEFAULT_SETUP_BASE_IDS[i]
    end
    for t = 1, (num_tracks or cfg.NUM_TRACKS) do
        local gid = "permute_track_" .. t
        ids[#ids + 1] = gid .. "_type"
        ids[#ids + 1] = gid .. "_ch"
        ids[#ids + 1] = gid .. "_note"
        ids[#ids + 1] = gid .. "_vel"
        ids[#ids + 1] = gid .. "_len"
        ids[#ids + 1] = gid .. "_hold_tie_len"
    end
    return ids
end

return M
