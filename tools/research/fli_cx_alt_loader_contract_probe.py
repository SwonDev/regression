#!/usr/bin/env python3
"""Observa el contrato público CX_ALT_LOADER_SOCKET sin lanzar procesos.

La sonda recibe una única petición REQUEST_LOAD_WINE, normaliza su forma y
responde con fallo deliberado para que Wine conserve su ruta de fallback. No
persiste valores de entorno, argumentos ni descriptores; únicamente tamaños,
nombres de variables, tipos y huellas.
"""

from __future__ import annotations

import argparse
import array
import hashlib
import json
import os
import socket
import stat
import struct
import sys
from pathlib import Path
REQUEST_LOAD_WINE = 0x52C17355
RESPONSE_SUCCESS = REQUEST_LOAD_WINE + 1
MAX_BLOCK_BYTES = 16 * 1024 * 1024


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


def fingerprint(data: bytes) -> str:
    return hashlib.sha256(data).hexdigest()


def nul_entries(data: bytes) -> list[bytes]:
    if not data:
        return []
    if not data.endswith(b"\0"):
        raise ValueError("el bloque NUL no termina correctamente")
    return [entry for entry in data.split(b"\0") if entry]


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


def receive_request(connection: socket.socket) -> tuple[dict[str, object], list[int]]:
    request_type = read_u32(connection)
    working_directory = read_exact(connection, read_u64(connection))
    environment = read_exact(connection, read_u64(connection))
    arguments = read_exact(connection, read_u64(connection))

    descriptor_array = array.array("i")
    data, ancillary, _, _ = connection.recvmsg(
        1,
        socket.CMSG_SPACE(5 * descriptor_array.itemsize),
    )
    for level, message_type, payload in ancillary:
        if level == socket.SOL_SOCKET and message_type == socket.SCM_RIGHTS:
            usable = len(payload) - (len(payload) % descriptor_array.itemsize)
            descriptor_array.frombytes(payload[:usable])

    environment_entries = nul_entries(environment)
    argument_entries = nul_entries(arguments)
    environment_names = sorted(
        entry.split(b"=", 1)[0].decode("utf-8", "replace")
        for entry in environment_entries
    )
    descriptors = list(descriptor_array)
    receipt: dict[str, object] = {
        "schema": 1,
        "request_type": request_type,
        "request_load_wine_matches": request_type == REQUEST_LOAD_WINE,
        "working_directory_length": len(working_directory),
        "working_directory_fingerprint": fingerprint(working_directory),
        "environment_length": len(environment),
        "environment_entry_count": len(environment_entries),
        "environment_names": environment_names,
        "environment_fingerprint": fingerprint(environment),
        "argument_length": len(arguments),
        "argument_count": len(argument_entries),
        "argument_lengths": [len(entry) for entry in argument_entries],
        "argument_fingerprints": [fingerprint(entry) for entry in argument_entries],
        "ancillary_payload_length": len(data),
        "ancillary_descriptor_count": len(descriptors),
        "ancillary_descriptor_kinds": [descriptor_kind(fd) for fd in descriptors],
    }
    return receipt, descriptors


def parse_arguments() -> argparse.Namespace:
    parser = argparse.ArgumentParser()
    parser.add_argument("--socket", required=True, type=Path)
    parser.add_argument("--receipt", required=True, type=Path)
    parser.add_argument("--timeout", type=float, default=30.0)
    parser.add_argument(
        "--response",
        choices=("failure", "success"),
        default="failure",
        help="failure mantiene el fallback de Wine; success solo se usa con un cargador real",
    )
    return parser.parse_args()


def main() -> int:
    options = parse_arguments()
    socket_parent = options.socket.parent.resolve(strict=True)
    parent_metadata = socket_parent.stat()
    if (
        not os.fspath(socket_parent).startswith(
            "/private/tmp/regression-fli-cx-alt-loader."
        )
        or parent_metadata.st_uid != os.getuid()
        or stat.S_IMODE(parent_metadata.st_mode) != 0o700
        or options.socket.name in ("", ".", "..")
    ):
        raise RuntimeError("el directorio del socket no es privado o permitido")
    socket_path = socket_parent / options.socket.name
    receipt_path = options.receipt.resolve(strict=False)
    if socket_path == receipt_path or len(os.fsencode(socket_path)) >= 104:
        raise RuntimeError("la ruta del socket no es válida para sockaddr_un")
    remove_owned_socket(socket_path)

    server = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
    descriptors: list[int] = []
    try:
        server.bind(os.fspath(socket_path))
        os.chmod(socket_path, 0o600)
        server.listen(1)
        server.settimeout(options.timeout)
        connection, _ = server.accept()
        with connection:
            connection.settimeout(options.timeout)
            receipt, descriptors = receive_request(connection)
            response = RESPONSE_SUCCESS if options.response == "success" else 0
            connection.sendall(struct.pack("<I", response))
            receipt["response"] = options.response
            receipt["response_code"] = response
            receipt["passive_only"] = options.response == "failure"
            write_private_json(receipt_path, receipt)
    finally:
        for descriptor in descriptors:
            try:
                os.close(descriptor)
            except OSError:
                pass
        server.close()
        remove_owned_socket(socket_path)
    return 0


if __name__ == "__main__":
    try:
        raise SystemExit(main())
    except Exception as error:
        print(f"ERROR: {error}", file=sys.stderr)
        raise SystemExit(70)
