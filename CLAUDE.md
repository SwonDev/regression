# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

> **Regression** es una app nativa de barra de menús (`LSUIElement`) que ejecuta Steam de Windows
> en macOS con **su propio motor** de compatibilidad. Regression es el **único backend operativo**:
> su runtime, su botella y la única biblioteca física de juegos son propios. CrossOver **no se
> invoca, no comparte estado y solo aparece en expedientes históricos fechados**; tampoco existe
> red, CLI ni backend de CodeWeavers en el producto. La telemetría local conserva evidencia, pero
> **no aplica perfiles automáticamente**.
>
> **`AGENTS.md` es la fuente de verdad** (reglas inviolables + protocolo, compartida con Codex).
> Si algo de este archivo difiere de `AGENTS.md`, **manda `AGENTS.md`**. `README.md` es la portada
> del producto y `docs/README.md` el índice técnico.

> **Contrato del checkout:** Regression **1.12.6 (44)**, release estable publicada, y SQLite **v17**.
> **v1.11.0 (37)** es el baseline histórico: conservar sus gates `public-1.11` de transición no
> autoriza a saltarse la matriz global de futuras releases.

---

## 0. Antes de tocar nada

```bash
git status --short && git log -1 --oneline    # ¿en qué rama y commit estoy?
git fetch origin && git log --oneline -1 origin/master
ls build Scripts patches                       # los tres deben existir
```

El trabajo publicado vive en **`origin/master`**. Antes de investigar o cambiar algo, comprueba
que el checkout coincide con él: una rama antigua contiene reglas, PIN, versiones y verificadores
caducados, y llevaría a "arreglar" sobre un estado que ya no existe. `build/` contiene todos los
verificadores del estado protegido; si falta, el checkout está incompleto.

**Si `build/` no existe, casi siempre lo ha borrado el limpiador de disco Mole**, que la trata
como carpeta de artefactos: lo es en su mayor parte (los `dxmt64`, `vkd3d64` y
`windows-media-component` que `.gitignore` excluye), pero ahí viven también los 36 scripts
versionados. Se recupera entero con `git restore build/`; comprobado en el log de la app
(`~/Library/Logs/mole/operations.log`), que lo registra el 2026-07-27, el 2026-08-12 y el
2026-08-22. No es un borrado del proyecto ni de ningún script de `build/`: los `rm -rf` de la
serie están todos acotados a subrutas (`$ROOT/build/dxmt64`, `$STAGING_APP`).

Al empezar una sesión que continúa trabajo previo: `mem_session_start` + `mem_search` (Engram)
antes de actuar, y `mem_save` proactivamente ante cada decisión, bug resuelto o hallazgo.

---

## Agent skills

### Issue tracker

Las tareas publicables se gestionan como issues de GitHub. Consulta `docs/agents/issue-tracker.md`.

### Triage labels

Se usa el vocabulario canónico de cinco estados. Consulta `docs/agents/triage-labels.md`.

### Domain docs

El repositorio usa un único contexto de dominio y ADR globales. Consulta `docs/agents/domain.md`.

---

## 1. Arquitectura (la parte que hay que entender leyendo varios archivos)

Regression son **tres capas acopladas**; casi todo el trabajo real ocurre en la frontera entre ellas.

### 1.1 App nativa (SwiftPM, Swift 6.2, macOS 14+)

`Package.swift` define cuatro targets y **ningún proyecto Xcode**:

| Target | Rol |
|---|---|
| `RegressionCore` (librería) | Todo el dominio: repositorio SQLite, preflight, telemetría, perfiles, catálogos, recetas |
| `Regression` (ejecutable) | UI SwiftUI de barra de menús (`MenuBarView`, `RegressionAppModel`) |
| `RegressionControl` (ejecutable `regressionctl`) | CLI con la **misma** lógica de `RegressionCore`; es la vía de trabajo del agente |
| `CSQLite` (systemLibrary) | Shim de SQLite del sistema; no hay dependencias externas |

Piezas de `RegressionCore` que conviene conocer antes de cambiar comportamiento:

- `CompatibilityRepository(.swift|+Preflight|+Research|+RuntimeEvolution|+LaunchEnvelope)` — todo
  el acceso a SQLite, dividido por área. Es el archivo más grande del proyecto.
- `GameTestPreflight` — diagnóstico **de solo lectura** previo a cualquier lanzamiento.
- `LaunchEnvelope` / `CompatibilityRepository+LaunchEnvelope` — el sobre durable v17 que autoriza
  un `spawn`: vincula run, App ID, preflight fresco y las identidades cerradas de componentes y
  perfiles. **Nunca contiene comandos, rutas ni DLLs.**
- `TelemetryCoordinator`, `SteamLogMonitor`, `GameSessionArtifactCleaner` — observación de la
  sesión de Steam, agrupación launcher + ejecutable en un solo run y limpieza acotada al run exacto.
- `GameRuntimeProfileCatalog` — catálogo **compilado** de perfiles por ejecutable; gobierna
  `identifier`, `revision` y `executable`, y sobrescribe metadatos contradictorios.
- `VerifiedGameCatalog` — certificaciones perfectas embebidas en el binario; sobreviven a una
  regeneración de SQLite.
- `CompiledGameRepairs`, `WindowsMediaRepairInterlock`, `UnrealBootstrapRouteDetector`,
  `AppleGPTKOnboarding` — reparaciones **compiladas, cerradas y versionadas**. La base de
  aprendizaje jamás ejecuta un comando almacenado.
- `RegressionReleaseUpdate` — canal único de autoactualización estable.

### 1.2 Runtime (Wine + capas gráficas), fuera de Swift

Vive en el bundle: `Regression.app/Contents/SharedSupport/wine-root`, con el `--prefix` **horneado**
a la ruta absoluta de instalación. El lanzador es `Scripts/regression-engine.sh` →
`Contents/MacOS/regression-engine`.

El aislamiento por juego **no se hace con variables globales ni con el registro**: se hace con
parches propios de Wine en `patches/`, activados por *basename* exacto del ejecutable —
`per-process-graphics-routing`, `process-scoped-dll-isolation`, `macos-linux-uname-sigsys`
(Borderlands 4), `winemac-gl-surface-resync` (Fields of Mistria), `unreal-bootstrap-autodetect`,
`unity-borderless-focus`, `windows-media-autodetect`, `device-notification-invalid-handle`.
Ese es el patrón a replicar al blindar un juego nuevo.

Capas gráficas: **DXMT v0.72 + parche cross-process** (D3D11), **DXVK 1.10.3** (D3D9),
**Apple GPTK/D3DMetal** por perfil aislado (D3D12), `winemac.drv` y perfiles OpenGL.

### 1.3 Datos locales (SQLite v17)

`~/Library/Application Support/Regression/Compatibility/compatibility.sqlite` (`0700`/`0600`).
Cadena que importa: `games` → `runs` → `run_processes` → `run_preflight_reports` →
`run_verifications` → `verified_game_certifications`, con `configuration_snapshots` y
`engine_snapshots` aportando las huellas. La identidad de motor **excluye** `gameconfig.*`: cambiar
resolución no crea un stack falso, cambiar Wine/DLL/registro sí.

**Un `perfect` exige custodia completa de procesos**: `runs.process_id` = la única fila
`run_processes.is_representative=1`, run terminado, verificación posterior al cierre. Mutar después
esa cadena invalida el veredicto sin borrar el historial. Un `exit code 0` **nunca** certifica nada.

---

## 2. Comandos

### Desarrollo Swift

```bash
swift build                       # compilación de depuración
swift build -c release            # binarios de release
swift test                        # suite XCTest completa (RegressionCoreTests)
swift test --filter TelemetryCoordinatorTests                       # una clase
swift test --filter TelemetryCoordinatorTests/testNombreDelCaso     # un solo test
```

### Contratos de shell (no los ejecuta `swift test`)

`Tests/Shell/*.sh` son ejecutables independientes que verifican release, instalador, entitlements,
autoridad del runtime sellado y coherencia de versión. No hay runner: se invocan uno a uno.

```bash
bash Tests/Shell/release-version-coherence.sh     # versión coherente en todos los archivos
bash Tests/Shell/documentation-contract-1.12.sh
bash Tests/Shell/no-codeweavers-runtime.sh        # el producto no toca CrossOver
for t in Tests/Shell/*.sh; do bash "$t" || echo "FALLA: $t"; done
```

### Estado protegido y verificadores

```bash
bash build/verify-protected-state.sh --include-bottle   # todos los PIN, sin lanzar juegos
bash build/verify-canonical-installation.sh             # una única app descubrible
bash build/install-game-profiles.sh                     # fija perfiles por juego y firma
bash build/verify-release-asset.sh ASSET CHECKSUM VERSION BUILD
bash build/verify-public-installed-state.sh --release-1.12.3
```

### Build del runtime (solo si cambia el runtime)

```bash
bash build/apply-wine-patches.sh   # serie de parches propios sobre sources-26.3.0
bash build/build-wine.sh           # wine CX 26.3.0 → Regression.app
bash build/build-dxmt.sh           # DXMT v0.72 + parches
bash build/build-public-wine-runtime.sh   # recompila el arranque para /Applications
Scripts/sign_regression.sh Regression.app # SIEMPRE tras tocar el bundle
```

Toolchain x86 ya compilado en `toolchain/x86/` — no recompilar salvo cambio de versiones.

### CLI `regressionctl` (la herramienta de trabajo para validar juegos)

```bash
regressionctl status
regressionctl preflight APP_ID --backend regression   # obligatorio antes de lanzar
regressionctl launch APP_ID --backend regression
regressionctl runs | processes RUN_ID | profiles | engines | certifications
regressionctl verify RUN_ID perfect|playable|failed [--note TEXTO]
regressionctl observe APP_ID perfect|playable|failed --backend regression --name NOMBRE
regressionctl research-protocol | research-open | research-hypothesis | research-stage \
              research-attach-run | research-gate | research-artifact | research-finish
regressionctl cloud-status APP_ID                      # ¿la caché de Steam Cloud cuadra con el disco?
regressionctl library-status | validate-library APP_ID --run RUN_ID
regressionctl database | export RUTA
```

### Validación visual (no opcional)

```bash
open /Applications/Regression.app
swift tools/diagnostics/list-windows.swift steam
screencapture -x -l <CGWindowID> /tmp/check.png   # capturar y MIRAR la imagen
```

---

## 3. Reglas inviolables (resumen; el detalle está en `AGENTS.md`)

### Principios

1. **JAMÁS se integra algo que rompe lo que ya funciona.** Lo decide la matriz de validación (§4),
   no las intenciones. Si algo que antes funcionaba falla → revertir primero, preguntar después.
2. **El baseline propio y las fuentes FOSS mandan.** Baseline y candidato se ejecutan **dentro de
   Regression**; no se instala, abre, consulta ni inspecciona CrossOver para diagnosticar.
3. **Autonomía operativa estricta.** Ni botella, ni juegos, ni credenciales, ni registro, ni
   configuración compartidos. Nada de DLLs, dylibs ni binarios propietarios copiados.
4. **Legalidad limpia.** Solo fuentes open-source oficiales. Los binarios de Apple (GPTK:
   `D3DMetal.framework`, `libd3dshared.dylib`) se usan tal cual, solo en local, jamás redistribuidos.
5. **I+D sin techo, promoción aislada y con evidencia.** Los PIN protegen el motor estable, no
   limitan la investigación en un perfil aislado con rollback.

### Reglas técnicas duras (errores ya cometidos, no se repiten)

1. **Backup antes de tocar botella o bundle** (`backups/`). Sin excepciones.
2. **Validación visual obligatoria tras cualquier cambio gráfico**: relanzar, capturar la ventana
   de Steam, confirmar que la tienda renderiza. Negra → revertir al instante.
3. **NO overrides `d3d11/d3d10core/dxgi=native`**: las DLLs de DXMT son módulos wine (builtin) y el
   override las hace "not found". Overrides solo para PE planas (`d3d9` de DXVK sí).
4. **La dxgi de DXMT es intocable EN PAREJA**: system32 **y** wine-root. Romper la pareja mata
   todos los juegos D3D11 al instante (exit 53). D3D12 necesita la dxgi de wine → conflicto
   documentado en README §8.
5. **No mezclar `d3d11`/`dxgi` de Apple con DXMT** en system32 (CEF muere). `d3d12*` sí coexiste;
   las DLLs de Apple solo se cargan desde `lib/apple_gptk/wine`.
6. **Cada perfil de juego se activa por proceso, nunca globalmente** (Grim Dawn, DragonSword,
   Titan Quest II, Borderlands 4, Dragonwilds, HWR2…). Convertirlo en registro o entorno global es
   la causa reproducida de negros, parpadeos y congelaciones.
7. **Cerrar siempre la validación en la UI**: verificar el run como `perfect`, refrescar Regression,
   capturar la fila verde. Los fallos históricos se conservan.
8. **Limpiar `dxmt-cxpresent-*.id` antes de lanzar** (ya en el launcher): stale → pantalla negra.
9. **No experimentar sobre el estado bueno.** Copia de la botella o DLLs respaldadas.
10. **Antes de diagnosticar, descartar el entorno** (la mitad de los "bugs" históricos):
    wineservers de otros builds, `services.exe` huérfanos (iconos Steam fantasma), diálogo modal
    de Steam Cloud bloqueando el IPC, juego que exige Steam activo por DRM.
11. **Tras tocar el bundle: `Scripts/sign_regression.sh Regression.app`.** Firma estable, no ad hoc.
12. **PE sin strip** (rompe unwind SEH y la firma de módulos builtin).
13. **No cambiar el modelo de IA ni el stack decidido** sin permiso explícito del usuario.
14. Responder siempre en **español con tildes**; código y comentarios en el idioma del código existente.
15. **No atribuir un Steam Wine solo por el texto de `ps`**: excluir `steamwebhelper.exe` y resolver
    el backend por `lsof` del cliente real.
16. **La terminación nativa no espera a la red**: cancelar tareas, serializar SQLite, responder a AppKit.
17. **No anidar layouts perezosos en el popover** (`LazyVStack` + `DisclosureGroup` provocó un ciclo
    de AttributeGraph al 99,7 % de CPU).
18. **Toda prueba empieza por el preflight canónico**, que **solo observa**: no mata procesos, no
    borra archivos, no modifica botellas, no certifica.
19. **Solo `/Applications/Regression.app` puede ser descubrible.** `Regression.app/` del checkout es
    staging de desarrollo, desregistrado; los rollbacks viven en `.noindex`.
20. **Un `perfect` requiere custodia completa de procesos** (§1.3).
21. **No ocultar degradaciones de telemetría**: rotación, truncado o formato inesperado se propagan
    como incidencias tipadas.
22. **Windows Media solo se repara para un App ID exacto**, con inventario fresco, Steam en reposo,
    lease, WAL, backup, rollback y recibo.
23. **El runtime público es un conjunto sellado**: hashes y permisos compilados de wrapper,
    wineserver, loader, `ntdll.so`, `wine.inf`, ambas `ntdll.dll` PE y VC++/UCRT; `PATH` fijado a
    `/usr/bin:/bin:/usr/sbin:/sbin` y `WINESERVERSOCKET` heredado eliminado.
24. **El sobre de lanzamiento v17 precede al `spawn`** y no guarda comandos ni rutas. Auto-retry y
    rollback automáticos permanecen **bloqueados** hasta tener receta compilada, verificador y recibo.
25. **Un contexto OpenGL core 3.2+ sin bit forward-compatible se concede, no se rechaza.** macOS
    solo expone ese contexto en forma forward-compatible, así que rechazarlo era un fallo cierto.
    Corrección **general** en `winemac.drv`; `CX_FWD_COMPAT_GL_CTX` por ejecutable queda como
    compatibilidad histórica y no se usa para blindar juegos nuevos. `REGRESSION_GL_CORE_FORWARD_COMPAT=0`
    restaura el rechazo para A/B.
26. **HashLink se detecta por contenido** (`hlboot.dat` + `libhl.dll` en la raíz del juego), nunca
    por ejecutable ni App ID. Solo esos procesos resuelven stubs para las siete funciones GL de
    compute/SSBO que macOS no ofrece sobre GL 4.1; los stubs no hacen el trabajo y registran un
    `ERR` si alguna vez se invocan. Ver `docs/games/cursemark.md`.
27. **El runtime se compila desde el tar FOSS oficial + `apply-wine-patches.sh`**, nunca desde
    `sources-26.3.0/wine` tal como esté. Los `.so` se sustituyen uno a uno con firma **ad hoc**;
    `bin/wine`, `bin/wineserver` y el loader **no** admiten binarios crudos. Después,
    `build/refresh-release-pins.sh`. Ver `docs/runtime-rebuild.md`.
28. **La versión del bundle se sube al publicar, nunca antes**, y `supportedApplicationVersion` y
    `supportedBuildIdentifier` van siempre juntos: subir una sin release deja la app bloqueada por
    downgrade y en `unsupportedVariant`.
29. **La colisión de overlays es del EOS SDK, no de Unreal.** Dragonwilds, Cloudheim y TMNT
    (este último **FNA**) revientan con el mismo puntero corrupto `0x5320747375725420`, que es
    texto ASCII, no una dirección. Lo único común es `EOSSDK-Win64-Shipping.dll`. Se corrige
    deshabilitando `EOSOVH-Win64-Shipping` **solo dentro de ese proceso**, jamás en global.
30. **Una activación compilada exige respaldo y manifiesto de rollback.** El intento recorre
    `detected → planned → appliedAwaitingRelaunch`; el repositorio no lo promueve sin huellas
    antes/después ni manifiesto de dos entradas. Reincidir con la receta ya activa cierra el
    intento como `failed` en vez de reescribir la botella en bucle.
31. **El permiso de custodia se toma una vez por lanzamiento** y vive todo el ámbito. Volver a
    pedirlo dentro del arranque de Steam se bloqueaba a sí mismo con la intención ya registrada.
32. **La ventana de observabilidad del lanzamiento cubre un arranque en frío de Steam.** Con dos
    segundos, la intención se quedaba en disco y la biblioteca bloqueada hasta matar Steam.
33. **«Arranca y se cierra solo» sin ventana ni crash → mira Steam Cloud antes que el motor.** Si
    `remotecache.vdf` declara archivos sincronizados que no existen en la carpeta de guardado,
    Steam no los rebaja y el juego abandona. Se copian desde `userdata/<id>/<appid>/remote/` con
    `cp -p`. Ver `docs/games/core-keeper.md`.
34. **Ante «me lo has roto», A/B de una variable antes que argumentar.** Los backups de
    `install-runtime-canonical.sh` traen runtime, PIN, `ComponentHealth` y verificadores: revertir
    entero y reproducir es un experimento limpio. Razonar por qué algo «no puede» ser la causa no
    es evidencia.

---

## 4. Cómo se trabaja aquí (protocolo)

- **Una variable por cambio.** Dos cambios a la vez ya han costado días en este proyecto.
- **Ciclo obligatorio**: preflight → reproducir → descartar entorno → backup → UNA variable →
  validar matriz → solo entonces integrar (y nuevo backup si el estado es mejor).

**Matriz de validación** (siempre con captura visual mirada):

| Si tocaste… | Valida |
|---|---|
| Wine (build, dlls de wine-root) | Steam tienda + Moonlighter 2 (Unity) + Palworld |
| Perfil aislado por ejecutable | Juego objetivo completo + tienda + un perfil blindado no afectado |
| DXMT (d3d11/dxgi/d3d10core) | Tienda (CEF) + Palworld (personajes visibles) |
| DXVK / d3d9 | Un juego D3D9 + tienda |
| `winemac.drv` / parche cross-process | Tienda + clicks precisos + Palworld |
| Launcher (env, rutas) | Arranque desde cero: tienda + un juego |
| Registro de la botella | Tienda + clicks + un juego |
| Fuentes de la botella | Steam arranca (sin ellas crashea con assert Win32Font) |

**"Compila" o "el proceso corre" NO es validación.**

**PINs** (no tocar sin la matriz completa): DXMT v0.72 + parche cross-process · Wine CX 26.3.0 con
`--prefix` horneado · dxgi de DXMT en pareja · perfiles D3DMetal por proceso · `RetinaMode=n` ·
55 fuentes TTF en la botella · PE sin strip.

**Definición de hecho**: (1) el problema no se reproduce, (2) la matriz de su fila pasa entera con
capturas, (3) hay backup del estado nuevo si es mejor, (4) `README`/`AGENTS`/`CLAUDE` y el
expediente reflejan el cambio.

---

## 5. Flujo: blindar un juego que el usuario reporta como roto

1. **Expediente primero**: `regressionctl research-open` y `docs/games/<juego>.md` con síntoma,
   hipótesis falsables y referencia. Registrar antes del primer cambio (`research-hypothesis`).
2. **Preflight** (`regressionctl preflight APP_ID --backend regression`) y descarte ambiental.
3. **Reproducir** el fallo y capturarlo; guardar el run fallido — el historial no se borra.
4. **Una variable por experimento**, aislada (`research-stage`), con rollback y `research-gate`.
5. **Implementar la corrección acotada**: parche de Wine por basename exacto, entrada en
   `GameRuntimeProfileCatalog`, o receta en `CompiledGameRepairs`. Nunca variable global,
   nunca registro global, nunca comando aprendido desde SQLite.
6. **Tests**: `swift test` + los `Tests/Shell` afectados; añadir el caso de no regresión.
7. **Matriz de validación** de la fila correspondiente, con capturas.
8. **Certificar**: `regressionctl verify RUN_ID perfect`, refrescar la app y capturar la fila verde
   `Verificado perfecto: Regression`. Si comparte limitación con la referencia histórica y no hay
   modo de pantalla adecuado → `playableWithIssues`, **no** se maquilla como perfecto.
9. **Publicar el conocimiento**: expediente en `docs/games/`, regla nueva en `AGENTS.md` (+ espejo
   aquí), PIN si procede, fila en `docs/README.md` y en la tabla de compatibilidad del `README.md`,
   y alta en `VerifiedGameCatalog` al blindarlo en una versión publicada.
10. `mem_save` con la causa raíz, la receta y el run exacto.

---

## 6. Flujo: publicar una versión nueva

La versión vive en **cinco sitios** que deben coincidir; `Tests/Shell/release-version-coherence.sh`
es la puerta que lo verifica:

`Scripts/install_regression.sh` · `Scripts/package_regression.sh` · `Scripts/package_release.sh` ·
`Sources/RegressionCore/ComponentHealth.swift` (`supportedApplicationVersion`) · `Info.plist` del bundle.

```bash
bash build/release.sh              # prepara, sella los PIN y verifica el asset
bash build/release.sh --publish    # además crea la release en GitHub
```

`build/release.sh` es la vía normal y hace el flujo entero: reconstruye los insumos que no se
versionan (staging desde la app canónica, componentes sellados, builder público), **deriva** los
tres juegos de PIN de los artefactos reales y los escribe en su sitio, pasa la suite y los
contratos, empaqueta y verifica el asset exacto. No relaja nada: todos los verificadores siguen
ejecutándose y comparando contra un PIN; lo que cambia es que el PIN se calcula en vez de teclearse.

**Por qué hacía falta.** Los mismos cuatro binarios de arranque se fijan en tres formas distintas
—crudo del builder, instalado y firmado en el bundle, y saneado con `strip` para el asset— repartidas
en siete archivos. Reconciliar eso a mano costaba horas y fallaba en silencio: refrescar un juego
desincronizaba otro y el error aparecía tres pasos más tarde sin decir dónde estaba.

Los pasos sueltos siguen existiendo para depurar un fallo concreto:

```bash
bash Scripts/package_regression.sh          # staging firmado
bash Scripts/package_release.sh             # asset público portable
bash build/verify-release-asset.sh ASSET CHECKSUM VERSION BUILD
bash build/verify-public-installed-state.sh --release-X.Y.Z
bash build/verify-canonical-installation.sh
```

**No se publica ni se instala una versión que no supere `verify-release-asset.sh` sobre el asset
exacto que recibirá GitHub.** Actualizar también la nota de contrato en `README.md`, `docs/README.md`,
`AGENTS.md` y este archivo.

---

## 7. Estado actual (2026-08-22)

- **Release estable**: v1.12.6 (44), instalada en `/Applications/Regression.app`. Baseline
  histórico: v1.11.0 (37).
- **27 certificaciones activas**, todas fijadas en el catálogo compilado (revisión `2026-08-19.2`).
  Con expediente público: Grim Dawn, Clair Obscur, DragonSword, Hell Clock, Heroes of Hammerwatch II,
  Secrets of Grindea, Fields of Mistria, Titan Quest II, Forsaken Isle, Dragonwilds, Tinkerlands,
  Moonlighter 2, Cross Blitz, Luminary Demo, Borderlands 4, Cursemark; más Cube World y FFT en el
  catálogo integrado. **Verificados por el usuario sin expediente propio** —funcionaron sobre el
  baseline general desde el primer lanzamiento, sin perfil ni receta, así que no hay investigación
  que contar—: Sephiria, Dwarven Realms, Monsuta, Luma Island, Crashlands 2, Tainted Grail,
  IRON NEST, Granblue Fantasy: Relink y Temtem: Swarm.
- **Reparados y pendientes de certificar**: **Cloudheim** (2070270). El overlay de Epic
  (`EOSOVH`) y el de Steam encadenaban hooks sobre el `d3d11` de DXMT y saltaban a un puntero
  corrupto. Se aísla `EOSOVH-Win64-Shipping` **solo** dentro de `CloudheimSteam-Win64-Shipping.exe`
  (perfil compilado + ruta en el lanzador). Confirmado por el usuario; falta la matriz funcional
  con el run cerrado. Ver `docs/games/cloudheim.md`.
- **Bloqueado por anticheat**: **Dune: Awakening** (1172710) lleva **BattlEye**. Misma categoría
  que FANTASY LIFE i: no se elude ni se presenta como compatible.
- **Incompatible por Vulkan**: **Enshrouded** (1203620) es Vulkan puro y exige la característica
  1.2 `drawIndirectCount`. Su propio log lo dice —«skipping device because 'drawIndirectCount' is
  not supported»— y MoltenVK la declara falsa porque sus `vkCmdDrawIndirectCount` son **stubs
  vacíos**. Activar el flag haría que arrancara sin pintar nada. Upstream lleva el issue abierto
  desde 2018. No se enruta a D3DMetal porque el juego no llama a Direct3D.
  Ver `docs/games/enshrouded.md`.
- **Reparado por la corrección general de D3D12 y publicado en 1.12.6**: **Redfall** (1294810)
  llega a su pantalla de título con la escena completa —validado desde la release instalada, con
  D3DMetal cargado— y **Wayfinder** (1171690) inicializa D3D12 (`Feature Level 12_1`). A Wayfinder
  le queda que no llega a crear ventana; se investiga aparte.
- **Diagnosticado, corrección pendiente**: **Critadel** (808010) renderiza perfecto pero su
  ventana a pantalla completa es *frontmost* sin ser *key*, así que el teclado no llega hasta que
  se hace clic. Probablemente comparte causa con «el clic derecho deja de funcionar en Steam» y
  con «Enter pasa el juego a ventana». Ver `docs/games/critadel.md`.
- **Reparados y pendientes de certificar**: **Dragonkin: The Banished** (1863430). Es UE5 con
  **D3D12** y no tenía ruta a D3DMetal, así que caía al `d3d12` de Wine sobre vkd3d/MoltenVK y
  perdía toda la geometría estática (edificios, props, decoración) mientras terreno, personajes y
  HUD sí pintaban. Se le asigna **Apple GPTK 4.0b2** por proceso exacto. Confirmado por el
  usuario. Ver `docs/games/dragonkin-the-banished.md`.
- **Reparados y pendientes de certificar**: **TMNT: Shredder's Revenge** (1361510). Es **FNA**,
  no Unreal, y aun así reprodujo el crash de Cloudheim con el **mismo** puntero corrupto
  `0x5320747375725420` —que es texto ASCII, no una dirección—: lo único que comparten es el EOS
  SDK. Se aísla `EOSOVH-Win64-Shipping` **solo** dentro de `TMNT.exe`. Arranque confirmado por el
  usuario (pantalla de título, versión 1.0.0.349). Ver `docs/games/tmnt-shredders-revenge.md`.
- **Resuelto sin tocar el motor**: **Core Keeper** (1621690). Se cerraba solo a los ~15 s, sin
  ventana y sin crash, porque el `remotecache.vdf` de Steam declaraba los ocho archivos de nube
  como sincronizados en local mientras la carpeta de guardado del juego estaba vacía: Steam no los
  volvía a bajar y el juego abandonaba el arranque. Las partidas seguían íntegras en
  `userdata/.../remote/`; bastó copiarlas a la carpeta local conservando fechas. Descartado el
  runtime nuevo con un **A/B de una sola variable** (con el `ntdll.so` anterior fallaba igual).
  Confirmado por el usuario. Ver `docs/games/core-keeper.md`.
- **Validados con incidencia**: Dragon's Dogma 2 (letterbox 16:9), Rotwood (superficie 1512×870).
- **Investigación abierta y separada**: FANTASY LIFE i, bloqueado por la política oficial de EAC en
  entornos virtualizados (`208 Cannot run under Virtual Machine`). No se elude, no se oculta la VM,
  no se presenta como compatible. La línea de trabajo es Proton sobre ARM en Mac (FEXCore nativo
  arm64) para los títulos con anticheat; vive en `tools/research/` y `work/` como **rama de
  investigación aparte**, no forma parte del producto y solo se integraría si diera resultados.
- **D3D12 se enruta por evidencia, no por lista**: `D3D12MetalRouteDetector` acepta **dos**
  formas, ambas del propio juego: el Agility SDK en la estructura canónica de Unreal, o que el
  ejecutable declare `d3d12.dll` como **delay-load** en su PE. La segunda es la que de verdad usa
  Unreal —enlazarlo estáticamente impediría arrancar sin D3D12— y es la que resolvió el
  «DX12 is not supported in your system» que se repetía juego tras juego. Las rutas compiladas
  mandan (DragonSword sigue en GPTK 3.0) y un Unity que solo empaqueta el SDK en la raíz no se
  toca. `regressionctl d3d12-metal-routes`. Ver `docs/games/d3d12-delay-load-routing.md`.
- **La autorreparación ya está desbloqueada y blindada.** El loader v2 acredita el App ID contra
  el `appmanifest` de Steam antes de aplicar nada, y la activación solo se promueve a aplicada si
  trae respaldo real y manifiesto de rollback de dos entradas. `reconcile` y `restore` funcionan.
  Sigue siendo un aprendizaje **acotado**: `CompiledCrashRepairLearner` solo lee `.log` bajo
  `drive_c/users` que mencionen el ejecutable, así que un juego que solo deja traza en el log del
  lanzador —TMNT— se blinda a mano.
- **Matriz de regresión permanente**: Steam/CEF, Palworld, Moonlighter 2 (control Unity) y la ruta D3D9.
  ⚠️ Palworld y Moonlighter 2 **ya no están instalados**; en su lugar se validó con Fields of
  Mistria (Unity) y Dragonkin (UE5/D3D12 por GPTK), que cubren las mismas clases de motor.
- ⚠️ **El lanzador instalado está por delante del contrato publicado.** `Contents/MacOS/regression-engine`
  incluye las rutas de Cloudheim y TMNT y el detector D3D12 por evidencia, y su hash ya no coincide
  con los PIN de 1.12.4. El `ntdll.so` instalado es el **loader v2** (acredita el App ID), con
  `ComponentHealth` y los verificadores del asset refrescados en consecuencia. Es deliberado: se
  resuelve al publicar la próxima versión, **nunca** reescribiendo los PIN de una release ya
  publicada. `build/verify-protected-state.sh` apunta al bundle de *staging* del checkout, así que
  no sirve para auditar `/Applications`; `verify-public-installed-state.sh` todavía no tiene modo
  `--release-1.12.5` y hay que añadirlo al publicar. Backups en
  `backups/launcher-pre-cloudheim-20260821-195727/`, `backups/runtime-install-20260822-062125/` y
  `backups/launcher-pre-tmnt-20260822-065735/`.
- La botella vive en `~/Library/Application Support/Regression/Bottles/Steam/` (datos del usuario,
  fuera del repo).
