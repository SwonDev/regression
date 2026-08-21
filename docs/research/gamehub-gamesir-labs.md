# Expediente: el motor de GameHub for Mac (gamesir-labs)

> **Estado: investigación de código fuente, sin ejecutar.** Todo lo que sigue procede de leer los
> repositorios en los commits fijados abajo. **Nada se ha compilado, instalado ni lanzado.** Cada
> afirmación de comportamiento es una hipótesis hasta que pase la matriz de validación de `AGENTS.md`
> con captura mirada. No se ha tocado el runtime, la botella ni el bundle de Regression.

- **Fecha de la investigación**: 2026-08-21
- **Organización**: <https://github.com/orgs/gamesir-labs/repositories>
- **Producto**: GameHub for Mac (beta, <https://gamemac.com>), de GameSir Labs
- **Relevancia**: es el mismo problema que resuelve Regression —Steam de Windows sobre macOS con
  motor de compatibilidad propio—, resuelto por otro equipo y con el código publicado.

---

## 1. Inventario: qué hay de verdad en cada repositorio

Lo primero fue separar el trabajo original de los espejos. Cuatro de los ocho repositorios **no
contienen ni un solo commit propio**: son copias sin modificar. Comparación hecha contra el upstream
de cada uno con la API de GitHub.

| Repositorio | Origen | Delta propio | Licencia | Veredicto |
|---|---|---|---|---|
| **`dxmt`** | fork de `3Shain/dxmt` | **+1755 / −1254 (divergido)**, 656 commits del equipo | LGPL-2.1+ | **Oro.** D3D12 y D3D9 sobre Metal |
| **`wine`** | árbol propio, Wine 10.0 | **1706 commits** sobre `Release 10.0` | LGPL-2.1+ | **Oro.** Proton para macOS + parches por juego |
| **`apitrace`** | árbol propio | **182 commits** de 时雨 | sin declarar | Alto. Trazado D3D dentro de Wine en macOS |
| **`Metal-Rust`** | propio, v1.0.0 | 23 commits | Apache-2.0 | Sin valor para Regression (Swift/C, no Rust) |
| `dxvk` | fork de `K0bin/dxvk` | **0 propios**, 380 por detrás | Zlib | Espejo obsoleto. Ignorar |
| `MGL` | fork de `openglonmetal/MGL` | **0 propios**, idéntico | Apache-2.0 | Espejo. El valor está en el upstream |
| `rosettax87_jit` | fork de `Lifeisawful/rosettax87_jit` | **0 propios**, 90 por detrás | MIT | Espejo. Usar el upstream |
| `gamehub-for-mac` | tracker de issues | 35 issues | — | Inteligencia de campo, sin código |

**Conclusión del inventario:** el trabajo original de GameSir Labs está en `dxmt`, `wine` y
`apitrace`. Lo demás son dependencias que espejaron para fijar su cadena de build.

### Autoría de `dxmt`

| Autor | Commits | Quién es |
|---|---|---|
| 3Shain / Feifan He (`san3shain@outlook.com`) | 1060 | Autor **upstream** de DXMT, empleado de CodeWeavers |
| 时雨 | 515 | Equipo GameSir |
| xiaoyi1212 | 141 | Equipo GameSir |

Los 656 commits del equipo se reparten así por área, y el reparto dice exactamente dónde han
invertido: `fix(d3d12)` 118 · `test(d3d12)` 104 · `perf(d3d12)` 46 · `fix(dxmt)` 25 · `chore(dxil)` 23
· `fix(airconv)` 22 · `chore(apitrace)` 21 · `fix(d3d11)` 10 · `fix(winemetal4)` 7.

**Su aportación propia es, casi por completo, llevar DXMT a D3D12.**

---

## 2. Hallazgo principal: overlays por proceso en el loader de Wine

Es el hallazgo que justifica todo el expediente, porque **resuelve el conflicto que Regression tiene
documentado como irresoluble en `README` §8** (la `dxgi` de DXMT es intocable en pareja, pero D3D12
necesita la `dxgi` de Wine).

GameHub añade tres mecanismos genéricos al loader, documentados en la propia página de manual de Wine:

### `WINE_PROCESS_ENV_DIR` — entorno por ejecutable
`loader: Add per-process environment directory overlays` (576 líneas: `loader/main.c`,
`dlls/ntdll/unix/env.c`, `dlls/ntdll/unix/process.c`, `loader/wine.man.in`).

Antes de arrancar cada proceso hijo, Wine busca `<basename>.env` (comparación **insensible a
mayúsculas**) en ese directorio. Formato `NAME=VALUE`, `#` comenta, `unset` elimina una variable.
Cada proceso parte del entorno común y aplica encima su fichero; **un proceso sin fichero no hereda
el override del anterior**.

El ejemplo del manual, literal, es el caso de Regression:

> Si el directorio contiene `cef.exe.env` con `WINEDLLPATH=/opt/dxmt/lib` y `gta5.exe.env` con
> `WINEDLLPATH=/opt/gptk/lib`, entonces `Cef.exe` usará DXMT mientras que `gta5.exe` usará GPTK.

Esto es **la coexistencia DXMT / Apple GPTK por proceso**, hecha en el loader, sin registro global y
sin variables globales — es decir, cumpliendo la regla 6 de `AGENTS.md` por construcción en lugar de
a base de parches por *basename*.

### `WINE_PROCESS_CMDLINE_DIR` — argumentos por ejecutable
`kernelbase: Add per-process command-line override files`. Busca `<basename>.cmd` y **añade** su
contenido a la línea de comandos del hijo. Un `.cmd` **vacío desactiva** el hack interno de Wine para
ese ejecutable. El ejemplo del manual es `cef.exe.cmd` con `--disable-gpu --use-angle=vulkan`.

### `WINEDLLDIR` con builtins
`ntdll: Allow WINEDLLDIR overlays to add builtins` (`dlls/ntdll/loader.c`, +181 líneas de test en
`dlls/kernel32/tests/process.c`). Permite que un overlay **aporte** módulos builtin, no solo
sustituya. Es lo que hace utilizable el `WINEDLLPATH` por proceso del ejemplo anterior.

**Por qué importa tanto:** hoy Regression aísla cada juego con parches propios de Wine activados por
*basename* exacto (`per-process-graphics-routing`, `process-scoped-dll-isolation`…). Funciona, pero
cada juego nuevo exige tocar C y recompilar el runtime. Este mecanismo hace lo mismo **con un fichero
de texto por ejecutable**, y encaja de forma natural con `GameRuntimeProfileCatalog`: un perfil
compilado podría materializar su `.env`/`.cmd` en un directorio sellado del bundle. Sigue sin haber
comandos aprendidos desde SQLite; sigue siendo cerrado y versionado.

---

## 3. DXMT: D3D12 sobre Metal 4 y D3D9 sobre Metal

### 3.1 D3D12 — real, grande, y con un techo de sistema

En la rama `main` hay una implementación completa: **42 ficheros, 50.678 líneas** en `src/d3d12`,
que compila **`d3d12.dll` y `d3d12core.dll`** con soporte de **Agility SDK** (`d3d12_agility.hpp`).
Cubre command list/allocator/queue, descriptor heap con *journal* y *mirror*, root signature,
pipeline, fence, query, heap, sparse/tiled resources y un backend DXGI propio
(`d3d12_dxgi_backend.cpp`). Añaden un parser **DXIL** (el formato de shader de D3D12, SM6) sobre su
conversor `airconv`.

La cobertura de test es seria: **127 ficheros `_spec.cpp`** en `tests/d3d12`, 700+ declaraciones
GoogleTest, manifiesto de superficie pública en `tests/coverage/d3d12_coverage.json` (165 métodos
registrados en la última ronda), *fault injection* y un *mutation runner*. El plan de test
suplementario (`dxmt_d3d12_metal4_supplemental_test_plan.md`, en chino, fechado 2026-07-17) compara
contra **WARP** como oráculo.

> ⛔ **Restricción dura, verificada en el código.** El D3D12 se compila con `-DDXMT_DX12_METAL4=1`,
> se instala con `install_tag: 'runtime-metal4'`, depende de `winemetal4_dep` y comprueba en
> `src/d3d12/d3d12.cpp:116` → `device.supportsFamily(WMTGPUFamilyMetal4)`. El módulo `winemetal4`
> usa APIs **MTL4 reales** (`MTL4CommandQueue`, `MTL4CommandAllocator`, `MTL4ArgumentTable`,
> `MTL4CounterHeap`). **Metal 4 exige macOS 26.** Regression soporta macOS 14+.
>
> Es decir: **el D3D12 de DXMT no sustituye a Apple GPTK en el parque instalado de Regression.**
> Sustituiría a GPTK **solo en macOS 26+**, conviviendo con GPTK en versiones anteriores. Y
> justamente esa convivencia es la que habilita el overlay por proceso de §2.

`d3d11` sigue dependiendo de `winemetal_dep` (Metal 3), así que **la ruta D3D11 que usa Regression
hoy no se ve afectada por el techo de Metal 4**.

### 3.2 D3D9 — en la rama `dev-main`, no en `main`

`origin/dev-main` (404 commits por delante de `main`, 37 de ellos de `d3d9`) añade **`src/d3d9` con
72 ficheros**: implementación D3D9 nativa sobre Metal, con suite de conformidad propia, trabajo de
rendimiento (`perf(d3d9): keep the resolved half of a draw off the calling thread`, `transform the
fixed-function lights only when they move`, `rebuild only the state axes a draw changed`), caché de
shaders versionada y nombre de la capa en el **Metal HUD**.

Para Regression esto es la vía para **retirar DXVK 1.10.3**, que es de 2022 y va sobre MoltenVK
(Vulkan → Metal, dos traducciones). D3D9 nativo sobre Metal elimina una capa entera.

### 3.3 Configuración por juego que hoy no tenemos

`dxmt.conf` y `DXMT_CONFIG`/`DXMT_CONFIG_FILE` exponen, entre otras:

- `d3d11.preferredMaxFrameRate` / `d3d12.preferredMaxFrameRate` — **frame pacing por Metal**
  (`presentDrawableAfterMinimumDuration`), no simulado en CPU.
- `DXMT_METALFX_SPATIAL_SWAPCHAIN=1` + `d3d11.metalSpatialUpscaleFactor` — **MetalFX Spatial
  Upscaling** en el swapchain. Rendimiento gratis en juegos que van justos.
- `dxgi.customVendorId` / `customDeviceId` / `customDeviceDesc` / `forceSDR` — mentir sobre la GPU;
  es el mecanismo genérico para los juegos que hacen detección de hardware.
- `d3d11.ignoreMapFlagNoWait` — ya activado por defecto para Sonic X Shadow Generations.
- `dxmt.shaderMetalVersion` (310 = macOS 14, 320 = macOS 15).

Y `docs/COMPATIBILITY_FLAG.md` documenta los **Compatibility Issue Flags** del Metal HUD con
`-Ddxmt_debug=1`: una línea recta significa que todo va bien, y letras concretas indican qué no está
soportado (tessellator output, pipeline geometry-tessellation, `DrawAuto()`, comandos predicados,
stream output appending, múltiples streams SO). Es un **diagnóstico visual inmediato** que encaja con
el protocolo de captura mirada de Regression.

---

## 4. El Wine de GameHub: Proton para macOS

Su `README.md` lo declara sin ambigüedad:

> This repository is a **Proton-based Wine tree** with additional patches for macOS compatibility,
> graphics integration, and game-specific behavior. The patch set is curated from multiple sources,
> including: **WineCX, CrossOver (CodeWeavers), upstream Wine**…

Base **Wine 10.0** (`Release 10.0.`, 2025-01-21) con **1706 commits** encima. La mayoría son el
patchset de Proton; el bloque final son sus parches propios de macOS, firmados como
`gamesir <gamesir@gamemac.com>`.

### 4.1 Parches que atacan problemas abiertos o documentados de Regression

| Parche de GameHub | Qué toca en Regression |
|---|---|
| `win32u: Disable display mode emulation by default` + `winemac.drv: Ignore kDisplayModeSafeFlag for display modes on Apple Silicon` | **Dragon's Dogma 2 (letterbox 16:9)** y **Rotwood (superficie 1512×870)**, las dos incidencias abiertas del §7 de `CLAUDE.md` |
| `user32: Skip specific dialogs and message boxes defined by environment variables` | El **diálogo modal de Steam Cloud que bloquea el IPC**, causa ambiental de la regla 10 |
| `kernelbase: Force single-process mode for steamwebhelper` (×2) | Los **`services.exe` huérfanos e iconos Steam fantasma** de la regla 10, y la regla 15 sobre no atribuir backend por el texto de `ps` |
| `ntdll: Apply binary patches for known problematic web engine DLLs` | **CEF**, la tienda de Steam: la fila más crítica de la matriz de validación |
| `winemac.drv: Add graphics driver hooks for D3DMetal (GPTK)` · `ntdll: Handle MS ABI calls from d3dmetal (GPTK)` · `winemac.drv: Add registry access callbacks used by d3dmetal to init params` · `ntdll: Register loaded PE code ranges with libd3dshared on macOS` | El pegamento **Apple GPTK / D3DMetal** que Regression mantiene a mano en perfiles aislados |
| `setupapi: HACK: Fix GPU LUID reporting for Diablo IV + D3DMetal` | Misma familia: detección de GPU con GPTK |
| `server: Switch to mach_msg on macOS (mach_msg2())` + `ntdll: ...` (×4 commits) | **Rendimiento del wineserver** en macOS |
| `ntdll: Force use of TLS expansion slots on macOS to avoid GS conflict` · `Initialize PEB pointer in macOS gs segment` · `Hook localtime to prevent corruption of the PEB pointer on macOS` | Corrupción de PEB por el segmento GS, clase de bug muy cara de diagnosticar |
| `ntdll: Add W|X write fault hack for macOS` (partes 1 y 2) | JIT y memoria W^X bajo Hardened Runtime |
| `ntdll: Don't use private writable mappings on macOS` (Wine-Bug 58008) · `Free additional low memory on macOS to avoid address space conflicts` · `Prefer reserved area for virtual memory allocation` | Conflictos de espacio de direcciones — misma familia que los `pagezero`/`fixed mapping` del laboratorio FLI |
| `winecoreaudio.drv: Switch to kAudioUnitSubType_DefaultOutput` | Cambio de dispositivo de audio en caliente |
| `server: Flush and fsync registry files before closing` | Integridad del registro de la botella |
| `ntdll: Refuse to load builtins lacking architecture-specific PE directory` | Emparenta con la regla 12 (**PE sin strip**) |
| `services: Increase default service pipe timeout for Rosetta` | Arranques lentos bajo traducción |

### 4.2 Catálogo de arreglos por juego, listo para leer

Este es el «blindar de golpe muchísimos juegos» de la petición. Cada uno es un commit acotado y
legible: **GTA V / Rockstar Launcher**, **CS2** (detección de GPU en Apple Silicon), **Diablo IV**,
**Path of Exile 2** (MoltenVK), **Manor Lords**, **Battle.net** (descriptores de seguridad),
**Halo MCC** (`ConvertThreadToFiberEx`), **Marvel Rivals**, **Helldivers 2** (actualizaciones de
icono), **Persona 5 Strikers**, **Skyrim SE** (stutter de ratón + DPI awareness),
**Assassin's Creed Rogue** (stutter de ratón), **HoYoPlay**, **Ubisoft Connect** (SwiftShader ICD),
**EA Desktop**, **Slay the Spire 2**, **Forza Horizon 4/5**, **WRC Generations**, **The Sims**…

⚠️ Ojo: una parte de estos parches son de la rama `winex11.drv` (Proton/Linux) y **no aplican** a
`winemac.drv`. Hay que clasificarlos uno a uno antes de prometer nada.

### 4.3 Rosetta x87 con JIT

`ntdll: Support 'ROSETTA_X87_PATH'` + `ntdll: Stash DYLD_INSERT_LIBRARIES before Rosetta loader exec`.
El README lo documenta: cuando Wine detecta un ejecutable PE i386 inicial por la ruta *no-preloader*,
**se re-ejecuta a través del loader configurado** para que Rosetta use la ruta x87 con JIT.

El loader es `Lifeisawful/rosettax87_jit` (**MIT**): engancha Rosetta, sustituye los manejadores de
instrucciones x87 por implementaciones más rápidas y parchea el pipeline de traducción para emitir
AArch64 directamente.

> ⛔ **Coste real, no negociable.** Exige **macOS 15+** y el entitlement
> `com.apple.security.cs.debugger`, con un diálogo de autorización de depuración al usuario — o, peor,
> desactivar la protección de depuración de SIP (`csrutil enable --without debug`). Para un producto
> firmado y sellado como Regression eso es una **degradación de la postura de seguridad** y una
> decisión de producto, no técnica. Se documenta como opción; **no se propone activarlo**.

Interés colateral: `wow64cpu: Implement is_rosetta2`, `server: Implement is_apple_silicon` y
`ntdll: Implement handle_cet_nop` son piezas directamente útiles para el laboratorio FLI.

---

## 4.4 ⚠️ Dónde **no** está su base de conocimiento por juego

Medido sobre el código, no supuesto. Es la corrección más importante de este expediente, porque la
impresión natural al ver el catálogo de parches es la contraria:

| Medida | Resultado |
|---|---|
| Commits con `HACK` en todo el árbol de Wine | **597** |
| De esos, firmados por `gamesir` | **19** |
| Ejecutables `.exe` citados en el código de Wine | 44, de los que ~28 son juego/launcher |
| Ejecutables `.exe` citados en **todo DXMT** | **1** |
| Base de datos de juegos (JSON/conf) en los repos | **ninguna** |

Los 597 `HACK` son el **patchset de Proton**, público y de Valve, en su mayoría orientado a Linux.
Los hacks de JRPG (`MarySkelter`, `NeptuniaVirtualStars`, `DeathEndReQuest`) son de **KingKrouch**
(2025-06-17) y el de `start_protected_game.exe` es de **Paul Gofman** (Valve): heredados, no suyos.
Lo propio de GameSir son ~19 parches de 2026-04: GTA5, cs2, SkyrimSE, SlayTheSpire2, EADesktop,
Battle.net, steamwebhelper, HoYoPlay, Marvel Rivals, Helldivers 2, Persona 5 Strikers, Manor Lords…

**Conclusión: la base de compatibilidad por juego de GameHub no está publicada.** Vive en su cliente
cerrado (gamemac.com). Lo que han publicado es **el motor**. DXMT no tiene ni una tabla de perfiles
por ejecutable: su calidad por juego viene de la implementación general, no de una lista.

Esto tiene una consecuencia práctica y buena: si sus juegos funcionan por **capacidad general del
motor** y no por una lista de casos, entonces **portar los parches generales transfiere el beneficio**
sin necesidad de adoptar su runtime entero.

## 5. apitrace: el diagnóstico que a Regression le falta

`gamesir-labs/apitrace` tiene **182 commits propios** (perf y corrección de `retrace`: compilación de
dispatch tipado, estado de replay ordenado por evento, copias de descriptores de sampler). DXMT lo
integra opcionalmente: `option('apitrace_builtin')` y `option('apitrace_source_path')`.

Hoy Regression diagnostica con preflight, telemetría, logs y **captura visual mirada**. Un trazado de
llamadas D3D reproducible dentro de Wine en macOS permitiría pasar de «la tienda sale negra» a «la
llamada N devuelve X», que es exactamente el salto que pide el protocolo de una variable por cambio.

---

## 6. MGL: la pista para Cursemark y el techo de OpenGL

`MGL` es **OpenGL 4.6 sobre Metal** (`openglonmetal/MGL`, Apache-2.0). El espejo de gamesir-labs es
idéntico al upstream, así que el valor está en el proyecto original — pero el hecho de que lo
espejaran indica que evaluaron el mismo problema.

macOS solo expone **OpenGL 4.1**. La regla 26 de `AGENTS.md` existe por eso: Cursemark (HashLink)
necesita siete funciones GL de compute/SSBO que macOS no ofrece, y Regression resuelve **stubs que no
hacen el trabajo y registran un `ERR` si se invocan**. MGL es la única vía conocida para que esas
funciones **existan de verdad**. Es una línea de investigación propia, grande y aparte; se registra
aquí para no perderla.

---

## 7. Inteligencia de campo: el tracker `gamehub-for-mac`

35 issues, 31 abiertas, 263 estrellas. Confirma que GameHub **no ha resuelto lo que Regression tampoco
ha resuelto**, y eso valida la línea actual:

- **#19 «Anti cheat failed loading»** — el anticheat sigue sin resolverse también para ellos.
  Refuerza que la posición de Regression con FANTASY LIFE i (EAC, `208 Cannot run under Virtual
  Machine`) es la correcta y que el laboratorio FLI sigue siendo I+D aparte.
- **#23 Helldivers 2** pantalla negra · **#27 Spider-Man 2** personajes en T-pose · **#34 Mewgenics**
  «Could not create GL context» (justo el fallo que Regression corrigió de forma **general** en
  `winemac.drv` con la regla 25 de contexto GL core forward-compatible) · **#33 Europa Universalis IV**
  launcher que no renderiza.
- Varias son de infraestructura Steam (depots, betakeys, appmanifests), no del motor.

---

## 8. Restricciones, riesgos y lo que **no** se puede hacer

1. **Licencias.** `dxmt` y `wine` son **LGPL-2.1+**; `rosettax87_jit` **MIT**; `MGL` y `Metal-Rust`
   **Apache-2.0**. `apitrace` **no declara licencia** en su copia → tratar como *no reutilizable*
   hasta aclararlo. Todo lo demás es compatible con la regla 4 (legalidad limpia), **con atribución
   obligatoria** y conservando los avisos de copyright de CodeWeavers y de 3Shain.
2. **Su Wine es Proton + WineCX + CrossOver, base Wine 10.0.** Regression compila desde el **tar FOSS
   oficial de CrossOver 26.3.0** (regla 27). **No se propone cambiar de base**: sería tirar el
   contrato del runtime sellado, los PIN y la evidencia del builder. La vía correcta es
   **portar parches concretos**, uno por uno, con su matriz.
3. **El D3D12 de DXMT exige Metal 4 → macOS 26.** No sustituye a Apple GPTK en macOS 14/15.
4. **Rosetta x87 JIT exige el entitlement de depurador y macOS 15+.** Degrada la postura de seguridad
   del bundle firmado. Decisión del usuario, no automática.
5. **Parte del catálogo por juego es `winex11.drv`** (Linux) y no aplica a `winemac.drv`.
6. **La regla 2 de `AGENTS.md` sigue vigente**: no se instala, abre ni consulta CrossOver *el
   producto* para diagnosticar. Leer **código fuente LGPL publicado** no es eso, pero cualquier
   parche importado debe quedar registrado con su procedencia.
7. **Nada de esto está compilado ni probado.** Cada bloque necesita su fila de la matriz de
   validación con captura mirada antes de integrarse.

---

## 9. Plan de aprovechamiento propuesto (una variable por cambio)

Ordenado por relación valor/riesgo. Cada fase es independiente y reversible.

| Fase | Qué | Por qué primero | Matriz a validar |
|---|---|---|---|
| **F1** | Portar `WINE_PROCESS_ENV_DIR` + `WINEDLLDIR` builtins al Wine de Regression | Desbloquea la convivencia DXMT/GPTK por proceso (`README` §8) y sustituye parches C por ficheros de perfil | Wine: tienda + Moonlighter 2 + Palworld, y un perfil blindado no afectado |
| **F2** | Portar los dos parches de **display mode** (`Disable display mode emulation`, `Ignore kDisplayModeSafeFlag`) | Ataca las **dos únicas incidencias abiertas** con juego validado (Dragon's Dogma 2, Rotwood) | Wine + los dos juegos + tienda |
| **F3** | `MetalFX Spatial` + `preferredMaxFrameRate` vía `dxmt.conf` por perfil | **Sin tocar código**: es configuración de la DXMT que ya corre | DXMT: tienda (CEF) + Palworld |
| **F4** | `user32` skip de diálogos + `steamwebhelper` single-process | Elimina dos causas ambientales recurrentes de la regla 10 | Launcher + arranque desde cero |
| **F5** | `WINE_PROCESS_CMDLINE_DIR` | Completa F1; argumentos por ejecutable sin recompilar | Igual que F1 |
| **F6** | Evaluar **DXMT D3D9** (`dev-main`) frente a DXVK 1.10.3 | Quita una capa entera de traducción; rama aún no fusionada a `main` | DXVK/d3d9: un juego D3D9 + tienda |
| **F7** | Triaje del catálogo de parches por juego (clasificar `winemac` vs `winex11`) | Es el «blindar muchos juegos de golpe», pero exige clasificación previa | Una fila por juego |
| **F8** | `apitrace` como herramienta de diagnóstico (no de producto) | Salto cualitativo en depuración | No aplica: no entra en el bundle |
| **F9** | **DXMT D3D12 / Metal 4** como ruta opcional en macOS 26+ | Alto valor, techo de sistema; depende de F1 para convivir con GPTK | D3D12 completa + GPTK no afectado |
| **F10** | **MGL** para el techo de OpenGL 4.1 (Cursemark) | Investigación grande y aparte | Expediente propio |

**Fuera de alcance por decisión explícita:** cambiar la base del runtime a Proton, activar el loader
Rosetta x87 (entitlement de depurador), y `Metal-Rust` (no aplica al stack Swift/C).

---

## 9.bis Triaje ejecutado contra nuestro árbol (2026-08-21)

El plan de §9 se escribió **antes** de comparar sus parches con lo que Regression ya tiene. Hecha la
comparación, cambia bastante. Estos son los datos, no impresiones.

### Ya lo teníamos: el mecanismo por proceso

Regression **ya implementa** el enrutado por proceso que parecía el hallazgo estrella:

- `patches/wine-26.3.0-per-process-graphics-routing.patch` (383 líneas, `dlls/ntdll/unix/loader.c`):
  enruta backend gráfico, `WINEDLLPATH`, `CX_ACTIVE_GRAPHICS_BACKEND`, `MVK_CONFIG_*` y
  `REGRESSION_RETINA_MODE` por ejecutable.
- `patches/wine-26.3.0-process-scoped-dll-isolation.patch` (168 líneas): rutas
  `REGRESSION_PROCESS_DLL_ISOLATION_ROUTE_<N>` bajo `REGRESSION_COMPILED_REPAIR`.

Portar `WINE_PROCESS_ENV_DIR` sería **duplicar** capacidad existente. Y su versión lee ficheros
`.env` de un directorio, lo que introduce una superficie de configuración en disco que el modelo de
runtime sellado evita a propósito. **F1 queda descartada.**

### Ya lo teníamos: la base es más nueva que la suya

Nuestra base es **Wine 11.0 (CrossOver 26.3.0)**; la suya es **Wine 10.0 (Proton)**. Verificado por
grep sobre `sources-26.3.0/wine`:

| Parche de GameHub | ¿Presente ya? |
|---|---|
| `mach_msg2` (IPC del wineserver) | ✅ `mach_msg2_trap`, 16 usos |
| GPTK / d3dmetal / libd3dshared | ✅ en CX (`setupapi/devinst.c`, `ntdll/loader.c`) y en nuestros parches |
| msync · esync · TLS expansion slots · PEB en segmento gs | ✅ |
| Parches binarios a DLLs de motor web (CEF) | ✅ |
| `winecoreaudio` DefaultOutput · `kDisplayModeSafeFlag` | ✅ |
| `GetDiskFreeSpaceExW` · `CreateSymbolicLink` · reserved area para VA | ✅ |
| **`user32`: skip de diálogos por variable de entorno** | ❌ ausente |
| **`kernelbase`: steamwebhelper `--single-process`** | ❌ ausente |

CodeWeavers ya había subido el trabajo de macOS a CX 26.3.0; GameHub lo estaba reimplementando sobre
Proton. **La cosecha de parches de Wine es mucho menor de lo que parecía.**

### El parche de diálogos: buena idea, implementación no apta

`user32: Skip specific dialogs and message boxes defined by environment variables` ataca una causa
ambiental documentada (regla 10: el modal de Steam Cloud bloqueando el IPC). Pero su código tiene
defectos que **no se copian**:

- `StrStrW(caption_env, window_text)` con `window_text` vacío devuelve no-NULL → **se saltaría
  cualquier diálogo**. `GetWindowTextW` sobre un diálogo sin título, o sobre `hwnd == 0` cuando
  `DIALOG_CreateIndirect` falla, cae justo en ese caso.
- `msgbox->lpszCaption` puede ser `NULL` y se pasa directo a `StrStrW`.
- Búferes fijos de 128/256 con truncado silencioso, y elección del botón "NO" por heurística
  (`first_btn_id + 1`).

Si se porta, se reimplementa con guardas y nombres `REGRESSION_*`, activado por perfil compilado.

### El primer paso real: configuración de DXMT, sin recompilar nada

Verificado sobre el binario instalado (`wine-root/lib/wine/x86_64-windows/`), **la DXMT v0.72 que ya
enviamos soporta**:

| Clave / variable | Efecto |
|---|---|
| `d3d11.preferredMaxFrameRate` | Frame pacing por Metal (`presentDrawableAfterMinimumDuration`) |
| `DXMT_METALFX_SPATIAL_SWAPCHAIN` + `d3d11.metalSpatialUpscaleFactor` | MetalFX Spatial Upscaling |
| `dxgi.customVendorId` · `customDeviceId` · `customDeviceDesc` · `forceSDR` | Identidad de GPU declarada |
| `d3d11.ignoreMapFlagNoWait` | Juegos que no manejan `DXGI_ERROR_WAS_STILL_DRAWING` |
| `dxmt.shaderMetalVersion` | 310 (macOS 14) / 320 (macOS 15) |
| `DXMT_CONFIG` · `DXMT_CONFIG_FILE` · `DXMT_LOG_PATH` · `DXMT_LOG_LEVEL` | Vía de activación y diagnóstico |

El lanzador ya exporta `DXMT_CROSS_PROCESS_PRESENT=1`, así que el patrón de inyectar variables de
DXMT por proceso **ya existe**. Exponerlas por perfil compilado **no toca el runtime sellado, no
recompila Wine, no altera hashes ni PIN, y es reversible quitando la variable**.

**Fase A revisada:** empezar por aquí. `dxgi.custom*` es además el mecanismo general para los juegos
que hacen detección de hardware — la misma clase de problema que GameHub resuelve con hacks por juego
(CS2, GTA, Diablo IV), pero resuelto por configuración en lugar de por lista de ejecutables.

## 10. Reproducibilidad

### Forks creados (copia estable bajo control del usuario)

| Fork | Origen |
|---|---|
| `SwonDev/upstream-dxmt` | `gamesir-labs/dxmt` |
| `SwonDev/upstream-wine` | `gamesir-labs/wine` |
| `SwonDev/upstream-apitrace` | `gamesir-labs/apitrace` |
| `SwonDev/upstream-rosettax87_jit` | `Lifeisawful/rosettax87_jit` (el upstream real, no el espejo) |

No se forkean `dxvk`, `MGL` ni `Metal-Rust`: son espejos sin cambios o irrelevantes; para ellos el
upstream original es la fuente correcta.

### Clones locales y commits fijados

Ruta: `work/gamesir-labs-20260821/` (fuera del control de versiones, ~1 GB).

| Repositorio | Commit | Fecha |
|---|---|---|
| `dxmt` (main) | `98bc4899e0fff63c5956062c62b752581199be7a` | 2026-07-18 |
| `dxmt` (dev-main, **D3D9**) | `dd99192a1c2537c1c964e7e525336985668854f2` | 2026-08-12 |
| `dxmt` (test-dev-12, **D3D12**) | `11b0ffed5751afe91b3b4c473a592ed91f1c0911` | 2026-07-23 |
| `dxmt` (test-dev) | `440a487c2b6c24c75e61c44b7f4722e41fc91c53` | 2026-07-23 |
| `wine` | `316bf39a51ebf599bc755709a441e17539238874` | 2026-04-25 |
| `apitrace` | `92e064a2bd65b56dfded1bdf434c14d9a8cb2c54` | 2026-07-22 |
| `rosettax87_jit` | `a34993d909c563012f7f92482832f6e3130ab1df` | 2026-04-14 |
| `MGL` | `de0ded04ec7dc99182e27e555a17775523b26911` | 2026-01-12 |
| `dxvk` | `011706c611dbc34c31e0acd2eca249bc20542e48` | 2026-04-17 |
| `Metal-Rust` | `cca1d7d75393a23934379b51579b23970177bd4f` | 2026-08-02 |

Base de los parches de Wine: `b0738596750` (`Release 10.0.`, 2025-01-21) → **1706 commits** hasta HEAD.

### Vigilancia continua de los upstreams

`tools/upstream/check-upstream-sources.sh` compara los PIN de `tools/upstream/gamesir-labs.pins`
contra la cabeza actual de cada rama vigilada y **reporta** los commits nuevos, clasificados por área
(`d3d12-metal4`, `d3d9`, `overlay-por-proceso`, `winemac.drv`, `parche-por-juego`,
`winex11-NO-APLICA`, `rosetta-x87`, `nucleo-wine`, `ruido`).

```bash
bash tools/upstream/check-upstream-sources.sh    # 0 sin novedades · 10 hay novedades · 1 error
```

Es de **solo lectura por diseño**: no descarga, no compila, no toca runtime, botella ni bundle, y
**no mueve los PIN**. El PIN es el estado ya revisado por una persona; que upstream avance abre una
revisión, no autoriza una integración. Mover un PIN es el **último** paso de una corrección que ya
pasó su matriz, no el primero.

### Comandos de verificación

```bash
cd work/gamesir-labs-20260821
git -C wine log --oneline b0738596750..HEAD          # los 1706 parches sobre Wine 10.0
git -C wine show 709286074a0 -- loader/wine.man.in   # contrato de WINE_PROCESS_ENV_DIR
git -C dxmt ls-tree -r --name-only origin/dev-main src/d3d9 | wc -l
grep -n "WMTGPUFamilyMetal4" dxmt/src/d3d12/d3d12.cpp # el gate de Metal 4
```
