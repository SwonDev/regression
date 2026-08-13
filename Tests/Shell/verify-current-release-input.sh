#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
VERIFIER="$ROOT/build/verify-current-release-input.sh"
SCRATCH="$(mktemp -d /private/tmp/regression-current-release-input.XXXXXX)"
trap 'find "$SCRATCH" -depth -delete' EXIT
APP="$SCRATCH/Regression.app"
BIN="$SCRATCH/bin"
FIXTURE_ROOT="$SCRATCH/root"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/SharedSupport/bin" \
    "$BIN" "$FIXTURE_ROOT/Scripts"

printf 'main-current\n' > "$BIN/Regression"
printf 'ctl-current\n' > "$BIN/regressionctl"
chmod 755 "$BIN/Regression" "$BIN/regressionctl"
for pair in \
    'regression-engine.sh:Contents/MacOS/regression-engine' \
    'install_apple_gptk_component.sh:Contents/SharedSupport/bin/install-apple-gptk-component' \
    'install_windows_media_component.sh:Contents/SharedSupport/bin/install-windows-media-component'
do
    source_name="${pair%%:*}"
    bundled="${pair#*:}"
    printf 'script-current-%s\n' "$source_name" > "$FIXTURE_ROOT/Scripts/$source_name"
    cp "$FIXTURE_ROOT/Scripts/$source_name" "$APP/$bundled"
done
cp "$BIN/Regression" "$APP/Contents/MacOS/Regression"
cp "$BIN/regressionctl" "$APP/Contents/SharedSupport/bin/regressionctl"
chmod 755 "$APP/Contents/MacOS/Regression" \
    "$APP/Contents/SharedSupport/bin/regressionctl"

"$VERIFIER" public-1.11 "$APP" "$BIN" "$FIXTURE_ROOT" >/dev/null
"$VERIFIER" development "$APP" "$BIN" "$FIXTURE_ROOT" >/dev/null

expect_rejection() {
    local description="$1" expected="$2"
    shift 2
    output="$("$@" 2>&1)" && {
        printf 'FAIL: se aceptó %s\n' "$description" >&2
        exit 1
    }
    grep -F "$expected" <<< "$output" >/dev/null \
        || { printf 'FAIL: diagnóstico inesperado para %s: %s\n' "$description" "$output" >&2; exit 1; }
}

printf 'main-stale\n' > "$APP/Contents/MacOS/Regression"
expect_rejection 'main stale' 'binario Release actual: Regression' \
    "$VERIFIER" public-1.11 "$APP" "$BIN" "$FIXTURE_ROOT"
cp "$BIN/Regression" "$APP/Contents/MacOS/Regression"
printf 'ctl-stale\n' > "$APP/Contents/SharedSupport/bin/regressionctl"
expect_rejection 'CLI stale' 'binario Release actual: regressionctl' \
    "$VERIFIER" public-1.11 "$APP" "$BIN" "$FIXTURE_ROOT"
cp "$BIN/regressionctl" "$APP/Contents/SharedSupport/bin/regressionctl"
printf 'script-stale\n' > "$APP/Contents/MacOS/regression-engine"
expect_rejection 'script stale' 'script actual: regression-engine.sh' \
    "$VERIFIER" public-1.11 "$APP" "$BIN" "$FIXTURE_ROOT"
expect_rejection 'modo desconocido' 'modo de input debe ser development o public-1.11' \
    "$VERIFIER" unknown "$APP" "$BIN" "$FIXTURE_ROOT"

printf 'PASS: input público actual acepta positivos y rechaza main, CLI, scripts stale y modo desconocido.\n'
