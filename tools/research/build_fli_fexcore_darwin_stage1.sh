#!/usr/bin/env bash

set -euo pipefail

# Construye el primer hito nativo de FEXCore para macOS desde una revisión
# pública exacta. El resultado es una biblioteca de investigación: todavía no
# implementa el ABI de proceso Linux ni ejecuta huéspedes x86-64.

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
PATCH_STAGE1="$ROOT/patches/fex-a04b0241-darwin-core-stage1.patch"
PATCH_STAGE2="$ROOT/patches/fex-a04b0241-darwin-map-jit-stage2.patch"
LOADER_PROBE="$ROOT/tools/research/run_fli_fexcore_darwin_loader_probe.sh"
ALLOCATOR_PROBE="$ROOT/tools/research/run_fli_fexcore_allocator_probe.sh"
EXPECTED_REVISION="a04b0241c2fe3911729842205cd8643981108aad"
SOURCE_DIRECTORY=""
OUTPUT_DIRECTORY=""
STAGE="1"

usage() {
  cat <<'EOF'
Uso: tools/research/build_fli_fexcore_darwin_stage1.sh \
  --source RUTA_FEX --stage 1|2 --output-dir RUTA_PRIVADA

Requisitos:
  - checkout público de FEX en a04b0241c2fe3911729842205cd8643981108aad
  - submódulos/materiales de compilación ya presentes
  - CMake, Ninja, Xcode CLI y fmt instalados

El script clona el árbol mediante APFS, aplica el parche solo a la copia y
conserva la biblioteca, recibos y hashes en la carpeta privada indicada.

  stage 1  Compila/carga el núcleo; conserva el bloqueo RWX sin MAP_JIT.
  stage 2  Añade MAP_JIT y exige que el contrato ejecutable devuelva 42.
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
[[ "$STAGE" == "1" || "$STAGE" == "2" ]] || {
  echo "ERROR: --stage debe ser 1 o 2." >&2
  exit 64
}
[[ -f "$PATCH_STAGE1" && -f "$PATCH_STAGE2" && -x "$LOADER_PROBE" && -x "$ALLOCATOR_PROBE" ]] || {
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
if [[ "$STAGE" == "2" ]]; then
  git -C "$SOURCE_COPY" apply --check "$PATCH_STAGE2"
  git -C "$SOURCE_COPY" apply "$PATCH_STAGE2"
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
  if [[ "$STAGE" == "2" ]]; then
    printf 'patch_stage2=%s\n' 'fex-a04b0241-darwin-map-jit-stage2.patch'
  fi
  printf 'target=%s\n' 'FEXCore_shared'
  printf 'host=%s\n' 'macos-arm64'
  printf 'guest_execution=%s\n' 'not-implemented'
  printf 'linux_process_abi=%s\n' 'not-implemented'
  printf 'fex_allocator=%s\n' 'disabled-stage1'
  if [[ "$STAGE" == "2" ]]; then
    printf 'jit_mapping=%s\n' 'map-jit-verified'
  else
    printf 'jit_mapping=%s\n' 'blocked-without-map-jit'
  fi
  printf 'jit_emitter_write_scopes=%s\n' 'not-integrated'
  printf 'cmake_version=%s\n' "$(cmake --version | head -1 | awk '{print $3}')"
  printf 'compiler=%s\n' "$(/usr/bin/clang --version | head -1 | sed 's/ (.*//')"
  printf 'sdk=%s\n' "$(xcrun --sdk macosx --show-sdk-version)"
} > "$BUILD_RECEIPT"
chmod 0600 "$BUILD_RECEIPT"

shasum -a 256 "$PATCH_STAGE1" \
  | awk '{ print $1 "  repository/patches/fex-a04b0241-darwin-core-stage1.patch" }' \
  > "$OUTPUT_DIRECTORY/patch-stage1.sha256"
if [[ "$STAGE" == "2" ]]; then
  shasum -a 256 "$PATCH_STAGE2" \
    | awk '{ print $1 "  repository/patches/fex-a04b0241-darwin-map-jit-stage2.patch" }' \
    > "$OUTPUT_DIRECTORY/patch-stage2.sha256"
fi
shasum -a 256 "$OUTPUT_DIRECTORY/libFEXCore.dylib" \
  | awk '{ print $1 "  libFEXCore.dylib" }' \
  > "$OUTPUT_DIRECTORY/library.sha256"
chmod 0600 "$OUTPUT_DIRECTORY"/*.sha256

"$LOADER_PROBE" \
  --library "$OUTPUT_DIRECTORY/libFEXCore.dylib" \
  --output-dir "$OUTPUT_DIRECTORY/loader"

ALLOCATOR_EXPECTATION="blocked"
if [[ "$STAGE" == "2" ]]; then
  ALLOCATOR_EXPECTATION="pass"
fi
"$ALLOCATOR_PROBE" \
  --library "$OUTPUT_DIRECTORY/libFEXCore.dylib" \
  --fex-source "$SOURCE_COPY" \
  --fex-build "$BUILD_DIRECTORY" \
  --expect "$ALLOCATOR_EXPECTATION" \
  --output-dir "$OUTPUT_DIRECTORY/allocator"

(
  cd "$OUTPUT_DIRECTORY"
  TREE_INPUTS=(build.txt patch-stage1.sha256 library.sha256 loader/tree.sha256 allocator/tree.sha256)
  if [[ -f patch-stage2.sha256 ]]; then
    TREE_INPUTS+=(patch-stage2.sha256)
  fi
  shasum -a 256 "${TREE_INPUTS[@]}" > tree.sha256
)
chmod 0600 "$OUTPUT_DIRECTORY/tree.sha256"

echo "FEXCore Darwin stage $STAGE reproducido y verificado."
echo "Evidencia privada: $OUTPUT_DIRECTORY"
