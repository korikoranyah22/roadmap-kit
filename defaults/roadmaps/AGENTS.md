# Contrato operativo de roadmaps

Estas reglas aplican a todo `roadmaps/`.

## Jerarquía de autoridad

1. Código, migraciones, tests y evidencia ejecutable describen lo que existe.
2. El `README.md` de cada roadmap describe el estado, el orden y los gates abiertos.
3. La tarea enlazada por `next_task` describe el siguiente corte ejecutable.
4. `research/`, `decisions/` y `evidence/` aportan soporte; no cambian el estado por sí solos.
5. `pending/`, `specs/`, spikes históricos y `archive/` nunca reabren trabajo automáticamente.

Si código y roadmap difieren, revalidar y corregir el roadmap. Nunca adaptar la documentación para fingir que lo ya construido cumple un gate distinto.

## Estados

Roadmaps abiertos:

- `proposed`: falta definir resultado o gate de cierre.
- `ready`: está diseñado y puede iniciarse.
- `active`: pertenece al foco actual; puede estar momentáneamente ocioso con su `next_task` en `ready`.
- `blocked`: no puede avanzar sin una decisión o cambio externo identificado.
- `paused`: es válido, pero se decidió no invertir atención ahora.

Tareas:

- `planned`, `ready`, `doing`, `blocked`; `done` conserva evidencia aceptada hasta archivar el roadmap.
- Sólo una tarea `doing` por roadmap.
- Mantener como máximo tres tareas `ready`; el resto permanece como milestone.

Límite global: hasta dos roadmaps `active` de lane `feature` y uno `active` de lane `maintenance`.

`depends_on` expresa un bloqueo duro entre roadmaps abiertos. Un roadmap con dependencias abiertas debe
permanecer `paused`, `blocked` o `proposed`; las relaciones informativas se describen en prosa, no en ese campo.

## Lectura mínima

Para retomar trabajo, leer solamente:

1. `roadmaps/README.md`;
2. el `README.md` del roadmap elegido;
3. su `next_task`;
4. los archivos que esa tarea enlace explícitamente.

No reconstruir la historia recorriendo commits o documentos antiguos salvo que la tarea sea de triage o la evidencia actual sea contradictoria.

## Actualizaciones atómicas

Una implementación y su estado se actualizan en el mismo cambio. Al cerrar una tarea:

- registrar comandos y resultados reales, no “debería pasar”;
- resumir el resultado en el milestone correspondiente;
- retirar la tarea de `tasks/` o dejarla marcada hasta que el cierre del roadmap la archive;
- seleccionar una nueva `next_task` o cambiar el roadmap a `blocked`, `paused` o `closed` mediante el workflow apropiado.

`roadmaps/README.md` es generado por `scripts/roadmap.ps1 index`; no editar su tabla a mano.
