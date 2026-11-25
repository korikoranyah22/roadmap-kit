## Roadmaps

El trabajo planificado se gobierna desde `roadmaps/README.md`.

Antes de investigar o implementar:

1. Leer `roadmaps/README.md` y elegir un solo roadmap abierto.
2. Ejecutar `pwsh -NoProfile -File scripts/roadmap.ps1 resume -Roadmap RM-###`.
3. Leer `roadmaps/AGENTS.md`, el roadmap y únicamente su `next_task`.
4. Cargar las skills declaradas por la tarea.
5. Ejecutar la verificación, actualizar evidencia y correr `roadmap.ps1 check` e `index`.

El estado operativo vive en `roadmaps/`; el comportamiento estable vive en `docs/`; Git conserva la historia. Los roadmaps cerrados reciben `CLOSEOUT.md` y salen del contexto activo.
