local M = {}

M.zone_track_defaults = {
    zone_b = 11,
    zone_c = 12,
    zone_d = 13,
    zone_e = 14
}

M.zone_keys = { "zone_b", "zone_c", "zone_d", "zone_e" }

M.grid_note_to_zone = {}
for note = 11, 18 do
    M.grid_note_to_zone[note] = "zone_a"
end
for note = 21, 28 do
    M.grid_note_to_zone[note] = "zone_b"
end
for note = 31, 48 do
    M.grid_note_to_zone[note] = "zone_c"
end
for note = 51, 68 do
    M.grid_note_to_zone[note] = "zone_d"
end
for note = 71, 88 do
    M.grid_note_to_zone[note] = "zone_e"
end

M.lpp_outer_controls = {
    zone_e_clear_track = { type = "cc", id = 80 },
    zone_e_oct_down = { type = "cc", id = 70 },
    zone_e_oct_up = { type = "cc", id = 79 },

    zone_d_clear_track = { type = "cc", id = 60 },
    zone_d_oct_down = { type = "cc", id = 50 },
    zone_d_oct_up = { type = "cc", id = 59 },

    zone_c_clear_track = { type = "cc", id = 40 },
    zone_c_oct_down = { type = "cc", id = 30 },
    zone_c_oct_up = { type = "cc", id = 39 },

    zone_b_oct_down = { type = "cc", id = 20 },
    zone_b_oct_up = { type = "cc", id = 29 },
    zone_b_clear_track = { type = "cc", id = 97 },
    zone_b_double_length = { type = "cc", id = 98 },

    zone_a_midi_record = { type = "cc", id = 10 },
    zone_a_page_toggle = { type = "cc", id = 19 },
    zone_length_modifier = { type = "cc", id = 90 },

    zone_c_double_length = { type = "cc", id = 49 },
    zone_d_double_length = { type = "cc", id = 69 },
    zone_e_double_length = { type = "cc", id = 89 },

    clear_drum_track_1 = { type = "cc", id = 101 },
    clear_drum_track_2 = { type = "cc", id = 102 },
    clear_drum_track_3 = { type = "cc", id = 103 },
    clear_drum_track_4 = { type = "cc", id = 104 },
    clear_drum_track_5 = { type = "cc", id = 105 },
    clear_drum_track_6 = { type = "cc", id = 106 },
    clear_drum_track_7 = { type = "cc", id = 107 },
    clear_drum_track_8 = { type = "cc", id = 108 },

    duplicate_drum_track_1 = { type = "cc", id = 1 },
    duplicate_drum_track_2 = { type = "cc", id = 2 },
    duplicate_drum_track_3 = { type = "cc", id = 3 },
    duplicate_drum_track_4 = { type = "cc", id = 4 },
    duplicate_drum_track_5 = { type = "cc", id = 5 },
    duplicate_drum_track_6 = { type = "cc", id = 6 },
    duplicate_drum_track_7 = { type = "cc", id = 7 },
    duplicate_drum_track_8 = { type = "cc", id = 8 },
}

M.lpp_outer_control_by_message = {}
for key, def in pairs(M.lpp_outer_controls) do
    if def and def.type and def.id then
        M.lpp_outer_control_by_message[def.type .. ":" .. tostring(def.id)] = key
    end
end

M.known = {
    left_side_cc = { 10, 20, 30, 40, 50, 60, 70, 80, 90 },
    right_side_cc = { 19, 29, 39, 49, 59, 69, 79, 89 },
    top_cc = { 91, 92, 93, 94, 95, 96, 97, 98 },
    bottom_cc = { 1, 2, 3, 4, 5, 6, 7, 8 },
    scene_cc = { 101, 102, 103, 104, 105, 106, 107, 108 },
    logo_cc = 99,
}

M.zone_melodic_colors = {
    zone_b = { rows = { 2 }, octave = 7, note = 5 },
    zone_c = { rows = { 3, 4 }, octave = 108, note = 60 },
    zone_d = { rows = { 5, 6 }, octave = 13, note = 9 },
    zone_e = { rows = { 7, 8 }, octave = 71, note = 3 },
}

M.drum_palette_by_note = {
    [11] = 94,
    [12] = 21,
    [13] = 16,
    [14] = 13,
    [15] = 61,
    [16] = 8,
    [17] = 108,
    [18] = 4,
}

M.syx_palette_by_note = {}
for note, color in pairs(M.drum_palette_by_note) do
    M.syx_palette_by_note[note] = color
end

for _, zone in ipairs(M.zone_keys) do
    local zone_colors = M.zone_melodic_colors[zone]
    if zone_colors and type(zone_colors.rows) == "table" then
        for _, row in ipairs(zone_colors.rows) do
            for col = 1, 8 do
                local note = (row * 10) + col
                local color = (col == 1 or col == 8) and zone_colors.octave or zone_colors.note
                M.syx_palette_by_note[note] = color
            end
        end
    end
end

return M
