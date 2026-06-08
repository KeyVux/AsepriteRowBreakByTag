-- Tag-Packed Spritesheet Exporter
-- Exports a spritesheet where frames are packed row-by-row,
-- but a new row is always started when the tag changes.

-- ─── Helpers ──────────────────────────────────────────────────────────────────

-- Recursively collect all visible, non-group layers (respects group visibility)
local function collect_visible_layers(container, list, parent_visible)
  parent_visible = (parent_visible ~= false)
  for _, layer in ipairs(container.layers) do
    local visible = parent_visible and layer.isVisible
    if layer.isGroup then
      collect_visible_layers(layer, list, visible)
    elseif visible then
      table.insert(list, layer)
    end
  end
  return list
end

-- Returns the tight bounding rect of non-transparent pixels in an Image,
-- or nil if the image is fully transparent. Handles RGB, Grayscale, and Indexed.
local function trim_bounds(img, sprite)
  local x0, y0, x1, y1 = img.width, img.height, -1, -1
  local cm  = sprite.colorMode
  local pal = sprite.palettes[1]
  local tc  = sprite.transparentColor

  for py = 0, img.height - 1 do
    for px = 0, img.width - 1 do
      local c = img:getPixel(px, py)
      local opaque = false

      if cm == ColorMode.RGB then
        opaque = app.pixelColor.rgbaA(c) > 0
      elseif cm == ColorMode.GRAY then
        opaque = app.pixelColor.grayaA(c) > 0
      elseif cm == ColorMode.INDEXED then
        if c ~= tc then
          if pal and c < #pal then
            opaque = pal:getColor(c).alpha > 0
          else
            opaque = true
          end
        end
      end

      if opaque then
        if px < x0 then x0 = px end
        if py < y0 then y0 = py end
        if px > x1 then x1 = px end
        if py > y1 then y1 = py end
      end
    end
  end

  if x1 < 0 then return nil end
  return { x = x0, y = y0, w = x1 - x0 + 1, h = y1 - y0 + 1 }
end

-- Flatten all visible layers for a given frame index into a single Image
local function flatten_frame(sprite, frame_index, visible_layers)
  local flat = Image(sprite.spec)
  flat:clear()
  for _, layer in ipairs(visible_layers) do
    local cel = layer:cel(frame_index)
    if cel then
      flat:drawImage(cel.image, cel.position)
    end
  end
  return flat
end

-- ─── Main export function ─────────────────────────────────────────────────────

local function export_spritesheet(plugin)
  local spr = app.activeSprite
  if not spr then
    app.alert("No active sprite.")
    return
  end

  -- ── Config dialog ──────────────────────────────────────────────────────────

  local prefs = plugin and plugin.preferences or {}
  if prefs.maxWidth == nil  then prefs.maxWidth  = 4096 end
  if prefs.padding  == nil  then prefs.padding   = 1    end

  local default_out = app.fs.joinPath(
    app.fs.filePath(spr.filename),
    app.fs.fileTitle(spr.filename) .. "_sheet.png"
  )

  local dlg = Dialog("Tag-Packed Spritesheet Export")
  dlg:file{
    id        = "output",
    label     = "Output PNG",
    save      = true,
    filetypes = { "png" },
    filename  = default_out,
  }
  dlg:number{ id = "maxWidth",   label = "Max sheet width (px)",       text = tostring(prefs.maxWidth), decimals = 0 }
  dlg:number{ id = "padding",    label = "Padding between frames (px)", text = tostring(prefs.padding),  decimals = 0 }
  dlg:check{  id = "trimFrames", label = "Trim transparent borders",    selected = false }
  dlg:check{  id = "save_json",  label = "Export JSON metadata",        selected = false }
  dlg:button{ id = "ok",     text = "Export", focus = true }
  dlg:button{ id = "cancel", text = "Cancel" }
  dlg:show()

  if not dlg.data.ok then return end

  local output_path = dlg.data.output
  local max_width   = math.max(1,  math.floor(dlg.data.maxWidth))
  local padding     = math.max(0,  math.floor(dlg.data.padding))
  local trim_frames = dlg.data.trimFrames
  local save_json   = dlg.data.save_json

  if output_path == "" then
    app.alert("Please choose an output file.")
    return
  end

  -- Persist preferences
  if plugin then
    prefs.maxWidth = max_width
    prefs.padding  = padding
  end

  -- ── Build frame-tag map ────────────────────────────────────────────────────

  -- frame_tag[i] = tag name for frame i (1-indexed), "" if untagged
  local frame_tag = {}
  for i = 1, #spr.frames do frame_tag[i] = "" end

  -- Sort tags by first frame so earlier tags win on overlap
  local sorted_tags = {}
  for _, tag in ipairs(spr.tags) do
    table.insert(sorted_tags, tag)
  end
  table.sort(sorted_tags, function(a, b)
    return a.fromFrame.frameNumber < b.fromFrame.frameNumber
  end)

  for _, tag in ipairs(sorted_tags) do
    for fi = tag.fromFrame.frameNumber, tag.toFrame.frameNumber do
      if frame_tag[fi] == "" then
        frame_tag[fi] = tag.name
      end
    end
  end

  -- ── Collect visible layers ─────────────────────────────────────────────────

  local visible_layers = collect_visible_layers(spr, {}, true)

  -- ── Build per-frame entry list ─────────────────────────────────────────────

  -- entry = { img, tag, srcX, srcY, w, h }
  local entries = {}
  for fi = 1, #spr.frames do
    local flat = flatten_frame(spr, fi, visible_layers)

    local sx, sy, sw, sh = 0, 0, spr.width, spr.height
    if trim_frames then
      local b = trim_bounds(flat, spr)
      if b then
        sx, sy, sw, sh = b.x, b.y, b.w, b.h
      else
        sw, sh = 1, 1  -- fully transparent: 1×1 placeholder
      end
    end

    table.insert(entries, {
      img  = flat,
      tag  = frame_tag[fi],
      srcX = sx, srcY = sy,
      w    = sw, h    = sh,
    })
  end

  -- ── Layout ─────────────────────────────────────────────────────────────────
  -- Pack frames row-by-row; start a new row whenever the tag changes.

  local rows       = {}
  local cur_row    = nil
  local cur_tag    = nil  -- will differ from any real tag on first frame
  local cursor_x   = 0
  local cursor_y   = 0

  for _, entry in ipairs(entries) do
    local new_tag = (entry.tag ~= cur_tag)
    local fits_x  = cur_row and (cursor_x + entry.w) <= max_width

    if (not cur_row) or new_tag or (not fits_x) then
      -- Close previous row
      if cur_row then
        local rh = 0
        for _, slot in ipairs(cur_row.frames) do
          if slot.entry.h > rh then rh = slot.entry.h end
        end
        cur_row.rowH = rh
        cursor_y = cursor_y + rh + padding
      end
      -- Open new row
      cur_row = { frames = {}, rowH = 0, rowY = cursor_y, tag = entry.tag }
      table.insert(rows, cur_row)
      cursor_x = 0
      if new_tag then cur_tag = entry.tag end
    end

    table.insert(cur_row.frames, {
      entry  = entry,
      sheetX = cursor_x,
      sheetY = cursor_y,
    })
    cursor_x = cursor_x + entry.w + padding
  end

  -- Close last row
  if cur_row then
    local rh = 0
    for _, slot in ipairs(cur_row.frames) do
      if slot.entry.h > rh then rh = slot.entry.h end
    end
    cur_row.rowH = rh
    cursor_y = cursor_y + rh
  end

  -- ── Sheet dimensions ───────────────────────────────────────────────────────

  local sheet_w, sheet_h = 0, cursor_y
  for _, row in ipairs(rows) do
    for _, slot in ipairs(row.frames) do
      local right = slot.sheetX + slot.entry.w
      if right > sheet_w then sheet_w = right end
    end
  end

  if sheet_w == 0 or sheet_h == 0 then
    app.alert("Nothing to export (empty sprite?).")
    return
  end

  -- ── Compose sheet ──────────────────────────────────────────────────────────

  local sheet_spec = ImageSpec{
    width            = sheet_w,
    height           = sheet_h,
    colorMode        = spr.colorMode,
    transparentColor = spr.transparentColor,
  }
  local sheet = Image(sheet_spec)
  sheet:clear()

  -- Collect JSON data while compositing
  local json_frames = {}
  local json_tags   = {}
  local current_json_tag = nil
  local current_json_tag_entry = nil

  for _, row in ipairs(rows) do
    for _, slot in ipairs(row.frames) do
      local e = slot.entry

      -- Draw the (possibly trimmed) sub-image from the flattened frame
      local sub = Image(ImageSpec{
        width            = e.w,
        height           = e.h,
        colorMode        = spr.colorMode,
        transparentColor = spr.transparentColor,
      })
      sub:clear()
      sub:drawImage(e.img, Point(-e.srcX, -e.srcY))

      sheet:drawImage(sub, Point(slot.sheetX, slot.sheetY))

      -- JSON accumulation
      if save_json then
        if e.tag ~= current_json_tag then
          current_json_tag = e.tag
          current_json_tag_entry = { name = e.tag, frames = {} }
          table.insert(json_tags, current_json_tag_entry)
        end
        local frame_key = e.tag .. "_" .. tostring(#current_json_tag_entry.frames + 1)
        table.insert(json_frames, {
          key = frame_key,
          x   = slot.sheetX, y = slot.sheetY,
          w   = e.w,         h = e.h,
        })
        table.insert(current_json_tag_entry.frames, frame_key)
      end
    end
  end

  -- ── Save PNG ───────────────────────────────────────────────────────────────

  if spr.colorMode == ColorMode.INDEXED and #spr.palettes > 0 then
    sheet:saveAs{ filename = output_path, palette = spr.palettes[1] }
  else
    sheet:saveAs(output_path)
  end

  -- ── Save JSON sidecar ──────────────────────────────────────────────────────

  if save_json then
    local json_path = output_path:gsub("%.png$", ".json")
    local f = io.open(json_path, "w")
    if f then
      f:write('{\n  "frames": {\n')
      for i, fr in ipairs(json_frames) do
        local comma = (i < #json_frames) and "," or ""
        f:write(string.format(
          '    "%s": { "frame": { "x": %d, "y": %d, "w": %d, "h": %d } }%s\n',
          fr.key, fr.x, fr.y, fr.w, fr.h, comma
        ))
      end
      f:write('  },\n  "meta": {\n    "tags": [\n')
      for i, tg in ipairs(json_tags) do
        local comma = (i < #json_tags) and "," or ""
        local frames_str = '"' .. table.concat(tg.frames, '", "') .. '"'
        f:write(string.format(
          '      { "name": "%s", "frames": [ %s ] }%s\n',
          tg.name, frames_str, comma
        ))
      end
      f:write('    ]\n  }\n}\n')
      f:close()
    end
  end

  -- ── Done ───────────────────────────────────────────────────────────────────

  local msg = string.format(
    "Exported %d frames across %d rows.\nSaved to: %s",
    #entries, #rows, output_path
  )
  if save_json then
    msg = msg .. "\nJSON: " .. output_path:gsub("%.png$", ".json")
  end
  app.alert(msg)
end

-- ─── Plugin entry points ──────────────────────────────────────────────────────

function init(plugin)
  plugin:newCommand{
    id      = "TagPackedSpritesheetExport",
    title   = "Tag-Packed Spritesheet Export",
    group   = "file_export",
    onclick = function()
      export_spritesheet(plugin)
    end,
  }
end

function exit(plugin)
  -- nothing to clean up
end
-- Tag-Packed Spritesheet Exporter
-- Exports a spritesheet where frames are packed row-by-row,
-- but a new row is always started when the tag changes.

-- ─── Helpers ──────────────────────────────────────────────────────────────────

-- Recursively collect all visible, non-group layers (respects group visibility)
local function collect_visible_layers(container, list, parent_visible)
  parent_visible = (parent_visible ~= false)
  for _, layer in ipairs(container.layers) do
    local visible = parent_visible and layer.isVisible
    if layer.isGroup then
      collect_visible_layers(layer, list, visible)
    elseif visible then
      table.insert(list, layer)
    end
  end
  return list
end

-- Returns the tight bounding rect of non-transparent pixels in an Image,
-- or nil if the image is fully transparent. Handles RGB, Grayscale, and Indexed.
local function trim_bounds(img, sprite)
  local x0, y0, x1, y1 = img.width, img.height, -1, -1
  local cm  = sprite.colorMode
  local pal = sprite.palettes[1]
  local tc  = sprite.transparentColor

  for py = 0, img.height - 1 do
    for px = 0, img.width - 1 do
      local c = img:getPixel(px, py)
      local opaque = false

      if cm == ColorMode.RGB then
        opaque = app.pixelColor.rgbaA(c) > 0
      elseif cm == ColorMode.GRAY then
        opaque = app.pixelColor.grayaA(c) > 0
      elseif cm == ColorMode.INDEXED then
        if c ~= tc then
          if pal and c < #pal then
            opaque = pal:getColor(c).alpha > 0
          else
            opaque = true
          end
        end
      end

      if opaque then
        if px < x0 then x0 = px end
        if py < y0 then y0 = py end
        if px > x1 then x1 = px end
        if py > y1 then y1 = py end
      end
    end
  end

  if x1 < 0 then return nil end
  return { x = x0, y = y0, w = x1 - x0 + 1, h = y1 - y0 + 1 }
end

-- Flatten all visible layers for a given frame index into a single Image
local function flatten_frame(sprite, frame_index, visible_layers)
  local flat = Image(sprite.spec)
  flat:clear()
  for _, layer in ipairs(visible_layers) do
    local cel = layer:cel(frame_index)
    if cel then
      flat:drawImage(cel.image, cel.position)
    end
  end
  return flat
end

-- ─── Main export function ─────────────────────────────────────────────────────

local function export_spritesheet(plugin)
  local spr = app.activeSprite
  if not spr then
    app.alert("No active sprite.")
    return
  end

  -- ── Config dialog ──────────────────────────────────────────────────────────

  local prefs = plugin and plugin.preferences or {}
  if prefs.maxWidth == nil  then prefs.maxWidth  = 4096 end
  if prefs.padding  == nil  then prefs.padding   = 1    end

  local default_out = app.fs.joinPath(
    app.fs.filePath(spr.filename),
    app.fs.fileTitle(spr.filename) .. "_sheet.png"
  )

  local dlg = Dialog("Tag-Packed Spritesheet Export")
  dlg:file{
    id        = "output",
    label     = "Output PNG",
    save      = true,
    filetypes = { "png" },
    filename  = default_out,
  }
  dlg:number{ id = "maxWidth",   label = "Max sheet width (px)",       text = tostring(prefs.maxWidth), decimals = 0 }
  dlg:number{ id = "padding",    label = "Padding between frames (px)", text = tostring(prefs.padding),  decimals = 0 }
  dlg:check{  id = "trimFrames", label = "Trim transparent borders",    selected = false }
  dlg:check{  id = "save_json",  label = "Export JSON metadata",        selected = false }
  dlg:button{ id = "ok",     text = "Export", focus = true }
  dlg:button{ id = "cancel", text = "Cancel" }
  dlg:show()

  if not dlg.data.ok then return end

  local output_path = dlg.data.output
  local max_width   = math.max(1,  math.floor(dlg.data.maxWidth))
  local padding     = math.max(0,  math.floor(dlg.data.padding))
  local trim_frames = dlg.data.trimFrames
  local save_json   = dlg.data.save_json

  if output_path == "" then
    app.alert("Please choose an output file.")
    return
  end

  -- Persist preferences
  if plugin then
    prefs.maxWidth = max_width
    prefs.padding  = padding
  end

  -- ── Build frame-tag map ────────────────────────────────────────────────────

  -- frame_tag[i] = tag name for frame i (1-indexed), "" if untagged
  local frame_tag = {}
  for i = 1, #spr.frames do frame_tag[i] = "" end

  -- Sort tags by first frame so earlier tags win on overlap
  local sorted_tags = {}
  for _, tag in ipairs(spr.tags) do
    table.insert(sorted_tags, tag)
  end
  table.sort(sorted_tags, function(a, b)
    return a.fromFrame.frameNumber < b.fromFrame.frameNumber
  end)

  for _, tag in ipairs(sorted_tags) do
    for fi = tag.fromFrame.frameNumber, tag.toFrame.frameNumber do
      if frame_tag[fi] == "" then
        frame_tag[fi] = tag.name
      end
    end
  end

  -- ── Collect visible layers ─────────────────────────────────────────────────

  local visible_layers = collect_visible_layers(spr, {}, true)

  -- ── Build per-frame entry list ─────────────────────────────────────────────

  -- entry = { img, tag, srcX, srcY, w, h }
  local entries = {}
  for fi = 1, #spr.frames do
    local flat = flatten_frame(spr, fi, visible_layers)

    local sx, sy, sw, sh = 0, 0, spr.width, spr.height
    if trim_frames then
      local b = trim_bounds(flat, spr)
      if b then
        sx, sy, sw, sh = b.x, b.y, b.w, b.h
      else
        sw, sh = 1, 1  -- fully transparent: 1×1 placeholder
      end
    end

    table.insert(entries, {
      img  = flat,
      tag  = frame_tag[fi],
      srcX = sx, srcY = sy,
      w    = sw, h    = sh,
    })
  end

  -- ── Layout ─────────────────────────────────────────────────────────────────
  -- Pack frames row-by-row; start a new row whenever the tag changes.

  local rows       = {}
  local cur_row    = nil
  local cur_tag    = nil  -- will differ from any real tag on first frame
  local cursor_x   = 0
  local cursor_y   = 0

  for _, entry in ipairs(entries) do
    local new_tag = (entry.tag ~= cur_tag)
    local fits_x  = cur_row and (cursor_x + entry.w) <= max_width

    if (not cur_row) or new_tag or (not fits_x) then
      -- Close previous row
      if cur_row then
        local rh = 0
        for _, slot in ipairs(cur_row.frames) do
          if slot.entry.h > rh then rh = slot.entry.h end
        end
        cur_row.rowH = rh
        cursor_y = cursor_y + rh + padding
      end
      -- Open new row
      cur_row = { frames = {}, rowH = 0, rowY = cursor_y, tag = entry.tag }
      table.insert(rows, cur_row)
      cursor_x = 0
      if new_tag then cur_tag = entry.tag end
    end

    table.insert(cur_row.frames, {
      entry  = entry,
      sheetX = cursor_x,
      sheetY = cursor_y,
    })
    cursor_x = cursor_x + entry.w + padding
  end

  -- Close last row
  if cur_row then
    local rh = 0
    for _, slot in ipairs(cur_row.frames) do
      if slot.entry.h > rh then rh = slot.entry.h end
    end
    cur_row.rowH = rh
    cursor_y = cursor_y + rh
  end

  -- ── Sheet dimensions ───────────────────────────────────────────────────────

  local sheet_w, sheet_h = 0, cursor_y
  for _, row in ipairs(rows) do
    for _, slot in ipairs(row.frames) do
      local right = slot.sheetX + slot.entry.w
      if right > sheet_w then sheet_w = right end
    end
  end

  if sheet_w == 0 or sheet_h == 0 then
    app.alert("Nothing to export (empty sprite?).")
    return
  end

  -- ── Compose sheet ──────────────────────────────────────────────────────────

  local sheet_spec = ImageSpec{
    width            = sheet_w,
    height           = sheet_h,
    colorMode        = spr.colorMode,
    transparentColor = spr.transparentColor,
  }
  local sheet = Image(sheet_spec)
  sheet:clear()

  -- Collect JSON data while compositing
  local json_frames = {}
  local json_tags   = {}
  local current_json_tag = nil
  local current_json_tag_entry = nil

  for _, row in ipairs(rows) do
    for _, slot in ipairs(row.frames) do
      local e = slot.entry

      -- Draw the (possibly trimmed) sub-image from the flattened frame
      local sub = Image(ImageSpec{
        width            = e.w,
        height           = e.h,
        colorMode        = spr.colorMode,
        transparentColor = spr.transparentColor,
      })
      sub:clear()
      sub:drawImage(e.img, Point(-e.srcX, -e.srcY))

      sheet:drawImage(sub, Point(slot.sheetX, slot.sheetY))

      -- JSON accumulation
      if save_json then
        if e.tag ~= current_json_tag then
          current_json_tag = e.tag
          current_json_tag_entry = { name = e.tag, frames = {} }
          table.insert(json_tags, current_json_tag_entry)
        end
        local frame_key = e.tag .. "_" .. tostring(#current_json_tag_entry.frames + 1)
        table.insert(json_frames, {
          key = frame_key,
          x   = slot.sheetX, y = slot.sheetY,
          w   = e.w,         h = e.h,
        })
        table.insert(current_json_tag_entry.frames, frame_key)
      end
    end
  end

  -- ── Save PNG ───────────────────────────────────────────────────────────────

  if spr.colorMode == ColorMode.INDEXED and #spr.palettes > 0 then
    sheet:saveAs{ filename = output_path, palette = spr.palettes[1] }
  else
    sheet:saveAs(output_path)
  end

  -- ── Save JSON sidecar ──────────────────────────────────────────────────────

  if save_json then
    local json_path = output_path:gsub("%.png$", ".json")
    local f = io.open(json_path, "w")
    if f then
      f:write('{\n  "frames": {\n')
      for i, fr in ipairs(json_frames) do
        local comma = (i < #json_frames) and "," or ""
        f:write(string.format(
          '    "%s": { "frame": { "x": %d, "y": %d, "w": %d, "h": %d } }%s\n',
          fr.key, fr.x, fr.y, fr.w, fr.h, comma
        ))
      end
      f:write('  },\n  "meta": {\n    "tags": [\n')
      for i, tg in ipairs(json_tags) do
        local comma = (i < #json_tags) and "," or ""
        local frames_str = '"' .. table.concat(tg.frames, '", "') .. '"'
        f:write(string.format(
          '      { "name": "%s", "frames": [ %s ] }%s\n',
          tg.name, frames_str, comma
        ))
      end
      f:write('    ]\n  }\n}\n')
      f:close()
    end
  end

  -- ── Done ───────────────────────────────────────────────────────────────────

  local msg = string.format(
    "Exported %d frames across %d rows.\nSaved to: %s",
    #entries, #rows, output_path
  )
  if save_json then
    msg = msg .. "\nJSON: " .. output_path:gsub("%.png$", ".json")
  end
  app.alert(msg)
end

-- ─── Plugin entry points ──────────────────────────────────────────────────────

function init(plugin)
  plugin:newCommand{
    id      = "TagPackedSpritesheetExport",
    title   = "Tag-Packed Spritesheet Export",
    group   = "file_export",
    onclick = function()
      export_spritesheet(plugin)
    end,
  }
end

function exit(plugin)
  -- nothing to clean up
end
