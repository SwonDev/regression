#!/usr/bin/env bash

set -euo pipefail

# Comprueba únicamente que dyld puede cargar una FEXCore arm64 ya compilada.
# No invoca su API, no ejecuta huéspedes ELF y no modifica Steam ni EAC.

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
SOURCE="$ROOT/tools/research/fli_fexcore_darwin_loader_probe.c"
LIBRARY=""
OUTPUT_DIRECTORY=""

usage() {
  cat <<'EOF'
Uso: tools/research/run_fli_fexcore_darwin_loader_probe.sh --library RUTA [--output-dir RUTA]

  --library RUTA    FEXCore arm64 Mach-O compilada para macOS.
  --output-dir RUTA Conserva recibos y hashes en una carpeta privada.

La sonda solo realiza dlopen(RTLD_NOW|RTLD_LOCAL) y dlclose.
EOF
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --library)
      [[ $# -ge 2 ]] || { usage >&2; exit 64; }
      LIBRARY="$2"
      shift 2
      ;;
    --output-dir)
      [[ $# -ge 2 ]] || { usage >&2; exit 64; }
      OUTPUT_DIRECTORY="$2"
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

[[ -n "$LIBRARY" && -f "$LIBRARY" && ! -L "$LIBRARY" ]] || {
  echo "ERROR: --library debe señalar una biblioteca regular existente." >&2
  exit 66
}

[[ "$(file -b "$LIBRARY")" == *"Mach-O 64-bit dynamically linked shared library arm64"* ]] || {
  echo "ERROR: la biblioteca no es una dylib Mach-O arm64." >&2
  exit 65
}

BUILD_DIRECTORY="$(mktemp -d /private/tmp/regression-fli-fexcore-loader.XXXXXX)"
cleanup() {
  case "$BUILD_DIRECTORY" in
    /private/tmp/regression-fli-fexcore-loader.*)
      rm -rf -- "$BUILD_DIRECTORY"
      ;;
  esac
}
trap cleanup EXIT

PROBE="$BUILD_DIRECTORY/fli-fexcore-darwin-loader-probe"
/usr/bin/clang \
  -std=c17 \
  -arch arm64 \
  -Wall \
  -Wextra \
  -Werror \
  -O2 \
  "$SOURCE" \
  -o "$PROBE"

codesign --force --sign - "$PROBE" >/dev/null
codesign --verify --strict "$PROBE"

RECEIPT="$BUILD_DIRECTORY/loader-probe.json"
"$PROBE" "$LIBRARY" | tee "$RECEIPT"

LINK_RECEIPT="$BUILD_DIRECTORY/link.txt"
{
  printf '%s\n' 'format=mach-o-arm64-dylib'
  printf '%s\n' 'loader=dyld'
  printf '%s\n' 'mode=RTLD_NOW|RTLD_LOCAL|RTLD_FIRST'
  otool -L "$LIBRARY" | tail -n +2 | sed -E 's#^[[:space:]]+/.*/([^/]+) \(#dependency=\1 (#'
} > "$LINK_RECEIPT"

if [[ -n "$OUTPUT_DIRECTORY" ]]; then
  install -d -m 0700 "$OUTPUT_DIRECTORY"
  install -m 0600 "$RECEIPT" "$OUTPUT_DIRECTORY/loader-probe.json"
  install -m 0600 "$LINK_RECEIPT" "$OUTPUT_DIRECTORY/link.txt"
  shasum -a 256 "$SOURCE" \
    | awk '{ print $1 "  repository/tools/research/fli_fexcore_darwin_loader_probe.c" }' \
    > "$OUTPUT_DIRECTORY/source.sha256"
  shasum -a 256 "$LIBRARY" \
    | awk '{ print $1 "  libFEXCore.dylib" }' \
    > "$OUTPUT_DIRECTORY/library.sha256"
  (
    cd "$OUTPUT_DIRECTORY"
    shasum -a 256 loader-probe.json link.txt source.sha256 library.sha256 > tree.sha256
  )
  chmod 0600 "$OUTPUT_DIRECTORY"/*.txt "$OUTPUT_DIRECTORY"/*.json "$OUTPUT_DIRECTORY"/*.sha256
  echo "Evidencia privada: $OUTPUT_DIRECTORY"
fi
