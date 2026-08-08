# Secrets of Grindea — expediente de compatibilidad

## Estado blindado

- **Steam App ID:** `269770`
- **Ejecutable:** `Secrets Of Grindea.exe`
- **Backend:** motor propio de Regression, baseline general sin perfil por ejecutable
- **Run perfecto:** `953B6822-AC77-4977-B862-B206D3CE16AE`
- **Huella de configuración:**
  `8bf2d0909a1d0ed0500a900183492136eb54a4396f72ad15a28940a0dfd3c61f`
- **Huella de motor:**
  `2dca5d61f65d10ac63fa3876c4af0c62f078b7f6f884c208d9590db8f746b820`
- **Catálogo compilado:** revisión `2026-08-02.1`, origen `embeddedCatalog`
- **Resultado:** render, HUD, entrada, opciones y gameplay correctos; habilidades y eventos sin
  los trabones iniciales; cierre normal de la ventana en dos segundos.
- **Confirmación:** el usuario confirmó expresamente que la ejecución «funciona perfecto», «va
  muy bien» y autorizó blindarla.
- **Dependencia de CrossOver:** ninguna durante el run certificado. CrossOver se utilizó solo
  como referencia A/B.

No existe una receta especial para este juego. El estado ganador es el runtime general intacto,
sin variables experimentales, overrides, cambios de registro ni DLL adicionales. Crear un perfil
artificial introduciría una divergencia que no está respaldada por la ejecución perfecta.

## Referencia A/B

Secrets of Grindea usa XNA redirigido por Wine Mono/FNA. El inventario en vivo confirmó que
CrossOver 26.3 y Regression cargan las mismas versiones, idénticas byte a byte, de WineMono.FNA,
FNA3D x86, FAudio x86 y SDL3 x86. Ambos recorren FNA3D Vulkan y MoltenVK; la principal diferencia
observada estaba en Wine Vulkan/MoltenVK y no justificó sustituir el baseline después de la
validación final.

| Prueba | Run | Resultado |
|---|---|---|
| Regression inicial | `D6B1FE90-A30D-4733-A717-A1DEC7025BAB` | render correcto; tirones intermitentes durante habilidades o eventos |
| CrossOver 26.3 | `3140BD42-5209-4E62-912B-97326F9B0A28` | el usuario confirmó funcionamiento muy bueno |
| Regression, OpenGL aislado | `47245F1B-D47F-4411-9117-20F03BAF30A1` | arranque y carga mucho peores, congelaciones, tirones y HUD ausente |
| Regression, compilación Metal concurrente | `8A2B42EC-2911-4D51-B6DA-36EEBA124DED` y `9D199EAA-0B90-4E9F-95C9-D3050B6ED59B` | page fault en SDL3 de 32 bits antes de gameplay |
| Regression baseline limpio | `953B6822-AC77-4977-B862-B206D3CE16AE` | perfecto y sin trabones |

Las dos variables candidatas eran efímeras. Se retiraron al cerrar sus procesos y nunca se
instalaron en el bundle, la botella, el registro o un perfil compilado. Sus resultados negativos
permanecen en el expediente `C9A6E901-9CE5-4B96-84D3-037E3C057EBA` y no pueden convertirse en
recetas ejecutables.

## Matriz funcional

| Puerta | Evidencia observada |
|---|---|
| Inicio | splash, menú, carga del guardado y entrada a la partida |
| Render | escenario, personaje, enemigos, partículas y HUD completos |
| Entrada | movimiento, combate, habilidades y navegación suficientes para jugar y morir |
| Opciones | `Config.txt` permaneció idéntico al snapshot anterior; no apareció un ajuste oculto de HUD |
| Gameplay | combate real prolongado; el usuario confirmó ausencia de trabones en habilidades y eventos |
| HUD | una desaparición transitoria se recuperó tras muerte/respawn sin modificar archivos |
| Persistencia | personaje y mundo se guardaron y se conservaron en el snapshot certificado |
| Cierre | botón normal de macOS; proceso finalizado en dos segundos, run reconciliado sin crash |
| Recursos propios | la ejecución certificada perteneció al backend Regression |
| No regresión | runtime, perfiles Grim Dawn/DD2/DragonSword/HWR2 y pareja DXMT/D3D9 verificados por hash |

## Incidencia transitoria del HUD

Durante el run perfecto el HUD desapareció temporalmente, aunque el mundo y el gameplay seguían
renderizando. El `Config.txt` vivo era idéntico byte a byte al respaldo y no contiene una opción
de interfaz. La muerte del personaje y el respawn reconstruyeron el HUD completo sin reiniciar ni
cambiar la configuración.

El comportamiento coincide con un fallo ya descrito en el foro oficial de Secrets of Grindea:
en un caso la interfaz volvió al cambiar de pantalla y también existe el comando `/toggleui` como
recuperación manual. Por tanto, esta incidencia se conserva como estado transitorio del juego,
no como falta de assets, corrupción del guardado o perfil gráfico necesario.

Referencia pública:
<https://secretsofgrindea.com/forum/index.php?threads/the-onscreen-ui-has-disappeared.9866/>

## Evidencia privada y rollback

El backup canónico vive en:

```text
backups/secrets-of-grindea-baseline-20260802-0544/
```

Incluye la SQLite anterior a los experimentos, la SQLite certificada, los datos de usuario de
Regression y CrossOver, configuración de Steam Cloud, saves finales y las capturas principales:

```text
regression-gameplay-baseline.png                         c8ab033adb50265eb874cc99474ce50391fd6979fe3b897745e41fffa8e185b0
user-opengl-gameplay-missing-ui.png                     64455e3f28ed347bdd61b8dad5306606317a2c52275f8401a110f412b732dbd6
concurrent-compile-sdl3-page-fault.png                   5a31d389cf9deedf6efccc3629dddb884cb0af239ab46288b0b12223f8ecbc85
baseline-vulkan-missing-ui-latest.png                    7c931dd1a50d777bc67330bce1d4ee92b5a1dc219027a22b6397c33e88342bfd
baseline-vulkan-ui-restored-after-respawn.png            f3dd4e61f9d5af3722fc96e58245fb7d38114ffc11f6886d0cd88c9867d62c36
baseline-vulkan-perfect-live-capture.png                 0d2b3bcf1e680727c3bff5a529256123dcd5bef67a3eba624d648d4530943963
regression-secrets-of-grindea-certified-green-filtered.png
                                                         5aac95f759b84b6b6e2add35181c8646689350f23c308e989952132a76c9e344
post-catalog-steam-render.png                             24c03c821022cae58ea88b642d8f371a2a15d11d76a9541dced6273c991df595
post-catalog-grindea-certified-green.png                 e22509ab0499147e1aa7a1dc5a0a7f3ef91dd826830c73e7f253f5d5cc5b064a
compatibility-before-experiments.sqlite                  da0a736ac8e294f1af6085964c8f69d0848705a95c5326c89d8794fcbb7be76d
compatibility-certified.sqlite                           fa0cb50291d978412bdfa2287ca6e880a00b7a7daa71680a8811c22610d009d9
compatibility-post-catalog.sqlite                        7a2578120ecac5ebb1ce6f447cddb0e8980d910814c2ac0a5173cb6c6f8ec500
certified-userdata/Config.txt                            22ea19a750efeb070cde19ca8cbe49c0eab0af8bb77f41cc846958537e00728b
certified-userdata/Characters/0.cha                      34726af47168da8f0f67d0f081b76abbb481a12547e93fdf81d36ccd61245bef
certified-userdata/Worlds/0.wld                          5ce392ff2dd691ecac63c90aa5d0df0064e1e735c9d77d659ce074b754ce80ac
```

La SQLite certificada pasó `PRAGMA quick_check`, tiene cero referencias huérfanas y conserva el
historial fallido. La revisión compilada se reconcilió como `embeddedCatalog` conservando el run
y ambas huellas exactas. La app mostró la fila verde `Verificado perfecto: Regression` después
del relanzamiento. Steam renderizó su tienda completa, el backend CrossOver quedó cerrado y el
motor propio permaneció activo.

El catálogo y su test se añadieron en `VerifiedGameCatalog.swift` y
`RegressionCoreTests.swift`. `swift test` ejecutó 86 tests con 0 fallos y un diagnóstico local
omitido por diseño. El bundle pasó `codesign --verify --deep --strict`, mantiene firma Apple
Development y satisface su requisito designado. Binarios instalados:

```text
Regression                               883fc698c418eee1b7725a9c9ebcf33fdd9952d6049af388ea5edf91bc1854fc
regressionctl                            5d410fe3d1388b76c9393f6d81a329bd5c5e597021543f9b116fc40ca389bc0e
```

El bundle anterior completo quedó preservado mediante clon APFS en
`canonical-catalog/Regression-before-grindea-catalog.app`. El empaquetador creó además el backup
transaccional
`backups/native-packaging/regression-native-before-1.7.3-29-20260802-064342.tar.gz`.

El rollback puede restaurar por separado la base de compatibilidad o los datos del juego. No se
necesita rollback de motor porque ninguna A/B modificó el estado instalado.

## Regla de no regresión

Secrets of Grindea debe seguir usando el baseline general con la huella certificada. No se debe
activar `FNA3D_FORCE_DRIVER=OpenGL` ni
`MVK_CONFIG_SHOULD_MAXIMIZE_CONCURRENT_COMPILATION=1` para este ejecutable. Una futura
optimización de Wine Vulkan, MoltenVK o FNA3D solo podrá reemplazar este estado después de repetir
la matriz funcional completa y demostrar una mejora medible sin alterar Steam ni los perfiles
blindados.
