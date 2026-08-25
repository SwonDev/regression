#!/usr/bin/env bash

set -euo pipefail

# Ejecuta el bootstrap de proceso Linux x86-64 estrictamente controlado o una
# frontera incremental con ld-linux/glibc reales. El modo Wine64 puede cargar
# ese componente oficial de Proton, pero nunca el orquestador, Steam, juegos o EAC.

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
PROBE_SOURCE="$ROOT/tools/research/fli_fexcore_process_probe.cpp"
COMPAT_DIRECTORY="$ROOT/tools/research/fli_compat"
ENTITLEMENTS="$ROOT/tools/research/fli_nonvm_host_probe.entitlements"
DEBUG_ENTITLEMENTS="$ROOT/tools/research/fli_nonvm_host_probe_debug.entitlements"
LIBRARY=""
FEX_SOURCE=""
FEX_BUILD=""
OUTPUT_DIRECTORY=""
REAL_ROOTFS=""
GUEST_PROGRAM="/usr/bin/true"
GUEST_ARGUMENTS=()
GUEST_ARGUMENT_COUNT=0
GUEST_COMPONENT_KIND="generic"
PRIVATE_IR_DUMP_DIRECTORY=""
DISASSEMBLE_HOST_BLOCKS=0
INSTRUMENT_LOW_PAGE_ALIAS=0
INSTRUMENT_LOW_MEMORY_BIAS=0
INSTRUMENT_HIGH_MEMORY_REGION=0
INSTRUMENT_VFORK_CHILD=0
INSTRUMENT_VFORK_PARENT=0
INSTRUMENT_VFORK_PARENT_PROCESS_BRIDGE=0
INSTRUMENT_VFORK_PARENT_WINESERVER_BRIDGE=0
GUEST_BIND_NOW=0
INITIAL_WINE_COMMAND_LINE=0
WINE_ARCH_WOW64=0
CX_ALT_LOADER_SOCKET=""
CX_ALT_LOADER_HOST_SOCKET=""
INHERITED_WINESERVER_SOCKET_FD=-1
GUEST_STDIN_FD=-1
GUEST_STDOUT_FD=-1
GUEST_STDERR_FD=-1
REAL_ROOTFS_WINE_PREFIX_PRESENT_BEFORE=0

usage() {
  cat <<'EOF'
Uso: tools/research/run_fli_fexcore_process_probe.sh \
  --library RUTA --fex-source RUTA --fex-build RUTA \
  --output-dir RUTA_PRIVADA [--real-rootfs RUTA_PRIVADA \
  [--guest-program /RUTA_ABSOLUTA] [--guest-arg VALOR]... \
  [--guest-component-kind generic|official-proton-wine64|official-proton-wine64-preloader|official-proton-wineserver] \
  [--private-ir-dump-dir DIRECTORIO_PRIVADO_EXISTENTE] \
  [--private-host-disassembly] \
  [--instrument-low-page-alias|--instrument-low-memory-bias] \
  [--instrument-high-memory-region] \
  [--instrument-vfork-child|--instrument-vfork-parent|--instrument-vfork-parent-process-bridge|--instrument-vfork-parent-wineserver-bridge] [--guest-bind-now] \
  [--initial-wine-command-line] [--wine-arch-wow64] \
  [--cx-alt-loader-socket /tmp/SOCKET --cx-alt-loader-host-socket /private/tmp/SOCKET] \
  [--inherited-wineserver-socket-fd FD] \
  [--guest-stdin-fd FD --guest-stdout-fd FD --guest-stderr-fd FD]]

Sin --real-rootfs ejecuta el par ELF controlado. Con --real-rootfs carga
el ejecutable huésped solicitado y ld-linux x86-64 reales, y se detiene en la
primera frontera de syscall todavía no implementada. El ejecutable predeterminado
es /usr/bin/true. No carga el orquestador Proton, Steam, juegos ni EAC.
El alias instrumental solo acepta la shared user data Linux exacta en
0x7ffe0000 y no crea un mapeo host en esa dirección.
El candidato de bias reserva un shadow alto de 4 GiB y traduce allí únicamente
los accesos lógicos bajos; permanece apagado salvo petición explícita.
La ventana alta instrumental añade únicamente 16 MiB lógicos desde 4 GiB,
respaldados por páginas host ordinarias y exige el shadow bajo de la misma A/B.
La rama vfork instrumental sigue solo el hijo hasta su próxima frontera; no
crea un proceso, no reanuda al padre y permanece apagada por defecto.
La rama padre vfork devuelve únicamente un PID diagnóstico acotado para medir
el siguiente syscall del padre; tampoco crea un proceso y permanece apagada.
El puente de proceso padre vfork crea un hijo host firmado real, devuelve su PID
y traduce únicamente el wait4 exacto observado; no inicia wineserver ni Proton.
El puente wineserver conserva ese PID/wait y añade únicamente el wineserver -f
oficial en el mismo RootFS/prefijo privado; no inicia el orquestador Proton.
El socket alternativo reproduce solo el contrato público de Wine/CrossOver.
La ruta huésped bajo /tmp se traduce únicamente al socket host corto, privado
y explícito pasado junto a ella; el resto de sockets sigue confinado al RootFS.
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
    --private-ir-dump-dir)
      [[ $# -ge 2 ]] || { usage >&2; exit 64; }
      PRIVATE_IR_DUMP_DIRECTORY="$2"
      shift 2
      ;;
    --private-host-disassembly)
      DISASSEMBLE_HOST_BLOCKS=1
      shift
      ;;
    --instrument-low-page-alias)
      INSTRUMENT_LOW_PAGE_ALIAS=1
      shift
      ;;
    --instrument-low-memory-bias)
      INSTRUMENT_LOW_MEMORY_BIAS=1
      shift
      ;;
    --instrument-high-memory-region)
      INSTRUMENT_HIGH_MEMORY_REGION=1
      shift
      ;;
    --instrument-vfork-child)
      INSTRUMENT_VFORK_CHILD=1
      shift
      ;;
    --instrument-vfork-parent)
      INSTRUMENT_VFORK_PARENT=1
      shift
      ;;
    --instrument-vfork-parent-process-bridge)
      INSTRUMENT_VFORK_PARENT_PROCESS_BRIDGE=1
      shift
      ;;
    --instrument-vfork-parent-wineserver-bridge)
      INSTRUMENT_VFORK_PARENT_WINESERVER_BRIDGE=1
      shift
      ;;
    --guest-bind-now)
      GUEST_BIND_NOW=1
      shift
      ;;
    --initial-wine-command-line)
      INITIAL_WINE_COMMAND_LINE=1
      shift
      ;;
    --wine-arch-wow64)
      WINE_ARCH_WOW64=1
      shift
      ;;
    --cx-alt-loader-socket)
      [[ $# -ge 2 ]] || { usage >&2; exit 64; }
      CX_ALT_LOADER_SOCKET="$2"
      shift 2
      ;;
    --cx-alt-loader-host-socket)
      [[ $# -ge 2 ]] || { usage >&2; exit 64; }
      CX_ALT_LOADER_HOST_SOCKET="$2"
      shift 2
      ;;
    --inherited-wineserver-socket-fd)
      [[ $# -ge 2 ]] || { usage >&2; exit 64; }
      [[ "$2" =~ ^[0-9]+$ && "$2" -gt 2 && "$2" -le 65535 ]] || {
        echo "ERROR: el descriptor heredado de wineserver no es válido." >&2
        exit 64
      }
      INHERITED_WINESERVER_SOCKET_FD="$2"
      shift 2
      ;;
    --guest-stdin-fd|--guest-stdout-fd|--guest-stderr-fd)
      [[ $# -ge 2 ]] || { usage >&2; exit 64; }
      [[ "$2" =~ ^[0-9]+$ && "$2" -gt 2 && "$2" -le 65535 ]] || {
        echo "ERROR: el descriptor estándar huésped no es válido." >&2
        exit 64
      }
      case "$1" in
        --guest-stdin-fd) GUEST_STDIN_FD="$2" ;;
        --guest-stdout-fd) GUEST_STDOUT_FD="$2" ;;
        --guest-stderr-fd) GUEST_STDERR_FD="$2" ;;
      esac
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
[[ -f "$PROBE_SOURCE" && -f "$COMPAT_DIRECTORY/elf.h" \
  && -f "$COMPAT_DIRECTORY/linux/limits.h" && -f "$ENTITLEMENTS" \
  && -f "$DEBUG_ENTITLEMENTS" ]] || {
  echo "ERROR: faltan la sonda, la compatibilidad ELF o sus entitlements." >&2
  exit 66
}
[[ -n "$OUTPUT_DIRECTORY" && ! -e "$OUTPUT_DIRECTORY" && ! -L "$OUTPUT_DIRECTORY" ]] || {
  echo "ERROR: --output-dir debe ser una ruta privada nueva." >&2
  exit 66
}
if [[ -n "$REAL_ROOTFS" ]]; then
  GUEST_STANDARD_FD_COUNT=0
  [[ "$GUEST_STDIN_FD" -ge 0 ]] && GUEST_STANDARD_FD_COUNT=$((GUEST_STANDARD_FD_COUNT + 1))
  [[ "$GUEST_STDOUT_FD" -ge 0 ]] && GUEST_STANDARD_FD_COUNT=$((GUEST_STANDARD_FD_COUNT + 1))
  [[ "$GUEST_STDERR_FD" -ge 0 ]] && GUEST_STANDARD_FD_COUNT=$((GUEST_STANDARD_FD_COUNT + 1))
  [[ "$GUEST_STANDARD_FD_COUNT" -eq 0 || "$GUEST_STANDARD_FD_COUNT" -eq 3 ]] || {
    echo "ERROR: los tres descriptores estándar huéspedes deben proporcionarse juntos." >&2
    exit 64
  }
  if [[ "$GUEST_STANDARD_FD_COUNT" -eq 3 ]]; then
    [[ "$DISASSEMBLE_HOST_BLOCKS" -eq 0 ]] || {
      echo "ERROR: la desensamblación host no admite descriptores estándar huéspedes externos." >&2
      exit 64
    }
    for guest_standard_fd in "$GUEST_STDIN_FD" "$GUEST_STDOUT_FD" "$GUEST_STDERR_FD"; do
      [[ -e "/dev/fd/$guest_standard_fd" ]] || {
        echo "ERROR: un descriptor estándar huésped no está abierto." >&2
        exit 66
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
  if [[ "$GUEST_COMPONENT_KIND" == "official-proton-wine64" \
    && "$GUEST_PROGRAM" != "/opt/proton/files/lib/wine/x86_64-unix/wine64" ]]; then
    echo "ERROR: el componente Proton Wine64 exige su ruta invitada canónica." >&2
    exit 64
  fi
  if [[ "$GUEST_COMPONENT_KIND" == "official-proton-wine64-preloader" \
    && "$GUEST_PROGRAM" != "/opt/proton/files/lib/wine/x86_64-unix/wine-preloader" \
    && "$GUEST_PROGRAM" != "/opt/proton/files/lib/wine/x86_64-unix/wine64-preloader" ]]; then
    echo "ERROR: el preloader Proton Wine64 exige su ruta invitada canónica." >&2
    exit 64
  fi
  if [[ "$GUEST_COMPONENT_KIND" == "official-proton-wineserver" \
    && "$GUEST_PROGRAM" != "/opt/proton/files/bin/wineserver" ]]; then
    echo "ERROR: wineserver oficial exige su ruta invitada canónica." >&2
    exit 64
  fi
  if [[ "$INSTRUMENT_LOW_PAGE_ALIAS" -eq 1 \
    && "$GUEST_COMPONENT_KIND" != "official-proton-wine64-preloader" ]]; then
    echo "ERROR: el alias bajo instrumental solo se admite con el preloader Wine64 oficial." >&2
    exit 64
  fi
  if [[ "$INSTRUMENT_LOW_MEMORY_BIAS" -eq 1 \
    && "$GUEST_COMPONENT_KIND" != "official-proton-wine64-preloader" ]]; then
    echo "ERROR: el bias bajo instrumental solo se admite con el preloader Wine64 oficial." >&2
    exit 64
  fi
  if [[ "$INSTRUMENT_HIGH_MEMORY_REGION" -eq 1 \
    && "$GUEST_COMPONENT_KIND" != "official-proton-wine64-preloader" ]]; then
    echo "ERROR: la ventana alta instrumental solo se admite con el preloader Wine64 oficial." >&2
    exit 64
  fi
  if [[ "$INSTRUMENT_HIGH_MEMORY_REGION" -eq 1 \
    && "$INSTRUMENT_LOW_MEMORY_BIAS" -ne 1 ]]; then
    echo "ERROR: la ventana alta instrumental exige --instrument-low-memory-bias." >&2
    exit 64
  fi
  if [[ "$INSTRUMENT_LOW_PAGE_ALIAS" -eq 1 && "$INSTRUMENT_LOW_MEMORY_BIAS" -eq 1 ]]; then
    echo "ERROR: alias y bias bajo son candidatos A/B mutuamente excluyentes." >&2
    exit 64
  fi
  if [[ "$INITIAL_WINE_COMMAND_LINE" -eq 1 ]]; then
    [[ "$GUEST_COMPONENT_KIND" == "official-proton-wine64-preloader" \
      && "$GUEST_ARGUMENT_COUNT" -ge 2 \
      && "${GUEST_ARGUMENTS[0]}" == "/opt/proton/files/lib/wine/x86_64-unix/wine" \
      && -f "$REAL_ROOTFS${GUEST_ARGUMENTS[0]}" \
      && ! -L "$REAL_ROOTFS${GUEST_ARGUMENTS[0]}" ]] || {
      echo "ERROR: la línea inicial de Wine exige preloader, loader y programa oficiales." >&2
      exit 64
    }
  fi
  if [[ "$WINE_ARCH_WOW64" -eq 1 ]]; then
    [[ "$GUEST_COMPONENT_KIND" == "official-proton-wine64-preloader" \
      && "$GUEST_ARGUMENT_COUNT" -ge 2 \
      && "${GUEST_ARGUMENTS[0]}" == "/opt/proton/files/lib/wine/x86_64-unix/wine" \
      && -f "$REAL_ROOTFS${GUEST_ARGUMENTS[0]}" \
      && ! -L "$REAL_ROOTFS${GUEST_ARGUMENTS[0]}" ]] || {
      echo "ERROR: WINEARCH=wow64 exige preloader, loader y programa oficiales." >&2
      exit 64
    }
  fi
  if [[ "$INHERITED_WINESERVER_SOCKET_FD" -ge 0 ]]; then
    [[ "$GUEST_COMPONENT_KIND" == "official-proton-wine64-preloader"
      && -e "/dev/fd/$INHERITED_WINESERVER_SOCKET_FD" ]] || {
      echo "ERROR: el socket heredado exige preloader oficial y un descriptor abierto." >&2
      exit 66
    }
  fi
  [[ "$GUEST_PROGRAM" =~ ^/[A-Za-z0-9_+./-]+$ \
    && "/$GUEST_PROGRAM/" != *"/../"* \
    && "/$GUEST_PROGRAM/" != *"/./"* \
    && "$GUEST_PROGRAM" != *"//"* ]] || {
    echo "ERROR: --guest-program debe ser una ruta invitada absoluta y normalizada." >&2
    exit 64
  }
  for required in \
    "$REAL_ROOTFS$GUEST_PROGRAM" \
    "$REAL_ROOTFS/usr/lib64/ld-linux-x86-64.so.2" \
    "$REAL_ROOTFS/usr/lib64/libc.so.6"; do
    [[ -f "$required" && ! -L "$required" ]] || {
      echo "ERROR: el RootFS real debe contener ELF regulares y privados: $required" >&2
      exit 66
    }
  done
  if [[ -d "$REAL_ROOTFS/home/regression/.wine" \
    && ! -L "$REAL_ROOTFS/home/regression/.wine" ]]; then
    REAL_ROOTFS_WINE_PREFIX_PRESENT_BEFORE=1
  fi
  if [[ -n "$PRIVATE_IR_DUMP_DIRECTORY" ]]; then
    [[ -d "$PRIVATE_IR_DUMP_DIRECTORY" && ! -L "$PRIVATE_IR_DUMP_DIRECTORY" \
      && "$(stat -f '%Su' "$PRIVATE_IR_DUMP_DIRECTORY")" == "$(id -un)" \
      && "$(stat -f '%Lp' "$PRIVATE_IR_DUMP_DIRECTORY")" == "700" ]] || {
      echo "ERROR: --private-ir-dump-dir debe ser un directorio 0700 propio y existente." >&2
      exit 66
    }
  fi
  PROTON_NTDLL="$REAL_ROOTFS/opt/proton/files/lib/wine/x86_64-unix/ntdll.so"
  PROTON_LIBGCC="$REAL_ROOTFS/usr/lib64/libgcc_s.so.1"
  if [[ -e "$PROTON_NTDLL" || -L "$PROTON_NTDLL" \
    || -e "$PROTON_LIBGCC" || -L "$PROTON_LIBGCC" ]]; then
    [[ "$GUEST_COMPONENT_KIND" == "official-proton-wine64" \
      || "$GUEST_COMPONENT_KIND" == "official-proton-wine64-preloader" ]] || {
      echo "ERROR: el cierre ntdll+libgcc solo pertenece a Wine64 oficial." >&2
      exit 66
    }
    for required in "$PROTON_NTDLL" "$PROTON_LIBGCC"; do
      [[ -f "$required" && ! -L "$required" ]] || {
        echo "ERROR: el cierre ntdll+libgcc debe estar completo y ser regular: $required" >&2
        exit 66
      }
    done
  fi
  [[ $GUEST_ARGUMENT_COUNT -le 32 ]] || {
    echo "ERROR: la sonda admite como máximo 32 argumentos huéspedes." >&2
    exit 64
  }
  if [[ $GUEST_ARGUMENT_COUNT -gt 0 ]]; then
    for guest_argument in "${GUEST_ARGUMENTS[@]}"; do
      [[ ${#guest_argument} -le 4096 ]] || {
        echo "ERROR: un argumento huésped supera 4096 caracteres." >&2
        exit 64
      }
    done
  fi
elif [[ "$GUEST_PROGRAM" != "/usr/bin/true" || $GUEST_ARGUMENT_COUNT -ne 0 ]]; then
  echo "ERROR: --guest-program y --guest-arg requieren --real-rootfs." >&2
  exit 64
fi
VFORK_MODE_COUNT=$((INSTRUMENT_VFORK_CHILD + INSTRUMENT_VFORK_PARENT + INSTRUMENT_VFORK_PARENT_PROCESS_BRIDGE + INSTRUMENT_VFORK_PARENT_WINESERVER_BRIDGE))
if [[ "$VFORK_MODE_COUNT" -gt 1 ]]; then
  echo "ERROR: las ramas diagnósticas de vfork son mutuamente excluyentes." >&2
  exit 64
fi
if [[ "$VFORK_MODE_COUNT" -eq 1 ]]; then
  if [[ "$INSTRUMENT_LOW_MEMORY_BIAS" -ne 1 \
    || "$GUEST_COMPONENT_KIND" != "official-proton-wine64-preloader" ]]; then
    echo "ERROR: la rama vfork instrumental exige preloader oficial y bias bajo." >&2
    exit 64
  fi
fi
if [[ "$INSTRUMENT_VFORK_PARENT_WINESERVER_BRIDGE" -eq 1 ]]; then
  [[ -f "$REAL_ROOTFS/opt/proton/files/bin/wineserver" \
    && ! -L "$REAL_ROOTFS/opt/proton/files/bin/wineserver" \
    && -d "$REAL_ROOTFS/home/regression/.wine" \
    && ! -L "$REAL_ROOTFS/home/regression/.wine" ]] || {
    echo "ERROR: el puente wineserver exige binario oficial y prefijo privado regulares." >&2
    exit 66
  }
fi
if [[ "$GUEST_BIND_NOW" -eq 1 ]]; then
  if [[ "$GUEST_COMPONENT_KIND" != "official-proton-wine64-preloader" \
      || "$INSTRUMENT_VFORK_CHILD" -eq 1 \
      || "$INSTRUMENT_VFORK_PARENT" -eq 1 \
      || "$INSTRUMENT_VFORK_PARENT_PROCESS_BRIDGE" -eq 1 \
      || "$INSTRUMENT_VFORK_PARENT_WINESERVER_BRIDGE" -eq 1 ]]; then
    echo "ERROR: LD_BIND_NOW diagnóstico exige el preloader oficial sin rama vfork." >&2
    exit 64
  fi
fi
if [[ -z "$REAL_ROOTFS" && "$INSTRUMENT_LOW_PAGE_ALIAS" -eq 1 ]]; then
  echo "ERROR: --instrument-low-page-alias requiere --real-rootfs." >&2
  exit 64
fi
if [[ -z "$REAL_ROOTFS" && "$INSTRUMENT_LOW_MEMORY_BIAS" -eq 1 ]]; then
  echo "ERROR: --instrument-low-memory-bias requiere --real-rootfs." >&2
  exit 64
fi
if [[ -z "$REAL_ROOTFS" && "$INSTRUMENT_HIGH_MEMORY_REGION" -eq 1 ]]; then
  echo "ERROR: --instrument-high-memory-region requiere --real-rootfs." >&2
  exit 64
fi
if [[ -z "$REAL_ROOTFS" && "$INITIAL_WINE_COMMAND_LINE" -eq 1 ]]; then
  echo "ERROR: --initial-wine-command-line requiere --real-rootfs." >&2
  exit 64
fi
if [[ -z "$REAL_ROOTFS" && "$WINE_ARCH_WOW64" -eq 1 ]]; then
  echo "ERROR: --wine-arch-wow64 requiere --real-rootfs." >&2
  exit 64
fi
if [[ -n "$CX_ALT_LOADER_SOCKET" || -n "$CX_ALT_LOADER_HOST_SOCKET" ]]; then
  CX_ALT_LOADER_HOST_PARENT="$(cd "$(dirname "$CX_ALT_LOADER_HOST_SOCKET")" 2>/dev/null && pwd -P)" || {
    echo "ERROR: no se pudo resolver el directorio del socket alternativo host." >&2
    exit 66
  }
  [[ -n "$REAL_ROOTFS" \
    && -n "$CX_ALT_LOADER_SOCKET" \
    && -n "$CX_ALT_LOADER_HOST_SOCKET" \
    && "$GUEST_COMPONENT_KIND" == "official-proton-wine64-preloader" \
    && "$CX_ALT_LOADER_SOCKET" == /tmp/* \
    && "$CX_ALT_LOADER_SOCKET" != *'/../'* \
    && "$CX_ALT_LOADER_SOCKET" != *'/./'* \
    && "$CX_ALT_LOADER_HOST_PARENT" == /private/tmp/regression-fli-cx-alt-loader.* \
    && "${#CX_ALT_LOADER_HOST_SOCKET}" -lt 104 \
    && -S "$CX_ALT_LOADER_HOST_SOCKET" \
    && "$(stat -f '%Su' "$CX_ALT_LOADER_HOST_SOCKET")" == "$(id -un)" \
    && "$(stat -f '%OLp' "$CX_ALT_LOADER_HOST_SOCKET")" == "600" \
    && "$(stat -f '%Su' "$CX_ALT_LOADER_HOST_PARENT")" == "$(id -un)" \
    && "$(stat -f '%OLp' "$CX_ALT_LOADER_HOST_PARENT")" == "700" ]] || {
    echo "ERROR: el socket alternativo exige un par huésped/host corto y privado del usuario." >&2
    exit 66
  }
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

BUILD_DIRECTORY="$(mktemp -d /private/tmp/regression-fli-fex-process-probe.XXXXXX)"
cleanup() {
  local status=$?
  if [[ "$status" -ne 0 && "${REGRESSION_KEEP_FAILED_BUILD:-0}" == "1" ]]; then
    echo "Diagnóstico preservado: $BUILD_DIRECTORY" >&2
    return
  fi
  case "$BUILD_DIRECTORY" in
    /private/tmp/regression-fli-fex-process-probe.*)
      rm -rf -- "$BUILD_DIRECTORY"
      ;;
  esac
}
trap cleanup EXIT

RUNTIME_DIRECTORY="$BUILD_DIRECTORY/runtime"
mkdir -m 0700 "$RUNTIME_DIRECTORY"
RUNTIME_LIBRARY="$RUNTIME_DIRECTORY/libFEXCore.dylib"
FMT_LIBRARY="$RUNTIME_DIRECTORY/libfmt.12.dylib"
PROBE="$RUNTIME_DIRECTORY/fli-fexcore-process-probe"
PRIVATE_GUEST_STDERR="$BUILD_DIRECTORY/guest-stderr.log"
PRIVATE_HOST_DISASSEMBLY="$BUILD_DIRECTORY/host-disassembly.log"
VFORK_WINESERVER_BRIDGE_DIRECTORY="$BUILD_DIRECTORY/vfork-wineserver-bridge"
if [[ "$INSTRUMENT_VFORK_PARENT_WINESERVER_BRIDGE" -eq 1 ]]; then
  mkdir -m 0700 "$VFORK_WINESERVER_BRIDGE_DIRECTORY"
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

OPTIMIZATION_FLAGS=(-O2)
SIGN_ENTITLEMENTS="$ENTITLEMENTS"
GUEST_MEMORY_BIAS_DEFINE=""
if [[ "${REGRESSION_FLI_PROBE_DEBUG:-0}" == "1" \
  && "${REGRESSION_FLI_PROBE_DEBUG_OPTIMIZED:-0}" == "1" ]]; then
  echo "ERROR: los modos de depuración O0 y O2 son mutuamente excluyentes." >&2
  exit 64
elif [[ "${REGRESSION_FLI_PROBE_DEBUG:-0}" == "1" ]]; then
  OPTIMIZATION_FLAGS=(-O0 -g)
  SIGN_ENTITLEMENTS="$DEBUG_ENTITLEMENTS"
elif [[ "${REGRESSION_FLI_PROBE_DEBUG_OPTIMIZED:-0}" == "1" ]]; then
  OPTIMIZATION_FLAGS=(-O2 -g)
  SIGN_ENTITLEMENTS="$DEBUG_ENTITLEMENTS"
fi
if [[ "$INSTRUMENT_LOW_MEMORY_BIAS" -eq 1 \
  || "$INSTRUMENT_HIGH_MEMORY_REGION" -eq 1 ]]; then
  GUEST_MEMORY_BIAS_DEFINE="-DREGRESSION_FEXCORE_GUEST_MEMORY_BIAS=1"
fi
if [[ "$VFORK_MODE_COUNT" -eq 1 ]]; then
  GUEST_MEMORY_BIAS_DEFINE="-DREGRESSION_FEXCORE_GUEST_MEMORY_BIAS=1"
fi

/usr/bin/c++ \
  -std=c++20 \
  -arch arm64 \
  -Wall \
  -Wextra \
  -Werror \
  -Wno-unused-parameter \
  -Wno-sign-compare \
  "${OPTIMIZATION_FLAGS[@]}" \
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
  "$PROBE_SOURCE" \
  -L "$RUNTIME_DIRECTORY" \
  -lFEXCore \
  -Wl,-rpath,@executable_path \
  -o "$PROBE"

codesign --force \
  --sign "$IDENTITY" \
  --options runtime \
  --entitlements "$SIGN_ENTITLEMENTS" \
  "$PROBE" >/dev/null

codesign --verify --strict "$FMT_LIBRARY"
codesign --verify --strict "$RUNTIME_LIBRARY"
codesign --verify --strict "$PROBE"

RECEIPT="$BUILD_DIRECTORY/process-probe.json"
if [[ -n "$REAL_ROOTFS" ]]; then
  install -m 0600 /dev/null "$RECEIPT"
  PROBE_ARGUMENTS=(
    --real-rootfs "$REAL_ROOTFS"
    --guest-program "$GUEST_PROGRAM"
    --guest-component-kind "$GUEST_COMPONENT_KIND"
    --private-stderr-output "$PRIVATE_GUEST_STDERR"
    --private-receipt-output "$RECEIPT"
  )
  if [[ -n "$PRIVATE_IR_DUMP_DIRECTORY" ]]; then
    PROBE_ARGUMENTS+=(--private-ir-dump-dir "$PRIVATE_IR_DUMP_DIRECTORY")
  fi
  if [[ "$DISASSEMBLE_HOST_BLOCKS" -eq 1 ]]; then
    PROBE_ARGUMENTS+=(--disassemble-host-blocks)
  fi
  if [[ $GUEST_ARGUMENT_COUNT -gt 0 ]]; then
    for guest_argument in "${GUEST_ARGUMENTS[@]}"; do
      PROBE_ARGUMENTS+=(--guest-arg "$guest_argument")
    done
  fi
  if [[ "$INSTRUMENT_LOW_PAGE_ALIAS" -eq 1 ]]; then
    PROBE_ARGUMENTS+=(--instrument-low-page-alias)
  fi
  if [[ "$INSTRUMENT_LOW_MEMORY_BIAS" -eq 1 ]]; then
    PROBE_ARGUMENTS+=(--instrument-low-memory-bias)
  fi
  if [[ "$INSTRUMENT_HIGH_MEMORY_REGION" -eq 1 ]]; then
    PROBE_ARGUMENTS+=(--instrument-high-memory-region)
  fi
  if [[ "$INSTRUMENT_VFORK_CHILD" -eq 1 ]]; then
    PROBE_ARGUMENTS+=(--instrument-vfork-child)
  fi
  if [[ "$INSTRUMENT_VFORK_PARENT" -eq 1 ]]; then
    PROBE_ARGUMENTS+=(--instrument-vfork-parent)
  fi
  if [[ "$INSTRUMENT_VFORK_PARENT_PROCESS_BRIDGE" -eq 1 ]]; then
    PROBE_ARGUMENTS+=(--instrument-vfork-parent-process-bridge)
  fi
  if [[ "$INSTRUMENT_VFORK_PARENT_WINESERVER_BRIDGE" -eq 1 ]]; then
    PROBE_ARGUMENTS+=(
      --instrument-vfork-parent-wineserver-bridge
      --vfork-wineserver-bridge-dir "$VFORK_WINESERVER_BRIDGE_DIRECTORY"
    )
  fi
  if [[ "$GUEST_BIND_NOW" -eq 1 ]]; then
    PROBE_ARGUMENTS+=(--guest-bind-now)
  fi
  if [[ "$INITIAL_WINE_COMMAND_LINE" -eq 1 ]]; then
    PROBE_ARGUMENTS+=(--initial-wine-command-line)
  fi
  if [[ "$WINE_ARCH_WOW64" -eq 1 ]]; then
    PROBE_ARGUMENTS+=(--wine-arch-wow64)
  fi
  if [[ -n "$CX_ALT_LOADER_SOCKET" ]]; then
    PROBE_ARGUMENTS+=(
      --cx-alt-loader-socket "$CX_ALT_LOADER_SOCKET"
      --cx-alt-loader-host-socket "$CX_ALT_LOADER_HOST_SOCKET"
    )
  fi
  if [[ "$INHERITED_WINESERVER_SOCKET_FD" -ge 0 ]]; then
    PROBE_ARGUMENTS+=(
      --inherited-wineserver-socket-fd "$INHERITED_WINESERVER_SOCKET_FD"
    )
  fi
  if [[ "$DISASSEMBLE_HOST_BLOCKS" -eq 1 ]]; then
    "$PROBE" "${PROBE_ARGUMENTS[@]}" 2>"$PRIVATE_HOST_DISASSEMBLY"
    [[ -f "$PRIVATE_HOST_DISASSEMBLY" && ! -L "$PRIVATE_HOST_DISASSEMBLY" \
      && "$(stat -f '%z' "$PRIVATE_HOST_DISASSEMBLY")" -le 134217728 ]] || {
      echo "ERROR: la desensamblación host privada falta o supera 128 MiB." >&2
      exit 70
    }
  else
    if [[ "$GUEST_STANDARD_FD_COUNT" -eq 3 ]]; then
      "$PROBE" "${PROBE_ARGUMENTS[@]}" \
        <&"$GUEST_STDIN_FD" >&"$GUEST_STDOUT_FD" 2>&"$GUEST_STDERR_FD"
    else
      "$PROBE" "${PROBE_ARGUMENTS[@]}"
    fi
  fi
  [[ -f "$PRIVATE_GUEST_STDERR" && ! -L "$PRIVATE_GUEST_STDERR" \
    && "$(stat -f '%z' "$PRIVATE_GUEST_STDERR")" -le 1048576 ]] || {
    echo "ERROR: el diagnóstico huésped privado falta o supera 1 MiB." >&2
    exit 70
  }
  # Un resultado negativo es evidencia de I+D: se conserva antes de evaluar
  # las hipótesis del runner para que una aserción descartada no lo destruya.
  install -d -m 0700 "$OUTPUT_DIRECTORY"
  install -m 0600 "$RECEIPT" "$OUTPUT_DIRECTORY/process-probe.json"
  install -m 0600 "$PRIVATE_GUEST_STDERR" "$OUTPUT_DIRECTORY/guest-stderr.log"
  if [[ "$INSTRUMENT_VFORK_PARENT_WINESERVER_BRIDGE" -eq 1 ]]; then
    VFORK_WINESERVER_RECEIPT="$VFORK_WINESERVER_BRIDGE_DIRECTORY/wineserver-process-probe.json"
    VFORK_WINESERVER_HOST_STDERR="$VFORK_WINESERVER_BRIDGE_DIRECTORY/wineserver-host-stderr.log"
    VFORK_WINESERVER_GUEST_STDERR="$VFORK_WINESERVER_BRIDGE_DIRECTORY/wineserver-guest-stderr.log"
    for private_artifact in \
      "$VFORK_WINESERVER_RECEIPT" \
      "$VFORK_WINESERVER_HOST_STDERR" \
      "$VFORK_WINESERVER_GUEST_STDERR"; do
      [[ -f "$private_artifact" && ! -L "$private_artifact" \
        && "$(stat -f '%Su' "$private_artifact")" == "$(id -un)" \
        && "$(stat -f '%Lp' "$private_artifact")" == "600" \
        && "$(stat -f '%z' "$private_artifact")" -le 67108864 ]] || {
        echo "ERROR: falta un artefacto privado y acotado del wineserver puente." >&2
        exit 70
      }
    done
    install -m 0600 "$VFORK_WINESERVER_RECEIPT" \
      "$OUTPUT_DIRECTORY/wineserver-process-probe.json"
    install -m 0600 "$VFORK_WINESERVER_HOST_STDERR" \
      "$OUTPUT_DIRECTORY/wineserver-host-stderr.log"
    install -m 0600 "$VFORK_WINESERVER_GUEST_STDERR" \
      "$OUTPUT_DIRECTORY/wineserver-guest-stderr.log"
  fi
  if [[ "$DISASSEMBLE_HOST_BLOCKS" -eq 1 ]]; then
    install -m 0600 "$PRIVATE_HOST_DISASSEMBLY" "$OUTPUT_DIRECTORY/host-disassembly.log"
  fi
  ASSERTIONS=(
    "\"main_elf\":\"$GUEST_PROGRAM\""
    "\"guest_arg_count\":$GUEST_ARGUMENT_COUNT"
    "\"guest_component_kind\":\"$GUEST_COMPONENT_KIND\""
    '"guest_entry_executed":true'
  )
  if [[ "$INSTRUMENT_LOW_MEMORY_BIAS" -eq 1 ]]; then
    ASSERTIONS+=(
      '"low_memory_bias_mode_enabled":true'
      '"low_memory_shadow_reserved":true'
      '"low_memory_shadow_guest_limit":4294967296'
      '"low_memory_shadow_host_page_size":16384'
      '"low_memory_sparse_redirect_enabled":true'
      '"low_memory_sparse_redirect_guest_page":2147352576'
      '"low_memory_host_low_mapping_created":false'
      '"low_memory_exec_host_enforced":false'
      '"low_page_alias_mode_enabled":false'
    )
  else
    ASSERTIONS+=(
      '"low_memory_bias_mode_enabled":false'
      '"mprotect_host_enforced":false'
    )
  fi
  if [[ "$INSTRUMENT_HIGH_MEMORY_REGION" -eq 1 ]]; then
    ASSERTIONS+=(
      '"high_memory_region_mode_enabled":true'
      '"high_memory_region_reserved":true'
      '"high_memory_region_guest_base":4294967296'
      '"high_memory_region_size":16777216'
      '"high_memory_region_host_page_size":16384'
    )
  else
    ASSERTIONS+=(
      '"high_memory_region_mode_enabled":false'
      '"high_memory_region_reserved":false'
    )
  fi
  if [[ "$INSTRUMENT_VFORK_CHILD" -eq 1 ]]; then
    ASSERTIONS+=(
      '"virtual_vfork_child_instrumentation_enabled":true'
      '"virtual_vfork_parent_instrumentation_enabled":false'
      '"virtual_vfork_parent_process_bridge_enabled":false'
      '"virtual_vfork_parent_wineserver_bridge_enabled":false'
      '"virtual_vfork_child_entered":true'
      '"virtual_vfork_child_stack_applied":true'
      '"virtual_vfork_parent_resumed":false'
      '"rt_sigprocmask_query_success_count":1'
      '"rt_sigaction_syscall_seen":true'
      '"rt_sigaction_set_success_count":2'
      '"unsupported_execve_envp_readable":true'
      '"unsupported_execve_envp_terminated":true'
      '"unsupported_execve_env_has_lc_all_c":true'
      '"unsupported_execve_env_has_private_home":true'
      '"unsupported_execve_env_has_wine_loader_noexec":false'
    )
    if [[ "$WINE_ARCH_WOW64" -eq 1 ]]; then
      ASSERTIONS+=(
        '"unsupported_execve_env_count":3'
        '"unsupported_execve_env_unknown_count":0'
        '"unsupported_execve_env_has_wine_arch_wow64":true'
      )
    else
      ASSERTIONS+=(
        '"unsupported_execve_env_count":2'
        '"unsupported_execve_env_unknown_count":0'
        '"unsupported_execve_env_has_wine_arch_wow64":false'
      )
    fi
  elif [[ "$INSTRUMENT_VFORK_PARENT" -eq 1 ]]; then
    ASSERTIONS+=(
      '"virtual_vfork_child_instrumentation_enabled":false'
      '"virtual_vfork_parent_instrumentation_enabled":true'
      '"virtual_vfork_parent_process_bridge_enabled":false'
      '"virtual_vfork_parent_wineserver_bridge_enabled":false'
      '"virtual_vfork_child_entered":false'
      '"virtual_vfork_parent_entered":true'
      '"virtual_vfork_parent_entry_count":1'
      '"virtual_vfork_parent_diagnostic_pid":4242'
      '"virtual_vfork_parent_resumed":true'
      '"virtual_vfork_parent_stack_unmap_accepted":true'
      '"virtual_vfork_parent_stack_unmap_accept_count":1'
      '"virtual_vfork_parent_stack_unmap_length":36864'
      '"first_unsupported_syscall":61'
      '"unsupported_wait4_boundary_seen":true'
      '"unsupported_wait4_process_id":4242'
      '"unsupported_wait4_options":0'
      '"unsupported_wait4_status_class":"guest-memory"'
      '"unsupported_wait4_resource_usage_class":"zero"'
    )
  elif [[ "$INSTRUMENT_VFORK_PARENT_WINESERVER_BRIDGE" -eq 1 ]]; then
    ASSERTIONS+=(
      '"virtual_vfork_child_instrumentation_enabled":false'
      '"virtual_vfork_parent_instrumentation_enabled":false'
      '"virtual_vfork_parent_process_bridge_enabled":false'
      '"virtual_vfork_parent_wineserver_bridge_enabled":true'
      '"virtual_vfork_child_entered":false'
      '"virtual_vfork_parent_entered":true'
      '"virtual_vfork_parent_entry_count":1'
      '"virtual_vfork_parent_diagnostic_pid":0'
      '"virtual_vfork_parent_resumed":true'
      '"virtual_vfork_parent_stack_unmap_accepted":true'
      '"virtual_vfork_parent_stack_unmap_accept_count":1'
      '"virtual_vfork_parent_stack_unmap_length":36864'
      '"virtual_vfork_bridge_spawn_attempt_count":1'
      '"virtual_vfork_bridge_spawn_result":0'
      '"virtual_vfork_bridge_process_id_positive":true'
      '"virtual_vfork_bridge_signal_mask_explicit":true'
      '"virtual_vfork_bridge_signal_defaults_explicit":true'
      '"virtual_vfork_bridge_wait_seen":true'
      '"virtual_vfork_bridge_wait_pid_matched":true'
      '"virtual_vfork_bridge_wait_status_writable":true'
      '"virtual_vfork_bridge_wait_resource_usage_zero":true'
      '"virtual_vfork_bridge_wait_success_count":1'
      '"virtual_vfork_bridge_host_wait_status":0'
      '"virtual_vfork_bridge_child_exited":true'
      '"virtual_vfork_bridge_child_exit_code":0'
      '"virtual_vfork_bridge_child_reaped":true'
      '"virtual_vfork_bridge_last_host_error":0'
      '"virtual_vfork_wineserver_spawn_attempt_count":1'
      '"virtual_vfork_wineserver_spawn_result":0'
      '"virtual_vfork_wineserver_process_id_positive":true'
      '"virtual_vfork_wineserver_signal_mask_explicit":true'
      '"virtual_vfork_wineserver_signal_defaults_explicit":true'
      '"virtual_vfork_wineserver_socket_ready":true'
      '"virtual_vfork_wineserver_exited_before_ready":false'
      '"virtual_vfork_wineserver_process_reaped":true'
      '"virtual_vfork_wineserver_host_wait_status":0'
      '"virtual_vfork_wineserver_child_exited":true'
      '"virtual_vfork_wineserver_child_exit_code":0'
      '"virtual_vfork_wineserver_child_signaled":false'
      '"virtual_vfork_wineserver_child_term_signal":-1'
      '"virtual_vfork_wineserver_cleanup_signal_sent":false'
      '"virtual_vfork_wineserver_force_kill_signal_sent":false'
      '"virtual_vfork_wineserver_finalized":true'
      '"virtual_vfork_wineserver_last_host_error":0'
    )
  elif [[ "$INSTRUMENT_VFORK_PARENT_PROCESS_BRIDGE" -eq 1 ]]; then
    ASSERTIONS+=(
      '"virtual_vfork_child_instrumentation_enabled":false'
      '"virtual_vfork_parent_instrumentation_enabled":false'
      '"virtual_vfork_parent_process_bridge_enabled":true'
      '"virtual_vfork_parent_wineserver_bridge_enabled":false'
      '"virtual_vfork_child_entered":false'
      '"virtual_vfork_parent_entered":true'
      '"virtual_vfork_parent_entry_count":1'
      '"virtual_vfork_parent_diagnostic_pid":0'
      '"virtual_vfork_parent_resumed":true'
      '"virtual_vfork_parent_stack_unmap_accepted":true'
      '"virtual_vfork_parent_stack_unmap_accept_count":1'
      '"virtual_vfork_parent_stack_unmap_length":36864'
      '"virtual_vfork_bridge_spawn_attempt_count":1'
      '"virtual_vfork_bridge_spawn_result":0'
      '"virtual_vfork_bridge_process_id_positive":true'
      '"virtual_vfork_bridge_signal_mask_explicit":true'
      '"virtual_vfork_bridge_signal_defaults_explicit":true'
      '"virtual_vfork_bridge_wait_seen":true'
      '"virtual_vfork_bridge_wait_pid_matched":true'
      '"virtual_vfork_bridge_wait_status_writable":true'
      '"virtual_vfork_bridge_wait_resource_usage_zero":true'
      '"virtual_vfork_bridge_wait_success_count":1'
      '"virtual_vfork_bridge_host_wait_status":0'
      '"virtual_vfork_bridge_child_exited":true'
      '"virtual_vfork_bridge_child_exit_code":0'
      '"virtual_vfork_bridge_child_reaped":true'
      '"virtual_vfork_bridge_last_host_error":0'
    )
  else
    ASSERTIONS+=(
      '"virtual_vfork_child_instrumentation_enabled":false'
      '"virtual_vfork_parent_instrumentation_enabled":false'
      '"virtual_vfork_parent_process_bridge_enabled":false'
      '"virtual_vfork_parent_wineserver_bridge_enabled":false'
    )
  fi
  if [[ "$GUEST_COMPONENT_KIND" == "official-proton-wine64-preloader" ]]; then
    ASSERTIONS+=(
      '"mode":"real-static-pie-first-syscall"'
      '"pt_interp_resolved":false'
      '"interpreter_elf_loaded":false'
      '"dynamic_interpreter":"none-static-pie"'
      '"glibc_interpreter_mapped":false'
      '"glibc_entry_executed":false'
    )
    if [[ "$INITIAL_WINE_COMMAND_LINE" -eq 1 ]]; then
      ASSERTIONS+=(
        '"wine_loader_noexec_environment":false'
        '"initial_wine_command_line_enabled":true'
      )
    else
      ASSERTIONS+=(
        '"wine_loader_noexec_environment":true'
        '"initial_wine_command_line_enabled":false'
      )
    fi
  else
    ASSERTIONS+=(
      '"mode":"real-glibc-first-syscall"'
      '"pt_interp_resolved":true'
      '"interpreter_elf_loaded":true'
      '"dynamic_interpreter":"private-rootfs-glibc-ld-linux-x86-64"'
      '"wine_loader_noexec_environment":false'
      '"initial_wine_command_line_enabled":false'
      '"glibc_interpreter_mapped":true'
      '"glibc_entry_executed":true'
    )
  fi
  if [[ "$WINE_ARCH_WOW64" -eq 1 ]]; then
    ASSERTIONS+=('"wine_arch_wow64_environment":true')
    if [[ "$INITIAL_WINE_COMMAND_LINE" -eq 1 ]]; then
      ASSERTIONS+=('"post_wine_reexec_wow64_entry":false')
    else
      ASSERTIONS+=('"post_wine_reexec_wow64_entry":true')
    fi
  else
    ASSERTIONS+=(
      '"wine_arch_wow64_environment":false'
      '"post_wine_reexec_wow64_entry":false'
    )
  fi
  if [[ -n "$CX_ALT_LOADER_SOCKET" ]]; then
    ASSERTIONS+=(
      '"cx_alt_loader_socket_environment":true'
      '"cx_alt_loader_host_socket_mapped":true'
    )
  else
    ASSERTIONS+=(
      '"cx_alt_loader_socket_environment":false'
      '"cx_alt_loader_host_socket_mapped":false'
    )
  fi
  if [[ "$GUEST_BIND_NOW" -eq 1 ]]; then
    ASSERTIONS+=('"bind_now_environment":true')
  else
    ASSERTIONS+=('"bind_now_environment":false')
  fi
  if [[ "$INSTRUMENT_LOW_PAGE_ALIAS" -eq 1 ]]; then
    ASSERTIONS+=(
      '"low_page_alias_mode_enabled":true'
      '"low_page_alias_request_seen":true'
      '"low_page_alias_accepted":true'
      '"low_page_alias_accept_count":1'
      '"low_page_alias_backing_zeroed":true'
      '"guest_signal_boundary_seen":true'
      '"guest_signal_boundary_address_register_matches_fault":true'
    )
  else
    ASSERTIONS+=('"low_page_alias_mode_enabled":false')
  fi
  if [[ -d "$REAL_ROOTFS/home/regression" && ! -L "$REAL_ROOTFS/home/regression" ]]; then
    ASSERTIONS+=('"private_guest_home_directory_present":true')
  else
    ASSERTIONS+=('"private_guest_home_directory_present":false')
  fi
  if [[ "$REAL_ROOTFS_WINE_PREFIX_PRESENT_BEFORE" -eq 1 ]]; then
    ASSERTIONS+=('"private_wine_prefix_directory_present":true')
    if [[ -z "$INHERITED_WINESERVER_SOCKET_FD" ]]; then
      ASSERTIONS+=('"chdir_syscall_seen":true')
    fi
  else
    ASSERTIONS+=('"private_wine_prefix_directory_present":false')
  fi
  if [[ "$GUEST_PROGRAM" == "/usr/bin/true" ]]; then
    ASSERTIONS+=(
      '"brk_syscall_seen":true'
      '"access_syscall_seen":true'
      '"openat_syscall_seen":true'
      '"read_syscall_seen":true'
      '"pread64_syscall_seen":true'
      '"fstat_syscall_seen":true'
      '"mmap_syscall_seen":true'
      '"close_syscall_seen":true'
      '"arch_prctl_syscall_seen":true'
      '"set_tid_address_syscall_seen":true'
      '"set_robust_list_syscall_seen":true'
      '"rseq_syscall_seen":true'
      '"mprotect_syscall_seen":true'
      '"prlimit64_syscall_seen":true'
      '"getrandom_syscall_seen":true'
    )
  fi
else
  "$PROBE" | tee "$RECEIPT"
  ASSERTIONS=(
    '"argv_seen_by_guest":true'
    '"write_syscall_seen":true'
    '"captured_output_match":true'
    '"exit_syscall_seen":true'
    '"exit_code":42'
    '"glibc_loaded":false'
    '"unaligned_backpatch_count":0'
  )
fi
ASSERTIONS+=(
  '"parser":"FEX-ELFParser"'
  '"main_elf_loaded":true'
  '"bss_zeroed":true'
  '"initial_stack_present":true'
  '"auxv_present":true'
  '"proton_executed":false'
  '"steam_executed":false'
  '"eac_executed":false'
)
for assertion in "${ASSERTIONS[@]}"; do
  grep -Fq "$assertion" "$RECEIPT" || {
    echo "ERROR: falta la aserción de proceso: $assertion" >&2
    exit 70
  }
done
if [[ "$INSTRUMENT_VFORK_PARENT_PROCESS_BRIDGE" -eq 1 \
    || "$INSTRUMENT_VFORK_PARENT_WINESERVER_BRIDGE" -eq 1 ]] \
  && grep -Eq '"first_unsupported_syscall":61([,}])' "$RECEIPT"; then
  echo "ERROR: el puente nativo no consumió el wait4 exacto del padre Wine." >&2
  exit 70
fi
if [[ "$INSTRUMENT_VFORK_PARENT_WINESERVER_BRIDGE" -eq 1 ]]; then
  for assertion in \
    '"guest_component_kind":"official-proton-wineserver"' \
    '"guest_arg_count":1' \
    '"main_completed":true' \
    '"exit_code":0' \
    '"proton_executed":false' \
    '"steam_executed":false' \
    '"eac_executed":false'; do
    grep -Fq "$assertion" "$VFORK_WINESERVER_RECEIPT" || {
      echo "ERROR: el wineserver puente no conservó su contrato: $assertion" >&2
      exit 70
    }
  done
  for assertion in \
    '"virtual_vfork_wineserver_guest_socket_path":"/tmp/.wine-[0-9]+/server-[0-9a-f]+-[0-9a-f]+/socket"' \
    '"virtual_vfork_wineserver_socket_readiness_poll_count":[1-9][0-9]*' \
    '"connect_success_count":[1-9][0-9]*'; do
    grep -Eq "$assertion" "$RECEIPT" || {
      echo "ERROR: el cliente Wine no consumió el socket exacto del puente: $assertion" >&2
      exit 70
    }
  done
  for assertion in \
    '"bind_success_count":[1-9][0-9]*' \
    '"listen_success_count":[1-9][0-9]*' \
    '"accept_success_count":[1-9][0-9]*'; do
    grep -Eq "$assertion" "$VFORK_WINESERVER_RECEIPT" || {
      echo "ERROR: el wineserver oficial no completó su transporte: $assertion" >&2
      exit 70
    }
  done
fi
if [[ "$REAL_ROOTFS_WINE_PREFIX_PRESENT_BEFORE" -eq 1 \
    && -z "$INHERITED_WINESERVER_SOCKET_FD" ]] \
  && ! grep -Eq '"chdir_success_count":[1-9][0-9]*' "$RECEIPT"; then
  echo "ERROR: el componente Wine no completó ningún chdir en el prefijo privado." >&2
  exit 70
fi
if [[ "$INSTRUMENT_LOW_PAGE_ALIAS" -eq 1 ]] \
  && ! grep -Eq '"guest_signal_boundary_low_address":[1-9][0-9]*' "$RECEIPT"; then
  echo "ERROR: la frontera del alias no conservó una dirección huésped baja." >&2
  exit 70
fi
if [[ -n "$REAL_ROOTFS" ]]; then
  grep -Eq '"raw_guest_signal_boundary_seen":(true|false)' "$RECEIPT" || {
    echo "ERROR: falta la señal bruta saneada de la frontera huésped." >&2
    exit 70
  }
  grep -Eq '"controlled_stop_signal_seen":(true|false)' "$RECEIPT" || {
    echo "ERROR: falta la clasificación de la parada controlada." >&2
    exit 70
  }
fi
if [[ -n "$REAL_ROOTFS" ]] \
  && ! grep -Eq '"first_unsupported_syscall":[0-9]+' "$RECEIPT" \
  && ! grep -Fq '"main_completed":true' "$RECEIPT" \
  && ! grep -Fq '"exit_syscall_seen":true' "$RECEIPT" \
  && ! grep -Fq '"guest_signal_boundary_seen":true' "$RECEIPT" \
  && ! { [[ "$GUEST_COMPONENT_KIND" == "official-proton-wine64" ]] \
    && { grep -Fq '"proton_wine_ntdll_load_failure":true' "$RECEIPT" \
      || grep -Fq '"proton_wine_glibc_version_failure":true' "$RECEIPT"; }; }; then
  echo "ERROR: el ejecutable huésped no alcanzó una frontera observable ni completó su ejecución." >&2
  exit 70
fi
first_unsupported_is() {
  grep -Eq "\"first_unsupported_syscall\":${1}([,}])" "$RECEIPT"
}
if [[ -n "$REAL_ROOTFS" && "$GUEST_PROGRAM" == "/usr/bin/true" ]] \
  && ! grep -Eq '"unaligned_backpatch_count":[1-9][0-9]*' "$RECEIPT"; then
  echo "ERROR: ld-linux no ejercitó el puente SIGBUS/TSO de FEX." >&2
  exit 70
fi
if [[ -n "$REAL_ROOTFS" && "$GUEST_PROGRAM" == "/usr/bin/true" ]] \
  && ! grep -Eq '"openat_success_count":[1-9][0-9]*' "$RECEIPT"; then
  echo "ERROR: glibc no abrió ninguna dependencia dentro del RootFS privado." >&2
  exit 70
fi
if [[ -n "$REAL_ROOTFS" ]] && first_unsupported_is 12; then
  echo "ERROR: brk sigue sin estar implementada en la frontera glibc." >&2
  exit 70
fi
if [[ -n "$REAL_ROOTFS" ]] && first_unsupported_is 102; then
  echo "ERROR: getuid sigue sin estar implementada en la frontera Wine64." >&2
  exit 70
fi
if [[ -n "$REAL_ROOTFS" ]] && first_unsupported_is 41; then
  echo "ERROR: socket sigue sin estar implementada en la frontera Wine64." >&2
  exit 70
fi
if [[ -n "$REAL_ROOTFS" ]] && first_unsupported_is 42; then
  echo "ERROR: connect sigue sin estar implementada en la frontera Wine64." >&2
  exit 70
fi
if [[ -n "$REAL_ROOTFS" ]] && first_unsupported_is 72; then
  for assertion in \
    '"unsupported_fcntl_boundary_seen":true' \
    '"unsupported_fcntl_descriptor_closed":false'; do
    grep -Fq "$assertion" "$RECEIPT" || {
      echo "ERROR: fcntl se alcanzó sin clasificar su descriptor: $assertion" >&2
      exit 70
    }
  done
  grep -Eq '"unsupported_fcntl_argument_class":"(zero|guest-memory|scalar-or-outside)"' "$RECEIPT" || {
    echo "ERROR: fcntl no clasificó su tercer argumento." >&2
    exit 70
  }
fi
if [[ -n "$REAL_ROOTFS" ]] && first_unsupported_is 59; then
  grep -Fq '"unsupported_execve_boundary_seen":true' "$RECEIPT" || {
    echo "ERROR: execve se alcanzó sin clasificar su frontera." >&2
    exit 70
  }
  grep -Fq '"unsupported_execve_argv_readable":true' "$RECEIPT" || {
    echo "ERROR: execve no expuso un argv huésped legible." >&2
    exit 70
  }
  grep -Fq '"unsupported_execve_argv_terminated":true' "$RECEIPT" || {
    echo "ERROR: execve no expuso un argv huésped terminado." >&2
    exit 70
  }
  grep -Eq '"unsupported_execve_arg_fingerprints":\[[0-9]+' "$RECEIPT" || {
    echo "ERROR: execve no conservó las huellas saneadas de argv." >&2
    exit 70
  }
  grep -Eq '"unsupported_execve_arg_kinds":\["[a-z-]+"' "$RECEIPT" || {
    echo "ERROR: execve no clasificó la forma de argv." >&2
    exit 70
  }
fi
if [[ -n "$REAL_ROOTFS" ]] && first_unsupported_is 56; then
  for assertion in \
    '"first_unsupported_syscall_name":"clone"' \
    '"unsupported_clone_boundary_seen":true'; do
    grep -Fq "$assertion" "$RECEIPT" || {
      echo "ERROR: clone se alcanzó sin clasificar su frontera: $assertion" >&2
      exit 70
    }
  done
  grep -Eq '"unsupported_clone_child_stack_class":"(guest-memory|guest-memory-end|low-shadow|low-shadow-end|zero|scalar-or-outside)"' "$RECEIPT" || {
    echo "ERROR: clone no clasificó la pila hija." >&2
    exit 70
  }
fi
if [[ -n "$REAL_ROOTFS" ]] && first_unsupported_is 2; then
  echo "ERROR: open sigue sin estar implementada en la frontera del preloader." >&2
  exit 70
fi
if [[ -n "$REAL_ROOTFS" ]] && first_unsupported_is 157; then
  grep -Fq '"unsupported_prctl_boundary_seen":true' "$RECEIPT" || {
    echo "ERROR: prctl se alcanzó sin clasificar su frontera." >&2
    exit 70
  }
  grep -Eq '"unsupported_prctl_argument2_class":"(zero|guest-memory|scalar)"' "$RECEIPT" || {
    echo "ERROR: prctl no clasificó su segundo argumento." >&2
    exit 70
  }
fi
if [[ -n "$REAL_ROOTFS" ]] && first_unsupported_is 323; then
  grep -Fq '"unsupported_userfaultfd_boundary_seen":true' "$RECEIPT" || {
    echo "ERROR: userfaultfd se alcanzó sin clasificar sus flags." >&2
    exit 70
  }
fi
if [[ -n "$REAL_ROOTFS" ]] && first_unsupported_is 435; then
  for assertion in \
    '"first_unsupported_syscall_name":"clone3"' \
    '"unsupported_clone3_boundary_seen":true' \
    '"unsupported_clone3_structure_readable":true' \
    '"unsupported_clone3_argument_class":"guest-memory"'; do
    grep -Fq "$assertion" "$RECEIPT" || {
      echo "ERROR: clone3 se alcanzó sin una estructura huésped legible: $assertion" >&2
      exit 70
    }
  done
  grep -Eq '"unsupported_clone3_size":[1-9][0-9]*' "$RECEIPT" || {
    echo "ERROR: clone3 no conservó el tamaño de clone_args." >&2
    exit 70
  }
fi
if [[ -n "$REAL_ROOTFS" ]] \
  && grep -Eq '"clone3_call_count":[1-9][0-9]*' "$RECEIPT"; then
  for assertion in \
    '"clone3_last_structure_readable":true' \
    '"clone3_last_size":88'; do
    grep -Fq "$assertion" "$RECEIPT" || {
      echo "ERROR: clone3 ejecutó sin conservar su forma observada: $assertion" >&2
      exit 70
    }
  done
fi
if [[ -n "$REAL_ROOTFS" ]] && first_unsupported_is 14; then
  grep -Fq '"unsupported_rt_sigprocmask_boundary_seen":true' "$RECEIPT" || {
    echo "ERROR: rt_sigprocmask se alcanzó sin clasificar sus argumentos." >&2
    exit 70
  }
  grep -Eq '"unsupported_rt_sigprocmask_(set|oldset)_class":"(zero|guest-memory|scalar-or-outside)"' "$RECEIPT" || {
    echo "ERROR: rt_sigprocmask no clasificó sus punteros de máscara." >&2
    exit 70
  }
fi
if [[ -n "$REAL_ROOTFS" ]] && first_unsupported_is 13; then
  for assertion in \
    '"first_unsupported_syscall_name":"rt_sigaction"' \
    '"unsupported_rt_sigaction_boundary_seen":true'; do
    grep -Fq "$assertion" "$RECEIPT" || {
      echo "ERROR: rt_sigaction se alcanzó sin clasificar su frontera: $assertion" >&2
      exit 70
    }
  done
  grep -Eq '"unsupported_rt_sigaction_(action|oldaction)_class":"(zero|signal-ignore|guest-memory|low-shadow|scalar-or-outside)"' "$RECEIPT" || {
    echo "ERROR: rt_sigaction no clasificó sus punteros de acción." >&2
    exit 70
  }
fi
if [[ -n "$REAL_ROOTFS" ]] && first_unsupported_is 21; then
  echo "ERROR: access sigue sin estar implementada en la frontera glibc." >&2
  exit 70
fi
if [[ -n "$REAL_ROOTFS" ]] && first_unsupported_is 20; then
  echo "ERROR: writev sigue sin estar implementada en la frontera glibc." >&2
  exit 70
fi
if [[ -n "$REAL_ROOTFS" ]] && first_unsupported_is 257; then
  echo "ERROR: openat sigue sin estar implementada en la frontera glibc." >&2
  exit 70
fi
if [[ -n "$REAL_ROOTFS" ]] && first_unsupported_is 262; then
  echo "ERROR: newfstatat sigue sin estar implementada en la frontera glibc." >&2
  exit 70
fi
if [[ -n "$REAL_ROOTFS" ]] && first_unsupported_is 0; then
  echo "ERROR: read sigue sin estar implementada en la frontera glibc." >&2
  exit 70
fi
if [[ -n "$REAL_ROOTFS" ]] && first_unsupported_is 17; then
  echo "ERROR: pread64 sigue sin estar implementada en la frontera glibc." >&2
  exit 70
fi
if [[ -n "$REAL_ROOTFS" ]] && first_unsupported_is 5; then
  echo "ERROR: fstat sigue sin estar implementada en la frontera glibc." >&2
  exit 70
fi
if [[ -n "$REAL_ROOTFS" ]] && first_unsupported_is 4; then
  echo "ERROR: stat sigue sin estar implementada en la frontera glibc." >&2
  exit 70
fi
if [[ -n "$REAL_ROOTFS" ]] && first_unsupported_is 9; then
  echo "ERROR: mmap sigue sin estar implementada en la frontera glibc." >&2
  exit 70
fi
if [[ -n "$REAL_ROOTFS" ]] && first_unsupported_is 3; then
  echo "ERROR: close sigue sin estar implementada en la frontera glibc." >&2
  exit 70
fi
if [[ -n "$REAL_ROOTFS" ]] && first_unsupported_is 158; then
  echo "ERROR: arch_prctl sigue sin estar implementada en la frontera glibc." >&2
  exit 70
fi
if [[ -n "$REAL_ROOTFS" ]] && first_unsupported_is 218; then
  echo "ERROR: set_tid_address sigue sin estar implementada en la frontera glibc." >&2
  exit 70
fi
if [[ -n "$REAL_ROOTFS" ]] && first_unsupported_is 273; then
  echo "ERROR: set_robust_list sigue sin estar implementada en la frontera glibc." >&2
  exit 70
fi
if [[ -n "$REAL_ROOTFS" ]] && first_unsupported_is 334; then
  echo "ERROR: rseq sigue sin estar traducida en la frontera glibc." >&2
  exit 70
fi
if [[ -n "$REAL_ROOTFS" ]] && first_unsupported_is 10; then
  echo "ERROR: mprotect sigue sin estar traducida en la frontera glibc." >&2
  exit 70
fi
if [[ -n "$REAL_ROOTFS" ]] && first_unsupported_is 302; then
  echo "ERROR: prlimit64 sigue sin estar traducida en la frontera glibc." >&2
  exit 70
fi
if [[ -n "$REAL_ROOTFS" ]] && first_unsupported_is 228; then
  echo "ERROR: clock_gettime sigue sin estar traducida en la frontera glibc." >&2
  exit 70
fi
if [[ -n "$REAL_ROOTFS" ]] && first_unsupported_is 230; then
  echo "ERROR: clock_nanosleep sigue sin estar traducida en la frontera glibc." >&2
  exit 70
fi
if [[ -n "$REAL_ROOTFS" ]] && first_unsupported_is 318; then
  echo "ERROR: getrandom sigue sin estar traducida en la frontera glibc." >&2
  exit 70
fi
if [[ -n "$REAL_ROOTFS" ]] && first_unsupported_is 63; then
  echo "ERROR: uname sigue sin estar traducida en la frontera glibc." >&2
  exit 70
fi
if [[ -n "$REAL_ROOTFS" ]] && first_unsupported_is 79; then
  echo "ERROR: getcwd sigue sin estar traducida en la frontera glibc." >&2
  exit 70
fi
if [[ -n "$REAL_ROOTFS" ]] && first_unsupported_is 80; then
  for assertion in \
    '"unsupported_chdir_boundary_seen":true' \
    '"unsupported_chdir_path_class":"absolute"' \
    '"unsupported_chdir_target_exists":true' \
    '"unsupported_chdir_target_directory":true'; do
    grep -Fq "$assertion" "$RECEIPT" || {
      echo "ERROR: chdir se alcanzó sin una ruta huésped absoluta y confinada válida: $assertion" >&2
      exit 70
    }
  done
fi
if [[ -n "$REAL_ROOTFS" ]] && first_unsupported_is 83; then
  for assertion in \
    '"unsupported_mkdir_boundary_seen":true' \
    '"unsupported_mkdir_path_readable":true' \
    '"unsupported_mkdir_parent_confined":true' \
    '"unsupported_mkdir_parent_exists":true' \
    '"unsupported_mkdir_parent_directory":true' \
    '"unsupported_mkdir_target_exists":false'; do
    grep -Fq "$assertion" "$RECEIPT" || {
      echo "ERROR: mkdir se alcanzó sin una ruta huésped confinada y creable: $assertion" >&2
      exit 70
    }
  done
fi
if [[ -n "$REAL_ROOTFS" ]] && first_unsupported_is 88; then
  for assertion in \
    '"unsupported_symlink_boundary_seen":true' \
    '"unsupported_symlink_target_readable":true' \
    '"unsupported_symlink_link_readable":true' \
    '"unsupported_symlink_link_parent_confined":true' \
    '"unsupported_symlink_link_parent_exists":true' \
    '"unsupported_symlink_link_parent_directory":true' \
    '"unsupported_symlink_link_exists":false'; do
    grep -Fq "$assertion" "$RECEIPT" || {
      echo "ERROR: symlink se alcanzó sin un enlace huésped confinado: $assertion" >&2
      exit 70
    }
  done
fi
if [[ -n "$REAL_ROOTFS" ]] && first_unsupported_is 89; then
  echo "ERROR: readlink sigue sin estar traducida en la frontera glibc." >&2
  exit 70
fi
if [[ -n "$REAL_ROOTFS" && "$GUEST_PROGRAM" == "/usr/bin/true" ]] \
  && ! grep -Eq '"getrandom_success_count":[1-9][0-9]*' "$RECEIPT"; then
  echo "ERROR: glibc no obtuvo entropía mediante getrandom." >&2
  exit 70
fi

install -d -m 0700 "$OUTPUT_DIRECTORY"
install -m 0600 "$RECEIPT" "$OUTPUT_DIRECTORY/process-probe.json"
if [[ -n "$REAL_ROOTFS" ]]; then
  install -m 0600 "$PRIVATE_GUEST_STDERR" "$OUTPUT_DIRECTORY/guest-stderr.log"
fi
{
  printf 'schema=%s\n' '2'
  printf 'signature=%s\n' 'valid'
  printf 'hardened_runtime=%s\n' 'yes'
  printf 'allow_jit=%s\n' 'true'
  printf 'team_identifier=%s\n' 'present-and-matched'
  if [[ -n "$REAL_ROOTFS" ]]; then
    printf 'guest_stderr=%s\n' 'private-0600'
    if [[ "$GUEST_COMPONENT_KIND" == "official-proton-wine64-preloader" ]]; then
      printf 'process_abi_scope=%s\n' 'real-static-pie-first-syscall-boundary'
      printf 'dynamic_interpreter=%s\n' 'none-static-pie'
      printf 'glibc=%s\n' 'not-entered-by-main'
      if [[ "$INITIAL_WINE_COMMAND_LINE" -eq 1 ]]; then
        printf 'wine_loader_noexec=%s\n' 'disabled-for-initial-command-line'
        printf 'initial_wine_command_line=%s\n' 'enabled'
      else
        printf 'wine_loader_noexec=%s\n' 'enabled-for-loader-reentry'
        printf 'initial_wine_command_line=%s\n' 'disabled'
      fi
      if [[ "$WINE_ARCH_WOW64" -eq 1 ]]; then
        printf 'wine_arch_environment=%s\n' 'wow64-64-bit-host-process'
        if [[ "$INITIAL_WINE_COMMAND_LINE" -eq 1 ]]; then
          printf 'wine_process_entry=%s\n' 'initial-wrapper-before-reexec'
        else
          printf 'wine_process_entry=%s\n' 'measured-post-reexec-state'
        fi
      else
        printf 'wine_arch_environment=%s\n' 'unset'
        printf 'wine_process_entry=%s\n' 'legacy-probe-entry'
      fi
    else
      printf 'process_abi_scope=%s\n' 'real-glibc-first-syscall-boundary'
      printf 'dynamic_interpreter=%s\n' 'private-rootfs-glibc-ld-linux-x86-64'
      printf 'glibc=%s\n' 'entry-executed'
    fi
    printf 'guest_program=%s\n' "$GUEST_PROGRAM"
    printf 'guest_arg_count=%s\n' "$GUEST_ARGUMENT_COUNT"
    printf 'guest_component_kind=%s\n' "$GUEST_COMPONENT_KIND"
    if [[ "$INHERITED_WINESERVER_SOCKET_FD" -ge 0 ]]; then
      printf 'inherited_wineserver_socket=%s\n' 'present-open-host-descriptor'
    else
      printf 'inherited_wineserver_socket=%s\n' 'absent'
    fi
    if [[ "$GUEST_BIND_NOW" -eq 1 ]]; then
      printf 'bind_now_environment=%s\n' 'enabled-diagnostic-only'
    else
      printf 'bind_now_environment=%s\n' 'disabled'
    fi
    if [[ "$INSTRUMENT_LOW_PAGE_ALIAS" -eq 1 ]]; then
      printf 'low_page_alias_instrumentation=%s\n' 'enabled-exact-shared-user-data-only'
      printf 'low_page_host_mapping=%s\n' 'forbidden-not-created'
    else
      printf 'low_page_alias_instrumentation=%s\n' 'disabled'
    fi
    if [[ "$INSTRUMENT_LOW_MEMORY_BIAS" -eq 1 ]]; then
      printf 'low_memory_bias_instrumentation=%s\n' 'enabled-below-4g-disabled-by-default'
      printf 'low_memory_shadow=%s\n' 'high-4g-prot-none-reservation'
      printf 'low_memory_sparse_redirect=%s\n' 'shared-user-data-page-only'
      printf 'low_host_mapping=%s\n' 'forbidden-not-created'
      printf 'guest_page_granularity=%s\n' '4096'
      printf 'host_page_granularity=%s\n' '16384'
    else
      printf 'low_memory_bias_instrumentation=%s\n' 'disabled'
    fi
    if [[ "$INSTRUMENT_VFORK_CHILD" -eq 1 ]]; then
      printf 'vfork_child_instrumentation=%s\n' 'enabled-child-only-no-process-no-parent-resume'
      printf 'vfork_child_signal_mask_query=%s\n' 'exact-null-set-oldset-only'
    else
      printf 'vfork_child_instrumentation=%s\n' 'disabled'
    fi
    if [[ "$INSTRUMENT_VFORK_PARENT" -eq 1 ]]; then
      printf 'vfork_parent_instrumentation=%s\n' 'enabled-parent-only-diagnostic-pid-no-process'
      printf 'vfork_parent_stack_unmap=%s\n' 'exact-measured-map-stack-lifo-only'
    else
      printf 'vfork_parent_instrumentation=%s\n' 'disabled'
    fi
    if [[ "$INSTRUMENT_VFORK_PARENT_PROCESS_BRIDGE" -eq 1 ]]; then
      printf 'vfork_parent_process_bridge=%s\n' 'enabled-signed-native-child-real-pid-exact-wait4'
      printf 'vfork_parent_process_scope=%s\n' 'no-wineserver-no-proton-orchestrator'
    else
      printf 'vfork_parent_process_bridge=%s\n' 'disabled'
    fi
    if [[ "$INSTRUMENT_VFORK_PARENT_WINESERVER_BRIDGE" -eq 1 ]]; then
      printf 'vfork_parent_wineserver_bridge=%s\n' 'enabled-official-foreground-wineserver-exact-private-socket'
      printf 'vfork_parent_wineserver_scope=%s\n' 'wine-client-server-transport-no-proton-orchestrator'
    else
      printf 'vfork_parent_wineserver_bridge=%s\n' 'disabled'
    fi
  else
    printf 'process_abi_scope=%s\n' 'controlled-pt-interp-stack-bss-write-exit'
    printf 'dynamic_interpreter=%s\n' 'controlled-fixture-only'
    printf 'glibc=%s\n' 'not-loaded'
  fi
  if [[ "$GUEST_COMPONENT_KIND" == "official-proton-wine64" ]]; then
    printf 'proton_component=%s\n' 'wine64-invoked'
  elif [[ "$GUEST_COMPONENT_KIND" == "official-proton-wine64-preloader" ]]; then
    printf 'proton_component=%s\n' 'wine64-preloader-invoked'
  elif [[ "$GUEST_COMPONENT_KIND" == "official-proton-wineserver" ]]; then
    printf 'proton_component=%s\n' 'wineserver-invoked'
  else
    printf 'proton_component=%s\n' 'not-included'
  fi
  printf 'proton_orchestrator=%s\n' 'not-executed'
  printf 'steam=%s\n' 'not-executed'
  printf 'eac=%s\n' 'not-executed'
} > "$OUTPUT_DIRECTORY/scope.txt"
shasum -a 256 \
  "$PROBE_SOURCE" \
  "$COMPAT_DIRECTORY/elf.h" \
  "$COMPAT_DIRECTORY/linux/limits.h" \
  "$ELF_PARSER_HEADER" \
  "$ELF_CONTAINER_HEADER" \
  | sed "s#  $ROOT/#  repository/#; s#  $FEX_SOURCE/#  upstream-fex/#" \
  > "$OUTPUT_DIRECTORY/sources.sha256"
shasum -a 256 "$LIBRARY" \
  | awk '{ print $1 "  input-libFEXCore.dylib" }' \
  > "$OUTPUT_DIRECTORY/library.sha256"
if [[ -n "$REAL_ROOTFS" ]]; then
  ROOTFS_HASH_PATHS=(
    "$REAL_ROOTFS$GUEST_PROGRAM"
    "$REAL_ROOTFS/usr/lib64/ld-linux-x86-64.so.2"
    "$REAL_ROOTFS/usr/lib64/libc.so.6"
  )
  if [[ -f "$REAL_ROOTFS/opt/proton/files/lib/wine/x86_64-unix/ntdll.so" ]]; then
    ROOTFS_HASH_PATHS+=(
      "$REAL_ROOTFS/opt/proton/files/lib/wine/x86_64-unix/ntdll.so"
      "$REAL_ROOTFS/usr/lib64/libgcc_s.so.1"
    )
  fi
  if [[ -f "$REAL_ROOTFS/opt/proton/files/lib/wine/x86_64-unix/wine" ]]; then
    ROOTFS_HASH_PATHS+=(
      "$REAL_ROOTFS/opt/proton/files/lib/wine/x86_64-unix/wine"
    )
  fi
  WINDOWS_ROOT="$REAL_ROOTFS/opt/proton/files/lib/wine/x86_64-windows"
  if [[ -d "$WINDOWS_ROOT" && ! -L "$WINDOWS_ROOT" ]]; then
    while IFS= read -r -d '' windows_file; do
      ROOTFS_HASH_PATHS+=("$windows_file")
    done < <(find "$WINDOWS_ROOT" -maxdepth 1 -type f -print0 | LC_ALL=C sort -z)
  fi
  if [[ "$GUEST_PROGRAM" == "/usr/lib64/ld-linux-x86-64.so.2" \
    || "$GUEST_PROGRAM" == "/usr/lib64/libc.so.6" ]]; then
    ROOTFS_HASH_PATHS=(
      "$REAL_ROOTFS/usr/lib64/ld-linux-x86-64.so.2"
      "$REAL_ROOTFS/usr/lib64/libc.so.6"
    )
  fi
  shasum -a 256 "${ROOTFS_HASH_PATHS[@]}" \
    | sed "s#  $REAL_ROOTFS/#  rootfs/#" \
    > "$OUTPUT_DIRECTORY/rootfs.sha256"
fi
(
  cd "$OUTPUT_DIRECTORY"
  TREE_FILES=(process-probe.json scope.txt sources.sha256 library.sha256)
  [[ -f rootfs.sha256 ]] && TREE_FILES+=(rootfs.sha256)
  [[ -f guest-stderr.log ]] && TREE_FILES+=(guest-stderr.log)
  [[ -f host-disassembly.log ]] && TREE_FILES+=(host-disassembly.log)
  shasum -a 256 "${TREE_FILES[@]}" > tree.sha256
)
chmod 0600 "$OUTPUT_DIRECTORY"/*.txt "$OUTPUT_DIRECTORY"/*.json "$OUTPUT_DIRECTORY"/*.sha256
[[ ! -f "$OUTPUT_DIRECTORY/guest-stderr.log" ]] || chmod 0600 "$OUTPUT_DIRECTORY/guest-stderr.log"
[[ ! -f "$OUTPUT_DIRECTORY/host-disassembly.log" ]] || chmod 0600 "$OUTPUT_DIRECTORY/host-disassembly.log"

echo "Bootstrap ELF x86-64 controlado ejecutado mediante FEXCore Darwin."
echo "Evidencia privada: $OUTPUT_DIRECTORY"
