-- DSH in-REAPER verification harness for TrimLeadingTrailingSilence.lua
-- Runs inside the currently open REAPER instance (via -nonewinst).
-- Creates a temporary track and synthetic items, runs headless copies of the
-- script, checks item geometry/fades, then removes the temporary track.

local info = debug.getinfo(1, "S")
local SCRIPT_PATH = info.source:gsub("^@", "")
local SCRIPT_DIR = SCRIPT_PATH:match("^(.*)[\\/]") or "."
local ROOT = SCRIPT_DIR .. "/../.."
local MEDIA = SCRIPT_DIR .. "/test-media"
local REPORT = SCRIPT_DIR .. "/synthetic-report.txt"
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

local function make_variant(name, replacements)
  local text = read_all(ROOT .. "/TrimLeadingTrailingSilence.lua")

  text = text:gsub(
    "show_settings_window%s*=%s*true",
    "show_settings_window = false", 1
  )
  text = text:gsub(
    "show_summary%s*=%s*true",
    "show_summary    = false", 1
  )

  for _, pair in ipairs(replacements or {}) do
    local count
    text, count = text:gsub(pair[1], pair[2], 1)
    assert(count == 1, "variant replacement failed: " .. pair[1])
  end

  local path = GENERATED .. "/" .. name
  write_all(path, text)
  return path
end

local report = assert(io.open(REPORT, 'w'))
local pass, fail = 0, 0

local function log(text)
  report:write(tostring(text) .. '\n')
  report:flush()
end

local function near(a, b, tol)
  return math.abs(a - b) <= (tol or 0.0005)
end

local function expect_near(label, actual, expected, tol)
  if not near(actual, expected, tol) then
    error(string.format(
      '%s: actual=%.9f expected=%.9f', label, actual, expected
    ), 2)
  end
end

local function expect_equal(label, actual, expected)
  if actual ~= expected then
    error(string.format(
      '%s: actual=%s expected=%s',
      label, tostring(actual), tostring(expected)
    ), 2)
  end
end

-- Avoid polluting the user's undo history and avoid modal boxes.
reaper.Undo_BeginBlock2 = function() end
reaper.Undo_EndBlock2 = function() end
reaper.ShowMessageBox = function(text, title)
  log('MSGBOX: ' .. tostring(title) .. ' :: ' .. tostring(text))
  return 0
end

-- Saved project state.
local saved_selected = {}
local saved_cursor = reaper.GetCursorPosition()
local original_track = reaper.GetTrack(0, 0)
local original_item_count = original_track
  and reaper.CountTrackMediaItems(original_track) or -1

for i = 0, reaper.CountSelectedMediaItems(0) - 1 do
  saved_selected[#saved_selected + 1] = reaper.GetSelectedMediaItem(0, i)
end

-- Temporary track at the end of the project.
local original_track_count = reaper.CountTracks(0)
reaper.InsertTrackAtIndex(original_track_count, true)
local test_track = reaper.GetTrack(0, original_track_count)

if test_track then
  reaper.GetSetMediaTrackInfo_String(test_track, 'P_NAME', 'DSH_TEST_TEMP', true)
end

local function select_only(target)
  for i = 0, reaper.CountMediaItems(0) - 1 do
    local item = reaper.GetMediaItem(0, i)
    reaper.SetMediaItemSelected(item, item == target)
  end
end

local function make_item(wav, position, length, start_offset, options)
  options = options or {}
  local item = reaper.AddMediaItemToTrack(test_track)
  local take = reaper.AddTakeToMediaItem(item)
  local source = reaper.PCM_Source_CreateFromFile(wav)

  if not source then
    error('could not open source: ' .. wav)
  end

  reaper.SetMediaItemTake_Source(take, source)
  reaper.SetMediaItemInfo_Value(item, 'D_POSITION', position)
  reaper.SetMediaItemInfo_Value(item, 'D_LENGTH', length)
  reaper.SetMediaItemTakeInfo_Value(
    take, 'D_STARTOFFS', start_offset or 0
  )
  reaper.SetMediaItemInfo_Value(item, 'B_LOOPSRC', options.loop or 0)
  reaper.SetMediaItemInfo_Value(
    item, 'D_FADEINLEN', options.fade_in or 0
  )
  reaper.SetMediaItemInfo_Value(
    item, 'D_FADEOUTLEN', options.fade_out or 0
  )
  reaper.SetMediaItemInfo_Value(
    item, 'C_FADEINSHAPE', options.fade_in_shape or 0
  )
  reaper.SetMediaItemInfo_Value(
    item, 'C_FADEOUTSHAPE', options.fade_out_shape or 0
  )
  reaper.SetMediaItemInfo_Value(
    item, 'D_FADEINDIR', options.fade_in_dir or 0
  )
  reaper.SetMediaItemInfo_Value(
    item, 'D_FADEOUTDIR', options.fade_out_dir or 0
  )
  reaper.UpdateItemInProject(item)
  return item, take
end

local function values(item, take)
  return {
    position = reaper.GetMediaItemInfo_Value(item, 'D_POSITION'),
    length = reaper.GetMediaItemInfo_Value(item, 'D_LENGTH'),
    start_offset = reaper.GetMediaItemTakeInfo_Value(
      take, 'D_STARTOFFS'
    ),
    fade_in = reaper.GetMediaItemInfo_Value(item, 'D_FADEINLEN'),
    fade_out = reaper.GetMediaItemInfo_Value(item, 'D_FADEOUTLEN'),
    fade_in_shape = reaper.GetMediaItemInfo_Value(
      item, 'C_FADEINSHAPE'
    ),
    fade_out_shape = reaper.GetMediaItemInfo_Value(
      item, 'C_FADEOUTSHAPE'
    ),
    fade_in_dir = reaper.GetMediaItemInfo_Value(item, 'D_FADEINDIR'),
    fade_out_dir = reaper.GetMediaItemInfo_Value(item, 'D_FADEOUTDIR'),
  }
end

local function dump(label, v)
  log(string.format(
    '%s pos=%.9f len=%.9f soffs=%.9f fin=%.9f fout=%.9f '
      .. 'shape=%.0f/%.0f dir=%.3f/%.3f',
    label, v.position, v.length, v.start_offset,
    v.fade_in, v.fade_out,
    v.fade_in_shape, v.fade_out_shape,
    v.fade_in_dir, v.fade_out_dir
  ))
end

local function run_variant(path)
  local chunk, err = loadfile(path)

  if not chunk then
    error('loadfile failed: ' .. tostring(err))
  end

  chunk()
end

local function test_case(name, fn)
  local ok, err = xpcall(fn, debug.traceback)

  if ok then
    pass = pass + 1
    log('PASS ' .. name)
  else
    fail = fail + 1
    log('FAIL ' .. name .. ' :: ' .. tostring(err))
  end
end

local DEFAULT = make_variant("default.lua")
local THRESHOLD40 = make_variant("threshold40.lua", {
  { "threshold_db%s*=%s*-80%.0", "threshold_db    = -40.0" },
})
local PADS0 = make_variant("pads0.lua", {
  { "leading_pad_ms%s*=%s*30%.0", "leading_pad_ms  = 0.0" },
  { "trailing_pad_ms%s*=%s*100%.0", "trailing_pad_ms = 0.0" },
})
local PRESERVE = make_variant("preserve.lua", {
  { 'fade_policy%s*=%s*"short"', 'fade_policy     = "preserve"' },
})
local VOICE = MEDIA .. "/voice5.wav"
local OFFSET = MEDIA .. "/offset6.wav"
local HUM = MEDIA .. "/hum2.wav"
local SILENCE = MEDIA .. "/silence2.wav"
local STEREO = MEDIA .. "/stereo5.wav"

for _, path in ipairs({ VOICE, OFFSET, HUM, SILENCE, STEREO }) do
  local file = io.open(path, "rb")
  assert(file, "missing " .. path .. "; run python make_test_media.py")
  file:close()
end

local function run_tests()
  log('project=' .. tostring(reaper.GetProjectName(0, '')))
  log('tracks_before=' .. original_track_count)
  log('original_items_on_track0=' .. tostring(original_item_count))

  test_case('A default voice item at 100s', function()
    local item, take = make_item(VOICE, 100, 5, 0)
    local count_before = reaper.CountTrackMediaItems(test_track)
    select_only(item)
    run_variant(DEFAULT)
    local v = values(item, take)
    dump('A', v)
    expect_near('A position', v.position, 100.37)
    expect_near('A length', v.length, 4.43)
    expect_near('A start offset', v.start_offset, 0.37)
    expect_near('A fade in', v.fade_in, 0.002, 1e-7)
    expect_near('A fade out', v.fade_out, 0.005, 1e-7)
    expect_equal('A fade-in shape', v.fade_in_shape, 0)
    expect_equal('A fade-out shape', v.fade_out_shape, 0)
    expect_near('A content position',
      v.position + (2.5 - v.start_offset), 102.5, 1e-6)
    expect_equal('A no extra items',
      reaper.CountTrackMediaItems(test_track), count_before)
  end)

  test_case('B source start offset 2s', function()
    local item, take = make_item(OFFSET, 200, 3, 2.0)
    select_only(item)
    run_variant(DEFAULT)
    local v = values(item, take)
    dump('B', v)
    expect_near('B position', v.position, 200.47)
    expect_near('B length', v.length, 1.83)
    expect_near('B start offset', v.start_offset, 2.47)
    expect_near('B fade in', v.fade_in, 0.002, 1e-7)
    expect_near('B fade out', v.fade_out, 0.005, 1e-7)
    expect_near('B content position',
      v.position + (3.0 - v.start_offset), 201.0, 1e-6)
  end)

  test_case('C existing fades are reset to short linear', function()
    local item, take = make_item(VOICE, 300, 5, 0, {
      fade_in = 0.5,
      fade_out = 0.3,
      fade_in_shape = 2,
      fade_out_shape = 3,
      fade_in_dir = 0.5,
      fade_out_dir = -0.5,
    })
    select_only(item)
    run_variant(DEFAULT)
    local v = values(item, take)
    dump('C', v)
    expect_near('C position', v.position, 300.37)
    expect_near('C length', v.length, 4.43)
    expect_near('C fade in', v.fade_in, 0.002, 1e-7)
    expect_near('C fade out', v.fade_out, 0.005, 1e-7)
    expect_equal('C fade-in shape', v.fade_in_shape, 0)
    expect_equal('C fade-out shape', v.fade_out_shape, 0)
    expect_near('C fade-in curve', v.fade_in_dir, 0, 1e-9)
    expect_near('C fade-out curve', v.fade_out_dir, 0, 1e-9)
  end)

  test_case('D repeating loop source is skipped untouched', function()
    local item, take = make_item(VOICE, 400, 6, 0, {
      loop = 1,
      fade_in = 0.1,
      fade_out = 0.1,
    })
    select_only(item)
    run_variant(DEFAULT)
    local v = values(item, take)
    dump('D', v)
    expect_near('D position', v.position, 400)
    expect_near('D length', v.length, 6)
    expect_near('D fade in', v.fade_in, 0.1, 1e-7)
    expect_near('D fade out', v.fade_out, 0.1, 1e-7)
  end)

  test_case('E loop flag without repetition is processed', function()
    local item, take = make_item(VOICE, 500, 5, 0, { loop = 1 })
    select_only(item)
    run_variant(DEFAULT)
    local v = values(item, take)
    dump('E', v)
    expect_near('E position', v.position, 500.37)
    expect_near('E length', v.length, 4.43)
    expect_near('E start offset', v.start_offset, 0.37)
  end)

  test_case('F steady hum above -80 prevents trimming', function()
    local item, take = make_item(HUM, 600, 2, 0)
    select_only(item)
    run_variant(DEFAULT)
    local v = values(item, take)
    dump('F', v)
    expect_near('F position', v.position, 600)
    expect_near('F length', v.length, 2)
    expect_near('F fade in', v.fade_in, 0)
  end)

  test_case('G threshold -40 trims the hum', function()
    local item, take = make_item(HUM, 700, 2, 0)
    select_only(item)
    run_variant(THRESHOLD40)
    local v = values(item, take)
    dump('G', v)
    expect_near('G position', v.position, 700.47)
    expect_near('G length', v.length, 1.53)
    expect_near('G start offset', v.start_offset, 0.47)
    expect_near('G fade in', v.fade_in, 0.002, 1e-7)
    expect_near('G fade out', v.fade_out, 0)
  end)

  test_case('H zero pads trim full silence', function()
    local item, take = make_item(VOICE, 800, 5, 0)
    select_only(item)
    run_variant(PADS0)
    local v = values(item, take)
    dump('H', v)
    expect_near('H position', v.position, 800.4)
    expect_near('H length', v.length, 4.3)
  end)

  test_case('I item at project zero', function()
    local item, take = make_item(VOICE, 0, 5, 0)
    select_only(item)
    run_variant(DEFAULT)
    local v = values(item, take)
    dump('I', v)
    expect_near('I position', v.position, 0.37)
    expect_near('I length', v.length, 4.43)
  end)

  test_case('J fully silent item is skipped', function()
    local item, take = make_item(SILENCE, 900, 2, 0)
    select_only(item)
    run_variant(DEFAULT)
    local v = values(item, take)
    dump('J', v)
    expect_near('J position', v.position, 900)
    expect_near('J length', v.length, 2)
    expect_near('J fade in', v.fade_in, 0)
  end)

  test_case('K stereo source with one audible channel', function()
    local item, take = make_item(STEREO, 1000, 5, 0)
    select_only(item)
    run_variant(DEFAULT)
    local v = values(item, take)
    dump('K', v)
    expect_near('K position', v.position, 1000.37)
    expect_near('K length', v.length, 4.43)
  end)

  test_case('L negative source offset', function()
    local item, take = make_item(VOICE, 1100, 6, -1.0)
    select_only(item)
    run_variant(DEFAULT)
    local v = values(item, take)
    dump('L', v)
    expect_near('L position', v.position, 1101.37)
    expect_near('L length', v.length, 4.43)
    expect_near('L start offset', v.start_offset, 0.37)
    expect_near('L content position',
      v.position + (3.0 - v.start_offset), 1104.0, 1e-6)
  end)

  test_case('M preserve policy shortens existing fades', function()
    local item, take = make_item(VOICE, 1200, 5, 0, {
      fade_in = 0.5,
      fade_out = 0.3,
      fade_in_shape = 2,
      fade_out_shape = 3,
    })
    select_only(item)
    run_variant(PRESERVE)
    local v = values(item, take)
    dump('M', v)
    expect_near('M position', v.position, 1200.37)
    expect_near('M length', v.length, 4.43)
    expect_near('M fade in', v.fade_in, 0.13, 1e-7)
    expect_near('M fade out', v.fade_out, 0.1, 1e-7)
    expect_equal('M fade-in shape', v.fade_in_shape, 2)
    expect_equal('M fade-out shape', v.fade_out_shape, 3)
  end)
end

local function cleanup()
  if test_track then
    pcall(reaper.DeleteTrack, test_track)
    test_track = nil
  end

  for i = 0, reaper.CountMediaItems(0) - 1 do
    reaper.SetMediaItemSelected(reaper.GetMediaItem(0, i), false)
  end

  for _, item in ipairs(saved_selected) do
    pcall(reaper.SetMediaItemSelected, item, true)
  end

  pcall(reaper.SetEditCurPos, saved_cursor, false, false)
  pcall(reaper.UpdateArrange)
end

local ok, err = xpcall(run_tests, debug.traceback)

if not ok then
  log('FATAL: ' .. tostring(err))
  fail = fail + 1
end

cleanup()

if original_track then
  local count_after = reaper.CountTrackMediaItems(original_track)
  log('original_items_after=' .. tostring(count_after))
  if count_after ~= original_item_count then
    fail = fail + 1
    log('FAIL original track item count changed')
  end
end

log(string.format('DONE pass=%d fail=%d', pass, fail))
report:close()
