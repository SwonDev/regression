# RuneScape: Dragonwilds — expediente de compatibilidad

## Estado blindado

- **Steam App ID:** `1374490`
- **Bootstrap:** `RSDragonwilds.exe`
- **Ejecutable real:** `RSDragonwilds/RSDragonwilds/Binaries/Win64/RSDragonwilds-Win64-Shipping.exe`
- **Tecnología:** Unreal Engine, D3D11, Steam Overlay, EOS SDK y EOS Overlay
- **Backend:** motor propio de Regression, DXMT general protegido
- **Perfil compilado:** `unreal-d3d11-dual-overlay-isolation@1`
- **Run perfecto:** `E5244599-5E9F-4F78-BB9B-00CC781E539E`
- **Huella de configuración:** `596c6ae2057bbae251428da17ad911e46f7ef6dba73950d8c5bd00d9c9cc53a5`
- **Huella de motor:** `17e2f294927c10198edaf33ca11751376269a8271023e5e660bdca8d36874c56`

La ejecución exacta alcanzó título, consentimiento, calibración, juramento, menú 3D, selección de
mundo y personaje, mundo existente y gameplay. Se verificaron movimiento WASD, cámara con ratón,
pausa, cambio y restauración de `Screen Shake`, guardado y salida al escritorio desde el juego.
Las opciones de actividad opcionales quedaron desmarcadas.

## Síntoma y causa raíz

El Shipping terminaba con una violación de acceso dentro de D3D11. La traza reproducida contenía
simultáneamente:

```text
Unhandled Exception: EXCEPTION_ACCESS_VIOLATION
d3d11.dll
gameoverlayrenderer64.dll
EOSOVH-Win64-Shipping.dll
EOSSDK-Win64-Shipping.dll
```

Desactivar todo el overlay de Steam o alterar D3D11 globalmente habría cambiado otros juegos. La
A/B discriminante mantuvo Steam, EOS SDK y DXMT intactos y deshabilitó únicamente
`EOSOVH-Win64-Shipping` dentro del proceso Shipping. Esa única variable eliminó el crash y
permitió completar la matriz funcional.

## Reparación aprendible, pero cerrada

`CompiledRepairClassifier` reconoce la receta solo cuando están presentes los cinco marcadores
anteriores. Tras un run realmente clasificado como `crashed`, `TelemetryCoordinator` puede:

1. inspeccionar logs recientes solo bajo `drive_c/users/*/AppData/Local`;
2. respetar límites de tiempo, 9 niveles, 4096 entradas y 4 MiB por cola de log;
3. no seguir enlaces simbólicos;
4. vincular el basename PE exacto a la receta conocida
   `unreal-d3d11-dual-overlay-isolation-v1`;
5. guardar un snapshot privado de rollback y un `repair_receipt`.

La activación tipada no contiene rutas, variables, DLL arbitrarias, URLs ni comandos. Wine acepta
solo un basename PE validado, una receta enumerada en código y la acción cerrada
`EOSOVH-Win64-Shipping=disabled`. Así, un futuro Unreal con la misma colisión demostrada puede
autorrepararse en el siguiente arranque sin convertir SQLite ni un log controlado por el juego en
una vía de ejecución.

Dragonwilds conserva además una ruta compilada inicial por ejecutable exacto para que una
instalación nueva reciba la corrección desde el primer lanzamiento. Tanto el botón de Regression
como «Jugar» dentro de Steam heredan la misma política.

## Evidencia visual privada

| Puerta | Archivo | SHA-256 |
|---|---|---|
| Menú principal | `main-menu.png` | `fef5e95e51e72d6a655b2e51edaeacaf99b02c2359c1760d2aa9f47e95298f83` |
| Ajuste restaurado | `screen-shake-restored.png` | `140c3922b068780f616af6bf61be6b21dff3ebf04089dc7da3b25a7db8819a42` |
| Gameplay | `exact-run-gameplay.png` | `032725d9487b517818788a5fbcd55110ad1effb709a224ad305919b416d02260` |
| Movimiento | `exact-run-after-movement.png` | `85fe1248f0f2b6f6063ad3356c888b5774afd6690e050644cee5f26b27ed183a` |
| Cámara | `exact-run-after-camera.png` | `16f830d59d7eb54afbd8671af7bc865959353c6f66849451cb5bfc9bf78a11b4` |
| Pausa | `exact-run-pause-native.png` | `508a3a48c1b55ab490147b85d793737a6af144df7caad446749f04a04d6ca54b` |
| Steam tras el cierre | `exact-run-exit-confirm.png` | `a2055200329230df81ad9077240e367dc356be712e25335aa88ddfae4aa4533f` |

## PIN y rollback

```text
ntdll.so del run perfecto:   bf4f25e96883150e955f4465a5a15cbd6adaf0f152a8e1239004486dfbf2b81a
ntdll.so endurecido 1.9.0:   4a1679b1e05d42e2aba768c4cf93e1acf8cd3ef6fed5400f9ef343953cbfd194
launcher regression-engine: 1ca7959ef2da4968cc057386cce3bba507d2ca3b16d535096273947fe1eb66df
recetas Swift endurecidas:   7debde51806e6808e69c3fc81fc4a5f1da4bb9c601e1932ecc46bce0fef5cc31
parche Wine endurecido:      0c369514975faf248b53e572ed698fa2a2293a6593c86661b446983054c0917b
```

- Baseline y estado de juegos: `backups/three-games-baseline-20260808-224354/`.
- Runtime anterior: `runtime/ntdll.so.pre-dragonwilds`, SHA-256 `9e3eb235…`.
- Launcher anterior: `runtime/regression-engine.pre-three-games`, SHA-256 `5d99cae9…`.
- Evidencia privada: `work/three-games-20260808/evidence/dragonwilds/`.

## Regla de no regresión

No deshabilitar EOSOVH, EOS SDK, Steam Overlay ni D3D11 globalmente. Una coincidencia parcial no
activa la receta. Cualquier ampliación del clasificador o de la acción permitida exige repro rojo,
A/B de una sola variable, rollback, juego objetivo completo, Steam/CEF, Moonlighter 2 y el control
DXMT disponible. Un cierre limpio o una huella parecida nunca bastan para aprenderla.
