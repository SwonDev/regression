#!/usr/bin/env bash
set -Eeuo pipefail

# Construye el componente LGPL opcional que aporta ASF/WMA2 a Wine GStreamer.
# Por defecto recompila todo desde las fuentes fijadas. Para ensamblar el A/B
# ya construido se pueden proporcionar los tres prefijos mediante el entorno.

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
GST_ROOT="${REGRESSION_GSTREAMER_SOURCE:-$ROOT/sources-26.3.0/gstreamer}"
WORK_ROOT="${REGRESSION_WINDOWS_MEDIA_WORK:-$ROOT/build/windows-media-work}"
OUTPUT_ROOT="${REGRESSION_WINDOWS_MEDIA_OUTPUT:-$ROOT/build/windows-media-component/1}"
FFMPEG_SOURCE="${REGRESSION_FFMPEG_SOURCE:-$WORK_ROOT/FFmpeg}"
FFMPEG_PREFIX="${REGRESSION_FFMPEG_PREFIX:-$WORK_ROOT/ffmpeg-prefix}"
ASF_PREFIX="${REGRESSION_ASF_PREFIX:-$WORK_ROOT/asf-prefix}"
LIBAV_PREFIX="${REGRESSION_GST_LIBAV_PREFIX:-$WORK_ROOT/gst-libav-prefix}"
WINE_GSTREAMER="$ROOT/Regression.app/Contents/SharedSupport/wine-root/lib/wine/x86_64-unix/winegstreamer.so"
FFMPEG_COMMIT="f1e3a2bf7a2f2cde936d1ed97f09a26853d20125"
GST_VERSION="1.24.4"
TOOLCHAIN_PKGCONFIG="$ROOT/toolchain/x86/lib/pkgconfig:$ROOT/toolchain/x86/share/pkgconfig"
CROSS_FILE="$ROOT/build/toolchain/x86_64-darwin.ini"

fail() { printf 'ERROR: %s\n' "$*" >&2; exit 1; }

for command in clang git meson ninja install_name_tool otool codesign shasum; do
    command -v "$command" >/dev/null 2>&1 || fail "falta la herramienta $command"
done
[[ -f "$CROSS_FILE" ]] || fail "falta el cross-file x86_64 de Regression"
[[ -d "$GST_ROOT/subprojects/gst-plugins-ugly" ]] || fail "faltan las fuentes GStreamer"
[[ -f "$WINE_GSTREAMER" ]] || fail "falta winegstreamer.so en el runtime canónico"

if [[ ! -f "$FFMPEG_PREFIX/lib/libavcodec.60.dylib" ]]; then
    mkdir -p "$WORK_ROOT"
    if [[ ! -d "$FFMPEG_SOURCE/.git" ]]; then
        git clone --filter=blob:none --branch n6.1.6 --depth 1 \
            https://github.com/FFmpeg/FFmpeg.git "$FFMPEG_SOURCE"
    fi
    [[ "$(git -C "$FFMPEG_SOURCE" rev-parse HEAD)" == "$FFMPEG_COMMIT" ]] \
        || fail "FFmpeg no coincide con el commit fijado $FFMPEG_COMMIT"
    rm -rf "$WORK_ROOT/ffmpeg-build" "$FFMPEG_PREFIX"
    mkdir -p "$WORK_ROOT/ffmpeg-build"
    (
        cd "$WORK_ROOT/ffmpeg-build"
        "$FFMPEG_SOURCE/configure" \
            --prefix="$FFMPEG_PREFIX" \
            --arch=x86_64 --target-os=darwin --cc=clang --cxx=clang++ \
            --enable-shared --disable-static --disable-programs --disable-doc \
            --disable-debug --disable-autodetect --disable-x86asm \
            --disable-gpl --disable-nonfree \
            --enable-avcodec --enable-avformat --enable-avfilter --enable-avutil \
            --enable-swresample --enable-swscale \
            --extra-cflags='-arch x86_64 -O2 -mmacosx-version-min=12.0' \
            --extra-cxxflags='-arch x86_64 -O2 -mmacosx-version-min=12.0' \
            --extra-ldflags='-arch x86_64 -mmacosx-version-min=12.0 -Wl,-rpath,@loader_path'
        make -j"$(sysctl -n hw.logicalcpu)"
        make install
    )
fi

if [[ ! -f "$ASF_PREFIX/lib/gstreamer-1.0/libgstasf.dylib" ]]; then
    rm -rf "$WORK_ROOT/gst-asf-build" "$ASF_PREFIX"
    PKG_CONFIG_PATH="$TOOLCHAIN_PKGCONFIG" \
    PKG_CONFIG_LIBDIR="$TOOLCHAIN_PKGCONFIG" \
    meson setup "$WORK_ROOT/gst-asf-build" \
        "$GST_ROOT/subprojects/gst-plugins-ugly" \
        --cross-file "$CROSS_FILE" --buildtype release --default-library shared \
        --prefix "$ASF_PREFIX" -Dauto_features=disabled -Dasfdemux=enabled \
        -Dtests=disabled -Ddoc=disabled -Dnls=disabled -Dorc=disabled -Dgpl=disabled
    meson compile -C "$WORK_ROOT/gst-asf-build"
    meson install -C "$WORK_ROOT/gst-asf-build"
fi

if [[ ! -f "$LIBAV_PREFIX/lib/gstreamer-1.0/libgstlibav.dylib" ]]; then
    rm -rf "$WORK_ROOT/gst-libav-build" "$LIBAV_PREFIX"
    PKG_CONFIG_PATH="$FFMPEG_PREFIX/lib/pkgconfig:$TOOLCHAIN_PKGCONFIG" \
    PKG_CONFIG_LIBDIR="$FFMPEG_PREFIX/lib/pkgconfig:$TOOLCHAIN_PKGCONFIG" \
    meson setup "$WORK_ROOT/gst-libav-build" \
        "$GST_ROOT/subprojects/gst-libav" \
        --cross-file "$CROSS_FILE" --buildtype release --default-library shared \
        --prefix "$LIBAV_PREFIX" -Dauto_features=disabled -Dtests=disabled \
        -Ddoc=disabled -Dpackage-name='Regression Windows Media Component' \
        -Dpackage-origin='https://github.com/adrianpereradelgado/Regression'
    meson compile -C "$WORK_ROOT/gst-libav-build"
    meson install -C "$WORK_ROOT/gst-libav-build"
fi

rm -rf "$OUTPUT_ROOT"
mkdir -p "$OUTPUT_ROOT/gstreamer-1.0" "$OUTPUT_ROOT/lib" "$OUTPUT_ROOT/Documentation"
install -m 755 "$ASF_PREFIX/lib/gstreamer-1.0/libgstasf.dylib" \
    "$OUTPUT_ROOT/gstreamer-1.0/libgstasf.dylib"
install -m 755 "$LIBAV_PREFIX/lib/gstreamer-1.0/libgstlibav.dylib" \
    "$OUTPUT_ROOT/gstreamer-1.0/libgstlibav.dylib"

for library in \
    libavfilter.9.dylib libavformat.60.dylib libavcodec.60.dylib \
    libavutil.58.dylib libswresample.4.dylib libswscale.7.dylib
do
    install -m 755 "$FFMPEG_PREFIX/lib/$library" "$OUTPUT_ROOT/lib/$library"
done

install -m 644 "$GST_ROOT/subprojects/gst-plugins-ugly/COPYING" \
    "$OUTPUT_ROOT/Documentation/GStreamer-plugins-ugly-LGPL-2.1.txt"
install -m 644 "$GST_ROOT/subprojects/gst-libav/COPYING" \
    "$OUTPUT_ROOT/Documentation/GStreamer-gst-libav-LGPL-2.1.txt"
install -m 644 "$FFMPEG_SOURCE/COPYING.LGPLv2.1" \
    "$OUTPUT_ROOT/Documentation/FFmpeg-LGPL-2.1.txt"
install -m 644 "$FFMPEG_SOURCE/LICENSE.md" \
    "$OUTPUT_ROOT/Documentation/FFmpeg-LICENSE.md"

for plugin in "$OUTPUT_ROOT/gstreamer-1.0/"*.dylib; do
    while IFS= read -r dependency; do
        case "$dependency" in
            /usr/lib/*|/System/Library/*) continue ;;
        esac
        basename="${dependency##*/}"
        [[ "$basename" == "${plugin##*/}" ]] && continue
        if [[ -f "$OUTPUT_ROOT/lib/$basename" ]]; then
            replacement="@loader_path/../lib/$basename"
        else
            # El bundle de desarrollo de Wine conserva los install names de su
            # toolchain, mientras que package_release.sh los relocaliza dentro
            # del asset público. Usar exactamente el mismo install name que
            # winegstreamer.so evita que dyld cargue dos copias de GStreamer.
            replacement="$(otool -L "$WINE_GSTREAMER" | tail -n +2 \
                | sed -E 's/^[[:space:]]*(.*) \(compatibility version.*/\1/' \
                | awk -v name="$basename" -F/ '$NF == name { print; exit }')"
            if [[ -z "$replacement" && -f "$ROOT/toolchain/x86/lib/$basename" ]]; then
                replacement="$ROOT/toolchain/x86/lib/$basename"
            fi
            [[ -n "$replacement" ]] \
                || fail "el runtime GStreamer no aporta la dependencia $basename"
        fi
        [[ "$dependency" == "$replacement" ]] \
            || install_name_tool -change "$dependency" "$replacement" "$plugin"
    done < <(otool -L "$plugin" | tail -n +2 | sed -E 's/^[[:space:]]*(.*) \(compatibility version.*/\1/')
    current_id="$(otool -D "$plugin" 2>/dev/null | tail -n +2 | head -1 || true)"
    [[ "$current_id" != /* ]] || install_name_tool -id "@rpath/${current_id##*/}" "$plugin"
    while IFS= read -r rpath; do
        [[ -n "$rpath" ]] && install_name_tool -delete_rpath "$rpath" "$plugin"
    done < <(otool -l "$plugin" | awk '/LC_RPATH/{seen=1; next} seen && /path /{print $2; seen=0}')
done

for library in "$OUTPUT_ROOT/lib/"*.dylib; do
    while IFS= read -r dependency; do
        [[ "$dependency" == /* ]] || continue
        case "$dependency" in
            /usr/lib/*|/System/Library/*) continue ;;
        esac
        basename="${dependency##*/}"
        [[ -f "$OUTPUT_ROOT/lib/$basename" ]] \
            || fail "dependencia FFmpeg no incluida: $library -> $dependency"
        install_name_tool -change "$dependency" "@loader_path/$basename" "$library"
    done < <(otool -L "$library" | tail -n +2 | sed -E 's/^[[:space:]]*(.*) \(compatibility version.*/\1/')
    current_id="$(otool -D "$library" 2>/dev/null | tail -n +2 | head -1 || true)"
    [[ "$current_id" != /* ]] || install_name_tool -id "@rpath/${current_id##*/}" "$library"
done

# FFmpeg expone su configuración de build mediante avcodec_configuration().
# Neutralizar la raíz local antes de firmar conserva esa información útil sin
# filtrar el checkout del constructor ni hacer el componente no reproducible.
sanitize_literal()
{
    local source="$1"
    local neutral="$2"
    local padding='' replacement file

    [[ -n "$source" && ${#neutral} -le ${#source} ]] || return 0
    while [[ ${#padding} -lt $((${#source} - ${#neutral})) ]]; do padding="${padding}_"; done
    replacement="${neutral}${padding}"
    while IFS= read -r -d '' file; do
        FROM_LITERAL="$source" TO_LITERAL="$replacement" \
            /usr/bin/perl -0pi -e 's/\Q$ENV{FROM_LITERAL}\E/$ENV{TO_LITERAL}/g' "$file"
    done < <(rg -a -F -l -0 "$source" "$OUTPUT_ROOT" || true)
}
sanitize_literal "$FFMPEG_PREFIX" '/opt/regression/ffmpeg'
sanitize_literal "$ASF_PREFIX" '/opt/regression/asf'
sanitize_literal "$LIBAV_PREFIX" '/opt/regression/gst-libav'
sanitize_literal "$FFMPEG_SOURCE" '/opt/regression/ffmpeg-src'

# No se neutraliza ROOT en los dos plugins: sus install names GStreamer deben
# coincidir byte a byte con los de winegstreamer.so en el bundle de desarrollo.
# El empaquetador público relocaliza ambos conjuntos a @rpath dentro del asset.

for binary in "$OUTPUT_ROOT/gstreamer-1.0/"*.dylib "$OUTPUT_ROOT/lib/"*.dylib; do
    [[ "$(lipo -archs "$binary")" == "x86_64" ]] || fail "$binary no es x86_64 exacto"
    codesign --force --sign - "$binary"
done

/usr/bin/printf '%s\n' \
    'component=windows-media-gstreamer' \
    'component_version=1' \
    "gstreamer_version=$GST_VERSION" \
    'ffmpeg_tag=n6.1.6' \
    "ffmpeg_commit=$FFMPEG_COMMIT" \
    'ffmpeg_license=LGPL-2.1-or-later' \
    'ffmpeg_gpl=disabled' \
    'ffmpeg_nonfree=disabled' \
    'architectures=x86_64' > "$OUTPUT_ROOT/BUILD.txt"
(
    cd "$OUTPUT_ROOT"
    find . -type f ! -name manifest.sha256 -print0 | LC_ALL=C sort -z \
        | xargs -0 shasum -a 256 > manifest.sha256
    shasum -a 256 -c manifest.sha256
)
printf 'Componente Windows Media construido en %s\n' "$OUTPUT_ROOT"
