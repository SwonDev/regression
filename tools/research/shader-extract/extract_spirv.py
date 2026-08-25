#!/usr/bin/env python3
"""Extrae módulos SPIR-V de los paquetes de datos de un juego, sin ejecutarlo.

Muchos motores guardan el SPIR-V sin comprimir dentro de sus `.dat`/`.pak`, así que se localiza por
su número mágico y se delimita recorriendo instrucciones. Sirve para convertir los shaders con
MoltenVKShaderConverter y estudiar el MSL exacto que verá Metal —incluida la línea que señala
`MTL_SHADER_VALIDATION`— sin arrancar Steam ni el juego.

    python3 tools/research/shader-extract/extract_spirv.py <dir_del_juego> <dir_salida>
"""
import os, sys, glob, struct

MAGIC = b'\x03\x02\x23\x07'
TAMANO_MINIMO = 1000          # por debajo de esto es ruido, no un shader real


def delimitar(data: bytes, inicio: int) -> int:
    """Devuelve el tamaño del módulo que empieza en `inicio`, o 0 si no lo parece."""
    n = len(data)
    if inicio + 20 > n:
        return 0
    w = inicio + 20                       # la cabecera SPIR-V son cinco palabras
    while w + 4 <= n:
        palabra = struct.unpack_from('<I', data, w)[0]
        cuenta, opcode = palabra >> 16, palabra & 0xFFFF
        if cuenta == 0:
            break
        siguiente = w + cuenta * 4
        if siguiente > n:
            break
        w = siguiente
        if opcode == 0 and cuenta == 1:   # OpNop suelto: final razonable
            break
    tamano = w - inicio
    return tamano if tamano > TAMANO_MINIMO else 0


def main() -> int:
    if len(sys.argv) != 3:
        print(__doc__)
        return 2
    juego, salida = sys.argv[1], sys.argv[2]
    os.makedirs(salida, exist_ok=True)

    total = 0
    paquetes = sorted(glob.glob(os.path.join(juego, '*.dat')) +
                      glob.glob(os.path.join(juego, '*.pak')))
    if not paquetes:
        print(f'no hay paquetes .dat ni .pak en {juego}')
        return 1

    for paquete in paquetes:
        with open(paquete, 'rb') as fh:
            data = fh.read()
        i = data.find(MAGIC)
        while i >= 0:
            tamano = delimitar(data, i)
            if tamano:
                with open(os.path.join(salida, f'm{total:05d}.spv'), 'wb') as out:
                    out.write(data[i:i + tamano])
                total += 1
            i = data.find(MAGIC, i + 4)
        print(f'  {os.path.basename(paquete)}: acumulados {total}')

    print(f'módulos extraídos: {total}')
    return 0


if __name__ == '__main__':
    sys.exit(main())
