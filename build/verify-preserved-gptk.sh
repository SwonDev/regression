#!/usr/bin/env bash
# Comprueba después de instalar que el payload GPTK autorizado conserva bytes y enlaces.
set -Eeuo pipefail

EXPECTED_APP="${1:-}"
INSTALLED_APP="${2:-/Applications/Regression.app}"

fail()
{
    printf 'ERROR: %s\n' "$*" >&2
    exit 1
}

[[ -d "$EXPECTED_APP" && ! -L "$EXPECTED_APP" ]] \
    || fail "falta el bundle que contiene el GPTK de referencia"
[[ -d "$INSTALLED_APP" && ! -L "$INSTALLED_APP" ]] \
    || fail "falta el bundle instalado"

EXPECTED_GPTK="$EXPECTED_APP/Contents/SharedSupport/wine-root/lib/apple_gptk"
INSTALLED_GPTK="$INSTALLED_APP/Contents/SharedSupport/wine-root/lib/apple_gptk"
[[ -d "$EXPECTED_GPTK/external/D3DMetal.framework" ]] \
    || fail "la referencia no contiene D3DMetal.framework"
[[ -d "$INSTALLED_GPTK/external/D3DMetal.framework" ]] \
    || fail "la instalación no conservó D3DMetal.framework"

manifest()
{
    local root="$1"
    (
        cd "$root"
        /usr/sbin/mtree -c -k type,mode,link,sha256digest \
            | sed -n '/^# \.$/,$p'
    )
}

expected_manifest="$(mktemp /private/tmp/regression-gptk-expected.XXXXXX)"
installed_manifest="$(mktemp /private/tmp/regression-gptk-installed.XXXXXX)"
cleanup()
{
    unlink "$expected_manifest" 2>/dev/null || true
    unlink "$installed_manifest" 2>/dev/null || true
}
trap cleanup EXIT
manifest "$EXPECTED_GPTK" > "$expected_manifest"
manifest "$INSTALLED_GPTK" > "$installed_manifest"

if ! cmp -s "$expected_manifest" "$installed_manifest"; then
    printf 'Referencia: %s\nInstalado:  %s\n' \
        "$(shasum -a 256 "$expected_manifest" | awk '{ print $1 }')" \
        "$(shasum -a 256 "$installed_manifest" | awk '{ print $1 }')" >&2
    fail "el instalador no conservó exactamente los hashes, modos o enlaces GPTK"
fi

printf 'GPTK autorizado conservado: %s\n' \
    "$(shasum -a 256 "$expected_manifest" | awk '{ print $1 }')"
