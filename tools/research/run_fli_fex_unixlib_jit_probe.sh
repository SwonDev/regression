#!/bin/zsh
set -euo pipefail

if (( $# < 2 || $# > 3 )); then
  print -u2 "uso: $0 <fex-source-root> <unixlib-module> [evidence-output-dir]"
  exit 64
fi

root=${0:A:h:h:h}
script_dir=${0:A:h}
fex_source=${1:A}
unixlib_module=${2:A}
evidence_output=${3:-}

if [[ ! -f "$fex_source/Source/Windows/UnixLib/FEXUnixLib.h" ]]; then
  print -u2 "No se encontró FEXUnixLib.h en: $fex_source"
  exit 65
fi

if [[ ! -f "$unixlib_module" || -L "$unixlib_module" ]]; then
  print -u2 "El módulo UnixLib debe ser un archivo regular: $unixlib_module"
  exit 66
fi

identity=${REGRESSION_CODESIGN_IDENTITY:-}
if [[ -z "$identity" ]]; then
  identity=$(security find-identity -v -p codesigning 2>/dev/null | awk '/"Apple Development:/ { print $2; exit }')
fi
if [[ -z "$identity" || "$identity" == "-" ]]; then
  print -u2 "La sonda endurecida necesita una identidad Apple Development estable."
  exit 69
fi

build_dir=$(mktemp -d /private/tmp/regression-fli-fex-unixlib-jit.XXXXXX)
cleanup() {
  case "$build_dir" in
    /private/tmp/regression-fli-fex-unixlib-jit.*)
      rm -rf -- "$build_dir"
      ;;
  esac
}
trap cleanup EXIT

runtime_dir="$build_dir/runtime"
mkdir -m 0700 "$runtime_dir"
runtime_module="$runtime_dir/${unixlib_module:t}"
probe="$runtime_dir/fli-fex-unixlib-jit-probe"
cp "$unixlib_module" "$runtime_module"

xcrun clang++ \
  -std=c++20 \
  -arch arm64 \
  -O2 \
  -Wall \
  -Wextra \
  -Werror \
  -I "$fex_source/Source/Windows/UnixLib" \
  "$script_dir/fli_fex_unixlib_jit_probe.cpp" \
  -o "$probe"

codesign --force --sign "$identity" --options runtime "$runtime_module" >/dev/null
codesign --force \
  --sign "$identity" \
  --options runtime \
  --entitlements "$root/tools/research/fli_nonvm_host_probe.entitlements" \
  "$probe" >/dev/null

codesign --verify --strict "$runtime_module"
codesign --verify --strict "$probe"

allow_jit=$(codesign -d --entitlements :- "$probe" 2>/dev/null \
  | plutil -extract 'com\.apple\.security\.cs\.allow-jit' raw -o - -- -)
if [[ "$allow_jit" != "true" ]]; then
  print -u2 "La sonda perdió el entitlement com.apple.security.cs.allow-jit."
  exit 70
fi

receipt="$build_dir/unixlib-jit-probe.txt"
"$probe" "$runtime_module" | tee "$receipt"
grep -Fq 'RESULT PASS' "$receipt" || {
  print -u2 "La sonda JIT no superó el contrato completo."
  exit 70
}

if [[ -n "$evidence_output" ]]; then
  evidence_output=${evidence_output:A}
  if [[ -L "$evidence_output" ]]; then
    print -u2 "El directorio de evidencia no puede ser un enlace simbólico."
    exit 66
  fi
  install -d -m 0700 "$evidence_output"
  install -m 0600 "$receipt" "$evidence_output/unixlib-jit-probe.txt"
  shasum -a 256 \
    "$script_dir/fli_fex_unixlib_jit_probe.cpp" \
    "$script_dir/run_fli_fex_unixlib_jit_probe.sh" \
    "$root/tools/research/fli_nonvm_host_probe.entitlements" \
    "$unixlib_module" \
    | sed "s#  $root/#  repository/#; s#  $fex_source/#  fex-source/#; s#  $unixlib_module#  unixlib-module#" \
    > "$evidence_output/sources.sha256"
  chmod 0600 "$evidence_output/sources.sha256"
  {
    print 'signature=valid'
    print 'hardened_runtime=yes'
    print 'allow_jit=true'
    print 'identity=apple-development-local'
  } > "$evidence_output/signature.txt"
  chmod 0600 "$evidence_output/signature.txt"
  (
    cd "$evidence_output"
    shasum -a 256 unixlib-jit-probe.txt sources.sha256 signature.txt > tree.sha256
  )
  chmod 0600 "$evidence_output/tree.sha256"
  print "Evidencia privada: $evidence_output"
fi
