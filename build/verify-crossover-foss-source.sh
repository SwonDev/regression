#!/bin/bash

set -u
set -o pipefail

SCRIPT_DIR="$(CDPATH='' cd "$(dirname "$0")" && pwd)"
CONTRACT="${REGRESSION_CROSSOVER_FOSS_CONTRACT:-$SCRIPT_DIR/crossover-foss-26.3.0.contract}"
WORK_DIR=""

usage() {
    cat <<'EOF'
Uso:
  build/verify-crossover-foss-source.sh TAR_LOCAL [ÁRBOL_LOCAL]

Verifica, sin acceder a la red, el tar FOSS oficial fijado en el contrato.
ÁRBOL_LOCAL puede apuntar a un directorio que contenga wine/, dxvk/, etc. o
a la raíz extraída que contenga sources/. La comparación nunca modifica ese árbol.
EOF
}

emit() {
    printf '%s=%s\n' "$1" "$2"
}

fail() {
    emit result fail
    emit error_code "$1"
    emit error_detail "$2"
    exit 1
}

cleanup() {
    if [[ -n "$WORK_DIR" && -d "$WORK_DIR" ]]; then
        case "$WORK_DIR" in
            /private/tmp/regression-crossover-foss.*)
                /bin/rm -rf -- "$WORK_DIR"
                ;;
        esac
    fi
}

contract_value() {
    local key="$1"
    /usr/bin/awk -F= -v wanted="$key" '
        $1 == wanted {
            sub(/^[^=]*=/, "")
            print
            exit
        }
    ' "$CONTRACT"
}

sha256_file() {
    /usr/bin/shasum -a 256 "$1" | /usr/bin/awk '{print $1}'
}

validate_contract() {
    [[ -f "$CONTRACT" ]] || fail contract_missing "No se encontró el contrato reproducible."

    local version archive_hash archive_root baseline_count
    version="$(contract_value contract_version)"
    archive_hash="$(contract_value archive_sha256)"
    archive_root="$(contract_value archive_root)"
    baseline_count="$(/usr/bin/awk -F= '$1 == "baseline" { count++ } END { print count + 0 }' "$CONTRACT")"

    [[ "$version" == "1" ]] || fail contract_invalid "La versión del contrato no está soportada."
    [[ "$archive_hash" =~ ^[0-9a-f]{64}$ ]] \
        || fail contract_invalid "El SHA-256 del archivo no es válido."
    [[ "$archive_root" =~ ^[A-Za-z0-9._-]+$ ]] \
        || fail contract_invalid "La raíz declarada no es una ruta simple."
    (( baseline_count >= 3 )) \
        || fail contract_invalid "El contrato debe fijar al menos tres archivos base."
}

validate_member_paths() {
    local listing="$1"
    local root="$2"

    /usr/bin/awk -v root="$root" '
        BEGIN { bad = 0 }
        {
            path = $0
            if (path == "" || path ~ /^\// || path ~ /(^|\/)\.\.(\/|$)/ ||
                (path != root && index(path, root "/") != 1)) {
                bad = 1
            }
        }
        END { exit bad }
    ' "$listing" || fail archive_unsafe_path "El tar contiene una ruta absoluta, traversal o una entrada fuera de la raíz fijada."
}

validate_member_types_and_links() {
    local verbose_listing="$1"
    local root="$2"
    local links="$WORK_DIR/symlinks.tsv"

    : > "$links"
    /usr/bin/awk -v output="$links" '
        {
            type = substr($1, 1, 1)
            if (type == "-" || type == "d") next
            if (type != "l") exit 20

            # BSD tar muestra enlaces como: ... nombre -> destino. Para evitar
            # una interpretación ambigua, nombres o destinos con espacios se
            # rechazan en vez de intentar adivinarlos.
            if (NF != 11 || $10 != "->") exit 21
            print $9 "\t" $11 >> output
        }
    ' "$verbose_listing"
    case $? in
        0) ;;
        20) fail archive_unsafe_type "El tar contiene un tipo de entrada distinto de archivo, directorio o enlace simbólico." ;;
        *) fail archive_unsafe_link "El tar contiene un enlace simbólico ambiguo." ;;
    esac

    /usr/bin/awk -F '\t' -v root="$root" '
        function push(component) {
            if (component == "" || component == ".") return 1
            if (component == "..") {
                if (depth == 0) return 0
                depth--
                return 1
            }
            stack[++depth] = component
            return 1
        }
        {
            link = $1
            target = $2
            if (target == "" || target ~ /^\//) exit 1

            depth = 0
            count = split(link, parts, "/")
            for (i = 1; i < count; i++) if (!push(parts[i])) exit 1
            count = split(target, parts, "/")
            for (i = 1; i <= count; i++) if (!push(parts[i])) exit 1
            if (depth == 0 || stack[1] != root) exit 1
        }
    ' "$links" || fail archive_unsafe_link "Un enlace simbólico podría escapar de la raíz fijada."
}

verify_inventory() {
    local source_root="$1"
    local component
    local expected="$WORK_DIR/components.expected.txt"
    local actual="$WORK_DIR/components.actual.txt"
    : > "$expected"
    while IFS= read -r component; do
        [[ -n "$component" ]] || continue
        printf '%s\n' "$component" >> "$expected"
        [[ -d "$source_root/$component" ]] \
            || fail inventory_mismatch "Falta un componente declarado en el contrato: $component"
    done < <(/usr/bin/awk -F= '$1 == "component" { print $2 }' "$CONTRACT")

    /usr/bin/find "$source_root" -mindepth 1 -maxdepth 1 -type d -print \
        | /usr/bin/awk -F/ '{ print $NF }' \
        | LC_ALL=C /usr/bin/sort > "$actual"
    LC_ALL=C /usr/bin/sort -o "$expected" "$expected"
    /usr/bin/cmp -s "$expected" "$actual" \
        || fail inventory_mismatch "El inventario de primer nivel no coincide exactamente con el contrato."
}

verify_versions() {
    local source_root="$1"
    local record identifier relative expected
    while IFS='|' read -r record relative expected; do
        [[ "$record" == version=* ]] || continue
        identifier="${record#version=}"
        [[ -f "$source_root/$relative" ]] \
            || fail version_file_missing "Falta el archivo de versión para $identifier."
        /usr/bin/grep -F -q -- "$expected" "$source_root/$relative" \
            || fail version_mismatch "La versión declarada de $identifier no coincide."
    done < "$CONTRACT"
}

verify_baseline_hashes() {
    local source_root="$1"
    local record relative expected actual
    while IFS='|' read -r record expected; do
        [[ "$record" == baseline=* ]] || continue
        relative="${record#baseline=}"
        [[ -f "$source_root/$relative" && ! -L "$source_root/$relative" ]] \
            || fail baseline_file_missing "Falta un archivo base fijado: $relative"
        actual="$(sha256_file "$source_root/$relative")" \
            || fail hash_tool_failed "No se pudo calcular un SHA-256 base."
        [[ "$actual" == "$expected" ]] \
            || fail baseline_hash_mismatch "Un archivo base no coincide con la publicación oficial: $relative"
    done < "$CONTRACT"
}

resolve_comparison_root() {
    local candidate="$1"
    if [[ -d "$candidate/sources/wine" ]]; then
        printf '%s\n' "$candidate/sources"
    elif [[ -d "$candidate/wine" ]]; then
        printf '%s\n' "$candidate"
    else
        return 1
    fi
}

compare_tree() {
    local candidate="$1"
    local source_root record relative expected actual
    local changed="$WORK_DIR/tree-changed.txt"
    local missing="$WORK_DIR/tree-missing.txt"
    : > "$changed"
    : > "$missing"

    source_root="$(resolve_comparison_root "$candidate")" \
        || fail comparison_tree_invalid "El árbol opcional no contiene sources/wine ni wine."

    while IFS='|' read -r record expected; do
        [[ "$record" == baseline=* ]] || continue
        relative="${record#baseline=}"
        if [[ ! -f "$source_root/$relative" || -L "$source_root/$relative" ]]; then
            printf '%s\n' "$relative" >> "$missing"
            continue
        fi
        actual="$(sha256_file "$source_root/$relative")" \
            || fail hash_tool_failed "No se pudo calcular un SHA-256 del árbol comparado."
        if [[ "$actual" != "$expected" ]]; then
            printf '%s\n' "$relative" >> "$changed"
        fi
    done < "$CONTRACT"

    if [[ -s "$missing" ]]; then
        emit tracked_patch_points incomplete
    elif [[ -s "$changed" ]]; then
        emit tracked_patch_points differ
    else
        emit tracked_patch_points match
    fi
    emit tracked_patch_points_changed_count "$(/usr/bin/awk 'END { print NR + 0 }' "$changed")"
    emit tracked_patch_points_missing_count "$(/usr/bin/awk 'END { print NR + 0 }' "$missing")"
    if [[ -s "$changed" ]]; then
        emit tracked_patch_points_changed_files "$(/usr/bin/paste -sd, "$changed")"
    fi
    if [[ -s "$missing" ]]; then
        emit tracked_patch_points_missing_files "$(/usr/bin/paste -sd, "$missing")"
    fi

    compare_complete_tree "$SOURCE_ROOT" "$source_root"
}

build_tree_manifest() {
    local root="$1"
    local output="$2"
    local unsorted="$output.unsorted"
    local file_list="$output.files.nul"
    local file_hashes="$output.files.sha256"
    local path relative entry_type digest target line absolute
    : > "$unsorted"
    : > "$file_list"

    while IFS= read -r -d '' path; do
        relative="${path#"$root"/}"
        case "$relative" in
            *$'\n'*|*$'\r'*|*$'\t'*|*$'\\'*)
                return 2
                ;;
        esac

        if [[ -L "$path" ]]; then
            entry_type=l
            target="$(/usr/bin/readlink "$path")" || return 1
            case "$target" in
                *$'\n'*|*$'\r'*|*$'\t'*) return 2 ;;
            esac
            digest="$(printf '%s' "$target" | /usr/bin/shasum -a 256 | /usr/bin/awk '{print $1}')" \
                || return 1
        elif [[ -f "$path" ]]; then
            # Los hashes se calculan en lotes. Lanzar un proceso shasum por
            # cada uno de los más de 46.000 archivos oficiales no es un coste
            # razonable para un gate reproducible.
            printf '%s\0' "$path" >> "$file_list"
            continue
        elif [[ -d "$path" ]]; then
            entry_type=d
            digest=-
        else
            entry_type=o
            digest=-
        fi
        printf '%s\t%s\t%s\n' "$relative" "$entry_type" "$digest" >> "$unsorted"
    done < <(/usr/bin/find "$root" -mindepth 1 -print0)

    if [[ -s "$file_list" ]]; then
        /usr/bin/xargs -0 /usr/bin/shasum -a 256 -- < "$file_list" > "$file_hashes" \
            || return 1
        while IFS= read -r line; do
            digest="${line%% *}"
            absolute="${line#*  }"
            [[ "$digest" =~ ^[0-9a-f]{64}$ && "$absolute" != "$line" ]] || return 1
            relative="${absolute#"$root"/}"
            [[ "$relative" != "$absolute" ]] || return 1
            printf '%s\tf\t%s\n' "$relative" "$digest" >> "$unsorted"
        done < "$file_hashes"
    fi

    LC_ALL=C /usr/bin/sort "$unsorted" > "$output" || return 1
}

compare_complete_tree() {
    local expected_root="$1"
    local actual_root="$2"
    local expected_manifest="$WORK_DIR/tree.expected.manifest"
    local actual_manifest="$WORK_DIR/tree.actual.manifest"
    local expected_hash actual_hash expected_count actual_count

    build_tree_manifest "$expected_root" "$expected_manifest"
    case $? in
        0) ;;
        2) fail comparison_tree_unsupported_name "El árbol oficial contiene un nombre no representable de forma inequívoca." ;;
        *) fail comparison_tree_unreadable "No se pudo construir el manifiesto completo del árbol oficial." ;;
    esac
    build_tree_manifest "$actual_root" "$actual_manifest"
    case $? in
        0) ;;
        2) fail comparison_tree_unsupported_name "El árbol comparado contiene un nombre no representable de forma inequívoca." ;;
        *) fail comparison_tree_unreadable "No se pudo construir el manifiesto completo del árbol comparado." ;;
    esac

    expected_hash="$(sha256_file "$expected_manifest")" \
        || fail hash_tool_failed "No se pudo firmar el manifiesto oficial."
    actual_hash="$(sha256_file "$actual_manifest")" \
        || fail hash_tool_failed "No se pudo firmar el manifiesto comparado."
    expected_count="$(/usr/bin/awk 'END { print NR + 0 }' "$expected_manifest")"
    actual_count="$(/usr/bin/awk 'END { print NR + 0 }' "$actual_manifest")"

    emit tree_comparison_scope complete_paths_types_content_and_link_targets
    emit tree_expected_entry_count "$expected_count"
    emit tree_actual_entry_count "$actual_count"
    emit tree_expected_manifest_sha256 "$expected_hash"
    emit tree_actual_manifest_sha256 "$actual_hash"

    if /usr/bin/cmp -s "$expected_manifest" "$actual_manifest"; then
        emit tree_classification full_tree_match
        return 0
    fi
    emit tree_classification full_tree_differ
    return 3
}

if [[ $# -lt 1 || $# -gt 2 ]]; then
    usage >&2
    exit 2
fi

ARCHIVE_INPUT="$1"
COMPARISON_TREE="${2:-}"

validate_contract
[[ -f "$ARCHIVE_INPUT" ]] || fail archive_missing "La ruta indicada no es un archivo local."

WORK_DIR="$(/usr/bin/mktemp -d /private/tmp/regression-crossover-foss.XXXXXX)" \
    || fail temporary_directory_failed "No se pudo crear un directorio temporal privado."
trap cleanup 0
trap 'exit 130' HUP INT TERM
/bin/chmod 700 "$WORK_DIR" || fail temporary_directory_failed "No se pudo proteger el directorio temporal."

# Se trabaja sobre una copia temporal estable para que el archivo de entrada no
# pueda cambiar entre el cálculo del hash y la extracción.
ARCHIVE="$WORK_DIR/input.tar.gz"
/bin/cp -p -- "$ARCHIVE_INPUT" "$ARCHIVE" \
    || fail archive_copy_failed "No se pudo copiar el tar al área temporal."
/bin/chmod 600 "$ARCHIVE" \
    || fail archive_copy_failed "No se pudo proteger la copia temporal."

EXPECTED_ARCHIVE_HASH="$(contract_value archive_sha256)"
ACTUAL_ARCHIVE_HASH="$(sha256_file "$ARCHIVE")" \
    || fail hash_tool_failed "No se pudo calcular el SHA-256 del tar."
[[ "$ACTUAL_ARCHIVE_HASH" == "$EXPECTED_ARCHIVE_HASH" ]] \
    || fail archive_hash_mismatch "El tar local no es la publicación oficial fijada."

ROOT_NAME="$(contract_value archive_root)"
MEMBER_LIST="$WORK_DIR/members.txt"
VERBOSE_LIST="$WORK_DIR/members.verbose.txt"
LC_ALL=C /usr/bin/tar -tzf "$ARCHIVE" > "$MEMBER_LIST" \
    || fail archive_unreadable "El tar no se puede enumerar como gzip válido."
LC_ALL=C /usr/bin/tar -tvzf "$ARCHIVE" > "$VERBOSE_LIST" \
    || fail archive_unreadable "No se pudieron inspeccionar los tipos del tar."
validate_member_paths "$MEMBER_LIST" "$ROOT_NAME"
validate_member_types_and_links "$VERBOSE_LIST" "$ROOT_NAME"

EXTRACTED="$WORK_DIR/extracted"
/bin/mkdir -m 700 "$EXTRACTED" \
    || fail temporary_directory_failed "No se pudo preparar la extracción temporal."
/usr/bin/tar -xzf "$ARCHIVE" -C "$EXTRACTED" --no-same-owner --no-same-permissions \
    || fail archive_extraction_failed "La extracción temporal segura falló."

SOURCE_ROOT="$EXTRACTED/$ROOT_NAME"
[[ -d "$SOURCE_ROOT" ]] || fail archive_root_missing "No existe la raíz fijada tras extraer."
verify_inventory "$SOURCE_ROOT"
verify_versions "$SOURCE_ROOT"
verify_baseline_hashes "$SOURCE_ROOT"

emit contract_version "$(contract_value contract_version)"
emit release "$(contract_value release)"
emit archive_identity official_foss_release
emit archive_sha256 "$ACTUAL_ARCHIVE_HASH"
emit archive_safety pass
emit inventory pass
emit versions pass
emit baseline_hashes pass
emit artifact_gate pass

if [[ -n "$COMPARISON_TREE" ]]; then
    if compare_tree "$COMPARISON_TREE"; then
        emit comparison_gate pass
    else
        comparison_status=$?
        if [[ $comparison_status -eq 3 ]]; then
            emit comparison_gate fail
            emit aggregate_gate fail
            fail comparison_tree_differs "El árbol comparado no coincide completamente con el tar autenticado."
        fi
        fail comparison_failed "La comparación completa no pudo finalizar."
    fi
else
    emit tree_classification not_compared
    emit tracked_patch_points not_compared
    emit comparison_gate not_requested
fi

emit aggregate_gate pass
emit network_access none
emit result pass
