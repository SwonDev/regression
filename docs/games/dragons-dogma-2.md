# Dragon's Dogma 2 — expediente de compatibilidad

## Estado actual

- **Steam App ID:** `2054970`
- **Ejecutable:** `DD2.exe`
- **Estado:** perfil promocionado, protegido y validado como `Funciona con incidencias` en el run
  exacto `257CEEDB-8EE7-4D4E-AF6B-589741406C1F`.
- **Render validado:** D3DMetal + Retina por proceso, con 1512×945 lógicos en ventana sin bordes y
  framebuffer físico de 3024×1890.
- **Presentación:** Dragon's Dogma 2 compone una imagen 16:9 dentro del panel 1512×945 y conserva
  letterbox arriba y abajo. La misma franja se reprodujo en CrossOver; no procede del perfil de
  Regression, pero impide etiquetar el resultado como visualmente perfecto.
- **Entrada:** click, navegación, movimiento y diálogo respondieron con precisión a 1512×945. La
  variante de 3024×1890 internos se descartó porque desbordaba la presentación y desplazaba el
  puntero.
- **Opciones:** accesibles desde título y gameplay; 1512×945, 120 Hz y ventana sin bordes quedaron
  persistidos en `config.ini`.
- **Gameplay:** carga, mundo, personaje, HUD, rendimiento, pausa y opciones se comprobaron
  visualmente y el usuario confirmó que funcionaban bien.
- **Dependencia de CrossOver:** ninguna en el perfil del motor propio. Los archivos del juego
  siguen en la biblioteca física compartida; los ejecutables cargan Wine, el driver y D3DMetal
  desde el árbol de Regression.

Este expediente no certifica el juego como perfecto ni crea una entrada en
`VerifiedGameCatalog`: el usuario autorizó blindar la receta estable dejando patente la limitación
de encuadre compartida con CrossOver. La base local conserva el veredicto con incidencias, mientras
que el runtime queda fijado por hashes y por el instalador transaccional del perfil. El cierre
limpio o `exit=0` no se usaron para elevar el veredicto.

## Síntoma inicial

El baseline del motor propio creaba el proceso pero no presentaba imagen útil. En CrossOver el
juego renderizaba y era jugable. La comparación descartó un problema de archivos instalados o de
la GPU: ambas pruebas usaban el mismo Mac y la misma biblioteca física de Steam.

## Referencia CrossOver

La ejecución de referencia usaba D3DMetal y un escritorio lógico de 1512×945. La captura completa
de macOS era 3024×1890, por lo que CrossOver demostraba que el juego podía presentar correctamente
sobre una superficie Retina. Al aislar `RetinaMode=y` en `DD2.exe`, Regression conservó esa
presentación física y el selector pasó a enumerar también modos físicos superiores. La prueba
final estableció que esos modos enumerados no deben confundirse con la resolución interna idónea:
3024×1890 internos provocaban desbordamiento y un mapa de ratón incorrecto; 1512×945 lógicos con
backing Retina reproducen la referencia correcta.

La inspección permitida confirmó `d3d12.dll`, `dxgi.dll`, `D3DMetal.framework` y
`libd3dshared.dylib`. Regression ya disponía localmente de las piezas Apple verificadas; no se
copió ningún binario propietario de CrossOver ni se enlazó su instalación.

## Matriz A/B

| Candidato | Render | Entrada/opciones | Veredicto |
|---|---|---|---|
| Baseline Regression | negro/sin presentación útil | no evaluable | rechazado |
| D3DMetal sin Retina por proceso | imagen, pero sin paridad de modos lógicos | incompleto | rechazado |
| D3DMetal + Retina como cambio global | funcional | arriesga Steam y otros juegos | no promocionable |
| D3DMetal + Retina solo en `DD2.exe` | 3024×1890 físico | opciones y gameplay | candidato funcional |
| 3024×1890 internos en pantalla completa | nítido, pero desbordado | puntero de macOS visible y click desplazado | rechazado |
| 1512×945 lógicos en pantalla completa | render y rendimiento estables | click preciso; ventana desplazada | incompleto |
| 1512×945 lógicos sin bordes + backing Retina | 3024×1890 físico, letterbox 16:9 igual que CrossOver | click, opciones y gameplay estables | validado con incidencia conocida |
| Bundle canónico firmado + control Grim Dawn | perfil aislado, Steam y PIN intactos | matriz protegida | promocionado y protegido |

## Menú de pausa: carga fría y carga caliente

El primer `Esc` desde gameplay produjo una transición negra prolongada. Al dar foco explícito al
juego y medir la misma acción, el menú apareció entre los 10 y 15 segundos. En la repetición final
del candidato, después de cargar la partida, el menú de pausa ya estaba completo en `t+1`. La
imagen del gameplay volvió correctamente al cerrarlo y las opciones se abrieron desde Sistema.

Esto distingue una carga fría de recursos del menú de una pérdida persistente de render o de
entrada. La repetición canónica confirmó el menú completo en `t+1`, sin agravar el comportamiento
y con retorno correcto a gameplay.

## Implementación candidata

El perfil combina dos parches versionados:

1. `wine-26.3.0-per-process-graphics-routing.patch` reconoce exclusivamente `DD2.exe`, antepone
   `lib/profiles/dragons-dogma-2` y define D3DMetal y Retina solo en ese proceso.
2. `wine-26.3.0-per-process-retina.patch` permite que `winemac.drv` lea
   `REGRESSION_RETINA_MODE`; si no existe, conserva el `RetinaMode=n` global de la botella.

El directorio del perfil contiene:

- `winemac.so` y `winemac.drv` recompilados con la lectura por proceso;
- enlaces relativos a los módulos Apple `atidxx64`, `d3d11`, `d3d12`, `dxgi`, `nvapi64` y
  `nvngx` ya presentes en Regression;
- ningún binario procedente de `/Applications/CrossOver.app`.

Steam y los demás juegos continúan usando los módulos globales protegidos:

```text
winemac.so global:  50fda6d287a23324c39c75c7c887ae3ae0bf4e175c61bae4a92229053b5c65f2
winemac.drv global: da91ec701a18e97c0c3cd943d383ef996092c11d74983876fd44c90b03d5e5b1
ntdll.dll PE64:     44b1379db1b9e3472d1746830eddd88718dbbc761de2e406d45b8be198593ef3
ntdll.dll PE32:     3d2b085b1dce4db5615a2a95d96860b644e1bfd4c907d0a68d177d02bd2010e8
```

Solo cambia el router Unix `ntdll.so`, reconstruido desde el directorio incremental compatible:

```text
ntdll.so router:    9e37f4a1c4c163909b7bc26b2a38b6408f02e261ddbf079b9608bc884b65f67d
DD2 winemac.so:     34d373a22fd224fec6e32d1bf7f31c647c518345752dc6bc632883c8c9aefc42
DD2 winemac.drv:    2ee679fa891fa336b2dd3623a1945f47c1c5834853e66eff342ba356c12d8c32
```

`build/build-dd2-profile.sh` aplica o verifica los parches, compila únicamente esos tres
artefactos y exige sus hashes. `build/install-game-profiles.sh` crea backup, monta el perfil de
forma atómica, comprueba que los módulos globales no han cambiado y firma la app. Si falla el
montaje, la verificación o la firma, restaura automáticamente `ntdll.so` y el perfil anterior y
vuelve a firmar el estado recuperado.
`build/verify-protected-state.sh` protege a partir de ahora las dos mitades PE de `ntdll` además
de la mitad Unix, precisamente para impedir una pareja parcial.

## Incidencia de empaquetado descubierta

Una recompilación temprana desde `build/wine64` sustituyó solo `ntdll.so` y dejó las DLL PE
anteriores. La sesión terminó durante el arranque y el log mostraba
`Win32Font.cpp:1129: Couldn't get string length`. La repetición controlada demostró después que
ese mensaje también aparece varias veces mientras Steam permanece abierto, renderiza CEF, acepta
clicks y lanza DD2; por sí solo no es una aserción fatal ni una causa raíz válida.

La solución robusta sigue siendo reconstruir `ntdll.so` desde `build/wine-profile`, el mismo
directorio y configuración que originaron el runtime canónico, y decidir por proceso vivo,
captura y huella `lsof`, no por una línea aislada del log. Con ese artefacto, las DLL PE y el
`winemac` global permanecen byte a byte intactos. La regla general es no mezclar familias de build
sin validar la matriz completa y no confundir un warning conocido con un fallo reproducido.

## Evidencia local

Todo el expediente privado está bajo:

```text
backups/dd2-investigation-20260728-212116/
├── candidate/
├── evidence/
├── install-test/Regression.app
└── candidate-auth-*/

backups/dd2-final-confirmation-20260729-0738/
├── prelaunch/
├── postlaunch/
└── *.png
```

Evidencias principales:

- gameplay, movimiento, menús y opciones: `candidate-per-process-dd2-*.png`;
- carga fría/caliente de pausa: `candidate-per-process-dd2-pause-refocused-*` y
  `candidate-per-process-dd2-second-pause-*`;
- módulos del juego: `candidate-per-process-dd2-lsof.txt`;
- aislamiento final: `candidate-dd2-profile-smoke-messagebox-lsof.txt`;
- prueba visual del perfil exacto: `candidate-dd2-profile-smoke-messagebox.png`;
- resolución nativa y persistencia final: `candidate-router-dd2-native-*.png` y
  `candidate-router-dd2-gameplay-options-native-persisted.png`;
- gameplay y entrada final: `candidate-router-dd2-load-t6.png` y
  `candidate-router-dd2-gameplay-input-w.png`;
- huella resumida del runtime: `candidate-router-dd2-runtime-proof.txt`;
- Steam sano tras el cierre del juego: `candidate-router-steam-after-dd2-clean-exit.png`;
- instalación reproducible en clon: `install-test/Regression.app`.
- matriz de la app canónica: `canonical-dd2-*.png`;
- control protegido de Grim Dawn y Steam posterior: `../canonical-grimdawn-*.png` y
  `../canonical-steam-after-grimdawn-control.png`;
- recibo canónico, run exacto y huellas: `canonical-matrix-receipt.md`.
- confirmación final a 1512×945: `after-user-confirmation.png`;
- selección y persistencia de ventana sin bordes: `window-mode-after-right.png` y
  `borderless-saved.png`;
- pausa/gameplay tras persistir la receta: `borderless-gameplay-after-save.png`;
- estado instalado del backend seleccionado: `postlaunch/regression-popover-dd2-playable-summary.png`,
  que muestra `Funciona con incidencias: Regression` sin atribuir el empate a CrossOver;
- rollback de configuración, saves y SQLite: `dd2-final-confirmation-20260729-0738/prelaunch`
  y `postlaunch`, con manifiesto `SHA256SUMS` verificado.

Hashes seleccionados:

```text
opciones gráficas:  c88e4e086caba4dc6508d348b4c1a4490486cb91424d6a0039e5fb51664cfa2c
opciones abiertas:   67c65d6ebe3bc77f1f76ee2b6f00eb41c9abb0db346150904b142dfb8dd47e5c
segunda pausa t+1:   5c287a6cc05610a4312bba2123bfa19c4198178154f4595b3752279d8db4d050
smoke Retina:        ae1f4f33f0c51efc653578fc156ade5ec32f463a2bdb33eb6d8335f299805a05
lsof perfil aislado: 4685d85586ba62a6824f8723fff00bad788b45d2d51130dc521954c463e4da07
3024×1890 selector:   d06f1e5bcc5fcee69fffae333841c994332e9494c9ca7938ca7de47bd691223f
cambios guardados:    fb687e2307cb943df48c6905bccc634afea6aa994959cc65fe127af6d1829adc
resolución persistida:3026fc7f1296a2c9a7e48f032e81cf0ba926d95b7113798f881d9d87e04d4c45
gameplay cargado:     df87addbfceb5167f9b36e9092efac803d0e207b757d390fecd412e177f050c6
entrada y diálogo:    65edcca1c37c3acbba73d36959893bb6d6bad5b56412aa217ef336b88d423c1e
pausa t+1:            e8f82c88f9f72fc744b1be0867b4108c23a4b5075f5ca06d02c4a19ed958cbc9
huella runtime:       8f8863a6932aeae12dc293a545ad828da7f74d7aab94ae28282347f3e2b47de0
canónico 3024×1890:   b1239608c4bf502b17fc19c4c8ba4af20e613d0ce85defaf2915e02a40a3f4dd
canónico gameplay/HID:716144337e63590828c8b44c048d0ae555afbef08e4957270884676cc0e4ca5c
canónico pausa t+1:   35a176a6961e844a1065823e1ac82bf860c228ffb6130e04504c5d646aa1d8d4
control Grim opciones:7479902b7ef39d91079d7a3ec8ae77f3b5c2b8e02401ec1e18e890ccde68d760
confirmación 1512×945:7008165c2b186d98d1dea919d27ecc2b9c1cbd03fb1d27f174bd302a45ad83d4
sin bordes seleccionado:af5c57b98bf31a58f232dd32e456c6151515536cb39521de7b078d38fe5c48c1
sin bordes guardado:  a09c662ad4848174437185b9f23632c9c215b796068bb0a4e9509b86221d1b76
gameplay final:       8e997897bacbc32ea57b95366e7a383965188ea9232ea12652639637e9ddaef1
config final:         428ace1583bd122dd768ddf5f15dc6989c1aff9e2fcd0e5885c87d9d8d4d9993
resumen instalado:    235b5a0896a280e21e1c1014096753c9272f44760bc6089e45d48883fd63e092
```

La evidencia tiene permisos privados y está excluida de Git. Los ficheros de autenticación de
Steam usados en copias experimentales no se exportan ni se documentan.

## Rollback, promoción y veredicto

La instalación se ensayó dos veces —incluida la idempotencia— sobre un clon APFS del bundle. Se
forzó además un fallo de firma después de instalar router y perfil: el trap transaccional recuperó
el baseline y `verify-protected-state.sh --before-dd2-promotion` volvió a pasarlo completo. El
backup de la transición conserva el antiguo `ntdll.so` con hash
`2cd0f030fd0b92bbf17308021d23b2a2fede6ab02d528c44c03753dfcb049c97`.

El run técnico `3853E126-1D58-427F-97A1-E36E43509A43` conserva la matriz previa de resolución
física alta. El veredicto de usuario se registró únicamente sobre la repetición exacta
`257CEEDB-8EE7-4D4E-AF6B-589741406C1F`, que terminó con `exit=0`, huella de configuración
`a30c0026fbe0fbd95caa350dbecdeee4cc2ee81c1c206f6b878d4ad63fca6f9e` y huella de motor
`8454bf44804d122d587261d7084ddc08db1185e8c6bc703c5701b5669087c0d7`.

La base local muestra `Funciona con incidencias`; no se añadió una certificación perfecta ni una
fila verde al catálogo embebido. El perfil D3DMetal + Retina sí queda promocionado, protegido y
reproducible. Una futura eliminación del letterbox debe investigarse en otro candidato aislado y
no autoriza a alterar esta receta estable.
