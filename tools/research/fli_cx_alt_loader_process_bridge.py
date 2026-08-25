#!/usr/bin/env python3
"""Puente host abierto y acotado para el contrato público CX_ALT_LOADER_SOCKET.

Acepta una única petición LOAD_WINE ya medida, valida su forma sin persistir
argumentos ni valores de entorno y crea un proceso FEX/Proton independiente.
Solo responde éxito después de que el proceso host exista y siga vivo. Esta
pieza pertenece al laboratorio privado: no ejecuta Steam, EAC ni juegos.
"""

from __future__ import annotations

import argparse
import array
import hashlib
import json
import os
import signal
import socket
import stat
import struct
import subprocess
import sys
import time
from pathlib import Path


REQUEST_LOAD_WINE = 0x52C17355
RESPONSE_SUCCESS = REQUEST_LOAD_WINE + 1
RESPONSE_FAILURE = 0
MAX_BLOCK_BYTES = 16 * 1024 * 1024
ALLOWED_ENVIRONMENT = {
    b"HOME=/home/regression",
    b"LC_ALL=C",
    b"WINEARCH=wow64",
}


def read_exact(connection: socket.socket, length: int) -> bytes:
    if length < 0 or length > MAX_BLOCK_BYTES:
        raise ValueError(f"longitud fuera de rango: {length}")
    result = bytearray()
    while len(result) < length:
        chunk = connection.recv(length - len(result))
        if not chunk:
            raise EOFError("el cliente cerró antes de completar el bloque")
        result.extend(chunk)
    return bytes(result)


def read_u32(connection: socket.socket) -> int:
    return struct.unpack("<I", read_exact(connection, 4))[0]


def read_u64(connection: socket.socket) -> int:
    return struct.unpack("<Q", read_exact(connection, 8))[0]


def read_block(connection: socket.socket) -> bytes:
    return read_exact(connection, read_u64(connection))


def nul_entries(data: bytes) -> list[bytes]:
    if not data:
        return []
    if not data.endswith(b"\0"):
        raise ValueError("el bloque NUL no termina correctamente")
    return [entry for entry in data.split(b"\0") if entry]


def fingerprint(data: bytes) -> str:
    return hashlib.sha256(data).hexdigest()


def descriptor_kind(descriptor: int) -> str:
    mode = os.fstat(descriptor).st_mode
    if stat.S_ISREG(mode):
        return "regular"
    if stat.S_ISDIR(mode):
        return "directory"
    if stat.S_ISFIFO(mode):
        return "fifo"
    if stat.S_ISSOCK(mode):
        return "socket"
    if stat.S_ISCHR(mode):
        return "character"
    return "other"


def write_private_json(path: Path, payload: dict[str, object]) -> None:
    path.parent.mkdir(mode=0o700, parents=True, exist_ok=True)
    temporary = path.with_name(path.name + ".tmp")
    descriptor = os.open(temporary, os.O_WRONLY | os.O_CREAT | os.O_TRUNC, 0o600)
    with os.fdopen(descriptor, "w", encoding="utf-8") as stream:
        json.dump(payload, stream, ensure_ascii=False, sort_keys=True, indent=2)
        stream.write("\n")
    os.replace(temporary, path)


def remove_owned_socket(path: Path) -> None:
    try:
        metadata = path.lstat()
    except FileNotFoundError:
        return
    if not stat.S_ISSOCK(metadata.st_mode) or metadata.st_uid != os.getuid():
        raise RuntimeError("la ruta existente no es un socket propiedad del usuario")
    path.unlink()


def receive_request(
    connection: socket.socket,
) -> tuple[int, bytes, list[bytes], list[bytes], list[int]]:
    request_type = read_u32(connection)
    working_directory = read_block(connection)
    environment_entries = nul_entries(read_block(connection))
    argument_entries = nul_entries(read_block(connection))
    descriptor_array = array.array("i")
    data, ancillary, _, _ = connection.recvmsg(
        1,
        socket.CMSG_SPACE(5 * descriptor_array.itemsize),
    )
    for level, message_type, payload in ancillary:
        if level == socket.SOL_SOCKET and message_type == socket.SCM_RIGHTS:
            usable = len(payload) - (len(payload) % descriptor_array.itemsize)
            descriptor_array.frombytes(payload[:usable])
    if len(data) != 1:
        raise ValueError("la carga auxiliar no coincide con el contrato medido")
    return (
        request_type,
        working_directory,
        environment_entries,
        argument_entries,
        list(descriptor_array),
    )


def validate_private_path(path: Path, *, directory: bool) -> Path:
    resolved = path.resolve(strict=True)
    metadata = resolved.stat()
    if metadata.st_uid != os.getuid():
        raise ValueError(f"la ruta no pertenece al usuario: {resolved}")
    if directory and not stat.S_ISDIR(metadata.st_mode):
        raise ValueError(f"la ruta no es un directorio: {resolved}")
    if not directory and not stat.S_ISREG(metadata.st_mode):
        raise ValueError(f"la ruta no es un archivo regular: {resolved}")
    return resolved


def build_child_command(
    options: argparse.Namespace,
    arguments: list[str],
    descriptors: list[int],
) -> list[str]:
    command = [
        os.fspath(options.runner),
        "--library",
        os.fspath(options.library),
        "--fex-source",
        os.fspath(options.fex_source),
        "--fex-build",
        os.fspath(options.fex_build),
        "--output-dir",
        os.fspath(options.child_output),
        "--real-rootfs",
        os.fspath(options.rootfs),
        "--guest-program",
        "/opt/proton/files/lib/wine/x86_64-unix/wine-preloader",
        "--guest-arg",
        "/opt/proton/files/lib/wine/x86_64-unix/wine",
    ]
    for argument in arguments:
        command.extend(("--guest-arg", argument))
    command.extend(
        (
            "--guest-component-kind",
            "official-proton-wine64-preloader",
            "--instrument-low-memory-bias",
            "--wine-arch-wow64",
            "--inherited-wineserver-socket-fd",
            str(descriptors[3]),
            "--guest-stdin-fd",
            str(descriptors[0]),
            "--guest-stdout-fd",
            str(descriptors[1]),
            "--guest-stderr-fd",
            str(descriptors[2]),
        )
    )
    return command


def send_start_response(
    connection: socket.socket,
    child: subprocess.Popen[bytes],
    readiness_delay: float,
) -> tuple[bool, int | None]:
    """Responde cuando el proceso host existe, sin esperar a que termine.

    El cliente Wine bloquea inmediatamente en la lectura de esta respuesta.
    Esperar aquí al cierre del hijo interbloquearía ambos lados de la sesión.
    """

    if readiness_delay < 0:
        raise ValueError("el intervalo de preparación no puede ser negativo")
    if readiness_delay:
        time.sleep(readiness_delay)
    early_exit_code = child.poll()
    if early_exit_code is not None:
        connection.sendall(struct.pack("<I", RESPONSE_FAILURE))
        return False, early_exit_code
    connection.sendall(struct.pack("<I", RESPONSE_SUCCESS))
    return True, None


def terminate_child_group(child: subprocess.Popen[bytes]) -> None:
    """Recoge únicamente el grupo privado creado para el runner del laboratorio."""

    try:
        os.killpg(child.pid, signal.SIGTERM)
    except ProcessLookupError:
        return
    try:
        child.wait(timeout=5)
    except subprocess.TimeoutExpired:
        try:
            os.killpg(child.pid, signal.SIGKILL)
        except ProcessLookupError:
            pass
        child.wait(timeout=5)


def run(options: argparse.Namespace) -> int:
    options.runner = validate_private_path(options.runner, directory=False)
    options.library = validate_private_path(options.library, directory=False)
    options.fex_source = validate_private_path(options.fex_source, directory=True)
    options.fex_build = validate_private_path(options.fex_build, directory=True)
    options.rootfs = validate_private_path(options.rootfs, directory=True)
    if options.child_output.exists() or options.receipt.exists():
        raise ValueError("la salida del hijo o el recibo ya existen")
    socket_parent = options.socket.parent.resolve(strict=True)
    parent_metadata = socket_parent.stat()
    if (
        socket_parent.parent != Path("/private/tmp")
        or not socket_parent.name.startswith("regression-fli-cx-alt-loader.")
        or parent_metadata.st_uid != os.getuid()
        or stat.S_IMODE(parent_metadata.st_mode) != 0o700
        or options.socket.name in ("", ".", "..")
    ):
        raise ValueError("el directorio del socket no es privado o permitido")
    socket_path = socket_parent / options.socket.name
    if len(os.fsencode(socket_path)) >= 104:
        raise ValueError("la ruta del socket supera sockaddr_un")
    remove_owned_socket(socket_path)

    server = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
    descriptors: list[int] = []
    child: subprocess.Popen[bytes] | None = None
    child_group_needs_cleanup = False
    child_runner_stdout: int | None = None
    child_runner_stderr: int | None = None
    receipt: dict[str, object] = {"schema": 1, "response": "failure"}
    try:
        server.bind(os.fspath(socket_path))
        os.chmod(socket_path, 0o600)
        server.listen(1)
        server.settimeout(options.timeout)
        connection, _ = server.accept()
        with connection:
            connection.settimeout(options.timeout)
            (
                request_type,
                working_directory,
                environment_entries,
                argument_entries,
                descriptors,
            ) = receive_request(connection)
            argument_fingerprints = [fingerprint(entry) for entry in argument_entries]
            descriptor_kinds = [descriptor_kind(descriptor) for descriptor in descriptors]
            receipt.update(
                {
                    "request_type": request_type,
                    "request_load_wine_matches": request_type == REQUEST_LOAD_WINE,
                    "working_directory_empty": not working_directory,
                    "environment_entry_count": len(environment_entries),
                    "environment_names": sorted(
                        entry.split(b"=", 1)[0].decode("ascii", "strict")
                        for entry in environment_entries
                    ),
                    "argument_count": len(argument_entries),
                    "argument_lengths": [len(entry) for entry in argument_entries],
                    "argument_fingerprints": argument_fingerprints,
                    "ancillary_descriptor_count": len(descriptors),
                    "ancillary_descriptor_kinds": descriptor_kinds,
                }
            )
            if request_type != REQUEST_LOAD_WINE or working_directory:
                raise ValueError("la petición no coincide con LOAD_WINE medido")
            if set(environment_entries) != ALLOWED_ENVIRONMENT:
                raise ValueError("el entorno huésped no pertenece al conjunto permitido")
            if argument_fingerprints != options.expected_argument_fingerprint:
                raise ValueError("los argumentos no coinciden con la prueba controlada")
            if len(descriptors) not in (4, 5) or descriptor_kinds[3] != "socket":
                raise ValueError("los descriptores no coinciden con el contrato Wine")
            if len(descriptors) == 5 and descriptor_kinds[4] not in ("fifo", "regular"):
                raise ValueError("el descriptor opcional de espera no es válido")
            decoded_arguments = [entry.decode("utf-8", "strict") for entry in argument_entries]
            command = build_child_command(options, decoded_arguments, descriptors)
            runner_stdout_path = options.receipt.with_name(
                options.receipt.name + ".child-runner-stdout.log"
            )
            runner_stderr_path = options.receipt.with_name(
                options.receipt.name + ".child-runner-stderr.log"
            )
            if runner_stdout_path.exists() or runner_stderr_path.exists():
                raise ValueError("los diagnósticos privados del runner ya existen")
            child_runner_stdout = os.open(
                runner_stdout_path,
                os.O_WRONLY | os.O_CREAT | os.O_EXCL,
                0o600,
            )
            child_runner_stderr = os.open(
                runner_stderr_path,
                os.O_WRONLY | os.O_CREAT | os.O_EXCL,
                0o600,
            )
            child = subprocess.Popen(
                command,
                stdin=subprocess.DEVNULL,
                stdout=child_runner_stdout,
                stderr=child_runner_stderr,
                pass_fds=tuple(descriptors),
                close_fds=True,
                start_new_session=True,
            )
            child_group_needs_cleanup = True
            os.close(child_runner_stdout)
            child_runner_stdout = None
            os.close(child_runner_stderr)
            child_runner_stderr = None
            receipt["child_process_created"] = True
            receipt["child_pid_positive"] = child.pid > 0
            receipt["child_pid"] = child.pid
            receipt["child_process_group_created"] = True
            receipt["child_process_group_id"] = child.pid
            write_private_json(options.receipt, receipt)
            response_succeeded, early_exit_code = send_start_response(
                connection,
                child,
                options.readiness_delay,
            )
            receipt["readiness_delay_seconds"] = options.readiness_delay
            receipt["response_sent_while_child_alive"] = response_succeeded
            receipt["response"] = "success" if response_succeeded else "failure"
            receipt["response_code"] = (
                RESPONSE_SUCCESS if response_succeeded else RESPONSE_FAILURE
            )
            if not response_succeeded:
                receipt["child_exit_code"] = early_exit_code
                receipt["child_completed"] = True
                write_private_json(options.receipt, receipt)
                return 70
            write_private_json(options.receipt, receipt)
            try:
                child_return_code = child.wait(timeout=options.child_timeout)
            except subprocess.TimeoutExpired:
                receipt["child_timed_out_after_response"] = True
                write_private_json(options.receipt, receipt)
                return 70
            receipt["child_exit_code"] = child_return_code
            receipt["child_completed"] = True
            child_group_needs_cleanup = False
            write_private_json(options.receipt, receipt)
            return 0 if child_return_code == 0 else 70
    finally:
        for host_descriptor in (child_runner_stdout, child_runner_stderr):
            if host_descriptor is not None:
                try:
                    os.close(host_descriptor)
                except OSError:
                    pass
        if child is not None and child_group_needs_cleanup:
            terminate_child_group(child)
        for descriptor in descriptors:
            try:
                os.close(descriptor)
            except OSError:
                pass
        server.close()
        remove_owned_socket(socket_path)


def parse_arguments() -> argparse.Namespace:
    parser = argparse.ArgumentParser()
    parser.add_argument("--socket", required=True, type=Path)
    parser.add_argument("--receipt", required=True, type=Path)
    parser.add_argument("--runner", required=True, type=Path)
    parser.add_argument("--library", required=True, type=Path)
    parser.add_argument("--fex-source", required=True, type=Path)
    parser.add_argument("--fex-build", required=True, type=Path)
    parser.add_argument("--rootfs", required=True, type=Path)
    parser.add_argument("--child-output", required=True, type=Path)
    parser.add_argument(
        "--expected-argument-fingerprint",
        action="append",
        default=[],
        required=True,
    )
    parser.add_argument("--timeout", type=float, default=30.0)
    parser.add_argument("--child-timeout", type=float, default=120.0)
    parser.add_argument("--readiness-delay", type=float, default=0.2)
    return parser.parse_args()


if __name__ == "__main__":
    try:
        raise SystemExit(run(parse_arguments()))
    except Exception as error:
        print(f"ERROR: {error}", file=sys.stderr)
        raise SystemExit(70)
