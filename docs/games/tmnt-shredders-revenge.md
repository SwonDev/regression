# TMNT: Shredder's Revenge — expediente de compatibilidad

## Estado

- **Steam App ID:** `1361510`
- **Ejecutable real:** `TMNT/TMNT.exe` (Steam lo lanza directamente; `Launcher.exe` no interviene)
- **Tecnología:** **FNA** (`FNA.dll`, `FNA3D.dll`, `FAudio.dll`, SDL2), D3D11, Steam Overlay,
  EOS SDK (`EOSSDK-Win64-Shipping.dll`) y EOS Overlay
- **Backend:** motor propio de Regression, DXMT general protegido
- **Perfil compilado:** `tmnt-shredders-revenge.fna-d3d11-dual-overlay-isolation@1`
- **Estado:** **arranque reparado y confirmado por el usuario** (pantalla de título con
  «PRESS ANY BUTTON», versión 1.0.0.349). Todavía **sin certificar**: falta el run cerrado con
  custodia completa de procesos y la matriz funcional (entrada, ajustes, gameplay).

Es el primer caso que demuestra que la colisión de overlays **no es un problema de Unreal**: TMNT
no lleva Unreal por ninguna parte. Lo que comparten Cloudheim, Dragonwilds y TMNT es el **EOS SDK**,
que instala su overlay en la botella
(`C:\Program Files (x86)\Epic Games\Epic Online Services\managedArtifacts/.../EOSOVH-Win64-Shipping.dll`).

## Síntoma y causa raíz

El juego moría antes de abrir ventana y saltaba el **Wine Debugger**. La traza del lanzador:

```text
warn:  D3D11Device: Unknown interface query 0ec870a6-5d7e-4c22-8cfc-5baae07616ed
wine: Unhandled page fault on execute access to 5320747375725420
      at address 5320747375725420 (thread 0a74), starting debugger...
```

El valor `5320747375725420` **no es una dirección**: son bytes ASCII (`"S trust "`). El RIP saltó a
texto, que es la firma de un puntero de hook sobrescrito. Y es **exactamente el mismo valor** que
registró Cloudheim (`EXCEPTION_ACCESS_VIOLATION 0x5320747375725420`, ver
[`cloudheim.md`](cloudheim.md)), lo que confirma que es la misma colisión y no una coincidencia.

La secuencia es la ya conocida: el overlay de Steam y el de EOS encadenan hooks sobre el mismo
dispositivo D3D11 de DXMT; el segundo en cadenar sobrescribe el trampolín del primero y la llamada
siguiente —aquí, justo después de que un overlay consulte una interfaz desconocida sobre el
dispositivo— salta al vacío.

## Corrección

Se deshabilita `EOSOVH-Win64-Shipping` **solo dentro de `TMNT.exe`**, por basename exacto:

- `Scripts/regression-engine.sh` → `REGRESSION_PROCESS_DLL_ISOLATION_ROUTE_2_{EXECUTABLE,DLL}`.
- `GameRuntimeProfileCatalog` → perfil compilado con `profile.scope: exact-process` y
  `profile.dll.policy: disabled-only-in-matched-process`.

No hay override global, ni entrada de registro, ni variable de entorno heredable: cualquier otro
juego con EOS SDK conserva su overlay intacto. El test
`testTMNTCompiledProfileIsolatesTheOverlayOnlyInsideItsOwnProcess` fija que el basename es único en
el catálogo, para que la receta no pueda colarse como general.

## Por qué la autorreparación no lo aprendió sola

`CompiledCrashRepairLearner` solo inspecciona ficheros `.log` bajo `drive_c/users` modificados
dentro de la ventana del run y que **mencionen el basename del ejecutable**. TMNT no deja ahí su
traza: el fallo solo aparece en el log del propio lanzador de Regression, fuera de la botella. Por
eso el aprendizaje no tenía nada que reconocer y el blindaje se hizo a mano, siguiendo §5 de
`AGENTS.md`. Ampliar el alcance del detector a los logs del lanzador es una línea abierta: exige
antes decidir cómo se acredita que la traza pertenece a ese App ID y no a otro proceso de la sesión.

## Efecto colateral encontrado y corregido

Dar a TMNT `requiresActiveSteamClient: true` destapó un **bloqueo circular** en el arranque de
Steam que afectaba por igual a Cloudheim y a Titan Quest II: ver la sección correspondiente en
`AGENTS.md`. Con Steam cerrado, el lanzamiento registraba su intención de custodia y acto seguido
volvía a pedir el permiso de custodia, que el interlock deniega precisamente mientras esa intención
exista. El juego no arrancaba nunca y cada reintento renovaba la intención.

## Reproducción

```bash
regressionctl preflight 1361510 --backend regression
regressionctl launch 1361510 --backend regression
```

Con el blindaje puesto el juego llega a la pantalla de título en menos de un minuto. Sin él, el
proceso muere sin ventana y aparece el Wine Debugger.
