#!/usr/bin/env bash

set -euo pipefail

# Prueba el contrato de memoria ejecutable de una FEXCore Darwin. La biblioteca
# y fmt se copian a un bundle temporal, se firman con el mismo Team ID y se
# ejecuta únicamente código arm64 generado por la propia sonda.

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
PROBE_SOURCE="$ROOT/tools/research/fli_fexcore_allocator_probe.cpp"
ENTITLEMENTS="$ROOT/tools/research/fli_nonvm_host_probe.entitlements"
LIBRARY=""
FEX_SOURCE=""
FEX_BUILD=""
OUTPUT_DIRECTORY=""
EXPECTED=""

usage() {
  cat <<'EOF'
Uso: tools/research/run_fli_fexcore_allocator_probe.sh \
  --library RUTA --fex-source RUTA --fex-build RUTA \
  --expect blocked|pass --output-dir RUTA_PRIVADA

  blocked  Espera que el runtime endurecido rechace RWX sin MAP_JIT (errno 13).
  pass     Espera asignación MAP_JIT y ejecución arm64 con resultado 42.

No carga ni ejecuta huéspedes x86-64, Proton, Steam ni EAC.
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
    --expect)
      [[ $# -ge 2 ]] || { usage >&2; exit 64; }
      EXPECTED="$2"
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
[[ "$EXPECTED" == "blocked" || "$EXPECTED" == "pass" ]] || {
  echo "ERROR: --expect debe ser blocked o pass." >&2
  exit 64
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

BUILD_DIRECTORY="$(mktemp -d /private/tmp/regression-fli-fex-allocator-probe.XXXXXX)"
cleanup() {
  case "$BUILD_DIRECTORY" in
    /private/tmp/regression-fli-fex-allocator-probe.*)
      rm -rf -- "$BUILD_DIRECTORY"
      ;;
  esac
}
trap cleanup EXIT

RUNTIME_DIRECTORY="$BUILD_DIRECTORY/runtime"
mkdir -m 0700 "$RUNTIME_DIRECTORY"
RUNTIME_LIBRARY="$RUNTIME_DIRECTORY/libFEXCore.dylib"
FMT_LIBRARY="$RUNTIME_DIRECTORY/libfmt.12.dylib"
PROBE="$RUNTIME_DIRECTORY/fli-fexcore-allocator-probe"

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
  -isystem /opt/homebrew/include \
  "$PROBE_SOURCE" \
  -L "$RUNTIME_DIRECTORY" \
  -lFEXCore \
  -Wl,-rpath,@executable_path \
  -o "$PROBE"

codesign --force \
  --sign "$IDENTITY" \
  --options runtime \
  --entitlements "$ENTITLEMENTS" \
  "$PROBE" >/dev/null

codesign --verify --strict "$FMT_LIBRARY"
codesign --verify --strict "$RUNTIME_LIBRARY"
codesign --verify --strict "$PROBE"

RECEIPT="$BUILD_DIRECTORY/allocator-probe.json"
set +e
"$PROBE" | tee "$RECEIPT"
STATUS="${PIPESTATUS[0]}"
set -e

case "$EXPECTED" in
  blocked)
    [[ "$STATUS" -eq 70 ]] \
      && grep -Fq '"fex_virtual_alloc":false' "$RECEIPT" \
      && grep -Fq '"errno":13' "$RECEIPT" || {
        echo "ERROR: el baseline no produjo el bloqueo MAP_JIT esperado." >&2
        exit 70
      }
    ;;
  pass)
    [[ "$STATUS" -eq 0 ]] \
      && grep -Fq '"fex_virtual_alloc":true' "$RECEIPT" \
      && grep -Fq '"native_result":42' "$RECEIPT" || {
        echo "ERROR: el candidato MAP_JIT no superó el contrato ejecutable." >&2
        exit 70
      }
    ;;
esac

install -d -m 0700 "$OUTPUT_DIRECTORY"
install -m 0600 "$RECEIPT" "$OUTPUT_DIRECTORY/allocator-probe.json"
{
  printf 'schema=%s\n' '1'
  printf 'expectation=%s\n' "$EXPECTED"
  printf 'signature=%s\n' 'valid'
  printf 'hardened_runtime=%s\n' 'yes'
  printf 'allow_jit=%s\n' 'true'
  printf 'team_identifier=%s\n' 'present-and-matched'
  printf 'guest_execution=%s\n' 'none'
} > "$OUTPUT_DIRECTORY/signature.txt"
shasum -a 256 "$PROBE_SOURCE" "$ENTITLEMENTS" \
  | sed "s#  $ROOT/#  repository/#" \
  > "$OUTPUT_DIRECTORY/sources.sha256"
shasum -a 256 "$LIBRARY" \
  | awk '{ print $1 "  input-libFEXCore.dylib" }' \
  > "$OUTPUT_DIRECTORY/library.sha256"
(
  cd "$OUTPUT_DIRECTORY"
  shasum -a 256 allocator-probe.json signature.txt sources.sha256 library.sha256 > tree.sha256
)
chmod 0600 "$OUTPUT_DIRECTORY"/*.txt "$OUTPUT_DIRECTORY"/*.json "$OUTPUT_DIRECTORY"/*.sha256

echo "Contrato FEXCore de memoria ejecutable verificado: $EXPECTED"
echo "Evidencia privada: $OUTPUT_DIRECTORY"
