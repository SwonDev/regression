#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
SOURCE_PAYLOAD="$ROOT/build/windows-media-component/1"
WORK_DIR="$(mktemp -d /private/tmp/regression-windows-media-test.XXXXXX)"
APP="$WORK_DIR/Regression.app"
INSTALLER="$APP/Contents/SharedSupport/bin/install-windows-media-component"
TEST_HOME="$WORK_DIR/home"
APPLICATION_SUPPORT="$TEST_HOME/Library/Application Support/Regression"
COMPONENT_ROOT="$APPLICATION_SUPPORT/Components/WindowsMedia/1"
RECEIPT="$APPLICATION_SUPPORT/Receipts/Components/WindowsMedia/1-link-repair.receipt"
SYNC_HELPER="$WORK_DIR/durable-sync"
ENGINE="$APP/Contents/MacOS/regression-engine"
WINE="$APP/Contents/SharedSupport/wine-root/bin/wine"
STEAM="$APPLICATION_SUPPORT/Bottles/Steam/drive_c/Program Files (x86)/Steam/Steam.exe"

cleanup()
{
    /usr/bin/find "$WORK_DIR" -depth -delete
}
trap cleanup EXIT

fail()
{
    printf 'FAIL: %s\n' "$*" >&2
    exit 1
}

expect_failure()
{
    local description="$1"
    local expected="$2"
    shift 2
    local output status

    set +e
    output="$("$@" 2>&1)"
    status=$?
    set -e
    [[ $status -ne 0 ]] || fail "$description debía fallar"
    /usr/bin/grep -Fq -- "$expected" <<< "$output" \
        || fail "$description falló sin el diagnóstico esperado: $output"
}

reset_fixture()
{
    /usr/bin/find "$APP" -depth -delete 2>/dev/null || true
    /usr/bin/find "$TEST_HOME" -depth -delete 2>/dev/null || true
    /bin/mkdir -p "$APP/Contents/MacOS" "$APP/Contents/SharedSupport/bin" \
        "$APP/Contents/SharedSupport/components/windows-media" \
        "$APP/Contents/SharedSupport/wine-root/bin" \
        "$(/usr/bin/dirname "$STEAM")"
    /usr/bin/ditto "$SOURCE_PAYLOAD" \
        "$APP/Contents/SharedSupport/components/windows-media/1"
    /usr/bin/install -m 755 "$ROOT/Scripts/install_windows_media_component.sh" "$INSTALLER"
    /usr/bin/install -m 755 "$ROOT/Scripts/regression-engine.sh" "$ENGINE"
    /usr/bin/install -m 755 "$SYNC_HELPER" \
        "$APP/Contents/SharedSupport/bin/regressionctl"
    /usr/bin/printf '%s\n' '#!/bin/bash' 'exit 0' > "$WINE"
    /bin/chmod 755 "$WINE"
    /usr/bin/touch "$STEAM"
    printf 'wine-root-sentinel\n' > \
        "$APP/Contents/SharedSupport/wine-root/sentinel"
    printf 'bottle-sentinel\n' > \
        "$APPLICATION_SUPPORT/Bottles/Steam/sentinel"
}

run_installer()
{
    env HOME="$TEST_HOME" \
        REGRESSION_WINDOWS_MEDIA_INTERNAL_TEST_VARIANT=public \
        REGRESSION_WINDOWS_MEDIA_INTERNAL_TEST_SYNC_HELPER="$SYNC_HELPER" \
        REGRESSION_WINDOWS_MEDIA_TEST_APP_ROOT="$APP" \
        "$INSTALLER" "$@" \
        --lease-token 11111111-1111-4111-8111-111111111111 \
        --lease-owner-pid $$
}

[[ -d "$SOURCE_PAYLOAD" ]] || fail "falta el payload Windows Media focal"
/bin/cat > "$SYNC_HELPER" <<'PYTHON'
#!/usr/bin/python3
import os
import sys

command = sys.argv[1]
if command == "durable-sync":
    for path in sys.argv[2:]:
        descriptor = os.open(path, os.O_RDONLY | os.O_NOFOLLOW)
        try:
            os.fsync(descriptor)
        finally:
            os.close(descriptor)
elif command == "windows-media-repair-plan":
    print("REGRESSION_WINDOWS_MEDIA_PLAN=repair")
    print("REGRESSION_WINDOWS_MEDIA_LEASE=11111111-1111-4111-8111-111111111111")
elif command == "windows-media-pending-recovery-app-id":
    intent = os.path.join(
        os.environ["HOME"],
        "Library/Application Support/Regression/Transactions/WindowsMedia/1-link-repair.intent",
    )
    if os.path.exists(intent):
        values = dict(line.split("=", 1) for line in open(intent, encoding="utf-8").read().splitlines())
        print("REGRESSION_WINDOWS_MEDIA_PENDING_APP_ID=" + values["app_id"])
    else:
        print("REGRESSION_WINDOWS_MEDIA_PENDING_APP_ID=none")
elif command == "consume-windows-media-repair-lease":
    pass
elif command == "release-windows-media-lease":
    pass
elif command == "acquire-windows-media-runtime-lease":
    print("REGRESSION_WINDOWS_MEDIA_RUNTIME_LEASE=22222222-2222-4222-8222-222222222222")
elif command == "windows-media-private-file":
    support = os.path.join(os.environ["HOME"], "Library/Application Support/Regression")
    paths = {
        "intent": os.path.join(support, "Transactions/WindowsMedia/1-link-repair.intent"),
        "receipt": os.path.join(support, "Receipts/Components/WindowsMedia/1-link-repair.receipt"),
    }
    operation = sys.argv[2]
    path = paths[sys.argv[3]]
    if operation == "prepare":
        root_descriptor = os.open(support, os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW)
        try:
            for relative in (
                "Components/WindowsMedia",
                "Backups/Components/WindowsMedia",
                "Transactions/WindowsMedia",
                "Receipts/Components/WindowsMedia",
            ):
                current = os.dup(root_descriptor)
                try:
                    for component in relative.split("/"):
                        try:
                            os.mkdir(component, mode=0o700, dir_fd=current)
                        except FileExistsError:
                            pass
                        following = os.open(
                            component,
                            os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW,
                            dir_fd=current,
                        )
                        metadata = os.fstat(following)
                        if metadata.st_uid != os.getuid() or metadata.st_mode & 0o7777 != 0o700:
                            os.close(following)
                            raise OSError("unsafe managed directory")
                        os.close(current)
                        current = following
                finally:
                    os.close(current)
        finally:
            os.close(root_descriptor)
    elif operation == "read":
        descriptor = os.open(path, os.O_RDONLY | os.O_NOFOLLOW)
        try:
            sys.stdout.buffer.write(os.read(descriptor, 8192))
        finally:
            os.close(descriptor)
    elif operation == "write":
        os.makedirs(os.path.dirname(path), mode=0o700, exist_ok=True)
        temporary = path + ".temporary"
        descriptor = os.open(temporary, os.O_WRONLY | os.O_CREAT | os.O_EXCL | os.O_NOFOLLOW, 0o600)
        try:
            os.write(descriptor, sys.stdin.buffer.read())
            os.fsync(descriptor)
        finally:
            os.close(descriptor)
        os.replace(temporary, path)
        parent = os.open(os.path.dirname(path), os.O_RDONLY | os.O_DIRECTORY)
        try:
            os.fsync(parent)
        finally:
            os.close(parent)
    elif operation == "remove":
        os.unlink(path)
        parent = os.open(os.path.dirname(path), os.O_RDONLY | os.O_DIRECTORY)
        try:
            os.fsync(parent)
        finally:
            os.close(parent)
elif command == "windows-media-anchored-link":
    support = os.path.join(os.environ["HOME"], "Library/Application Support/Regression")
    component = os.path.join(support, "Components/WindowsMedia")
    backup = os.path.join(support, "Backups/Components/WindowsMedia")
    os.makedirs(component, mode=0o700, exist_ok=True)
    os.makedirs(backup, mode=0o700, exist_ok=True)
    operation = sys.argv[2]
    value = sys.argv[3] if len(sys.argv) > 3 else None
    if operation == "create-stage":
        app = os.environ["REGRESSION_WINDOWS_MEDIA_TEST_APP_ROOT"]
        os.symlink(os.path.join(app, "Contents/SharedSupport/components/windows-media/1"), os.path.join(component, value))
    elif operation == "backup-current":
        os.rename(os.path.join(component, "1"), os.path.join(backup, value))
    elif operation == "commit-stage":
        os.rename(os.path.join(component, value), os.path.join(component, "1"))
    elif operation == "restore-backup":
        os.rename(os.path.join(backup, value), os.path.join(component, "1"))
    elif operation == "remove-stage":
        os.unlink(os.path.join(component, value))
    elif operation == "remove-current":
        os.unlink(os.path.join(component, "1"))
elif command == "unreal-bootstrap-routes":
    pass
elif command == "prepare-launch-state":
    print("REGRESSION_REPAIR_STATE=no-op")
else:
    raise SystemExit(1)
PYTHON
/bin/chmod 700 "$SYNC_HELPER"
for digest in \
    ac662661fb3384c6ad100066391cab209f9de60b2e129fb92e07365ee6fe9bb1 \
    da8ba98d99d157f981ef3a2472dc9d74c9ce4673ef126bdd61851b9dd21dedb3
do
    /usr/bin/grep -Fq "$digest" "$ROOT/Sources/RegressionCore/ComponentHealth.swift" \
        || fail "ComponentHealth no contiene la autoridad compilada $digest"
    /usr/bin/grep -Fq "$digest" "$ROOT/Scripts/install_windows_media_component.sh" \
        || fail "el instalador no comparte la autoridad compilada $digest"
done

reset_fixture
SOURCE_ROOT="$APP/Contents/SharedSupport/components/windows-media/1"
expect_failure "mutación sin App ID" "--app-id es obligatorio" run_installer
expect_failure "App ID con cero inicial" "Steam App ID canónico" \
    run_installer --app-id 0347940
expect_failure "App ID fuera de UInt32" "Steam App ID canónico" \
    run_installer --app-id 4294967296
[[ ! -e "$COMPONENT_ROOT" && ! -L "$COMPONENT_ROOT" ]] \
    || fail "una autorización inválida no debe mutar el componente"

printf 'component=media-drifted\n' > "$SOURCE_ROOT/BUILD.txt"
(
    cd "$SOURCE_ROOT"
    /usr/bin/find . -type f ! -name 'manifest.sha256*' -print \
        | LC_ALL=C /usr/bin/sort \
        | /usr/bin/xargs /usr/bin/shasum -a 256 > manifest.sha256.new
    /bin/mv manifest.sha256.new manifest.sha256
    /usr/bin/shasum -a 256 -c manifest.sha256 >/dev/null
) || fail "el fixture derivado debía ser autoconsistente"
expect_failure "manifest autoconsistente no compilado" "autoridad compilada" \
    run_installer --app-id 347940
[[ ! -e "$COMPONENT_ROOT" && ! -L "$COMPONENT_ROOT" ]] \
    || fail "un manifest no autorizado no debe instalarse"

reset_fixture
OUTSIDE="$WORK_DIR/outside-components"
/bin/mkdir -p "$OUTSIDE" "$APPLICATION_SUPPORT"
/bin/ln -s "$OUTSIDE" "$APPLICATION_SUPPORT/Components"
expect_failure "cadena administrada con symlink" \
    "no se pudo preparar el almacenamiento Windows Media de forma anclada" \
    run_installer --app-id 347940
[[ -z "$(/bin/ls -A "$OUTSIDE")" ]] || fail "el destino externo no debía mutarse"

reset_fixture
OLD_TARGET="$WORK_DIR/old-windows-media"
/bin/mkdir -p "$OLD_TARGET" "$(/usr/bin/dirname "$COMPONENT_ROOT")"
/bin/chmod 700 "$APPLICATION_SUPPORT/Components" "$(/usr/bin/dirname "$COMPONENT_ROOT")"
/bin/ln -s "$OLD_TARGET" "$COMPONENT_ROOT"
old_raw_target="$(/usr/bin/readlink "$COMPONENT_ROOT")"
wine_before="$(/usr/bin/shasum -a 256 \
    "$APP/Contents/SharedSupport/wine-root/sentinel" | /usr/bin/awk '{print $1}')"
bottle_before="$(/usr/bin/shasum -a 256 \
    "$APPLICATION_SUPPORT/Bottles/Steam/sentinel" | /usr/bin/awk '{print $1}')"
expect_failure "fallo posterior al cutover" "fallo interno posterior al cutover" \
    env HOME="$TEST_HOME" \
        REGRESSION_WINDOWS_MEDIA_INTERNAL_TEST_VARIANT=public \
        REGRESSION_WINDOWS_MEDIA_INTERNAL_TEST_FAULT=post-swap \
        REGRESSION_WINDOWS_MEDIA_INTERNAL_TEST_SYNC_HELPER="$SYNC_HELPER" \
        REGRESSION_WINDOWS_MEDIA_TEST_APP_ROOT="$APP" \
        "$INSTALLER" --app-id 347940 \
            --lease-token 11111111-1111-4111-8111-111111111111 --lease-owner-pid $$
[[ -L "$COMPONENT_ROOT" ]] || fail "el enlace anterior debía restaurarse"
[[ "$(/usr/bin/readlink "$COMPONENT_ROOT")" == "$old_raw_target" ]] \
    || fail "el rollback no restauró el destino anterior exacto"
[[ ! -f "$RECEIPT" ]] \
    || ! /usr/bin/grep -Fq 'result=succeeded' "$RECEIPT" \
    || fail "un rollback no puede emitir recibo de éxito"
[[ "$(/usr/bin/shasum -a 256 "$APP/Contents/SharedSupport/wine-root/sentinel" \
    | /usr/bin/awk '{print $1}')" == "$wine_before" ]] \
    || fail "la reparación alteró el Wine root"
[[ "$(/usr/bin/shasum -a 256 "$APPLICATION_SUPPORT/Bottles/Steam/sentinel" \
    | /usr/bin/awk '{print $1}')" == "$bottle_before" ]] \
    || fail "la reparación alteró la botella"

reset_fixture
run_installer --app-id 347940 >/dev/null
[[ -L "$COMPONENT_ROOT" ]] || fail "faltó el enlace versionado instalado"
[[ "$(/usr/bin/readlink "$COMPONENT_ROOT")" == \
    "$APP/Contents/SharedSupport/components/windows-media/1" ]] \
    || fail "el enlace instalado no apunta al payload sellado"
[[ -f "$RECEIPT" && ! -L "$RECEIPT" ]] || fail "faltó el recibo operativo tipado"
for literal in \
    'schema=1' \
    'kind=trusted-component-link-repair' \
    'component_id=windows-media-gstreamer' \
    'component_version=1' \
    'app_id=347940' \
    'result=succeeded'
do
    /usr/bin/grep -Fxq "$literal" "$RECEIPT" \
        || fail "el recibo no contiene: $literal"
done
run_installer --verify-only >/dev/null

for phase in \
    after-prepared-wal after-prepared \
    after-backed-up-wal after-backed-up \
    after-swapped-wal after-swapped
do
    reset_fixture
    OLD_TARGET="$WORK_DIR/old-$phase"
    /bin/mkdir -p "$OLD_TARGET" "$(/usr/bin/dirname "$COMPONENT_ROOT")"
    /bin/chmod 700 "$APPLICATION_SUPPORT/Components" "$(/usr/bin/dirname "$COMPONENT_ROOT")"
    /bin/ln -s "$OLD_TARGET" "$COMPONENT_ROOT"
    wine_before="$(/usr/bin/shasum -a 256 \
        "$APP/Contents/SharedSupport/wine-root/sentinel" | /usr/bin/awk '{print $1}')"
    bottle_before="$(/usr/bin/shasum -a 256 \
        "$APPLICATION_SUPPORT/Bottles/Steam/sentinel" | /usr/bin/awk '{print $1}')"
    set +e
    env HOME="$TEST_HOME" \
        REGRESSION_WINDOWS_MEDIA_INTERNAL_TEST_VARIANT=public \
        REGRESSION_WINDOWS_MEDIA_INTERNAL_TEST_FAULT="$phase" \
        REGRESSION_WINDOWS_MEDIA_INTERNAL_TEST_SYNC_HELPER="$SYNC_HELPER" \
        REGRESSION_WINDOWS_MEDIA_TEST_APP_ROOT="$APP" \
        "$INSTALLER" --app-id 347940 \
            --lease-token 11111111-1111-4111-8111-111111111111 \
            --lease-owner-pid $$ >/dev/null 2>&1
    crash_status=$?
    set -e
    [[ $crash_status -ne 0 ]] || fail "$phase debía interrumpirse"
    if [[ "$phase" == "after-backed-up" ]]; then
        env HOME="$TEST_HOME" \
            REGRESSION_WINDOWS_MEDIA_INTERNAL_TEST_VARIANT=public \
            REGRESSION_WINDOWS_MEDIA_INTERNAL_TEST_SYNC_HELPER="$SYNC_HELPER" \
            REGRESSION_WINDOWS_MEDIA_TEST_APP_ROOT="$APP" \
            "$ENGINE" >/dev/null
    else
        env HOME="$TEST_HOME" \
            REGRESSION_WINDOWS_MEDIA_INTERNAL_TEST_VARIANT=public \
            REGRESSION_WINDOWS_MEDIA_INTERNAL_TEST_SYNC_HELPER="$SYNC_HELPER" \
            REGRESSION_WINDOWS_MEDIA_TEST_APP_ROOT="$APP" \
            "$ENGINE" -applaunch 347940 >/dev/null
    fi
    run_installer --app-id 347940 >/dev/null
    run_installer --verify-only >/dev/null
    [[ ! -e "$APPLICATION_SUPPORT/Transactions/WindowsMedia/1-link-repair.intent" ]] \
        || fail "$phase dejó una intención sin reconciliar"
    [[ -L "$COMPONENT_ROOT" ]] || fail "$phase no terminó con enlace verificable"
    [[ "$wine_before" == "$(/usr/bin/shasum -a 256 \
        "$APP/Contents/SharedSupport/wine-root/sentinel" | /usr/bin/awk '{print $1}')" ]] \
        || fail "$phase alteró el Wine root"
    [[ "$bottle_before" == "$(/usr/bin/shasum -a 256 \
        "$APPLICATION_SUPPORT/Bottles/Steam/sentinel" | /usr/bin/awk '{print $1}')" ]] \
        || fail "$phase alteró la botella"
done

reset_fixture
set +e
env HOME="$TEST_HOME" \
    REGRESSION_WINDOWS_MEDIA_INTERNAL_TEST_VARIANT=public \
    REGRESSION_WINDOWS_MEDIA_INTERNAL_TEST_FAULT=after-prepared \
    REGRESSION_WINDOWS_MEDIA_INTERNAL_TEST_SYNC_HELPER="$SYNC_HELPER" \
    REGRESSION_WINDOWS_MEDIA_TEST_APP_ROOT="$APP" \
    "$INSTALLER" --app-id 347940 \
        --lease-token 11111111-1111-4111-8111-111111111111 \
        --lease-owner-pid $$ >/dev/null 2>&1
mismatch_crash_status=$?
set -e
[[ $mismatch_crash_status -ne 0 ]] || fail "el fixture de WAL cruzado debía interrumpirse"
expect_failure \
    "launch explícito no puede reconciliar WAL de otro App ID" \
    "Windows Media dejó un estado no verificable" \
    env HOME="$TEST_HOME" \
        REGRESSION_WINDOWS_MEDIA_INTERNAL_TEST_VARIANT=public \
        REGRESSION_WINDOWS_MEDIA_INTERNAL_TEST_SYNC_HELPER="$SYNC_HELPER" \
        REGRESSION_WINDOWS_MEDIA_TEST_APP_ROOT="$APP" \
        "$ENGINE" -applaunch 999
run_installer --app-id 347940 >/dev/null
run_installer --verify-only >/dev/null

expect_failure \
    "override de helper fuera de fixture" \
    "los seams internos de Windows Media solo aceptan fixtures privados" \
    env HOME="$TEST_HOME" \
        REGRESSION_WINDOWS_MEDIA_INTERNAL_TEST_SYNC_HELPER=/bin/true \
        "$ROOT/Scripts/install_windows_media_component.sh" --verify-only

printf 'PASS: Windows Media exige autoridad compilada y repara con rollback y recibo cerrado.\n'
