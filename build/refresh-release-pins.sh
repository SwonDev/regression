#!/usr/bin/env bash
# Regenera los PIN del runtime desde artefactos reales, en lugar de copiarlos a mano.
#
# Un cambio en el runtime obligaba antes a reescribir el mismo SHA-256 en cinco
# sitios distintos (ComponentHealth, su test, el verificador del estado protegido
# y la evidencia del builder). Cualquier olvido dejaba la app en
# `unsupportedVariant` o el estado protegido en falso negativo, y el error solo
# aparecía después de instalar. Este script toma los bytes que de verdad se van a
# publicar y actualiza todos esos puntos a la vez.
#
#   build/refresh-release-pins.sh [--bundle RUTA] [--builder RUTA] [--check]
#
# --check no escribe nada: informa de las diferencias y devuelve 1 si alguna
# existe, de modo que sirve como puerta antes de empaquetar.
set -Eeuo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
BUNDLE="${REGRESSION_APP_PATH:-/Applications/Regression.app}"
BUILDER="${REGRESSION_RUNTIME_BUILDER:-$ROOT/build/wine64-dist}"
EVIDENCE="$ROOT/build/release-runtime-pins.txt"
CHECK_ONLY=false

while [[ $# -gt 0 ]]; do
    case "$1" in
        --bundle) BUNDLE="$2"; shift 2 ;;
        --builder) BUILDER="$2"; shift 2 ;;
        --check) CHECK_ONLY=true; shift ;;
        -h|--help) sed -n '2,16p' "$0"; exit 0 ;;
        *) printf 'ERROR: opción desconocida: %s\n' "$1" >&2; exit 64 ;;
    esac
done

fail() { printf 'ERROR: %s\n' "$*" >&2; exit 1; }

WINE_ROOT="$BUNDLE/Contents/SharedSupport/wine-root"
[[ -d "$WINE_ROOT" ]] || fail "el bundle no contiene un runtime: $WINE_ROOT"

sha() { shasum -a 256 "$1" | awk '{print $1}'; }

# Huella de los bytes de código, sin la firma: permite comparar un binario recién
# compilado con el mismo binario ya firmado dentro del bundle.
normalized() {
    local path="$1" scratch digest status
    [[ -f "$path" && ! -L "$path" ]] || return 1
    scratch="$(mktemp -d /private/tmp/regression-pin-normalize.XXXXXX)"
    cp "$path" "$scratch/payload" || { rm -rf "$scratch"; return 1; }
    codesign --remove-signature "$scratch/payload" >/dev/null 2>&1 || true
    set +e
    digest="$(/usr/bin/python3 "$ROOT/build/normalized-macho-sha256.py" "$scratch/payload")"
    status=$?
    set -e
    rm -rf "$scratch"
    [[ $status -eq 0 && "$digest" =~ ^[0-9a-f]{64}$ ]] || return 1
    printf '%s\n' "$digest"
}

# Conjunto sellado: los ficheros del bundle cuyo hash gobierna ComponentHealth.
SEALED_PATHS=(
    "bin/wine"
    "bin/wineserver"
    "lib/wine/x86_64-unix/wine"
    "lib/wine/x86_64-unix/ntdll.so"
    "share/wine/wine.inf"
    "lib/wine/x86_64-windows/ntdll.dll"
    "lib/wine/i386-windows/ntdll.dll"
)

# Builder: binario de compilación -> ruta equivalente dentro del runtime instalado.
BUILDER_ENTRIES=(
    "tools/wine/wine:bin/wine"
    "server/wineserver:bin/wineserver"
    "loader/wine:lib/wine/x86_64-unix/wine"
    "dlls/ntdll/ntdll.so:lib/wine/x86_64-unix/ntdll.so"
)

declare -a REPORT=()
changed=0

record() {
    local label="$1" old="$2" new="$3"
    if [[ "$old" == "$new" ]]; then
        REPORT+=("  = $label")
    else
        REPORT+=("  ~ $label")
        REPORT+=("      antes: ${old:-<ausente>}")
        REPORT+=("      ahora: $new")
        changed=1
    fi
}

# --- ComponentHealth.swift y su test -----------------------------------------
COMPONENT_HEALTH="$ROOT/Sources/RegressionCore/ComponentHealth.swift"
COMPONENT_TESTS="$ROOT/Tests/RegressionCoreTests/ComponentHealthTests.swift"

for relative in "${SEALED_PATHS[@]}"; do
    file="$WINE_ROOT/$relative"
    [[ -f "$file" ]] || fail "falta el fichero sellado en el bundle: $relative"
    actual="$(sha "$file")"
    current="$(python3 - "$COMPONENT_HEALTH" "$relative" <<'PY'
import io, re, sys
source, relative = sys.argv[1], sys.argv[2]
text = io.open(source, encoding="utf-8").read()
pattern = re.compile(
    r'relativePath:\s*"' + re.escape(relative) + r'",\s*\n\s*expectedSHA256:\s*"([0-9a-f]{64})"'
)
found = pattern.search(text)
print(found.group(1) if found else "")
PY
)"
    record "ComponentHealth $relative" "$current" "$actual"
    if ! $CHECK_ONLY && [[ "$current" != "$actual" && -n "$current" ]]; then
        python3 - "$COMPONENT_HEALTH" "$relative" "$actual" <<'PY'
import io, re, sys
source, relative, digest = sys.argv[1], sys.argv[2], sys.argv[3]
text = io.open(source, encoding="utf-8").read()
pattern = re.compile(
    r'(relativePath:\s*"' + re.escape(relative) + r'",\s*\n\s*expectedSHA256:\s*")([0-9a-f]{64})(")'
)
text, count = pattern.subn(lambda m: m.group(1) + digest + m.group(3), text)
assert count == 1, f"{relative}: {count} coincidencias en ComponentHealth"
io.open(source, "w", encoding="utf-8").write(text)
PY
        # El test fija el mismo conjunto con la ruta como clave del diccionario.
        python3 - "$COMPONENT_TESTS" "$relative" "$actual" <<'PY'
import io, re, sys
source, relative, digest = sys.argv[1], sys.argv[2], sys.argv[3]
text = io.open(source, encoding="utf-8").read()
pattern = re.compile(
    r'("' + re.escape(relative) + r'":\s*\n\s*")([0-9a-f]{64})(")'
)
text, count = pattern.subn(lambda m: m.group(1) + digest + m.group(3), text)
if count:
    io.open(source, "w", encoding="utf-8").write(text)
PY
        # Los verificadores repiten el mismo digest en su rama activa y en los
        # helpers por versión. El valor anterior identifica sin ambigüedad ese
        # estado, así que sustituirlo no toca las ramas históricas, que fijan
        # digests distintos de releases anteriores.
        for verifier in "$ROOT"/build/verify-*.sh; do
            [[ -f "$verifier" ]] || continue
            python3 - "$verifier" "$current" "$actual" <<'PY'
import io, sys
source, old, new = sys.argv[1], sys.argv[2], sys.argv[3]
text = io.open(source, encoding="utf-8").read()
if old and old in text:
    io.open(source, "w", encoding="utf-8").write(text.replace(old, new))
PY
        done
    fi
done

# --- Evidencia del builder ----------------------------------------------------
# El árbol de compilación pesa gigabytes y nunca se versiona: cuando desaparece,
# el estado protegido dejaba de poder acreditarse y la release se bloqueaba. La
# evidencia mínima sí cabe en el repositorio y es lo único que hace falta.
PROTECTED="$ROOT/build/verify-protected-state.sh"
builder_lines=()
for entry in "${BUILDER_ENTRIES[@]}"; do
    build_relative="${entry%%:*}"
    app_relative="${entry##*:}"
    builder_file="$BUILDER/$build_relative"
    if [[ ! -f "$builder_file" ]]; then
        REPORT+=("  ! builder ausente para $build_relative (se conserva el PIN actual)")
        continue
    fi
    # Un binario del builder solo puede acreditar el runtime instalado si ambos
    # contienen los mismos bytes de código. Se comparan sin firma: el bundle va
    # firmado y el builder no, pero el resto debe coincidir. Declarar un builder
    # que no corresponde produciría una release que dice proceder de un origen
    # que nunca la generó.
    if ! builder_norm="$(normalized "$builder_file")" \
        || ! bundle_norm="$(normalized "$WINE_ROOT/$app_relative")"; then
        REPORT+=("  ! no se pudo normalizar $build_relative")
        continue
    fi
    if [[ "$builder_norm" != "$bundle_norm" ]]; then
        REPORT+=("  ! $build_relative del builder NO corresponde al runtime instalado")
        REPORT+=("      se conserva su PIN actual; recompila e instala ese binario")
        continue
    fi
    actual="$(sha "$builder_file")"
    current="$(grep -oE "[0-9a-f]{64}:${build_relative//\//\\/}:" "$PROTECTED" 2>/dev/null \
        | head -1 | cut -d: -f1 || true)"
    record "builder $build_relative" "$current" "$actual"
    # Se guarda también la huella sin firma: es lo que permite acreditar el
    # runtime instalado cuando el árbol de compilación ya no existe.
    builder_lines+=("$actual  $builder_norm  $build_relative  $app_relative")
    if ! $CHECK_ONLY && [[ -n "$current" && "$current" != "$actual" ]]; then
        python3 - "$PROTECTED" "$current" "$actual" <<'PY'
import io, sys
source, old, new = sys.argv[1], sys.argv[2], sys.argv[3]
text = io.open(source, encoding="utf-8").read()
io.open(source, "w", encoding="utf-8").write(text.replace(old, new))
PY
    fi
done

if ! $CHECK_ONLY && (( ${#builder_lines[@]} > 0 )); then
    {
        printf '# Evidencia del builder sellado del runtime público.\n'
        printf '# Generado por build/refresh-release-pins.sh; no editar a mano.\n'
        printf '# sha256-builder  sha256-sin-firma  ruta-en-el-builder  ruta-en-el-runtime\n'
        printf '%s\n' "${builder_lines[@]}"
    } > "$EVIDENCE"
fi

printf 'PIN del runtime (%s)\n' "$([[ $CHECK_ONLY == true ]] && echo comprobación || echo actualización)"
printf 'bundle:  %s\n' "$BUNDLE"
printf 'builder: %s\n' "$BUILDER"
printf '%s\n' "${REPORT[@]}"

if $CHECK_ONLY; then
    (( changed == 0 )) || {
        printf '\nHay PIN desalineados con los artefactos reales.\n' >&2
        exit 1
    }
    printf '\nTodos los PIN coinciden con los artefactos reales.\n'
else
    printf '\nEvidencia escrita en %s\n' "${EVIDENCE#"$ROOT"/}"
fi
