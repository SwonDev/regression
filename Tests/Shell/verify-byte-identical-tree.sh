#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
VERIFIER="$ROOT/build/verify-byte-identical-tree.sh"
WORK_DIR="$(mktemp -d /private/tmp/regression-tree-verifier-test.XXXXXX)"
TREE_SCRATCH_BEFORE="$(find /private/tmp -maxdepth 1 \
    -name 'regression-tree-verify.*' | wc -l | tr -d ' ')"

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

SOURCE="$WORK_DIR/source"
CANDIDATE="$WORK_DIR/candidate"
mkdir -p "$SOURCE/bin" "$SOURCE/lib"
printf 'runtime-v1\n' > "$SOURCE/bin/wine"
chmod 755 "$SOURCE/bin/wine"
printf 'payload-v1\n' > "$SOURCE/lib/module.dylib"
ln -s ../lib/module.dylib "$SOURCE/bin/module-link"
xattr -w local.regression.test preserved "$SOURCE/lib/module.dylib"
ditto "$SOURCE" "$CANDIDATE"

"$VERIFIER" "$SOURCE" "$CANDIDATE" >/dev/null

printf 'runtime-v2\n' > "$CANDIDATE/bin/wine"
expect_failure "un byte modificado" "$VERIFIER" "$SOURCE" "$CANDIDATE"
ditto "$SOURCE" "$CANDIDATE"

unlink "$CANDIDATE/bin/module-link"
ln -s ../lib/other.dylib "$CANDIDATE/bin/module-link"
expect_failure "un destino de enlace modificado" "$VERIFIER" "$SOURCE" "$CANDIDATE"
ditto "$SOURCE" "$CANDIDATE"

xattr -w local.regression.test drifted "$CANDIDATE/lib/module.dylib"
expect_failure "un atributo extendido modificado" "$VERIFIER" "$SOURCE" "$CANDIDATE"
ditto "$SOURCE" "$CANDIDATE"

chmod 644 "$CANDIDATE/bin/wine"
expect_failure "un modo modificado" "$VERIFIER" "$SOURCE" "$CANDIDATE"
ditto "$SOURCE" "$CANDIDATE"

printf 'control-v1\n' > "$SOURCE/bin/regressionctl"
printf 'control-v2\n' > "$CANDIDATE/bin/regressionctl"
"$VERIFIER" "$SOURCE" "$CANDIDATE" bin/regressionctl >/dev/null
printf 'runtime-v2\n' > "$CANDIDATE/bin/wine"
expect_failure "drift fuera de la exclusión exacta" \
    "$VERIFIER" "$SOURCE" "$CANDIDATE" bin/regressionctl
ditto "$SOURCE" "$CANDIDATE"

mkdir -p "$SOURCE/lib/private/runtime" "$CANDIDATE/lib/private/runtime"
printf 'private-a\n' > "$SOURCE/lib/private/runtime/payload"
printf 'private-b\n' > "$CANDIDATE/lib/private/runtime/payload"
"$VERIFIER" "$SOURCE" "$CANDIDATE" lib/private/ >/dev/null
printf 'outside-drift\n' > "$CANDIDATE/lib/module.dylib"
expect_failure "drift fuera del subtree excluido" \
    "$VERIFIER" "$SOURCE" "$CANDIDATE" lib/private/
TREE_SCRATCH_AFTER="$(find /private/tmp -maxdepth 1 \
    -name 'regression-tree-verify.*' | wc -l | tr -d ' ')"
[[ "$TREE_SCRATCH_AFTER" == "$TREE_SCRATCH_BEFORE" ]] \
    || fail "el verificador dejó directorios temporales"

printf 'PASS: el verificador detecta drift de bytes, enlaces, xattrs y modos.\n'
