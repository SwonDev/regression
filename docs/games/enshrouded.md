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

## Por qué no se publica

Dos motivos, y el primero es el que manda.

### 1. MoltenVK aquí es el fork de CodeWeavers, y su SPIRV-Cross no está en el tar

El `MoltenVK` de `sources-26.3.0` **usa** campos que el SPIRV-Cross oficial no tiene:
`for_mesh_pipeline`, `input_primitive_type`, `add_texture_buffer_offsets`,
`texture_offset_buffer_index` y un `MSLShaderInterfaceVariable` extendido con
`binding`, `offset`, `stride` y `normalized`. Están comprobados uno a uno: MoltenVK los referencia.

En el árbol, `External/SPIRV-Cross` es el **upstream oficial** con esos campos añadidos a mano como
*stubs* para que compile. Es decir: MoltenVK los rellena y SPIRV-Cross los **ignora en silencio**.
Compilar y publicar ese binario pondría a **todos** los juegos D3D9 —que van por DXVK y por tanto
por MoltenVK— sobre un traductor de shaders que descarta parámetros de vertex input y de pipeline
sin decir nada. Eso es exactamente el fallo silencioso que este proyecto no produce.

Publicarlo exigiría el SPIRV-Cross del fork de CodeWeavers, que no viaja en el tar FOSS.

### 2. Aun así, el juego topa después con otra cosa

Con la característica ya aceptada, Enshrouded falla más adelante compilando un shader de cómputo:

```text
[graphics] vkCreateComputePipelines of pipeline 'VolumetricFog3ViewVolumeIntegrate' failed
           with error 'VK_ERROR_INVALID_SHADER_NV'
[X] Error compiling gpc pipeline 1/16
```

Y el error real de SPIRV-Cross, con `MVK_CONFIG_LOG_LEVEL=4`:

```text
error: Maximum compilation loops detected and no forward progress was made. Must be a SPIRV-Cross bug!
```

Es un defecto del traductor con ese shader concreto, no una característica que falte. El
SPIRV-Cross del árbol es de **julio de 2024** (`68d4011`) y upstream lleva 449 commits por delante,
pero actualizarlo choca de nuevo con el punto 1: los stubs son precisamente lo que habría que
rebasar sobre la revisión nueva.

## Qué haría falta para cerrarlo

En este orden, y ninguno es un atajo:

1. Conseguir el SPIRV-Cross que corresponde a este MoltenVK —el del fork— o portar los campos que
   MoltenVK usa a una revisión reciente del oficial, implementándolos de verdad en vez de stubs.
2. Reconstruir MoltenVK con el parche de `drawIndirectCount` sobre esa base.
3. Comprobar si el shader `VolumetricFog3ViewVolumeIntegrate` ya traduce; si no, aislar el
   constructo que hace bucle en `CompilerGLSL::compile()` y corregirlo.
4. Revalidar **toda** la fila D3D9 de la matriz, porque MoltenVK sirve a DXVK: sustituirlo afecta
   a cualquier juego D3D9, no solo a este.

## Lo que no se hace

Forzar el flag sin la implementación. Ya está dicho en `AGENTS.md`: el juego pasaría su
comprobación y no pintaría la geometría indirecta. Un fallo silencioso es peor que un error claro.
