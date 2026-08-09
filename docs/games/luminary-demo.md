# Luminary Demo

## Estado blindado

- **Steam App ID:** `4059020`
- **Motor:** Unreal Engine `5.7.4`
- **Backend certificado:** Regression
- **Run perfecto:** `EE1C5A66-1AAA-4594-B30D-1E8ECFA5A27B`
- **Huella de configuración y motor:** `fa3cb7e58e5fc638ad9e4d1e20161a3ecf07ba2e1acd05db280f1a3af2d4a3b0`

El usuario confirmó que el juego funciona a la perfección. La ejecución exacta cubrió título,
menú, carga de nivel, gameplay, movimiento y cierre limpio. No apareció un crash nuevo después
de más de ocho minutos de sesión.

## Dos fallos independientes

### Bootstrap Unreal

`LuminaryDemo.exe` mostraba primero un falso error de Microsoft Visual C++ y Steam llegó a
registrar `Module not found (0x7E)`. Regression ahora identifica el layout Unreal instalado y
redirige únicamente el bootstrap a
`Luminary/Binaries/Win64/LuminaryDemo-Win64-Shipping.exe`. La detección está limitada al árbol del
juego y no instala un bypass genérico de redistribuibles.

### Notificación de dispositivo obsoleta

Tras renderizar correctamente, una ejecución anterior sufría una access violation tardía. El
stack reproducible atravesaba `sechost` y `cfgmgr32`; la causa era un `HDEVNOTIFY` inválido en
`CM_Unregister_Notification` y `I_ScUnregisterDeviceNotification`.

El runtime incorpora los cambios oficiales de Wine que:

- convierten los handles de notificación en objetos validados;
- invalidan el objeto al desregistrarlo;
- rechazan usos posteriores en vez de desreferenciar memoria obsoleta;
- cubren la conducta con tests de `cfgmgr32` y `user32`.

La prueba focal de `cfgmgr32` ejecutó 1973 comprobaciones, con cero fallos y un `todo` esperado.

## Aislamiento y rollback

No hay perfil D3DMetal/DXMT especial para Luminary. La detección del bootstrap es una receta
Unreal acotada y el arreglo de notificaciones pertenece al runtime común porque corrige un
contrato Win32 general. Las cuatro DLL anteriores (`cfgmgr32` y `sechost`, x64 e i386) se
preservaron antes de promover el candidato.

La matriz completa de Wine —Steam/CEF, Moonlighter 2 y Palworld— es obligatoria antes de publicar
la release. Si alguno falla, se restaura el runtime anterior; un código de salida por sí solo no
sustituye la evidencia visual.
