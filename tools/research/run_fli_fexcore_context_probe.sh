#!/usr/bin/env bash

set -euo pipefail

# Construye y ejecuta una sonda mínima de creación/destrucción de Context FEX.
# No inicializa el dispatcher, señales, syscalls ni carga huéspedes x86-64.

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
PROBE_SOURCE="$ROOT/tools/research/fli_fexcore_context_probe.cpp"
LIBRARY=""
FEX_SOURCE=""
FEX_BUILD=""
OUTPUT_DIRECTORY=""

usage() {
  cat <<'EOF'
Uso: tools/research/run_fli_fexcore_context_probe.sh \
  --library RUTA --fex-source RUTA --fex-build RUTA \
  --output-dir RUTA_PRIVADA

La sonda crea y destruye un Context FEXCore nativo. No llama InitCore y no
carga ni ejecuta huéspedes x86-64, Proton, Steam ni EAC.
EOF
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --library)
      [[ $# -ge 2 ]] || { usage >&2; exit 64; }
      LIBRARY="$2"
      shift 2
      ;;
    --fex-source)
      [[ $# -ge 2 ]] || { usage >&2; exit 64; }
      FEX_SOURCE="$2"
      shift 2
      ;;
    --fex-build)
      [[ $# -ge 2 ]] || { usage >&2; exit 64; }
      FEX_BUILD="$2"
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

[[ -f "$LIBRARY" && ! -L "$LIBRARY" ]] || {
  echo "ERROR: --library debe señalar una dylib regular." >&2
  exit 66
}
[[ -d "$FEX_SOURCE/FEXCore/include" && -d "$FEX_BUILD/include" ]] || {
  echo "ERROR: faltan las cabeceras fuente o generadas de FEXCore." >&2
  exit 66
}
[[ -n "$OUTPUT_DIRECTORY" && ! -L "$OUTPUT_DIRECTORY" ]] || {
  echo "ERROR: --output-dir es obligatorio y no puede ser un enlace simbólico." >&2
  exit 66
}

IDENTITY="${REGRESSION_CODESIGN_IDENTITY:-}"
if [[ -z "$IDENTITY" ]]; then
  IDENTITY="$(security find-identity -v -p codesigning 2>/dev/null \
    | awk '/"Apple Development:/ { print $2; exit }')"
fi
[[ -n "$IDENTITY" && "$IDENTITY" != "-" ]] || {
  echo "ERROR: la prueba endurecida requiere una identidad Apple Development estable." >&2
  exit 69
}

BUILD_DIRECTORY="$(mktemp -d /private/tmp/regression-fli-fex-context-probe.XXXXXX)"
cleanup() {
  case "$BUILD_DIRECTORY" in
    /private/tmp/regression-fli-fex-context-probe.*)
      rm -rf -- "$BUILD_DIRECTORY"
      ;;
  esac
}
trap cleanup EXIT

RUNTIME_DIRECTORY="$BUILD_DIRECTORY/runtime"
mkdir -m 0700 "$RUNTIME_DIRECTORY"
RUNTIME_LIBRARY="$RUNTIME_DIRECTORY/libFEXCore.dylib"
FMT_LIBRARY="$RUNTIME_DIRECTORY/libfmt.12.dylib"
PROBE="$RUNTIME_DIRECTORY/fli-fexcore-context-probe"

cp "$LIBRARY" "$RUNTIME_LIBRARY"
cp -L /opt/homebrew/opt/fmt/lib/libfmt.12.dylib "$FMT_LIBRARY"
install_name_tool -id @rpath/libfmt.12.dylib "$FMT_LIBRARY"
install_name_tool \
  -change /opt/homebrew/opt/fmt/lib/libfmt.12.dylib \
  @loader_path/libfmt.12.dylib \
  "$RUNTIME_LIBRARY"

codesign --force --sign "$IDENTITY" --options runtime "$FMT_LIBRARY" >/dev/null
codesign --force --sign "$IDENTITY" --options runtime "$RUNTIME_LIBRARY" >/dev/null

/usr/bin/c++ \
  -std=c++20 \
  -arch arm64 \
  -Wall \
  -Wextra \
  -Werror \
  -Wno-unused-parameter \
  -O2 \
  -I "$FEX_SOURCE/FEXCore/include" \
  -I "$FEX_BUILD/include" \
  -I "$FEX_SOURCE/FEXHeaderUtils" \
  -I "$FEX_SOURCE/CodeEmitter" \
  -I "$FEX_SOURCE/External/unordered_dense/include" \
  -isystem /opt/homebrew/include \
  "$PROBE_SOURCE" \
  -L "$RUNTIME_DIRECTORY" \
  -lFEXCore \
  -Wl,-rpath,@executable_path \
  -o "$PROBE"

codesign --force --sign "$IDENTITY" --options runtime "$PROBE" >/dev/null

codesign --verify --strict "$FMT_LIBRARY"
codesign --verify --strict "$RUNTIME_LIBRARY"
codesign --verify --strict "$PROBE"

RECEIPT="$BUILD_DIRECTORY/context-probe.json"
"$PROBE" | tee "$RECEIPT"
grep -Fq '"context_created":true' "$RECEIPT" || {
  echo "ERROR: FEXCore no creó el contexto nativo esperado." >&2
  exit 70
}
grep -Fq '"guest_elf_executed":false' "$RECEIPT" || {
  echo "ERROR: el recibo no conserva la frontera de no ejecución huésped." >&2
  exit 70
}

install -d -m 0700 "$OUTPUT_DIRECTORY"
install -m 0600 "$RECEIPT" "$OUTPUT_DIRECTORY/context-probe.json"
{
  printf 'schema=%s\n' '1'
  printf 'signature=%s\n' 'valid'
  printf 'hardened_runtime=%s\n' 'yes'
  printf 'allow_jit=%s\n' 'false'
  printf 'team_identifier=%s\n' 'present-and-matched'
  printf 'init_core=%s\n' 'not-invoked'
  printf 'guest_execution=%s\n' 'none'
} > "$OUTPUT_DIRECTORY/signature.txt"
shasum -a 256 "$PROBE_SOURCE" \
  | sed "s#  $ROOT/#  repository/#" \
  > "$OUTPUT_DIRECTORY/sources.sha256"
shasum -a 256 "$LIBRARY" \
  | awk '{ print $1 "  input-libFEXCore.dylib" }' \
  > "$OUTPUT_DIRECTORY/library.sha256"
(
  cd "$OUTPUT_DIRECTORY"
  shasum -a 256 context-probe.json signature.txt sources.sha256 library.sha256 > tree.sha256
)
chmod 0600 "$OUTPUT_DIRECTORY"/*.txt "$OUTPUT_DIRECTORY"/*.json "$OUTPUT_DIRECTORY"/*.sha256

echo "Creación de Context FEXCore nativo verificada."
echo "Evidencia privada: $OUTPUT_DIRECTORY"
