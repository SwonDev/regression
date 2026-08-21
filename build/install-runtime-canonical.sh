#!/usr/bin/env bash
# Instala en el bundle canónico un runtime recién compilado, de forma ATÓMICA.
#
# Sustituir el runtime y refrescar los PIN es una sola operación: entre medias, la
# app queda con `ntdll.so` nuevo y `ComponentHealth` viejo, y la puerta de
# lanzamiento (`RegressionLaunchComponentGate.requireReady`) se niega a abrir
# juegos. Hacerlo en pasos sueltos deja la instalación rota si algo se detiene.
#
# Este script hace todo o revierte todo. Cualquier fallo restaura el estado
# anterior: runtime, PIN, fuentes tocadas por el refresco y binarios del bundle.
#
#   build/install-runtime-canonical.sh [--builder RUTA] [--bundle RUTA]
set -Eeuo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
BUNDLE="${REGRESSION_APP_PATH:-/Applications/Regression.app}"
BUILDER="$ROOT/build/wine64-canonical"

while [[ $# -gt 0 ]]; do
    case "$1" in
        --builder) BUILDER="$2"; shift 2 ;;
        --bundle) BUNDLE="$2"; shift 2 ;;
        *) printf 'ERROR: opción desconocida: %s\n' "$1" >&2; exit 64 ;;
    esac
done

WINE_ROOT="$BUNDLE/Contents/SharedSupport/wine-root"
STAMP="$(date +%Y%m%d-%H%M%S)"
SNAP="$ROOT/backups/runtime-install-$STAMP"

step() { printf '\n== %s ==\n' "$*"; }
fail() { printf 'ERROR: %s\n' "$*" >&2; exit 1; }

# --- precondiciones ----------------------------------------------------------
[[ -d "$WINE_ROOT" ]] || fail "el bundle no contiene runtime: $WINE_ROOT"
[[ -f "$BUILDER/dlls/ntdll/ntdll.so" ]] || fail "falta el builder: $BUILDER"
if pgrep -f "wineserver" >/dev/null 2>&1; then
    fail "hay un wineserver activo; cierra Steam antes de tocar el runtime"
fi

# --- instantánea para rollback ----------------------------------------------
step "Instantánea en ${SNAP#$ROOT/}"
mkdir -p "$SNAP/bundle"
cp "$WINE_ROOT/lib/wine/x86_64-unix/ntdll.so" "$SNAP/ntdll.so"
cp "$BUNDLE/Contents/MacOS/Regression" "$SNAP/bundle/Regression"
cp "$BUNDLE/Contents/SharedSupport/bin/regressionctl" "$SNAP/bundle/regressionctl"
cp "$ROOT/build/release-runtime-pins.txt" "$SNAP/release-runtime-pins.txt"
cp "$ROOT/Sources/RegressionCore/ComponentHealth.swift" "$SNAP/ComponentHealth.swift"
cp "$ROOT/Tests/RegressionCoreTests/ComponentHealthTests.swift" "$SNAP/ComponentHealthTests.swift"
for v in verify-protected-state.sh verify-public-installed-state.sh \
         verify-public-runtime-transform-1.12.sh verify-release-asset.sh; do
    cp "$ROOT/build/$v" "$SNAP/$v"
done
printf 'ok\n' > "$SNAP/.complete"

rollback() {
    printf '\n!! Revirtiendo al estado anterior\n' >&2
    cp "$SNAP/ntdll.so" "$WINE_ROOT/lib/wine/x86_64-unix/ntdll.so" || true
    cp "$SNAP/bundle/Regression" "$BUNDLE/Contents/MacOS/Regression" || true
    cp "$SNAP/bundle/regressionctl" "$BUNDLE/Contents/SharedSupport/bin/regressionctl" || true
    cp "$SNAP/release-runtime-pins.txt" "$ROOT/build/release-runtime-pins.txt" || true
    cp "$SNAP/ComponentHealth.swift" "$ROOT/Sources/RegressionCore/ComponentHealth.swift" || true
    cp "$SNAP/ComponentHealthTests.swift" "$ROOT/Tests/RegressionCoreTests/ComponentHealthTests.swift" || true
    for v in verify-protected-state.sh verify-public-installed-state.sh \
             verify-public-runtime-transform-1.12.sh verify-release-asset.sh; do
        cp "$SNAP/$v" "$ROOT/build/$v" 2>/dev/null || true
    done
    bash "$ROOT/Scripts/sign_regression.sh" "$BUNDLE" >/dev/null 2>&1 || true
    printf '!! Estado anterior restaurado desde %s\n' "${SNAP#$ROOT/}" >&2
}
SUCCESS=false
trap '[[ "$SUCCESS" == true ]] || rollback' EXIT

# --- 1. runtime --------------------------------------------------------------
step "1/6 Instalando ntdll.so del builder"
cp "$BUILDER/dlls/ntdll/ntdll.so" "$WINE_ROOT/lib/wine/x86_64-unix/ntdll.so"
codesign -f -s - "$WINE_ROOT/lib/wine/x86_64-unix/ntdll.so"
printf '   %s\n' "$(shasum -a 256 "$WINE_ROOT/lib/wine/x86_64-unix/ntdll.so" | cut -c1-32)"

# --- 2. PIN ------------------------------------------------------------------
step "2/6 Refrescando los PIN desde el builder"
bash "$ROOT/build/refresh-release-pins.sh" --bundle "$BUNDLE" --builder "$BUILDER"

step "3/6 Comprobando que no quedan diferencias"
bash "$ROOT/build/refresh-release-pins.sh" --bundle "$BUNDLE" --builder "$BUILDER" --check \
    || fail "el refresco de PIN dejó diferencias pendientes"

# --- 4. binarios Swift con los PIN nuevos compilados -------------------------
step "4/6 Compilando release y pasando la suite"
(cd "$ROOT" && swift build -c release >/dev/null)
# La salida se captura una sola vez y se compara sin tuberías: cualquier `grep -q`
# cierra la tubería antes de tiempo, el productor recibe SIGPIPE y `pipefail` daría
# la suite por fallida aunque esté en verde. Además evita ejecutarla dos veces.
test_output="$(cd "$ROOT" && swift test 2>&1 || true)"
printf '%s\n' "$test_output" | grep -E "Executed .* tests" | tail -1
[[ "$test_output" == *"0 failures (0 unexpected)"* ]] \
    || fail "la suite no está en verde"

step "5/6 Instalando los binarios en el bundle"
cp "$ROOT/.build/release/Regression" "$BUNDLE/Contents/MacOS/Regression"
cp "$ROOT/.build/release/regressionctl" "$BUNDLE/Contents/SharedSupport/bin/regressionctl"
bash "$ROOT/Scripts/sign_regression.sh" "$BUNDLE" >/dev/null
codesign --verify --strict "$BUNDLE" || fail "la firma del bundle no verifica"

# --- 6. coherencia final -----------------------------------------------------
step "6/6 Verificando que el PIN compilado corresponde al runtime instalado"
installed="$(shasum -a 256 "$WINE_ROOT/lib/wine/x86_64-unix/ntdll.so" | awk '{print $1}')"
grep -q "$installed" "$ROOT/Sources/RegressionCore/ComponentHealth.swift" \
    || fail "ComponentHealth no declara el ntdll.so instalado"

SUCCESS=true
printf '\nRuntime instalado y coherente. Instantánea de rollback: %s\n' "${SNAP#$ROOT/}"
printf 'Falta la matriz de validación (tienda + Moonlighter 2 + Palworld) antes de publicar.\n'
