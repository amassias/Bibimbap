# Bibimbap

Bibimbap is a native macOS configurator for Pulsar mice, built with SwiftUI and
Swift 6.

It talks directly to supported devices through `IOHIDManager`, so it does not
depend on WebHID, a browser wrapper, or a background web service. The interface
uses a catalog-backed image and capability set for each recognized mouse.

> [!NOTE]
> Bibimbap is an independent personal project and is not affiliated with,
> endorsed by, or maintained by Pulsar Gaming Gears. The protocol implementation
> is based on documented observations in
> [`docs/protocol.md`](docs/protocol.md).

## Highlights

- Native macOS interface with automatic light and dark appearance.
- English by default, with instant French switching in Settings.
- Overview dashboard with connection, battery, signal, firmware, DPI, polling,
  and active profile information.
- Model-aware button customization: only controls available on the connected
  mouse are shown.
- DPI stages, polling rate, lift-off distance, debounce, sensor options, and
  DPI lighting controls.
- Macro editing, validation, hardware-slot assignment, and repeat behavior.
- Wireless receiver status, pairing, battery behavior, and power settings.
- Menu bar controls for common actions without opening the main window.
- Versioned JSON profile backup, diagnostic export, and factory reset tools.
- A bundled catalog covering 31 device families, 127 model identifiers, and 127
  matching mouse images.

## Project status

| Layer | Status |
|---|---|
| HID transport (`PulsarHID`) | Validated on hardware over USB and through an 8K receiver |
| Protocol (`PulsarProtocol`) | Reading and writing validated on hardware |
| Device catalog (`PulsarCatalog`) | 31 families and 127 models from catalog snapshot v1.3.11 |
| Simulator (`PulsarSimulator`) | Nominal path plus injected failure scenarios |
| Application (`BibimbapFeatures` + `BibimbapUI`) | Complete configuration UI, pairing, backups, and diagnostics |
| Macros | Read, write, edit, validate, and simulator end-to-end coverage |
| Localization | English source language with complete French UI coverage |
| Firmware updates | Not implemented; update commands are explicitly rejected |

The current test suite contains 105 tests across protocol codecs, catalog
coverage, the simulator, profile archives, write planning, application state,
and macro round trips.

## Compatibility

Compatibility is described at three different levels:

| Level | Scope |
|---|---|
| Declared by the bundled catalog | 127 model identifiers under catalog CID 87 |
| Covered by fixtures | A real X2 CrazyLight capture, replayed by the test suite |
| Validated on physical hardware | X2 CrazyLight over USB and through an 8K receiver |

Hardware validation for the X2 CrazyLight:

| Operation | USB | 8K receiver |
|---|---:|---:|
| Handshake, firmware, battery, and profile | ✅ | ✅ |
| Settings-region read | ✅ | ✅ |
| DPI, color, and button decoding | ✅ | ✅ |
| Scalar setting write | ✅ | ✅ |
| Checksummed compound-block write | ✅ | ✅ |
| Multi-report macro write | ✅ | ✅ |
| Button-function write | ✅ | ✅ |
| Independent read-back and restoration | ✅ | ✅ |
| Polling above 1 kHz | Not applicable | Not yet hardware-validated |

The X2 CrazyLight is limited to 1 kHz over USB and reaches higher polling rates
through its receiver. The higher polling-codec branch therefore cannot be
validated over the wired connection on this model.

## Safety model

Bibimbap treats the device state as the source of truth:

- Every write is followed by an independent read-back.
- A mismatched read-back fails the operation and rolls the batch back in reverse
  order.
- A failed rollback is surfaced as an uncertain hardware state instead of being
  hidden behind a generic error.
- Unsupported capabilities are omitted from the interface.
- Unknown models are rejected instead of receiving guessed flash addresses or
  limits.
- Importing a profile only fills the pending draft; unsupported values are
  skipped and reported.
- The device catalog is bundled and never downloaded or executed at runtime.

## Architecture

```text
Package.swift
Sources/
  BibimbapLocalization/   In-app language selection and localization helpers
  BibimbapFeatures/       Observable state, drafts, validation, and write plans
  BibimbapUI/             SwiftUI shell, sections, theme, and device artwork
  PulsarCatalog/          Versioned device capabilities and model metadata
  PulsarHID/              HID discovery, opening, and report transport
  PulsarProtocol/         Frames, checksums, flash map, codecs, and sessions
  PulsarSimulator/        Simulated device and injected failure paths
  bibimbap-render/        Off-screen light/dark UI renderer
  pulsar-probe/           Read-only hardware diagnostics
  pulsar-writetest/       Explicit reversible hardware-write checks
App/
  Bibimbap.xcodeproj      macOS application target
  Bibimbap/               App entry point, assets, entitlements, and strings
Tests/                    Protocol, catalog, simulator, feature, and fixture tests
Tools/generate_catalog.py Catalog regeneration tool
docs/protocol.md          Observed protocol documentation
Design/                   Logo concepts and redesign reference screens
```

## Requirements

- macOS 15 or later
- Apple silicon Mac
- Xcode with the macOS 15 SDK or later
- A supported Pulsar mouse or receiver for hardware use

## Build and test

Build and test the Swift package:

```bash
swift build
swift test
```

Build the macOS application:

```bash
xcodebuild \
  -project App/Bibimbap.xcodeproj \
  -scheme Bibimbap \
  -configuration Debug \
  build
```

Run the application with a simulated X2 CrazyLight:

```bash
BIBIMBAP_SIMULATED=1 \
  /path/to/Bibimbap.app/Contents/MacOS/Bibimbap
```

## Development tools

Read a connected device without writing anything:

```bash
swift run pulsar-probe
```

Run the reversible hardware-write checks:

```bash
swift run pulsar-writetest
```

The default suite covers scalar settings, a checksummed DPI block, a multi-report
macro block, and a button function. Each test reads the original bytes, writes a
test value, independently reads it back, restores the original bytes, and verifies
the restoration.

The polling test is intentionally excluded from the default set because changing
the report rate may renegotiate the wireless link:

```bash
swift run pulsar-writetest polling
```

Regenerate the bundled device catalog:

```bash
python3 Tools/generate_catalog.py
```

Compare the bundled catalog with the currently published upstream catalog:

```bash
BIBIMBAP_CHECK_CATALOG=1 swift test --filter CatalogSnapshotTests
```

## UI rendering

Generate PNG previews for every section in light and dark appearance without
requiring physical hardware:

```bash
swift run bibimbap-render .render
```

The renderer uses the simulator and is intended for layout, hierarchy, density,
and localization review. Native AppKit controls may look flatter in off-screen
renders than they do in the running application.

## Localization

English is the source and fallback language. French can be selected from the
application's Settings screen and updates immediately without reconnecting the
mouse.

The String Catalog is stored at:

```text
App/Bibimbap/Localizable.xcstrings
```

## Menu bar behavior

The menu bar accessory provides quick access to the active DPI stage, polling
rate, profile, battery state, and device reload.

The 18 × 18 template icon encodes battery level in the mouse body itself, keeping
its footprint stable as the charge changes. Because it is a template image, macOS
automatically applies the correct tint for the current appearance and selection
state.

The Dock icon can be hidden from Settings. Bibimbap then behaves as a menu bar
accessory, and the application prevents both entry points from being disabled at
the same time.
