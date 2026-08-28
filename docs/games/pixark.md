# PixARK — «suena la música y se cierra solo»

**App ID 593600 · Unreal Engine 4.5.1 (fork de ARK, `ShooterGame`) · D3D11 · 64 bits**

## Síntoma

Se pulsa «Jugar» en el Steam de Regression, el proceso arranca, suena un fragmento de la música
de la portada y la ventana nunca llega a aparecer: el juego se cierra solo. No hay diálogo de
error, no hay crash de Windows y el `ShooterGame.log` queda cortado en 4096 bytes exactos —el
buffer sin volcar—, así que el log del juego no dice nada útil.

## Causa raíz

El proceso no se cae: **lo aborta el traductor gráfico**. Con la salida de Wine a la vista el
último renglón antes de morir es inequívoco:

```
0794:warn:seh:OutputDebugStringA "LogD3D11RHI: Async texture creation enabled"
err:   ../dxmt-src/src/d3d11/d3d11_context_impl.cpp:UpdateTexture: "update staging texture".
0794:trace:seh:raise (22)          ← SIGABRT
```

`UpdateTexture` de DXMT termina en `UNIMPLEMENTED("update texture: staging")` cuando el destino
de un `UpdateSubresource` es una textura `D3D11_USAGE_STAGING`. Es exactamente lo que hace la
creación asíncrona de texturas de UE4: crea la textura en `STAGING`, la rellena con
`UpdateSubresource` y la copia con `CopyResource` a la textura definitiva. UE4 activa ese camino
porque DXMT declara `DriverConcurrentCreates = TRUE` (`d3d11_inspection.cpp:13`), y lo activa
**durante la inicialización del RHI**, antes de abrir ventana.

Por eso el juego suena —el audio ya está inicializado— y muere sin pintar un solo fotograma.

## Lo que no era, con evidencia

| Hipótesis | Descartada porque |
|---|---|
| Falta un runtime (VC++/UCRT) | El proceso llega a inicializar el RHI de D3D11; el fallo es posterior |
| Steam Cloud desincronizada | El `appmanifest` está completo y el fallo se reproduce con Steam en reposo |
| El streaming de texturas | Con `-NOTEXTURESTREAMING` **muere igual**: el `UpdateSubresource` sobre staging ocurre en la inicialización del RHI, no al hacer streaming |
| El entorno (wineservers huérfanos) | Reproducido con sesión Wine limpia y Steam recién arrancado |

## Los otros dos backends también fallan, y por motivos distintos

Antes de fijar el perfil se midieron los tres caminos disponibles. Importa dejarlo escrito: el
juego necesita **las dos cosas a la vez**, y sólo un backend las tiene.

| Backend | Resultado |
|---|---|
| **DXMT** (baseline) | Aborta en la inicialización del RHI: `UpdateTexture: staging` no implementado |
| **DXVK** (`lib/dxvk`) | Arranca, menú y mundo, pero sus **geometry shaders** no compilan: SPIRV-Cross emite `EmitVertex()` en MSL y Metal no lo conoce → `VK_ERROR_INVALID_SHADER_NV`, después `kIOGPUCommandBufferCallbackErrorPageFault` y `VK_ERROR_DEVICE_LOST`. El juego cae con «Client resource loading has encountered an unexpected condition» |
| **Apple GPTK 4.0b2** | El proceso vive pero **no abre ventana**: se queda colgado sin escribir una línea de log |
| **Apple GPTK 3.0** | **Funciona entero** |

DXMT sí implementa geometry shaders (`d3d11_pipeline_gs.cpp`); lo que le falta es el staging.
DXVK sí acepta el staging; lo que le falta, sobre MoltenVK, son los geometry shaders. D3DMetal 3.0
tiene ambos.

## Corrección

`PixARK.exe` se enruta al componente **Apple GPTK 3.0** por su basename exacto, con el mismo
contrato indexado que ya usan Grim Dawn, DragonSword, Dragon's Dogma 2 y FINAL FANTASY TACTICS:

- `Scripts/regression-engine.sh` publica `REGRESSION_EXTERNAL_D3DMETAL_ROUTE_*` para `PixARK.exe`
  sólo si el componente 3.0 acredita su verificación.
- `GameRuntimeProfileCatalog` fija la identidad compilada
  `pixark.apple-gptk-3.0-portable` (revisión 1, App ID 593600).

**No se toca DXMT, ni su PIN, ni el baseline.** Cualquier otro proceso —la tienda de Steam
incluida— sigue exactamente en DXMT. El perfil se activa por proceso, nunca globalmente.

## Por qué no se corrigió DXMT

Sería la corrección general: `UpdateTexture` sobre staging es ~20 líneas (escribir en el buffer
mapeado del recurso staging, sin GPU). Se dejó fuera de forma deliberada y consciente:

1. Reconstruir DXMT exige LLVM x86_64 y un árbol de Wine compilado que este checkout no conserva.
2. Sustituir `d3d11.dll` rompe el PIN **DXMT v0.72 + parche cross-process**, lo que obliga a la
   matriz completa de validación gráfica sobre un artefacto no reproducible aquí.
3. Las fuentes de DXMT disponibles (`work/gamesir-labs-*/dxmt`) son de otro laboratorio y **no
   están acreditadas como la v0.72 publicada**: compilar de ahí no sería una variable, sería un
   cambio de generación entera.

Queda anotado como deuda con causa raíz identificada y sitio exacto:
`src/d3d11/d3d11_context_impl.cpp`, rama `GetStagingResource` de `UpdateTexture`. Cuando se
regenere el toolchain de DXMT, ese arreglo retira la necesidad del perfil.

## Validación

- Preflight y descarte ambiental previos; sesión Wine limpia y Steam recién arrancado.
- Menú principal, configuración de partida, creación de mapa, creación de personaje y **juego en
  el mundo**: terreno voxel, vegetación, fauna, HUD, estructura Tek y ciclo de día (el reloj
  avanza de 08:40 a 08:59 con el personaje en movimiento).
- Cero `err:` de la capa gráfica en toda la sesión; CPU de juego sostenida.
- Capturas miradas en cada paso.
