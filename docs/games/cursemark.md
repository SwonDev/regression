# Cursemark (App ID 3219180)

> **Estado:** Verificado perfecto en Regression · run `2798D808-2007-4C66-ADC9-D5E4A3AB1A11`
> **Motor del juego:** Heaps.io sobre HashLink (`libhl.dll`, `*.hdll`, `hlboot.dat`) con SDL2 y OpenGL
> **Corrección:** general del runtime, sin perfil por ejecutable y sin entradas en el catálogo de perfiles

## Síntoma

Al lanzar el juego, Cursemark abortaba antes del primer fotograma con un diálogo propio:

```
OpenGL Error
The application was unable to create an OpenGL context
for your Apple M5 Pro video card.
OpenGL 3.2+ is required, please update your driver.
```

La base local conservaba tres ejecuciones previas terminadas en `crashed` con `exit -1`
(`5E700D01…`, `C94A73D7…`, `D8F9B172…`). El mensaje culpa al driver, pero el driver no era la causa.

## Causa raíz

Son **dos puertas independientes**, y ambas debían abrirse. El diagnóstico se hizo con
`WINEDEBUG=+wgl` sobre el ejecutable exacto.

### Puerta 1 — contexto core 3.2 sin el bit forward-compatible

El juego pide exactamente esto:

```
macdrv_context_create   Attrib 0x2091: 3    WGL_CONTEXT_MAJOR_VERSION_ARB
macdrv_context_create   Attrib 0x2092: 2    WGL_CONTEXT_MINOR_VERSION_ARB
macdrv_context_create   Attrib 0x9126: 1    WGL_CONTEXT_PROFILE_MASK_ARB = CORE
warn:wgl: OS X only supports forward-compatible 3.2+ contexts
```

No manda `WGL_CONTEXT_FLAGS_ARB`, así que no lleva `WGL_CONTEXT_FORWARD_COMPATIBLE_BIT_ARB`.
macOS **solo** expone contextos core 3.2+ en forma forward-compatible, de modo que la petición no
puede satisfacerse de otra manera y `macdrv_context_create` devolvía `ERROR_INVALID_VERSION_ARB`.

Es la misma clase de fallo que Heroes of Hammerwatch II, pero llega por otra vía: HWR2 la provoca
desde BGFX y Cursemark desde SDL2, que solo añade el bit si la aplicación lo pide explícitamente.
El arreglo histórico de HWR2 quedó atado a `CX_FWD_COMPAT_GL_CTX=1`, una variable que el router
exporta **únicamente** para `hwr2.exe`; cualquier otro título de esa familia seguía roto.

### Puerta 2 — la tabla de imports de HashLink

Con el contexto ya concedido, el juego resuelve su tabla completa de funciones GL y **se detiene en
la primera que no resuelve**:

```
wglGetProcAddress "glCreateProgram"   -> 0x7ffb11ea867c
wglGetProcAddress "glDispatchCompute" -> 0x0        ← aquí paraba
```

HashLink resuelve 116 funciones GL; siete pertenecen a compute/SSBO/indirect y no existen en el
OpenGL 4.1 al que Apple congeló macOS: `glDispatchCompute`, `glMemoryBarrier`, `glBindImageTexture`,
`glShaderStorageBlockBinding`, `glGetProgramResourceIndex`, `glMultiDrawElementsIndirect` y
`glMultiDrawElementsIndirectCountARB`. En macOS nativo HashLink enlaza OpenGL directamente y no
resuelve punteros, así que este camino solo aparece al ejecutar la build de Windows bajo Wine.

## Corrección

### `patches/wine-26.3.0-opengl-core-forward-compat.patch` (general)

`macdrv_context_create` concede el bit forward-compatible a **toda** petición core ≥3.2 que lo
omita, en lugar de rechazarla. No puede degradar ningún título que hoy funcione: esa rama terminaba
siempre en un fallo duro, de modo que el cambio convierte un fallo cierto en un contexto válido.
`CX_FWD_COMPAT_GL_CTX=1` se conserva por compatibilidad y
`REGRESSION_GL_CORE_FORWARD_COMPAT=0` restaura el rechazo estricto para una A/B sin recompilar.

### `patches/wine-26.3.0-hashlink-gl-compute-stubs.patch` (acotado por contenido)

`dlls/ntdll/unix/loader.c` reconoce un runtime HashLink **por contenido**: la raíz del juego bajo
`steamapps/common` debe contener a la vez `hlboot.dat` y `libhl.dll`. No hay lista de ejecutables ni
App IDs, así que cualquier título Heaps/HashLink presente o futuro queda cubierto y ningún otro
motor se ve afectado. Solo entonces exporta `REGRESSION_GL_HASHLINK_RUNTIME=1`.

`dlls/opengl32/unix_wgl.c` resuelve, únicamente en esos procesos, stubs para las siete entradas
ausentes. Los stubs **no hacen el trabajo**: registran un `ERR` la primera vez que se los invoca, de
modo que un título que realmente dependiera de compute dejaría evidencia en el log en lugar de
renderizar mal en silencio.

**Evidencia de que Cursemark no usa compute:** en el run validado los stubs se resolvieron pero
**nunca fueron invocados** (cero registros de `did nothing`) mientras el juego renderizaba 37.548
`macdrv_surface_swap`.

## A/B que fija la causa

| Variante | Resultado |
|---|---|
| Baseline (runtime 1.12.3) | `OS X only supports forward-compatible 3.2+ contexts` → diálogo OpenGL Error |
| Solo puerta 1 | Contexto concedido, para en `glDispatchCompute -> 0x0`, 0 swaps → diálogo OpenGL Error |
| Puertas 1 + 2 | Menú, partida cargada, gameplay, HUD, entrada y cámara; 37.548 swaps |

## Validación

- Menú principal completo en Retina 3024×1968, cursor propio del juego.
- «Continue Journey» carga la partida real en el *Shrine of Valoria*: personaje, HUD (100/100, 3/3,
  maná 44), iluminación dinámica de antorchas, cascadas y vegetación sin artefactos.
- Movimiento por clic con seguimiento de cámara y cursor preciso.
- Cierre limpio: proceso representativo `pid=1388` con `exit=0` y run reconciliado.
- Steam/CEF renderiza la tienda con el mismo runtime.
- Confirmación visual y jugable explícita del usuario sobre la instalación canónica.

## Regla de no regresión

La corrección es **general y sin perfil**: Cursemark no debe recibir una entrada en
`GameRuntimeProfileCatalog` ni una variable por ejecutable. Si un título HashLink futuro fallara,
primero hay que comprobar con `WINEDEBUG=+wgl` si aparece una función GL nueva sin resolver; ampliar
el conjunto compilado de stubs exige repetir la matriz y comprobar que ninguno se invoca en
ejecución. `REGRESSION_GL_CORE_FORWARD_COMPAT=0` reproduce el estado anterior para comparar.
