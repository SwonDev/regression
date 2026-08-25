#!/usr/bin/env bash
# Deriva y verifica la autoridad pública 1.12 desde el builder raw sellado.
# La transformación refleja exactamente el tramo de package_release que modifica
# estos cuatro Mach-O: strip de símbolos, saneado literal y firma ad hoc.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
PUBLIC_BUILD="${REGRESSION_PUBLIC_WINE_BUILD:-$ROOT/build/release-1.12.0/wine64-public}"
MODE="${1:-}"
PRINT_DERIVED=false
WINE_ROOT="${2:-}"
SCRATCH=""

fail() { printf 'ERROR: %s\n' "$*" >&2; exit 1; }

cleanup() {
    [[ -n "$SCRATCH" && -d "$SCRATCH" ]] || return 0
    find "$SCRATCH" -mindepth 1 -depth -delete
    rmdir "$SCRATCH"
}
trap cleanup EXIT

runtime_entries() {
    cat <<'EOF'
tools/wine/wine bin/wine 276090bbf100ae02ad5bac5cd254dab1c105c3b44fd025b5ef205f3775463ea1
server/wineserver bin/wineserver e88c8c63e2a4cbfb8cacfb1b5c322ea166665575e5982ecd2ef6a831fde5212a
loader/wine lib/wine/x86_64-unix/wine 0bd32de30071bdedc05a40d5750a4603586e45a1a66be25aad7975366b81f620
dlls/ntdll/ntdll.so lib/wine/x86_64-unix/ntdll.so 5e96c72ac1ad66e56803f8055d3d6e8294e56c7596d85e02acc4e7eda4006570
EOF
}

sanitize_literal() {
    local root="$1" source="$2" neutral="$3" source_length neutral_length replacement
    [[ -n "$source" ]] || return 0
    source_length=${#source}
    neutral_length=${#neutral}
    (( neutral_length <= source_length )) \
        || fail "el reemplazo portable no cabe en el literal de origen"
    replacement="$neutral$(printf '%*s' $((source_length - neutral_length)) '' | tr ' ' '_')"
    while IFS= read -r -d '' candidate; do
        FROM_LITERAL="$source" TO_LITERAL="$replacement" \
            /usr/bin/perl -0pi -e 's/\Q$ENV{FROM_LITERAL}\E/$ENV{TO_LITERAL}/g' "$candidate"
    done < <(rg -a -F -l -0 "$source" "$root" || true)
}

remove_private_rpaths() {
    local candidate="$1" rpath
    while IFS= read -r rpath; do
        [[ "$rpath" == /* && "$rpath" != /usr/lib/* && "$rpath" != /System/Library/* ]] \
            || continue
        install_name_tool -delete_rpath "$rpath" "$candidate"
    done < <(otool -l "$candidate" \
        | awk '/LC_RPATH/{rpath=1; next} rpath && $1 == "path" { print $2; rpath=0 }')
}

derive_runtime() {
    local destination="$1" source_relative destination_relative expected destination_path actual
    while IFS=' ' read -r source_relative destination_relative expected; do
        destination_path="$destination/$destination_relative"
        mkdir -p "$(dirname "$destination_path")"
        cp -c "$PUBLIC_BUILD/$source_relative" "$destination_path"
        remove_private_rpaths "$destination_path"
        xcrun strip -S "$destination_path"
    done < <(runtime_entries)
    sanitize_literal "$destination" "$ROOT" /opt/regression/src
    sanitize_literal "$destination" "$HOME" /Users/regression
    while IFS=' ' read -r source_relative destination_relative expected; do
        destination_path="$destination/$destination_relative"
        codesign --force --sign - "$destination_path" >/dev/null
        actual="$(shasum -a 256 "$destination_path" | awk '{print $1}')"
        if [[ "$PRINT_DERIVED" == "true" ]]; then
            printf '%s %s %s\n' "$source_relative" "$destination_relative" "$actual"
            continue
        fi
        [[ "$actual" == "$expected" ]] \
            || fail "la transformación pública 1.12 no deriva el PIN esperado: $destination_relative"
    done < <(runtime_entries)
}

verify_runtime() {
    local destination="$1" expected_root source_relative destination_relative expected destination_path derived_path actual derived rpaths
    [[ -d "$destination" && ! -L "$destination" ]] \
        || fail "el wine-root público debe ser un directorio físico"
    SCRATCH="$(mktemp -d /private/tmp/regression-public-runtime-derive.XXXXXX)"
    expected_root="$SCRATCH/wine-root"
    derive_runtime "$expected_root"
    while IFS=' ' read -r source_relative destination_relative expected; do
        destination_path="$destination/$destination_relative"
        derived_path="$expected_root/$destination_relative"
        [[ -f "$destination_path" && ! -L "$destination_path" ]] \
            || fail "falta el runtime público transformado: $destination_relative"
        actual="$(shasum -a 256 "$destination_path" | awk '{print $1}')"
        derived="$(shasum -a 256 "$derived_path" | awk '{print $1}')"
        [[ "$derived" == "$expected" && "$actual" == "$expected" ]] \
            || fail "el runtime público no coincide con la transformación derivada: $destination_relative"
        cmp -s "$derived_path" "$destination_path" \
            || fail "el runtime público difiere de la transformación derivada: $destination_relative"
        rpaths="$(otool -l "$destination_path" \
            | awk '/LC_RPATH/{rpath=1; next} rpath && $1 == "path" { print $2; rpath=0 }')"
        case "$destination_relative" in
            bin/wine|bin/wineserver|lib/wine/x86_64-unix/wine)
                [[ -z "$rpaths" ]] \
                    || fail "el runtime público conserva LC_RPATH no portable: $destination_relative"
                ;;
            lib/wine/x86_64-unix/ntdll.so)
                [[ "$rpaths" == "@loader_path/" ]] \
                    || fail "ntdll público no conserva exclusivamente @loader_path/"
                ;;
        esac
        if awk '$0 ~ /^\// && $0 !~ /^\/System\/Library\// && $0 !~ /^\/usr\/lib\// { found=1 } END { exit !found }' \
            <<< "$rpaths"; then
            fail "el runtime público conserva LC_RPATH absoluto no permitido: $destination_relative"
        fi
    done < <(runtime_entries)
    if rg -a -F -l "$ROOT" "$destination" >/dev/null ||
       rg -a -F -l "$HOME" "$destination" >/dev/null; then
        fail "el runtime público transformado conserva una ruta personal"
    fi
}

REGRESSION_PUBLIC_WINE_BUILD="$PUBLIC_BUILD" \
    "$ROOT/build/verify-sealed-public-runtime-1.12.sh" >/dev/null

case "$MODE" in
    --print-derived)
        # Emite la tabla que debe fijarse arriba tras recompilar el runtime.
        PRINT_DERIVED=true
        SCRATCH="$(mktemp -d /private/tmp/regression-public-runtime-print.XXXXXX)"
        derive_runtime "$SCRATCH"
        find "$SCRATCH" -depth -delete
        exit 0
        ;;
    --derive)
        [[ -n "$WINE_ROOT" ]] || fail "uso: $0 --derive WINE_ROOT | --verify WINE_ROOT"
        [[ -d "$WINE_ROOT" && ! -L "$WINE_ROOT" ]] \
            || fail "el wine-root público debe ser un directorio físico"
        derive_runtime "$WINE_ROOT"
        ;;
    --verify)
        [[ -n "$WINE_ROOT" ]] || fail "uso: $0 --derive WINE_ROOT | --verify WINE_ROOT"
        verify_runtime "$WINE_ROOT"
        ;;
    *)
        fail "uso: $0 --derive WINE_ROOT | --verify WINE_ROOT"
        ;;
esac

printf 'Autoridad pública derivada 1.12 verificada: %s\n' "$WINE_ROOT"
