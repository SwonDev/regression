#!/bin/bash
# Cadena TLS + freetype (x86_64 bajo Rosetta) — con guards por paso
source "$(dirname "$0")/toolchain-common.sh"

# ---------- GMP ----------
if [ ! -e "$PREFIX/lib/libgmp.10.dylib" ]; then
    step "GMP"
    cd "$WORK"; rm -rf gmp-build; mkdir gmp-build; cd gmp-build
    A "$SRC/gnutls/gmp/configure" $HOST --prefix="$PREFIX" --enable-shared --disable-static
    A make -j6
    A make install
else
    step "GMP (ya compilado, skip)"
fi

# ---------- Nettle (tarball oficial, el snapshot CX no trae configure) ----------
if [ ! -e "$PREFIX/lib/libnettle.8.dylib" ]; then
    step "Nettle 3.10"
    cd "$WORK"
    if [ ! -f nettle-3.10.tar.gz ]; then
        curl -L -o nettle-3.10.tar.gz https://ftp.gnu.org/gnu/nettle/nettle-3.10.tar.gz
    fi
    rm -rf nettle-3.10 nettle-build; tar xzf nettle-3.10.tar.gz; mkdir nettle-build; cd nettle-build
    A "$WORK/nettle-3.10/configure" $HOST --prefix="$PREFIX" --enable-shared --disable-static \
        --disable-documentation
    A make -j6
    A make install
else
    step "Nettle (ya compilado, skip)"
fi

# ---------- GnuTLS ----------
if [ ! -e "$PREFIX/lib/libgnutls.30.dylib" ]; then
    step "GnuTLS 3.8.3"
    cd "$WORK"; rm -rf gnutls-build; mkdir gnutls-build; cd gnutls-build
    A "$SRC/gnutls/gnutls/configure" $HOST --prefix="$PREFIX" \
        NETTLE_LIBS="-lnettle" NETTLE_CFLAGS="-I$PREFIX/include" \
        HOGWEED_LIBS="-lhogweed" HOGWEED_CFLAGS="-I$PREFIX/include" \
        GMP_LIBS="-lgmp" \
        --with-included-libtasn1 --with-included-unistring --disable-gost \
        --without-p11-kit --without-tpm2 --without-zlib --without-brotli --without-zstd \
        --disable-doc --disable-tests --disable-tools --disable-guile --disable-nls \
        --disable-libdane --disable-cxx \
        --enable-shared --disable-static
    A make -j6
    A make install
else
    step "GnuTLS (ya compilado, skip)"
fi

# ---------- FreeType ----------
if [ ! -e "$PREFIX/lib/libfreetype.6.dylib" ]; then
    step "FreeType (meson)"
    cd "$WORK"; rm -rf freetype-build
    A meson setup freetype-build "$SRC/freetype" \
        --cross-file "$WORK/x86_64-darwin.ini" \
        --prefix="$PREFIX" --buildtype=release --default-library=shared \
        -Dzlib=enabled -Dpng=disabled -Dbrotli=disabled -Dbzip2=disabled \
        -Dharfbuzz=disabled -Dtests=disabled
    A meson compile -C freetype-build -j6
    A meson install -C freetype-build
else
    step "FreeType (ya compilado, skip)"
fi

step "CADENA A COMPLETADA"
ls -la "$PREFIX/lib/" | grep -E "gnutls|nettle|gmp|freetype"
