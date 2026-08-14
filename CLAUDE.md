# CLAUDE.md — Proyecto Regression

> Aplicación nativa de barra de menús con Regression como único motor operativo. Su runtime,
> botella y única biblioteca física de juegos son propios; CrossOver no se invoca, no comparte
> estado y solo aparece en expedientes históricos fechados. No existe red, CLI ni backend de
> CodeWeavers en el producto. La telemetría local
> conserva evidencia, pero no aplica perfiles automáticamente.
>
> Documentación hermana: `AGENTS.md` (reglas inviolables + protocolo, fuente de verdad que
> comparte con Codex) y `README.md` (arquitectura, build reproducible, diagnósticos, método).
> Si algo aquí difiere de `AGENTS.md`, manda `AGENTS.md`.

> **Contrato actual del checkout (14 de agosto de 2026):** Regression **1.12.1 (39)**, release
> estable publicada, y SQLite **v17**. **v1.11.0 (37)** es el baseline histórico; conservar sus
> gates de transición no autoriza a saltarse la matriz global de futuras releases.

---

## 1. Estado conseguido (2026-07-28)

**Baseline histórico verificado con capturas (2026-07-28; no describe la arquitectura actual):**
- La etapa anterior integraba la botella Steam de CrossOver, conmutación segura de backend, app
  `LSUIElement` sin Dock, biblioteca compartida y base SQLite v11 de aprendizaje exportable. Ese
  diseño se conserva solo como historia y ya no describe la arquitectura operativa. La
  base normaliza motores por Wine/componentes/registro, separa opciones del juego, vincula cada
  blindado con su evidencia/configuración/motor exactos, conserva el preflight de cada prueba y
  conservaba entonces comparaciones no vinculantes con metadatos públicos de CodeWeavers. Esa
  integración fue retirada. Los
  datos técnicos locales usan permisos `0700`/`0600` y los logs del lanzador tienen retención
  acotada.
- Steam completo: tienda, login, biblioteca, navegación, clicks precisos (CEF/Chromium vía
  parche propio de presentación cross-process IOSurface en DXMT + consumer en winemac.drv).
- Palworld completo (personaje + mundo + HUD), Moonlighter 2 (Unity IL2CPP), Grim Dawn,
  Romestead. D3D9 vía DXVK 1.10.3.
- App autocontenida y firmada con identidad de desarrollo estable. La única instalación
  descubrible es el bundle físico `/Applications/Regression.app`; `Regression.app/` en el
  checkout es solo un artefacto de desarrollo desregistrado. El runtime público lleva el
  `--prefix` horneado para `/Applications`, por lo que no se mueve sin recompilar Wine.
- Repo privado en GitHub: `SwonDev/regression` (docs + scripts + parches propios; sin
  binarios de Apple ni fuentes de CrossOver, ver `NOTICE.md`).
- Icono oficial del usuario integrado (`assets/icon/oficial/`).
- Backups consolidados: base general en `regression-last-good-20260726.tar.gz`, perfil posterior
  verificado en `grimdawn-d3dmetal-perfect-20260727-1802/`, baseline anterior y configuración de
  botella. `backups/README.md` distingue recuperación, evidencia rechazada y datos de usuario.
- Catálogo canónico `VerifiedGameCatalog`: Cube World, FFT y Grim Dawn permanecen marcados como
  `Verificado perfecto: Regression` aunque se regenere SQLite. La base conserva todos los runs,
  configuraciones e incidencias que explican cómo se blindó cada perfil.

**Perfiles importantes:**
- **FFT**: funcionamiento perfecto confirmado por el usuario en el motor propio; el crash de
  la ruta vkd3d queda como diagnóstico histórico, no como veredicto del juego.
- **Cube World**: perfecto confirmado en Regression. La botella CrossOver reinstalada falla
  actualmente con pantalla negra/Direct3D; no debe degradar el perfil propio blindado.

---

## 2. Reglas inviolables

### Principios (valen más que cualquier arreglo concreto)

1. **JAMÁS se integra algo que rompe lo que ya funciona.** Un arreglo que apaga otra cosa
   no es un arreglo: se revierte al instante y se repiensa. Lo que decide es la matriz de
   validación (§3), no las intenciones.
2. **El baseline propio y las fuentes FOSS mandan.** Las versiones exactas, convenciones de
   build, wiring de DLLs, configuración y código oficial del runtime se contrastan antes de
   cambiar nada. Baseline y candidato se ejecutan dentro de Regression; no se instala, abre,
   consulta o inspecciona CrossOver para diagnosticar.
3. **Autonomía operativa estricta.** Regression no invoca CrossOver ni comparte con él botella,
   juegos, credenciales, registro o configuración. No se copian DLLs/dylibs ni binarios
   propietarios; las observaciones históricas no tienen autoridad y toda implementación actual
   procede de fuentes FOSS oficiales o recursos Apple autorizados localmente.
4. **Legalidad limpia.** Solo fuentes open-source oficiales. Nada de descompilar ni extraer
   código de binarios propietarios (GUI de CrossOver, licencias, forks privados). Los
   binarios de Apple (GPTK: D3DMetal.framework, libd3dshared.dylib) se usan tal cual los
   distribuye Apple, solo en local, jamás redistribuidos.

### Reglas técnicas duras (errores que YA se han cometido y NO se repiten)

1. **Backup antes de tocar botella o bundle** (`backups/`). Sin excepciones.
2. **Validación visual obligatoria tras cualquier cambio gráfico**: relanzar, capturar la
   ventana de Steam (`screencapture -x -l <CGWindowID>`), confirmar que la tienda renderiza.
   Negra → revertir al instante.
3. **NO overrides `d3d11/d3d10core/dxgi=native`** en el registro de la botella: las DLLs de
   DXMT son módulos wine (formato builtin) y el override las hace "not found". DXMT va en
   system32 sin override. Overrides solo para PE planas (d3d9 de DXVK sí).
4. **La dxgi de DXMT es intocable EN PAREJA**: va en system32 Y en wine-root. Wine valida la
   pareja; si wine-root lleva otra dxgi, la de DXMT deja de cargar y TODOS los juegos D3D11
   mueren al instante (exit 53). El conflicto con D3D12 (que necesita la dxgi de wine) está
   documentado con sus vías de solución en README §8.
5. **No mezclar d3d11/dxgi de Apple con DXMT** en system32 (CEF muere). d3d12* de Apple sí
   coexiste. Las dlls de Apple del GPTK son formato builtin: como "native" dan "not found";
   se cargan solo desde su propio árbol (`lib/apple_gptk/wine`).
6. **Grim Dawn está fijado a D3DMetal por proceso.** `grim dawn.exe` usa
   `lib/profiles/grim-dawn` → `../apple_gptk/wine`, activa D3DMetal solo en ese proceso y
   fuerza `atidxx64/d3d9/nvapi64/nvngx=builtin`. Nunca convertirlo en ajuste global.
7. **Cerrar siempre la validación en la UI.** Tras la confirmación visual, verificar el run como
   `perfect`, refrescar Regression y comprobar la fila verde. Conservar los fallos históricos y
   añadir el juego a `VerifiedGameCatalog` al blindarlo en una versión publicada.
8. **Limpiar `dxmt-cxpresent-*.id` antes de lanzar** (ya en el launcher): ficheros stale →
   pantalla negra por hwnd reutilizado.
9. **No experimentar sobre el estado bueno.** Experimentos en copia de la botella o con
   dlls respaldadas; solo se aplica tras validar.
10. **Antes de diagnosticar, descartar el entorno** (la mitad de los "bugs" históricos):
   wineservers de otros builds corriendo (muerte silenciosa), `services.exe` huérfanos
   (iconos Steam fantasma en la barra de menús de macOS), diálogo modal de Steam Cloud
   bloqueando el IPC (los juegos mueren al instante sin log → desactivar cloud del appid
   en `userdata/<id>/config/localconfig.vdf`), juego que necesita Steam activo por DRM.
11. **Tras `make install` o tocar el bundle: `Scripts/sign_regression.sh Regression.app`**. La
    firma estable conserva los permisos; la firma ad hoc es solo un fallback explícito.
12. **PE sin strip** (el strip rompe unwind SEH y la firma de módulos builtin).
13. **No cambiar el modelo de IA ni el stack decidido** sin permiso explícito del usuario.
14. Responde siempre en **español**, con tildes. Código y comentarios del repo en el idioma
    del código existente.
15. **No atribuir un Steam Wine solo por el texto de `ps`.** macOS puede mostrar únicamente
    `C:\...\Steam.exe` tras el desacople. Excluir `steamwebhelper.exe`, resolver el backend por
    los ficheros abiertos del cliente real (`lsof`) y no tratar un wineserver vivo como prueba
    suficiente de que Steam está activo.
16. **La terminación nativa no espera indefinidamente a la red.** Cancelar las tareas, serializar
    reconciliación y cierre SQLite, y responder entonces a AppKit. Validar el cierre instalado
    después de tocar este flujo.
17. **No anidar layouts perezosos en el popover.** Las filas actuales usan `VStack` dentro del
    único `ScrollView`; `LazyVStack` con grupos desplegables produjo un ciclo de AttributeGraph.
    Tras cambios de UI, estresar Aprendizaje y comprobar respuesta, cierre y CPU en reposo.
18. **Toda prueba de juego empieza con el preflight canónico.** Un bloqueo detiene el lanzamiento;
    un aviso se conserva con el run. El diagnóstico solo observa: no termina procesos, elimina
    archivos, modifica botellas ni concede por sí mismo una certificación.
19. **Solo `/Applications/Regression.app` puede ser una aplicación descubrible.** Los artefactos
    de desarrollo se desregistran y los rollbacks se conservan en directorios `.noindex`. La
    sesión no termina hasta que `build/verify-canonical-installation.sh` confirma firma,
    Spotlight, LaunchServices y ausencia de otras instalaciones. Ver
    `docs/canonical-installation.md`.
20. **Un `perfect` requiere custodia completa de procesos.** El PID del run debe ser la fila
    representativa exacta, todos los procesos deben estar cerrados y la verificación debe ser
    posterior. Cambiar después `run_processes` invalida el veredicto y su certificación.
21. **No ocultar degradaciones de telemetría.** Rotación, truncado, lectura parcial, log ausente o
    formato inesperado se propagan como incidencias tipadas y acotadas. Una nueva época de log no
    puede consumir eventos antiguos para satisfacer una intención reciente.
22. **Windows Media solo se repara para un juego exacto.** Exigir App ID canónico, inventario
    anclado y fresco con WMA/WMV/ASF, Steam en reposo, payload autorizado, lease exclusivo, WAL,
    backup, rollback, recibo y verificación posterior. Nunca ejecutar la reparación al abrir Steam
    sin App ID ni tomar rutas o comandos desde SQLite.
23. **El runtime público es un conjunto sellado.** Wrapper, wineserver, loader, `ntdll.so`,
    `wine.inf`, las dos `ntdll.dll` PE y VC++/UCRT deben coincidir con hashes/permisos compilados.
    Usar rutas absolutas al Wine y `WINESERVER` sellados, fijar `PATH` exactamente a
    `/usr/bin:/bin:/usr/sbin:/sbin`, borrar `WINESERVERSOCKET` heredado y no aceptar Wine,
    wineserver ni un `PATH` hostil del entorno.
24. **El sobre de lanzamiento v17 precede al `spawn`.** Debe vincular App ID, run, preflight
    reciente, generación fresca de requisitos e identidades cerradas. No guarda comandos ni
    rutas. La telemetría puede adoptar el run y solo la verificación explícita lo completa. Las
    políticas puras de retry/recuperación no ejecutan auto-retry ni rollback: ambas mutaciones
    permanecen bloqueadas hasta integrar receta compilada, verificador y recibo. Steam observado
    exige gesto; un recibo o telemetría cerrada nunca sustituyen la verificación funcional.

---

## 3. Cómo se trabaja aquí (resumen del protocolo de AGENTS.md)

- **Una variable por cambio.** Si cambias dos cosas y algo se rompe (o se arregla), no
  sabes cuál fue — eso ya ha costado días.
- **Ciclo obligatorio**: reproducir → descartar entorno → backup → UNA variable →
  validar matriz → solo entonces integrar (y nuevo backup si es mejor).
- **Matriz de validación según lo tocado** (siempre con captura visual):
  - Wine build / dlls wine-root → tienda + Moonlighter 2 + Palworld.
  - Perfil aislado por ejecutable → juego objetivo completo + tienda + un perfil blindado no afectado.
  - DXMT (d3d11/dxgi/d3d10core) → tienda (CEF) + Palworld (personajes visibles).
  - DXVK / d3d9 → un juego D3D9 + tienda.
  - winemac.drv / parche cross-process → tienda + clicks + Palworld.
  - Launcher (env, rutas) → arranque desde cero: tienda + un juego.
  - Registro botella → tienda + clicks + un juego.
- **"Compila" o "el proceso corre" NO es validación.** Validar = captura visual mirada.
- **PINs** (no tocar sin validar la matriz completa): DXMT v0.72 + parche cross-process
  (`main` rompe los skeletal meshes de Palworld); wine CX 26.3.0 con `--prefix` horneado a
  la app; dxgi de DXMT en pareja; Grim Dawn con D3DMetal completo y overrides builtin por
  proceso; RetinaMode=n; 55 fuentes TTF en la botella; PE sin strip.

---

## 4. Build rápido

```bash
bash build/build-wine.sh    # wine CX 26.3.0 + parche winemac → instala en Regression.app
bash build/install-game-profiles.sh  # verifica/fija Grim Dawn y firma el bundle
bash build/verify-protected-state.sh --include-bottle  # comprueba todos los PIN sin lanzar juegos
# DXMT: meson compile -C build/toolchain/dxmt72  (fuente: build/toolchain/dxmt-src, v0.72 + parches)
Scripts/sign_regression.sh Regression.app  # SIEMPRE tras instalar
open /Applications/Regression.app          # validación visual obligatoria
bash build/verify-canonical-installation.sh # una única app descubrible
```

- Toolchain ya compilado en `toolchain/x86/` — no recompilar salvo cambio de versiones.
- Detalles y receta completa: README §5. Scripts: `build/*.sh`.
- La botella vive en `~/Library/Application Support/Regression/Bottles/Steam/` (datos del
  usuario, fuera del repo).

---

## 5. Hoja de ruta actual

1. Mantener Regression como único backend estable y verificar visualmente cada ejecución desde
   su menú; no inferir éxito por exit code.
2. Validar Steam y los juegos desde la única biblioteca física dentro de la botella Regression,
   manteniendo cada perfil blindado sin cambios globales.
3. Conservar las observaciones históricas en SQLite/JSON y trasladar mejoras al motor propio solo
   desde fuentes públicas o reimplementación legal, de forma aislada por juego.
4. Mantener MoltenVK/D3D12 como investigación aislada del motor propio, sin invalidar FFT ni
   otros juegos ya confirmados por rutas distintas. `cxcompatdb` no se consulta ni se replica.
5. Menores: Wine Mono 10.4.1 cuando un juego real lo requiera y comparativas de rendimiento.

---

## 6. Verificación rápida del estado bueno

```bash
open /Applications/Regression.app   # debe abrir Steam y renderizar la tienda
swift -e 'import CoreGraphics
let l = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as! [[String: Any]]
for w in l { if let n = w[kCGWindowName as String] as? String, !n.isEmpty { print("\(w[kCGWindowNumber as String]!)  \(w[kCGWindowOwnerName as String]!)  \(n)") } }'
screencapture -x -l <id> /tmp/check.png   # capturar y MIRAR la imagen
```
