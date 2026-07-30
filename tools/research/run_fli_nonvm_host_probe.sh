#!/usr/bin/env bash

set -euo pipefail

# Compila y ejecuta una sonda nativa, aislada y de solo lectura. No carga ni
# ejecuta el ELF entregado y no modifica Steam, Proton, EAC ni ninguna botella.

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
SOURCE="$ROOT/tools/research/fli_nonvm_host_probe.c"
ENTITLEMENTS="$ROOT/tools/research/fli_nonvm_host_probe.entitlements"
ELF_PATH=""
OUTPUT_DIRECTORY=""

usage() {
  cat <<'EOF'
Uso: tools/research/run_fli_nonvm_host_probe.sh [--elf RUTA] [--output-dir RUTA]

  --elf RUTA        Inspecciona exclusivamente cabeceras ELF64 x86-64.
  --output-dir RUTA Conserva recibo, hashes y metadatos sin rutas personales.

La sonda nunca ejecuta el ELF ni enumera símbolos o contenido propietario.
EOF
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --elf)
      [[ $# -ge 2 ]] || { usage >&2; exit 64; }
      ELF_PATH="$2"
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

[[ -f "$SOURCE" && -f "$ENTITLEMENTS" ]] || {
  echo "ERROR: faltan los fuentes canónicos de la sonda." >&2
  exit 66
}

if [[ -n "$ELF_PATH" ]]; then
  [[ -f "$ELF_PATH" && ! -L "$ELF_PATH" ]] || {
    echo "ERROR: el ELF debe ser un archivo regular, existente y no simbólico." >&2
    exit 66
  }
fi

BUILD_DIRECTORY="$(mktemp -d /private/tmp/regression-fli-nonvm-host.XXXXXX)"
cleanup() {
  case "$BUILD_DIRECTORY" in
    /private/tmp/regression-fli-nonvm-host.*)
      rm -rf -- "$BUILD_DIRECTORY"
      ;;
  esac
}
trap cleanup EXIT

PROBE="$BUILD_DIRECTORY/fli-nonvm-host-probe"
/usr/bin/clang \
  -std=c17 \
  -arch arm64 \
  -Wall \
  -Wextra \
  -Werror \
  -O2 \
  "$SOURCE" \
  -o "$PROBE"

codesign --force \
  --sign - \
  --options runtime \
  --entitlements "$ENTITLEMENTS" \
  "$PROBE" >/dev/null
codesign --verify --strict "$PROBE"

ALLOW_JIT="$(codesign -d --entitlements :- "$PROBE" 2>/dev/null \
  | plutil -extract 'com\.apple\.security\.cs\.allow-jit' raw -o - -- -)"
[[ "$ALLOW_JIT" == "true" ]] || {
  echo "ERROR: la firma de la sonda perdió com.apple.security.cs.allow-jit." >&2
  exit 70
}

SIGNATURE_RECEIPT="$BUILD_DIRECTORY/signature.txt"
{
  printf '%s\n' 'signature=valid'
  printf '%s\n' 'hardened_runtime=yes'
  printf 'allow_jit=%s\n' "$ALLOW_JIT"
  printf '%s\n' 'identity=adhoc-research-helper'
} > "$SIGNATURE_RECEIPT"

PROBE_ARGUMENTS=()
if [[ -n "$ELF_PATH" ]]; then
  PROBE_ARGUMENTS=(--elf "$ELF_PATH")
fi

RECEIPT="$BUILD_DIRECTORY/receipt.json"
"$PROBE" "${PROBE_ARGUMENTS[@]}" | tee "$RECEIPT"

if [[ -n "$OUTPUT_DIRECTORY" ]]; then
  install -d -m 0700 "$OUTPUT_DIRECTORY"
  install -m 0600 "$RECEIPT" "$OUTPUT_DIRECTORY/host-probe.json"
  install -m 0600 "$SIGNATURE_RECEIPT" "$OUTPUT_DIRECTORY/signature.txt"
  shasum -a 256 "$SOURCE" "$ENTITLEMENTS" \
    | sed "s#  $ROOT/#  repository/#" \
    > "$OUTPUT_DIRECTORY/sources.sha256"
  chmod 0600 "$OUTPUT_DIRECTORY/sources.sha256"
  if [[ -n "$ELF_PATH" ]]; then
    shasum -a 256 "$ELF_PATH" \
      | awk '{ print $1 "  inspected-elf" }' \
      > "$OUTPUT_DIRECTORY/elf.sha256"
    chmod 0600 "$OUTPUT_DIRECTORY/elf.sha256"
  fi
  TREE_INPUTS=(host-probe.json signature.txt sources.sha256)
  if [[ -f "$OUTPUT_DIRECTORY/elf.sha256" ]]; then
    TREE_INPUTS+=(elf.sha256)
  fi
  (
    cd "$OUTPUT_DIRECTORY"
    shasum -a 256 "${TREE_INPUTS[@]}" > tree.sha256
  )
  chmod 0600 "$OUTPUT_DIRECTORY/tree.sha256"
  echo "Evidencia privada: $OUTPUT_DIRECTORY"
fi
