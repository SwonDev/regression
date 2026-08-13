#!/usr/bin/env bash
# Contrato de autoridad del release: el tar y su checksum no pueden avalarse mutuamente,
# los payloads sellados usan hashes compilados y ningún enlace puede escapar del bundle.
# shellcheck disable=SC2016
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
INSTALLER="$ROOT/Scripts/install_regression.sh"
VERIFIER="$ROOT/build/verify-release-asset.sh"
WORK_DIR="$(mktemp -d /private/tmp/regression-release-authority-test.XXXXXX)"

cleanup()
{
    find "$WORK_DIR" -depth -delete
}
trap cleanup EXIT

fail()
{
    printf 'FAIL: %s\n' "$*" >&2
    exit 1
}

expect_failure()
{
    local description="$1"
    local expected="$2"
    shift 2
    local output status

    set +e
    output="$("$@" 2>&1)"
    status=$?
    set -e
    [[ $status -ne 0 ]] || fail "$description debía fallar"
    /usr/bin/grep -Fq "$expected" <<< "$output" \
        || fail "$description falló sin el diagnóstico esperado: $output"
}

for script in "$INSTALLER" "$VERIFIER"; do
    /usr/bin/grep -Fq 'REGRESSION_RELEASE_AUTHORITY_V1_BEGIN' "$script" \
        || fail "falta la autoridad compilada v1 en $script"
    /usr/bin/grep -Fq 'REGRESSION_RELEASE_AUTHORITY_V1_END' "$script" \
        || fail "la autoridad compilada v1 no está delimitada en $script"
    /usr/bin/grep -Fq 'da8ba98d99d157f981ef3a2472dc9d74c9ce4673ef126bdd61851b9dd21dedb3' \
        "$script" || fail "falta la autoridad Windows Media en $script"
done
/usr/bin/grep -Fq 'PATH="/usr/bin:/bin:/usr/sbin:/sbin"' "$INSTALLER" \
    || fail "el instalador público permite sustituir comandos de confianza mediante PATH"

installer_authority="$WORK_DIR/installer-authority"
verifier_authority="$WORK_DIR/verifier-authority"
/usr/bin/sed -n \
    '/REGRESSION_RELEASE_AUTHORITY_V1_BEGIN/,/REGRESSION_RELEASE_AUTHORITY_V1_END/p' \
    "$INSTALLER" > "$installer_authority"
/usr/bin/sed -n \
    '/REGRESSION_RELEASE_AUTHORITY_V1_BEGIN/,/REGRESSION_RELEASE_AUTHORITY_V1_END/p' \
    "$VERIFIER" > "$verifier_authority"
/usr/bin/cmp -s "$installer_authority" "$verifier_authority" \
    || fail "instalador y verificador no comparten la misma autoridad compilada"

HELPERS="$WORK_DIR/installer-authority-helpers.sh"
/usr/bin/sed -n \
    '/^authority_value()/,/^}/p; /^path_chain_is_physical()/,/^}/p; /^trusted_digest_from_github_release()/,/^}/p; /^verify_gptk_3_receipt_authority()/,/^}/p' \
    "$INSTALLER" > "$HELPERS"
# shellcheck disable=SC1090
source "$HELPERS"

api_digest="bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb"
api_fixture="$WORK_DIR/github-release.json"
cat > "$api_fixture" <<EOF
{
  "tag_name": "v1.10.1",
  "draft": false,
  "prerelease": false,
  "assets": [{
    "name": "Regression-1.10.1-macos-arm64.tar.zst",
    "digest": "sha256:$api_digest",
    "browser_download_url": "https://github.com/SwonDev/regression/releases/download/v1.10.1/Regression-1.10.1-macos-arm64.tar.zst"
  }]
}
EOF
VERSION="1.10.1"
REPO="SwonDev/regression"
export VERSION REPO
[[ "$(trusted_digest_from_github_release "$api_fixture" \
    "Regression-1.10.1-macos-arm64.tar.zst")" == "$api_digest" ]] \
    || fail "la API oficial no se interpreta como autoridad por tag, URL, asset y digest"

receipt_root="$WORK_DIR/gptk-3.0"
receipt="$WORK_DIR/3.0-license-receipt"
mkdir -p "$receipt_root/Documentation"
printf 'licencia protegida\n' > "$receipt_root/Documentation/License.rtf"
license_hash="$(shasum -a 256 "$receipt_root/Documentation/License.rtf" | awk '{print $1}')"
cat > "$receipt" <<EOF
schema=1
version=3.0
source_kind=existing-protected-component
catalog_id=apple-gptk-protected-profiles
payload_fingerprint=fdc07beb364b2327896196e214996585fbcc1a10c71784d383218d2de9db57d7
license_sha256=$license_hash
confirmation=ACEPTO LA LICENCIA DE APPLE GPTK 3.0
confirmed_at=2026-08-13T12:00:00Z
EOF
chmod 600 "$receipt"
verify_gptk_3_receipt_authority "$receipt" "$receipt_root" \
    || fail "un recibo GPTK 3.0 exacto y privado debía validarse"
receipt_parent_outside="$WORK_DIR/receipt-parent-outside"
receipt_parent_link="$WORK_DIR/receipt-parent-link"
mkdir -p "$receipt_parent_outside"
ln -s "$receipt_parent_outside" "$receipt_parent_link"
cp "$receipt" "$receipt_parent_outside/receipt"
chmod 600 "$receipt_parent_outside/receipt"
if verify_gptk_3_receipt_authority "$receipt_parent_link/receipt" "$receipt_root"; then
    fail "un recibo bajo una cadena de symlinks no puede autorizar preservación"
fi
/usr/bin/sed -i '' 's/confirmation=.*/confirmation=aceptación inválida/' "$receipt"
if verify_gptk_3_receipt_authority "$receipt" "$receipt_root"; then
    fail "un recibo GPTK sin aceptación exacta no puede autorizar preservación"
fi

for literal in \
    'verify_gptk_3_payload_authority "$D3DMETAL_SOURCE"' \
    'verify_gptk_3_receipt_authority "$GPTK_3_RECEIPT" "$D3DMETAL_SOURCE"' \
    'GPTK_PRESERVED_GENERATION="3.0"'
do
    /usr/bin/grep -Fq "$literal" "$INSTALLER" \
        || fail "falta la puerta GPTK: $literal"
done

VERSION="$(/usr/bin/awk -F\" '$1 == "VERSION=" { print $2; exit }' "$INSTALLER")"
BUILD="$(/usr/bin/awk -F\" '$1 == "BUILD_NUMBER=" { print $2; exit }' "$INSTALLER")"
ASSET_NAME="$(/usr/bin/awk -F\" '$1 == "ASSET_NAME=" { print $2; exit }' "$INSTALLER")"
ASSET_NAME="${ASSET_NAME//'${VERSION}'/$VERSION}"
[[ -n "$VERSION" && -n "$BUILD" && -n "$ASSET_NAME" ]] \
    || fail "no se pudo leer la identidad compilada del instalador"
[[ "$ASSET_NAME" == "Regression-${VERSION}-macos-arm64.tar.gz" ]] \
    || fail "la release 1.11 debe usar gzip extraíble por macOS sin zstd externo"
if /usr/bin/grep -Eq '(^|[^[:alnum:]_])zstd([^[:alnum:]_]|$)' "$INSTALLER"; then
    fail "el instalador público no puede depender de zstd en un Mac limpio"
fi

fixture="$WORK_DIR/fixture"
mkdir -p "$fixture/Regression.app"
ln -s ../../outside "$fixture/Regression.app/escape"
asset="$WORK_DIR/$ASSET_NAME"
PATH="/usr/bin:/bin:/usr/sbin:/sbin" \
    /usr/bin/tar -czf "$asset" -C "$fixture" Regression.app
actual="$(shasum -a 256 "$asset" | awk '{print $1}')"
checksum="$WORK_DIR/$ASSET_NAME.sha256"
printf '%s  %s\n' "$actual" "$ASSET_NAME" > "$checksum"

trusted="$WORK_DIR/release-digest-v1"
cat > "$trusted" <<EOF
schema=regression-release-digest-v1
repository=SwonDev/regression
tag=v$VERSION
asset=$ASSET_NAME
sha256=$actual
EOF

expect_failure "enlace relativo escapando en el instalador" \
    "enlace simbólico escapa del bundle" \
    "$INSTALLER" --verify-release --yes --skip-switch2bridge-install \
        --asset-file "$asset" --checksum-file "$checksum" \
        --trusted-digest-file "$trusted"

expect_failure "enlace relativo escapando en el verificador" \
    "enlace simbólico escapa del bundle" \
    "$VERIFIER" "$asset" "$checksum" "$VERSION" "$BUILD"

laboratory_fixture="$WORK_DIR/laboratory-fixture"
mkdir -p "$laboratory_fixture/Regression.app/000-runtime"
printf 'copia de laboratorio\n' \
    > "$laboratory_fixture/Regression.app/000-runtime/d3d11.dll.bak-investigation"
# El backup aparece antes de un árbol suficientemente grande para reproducir el SIGPIPE que
# provoca `find | grep -q` bajo pipefail; los gates usan `find -print -quit` sin ese pipeline.
for index in $(jot 12000 1); do
    mkdir -p "$laboratory_fixture/Regression.app/runtime-$index"
    printf 'payload %s\n' "$index" \
        > "$laboratory_fixture/Regression.app/runtime-$index/payload-$index.bin"
done
laboratory_asset="$WORK_DIR/laboratory-$ASSET_NAME"
PATH="/usr/bin:/bin:/usr/sbin:/sbin" \
    /usr/bin/tar -czf "$laboratory_asset" -C "$laboratory_fixture" Regression.app
laboratory_actual="$(shasum -a 256 "$laboratory_asset" | awk '{print $1}')"
laboratory_checksum="$laboratory_asset.sha256"
printf '%s  %s\n' "$laboratory_actual" "$ASSET_NAME" > "$laboratory_checksum"
laboratory_trusted="$WORK_DIR/laboratory-release-digest-v1"
cat > "$laboratory_trusted" <<EOF
schema=regression-release-digest-v1
repository=SwonDev/regression
tag=v$VERSION
asset=$ASSET_NAME
sha256=$laboratory_actual
EOF
expect_failure "copia .bak-* en el instalador" \
    "El asset contiene copias de laboratorio" \
    "$INSTALLER" --verify-release --yes --skip-switch2bridge-install \
        --asset-file "$laboratory_asset" --checksum-file "$laboratory_checksum" \
        --trusted-digest-file "$laboratory_trusted"
expect_failure "copia .bak-* en el verificador" \
    "el asset contiene copias de laboratorio" \
    "$VERIFIER" "$laboratory_asset" "$laboratory_checksum" "$VERSION" "$BUILD"

spoofed="$WORK_DIR/spoofed-release-digest-v1"
cat > "$spoofed" <<EOF
schema=regression-release-digest-v1
repository=SwonDev/regression
tag=v$VERSION
asset=$ASSET_NAME
sha256=aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa
EOF
expect_failure "tar y checksum falsificados juntos" \
    "autoridad independiente" \
    "$INSTALLER" --verify-release --yes --skip-switch2bridge-install \
        --asset-file "$asset" --checksum-file "$checksum" \
        --trusted-digest-file "$spoofed"

printf 'PASS: autoridad externa, payload sellado, GPTK autorizado y enlaces confinados.\n'
