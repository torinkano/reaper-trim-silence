-- Mock test harness for TrimLeadingTrailingSilence.lua
-- Runs the script against a simulated REAPER API. This validates the
-- detection/planning/trim math only; it is not a REAPER runtime test.

local SELF = debug.getinfo(1, "S").source:gsub("^@", "")
local SELF_DIR = SELF:match("^(.*)[\\/]") or "."
local SCRIPT = SELF_DIR .. "/../TrimLeadingTrailingSilence.lua"
local SR = 8000

local passed, failed = 0, 0
local failures = {}

local function near(a, b, tol)
  return math.abs(a - b) <= (tol or 1e-6)
end

local function check(cond, message)
  if not cond then
    error(message, 2)
  end
end

local function new_array(size)
  local buffer = {}
  for i = 1, size do
    buffer[i] = 0
  end
  function buffer.clear()
    for i = 1, size do
      buffer[i] = 0
    end
  end
  return buffer
end

local function make_source(duration, channels, sampler)
  local frames = math.floor(duration * SR + 0.5)
  local source = {
    duration = duration,
    sample_rate = SR,
    channels = channels,
    section = false,
    reversed = false,
    samples = {},
    frames = frames,
  }

  for channel = 1, channels do
    local data = {}
    for frame = 1, frames do
      local t = (frame - 1) / SR
      local value = sampler(t, channel)
      if not value then
        value = 0
      end
      data[frame] = value
    end
    source.samples[channel] = data
  end

  return source
end

local function make_mock()
  local mock = {
    selected = {},
    tracks = {},
    message = nil,
    message_title = nil,
    console = {},
    messages = {},
    extstate = {},
    imgui_enabled = false,
    deferred = nil,
    undo_begin_count = 0,
    undo_end_count = 0,
    ui_depth = 0,
    undo_open = false,
    api = {},
  }

  local api = mock.api

  function api.APIExists(name)
    if name:sub(1, 5) == "ImGui" then
      return mock.imgui_enabled and api[name] ~= nil
    end
    return api[name] ~= nil
  end

  function api.defer(callback)
    mock.deferred = callback
  end

  function api.CountSelectedMediaItems()
    return #mock.selected
  end

  function api.GetSelectedMediaItem(project, index)
    return mock.selected[index + 1]
  end

  function api.GetActiveTake(item)
    return item.takes[item.active_take]
  end

  function api.GetMediaItemTake(item, index)
    return item.takes[index + 1]
  end

  function api.CountTakes(item)
    return #item.takes
  end

  function api.TakeIsMIDI(take)
    return take.midi == true
  end

  function api.GetTakeNumStretchMarkers(take)
    return take.stretch_markers or 0
  end

  function api.GetMediaItemTake_Source(take)
    return take.source
  end

  function api.GetMediaSourceNumChannels(source)
    return source and source.channels or 0
  end

  function api.GetMediaSourceSampleRate(source)
    return source and source.sample_rate or 0
  end

  function api.GetMediaSourceLength(source)
    if not source then
      return 0, false
    end
    return source.duration or 0, source.beat_based or false
  end

  function api.PCM_Source_GetSectionInfo(source)
    if not source then
      return false
    end
    return source.section or false, 0, source.duration or 0, source.reversed or false
  end

  function api.GetMediaItemTake_Track(take)
    return take.track
  end

  function api.GetMediaItemTake_Item(take)
    return take.item
  end

  function api.CountTrackMediaItems(track)
    return #track.items
  end

  function api.GetTrackMediaItem(track, index)
    return track.items[index + 1]
  end

  function api.GetMediaTrackInfo_Value(track, parm)
    if parm == "C_LOCK" then
      return track.lock or 0
    end
    return 0
  end

  local function item_get(item, parm)
    if parm == "D_POSITION" then return item.position end
    if parm == "D_LENGTH" then return item.length end
    if parm == "C_LOCK" then return item.lock or 0 end
    if parm == "B_LOOPSRC" then return item.loop or 0 end
    if parm == "B_ALLTAKESPLAY" then return item.all_takes_play or 0 end
    if parm == "D_FADEINLEN" then return item.fade_in or 0 end
    if parm == "D_FADEOUTLEN" then return item.fade_out or 0 end
    if parm == "D_FADEINLEN_AUTO" then return item.fade_in_auto or -1 end
    if parm == "D_FADEOUTLEN_AUTO" then return item.fade_out_auto or -1 end
    if parm == "C_FADEINSHAPE" then return item.fade_in_shape or 0 end
    if parm == "C_FADEOUTSHAPE" then return item.fade_out_shape or 0 end
    if parm == "D_FADEINDIR" then return item.fade_in_dir or 0 end
    if parm == "D_FADEOUTDIR" then return item.fade_out_dir or 0 end
    if parm == "D_SNAPOFFSET" then return item.snap_offset or 0 end
    if parm == "I_GROUPID" then return item.group or 0 end
    return 0
  end

  function api.GetMediaItemInfo_Value(item, parm)
    return item_get(item, parm)
  end

  function api.SetMediaItemInfo_Value(item, parm, value)
    if item.fail_apply and parm == "D_LENGTH" then
      error("simulated apply failure")
    end
    if parm == "D_POSITION" then item.position = value
    elseif parm == "D_LENGTH" then item.length = value
    elseif parm == "C_LOCK" then item.lock = value
    elseif parm == "B_LOOPSRC" then item.loop = value
    elseif parm == "B_ALLTAKESPLAY" then item.all_takes_play = value
    elseif parm == "D_FADEINLEN" then item.fade_in = value
    elseif parm == "D_FADEOUTLEN" then item.fade_out = value
    elseif parm == "D_FADEINLEN_AUTO" then item.fade_in_auto = value
    elseif parm == "D_FADEOUTLEN_AUTO" then item.fade_out_auto = value
    elseif parm == "C_FADEINSHAPE" then item.fade_in_shape = value
    elseif parm == "C_FADEOUTSHAPE" then item.fade_out_shape = value
    elseif parm == "D_FADEINDIR" then item.fade_in_dir = value
    elseif parm == "D_FADEOUTDIR" then item.fade_out_dir = value
    elseif parm == "D_SNAPOFFSET" then item.snap_offset = value
    elseif parm == "I_GROUPID" then item.group = value
    end
    return true
  end

  function api.GetMediaItemTakeInfo_Value(take, parm)
    if parm == "D_STARTOFFS" then return take.start_offset or 0 end
    if parm == "D_PLAYRATE" then return take.rate or 1 end
    if parm == "D_VOL" then return take.volume or 1 end
    if parm == "D_PAN" then return 0 end
    return 0
  end

  function api.SetMediaItemTakeInfo_Value(take, parm, value)
    if parm == "D_STARTOFFS" then take.start_offset = value
    elseif parm == "D_PLAYRATE" then take.rate = value
    elseif parm == "D_VOL" then take.volume = value
    end
    return true
  end

  function api.CountTakeEnvelopes(take)
    return #(take.envelopes or {})
  end

  function api.GetTakeEnvelope(take, index)
    return take.envelopes[index + 1]
  end

  function api.CountEnvelopePoints(envelope)
    return #envelope.points
  end

  function api.GetEnvelopePoint(envelope, index)
    local point = envelope.points[index + 1]
    if not point then
      return false
    end
    return true, point.time, point.value, point.shape or 0,
      point.tension or 0, point.selected or false
  end

  function api.SetEnvelopePoint(envelope, index, time, value, shape, tension, selected, no_sort)
    local point = envelope.points[index + 1]
    if point then
      if time ~= nil then point.time = time end
      if value ~= nil then point.value = value end
      if shape ~= nil then point.shape = shape end
      if tension ~= nil then point.tension = tension end
      if selected ~= nil then point.selected = selected end
    end
    return true
  end

  function api.Envelope_SortPoints(envelope)
    table.sort(envelope.points, function(a, b) return a.time < b.time end)
    return true
  end

  function api.CreateTakeAudioAccessor(take)
    mock.accessor_creations = (mock.accessor_creations or 0) + 1

    if take and take.no_accessor then
      return nil
    end
    return { take = take }
  end

  function api.DestroyAudioAccessor(accessor)
  end

  function api.GetAudioAccessorEndTime(accessor)
    local take = accessor.take
    local item = take.item
    local source = take.source
    local start_offset = take.start_offset or 0
    local source_end

    if start_offset >= 0 then
      source_end = (source.duration or 0) - start_offset
    else
      source_end = -start_offset + (source.duration or 0)
    end

    if source_end < 0 then
      source_end = 0
    end

    return math.min(item.length, source_end)
  end

  function api.GetAudioAccessorSamples(accessor, sample_rate, channels, start_time, frames, buffer)
    if mock.fail_read then
      return -1
    end

    local take = accessor.take
    local source = take.source

    if not source then
      return 0
    end

    local source_rate = source.sample_rate
    local base_source_time = (take.start_offset or 0) + start_time * (take.rate or 1)
    local any = false

    for frame = 0, frames - 1 do
      local source_time = base_source_time + frame / sample_rate
      local source_frame = math.floor(source_time * source_rate + 0.5) + 1

      for channel = 1, channels do
        local value = 0

        if source_frame >= 1 and source_frame <= source.frames
          and source.samples[channel] then
          value = source.samples[channel][source_frame]
        end

        buffer[frame * channels + channel] = value

        if value ~= 0 then
          any = true
        end
      end
    end

    if any then
      return 1
    end
    return 0
  end

  function api.new_array(size)
    return new_array(size)
  end

  function api.Undo_BeginBlock2()
    mock.undo_open = true
    mock.undo_begin_count = mock.undo_begin_count + 1
  end

  function api.Undo_EndBlock2()
    mock.undo_open = false
    mock.undo_end_count = mock.undo_end_count + 1
  end

  function api.PreventUIRefresh(delta)
    mock.ui_depth = mock.ui_depth + (delta or 0)
  end

  function api.UpdateArrange()
  end

  function api.UpdateItemInProject()
  end

  function api.ShowMessageBox(text, title, flags)
    mock.messages[#mock.messages + 1] = { text = text, title = title }
    mock.message = text
    mock.message_title = title
    return 0
  end

  function api.ShowConsoleMsg(text)
    mock.console[#mock.console + 1] = text
  end

  function api.GetExtState(section, key)
    local values = mock.extstate[section]
    if not values then
      return ""
    end
    return values[key] or ""
  end

  function api.SetExtState(section, key, value)
    if not mock.extstate[section] then
      mock.extstate[section] = {}
    end
    mock.extstate[section][key] = value
  end

  function api.GetUserInputs(title, count, captions, defaults)
    -- Simulate pressing OK without editing anything.
    return true, defaults
  end

  function api.time_precise()
    mock.time = (mock.time or 0) + 1.0
    return mock.time
  end

  function api.GetCursorPosition()
    return mock.cursor or 0
  end

  function api.SetEditCurPos(position)
    mock.cursor = position
  end

  function api.Main_OnCommand()
  end

  function api.GetSet_ArrangeView2(proj, is_set, x1, x2, start_time, end_time)
    if is_set then
      mock.arrange_start = start_time
      mock.arrange_end = end_time
      return start_time, end_time
    end
    mock.arrange_start = mock.arrange_start or 0
    mock.arrange_end = mock.arrange_end or 20
    return mock.arrange_start, mock.arrange_end
  end

  function api.ImGui_Cond_FirstUseEver()
    return 4
  end

  function api.ImGui_MouseButton_Right()
    return 1
  end

  function api.ImGui_CreateContext(name)
    return { name = name }
  end

  function api.ImGui_Begin(ctx, name, open)
    return true, mock.imgui_p_open ~= false
  end

  function api.ImGui_End()
  end

  function api.ImGui_SetNextWindowSize()
  end

  function api.ImGui_SliderDouble(ctx, label, value, min_value, max_value, format)
    mock.last_slider_label = label

    if label == "Threshold (dBFS)" and mock.imgui_threshold then
      return true, mock.imgui_threshold
    end

    if label == "Fade in (ms)" and mock.imgui_fade_in then
      return true, mock.imgui_fade_in
    end

    return false, value
  end

  function api.ImGui_InputDouble(ctx, label, value, step, step_fast, format)
    if mock.imgui_input_value then
      return not mock.imgui_input_retval_false, mock.imgui_input_value
    end
    return false, value
  end

  function api.ImGui_Checkbox(ctx, label, value)
    return false, value
  end

  function api.ImGui_Button(ctx, label, width, height)
    return mock.imgui_click_button == label
  end

  function api.ImGui_SameLine()
  end

  function api.ImGui_Text()
  end

  function api.ImGui_TextWrapped()
  end

  function api.ImGui_Separator()
  end

  function api.ImGui_Spacing()
  end

  function api.ImGui_SetNextItemWidth()
  end

  function api.ImGui_IsItemHovered()
    return mock.imgui_hovered == true
      and mock.last_slider_label == mock.imgui_hover_label
  end

  function api.ImGui_IsMouseClicked(ctx, button)
    return mock.imgui_right_clicked == true and button == 1
  end

  function api.ImGui_OpenPopup(ctx, id)
    mock.opened_popup = id
  end

  function api.ImGui_BeginPopup(ctx, id)
    return mock.imgui_popup_open == true and mock.opened_popup == id
  end

  function api.ImGui_EndPopup()
  end

  function api.ImGui_CloseCurrentPopup()
  end

  function api.ImGui_IsKeyPressed()
    return false
  end

  function api.ImGui_SetKeyboardFocusHere()
  end

  return mock
end

local function load_script(mock, replacements)
  local file = assert(io.open(SCRIPT, "r"))
  local source = file:read("*a")
  file:close()

  for _, replacement in ipairs(replacements or {}) do
    local new_source, count = source:gsub(replacement[1], replacement[2], 1)
    assert(count == 1, "test transform did not match: " .. replacement[1])
    source = new_source
  end

  _G.reaper = mock.api
  local chunk, err = load(source, "@" .. SCRIPT)
  assert(chunk, err)
  chunk()
end

local function make_track(mock)
  local track = { items = {}, lock = 0 }
  mock.tracks[#mock.tracks + 1] = track
  return track
end

local function add_item(mock, track, options)
  local item = {
    position = options.position or 0,
    length = options.length or 0,
    track = track,
    takes = options.takes,
    active_take = options.active_take or 1,
    lock = options.lock or 0,
    loop = options.loop or 0,
    all_takes_play = options.all_takes_play or 0,
    fade_in = options.fade_in or 0,
    fade_out = options.fade_out or 0,
    fade_in_auto = options.fade_in_auto or -1,
    fade_out_auto = options.fade_out_auto or -1,
    fade_in_shape = options.fade_in_shape or 0,
    fade_out_shape = options.fade_out_shape or 0,
    fade_in_dir = options.fade_in_dir or 0,
    fade_out_dir = options.fade_out_dir or 0,
    snap_offset = 0,
    group = 0,
  }

  for _, take in ipairs(item.takes) do
    take.item = item
    take.track = track
  end

  track.items[#track.items + 1] = item

  if options.selected ~= false then
    mock.selected[#mock.selected + 1] = item
  end

  return item
end

local function new_take(source, options)
  options = options or {}
  return {
    source = source,
    start_offset = options.start_offset or 0,
    rate = options.rate or 1,
    midi = options.midi or false,
    stretch_markers = options.stretch_markers or 0,
    volume = 1,
    envelopes = options.envelopes or {},
  }
end

local function voice_pattern(t)
  if t < 0.4 then return 0 end
  if t < 1.0 then return 0.2 end
  if t < 2.0 then return 0 end
  if t < 4.7 then return 0.2 end
  return 0
end

local tests = {}

local function add_test(name, fn)
  tests[#tests + 1] = { name = name, fn = fn }
end


add_test("normal voice item at 10s: edges only, internal pause preserved", function()
  local mock = make_mock()
  local track = make_track(mock)
  local source = make_source(5.0, 1, voice_pattern)
  local take = new_take(source)
  local item = add_item(mock, track, {
    position = 10.0,
    length = 5.0,
    takes = { take },
  })

  load_script(mock)

  check(near(item.position, 10.37), "position: " .. tostring(item.position))
  check(near(item.length, 4.43), "length: " .. tostring(item.length))
  check(near(take.start_offset, 0.37), "start offset: " .. tostring(take.start_offset))
  check(near(item.fade_in, 0.002), "fade in: " .. tostring(item.fade_in))
  check(near(item.fade_out, 0.005), "fade out: " .. tostring(item.fade_out))
  check(mock.message and mock.message:find("left 1, right 1", 1, true) ~= nil,
    "summary should count both edges: " .. tostring(mock.message))

  -- The source sample at 2.5 s must still be heard at 12.5 s.
  local before = 10.0 + 2.5
  local after = item.position + (2.5 - take.start_offset)
  check(near(before, after, 1e-9), "content moved on the timeline")
end)

add_test("loop source flag without actual repetition is processed", function()
  local mock = make_mock()
  local track = make_track(mock)
  local source = make_source(5.0, 1, voice_pattern)
  local take = new_take(source)
  local item = add_item(mock, track, {
    position = 10.0,
    length = 5.0,
    takes = { take },
    loop = 1,
  })

  load_script(mock)

  check(near(item.position, 10.37), "position: " .. tostring(item.position))
  check(near(item.length, 4.43), "length: " .. tostring(item.length))
  check(near(take.start_offset, 0.37), "start offset")
  check(mock.message and not mock.message:find("loop source", 1, true),
    "non-repeating loop flag should not be reported as skipped")
end)

add_test("item at timeline zero, sound touching both edges: untouched", function()
  local mock = make_mock()
  local track = make_track(mock)
  local source = make_source(2.0, 1, function(t)
    return 0.2
  end)
  local take = new_take(source)
  local item = add_item(mock, track, {
    position = 0.0,
    length = 2.0,
    takes = { take },
    fade_in = 0.05,
    fade_out = 0.03,
  })

  load_script(mock)

  check(near(item.position, 0.0), "position changed")
  check(near(item.length, 2.0), "length changed")
  check(near(take.start_offset, 0.0), "start offset changed")
  check(near(item.fade_in, 0.05), "existing fade-in was overwritten")
  check(near(item.fade_out, 0.03), "existing fade-out was overwritten")
  check(mock.message and mock.message:find("Unchanged: 1", 1, true) ~= nil,
    "should report one unchanged item")
end)

add_test("source start offset 2s: trim math and content position", function()
  local mock = make_mock()
  local track = make_track(mock)
  local source = make_source(6.0, 1, function(t)
    if t >= 2.5 and t < 4.2 then
      return 0.2
    end
    return 0
  end)
  local take = new_take(source, { start_offset = 2.0 })
  local item = add_item(mock, track, {
    position = 20.0,
    length = 3.0,
    takes = { take },
  })

  load_script(mock)

  check(near(item.position, 20.47), "position: " .. tostring(item.position))
  check(near(item.length, 1.83), "length: " .. tostring(item.length))
  check(near(take.start_offset, 2.47), "start offset: " .. tostring(take.start_offset))

  local before = 20.0 + (3.0 - 2.0)
  local after = item.position + (3.0 - take.start_offset)
  check(near(before, after, 1e-9), "content at source 3.0s moved")
end)

add_test("quiet breath and weak tail above threshold are preserved", function()
  local mock = make_mock()
  local track = make_track(mock)
  local source = make_source(3.0, 1, function(t)
    if t >= 0.2 and t < 0.5 then
      return 0.001 -- -60 dBFS breath
    end
    if t >= 0.7 and t < 2.5 then
      return 0.2
    end
    if t >= 2.5 and t < 2.9 then
      return 0.0005 -- -66 dBFS tail
    end
    return 0
  end)
  local take = new_take(source)
  local item = add_item(mock, track, {
    position = 5.0,
    length = 3.0,
    takes = { take },
  })

  load_script(mock)

  check(near(item.position, 5.17), "position: " .. tostring(item.position))
  check(near(item.length, 2.83), "length: " .. tostring(item.length))
  check(near(item.fade_in, 0.002), "fade in")
  check(near(item.fade_out, 0.0), "untouched fade out should stay 0")
  check(near(take.start_offset, 0.17), "start offset")
end)

add_test("fully silent item is skipped and not modified", function()
  local mock = make_mock()
  local track = make_track(mock)
  local source = make_source(2.0, 1, function() return 0 end)
  local take = new_take(source)
  local item = add_item(mock, track, {
    position = 3.0,
    length = 2.0,
    takes = { take },
    fade_in = 0.01,
  })

  load_script(mock)

  check(near(item.position, 3.0), "position changed")
  check(near(item.length, 2.0), "length changed")
  check(near(take.start_offset, 0.0), "start offset changed")
  check(near(item.fade_in, 0.01), "fade changed")
  check(mock.message and mock.message:find("fully silent: 1", 1, true) ~= nil,
    "should report a silent item")
end)

add_test("default short policy resets existing fades on trimmed edges", function()
  local mock = make_mock()
  local track = make_track(mock)
  local source = make_source(5.0, 1, voice_pattern)
  local take = new_take(source)
  local item = add_item(mock, track, {
    position = 10.0,
    length = 5.0,
    takes = { take },
    fade_in = 0.5,
    fade_out = 0.3,
    fade_in_shape = 2,
    fade_out_shape = 3,
    fade_in_dir = 0.5,
    fade_out_dir = -0.5,
  })

  load_script(mock)

  check(near(item.fade_in, 0.002), "fade in: " .. tostring(item.fade_in))
  check(near(item.fade_out, 0.005), "fade out: " .. tostring(item.fade_out))
  check(near(item.fade_in_shape, 0), "fade-in shape should reset")
  check(near(item.fade_out_shape, 0), "fade-out shape should reset")
  check(near(item.fade_in_dir, 0), "fade-in curvature should reset")
  check(near(item.fade_out_dir, 0), "fade-out curvature should reset")
end)

add_test("preserve policy keeps existing fades over the same audio", function()
  local mock = make_mock()
  local track = make_track(mock)
  local source = make_source(5.0, 1, voice_pattern)
  local take = new_take(source)
  local item = add_item(mock, track, {
    position = 10.0,
    length = 5.0,
    takes = { take },
    fade_in = 0.5,
    fade_out = 0.3,
    fade_in_shape = 2,
    fade_out_shape = 3,
    fade_in_dir = 0.5,
    fade_out_dir = -0.5,
  })

  load_script(mock, {
    { 'fade_policy%s*=%s*"short"', 'fade_policy = "preserve"' },
  })

  check(near(item.fade_in, 0.13, 1e-9), "fade in: " .. tostring(item.fade_in))
  check(near(item.fade_out, 0.1, 1e-9), "fade out: " .. tostring(item.fade_out))
  check(near(item.fade_in_shape, 2), "fade-in shape should be preserved")
  check(near(item.fade_out_shape, 3), "fade-out shape should be preserved")
end)

add_test("old saved preserve policy is migrated to the new short default", function()
  local mock = make_mock()
  mock.extstate["TrimLeadingTrailingSilence"] = {
    fade_policy = "preserve",
  }
  local track = make_track(mock)
  local source = make_source(5.0, 1, voice_pattern)
  local take = new_take(source)
  local item = add_item(mock, track, {
    position = 10.0,
    length = 5.0,
    takes = { take },
    fade_in = 0.5,
    fade_out = 0.3,
  })

  load_script(mock)

  check(near(item.fade_in, 0.002), "fade in: " .. tostring(item.fade_in))
  check(near(item.fade_out, 0.005), "fade out: " .. tostring(item.fade_out))
end)

add_test("auto crossfade on the left edge: left kept, right trimmed", function()
  local mock = make_mock()
  local track = make_track(mock)
  local source = make_source(5.0, 1, voice_pattern)
  local take = new_take(source)
  local item = add_item(mock, track, {
    position = 10.0,
    length = 5.0,
    takes = { take },
    fade_in_auto = 0.5,
  })

  load_script(mock)

  check(near(item.position, 10.0), "left edge must not move")
  check(near(take.start_offset, 0.0), "left start offset must not move")
  check(near(item.length, 4.8), "right edge should be trimmed: " .. tostring(item.length))
  check(near(item.fade_in_auto, 0.5), "auto fade must be preserved")
  check(mock.message and mock.message:find("automatic crossfade: 1", 1, true) ~= nil,
    "should report auto-fade edge")
end)

add_test("overlap on the left edge: left kept, right trimmed", function()
  local mock = make_mock()
  local track = make_track(mock)
  local source = make_source(5.0, 1, voice_pattern)
  local take = new_take(source)
  local item = add_item(mock, track, {
    position = 10.0,
    length = 5.0,
    takes = { take },
  })

  local other_source = make_source(1.0, 1, function() return 0 end)
  local other_take = new_take(other_source)
  add_item(mock, track, {
    position = 9.9,
    length = 1.0,
    takes = { other_take },
    selected = false,
  })

  load_script(mock)

  check(near(item.position, 10.0), "left edge must not move")
  check(near(item.length, 4.8), "right edge should be trimmed: " .. tostring(item.length))
  check(mock.message and mock.message:find("overlap/crossfade: 1", 1, true) ~= nil,
    "should report overlap edge")
end)

add_test("multiple takes: both start offsets and take envelopes follow the trim", function()
  local mock = make_mock()
  local track = make_track(mock)
  local source = make_source(5.0, 1, voice_pattern)
  local envelope = {
    points = {
      { time = 1.0, value = 0.5, shape = 0, tension = 0, selected = false },
    },
  }
  local take_a = new_take(source)
  local take_b = new_take(source, { envelopes = { envelope } })
  local item = add_item(mock, track, {
    position = 10.0,
    length = 5.0,
    takes = { take_a, take_b },
    active_take = 1,
  })

  load_script(mock)

  check(near(take_a.start_offset, 0.37), "take A start offset")
  check(near(take_b.start_offset, 0.37), "take B start offset")
  check(near(envelope.points[1].time, 0.63, 1e-9),
    "take envelope time: " .. tostring(envelope.points[1].time))
  check(near(item.length, 4.43), "item length")
end)

add_test("take envelope point inside trimmed lead: item is skipped", function()
  local mock = make_mock()
  local track = make_track(mock)
  local source = make_source(5.0, 1, voice_pattern)
  local envelope = {
    points = {
      { time = 0.1, value = 0.5, shape = 0, tension = 0, selected = false },
    },
  }
  local take = new_take(source, { envelopes = { envelope } })
  local item = add_item(mock, track, {
    position = 10.0,
    length = 5.0,
    takes = { take },
  })

  load_script(mock)

  check(near(item.position, 10.0), "position changed")
  check(near(item.length, 5.0), "length changed")
  check(near(take.start_offset, 0.0), "start offset changed")
  check(near(envelope.points[1].time, 0.1), "envelope point changed")
  check(mock.message and mock.message:find(
    "take envelope point in trimmed lead: 1", 1, true
  ) ~= nil, "summary should report the skipped take envelope")
end)

add_test("preview_only changes nothing but reports would-be trims", function()
  local mock = make_mock()
  local track = make_track(mock)
  local source = make_source(5.0, 1, voice_pattern)
  local take = new_take(source)
  local item = add_item(mock, track, {
    position = 10.0,
    length = 5.0,
    takes = { take },
  })

  load_script(mock, {
    { 'preview_only%s*=%s*false', 'preview_only = true' },
  })

  check(near(item.position, 10.0), "position changed in preview")
  check(near(item.length, 5.0), "length changed in preview")
  check(near(take.start_offset, 0.0), "start offset changed in preview")
  check(mock.message and mock.message:find("PREVIEW ONLY", 1, true) ~= nil,
    "preview summary missing")
  check(mock.message and mock.message:find("Would trim: 1", 1, true) ~= nil,
    "preview should count trims")
end)

add_test("very short item: fade lengths are clamped to the new length", function()
  local mock = make_mock()
  local track = make_track(mock)
  local source = make_source(0.004, 1, function(t)
    if t >= 0.001 and t < 0.003 then
      return 0.2
    end
    return 0
  end)
  local take = new_take(source)
  local item = add_item(mock, track, {
    position = 0.0,
    length = 0.004,
    takes = { take },
  })

  load_script(mock, {
    { 'leading_pad_ms%s*=%s*30%.0', 'leading_pad_ms = 0.0' },
    { 'trailing_pad_ms%s*=%s*100%.0', 'trailing_pad_ms = 0.0' },
    { 'min_trim_ms%s*=%s*1%.0', 'min_trim_ms = 0.0' },
  })

  check(near(item.length, 0.002, 1e-9), "length: " .. tostring(item.length))
  check(item.fade_in >= 0 and item.fade_out >= 0, "negative fade")
  check(item.fade_in + item.fade_out <= item.length + 1e-9,
    "fades overlap: " .. tostring(item.fade_in) .. " + " .. tostring(item.fade_out))
end)


add_test("right-only trim: left edge and fade-in stay untouched", function()
  local mock = make_mock()
  local track = make_track(mock)
  local source = make_source(1.0, 1, function(t)
    if t < 0.4 then return 0.2 end
    return 0
  end)
  local take = new_take(source)
  local item = add_item(mock, track, {
    position = 2.0,
    length = 1.0,
    takes = { take },
    fade_in = 0.1,
    fade_out = 0.2,
  })

  load_script(mock)

  check(near(item.position, 2.0), "position changed")
  check(near(item.length, 0.5), "length: " .. tostring(item.length))
  check(near(item.fade_in, 0.1), "fade-in should not be touched")
  check(near(item.fade_out, 0.005), "fade-out should be short")
  check(near(take.start_offset, 0.0), "start offset changed")
end)

add_test("snap offset stays over the same audio after a left trim", function()
  local mock = make_mock()
  local track = make_track(mock)
  local source = make_source(5.0, 1, voice_pattern)
  local take = new_take(source)
  local item = add_item(mock, track, {
    position = 10.0,
    length = 5.0,
    takes = { take },
  })
  item.snap_offset = 0.5

  load_script(mock)

  check(near(item.position, 10.37), "position")
  check(near(item.snap_offset, 0.13), "snap offset: " .. tostring(item.snap_offset))
  check(near(item.position + item.snap_offset, 10.5, 1e-9),
    "absolute snap position moved")
end)

add_test("threshold setting changes detection (UI-derived value refresh)", function()
  local mock = make_mock()
  local track = make_track(mock)
  local source = make_source(2.0, 1, function(t)
    if t < 0.5 then return 0.001 end -- -60 dBFS hum
    return 0.2
  end)
  local take = new_take(source)
  local item = add_item(mock, track, {
    position = 0.0,
    length = 2.0,
    takes = { take },
  })

  load_script(mock, {
    { 'threshold_db%s*=%s*%-80%.0', 'threshold_db = -40.0' },
  })

  check(near(item.position, 0.47), "position: " .. tostring(item.position))
  check(near(item.length, 1.53), "length: " .. tostring(item.length))
  check(near(item.fade_in, 0.002), "fade in")
end)

add_test("pad settings change trim amount", function()
  local mock = make_mock()
  local track = make_track(mock)
  local source = make_source(5.0, 1, voice_pattern)
  local take = new_take(source)
  local item = add_item(mock, track, {
    position = 10.0,
    length = 5.0,
    takes = { take },
  })

  load_script(mock, {
    { 'leading_pad_ms%s*=%s*30%.0', 'leading_pad_ms = 0.0' },
    { 'trailing_pad_ms%s*=%s*100%.0', 'trailing_pad_ms = 0.0' },
  })

  check(near(item.position, 10.4), "position: " .. tostring(item.position))
  check(near(item.length, 4.3), "length: " .. tostring(item.length))
end)

add_test("steady low-level noise above threshold prevents trimming", function()
  local mock = make_mock()
  local track = make_track(mock)
  local source = make_source(2.0, 1, function() return 0.0003 end) -- -70 dBFS
  local take = new_take(source)
  local item = add_item(mock, track, {
    position = 0.0,
    length = 2.0,
    takes = { take },
  })

  load_script(mock)

  check(near(item.position, 0.0), "position changed")
  check(near(item.length, 2.0), "length changed")
  check(mock.message and mock.message:find("Unchanged: 1", 1, true) ~= nil,
    "low-level noise should count as sound")
end)

add_test("item longer than source: trailing source-less area is trimmed", function()
  local mock = make_mock()
  local track = make_track(mock)
  local source = make_source(2.0, 1, function(t)
    if t < 1.5 then return 0.2 end
    return 0
  end)
  local take = new_take(source)
  local item = add_item(mock, track, {
    position = 0.0,
    length = 3.0,
    takes = { take },
  })

  load_script(mock)

  check(near(item.length, 1.6), "length: " .. tostring(item.length))
  check(near(take.start_offset, 0.0), "start offset changed")
  check(near(item.fade_out, 0.005), "fade out")
end)

add_test("negative source offset: content position is preserved", function()
  local mock = make_mock()
  local track = make_track(mock)
  local source = make_source(3.0, 1, function(t)
    if t < 2.0 then return 0.2 end
    return 0
  end)
  local take = new_take(source, { start_offset = -1.0 })
  local item = add_item(mock, track, {
    position = 10.0,
    length = 4.0,
    takes = { take },
  })

  load_script(mock)

  check(near(item.position, 10.97), "position: " .. tostring(item.position))
  check(near(item.length, 2.13), "length: " .. tostring(item.length))
  check(near(take.start_offset, -0.03), "start offset: " .. tostring(take.start_offset))

  local before = 10.0 + (0.0 - (-1.0))
  local after = item.position + (0.0 - take.start_offset)
  check(near(before, after, 1e-9), "content at source 0s moved")
end)

add_test("untouched long fade is clamped, trimmed fade still added", function()
  local mock = make_mock()
  local track = make_track(mock)
  local source = make_source(1.0, 1, function(t)
    if t < 0.2 then return 0.2 end
    return 0
  end)
  local take = new_take(source)
  local item = add_item(mock, track, {
    position = 0.0,
    length = 1.0,
    takes = { take },
    fade_in = 0.5,
    fade_out = 0.1,
  })

  load_script(mock)

  check(near(item.length, 0.3), "length: " .. tostring(item.length))
  check(near(item.fade_out, 0.005), "trimmed fade-out should be short")
  check(item.fade_in <= item.length + 1e-9, "fade-in exceeds item")
  check(item.fade_in + item.fade_out <= item.length + 1e-9,
    "fades overlap: " .. tostring(item.fade_in) .. " + " .. tostring(item.fade_out))
end)

add_test("batch: mixed items, one undo block, selection preserved", function()
  local mock = make_mock()
  local track = make_track(mock)

  local voice_source = make_source(5.0, 1, voice_pattern)
  local voice_take = new_take(voice_source)
  local voice_item = add_item(mock, track, {
    position = 10.0,
    length = 5.0,
    takes = { voice_take },
  })

  local full_source = make_source(2.0, 1, function() return 0.2 end)
  local full_take = new_take(full_source)
  local full_item = add_item(mock, track, {
    position = 20.0,
    length = 2.0,
    takes = { full_take },
  })

  local silent_source = make_source(2.0, 1, function() return 0 end)
  local silent_take = new_take(silent_source)
  local silent_item = add_item(mock, track, {
    position = 30.0,
    length = 2.0,
    takes = { silent_take },
  })

  load_script(mock)

  check(near(voice_item.position, 10.37), "voice item position")
  check(near(voice_item.length, 4.43), "voice item length")
  check(near(full_item.position, 20.0), "full item changed")
  check(near(silent_item.position, 30.0), "silent item changed")
  check(mock.undo_begin_count == 1, "one undo block expected")
  check(mock.undo_end_count == 1, "undo block not closed")
  check(mock.ui_depth == 0, "UI refresh not restored")
  check(#mock.selected == 3, "selection count changed")

  check(mock.message and mock.message:find("Selected: 3", 1, true) ~= nil,
    "summary selected count")
  check(mock.message and mock.message:find("Trimmed: 1", 1, true) ~= nil,
    "summary trimmed count")
  check(mock.message and mock.message:find("Unchanged: 1", 1, true) ~= nil,
    "summary unchanged count")
  check(mock.message and mock.message:find("fully silent: 1", 1, true) ~= nil,
    "summary silent count")
end)

add_test("preview creates no undo block", function()
  local mock = make_mock()
  local track = make_track(mock)
  local source = make_source(5.0, 1, voice_pattern)
  local take = new_take(source)
  local item = add_item(mock, track, {
    position = 10.0,
    length = 5.0,
    takes = { take },
  })

  load_script(mock, {
    { 'preview_only%s*=%s*false', 'preview_only = true' },
  })

  check(near(item.position, 10.0), "preview changed the item")
  check(mock.undo_begin_count == 0, "preview must not open undo")
  check(mock.ui_depth == 0, "UI refresh depth")
end)

add_test("ImGui settings window Run commits the live preview", function()
  local mock = make_mock()
  mock.imgui_enabled = true
  mock.imgui_click_button = "Run"
  local track = make_track(mock)
  local source = make_source(5.0, 1, voice_pattern)
  local take = new_take(source)
  local item = add_item(mock, track, {
    position = 10.0,
    length = 5.0,
    takes = { take },
  })

  load_script(mock)

  -- The live preview is applied as soon as the window is built.
  check(near(item.position, 10.37), "initial live preview missing")
  check(mock.deferred ~= nil, "settings window should defer its loop")

  mock.deferred()

  check(near(item.position, 10.37), "GUI Run did not process the item")
  check(near(item.length, 4.43), "GUI Run length")
  check(mock.undo_begin_count == 1, "GUI Run should open one undo block")
  check(mock.undo_end_count == 1, "GUI Run undo block not closed")
  check(mock.ui_depth == 0, "GUI Run UI refresh depth")
end)

add_test("ImGui Cancel restores the original item state", function()
  local mock = make_mock()
  mock.imgui_enabled = true
  mock.imgui_click_button = "Cancel"
  local track = make_track(mock)
  local source = make_source(5.0, 1, voice_pattern)
  local take = new_take(source)
  local item = add_item(mock, track, {
    position = 10.0,
    length = 5.0,
    takes = { take },
    fade_in_shape = 2,
    fade_out_shape = 3,
    fade_in_dir = 0.5,
    fade_out_dir = -0.5,
  })

  load_script(mock)

  check(near(item.position, 10.37), "initial preview should be applied")
  check(near(take.start_offset, 0.37), "initial preview offset")
  check(near(item.fade_in_shape, 0), "preview should reset fade-in shape")

  mock.deferred()

  check(near(item.position, 10.0), "cancel did not restore position")
  check(near(item.length, 5.0), "cancel did not restore length")
  check(near(take.start_offset, 0.0), "cancel did not restore start offset")
  check(near(item.fade_in, 0.0), "cancel did not restore fade in")
  check(near(item.fade_out, 0.0), "cancel did not restore fade out")
  check(near(item.fade_in_shape, 2), "cancel did not restore fade-in shape")
  check(near(item.fade_out_shape, 3), "cancel did not restore fade-out shape")
  check(near(item.fade_in_dir, 0.5), "cancel did not restore fade-in curve")
  check(near(item.fade_out_dir, -0.5), "cancel did not restore fade-out curve")
  check(mock.undo_begin_count == 0, "cancel must not create undo")
  check(mock.ui_depth == 0, "cancel UI refresh depth")
end)

add_test("ImGui boundary navigation steps through item head and tail", function()
  local mock = make_mock()
  mock.imgui_enabled = true
  mock.imgui_click_button = "Next >"
  local track = make_track(mock)
  local source = make_source(5.0, 1, voice_pattern)
  local take = new_take(source)
  local item = add_item(mock, track, {
    position = 10.0,
    length = 5.0,
    takes = { take },
  })

  load_script(mock)

  check((mock.cursor or 0) == 0,
    "cursor should not move before navigation")

  mock.deferred()
  check(near(mock.cursor, 10.37), "first boundary should be item head")
  check(near(mock.arrange_start, 0.37),
    "first boundary should be centered: " .. tostring(mock.arrange_start))

  mock.deferred()
  check(near(mock.cursor, 14.8), "second boundary should be item tail")
  check(near(mock.arrange_start, 4.8),
    "second boundary should be centered: " .. tostring(mock.arrange_start))
end)

add_test("ImGui Cancel restores take envelope point times", function()
  local mock = make_mock()
  mock.imgui_enabled = true
  mock.imgui_click_button = "Cancel"
  local track = make_track(mock)
  local source = make_source(5.0, 1, voice_pattern)
  local envelope = {
    points = {
      { time = 1.0, value = 0.5, shape = 0, tension = 0, selected = false },
    },
  }
  local take = new_take(source, { envelopes = { envelope } })
  local item = add_item(mock, track, {
    position = 10.0,
    length = 5.0,
    takes = { take },
  })

  load_script(mock)

  check(near(envelope.points[1].time, 0.63, 1e-9),
    "preview should shift the envelope point")
  check(near(item.position, 10.37), "initial preview position")

  mock.deferred()

  check(near(envelope.points[1].time, 1.0, 1e-9),
    "cancel should restore the envelope point")
  check(near(item.position, 10.0), "cancel should restore the item")
end)

add_test("fade-only preview change does not rescan audio", function()
  local mock = make_mock()
  mock.imgui_enabled = true
  mock.imgui_fade_in = 10
  local track = make_track(mock)
  local source = make_source(5.0, 1, voice_pattern)
  local take = new_take(source)
  local item = add_item(mock, track, {
    position = 10.0,
    length = 5.0,
    takes = { take },
  })

  load_script(mock)

  local scans_after_initial = mock.accessor_creations
  check(scans_after_initial == 1, "initial preview should scan once")

  mock.deferred()

  check(near(item.fade_in, 0.010), "fade in: " .. tostring(item.fade_in))
  check(mock.accessor_creations == scans_after_initial,
    "fade-only change should not create another audio accessor")
end)

add_test("ImGui threshold slider actually changes detection", function()
  local mock = make_mock()
  mock.imgui_enabled = true
  mock.imgui_threshold = -40
  local track = make_track(mock)
  local source = make_source(2.0, 1, function(t)
    if t < 0.5 then return 0.001 end -- -60 dBFS hum
    return 0.2
  end)
  local take = new_take(source)
  local item = add_item(mock, track, {
    position = 0.0,
    length = 2.0,
    takes = { take },
  })

  load_script(mock)
  mock.deferred()

  check(near(item.position, 0.47), "position: " .. tostring(item.position))
  check(near(item.length, 1.53), "length: " .. tostring(item.length))
end)

add_test("right-click popup can type an exact threshold value", function()
  local mock = make_mock()
  mock.imgui_enabled = true
  mock.imgui_hovered = true
  mock.imgui_hover_label = "Threshold (dBFS)"
  mock.imgui_right_clicked = true
  mock.imgui_popup_open = true
  mock.imgui_input_value = -40

  local track = make_track(mock)
  local source = make_source(2.0, 1, function(t)
    if t < 0.5 then return 0.001 end -- -60 dBFS hum
    return 0.2
  end)
  local take = new_take(source)
  local item = add_item(mock, track, {
    position = 0.0,
    length = 2.0,
    takes = { take },
  })

  load_script(mock)
  mock.deferred()

  check(near(item.position, 0.47), "position: " .. tostring(item.position))
  check(near(item.length, 1.53), "length: " .. tostring(item.length))
end)

add_test("right-click popup value applies even without a changed flag", function()
  local mock = make_mock()
  mock.imgui_enabled = true
  mock.imgui_hovered = true
  mock.imgui_hover_label = "Threshold (dBFS)"
  mock.imgui_right_clicked = true
  mock.imgui_popup_open = true
  mock.imgui_input_value = -40
  mock.imgui_input_retval_false = true

  local track = make_track(mock)
  local source = make_source(2.0, 1, function(t)
    if t < 0.5 then return 0.001 end
    return 0.2
  end)
  local take = new_take(source)
  local item = add_item(mock, track, {
    position = 0.0,
    length = 2.0,
    takes = { take },
  })

  load_script(mock)
  mock.deferred()

  check(near(item.position, 0.47), "position: " .. tostring(item.position))
  check(near(item.length, 1.53), "length: " .. tostring(item.length))
end)

add_test("accessor read failure is reported and nothing is modified", function()
  local mock = make_mock()
  mock.fail_read = true
  local track = make_track(mock)
  local source = make_source(5.0, 1, voice_pattern)
  local take = new_take(source)
  local item = add_item(mock, track, {
    position = 10.0,
    length = 5.0,
    takes = { take },
  })

  load_script(mock)

  check(near(item.position, 10.0), "position changed")
  check(near(item.length, 5.0), "length changed")
  check(mock.undo_begin_count == 0, "no undo block expected")
  check(mock.ui_depth == 0, "UI refresh depth")
  check(mock.message and mock.message:find("Errors: 1", 1, true) ~= nil,
    "summary should report one error")
end)

add_test("accessor creation failure is skipped cleanly", function()
  local mock = make_mock()
  local track = make_track(mock)
  local source = make_source(5.0, 1, voice_pattern)
  local take = new_take(source)
  take.no_accessor = true
  local item = add_item(mock, track, {
    position = 10.0,
    length = 5.0,
    takes = { take },
  })

  load_script(mock)

  check(near(item.position, 10.0), "position changed")
  check(mock.undo_begin_count == 0, "no undo block expected")
  check(mock.message and mock.message:find("audio accessor failed: 1", 1, true) ~= nil,
    "summary should report the accessor failure")
end)

add_test("apply failure stops, closes undo/UI, and reports partial progress", function()
  local mock = make_mock()
  local track = make_track(mock)
  local source = make_source(5.0, 1, voice_pattern)
  local take = new_take(source)
  local item = add_item(mock, track, {
    position = 10.0,
    length = 5.0,
    takes = { take },
  })
  item.fail_apply = true

  load_script(mock)

  check(near(item.position, 10.0), "position changed")
  check(mock.undo_begin_count == 1, "undo should have started")
  check(mock.undo_end_count >= 1, "undo must be closed")
  check(mock.undo_open == false, "undo left open")
  check(mock.ui_depth == 0, "UI refresh left open")
  check(mock.messages[1] and mock.messages[1].text:find(
    "Applied 0 of 1 planned trims", 1, true
  ) ~= nil, "summary should report partial progress")
  check(mock.messages[#mock.messages]
    and mock.messages[#mock.messages].text:find(
      "Processing stopped", 1, true
    ) ~= nil, "error box missing")
end)

add_test("right-only trim clamps an out-of-range snap offset", function()
  local mock = make_mock()
  local track = make_track(mock)
  local source = make_source(1.0, 1, function(t)
    if t < 0.2 then return 0.2 end
    return 0
  end)
  local take = new_take(source)
  local item = add_item(mock, track, {
    position = 0.0,
    length = 1.0,
    takes = { take },
  })
  item.snap_offset = 0.9

  load_script(mock)

  check(near(item.length, 0.3), "length: " .. tostring(item.length))
  check(near(item.snap_offset, 0.3), "snap offset: " .. tostring(item.snap_offset))
end)

local unsupported_cases = {
  {
    name = "take playrate not 1.0 is skipped",
    label = "take playrate not 1.0: 1",
    configure = function(options, take)
      take.rate = 1.5
    end,
  },
  {
    name = "stretch markers are skipped",
    label = "stretch markers: 1",
    configure = function(options, take)
      take.stretch_markers = 1
    end,
  },
  {
    name = "repeating loop source is skipped",
    label = "loop source repeats (turn Loop source off): 1",
    configure = function(options)
      options.loop = 1
      options.length = 6.0
    end,
  },
  {
    name = "reversed source is skipped",
    label = "reversed source: 1",
    configure = function(options, take, source)
      source.reversed = true
    end,
  },
  {
    name = "locked item is skipped",
    label = "locked item: 1",
    configure = function(options)
      options.lock = 1
    end,
  },
  {
    name = "MIDI take is skipped",
    label = "MIDI take: 1",
    configure = function(options, take)
      take.midi = true
    end,
  },
  {
    name = "missing sample rate is skipped",
    label = "no source sample rate: 1",
    configure = function(options, take, source)
      source.sample_rate = 0
    end,
  },
  {
    name = "beat-based source is skipped",
    label = "beat-based source: 1",
    configure = function(options, take, source)
      source.beat_based = true
    end,
  },
}

for _, case in ipairs(unsupported_cases) do
  add_test(case.name, function()
    local mock = make_mock()
    local track = make_track(mock)
    local source = make_source(5.0, 1, voice_pattern)
    local take = new_take(source)
    local options = {
      position = 10.0,
      length = 5.0,
      takes = { take },
    }

    case.configure(options, take, source)

    local item = add_item(mock, track, options)

    load_script(mock)

    check(near(item.position, 10.0), "position changed")
    check(near(item.length, options.length), "length changed")
    check(near(take.start_offset, 0.0), "start offset changed")
    check(mock.message and mock.message:find(case.label, 1, true) ~= nil,
      "summary missing [" .. case.label .. "]: " .. tostring(mock.message))
  end)
end

add_test("all takes play is skipped", function()
  local mock = make_mock()
  local track = make_track(mock)
  local source = make_source(5.0, 1, voice_pattern)
  local take_a = new_take(source)
  local take_b = new_take(source)
  local item = add_item(mock, track, {
    position = 10.0,
    length = 5.0,
    takes = { take_a, take_b },
    active_take = 1,
    all_takes_play = 1,
  })

  load_script(mock)

  check(near(item.position, 10.0), "position changed")
  check(near(item.length, 5.0), "length changed")
  check(mock.message and mock.message:find("all takes play: 1", 1, true) ~= nil,
    "summary missing all-takes-play")
end)

add_test("stereo source: any channel above threshold counts", function()
  local mock = make_mock()
  local track = make_track(mock)
  local source = make_source(2.0, 2, function(t, channel)
    if channel == 1 then
      return 0
    end
    if t >= 0.5 and t < 1.5 then
      return 0.2
    end
    return 0
  end)
  local take = new_take(source)
  local item = add_item(mock, track, {
    position = 0.0,
    length = 2.0,
    takes = { take },
  })

  load_script(mock)

  check(near(item.length, 1.13), "length: " .. tostring(item.length))
  check(near(item.position, 0.47), "position: " .. tostring(item.position))
end)


for _, test in ipairs(tests) do
  local ok, err = xpcall(test.fn, debug.traceback)
  if ok then
    passed = passed + 1
    print("PASS  " .. test.name)
  else
    failed = failed + 1
    failures[#failures + 1] = test.name .. "\n" .. tostring(err)
    print("FAIL  " .. test.name)
  end
end

print(string.format("\n%d passed, %d failed", passed, failed))

for _, failure in ipairs(failures) do
  print("\n=== " .. failure)
end

if failed > 0 then
  os.exit(1)
end





