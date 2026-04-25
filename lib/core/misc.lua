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

    function App:is_temp_button_fill_mode()
        return self.temp_button_mode == "fill"
    end

    function App:get_temp_button_label()
        return self:is_temp_button_fill_mode() and "fill" or "temp"
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
        self.transpose_seq_clock_phase = 0
        self.transpose_seq_step = 1
    end

    function App:key(n, z)
        if z == 1 then
            self.key_held[n] = true
        else
            self.key_held[n] = nil
        end
        if z == 0 then return end

        if (n == 2 and self.key_held[3]) or (n == 3 and self.key_held[2]) then
            params:set("permute_ext_clock", self.use_midi_clock and 1 or 2)
            return
        end

        if n == 2 then
            if self.playing then self:stop() else self:start() end
        elseif n == 3 then
            self:queue_transport_align_on_next_beat()
            self:flash_status("reset", "next beat", 0.35)
        end
    end

    function App:enc(n, d)
        if n == 2 then
            params:delta("permute_tempo", d)
        elseif n == 3 then
            self.sel_track = clamp((self.sel_track or 1) + d, 1, cfg.NUM_TRACKS)
            self:request_arc_redraw()
            self:request_redraw()
            self:request_aux_redraw()
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
                self:redraw_main_grid()
                self.grid_dirty = false
            end
            if self.aux_grid_dirty then
                self:redraw_aux_grid()
                self.aux_grid_dirty = false
            end
            if self.screen_dirty and not self:is_menu_active() then
                self:redraw_screen()
                self.screen_dirty = false
            end
            if self.arc_dirty then
                self:redraw_arc()
                self.arc_dirty = false
            end
        end, 1 / 30, -1)
        self.grid_timer:start()

        self.gc_metro = metro.init(function()
            collectgarbage("step", 50)
        end, 1 / 30, -1)
        self.gc_metro:start()

        self:request_redraw()
    end

    function App:cleanup()
        self:stop()
        if self.grid_timer then self.grid_timer:stop() end
        if self.gc_metro then self.gc_metro:stop() end
        if self.clock_debug_enabled then self:set_clock_debug_enabled(false) end
        if self.arc_dev then
            self.arc_dev:all(0)
            self.arc_dev:refresh()
        end
    end

end

return M
