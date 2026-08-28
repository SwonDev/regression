# Preparar Regression para vivir sin Rosetta

> Investigación del **2026-08-28**. Los datos externos llevan fecha porque caducan solos; lo
> verificado en local se marca como tal y se puede reproducir con los comandos que se citan.

Regression es hoy una app **arm64 nativa** cuyo motor entero es **x86_64 bajo Rosetta 2**. Cuando
Rosetta se retire, el motor deja de arrancar. Este documento fija lo que se sabe, lo que ya
tenemos, lo que falta y por dónde tiraría yo.

---

## 1. El plazo real

| Hito | Cuándo | Qué implica |
|---|---|---|
| macOS 26.4 | ya ocurrido | El sistema **avisa** al abrir una app que necesita Rosetta |
| macOS 27 «Golden Gate» | septiembre 2026 | Rosetta 2 **completo** |
| macOS 28 | otoño 2027 | Rosetta se retira **salvo un subconjunto** para juegos Intel antiguos no mantenidos |

**No hay que contar con ese subconjunto.** Está descrito para juegos *de macOS* con binarios Intel
sin mantenimiento; nada garantiza que cubra a un Wine x86_64 de terceros que se recompila en cada
release. Planificar la continuidad del producto sobre esa excepción sería una apuesta, no un plan.

Margen efectivo: **algo más de un año** desde hoy hasta el corte.

---

## 2. Qué depende de Rosetta, medido

```bash
W=/Applications/Regression.app/Contents/SharedSupport/wine-root
lipo -archs "$W/bin/wine" "$W/bin/wineserver" "$W/lib/wine/x86_64-unix/ntdll.so"
lipo -archs /Applications/Regression.app/Contents/MacOS/Regression
ls "$W/lib/wine"
```

| Pieza | Arquitectura | Verificado |
|---|---|---|
| App Regression (SwiftUI, `RegressionCore`, `regressionctl`) | **arm64 nativo** | 2026-08-28 |
| `bin/wine`, `bin/wineserver`, `lib/wine/x86_64-unix/*.so` | **x86_64** | 2026-08-28 |
| Árbol `wine-root/lib/wine` | sólo `x86_64-unix`, `x86_64-windows`, `i386-windows` | 2026-08-28 |
| DXMT (`d3d11.dll`, unixlib `winemetal.so`) | x86_64 | 2026-08-28 |
| D3DMetal / `libd3dshared.dylib` (Apple GPTK 3.0 y 4.0b2) | **x86_64 únicamente** | 2026-08-28 |

La interfaz sobrevive intacta. **Todo lo demás hay que portarlo.**

---

## 3. Lo que ya existe ahí fuera (y lo que ya tenemos en casa)

### Wine

- **Wine 11.0** (enero 2026) cerró la nueva arquitectura WoW64 y añadió NTSYNC.
- **Wine 10.0** ya traía **ARM64EC** completo; las 11.x lo han ido puliendo — **11.16**, de hace
  días, mejora el manejo de excepciones en ARM64EC.

ARM64EC es el modelo que nos sirve: el proceso es ARM64 nativo, las DLL del sistema son PE ARM64, y
sólo el código x86-64 del juego pasa por un emulador.

### CrossOver Preview ARM64 — ya está en este repo

`Crossover-ARM64/` contiene la **CrossOver Preview** del 30-31 de julio de 2026 **y su tar de
fuentes** (`crossover-sources-20260731.tar`). Inspeccionada en local:

```
lib/wine/aarch64-unix/      ← Wine nativo arm64 (7,3 MB)
lib/wine/aarch64-windows/   ← DLLs PE ARM64 (d3d11, d3d12, dxgi… ya están)
lib/wine/x86_64-windows/    ← PE x86-64, lo que ejecuta el juego
lib/wine/i386-windows/
lib/wine/x86_64-unix/       ← el mundo antiguo, aún presente: build de transición
lib/aarch64/libMoltenVK.dylib   ← arm64 nativo
lib/wine/aarch64-unix/libwow64fex.so     ← 52 KB, un unixlib puente
lib/wine/aarch64-unix/libarm64ecfex.so   ← 52 KB, idéntico en tamaño
```

Los dos `*fex.so` exportan sólo `__wine_unix_call_funcs` y no contienen rastro de FEX: son el
**punto de enganche** del emulador, no el emulador. El tar de fuentes trae `wine`, `dxmt`, `dxvk`,
`moltenvk`, `vkd3d`… pero **no trae FEX**.

### FEX

- Upstream (`FEX-Emu/FEX`) es **Linux**; no declara soporte de macOS.
- CodeWeavers portó una versión propia para su build ARM64 de macOS. **No viene en su tar de
  fuentes**, así que no es una fuente de la que podamos partir.
- **Pero el laboratorio de este repo ya lo ha atacado**: `patches/fex-a04b0241-darwin-core-stage1`,
  `-map-jit-stage2`, `-guest-memory-bias-stage3`, más dos parches de selectores de segmento
  (`fs`/`gs`). `work/fli-proton-arm64-20260808/` documenta una reentrada acreditada en
  `libFEXCore.dylib`. Se abrió por el anticheat de FANTASY LIFE i; resulta ser **también el plan de
  continuidad del producto**.

### DXMT

El tar ARM64 de CrossOver **incluye `sources/dxmt`** (el de 26.3.0 no lo incluía) y ese árbol trae
un cross-file **`build-arm64ec.txt`**:

```ini
[binaries]
c = 'arm64ec-w64-mingw32-gcc'
...
[host_machine]
cpu_family = 'aarch64'
```

Además el proyecto DXMT declara un **unixlib arm64 nativo** para creación de PSO, compilación de
MSL a metallib y caché de shaders en disco, y recomienda arm64 precisamente porque Rosetta se
retira. **La capa gráfica propia tiene camino.**

---

## 4. El riesgo que nadie está mirando: D3DMetal

En la CrossOver Preview **ARM64** de julio de 2026, `D3DMetal.framework` y `libd3dshared.dylib`
**siguen siendo x86_64**. Apple no ha publicado un GPTK arm64.

Y en el modelo ARM64EC el proceso anfitrión es arm64: **no puede cargar un framework nativo
x86_64**. Es decir, salvo que Apple lo porte, la ruta `external-d3dmetal` desaparece con Rosetta, y
con ella los juegos que hoy dependen de ella:

> Grim Dawn · DragonSword · Dragon's Dogma 2 · FINAL FANTASY TACTICS · Titan Quest II ·
> Borderlands 4 · Dragonkin · The Witcher 3 · **PixARK**

**Ese, y no el emulador, es el trabajo de fondo**: cada juego que se pueda mover de D3DMetal a DXMT
es un juego que sobrevive. Y aquí está la conexión con lo que se hizo el 2026-08-28: corregir
`UpdateSubresource` sobre textura staging en DXMT (v1.12.13) fue justo eso. PixARK conserva su
perfil GPTK porque está validado, pero **ya funciona sobre DXMT**: el día que haya que migrar, ese
juego ya no es un problema.

---

## 5. Por dónde tiraría yo

En este orden, y con la regla de siempre: **una variable por paso, y el motor estable no se toca**.

### Fase 0 — Reducir la superficie D3DMetal *(se puede hacer ya, sin ARM de por medio)*

Es lo único que aporta valor inmediato **y** despeja el futuro, y no depende de que nada externo
madure. Por cada juego con perfil GPTK: probarlo sobre DXMT y anotar qué le falta al traductor.
Cada carencia corregida en DXMT vale para todos los juegos, no para uno.

*Hito medible:* una tabla en este documento con los nueve juegos y su veredicto sobre DXMT.

### Fase 1 — Wine arm64 reproducible

Compilar el árbol `wine` del tar del 31-07-2026 para `aarch64`, con la serie de parches propia
reportada. Los ~20 parches de `patches/wine-26.3.0-*` están escritos contra el árbol x86_64 de
26.3.0: **reportarlos es trabajo real**, y algunos (los que tocan `signal_x86_64.c`, selectores de
segmento o el loader) pueden no tener sentido en arm64.

*Hito medible:* `wineboot` completo en una botella desechable, sin juegos, sin Steam.

### Fase 2 — El emulador x86-64

Construir `libwow64fex.so` y `libarm64ecfex.so` **propios**, desde FEX upstream más los parches de
Darwin que ya existen en `patches/fex-*`. Es la pieza de mayor riesgo y la que más depende del
trabajo previo del laboratorio.

*Hito medible:* un `.exe` PE x86-64 de consola que imprime y termina.

*Si esta fase se atasca*, la alternativa es esperar a que CodeWeavers publique su port o a que
upstream acepte Darwin; en ese caso la Fase 0 sigue siendo lo que salva el producto.

### Fase 3 — Capas gráficas

- **DXMT** con `build-arm64ec.txt` y su unixlib arm64. El `native_llvm_path` pasa a ser LLVM
  **arm64** (más fácil que hoy: Homebrew lo tiene nativo).
- **MoltenVK** arm64 — CrossOver ya lo distribuye así; nuestros tres parches de Enshrouded habría
  que reportarlos.
- **DXVK** arm64ec.
- **D3DMetal**: sin salida propia. Depende de Apple.

*Hito medible:* la tienda de Steam renderizando, que es el canario de siempre.

### Fase 4 — El aparato de verificación

Todo el sellado asume x86_64: `toolchain/x86/`, los `-arch x86_64` de los builds, los PIN, los
verificadores, `ComponentHealth` y el `RuntimeModuleCatalog`. Hay que decidir si el runtime arm64
convive con el x86_64 en un mismo bundle —como hace CrossOver ahora— o lo sustituye.

Convivir es lo sensato durante la transición, pero **duplica la matriz de validación**.

---

## 6. Qué haría esta semana si hubiera que empezar

Nada de esto toca el motor estable:

1. **Fase 0 sobre un juego**, el que menos dependa de D3D12 — probablemente Grim Dawn o FFT— y
   anotar el resultado.
2. Leer `work/fli-proton-arm64-20260808/RESUME.md` y decidir si el laboratorio FEX se retoma tal
   cual o se replantea ahora que el objetivo ya no es sólo el anticheat.
3. Compilar el Wine `aarch64` del tar **sin parches propios**, sólo para ver si el árbol oficial
   levanta en este Mac. Es barato y responde a la pregunta más grande.

---

## 7. Fuentes

- [Rosetta 2 discontinuation notice — 9to5Mac, 2026-02-16](https://9to5mac.com/2026/02/16/macos-26-4-will-notify-users-of-rosetta-2-discontinuation/)
- [Rosetta 2 ends with macOS 27 Golden Gate](https://www.squaredtech.co/rosetta-2-ends-with-macos-27-golden-gate-what-it-means-for-your-mac)
- [Rosetta 2 end of support: macOS 28 — TechTimes, 2026-05-30](https://www.techtimes.com/articles/317445/20260530/rosetta-2-end-support-macos-28-will-break-18000-intel-apps-2027.htm)
- [CrossOver Preview: The right to bear ARM64 on Mac — CodeWeavers, 2026-07-31](https://www.codeweavers.com/blog/mjohnson/2026/7/31/crossover-preview-the-right-to-bear-arm64-on-mac)
- [PortJump Update: macOS support for Intel based applications — CodeWeavers, 2026-06-19](https://www.codeweavers.com/blog/orudge/2026/6/19/portjump-update-upcoming-changes-to-macos-support-for-intel-based-applications)
- [Wine 11.16 release notes](https://gitlab.winehq.org/wine/wine/-/releases/wine-11.16)
- [Wine 11.0 released — ADMIN Magazine](https://www.admin-magazine.com/News/Wine-11-Released)
- [FEX-Emu](https://fex-emu.com/) · [FEX-Emu/FEX en GitHub](https://github.com/FEX-Emu/FEX) · [Development:ARM64EC — FEX-Emu Wiki](https://wiki.fex-emu.com/index.php/Development:ARM64EC)
- [Hangover (Wine arm64 + FEX en Linux)](https://github.com/AndreRH/hangover)
