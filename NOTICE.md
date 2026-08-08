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
| Source Han Sans | 2.005R | https://github.com/adobe-fonts/source-han-sans | SIL Open Font License 1.1 |
| Switch2Bridge | commit `ff2e1a1d99c8529a8f693fa4ab7cf82583cd3d7d` | https://github.com/SwonDev/Switch2Bridge | MIT |
| GStreamer plugins-ugly (ASF) | 1.24.4 | incluido en CrossOver Sources | LGPL-2.1+; módulos GPL desactivados |
| GStreamer gst-libav | 1.24.4 | incluido en CrossOver Sources | LGPL-2.1+ |
| FFmpeg | 6.1.6 (`f1e3a2bf…`) | https://github.com/FFmpeg/FFmpeg | LGPL-2.1+; GPL/nonfree desactivados |

Descomprime el tarball de CrossOver como `sources-26.3.0/` en la raíz del proyecto y aplica
`patches/wine-26.3.0-winemac-cxpresent-consumer.patch`. Clona DXMT en `build/toolchain/dxmt-src`,
checkout `v0.72` y aplica `patches/dxmt-v0.72-cross-process-present.patch`.

El asset de usuario compila Switch2Bridge desde el commit y archivo oficial fijados por
`Scripts/package_release.sh`. Incluye tanto el demonio arm64 como la shim SDL x86_64, su licencia
MIT y la fuente de la shim. El instalador lo activa solo en macOS 15 o posterior y modifica
únicamente la botella propia de Regression.

El componente Windows Media del asset se construye mediante
`build/build-windows-media-component.sh`. Incluye solo el demultiplexor ASF de GStreamer,
`gst-libav`, las bibliotecas FFmpeg necesarias y sus textos de licencia. Su manifiesto firmado se
verifica antes de instalar o reparar el enlace local; no incluye codecs propietarios de Microsoft.

## Binarios con licencia restrictiva (NO redistribuibles)

- **Apple Game Porting Toolkit** (D3DMetal.framework, libd3dshared.dylib): licencia de
  evaluación de Apple, solo uso local. Descargar de https://developer.apple.com/games/
  (cuenta de desarrollador). Se copian a
  `Regression.app/Contents/SharedSupport/wine-root/lib/apple_gptk/` durante el empaquetado.
  El asset instalable del release **no los incluye**: `Scripts/install_regression.sh` los
  detecta en el Mac del usuario (GPTK, Whisky o Mythic) y los copia localmente.
- **Steam** (Valve): `SteamSetup.exe` de https://store.steampowered.com/about/ — el usuario lo
  instala en su propia botella.
- **Fuentes Microsoft** (`msyh.ttc`, `simsun.ttc` y corefonts): no se incluyen en el asset
  público. Las copias que existan en una botella privada del usuario permanecen locales y el
  instalador nunca las extrae de CrossOver. El asset usa únicamente Source Han Sans desde su
  distribución oficial bajo SIL Open Font License y las fuentes integradas legalmente en Wine.

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
