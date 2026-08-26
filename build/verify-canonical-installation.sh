#!/bin/bash
# Comprueba que macOS solo descubre la instalación estable de Regression.
set -euo pipefail

CANONICAL_APP="/Applications/Regression.app"
LSREGISTER="/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister"

fail() {
    printf 'ERROR: %s\n' "$*" >&2
    exit 1
}

[[ -d "$CANONICAL_APP" ]] || fail "falta $CANONICAL_APP"
[[ ! -L "$CANONICAL_APP" ]] || fail "$CANONICAL_APP debe ser un bundle real, no un enlace"

PLIST="$CANONICAL_APP/Contents/Info.plist"
[[ "$(plutil -extract CFBundleIdentifier raw "$PLIST")" == "local.regression.launcher" ]] \
    || fail "el bundle canónico tiene un identificador inesperado"
VERSION="$(plutil -extract CFBundleShortVersionString raw "$PLIST")"
BUILD="$(plutil -extract CFBundleVersion raw "$PLIST")"
codesign --verify --deep --strict "$CANONICAL_APP"

QUERY='kMDItemContentTypeTree == "com.apple.application-bundle" && (kMDItemFSName == "*Regression*.app"cd || kMDItemDisplayName == "*Regression*"cd)'
SPOTLIGHT_APPS="$(mdfind "$QUERY" | sort)"
[[ "$SPOTLIGHT_APPS" == "$CANONICAL_APP" ]] || {
    printf 'Aplicaciones que Spotlight atribuye a Regression:\n%s\n' "$SPOTLIGHT_APPS" >&2
    fail "Spotlight debe devolver únicamente $CANONICAL_APP"
}

if [[ -x "$LSREGISTER" ]]; then
    while IFS= read -r line; do
        path="$(printf '%s\n' "$line" \
            | sed -E 's/^path:[[:space:]]*//; s/[[:space:]]+\(0x[0-9a-fA-F]+\)$//')"
        name="${path##*/}"
        case "$name" in
            Regression*.app|regression*.app)
                [[ "$path" == "$CANONICAL_APP" ]] \
                    || fail "LaunchServices conserva una app no canónica: $path"
                ;;
        esac
    done < <("$LSREGISTER" -dump | grep '^path:')
fi

for applications in /Applications "$HOME/Applications"; do
    [[ -d "$applications" ]] || continue
    while IFS= read -r app; do
        [[ "$app" == "$CANONICAL_APP" ]] \
            || fail "hay otra Regression instalada: $app"
    done < <(find "$applications" -mindepth 1 -maxdepth 1 \
        \( -iname 'Regression.app' -o -iname 'Regression-*.app' \) -print)
done

printf 'Instalación canónica verificada: Regression %s (%s) en %s\n' \
    "$VERSION" "$BUILD" "$CANONICAL_APP"
