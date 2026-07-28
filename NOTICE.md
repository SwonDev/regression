# NOTICE — Componentes de terceros (NO incluidos en este repositorio)

Regression se construye sobre componentes de terceros que **no se distribuyen** en este repo,
por tamaño, por licencia o por ser material descargable de su fuente oficial. Para reproducir
el build necesitas obtenerlos tú mismo:

## Fuentes open-source (descarga oficial)

| Componente | Versión | Origen | Licencia |
|---|---|---|---|
| CrossOver Sources (fork de Wine) | **26.3.0** | https://www.codeweavers.com/crossover/source | LGPL-2.1+ |
| DXMT | **v0.72** | https://github.com/3Shain/dxmt | LGPL-2.1+ |
| DXVK | 1.10.3 | https://github.com/doitsujin/dxvk | Zlib |
| MoltenVK (build CX) | 1.2.10 | incluido en CrossOver Sources | Apache-2.0 |
| LLVM | 15 | https://llvm.org | Apache-2.0 + LLVM exceptions |
| mingw-w64 | — | https://www.mingw-w64.org | Zpl/MIT |

Descomprime el tarball de CrossOver como `sources-26.3.0/` en la raíz del proyecto y aplica
`patches/wine-26.3.0-winemac-cxpresent-consumer.patch`. Clona DXMT en `build/toolchain/dxmt-src`,
checkout `v0.72` y aplica `patches/dxmt-v0.72-cross-process-present.patch`.

## Binarios con licencia restrictiva (NO redistribuibles)

- **Apple Game Porting Toolkit** (D3DMetal.framework, libd3dshared.dylib): licencia de
  evaluación de Apple, solo uso local. Descargar de https://developer.apple.com/games/
  (cuenta de desarrollador). Se copian a
  `Regression.app/Contents/SharedSupport/wine-root/lib/apple_gptk/` durante el empaquetado.
- **Steam** (Valve): `SteamSetup.exe` de https://store.steampowered.com/about/ — el usuario lo
  instala en su propia botella.

## Qué más falta para reproducir (generado localmente, no versionado)

- `Regression.app/` — se genera con los scripts de `build/` (~1,7 GB).
- `toolchain/x86/` — dependencias compiladas por `build/toolchain-a-tls.sh` y
  `build/toolchain-b-gstreamer.sh` (gnutls, gstreamer, freetype, SDL2…).
- La botella de Steam — datos del usuario, vive fuera del repo en
  `~/Library/Application Support/Regression/Bottles/Steam`.

## Metadatos públicos consultados en ejecución

La comparación opcional usa fichas web públicas y JSON-LD de la
[CodeWeavers Compatibility Database](https://www.codeweavers.com/compatibility). Regression
almacena localmente solo metadatos normalizados, respeta su cadencia publicada y enlaza a la
fuente original. Este repositorio no incluye una copia de la base, `cxcompatdb`, crossties privados
ni contenido protegido de CodeWeavers. Sus valoraciones son contexto externo y no certifican el
motor propio.

## Licencia del contenido de este repo

Los parches de `patches/` derivan de Wine y DXMT y se publican bajo **LGPL-2.1+** (ver
`LICENSE`). Los scripts de `build/` y la documentación se publican bajo los mismos términos
para simplificar.

**Importante**: este es un proyecto personal/educativo. "CrossOver" es marca de CodeWeavers;
"Steam" de Valve; "Metal"/"Game Porting Toolkit" de Apple. Este repo no está afiliado a
ninguna de ellas.
