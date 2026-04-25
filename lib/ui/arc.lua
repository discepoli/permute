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
            self:invalidate_step_cache(t)
            if label and value then self:flash_status(label, value, 0.3) end
            self:request_arc_redraw()
            self:request_redraw()
            if t == self.sel_track then self:request_aux_redraw() end
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

    function App:grid_led_on(dev, x, y, level)
        if dev then dev:led(x, y, level) end
    end

    function App:grid_led_main(x, y, level)
        self:grid_led_on(self.main_grid_dev, x, y, level)
    end

    function App:grid_led(a, b, c, d)
        if d == nil then
            return self:grid_led_main(a, b, c)
        end
        return self:grid_led_on(a, b, c, d)
    end

    function App:request_arc_redraw()
        self.arc_dirty = true
    end

    function App:request_aux_redraw()
        self.aux_grid_dirty = true
    end

    function App:request_redraw()
        self.screen_dirty = true
        self.grid_dirty = true
        if not self.playing then self.arc_dirty = true end
    end

end

return M
