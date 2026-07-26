# CLAUDE.md — Proyecto Regression

> Motor de compatibilidad Windows→macOS propio (equivalente a CrossOver), compilado 100 %
> desde fuentes open-source. `Regression.app` abre Steam de Windows en macOS (Apple Silicon,
> Rosetta 2) con doble click y ejecuta juegos. Proyecto personal/educativo.
>
> Documentación hermana: `AGENTS.md` (reglas inviolables + protocolo, fuente de verdad que
> comparte con Codex) y `README.md` (arquitectura, build reproducible, diagnósticos, método).
> Si algo aquí difiere de `AGENTS.md`, manda `AGENTS.md`.

---

## 1. Estado conseguido (2026-07-26)

**Funciona (verificado con capturas):**
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
- Backups de referencia: `backups/regression-blindado-20260725.tar.gz` (app + docs + parches
  + scripts) y `backups/botella-config-20260725.tar.gz` (registros + fuentes + DLLs).
  Punto de restauración completo.

**Bugs abiertos con diagnóstico hecho (detalle completo en README §8):**
- **FFT (D3D12)**: crash en `vkCreateComputePipelines` (vkd3d → winevulkan → nuestro
  MoltenVK con 3 stubs de SPIRV-Cross). Repro: `build/d3d12test.exe` (fuente versionada).
- **Cube World (D3D11)**: pantalla negra; crea dos swapchains (raíz + hija). En CrossOver
  con DXMT también falla ("Could not initialize Direct3D") — verificar si funciona con DXVK.

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
3. **Regression es 100 % independiente de CrossOver.** Nada en runtime puede depender de
   que CrossOver esté instalado: ni DLLs, ni dylibs, ni rutas, ni procesos, ni su botella.
   CrossOver se usa SOLO como referencia de estudio (fuentes LGPL oficiales, inspección
   estática, comparativas A/B). Piezas que solo existen en CrossOver (su fork de DXMT, su
   SPIRV-Cross, su MoltenVK compilada, cxcompatdb) se reconstruyen desde fuentes públicas
   o se reimplementan — NO se copian binarios.
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
6. **Limpiar `dxmt-cxpresent-*.id` antes de lanzar** (ya en el launcher): ficheros stale →
   pantalla negra por hwnd reutilizado.
7. **No experimentar sobre el estado bueno.** Experimentos en copia de la botella o con
   dlls respaldadas; solo se aplica tras validar.
8. **Antes de diagnosticar, descartar el entorno** (la mitad de los "bugs" históricos):
   wineservers de otros builds corriendo (muerte silenciosa), `services.exe` huérfanos
   (iconos Steam fantasma en la barra de menús de macOS), diálogo modal de Steam Cloud
   bloqueando el IPC (los juegos mueren al instante sin log → desactivar cloud del appid
   en `userdata/<id>/config/localconfig.vdf`), juego que necesita Steam activo por DRM.
9. **Tras `make install` o tocar el bundle: `codesign --force --deep --sign - Regression.app`**.
10. **PE sin strip** (el strip rompe unwind SEH y la firma de módulos builtin).
11. **No cambiar el modelo de IA ni el stack decidido** sin permiso explícito del usuario.
12. Responde siempre en **español**, con tildes. Código y comentarios del repo en el idioma
    del código existente.

---

## 3. Cómo se trabaja aquí (resumen del protocolo de AGENTS.md)

- **Una variable por cambio.** Si cambias dos cosas y algo se rompe (o se arregla), no
  sabes cuál fue — eso ya ha costado días.
- **Ciclo obligatorio**: reproducir → descartar entorno → backup → UNA variable →
  validar matriz → solo entonces integrar (y nuevo backup si es mejor).
- **Matriz de validación según lo tocado** (siempre con captura visual):
  - Wine build / dlls wine-root → tienda + Moonlighter 2 + Palworld.
  - DXMT (d3d11/dxgi/d3d10core) → tienda (CEF) + Palworld (personajes visibles).
  - DXVK / d3d9 → un juego D3D9 + tienda.
  - winemac.drv / parche cross-process → tienda + clicks + Palworld.
  - Launcher (env, rutas) → arranque desde cero: tienda + un juego.
  - Registro botella → tienda + clicks + un juego.
- **"Compila" o "el proceso corre" NO es validación.** Validar = captura visual mirada.
- **PINs** (no tocar sin validar la matriz completa): DXMT v0.72 + parche cross-process
  (`main` rompe los skeletal meshes de Palworld); wine CX 26.3.0 con `--prefix` horneado a
  la app; dxgi de DXMT en pareja; RetinaMode=n; 55 fuentes TTF en la botella; PE sin strip.

---

## 4. Build rápido

```bash
bash build/build-wine.sh    # wine CX 26.3.0 + parche winemac → instala en Regression.app
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

1. **MoltenVK compute** (desbloquea FFT + todos los D3D12): reproducir el crash con
   `build/d3d12test.exe` (`WINEDLLOVERRIDES=dxgi=b`), backtrace con lldb, recompilar
   MoltenVK activando los 3 stubs de `spirv_msl.hpp` de uno en uno
   (`texture_offset_buffer_index`, `add_texture_buffer_offsets`, `bitwise_not_causes_ice`).
2. **D3D12 vía D3DMetal de Apple** (alternativa si MoltenVK se resiste): wiring de CX
   mapeado en README §8; CW HACK 22434 ya compilado en nuestro wine
   (`ntdll/unix/loader.c`, env `CX_APPLEGPTK_LIBD3DSHARED_PATH` ya en el launcher).
3. **Cube World**: verificar primero si en CrossOver funciona con DXVK; el consumer de
   winemac necesita z-order de subcapas para múltiples superficies; candidato child-hwnd
   ya en fuente (`build/toolchain/dxmt-src`, no instalado — la dll en system32 es la
   original blindada).
4. `cxcompatdb.so` (compat per-app de CX; nuestro wine avisa de su ausencia).
5. Menores: Wine Mono 10.4.1 (.NET), comparativa FPS Grim Dawn vs CX, más juegos del
   catálogo según pida el usuario.

---

## 6. Verificación rápida del estado bueno

```bash
open -a Regression   # debe abrir Steam y renderizar la tienda
swift -e 'import CoreGraphics
let l = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as! [[String: Any]]
for w in l { if let n = w[kCGWindowName as String] as? String, !n.isEmpty { print("\(w[kCGWindowNumber as String]!)  \(w[kCGWindowOwnerName as String]!)  \(n)") } }'
screencapture -x -l <id> /tmp/check.png   # capturar y MIRAR la imagen
```
