#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
APP="${1:-$ROOT/Regression.app}"
ENTITLEMENTS="$ROOT/assets/native/Regression.entitlements"

[[ -d "$APP" ]] || {
    echo "ERROR: no existe el bundle que se debe firmar: $APP" >&2
    exit 1
}
[[ -f "$ENTITLEMENTS" ]] || {
    echo "ERROR: falta el contrato de capacidades: $ENTITLEMENTS" >&2
    exit 1
}

# Una identidad Apple estable mantiene el designated requirement entre builds y permite que
# macOS asocie las decisiones de privacidad con Regression en lugar de con un hash efímero.
# En una máquina de desarrollo nueva se puede fijar otra identidad mediante la variable pública
# REGRESSION_CODESIGN_IDENTITY. El valor y la identidad concreta nunca se guardan en el repo.
identity="${REGRESSION_CODESIGN_IDENTITY:-}"
if [[ -z "$identity" ]]; then
    identity="$(security find-identity -v -p codesigning 2>/dev/null \
        | awk '/"Apple Development:/ { print $2; exit }')"
fi

if [[ -n "$identity" && "$identity" != "-" ]]; then
    codesign --force --deep --options runtime --entitlements "$ENTITLEMENTS" \
        --sign "$identity" "$APP"
    signing_mode="development"
else
    codesign --force --deep --entitlements "$ENTITLEMENTS" --sign - "$APP"
    signing_mode="adhoc"
fi

codesign --verify --deep --strict "$APP"

for key in \
    'com\.apple\.security\.automation\.apple-events' \
    'com\.apple\.security\.cs\.allow-unsigned-executable-memory' \
    'com\.apple\.security\.device\.audio-input' \
    'com\.apple\.security\.device\.camera'
do
    value="$(codesign -d --entitlements :- "$APP" 2>/dev/null \
        | plutil -extract "$key" raw -o - -- -)"
    [[ "$value" == "true" ]] || {
        echo "ERROR: la firma final perdió una capacidad requerida: $key" >&2
        exit 1
    }
done

if [[ "$signing_mode" == "development" ]]; then
    requirement="$(codesign -d -r- "$APP" 2>&1)"
    if [[ "$requirement" == *"cdhash"* ]]; then
        echo "ERROR: la firma no produjo una identidad estable entre builds." >&2
        exit 1
    fi
    team_identifier="$(codesign -dv --verbose=4 "$APP" 2>&1 \
        | awk -F= '/^TeamIdentifier=/ { print $2; exit }')"
    [[ -n "$team_identifier" && "$team_identifier" != "not set" ]] || {
        echo "ERROR: la firma estable no contiene TeamIdentifier." >&2
        exit 1
    }
    echo "Regression.app firmada con identidad de desarrollo estable y runtime endurecido."
else
    echo "AVISO: no hay identidad Apple Development disponible; se usó firma ad hoc." >&2
    echo "Los permisos de macOS pueden volver a solicitarse después de cada build." >&2
fi
