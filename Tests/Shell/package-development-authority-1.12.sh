#!/usr/bin/env bash
# El candidato de empaquetado 1.12 no puede heredar los hashes 1.11 ni aceptar un
# builder/runtime/autorreparación distintos. Usa un bundle efímero: nunca toca /Applications.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
VERIFIER="$ROOT/build/verify-protected-state.sh"
RELEASE_PACKAGER="$ROOT/Scripts/package_release.sh"
NATIVE_PACKAGER="$ROOT/Scripts/package_regression.sh"
RUNTIME_SOURCE="$ROOT/build/release-1.12.0/wine64-public"
MEDIA_SOURCE="$ROOT/build/windows-media-component/1"
SCRATCH="$(mktemp -d /private/tmp/regression-package-development-authority.XXXXXX)"

cleanup() {
    find "$SCRATCH" -mindepth 1 -depth -delete
    rmdir "$SCRATCH"
}
trap cleanup EXIT

fail() {
    printf 'FAIL: %s\n' "$*" >&2
    exit 1
}

expect_failure() {
    local description="$1" expected="$2"
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

for source in \
    "$RUNTIME_SOURCE/tools/wine/wine" \
    "$RUNTIME_SOURCE/server/wineserver" \
    "$RUNTIME_SOURCE/loader/wine" \
    "$RUNTIME_SOURCE/dlls/ntdll/ntdll.so" \
    "$MEDIA_SOURCE/manifest.sha256"
do
    [[ -f "$source" ]] || fail "falta el insumo de fixture 1.12: $source"
done

export PATH="/usr/bin:/bin:/usr/sbin:/sbin"

make_fixture() {
    local app="$1" builder="$2"
    mkdir -p \
        "$app/Contents/MacOS" \
        "$app/Contents/SharedSupport/bin" \
        "$app/Contents/SharedSupport/components/windows-media" \
        "$app/Contents/SharedSupport/wine-root/bin" \
        "$app/Contents/SharedSupport/wine-root/lib/wine/x86_64-unix" \
        "$builder/tools/wine" \
        "$builder/server" \
        "$builder/loader" \
        "$builder/dlls/ntdll"

    cat > "$app/Contents/Info.plist" <<'EOF'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict><key>CFBundleIdentifier</key><string>com.swondev.regression.fixture</string><key>CFBundleExecutable</key><string>Regression</string></dict></plist>
EOF

    install -m 755 "$ROOT/Scripts/regression-engine.sh" \
        "$app/Contents/MacOS/regression-engine"
    install -m 755 "$ROOT/Scripts/install_apple_gptk_component.sh" \
        "$app/Contents/SharedSupport/bin/install-apple-gptk-component"
    install -m 755 "$ROOT/Scripts/install_windows_media_component.sh" \
        "$app/Contents/SharedSupport/bin/install-windows-media-component"
    ditto "$MEDIA_SOURCE" "$app/Contents/SharedSupport/components/windows-media/1"

    install -m 755 "$RUNTIME_SOURCE/tools/wine/wine" \
        "$builder/tools/wine/wine"
    install -m 755 "$RUNTIME_SOURCE/server/wineserver" \
        "$builder/server/wineserver"
    install -m 755 "$RUNTIME_SOURCE/loader/wine" \
        "$builder/loader/wine"
    install -m 755 "$RUNTIME_SOURCE/dlls/ntdll/ntdll.so" \
        "$builder/dlls/ntdll/ntdll.so"

    install -m 755 "$builder/tools/wine/wine" \
        "$app/Contents/SharedSupport/wine-root/bin/wine"
    install -m 755 "$builder/server/wineserver" \
        "$app/Contents/SharedSupport/wine-root/bin/wineserver"
    install -m 755 "$builder/loader/wine" \
        "$app/Contents/SharedSupport/wine-root/lib/wine/x86_64-unix/wine"
    install -m 755 "$builder/dlls/ntdll/ntdll.so" \
        "$app/Contents/SharedSupport/wine-root/lib/wine/x86_64-unix/ntdll.so"

    # La prueba usa la misma clase de firma que el empaquetador cuando no hay una
    # identidad Apple Development disponible. Así comprobamos la normalización de
    # LC_CODE_SIGNATURE en un Mach-O realmente firmado, no una simulación.
    for signed_runtime in \
        "$app/Contents/SharedSupport/wine-root/bin/wine" \
        "$app/Contents/SharedSupport/wine-root/bin/wineserver" \
        "$app/Contents/SharedSupport/wine-root/lib/wine/x86_64-unix/wine" \
        "$app/Contents/SharedSupport/wine-root/lib/wine/x86_64-unix/ntdll.so"
    do
        codesign --force --sign - "$signed_runtime" >/dev/null
    done
    codesign --force --deep --sign - "$app" >/dev/null
}

run_candidate_gate() {
    local app="$1" builder="$2"
    REGRESSION_APP_PATH="$app" \
        REGRESSION_1_12_DEVELOPMENT_RUNTIME_BUILD="$builder" \
        "$VERIFIER" --release-1.12-development-candidate
}

APP="$SCRATCH/Regression.app"
BUILDER="$SCRATCH/wine64-public"
make_fixture "$APP" "$BUILDER"
run_candidate_gate "$APP" "$BUILDER" >/dev/null

STALE_ENGINE_APP="$SCRATCH/stale-engine.app"
STALE_ENGINE_BUILDER="$SCRATCH/stale-engine-builder"
make_fixture "$STALE_ENGINE_APP" "$STALE_ENGINE_BUILDER"
printf 'stale engine\n' > "$STALE_ENGINE_APP/Contents/MacOS/regression-engine"
expect_failure "un motor 1.11 o manipulado" \
    'cambió el recurso protegido: Contents/MacOS/regression-engine' \
    run_candidate_gate "$STALE_ENGINE_APP" "$STALE_ENGINE_BUILDER"

STALE_MEDIA_APP="$SCRATCH/stale-media.app"
STALE_MEDIA_BUILDER="$SCRATCH/stale-media-builder"
make_fixture "$STALE_MEDIA_APP" "$STALE_MEDIA_BUILDER"
printf 'stale media installer\n' \
    > "$STALE_MEDIA_APP/Contents/SharedSupport/bin/install-windows-media-component"
expect_failure "un instalador Windows Media antiguo o manipulado" \
    'cambió el recurso protegido: Contents/SharedSupport/bin/install-windows-media-component' \
    run_candidate_gate "$STALE_MEDIA_APP" "$STALE_MEDIA_BUILDER"

STALE_RUNTIME_APP="$SCRATCH/stale-runtime.app"
STALE_RUNTIME_BUILDER="$SCRATCH/stale-runtime-builder"
make_fixture "$STALE_RUNTIME_APP" "$STALE_RUNTIME_BUILDER"
install -m 755 "$STALE_RUNTIME_BUILDER/loader/wine" \
    "$STALE_RUNTIME_APP/Contents/SharedSupport/wine-root/lib/wine/x86_64-unix/ntdll.so"
codesign --force --sign - \
    "$STALE_RUNTIME_APP/Contents/SharedSupport/wine-root/lib/wine/x86_64-unix/ntdll.so" >/dev/null
codesign --force --deep --sign - "$STALE_RUNTIME_APP" >/dev/null
expect_failure "un ntdll de runtime no autorizado" \
    'el runtime firmado no coincide con el builder 1.12: lib/wine/x86_64-unix/ntdll.so' \
    run_candidate_gate "$STALE_RUNTIME_APP" "$STALE_RUNTIME_BUILDER"

STALE_BUILDER_APP="$SCRATCH/stale-builder.app"
STALE_BUILDER="$SCRATCH/stale-builder"
make_fixture "$STALE_BUILDER_APP" "$STALE_BUILDER"
install -m 755 "$ROOT/Scripts/regression-engine.sh" "$STALE_BUILDER/server/wineserver"
expect_failure "un builder 1.12 sustituido" \
    'cambió el binario sellado del builder 1.12: server/wineserver' \
    run_candidate_gate "$STALE_BUILDER_APP" "$STALE_BUILDER"

expect_failure "la autoridad histórica 1.11 no se relaja" \
    'cambió el recurso protegido: Contents/MacOS/regression-engine' \
    env REGRESSION_APP_PATH="$APP" "$VERIFIER" --release-1.11-development-candidate

/usr/bin/grep -Fq -- '--release-1.12-development-candidate' "$NATIVE_PACKAGER" \
    || fail "package_regression no solicita la autoridad 1.12"
/usr/bin/grep -Fq -- '--release-1.12-development-candidate' "$RELEASE_PACKAGER" \
    || fail "package_release no solicita la autoridad 1.12"
/usr/bin/grep -Fq 'verify_protected_state release-1.12-development-candidate' "$NATIVE_PACKAGER" \
    || fail "el gate final de package_regression no usa la autoridad 1.12"
for copy_contract in \
    'install_runtime_1_12_file tools/wine/wine bin/wine' \
    'install_runtime_1_12_file server/wineserver bin/wineserver' \
    'install_runtime_1_12_file loader/wine lib/wine/x86_64-unix/wine' \
    'install_runtime_1_12_file dlls/ntdll/ntdll.so lib/wine/x86_64-unix/ntdll.so' \
    'codesign --force --options runtime --sign'
do
    /usr/bin/grep -Fq "$copy_contract" "$NATIVE_PACKAGER" \
        || fail "package_regression no conserva el contrato de conjunto 1.12: $copy_contract"
done
if /usr/bin/grep -Fq 'CANDIDATE_NTDLL=' "$NATIVE_PACKAGER"; then
    fail "package_regression todavía permite sustituir ntdll de forma aislada"
fi

# Esta ruta ejercita el contrato real del empaquetador sin crear stage, asset ni instalación.
REGRESSION_RELEASE_CONTRACT_ONLY=1 "$RELEASE_PACKAGER" >/dev/null

printf 'PASS: autoridad de packaging 1.12 fija motor, Windows Media, builder y runtime; 1.11 sigue histórico.\n'
