---
name: roadmap-closeout
roles: [verifier, archivist, portfolio-curator]
output: documentación estable y roadmap fuera del contexto activo
---

# Workflow — cierre y archivo

1. `verifier` confirma la condición de cierre contra `HEAD`, tests y smoke final.
2. Por cada tarea `done`, ejecutar `docs promote -Roadmap RM-### -Task <id>` y revisar explícitamente el plan; `-Apply` sólo puede crear scaffolds, nunca aceptar su contenido.
3. `archivist` reemplaza scaffolds, sincroniza `docs/` para describir el comportamiento implementado y registra `roadmaps`/supersession; research no se copia como verdad estable.
4. Ejecutar `docs check -Strict`, `docs index`, `docs graph` y `docs drift`; `attention`, `unknown` o vistas desactualizadas bloquean el cierre.
5. Registrar deuda excluida; una deuda material se convierte en otro roadmap antes del cierre.
6. Crear `CLOSEOUT.md` desde la plantilla con commit, fecha, evidencia y cada path administrado en `documentation`.
7. Ejecutar `pwsh -NoProfile -File scripts/roadmap.ps1 close-check -Roadmap RM-###`; no archivar mientras reporte impactos incumplidos.
8. Mover la carpeta de `roadmaps/open/` a `roadmaps/archive/<año>/`.
9. Agregar una sola fila a `roadmaps/archive/README.md`.
10. Regenerar el índice abierto y ejecutar `scripts/roadmap.ps1 check`.

El contenido archivado no se carga por defecto y nunca funciona como backlog implícito.
