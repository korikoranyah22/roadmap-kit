---
name: roadmap-delivery
roles: [portfolio-curator, implementer, verifier]
output: tarea verificada y roadmap actualizado
---

# Workflow — entrega de una tarea

1. **Selección:** `portfolio-curator` confirma que la tarea coincide con `next_task`, dependencias y límite de WIP.
2. **Revalidación:** `implementer` contrasta el contexto mínimo con `HEAD`; si cambió una premisa, vuelve a triage.
3. **Red:** cuando el comportamiento admite regresión, crear primero la evidencia fallida con `bug-reproducer` o `test-author`.
4. **Implementación:** cargar `executor_skill` y realizar sólo el alcance declarado.
5. **Verificación focal:** ejecutar todos los comandos de la tarea.
6. **Verificación proporcional:** build y suites afectadas; no ocultar fallos preexistentes.
7. **Revisión independiente:** `verifier` comprueba criterios contra diff, código y resultados, no contra el resumen del implementador.
8. **Persistencia:** completar evidencia, milestone, `now`, `next_gate`, `next_task`, `updated` y `last_verified_commit`.
9. **Consistencia:** ejecutar `scripts/roadmap.ps1 check` e `index`.

Una tarea sólo pasa a hecha cuando los criterios y la evidencia coinciden. Un resultado parcial vuelve a `ready` o `blocked` con la diferencia exacta.
