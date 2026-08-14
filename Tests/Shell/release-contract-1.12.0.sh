#!/usr/bin/env bash
# shellcheck disable=SC2016
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

write_installer "$SCRATCH/matching.sh" 1.12.3 41
REGRESSION_RELEASE_CONTRACT_ONLY=1 \
REGRESSION_RELEASE_INSTALLER_SOURCE="$SCRATCH/matching.sh" \
    "$PACKAGER" >/dev/null
REGRESSION_RELEASE_CONTRACT_ONLY=1 "$PACKAGER" >/dev/null

write_installer "$SCRATCH/wrong-version.sh" 1.11.0 41
if REGRESSION_RELEASE_CONTRACT_ONLY=1 \
    REGRESSION_RELEASE_INSTALLER_SOURCE="$SCRATCH/wrong-version.sh" \
    "$PACKAGER" >/dev/null 2>&1; then
    printf 'FAIL: se aceptó un instalador de otra versión.\n' >&2
    exit 1
fi

write_installer "$SCRATCH/wrong-build.sh" 1.12.3 40
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
    || { printf 'FAIL: el instalador no solicita el gzip canónico de la release.\n' >&2; exit 1; }
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
grep -Fx 'VERSION="1.12.3"' "$NATIVE_PACKAGER" >/dev/null \
    || { printf 'FAIL: package_regression no declara 1.12.3.\n' >&2; exit 1; }
grep -Fx 'BUILD_NUMBER="41"' "$NATIVE_PACKAGER" >/dev/null \
    || { printf 'FAIL: package_regression no declara build 41.\n' >&2; exit 1; }
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
grep -F -- '--release-1.12.0)' "$PUBLIC_STATE_GATE" >/dev/null \
    || { printf 'FAIL: falta el seam público 1.12.0.\n' >&2; exit 1; }
grep -F -- '--release-1.12.1)' "$PUBLIC_STATE_GATE" >/dev/null \
    || { printf 'FAIL: falta el seam público 1.12.1.\n' >&2; exit 1; }
grep -F -- '--release-1.12.2)' "$PUBLIC_STATE_GATE" >/dev/null \
    || { printf 'FAIL: falta el seam público 1.12.2.\n' >&2; exit 1; }
grep -F -- '--release-1.12.3)' "$PUBLIC_STATE_GATE" >/dev/null \
    || { printf 'FAIL: falta el seam público 1.12.3.\n' >&2; exit 1; }
for installed_pin in \
    8e8aad9628e9eb4f85848aba0538d10bd3c4fa242e7d96f6a826b93830329eff \
    fed13faa895c9ea5896a6497490db26674c3dca2a318e3389d8e43ba3e00f552 \
    8d14fb9d6d9730c300ba16b5997d98218a2a40a78008d60f3a6edb719f328db3 \
    5636a6505e872c8d185d8db7ced2d4aa8e9057e81c4c579e4b623009f9c2857b \
    687717fa95835146dfe4b45c6a29d7a82fb37742810fdb4213908dd3176b82e9
do
    grep -F "$installed_pin" "$PUBLIC_STATE_GATE" >/dev/null \
        || { printf 'FAIL: el estado público 1.12 omite el PIN %s.\n' "$installed_pin" >&2; exit 1; }
done

printf 'PASS: versión, build, instalador exacto y PIN público derivado están cerrados.\n'
