# PrintProcessor

Batch-process subject photos into print-ready files (300 dpi) on macOS 14+.
Dark Photoshop-style AppKit app, built with SwiftPM only — no Xcode project.

## Targets

- `PrintProcessorCore` — pure Swift library (no AppKit): `PaperSize`, `AppSettings`, `Theme`.
- `PrintProcessor` — AppKit executable.
- `PrintProcessorCheck` — self-check that verifies `PaperSize` pixel math and defaults.

## Build & run

```sh
swift build
swift run PrintProcessorCheck
```

## App bundle

```sh
Scripts/build_app.sh
# -> DELIVERABLES/PrintProcessor.app
```

The script wraps the release binary with `Info.plist`, `AppIcon.icns`, and an ad-hoc
signature. Bundle id: `com.johorstudio.printprocessor`, version `0.0.1`.

## Notes

- UI language is English; brand is written `JohorStudio.com`.
- Requires Command Line Tools only; no `.metal` shaders are used.
