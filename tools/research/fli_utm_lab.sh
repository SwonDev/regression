#!/usr/bin/env bash

set -euo pipefail

# Orquestador explícito para el laboratorio aislado de FANTASY LIFE i.
# No autentica Steam, no lee credenciales y no modifica el backend macOS.

LAB_HOST="${FLI_UTM_HOST:-192.168.64.2}"
LAB_USER="${FLI_UTM_USER:-adrianpereradelgado}"
LAB_UID="${FLI_UTM_UID:-501}"
LAB_KEY="${FLI_UTM_KEY:-/Users/adrianpereradelgado/.lima/_config/user}"

LAB_ROOT="/var/lib/regression-fli-utm"
STEAM_HOME="$LAB_ROOT/fli-linux-steam-reference/home"
GAME_SOURCE="/private/tmp/regression-dxvk-linux/fli-game-clone"
GAME_DESTINATION="$LAB_ROOT/fli-game-clone"
FEX_ROOTFS="/var/lib/regression-fli-arm-lab/fex-home/.local/share/fex-emu/RootFS/Fedora_43.sqsh"
FEX_SYSTEM="/usr/bin/FEXBash"
FEX_CANDIDATE_DIR="$LAB_ROOT/fex-fs-gs-preserve-base-v3/bin"
FEX_CANDIDATE="$FEX_CANDIDATE_DIR/FEXBash"
FEX_CANDIDATE_BINARY="$FEX_CANDIDATE_DIR/FEX"
BINFMT_OVERRIDE_DIR="/run/binfmt.d"
BINFMT_MARKER="/run/regression-fli-fex-v3-binfmt"
PROTON_OFFICIAL="/var/lib/regression-fli-arm-lab/official-valve/proton-x86_64"
PROTON_CANDIDATE="$LAB_ROOT/candidates/proton-11-x86-fex-v3-dxvk-1.10.3-fli"
DXVK_1103_OVERLAY="$LAB_ROOT/probes/d3d11/dxvk-1.10.3-upstream"
PROTON_OFFICIAL_MANIFEST_NAME="regression-fli-proton-11-x86-fex-v3.vdf"
PROTON_CANDIDATE_MANIFEST_NAME="regression-fli-proton-11-x86-fex-v3-dxvk1103.vdf"
STEAM_CONFIG="$STEAM_HOME/.local/share/Steam/config/config.vdf"
FLI_APP_ID="2993780"
FLI_COMPAT_TOOL="regression_fli_proton_11_x86_fex_v3_dxvk_1103"

SSH=(
  ssh
  -i "$LAB_KEY"
  -o StrictHostKeyChecking=no
  -o UserKnownHostsFile=/dev/null
  -o IdentitiesOnly=yes
  -o BatchMode=yes
  "$LAB_USER@$LAB_HOST"
)

usage() {
  cat <<'EOF'
Uso: tools/research/fli_utm_lab.sh COMANDO

Comandos de solo lectura:
  status              Estado de VM, GPU, display, Steam y copia del juego.
  verify-game         Verifica tamaño, recuento y binarios críticos del juego.
  install-status      Comprueba el manifiesto oficial sin mostrar datos de cuenta.

Comandos explícitos del laboratorio:
  start-display       Arranca Xorg y Openbox en la VM aislada.
  display-on          Reactiva el conector virtual si DPMS lo apagó.
  stage-game          Reanuda la copia 9p → ext4 sin borrar el destino.
  stage-library       Enlaza el juego en la biblioteca sin crear un manifiesto.
  prepare-steam-library
                      Entrega a Steam la copia aislada del juego, conservando
                      un recibo de propiedad, hashes y rollback.
  stage-proton        Registra Proton 11 + DXVK 1.10.3 como candidato aislado.
  select-proton       Selecciona ese Proton solo para FANTASY LIFE i mediante
                      la preferencia CompatToolMapping que escribe Steam.
  select-binfmt-v3    Activa FEX FS/GS v3 solo mientras el laboratorio está en reposo.
  start-steam-system  Arranca Steam con el FEX de la distribución.
  start-steam-system-visible
                      Igual que start-steam-system, pero muestra la interfaz
                      completa para validar diálogos oficiales de Steam.
  start-steam-v3      Arranca todo Steam/Proton con el candidato FS/GS v3.
  start-steam-v3-visible
                      Igual que start-steam-v3, pero muestra la interfaz tras
                      una autenticación ya existente.
  start-steam-v3-software-ui
                      Igual que start-steam-v3, pero fuerza CEF software solo
                      para recuperar una interfaz Steam negra.
  stop-steam          Detiene solo el cgroup Steam del laboratorio.
  restore-binfmt      Restaura el handler FEX del sistema con la VM en reposo.
  allow-userns        Relaja AppArmor userns solo para este arranque de la VM.
  restore-userns      Restaura inmediatamente la restricción de AppArmor.

`allow-userns` exige FLI_LAB_CONFIRM_USERNS=YES. Nunca se persiste esta
relajación y debe revertirse con `restore-userns` antes de pausar la VM.
EOF
}

select_fli_compat_tool() {
  assert_fex_idle

  local receipt_directory
  receipt_directory="$LAB_ROOT/evidence/steam-compat-tool-$FLI_APP_ID-$(date +%Y%m%d-%H%M%S)"

  remote "set -eu
    test -f '$STEAM_CONFIG'
    manifest='$STEAM_HOME/.local/share/Steam/compatibilitytools.d/$PROTON_CANDIDATE_MANIFEST_NAME'
    test -f \"\$manifest\"
    grep -Fq '\"$FLI_COMPAT_TOOL\"' \"\$manifest\"
    sudo install -d -o '$LAB_USER' -g '$LAB_USER' -m 0700 '$receipt_directory'"

  remote python3 - \
    "$STEAM_CONFIG" \
    "$FLI_APP_ID" \
    "$FLI_COMPAT_TOOL" \
    "$receipt_directory" <<'PY'
import hashlib
import json
import os
from pathlib import Path
import shutil
import stat
import sys

config_path = Path(sys.argv[1])
app_id = sys.argv[2]
tool_name = sys.argv[3]
receipt_directory = Path(sys.argv[4])


class VDFObject:
    def __init__(self, entries, close_start=None):
        self.entries = entries
        self.close_start = close_start


def tokenize(text):
    tokens = []
    index = 0
    while index < len(text):
        char = text[index]
        if char.isspace():
            index += 1
            continue
        if text.startswith("//", index):
            newline = text.find("\n", index + 2)
            index = len(text) if newline == -1 else newline + 1
            continue
        if char in "{}":
            tokens.append((char, char, index, index + 1))
            index += 1
            continue
        if char != '"':
            raise ValueError(f"Token VDF no esperado en byte {index}")

        start = index
        index += 1
        value = []
        while index < len(text):
            char = text[index]
            if char == '"':
                index += 1
                tokens.append(("string", "".join(value), start, index))
                break
            if char == "\\":
                index += 1
                if index >= len(text):
                    raise ValueError("Escape VDF incompleto")
                escaped = text[index]
                value.append({"n": "\n", "r": "\r", "t": "\t"}.get(escaped, escaped))
                index += 1
                continue
            value.append(char)
            index += 1
        else:
            raise ValueError("String VDF sin cerrar")
    return tokens


def parse(text):
    tokens = tokenize(text)
    cursor = 0

    def parse_entries(expect_close):
        nonlocal cursor
        entries = []
        while cursor < len(tokens):
            kind, value, start, _ = tokens[cursor]
            if kind == "}":
                if not expect_close:
                    raise ValueError("Cierre VDF inesperado")
                cursor += 1
                return VDFObject(entries, start)
            if kind != "string":
                raise ValueError(f"Clave VDF no válida en byte {start}")
            key = value
            cursor += 1
            if cursor >= len(tokens):
                raise ValueError(f"Valor ausente para {key}")
            next_kind, next_value, next_start, _ = tokens[cursor]
            if next_kind == "{":
                cursor += 1
                entries.append((key, parse_entries(True)))
            elif next_kind == "string":
                cursor += 1
                entries.append((key, next_value))
            else:
                raise ValueError(f"Valor VDF no válido en byte {next_start}")
        if expect_close:
            raise ValueError("Objeto VDF sin cerrar")
        return VDFObject(entries)

    root = parse_entries(False)
    if cursor != len(tokens):
        raise ValueError("Tokens VDF sin consumir")
    return root


def unique_object(parent, key):
    matches = [value for entry_key, value in parent.entries if entry_key == key]
    if len(matches) != 1 or not isinstance(matches[0], VDFObject):
        raise ValueError(f"Ruta VDF ambigua o ausente: {key}")
    return matches[0]


def child_value(parent, key):
    matches = [value for entry_key, value in parent.entries if entry_key == key]
    if len(matches) != 1:
        raise ValueError(f"Entrada VDF ambigua o ausente: {key}")
    return matches[0]


def steam_object(root):
    node = root
    for component in ("InstallConfigStore", "Software", "Valve", "Steam"):
        node = unique_object(node, component)
    return node


def mapping_for(steam):
    matches = [value for key, value in steam.entries if key == "CompatToolMapping"]
    if len(matches) > 1 or (matches and not isinstance(matches[0], VDFObject)):
        raise ValueError("CompatToolMapping es ambiguo")
    return matches[0] if matches else None


def verify_mapping(text):
    mapping = mapping_for(steam_object(parse(text)))
    if mapping is None:
        raise ValueError("No se creó CompatToolMapping")
    app = unique_object(mapping, app_id)
    expected = {"name": tool_name, "config": "", "priority": "250"}
    actual = {key: child_value(app, key) for key in expected}
    if actual != expected:
        raise ValueError(f"Asignación inesperada: {actual!r}")


original = config_path.read_text(encoding="utf-8")
original_hash = hashlib.sha256(original.encode("utf-8")).hexdigest()
steam = steam_object(parse(original))
mapping = mapping_for(steam)

if mapping is not None:
    existing = [value for key, value in mapping.entries if key == app_id]
    if existing:
        verify_mapping(original)
        print("FLI_COMPAT_TOOL_ALREADY_SELECTED")
        sys.exit(0)
    insertion_object = mapping
    indent = "\t" * 5
else:
    insertion_object = steam
    indent = "\t" * 4

if insertion_object.close_start is None:
    raise ValueError("No se localizó el cierre del objeto VDF")
line_start = original.rfind("\n", 0, insertion_object.close_start) + 1
if original[line_start:insertion_object.close_start].strip():
    raise ValueError("El cierre VDF no ocupa una línea independiente")

if mapping is None:
    block = (
        f'{indent}"CompatToolMapping"\n'
        f'{indent}' + '{\n'
        f'{indent}\t"{app_id}"\n'
        f'{indent}\t' + '{\n'
        f'{indent}\t\t"name"\t\t"{tool_name}"\n'
        f'{indent}\t\t"config"\t\t""\n'
        f'{indent}\t\t"priority"\t\t"250"\n'
        f'{indent}\t' + '}\n'
        f'{indent}' + '}\n'
    )
else:
    block = (
        f'{indent}"{app_id}"\n'
        f'{indent}' + '{\n'
        f'{indent}\t"name"\t\t"{tool_name}"\n'
        f'{indent}\t"config"\t\t""\n'
        f'{indent}\t"priority"\t\t"250"\n'
        f'{indent}' + '}\n'
    )

updated = original[:line_start] + block + original[line_start:]
verify_mapping(updated)
updated_hash = hashlib.sha256(updated.encode("utf-8")).hexdigest()

backup_path = receipt_directory / "config.vdf.before"
shutil.copy2(config_path, backup_path)
os.chmod(backup_path, 0o600)
if hashlib.sha256(backup_path.read_bytes()).hexdigest() != original_hash:
    raise ValueError("El backup de config.vdf no coincide con el original")

file_stat = config_path.stat()
temporary_path = config_path.with_name(f".{config_path.name}.regression-fli-{os.getpid()}")
descriptor = os.open(temporary_path, os.O_WRONLY | os.O_CREAT | os.O_EXCL, stat.S_IMODE(file_stat.st_mode))
try:
    with os.fdopen(descriptor, "w", encoding="utf-8", newline="") as handle:
        handle.write(updated)
        handle.flush()
        os.fsync(handle.fileno())
    os.replace(temporary_path, config_path)
    directory_fd = os.open(config_path.parent, os.O_RDONLY)
    try:
        os.fsync(directory_fd)
    finally:
        os.close(directory_fd)
finally:
    if temporary_path.exists():
        temporary_path.unlink()

receipt = {
    "app_id": app_id,
    "compatibility_tool": tool_name,
    "config": "",
    "priority": "250",
    "original_sha256": original_hash,
    "updated_sha256": updated_hash,
    "backup": str(backup_path),
}
receipt_path = receipt_directory / "receipt.json"
receipt_path.write_text(json.dumps(receipt, indent=2, sort_keys=True) + "\n", encoding="utf-8")
os.chmod(receipt_path, 0o600)

if hashlib.sha256(config_path.read_bytes()).hexdigest() != updated_hash:
    raise ValueError("La escritura final de config.vdf no coincide")

print(f"FLI_COMPAT_TOOL_SELECTED {receipt_directory}")
PY
}

remote() {
  "${SSH[@]}" "$@"
}

assert_fex_idle() {
  remote "set -eu
    if systemctl is-active --quiet regression-fli-steam.service; then
      echo 'Steam sigue activo; no se modificará binfmt_misc.' >&2
      exit 17
    fi
    if pgrep -u '$LAB_UID' -x steam >/dev/null || pgrep -u '$LAB_UID' -x FEXServer >/dev/null; then
      echo 'Quedan procesos Steam/FEX; no se modificará binfmt_misc.' >&2
      exit 18
    fi"
}

prepare_steam_library() {
  assert_fex_idle

  local receipt_directory
  receipt_directory="$LAB_ROOT/evidence/steam-library-ownership-$FLI_APP_ID-$(date +%Y%m%d-%H%M%S)"

  remote "set -eu
    game='$GAME_DESTINATION'
    steamapps='$STEAM_HOME/.local/share/Steam/steamapps'
    link=\"\$steamapps/common/FANTASY LIFE i\"
    test -d \"\$game\"
    test -L \"\$link\"
    test \"\$(readlink \"\$link\")\" = \"\$game\"
    test ! -e \"\$steamapps/appmanifest_$FLI_APP_ID.acf\"

    owners=\"\$(find \"\$game\" -printf '%u:%g\\n' | sort -u)\"
    case \"\$owners\" in
      root:root|'$LAB_USER:$LAB_USER') ;;
      *)
        echo 'La copia tiene propietarios mezclados; no se modificará.' >&2
        printf '%s\\n' \"\$owners\" >&2
        exit 24
        ;;
    esac

    sudo install -d -o '$LAB_USER' -g '$LAB_USER' -m 0700 '$receipt_directory'
    {
      printf 'path=%s\\n' \"\$game\"
      printf 'before_owners=%s\\n' \"\$owners\"
      printf 'rollback=sudo chown -R root:root %q\\n' \"\$game\"
      find \"\$game\" -printf '%u:%g\\n' | sort | uniq -c
      sha256sum \"\$game/EACLauncher.exe\" \"\$game/EasyAntiCheat/Settings.json\"
    } | sudo -u '$LAB_USER' tee '$receipt_directory/before.txt' >/dev/null
    chmod 0600 '$receipt_directory/before.txt'

    if [ \"\$owners\" = 'root:root' ]; then
      sudo chown -R '$LAB_USER:$LAB_USER' \"\$game\"
    fi

    test \"\$(find \"\$game\" -printf '%u:%g\\n' | sort -u)\" = '$LAB_USER:$LAB_USER'
    sudo -u '$LAB_USER' test -w \"\$game\"
    {
      printf 'after_owners=%s\\n' '$LAB_USER:$LAB_USER'
      find \"\$game\" -printf '%u:%g\\n' | sort | uniq -c
      sha256sum \"\$game/EACLauncher.exe\" \"\$game/EasyAntiCheat/Settings.json\"
    } | sudo -u '$LAB_USER' tee '$receipt_directory/after.txt' >/dev/null
    chmod 0600 '$receipt_directory/after.txt'
    test \"\$(tail -n 2 '$receipt_directory/before.txt')\" = \
      \"\$(tail -n 2 '$receipt_directory/after.txt')\"
    echo 'FLI_STEAM_LIBRARY_WRITABLE $receipt_directory'"
}

select_candidate_binfmt() {
  assert_fex_idle
  remote "set -eu
    test -x '$FEX_CANDIDATE_BINARY'
    test \"\$(sha256sum '$FEX_CANDIDATE_BINARY' | awk '{print \$1}')\" = \
      '52dd0d29966fe71b71f6f1b042bdc2254494568261f65dd51d0bee3494d97761'
    test ! -e /etc/binfmt.d/FEX-x86.conf
    test ! -e /etc/binfmt.d/FEX-x86_64.conf
    sudo install -d -m 0755 '$BINFMT_OVERRIDE_DIR'
    for architecture in x86 x86_64; do
      source_file=\"/usr/lib/binfmt.d/FEX-\$architecture.conf\"
      override_file='$BINFMT_OVERRIDE_DIR'/FEX-\$architecture.conf
      test -f \"\$source_file\"
      if [ -e \"\$override_file\" ] && ! grep -Fq ':$FEX_CANDIDATE_BINARY:' \"\$override_file\"; then
        echo \"Override ajeno detectado en \$override_file; no se sobrescribirá.\" >&2
        exit 20
      fi
      sed 's#:/usr/bin/FEX:#:$FEX_CANDIDATE_BINARY:#' \"\$source_file\" | \
        sudo tee \"\$override_file\" >/dev/null
    done
    sudo install -m 0600 /dev/null '$BINFMT_MARKER'
    sudo systemctl restart systemd-binfmt.service
    grep -Fx 'interpreter $FEX_CANDIDATE_BINARY' /proc/sys/fs/binfmt_misc/FEX-x86 >/dev/null
    grep -Fx 'interpreter $FEX_CANDIDATE_BINARY' /proc/sys/fs/binfmt_misc/FEX-x86_64 >/dev/null
    echo 'FLI_FEX_V3_BINFMT_ACTIVE'"
}

restore_system_binfmt() {
  assert_fex_idle
  remote "set -eu
    for architecture in x86 x86_64; do
      override_file='$BINFMT_OVERRIDE_DIR'/FEX-\$architecture.conf
      if [ -e \"\$override_file\" ]; then
        if ! grep -Fq ':$FEX_CANDIDATE_BINARY:' \"\$override_file\"; then
          echo \"Override ajeno detectado en \$override_file; no se eliminará.\" >&2
          exit 21
        fi
        sudo rm \"\$override_file\"
      fi
    done
    sudo rm -f '$BINFMT_MARKER'
    sudo systemctl restart systemd-binfmt.service
    grep -Fx 'interpreter /usr/bin/FEX' /proc/sys/fs/binfmt_misc/FEX-x86 >/dev/null
    grep -Fx 'interpreter /usr/bin/FEX' /proc/sys/fs/binfmt_misc/FEX-x86_64 >/dev/null
    echo 'FLI_SYSTEM_FEX_BINFMT_ACTIVE'"
}

steam_install_status() {
  local manifest
  manifest="$STEAM_HOME/.local/share/Steam/steamapps/appmanifest_$FLI_APP_ID.acf"

  remote python3 - "$manifest" "$GAME_DESTINATION" "$FLI_APP_ID" <<'PY'
import re
import sys
from pathlib import Path

manifest = Path(sys.argv[1])
game = Path(sys.argv[2])
expected_app_id = sys.argv[3]

if not manifest.exists():
    print("FLI_OFFICIAL_INSTALL_PENDING")
    raise SystemExit(0)

text = manifest.read_text(encoding="utf-8", errors="replace")


def value(key):
    match = re.search(r'^\s*"' + re.escape(key) + r'"\s+"([^"]*)"', text, re.MULTILINE)
    return match.group(1) if match else None


app_id = value("appid")
install_dir = value("installdir")
if app_id != expected_app_id:
    raise SystemExit("El manifiesto pertenece a otro App ID")
if install_dir != "FANTASY LIFE i":
    raise SystemExit("El manifiesto apunta a un directorio inesperado")
if not game.is_dir():
    raise SystemExit("La copia local del juego ya no existe")

print("FLI_OFFICIAL_MANIFEST_PRESENT")
for key in ("name", "StateFlags", "BytesToDownload", "BytesDownloaded", "SizeOnDisk"):
    field = value(key)
    if field is not None:
        print(f"{key}={field}")
PY

  remote "set -eu
    sha256sum \
      '$GAME_DESTINATION/EACLauncher.exe' \
      '$GAME_DESTINATION/EasyAntiCheat/Settings.json'"
}

stage_proton_tool() {
  assert_fex_idle
  remote "set -eu
    test -x '$PROTON_OFFICIAL/proton'
    test -f '$PROTON_OFFICIAL/toolmanifest.vdf'
    test -f '$DXVK_1103_OVERLAY/d3d11.dll'
    test -f '$DXVK_1103_OVERLAY/dxgi.dll'
    test \"\$(sha256sum '$PROTON_OFFICIAL/proton' | awk '{print \$1}')\" = \
      'b56de46d7619ebf6975a625e47c202c81baa375ca3576983e221bc9892b0633b'
    test \"\$(sha256sum '$PROTON_OFFICIAL/files/bin/wine' | awk '{print \$1}')\" = \
      '7a6de49c00d8ed2ba55c6967d3643c5ef729f5e562fb51e47e4f41c6cdb5c92a'
    test \"\$(sha256sum '$PROTON_OFFICIAL/files/lib/wine/dxvk/x86_64-windows/d3d11.dll' | awk '{print \$1}')\" = \
      '3b92dee0ac6b332c58ed49639c0ce2950a13e44e380ffcd882394c6b46371ef9'
    test \"\$(sha256sum '$PROTON_OFFICIAL/files/lib/wine/dxvk/x86_64-windows/dxgi.dll' | awk '{print \$1}')\" = \
      '362bf40d396777e2588ec6cbc96248880752a328f7c52608c3dad79ce670428b'
    test \"\$(sha256sum '$DXVK_1103_OVERLAY/d3d11.dll' | awk '{print \$1}')\" = \
      'e78bbb4ff8a34bd81ec127f54514ec9b61ce8e6e0f6b81a4a7d3b51b5f5bebf7'
    test \"\$(sha256sum '$DXVK_1103_OVERLAY/dxgi.dll' | awk '{print \$1}')\" = \
      'e4a06360582d75e4a59fb2ca2c1c8dec3efde910d6fb252b99d125d34819d432'
    if [ ! -e '$PROTON_CANDIDATE' ]; then
      test \"\$(stat -c %d '$PROTON_OFFICIAL')\" = \"\$(stat -c %d '$LAB_ROOT/candidates')\"
      sudo cp -al '$PROTON_OFFICIAL' '$PROTON_CANDIDATE'
      for dll in d3d11.dll dxgi.dll; do
        official_dll='$PROTON_OFFICIAL/files/lib/wine/dxvk/x86_64-windows/'\"\$dll\"
        candidate_dll='$PROTON_CANDIDATE/files/lib/wine/dxvk/x86_64-windows/'\"\$dll\"
        test \"\$(stat -c %i \"\$official_dll\")\" = \"\$(stat -c %i \"\$candidate_dll\")\"
        sudo rm \"\$candidate_dll\"
        sudo install -m 0755 '$DXVK_1103_OVERLAY/'\"\$dll\" \"\$candidate_dll\"
      done
    fi
    test \"\$(sha256sum '$PROTON_CANDIDATE/proton' | awk '{print \$1}')\" = \
      'b56de46d7619ebf6975a625e47c202c81baa375ca3576983e221bc9892b0633b'
    test \"\$(sha256sum '$PROTON_CANDIDATE/files/bin/wine' | awk '{print \$1}')\" = \
      '7a6de49c00d8ed2ba55c6967d3643c5ef729f5e562fb51e47e4f41c6cdb5c92a'
    test \"\$(sha256sum '$PROTON_CANDIDATE/files/lib/wine/dxvk/x86_64-windows/d3d11.dll' | awk '{print \$1}')\" = \
      'e78bbb4ff8a34bd81ec127f54514ec9b61ce8e6e0f6b81a4a7d3b51b5f5bebf7'
    test \"\$(sha256sum '$PROTON_CANDIDATE/files/lib/wine/dxvk/x86_64-windows/dxgi.dll' | awk '{print \$1}')\" = \
      'e4a06360582d75e4a59fb2ca2c1c8dec3efde910d6fb252b99d125d34819d432'
    tool_directory='$STEAM_HOME/.local/share/Steam/compatibilitytools.d'
    manifest=\"\$tool_directory/$PROTON_CANDIDATE_MANIFEST_NAME\"
    install -d -m 0755 \"\$tool_directory\"
    temporary=\$(mktemp \"\$tool_directory/.regression-fli-proton.XXXXXX\")
    trap 'rm -f \"\$temporary\"' EXIT
    cat >\"\$temporary\" <<'EOF'
\"compatibilitytools\"
{
  \"compat_tools\"
  {
    \"regression_fli_proton_11_x86_fex_v3_dxvk_1103\"
    {
      \"install_path\" \"$PROTON_CANDIDATE\"
      \"display_name\" \"Regression FLI — Proton 11 + DXVK 1.10.3\"
      \"from_oslist\" \"windows\"
      \"to_oslist\" \"linux\"
    }
  }
}
EOF
    chmod 0644 \"\$temporary\"
    if [ -e \"\$manifest\" ]; then
      cmp -s \"\$temporary\" \"\$manifest\" || {
        echo \"El manifiesto existente difiere; no se sobrescribirá: \$manifest\" >&2
        exit 23
      }
      rm \"\$temporary\"
    else
      mv \"\$temporary\" \"\$manifest\"
    fi
    trap - EXIT
    grep -Fq '\"install_path\" \"$PROTON_CANDIDATE\"' \"\$manifest\"
    echo 'FLI_PROTON_11_DXVK_1103_TOOL_STAGED'"
}

require_userns_allowed() {
  local value
  value="$(remote "sysctl -n kernel.apparmor_restrict_unprivileged_userns")"
  if [[ "$value" != "0" ]]; then
    echo "AppArmor userns sigue restringido; ejecuta allow-userns de forma explícita." >&2
    exit 78
  fi
}

start_steam() {
  local mode="$1"
  local ui_mode="${2:-default}"
  local visibility="${3:-silent}"
  local fex_bash
  local steam_extra_args=""
  local steam_visibility_args=""

  require_userns_allowed

  case "$mode" in
    system)
      fex_bash="$FEX_SYSTEM"
      restore_system_binfmt
      ;;
    v3)
      fex_bash="$FEX_CANDIDATE"
      stage_proton_tool
      select_candidate_binfmt
      ;;
    *)
      echo "Modo FEX desconocido: $mode" >&2
      exit 64
      ;;
  esac

  case "$ui_mode" in
    default)
      ;;
    software)
      # Flag oficial presente en el binario Steam. Solo afecta a CEF; Proton y
      # el backend gráfico del juego permanecen sin cambios.
      steam_extra_args="-cef-disable-gpu"
      ;;
    *)
      echo "Modo de interfaz Steam desconocido: $ui_mode" >&2
      exit 64
      ;;
  esac

  case "$visibility" in
    silent)
      steam_visibility_args="-silent"
      ;;
    visible)
      ;;
    *)
      echo "Modo de visibilidad Steam desconocido: $visibility" >&2
      exit 64
      ;;
  esac

  if ! remote "set -eu
    test -x '$fex_bash'
    test -x '$STEAM_HOME/.local/share/Steam/steam.sh'
    test -f '$FEX_ROOTFS'
    if systemctl is-active --quiet regression-fli-steam.service; then
      echo 'Steam ya está activo; no se iniciará una segunda instancia.' >&2
      exit 17
    fi
    if pgrep -u '$LAB_UID' -x steam >/dev/null || pgrep -u '$LAB_UID' -x FEXServer >/dev/null; then
      echo 'Quedan procesos Steam/FEX fuera del cgroup esperado; revísalos antes de continuar.' >&2
      exit 18
    fi
    sudo install -d -o '$LAB_USER' -g '$LAB_USER' -m 0700 '/run/user/$LAB_UID'
    sudo systemd-run --unit=regression-fli-steam --collect \
      --property=User='$LAB_USER' \
      --property=Group='$LAB_USER' \
      --property=KillMode=control-group \
      --setenv=DISPLAY=:0 \
      --setenv=HOME='$STEAM_HOME' \
      --setenv=XDG_RUNTIME_DIR='/run/user/$LAB_UID' \
      --setenv=FEX_ROOTFS='$FEX_ROOTFS' \
      '$fex_bash' \
      '$STEAM_HOME/.local/share/Steam/steam.sh' \
      -steamos $steam_visibility_args $steam_extra_args
    for attempt in \$(seq 1 80); do
      if systemctl is-active --quiet regression-fli-steam.service && \
         pgrep -u '$LAB_UID' -x steam >/dev/null; then
        echo 'FLI_STEAM_STARTED'
        exit 0
      fi
      sleep 0.25
    done
    echo 'Steam no alcanzó un proceso verificable.' >&2
    exit 22"; then
    remote "sudo systemctl stop regression-fli-steam.service 2>/dev/null || true"
    if [[ "$mode" == "v3" ]]; then
      restore_system_binfmt
    fi
    return 1
  fi
}

command="${1:-}"
case "$command" in
  status)
    remote "set -u
      echo 'SYSTEM'; uname -a
      echo 'USERNS'; sysctl kernel.apparmor_restrict_unprivileged_userns
      echo 'BINFMT';
      for entry in FEX-x86 FEX-x86_64; do
        echo \"---\$entry\"; sed -n '1,8p' \"/proc/sys/fs/binfmt_misc/\$entry\"
      done
      if [ -e '$BINFMT_MARKER' ]; then echo 'Regression FEX v3 override: active'; fi
      echo 'DISPLAY'; DISPLAY=:0 xrandr --current 2>/dev/null | sed -n '1,35p'
      echo 'VULKAN'; DISPLAY=:0 XDG_RUNTIME_DIR='/run/user/$LAB_UID' vulkaninfo --summary 2>/dev/null | sed -n '1,90p'
      echo 'SERVICES'; systemctl --no-pager --full status \
        regression-fli-xorg.service regression-fli-openbox.service \
        regression-fli-steam.service regression-fli-gamecopy.service 2>&1 | sed -n '1,180p'
      echo 'GAME'; du -sh '$GAME_DESTINATION' 2>/dev/null || true
      echo 'PROTON_TOOL';
      test -f '$STEAM_HOME/.local/share/Steam/compatibilitytools.d/$PROTON_OFFICIAL_MANIFEST_NAME' && \
        sed -n '1,30p' '$STEAM_HOME/.local/share/Steam/compatibilitytools.d/$PROTON_OFFICIAL_MANIFEST_NAME' || true
      test -f '$STEAM_HOME/.local/share/Steam/compatibilitytools.d/$PROTON_CANDIDATE_MANIFEST_NAME' && \
        sed -n '1,30p' '$STEAM_HOME/.local/share/Steam/compatibilitytools.d/$PROTON_CANDIDATE_MANIFEST_NAME' || true
      echo 'DISK'; df -h '$LAB_ROOT'"
    ;;

  verify-game)
    remote "set -eu
      test -d '$GAME_DESTINATION'
      echo 'SIZE'; du -sb '$GAME_DESTINATION'
      echo 'FILES'; find '$GAME_DESTINATION' -type f | wc -l
      echo 'LINKS'; find '$GAME_DESTINATION' -type l | wc -l
      echo 'CRITICAL_HASHES'
      sha256sum \
        '$GAME_DESTINATION/EACLauncher.exe' \
        '$GAME_DESTINATION/EasyAntiCheat/Settings.json'
      test \"\$(sha256sum '$GAME_DESTINATION/EACLauncher.exe' | awk '{print \$1}')\" = \
        'e86f518b447a90790f8458bd7be36bc42ae3cdaf723e6b9efcdcea3b544fd95c'
      test \"\$(sha256sum '$GAME_DESTINATION/EasyAntiCheat/Settings.json' | awk '{print \$1}')\" = \
        '604da8db104b1e4de245bbdf8fdb43cc71b9fa902975f7168f96974e98c85cfe'
      echo 'FLI_GAME_CLONE_OK'"
    ;;

  install-status)
    steam_install_status
    ;;

  start-display)
    remote "set -eu
      sudo install -d -o '$LAB_USER' -g '$LAB_USER' -m 0700 '/run/user/$LAB_UID'
      if ! systemctl is-active --quiet regression-fli-xorg.service; then
        sudo systemd-run --unit=regression-fli-xorg --collect \
          /usr/lib/xorg/Xorg :0 vt1 -nolisten tcp -noreset \
          -logfile '$LAB_ROOT/Xorg.0.log' -verbose 3
      fi
      for attempt in \$(seq 1 40); do
        DISPLAY=:0 xrandr --current >/dev/null 2>&1 && break
        sleep 0.25
      done
      DISPLAY=:0 xrandr --current >/dev/null
      if ! systemctl is-active --quiet regression-fli-openbox.service; then
        sudo systemd-run --unit=regression-fli-openbox --collect \
          --property=User='$LAB_USER' --property=Group='$LAB_USER' \
          --setenv=DISPLAY=:0 --setenv=HOME='$STEAM_HOME' \
          --setenv=XDG_RUNTIME_DIR='/run/user/$LAB_UID' \
          /usr/bin/dbus-run-session -- /usr/bin/openbox-session
      fi
      DISPLAY=:0 xset s off -dpms
      DISPLAY=:0 xset dpms force on
      echo 'FLI_DISPLAY_OK'"
    ;;

  display-on)
    remote "DISPLAY=:0 xset s off -dpms; DISPLAY=:0 xset dpms force on; DISPLAY=:0 xrandr --current | sed -n '1,20p'"
    ;;

  stage-game)
    remote "set -eu
      test -d '$GAME_SOURCE'
      sudo install -d -m 0755 '$GAME_DESTINATION'
      if systemctl is-active --quiet regression-fli-gamecopy.service; then
        echo 'La copia ya está activa.'
        exit 0
      fi
      sudo systemd-run --unit=regression-fli-gamecopy --collect \
        --property=Nice=10 \
        --property=IOSchedulingClass=best-effort \
        --property=IOSchedulingPriority=6 \
        /usr/bin/rsync -rt --info=stats2 '$GAME_SOURCE/' '$GAME_DESTINATION/'"
    ;;

  stage-library)
    remote "set -eu
      test -d '$GAME_DESTINATION'
      steamapps='$STEAM_HOME/.local/share/Steam/steamapps'
      sudo install -d -o '$LAB_USER' -g '$LAB_USER' -m 0755 \"\$steamapps\"
      sudo install -d -o '$LAB_USER' -g '$LAB_USER' -m 0755 \"\$steamapps/common\"
      link=\"\$steamapps/common/FANTASY LIFE i\"
      if [ -e \"\$link\" ] || [ -L \"\$link\" ]; then
        test \"\$(readlink \"\$link\")\" = '$GAME_DESTINATION'
      else
        sudo -u '$LAB_USER' ln -s '$GAME_DESTINATION' \"\$link\"
      fi
      test ! -e \"\$steamapps/appmanifest_2993780.acf\"
      echo 'FLI_LIBRARY_STAGED_WITHOUT_MANIFEST'"
    ;;

  prepare-steam-library)
    prepare_steam_library
    ;;

  stage-proton)
    stage_proton_tool
    ;;

  select-proton)
    select_fli_compat_tool
    ;;

  select-binfmt-v3)
    select_candidate_binfmt
    ;;

  start-steam-system)
    start_steam system
    ;;

  start-steam-system-visible)
    start_steam system default visible
    ;;

  start-steam-v3)
    start_steam v3
    ;;

  start-steam-v3-visible)
    start_steam v3 default visible
    ;;

  start-steam-v3-software-ui)
    start_steam v3 software
    ;;

  stop-steam)
    remote "set -eu
      if systemctl is-active --quiet regression-fli-steam.service; then
        sudo systemctl stop regression-fli-steam.service
      fi
      for attempt in \$(seq 1 40); do
        if ! pgrep -u '$LAB_UID' -x steam >/dev/null && ! pgrep -u '$LAB_UID' -x FEXServer >/dev/null; then
          echo 'FLI_STEAM_STOPPED'
          exit 0
        fi
        sleep 0.25
      done
      echo 'Quedan procesos Steam/FEX; no se forzará su terminación.' >&2
      exit 19"
    restore_system_binfmt
    ;;

  restore-binfmt)
    restore_system_binfmt
    ;;

  allow-userns)
    if [[ "${FLI_LAB_CONFIRM_USERNS:-}" != "YES" ]]; then
      echo "Operación rechazada. Repite con FLI_LAB_CONFIRM_USERNS=YES." >&2
      exit 64
    fi
    remote "sudo sysctl -w kernel.apparmor_restrict_unprivileged_userns=0"
    ;;

  restore-userns)
    remote "sudo sysctl -w kernel.apparmor_restrict_unprivileged_userns=1"
    ;;

  -h|--help|help|'')
    usage
    ;;

  *)
    echo "Comando desconocido: $command" >&2
    usage >&2
    exit 64
    ;;
esac
