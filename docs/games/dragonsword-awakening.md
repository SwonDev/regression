# DragonSword : Awakening — expediente de compatibilidad

## Estado blindado

- **Steam App ID:** `4570720`
- **Ejecutable objetivo:** `DSClient-Win64-Shipping.exe`
- **Backend:** motor propio Regression, D3DMetal completo y aislado por proceso
- **Run perfecto:** `6074F679-9CE1-4D6C-A386-2021F06FDE96`
- **Configuración:** `4adbe37064a8e289e5989d7c11678fc03451d1ad01ee760424cc94f45b4ab0bd`
- **Resultado:** render Retina 3024×1964, entrada y pausa precisas, opciones operativas, gameplay
  estable y salida limpia. El usuario confirmó que la ejecución iba «extremadamente perfecto» y
  sin los tirones de los candidatos anteriores.
- **Dependencia de CrossOver:** ninguna durante la ejecución de Regression. CrossOver se usó solo
  como referencia A/B; el perfil apunta a los recursos Apple instalados dentro de Regression.

La certificación `perfect` pertenece al run exacto anterior. Los runs fallidos y los candidatos
con incidencias se conservan como historial y no se reinterpretan como éxitos.

## Causa raíz

La botella propia tiene DXMT/DXVK protegidos globalmente para Steam y otros juegos. Anteponer el
directorio D3DMetal mediante `WINE_DLL_PATH` no neutralizaba por sí solo esos overrides. El primer
candidato aislado terminaba mezclando:

- `D3DMetal.framework` y `libd3dshared.dylib`;
- `dxgi` global de DXMT;
- `d3d12` del árbol Wine global.

Esa ruta híbrida creó el proceso, pero dejó el juego congelado en el logo de Unreal Engine. El run
`706F675F-7CC9-414F-9F00-4802C2E95BF8` documenta ese fallo y fue revertido antes de continuar.

La corrección no cambia el registro ni `system32`. El router reconoce únicamente el nombre exacto
`DSClient-Win64-Shipping.exe`, antepone `lib/profiles/dragonsword` y fuerza como `builtin` dentro de
ese proceso este conjunto indivisible:

```text
atidxx64 d3d9 dcomp d3d11 d3d12 dxgi nvapi64 nvngx
```

Además define `CX_GRAPHICS_BACKEND=d3dmetal`, `CX_ACTIVE_GRAPHICS_BACKEND=d3dmetal`,
`WINED3DMETAL=1` y `REGRESSION_RETINA_MODE=y`. Steam, CEF, Grim Dawn, Dragon's Dogma 2 y cualquier
otro proceso conservan sus rutas anteriores.

## Referencia CrossOver y matriz A/B

| Candidato | Ruta efectiva | Resultado |
|---|---|---|
| Regression baseline | DXMT global | jugable con tirones ocasionales |
| Regression, D3DMetal parcial | ruta híbrida | mejor rendimiento, pero tirones residuales |
| CrossOver `E57336E0-EA76-48C2-9E1B-B391EBF9E07A` | D3DMetal coherente | referencia «excelsa», sin tirones |
| Regression `706F675F-7CC9-414F-9F00-4802C2E95BF8` | D3DMetal + DXMT/Wine global | congelado en logo Unreal; rechazado |
| Regression `6074F679-9CE1-4D6C-A386-2021F06FDE96` | D3DMetal coherente por proceso | perfecto; promocionado |

La inspección `lsof` del run perfecto confirmó que `DSClient-Win64-Shipping.exe` cargó:

```text
lib/apple_gptk/external/D3DMetal.framework/Versions/A/D3DMetal
lib/apple_gptk/external/libd3dshared.dylib
lib/apple_gptk/wine/x86_64-windows/d3d12.dll
lib/apple_gptk/wine/x86_64-windows/dxgi.dll
```

No cargó la `dxgi` global de DXMT. La presencia de MoltenVK coincide con la referencia CrossOver y
no vuelve híbrido el backend D3D12 mientras `dxgi` y `d3d12` procedan juntos del perfil Apple.

Un aviso de Unreal sobre un supuesto driver AMD puede aparecer antes del logo. Se pulsa **No**:
es una detección de versión emulada y no requiere descargar ni instalar controladores de Windows.
Después de descartarlo, el run perfecto llegó a gameplay normal.

## Implementación reproducible

La receta vive en:

- `patches/wine-26.3.0-per-process-graphics-routing.patch`;
- `build/build-dd2-profile.sh`, que reconstruye el router desde el build incremental compatible;
- `build/install-game-profiles.sh`, que instala el router y el enlace del perfil de forma
  transaccional, verifica hashes y firma el bundle;
- `build/verify-protected-state.sh`, que protege el router, el enlace, los perfiles anteriores,
  los módulos globales y la botella.

Hashes fijados:

```text
ntdll.so router:     2a446467a9faa0885f350d096fb6424c92f62201b733f974150c931e3a535a6a
d3d12.dll Apple:     bbda1c4e94ee70255c528c5689b28333ca9bece2d755ede7c4197977a534704f
dxgi.dll Apple:      1b1f2d80349e043e6c628b515ba6b44478a1209c504e6c9f3dae4a9d1b06d561
D3DMetal.framework: 05a7beaed4494a4f5f53d3f626a82fffc3b70146436a908b7048a0632a49e1a8
libd3dshared.dylib:  5131e631eee8b542eadf48f4df9fd662d9aeeb59139137e0e6e14047dc434995
```

El router anterior de DD2 (`9e37f4a1...`) y su perfil permanecen en el rollback previo. Las DLL PE
de `ntdll`, `winemac`, DXMT y D3D9 globales no cambian.

## Evidencia y rollback local

La evidencia privada está en:

```text
backups/dragonsword-d3dmetal-candidate-20260729-092232/
backups/dragonsword-d3dmetal-rerun-20260729-100602/
```

La primera ruta conserva la referencia CrossOver. La segunda contiene el baseline anterior, el
candidato, el save previo, el fallo del run híbrido y las capturas del run perfecto:

```text
regression-perfect-gameplay.png              0949c92be60816210419a97b5f579ca566a961ebf2f9acd029e51ae093ad3d79
regression-perfect-pause-menu.png            988a752b6978a5eabc0d6bb22c915678f470d5726ea73f165a55a512fde99375
regression-after-clean-exit-steam-window.png  5c78633bf727584de4968fac3c887924c58a442c13714f0c287e7c2984883430
```

Después de empaquetar Regression `1.7.1` (`27`), se reemplazó limpiamente la instancia nativa
anterior y se repitió la validación instalada. El popover superó doce ciclos de despliegue del
apartado de aprendizaje, volvió a reposo y mostró la fila verde de DragonSword. Steam renderizó
la tienda completa mediante el motor propio y se cerró normalmente. Los recibos finales viven en
`backups/dragonsword-d3dmetal-rerun-20260729-100602/final-validation/`:

```text
regression-1.7.1-dragonsword-green.png  ee568fa3715fd35171fc37c6cea62648a9a306436e34afbe0d4490c6acd23114
regression-1.7.1-popover.png            1120156138679cbda255afca941b3d68fc4327465da3cfb37305b80550ae4631
regression-1.7.1-steam-store.png        8b4888fcb22cf781fd33f20fac408c2017a4cd27e1cf6a1aba52f0d7fdfafcd0
```

El rollback restaura `pre-change/ntdll-installed.so` con hash
`9e37f4a1c4c163909b7bc26b2a38b6408f02e261ddbf079b9608bc884b65f67d`, elimina
`lib/profiles/dragonsword`, vuelve a firmar y ejecuta
`build/verify-protected-state.sh --before-dragonsword-promotion --include-bottle`.

## Regla de no regresión

El perfil solo puede cambiar después de repetir el mismo ciclo: referencia CrossOver, copia o
candidato aislado, una variable, captura de gameplay, entrada, opciones, pausa, salida limpia,
inventario de módulos, rollback y matriz de Steam más un perfil protegido. Una versión más nueva
de Wine o D3DMetal no sustituye esta receta por número de versión.
