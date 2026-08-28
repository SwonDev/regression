#!/usr/bin/env bash
#
# `UpdateSubresource` sobre una textura D3D11_USAGE_STAGING terminaba en `UNIMPLEMENTED` y DXMT
# abortaba el proceso, así que cualquier motor con la creación asíncrona de texturas de Unreal
# Engine 4 se cerraba antes del primer fotograma. Este contrato acredita que la corrección sigue
# en la serie versionada y que conserva las tres decisiones que la hacen correcta.
set -Eeuo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
PATCH="$ROOT/patches/dxmt-v0.72-update-staging-texture.patch"
APPLIER="$ROOT/build/apply-dxmt-patches.sh"

fail() { printf 'FAIL: %s\n' "$1" >&2; exit 1; }

[[ -f "$PATCH" ]] || fail "falta el parche de la actualización de texturas staging"
[[ -x "$APPLIER" ]] || fail "falta el aplicador de la serie DXMT"

contents="$(cat "$PATCH")"

# El UNIMPLEMENTED que abortaba el proceso se retira, no se degrada a aviso.
grep -q '^-.*UNIMPLEMENTED("update staging texture")' <<< "$contents" \
    || fail "el parche ya no retira el UNIMPLEMENTED que abortaba el proceso"
grep -q '^+.*UNIMPLEMENTED' <<< "$contents" \
    && fail "la corrección no puede reintroducir un UNIMPLEMENTED en esa rama"

# La copia va por el command buffer, no por un memcpy desde CPU: el destino puede tener trabajo
# encolado y una escritura directa se saltaría el orden.
grep -q '^+.*WMTBlitCommandCopyFromBufferToBuffer' <<< "$contents" \
    || fail "la actualización staging debe copiarse buffer a buffer por el command buffer"
grep -q '^+.*UseCopyDestination' <<< "$contents" \
    || fail "el recurso staging de destino debe declararse como destino de copia"

# Las texturas comprimidas direccionan bloques y el origen llega en texels.
grep -q '^+.*MTL_DXGI_FORMAT_BC' <<< "$contents" \
    || fail "el parche debe distinguir el direccionamiento por bloques de los formatos BC"

# La serie completa se aplica en orden y el cross-process sigue delante: sostiene el PIN.
grep -q 'dxmt-v0.72-cross-process-present.patch' "$APPLIER" \
    || fail "el aplicador perdió el parche cross-process que sostiene el PIN"
grep -q 'dxmt-v0.72-update-staging-texture.patch' "$APPLIER" \
    || fail "el aplicador no declara la corrección de texturas staging"
cross_line="$(grep -n 'dxmt-v0.72-cross-process-present.patch' "$APPLIER" | head -1 | cut -d: -f1)"
staging_line="$(grep -n 'dxmt-v0.72-update-staging-texture.patch"' "$APPLIER" | head -1 | cut -d: -f1)"
[[ "$cross_line" -lt "$staging_line" ]] \
    || fail "la serie DXMT debe aplicar el cross-process antes que la corrección staging"

# El árbol se prepara desde el tag de la generación fijada, nunca «tal como esté».
grep -q 'v0.72' "$ROOT/build/build-dxmt.sh" \
    || fail "build-dxmt.sh debe fijar el árbol al tag de la generación del PIN"
grep -q 'apply-dxmt-patches.sh' "$ROOT/build/build-dxmt.sh" \
    || fail "build-dxmt.sh debe aplicar la serie versionada antes de compilar"

printf 'PASS: DXMT implementa la actualización de texturas staging y su serie sigue ordenada.\n'
