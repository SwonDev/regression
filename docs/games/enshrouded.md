# Enshrouded — expediente de compatibilidad

## Estado

- **Steam App ID:** `1203620`
- **Ejecutable:** `Enshrouded/enshrouded.exe`
- **Tecnología:** **Vulkan puro** (no llama a Direct3D en ningún punto)
- **Estado:** **no funciona todavía, pero el motivo cambió.** El bloqueo que se documentaba —
  `drawIndirectCount` sin implementar— **está resuelto y demostrado**. Lo que impide publicarlo
  es otra cosa, y está medida más abajo.

## Síntoma original

Diálogo nativo de Wine al lanzar:

```text
Error
No compatible graphics device found.
```

El juego enumeraba el dispositivo sin problema y lo descartaba por una sola razón, en su propio
log (`enshrouded.log`):

```text
[graphics] skipping device because 'drawIndirectCount' is not supported!
[graphics] No usable Vulkan device found!
```

## Lo que se implementó, y funciona

MoltenVK declaraba `_vulkan12FeaturesNoExt.drawIndirectCount = false` porque
`vkCmdDrawIndirectCount` y `vkCmdDrawIndexedIndirectCount` eran **puntos de entrada vacíos**.

Se implementaron de verdad, contra las fuentes FOSS oficiales del tar:
`patches/moltenvk-26.3.0-draw-indirect-count.patch`.

La idea es la única que Metal admite. Metal no sabe variar el número de draws de un render
encoder, pero **un draw con cero vértices no dibuja nada**. Y el contador vive en la GPU: puede
escribirlo un dispatch del mismo command buffer, así que no se puede leer desde la CPU al grabar.
Así que se recorta en la GPU, justo antes de dibujar:

1. Un kernel nuevo (`cmdDrawIndirectClampCount` y su variante indexada) copia los argumentos de
   los draws cuyo índice está por debajo de `*countBuffer` y **anula el resto** poniendo su cuenta
   de vértices —o de índices— e instancias a cero.
2. Después se encodean `maxDrawCount` draws indirectos sobre ese buffer ya recortado, reutilizando
   la ruta de dibujo indirecto que MoltenVK ya tenía.

El patrón —conmutar a un encoder de cómputo en mitad de un draw y volver— no es invención: es
exactamente lo que `MVKCmdDrawIndirect::encodeIndexedIndirect` ya hacía para los abanicos de
triángulos.

**Resultado medido.** Con ese MoltenVK instalado, el log del juego pasa de descartar el
dispositivo a esto:

```text
[graphics] Created Vulkan device!
[graphics] Device supports BC texture compression!
[graphics] Supported vulkan device formats:
[options] using default render settings for graphics device 'Apple M5 Pro'
```

El juego acepta la GPU y avanza hasta compilar sus pipelines. El bloqueo documentado ya no existe.

## Por qué no se publica todavía

**Corrección de un diagnóstico anterior.** Se llegó a escribir aquí que el SPIRV-Cross que este
MoltenVK necesita «no viaja en el tar FOSS». **Es falso, y conviene que quede dicho.** El tar sí lo
trae: `sources/moltenvk/External/SPIRV-Cross` es la versión de CodeWeavers, con
`for_mesh_pipeline` (31 usos en `spirv_msl.cpp`), `input_primitive_type`,
`add_texture_buffer_offsets`, `texture_offset_buffer_index` y el `MSLShaderInterfaceVariable`
extendido con `binding`, `offset`, `stride` y `normalized`, **implementados de verdad**.

Lo que estaba contaminado era el **árbol de trabajo**: su `External/SPIRV-Cross` es el upstream
oficial con esos campos añadidos a mano como *stubs*, mil líneas más corto. Compilar MoltenVK desde
ahí produce un traductor que acepta esos parámetros y los ignora en silencio. Es exactamente el
mismo error que la regla del runtime de Wine ya prohíbe: **se compila desde el tar oficial, nunca
desde el árbol de trabajo tal como esté**.

Compilado desde el tar, con el SPIRV-Cross correcto y el parche encima, MoltenVK sale limpio.
Wayfinder y Redfall —los dos títulos instalados que tocan DXVK D3D9 al arrancar— siguen
funcionando con ese binario.

Aun así **no se publica**, por dos motivos:

1. **Enshrouded todavía no arranca con él, y no sé por qué.** Lo que sí está medido:

   - Acepta la GPU: `drawIndirectCount=VK_TRUE`, `maxDrawIndirectCount=1.073.741.824`,
     `Created Vulkan device!` con seis extensiones.
   - Inicializa todo lo demás sin una queja: caché de pipelines, sonido WASAPI, animación, P2P.
   - Crea su cola de compilación de pipelines con **14 hilos de trabajo**.
   - Escribe `[app] start creation step WaitForGpcLoaderReady` y **el proceso desaparece a los
     3 segundos** (Steam: `Game process removed`).

   Y lo que se descartó buscándolo:

   - **No es un crash**: no hay informe en `~/Library/Logs/DiagnosticReports`, ni minidump de
     breakpad en `Steam/dumps` (sí los hay de otros procesos esa misma noche, así que el
     mecanismo funciona).
   - **No es una excepción de Windows**: con `WINEDEBUG=+seh` las únicas `c0000005` del log
     pertenecen al dispositivo Vulkan 1.0 de Steam, no al 1.2 del juego.
   - **No es un error de MoltenVK**: su log llega hasta la creación del `VkDevice` del juego y no
     emite un solo `[mvk-error]` después. Con el build contaminado sí lo emitía —
     `VK_ERROR_INVALID_SHADER_NV` en `VolumetricFog3ViewVolumeIntegrate`—, así que el canal
     funciona y aquí simplemente no hay error que contar.
   - **No es falta de tiempo**: el proceso no está compilando, ha terminado.

   Sale limpio, sin decir nada, justo al empezar a cargar pipelines. Sin un rastro nuevo, seguir
   probando sería dar palos de ciego; hace falta instrumentar la creación de pipelines dentro de
   MoltenVK y ver qué hilo se va.

2. **Publicar `libMoltenVK.dylib` obliga a revalidar toda la fila D3D9 de la matriz**, y no hay
   ningún juego D3D9 puro instalado con el que hacerlo: Sonic Adventure 2 va por `wined3d` desde
   1.12.7 y el resto son D3D11/D3D12. Sustituir el traductor de shaders de todos los juegos D3D9
   sin una sola prueba D3D9 real, y sin que arregle nada visible hoy, es riesgo sin beneficio.

El binario publicado se restauró y el estado instalado vuelve a verificar como 1.12.7 (45).

## Qué haría falta para cerrarlo

1. Averiguar por qué el proceso muere en `WaitForGpcLoaderReady` sin dejar rastro. La vía es
   instrumentar la compilación de pipelines de MoltenVK, no el juego.
2. Instalar un juego D3D9 puro para poder acreditar la fila D3D9 de la matriz con el MoltenVK nuevo.
3. Solo entonces, cortar una release con él.

## Lo que no se hace

Forzar el flag sin la implementación. Ya está dicho en `AGENTS.md`: el juego pasaría su
comprobación y no pintaría la geometría indirecta. Un fallo silencioso es peor que un error claro.
