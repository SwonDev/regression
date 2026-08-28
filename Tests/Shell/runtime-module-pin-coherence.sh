#!/usr/bin/env bash
#
# Los módulos gráficos protegidos tienen su hash en DOS sitios que nadie ataba: los verificadores
# de shell y `RuntimeModuleCatalog.expectedSHA256`, que es lo que consulta la app **antes de
# arrancar Steam**. Resellar sólo el primero deja la app rechazando su propio runtime con
# «La ruta gráfica no es elegible: renderer.incomplete.dxmt:...» y Steam no abre, aunque todos los
# verificadores pasen. Este contrato exige que ambos declaren lo mismo.
set -Eeuo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
CATALOG="$ROOT/Sources/RegressionCore/RuntimeModuleCatalog.swift"
PROTECTED="$ROOT/build/verify-protected-state.sh"

fail() { printf 'FAIL: %s\n' "$1" >&2; exit 1; }

[[ -f "$CATALOG" ]] || fail "falta el catálogo de módulos del runtime"
[[ -f "$PROTECTED" ]] || fail "falta el verificador del estado protegido"

# moduleID de Swift -> nombre de archivo tal como lo fija el verificador.
check_module()
{
    local module_id="$1" file_name="$2" catalog_hash protected_hash

    # El hash se lee del bloque `expectedSHA256`, no del descriptor: el identificador aparece en
    # los dos sitios y el descriptor no lleva hash, así que buscarlo sin anclar devuelve el del
    # módulo anterior y el contrato pasaría comparando cosas distintas.
    catalog_hash="$(
        /usr/bin/awk -v id="\"$module_id\"" '
            /static func expectedSHA256/ { inside = 1 }
            inside && /^        default:/ { exit }
            inside && /^        case \(/ { armed = index($0, id) ? 1 : 0; next }
            inside && armed && match($0, /[0-9a-f]{64}/) {
                print substr($0, RSTART, RLENGTH); exit
            }
        ' "$CATALOG"
    )"
    [[ -n "$catalog_hash" ]] || fail "el catálogo no declara un hash para $module_id"

    protected_hash="$(
        /usr/bin/grep -E "verify_hash [0-9a-f]{64} \"Contents/SharedSupport/wine-root/lib/wine/x86_64-windows/$file_name\"" \
            "$PROTECTED" | /usr/bin/awk '{print $2}' | /usr/bin/head -1
    )"
    [[ -n "$protected_hash" ]] || fail "el estado protegido no fija $file_name en wine-root"

    [[ "$catalog_hash" == "$protected_hash" ]] || fail \
        "$module_id: el catálogo compilado dice ${catalog_hash:0:12}… y el estado protegido ${protected_hash:0:12}…"
}

check_module "dxmt.d3d11" "d3d11.dll"
check_module "dxmt.dxgi" "dxgi.dll"

printf 'PASS: el catálogo compilado y el estado protegido fijan los mismos módulos gráficos.\n'
