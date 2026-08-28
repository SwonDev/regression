# Preparar Regression para vivir sin Rosetta

> Investigación del **2026-08-28**. Los datos externos llevan fecha porque caducan solos; todo lo
> marcado como *verificado* se comprobó en esta máquina y trae el comando para reproducirlo.

Regression es hoy una app **arm64 nativa** con el motor entero en **x86_64 bajo Rosetta 2**. Cuando
Rosetta se retire, el motor deja de arrancar. Este documento fija qué se sabe, qué se puede tomar
de dónde, quién lo ha hecho ya, y por dónde tiraría yo.

---

## 1. El plazo

| Hito | Cuándo | Qué implica |
|---|---|---|
| macOS 26.4 | ya ocurrido | El sistema **avisa** al abrir una app que necesita Rosetta |
| macOS 27 «Golden Gate» | septiembre 2026 | Rosetta 2 **completo** |
| macOS 28 | otoño 2027 | Se retira **salvo un subconjunto** para juegos Intel no mantenidos |

Margen efectivo: **algo más de un año**.

---

## 2. Qué depende de Rosetta, medido

```bash
W=/Applications/Regression.app/Contents/SharedSupport/wine-root
lipo -archs "$W/bin/wine" "$W/bin/wineserver" "$W/lib/wine/x86_64-unix/ntdll.so"
lipo -archs /Applications/Regression.app/Contents/MacOS/Regression
ls "$W/lib/wine"
```

| Pieza | Arquitectura |
|---|---|
| App Regression (SwiftUI, `RegressionCore`, `regressionctl`) | **arm64 nativo** ✅ |
| `bin/wine`, `bin/wineserver`, `lib/wine/x86_64-unix/*.so` | x86_64 |
| Árbol `wine-root/lib/wine` | sólo `x86_64-unix`, `x86_64-windows`, `i386-windows` |
| DXMT (`d3d11.dll` + `winemetal.so`) | x86_64 |
| D3DMetal / `libd3dshared.dylib` (GPTK 3.0 y 4.0b2) | x86_64 |

La interfaz sobrevive intacta. Todo lo demás hay que portarlo.

---

## 3. El hallazgo que cambia el plan: CrossOver ARM64 **no usa FEX en macOS**

`Crossover-ARM64/` de este repo contiene la **CrossOver Preview del 30-31 de julio de 2026** con su
tar de fuentes. Trae dos ficheros con nombre prometedor:

```
lib/wine/aarch64-unix/libwow64fex.so     52 KB
lib/wine/aarch64-unix/libarm64ecfex.so   52 KB   (idéntico tamaño)
```

Parecen FEX. **No lo son.** Verificado:

```bash
cd "Crossover-ARM64/CrossOver Preview.app/Contents/SharedSupport/CrossOver"
size -m  lib/wine/aarch64-unix/libwow64fex.so   # __text: 176 bytes
nm -gU   lib/wine/aarch64-unix/libwow64fex.so   # sólo ___wine_unix_call_funcs
nm -u    lib/wine/aarch64-unix/libwow64fex.so   # _mmap, _pthread_jit_write_protect_np,
                                                # _thread_set_x86_64_compat
```

**176 bytes de código.** No hay emulador ahí dentro: es un **puente** a
`thread_set_x86_64_compat`, una llamada del kernel de macOS que pone un hilo en modo de
compatibilidad x86-64 **dentro de un proceso arm64**. Existe en este Mac:

```bash
nm -gU /usr/lib/system/libsystem_kernel.dylib | grep x86_64_compat
# 0000000000000c94 T _thread_set_x86_64_compat
```

Es decir: **CodeWeavers portó Wine a arm64 nativo pero sigue traduciendo x86 con Rosetta**, sólo que
por hilo en vez de por proceso. El nombre `*fex.so` es la interfaz de emulador que Wine espera, no
el motor que hay detrás.

**Consecuencia para el plan:** hay **dos caminos**, no uno, y conviene no confundirlos.

| | **Camino A — puente a Rosetta** | **Camino B — FEX propio** |
|---|---|---|
| Qué es | Lo que hace CrossOver hoy: unixlib fino sobre `thread_set_x86_64_compat` | Portar FEX a Darwin y construir `libwow64fex`/`libarm64ecfex` reales |
| Coste | **Bajo** (el puente son cientos de líneas) | **Alto** |
| Rendimiento | El de Rosetta, que es muy bueno | El de FEX, peor que Rosetta en general |
| Riesgo | Depende de que Apple conserve esa API en el subconjunto de juegos | Ninguno externo |
| Estado propio | Nada hecho | `patches/fex-a04b0241-darwin-*` + `work/fli-proton-arm64-20260808/` |

Que Apple mantenga `thread_set_x86_64_compat` es **plausible** —es exactamente el mecanismo que
necesita un traductor de juegos, que es lo que dice conservar— pero **no está garantizado por
escrito**. Por eso B no se descarta: es el seguro.

---

## 4. Qué se puede tomar del CrossOver ARM64, y qué no

### Sí: el tar de fuentes

`Crossover-ARM64/crossover-sources-20260731.tar` (959 MB). Es la publicación LGPL de CodeWeavers y
**es la base legítima del port**, igual que hoy usamos `crossover-sources-26.3.0.tar.gz`.

```bash
tar -tf Crossover-ARM64/crossover-sources-20260731.tar | awk -F/ '{print $2}' | sort -u
# android busybox cabextract dxmt dxvk freetype ghostscript glib gnutls gstreamer
# htmltextview makedep moltenvk po4a pyxdg vkd3d wine
```

Lo que aporta frente al tar de 26.3.0:

- **`sources/wine` con el port arm64 completo** — 13 820 archivos, incluido `dlls/winemac.drv`.
- **`sources/dxmt`** — que el tar de 26.3.0 **no traía**, y con un cross-file nuevo:

  ```ini
  # sources/dxmt/build-arm64ec.txt
  [binaries]
  c = 'arm64ec-w64-mingw32-gcc'
  ...
  [host_machine]
  cpu_family = 'aarch64'
  ```

- `sources/moltenvk`, `sources/dxvk`, `sources/vkd3d` actualizados.

**No trae FEX**, coherente con el hallazgo de §3: no lo usan.

### No: los binarios del bundle

`CrossOver Preview.app` es un build propietario de CodeWeavers. Por la regla 4 del proyecto
(*sólo fuentes open-source oficiales; nada de binarios propietarios copiados*) **no se copia nada de
ahí**. Sirve para dos cosas legítimas:

1. **Referencia de estructura** — saber qué debe existir y dónde.
2. **Verificación** — comparar que lo que compilamos tiene la misma forma.

### La estructura que hay que reproducir (medida en el bundle)

```
lib/wine/aarch64-unix/      7,3 MB   unixlibs nativos arm64: ntdll, win32u, winemac,
                                     winecoreaudio, winegstreamer, opengl32, winebus…
lib/wine/aarch64-windows/   602 MB   las DLL PE del lado Windows (ARM64/ARM64EC)
lib/wine/x86_64-windows/    163 MB   PE x86-64: lo que carga el juego emulado
lib/wine/i386-windows/      157 MB
lib/wine/x86_64-unix/       5,8 MB   el mundo antiguo, aún presente (build de transición)
lib/dxmt/aarch64-unix/winemetal.so       22 MB  ← el compilador de shaders vive aquí
lib/dxmt/aarch64-windows/{d3d11,d3d10core}.dll  ← DXMT en ARM64EC, 4,9 MB
lib/aarch64/libMoltenVK.dylib            arm64 nativo
lib/apple_gptk/                          SÓLO x86_64-unix y x86_64-windows
```

Tres lecturas importantes de esa tabla:

- **`winemac.so` está en `aarch64-unix`**: el driver de ventanas de macOS **ya está portado**. Era
  la incógnita más grande y está resuelta en fuentes LGPL.
- **DXMT ya existe en ARM64EC**, y con el reparto que le conviene: el PE es fino (4,9 MB) y el
  compilador de shaders con LLVM va en el unixlib nativo (22 MB). *Nuestro* build actual mete
  airconv dentro del PE (22 MB) — al portar conviene adoptar el reparto de arriba.
- **`lib/dxvk` no tiene `aarch64-*`**: DXVK aún no está en ARM64EC ni siquiera en CrossOver.
- El `d3d11.dll` de `lib/wine/aarch64-windows/` es **wined3d**, no DXMT (241 coincidencias de
  `wined3d` en sus strings): es el fallback genérico.

---

## 4-bis. Lo que dicen las fuentes primarias (consultadas el 2026-08-28)

### Wine

`wine-11.16` es del **22 de agosto de 2026**, seis días antes de esta investigación. Sus notas:
motor Mono 11.3.0 **con soporte ARM64**, decodificación de vídeo por VA-API, **manejo de
excepciones mejorado en ARM64EC** y 35 correcciones. Es decir: ARM64EC sigue recibiendo trabajo
activo cada quincena. La rama 11.x es de desarrollo; la estable es 11.0 (enero 2026), que cerró la
nueva arquitectura WoW64 — el mecanismo del que depende todo este modelo.

### CodeWeavers, en su propio anuncio

Sobre la Preview ARM64 de julio, y esto conviene citarlo tal cual porque **fija el calendario
ajeno**:

- **«no D3DMetal in this build»** — confirma por escrito lo que medimos en §5.
- **«Direct3D 12 support coming soon»**.
- Muchos lanzadores de juegos no funcionan; el build «no sirve para nada más que probar».
- **Todo eso debería estar resuelto para CrossOver 27, previsto a principios de 2027.**

Ese último punto ordena nuestra estrategia: **su tar de fuentes de CrossOver 27 llegará antes que
macOS 28** (otoño 2027). No tiene sentido adelantarles el port del runtime; tiene sentido preparar
lo que ellos no van a hacer por nosotros.

> **Discrepancia sin resolver.** CodeWeavers dice usar «su propio emulador x86 open source, FEX, en
> vez del traductor de Apple». Lo que medimos en el binario del 31 de julio es un puente de 176
> bytes a `thread_set_x86_64_compat` (§3). Puede ser un paso intermedio, que FEX se cargue aparte, o
> que la nota simplifique. **No lo damos por resuelto.** Y da igual para el plan: la interfaz de
> enganche es la misma (`__wine_unix_call_funcs` en `lib/wine/aarch64-unix/`), así que se puede
> empezar por el puente y cambiar el motor después sin rehacer nada.

### gamesir-labs — de donde sale nuestro DXMT

```bash
gh api "orgs/gamesir-labs/repos?per_page=100" \
   --jq '.[] | "\(.name)\t\(.pushed_at[0:10])\t\(.description)"'
```

| Repo | Último push | Qué es |
|---|---|---|
| `dxmt` | 2026-08-13 | **El que usamos.** «D3D12, D3D11, D3D10 y D3D9 for macOS / Wine» |
| `wine` | 2026-04-25 | **Un árbol de Wine basado en Proton para macOS**, con parches de WineCX, CrossOver y upstream |
| `rosettax87_jit` | 2026-04-14 | Fork de `Lifeisawful/rosettax87_jit`: hookea Rosetta para acelerar x87 y emitir AArch64 directo. **Optimiza Rosetta, no lo sustituye** |
| `MGL` | 2026-01-29 | OpenGL 4.6 sobre Metal |
| `dxvk`, `apitrace`, `Metal-Rust`, `gamehub-for-mac` | varios | Auxiliares |

Que exista `gamesir-labs/wine` como árbol **Proton para macOS** es relevante: es exactamente la
línea del laboratorio `work/fli-proton-arm64-20260808/`.

### DXMT: el upstream real es `3Shain/dxmt`

`gamesir-labs/dxmt` se declara **downstream** de [`3Shain/dxmt`](https://github.com/3Shain/dxmt)
(1160 estrellas, push del 2026-08-26). Y ahí está la novedad que más nos afecta:

| | Upstream `3Shain` | Downstream `gamesir-labs` (el nuestro) |
|---|---|---|
| Última versión | **v0.80** (2026-04-23) | v0.74 |
| **ARM64EC** | **Sí**: `build-arm64ec.txt` en `main`; «build: add arm64ec support» el 2026-03-09 y «ci: package ARM64EC build» el 2026-08-04 | **No**: sólo `build-win32.txt` y `build-win64.txt` |
| **D3D12** | No está ni en el plan de 1.0 | **Sí**: `src/d3d12/` completo, más `src/winemetal4` (Metal 4) |
| Licencia | MIT hasta v0.80; **LGPL a partir de ahí** | LGPL 2.1+ |

Verificado en local:

```bash
ls work/gamesir-labs-20260821/dxmt/src/    # …d3d12 winemetal4…
ls build/toolchain/dxmt-src/src/           # v0.72: sin d3d12
ls work/gamesir-labs-20260821/dxmt/build-*.txt   # sin arm64ec
```

**Y ésta es la tensión central del port:** lo que sustituye a D3DMetal (**D3D12**) está en el
downstream; lo que hace falta para ARM (**ARM64EC**) está en el upstream. Hoy **no hay un solo árbol
con las dos cosas**. Resolverlo es trabajo real, y hay tres salidas:

1. Esperar a que gamesir-labs rebase sobre `3Shain` v0.80+ *(lo más barato; hay que vigilarlo)*.
2. Portar el `build-arm64ec` del upstream al árbol de gamesir-labs *(unos pocos ficheros de build,
   pero el código nuevo de `d3d12`/`winemetal4` tiene que compilar en ARM64EC)*.
3. Usar el upstream para ARM y renunciar a D3D12 *(nos devuelve al problema de D3DMetal)*.

El roadmap de DXMT 1.0 (issue #151, actualizado el 2026-08-05) incluye además **«Cross-Process
Rendering — Wine upstream changes required»**, que es justo lo que resuelve nuestro parche
`dxmt-v0.72-cross-process-present`. Merece la pena seguirlo: puede que upstream converja con lo que
mantenemos a mano.

---

## 4-ter. Alguien ya lo ha hecho: `metalsharp/VKMT-Wine`

**Es el proyecto más avanzado que existe en esta línea y hay que estudiarlo antes de escribir una
línea de código propio.** Consultado el 2026-08-28.

> [`metalsharp/VKMT-Wine`](https://github.com/metalsharp/VKMT-Wine) — *«A 0-Rosetta Wine Build for
> Arm64 macOS Silicon, using a custom FEX build»*. **MIT**, creado el 24-07-2026, último push el
> 20-08-2026, release **VKMT-1.0** del 01-08-2026 con runtime completo empaquetado. CI con
> ShellCheck, Ruff, Clippy, CMake y CodeQL.

Su arquitectura es literalmente la que necesitamos:

```text
Apple Silicon macOS
└── ARM64 Wine host y wineserver
    ├── ARM64/AArch64 Windows
    ├── ARM64EC Windows
    ├── x86_64 Windows  ── FEX xtajit64
    └── i386/WoW64      ── FEX xtajit
```

Y sus invariantes son los que adoptaríamos: **host ARM64 nativo, Rosetta rechazado**,
`FEX_TSOENABLED=0`, cachés de código traducido versionadas por prefijo, y parada del wineserver
exacto al cambiar de proveedor.

### Su pila gráfica responde a nuestro problema

| Lane | D3D11/D3D9/DXGI | D3D12 | Puente nativo |
|---|---|---|---|
| ARM64/AArch64 | DXVK | **VKD3D-Proton** | puente Unix ARM64 de DXMT |
| ARM64EC | DXVK | **VKD3D-Proton** | puente Windows ARM64EC de DXMT |
| x86_64 | DXVK | **VKD3D-Proton** | `xtajit64` + DXMT |
| i386/WoW64 | DXVK | **VKD3D-Proton** | `xtajit` + DXMT |

**El sustituto de D3DMetal es VKD3D-Proton** (D3D12 → Vulkan → MoltenVK → Metal). No es una
suposición nuestra: es lo que ellos ejecutan. Y nosotros **ya tenemos la receta**:
`build/build-vkd3d-dxvk.sh` compila vkd3d 1.18, sólo que hoy no se instala en el runtime porque
D3D12 va por GPTK.

### Su auditoría de D3DMetal cierra el asunto

`D3DMetal.md` es una auditoría independiente que llega a nuestra misma conclusión con **una razón
técnica que no habíamos escrito**:

> «El árbol actual no contiene ningún loader Mach-O ni `dyld` para traducir un `D3DMetal.framework`
> o `libd3dshared.dylib` x86_64 de macOS dentro del host ARM64 de Wine. FEX traduce las rutas del
> guest Windows, pero **no puede por sí mismo convertir un proveedor x86_64 de macOS en un proveedor
> ARM64 nativo**.»

Es decir: **ni siquiera con FEX se salva D3DMetal**, porque FEX emula el *invitado Windows*, no
dylibs *de macOS*. Lo verifican por tres vías: el GPTK 3.0-2 instalado es x86_64;
[`utmapp/d3dmetal-native`](https://github.com/utmapp/d3dmetal-native) documenta que el framework de
Apple exige un proceso x86_64 bajo Rosetta; y CodeWeavers dice por escrito que su build ARM64 no lo
incluye. Su release es **D3DMetal-free por diseño**.

### Sus parches son el mapa de I+D

`patches/` (MIT) es, punto por punto, la lista de lo que hay que resolver:

| Parche | Qué resuelve |
|---|---|
| `wine-11.12-vkmt.patch` (192 KB) | Integración base de Wine ARM64 en macOS |
| `wine-11.12-no-tso-steam-runtime.patch` (839 KB) | Ordenación de memoria software y ruta de Steam |
| `wine-wow64-f108c09.patch` | Reparación del puente WoW64 |
| `fex-2607-vkmt.patch` · `fex-2607-no-tso-steam-runtime.patch` · `fex-wow64-nested-code-buffer-pin.patch` | **El proveedor FEX y la propiedad del buffer de código del guest** |
| **`dxmt-v0.80-xcode27-arm64.patch`** | **DXMT v0.80 compilando nativo en ARM64** |
| `dxvk-vkmt-moltenvk.patch` · `vkd3d-proton-tls.patch` · `vkd3d-proton-vkmt-wine-compat.patch` | DXVK y VKD3D-Proton sobre MoltenVK |
| `MoltenVK-vkmt-fatal-gaps.patch` (48 KB) · `moltenvk-665b11e7.patch` | **Huecos de Metal que MoltenVK no cubre** |
| `wine-mono-11.2.0-arm64-coree.patch` | Loader gestionado ARM64 |

**Coincidencia que no conviene desaprovechar: parten de FEX 2607, igual que nuestro laboratorio**
(`patches/fex-2607-x86_64-{fs,gs}-selector.patch`). Sus parches de Darwin y los nuestros
—`fex-a04b0241-darwin-{core,map-jit,guest-memory-bias}`— atacan el mismo problema desde dos sitios.
El suyo está probado de punta a punta; el nuestro no.

Su `MoltenVK-vkmt-fatal-gaps.patch` merece lectura aparte: nosotros mantenemos tres parches propios
de MoltenVK por Enshrouded, y es probable que haya solape.

### Lo que NO da

- 4 estrellas y dos meses de vida: **no es una dependencia, es una referencia**. Su release es un
  runtime empaquetado, no un producto con matriz de compatibilidad publicada.
- No hay lista de juegos verificados ni evidencia de rendimiento comparable a la nuestra.
- La licencia MIT cubre *su* material; Wine, FEX, DXMT, DXVK, VKD3D-Proton y MoltenVK conservan la
  suya. Estudiar y aprender: sí. Copiar el runtime: no.

## 4-quater. Lo que hace Valve, que puede cambiarlo todo

- **Proton 11.0** (abril 2026) añadió **soporte ARM64 con FEX integrado** (FEX-2604 → 2605), pensado
  para Steam Frame con Snapdragon. **FEX 2608** es de agosto de 2026. Es decir: Valve ya tiene
  **Proton + FEX funcionando en ARM64**, sólo que en Linux.
- **El cliente de Steam ya corre nativo en Apple Silicon** (beta), precisamente porque Apple retira
  Rosetta: sin cliente nativo, sus usuarios de Mac pierden la biblioteca en macOS 28.

Ese es el escenario que lo cambiaría todo: **si Valve porta Proton a macOS**, el problema deja de
ser nuestro. No hay anuncio, y la objeción técnica que circula es real —Proton haría
DX→Vulkan→Metal con shaders DXIL→SPIR-V→MSL, mientras GPTK mapea DX→Metal directo—, pero es
exactamente lo que VKMT ya hace con VKD3D-Proton+MoltenVK. **Ponerlo en seguimiento, no en el
camino crítico.**

---

## 5. El riesgo mayor sigue siendo D3DMetal

`lib/apple_gptk/` en la Preview **ARM64** sólo tiene `x86_64-unix` y `x86_64-windows`, y el propio
`D3DMetal.framework` es x86_64 (`lipo -archs` lo confirma). Apple no ha publicado GPTK arm64, y un
proceso ARM64EC no puede cargar un framework nativo x86-64.

Sin GPTK arm64, la ruta `external-d3dmetal` desaparece y con ella:

> Grim Dawn · DragonSword · Dragon's Dogma 2 · FINAL FANTASY TACTICS · Titan Quest II ·
> Borderlands 4 · Dragonkin · The Witcher 3 · **PixARK**

**Ese es el trabajo de fondo, y no depende de nada externo**: cada juego que se pueda mover de
D3DMetal a DXMT es un juego que sobrevive. La corrección de `UpdateSubresource` sobre textura
staging (v1.12.13) fue el primer paso real; por eso PixARK ya funciona sobre DXMT aunque conserve
su perfil.

---

## 6. Quién ya lo ha hecho: código del que aprender

| Proyecto | Qué aporta | Aplicable |
|---|---|---|
| **[Hangover](https://github.com/AndreRH/hangover)** (AndreRH) | Wine arm64 + FEX/Box64 en Linux. **Es el modelo conceptual**: el emulador se carga como DLL y se sale de la emulación en el syscall win32 / wine unix call, en vez de emular Wine entero | Arquitectura y `docs/COMPILE.md`. Es Linux; no hay port a macOS (issue #97 abierto desde 2020) |
| **[FEX-Emu](https://github.com/FEX-Emu/FEX)** + [wiki ARM64EC](https://wiki.fex-emu.com/index.php/Development:ARM64EC) | Los targets exactos: `-DMINGW_TRIPLE=arm64ec-w64-mingw32` → `libarm64ecfex.dll`; `-DMINGW_TRIPLE=aarch64-w64-mingw32` → `libwow64fex.dll` | Camino B. Upstream **no soporta macOS** y no lo tiene en plan |
| **Wine upstream 11.x** | ARM64EC completo desde 10.0, pulido en 11.x (11.16 mejora excepciones ARM64EC). Se configura con `--enable-archs=arm64ec,aarch64,i386` | Referencia del modelo; nuestro árbol sale del tar de CodeWeavers |
| `Jpkovas/FEX_MacOs` | Fork que dice apuntar a macOS ARM64 | **No fiable**: sin documentación macOS ni notas de estado. Mirar, no depender |
| Sikarugir, Whisky | Wrappers de Wine para macOS | Siguen dependiendo de Rosetta clásico. Sin valor para esto |

Y en casa: `patches/fex-a04b0241-darwin-{core-stage1,map-jit-stage2,guest-memory-bias-stage3}` más
dos de selectores `fs`/`gs`, con `work/fli-proton-arm64-20260808/` documentando una reentrada
acreditada en `libFEXCore.dylib`. Se abrió por el anticheat de FANTASY LIFE i; **es la única base
propia para el camino B**.

---

## 7. El plan

Tres calendarios ajenos ordenan el trabajo: **CrossOver 27** a principios de 2027 con su tar de
fuentes, **macOS 28** en otoño de 2027, y **VKMT-Wine**, que ya existe hoy y demuestra que el modelo
completo funciona. Nuestra ventaja es no tener que descubrir nada: hay un camino trazado y probado.

Regla de siempre: **una variable por paso y el motor estable no se toca**.

### Fase A — Quitarnos D3DMetal *(empezar ya; no depende de nadie)*

No hay proveedor ARM64 de D3DMetal y **no lo habrá**: ni Apple lo ha publicado, ni FEX puede
salvarlo (§4-ter). El sustituto está identificado y probado por VKMT: **VKD3D-Proton** para D3D12 y
**DXMT** para D3D11.

Dos frentes, ambos ejecutables hoy sobre el runtime x86_64 actual:

1. **Por cada juego con perfil GPTK**, probarlo sobre DXMT y anotar qué le falta al traductor. Cada
   carencia corregida vale para todos.
2. **Levantar la ruta VKD3D-Proton**, que ya tenemos a medias: `build/build-vkd3d-dxvk.sh` compila
   vkd3d 1.18 pero no se instala en el runtime. Ponerla en pie y medirla contra D3DMetal en los
   juegos D3D12 —Dragonkin, The Witcher 3, Borderlands 4— dice cuánto rendimiento cuesta el cambio.

*Hito:* tabla con los nueve juegos GPTK, su veredicto sobre DXMT y, para los D3D12, su medición
sobre VKD3D-Proton.

### Fase B — Resolver la tensión de DXMT *(en paralelo; nos bloquea)*

Necesitamos un árbol con **D3D12** (downstream `gamesir-labs`) **y ARM64EC** (upstream `3Shain`).
Hoy no existe… **pero VKMT publica `dxmt-v0.80-xcode27-arm64.patch`**, que es exactamente el puente
que falta. Estudiarlo antes de intentar nada propio.

Además, subir de v0.72 a v0.80 es **una release nuestra con matriz completa**: conviene hacerla
antes, sola, y no mezclada con el port a ARM.

*Hito:* un `d3d11.dll` ARM64EC compilado desde un árbol que también tenga `src/d3d12`.

### Fase C — Estudiar VKMT en serio *(barato y ahorra meses)*

Antes de escribir código de port: leer sus 18 parches y su `docs/architecture.md`, y **replicar su
runtime en una máquina de pruebas** para ver qué funciona de verdad. Preguntas concretas a
responder:

- ¿Qué hace `wine-11.12-no-tso-steam-runtime.patch` en 839 KB, y cuánto de eso necesitamos?
- ¿Su `MoltenVK-vkmt-fatal-gaps.patch` solapa con nuestros tres parches de Enshrouded?
- ¿Sus parches de FEX 2607 hacen innecesarios los `fex-a04b0241-darwin-*` del laboratorio, o los
  complementan? **Partimos de la misma versión de FEX**, así que es comparable línea a línea.

*Hito:* un documento corto que diga, parche a parche, *adoptamos · adaptamos · no aplica*.

### Fase D — Wine arm64 reproducible

```bash
CLEAN=/private/tmp/regression-wine-arm64
rm -rf "$CLEAN" && mkdir -p "$CLEAN"
tar -xf Crossover-ARM64/crossover-sources-20260731.tar -C "$CLEAN" sources/wine
cd "$CLEAN/sources/wine" && ./configure --enable-archs=arm64ec,aarch64,i386 && make -j
```

Primero **sin parches propios**: responde por muy poco esfuerzo si el árbol oficial levanta aquí.
Después, clasificar los ~20 `patches/wine-26.3.0-*` en *aplica igual · hay que reescribir · ya no
aplica*; los que tocan `signal_x86_64.c`, selectores de segmento o el loader son los sospechosos.

Cuando salga el tar de **CrossOver 27**, rehacer esta fase sobre él.

*Hito:* `wineboot` completo en una botella desechable.

### Fase E — El motor de emulación

Dos opciones, y ahora sabemos que **las dos están demostradas**:

- **El puente a Rosetta** (lo que hace CrossOver): unixlib fino sobre `thread_set_x86_64_compat`.
  Barato, rendimiento de Rosetta, y **dependiente de que Apple conserve esa API**.
- **FEX propio** (lo que hace VKMT, y lo que hace Valve en Linux): sin dependencia de Apple, con un
  camino ya trazado por terceros y por nuestro propio laboratorio.

Dado que **VKMT demuestra que FEX funciona en macOS**, el equilibrio cambia respecto a lo que
pensábamos: el puente deja de ser «la única opción barata» y pasa a ser «el atajo si hay prisa».
Diseñar contra la interfaz `__wine_unix_call_funcs` permite empezar por uno y cambiar al otro.

*Hito:* un `.exe` PE x86-64 de consola que imprime y termina.

### Fase F — Capas gráficas

- **DXMT** ARM64EC con el reparto de CrossOver (PE fino + LLVM en el unixlib arm64); `native_llvm_path`
  pasa a LLVM **arm64**, que Homebrew sirve nativo.
- **VKD3D-Proton** para D3D12, con los parches de VKMT como referencia.
- **MoltenVK** arm64, reconciliando nuestros parches de Enshrouded con los suyos.
- **DXVK**: VKMT lo tiene en ARM64; CrossOver aún no.

*Hito:* la tienda de Steam renderizando, que es el canario de siempre.

### Fase G — El aparato de sellado

Todo asume x86_64: `toolchain/x86/`, los `-arch x86_64`, los PIN, `verify-*.sh`, `ComponentHealth` y
`RuntimeModuleCatalog`. Decidir si el runtime arm64 **convive** con el x86_64 —como CrossOver, y es
lo sensato en la transición— o lo sustituye. Convivir **duplica la matriz**; hay que presupuestarlo.

*Hito:* matriz verde en las dos arquitecturas.

---

## 8. Qué haría la primera semana

Nada de esto toca el motor estable:

1. **Levantar VKD3D-Proton** sobre el runtime actual y medirlo contra D3DMetal en un juego D3D12.
   Es la pregunta que más decide: si el coste en rendimiento es asumible, D3DMetal deja de dar
   miedo.
2. **Leer los 18 parches de VKMT** y escribir el *adoptamos · adaptamos · no aplica*. Es lectura,
   no código, y puede ahorrar meses.
3. **Fase A sobre un juego**: el que menos dependa de D3D12 —Grim Dawn o FFT— sobre DXMT.
4. **Compilar el Wine `aarch64` del tar sin parches propios.**

Y poner en seguimiento cuatro cosas que llegarán solas y cambian el plan: el tar de **CrossOver 27**,
el rebase de **`gamesir-labs/dxmt`** sobre v0.80+, el **issue #166 de DXMT** (cross-process
rendering, que podría hacer innecesario un parche que hoy mantenemos), y cualquier movimiento de
**Valve hacia Proton en macOS**.

---

## 9. Fuentes

- [Rosetta 2 discontinuation notice — 9to5Mac, 2026-02-16](https://9to5mac.com/2026/02/16/macos-26-4-will-notify-users-of-rosetta-2-discontinuation/)
- [Rosetta 2 ends with macOS 27 Golden Gate](https://www.squaredtech.co/rosetta-2-ends-with-macos-27-golden-gate-what-it-means-for-your-mac)
- [Rosetta 2 end of support: macOS 28 — TechTimes, 2026-05-30](https://www.techtimes.com/articles/317445/20260530/rosetta-2-end-support-macos-28-will-break-18000-intel-apps-2027.htm)
- [CrossOver Preview: The right to bear ARM64 on Mac — CodeWeavers, 2026-07-31](https://www.codeweavers.com/blog/mjohnson/2026/7/31/crossover-preview-the-right-to-bear-arm64-on-mac)
- [PortJump Update: macOS support for Intel based applications — CodeWeavers, 2026-06-19](https://www.codeweavers.com/blog/orudge/2026/6/19/portjump-update-upcoming-changes-to-macos-support-for-intel-based-applications)
- [First Apple Silicon CrossOver build in testing — AppleInsider, 2026-07-31](https://appleinsider.com/articles/26/07/31/first-apple-silicon-native-crossover-build-in-testing-as-rosettas-end-nears)
- [Wine 11.16 release notes](https://gitlab.winehq.org/wine/wine/-/releases/wine-11.16) · [Wine 11.0 — ADMIN Magazine](https://www.admin-magazine.com/News/Wine-11-Released)
- [FEX-Emu](https://fex-emu.com/) · [FEX-Emu/FEX](https://github.com/FEX-Emu/FEX) · [Development:ARM64EC — FEX wiki](https://wiki.fex-emu.com/index.php/Development:ARM64EC)
- [Hangover](https://github.com/AndreRH/hangover) · [Hangover 11.0 — Phoronix](https://www.phoronix.com/news/Hangover-11.0-Released)
- [3Shain/dxmt](https://github.com/3Shain/dxmt) (upstream real de DXMT) · [Roadmap DXMT 1.0, issue #151](https://github.com/3Shain/dxmt/issues/151) · [Release v0.80](https://github.com/3Shain/dxmt/releases/tag/v0.80)
- [gamesir-labs](https://github.com/gamesir-labs) — `dxmt` (downstream con D3D12), `wine` (árbol Proton para macOS), `rosettax87_jit`, `MGL`
- [metalsharp/VKMT-Wine](https://github.com/metalsharp/VKMT-Wine) — Wine ARM64 + FEX en macOS, 0-Rosetta · [su auditoría de D3DMetal](https://github.com/metalsharp/VKMT-Wine/blob/main/D3DMetal.md) · [sus parches](https://github.com/metalsharp/VKMT-Wine/tree/main/patches)
- [utmapp/d3dmetal-native](https://github.com/utmapp/d3dmetal-native) — documenta que D3DMetal exige un proceso x86_64 bajo Rosetta
- [Proton 11.0-1 Beta 3: FEX para ARM64 — GamingOnLinux, 2026-05](https://www.gamingonlinux.com/2026/05/proton-11-0-1-beta-3-brings-fex-upgrades-for-linux-arm64-like-the-steam-frame/) · [FEX 2608 — Phoronix](https://www.phoronix.com/news/FEX-2608-Released)
- [i1rr/steam-arm64-mac](https://github.com/i1rr/steam-arm64-mac) — Steam nativo en Apple Silicon sin Rosetta
- [CrossOver ARM64 y FEX probados — blendlogic](https://blendlogic.com/posts/crossover-arm64-fex-mac-gaming.html) · [CrossOver Goes Native on Apple Silicon — TUAW, 2026-08-02](https://www.tuaw.com/2026/08/02/crossover-goes-native-on-apple-silicon)
- [Rosetta 2 en un Mac con Apple silicon — Apple](https://support.apple.com/guide/security/rosetta-2-on-a-mac-with-apple-silicon-secebb113be1/web)
