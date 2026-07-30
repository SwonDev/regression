#!/usr/bin/env python3
"""Carga un módulo Unix de EAC sin invocar símbolos privados.

Esta sonda se limita a la frontera pública de ``dlopen(3)``. Sirve para
distinguir un fallo del cargador ELF o de dependencias de un error posterior
de inicialización dentro de Wine/Proton. No inspecciona ni modifica el módulo.
"""

from __future__ import annotations

import ctypes
import os
import platform
import sys


def main() -> int:
    module_path = os.environ.get("EAC_SO")
    if not module_path:
        print("EAC_SO no está definido", file=sys.stderr)
        return 64

    print(f"architecture={platform.machine()}", flush=True)
    print(f"module={module_path}", flush=True)

    try:
        ctypes.CDLL(module_path, mode=os.RTLD_NOW | os.RTLD_LOCAL)
    except OSError as error:
        print(f"dlopen_error={error}", file=sys.stderr, flush=True)
        return 1

    print("dlopen=ok", flush=True)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
