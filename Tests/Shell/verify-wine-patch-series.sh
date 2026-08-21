#!/usr/bin/env bash
set -Eeuo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
# El tar oficial puede estar en la caché del operador o en la raíz del checkout.
# Se acepta cualquiera de los dos: su SHA-256 se verifica igual justo debajo, así
# que la procedencia queda acreditada sea cual sea la ruta.
DEFAULT_ARCHIVE="$HOME/Library/Caches/Regression/FOSS/crossover-sources-26.3.0.tar.gz"
[[ -f "$DEFAULT_ARCHIVE" ]] || DEFAULT_ARCHIVE="$ROOT/crossover-sources-26.3.0.tar.gz"
ARCHIVE="${1:-$DEFAULT_ARCHIVE}"
EXPECTED_SHA="ac99c8ca4b3848f3e81784135f023df266b61c2345726ea55a50b3e030dd6872"
WORK="$(mktemp -d "${TMPDIR:-/tmp}/regression-wine-patch-series.XXXXXX")"

cleanup() {
    [[ -n "$WORK" && "$WORK" == "${TMPDIR:-/tmp}"/regression-wine-patch-series.* ]] || return
    rm -rf -- "$WORK"
}
trap cleanup EXIT

fail() {
    printf 'ERROR: %s\n' "$*" >&2
    exit 1
}

[[ -f "$ARCHIVE" ]] || fail "no existe el tar FOSS local: $ARCHIVE"
ACTUAL_SHA="$(shasum -a 256 "$ARCHIVE" | awk '{print $1}')"
[[ "$ACTUAL_SHA" == "$EXPECTED_SHA" ]] \
    || fail "el tar FOSS no coincide con CrossOver 26.3.0 oficial"

tar -xzf "$ARCHIVE" -C "$WORK" sources/wine
SOURCE="$WORK/sources/wine"
REGRESSION_WINE_SOURCE="$SOURCE" "$ROOT/build/apply-wine-patches.sh"

# El segundo paso protege además la idempotencia del aplicador sobre el árbol
# ya extendido por los parches posteriores.
REGRESSION_WINE_SOURCE="$SOURCE" "$ROOT/build/apply-wine-patches.sh"

if find "$SOURCE" -type f \( -name '*.rej' -o -name '*.orig' \) -print -quit | grep -q .; then
    fail "la serie dejó rechazos o copias de una aplicación aproximada"
fi

if [[ "${REGRESSION_WINE_PATCH_SKIP_COMPILE:-0}" != "1" ]]; then
    BUILD="$WORK/build"
    mkdir -p "$BUILD"
    (
        cd "$BUILD"
        PATH="/opt/homebrew/opt/bison/bin:/opt/homebrew/opt/flex/bin:$PATH" \
        BISON=/opt/homebrew/opt/bison/bin/bison \
        CC=clang CXX=clang++ CFLAGS='-arch x86_64 -O0' CXXFLAGS='-arch x86_64 -O0' \
        OBJCFLAGS='-arch x86_64 -O0' LDFLAGS='-arch x86_64' \
        "$SOURCE/configure" -C --enable-archs=i386,x86_64 --without-mingw \
            --without-alsa --without-coreaudio --without-cups --without-dbus \
            --without-ffmpeg --without-fontconfig --without-freetype \
            --without-gettext --without-gnutls --without-gstreamer \
            --without-krb5 --without-netapi --without-opencl --without-opengl \
            --without-pcap --without-pcsclite --without-pulse --without-sane \
            --without-sdl --without-udev --without-usb --without-v4l2 \
            --without-vulkan --without-wayland --without-x \
            --build=x86_64-apple-darwin --host=x86_64-apple-darwin
        make -s -j"$(sysctl -n hw.activecpu)" dlls/ntdll/ntdll.so
        [[ -x dlls/ntdll/ntdll.so ]] \
            || fail "la compilación no produjo dlls/ntdll/ntdll.so"
        file dlls/ntdll/ntdll.so | grep -q 'Mach-O 64-bit.*x86_64' \
            || fail "ntdll.so no es un Mach-O x86_64"
    )
    printf 'Serie Wine reproducible: tar oficial, aplicación estricta, estructura y compilación válidas.\n'
else
    printf 'Serie Wine reproducible: tar oficial, aplicación estricta y estructura válidas (compilación omitida).\n'
fi
