-- @noindex
-- ReaBackground.lua — shows a video (synced to the play/edit cursor) or a
-- still image behind the arrange view, using reaper_reabackground.dylib. One
-- script hosts both the engine (defer loop) and the settings window (ReaImGui).
-- Running the action again while it runs reopens the window: the extension
-- intercepts the relaunch and sets ExtState "show" instead. The script exits
-- when the window is closed and the background is stopped.

local SECTION = "ReaBackground"
local LIB_DIR = reaper.GetResourcePath() .. "/Data/ReaBackground/"

-- Fallbacks for themes that don't set these (REAPER's own defaults).
local DEFAULT_MODES = { timesel_drawmode = 0x21100, mute_overlay_mode = 0x2A600,
                        col_gridlines1dm = 0x30000, col_gridlines2dm = 0x30000, col_gridlines3dm = 0x30000 }
-- Draw modes: low byte = LICE blend mode, next byte = alpha/256; bit 0x10000
-- means blending is off and the colour is drawn solid.
local function mode_solid(mode) return mode & 0x10000 ~= 0 end
local function mode_alpha(mode) return mode_solid(mode) and 1 or ((mode >> 8) & 0xFF) / 256 end
-- Near-key catch-all for shaded background we did not predict (see extension).
local NEAR_OPACITY, NEAR_GAIN = 0.35, 3
-- Theme colours that make up the empty track-area background; all get set to the key.
local BG_KEYS = { "col_arrangebg", "col_tr1_bg", "col_tr2_bg", "selcol_tr1_bg", "selcol_tr2_bg" }
local ENABLE_RETRY_S = 5
local CHECK_INTERVAL = 1

if not reaper.AUBG_Enable or not reaper.AUBG_ImportImage then
  reaper.MB("reaper_reabackground.dylib is missing or outdated. Install it into UserPlugins and restart REAPER.", "ReaBackground", 0)
  return
end

local _, script_path, sec_id, cmd_id = reaper.get_action_context()
reaper.RecursiveCreateDirectory(LIB_DIR, 0)

local function setting(key, default)
  local v = reaper.GetExtState(SECTION, key)
  if v == "" then return default end
  return tonumber(v) or v
end
local function set_setting(key, value)
  reaper.SetExtState(SECTION, key, tostring(value), true)
end
local function proj_get(key)
  local _, v = reaper.GetProjExtState(0, SECTION, key)
  return v
end
local function proj_set(key, value)
  if proj_get(key) ~= value then
    reaper.SetProjExtState(0, SECTION, key, value)
    reaper.MarkProjectDirty(0)
  end
end

local function native_to_rgb(native)
  local r, g, b = reaper.ColorFromNative(native)
  return (r << 16) | (g << 8) | b
end
local function rgb_to_native(rgb)
  return reaper.ColorToNative((rgb >> 16) & 0xFF, (rgb >> 8) & 0xFF, rgb & 0xFF)
end
local function log(fmt, ...) reaper.ShowConsoleMsg("ReaBackground: " .. string.format(fmt, ...) .. "\n") end

---------------------------------------------------------------------------
-- Theme
---------------------------------------------------------------------------
local function shell_quote(s) return "'" .. s:gsub("'", "'\\''") .. "'" end

-- Draw modes are not exposed by GetThemeColor, so read them from the theme
-- file (unzipping if needed); cached per file since that is slow.
local modes_cache = { file = nil, modes = nil }
local function read_theme_modes()
  local f = reaper.GetLastColorThemeFile() or ""
  if modes_cache.file == f and modes_cache.modes then return modes_cache.modes end
  if not reaper.file_exists(f) and reaper.file_exists(f .. "Zip") then f = f .. "Zip" end
  local text
  if f:lower():match("%.reaperthemezip$") then
    local entry
    local list = io.popen("unzip -Z1 " .. shell_quote(f) .. " 2>/dev/null")
    if list then
      for line in list:lines() do
        if line:lower():match("%.reapertheme$") then entry = line break end
      end
      list:close()
    end
    if entry then
      local p = io.popen("unzip -p " .. shell_quote(f) .. " " .. shell_quote(entry) .. " 2>/dev/null")
      if p then text = p:read("a"); p:close() end
    end
  else
    local fh = io.open(f, "rb")
    if fh then text = fh:read("a"); fh:close() end
  end
  local modes = {}
  for k, v in ("\n" .. (text or "")):gmatch("\n%s*([%w_]+)%s*=%s*(%-?%d+)") do
    if k:match("_drawmode$") or k:match("_mode$") then modes[k] = tonumber(v) end
  end
  modes_cache.file, modes_cache.modes = f, modes
  return modes
end

local saved, key_rgb, key_native = nil, nil, nil
local theme_file = nil

local function snapshot_theme()
  saved = {}
  for _, k in ipairs(BG_KEYS) do saved[k] = reaper.GetThemeColor(k, 0) end
  key_rgb = native_to_rgb(saved["col_tr1_bg"])
  key_native = rgb_to_native(key_rgb)
  theme_file = reaper.GetLastColorThemeFile()
end

local function restore_theme()
  if not saved then return end
  for k, v in pairs(saved) do reaper.SetThemeColor(k, v, 0) end
  saved = nil
  reaper.UpdateArrange()
end

-- Composite of two translucent overlays (ov1 under ov2) as one straight colour + alpha.
local function stack(c1, a1, c2, a2)
  local a = a1 + a2 * (1 - a1)
  if a <= 0 then return c2, 0 end
  local w1, w2 = a1 * (1 - a2) / a, a2 / a
  local function ch(sh)
    return math.floor(((c1 >> sh) & 0xFF) * w1 + ((c2 >> sh) & 0xFF) * w2 + 0.5)
  end
  return (ch(16) << 16) | (ch(8) << 8) | ch(0), a
end

-- Registers the colours REAPER produces by drawing its translucent overlays
-- over the key, so they show as shading over the video instead of opaque.
local function register_keys()
  local shading, grid = setting("shading", 0.6), setting("grid", 0.5)
  local modes = read_theme_modes()
  local overlays = {}
  local function add(col_key, mode_key, alpha_of)
    local col = reaper.GetThemeColor(col_key, 0)
    local mode = modes[mode_key] or DEFAULT_MODES[mode_key]
    if col ~= -1 and mode then
      overlays[#overlays + 1] = { rgb = native_to_rgb(col), mode = mode, alpha = alpha_of(mode_alpha(mode)) }
    end
  end
  -- Faint theme overlays would vanish over video; lift them to a visible floor.
  add("col_tl_bgsel", "timesel_drawmode", function(a) return math.min(1, math.max(0.3, a * 3)) * shading end)
  add("mute_overlay_col", "mute_overlay_mode", function(a) return math.min(1, math.max(0.3, a * 3)) * shading end)
  -- Grid lines: the slider is their opacity over the video (100 % = solid in
  -- the theme colour; most themes, including REAPER's own, draw them solid).
  for i = 1, 3 do
    add("col_gridlines" .. (i > 1 and i or ""), "col_gridlines" .. i .. "dm", function() return grid end)
  end
  local function blend(bg, o) return mode_solid(o.mode) and o.rgb or reaper.AUBG_BlendColor(bg, o.rgb, o.mode) end

  reaper.AUBG_ClearKeys()
  for i, o in ipairs(overlays) do
    local src = blend(key_rgb, o)
    if src >= 0 then
      reaper.AUBG_AddKey(src, 2, o.rgb, o.alpha)
      -- A solid overlay hides what is under it, so its own key already
      -- covers that pair; registering it here would shade the overlay
      -- everywhere, not just where the pair occurs.
      for j, p in ipairs(overlays) do
        if i ~= j and not mode_solid(p.mode) then
          local src2 = blend(src, p)
          local c, a = stack(o.rgb, o.alpha, p.rgb, p.alpha)
          if src2 >= 0 then reaper.AUBG_AddKey(src2, 2, c, a) end
        end
      end
    end
  end
  reaper.AUBG_SetNearKey(math.floor(setting("near_tol", 40)), NEAR_OPACITY, NEAR_GAIN)
  -- Pixels keyed with the previous outputs are premultiplied and cannot be
  -- re-derived; a full repaint gives the pass fresh source colours.
  reaper.UpdateArrange()
end

local function apply_theme()
  for _, k in ipairs(BG_KEYS) do reaper.SetThemeColor(k, key_native, 0) end
  reaper.UpdateArrange()
  register_keys()
end

---------------------------------------------------------------------------
-- Media resolution
---------------------------------------------------------------------------
local warned = {}

-- Library files are <name>.<ext>; a name has exactly one file.
local MEDIA_EXT = { mp4 = "video", jpg = "image", png = "image" }
local function lib_path(name)
  for ext in pairs(MEDIA_EXT) do
    local path = LIB_DIR .. name .. "." .. ext
    if reaper.file_exists(path) then return path end
  end
end
local function is_image(path)
  return path ~= nil and MEDIA_EXT[path:match("%.([^.]+)$") or ""] == "image"
end

-- Which part of the aspect-fill-cropped video shows, -1..1 per axis; a
-- property of the video itself (persisted ExtState keyed by its library name).
local function pan_key(path) return "pan:" .. ((path or ""):match("([^/]*)%.[^.]+$") or "") end
local function video_pan(path)
  local px, py = reaper.GetExtState(SECTION, pan_key(path)):match("^([%-%d%.]+),([%-%d%.]+)$")
  return tonumber(px) or 0, tonumber(py) or 0
end
local function set_video_pan(path, x, y)
  if math.abs(x) < 0.001 and math.abs(y) < 0.001 then
    reaper.DeleteExtState(SECTION, pan_key(path), true)
  else
    set_setting(pan_key(path), string.format("%.3f,%.3f", x, y))
  end
end

-- Returns the media path to show for a project (or nil) plus its playback
-- range: in/out = the part of the video that plays from project time 0
-- (out 0 = end); loop repeats that range. The project's own choice ("video")
-- falls back to the global default when empty.
local function resolve(proj)
  local _, video = reaper.GetProjExtState(proj, SECTION, "video")
  local _, tin = reaper.GetProjExtState(proj, SECTION, "in")
  local _, tout = reaper.GetProjExtState(proj, SECTION, "out")
  local _, loop = reaper.GetProjExtState(proj, SECTION, "loop")
  tin, tout, loop = tonumber(tin) or 0, tonumber(tout) or 0, loop == "1"
  local default = reaper.GetExtState(SECTION, "default_video")
  local name = video ~= "" and video or default
  if name == "" then return nil, tin, tout, loop end
  local path = lib_path(name)
  if not path then
    local fallback = (video ~= "" and default ~= "" and default ~= name) and lib_path(default) or nil
    local tag = tostring(proj) .. "/" .. name
    if not warned[tag] then
      warned[tag] = true
      log("'%s' not found in %s%s", name, LIB_DIR, fallback and "; using the global default" or "")
    end
    return fallback, tin, tout, loop
  end
  return path, tin, tout, loop
end

---------------------------------------------------------------------------
-- Engine
---------------------------------------------------------------------------
local bg_on = true
local enabled = false
local cur_path, cur_in, cur_out, cur_loop = nil, 0, 0, false
local cur_pan = ""
local cur_rate = nil
local cur_proj = nil
local start_time = reaper.time_precise()
local last_check = 0
local gave_up = false

local function disable()
  if enabled then reaper.AUBG_Enable(0, 0, 0) end
  enabled, cur_path, cur_proj = false, nil, nil
  restore_theme()
end

local function enable()
  snapshot_theme()
  local mode = reaper.AUBG_Enable(1, key_rgb, 0)
  if mode <= 0 then saved = nil return mode end
  enabled = true
  apply_theme()
  return mode
end

local function open_video(path, opacity)
  if reaper.AUBG_OpenVideo(path, opacity) ~= 1 then
    log("could not open %s", path)
    return false
  end
  return true
end

-- Re-resolves the video and settings; called on project switch and once per second.
local function refresh(proj)
  local path, tin, tout, loop = resolve(proj)
  cur_in, cur_out, cur_loop = tin, tout, loop
  if not path then
    if enabled then disable() end
    return
  end
  if not enabled then
    local mode = enable()
    if mode <= 0 then
      if reaper.time_precise() - start_time > ENABLE_RETRY_S and not gave_up then
        gave_up = true
        log("AUBG_Enable failed (%d): %s", mode, ({ [-1] = "arrange window not found", [-2] = "could not hook WndProc",
          [-3] = "swell internals changed", [-4] = "Metal renderer is off" })[mode] or "?")
      end
      return
    end
  end
  if path ~= cur_path then
    cur_path, cur_pan = path, ""
    open_video(path, setting("opacity", 0.6))
  end
  local px, py = video_pan(path)
  if px .. "," .. py ~= cur_pan then
    cur_pan = px .. "," .. py
    reaper.AUBG_SetPan(px, py)
  end
end

-- Re-applies our colours after the theme changed under us: a reload drops our
-- overrides (start over from the new colours), a tweak in place (theme
-- adjuster) is captured by restoring ours first and snapshotting again.
local function check_theme()
  if not enabled then return end
  local reloaded = reaper.GetLastColorThemeFile() ~= theme_file
  if not reloaded and reaper.GetThemeColor("col_tr1_bg", 0) == key_native then return end
  modes_cache.modes = nil
  if reloaded then saved = nil else restore_theme() end
  snapshot_theme()
  reaper.AUBG_SetKey(key_rgb, 0)
  apply_theme()
end

local last_settings = ""
local function settings_signature()
  return table.concat({ reaper.GetExtState(SECTION, "default_video"), reaper.GetExtState(SECTION, "opacity"),
                        reaper.GetExtState(SECTION, "shading"), reaper.GetExtState(SECTION, "grid"),
                        reaper.GetExtState(SECTION, "near_tol") }, "|")
end

local function engine_tick(now)
  local proj = reaper.EnumProjects(-1)
  if proj ~= cur_proj then
    cur_proj = proj
    refresh(proj)
    last_check = now
  elseif now - last_check >= CHECK_INTERVAL or (not enabled and not gave_up) then
    last_check = now
    check_theme()
    local sig = settings_signature()
    local keys_changed = sig ~= last_settings and last_settings ~= ""
    last_settings = sig
    refresh(proj)
    if keys_changed and enabled then
      register_keys()
      reaper.AUBG_SetOpacity(setting("opacity", 0.6))
    end
  end

  if enabled and cur_path then
    local rate = reaper.Master_GetPlayRate(proj)
    if rate ~= cur_rate then cur_rate = rate; reaper.AUBG_SetRate(rate) end
    local playing = (reaper.GetPlayState() & 1) == 1
    local pos = playing and reaper.GetPlayPosition() or reaper.GetCursorPosition()
    if is_image(cur_path) then
      reaper.AUBG_Sync(0, 0, pos >= 0 and 1 or 0)
    else
      local dur = reaper.AUBG_GetDuration()
      local stop = (cur_out > 0 and (dur <= 0 or cur_out < dur)) and cur_out or dur
      local span = stop - cur_in
      local t = cur_in + ((cur_loop and span > 0) and pos % span or pos)
      local visible = pos >= 0 and (stop <= 0 or t < stop)
      reaper.AUBG_Sync(t, playing and 1 or 0, visible and 1 or 0)
    end
  end
end

local function start_background()
  bg_on, gave_up, start_time = true, false, reaper.time_precise()
end
local function stop_background()
  bg_on = false
  disable()
end

---------------------------------------------------------------------------
-- Settings window: a fixed 520x640 under a native title bar, split by the
-- golden ratio (preview above, video grid below, then the footer). Heights
-- are budgeted from the available area so only the video grid ever scrolls.
---------------------------------------------------------------------------
local ImGui, ctx = nil, nil
local font, font_s = nil, nil
local library = {}
-- The file being imported: picked (picking/src/image/duration/in_sec/out_sec),
-- then converting (dst_name) until the transcode finishes or fails (error).
local import = { picking = false, src = "", image = false, name = "", duration = 0, in_sec = 0, out_sec = 0,
                 dst_name = nil, error = nil, img = nil }
local delete_target = nil
local preview = { path = nil, dur = 0, time = nil, want = nil, img = nil, last = 0 }
local tl = { drag = nil, tin = 0, tout = 0 }
local thumb_budget = 0

local PHI = (1 + math.sqrt(5)) / 2
local W, H, PAD = 520, 640, 21   -- PAD: window edges, grid gutter, and between sections
local TITLE_H, ICON, TL_H = 34, 30, 22
local THUMB_DIR = LIB_DIR .. ".thumbs/"

-- Frames sit well above the window background so controls read as controls;
-- slider tracks sit between the two.
local UI = {
  bg = 0x16181CFF, card = 0x1D2026FF, frame = 0x333943FF, frame_hover = 0x414853FF, line = 0x2F343DFF, track = 0x23272EFF,
  text = 0xECEEF1FF, muted = 0x8B939FFF, faint = 0x565D68FF, scrim = 0x16181CB8, chip = 0x16181CCC,
  accent = 0xFE3C60FF, accent_hover = 0xFF5F7DFF, accent_dim = 0xFE3C6033, on_accent = 0x16181CFF,
  danger = 0xF07178FF,
}

local function load_imgui()
  if ImGui then return true end
  if not reaper.ImGui_GetBuiltinPath then
    reaper.MB("The settings window needs ReaImGui 0.9 or newer (install/update via ReaPack).", "ReaBackground", 0)
    if reaper.ReaPack_BrowsePackages then reaper.ReaPack_BrowsePackages("ReaImGui") end
    return false
  end
  package.path = reaper.ImGui_GetBuiltinPath() .. "/?.lua;" .. package.path
  ImGui = require "imgui" "0.9"
  return true
end

local function push_style()
  local vars = {
    { ImGui.StyleVar_WindowPadding, PAD, PAD }, { ImGui.StyleVar_FramePadding, 13, 8 },
    { ImGui.StyleVar_ItemSpacing, 8, 8 },       { ImGui.StyleVar_ItemInnerSpacing, 8, 8 },
    { ImGui.StyleVar_FrameRounding, 8 },        { ImGui.StyleVar_ChildRounding, 13 },
    { ImGui.StyleVar_PopupRounding, 13 },       { ImGui.StyleVar_GrabRounding, 8 },
    { ImGui.StyleVar_GrabMinSize, 13 },         { ImGui.StyleVar_ScrollbarSize, 5 },
    { ImGui.StyleVar_ScrollbarRounding, 5 },    { ImGui.StyleVar_WindowBorderSize, 0 },
    { ImGui.StyleVar_ChildBorderSize, 0 },      { ImGui.StyleVar_FrameBorderSize, 0 },
    { ImGui.StyleVar_PopupBorderSize, 0 },      { ImGui.StyleVar_WindowRounding, 0 },
  }
  for _, v in ipairs(vars) do ImGui.PushStyleVar(ctx, v[1], v[2], v[3]) end
  local cols = {
    { ImGui.Col_WindowBg, UI.bg }, { ImGui.Col_ChildBg, UI.card }, { ImGui.Col_PopupBg, UI.card }, { ImGui.Col_Border, UI.line },
    { ImGui.Col_Text, UI.text }, { ImGui.Col_TextDisabled, UI.muted },
    { ImGui.Col_TitleBg, UI.bg }, { ImGui.Col_TitleBgActive, UI.bg }, { ImGui.Col_ModalWindowDimBg, 0x00000099 },
    { ImGui.Col_FrameBg, UI.frame }, { ImGui.Col_FrameBgHovered, UI.frame_hover }, { ImGui.Col_FrameBgActive, UI.frame_hover },
    { ImGui.Col_Button, UI.frame }, { ImGui.Col_ButtonHovered, UI.frame_hover }, { ImGui.Col_ButtonActive, UI.line },
    { ImGui.Col_Header, UI.accent_dim }, { ImGui.Col_HeaderHovered, UI.frame_hover }, { ImGui.Col_HeaderActive, UI.frame_hover },
    { ImGui.Col_SliderGrab, UI.accent }, { ImGui.Col_SliderGrabActive, UI.accent_hover },
    { ImGui.Col_CheckMark, UI.accent }, { ImGui.Col_PlotHistogram, UI.accent },
    { ImGui.Col_Separator, UI.line }, { ImGui.Col_ScrollbarBg, 0x00000000 }, { ImGui.Col_ScrollbarGrab, UI.faint },
    { ImGui.Col_ScrollbarGrabHovered, UI.muted }, { ImGui.Col_ScrollbarGrabActive, UI.muted },
  }
  for _, c in ipairs(cols) do ImGui.PushStyleColor(ctx, c[1], c[2]) end
  return #vars, #cols
end

local function label_text(text)
  ImGui.PushFont(ctx, font_s)
  ImGui.PushStyleColor(ctx, ImGui.Col_Text, UI.muted)
  ImGui.Text(ctx, text:upper())
  ImGui.PopStyleColor(ctx)
  ImGui.PopFont(ctx)
end
local function label(text)
  label_text(text)
  ImGui.Dummy(ctx, 0, 5)
end
local function tip(text)
  ImGui.PushStyleColor(ctx, ImGui.Col_PopupBg, 0x000000FF)
  ImGui.SetTooltip(ctx, text)
  ImGui.PopStyleColor(ctx)
end

local function solid_button(text, w, h, color)
  ImGui.PushStyleColor(ctx, ImGui.Col_Button, color or UI.accent)
  ImGui.PushStyleColor(ctx, ImGui.Col_ButtonHovered, color or UI.accent_hover)
  ImGui.PushStyleColor(ctx, ImGui.Col_ButtonActive, color or UI.accent)
  ImGui.PushStyleColor(ctx, ImGui.Col_Text, UI.on_accent)
  local r = ImGui.Button(ctx, text, w or 0, h or 0)
  ImGui.PopStyleColor(ctx, 4)
  return r
end

local function fmt_time(s)
  if not s or s <= 0 then return "-:--" end
  return string.format("%d:%02d", math.floor(s / 60), math.floor(s % 60))
end
local function fmt_time_frac(s)
  return string.format("%d:%04.1f", math.floor(s / 60), s % 60)
end
local function clamp(v, lo, hi) return math.max(lo, math.min(hi, v)) end

---------------------------------------------------------------------------
-- Vector icons (no icon font needed)
---------------------------------------------------------------------------
local function draw_globe(dl, cx, cy, r, col, th)
  ImGui.DrawList_AddCircle(dl, cx, cy, r, col, 0, th)
  ImGui.DrawList_AddLine(dl, cx - r, cy, cx + r, cy, col, th)
  local k = r * 0.56
  ImGui.DrawList_AddBezierCubic(dl, cx, cy - r, cx + k, cy - r, cx + k, cy + r, cx, cy + r, col, th, 0)
  ImGui.DrawList_AddBezierCubic(dl, cx, cy - r, cx - k, cy - r, cx - k, cy + r, cx, cy + r, col, th, 0)
end
local function draw_trash(dl, cx, cy, r, col, th)
  ImGui.DrawList_AddLine(dl, cx - r, cy - r * 0.5, cx + r, cy - r * 0.5, col, th)
  ImGui.DrawList_AddRect(dl, cx - r * 0.3, cy - r * 0.85, cx + r * 0.3, cy - r * 0.5, col, 1, 0, th)
  ImGui.DrawList_AddRect(dl, cx - r * 0.7, cy - r * 0.5, cx + r * 0.7, cy + r, col, 2, 0, th)
  ImGui.DrawList_AddLine(dl, cx - r * 0.25, cy - r * 0.15, cx - r * 0.25, cy + r * 0.65, col, th)
  ImGui.DrawList_AddLine(dl, cx + r * 0.25, cy - r * 0.15, cx + r * 0.25, cy + r * 0.65, col, th)
end
local ICONS = { globe = draw_globe, trash = draw_trash }

-- Round icon in one of three states: resting (chip, plain icon), active
-- (chip, icon in `color`), hovered (filled with `color`).
local function draw_icon(dl, kind, color, cx, cy, active, hov)
  ImGui.DrawList_AddCircleFilled(dl, cx, cy, ICON / 2, hov and color or UI.chip)
  ICONS[kind](dl, cx, cy, ICON * 0.23, hov and UI.on_accent or active and color or UI.text, 1.5)
end

local function icon_button(id, kind, color, active, tip_text)
  local x, y = ImGui.GetCursorScreenPos(ctx)
  local clicked = ImGui.InvisibleButton(ctx, id, ICON, ICON)
  local hov = ImGui.IsItemHovered(ctx)
  draw_icon(ImGui.GetWindowDrawList(ctx), kind, color, x + ICON / 2, y + ICON / 2, active, hov)
  if hov then tip(tip_text) end
  return clicked
end

local function load_image(path)
  local ok, img = pcall(ImGui.CreateImage, path)
  if not ok or not img then return nil end
  ImGui.Attach(ctx, img)
  return img
end

-- Draws an image letterboxed into a rounded rect (placeholder when nil) and
-- returns the rect the image occupies.
local function image_fit(dl, img, x0, y0, x1, y1, rounding)
  ImGui.DrawList_AddRectFilled(dl, x0, y0, x1, y1, UI.frame, rounding)
  if not img then return end
  local iw, ih = ImGui.Image_GetSize(img)
  local w, h = x1 - x0, y1 - y0
  local s = math.min(w / iw, h / ih)
  local dw, dh = iw * s, ih * s
  local ox, oy = x0 + (w - dw) / 2, y0 + (h - dh) / 2
  ImGui.DrawList_AddImageRounded(dl, img, ox, oy, ox + dw, oy + dh, 0, 0, 1, 1, 0xFFFFFFFF, rounding)
  return ox, oy, ox + dw, oy + dh
end

-- Dims the parts of the preview that aspect-fill crops away in an arrange of
-- the current size; dragging inside the visible window slides it along the
-- cropped axis (live, saved to the project on release).
local pan_drag = nil
local function crop_overlay(dl, path, x0, y0, x1, y1)
  if not x0 or not path then return end
  local vw, vh = reaper.AUBG_ViewSize():match("^(%d+),(%d+)$")
  if not vw or tonumber(vw) == 0 or tonumber(vh) == 0 then return end
  local w, h = x1 - x0, y1 - y0
  local vis_w, vis_h = w, h
  if vw / vh > w / h then vis_h = w * vh / vw else vis_w = h * vw / vh end
  local cx, cy = (w - vis_w) / 2, (h - vis_h) / 2
  if cx < 1 and cy < 1 then return end
  local horizontal = cx >= 1
  local px, py = video_pan(path)
  if pan_drag then px, py = pan_drag.x, pan_drag.y end
  local wx, wy = x0 + cx * (1 + px), y0 + cy * (1 + py)

  ImGui.SetCursorScreenPos(ctx, wx, wy)
  ImGui.InvisibleButton(ctx, "##pan", vis_w, vis_h)
  if ImGui.IsItemActivated(ctx) then pan_drag = { x = px, y = py } end
  if ImGui.IsItemActive(ctx) and pan_drag then
    local dx, dy = ImGui.GetMouseDelta(ctx)
    if horizontal then pan_drag.x = clamp(pan_drag.x + dx / cx, -1, 1) else pan_drag.y = clamp(pan_drag.y + dy / cy, -1, 1) end
    reaper.AUBG_SetPan(pan_drag.x, pan_drag.y)
    px, py = pan_drag.x, pan_drag.y
    wx, wy = x0 + cx * (1 + px), y0 + cy * (1 + py)
  end
  if ImGui.IsItemDeactivated(ctx) and pan_drag then
    set_video_pan(path, pan_drag.x, pan_drag.y)
    pan_drag = nil
  end
  if ImGui.IsItemHovered(ctx) or ImGui.IsItemActive(ctx) then
    ImGui.SetMouseCursor(ctx, horizontal and ImGui.MouseCursor_ResizeEW or ImGui.MouseCursor_ResizeNS)
    if not pan_drag then tip("Drag to choose which part shows; dimmed areas are cropped at the arrange's current size") end
  end

  local shade = 0x000000A0
  if horizontal then
    ImGui.DrawList_AddRectFilled(dl, x0, y0, wx, y1, shade)
    ImGui.DrawList_AddRectFilled(dl, wx + vis_w, y0, x1, y1, shade)
  else
    ImGui.DrawList_AddRectFilled(dl, x0, y0, x1, wy, shade)
    ImGui.DrawList_AddRectFilled(dl, x0, wy + vis_h, x1, y1, shade)
  end
  ImGui.DrawList_AddRect(dl, wx, wy, wx + vis_w, wy + vis_h, 0xFFFFFF90, 0, 0, 1)
end

-- Loads a library entry's thumbnail, generating it (one per frame) on first sight.
local function ensure_thumb(v)
  if v.img or v.failed then return end
  if not reaper.file_exists(v.thumb) then
    if thumb_budget <= 0 then return end
    thumb_budget = thumb_budget - 1
    if reaper.AUBG_Frame(v.path, v.thumb, -1, 352, 198) ~= 1 then v.failed = true return end
  end
  v.img = load_image(v.thumb)
  if not v.img then v.failed = true end
end

local function refresh_library()
  library = {}
  reaper.RecursiveCreateDirectory(THUMB_DIR, 0)
  reaper.EnumerateFiles(LIB_DIR, -1)   -- drop REAPER's cached listing
  local i = 0
  while true do
    local f = reaper.EnumerateFiles(LIB_DIR, i)
    if not f then break end
    local name, ext = f:match("^(.+)%.([^.]+)$")
    local kind = name and MEDIA_EXT[ext]
    if kind and not name:match("%.part$") then
      library[#library + 1] = { name = name, path = LIB_DIR .. f, kind = kind, thumb = THUMB_DIR .. name .. ".jpg",
                                duration = kind == "video" and reaper.AUBG_ProbeDuration(LIB_DIR .. f) or 0 }
    end
    i = i + 1
  end
  table.sort(library, function(a, b) return a.name:lower() < b.name:lower() end)
end
local function library_entry(path)
  for _, v in ipairs(library) do if v.path == path then return v end end
end

local function sanitize(name)
  name = name:gsub("[^%w_%-]", "_"):gsub("^_+", ""):gsub("_+$", ""):sub(1, 64)
  return name ~= "" and name or "video"
end
local function unique_name(name)
  local candidate, n = name, 1
  while lib_path(candidate) do
    n = n + 1
    candidate = name .. "-" .. n
  end
  return candidate
end

-- The file chooser is a modeless panel owned by the extension (a modal dialog
-- would stall other scripts' defer loops and ReaImGui would drop their
-- contexts); poll_picker picks up its result each frame.
local function poll_picker()
  if not import.picking then return end
  local state = reaper.AUBG_PickState()
  if state == 1 then return end
  import.picking = false
  if state ~= 2 then return end
  local file = reaper.AUBG_PickedPath()
  import.src = file
  import.image = reaper.AUBG_IsImage(file) == 1
  import.duration = import.image and 0 or reaper.AUBG_ProbeDuration(file)
  import.name = sanitize((file:match("([^/\\]+)$") or "video"):gsub("%.[^.]+$", ""))
  import.in_sec, import.out_sec, import.error = 0, import.duration, nil
  if import.img then ImGui.Detach(ctx, import.img) end
  import.img = reaper.AUBG_Frame(file, THUMB_DIR .. "import.jpg", -1, 704, 396) == 1 and load_image(THUMB_DIR .. "import.jpg") or nil
  ImGui.OpenPopup(ctx, "Import")
end

local function start_import()
  local name = unique_name(sanitize(import.name))
  if import.image then
    if reaper.AUBG_ImportImage(import.src, LIB_DIR .. name) ~= "" then
      import.src, import.error = "", nil
      refresh_library()
    else
      import.error = "could not read the image"
    end
    return
  end
  local tin = import.in_sec > 0.05 and import.in_sec or 0
  local tout = import.out_sec < import.duration - 0.05 and import.out_sec or 0
  local rv = reaper.AUBG_TranscodeStart(import.src, LIB_DIR .. name .. ".mp4", tin, tout)
  if rv == 1 then
    import.dst_name, import.error, import.src = name, nil, ""
  else
    import.error = ({ [-1] = "could not read the file", [-2] = "another import is running", [-3] = "a video with that name exists", [-4] = "unsupported source" })[rv] or tostring(rv)
  end
end

---------------------------------------------------------------------------
-- Sections
---------------------------------------------------------------------------
-- Seconds field: a plain number with the unit beside it, clamped on commit.
local function seconds_input(id, caption, value, w, lo, hi)
  local x, y = ImGui.GetCursorScreenPos(ctx)
  ImGui.DrawList_AddTextEx(ImGui.GetWindowDrawList(ctx), font_s, 12, x, y, UI.muted, caption)
  ImGui.Dummy(ctx, w, 14)
  ImGui.SetNextItemWidth(ctx, w - 18)
  local rv, v = ImGui.InputDouble(ctx, id, value, 0, 0, "%.1f")
  if ImGui.IsItemDeactivatedAfterEdit(ctx) then v = clamp(v, lo, hi); rv = true end
  ImGui.SameLine(ctx, 0, 5)
  ImGui.TextColored(ctx, UI.muted, "s")
  return rv and v or value
end

-- Preview plus, for a video, its duration and the range to keep.
local function draw_import_popup(pw)
  ImGui.SetNextWindowSize(ctx, pw, 0)
  if not ImGui.BeginPopupModal(ctx, "Import", nil, ImGui.WindowFlags_NoTitleBar | ImGui.WindowFlags_NoResize) then return end
  local w = pw - 2 * PAD
  local h, under = math.floor(w * 9 / 16), 26
  local x, y = ImGui.GetCursorScreenPos(ctx)
  local dl = ImGui.GetWindowDrawList(ctx)
  image_fit(dl, import.img, x, y, x + w, y + h, 8)
  local half = (w - 13) / 2
  if import.image then
    ImGui.Dummy(ctx, w, h)
  else
    local dur = fmt_time(import.duration)
    ImGui.PushFont(ctx, font_s)
    local dw = ImGui.CalcTextSize(ctx, dur)
    ImGui.PopFont(ctx)
    ImGui.DrawList_AddTextEx(dl, font_s, 12, x + (w - dw) / 2, y + h + (under - 12) / 2 + 1, UI.muted, dur)
    ImGui.Dummy(ctx, w, h + under)
    ImGui.Dummy(ctx, 0, 8)

    local d = import.duration
    ImGui.BeginGroup(ctx)
    import.in_sec = seconds_input("##in", "START", import.in_sec, half, 0, math.max(0, math.min(import.out_sec, d) - 0.1))
    ImGui.EndGroup(ctx)
    ImGui.SameLine(ctx, 0, 13)
    ImGui.BeginGroup(ctx)
    import.out_sec = seconds_input("##out", "END", import.out_sec, half, math.min(import.in_sec + 0.1, d), d)
    ImGui.EndGroup(ctx)
  end
  ImGui.Dummy(ctx, 0, 21)
  if solid_button("Import", half, TITLE_H) then start_import(); ImGui.CloseCurrentPopup(ctx) end
  ImGui.SameLine(ctx, 0, 13)
  if ImGui.Button(ctx, "Cancel", half, TITLE_H) then import.src = ""; ImGui.CloseCurrentPopup(ctx) end
  ImGui.EndPopup(ctx)
end

local function draw_delete_popup(pw, default, proj_video)
  if delete_target then ImGui.OpenPopup(ctx, "Delete video") end
  ImGui.SetNextWindowSize(ctx, pw, 0)
  if not ImGui.BeginPopupModal(ctx, "Delete video", nil, ImGui.WindowFlags_NoTitleBar | ImGui.WindowFlags_NoResize) then return end
  label("Delete")
  ImGui.TextWrapped(ctx, "Remove this background from the library? Projects using it fall back to the default.")
  ImGui.Dummy(ctx, 0, 13)
  local half = (pw - 2 * PAD - 8) / 2
  if solid_button("Delete", half, TITLE_H, UI.danger) then
    local path = lib_path(delete_target)
    if path then os.remove(path) end
    os.remove(THUMB_DIR .. delete_target .. ".jpg")
    reaper.DeleteExtState(SECTION, "pan:" .. delete_target, true)
    if default == delete_target then set_setting("default_video", "") end
    if proj_video == delete_target then proj_set("video", "") end
    delete_target = nil
    refresh_library()
    ImGui.CloseCurrentPopup(ctx)
  end
  ImGui.SameLine(ctx)
  if ImGui.Button(ctx, "Cancel", half, TITLE_H) then delete_target = nil; ImGui.CloseCurrentPopup(ctx) end
  ImGui.EndPopup(ctx)
end

-- "+" tile at the end of the grid: import, with progress while converting.
local function draw_add_tile(dl, x, y, x1, y1, status)
  ImGui.SetCursorScreenPos(ctx, x, y)
  local clicked = ImGui.InvisibleButton(ctx, "##add", x1 - x, y1 - y)
  local hov = ImGui.IsItemHovered(ctx)
  local col = import.error and UI.danger or (hov and UI.accent or UI.faint)
  ImGui.DrawList_AddRect(dl, x + 0.5, y + 0.5, x1 - 0.5, y1 - 0.5, col, 8, 0, 1)
  local cx, cy = (x + x1) / 2, (y + y1) / 2
  if status == 1 then
    local w = (x1 - x) / PHI
    ImGui.DrawList_AddRectFilled(dl, cx - w / 2, cy - 2, cx + w / 2, cy + 2, UI.track, 2)
    ImGui.DrawList_AddRectFilled(dl, cx - w / 2, cy - 2, cx - w / 2 + w * reaper.AUBG_TranscodeProgress(), cy + 2, UI.accent, 2)
    if hov then tip("Converting... click to cancel") end
    if clicked then reaper.AUBG_TranscodeCancel() end
  else
    ImGui.DrawList_AddLine(dl, cx - 8, cy, cx + 8, cy, col, 2)
    ImGui.DrawList_AddLine(dl, cx, cy - 8, cx, cy + 8, col, 2)
    if hov then tip(import.error and ("Import failed: " .. import.error) or "Import a video or image") end
    if clicked then
      import.error = nil
      if reaper.AUBG_PickFile("Choose a video or image to import") == 1 then import.picking = true end
    end
  end
end

-- Three cells per row with the same gutter between cells and to the walls.
local function draw_grid(width, default, proj_video, status)
  local cols, under, g = 3, 26, PAD
  local cw = math.floor((width - (cols + 1) * g) / cols)
  local img_h = math.floor(cw * 9 / 16)
  local cell_h = img_h + under

  local ox, oy = ImGui.GetCursorScreenPos(ctx)
  local x0, y0 = ox + g, oy + g
  local dl = ImGui.GetWindowDrawList(ctx)
  local count = #library + 1
  local rows = math.ceil(count / cols)
  local function cell(i)
    local c, r = (i - 1) % cols, (i - 1) // cols
    local x, y = x0 + c * (cw + g), y0 + r * (cell_h + g)
    return x, y, x + cw, y + img_h
  end
  for i, v in ipairs(library) do
    ensure_thumb(v)
    local x, y, x1, y1 = cell(i)
    ImGui.PushID(ctx, v.name)
    image_fit(dl, v.img, x, y, x1, y1, 8)

    -- The thumbnail itself picks (or unpicks) the background for this project.
    local is_default, is_proj = v.name == default, v.name == proj_video
    local in_use = is_proj or (proj_video == "" and is_default)
    ImGui.SetCursorScreenPos(ctx, x, y)
    ImGui.SetNextItemAllowOverlap(ctx)   -- else the icon buttons drawn over it never get the click
    if ImGui.InvisibleButton(ctx, "##pick", cw, img_h) then proj_set("video", is_proj and "" or v.name) end
    local hover = ImGui.IsMouseHoveringRect(ctx, x, y, x1, y1 + under) and not ImGui.IsPopupOpen(ctx, "", ImGui.PopupFlags_AnyPopupId)
    if in_use or hover then
      ImGui.DrawList_AddRect(dl, x - 3, y - 3, x1 + 3, y1 + 3, in_use and UI.accent or (UI.accent & 0xFFFFFF00 | 0x80), 10, 0, 2)
    end
    if ImGui.IsItemHovered(ctx) then
      tip(is_proj and "Used in this project (click to clear)" or in_use and "Used here as the global default (click to pin to this project)" or "Use in this project")
    end

    local dur = v.kind == "image" and "image" or fmt_time(v.duration)
    ImGui.PushFont(ctx, font_s)
    local dw = ImGui.CalcTextSize(ctx, dur)
    ImGui.PopFont(ctx)
    ImGui.DrawList_AddTextEx(dl, font_s, 12, x + (cw - dw) / 2, y1 + (under - 12) / 2 + 1, UI.muted, dur)
    if hover then
      ImGui.SetCursorScreenPos(ctx, x + 6, y1 - 6 - ICON)
      if icon_button("##default", "globe", UI.accent, is_default, is_default and "Global default (click to clear)" or "Use everywhere (global default)") then
        set_setting("default_video", is_default and "" or v.name)
      end
      ImGui.SetCursorScreenPos(ctx, x1 - 6 - ICON, y1 - 6 - ICON)
      if icon_button("##delete", "trash", UI.danger, false, "Delete from library") then delete_target = v.name end
    elseif is_default then
      draw_icon(dl, "globe", UI.accent, x + 6 + ICON / 2, y1 - 6 - ICON / 2, true, false)
    end
    ImGui.PopID(ctx)
  end
  local x, y, x1, y1 = cell(count)
  draw_add_tile(dl, x, y, x1, y1, status)
  ImGui.SetCursorScreenPos(ctx, ox, oy)
  ImGui.Dummy(ctx, width, rows * cell_h + (rows + 1) * g)
end

local function draw_videos(top_h, aw)
  local default = reaper.GetExtState(SECTION, "default_video")
  local proj_video = proj_get("video")
  local status = reaper.AUBG_TranscodeStatus()
  if import.dst_name and status ~= 1 then
    -- A transcode we started has finished (or failed) since the last frame.
    if status == 2 then refresh_library() elseif status == -1 then import.error = reaper.AUBG_TranscodeError() end
    import.dst_name = nil
  end

  -- Full-bleed: the child starts at the window's left edge, outside the padding.
  ImGui.SetCursorPosX(ctx, 0)
  ImGui.PushStyleVar(ctx, ImGui.StyleVar_WindowPadding, 0, 0)
  ImGui.PushStyleVar(ctx, ImGui.StyleVar_ChildRounding, 0)
  local open = ImGui.BeginChild(ctx, "videos", ImGui.GetWindowWidth(ctx), top_h, ImGui.ChildFlags_None)
  ImGui.PopStyleVar(ctx, 2)
  if not open then return end
  draw_grid(ImGui.GetContentRegionAvail(ctx), default, proj_video, status)
  local pw = math.floor(aw / PHI)
  poll_picker()
  draw_import_popup(pw)
  draw_delete_popup(pw, default, proj_video)
  ImGui.EndChild(ctx)
end

-- In/out range with a scrub cursor. Returns tin, tout, cur, changed, released.
local function timeline(dur, tin, tout, cur, w)
  local x, y = ImGui.GetCursorScreenPos(ctx)
  ImGui.InvisibleButton(ctx, "##timeline", w, TL_H)
  local dl = ImGui.GetWindowDrawList(ctx)
  local m = 7
  local function px(t) return x + m + (t / dur) * (w - 2 * m) end
  local function tt(p) return clamp((p - x - m) / (w - 2 * m) * dur, 0, dur) end
  local changed, released = false, false
  local mx = ImGui.GetMousePos(ctx)
  if ImGui.IsItemActivated(ctx) then
    local din, dout = math.abs(mx - px(tin)), math.abs(mx - px(tout))
    tl.drag = (din <= 9 and din <= dout) and "in" or (dout <= 9 and "out") or "cur"
  end
  if ImGui.IsItemActive(ctx) and tl.drag then
    local t = tt(mx)
    if tl.drag == "in" then tin = math.min(t, tout - 0.1); cur = tin
    elseif tl.drag == "out" then tout = math.max(t, tin + 0.1); cur = tout
    else cur = clamp(t, tin, tout) end
    changed = true
    tip((tl.drag == "in" and "from " or tl.drag == "out" and "to " or "") .. fmt_time_frac(cur))
  elseif ImGui.IsItemHovered(ctx) then
    tip(fmt_time_frac(tin) .. "  -  " .. fmt_time_frac(tout))
  end
  if ImGui.IsItemDeactivated(ctx) then released, tl.drag = true, nil end

  local cy = y + TL_H / 2
  ImGui.DrawList_AddRectFilled(dl, x + m, cy - 2, x + w - m, cy + 2, UI.track, 2)
  ImGui.DrawList_AddRectFilled(dl, px(tin), cy - 2, px(tout), cy + 2, UI.accent, 2)
  for _, t in ipairs({ tin, tout }) do
    ImGui.DrawList_AddRectFilled(dl, px(t) - 3, cy - 9, px(t) + 3, cy + 9, UI.accent, 3)
  end
  local cx = px(cur)
  ImGui.DrawList_AddLine(dl, cx, y + 4, cx, y + TL_H - 4, UI.text, 2)
  ImGui.DrawList_AddTriangleFilled(dl, cx - 5, y, cx + 5, y, cx, y + 5, UI.text)
  return tin, tout, cur, changed, released
end

local drag = {}
-- Slider drawn as a bar filled up to the value: the track and fill go in
-- first, the widget itself is invisible, and the label is drawn on top in two
-- clipped halves so it stays readable over both the fill and the track.
local function percent_slider(id, key, default, fmt, w, on_change, on_release)
  local x, y = ImGui.GetCursorScreenPos(ctx)
  local h = ImGui.GetFrameHeight(ctx)
  local dl = ImGui.GetWindowDrawList(ctx)
  local cur = drag[key] or setting(key, default) * 100
  local fill_x = x + math.floor(w * cur / 100 + 0.5)
  local hovered = ImGui.IsMouseHoveringRect(ctx, x, y, x + w, y + h)
  ImGui.DrawList_AddRectFilled(dl, x, y, x + w, y + h, hovered and UI.frame or UI.track, 8)
  ImGui.DrawList_PushClipRect(dl, x, y, fill_x, y + h, true)
  ImGui.DrawList_AddRectFilled(dl, x, y, x + w, y + h, hovered and UI.accent_hover or UI.accent, 8)
  ImGui.DrawList_PopClipRect(dl)

  ImGui.PushStyleColor(ctx, ImGui.Col_FrameBg, 0)
  ImGui.PushStyleColor(ctx, ImGui.Col_FrameBgHovered, 0)
  ImGui.PushStyleColor(ctx, ImGui.Col_FrameBgActive, 0)
  ImGui.PushStyleColor(ctx, ImGui.Col_SliderGrab, 0)
  ImGui.PushStyleColor(ctx, ImGui.Col_SliderGrabActive, 0)
  ImGui.SetNextItemWidth(ctx, w)
  local rv, v = ImGui.SliderDouble(ctx, id, cur, 0, 100, "")
  ImGui.PopStyleColor(ctx, 5)

  local label = string.format(fmt, rv and v or cur)
  local tw, th = ImGui.CalcTextSize(ctx, label)
  local tx, ty = x + math.floor((w - tw) / 2), y + math.floor((h - th) / 2)
  ImGui.DrawList_PushClipRect(dl, x, y, fill_x, y + h, true)
  ImGui.DrawList_AddText(dl, tx, ty, UI.on_accent, label)
  ImGui.DrawList_PopClipRect(dl)
  ImGui.DrawList_PushClipRect(dl, fill_x, y, x + w, y + h, true)
  ImGui.DrawList_AddText(dl, tx, ty, UI.text, label)
  ImGui.DrawList_PopClipRect(dl)
  if rv then
    drag[key] = v
    if on_change then on_change(v / 100) end
  end
  if ImGui.IsItemDeactivatedAfterEdit(ctx) and drag[key] then
    set_setting(key, string.format("%.2f", drag[key] / 100))
    drag[key] = nil
    if on_release then on_release() end
    last_settings = settings_signature()   -- already applied; keep engine_tick from applying it again
  end
end

-- A pill-shaped toggle in the sliders' style, told apart from them by its
-- white outline. Filled with the accent when on.
local function toggle_button(id, label, on, w, disabled)
  local x, y = ImGui.GetCursorScreenPos(ctx)
  local h = ImGui.GetFrameHeight(ctx)
  local dl = ImGui.GetWindowDrawList(ctx)
  ImGui.BeginDisabled(ctx, disabled)
  local clicked = ImGui.InvisibleButton(ctx, id, w, h)
  ImGui.EndDisabled(ctx)
  local hovered = not disabled and ImGui.IsItemHovered(ctx)
  local fill = on and (hovered and UI.accent_hover or UI.accent) or (hovered and UI.frame or UI.track)
  local outline = disabled and UI.faint or UI.text
  ImGui.DrawList_AddRectFilled(dl, x, y, x + w, y + h, fill, 8)
  ImGui.DrawList_AddRect(dl, x + 0.5, y + 0.5, x + w - 0.5, y + h - 0.5, outline, 8, 0, 1.5)
  local tw, th = ImGui.CalcTextSize(ctx, label)
  local color = disabled and UI.faint or (on and UI.on_accent or UI.text)
  ImGui.DrawList_AddText(dl, x + math.floor((w - tw) / 2), y + math.floor((h - th) / 2), color, label)
  return clicked
end

local function draw_project(width, height, now)
  ImGui.PushStyleColor(ctx, ImGui.Col_ChildBg, 0)
  local open = ImGui.BeginChild(ctx, "project", width, height, ImGui.ChildFlags_None, ImGui.WindowFlags_NoScrollbar | ImGui.WindowFlags_NoScrollWithMouse)
  ImGui.PopStyleColor(ctx)
  if not open then return end
  local inner_w, inner_h = width, height
  local path, tin, tout, loop = resolve(0)
  local image = is_image(path)
  ImGui.PushStyleVar(ctx, ImGui.StyleVar_FramePadding, 13, 5)
  local ROW_H = ImGui.GetFrameHeight(ctx)   -- checkbox and slider height
  -- An image has no timeline, so the preview takes its space.
  local below = image and (8 + ROW_H) or (8 + TL_H + 8 + ROW_H)

  local pv_h = math.min(math.floor(inner_w * 9 / 16), inner_h - below)
  local pv_w = math.min(inner_w, math.floor(pv_h * 16 / 9))
  ImGui.SetCursorPosY(ctx, ImGui.GetCursorPosY(ctx) + math.max(0, math.floor((inner_h - pv_h - below) / 2)))
  local x, y = ImGui.GetCursorScreenPos(ctx)
  x = x + math.floor((inner_w - pv_w) / 2)
  local dl = ImGui.GetWindowDrawList(ctx)

  -- Preview frame, regenerated (throttled) when the media or scrub time changes.
  if path ~= preview.path then
    local entry = library_entry(path)
    preview.path, preview.img, preview.time = path, nil, nil
    preview.dur = (path and not image) and ((entry and entry.duration > 0) and entry.duration or reaper.AUBG_ProbeDuration(path)) or 0
    preview.want = nil
  end
  local dur = preview.dur
  if path and dur > 0 then
    tin = clamp(tin, 0, dur)
    tout = (tout > 0 and tout < dur) and tout or dur
    if tout <= tin then tin, tout = 0, dur end
    if not preview.want then preview.want = (tin + tout) / 2 end
  elseif image then
    preview.want = 0
  end
  if path and preview.want and preview.want ~= preview.time and now - preview.last > 0.08 then
    if reaper.AUBG_Frame(path, THUMB_DIR .. "preview.jpg", preview.want, pv_w * 2, pv_h * 2) == 1 then
      if preview.img then ImGui.Detach(ctx, preview.img) end
      preview.img = load_image(THUMB_DIR .. "preview.jpg")
    end
    preview.time, preview.last = preview.want, now
  end
  local ix0, iy0, ix1, iy1 = image_fit(dl, preview.img, x, y, x + pv_w, y + pv_h, 8)
  ImGui.SetCursorScreenPos(ctx, x, y)
  ImGui.Dummy(ctx, pv_w, pv_h)
  crop_overlay(dl, path, ix0, iy0, ix1, iy1)

  if not image then
    ImGui.SetCursorScreenPos(ctx, x, y + pv_h + 8)
    if path and dur > 0 then
      if not tl.drag then tl.tin, tl.tout = tin, tout end
      local cur, changed, released
      tl.tin, tl.tout, cur, changed, released = timeline(dur, tl.tin, tl.tout, preview.want, pv_w)
      if changed then preview.want = cur end
      if released then
        proj_set("in", tl.tin > 0.05 and string.format("%.2f", tl.tin) or "")
        proj_set("out", tl.tout < dur - 0.05 and string.format("%.2f", tl.tout) or "")
      end
    else
      ImGui.Dummy(ctx, pv_w, TL_H)
    end
  end

  -- One row: the three sliders and, for a video, the Loop toggle.
  -- Opacity is a layer property, so it follows the drag live. Shading and grid
  -- rebuild the key table and repaint the arrange, so they apply on release.
  local loop_w = image and 0 or (ImGui.CalcTextSize(ctx, "Loop") + 28)
  local gaps = image and 2 or 3
  local third = math.floor((pv_w - loop_w - gaps * 8) / 3)
  local gap = (pv_w - 3 * third - loop_w) / gaps
  local function rekey() if enabled then register_keys() end end
  ImGui.SetCursorScreenPos(ctx, x, y + pv_h + below - ROW_H)
  percent_slider("##opacity", "opacity", 0.6, "background %.0f%%", third, function(v) reaper.AUBG_SetOpacity(v) end)
  if ImGui.IsItemHovered(ctx) then tip("Background opacity over the track background colour") end
  ImGui.SameLine(ctx, 0, gap)
  percent_slider("##shading", "shading", 0.6, "shading %.0f%%", third, nil, rekey)
  if ImGui.IsItemHovered(ctx) then tip("Opacity of time selection and mute shading over the video") end
  ImGui.SameLine(ctx, 0, gap)
  percent_slider("##grid", "grid", 0.5, "grid %.0f%%", third, nil, rekey)
  if ImGui.IsItemHovered(ctx) then tip("Grid line opacity over the video") end
  if not image then
    ImGui.SameLine(ctx, 0, gap)
    if toggle_button("##loop", "Loop", loop, loop_w, not path) then proj_set("loop", loop and "" or "1") end
    if ImGui.IsItemHovered(ctx) then tip("Loop the video within its in/out range") end
  end
  ImGui.PopStyleVar(ctx)
  ImGui.EndChild(ctx)
end

local switch = { t = nil, last = 0 }
local function lerp_col(a, b, t)
  local function ch(sh) return math.floor(((a >> sh) & 0xFF) * (1 - t) + ((b >> sh) & 0xFF) * t + 0.5) end
  return (ch(24) << 24) | (ch(16) << 16) | (ch(8) << 8) | ch(0)
end

-- Hold Alt to see sync and keying diagnostics in the footer.
local stats = { t = 0, paints = 0, pps = 0 }
local function draw_stats(x, y, now)
  local probe = reaper.AUBG_Probe()
  if probe ~= "" then
    ImGui.DrawList_AddTextEx(ImGui.GetWindowDrawList(ctx), font_s, 12, x, y, UI.muted, probe)
    return
  end
  local f = {}
  for v in reaper.AUBG_Stats():gmatch("[^|]+") do f[#f + 1] = v end
  if #f < 7 then return end
  local paints = tonumber(f[7]) or 0
  if now - stats.t >= 1 then
    stats.pps, stats.paints, stats.t = math.floor((paints - stats.paints) / math.max(now - stats.t, 1e-3) + 0.5), paints, now
  end
  local mode = ({ w = "write", f = "full" })[f[6]] or f[6]
  local text = string.format("drift %s ms  seeks %s%s  timeouts %s  rate %s  lead %s ms  key %s ms %s %sk px  paints %d/s",
    f[1], f[2], f[8] == "1" and "*" or "", f[9] or "0", f[3], f[4], f[5], mode, math.floor((tonumber(f[10]) or 0) / 1000 + 0.5), stats.pps)
  ImGui.DrawList_AddTextEx(ImGui.GetWindowDrawList(ctx), font_s, 12, x, y, UI.muted, text)
end

-- "Start with REAPER" on the left, macOS-style switch for the background on the right.
local function draw_footer(aw, now)
  local tw, th = 51, 31
  local x, y = ImGui.GetCursorScreenPos(ctx)
  local dl = ImGui.GetWindowDrawList(ctx)
  if enabled and (ImGui.IsKeyDown(ctx, ImGui.Mod_Alt) or reaper.AUBG_AltDown() == 1) then
    draw_stats(x, y + (th - 12) / 2, now)
  else
    ImGui.PushStyleVar(ctx, ImGui.StyleVar_FramePadding, 13, 5)
    ImGui.SetCursorScreenPos(ctx, x, y + (th - 25) / 2)
    local rv, v = ImGui.Checkbox(ctx, "Start with REAPER", setting("autostart", 0) == 1)
    if rv then set_setting("autostart", v and 1 or 0) end
    ImGui.PopStyleVar(ctx)
  end
  local caption = "Background"
  ImGui.PushFont(ctx, font_s)
  local lw = ImGui.CalcTextSize(ctx, caption)
  ImGui.PopFont(ctx)
  local sx = x + aw - tw
  ImGui.DrawList_AddTextEx(dl, font_s, 12, sx - 13 - lw, y + (th - 12) / 2, UI.muted, caption)
  ImGui.SetCursorScreenPos(ctx, sx, y)
  local clicked = ImGui.InvisibleButton(ctx, "##switch", tw, th)
  if clicked then
    if bg_on then stop_background() else start_background() end
  end
  if ImGui.IsItemHovered(ctx) then tip(bg_on and "Background on" or "Background off") end

  local target = bg_on and 1 or 0
  if not switch.t then switch.t = target end
  local dt = switch.last > 0 and math.min(now - switch.last, 0.1) or 0
  switch.last = now
  switch.t = switch.t + clamp(target - switch.t, -dt * 8, dt * 8)
  local t = switch.t
  ImGui.DrawList_AddRectFilled(dl, sx, y, sx + tw, y + th, lerp_col(UI.frame_hover, UI.accent, t), th / 2)
  local kx, ky, kr = sx + th / 2 + (tw - th) * t, y + th / 2, th / 2 - 2
  ImGui.DrawList_AddCircleFilled(dl, kx, ky + 1, kr, 0x00000040)
  ImGui.DrawList_AddCircleFilled(dl, kx, ky, kr, 0xFFFFFFFF)
end

-- Draws one frame of the window; returns false once it has been closed.
local function draw_window(now)
  if not load_imgui() then return false end
  if not ctx or not ImGui.ValidatePtr(ctx, "ImGui_Context*") then
    ctx = ImGui.CreateContext("ReaBackground")
    ImGui.SetConfigVar(ctx, ImGui.ConfigVar_ViewportsNoDecoration, 0)
    font = ImGui.CreateFont("sans-serif", 15)
    font_s = ImGui.CreateFont("sans-serif", 12)
    ImGui.Attach(ctx, font)
    ImGui.Attach(ctx, font_s)
    preview.path, preview.img = nil, nil
    refresh_library()
  end
  thumb_budget = 1
  local nvars, ncols = push_style()
  ImGui.PushFont(ctx, font)
  ImGui.SetNextWindowSize(ctx, W, H, ImGui.Cond_Always)
  local flags = ImGui.WindowFlags_NoTitleBar | ImGui.WindowFlags_NoResize | ImGui.WindowFlags_NoCollapse |
    ImGui.WindowFlags_NoScrollbar | ImGui.WindowFlags_NoScrollWithMouse
  local visible, open = ImGui.Begin(ctx, "ReaBackground", true, flags)
  if visible then
    local aw, ah = ImGui.GetContentRegionAvail(ctx)
    local body = ah - TITLE_H - 2 * PAD
    local top_h = math.floor(body / PHI)
    local bottom_h = body - top_h
    draw_project(aw, top_h, now)
    ImGui.Dummy(ctx, 0, PAD - 16)
    draw_videos(bottom_h, aw)
    ImGui.Dummy(ctx, 0, PAD - 16)
    draw_footer(aw, now)
    ImGui.End(ctx)
  end
  ImGui.PopFont(ctx)
  ImGui.PopStyleColor(ctx, ncols)
  ImGui.PopStyleVar(ctx, nvars)
  return open
end

---------------------------------------------------------------------------
-- Main loop
---------------------------------------------------------------------------
local want_window = reaper.GetExtState(SECTION, "headless") ~= "1"
reaper.DeleteExtState(SECTION, "headless", false)

local function main()
  local now = reaper.time_precise()
  if reaper.GetExtState(SECTION, "show") == "1" then
    reaper.DeleteExtState(SECTION, "show", false)
    want_window = true
  end
  if bg_on then engine_tick(now) end
  if want_window then want_window = draw_window(now) end
  if not bg_on and not want_window then return end
  reaper.defer(main)
end

-- Lets the extension find and relaunch this script (menu item, auto-start) and
-- intercept re-runs while it is running.
reaper.SetExtState(SECTION, "script_path", script_path, true)
reaper.AUBG_SetScript(cmd_id)
if reaper.set_action_options then reaper.set_action_options(1) end
last_settings = settings_signature()

reaper.atexit(function()
  disable()
  reaper.AUBG_SetScript(0)
end)
main()
