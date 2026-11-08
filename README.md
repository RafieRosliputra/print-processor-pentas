# PrintProcessor

Batch-process subject photos into print-ready files (300 dpi) on macOS 14+.
Dark Photoshop-style AppKit app, built with SwiftPM only — no Xcode project.

## Targets

- `PrintProcessorCore` — pure Swift library (no AppKit): `PaperSize`, `AppSettings`,
  `Theme`, `Compositor`, `ImageCache`, `ExportJob`, `WebPExport`, `ICCProfile`.
- `PrintProcessor` — AppKit executable.
- `PrintProcessorCheck` — self-check that verifies paper-size math, defaults,
  compositor stacking, export JPG/WebP output, metadata stripping, and parallel export.

## Build & run

```sh
swift build
swift run PrintProcessorCheck   # self-test gate (exits non-zero on failure)
swift run PrintProcessor        # launch the app
```

Only Command Line Tools are required (no Xcode project, no custom `.metal` shaders).

## App bundle

```sh
Scripts/build_app.sh
# -> DELIVERABLES/PrintProcessor.app
```

The script builds a release binary and wraps it with `Info.plist`, `AppIcon.icns`,
and an ad-hoc signature. Bundle id: `com.johorstudio.printprocessor`, version `0.0.1`.

## Usage

1. Pick a paper size in the top-right bar (the canvas stays locked until then).
2. Add photos with **Add photos…** or by dragging files/folders onto the canvas
   (JPG/JPEG/WebP/PNG). Natural sort keeps `2` before `10`.
3. Adjust each photo on the canvas (see shortcuts below); edits auto-save to a
   project `.json` in the working folder and are restored on relaunch.
4. Configure the Export section (formats, quality, sizing) and press **Process**
   (or **⌘P**) to write `JPG/` and `WebP/` folders.
5. Use **Render** (or **⌘R**) to preview the current photo at full resolution in
   Quick Look; **Space** closes it.

## Export

- JPG and/or WebP, written into `JPG/` and `WebP/` under the export root
  (default = working folder; pick another with **Export to…**, which has a New
  Folder button).
- JPG: 300 dpi, sRGB ICC profile embedded (APP2 `ICC_PROFILE`), JFIF density
  300 dpi, EXIF/XMP stripped (APP1 markers removed). Quality 0–12 (Photoshop
  scale, default 10); size by inch (300 dpi) or long edge in pixels.
- WebP: long edge in pixels (0 = full paper size) + quality % (default 50),
  alpha off, via `cwebp`. The sRGB ICC profile is embedded (`ICCP` RIFF chunk)
  and EXIF/XMP/GPS are stripped.
- Filename pattern (Settings): `{name}`, `{size}`, `{number}`, `{index}`; default `{name}`.
- Collision: Replace / Skip / Keep both, with "Apply to all".
- Parallel on all CPU cores (Settings → CPU core limit overrides); progress is
  shown under the Process button. A **Cancel** button appears next to Process
  while exporting; cancel stops the remaining files and the status shows
  `Cancelled n/total`.
- **Render** button under the canvas renders the current photo at full size to a
  temp file and opens Quick Look; **Space** closes it and the temp file is deleted.

## PSD flow

- **Layer 2 (PSD text):** load a PSD with a text layer + layer style via
  **Load PSD…** (or drag-and-drop). The target layer is `TEXT` (name changeable
  in Settings), otherwise the first text layer. Text is set in Photoshop in the
  background, so the style stays 100 % identical. Text comes from (in priority
  order) a manual edit → an imported/pasted `number → name` list → filename scan
  (split on ` - `). Long text wraps, then shrinks down to a minimum scale.
- **Layer 3 (PSD overlay):** load a PSD overlay via **Load PSD…**; the app
  flattens it to `<name>-00.webp` beside the PSD. The app watches the PSD, and
  each save produces a new numbered webp (`-01`, `-02`, …). Numbering never
  reuses numbers and existing webps are never overwritten.
- **Middle-click** a layer 2/3/4 element opens its file in Photoshop. For a
  photo, on close the app asks: save as new version (`name-01.webp`, original
  untouched), replace original, or cancel.

## Keyboard shortcuts

All shortcuts are listed on the Keyboard Shortcuts tab. Click a combo to record a
new key; conflicts are flagged in red; Reset restores defaults. Bindings persist
and are read live by the canvas.

| Action | Default |
|---|---|
| Next photo | Space |
| Previous photo | Double-tap Space |
| Zoom | Scroll |
| Rotate | R + scroll |
| Nudge 1 px | Arrow keys |
| Nudge 10 px | Shift + arrows |
| Global edit (all) | ⌘⇧ + drag/scroll |
| Apply to following | ⇧ + drag/scroll |
| Undo | ⌘Z |
| Redo | ⌘⇧Z |
| Render (Quick Look) | ⌘R |
| Process / Save | ⌘P |
| Open in Photoshop | Middle-click |

## Troubleshooting

- **`cwebp not found`** — WebP export (and PSD-overlay flattening) needs the
  `cwebp` binary. Install it with `brew install webp`, or set the absolute path
  in Settings → cwebp path. The app also checks `/opt/homebrew/bin/cwebp` and
  `/usr/local/bin/cwebp`, then `PATH`.
- **Photoshop not detected** — the app auto-detects Adobe Photoshop in
  `/Applications`. If your install is elsewhere, set the `.app` path in
  Settings → Photoshop path.
- **No image appears / canvas locked** — select a paper size first, then add
  photos. Orientation follows the first photo (toggle with the Portrait/
  Landscape button).

## Notes

- UI language is English; brand is written `JohorStudio.com`.
- Requires Command Line Tools only; no `.metal` shaders are used.
- Photoshop is auto-detected in `/Applications` (path override in Settings).
- Tooltip delay: tooltips are set via `NSView.toolTip` (system default delay).
  The Settings → "Tooltip delay (s)" value is stored and clamped, but AppKit
  exposes no public API to change the global tooltip delay, and
  `NSToolTipManager` is not in the public SDK interface, so the value is not
  currently applied at runtime (documented limitation).
