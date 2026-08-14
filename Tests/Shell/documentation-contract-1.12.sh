#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
SCHEMA_SOURCE="$ROOT/Sources/RegressionCore/CompatibilityRepository.swift"

fail()
{
    printf 'FAIL: %s\n' "$*" >&2
    exit 1
}

require_literal()
{
    local file="$1"
    local literal="$2"
    /usr/bin/grep -Fq -- "$literal" "$ROOT/$file" \
        || fail "$file no contiene el contrato: $literal"
}

require_absent()
{
    local file="$1"
    local literal="$2"
    ! /usr/bin/grep -Fq -- "$literal" "$ROOT/$file" \
        || fail "$file conserva como actual una afirmación obsoleta: $literal"
}

current_schema="$(/usr/bin/sed -nE \
    's/^[[:space:]]*public static let currentSchemaVersion = ([0-9]+)[[:space:]]*$/\1/p' \
    "$SCHEMA_SOURCE")"
[[ "$current_schema" =~ ^[0-9]+$ ]] \
    || fail "no se pudo derivar un único currentSchemaVersion de CompatibilityRepository.swift"

latest_migration="$(/usr/bin/sed -nE \
    's/.*PRAGMA user_version=([0-9]+);.*/\1/p' \
    "$SCHEMA_SOURCE" | /usr/bin/tail -n 1)"
[[ "$latest_migration" == "$current_schema" ]] \
    || fail "currentSchemaVersion=$current_schema no coincide con la última migración=$latest_migration"

for file in README.md AGENTS.md CLAUDE.md docs/README.md; do
    require_literal "$file" '1.12.3 (41)'
    require_literal "$file" 'v1.11.0 (37)'
done

require_literal README.md "SQLite **v${current_schema}**"
require_literal AGENTS.md '**Un perfecto v15 pertenece al proceso representativo exacto'
require_literal AGENTS.md '**Windows Media se repara por contenido, App ID y lease exclusivo.**'
require_literal AGENTS.md '**El runtime público 1.12 se autoriza como conjunto sellado.**'
require_literal AGENTS.md "SQLite **v${current_schema}**"
require_literal docs/compatibility-platform.md "Esquema SQLite actual: **v${current_schema}**"
require_literal docs/compatibility-platform.md '## Custodia de procesos y perfectos v15'
require_literal docs/compatibility-platform.md '## Salud de la telemetría'
require_literal docs/compatibility-platform.md "## Autoridad de lanzamiento v${current_schema}"
require_literal README.md 'auto-retry y el rollback automáticos permanecen'
require_literal docs/compatibility-platform.md \
    "\`retryDecision\` y \`recoveryDecision\` son por ahora políticas puras"
require_literal docs/compatibility-platform.md 'avance a espera de verificación y cierre solo tras'
require_literal docs/runtime-evolution.md "## Esquema vigente v${current_schema}"
require_literal docs/runtime-evolution.md '## Hito v15: custodia perfecta representativa'
require_literal docs/runtime-evolution.md 'No existe aún un ejecutor seguro'
require_literal docs/runtime-evolution.md '### Reparación Windows Media por App ID'
require_literal docs/runtime-evolution.md '### Autoridad de perfiles y renderers'
require_literal docs/runtime-evolution.md '### Sello del runtime público 1.12'
require_literal docs/game-test-readiness.md "El esquema actual **v${current_schema}**"
require_literal docs/game-test-readiness.md 'run siga abierto, la telemetría puede adoptarlo sin duplicar la sesión'
require_literal docs/game-test-readiness.md 'la telemetría no lo reanuda'
require_literal RESUME_REGRESSION_AAA.md '**Checkpoint histórico cerrado.**'
for file in README.md AGENTS.md CLAUDE.md docs/runtime-evolution.md; do
    require_literal "$file" '/usr/bin:/bin:/usr/sbin:/sbin'
done

require_absent AGENTS.md 'SQLite v14 normalizada'
require_absent AGENTS.md '## Estado rápido (2026-08-13)'
require_absent docs/compatibility-research.md 'El esquema local v14 separa'
require_absent docs/README.md 'Regression.app/                  App canónica de desarrollo'
require_absent README.md 'PATH cerrado dentro del bundle'
require_absent AGENTS.md "\`WINESERVER\` y el \`PATH\` internos"
require_absent CLAUDE.md "Fijar \`WINESERVER\` y \`PATH\` al bundle"
require_absent docs/runtime-evolution.md 'PATH` donde el bundle precede al sistema'
require_absent README.md 'puede reintentarse automáticamente una sola vez'
require_absent docs/runtime-evolution.md 'antes del relanzamiento se revierte la reparación'
require_absent docs/game-test-readiness.md 'Una interrupción conserva la fase para una futura decisión segura'

printf 'PASS: documentación coherente con 1.12.3 (41), SQLite v%s y baseline v1.11.0.\n' \
    "$current_schema"
