#!/usr/bin/env bash
# shellcheck disable=SC2016
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
INSTALLER="$ROOT/Scripts/install_regression.sh"
RELEASE_PACKAGER="$ROOT/Scripts/package_release.sh"
NATIVE_PACKAGER="$ROOT/Scripts/package_regression.sh"
SCRATCH="$(mktemp -d /private/tmp/regression-version-coherence-test.XXXXXX)"

cleanup() {
    find "$SCRATCH" -mindepth 1 -depth -delete
    rmdir "$SCRATCH"
}
trap cleanup EXIT

contract_value() {
    local file="$1" key="$2" lines value
    lines="$(grep -E "^${key}=\"[^\"]+\"$" "$file" || true)"
    [[ -n "$lines" && "$(printf '%s\n' "$lines" | wc -l | tr -d ' ')" == "1" ]] \
        || return 1
    value="${lines#*=\"}"
    value="${value%\"}"
    printf '%s\n' "$value"
}

assert_contract() {
    local installer="$1" release_packager="$2" native_packager="$3"
    [[ "$(contract_value "$installer" VERSION)" == "1.12.0" ]] || return 1
    [[ "$(contract_value "$installer" BUILD_NUMBER)" == "38" ]] || return 1
    grep -Fx 'VERSION="${REGRESSION_RELEASE_VERSION:-1.12.0}"' \
        "$release_packager" >/dev/null || return 1
    grep -Fx 'BUILD_NUMBER="${REGRESSION_RELEASE_BUILD_NUMBER:-38}"' \
        "$release_packager" >/dev/null || return 1
    [[ "$(contract_value "$native_packager" VERSION)" == "1.12.0" ]] || return 1
    [[ "$(contract_value "$native_packager" BUILD_NUMBER)" == "38" ]] || return 1
}

assert_contract "$INSTALLER" "$RELEASE_PACKAGER" "$NATIVE_PACKAGER" || {
    printf 'FAIL: instalador y empaquetadores no comparten el contrato 1.12.0 (38).\n' >&2
    exit 1
}

cp "$INSTALLER" "$SCRATCH/install_regression.sh"
cp "$RELEASE_PACKAGER" "$SCRATCH/package_release.sh"
cp "$NATIVE_PACKAGER" "$SCRATCH/package_regression.sh"
/usr/bin/sed -i '' 's/^VERSION="1.12.0"$/VERSION="1.11.0"/' \
    "$SCRATCH/package_regression.sh"
if assert_contract \
    "$SCRATCH/install_regression.sh" \
    "$SCRATCH/package_release.sh" \
    "$SCRATCH/package_regression.sh"; then
    printf 'FAIL: el contrato aceptó un empaquetador 1.11 divergente.\n' >&2
    exit 1
fi

printf 'PASS: instalador y empaquetadores comparten 1.12.0 (38) y el drift 1.11 se rechaza.\n'
