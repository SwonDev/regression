#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
HELPER="$ROOT/build/verify-public-1.11-transition-bundle.sh"
BASELINE="${REGRESSION_PUBLIC_1_11_BASELINE_APP:-}"
CANDIDATE="${REGRESSION_PUBLIC_1_11_CANDIDATE_APP:-}"
[[ -d "$BASELINE" && -d "$CANDIDATE" ]] || {
    printf 'FAIL: define baseline y candidato públicos 1.11 físicos.\n' >&2; exit 1;
}
SCRATCH="$(mktemp -d /private/tmp/regression-public-1.11-negative.XXXXXX)"
trap 'find "$SCRATCH" -depth -delete' EXIT

"$HELPER" baseline "$BASELINE" >/dev/null
"$HELPER" candidate "$CANDIDATE" >/dev/null

expect_failure() {
    local description="$1" expected="$2" role="$3" source="$4" mutation="$5"
    local copy="$SCRATCH/$description.app" output
    cp -cR "$source" "$copy"
    eval "$mutation"
    output="$("$HELPER" "$role" "$copy" 2>&1)" && {
        printf 'FAIL: se aceptó %s\n' "$description" >&2; exit 1;
    }
    grep -F "$expected" <<< "$output" >/dev/null \
        || { printf 'FAIL: diagnóstico inesperado %s: %s\n' "$description" "$output" >&2; exit 1; }
    find "$copy" -depth -delete
}

expect_failure baseline-main 'hash baseline inesperado' baseline "$BASELINE" \
    'cp "$CANDIDATE/Contents/MacOS/Regression" "$copy/Contents/MacOS/Regression"'
expect_failure baseline-ctl 'hash baseline inesperado' baseline "$BASELINE" \
    'cp "$CANDIDATE/Contents/SharedSupport/bin/regressionctl" "$copy/Contents/SharedSupport/bin/regressionctl"'
expect_failure baseline-gptk 'baseline contiene payload o enlaces GPTK' baseline "$BASELINE" \
    'printf injected > "$copy/Contents/SharedSupport/wine-root/lib/apple_gptk/external/injected"'
expect_failure candidate-main 'hash candidate inesperado' candidate "$CANDIDATE" \
    'cp "$BASELINE/Contents/MacOS/Regression" "$copy/Contents/MacOS/Regression"'
expect_failure candidate-ctl 'hash candidate inesperado' candidate "$CANDIDATE" \
    'cp "$BASELINE/Contents/SharedSupport/bin/regressionctl" "$copy/Contents/SharedSupport/bin/regressionctl"'
expect_failure candidate-gptk 'candidate contiene payload o enlaces GPTK' candidate "$CANDIDATE" \
    'printf injected > "$copy/Contents/SharedSupport/wine-root/lib/apple_gptk/external/injected"'
expect_failure candidate-bridge 'Switch2Bridge candidate no declara el commit fijado' candidate "$CANDIDATE" \
    'plutil -replace Switch2BridgeCommit -string stale "$copy/Contents/SharedSupport/Switch2Bridge/Switch2Bridge.app/Contents/Info.plist"'
expect_failure candidate-bridge-hash 'hash candidate inesperado' candidate "$CANDIDATE" \
    'printf stale >> "$copy/Contents/SharedSupport/Switch2Bridge/Switch2Bridge.app/Contents/MacOS/Switch2Bridge"'
expect_failure candidate-bridge-id 'Switch2Bridge candidate tiene bundle ID inesperado' candidate "$CANDIDATE" \
    'plutil -replace CFBundleIdentifier -string stale "$copy/Contents/SharedSupport/Switch2Bridge/Switch2Bridge.app/Contents/Info.plist"'
output="$("$HELPER" unknown "$CANDIDATE" 2>&1)" && {
    printf 'FAIL: se aceptó modo desconocido.\n' >&2; exit 1;
}
grep -F 'rol desconocido' <<< "$output" >/dev/null

asset_fixture="$SCRATCH/asset-fixture"
mkdir -p "$asset_fixture"
cp -cR "$CANDIDATE" "$asset_fixture/Regression.app"
mkdir "$asset_fixture/Regression.app/Contents/Injected"
asset="$SCRATCH/injected.tar.gz"
checksum="$asset.sha256"
COPYFILE_DISABLE=1 tar -czf "$asset" -C "$asset_fixture" Regression.app
printf '%s  %s\n' "$(shasum -a 256 "$asset" | awk '{print $1}')" \
    "$(basename "$asset")" > "$checksum"
output="$("$ROOT/build/verify-installed-runtime-candidate.sh" --baseline-public-1.11 \
    "$asset" "$checksum" "$BASELINE" 2>&1)" && {
    printf 'FAIL: se aceptó Contents/Injected.\n' >&2; exit 1;
}
grep -F 'estructura superior de Contents' <<< "$output" >/dev/null \
    || { printf 'FAIL: diagnóstico inesperado para Contents/Injected: %s\n' "$output" >&2; exit 1; }

printf 'PASS: transición pública 1.11 rechaza stale, GPTK, estructura inyectada y modo desconocido.\n'
