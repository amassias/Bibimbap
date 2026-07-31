# Contributing to Bibimbap

Thanks for your interest in improving Bibimbap.

## Before opening a pull request

1. Open an issue first for significant changes so we can align on scope.
2. Keep changes focused and include clear reproduction steps for bug fixes.
3. For hardware-specific behavior, include model, firmware version, and macOS version.

## Development setup

```bash
swift build
swift test
```

Build the macOS app:

```bash
xcodebuild \
  -project App/Bibimbap.xcodeproj \
  -scheme Bibimbap \
  -configuration Debug \
  build
```

## Pull request checklist

- [ ] Change is scoped to a single problem.
- [ ] Existing tests pass, and new tests are added when logic changes.
- [ ] README/docs are updated if user-facing behavior changes.
- [ ] No firmware update behavior is introduced (currently unsupported).

## Reporting issues

Please use the issue templates and include diagnostics when possible:

```bash
swift run pulsar-probe
```
