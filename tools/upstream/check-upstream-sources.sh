#!/usr/bin/env bash
# Vigila las fuentes de terceros fijadas en gamesir-labs.pins y REPORTA lo que ha
# cambiado desde la última revisión. Es de SOLO LECTURA por diseño:
#
#   - No descarga, no compila, no toca el runtime, la botella ni el bundle.
#   - No mueve ningún PIN: el PIN representa el estado ya revisado por una persona.
#   - Que upstream avance no autoriza nada. Solo abre una revisión que debe pasar
#     la matriz de validación de AGENTS.md antes de integrarse.
#
# Códigos de salida: 0 sin novedades · 10 hay novedades por revisar · 1 error.

set -uo pipefail

RAIZ="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
PINS="${1:-$RAIZ/tools/upstream/gamesir-labs.pins}"

if ! command -v gh >/dev/null 2>&1; then
  printf 'ERROR: se necesita el CLI «gh» autenticado para consultar los upstreams.\n' >&2
  exit 1
fi
if [ ! -f "$PINS" ]; then
  printf 'ERROR: no existe el fichero de PIN: %s\n' "$PINS" >&2
  exit 1
fi

# Clasifica un asunto de commit en el área que le toca a Regression.
clasificar() {
  local asunto="$1"
  case "$asunto" in
    *HACK*|*hack*)                       printf 'parche-por-juego' ;;
    *winemac*|*winemac.drv*)             printf 'winemac.drv' ;;
    *winex11*|*fshack*)                  printf 'winex11-NO-APLICA' ;;
    *d3d12*|*dxil*)                      printf 'd3d12-metal4' ;;
    *d3d9*)                              printf 'd3d9' ;;
    *d3d11*|*dxgi*|*airconv*)            printf 'd3d11-dxgi' ;;
    *loader:*|*WINEDLLDIR*|*per-process*|*overlay*) printf 'overlay-por-proceso' ;;
    *ntdll*|*server:*|*wineserver*)      printf 'nucleo-wine' ;;
    *rosetta*|*Rosetta*|*x87*)           printf 'rosetta-x87' ;;
    ci*|chore*|docs*|test*)              printf 'ruido' ;;
    *)                                   printf 'otros' ;;
  esac
}

total_nuevos=0
repos_con_novedad=0

printf '== Vigilancia de fuentes de terceros ==\n'
printf 'PIN: %s\n\n' "${PINS#$RAIZ/}"

while IFS=$'\t' read -r repo rama pin nota; do
  case "${repo:-}" in ''|'#'*) continue ;; esac

  cabeza="$(gh api "repos/$repo/commits/$rama" --jq '.sha' 2>/dev/null)"
  if [ -z "$cabeza" ]; then
    printf '  !! %s@%s — no se pudo consultar (repo movido, privado o sin red)\n' "$repo" "$rama"
    continue
  fi

  if [ "$pin" = "UPSTREAM" ]; then
    version="$(gh api "repos/$repo/tags" --jq '.[0].name' 2>/dev/null || printf '?')"
    printf '  ·  %-28s %-12s referencia, versión actual: %s\n' "$repo" "$rama" "$version"
    continue
  fi

  if [ "$cabeza" = "$pin" ]; then
    printf '  OK %-28s %-12s sin cambios desde la revisión\n' "$repo" "$rama"
    continue
  fi

  nuevos="$(gh api "repos/$repo/compare/$pin...$cabeza" --jq '.ahead_by' 2>/dev/null || printf '?')"
  printf '  ** %-28s %-12s %s commits nuevos  (%s)\n' "$repo" "$rama" "$nuevos" "$nota"
  printf '     PIN revisado: %s\n     Cabeza ahora: %s\n' "${pin:0:12}" "${cabeza:0:12}"

  gh api "repos/$repo/compare/$pin...$cabeza" \
      --jq '.commits[].commit.message | split("\n")[0]' 2>/dev/null \
    | head -400 | while IFS= read -r linea; do
        [ -z "$linea" ] && continue
        printf '%s\t%s\n' "$(clasificar "$linea")" "$linea"
      done | sort | awk -F'\t' '
        { conteo[$1]++; if (conteo[$1] <= 3) ejemplo[$1] = ejemplo[$1] "\n       - " substr($2,1,88) }
        END { for (a in conteo) printf "     [%s] %d%s\n", a, conteo[a], ejemplo[a] }' \
    | sort

  total_nuevos=$((total_nuevos + ${nuevos//[!0-9]/0}))
  repos_con_novedad=$((repos_con_novedad + 1))
  printf '\n'
done < "$PINS"

printf '\n== Resumen ==\n'
if [ "$repos_con_novedad" -eq 0 ]; then
  printf 'Sin novedades. Todas las fuentes siguen en el estado revisado.\n'
  exit 0
fi

printf '%d fuente(s) con novedades, %d commits nuevos en total.\n' "$repos_con_novedad" "$total_nuevos"
cat <<'AVISO'

Esto NO autoriza ninguna integración. Para aprovechar algo de lo anterior:
  1. Abrir expediente (regressionctl research-open) y anotar la hipótesis.
  2. Portar UNA variable, aislada, con backup previo.
  3. Pasar la fila de la matriz de validación de AGENTS.md, con captura mirada.
  4. Solo entonces mover el PIN de este fichero, y decir de dónde viene el parche.
AVISO
exit 10
