# Critadel — expediente de compatibilidad

## Estado

- **Steam App ID:** `808010`
- **Ejecutable:** `Critadel/Critadel.exe`
- **Tecnología:** **GameMaker** (YoYo Games Runner), D3D11 enlazado de forma estática
- **Estado:** **renderiza perfecto; el teclado no llega hasta que se hace clic en la ventana.**
  Diagnosticado, corrección pendiente.

## Síntoma

El juego arranca y muestra su pantalla de título completa —arte, animación, «PRESS ANY KEY»— pero
no responde ni a teclado ni a ratón. Al usuario le parece que el juego está colgado.

## Qué se comprobó

- La ventana existe y está en pantalla: `L21`, `1512x982`, título `Critadel`. **Vive en la capa 21**,
  no en la 0, que es lo normal en una ventana de Wine a pantalla completa.
- macOS considera el proceso **frontmost y visible**: `System Events` devuelve
  `Critadel.exe, true, true, false`.
- Aun siendo la app en primer plano, las pulsaciones sintéticas (`space`, `return`) **no llegan**.
- Tras un **clic dentro de la ventana**, la misma pulsación sí surte efecto y el rótulo
  «PRESS ANY KEY» desaparece.

Es decir: la ventana es frontmost pero **no es la ventana *key***, así que no recibe teclado
hasta que un clic se la concede.

## Pista del propio motor

El binario contiene la cadena:

```text
Couldn't set app to fullscreen as it's occluded by something. Will try again later...
```

GameMaker reintenta el paso a pantalla completa cuando cree estar ocluido. Encaja con un estado
de foco que el runner no da por bueno.

## Relación con otros síntomas reportados

El usuario describe además que en Steam «de repente el clic derecho deja de funcionar» y que «a
veces al dar a Enter los juegos se pasan a modo ventana». Los tres son fallos de foco o de estado
de entrada en `winemac.drv` y conviene investigarlos juntos antes de escribir una receta por juego:
una corrección de foco general los cubriría a la vez, y una receta por ejecutable no.

## Nota de método

Este juego costó tres diagnósticos equivocados de «no abre ventana» porque
`tools/diagnostics/list-windows.swift` filtraba por `layer == 0`. Ya no filtra por capa.
