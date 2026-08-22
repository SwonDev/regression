# Core Keeper — expediente de compatibilidad

## Estado

- **Steam App ID:** `1621690`
- **Ejecutable:** `Core Keeper/CoreKeeper.exe`
- **Tecnología:** Unity 6 (`6000.0.59f2`), D3D11 sobre DXMT
- **Perfil compilado:** **ninguno, y es deliberado** (ver más abajo)
- **Estado:** **funcionando.** Se cerraba solo al arrancar por un desajuste entre la caché de
  Steam Cloud y el disco. Resuelto el 2026-08-22 restaurando los archivos de nube en la carpeta
  local del juego. Confirmado por el usuario.

## Síntoma

El proceso vivía entre 12 y 18 segundos y **nunca creaba ventana**: parecía que iba a arrancar y se
cerraba solo. Steam registraba `App Running` y, unos segundos después, `Game process removed`. No
había crash: el log terminaba en la ruta ordenada de cierre (`Manager:QuitHandler()` →
`Application:Internal_ApplicationQuit()`).

## Causa raíz

`Steam/userdata/121123806/1621690/remotecache.vdf` declaraba los **ocho** archivos de nube como ya
sincronizados en local (`syncstate 1`, `localtime` de 2024), pero la carpeta donde el juego los
busca —`AppData/LocalLow/Pugstorm/Core Keeper/Steam/121123806/`— estaba **vacía**. Con esa caché,
Steam concluye «ya sincronizado, nada que descargar» y no vuelve a bajarlos:

```text
[AppID 1621690] Currently already synced to global change number '44', should be nothing to download
[AppID 1621690] AutoCloud done. Watching 0 files
```

El juego entra entonces en `CloudSyncDown`, ve que **nada** existe en local, intenta materializar
cada archivo, falla en todos y abandona el arranque:

```text
CloudSyncDown
localExists=False localTimestamp=1/1/0001 12:00:00 AM cloudTimestamp=8/27/2024 10:22:12 PM   (x8)
Write failed: Success : '…\Steam\121123806\Admins.json.pugbackup' (-2147024896)              (x8)
FileNotFoundException: Could not find file "…\Steam\121123806\saves\0.json"
```

Las partidas **nunca estuvieron en peligro**: el espejo local de Steam Cloud,
`userdata/121123806/1621690/remote/`, conservaba los ocho archivos íntegros y con el tamaño exacto
que declara la caché. El fallo era de ubicación, no de pérdida.

## Corrección

Copiar los ocho archivos de `userdata/121123806/1621690/remote/` a
`AppData/LocalLow/Pugstorm/Core Keeper/Steam/121123806/`, conservando sus fechas originales
(`cp -p`) para que el juego no interprete la copia local como más reciente que la nube y suba nada.

```bash
S="$HOME/Library/Application Support/Regression/Bottles/Steam/drive_c/Program Files (x86)/Steam"
R="$S/userdata/121123806/1621690/remote"
D="$HOME/Library/Application Support/Regression/Bottles/Steam/drive_c/users/crossover/AppData/LocalLow/Pugstorm/Core Keeper/Steam/121123806"
cd "$R" && find . -type f | while read f; do mkdir -p "$D/$(dirname "$f")"; cp -p "$f" "$D/$f"; done
```

No hay perfil compilado, ni receta, ni ruta en el lanzador: el motor no interviene en este fallo y
no debe hacerlo. Regression **no borra** nada bajo `drive_c/users`; se verificó que ningún
componente referencia `LocalLow` ni elimina archivos de guardado, y `GameSessionArtifactCleaner`
solo inspecciona procesos.

## Qué se descartó, y cómo

- **El runtime nuevo, descartado con A/B de una sola variable.** Se restauró el `ntdll.so` anterior
  (`e6fc02dc`) con sus PIN y el juego **falló exactamente igual**: proceso a los 30 s, muerto a los
  42 s, sin ventana. El loader v2 tampoco podía intervenir: la botella no contiene ningún fichero
  de activación compilada.
- **No es gráfico.** D3D11 inicializa contra `Apple M5 Pro` y el juego carga sus 7996 data blocks y
  el atlas de sprites antes de morir. `GpuFence::Create(): Failed to create ID3D11Fence, error
  0x80004005` aparece, pero no impide continuar.
- **No es permisos ni espacio.** El árbol de guardado pertenece al usuario, sin flags de
  inmutabilidad ni ACL, y el propio juego escribe `Player.log`, `sentry-unity.lock` y `mods/` en
  esa misma jerarquía durante el arranque fallido.
- **No son las dos opciones de inicio.** El diálogo «Core Keeper» / «Core Keeper (sin mods)»
  bloqueaba los reintentos mientras estaba abierto, pero el fallo se reproduce igual una vez
  elegida una opción.

## Por qué NO se le asigna ruta a D3DMetal

Core Keeper empaqueta el Agility SDK (`D3D12/D3D12Core.dll`) en la **raíz** del juego, no en la
estructura canónica `…/Binaries/Win64/D3D12/` de Unreal. `D3D12MetalRouteDetector` exige esa
estructura precisamente para no tocarlo: el juego renderiza por D3D11 y una ruta a D3DMetal sería
una intervención sin evidencia. El caso está fijado en
`testDetectorIgnoresUnityLayoutThatMerelyShipsTheAgilitySDK`.

## Señal a recordar

Un juego que «hace como que arranca y se cierra solo», sin ventana y sin crash, con Steam diciendo
que no hay nada que descargar: contrasta `remotecache.vdf` contra el disco antes de mirar el motor.
Si la caché declara archivos que no existen, el juego se queda sin sus datos y ningún cambio en
Wine, DXMT o los perfiles lo va a arreglar.
