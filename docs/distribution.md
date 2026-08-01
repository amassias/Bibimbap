# Distribution and release contract

This document describes the BIB-017 distribution path. The source of truth is the
tagged commit plus `scripts/package_macos.sh`; the GitHub Actions workflow does not
contain a second build recipe.

## What the workflow produces

Pushing a tag named `vX.Y.Z` starts
[macOS distribution](../.github/workflows/release.yml). A manual workflow run can
also produce an unsigned test package for a chosen version. The package is built from
`App/Bibimbap.xcodeproj`, with bundle identifier `gg.pulsar.bibimbap`, and targets
Apple silicon (`arm64`) on macOS 15 or later.

Each run writes these versioned files to its artifact directory:

```text
Bibimbap-X.Y.Z-arm64.zip
Bibimbap-X.Y.Z-arm64.dmg
Bibimbap-X.Y.Z-arm64-manifest.json
SHA256SUMS
```

The ZIP is created with a sorted file list, metadata stripped from the archive, and
file timestamps derived from `SOURCE_DATE_EPOCH`. The DMG is created with `hdiutil`
from the same staged application. The manifest records the source commit, build
number, architecture, signature state, notarization state, and the SHA-256 of each
archive. `SHA256SUMS` is the check a downloader should use before opening an app.

This is reproducible in the operational sense: the version, source commit, build
inputs and packaging commands are recorded and can be rerun by GitHub Actions or
locally. Apple signatures and notarization tickets contain service-generated data, so
signed/notarized archives are not promised to be byte-for-byte identical across runs.

## Local packaging

Run the metadata check first, then package into the ignored `.build` directory:

```bash
./scripts/validate_distribution.sh
./scripts/package_macos.sh --version 0.1.0 --output .build/distribution --arch arm64
./scripts/validate_distribution.sh --artifacts .build/distribution
```

The script never chooses a development certificate implicitly. Without
`BIBIMBAP_SIGNING_IDENTITY`, it disables Xcode signing and the manifest says
`"signed": false`. If an identity is supplied, the resulting app must expose a
`Developer ID Application` authority and pass `codesign --verify --deep --strict`.
An Apple Development identity is not accepted as a release signature.

To use a local Developer ID identity:

```bash
BIBIMBAP_SIGNING_IDENTITY='Developer ID Application: Example (TEAMID)' \
  BIBIMBAP_DEVELOPMENT_TEAM='TEAMID' \
  ./scripts/package_macos.sh --version 0.1.0 --output .build/distribution
```

The identity and team must already be present in the local keychain. No certificate,
private key, provisioning profile, or secret is committed to this repository.

## Optional notarization

Notarization is requested only when a complete credential mode is present. The script
submits the ZIP with `xcrun notarytool --wait`, requires an explicit `Accepted` result,
staples the ticket to the staged app, validates it with `stapler`, rechecks the code
signature and `spctl`, then recreates the ZIP and DMG. A rejection, timeout, missing
key, or failed staple is an error. No successful notarization is inferred from the
presence of credentials.

Supported environment-variable modes are:

```text
BIBIMBAP_NOTARY_PROFILE

BIBIMBAP_NOTARY_KEY_PATH + BIBIMBAP_NOTARY_KEY_ID + BIBIMBAP_NOTARY_ISSUER

BIBIMBAP_APPLE_ID + BIBIMBAP_APPLE_TEAM_ID + BIBIMBAP_APP_SPECIFIC_PASSWORD
```

The first mode uses a local `notarytool` keychain profile. The second uses an App
Store Connect `.p8` key. The third uses an Apple ID app-specific password. These
values are only inputs to the local command; they are never written to the manifest.
If none is supplied, the manifest records `notarizationStatus: "not-requested"`.

The GitHub workflow supports the App Store Connect mode with these repository secrets:

```text
MACOS_CERTIFICATE_P12_BASE64
MACOS_CERTIFICATE_PASSWORD
MACOS_KEYCHAIN_PASSWORD
APPLE_NOTARY_KEY_BASE64
APPLE_NOTARY_KEY_ID
APPLE_NOTARY_ISSUER_ID
```

The certificate secrets are optional as a group. If they are absent, the workflow
publishes an explicitly unsigned artifact rather than signing with the development
identity present in the project file. The notarization secrets are optional as a
group; a partial group fails the job. Notarization cannot run without a Developer ID
identity.

## Installation and HID permission

1. Download the ZIP or DMG from the [GitHub Releases download page](download.md).
2. Check the matching entry in `SHA256SUMS` before opening the app.
3. Copy `Bibimbap.app` to `/Applications` and launch it.
4. If macOS reports that an unsigned package cannot be opened, do not treat that as a
   signed release: use the documented right-click **Open** flow only for a package you
   intentionally built or received from a trusted test run. A public release should
   use the signed/notarized assets when the repository secrets are configured.
5. For HID access, open **System Settings → Privacy & Security → Input Monitoring**,
   allow Bibimbap, then relaunch it. macOS may not show the prompt again after a
   denial. The application uses the vendor configuration collection (`0xFF05`), not
   the ordinary pointing collection; the full diagnostic procedure is in
   [`docs/troubleshooting.md`](troubleshooting.md).

An installable package does not imply that a particular mouse has been physically
validated. The hardware evidence levels and the operations they cover are maintained
in [`docs/validation-matrix.md`](validation-matrix.md).

## Release page and notes

The stable download page is the repository's
[latest GitHub Release](https://github.com/amassias/Bibimbap/releases/latest). A tag
release attaches the ZIP, DMG, manifest and checksums directly to that page. Release
notes live under [`docs/releases/`](releases/) and are passed to `gh release create` by
the workflow; if notes for a future version are absent, GitHub-generated notes are
used without changing the packaged files.
