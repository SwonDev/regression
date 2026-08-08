#!/usr/bin/env bash

set -euo pipefail

# Materializa un RootFS glibc mínimo y privado para una única sonda ELF x86-64.
# Solo admite ejecutables cuya única dependencia DT_NEEDED sea libc.so.6. El
# componente Wine64 oficial puede añadir el cierre indivisible ntdll+libgcc.

PROGRAM=""
GUEST_PROGRAM=""
LOADER=""
LIBC=""
OUTPUT_DIRECTORY=""
SOURCE_LABEL=""
COMPONENT_KIND="generic"
PROTON_NTDLL=""
LIBGCC=""
PROTON_WINE_LOADER=""
PROTON_WINESERVER=""
PROTON_NLS=""
PROTON_LOCALE_NLS_DIR=""
PROTON_WINDOWS_DIR=""
PROTON_WINDOWS_ENTRY="cmd.exe"
PRIVATE_WINE_PREFIX=0
PROTON_WINDOWS_CMD_CLOSURE=(
  advapi32.dll
  cmd.exe
  gdi32.dll
  kernel32.dll
  kernelbase.dll
  msvcrt.dll
  ntdll.dll
  rpcrt4.dll
  sechost.dll
  shcore.dll
  shell32.dll
  shlwapi.dll
  ucrtbase.dll
  user32.dll
  win32u.dll
)
PROTON_WINDOWS_WINEBOOT_CLOSURE=(
  advapi32.dll
  cmd.exe
  gdi32.dll
  kernel32.dll
  kernelbase.dll
  msvcrt.dll
  ntdll.dll
  rpcrt4.dll
  sechost.dll
  shcore.dll
  shell32.dll
  start.exe
  shlwapi.dll
  ucrtbase.dll
  user32.dll
  win32u.dll
  wineboot.exe
  ws2_32.dll
)
PROTON_WINDOWS_CLOSURE=()

usage() {
  cat <<'EOF'
Uso: tools/research/prepare_fli_glibc_rootfs.sh \
  --program ELF_X86_64 --guest-program /RUTA_ABSOLUTA \
  --loader LD_LINUX_X86_64 --libc LIBC_X86_64 \
  --source-label ETIQUETA --output-dir RUTA_PRIVADA_NUEVA \
  [--component-kind generic|official-proton-wine64|official-proton-wine64-preloader|official-proton-wineserver \
  [--proton-ntdll NTDLL_SO --libgcc LIBGCC_S_SO_1] \
  [--proton-wine-loader WINE_X86_64] \
  [--proton-wineserver WINESERVER_X86_64] \
  [--proton-nls L_INTL_NLS] \
  [--proton-locale-nls-dir DIRECTORIO_NLS] \
  [--proton-windows-dir X86_64_WINDOWS \
   --proton-windows-entry cmd.exe|wineboot.exe] \
  [--private-wine-prefix]]

Crea un RootFS mínimo con un único ejecutable dinámico, ld-linux y libc. Para
Wine64 oficial, ntdll.so y libgcc_s.so.1 son una pareja opcional inseparable.
La mitad PE opcional se reduce al cierre estático verificado de cmd.exe o de
wineboot.exe. No incluye el orquestador Proton, Steam, credenciales, juegos ni
EAC.
EOF
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --program)
      [[ $# -ge 2 ]] || { usage >&2; exit 64; }
      PROGRAM="$2"
      shift 2
      ;;
    --guest-program)
      [[ $# -ge 2 ]] || { usage >&2; exit 64; }
      GUEST_PROGRAM="$2"
      shift 2
      ;;
    --loader)
      [[ $# -ge 2 ]] || { usage >&2; exit 64; }
      LOADER="$2"
      shift 2
      ;;
    --libc)
      [[ $# -ge 2 ]] || { usage >&2; exit 64; }
      LIBC="$2"
      shift 2
      ;;
    --source-label)
      [[ $# -ge 2 ]] || { usage >&2; exit 64; }
      SOURCE_LABEL="$2"
      shift 2
      ;;
    --output-dir)
      [[ $# -ge 2 ]] || { usage >&2; exit 64; }
      OUTPUT_DIRECTORY="$2"
      shift 2
      ;;
    --component-kind)
      [[ $# -ge 2 ]] || { usage >&2; exit 64; }
      COMPONENT_KIND="$2"
      shift 2
      ;;
    --proton-ntdll)
      [[ $# -ge 2 ]] || { usage >&2; exit 64; }
      PROTON_NTDLL="$2"
      shift 2
      ;;
    --libgcc)
      [[ $# -ge 2 ]] || { usage >&2; exit 64; }
      LIBGCC="$2"
      shift 2
      ;;
    --proton-wine-loader)
      [[ $# -ge 2 ]] || { usage >&2; exit 64; }
      PROTON_WINE_LOADER="$2"
      shift 2
      ;;
    --proton-wineserver)
      [[ $# -ge 2 ]] || { usage >&2; exit 64; }
      PROTON_WINESERVER="$2"
      shift 2
      ;;
    --proton-nls)
      [[ $# -ge 2 ]] || { usage >&2; exit 64; }
      PROTON_NLS="$2"
      shift 2
      ;;
    --proton-locale-nls-dir)
      [[ $# -ge 2 ]] || { usage >&2; exit 64; }
      PROTON_LOCALE_NLS_DIR="$2"
      shift 2
      ;;
    --proton-windows-dir)
      [[ $# -ge 2 ]] || { usage >&2; exit 64; }
      PROTON_WINDOWS_DIR="$2"
      shift 2
      ;;
    --proton-windows-entry)
      [[ $# -ge 2 ]] || { usage >&2; exit 64; }
      PROTON_WINDOWS_ENTRY="$2"
      shift 2
      ;;
    --private-wine-prefix)
      PRIVATE_WINE_PREFIX=1
      shift
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

case "$PROTON_WINDOWS_ENTRY" in
  cmd.exe)
    PROTON_WINDOWS_CLOSURE=("${PROTON_WINDOWS_CMD_CLOSURE[@]}")
    ;;
  wineboot.exe)
    PROTON_WINDOWS_CLOSURE=("${PROTON_WINDOWS_WINEBOOT_CLOSURE[@]}")
    ;;
  *)
    echo "ERROR: --proton-windows-entry no pertenece al conjunto permitido." >&2
    exit 64
    ;;
esac

[[ -n "$PROGRAM" && -n "$GUEST_PROGRAM" && -n "$LOADER" && -n "$LIBC" \
  && -n "$OUTPUT_DIRECTORY" && -n "$SOURCE_LABEL" ]] || {
  usage >&2
  exit 64
}
[[ "$GUEST_PROGRAM" =~ ^/[A-Za-z0-9_+./-]+$ \
  && "/$GUEST_PROGRAM/" != *"/../"* \
  && "/$GUEST_PROGRAM/" != *"/./"* \
  && "$GUEST_PROGRAM" != *"//"* ]] || {
  echo "ERROR: --guest-program debe ser una ruta absoluta y normalizada." >&2
  exit 64
}
[[ "$SOURCE_LABEL" =~ ^[A-Za-z0-9_.+-]+$ ]] || {
  echo "ERROR: --source-label solo admite una etiqueta estable y no sensible." >&2
  exit 64
}
[[ "$COMPONENT_KIND" == "generic" \
  || "$COMPONENT_KIND" == "official-proton-wine64" \
  || "$COMPONENT_KIND" == "official-proton-wine64-preloader" \
  || "$COMPONENT_KIND" == "official-proton-wineserver" ]] || {
  echo "ERROR: --component-kind no pertenece al conjunto permitido." >&2
  exit 64
}
if [[ "$COMPONENT_KIND" == "official-proton-wine64" \
  && "$GUEST_PROGRAM" != "/opt/proton/files/lib/wine/x86_64-unix/wine64" ]]; then
  echo "ERROR: el componente Proton Wine64 exige su ruta invitada canónica." >&2
  exit 64
fi
if [[ "$COMPONENT_KIND" == "official-proton-wine64-preloader" \
  && "$GUEST_PROGRAM" != "/opt/proton/files/lib/wine/x86_64-unix/wine-preloader" ]]; then
  echo "ERROR: el preloader Proton Wine64 exige su ruta invitada canónica." >&2
  exit 64
fi
if [[ "$COMPONENT_KIND" == "official-proton-wineserver" \
  && "$GUEST_PROGRAM" != "/opt/proton/files/bin/wineserver" ]]; then
  echo "ERROR: wineserver oficial exige su ruta invitada canónica." >&2
  exit 64
fi
if [[ -n "$PROTON_NTDLL" || -n "$LIBGCC" ]]; then
  [[ "$COMPONENT_KIND" == "official-proton-wine64" \
    || "$COMPONENT_KIND" == "official-proton-wine64-preloader" ]] || {
    echo "ERROR: ntdll y libgcc solo se admiten para Wine64 oficial de Proton." >&2
    exit 64
  }
  [[ -n "$PROTON_NTDLL" && -n "$LIBGCC" ]] || {
    echo "ERROR: --proton-ntdll y --libgcc forman una pareja inseparable." >&2
    exit 64
  }
fi
if [[ "$COMPONENT_KIND" == "official-proton-wine64-preloader" ]]; then
  [[ -n "$PROTON_WINE_LOADER" && -n "$PROTON_NTDLL" && -n "$LIBGCC" ]] || {
    echo "ERROR: el preloader oficial requiere wine x86-64 y el cierre ntdll+libgcc." >&2
    exit 64
  }
elif [[ -n "$PROTON_WINE_LOADER" ]]; then
  echo "ERROR: --proton-wine-loader solo pertenece al preloader oficial." >&2
  exit 64
fi
if [[ -n "$PROTON_WINESERVER" \
  && "$COMPONENT_KIND" != "official-proton-wine64-preloader" ]]; then
  echo "ERROR: --proton-wineserver solo pertenece al cierre del preloader oficial." >&2
  exit 64
fi
if [[ -n "$PROTON_NLS" ]]; then
  [[ "$COMPONENT_KIND" == "official-proton-wineserver" \
    || "$COMPONENT_KIND" == "official-proton-wine64-preloader" ]] || {
    echo "ERROR: l_intl.nls solo pertenece al cierre oficial que ejecuta wineserver." >&2
    exit 64
  }
  [[ -f "$PROTON_NLS" && ! -L "$PROTON_NLS" && -s "$PROTON_NLS" ]] || {
    echo "ERROR: --proton-nls debe ser un archivo regular no vacío." >&2
    exit 66
  }
  file "$PROTON_NLS" | grep -Fq ': data' || {
    echo "ERROR: l_intl.nls no tiene el formato de datos esperado." >&2
    exit 65
  }
fi
if [[ -n "$PROTON_LOCALE_NLS_DIR" ]]; then
  [[ "$COMPONENT_KIND" == "official-proton-wine64-preloader" \
    && "$PROTON_WINDOWS_ENTRY" == "wineboot.exe" ]] || {
    echo "ERROR: las tablas locale solo pertenecen al cierre de wineboot oficial." >&2
    exit 64
  }
  [[ -n "$PROTON_NLS" ]] || {
    echo "ERROR: las tablas locale requieren también l_intl.nls." >&2
    exit 64
  }
  [[ -d "$PROTON_LOCALE_NLS_DIR" && ! -L "$PROTON_LOCALE_NLS_DIR" ]] || {
    echo "ERROR: --proton-locale-nls-dir debe ser un directorio regular." >&2
    exit 66
  }
  for name in c_20127.nls locale.nls; do
    source="$PROTON_LOCALE_NLS_DIR/$name"
    [[ -f "$source" && ! -L "$source" && -s "$source" ]] || {
      echo "ERROR: falta una tabla locale regular no vacía: $name" >&2
      exit 66
    }
    file "$source" | grep -Fq ': data' || {
      echo "ERROR: la tabla locale no tiene el formato esperado: $name" >&2
      exit 65
    }
  done
elif [[ "$PROTON_WINDOWS_ENTRY" == "wineboot.exe" ]]; then
  echo "ERROR: wineboot.exe exige el par c_20127.nls + locale.nls." >&2
  exit 64
fi
if [[ -n "$PROTON_WINDOWS_DIR" ]]; then
  [[ "$COMPONENT_KIND" == "official-proton-wine64" \
    || "$COMPONENT_KIND" == "official-proton-wine64-preloader" ]] || {
    echo "ERROR: la mitad PE solo se admite para Wine64 oficial de Proton." >&2
    exit 64
  }
  [[ -n "$PROTON_NTDLL" && -n "$LIBGCC" ]] || {
    echo "ERROR: la mitad PE requiere primero el cierre Unix ntdll+libgcc." >&2
    exit 64
  }
  [[ -d "$PROTON_WINDOWS_DIR" && ! -L "$PROTON_WINDOWS_DIR" ]] || {
    echo "ERROR: --proton-windows-dir debe ser un directorio regular." >&2
    exit 66
  }
elif [[ "$PROTON_WINDOWS_ENTRY" != "cmd.exe" ]]; then
  echo "ERROR: --proton-windows-entry exige --proton-windows-dir." >&2
  exit 64
fi
if [[ "$PRIVATE_WINE_PREFIX" -eq 1 ]]; then
  [[ "$COMPONENT_KIND" == "official-proton-wine64" \
    || "$COMPONENT_KIND" == "official-proton-wine64-preloader" \
    || "$COMPONENT_KIND" == "official-proton-wineserver" ]] || {
    echo "ERROR: el prefijo privado solo pertenece a sondas Wine/Proton oficiales." >&2
    exit 64
  }
fi

SOURCES=("$PROGRAM" "$LOADER" "$LIBC")
if [[ -n "$PROTON_NTDLL" ]]; then
  SOURCES+=("$PROTON_NTDLL" "$LIBGCC")
fi
if [[ -n "$PROTON_WINE_LOADER" ]]; then
  SOURCES+=("$PROTON_WINE_LOADER")
fi
if [[ -n "$PROTON_WINESERVER" ]]; then
  SOURCES+=("$PROTON_WINESERVER")
fi
for source in "${SOURCES[@]}"; do
  [[ -f "$source" && ! -L "$source" ]] || {
    echo "ERROR: cada entrada debe ser un archivo regular, no un enlace: $source" >&2
    exit 66
  }
  file "$source" | grep -Fq 'ELF 64-bit LSB' || {
    echo "ERROR: la entrada no es un ELF de Linux de 64 bits: $source" >&2
    exit 65
  }
  file "$source" | grep -Fq 'x86-64' || {
    echo "ERROR: la entrada no es x86-64: $source" >&2
    exit 65
  }
done

if [[ -n "$PROTON_WINDOWS_DIR" ]]; then
  for name in "${PROTON_WINDOWS_CLOSURE[@]}"; do
    source="$PROTON_WINDOWS_DIR/$name"
    [[ -f "$source" && ! -L "$source" ]] || {
      echo "ERROR: el cierre Windows debe contener archivos regulares: $name" >&2
      exit 66
    }
    file "$source" | grep -Fq 'PE32+ executable' || {
      echo "ERROR: el cierre Windows contiene un archivo que no es PE32+: $name" >&2
      exit 65
    }
    file "$source" | grep -Fq 'x86-64' || {
      echo "ERROR: el cierre Windows contiene un PE que no es x86-64: $name" >&2
      exit 65
    }
    while IFS= read -r dependency; do
      [[ -z "$dependency" ]] && continue
      case " ${PROTON_WINDOWS_CLOSURE[*]} " in
        *" $dependency "*) ;;
        *)
          echo "ERROR: dependencia PE fuera del cierre permitido: $name -> $dependency" >&2
          exit 65
          ;;
      esac
    done < <(/usr/bin/objdump -p "$source" \
      | awk '$1 == "DLL" && $2 == "Name:" { print tolower($3) }')
    SOURCES+=("$source")
  done
fi
if [[ -n "$PROTON_NLS" ]]; then
  SOURCES+=("$PROTON_NLS")
fi
if [[ -n "$PROTON_LOCALE_NLS_DIR" ]]; then
  SOURCES+=(
    "$PROTON_LOCALE_NLS_DIR/c_20127.nls"
    "$PROTON_LOCALE_NLS_DIR/locale.nls"
  )
fi
[[ ! -e "$OUTPUT_DIRECTORY" && ! -L "$OUTPUT_DIRECTORY" ]] || {
  echo "ERROR: --output-dir debe ser una ruta nueva." >&2
  exit 66
}

OBJDUMP_OUTPUT="$(/usr/bin/objdump -p "$PROGRAM")"
grep -Fq 'file format elf64-x86-64' <<<"$OBJDUMP_OUTPUT" || {
  echo "ERROR: objdump no reconoce el ejecutable como ELF x86-64." >&2
  exit 65
}
NEEDED_COUNT="$(awk '$1 == "NEEDED" { ++count } END { print count + 0 }' <<<"$OBJDUMP_OUTPUT")"
NEEDED_LIBRARY="$(awk '$1 == "NEEDED" { print $2 }' <<<"$OBJDUMP_OUTPUT")"
if [[ "$COMPONENT_KIND" == "official-proton-wine64-preloader" ]]; then
  [[ "$NEEDED_COUNT" -eq 0 ]] || {
    echo "ERROR: el wine-preloader oficial debe ser un PIE estático sin DT_NEEDED." >&2
    exit 65
  }
  strings -a "$PROGRAM" | grep -Fxq '/lib64/ld-linux-x86-64.so.2' && {
    echo "ERROR: el wine-preloader oficial no debe declarar PT_INTERP." >&2
    exit 65
  }
else
  [[ "$NEEDED_COUNT" -eq 1 && "$NEEDED_LIBRARY" == "libc.so.6" ]] || {
    echo "ERROR: el RootFS mínimo solo admite un ejecutable que dependa exclusivamente de libc.so.6." >&2
    exit 65
  }
  file "$PROGRAM" | grep -Fq 'interpreter /lib64/ld-linux-x86-64.so.2' || {
    echo "ERROR: el ejecutable no solicita el intérprete x86-64 esperado." >&2
    exit 65
  }
fi

if [[ -n "$PROTON_WINE_LOADER" ]]; then
  WINE_LOADER_NEEDED="$(/usr/bin/objdump -p "$PROTON_WINE_LOADER" \
    | awk '$1 == "NEEDED" { print $2 }')"
  [[ "$WINE_LOADER_NEEDED" == "libc.so.6" ]] || {
    echo "ERROR: el cargador wine x86-64 debe depender exclusivamente de libc.so.6." >&2
    exit 65
  }
  file "$PROTON_WINE_LOADER" \
    | grep -Fq 'interpreter /lib64/ld-linux-x86-64.so.2' || {
    echo "ERROR: el cargador wine x86-64 no solicita el intérprete esperado." >&2
    exit 65
  }
fi

if [[ -n "$PROTON_WINESERVER" ]]; then
  WINESERVER_NEEDED="$(/usr/bin/objdump -p "$PROTON_WINESERVER" \
    | awk '$1 == "NEEDED" { print $2 }')"
  [[ "$WINESERVER_NEEDED" == "libc.so.6" ]] || {
    echo "ERROR: wineserver debe depender exclusivamente de libc.so.6." >&2
    exit 65
  }
  file "$PROTON_WINESERVER" \
    | grep -Fq 'interpreter /lib64/ld-linux-x86-64.so.2' || {
    echo "ERROR: wineserver no solicita el intérprete x86-64 esperado." >&2
    exit 65
  }
fi

if [[ -n "$PROTON_NTDLL" ]]; then
  NTDLL_NEEDED="$(/usr/bin/objdump -p "$PROTON_NTDLL" \
    | awk '$1 == "NEEDED" { print $2 }' | LC_ALL=C sort)"
  [[ "$NTDLL_NEEDED" == $'libc.so.6\nlibgcc_s.so.1' ]] || {
    echo "ERROR: ntdll.so no tiene el cierre DT_NEEDED esperado." >&2
    exit 65
  }
  LIBGCC_NEEDED="$(/usr/bin/objdump -p "$LIBGCC" \
    | awk '$1 == "NEEDED" { print $2 }')"
  [[ "$LIBGCC_NEEDED" == "libc.so.6" ]] || {
    echo "ERROR: libgcc_s.so.1 debe depender exclusivamente de libc.so.6." >&2
    exit 65
  }
fi

umask 077
ROOTFS="$OUTPUT_DIRECTORY/rootfs"
install -d -m 0700 \
  "$(dirname "$ROOTFS$GUEST_PROGRAM")" \
  "$ROOTFS/usr/lib64" \
  "$ROOTFS/lib/x86_64-linux-gnu" \
  "$ROOTFS/home/regression" \
  "$ROOTFS/tmp"
if [[ "$PRIVATE_WINE_PREFIX" -eq 1 ]]; then
  install -d -m 0700 "$ROOTFS/home/regression/.wine"
fi
install -m 0500 "$PROGRAM" "$ROOTFS$GUEST_PROGRAM"
install -m 0500 "$LOADER" "$ROOTFS/usr/lib64/ld-linux-x86-64.so.2"
install -m 0500 "$LIBC" "$ROOTFS/lib/x86_64-linux-gnu/libc.so.6"
ln "$ROOTFS/lib/x86_64-linux-gnu/libc.so.6" "$ROOTFS/usr/lib64/libc.so.6"
if [[ -n "$PROTON_NTDLL" ]]; then
  install -m 0500 "$PROTON_NTDLL" \
    "$ROOTFS/opt/proton/files/lib/wine/x86_64-unix/ntdll.so"
  install -m 0500 "$LIBGCC" "$ROOTFS/lib/x86_64-linux-gnu/libgcc_s.so.1"
  ln "$ROOTFS/lib/x86_64-linux-gnu/libgcc_s.so.1" \
    "$ROOTFS/usr/lib64/libgcc_s.so.1"
fi
if [[ -n "$PROTON_WINE_LOADER" ]]; then
  install -m 0500 "$PROTON_WINE_LOADER" \
    "$ROOTFS/opt/proton/files/lib/wine/x86_64-unix/wine"
fi
if [[ -n "$PROTON_WINESERVER" ]]; then
  install -d -m 0700 "$ROOTFS/opt/proton/files/bin"
  install -m 0500 "$PROTON_WINESERVER" \
    "$ROOTFS/opt/proton/files/bin/wineserver"
fi
if [[ -n "$PROTON_NLS" ]]; then
  install -d -m 0700 "$ROOTFS/opt/proton/files/share/wine/nls"
  install -m 0400 "$PROTON_NLS" \
    "$ROOTFS/opt/proton/files/share/wine/nls/l_intl.nls"
fi
if [[ -n "$PROTON_LOCALE_NLS_DIR" ]]; then
  install -m 0400 "$PROTON_LOCALE_NLS_DIR/c_20127.nls" \
    "$ROOTFS/opt/proton/files/share/wine/nls/c_20127.nls"
  install -m 0400 "$PROTON_LOCALE_NLS_DIR/locale.nls" \
    "$ROOTFS/opt/proton/files/share/wine/nls/locale.nls"
fi
if [[ -n "$PROTON_WINDOWS_DIR" ]]; then
  install -d -m 0700 "$ROOTFS/opt/proton/files/lib/wine/x86_64-windows"
  for name in "${PROTON_WINDOWS_CLOSURE[@]}"; do
    mode=0400
    [[ "$name" == *.exe ]] && mode=0500
    install -m "$mode" "$PROTON_WINDOWS_DIR/$name" \
      "$ROOTFS/opt/proton/files/lib/wine/x86_64-windows/$name"
  done
fi

{
  printf 'schema=%s\n' '4'
  printf 'source_label=%s\n' "$SOURCE_LABEL"
  printf 'guest_program=%s\n' "$GUEST_PROGRAM"
  printf 'component_kind=%s\n' "$COMPONENT_KIND"
  printf 'libc_guest_path=%s\n' '/lib/x86_64-linux-gnu/libc.so.6'
  printf 'libc_verifier_alias=%s\n' '/usr/lib64/libc.so.6'
  printf 'scope=%s\n' 'private-open-source-process-abi-probe'
  printf 'guest_home=%s\n' '/home/regression'
  printf 'guest_home_mode=%s\n' '0700'
  if [[ "$PRIVATE_WINE_PREFIX" -eq 1 ]]; then
    printf 'private_wine_prefix=%s\n' '/home/regression/.wine'
    printf 'private_wine_prefix_mode=%s\n' '0700'
  else
    printf 'private_wine_prefix=%s\n' 'not-included'
  fi
  printf 'guest_tmp=%s\n' '/tmp'
  printf 'guest_tmp_mode=%s\n' '0700'
  if [[ "$COMPONENT_KIND" == "official-proton-wine64" \
    || "$COMPONENT_KIND" == "official-proton-wine64-preloader" \
    || "$COMPONENT_KIND" == "official-proton-wineserver" ]]; then
    if [[ "$COMPONENT_KIND" == "official-proton-wine64-preloader" ]]; then
      printf 'proton_component=%s\n' 'wine64-preloader-included'
    elif [[ "$COMPONENT_KIND" == "official-proton-wineserver" ]]; then
      printf 'proton_component=%s\n' 'wineserver-included-as-main-program'
    else
      printf 'proton_component=%s\n' 'wine64-included'
    fi
    printf 'proton_component_origin=%s\n' 'official-valve-build'
    if [[ "$COMPONENT_KIND" == "official-proton-wine64-preloader" ]]; then
      printf 'proton_preloader=%s\n' 'x86_64-static-pie-included'
      printf 'proton_preloader_origin=%s\n' 'official-valve-build'
      printf 'proton_wine_loader=%s\n' 'x86_64-included'
      printf 'proton_wine_loader_origin=%s\n' 'official-valve-build'
      printf 'wine_loader_noexec=%s\n' 'required-by-official-proton-route'
    fi
    if [[ "$COMPONENT_KIND" == "official-proton-wineserver" ]]; then
      printf 'proton_wineserver=%s\n' 'included-as-main-program'
      printf 'proton_wineserver_origin=%s\n' 'official-valve-build'
    elif [[ -n "$PROTON_WINESERVER" ]]; then
      printf 'proton_wineserver=%s\n' 'x86_64-included'
      printf 'proton_wineserver_origin=%s\n' 'official-valve-build'
    else
      printf 'proton_wineserver=%s\n' 'not-included'
    fi
    if [[ -n "$PROTON_NLS" ]]; then
      printf 'proton_nls=%s\n' '/opt/proton/files/share/wine/nls/l_intl.nls'
      printf 'proton_nls_origin=%s\n' 'official-valve-source'
    else
      printf 'proton_nls=%s\n' 'not-included'
    fi
    if [[ -n "$PROTON_LOCALE_NLS_DIR" ]]; then
      printf 'proton_locale_nls=%s\n' 'c_20127.nls+locale.nls-included'
      printf 'proton_locale_nls_origin=%s\n' 'official-valve-source'
    else
      printf 'proton_locale_nls=%s\n' 'not-included'
    fi
    if [[ -n "$PROTON_NTDLL" ]]; then
      printf 'proton_ntdll=%s\n' 'included'
      printf 'proton_ntdll_origin=%s\n' 'official-valve-build'
      printf 'libgcc=%s\n' 'included'
      printf 'libgcc_origin=%s\n' 'official-steam-runtime'
    else
      printf 'proton_ntdll=%s\n' 'not-included'
      printf 'libgcc=%s\n' 'not-included'
    fi
    if [[ -n "$PROTON_WINDOWS_DIR" ]]; then
      printf 'proton_windows_entry=%s\n' "$PROTON_WINDOWS_ENTRY"
      printf 'proton_windows_closure=%s\n' "${PROTON_WINDOWS_ENTRY%.exe}-static-imports-included"
      printf 'proton_windows_closure_origin=%s\n' 'official-valve-build'
      printf 'proton_windows_closure_count=%s\n' "${#PROTON_WINDOWS_CLOSURE[@]}"
    else
      printf 'proton_windows_entry=%s\n' 'not-included'
      printf 'proton_windows_closure=%s\n' 'not-included'
    fi
  else
    printf 'proton_component=%s\n' 'not-included'
    printf 'proton_component_origin=%s\n' 'none'
  fi
  printf 'proton_orchestrator=%s\n' 'not-included'
  printf 'steam=%s\n' 'not-included'
  printf 'credentials=%s\n' 'not-included'
  printf 'game=%s\n' 'not-included'
  printf 'eac=%s\n' 'not-included'
} > "$OUTPUT_DIRECTORY/provenance.txt"
SOURCE_RECEIPT_PATHS=(
  "source$GUEST_PROGRAM"
  'source/ld-linux-x86-64.so.2'
  'source/libc.so.6'
)
if [[ -n "$PROTON_NTDLL" ]]; then
  SOURCE_RECEIPT_PATHS+=('source/ntdll.so' 'source/libgcc_s.so.1')
fi
if [[ -n "$PROTON_WINE_LOADER" ]]; then
  SOURCE_RECEIPT_PATHS+=('source/x86_64-unix/wine')
fi
if [[ -n "$PROTON_WINESERVER" ]]; then
  SOURCE_RECEIPT_PATHS+=('source/bin/wineserver')
fi
if [[ -n "$PROTON_WINDOWS_DIR" ]]; then
  for name in "${PROTON_WINDOWS_CLOSURE[@]}"; do
    SOURCE_RECEIPT_PATHS+=("source/x86_64-windows/$name")
  done
fi
if [[ -n "$PROTON_NLS" ]]; then
  SOURCE_RECEIPT_PATHS+=('source/share/wine/nls/l_intl.nls')
fi
if [[ -n "$PROTON_LOCALE_NLS_DIR" ]]; then
  SOURCE_RECEIPT_PATHS+=(
    'source/share/wine/nls/c_20127.nls'
    'source/share/wine/nls/locale.nls'
  )
fi
{
  for index in "${!SOURCES[@]}"; do
    hash="$(shasum -a 256 "${SOURCES[$index]}" | awk '{ print $1 }')"
    printf '%s  %s\n' "$hash" "${SOURCE_RECEIPT_PATHS[$index]}"
  done
} > "$OUTPUT_DIRECTORY/source.sha256"
ROOTFS_HASH_PATHS=(
  "$ROOTFS$GUEST_PROGRAM" \
  "$ROOTFS/usr/lib64/ld-linux-x86-64.so.2" \
  "$ROOTFS/lib/x86_64-linux-gnu/libc.so.6" \
  "$ROOTFS/usr/lib64/libc.so.6"
)
if [[ -n "$PROTON_NTDLL" ]]; then
  ROOTFS_HASH_PATHS+=(
    "$ROOTFS/opt/proton/files/lib/wine/x86_64-unix/ntdll.so"
    "$ROOTFS/lib/x86_64-linux-gnu/libgcc_s.so.1"
    "$ROOTFS/usr/lib64/libgcc_s.so.1"
  )
fi
if [[ -n "$PROTON_WINE_LOADER" ]]; then
  ROOTFS_HASH_PATHS+=(
    "$ROOTFS/opt/proton/files/lib/wine/x86_64-unix/wine"
  )
fi
if [[ -n "$PROTON_WINESERVER" ]]; then
  ROOTFS_HASH_PATHS+=(
    "$ROOTFS/opt/proton/files/bin/wineserver"
  )
fi
if [[ -n "$PROTON_WINDOWS_DIR" ]]; then
  for name in "${PROTON_WINDOWS_CLOSURE[@]}"; do
    ROOTFS_HASH_PATHS+=("$ROOTFS/opt/proton/files/lib/wine/x86_64-windows/$name")
  done
fi
if [[ -n "$PROTON_NLS" ]]; then
  ROOTFS_HASH_PATHS+=(
    "$ROOTFS/opt/proton/files/share/wine/nls/l_intl.nls"
  )
fi
if [[ -n "$PROTON_LOCALE_NLS_DIR" ]]; then
  ROOTFS_HASH_PATHS+=(
    "$ROOTFS/opt/proton/files/share/wine/nls/c_20127.nls"
    "$ROOTFS/opt/proton/files/share/wine/nls/locale.nls"
  )
fi
shasum -a 256 "${ROOTFS_HASH_PATHS[@]}" \
  | sed "s#  $ROOTFS/#  rootfs/#" > "$OUTPUT_DIRECTORY/rootfs.sha256"
(
  cd "$OUTPUT_DIRECTORY"
  shasum -a 256 provenance.txt source.sha256 rootfs.sha256 > tree.sha256
)
chmod 0600 "$OUTPUT_DIRECTORY"/*.txt "$OUTPUT_DIRECTORY"/*.sha256

echo "RootFS glibc x86-64 mínimo preparado: $OUTPUT_DIRECTORY"
