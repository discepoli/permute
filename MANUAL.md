# permute manual

permute is a 14-track MIDI sequencer for norns. A 16×16 grid is the primary interface. It supports a second 16×8 grid, a four-ring Arc, MIDI input and output, crow triggers, and Launchpad Pro Mk3 performance controls.

## Contents

- [Install and connect](#install-and-connect)
- [Start a pattern](#start-a-pattern)
- [Grid layouts](#grid-layouts)
- [Modifier row reference](#modifier-row-reference)
- [Dynamic row reference](#dynamic-row-reference)
- [Editing modes](#editing-modes)
- [Pattern slots](#pattern-slots)
- [External devices](#external-devices)
- [Parameters](#parameters)
- [Saved defaults and presets](#saved-defaults-and-presets)

## Install and connect

Install permute from the norns `SYSTEM > SCRIPTS` page:

```text
;install https://github.com/discepoli/permute
```

Connect a grid before launching the script. permute assigns connected grids automatically:

- One grid is the main grid.
- With two grids, a 16×8 grid becomes the auxiliary grid and the other grid becomes the main grid.
- If no 16×8 grid is connected, the first connected grid is the main grid.
- You can connect or disconnect grids while permute is running. The script reassigns them automatically.

For MIDI, connect your sound source to norns and select its port in `PARAMS > permute > clock + midi`. The first output port is always active. The next three output ports are optional. MIDI notes, clock, and transport go to every enabled output port.

## Start a pattern

1. Set the MIDI output port and each track's MIDI channel in `PARAMS`.
2. Press K2 to start the transport.
3. Press a pad in a track row to add a step. Press the pad again to remove it.
4. Hold a step and press the dynamic row to set its pitch or velocity.

Track 1 is the bottom row. Track 14 is the top row. The default configuration puts drum tracks on tracks 1-10, mono melodic tracks on 11-13, and a polyphonic track on 14.

K2 starts and stops the transport. K3 resets the transport. Hold K2 and press K3 to switch between internal and external MIDI clock. E2 changes tempo, and E3 selects a track.

Hold K1 and turn E2 to change global swing. Hold K1 and turn E3 to change the swing profile.

## Grid layouts

### Main 16×16 grid

Rows 1-14 show the 14 track lanes. Row 15 is the dynamic row. Row 16 is the modifier row. Columns 1-16 represent the current page's 16 steps.

On a normal track, a short tap adds or removes a gate. Hold an active step for at least 150 ms, then press another step in the same track row to fill the span between them. The copied span uses the first step's pitch and velocity. Enable or disable this behavior per track with `hold tie length`.

Drum tracks store a fixed MIDI note and a per-step velocity. Mono tracks store one scale degree per step. Poly tracks store one or more scale degrees per step. A split track has separate eight-step gate and pitch lanes in the same track row. See [Split tracks](#split-tracks).

### 128 grid

A 16×8 grid uses rows 1-6 for six visible tracks, row 7 for the dynamic row, and row 8 for modifiers. Track pages follow the selected track, so selecting tracks 1-6 shows those rows and selecting tracks 7-12 shows the next page. Tracks 13-14 appear when you select either track.

The 128 grid keeps the same columns and modifier behavior, but its smaller height changes takeover and transpose-sequencer layouts. It does not show the modifier-driven dynamic row while in takeover mode.

### Auxiliary 16×8 grid

The auxiliary grid always edits the selected track and its own page. Each column is one step. Its eight rows set velocity for a drum track or scale degrees for a melodic track. On a poly track, press multiple pads in a column to build a chord.

The auxiliary grid remains available while the main grid is in overview or takeover mode. Use `follow aux page` to move its page with playback, or `follow edit page` to make it follow the selected track's editing page.

## Modifier row reference

Hold a modifier, then press a track row or a step. Most modifiers select the touched track as the current track. The controls below work on the main grid, and their step-level effects also work on the auxiliary grid.

### Column 1: Mute

Hold **Mute** and press any pad in a track lane to toggle that track's mute state. A muted track keeps its pattern but sends no notes.

### Column 2: Solo

Hold **Solo** and press a track lane to toggle its solo state. When one or more tracks are soloed, all non-solo tracks are muted. Clear the last solo to restore all tracks.

### Column 3: Start

Hold **Start** and press a step to set the selected track's first playback step. The track playhead resets to that point. On a split track, the left half sets the gate-lane start and the right half sets the pitch-lane start.

While **Start** is held, the dynamic row selects a 16-step page for the selected track. This is how you reach steps beyond the first 16. On a split track, dynamic-row columns 1-8 set the gate-lane start and columns 9-16 set the pitch-lane start.

Hold **Shift + Start** to halve the selected track's current length. The start position stays fixed.

### Column 4: End

Hold **End** and press a step to set the selected track's last playback step. On a split track, the left half sets the gate-lane end and the right half sets the pitch-lane end.

While **End** is held, the dynamic row selects a page, the same way it does for **Start**. On a split track, it sets the two lane endpoints.

Hold **Shift + End** to double the selected track's current length, up to the 128-step limit. permute copies the current material into the new portion of the track.

### Column 5: Track Select

Hold **Track Select** and press a track row to make it the selected track without changing its steps. The selected track receives octave, transpose, Arc, and auxiliary-grid edits.

Double-tap **Track Select** to toggle focus mode. In focus mode, the first ordinary press on a different track selects it, and the next press edits a step. This prevents accidental edits while changing tracks.

### Column 6: Random Notes

Hold **Random Notes** and press a dynamic-row column to randomize the notes or velocities of active steps in the selected track. Higher columns apply a stronger change.

Hold **Shift + Random Notes** and choose a dynamic-row column to set a per-track probability and pitch span for ongoing note randomization. The selected column sets both: it becomes the chance that each active step changes and the maximum change in scale degrees.

Hold **Random Notes + Random Steps** and choose the dynamic row to randomize both pitch or velocity and gates at the same intensity.

### Column 7: Random Steps

Hold **Random Steps** and press a dynamic-row column to randomly redistribute active gates in the selected track. The column selects the density.

Hold **Shift + Random Steps** and choose a dynamic-row column to set the selected track's ongoing gate-randomization probability.

### Column 8: Temp, Fill, and pattern slots

The button in column 8 enters pattern-slot mode alone and performs Temp or Fill with Shift. `temp button mode` determines whether the Shift combination uses Temp or Fill.

Hold **Temp + Shift** and press an empty step to add a temporary gate. Temporary gates disappear when you release the combination. Existing gates remain. On melodic tracks, the regular grid position keeps the stored pitch; on the auxiliary grid or in takeover, the row you press chooses pitch or velocity.

Double-tap **Temp + Shift** to latch temporary mode. Double-tap it again to release the latch and clear all temporary gates.

Hold **Temp** without Shift to enter pattern-slot mode. Each track row now shows 16 pattern slots instead of steps. Press a slot to select it for that track. Press the current slot twice to copy its pattern, then press another slot in the same row to paste it. A slot stores the track's gates, pitches, velocities, ties, range, octave, speed, transpose, Arc settings, ratios, spice, and split-track data.

Set `temp button mode` to `fill` to use the Fill behavior below.

### Column 9: Ratios

Hold **Ratios** and set a ratio on the dynamic row. Columns 1-8 select the playback position. Columns 9-16 select a cycle length of 1-8 loops. Then press a step to assign that ratio. For example, position 2 in a cycle of 4 plays the step only on the second pass through the track.

On the main grid, assign a ratio to an existing or newly created step. On the auxiliary grid and in takeover, you also set the drum velocity or melodic degree while assigning it.

#### Fill with Column 8 + Shift

When `temp button mode` is `fill`, hold **Column 8 + Shift** and press steps to create fill-only notes. Fill notes play only while the combination is held or latched. Double-tap **Column 8 + Shift** to latch the fill, and double-tap again to turn it off.

On a regular track row, a fill copies the step's current pitch and default velocity. On the auxiliary grid or in takeover, the pad's row chooses its pitch or velocity. A split track supports fill gates in its gate lane.

### Column 10: Shift

**Shift** combines with other controls:

- **Shift + Start** halves the selected track's length.
- **Shift + End** doubles the selected track's length.
- **Shift + Random Notes** sets ongoing note-randomization probability and span.
- **Shift + Random Steps** sets ongoing gate-randomization probability.
- **Shift + Temp** activates Temp or Fill behavior.
- **Shift + Transpose** turns external MIDI recording on or off.
- **Shift + Takeover** turns realtime grid recording on or off.
- **Shift + Spice** undoes the last edit.
- **Shift + Beat Repeat** redoes the last undone edit.
- **Shift + Clear** clears every track or, when used in transpose-sequencer takeover, resets the transpose sequence.
- **Shift + Clear + another modifier** clears that modifier's data across all tracks.

### Column 11: Octave

Hold **Octave** and press a dynamic-row column to set the selected track's octave offset. Column 8 is zero. Columns 1-7 set -7 through -1 octaves, and columns 9-16 set +1 through +8 octaves.

Hold **Shift + Octave** and use the dynamic row to change the octave page used while editing notes. This moves the visible pitch window without changing the track's playback octave. On the auxiliary grid, the same combination changes that edit-octave page from its columns.

### Column 12: Transpose

Hold **Transpose** and choose a dynamic-row column to transpose the selected track. Column 8 is zero. The offset is in semitones or scale degrees, according to `transpose mode`.

Hold **Shift + Transpose** to turn external MIDI recording on or off. While transport is running, incoming MIDI notes are recorded into the selected or matched track at the current step.

### Column 13: Takeover

Press **Takeover** to enter or leave takeover mode for the selected track. The grid becomes a full-track editor:

- A drum track becomes a 15-level velocity display. Press a row in a column to add, move, or remove that step's velocity.
- A mono track becomes a pitch grid. Press a row in a column to set that step's scale degree.
- A poly track lets you add or remove several pitches in the same column.
- A split track uses its dedicated split editor.

The modifier row remains at the bottom. Most modifiers continue to work on the track. On a 16×16 grid, the dynamic row remains available for modifier actions. On a 128 grid, all seven rows above the modifier row are note or velocity rows.

Hold **Track Select + Takeover** to enter transpose-sequencer takeover. See [Transpose sequencer](#transpose-sequencer).

Hold **Shift + Takeover** to toggle realtime grid recording. Realtime mode uses each normal track row as a performance keyboard while transport runs. A drum track maps grid columns to velocity. A melodic track maps columns to scale degrees. Presses write and audition the current step. On a poly track, hold several columns to record a chord.

### Column 14: Clear

Hold **Clear** and press a track lane or any step in it to erase that track's pattern, fills, ratios, spice, randomization settings, and Arc state.

Hold **Clear + Shift** and press a track lane or step to clear every track.

Hold **Clear** and press another modifier to reset that modifier for the selected track. Hold **Clear + Shift** and press a modifier to reset it across all tracks. This supports mute, solo, start, end, octave, transpose, spice, fill, ratios, random-steps, and random-notes data.

### Column 15: Spice

Hold **Spice**, choose an amount on the dynamic row, then press playable steps to assign it. Column 8 is zero. Columns 1-7 select negative values, and columns 9-16 select positive values. Each time a spiced step plays, its pitch changes by the assigned amount and accumulates until it reaches the `spice accum min` or `spice accum max` limit.

Hold **Spice** without choosing a value, then press a step to remove its spice assignment. Spice applies to the pitch lane of a split track.

Hold **Shift + Spice** to undo.

### Column 16: Beat Repeat

Hold **Beat Repeat** and use the dynamic row to create a temporary repeat. Press the same selected length again to turn it off. By default, the 16 dynamic-row columns select repeat lengths of 1-16 steps.

Hold **Beat Repeat** and press a track lane to include or exclude it from the repeat. The selected repeat length is held only while Beat Repeat is held.

`b. repeat mode` changes the dynamic row:

- `full-row` maps all 16 columns to lengths 1-16.
- `one-handed` maps columns 13-16 to lengths 1, 2, 4, and 8.
- `step-select` uses two dynamic-row presses to set an inclusive start and end step. The repeat starts when the transport reaches the first selected step.

`b. repeat direction` reverses the left-to-right mapping.

Hold **Shift + Beat Repeat** to redo.

### Columns 3 + 4: Start + End speed mode

Hold **Start + End** to enter speed mode. Choose a dynamic-row column to set the selected track's clock ratio:

| Columns | Ratio |
| --- | --- |
| 1-6 | 8×, 6×, 4×, 3×, 2×, 1× |
| 7-16 | 1/2, 1/3, 1/4, 1/6, 1/8, 1/12, 1/16, 1/24, 1/32, 1/48 |

Release either modifier to leave speed mode.

## Dynamic row reference

The dynamic row changes meaning based on the held modifier. This priority order matters: pattern slots, Shift-randomization, ratios, octave, transpose, Start/End, randomization, beat repeat, speed, spice, then the held step's pitch or velocity editor.

Without a modifier, hold a step and press the dynamic row:

- On a drum track, columns 2-16 select velocity levels 1-15. Column 1 produces level 0 and is normally used to remove the step.
- On a mono track, columns 1-16 select a scale degree.
- On a poly track, columns 1-16 add or remove a scale degree from the chord.

The dynamic row is also the global pattern-slot selector while **Temp** is held. Its behavior is controlled by `slot dynamic mode`:

- `last` selects the requested slot when it exists for a track, otherwise uses that track's highest filled slot.
- `all` selects the requested slot for every track, creating blank patterns where needed.
- `only` changes only tracks that already have the requested slot.

## Editing modes

### Takeover mode

Takeover edits one selected track at full height. Press **Takeover** again to return to the track overview. Use **Track Select** first if you want to open a different track without changing its steps.

The selected track's page controls which group of 16 steps takeover displays. Hold **Start** or **End** and choose a dynamic-row page to change it. `follow edit page` can move that page with playback.

### Realtime mode

Realtime mode is intended for live input while the sequencer runs. Enable it with **Shift + Takeover**, then use each track row:

- Press any column in a drum track row to record the current step at a velocity derived from the column.
- Press a column in a mono track row to record and hear the corresponding scale degree.
- Hold multiple columns in a poly track row to record and hear a chord.

Realtime mode turns off regular takeover and transpose-sequencer takeover. It records only while the transport is running.

### Transpose sequencer

Hold **Track Select + Takeover** to open a 16-step transpose sequencer. It transposes assigned melodic tracks. Drum tracks cannot be assigned.

On a 16×16 grid:

- Rows 1-8 are the transpose-step pitch grid. Press a column and row to enable a transpose step and set its degree.
- Row 9 is unused.
- Row 10 sets the transpose-sequence clock ratio.
- Row 11 assigns tracks 1-14. Column 16 resets the sequence, immediately or at the next beat according to `reset timing`.
- Row 13 sets the key.
- Row 14 sets the scale rotation for non-chromatic scales.
- Row 15 sets the scale type.
- Row 16 is the modifier row.

On a 128 grid, the sequence is one row. Press a column to enable it, then use its dynamic row to choose degree 1-16. Row 2 sets clock ratio, row 3 assigns tracks and resets, row 4 selects key, row 5 selects scale rotation, row 6 selects scale type, row 7 selects the current step's degree, and row 8 is modifiers.

Hold one active transpose step and press another to fill the range between them with the first step's degree. Hold **Clear** and press a transpose step to disable it. Hold **Shift + Clear** to reset the entire transpose sequence.

### Split tracks

A split track has an eight-stage gate sequence in columns 1-8 and an eight-stage pitch sequence in columns 9-16. The gate lane controls whether each stage plays. The pitch lane sets each stage's scale degree.

Hold a gate stage and use the dynamic row:

- Columns 1-8 set the number of substeps.
- Columns 11-13 choose `triggered`, `ratchet`, or `held` playback.
- Column 15 turns pitch advance on.
- Column 16 turns pitch advance off.

Hold a pitch stage and use the dynamic row to choose its scale degree. Start and End set each lane's bounds independently. Temp and Fill affect the gate lane. Spice affects the pitch lane.

## Pattern slots

Pattern slots are per-track snapshots, not norns presets. Enter the mode by holding **Temp** without Shift.

Each track has 16 slots. Changing a track's steps saves its edits into the active slot before permute loads a different slot. Empty slots load as blank track patterns.

Use `slot switch timing` to decide when a selected slot becomes active:

- `immediate` changes it now and keeps its playhead within the new range.
- `bar-end` changes it when that track wraps.
- `master-end` changes all queued tracks when the master sequence ends. If master length is off, it falls back to `bar-end`.

Pattern slots are stored inside norns presets. See [Saved defaults and presets](#saved-defaults-and-presets).

## External devices

### MIDI clock and transport

Set `external midi clock` to `on` to advance permute from incoming MIDI clock. Choose the source with `midi in port` or `midi in port 2`. Configure `incoming clock ppqn` to match the sender's clock rate. `interp clock ppqn` sets the internal clock resolution used to interpolate it.

Incoming MIDI Start, Continue, and Stop start, resume, and stop permute. K3 also toggles between internal and external clock. Enable `send midi clock out` and `send midi start/stop out` to forward permute's transport messages to the selected MIDI output ports.

### MIDI input and recording

permute can pass incoming notes to its output ports and record them while the transport runs.

For drum tracks, an incoming note selects a drum track when its MIDI channel and fixed base note match. For melodic tracks, an incoming note selects the first melodic track whose MIDI channel matches. The `midi in auto channel` always targets the currently selected track.

Turn on external MIDI recording with **Shift + Transpose**. Incoming notes write to the current step. Mono tracks record the nearest degree in the current scale, poly tracks record held notes as a chord, and drum tracks record velocity. Realtime grid mode also enables MIDI recording.

### Arc

Connect a four-ring Arc to control the selected track's Euclidean overlay:

- Ring 1 sets the number of pulses.
- Ring 2 rotates the pattern.
- Ring 3 sets variance from 0-100%. For split tracks, it sets the proportion of stage steps used.
- Ring 4 selects a variation mode. Normal tracks provide triangle, ramp-down, ramp-up, random, and four cadence modes. Split tracks provide predefined trigger, ratchet, held, and pitch-advance behaviors.

The four `arc k* threshold` params set how much encoder movement counts as one adjustment for each ring.

### crow

Set `crow enabled` to `on`, then assign `crow out1 track` or `crow out2 track`. When an assigned track plays a note, its crow output sends a 5 V trigger and returns to 0 V after 10 ms. A track value of `0` disables that output.

### Launchpad Pro Mk3

Enable `lpp integration`, choose the Launchpad's MIDI input port, and optionally enable `lpp auto programmer` so permute sends it into programmer mode. Enable `lpp led feedback` if you want the script to set its colors.

The Launchpad's grid is divided into five zones:

- Zone A, the top row, plays the eight visible drum tracks. Use the page control to reach drum tracks 9-14.
- Zone B plays the default bass track, track 11.
- Zone C plays the default lead 1 track, track 12.
- Zone D plays the default lead 2 track, track 13.
- Zone E plays the default chord track, track 14.

The melodic zones quantize their pads to the current scale. The outer buttons move each zone's octave, clear its mapped melodic track, and double its track length. Hold the length modifier while pressing a double-length button to halve the length instead.

The drum controls clear or resize their visible drum track. The MIDI-record button toggles external MIDI recording. The page button switches between drum tracks 1-8 and 9-14.

The LPP color params control the palette values sent to each melodic zone, the clear buttons, and drum pads. They do not change MIDI notes or track routing.

## Parameters

The `PARAMS` list is ordered as follows:

1. `permute`, containing the Music through Arc controls below.
2. `track 1 config` through `track 14 config`.
3. `lpp integration`.
4. the Actions controls.

Open `PARAMS > permute` for the main sequencer configuration. The per-track, LPP, and Actions entries follow it at the top level in the order shown above.

### Music

- `scale`: chromatic, diatonic, pentatonic, lightbath, octaves and fifths, or octaves only. Default: diatonic.
- `key`: root note from C through B. Default: C.
- `scale degree`: mode rotation for a non-chromatic scale. Chromatic ignores it.

### Transport

- `tempo`: 30-300 BPM. Default: 145.
- `master length`: turns a global sequence reset on or off.
- `master length steps`: global reset length, 1-1024 steps. Default: 128.
- `reset timing`: resets immediately or on the next beat.

### Clock and MIDI

- `external midi clock`: use incoming MIDI clock instead of norns's internal clock.
- `incoming clock ppqn`: expected incoming resolution, 24, 48, 96, or 192 pulses per quarter note.
- `interp clock ppqn`: internal interpolation resolution, 24, 48, 96, or 192 PPQN. Default: 96.
- `send midi clock out`: send MIDI Clock to all active output ports.
- `send midi start/stop out`: send MIDI Start and Stop to active output ports.
- `clock debug`: write clock diagnostics.
- `note timing log`: include note timing in those diagnostics.
- `transport monitor`: show timing-monitor data.
- `midi out port`: required primary output, 1-16.
- `midi out port 2`, `3`, `4`: optional additional output ports, `off` or 1-16.
- `midi in port`, `midi in port 2`: optional input ports, `off` or 1-16.
- `midi in auto channel`: channel 1-16 that routes incoming notes to the selected track. Default: 16.

### Playback behavior

- `follow main page`: move the main overview page to follow playback.
- `follow edit page`: move the selected track's edit page to follow playback.
- `follow aux page`: move the auxiliary grid page to follow playback.
- `swing profile`: select the global swing curve.
- `global swing %`: 25-75%. Default: 50%.
- `b. repeat mode`: `full-row`, `one-handed`, or `step-select`.
- `b. repeat direction`: map repeat lengths left-to-right or right-to-left.
- `transpose mode`: transpose in semitones or scale degrees.
- `temp button mode`: use the Temp button as `temp` or `fill` when combined with Shift.

### Pattern slots

- `slot dynamic mode`: `last`, `all`, or `only`. See [Dynamic row reference](#dynamic-row-reference).
- `slot switch timing`: `immediate`, `bar-end`, or `master-end`.

### Note shaping

- `melody gate ticks`: default note duration for melodic tracks, 1-24 ticks. Default: 5.
- `drum gate ticks`: default note duration for drum tracks, 1-12 ticks. Default: 1.
- `spice accum min`: lower MIDI-note bound for accumulated spice, -127 to 127.
- `spice accum max`: upper MIDI-note bound for accumulated spice, -127 to 127.

### Outputs and display

- `crow enabled`: enable crow note triggers.
- `crow out1 track`, `crow out2 track`: assign output 1 or 2 to a track. `0` is off.
- `redraw fps`: grid redraw rate, 10-60 frames per second. Default: 30.
- `screen orientation`: normal or clockwise 90°.

### Arc controls

- `arc k1 threshold`, `arc k2 threshold`, `arc k3 threshold`, `arc k4 threshold`: ring movement thresholds from 1-32. Defaults are 8, 12, 2, and 16.

### Track parameters

`track N config` appears once for each of the 14 tracks. These parameters define what a track sends and how new steps behave.

- `track type`: Selects `drum`, `mono`, `poly`, or `split`.
  - `drum` sends the track's fixed base note. Grid rows set per-step velocity.
  - `mono` sends one scale-quantized note per active step.
  - `poly` sends a chord of one or more scale-quantized notes per active step.
  - `split` is a beta track type. It has separate eight-stage gate and pitch lanes, and its timing and editing behavior may change. See [Split tracks](#split-tracks).
- `midi channel`: The output channel for this track, from 1-16.
- `base note`: The fixed MIDI note sent by a drum track, from 0-127. On melodic tracks, it is the base note used before scale-degree, octave, and transpose offsets are applied.
- `default velocity`: The MIDI velocity assigned to newly created steps, from 0-127. Existing steps keep their stored velocity.
- `default note length`: The duration assigned to notes on this track, from 1-24 clock ticks. It overrides the global drum or melody gate-tick default for the track.
- `hold tie length`: Turns hold-and-drag span editing on or off. When it is on, hold an active step for at least 150 ms and press another step in the same track row to fill the span between them with tied copies of the first step.

### LPP integration

- `lpp integration`: enable or disable Launchpad Pro Mk3 controls.
- `lpp midi in port`: Launchpad input port, `off` or 1-16.
- `lpp auto programmer`: enter programmer mode automatically.
- `lpp led feedback`: send color feedback to the device.
- `lpp [b/c/d/e] octave color` and `note color`: palette values, 0-127, for the zone's octave pads and note pads.
- `lpp clear mapped color`, `lpp clear unmapped color`: palette values for clear-button states.
- `lpp drum 1 color` through `lpp drum 8 color`: palette values for visible drum pads.

### Actions

Actions appear after `lpp integration`, at the bottom of the main parameter list.

- `panic`: send note-off messages for every active note.
- `start` and `stop`: control the transport.
- `save as default`, `reload default`, `clear default (factory)`: manage the saved startup configuration.

## Saved defaults and presets

Saved defaults and presets solve different problems.

### Saved default

A saved default is the configuration permute loads every time it starts. It includes the permute parameters and all per-track configuration: scale, key, clock and MIDI routing, device settings, display settings, track types, channels, base notes, default velocity, note lengths, and hold behavior.

It does not save your pattern data. Use `save as default` after you set up your usual hardware and routing. Use `reload default` to restore it during a session. Use `clear default (factory)` to delete it and immediately restore the script's built-in configuration.

### norns preset

A norns preset is a complete musical snapshot. Save and load it from the normal norns PSET controls. It stores the sequence state, including every track's gates, pitches, velocities, ties, range, octave, speed, transpose, randomization, fills, ratios, spice, Arc pattern, pattern slots, beat-repeat settings, global musical settings, display options, and LPP state.

A preset also stores the track configuration. Loading one can therefore change track types, MIDI channels, and base notes. It does not replace the saved default that loads when permute starts.
