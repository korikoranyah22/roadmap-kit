---
name: roadmap-verify
description: revisar si una tarea o gate está realmente cerrado contra evidencia ejecutable
triggers: [verificar roadmap, revisar gate, aceptar tarea, cierre de milestone]
tools: [read_file, search, run, apply_patch]
---

# Verificar una tarea o gate

## Procedimiento

1. Leer roadmap, tarea, criterios y evidencia sin tomar el resumen del implementador como prueba.
2. Inspeccionar diff y estado Git; trazar cada criterio al artefacto o comando exacto.
3. Reejecutar comandos focales y la suite proporcional al riesgo.
4. Buscar invariantes rotas, flags apagados, caminos alternativos y documentación contradictoria.
5. Aceptar, devolver a `ready` con diferencia concreta o marcar `blocked` con condición externa.
6. Si se acepta, registrar evidencia y ejecutar `scripts/roadmap.ps1 check`, `index` y `git diff --check`.

Un happy path no cierra criterios que también exigen aislamiento, rollback o portabilidad.
