#!/usr/bin/env bash
set -euo pipefail

die() {
    printf 'error: %s\n' "$*" >&2
    exit 1
}

log() {
    printf 'package: %s\n' "$*"
}

usage() {
    cat <<'USAGE'
Usage: scripts/package_macos.sh --version VERSION [options]

Build and package the Bibimbap macOS application as a versioned ZIP and DMG.

Options:
  --version VERSION       Marketing version to embed and use in artifact names.
  --build-number NUMBER   CFBundleVersion; defaults to the commit count.
  --output DIRECTORY      Artifact directory; defaults to .build/distribution.
  --derived-data DIRECTORY
                          Xcode derived-data directory; defaults to a temporary one.
  --arch arm64|x86_64|universal
                          Architecture to build; defaults to arm64.
  --skip-dmg              Do not create a DMG (for local diagnostics only).
  --help                  Show this help.

Signing and notarization are controlled by environment variables. See
docs/distribution.md for the complete contract. With no signing identity, the
script deliberately builds an unsigned app and records that fact in the manifest.
USAGE
}

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
project_path="$repo_root/App/Bibimbap.xcodeproj"
scheme="Bibimbap"
configuration="Release"
version="${BIBIMBAP_VERSION:-}"
build_number="${BIBIMBAP_BUILD_NUMBER:-}"
output_dir="${BIBIMBAP_OUTPUT_DIR:-$repo_root/.build/distribution}"
derived_data="${BIBIMBAP_DERIVED_DATA_DIR:-}"
architecture="${BIBIMBAP_ARCH:-arm64}"
create_dmg=true

while (($# > 0)); do
    case "$1" in
        --version)
            (($# >= 2)) || die "--version needs a value"
            version="$2"
            shift 2
            ;;
        --build-number)
            (($# >= 2)) || die "--build-number needs a value"
            build_number="$2"
            shift 2
            ;;
        --output)
            (($# >= 2)) || die "--output needs a directory"
            output_dir="$2"
            shift 2
            ;;
        --derived-data)
            (($# >= 2)) || die "--derived-data needs a directory"
            derived_data="$2"
            shift 2
            ;;
        --arch)
            (($# >= 2)) || die "--arch needs a value"
            architecture="$2"
            shift 2
            ;;
        --skip-dmg)
            create_dmg=false
            shift
            ;;
        --help|-h)
            usage
            exit 0
            ;;
        *)
            die "unknown argument: $1"
            ;;
    esac
done

[[ -d "$project_path" ]] || die "Xcode project not found: $project_path"
command -v xcodebuild >/dev/null 2>&1 || die "xcodebuild is required"
command -v git >/dev/null 2>&1 || die "git is required"
command -v shasum >/dev/null 2>&1 || die "shasum is required"
command -v zip >/dev/null 2>&1 || die "zip is required"
if [[ "$create_dmg" == true ]]; then
    command -v hdiutil >/dev/null 2>&1 || die "hdiutil is required to create a DMG"
fi

if [[ -z "$version" ]]; then
    version="$(awk -F'= ' '/MARKETING_VERSION = / {gsub(/;.*/, "", $2); print $2; exit}' "$project_path/project.pbxproj")"
fi
[[ "$version" =~ ^[0-9]+\.[0-9]+\.[0-9]+([.-][0-9A-Za-z.-]+)?$ ]] || die "invalid marketing version: $version"

if [[ -z "$build_number" ]]; then
    build_number="$(git -C "$repo_root" rev-list --count HEAD)"
fi
[[ "$build_number" =~ ^[0-9]+$ ]] || die "invalid build number: $build_number"

source_date_epoch="${SOURCE_DATE_EPOCH:-$(git -C "$repo_root" show -s --format=%ct HEAD)}"
[[ "$source_date_epoch" =~ ^[0-9]+$ ]] || die "SOURCE_DATE_EPOCH must be an integer"

case "$architecture" in
    arm64)
        xcode_archs="arm64"
        ;;
    x86_64)
        xcode_archs="x86_64"
        ;;
    universal)
        xcode_archs="arm64 x86_64"
        ;;
    *)
        die "unsupported architecture: $architecture"
        ;;
esac

mkdir -p "$output_dir"
output_dir="$(cd "$output_dir" && pwd)"

work_root="$(mktemp -d "${TMPDIR:-/tmp}/bibimbap-package.XXXXXX")"
trap 'rm -rf "$work_root"' EXIT

if [[ -z "$derived_data" ]]; then
    derived_data="$work_root/DerivedData"
else
    mkdir -p "$derived_data"
    derived_data="$(cd "$derived_data" && pwd)"
fi

signing_identity="${BIBIMBAP_SIGNING_IDENTITY:-${SIGNING_IDENTITY:-}}"
development_team="${BIBIMBAP_DEVELOPMENT_TEAM:-${DEVELOPMENT_TEAM:-}}"

if [[ -n "$signing_identity" ]]; then
    signing_args=(
        "CODE_SIGNING_ALLOWED=YES"
        "CODE_SIGNING_REQUIRED=YES"
        "CODE_SIGN_IDENTITY=$signing_identity"
        "CODE_SIGN_STYLE=Manual"
    )
    if [[ -n "$development_team" ]]; then
        signing_args+=("DEVELOPMENT_TEAM=$development_team")
    fi
    log "building a Developer ID candidate with identity $signing_identity"
else
    signing_args=(
        "CODE_SIGNING_ALLOWED=NO"
        "CODE_SIGNING_REQUIRED=NO"
        "CODE_SIGN_IDENTITY="
        "CODE_SIGN_STYLE=Manual"
    )
    log "no signing identity supplied; building unsigned artifacts"
fi

log "building version $version (build $build_number, arch $architecture)"
xcodebuild \
    -quiet \
    -project "$project_path" \
    -scheme "$scheme" \
    -configuration "$configuration" \
    -sdk macosx \
    -destination 'generic/platform=macOS' \
    -derivedDataPath "$derived_data" \
    ARCHS="$xcode_archs" \
    ONLY_ACTIVE_ARCH=NO \
    MARKETING_VERSION="$version" \
    CURRENT_PROJECT_VERSION="$build_number" \
    "${signing_args[@]}" \
    build

app_path="$derived_data/Build/Products/$configuration/Bibimbap.app"
[[ -d "$app_path" ]] || die "Xcode did not produce $app_path"
info_plist="$app_path/Contents/Info.plist"
[[ -f "$info_plist" ]] || die "application Info.plist is missing"

plist_value() {
    /usr/libexec/PlistBuddy -c "Print :$1" "$info_plist"
}

bundle_identifier="$(plist_value CFBundleIdentifier)"
bundle_version="$(plist_value CFBundleShortVersionString)"
bundle_build="$(plist_value CFBundleVersion)"
[[ "$bundle_identifier" == "gg.pulsar.bibimbap" ]] || die "unexpected bundle identifier: $bundle_identifier"
[[ "$bundle_version" == "$version" ]] || die "bundle version $bundle_version does not match $version"
[[ "$bundle_build" == "$build_number" ]] || die "bundle build $bundle_build does not match $build_number"

signature_info="$(/usr/bin/codesign --display --verbose=4 "$app_path" 2>&1 || true)"
signature_status="unsigned"
if [[ -n "$signing_identity" ]]; then
    printf '%s\n' "$signature_info" | grep -Eq 'Authority=Developer ID Application:' \
        || die "the built app is not signed by a Developer ID Application identity"
    /usr/bin/codesign --verify --deep --strict --verbose=2 "$app_path"
    signature_status="signed"
else
    if printf '%s\n' "$signature_info" | grep -Eq 'Authority='; then
        die "the build has a certificate authority even though no signing identity was supplied"
    fi
    if printf '%s\n' "$signature_info" | grep -Eq 'TeamIdentifier=' \
        && ! printf '%s\n' "$signature_info" | grep -Eq 'TeamIdentifier=not set'; then
        die "the build has a team identifier even though no signing identity was supplied"
    fi
    if ! printf '%s\n' "$signature_info" | grep -Eq 'Signature=adhoc|code object is not signed at all'; then
        die "could not prove that the build is unsigned"
    fi
fi

staging_dir="$work_root/staging"
mkdir -p "$staging_dir"
COPYFILE_DISABLE=1 ditto "$app_path" "$staging_dir/Bibimbap.app"

archive_timestamp="$(date -u -r "$source_date_epoch" '+%Y%m%d%H%M.%S')"
touch_tree() {
    find "$1" -exec touch -h -t "$archive_timestamp" {} +
}
touch_tree "$staging_dir/Bibimbap.app"

base_name="Bibimbap-$version-$architecture"
zip_path="$output_dir/$base_name.zip"
dmg_path="$output_dir/$base_name.dmg"
manifest_path="$output_dir/$base_name-manifest.json"
checksums_path="$output_dir/SHA256SUMS"

create_zip() {
    rm -f "$zip_path"
    (
        cd "$staging_dir"
        LC_ALL=C find Bibimbap.app -print | LC_ALL=C sort | /usr/bin/zip -X -q "$zip_path" -@
    )
}

create_dmg() {
    rm -f "$dmg_path"
    hdiutil create \
        -quiet \
        -volname "Bibimbap $version" \
        -srcfolder "$staging_dir" \
        -ov \
        -format UDZO \
        -imagekey zlib-level=9 \
        "$dmg_path"
}

create_zip
if [[ "$create_dmg" == true ]]; then
    create_dmg
fi

notary_profile="${BIBIMBAP_NOTARY_PROFILE:-}"
notary_key_path="${BIBIMBAP_NOTARY_KEY_PATH:-}"
notary_key_id="${BIBIMBAP_NOTARY_KEY_ID:-}"
notary_issuer="${BIBIMBAP_NOTARY_ISSUER:-}"
apple_id="${BIBIMBAP_APPLE_ID:-}"
apple_team_id="${BIBIMBAP_APPLE_TEAM_ID:-}"
app_specific_password="${BIBIMBAP_APP_SPECIFIC_PASSWORD:-}"

notarization_requested=false
for notary_value in \
    "$notary_profile" "$notary_key_path" "$notary_key_id" "$notary_issuer" \
    "$apple_id" "$apple_team_id" "$app_specific_password"; do
    if [[ -n "$notary_value" ]]; then
        notarization_requested=true
        break
    fi
done

notarization_status="not-requested"
if [[ "$notarization_requested" == true ]]; then
    [[ -n "$signing_identity" ]] || die "notarization credentials require a Developer ID signing identity"
    command -v xcrun >/dev/null 2>&1 || die "xcrun is required for notarization"

    notary_output="$work_root/notary-result.json"
    if [[ -n "$notary_profile" ]]; then
        [[ -z "$notary_key_path$notary_key_id$notary_issuer$apple_id$apple_team_id$app_specific_password" ]] \
            || die "choose one notarization credential mode"
        log "submitting ZIP to notarytool using keychain profile"
        if ! xcrun notarytool submit "$zip_path" \
            --keychain-profile "$notary_profile" \
            --wait \
            --output-format json | tee "$notary_output"; then
            die "notarytool rejected or could not submit the archive"
        fi
    elif [[ -n "$notary_key_path" || -n "$notary_key_id" || -n "$notary_issuer" ]]; then
        [[ -n "$notary_key_path" && -n "$notary_key_id" && -n "$notary_issuer" ]] \
            || die "notary API key mode requires path, key id and issuer"
        [[ -f "$notary_key_path" ]] || die "notary API key file not found: $notary_key_path"
        [[ -z "$apple_id$apple_team_id$app_specific_password" ]] \
            || die "choose one notarization credential mode"
        log "submitting ZIP to notarytool using App Store Connect API key"
        if ! xcrun notarytool submit "$zip_path" \
            --key "$notary_key_path" \
            --key-id "$notary_key_id" \
            --issuer "$notary_issuer" \
            --wait \
            --output-format json | tee "$notary_output"; then
            die "notarytool rejected or could not submit the archive"
        fi
    else
        [[ -n "$apple_id" && -n "$apple_team_id" && -n "$app_specific_password" ]] \
            || die "Apple ID mode requires Apple ID, team id and app-specific password"
        log "submitting ZIP to notarytool using Apple ID credentials"
        if ! xcrun notarytool submit "$zip_path" \
            --apple-id "$apple_id" \
            --team-id "$apple_team_id" \
            --password "$app_specific_password" \
            --wait \
            --output-format json | tee "$notary_output"; then
            die "notarytool rejected or could not submit the archive"
        fi
    fi

    grep -Eq '"status"[[:space:]]*:[[:space:]]*"Accepted"' "$notary_output" \
        || die "notarytool did not report Accepted"
    xcrun stapler staple "$staging_dir/Bibimbap.app"
    xcrun stapler validate "$staging_dir/Bibimbap.app"
    /usr/bin/codesign --verify --deep --strict --verbose=2 "$staging_dir/Bibimbap.app"
    xcrun spctl --assess --type execute --verbose=4 "$staging_dir/Bibimbap.app"

    touch_tree "$staging_dir/Bibimbap.app"
    create_zip
    if [[ "$create_dmg" == true ]]; then
        create_dmg
    fi
    notarization_status="accepted-and-stapled"
fi

zip_hash="$(shasum -a 256 "$zip_path" | awk '{print $1}')"
dmg_hash=""
if [[ "$create_dmg" == true ]]; then
    dmg_hash="$(shasum -a 256 "$dmg_path" | awk '{print $1}')"
fi
source_commit="$(git -C "$repo_root" rev-parse HEAD)"
signed_json=false
notarized_json=false
if [[ "$signature_status" == signed ]]; then
    signed_json=true
fi
if [[ "$notarization_status" == accepted-and-stapled ]]; then
    notarized_json=true
fi

rm -f "$manifest_path" "$checksums_path"
{
    printf '{\n'
    printf '  "app": "Bibimbap",\n'
    printf '  "bundleIdentifier": "%s",\n' "$bundle_identifier"
    printf '  "version": "%s",\n' "$version"
    printf '  "build": "%s",\n' "$build_number"
    printf '  "architecture": "%s",\n' "$architecture"
    printf '  "sourceCommit": "%s",\n' "$source_commit"
    printf '  "sourceDateEpoch": %s,\n' "$source_date_epoch"
    printf '  "signed": %s,\n' "$signed_json"
    printf '  "notarized": %s,\n' "$notarized_json"
    printf '  "notarizationStatus": "%s",\n' "$notarization_status"
    printf '  "artifacts": {\n'
    printf '    "zip": {"name": "%s", "sha256": "%s"}' "$(basename "$zip_path")" "$zip_hash"
    if [[ "$create_dmg" == true ]]; then
        printf ',\n'
        printf '    "dmg": {"name": "%s", "sha256": "%s"}\n' "$(basename "$dmg_path")" "$dmg_hash"
    else
        printf '\n'
    fi
    printf '  }\n'
    printf '}\n'
} > "$manifest_path"

{
    printf '%s  %s\n' "$zip_hash" "$(basename "$zip_path")"
    if [[ "$create_dmg" == true ]]; then
        printf '%s  %s\n' "$dmg_hash" "$(basename "$dmg_path")"
    fi
    printf '%s  %s\n' "$(shasum -a 256 "$manifest_path" | awk '{print $1}')" "$(basename "$manifest_path")"
} > "$checksums_path"

log "created $(basename "$zip_path")"
if [[ "$create_dmg" == true ]]; then
    log "created $(basename "$dmg_path")"
fi
log "created $(basename "$manifest_path")"
log "created $(basename "$checksums_path")"
log "signature=$signature_status notarization=$notarization_status"
