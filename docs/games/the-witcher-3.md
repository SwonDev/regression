# The Witcher 3: Wild Hunt — expediente de compatibilidad

## Estado

- **Steam App ID:** `292030`
- **Cadena de arranque:** Steam → `REDprelauncher.exe` (32 bits) → interfaz `REDlauncher.exe`
  (32 bits, Qt WebEngine) → `bin/x64_dx12/witcher3.exe` (64 bits)
- **Tecnología:** REDengine, D3D12 (edición Next-Gen). También trae un binario D3D11 en `bin/x64`.
- **Perfil compilado:** `witcher3.exe` enrutado a **Apple GPTK 4.0b2 (D3DMetal)** + argumento
  `--launcher-skip` añadido a `REDprelauncher.exe`
- **Estado:** **funcionando.** Corregido el 2026-08-25.

## Síntoma

El juego no arrancaba. Aparecía el diálogo «Program Error» de Wine —`REDlauncher.exe` ha
encontrado un problema grave— y la cadena se quedaba ahí.

## Causa raíz

Son **tres** fallos encadenados, y ninguno es del juego.

### 1. El prelanzador es de 32 bits y DXVK no tiene Vulkan ahí

`REDlauncher.exe` es Qt y usa D3D9. Su log lo dice sin ambigüedad:

```text
info:  Game: REDlauncher.exe
info:  DXVK: v1.10.3
info:  Required Vulkan extension VK_KHR_surface not supported
terminate called after throwing an instance of 'dxvk::DxvkError'
[Fatal] Crash signal invoked, 22.
```

MoltenVK solo existe en 64 bits. Un proceso i386 que cargue el `d3d9` de DXVK no llega a crear
instancia Vulkan, DXVK lanza `dxvk::DxvkError`, nadie la captura y `terminate()` mata el proceso.
**El fallo es de la arquitectura, no del juego**, así que la corrección es general: cualquier
proceso i386 prefiere el `d3d9` builtin de Wine, que sí funciona ahí. No hay lista de títulos.

### 2. La interfaz del prelanzador es Chromium y revienta igual

Resuelto lo anterior, el crash cambia de sitio: `QtWebEngineProcess.exe` —Chromium embebido— entra
en un bucle de `Unhandled division by zero at address 000000014000D0BC`. Es un componente del
proveedor y no lo arregla este runtime.

El propio prelanzador admite **`--launcher-skip`** —lo acredita su binario: `launcher-skip`,
`launcher_skipped`, `sendLauncherSkippedEvent`—, que es lo que hace un usuario que no quiere esa
interfaz. El loader lo añade a la línea de comandos de ese proceso exacto, reutilizando el mismo
mecanismo compilado que ya servía `-window-mode borderless`.

### 3. El prelanzador siempre arranca el binario D3D12

Con la interfaz omitida, lanza `bin\x64_dx12\witcher3.exe` —comprobado leyendo la ruta del proceso—
**aunque su configuración liste antes la entrada de DirectX 11**, y aunque se le pase
`--launcher-fallback`. Sin una ruta a D3DMetal, el juego responde:

> GPU does not meet minimal requirements. Support for DirectX 12 is required.

Se le asigna **Apple GPTK 4.0b2** por proceso exacto, igual que a Dragonkin, Borderlands 4 y
Titan Quest II. Con eso el juego arranca y renderiza.

## Lo que se descartó, con evidencia

| Hipótesis | Experimento | Resultado |
|---|---|---|
| Redirigir la imagen del prelanzador al juego | ruta de bootstrap `REDprelauncher.exe → bin/x64/witcher3.exe` | Steam falla con `AppError_46 "Request not supported" (0x32)`: **una redirección de imagen no puede cruzar arquitecturas** (prelanzador de 32 bits, juego de 64). El detector ahora lo comprueba antes de proponerla. |
| Reordenar `launcher-configuration.json` para que DirectX 11 vaya primero | edición con respaldo y relanzamiento | El prelanzador sigue eligiendo D3D12. La preferencia no es el orden del archivo. |
| `--launcher-fallback` | añadido junto a `--launcher-skip` | Sigue eligiendo D3D12. |
| Quitar `REDlauncher.exe` para que no haya interfaz que abrir | apartado temporalmente | El prelanzador ejecuta el **instalador** `setup_redlauncher.exe`. Peor. |

El binario D3D11 (`bin/x64/witcher3.exe`) funciona perfectamente si se ejecuta a mano, pero no hay
forma admitida de que el prelanzador lo elija, así que la corrección va por D3D12.

## Validación

Lanzado desde Regression por la ruta normal de Steam: el prelanzador se salta su interfaz, arranca
`bin\x64_dx12\witcher3.exe` y el juego reproduce la cinemática de introducción con subtítulos,
geometría, iluminación y HUD. D3DMetal reporta dos emulaciones esperadas —`EndQuery` tipo 2 y
buffers `R32G32B32` tipados— sin efecto visible.

## Reglas que salieron de aquí

- Un proceso de 32 bits no puede usar DXVK en este runtime; se le da el `d3d9` builtin.
- Una redirección de imagen no cruza arquitecturas: se comprueba **antes** de proponerla.
- El argumento compilado que se añade a una línea de comandos es una lista cerrada en el loader;
  no puede venir del entorno ni de la base de aprendizaje.
