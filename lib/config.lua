local M = {}

M.DEFAULT_TEMPO_BPM = 145
M.DEFAULT_VEL_LEVEL = 12
M.DEFAULT_MELODIC_BASE_NOTE = 48
M.DEFAULT_MASTER_SEQ_LEN = 128
M.MAX_MASTER_SEQ_LEN = 1024

M.NUM_TRACKS = 14
M.NUM_STEPS = 16
M.MOD_ROW = 16
M.DYN_ROW = 15

M.SCALES = {
  chromatic = { 0, 1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11 },
  diatonic = { 0, 2, 4, 5, 7, 9, 11 },
  pentatonic = { 0, 2, 4, 7, 9 },
  lightbath = { 0, 2, 7, 9 }
}

M.TRACK_CFG = {
  { type = "drum", ch = 8, note = 60 },
  { type = "drum", ch = 8, note = 61 },
  { type = "drum", ch = 7, note = 60 },
  { type = "drum", ch = 7, note = 61 },
  { type = "drum", ch = 7, note = 62 },
  { type = "drum", ch = 7, note = 63 },
  { type = "drum", ch = 7, note = 64 },
  { type = "drum", ch = 7, note = 65 },
  { type = "drum", ch = 7, note = 66 },
  { type = "drum", ch = 7, note = 67 },
  { type = "mono", ch = 5, note = 52 },
  { type = "mono", ch = 4, note = 52 },
  { type = "mono", ch = 3, note = 52 },
  { type = "poly", ch = 2, note = 52 }
}

M.MOD = {
  MUTE = 1,
  SOLO = 2,
  START = 3,
  END_STEP = 4,
  RAND_NOTES = 6,
  RAND_STEPS = 7,
  TEMP = 8,
  FILL = 9,
  SHIFT = 10,
  OCTAVE = 11,
  TRANSPOSE = 12,
  TAKEOVER = 13,
  CLEAR = 14,
  SPICE = 15,
  BEAT_RPT = 16
}

M.SPICE_MIN = -7
M.SPICE_MAX = 7

M.MIDI_CLOCK_TICKS_PER_STEP = 6

return M
