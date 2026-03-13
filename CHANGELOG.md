# Changelog

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.0.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [0.1.0] - 2026-03-12

### Added
- **Base Note Parameter**: Added per-track `base note` parameter (`permute_track_<n>_note`) for drum tracks, accessible in params > track config
- **MIDI Channel Display**: Held-step screen now displays MIDI channel for both melodic and drum tracks
- **Global Undo/Redo**: Implemented global undo/redo history system with up to 5 states
  - `Shift + Spice` = undo last action
  - `Shift + Beat Repeat` = redo last action
  - History captures both app state and track configuration
- **Default Setup Persistence**: Added system to save and restore all global permute settings and track configs
  - Auto-loads saved default on script startup
  - New params menu actions: `save as default`, `reload default`, `clear default (factory)`
  - Factory defaults are captured on init and can be restored via clear default
- **Configurable Spice Accumulator Bounds**: Added runtime-configurable min/max bounds for spice accumulator
  - New params: `spice accum min` and `spice accum max` (range: -127 to 127)
  - Bounds are validated to ensure min ≤ max
  - Included in default setup persistence

### Changed
- **Drum Track Defaults**: Tracks 9 and 10 now default to drum type instead of mono
- **Drum Velocity Behavior**: Fixed drum velocity takeover mode behavior
  - Velocity slider presses (rows 1-15) no longer toggle steps off, only adjust velocity
  - Step on/off toggling now exclusively happens via dynamic row (row 16) press
  - Creating a new step on dynamic row initializes velocity to default level
  - Creating a new step via velocity slider also creates step with that velocity level

### Fixed
- Undo/redo state now properly stops all notes before restoring state to prevent stuck notes
- Mod shortcut consumption tracking prevents unintended side effects on button release
- Held-step tracking now includes row position to correctly identify dynamic row interactions

## [Unreleased]

---

[0.1.0]: https://github.com/ndiscepoli/permute/releases/tag/v0.1.0
