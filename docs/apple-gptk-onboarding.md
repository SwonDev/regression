# Apple GPTK: instalación asistida y generaciones protegidas

Regression no redistribuye D3DMetal ni descarga Apple GPTK en nombre del usuario. Apple exige
iniciar sesión y aceptar sus términos en el portal oficial, por lo que esa decisión no puede
automatizarse ni simularse. La aplicación automatiza todo lo que ocurre antes y después de esa
aceptación sin depender de otra aplicación de compatibilidad.

Los componentes de Apple no son intercambiables. Titan Quest II y Borderlands 4 fijan GPTK
4.0b2; Grim Dawn, DragonSword y Dragon’s Dogma 2 conservan perfiles históricos certificados con
GPTK 3.0. Regression selecciona la generación por App ID desde código firmado y bloquea el proceso
si solo existe otra versión, aunque sus archivos parezcan compatibles.

## Flujo en Regression

1. **Mantenimiento → Apple GPTK** indica si el componente falta, está verificándose o ya está listo.
2. **Abrir descarga oficial** lleva únicamente a `developer.apple.com`.
3. **Seleccionar DMG** permite elegir `Evaluation_environment_for_Windows_games_4.0_beta_2.dmg`.
4. Regression monta el DMG en modo de solo lectura, verifica su SHA-256, el payload, las firmas y
   la licencia, y muestra el RTF completo en una hoja nativa desplazable.
5. La instalación solo se habilita después de confirmar explícitamente la licencia. La autorización
   es un token privado de un uso, ligado al DMG y a la licencia inspeccionados, y caduca a los diez
   minutos.
6. El componente se instala mediante staging, backup, verificación final y rollback. El DMG y un
   recibo privado permiten futuras reparaciones automáticas sin volver a buscar el archivo.

## Qué ocurre cuando falta

Steam y los juegos que usan el runtime general pueden seguir funcionando. Solo los perfiles que
declaran D3DMetal quedan bloqueados con una recuperación visible. Regression nunca presenta GPTK
como instalado si no supera la verificación completa y nunca sustituye silenciosamente ese perfil
por otro backend gráfico.

En GPTK 3.0 Regression solo reconoce el payload protegido exacto y su topología completa. Todavía
no existe una huella demostrada del DMG original que permita ofrecer un onboarding nuevo con la
misma autoridad. Por eso una instalación fresca bloquea honestamente esos tres perfiles, en lugar
de sustituirlos por 4.0b2 o aceptar un DMG parecido. Una instalación anterior únicamente puede
conservar esa generación si sus bytes, enlaces y autorización local superan el contrato completo.

## Límites de seguridad y licencia

- La única fuente aceptada para onboarding nuevo es el DMG oficial exacto de Apple GPTK 4.0 beta 2.
- GPTK 3.0 permanece cerrado a nuevas instalaciones hasta disponer de una identidad de DMG
  demostrable; conocer los hashes del payload no equivale a aceptar su licencia.
- No se exploran Descargas ni aplicaciones de terceros para apropiarse de binarios.
- Caché, autorización y recibo usan almacenamiento privado del usuario; no entran en Git ni en la
  release pública.
- Una actualización de versión, hash o licencia exige una nueva inspección y aceptación.
- La reparación automática solo reutiliza un DMG cuyo recibo siga coincidiendo exactamente.

La página oficial de referencia es [Game Porting Toolkit](https://developer.apple.com/games/game-porting-toolkit/).
