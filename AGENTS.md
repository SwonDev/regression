# AGENTS.md — Reglas del proyecto Regression

Lee `README.md` primero (arquitectura, build, estado, método de investigación de CrossOver).
Este archivo es la fuente de verdad de reglas y protocolo (Codex lo lee nativamente).
`CLAUDE.md` es su espejo adaptado para Claude Code — si difieren, manda este.

## Lo que es este proyecto

`Regression.app` es el punto de entrada nativo para ejecutar Steam de Windows en macOS. Desde
2026-07-27 tiene dos backends aislados: **CrossOver es el motor predeterminado temporal** y el
motor Windows→macOS propio sigue íntegro y seleccionable para desarrollo y perfiles verificados.
La app vive en la barra de menús, no en el Dock; la ventana general de CrossOver solo se muestra
para instalar, actualizar, reparar o validar la licencia.

La botella `Steam` de CrossOver es canónica para los archivos de juegos. El `steamapps` del motor
propio es un enlace a esa misma carpeta, pero cada botella conserva por separado credenciales,
registro, saves fuera de Steam Cloud y configuración de Steam. Nunca se ejecutan ambos Steam a la
vez. La base local de aprendizaje **observa y compara**, pero no aplica perfiles automáticamente.

## Reglas inviolables

### Principios (valen más que cualquier arreglo concreto)

1. **JAMÁS se integra algo que rompe lo que ya funciona.** Un arreglo que apaga otra cosa
   no es un arreglo: se revierte al instante y se repiensa. No se negocia ni "de momento".
   Lo que decide es la matriz de validación (ver Protocolo), no las intenciones. Si al
   validar algo que antes funcionaba falla → revertir primero, preguntar después.
2. **La referencia es CrossOver: se copia literalmente cómo lo hace CrossOver.** Si en
   CrossOver funciona y en Regression no, la respuesta está en su stack: versiones exactas
   de cada componente, convenciones de build (prefix horneado en la app), wiring de DLLs
   (qué va en system32, qué va en lib, qué es builtin y qué es native), configuración de
   botella y crossties. Se estudia y se replica ESO antes de inventar nada. La paridad se
   consigue igualando, no improvisando. Ir juego por juego sin este método está prohibido.
3. **Separación estricta de backends.** El backend CrossOver depende deliberadamente de la
   instalación y licencia del usuario y se invoca solo mediante su CLI oficial. El motor propio
   debe seguir siendo independiente: no se copian DLLs, dylibs ni binarios propietarios desde
   CrossOver. Las observaciones de CrossOver se trasladan al motor propio únicamente mediante
   fuentes públicas o reimplementación legal, nunca copiando `cxcompatdb` ni forks privados.
4. **Legalidad limpia.** Solo fuentes open-source oficiales (Wine/DXMT/DXVK/MoltenVK LGPL,
   Apache, zlib…). Nada de descompilar ni extraer código de binarios propietarios (GUI de
   CrossOver, sistema de licencias, forks privados de DXMT/SPIRV-Cross). Los binarios de
   Apple (GPTK: D3DMetal.framework, libd3dshared.dylib) se usan tal cual los distribuye
   Apple, solo en local, jamás redistribuidos (por eso no están en el repo ni en GitHub).
   Esto es un proyecto personal/educativo: se documenta como tal.
5. **I+D sin techo, promoción aislada y con evidencia.** Los PIN protegen el motor estable;
   no son un límite para investigar un juego que aún falle. En un perfil experimental aislado
   se puede usar Rosetta, otra versión —también más reciente— de Wine, otro toolchain o cualquier
   dependencia abierta necesaria. CrossOver sigue siendo la referencia primaria para elegir y
   medir cada cambio. El candidato solo se blinda cuando funcionan render, entrada, opciones
   persistentes y gameplay, y nunca puede modificar otro perfil verificado ni introducir una
   dependencia de CrossOver en el motor propio. Un cambio global exige además su matriz completa.

### Reglas técnicas duras (errores que YA se han cometido y NO se repiten)

1. **Backup antes de tocar botella o bundle** (`backups/`). Sin excepciones. Antes y después de
   empaquetar, ejecutar `build/verify-protected-state.sh`; añadir `--include-bottle` cuando la
   botella canónica esté disponible.
2. **Validación visual obligatoria tras cualquier cambio gráfico**: relanzar app, capturar
   ventana de Steam (screencapture por CGWindowID), confirmar que la tienda renderiza. Si está
   negra → revertir al instante.
3. **NO overrides `d3d11/d3d10core/dxgi=native`** en el registro de la botella: las DLLs de DXMT
   son módulos wine y el override las hace "not found" (tienda negra). DXMT va en system32 sin
   override. Overrides solo para PE planas (d3d9 de DXVK sí).
4. **La dxgi de DXMT es intocable EN PAREJA**: va en system32 Y en wine-root. Wine valida la
   pareja; si wine-root lleva otra dxgi (p.ej. la de wine), la de DXMT deja de cargar y TODOS
   los juegos D3D11 mueren al instante (exit 53). D3D12 necesita la dxgi de wine — el
   conflicto y las vías de solución están documentados en README §8.
5. **No mezclar d3d11/dxgi de Apple con DXMT** en system32 (CEF muere). d3d12* de Apple sí coexiste.
   OJO: las dlls de Apple del GPTK son formato builtin (como las de DXMT): como "native" dan
   "not found"; se cargan solo desde su propio árbol (`lib/apple_gptk/wine`).
6. **Grim Dawn está fijado a D3DMetal por proceso.** `grim dawn.exe` usa el perfil interno
   `lib/profiles/grim-dawn` → `../apple_gptk/wine`, activa D3DMetal solo en ese proceso y fuerza
   `atidxx64/d3d9/nvapi64/nvngx=builtin`. No convertirlo en registro o entorno global: la mezcla
   D3DMetal + d3d9 DXVK fue la causa reproducida de negro y parpadeo.
7. **Limpiar `dxmt-cxpresent-*.id` antes de lanzar** (ya en el launcher): ficheros stale →
   pantalla negra por hwnd reutilizado.
8. **No "probar cosas" en vivo sobre el estado bueno.** Cada experimento en copia de la botella
   o con dlls respaldadas; solo se aplica tras validar.
9. **Antes de diagnosticar, descartar el entorno** (la mitad de los "bugs" históricos):
   wineservers de otros builds corriendo (muerte silenciosa), `services.exe` huérfanos
   (iconos Steam fantasma en la barra de menús), diálogo modal de Steam Cloud bloqueando el
   IPC (los juegos mueren al instante sin log: desactivar cloud del appid en
   `localconfig.vdf`), juego que necesita Steam activo por DRM.
10. **Tras `make install` o tocar el bundle: `codesign --force --deep --sign - Regression.app`**.
11. **PE sin strip** (el strip rompe unwind SEH y la firma de módulos builtin).
12. **No cambiar el modelo de IA ni el stack decidido** sin permiso explícito del usuario.
13. Responde siempre en **español**, con tildes. Código y comentarios del repo en el idioma del
    código existente.
14. **Todo juego confirmado perfecto debe quedar visible como blindado.** Inmediatamente después
    de la confirmación visual, verificar la ejecución exacta en la base local con veredicto
    `perfect` (render, entrada, opciones y gameplay en `passed`) y refrescar la app hasta comprobar la fila
    verde `Verificado perfecto: Regression`. Los fallos anteriores se conservan como historial;
    el perfil perfecto tiene prioridad. Si la validación es histórica y anterior a la telemetría,
    registrar una observación importada con App ID, nombre, backend, nota y evidencia/rollback.
    Un exit code 0 jamás crea este estado por sí solo. La confirmación modal del veredicto
    perfecto es una salvaguarda deliberada y no se elimina. Tampoco puede certificarse un run que
    siga en `preparing` o no tenga PID: cualquier marca heredada así se anula, no se promociona.
15. **Una referencia pública nunca es una certificación local.** CodeWeavers aporta contexto
    externo mediante páginas públicas y metadatos normalizados. No se copia su base propietaria,
    no se aplica configuración y un 5/5 jamás crea `Verificado perfecto`. Mantener fuente, caché,
    cadencia y vínculo separados por App ID; ver `docs/compatibility-platform.md`.
16. **No atribuir un Steam Wine solo por el texto de `ps`.** Tras desacoplarse, macOS suele
    mostrar únicamente `C:\...\Steam.exe`, sin ruta del runtime ni padre útil. El inspector debe
    excluir `steamwebhelper.exe` y resolver el backend mediante los ficheros abiertos del cliente
    real (`lsof`). Un wineserver vivo por sí solo no demuestra que Steam esté activo.
17. **La terminación nativa no espera indefinidamente a la red.** Cancelar monitorización y
    catálogo, serializar reconciliación/cierre SQLite y responder entonces a AppKit. Esperar el
    `.value` de una tarea URLSession cancelada dejó una instancia `LSUIElement` imposible de
    relanzar; el cierre limpio instalado debe probarse después de tocar este flujo.

## Protocolo de trabajo (OBLIGATORIO — cómo se hacen las cosas aquí)

Este proyecto es un sistema de muchas piezas acopladas (wine + DXMT + DXVK + D3DMetal + CEF +
botella + launcher). La historia demuestra que **casi todas las roturas vinieron de cambiar
varias cosas a la vez o de tocar el estado bueno para "probar"**. Sigue este protocolo siempre.

### 1. Antes de cambiar nada

1. **Reproduce el problema** y escribe en qué consiste exactamente (juego, momento, síntoma,
   captura). Si no puedes reproducirlo, no estás arreglando nada: estás adivinando.
2. **Descarta causas ambientales primero** (son la mitad de los "bugs" históricos):
   - ¿Hay wineservers de OTROS builds corriendo? (`ps aux | grep wineserver`) → mátalos. Un
     wineserver de otro build causa muertes silenciosas que parecen bugs del motor.
   - ¿Hay `services.exe` huérfanos (PPID 1, sin wineserver)? Son restos de sesiones wine
     muertas: dejan **iconos de Steam fantasmas en la barra de menús de macOS** y pueden
     interferir. Se limpian con `kill <pid>` — son seguros de matar.
   - ¿La botella tiene ficheros `dxmt-cxpresent-*.id` stale? (el launcher ya los limpia, pero
     si lanzas wine a mano, límpialos tú).
   - ¿El juego necesita Steam activo (DRM)? Los juegos Unity/IL2CPP mueren al iniciar si Steam
     no está corriendo — no es un bug del motor.
3. **Haz backup** de lo que vas a tocar (botella → copia o tar en `backups/`; dlls → cópialas
   con sufijo `.bak` junto al original). Sin backup no se toca nada.
4. **Consulta la tabla de PINs** (abajo). Si tu arreglo implica tocar un PIN, necesitas validar
   la matriz COMPLETA después, no solo tu juego.

### 2. Cómo se cambia algo

- **UNA variable por cambio.** Una dll, un override, un parámetro. Si cambias dos cosas y algo
  se rompe (o se arregla), no sabes cuál fue — y en este proyecto eso ya ha costado días.
- **Nunca experimentes sobre el estado bueno.** Experimentos en copia de la botella o con dlls
  respaldadas. Solo se aplica al estado bueno tras validar.
- **Método de referencia: A/B contra CrossOver** (README §3-4). Antes de inventar una solución,
  mira qué hace CrossOver 26.3.0 (fuentes en `sources-26.3.0/`, botella real, crossties) y
  replica eso. La paridad se consigue igualando el stack exacto, no improvisando por juego.

### 3. Después de cambiar algo: matriz de validación

Según lo que tocaste, valida TODO lo de su fila antes de dar el cambio por bueno:

| Si tocaste… | Debes validar (con captura visual) |
|---|---|
| Wine (build, dlls en wine-root) | Steam tienda renderiza + Moonlighter 2 (Unity) + Palworld |
| Perfil aislado por ejecutable | Juego objetivo completo + Steam tienda + un perfil ya blindado no afectado |
| DXMT (d3d11/dxgi/d3d10core) | Steam tienda (CEF) + Palworld (personajes visibles) |
| DXVK / d3d9 | Un juego D3D9 + Steam tienda |
| winemac.drv / parche cross-process | Steam tienda + clicks precisos + Palworld |
| Launcher (env, rutas) | Arranque desde cero: Steam tienda + un juego |
| Registro de la botella (overrides, RetinaMode) | Steam tienda + clicks + un juego |
| Fuentes de la botella | Steam arranca (sin ellas crashea con assert Win32Font) |

Validar = lanzar, capturar con `screencapture -x -l <CGWindowID>` y **mirar la imagen**.
"Compila" o "el proceso corre" NO es validación. Si algo de la matriz falla → **revertir al
instante** (para eso está el backup) y repensar, no apilar otro cambio encima.

Cuando el usuario confirme el resultado perfecto, cerrar el ciclo en la propia UI: registrar el
veredicto sobre el run, refrescar Regression y capturar la fila verde. Esa captura forma parte de
la evidencia del perfil junto a la del juego.

### 4. Tabla de PINs (versiones/config FIJADAS — no tocar sin validar la matriz completa)

Estos PIN fijan el **backend estable predeterminado**, no los entornos aislados de I+D por juego.
Una alternativa puede convivir autocontenida en un perfil individual después de superar sus
pruebas; sustituir un PIN global requiere validar toda la matriz correspondiente.

| Pieza | Valor fijado | Razón | Test que lo protege |
|---|---|---|---|
| DXMT | **v0.72 + parche cross-process propio** | `main` hace invisibles los skeletal meshes | Palworld (personaje visible) |
| Wine | **CX 26.3.0 (`sources-26.3.0/wine`), `--prefix` horneado a la app** | Con prefix `/usr/local` mueren Unity y CEF | Moonlighter 2 + Steam tienda |
| d3d11/dxgi/d3d10core | DXMT en system32 + wine-root, **SIN override `native`** | El override las marca "not found" | Steam tienda |
| d3d11/dxgi de Apple | **NO** en system32 (solo d3d12*) | CEF muere | Steam tienda |
| d3d9 | DXVK 1.10.3, override `native` sí (PE plana) | Funciona | Juego D3D9 |
| Grim Dawn | D3DMetal completo por proceso; `d3d9/atidxx64/nvapi64/nvngx=builtin` | Evita mezcla DXVK y parpadeo | Gameplay + opciones + captura 3024×1964 |
| RetinaMode | `n` (HKCU\Software\Wine\Mac Driver) | Alinea clicks | Click en tienda |
| Fuentes | 55 TTFs (corefonts + CJK) en la botella | Sin ellas Steam crashea (assert Win32Font) | Steam arranca |
| DLLs PE | **SIN strip** | El strip rompe unwind SEH y firma de módulos | Juegos Unity |

### 5. Instalación y rutas (no improvisar)

- La **app canónica vive en el proyecto** (`Regression.app/`) porque el `--prefix` del wine va
  horneado a esa ruta absoluta. `/Applications/Regression.app` es un **symlink** a ella.
- **No copies la app a otro sitio ni la muevas** sin recompilar wine con el nuevo `--prefix`.
- Tras cualquier `make install` o cambio en el bundle: `codesign --force --deep --sign - Regression.app`.
- Tras recompilar/instalar: relanzar y validar la tienda con captura (regla 2).

### 6. Definición de "hecho"

Un cambio está hecho cuando: (1) el problema original ya no se reproduce, (2) la matriz de
validación de su fila pasa entera con capturas, (3) hay backup del estado nuevo si es mejor,
(4) README/AGENTS reflejan el cambio. Si solo cumples el punto 1, has arreglado una cosa y
quizá roto otra — que es exactamente lo que este protocolo existe para evitar.

## Estado rápido (2026-07-28)

- **Arquitectura operativa actual**: app nativa `LSUIElement` en barra de menús, CrossOver 26.3
  como backend predeterminado, motor propio seleccionable, conmutación con cierre limpio y una
  sola biblioteca física de juegos. El lanzador propio original está intacto en
  `Regression.app/Contents/MacOS/regression-engine`.
- **Aprendizaje local**: SQLite v6 normalizada en
  `~/Library/Application Support/Regression/Compatibility/compatibility.sqlite`; registra
  sistema, comandos saneados, componentes, backend gráfico, configuración de juego y deltas.
  La identidad de motor excluye `gameconfig.*`, de modo que una resolución distinta no crea un
  stack falso, mientras que cambiar Wine/DLL/registro sí. Las migraciones son transaccionales,
  crean backup privado y no dejan evidencias sin motor asociado. Cada blindado local referencia
  su evidencia, configuración y motor exactos; corregir el último veredicto perfecto lo desactiva
  sin borrar el historial.
  Un exit code 0 queda **sin verificar**: solo una validación visual explícita crea un perfil
  perfecto o con incidencias. Nada se aplica automáticamente al motor propio. Base, exportaciones,
  recibos y logs son privados del usuario (`0700`/`0600`); se retienen como máximo 20 logs del
  lanzador.
- **Referencia pública**: CodeWeavers Compatibility Database se consulta opcionalmente con sesión
  efímera, coincidencia exacta, caché, ETag y cadencia persistente. Solo se almacenan metadatos
  públicos normalizados y su comparación nunca modifica el veredicto local.
- OK total con el wine de prefijo propio: **Steam completo, Moonlighter 2 (Unity IL2CPP),
  Palworld (personaje), Grim Dawn, Romestead**, DXVK D3D9. Estado blindado intacto.
- **PIN: Grim Dawn = D3DMetal completo y aislado por ejecutable.** El perfil anterior mezclaba
  DXVK/MoltenVK y parpadeaba; el actual renderiza gameplay Retina 3024×1964, conserva clics y
  opciones y fue confirmado perfecto por el usuario. Evidencia y rollback local:
  `backups/grimdawn-d3dmetal-perfect-20260727-1802/`. Método y expediente reproducible:
  `docs/compatibility-research.md` y `docs/games/grim-dawn.md`.
- **PIN: DXMT = v0.72 + parche cross-process** (versión exacta de CrossOver). `main` rompe los
  skeletal meshes de Palworld — NO actualizar sin probar Palworld.
- **PIN: wine compilado con `--prefix` apuntando a la app** (Regression.app/Contents/SharedSupport/wine-root).
  Con el prefix por defecto (/usr/local) los juegos Unity morían al iniciar y CEF tenía crashes.
- **PIN: wine-root y system32 llevan la dxgi de DXMT** (pareja). Cambiar la builtin de
  wine-root por la de wine rompe la carga de la dxgi de DXMT en system32 (los juegos D3D11
  mueren al instante). D3D12 necesita la dxgi de wine → conflicto documentado en README §8.
- **Cube World**: el usuario confirmó render, encuadre, interacción y gameplay perfectos en el
  motor propio blindado; ese dato figura como mejor perfil conocido. En la botella CrossOver
  reinstalada, las pruebas actuales base/DXVK/D3DMetal muestran pantalla negra y
  "Could not initialize Direct3D"; no confundirlas con el éxito histórico de Regression.
- **FFT**: funcionamiento perfecto confirmado por el usuario en el motor propio tras aceptar el
  permiso de macOS. Conservar el registro respaldado; el diagnóstico antiguo de MoltenVK queda
  como historia de la ruta que fallaba, no como estado final del juego.
- **Steam Cloud desactivado** para 1128000/1004640 (el diálogo modal de sincronización
  bloquea el IPC de Steam y mata los lanzamientos — falso bug del motor).
- Backups consolidados: `backups/regression-last-good-20260726.tar.gz` (bundle exacto desde
  el que se restauró el estado bueno, extracción y firma verificadas),
  `backups/regression-blindado-20260725.tar.gz` (baseline blindado) y
  `backups/botella-config-20260725.tar.gz` (registros + 55 fuentes + DLLs DXMT/DXVK).
  El registro confirmado de FFT sigue en
  `backups/regression-steam-user-fft-perfect-20260726.reg`; los saves preventivos viven en
  `backups/user-data/`.
- Revisión de almacenamiento 2026-07-27: quedan solo las fuentes fijadas 26.3.0. El árbol ocupa
  ~6,0 GiB, incluidos ~1,8 GiB de app local y ~1,5 GiB de backups/evidencia. El expediente final
  de Grim Dawn explica el crecimiento posterior a la limpieza; no hay otra Regression instalada.
- **Instalación**: `/Applications/Regression.app` → symlink a la app del proyecto (canónica).
  Lanzar con `open -a Regression` desde cualquier sitio.

## Verificación rápida

```bash
open -a "$PWD/Regression.app"            # debe abrir Steam y renderizar la tienda
swift tools/diagnostics/list-windows.swift steam
screencapture -x -l <id> /tmp/check.png  # captura y revisar visualmente
bash build/install-game-profiles.sh      # verifica hashes/perfil Grim Dawn y vuelve a firmar
bash build/verify-protected-state.sh --include-bottle  # verifica PINs sin lanzar juegos
```

## Build

Scripts en `build/` (README §5). Toolchain ya compilado en `toolchain/x86/` — no recompilar
salvo cambio de versiones. Wine: `build/build-wine.sh`. DXMT: `build/build-dxmt.sh`.
