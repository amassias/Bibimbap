# Hardware validation matrix (BIB-018)

This matrix prevents four different kinds of evidence from being reported as one
thing. A green build or a simulator test never becomes a physical validation claim.
GitHub Actions runs without a mouse or receiver; no physical validation is performed
by CI.

## Evidence levels

| Level | What it proves | What it does not prove |
|---|---|---|
| Catalog model | The bundled metadata declares a CID/MID, sensor, firmware hints, capabilities and product IDs. | That the model is present, reachable, or safe to write on a particular unit. |
| Simulator | The deterministic `PulsarSimulator` exercises protocol and application paths, including injected failures. | HID descriptors, macOS permissions, radio behavior, firmware quirks or physical write success. |
| Fixture | A captured byte region can be replayed to test decoders, checksums and round trips. | That the capture is current, that every operation works, or that the fixture's device is connected now. |
| Physical validation | A named device, firmware, transport and operation was run with before/after evidence, independent read-back and restoration. | Other models, sensors, firmware versions, transports or polling modes not listed in that record. |

## Current catalog scope

The source is `Sources/PulsarCatalog/Resources/catalog.json`, schema version 2,
catalog snapshot `1.3.11`:

| Dimension | Declared scope |
|---|---|
| Families / models | 31 families / 127 model identifiers, all currently grouped under CID 87 in the embedded snapshot |
| Sensors | `pulsar x1`, `3950`, `3955`; the 3955 path uses the extended DPI block format |
| USB vendors | `0x3710` and `0x3554` |
| Product transport groups | 40 wired product IDs and 7 wireless product IDs in the catalog snapshot |
| Connection types in protocol model | Wired 1 kHz / 8 kHz and wireless 1 kHz / 2 kHz / 4 kHz / 8 kHz codes |
| Firmware metadata | Per-family device-version hints where known; missing values remain unknown rather than guessed |

The catalogue is a declaration layer. It is not a compatibility guarantee for every
firmware revision or every physical unit carrying the same CID/MID.

## Automated evidence in this repository

| Source | Representative device/context | Operations covered | Status |
|---|---|---|---|
| `PulsarCatalogTests` | Embedded catalog | Family/model uniqueness, presentation assets, vendor/product transport groups, sensor ranges and representable DPI defaults | Deterministic, offline |
| `PulsarSimulatorTests` | Simulated CID 87 / MID 10, including wireless 4 kHz and wired 1 kHz modes | Handshake, online/action status, flash reads, scalar and chunked writes, capability probing, dongle lighting, timeouts, checksum retries, dropped writes, disconnects, firmware-update blocking and notifications | Deterministic, no hardware |
| `HardwareFixtureTests` | `Tests/PulsarProtocolTests/Fixtures/x2-crazylight-core.json` | Snapshot decoding, scalar checksums, DPI decoding and re-encoding, colors, button functions and catalog recognition | Deterministic replay of a fixture |
| `PulsarProtocolTests` / feature tests | Codec and write-plan inputs | Frame checksums, flash addressing, DPI/macro codecs, write planning and rollback decisions | Deterministic, no hardware |

The release workflow runs the catalog, fixture and simulator-focused suites. It does
not run a physical device and it does not promote simulated wireless rates to radio
validation.

## Fixture record

The committed fixture identifies:

| Field | Recorded value |
|---|---|
| Model | Pulsar X2 CrazyLight, CID 87 / MID 10 |
| Sensor declaration | `pulsar x1` in the catalog |
| Firmware | `v3.05` |
| Transport | USB wired, protocol connection type `2` |
| Capture | Core settings region `0x0000..0x0100`, captured 2026-07-26 |
| Physical status | The JSON is a retained capture; replaying it is not a live connection |

The fixture is intentionally separate from the simulator. A simulator can generate a
valid nominal state without being a capture, while a fixture can expose decoder drift
without proving that a new write is accepted by hardware.

## Physical evidence retained in the repository

The following records are historical evidence written in
[`docs/protocol.md`](protocol.md). They were not executed by this packaging work or by
GitHub Actions, and no new hardware claim is made here:

| Device / firmware | Transport | Recorded operations | Restoration/read-back |
|---|---|---|---|
| X2 CrazyLight, CID 87 / MID 10, `v3.05` | USB wired | Handshake, version, battery, profile, settings-region read, checksums, DPI and button decoding | Read-only record |
| X2 CrazyLight, CID 87 / MID 10, `v3.05` | 8K receiver, protocol type 5 | Read path plus scalar, compound DPI, multi-report macro and button-function write paths | Independently read back and restored in the retained record |

This table must not be extended from simulator output or a CI log. A future physical
entry requires the device to be present and the operator to retain the diagnostic
record, firmware version, transport, receiver firmware when relevant, exact operation,
before bytes, after bytes, independent read-back and restoration result.

## Explicit limits and next physical runs

Not physically validated by this matrix:

- wireless polling above 1 kHz, including 2 kHz, 4 kHz and 8 kHz writes;
- the relationship between a catalog model and every firmware revision or receiver;
- all catalog sensors other than the retained X2 CrazyLight evidence;
- permission prompts, sleep/wake, reconnect and multi-device selection on real hardware;
- firmware update commands, which remain blocked in phase 1.

The polling write test is intentionally opt-in because a renegotiated wireless link can
interrupt restoration:

```bash
swift run pulsar-writetest polling
```

It must only be run with a documented recovery plan, a compatible physical device and
an operator ready to perform an independent read-back. The absence of such a run is a
known limitation, not a missing CI step.

## Physical validation record template

When hardware is available, add a dated record with at least:

```text
record-id:
date / operator:
macOS / app commit / package manifest:
device / CID / MID / sensor:
device firmware / receiver firmware:
transport / protocol connection type:
operations:
before snapshot or bytes:
write plan and independent read-back:
restoration result:
diagnostic log / fixture path:
known limits or failed attempts:
```
