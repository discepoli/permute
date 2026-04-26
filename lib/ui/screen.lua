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

    function App:get_screen_canvas_size()
        return 128, 64
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
            return
        end
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

    function App:redraw_rate(fps)
        local rate = math.max(10, math.min(60, fps or 30))
        self.redraw_min_ms = math.floor(1000 / rate)
        if self.grid_timer then self.grid_timer.time = 1 / rate end
    end

end

return M
