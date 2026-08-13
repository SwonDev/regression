#!/bin/bash

set -u
set -o pipefail

ROOT="$(CDPATH='' cd "$(dirname "$0")/../.." && pwd)"
SOURCE_SCRIPT="$ROOT/build/verify-crossover-foss-source.sh"
TEST_ROOT="$(/usr/bin/mktemp -d /private/tmp/regression-crossover-foss-tests.XXXXXX)"

cleanup() {
    case "$TEST_ROOT" in
        /private/tmp/regression-crossover-foss-tests.*)
            /bin/rm -rf -- "$TEST_ROOT"
            ;;
    esac
}
trap cleanup 0
trap 'exit 130' HUP INT TERM

fail() {
    printf 'FAIL: %s\n' "$1" >&2
    exit 1
}

assert_contains() {
    local file="$1"
    local expected="$2"
    /usr/bin/grep -F -q -- "$expected" "$file" \
        || fail "no se encontró '$expected' en la salida"
}

make_harness() {
    local name="$1"
    local harness="$TEST_ROOT/$name"
    /bin/mkdir -p "$harness/build"
    /bin/cp "$SOURCE_SCRIPT" "$harness/build/verify-crossover-foss-source.sh"
    /bin/chmod +x "$harness/build/verify-crossover-foss-source.sh"
    printf '%s\n' "$harness"
}

write_fixture_contract() {
    local contract="$1"
    local archive_hash="$2"
    local baseline_hash="$3"
    /bin/cat > "$contract" <<EOF
contract_version=1
product=Fixture
release=1.0
official_url=https://example.invalid/fixture.tar.gz
archive_name=fixture.tar.gz
archive_sha256=$archive_hash
archive_root=sources
component=wine
version=wine|wine/VERSION|Wine version fixture
baseline=wine/VERSION|$baseline_hash
baseline=wine/base-a.c|$baseline_hash
baseline=wine/base-b.c|$baseline_hash
EOF
}

make_safe_fixture() {
    local harness="$1"
    local fixture="$harness/fixture"
    /bin/mkdir -p "$fixture/sources/wine"
    printf 'Wine version fixture\n' > "$fixture/sources/wine/VERSION"
    /bin/cp "$fixture/sources/wine/VERSION" "$fixture/sources/wine/base-a.c"
    /bin/cp "$fixture/sources/wine/VERSION" "$fixture/sources/wine/base-b.c"
    printf 'contenido fuera de los patch points\n' > "$fixture/sources/wine/untracked.c"
    /usr/bin/tar -czf "$harness/fixture.tar.gz" -C "$fixture" sources

    local archive_hash baseline_hash
    archive_hash="$(/usr/bin/shasum -a 256 "$harness/fixture.tar.gz" | /usr/bin/awk '{print $1}')"
    baseline_hash="$(/usr/bin/shasum -a 256 "$fixture/sources/wine/VERSION" | /usr/bin/awk '{print $1}')"
    write_fixture_contract "$harness/build/crossover-foss-26.3.0.contract" "$archive_hash" "$baseline_hash"
}

test_safe_fixture_and_tree_classification() {
    local harness output
    harness="$(make_harness safe)"
    make_safe_fixture "$harness"
    output="$harness/output.txt"

    "$harness/build/verify-crossover-foss-source.sh" \
        "$harness/fixture.tar.gz" "$harness/fixture/sources" > "$output"
    assert_contains "$output" "archive_identity=official_foss_release"
    assert_contains "$output" "tree_comparison_scope=complete_paths_types_content_and_link_targets"
    assert_contains "$output" "tree_classification=full_tree_match"
    assert_contains "$output" "tracked_patch_points=match"
    assert_contains "$output" "aggregate_gate=pass"
    assert_contains "$output" "network_access=none"
    assert_contains "$output" "result=pass"

    printf 'cambio no rastreado por el contrato\n' >> "$harness/fixture/sources/wine/untracked.c"
    if "$harness/build/verify-crossover-foss-source.sh" \
        "$harness/fixture.tar.gz" "$harness/fixture/sources" > "$output"; then
        fail "un cambio fuera de los patch points superó el gate completo"
    fi
    assert_contains "$output" "tracked_patch_points=match"
    assert_contains "$output" "tree_classification=full_tree_differ"
    assert_contains "$output" "aggregate_gate=fail"
    assert_contains "$output" "result=fail"

    printf 'contenido fuera de los patch points\n' > "$harness/fixture/sources/wine/untracked.c"
    printf 'modificado\n' >> "$harness/fixture/sources/wine/base-a.c"
    if "$harness/build/verify-crossover-foss-source.sh" \
        "$harness/fixture.tar.gz" "$harness/fixture/sources" > "$output"; then
        fail "un cambio de patch point superó el gate completo"
    fi
    assert_contains "$output" "tracked_patch_points=differ"
    assert_contains "$output" "tracked_patch_points_changed_files=wine/base-a.c"
    assert_contains "$output" "tree_classification=full_tree_differ"
}

test_checksum_mismatch() {
    local harness output
    harness="$(make_harness checksum)"
    make_safe_fixture "$harness"
    output="$harness/output.txt"
    printf 'alteración\n' >> "$harness/fixture.tar.gz"

    if "$harness/build/verify-crossover-foss-source.sh" "$harness/fixture.tar.gz" > "$output"; then
        fail "un tar con checksum incorrecto fue aceptado"
    fi
    assert_contains "$output" "error_code=archive_hash_mismatch"
}

test_escaping_symlink() {
    local harness fixture archive_hash baseline_hash output
    harness="$(make_harness symlink)"
    fixture="$harness/fixture"
    /bin/mkdir -p "$fixture/sources/wine"
    printf 'Wine version fixture\n' > "$fixture/sources/wine/VERSION"
    /bin/cp "$fixture/sources/wine/VERSION" "$fixture/sources/wine/base-a.c"
    /bin/cp "$fixture/sources/wine/VERSION" "$fixture/sources/wine/base-b.c"
    /bin/ln -s ../../outside "$fixture/sources/escape"
    /usr/bin/tar -czf "$harness/fixture.tar.gz" -C "$fixture" sources
    archive_hash="$(/usr/bin/shasum -a 256 "$harness/fixture.tar.gz" | /usr/bin/awk '{print $1}')"
    baseline_hash="$(/usr/bin/shasum -a 256 "$fixture/sources/wine/VERSION" | /usr/bin/awk '{print $1}')"
    write_fixture_contract "$harness/build/crossover-foss-26.3.0.contract" "$archive_hash" "$baseline_hash"
    output="$harness/output.txt"

    if "$harness/build/verify-crossover-foss-source.sh" "$harness/fixture.tar.gz" > "$output"; then
        fail "un enlace que escapa de la raíz fue aceptado"
    fi
    assert_contains "$output" "error_code=archive_unsafe_link"
}

test_traversal_member() {
    local harness fixture archive_hash payload_hash output
    harness="$(make_harness traversal)"
    fixture="$harness/fixture"
    /bin/mkdir -p "$fixture"
    printf 'Wine version fixture\n' > "$fixture/payload"

    # La sustitución de nombre de BSD tar permite construir una entrada hostil
    # sin escribir jamás fuera del temporal de la prueba.
    /usr/bin/tar -czf "$harness/fixture.tar.gz" -C "$fixture" \
        -s ',^payload$,../escape,' payload
    /usr/bin/tar -tzf "$harness/fixture.tar.gz" 2>/dev/null \
        | /usr/bin/grep -F -q -- '../escape' \
        || fail "no se pudo construir el fixture de traversal"

    archive_hash="$(/usr/bin/shasum -a 256 "$harness/fixture.tar.gz" | /usr/bin/awk '{print $1}')"
    payload_hash="$(/usr/bin/shasum -a 256 "$fixture/payload" | /usr/bin/awk '{print $1}')"
    write_fixture_contract "$harness/build/crossover-foss-26.3.0.contract" "$archive_hash" "$payload_hash"
    output="$harness/output.txt"

    if "$harness/build/verify-crossover-foss-source.sh" "$harness/fixture.tar.gz" > "$output" 2>&1; then
        fail "una entrada con traversal fue aceptada"
    fi
    assert_contains "$output" "error_code=archive_unsafe_path"
}

/bin/bash -n "$SOURCE_SCRIPT" || fail "el script principal no supera bash -n"
test_safe_fixture_and_tree_classification
test_checksum_mismatch
test_escaping_symlink
test_traversal_member
printf 'PASS: verify-crossover-foss-source\n'
