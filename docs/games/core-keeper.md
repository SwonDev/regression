# Core Keeper — expediente de compatibilidad

## Estado

- **Steam App ID:** `1621690`
- **Ejecutable:** `Core Keeper/CoreKeeper.exe`
- **Tecnología:** Unity 6 (`6000.0.59f2`), D3D11 sobre DXMT
- **Perfil compilado:** **ninguno, y es deliberado** (ver más abajo)
- **Estado:** **falla al arrancar por sincronización de guardado en la nube.** No es una
  regresión del motor: la base de aprendizaje **no registra ningún run bueno** de este juego, así
  que nunca hubo un estado anterior que romper.

## Por qué NO se le asigna ruta a D3DMetal

Core Keeper empaqueta el Agility SDK (`D3D12/D3D12Core.dll`) en la **raíz** del juego, no en la
estructura canónica `…/Binaries/Win64/D3D12/` de Unreal. `D3D12MetalRouteDetector` exige esa
estructura precisamente para no tocarlo: el juego renderiza por D3D11 y una ruta a D3DMetal sería
una intervención sin evidencia. El caso está fijado en
`testDetectorIgnoresUnityLayoutThatMerelyShipsTheAgilitySDK`.

## Síntoma

El proceso vive entre 12 y 18 segundos y **nunca crea ventana**. Steam registra
`App Running` y, unos segundos después, `Game process removed`. No hay crash: el log termina en la
ruta ordenada de cierre (`Manager:QuitHandler()` → `Application:Internal_ApplicationQuit()`).

## Evidencia

En `AppData/LocalLow/Pugstorm/Core Keeper/Player.log` el arranque es sano —D3D11 inicializa contra
`Apple M5 Pro`, cargan 7996 data blocks y el atlas de sprites— y todo se tuerce en `CloudSyncDown`:

```text
CloudSyncDown
localExists=False localTimestamp=1/1/0001 12:00:00 AM cloudTimestamp=8/27/2024 10:22:12 PM
… (una línea por archivo, todas con localExists=False)
Write failed: Success : '…\Steam\121123806\Admins.json.pugbackup' (-2147024896)
… (una por cada archivo que intenta materializar)
FileNotFoundException: Could not find file "…\Steam\121123806\saves\0.json"
```

El árbol local (`saves/`, `worlds/`, `worldinfos/`…) existe, pertenece al usuario y está vacío:
**se creó hoy, en el primer arranque**. La nube sí tiene partidas (de 2023 y 2024). El juego
intenta respaldar cada archivo local antes de sobrescribirlo, el respaldo de algo que no existe
falla, y termina abandonando el arranque.

`logs/cloud_log.txt` de Steam muestra su propio AutoCloud completando sin incidencias
(`Successfully synced to ChangeNumber 0`), así que el problema está en la capa
`ISteamRemoteStorage` del juego, no en el cliente.

## Qué se descartó

- **No es el runtime nuevo.** La botella no contiene **ningún** fichero de activación compilada
  (`.regression/` solo tiene `repair-transactions`), así que el código v2 del loader —el que
  acredita el App ID contra el `appmanifest`— ni siquiera se ejecuta para este proceso.
- **No es gráfico.** D3D11 inicializa y el juego llega a cargar todos sus recursos. La única queja
  gráfica es `GpuFence::Create(): Failed to create ID3D11Fence, error 0x80004005`, que no impide
  continuar.
- **No son las dos opciones de inicio.** El diálogo «Core Keeper» / «Core Keeper (sin mods)»
  bloqueaba los reintentos mientras estaba abierto, pero el fallo se reproduce igual una vez
  elegida una opción.

## Siguiente paso

Comprobar si el arranque se completa con Steam Cloud desactivado para este App ID. Si es así, la
causa queda acotada al sync-down del juego con partidas remotas y sin copia local, y la decisión
sobre qué hace Regression al respecto —si es que debe hacer algo— se toma con esa evidencia.
