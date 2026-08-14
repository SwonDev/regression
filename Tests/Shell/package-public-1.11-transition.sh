#!/usr/bin/env bash
# Valida la procedencia sellada public-1.11 sin empaquetar ni tocar apps instaladas/de workspace.
# shellcheck disable=SC2016
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
PACKAGER="$ROOT/Scripts/package_release.sh"
MATERIALIZER="$ROOT/build/materialize-public-1.11-input.sh"
ASSET="$ROOT/build/release-1.11.0/Regression-1.11.0-macos-arm64.tar.gz"
EXPECTED_SHA256="47740fbf27e6e792e2f6c5bf0b08a8ca7344f0bd1241adb0ad0e72569c3baa7e"
SCRATCH="$(mktemp -d /private/tmp/regression-public-111-materializer-test.XXXXXX)"
REAL_WORK=""
TAMPER_WORK=""
SIDECAR_WORK=""
TRAVERSAL_WORK=""
ARCHIVE_WORK=""
SYMLINK_WORK=""
EXISTING_WORK=""

cleanup_path() {
    local target="$1"
    [[ -n "$target" && -d "$target" && ! -L "$target" ]] || return 0
    find "$target" -depth -delete
}
cleanup() {
    cleanup_path "$REAL_WORK"
    cleanup_path "$TAMPER_WORK"
    cleanup_path "$SIDECAR_WORK"
    cleanup_path "$TRAVERSAL_WORK"
    cleanup_path "$ARCHIVE_WORK"
    cleanup_path "$SYMLINK_WORK"
    cleanup_path "$EXISTING_WORK"
    cleanup_path "$SCRATCH"
}
trap cleanup EXIT

fail() { printf 'FAIL: %s\n' "$*" >&2; exit 1; }

expect_rejection() {
    local description="$1" expected="$2"
    shift 2
    local output
    if output="$("$@" 2>&1)"; then
        fail "se aceptó $description"
    fi
    [[ "$output" == *"$expected"* ]] \
        || fail "el rechazo de $description no fue explícito: $output"
}

make_release_work() {
    local work
    work="$(mktemp -d /private/tmp/regression-release.XXXXXX)"
    chmod 700 "$work"
    printf '%s\n' "$work"
}

# Positivo real: el mismo tar que alimenta la transición productiva se extrae y supera todos
# los PIN de bundle candidato. El hash raw se conserva antes y después de materializar.
[[ "$(shasum -a 256 "$ASSET" | awk '{print $1}')" == "$EXPECTED_SHA256" ]] \
    || fail "el asset real 1.11 no coincide con el PIN esperado por el test"
REAL_WORK="$(make_release_work)"
mkdir -m 700 "$REAL_WORK/stage"
REAL_DEST="$REAL_WORK/stage/Regression.app"
"$MATERIALIZER" "$REAL_DEST" >/dev/null
[[ -d "$REAL_DEST" && ! -L "$REAL_DEST" ]] \
    || fail "el materializador no produjo el bundle real"
REAL_SNAPSHOT="$REAL_WORK/source/Regression-1.11.0-macos-arm64.tar.gz"
[[ -f "$REAL_SNAPSHOT" && ! -L "$REAL_SNAPSHOT" \
    && "$(stat -f '%Lp' "$REAL_SNAPSHOT")" == "600" ]] \
    || fail "el asset no se inmovilizó en una instantánea privada 0600"
[[ "$(shasum -a 256 "$REAL_SNAPSHOT" | awk '{print $1}')" == "$EXPECTED_SHA256" ]] \
    || fail "la instantánea privada no conserva el asset autorizado"
[[ "$(shasum -a 256 "$ASSET" | awk '{print $1}')" == "$EXPECTED_SHA256" ]] \
    || fail "la materialización modificó el asset fuente"

for snapshot_contract in \
    'cp -c "$ASSET" "$SNAPSHOT_ASSET"' \
    'ACTUAL_SHA256="$(shasum -a 256 "$SNAPSHOT_ASSET"' \
    'tar -tf "$SNAPSHOT_ASSET"' \
    'tar --xattrs --no-mac-metadata -xf "$SNAPSHOT_ASSET"'
do
    grep -F "$snapshot_contract" "$MATERIALIZER" >/dev/null \
        || fail "falta el contrato de snapshot privado: $snapshot_contract"
done
for forbidden_source_read in \
    'shasum -a 256 "$ASSET"' \
    'tar -tf "$ASSET"' \
    'tar --xattrs --no-mac-metadata -xf "$ASSET"'
do
    if grep -F "$forbidden_source_read" "$MATERIALIZER" >/dev/null; then
        fail "el helper vuelve a leer el asset fuente tras crear el snapshot: $forbidden_source_read"
    fi
done

# Un tar alterado se rechaza por bytes raw antes de extraer. Las firmas internas no pueden
# autorizarlo: la autoridad está en el SHA-256 compilado del contenedor completo.
TAMPER_ROOT="$SCRATCH/tampered-root"
mkdir -p "$TAMPER_ROOT/build/release-1.11.0"
cp "$MATERIALIZER" "$TAMPER_ROOT/build/materialize-public-1.11-input.sh"
chmod 755 "$TAMPER_ROOT/build/materialize-public-1.11-input.sh"
cp -c "$ASSET" "$TAMPER_ROOT/build/release-1.11.0/Regression-1.11.0-macos-arm64.tar.gz"
cp "$ASSET.sha256" \
    "$TAMPER_ROOT/build/release-1.11.0/Regression-1.11.0-macos-arm64.tar.gz.sha256"
printf 'X' | dd of="$TAMPER_ROOT/build/release-1.11.0/Regression-1.11.0-macos-arm64.tar.gz" \
    bs=1 seek=0 conv=notrunc status=none
TAMPER_WORK="$(make_release_work)"
mkdir -m 700 "$TAMPER_WORK/stage"
expect_rejection "un asset alterado aunque sus payloads pudieran refirmarse" \
    "hash raw del asset público 1.11" \
    "$TAMPER_ROOT/build/materialize-public-1.11-input.sh" \
    "$TAMPER_WORK/stage/Regression.app"
[[ -z "$(find "$TAMPER_WORK/stage" -mindepth 1 -print -quit)" ]] \
    || fail "el asset alterado llegó a extraerse"

cp -c "$ASSET" "$TAMPER_ROOT/build/release-1.11.0/Regression-1.11.0-macos-arm64.tar.gz"
printf '%064d  Regression-1.11.0-macos-arm64.tar.gz\n' 0 \
    > "$TAMPER_ROOT/build/release-1.11.0/Regression-1.11.0-macos-arm64.tar.gz.sha256"
SIDECAR_WORK="$(make_release_work)"
mkdir -m 700 "$SIDECAR_WORK/stage"
expect_rejection "un sidecar manipulado" "sidecar público 1.11" \
    "$TAMPER_ROOT/build/materialize-public-1.11-input.sh" \
    "$SIDECAR_WORK/stage/Regression.app"

# Incluso un contenedor cuyo nuevo hash se compilase debe superar la puerta de rutas antes de
# extraer. Esta fixture focal fija su propio PIN solo para alcanzar y probar esa segunda barrera.
ARCHIVE_ROOT="$SCRATCH/archive-traversal-root"
mkdir -p "$ARCHIVE_ROOT/build/release-1.11.0" "$ARCHIVE_ROOT/payload"
printf 'escape\n' > "$ARCHIVE_ROOT/payload/file"
(
    cd "$ARCHIVE_ROOT/payload"
    tar -czf "$ARCHIVE_ROOT/build/release-1.11.0/Regression-1.11.0-macos-arm64.tar.gz" \
        -s ',^file$,../escape,' file
)
archive_hash="$(shasum -a 256 \
    "$ARCHIVE_ROOT/build/release-1.11.0/Regression-1.11.0-macos-arm64.tar.gz" | awk '{print $1}')"
printf '%s  Regression-1.11.0-macos-arm64.tar.gz\n' "$archive_hash" \
    > "$ARCHIVE_ROOT/build/release-1.11.0/Regression-1.11.0-macos-arm64.tar.gz.sha256"
cp "$MATERIALIZER" "$ARCHIVE_ROOT/build/materialize-public-1.11-input.sh"
/usr/bin/sed -i '' "s/$EXPECTED_SHA256/$archive_hash/" \
    "$ARCHIVE_ROOT/build/materialize-public-1.11-input.sh"
chmod 755 "$ARCHIVE_ROOT/build/materialize-public-1.11-input.sh"
ARCHIVE_WORK="$(make_release_work)"
mkdir -m 700 "$ARCHIVE_WORK/stage"
expect_rejection "un tar con traversal interno" "ruta fuera de Regression.app" \
    "$ARCHIVE_ROOT/build/materialize-public-1.11-input.sh" \
    "$ARCHIVE_WORK/stage/Regression.app"
[[ ! -e "$ARCHIVE_WORK/escape" ]] \
    || fail "el tar con traversal llegó a escribir fuera de staging"

# El confinamiento se decide sobre padres físicos, no por prefijos léxicos controlables.
TRAVERSAL_WORK="$(make_release_work)"
mkdir -m 700 "$TRAVERSAL_WORK/stage" "$TRAVERSAL_WORK/escape"
expect_rejection "un destino con traversal" "recorridos léxicos" \
    "$MATERIALIZER" "$TRAVERSAL_WORK/stage/../escape/Regression.app"

SYMLINK_WORK="$(make_release_work)"
mkdir -m 700 "$SYMLINK_WORK/real-stage"
ln -s "$SYMLINK_WORK/real-stage" "$SYMLINK_WORK/stage"
expect_rejection "un padre de staging simbólico" "directorio físico" \
    "$MATERIALIZER" "$SYMLINK_WORK/stage/Regression.app"

EXISTING_WORK="$(make_release_work)"
mkdir -m 700 "$EXISTING_WORK/stage" "$EXISTING_WORK/stage/Regression.app"
expect_rejection "un destino ya existente" "debe ser nuevo" \
    "$MATERIALIZER" "$EXISTING_WORK/stage/Regression.app"

# El modo public-1.11 no puede leer Regression.app del checkout ni /Applications: solo invoca
# el materializador sellado y copia su resultado temporal. La rama development conserva APP.
public_branch="$(awk '
    /if \[\[ "\$INPUT_STATE" == "public-1\.11" \]\]; then/ {inside=1; next}
    inside && /^else$/ {exit}
    inside {print}
' "$PACKAGER")"
[[ "$public_branch" == *'materialize-public-1.11-input.sh'* ]] \
    || fail "package_release no materializa el asset público sellado"
if [[ "$public_branch" == *'ditto '* ]]; then
    fail "package_release vuelve a copiar el input público después de validarlo"
fi
if [[ "$public_branch" == *'$APP'* || "$public_branch" == *'/Applications/Regression.app'* ]]; then
    fail "la rama public-1.11 todavía lee una app instalada o del workspace"
fi
if grep -Fq 'REGRESSION_RELEASE_PUBLIC_111_TRANSITION_CONTRACT_ONLY' "$PACKAGER"; then
    fail "package_release conserva el seam sustituible CONTRACT_ONLY"
fi
grep -F '"$ROOT/build/verify-protected-state.sh" --release-1.12-development-candidate' \
    "$PACKAGER" >/dev/null \
    || fail "el input de desarrollo perdió la autoridad 1.12"

printf 'PASS: el tar 1.11 sellado es la única procedencia pública y solo staging asciende a 1.12.\n'
