# Documentación de Regression

Este índice separa la portada del producto de la documentación técnica. Empieza por la ruta que
corresponda a tu objetivo y consulta `AGENTS.md` antes de cambiar runtime, perfiles o botella.

> **Contrato actual del código fuente:** Regression **1.12.7 (45)** y SQLite **v17**.
> **v1.12.7 (45)** es la release estable actual y **v1.11.0 (37)** el baseline histórico. Los documentos de
> expedientes conservan versiones anteriores como evidencia y no deben reinterpretarse como el
> estado de la release actual.

## Empieza aquí

| Objetivo | Documento |
|---|---|
| Instalar y entender el producto | [README principal](../README.md) |
| Investigar un juego sin romper otro | [Protocolo de compatibilidad](compatibility-research.md) |
| Preparar una prueba reproducible | [Preflight y evidencia](game-test-readiness.md) |
| Entender datos, perfiles y certificaciones | [Plataforma de compatibilidad](compatibility-platform.md) |
| Entender la autoridad durable de lanzamiento v17 | [Plataforma de compatibilidad](compatibility-platform.md#autoridad-de-lanzamiento-v17) |
| Revisar runtimes y autorreparación | [Evolución tecnológica](runtime-evolution.md) |
| Recompilar el runtime sin romper la instalación | [Recompilar el runtime](runtime-rebuild.md) |
| Entender telemetría y certificación v15 | [Plataforma de compatibilidad](compatibility-platform.md#custodia-de-procesos-y-perfectos-v15) |
| Preparar D3DMetal legalmente | [Apple GPTK: instalación asistida](apple-gptk-onboarding.md) |
| Auditar la aplicación Swift/macOS | [Auditoría nativa](native-app-audit.md) |
| Entender el canal de autoactualización | [Actualizaciones automáticas](automatic-updates.md) |
| Mantener una única app instalada | [Instalación canónica](canonical-installation.md) |
| Aprovechar el motor publicado de GameHub for Mac | [Expediente gamesir-labs](research/gamehub-gamesir-labs.md) |
| Aplicar las reglas operativas | [AGENTS.md](../AGENTS.md) |
| Consultar el contrato visual | [DESIGN.md](../DESIGN.md) |

## Fuentes de verdad

| Área | Fuente |
|---|---|
| Reglas y PIN protegidos | [`AGENTS.md`](../AGENTS.md) |
| Identidad visual | [`DESIGN.md`](../DESIGN.md) |
| Catálogo perfecto integrado | [`VerifiedGameCatalog.swift`](../Sources/RegressionCore/VerifiedGameCatalog.swift) |
| Perfiles compilados | [`GameRuntimeProfileCatalog.swift`](../Sources/RegressionCore/GameRuntimeProfileCatalog.swift) |
| Estado local y evidencia | `~/Library/Application Support/Regression/Compatibility/compatibility.sqlite` |
| Distribución pública | [Última release](https://github.com/SwonDev/regression/releases/latest) |
| Política de actualización | [`automatic-updates.md`](automatic-updates.md) |

Un documento de investigación no sustituye a la certificación local. Un proceso con código cero
tampoco crea un veredicto perfecto.

## Expedientes de juegos

### Verificados perfectos

| Juego | Documento |
|---|---|
| Grim Dawn | [`grim-dawn.md`](games/grim-dawn.md) |
| Clair Obscur: Expedition 33 | [`clair-obscur-expedition-33.md`](games/clair-obscur-expedition-33.md) |
| DragonSword: Awakening | [`dragonsword-awakening.md`](games/dragonsword-awakening.md) |
| Hell Clock | [`hell-clock.md`](games/hell-clock.md) |
| Heroes of Hammerwatch II | [`heroes-of-hammerwatch-2.md`](games/heroes-of-hammerwatch-2.md) |
| Secrets of Grindea | [`secrets-of-grindea.md`](games/secrets-of-grindea.md) |
| Fields of Mistria | [`fields-of-mistria.md`](games/fields-of-mistria.md) |
| Titan Quest II | [`titan-quest-2.md`](games/titan-quest-2.md) |
| Forsaken Isle | [`forsaken-isle.md`](games/forsaken-isle.md) |
| RuneScape: Dragonwilds | [`dragonwilds.md`](games/dragonwilds.md) |
| Tinkerlands | [`tinkerlands.md`](games/tinkerlands.md) |
| Moonlighter 2: The Endless Vault | [`moonlighter-2.md`](games/moonlighter-2.md) |
| Cross Blitz | [`cross-blitz.md`](games/cross-blitz.md) |
| Luminary Demo | [`luminary-demo.md`](games/luminary-demo.md) |
| Borderlands® 4 | [`borderlands-4.md`](games/borderlands-4.md) |
| Cursemark | [`cursemark.md`](games/cursemark.md) |

Cube World y FINAL FANTASY TACTICS — The Ivalice Chronicles también están certificados en el
catálogo integrado; sus primeras evidencias son anteriores al formato actual de expediente.

### Verificados por el usuario, sin expediente propio

Estos títulos funcionaron desde el primer lanzamiento sobre el baseline general: no necesitaron
perfil por ejecutable, receta compilada ni investigación, así que no tienen expediente que contar.
Su certificación procede de la validación directa del usuario y está fijada en el catálogo
compilado con el run exacto que la respalda.

| Juego | App ID |
|---|---|
| Sephiria | 2436940 |
| Dwarven Realms | 2015240 |
| Monsuta | 2193400 |
| Luma Island | 2408820 |
| Crashlands 2 | 1401730 |
| Tainted Grail: The Fall of Avalon | 1466060 |
| IRON NEST: Heavy Turret Simulator Demo | 4300500 |
| Granblue Fantasy: Relink | 881020 |
| Temtem: Swarm | 2510960 |

### Reparados, pendientes de certificación

El arranque está corregido y confirmado por el usuario, pero falta la matriz funcional completa con
el run cerrado. **No** tienen entrada en `VerifiedGameCatalog` hasta entonces.

| Juego | Corrección | Documento |
|---|---|---|
| Cloudheim | Overlay de Epic aislado en el proceso Shipping | [`cloudheim.md`](games/cloudheim.md) |
| Dragonkin: The Banished | D3D12 enrutado a D3DMetal (GPTK 4.0b2) por proceso exacto | [`dragonkin-the-banished.md`](games/dragonkin-the-banished.md) |
| TMNT: Shredder's Revenge | Overlay de Epic aislado en `TMNT.exe`; la colisión es del EOS SDK, no de Unreal | [`tmnt-shredders-revenge.md`](games/tmnt-shredders-revenge.md) |
| Core Keeper | Caché de Steam Cloud desincronizada del disco; se diagnostica con `regressionctl cloud-status` | [`core-keeper.md`](games/core-keeper.md) |
| D3D12 por delay-load | Corrección transversal: enruta a D3DMetal por la evidencia real de Unreal | [`d3d12-delay-load-routing.md`](games/d3d12-delay-load-routing.md) |
| Enshrouded | Exige `drawIndirectCount`; MoltenVK lo implementa como stub vacío | [`enshrouded.md`](games/enshrouded.md) |
| Critadel | Resuelto: la app del juego no llegaba a estar activa; cesión de activación y foco de ventana | [`critadel.md`](games/critadel.md) |
| The Witcher 3 | Prelanzador de 32 bits sin Vulkan, interfaz Chromium omitida y D3D12 por D3DMetal | [`the-witcher-3.md`](games/the-witcher-3.md) |
| Sonic Adventure 2 | Negro con música: el `d3d9` de DXVK aliasa el sampler de sombra y Metal lo rechaza; ruta a wined3d | [`sonic-adventure-2.md`](games/sonic-adventure-2.md) |
| Triaje 2026-08-24 | Nueve juegos reportados: qué se resolvió, qué es límite real y qué queda | [`triaje-2026-08-24.md`](games/triaje-2026-08-24.md) |

### Validados con incidencia

| Juego | Incidencia conservada | Documento |
|---|---|---|
| Dragon's Dogma 2 | Letterbox 16:9 | [`dragons-dogma-2.md`](games/dragons-dogma-2.md) |
| Rotwood | Superficie 1512×870 | [`rotwood.md`](games/rotwood.md) |

### Investigación abierta

| Juego | Estado | Documento |
|---|---|---|
| FANTASY LIFE i | Bloqueo oficial de EAC en VM; sin certificación | [`fantasy-life-i.md`](games/fantasy-life-i.md) |

## Investigación de terceros

Estudio de código publicado por otros proyectos que resuelven el mismo problema. Es material de
lectura y planificación: **no entra en el producto sin pasar la matriz de validación** de
`AGENTS.md`, con su procedencia y su licencia registradas.

| Fuente | Qué aporta | Documento |
|---|---|---|
| GameHub for Mac (gamesir-labs) | Overlays de Wine por proceso, D3D12/D3D9 en DXMT, catálogo de parches por juego | [`gamehub-gamesir-labs.md`](research/gamehub-gamesir-labs.md) |

## Ciclo de una corrección

1. Ejecutar el preflight canónico sin modificar el entorno.
2. Reproducir y registrar el síntoma exacto.
3. Comparar una sola variable en un laboratorio aislado.
4. Implementar una receta compilada y acotada por proceso, contenido o ejecutable.
5. Validar juego, Steam y perfiles afectados con evidencia visual.
6. Registrar el run perfecto o la incidencia honesta.
7. Actualizar expediente, PIN, pruebas y release pública.

La explicación completa y los criterios de cierre viven en
[`compatibility-research.md`](compatibility-research.md).

## Mapa del repositorio

```text
Regression.app/                  Artefacto local de desarrollo, nunca instalación canónica
Sources/Regression/              Interfaz nativa de barra de menús
Sources/RegressionCore/          Coordinación, perfiles, telemetría y catálogo
Tests/RegressionCoreTests/       Pruebas de comportamiento y no regresión
Scripts/                         Instalación, firma y empaquetado
build/                           Toolchain, verificadores y ensamblado
patches/                         Parches propios y auditables
assets/                          Marca, iconos, estados y entitlements
docs/games/                      Expedientes públicos por juego
tools/diagnostics/               Diagnósticos de solo lectura
tools/research/                  Laboratorios explícitamente no promocionados
```

## Mantenimiento documental

- La portada debe explicar producto, instalación, compatibilidad y navegación; no acumular diarios.
- Cada juego complejo vive en `docs/games/`.
- Las decisiones operativas permanentes se reflejan en `AGENTS.md`.
- Los cambios de identidad se reflejan en `DESIGN.md`.
- Los hashes, runs y límites se actualizan junto con la implementación que los modifica.
- Las pruebas fallidas se conservan en los expedientes, no se presentan como perfiles activos.
