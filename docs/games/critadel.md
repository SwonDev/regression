# Critadel — expediente de compatibilidad

## Estado

- **Steam App ID:** `808010`
- **Ejecutable:** `Critadel/Critadel.exe`
- **Tecnología:** **GameMaker** (YoYo Games Runner), D3D11 enlazado de forma estática
- **Perfil compilado:** **ninguno, y es deliberado.** La causa no era del juego.
- **Estado:** **funcionando.** El teclado no llegaba hasta hacer clic en la ventana. Corregido el
  2026-08-25 con dos cambios generales —uno en la app nativa y otro en `winemac.drv`—, no con una
  receta para este juego.

## Síntoma

El juego arranca y muestra su pantalla de título completa —arte, animación, «PRESS ANY KEY»— pero
no responde ni a teclado ni a ratón. Al usuario le parece que el juego está colgado.

## Causa raíz

Son **dos huecos encadenados**, y hasta cerrar los dos el síntoma no desaparece.

### 1. La aplicación del juego nunca llegaba a estar activa

macOS 14 dejó de permitir que una aplicación se ponga al frente por su cuenta: quien está activo
tiene que **cederle** la activación. Wine resuelve eso entre sus propios procesos con una
notificación distribuida —`WineAppWillActivateNotification`—: el juego la publica, las demás apps de
Wine del mismo prefijo ceden con `yieldActivationToApplication:` y solo entonces `NSApp.activate()`
prospera.

Regression no participaba en ese protocolo. Peor: **es accesoria (`LSUIElement`) y nunca queda
activa**, ni siquiera al pulsar dentro de su popover —comprobado—, así que tampoco podía ceder nada.
Si al lanzar el juego había delante una app que no es de Wine (Finder, un navegador, la propia
Regression), nadie cedía y el juego se quedaba visible pero inactivo.

### 2. GameMaker ordena su ventana **sin pedir activación**

Con `winemac.drv` instrumentado, el proceso del juego imprime una sola vez:

```text
REGDIAG order activate=0 appActive=0 keyIsWine=0 canKey=1 disabled=0 noFg=0
```

- `activate=0`: el lado Win32 muestra la ventana sin solicitar activación.
- `appActive=0`: la aplicación no está activa.
- `canKey=1`: la ventana **podría** ser *key*; simplemente nadie se lo concede.

Y en `winemac.drv` hay una asimetría real: al desactivarse la app, `macdrv_app_deactivated` deja el
foco de Win32 **en el escritorio**; al reactivarse, `macdrv_app_activated` solo actualiza el
portapapeles y **nadie lo restaura**. Además la activación se pide *antes* de ordenar la ventana en
pantalla, así que cuando `applicationDidBecomeActive` se dispara todavía no hay ventana a la que dar
el foco.

Resultado: ventana visible, por delante de todo y sin teclado. Un clic dentro sí funcionaba porque
genera `WINDOW_GOT_FOCUS` y el lado Win32 pone su ventana en primer plano —comprobado con
`WINEDEBUG=+key`, que pasa de cero eventos a `macdrv_ToUnicodeEx virtKey 0x000d` y `WM_CHAR`—.

## Corrección

Ambas partes son **generales**: benefician a cualquier juego, no solo a este.

1. **`WineActivationHandoff` + `WineActivationYielder`** (app nativa). Regression observa la
   notificación de Wine y cede la activación a un proceso **de su propia botella**, con el mismo
   contrato que usa Wine entre sus procesos. Además, al pulsar «Jugar» se activa a sí misma —el
   usuario acaba de interactuar con ella, así que macOS lo permite— y **cierra el popover**, que
   mientras seguía abierto retenía la ventana *key* y se quedaba las teclas del juego.
2. **`wine-26.3.0-winemac-restore-focus-on-activate.patch`**, ya dentro de la serie, con dos hunks:
   al recuperar la actividad se concede *key* a la ventana frontal si ninguna la tiene, y —una vez
   la ventana ya está ordenada en pantalla— se cierra el hueco de la carrera concediéndole el
   *key* ahí mismo.

   **El reparto entre lo síncrono y lo diferido no es un detalle de estilo, es el resultado de un
   A/B.** Conceder el *key* hay que hacerlo en el acto: diferirlo un turno del runloop lo pierde,
   porque para entonces el propio juego ya movió el foco. En cambio el descarte de los
   `WINDOW_LOST_FOCUS` pendientes —que `makeFocused:` hace y sin el cual el lado Win32 vuelve a
   soltar el foco justo después— **no** puede hacerse dentro de la pila del ordenado: colgaba a
   Runika antes siquiera de crear su ventana, justo tras inicializar su input. Se difiere solo eso.

## Validación

Partiendo de **Finder al frente** —el caso que fallaba—, se lanza desde el popover de Regression:
el popover se cierra, el juego pasa a ser la aplicación activa y la primera pulsación de Enter
retira «PRESS ANY KEY» **sin haber hecho clic en la ventana**.

Matriz de la fila «Wine» superada con capturas: tienda de Steam (CEF/DXMT), Fields of Mistria
(Unity) y Sonic Adventure 2 (D3D9).

## Avisos de método que costaron tiempo aquí

- **`osascript … set frontmost of process` puede fallar en silencio** con un proceso de Wine:
  devuelve sin error y la app no se activa. Comprobar siempre el frontmost después, no darlo por
  hecho: tres pruebas de teclado se dieron por malas por esto.
- **Una ventana puede estar frontmost sin ser *key*.** `AXFocused` devolvía `true` en ambos casos,
  así que no sirve para distinguirlos. Lo que lo distingue es si las teclas llegan a Wine.
- **Antes de dar por roto Steam, comprobar que no haya un juego a pantalla completa delante.**
  Durante la validación se creyó que Steam dejaba de responder al clic y renderizaba en negro; era
  Fields of Mistria interceptando los clics.
- Este juego costó tres diagnósticos equivocados de «no abre ventana» porque
  `tools/diagnostics/list-windows.swift` filtraba por `layer == 0`. Ya no filtra por capa.

## Relación con otros síntomas reportados

El usuario describía además que en Steam «de repente el clic derecho deja de funcionar» y que «a
veces al dar a Enter los juegos se pasan a modo ventana». Son de la misma familia —foco y estado de
entrada— y la corrección general de arriba es la que les corresponde; una receta por ejecutable no
los habría cubierto.
