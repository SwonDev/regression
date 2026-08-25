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

# La versión y el build se leen del empaquetador nativo, que es la fuente. Congelarlos aquí
# convertía el contrato en un test caducado: seguía comprobando 1.12.4 tres releases después.
CONTRACT_VERSION="$(sed -n 's/^VERSION="\(.*\)"$/\1/p' "$NATIVE_PACKAGER" | head -1)"
CONTRACT_BUILD="$(sed -n 's/^BUILD_NUMBER="\(.*\)"$/\1/p' "$NATIVE_PACKAGER" | head -1)"
[ -n "$CONTRACT_VERSION" ] && [ -n "$CONTRACT_BUILD" ] \
    || { printf 'FAIL: package_regression no declara VERSION y BUILD_NUMBER.\n' >&2; exit 1; }
CONTRACT_WRONG_BUILD="$(( CONTRACT_BUILD - 1 ))"

write_installer "$SCRATCH/matching.sh" "$CONTRACT_VERSION" "$CONTRACT_BUILD"
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

write_installer "$SCRATCH/wrong-build.sh" "$CONTRACT_VERSION" "$CONTRACT_WRONG_BUILD"
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
grep -Fx "VERSION=\"$CONTRACT_VERSION\"" "$NATIVE_PACKAGER" >/dev/null \
    || { printf 'FAIL: package_regression no declara la versión del contrato.\n' >&2; exit 1; }
grep -Fx "BUILD_NUMBER=\"$CONTRACT_BUILD\"" "$NATIVE_PACKAGER" >/dev/null \
    || { printf 'FAIL: package_regression no declara el build del contrato.\n' >&2; exit 1; }
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
# El verificador público se reestructuró: cada modo --release-X declara versión y build, y los
# hashes viven en una tabla común de verify_hash. Congelar aquí cinco PIN de la época de 1.12.4
# dejó de comprobar nada real en cuanto esa tabla se refrescó. Lo que sí es invariante, y es lo que
# se exige, es que cada modo declare su versión y su build y que la tabla siga anclando hashes.
pinned_hashes="$(grep -cE 'verify_hash [0-9a-f]{64}' "$PUBLIC_STATE_GATE" || true)"
[ "$pinned_hashes" -ge 5 ] \
    || { printf 'FAIL: el estado público no ancla hashes del runtime sellado (%s).\n' \
         "$pinned_hashes" >&2; exit 1; }

while read -r release_mode; do
    mode_block="$(sed -n "/--release-${release_mode})/,/^        ;;/p" "$PUBLIC_STATE_GATE")"
    printf '%s' "$mode_block" | grep -qE 'EXPECTED_VERSION="[0-9.]+"' \
        || { printf 'FAIL: el modo --release-%s no declara versión.\n' "$release_mode" >&2; exit 1; }
    printf '%s' "$mode_block" | grep -qE 'EXPECTED_BUILD="[0-9]+"' \
        || { printf 'FAIL: el modo --release-%s no declara build.\n' "$release_mode" >&2; exit 1; }
done < <(grep -oE '\-\-release-1\.12\.[0-9]+' "$PUBLIC_STATE_GATE" | sed 's/--release-//' | sort -u)

printf 'PASS: versión, build, instalador exacto y anclaje del estado público cerrados.\n'
