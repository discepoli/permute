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

    function App:midi_note_to_track_degree(track, midi_note)
        local target_note = clamp(tonumber(midi_note) or 0, 0, 127)
        local best_degree = 1
        local best_distance = 128
        for degree = cfg.MIN_SCALE_DEGREE, cfg.MAX_SCALE_DEGREE do
            local candidate = self:get_pitch(track, degree, 0)
            local distance = math.abs(candidate - target_note)
            if distance < best_distance then
                best_distance = distance
                best_degree = degree
            end
        end
        return best_degree
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

        if tr.ties then tr.ties[step] = false end
        local vel_level = self:midi_to_vel_level(clamp(tonumber(velocity) or self:get_track_default_midi_velocity(t), 0, 127))
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
        local from_input_port = source_port and self.midi_in_active_ports and self.midi_in_active_ports[source_port] or false

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
            self:request_aux_redraw()
            return
        elseif status == 251 then
            self.playing = true
            self:request_redraw()
            self:request_aux_redraw()
            return
        elseif status == 252 then
            self.playing = false
            self:clear_realtime_row_holds()
            self:stop_all_notes()
            self:request_redraw()
            self:request_aux_redraw()
            return
        end

        local status_high_nibble = math.floor(status / 16)
        if from_input_port and status_high_nibble >= 8 and status_high_nibble <= 14 then
            local channel = (status % 16) + 1
            local note = clamp(tonumber(data[2]) or 0, 0, 127)
            local velocity = clamp(tonumber(data[3]) or 0, 0, 127)
            if status_high_nibble == 9 then
                if velocity > 0 then
                    self:handle_midi_note_on(note, velocity, channel, source_port)
                else
                    self:handle_midi_note_off(note, 0, channel, source_port)
                end
            elseif status_high_nibble == 8 then
                self:handle_midi_note_off(note, velocity, channel, source_port)
            end
        end

        local msg = midi.to_msg(data)
        local t = msg and msg.type
        if t == "start" then
            self:reset_playheads()
            self.playing = true
            self:tick()
            self:request_redraw()
            self:request_aux_redraw()
        elseif t == "continue" then
            self.playing = true
            self:request_redraw()
            self:request_aux_redraw()
        elseif t == "stop" then
            self.playing = false
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
        end

        self.midi_port_slots = slots
        self.midi_in_port_slots = input_slots
        self.midi_in_auto_channel = auto_channel
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
    end

end

return M
