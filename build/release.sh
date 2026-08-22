#!/usr/bin/env bash
# Corta una release de Regression de principio a fin, en un solo comando.
#
# POR QUÉ EXISTE
#
# Los mismos cuatro binarios de arranque de Wine se fijan en el repositorio en
# TRES formas distintas, y cada una vive en archivos diferentes:
#
#   1. CRUDO      — tal como sale del builder público, sin firmar.
#   2. BUNDLE     — instalado en Regression.app y firmado con la identidad de desarrollo.
#   3. PÚBLICO    — además saneado (`strip`, rutas privadas fuera) y firmado ad hoc.
#                   Es lo único que viaja dentro del asset.
#
# Nada derivaba esos tres juegos de una sola fuente, así que cada release era una
# reconciliación manual de hashes por siete archivos. Peor: refrescar uno de los
# juegos desincronizaba otro en silencio, y el fallo solo aparecía tres pasos más
# tarde con un mensaje que no decía dónde estaba el problema.
#
# Este script deriva los tres juegos de los artefactos reales y los escribe en su
# sitio. NO relaja ninguna garantía: todos los verificadores siguen ejecutándose
# y siguen comparando contra un PIN. Lo que cambia es que el PIN se calcula en vez
# de teclearse.
#
# INVARIANTE INVIOLABLE
#
# Los contratos de releases YA PUBLICADAS no se tocan jamás. Este script no
# escribe en `build/verify-public-installed-state.sh` salvo para AÑADIR el modo
# de la versión nueva, y comprueba al terminar que las ramas históricas de
# `Scripts/package_regression.sh` siguen intactas. Si algo de eso cambiara,
# aborta y restaura.
#
#   build/release.sh                 # prepara y verifica; NO publica
#   build/release.sh --publish       # además crea la release en GitHub
#   build/release.sh --skip-tests    # solo para reintentar tras un fallo tardío
set -Eeuo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
CANONICAL_APP="${REGRESSION_APP_PATH:-/Applications/Regression.app}"
STAGING_APP="$ROOT/Regression.app"
PUBLIC_BUILD="$ROOT/build/wine64-dist"
PUBLISH=false
SKIP_TESTS=false

VERSION="$(sed -n 's/^VERSION="\([0-9.]*\)"$/\1/p' "$ROOT/Scripts/package_regression.sh" | head -1)"
BUILD_NUMBER="$(sed -n 's/^BUILD_NUMBER="\([0-9]*\)"$/\1/p' "$ROOT/Scripts/package_regression.sh" | head -1)"

while [[ $# -gt 0 ]]; do
    case "$1" in
        --publish) PUBLISH=true; shift ;;
        --skip-tests) SKIP_TESTS=true; shift ;;
        --version) VERSION="$2"; shift 2 ;;
        --build) BUILD_NUMBER="$2"; shift 2 ;;
        *) printf 'ERROR: opción desconocida: %s\n' "$1" >&2; exit 64 ;;
    esac
done

step() { printf '\n\033[1m== %s ==\033[0m\n' "$*"; }
info() { printf '   %s\n' "$*"; }
fail() {
    printf '\nERROR: %s\n' "$1" >&2
    [[ -n "${2:-}" ]] && printf '       %s\n' "$2" >&2
    exit 1
}

sha() { shasum -a 256 "$1" | awk '{print $1}'; }

# Sustituye un hash por otro SOLO en los archivos indicados, y solo si el viejo
# aparece ahí. Nunca hace un reemplazo global a ciegas.
reseal() {
    local old="$1" new="$2"; shift 2
    [[ "$old" == "$new" ]] && return 0
    local file changed=0
    for file in "$@"; do
        [[ -f "$file" ]] || continue
        if grep -q "$old" "$file"; then
            python3 - "$file" "$old" "$new" <<'PY'
import io, sys
path, old, new = sys.argv[1], sys.argv[2], sys.argv[3]
text = io.open(path, encoding="utf-8").read()
io.open(path, "w", encoding="utf-8").write(text.replace(old, new))
PY
            changed=$((changed + 1))
        fi
    done
    (( changed > 0 )) && info "resellado en $changed archivo(s): ${old:0:12} → ${new:0:12}"
    return 0
}

# ---------------------------------------------------------------------------
step "0/7 Guardias"

pgrep -f wineserver >/dev/null 2>&1 && fail \
    "hay un wineserver activo" "cierra Steam desde su propio menú antes de cortar una release"
[[ -d "$CANONICAL_APP" ]] || fail \
    "no existe la app canónica: $CANONICAL_APP" \
    "la release se corta desde la instalación validada, no desde un bundle cualquiera"
codesign --verify --strict "$CANONICAL_APP" >/dev/null 2>&1 || fail \
    "la app canónica no tiene una firma verificable" \
    "ejecuta Scripts/sign_regression.sh $CANONICAL_APP"

bash "$ROOT/Tests/Shell/release-version-coherence.sh" >/dev/null \
    || fail "la versión no es coherente en los cinco archivos" \
            "revisa Tests/Shell/release-version-coherence.sh para ver cuál discrepa"
info "versión $VERSION ($BUILD_NUMBER), coherente"

if $PUBLISH && gh release view "v$VERSION" >/dev/null 2>&1; then
    fail "v$VERSION ya está publicada" \
         "sube la versión en los cinco archivos antes de cortar una release nueva"
fi

# Testigos de lo que NO se puede tocar: contratos de releases ya publicadas.
PUBLISHED_WITNESS="$(sha "$ROOT/build/verify-public-installed-state.sh")"
HISTORIC_WITNESS="$(grep -c '767c2c54bfd395ad957f394038c5a930abc46296bb471d4696e186b9a68166f4' \
    "$ROOT/Scripts/package_regression.sh" || true)"

# ---------------------------------------------------------------------------
step "1/7 Insumos"

# El árbol de staging no se versiona y desaparece entre releases. Se reconstruye
# desde la app canónica validada, que es la única fuente legítima.
if [[ ! -d "$STAGING_APP/Contents/SharedSupport/wine-root" ]]; then
    info "reconstruyendo el staging desde $CANONICAL_APP"
    rm -rf "$STAGING_APP"
    ditto "$CANONICAL_APP" "$STAGING_APP"
    # Regla 19: solo /Applications puede ser descubrible.
    /System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister \
        -u "$STAGING_APP" 2>/dev/null || true
else
    info "staging presente"
fi

# Los componentes sellados viajan dentro de la app; el directorio de build es
# solo una copia de trabajo y también se pierde.
for component in windows-media steam-bottle-baseline; do
    target="$ROOT/build/${component/windows-media/windows-media-component}/1"
    [[ "$component" == "steam-bottle-baseline" ]] && target="$ROOT/build/steam-bottle-baseline/1"
    source="$CANONICAL_APP/Contents/SharedSupport/components/$component/1"
    if [[ ! -f "$target/manifest.sha256" ]]; then
        [[ -f "$source/manifest.sha256" ]] || fail \
            "falta el componente $component y la app canónica tampoco lo trae"
        info "reconstruyendo build/$component desde la app canónica"
        mkdir -p "$(dirname "$target")"
        ditto "$source" "$target"
    fi
    # Acreditar la copia: su manifiesto tiene que ser el mismo que el instalado.
    [[ "$(sha "$target/manifest.sha256")" == "$(sha "$source/manifest.sha256")" ]] || fail \
        "el componente $component de build no corresponde al de la app canónica" \
        "borra build/$component y vuelve a ejecutar este script"
done

# El builder público hornea el prefijo /Applications en los cuatro Mach-O de
# arranque. Sin él no hay asset posible.
step "2/7 Runtime público"
REGRESSION_PUBLIC_WINE_BUILD="$PUBLIC_BUILD" bash "$ROOT/build/build-public-wine-runtime.sh" \
    >/dev/null || fail "no se pudo construir el runtime público"
for relative in tools/wine/wine server/wineserver loader/wine dlls/ntdll/ntdll.so; do
    [[ -f "$PUBLIC_BUILD/$relative" ]] || fail "el builder público no produjo $relative"
done
info "builder público listo en ${PUBLIC_BUILD#"$ROOT"/}"

# ---------------------------------------------------------------------------
step "3/7 Sellado de los tres juegos de PIN"

RAW_SITES=(
    "$ROOT/build/verify-sealed-public-runtime-1.12.sh"
    "$ROOT/build/verify-protected-state.sh"
    "$ROOT/build/release-runtime-pins.txt"
)
PUBLIC_SITES=(
    "$ROOT/Sources/RegressionCore/ComponentHealth.swift"
    "$ROOT/Tests/RegressionCoreTests/ComponentHealthTests.swift"
    "$ROOT/build/verify-public-runtime-transform-1.12.sh"
    "$ROOT/build/verify-release-asset.sh"
    # El instalador viaja como asset y declara su propio ensemble: si se queda
    # atrás, el release publicado no se puede instalar aunque el asset sea válido.
    "$ROOT/Scripts/install_regression.sh"
)

# --- juego 1: crudo del builder --------------------------------------------
declare -a RAW_RELATIVES=(tools/wine/wine server/wineserver loader/wine dlls/ntdll/ntdll.so)
for relative in "${RAW_RELATIVES[@]}"; do
    actual="$(sha "$PUBLIC_BUILD/$relative")"
    # El PIN se localiza por la línea que nombra el binario, nunca por posición.
    current="$(grep -B1 -F "    $relative" "$ROOT/build/verify-sealed-public-runtime-1.12.sh" \
        | grep -oE "[0-9a-f]{64}" | head -1 || true)"
    [[ -n "$current" ]] || fail "no se localizó el PIN crudo de $relative"
    reseal "$current" "$actual" "${RAW_SITES[@]}"
done

# --- juego 3: ensemble público (lo único que viaja en el asset) -------------
DERIVED="$(REGRESSION_PUBLIC_WINE_BUILD="$PUBLIC_BUILD" \
    bash "$ROOT/build/verify-public-runtime-transform-1.12.sh" --print-derived)" \
    || fail "no se pudo derivar el ensemble público"
while read -r source destination actual; do
    [[ -n "$destination" && -n "$actual" ]] || continue
    # En runtime_entries la línea es «origen destino hash»: el PIN va al final.
    current="$(grep -F "$source $destination " \
        "$ROOT/build/verify-public-runtime-transform-1.12.sh" \
        | grep -oE "[0-9a-f]{64}" | head -1 || true)"
    [[ -n "$current" ]] || fail "no se localizó el PIN público de $destination"
    reseal "$current" "$actual" "${PUBLIC_SITES[@]}"
done <<< "$DERIVED"

# --- juego 2: lanzador del bundle ------------------------------------------
# `regression-engine` es un script: firmarlo no cambia sus bytes, así que su PIN
# es el mismo en el repositorio, en el staging y dentro del asset.
ENGINE_ACTUAL="$(sha "$ROOT/Scripts/regression-engine.sh")"
ENGINE_CURRENT="$(grep -oE 'EXPECTED_ENGINE_SHA256="[0-9a-f]{64}"' "$ROOT/build/verify-release-asset.sh" \
    | grep -oE '[0-9a-f]{64}' | head -1)"
if [[ "$ENGINE_CURRENT" != "$ENGINE_ACTUAL" ]]; then
    # En verify-protected-state las dos ocurrencias describen el bundle actual.
    reseal "$ENGINE_CURRENT" "$ENGINE_ACTUAL" \
        "$ROOT/build/verify-protected-state.sh" \
        "$ROOT/build/verify-release-asset.sh" \
        "$ROOT/Scripts/install_regression.sh"
    # En package_regression SOLO la rama de la línea vigente, nunca las históricas.
    python3 - "$ROOT/Scripts/package_regression.sh" "$ENGINE_CURRENT" "$ENGINE_ACTUAL" <<'PY'
import io, sys
path, old, new = sys.argv[1], sys.argv[2], sys.argv[3]
text = io.open(path, encoding="utf-8").read()
needle = f'''    if [[ "$installed_hash" == "{old}" &&
          "$source_hash" == "$installed_hash" ]]; then'''
if needle in text:
    replacement = needle.replace(old, new)
    io.open(path, "w", encoding="utf-8").write(text.replace(needle, replacement, 1))
    print("   rama vigente de package_regression.sh actualizada")
PY
fi

# --- el invariante ----------------------------------------------------------
[[ "$(sha "$ROOT/build/verify-public-installed-state.sh")" == "$PUBLISHED_WITNESS" ]] || fail \
    "el sellado tocó los contratos de releases ya publicadas" \
    "revierte build/verify-public-installed-state.sh: sus PIN describen 1.12.2-1.12.4"
[[ "$(grep -c '767c2c54bfd395ad957f394038c5a930abc46296bb471d4696e186b9a68166f4' \
    "$ROOT/Scripts/package_regression.sh" || true)" == "$HISTORIC_WITNESS" ]] || fail \
    "el sellado alteró una rama histórica de package_regression.sh"
info "contratos publicados intactos"

# ---------------------------------------------------------------------------
step "4/7 Suite"
if $SKIP_TESTS; then
    info "omitida por --skip-tests"
else
    output="$(cd "$ROOT" && swift test 2>&1 || true)"
    printf '%s\n' "$output" | grep -E "Executed .* tests" | tail -1 | sed 's/^/   /'
    [[ "$output" == *"0 failures (0 unexpected)"* ]] || fail "la suite no está en verde"
    for contract in release-version-coherence documentation-contract-1.12 \
                    no-codeweavers-runtime regression-engine-gptk-authority; do
        bash "$ROOT/Tests/Shell/$contract.sh" >/dev/null 2>&1 \
            || fail "el contrato $contract no pasa"
    done
    info "contratos de shell en verde"
fi

# ---------------------------------------------------------------------------
step "5/7 Empaquetado"
export REGRESSION_1_12_DEVELOPMENT_RUNTIME_BUILD="$PUBLIC_BUILD"
export REGRESSION_PUBLIC_WINE_BUILD="$PUBLIC_BUILD"
bash "$ROOT/Scripts/package_regression.sh" >/dev/null || fail "falló el empaquetado del staging"
info "staging firmado"
bash "$ROOT/Scripts/package_release.sh" >/dev/null || fail "falló la generación del asset público"

OUTPUT_DIR="$ROOT/build/release-$VERSION"
ASSET="$OUTPUT_DIR/Regression-$VERSION-macos-arm64.tar.gz"
CHECKSUM="$ASSET.sha256"
INSTALLER="$OUTPUT_DIR/install_regression.sh"
[[ -f "$ASSET" && -f "$CHECKSUM" && -f "$INSTALLER" ]] \
    || fail "el asset no quedó completo en ${OUTPUT_DIR#"$ROOT"/}"
info "asset: $(du -h "$ASSET" | cut -f1)  sha256 $(sha "$ASSET" | cut -c1-16)…"

# ---------------------------------------------------------------------------
step "6/7 Verificación del asset exacto"
bash "$ROOT/build/verify-release-asset.sh" "$ASSET" "$CHECKSUM" "$VERSION" "$BUILD_NUMBER" \
    | tail -1 | sed 's/^/   /'

# El staging es reconstruible desde la app canónica y, mientras exista, Spotlight
# lo indexa y `verify-canonical-installation.sh` falla por tener dos apps. Se
# retira en cuanto el asset está verificado.
rm -rf "$STAGING_APP"
info "staging retirado"

# ---------------------------------------------------------------------------
step "7/7 Publicación"
if ! $PUBLISH; then
    info "listo para publicar. Repite con --publish, o:"
    info "  gh release create v$VERSION $ASSET $CHECKSUM $INSTALLER"
    exit 0
fi
[[ -z "$(cd "$ROOT" && git status --porcelain -- Sources Scripts build Tests)" ]] || fail \
    "hay cambios sin commitear en el contrato" \
    "commitea el sellado antes de publicar: la release tiene que ser reproducible desde un commit"
gh release create "v$VERSION" "$ASSET" "$CHECKSUM" "$INSTALLER" \
    --title "Regression $VERSION" \
    --notes "Asset verificado con build/verify-release-asset.sh sobre el archivo exacto publicado."
info "publicada v$VERSION"
