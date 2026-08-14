#!/usr/bin/env bash
# Materializa exclusivamente el asset público 1.11 sellado en un staging temporal nuevo.
set -Eeuo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
ASSET_NAME="Regression-1.11.0-macos-arm64.tar.gz"
ASSET="$ROOT/build/release-1.11.0/$ASSET_NAME"
SIDECAR="$ASSET.sha256"
EXPECTED_SHA256="47740fbf27e6e792e2f6c5bf0b08a8ca7344f0bd1241adb0ad0e72569c3baa7e"
DEST_APP="${1:-}"
DEST_PARENT=""

fail() { printf 'ERROR: %s\n' "$*" >&2; exit 1; }

[[ -n "$DEST_APP" ]] || fail "uso: $0 DESTINO_NUEVO/Regression.app"
[[ "$DEST_APP" == /* ]] || fail "el destino debe ser absoluto"
[[ "$(basename "$DEST_APP")" == "Regression.app" ]] \
    || fail "el destino debe terminar exactamente en Regression.app"
[[ ! -e "$DEST_APP" && ! -L "$DEST_APP" ]] \
    || fail "el destino Regression.app debe ser nuevo"

DEST_PARENT="$(dirname "$DEST_APP")"
[[ -d "$DEST_PARENT" && ! -L "$DEST_PARENT" ]] \
    || fail "el padre de staging debe existir y ser un directorio físico"
DEST_PARENT_REAL="$(cd "$DEST_PARENT" && pwd -P)"
[[ "$DEST_PARENT_REAL" == "$DEST_PARENT" ]] \
    || fail "el padre de staging no puede contener enlaces ni recorridos léxicos"
[[ "$(basename "$DEST_PARENT_REAL")" == "stage" ]] \
    || fail "el staging público debe vivir en el subdirectorio stage"
WORK_DIR="$(dirname "$DEST_PARENT_REAL")"
WORK_BASENAME="$(basename "$WORK_DIR")"
[[ "$WORK_DIR" == /private/tmp/* && "$WORK_BASENAME" =~ ^regression-release\.[A-Za-z0-9]{6}$ ]] \
    || fail "el staging público debe estar confinado a un mktemp regression-release"
[[ -d "$WORK_DIR" && ! -L "$WORK_DIR" && "$(cd "$WORK_DIR" && pwd -P)" == "$WORK_DIR" ]] \
    || fail "la raíz temporal debe ser física"
[[ "$(stat -f '%u' "$WORK_DIR")" == "$(id -u)" && "$(stat -f '%Lp' "$WORK_DIR")" == "700" ]] \
    || fail "la raíz temporal debe pertenecer al usuario y usar permisos 0700"
[[ "$(stat -f '%u' "$DEST_PARENT_REAL")" == "$(id -u)" \
    && "$(stat -f '%Lp' "$DEST_PARENT_REAL")" == "700" ]] \
    || fail "el padre de staging debe pertenecer al usuario y usar permisos 0700"
[[ -z "$(find "$DEST_PARENT_REAL" -mindepth 1 -print -quit)" ]] \
    || fail "el padre de staging debe estar vacío"

[[ -f "$ASSET" && ! -L "$ASSET" ]] || fail "falta el asset público 1.11 físico"
[[ -f "$SIDECAR" && ! -L "$SIDECAR" ]] || fail "falta el sidecar público 1.11 físico"

# Todo el consumo posterior usa una instantánea privada. Aunque el asset fuente se sustituyese
# mientras cp crea el clon, el resultado queda inmóvil bajo una raíz 0700 y el PIN raw decide si
# esa instantánea completa es la autorizada; no existe una segunda lectura TOCTOU del checkout.
SNAPSHOT_DIR="$WORK_DIR/source"
[[ ! -e "$SNAPSHOT_DIR" && ! -L "$SNAPSHOT_DIR" ]] \
    || fail "el directorio privado de origen debe empezar ausente"
mkdir -m 700 "$SNAPSHOT_DIR"
SNAPSHOT_ASSET="$SNAPSHOT_DIR/$ASSET_NAME"
SNAPSHOT_SIDECAR="$SNAPSHOT_ASSET.sha256"
cp -c "$ASSET" "$SNAPSHOT_ASSET"
cp "$SIDECAR" "$SNAPSHOT_SIDECAR"
chmod 600 "$SNAPSHOT_ASSET" "$SNAPSHOT_SIDECAR"
for snapshot_file in "$SNAPSHOT_ASSET" "$SNAPSHOT_SIDECAR"; do
    [[ -f "$snapshot_file" && ! -L "$snapshot_file" \
        && "$(stat -f '%u' "$snapshot_file")" == "$(id -u)" \
        && "$(stat -f '%Lp' "$snapshot_file")" == "600" ]] \
        || fail "la instantánea pública debe ser un fichero privado 0600"
done

[[ "$(wc -l < "$SNAPSHOT_SIDECAR" | tr -d ' ')" == "1" ]] \
    || fail "el sidecar público debe contener exactamente una entrada"
read -r sidecar_hash sidecar_name sidecar_extra < "$SNAPSHOT_SIDECAR"
[[ -z "${sidecar_extra:-}" && "$sidecar_hash" == "$EXPECTED_SHA256" \
    && "$sidecar_name" == "$ASSET_NAME" ]] \
    || fail "el sidecar público 1.11 no coincide con el contrato compilado"
ACTUAL_SHA256="$(shasum -a 256 "$SNAPSHOT_ASSET" | awk '{print tolower($1)}')"
[[ "$ACTUAL_SHA256" == "$EXPECTED_SHA256" ]] \
    || fail "el hash raw del asset público 1.11 no coincide con el PIN compilado"

# El PIN raw ya hace inmutable el contenido conocido. Esta segunda puerta impide que un cambio
# futuro del asset introduzca rutas absolutas, ajenas al bundle o no normalizadas sin detectarlo.
while IFS= read -r entry; do
    [[ -n "$entry" ]] || fail "el tar contiene una ruta vacía"
    case "$entry" in
        Regression.app|Regression.app/|Regression.app/*) ;;
        *) fail "el tar contiene una ruta fuera de Regression.app: $entry" ;;
    esac
    normalized_entry="${entry%/}"
    case "/$normalized_entry/" in
        */../*|*/./*|*//* ) fail "el tar contiene una ruta no normalizada: $entry" ;;
    esac
done < <(tar -tf "$SNAPSHOT_ASSET")

tar --xattrs --no-mac-metadata -xf "$SNAPSHOT_ASSET" \
    -C "$DEST_PARENT_REAL" --no-same-owner
[[ -d "$DEST_APP" && ! -L "$DEST_APP" ]] \
    || fail "el asset no materializó un Regression.app físico"
[[ -z "$(find "$DEST_PARENT_REAL" -mindepth 1 -maxdepth 1 ! -name Regression.app -print -quit)" ]] \
    || fail "el asset materializó entradas raíz inesperadas"
"$ROOT/build/verify-public-1.11-transition-bundle.sh" candidate "$DEST_APP"

printf 'Input público 1.11 materializado y verificado: %s\n' "$DEST_APP"
