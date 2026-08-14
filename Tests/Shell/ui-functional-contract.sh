#!/bin/bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
MENU="$ROOT/Sources/Regression/MenuBarView.swift"
MODEL="$ROOT/Sources/Regression/RegressionAppModel.swift"
COMPONENTS="$ROOT/Sources/Regression/RegressionUIComponents.swift"
FIXTURES="$ROOT/Sources/Regression/RegressionVisualFixture.swift"

fail() {
  echo "FAIL: $1" >&2
  exit 1
}

require_literal() {
  local file="$1"
  local text="$2"
  rg -Fq -- "$text" "$file" || fail "falta '$text' en ${file#"$ROOT"/}"
}

require_literal "$MODEL" "func repairWindowsMediaComponent(appID: String) async"
require_literal "$MODEL" "var physicalLibraryCustodySizeDescription: String?"
require_literal "$MODEL" "var hasVerifiedNewerRegressionRelease: Bool"
require_literal "$MODEL" "var launchTimelinesByAppID"
require_literal "$MODEL" "repository.reconcileInterruptedLaunchEnvelopes()"
require_literal "$MODEL" "func componentHealthIssueTitle(_ issue: ComponentHealthIssue?) -> String"
require_literal "$COMPONENTS" "enum LibraryCustodyFailurePhase"
require_literal "$COMPONENTS" "case error(phase: LibraryCustodyFailurePhase, detail: String)"
require_literal "$MENU" "Actualizar y reparar"
require_literal "$MENU" "maintenanceIsExpanded = true"
require_literal "$MENU" "model.launchTimeline(for: game)"
require_literal "$MENU" ".focused(\$focusedControl, equals: .primaryAction)"
require_literal "$MENU" ".focused(\$focusedControl, equals: .gameSearch)"
require_literal "$FIXTURES" "case dark"
require_literal "$FIXTURES" "case normal"
require_literal "$FIXTURES" "case accessibility5"
require_literal "$FIXTURES" "enum RegressionVisualFixtureFocus"
require_literal "$FIXTURES" "case custodyEligible = \"custody-eligible\""
require_literal "$MENU" "regression.custody-eligible"
require_literal "$MENU" "DefaultActionWhenGlobalCTAUnavailable"
require_literal "$MENU" "Text(issue.title)"

if rg -Fq -- "110 GB" "$MENU" "$MODEL"; then
  fail "la custodia todavía presenta una cifra fija de tamaño"
fi

if rg -n "appleGPTKNeedsAttention" "$MENU" >/dev/null; then
  fail "GPTK opcional todavía sustituye el estado principal de Steam"
fi

if rg -n "repairWindowsMediaComponent\(\)" "$ROOT/Sources" >/dev/null; then
  fail "Windows Media todavía permite una reparación sin App ID"
fi

if sed -n '/private func ensureSteamRuntimeReadyForLaunch()/,/private func presentComponentFailure/p' "$MODEL" \
  | rg -n "rawValue|String\(describing" >/dev/null; then
  fail "el diagnóstico de ComponentHealth todavía expone valores técnicos sin localizar"
fi

if sed -n '/case \.eligible:/,/case \.preparing:/p' "$MENU" \
  | rg -n '^\s*\.keyboardShortcut\(\.defaultAction\)' >/dev/null; then
  fail "la custodia elegible todavía reclama Return incondicionalmente"
fi

if sed -n '/if let issue = model\.gameLaunchIssue/,/gameLaunchTimeline/p' "$MENU" \
  | rg -n 'Text\(issue\.title\)[[:space:][:print:]]*\.foregroundStyle\(\.orange\)' >/dev/null; then
  fail "el título de requisito todavía usa el color de advertencia de bajo contraste"
fi

# El contrato estático protege la forma de las APIs; el arnés siguiente comprueba la superficie
# renderizada real (OCR), contraste, foco AX nativo, Return, CTA y estados por juego.
"$ROOT/Tests/Shell/visual-fixture-contract.sh"

echo "PASS: UX funcional conserva Steam principal, custodia tipada, reparación por juego y fixtures ejecutables."
