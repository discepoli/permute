# Permute Refactor Plan

A functionality-preserving refactor of the Permute norns script aimed at improved runtime efficiency, maintainability, and readability. This plan is informed by monome/norns community best practices (study-4, grid-recipes, clocks.md) and review of the existing sources: `permute.lua`, `lib/app.lua` (~5k lines), `lib/params.lua`, `lib/config.lua`, and `lib/icons.lua`.

> No user-facing behavior should change. Every change here is structural, performance-oriented, or a readability cleanup. Bug fixes are explicitly out of scope.

---

## 1. Current State Summary

- `permute.lua` is a thin shim that forwards norns callbacks (`init`, `redraw`, `key`, `enc`, `cleanup`) to a single `App` class.
- `lib/app.lua` holds essentially the entire application: state, grid input routing, grid rendering for main + aux grids, arc handling, screen rendering in two orientations, MIDI I/O, clock handling, preset/default-setup I/O, undo/redo, transpose meta-sequencer, arc-euclidean (pulses/rotation/variance) engine, randomization, spice, fill, temp, beat-repeat, ratios, crow, etc.
- `lib/params.lua` is reasonable but has ad-hoc `clamp` and repeated `pcall`-based reads; action callbacks mutate `app` directly.
- `lib/icons.lua` is well isolated; each icon is a small function plus a dispatcher.
- `lib/config.lua` is small and clean.

### Pain points observed

1. **Monolith.** `lib/app.lua` at ~5,015 lines contains every concern. It makes reasoning, testing, and diffs painful.
2. **Per-tick allocations.** `play_tracks`, `build_arc_step_cache`, and `redraw_main_grid` each allocate tables (step_cache, order, `in_range_fn` closure, `capture_midi_ports` copies) on every MIDI tick (24x/beat) and every redraw. `ensure_track_state` is called repeatedly per track per tick.
3. **Redundant `clamp`.** Each file redefines `clamp`; norns provides `util.clamp`.
4. **Giant `handle_*` event switches.** `handle_main_grid_event`, `handle_aux_grid_event`, and `handle_transpose_takeover_event` contain deeply nested mod-held branches that duplicate logic (e.g., drum/mono/poly, ratios, temp/fill, spice, clear, beat-repeat).
5. **Grid draw redraws full state every frame.** A full `dev:all(0)` + row-by-row rebuild using `grid_led(x,y,lv)` per cell, with `build_arc_step_cache` called per track twice per frame.
6. **MIDI ports captured per note.** `capture_midi_ports` deep-copies the selected ports table on each note-on / note-off and stored per scheduled note-off.
7. **String-based dispatch.** `mod_name` / `mod_id_from_name` use long if/elseif ladders; icon dispatch in `icons.lua` also uses a large if/elseif.
8. **Screen orientation.** `redraw_screen_cw90` and the `normal` path have drifted slightly (redundant if branches, "cw90" checks inside the "normal" branch).
9. **Preset/default-setup.** `capture_default_setup_values` iterates a static list; `import_state` has an enormous sequence of type-checked copies — boilerplate can be pushed into a schema-driven helper.
10. **Beat repeat state.** "full-row", "one-handed", and "step-select" share three semi-independent state machines on the same flags; the logic to determine "is hold still active" is duplicated in multiple places.
11. **Redraw latency.** `request_redraw` calls `redraw()` synchronously every time state changes, even though `metro` will redraw at 30 fps. Screen redraws also don't respect `redraw_min_ms` the way grid redraws do.

---

## 2. Goals and Non-Goals

**Goals**
- Exact behavior parity (deterministic: same grid/arc output, same MIDI stream, same presets load/save).
- Reduce per-tick CPU and GC pressure in the audio/timing hot path (`tick`, `play_tracks`, `advance_clock_tick`).
- Split `lib/app.lua` into coherent modules so each one is <~600 lines and has a narrow responsibility.
- Remove duplicated logic; adopt norns idioms (`util.clamp`, `util.wrap`, `clock.run`, `metro`).
- Make the code easier to browse: consistent naming, small helpers, documented state tables.

**Non-Goals**
- No new features, no new params, no UI rewording.
- No changes to preset on-disk format (backwards-compatible load/save).
- No changes to grid/arc/midi wiring semantics.

---

## 3. Refactor Phases

Each phase is independently shippable and testable on hardware. Keep commits small and bisectable.

### Phase 0 — Safety net (before touching logic)

- Add a deterministic "golden" harness under `test/` (simple Lua scripts, not a full framework) that:
  - Constructs an `App`, feeds a scripted sequence of MIDI clock ticks + grid events, and snapshots:
    - `last_notes`, scheduled note-offs, `track_steps`, `step_cache` per step, grid LED matrix per redraw (using a stub `grid_dev:led` recorder), and screen text.
  - Compares against a committed snapshot.
- This is the acceptance gate for every subsequent phase (run after each PR, diff snapshots → zero).
- Also establish a minimal `test/stubs.lua` that provides `screen`, `grid`, `arc`, `midi`, `clock`, `metro`, `util`, `tab`, `crow`, `params`, `_path`, `_menu`, and `include` so files can be required in plain Lua for iterate-faster offline tests.

**Stub provenance (important).** To protect against divergence from real norns behavior, stubs are **ported from the official norns Lua sources in `monome/norns/lua/core/*.lua`**, not invented from scratch. Each stub file in `test/stubs/` carries a header comment citing the norns commit SHA + source file it was derived from, e.g.:

```lua
-- test/stubs/paramset.lua
-- derived from: monome/norns @ <sha>  lua/core/paramset.lua
-- behavior ported: add_*, set_action, bang (in declaration order),
--                  action_read/action_write/action_delete hooks
```

When norns releases a new version, `make stubs-check` diffs the cited sources and alerts if any stubbed API changed. This addresses the biggest risk of this approach (monome/norns#425 "stop the globalocalypse" — globals are deliberately under-specified; we re-anchor them to real source).

**Scope of parity the stubs must hit, in priority order:**

1. `params` — `add_number / add_option / add_trigger / add_group`, `set_action`, `set`, `get`, `delta`, `bang`, and the `action_read / action_write / action_delete` hooks that `lib/params.lua` monkey-patches.
2. `midi` — `connect(port)`, the `event` callback signature, `to_msg`, and `note_on / note_off / start / stop / clock / continue` methods on the connected device. Realtime status bytes (248/250/251/252) must round-trip correctly.
3. `grid` — `grid.connect(port)`, `grid.add / grid.remove` callbacks, `device.cols / device.rows / device.port`, and `:all / :led / :refresh / :intensity` on the device.
4. `arc` — `arc.connect()`, `arc.add / arc.remove`, `:all / :led / :refresh`, and the `delta(n,d)` callback.
5. `clock` — `clock.run`, `clock.cancel`, `clock.sync`, `clock.sleep`. The harness overrides these to be synchronous: `clock.run(fn, ...)` returns a handle and records the coroutine; the test runner drives ticks by calling `App:advance_clock_tick()` directly rather than relying on real scheduling.
6. `metro` — `metro.init{ event, time, count }` returning a handle with `:start / :stop`. The handle fires only when the test explicitly ticks it.
7. `screen` — the full draw API used by the app (`clear / level / move / line / text / rect / circle / arc / stroke / fill / close / font_size / text_extents / text_rotate / update / save / restore / translate / rotate`). All calls are recorded into a display list, not rasterized.
8. `util` — real `util.clamp / util.wrap / util.round / util.time / util.make_dir / util.linlin` (trivially reimplemented or copied from norns).
9. `tab` — `tab.save(obj, path)` and `tab.load(path)` backed by an in-memory filesystem keyed on path strings, so preset round-trip tests don't touch disk.
10. `crow` — `crow.output[1..4]` with a recording stub (`.volts`, `.action`, call-as-function); no real USB.
11. `_path`, `_menu` — `_path.data` returns a harness-controlled temp dir; `_menu.mode` is always `nil` so `is_menu_active()` returns `false`.
12. `musicutil` — `require("musicutil")` is resolvable and provides the handful of functions Permute uses (`note_num_to_name`). Ship the real upstream `musicutil.lua` in `test/vendor/`.
13. `include` — shim to `function(p) return require(p:gsub("/", ".")) end` with `package.path` pointed at the repo root.

**Determinism rules enforced by the harness:**

- `math.randomseed(0)` is called at the start of each scenario.
- `util.time()` returns a monotonically advancing value controlled by the test (`S.advance_time(n)`), not wall clock.
- No use of `os.time()` or `os.clock()` in production code (already true; Permute uses `util.time()`).
- `clock.run` / `metro` do not execute during a scenario unless the scenario explicitly ticks them.
- Grid LED snapshots are canonicalized (sorted by y,x) before diffing so ordering of `:led` calls within a single refresh doesn't produce false diffs.

**Known limitations of the harness (accepted by design):**

- Cannot verify wall-clock jitter, real `clock.sync` drift vs MIDI/Link, or grid quad refresh coalescing at the kernel level. These require on-device smoke testing.
- Cannot catch regressions where Permute starts calling `:led` so frequently that the real USB driver drops frames. Mitigation: snapshot also records a `leds_per_refresh` histogram and fails if it exceeds a configured threshold.
- Cannot verify `pcall`-wrapped error paths unless scenarios explicitly disable a subsystem (e.g., `S.disable("crow")` to simulate missing `crow` global).
- Floating-point rounding differences between LuaJIT (potentially on your dev machine if you use it) and stock Lua 5.3/5.4 (on norns) are rare for this code but possible. Mitigation: run the harness in the same Lua interpreter norns ships (`lua5.3`) and pin it in `Makefile`.

### Phase 1 — File split (pure mechanical move)

Break `lib/app.lua` into modules without changing behavior. Each module exposes a small, explicit interface. Suggested layout:

```
lib/
  app.lua                 -- public entry: App.new(), :init(), :key/enc/redraw/cleanup
  config.lua              -- unchanged
  icons.lua               -- unchanged for now (phase 4 tidies)
  params.lua              -- unchanged for now (phase 3 tidies)
  core/
    util.lua              -- clamp, deep_copy, now_ms, ensure_dir, wrap_index
    state.lua             -- new(), ensure_track_state, track_bounds, step_order
    history.lua           -- export_undo_state, import_undo_state, push/undo/redo
    presets.lua           -- preset + default-setup save/load/delete, default_setup_param_ids
  sequencer/
    scale.lua             -- SCALE_DEGREE_INDICES, get_mode_scale_and_root, get_pitch
    arc_pattern.lua       -- euclidean build, arc waves/cadence, build_arc_step_cache
    spice.lua             -- spice bounds, per-step accumulator
    ratios.lua            -- ratio label/cycle/position, apply + allows_play
    randomization.lua     -- apply_random_notes, apply_random_steps, evolving_rand
    transpose_seq.lua     -- meta-sequencer clock, layout, hold span
    beat_repeat.lua       -- full-row, one-handed, step-select state machines
  io/
    midi.lua              -- connect_midi_from_params, for_each_midi_device, note on/off, realtime
    crow.lua              -- trigger_crow wrapper
    transport.lua         -- start/stop, advance_clock_tick, tick, scheduled note-offs
  ui/
    screen.lua            -- redraw_screen (normal + cw90 paths share a common drawer)
    grid_main.lua         -- redraw_main_grid + dynamic_row + mod_row + takeover
    grid_aux.lua          -- redraw_aux_grid
    grid_input.lua        -- handle_main_grid_event + handle_aux_grid_event + handle_transpose_takeover_event
    arc.lua               -- redraw_arc, handle_arc_delta, connect_arc
```

The `App` object becomes a composition of these modules. Each module receives `self` (the App) and returns a namespace of functions, OR we register methods via `setmetatable` on App. Chosen pattern:

```lua
-- lib/app.lua
local App = {}
App.__index = App

require("lib/core/state").install(App)
require("lib/audio/arc_pattern").install(App)
require("lib/ui/screen").install(App)
-- etc.
```

Each `install(App)` adds methods to `App.__index`. This preserves the existing `self:foo()` call sites exactly, so the mechanical split is a pure move with zero logic change.

**Exit criteria for Phase 1:** golden harness diff is empty; `lib/app.lua` shrinks to <300 lines (wiring + top-level lifecycle).

### Phase 2 — Hot-path performance

All changes must preserve behavior. Focus on the per-tick path.

1. **Cache `track_cfg[t]` and `tracks[t]` locals inside hot loops.** Replace repeated `self.track_cfg[t].type` with a local captured once per track per tick.
2. **Stop rebuilding `step_cache` twice per frame.**
   - `build_arc_step_cache` is called in `play_tracks` and twice in `redraw_main_grid` (main + aux). Introduce a per-track cache invalidated when any of the inputs change: `tr.gates`, `tr.ties`, `tr.vels`, `tr.pitches`, `tr.arc`, `tr.start_step`, `tr.end_step`. Provide `invalidate_step_cache(track)` called at each mutation site (grid edits, randomization, clear, preset load, arc delta). Read-only reads reuse the cache. Expected: 2–3x reduction in grid redraw cost.
3. **Avoid closure allocation in redraw.** Replace `in_range_fn` closures with a cached `{lo=..., hi=...}` table, and inline the check (`s >= lo and s <= hi`).
4. **Replace `capture_midi_ports(ports)` deep-copies with reference sharing.** The active port list only changes when params change, so keep a single immutable `self.midi_out_ports_snapshot` table; `schedule_note_off` stores a reference, not a copy. Only copy on rare mutation events.
5. **Pre-compute `get_pitch` inputs.** `get_pitch` is called per note per tick; hoist `get_mode_scale_and_root()` and `track_transpose[t]`, `octave`, `key_root` out of the per-note loop into a `tick_context` struct passed into `play_tracks`.
6. **Replace `for_each_midi_device` with a pre-iterated list.** Cache `self.midi_devs_active = { dev1, dev2, ... }` updated only on port changes; iterate this short list without a `pairs`/`ipairs`/closure call per note.
7. **`active_note_offs` cleanup.** Replace the `table.remove` O(n) scan in `process_scheduled_note_offs` with a two-pointer compact-in-place (or a free-list / deque pattern). At high tick rates with many simultaneous gates this saves meaningful cycles.
8. **Lazy redraw.** `request_redraw` should set flags only; do not call `redraw()` synchronously. Let the existing 30Hz `grid_timer` metro drive `screen.update()` too (respect `permute_redraw_fps`). This also smooths frame pacing and avoids stalls during burst events (e.g., clear-all).
9. **Drum/mono/poly dispatch table.** Replace the repeated `if tc.type == "drum" / poly / mono` in `play_tracks`, `apply_random_notes`, `clear_track`, `apply_held_gate_span` with a small per-type handler table:

   ```lua
   local TRACK_TYPE_HANDLERS = {
     drum  = { play = play_drum_step, reset_pitch = drum_reset_pitch, ... },
     mono  = { play = play_mono_step, ... },
     poly  = { play = play_poly_step, ... },
   }
   ```

   This removes branches from the hot path and consolidates maintenance.

10. **`util.clamp` / `util.wrap`.** Replace local `clamp` in all files with norns' built-in `util.clamp`. Less code, same semantics, often marginally faster.

### Phase 3 — Input/event clarity

1. **Grid event router.** Extract a small table of resolvers that, given `(x, y, z, context)`, picks one handler. Pattern:

   ```lua
   local function route_main(self, x, y, z)
     if y == self:get_main_mod_row() then return "mod" end
     if y == self:get_main_dynamic_row() then return "dynamic" end
     if self.realtime_play_mode and self.playing then return "realtime" end
     if self.takeover_mode then return "takeover" end
     return "overview"
   end
   ```

   Each route maps to a single function. Deeply nested `if/elseif` chains in `handle_main_grid_event` become short dispatches.

2. **Mod-held handlers.** The on-press action when a mod is held (mute/solo/start/end/rand/clear/ratios/temp/fill/spice/beat_rpt) is currently duplicated in:
   - `handle_main_grid_event` (overview region)
   - `handle_main_grid_event` (takeover region)
   - `handle_aux_grid_event`

   Extract `apply_mod_action(mod, t, s, y, aux)` returning `(applied_value, should_push_undo)`. All three sites share the same function; ordering nuances (e.g., SHIFT+CLEAR first) live in one place.

3. **Beat repeat state.** Move the three modes to a single `BeatRepeat` module with a clear API:
   ```lua
   bro:set_mode(mode)
   bro:on_tick()
   bro:engage(track_steps)
   bro:reset()
   bro:target_step(current_track_1_step)
   ```
   Internal state stays private to the module.

4. **Temp/fill.** Unify around `temp_mode:"temp"|"fill"` with shared `latched/active` state and explicit transitions.

5. **Symbolic mod-id / name lookup.** Replace the string-dispatch ladders in `mod_name` and `mod_id_from_name` with a single bidirectional map built once at startup.

### Phase 4 — Rendering clarity

1. **Consolidate screen redraws.** `redraw_screen_cw90` and the normal branch share ~80% of their content. Introduce `draw_body_lines(lines)` which accepts a list of `{text, level}` entries and writes them in the appropriate orientation. The orientation-specific code becomes a thin adapter.
2. **Icon dispatch table.** In `lib/icons.lua` replace the 16-way `if/elseif` with a `DRAWERS = { [1] = draw_mute, [2] = draw_solo, ... }` table plus a `SPECIAL = { random_sequence = ..., clock_rate = ... }` table.
3. **`grid_led` variadic API.** The dual-arity `grid_led(a,b,c[,d])` is a footgun; split into `grid_led_main(x,y,l)` and `grid_led_on(dev,x,y,l)`. Usages migrated 1:1.
4. **Row drawers.** `draw_dynamic_row` is a 12-way if-chain; each branch is a self-contained row painter. Extract `DYN_ROW_PAINTERS = { octave = ..., transpose = ..., spice = ..., ... }` keyed on the detected mod combination.

### Phase 5 — Params, presets, default setup

1. **Declarative param table.** `lib/params.lua` declares ~30 params with near-identical boilerplate. Switch to a declarative table:
   ```lua
   local PARAMS = {
     { id = "permute_scale", kind = "option", opts = SCALE_NAMES, default = 2,
       action = function(app, v) app:set_scale_type(v) end },
     ...
   }
   ```
   Driver loop calls `params:add_*` and `params:set_action` for each entry. This halves the file and makes it scannable.
2. **Preset schema.** Replace the `import_state` hand-written type checks with a schema:
   ```lua
   local STATE_SCHEMA = {
     tracks = { type = "table_deep" },
     track_steps = { type = "table_deep" },
     scale_type = { type = "string", choices = SCALE_NAMES, default = "diatonic" },
     ...
   }
   ```
   Generic `import_with_schema(obj, state, schema)` + `export_with_schema(obj, schema)` removes ~200 lines of repetitive code while preserving the on-disk layout.
3. **Default-setup param IDs.** `default_setup_param_ids()` duplicates ids already named by `PARAMS`. Derive it from the schema (`PARAMS` entries with `default_setup = true`).

### Phase 6 — Naming + style polish

1. **Consistent `self.foo_bar` naming.** Remove mixed conventions (e.g., some booleans have `_enabled`, others don't).
2. **Move inline ARC/BEAT constants to `config.lua`** (ARC_DELTA_THRESHOLDS, ARC_VARIANCE_MODES, ARC_CADENCE_SHAPES, TRACK_SELECT_MOD, HOLD_THRESHOLD, redraw_min_ms default).
3. **Add brief section headers** to any remaining large files (`-- ===== SECTION =====`).
4. **Remove dead / no-op functions**: `get_screen_rotation_quadrants`, `is_screen_rotated_90`, `apply_screen_transform`, `reset_screen_transform` either do nothing or always return defaults. Inline or remove.

### Phase 7 — Optional ergonomic cleanups (only if time permits)

- Introduce a tiny `Observable` helper so mutations that require `screen_dirty / grid_dirty / arc_dirty` flag sets are centralized (reduces chance of forgetting a flag).
- Add `make test` target that runs the offline golden harness.
- Add `stylua.toml` / `.luacheckrc` and run `luacheck` / `stylua` (no public style changes, just warnings fixed).

---

## 4. Cross-Cutting Conventions (adopted throughout)

- Use `util.clamp`, `util.wrap`, `util.round` from norns.
- Prefer local caching in hot loops: `local get_pitch = self.get_pitch` (avoid repeated table lookups).
- Avoid creating closures per event. Hoist handlers to module scope.
- Avoid `deep_copy_table` in the hot path; only copy at preset boundaries and undo snapshots.
- Guard `screen.*` and `grid.*` calls with nil checks only at module edges, not per call site.
- Keep `request_redraw` purely as a flag-set (no direct `redraw()` call). Metro drives actual painting.

---

## 5. Risk and Validation

### 5.1 Refactor risks (production code)

| Risk | Mitigation |
|---|---|
| Behavioral drift during file split | Phase 0 golden harness; one module moved per commit |
| Performance regressions | Benchmark `tick()` on 128 steps active, 4 MIDI ports, measure before/after in `util.time()` |
| Preset incompatibility | Keep exact on-disk field names; add read-side defaults for older files |
| Grid visual drift | Snapshot-based LED matrix test using stub grid dev |
| Concurrency around `clock.run` | Keep `internal_clock_id` lifecycle untouched; restart logic unchanged |
| Menu/norns global hooks (`params.action_read/write/delete`) | Preserved verbatim inside `presets.lua`; no timing change |
| Local-function ordering traps when splitting files (see `llllllll.co` best-practices thread, Nov 2025) | Use the `install(App)` method-registration pattern so modules don't rely on file-local forward declarations |

### 5.2 Harness risks (test-only code)

The production code continues to use norns globals directly. Risk here is that the **stubs diverge from real norns behavior** and give false-positive "pass" results. Captured in Phase 0 but summarized:

| Risk | Source | Mitigation |
|---|---|---|
| Norns globals are under-specified and can drift between releases | monome/norns#425 "stop the globalocalypse" | Port stubs from `monome/norns/lua/core/*.lua` with commit-SHA headers; `make stubs-check` diffs on norns release |
| Stubbing realtime/hardware code is brittle (Zebra, norns core dev: *"the effort of mocking really blows up and is arguably not worth it"*) | `llllllll.co/t/norns-scripting-best-practices/23606` post #14 | Keep rich tests on pure modules (`sequencer/*`, `core/*`); treat `io/*` and `ui/*` as coarse "did it send the right MIDI / right LED stream" black-box tests |
| Coroutine/clock semantics differ between stub and real scheduler | `clock.run` is cooperative on norns | Harness never yields; tests drive ticks via `App:advance_clock_tick()`; `clock.run` in the stub is a no-op that records the fn for optional manual firing |
| `params:bang()` / `action_read/write/delete` callback ordering | `lib/params.lua` monkey-patches these three hooks | Port paramset semantics verbatim from norns; add a dedicated scenario `preset_hooks.lua` that verifies the write→read→delete ordering |
| Grid quad refresh coalescing (kernel-level batching on real device) | Not modeled in stubs | Add a `leds_per_refresh` histogram to each grid snapshot and fail if exceeds a configured ceiling; plus per-phase hardware smoke test |
| Lua interpreter differences (LuaJIT locally vs Lua 5.3/5.4 on norns) | `string.format`, `math.random` sequences, float edge cases | Pin test runner to `lua5.3` in `Makefile`; seed `math.randomseed(0)` per scenario |
| `include()` path resolution (norns custom) vs `require()` (plain Lua) | norns's `include` resolves relative to script dir | Shim `_G.include = function(p) return require(p:gsub("/", ".")) end` and set `package.path` to project root |
| `pcall`-guarded error paths not exercised (e.g., missing `crow`, `tab`) | Stubs always present by default | Each scenario can call `S.disable("crow")` / `S.disable("tab")` to force the fallback branches |

---

## 6. Out-of-Scope (Explicit)

- No functional changes to temp/fill semantics.
- No change to arc euclidean algorithm or variance shapes.
- No MIDI clock handling changes (`status == 248/250/251/252` branch stays exactly as-is).
- No change to how `sel_track` and `takeover_mode` interact.
- No change to preset file extension, path, or structure.

---

## 7. Suggested Order of Commits (one PR per item)

1. Add Phase 0 harness and stubs (no production code touched). Includes `test/stubs/*` ported from `monome/norns/lua/core/*.lua` with SHA headers, `test/run.lua` driver, `test/scenarios/*`, first pass of goldens, and `Makefile` targets `test`, `goldens-update`, `stubs-check`.
2. Phase 1: extract `core/util.lua` (clamp/copy/now_ms).
3. Phase 1: extract `core/state.lua` (`App.new`, `ensure_track_state`, bounds, order).
4. Phase 1: extract `io/midi.lua`, `io/crow.lua`, `io/transport.lua`.
5. Phase 1: extract `sequencer/*` (scale, arc_pattern, spice, ratios, randomization, transpose_seq, beat_repeat).
6. Phase 1: extract `ui/screen.lua`, `ui/arc.lua`, `ui/grid_main.lua`, `ui/grid_aux.lua`, `ui/grid_input.lua`.
7. Phase 1: extract `core/history.lua`, `core/presets.lua`. `lib/app.lua` now a thin wiring file.
8. Phase 2: hot-path caching (`tick_context`, step_cache invalidation, midi device list).
9. Phase 2: async redraw (metro-driven screen + grid).
10. Phase 3: route tables for grid events; consolidate mod-action handler.
11. Phase 3: BeatRepeat module encapsulation.
12. Phase 4: icon and row-painter dispatch tables.
13. Phase 5: declarative PARAMS + schema-driven presets/default-setup.
14. Phase 6: naming + dead code removal + `config.lua` consolidation.
15. Phase 7 (optional): Observable helper, luacheck/stylua pass.

---

## 8. Expected Payoff

- `lib/app.lua` goes from ~5000 lines to a <300-line orchestrator.
- Each concern is readable in isolation (<600 lines/module).
- Per-tick CPU drops meaningfully on 128-step busy sessions (eliminating redundant `build_arc_step_cache`, closure/table allocations, deep-copy of port lists).
- Grid/screen frame pacing is deterministic (metro-driven only).
- Adding a new mod/feature later becomes a matter of editing one handler table + one painter, not threading through three event handlers.
