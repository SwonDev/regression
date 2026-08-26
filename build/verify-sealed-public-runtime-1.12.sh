#!/usr/bin/env bash
# Verifica el artefacto público 1.12 ya producido. No lo configura ni recompila:
# package_release es consumidor del builder sellado, no su productor.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
PUBLIC_BUILD="${REGRESSION_PUBLIC_WINE_BUILD:-$ROOT/build/release-1.12.0/wine64-public}"
PUBLIC_PREFIX="/Applications/Regression.app/Contents/SharedSupport/wine-root"

fail() { printf 'ERROR: %s\n' "$*" >&2; exit 1; }

verify_raw_runtime_file() {
    local expected="$1" relative="$2" path actual mode
    path="$PUBLIC_BUILD/$relative"
    [[ -f "$path" && ! -L "$path" ]] \
        || fail "falta el binario sellado del builder público 1.12: $relative"
    mode="$(stat -f '%Lp' "$path")"
    [[ "$mode" == "755" ]] \
        || fail "el binario sellado debe tener modo 755: $relative"
    file "$path" | grep -q 'Mach-O 64-bit.*x86_64' \
        || fail "el binario sellado no es Mach-O x86_64: $relative"
    actual="$(shasum -a 256 "$path" | awk '{print $1}')"
    [[ "$actual" == "$expected" ]] \
        || fail "cambió el binario sellado del builder público 1.12: $relative"
}

[[ -d "$PUBLIC_BUILD" && ! -L "$PUBLIC_BUILD" ]] \
    || fail "falta el builder público sellado 1.12: $PUBLIC_BUILD"

verify_raw_runtime_file \
    b1d413fdb57e84408a9d9b990570808d523eb5f90ce282e34255971bd9c86074 \
    tools/wine/wine
verify_raw_runtime_file \
    2bfecf1bb9f75f8b2d1ff8251827b3b9dc110946739d0c747fe9a9f4347ed48e \
    server/wineserver
verify_raw_runtime_file \
    220650ffd61f9d612a391e9b5ab8be06d052cd85c0fb5586288737f522dcb06a \
    loader/wine
verify_raw_runtime_file \
    18d0f87b09e5735a7c819844488234f9a0f25c8dc1cc144e0be80733e1604cdc \
    dlls/ntdll/ntdll.so

NTDLL="$PUBLIC_BUILD/dlls/ntdll/ntdll.so"
WRAPPER="$PUBLIC_BUILD/tools/wine/wine"
for required in \
    "$PUBLIC_PREFIX/bin" \
    "$PUBLIC_PREFIX/lib/wine" \
    "$PUBLIC_PREFIX/share/wine" \
    REGRESSION_BOOTSTRAP_REDIRECT_COUNT \
    REGRESSION_EXTERNAL_D3DMETAL_ROUTE_COUNT \
    REGRESSION_WINDOWS_MEDIA_PROFILE \
    REGRESSION_PROCESS_DLL_ISOLATION_ROUTE_COUNT \
    compiled-repair-activations-v2.tsv
do
    strings -a "$NTDLL" | grep -F "$required" >/dev/null \
        || fail "ntdll público sellado no contiene el contrato requerido: $required"
done
for required in "$PUBLIC_PREFIX/bin" "$PUBLIC_PREFIX/lib"; do
    strings -a "$WRAPPER" | grep -F "$required" >/dev/null \
        || fail "el wrapper Wine público sellado no contiene la ruta requerida: $required"
done
if strings -a "$NTDLL" \
    | grep -E 'REGRESSION_EXTERNAL_D3DMETAL_(EXECUTABLE|WINE_ROOT)' >/dev/null; then
    fail "ntdll público sellado aún acepta la ruta GPTK genérica heredada"
fi
if strings -a \
    "$PUBLIC_BUILD/tools/wine/wine" \
    "$PUBLIC_BUILD/server/wineserver" \
    "$PUBLIC_BUILD/loader/wine" \
    "$NTDLL" \
    | grep -E '/Users/[^/]+/.*Regression\.app' >/dev/null; then
    fail "los binarios públicos sellados todavía contienen un prefijo local"
fi

printf 'Runtime público sellado 1.12 verificado: %s\n' "$PUBLIC_BUILD"
