# Hell Clock — expediente de compatibilidad

## Estado blindado

- **Steam App ID:** `1782460`
- **Ejecutable:** `Hell Clock.exe`
- **Backend:** motor propio de Regression, baseline general sin perfil por ejecutable
- **Run perfecto:** `2F2DE49D-DE01-4A7F-B2D2-39195EA5D68B`
- **Huella de configuración:**
  `aa2c5e6b85a6c077dfeb18bf0e626519000ee144eabf25ecccf0aa317a41f199`
- **Huella de motor:**
  `033fd4ebad662f34b73e309cc721cfae8cd32fdcd1b2b06b0d235e93e95a1dbb`
- **Resultado:** render Retina 3024×1964, entrada precisa, gameplay, pausa, opciones persistentes,
  restauración exacta de la configuración, retorno al menú y cierre limpio.
- **Confirmación:** el usuario confirmó expresamente que la ejecución actual en Regression va
  «excelente, perfecto» y autorizó su blindado.
- **Dependencia de CrossOver:** ninguna durante la ejecución. La instalación física del juego es
  compartida, pero Steam, Wine, la botella y los módulos cargados pertenecen a Regression.

El juego no necesita una receta especial. Su certificación fija el baseline general que ya estaba
protegido; crear un perfil artificial añadiría divergencia sin resolver ningún fallo reproducido.

## Matriz validada

El preflight canónico confirmó que la base SQLite, el motor, la botella, el manifiesto de Steam,
el aislamiento de Wine y la biblioteca compartida estaban listos. El launcher reinició sus
marcadores de presentación antes de enviar el App ID a Steam.

Se utilizó el tercer guardado existente, que era el de menor progreso y estaba respaldado. La
sesión completó estas puertas:

| Puerta | Evidencia observada |
|---|---|
| Inicio | título, selector de guardado y carga normal |
| Render | escenario, personaje, HUD, mapa y partículas sin artefactos |
| Entrada | movimiento por clic y cursor interno alineado en el centro y la zona inferior |
| Gameplay | partida real cargada y cámara actualizada al desplazarse |
| Pausa | menú abierto mediante Escape y reanudación normal |
| Opciones | panel gráfico accesible desde gameplay; 1512×982, Ultra y VSync operativos |
| Persistencia | VSync pasó de desactivado a activado y siguió activo al cerrar y reabrir opciones |
| Restauración | VSync volvió al valor inicial; la huella final coincidió con la inicial |
| Cierre | retorno al selector, confirmación de salida y fin de sesión agregado con `exit=0` |

La resolución lógica de 1512×982 se presentó como framebuffer Retina de 3024×1964. No hubo
bandas, desbordamiento, cursor de macOS expuesto ni desplazamiento del click.

## Decisión de certificación

El usuario autorizó que una validación visual autónoma del agente pueda crear el blindado cuando
este controle de forma directa toda la matriz y, además, confirmó expresamente este resultado
concreto como perfecto. No se usó el cierre limpio como sustituto de esa validación: las capturas
separadas demuestran gameplay, coordenadas del cursor, pausa, cambio de VSync, persistencia,
restauración y fila verde instalada.

La certificación local quedó vinculada al run exacto y la app mostró
`Verificado perfecto: Regression`. `VerifiedGameCatalog` conserva además una ficha compilada para
que el estado no dependa de regenerar la base local. Los runs anteriores sin verificar permanecen
como historial.

## Evidencia privada y rollback

La evidencia vive en:

```text
backups/hell-clock-baseline-20260729-120152/
```

Incluye la SQLite anterior, los datos de usuario de ambas botellas, el Steam userdata, el estado
posterior y estas capturas principales:

```text
02-gameplay-render.png                 d063995f35864331efed991a8649481da1dc4a56bbc9f423400467799fb131e8
03-gameplay-after-input.png            35c5b48b1ebe5e83d79bce7fadf0afd8590603f58ac5c0b564149ca4c7a6572c
04-cursor-center.png                   f60edfc8736d497e672b800ecf201f1bb7da3ebaa87217d12ad2cdaa5ccb2943
05-cursor-low.png                      ea2385fe1c6933b943de4a7761f74ad5dc1c9c5d583f02e271984dd64f40a4c2
06-pause.png                           e479b8960baf5e3d7e49e80558ec50da6407ae823cfe9a321edc8c2e6122eea5
08-options-vsync-on.png                aa92c4ea63b9ba3ee5ddff09fbe7c1b57fb2a0ed266611bf1f272c0a19eafe2e
09-options-vsync-persisted.png         81750b0f9ebc6505754faadcef558b6b296006b675c84dd9c4a49452581f1177
10-options-vsync-restored.png          b211fedb9016874716a3dc3771bdc7949529eddfd2d506fe1d47d7db77d674f9
12-regression-certified-green.png      21e89ac199a0b3fcfee368c6524c86945816a9e9bc7d63037ac9b69e7616eff4
compatibility-certified.sqlite         490fc4f59275287f902552c83eb997019f36093a2258cd6b9b6f7d29bdd975cd
```

El catálogo quedó instalado en Regression `1.7.2` (`28`) conservando el enlace canónico de
`/Applications`. El bundle superó firma profunda, runtime endurecido y verificación de estado
protegido; Steam siguió renderizando y la búsqueda instalada mostró la fila verde de Hell Clock.
El rollback completo de `1.7.1` (`27`) y los recibos finales viven en `canonical-build/`:

```text
Regression-1.7.1-build27.app            clon APFS firmado del bundle anterior
regression-1.7.2-steam-render.png       6e214f7b695adbee8a98084577a3d8d4e3209b097621ab1756310d8ae3dbc649
regression-1.7.2-hell-clock-green.png    ec64d7367f15f10ad58a7e0f62af5b25b1616bcaa2b6eaa56673422d2e5a323a
Regression 1.7.2 binario                0b13844903d20d9a54aafe8b9a3b68380fa99729a166cecd48acb5d3023d5047
regressionctl 1.7.2                     68b2222678cb39a8959a045898c7790dfb1a109dec3b9e59511acf3fe9ffefb0
```

El rollback puede restaurar por separado la SQLite, el userdata de Steam o los datos del juego.
La prueba no modificó DLL, registro global ni runtime, y `verify-protected-state.sh
--include-bottle` confirmó que los perfiles protegidos y la pareja DXMT/D3D9 seguían intactos.

## Regla de no regresión

Hell Clock debe continuar usando el baseline general. Una versión nueva de Wine, DXMT o cualquier
ajuste global solo podrá sustituirlo después de repetir esta matriz y la correspondiente a todos
los perfiles afectados. Un run que solo llegue al título, no permita cambiar opciones o no tenga
entrada precisa no reemplaza esta certificación.
