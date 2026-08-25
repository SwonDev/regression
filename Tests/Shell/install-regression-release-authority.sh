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
    /usr/bin/grep -Fq 'REGRESSION_RELEASE_AUTHORITY_V2_BEGIN' "$script" \
        || fail "falta la autoridad compilada v2 en $script"
    /usr/bin/grep -Fq 'REGRESSION_RELEASE_AUTHORITY_V2_END' "$script" \
        || fail "la autoridad compilada v2 no está delimitada en $script"
    /usr/bin/grep -Fq 'da8ba98d99d157f981ef3a2472dc9d74c9ce4673ef126bdd61851b9dd21dedb3' \
        "$script" || fail "falta la autoridad Windows Media en $script"
    # Los hashes del runtime sellado cambian en cada release; congelarlos aquí convertía el
    # contrato en un test caducado tres versiones después. Lo invariante, y lo que se exige, es
    # que la autoridad ancle una entrada por cada binario de arranque.
    for runtime_path in \
        'bin/wine' \
        'bin/wineserver' \
        'lib/wine/x86_64-unix/wine' \
        'lib/wine/x86_64-unix/ntdll.so' \
        'share/wine/wine.inf' \
        'lib/wine/x86_64-windows/ntdll.dll' \
        'lib/wine/i386-windows/ntdll.dll'
    do
        /usr/bin/grep -Eq "[0-9a-f]{64} ${runtime_path}\$" "$script" \
            || fail "la autoridad del runtime sellado no ancla '$runtime_path' en $script"
    done
    ! /usr/bin/grep -Fq \
        '8fb847f4f71ae120609c963fc588d3ea77b0887f173858c2d462e424a2d8fd8e' \
        "$script" || fail "el PIN 1.11 con rutas GPTK legacy sigue autorizado en $script"
    for pre_sign_hash in \
        668a88221884f4e62f3d40bed4a125a45e2e745c1d56610f8e3a33273a219299 \
        173c4926f53d0551d85ee6efe48e641867230a27bda7fc6a226ac484012d13fb \
        48ae6acb327148f3d8f02afcc93d8f8e61ab333b1dec752918244e58828cf5c9 \
        ff2a734999bf918507c90de4e910a740b6c4da2e05d0d028733eff82fb0239f2 \
        f3ccf2a487d8999659a1e641b043b916487851c1540362a0a983cdf0fd0bb8cc
    do
        ! /usr/bin/grep -Fq "$pre_sign_hash" "$script" \
            || fail "un hash pre-firma del builder sigue autorizado en $script"
    done
    /usr/bin/grep -Fq 'REGRESSION_EXTERNAL_D3DMETAL_ROUTE_COUNT' "$script" \
        || fail "el contrato GPTK indexado no se verifica en $script"
    /usr/bin/grep -Fq 'REGRESSION_EXTERNAL_D3DMETAL_(EXECUTABLE|WINE_ROOT)' "$script" \
        || fail "la ruta GPTK genérica heredada no se rechaza en $script"
done
# La versión concreta la cierra Tests/Shell/release-version-coherence.sh contra los cinco sitios
# que deben coincidir. Aquí sólo se exige que el instalador la declare, para que no dependa de un
# número que caduca en cada release.
/usr/bin/grep -Eq '^VERSION="[0-9]+\.[0-9]+\.[0-9]+"$' "$INSTALLER" \
    || fail "el instalador no declara una versión de Regression"
/usr/bin/grep -Eq '^BUILD_NUMBER="[0-9]+"$' "$INSTALLER" \
    || fail "el instalador no declara un número de build"
/usr/bin/grep -Fq 'PATH="/usr/bin:/bin:/usr/sbin:/sbin"' "$INSTALLER" \
    || fail "el instalador público permite sustituir comandos de confianza mediante PATH"
installer_preamble="$WORK_DIR/installer-preamble.sh"
/usr/bin/sed -n '1,/^VERSION=/p' "$INSTALLER" > "$installer_preamble"
WINESERVERSOCKET="$WORK_DIR/hostile-wineserver-socket" \
    /bin/bash -c 'source "$1"; [[ -z "${WINESERVERSOCKET+x}" ]]' \
        regression-installer-preamble "$installer_preamble" \
    || fail "el instalador conserva WINESERVERSOCKET hostil antes del Wine canónico"

installer_authority="$WORK_DIR/installer-authority"
verifier_authority="$WORK_DIR/verifier-authority"
/usr/bin/sed -n \
    '/REGRESSION_RELEASE_AUTHORITY_V2_BEGIN/,/REGRESSION_RELEASE_AUTHORITY_V2_END/p' \
    "$INSTALLER" > "$installer_authority"
/usr/bin/sed -n \
    '/REGRESSION_RELEASE_AUTHORITY_V2_BEGIN/,/REGRESSION_RELEASE_AUTHORITY_V2_END/p' \
    "$VERIFIER" > "$verifier_authority"
/usr/bin/cmp -s "$installer_authority" "$verifier_authority" \
    || fail "instalador y verificador no comparten la misma autoridad compilada"
# shellcheck disable=SC1090
source "$installer_authority"
runtime_authority_accepts()
{
    local expected_hash="$1" expected_path="$2"
    release_runtime_authority_v2 \
        | /usr/bin/grep -Fxq "$expected_hash $expected_path"
}
# La autoridad es una lista cerrada: para cada ruta admite un hash y sólo uno. Se comprueba esa
# propiedad, no un valor concreto, que cambia de forma legítima en cada release.
authorized_ntdll="$(release_runtime_authority_v2 \
    | /usr/bin/awk '$2 == "lib/wine/x86_64-unix/ntdll.so" { print $1 }')"
[[ "$(printf '%s\n' "$authorized_ntdll" | /usr/bin/grep -cE '^[0-9a-f]{64}$')" == "1" ]] \
    || fail "la autoridad pública no ancla exactamente un ntdll.so post-firma"
runtime_authority_accepts "$authorized_ntdll" lib/wine/x86_64-unix/ntdll.so \
    || fail "ntdll.so post-firma no supera la autoridad pública"
if runtime_authority_accepts \
    f3ccf2a487d8999659a1e641b043b916487851c1540362a0a983cdf0fd0bb8cc \
    lib/wine/x86_64-unix/ntdll.so; then
    fail "un ntdll.so ajeno supera indebidamente la autoridad pública"
fi

HELPERS="$WORK_DIR/installer-authority-helpers.sh"
/usr/bin/sed -n \
    '/^authority_value()/,/^}/p; /^path_chain_is_physical()/,/^}/p; /^trusted_digest_from_github_release()/,/^}/p' \
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

for literal in \
    'install-apple-gptk-component' \
    '--component 3.0 --recover-existing' \
    '--source-component "$D3DMETAL_SOURCE"' \
    'Components/AppleGPTK/3.0'
do
    /usr/bin/grep -Fq -- "$literal" "$INSTALLER" \
        || fail "falta la puerta GPTK: $literal"
done
if /usr/bin/grep -Fq 'cp -cR "$D3DMETAL_SOURCE" "$GPTK_ROOT"' "$INSTALLER"; then
    fail "el actualizador no puede volver a incrustar GPTK dentro del bundle"
fi

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
mkdir -p "$fixture/Regression.app/Contents"
cat > "$fixture/Regression.app/Contents/Info.plist" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>CFBundleIdentifier</key><string>local.regression.launcher</string>
<key>CFBundleShortVersionString</key><string>$VERSION</string>
<key>CFBundleVersion</key><string>$BUILD</string>
</dict></plist>
EOF
chmod 644 "$fixture/Regression.app/Contents/Info.plist"
ln -s ../../outside "$fixture/Regression.app/escape"
asset="$WORK_DIR/$ASSET_NAME"
PATH="/usr/bin:/bin:/usr/sbin:/sbin" \
    /usr/bin/tar --uid 0 --gid 0 --uname root --gname wheel \
        -czf "$asset" -C "$fixture" Regression.app
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
mkdir -p "$laboratory_fixture/Regression.app/Contents"
cp "$fixture/Regression.app/Contents/Info.plist" \
    "$laboratory_fixture/Regression.app/Contents/Info.plist"
chmod 644 "$laboratory_fixture/Regression.app/Contents/Info.plist"
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
    /usr/bin/tar --uid 0 --gid 0 --uname root --gname wheel \
        -czf "$laboratory_asset" -C "$laboratory_fixture" Regression.app
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
