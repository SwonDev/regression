# CLAUDE.md — Proyecto Regression

> Aplicación nativa de barra de menús con dos backends aislados: CrossOver 26.3 es el motor
> predeterminado temporal y el motor propio Windows→macOS sigue íntegro y seleccionable.
> La biblioteca física de juegos es única; credenciales, registro y configuración permanecen
> separados. La telemetría local observa y compara, pero no aplica perfiles automáticamente.
>
> Documentación hermana: `AGENTS.md` (reglas inviolables + protocolo, fuente de verdad que
> comparte con Codex) y `README.md` (arquitectura, build reproducible, diagnósticos, método).
> Si algo aquí difiere de `AGENTS.md`, manda `AGENTS.md`.

---

## 1. Estado conseguido (2026-07-28)

**Funciona (verificado con capturas):**
- Integración oficial con la botella Steam de CrossOver, conmutación segura de backend, app
  `LSUIElement` sin Dock, biblioteca compartida y base SQLite v6 de aprendizaje exportable. La
  base normaliza motores por Wine/componentes/registro, separa opciones del juego, vincula cada
  blindado con su evidencia/configuración/motor exactos y compara de
  forma no vinculante con metadatos públicos de CodeWeavers. Los
  datos técnicos locales usan permisos `0700`/`0600` y los logs del lanzador tienen retención
  acotada.
- Steam completo: tienda, login, biblioteca, navegación, clicks precisos (CEF/Chromium vía
  parche propio de presentación cross-process IOSurface en DXMT + consumer en winemac.drv).
- Palworld completo (personaje + mundo + HUD), Moonlighter 2 (Unity IL2CPP), Grim Dawn,
  Romestead. D3D9 vía DXVK 1.10.3.
- App autocontenida y firmada (adhoc), instalada en `/Applications/Regression.app`
  (symlink a la del proyecto — el `--prefix` del wine va horneado a la ruta del proyecto;
  NO mover la app sin recompilar wine).
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
2. **La referencia es CrossOver: se copia literalmente cómo lo hace CrossOver.** Versiones
   exactas de cada componente, convenciones de build (prefix horneado), wiring de DLLs
   (qué va en system32, qué en lib, qué es builtin y qué native), configuración de botella,
   crossties. Se estudia y se replica ESO antes de inventar. La paridad se consigue
   igualando, no improvisando. Prohibido ir juego por juego sin este método.
3. **Separación estricta de backends.** El backend CrossOver usa deliberadamente la instalación
   y licencia del usuario mediante su CLI oficial. El motor propio sigue independiente: no se
   copian DLLs/dylibs ni binarios propietarios; lo aprendido se reproduce desde fuentes públicas
   o mediante reimplementación legal.
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
11. **Tras `make install` o tocar el bundle: `codesign --force --deep --sign - Regression.app`**.
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
codesign --force --deep --sign - Regression.app   # SIEMPRE tras instalar
open -a Regression            # validación visual obligatoria
```

- Toolchain ya compilado en `toolchain/x86/` — no recompilar salvo cambio de versiones.
- Detalles y receta completa: README §5. Scripts: `build/*.sh`.
- La botella vive en `~/Library/Application Support/Regression/Bottles/Steam/` (datos del
  usuario, fuera del repo).

---

## 5. Hoja de ruta (orden acordado)

1. Usar CrossOver como backend estable predeterminado y verificar visualmente cada ejecución
   desde el menú de Regression; no inferir éxito por exit code.
2. Iniciar sesión una vez en el Steam propio y revalidar Cube World desde la biblioteca
   compartida, manteniendo su perfil blindado sin cambios globales.
3. Comparar configuraciones y motores verificados en SQLite/JSON y trasladarlos al motor propio solo
   desde fuentes públicas o reimplementación legal, de forma aislada por juego.
4. Mantener MoltenVK/D3D12 y `cxcompatdb` como investigación del motor propio, sin invalidar
   FFT ni otros juegos ya confirmados por rutas distintas.
5. Menores: Wine Mono 10.4.1 cuando un juego real lo requiera y comparativas de rendimiento.

---

## 6. Verificación rápida del estado bueno

```bash
open -a Regression   # debe abrir Steam y renderizar la tienda
swift -e 'import CoreGraphics
let l = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as! [[String: Any]]
for w in l { if let n = w[kCGWindowName as String] as? String, !n.isEmpty { print("\(w[kCGWindowNumber as String]!)  \(w[kCGWindowOwnerName as String]!)  \(n)") } }'
screencapture -x -l <id> /tmp/check.png   # capturar y MIRAR la imagen
```
