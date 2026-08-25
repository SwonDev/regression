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

1. **Enshrouded todavía no arranca con él, y ya se sabe exactamente dónde se queda.**

   Instrumentando MoltenVK paso a paso —creación de pipelines, `getMTLFunction`, y la conversión
   SPIR-V → MSL— el balance de una ejecución es este:

   | Marca | Veces |
   |---|---|
   | `vkCreateComputePipelines` entra | 12 |
   | Constructor `MVKComputePipeline` | 12 |
   | Llega a `getMTLFunction` | 12 |
   | Llega a `MVKShaderModule::getMTLFunction` | 12 |
   | Llega a `pMSLCompiler->compile()` | **3** |
   | **Vuelve de `compile()`** | **0** |
   | `vkCreateComputePipelines` retorna | **0** |

   Es decir: tres hilos entran en el compilador de SPIRV-Cross y **ninguno sale**; los otros nueve
   se quedan esperando detrás. El juego escribe `start creation step WaitForGpcLoaderReady`, su
   cargador de pipelines nunca queda listo y el proceso termina.

   **No es una excepción no capturada**: `libMoltenVKShaderConverter.a` se compila con excepciones
   —255 símbolos `__gxx_personality`— y el `catch (CompilerError&)` de `SPIRVToMSLConverter::convert`
   está instrumentado y no se dispara nunca.

   **Es un bucle sin salida en el backend MSL de SPIRV-Cross.** `CompilerGLSL::reset()` tiene una
   salvaguarda —`Maximum compilation loops detected and no forward progress was made`— pero **solo
   salta si el compilador no declara progreso**:

   ```cpp
   if (iteration_count >= options.force_recompile_max_debug_iterations && !is_force_recompile_forward_progress)
       SPIRV_CROSS_THROW("Maximum compilation loops detected ...");
   ```

   El propio comentario del código lo anticipa: «In buggy situations we will loop forever, or loop
   for an unbounded number of iterations». Con uno de los shaders de cómputo de Enshrouded se da
   justo ese caso: cada vuelta pide recompilar declarando progreso, así que la salvaguarda nunca
   salta y `compile()` gira indefinidamente.

   Con el SPIRV-Cross contaminado del árbol de trabajo **sí** saltaba —de ahí el
   `VK_ERROR_INVALID_SHADER_NV` en `VolumetricFog3ViewVolumeIntegrate` que se vio al principio—.
   Con el bueno, no salta y se cuelga. Es un defecto de SPIRV-Cross, no de este proyecto.

2. **Publicar `libMoltenVK.dylib` obliga a revalidar toda la fila D3D9 de la matriz**, y no hay
   ningún juego D3D9 puro instalado con el que hacerlo: Sonic Adventure 2 va por `wined3d` desde
   1.12.7 y el resto son D3D11/D3D12. Sustituir el traductor de shaders de todos los juegos D3D9
   sin una sola prueba D3D9 real, y sin que arregle nada visible hoy, es riesgo sin beneficio.

El binario publicado se restauró y el estado instalado vuelve a verificar como 1.12.7 (45).

## Qué haría falta para cerrarlo

1. **Encontrar qué construcción del shader hace que SPIRV-Cross pida recompilar sin parar.** La
   vía es instrumentar `CompilerGLSL::force_recompile()` para volcar quién la llama en cada vuelta
   y con qué motivo; el bucle está en `CompilerGLSL::compile()` y la cuenta en
   `CompilerGLSL::reset(iteration_count)`.
2. Corregirlo en SPIRV-Cross —o, como mínimo, hacer que la salvaguarda salte también con progreso
   declarado, para que un shader así **falle limpio** en vez de colgar al compilador de pipelines:
   un error es peor que un cuelgue solo si oculta información, y aquí la ocultaría menos.
3. Instalar un juego D3D9 puro para poder acreditar la fila D3D9 de la matriz con el MoltenVK nuevo.
4. Solo entonces, cortar una release con él.

## Lo que no se hace

Forzar el flag sin la implementación. Ya está dicho en `AGENTS.md`: el juego pasaría su
comprobación y no pintaría la geometría indirecta. Un fallo silencioso es peor que un error claro.
