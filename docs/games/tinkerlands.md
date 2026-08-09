# Tinkerlands — expediente de compatibilidad

## Estado blindado

- **Steam App ID:** `2617700`
- **Ejecutable:** `tinkerlands.exe`
- **Tecnología:** GameMaker
- **Backend:** motor propio de Regression, baseline general
- **Perfil compilado:** `gamemaker-retina-fullscreen-repair@1`
- **Run perfecto:** `0B6589C9-374B-4570-A30A-645EEF57A497`
- **Huella de configuración:** `7808621e2355e2c159b3bd78836738d2fc93ef9a5d2dc6468244117f3ff6e8f9`
- **Huella de motor:** `37e2ce6806f201c1bec1f0807e467b28b1dd988ba33635e9fb6c823a7ccfd745`

El juego ya renderizaba y tenía gameplay correcto, pero podía arrancar con una combinación
incoherente de ventana y resolución Retina. La ventana se veía completa mientras la coordenada
de entrada seguía escalada, de modo que el cursor no acertaba en los botones. Al cambiar a
pantalla completa desde el propio juego, puntero, interfaz y gameplay funcionaban correctamente.

## Reparación acotada del estado

Antes de lanzar Steam, `prepare-launch-state` busca únicamente el fichero conocido
`AppData/Local/Tinkerlands/useroptions.conf` dentro de la botella activa. La reparación se aplica
solo si el JSON válido contiene simultáneamente:

```text
fullscreen = 0
resolution >= 6
```

En ese caso cambia solo `fullscreen` a `1`, conserva todas las demás claves, crea un backup
adyacente de primera escritura y reemplaza el fichero atómicamente. La ruta tiene cuatro
componentes fijos, rechaza cualquier componente simbólico, limita el JSON a 64 KiB y es
idempotente. Una ventana válida de menor resolución o cualquier modo ya fullscreen no se modifica.

La condición representa una clase reutilizable de desajuste GameMaker/Retina, pero la ubicación
y el esquema permanecen compilados. El aprendizaje no puede inventar rutas ni reescribir opciones
desconocidas. La preparación es común al botón de Regression y al botón «Jugar» de Steam porque
ambos usan el mismo cliente preparado.

## Matriz funcional

| Puerta | Resultado |
|---|---|
| Menú | Render completo con puntero alineado |
| Vídeo | 3840×2160 y pantalla completa sin bordes visibles |
| Opción | `Performance Mode` cambiado y restaurado |
| Selección | Personaje e isla existentes accesibles |
| Gameplay | Partida cargada, HUD y mundo renderizados |
| Entrada | WASD movió al personaje; clics precisos en menús |
| Pausa | Menú de pausa accesible |
| Cierre | Guardado y salida limpia mediante la aplicación |

Evidencia privada principal:

```text
options-graphics.png              34a33c53aeef82d5634190aaa0ab9102dcfa44aa5ce59628c376cb22bb7033c2
performance-mode-restored.png     15b5fff636e68910de675ca2cb5fc2009aeff61a4c9d1b05e8c654c185c85af9
gameplay.png                      7064801273d3fa261fe5273b5ad2ef5936d48eca43764c787e967408cc3c166e
after-movement.png                11719440612570e8a46f0f4fc40250ccbbb0fb875c0941eb8641eb38150f8e99
pause.png                         b47da9e154bcfe3344ec55db36f5d0115b064ad10c3c2e5aed36b9ef02058ad6
```

## Rollback y regla de no regresión

- Baseline: `backups/three-games-baseline-20260808-224354/game-state/Tinkerlands/`.
- Evidencia: `work/three-games-20260808/evidence/tinkerlands/`.
- El estado inicial se inventarió antes de tocarlo; la preparación no volvió a modificarlo cuando
  la combinación ya era válida.

No forzar fullscreen, resolución ni RetinaMode globalmente. No aplicar esta receta a otro JSON,
ruta o juego por semejanza nominal. Para ampliar la clase se necesita un esquema compilado,
condición exacta, backup, idempotencia y matriz visual propia.
