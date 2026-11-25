---
name: roadmap-execute
description: implementar la next_task de un roadmap abierto manteniendo alcance, evidencia y estado sincronizados
triggers: [ejecutar roadmap, implementar next task, continuar roadmap, siguiente corte]
tools: [read_file, search, apply_patch, run]
---

# Ejecutar una tarea de roadmap

## Procedimiento

1. Leer `roadmaps/AGENTS.md`, el roadmap y únicamente su `next_task`.
2. Cargar `executor_skill`, `verification_skills` y las fuentes enlazadas por la tarea.
3. Cambiar la tarea a `doing` antes del primer cambio material.
4. Crear evidencia roja primero cuando el comportamiento admite regresión.
5. Implementar sólo el alcance declarado y ejecutar todos los comandos de verificación.
6. Completar evidencia, milestone, `now`, `next_gate`, `next_task`, `updated` y `last_verified_commit`.
7. Ejecutar `scripts/roadmap.ps1 check`, `index` y `git diff --check`.

Una tarea parcial vuelve a `ready` o `blocked` con la diferencia exacta; compilar no basta para marcarla `done`.
