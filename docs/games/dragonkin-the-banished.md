# Dragonkin: The Banished — expediente de compatibilidad

## Estado

- **Steam App ID:** `1863430`
- **Bootstrap:** `DragonkinTheBanished.exe`
- **Ejecutable real:** `Dragonkin - The Banished/DragonkinTheBanished/Binaries/Win64/DragonkinTheBanished-Win64-Shipping.exe`
- **Tecnología:** Unreal Engine 5, **D3D12 con Agility SDK** (`D3D12Core.dll`, `d3d12SDKLayers.dll`,
  `amd_fidelityfx_dx12.dll`), EOS SDK
- **Backend:** motor propio de Regression con **Apple GPTK 4.0b2 (D3DMetal)** por proceso exacto
- **Perfil compilado:** `dragonkin-the-banished.apple-gptk-4.0b2-shipping@1`
- **Estado:** **render reparado y confirmado por el usuario**. Todavía **sin certificar**: falta la
  matriz funcional completa con el run cerrado. No hay entrada en `VerifiedGameCatalog`.

El proyecto de Unreal se llama **`ProjectAlpha`**; sus datos viven en
`AppData/Local/ProjectAlpha/`. No escribe logs en `Saved/Logs`, así que el diagnóstico se hizo por
inventario del juego y del runtime, no por traza.

## Síntoma

El juego **arrancaba y se jugaba** —terreno, personajes, NPC, partículas, HUD y minimapa correctos—
pero **la geometría estática del entorno no se dibujaba**: edificios, props y decoración ausentes,
el fondo del menú principal reducido a un vacío gris con algunas mallas sueltas sin textura, y
"agujeros" oscuros en el terreno donde debía haber mallas. El minimapa sí mostraba la traza del
pueblo que el mundo no pintaba.

Un exit code 0 y cinco minutos de sesión: el juego no fallaba, **renderizaba de menos**.

## Causa raíz

Dragonkin es un título **D3D12**. Regression enruta D3D12 a **D3DMetal (Apple GPTK)** mediante rutas
por ejecutable exacto que declara el lanzador. La lista de rutas contenía `Grim Dawn.exe`,
`DSClient-Win64-Shipping.exe`, `DD2.exe`, `fft_enhanced.exe` (GPTK 3.0) y `TQ2-Win64-Shipping.exe`,
`Borderlands4.exe` (GPTK 4.0b2).

**`DragonkinTheBanished-Win64-Shipping.exe` no estaba en ninguna.** Sin ruta, el proceso caía al
baseline general: el `d3d12.dll` propio de Wine sobre **vkd3d → Vulkan → MoltenVK → Metal**. Esa
cadena no cubre la geometría GPU-driven de UE5, que desaparece en silencio mientras el resto del
frame sigue componiéndose.

Evidencia de que nunca tocó DXMT: DXMT escribe `<exe>_d3d11.log` junto al ejecutable cuando se usa
(existe para Cube World, Grim Dawn y steamwebhelper) y **Dragonkin no tenía ninguno**. Y el entorno
del proceso mostraba `REGRESSION_EXTERNAL_D3DMETAL_ROUTE_1_EXECUTABLE=DSClient-Win64-Shipping.exe`:
veía las rutas de otros juegos y ninguna suya.

GPTK **sí estaba instalado y verificado** (3.0 y 4.0b2, en `Components/AppleGPTK` del
almacenamiento privado del usuario, con `D3DMetal.framework` y `libd3dshared.dylib`). El problema
nunca fue el componente, sino que **nadie se lo asignaba a este juego**.

## A/B discriminante

| Variable | Ruta gráfica | Resultado |
|---|---|---|
| Baseline | Wine `d3d12` → vkd3d → MoltenVK | terreno y personajes sí; **sin edificios ni decoración** |
| **Ruta añadida** | **D3DMetal (GPTK 4.0b2)** por proceso exacto | **escena completa**: templo del menú con columnas, arcos y estatuas; Montescail con casas, banderas, empedrado y antorchas |

Una sola variable: la ruta del ejecutable. No se tocó el registro, ni la configuración del juego, ni
la escalabilidad, ni DXMT.

## Reparación

Tres piezas, coherentes entre sí y verificadas por
`testExternalAppleRoutesRemainExactAndComponentVerified`:

1. `Scripts/regression-engine.sh` — ruta `REGRESSION_EXTERNAL_D3DMETAL_ROUTE_*` para
   `DragonkinTheBanished-Win64-Shipping.exe` contra `components/apple-gptk/4.0b2/wine`.
2. `GameRuntimeProfileCatalog` — perfil `dragonkin-the-banished.apple-gptk-4.0b2-shipping@1`, con
   `profile.graphics.api = d3d12`, `profile.graphics.backend = d3dmetal` y
   `profile.scope = exact-app-process`.
3. `patches/wine-26.3.0-per-process-graphics-routing.patch` — el basename entra en
   `regression_executable_requires_external_gptk()`, la lista **fail-closed** compilada en Wine: si
   alguna vez faltara la ruta verificada, el proceso se rechaza en lugar de caer en silencio al
   camino largo y volver a renderizar de menos.

El contrato exige que las tres listas coincidan exactamente; el test lo comprueba leyendo el
lanzador, el catálogo y el propio parche.

## Requisito de runtime

La pieza 3 vive en un parche de Wine, así que **solo entra en vigor al recompilar el runtime**
(`build/apply-wine-patches.sh` + build, y después `build/refresh-release-pins.sh`). Las piezas 1 y 2
ya funcionan sin recompilar: la ruta se aplica por entorno y así se validó.

Mientras el runtime instalado no incorpore la pieza 3, Dragonkin **funciona** pero sin la garantía
fail-closed: si GPTK dejara de verificar, volvería a renderizar de menos en vez de negarse a
arrancar.

## Corrección general: detección por evidencia

Dragonkin dejó de ser un caso particular. `D3D12MetalRouteDetector` recorre la biblioteca y
propone ruta a D3DMetal para los títulos que **acreditan** Direct3D 12 con evidencia del propio
juego: el **Agility SDK** (`D3D12Core.dll`) dentro de la estructura canónica de Unreal
`<juego>/<proyecto>/Binaries/Win64/D3D12/`, junto a un **único** Shipping. El lanzador valida cada
basename y lo publica solo si GPTK 4.0b2 verifica.

Tres reglas lo mantienen seguro, y las tres tienen test:

1. **Las rutas compiladas mandan.** Un juego ya fijado a una generación no se reasigna, así que
   DragonSword conserva GPTK 3.0 y ningún certificado cambia de camino gráfico.
2. **Traer el SDK no basta.** Un Unity que empaqueta `D3D12Core.dll` en la raíz —sin
   `Binaries/Win64`— arranca en D3D11 y **no** se enruta. Es el caso real de **Core Keeper**, que
   funciona y no puede tocarse: `testDetectorIgnoresUnityLayoutThatMerelyShipsTheAgilitySDK`.
3. **Basename ambiguo, sin ruta.** Dos juegos con el mismo Shipping no reciben decisión gráfica,
   igual que en el detector de bootstraps Unreal.

Ejecutado contra la biblioteca real selecciona cuatro títulos: Dragonkin y DragonSword —ambos ya
con ruta compilada— y Dune Awakening y FANTASY LIFE i, bloqueados por anticheat. Es decir, **hoy no
cambia nada**: su valor es que el próximo Unreal con D3D12 se enrute solo en vez de renderizar de
menos en silencio hasta que alguien lo note.

```bash
regressionctl d3d12-metal-routes   # basename<TAB>ruta del Shipping acreditado
```

## Regla de no regresión

Todo título D3D12 nuevo necesita **las tres piezas**. Añadir solo la ruta del lanzador deja el
contrato incoherente y el test en rojo; añadir solo el perfil no cambia nada en ejecución. Y la
ausencia de ruta **no** produce un error visible: produce un juego que parece funcionar y renderiza
de menos, que es mucho más caro de detectar.
