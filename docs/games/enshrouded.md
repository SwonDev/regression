# Enshrouded — expediente de compatibilidad

## Estado

- **Steam App ID:** `1203620`
- **Ejecutable:** `Enshrouded/enshrouded.exe`
- **Tecnología:** **Vulkan puro** (no llama a Direct3D en ningún punto)
- **Perfil compilado:** **ninguno, y es deliberado.** Las cinco correcciones son del traductor
  Vulkan→Metal y benefician a cualquier juego que use las mismas funciones.
- **Estado:** **no se publica todavía, pero llegó a jugarse.** Con los tres parches puestos, el juego
  arranca, carga la partida y muestra mundo, HUD, misiones e inventario. Lo que impide publicarlo
  es un quinto bloqueo, medido y **no introducido por estos parches**: el juego lee un descriptor
  set sin enlazar desde sus shaders de cómputo y eso falla la dirección en la GPU. Detalle abajo.

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

Detrás de ese primer rechazo había una **cadena de cinco bloqueos**, cada uno oculto por el
anterior. Ninguno se descubrió razonando: cada uno apareció al quitar el de delante.

## Bloqueo 1 — `drawIndirectCount` no estaba implementado

MoltenVK declaraba `_vulkan12FeaturesNoExt.drawIndirectCount = false` porque
`vkCmdDrawIndirectCount` y `vkCmdDrawIndexedIndirectCount` eran **puntos de entrada vacíos**.

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

Con eso el juego acepta la GPU:

```text
[graphics] Created Vulkan device!
[options] using default render settings for graphics device 'Apple M5 Pro'
```

## Bloqueo 2 — un shader de cómputo no convergía

`VolumetricFog3ViewVolumeIntegrate` fallaba con:

```text
[mvk-error] SPIR-V to MSL conversion error: Maximum compilation loops detected and no forward
            progress was made. Must be a SPIRV-Cross bug!
```

Instrumentando `Compiler::force_recompile()` con `backtrace`, el causante dominante es
`CompilerGLSL::track_expression_read()` a través de `to_expression()`: cada pasada fuerza
temporales nuevos y SPIRV-Cross agota su tope de **3** pasadas de emisión. Ese tope es una opción
documentada —«Debug option, can be increased in an attempt to workaround SPIRV-Cross bugs
temporarily»—, así que se sube a 32 en `SPIRVToMSLConverter::convert`. Con eso el shader converge,
los 70 shaders del arranque compilan y **no queda ni un solo bucle agotado**.

## Bloqueo 3 — `gl_DrawID` no existía en el backend MSL

`patches/moltenvk-26.3.0-draw-index-builtin.patch`.

El juego pasa a fallar en pipelines gráficas con:

```text
[mvk-error] SPIR-V to MSL conversion error: DrawIndex is not supported in MSL.
```

Es el builtin `BuiltInDrawIndex` de SPIR-V, y **el juego lo usa precisamente porque ahora tiene
`drawIndirectCount`**: dibuja en lotes y necesita saber qué draw es cada uno. Metal no lo expone y
SPIRV-Cross lo rechazaba en tres sitios de `spirv_msl.cpp`.

Se implementa como buffer implícito, al estilo del `spvIndirectParams` que ya existía para
teselación:

- **SPIRV-Cross** declara `spvDrawIndex` con `build_constant_uint_array_pointer()` cuando el
  builtin está activo, y emite las lecturas como `spvDrawIndex[0]`.
- **MoltenVK** reserva el índice de buffer implícito, propaga `needsDrawIndexBuffer` desde el
  conversor hasta `MVKGraphicsPipeline`, y escribe el índice con `setVertexBytes` antes de cada
  draw de los bucles de `MVKCmdDraw`.

**El detalle que costó dos iteraciones**: no basta con emitir la lectura. `BuiltInDrawIndex` seguía
entrando además por el camino normal de builtins del entry point, y Metal recibía esto:

```text
constant uint* spvDrawIndex [[buffer(22)]],   ← el buffer implícito, correcto
…
uint spvDrawIndex[0] [[spvDrawIndex]]          ← el builtin, emitido ADEMÁS como argumento
```

con dos errores encadenados: `redefinition of parameter 'spvDrawIndex'` y `zero-length arrays are
not permitted in C++`. La corrección es declararlo **no directo** en `is_direct_input_builtin()`,
que es exactamente donde ya está `BuiltInViewIndex` por el mismo motivo.

## Bloqueo 4 — `VK_IMAGE_CREATE_BLOCK_TEXEL_VIEW_COMPATIBLE_BIT`

`patches/moltenvk-26.3.0-block-texel-view.patch`.

El juego arrancaba, abría ventana y moría con un diálogo que **engaña**:

```text
The graphics memory is too small.
```

No falta memoria: el heap que reporta MoltenVK son **25,7 GB**. El juego traduce cualquier fallo de
`createTexture` a `Graphics_NotEnoughDeviceMemory`. La causa real está una línea antes en su log:

```text
[graphics] vkCreateImage failed with error 'VK_ERROR_FEATURE_NOT_PRESENT'
```

Y en el log de MoltenVK:

```text
[mvk-error] VK_ERROR_FEATURE_NOT_PRESENT: vkCreateImage() : Metal does not allow uncompressed
            views of compressed images.
```

Instrumentando el punto del rechazo, es **una sola imagen** en todo el arranque:

```text
fmt=BC5_UNORM  type=3D  extent=384x384x256  mips=1  layers=1  samples=1
tiling=OPTIMAL usage=SAMPLED|STORAGE  flags=MUTABLE_FORMAT|BLOCK_TEXEL_VIEW_COMPATIBLE|EXTENDED_USAGE
```

El volumen de terreno con normales comprimidas, escrito por cómputo a través de una vista sin
comprimir (`RG32_UINT`, 64 bits = un bloque BC5) y muestreado después como BC5.

**Antes de escribir nada se midieron las dos vías alternativas, y las dos están descartadas con
evidencia, no con argumentos:**

1. **Vista de Metal.** `newTextureViewWithPixelFormat:` de BC5 a `RG32Uint` no devuelve error: lanza
   una **aserción dura** que aborta el proceso (`source texture pixelFormat
   (MTLPixelFormatBC5_RGUnorm) not compatible with texture view pixelFormat (MTLPixelFormatRG32Uint)`).
   El mensaje de MoltenVK era correcto, no conservador.
2. **Aliasing en un `MTLHeap` de tipo `placement`.** Metal *sí* deja crear las dos texturas en el
   mismo offset. Pero no comparten disposición: para un mismo contenido de 16 384 B, la BC5 pide
   32 768 B de heap y la `RG32Uint` 17 408 B. Escribiendo un patrón conocido por la vista y leyendo
   la comprimida por blit, **15 440 de 16 384 bytes salen distintos**. El aliasing no preserva el
   mapeo que Vulkan define.

Así que la vista tiene **almacenamiento propio**, y la imagen la reconcilia en sus barreras: la
copia va por un buffer temporal, porque `copyFromTexture:toBuffer:` y `copyFromBuffer:toTexture:`
sí definen la disposición como bloques lineales en orden raster —justo el mapeo que Vulkan exige—.
Las escrituras de shader viajan de la vista a la imagen; las de transferencia, al revés.

`REGRESSION_MVK_BLOCK_TEXEL_VIEW=0` restaura el rechazo, para poder hacer A/B.

## Bloqueo 5 — lectura de un descriptor set sin enlazar (abierto)

Con los cuatro anteriores resueltos el juego llega al menú, carga la partida y se juega. Pero
termina cayendo con:

```text
[graphics] vkWaitForFences failed with error 'VK_ERROR_DEVICE_LOST'
```

y en el traductor:

```text
[mvk-error] VK_ERROR_OUT_OF_DEVICE_MEMORY: MTLCommandBuffer execution failed (code 3):
            Caused GPU Address Fault Error (kIOGPUCommandBufferCallbackErrorPageFault)
```

La validación de shaders de Metal (`MTL_SHADER_VALIDATION=1`) lo localiza sin ambigüedad:

```text
Invalid device load at offset 2116, executing kernel function: "cs_main"
buffer: Out of bounds of user address space, length:1, resident:Read Write
encoder: "vkCmdDispatch ComputeEncoder", dispatch: 12
```

y la capa de depuración de Metal nombra el hueco:

```text
Compute Function(cs_main): missing Buffer binding at index 4 for spvDescriptorSet4[0]
```

Un shader de cómputo **del juego** lee el argument buffer de un descriptor set que no está
enlazado. SPIRV-Cross lo declara como parámetro del entry point, MoltenVK no enlaza nada en esa
ranura, y en Metal eso no es memoria vacía: **no hay memoria**, así que la primera lectura falla la
dirección. Un controlador Vulkan real devuelve basura y el juego sigue.

**No lo introducen estos parches, y está comprobado**: el binario anterior a todos ellos produce
**861 cargas inválidas idénticas** bajo la misma validación. Lo que cambia es si la ejecución llega
a dereferenciar lo bastante lejos como para reventar.

### Lo que se descartó, con evidencia

| Hipótesis | Cómo se descartó |
|---|---|
| El buffer de `gl_DrawID` | Emitiendo `gl_DrawID` como constante cero, **sin buffer**: sigue fallando |
| La sincronización del volumen BC5 | `REGRESSION_MVK_BLOCK_TEXEL_SYNC=0`: sigue fallando |
| La emulación de bloques en general | La imagen se crea en el segundo 51 y el fallo llega en el 8 |
| Offset no alineado del buffer temporal | Buffer dedicado (offset cero): sigue fallando |
| `spvDrawIndex` sin enlazar en teselación/malla | Se enlaza ya en las tres etapas por el estado del encoder: sigue fallando |
| Los avisos `missing Buffer binding` como causa | Salen **4 322 veces** en un binario que no falla |
| Desactivar los argument buffers de Metal | Quita el fallo, **pero** las pipelines *bindless* no compilan y el juego muere al arrancar |
| Rellenar con memoria cero los sets sin enlazar | Sin efecto; se revirtió por no estar verificado |
| Enlazar siempre el argument buffer del set enlazado | Sin efecto; se revirtió por lo mismo |
| Que un set sin enlazar baste para provocarlo | **Reproductor propio** (`tools/research/moltenvk-probe/`): un shader de cómputo que declara y lee un `set = 4` que la aplicación no enlaza **no falla**. Los avisos `missing Buffer binding` son benignos |
| Que subir `force_recompile_max_debug_iterations` cambiara un shader que ya funcionaba | Imposible por construcción: ese tope sólo **lanza** cuando se supera, así que un shader que convergía en ≤3 pasadas emite el mismo MSL con el tope en 32. Subirlo sólo rescata shaders que antes fallaban |
| Que MoltenVK dimensione mal un buffer enlazado | Reproductor: `length()` de un array de tamaño dinámico devuelve **1024** con `VK_WHOLE_SIZE` y **256** con un rango de 1024 B. El buffer auxiliar de tamaños es correcto |
| Que un array *bindless* indexado fuera de los descriptores reservados lo provoque | Reproductor: con `VARIABLE_DESCRIPTOR_COUNT` y `PARTIALLY_BOUND`, reservando 0 ó 4 descriptores e indexando el 264 o el 1023, **no falla**. MoltenVK dimensiona por la cuenta declarada, no por la reservada |
| Que el buffer implícito de tamaños se enlace vacío al cambiar de pipeline | Reproductor: tres dispatches con un cambio de pipeline en medio y sin re-enlazar los descriptor sets dan `length()` = 1024 en los tres |
| Que el array *bindless* de **texturas** fuera de rango lo provoque | Reproductor: array de texturas 3D con `PARTIALLY_BOUND`, cuatro escritas y muestreando la 3000, **no falla**. Es la forma que tienen de verdad los shaders del juego: su firma real declara `array<texture3d<float>, 32768>` |
| Que el orden de vinculación lo provoque | Reproductor: enlazar los descriptor sets **antes** de la pipeline no falla |
| Que un layout de pipeline compatible pero distinto invalide el set | Reproductor: enlazar los sets con un layout y la pipeline con otro compatible no falla |

### El mecanismo, ya identificado

Los shaders del juego se pudieron **extraer y convertir sin ejecutarlo**: su SPIR-V viaja sin
comprimir dentro de los `enshrouded_0NN.dat` y se localiza por su número mágico
(`tools/research/shader-extract/`). De ahí salieron **6 050 módulos**, 5 824 de cómputo, convertidos
a MSL con las mismas opciones que usa el runtime (`-mab`, argument buffers) para que la numeración
de líneas coincida con la que reporta la validación.

Con eso, la línea 501 que señala el informe deja de ser un misterio. Tiene esta forma:

```metal
_363._m1._m0[1] = (*spvDescriptorSet1.m_8)._m0[_262]._m1._m0[1];
```

donde `m_8` se declara dentro del propio argument buffer:

```metal
const device _29* m_8 [[id(3)]];
```

Es decir: **el shader lee un puntero guardado dentro del argument buffer y lo desreferencia**, con
un índice dinámico. Si ese argument buffer no está enlazado, el puntero sale nulo y desreferenciar
cero más un desplazamiento da exactamente lo que dice el informe —«Out of bounds of user address
space, length:1»—. No hay nada que Metal pueda acotar: es una dirección cruda.

Eso explica de paso por qué **rellenar la ranura con memoria cero no sirvió**: ceros son un puntero
nulo, y el fallo es el mismo. La corrección tiene que hacer que ese argument buffer esté enlazado
con su contenido real, no con relleno.

Lo que sigue sin reproducirse en el arnés es **la condición que deja ese set sin enlazar**: ni el
orden de vinculación (sets antes que la pipeline), ni un layout compatible pero distinto, ni un set
sencillamente no enlazado bastan por sí solos.

### Aviso de método

**La validación de GPU de Metal tapa este fallo**: enlaza recursos de relleno en las ranuras
vacías, así que con `MTL_DEBUG_LAYER=1` o `MTL_SHADER_VALIDATION=1` el juego no cae. Por eso hubo
una sesión en la que pareció estable: no lo era.

Del mismo modo, **un binario compilado de forma incremental llegó a jugarse cinco minutos** y uno
limpio de las **mismas fuentes —comprobadas byte a byte—** cae a los ocho segundos. No es una
diferencia de código: es una carrera cuya ventana depende de detalles del binario. El binario
"bueno" enseñaba las mismas 861 cargas inválidas.

## Cómo se reconstruye

```bash
bash build/build-moltenvk.sh
```

Extrae MoltenVK del tar FOSS oficial, aplica los tres parches en orden y compila. **No se compila
desde `sources-26.3.0/moltenvk` del checkout**: ese árbol lleva el SPIRV-Cross upstream en vez del
de CodeWeavers y produce un traductor que acepta los parámetros de MoltenVK y los ignora en
silencio. Se distingue con `grep -c for_mesh_pipeline External/SPIRV-Cross/spirv_msl.cpp`: el del
tar da **31**, el contaminado da **0**. El script lo comprueba y aborta si no cuadra.

Dos trampas del propio build, las dos fijadas en el script:

- **MoltenVK no compila SPIRV-Cross: lo copia** desde `${BUILT_PRODUCTS_DIR}/libSPIRVCross.a`. Si
  cada proyecto usa su propio `-derivedDataPath`, el paquete enlaza un `.a` viejo y los cambios del
  traductor no llegan al dylib **sin dar ningún error**.
- Xcode **no rastrea ese `.a` copiado como entrada**, así que un `.a` nuevo no basta para que
  re-enlace. Hay que retirar el `libMoltenVK.dylib` del directorio de productos para forzarlo.

## Pendiente antes de certificar

1. **Cerrar el bloqueo 5.** Nueve hipótesis descartadas, ocho de ellas sin tocar el juego, y el
   **mecanismo ya identificado** (arriba): un puntero nulo leído de un argument buffer sin enlazar.
   Lo que falta es la condición que lo deja sin enlazar. Lo que queda no se puede adivinar: hace falta **un dato concreto del juego**, y
   se obtiene con una sola ejecución.

   **El paso exacto que falta** es leer el MSL del shader que revienta. El informe de la validación
   da función, línea y columna —`cs_main`, `program_source:501:55`—, así que basta con volcar el MSL
   convertido y mirar esa línea:

   ```bash
   MVK_CONFIG_LOG_LEVEL=4 MTL_SHADER_VALIDATION=1 MTL_SHADER_VALIDATION_REPORT_TO_STDERR=1 \
       /Applications/Regression.app/Contents/MacOS/regression-engine > /tmp/ensh.log 2>&1 &
   regressionctl launch 1203620 --backend regression
   # después: localizar el cs_main cuyo program_source llega a la línea 501 y leerla
   ```

   Esa línea dice qué buffer se lee y con qué índice. Con eso, el patrón se reproduce en el arnés
   —`tools/research/moltenvk-probe/`, tres patrones ya cubiertos— y se corrige sin volver a
   arrancar el juego. Sin ese dato, cualquier corrección sería a ciegas, y ya se probaron dos así:
   ninguna sirvió y ambas se revirtieron.

2. **Medir el coste de la sincronización de bloques.** Cada barrera que publica escrituras de shader
   sobre esa imagen copia el volumen entero (≈18,9 MB) de ida y vuelta. Falta saber con qué
   frecuencia ocurre y si conviene acotarlo con una marca de «sucio».
3. **Matriz de validación completa**, incluida una fila D3D9 real: publicar `libMoltenVK.dylib`
   cambia el traductor de shaders de **todos** los juegos Vulkan y de la ruta DXVK.

Mientras tanto, **la app instalada lleva el `libMoltenVK.dylib` publicado de 1.12.7**, verificado con
`build/verify-public-installed-state.sh --release-1.12.7`. El experimental se reconstruye con un
comando (`bash build/build-moltenvk.sh`) y se instala copiándolo sobre esa ruta.

## Lo que no se hace

Forzar el flag sin la implementación. Ya está dicho en `AGENTS.md`: el juego pasaría su
comprobación y no pintaría la geometría indirecta. Un fallo silencioso es peor que un error claro.
