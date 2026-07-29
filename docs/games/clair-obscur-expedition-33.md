# Clair Obscur: Expedition 33 — expediente de compatibilidad

## Estado final

- **Steam App ID:** `1903340`
- **Ejecutables observados:** `Expedition33_Steam.exe` y
  `Sandfall/Binaries/Win64/SandFall-Win64-Shipping.exe`.
- **Estado:** verificado perfecto en el motor propio de Regression el 29 de julio de 2026.
- **Run canónico:** `4667F4AA-DE5C-4F7A-A7A5-AAAB29829D3C`.
- **Render:** ventana lógica 1512×982 y captura Retina 3024×1964; título, escenario, personajes,
  HUD, transparencias, partículas e iluminación completos.
- **Entrada:** confirmación, Escape y navegación HID precisos.
- **Opciones:** panel gráfico usable; Épico, TSR Épico, escala 100 %, sin bordes, monitor APPA05E
  y 3024×1964 observados. La prueba reversible de VSync persistió y se restauró antes del run
  canónico.
- **Gameplay:** partida existente cargada, combate real renderizado y pausa desde combate
  confirmada.
- **Salida:** ambos procesos observados terminaron limpiamente con código 0.
- **Dependencia de CrossOver:** ninguna en el runtime del motor propio. Los archivos del juego
  residen en la biblioteca física compartida, como en el resto de la arquitectura temporal.
- **Distintivo local:** `Verificado perfecto: Regression`, comprobado visualmente tras vincular la
  confirmación del usuario al run canónico.

## Receta blindada

El juego funciona con el baseline general de Regression 1.7.0. No necesita perfil, DLL, override,
registro ni variable por ejecutable. Esto es deliberado: blindar el juego significa fijar la
huella exacta que funcionó, no añadir una excepción innecesaria.

```text
configuración: 8454bf44804d122d587261d7084ddc08db1185e8c6bc703c5701b5669087c0d7
motor:         8454bf44804d122d587261d7084ddc08db1185e8c6bc703c5701b5669087c0d7
RetinaMode:    n
renderer:      gl
```

La instantánea completa de componentes queda normalizada en SQLite v12 y en la exportación
privada del expediente. La igualdad de ambas huellas demuestra que el run no produjo un delta de
motor ni de botella. Esta certificación no convierte el baseline en una receta global nueva ni
autoriza a cambiar los PIN de DXMT, D3D9, Grim Dawn o Dragon's Dogma 2.

## Matriz de validación

| Puerta | Evidencia | Resultado |
|---|---|---|
| Preflight | base v12, motor, Steam/Wine aislados, manifest y biblioteca coherentes | superada |
| Steam previo | tienda completa renderizada por Regression | superada |
| Arranque | título y confirmación de carga visibles | superada |
| Render | combate 3024×1964 con mundo, personajes, HUD y efectos | superada |
| Entrada | Return y Escape HID respondieron con precisión | superada |
| Opciones | panel gráfico usable y VSync reversible/persistente | superada |
| Gameplay | partida cargada y combate real observado | superada |
| Ciclo de vida | pausa desde combate y dos procesos con exit 0 | superada |
| Confirmación humana | el usuario declaró que funcionaba perfecto | superada |
| Catálogo local | fila verde comprobada en Regression | superada |

La primera carga del título de la sesión exploratoria tardó aproximadamente 95 segundos. En el
run canónico, el juego alcanzó la confirmación de carga alrededor de 35 segundos y el gameplay
apareció seis segundos después de confirmar. Ese comportamiento se registra como variación de
carga, no como un fallo de render.

## Evidencia local y rollback

El expediente privado, excluido de Git, vive en:

```text
backups/clair-obscur-investigation-20260729-050233/
├── regression-bottle-prelaunch.tar.gz
├── sandfall-files-before.sha256
├── resume-steam-before-launch.png
├── resume-launch-t35.png
├── resume-load-t6.png
├── resume-pause-second.png
├── regression-row-perfect.png
├── installed-steam-after-package.png
├── installed-regression-row-perfect.png
├── post-test-preferences/
├── post-validation-state/
├── compatibility-after-certification.sqlite
└── compatibility-after-certification.json
```

Hashes principales:

```text
Steam previo:          2702216abead0e798b591f6ad2fe1b92a9d82c3f81b03fd0b7d076e961b68ea9
confirmación de carga: e777b1f8b7d5dbc1a252f8feac43942228dd3e7e6cc469e7ed47a39d70f47fff
gameplay canónico:     a761251795a8a6f89d75fad2f787da37f5f92917084d7f13a52d2b9270d2e7b4
pausa desde combate:   bee19399dd59fc072b42873e0e7c835ad0c864d80c92823d2ea6aa16dff0acb9
distintivo verde:      c872f546a0388d8cc733ec5d778050943d186d9a679db4339049975576b04c00
Steam tras empaquetar: 10c95401f3e64dfd26d22dedc300b3e766e2f019b2bb325012173fa281a65e9d
fila tras empaquetar:  0a986b38f93c6ccd78e8213f8710dcab89e14aff06b075acff63c7d1eaa42905
```

La partida principal anterior al run tenía SHA-256
`f81198cee3fe72199a85c6bda0a232e70229c341ba2681e1299a1e7cbe015223`. El gameplay confirmado
generó un guardado nuevo con SHA-256
`0ff70eeef8bf854c80d40eed0f451cf3c8fd9ca8611802c3d2f473fdfa1500ca`; se conservó como progreso
del usuario y además se copió a `post-validation-state/`. No se restauró el guardado antiguo. El
tar previo y la copia posterior permiten volver a cualquiera de los dos estados sin ambigüedad.

La copia SQLite posterior a la certificación pasó `PRAGMA quick_check` y conserva el run, sus dos
procesos, las cuatro dimensiones `passed`, la confirmación visual y la huella del motor exacto.

## Invariantes para el futuro

- No crear un perfil específico mientras el baseline exacto siga pasando la matriz.
- No promover una versión nueva del runtime por número de versión: compararla en aislamiento y
  conservar esta huella como rollback.
- Cualquier cambio en Wine, DXMT, DXVK, D3DMetal, presentación, registro o launcher debe repetir
  Steam, título, gameplay, pausa/opciones y salida de este juego antes de sustituir su receta.
- Un exit 0 por sí solo no renueva la certificación; sigue siendo necesaria la inspección visual.
- La biblioteca compartida no convierte el motor propio en dependiente de CrossOver.
