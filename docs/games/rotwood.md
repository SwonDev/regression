# Rotwood — expediente de compatibilidad

## Estado validado

- **Steam App ID:** `2015270`
- **Ejecutable:** `rotwood.exe`
- **Backend:** motor propio de Regression, sin perfil especial
- **Run exacto:** `E9316F8E-A6C3-4DE2-A075-6884A923AE4D`
- **Huella de motor y configuración:**
  `033fd4ebad662f34b73e309cc721cfae8cd32fdcd1b2b06b0d235e93e95a1dbb`
- **Estado local:** `Funciona con incidencias`
- **Resultado funcional:** render, entrada, gameplay, pausa, opciones y cierre con guardado
  comprobados. El usuario confirmó que el juego funciona perfectamente en lo funcional.
- **Incidencia visual:** el juego deja bandas negras arriba y abajo. CrossOver 26.3 reproduce las
  mismas bandas, por lo que no son una regresión específica del motor propio.

No se crea una certificación `perfect` ni una entrada en `VerifiedGameCatalog`: la presentación
no satisface el criterio visual del usuario. El veredicto con incidencias pertenece al run exacto
anterior y ya se muestra de forma persistente en la app.

## Baseline Regression

El preflight canónico pasó con un único aviso: había dos marcadores DXMT obsoletos que el launcher
normal elimina antes de arrancar. No existían wineservers ajenos, servicios huérfanos ni un
segundo Steam activo.

La ejecución llegó a una partida real y permitió comprobar:

| Puerta | Resultado |
|---|---|
| Render | escena, personaje, HUD y mundo correctos |
| Entrada | movimiento, combate y navegación precisos |
| Pausa | menú abierto y cerrado sin bloquear la partida |
| Opciones | pestaña gráfica accesible; modo sin bordes y resolución máxima visibles |
| Gameplay | funcionamiento excelente confirmado por el usuario |
| Cierre | guardado, retorno al menú y salida normal con `exit=0` |

Rotwood escribió esta geometría en su `settings.ini`:

```ini
[graphics]
window_width = 1512
window_height = 870
fullscreen_y = 65
fullscreen_x = 0
```

La pantalla lógica del Mac era 1512×982, con framebuffer Retina de 3024×1964. El juego compone
por tanto una superficie de 1512×870 dentro de una pantalla más alta. Su panel gráfico ofrece
«Resolución máxima» como límite vertical de render, pero no un selector de relación de aspecto o
un modo nativo 1512×982 que elimine las bandas.

## Comparación A/B con CrossOver

Tras cerrar el juego y cambiar de backend limpiamente, el preflight de CrossOver 26.3 también
pasó. Se lanzó la misma instalación física de Steam y Rotwood mediante la CLI oficial de
CrossOver. La pantalla inicial y el menú mostraron las mismas bandas superior e inferior.

Al cerrar, CrossOver registró:

```ini
[graphics]
window_width = 1512
window_height = 870
fullscreen_y = 0
fullscreen_x = 0
```

La diferencia de `fullscreen_y` no cambia la superficie renderizada: ambos backends reciben
1512×870 y producen la misma presentación en la pantalla 1512×982. Esta prueba falsifica la
hipótesis de que Regression estuviera recortando o reescalando el juego.

No se copiaron DLL, dylib, binarios ni datos propietarios de CrossOver. CrossOver se usó
exclusivamente como referencia conductual A/B.

## Decisión de ingeniería

No se modifica el runtime, la botella, el registro ni la configuración del juego. Forzar a ciegas
1512×982 cambiaría la geometría que el propio juego elige y podría introducir distorsión,
recorte o entrada imprecisa. Cualquier intento futuro de eliminar las bandas deberá ejecutarse
como candidato aislado, con rollback y comparación completa; nunca sobre este baseline excelente.

La receta estable es el baseline general con huella `033fd4eb…`. Como no fue necesario cambiar
una pieza compartida, los perfiles protegidos de Grim Dawn, Dragon's Dogma 2, DragonSword,
Cube World, Clair Obscur y FFT no se tocaron.

## Evidencia privada y rollback

El expediente local vive en:

```text
backups/rotwood-baseline-20260729-111437/
```

Incluye SQLite previo, datos de usuario de ambas botellas, capturas de gameplay/opciones, la
comparación CrossOver y la fila instalada de Regression:

```text
user-gameplay-letterbox.png            2e08857dd152af2d58afa88e6f23222118244178bfef5880a68a80bfced8a0dc
regression-gameplay-letterbox.png      c037d99ada599783fd4cadbaf601cca2eaa10a8884b623f23fe2f0dec818df05
rotwood-graphics-options.png            b9c3ff4e2fc8bb31be6aef05f2b431bcd906d6f24d446e90fdc7f839867bb30a
crossover-menu-letterbox.png           3cce535b7c829011971b378e340e5a792287407cf50d1255170fa4bd466f653f
crossover-main-letterbox.png           96f66185c7698dd10277600f80080f95fbf42d0eee0ffd3c4c8ebad4ab50cd37
regression-ui-playable-row.png          81dd67ae5e7e67455b226583e4d83e5da84d032c7e105b4a82b77c9feea16ba7
```

El rollback conserva la base de compatibilidad anterior y los datos de usuario de Rotwood en
archivos separados por backend. La evidencia está excluida de Git y mantiene permisos privados.

## Regla de no regresión

Una futura mejora visual no sustituye este baseline por intuición. Debe demostrar simultáneamente
que elimina las bandas, conserva la composición correcta, mantiene la entrada precisa, permite
cambiar opciones, persiste tras reiniciar y no altera ningún perfil protegido. Hasta entonces,
el estado honesto es «funciona con incidencias», aunque su funcionamiento sea excelente.
