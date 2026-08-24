#!/usr/bin/env bash
# shellcheck disable=SC2016
#
# La versión de una release vive en varios archivos y todos tienen que coincidir. Este contrato
# comprueba **la coherencia**, no un número concreto: la versión se deriva del empaquetador nativo
# y se exige que el instalador y el empaquetador público declaren la misma.
#
# Hardcodear aquí «1.12.5 (43)» convertía este test en un sexto sitio donde vivía la versión, así
# que subirla obligaba a editarlo y el fallo aparecía como «no comparten el contrato» —un mensaje
# que señala al sitio equivocado—. Derivarla elimina ese sitio.
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
    local version build

    # El empaquetador nativo es la fuente: de él salen la versión y el build que deben compartir
    # el instalador y el empaquetador público.
    version="$(contract_value "$native_packager" VERSION)" || return 1
    build="$(contract_value "$native_packager" BUILD_NUMBER)" || return 1
    [[ "$version" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] || return 1
    [[ "$build" =~ ^[0-9]+$ ]] || return 1

    [[ "$(contract_value "$installer" VERSION)" == "$version" ]] || return 1
    [[ "$(contract_value "$installer" BUILD_NUMBER)" == "$build" ]] || return 1
    grep -Fx "VERSION=\"\${REGRESSION_RELEASE_VERSION:-${version}}\"" \
        "$release_packager" >/dev/null || return 1
    grep -Fx "BUILD_NUMBER=\"\${REGRESSION_RELEASE_BUILD_NUMBER:-${build}}\"" \
        "$release_packager" >/dev/null || return 1
}

CONTRACT_VERSION="$(contract_value "$NATIVE_PACKAGER" VERSION || true)"
CONTRACT_BUILD="$(contract_value "$NATIVE_PACKAGER" BUILD_NUMBER || true)"

assert_contract "$INSTALLER" "$RELEASE_PACKAGER" "$NATIVE_PACKAGER" || {
    printf 'FAIL: instalador y empaquetadores no comparten el contrato %s (%s).\n' \
        "${CONTRACT_VERSION:-?}" "${CONTRACT_BUILD:-?}" >&2
    exit 1
}

# Un empaquetador que se desvía tiene que rechazarse, no colarse por coincidir en el resto.
cp "$INSTALLER" "$SCRATCH/install_regression.sh"
cp "$RELEASE_PACKAGER" "$SCRATCH/package_release.sh"
cp "$NATIVE_PACKAGER" "$SCRATCH/package_regression.sh"
/usr/bin/sed -i '' "s/^VERSION=\"${CONTRACT_VERSION}\"$/VERSION=\"0.0.1\"/" \
    "$SCRATCH/package_regression.sh"
if assert_contract \
    "$SCRATCH/install_regression.sh" \
    "$SCRATCH/package_release.sh" \
    "$SCRATCH/package_regression.sh"; then
    printf 'FAIL: el contrato aceptó un empaquetador divergente.\n' >&2
    exit 1
fi

printf 'PASS: instalador y empaquetadores comparten %s (%s) y el drift se rechaza.\n' \
    "$CONTRACT_VERSION" "$CONTRACT_BUILD"
