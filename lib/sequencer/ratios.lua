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
local SPEED_RATIOS = {
    { 8, 1 },
    { 6, 1 },
    { 4, 1 },
    { 3, 1 },
    { 2, 1 },
    { 1, 1 },
    { 1, 2 },
    { 1, 3 },
    { 1, 4 },
    { 1, 6 },
    { 1, 8 },
    { 1, 12 },
    { 1, 16 },
    { 1, 24 },
    { 1, 32 },
    { 1, 48 }
}

function M.install(App)
    function App:get_speed_ratio_label(mult, div)
        local m = clamp(tonumber(mult) or 1, 1, 8)
        local d = clamp(tonumber(div) or 1, 1, 64)
        if d == 1 then return tostring(m) .. "x" end
        return "1/" .. tostring(d)
    end

    function App:get_speed_ratio_for_column(x)
        local col = clamp(tonumber(x) or 6, 1, 16)
        local ratio = SPEED_RATIOS[col] or SPEED_RATIOS[6]
        return ratio[1], ratio[2]
    end

    function App:get_speed_column_for_ratio(mult, div)
        local m = clamp(tonumber(mult) or 1, 1, 8)
        local d = clamp(tonumber(div) or 1, 1, 64)
        for col = 1, #SPEED_RATIOS do
            local ratio = SPEED_RATIOS[col]
            if ratio[1] == m and ratio[2] == d then
                return col
            end
        end
        return 6
    end

    function App:is_power_of_two_speed_ratio(mult, div)
        local m = tonumber(mult) or 1
        local d = tonumber(div) or 1
        if m < 1 or d < 1 then return false end
        local function is_power_of_two(n)
            return n == 1 or (n % 2 == 0 and is_power_of_two(n / 2))
        end
        return is_power_of_two(m) and is_power_of_two(d)
    end

    function App:get_ratio_label()
        return tostring(clamp(tonumber(self.ratio_pending_position) or 1, 1, self.ratio_pending_cycle or 1))
            .. "/" .. tostring(self.ratio_pending_cycle or 1)
    end

    function App:set_ratio_cycle(cycle)
        self.ratio_pending_cycle = clamp(tonumber(cycle) or 1, 1, 8)
        self.ratio_pending_position = clamp(tonumber(self.ratio_pending_position) or 1, 1, self.ratio_pending_cycle)
    end

    function App:set_ratio_position(pos)
        self.ratio_pending_position = clamp(tonumber(pos) or 1, 1, self.ratio_pending_cycle or 1)
    end

    function App:apply_pending_ratio_to_step(track, step)
        if not self.ratios[track] then self.ratios[track] = {} end

        self.ratios[track][step] = {
            cycle = self.ratio_pending_cycle,
            position = clamp(tonumber(self.ratio_pending_position) or 1, 1, self.ratio_pending_cycle or 1)
        }
        return self:get_ratio_label()
    end

    function App:step_ratio_allows_play(track, step)
        local data = self.ratios[track] and self.ratios[track][step]
        if type(data) ~= "table" then return true end
        local cycle = clamp(tonumber(data.cycle) or 1, 1, 8)
        local loop_index = ((clamp(tonumber(self.track_loop_count[track]) or 1, 1, 999999) - 1) % cycle) + 1
        return loop_index == clamp(tonumber(data.position) or 1, 1, cycle)
    end

end

return M
