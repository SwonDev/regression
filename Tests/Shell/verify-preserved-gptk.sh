#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
VERIFIER="$ROOT/build/verify-preserved-gptk.sh"
WORK_DIR="$(mktemp -d /private/tmp/regression-gptk-verifier-test.XXXXXX)"

cleanup()
{
    find "$WORK_DIR" -depth -delete
}
trap cleanup EXIT

fail()
{
    printf 'FAIL: %s\n' "$*" >&2
    exit 1
}

expect_failure()
{
    local description="$1"
    shift
    if "$@" >"$WORK_DIR/unexpected.stdout" 2>"$WORK_DIR/unexpected.stderr"; then
        fail "$description debía rechazarse"
    fi
}

EXPECTED="$WORK_DIR/expected/Regression.app"
INSTALLED="$WORK_DIR/installed/Regression.app"
RELATIVE="Contents/SharedSupport/wine-root/lib/apple_gptk"
mkdir -p "$EXPECTED/$RELATIVE/external/D3DMetal.framework/Versions/A"
printf 'd3dmetal-v1\n' > "$EXPECTED/$RELATIVE/external/D3DMetal.framework/Versions/A/D3DMetal"
ln -s Versions/Current "$EXPECTED/$RELATIVE/external/D3DMetal.framework/D3DMetal"
ln -s A "$EXPECTED/$RELATIVE/external/D3DMetal.framework/Versions/Current"
ditto "$EXPECTED" "$INSTALLED"

"$VERIFIER" "$EXPECTED" "$INSTALLED" >/dev/null

printf 'd3dmetal-drift\n' > "$INSTALLED/$RELATIVE/external/D3DMetal.framework/Versions/A/D3DMetal"
expect_failure "bytes GPTK modificados" "$VERIFIER" "$EXPECTED" "$INSTALLED"
find "$INSTALLED" -depth -delete
ditto "$EXPECTED" "$INSTALLED"

unlink "$INSTALLED/$RELATIVE/external/D3DMetal.framework/Versions/Current"
ln -s B "$INSTALLED/$RELATIVE/external/D3DMetal.framework/Versions/Current"
expect_failure "enlace GPTK modificado" "$VERIFIER" "$EXPECTED" "$INSTALLED"

printf 'PASS: la conservación GPTK acepta identidad y rechaza bytes o enlaces distintos.\n'
