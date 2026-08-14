#!/bin/bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
BIN="${REGRESSION_FIXTURE_BINARY:-$ROOT/.build/arm64-apple-macosx/debug/Regression}"
WORK="$(mktemp -d "${TMPDIR:-/tmp}/regression-visual-fixtures.XXXXXX")"
ACTIVE_PID=""

fail() {
  echo "FAIL: $1" >&2
  exit 1
}

cleanup() {
  if [[ -n "$ACTIVE_PID" ]] && kill -0 "$ACTIVE_PID" 2>/dev/null; then
    kill "$ACTIVE_PID" 2>/dev/null || true
    wait "$ACTIVE_PID" 2>/dev/null || true
  fi
  if [[ "${REGRESSION_KEEP_FIXTURE_ARTIFACTS:-0}" == "1" ]]; then
    echo "Fixture artifacts retained at $WORK" >&2
  else
    rm -rf "$WORK"
  fi
}
trap cleanup EXIT

[[ -x "$BIN" ]] || fail "falta el binario Debug de fixture: $BIN"

ax_dump() {
  osascript <<'APPLESCRIPT'
on collectElements(container, depth)
  if depth is greater than 8 then return ""
  set output to ""
  tell application "System Events"
    try
      set children to UI elements of container
      repeat with element in children
        try
          set output to output & (name of element as text) & linefeed
        end try
        try
          set output to output & (value of attribute "AXIdentifier" of element as text) & linefeed
        end try
        set output to output & my collectElements(element, depth + 1)
      end repeat
    end try
  end tell
  return output
end collectElements

tell application "System Events"
  tell process "Regression"
    if not (exists) then error "Regression no aparece en el árbol AX"
    set output to ""
    repeat with fixtureWindow in windows
      set output to output & (name of fixtureWindow as text) & linefeed
      set output to output & my collectElements(fixtureWindow, 0)
    end repeat
    if output is "" then error "el fixture aún no expone una ventana AX"
    return output
  end tell
end tell
APPLESCRIPT
}

ax_focused_identifier() {
  osascript <<'APPLESCRIPT'
on focusedIdentifier(container, depth)
  if depth is greater than 8 then return ""
  tell application "System Events"
    try
      set children to UI elements of container
      repeat with element in children
        try
          if focused of element is true then return value of attribute "AXIdentifier" of element
        end try
        set nestedIdentifier to my focusedIdentifier(element, depth + 1)
        if nestedIdentifier is not "" then return nestedIdentifier
      end repeat
    end try
  end tell
  return ""
end focusedIdentifier

tell application "System Events"
  tell process "Regression"
    if not (exists) then error "Regression no aparece en el árbol AX"
    repeat with fixtureWindow in windows
      try
        set focusedElement to value of attribute "AXFocusedUIElement" of fixtureWindow
        set focusedIdentifier to value of attribute "AXIdentifier" of focusedElement
        if focusedIdentifier is not "" then return focusedIdentifier
      end try
      set identifier to my focusedIdentifier(fixtureWindow, 0)
      if identifier is not "" then return identifier
    end repeat
    return ""
  end tell
end tell
APPLESCRIPT
}

fixture_window_number() {
  swift "$ROOT/Tests/Shell/fixture_window_probe.swift"
}

capture_fixture_window() {
  local destination="$1"
  local window_number=""
  local attempts=0
  until window_number="$(fixture_window_number 2>/dev/null)" && [[ "$window_number" =~ ^[0-9]+$ ]]; do
    attempts=$((attempts + 1))
    (( attempts < 30 )) || fail "no se obtuvo el identificador AX de la ventana fixture"
    sleep 0.2
  done
  # `-l` recorta exactamente la ventana on-screen identificada por propietario, título y capa;
  # no se admite una captura completa porque el OCR no debe depender de UI ajena ni del escritorio.
  screencapture -x -l "$window_number" "$destination"
  test -s "$destination" || fail "no se pudo capturar la ventana fixture"
}

start_fixture() {
  local state="$1"
  local appearance="$2"
  local text_size="${3:-accessibility5}"
  local focus="${4:-}"
  local scroll="${5:-}"
  local args=(
    "--regression-visual-fixture=$state"
    "--regression-visual-appearance=$appearance"
    "--regression-visual-text-size=$text_size"
  )
  if [[ -n "$focus" ]]; then
    args+=("--regression-visual-focus=$focus")
  fi
  if [[ -n "$scroll" ]]; then
    args+=("--regression-visual-scroll=$scroll")
  fi
  "$BIN" "${args[@]}" >"$WORK/$state-$appearance.log" 2>&1 &
  ACTIVE_PID=$!
  # Espera el siguiente ciclo principal de AppKit antes de inspeccionar la ventana del popover.
  sleep 1
  osascript <<'APPLESCRIPT' >/dev/null
tell application "System Events"
  set frontmost of process "Regression" to true
end tell
APPLESCRIPT
  local attempts=0
  until ax_dump >"$WORK/$state-$appearance.ax" 2>"$WORK/$state-$appearance.ax-error"; do
    attempts=$((attempts + 1))
    (( attempts < 30 )) || {
      cat "$WORK/$state-$appearance.ax-error" >&2 || true
      fail "no se obtuvo el árbol AX del fixture $state/$appearance"
    }
    sleep 0.2
  done
  # ScrollViewReader aplica el ancla del fixture en el siguiente turno de renderización.
  sleep 0.5
  capture_fixture_window "$WORK/$state-$appearance.png"
  swift "$ROOT/Tests/Shell/fixture_text_probe.swift" "$WORK/$state-$appearance.png" \
    >"$WORK/$state-$appearance.ocr"
}

stop_fixture() {
  kill "$ACTIVE_PID" 2>/dev/null || true
  wait "$ACTIVE_PID" 2>/dev/null || true
  ACTIVE_PID=""
}

require_ax() {
  local expected="$1"
  if ! rg -Fq -- "$expected" "$WORK"/*.ax; then
    sed -n '1,120p' "$WORK"/*.ax >&2 || true
    fail "AX no contiene '$expected'"
  fi
}

require_visible() {
  local expected="$1"
  rg -Fq -- "$expected" "$WORK"/*.ocr || fail "la captura no muestra '$expected'"
}

require_in_process_ax_focus() {
  local expected="$1"
  rg -Fq -- "focused=$expected" "$WORK"/*.log \
    || fail "el audit AX nativo no registró foco en '$expected'"
}

# Estados semánticos: todos se ejecutan con el modelo fixture, que no inicia Steam ni Wine.
start_fixture launch-timeline light
require_visible "Registro de lanzamiento"
require_visible "Recibo: telemetría pendiente"
require_visible "Reparación Pantalla completa sin"
require_visible "bordes de Unity"
stop_fixture

start_fixture windows-media-game-failure dark
require_visible "Abrir Steam"
stop_fixture
# El requisito por juego conserva el texto semántico principal en claro, oscuro y ambos modos
# de alto contraste. El contrato estático comprueba que solo el icono usa el color warning.
start_fixture windows-media-game-failure light accessibility5 "" game
require_visible "Windows Media"
require_visible "necesita atención"
stop_fixture
start_fixture windows-media-game-failure dark accessibility5 "" game
require_visible "Windows Media"
require_visible "necesita atención"
stop_fixture
start_fixture windows-media-game-failure high-contrast-light accessibility5 "" game
require_visible "Windows Media"
require_visible "necesita atención"
stop_fixture
start_fixture windows-media-game-failure high-contrast-dark accessibility5 "" game
require_visible "Windows Media"
require_visible "necesita atención"
stop_fixture

start_fixture custody-transfer-error high-contrast-light
require_visible "traslado"
stop_fixture

start_fixture runtime-broken-with-update high-contrast-dark
require_visible "Actualizar y reparar"
stop_fixture

# Contraste: el modo aumentado debe modificar la superficie dentro del MISMO esquema, no solo
# diferir entre Aqua y Dark Aqua.
start_fixture ready light
LIGHT_STANDARD_HASH="$(shasum -a 256 "$WORK/ready-light.png" | awk '{print $1}')"
stop_fixture
start_fixture ready high-contrast-light
LIGHT_HIGH_CONTRAST_HASH="$(shasum -a 256 "$WORK/ready-high-contrast-light.png" | awk '{print $1}')"
stop_fixture
[[ "$LIGHT_STANDARD_HASH" != "$LIGHT_HIGH_CONTRAST_HASH" ]] \
  || fail "alto contraste claro no modifica la superficie clara"
start_fixture ready dark
DARK_STANDARD_HASH="$(shasum -a 256 "$WORK/ready-dark.png" | awk '{print $1}')"
stop_fixture
start_fixture ready high-contrast-dark
DARK_HIGH_CONTRAST_HASH="$(shasum -a 256 "$WORK/ready-high-contrast-dark.png" | awk '{print $1}')"
stop_fixture
[[ "$DARK_STANDARD_HASH" != "$DARK_HIGH_CONTRAST_HASH" ]] \
  || fail "alto contraste oscuro no modifica la superficie oscura"

# Foco AX real: se comprueba el identificador, no solo un FocusState en el código.
start_fixture ready light accessibility5 primary-action
require_in_process_ax_focus "regression.primary-action"
# El modelo fixture consume esta acción exclusivamente en Debug: Return verifica la ruta de
# teclado/defaultAction sin iniciar Steam, Wine, reparaciones ni procesos externos.
osascript <<'APPLESCRIPT' >/dev/null
tell application "System Events"
  tell process "Regression" to key code 36
end tell
APPLESCRIPT
sleep 0.4
capture_fixture_window "$WORK/ready-return.png"
swift "$ROOT/Tests/Shell/fixture_text_probe.swift" "$WORK/ready-return.png" \
  >"$WORK/ready-return.ocr"
tr '\n' ' ' <"$WORK/ready-return.ocr" | rg -Fq -- "acción principal recibida por teclado" \
  || fail "Return no activó la acción principal del fixture"
stop_fixture
start_fixture ready dark accessibility5 game-search
require_in_process_ax_focus "regression.game-search"
stop_fixture

# Custodia elegible comparte la pantalla con Steam, pero no puede reclamar Return mientras
# Steam está disponible. El foco explícito ejerce su propia ruta sin registrar otro defaultAction.
start_fixture custody-eligible light accessibility5 custody-eligible
require_in_process_ax_focus "regression.custody-eligible"
osascript <<'APPLESCRIPT' >/dev/null
tell application "System Events"
  tell process "Regression" to key code 36
end tell
APPLESCRIPT
sleep 0.4
capture_fixture_window "$WORK/custody-return.png"
swift "$ROOT/Tests/Shell/fixture_text_probe.swift" "$WORK/custody-return.png" \
  >"$WORK/custody-return.ocr"
tr '\n' ' ' <"$WORK/custody-return.ocr" | rg -Fq -- "revisión de custodia recibida por teclado" \
  || fail "Return no activó la revisión de custodia del fixture"
stop_fixture

echo "PASS: fixtures visuales y AX ejercitan contraste, foco, timeline, requisitos por juego y CTA de actualización."
