local Icons = {}

local function line(x1, y1, x2, y2)
  screen.move(x1, y1)
  screen.line(x2, y2)
  screen.stroke()
end

local function circle_stroke(x, y, r)
  screen.circle(x, y, r)
  screen.stroke()
end

local function draw_mute(cx, cy, fg, dim)
  screen.level(fg)
  screen.move(cx - 18, cy + 4)
  screen.line(cx - 8, cy + 4)
  screen.line(cx - 2, cy + 10)
  screen.line(cx - 2, cy - 10)
  screen.line(cx - 8, cy - 4)
  screen.line(cx - 18, cy -4)
  screen.close()
  screen.stroke()
  screen.level(dim)
  screen.arc(cx + 2, cy, 6, -0.8, 0.8)
  screen.stroke()
  screen.arc(cx + 2, cy, 10, -0.8, 0.8)
  screen.stroke()
  screen.level(fg)
  line(cx - 14, cy + 12, cx + 10, cy - 12)
end

local function draw_solo(cx, cy, fg, dim)
  screen.level(fg)
  screen.move(cx - 18, cy + 4)
  screen.line(cx - 8, cy + 4)
  screen.line(cx - 2, cy + 10)
  screen.line(cx - 2, cy - 10)
  screen.line(cx - 8, cy - 4)
  screen.line(cx - 18, cy -4)
  screen.close()
  screen.stroke()
  screen.arc(cx + 2, cy, 6, -0.8, 0.8)
  screen.stroke()
  screen.arc(cx + 2, cy, 10, -0.8, 0.8)
  screen.stroke()
  screen.arc(cx + 2, cy, 14, -0.8, 0.8)
  screen.stroke()
end

local function draw_traffic(cx, cy, fg, dim, top_on, bottom_on)
  screen.level(fg)
  screen.rect(cx - 8, cy - 18, 16, 36)
  screen.stroke()

  screen.level(top_on and fg or dim)
  screen.circle(cx, cy - 10, 4)
  if top_on then screen.fill() else screen.stroke() end

  screen.level(dim)
  screen.circle(cx, cy, 4)
  screen.stroke()

  screen.level(bottom_on and fg or dim)
  screen.circle(cx, cy + 10, 4)
  if bottom_on then screen.fill() else screen.stroke() end
end

local function draw_track_select(cx, cy, fg, dim, state)
  screen.level(fg)
  screen.move(cx - 12, cy - 16)
  screen.line(cx - 2, cy + 10)
  screen.line(cx + 4, cy + 4)
  screen.line(cx + 8, cy + 14)
  screen.line(cx + 13, cy + 12)
  screen.line(cx + 8, cy + 2)
  screen.line(cx + 15, cy + 2)
  screen.close()
  screen.stroke()
end

local function draw_rand_notes(cx, cy, fg, dim, state)
  local kx = cx - 24
  local ky = cy - 8

  screen.level(fg)
  screen.rect(kx, ky, 15, 16)
  screen.stroke()
  line(kx + 5, ky, kx + 5, ky + 16)
  line(kx + 10, ky, kx + 10, ky + 16)

  screen.rect(kx + 3, ky, 3, 8)
  screen.fill()
  screen.rect(kx + 8, ky, 3, 8)
  screen.fill()

  screen.rect(cx + 8, cy - 8, 16, 16)
  screen.stroke()
  local rolled = state and state.rand_notes_rolled
  screen.level(dim)
  if rolled then
    screen.circle(cx + 12, cy - 4, 1)
    screen.fill()
    screen.circle(cx + 20, cy + 4, 1)
    screen.fill()
  else
    screen.circle(cx + 12, cy - 4, 1)
    screen.fill()
    screen.circle(cx + 16, cy, 1)
    screen.fill()
    screen.circle(cx + 20, cy + 4, 1)
    screen.fill()
  end
end

local function draw_rand_steps(cx, cy, fg, dim, state)
  local mixed = state and state.rand_steps_shuffled
  screen.level(fg)
  if mixed then
    screen.rect(cx - 20, cy + 6, 8, 4)
    screen.stroke()
    screen.rect(cx - 10, cy - 2, 8, 4)
    screen.stroke()
    screen.rect(cx + 0, cy + 2, 8, 4)
    screen.stroke()
    screen.rect(cx + 10, cy - 10, 8, 4)
    screen.stroke()
  else
    screen.rect(cx - 20, cy + 8, 8, 4)
    screen.stroke()
    screen.rect(cx - 10, cy + 2, 8, 4)
    screen.stroke()
    screen.rect(cx + 0, cy - 4, 8, 4)
    screen.stroke()
    screen.rect(cx + 10, cy - 10, 8, 4)
    screen.stroke()
  end
  screen.level(dim)
  line(cx - 22, cy + 14, cx + 22, cy + 14)
end

local function circle_stroke(cx, cy, r)
  -- Use move to jump the pen to the circle's starting point (right edge)
  screen.move(cx + r, cy)
  screen.circle(cx, cy, r)
  screen.stroke()
end

local function draw_temp(cx, cy, fg, dim)
  local r = 14
  screen.level(fg)
  circle_stroke(cx, cy, r)
  circle_stroke(cx, cy, r - 3)

  -- For rectangles, move to the top-left corner before drawing
  screen.move(cx - 7, cy - 23)
  screen.rect(cx - 7, cy - 23, 14, 4)
  screen.stroke()
  
  line(cx, cy - 19, cx, cy - 15)
  line(cx - 3, cy - 23, cx + 3, cy - 23)

  screen.move(cx - 14, cy - 14)
  screen.rect(cx - 14, cy - 14, 4, 4)
  screen.stroke()
  
  screen.move(cx + 10, cy - 14)
  screen.rect(cx + 10, cy - 14, 4, 4)
  screen.stroke()

  screen.level(dim)
  line(cx, cy - 11, cx, cy - 9)
  line(cx + 11, cy, cx + 9, cy)
  line(cx, cy + 11, cx, cy + 9)
  line(cx - 11, cy, cx - 9, cy)

  screen.level(fg)
  circle_stroke(cx, cy, 2)
  line(cx, cy, cx, cy - 6)
  line(cx, cy, cx + 6, cy + 5)
end



local function draw_fill(cx, cy, fg, dim, state)
  local y = cy + 2
  for i = 0, 3 do
    local x = cx - 22 + i * 12
    if i == 3 then
      screen.level(fg)
      screen.rect(x, y - 6, 10, 10)
      screen.fill()
    else
      screen.level(dim)
      screen.rect(x, y - 6, 10, 10)
      screen.stroke()
    end
  end
end

local function draw_shift(cx, cy, fg)
  screen.level(fg)
  screen.rect(cx - 20, cy - 10, 40, 20)
  screen.stroke()
  line(cx, cy - 6, cx, cy + 4)
  line(cx - 5, cy - 1, cx, cy - 6)
  line(cx + 5, cy - 1, cx, cy - 6)
end

local function draw_octave(cx, cy, fg, dim)
  local heights = { 12, 16, 20, 15, 10 }
  for i = 1, 5 do
    local x = cx - 16 + (i - 1) * 8
    local h = heights[i]
    screen.level(i == 3 and fg or dim)
    screen.rect(x, cy + 10 - h, 6, h)
    screen.stroke()
  end
end

local function draw_transpose(cx, cy, fg, dim)
  screen.level(dim)
  for i = -2, 2 do
    line(cx - 22, cy + i * 4, cx + 22, cy + i * 4)
  end
  screen.level(fg)
  screen.circle(cx - 8, cy + 2, 3)
  screen.fill()
  line(cx - 5, cy + 2, cx - 5, cy - 10)
  screen.circle(cx + 8, cy - 6, 3)
  screen.fill()
  line(cx + 11, cy - 6, cx + 11, cy - 18)
end

local function draw_takeover(cx, cy, fg, dim)
  local x0 = cx - 24
  local y0 = cy - 16
  local w = 48
  local h = 30
  screen.level(dim)
  screen.rect(x0, y0, w, h)
  screen.stroke()

  for i = 1, 5 do
    local x = x0 + i * 8
    line(x, y0, x, y0 + h)
  end
  for i = 1, 4 do
    local y = y0 + i * 6
    line(x0, y, x0 + w, y)
  end

  screen.level(fg)
  screen.rect(x0 + 0, y0 + 4, 32, 5)
  screen.fill()
  screen.rect(x0 + 8, y0 + 13, 32, 5)
  screen.fill()
  screen.rect(x0 + 16, y0 + 22, 32, 5)
  screen.fill()
end

local function draw_clear(cx, cy, fg, dim)
  screen.level(fg)
  screen.rect(cx - 16, cy - 16, 32, 5)
  screen.stroke()
  screen.rect(cx - 6, cy - 20, 12, 4)
  screen.stroke()

  screen.move(cx - 13, cy - 10)
  screen.line(cx + 13, cy - 10)
  screen.line(cx + 10, cy + 18)
  screen.line(cx - 10, cy + 18)
  screen.close()
  screen.stroke()

  screen.level(dim)
  line(cx - 5, cy - 4, cx - 5, cy + 14)
  line(cx, cy - 4, cx, cy + 14)
  line(cx + 5, cy - 4, cx + 5, cy + 14)
end

local function draw_spice(cx, cy, fg, dim)
  screen.level(fg)
  screen.rect(cx - 8, cy - 10, 16, 20)
  screen.stroke()
  screen.rect(cx - 6, cy - 14, 12, 4)
  screen.stroke()
  screen.level(dim)
  screen.circle(cx - 6, cy + 14, 1)
  screen.fill()
  screen.circle(cx - 2, cy + 16, 1)
  screen.fill()
  screen.circle(cx + 3, cy + 13, 1)
  screen.fill()
  screen.circle(cx + 7, cy + 15, 1)
  screen.fill()
end

local function draw_beat_repeat(cx, cy, fg, dim)
  local x0 = cx - 24
  local y0 = cy - 14
  local w = 48
  local h = 28

  -- outline
  screen.level(fg)
  screen.rect(x0, y0, w, h)
  screen.stroke()

  -- bar ends
  screen.rect(x0 , y0, 2, h)
  screen.fill()
  line(x0 + 5, y0, x0 + 5, y0 + h)
  screen.rect(x0 + w - 3, y0, 2, h)
  screen.fill()
  line(x0 + w - 5, y0, x0 + w - 5, y0 + h)

  line(x0, y0 + 9, x0 + w, y0 + 9)
  line(x0, y0 + 18, x0 + w, y0 + 18)

  screen.circle(x0 + 10, y0 + 6, 1)
  screen.fill()
  screen.circle(x0 + w - 10, y0 + 6, 1)
  screen.fill()
  screen.circle(x0 + 10, y0 + 13, 1)
  screen.fill()
  screen.circle(x0 + w - 10, y0 + 13, 1)
  screen.fill()
end

local function draw_random_sequence(cx, cy, fg, dim, state)
  local rolled = state and (state.rand_notes_rolled or state.rand_steps_shuffled)

  screen.level(fg)
  screen.rect(cx - 10, cy - 10, 20, 20)
  screen.stroke()

  screen.level(dim)
  if rolled then
    screen.circle(cx - 5, cy - 5, 1)
    screen.fill()
    screen.circle(cx + 5, cy + 5, 1)
    screen.fill()
  else
    screen.circle(cx - 5, cy - 5, 1)
    screen.fill()
    screen.circle(cx, cy, 1)
    screen.fill()
    screen.circle(cx + 5, cy + 5, 1)
    screen.fill()
  end
end

local function draw_clock_rate(cx, cy, fg, dim)
  screen.level(fg)
  line(cx - 18, cy - 8, cx - 8, cy + 8)
  line(cx - 8, cy - 8, cx - 18, cy + 8)

  line(cx + 2, cy, cx + 18, cy)
  screen.level(dim)
  screen.circle(cx + 10, cy - 7, 1)
  screen.fill()
  screen.circle(cx + 10, cy + 7, 1)
  screen.fill()
end

local DRAWERS = {
  [1] = draw_mute,
  [2] = draw_solo,
  [3] = function(cx, cy, fg, dim) draw_traffic(cx, cy, fg, dim, false, true) end,
  [4] = function(cx, cy, fg, dim) draw_traffic(cx, cy, fg, dim, true, false) end,
  [5] = draw_track_select,
  [6] = draw_rand_notes,
  [7] = draw_rand_steps,
  [8] = function(cx, cy, fg, dim, state)
    if state and state.temp_button_mode == "fill" then
      draw_fill(cx, cy, fg, dim, state)
    else
      draw_temp(cx, cy, fg, dim)
    end
  end,
  [9] = draw_clock_rate,
  [10] = draw_shift,
  [11] = draw_octave,
  [12] = draw_transpose,
  [13] = draw_takeover,
  [14] = draw_clear,
  [15] = draw_spice,
  [16] = draw_beat_repeat,
}

local SPECIAL = {
  random_sequence = draw_random_sequence,
  clock_rate = draw_clock_rate,
}

function Icons.draw(mod_id, cx, cy, fg, dim, state)
  local drawer = DRAWERS[mod_id]
  if not drawer then return false end
  drawer(cx, cy, fg, dim, state)
  return true
end

function Icons.draw_special(name, cx, cy, fg, dim, state)
  local drawer = SPECIAL[name]
  if not drawer then return false end
  drawer(cx, cy, fg, dim, state)
  return true
end

return Icons
