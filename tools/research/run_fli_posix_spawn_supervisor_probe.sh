#!/usr/bin/env bash

set -euo pipefail

# Valida una única primitiva host: crear un ayudante firmado mediante
# posix_spawn desde un proceso macOS arm64 realmente multihilo, con argv y envp
# explícitos. No ejecuta FEX, Wine, Proton, Steam, juegos ni EAC.

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
SOURCE="$ROOT/tools/research/fli_posix_spawn_supervisor_probe.cpp"
OUTPUT_DIRECTORY=""

usage() {
  echo "Uso: tools/research/run_fli_posix_spawn_supervisor_probe.sh --output-dir RUTA_PRIVADA_NUEVA"
}

while [[ $# -gt 0 ]]; do
  case "$1" in
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
  echo "ERROR: falta la fuente regular de la sonda posix_spawn." >&2
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

BUILD_DIRECTORY="$(mktemp -d /private/tmp/regression-fli-posix-spawn-supervisor.XXXXXX)"
cleanup() {
  local status=$?
  if [[ "$status" -ne 0 && "${REGRESSION_KEEP_FAILED_BUILD:-0}" == "1" ]]; then
    echo "Diagnóstico preservado: $BUILD_DIRECTORY" >&2
    return
  fi
  case "$BUILD_DIRECTORY" in
    /private/tmp/regression-fli-posix-spawn-supervisor.*)
      rm -rf -- "$BUILD_DIRECTORY"
      ;;
  esac
}
trap cleanup EXIT

PROBE="$BUILD_DIRECTORY/fli-posix-spawn-supervisor-probe"
RECEIPT="$BUILD_DIRECTORY/posix-spawn-supervisor.json"

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
"$PROBE" | tee "$RECEIPT"
PROBE_STATUS=${PIPESTATUS[0]}
set -e

umask 077
install -d -m 0700 "$OUTPUT_DIRECTORY"
install -m 0600 "$RECEIPT" "$OUTPUT_DIRECTORY/posix-spawn-supervisor.json"
shasum -a 256 "$SOURCE" \
  | sed "s#  $ROOT/#  repository/#" > "$OUTPUT_DIRECTORY/source.sha256"
shasum -a 256 "$PROBE" \
  | awk '{ print $1 "  ephemeral-signed-probe" }' > "$OUTPUT_DIRECTORY/binary.sha256"
{
  printf 'schema=%s\n' '1'
  printf 'scope=%s\n' 'isolated-multithreaded-posix-spawn-supervisor'
  printf 'signature=%s\n' 'apple-development-valid'
  printf 'hardened_runtime=%s\n' 'yes'
  printf 'child=%s\n' 'same-signed-probe-self-validation-only'
  printf 'argv=%s\n' 'explicit-two-entries'
  printf 'environment=%s\n' 'explicit-two-entry-allowlist'
  printf 'fex=%s\n' 'not-executed'
  printf 'wine=%s\n' 'not-executed'
  printf 'proton=%s\n' 'not-executed'
  printf 'steam=%s\n' 'not-executed'
  printf 'game=%s\n' 'not-executed'
  printf 'eac=%s\n' 'not-executed'
  printf 'probe_exit_status=%s\n' "$PROBE_STATUS"
} > "$OUTPUT_DIRECTORY/scope.txt"
(
  cd "$OUTPUT_DIRECTORY"
  shasum -a 256 posix-spawn-supervisor.json source.sha256 binary.sha256 scope.txt > tree.sha256
)
chmod 0600 "$OUTPUT_DIRECTORY"/*

for assertion in \
  '"host":"macos-arm64"' \
  '"probe":"posix-spawn-supervisor"' \
  '"multithreaded_host":true' \
  '"worker_ready":true' \
  '"worker_blocking_at_spawn":true' \
  '"pipe_close_on_exec":true' \
  '"file_actions_initialized":true' \
  '"spawn_attributes_initialized":true' \
  '"spawn_signal_mask_explicit":true' \
  '"spawn_signal_defaults_explicit":true' \
  '"spawn_result":0' \
  '"spawned_pid_positive":true' \
  '"waitpid_success":true' \
  '"waitpid_matches_spawned_pid":true' \
  '"child_exited":true' \
  '"child_exit_code":42' \
  '"child_contract_passed":true' \
  '"explicit_argument_count":2' \
  '"explicit_environment_count":2' \
  '"explicit_environment_lc_all_c":true' \
  '"explicit_environment_private_home":true' \
  '"worker_released":true' \
  '"worker_joined":true' \
  '"fex_executed":false' \
  '"wine_executed":false' \
  '"proton_executed":false' \
  '"steam_executed":false' \
  '"game_executed":false' \
  '"eac_executed":false' \
  '"passed":true'; do
  grep -Fq "$assertion" "$OUTPUT_DIRECTORY/posix-spawn-supervisor.json" || {
    echo "ERROR: falta la aserción del supervisor: $assertion" >&2
    exit 70
  }
done

[[ "$PROBE_STATUS" -eq 0 ]] || {
  echo "Resultado negativo reproducible preservado: $OUTPUT_DIRECTORY" >&2
  exit "$PROBE_STATUS"
}

echo "Supervisor posix_spawn multihilo validado: $OUTPUT_DIRECTORY"
