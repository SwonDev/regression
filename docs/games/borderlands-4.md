# Borderlands 4

## Estado

- **Steam App ID:** `1285190`
- **Backend certificado:** Regression
- **Veredicto:** Verificado perfecto
- **Fecha:** 2026-08-09
- **Evidencia local final:** observación importada
  `1BDCD9E2-D5F1-4C30-BBDA-43B0E5B3BBCA`
- **Perfil compilado:** `borderlands-4.apple-gptk-linux-uname@1`
- **Huella de configuración final:**
  `a2ec1490e641083b69d63e39f5d013a84760ccf50ca4fb8333b2843f191feeec`
- **Huella de motor final:**
  `d7172135a42000c3c4f672663500351f27df9b89bea0d76551dc79be828b95d0`

La observación es importada porque Regression no estaba abierta como coordinador de telemetría
durante la ejecución definitiva. No se inventó un run. La observación anterior
`F84A12D5-EF7D-4778-B20D-F61F9FB694CE` se conserva como historial; la observación final fija las
huellas posteriores al aislamiento estricto de CEF. El usuario confirmó explícitamente gameplay
real con render, HUD, cámara, entrada y rendimiento perfectos tras completar las dos fases de
compilación de shaders.

## Síntoma original

`Borderlands4.exe` moría antes de crear D3D12. Wine mostraba un page fault de ejecución en una
dirección baja variable (`0x5e570`, `0xe710a0`) con la pila ya dañada. Cambiar overlays o DLLs de
gráficos no alteraba la firma causal.

## Causa raíz

Un helper Unix x86-64 ejecutado mediante `__wine_unix_call_dispatcher` emite directamente el
opcode Linux `syscall` con `RAX=63`. En Linux x86-64, 63 es `uname`; en macOS ese número está
reservado y genera `SIGSYS`. El manejador anterior de Wine interpretaba la señal como una llamada
NT y corrompía el retorno, de donde procedía el page fault aparente.

La corrección vive en
[`wine-26.3.0-macos-linux-uname-sigsys.patch`](../../patches/wine-26.3.0-macos-linux-uname-sigsys.patch)
y se habilita únicamente después de que el loader haya identificado el basename exacto
`Borderlands4.exe`. El loader elimina primero cualquier valor heredado, de modo que Steam,
CEF y otros juegos no pueden activar la traducción mediante el entorno. Dentro del proceso
autorizado todavía exige simultáneamente:

1. `SIGSYS` dentro de un syscall ya despachado por Wine.
2. `RAX == 63`.
3. Los dos bytes anteriores a `RIP` son exactamente `0x0f 0x05` (`syscall`).

Solo entonces escribe la estructura Linux `old_utsname` de seis campos de 65 bytes y devuelve
éxito. El flag se calcula antes de instalar el manejador y dentro de este solo se lee estado
estático seguro. No se interceptan syscalls NT, no se cambian procesos ajenos y no existe una
ruta configurable desde SQLite.

## Ruta gráfica aislada

El ejecutable exacto `Borderlands4.exe` usa D3D12. Regression selecciona el componente local
verificado de Game Porting Toolkit 4.0 beta 2 únicamente para ese basename, mediante el mismo
router compilado que ya protege Titan Quest II. El componente de Apple:

- se instala o repara desde su DMG oficial;
- se verifica mediante manifiesto antes de usarlo;
- no se versiona ni se redistribuye en GitHub;
- no modifica DXMT, DXVK ni el registro global de la botella.

Ambos puntos de entrada —botón de Regression y «Jugar» dentro de Steam— heredan la misma ruta
exacta. El launcher no ejecuta lotes aprendidos ni comandos generados por el juego.

## Evidencia

| Evidencia | SHA-256 |
|---|---|
| Logo 2K tras superar el crash | `b4edaa25e181a60ac584a13002e9fae7a03e51dc189ac3fdc7df9c5d53a00657` |
| Gameplay confirmado perfecto | `3458c7b8eb729a499edbfc283db37b6102dd4c4a837f3fa9e2e93d4c923754aa` |
| Menú final con traducción limitada al proceso exacto | `b881a578e9e766058106eb420fef8b2af8a50bd77d4c1b7c8334c250636969f7` |

Los originales permanecen fuera del asset público en
`backups/compat-20260809-baseline/evidence/borderlands4/`.

## Matriz final de Regression 1.10.0

La validación del mismo candidato que se empaqueta dejó estas puertas visuales:

| Puerta | Resultado | SHA-256 |
|---|---|---|
| Steam Store antes de los juegos | Render correcto | `84e4c962f34775b9a74146c237a3ae39f1af3efa2bf26d0e78c1b2230dfa888b` |
| Moonlighter 2, control Unity | Menú renderizado | `2b5b45763a120a4e7a6ff61577db292c9f2d93f5b9cd856223b14730cdc919b` |
| Borderlands 4, proceso exacto | Menú 3D completo | `b881a578e9e766058106eb420fef8b2af8a50bd77d4c1b7c8334c250636969f7` |
| Steam tras Borderlands 4 | Biblioteca renderizada | `6423ee5b23ea82f2b248030831beb1335d848ece3465003bd52580c5431a2661` |
| Cross Blitz | Render correcto | `d4c11781430772b1e9f95f62f30d5ca6244008214440304c98b200186994bb9d` |
| Luminary Demo | Render correcto | `68078c31d83af5eaa4ad0c34713e65ff4707501904d3279ac851663a9dfe17be` |
| Luma Island, control D3D11 | Render correcto | `fbcde4e086744aa11e5138412e4c4d66bf44be3bf5c972f8853d973182bdd5eb` |
| Steam Store final | Render correcto | `de9130c1835db3881dbfd502f96207a467373be6951ea1fa363623707db47ff7` |

Palworld no estaba instalado en la máquina de validación. No se descargó de forma implícita; se
usó Luma Island como puerta D3D11 adicional y, además, esta corrección no modifica DXMT. Tras cada
juego se cerraron el ejecutable exacto y sus auxiliares; la sesión terminó sin procesos Steam,
Wine, overlay, `conhost` ni depuradores huérfanos.

## Contrato de no regresión

- No globalizar D3DMetal ni introducir overrides `native` de D3D12/DXGI.
- No ampliar la traducción de ABI a otros números de syscall o señales.
- No retirar la puerta compilada por basename: la variante global dejó negra la tienda CEF en
  la matriz A/B y fue descartada antes de publicar.
- No convertir datos aprendidos en comandos, rutas o DLL arbitrarias.
- Cualquier cambio en `ntdll.so` obliga a validar Steam/CEF, Moonlighter 2 y Palworld.
- El perfil de Borderlands 4 debe permanecer restringido al App ID `1285190` y al basename
  `Borderlands4.exe`.

## Legalidad y alcance

La corrección traduce una ABI pública Linux a macOS y utiliza el paquete oficial de Apple
aportado por el usuario. No desactiva, parchea ni elude Denuvo, Steam DRM u otro sistema de
protección. Los componentes redistribuidos por Regression siguen siendo únicamente los que sus
licencias permiten.
