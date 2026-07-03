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
local lpp_map = include("lib/io/lpp_map")

local M = {}

function M.install(App)
    function App:get_selected_midi_ports(source_slots)
        local ports = {}
        local seen = {}
        for _, port in ipairs(source_slots or self.midi_port_slots or {}) do
            local midi_port = clamp(tonumber(port) or 0, 0, 16)
            if midi_port > 0 and not seen[midi_port] then
                ports[#ports + 1] = midi_port
                seen[midi_port] = true
            end
        end
        return ports
    end

    function App:get_selected_midi_in_ports()
        return self:get_selected_midi_ports(self.midi_in_port_slots)
    end

    function App:capture_midi_ports(ports)
        if type(ports) == "table" then return ports end
        return self.midi_out_ports_snapshot or self:get_selected_midi_ports()
    end

    function App:for_each_midi_device(ports, fn)
        local selected_ports = self:capture_midi_ports(ports)
        if selected_ports == self.midi_out_ports_snapshot and type(self.midi_devs_active) == "table" then
            for i = 1, #self.midi_devs_active do
                local active = self.midi_devs_active[i]
                if active and active.dev then
                    fn(active.dev, active.port)
                end
            end
            return selected_ports
        end

        for _, port in ipairs(selected_ports) do
            local dev = self.midi_devs[port]
            if dev then fn(dev, port) end
        end
        return selected_ports
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

    function App:midi_cc(cc, val, ch, ports)
        self:for_each_midi_device(ports, function(dev)
            pcall(function() dev:cc(cc, val, ch) end)
        end)
    end

    function App:midi_sysex(bytes, ports)
        if type(bytes) ~= "table" then return end
        self:for_each_midi_device(ports, function(dev)
            if dev.send then
                pcall(function() dev:send(bytes) end)
            elseif dev.sysex then
                pcall(function() dev:sysex(bytes) end)
            end
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

    function App:is_lpp_port(source_port)
        if not self.lpp_enabled then return false end
        local lpp_port = clamp(tonumber(self.lpp_input_port) or 0, 0, 16)
        return lpp_port > 0 and source_port == lpp_port
    end

    function App:lpp_identify_zone_from_note(note)
        return lpp_map.grid_note_to_zone[clamp(tonumber(note) or 0, 0, 127)]
    end

    function App:lpp_zone_target_track(zone)
        if zone == "zone_a" then return nil end
        local defaults = lpp_map.zone_track_defaults or {}
        local track = clamp(
            tonumber((self.lpp_zone_track or {})[zone]) or tonumber(defaults[zone]) or 1,
            1, cfg.NUM_TRACKS)
        return track
    end

    function App:lpp_zone_octave_label(zone)
        local labels = {
            zone_a = "drums",
            zone_b = "bass",
            zone_c = "lead1",
            zone_d = "lead2",
            zone_e = "chords"
        }
        return labels[zone] or tostring(zone or "")
    end

    function App:toggle_external_midi_record_mode()
        self.external_midi_record_mode = not self.external_midi_record_mode
        self:flash_mod_applied(cfg.MOD.TRANSPOSE, self.external_midi_record_mode and "midi rec on" or "midi rec off")
        if self.lpp_enabled then
            self:lpp_refresh_octave_leds()
        end
    end

    function App:lpp_track_can_double_length(track)
        local t = clamp(tonumber(track) or 1, 1, cfg.NUM_TRACKS)
        local tr = self:ensure_track_state(t)
        if not tr then return false end
        local lo, hi = self:get_track_bounds(tr)
        local len = hi - lo + 1
        return len < self:get_track_step_limit()
    end

    function App:lpp_track_can_half_length(track)
        local t = clamp(tonumber(track) or 1, 1, cfg.NUM_TRACKS)
        local tr = self:ensure_track_state(t)
        if not tr then return false end
        local lo, hi = self:get_track_bounds(tr)
        local len = hi - lo + 1
        return len > 1
    end

    function App:lpp_double_track_length(track)
        local t = clamp(tonumber(track) or 1, 1, cfg.NUM_TRACKS)
        local tr = self:ensure_track_state(t)
        local tc = self.track_cfg[t]
        if not tr or not tc then return false, nil end

        local start = clamp(tonumber(tr.start_step) or 1, 1, self:get_track_step_limit())
        local finish = clamp(tonumber(tr.end_step) or cfg.NUM_STEPS, 1, self:get_track_step_limit())
        local reverse = finish < start
        local lo, hi = self:get_track_bounds(tr)
        local len = hi - lo + 1
        if len <= 0 then return false, nil end

        local step_limit = self:get_track_step_limit()
        local max_len = reverse and start or (step_limit - start + 1)
        local new_len = math.min(len * 2, max_len)
        local copy_len = new_len - len
        if copy_len <= 0 then return false, len end

        self:push_undo_state("lpp_double_len")

        local function copy_step(src, dst)
            tr.gates[dst] = not not tr.gates[src]
            if tr.ties then tr.ties[dst] = not not tr.ties[src] end
            tr.vels[dst] = clamp(tonumber(tr.vels[src]) or cfg.DEFAULT_VEL_LEVEL, 1, 15)
            if tc.type == "poly" then
                if type(tr.pitches[src]) == "table" then
                    tr.pitches[dst] = deep_copy_table(tr.pitches[src])
                else
                    tr.pitches[dst] = { clamp(tonumber(tr.pitches[src]) or 1, cfg.MIN_SCALE_DEGREE, cfg.MAX_SCALE_DEGREE) }
                end
            elseif tc.type ~= "drum" then
                tr.pitches[dst] = clamp(tonumber(tr.pitches[src]) or 1, cfg.MIN_SCALE_DEGREE, cfg.MAX_SCALE_DEGREE)
            end

            if type(self.ratios[t]) == "table" then
                self.ratios[t][dst] = self.ratios[t][src] and deep_copy_table(self.ratios[t][src]) or nil
            end
            if type(self.spice[t]) == "table" then
                self.spice[t][dst] = self.spice[t][src] and deep_copy_table(self.spice[t][src]) or nil
            end
            if type(self.fill_patterns[t]) == "table" then
                self.fill_patterns[t][dst] = self.fill_patterns[t][src] and deep_copy_table(self.fill_patterns[t][src]) or nil
            end
        end

        for i = 0, copy_len - 1 do
            local src = reverse and (start - i) or (start + i)
            local dst = reverse and (start - len - i) or (start + len + i)
            if src < 1 or src > step_limit or dst < 1 or dst > step_limit then break end
            copy_step(src, dst)
        end

        if reverse then
            tr.end_step = clamp(start - new_len + 1, 1, step_limit)
        else
            tr.end_step = clamp(start + new_len - 1, 1, step_limit)
        end

        self:invalidate_step_cache(t)
        self:request_arc_redraw()
        self:request_redraw()
        self:request_aux_redraw()
        if self.lpp_enabled then self:lpp_refresh_octave_leds() end

        return true, new_len
    end

    function App:lpp_half_track_length(track)
        local t = clamp(tonumber(track) or 1, 1, cfg.NUM_TRACKS)
        local tr = self:ensure_track_state(t)
        if not tr then return false, nil end

        local step_limit = self:get_track_step_limit()
        local start = clamp(tonumber(tr.start_step) or 1, 1, step_limit)
        local finish = clamp(tonumber(tr.end_step) or cfg.NUM_STEPS, 1, step_limit)
        local reverse = finish < start
        local lo, hi = self:get_track_bounds(tr)
        local len = hi - lo + 1
        if len <= 1 then return false, len end

        local new_len = math.max(1, math.floor(len / 2))
        if new_len == len then return false, len end

        self:push_undo_state("lpp_half_len")

        if reverse then
            tr.end_step = clamp(start - new_len + 1, 1, step_limit)
        else
            tr.end_step = clamp(start + new_len - 1, 1, step_limit)
        end

        self:invalidate_step_cache(t)
        self:request_arc_redraw()
        self:request_redraw()
        self:request_aux_redraw()
        if self.lpp_enabled then self:lpp_refresh_octave_leds() end
        return true, new_len
    end

    function App:mark_recorded_step_skip_once(track, step)
        local t = clamp(tonumber(track) or 1, 1, cfg.NUM_TRACKS)
        local s = clamp(tonumber(step) or 1, 1, self:get_track_step_limit())
        if type(self.midi_record_skip_once) ~= "table" then self.midi_record_skip_once = {} end
        if type(self.midi_record_skip_once[t]) ~= "table" then self.midi_record_skip_once[t] = {} end
        self.midi_record_skip_once[t][s] = now_ms()
    end

    function App:get_recorded_step_skip_window_ms()
        local bpm = clamp(tonumber(self.tempo_bpm) or 120, 20, 300)
        local step_ms = (60 / bpm) * 1000 / 4
        return clamp(math.floor(step_ms * 1.25), 40, 220)
    end

    function App:consume_recorded_step_skip_once(track, step)
        local t = clamp(tonumber(track) or 1, 1, cfg.NUM_TRACKS)
        local s = clamp(tonumber(step) or 1, 1, self:get_track_step_limit())
        local by_track = type(self.midi_record_skip_once) == "table" and self.midi_record_skip_once[t] or nil
        if type(by_track) ~= "table" or not by_track[s] then return false end
        local stamped_at = tonumber(by_track[s]) or 0
        by_track[s] = nil
        local elapsed = math.max(0, now_ms() - stamped_at)
        return elapsed <= self:get_recorded_step_skip_window_ms()
    end

    function App:lpp_apply_zone_octave(zone, delta)
        if zone == "zone_a" then return end
        local amount = clamp(tonumber(delta) or 0, -1, 1)
        if amount == 0 then return end
        if type(self.lpp_zone_octave) ~= "table" then self.lpp_zone_octave = {} end
        local current = clamp(tonumber(self.lpp_zone_octave[zone]) or 0, self.lpp_octave_min, self.lpp_octave_max)
        local next_value = clamp(current + amount, self.lpp_octave_min, self.lpp_octave_max)
        if next_value == current then return end
        self.lpp_zone_octave[zone] = next_value
        self:flash_status(self:lpp_zone_octave_label(zone), "oct " .. tostring(next_value), 0.35)
        self:lpp_refresh_octave_leds()
    end

    function App:lpp_send_programmer_mode(enable)
        if not self.lpp_enabled then return end
        local lpp_port = clamp(tonumber(self.lpp_input_port) or 0, 0, 16)
        if lpp_port < 1 then return end
        local mode = enable and 1 or 0
        self:midi_sysex({ 240, 0, 32, 41, 2, 14, 14, mode, 247 }, { lpp_port })
    end

    function App:lpp_led_set(control_key, color, mode)
        if not self.lpp_enabled or not self.lpp_led_feedback then return end
        local lpp_port = clamp(tonumber(self.lpp_input_port) or 0, 0, 16)
        if lpp_port < 1 then return end
        local def = lpp_map.lpp_outer_controls[control_key]
        if type(def) ~= "table" then return end
        local id = clamp(tonumber(def.id) or 0, 0, 127)
        if id < 1 then return end
        local midi_ch = 1
        if mode == "flash" then
            midi_ch = 2
        elseif mode == "pulse" then
            midi_ch = 3
        end
        local palette = clamp(tonumber(color) or 0, 0, 127)
        if def.type == "cc" then
            self:midi_cc(id, palette, midi_ch, { lpp_port })
        else
            self:midi_note_on(id, palette, midi_ch, { lpp_port })
        end
    end

    function App:lpp_zone_grid_color(zone, col)
        local zone_colors = ((self.lpp_zone_melodic_colors or {})[zone]) or {}
        local fallback = (lpp_map.zone_melodic_colors or {})[zone] or {}
        local octave_color = clamp(tonumber(zone_colors.octave) or tonumber(fallback.octave) or 0, 0, 127)
        local note_color = clamp(tonumber(zone_colors.note) or tonumber(fallback.note) or 0, 0, 127)
        if col == 1 or col == 8 then return octave_color end
        return note_color
    end

    function App:lpp_refresh_octave_leds()
        if not self.lpp_enabled or not self.lpp_led_feedback then return end
        local lpp_port = clamp(tonumber(self.lpp_input_port) or 0, 0, 16)
        if lpp_port < 1 then return end

        local drum_page = clamp(tonumber(self.lpp_drum_page) or 1, 1, 2)
        for note, zone in pairs(lpp_map.grid_note_to_zone or {}) do
            local midi_note = clamp(tonumber(note) or 0, 0, 127)
            local col = midi_note % 10
            local color = 0
            if zone == "zone_a" then
                local track = col + ((drum_page - 1) * 8)
                local tc = self.track_cfg[track]
                local mapped = tc and tc.type == "drum" and track <= cfg.NUM_TRACKS
                color = mapped and clamp(tonumber((self.lpp_drum_track_colors or {})[col]) or 0, 0, 127) or 0
            else
                color = self:lpp_zone_grid_color(zone, col)
            end
            self:midi_note_on(midi_note, color, 1, { lpp_port })
        end

        for _, zone in ipairs({ "zone_b", "zone_c", "zone_d", "zone_e" }) do
            local offset = clamp(tonumber((self.lpp_zone_octave or {})[zone]) or 0, self.lpp_octave_min,
                self.lpp_octave_max)
            local down_key = zone .. "_oct_down"
            local up_key = zone .. "_oct_up"
            if offset > 0 then
                self:lpp_led_set(up_key, 21, "static")
                self:lpp_led_set(down_key, 1, "static")
            elseif offset < 0 then
                self:lpp_led_set(up_key, 1, "static")
                self:lpp_led_set(down_key, 45, "static")
            else
                self:lpp_led_set(up_key, 3, "static")
                self:lpp_led_set(down_key, 3, "static")
            end
        end

        self:lpp_led_set("zone_a_midi_record", self.external_midi_record_mode and 5 or 0, "static")
        self:lpp_led_set("zone_a_page_toggle", self.lpp_drum_page == 1 and 9 or 45, "static")
        self:lpp_led_set("zone_length_modifier", self.lpp_length_modifier_held and 15 or 1, "static")
        local zone_b_track = self:lpp_zone_target_track("zone_b")
        local zone_b_tc = zone_b_track and self.track_cfg[zone_b_track] or nil
        self:lpp_led_set("zone_b_clear_track", (zone_b_tc and zone_b_tc.type ~= "drum") and 21 or 1, "static")

        for i = 1, 8 do
            local track = i + ((self.lpp_drum_page - 1) * 8)
            local tc = self.track_cfg[track]
            local color = (tc and tc.type == "drum")
                and clamp(tonumber(self.lpp_clear_button_mapped_color) or 9, 0, 127)
                or clamp(tonumber(self.lpp_clear_button_unmapped_color) or 1, 0, 127)
            self:lpp_led_set("clear_drum_track_" .. tostring(i), color, "static")
            local can_resize = self.lpp_length_modifier_held
                and self:lpp_track_can_half_length(track)
                or self:lpp_track_can_double_length(track)
            self:lpp_led_set("duplicate_drum_track_" .. tostring(i), can_resize and 21 or 1, "static")
        end

        for _, zone in ipairs({ "zone_b", "zone_c", "zone_d", "zone_e" }) do
            local track = self:lpp_zone_target_track(zone)
            local can_resize = track and (self.lpp_length_modifier_held
                and self:lpp_track_can_half_length(track)
                or self:lpp_track_can_double_length(track))
            self:lpp_led_set(zone .. "_double_length", can_resize and 21 or 1, "static")
        end
    end

    function App:lpp_handle_control_action(control_key)
        if type(control_key) ~= "string" then return end

        if control_key == "zone_a_midi_record" then
            self:toggle_external_midi_record_mode()
            self:request_redraw()
            self:request_aux_redraw()
            return
        elseif control_key == "zone_a_page_toggle" then
            self.lpp_drum_page = (clamp(tonumber(self.lpp_drum_page) or 1, 1, 2) == 1) and 2 or 1
            self:flash_status("drums", "page " .. tostring(self.lpp_drum_page), 0.35)
            self:lpp_refresh_octave_leds()
            return
        end

        local clear_idx = string.match(control_key, "^clear_drum_track_(%d+)$")
        if clear_idx then
            local idx = clamp(tonumber(clear_idx) or 1, 1, 8)
            local track = idx + ((clamp(tonumber(self.lpp_drum_page) or 1, 1, 2) - 1) * 8)
            if track >= 1 and track <= cfg.NUM_TRACKS then
                local tc = self.track_cfg[track]
                if tc and tc.type == "drum" then
                    self:push_undo_state()
                    self.sel_track = track
                    self:clear_track(track)
                    self:flash_status("clear drum", tostring(track), 0.35)
                    self:lpp_refresh_octave_leds()
                end
            end
            return
        end

        local dup_idx = string.match(control_key, "^duplicate_drum_track_(%d+)$")
        if dup_idx then
            local idx = clamp(tonumber(dup_idx) or 1, 1, 8)
            local track = idx + ((clamp(tonumber(self.lpp_drum_page) or 1, 1, 2) - 1) * 8)
            if track >= 1 and track <= cfg.NUM_TRACKS then
                local tc = self.track_cfg[track]
                if tc and tc.type == "drum" then
                    local ok, new_len
                    if self.lpp_length_modifier_held then
                        ok, new_len = self:lpp_half_track_length(track)
                        self:flash_status("1/2 t" .. tostring(track), ok and (tostring(new_len) .. " steps") or "min", 0.45)
                    else
                        ok, new_len = self:lpp_double_track_length(track)
                        self:flash_status("x2 t" .. tostring(track), ok and (tostring(new_len) .. " steps") or "max", 0.45)
                    end
                end
            end
            return
        end

        local double_zone = string.match(control_key, "^(zone_[bcde])_double_length$")
        if double_zone then
            local track = self:lpp_zone_target_track(double_zone)
            if track then
                local ok, new_len
                if self.lpp_length_modifier_held then
                    ok, new_len = self:lpp_half_track_length(track)
                    if ok then
                        self:flash_status("1/2 t" .. tostring(track), tostring(new_len) .. " steps", 0.45)
                    else
                        self:flash_status("1/2 t" .. tostring(track), "min", 0.35)
                    end
                else
                    ok, new_len = self:lpp_double_track_length(track)
                    if ok then
                        self:flash_status("x2 t" .. tostring(track), tostring(new_len) .. " steps", 0.45)
                    else
                        self:flash_status("x2 t" .. tostring(track), "max", 0.35)
                    end
                end
            end
            return
        end

        local zone = string.match(control_key, "^(zone_[bcde])_")
        if zone then
            if control_key:sub(-7) == "_oct_up" then
                self:lpp_apply_zone_octave(zone, 1)
                return
            elseif control_key:sub(-9) == "_oct_down" then
                self:lpp_apply_zone_octave(zone, -1)
                return
            elseif control_key:sub(-12) == "_clear_track" then
                local track = self:lpp_zone_target_track(zone)
                local tc = track and self.track_cfg[track] or nil
                if track and tc and tc.type ~= "drum" then
                    self:push_undo_state()
                    self.sel_track = track
                    self:clear_track(track)
                    self:flash_status("clear", self:lpp_zone_octave_label(zone), 0.35)
                end
                return
            end
        end
    end

    function App:lpp_handle_control_message(message_type, id, value)
        local msg_type = message_type or ""
        local msg_id = tostring(clamp(tonumber(id) or 0, 0, 127))
        local key = lpp_map.lpp_outer_control_by_message[msg_type .. ":" .. msg_id]
        if not key then
            local fallback_type = (msg_type == "cc") and "note" or "cc"
            key = lpp_map.lpp_outer_control_by_message[fallback_type .. ":" .. msg_id]
        end
        if not key then return false end
        if key == "zone_length_modifier" then
            self.lpp_length_modifier_held = value > 0
            if self.lpp_enabled then self:lpp_refresh_octave_leds() end
            return true
        end
        if value <= 0 then return false end
        self:lpp_handle_control_action(key)
        return true
    end

    function App:lpp_track_for_note(note, zone)
        if zone == "zone_a" then
            local col = clamp(tonumber(note) or 0, 0, 127) % 10
            if col < 1 or col > 8 then return nil end
            local track = col + ((clamp(tonumber(self.lpp_drum_page) or 1, 1, 2) - 1) * 8)
            if track < 1 or track > cfg.NUM_TRACKS then return nil end
            if (self.track_cfg[track] or {}).type ~= "drum" then return nil end
            return track
        end
        return self:lpp_zone_target_track(zone)
    end

    function App:lpp_note_to_zone_degree(note, zone)
        local midi_note = clamp(tonumber(note) or 0, 0, 127)
        local col = midi_note % 10
        if col < 1 or col > 8 then return nil end

        if zone == "zone_b" then
            return col
        end

        local rows_by_zone = {
            zone_c = { 3, 4 },
            zone_d = { 5, 6 },
            zone_e = { 7, 8 }
        }
        local rows = rows_by_zone[zone]
        if not rows then return nil end

        local row = math.floor(midi_note / 10)
        for idx, row_ten in ipairs(rows) do
            if row == row_ten then
                return col + ((idx - 1) * 7)
            end
        end
        return nil
    end

    function App:handle_lpp_note_on(note, velocity, ch, source_port)
        local zone = self:lpp_identify_zone_from_note(note)
        if not zone then return false end
        local track = self:lpp_track_for_note(note, zone)
        if not track then return true end
        local tc = self.track_cfg[track]
        if not tc then return true end

        local output_ports = self:capture_midi_ports()
        local offset = clamp(tonumber((self.lpp_zone_octave or {})[zone]) or 0, self.lpp_octave_min, self.lpp_octave_max)
        local out_note = clamp(tonumber(note) or 0, 0, 127)
        if tc.type == "drum" then
            out_note = clamp(tonumber(tc.note) or 60, 0, 127)
        elseif zone ~= "zone_a" then
            local base_degree = self:lpp_note_to_zone_degree(note, zone)
            if base_degree then
                local degree_offset = offset * self:get_scale_degree_span()
                local degree = clamp(base_degree + degree_offset, cfg.MIN_SCALE_DEGREE, cfg.MAX_SCALE_DEGREE)
                out_note = self:get_pitch(track, degree, 0)
            end
        end
        local out_ch = clamp(tonumber(tc.ch) or 1, 1, 16)
        local vel = clamp(tonumber(velocity) or self:get_track_default_midi_velocity(track), 0, 127)

        self:midi_note_on(out_note, vel, out_ch, output_ports)
        self:trigger_crow(track, out_note)

        if source_port then
            if type(self.midi_in_active_notes[source_port]) ~= "table" then self.midi_in_active_notes[source_port] = {} end
            local input_ch = clamp(tonumber(ch) or 1, 1, 16)
            if type(self.midi_in_active_notes[source_port][input_ch]) ~= "table" then
                self.midi_in_active_notes[source_port][input_ch] = {}
            end
            self.midi_in_active_notes[source_port][input_ch][note] = {
                track = track,
                note = out_note,
                ch = out_ch,
                ports = output_ports
            }
        end

        self:record_midi_input_note(track, out_note, vel, true)
        return true
    end

    function App:handle_lpp_note_off(note, _velocity, ch, source_port)
        local zone = self:lpp_identify_zone_from_note(note)
        if not zone then return false end

        local channel = clamp(tonumber(ch) or 1, 1, 16)
        local input_note = clamp(tonumber(note) or 0, 0, 127)
        local note_state = nil
        if source_port and type(self.midi_in_active_notes[source_port]) == "table" then
            local by_channel = self.midi_in_active_notes[source_port][channel]
            if type(by_channel) == "table" then
                note_state = by_channel[input_note]
                by_channel[input_note] = nil
            end
        end
        if note_state then
            self:midi_note_off(note_state.note, 0, note_state.ch, note_state.ports)
            self:record_midi_input_note(note_state.track, note_state.note, 0, false)
        end
        return true
    end

    function App:midi_note_to_track_degree(track, midi_note)
        return self:note_to_nearest_degree(track, midi_note, nil, cfg.MIN_SCALE_DEGREE, cfg.MAX_SCALE_DEGREE)
    end

    function App:get_midi_in_target_track(ch, note)
        local channel = clamp(tonumber(ch) or 1, 1, 16)
        local input_note = clamp(tonumber(note) or 0, 0, 127)
        local auto_channel = clamp(tonumber(self.midi_in_auto_channel) or 16, 1, 16)

        if channel == auto_channel then
            return clamp(tonumber(self.sel_track) or 1, 1, cfg.NUM_TRACKS)
        end

        local drum_channel_has_mapping = false
        for t = 1, cfg.NUM_TRACKS do
            local tc = self.track_cfg[t]
            if tc and tc.type == "drum" and clamp(tonumber(tc.ch) or 1, 1, 16) == channel then
                drum_channel_has_mapping = true
                if clamp(tonumber(tc.note) or 60, 0, 127) == input_note then
                    return t
                end
            end
        end

        if drum_channel_has_mapping then
            return nil
        end

        for t = 1, cfg.NUM_TRACKS do
            local tc = self.track_cfg[t]
            if tc and tc.type ~= "drum" and clamp(tonumber(tc.ch) or 1, 1, 16) == channel then
                return t
            end
        end

        for t = 1, cfg.NUM_TRACKS do
            local tc = self.track_cfg[t]
            if tc and clamp(tonumber(tc.ch) or 1, 1, 16) == channel then
                return t
            end
        end

        return nil
    end

    function App:is_midi_record_mode_enabled()
        return self.playing and (self.realtime_play_mode or self.external_midi_record_mode)
    end

    function App:record_midi_input_note(track, note, velocity, is_note_on)
        if not self:is_midi_record_mode_enabled() then return end
        if not is_note_on and (self.track_cfg[track] or {}).type ~= "poly" then return end

        local t = clamp(tonumber(track) or 1, 1, cfg.NUM_TRACKS)
        local tr = self:ensure_track_state(t)
        local tc = self.track_cfg[t]
        local step = self:get_realtime_target_step(t)
        if not tr or not tc or not step then return end
        if is_note_on then
            self:mark_recorded_step_skip_once(t, step)
        end

        if tr.ties then tr.ties[step] = false end
        local vel_level = self:midi_to_vel_level(clamp(tonumber(velocity) or self:get_track_default_midi_velocity(t), 0,
            127))
        local degree = self:midi_note_to_track_degree(t, note)

        if tc.type == "drum" then
            if is_note_on then
                tr.gates[step] = true
                tr.vels[step] = vel_level
            end
        elseif tc.type == "poly" then
            if type(self.midi_in_record_holds[t]) ~= "table" then self.midi_in_record_holds[t] = {} end
            if is_note_on then
                self.midi_in_record_holds[t][note] = degree
            else
                self.midi_in_record_holds[t][note] = nil
                return
            end

            local chord = {}
            local seen = {}
            for _, held_degree in pairs(self.midi_in_record_holds[t]) do
                local d = clamp(tonumber(held_degree) or degree, cfg.MIN_SCALE_DEGREE, cfg.MAX_SCALE_DEGREE)
                if not seen[d] then
                    chord[#chord + 1] = d
                    seen[d] = true
                end
            end
            table.sort(chord)
            if #chord == 0 then chord[1] = degree end

            tr.gates[step] = true
            tr.vels[step] = vel_level
            tr.pitches[step] = chord
        else
            if is_note_on then
                tr.gates[step] = true
                tr.vels[step] = vel_level
                tr.pitches[step] = degree
            end
        end

        self:invalidate_step_cache(t)
        self:request_arc_redraw()
        self:request_redraw()
        self:request_aux_redraw()
    end

    function App:handle_midi_note_on(note, velocity, ch, source_port)
        local track = self:get_midi_in_target_track(ch, note)
        if not track then return end
        local tc = self.track_cfg[track]
        if not tc then return end

        local output_ports = self:capture_midi_ports()
        local out_note = clamp(tonumber(note) or 0, 0, 127)
        if tc.type == "drum" then
            out_note = clamp(tonumber(tc.note) or 60, 0, 127)
        end
        local out_ch = clamp(tonumber(tc.ch) or 1, 1, 16)
        local vel = clamp(tonumber(velocity) or self:get_track_default_midi_velocity(track), 0, 127)

        self:midi_note_on(out_note, vel, out_ch, output_ports)
        self:trigger_crow(track, out_note)

        if source_port then
            if type(self.midi_in_active_notes[source_port]) ~= "table" then self.midi_in_active_notes[source_port] = {} end
            local input_ch = clamp(tonumber(ch) or 1, 1, 16)
            if type(self.midi_in_active_notes[source_port][input_ch]) ~= "table" then
                self.midi_in_active_notes[source_port][input_ch] = {}
            end
            self.midi_in_active_notes[source_port][input_ch][note] = {
                track = track,
                note = out_note,
                ch = out_ch,
                ports = output_ports
            }
        end

        self:record_midi_input_note(track, note, vel, true)
    end

    function App:handle_midi_note_off(note, _velocity, ch, source_port)
        local channel = clamp(tonumber(ch) or 1, 1, 16)
        local input_note = clamp(tonumber(note) or 0, 0, 127)
        local note_state = nil

        if source_port and type(self.midi_in_active_notes[source_port]) == "table" then
            local by_channel = self.midi_in_active_notes[source_port][channel]
            if type(by_channel) == "table" then
                note_state = by_channel[input_note]
                by_channel[input_note] = nil
            end
        end

        if note_state then
            self:midi_note_off(note_state.note, 0, note_state.ch, note_state.ports)
            self:record_midi_input_note(note_state.track, input_note, 0, false)
        else
            local track = self:get_midi_in_target_track(channel, input_note)
            if track then self:record_midi_input_note(track, input_note, 0, false) end
        end
    end

    function App:handle_midi_message(data, source_port)
        local status = data[1] or 0
        local is_realtime = (status == 248) or (status == 250) or (status == 251) or (status == 252)
        local from_input_port = source_port and self.midi_in_active_ports and self.midi_in_active_ports[source_port] or
        false

        if is_realtime and source_port then
            if not self.midi_clock_in_port then
                self.midi_clock_in_port = source_port
            elseif self.midi_clock_in_port ~= source_port then
                return
            end
        end

        if status == 248 then
            if self.use_midi_clock and self.playing then
                self:on_external_clock_pulse()
                self:advance_clock_tick()
            end
            return
        elseif status == 250 then
            self:reset_playheads()
            self.playing = true
            self:reset_external_clock_sync()
            self:on_external_clock_pulse()
            if self.clock_debug_enabled then
                self:clock_debug_reset_state()
                self:clock_debug_log(string.format("[%s] start mode=external tempo=%s",
                    os.date("%H:%M:%S"),
                    tostring(self.tempo_bpm)))
            end
            self:request_redraw()
            self:request_aux_redraw()
            return
        elseif status == 251 then
            self.playing = true
            if self.clock_debug_enabled then
                self:clock_debug_reset_state()
                self:clock_debug_log(string.format("[%s] continue mode=external tempo=%s",
                    os.date("%H:%M:%S"),
                    tostring(self.tempo_bpm)))
            end
            self:request_redraw()
            self:request_aux_redraw()
            return
        elseif status == 252 then
            self.playing = false
            if self.transport_scheduler_id then
                clock.cancel(self.transport_scheduler_id)
                self.transport_scheduler_id = nil
            end
            self:clear_realtime_row_holds()
            self:stop_all_notes()
            self:request_redraw()
            self:request_aux_redraw()
            return
        end

        local status_high_nibble = math.floor(status / 16)
        if from_input_port and status_high_nibble >= 8 and status_high_nibble <= 14 then
            local channel = (status % 16) + 1
            local data2 = clamp(tonumber(data[2]) or 0, 0, 127)
            local value = clamp(tonumber(data[3]) or 0, 0, 127)

            if self:is_lpp_port(source_port) then
                if status_high_nibble == 11 then
                    if self:lpp_handle_control_message("cc", data2, value) then return end
                elseif status_high_nibble == 9 then
                    if value > 0 then
                        if self:handle_lpp_note_on(data2, value, channel, source_port) then return end
                    else
                        if self:handle_lpp_note_off(data2, 0, channel, source_port) then return end
                    end
                elseif status_high_nibble == 8 then
                    if self:handle_lpp_note_off(data2, value, channel, source_port) then return end
                end
            end

            if status_high_nibble == 9 then
                if value > 0 then
                    self:handle_midi_note_on(data2, value, channel, source_port)
                else
                    self:handle_midi_note_off(data2, 0, channel, source_port)
                end
            elseif status_high_nibble == 8 then
                self:handle_midi_note_off(data2, value, channel, source_port)
            end
        end

        local msg = midi.to_msg(data)
        local t = msg and msg.type
        if t == "start" then
            self:reset_playheads()
            self.playing = true
            self:reset_external_clock_sync()
            self:request_redraw()
            self:request_aux_redraw()
        elseif t == "continue" then
            self.playing = true
            self:request_redraw()
            self:request_aux_redraw()
        elseif t == "stop" then
            self.playing = false
            if self.transport_scheduler_id then
                clock.cancel(self.transport_scheduler_id)
                self.transport_scheduler_id = nil
            end
            self:clear_realtime_row_holds()
            self:stop_all_notes()
            self:request_redraw()
            self:request_aux_redraw()
        end
    end

    function App:bind_midi_device_event(port_id)
        local dev = self.midi_devs[port_id]
        if not dev then return end
        dev.event = function(data)
            local is_output_active = self.midi_active_ports and self.midi_active_ports[port_id]
            local is_input_active = self.midi_in_active_ports and self.midi_in_active_ports[port_id]
            if is_output_active or is_input_active then
                self:handle_midi_message(data, port_id)
            end
        end
    end

    function App:connect_midi_from_params()
        local slots = { 1, 0, 0, 0 }
        local input_slots = { 0, 0 }
        local auto_channel = 16
        local lpp_enabled = false
        local lpp_input_port = 0
        local lpp_auto_programmer = false
        local lpp_led_feedback = true

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

            local ok_in_1, port_in_1 = pcall(function() return params:get("permute_midi_in") end)
            if ok_in_1 and port_in_1 ~= nil then
                input_slots[1] = clamp((tonumber(port_in_1) or 1) - 1, 0, 16)
            end

            local ok_in_2, port_in_2 = pcall(function() return params:get("permute_midi_in_2") end)
            if ok_in_2 and port_in_2 ~= nil then
                input_slots[2] = clamp((tonumber(port_in_2) or 1) - 1, 0, 16)
            end

            local ok_auto_ch, auto_ch_param = pcall(function() return params:get("permute_midi_in_auto_ch") end)
            if ok_auto_ch and auto_ch_param ~= nil then
                auto_channel = clamp(tonumber(auto_ch_param) or 16, 1, 16)
            end

            local ok_lpp_enable, lpp_enable_param = pcall(function() return params:get("permute_lpp_enable") end)
            if ok_lpp_enable and lpp_enable_param ~= nil then
                lpp_enabled = tonumber(lpp_enable_param) == 2
            end

            local ok_lpp_port, lpp_port_param = pcall(function() return params:get("permute_lpp_input_port") end)
            if ok_lpp_port and lpp_port_param ~= nil then
                lpp_input_port = clamp((tonumber(lpp_port_param) or 1) - 1, 0, 16)
            end

            local ok_lpp_auto, lpp_auto_param = pcall(function() return params:get("permute_lpp_auto_programmer") end)
            if ok_lpp_auto and lpp_auto_param ~= nil then
                lpp_auto_programmer = tonumber(lpp_auto_param) == 2
            end

            local ok_lpp_led, lpp_led_param = pcall(function() return params:get("permute_lpp_led_feedback") end)
            if ok_lpp_led and lpp_led_param ~= nil then
                lpp_led_feedback = tonumber(lpp_led_param) == 2
            end
        end

        self.midi_port_slots = slots
        self.midi_in_port_slots = input_slots
        self.midi_in_auto_channel = auto_channel
        self.lpp_enabled = lpp_enabled
        self.lpp_input_port = lpp_input_port
        self.lpp_programmer_auto_enter = lpp_auto_programmer
        self.lpp_led_feedback = lpp_led_feedback
        self.midi_out_ports = self:get_selected_midi_ports()
        self.midi_in_ports = self:get_selected_midi_in_ports()
        self.midi_out_ports_snapshot = deep_copy_table(self.midi_out_ports)
        self.midi_in_ports_snapshot = deep_copy_table(self.midi_in_ports)
        self.midi_active_ports = {}
        self.midi_in_active_ports = {}
        self.midi_in_active_notes = {}
        self.midi_in_record_holds = {}
        self.midi_clock_in_port = nil
        self.midi_devs_active = {}

        local ports_to_bind = {}
        local seen = {}
        for _, port in ipairs(self.midi_out_ports) do
            if not seen[port] then
                ports_to_bind[#ports_to_bind + 1] = port
                seen[port] = true
            end
            self.midi_active_ports[port] = true
        end

        for _, port in ipairs(self.midi_in_ports) do
            if not seen[port] then
                ports_to_bind[#ports_to_bind + 1] = port
                seen[port] = true
            end
            self.midi_in_active_ports[port] = true
        end

        local lpp_port = clamp(tonumber(self.lpp_input_port) or 0, 0, 16)
        if self.lpp_enabled and lpp_port > 0 then
            if not seen[lpp_port] then
                ports_to_bind[#ports_to_bind + 1] = lpp_port
                seen[lpp_port] = true
            end
            self.midi_in_active_ports[lpp_port] = true
        end

        for _, port_id in ipairs(ports_to_bind) do
            if not self.midi_devs[port_id] then
                self.midi_devs[port_id] = midi.connect(port_id)
            end
            self:bind_midi_device_event(port_id)
        end

        for _, port_id in ipairs(self.midi_out_ports) do
            local dev = self.midi_devs[port_id]
            if dev then
                self.midi_devs_active[#self.midi_devs_active + 1] = { port = port_id, dev = dev }
            end
        end

        self.midi_dev = self.midi_devs[self.midi_out_ports[1]]

        if self.lpp_enabled and self.lpp_programmer_auto_enter then
            self:lpp_send_programmer_mode(true)
        end
        if self.lpp_enabled then
            self:lpp_refresh_octave_leds()
        end
    end
end

return M
