---
name: roadmap-triage
description: reconciliar un roadmap con código y Git antes de priorizarlo o retomarlo
triggers: [roadmap, triage, priorizar roadmap, retomar roadmap, estado real]
tools: [read_file, search, run, apply_patch]
---

# Triage de roadmaps

## Procedimiento

1. Leer `roadmaps/README.md`, `roadmaps/AGENTS.md`, el roadmap elegido y sólo su `next_task`.
2. Obtener `git status --short --branch`, `HEAD` y los commits relevantes posteriores a `last_verified_commit`.
3. Contrastar milestones y bloqueos con código, tests y evidencia ejecutable.
4. Retirar falsos pendientes o falsos cierres; reducir la cola a una tarea siguiente y hasta tres `ready`.
5. Actualizar metadata, estado verificado, `now`, `next_gate` y `next_task`.
6. Ejecutar `scripts/roadmap.ps1 check`, `index` y `git diff --check`.

No usar archivos históricos como backlog autoritativo salvo que la tarea los enlace como evidencia.
