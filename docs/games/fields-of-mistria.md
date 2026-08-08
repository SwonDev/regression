# Fields of Mistria — expediente de compatibilidad

## Estado blindado

- **Steam App ID:** `2142790`
- **Ejecutable:** `FieldsOfMistria.exe`
- **Backend:** motor propio de Regression, baseline general sin perfil por ejecutable
- **Run perfecto:** `BAAC2B06-3CAD-467A-B1F1-834B76B794AD` (proceso representativo exit=0)
- **Huella de motor/configuración:**
  `9d3e77a78a6501f33b32705937555a833f7fa3966011e02616d3811f592146b9`
- **Catálogo compilado:** revisión `2026-08-08.1`, origen `embeddedCatalog`
- **Resultado:** arranque directo renderizando en pantalla completa, menú, nueva partida,
  gameplay, pausa, opciones persistentes y cierre limpio.
- **Confirmación:** el usuario jugó ~1 h en el run con el parche (nueva partida, granja y
  pueblo), confirmó el funcionamiento perfecto en dos arranques consecutivos sin
  intervención y registró el veredicto perfecto desde la app.
- **Dependencia de CrossOver:** ninguna. CrossOver 26.3 reproduce el mismo fallo y se usó
  solo como referencia del síntoma compartido.

## Síntoma y causa raíz

El juego iniciaba con audio correcto y **pantalla verde uniforme**: ni logo ni menú. En
CrossOver 26.3 ocurría lo mismo, así que nunca fue una regresión del motor.

Fields of Mistria no usa el runtime estándar de GameMaker: sus assets son GML pero el
runner es `maybe`, un motor propio de NPC Studio escrito en **Rust + SDL3 + FMOD** que
renderiza con **OpenGL 4.1** (`GlRenderer("Apple M5 Pro") 4.1 Metal - 90.5`). Toda la
teoría D3D11/DXMT era falsa: el juego solo consulta DXGI para enumerar modos de pantalla.

La secuencia del fallo, verificada en código y en ejecución:

1. SDL3 crea la ventana de **1×1** y el contexto GL se hace actual sobre ella;
   `wine_updateBackingSize` (`cocoa_opengl.m`) fija `kCGLCPSurfaceBackingSize = {1,1}` y
   activa `kCGLCESurfaceBackingSize`. La CGL surface queda clavada a 1×1.
2. El juego pasa a fullscreen (1512×982) en varios `SetWindowPos` con el hilo de render
   ya swappeando. El token `updated` de win32u (`GL_FLUSH_UPDATED`) es **one-shot** y se
   consume en un flush intermedio con el client rect todavía en 1×1.
3. Además, `opengl_drawable_flush` (`win32u/opengl.c`) tiene el bug upstream
   `flags = GL_FLUSH_INTERVAL` (asignación, no `|=`) que **borra** `GL_FLUSH_UPDATED`
   cuando el cambio de swap interval llega en el mismo flush — el juego fija VSync justo
   al arrancar.
4. Sin token, nada vuelve a medir la ventana: CoreGL estira la surface 1×1 a toda la
   pantalla → verde uniforme permanente con el juego corriendo (música y lógica vivas).

Cualquier evento de ventana posterior (moverla 1 px, ciertos cambios de modo) rehace la
surface al instante: por eso el usuario lo veía funcionar cuando lo lanzaba él y los
lanzamientos silenciosos quedaban verdes. Descartado con pruebas: overlay de Steam
(verde también sin Steam), foco/pausa (un run recuperó el foco y siguió verde), modo
ventana como requisito (en ventana renderiza siempre, pero no es la solución deseada),
caché de shaders Metal.

## Corrección (parche propio)

`patches/wine-26.3.0-winemac-gl-surface-resync.patch` sobre
`sources-26.3.0/wine/dlls/winemac.drv/opengl.c` (unix-side puro; la mitad PE
`winemac.drv` queda byte a byte idéntica, hash PIN `da91ec70…` intacto):

- `macdrv_context` gana `RECT draw_rect`, cebado en `macdrv_make_current`.
- `macdrv_surface_flush` compara el client rect vivo (`NtUserGetClientRect` con
  `NtUserGetDpiForWindow`, la misma forma que ya usa `make_context_current`) y, si
  cambió de verdad, fuerza `GL_FLUSH_UPDATED` en ese mismo swap. El primer present tras
  entrar en fullscreen rehace la surface con el tamaño real. No depende del token.
- Sin gate: reproduce el comportamiento que el driver ya intenta tener. En reposo es un
  `NtUserGetClientRect` (caché local, sin round-trip) + `EqualRect` por swap.

Solo afecta al path WGL de winemac. DXMT, D3DMetal, DXVK y Vulkan no pasan por esa
función; el consumer cross-process de CEF (`cocoa_window.m`) no se toca. El perfil HWR2
usa su propio `winemac.so` (`lib/profiles/heroes-hammerwatch-2`), no tocado.

## Matriz funcional

| Puerta | Evidencia observada |
|---|---|
| Inicio/render | 2/2 arranques con parche renderizan el menú sin intervención (confirmado por el usuario con capturas); antes: verde permanente |
| Entrada | navegación de menús con clicks exactos (Ajustes/Pantalla/VSync/Salir) y gameplay del usuario |
| Opciones | VSync On→Off escrito en `settings.json`; persistió tras relanzar (`vsync=0`) |
| Restauración | VSync devuelto a On desde la UI (`vsync=1`); settings del usuario intactos (`open_fscreen=true`) |
| Pausa | ciclos pérdida/recuperación de foco pausan y reanudan correctamente |
| Gameplay | nueva partida, granja y pueblo (~1 h real; 6:00am→9:26am in-game) y sesión nocturna certificada |
| Cierre | Salir con confirmación → proceso representativo exit=0 (run BAAC2B06) |
| Recursos propios | proceso con `winemac.so`/`winemetal.so` de Regression.app; cero rutas ejecutables de CrossOver |
| No regresión | Steam tienda renderiza y navega con el driver parcheado; `verify-protected-state.sh` OK con PIN actualizado (`4723d219…`); perfiles Grim Dawn/DD2/DragonSword/HWR2 intactos por hash; 86/86 swift tests |

## Incidencia ajena resuelta durante la investigación

El 2026-08-04 otro proyecto del usuario (**Switch2Bridge**) instaló un shim de
`libSDL2-2.0.0.dylib` dentro de `Regression.app` que rompía la firma
(`codesign --verify` fallaba por «file added»). Decisión del usuario: **conservar el
shim y refirmar con él dentro**. El bundle quedó sellado y verificado
(`--deep --strict` OK) con identidad Apple Development estable.

## Evidencia privada y rollback

```text
backups/fields-of-mistria-investigation-20260807-202141/private-evidence/
```

Incluye capturas del síntoma y del resultado, logs del runner (`MAYBE_OPENGL_DEBUG`),
inventario de módulos, snapshot de settings, informes de build/tests/firma y manifiesto
de rollback, todo con SHA-256 en `SHA256SUMS.txt`. Claves:

- Rollback de motor: restaurar `winemac.so.bundle-orig` (`50fda6d2…`) en
  `Contents/SharedSupport/wine-root/lib/wine/x86_64-unix/winemac.so` y refirmar;
  `opengl.c.orig` revierte la fuente.
- El backup transaccional del empaquetado del catálogo quedó en
  `backups/native-packaging/`.

## Regla de no regresión

Fields of Mistria usa el baseline general con el winemac parcheado; no tiene perfil por
ejecutable ni overrides. Cualquier cambio futuro en `macdrv_surface_flush` o en la ruta
GL de winemac debe repetir este expediente: arranque fullscreen sin intervención, menú,
opciones persistentes, gameplay y cierre con exit=0, más la matriz winemac (Steam
tienda + clicks + un perfil GL blindado).
