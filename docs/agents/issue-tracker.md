# Issue tracker: GitHub

Los issues y especificaciones de Regression viven en GitHub. Usa `gh` desde este checkout para
leerlos, crearlos, comentarlos, etiquetarlos y cerrarlos.

## Convenciones

- Crear: `gh issue create --title "..." --body "..."`.
- Leer con contexto: `gh issue view <número> --comments`.
- Listar: `gh issue list --state open --json number,title,body,labels,comments`.
- Comentar: `gh issue comment <número> --body "..."`.
- Etiquetar: `gh issue edit <número> --add-label "..."`.
- Cerrar: `gh issue close <número> --comment "..."`.

Los pull requests no son una superficie de triaje de peticiones. Cuando una skill diga
«publicar en el issue tracker», debe crear un issue en `SwonDev/regression`.
