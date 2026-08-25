#!/usr/bin/env python3
"""Supervisa una A/B acotada del cargador alternativo Wine/FEX.

El supervisor crea dos sesiones privadas (helper y padre), captura muestras de
los procesos reales una vez que LOAD_WINE obtiene respuesta y recoge solamente
los grupos que él mismo ha creado. Todos los artefactos se conservan aunque la
prueba expire. No inicia Proton, Steam, EAC ni juegos.
"""

from __future__ import annotations

import argparse
import json
import os
import re
import shutil
import signal
import stat
import subprocess
import sys
import tempfile
import time
from pathlib import Path
from typing import Any


ARGUMENT_FINGERPRINTS = (
    "cdf3c8524894b10f8ff7635abeabfdfabb04ed61b636b79f275d0caa23c55928",
    "95fe6f3c674a58ba6af7602213cdb4ef8163fbf63d352959d21320f34af17c19",
)
LABEL_PATTERN = re.compile(r"[A-Za-z0-9][A-Za-z0-9._-]{0,95}\Z")
PROCESS_COLUMNS = ("pid", "ppid", "pgid", "state", "etime", "command")


def write_private_json(path: Path, payload: dict[str, Any]) -> None:
    path.parent.mkdir(mode=0o700, parents=True, exist_ok=True)
    temporary = path.with_name(path.name + ".tmp")
    descriptor = os.open(temporary, os.O_WRONLY | os.O_CREAT | os.O_TRUNC, 0o600)
    with os.fdopen(descriptor, "w", encoding="utf-8") as stream:
        json.dump(payload, stream, ensure_ascii=False, sort_keys=True, indent=2)
        stream.write("\n")
    os.replace(temporary, path)


def validate_owned_path(path: Path, *, directory: bool) -> Path:
    resolved = path.resolve(strict=True)
    metadata = resolved.stat()
    if metadata.st_uid != os.getuid():
        raise ValueError(f"la ruta no pertenece al usuario: {resolved}")
    expected = stat.S_ISDIR(metadata.st_mode) if directory else stat.S_ISREG(metadata.st_mode)
    if not expected:
        kind = "directorio" if directory else "archivo regular"
        raise ValueError(f"la ruta no es un {kind}: {resolved}")
    return resolved


def validate_new_output(path: Path) -> Path:
    parent = path.parent.resolve(strict=True)
    metadata = parent.stat()
    if metadata.st_uid != os.getuid() or not stat.S_ISDIR(metadata.st_mode):
        raise ValueError("el padre de la salida no es un directorio propio")
    if path.exists() or path.is_symlink():
        raise ValueError(f"la salida ya existe: {path}")
    return parent / path.name


def process_snapshot() -> list[dict[str, Any]]:
    completed = subprocess.run(
        ["/bin/ps", "-axo", "pid=,ppid=,pgid=,state=,etime=,command="],
        check=True,
        capture_output=True,
        text=True,
    )
    rows: list[dict[str, Any]] = []
    for line in completed.stdout.splitlines():
        parts = line.strip().split(None, 5)
        if len(parts) != len(PROCESS_COLUMNS):
            continue
        row = dict(zip(PROCESS_COLUMNS, parts, strict=True))
        for key in ("pid", "ppid", "pgid"):
            row[key] = int(row[key])
        rows.append(row)
    return rows


def group_rows(process_group: int) -> list[dict[str, Any]]:
    return [row for row in process_snapshot() if row["pgid"] == process_group]


def terminate_group(process: subprocess.Popen[bytes] | None) -> dict[str, Any]:
    result: dict[str, Any] = {
        "present": process is not None,
        "term_sent": False,
        "kill_sent": False,
        "return_code": None,
    }
    if process is None:
        return result
    if process.poll() is not None:
        result["return_code"] = process.returncode
        return result
    try:
        os.killpg(process.pid, signal.SIGTERM)
        result["term_sent"] = True
    except ProcessLookupError:
        result["return_code"] = process.poll()
        return result
    try:
        result["return_code"] = process.wait(timeout=5)
        return result
    except subprocess.TimeoutExpired:
        pass
    try:
        os.killpg(process.pid, signal.SIGKILL)
        result["kill_sent"] = True
    except ProcessLookupError:
        result["return_code"] = process.poll()
        return result
    result["return_code"] = process.wait(timeout=5)
    return result


def read_json_if_complete(path: Path) -> dict[str, Any] | None:
    try:
        with path.open("r", encoding="utf-8") as stream:
            value = json.load(stream)
    except (FileNotFoundError, json.JSONDecodeError, OSError):
        return None
    return value if isinstance(value, dict) else None


def wait_for_socket(path: Path, helper: subprocess.Popen[bytes], timeout: float) -> None:
    deadline = time.monotonic() + timeout
    while time.monotonic() < deadline:
        if path.exists() and stat.S_ISSOCK(path.lstat().st_mode):
            return
        helper_status = helper.poll()
        if helper_status is not None:
            raise RuntimeError(f"el helper terminó antes de crear el socket: {helper_status}")
        time.sleep(0.05)
    raise TimeoutError("el helper no creó el socket dentro del plazo")


def sample_process(process_id: int, output: Path, duration: int) -> dict[str, Any]:
    completed = subprocess.run(
        ["/usr/bin/sample", str(process_id), str(duration), "1", "-file", os.fspath(output)],
        check=False,
        capture_output=True,
        text=True,
        timeout=duration + 8,
    )
    return {
        "pid": process_id,
        "return_code": completed.returncode,
        "output": output.name,
        "stderr": completed.stderr[-4096:],
    }


def select_sample_targets(rows: list[dict[str, Any]]) -> list[int]:
    probes = [
        row["pid"]
        for row in rows
        if "fli-fexcore-process-probe" in str(row["command"])
    ]
    if probes:
        return sorted(set(probes))
    return sorted({int(row["pid"]) for row in rows})[-2:]


def clone_rootfs(source: Path, destination: Path) -> None:
    destination.parent.mkdir(mode=0o700, parents=True, exist_ok=False)
    subprocess.run(
        ["/usr/bin/ditto", "--noqtn", os.fspath(source), os.fspath(destination)],
        check=True,
    )


def build_helper_command(options: argparse.Namespace, socket_path: Path) -> list[str]:
    return [
        os.fspath(options.python),
        os.fspath(options.helper),
        "--socket",
        os.fspath(socket_path),
        "--receipt",
        os.fspath(options.helper_receipt),
        "--runner",
        os.fspath(options.runner),
        "--library",
        os.fspath(options.library),
        "--fex-source",
        os.fspath(options.fex_source),
        "--fex-build",
        os.fspath(options.fex_build),
        "--rootfs",
        os.fspath(options.rootfs),
        "--child-output",
        os.fspath(options.child_output),
        "--expected-argument-fingerprint",
        ARGUMENT_FINGERPRINTS[0],
        "--expected-argument-fingerprint",
        ARGUMENT_FINGERPRINTS[1],
        "--timeout",
        str(options.total_timeout),
        "--child-timeout",
        str(max(5.0, options.total_timeout - 5.0)),
        "--readiness-delay",
        "0.2",
    ]


def build_parent_command(options: argparse.Namespace, socket_path: Path) -> list[str]:
    return [
        os.fspath(options.runner),
        "--library",
        os.fspath(options.library),
        "--fex-source",
        os.fspath(options.fex_source),
        "--fex-build",
        os.fspath(options.fex_build),
        "--output-dir",
        os.fspath(options.parent_output),
        "--real-rootfs",
        os.fspath(options.rootfs),
        "--guest-program",
        "/opt/proton/files/lib/wine/x86_64-unix/wine-preloader",
        "--guest-arg",
        "/opt/proton/files/lib/wine/x86_64-unix/wine",
        "--guest-arg",
        r"C:\windows\system32\wineboot.exe",
        "--guest-arg",
        "--init",
        "--guest-component-kind",
        "official-proton-wine64-preloader",
        "--instrument-low-memory-bias",
        "--instrument-vfork-parent-wineserver-bridge",
        "--initial-wine-command-line",
        "--wine-arch-wow64",
        "--cx-alt-loader-socket",
        f"/tmp/{socket_path.name}",
        "--cx-alt-loader-host-socket",
        os.fspath(socket_path),
    ]


def run(options: argparse.Namespace) -> int:
    started = time.monotonic()
    options.runner = validate_owned_path(options.runner, directory=False)
    options.helper = validate_owned_path(options.helper, directory=False)
    options.library = validate_owned_path(options.library, directory=False)
    options.fex_source = validate_owned_path(options.fex_source, directory=True)
    options.fex_build = validate_owned_path(options.fex_build, directory=True)
    options.base_rootfs = validate_owned_path(options.base_rootfs, directory=True)
    options.python = validate_owned_path(options.python, directory=False)
    if not LABEL_PATTERN.fullmatch(options.label):
        raise ValueError("--label contiene caracteres no permitidos")
    if not 20 <= options.total_timeout <= 120:
        raise ValueError("--total-timeout debe estar entre 20 y 120 segundos")
    if not 0.5 <= options.sample_after < options.total_timeout - 5:
        raise ValueError("--sample-after queda fuera del intervalo seguro")
    if not 1 <= options.sample_duration <= 5:
        raise ValueError("--sample-duration debe estar entre 1 y 5 segundos")

    output = validate_new_output(options.research_root / options.label)
    output.mkdir(mode=0o700)
    options.rootfs = output / "rootfs-copy" / "rootfs"
    options.helper_receipt = output / "helper-receipt.json"
    options.child_output = output / "child-output"
    options.parent_output = output / "parent-output"
    supervisor_receipt = output / "supervisor-receipt.json"
    helper_log_path = output / "helper.log"
    parent_log_path = output / "parent.log"
    receipt: dict[str, Any] = {
        "schema": 1,
        "label": options.label,
        "state": "preparing",
        "stable_engine_touched": False,
        "proton_orchestrator_executed": False,
        "steam_executed": False,
        "eac_executed": False,
        "game_executed": False,
    }
    write_private_json(supervisor_receipt, receipt)

    helper: subprocess.Popen[bytes] | None = None
    parent: subprocess.Popen[bytes] | None = None
    socket_directory: Path | None = None
    helper_log: Any = None
    parent_log: Any = None
    try:
        clone_rootfs(options.base_rootfs, options.rootfs)
        receipt["rootfs_cloned"] = True
        receipt["state"] = "starting"
        write_private_json(supervisor_receipt, receipt)

        socket_directory = Path(
            tempfile.mkdtemp(prefix="regression-fli-cx-alt-loader.", dir="/private/tmp")
        )
        os.chmod(socket_directory, 0o700)
        socket_path = socket_directory / "loader.sock"
        helper_log = helper_log_path.open("xb", buffering=0)
        parent_log = parent_log_path.open("xb", buffering=0)
        helper = subprocess.Popen(
            build_helper_command(options, socket_path),
            stdin=subprocess.DEVNULL,
            stdout=helper_log,
            stderr=helper_log,
            close_fds=True,
            start_new_session=True,
        )
        receipt["helper_pid"] = helper.pid
        wait_for_socket(socket_path, helper, min(15.0, options.total_timeout / 3))
        parent_environment = os.environ.copy()
        parent_environment["REGRESSION_KEEP_FAILED_BUILD"] = "1"
        parent = subprocess.Popen(
            build_parent_command(options, socket_path),
            stdin=subprocess.DEVNULL,
            stdout=parent_log,
            stderr=parent_log,
            env=parent_environment,
            close_fds=True,
            start_new_session=True,
        )
        receipt.update(
            {
                "parent_pid": parent.pid,
                "state": "running",
                "helper_group": helper.pid,
                "parent_group": parent.pid,
            }
        )
        write_private_json(supervisor_receipt, receipt)

        response_at: float | None = None
        sampled = False
        deadline = started + options.total_timeout
        while time.monotonic() < deadline:
            helper_receipt = read_json_if_complete(options.helper_receipt)
            if parent.poll() is not None and helper_receipt is None:
                receipt["state"] = "parent_failed_before_load_wine"
                receipt["parent_return_code_before_load_wine"] = parent.returncode
                break
            if helper_receipt is not None and helper_receipt.get("response") == "success":
                if response_at is None:
                    response_at = time.monotonic()
                    receipt["load_wine_response_seen"] = True
                    write_private_json(supervisor_receipt, receipt)
                if not sampled and time.monotonic() - response_at >= options.sample_after:
                    parent_rows = group_rows(parent.pid)
                    child_group = int(helper_receipt.get("child_process_group_id", 0))
                    child_rows = group_rows(child_group) if child_group > 0 else []
                    receipt["parent_processes_at_sample"] = parent_rows
                    receipt["child_processes_at_sample"] = child_rows
                    samples: list[dict[str, Any]] = []
                    for process_id in select_sample_targets(parent_rows):
                        samples.append(
                            sample_process(
                                process_id,
                                output / f"parent-{process_id}.sample.txt",
                                options.sample_duration,
                            )
                        )
                    for process_id in select_sample_targets(child_rows):
                        samples.append(
                            sample_process(
                                process_id,
                                output / f"child-{process_id}.sample.txt",
                                options.sample_duration,
                            )
                        )
                    receipt["samples"] = samples
                    receipt["sampled"] = True
                    sampled = True
                    write_private_json(supervisor_receipt, receipt)
            if parent.poll() is not None and helper.poll() is not None:
                receipt["state"] = "completed"
                break
            time.sleep(0.1)
        else:
            receipt["state"] = "timed_out"
            receipt["total_timeout_reached"] = True

        receipt["parent_return_code_before_cleanup"] = parent.poll()
        receipt["helper_return_code_before_cleanup"] = helper.poll()
        return 0 if receipt["state"] == "completed" else 70
    finally:
        receipt["parent_cleanup"] = terminate_group(parent)
        receipt["helper_cleanup"] = terminate_group(helper)
        if parent_log is not None:
            parent_log.close()
        if helper_log is not None:
            helper_log.close()
        if socket_directory is not None:
            shutil.rmtree(socket_directory, ignore_errors=True)
        receipt["elapsed_seconds"] = round(time.monotonic() - started, 3)
        receipt["cleanup_complete"] = True
        receipt["parent_group_remaining"] = (
            group_rows(parent.pid) if parent is not None else []
        )
        receipt["helper_group_remaining"] = (
            group_rows(helper.pid) if helper is not None else []
        )
        write_private_json(supervisor_receipt, receipt)


def parse_arguments() -> argparse.Namespace:
    parser = argparse.ArgumentParser()
    parser.add_argument("--label", required=True)
    parser.add_argument("--research-root", required=True, type=Path)
    parser.add_argument("--base-rootfs", required=True, type=Path)
    parser.add_argument("--runner", required=True, type=Path)
    parser.add_argument("--helper", required=True, type=Path)
    parser.add_argument("--library", required=True, type=Path)
    parser.add_argument("--fex-source", required=True, type=Path)
    parser.add_argument("--fex-build", required=True, type=Path)
    parser.add_argument(
        "--python",
        type=Path,
        default=Path("/opt/homebrew/bin/python3"),
    )
    parser.add_argument("--total-timeout", type=float, default=55.0)
    parser.add_argument("--sample-after", type=float, default=8.0)
    parser.add_argument("--sample-duration", type=int, default=2)
    return parser.parse_args()


if __name__ == "__main__":
    try:
        raise SystemExit(run(parse_arguments()))
    except Exception as error:
        print(f"ERROR: {error}", file=sys.stderr)
        raise SystemExit(70)
