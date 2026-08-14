#!/usr/bin/env bash
# Materializa la receta gráfica de botella ya blindada como componente LGPL de solo lectura.
# La fuente debe coincidir byte a byte con los PIN compilados; nunca se aprende de una botella
# arbitraria ni se acepta un manifiesto aportado por el usuario.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SOURCE_BOTTLE="${REGRESSION_BASELINE_BOTTLE:-$HOME/Library/Application Support/Regression/Bottles/Steam}"
SOURCE_SYSTEM32="$SOURCE_BOTTLE/drive_c/windows/system32"
OUTPUT_ROOT="${REGRESSION_STEAM_BOTTLE_BASELINE_OUTPUT:-$ROOT/build/steam-bottle-baseline/1}"
WORK_ROOT="$(/usr/bin/mktemp -d /private/tmp/regression-steam-bottle-baseline.XXXXXX)"
trap '/usr/bin/find "$WORK_ROOT" -depth -delete 2>/dev/null || true' EXIT

fail()
{
    printf 'ERROR: %s\n' "$*" >&2
    exit 1
}

source_authority()
{
    cat <<'EOF'
ff2062e17cfb5d4a0e4259e01fb264bb53e33fa093816e60c6e5a8f1e201b0eb d3d9.dll
0b97d99a61eeeefefc4451d49477d31dc8c6e50ecca7651003655ac67f72aef4 d3d10core.dll
e6209af3a04947504af1f12b4533eded103687841197cff45a92d1a5f916c0a8 d3d11.dll
25f74dafc3ebaf77ddc5a7b32d933853462c303a2636399860e80937cda82941 dxgi.dll
30385de93e7908cd7296b72b3c99a4bdf4686f95148e40aff014b4ec9b9a9041 winemetal.dll
EOF
}

baseline_authority()
{
    cat <<'EOF'
ff2062e17cfb5d4a0e4259e01fb264bb53e33fa093816e60c6e5a8f1e201b0eb d3d9.dll
0b97d99a61eeeefefc4451d49477d31dc8c6e50ecca7651003655ac67f72aef4 d3d10core.dll
e6209af3a04947504af1f12b4533eded103687841197cff45a92d1a5f916c0a8 d3d11.dll
25f74dafc3ebaf77ddc5a7b32d933853462c303a2636399860e80937cda82941 dxgi.dll
d53c92237bc98e1b8a17139f6bb22aa8a93c6cc1c7307a7146e38529acefa179 winemetal.dll
EOF
}

[[ -d "$SOURCE_SYSTEM32" && ! -L "$SOURCE_SYSTEM32" ]] \
    || fail "la fuente system32 no es un directorio físico"
mkdir -m 700 "$WORK_ROOT/payload"
while IFS=' ' read -r expected module; do
    source_file="$SOURCE_SYSTEM32/$module"
    [[ -f "$source_file" && ! -L "$source_file" ]] || fail "falta $module en la fuente"
    actual="$(/usr/bin/shasum -a 256 "$source_file" | /usr/bin/awk '{print $1}')"
    [[ "$actual" == "$expected" ]] || fail "$module no coincide con la receta blindada"
    /usr/bin/install -m 0644 "$source_file" "$WORK_ROOT/payload/$module"
done < <(source_authority)

# winemetal conserva una ruta de compilación sin efecto en la ejecución. El asset público no
# puede filtrar el HOME del constructor: se sustituye por un marcador más corto y se rellena sin
# cambiar offsets, exactamente igual que el pipeline de release. El hash resultante está fijado.
source_length=${#HOME}
neutral="/Users/regression"
[[ ${#neutral} -le $source_length ]] || fail "el marcador público no cabe en la ruta privada"
padding=""
while [[ ${#padding} -lt $((source_length - ${#neutral})) ]]; do padding="${padding}_"; done
FROM_LITERAL="$HOME" TO_LITERAL="${neutral}${padding}" \
    /usr/bin/perl -0pi -e 's/\Q$ENV{FROM_LITERAL}\E/$ENV{TO_LITERAL}/g' \
    "$WORK_ROOT/payload/winemetal.dll"

while IFS=' ' read -r expected module; do
    actual="$(/usr/bin/shasum -a 256 "$WORK_ROOT/payload/$module" \
        | /usr/bin/awk '{print $1}')"
    [[ "$actual" == "$expected" ]] || fail "$module no coincide con la receta pública"
done < <(baseline_authority)

(
    cd "$WORK_ROOT/payload"
    while IFS=' ' read -r expected module; do
        printf '%s  ./%s\n' "$expected" "$module"
    done < <(baseline_authority) > manifest.sha256
    /usr/bin/shasum -a 256 -c manifest.sha256
)
/bin/chmod 0755 "$WORK_ROOT/payload"
/bin/chmod 0644 "$WORK_ROOT/payload/manifest.sha256" "$WORK_ROOT/payload"/*.dll

if [[ -e "$OUTPUT_ROOT" || -L "$OUTPUT_ROOT" ]]; then
    [[ -d "$OUTPUT_ROOT" && ! -L "$OUTPUT_ROOT" ]] || fail "el destino no es físico"
    /usr/bin/find "$OUTPUT_ROOT" -depth -delete
fi
/bin/mkdir -p "$(/usr/bin/dirname "$OUTPUT_ROOT")"
/bin/mv "$WORK_ROOT/payload" "$OUTPUT_ROOT"
printf 'Componente de botella blindado preparado en %s\n' "$OUTPUT_ROOT"
