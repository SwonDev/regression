# Grim Dawn — expediente de compatibilidad

## Estado final

- **Steam App ID:** `219990`
- **Ejecutable:** `x64/grim dawn.exe`
- **Estado:** verificado perfecto en el motor propio de Regression el 27 de julio de 2026.
- **Render:** D3DMetal, framebuffer Retina de 3024×1964.
- **Entrada:** click preciso, incluido inventario, diálogos y menús.
- **Opciones:** editables y persistentes.
- **Gameplay:** sin parpadeos ni corrupción gráfica en la escena verificada.
- **Dependencia de CrossOver:** ninguna en el proceso del juego. Los archivos de Steam pueden
  residir en la biblioteca física compartida, pero Wine, el perfil y las capas gráficas proceden
  de `Regression.app`.
- **Distintivo local:** `Verificado perfecto: Regression`, comprobado visualmente en la app tras
  asociar la confirmación al run canónico.

La confirmación final del usuario fue inequívoca: Grim Dawn ejecutado desde Regression funcionó
sin parpadeos y con precisión correcta. La captura canónica muestra gameplay, inventario y un
diálogo interactivo abiertos, lo que aporta evidencia adicional de presentación y entrada.

## Problemas observados durante la investigación

Las distintas rutas fallidas produjeron síntomas diferentes:

- imagen correcta con coordenadas del ratón desplazadas después de cambiar resolución;
- click alineado al reducir el render interno, a costa de imagen degradada y artefactos;
- imposibilidad de pulsar o aplicar opciones gráficas;
- pantalla completamente negra;
- parpadeo intenso del personaje en el menú y del entorno durante gameplay;
- arranques con cuadros corruptos en la esquina superior izquierda;
- carga anormalmente larga o ausencia de presentación.

Esto demostró que no había un único “bug de resolución”. El escalado podía enmascarar el problema
de entrada, pero no explicaba el parpadeo ni el negro.

## Referencia observada en CrossOver

La prueba estable de CrossOver 26.3 funcionaba con la botella fijada explícitamente a D3DMetal.
El mismo juego podía partir de un escritorio lógico de 1512×982 y usar 3024×1964 dentro del juego
sin perder precisión. Esa comparación descartó que Retina o la alta resolución fueran por sí solas
la causa.

La inspección permitida de la ejecución correcta mostró la pareja Apple `d3d11.dll`/`dxgi.dll`,
`D3DMetal.framework` y `libd3dshared.dylib`. La lección importante no era copiar CrossOver, sino
replicar en el runtime propio una ruta D3DMetal completa y coherente.

## Matriz A/B decisiva

| Candidato | Imagen | Entrada/opciones | Veredicto |
|---|---|---|---|
| Estado DXMT/DXVK mezclado tras pruebas previas | negro o parpadeo | variable | rechazado |
| Reducir render interno | pobre/artefactos | click preciso | rechazado |
| Cambios globales de Retina o escala | Steam llegó a desbordarse | no resolvió ambos problemas | revertido |
| Solo `d3d11`/`dxgi` de Apple | ruta gráfica aún mezclada con `d3d9` DXVK | arranque negro/inestable | rechazado |
| Perfil Apple completo + D3DMetal activo + overrides builtin por proceso | limpio a 3024×1964 | preciso y persistente | **perfecto** |

La prueba parcial fue especialmente útil: anteponer solo la pareja D3D11 no bastaba mientras la
botella heredara `d3d9`, AMD o NVIDIA de otros perfiles. Esa mezcla explicaba que una ejecución
pudiera presentar imagen y aun así parpadear.

## Implementación integrada

El parche `patches/wine-26.3.0-per-process-graphics-routing.patch` modifica el cargador de Wine
para seleccionar un perfil solo cuando el ejecutable es `grim dawn.exe`:

1. antepone `lib/profiles/grim-dawn` al orden de búsqueda de DLLs;
2. el perfil es un enlace interno a `../apple_gptk/wine`;
3. define `CX_GRAPHICS_BACKEND=d3dmetal` y
   `CX_ACTIVE_GRAPHICS_BACKEND=d3dmetal` dentro del proceso;
4. fuerza como builtin, también dentro del proceso, `atidxx64`, `d3d9`, `nvapi64` y `nvngx`;
5. no modifica el registro global, `system32`, Steam, Cube World, FFT ni otros juegos.

El override se añade con el mecanismo interno de orden de carga de Wine, no mediante
`WINEDLLOVERRIDES` global. El launcher y la botella permanecen en su configuración estable.

`build/install-game-profiles.sh` convierte el perfil en una instalación reproducible:

- comprueba los SHA-256 fijados de las piezas locales de Apple GPTK;
- preserva cualquier perfil previo antes de sustituirlo;
- crea el enlace relativo interno;
- firma de nuevo `Regression.app`;
- verifica la firma.

Los recursos Apple no están en Git ni se redistribuyen. El script solo verifica la instalación
local autorizada.

## Evidencia canónica

La ejecución final se lanzó desde Steam bajo el wineserver de Regression. La inspección del PID
del juego confirmó:

- `d3d11.dll` y `dxgi.dll` desde
  `Regression.app/Contents/SharedSupport/wine-root/lib/apple_gptk/wine/`;
- `D3DMetal.framework` y `libd3dshared.dylib` desde el árbol local de Regression;
- ausencia de módulos cargados desde `/Applications/CrossOver.app`;
- ausencia de `d3d9.dll` cargada en el proceso final;
- presencia adicional de la MoltenVK propia del toolchain, sin que eso reintrodujera la DLL D3D9
  de DXVK ni afectara al render D3D11 verificado.

Artefactos locales preservados, excluidos de Git por privacidad y licencias:

```text
backups/grimdawn-d3dmetal-perfect-20260727-1802/
├── visual-canonical-3024x1964.png
├── runtime-modules-canonical.txt
├── options.txt
├── private-evidence/
│   ├── apple/apple-gptk-runtime-exact.tar.gz
│   ├── crossover-reference/
│   ├── regression-runtime/all-grim-dawn-research-logs.tar.gz
│   ├── learning-db/compatibility-final.sqlite
│   ├── system/
│   └── SHA256SUMS-private-evidence.txt
├── loader-before.c
├── ntdll-before.so
├── profile-before.tar.gz
└── routing-patch-before.patch
```

Hashes de la evidencia final:

```text
captura canónica: 03bcc3f54aebf437f7ed524cde06072c5306c997de8975bec6623435af4f93ff
módulos saneados: 0955d058ffe6c6ea379fe453fe8d087036a91457be281d7db7ba7749c8212758
ntdll instalado:  2cd0f030fd0b92bbf17308021d23b2a2fede6ab02d528c44c03753dfcb049c97
parche fuente:     60ee51e3e441e7115e13cedbe6c7826402a2a0c555f1ba8432585fe7ea3b30ef
distintivo UI:      178fff5e46496cf5fd47a46d4377ae69efd822c32fd9e756871d506adc8a6997
menú final app:     8c720ae37d1d754674dc518f26617b07df61a93c66e211bdde5b63172f779b72
Steam final:        44736cf87509b7b9debdc011ec6cbc7c5e3c6b46692fd0d3ad9a219f070fbddd
```

El subdirectorio `private-evidence` conserva además el árbol Apple GPTK exacto, los registros de
la botella CrossOver de referencia, todos los logs encontrados, el proceso y `lsof` completos, la
base SQLite, versiones del sistema y firma. Tiene permisos `0700`/`0600` y está ignorado por Git;
sirve para I+D local y no se comparte por privacidad y licencia.

La app pasó `codesign --verify --deep --strict`. El parche se aplicó con `patch -p1 --dry-run`
sobre el `loader.c` original del tarball 26.3.0 y el resultado fue idéntico a la fuente compilada.
El paquete Swift pasó 10 casos registrados —9 ejecutados y 1 diagnóstico local omitido por
diseño— sin fallos, y compiló en modo Release.

## Rollback

El estado anterior está preservado en
`backups/grimdawn-d3dmetal-perfect-20260727-1802/`. Para investigar otro candidato no se modifica
este perfil: se crea una copia o un perfil nuevo. Si una futura recompilación cambia `ntdll.so`, se
debe reinstalar el parche versionado, ejecutar `build/install-game-profiles.sh`, firmar y repetir
la validación visual.

## Invariantes para el futuro

- No sustituir este perfil por DXMT o DXVK porque otro juego los necesite.
- No mover las DLL de Apple a `system32` ni establecer overrides nativos globales.
- No eliminar los overrides builtin específicos sin reproducir toda la matriz A/B.
- No confundir la biblioteca de archivos compartida con una dependencia de ejecución de
  CrossOver.
- Cualquier cambio en Wine, ntdll, presentación, escala o registro exige reabrir Grim Dawn,
  comprobar gameplay, clicks y opciones, y conservar una nueva captura.
