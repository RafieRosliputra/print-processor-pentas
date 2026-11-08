# PrintProcessor

Batch-process subject photos into print-ready files (300 dpi) on macOS 14+.
Dark Photoshop-style AppKit app, built with SwiftPM only — no Xcode project.

## Targets

- `PrintProcessorCore` — pure Swift library (no AppKit): `PaperSize`, `AppSettings`,
  `Theme`, `Compositor`, `ImageCache`, `ExportJob`, `WebPExport`.
- `PrintProcessor` — AppKit executable.
- `PrintProcessorCheck` — self-check that verifies paper-size math, defaults,
  compositor stacking, export JPG/WebP output, and parallel export.

## Build & run

```sh
swift build
swift run PrintProcessorCheck   # self-test gate (exits non-zero on failure)
swift run PrintProcessor        # launch the app
```

## App bundle

```sh
Scripts/build_app.sh
# -> DELIVERABLES/PrintProcessor.app
```

The script builds a release binary and wraps it with `Info.plist`, `AppIcon.icns`,
and an ad-hoc signature. Bundle id: `com.johorstudio.printprocessor`, version `0.0.1`.

## Export

- JPG and/or WebP, written into `JPG/` and `WebP/` under the export root
  (default = working folder; pick another with **Export to…**, which has a New
  Folder button).
- JPG: 300 dpi, sRGB profile embedded, source metadata stripped; quality 0–12
  (Photoshop scale, default 10); size by inch (300 dpi) or long edge in pixels.
- WebP: long edge in pixels (0 = full paper size) + quality % (default 50),
  alpha off, via `cwebp` (PATH or Settings → cwebp path).
- Filename pattern (Settings): `{name}`, `{size}`, `{number}`, `{index}`; default `{name}`.
- Collision: Replace / Skip / Keep both, with "Apply to all".
- Parallel on all CPU cores (Settings → CPU core limit overrides); progress is
  shown under the Process button.
- **Render** button under the canvas renders the current photo at full size to a
  temp file and opens Quick Look; **Space** closes it and the temp file is deleted.

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

## Notes

- UI language is English; brand is written `JohorStudio.com`.
- Requires Command Line Tools only; no `.metal` shaders are used.
- Photoshop is auto-detected in `/Applications` (path override in Settings).
- Tooltip delay: tooltips are set via `NSView.toolTip` (system default delay).
  The Settings → "Tooltip delay (s)" value is stored and clamped, but AppKit
  exposes no public API to change the global tooltip delay, and
  `NSToolTipManager` is not in the public SDK interface, so the value is not
  currently applied at runtime (documented limitation).
