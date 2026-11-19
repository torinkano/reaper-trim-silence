# Testing

## Environment

- REAPER 7.78 x64 (Windows)
- ReaImGui 0.10.0.5
- Lua 5.4 for the mock harness
- REAPER's ReaScript `-nonewinst` command-line execution for real tests

## Mock test suite

```bash
lua tests/test_trim.lua
```

Result: **47 passed, 0 failed**.

The mock suite simulates the REAPER API and covers detection/planning/trim
math, item geometry, take start offsets, fades, take envelopes, unsupported
items, preview state capture/restore, GUI Run/Cancel, right-click input,
boundary navigation, and loop-source handling.

## Real REAPER tests

### Synthetic media

```bash
python tests/reaper/make_test_media.py
"C:\Program Files\REAPER (x64)\reaper.exe" -nonewinst tests/reaper/run_synthetic_tests.lua
```

The harness creates one temporary track, inserts synthetic WAV items at
known positions, runs headless copies of the script, asserts the resulting
item fields, and deletes the temporary track.

**13/13 passed:**

- item at 100 s
- source start offset 2 s
- existing 0.5 / 0.3 s fades reset on trimmed edges
- loop source that actually repeats is skipped untouched
- loop flag without repetition is processed
- steady hum above `-80 dBFS` is not trimmed
- hum trimmed with `-40 dBFS`
- zero pads remove all leading/trailing silence
- item at project time 0
- fully silent item skipped
- stereo source with one audible channel
- negative `D_STARTOFFS`
- `preserve` fade policy shortens existing fades

Report: `tests/reaper/synthetic-report.txt` (generated, not committed).

### Selected-item duplicate

```bash
"C:\Program Files\REAPER (x64)\reaper.exe" -nonewinst tests/reaper/run_actual_item_test.lua
```

This duplicates the selected media item onto a temporary track, runs the
headless script copy on the duplicate, reports before/after values, then
deletes the temporary track and restores the original selection.

Observed on a real voice item:

```text
source length = 5.710479 s
loop source flag set, but no actual repetition
duplicate before: pos 295.218379812  len 5.710479167  soffs 0
duplicate after:  pos 295.223358978  len 5.705500000  soffs 0.004979
fade-in: 0.059 -> 0.002
fade-out: 0.1074 (right edge not trimmed, unchanged)
original item: unchanged
```

### Arrange-view centering

A separate API check confirmed `GetSet_ArrangeView2` can keep the current
horizontal zoom and center the edit cursor:

```text
view width = 0.716 s
target     = 300.000 s
center     = 299.9994 s  (pixel quantization)
```

The view was restored after the check.

## Not automated

Actual mouse interaction inside the ReaImGui window (dragging, right-click
popup typing, Head/Tail buttons, Run/Cancel with live preview) is not
automated. Those paths are covered by the mock suite, while the audio
processing and item geometry are covered by the real REAPER tests.

## Notes

- The real-test harness writes reports under `tests/reaper/` and generated
  variants under `tests/reaper/.generated/`; both are gitignored.
- `run_actual_item_test.lua` operates on a duplicate only. The original item
  is never modified.
- Test reports can contain local paths, so they are intentionally not
  committed.
