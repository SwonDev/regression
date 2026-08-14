#!/usr/bin/env bash
set -Eeuo pipefail

PATH="/usr/bin:/bin:/usr/sbin:/sbin"
export PATH
umask 077

# Expone transaccionalmente el payload LGPL firmado que viaja con Regression. La reparación
# solo cambia el enlace versionado bajo Application Support; no modifica Wine ni la botella.

APP_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)"
SOURCE_ROOT="$APP_ROOT/Contents/SharedSupport/components/windows-media/1"
APPLICATION_SUPPORT="$HOME/Library/Application Support/Regression"
COMPONENT_PARENT="$APPLICATION_SUPPORT/Components/WindowsMedia"
COMPONENT_ROOT="$COMPONENT_PARENT/1"
BACKUP_PARENT="$APPLICATION_SUPPORT/Backups/Components/WindowsMedia"
TRANSACTION_PARENT="$APPLICATION_SUPPORT/Transactions/WindowsMedia"
JOURNAL="$TRANSACTION_PARENT/1-link-repair.intent"
SYNC_HELPER="${REGRESSION_WINDOWS_MEDIA_INTERNAL_TEST_SYNC_HELPER:-$APP_ROOT/Contents/SharedSupport/bin/regressionctl}"
COMPONENT_ID="windows-media-gstreamer"
COMPONENT_VERSION="1"
DEVELOPMENT_MANIFEST_SHA256="ac662661fb3384c6ad100066391cab209f9de60b2e129fb92e07365ee6fe9bb1"
PUBLIC_MANIFEST_SHA256="da8ba98d99d157f981ef3a2472dc9d74c9ce4673ef126bdd61851b9dd21dedb3"
VERIFY_ONLY=false
APP_ID="none"
LEASE_TOKEN="none"
LEASE_OWNER_PID="none"
LEASE_CONSUMED=false
RECEIPT_APP_ID="none"
JOURNAL_CONTENT=""
STAGE=""
STAGE_REFERENCE="none"
ROLLBACK=""
ROLLBACK_REFERENCE="none"
PREVIOUS_PRESENT=false
PREVIOUS_FINGERPRINT=""
COMPONENT_SWAPPED=false
INSTALL_COMMITTED=false

fail()
{
    printf 'ERROR: %s\n' "$*" >&2
    exit 1
}

reject_symlink_path_chain()
{
    local path="$1"
    local cursor="$path"

    while [[ "$cursor" != "/" && "$cursor" != "." ]]; do
        [[ ! -L "$cursor" ]] || fail \
            "la ruta administrada contiene un enlace simbólico: $cursor"
        cursor="$(/usr/bin/dirname "$cursor")"
    done
}

validate_internal_test_seams()
{
    local requested_variant="${REGRESSION_WINDOWS_MEDIA_INTERNAL_TEST_VARIANT:-}"
    local requested_fault="${REGRESSION_WINDOWS_MEDIA_INTERNAL_TEST_FAULT:-}"
    local requested_sync_helper="${REGRESSION_WINDOWS_MEDIA_INTERNAL_TEST_SYNC_HELPER:-}"

    [[ -n "$requested_variant" || -n "$requested_fault" || -n "$requested_sync_helper" ]] \
        || return 0
    [[ "$APP_ROOT" == /private/tmp/regression-windows-media-test.*/* \
       && "$HOME" == /private/tmp/regression-windows-media-test.*/* ]] || fail \
        "los seams internos de Windows Media solo aceptan fixtures privados en /private/tmp"
    if [[ -n "$requested_sync_helper" ]]; then
        [[ "$requested_sync_helper" == /private/tmp/regression-windows-media-test.*/* ]] \
            || fail "el helper interno de Windows Media debe pertenecer al fixture privado"
        reject_symlink_path_chain "$requested_sync_helper"
        [[ -f "$requested_sync_helper" && -x "$requested_sync_helper" ]] \
            || fail "el helper interno de Windows Media no es un ejecutable regular"
    fi
    case "$requested_variant" in
        ""|development|public) ;;
        *) fail "variante interna de Windows Media no válida" ;;
    esac
    case "$requested_fault" in
        ""|after-prepared-wal|after-prepared|after-backed-up-wal|after-backed-up|after-swapped-wal|after-swapped|post-swap) ;;
        *) fail "punto de fallo interno de Windows Media no válido" ;;
    esac
}

anchored_link_mutation()
{
    "$SYNC_HELPER" windows-media-anchored-link "$@" \
        --app-id "$APP_ID" --lease-token "$LEASE_TOKEN" \
        --owner-pid "$LEASE_OWNER_PID" >/dev/null
}

anchored_private_file()
{
    local operation="$1"
    local kind="$2"

    "$SYNC_HELPER" windows-media-private-file "$operation" "$kind" \
        --app-id "$APP_ID" --lease-token "$LEASE_TOKEN" \
        --owner-pid "$LEASE_OWNER_PID"
}

expected_manifest_sha256()
{
    case "${REGRESSION_WINDOWS_MEDIA_INTERNAL_TEST_VARIANT:-}" in
        development) printf '%s\n' "$DEVELOPMENT_MANIFEST_SHA256" ;;
        public) printf '%s\n' "$PUBLIC_MANIFEST_SHA256" ;;
        "")
            if [[ "$APP_ROOT" == "/Applications/Regression.app" ]]; then
                printf '%s\n' "$PUBLIC_MANIFEST_SHA256"
            else
                printf '%s\n' "$DEVELOPMENT_MANIFEST_SHA256"
            fi
            ;;
    esac
}

verify_source()
{
    local expected_manifest="$1"
    local actual_manifest
    local manifest_entries
    local actual_files

    reject_symlink_path_chain "$SOURCE_ROOT"
    [[ -d "$SOURCE_ROOT" && ! -L "$SOURCE_ROOT" ]] || return 1
    [[ -f "$SOURCE_ROOT/manifest.sha256" && ! -L "$SOURCE_ROOT/manifest.sha256" ]] \
        || return 1
    actual_manifest="$(/usr/bin/shasum -a 256 "$SOURCE_ROOT/manifest.sha256" \
        | /usr/bin/awk '{print $1}')"
    [[ "$actual_manifest" == "$expected_manifest" ]] || return 2
    [[ -z "$(/usr/bin/find "$SOURCE_ROOT" -type l -print -quit)" ]] || return 1
    [[ -z "$(/usr/bin/find "$SOURCE_ROOT" ! -type d ! -type f -print -quit)" ]] || return 1
    manifest_entries="$(/usr/bin/wc -l < "$SOURCE_ROOT/manifest.sha256" \
        | /usr/bin/tr -d ' ')"
    actual_files="$(/usr/bin/find "$SOURCE_ROOT" -type f ! -name manifest.sha256 \
        | /usr/bin/wc -l | /usr/bin/tr -d ' ')"
    [[ "$actual_files" == "$manifest_entries" ]] || return 1
    (
        cd "$SOURCE_ROOT"
        /usr/bin/shasum -a 256 -c manifest.sha256 >/dev/null
    ) || return 1
    /usr/bin/codesign --verify --strict "$SOURCE_ROOT/gstreamer-1.0/libgstasf.dylib" \
        >/dev/null 2>&1 || return 1
    /usr/bin/codesign --verify --strict "$SOURCE_ROOT/gstreamer-1.0/libgstlibav.dylib" \
        >/dev/null 2>&1 || return 1
}

component_is_current()
{
    local expected_manifest="$1"

    [[ -L "$COMPONENT_ROOT" ]] || return 1
    [[ "$(/usr/bin/readlink "$COMPONENT_ROOT")" == "$SOURCE_ROOT" ]] || return 1
    verify_source "$expected_manifest"
}

fingerprint_component_root()
{
    local description

    if [[ -L "$COMPONENT_ROOT" ]]; then
        description="symlink:$(/usr/bin/readlink "$COMPONENT_ROOT")"
    elif [[ -e "$COMPONENT_ROOT" ]]; then
        description="path:$(/usr/bin/stat -f '%HT:%d:%i:%z' "$COMPONENT_ROOT")"
    else
        description="missing"
    fi
    printf '%s' "$description" | /usr/bin/shasum -a 256 | /usr/bin/awk '{print $1}'
}

write_journal()
{
    local phase="$1"
    local expected_manifest="$2"

    printf '%s\n' \
        'schema=1' \
        'kind=trusted-component-link-repair-intent' \
        "component_id=$COMPONENT_ID" \
        "component_version=$COMPONENT_VERSION" \
        "app_id=$APP_ID" \
        "manifest_sha256=$expected_manifest" \
        "previous_present=$PREVIOUS_PRESENT" \
        "previous_fingerprint=$PREVIOUS_FINGERPRINT" \
        "rollback_reference=$ROLLBACK_REFERENCE" \
        "stage_reference=$STAGE_REFERENCE" \
        "phase=$phase" | anchored_private_file write intent
}

journal_value()
{
    local key="$1"
    printf '%s\n' "$JOURNAL_CONTENT" \
        | /usr/bin/awk -F= -v key="$key" '$1 == key { sub(/^[^=]*=/, ""); print }'
}

is_canonical_app_id()
{
    local value="$1"
    [[ "$value" =~ ^[1-9][0-9]{0,9}$ ]] || return 1
    (( 10#$value <= 4294967295 ))
}

reconcile_pending_transaction()
{
    local phase journal_app_id journal_manifest journal_previous journal_rollback journal_stage
    local recorded_fingerprint

    [[ -e "$JOURNAL" || -L "$JOURNAL" ]] || return 0
    [[ -f "$JOURNAL" && ! -L "$JOURNAL" ]] || fail \
        "la intención Windows Media pendiente no es un fichero regular"
    JOURNAL_CONTENT="$(anchored_private_file read intent)" || fail \
        "la intención Windows Media pendiente no admite lectura anclada privada"
    [[ "$(printf '%s\n' "$JOURNAL_CONTENT" | /usr/bin/wc -l | /usr/bin/tr -d ' ')" == "11" ]] || fail \
        "la intención Windows Media pendiente no tiene el contrato esperado"
    [[ "$(journal_value schema)" == "1" \
       && "$(journal_value kind)" == "trusted-component-link-repair-intent" \
       && "$(journal_value component_id)" == "$COMPONENT_ID" \
       && "$(journal_value component_version)" == "$COMPONENT_VERSION" ]] || fail \
        "la intención Windows Media pendiente no pertenece a esta receta"
    journal_app_id="$(journal_value app_id)"
    journal_manifest="$(journal_value manifest_sha256)"
    journal_previous="$(journal_value previous_present)"
    recorded_fingerprint="$(journal_value previous_fingerprint)"
    journal_rollback="$(journal_value rollback_reference)"
    journal_stage="$(journal_value stage_reference)"
    phase="$(journal_value phase)"
    [[ "$journal_manifest" == "$EXPECTED_MANIFEST_SHA256" \
       && "$recorded_fingerprint" =~ ^[0-9a-f]{64}$ \
       && ( "$journal_previous" == true || "$journal_previous" == false ) ]] || fail \
        "la intención Windows Media pendiente no coincide con la autoridad actual"
    is_canonical_app_id "$journal_app_id" || fail \
        "la intención Windows Media pendiente no contiene un App ID canónico"
    [[ "$journal_app_id" == "$APP_ID" ]] || fail \
        "la intención Windows Media pendiente pertenece a otro App ID"
    [[ "$journal_stage" =~ ^\.1-stage-[0-9]+$ ]] || fail \
        "la referencia de staging Windows Media no es válida"
    if [[ "$journal_rollback" != "none" ]]; then
        [[ "$journal_rollback" =~ ^1-before-repair-[0-9]{8}-[0-9]{6}-[0-9]+$ ]] || fail \
            "la referencia de rollback Windows Media no es válida"
        ROLLBACK_REFERENCE="$journal_rollback"
        ROLLBACK="$BACKUP_PARENT/$ROLLBACK_REFERENCE"
    fi
    PREVIOUS_PRESENT="$journal_previous"
    PREVIOUS_FINGERPRINT="$recorded_fingerprint"
    RECEIPT_APP_ID="$journal_app_id"
    STAGE_REFERENCE="$journal_stage"
    STAGE="$COMPONENT_PARENT/$STAGE_REFERENCE"

    case "$phase" in
        prepared)
            if [[ -L "$STAGE" ]]; then
                anchored_link_mutation remove-stage "$STAGE_REFERENCE"
            elif [[ -e "$STAGE" ]]; then
                fail "el staging Windows Media pendiente dejó de ser un enlace"
            fi
            if [[ "$PREVIOUS_PRESENT" == true ]]; then
                [[ -e "$COMPONENT_ROOT" || -L "$COMPONENT_ROOT" ]] || fail \
                    "la fase prepared perdió el componente anterior"
                [[ "$(fingerprint_component_root)" == "$PREVIOUS_FINGERPRINT" ]] || fail \
                    "la fase prepared no conserva el componente anterior"
            else
                [[ ! -e "$COMPONENT_ROOT" && ! -L "$COMPONENT_ROOT" ]] || fail \
                    "la fase prepared encontró un componente no autorizado"
            fi
            anchored_private_file remove intent
            STAGE=""
            ;;
        backed-up)
            [[ "$PREVIOUS_PRESENT" == true && -n "$ROLLBACK" ]] || fail \
                "la fase backed-up no declara un rollback anterior"
            if [[ -e "$COMPONENT_ROOT" || -L "$COMPONENT_ROOT" ]]; then
                [[ "$(fingerprint_component_root)" == "$PREVIOUS_FINGERPRINT" \
                   && ! -e "$ROLLBACK" && ! -L "$ROLLBACK" ]] || fail \
                    "la fase backed-up tiene un estado ambiguo"
            else
                [[ -e "$ROLLBACK" || -L "$ROLLBACK" ]] || fail \
                    "la fase backed-up no conserva un rollback restaurable"
                anchored_link_mutation restore-backup "$ROLLBACK_REFERENCE"
            fi
            if [[ -L "$STAGE" ]]; then
                anchored_link_mutation remove-stage "$STAGE_REFERENCE"
            elif [[ -e "$STAGE" ]]; then
                fail "el staging Windows Media pendiente dejó de ser un enlace"
            fi
            anchored_private_file remove intent
            STAGE=""
            ;;
        swapped)
            if component_is_current "$EXPECTED_MANIFEST_SHA256"; then
                write_receipt "$EXPECTED_MANIFEST_SHA256" succeeded \
                    "$(fingerprint_component_root)"
                anchored_private_file remove intent
                INSTALL_COMMITTED=true
                STAGE=""
                return 0
            fi
            if [[ -L "$STAGE" ]]; then
                anchored_link_mutation remove-stage "$STAGE_REFERENCE"
            elif [[ -e "$STAGE" ]]; then
                fail "el staging Windows Media pendiente dejó de ser un enlace"
            fi
            if [[ -L "$COMPONENT_ROOT" ]]; then
                anchored_link_mutation remove-current
            elif [[ -e "$COMPONENT_ROOT" ]]; then
                fail "la fase swapped encontró un destino no administrado"
            fi
            if [[ -n "$ROLLBACK" && ( -e "$ROLLBACK" || -L "$ROLLBACK" ) ]]; then
                anchored_link_mutation restore-backup "$ROLLBACK_REFERENCE"
            elif [[ "$PREVIOUS_PRESENT" == true ]]; then
                fail "la fase swapped perdió el rollback anterior"
            fi
            anchored_private_file remove intent
            STAGE=""
            ;;
        *) fail "la fase de la intención Windows Media no es válida" ;;
    esac
}

write_receipt()
{
    local expected_manifest="$1"
    local result="$2"
    local after_fingerprint="$3"

    # Recibo operativo del enlace local. No suplanta RepairReceipt ni certifica el juego.
    printf '%s\n' \
        'schema=1' \
        'kind=trusted-component-link-repair' \
        "component_id=$COMPONENT_ID" \
        "component_version=$COMPONENT_VERSION" \
        "app_id=$RECEIPT_APP_ID" \
        "manifest_sha256=$expected_manifest" \
        "previous_fingerprint=$PREVIOUS_FINGERPRINT" \
        "after_fingerprint=$after_fingerprint" \
        "rollback_reference=$ROLLBACK_REFERENCE" \
        "result=$result" \
        "created_at=$(/bin/date -u +%Y-%m-%dT%H:%M:%SZ)" \
        | anchored_private_file write receipt
}

cleanup()
{
    local status=$?
    local rollback_succeeded=false
    trap - EXIT
    set +e

    if [[ -n "$STAGE" && -L "$STAGE" ]]; then
        anchored_link_mutation remove-stage "$STAGE_REFERENCE" || true
    fi
    if [[ $status -ne 0 && "$INSTALL_COMMITTED" != true ]]; then
        if [[ "$COMPONENT_SWAPPED" == true ]]; then
            if [[ -L "$COMPONENT_ROOT" ]]; then
                anchored_link_mutation remove-current || true
            elif [[ -e "$COMPONENT_ROOT" ]]; then
                printf 'ERROR: el destino cambió durante el rollback; se conserva la intención %s\n' \
                    "$JOURNAL" >&2
            fi
        fi
        if [[ -n "$ROLLBACK" && ( -e "$ROLLBACK" || -L "$ROLLBACK" ) \
              && ! -e "$COMPONENT_ROOT" && ! -L "$COMPONENT_ROOT" ]]; then
            anchored_link_mutation restore-backup "$ROLLBACK_REFERENCE" || true
            rollback_succeeded=true
            printf 'Se restauró el enlace Windows Media anterior desde %s\n' "$ROLLBACK" >&2
        elif [[ "$PREVIOUS_PRESENT" == true \
                && ( -e "$COMPONENT_ROOT" || -L "$COMPONENT_ROOT" ) \
                && "$(fingerprint_component_root)" == "$PREVIOUS_FINGERPRINT" ]]; then
            rollback_succeeded=true
        elif [[ "$PREVIOUS_PRESENT" == false \
                && ! -e "$COMPONENT_ROOT" && ! -L "$COMPONENT_ROOT" ]]; then
            rollback_succeeded=true
        fi
        if [[ "$rollback_succeeded" == true && -f "$JOURNAL" && ! -L "$JOURNAL" ]]; then
            anchored_private_file remove intent || true
        fi
    fi
    if [[ "$LEASE_CONSUMED" == true ]]; then
        "$SYNC_HELPER" release-windows-media-lease "$LEASE_TOKEN" \
            --owner-pid "$LEASE_OWNER_PID" --consumed >/dev/null 2>&1 || true
    fi
    exit "$status"
}
trap cleanup EXIT

while [[ $# -gt 0 ]]; do
    case "$1" in
        --verify-only) VERIFY_ONLY=true ;;
        --app-id)
            shift
            [[ $# -gt 0 ]] || fail "--app-id requiere un Steam App ID canónico"
            is_canonical_app_id "$1" || fail "--app-id requiere un Steam App ID canónico"
            APP_ID="$1"
            ;;
        --lease-token)
            shift
            [[ $# -gt 0 && "$1" =~ ^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$ ]] \
                || fail "--lease-token requiere un token efímero válido"
            LEASE_TOKEN="$1"
            ;;
        --lease-owner-pid)
            shift
            [[ $# -gt 0 && "$1" =~ ^[1-9][0-9]{0,9}$ ]] \
                || fail "--lease-owner-pid requiere un PID válido"
            LEASE_OWNER_PID="$1"
            ;;
        --help|-h)
            printf 'Uso: %s [--verify-only] [--app-id STEAM_APP_ID]\n' "$0"
            exit 0
            ;;
        *) fail "argumento desconocido: $1" ;;
    esac
    shift
done

validate_internal_test_seams
EXPECTED_MANIFEST_SHA256="$(expected_manifest_sha256)"

if $VERIFY_ONLY; then
    [[ ! -e "$JOURNAL" && ! -L "$JOURNAL" ]] || fail \
        "existe una intención Windows Media pendiente de reconciliar"
    component_is_current "$EXPECTED_MANIFEST_SHA256" || fail \
        "el componente Windows Media 1 no está instalado o no supera la autoridad compilada"
    printf 'Componente Windows Media 1 verificado en %s\n' "$COMPONENT_ROOT"
    exit 0
fi
[[ "$APP_ID" != "none" ]] || fail \
    "--app-id es obligatorio para cualquier mutación Windows Media"
[[ "$LEASE_TOKEN" != "none" && "$LEASE_OWNER_PID" != "none" ]] || fail \
    "una mutación Windows Media exige un lease efímero"
RECEIPT_APP_ID="$APP_ID"
"$SYNC_HELPER" consume-windows-media-repair-lease "$APP_ID" "$LEASE_TOKEN" \
    --owner-pid "$LEASE_OWNER_PID" --revalidate-idle >/dev/null \
    || fail "el lease Windows Media no superó la revalidación de reposo"
LEASE_CONSUMED=true
anchored_private_file prepare intent >/dev/null || fail \
    "no se pudo preparar el almacenamiento Windows Media de forma anclada"
reconcile_pending_transaction
if [[ "$INSTALL_COMMITTED" == true ]] || component_is_current "$EXPECTED_MANIFEST_SHA256"; then
    printf 'Componente Windows Media 1 verificado en %s\n' "$COMPONENT_ROOT"
    exit 0
fi
set +e
verify_source "$EXPECTED_MANIFEST_SHA256"
source_status=$?
set -e
if [[ $source_status -eq 2 ]]; then
    fail "el manifiesto Windows Media no coincide con la autoridad compilada"
elif [[ $source_status -ne 0 ]]; then
    fail "el payload Windows Media sellado no supera su inventario y firmas"
fi

PREVIOUS_FINGERPRINT="$(fingerprint_component_root)"
if [[ -e "$COMPONENT_ROOT" || -L "$COMPONENT_ROOT" ]]; then
    PREVIOUS_PRESENT=true
    ROLLBACK_REFERENCE="1-before-repair-$(/bin/date +%Y%m%d-%H%M%S)-$$"
    ROLLBACK="$BACKUP_PARENT/$ROLLBACK_REFERENCE"
    [[ ! -e "$ROLLBACK" && ! -L "$ROLLBACK" ]] || fail \
        "la ruta de rollback Windows Media ya existe"
fi

STAGE_REFERENCE=".1-stage-$$"
STAGE="$COMPONENT_PARENT/$STAGE_REFERENCE"
[[ ! -e "$STAGE" && ! -L "$STAGE" ]] || fail \
    "la ruta de staging Windows Media ya existe"
write_journal prepared "$EXPECTED_MANIFEST_SHA256"
if [[ "${REGRESSION_WINDOWS_MEDIA_INTERNAL_TEST_FAULT:-}" == "after-prepared-wal" ]]; then
    /bin/kill -KILL $$
fi
anchored_link_mutation create-stage "$STAGE_REFERENCE"
if [[ "${REGRESSION_WINDOWS_MEDIA_INTERNAL_TEST_FAULT:-}" == "after-prepared" ]]; then
    /bin/kill -KILL $$
fi

if [[ "$PREVIOUS_PRESENT" == true ]]; then
    write_journal backed-up "$EXPECTED_MANIFEST_SHA256"
    if [[ "${REGRESSION_WINDOWS_MEDIA_INTERNAL_TEST_FAULT:-}" == "after-backed-up-wal" ]]; then
        /bin/kill -KILL $$
    fi
    anchored_link_mutation backup-current "$ROLLBACK_REFERENCE"
    if [[ "${REGRESSION_WINDOWS_MEDIA_INTERNAL_TEST_FAULT:-}" == "after-backed-up" ]]; then
        /bin/kill -KILL $$
    fi
fi
write_journal swapped "$EXPECTED_MANIFEST_SHA256"
if [[ "${REGRESSION_WINDOWS_MEDIA_INTERNAL_TEST_FAULT:-}" == "after-swapped-wal" ]]; then
    /bin/kill -KILL $$
fi
"$SYNC_HELPER" consume-windows-media-repair-lease "$APP_ID" "$LEASE_TOKEN" \
    --owner-pid "$LEASE_OWNER_PID" --revalidate-idle >/dev/null \
    || fail "el lease Windows Media perdió el reposo antes del cutover"
anchored_link_mutation commit-stage "$STAGE_REFERENCE"
STAGE=""
COMPONENT_SWAPPED=true
if [[ "${REGRESSION_WINDOWS_MEDIA_INTERNAL_TEST_FAULT:-}" == "after-swapped" ]]; then
    /bin/kill -KILL $$
fi

if [[ "${REGRESSION_WINDOWS_MEDIA_INTERNAL_TEST_FAULT:-}" == "post-swap" ]]; then
    fail "fallo interno posterior al cutover"
fi
component_is_current "$EXPECTED_MANIFEST_SHA256" || fail \
    "el componente instalado no supera la verificación final"
write_receipt "$EXPECTED_MANIFEST_SHA256" succeeded "$(fingerprint_component_root)"
INSTALL_COMMITTED=true
anchored_private_file remove intent
printf 'Componente Windows Media 1 instalado y verificado en %s\n' "$COMPONENT_ROOT"
