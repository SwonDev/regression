#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
PACKAGER="$ROOT/Scripts/package_release.sh"
NATIVE_PACKAGER="$ROOT/Scripts/package_regression.sh"
PUBLIC_STATE_GATE="$ROOT/build/verify-public-installed-state.sh"
SCRATCH="$(mktemp -d /private/tmp/regression-release-contract-test.XXXXXX)"

cleanup() {
    find "$SCRATCH" -mindepth 1 -depth -delete
    rmdir "$SCRATCH"
}
trap cleanup EXIT

write_installer() {
    local path="$1" version="$2" build="$3"
    cat > "$path" <<EOF
#!/bin/bash
set -euo pipefail
VERSION="$version"
BUILD_NUMBER="$build"
EOF
    chmod 755 "$path"
}

write_installer "$SCRATCH/matching.sh" 1.11.0 37
REGRESSION_RELEASE_CONTRACT_ONLY=1 \
REGRESSION_RELEASE_INSTALLER_SOURCE="$SCRATCH/matching.sh" \
    "$PACKAGER" >/dev/null

write_installer "$SCRATCH/wrong-version.sh" 1.10.1 37
if REGRESSION_RELEASE_CONTRACT_ONLY=1 \
    REGRESSION_RELEASE_INSTALLER_SOURCE="$SCRATCH/wrong-version.sh" \
    "$PACKAGER" >/dev/null 2>&1; then
    printf 'FAIL: se aceptó un instalador de otra versión.\n' >&2
    exit 1
fi

write_installer "$SCRATCH/wrong-build.sh" 1.11.0 36
if REGRESSION_RELEASE_CONTRACT_ONLY=1 \
    REGRESSION_RELEASE_INSTALLER_SOURCE="$SCRATCH/wrong-build.sh" \
    "$PACKAGER" >/dev/null 2>&1; then
    printf 'FAIL: se aceptó un instalador de otro build.\n' >&2
    exit 1
fi

printf 'payload-hash  ./lib/plugin.dylib\n' > "$SCRATCH/manifest.sha256"
manifest_hash="$(shasum -a 256 "$SCRATCH/manifest.sha256" | awk '{print $1}')"
cat > "$SCRATCH/catalog-matching.swift" <<EOF
private static let windowsMediaPublicManifestSHA256: String? = "$manifest_hash"
EOF
REGRESSION_RELEASE_MANIFEST_PIN_ONLY=1 \
REGRESSION_RELEASE_INSTALLER_SOURCE="$SCRATCH/matching.sh" \
REGRESSION_RELEASE_COMPONENT_HEALTH_SOURCE="$SCRATCH/catalog-matching.swift" \
REGRESSION_RELEASE_WINDOWS_MEDIA_MANIFEST="$SCRATCH/manifest.sha256" \
    "$PACKAGER" >/dev/null

cat > "$SCRATCH/catalog-pending.swift" <<'EOF'
private static let windowsMediaPublicManifestSHA256: String? = nil
EOF
if REGRESSION_RELEASE_MANIFEST_PIN_ONLY=1 \
    REGRESSION_RELEASE_INSTALLER_SOURCE="$SCRATCH/matching.sh" \
    REGRESSION_RELEASE_COMPONENT_HEALTH_SOURCE="$SCRATCH/catalog-pending.swift" \
    REGRESSION_RELEASE_WINDOWS_MEDIA_MANIFEST="$SCRATCH/manifest.sha256" \
    "$PACKAGER" >/dev/null 2>&1; then
    printf 'FAIL: se aceptó un catálogo público sin hash medido.\n' >&2
    exit 1
fi

cat > "$SCRATCH/catalog-wrong.swift" <<'EOF'
private static let windowsMediaPublicManifestSHA256: String? = "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"
EOF
if REGRESSION_RELEASE_MANIFEST_PIN_ONLY=1 \
    REGRESSION_RELEASE_INSTALLER_SOURCE="$SCRATCH/matching.sh" \
    REGRESSION_RELEASE_COMPONENT_HEALTH_SOURCE="$SCRATCH/catalog-wrong.swift" \
    REGRESSION_RELEASE_WINDOWS_MEDIA_MANIFEST="$SCRATCH/manifest.sha256" \
    "$PACKAGER" >/dev/null 2>&1; then
    printf 'FAIL: se aceptó un PIN público distinto del candidato real.\n' >&2
    exit 1
fi

grep -F "INSTALLER=\"\$OUTPUT_DIR/install_regression.sh\"" "$PACKAGER" >/dev/null \
    || { printf 'FAIL: package_release no emite el instalador oficial.\n' >&2; exit 1; }
grep -F 'ASSET_NAME="Regression-${VERSION}-macos-arm64.tar.gz"' "$PACKAGER" >/dev/null \
    || { printf 'FAIL: package_release no emite el gzip autocontenido de macOS.\n' >&2; exit 1; }
grep -F 'ASSET_NAME="Regression-${VERSION}-macos-arm64.tar.gz"' \
    "$ROOT/Scripts/install_regression.sh" >/dev/null \
    || { printf 'FAIL: el instalador no solicita el gzip canónico 1.11.\n' >&2; exit 1; }
grep -F 'verify-current-release-input.sh' "$PACKAGER" >/dev/null \
    || { printf 'FAIL: package_release no verifica el staging público actual.\n' >&2; exit 1; }
for release_build_gate in \
    'swift build -c release -Xswiftc -warnings-as-errors --product Regression' \
    'swift build -c release -Xswiftc -warnings-as-errors --product regressionctl'
do
    grep -F "$release_build_gate" "$PACKAGER" >/dev/null \
        || { printf 'FAIL: falta compilación productiva WAE antes del staging: %s\n' \
            "$release_build_gate" >&2; exit 1; }
done
if grep -F 'REGRESSION_RELEASE_SWIFT_BIN_DIR' "$PACKAGER" >/dev/null; then
    printf 'FAIL: package_release permite sustituir los productos Swift Release.\n' >&2
    exit 1
fi
grep -F "cmp -s \"\$INSTALLER_SOURCE\" \"\$INSTALLER_TEMP\"" "$PACKAGER" >/dev/null \
    || { printf 'FAIL: package_release no exige copia byte a byte.\n' >&2; exit 1; }
grep -Fx 'VERSION="1.11.0"' "$NATIVE_PACKAGER" >/dev/null \
    || { printf 'FAIL: package_regression no declara 1.11.0.\n' >&2; exit 1; }
grep -Fx 'BUILD_NUMBER="37"' "$NATIVE_PACKAGER" >/dev/null \
    || { printf 'FAIL: package_regression no declara build 37.\n' >&2; exit 1; }
grep -F 'NATIVE_BACKUP_PATHS+=(Contents/SharedSupport/bin/install-apple-gptk-component)' \
    "$NATIVE_PACKAGER" >/dev/null \
    || { printf 'FAIL: el backup nativo omite el instalador GPTK.\n' >&2; exit 1; }
if grep -F 'set_plist_value NSAppleEventsUsageDescription' "$NATIVE_PACKAGER" >/dev/null; then
    printf 'FAIL: el bundle sigue solicitando Apple Events.\n' >&2
    exit 1
fi
for historical_mode in --baseline-1.10.0 --release-1.10.1; do
    grep -F -- "$historical_mode)" "$PUBLIC_STATE_GATE" >/dev/null \
        || { printf 'FAIL: se perdió el modo histórico %s.\n' "$historical_mode" >&2; exit 1; }
done
grep -F -- '--release-1.11.0)' "$PUBLIC_STATE_GATE" >/dev/null \
    || { printf 'FAIL: falta el seam público 1.11.0.\n' >&2; exit 1; }

printf 'PASS: versión, build, instalador exacto y PIN público derivado están cerrados.\n'
