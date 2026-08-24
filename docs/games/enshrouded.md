# Enshrouded — expediente de compatibilidad

## Estado

- **Steam App ID:** `1203620`
- **Ejecutable:** `Enshrouded/enshrouded.exe`
- **Tecnología:** **Vulkan puro** (no usa Direct3D en absoluto)
- **Estado:** **no puede funcionar hoy.** Requiere extensiones Vulkan de trazado de rayos por
  hardware que MoltenVK no implementa. No se elude ni se presenta como compatible.

## Síntoma

Al lanzarlo aparece un diálogo nativo de Wine:

```text
Error
No compatible graphics device found.
```

El proceso queda vivo esperando el `OK`, sin ventana de juego.

## Causa raíz

`enshrouded.exe` no importa **ninguna** DLL de Direct3D, ni estática ni diferida: nombra
`vulkan-1.dll` y resuelve todo por Vulkan. Entre las extensiones que declara están:

```text
VK_KHR_acceleration_structure
VK_KHR_ray_tracing_pipeline
VK_KHR_buffer_device_address
VK_KHR_dynamic_rendering
```

MoltenVK 1.2.10 —la implementación de Vulkan sobre Metal que usa el runtime— expone **111
extensiones** y **ninguna** de trazado de rayos. Se comprobó contra la lista que el propio
runtime imprime al arrancar: cero coincidencias para `ray_tracing` o `acceleration_structure`.

El mensaje del juego es, por tanto, **correcto**: en este sistema no existe un dispositivo Vulkan
que cumpla lo que pide.

## Por qué no se enruta a D3DMetal

D3DMetal implementa Direct3D, no Vulkan. Enshrouded no llama a Direct3D en ningún punto, así que
una ruta a GPTK no cambiaría nada. El detector de rutas D3D12 lo excluye correctamente: no
declara `d3d12.dll` ni estática ni diferidamente.

## Qué haría falta

Que MoltenVK implemente `VK_KHR_acceleration_structure` y `VK_KHR_ray_tracing_pipeline` sobre
Metal Ray Tracing, o que el juego ofrezca una ruta sin trazado de rayos. Ninguna de las dos está
en nuestra mano. Se revisa cuando MoltenVK publique soporte; hasta entonces el título queda en la
misma categoría honesta que los bloqueados por anticheat: **incompatible y declarado como tal**.
