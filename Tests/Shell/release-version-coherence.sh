#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
INSTALLER="$ROOT/Scripts/install_regression.sh"
CANDIDATE_PACKAGER="$ROOT/Scripts/package_installed_runtime_candidate.sh"
CANDIDATE_VERIFIER="$ROOT/build/verify-installed-runtime-candidate.sh"
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
    local installer="$1" packager="$2" verifier="$3"
    [[ "$(contract_value "$installer" VERSION)" == "1.11.0" ]] || return 1
    [[ "$(contract_value "$installer" BUILD_NUMBER)" == "37" ]] || return 1
    [[ "$(contract_value "$packager" BASELINE_VERSION)" == "1.10.1" ]] || return 1
    [[ "$(contract_value "$packager" BASELINE_BUILD_NUMBER)" == "36" ]] || return 1
    [[ "$(contract_value "$packager" TARGET_VERSION)" == "1.11.0" ]] || return 1
    [[ "$(contract_value "$packager" TARGET_BUILD_NUMBER)" == "37" ]] || return 1
    [[ "$(contract_value "$verifier" BASELINE_VERSION)" == "1.10.1" ]] || return 1
    [[ "$(contract_value "$verifier" BASELINE_BUILD_NUMBER)" == "36" ]] || return 1
    [[ "$(contract_value "$verifier" TARGET_VERSION)" == "1.11.0" ]] || return 1
    [[ "$(contract_value "$verifier" TARGET_BUILD_NUMBER)" == "37" ]] || return 1
    grep -F 'verify-public-installed-state.sh" --release-1.10.1' "$packager" >/dev/null \
        || return 1
    grep -F 'verify-public-installed-state.sh" --release-1.11.0' "$verifier" >/dev/null \
        || return 1
}

assert_contract "$INSTALLER" "$CANDIDATE_PACKAGER" "$CANDIDATE_VERIFIER" || {
    printf 'FAIL: instalador, promoción y verificador no comparten el contrato 1.11.0 (37).\n' >&2
    exit 1
}

cp "$INSTALLER" "$SCRATCH/install_regression.sh"
cp "$CANDIDATE_PACKAGER" "$SCRATCH/package_installed_runtime_candidate.sh"
cp "$CANDIDATE_VERIFIER" "$SCRATCH/verify-installed-runtime-candidate.sh"
/usr/bin/sed -i '' 's/^TARGET_BUILD_NUMBER="37"$/TARGET_BUILD_NUMBER="36"/' \
    "$SCRATCH/package_installed_runtime_candidate.sh"
if assert_contract \
    "$SCRATCH/install_regression.sh" \
    "$SCRATCH/package_installed_runtime_candidate.sh" \
    "$SCRATCH/verify-installed-runtime-candidate.sh"; then
    printf 'FAIL: el contrato aceptó un build candidato divergente.\n' >&2
    exit 1
fi

printf 'PASS: instalador y candidato comparten 1.11.0 (37) y el drift negativo se rechaza.\n'
