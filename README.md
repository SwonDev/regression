# Regression

Aplicación nativa de barra de menús que abre Steam de Windows en macOS y permite elegir entre
dos motores aislados:

- **CrossOver 26.3**, backend predeterminado temporal, invocado mediante su CLI oficial y la
  botella licenciada existente del usuario.
- **Regression**, motor propio Windows→macOS construido desde fuentes open-source, conservado
  íntegro para perfiles verificados y para sustituir progresivamente a CrossOver.

La aplicación registra localmente cómo se ejecuta cada juego, normaliza las configuraciones y
compara resultados. No copia credenciales ni binarios propietarios y todavía no aplica de forma
automática lo aprendido. Un proceso que sale con código 0 no cuenta como compatible: el éxito
requiere una verificación visual explícita.

**Estrategia de independencia futura**: fijar las versiones exactas y convenciones observables de
CrossOver, trasladándolas al motor propio solo desde fuentes públicas o mediante reimplementación
legal. La paridad se consigue con evidencia reproducible, no con cambios globales a ciegas.

**Qué contiene este repo**: documentación, scripts de build (`build/*.sh`) y los parches
propios (`patches/`). **No** contiene las fuentes de CrossOver, los binarios del GPTK de
Apple, la app compilada ni la botella — ver `NOTICE.md` para saber cómo obtener cada pieza
y por qué no se redistribuyen. Licencia: LGPL-2.1+ (`LICENSE`).

---

## 0. Arquitectura operativa temporal (2026-07-27)

1. `Regression.app` se inicia como `LSUIElement`: aparece en la barra de menús y no en el Dock.
2. Detecta CrossOver, su versión, la botella que contiene Steam, el estado de la botella y el
   backend gráfico predeterminado declarado por su runtime.
3. Abre Steam mediante
   `CrossOver.app/Contents/SharedSupport/CrossOver/bin/wine --bottle <nombre> --cx-app ...`.
   La interfaz general de CrossOver solo se abre para instalación, actualización, reparación o
   licencia.
4. El selector cambia entre CrossOver y Regression cerrando primero el Steam activo; nunca deben
   coexistir dos procesos que escriban en la biblioteca.
5. La carpeta `steamapps` del motor propio enlaza a la biblioteca canónica de CrossOver. Los
   juegos se instalan una sola vez; credenciales, registro y datos externos a `steamapps` siguen
   separados de forma segura.
6. SQLite guarda ejecuciones, configuraciones, huellas de DLL/runtime, variables permitidas,
   resolución/configuración gráfica detectable, deltas y verificaciones. Los perfiles se pueden
   consultar y exportar como JSON, pero no se aplican automáticamente.
7. Una validación visual perfecta se registra sobre la ejecución concreta. La lista muestra
   entonces `Verificado perfecto: Regression` en verde; los intentos fallidos se conservan para
   investigación, pero no degradan el mejor perfil ya confirmado. La app exige una segunda
   confirmación explícita antes de guardar un veredicto perfecto para evitar certificaciones
   accidentales.
8. La base, sus exportaciones, los recibos y los logs técnicos se guardan con permisos exclusivos
   del usuario (`0700` para directorios y `0600` para archivos). El lanzador conserva como máximo
   20 logs propios y no registra credenciales ni argumentos no permitidos.

Rutas principales:

- Base: `~/Library/Application Support/Regression/Compatibility/compatibility.sqlite`
- Backups de la unificación: `~/Library/Application Support/Regression/Backups/SharedLibrary/`
- CLI de mantenimiento: `Regression.app/Contents/SharedSupport/bin/regressionctl`
- Motor propio preservado: `Regression.app/Contents/MacOS/regression-engine`

Consulta local (sin modificar perfiles automáticamente):

```bash
Regression.app/Contents/SharedSupport/bin/regressionctl status
Regression.app/Contents/SharedSupport/bin/regressionctl runs
Regression.app/Contents/SharedSupport/bin/regressionctl profiles
Regression.app/Contents/SharedSupport/bin/regressionctl observations
Regression.app/Contents/SharedSupport/bin/regressionctl export /tmp/regression-compatibilidad.json
```

Cerrar una validación perfecta desde terminal —la app ofrece la misma acción en “Ejecuciones
recientes”—:

```bash
Regression.app/Contents/SharedSupport/bin/regressionctl runs
Regression.app/Contents/SharedSupport/bin/regressionctl verify <RUN_ID> perfect \
  --note "Render, entrada, opciones y gameplay confirmados visualmente"
```

Para una validación histórica anterior a la telemetría se usa `observe APP_ID perfect` con nombre,
backend y nota de evidencia. Nunca se infiere “perfecto” de un cierre normal.

---

## 1. Estado del motor propio blindado

### Funciona (todo verificado con capturas)
- **Steam completo**: tienda, login, biblioteca, navegación, clicks precisos (CEF/Chromium).
- **Moonlighter 2** (Unity IL2CPP) — menú y carga correctos.
- **Palworld COMPLETO**: personaje + mundo + HUD (DXMT v0.72 + `-dx11`).
- **Grim Dawn** (D3D11) — perfil aislado D3DMetal, 3024×1964 Retina, gameplay, clics y
  opciones gráficas confirmados sin parpadeo; **Romestead** (Unity) in-game.
- **D3D9**: DXVK 1.10.3.
- **Packaging**: app autocontenida (~1,8 GB, PE sin strip — el strip rompía el unwind SEH),
  firmada adhoc, icono propio. Backup canónico actual:
  `backups/regression-last-good-20260726.tar.gz`.

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
    ├── MacOS/Regression          # app SwiftUI de barra de menús
    ├── MacOS/regression-engine   # launcher propio original: env + exec wine Steam.exe
    ├── Info.plist                # LSUIElement=true, CFBundleIconFile=Regression
    ├── Resources/Regression.icns # icono (squircle, degradado azul-púrpura + R)
    └── SharedSupport/
        ├── bin/regressionctl     # diagnóstico, perfiles, exportación y conmutación
        └── wine-root/            # runtime propio autocontenido
            ├── bin/                  # wine, wineserver, ...
            ├── lib/wine/
            │   ├── i386-windows/     # DLLs PE 32-bit (wow64)
            │   ├── x86_64-windows/   # DLLs PE 64-bit + DXMT + Apple d3d12 + DXVK d3d9
            │   └── x86_64-unix/      # .so unix (winemac, winemetal, winevulkan, ...)
            ├── lib/runtime/           # gnutls, gstreamer, glib, freetype, SDL2, MoltenVK
            ├── lib/profiles/grim-dawn # enlace aislado al árbol D3DMetal verificado
            └── lib/apple_gptk/        # D3DMetal.framework + libd3dshared.dylib (Apple)
```

**Botellas (fuera de la app, datos de usuario)**:

- CrossOver: `~/Library/Application Support/CrossOver/Bottles/Steam/` (canónica actual).
- Regression: `~/Library/Application Support/Regression/Bottles/Steam/` (motor propio; su
  `steamapps` enlaza a la anterior, pero conserva login/registro/configuración propios).

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
bash build/install-game-profiles.sh    # fija Grim Dawn a D3DMetal, verifica hashes y firma
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
> de PINs, definición de "hecho") y los **principios inviolables** (nunca romper lo que
> funciona, separación estricta de backends, CrossOver como referencia y legalidad limpia)
> están en `AGENTS.md` → secciones "Reglas inviolables" y
> "Protocolo de trabajo". Leerlos antes de tocar nada; estas reglas son el resumen.

1. **Backup antes de tocar una botella o el bundle.** Copia en `backups/`. No modificar la
   botella CrossOver canónica durante experimentos; perfiles en variables de proceso o copias.
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
10. **Icono oficial** (2026-07-26): creado por el usuario (SVG en `assets/icon/oficial/`),
    integrado como `Regression.icns` (squircle con máscara separada + DstIn, sips + iconutil).
11. **Los PIN son una base estable, no un techo de I+D.** Para reparar un juego se permiten,
    en un perfil aislado, Rosetta, versiones alternativas o más recientes de Wine, toolchains y
    dependencias abiertas. CrossOver es siempre la referencia de comportamiento. El candidato
    solo pasa a perfil verificado tras probar render, clicks, cambios gráficos persistentes y
    gameplay; no puede alterar perfiles blindados ni depender de CrossOver en runtime.
12. **Grim Dawn = perfil D3DMetal completo, nunca mezcla gráfica.** `grim dawn.exe` antepone
    exclusivamente `lib/profiles/grim-dawn` (enlace interno a `lib/apple_gptk/wine`), declara
    `CX_ACTIVE_GRAPHICS_BACKEND=d3dmetal` dentro de ese proceso y fuerza a builtin
    `atidxx64`, `d3d9`, `nvapi64` y `nvngx`. No trasladar esos cambios al registro global:
    mezclar D3DMetal con el `d3d9` DXVK de la botella produjo negro y parpadeos.

---

## 7. Decisiones clave (por qué está así)

- **Todo x86_64 bajo Rosetta** (no wow64 arm64): paridad exacta con el producto CX y menos riesgo.
- **DXMT upstream + parche cross-process propio** en vez de su fork (privado, no publicable).
- **winemac parcheado** (consumer IOSurface) — es el ÚNICO parche al árbol de wine.
- **D3DMetal = binarios de Apple del GPTK instalado** (licencia evaluación, uso local).
- **Routing gráfico por ejecutable en ntdll**: cada perfil se antepone únicamente en su proceso;
  Grim Dawn no altera Steam, Cube World, FFT ni el backend global.
- **Botella fuera de la app**: datos de usuario (login, juegos) separados del artefacto firmado.
- **Strip agresivo** del runtime (mingw-strip PE, strip -x .so): 1,5 GB → 596 MB.

---

## 8. Historial técnico y siguientes pasos

### Grim Dawn blindado (2026-07-27)

El procedimiento general está documentado en
[`docs/compatibility-research.md`](docs/compatibility-research.md) y el expediente completo de
pruebas, descartes, hashes, rollback y receta final vive en
[`docs/games/grim-dawn.md`](docs/games/grim-dawn.md).

La referencia estable de CrossOver 26.3 no era su modo automático: la botella fijada a
**D3DMetal** cargaba `d3d11.dll`, `dxgi.dll`, `D3DMetal.framework` y `libd3dshared.dylib`, sin
DXVK para el juego. Regression ya contenía esos recursos locales de Apple byte a byte idénticos,
pero su perfil anterior mezclaba D3DMetal con `d3d9.dll` de DXVK/MoltenVK; esa combinación causaba
parpadeos, negro o ausencia de presentación.

La solución final es exclusiva de `grim dawn.exe`: perfil completo Apple GPTK, flags activos de
D3DMetal y overrides builtin por proceso para neutralizar la ruta DXVK heredada de la botella.
La prueba canónica alcanzó gameplay a 3024×1964, con clic preciso y opciones persistentes; el
usuario confirmó ausencia total de parpadeo y la captura Retina se preservó localmente en
`backups/grimdawn-d3dmetal-perfect-20260727-1802/`. `lsof` confirmó que el proceso cargaba los
recursos de `Regression.app` y ninguna biblioteca ejecutable de CrossOver. Los archivos del juego
pueden residir en la biblioteca física compartida; el motor y el perfil no dependen de CrossOver.

### Hallazgos de diagnóstico (2026-07-26, sesión Cube World + FFT)

> Esta sección conserva rutas que fallaron porque siguen siendo útiles para desarrollar el motor
> propio. No representa el veredicto final de los juegos: después de estas pruebas, el usuario
> confirmó **FFT perfecto** y **Cube World perfecto** en la versión blindada de Regression.

**Arquitectura gráfica de CrossOver 26.3 (mapeada inspeccionando su instalación)**:
- `lib/wine/x86_64-windows/`: PEs pequeños wine estándar (d3d11 425 KB, dxgi 218 KB,
  d3d12 92 KB, wined3d 1,4 MB + libvkd3d-1/libvkd3d-shader-1/libvkd3d-utils-1 dinámicos).
  Su `x86_64-unix/` tiene solo 34 `.so` (sin wined3d/d3d11/dxgi/d3d12 unix — todo PE-side).
- `lib/dxmt/`: su fork DXMT (d3d11 4,7 MB, dxgi 1,7 MB + winemetal.so) — NUNCA en system32.
- `lib64/apple_gptk/`: D3DMetal de Apple (dlls builtin-format + sus .so + libd3dshared).
- D3D12 en CX = d3d12.dll (92 KB) → libvkd3d-1.dll → winevulkan → **SU MoltenVK** (SPIRV-Cross fork).
- Botellas CX: system32 con forwarders pequeños, CERO overrides d3d.

**FFT (D3D12) — ruta vkd3d fallida histórica**: nuestro D3D12 muere dentro de
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

**Cube World (D3D11) — estado conocido**: crea dos swapchains (raíz + hija). Tras el trabajo
posterior, el usuario confirmó que el motor propio blindado renderizó el menú y el gameplay con
encuadre e interacción perfectos; es el mejor perfil almacenado. CrossOver llegó históricamente a
renderizarlo con recorte inferior, pero esa configuración exacta no quedó capturada. En la botella
CrossOver reinstalada actual, tres pruebas visuales (automática, DXVK aislado y D3DMetal aislado)
produjeron pantalla negra y `Could not initialize Direct3D`; constan como fallidas y no modifican
el perfil perfecto de Regression.

**Steam Cloud**: el diálogo modal "No se puede sincronizar" BLOQUEA el IPC de Steam
(`SteamAPI_Init` falla y el juego muere al instante — parecía un bug del motor y era esto).
Desactivado el cloud para 1128000 y 1004640 en
`userdata/121123806/config/localconfig.vdf` (`"cloud" { "enabled" "0" }`). Si vuelve a
pasar con otro juego: mismo arreglo.

### Cola de trabajo

1. Iniciar sesión una vez en el Steam propio y revalidar el perfil blindado de Cube World desde la
   biblioteca compartida; no alterar su motor para acomodar la botella CrossOver actual.
2. Aprender mediante ejecuciones normales de CrossOver qué perfiles usa el resto del catálogo,
   marcando visualmente render, entrada y opciones antes de considerarlos perfectos.
3. Comparar configuraciones verificadas y trasladarlas al motor propio solo mediante fuentes
   públicas/reimplementación, de forma aislada por juego y sin aplicación automática todavía.
4. Mantener el diagnóstico de MoltenVK/D3D12 como investigación del motor propio, sin invalidar el
   funcionamiento ya confirmado de FFT por otra ruta.
5. **Wine Mono 10.4.1** para juegos .NET cuando un título real lo requiera.

---

## 9. Estructura del repo

- `patches/` — **los parches propios** (lo único de código Wine/DXMT versionado): consumer
  IOSurface para winemac.drv, presentación cross-process para DXMT v0.72 y routing gráfico
  aislado por ejecutable para Wine CX 26.3.0.
- `Regression.app/` — LA APP (autocontenida, firmada). **Canónica**: `/Applications/Regression.app`
  es un symlink a ella (el `--prefix` del wine va horneado a esta ruta; no mover sin recompilar).
  *(No versionada: 1,7 GB y contiene binarios del GPTK de Apple no redistribuibles.)*
- `backups/` — backups consolidados y un manifiesto local en `backups/README.md`.
- `build/` — scripts de build + toolchains + logs + tests D3D (`/tmp/d3d*test.exe`).
- `sources-26.3.0/` — fuentes oficiales CX 26.3.0 (wine fork parcheado winemac).
- `toolchain/x86/` — dependencias compiladas (gnutls, gstreamer, etc.).
- `assets/icon/` — fuentes del icono.
- `crossover-sources-26.3.0.tar.gz` — tarball original de la versión fijada.
- `installers/` — SteamSetup.exe oficial.

---

## 10. Estado de almacenamiento (2026-07-27)

- Árbol del proyecto: **~5,4 GiB** medidos con `du`.
- Biblioteca canónica actual: `steamapps` de la botella CrossOver `Steam` (~80 GB en la medición
  de esta migración). Regression apunta a esos mismos archivos mediante enlace simbólico.
- La antigua `steamapps` propia (~4 MB) se movió de forma recuperable a
  `~/Library/Application Support/Regression/Backups/SharedLibrary/`; no se borró ningún juego.
- Se retiraron `stage/`, `bottles/test/`, las fuentes y el tarball residuales de 26.2.0,
  siete bundles de respaldo redundantes/fallidos y artefactos de experimentación.
- Se conservaron la app canónica firmada, las fuentes 26.3.0, el toolchain, el motor y la botella
  propios blindados, los puntos de recuperación y los backups de partidas.
