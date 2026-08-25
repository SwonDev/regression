#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
WINE_SOURCE="${REGRESSION_WINE_SOURCE:-$ROOT/sources-26.3.0/wine}"

PATCHES=(
    "$ROOT/patches/wine-26.3.0-winemac-cxpresent-consumer.patch"
    "$ROOT/patches/wine-26.3.0-winemac-explorer-dockless.patch"
    "$ROOT/patches/wine-26.3.0-per-process-graphics-routing.patch"
    "$ROOT/patches/wine-26.3.0-device-notification-invalid-handle.patch"
    "$ROOT/patches/wine-26.3.0-tq2-steam-startup-image.patch"
    "$ROOT/patches/wine-26.3.0-unreal-bootstrap-autodetect.patch"
    "$ROOT/patches/wine-26.3.0-per-process-retina.patch"
    "$ROOT/patches/wine-26.3.0-winemac-gl-surface-resync.patch"
    "$ROOT/patches/wine-26.3.0-windows-media-autodetect.patch"
    "$ROOT/patches/wine-26.3.0-process-scoped-dll-isolation.patch"
    "$ROOT/patches/wine-26.3.0-unity-borderless-focus.patch"
    "$ROOT/patches/wine-26.3.0-macos-linux-uname-sigsys.patch"
    "$ROOT/patches/wine-26.3.0-opengl-core-forward-compat.patch"
    "$ROOT/patches/wine-26.3.0-hashlink-gl-compute-stubs.patch"
    "$ROOT/patches/wine-26.3.0-winemac-restore-focus-on-activate.patch"
)

LEGACY_EXTERNAL_D3DMETAL_MIGRATION="$ROOT/patches/wine-26.3.0-remove-legacy-external-d3dmetal-env.patch"

[[ -d "$WINE_SOURCE" ]] || {
    echo "ERROR: no existe el árbol Wine esperado: $WINE_SOURCE" >&2
    exit 1
}

# El tar FOSS oficial no incluye metadatos Git. En un volumen macOS
# case-insensitive, dejar que `git -C` ascienda hasta el repositorio padre puede
# hacer que `git apply --check` trate este árbol de build como una ruta ignorada
# y devuelva un falso positivo. Anclamos un repositorio efímero dentro del árbol
# Wine para que la aplicabilidad y la reversibilidad se midan contra esos bytes.
wine_source_root="$(cd "$WINE_SOURCE" && pwd -P)"
git_root="$(git -C "$wine_source_root" rev-parse --show-toplevel 2>/dev/null || true)"
if [[ "$git_root" != "$wine_source_root" ]]; then
    git -C "$wine_source_root" init -q
    git_root="$(git -C "$wine_source_root" rev-parse --show-toplevel)"
fi
[[ "$git_root" == "$wine_source_root" ]] || {
    echo "ERROR: git apply no quedó anclado al árbol Wine: $git_root" >&2
    exit 1
}

# Los árboles de trabajo anteriores ya contienen el router base y no pueden
# reaplicar su hunk completo. Migra primero y de forma exacta el único contrato
# retirado; una fuente limpia aún no contiene la función y llega sin mutaciones
# al parche base actualizado.
loader_source="$WINE_SOURCE/dlls/ntdll/unix/loader.c"
if rg -q 'REGRESSION_EXTERNAL_D3DMETAL_(EXECUTABLE|WINE_ROOT)' "$loader_source"; then
    [[ -f "$LEGACY_EXTERNAL_D3DMETAL_MIGRATION" ]] || {
        echo "ERROR: falta la migración del contrato GPTK heredado" >&2
        exit 1
    }
    git -C "$WINE_SOURCE" apply --check --whitespace=error-all \
        "$LEGACY_EXTERNAL_D3DMETAL_MIGRATION" || {
        echo "ERROR: el contrato GPTK heredado no coincide con la migración versionada" >&2
        exit 1
    }
    git -C "$WINE_SOURCE" apply --whitespace=error-all \
        "$LEGACY_EXTERNAL_D3DMETAL_MIGRATION"
    echo "Migración aplicada: $(basename "$LEGACY_EXTERNAL_D3DMETAL_MIGRATION")"
fi

for patch_file in "${PATCHES[@]}"; do
    [[ -f "$patch_file" ]] || {
        echo "ERROR: falta el parche requerido: $patch_file" >&2
        exit 1
    }

    if git -C "$WINE_SOURCE" apply --check --whitespace=error-all "$patch_file" \
        >/dev/null 2>&1; then
        # `git apply` never guesses with fuzz. A patch whose context no longer
        # identifies the intended function is rejected instead of being moved
        # to a merely similar brace block elsewhere in loader.c.
        git -C "$WINE_SOURCE" apply --whitespace=error-all "$patch_file"
        echo "Parche aplicado: $(basename "$patch_file")"
    elif git -C "$WINE_SOURCE" apply --reverse --check --whitespace=error-all "$patch_file" \
        >/dev/null 2>&1; then
        echo "Parche ya aplicado: $(basename "$patch_file")"
    elif [[ "$(basename "$patch_file")" == "wine-26.3.0-per-process-graphics-routing.patch" ]] &&
         rg -q 'static void regression_set_graphics_backend\(void\)' \
             "$WINE_SOURCE/dlls/ntdll/unix/loader.c" &&
         rg -q 'regression_builtin_bootstrap_routes' \
             "$WINE_SOURCE/dlls/ntdll/unix/loader.c" &&
         rg -q 'REGRESSION_EXTERNAL_D3DMETAL_ROUTE_%u_EXECUTABLE' \
             "$WINE_SOURCE/dlls/ntdll/unix/loader.c" &&
         ! rg -q 'REGRESSION_EXTERNAL_D3DMETAL_(EXECUTABLE|WINE_ROOT)' \
             "$WINE_SOURCE/dlls/ntdll/unix/loader.c"; then
        # Los perfiles posteriores añaden rutas dentro del bloque que creó este
        # parche. Eso impide invertir el hunk original aunque su contrato esté
        # íntegro. Verificar los símbolos compilados y la ausencia de la ruta
        # genérica heredada evita aceptar un parche parcial o inseguro.
        echo "Parche ya aplicado y extendido: $(basename "$patch_file")"
    elif [[ "$(basename "$patch_file")" == "wine-26.3.0-tq2-steam-startup-image.patch" ]] &&
         rg -q 'static WCHAR \*regression_tq2_shipping_image' \
             "$WINE_SOURCE/dlls/ntdll/unix/env.c" &&
         rg -q 'return regression_tq2_shipping_image' \
             "$WINE_SOURCE/dlls/ntdll/unix/env.c"; then
        # El autodetector Unreal conserva la receta compilada de TQ2 como
        # fallback, pero envuelve su llamada. Verificar ambas piezas evita
        # confundir la extensión deliberada con un parche incompleto.
        echo "Parche ya aplicado y extendido: $(basename "$patch_file")"
    elif [[ "$(basename "$patch_file")" == "wine-26.3.0-windows-media-autodetect.patch" ]] &&
         rg -q 'static void regression_set_windows_media_compatibility\(void\)' \
             "$WINE_SOURCE/dlls/ntdll/unix/loader.c" &&
         rg -q 'regression_set_windows_media_compatibility\(\);' \
             "$WINE_SOURCE/dlls/ntdll/unix/loader.c"; then
        # La reparación tipada de DLL por proceso se inserta junto al router de
        # medios. Verificar los dos símbolos conserva la idempotencia sin
        # aceptar un parche de GStreamer parcial.
        echo "Parche ya aplicado y extendido: $(basename "$patch_file")"
    elif [[ "$(basename "$patch_file")" == "wine-26.3.0-process-scoped-dll-isolation.patch" ]] &&
         rg -q 'static void regression_set_process_dll_isolation\(void\)' \
             "$WINE_SOURCE/dlls/ntdll/unix/loader.c" &&
         rg -q 'regression_apply_learned_process_repair\(\);' \
             "$WINE_SOURCE/dlls/ntdll/unix/loader.c" &&
         rg -q 'regression_set_process_dll_isolation\(\);' \
             "$WINE_SOURCE/dlls/ntdll/unix/loader.c"; then
        # El parche ABI posterior se inserta inmediatamente junto a esta
        # llamada, por lo que el hunk original ya no es reversible literalmente.
        echo "Parche ya aplicado y extendido: $(basename "$patch_file")"
    elif [[ "$(basename "$patch_file")" == "wine-26.3.0-unreal-bootstrap-autodetect.patch" ]] &&
         rg -q 'static int regression_bootstrap_target_is_safe' \
             "$WINE_SOURCE/dlls/ntdll/unix/loader.c" &&
         rg -q 'static WCHAR \*regression_environment_shipping_image' \
             "$WINE_SOURCE/dlls/ntdll/unix/env.c"; then
        echo "Parche ya aplicado y verificado: $(basename "$patch_file")"
    elif [[ "$(basename "$patch_file")" == "wine-26.3.0-macos-linux-uname-sigsys.patch" ]] &&
         rg -q 'static void regression_set_process_abi_compatibility\(void\)' \
             "$WINE_SOURCE/dlls/ntdll/unix/loader.c" &&
         rg -q 'regression_linux_uname_enabled &&' \
             "$WINE_SOURCE/dlls/ntdll/unix/signal_x86_64.c"; then
        echo "Parche ya aplicado y aislado por proceso: $(basename "$patch_file")"
    else
        echo "ERROR: el parche no está aplicado ni puede aplicarse limpiamente: $patch_file" >&2
        exit 1
    fi
done

# La aplicabilidad textual no basta: varios bloques de loader.c contienen
# cierres casi idénticos. Este parser estructural de llaves garantiza que las
# llamadas solo viven en start_main_thread y en su orden de inicialización.
python3 - "$WINE_SOURCE/dlls/ntdll/unix/loader.c" <<'PY'
from pathlib import Path
import re
import sys

source = Path(sys.argv[1]).read_text(encoding="utf-8")


def function_body(signature: str) -> str:
    match = re.search(signature, source)
    if not match:
        raise SystemExit(f"ERROR: no se encontró la función requerida: {signature}")
    start = source.find("{", match.end())
    if start < 0:
        raise SystemExit(f"ERROR: la función no abre un cuerpo: {signature}")

    depth = 0
    state = "code"
    index = start
    while index < len(source):
        char = source[index]
        next_char = source[index + 1] if index + 1 < len(source) else ""
        if state == "code":
            if char == '"':
                state = "string"
            elif char == "'":
                state = "character"
            elif char == "/" and next_char == "*":
                state = "block-comment"
                index += 1
            elif char == "/" and next_char == "/":
                state = "line-comment"
                index += 1
            elif char == "{":
                depth += 1
            elif char == "}":
                depth -= 1
                if depth == 0:
                    return source[start + 1:index]
        elif state in {"string", "character"}:
            if char == "\\":
                index += 1
            elif (state == "string" and char == '"') or (
                state == "character" and char == "'"
            ):
                state = "code"
        elif state == "block-comment" and char == "*" and next_char == "/":
            state = "code"
            index += 1
        elif state == "line-comment" and char == "\n":
            state = "code"
        index += 1
    raise SystemExit(f"ERROR: cuerpo sin cerrar: {signature}")


start_main = function_body(r"static\s+void\s+start_main_thread\s*\(\s*void\s*\)")
ordered_calls = [
    "regression_set_process_dll_isolation();",
    "regression_set_process_abi_compatibility();",
    "regression_set_windows_media_compatibility();",
    "regression_set_graphics_backend();",
]
positions = []
for call in ordered_calls:
    if source.count(call) != 1:
        raise SystemExit(f"ERROR: {call} debe aparecer exactamente una vez en loader.c")
    position = start_main.find(call)
    if position < 0:
        raise SystemExit(f"ERROR: {call} quedó fuera de start_main_thread")
    positions.append(position)

load_position = start_main.find("load_wow64_ntdll( main_image_info.Machine );")
api_position = start_main.find("load_apiset_dll();")
done_position = start_main.find("server_init_process_done();")
if min(load_position, api_position, done_position) < 0:
    raise SystemExit("ERROR: start_main_thread perdió sus anclas de arranque")
if not (load_position < api_position < positions[0] < positions[1] < positions[2]
        < positions[3] < done_position):
    raise SystemExit("ERROR: el orden de inicialización de Regression es incorrecto")

wine_main = function_body(
    r"DECLSPEC_EXPORT\s+void\s+__wine_main\s*\(\s*int\s+argc\s*,\s*char\s*\*argv\[\]\s*\)"
)
if wine_main.count("regression_redirect_bootstrap( argc, argv );") != 1:
    raise SystemExit("ERROR: el redirector bootstrap no está dentro de __wine_main")
PY

echo "Layout de loader Wine verificado."
