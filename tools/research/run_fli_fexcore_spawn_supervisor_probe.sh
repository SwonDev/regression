#!/usr/bin/env bash

set -euo pipefail

# Compila un ayudante FEXCore firmado que ejecuta exclusivamente el ELF x86-64
# controlado de la sonda y lo crea mediante posix_spawn desde un supervisor
# macOS arm64 multihilo. No carga Wine, Proton, Steam, juegos ni EAC.

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
HELPER_SOURCE="$ROOT/tools/research/fli_fexcore_process_probe.cpp"
SUPERVISOR_SOURCE="$ROOT/tools/research/fli_posix_spawn_external_helper_probe.cpp"
COMPAT_DIRECTORY="$ROOT/tools/research/fli_compat"
ENTITLEMENTS="$ROOT/tools/research/fli_nonvm_host_probe.entitlements"
LIBRARY=""
FEX_SOURCE=""
FEX_BUILD=""
OUTPUT_DIRECTORY=""
REAL_ROOTFS=""
GUEST_PROGRAM="/usr/bin/true"
GUEST_COMPONENT_KIND="generic"
GUEST_ARGUMENTS=()
GUEST_ARGUMENT_COUNT=0
DIAGNOSTIC_POST_SESSION_SYSCALL_LIMIT=0
INSTRUMENT_LOW_MEMORY_BIAS=false

usage() {
  cat <<'EOF'
Uso: tools/research/run_fli_fexcore_spawn_supervisor_probe.sh \
  --library RUTA --fex-source RUTA --fex-build RUTA \
  --output-dir RUTA_PRIVADA_NUEVA [--real-rootfs RUTA_PRIVADA \
  [--guest-program /RUTA] \
  [--guest-arg VALOR]... \
  [--guest-component-kind generic|official-proton-wine64|official-proton-wine64-preloader|official-proton-wineserver] \
  [--instrument-low-memory-bias] \
  [--diagnostic-post-session-syscall-limit N]]

Sin --real-rootfs ejecuta el ELF x86-64 controlado. Con --real-rootfs carga
exclusivamente /usr/bin/true y su glibc x86-64 desde ese RootFS privado.
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
    --real-rootfs)
      [[ $# -ge 2 ]] || { usage >&2; exit 64; }
      REAL_ROOTFS="$2"
      shift 2
      ;;
    --guest-program)
      [[ $# -ge 2 ]] || { usage >&2; exit 64; }
      GUEST_PROGRAM="$2"
      shift 2
      ;;
    --guest-arg)
      [[ $# -ge 2 ]] || { usage >&2; exit 64; }
      GUEST_ARGUMENTS[$GUEST_ARGUMENT_COUNT]="$2"
      GUEST_ARGUMENT_COUNT=$((GUEST_ARGUMENT_COUNT + 1))
      shift 2
      ;;
    --guest-component-kind)
      [[ $# -ge 2 ]] || { usage >&2; exit 64; }
      GUEST_COMPONENT_KIND="$2"
      shift 2
      ;;
    --instrument-low-memory-bias)
      INSTRUMENT_LOW_MEMORY_BIAS=true
      shift
      ;;
    --diagnostic-post-session-syscall-limit)
      [[ $# -ge 2 && "$2" =~ ^[0-9]+$ && "$2" -ge 1 && "$2" -le 10000000 ]] || {
        echo "ERROR: el límite diagnóstico debe ser un entero entre 1 y 10000000." >&2
        exit 64
      }
      DIAGNOSTIC_POST_SESSION_SYSCALL_LIMIT="$2"
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

ELF_PARSER_HEADER="$FEX_SOURCE/Source/Tools/CommonTools/Linux/Utils/ELFParser.h"
ELF_CONTAINER_HEADER="$FEX_SOURCE/Source/Tools/CommonTools/Linux/Utils/ELFContainer.h"
[[ -f "$LIBRARY" && ! -L "$LIBRARY" ]] || {
  echo "ERROR: --library debe señalar una dylib regular." >&2
  exit 66
}
[[ -d "$FEX_SOURCE/FEXCore/include" && -d "$FEX_BUILD/include" \
  && -f "$ELF_PARSER_HEADER" && -f "$ELF_CONTAINER_HEADER" ]] || {
  echo "ERROR: faltan las fuentes o cabeceras generadas de FEX." >&2
  exit 66
}
[[ -f "$HELPER_SOURCE" && -f "$SUPERVISOR_SOURCE" \
  && -f "$COMPAT_DIRECTORY/elf.h" \
  && -f "$COMPAT_DIRECTORY/linux/limits.h" \
  && -f "$ENTITLEMENTS" ]] || {
  echo "ERROR: faltan las sondas, la compatibilidad ELF o los entitlements." >&2
  exit 66
}
[[ -n "$OUTPUT_DIRECTORY" && ! -e "$OUTPUT_DIRECTORY" && ! -L "$OUTPUT_DIRECTORY" ]] || {
  echo "ERROR: --output-dir debe ser una ruta privada nueva." >&2
  exit 66
}
if [[ -n "$REAL_ROOTFS" ]]; then
  [[ "$GUEST_ARGUMENT_COUNT" -le 32 ]] || {
    echo "ERROR: se admiten como máximo 32 argumentos huéspedes explícitos." >&2
    exit 64
  }
  if [[ "$GUEST_ARGUMENT_COUNT" -gt 0 ]]; then
    for guest_argument in "${GUEST_ARGUMENTS[@]}"; do
      [[ ${#guest_argument} -le 4096 && "$guest_argument" != *$'\n'* \
        && "$guest_argument" != *$'\r'* ]] || {
        echo "ERROR: un argumento huésped excede el límite o contiene controles." >&2
        exit 64
      }
    done
  fi
  [[ "$GUEST_COMPONENT_KIND" == "generic" \
    || "$GUEST_COMPONENT_KIND" == "official-proton-wine64" \
    || "$GUEST_COMPONENT_KIND" == "official-proton-wine64-preloader" \
    || "$GUEST_COMPONENT_KIND" == "official-proton-wineserver" ]] || {
    echo "ERROR: --guest-component-kind no pertenece al conjunto permitido." >&2
    exit 64
  }
  [[ "$GUEST_PROGRAM" =~ ^/[A-Za-z0-9_+./-]+$ \
    && "/$GUEST_PROGRAM/" != *"/../"* \
    && "/$GUEST_PROGRAM/" != *"/./"* \
    && "$GUEST_PROGRAM" != *"//"* ]] || {
    echo "ERROR: --guest-program debe ser una ruta invitada absoluta y normalizada." >&2
    exit 64
  }
  if [[ "$GUEST_COMPONENT_KIND" == "official-proton-wineserver" \
    && "$GUEST_PROGRAM" != "/opt/proton/files/bin/wineserver" ]]; then
    echo "ERROR: wineserver oficial exige su ruta invitada canónica." >&2
    exit 64
  fi
  if [[ "$DIAGNOSTIC_POST_SESSION_SYSCALL_LIMIT" -ne 0 \
    && "$GUEST_COMPONENT_KIND" != "official-proton-wineserver" ]]; then
    echo "ERROR: el límite diagnóstico posterior al session mapping solo admite wineserver oficial." >&2
    exit 64
  fi
  for required in \
    "$REAL_ROOTFS$GUEST_PROGRAM" \
    "$REAL_ROOTFS/usr/lib64/ld-linux-x86-64.so.2" \
    "$REAL_ROOTFS/usr/lib64/libc.so.6"; do
    [[ -f "$required" && ! -L "$required" ]] || {
      echo "ERROR: el RootFS real debe contener ELF regulares y privados: $required" >&2
      exit 66
    }
  done
elif [[ "$GUEST_PROGRAM" != "/usr/bin/true" || "$GUEST_COMPONENT_KIND" != "generic" \
  || "$GUEST_ARGUMENT_COUNT" -ne 0 || "$INSTRUMENT_LOW_MEMORY_BIAS" == true ]]; then
  echo "ERROR: las opciones de huésped requieren --real-rootfs." >&2
  exit 64
fi

IDENTITY="${REGRESSION_CODESIGN_IDENTITY:-}"
if [[ -z "$IDENTITY" ]]; then
  IDENTITY="$(security find-identity -v -p codesigning 2>/dev/null \
    | awk '/"Apple Development:/ { print $2; exit }')"
fi
[[ -n "$IDENTITY" && "$IDENTITY" != "-" ]] || {
  echo "ERROR: la prueba endurecida requiere una identidad Apple Development estable." >&2
  exit 69
}

BUILD_DIRECTORY="$(mktemp -d /private/tmp/regression-fli-fex-spawn-supervisor.XXXXXX)"
GUEST_DIAGNOSTIC_DIRECTORY=""
cleanup() {
  local status=$?
  if [[ "$status" -ne 0 && "${REGRESSION_KEEP_FAILED_BUILD:-0}" == "1" ]]; then
    echo "Diagnóstico preservado: $BUILD_DIRECTORY" >&2
    if [[ -n "$GUEST_DIAGNOSTIC_DIRECTORY" ]]; then
      echo "Diagnóstico huésped preservado: $GUEST_DIAGNOSTIC_DIRECTORY" >&2
    fi
    return
  fi
  case "$BUILD_DIRECTORY" in
    /private/tmp/regression-fli-fex-spawn-supervisor.*)
      rm -rf -- "$BUILD_DIRECTORY"
      ;;
  esac
  if [[ -n "$GUEST_DIAGNOSTIC_DIRECTORY" ]]; then
    case "$GUEST_DIAGNOSTIC_DIRECTORY" in
      /private/tmp/regression-fli-fex-process-probe.*)
        rm -rf -- "$GUEST_DIAGNOSTIC_DIRECTORY"
        ;;
    esac
  fi
}
trap cleanup EXIT

RUNTIME_DIRECTORY="$BUILD_DIRECTORY/runtime"
HOST_HOME="$BUILD_DIRECTORY/host-home"
mkdir -m 0700 "$RUNTIME_DIRECTORY" "$HOST_HOME"
RUNTIME_LIBRARY="$RUNTIME_DIRECTORY/libFEXCore.dylib"
FMT_LIBRARY="$RUNTIME_DIRECTORY/libfmt.12.dylib"
HELPER="$RUNTIME_DIRECTORY/fli-fexcore-controlled-helper"
SUPERVISOR="$BUILD_DIRECTORY/fli-posix-spawn-fex-supervisor"
SUPERVISOR_RECEIPT="$BUILD_DIRECTORY/spawn-supervisor.json"
HELPER_RECEIPT="$BUILD_DIRECTORY/fex-helper.json"
HELPER_STDERR="$BUILD_DIRECTORY/fex-helper-stderr.log"
GUEST_STDERR=""
if [[ -n "$REAL_ROOTFS" ]]; then
  GUEST_DIAGNOSTIC_DIRECTORY="$(mktemp -d /private/tmp/regression-fli-fex-process-probe.XXXXXX)"
  GUEST_STDERR="$GUEST_DIAGNOSTIC_DIRECTORY/guest-stderr.log"
fi

cp "$LIBRARY" "$RUNTIME_LIBRARY"
cp -L /opt/homebrew/opt/fmt/lib/libfmt.12.dylib "$FMT_LIBRARY"
install_name_tool -id @rpath/libfmt.12.dylib "$FMT_LIBRARY"
install_name_tool \
  -change /opt/homebrew/opt/fmt/lib/libfmt.12.dylib \
  @loader_path/libfmt.12.dylib \
  "$RUNTIME_LIBRARY"

codesign --force --sign "$IDENTITY" --options runtime "$FMT_LIBRARY" >/dev/null
codesign --force --sign "$IDENTITY" --options runtime "$RUNTIME_LIBRARY" >/dev/null

GUEST_MEMORY_BIAS_DEFINE=""
if [[ "$INSTRUMENT_LOW_MEMORY_BIAS" == true ]]; then
  GUEST_MEMORY_BIAS_DEFINE="-DREGRESSION_FEXCORE_GUEST_MEMORY_BIAS=1"
fi

/usr/bin/c++ \
  -std=c++20 \
  -arch arm64 \
  -O2 \
  -Wall \
  -Wextra \
  -Werror \
  -Wno-unused-parameter \
  -Wno-sign-compare \
  ${GUEST_MEMORY_BIAS_DEFINE:+"$GUEST_MEMORY_BIAS_DEFINE"} \
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
  "$HELPER_SOURCE" \
  -L "$RUNTIME_DIRECTORY" \
  -lFEXCore \
  -Wl,-rpath,@executable_path \
  -o "$HELPER"

/usr/bin/c++ \
  -std=c++20 \
  -arch arm64 \
  -O2 \
  -Wall \
  -Wextra \
  -Werror \
  "$SUPERVISOR_SOURCE" \
  -o "$SUPERVISOR"

codesign --force \
  --sign "$IDENTITY" \
  --options runtime \
  --entitlements "$ENTITLEMENTS" \
  "$HELPER" >/dev/null
codesign --force --sign "$IDENTITY" --options runtime "$SUPERVISOR" >/dev/null

codesign --verify --strict "$FMT_LIBRARY"
codesign --verify --strict "$RUNTIME_LIBRARY"
codesign --verify --strict "$HELPER"
codesign --verify --strict "$SUPERVISOR"

SUPERVISOR_ARGUMENTS=(
  --helper "$HELPER" \
  --host-home "$HOST_HOME" \
  --child-output "$HELPER_RECEIPT" \
  --child-error "$HELPER_STDERR"
)
EXPLICIT_ARGUMENT_COUNT=1
if [[ -n "$REAL_ROOTFS" ]]; then
  for helper_argument in \
    --real-rootfs "$REAL_ROOTFS" \
    --guest-program "$GUEST_PROGRAM" \
    --guest-component-kind "$GUEST_COMPONENT_KIND" \
    --private-stderr-output "$GUEST_STDERR"; do
    SUPERVISOR_ARGUMENTS+=(--helper-arg "$helper_argument")
    EXPLICIT_ARGUMENT_COUNT=$((EXPLICIT_ARGUMENT_COUNT + 1))
  done
  if [[ "$GUEST_ARGUMENT_COUNT" -gt 0 ]]; then
    for guest_argument in "${GUEST_ARGUMENTS[@]}"; do
      SUPERVISOR_ARGUMENTS+=(--helper-arg --guest-arg --helper-arg "$guest_argument")
      EXPLICIT_ARGUMENT_COUNT=$((EXPLICIT_ARGUMENT_COUNT + 2))
    done
  fi
  if [[ "$DIAGNOSTIC_POST_SESSION_SYSCALL_LIMIT" -ne 0 ]]; then
    SUPERVISOR_ARGUMENTS+=(
      --helper-arg --diagnostic-post-session-syscall-limit \
      --helper-arg "$DIAGNOSTIC_POST_SESSION_SYSCALL_LIMIT"
    )
    EXPLICIT_ARGUMENT_COUNT=$((EXPLICIT_ARGUMENT_COUNT + 2))
  fi
  if [[ "$INSTRUMENT_LOW_MEMORY_BIAS" == true ]]; then
    SUPERVISOR_ARGUMENTS+=(--helper-arg --instrument-low-memory-bias)
    EXPLICIT_ARGUMENT_COUNT=$((EXPLICIT_ARGUMENT_COUNT + 1))
  fi
fi

set +e
"$SUPERVISOR" "${SUPERVISOR_ARGUMENTS[@]}" | tee "$SUPERVISOR_RECEIPT"
SUPERVISOR_STATUS=${PIPESTATUS[0]}
set -e

[[ -f "$HELPER_RECEIPT" && ! -L "$HELPER_RECEIPT" \
  && -f "$HELPER_STDERR" && ! -L "$HELPER_STDERR" \
  && "$(stat -f '%z' "$HELPER_RECEIPT")" -le 1048576 \
  && "$(stat -f '%z' "$HELPER_STDERR")" -le 1048576 ]] || {
  echo "ERROR: la salida privada del ayudante falta o supera 1 MiB." >&2
  exit 70
}
if [[ -n "$REAL_ROOTFS" ]]; then
  [[ -f "$GUEST_STDERR" && ! -L "$GUEST_STDERR" \
    && "$(stat -f '%z' "$GUEST_STDERR")" -le 1048576 ]] || {
    echo "ERROR: el stderr huésped privado falta o supera 1 MiB." >&2
    exit 70
  }
fi

umask 077
install -d -m 0700 "$OUTPUT_DIRECTORY"
install -m 0600 "$SUPERVISOR_RECEIPT" "$OUTPUT_DIRECTORY/spawn-supervisor.json"
install -m 0600 "$HELPER_RECEIPT" "$OUTPUT_DIRECTORY/fex-helper.json"
install -m 0600 "$HELPER_STDERR" "$OUTPUT_DIRECTORY/fex-helper-stderr.log"
if [[ -n "$REAL_ROOTFS" ]]; then
  install -m 0600 "$GUEST_STDERR" "$OUTPUT_DIRECTORY/guest-stderr.log"
fi

for assertion in \
  '"host":"macos-arm64"' \
  '"probe":"posix-spawn-external-helper"' \
  '"multithreaded_host":true' \
  '"worker_blocking_at_spawn":true' \
  '"child_stdout_redirected":true' \
  '"child_stderr_redirected":true' \
  '"spawn_signal_mask_explicit":true' \
  '"spawn_signal_defaults_explicit":true' \
  '"spawn_result":0' \
  '"spawned_pid_positive":true' \
  '"waitpid_matches_spawned_pid":true' \
  '"child_exited":true' \
  '"child_exit_code":0' \
  "\"explicit_argument_count\":$EXPLICIT_ARGUMENT_COUNT" \
  '"explicit_environment_count":2' \
  '"explicit_environment_lc_all_c":true' \
  '"explicit_environment_private_host_home":true' \
  '"passed":true'; do
  grep -Fq "$assertion" "$OUTPUT_DIRECTORY/spawn-supervisor.json" || {
    echo "ERROR: falta la aserción del supervisor FEX: $assertion" >&2
    exit 70
  }
done

HELPER_ASSERTIONS=(
  '"parser":"FEX-ELFParser"'
  '"main_elf_loaded":true'
  '"bss_zeroed":true'
  '"initial_stack_present":true'
  '"auxv_present":true'
  '"proton_executed":false'
  '"steam_executed":false'
  '"eac_executed":false'
)
if [[ -n "$REAL_ROOTFS" ]]; then
  HELPER_ASSERTIONS+=(
    "\"main_elf\":\"$GUEST_PROGRAM\""
    "\"guest_arg_count\":$GUEST_ARGUMENT_COUNT"
    "\"guest_component_kind\":\"$GUEST_COMPONENT_KIND\""
    '"guest_entry_executed":true'
    '"mode":"real-glibc-first-syscall"'
    '"pt_interp_resolved":true'
    '"interpreter_elf_loaded":true'
    '"dynamic_interpreter":"private-rootfs-glibc-ld-linux-x86-64"'
    '"glibc_interpreter_mapped":true'
    '"glibc_entry_executed":true'
    '"private_guest_home_directory_present":true'
  )
  if [[ "$GUEST_PROGRAM" == "/usr/bin/true" ]]; then
    HELPER_ASSERTIONS+=(
      '"exit_syscall_seen":true'
      '"exit_code":0'
      '"main_completed":true'
      '"proton_component_executed":false'
    )
  elif [[ "$GUEST_COMPONENT_KIND" == "official-proton-wineserver" ]]; then
    HELPER_ASSERTIONS+=(
      '"proton_component_executed":true'
      '"rt_sigaction_guest_sigpipe_ignore_success_count":1'
    )
    if [[ "$DIAGNOSTIC_POST_SESSION_SYSCALL_LIMIT" -ne 0 ]]; then
      HELPER_ASSERTIONS+=(
        "\"post_session_syscall_diagnostic_limit\":$DIAGNOSTIC_POST_SESSION_SYSCALL_LIMIT"
        '"post_session_syscall_diagnostic_limit_seen":true'
      )
    fi
  fi
else
  HELPER_ASSERTIONS+=(
    '"argv_seen_by_guest":true'
    '"write_syscall_seen":true'
    '"captured_output_match":true'
    '"exit_syscall_seen":true'
    '"exit_code":42'
    '"glibc_loaded":false'
    '"unaligned_backpatch_count":0'
  )
fi
for assertion in "${HELPER_ASSERTIONS[@]}"; do
  grep -Fq "$assertion" "$OUTPUT_DIRECTORY/fex-helper.json" || {
    echo "ERROR: el ayudante FEX no cumplió el contrato controlado: $assertion" >&2
    exit 70
  }
done
if [[ -n "$REAL_ROOTFS" && "$GUEST_PROGRAM" != "/usr/bin/true" ]] \
  && ! grep -Eq '"first_unsupported_syscall":[0-9]+' "$OUTPUT_DIRECTORY/fex-helper.json" \
  && ! grep -Fq '"main_completed":true' "$OUTPUT_DIRECTORY/fex-helper.json" \
  && ! grep -Fq '"exit_syscall_seen":true' "$OUTPUT_DIRECTORY/fex-helper.json" \
  && ! grep -Fq '"guest_signal_boundary_seen":true' "$OUTPUT_DIRECTORY/fex-helper.json" \
  && ! grep -Fq '"post_session_syscall_diagnostic_limit_seen":true' "$OUTPUT_DIRECTORY/fex-helper.json"; then
  echo "ERROR: el ayudante FEX no alcanzó una frontera observable." >&2
  exit 70
fi

[[ "$SUPERVISOR_STATUS" -eq 0 ]] || {
  echo "Resultado negativo reproducible preservado: $OUTPUT_DIRECTORY" >&2
  exit "$SUPERVISOR_STATUS"
}

shasum -a 256 \
  "$HELPER_SOURCE" \
  "$SUPERVISOR_SOURCE" \
  "$COMPAT_DIRECTORY/elf.h" \
  "$COMPAT_DIRECTORY/linux/limits.h" \
  "$ELF_PARSER_HEADER" \
  "$ELF_CONTAINER_HEADER" \
  | sed "s#  $ROOT/#  repository/#; s#  $FEX_SOURCE/#  upstream-fex/#" \
  > "$OUTPUT_DIRECTORY/sources.sha256"
shasum -a 256 "$LIBRARY" \
  | awk '{ print $1 "  input-libFEXCore.dylib" }' \
  > "$OUTPUT_DIRECTORY/library.sha256"
shasum -a 256 "$SUPERVISOR" "$HELPER" \
  | awk 'NR == 1 { print $1 "  ephemeral-signed-supervisor" }
         NR == 2 { print $1 "  ephemeral-signed-fex-helper" }' \
  > "$OUTPUT_DIRECTORY/binaries.sha256"
if [[ -n "$REAL_ROOTFS" ]]; then
  shasum -a 256 \
    "$REAL_ROOTFS$GUEST_PROGRAM" \
    "$REAL_ROOTFS/usr/lib64/ld-linux-x86-64.so.2" \
    "$REAL_ROOTFS/usr/lib64/libc.so.6" \
    | sed "s#  $REAL_ROOTFS/#  rootfs/#" \
    > "$OUTPUT_DIRECTORY/rootfs.sha256"
fi
{
  printf 'schema=%s\n' '1'
  printf 'scope=%s\n' 'isolated-multithreaded-posix-spawn-fex-helper'
  printf 'signature=%s\n' 'apple-development-valid'
  printf 'hardened_runtime=%s\n' 'yes'
  printf 'helper_entitlement=%s\n' 'allow-jit'
  if [[ -n "$REAL_ROOTFS" ]]; then
    printf 'guest=%s\n' "$GUEST_PROGRAM"
    printf 'guest_component_kind=%s\n' "$GUEST_COMPONENT_KIND"
    printf 'guest_argument_count=%s\n' "$GUEST_ARGUMENT_COUNT"
    printf 'instrument_low_memory_bias=%s\n' "$INSTRUMENT_LOW_MEMORY_BIAS"
    printf 'diagnostic_post_session_syscall_limit=%s\n' "$DIAGNOSTIC_POST_SESSION_SYSCALL_LIMIT"
    printf 'glibc=%s\n' 'private-rootfs-entry-executed'
  else
    printf 'guest=%s\n' 'controlled-x86-64-elf-fixture'
    printf 'glibc=%s\n' 'not-loaded'
  fi
  printf 'wine=%s\n' 'not-executed'
  printf 'proton=%s\n' 'not-executed'
  printf 'steam=%s\n' 'not-executed'
  printf 'game=%s\n' 'not-executed'
  printf 'eac=%s\n' 'not-executed'
  printf 'supervisor_exit_status=%s\n' "$SUPERVISOR_STATUS"
} > "$OUTPUT_DIRECTORY/scope.txt"
(
  cd "$OUTPUT_DIRECTORY"
  TREE_FILES=(
    spawn-supervisor.json
    fex-helper.json
    fex-helper-stderr.log
    sources.sha256
    library.sha256
    binaries.sha256
    scope.txt
  )
  [[ -f guest-stderr.log ]] && TREE_FILES+=(guest-stderr.log)
  [[ -f rootfs.sha256 ]] && TREE_FILES+=(rootfs.sha256)
  shasum -a 256 "${TREE_FILES[@]}" > tree.sha256
)
chmod 0600 "$OUTPUT_DIRECTORY"/*

echo "Ayudante FEXCore separado creado por posix_spawn y validado: $OUTPUT_DIRECTORY"
