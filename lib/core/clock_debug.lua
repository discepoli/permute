local H = include("lib/core/util")
local ensure_dir = H.ensure_dir
local cfg = H.cfg

local M = {}

local function percentile(sorted, p)
    if type(sorted) ~= "table" or #sorted == 0 then return 0 end
    local idx = math.floor((p * (#sorted - 1)) + 1.5)
    if idx < 1 then idx = 1 end
    if idx > #sorted then idx = #sorted end
    return sorted[idx]
end

local function copy_sorted(values)
    local out = {}
    for i = 1, #(values or {}) do out[i] = values[i] end
    table.sort(out)
    return out
end

function M.install(App)
    function App:clock_debug_reset_state()
        self.clock_debug_prev_internal_ms = nil
        self.clock_debug_prev_external_advance_ms = nil
        self.clock_debug_pending_ticks = 0
        self.clock_debug_tick_count = 0
        self.clock_debug_overrun_count = 0
        self.clock_debug_dt_samples = {}
        self.clock_debug_overrun_samples = {}
        self.clock_debug_hist = { [1] = 0, [2] = 0, [3] = 0, [4] = 0, [5] = 0 }
        self.clock_debug_rate_counts = {}
        local now = ((util and util.time and util.time()) or 0) * 1000
        self.clock_debug_rate_start_ms = now
        self.clock_debug_rate_last_ms = now
    end

    function App:clock_debug_log(line)
        if not self.clock_debug_enabled then return end
        self.clock_debug_buffer = self.clock_debug_buffer or {}
        local b = self.clock_debug_buffer
        b[#b + 1] = line
        if #b > 2000 then
            table.remove(b, 1)
        end
    end

    function App:clock_debug_log_note_on(track, step, note, ch, vel)
        if not self.clock_debug_enabled or not self.clock_debug_note_events then return end
        local tick = tonumber(self.transport_clock) or 0
        local step_ticks = tonumber(cfg.MIDI_CLOCK_TICKS_PER_STEP) or 6
        local beat_ticks = step_ticks * 4
        self:clock_debug_log(string.format(
            "[%s] note_on tick=%.3f step_mod=%.3f beat_mod=%.3f track=%d counter=%d step=%d note=%d ch=%d vel=%d swing=%d profile=%s",
            os.date("%H:%M:%S"),
            tick,
            tick % step_ticks,
            tick % beat_ticks,
            tonumber(track) or 0,
            tonumber((self.track_steps or {})[track]) or 0,
            tonumber(step) or 0,
            tonumber(note) or 0,
            tonumber(ch) or 0,
            tonumber(vel) or 0,
            tonumber(self.global_swing_percent) or 50,
            tostring(self.global_swing_profile or "linear")))
    end

    function App:_clock_debug_flush()
        local h = self.clock_debug_log_handle
        local b = self.clock_debug_buffer
        if not h or not b or #b == 0 then return end
        h:write(table.concat(b, "\n") .. "\n")
        h:flush()
        for i = 1, #b do b[i] = nil end
    end

    function App:clock_debug_on_tick_start(t_start)
        self.clock_debug_tick_count = (tonumber(self.clock_debug_tick_count) or 0) + 1
        if self.clock_debug_count then
            self:clock_debug_count("transport", 1)
        end
        local prev = self.clock_debug_prev_internal_ms
        if prev then
            local dt = t_start - prev
            local ppqn = self.use_midi_clock and 24 or math.max(tonumber(self.transport_scheduler_ppqn) or 24, 24)
            local bpm = (self.use_midi_clock and tonumber(self.external_clock_bpm_estimate)) or
                tonumber(self.tempo_bpm) or 120
            local expected = 60000 / (bpm * ppqn)
            local thr = tonumber(self.clock_debug_threshold_ms) or 2
            local delta = dt - expected
            local dt_samples = self.clock_debug_dt_samples or {}
            dt_samples[#dt_samples + 1] = dt
            self.clock_debug_dt_samples = dt_samples
            if math.abs(delta) > thr then
                self:clock_debug_log(string.format(
                    "[%s] jitter dt=%.3f exp=%.3f d=%.3f",
                    os.date("%H:%M:%S"), dt, expected, delta))
            end
        end
        self.clock_debug_prev_internal_ms = t_start
    end

    function App:clock_debug_count(name, amount)
        if not self.clock_debug_enabled then return end
        local counts = self.clock_debug_rate_counts or {}
        counts[name] = (tonumber(counts[name]) or 0) + (tonumber(amount) or 1)
        self.clock_debug_rate_counts = counts
    end

    function App:clock_debug_maybe_write_rates(now_ms)
        if not self.clock_debug_enabled then return end
        local now = tonumber(now_ms) or (((util and util.time and util.time()) or 0) * 1000)
        local start = tonumber(self.clock_debug_rate_start_ms) or now
        local elapsed = (now - start) / 1000
        if elapsed < 5 then return end

        local c = self.clock_debug_rate_counts or {}
        local function rate(name)
            return (tonumber(c[name]) or 0) / math.max(elapsed, 0.001)
        end

        self:clock_debug_log(string.format(
            "[%s] rates transport=%.1f/s boundaries=%.1f/s hits=%.1f/s grid_redraw=%.1f/s aux_redraw=%.1f/s screen_redraw=%.1f/s request_redraw=%.1f/s request_aux_redraw=%.1f/s grid_dirty=%.1f/s",
            os.date("%H:%M:%S"),
            rate("transport"),
            rate("boundaries"),
            rate("track_hits"),
            rate("grid_redraw"),
            rate("aux_redraw"),
            rate("screen_redraw"),
            rate("request_redraw"),
            rate("request_aux_redraw"),
            rate("grid_dirty")))

        self.clock_debug_rate_counts = {}
        self.clock_debug_rate_start_ms = now
        self.clock_debug_rate_last_ms = now
    end

    function App:clock_debug_on_tick_end(total_ms)
        local thr = tonumber(self.clock_debug_threshold_ms) or 2
        local over_samples = self.clock_debug_overrun_samples or {}
        over_samples[#over_samples + 1] = total_ms
        self.clock_debug_overrun_samples = over_samples

        local hist = self.clock_debug_hist or {}
        if total_ms < 1 then
            hist[1] = (hist[1] or 0) + 1
        elseif total_ms < 2 then
            hist[2] = (hist[2] or 0) + 1
        elseif total_ms < 4 then
            hist[3] = (hist[3] or 0) + 1
        elseif total_ms < 8 then
            hist[4] = (hist[4] or 0) + 1
        else
            hist[5] = (hist[5] or 0) + 1
        end
        self.clock_debug_hist = hist

        if total_ms > thr then
            self.clock_debug_overrun_count = (tonumber(self.clock_debug_overrun_count) or 0) + 1
            self:clock_debug_log(string.format("[%s] overrun total=%.3fms", os.date("%H:%M:%S"), total_ms))
        end
    end

    function App:clock_debug_write_summary()
        self:clock_debug_maybe_write_rates(((util and util.time and util.time()) or 0) * 1000)
        local ticks = tonumber(self.clock_debug_tick_count) or 0
        local overruns = tonumber(self.clock_debug_overrun_count) or 0
        local dt_sorted = copy_sorted(self.clock_debug_dt_samples)
        local total_sorted = copy_sorted(self.clock_debug_overrun_samples)
        local hist = self.clock_debug_hist or {}

        self:clock_debug_log(string.format(
            "[%s] summary ticks=%d overruns=%d dt_ms(p50/p95/p99)=%.3f/%.3f/%.3f total_ms(p50/p95/p99)=%.3f/%.3f/%.3f",
            os.date("%Y-%m-%d %H:%M:%S"),
            ticks,
            overruns,
            percentile(dt_sorted, 0.50),
            percentile(dt_sorted, 0.95),
            percentile(dt_sorted, 0.99),
            percentile(total_sorted, 0.50),
            percentile(total_sorted, 0.95),
            percentile(total_sorted, 0.99)))
        self:clock_debug_log(string.format(
            "[%s] histogram total_ms <1=%d 1-2=%d 2-4=%d 4-8=%d >=8=%d",
            os.date("%Y-%m-%d %H:%M:%S"),
            hist[1] or 0,
            hist[2] or 0,
            hist[3] or 0,
            hist[4] or 0,
            hist[5] or 0))
    end

    function App:set_clock_debug_enabled(enabled)
        local next_enabled = not not enabled
        if self.clock_debug_enabled == next_enabled then return end

        if next_enabled then
            self.clock_debug_enabled = true
            ensure_dir(self:preset_dir())
            local stamp = os.date("%Y%m%d-%H%M%S")
            self.clock_debug_log_path = self:preset_dir() .. "clock-debug-" .. stamp .. ".log"
            self.clock_debug_log_handle = io.open(self.clock_debug_log_path, "a")
            self.clock_debug_buffer = {}
            self:clock_debug_reset_state()
            self:clock_debug_log(string.format(
                "[%s] clock debug enabled threshold=%.3fms mode=%s",
                os.date("%Y-%m-%d %H:%M:%S"),
                tonumber(self.clock_debug_threshold_ms) or 2,
                self.use_midi_clock and "external" or "internal"))
            self.clock_debug_flush_metro = metro.init(function()
                self:_clock_debug_flush()
            end, 0.25, -1)
            self.clock_debug_flush_metro:start()
            return
        end

        self:clock_debug_write_summary()
        if self.clock_debug_flush_metro then
            self.clock_debug_flush_metro:stop()
            self.clock_debug_flush_metro = nil
        end
        self:_clock_debug_flush()
        if self.clock_debug_log_handle then
            self.clock_debug_log_handle:close()
        end
        self.clock_debug_log_handle = nil
        self.clock_debug_buffer = nil
        self.clock_debug_enabled = false
    end
end

return M
