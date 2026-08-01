#!/usr/bin/env bash
set -euo pipefail

die() {
    printf 'distribution validation error: %s\n' "$*" >&2
    exit 1
}

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
artifact_dir=""

while (($# > 0)); do
    case "$1" in
        --artifacts)
            (($# >= 2)) || die "--artifacts needs a directory"
            artifact_dir="$2"
            shift 2
            ;;
        --help|-h)
            printf '%s\n' "Usage: scripts/validate_distribution.sh [--artifacts DIRECTORY]"
            exit 0
            ;;
        *)
            die "unknown argument: $1"
            ;;
    esac
done

required_files=(
    "$repo_root/README.md"
    "$repo_root/.github/workflows/release.yml"
    "$repo_root/docs/download.md"
    "$repo_root/docs/distribution.md"
    "$repo_root/docs/validation-matrix.md"
    "$repo_root/docs/releases/0.1.0.md"
    "$repo_root/App/Bibimbap.xcodeproj/project.pbxproj"
    "$repo_root/scripts/package_macos.sh"
)
for required_file in "${required_files[@]}"; do
    [[ -f "$required_file" ]] || die "missing required file: $required_file"
done

[[ -x "$repo_root/scripts/package_macos.sh" ]] || die "package script is not executable"
[[ -x "$repo_root/scripts/validate_distribution.sh" ]] || die "validation script is not executable"

project_file="$repo_root/App/Bibimbap.xcodeproj/project.pbxproj"
version="$(awk -F'= ' '/MARKETING_VERSION = / {gsub(/;.*/, "", $2); print $2; exit}' "$project_file")"
[[ "$version" =~ ^[0-9]+\.[0-9]+\.[0-9]+([.-][0-9A-Za-z.-]+)?$ ]] \
    || die "project marketing version is not semver-like: $version"
grep -Eq 'PRODUCT_BUNDLE_IDENTIFIER = gg\.pulsar\.bibimbap;' "$project_file" \
    || die "bundle identifier is not gg.pulsar.bibimbap"
grep -Eq 'MACOSX_DEPLOYMENT_TARGET = 15\.0;' "$project_file" \
    || die "macOS deployment target is not 15.0"

grep -Eq 'docs/download\.md' "$repo_root/README.md" || die "README has no download page link"
grep -Eq 'docs/validation-matrix\.md' "$repo_root/README.md" \
    || die "README has no validation matrix link"
grep -Eqi 'currently ships as source code' "$repo_root/README.md" \
    && die "README still describes source-only distribution"
grep -Eq 'BIB-017' "$repo_root/docs/distribution.md" || die "distribution doc has no BIB-017 reference"
grep -Eq 'BIB-018' "$repo_root/docs/validation-matrix.md" || die "validation matrix has no BIB-018 reference"
grep -Eqi 'not.*performed.*CI|no hardware.*CI|CI.*no hardware' "$repo_root/docs/validation-matrix.md" \
    || die "validation matrix does not state that CI has no physical hardware"
grep -Eqi 'polling.*(above|over|greater).*1 kHz|1 kHz.*(wireless|sans fil)' \
    "$repo_root/docs/validation-matrix.md" \
    || die "validation matrix does not state the >1 kHz wireless limitation"

python3 - "$repo_root" <<'PY'
import json
import sys
from pathlib import Path

root = Path(sys.argv[1])
catalog = json.loads((root / "Sources/PulsarCatalog/Resources/catalog.json").read_text())
families = catalog["families"]
model_count = sum(len(family["mids"]) for family in families)
sensor_names = {family["sensor"]["type"] for family in families}
assert catalog["schemaVersion"] == 2, catalog["schemaVersion"]
assert catalog["sourceVersion"] == "1.3.11", catalog["sourceVersion"]
assert len(families) == 31, len(families)
assert model_count == 127, model_count
assert sensor_names == {"pulsar x1", "3950", "3955"}, sensor_names
assert set(catalog["mouseProductIDs"]) == {"wired", "wireless"}

fixture = json.loads(
    (root / "Tests/PulsarProtocolTests/Fixtures/x2-crazylight-core.json").read_text()
)
assert fixture["device"]["cid"] == 87
assert fixture["device"]["mid"] == 10
assert fixture["device"]["firmware"] == "v3.05"
assert fixture["device"]["connectionType"] == 2
assert fixture["coreRegion"], "fixture core region is empty"
print(f"catalog: {len(families)} families, {model_count} models, sensors={','.join(sorted(sensor_names))}")
print("fixture: CID 87 / MID 10 / firmware v3.05 / wired connection type 2")
PY

if [[ -n "$artifact_dir" ]]; then
    [[ -d "$artifact_dir" ]] || die "artifact directory not found: $artifact_dir"
    artifact_dir="$(cd "$artifact_dir" && pwd)"

    shopt -s nullglob
    manifests=("$artifact_dir"/*-manifest.json)
    zips=("$artifact_dir"/*.zip)
    dmgs=("$artifact_dir"/*.dmg)
    [[ ${#manifests[@]} -eq 1 ]] || die "expected exactly one manifest in $artifact_dir"
    [[ ${#zips[@]} -eq 1 ]] || die "expected exactly one ZIP in $artifact_dir"
    [[ ${#dmgs[@]} -eq 1 ]] || die "expected exactly one DMG in $artifact_dir"
    [[ -f "$artifact_dir/SHA256SUMS" ]] || die "SHA256SUMS is missing"

    (
        cd "$artifact_dir"
        shasum -a 256 -c SHA256SUMS
        unzip -t "$(basename "${zips[0]}")" >/dev/null
    )
    unzip -l "${zips[0]}" | grep -E 'Bibimbap\.app/Contents/MacOS/Bibimbap$' >/dev/null \
        || die "ZIP does not contain the Bibimbap executable"
    hdiutil imageinfo "${dmgs[0]}" >/dev/null \
        || die "DMG cannot be inspected by hdiutil"

    python3 - "${manifests[0]}" "$artifact_dir" <<'PY'
import json
import sys
from pathlib import Path

manifest_path = Path(sys.argv[1])
artifact_dir = Path(sys.argv[2])
manifest = json.loads(manifest_path.read_text())
assert manifest["app"] == "Bibimbap"
assert manifest["bundleIdentifier"] == "gg.pulsar.bibimbap"
assert manifest["version"]
assert manifest["sourceCommit"]
assert isinstance(manifest["signed"], bool)
assert isinstance(manifest["notarized"], bool)
for entry in manifest["artifacts"].values():
    artifact = artifact_dir / entry["name"]
    assert artifact.is_file(), artifact
    assert len(entry["sha256"]) == 64, entry
print(
    f"artifact: version={manifest['version']} arch={manifest['architecture']} "
    f"signed={manifest['signed']} notarized={manifest['notarized']}"
)
PY
fi

printf '%s\n' "distribution metadata is coherent (project version $version)"
