-- @description Trim leading and trailing silence (voice-safe)
-- @author Jzpi
-- @version 1.0.0
-- @changelog Initial ReaPack release: source-level leading/trailing trim, short fade reset, live preview, fade-only fast path, boundary navigation, center view.
-- @link https://github.com/Jzpi/reaper-trim-silence

--[[
 * ReaScript Name: Trim leading and trailing silence (voice-safe)
 * Inspired by: X-Raym - "Trim selected items at first and last transient"
 * Original author: X-Raym
 * Original licence: GPL v3
 * Licence: GPL v3
 *
 * What this script does
 *   - Processes selected audio media items only.
 *   - Reads the active take through a take AudioAccessor. Accessor samples are
 *     pre-FX and pre-volume/pre-fade, so the threshold describes the source
 *     recording rather than the processed track output.
 *   - Finds the first and the last sample above the threshold and trims only
 *     the leading and the trailing part of the item.
 *   - Never cuts or deletes anything between the first and the last sound.
 *   - Keeps the retained audio at its original timeline positions: no
 *     snapping, no re-ordering, no ripple movement.
 *   - Writes a short fade only on an edge that was actually moved.
 *   - Opens a settings window first (ReaImGui, or a native dialog as
 *     fallback) so threshold, pads, fades and preview can be adjusted
 *     without editing the script. The window live-previews the result on
 *     the selected items; Cancel restores, Run commits as one undo step.
 *   - Uses a single undo block and does not change the selection, the edit
 *     cursor, ripple editing, grouping or snap settings.
 *
 * Requirements
 *   - REAPER 7.x ReaScript engine.
 *   - SWS extension is NOT required.
 *
 * Scope
 *   Supported: ordinary audio sources (WAV/AIFF/MP3/FLAC...), one or more
 *   audio takes on an item, take playrate exactly 1.0, no stretch markers,
 *   not a reversed source, item not locked. "Loop source" is fine as long
 *   as the item does not actually run past the source end.
 *   Unsupported items are skipped and counted; they are never modified.
--]]

-- ============================== USER SETTINGS ===============================

local CFG = {
  -- A sample counts as "sound" when its absolute value is above this level.
  -- This is intentionally low: it removes near-digital silence and leaves
  -- room tone/breath alone. Ordinary room tone is often -45..-65 dBFS, so
  -- with -80 noisy edges will stay untouched. That is by design; test a
  -- higher value (for example -60) on a copy if you want noise removal.
  threshold_db    = -80.0,

  -- Extra audio kept before the first sound and after the last sound.
  leading_pad_ms  = 30.0,
  trailing_pad_ms = 100.0,

  -- Fade lengths used on edges that were actually moved.
  fade_in_ms      = 2.0,
  fade_out_ms     = 5.0,

  -- "short"    : on a trimmed edge, replace the existing fade with a fresh
  --              fade_in_ms/fade_out_ms fade (default).
  -- "preserve" : on a trimmed edge, shorten the existing manual fade by the
  --              trim amount instead of replacing it.
  -- Untouched edges and fade shapes are never changed in either mode.
  fade_policy     = "short",

  -- Ignore per-edge trims shorter than this.
  min_trim_ms     = 1.0,

  -- Frames per channel per audio read block.
  block_frames    = 4096,

  -- Minimum time between live-preview refreshes while settings are being
  -- changed. 200-300 ms is a good tradeoff for large selections.
  preview_refresh_ms = 250.0,

  -- true = Run only reports; the window still live-previews, then restores
  -- the original item state when Run is pressed.
  preview_only    = false,

  -- Show a settings window before processing (ReaImGui, with a native
  -- dialog as fallback). Set to false to run immediately with the values
  -- stored above / last saved in the window.
  show_settings_window = true,

  -- Show a summary message box after the run.
  show_summary    = true,

  -- Print per-item details to the ReaScript console.
  console         = false,
}

-- ============================================================================

local DEFAULTS = {}

for key, value in pairs(CFG) do
  DEFAULTS[key] = value
end

local EXT_SECTION = "TrimLeadingTrailingSilence"
local SETTINGS_VERSION = "2"

local threshold_amp
local leading_pad
local trailing_pad
local min_trim
local block_frames

-- CFG can be changed by the settings window after the script has started,
-- so every derived value is recalculated from CFG right before processing.
local function RefreshDerivedSettings()
  threshold_amp = 10 ^ (CFG.threshold_db / 20)
  leading_pad = math.max(0, CFG.leading_pad_ms) / 1000
  trailing_pad = math.max(0, CFG.trailing_pad_ms) / 1000
  min_trim = math.max(0, CFG.min_trim_ms) / 1000
  block_frames = math.max(64, math.floor(CFG.block_frames))
end

RefreshDerivedSettings()

local EPS = 1e-9

local stats = {
  selected = 0,
  planned = 0,
  applied = 0,
  trimmed = 0,
  unchanged = 0,
  left_edges = 0,
  right_edges = 0,
  removed_seconds = 0,
  overlap_edges = 0,
  auto_fade_edges = 0,
  skipped = {},
  errors = 0,
}

local function log(text)
  if CFG.console then
    reaper.ShowConsoleMsg(tostring(text) .. "\n")
  end
end

local function count_skip(reason)
  stats.skipped[reason] = (stats.skipped[reason] or 0) + 1
end


-- Returns item/take/audio information, or nil plus a skip reason.
local function CollectItemInfo(item)
  local take = reaper.GetActiveTake(item)

  if not take then
    return nil, "no_active_take"
  end

  if reaper.TakeIsMIDI(take) then
    return nil, "midi_take"
  end

  local item_lock = math.floor(
    reaper.GetMediaItemInfo_Value(item, "C_LOCK") + 0.5
  )

  if (item_lock & 1) ~= 0 then
    return nil, "locked_item"
  end

  local track = reaper.GetMediaItemTake_Track(take)

  local position = reaper.GetMediaItemInfo_Value(item, "D_POSITION")
  local length   = reaper.GetMediaItemInfo_Value(item, "D_LENGTH")

  if length <= 0 then
    return nil, "zero_length"
  end

  local loop_source =
    reaper.GetMediaItemInfo_Value(item, "B_LOOPSRC") > 0.5

  local take_count = reaper.CountTakes(item)

  if take_count < 1 then
    return nil, "no_active_take"
  end

  if take_count > 1
    and reaper.GetMediaItemInfo_Value(item, "B_ALLTAKESPLAY") > 0.5 then
    return nil, "all_takes_play"
  end

  local takes = {}

  for index = 0, take_count - 1 do
    local other_take = reaper.GetMediaItemTake(item, index)

    if not other_take then
      return nil, "missing_take"
    end

    if reaper.TakeIsMIDI(other_take) then
      return nil, "midi_take"
    end

    local rate = reaper.GetMediaItemTakeInfo_Value(
      other_take, "D_PLAYRATE"
    )

    if math.abs(rate - 1.0) > 1e-6 then
      return nil, "playrate_not_1"
    end

    if reaper.GetTakeNumStretchMarkers(other_take) > 0 then
      return nil, "stretch_markers"
    end

    local source = reaper.GetMediaItemTake_Source(other_take)

    if not source then
      return nil, "no_source"
    end

    local is_section, section_offs, section_len, is_reversed =
      reaper.PCM_Source_GetSectionInfo(source)

    if is_reversed then
      return nil, "reversed_source"
    end

    local source_length, length_is_qn = reaper.GetMediaSourceLength(source)

    if length_is_qn then
      return nil, "beat_based_source"
    end

    -- Loop source only matters when the item actually runs past the source
    -- end. A non-repeating loop flag is harmless and can be processed.
    -- If the source length is not known yet (0), do not skip the item:
    -- an unknown length must not be treated as a real loop repetition.
    if loop_source and source_length > 0.0005 then
      local start_offset = reaper.GetMediaItemTakeInfo_Value(
        other_take, "D_STARTOFFS"
      )

      if start_offset + length > source_length + 0.0005 then
        return nil, "loop_repeats"
      end
    end

    takes[#takes + 1] = other_take
  end

  local source = reaper.GetMediaItemTake_Source(take)
  local channels = reaper.GetMediaSourceNumChannels(source)

  if channels < 1 then
    return nil, "no_channels"
  end

  local sample_rate = reaper.GetMediaSourceSampleRate(source)

  if not sample_rate or sample_rate <= 0 then
    return nil, "no_sample_rate"
  end

  sample_rate = math.floor(sample_rate + 0.5)

  return {
    item = item,
    take = take,
    takes = takes,
    track = track,
    position = position,
    length = length,
    sample_rate = sample_rate,
    channels = channels,
  }
end


-- Reads the take from both ends. Returns the first and the last audible
-- frame index (item-relative, 0 = item left edge), or nil if the whole
-- item is below the threshold.
local function ScanAudio(accessor, sample_rate, channels, item_length)
  local total_frames = math.max(
    1, math.floor(item_length * sample_rate + 0.5)
  )

  local buffer = reaper.new_array(block_frames * channels)

  local first_frame = nil
  local frame_pos = 0

  while frame_pos < total_frames do
    local frames = math.min(block_frames, total_frames - frame_pos)

    buffer.clear()

    local retval = reaper.GetAudioAccessorSamples(
      accessor,
      sample_rate,
      channels,
      frame_pos / sample_rate,
      frames,
      buffer
    )

    if retval < 0 then
      error("GetAudioAccessorSamples failed during the leading scan")
    end

    if retval > 0 then
      for frame = 0, frames - 1 do
        local base = frame * channels
        local audible = false

        for channel = 1, channels do
          if math.abs(buffer[base + channel]) > threshold_amp then
            audible = true
            break
          end
        end

        if audible then
          first_frame = frame_pos + frame
          break
        end
      end
    end

    if first_frame then
      break
    end

    frame_pos = frame_pos + frames
  end

  if not first_frame then
    return nil, nil
  end

  local last_frame = nil
  local end_frame = total_frames

  while end_frame > 0 do
    local frames = math.min(block_frames, end_frame)
    local start_frame = end_frame - frames

    buffer.clear()

    local retval = reaper.GetAudioAccessorSamples(
      accessor,
      sample_rate,
      channels,
      start_frame / sample_rate,
      frames,
      buffer
    )

    if retval < 0 then
      error("GetAudioAccessorSamples failed during the trailing scan")
    end

    if retval > 0 then
      for frame = frames - 1, 0, -1 do
        local base = frame * channels
        local audible = false

        for channel = 1, channels do
          if math.abs(buffer[base + channel]) > threshold_amp then
            audible = true
            break
          end
        end

        if audible then
          last_frame = start_frame + frame
          break
        end
      end
    end

    if last_frame then
      break
    end

    end_frame = start_frame
  end

  return first_frame, last_frame
end


-- True when another item on the same track intersects the given project-time
-- range. Used to avoid silently changing an existing overlap/crossfade.
local function HasOtherItemInRange(track, item, range_start, range_end)
  local count = reaper.CountTrackMediaItems(track)

  for index = 0, count - 1 do
    local other = reaper.GetTrackMediaItem(track, index)

    if other and other ~= item then
      local other_pos = reaper.GetMediaItemInfo_Value(
        other, "D_POSITION"
      )
      local other_end = other_pos + reaper.GetMediaItemInfo_Value(
        other, "D_LENGTH"
      )

      if other_pos < range_end - EPS and other_end > range_start + EPS then
        return true
      end
    end
  end

  return false
end


local TakeEnvelopeHasPointBefore

-- Builds a trim plan from the detected sample positions.
local function BuildPlan(info, first_frame, last_frame)
  local sample_rate = info.sample_rate
  local length = info.length

  local first_time = first_frame / sample_rate
  local last_end_time = math.min(
    length, (last_frame + 1) / sample_rate
  )

  local new_start = math.min(
    length, math.max(0, first_time - leading_pad)
  )
  local new_end = math.min(length, last_end_time + trailing_pad)

  if new_end <= new_start then
    return nil, "too_short"
  end

  local trim_left  = new_start
  local trim_right = length - new_end

  if trim_left < min_trim then
    trim_left = 0
  end

  if trim_right < min_trim then
    trim_right = 0
  end

  if trim_left == 0 and trim_right == 0 then
    return nil, "unchanged"
  end

  -- Do not change an edge that currently participates in an automatic
  -- crossfade, or an overlap with another item on the same track.
  if trim_left > 0 then
    local auto_fade_in = reaper.GetMediaItemInfo_Value(
      info.item, "D_FADEINLEN_AUTO"
    )

    if auto_fade_in > 0 then
      trim_left = 0
      stats.auto_fade_edges = stats.auto_fade_edges + 1
    elseif info.track and HasOtherItemInRange(
      info.track,
      info.item,
      info.position,
      info.position + trim_left
    ) then
      trim_left = 0
      stats.overlap_edges = stats.overlap_edges + 1
    end
  end

  if trim_right > 0 then
    local auto_fade_out = reaper.GetMediaItemInfo_Value(
      info.item, "D_FADEOUTLEN_AUTO"
    )

    if auto_fade_out > 0 then
      trim_right = 0
      stats.auto_fade_edges = stats.auto_fade_edges + 1
    elseif info.track and HasOtherItemInRange(
      info.track,
      info.item,
      info.position + length - trim_right,
      info.position + length
    ) then
      trim_right = 0
      stats.overlap_edges = stats.overlap_edges + 1
    end
  end

  if trim_left == 0 and trim_right == 0 then
    return nil, "unchanged"
  end

  -- Do not cut through a take envelope point: shifting it would move it
  -- outside the item and could change the automation curve.
  if trim_left > 0 then
    for _, take in ipairs(info.takes) do
      if TakeEnvelopeHasPointBefore(take, trim_left) then
        return nil, "take_envelope_in_trim"
      end
    end
  end

  local new_length = length - trim_left - trim_right

  if new_length <= 0.0005 then
    return nil, "too_short"
  end

  return {
    item = info.item,
    takes = info.takes,
    position = info.position,
    length = length,
    new_length = new_length,
    trim_left = trim_left,
    trim_right = trim_right,
    first_sound_time = first_time,
    last_sound_end_time = last_end_time,
  }
end


-- True when a take envelope has a point inside the part that would be cut.
-- Such a point cannot be moved outside the item without changing automation,
-- so the item is skipped instead.
TakeEnvelopeHasPointBefore = function(take, time_limit)
  local envelope_count = reaper.CountTakeEnvelopes(take)

  for envelope_index = 0, envelope_count - 1 do
    local envelope = reaper.GetTakeEnvelope(take, envelope_index)

    if envelope then
      local point_count = reaper.CountEnvelopePoints(envelope)

      for point_index = 0, point_count - 1 do
        local retval, time = reaper.GetEnvelopePoint(
          envelope, point_index
        )

        if retval and time < time_limit - EPS then
          return true
        end
      end
    end
  end

  return false
end


-- Shifts take envelope points so they stay over the same audio after a
-- left-edge trim. Take envelope point positions are counted from the take
-- position (item-relative time), so the shift is the item-time trim.
local function ShiftTakeEnvelopes(take, offset)
  local envelope_count = reaper.CountTakeEnvelopes(take)

  for envelope_index = 0, envelope_count - 1 do
    local envelope = reaper.GetTakeEnvelope(take, envelope_index)

    if envelope then
      local point_count = reaper.CountEnvelopePoints(envelope)
      local changed = false

      for point_index = 0, point_count - 1 do
        local retval, time, value, shape, tension, selected =
          reaper.GetEnvelopePoint(envelope, point_index)

        if retval then
          reaper.SetEnvelopePoint(
            envelope,
            point_index,
            time + offset,
            value,
            shape,
            tension,
            selected,
            true
          )
          changed = true
        end
      end

      if changed then
        reaper.Envelope_SortPoints(envelope)
      end
    end
  end
end


-- Computes the fade lengths after a trim. Only trimmed edges are written,
-- except when an untouched fade would otherwise exceed the new item length.
local function ComputeFadeLengths(plan)
  local item = plan.item
  local length = plan.new_length

  local old_in = reaper.GetMediaItemInfo_Value(item, "D_FADEINLEN")
  local old_out = reaper.GetMediaItemInfo_Value(item, "D_FADEOUTLEN")

  local fade_in = old_in
  local fade_out = old_out

  if plan.trim_left > 0 then
    local desired = math.max(0, CFG.fade_in_ms) / 1000

    if CFG.fade_policy == "preserve" and old_in > 0.0005 then
      desired = math.max(0, old_in - plan.trim_left)
    end

    if desired > 0.0005 then
      fade_in = desired
    else
      fade_in = math.max(0, CFG.fade_in_ms) / 1000
    end
  end

  if plan.trim_right > 0 then
    local desired = math.max(0, CFG.fade_out_ms) / 1000

    if CFG.fade_policy == "preserve" and old_out > 0.0005 then
      desired = math.max(0, old_out - plan.trim_right)
    end

    if desired > 0.0005 then
      fade_out = desired
    else
      fade_out = math.max(0, CFG.fade_out_ms) / 1000
    end
  end

  fade_in = math.min(fade_in, length)
  fade_out = math.min(fade_out, length)

  if fade_in + fade_out > length then
    if plan.trim_left > 0 and plan.trim_right > 0 then
      -- Both edges were shortened: keep the two short fades proportional.
      local total = fade_in + fade_out

      if total > 0 then
        local scale = length / total
        fade_in = fade_in * scale
        fade_out = fade_out * scale
      end
    elseif plan.trim_left > 0 then
      -- The left fade is the new de-click fade; clamp the untouched right
      -- fade so that it cannot overlap it.
      fade_in = math.min(fade_in, length)
      fade_out = math.min(fade_out, math.max(0, length - fade_in))
    elseif plan.trim_right > 0 then
      fade_out = math.min(fade_out, length)
      fade_in = math.min(fade_in, math.max(0, length - fade_out))
    end
  end

  return fade_in, fade_out, old_in, old_out
end


local function ApplyPlan(plan)
  local item = plan.item
  local new_position = plan.position + plan.trim_left

  local fade_in, fade_out, old_in, old_out = ComputeFadeLengths(plan)
  local old_snap = reaper.GetMediaItemInfo_Value(item, "D_SNAPOFFSET")

  -- Keep the snap point over the same audio when possible and keep it
  -- inside the new item bounds.
  local new_snap = old_snap - plan.trim_left

  if new_snap < 0 then
    new_snap = 0
  elseif new_snap > plan.new_length then
    new_snap = plan.new_length
  end

  -- Match REAPER's own trim order: length, position, take offsets.
  reaper.SetMediaItemInfo_Value(item, "D_LENGTH", plan.new_length)

  if plan.trim_left > 0 then
    reaper.SetMediaItemInfo_Value(item, "D_POSITION", new_position)

    for _, take in ipairs(plan.takes) do
      local rate = reaper.GetMediaItemTakeInfo_Value(
        take, "D_PLAYRATE"
      )
      local start_offset = reaper.GetMediaItemTakeInfo_Value(
        take, "D_STARTOFFS"
      )

      reaper.SetMediaItemTakeInfo_Value(
        take,
        "D_STARTOFFS",
        start_offset + plan.trim_left * rate
      )

      ShiftTakeEnvelopes(take, -plan.trim_left)
    end
  end

  if math.abs(new_snap - old_snap) > EPS then
    reaper.SetMediaItemInfo_Value(item, "D_SNAPOFFSET", new_snap)
  end

  if plan.trim_left > 0 then
    reaper.SetMediaItemInfo_Value(item, "D_FADEINLEN", fade_in)
  elseif fade_in < old_in - EPS then
    reaper.SetMediaItemInfo_Value(item, "D_FADEINLEN", fade_in)
  end

  if plan.trim_right > 0 then
    reaper.SetMediaItemInfo_Value(item, "D_FADEOUTLEN", fade_out)
  elseif fade_out < old_out - EPS then
    reaper.SetMediaItemInfo_Value(item, "D_FADEOUTLEN", fade_out)
  end

  -- A fresh short fade is written as a linear fade from zero. This also
  -- resets any old fade shape/curvature on a trimmed edge.
  if CFG.fade_policy == "short" then
    if plan.trim_left > 0 then
      reaper.SetMediaItemInfo_Value(item, "C_FADEINSHAPE", 0)
      reaper.SetMediaItemInfo_Value(item, "D_FADEINDIR", 0)
    end

    if plan.trim_right > 0 then
      reaper.SetMediaItemInfo_Value(item, "C_FADEOUTSHAPE", 0)
      reaper.SetMediaItemInfo_Value(item, "D_FADEOUTDIR", 0)
    end
  end

  reaper.UpdateItemInProject(item)
end


local function ProcessItem(item)
  local info, reason = CollectItemInfo(item)

  if not info then
    return nil, reason
  end

  local accessor = reaper.CreateTakeAudioAccessor(info.take)

  if not accessor then
    return nil, "accessor_failed"
  end

  -- The take accessor uses item-relative time. Its end can be earlier than
  -- the item end (for example when the source is shorter than the item);
  -- do not read past that point.
  local scan_length = info.length
  local accessor_end = reaper.GetAudioAccessorEndTime(accessor)

  if accessor_end and accessor_end > 0.000001
    and accessor_end < scan_length then
    scan_length = accessor_end
  end

  local ok, first_frame, last_frame = pcall(
    ScanAudio,
    accessor,
    info.sample_rate,
    info.channels,
    scan_length
  )

  reaper.DestroyAudioAccessor(accessor)

  if not ok then
    error(first_frame)
  end

  if not first_frame or not last_frame then
    return nil, "silent"
  end

  return BuildPlan(info, first_frame, last_frame)
end


local SKIP_LABELS = {
  no_active_take = "no active take",
  midi_take = "MIDI take",
  locked_item = "locked item",
  zero_length = "zero length",
  loop_repeats = "loop source repeats (turn Loop source off)",
  all_takes_play = "all takes play",
  missing_take = "missing take",
  playrate_not_1 = "take playrate not 1.0",
  stretch_markers = "stretch markers",
  no_source = "no source",
  reversed_source = "reversed source",
  no_channels = "no audio channels",
  beat_based_source = "beat-based source",
  no_sample_rate = "no source sample rate",
  silent = "fully silent",
  too_short = "too short after trim",
  take_envelope_in_trim = "take envelope point in trimmed lead",
  accessor_failed = "audio accessor failed",
}


local function BuildSummary()
  local lines = {}

  if CFG.preview_only then
    lines[#lines + 1] = "PREVIEW ONLY - nothing was changed."
  end

  if CFG.preview_only then
    lines[#lines + 1] = string.format(
      "Selected: %d    Would trim: %d    Unchanged: %d",
      stats.selected, stats.trimmed, stats.unchanged
    )
  else
    lines[#lines + 1] = string.format(
      "Selected: %d    Trimmed: %d    Unchanged: %d",
      stats.selected, stats.trimmed, stats.unchanged
    )
  end

  lines[#lines + 1] = string.format(
    "Threshold: %.1f dBFS    Pads: %.0f/%.0f ms    Fades: %.1f/%.1f ms (%s)",
    CFG.threshold_db,
    CFG.leading_pad_ms,
    CFG.trailing_pad_ms,
    CFG.fade_in_ms,
    CFG.fade_out_ms,
    CFG.fade_policy
  )

  lines[#lines + 1] = string.format(
    "Edges moved: left %d, right %d    Audio removed: %.1f ms",
    stats.left_edges, stats.right_edges, stats.removed_seconds * 1000
  )

  if not CFG.preview_only and stats.planned > stats.applied then
    lines[#lines + 1] = string.format(
      "Applied %d of %d planned trims before stopping.",
      stats.applied, stats.planned
    )
  end

  if stats.trimmed == 0 and stats.unchanged > 0 then
    lines[#lines + 1] = string.format(
      "Nothing was trimmed. With a %.1f dBFS threshold, any room tone "
        .. "above that level counts as sound; test a less negative value "
        .. "(for example -60) on a copy.",
      CFG.threshold_db
    )
  end

  if stats.overlap_edges > 0 then
    lines[#lines + 1] = string.format(
      "Edges kept because of an overlap/crossfade: %d",
      stats.overlap_edges
    )
  end

  if stats.auto_fade_edges > 0 then
    lines[#lines + 1] = string.format(
      "Edges kept because of an automatic crossfade: %d",
      stats.auto_fade_edges
    )
  end

  local skip_lines = {}

  for reason, count in pairs(stats.skipped) do
    local label = SKIP_LABELS[reason] or reason
    skip_lines[#skip_lines + 1] = string.format("%s: %d", label, count)
  end

  table.sort(skip_lines)

  if #skip_lines > 0 then
    lines[#lines + 1] = "Skipped items:"
    for _, line in ipairs(skip_lines) do
      lines[#lines + 1] = "  " .. line
    end
  end

  if stats.errors > 0 then
    lines[#lines + 1] = string.format("Errors: %d", stats.errors)
  end

  return table.concat(lines, "\n")
end


local function CheckRequiredAPIs()
  local required_apis = {
    "CreateTakeAudioAccessor",
    "DestroyAudioAccessor",
    "GetAudioAccessorEndTime",
    "GetAudioAccessorSamples",
    "GetMediaItemTake_Source",
    "GetMediaSourceLength",
    "GetMediaSourceNumChannels",
    "GetMediaSourceSampleRate",
    "PCM_Source_GetSectionInfo",
    "CountTakeEnvelopes",
    "GetTakeEnvelope",
    "CountEnvelopePoints",
    "GetEnvelopePoint",
    "SetEnvelopePoint",
    "Envelope_SortPoints",
  }

  local missing = {}

  for _, name in ipairs(required_apis) do
    if not reaper.APIExists(name) then
      missing[#missing + 1] = name
    end
  end

  return missing
end


local function GetSelectedItems()
  local items = {}
  local count = reaper.CountSelectedMediaItems(0)

  for index = 0, count - 1 do
    local item = reaper.GetSelectedMediaItem(0, index)

    if item then
      items[#items + 1] = item
    end
  end

  return items
end


local function ResetScanStats(selected_count)
  stats.selected = selected_count
  stats.planned = 0
  stats.applied = 0
  stats.trimmed = 0
  stats.unchanged = 0
  stats.left_edges = 0
  stats.right_edges = 0
  stats.removed_seconds = 0
  stats.overlap_edges = 0
  stats.auto_fade_edges = 0
  stats.skipped = {}
  stats.errors = 0
end


local function ScanItems(items)
  RefreshDerivedSettings()
  ResetScanStats(#items)

  local plans = {}

  for index, item in ipairs(items) do
    local ok, plan, reason = pcall(ProcessItem, item)

    if not ok then
      stats.errors = stats.errors + 1
      log(string.format("item %d: error: %s", index, tostring(plan)))
    elseif plan then
      plans[#plans + 1] = plan

      log(string.format(
        "item %d: plan trim left %.2f ms (first sound %.2f ms), "
          .. "right %.2f ms (last sound ends %.2f ms)",
        index,
        plan.trim_left * 1000,
        plan.first_sound_time * 1000,
        plan.trim_right * 1000,
        plan.last_sound_end_time * 1000
      ))
    elseif reason == "unchanged" then
      stats.unchanged = stats.unchanged + 1
      log(string.format("item %d: unchanged", index))
    else
      reason = reason or "unknown"
      count_skip(reason)
      log(string.format("item %d: skipped (%s)", index, tostring(reason)))
    end
  end

  stats.planned = #plans
  return plans
end


local function GetPlanTotals(plans)
  local left = 0
  local right = 0
  local removed = 0

  for _, plan in ipairs(plans) do
    left = left + (plan.trim_left > 0 and 1 or 0)
    right = right + (plan.trim_right > 0 and 1 or 0)
    removed = removed + plan.trim_left + plan.trim_right
  end

  return left, right, removed
end


local function FillPlannedStats(plans)
  stats.trimmed = #plans
  stats.left_edges, stats.right_edges, stats.removed_seconds =
    GetPlanTotals(plans)
end


local function ApplyPlansWithUndo(plans)
  if #plans == 0 then
    return true
  end

  local undo_open = false
  local ui_hidden = false

  local ok, err = xpcall(function()
    reaper.Undo_BeginBlock2(0)
    undo_open = true

    reaper.PreventUIRefresh(1)
    ui_hidden = true

    for _, plan in ipairs(plans) do
      ApplyPlan(plan)

      stats.applied = stats.applied + 1
      stats.trimmed = stats.trimmed + 1
      stats.removed_seconds = stats.removed_seconds
        + plan.trim_left + plan.trim_right
      stats.left_edges = stats.left_edges
        + (plan.trim_left > 0 and 1 or 0)
      stats.right_edges = stats.right_edges
        + (plan.trim_right > 0 and 1 or 0)
    end

    reaper.PreventUIRefresh(-1)
    ui_hidden = false

    reaper.UpdateArrange()

    reaper.Undo_EndBlock2(
      0,
      "Trim leading/trailing silence (voice-safe)",
      -1
    )
    undo_open = false
  end, debug.traceback)

  -- Make sure UI refresh and the undo block are always closed.
  if ui_hidden then
    reaper.PreventUIRefresh(-1)
    ui_hidden = false
  end

  if undo_open then
    pcall(function()
      reaper.Undo_EndBlock2(
        0,
        "Trim leading/trailing silence (voice-safe)",
        -1
      )
    end)
    undo_open = false
  end

  reaper.UpdateArrange()
  return ok, err
end


-- Applies a preview without creating undo points. The caller restores the
-- captured original state before committing or cancelling.
local function ApplyPlansPreview(plans)
  if #plans == 0 then
    return true
  end

  local ui_hidden = false

  local ok, err = xpcall(function()
    reaper.PreventUIRefresh(1)
    ui_hidden = true

    for _, plan in ipairs(plans) do
      ApplyPlan(plan)
    end

    reaper.PreventUIRefresh(-1)
    ui_hidden = false

    reaper.UpdateArrange()
  end, debug.traceback)

  if ui_hidden then
    reaper.PreventUIRefresh(-1)
    ui_hidden = false
  end

  reaper.UpdateArrange()
  return ok, err
end


local function CaptureItemState(item)
  local state = {
    item = item,
    position = reaper.GetMediaItemInfo_Value(item, "D_POSITION"),
    length = reaper.GetMediaItemInfo_Value(item, "D_LENGTH"),
    snap_offset = reaper.GetMediaItemInfo_Value(item, "D_SNAPOFFSET"),
    fade_in = reaper.GetMediaItemInfo_Value(item, "D_FADEINLEN"),
    fade_out = reaper.GetMediaItemInfo_Value(item, "D_FADEOUTLEN"),
    fade_in_auto = reaper.GetMediaItemInfo_Value(
      item, "D_FADEINLEN_AUTO"
    ),
    fade_out_auto = reaper.GetMediaItemInfo_Value(
      item, "D_FADEOUTLEN_AUTO"
    ),
    fade_in_shape = reaper.GetMediaItemInfo_Value(
      item, "C_FADEINSHAPE"
    ),
    fade_out_shape = reaper.GetMediaItemInfo_Value(
      item, "C_FADEOUTSHAPE"
    ),
    fade_in_dir = reaper.GetMediaItemInfo_Value(item, "D_FADEINDIR"),
    fade_out_dir = reaper.GetMediaItemInfo_Value(item, "D_FADEOUTDIR"),
    takes = {},
  }

  for take_index = 0, reaper.CountTakes(item) - 1 do
    local take = reaper.GetMediaItemTake(item, take_index)

    if take then
      local take_state = {
        take = take,
        start_offset = reaper.GetMediaItemTakeInfo_Value(
          take, "D_STARTOFFS"
        ),
        envelopes = {},
      }

      for envelope_index = 0, reaper.CountTakeEnvelopes(take) - 1 do
        local envelope = reaper.GetTakeEnvelope(take, envelope_index)

        if envelope then
          local times = {}

          for point_index = 0, reaper.CountEnvelopePoints(envelope) - 1 do
            local retval, time, value, shape, tension, selected =
              reaper.GetEnvelopePoint(envelope, point_index)

            if retval then
              times[#times + 1] = {
                time = time,
                value = value,
                shape = shape,
                tension = tension,
                selected = selected,
              }
            end
          end

          take_state.envelopes[#take_state.envelopes + 1] = {
            envelope = envelope,
            times = times,
          }
        end
      end

      state.takes[#state.takes + 1] = take_state
    end
  end

  return state
end


local function RestoreItemState(state)
  local item = state.item

  reaper.SetMediaItemInfo_Value(item, "D_LENGTH", state.length)
  reaper.SetMediaItemInfo_Value(item, "D_POSITION", state.position)

  for _, take_state in ipairs(state.takes) do
    reaper.SetMediaItemTakeInfo_Value(
      take_state.take,
      "D_STARTOFFS",
      take_state.start_offset
    )

    for _, envelope_state in ipairs(take_state.envelopes) do
      local envelope = envelope_state.envelope
      local times = envelope_state.times

      for point_index = 1, #times do
        local point = times[point_index]

        reaper.SetEnvelopePoint(
          envelope,
          point_index - 1,
          point.time,
          point.value,
          point.shape,
          point.tension,
          point.selected,
          true
        )
      end

      reaper.Envelope_SortPoints(envelope)
    end
  end

  reaper.SetMediaItemInfo_Value(
    item, "D_SNAPOFFSET", state.snap_offset
  )
  reaper.SetMediaItemInfo_Value(item, "D_FADEINLEN", state.fade_in)
  reaper.SetMediaItemInfo_Value(item, "D_FADEOUTLEN", state.fade_out)
  reaper.SetMediaItemInfo_Value(
    item, "D_FADEINLEN_AUTO", state.fade_in_auto
  )
  reaper.SetMediaItemInfo_Value(
    item, "D_FADEOUTLEN_AUTO", state.fade_out_auto
  )
  reaper.SetMediaItemInfo_Value(
    item, "C_FADEINSHAPE", state.fade_in_shape
  )
  reaper.SetMediaItemInfo_Value(
    item, "C_FADEOUTSHAPE", state.fade_out_shape
  )
  reaper.SetMediaItemInfo_Value(
    item, "D_FADEINDIR", state.fade_in_dir
  )
  reaper.SetMediaItemInfo_Value(
    item, "D_FADEOUTDIR", state.fade_out_dir
  )

  reaper.UpdateItemInProject(item)
end


local function RestoreOriginalStates(states)
  reaper.PreventUIRefresh(1)

  for _, state in ipairs(states) do
    RestoreItemState(state)
  end

  reaper.PreventUIRefresh(-1)
  reaper.UpdateArrange()
end


local function Init()
  RefreshDerivedSettings()

  local missing = CheckRequiredAPIs()

  if #missing > 0 then
    reaper.ShowMessageBox(
      "This script needs a newer REAPER version.\nMissing API:\n"
        .. table.concat(missing, "\n"),
      "Trim leading/trailing silence",
      0
    )
    return
  end

  local items = GetSelectedItems()

  if #items == 0 then
    reaper.ShowMessageBox(
      "Select one or more audio media items first.",
      "Trim leading/trailing silence",
      0
    )
    return
  end

  local plans = ScanItems(items)
  local apply_error = nil

  if CFG.preview_only then
    FillPlannedStats(plans)
  else
    local ok, err = ApplyPlansWithUndo(plans)

    if not ok then
      apply_error = err
      stats.errors = stats.errors + 1
    end
  end

  if CFG.show_summary then
    local title = CFG.preview_only
      and "Trim leading/trailing silence (preview)"
      or "Trim leading/trailing silence"

    reaper.ShowMessageBox(BuildSummary(), title, 0)
  end

  if apply_error then
    reaper.ShowMessageBox(
      "Processing stopped while applying changes.\n"
        .. "Finished changes can be reverted with Undo.\n\n"
        .. tostring(apply_error),
      "Trim leading/trailing silence: error",
      0
    )
  end
end


-- ============================ SETTINGS STORAGE =============================

local function ClampNumber(value, default, min_value, max_value)
  local number = tonumber(value)

  if not number then
    number = default
  end

  if number < min_value then
    number = min_value
  elseif number > max_value then
    number = max_value
  end

  return number
end


local function LoadSettings()
  CFG.threshold_db = ClampNumber(
    reaper.GetExtState(EXT_SECTION, "threshold_db"),
    DEFAULTS.threshold_db, -144, 0
  )
  CFG.leading_pad_ms = ClampNumber(
    reaper.GetExtState(EXT_SECTION, "leading_pad_ms"),
    DEFAULTS.leading_pad_ms, 0, 5000
  )
  CFG.trailing_pad_ms = ClampNumber(
    reaper.GetExtState(EXT_SECTION, "trailing_pad_ms"),
    DEFAULTS.trailing_pad_ms, 0, 5000
  )
  CFG.fade_in_ms = ClampNumber(
    reaper.GetExtState(EXT_SECTION, "fade_in_ms"),
    DEFAULTS.fade_in_ms, 0, 1000
  )
  CFG.fade_out_ms = ClampNumber(
    reaper.GetExtState(EXT_SECTION, "fade_out_ms"),
    DEFAULTS.fade_out_ms, 0, 1000
  )
  CFG.min_trim_ms = ClampNumber(
    reaper.GetExtState(EXT_SECTION, "min_trim_ms"),
    DEFAULTS.min_trim_ms, 0, 1000
  )
  CFG.preview_refresh_ms = ClampNumber(
    reaper.GetExtState(EXT_SECTION, "preview_refresh_ms"),
    DEFAULTS.preview_refresh_ms, 50, 2000
  )

  -- Settings written by older versions stored "preserve" by default. The
  -- new default is "short" (reset fades on trimmed edges), so old stored
  -- fade policies are intentionally ignored until the window is saved once
  -- with the current settings version.
  local settings_version = reaper.GetExtState(
    EXT_SECTION, "settings_version"
  )
  local policy = reaper.GetExtState(EXT_SECTION, "fade_policy")

  if settings_version == SETTINGS_VERSION
    and (policy == "preserve" or policy == "short") then
    CFG.fade_policy = policy
  end

  local summary = reaper.GetExtState(EXT_SECTION, "show_summary")

  if summary ~= "" then
    CFG.show_summary = (summary == "1")
  end
end


local function SaveSettings()
  reaper.SetExtState(EXT_SECTION, "settings_version", SETTINGS_VERSION, true)
  reaper.SetExtState(EXT_SECTION, "threshold_db",
    string.format("%.4f", CFG.threshold_db), true)
  reaper.SetExtState(EXT_SECTION, "leading_pad_ms",
    string.format("%.4f", CFG.leading_pad_ms), true)
  reaper.SetExtState(EXT_SECTION, "trailing_pad_ms",
    string.format("%.4f", CFG.trailing_pad_ms), true)
  reaper.SetExtState(EXT_SECTION, "fade_in_ms",
    string.format("%.4f", CFG.fade_in_ms), true)
  reaper.SetExtState(EXT_SECTION, "fade_out_ms",
    string.format("%.4f", CFG.fade_out_ms), true)
  reaper.SetExtState(EXT_SECTION, "min_trim_ms",
    string.format("%.4f", CFG.min_trim_ms), true)
  reaper.SetExtState(EXT_SECTION, "preview_refresh_ms",
    string.format("%.4f", CFG.preview_refresh_ms), true)
  reaper.SetExtState(EXT_SECTION, "fade_policy", CFG.fade_policy, true)
  reaper.SetExtState(EXT_SECTION, "show_summary",
    CFG.show_summary and "1" or "0", true)
end


-- ========================== NATIVE DIALOG FALLBACK =========================

local function ShowNativeSettings()
  local captions =
    "Threshold dBFS,Lead pad ms,Trail pad ms,Fade in ms,Fade out ms,"
    .. "Min trim ms,Fade policy preserve/short,Preview only 0/1,"
    .. "Show summary 0/1"
  local defaults = string.format(
    "%.1f,%.1f,%.1f,%.1f,%.1f,%.1f,%s,%d,%d",
    CFG.threshold_db,
    CFG.leading_pad_ms,
    CFG.trailing_pad_ms,
    CFG.fade_in_ms,
    CFG.fade_out_ms,
    CFG.min_trim_ms,
    CFG.fade_policy,
    CFG.preview_only and 1 or 0,
    CFG.show_summary and 1 or 0
  )

  local retval, values = reaper.GetUserInputs(
    "Trim leading/trailing silence", 9, captions, defaults
  )

  if not retval then
    return
  end

  local fields = {}

  for value in string.gmatch(values .. ",", "([^,]*),") do
    fields[#fields + 1] = value
  end

  if #fields < 9 then
    reaper.ShowMessageBox(
      "Could not read the settings. Nothing was changed.",
      "Trim leading/trailing silence", 0
    )
    return
  end

  CFG.threshold_db = ClampNumber(
    fields[1], CFG.threshold_db, -144, 0
  )
  CFG.leading_pad_ms = ClampNumber(
    fields[2], CFG.leading_pad_ms, 0, 5000
  )
  CFG.trailing_pad_ms = ClampNumber(
    fields[3], CFG.trailing_pad_ms, 0, 5000
  )
  CFG.fade_in_ms = ClampNumber(
    fields[4], CFG.fade_in_ms, 0, 1000
  )
  CFG.fade_out_ms = ClampNumber(
    fields[5], CFG.fade_out_ms, 0, 1000
  )
  CFG.min_trim_ms = ClampNumber(
    fields[6], CFG.min_trim_ms, 0, 1000
  )
  CFG.fade_policy = (fields[7] == "short") and "short" or "preserve"
  CFG.preview_only = (fields[8] == "1")
  CFG.show_summary = (fields[9] ~= "0")

  SaveSettings()
  Init()
end


-- ============================ IMGUI SETTINGS ===============================

local function ImGuiConstant(name, fallback)
  local value = reaper[name]

  if type(value) == "function" then
    return value()
  elseif value ~= nil then
    return value
  end

  return fallback
end


local function ImGuiAvailable()
  local names = {
    "ImGui_CreateContext",
    "ImGui_Begin",
    "ImGui_End",
    "ImGui_SetNextWindowSize",
    "ImGui_SliderDouble",
    "ImGui_InputDouble",
    "ImGui_Checkbox",
    "ImGui_Button",
    "ImGui_SameLine",
    "ImGui_Text",
    "ImGui_TextWrapped",
    "ImGui_Separator",
    "ImGui_Spacing",
    "ImGui_SetNextItemWidth",
    "ImGui_IsItemHovered",
    "ImGui_IsMouseClicked",
    "ImGui_OpenPopup",
    "ImGui_BeginPopup",
    "ImGui_EndPopup",
    "ImGui_CloseCurrentPopup",
    "ImGui_IsKeyPressed",
    "ImGui_SetKeyboardFocusHere",
  }

  for _, name in ipairs(names) do
    if not reaper.APIExists(name) then
      return false
    end
  end

  return true
end


local function ShowImGuiSettings(items)
  local ctx = reaper.ImGui_CreateContext("Trim leading/trailing silence")

  if not ctx then
    ShowNativeSettings()
    return
  end

  -- Timeline order makes the boundary navigation predictable.
  table.sort(items, function(a, b)
    local pa = reaper.GetMediaItemInfo_Value(a, "D_POSITION")
    local pb = reaper.GetMediaItemInfo_Value(b, "D_POSITION")
    return pa < pb
  end)

  local originals = {}

  for _, item in ipairs(items) do
    originals[#originals + 1] = CaptureItemState(item)
  end

  local window_open = true
  local original_cursor = reaper.GetCursorPosition()
  local original_view_start, original_view_end =
    reaper.GetSet_ArrangeView2(0, false, 0, 0)
  local boundary_index = 0
  local center_view = true
  local preserve_fades = CFG.fade_policy == "preserve"
  local preview_only = CFG.preview_only
  local show_summary = CFG.show_summary
  local plans = {}
  local plans_valid = false
  local preview_error = nil
  local scan_dirty = false
  local fade_dirty = false
  local last_preview = 0
  local popup_values = {}
  local popup_focus = {}

  local first_use = ImGuiConstant("ImGui_Cond_FirstUseEver", 4)
  local right_button = ImGuiConstant("ImGui_MouseButton_Right", 1)
  local enter_key = ImGuiConstant("ImGui_Key_Enter", 0)

  -- need_scan = false means only fade settings changed: reuse the last
  -- detection plan and just restore + reapply fades. This avoids a full
  -- audio rescan when dragging the fade sliders.
  local function UpdatePreview(need_scan)
    RestoreOriginalStates(originals)

    local result = plans

    if need_scan or not plans_valid then
      local ok, scanned = pcall(ScanItems, items)

      if not ok then
        plans_valid = false
        preview_error = tostring(scanned)
        RestoreOriginalStates(originals)
        return false
      end

      result = scanned
      plans_valid = true
    end

    local applied, apply_error = ApplyPlansPreview(result)

    if not applied then
      plans_valid = false
      preview_error = tostring(apply_error)
      RestoreOriginalStates(originals)
      return false
    end

    plans = result
    preview_error = nil
    return true
  end

  local function DrawNumber(label, key, min_value, max_value, format)
    local changed = false

    local slider_changed, value = reaper.ImGui_SliderDouble(
      ctx, label, CFG[key], min_value, max_value, format
    )

    if slider_changed then
      CFG[key] = value
      changed = true
    end

    -- Right-click a slider to type an exact value in a small popup.
    if reaper.ImGui_IsItemHovered(ctx)
      and reaper.ImGui_IsMouseClicked(ctx, right_button) then
      popup_values[key] = CFG[key]
      popup_focus[key] = true
      reaper.ImGui_OpenPopup(ctx, "##" .. key)
    end

    if reaper.ImGui_BeginPopup(ctx, "##" .. key) then
      reaper.ImGui_Text(ctx, label)
      reaper.ImGui_SetNextItemWidth(ctx, 180)

      if popup_focus[key] then
        reaper.ImGui_SetKeyboardFocusHere(ctx)
        popup_focus[key] = false
      end

      local typed_changed, typed = reaper.ImGui_InputDouble(
        ctx, "##value", popup_values[key] or CFG[key], 0, 0, format
      )

      -- Apply the displayed value even if ImGui did not report a change
      -- this frame (some versions only report on Enter/focus loss). This
      -- keeps the live preview in sync while typing and if the popup is
      -- dismissed by clicking elsewhere.
      if typed ~= nil then
        local clamped = ClampNumber(
          typed, CFG[key], min_value, max_value
        )

        if math.abs(clamped - CFG[key]) > 1e-9 then
          popup_values[key] = clamped
          CFG[key] = clamped
          changed = true
        end
      elseif typed_changed then
        changed = true
      end

      if reaper.ImGui_Button(ctx, "OK")
        or reaper.ImGui_IsKeyPressed(ctx, enter_key) then
        reaper.ImGui_CloseCurrentPopup(ctx)
      end

      reaper.ImGui_EndPopup(ctx)
    end

    return changed
  end

  local function GetBoundaryInfo(index)
    if #items == 0 then
      return nil
    end

    index = math.max(1, math.min(#items * 2, index))

    local item_index = math.floor((index - 1) / 2) + 1
    local item = items[item_index]
    local position = reaper.GetMediaItemInfo_Value(item, "D_POSITION")
    local length = reaper.GetMediaItemInfo_Value(item, "D_LENGTH")
    local is_head = (index % 2 == 1)
    local target = is_head and position or (position + length)

    return target, item_index, is_head
  end

  local function RestoreCursor()
    reaper.SetEditCurPos(original_cursor, false, false)
  end

  local function RestoreView()
    if original_view_start
      and original_view_end
      and original_view_end > original_view_start then
      reaper.GetSet_ArrangeView2(
        0, true, 0, 0, original_view_start, original_view_end
      )
    end
  end

  local function CenterArrangeOnCursor()
    local view_start, view_end = reaper.GetSet_ArrangeView2(
      0, false, 0, 0
    )

    if not view_start or not view_end or view_end <= view_start then
      return
    end

    local cursor = reaper.GetCursorPosition()
    local width = view_end - view_start

    -- Keep the current horizontal zoom, but put the edit cursor exactly
    -- in the middle of the arrange view.
    reaper.GetSet_ArrangeView2(
      0, true, 0, 0, cursor - width / 2, cursor + width / 2
    )
  end

  local function JumpToBoundary(index)
    local total = #items * 2

    if total == 0 then
      return
    end

    if index < 1 then
      index = total
    elseif index > total then
      index = 1
    end

    boundary_index = index

    local target = GetBoundaryInfo(index)

    if target then
      reaper.SetEditCurPos(target, true, true)

      if center_view then
        CenterArrangeOnCursor()
      end
    end
  end

  local function DrawBoundaryNavigation()
    reaper.ImGui_Separator(ctx)
    reaper.ImGui_Spacing(ctx)

    local total = #items * 2

    if boundary_index == 0 then
      reaper.ImGui_Text(ctx, string.format(
        "Boundary navigation: - / %d", total
      ))
    else
      local target, item_index, is_head =
        GetBoundaryInfo(boundary_index)

      reaper.ImGui_Text(ctx, string.format(
        "Boundary %d/%d - item %d/%d %s @ %.3f s",
        boundary_index, total, item_index, #items,
        is_head and "HEAD" or "TAIL", target
      ))
    end

    if reaper.ImGui_Button(ctx, "< Prev") then
      if boundary_index == 0 then
        JumpToBoundary(total)
      else
        JumpToBoundary(boundary_index - 1)
      end
    end

    reaper.ImGui_SameLine(ctx)

    if reaper.ImGui_Button(ctx, "Next >") then
      if boundary_index == 0 then
        JumpToBoundary(1)
      else
        JumpToBoundary(boundary_index + 1)
      end
    end

    reaper.ImGui_SameLine(ctx)

    local current_item = boundary_index == 0
      and 1
      or math.floor((boundary_index - 1) / 2) + 1

    if reaper.ImGui_Button(ctx, "Head") then
      JumpToBoundary(current_item * 2 - 1)
    end

    reaper.ImGui_SameLine(ctx)

    if reaper.ImGui_Button(ctx, "Tail") then
      JumpToBoundary(current_item * 2)
    end

    reaper.ImGui_SameLine(ctx)

    if reaper.ImGui_Button(ctx, "Play/Stop") then
      reaper.Main_OnCommand(40044, 0)
    end

    local _, center_checked = reaper.ImGui_Checkbox(
      ctx, "Center view on cursor", center_view
    )
    center_view = center_checked

    reaper.ImGui_TextWrapped(ctx,
      "Moves the edit cursor. While playing, playback seeks to the "
      .. "boundary. Use Head + Play/Stop to audition an item, or step "
      .. "through every selected item head and tail."
    )
  end

  local initial_ok = UpdatePreview()

  if not initial_ok then
    RestoreOriginalStates(originals)
    RestoreCursor()
    RestoreView()
    reaper.ShowMessageBox(
      "Could not build the live preview.\n\n" .. tostring(preview_error),
      "Trim leading/trailing silence: preview error",
      0
    )
    return
  end

  last_preview = reaper.time_precise()

  local function Loop()
    reaper.ImGui_SetNextWindowSize(ctx, 560, 0, first_use)

    local visible, p_open = reaper.ImGui_Begin(
      ctx, "Trim leading/trailing silence", window_open
    )

    local run = false
    local scan_changed = false
    local fade_changed = false

    if visible then
      reaper.ImGui_Text(ctx, string.format(
        "Items in live preview: %d", #items
      ))
      reaper.ImGui_Separator(ctx)
      reaper.ImGui_Spacing(ctx)

      if DrawNumber(
        "Threshold (dBFS)", "threshold_db", -144, 0, "%.1f"
      ) then
        scan_changed = true
      end

      if DrawNumber(
        "Leading pad (ms)", "leading_pad_ms", 0, 5000, "%.1f"
      ) then
        scan_changed = true
      end

      if DrawNumber(
        "Trailing pad (ms)", "trailing_pad_ms", 0, 5000, "%.1f"
      ) then
        scan_changed = true
      end

      if DrawNumber(
        "Fade in (ms)", "fade_in_ms", 0, 1000, "%.1f"
      ) then
        fade_changed = true
      end

      if DrawNumber(
        "Fade out (ms)", "fade_out_ms", 0, 1000, "%.1f"
      ) then
        fade_changed = true
      end

      if DrawNumber(
        "Minimum trim (ms)", "min_trim_ms", 0, 1000, "%.1f"
      ) then
        scan_changed = true
      end

      -- Changing this one only affects the refresh interval itself.
      if DrawNumber(
        "Live preview interval (ms)",
        "preview_refresh_ms", 50, 1000, "%.0f"
      ) then
        CFG.preview_refresh_ms = math.max(
          50, math.min(1000, CFG.preview_refresh_ms)
        )
      end

      reaper.ImGui_Spacing(ctx)

      local _, checked

      _, checked = reaper.ImGui_Checkbox(
        ctx,
        "Keep existing fade lengths (off = reset to short fades)",
        preserve_fades
      )

      if checked ~= preserve_fades then
        preserve_fades = checked
        fade_changed = true
      end

      _, checked = reaper.ImGui_Checkbox(
        ctx, "Preview only (Run reports, then restores)", preview_only
      )
      preview_only = checked

      _, checked = reaper.ImGui_Checkbox(
        ctx, "Show summary after Run", show_summary
      )
      show_summary = checked

      reaper.ImGui_Spacing(ctx)
      reaper.ImGui_Separator(ctx)
      reaper.ImGui_Spacing(ctx)

      reaper.ImGui_TextWrapped(ctx,
        "Drag a slider, or right-click it to type an exact value. "
        .. "Changes are applied to the selected items immediately so "
        .. "you can audition them. Run commits; Cancel or closing the "
        .. "window restores the original item state."
      )

      reaper.ImGui_Spacing(ctx)

      reaper.ImGui_TextWrapped(ctx,
        "Threshold is measured on the source audio, before item/take "
        .. "volume and fades. Room tone above the threshold counts as "
        .. "sound, so noisy edges are intentionally left untouched."
      )

      reaper.ImGui_Spacing(ctx)

      if preview_error then
        reaper.ImGui_Text(ctx, "Preview error: " .. tostring(preview_error))
      else
        local status = string.format(
          "Live preview: %d item(s) would be trimmed", #plans
        )

        if stats.errors > 0 then
          status = status .. string.format(", %d error(s)", stats.errors)
        end

        reaper.ImGui_Text(ctx, status)
      end

      reaper.ImGui_Spacing(ctx)
      DrawBoundaryNavigation()
      reaper.ImGui_Spacing(ctx)

      if reaper.ImGui_Button(ctx, "Run", 120, 0) then
        run = true
      end

      reaper.ImGui_SameLine(ctx)

      if reaper.ImGui_Button(ctx, "Cancel", 100, 0) then
        window_open = false
      end

      reaper.ImGui_SameLine(ctx)

      if reaper.ImGui_Button(ctx, "Defaults") then
        CFG.threshold_db = DEFAULTS.threshold_db
        CFG.leading_pad_ms = DEFAULTS.leading_pad_ms
        CFG.trailing_pad_ms = DEFAULTS.trailing_pad_ms
        CFG.fade_in_ms = DEFAULTS.fade_in_ms
        CFG.fade_out_ms = DEFAULTS.fade_out_ms
        CFG.min_trim_ms = DEFAULTS.min_trim_ms
        CFG.preview_refresh_ms = DEFAULTS.preview_refresh_ms
        preserve_fades = DEFAULTS.fade_policy == "preserve"
        preview_only = DEFAULTS.preview_only
        show_summary = DEFAULTS.show_summary
        scan_changed = true
        fade_changed = true
      end
    end

    reaper.ImGui_End(ctx)

    if p_open == false then
      window_open = false
    end

    -- Keep CFG in sync with the window before previewing or committing.
    CFG.fade_policy = preserve_fades and "preserve" or "short"
    CFG.preview_only = preview_only
    CFG.show_summary = show_summary

    if scan_changed then
      scan_dirty = true
    end

    if fade_changed then
      fade_dirty = true
    end

    if run then
      if preview_error then
        reaper.ShowMessageBox(
          "The live preview failed. Nothing is committed.\n\n"
            .. tostring(preview_error),
          "Trim leading/trailing silence: preview error",
          0
        )
        RestoreOriginalStates(originals)
        RestoreCursor()
        RestoreView()
        window_open = false
        return
      end

      if scan_dirty or not plans_valid then
        if not UpdatePreview(true) then
          reaper.ShowMessageBox(
            "The live preview failed. Nothing is committed.\n\n"
              .. tostring(preview_error),
            "Trim leading/trailing silence: preview error",
            0
          )
          RestoreOriginalStates(originals)
          RestoreCursor()
          RestoreView()
          window_open = false
          return
        end

        scan_dirty = false
        fade_dirty = false
      end

      RestoreOriginalStates(originals)

      if preview_only then
        FillPlannedStats(plans)
      else
        local ok, err = ApplyPlansWithUndo(plans)

        if not ok then
          stats.errors = stats.errors + 1
          reaper.ShowMessageBox(
            "Processing stopped while applying changes.\n"
              .. "Finished changes can be reverted with Undo.\n\n"
              .. tostring(err),
            "Trim leading/trailing silence: error",
            0
          )
        end
      end

      SaveSettings()

      if show_summary then
        local title = preview_only
          and "Trim leading/trailing silence (preview)"
          or "Trim leading/trailing silence"

        reaper.ShowMessageBox(BuildSummary(), title, 0)
      end

      return
    end

    if not window_open then
      RestoreOriginalStates(originals)
      RestoreCursor()
      RestoreView()
      return
    end

    if scan_dirty or fade_dirty then
      local now = reaper.time_precise()
      local interval = math.max(
        0.05, math.min(2.0, (CFG.preview_refresh_ms or 250) / 1000)
      )

      if now - last_preview >= interval then
        local need_scan = scan_dirty
        scan_dirty = false
        fade_dirty = false

        UpdatePreview(need_scan)
        last_preview = reaper.time_precise()
      end
    end

    reaper.defer(Loop)
  end

  reaper.defer(Loop)
end


local function Start()
  if not CFG.show_settings_window then
    Init()
    return
  end

  LoadSettings()

  local missing = CheckRequiredAPIs()

  if #missing > 0 then
    reaper.ShowMessageBox(
      "This script needs a newer REAPER version.\nMissing API:\n"
        .. table.concat(missing, "\n"),
      "Trim leading/trailing silence",
      0
    )
    return
  end

  local items = GetSelectedItems()

  if #items == 0 then
    reaper.ShowMessageBox(
      "Select one or more audio media items first.",
      "Trim leading/trailing silence",
      0
    )
    return
  end

  if ImGuiAvailable() then
    ShowImGuiSettings(items)
  else
    ShowNativeSettings()
  end
end


Start()

