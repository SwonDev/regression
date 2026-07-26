# Regression

Motor de compatibilidad Windows→macOS propio (equivalente a CrossOver), construido 100 % desde
código fuente open-source, sin una sola línea de binarios propietarios de CodeWeavers ejecutándose.

**Resultado**: una app (`Regression.app`) que con doble click abre Steam de Windows en macOS
(Apple Silicon, vía Rosetta 2), loguea, navega y juega.

**Estrategia de paridad: fijar las versiones EXACTAS de CrossOver** en cada componente
(ver tabla §3) **y sus convenciones de build** (prefix horneado en la app, como hacen ellos).
Ir juego por juego no escala; igualar el stack exacto sí.

**Qué contiene este repo**: documentación, scripts de build (`build/*.sh`) y los parches
propios (`patches/`). **No** contiene las fuentes de CrossOver, los binarios del GPTK de
Apple, la app compilada ni la botella — ver `NOTICE.md` para saber cómo obtener cada pieza
y por qué no se redistribuyen. Licencia: LGPL-2.1+ (`LICENSE`).

---

## 1. Estado actual (2026-07-25, FINAL)

### Funciona (todo verificado con capturas)
- **Steam completo**: tienda, login, biblioteca, navegación, clicks precisos (CEF/Chromium).
- **Moonlighter 2** (Unity IL2CPP) — menú y carga correctos.
- **Palworld COMPLETO**: personaje + mundo + HUD (DXMT v0.72 + `-dx11`).
- **Grim Dawn** (D3D11), **Romestead** (Unity) in-game.
- **D3D9**: DXVK 1.10.3.
- **Packaging**: app autocontenida (~950 MB, PE sin strip — el strip rompía el unwind SEH),
  firmada adhoc, icono propio. Backup: `backups/regression-app-final-20260725.tar.gz`.

### Las dos claves de la paridad (aprendidas a las malas)
1. **DXMT = v0.72** (versión exacta de CX; `main` tiene una regresión que hace invisibles los
   skeletal meshes en Palworld).
2. **Wine compilado con `--prefix` apuntando a la app**. Con el prefix por defecto
   (`/usr/local`, inexistente) la resolución de módulos se degradaba: juegos Unity morían al
   iniciar y el estado dependía del modo (build tree vs instalado). CrossOver hornea su prefix
   en su app — nosotros igual.

### Pendiente honesto
1. **Test sintético D3D12 peta** (page fault en D3D12CreateDevice) en nuestro wine; con el de CX
   va. Nota: D3DMetal funciona en juego real (Palworld corría en D3D12 rindiendo mundo).
2. **DXVK solo d3d9**; vkd3d sin d3d12.dll en el snapshot.
3. **MoltenVK con stubs** (3 features del SPIRV-Cross privado de CX): afecta a la ruta
   Vulkan (DXVK/vkd3d) en algunos juegos.

---

## 2. Arquitectura

```
Regression.app/
└── Contents/
    ├── MacOS/regression          # launcher (bash): env + exec wine Steam.exe
    ├── Info.plist                # CFBundleIconFile=Regression
    ├── Resources/Regression.icns # icono (squircle, degradado azul-púrpura + R)
    └── SharedSupport/wine/       # runtime autocontenido (596 MB)
        ├── bin/                  # wine, wineserver, ...
        ├── lib/wine/
        │   ├── i386-windows/     # DLLs PE 32-bit (wow64)
        │   ├── x86_64-windows/   # DLLs PE 64-bit + DXMT + Apple d3d12 + DXVK d3d9
        │   └── x86_64-unix/      # .so unix (winemac, winemetal, winevulkan, ...)
        ├── lib/runtime/          # gnutls, gstreamer(+plugins), glib, freetype, SDL2, MoltenVK
        └── lib/apple_gptk/       # D3DMetal.framework + libd3dshared.dylib (Apple)
```

**Botella (fuera de la app, datos de usuario)**:
`~/Library/Application Support/Regression/Bottles/Steam/` (~8 GB: Steam + juegos + login).

### Pipeline de presentación CEF (lo más delicado)
Chromium crea los swapchains desde su **GPU process** para ventanas del **browser process**
(cross-process). Ni DXMT upstream ni wine soportan eso. Nuestra solución (basada en
`PapaRascal2020/uncork`):

1. **DXMT producer** (`build/toolchain/dxmt-src`): si el swapchain es cross-process, renderiza a
   una **IOSurface GLOBAL** (`kIOSurfaceIsGlobal`) creada en `winemetal_unix.c` y publica
   `id w h root x y` en `C:\windows\temp\dxmt-cxpresent-<hwnd-hijo>.id`.
2. **winemac consumer** (`sources-26.3.0/wine/dlls/winemac.drv/cocoa_window.m`): timer de 16 ms
   lee TODOS los `.id`, agrupa por ventana raíz y compone **una subcapa CALayer por hijo**
   en modo layer-hosting (`layerContentsRedrawPolicy=Never`) en su posición exacta.
3. Gate: `DXMT_CROSS_PROCESS_PRESENT=1`.

CEF crea un swapchain por hijo (cabecera 92pt, contenido, popups) → sin posiciones por hijo,
clicks desalineados y contenido negro. **No tocar esto sin leer la sección 6.**

---

## 3. Cómo se usa el código de CrossOver (legalmente)

| Componente | Origen | Licencia | Uso |
|---|---|---|---|
| Wine 11 (fork CX 26.3.0) | `media.codeweavers.com/pub/crossover/source/crossover-sources-26.3.0.tar.gz` | LGPL | Compilado tal cual + parche winemac (consumer) |
| gnutls/nettle/gmp, glib, gstreamer, freetype, moltenvk, vkd3d, dxvk | mismo tarball oficial | LGPL/Apache | Compilados x86_64 |
| DXMT | github.com/3Shain/dxmt (main) | zlib | Compilado + parche cross-process propio |
| LLVM 15.0.7 | llvm-project | Apache | Backend airconv de DXMT |
| SPIRV-Headers, libffi, pcre2, SDL2, corefonts | repos oficiales / SourceForge | varias | toolchain/botella |
| D3DMetal.framework, libd3dshared, PE d3d12* | bundle de CrossOver instalado (Apple GPTK) | Apple | Binarios locales, uso personal (NO redistribuible) |
| Fuente CJK (msyh, simsun, SourceHan) | botella Steam de CrossOver del usuario | MS/OFL | Copia local |

**Lo que NO se usa**: GUI de CrossOver, gestor de botellas, sistema de licencias, su fork privado
de DXMT ni de SPIRV-Cross (no públicos). CrossOver compila todo **x86_64 bajo Rosetta** (su CI:
`tools/gitlab/build-mac` → `arch -x86_64 ../configure --enable-win64`). Nosotros igual, pero con
`--enable-archs=i386,x86_64` (wow64 completo, necesario para SteamSetup.exe PE32).

---

## 4. Cómo investigar el código/comportamiento de CrossOver (método)

Sin ingeniería inversa de lo propietario — todo por inspección de datos legítimos:

1. **Crossties** (`~/Library/Application Support/CrossOver/tie/crossover.tie`, XML 23 MB):
   receta por app (dependencias, env vars, claves de registro, template). El perfil de Steam es
   `com.codeweavers.c4.206`. Se parseó para replicar la botella.
2. **Botella real** (`~/Library/Application Support/CrossOver/Bottles/Steam/`):
   `cxbottle.conf` (env vars: `WINEMSYNC=1`, appid creador), `user.reg`/`system.reg`
   (DllOverrides, tweaks Direct3D: `cb_access_map_w=1`), system32 (qué DLLs son de Apple/DXMT).
3. **Su CI en las fuentes** (`sources-26.3.0/wine/tools/gitlab/build-mac`): flags exactas de build.
4. **Binarios** (`file`, `otool -L`, `lipo -info`): arquitectura real del producto (todo x86_64).
5. **CW HACKs en el código**: buscar "CW HACK" en `sources-26.3.0/wine/` (p.ej. 22434 non-native
   code regions para D3DMetal, 22435 `__wine_unix_call_exported`, 24067 `prepend_dll_path`).
6. **Comparativa A/B**: ejecutar el mismo binario/botella con su wine y con el nuestro
   (`CX_ROOT=/Applications/CrossOver.app/Contents/SharedSupport/CrossOver CX_BOTTLE=Steam
   $CX_ROOT/bin/wine ...`) y difereciar env (`WINEDEBUG=+relay`, `+loaddll`, `+module`).
7. **Logs del juego/Steam**: `<prefix>/drive_c/Program Files (x86)/Steam/logs/*.txt`.

---

## 5. Build (reproducible)

Scripts en `build/` (todos con guards por paso; logs en `build/logs/`):

```bash
# 1) Toolchain x86_64 (prereqs: brew mingw-w64 meson ninja cmake automake bison flex nasm cabextract)
bash build/toolchain-a-tls.sh        # gmp → nettle → gnutls → freetype
bash build/toolchain-b-gstreamer.sh  # libffi → pcre2 → glib → gstreamer
# SDL2: ver historial (cmake con CMAKE_OSX_ARCHITECTURES=x86_64)
# 2) LLVM 15 x86_64 (para DXMT/airconv) — ver build/…/dxmt-src/toolchains
# 3) Wine 11 CX wow64
bash build/build-wine.sh             # configure --enable-archs=i386,x86_64, CFLAGS -arch x86_64
# 4) Gráficos
bash build/build-vkd3d-dxvk.sh       # vkd3d libs + DXVK (PE mingw)
bash build/build-dxmt.sh             # DXMT win64 (PE + winemetal.so)
# MoltenVK: sources-26.3.0/moltenvk (git init + remote KhronosGroup; SPIRV-Cross rev upstream;
# stubs en External/SPIRV-Cross/spirv_msl.hpp) → xcodebuild MoltenVKPackaging
# 5) Botella
bash build/create-steam-bottle.sh    # prefijo + receta crosstie + corefonts
# 6) App
make -C build/wine64 install DESTDIR=stage + strip (ver sección 7) → montar SharedSupport
```

Gotchas de build (todos resueltos, no redescubrir):
- `arch -x86_64` NO funciona con binarios arm64-only (cmake/meson/pkg-config). Usar
  `CFLAGS="-arch x86_64"` + `--build/--host=x86_64-apple-darwin`. Los conftest corren bajo Rosetta.
- `PKG_CONFIG_LIBDIR` (no `PKG_CONFIG_PATH`) o brew cuela libs arm64 (libidn2 rompió gnutls).
- nettle del tarball CX no trae `configure` → tarball oficial 3.10. gnutls: `--disable-gost` +
  `NETTLE_LIBS/HOGWEED_LIBS/GMP_LIBS` explícitos (su hooks.m4 no los rellena).
- glib 2.78: subproject gvdb (gitlab.gnome.org rev 0854af0) + parche `distutils` (python 3.14).
- gstreamer: `-Dgst-plugins-base:pango=disabled -Dgst-plugins-good:png=disabled
  -Dgst-plugins-bad:{closedcaption,analyticsoverlay,ttml}=disabled` (cairo/harfbuzz/libpng rotos);
  libpng wrap parcheado (`fp.h` obsoleto → `__has_include`).
- DXVK 1.10.3 + mingw14: `-include cstdint` y guards `__MINGW64_VERSION_MAJOR < 12`.
- mingw y IIDs de d3d12/dxgi: `#define INITGUID` antes de los includes.
- DXMT: LLVM FUERA del source tree (meson prohíbe rutas absolutas al árbol).

---

## 6. Reglas de oro para futuros agentes (NO saltárselas)

> El **protocolo de trabajo completo** (ciclo de cambio, matriz de validación por pieza, tabla
> de PINs, definición de "hecho") está en `AGENTS.md` → sección "Protocolo de trabajo".
> Leerlo antes de tocar nada; estas reglas son el resumen.

1. **Backup antes de tocar la botella o el bundle.** Copia en `backups/`. La botella vive en
   `~/Library/Application Support/Regression/Bottles/Steam/`.
2. **Tras CUALQUIER cambio gráfico**: relanzar la app y verificar que la tienda renderiza
   (screencapture del CGWindowID). Si está negra, revertir inmediatamente.
3. **NO poner overrides `d3d11/d3d10core/dxgi=native`.** Las DLLs de DXMT son módulos wine
   (builtin-format) y wine las RECHAZA como "native" → "not found" → tienda negra. DXMT carga
   desde system32 como builtin sin override. Overrides solo para DLLs PE planas (d3d9=DXVK, ok).
4. **Limpiar `dxmt-cxpresent-*.id` del temp al arrancar** (el launcher ya lo hace): ficheros
   stale + reutilización de hwnd = superficies fantasma → pantalla negra.
5. **No mezclar d3d11/dxgi de Apple (D3DMetal) con DXMT** en el mismo system32: CEF muere.
   D3D12 (d3d12.dll, d3d12core.dll, nvapi64, nvngx, atidxx64) puede coexistir.
6. **Clicks imprecisos** → `RetinaMode=n` en `HKCU\Software\Wine\Mac Driver` (ya aplicado).
7. **Crash Win32Font assert en Steam** → faltan fuentes CJK (copiar las 55 de la botella CX).
8. **DYLD**: `DYLD_FALLBACK_LIBRARY_PATH` debe incluir runtime + x86_64-unix (winemac.so) +
   apple_gptk/external (D3DMetal.framework).
9. **Steam se instala PE32**: hace falta wow64 completo (`--enable-archs=i386,x86_64`).
10. **codex gpt-image sin cuota hasta 2026-07-28 19:03** — icono actual = placeholder magick.

---

## 7. Decisiones clave (por qué está así)

- **Todo x86_64 bajo Rosetta** (no wow64 arm64): paridad exacta con el producto CX y menos riesgo.
- **DXMT upstream + parche cross-process propio** en vez de su fork (privado, no publicable).
- **winemac parcheado** (consumer IOSurface) — es el ÚNICO parche al árbol de wine.
- **D3DMetal = binarios de Apple del GPTK instalado** (licencia evaluación, uso local).
- **Botella fuera de la app**: datos de usuario (login, juegos) separados del artefacto firmado.
- **Strip agresivo** del runtime (mingw-strip PE, strip -x .so): 1,5 GB → 596 MB.

---

## 8. Siguientes pasos (orden sugerido)

### Hallazgos de diagnóstico (2026-07-26, sesión Cube World + FFT)

**Arquitectura gráfica de CrossOver 26.3 (mapeada inspeccionando su instalación)**:
- `lib/wine/x86_64-windows/`: PEs pequeños wine estándar (d3d11 425 KB, dxgi 218 KB,
  d3d12 92 KB, wined3d 1,4 MB + libvkd3d-1/libvkd3d-shader-1/libvkd3d-utils-1 dinámicos).
  Su `x86_64-unix/` tiene solo 34 `.so` (sin wined3d/d3d11/dxgi/d3d12 unix — todo PE-side).
- `lib/dxmt/`: su fork DXMT (d3d11 4,7 MB, dxgi 1,7 MB + winemetal.so) — NUNCA en system32.
- `lib64/apple_gptk/`: D3DMetal de Apple (dlls builtin-format + sus .so + libd3dshared).
- D3D12 en CX = d3d12.dll (92 KB) → libvkd3d-1.dll → winevulkan → **SU MoltenVK** (SPIRV-Cross fork).
- Botellas CX: system32 con forwarders pequeños, CERO overrides d3d.

**FFT (D3D12) — causa raíz ENCONTRADA**: nuestro D3D12 muere dentro de
`vkCreateComputePipelines` (vkd3d → winevulkan → nuestro MoltenVK). El assert real:
`!status && "vkCreateComputePipelines"` en `winevulkan/loader_thunks.c:3119`, con un
c0000005 (salto a dirección basura) dentro de la llamada unixlib. Sospechoso principal:
nuestro build de MoltenVK 1.2.10 con los 3 stubs de SPIRV-Cross (`spirv_msl.hpp`:
`texture_offset_buffer_index`, `add_texture_buffer_offsets`, `bitwise_not_causes_ice`).
Reproducible con `build/d3d12test.exe` (fuente en `build/d3d12test.c`).
Además: la dxgi de DXMT en system32 rompe D3D12 (FFT la cargaba nativa y su check de GPU
fallaba: "Graphics card is not supported"). Con `WINEDLLOVERRIDES=dxgi=b` (nuestra dxgi
builtin de wine —reconstruida desde `build/wine64`, ver nota abajo) el juego enumera el adaptador
("NVIDIA GeForce 8800 GTX", spoof de wined3d GL) y muere en el mismo crash de vkd3d.
OJO: la dxgi builtin de wine y la de DXMT NO pueden coexistir como builtin — wine valida el
par PE/expectativa y solo carga la de DXMT de system32 si wine-root también tiene la de DXMT.
Por eso wine-root lleva la dxgi de DXMT (estado blindado) y D3D12 queda bloqueado por MoltenVK.

**Cube World (D3D11) — causa acotada**: el juego crea DOS swapchains (raíz 1512x838 +
hija 1512x728 @ 0,92). Con el present normal de DXMT: pantalla negra (fullscreen y ventana).
Forzando la ruta IOSurface (`cross_process=true`): el consumer de winemac compone las
superficies (la pantalla pasa de negra a BLANCA) pero sin contenido del juego. En CrossOver
con DXMT **también falla** ("Could not initialize Direct3D") — la afirmación del usuario de
que funciona en CX probablemente implica DXVK activado en CX (no verificado aún).
Candidato en fuente (NO instalado): condición child-hwnd en `dxmt-src` (ruta IOSurface para
swapchains hijas, gated por `DXMT_CROSS_PROCESS_PRESENT`). La dll de system32 es la original
(blindada); la fuente tiene el candidato sin probar.

**Steam Cloud**: el diálogo modal "No se puede sincronizar" BLOQUEA el IPC de Steam
(`SteamAPI_Init` falla y el juego muere al instante — parecía un bug del motor y era esto).
Desactivado el cloud para 1128000 y 1004640 en
`userdata/121123806/config/localconfig.vdf` (`"cloud" { "enabled" "0" }`). Si vuelve a
pasar con otro juego: mismo arreglo.

### Cola de trabajo

1. **MoltenVK**: reproducir el crash de compute con un shader mínimo y localizar si es uno
   de los 3 stubs (recompilar activándolos de uno en uno) o divergencia mayor con el fork
   de CX. Alternativa: backtrace nativo con lldb dentro de vkCreateComputePipelines.
2. **Cube World**: probar en CX con DXVK activado (si ahí funciona → evaluar DXVK per-juego
   en Regression: DXVK d3d11+dxgi nativas en el DIR del juego + `WINEDLLOVERRIDES`
   documentado — OJO: DXVK d3d11 usa compute shaders, choca con el mismo crash de MoltenVK).
3. **d3d12.so attach Apple** (CW HACK 22434 en `ntdll/unix/loader.c`): la ruta D3DMetal de
   Apple como alternativa a vkd3d para D3D12 (sus dlls son builtin-format: hay que cargarlas
   desde su propio árbol `lib/apple_gptk/wine`, no como "native").
4. **Más juegos**: probar el catálogo del usuario según lo pida (siempre con Steam activo y sin
   wineservers ajenos — ver protocolo en `AGENTS.md`).
5. **Rendimiento**: comparativa FPS Grim Dawn vs CrossOver (mismo save/zona).
6. **Wine Mono 10.4.1** para juegos .NET.
6. **Icono definitivo**: regenerar con codex gpt-image (3 variantes) tras 2026-07-28.
7. **GUI mínima opcional**: solo si el usuario la pide (él quiere cero UI: doble click → Steam).

---

## 9. Estructura del repo

- `patches/` — **los parches propios** (lo único de código versionado): consumer IOSurface
  para winemac.drv (CX wine 26.3.0) y presentación cross-process para DXMT v0.72.
- `Regression.app/` — LA APP (autocontenida, firmada). **Canónica**: `/Applications/Regression.app`
  es un symlink a ella (el `--prefix` del wine va horneado a esta ruta; no mover sin recompilar).
  *(No versionada: 1,7 GB y contiene binarios del GPTK de Apple no redistribuibles.)*
- `backups/` — copias de seguridad (tar.gz de la app).
- `build/` — scripts de build + toolchains + logs + tests D3D (`/tmp/d3d*test.exe`).
- `sources-26.2.0/`, `sources-26.3.0/` — fuentes oficiales CX (wine fork parcheado winemac).
- `toolchain/x86/` — dependencias compiladas (gnutls, gstreamer, etc.).
- `assets/icon/` — fuentes del icono.
- `crossover-sources-*.tar.gz` — tarballs originales.
- `installers/` — SteamSetup.exe oficial.
