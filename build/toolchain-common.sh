#!/bin/bash
# Toolchain x86_64 (Rosetta) para Regression — paridad con CrossOver 26.3
set -Eeuo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SRC="$ROOT/sources-26.3.0"
PREFIX=$ROOT/toolchain/x86
WORK=$ROOT/build/toolchain
mkdir -p "$PREFIX" "$WORK" "$ROOT/build/logs"

export PATH="$PREFIX/bin:/opt/homebrew/opt/bison/bin:/opt/homebrew/opt/flex/bin:/opt/homebrew/bin:/usr/bin:/bin:/usr/sbin:/sbin"
export CFLAGS="-arch x86_64 -O2 -mmacosx-version-min=12.0"
export CXXFLAGS="$CFLAGS"
export OBJCFLAGS="$CFLAGS"
export LDFLAGS="-arch x86_64 -L$PREFIX/lib -Wl,-rpath,$PREFIX/lib"
export CPPFLAGS="-I$PREFIX/include"
export PKG_CONFIG_PATH="$PREFIX/lib/pkgconfig:$PREFIX/share/pkgconfig"
export PKG_CONFIG_LIBDIR="$PREFIX/lib/pkgconfig:$PREFIX/share/pkgconfig"
export PKG_CONFIG="pkg-config"

# build=host=x86_64 -> autotools NO lo trata como cross y ejecuta los
# conftest (corren bajo Rosetta transparentemente)
HOST="--build=x86_64-apple-darwin --host=x86_64-apple-darwin"

A() { "$@"; }

# Archivo cross para meson (host arm64 -> target x86_64, binarios ejecutables vía Rosetta)
cat > "$WORK/x86_64-darwin.ini" <<'EOF'
[binaries]
c = 'clang'
cpp = 'clang++'
objc = 'clang'
objcpp = 'clang++'
ar = 'ar'
strip = 'strip'
pkg-config = 'pkg-config'

[properties]
needs_exe_wrapper = false

[built-in options]
c_args = ['-arch', 'x86_64', '-mmacosx-version-min=12.0']
cpp_args = ['-arch', 'x86_64', '-mmacosx-version-min=12.0']
objc_args = ['-arch', 'x86_64', '-mmacosx-version-min=12.0']
c_link_args = ['-arch', 'x86_64']
cpp_link_args = ['-arch', 'x86_64']
objc_link_args = ['-arch', 'x86_64']

[host_machine]
system = 'darwin'
subsystem = 'macos'
kernel = 'xnu'
cpu_family = 'x86_64'
cpu = 'x86_64'
endian = 'little'
EOF

step() { echo ""; echo "==================== $1 ===================="; }
