#!/usr/bin/env bash
# Demuestra que el staging público contiene exactamente los binarios Release y scripts actuales.
set -euo pipefail

MODE="${1:-}"
APP="${2:-}"
BIN_DIR="${3:-}"
ROOT="${4:-}"

fail() { printf 'ERROR: %s\n' "$*" >&2; exit 1; }

case "$MODE" in
    development)
        exit 0
        ;;
    public-1.11)
        ;;
    *)
        fail "el modo de input debe ser development o public-1.11"
        ;;
esac

[[ -d "$APP" && -d "$BIN_DIR" && -d "$ROOT/Scripts" ]] \
    || fail "faltan las raíces físicas del input público"
for binary_pair in \
    "Regression:Contents/MacOS/Regression" \
    "regressionctl:Contents/SharedSupport/bin/regressionctl"
do
    product="${binary_pair%%:*}"
    bundled="${binary_pair#*:}"
    [[ -x "$BIN_DIR/$product" && -x "$APP/$bundled" ]] \
        || fail "falta el binario Release actual: $product"
    cmp -s "$BIN_DIR/$product" "$APP/$bundled" \
        || fail "el staging público no contiene el binario Release actual: $product"
done
for script_pair in \
    "regression-engine.sh:Contents/MacOS/regression-engine" \
    "install_apple_gptk_component.sh:Contents/SharedSupport/bin/install-apple-gptk-component" \
    "install_windows_media_component.sh:Contents/SharedSupport/bin/install-windows-media-component"
do
    source_script="${script_pair%%:*}"
    bundled_script="${script_pair#*:}"
    [[ -f "$ROOT/Scripts/$source_script" && -f "$APP/$bundled_script" ]] \
        || fail "falta el script actual: $source_script"
    cmp -s "$ROOT/Scripts/$source_script" "$APP/$bundled_script" \
        || fail "el staging público no contiene el script actual: $source_script"
done

printf 'Input público actual verificado: binarios Release y scripts coinciden.\n'
