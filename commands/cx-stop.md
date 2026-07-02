---
name: cx-stop
description: "[DEPRECATED v4] Close current session cleanly — flush observations and run Stop hook"
command: true
---

# /cx-stop — DEPRECATED en v4.0.0

Este comando fue eliminado en el set v4 (docs/DESIGN-V4.md).

**Sin sustituto directo.** Razón: el cierre manual de sesión queda cubierto por `/cx-eod` (acumulativo 24h) y el propio hook Stop del harness (ver DESIGN-V4 §5).

Mapeo: cx-analyze/cx-distill/cx-dream/cx-promote/cx-backfill → /cx-maintain (mantenimiento determinista). cx-validate/cx-evolve/cx-downvote/cx-retro → /cx-review (digest humano semanal). cx-timeline/cx-dashboard/cx-export → /cx-status. cx-audit → workflow `cortex-audit`. cx-feedback/cx-feedback-auto/cx-router/cx-stop → eliminados sin sustituto (razón en DESIGN-V4 §5).

Al ejecutarse, este stub SOLO imprime este aviso. No ejecuta ninguna lógica antigua.
