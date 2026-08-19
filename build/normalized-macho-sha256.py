#!/usr/bin/env python3
"""Huella de un Mach-O sin la parte que cambia al firmarlo.

`codesign --remove-signature` recupera el binario original salvo por vmsize y
filesize de __LINKEDIT, que quedan actualizados por el blob retirado. Poner esos
dos campos a cero permite comparar un binario recién compilado con el mismo
binario ya firmado dentro del bundle; el resto de la carga ejecutable, la
cabecera y los demás load commands siguen entrando en la huella.

Se usa desde el verificador del estado protegido y desde el generador de PIN, de
modo que ambos acrediten con el mismo criterio: dos implementaciones distintas
del mismo cálculo producirían evidencias que no se pueden comparar entre sí.
"""
import hashlib
import struct
import sys

payload = bytearray(open(sys.argv[1], "rb").read())
if len(payload) < 32 or struct.unpack_from("<I", payload, 0)[0] != 0xFEEDFACF:
    raise SystemExit("no es un Mach-O fino de 64 bits little-endian")

ncmds, sizeofcmds = struct.unpack_from("<II", payload, 16)
commands_end = 32 + sizeofcmds
if commands_end > len(payload):
    raise SystemExit("cabecera Mach-O truncada")

offset = 32
linkedit_count = 0
for _ in range(ncmds):
    if offset + 8 > commands_end:
        raise SystemExit("load command truncado")
    command, command_size = struct.unpack_from("<II", payload, offset)
    if command_size < 8 or offset + command_size > commands_end:
        raise SystemExit("load command inválido")
    if command == 0x19 and command_size >= 72:
        name = bytes(payload[offset + 8:offset + 24]).split(b"\0", 1)[0]
        if name == b"__LINKEDIT":
            payload[offset + 32:offset + 40] = b"\0" * 8
            payload[offset + 48:offset + 56] = b"\0" * 8
            linkedit_count += 1
    offset += command_size

if offset != commands_end or linkedit_count != 1:
    raise SystemExit("topología Mach-O inesperada para normalización")
print(hashlib.sha256(payload).hexdigest())
