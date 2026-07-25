#!/bin/bash
# Cadena GLib + GStreamer (x86_64 bajo Rosetta) — con guards por paso
source "$(dirname "$0")/toolchain-common.sh"

# ---------- libffi ----------
if [ ! -e "$PREFIX/lib/libffi.8.dylib" ]; then
    step "libffi 3.4.6"
    cd "$WORK"
    if [ ! -f libffi-3.4.6.tar.gz ]; then
        curl -L -o libffi-3.4.6.tar.gz https://github.com/libffi/libffi/releases/download/v3.4.6/libffi-3.4.6.tar.gz
    fi
    rm -rf libffi-3.4.6 libffi-build; tar xzf libffi-3.4.6.tar.gz; mkdir libffi-build; cd libffi-build
    A "$WORK/libffi-3.4.6/configure" $HOST --prefix="$PREFIX" --enable-shared --disable-static --disable-docs
    A make -j6
    A make install
else
    step "libffi (ya compilado, skip)"
fi

# ---------- PCRE2 ----------
if [ ! -e "$PREFIX/lib/libpcre2-8.0.dylib" ]; then
    step "PCRE2 10.44"
    cd "$WORK"
    if [ ! -f pcre2-10.44.tar.bz2 ]; then
        curl -L -o pcre2-10.44.tar.bz2 https://github.com/PCRE2Project/pcre2/releases/download/pcre2-10.44/pcre2-10.44.tar.bz2
    fi
    rm -rf pcre2-10.44 pcre2-build; tar xjf pcre2-10.44.tar.bz2; mkdir pcre2-build; cd pcre2-build
    A "$WORK/pcre2-10.44/configure" $HOST --prefix="$PREFIX" --enable-shared --disable-static \
        --enable-jit --enable-pcre2-8 --disable-pcre2-16 --disable-pcre2-32
    A make -j6
    A make install
else
    step "PCRE2 (ya compilado, skip)"
fi

# ---------- GLib ----------
if [ ! -e "$PREFIX/lib/libglib-2.0.0.dylib" ]; then
    step "GLib 2.78 (meson)"
    cd "$WORK"; rm -rf glib-build
    A meson setup glib-build "$SRC/glib" \
        --cross-file "$WORK/x86_64-darwin.ini" \
        --prefix="$PREFIX" --buildtype=release --default-library=shared \
        -Dtests=false -Dnls=disabled -Dlibmount=disabled -Dlibelf=disabled \
        -Dselinux=disabled -Ddtrace=false -Dsystemtap=false -Dsysprof=disabled \
        -Dgtk_doc=false -Dman=false \
        -Dgio_module_dir="$PREFIX/lib/gio/modules"
    A meson compile -C glib-build -j6
    A meson install -C glib-build
else
    step "GLib (ya compilado, skip)"
fi

# ---------- GStreamer ----------
if [ ! -e "$PREFIX/lib/libgstreamer-1.0.0.dylib" ]; then
    step "GStreamer 1.24.4 (meson, monorepo)"
    cd "$WORK"; rm -rf gstreamer-build
    A meson setup gstreamer-build "$SRC/gstreamer" \
        --cross-file "$WORK/x86_64-darwin.ini" \
        --prefix="$PREFIX" --buildtype=release --default-library=shared \
        -Dexamples=disabled -Dtests=disabled \
        -Dintrospection=disabled -Dnls=disabled -Dorc=disabled \
        -Dlibav=disabled -Dugly=disabled -Dsharp=disabled -Drs=disabled \
        -Dpython=disabled -Ddevtools=disabled -Dges=disabled \
        -Drtsp_server=disabled -Dqt5=disabled -Dgpl=disabled \
        -Dbase=enabled -Dgood=enabled -Dbad=enabled \
        -Dgst-plugins-good:png=disabled -Dgst-plugins-base:pango=disabled \
        -Dgst-plugins-bad:closedcaption=disabled -Dgst-plugins-bad:analyticsoverlay=disabled \
        -Dgst-plugins-bad:ttml=disabled
    A meson compile -C gstreamer-build -j6
    A meson install -C gstreamer-build
else
    step "GStreamer (ya compilado, skip)"
fi

step "CADENA B COMPLETADA"
ls "$PREFIX/lib/" | grep -E "glib|gstreamer|ffi|pcre2" | head
