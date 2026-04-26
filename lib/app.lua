local H = include("lib/core/util")
local cfg = H.cfg
local deep_copy_table = H.deep_copy_table
local ARC_DELTA_THRESHOLDS = H.ARC_DELTA_THRESHOLDS

local App = {}
App.__index = App

function App.new()
    local self = setmetatable({}, App)

    self.tempo_bpm = cfg.DEFAULT_TEMPO_BPM
    self.use_midi_clock = false
    self.send_midi_clock_out = true
    self.send_midi_start_stop_out = true
    self.reset_timing = "instant"
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
    self.HOLD_THRESHOLD = cfg.DEFAULT_HOLD_THRESHOLD_MS

    self.last_notes = {}
    self.clock_ticks = 0
    self.transport_clock = 0
    self.active_note_offs = {}

    self.last_redraw_time = 0
    self.redraw_min_ms = cfg.DEFAULT_REDRAW_MIN_MS
    self.redraw_deferred = false
    self.screen_orientation = "normal"

    self.track_steps = {}
    self.track_clock_div = {}
    self.track_clock_mult = {}
    self.track_clock_phase = {}
    self.track_loop_count = {}

    self.mod_held = {}
    self.key_held = {}
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
    self.track_rand_gate_prob = {}
    self.track_rand_pitch_prob = {}
    self.track_rand_pitch_span = {}
    self.transpose_mode = "semitone"
    self.transpose_takeover_mode = false
    self.transpose_seq_enabled = false
    self.transpose_seq_steps = {}
    self.transpose_seq_selected_step = 1
    self.transpose_seq_assign = {}
    self.transpose_seq_clock_mult = 1
    self.transpose_seq_clock_div = 4
    self.transpose_seq_clock_phase = 0
    self.transpose_seq_step = 1
    self.transpose_seq_step_held = {}
    self.transpose_seq_hold_start = nil
    self.pending_meta_reset_on_beat = false
    self.pending_transport_align_on_beat = false
    self.track_default_vel = {}
    self.track_gate_ticks = {}
    self.track_hold_tie_len_enabled = {}
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
    self.aux_grid_dirty = true
    self.arc_dirty = true
    self.grid_timer = nil
    self.gc_metro = nil
    self.internal_clock_id = nil
    self.midi_clock_out_id = nil
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
    self.midi_devs_active = {}
    self.midi_port_slots = { 1, 0, 0, 0 }
    self.midi_out_ports = { 1 }
    self.midi_out_ports_snapshot = { 1 }
    self.midi_active_ports = { [1] = true }
    self.midi_clock_in_port = nil
    self.step_cache = {}
    self.step_cache_meta = {}
    self.step_cache_rev = {}

    self.crow_enabled = false
    self.crow_track_1 = 0
    self.crow_track_2 = 0
    self.clock_debug_enabled = false
    self.clock_debug_threshold_ms = 2
    self.clock_debug_buffer = nil
    self.clock_debug_log_handle = nil
    self.clock_debug_log_path = nil
    self.clock_debug_flush_metro = nil
    self.clock_debug_prev_internal_ms = nil
    self.clock_debug_prev_external_advance_ms = nil
    self.clock_debug_pending_ticks = 0
    self.clock_debug_tick_count = 0
    self.clock_debug_overrun_count = 0
    self.clock_debug_dt_samples = {}
    self.clock_debug_overrun_samples = {}
    self.clock_debug_hist = { [1] = 0, [2] = 0, [3] = 0, [4] = 0, [5] = 0 }

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
        self.track_rand_gate_prob[t] = 0
        self.track_rand_pitch_prob[t] = 0
        self.track_rand_pitch_span[t] = 0
        self.transpose_seq_assign[t] = (self.track_cfg[t].type ~= "drum")
        self.track_default_vel[t] = self:vel_to_midi(cfg.DEFAULT_VEL_LEVEL)
        self.track_gate_ticks[t] = (self.track_cfg[t].type == "drum") and self.drum_gate_clocks or
            self.melody_gate_clocks
        self.track_hold_tie_len_enabled[t] = true
    end

    for s = 1, cfg.NUM_STEPS do
        self.transpose_seq_steps[s] = { active = false, degree = 1 }
    end

    return self
end

include("lib/core/state").install(App)
include("lib/core/history").install(App)
include("lib/core/presets").install(App)
include("lib/core/clock_debug").install(App)
include("lib/sequencer/scale").install(App)
include("lib/sequencer/arc_pattern").install(App)
include("lib/sequencer/spice").install(App)
include("lib/sequencer/ratios").install(App)
include("lib/sequencer/randomization").install(App)
include("lib/sequencer/transpose_seq").install(App)
include("lib/sequencer/beat_repeat").install(App)
include("lib/io/midi").install(App)
include("lib/io/crow").install(App)
include("lib/io/transport").install(App)
include("lib/ui/screen").install(App)
include("lib/ui/grid_main").install(App)
include("lib/ui/grid_aux").install(App)
include("lib/ui/grid_input").install(App)
include("lib/ui/arc").install(App)
include("lib/core/misc").install(App)

return App
