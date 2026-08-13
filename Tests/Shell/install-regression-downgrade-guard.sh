#!/usr/bin/env bash
# shellcheck disable=SC2016
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
INSTALLER="$ROOT/Scripts/install_regression.sh"
SCRATCH="$(mktemp -d /private/tmp/regression-downgrade-guard.XXXXXX)"

cleanup()
{
    find "$SCRATCH" -depth -delete
}
trap cleanup EXIT

fail_test()
{
    printf 'FAIL: %s\n' "$*" >&2
    exit 1
}

HELPERS="$SCRATCH/helpers.sh"
sed -n \
    '/^semantic_version_compare()/,/^}/p; /^guard_destination_not_newer()/,/^}/p' \
    "$INSTALLER" > "$HELPERS"
grep -Fq 'guard_destination_not_newer()' "$HELPERS" \
    || fail_test "el instalador no expone la puerta de downgrade"

fail() { printf '%s\n' "$*" >&2; }
path_chain_is_physical() { return 0; }
# shellcheck disable=SC1090
source "$HELPERS"

make_destination()
{
    local version="$1"
    local destination="$SCRATCH/Regression.app"
    find "$destination" -depth -delete 2>/dev/null || true
    mkdir -p "$destination/Contents"
    plutil -create xml1 "$destination/Contents/Info.plist"
    plutil -insert CFBundleIdentifier -string local.regression.launcher \
        "$destination/Contents/Info.plist"
    plutil -insert CFBundleShortVersionString -string "$version" \
        "$destination/Contents/Info.plist"
    printf '%s\n' "$destination"
}

destination="$(make_destination 1.11.0)"
set +e
downgrade_output="$(guard_destination_not_newer "$destination" 1.10.1 2>&1)"
downgrade_status=$?
set -e
[[ $downgrade_status -ne 0 ]] || fail_test "1.10.1 pudo sustituir 1.11.0"
grep -Fq 'anterior a la instalada' <<< "$downgrade_output" \
    || fail_test "el downgrade no devolvió un diagnóstico explícito"

guard_destination_not_newer "$destination" 1.11.0 \
    || fail_test "la reparación de la misma versión quedó bloqueada"

destination="$(make_destination 1.10.1)"
guard_destination_not_newer "$destination" 1.11.0 \
    || fail_test "una actualización posterior quedó bloqueada"

destination="$(make_destination version-inválida)"
if guard_destination_not_newer "$destination" 1.11.0 >/dev/null 2>&1; then
    fail_test "una identidad instalada no semántica se aceptó"
fi

missing="$SCRATCH/missing.app"
guard_destination_not_newer "$missing" 1.11.0 \
    || fail_test "una instalación nueva quedó bloqueada"

guard_line="$(grep -nF 'guard_destination_not_newer "$DESTINATION" "$VERSION"' \
    "$INSTALLER" | head -n 1 | cut -d: -f1)"
download_line="$(grep -nF 'step "2/7 Descarga e integridad del release"' \
    "$INSTALLER" | head -n 1 | cut -d: -f1)"
[[ -n "$guard_line" && -n "$download_line" && "$guard_line" -lt "$download_line" ]] \
    || fail_test "la puerta de downgrade no precede a la descarga y sustitución"

grep -Fq 'mv "$BACKUP_PATH" "$DESTINATION"' "$INSTALLER" \
    || fail_test "el rollback interno dejó de restaurar el backup autenticado directamente"
if grep -Eq 'ALLOW_DOWNGRADE|allow-downgrade|REGRESSION_.*DOWNGRADE' "$INSTALLER"; then
    fail_test "el instalador expone un bypass externo de downgrade"
fi

printf 'PASS: downgrade bloqueado, reparación igual y actualización posterior permitidas.\n'
