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

1. **Enshrouded avanza mucho más, pero todavía no arranca. La cadena de bloqueos está medida.**

   Primero, una corrección: hubo dos diagnósticos intermedios equivocados —«muere sin dejar
   rastro» y «bucle infinito que nunca lanza»— y los dos eran **artefactos de builds
   inconsistentes**. MoltenVK aquí enlaza un `libSPIRVCross.a` prefabricado que vive en
   `External/build/Release` y dentro de `SPIRVCross.xcframework`; reconstruir solo el conversor o
   solo el dylib mezcla dos versiones distintas y produce síntomas que no son reales. **Se
   construye con `MoltenVKPackaging.xcodeproj`, esquema «MoltenVK Package (macOS only)»**, y si se
   toca SPIRV-Cross hay que rehacer también su `.a` y la slice del xcframework.

   Con un build coherente, la cadena real es esta:

   **Bloqueo 1 — `drawIndirectCount` (resuelto).** Implementado; el juego acepta la GPU.

   **Bloqueo 2 — un shader de cómputo no convergía (resuelto).**
   `VolumetricFog3ViewVolumeIntegrate` fallaba con:

   ```text
   [mvk-error] SPIR-V to MSL conversion error: Maximum compilation loops detected and no forward
               progress was made. Must be a SPIRV-Cross bug!
   ```

   Instrumentando `Compiler::force_recompile()` con `backtrace`, el causante dominante es
   `CompilerGLSL::track_expression_read()` a través de `to_expression()`: cada pasada fuerza
   temporales nuevos y SPIRV-Cross agota su tope de **3** pasadas de emisión. Ese tope es una
   opción documentada —«Debug option, can be increased in an attempt to workaround SPIRV-Cross
   bugs temporarily»—, así que se sube a 32 en `SPIRVToMSLConverter::convert`. Con eso el shader
   converge, los 70 shaders del arranque compilan y **no queda ni un solo bucle agotado**.

   **Bloqueo 3 — `gl_DrawID` (abierto).** El juego pasa a fallar en pipelines gráficas
   —`BillboardModelChunk_*`, `Terrain_Visibility_Chunklets`— con:

   ```text
   [mvk-error] SPIR-V to MSL conversion error: DrawIndex is not supported in MSL.
   ```

   Es el builtin `BuiltInDrawIndex` de SPIR-V. Metal no lo expone, y SPIRV-Cross lo rechaza en
   tres sitios de `spirv_msl.cpp`. **El juego lo usa precisamente porque ahora tiene
   `drawIndirectCount`**: dibuja en lotes y necesita saber qué draw es cada uno.

2. **Publicar `libMoltenVK.dylib` obliga a revalidar toda la fila D3D9 de la matriz**, y no hay
   ningún juego D3D9 puro instalado con el que hacerlo: Sonic Adventure 2 va por `wined3d` desde
   1.12.7 y el resto son D3D11/D3D12. Sustituir el traductor de shaders de todos los juegos D3D9
   sin una sola prueba D3D9 real, y sin que arregle nada visible hoy, es riesgo sin beneficio.

El binario publicado se restauró y el estado instalado vuelve a verificar como 1.12.7 (45).

## Qué haría falta para cerrarlo

1. **Implementar `gl_DrawID` en el backend MSL.** Es abordable porque en la ruta indirecta el
   índice del draw **se conoce al codificar**: MoltenVK ya encodea un draw de Metal por cada draw
   de Vulkan, así que basta con pasarlo. El diseño sería:
   - SPIRV-Cross: declarar un buffer implícito —al estilo del `spvIndirectParams` que ya existe
     para teselación— y emitir `BuiltInDrawIndex` como lectura de él, en lugar de los tres
     `SPIRV_CROSS_THROW` de `spirv_msl.cpp`; y reportarlo en los resultados de conversión.
   - MoltenVK: reservar el índice de buffer implícito, propagar `needsDrawIndexBuffer` y escribir
     el índice antes de cada draw en los cuatro caminos indirectos —`MVKCmdDrawIndirect`,
     `MVKCmdDrawIndexedIndirect` y sus variantes con contador—.
   No es un parche pequeño: toca el manejo de builtins de SPIRV-Cross, que afecta a **todos** los
   shaders de **todos** los juegos. Va con su propia validación.
2. Comprobar si detrás de `gl_DrawID` aparece un cuarto bloqueo. El juego usa un renderizador con
   muchas características modernas y la cadena podría no terminar ahí.
3. Instalar un juego D3D9 puro para poder acreditar la fila D3D9 de la matriz con el MoltenVK nuevo.
4. Solo entonces, cortar una release con él.

## Lo que no se hace

Forzar el flag sin la implementación. Ya está dicho en `AGENTS.md`: el juego pasaría su
comprobación y no pintaría la geometría indirecta. Un fallo silencioso es peor que un error claro.
