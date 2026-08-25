#!/usr/bin/env bash
set -Eeuo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
CONTRACT="$ROOT/build/crossover-foss-26.3.0.contract"
# El tar oficial vale desde la caché del operador o desde la raíz del checkout:
# su SHA-256 se acredita contra el contrato, así que la ruta no es la autoridad.
DEFAULT_ARCHIVE="$HOME/Library/Caches/Regression/FOSS/crossover-sources-26.3.0.tar.gz"
[[ -f "$DEFAULT_ARCHIVE" ]] || DEFAULT_ARCHIVE="$ROOT/crossover-sources-26.3.0.tar.gz"
ARCHIVE="${1:-${REGRESSION_CROSSOVER_FOSS_ARCHIVE:-$DEFAULT_ARCHIVE}}"
# El árbol real se extrae del tar, nunca se toma de sources-26.3.0/ del checkout: ese árbol ya
# lleva la serie aplicada a mano y con los parches regenerados deja de detectarse como aplicado y
# de aplicarse limpiamente, así que el test fallaba sin que el build estuviera roto (regla 27).
REAL_WINE_SOURCE="${REGRESSION_WINE_SOURCE:-}"
TMP_ROOT="$(/usr/bin/mktemp -d /tmp/regression-wine-patch-gptk.XXXXXX)"
trap '/usr/bin/find "$TMP_ROOT" -depth -delete' EXIT

fail()
{
    printf 'FAIL: %s\n' "$*" >&2
    exit 1
}

contract_value()
{
    local key="$1"
    /usr/bin/awk -F= -v key="$key" '$1 == key { print substr($0, index($0, "=") + 1); exit }' \
        "$CONTRACT"
}

assert_indexed_only()
{
    local source="$1"
    local loader="$source/dlls/ntdll/unix/loader.c"

    /usr/bin/grep -F 'REGRESSION_EXTERNAL_D3DMETAL_ROUTE_%u_EXECUTABLE' "$loader" >/dev/null \
        || fail "el loader no conserva el basename GPTK indexado: $source"
    /usr/bin/grep -F 'REGRESSION_EXTERNAL_D3DMETAL_ROUTE_%u_WINE_ROOT' "$loader" >/dev/null \
        || fail "el loader no conserva la raíz GPTK indexada: $source"
    if /usr/bin/grep -E 'REGRESSION_EXTERNAL_D3DMETAL_(EXECUTABLE|WINE_ROOT)' "$loader" \
        >/dev/null; then
        fail "el loader aún acepta el par GPTK genérico: $source"
    fi
}

apply_twice()
{
    local source="$1"

    REGRESSION_WINE_SOURCE="$source" "$ROOT/build/apply-wine-patches.sh" >/dev/null
    assert_indexed_only "$source"
    REGRESSION_WINE_SOURCE="$source" "$ROOT/build/apply-wine-patches.sh" >/dev/null
    assert_indexed_only "$source"
}

[[ -f "$CONTRACT" ]] || fail "falta el contrato FOSS"
[[ -f "$ARCHIVE" ]] || fail "falta el tar FOSS oficial: $ARCHIVE"
if [[ -z "$REAL_WINE_SOURCE" ]]; then
    REAL_WINE_SOURCE="$TMP_ROOT/real/wine"
    /bin/mkdir -p "$TMP_ROOT/real"
    /usr/bin/tar xzf "$ARCHIVE" -C "$TMP_ROOT/real" --strip-components=1 sources/wine
fi
[[ -d "$REAL_WINE_SOURCE" ]] || fail "falta el árbol Wine real: $REAL_WINE_SOURCE"

expected_archive_hash="$(contract_value archive_sha256)"
actual_archive_hash="$(/usr/bin/shasum -a 256 "$ARCHIVE" | /usr/bin/awk '{ print $1 }')"
[[ "$actual_archive_hash" == "$expected_archive_hash" ]] \
    || fail "el tar no coincide con el SHA-256 oficial"

# Gate del árbol de trabajo preexistente: la primera ejecución migra si aún
# conserva el contrato legado; la segunda demuestra idempotencia real.
apply_twice "$REAL_WINE_SOURCE"

# Gate independiente desde los bytes oficiales sin parches.
/usr/bin/tar -xzf "$ARCHIVE" -C "$TMP_ROOT" sources/wine
CLEAN_WINE_SOURCE="$TMP_ROOT/sources/wine"
expected_loader_hash="$(/usr/bin/awk -F'|' \
    '$1 == "baseline=wine/dlls/ntdll/unix/loader.c" { print $2; exit }' "$CONTRACT")"
actual_loader_hash="$(/usr/bin/shasum -a 256 \
    "$CLEAN_WINE_SOURCE/dlls/ntdll/unix/loader.c" | /usr/bin/awk '{ print $1 }')"
[[ "$actual_loader_hash" == "$expected_loader_hash" ]] \
    || fail "el loader del tar no es el baseline oficial limpio"
apply_twice "$CLEAN_WINE_SOURCE"

printf 'PASS: la serie GPTK migra el árbol real y construye dos veces desde el tar limpio.\n'
