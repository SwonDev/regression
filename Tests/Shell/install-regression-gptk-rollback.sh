#!/usr/bin/env bash
# Caracteriza la puerta crítica post-swap: un mismatch GPTK debe invocar rollback explícito.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
INSTALLER="$ROOT/Scripts/install_regression.sh"
WORK_DIR="$(mktemp -d /private/tmp/regression-gptk-rollback-test.XXXXXX)"

cleanup()
{
    find "$WORK_DIR" -depth -delete
}
trap cleanup EXIT

fail()
{
    printf 'FAIL: %s\n' "$*" >&2
    exit 1
}

rollback()
{
    local status="${1:-1}"
    find "$DESTINATION" -depth -delete
    mv "$BACKUP_PATH" "$DESTINATION"
    return "$status"
}

# El test extrae el bloque de producción exacto, no una reimplementación de su condición.
BLOCK="$WORK_DIR/gptk-guard.sh"
# shellcheck disable=SC2016
sed -n \
    '/\/usr\/bin\/cmp -s "$GPTK_PRESERVATION_MANIFEST" "$GPTK_INSTALLED_MANIFEST" || {/,/^[[:space:]]*}/p' \
    "$INSTALLER" > "$BLOCK"
rg -q '^        rollback 1$' "$BLOCK" \
    || fail "la puerta GPTK post-swap no llama rollback explícitamente"
! rg -q 'exit 1' "$BLOCK" \
    || fail "la puerta GPTK volvió a depender de exit en un bloque ||"

OLD_APP="$WORK_DIR/Regression.app.before"
DESTINATION="$WORK_DIR/Regression.app"
BACKUP_PATH="$WORK_DIR/.Regression.app.backup"
mkdir -p "$OLD_APP" "$DESTINATION"
printf 'stable\n' > "$OLD_APP/identity"
printf 'candidate\n' > "$DESTINATION/identity"
mv "$OLD_APP" "$BACKUP_PATH"
printf 'expected\n' > "$WORK_DIR/expected.mtree"
printf 'drifted\n' > "$WORK_DIR/actual.mtree"

fail()
{
    :
}
GPTK_PRESERVATION_MANIFEST="$WORK_DIR/expected.mtree"
GPTK_INSTALLED_MANIFEST="$WORK_DIR/actual.mtree"

# shellcheck disable=SC1090
set +e
# shellcheck disable=SC1090
source "$BLOCK"
guard_status=$?
set -e
[[ $guard_status -ne 0 ]] \
    || { printf 'FAIL: un mismatch GPTK debía fallar\n' >&2; exit 1; }
[[ "$(<"$DESTINATION/identity")" == "stable" ]] \
    || { printf 'FAIL: no se restauró la app anterior\n' >&2; exit 1; }
[[ ! -e "$BACKUP_PATH" ]] \
    || { printf 'FAIL: el backup no se consumió durante rollback\n' >&2; exit 1; }

printf 'PASS: el mismatch GPTK post-swap restaura exactamente la app anterior.\n'
