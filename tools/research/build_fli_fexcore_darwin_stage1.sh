#!/usr/bin/env bash

set -euo pipefail

# Construye el primer hito nativo de FEXCore para macOS desde una revisión
# pública exacta. El resultado es una biblioteca de investigación: ejecuta
# bloques x86-64 y un bootstrap de proceso controlado, pero todavía no carga
# glibc ni implementa el ABI Linux completo que necesita Proton.

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
PATCH_STAGE1="$ROOT/patches/fex-a04b0241-darwin-core-stage1.patch"
PATCH_STAGE2="$ROOT/patches/fex-a04b0241-darwin-map-jit-stage2.patch"
PATCH_STAGE3="$ROOT/patches/fex-a04b0241-darwin-guest-memory-bias-stage3.patch"
LOADER_PROBE="$ROOT/tools/research/run_fli_fexcore_darwin_loader_probe.sh"
ALLOCATOR_PROBE="$ROOT/tools/research/run_fli_fexcore_allocator_probe.sh"
CONTEXT_PROBE="$ROOT/tools/research/run_fli_fexcore_context_probe.sh"
ELF_PROBE="$ROOT/tools/research/run_fli_fexcore_elf_probe.sh"
PROCESS_PROBE="$ROOT/tools/research/run_fli_fexcore_process_probe.sh"
EXPECTED_REVISION="a04b0241c2fe3911729842205cd8643981108aad"
SOURCE_DIRECTORY=""
OUTPUT_DIRECTORY=""
STAGE="1"

usage() {
  cat <<'EOF'
Uso: tools/research/build_fli_fexcore_darwin_stage1.sh \
  --source RUTA_FEX --stage 1|2|3 --output-dir RUTA_PRIVADA

Requisitos:
  - checkout público de FEX en a04b0241c2fe3911729842205cd8643981108aad
  - submódulos/materiales de compilación ya presentes
  - CMake, Ninja, Xcode CLI y fmt instalados

El script clona el árbol mediante APFS, aplica el parche solo a la copia y
conserva la biblioteca, recibos y hashes en la carpeta privada indicada.

  stage 1  Compila/carga el núcleo; conserva el bloqueo RWX sin MAP_JIT.
  stage 2  Añade MAP_JIT, valida el ciclo completo del JIT y ejecuta un ELF
           estático y un bootstrap PT_INTERP controlado, sin glibc ni Proton.
  stage 3  Añade traducción de datos huésped bajos y regiones lógicas altas,
           desactivadas por defecto, además de una redirección dispersa para
           aislar una página huésped de 4 KiB sobre un host de 16 KiB. Valida
           también el contrato bidireccional, rechaza mapas ambiguos y prueba
           la sustitución y retirada segura del backing de un bloque JIT ya
           compilado. Atribuye además un fallo Darwin controlado a su dirección
           huésped exacta y restaura los handlers y el backing tras la prueba.
EOF
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --source)
      [[ $# -ge 2 ]] || { usage >&2; exit 64; }
      SOURCE_DIRECTORY="$2"
      shift 2
      ;;
    --output-dir)
      [[ $# -ge 2 ]] || { usage >&2; exit 64; }
      OUTPUT_DIRECTORY="$2"
      shift 2
      ;;
    --stage)
      [[ $# -ge 2 ]] || { usage >&2; exit 64; }
      STAGE="$2"
      shift 2
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      usage >&2
      exit 64
      ;;
  esac
done

[[ -d "$SOURCE_DIRECTORY" && -f "$SOURCE_DIRECTORY/CMakeLists.txt" ]] || {
  echo "ERROR: --source no es un checkout completo de FEX." >&2
  exit 66
}
[[ -n "$OUTPUT_DIRECTORY" && ! -L "$OUTPUT_DIRECTORY" ]] || {
  echo "ERROR: --output-dir es obligatorio y no puede ser un enlace simbólico." >&2
  exit 66
}
[[ "$STAGE" == "1" || "$STAGE" == "2" || "$STAGE" == "3" ]] || {
  echo "ERROR: --stage debe ser 1, 2 o 3." >&2
  exit 64
}
[[ -f "$PATCH_STAGE1" && -f "$PATCH_STAGE2" && -f "$PATCH_STAGE3" && -x "$LOADER_PROBE" && -x "$ALLOCATOR_PROBE" \
  && -x "$CONTEXT_PROBE" && -x "$ELF_PROBE" && -x "$PROCESS_PROBE" ]] || {
  echo "ERROR: faltan los parches o las sondas canónicas." >&2
  exit 66
}

ACTUAL_REVISION="$(git -C "$SOURCE_DIRECTORY" rev-parse HEAD)"
[[ "$ACTUAL_REVISION" == "$EXPECTED_REVISION" ]] || {
  echo "ERROR: revisión FEX no permitida para este experimento." >&2
  exit 65
}

BUILD_ROOT="$(mktemp -d /private/tmp/regression-fli-fexcore-stage1.XXXXXX)"
cleanup() {
  case "$BUILD_ROOT" in
    /private/tmp/regression-fli-fexcore-stage1.*)
      rm -rf -- "$BUILD_ROOT"
      ;;
  esac
}
trap cleanup EXIT

SOURCE_COPY="$BUILD_ROOT/source"
BUILD_DIRECTORY="$BUILD_ROOT/build"
cp -cR "$SOURCE_DIRECTORY" "$SOURCE_COPY"

# Un submódulo conserva un archivo .git con una ruta relativa al checkout
# original. La copia de laboratorio no necesita metadatos Git para compilar.
if [[ -e "$SOURCE_COPY/.git" ]]; then
  mv "$SOURCE_COPY/.git" "$SOURCE_COPY/.git-source-reference"
fi

git -C "$SOURCE_COPY" apply --check "$PATCH_STAGE1"
git -C "$SOURCE_COPY" apply "$PATCH_STAGE1"
if [[ "$STAGE" == "2" || "$STAGE" == "3" ]]; then
  git -C "$SOURCE_COPY" apply --check "$PATCH_STAGE2"
  git -C "$SOURCE_COPY" apply "$PATCH_STAGE2"
fi
if [[ "$STAGE" == "3" ]]; then
  git -C "$SOURCE_COPY" apply --check "$PATCH_STAGE3"
  git -C "$SOURCE_COPY" apply "$PATCH_STAGE3"
fi

cmake \
  -S "$SOURCE_COPY" \
  -B "$BUILD_DIRECTORY" \
  -G Ninja \
  -DBUILD_DARWIN_CORE_ONLY=ON \
  -DCMAKE_BUILD_TYPE=Debug \
  -DTUNE_CPU=none \
  -DENABLE_FEX_ALLOCATOR=OFF \
  -DENABLE_JEMALLOC_GLIBC_ALLOC=OFF \
  -DENABLE_LTO=OFF

cmake --build "$BUILD_DIRECTORY" \
  --target FEXCore_shared \
  -j "$(sysctl -n hw.logicalcpu)"

LIBRARY="$BUILD_DIRECTORY/FEXCore/Source/libFEXCore.dylib"
[[ -f "$LIBRARY" && "$(file -b "$LIBRARY")" == *"Mach-O 64-bit dynamically linked shared library arm64"* ]] || {
  echo "ERROR: la compilación no produjo la biblioteca arm64 esperada." >&2
  exit 70
}

install -d -m 0700 "$OUTPUT_DIRECTORY"
install -m 0700 "$LIBRARY" "$OUTPUT_DIRECTORY/libFEXCore.dylib"

BUILD_RECEIPT="$OUTPUT_DIRECTORY/build.txt"
{
  printf 'schema=%s\n' '1'
  printf 'stage=%s\n' "$STAGE"
  printf 'upstream=%s\n' 'FEX-Emu/FEX'
  printf 'revision=%s\n' "$EXPECTED_REVISION"
  printf 'patch_stage1=%s\n' 'fex-a04b0241-darwin-core-stage1.patch'
  if [[ "$STAGE" == "2" || "$STAGE" == "3" ]]; then
    printf 'patch_stage2=%s\n' 'fex-a04b0241-darwin-map-jit-stage2.patch'
  fi
  if [[ "$STAGE" == "3" ]]; then
    printf 'patch_stage3=%s\n' 'fex-a04b0241-darwin-guest-memory-bias-stage3.patch'
  fi
  printf 'target=%s\n' 'FEXCore_shared'
  printf 'host=%s\n' 'macos-arm64'
  if [[ "$STAGE" == "2" || "$STAGE" == "3" ]]; then
    printf 'guest_execution=%s\n' 'controlled-block-only'
  else
    printf 'guest_execution=%s\n' 'not-implemented'
  fi
  if [[ "$STAGE" == "2" || "$STAGE" == "3" ]]; then
    printf 'linux_process_abi=%s\n' 'controlled-pt-interp-stack-bss-write-exit-only'
  else
    printf 'linux_process_abi=%s\n' 'not-implemented'
  fi
  if [[ "$STAGE" == "3" ]]; then
    printf 'guest_low_memory_translation=%s\n' 'controlled-data-access-below-4g-disabled-by-default'
    printf 'guest_high_memory_translation=%s\n' 'bounded-sparse-regions-disabled-by-default'
    printf 'guest_address_translation=%s\n' 'bidirectional-bounded-overlap-rejected-disabled-by-default'
    printf 'guest_region_lifecycle=%s\n' 'dynamic-update-clear-protect-unmap-jit-reuse-verified'
    printf 'guest_region_fault_attribution=%s\n' 'darwin-signal-host-to-guest-exact-cleanup-verified'
  else
    printf 'guest_low_memory_translation=%s\n' 'not-implemented'
    printf 'guest_high_memory_translation=%s\n' 'not-implemented'
    printf 'guest_address_translation=%s\n' 'not-implemented'
    printf 'guest_region_lifecycle=%s\n' 'not-implemented'
    printf 'guest_region_fault_attribution=%s\n' 'not-implemented'
  fi
  printf 'fex_allocator=%s\n' 'disabled-stage1'
  if [[ "$STAGE" == "2" || "$STAGE" == "3" ]]; then
    printf 'jit_mapping=%s\n' 'map-jit-verified'
  else
    printf 'jit_mapping=%s\n' 'blocked-without-map-jit'
  fi
  if [[ "$STAGE" == "2" || "$STAGE" == "3" ]]; then
    printf 'jit_emitter_write_scopes=%s\n' 'dispatcher+compile-code+runtime-link+direct-delink+indirect-delink'
  else
    printf 'jit_emitter_write_scopes=%s\n' 'not-integrated'
  fi
  printf 'cmake_version=%s\n' "$(cmake --version | head -1 | awk '{print $3}')"
  printf 'compiler=%s\n' "$(/usr/bin/clang --version | head -1 | sed 's/ (.*//')"
  printf 'sdk=%s\n' "$(xcrun --sdk macosx --show-sdk-version)"
} > "$BUILD_RECEIPT"
chmod 0600 "$BUILD_RECEIPT"

shasum -a 256 "$PATCH_STAGE1" \
  | awk '{ print $1 "  repository/patches/fex-a04b0241-darwin-core-stage1.patch" }' \
  > "$OUTPUT_DIRECTORY/patch-stage1.sha256"
if [[ "$STAGE" == "2" || "$STAGE" == "3" ]]; then
  shasum -a 256 "$PATCH_STAGE2" \
    | awk '{ print $1 "  repository/patches/fex-a04b0241-darwin-map-jit-stage2.patch" }' \
    > "$OUTPUT_DIRECTORY/patch-stage2.sha256"
fi
if [[ "$STAGE" == "3" ]]; then
  shasum -a 256 "$PATCH_STAGE3" \
    | awk '{ print $1 "  repository/patches/fex-a04b0241-darwin-guest-memory-bias-stage3.patch" }' \
    > "$OUTPUT_DIRECTORY/patch-stage3.sha256"
fi
shasum -a 256 "$OUTPUT_DIRECTORY/libFEXCore.dylib" \
  | awk '{ print $1 "  libFEXCore.dylib" }' \
  > "$OUTPUT_DIRECTORY/library.sha256"
chmod 0600 "$OUTPUT_DIRECTORY"/*.sha256

"$LOADER_PROBE" \
  --library "$OUTPUT_DIRECTORY/libFEXCore.dylib" \
  --output-dir "$OUTPUT_DIRECTORY/loader"

ALLOCATOR_EXPECTATION="blocked"
if [[ "$STAGE" == "2" || "$STAGE" == "3" ]]; then
  ALLOCATOR_EXPECTATION="pass"
fi
"$ALLOCATOR_PROBE" \
  --library "$OUTPUT_DIRECTORY/libFEXCore.dylib" \
  --fex-source "$SOURCE_COPY" \
  --fex-build "$BUILD_DIRECTORY" \
  --expect "$ALLOCATOR_EXPECTATION" \
  --output-dir "$OUTPUT_DIRECTORY/allocator"

"$CONTEXT_PROBE" \
  --library "$OUTPUT_DIRECTORY/libFEXCore.dylib" \
  --fex-source "$SOURCE_COPY" \
  --fex-build "$BUILD_DIRECTORY" \
  --expect context \
  --output-dir "$OUTPUT_DIRECTORY/context"

if [[ "$STAGE" == "2" || "$STAGE" == "3" ]]; then
  "$CONTEXT_PROBE" \
    --library "$OUTPUT_DIRECTORY/libFEXCore.dylib" \
    --fex-source "$SOURCE_COPY" \
    --fex-build "$BUILD_DIRECTORY" \
    --expect init-core \
    --output-dir "$OUTPUT_DIRECTORY/init-core"

  "$CONTEXT_PROBE" \
    --library "$OUTPUT_DIRECTORY/libFEXCore.dylib" \
    --fex-source "$SOURCE_COPY" \
    --fex-build "$BUILD_DIRECTORY" \
    --expect compile-one \
    --output-dir "$OUTPUT_DIRECTORY/jit-compile"

  "$CONTEXT_PROBE" \
    --library "$OUTPUT_DIRECTORY/libFEXCore.dylib" \
    --fex-source "$SOURCE_COPY" \
    --fex-build "$BUILD_DIRECTORY" \
    --expect execute-one \
    --output-dir "$OUTPUT_DIRECTORY/guest-execution"

  "$CONTEXT_PROBE" \
    --library "$OUTPUT_DIRECTORY/libFEXCore.dylib" \
    --fex-source "$SOURCE_COPY" \
    --fex-build "$BUILD_DIRECTORY" \
    --expect execute-linked \
    --output-dir "$OUTPUT_DIRECTORY/guest-linking"

  "$CONTEXT_PROBE" \
    --library "$OUTPUT_DIRECTORY/libFEXCore.dylib" \
    --fex-source "$SOURCE_COPY" \
    --fex-build "$BUILD_DIRECTORY" \
    --expect invalidate-linked \
    --output-dir "$OUTPUT_DIRECTORY/guest-invalidation"

  "$CONTEXT_PROBE" \
    --library "$OUTPUT_DIRECTORY/libFEXCore.dylib" \
    --fex-source "$SOURCE_COPY" \
    --fex-build "$BUILD_DIRECTORY" \
    --expect invalidate-indirect \
    --output-dir "$OUTPUT_DIRECTORY/guest-indirect-invalidation"

  "$ELF_PROBE" \
    --library "$OUTPUT_DIRECTORY/libFEXCore.dylib" \
    --fex-source "$SOURCE_COPY" \
    --fex-build "$BUILD_DIRECTORY" \
    --output-dir "$OUTPUT_DIRECTORY/guest-elf-minimal"

  "$PROCESS_PROBE" \
    --library "$OUTPUT_DIRECTORY/libFEXCore.dylib" \
    --fex-source "$SOURCE_COPY" \
    --fex-build "$BUILD_DIRECTORY" \
    --output-dir "$OUTPUT_DIRECTORY/guest-process-bootstrap"

  if [[ "$STAGE" == "3" ]]; then
    "$CONTEXT_PROBE" \
      --library "$OUTPUT_DIRECTORY/libFEXCore.dylib" \
      --fex-source "$SOURCE_COPY" \
      --fex-build "$BUILD_DIRECTORY" \
      --expect execute-low-memory-bias \
      --output-dir "$OUTPUT_DIRECTORY/guest-low-memory-bias"

    "$CONTEXT_PROBE" \
      --library "$OUTPUT_DIRECTORY/libFEXCore.dylib" \
      --fex-source "$SOURCE_COPY" \
      --fex-build "$BUILD_DIRECTORY" \
      --expect execute-sparse-page-redirect \
      --output-dir "$OUTPUT_DIRECTORY/guest-sparse-page-redirect"

    "$CONTEXT_PROBE" \
      --library "$OUTPUT_DIRECTORY/libFEXCore.dylib" \
      --fex-source "$SOURCE_COPY" \
      --fex-build "$BUILD_DIRECTORY" \
      --expect execute-sparse-high-regions \
      --output-dir "$OUTPUT_DIRECTORY/guest-sparse-high-regions"

    "$CONTEXT_PROBE" \
      --library "$OUTPUT_DIRECTORY/libFEXCore.dylib" \
      --fex-source "$SOURCE_COPY" \
      --fex-build "$BUILD_DIRECTORY" \
      --expect inspect-address-translation \
      --output-dir "$OUTPUT_DIRECTORY/guest-address-translation"

    "$CONTEXT_PROBE" \
      --library "$OUTPUT_DIRECTORY/libFEXCore.dylib" \
      --fex-source "$SOURCE_COPY" \
      --fex-build "$BUILD_DIRECTORY" \
      --expect execute-region-lifecycle \
      --output-dir "$OUTPUT_DIRECTORY/guest-region-lifecycle"

    "$CONTEXT_PROBE" \
      --library "$OUTPUT_DIRECTORY/libFEXCore.dylib" \
      --fex-source "$SOURCE_COPY" \
      --fex-build "$BUILD_DIRECTORY" \
      --expect execute-region-fault-attribution \
      --output-dir "$OUTPUT_DIRECTORY/guest-region-fault-attribution"
  fi
fi

(
  cd "$OUTPUT_DIRECTORY"
  TREE_INPUTS=(build.txt patch-stage1.sha256 library.sha256 loader/tree.sha256 allocator/tree.sha256 context/tree.sha256)
  if [[ -f patch-stage2.sha256 ]]; then
    TREE_INPUTS+=(patch-stage2.sha256)
  fi
  if [[ -f patch-stage3.sha256 ]]; then
    TREE_INPUTS+=(patch-stage3.sha256)
  fi
  if [[ -f init-core/tree.sha256 ]]; then
    TREE_INPUTS+=(init-core/tree.sha256)
  fi
  if [[ -f jit-compile/tree.sha256 ]]; then
    TREE_INPUTS+=(jit-compile/tree.sha256)
  fi
  if [[ -f guest-execution/tree.sha256 ]]; then
    TREE_INPUTS+=(guest-execution/tree.sha256)
  fi
  if [[ -f guest-linking/tree.sha256 ]]; then
    TREE_INPUTS+=(guest-linking/tree.sha256)
  fi
  if [[ -f guest-invalidation/tree.sha256 ]]; then
    TREE_INPUTS+=(guest-invalidation/tree.sha256)
  fi
  if [[ -f guest-indirect-invalidation/tree.sha256 ]]; then
    TREE_INPUTS+=(guest-indirect-invalidation/tree.sha256)
  fi
  if [[ -f guest-elf-minimal/tree.sha256 ]]; then
    TREE_INPUTS+=(guest-elf-minimal/tree.sha256)
  fi
  if [[ -f guest-process-bootstrap/tree.sha256 ]]; then
    TREE_INPUTS+=(guest-process-bootstrap/tree.sha256)
  fi
  if [[ -f guest-low-memory-bias/tree.sha256 ]]; then
    TREE_INPUTS+=(guest-low-memory-bias/tree.sha256)
  fi
  if [[ -f guest-sparse-page-redirect/tree.sha256 ]]; then
    TREE_INPUTS+=(guest-sparse-page-redirect/tree.sha256)
  fi
  if [[ -f guest-sparse-high-regions/tree.sha256 ]]; then
    TREE_INPUTS+=(guest-sparse-high-regions/tree.sha256)
  fi
  if [[ -f guest-address-translation/tree.sha256 ]]; then
    TREE_INPUTS+=(guest-address-translation/tree.sha256)
  fi
  if [[ -f guest-region-lifecycle/tree.sha256 ]]; then
    TREE_INPUTS+=(guest-region-lifecycle/tree.sha256)
  fi
  if [[ -f guest-region-fault-attribution/tree.sha256 ]]; then
    TREE_INPUTS+=(guest-region-fault-attribution/tree.sha256)
  fi
  shasum -a 256 "${TREE_INPUTS[@]}" > tree.sha256
)
chmod 0600 "$OUTPUT_DIRECTORY/tree.sha256"

echo "FEXCore Darwin stage $STAGE reproducido y verificado."
echo "Evidencia privada: $OUTPUT_DIRECTORY"
