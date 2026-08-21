# Cloudheim — expediente de compatibilidad

## Estado

- **Steam App ID:** `2070270`
- **Bootstrap:** `CloudheimSteam.exe`
- **Ejecutable real:** `Cloudheim/ProtoCat/Binaries/Win64/CloudheimSteam-Win64-Shipping.exe`
- **Tecnología:** Unreal Engine, D3D11, Steam Overlay, EOS SDK y EOS Overlay
- **Backend:** motor propio de Regression, DXMT general protegido
- **Perfil compilado:** `cloudheim.unreal-d3d11-dual-overlay-isolation@1`
- **Estado:** **arranque reparado y confirmado por el usuario**. Todavía **sin certificar**: la
  custodia de procesos exige el run cerrado y la matriz funcional completa (render, entrada,
  ajustes gráficos y gameplay). No se crea entrada en `VerifiedGameCatalog` hasta entonces.

El proyecto de Unreal se llama **`ProtoCat`**, no `Cloudheim`: sus logs viven en
`AppData/Local/ProtoCat/Saved/Logs/ProtoCat.log`. Ese desajuste entre nombre de juego y nombre de
proyecto es la razón de que buscar el log por el nombre del juego no encuentre nada.

## Síntoma y causa raíz

El bootstrap y el Shipping terminaban ambos con **exit 3** y sin ventana. La traza reproducida
contiene los cinco marcadores de la colisión ya conocida, en este orden:

```text
Unhandled Exception: EXCEPTION_ACCESS_VIOLATION 0x5320747375725420
[Callstack] 0x5320747375725420 UnknownFunction        <- puntero corrupto
[Callstack] d3d11.dll                                  <- DXMT
[Callstack] d3d11.dll
[Callstack] gameoverlayrenderer64.dll                  <- overlay de Steam
[Callstack] EOSOVH-Win64-Shipping.dll  (x5)            <- overlay de Epic
[Callstack] EOSSDK-Win64-Shipping.dll  (x6)
[Callstack] CloudheimSteam-Win64-Shipping.exe
FPlatformMisc::RequestExitWithStatus(1, 3, LaunchWindowsStartup.ExceptionHandler)
```

Justo antes del fallo: `LogEOSOverlay: OverlayPath registry key found in HKCU`. La dirección
`0x5320747375725420` no es una dirección: son bytes ASCII interpretados como puntero, la firma de
un salto a través de una tabla corrompida por dos enganches encadenados sobre el mismo `d3d11`.

Es la **misma causa raíz que RuneScape: Dragonwilds** (ver [`dragonwilds.md`](dragonwilds.md)).

## A/B discriminante

| Variable | Estado del registro | Overlay de Epic | Resultado |
|---|---|---|---|
| Baseline | `OverlayPath` presente | carga | **crash**, exit 3, sin ventana |
| Experimento (descartado) | clave renombrada, **global** | no carga | arranca, pero afecta a **todos** los juegos |
| **Reparación adoptada** | `OverlayPath` **intacta** | no carga **solo en este proceso** | **arranca y se juega** |

La prueba definitiva se hizo con el registro **restaurado**. El log de esa ejecución demuestra que
la corrección es del motor y no del entorno:

```text
LogEOSOverlay: OverlayPath registry key found in HKCU
LogEOSOverlay: Failed to initialize overlay module: ERR_LOADLIBRARY_0000007E
```

La clave sigue ahí; el `LoadLibrary` falla con `0x7E` (módulo no encontrado) porque Wine deniega esa
DLL **dentro de ese basename exacto**. Steam, su overlay, el EOS SDK y DXMT quedan intactos.

## Reparación

Dos piezas, ambas cerradas y versionadas:

1. `GameRuntimeProfileCatalog` — perfil `cloudheim.unreal-d3d11-dual-overlay-isolation@1`, con
   `profile.dll.disabled = eosovh-win64-shipping` y
   `profile.dll.policy = disabled-only-in-matched-process`.
2. `Scripts/regression-engine.sh` — ruta compilada inicial
   `REGRESSION_PROCESS_DLL_ISOLATION_ROUTE_1`, para que una instalación nueva reciba la corrección
   desde el primer lanzamiento, tanto desde el botón de Regression como desde «Jugar» en Steam.

## Por qué NO se autorreparó (hallazgo del expediente)

`CompiledRepairClassifier` **sí** reconoce este log: los cinco marcadores están presentes. La
detección funciona. Lo que no ocurre es la aplicación, porque está desactivada a propósito en
`CompiledCrashRepairLearner.learn()`:

```swift
// no se muta la botella hasta que el loader pueda aislar App ID+basename.
return nil
```

El formato de ruta v1 del loader solo conoce **basename + receta**, sin App ID. Si dos juegos
distintos tuvieran un ejecutable con el mismo nombre, autorreparar uno se lo aplicaría al otro en
silencio. Ante ese riesgo, el proyecto eligió detectar y no actuar (regla 24 de `AGENTS.md`).

**Consecuencia práctica:** cada juego con esta colisión hay que blindarlo a mano, aunque la receta
ya exista. Cloudheim es la prueba: misma colisión que Dragonwilds, reconocida por el clasificador, y
aun así requirió un perfil escrito a mano.

**Corrección de documentación:** `dragonwilds.md` afirmaba que «un futuro Unreal con la misma
colisión demostrada puede autorrepararse en el siguiente arranque». Con el código actual eso **no
sucede**. La frase queda corregida allí.

## Camino para que sí se autorrepare

Extender el aislamiento de DLL por proceso a **ruta v2 = App ID + basename + receta**
(`patches/wine-26.3.0-process-scoped-dll-isolation.patch`) y, solo entonces, desbloquear la
escritura en `learn()`. Mientras el loader no distinga dos App ID con el mismo ejecutable, la
puerta debe seguir cerrada.

## Estado del bundle

La corrección está en el lanzador de `/Applications/Regression.app`, firmado de nuevo. **El hash de
`Contents/MacOS/regression-engine` ya no coincide con el contrato publicado de 1.12.4**, que lo fija
en ocho archivos. Es una desviación consciente y registrada: se resolverá al publicar la próxima
versión, no falsificando los PIN de una release ya publicada.

Backup del lanzador anterior: `backups/launcher-pre-cloudheim-20260821-195727/regression-engine`
(`8e8aad9628e9eb4f85848aba0538d10bd3c4fa242e7d96f6a826b93830329eff`).

## Regla de no regresión

No desactivar el overlay de Epic globalmente ni tocar el registro de la botella para esto: la acción
debe seguir acotada al basename exacto. Cualquier juego nuevo con los cinco marcadores se blinda
añadiendo su ruta, nunca ampliando el alcance de las existentes.
