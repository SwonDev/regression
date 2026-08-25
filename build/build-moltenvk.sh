#!/bin/bash
# MoltenVK (Vulkan -> Metal) — se compila desde el tar FOSS oficial + la serie de parches propios.
#
# NUNCA se compila desde sources-26.3.0/moltenvk del checkout: ese árbol lleva el SPIRV-Cross
# upstream, no el de CodeWeavers, y produce un traductor que acepta los parámetros de MoltenVK y
# los ignora en silencio. Se comprueba con `grep -c for_mesh_pipeline` sobre spirv_msl.cpp:
# el del tar da 31, el contaminado da 0.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
TAR="$ROOT/crossover-sources-26.3.0.tar.gz"
WORK="${REGRESSION_MVK_WORK:-/private/tmp/regression-moltenvk-build}"
SRC="$WORK/moltenvk"
DD="$WORK/derived"          # un único derived data para TODO el build (ver nota abajo)
XCB=/Applications/Xcode.app/Contents/Developer/usr/bin/xcodebuild

PATCHES=(
    moltenvk-26.3.0-draw-indirect-count.patch
    moltenvk-26.3.0-draw-index-builtin.patch
    moltenvk-26.3.0-block-texel-view.patch
)

step() { printf '\n==> %s\n' "$1"; }

[ -f "$TAR" ] || { echo "falta el tar oficial: $TAR" >&2; exit 1; }

step "Fuentes desde el tar oficial"
# El derived data se limpia junto con el arbol: si sobrevive, Xcode da por hecho el paso que
# genera los xcframeworks DENTRO del arbol de fuentes y el enlace falla buscandolos.
rm -rf "$SRC" "$DD"; mkdir -p "$SRC"
tar xzf "$TAR" -C "$SRC" --strip-components=2 sources/moltenvk

mesh=$(grep -c for_mesh_pipeline "$SRC/External/SPIRV-Cross/spirv_msl.cpp" || true)
[ "$mesh" -gt 0 ] || { echo "SPIRV-Cross del tar no es el de CodeWeavers (for_mesh_pipeline=$mesh)" >&2; exit 1; }
echo "SPIRV-Cross correcto (for_mesh_pipeline=$mesh)"

# El tar solo trae MoltenVK y su External/SPIRV-Cross. El resto de dependencias externas
# (glslang, cereal, Volk, Vulkan-Headers, Vulkan-Tools) las obtiene el propio fetchDependencies de
# MoltenVK, con las revisiones fijadas en ExternalRevisions/. Se cachean para no reclonar en cada
# build; REGRESSION_MVK_EXTCACHE apunta a la caché.
EXTCACHE="${REGRESSION_MVK_EXTCACHE:-$WORK/external-cache}"
EXTDEPS=(glslang cereal Volk Vulkan-Headers Vulkan-Tools)

cache_complete() {
    for d in "${EXTDEPS[@]}"; do [ -d "$EXTCACHE/$d" ] || return 1; done
    [ -f "$EXTCACHE/glslang/SPIRV/CInterface/spirv_c_interface.cpp" ] || return 1
    return 0
}

if cache_complete; then
    step "Dependencias externas (desde la caché)"
else
    step "Dependencias externas (fetchDependencies, requiere red)"
    # fetchDependencies clonaria tambien SPIRV-Cross desde upstream, que es exactamente el arbol
    # contaminado. Se aparta el del tar y se restaura despues, y se vuelve a comprobar.
    mv "$SRC/External/SPIRV-Cross" "$WORK/spirv-cross-tar"
    ( cd "$SRC" && ./fetchDependencies --macos ) > "$WORK/fetch.log" 2>&1 \
        || { tail -20 "$WORK/fetch.log"; echo "fetchDependencies fallo" >&2; exit 1; }
    rm -rf "$SRC/External/SPIRV-Cross"
    mv "$WORK/spirv-cross-tar" "$SRC/External/SPIRV-Cross"
    rm -rf "$EXTCACHE"; mkdir -p "$EXTCACHE"
    for d in "${EXTDEPS[@]}"; do
        [ -d "$SRC/External/$d" ] && cp -a "$SRC/External/$d" "$EXTCACHE/$d"
    done
fi

for d in "${EXTDEPS[@]}"; do
    rm -rf "$SRC/External/$d"
    [ -d "$EXTCACHE/$d" ] && cp -a "$EXTCACHE/$d" "$SRC/External/$d"
done

mesh=$(grep -c for_mesh_pipeline "$SRC/External/SPIRV-Cross/spirv_msl.cpp" || true)
[ "$mesh" -eq 31 ] || { echo "SPIRV-Cross ya no es el del tar tras fetchDependencies (for_mesh_pipeline=$mesh)" >&2; exit 1; }
echo "SPIRV-Cross sigue siendo el del tar (for_mesh_pipeline=$mesh)"

step "Serie de parches"
for p in "${PATCHES[@]}"; do
    patch -p1 --silent -d "$SRC" < "$ROOT/patches/$p"
    echo "  aplicado $p"
done

# MoltenVK no compila SPIRV-Cross: lo COPIA desde ${BUILT_PRODUCTS_DIR}/libSPIRVCross.a. Si cada
# proyecto usa su propio derived data, el paquete enlaza un .a viejo y los cambios del traductor
# no llegan al dylib sin dar ningún error.
step "SPIRV-Cross y demás dependencias externas"
"$XCB" build -project "$SRC/ExternalDependencies.xcodeproj" -scheme "ExternalDependencies-macOS" \
    -destination generic/platform=macOS ARCHS=x86_64 ONLY_ACTIVE_ARCH=NO -derivedDataPath "$DD" \
    > "$WORK/external.log" 2>&1 || { tail -30 "$WORK/external.log"; exit 1; }

# Xcode no rastrea ese .a copiado como entrada, así que un .a nuevo no basta para que re-enlace:
# hay que retirar el producto para forzarlo.
step "MoltenVK"
rm -f "$DD/Build/Products/Release/libMoltenVK.dylib"
"$XCB" build -project "$SRC/MoltenVKPackaging.xcodeproj" -scheme "MoltenVK Package (macOS only)" \
    -destination generic/platform=macOS ARCHS=x86_64 ONLY_ACTIVE_ARCH=NO -derivedDataPath "$DD" \
    > "$WORK/package.log" 2>&1 || { tail -30 "$WORK/package.log"; exit 1; }

DYLIB="$DD/Build/Products/Release/libMoltenVK.dylib"
[ -f "$DYLIB" ] || { echo "no se generó el dylib" >&2; exit 1; }
grep -q spvDrawIndex <(strings -a "$DYLIB") || { echo "el dylib no lleva el parche de gl_DrawID" >&2; exit 1; }

step "MOLTENVK COMPLETADO"
echo "  $DYLIB"
echo "  arquitectura: $(lipo -archs "$DYLIB")"
echo "  sha256:       $(shasum -a 256 "$DYLIB" | cut -d' ' -f1)"
echo
echo "Para instalarlo en el bundle:"
echo "  cp \"$DYLIB\" <bundle>/Contents/SharedSupport/wine-root/lib/runtime/libMoltenVK.dylib"
echo "  Scripts/sign_regression.sh <bundle>"
