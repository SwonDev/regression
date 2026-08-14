# Apple GPTK: instalación asistida y generaciones protegidas

Regression no redistribuye D3DMetal ni descarga Apple GPTK en nombre del usuario. Apple exige
iniciar sesión y aceptar sus términos en el portal oficial, por lo que esa decisión no puede
automatizarse ni simularse. La aplicación automatiza todo lo que ocurre antes y después de esa
aceptación sin depender de otra aplicación de compatibilidad.

Los componentes de Apple no son intercambiables. Titan Quest II y Borderlands 4 fijan GPTK
4.0b2; Grim Dawn, DragonSword, Dragon’s Dogma 2 y Final Fantasy Tactics conservan perfiles
certificados con GPTK 3.0. Regression selecciona la generación por App ID y basename PE exactos
desde código firmado y bloquea solo ese proceso si falta su generación, aunque exista otra cuyos
archivos parezcan compatibles.

Los dos componentes viven fuera del bundle firmado, en
`~/Library/Application Support/Regression/Components/AppleGPTK/3.0` y
`~/Library/Application Support/Regression/Components/AppleGPTK/4.0b2`. El launcher publica
rutas compiladas hacia esas raíces exclusivamente para `Grim Dawn.exe`,
`DSClient-Win64-Shipping.exe`, `DD2.exe` y `fft_enhanced.exe` (GPTK 3.0), y para
`TQ2-Win64-Shipping.exe` y `Borderlands4.exe` (GPTK 4.0b2). Wine rechaza esos basenames si la
ruta externa verificada no llega al proceso; no hay regreso al perfil interno ni al backend base.

## Flujo en Regression

1. **Mantenimiento → Apple GPTK** indica si el componente falta, está verificándose o ya está listo.
2. **Abrir descarga oficial** lleva únicamente a `developer.apple.com`.
3. **Seleccionar DMG** permite elegir el DMG oficial de la generación que solicita el perfil:
   `Evaluation_environment_for_Windows_games_3.0.dmg` o
   `Evaluation_environment_for_Windows_games_4.0_beta_2.dmg`.
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

En GPTK 3.0 Regression solo reconoce el payload protegido exacto y su topología completa. Una
instalación nueva liga la identidad del DMG elegido al recibo local después de verificar el payload
exacto y sus firmas Apple; una instalación anterior puede conservar su autorización histórica sin
copiar ni modificar el payload. En ambos casos, GPTK 3.0 conserva los cuatro perfiles anteriores
sin sustituirlos por 4.0b2 ni aceptar un componente parecido.

## Límites de seguridad y licencia

- La fuente aceptada para onboarding es únicamente el DMG oficial de la generación solicitada.
  GPTK 4.0b2 exige su SHA-256 fijado; GPTK 3.0 liga el SHA-256 del DMG inspeccionado al recibo
  después de validar el payload y las firmas Apple exactos.
- La licencia verificada para GPTK 3.0 es
  `external/D3DMetal.framework/Versions/A/Resources/LICENSE`; la de GPTK 4.0b2 es
  `Documentation/License.rtf`. No son intercambiables.
- GPTK 3.0 acepta dos recibos privados, ambos con permisos del usuario: el formato histórico de
  ocho campos (`source_kind`, catálogo y huella de payload) para un componente existente, o el
  formato de seis campos autorizado por DMG (`dmg_sha256` y huella de licencia). GPTK 4.0b2 solo
  acepta el formato de seis campos ligado a su DMG fijado.
- No se exploran Descargas ni aplicaciones de terceros para apropiarse de binarios.
- Caché, autorización y recibo usan almacenamiento privado del usuario; no entran en Git ni en la
  release pública.
- Una actualización de versión, hash o licencia exige una nueva inspección y aceptación.
- La reparación automática solo reutiliza un DMG cuyo recibo siga coincidiendo exactamente.

La página oficial de referencia es [Game Porting Toolkit](https://developer.apple.com/games/game-porting-toolkit/).
