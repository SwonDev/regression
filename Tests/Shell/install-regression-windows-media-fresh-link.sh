#!/usr/bin/env bash
# Verifica la provisión fresca del enlace multimedia sin abrir Wine, Steam ni la app.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
INSTALLER="$ROOT/Scripts/install_regression.sh"
WORK_ROOT="$(/usr/bin/mktemp -d /private/tmp/regression-wm-fresh-link.XXXXXX)"
trap '/usr/bin/find "$WORK_ROOT" -depth -delete' EXIT

abort_test()
{
    printf 'FAIL: %s\n' "$*" >&2
    exit 1
}

fail()
{
    printf 'PRODUCTION FAILURE: %s\n' "$*" >&2
}

cleanup_path()
{
    local target="$1"
    [[ -n "$target" && ( -e "$target" || -L "$target" ) ]] || return 0
    /usr/bin/find "$target" -depth -delete
}

eval "$(
    /usr/bin/sed -n '/^path_chain_is_physical()/,/^}/p' "$INSTALLER"
    /usr/bin/sed -n '/^provision_fresh_windows_media_link()/,/^}/p' "$INSTALLER"
)"

[[ "$(type -t provision_fresh_windows_media_link)" == function ]] \
    || abort_test "no se pudo cargar la provisión Windows Media"

export VERSION="test"
DESTINATION="$WORK_ROOT/Applications/Regression.app"
APP_SUPPORT="$WORK_ROOT/Library/Application Support/Regression"
PAYLOAD="$DESTINATION/Contents/SharedSupport/components/windows-media/1"
LINK="$APP_SUPPORT/Components/WindowsMedia/1"
WINDOWS_MEDIA_LINK_CREATED=0
WINDOWS_MEDIA_PROVISIONED_LINK=""

umask 077
/bin/mkdir -p "$PAYLOAD" "$APP_SUPPORT"
provision_fresh_windows_media_link
[[ "$WINDOWS_MEDIA_LINK_CREATED" -eq 1 \
    && "$WINDOWS_MEDIA_PROVISIONED_LINK" == "$LINK" \
    && -L "$LINK" \
    && "$(/usr/bin/readlink "$LINK")" == "$PAYLOAD" ]] \
    || abort_test "la instalación fresca no provisionó el enlace exacto"

first_inode="$(/usr/bin/stat -f %i "$LINK")"
provision_fresh_windows_media_link
second_inode="$(/usr/bin/stat -f %i "$LINK")"
[[ "$first_inode" == "$second_inode" ]] \
    || abort_test "la provisión fresca no es idempotente"

/bin/unlink "$LINK"
printf 'estado del usuario\n' > "$LINK"
WINDOWS_MEDIA_LINK_CREATED=0
WINDOWS_MEDIA_PROVISIONED_LINK=""
provision_fresh_windows_media_link
[[ -f "$LINK" && ! -L "$LINK" \
    && "$(<"$LINK")" == "estado del usuario" \
    && "$WINDOWS_MEDIA_LINK_CREATED" -eq 0 ]] \
    || abort_test "la instalación sustituyó un estado preexistente sin App ID"

rollback_guard="if [[ \$WINDOWS_MEDIA_LINK_CREATED -eq 1"
rollback_unlink="/bin/unlink \"\$WINDOWS_MEDIA_PROVISIONED_LINK\""
/usr/bin/grep -Fq "$rollback_guard" "$INSTALLER" \
    || abort_test "el rollback no registra el enlace creado por la instalación"
/usr/bin/grep -Fq "$rollback_unlink" "$INSTALLER" \
    || abort_test "el rollback no retira exclusivamente el enlace recién creado"

printf 'PASS: provisión fresca Windows Media idempotente y rollback acotado verificados.\n'
