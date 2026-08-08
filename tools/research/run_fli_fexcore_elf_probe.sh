#!/usr/bin/env bash

set -euo pipefail

# Carga con el parser público de FEX un ELF x86-64 estático generado por la
# sonda y comprueba la entrega de exit(42) al ABI Linux64 de FEXCore. No carga
# un linker dinámico, Proton, Steam, ningún juego ni EAC.

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
PROBE_SOURCE="$ROOT/tools/research/fli_fexcore_elf_probe.cpp"
COMPAT_DIRECTORY="$ROOT/tools/research/fli_compat"
ENTITLEMENTS="$ROOT/tools/research/fli_nonvm_host_probe.entitlements"
LIBRARY=""
FEX_SOURCE=""
FEX_BUILD=""
OUTPUT_DIRECTORY=""

usage() {
  cat <<'EOF'
Uso: tools/research/run_fli_fexcore_elf_probe.sh \
  --library RUTA --fex-source RUTA --fex-build RUTA \
  --output-dir RUTA_PRIVADA

Ejecuta únicamente un ELF x86-64 estático, autocontenido y controlado que
invoca exit(42). No carga un intérprete ELF, Proton, Steam, juegos ni EAC.
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

ELF_CONTAINER_SOURCE="$FEX_SOURCE/Source/Tools/CommonTools/Linux/Utils/ELFContainer.cpp"
ELF_CONTAINER_HEADER="$FEX_SOURCE/Source/Tools/CommonTools/Linux/Utils/ELFContainer.h"

[[ -f "$LIBRARY" && ! -L "$LIBRARY" ]] || {
  echo "ERROR: --library debe señalar una dylib regular." >&2
  exit 66
}
[[ -d "$FEX_SOURCE/FEXCore/include" && -d "$FEX_BUILD/include" \
  && -f "$ELF_CONTAINER_SOURCE" && -f "$ELF_CONTAINER_HEADER" ]] || {
  echo "ERROR: faltan las fuentes o cabeceras generadas de FEX." >&2
  exit 66
}
[[ -f "$PROBE_SOURCE" && -f "$COMPAT_DIRECTORY/elf.h" \
  && -f "$COMPAT_DIRECTORY/linux/limits.h" && -f "$ENTITLEMENTS" ]] || {
  echo "ERROR: faltan la sonda, la compatibilidad ELF o sus entitlements." >&2
  exit 66
}
[[ -n "$OUTPUT_DIRECTORY" && ! -e "$OUTPUT_DIRECTORY" && ! -L "$OUTPUT_DIRECTORY" ]] || {
  echo "ERROR: --output-dir debe ser una ruta privada nueva." >&2
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

BUILD_DIRECTORY="$(mktemp -d /private/tmp/regression-fli-fex-elf-probe.XXXXXX)"
cleanup() {
  case "$BUILD_DIRECTORY" in
    /private/tmp/regression-fli-fex-elf-probe.*)
      rm -rf -- "$BUILD_DIRECTORY"
      ;;
  esac
}
trap cleanup EXIT

RUNTIME_DIRECTORY="$BUILD_DIRECTORY/runtime"
mkdir -m 0700 "$RUNTIME_DIRECTORY"
RUNTIME_LIBRARY="$RUNTIME_DIRECTORY/libFEXCore.dylib"
FMT_LIBRARY="$RUNTIME_DIRECTORY/libfmt.12.dylib"
PROBE="$RUNTIME_DIRECTORY/fli-fexcore-elf-probe"

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
  -Wno-sign-compare \
  -O2 \
  -DARCHITECTURE_arm64=1 \
  -I "$COMPAT_DIRECTORY" \
  -I "$FEX_SOURCE/FEXCore/include" \
  -I "$FEX_SOURCE/FEXCore/Source" \
  -I "$FEX_BUILD/include" \
  -I "$FEX_SOURCE/FEXHeaderUtils" \
  -I "$FEX_SOURCE/CodeEmitter" \
  -I "$FEX_SOURCE/External/unordered_dense/include" \
  -I "$FEX_SOURCE/Source/Tools/CommonTools" \
  -isystem /opt/homebrew/include \
  "$PROBE_SOURCE" \
  "$ELF_CONTAINER_SOURCE" \
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

RECEIPT="$BUILD_DIRECTORY/elf-probe.json"
"$PROBE" | tee "$RECEIPT"
grep -Fq '"parser":"FEX-ELFContainer"' "$RECEIPT" || {
  echo "ERROR: la prueba no atravesó el parser público de FEX." >&2
  exit 70
}
grep -Fq '"guest_elf_executed":true' "$RECEIPT" || {
  echo "ERROR: el ELF x86-64 controlado no se ejecutó." >&2
  exit 70
}
grep -Fq '"linux_syscall_seen":true' "$RECEIPT" || {
  echo "ERROR: FEXCore no entregó el syscall Linux al host." >&2
  exit 70
}
grep -Fq '"linux_syscall_number":60' "$RECEIPT" || {
  echo "ERROR: el número de syscall Linux no coincide con exit." >&2
  exit 70
}
grep -Fq '"linux_syscall_argument":42' "$RECEIPT" || {
  echo "ERROR: el código de salida huésped no se conservó." >&2
  exit 70
}
grep -Fq '"proton_executed":false' "$RECEIPT"
grep -Fq '"steam_executed":false' "$RECEIPT"
grep -Fq '"eac_executed":false' "$RECEIPT"

install -d -m 0700 "$OUTPUT_DIRECTORY"
install -m 0600 "$RECEIPT" "$OUTPUT_DIRECTORY/elf-probe.json"
{
  printf 'schema=%s\n' '1'
  printf 'signature=%s\n' 'valid'
  printf 'hardened_runtime=%s\n' 'yes'
  printf 'allow_jit=%s\n' 'true'
  printf 'team_identifier=%s\n' 'present-and-matched'
  printf 'process_abi_scope=%s\n' 'minimal-static-elf-exit-only'
  printf 'dynamic_linker=%s\n' 'not-loaded'
  printf 'proton=%s\n' 'not-executed'
  printf 'steam=%s\n' 'not-executed'
  printf 'eac=%s\n' 'not-executed'
} > "$OUTPUT_DIRECTORY/scope.txt"
shasum -a 256 \
  "$PROBE_SOURCE" \
  "$COMPAT_DIRECTORY/elf.h" \
  "$COMPAT_DIRECTORY/linux/limits.h" \
  "$ELF_CONTAINER_HEADER" \
  "$ELF_CONTAINER_SOURCE" \
  | sed "s#  $ROOT/#  repository/#; s#  $FEX_SOURCE/#  upstream-fex/#" \
  > "$OUTPUT_DIRECTORY/sources.sha256"
shasum -a 256 "$LIBRARY" \
  | awk '{ print $1 "  input-libFEXCore.dylib" }' \
  > "$OUTPUT_DIRECTORY/library.sha256"
(
  cd "$OUTPUT_DIRECTORY"
  shasum -a 256 elf-probe.json scope.txt sources.sha256 library.sha256 > tree.sha256
)
chmod 0600 "$OUTPUT_DIRECTORY"/*.txt "$OUTPUT_DIRECTORY"/*.json "$OUTPUT_DIRECTORY"/*.sha256

echo "ELF x86-64 mínimo cargado y ejecutado mediante FEXCore Darwin."
echo "Evidencia privada: $OUTPUT_DIRECTORY"
