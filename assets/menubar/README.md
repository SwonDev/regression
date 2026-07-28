# Iconos de estado de la barra de menús

Regression utiliza cuatro iconos nítidos y estáticos. El icono cambia únicamente cuando cambia
el estado operativo de la aplicación; no existe reproducción continua, interpolación ni fundido.

| Estado | Significado |
|---|---|
| `ready` | Regression está disponible y Steam no está activo. |
| `working` | Se está detectando, preparando o cambiando el motor. |
| `running` | Steam está activo. |
| `error` | La aplicación necesita atención. |

## Archivos canónicos

`states/` contiene los cuatro PNG de 18 × 18 px y sus cuatro variantes Retina de 36 × 36 px.
Son los únicos recursos que `Scripts/package_regression.sh` incorpora en
`Regression.app/Contents/Resources`.

La huella visible de cada variante Retina está normalizada a 32 píxeles de alto dentro del
lienzo de 36 píxeles, centrada horizontalmente y desplazada un píxel hacia arriba para igualar
el centro óptico de los iconos nativos vecinos. Antes de normalizar se descarta el halo alfa
inferior al 10 % heredado del recorte de ImageGen; así los 32 píxeles corresponden al dibujo útil
y no a transparencia casi invisible. Las variantes 1× se derivan siempre de esas
fuentes Retina. `SHA256SUMS` fija exactamente los ocho resultados aprobados y el empaquetador lo
verifica antes de tocar el bundle canónico.

La salida original de GPT ImageGen permanece en `source/` y las composiciones de revisión en
`previews/` como material de diseño reproducible, pero no se empaquetan ni se reproducen en la
aplicación. Los 32 fotogramas intermedios del intento animado se retiraron al ser derivados sin
ningún consumidor. SHA-256 de la salida original:
`0b98cb22f34212bc88b7446f40fe44aa647af53d2c8ab03db7c24a8848670ffe`.

Los iconos empaquetados se cargan mediante `NSImage`, se marcan como plantillas nativas y dejan
que macOS aplique automáticamente el color correcto de la barra de menús.
Una `NSImageView` decorativa de 18 puntos presenta el recurso dentro del `NSStatusBarButton`
nativo. La vista ignora el hit testing, conserva el clic estándar de macOS y aplica una corrección
vertical de −0,5 puntos sin reescalar la imagen.
