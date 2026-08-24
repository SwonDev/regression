# Enshrouded — expediente de compatibilidad

## Estado

- **Steam App ID:** `1203620`
- **Ejecutable:** `Enshrouded/enshrouded.exe`
- **Tecnología:** **Vulkan puro** (no llama a Direct3D en ningún punto)
- **Estado:** **no puede funcionar hoy.** Exige la característica Vulkan 1.2 `drawIndirectCount`,
  que MoltenVK expone como stub vacío. No se falsea.

## Síntoma

Diálogo nativo de Wine al lanzar:

```text
Error
No compatible graphics device found.
```

## Causa raíz — medida en el log del propio juego

El juego **sí** encuentra y enumera el dispositivo Vulkan sin problema:

```text
[graphics] Vulkan device 0 (Apple M5 Pro):
[graphics] - api version   : 1.2.290
[graphics] - device type   : integrated gpu
[graphics] Finished device enumeration successfully
```

Y lo descarta después, por una sola razón:

```text
[graphics] skipping device because 'drawIndirectCount' is not supported!
[graphics] No usable Vulkan device found!
[graphics] Could not create vulkan device! error=no compatible device found
```

`enshrouded.log`, en la carpeta del juego, líneas 529-531.

## Por qué MoltenVK dice que no

En `MoltenVK/MoltenVK/GPUObjects/MVKDevice.mm` la característica está fijada a falso:

```objc
_vulkan12FeaturesNoExt.drawIndirectCount = false;
```

Y no es una omisión conservadora: los puntos de entrada existen, están registrados… y **están
vacíos**. En `MoltenVK/MoltenVK/Vulkan/vulkan.mm`:

```objc
MVK_PUBLIC_VULKAN_SYMBOL void vkCmdDrawIndirectCount(...) {
    MVKTraceVulkanCallStart();
    MVKTraceVulkanCallEnd();
}
```

No dibujan nada. MoltenVK declara la verdad.

## Lo que NO se va a hacer

Activar el flag a mano. El juego arrancaría —pasaría su comprobación— y **no pintaría** la
geometría que dibuja por indirect-count, que en un motor moderno es prácticamente todo. Un juego
que «arranca» y no renderiza es peor que un rechazo honesto, y además ocultaría la causa.

## Estado upstream y línea de trabajo real

El issue [KhronosGroup/MoltenVK#168](https://github.com/KhronosGroup/MoltenVK/issues/168) sigue
**abierto desde 2018**, etiquetado «Metal improvement required». No hay implementación parcial ni
workaround publicado.

Conviene registrar una matización: cuando se abrió el issue, Metal no tenía la primitiva. Hoy sí
—`MTLIndirectCommandBuffer` con `executeCommandsInBuffer:indirectBuffer:offset:` permite que sea
la GPU quien fije el número de comandos a ejecutar, que es exactamente lo que pide
`drawIndirectCount`—. Implementarlo es, por tanto, **posible**, pero significa mantener un fork de
MoltenVK con trabajo serio de Metal y SPIR-V. Es una línea de investigación, no una corrección de
esta sesión, y una implementación a medias sería justo el fallo silencioso que este proyecto evita.

## Corrección de un diagnóstico anterior

La primera versión de este expediente atribuía el fallo a las extensiones de trazado de rayos
(`VK_KHR_ray_tracing_pipeline`, `VK_KHR_acceleration_structure`) porque el binario las nombra.
Era **falso**: el juego las lista pero no las exige, y su propio log señala `drawIndirectCount`.
La lección es la de siempre — las cadenas de un binario sugieren, el log del juego acredita.

## Por qué no se enruta a D3DMetal

D3DMetal implementa Direct3D, no Vulkan. Enshrouded no llama a Direct3D, así que una ruta a GPTK
no cambiaría nada. El detector de rutas D3D12 lo excluye correctamente: no declara `d3d12.dll`
ni estática ni diferidamente.
