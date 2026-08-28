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

Regla de siempre: **una variable por paso y el motor estable no se toca**. Cada fase tiene un hito
que se puede enseñar.

### Fase 0 — Reducir la dependencia de D3DMetal *(empezar ya; no depende de ARM)*

Por cada juego con perfil GPTK: lanzarlo sobre DXMT y anotar qué le falta al traductor. Cada
carencia corregida en DXMT vale para todos los juegos.

*Hito:* tabla con los nueve juegos y su veredicto sobre DXMT, en este documento.
*Por qué primero:* es lo único que aporta valor hoy **y** despeja el futuro, y no depende de Apple,
de CodeWeavers ni de FEX.

### Fase 1 — Wine arm64 reproducible

```bash
CLEAN=/private/tmp/regression-wine-arm64
rm -rf "$CLEAN" && mkdir -p "$CLEAN"
tar -xf Crossover-ARM64/crossover-sources-20260731.tar -C "$CLEAN" sources/wine
# configure con las tres arquitecturas del modelo ARM64EC
./configure --enable-archs=arm64ec,aarch64,i386 …
```

Primero **sin parches propios**, para saber si el árbol oficial levanta en este Mac. Después,
reportar la serie: los ~20 `patches/wine-26.3.0-*` están escritos contra el árbol x86_64 de 26.3.0 y
**algunos no tienen sentido en arm64** —los que tocan `signal_x86_64.c`, los selectores de segmento
o el loader—. Hay que clasificarlos uno a uno: *aplica igual · hay que reescribir · ya no aplica*.

*Hito:* `wineboot` completo en una botella desechable. Sin Steam, sin juegos.

### Fase 2 — El emulador x86-64

**Camino A primero**, porque es barato y desbloquea todo lo demás: un unixlib puente sobre
`thread_set_x86_64_compat`, con la misma interfaz que espera Wine
(`__wine_unix_call_funcs`) y JIT con `pthread_jit_write_protect_np`. Es el diseño que CrossOver ya
demuestra que funciona; hay que escribirlo, no copiarlo.

**Camino B en paralelo y sin prisa**, retomando `work/fli-proton-arm64-20260808/`: si Apple retira
la API, el puente muere y FEX es lo único que queda.

*Hito:* un `.exe` PE x86-64 de consola que imprime y termina.

### Fase 3 — Capas gráficas

- **DXMT** con `build-arm64ec.txt`, adoptando el reparto de CrossOver (PE fino + LLVM en el unixlib
  arm64). El `native_llvm_path` pasa a LLVM **arm64**, que Homebrew ya sirve nativo — más fácil que
  hoy, donde hay que descargar el LLVM x86_64 oficial.
- **MoltenVK** arm64, reportando los tres parches de Enshrouded.
- **DXVK**: no existe en ARM64EC ni en CrossOver. Afecta sólo a D3D9; recordar que los procesos de
  32 bits ya van al `d3d9` builtin de Wine, así que el impacto real es menor de lo que parece.
- **D3DMetal**: sin salida propia. De ahí la Fase 0.

*Hito:* la tienda de Steam renderizando, que es el canario de siempre.

### Fase 4 — El aparato de sellado

Todo asume x86_64: `toolchain/x86/`, los `-arch x86_64` de los builds, los PIN, `verify-*.sh`,
`ComponentHealth` y `RuntimeModuleCatalog`. Decidir si el runtime arm64 **convive** con el x86_64 en
un bundle —como hace CrossOver ahora, y es lo sensato en la transición— o lo sustituye. Convivir
**duplica la matriz de validación**, y eso hay que presupuestarlo.

*Hito:* matriz verde en las dos arquitecturas, con el verificador distinguiéndolas.

---

## 8. Qué haría la primera semana

Nada de esto toca el motor estable:

1. **Fase 0 sobre un juego**: el que menos dependa de D3D12 —Grim Dawn o FFT— sobre DXMT, y anotar
   el resultado en la tabla.
2. **Compilar el Wine `aarch64` del tar sin parches propios**. Es barato y responde a la pregunta
   más grande: si el árbol oficial levanta aquí.
3. **Leer `work/fli-proton-arm64-20260808/RESUME.md`** y decidir si el laboratorio FEX se retoma tal
   cual o se replantea, ahora que el objetivo ya no es sólo el anticheat.

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
- [Rosetta 2 en un Mac con Apple silicon — Apple](https://support.apple.com/guide/security/rosetta-2-on-a-mac-with-apple-silicon-secebb113be1/web)
