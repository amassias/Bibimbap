# Download Bibimbap

The canonical download page is the
[latest GitHub Release](https://github.com/amassias/Bibimbap/releases/latest).
Every versioned release is generated from a `vX.Y.Z` tag by
[`.github/workflows/release.yml`](../.github/workflows/release.yml).

Each release contains:

- a versioned ZIP for direct installation;
- a versioned DMG for Finder-based installation;
- a manifest identifying the source commit, architecture, signature and notarization
  state;
- `SHA256SUMS` for an independent archive check.

Download the asset matching the Mac architecture documented by the release, verify its
checksum, and then follow [`docs/distribution.md`](distribution.md) for installation
and HID permission steps. The release page is the authoritative place to see whether
an asset is signed and notarized; a workflow artifact is a CI build, not evidence of
physical mouse validation.

For maintainers, the exact local reproduction command is:

```bash
./scripts/validate_distribution.sh
./scripts/package_macos.sh --version X.Y.Z --output .build/distribution --arch arm64
./scripts/validate_distribution.sh --artifacts .build/distribution
```
