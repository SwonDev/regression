---
name: Regression Native Utility
description: Contrato visual del lanzador macOS de barra de menús para Steam mediante CrossOver o el motor propio de Regression.
colors:
  primary: "#5E5CE6"
  secondary: "#0A84FF"
  success: "#30D158"
  warning: "#FFD60A"
  error: "#FF453A"
  surface: "#1C1C1E"
  on-surface: "#F2F2F7"
typography:
  title:
    fontFamily: SF Pro
    fontSize: 17px
    fontWeight: "600"
    lineHeight: 22px
  body:
    fontFamily: SF Pro
    fontSize: 13px
    fontWeight: "400"
    lineHeight: 18px
  callout:
    fontFamily: SF Pro
    fontSize: 14px
    fontWeight: "500"
    lineHeight: 19px
  caption:
    fontFamily: SF Pro
    fontSize: 11px
    fontWeight: "400"
    lineHeight: 14px
rounded:
  control: 8px
  card: 12px
  panel: 14px
spacing:
  unit: 4px
  compact: 8px
  regular: 12px
  section: 16px
components:
  status-row:
    backgroundColor: "{colors.surface}"
    textColor: "{colors.on-surface}"
    typography: "{typography.body}"
    rounded: "{rounded.card}"
    padding: "{spacing.regular}"
  status-success:
    backgroundColor: "{colors.success}"
    textColor: "{colors.surface}"
  status-warning:
    backgroundColor: "{colors.warning}"
    textColor: "{colors.surface}"
  backend-picker:
    backgroundColor: "{colors.surface}"
    textColor: "{colors.on-surface}"
    typography: "{typography.callout}"
    rounded: "{rounded.control}"
    padding: "{spacing.compact}"
  game-row:
    backgroundColor: "{colors.surface}"
    textColor: "{colors.on-surface}"
    typography: "{typography.body}"
    rounded: "{rounded.card}"
    padding: "{spacing.regular}"
  progress:
    backgroundColor: "{colors.surface}"
    textColor: "{colors.on-surface}"
    typography: "{typography.caption}"
    rounded: "{rounded.control}"
    padding: "{spacing.compact}"
---

## Overview

Regression es una utilidad nativa de macOS que vive en la barra de menús. Su panel debe sentirse como una extensión discreta del sistema, no como un gestor de botellas ni como una réplica visual de CrossOver. La jerarquía prioriza el estado operativo, la acción principal para abrir Steam y la selección consciente del motor.

El panel usa controles SwiftUI y materiales de macOS. No se crean imitaciones personalizadas de Liquid Glass, barras de título ni ventanas flotantes superpuestas. La interfaz general de CrossOver solo se abre como acción de reparación, licencia o actualización.

## Colors

Los valores anteriores documentan el tono semántico de referencia. En código se prefieren `Color.accentColor`, `Color.primary`, `Color.secondary` y los colores de estado del sistema para conservar contraste, vibrancy, accesibilidad y adaptación automática a los modos claro, oscuro y de alto contraste.

- Índigo del sistema para la identidad y el backend seleccionado.
- Azul del sistema para enlaces y acciones secundarias.
- Verde, amarillo y rojo únicamente para éxito, advertencia y error.
- Nunca comunicar un estado solo mediante color: acompañarlo con icono y texto.

## Typography

Se usa exclusivamente la tipografía del sistema. Los títulos emplean `headline`; el contenido, `body` o `callout`; los metadatos y App ID, `caption` con diseño monoespaciado cuando ayude a escanear datos técnicos. Se respetan Dynamic Type y los tamaños de accesibilidad disponibles en macOS.

## Layout

El panel tiene un ancho ideal de 380 puntos y una altura flexible con desplazamiento cuando la lista de juegos lo requiera. Aplica una cuadrícula de 4 puntos, márgenes exteriores de 16 puntos y separación de 12 a 16 puntos entre secciones.

Orden de contenido:

1. Estado actual y progreso.
2. Acción principal para abrir o mostrar Steam.
3. Selector del motor.
4. Juegos detectados y lanzamiento por App ID.
5. Datos locales, exportación y diagnóstico.
6. Reparación, actualización y salida.

## Elevation & Depth

La profundidad procede del material nativo del `MenuBarExtra` y de separadores del sistema. Las tarjetas internas usan fondos secundarios discretos; no se apilan materiales ni sombras fuertes. El foco visual se obtiene con espaciado y tipografía.

## Shapes

Los controles conservan su forma nativa. Los contenedores auxiliares usan radios de 10 a 12 puntos. No se mezclan píldoras, rectángulos y círculos sin función semántica. Los iconos proceden de SF Symbols.

## Components

- **Estado:** símbolo, resumen legible y detalle técnico opcional.
- **Acción principal:** un botón prominente cuyo texto cambia entre “Abrir Steam”, “Mostrar Steam” y “Reintentar”.
- **Selector de motor:** selector nativo que explica que cambiar de motor cerrará primero el Steam activo.
- **Juegos:** filas compactas con nombre, App ID y botón de reproducción; no muestran datos privados de la cuenta.
- **Historial:** resumen de ejecuciones locales, comparación y exportación bajo demanda.
- **Errores:** mensaje comprensible, causa técnica desplegable y una acción concreta como “Abrir CrossOver” o “Usar motor de Regression”.

## Do's and Don'ts

### Do

- Mostrar progreso durante detección, preparación, cambio de motor y lanzamiento.
- Mantener una sola instancia de Steam activa.
- Explicar cualquier cambio de botella, biblioteca o licencia antes de ejecutarlo.
- Usar etiquetas, ayuda contextual y accesibilidad para todos los controles.
- Conservar el motor propio visible como alternativa, sin activarlo silenciosamente.

### Don't

- No mostrar la aplicación en el Dock durante el uso normal.
- No abrir la interfaz general de CrossOver salvo reparación, actualización o licencia.
- No crear ni instalar otra botella o copia de Steam automáticamente.
- No almacenar credenciales, identificadores de cuenta ni registros sin filtrar.
- No iniciar simultáneamente Steam de CrossOver y Steam de Regression.
