---
name: roadmap-triage
roles: [portfolio-curator, researcher]
output: estado reconciliado y próximo corte ejecutable
---

# Workflow — triage y reconciliación

1. Leer el roadmap, su `next_task`, el código señalado y los commits posteriores a `last_verified_commit`.
2. Clasificar cada afirmación como verificada, desactualizada, bloqueada o no decidida.
3. Retirar falsos pendientes ya implementados y falsos cierres sin evidencia.
4. Reducir la cola a un `next_task` y hasta tres tareas `ready`.
5. Declarar dependencias y decisiones que realmente requieren intervención humana.
6. Actualizar metadata y ejecutar `scripts/roadmap.ps1 check` e `index`.
