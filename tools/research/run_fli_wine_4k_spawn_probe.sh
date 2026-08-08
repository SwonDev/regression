#!/usr/bin/env bash

set -euo pipefail

# Reproduce únicamente el relanzamiento arm64 de Wine en modo de páginas de
# 4 KiB observado en las fuentes suministradas de CrossOver Preview. No ejecuta
# Wine, FEX, Proton, Steam, juegos ni EAC y nunca solicita la capacidad
# restringida de Apple.

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
SOURCE="$ROOT/tools/research/fli_wine_4k_spawn_probe.c"
PUBLIC_ENTITLEMENTS="$ROOT/tools/research/fli_wine_host_public.entitlements"
APP_INFO_PLIST="$ROOT/tools/research/fli_wine_4k_spawn_probe.Info.plist"
OUTPUT_DIRECTORY=""

usage() {
  echo "Uso: tools/research/run_fli_wine_4k_spawn_probe.sh --output-dir RUTA_PRIVADA_NUEVA"
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --output-dir)
      [[ $# -ge 2 ]] || { usage >&2; exit 64; }
      OUTPUT_DIRECTORY="$2"
      shift 2
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      usage >&2
      exit 64
      ;;
  esac
done

[[ -f "$SOURCE" && ! -L "$SOURCE" ]] || {
  echo "ERROR: falta la fuente regular de la sonda de páginas de 4 KiB." >&2
  exit 66
}
[[ -f "$PUBLIC_ENTITLEMENTS" && ! -L "$PUBLIC_ENTITLEMENTS" ]] || {
  echo "ERROR: faltan las capacidades públicas reproducibles." >&2
  exit 66
}
[[ -f "$APP_INFO_PLIST" && ! -L "$APP_INFO_PLIST" ]] || {
  echo "ERROR: falta el Info.plist reproducible de la variante app." >&2
  exit 66
}
[[ -n "$OUTPUT_DIRECTORY" && ! -e "$OUTPUT_DIRECTORY" && ! -L "$OUTPUT_DIRECTORY" ]] || {
  echo "ERROR: --output-dir debe ser una ruta privada nueva." >&2
  exit 66
}

IDENTITY="${REGRESSION_CODESIGN_IDENTITY:-}"
if [[ -z "$IDENTITY" ]]; then
  IDENTITY="$(security find-identity -v -p codesigning 2>/dev/null \
    | awk '/\"Apple Development:/ { print $2; exit }')"
fi
[[ -n "$IDENTITY" && "$IDENTITY" != "-" ]] || {
  echo "ERROR: la A/B requiere una identidad Apple Development estable." >&2
  exit 69
}

BUILD_DIRECTORY="$(mktemp -d /private/tmp/regression-fli-wine-4k-spawn.XXXXXX)"
cleanup() {
  case "$BUILD_DIRECTORY" in
    /private/tmp/regression-fli-wine-4k-spawn.*)
      rm -rf -- "$BUILD_DIRECTORY"
      ;;
  esac
}
trap cleanup EXIT

BASE_PROBE="$BUILD_DIRECTORY/fli-wine-4k-spawn-linker"
/usr/bin/clang \
  -std=c17 \
  -arch arm64 \
  -mmacosx-version-min=26.0 \
  -O2 \
  -Wall \
  -Wextra \
  -Werror \
  "$SOURCE" \
  -o "$BASE_PROBE"

cp -p "$BASE_PROBE" "$BUILD_DIRECTORY/fli-wine-4k-spawn-development"
cp -p "$BASE_PROBE" "$BUILD_DIRECTORY/fli-wine-4k-spawn-public-jit"
APP_BUNDLE="$BUILD_DIRECTORY/fli-wine-4k-spawn-public-jit.app"
install -d -m 0755 "$APP_BUNDLE/Contents/MacOS"
install -m 0644 "$APP_INFO_PLIST" "$APP_BUNDLE/Contents/Info.plist"
install -m 0755 "$BASE_PROBE" \
  "$APP_BUNDLE/Contents/MacOS/fli-wine-4k-spawn-probe"

codesign --force --sign "$IDENTITY" --options runtime \
  "$BUILD_DIRECTORY/fli-wine-4k-spawn-development" >/dev/null
codesign --force --sign "$IDENTITY" --options runtime \
  --entitlements "$PUBLIC_ENTITLEMENTS" \
  "$BUILD_DIRECTORY/fli-wine-4k-spawn-public-jit" >/dev/null
codesign --force --sign "$IDENTITY" --options runtime \
  --entitlements "$PUBLIC_ENTITLEMENTS" \
  "$APP_BUNDLE" >/dev/null

umask 077
install -d -m 0700 "$OUTPUT_DIRECTORY"

run_variant() {
  local name="$1"
  local executable="$2"
  local status_file="$OUTPUT_DIRECTORY/$name.status"
  local stdout_file="$OUTPUT_DIRECTORY/$name.stdout.jsonl"
  local stderr_file="$OUTPUT_DIRECTORY/$name.stderr.jsonl"

  codesign --verify --strict "$executable"
  codesign -d --verbose=4 "$executable" \
    >"$OUTPUT_DIRECTORY/$name.signature.txt" 2>&1 || true
  codesign -d --entitlements :- "$executable" \
    >"$OUTPUT_DIRECTORY/$name.entitlements.plist" 2>&1 || true

  set +e
  "$executable" >"$stdout_file" 2>"$stderr_file"
  local status=$?
  set -e
  printf '%s\n' "$status" > "$status_file"
}

run_variant linker "$BASE_PROBE"
run_variant development "$BUILD_DIRECTORY/fli-wine-4k-spawn-development"
run_variant public-jit "$BUILD_DIRECTORY/fli-wine-4k-spawn-public-jit"
run_variant app-public-jit \
  "$APP_BUNDLE/Contents/MacOS/fli-wine-4k-spawn-probe"

{
  printf 'schema=%s\n' '1'
  printf 'scope=%s\n' 'isolated-macos-arm64-4k-page-setexec'
  printf 'host_page_size=%s\n' "$(getconf PAGESIZE)"
  printf 'restricted_entitlement_requested=%s\n' 'no'
  printf 'wine=%s\n' 'not-executed'
  printf 'fex=%s\n' 'not-executed'
  printf 'proton=%s\n' 'not-executed'
  printf 'steam=%s\n' 'not-executed'
  printf 'game=%s\n' 'not-executed'
  printf 'eac=%s\n' 'not-executed'
} > "$OUTPUT_DIRECTORY/scope.txt"

shasum -a 256 "$SOURCE" "$PUBLIC_ENTITLEMENTS" "$APP_INFO_PLIST" \
  | sed "s#  $ROOT/#  repository/#" > "$OUTPUT_DIRECTORY/sources.sha256"
(
  cd "$OUTPUT_DIRECTORY"
  shasum -a 256 -- * > tree.sha256
)
chmod 0600 "$OUTPUT_DIRECTORY"/*

for name in linker development public-jit app-public-jit; do
  grep -Fq '"phase":"before-setexec"' "$OUTPUT_DIRECTORY/$name.stderr.jsonl" || {
    echo "ERROR: $name no alcanzó la frontera de páginas de 4 KiB." >&2
    exit 70
  }
done

echo "A/B de páginas de 4 KiB preservada: $OUTPUT_DIRECTORY"
for name in linker development public-jit app-public-jit; do
  printf '%s: exit=%s\n' "$name" "$(cat "$OUTPUT_DIRECTORY/$name.status")"
done
