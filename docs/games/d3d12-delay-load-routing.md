# Enrutado D3D12 por evidencia de delay-load — expediente transversal

## Estado

- **Alcance:** cualquier juego Unreal que renderice con Direct3D 12.
- **Resuelto el:** 2026-08-24.
- **Confirmado:** Redfall (1294810) llega a su pantalla de título con la escena completa;
  Wayfinder (1171690) inicializa D3D12 (`Feature Level 12_1`) en vez de rendirse.

## Síntoma

El juego mostraba **«DX12 is not supported in your system»** y no arrancaba. El mismo mensaje
llevaba repitiéndose título tras título aunque la corrección —enrutar el proceso a D3DMetal— ya
estuviera hecha para otros juegos.

## Causa raíz

`D3D12MetalRouteDetector` aceptaba **una sola** forma de evidencia: el Agility SDK
(`D3D12Core.dll`) junto a un `*-Win64-Shipping.exe`, en la estructura canónica
`<juego>/<proyecto>/Binaries/Win64/D3D12/`. Esa forma la cumplen pocos títulos:

| Juego | Agility SDK | Ejecutable | ¿Detectado antes? |
|---|---|---|---|
| DragonSword | sí | `DSClient-Win64-Shipping.exe` | sí |
| Redfall | **no** | `Redfall.exe` | **no** |
| Wayfinder | **no** | `Wayfinder.exe` | **no** |

Redfall y Wayfinder fallaban por partida doble: ni traen el SDK ni nombran su ejecutable con el
sufijo `-Win64-Shipping`.

## La evidencia que sí sirve

Unreal **no enlaza `d3d12.dll` de forma estática**: si lo hiciera, el juego no arrancaría en una
máquina sin D3D12. Lo declara como **delay-load** y decide en tiempo de ejecución. Leer el
directorio de delay-load del PE acredita exactamente lo que hace falta saber.

Medido sobre la biblioteca entera:

```text
Wayfinder      estáticas=[dxgi, d3d9, d3d11]        delay-load=[d3d12, d3dcompiler_43]
Redfall        estáticas=[d3d11, d3d9, d3dcompiler] delay-load=[d3d12]
DragonSword    estáticas=[dxgi]                     delay-load=[d3d12, d3d9, d3d11]
Fields of Mistria  estáticas=[]                     delay-load=[]
Critadel       estáticas=[d3d11]                    delay-load=[]
Witcher 3 (dx11)   estáticas=[d3d11, dxgi]          delay-load=[]
Enshrouded     estáticas=[]                         delay-load=[]
```

Lo cumplen **exactamente** los títulos que necesitan D3D12 y **ninguno** de los que funcionan
sobre DXMT. DragonSword lo confirma desde el otro lado: su perfil compilado ya codificaba a mano
esta misma evidencia.

Buscar la cadena `d3d12.dll` por el fichero entero también la encuentra —fue mi primer sondeo—
pero encontraría igualmente cualquier dato incrustado que la contenga. Leer el directorio la
acredita. `PortableExecutableReader` hace esa lectura, acotada y sin seguir enlaces.

## Qué cambió

- `Sources/RegressionCore/PortableExecutableImports.swift` (nuevo): lector PE acotado que separa
  importación estática de delay-load.
- `D3D12MetalRouteDetector`: acepta la segunda evidencia además del Agility SDK.
- Se deja de exigir el sufijo `-Win64-Shipping` en el basename enrutable, aquí y en
  `Scripts/regression-engine.sh`. El basename sigue acotado a `[A-Za-z0-9_-]+\.exe` porque viaja
  hasta el loader de Wine dentro de una variable de entorno.

## Lo que NO cambió

Un ejecutable que no acredita ninguna de las dos formas conserva exactamente el comportamiento
anterior. El test `testDetectorLeavesDirect3D11OnlyUnrealGameAlone` fija que un Unreal que solo
usa D3D11 no puede recibir la pila de Apple por estar en la misma estructura de carpetas, y
`testDetectorIgnoresUnityLayoutThatMerelyShipsTheAgilitySDK` conserva el caso de Core Keeper.
