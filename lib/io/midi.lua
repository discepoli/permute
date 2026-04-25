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
        self.midi_out_ports_snapshot = deep_copy_table(self.midi_out_ports)
        self.midi_active_ports = {}
        self.midi_clock_in_port = nil
        self.midi_devs_active = {}

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
            local dev = self.midi_devs[port_id]
            if dev then
                self.midi_devs_active[#self.midi_devs_active + 1] = { port = port_id, dev = dev }
            end
        end

        self.midi_dev = self.midi_devs[self.midi_out_ports[1]]
    end

end

return M
