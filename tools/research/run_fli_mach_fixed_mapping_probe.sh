#!/usr/bin/env bash

set -euo pipefail

# Comprueba en un proceso efímero si puede liberarse exclusivamente la página
# objetivo dentro del __PAGEZERO propio y volver a reservarse mediante Mach sin
# MAP_FIXED ni VM_FLAGS_OVERWRITE. No ejecuta FEX, Wine, Proton, Steam, juegos
# ni EAC. Tanto el resultado positivo como el negativo se conservan.

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
SOURCE="$ROOT/tools/research/fli_mach_fixed_mapping_probe.cpp"
OUTPUT_DIRECTORY=""
RELEASE_OWN_PAGEZERO=0

usage() {
  echo "Uso: tools/research/run_fli_mach_fixed_mapping_probe.sh --release-own-pagezero --output-dir RUTA_PRIVADA_NUEVA"
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --release-own-pagezero)
      RELEASE_OWN_PAGEZERO=1
      shift
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

[[ -f "$SOURCE" && ! -L "$SOURCE" ]] || {
  echo "ERROR: falta la fuente regular de la sonda Mach." >&2
  exit 66
}
[[ "$RELEASE_OWN_PAGEZERO" == "1" ]] || {
  echo "ERROR: la liberación exacta exige confirmación explícita con --release-own-pagezero." >&2
  exit 64
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

BUILD_DIRECTORY="$(mktemp -d /private/tmp/regression-fli-mach-fixed-probe.XXXXXX)"
cleanup() {
  local status=$?
  if [[ "$status" -ne 0 && "${REGRESSION_KEEP_FAILED_BUILD:-0}" == "1" ]]; then
    echo "Diagnóstico preservado: $BUILD_DIRECTORY" >&2
    return
  fi
  case "$BUILD_DIRECTORY" in
    /private/tmp/regression-fli-mach-fixed-probe.*)
      rm -rf -- "$BUILD_DIRECTORY"
      ;;
  esac
}
trap cleanup EXIT

PROBE="$BUILD_DIRECTORY/fli-mach-fixed-mapping-probe"
RECEIPT="$BUILD_DIRECTORY/mach-fixed-mapping.json"

/usr/bin/c++ \
  -std=c++20 \
  -arch arm64 \
  -O2 \
  -Wall \
  -Wextra \
  -Werror \
  "$SOURCE" \
  -o "$PROBE"

codesign --force --sign "$IDENTITY" --options runtime "$PROBE" >/dev/null
codesign --verify --strict "$PROBE"
PAGEZERO_SIZE="$(otool -l "$PROBE" \
  | awk '/segname __PAGEZERO/{found=1} found && $1 == "vmsize" { print $2; exit }')"
[[ "$PAGEZERO_SIZE" == "0x0000000100000000" ]] || {
  echo "ERROR: la sonda no conserva el __PAGEZERO arm64 canónico de 4 GiB." >&2
  exit 70
}

set +e
"$PROBE" --release-own-pagezero | tee "$RECEIPT"
PROBE_STATUS=${PIPESTATUS[0]}
set -e

umask 077
install -d -m 0700 "$OUTPUT_DIRECTORY"
install -m 0600 "$RECEIPT" "$OUTPUT_DIRECTORY/mach-fixed-mapping.json"
shasum -a 256 "$SOURCE" \
  | sed "s#  $ROOT/#  #" > "$OUTPUT_DIRECTORY/source.sha256"
shasum -a 256 "$PROBE" \
  | awk '{ print $1 "  ephemeral-signed-probe" }' > "$OUTPUT_DIRECTORY/binary.sha256"
{
  printf 'schema=%s\n' '2'
  printf 'scope=%s\n' 'isolated-own-pagezero-release-no-overwrite-feasibility'
  printf 'address=%s\n' '0x7ffe0000'
  printf 'guest_page_size=%s\n' '4096'
  printf 'host_page_size=%s\n' '16384'
  printf 'macho_pagezero_size=%s\n' '4294967296'
  printf 'macho_layout=%s\n' 'canonical-arm64'
  printf 'release_scope=%s\n' 'exact-host-page-inside-own-pagezero-only'
  printf 'allocation_primitive=%s\n' 'mach_vm_allocate-vm_flags_fixed'
  printf 'overwrite_flag=%s\n' 'not-used'
  printf 'posix_map_fixed=%s\n' 'not-used'
  printf 'probe_exit_status=%s\n' "$PROBE_STATUS"
  printf 'fex=%s\n' 'not-executed'
  printf 'wine=%s\n' 'not-executed'
  printf 'proton=%s\n' 'not-executed'
  printf 'steam=%s\n' 'not-executed'
  printf 'game=%s\n' 'not-executed'
  printf 'eac=%s\n' 'not-executed'
} > "$OUTPUT_DIRECTORY/scope.txt"
(
  cd "$OUTPUT_DIRECTORY"
  shasum -a 256 mach-fixed-mapping.json source.sha256 binary.sha256 scope.txt > tree.sha256
)
chmod 0600 "$OUTPUT_DIRECTORY"/*

for assertion in \
  '"host":"macos-arm64"' \
  '"requested_address":2147352576' \
  '"guest_requested_length":4096' \
  '"host_page_size":16384' \
  '"target_host_page_aligned":true' \
  '"rounded_host_length":16384' \
  '"pagezero_found":true' \
  '"pagezero_contains_target":true' \
  '"pagezero_has_no_file_contents":true' \
  '"pagezero_has_no_permissions":true' \
  '"pagezero_safe_to_release":true' \
  '"initial_allocate_success":false' \
  '"vm_flags_overwrite_used":false' \
  '"posix_map_fixed_used":false'; do
  grep -Fq "$assertion" "$OUTPUT_DIRECTORY/mach-fixed-mapping.json" || {
    echo "ERROR: la evidencia no contiene el límite de seguridad: $assertion" >&2
    exit 70
  }
done

if [[ "$PROBE_STATUS" -ne 0 ]]; then
  echo "Resultado negativo reproducible preservado: $OUTPUT_DIRECTORY" >&2
  exit "$PROBE_STATUS"
fi

for assertion in \
  '"pagezero_release_success":true' \
  '"candidate_allocate_success":true' \
  '"protect_read_only_success":true' \
  '"collision_rejected":true' \
  '"sentinel_preserved":true' \
  '"cleanup_deallocate_success":true' \
  '"reallocate_success":true' \
  '"reallocate_cleanup_success":true' \
  '"passed":true'; do
  grep -Fq "$assertion" "$OUTPUT_DIRECTORY/mach-fixed-mapping.json" || {
    echo "ERROR: falta la aserción Mach segura: $assertion" >&2
    exit 70
  }
done

echo "Reserva Mach fija sin sobrescritura validada: $OUTPUT_DIRECTORY"
