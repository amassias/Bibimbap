# Bibimbap

[![Swift CI](https://github.com/amassias/Bibimbap/actions/workflows/swift.yml/badge.svg)](https://github.com/amassias/Bibimbap/actions/workflows/swift.yml)

A native macOS configurator for Pulsar mice — fast, direct, and built for power users.

Bibimbap is written in Swift 6 + SwiftUI and talks directly to supported devices through `IOHIDManager`.
No browser bridge. No WebHID wrapper. No background web service.

> [!NOTE]
> Bibimbap is an independent personal project and is not affiliated with, endorsed by, or maintained by Pulsar Gaming Gears. The protocol implementation is based on documented observations in [`docs/protocol.md`](docs/protocol.md).

> [!IMPORTANT]
> This project was built entirely with **Codex** and **Claude Code**.

## Table of contents

- [At a glance](#at-a-glance)
- [Download](#download)
- [Install](#install)
- [Usage](#usage)
- [Supported hardware and software](#supported-hardware-and-software)
- [Troubleshooting](#troubleshooting)
- [Get involved](#get-involved)
- [Screenshots](#screenshots)
- [Why Bibimbap](#why-bibimbap)
- [Features](#features)
- [Project status](#project-status)
- [Compatibility](#compatibility)
- [Validation matrix](#validation-matrix)
- [Distribution](#distribution)
- [Safety model](#safety-model)
- [Architecture](#architecture)
- [Requirements](#requirements)
- [Quick start](#quick-start)
- [Development tools](#development-tools)
- [UI rendering](#ui-rendering)
- [Localization](#localization)
- [Menu bar behavior](#menu-bar-behavior)

## At a glance

Bibimbap is a native macOS app for Pulsar mice that lets you configure device settings directly from macOS without vendor software or web bridges.

- **Native and lightweight:** SwiftUI app with direct HID communication.
- **Safe writes:** every write path has read-back validation and rollback support.
- **Model-aware UI:** only capabilities supported by your connected device are shown.
- **Installable releases:** versioned ZIP and DMG artifacts are produced by GitHub Actions.

## Download

The canonical download page is the [latest GitHub Release](https://github.com/amassias/Bibimbap/releases/latest).
Each tag release contains a versioned ZIP, DMG, manifest and `SHA256SUMS` file. The
[download page](docs/download.md) explains how to verify and install an asset.

## Install

For normal use, download the versioned ZIP or DMG from the
[GitHub Releases page](https://github.com/amassias/Bibimbap/releases/latest), verify
`SHA256SUMS`, copy `Bibimbap.app` to `/Applications`, and follow the HID permission
steps in [`docs/distribution.md`](docs/distribution.md). Xcode is not needed to install
a release. Unsigned workflow artifacts are explicitly labelled in their manifest and
may require the macOS right-click **Open** flow; they are not equivalent to a
notarized release.

For development, build and run locally:

```bash
xcodebuild \
  -project App/Bibimbap.xcodeproj \
  -scheme Bibimbap \
  -configuration Debug \
  build
```

Then launch `Bibimbap.app` from Xcode's build products or from DerivedData.

## Usage

1. Connect a supported Pulsar mouse (USB or compatible receiver).
2. Launch Bibimbap and select the detected device.
3. Review current settings, edit values, then apply changes.
4. Use profile export/import and diagnostics tools for backup and support.

For command-line diagnostics:

```bash
swift run pulsar-probe
```

## Supported hardware and software

- **OS:** macOS 15 or later
- **CPU:** Apple silicon
- **Release installation:** no Xcode required
- **Development toolchain:** Xcode with macOS 15 SDK or later
- **Hardware support scope:** Pulsar model identifiers bundled in `PulsarCatalog` (catalog snapshot v1.3.11)
- **Physical evidence retained in the repository:** X2 CrazyLight over USB and an 8K receiver; this is historical evidence, not a validation performed by CI.

See [Compatibility](#compatibility) and the [validation matrix](docs/validation-matrix.md) for the evidence level, tested operations and limits.

## Troubleshooting

- **HID access denied:** allow Bibimbap in System Settings › Privacy & Security › Input Monitoring, then relaunch. Bibimbap will not retry on its own — macOS stops re-prompting once a denial is recorded.
- **No device appears:** reconnect the mouse/receiver, then use Search again.
- **Several devices are listed:** Bibimbap never picks one for you. Choose the target by name, transport, VID/PID, and location; nothing is opened until you do.
- **The mouse was unplugged mid-edit:** your draft is kept. Bibimbap reconnects (5 attempts over ~10 s), reads the device back, and asks you to choose between your draft and the settings read back. Neither choice writes anything.
- **A write fails:** Bibimbap stops the operation, verifies state, and reports if rollback is uncertain. A write interrupted by a disconnect keeps the hardware state marked uncertain until you read the device back explicitly.
- **Unsupported options are missing:** controls are hidden when a capability is not declared for your model.
- **Need deeper diagnostics:** export a diagnostic report from Settings — it starts with the connection journal, which is the only useful part when a failure happens before any frame is exchanged. For read-only probing, run `swift run pulsar-probe` and attach the output to an issue.

Full detail, including the manual validation procedure: [`docs/troubleshooting.md`](docs/troubleshooting.md).

## Get involved

- Found a bug or hardware edge case? [Open an issue](https://github.com/amassias/Bibimbap/issues/new/choose).
- Want to contribute? Start with [CONTRIBUTING.md](CONTRIBUTING.md).
- Please follow the [Code of Conduct](CODE_OF_CONDUCT.md).

## Screenshots

> Screenshot section intentionally kept as a placeholder in this change set.
> Visual assets can be added in a follow-up task.

## Why Bibimbap

Pulsar users on macOS often need a lightweight, native way to inspect and configure their hardware.
Bibimbap focuses on reliability first: read from device, edit safely, write with verification, and recover clearly when something fails.

## Features

- Native macOS interface with automatic light and dark appearance.
- Overview dashboard with connection, battery, signal, firmware, DPI, polling, and active profile details.
- Model-aware customization: only controls supported by the connected mouse are shown.
- DPI stages, polling rate, lift-off distance, debounce, sensor options, and DPI lighting controls.
- Macro editing, validation, hardware-slot assignment, and repeat behavior.
- Wireless receiver status, pairing flow, battery behavior, and power settings.
- Menu bar controls for quick actions without opening the main window.
- Versioned JSON profile backup/import, diagnostics export, and factory reset tools.
- English source language with complete French UI coverage and instant in-app switching.
- Bundled catalog covering **31 device families**, **127 model identifiers**, and **127 matching images**.

## Project status

| Layer | Status |
|---|---|
| HID transport (`PulsarHID`) | Automated coverage; physical connection validation is tracked separately |
| Protocol (`PulsarProtocol`) | Codec and fixture coverage; historical physical records are listed separately |
| Device catalog (`PulsarCatalog`) | 31 families and 127 models from catalog snapshot v1.3.11 |
| Simulator (`PulsarSimulator`) | Nominal path plus injected failure scenarios |
| Application (`BibimbapFeatures` + `BibimbapUI`) | Complete configuration UI, pairing, backups, and diagnostics |
| Macros | Read, write, edit, validate, and simulator end-to-end coverage |
| Localization | English source language with complete French UI coverage |
| Firmware updates | Not implemented; update commands are explicitly rejected |

The current test suite contains **133 tests** across protocol codecs, catalog coverage, button numbering and geometry, simulator behavior, profile archives, write planning, app state, and macro round trips.

## Compatibility

Compatibility is described at three levels:

| Level | Scope |
|---|---|
| Declared by the bundled catalog | 127 model identifiers under catalog CID 87 |
| Covered by fixtures | A real X2 CrazyLight capture replayed by the test suite |
| Physical evidence retained in the repository | X2 CrazyLight over USB and through an 8K receiver; not executed by CI |

The retained physical record for the X2 CrazyLight is documented in
[`docs/validation-matrix.md`](docs/validation-matrix.md) and
[`docs/protocol.md`](docs/protocol.md). It must not be read as a new hardware run by
this package or by GitHub Actions:

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
| Polling above 1 kHz | Not applicable | Not yet physically validated |

The X2 CrazyLight is limited to 1 kHz over USB and reaches higher polling rates through its receiver, so higher polling-codec paths cannot be validated over wired mode on this model.

## Validation matrix

The full BIB-018 matrix distinguishes catalog declarations, simulator paths, retained
fixtures and physical validation. It also records sensors (`pulsar x1`, `3950`,
`3955`), transports, firmware evidence, operations and the explicit wireless polling
limit above 1 kHz: [`docs/validation-matrix.md`](docs/validation-matrix.md).

## Distribution

The BIB-017 packaging contract covers versioning, ZIP/DMG generation, optional
Developer ID signing, optional notarization, checksums, GitHub Release publication and
Input Monitoring instructions: [`docs/distribution.md`](docs/distribution.md).

## Safety model

Bibimbap treats device state as the source of truth:

- Every write is followed by an independent read-back.
- A mismatched read-back fails the operation and rolls the batch back in reverse order.
- A failed rollback is surfaced as an uncertain hardware state instead of being hidden behind a generic error.
- Unsupported capabilities are omitted from the interface.
- Unknown models are rejected instead of using guessed flash addresses or limits.
- Profile import only fills a pending draft; unsupported values are skipped and reported.
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
scripts/                  Reproducible distribution and metadata validation scripts
App/
  Bibimbap.xcodeproj      macOS application target
  Bibimbap/               App entry point, assets, entitlements, and strings
Tests/                    Protocol, catalog, simulator, feature, and fixture tests
Tools/generate_catalog.py Catalog regeneration tool
docs/protocol.md          Observed protocol documentation
docs/troubleshooting.md   Connection diagnosis and validation procedure
docs/validation-matrix.md Catalog, simulator, fixture and physical evidence matrix
docs/distribution.md      ZIP/DMG, signing, notarization and installation contract
Design/                   Logo concepts and redesign reference screens
```

## Requirements

- macOS 15 or later
- Apple silicon Mac
- Xcode with the macOS 15 SDK or later for development builds
- A supported Pulsar mouse or receiver for hardware usage

## Quick start

Build and test the Swift package:

```bash
swift build
swift test --filter HardwareFixtureTests
swift test --filter CatalogTests
swift test --filter SimulatorFaultTests
```

Build the macOS app:

```bash
xcodebuild \
  -project App/Bibimbap.xcodeproj \
  -scheme Bibimbap \
  -configuration Debug \
  build
```

Validate distribution metadata and build installable artifacts:

```bash
./scripts/validate_distribution.sh
./scripts/package_macos.sh --version 0.1.0 --output .build/distribution --arch arm64
./scripts/validate_distribution.sh --artifacts .build/distribution
```

Run the app with a simulated X2 CrazyLight:

```bash
BIBIMBAP_SIMULATED=1 \
  /path/to/Bibimbap.app/Contents/MacOS/Bibimbap
```

## Development tools

Read a connected device without writing:

```bash
swift run pulsar-probe
```

Run reversible hardware-write checks:

```bash
swift run pulsar-writetest
```

The default write-test suite covers scalar settings, a checksummed DPI block, a multi-report macro block, and a button function. Each test reads original bytes, writes a test value, reads it back independently, restores original bytes, and verifies restoration.

The polling test is intentionally excluded by default because changing report rate may renegotiate the wireless link:

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

Generate PNG previews for every section in light and dark mode, without physical hardware:

```bash
swift run bibimbap-render .render
```

The renderer uses the simulator and is intended for layout, hierarchy, density, and localization review. Native AppKit controls may look flatter in off-screen renders than in the running app.

## Localization

English is the source and fallback language. French can be selected in Settings and updates immediately without reconnecting the mouse.

String Catalog location:

```text
App/Bibimbap/Localizable.xcstrings
```

## Menu bar behavior

The menu bar accessory provides quick access to active DPI stage, polling rate, profile, battery state, and device reload.

The 18×18 template icon encodes battery level in the mouse body itself, keeping its footprint stable as charge changes. Because it is a template image, macOS automatically applies the correct tint for appearance and selection state.

The Dock icon can be hidden from Settings. Bibimbap then behaves as a menu bar accessory, and the app prevents both entry points from being disabled at the same time.
