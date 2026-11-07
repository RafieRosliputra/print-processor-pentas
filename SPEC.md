# Print Processor v0.0.1 — SPEC (repo: print-processor-pentas)

Owner: Rafi (JohorStudio.com). Spec by Claude, code by deepseek (boss-mode). Date: 2026-11-08.
Repo: ~/Desktop/ai/claude/projects/print-processor-pentas · github.com/RafieRosliputra/print-processor-pentas (local git + remote).
Icon: JohorStudio logo from ~/Desktop/ai/icon (WebP → PNG → AppIcon.icns).

## 1. Purpose
Mac app to batch-process ~200 subject photos (JPG/WebP) into print-ready files: place each photo on a layered template (background, overlays, text, watermark), adjust per photo, export at 300 dpi.

## 2. Platform & stack
- Swift 6.4, AppKit; GPU compositing via Core Image on Metal (ASSUME: only Command Line Tools installed, no Xcode → no custom .metal shaders). Build with SwiftPM + script that wraps the binary into PrintProcessor.app. Apple Silicon, macOS 14+.
- UI English, dark Photoshop-style theme (#323232 panels / #535353 borders), SF Pro font.
- Window opens maximised (not fullscreen).
- Edits kept in project `.json` in the working folder; auto-save every few seconds; reopen at last position after crash.
- Undo/redo (Cmd+Z / Cmd+Shift+Z): per image, up to 50 steps, cleared when switching image.

## 3. Layout
- Left: canvas (working window). Right: scrollable options panel (collapsible section per layer 1–6, each with on/off eye switch, in layer order).
- Top right: export size buttons, Process/Save button, status text under the button.
- Under canvas: Render button (Quick Look preview of full-res result; Space closes it).
- Tabs: Production (main), Keyboard Shortcuts, Settings.
- Every control has a tooltip (0.5 s delay: name + function + shortcut; delay adjustable/off in Settings).
- Orange glow around working area when mouse is over canvas or window is focused; off when focus is in the right panel.

## 4. Export size & canvas
- Sizes (inch, 300 dpi): 4x6, 5x7, 8x10, 8x12, 8x15, 11x14, 12x16, 12x10.
- Size must be picked first: until then the canvas is locked (photo cannot be dragged in).
- Orientation auto-follows the photo (portrait/landscape) with a rotate-orientation button.
- Last size remembered across projects/sessions.
- One size at a time; edits stored separately per size (4x6 and 8x10 keep their own adjustments).
- Changing canvas size with no stored edits for that size: scale existing positions proportionally to the new canvas.

## 5. Layers (top → bottom)
| # | Layer | Notes |
|---|---|---|
| 1 | Watermark text | Bottom right by default. Font, size, colour, opacity adjustable. Default: white, 60%, SF Pro Bold, size auto from canvas width. Selected = red box with 8 handles + rotate outside corners (move/size/rotate like Free Transform; Shift keeps ratio; click outside deselects). Global, per-image override. |
| 2 | PSD styled text | See §6. |
| 3 | Custom overlay | PNG / WebP / PSD with transparency. PSD → see §7. Global, per-image override. |
| – | Gradient | Only over layer 4, below layer 3. 2 end colours, angle, opacity, blend mode. |
| 4 | Subject photo | JPG/WebP (may have alpha). Main working layer, see §8. |
| 5 | Background (transparent) | Image file with alpha (PNG/WebP/JPG/PSD). |
| 6 | Final background | Image file or solid colour. |

Each layer 1–6 can be switched on/off individually.
Middle-click on layer 2/3/4 element opens its file in Photoshop. Layer 2 and 3 elements glow on hover.

## 6. Layer 2 — PSD text
- Load a PSD with a text layer + layer style via "Load PSD…" (file picker or drag-and-drop; any location; path stored in project .json). Text is edited by Photoshop in the background (script), style stays 100% identical. Photoshop auto-detected in /Applications (Adobe Photoshop 2026 present; path override in Settings).
- Target text layer: layer named `TEXT` (name changeable in Settings), otherwise the first text layer.
- One bounding box for all images (Rafi draws it), per-image override possible.
- Long text: wrap to new lines; if still too big, shrink font down to a minimum size (min size in Settings). Align left / centre / right option.
- Text source (priority): manual edit → pasted/imported list → filename scan.
  - List format e.g. `122 - Norman Hakim` → file `122.jpg` gets "Norman Hakim". Import `.txt` or paste directly in a text box.
  - Filename scan: split on ` - `; which side goes to layer 2 vs layer 1 is chosen in Settings (left/right), with a live preview of the scan result for the current files.
  - Examples: `122 - Norman Hakim.jpg` → layer 2 = "Norman Hakim". `Tingkatan 1C - 01.jpg` → layer 2 = "Tingkatan 1C", layer 1 watermark = "01".
  - Scan modes can be saved and switched with one click.

## 7. Layer 3 — PSD overlays
- "Load PSD…" option; open PSD in Photoshop from the app. On loading a PSD, auto-generate `name-00.webp`.
- Each time the PSD is saved/closed (app watches the file), export a new webp beside it: `name-01.webp`, `name-02.webp`, …
- Numbering never reuses numbers: if `name-04.webp` is saved while `name-01.webp` was deleted, continue to `name-05.webp` (highest ever + 1; track via highest number found plus a counter stored in the project).
- Existing webp files are never overwritten.

## 8. Layer 4 — subject photos
- Import: choose many files, drag and drop files/folders, or a text file (photo number + name list). Natural sort by number in filename (2 before 10).
- Spacebar = next file. Double-tap Spacebar (300 ms, adjustable) = previous file.
- Initial placement: Fit.
- Scroll = zoom. Drag = pan. R + scroll = rotate. Rotation step box: 0.01 to 1.5° per scroll (scroll on the box changes ±0.01); direction follows scroll direction.
- Arrow keys = move 1 px, Shift + arrow = 10 px (pixel basis chosen in Settings: export pixels default, or screen pixels).
- Glow orange line around the working area when keyboard/mouse are active on canvas.
- Global edits (absolute): Cmd+Shift while moving/zooming/rotating applies to all files in layer 4 so all match the current image's position, size, rotation. Shift applies the same to files below (after) the current file.
- Scroll supports mouse wheel and trackpad with adjustable sensitivity (zoom speed, rotate speed).
- Middle-click opens in Photoshop; on close the app asks every time: save as new version (`name-01.webp`, original untouched) or replace original.
- No pan constraint: the photo can be placed anywhere, even leaving the canvas partly or fully empty (Rafi confirmed).

## 9. Performance & cache
- Preview (downscaled) used for editing. On export always load the original at full quality.
- On load: immediately cache the first 10 images into RAM, then build the rest in background (low priority; must never block the UI).
- Remaining cache on temp disk (not permanent). Cache cleared on quit; deleted if the app crashes (cleaned at next launch).
- Decode off the main thread; prefetch next 3 / previous 2 images.

## 10. Export
- Targets: JPG, WebP, or both. Files go to their own folders `JPG/` and `WebP/` under the export root. Default root = working folder. Status shows counts, e.g. "JPG – 200 files / WebP – 200 files".
- Choose another folder via a picker that has the New Folder button.
- Output: 300 dpi, sRGB profile embedded, all metadata stripped (no EXIF, no copyright notice).
- JPG: choose by inch (300 dpi) or long edge px; quality 0–12 (Photoshop scale), default 10.
- WebP: long edge px; quality %, default 50.
- Filename pattern editable in Settings (e.g. {name}, {size}, {number}); default = original name.
- Existing file collision: ask replace / skip / keep both (with "apply to all").
- Export runs in parallel on all CPU cores by default (Settings switch to limit core count); app stays usable; progress bar + status under the button.
- Render button: render current image at full resolution into a temp file → Quick Look; Space closes; temp file deleted.

## 11. Keyboard Shortcuts tab
- Lists all shortcuts (single key or key+mouse). All customisable, conflict warning, Reset button.
- Defaults: Space next; double-Space back; scroll zoom; R+scroll rotate; arrows 1 px; Shift+arrows 10 px; Cmd+Shift / Shift global edit; Cmd+Z / Cmd+Shift+Z undo/redo; middle-click open in Photoshop.

## 12. Settings tab
Everything adjustable without code changes. Buttons: Apply (instant, no restart), Revert (discard unapplied changes), Defaults (confirm first).
Includes: double-tap speed, scroll sensitivity, nudge pixel basis, tooltip delay, watermark defaults, filename-scan mode, text layer name, min font size, Photoshop path, export defaults (JPG 10, WebP 50), filename pattern, CPU cores limit, cache sizes, auto-save interval, theme accents.

## 13. Out of scope for v0.0.1
Multi-size export in one go; light theme; Windows; iCloud/NAS sync.

## 14. Milestones (deepseek codes one, Claude audits, Rafi tests)
1. Package skeleton + build script (.app + icon), theme, window, Production/Shortcuts/Settings tabs, size buttons, locked canvas, canvas with layer 4 (import, spacebar nav, zoom/pan/rotate/arrows, glow, undo).
2. Overlays: layer 5/6, layer 3 (PNG/WebP), gradient, layer 1 watermark with handles, layer on/off switches.
3. Layer 2 PSD text via Photoshop + text list/filename scan; layer 3 PSD watcher + numbering; middle-click Photoshop.
4. Cache + performance (preview vs original), global/shift edits, per-size edits, autosave/recovery.
5. Export (parallel, JPG/WebP options, folders, filename pattern), Render/Quick Look, Settings/Shortcuts customisation, tooltips polish.

## 15. Open items
None.
