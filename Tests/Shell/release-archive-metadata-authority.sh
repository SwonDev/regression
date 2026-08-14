#!/usr/bin/env bash
# Cubre metadata pública y neutral de los headers pax sin generar una release real.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
PACKAGER="$ROOT/Scripts/package_release.sh"
VERIFIER="$ROOT/build/verify-release-asset.sh"
SCRATCH="$(mktemp -d /private/tmp/regression-release-archive-metadata.XXXXXX)"

cleanup() {
    find "$SCRATCH" -mindepth 1 -depth -delete
    rmdir "$SCRATCH"
}
trap cleanup EXIT

fail() {
    printf 'FAIL: %s\n' "$*" >&2
    exit 1
}

expect_failure() {
    local description="$1" expected="$2"
    shift 2
    local output exit_code
    set +e
    output="$("$@" 2>&1)"
    exit_code=$?
    set -e
    [[ $exit_code -ne 0 ]] || fail "$description debía fallar"
    /usr/bin/grep -Fq "$expected" <<< "$output" \
        || fail "$description falló sin el diagnóstico esperado: $output"
}

write_bundle() {
    local target="$1" info_mode="$2"
    mkdir -p "$target/Regression.app/Contents/MacOS"
    printf '<plist version="1.0"/>\n' > "$target/Regression.app/Contents/Info.plist"
    chmod "$info_mode" "$target/Regression.app/Contents/Info.plist"
    printf '#!/bin/sh\nexit 0\n' > "$target/Regression.app/Contents/MacOS/Regression"
    chmod 755 "$target/Regression.app/Contents/MacOS/Regression"
    xattr -w com.regression.archive-test preserved \
        "$target/Regression.app/Contents/MacOS/Regression"
}

write_checksum() {
    local archive="$1"
    shasum -a 256 "$archive" | awk '{ print $1 "  " FILENAME }' FILENAME="$(basename "$archive")" \
        > "$archive.sha256"
}

verify_metadata_only() {
    local archive="$1"
    REGRESSION_RELEASE_ARCHIVE_METADATA_ONLY=1 \
        "$VERIFIER" "$archive" "$archive.sha256" 1.12.1 39
}

make_normalized_archive() {
    local source="$1" archive="$2"
    COPYFILE_DISABLE=1 tar --xattrs --no-mac-metadata \
        --uid 0 --gid 0 --uname root --gname wheel \
        -C "$source" -czf "$archive" Regression.app
}

GOOD_ROOT="$SCRATCH/good"
write_bundle "$GOOD_ROOT" 644
GOOD_ARCHIVE="$SCRATCH/good.tar.gz"
make_normalized_archive "$GOOD_ROOT" "$GOOD_ARCHIVE"
write_checksum "$GOOD_ARCHIVE"
verify_metadata_only "$GOOD_ARCHIVE" >/dev/null
GOOD_EXTRACT="$SCRATCH/good-extract"
mkdir -p "$GOOD_EXTRACT"
COPYFILE_DISABLE=1 tar --xattrs --no-mac-metadata -xf "$GOOD_ARCHIVE" -C "$GOOD_EXTRACT"
[[ "$(xattr -p com.regression.archive-test \
    "$GOOD_EXTRACT/Regression.app/Contents/MacOS/Regression")" == "preserved" ]] \
    || fail "el tar público perdió un xattr del fichero ejecutable"

PERSONAL_ARCHIVE="$SCRATCH/personal.tar.gz"
# No dependemos del UID del runner: este header reproduce de forma determinista
# una identidad personal que el auditor debe rechazar.
COPYFILE_DISABLE=1 tar --xattrs --no-mac-metadata \
    --uid 501 --gid 20 --uname adrianpereradelgado --gname staff \
    -C "$GOOD_ROOT" -czf "$PERSONAL_ARCHIVE" Regression.app
write_checksum "$PERSONAL_ARCHIVE"
expect_failure "headers personales" 'header con metadata no neutral' \
    verify_metadata_only "$PERSONAL_ARCHIVE"

PRIVATE_ROOT="$SCRATCH/private"
write_bundle "$PRIVATE_ROOT" 600
PRIVATE_ARCHIVE="$SCRATCH/private.tar.gz"
make_normalized_archive "$PRIVATE_ROOT" "$PRIVATE_ARCHIVE"
write_checksum "$PRIVATE_ARCHIVE"
expect_failure "Info.plist privado" 'Contents/Info.plist debe ser un fichero regular 0644' \
    verify_metadata_only "$PRIVATE_ARCHIVE"

EXECUTABLE_INFO_ROOT="$SCRATCH/executable-info"
write_bundle "$EXECUTABLE_INFO_ROOT" 755
EXECUTABLE_INFO_ARCHIVE="$SCRATCH/executable-info.tar.gz"
make_normalized_archive "$EXECUTABLE_INFO_ROOT" "$EXECUTABLE_INFO_ARCHIVE"
write_checksum "$EXECUTABLE_INFO_ARCHIVE"
expect_failure "Info.plist ejecutable" 'Contents/Info.plist debe ser un fichero regular 0644' \
    verify_metadata_only "$EXECUTABLE_INFO_ARCHIVE"

/usr/bin/grep -Fq "chmod 644 \"\$app/Contents/Info.plist\"" "$PACKAGER" \
    || fail "package_release no normaliza Info.plist antes de firmar"
/usr/bin/grep -Fq -- '--uid 0 --gid 0 --uname root --gname wheel' "$PACKAGER" \
    || fail "package_release no fija la metadata de los headers"
/usr/bin/grep -Fq "verify_archive_metadata \"\$ASSET\"" "$VERIFIER" \
    || fail "verify-release-asset no audita la metadata del tar real"
if /usr/bin/grep -Fq 'asset público reproducible' "$PACKAGER"; then
    fail "package_release promete reproducibilidad byte a byte que no acredita"
fi

printf 'PASS: el asset fija headers neutrales, conserva xattrs y rechaza modos privados.\n'
