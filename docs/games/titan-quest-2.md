# Titan Quest II — expediente de compatibilidad

## Estado blindado

- **Steam App ID:** `1154030`
- **Bootstrap:** `TQ2.exe`
- **Ejecutable real:** `TQ2/Binaries/Win64/TQ2-Win64-Shipping.exe`
- **Backend:** motor propio de Regression, D3DMetal mediante Apple GPTK 4.0 beta 2
- **Puntos de entrada:** botón de Regression y botón «Jugar» del cliente Steam de Windows
- **Run perfecto final de Regression 1.8.0:** `228467BB-AECE-40EF-8FE5-E739250AA859`
- **Run perfecto histórico:** `D6B86246-9194-4DA0-9E83-EBA0B047783B`
- **Run de validación del botón de Steam:** `E0829432-73C8-4462-AACD-DD8CCF099C1E`
- **Resultado:** menú, selección y modelo 3D, carga de partida, gameplay, HUD, movimiento por
  clic, pausa, opciones y cierre limpio verificados visualmente.

La certificación perfecta final conserva la confirmación expresa y repetida del usuario. El run
terminó con los dos procesos observados en código `0`, registró las cuatro dimensiones como
`passed` y fijó la configuración y el motor exactos con la huella
`fb45e5ed2bd154a0127745aeddbc6d6a22ecdcc6be4d3380733d6af93440210b`. La promoción usa la misma
ruta para los dos puntos de entrada; los intentos fallidos previos permanecen como historial y no
se reinterpretan como éxitos.

## Síntoma y referencia

El bootstrap mostraba:

```text
The following component(s) are required to run this program:
Microsoft Visual C++ 2015-2022 Redistributable (x64)
```

El redistribuible ya estaba instalado y sus DLL se verificaron en la botella. El mensaje era un
falso negativo del bootstrap, compartido inicialmente con CrossOver, no una ausencia real de
`vcruntime140`, `vcruntime140_1`, `msvcp140` o `ucrtbase`. Ejecutar directamente el binario Unreal
con GPTK 4.0b2 alcanzó compilación de shaders, menú y gameplay perfecto; eso aisló el problema al
bootstrap y a la coherencia del backend gráfico.

## Causa raíz del doble punto de entrada

El primer candidato del botón de Regression iniciaba el ejecutable real directamente. Alcanzó el
menú en una ejecución, pero otro arranque quedó detenido en la pantalla legal: no reproducía el
argv, Steamworks y EOS de la ruta que había superado gameplay. El botón de Steam crea el proceso
a través de wineserver. Aunque el loader
redirigía correctamente su `argv`, `init_startup_info()` recibía todavía
`ImagePathName=TQ2.exe` desde wineserver y volvía a mapear el bootstrap. Además, la biblioteca
`steamapps` de Regression es deliberadamente un enlace a la biblioteca física canónica de
CrossOver; una validación `realpath` genérica y estricta rechazaba esa ruta conocida.

La reparación tiene dos capas compiladas y acotadas:

1. `loader.c` reconoce solo `TQ2.exe` y genera el destino desde un sufijo fijo bajo el prefijo
   lógico de Regression. Las rutas proporcionadas por entorno siguen sujetas al límite estricto
   de `realpath`; solo la receta integrada conoce el enlace canónico de `steamapps`.
2. `env.c` compara, sin distinguir mayúsculas, el sufijo completo
   `\\steamapps\\common\\Titan Quest II\\TQ2.exe` y sustituye únicamente esa imagen de startup
   por `\\TQ2\\Binaries\\Win64\\TQ2-Win64-Shipping.exe` antes de `load_main_exe()`.

La solución final elimina esa bifurcación: el botón de Regression envía
`Steam.exe -applaunch 1154030`, exactamente igual que el botón del cliente. Después, el router
gráfico coincide exclusivamente con `TQ2-Win64-Shipping.exe`, antepone el
componente externo y fuerza como builtin `d3d10`, `d3d11`, `d3d12`, `dxgi`, `nvapi64` y `nvngx`
dentro de ese proceso. Steam, CEF y los demás juegos conservan el runtime global.

## Componente GPTK autorreparable

`Scripts/install_apple_gptk_component.sh` instala GPTK 4.0b2 fuera del bundle, en
`~/Library/Application Support/Regression/Components/AppleGPTK/4.0b2`. Verifica:

- SHA-256 del DMG oficial;
- hashes de D3DMetal, `libd3dshared` y cada módulo Wine;
- versión del framework y firmas de Apple;
- instalación por staging, permisos privados, rollback y caché local.

Si el componente está incompleto, el launcher intenta repararlo desde el DMG oficial ya autorizado.
Si falta el DMG, muestra la descarga de Apple Developer. Regression no redistribuye binarios de
Apple ni automatiza la autenticación que Apple exige.

## Matriz funcional de Titan Quest II

| Puerta | Evidencia observada |
|---|---|
| Botón Regression | run `228467BB…`: delega en Steam, alcanza el mismo Shipping con GPTK 4.0b2 y termina en código 0 |
| Botón Steam | menú completo sin el diálogo VC++, usando la misma ruta Shipping+D3DMetal |
| Selección | modelos 3D, UI y fondo animado renderizados correctamente |
| Gameplay | partida cargada en Pyrgos con personaje, NPC, escenario, luces, HUD y minimapa |
| Entrada | clic en el terreno desplazó al personaje y actualizó la cámara |
| Pausa | `Esc` abrió el menú in-game correctamente |
| Opciones | panel accesible; el cambio accidental de prueba se descartó y volvió al valor original |
| Cierre | salida confirmada desde el juego; proceso terminó limpiamente en 14 s |
| Recursos | `lsof` confirmó el Shipping real, `ntdll.so` de Regression y D3DMetal/libd3dshared 4.0b2 |

Evidencia visual privada de esta promoción:

```text
regression-button-v4.png              5254ce9502f29176d36f01e2224efacb6918e18aafeae9e6db8c23ebb1d2d62b
regression-button-v7-current.png       cad17ab4d668ada6bae829d067f821884ea89cd27bcf4071efcabd6356a07a88
regression-button-v7-after-play.png    af5b052d7a2a25d682dff76aa37f07151cc00fb66580bbee9ce21c6d8e02529a
steam-button-v6-menu.png              925cab676ebb14d72ffb9cc6e5e18f47cc3a2ecaa8fd9ab2ac72b35a19540add
steam-button-v6-after-play.png        1b64e2b9a8660c81ced0f9eb5b2a6371f498b750a51d38009ad091841880bbd0
steam-button-v6-gameplay-input.png    aa1c2349b823e333a944ac43eb49f368aeb4c5ddebd899fbdeb96aa32aeff763
steam-button-v6-pause.png             7701b52f436da83bb3353d957870279cebd43c4495c38a46cdf9d007581ae30b
steam-button-v6-options.png           28deb18608ecfac42d1406bed0fe9f7665e36df1d1aac1490470812731ce08a1
```

## Implementación y PIN

La receta queda versionada en:

- `Scripts/regression-engine.sh`;
- `Scripts/install_apple_gptk_component.sh`;
- `patches/wine-26.3.0-per-process-graphics-routing.patch`;
- `patches/wine-26.3.0-tq2-steam-startup-image.patch`;
- `GameRuntimeProfileCatalog`, catálogo compilado y solo para App ID `1154030`;
- `build/install-game-profiles.sh` y `build/verify-protected-state.sh`.

Hashes promocionados:

```text
ntdll.so:                    adb97ddb229a7e20b1cac89b88ba81cfd9c9871c801b97dc50a596f0c5e2f113
launcher regression-engine: fd4e3e7ca59926b7977c63d9400dfb44a156f0aeb96b222ee3eba2c57fab3e4e
instalador GPTK:            6942782b7baf0049bb56aba2b9a4e00a107984b1b0198f2307fb63e87ce3103c
```

Los backups transaccionales de la promoción están en `backups/runtime-profiles/` y los estados
de investigación específicos en `backups/titan-quest-2-*`. El payload GPTK queda fuera del repo,
del bundle y de los backups publicables.

## Regla de no regresión

No se permite convertir el falso negativo de VC++ en un bypass global, alterar el registro de la
botella, reemplazar la `dxgi` global ni cargar GPTK 4 en Steam. Un juego similar solo puede usar la
infraestructura de redirección mediante otra receta compilada con App ID, bootstrap, destino,
componente, manifiesto, rollback y matriz propios. La base de aprendizaje puede observar la
necesidad, pero nunca ejecutar rutas ni comandos almacenados.
