---
name: roadmap-close
description: retirar un roadmap terminado del contexto activo y convertir su resultado en documentación estable
triggers: [cerrar roadmap, archivar roadmap, closeout, roadmap terminado]
tools: [read_file, search, apply_patch, run]
---

# Cerrar y archivar un roadmap

## Procedimiento

1. Verificar la condición de cierre contra tests, smokes y el commit actual.
2. Leer `roadmaps/workflows/roadmap-closeout.md` y `roadmaps/templates/CLOSEOUT.md`.
3. Sincronizar `docs/` con el comportamiento as-built; la investigación no se copia como verdad estable.
4. Registrar deuda excluida y crear `CLOSEOUT.md` con fecha, commit, gates y documentación.
5. Ejecutar `scripts/roadmap.ps1 close-check -Roadmap RM-###`.
6. Mover el roadmap a `roadmaps/archive/<año>/`, actualizar una fila del índice de archivo y regenerar el índice abierto.
7. Ejecutar `scripts/roadmap.ps1 check` y `git diff --check`.

No archivar para limpiar el tablero ni conservar un roadmap cerrado dentro del índice activo.
