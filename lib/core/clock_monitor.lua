local H = include("lib/core/util")
local ensure_dir = H.ensure_dir

local M = {}

local REALTIME_NAMES = {
    [248] = "clock",
    [250] = "start",
    [251] = "continue",
    [252] = "stop",
}

local function current_ms()
    return math.floor(((util and util.time and util.time()) or 0) * 1000)
end

local function memory_kb()
    return collectgarbage("count")
end

local function port_label(port)
    return port and tostring(port) or "unknown"
end

function M.install(App)
    function App:clock_monitor_reset_state()
        local now = current_ms()
        self.clock_monitor_last_realtime_status = nil
        self.clock_monitor_last_realtime_port = nil
        self.clock_monitor_last_realtime_ms = nil
        self.clock_monitor_last_external_pulse_ms = nil
        self.clock_monitor_last_periodic_ms = now
        self.clock_monitor_last_memory_check_ms = now
        self.clock_monitor_last_memory_kb = memory_kb()
        self.clock_monitor_last_subtick_generation = tonumber(self.external_clock_subtick_generation) or 0
        self.clock_monitor_last_subtick_rate_ms = now
        self.clock_monitor_transport_error_count = 0
        self.clock_monitor_no_pulse_alerted = false
        self.clock_monitor_last_playing = not not self.playing
        self.clock_monitor_last_playing_change_ms = now
    end

    function App:clock_monitor_log(line)
        if not self.clock_monitor_enabled then return end
        self.clock_monitor_buffer = self.clock_monitor_buffer or {}
        local b = self.clock_monitor_buffer
        b[#b + 1] = line
        if #b > 200 then
            table.remove(b, 1)
        end
    end

    function App:_clock_monitor_flush()
        local h = self.clock_monitor_log_handle
        local b = self.clock_monitor_buffer
        if not h or not b or #b == 0 then return end
        h:write(table.concat(b, "\n") .. "\n")
        h:flush()
        for i = 1, #b do b[i] = nil end
    end

    function App:clock_monitor_record_realtime(status, source_port, accepted)
        if not self.clock_monitor_enabled then return end
        local now = current_ms()
        local code = tonumber(status) or 0
        self.clock_monitor_last_realtime_status = code
        self.clock_monitor_last_realtime_port = source_port
        self.clock_monitor_last_realtime_ms = now

        if accepted == false then
            if code == 252 then
                self:clock_monitor_log(string.format(
                    "[%s] ignored realtime stop status=252 port=%s",
                    os.date("%H:%M:%S"),
                    port_label(source_port)))
            end
            return
        end

        if code == 248 then
            self.clock_monitor_last_external_pulse_ms = now
            self.clock_monitor_no_pulse_alerted = false
        elseif code == 252 then
            self:clock_monitor_log(string.format(
                "[%s] received stop status=252 port=%s playing=%s",
                os.date("%H:%M:%S"),
                port_label(source_port),
                tostring(self.playing)))
        end
    end

    function App:clock_monitor_set_playing(playing, reason, source_port)
        if not self.clock_monitor_enabled then return end
        local next_playing = not not playing
        if self.clock_monitor_last_playing == next_playing then return end
        self.clock_monitor_last_playing = next_playing
        self.clock_monitor_last_playing_change_ms = current_ms()
        self:clock_monitor_log(string.format(
            "[%s] playing=%s reason=%s port=%s last_status=%s",
            os.date("%H:%M:%S"),
            tostring(next_playing),
            tostring(reason or "unknown"),
            port_label(source_port),
            tostring(self.clock_monitor_last_realtime_status or "none")))
    end

    function App:clock_monitor_add_transport_error(err)
        if not self.clock_monitor_enabled then return end
        self.clock_monitor_transport_error_count = (tonumber(self.clock_monitor_transport_error_count) or 0) + 1
        self:clock_monitor_log(string.format(
            "[%s] transport error count=%d err=%s",
            os.date("%H:%M:%S"),
            self.clock_monitor_transport_error_count,
            tostring(err or "")))
    end

    function App:clock_monitor_poll()
        if not self.clock_monitor_enabled then return end
        local now = current_ms()
        local pulse_ms = tonumber(self.clock_monitor_last_external_pulse_ms)
        local since_pulse = pulse_ms and (now - pulse_ms) or nil

        if self.playing and self.use_midi_clock and not self.clock_monitor_no_pulse_alerted then
            local idle_ms = since_pulse
            if not idle_ms then
                local start_ms = tonumber(self.clock_monitor_last_playing_change_ms) or now
                idle_ms = now - start_ms
            end
            if idle_ms > 500 then
                self.clock_monitor_no_pulse_alerted = true
                self:clock_monitor_log(string.format(
                    "[%s] no external pulse for %dms while playing last_status=%s port=%s",
                    os.date("%H:%M:%S"),
                    math.floor(idle_ms + 0.5),
                    tostring(self.clock_monitor_last_realtime_status or "none"),
                    port_label(self.clock_monitor_last_realtime_port)))
            end
        end

        local memory_check_ms = tonumber(self.clock_monitor_last_memory_check_ms) or now
        if now - memory_check_ms >= 1000 then
            local mem = memory_kb()
            local prev = tonumber(self.clock_monitor_last_memory_kb) or mem
            local threshold = tonumber(self.clock_monitor_memory_jump_kb) or 512
            if mem - prev > threshold then
                self:clock_monitor_log(string.format(
                    "[%s] memory jump %.1fKB -> %.1fKB delta=%.1fKB",
                    os.date("%H:%M:%S"),
                    prev,
                    mem,
                    mem - prev))
            end
            self.clock_monitor_last_memory_kb = mem
            self.clock_monitor_last_memory_check_ms = now
        end

        local periodic_ms = tonumber(self.clock_monitor_last_periodic_ms) or now
        if now - periodic_ms < 10000 then return end

        local elapsed = math.max((now - (tonumber(self.clock_monitor_last_subtick_rate_ms) or now)) / 1000, 0.001)
        local generation = tonumber(self.external_clock_subtick_generation) or 0
        local last_generation = tonumber(self.clock_monitor_last_subtick_generation) or generation
        local subtick_rate = (generation - last_generation) / elapsed
        local status = tonumber(self.clock_monitor_last_realtime_status) or 0
        local status_name = REALTIME_NAMES[status] or tostring(status == 0 and "none" or status)
        local pulse_age = since_pulse and tostring(math.floor(since_pulse + 0.5)) or "none"

        self:clock_monitor_log(string.format(
            "[%s] monitor status=%s(%s) port=%s playing=%s pulse_age_ms=%s mem_kb=%.1f note_offs=%d scheduled_ons=%d subtick_gen=%d subtick_rate=%.1f/s errors=%d",
            os.date("%H:%M:%S"),
            tostring(status_name),
            tostring(status == 0 and "none" or status),
            port_label(self.clock_monitor_last_realtime_port),
            tostring(self.playing),
            pulse_age,
            memory_kb(),
            #(self.active_note_offs or {}),
            #(self.active_scheduled_note_ons or {}),
            generation,
            subtick_rate,
            tonumber(self.clock_monitor_transport_error_count) or 0))

        self.clock_monitor_last_periodic_ms = now
        self.clock_monitor_last_subtick_generation = generation
        self.clock_monitor_last_subtick_rate_ms = now
    end

    function App:set_clock_monitor_enabled(enabled)
        local next_enabled = not not enabled
        if self.clock_monitor_enabled == next_enabled then return end

        if next_enabled then
            self.clock_monitor_enabled = true
            ensure_dir(self:preset_dir())
            local stamp = os.date("%Y%m%d-%H%M%S")
            self.clock_monitor_log_path = self:preset_dir() .. "transport-monitor-" .. stamp .. ".log"
            self.clock_monitor_log_handle = io.open(self.clock_monitor_log_path, "a")
            self.clock_monitor_buffer = {}
            self:clock_monitor_reset_state()
            self:clock_monitor_log(string.format(
                "[%s] transport monitor enabled mode=%s mem_kb=%.1f",
                os.date("%Y-%m-%d %H:%M:%S"),
                self.use_midi_clock and "external" or "internal",
                memory_kb()))
            self.clock_monitor_flush_metro = metro.init(function()
                self:_clock_monitor_flush()
            end, 1, -1)
            self.clock_monitor_flush_metro:start()
            return
        end

        self:clock_monitor_poll()
        if self.clock_monitor_flush_metro then
            self.clock_monitor_flush_metro:stop()
            self.clock_monitor_flush_metro = nil
        end
        self:_clock_monitor_flush()
        if self.clock_monitor_log_handle then
            self.clock_monitor_log_handle:close()
        end
        self.clock_monitor_log_handle = nil
        self.clock_monitor_buffer = nil
        self.clock_monitor_enabled = false
    end
end

return M
