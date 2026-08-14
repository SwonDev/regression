#!/usr/bin/env bash
# La release 1.12 sólo puede incorporar el builder público ya sellado. Un build
# fresco no es una autoridad de release aunque compile correctamente.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
PACKAGER="$ROOT/Scripts/package_release.sh"
VERIFIER="$ROOT/build/verify-sealed-public-runtime-1.12.sh"
SEALED_BUILDER="$ROOT/build/release-1.12.0/wine64-public"
FRESH_BUILDER="$ROOT/build/wine64-dist"
SCRATCH="$(mktemp -d /private/tmp/regression-release-sealed-runtime.XXXXXX)"

cleanup() {
    find "$SCRATCH" -mindepth 1 -depth -delete
    rmdir "$SCRATCH"
}
trap cleanup EXIT

fail() {
    printf 'FAIL: %s\n' "$*" >&2
    exit 1
}

expect_failure() {
    local description="$1" expected="$2"
    shift 2
    local output status
    set +e
    output="$("$@" 2>&1)"
    status=$?
    set -e
    [[ $status -ne 0 ]] || fail "$description debía fallar"
    /usr/bin/grep -Fq "$expected" <<< "$output" \
        || fail "$description falló sin el diagnóstico esperado: $output"
}

[[ -d "$SEALED_BUILDER" && -d "$FRESH_BUILDER" ]] \
    || fail "faltan los builders sellado o fresco de la regresión"

SEALED_DEFAULT="PUBLIC_WINE_BUILD=\"\${REGRESSION_PUBLIC_WINE_BUILD:-\$ROOT/build/release-1.12.0/wine64-public}\""
/usr/bin/grep -Fx "$SEALED_DEFAULT" \
    "$PACKAGER" >/dev/null \
    || fail "la release 1.12 no usa el builder público sellado por defecto"

"$VERIFIER" >/dev/null
expect_failure "un builder fresco no puede alimentar la release" \
    'cambió el binario sellado del builder público 1.12' \
    env \
        REGRESSION_PUBLIC_WINE_BUILD="$FRESH_BUILDER" \
        "$VERIFIER"

DRIFT_BUILDER="$SCRATCH/wine64-public"
for relative in tools/wine/wine server/wineserver loader/wine dlls/ntdll/ntdll.so; do
    mkdir -p "$DRIFT_BUILDER/$(dirname "$relative")"
    cp -c "$SEALED_BUILDER/$relative" "$DRIFT_BUILDER/$relative"
done
printf 'drift\n' >> "$DRIFT_BUILDER/tools/wine/wine"
expect_failure "un builder sellado derivado no puede alimentar la release" \
    'cambió el binario sellado del builder público 1.12: tools/wine/wine' \
    env REGRESSION_PUBLIC_WINE_BUILD="$DRIFT_BUILDER" "$VERIFIER"

# El builder sellado es preconstruido; las fuentes posteriores lo hacen aparecer
# pendiente a make -q. Eso no cambia su autoridad ni puede disparar un rebuild.
set +e
make -q -C "$SEALED_BUILDER" \
    dlls/ntdll/ntdll.so loader/wine tools/wine/wine server/wineserver
make_query_status=$?
set -e
[[ $make_query_status -eq 1 ]] \
    || fail "la regresión esperaba make -q=1 para el builder sellado preconstruido"
"$VERIFIER" >/dev/null

for pin in \
    668a88221884f4e62f3d40bed4a125a45e2e745c1d56610f8e3a33273a219299 \
    173c4926f53d0551d85ee6efe48e641867230a27bda7fc6a226ac484012d13fb \
    48ae6acb327148f3d8f02afcc93d8f8e61ab333b1dec752918244e58828cf5c9 \
    f3ccf2a487d8999659a1e641b043b916487851c1540362a0a983cdf0fd0bb8cc
do
    /usr/bin/grep -Fq "$pin" "$VERIFIER" \
        || fail "falta el PIN raw 1.12 del builder sellado: $pin"
done

/usr/bin/grep -Fq 'build/apply-wine-patches.sh' "$PACKAGER" \
    || fail "la release no verifica la serie idempotente de parches"
/usr/bin/grep -Fq 'build/verify-sealed-public-runtime-1.12.sh' "$PACKAGER" \
    || fail "la release no acredita el builder público sellado antes de copiarlo"
if /usr/bin/grep -Fq 'build/build-public-wine-runtime.sh' "$PACKAGER"; then
    fail "la release todavía puede reconstruir un builder en la ruta pública 1.12"
fi

printf 'PASS: release 1.12 acepta el builder sellado preconstruido y rechaza fresh/drift.\n'
