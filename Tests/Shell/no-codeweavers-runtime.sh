#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
CONTROLLER="${1:-$ROOT/.build/debug/regressionctl}"
SCRATCH="$(mktemp -d /private/tmp/regression-no-codeweavers-runtime.XXXXXX)"

cleanup() {
    find "$SCRATCH" -mindepth 1 -depth -delete
    rmdir "$SCRATCH"
}
trap cleanup EXIT

scan_forbidden() {
    local pattern="$1"
    local output="$2"
    shift 2
    local status

    set +e
    /usr/bin/grep -Eni "$pattern" "$@" >"$output"
    status=$?
    set -e
    case "$status" in
        0) return 0 ;;
        1) return 1 ;;
        *)
            printf 'FAIL: el escáner del gate falló (grep exit=%s).\n' "$status" >&2
            exit 1
            ;;
    esac
}

[[ -x "$CONTROLLER" ]] \
    || { printf 'FAIL: no existe regressionctl ejecutable: %s\n' "$CONTROLLER" >&2; exit 1; }

for retired_command in catalog-sync catalog comparisons; do
    set +e
    REGRESSION_COMPATIBILITY_DATABASE_PATH="$SCRATCH/$retired_command.sqlite" \
        "$CONTROLLER" "$retired_command" 4242 >"$SCRATCH/$retired_command.output" 2>&1
    status=$?
    set -e

    [[ "$status" -eq 64 ]] \
        || { printf 'FAIL: %s no fue rechazado como comando retirado (exit=%s).\n' \
            "$retired_command" "$status" >&2; exit 1; }
    grep -F 'Uso: regressionctl' "$SCRATCH/$retired_command.output" >/dev/null \
        || { printf 'FAIL: regressionctl no devolvió el contrato de uso al rechazar %s.\n' \
            "$retired_command" >&2; exit 1; }
done

FAKE_HOME="$SCRATCH/home"
FAKE_CXBOTTLE="$FAKE_HOME/Applications/CrossOver.app/Contents/SharedSupport/CrossOver/bin/cxbottle"
mkdir -p "$(dirname "$FAKE_CXBOTTLE")"
cat > "$FAKE_CXBOTTLE" <<EOF
#!/bin/sh
printf 'spawned\n' >> '$SCRATCH/cxbottle-spawns'
exit 0
EOF
chmod 755 "$FAKE_CXBOTTLE"

set +e
HOME="$FAKE_HOME" REGRESSION_COMPATIBILITY_DATABASE_PATH="$SCRATCH/observe.sqlite" \
    "$CONTROLLER" observe 4242 failed --backend crossOver --name Legacy \
    >"$SCRATCH/observe.output" 2>&1
observe_status=$?
set -e
[[ "$observe_status" -eq 64 ]] \
    || { printf 'FAIL: observe aceptó CrossOver o devolvió un estado incorrecto (exit=%s).\n' \
        "$observe_status" >&2; exit 1; }
[[ ! -e "$SCRATCH/cxbottle-spawns" ]] \
    || { printf 'FAIL: observe ejecutó cxbottle.\n' >&2; exit 1; }

run_rejected_command() {
    local label="$1"
    shift
    set +e
    HOME="$FAKE_HOME" REGRESSION_COMPATIBILITY_DATABASE_PATH="$SCRATCH/rejected.sqlite" \
        "$CONTROLLER" "$@" >"$SCRATCH/rejected.output" 2>&1
    rejected_status=$?
    set -e
    [[ "$rejected_status" -eq 64 ]] \
        || { printf 'FAIL: %s no fue rechazado con exit 64 (exit=%s).\n' \
            "$label" "$rejected_status" >&2; exit 1; }
}
run_rejected_command 'preflight CrossOver' preflight 4242 --backend crossOver
run_rejected_command 'switch CrossOver' switch crossOver
[[ ! -e "$SCRATCH/cxbottle-spawns" ]] \
    || { printf 'FAIL: un comando rechazado ejecutó cxbottle.\n' >&2; exit 1; }

HOME="$FAKE_HOME" REGRESSION_COMPATIBILITY_DATABASE_PATH="$SCRATCH/research.sqlite" \
    "$CONTROLLER" research-open 4242 --name Autónomo --symptom Falla --expected Funciona \
    >"$SCRATCH/research-open.output" 2>&1
[[ ! -e "$SCRATCH/cxbottle-spawns" ]] \
    || { printf 'FAIL: research-open ejecutó cxbottle.\n' >&2; exit 1; }
HOME="$FAKE_HOME" REGRESSION_COMPATIBILITY_DATABASE_PATH="$SCRATCH/research.sqlite" \
    "$CONTROLLER" research-protocol >"$SCRATCH/research-protocol.output" 2>&1
if scan_forbidden 'crossover|codeweavers|cxbottle' \
    "$SCRATCH/research-protocol.forbidden" "$SCRATCH/research-protocol.output"; then
    printf 'FAIL: el protocolo nuevo sigue exigiendo una referencia externa.\n' >&2
    exit 1
fi

REGRESSION_COMPATIBILITY_DATABASE_PATH="$SCRATCH/technologies.sqlite" \
    "$CONTROLLER" technologies >"$SCRATCH/technologies.output" 2>&1

tr '[:upper:]' '[:lower:]' <"$SCRATCH/catalog-sync.output" >"$SCRATCH/usage-output"
if scan_forbidden 'catalog-sync|(^|[[:space:]|])catalog([[:space:]|]|$)|comparisons' \
    "$SCRATCH/usage.forbidden" "$SCRATCH/usage-output"; then
    printf 'FAIL: el CLI sigue anunciando un comando de catálogo retirado.\n' >&2
    exit 1
fi
tr '[:upper:]' '[:lower:]' <"$SCRATCH/technologies.output" >"$SCRATCH/technologies-normalized"
if scan_forbidden 'codeweavers|crossover|https?://[^[:space:]]*codeweavers' \
    "$SCRATCH/technologies.forbidden" "$SCRATCH/technologies-normalized"; then
    printf 'FAIL: technologies sigue exponiendo una referencia operativa retirada.\n' >&2
    exit 1
fi

PRODUCT_FILES=(
    "$ROOT/Sources/RegressionCore/InstallationDiscovery.swift"
    "$ROOT/Sources/RegressionControl/main.swift"
    "$ROOT/Sources/RegressionCore/ConfigurationCollector.swift"
    "$ROOT/Sources/RegressionCore/ExternalCatalogSynchronizer.swift"
    "$ROOT/Sources/RegressionCore/CodeWeaversCompatibilityProvider.swift"
    "$ROOT/Sources/RegressionCore/CrossOverUpdateChecker.swift"
    "$ROOT/Sources/RegressionCore/RuntimeTechnologyCatalog.swift"
    "$ROOT/Sources/Regression/RegressionVisualFixture.swift"
)
FORBIDDEN_RUNTIME_PATTERN='https?://([^/]*\.)?codeweavers\.com|URLSession|catalog-sync|cxbottle|SUFeedURL|cxbottle\.conf'
printf 'cxbottle\n' >"$SCRATCH/scanner-canary"
if ! scan_forbidden "$FORBIDDEN_RUNTIME_PATTERN" \
    "$SCRATCH/scanner-canary.result" "$SCRATCH/scanner-canary"; then
    printf 'FAIL: el escáner no detectó su testigo prohibido.\n' >&2
    exit 1
fi

if scan_forbidden "$FORBIDDEN_RUNTIME_PATTERN" \
    "$SCRATCH/forbidden-runtime" "${PRODUCT_FILES[@]}"; then
    printf 'FAIL: quedan rutas operativas de CodeWeavers en el producto:\n' >&2
    cat "$SCRATCH/forbidden-runtime" >&2
    exit 1
fi

if ! /usr/bin/strings "$CONTROLLER" >"$SCRATCH/controller.strings"; then
    printf 'FAIL: no se pudo extraer el contenido del binario exacto.\n' >&2
    exit 1
fi
if scan_forbidden "$FORBIDDEN_RUNTIME_PATTERN" \
    "$SCRATCH/forbidden-binary" "$SCRATCH/controller.strings"; then
    printf 'FAIL: el binario conserva rutas operativas de CodeWeavers:\n' >&2
    cat "$SCRATCH/forbidden-binary" >&2
    exit 1
fi

printf 'PASS: regressionctl y RegressionCore no exponen runtime operativo de CodeWeavers.\n'
