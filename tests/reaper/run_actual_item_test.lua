-- Actual test-item verification in the currently open REAPER instance.
-- Duplicates the selected media item onto a temporary track, runs the
-- headless script copy on the duplicate, and reports before/after values.
-- The original item is never modified.

local info = debug.getinfo(1, "S")
local SCRIPT_PATH = info.source:gsub("^@", "")
local SCRIPT_DIR = SCRIPT_PATH:match("^(.*)[\\/]") or "."
local ROOT = SCRIPT_DIR .. "/../.."
local REPORT = SCRIPT_DIR .. "/actual-item-report.txt"
local GENERATED = SCRIPT_DIR .. "/.generated"

reaper.RecursiveCreateDirectory(GENERATED, 0)

local function read_all(path)
  local file = assert(io.open(path, "rb"))
  local text = file:read("*a")
  file:close()
  return text
end

local function write_all(path, text)
  local file = assert(io.open(path, "wb"))
  file:write(text)
  file:close()
end

local function make_variant(name)
  local text = read_all(ROOT .. "/TrimLeadingTrailingSilence.lua")
  text = text:gsub(
    "show_settings_window%s*=%s*true",
    "show_settings_window = false", 1
  )
  text = text:gsub(
    "show_summary%s*=%s*true",
    "show_summary    = false", 1
  )
  local path = GENERATED .. "/" .. name
  write_all(path, text)
  return path
end

local DEFAULT = make_variant("actual-default.lua")

local report = assert(io.open(REPORT, 'w'))

local function log(text)
  report:write(tostring(text) .. '\n')
  report:flush()
end

reaper.Undo_BeginBlock2 = function() end
reaper.Undo_EndBlock2 = function() end
reaper.ShowMessageBox = function(text, title)
  log('MSGBOX: ' .. tostring(title) .. ' :: ' .. tostring(text))
  return 0
end

local source_item = reaper.GetSelectedMediaItem(0, 0)

if not source_item then
  log('NO_SELECTED_ITEM')
  report:close()
  return
end

local source_take = reaper.GetActiveTake(source_item)
local source = source_take and reaper.GetMediaItemTake_Source(source_take)

if not source then
  log('NO_SOURCE')
  report:close()
  return
end

local saved_cursor = reaper.GetCursorPosition()
local original_track_count = reaper.CountTracks(0)
local source_length, length_is_qn = reaper.GetMediaSourceLength(source)

log(string.format(
  'source_length=%.9f qn=%s tracks=%d',
  source_length or -1, tostring(length_is_qn), original_track_count
))

local function snapshot(item, take)
  return {
    position = reaper.GetMediaItemInfo_Value(item, 'D_POSITION'),
    length = reaper.GetMediaItemInfo_Value(item, 'D_LENGTH'),
    start_offset = reaper.GetMediaItemTakeInfo_Value(
      take, 'D_STARTOFFS'
    ),
    rate = reaper.GetMediaItemTakeInfo_Value(take, 'D_PLAYRATE'),
    loop = reaper.GetMediaItemInfo_Value(item, 'B_LOOPSRC'),
    fade_in = reaper.GetMediaItemInfo_Value(item, 'D_FADEINLEN'),
    fade_out = reaper.GetMediaItemInfo_Value(item, 'D_FADEOUTLEN'),
    fade_in_shape = reaper.GetMediaItemInfo_Value(
      item, 'C_FADEINSHAPE'
    ),
    fade_out_shape = reaper.GetMediaItemInfo_Value(
      item, 'C_FADEOUTSHAPE'
    ),
  }
end

local function dump(label, v)
  log(string.format(
    '%s pos=%.9f len=%.9f soffs=%.9f rate=%.6f loop=%s '
      .. 'fin=%.9f fout=%.9f shape=%.0f/%.0f',
    label, v.position, v.length, v.start_offset, v.rate,
    tostring(v.loop), v.fade_in, v.fade_out,
    v.fade_in_shape, v.fade_out_shape
  ))
end

local original_before = snapshot(source_item, source_take)
dump('original_before', original_before)

reaper.InsertTrackAtIndex(original_track_count, true)
local temp_track = reaper.GetTrack(0, original_track_count)
reaper.GetSetMediaTrackInfo_String(temp_track, 'P_NAME', 'DSH_ACTUAL_DUP', true)

local copy_item = reaper.AddMediaItemToTrack(temp_track)
local copy_take = reaper.AddTakeToMediaItem(copy_item)

if not copy_take or not reaper.SetMediaItemTake_Source(copy_take, source) then
  log('COPY_FAILED')
  reaper.DeleteTrack(temp_track)
  report:close()
  return
end

reaper.SetMediaItemInfo_Value(copy_item, 'D_POSITION', original_before.position)
reaper.SetMediaItemInfo_Value(copy_item, 'D_LENGTH', original_before.length)
reaper.SetMediaItemTakeInfo_Value(
  copy_take, 'D_STARTOFFS', original_before.start_offset
)
reaper.SetMediaItemTakeInfo_Value(
  copy_take, 'D_PLAYRATE', original_before.rate
)
reaper.SetMediaItemInfo_Value(copy_item, 'B_LOOPSRC', original_before.loop)
reaper.SetMediaItemInfo_Value(
  copy_item, 'D_FADEINLEN', original_before.fade_in
)
reaper.SetMediaItemInfo_Value(
  copy_item, 'D_FADEOUTLEN', original_before.fade_out
)
reaper.SetMediaItemInfo_Value(
  copy_item, 'C_FADEINSHAPE', original_before.fade_in_shape
)
reaper.SetMediaItemInfo_Value(
  copy_item, 'C_FADEOUTSHAPE', original_before.fade_out_shape
)

local copy_before = snapshot(copy_item, copy_take)
dump('copy_before', copy_before)

for i = 0, reaper.CountMediaItems(0) - 1 do
  reaper.SetMediaItemSelected(reaper.GetMediaItem(0, i), false)
end
reaper.SetMediaItemSelected(copy_item, true)

local chunk, err = loadfile(DEFAULT)

if not chunk then
  log('LOADFILE_FAILED ' .. tostring(err))
else
  local ok, run_err = xpcall(chunk, debug.traceback)

  if not ok then
    log('RUN_FAILED ' .. tostring(run_err))
  end
end

local copy_after = snapshot(copy_item, copy_take)
local original_after = snapshot(source_item, source_take)
dump('copy_after', copy_after)
dump('original_after', original_after)

local copy_changed =
  math.abs(copy_after.position - copy_before.position) > 1e-9
  or math.abs(copy_after.length - copy_before.length) > 1e-9
  or math.abs(copy_after.start_offset - copy_before.start_offset) > 1e-9
  or math.abs(copy_after.fade_in - copy_before.fade_in) > 1e-9
  or math.abs(copy_after.fade_out - copy_before.fade_out) > 1e-9

local original_unchanged =
  math.abs(original_after.position - original_before.position) <= 1e-9
  and math.abs(original_after.length - original_before.length) <= 1e-9
  and math.abs(original_after.start_offset - original_before.start_offset) <= 1e-9
  and math.abs(original_after.fade_in - original_before.fade_in) <= 1e-9
  and math.abs(original_after.fade_out - original_before.fade_out) <= 1e-9

log('copy_changed=' .. tostring(copy_changed))
log('original_unchanged=' .. tostring(original_unchanged))
log('loop_repeats=' .. tostring(
  (copy_before.start_offset + copy_before.length)
    > (source_length + 0.0005)
))

reaper.DeleteTrack(temp_track)

for i = 0, reaper.CountMediaItems(0) - 1 do
  reaper.SetMediaItemSelected(reaper.GetMediaItem(0, i), false)
end
reaper.SetMediaItemSelected(source_item, true)
reaper.SetEditCurPos(saved_cursor, false, false)
reaper.UpdateArrange()
log('DONE')
report:close()
