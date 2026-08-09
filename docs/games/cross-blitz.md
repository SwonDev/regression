# Cross Blitz

## Estado blindado

- **Steam App ID:** `1619520`
- **Motor:** Unity `2021.3.45f2`
- **Backend certificado:** Regression
- **Run perfecto:** `8EB67186-3D63-4C29-9535-BFC1BAB0A52B`
- **Receta:** `unity-intro-media-borderless-stability`
- **Huella de configuración:** `3d3b91f4c16907b92f19ba819ceb208a2f80b494b50eb9531efb37a35f120e4d`
- **Huella de motor:** `fa3cb7e58e5fc638ad9e4d1e20161a3ecf07ba2e1acd05db280f1a3af2d4a3b0`

El usuario confirmó render, entrada, menú, selección de héroe, estabilidad y cambio de escritorio
de macOS sin que reapareciese la superficie gris. El cierre fue manual y limpio.

## Síntoma y causa

El arranque mostraba el logo de Unity, una superficie negra con cursor y, en otras variantes, una
ventana gris de Wine. Una primera reparación alcanzó el menú, pero al perder y recuperar foco la
superficie volvía a gris.

Los logs minimizaron el caso a dos dimensiones independientes:

1. la intro multimedia cargaba `winegstreamer` y dejaba la superficie Unity inestable;
2. el modo fullscreen exclusivo de Unity 2021.3 no sobrevivía al cambio de escritorio de macOS.

## Reparación compilada

El perfil exacto de `Cross Blitz.exe`:

- deshabilita solo `winegstreamer` para ese proceso y conserva `mfplat`, `mf` y `mfreadwrite`;
- añade el argumento oficial de Unity `-window-mode borderless`;
- no modifica el registro, RetinaMode, el driver ni la multimedia globales.

La activación vive en `GameRuntimeProfileCatalog` y `CompiledGameRepair`. Ningún valor aprendido
desde SQLite se ejecuta como comando.

## Evidencia y no regresión

La captura final `cross-blitz-borderless-user-confirmed-perfect.png` tiene SHA-256
`7e9479032bc370c1caa6cef8cbd1f4d7953ff67d6b4005550c043c08f89d87f9`. La certificación exige
conservar el perfil por ejecutable y validar Steam junto a un perfil ya protegido después de
cambiar su launcher.

No se debe trasladar `WINEDLLOVERRIDES`, `-window-mode borderless` ni cualquier ajuste de pantalla
al entorno general: otros juegos Unity permanecen en el baseline, especialmente Moonlighter 2.
