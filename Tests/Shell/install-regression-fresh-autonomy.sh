#!/usr/bin/env bash
# Contrato estático del instalador público: una instalación nueva no importa runtimes ajenos.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
INSTALLER="$ROOT/Scripts/install_regression.sh"

fail()
{
    printf 'FAIL: %s\n' "$*" >&2
    exit 1
}

require_literal()
{
    local description="$1"
    local literal="$2"
    /usr/bin/grep -Fq -- "$literal" "$INSTALLER" \
        || fail "falta el contrato de $description"
}

reject_pattern()
{
    local description="$1"
    local pattern="$2"
    if /usr/bin/grep -Eiq -- "$pattern" "$INSTALLER"; then
        fail "el instalador conserva una dependencia prohibida: $description"
    fi
}

# Solo una instalación anterior de Regression puede aportar el GPTK 3 que se migra al almacén
# persistente. La app instalada después solo vuelve a inspeccionar ese componente exacto.
require_literal "fuente GPTK anterior" \
    "D3DMETAL_SOURCE=\"\$DESTINATION/Contents/SharedSupport/wine-root/lib/apple_gptk\""
require_literal "migración GPTK protegida" \
    '--component 3.0 --recover-existing'
require_literal "destino GPTK externo" \
    'GPTK_RECOVERED_COMPONENT="$APP_SUPPORT/Components/AppleGPTK/3.0"'
require_literal "inspección GPTK tras el cutover" \
    '--component 3.0 --inspect-existing --output-dir "$WORK_DIR/gptk-final-inspection"'

reject_pattern "Whisky" 'Whisky|com\.isaacmarovitz'
reject_pattern "Mythic" 'Mythic'
reject_pattern "CrossOver" 'CrossOver|cxoffice'
reject_pattern "Homebrew GPTK" '/opt/homebrew/.+game-porting-toolkit'
reject_pattern "prefijo Intel GPTK" '/usr/local/.+game-porting-toolkit'
reject_pattern "SharedSupport heredado" 'Regression/SharedSupport'
reject_pattern "búsqueda por candidatos" 'GPTK_CANDIDATES'

# La ausencia de GPTK no aborta: la app guiará la descarga autorizada desde Apple al abrirse.
require_literal "onboarding GPTK desde Apple" \
    'Regression te guiará para instalar Apple GPTK desde Apple cuando la abras.'
# shellcheck disable=SC2016
GPTK_INSTALL_BRANCH="$(/usr/bin/sed -n \
    '/^if \[\[ -d "\$DESTINATION.*D3DMetal\.framework" \]\]; then$/,/^# Los enlaces a perfiles D3DMetal/p' \
    "$INSTALLER")"
[[ -n "$GPTK_INSTALL_BRANCH" ]] || fail "no se pudo aislar la rama GPTK del instalador"
if printf '%s\n' "$GPTK_INSTALL_BRANCH" \
    | /usr/bin/grep -Eq '(^|[[:space:]])(fail|exit)([[:space:]]|$)'; then
    fail "la ausencia de GPTK vuelve a abortar la instalación"
fi

# Steam pertenece a la botella de Regression y procede del instalador oficial de Valve.
require_literal "botella propia" "BOTTLE=\"\$APP_SUPPORT/Bottles/Steam\""
# La preparación ocurre en una botella hermana y solo se promueve al terminar; el runtime
# canónico nunca muta la botella estable a mitad de una instalación.
# shellcheck disable=SC2016
require_literal "WINEPREFIX transaccional propio" '"WINEPREFIX=$BOTTLE_STAGE"'
# shellcheck disable=SC2016
require_literal "ejecutable Steam propio" 'STEAM_EXE="$STEAM_DIR/Steam.exe"'
# shellcheck disable=SC2016
require_literal "steamapps físico propio" 'STEAM_APPS="$STEAM_DIR/steamapps"'
# shellcheck disable=SC2016
require_literal "creación de steamapps propio" 'mkdir -p "$STEAM_APPS"'
require_literal "SteamSetup oficial" \
    'https://cdn.cloudflare.steamstatic.com/client/installer/SteamSetup.exe'
require_literal "instalación silenciosa dentro de Wine" \
    "run_wine_with_timeout 180 \"\$WINE\" \"\$STEAM_SETUP\" /S"

# La botella fresca no puede depender de DLL heredadas de un Mac actualizado. El asset debe
# traer la receta gráfica exacta y el instalador debe promoverla dentro del staging antes del
# cutover, con una postcondición criptográfica sobre los cinco módulos protegidos.
require_literal "semilla gráfica sellada" \
    'BOTTLE_BASELINE_ROOT="$DESTINATION/Contents/SharedSupport/components/steam-bottle-baseline/1"'
require_literal "verificación de la semilla gráfica" \
    'verify_steam_bottle_baseline "$BOTTLE_BASELINE_ROOT"'
require_literal "promoción gráfica en staging" \
    'install_steam_bottle_baseline "$BOTTLE_BASELINE_ROOT" "$BOTTLE_STAGE"'
require_literal "postcondición gráfica de la botella" \
    'verify_installed_steam_bottle_baseline "$BOTTLE_BASELINE_ROOT" "$BOTTLE_STAGE"'

baseline_install_line="$(/usr/bin/grep -nF \
    'install_steam_bottle_baseline "$BOTTLE_BASELINE_ROOT" "$BOTTLE_STAGE"' \
    "$INSTALLER" | /usr/bin/cut -d: -f1)"
bottle_cutover_line="$(/usr/bin/grep -nF 'mv "$BOTTLE_STAGE" "$BOTTLE"' \
    "$INSTALLER" | /usr/bin/cut -d: -f1)"
[[ -n "$baseline_install_line" && -n "$bottle_cutover_line" \
    && "$baseline_install_line" -lt "$bottle_cutover_line" ]] \
    || fail "la semilla gráfica no se instala antes del cutover de la botella"

printf 'PASS: instalación nueva autónoma, GPTK autorizado y Steam propio verificados.\n'
