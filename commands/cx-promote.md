---
name: cx-promote
description: "[DEPRECATED v4] Promote project-scoped instincts to global when detected in multiple projects"
command: true
---

# /cx-promote — DEPRECATED en v4.0.0

Este comando fue absorbido por el set v4 (docs/DESIGN-V4.md).

**Usa en su lugar:** `/cx-maintain` — la promoción determinista project→global (§3 del diseño) corre dentro del mantenimiento cron-able.

Mapeo: cx-analyze/cx-distill/cx-dream/cx-promote/cx-backfill → /cx-maintain (mantenimiento determinista). cx-validate/cx-evolve/cx-downvote/cx-retro → /cx-review (digest humano semanal). cx-timeline/cx-dashboard/cx-export → /cx-status. cx-audit → workflow `cortex-audit`. cx-feedback/cx-feedback-auto/cx-router/cx-stop → eliminados sin sustituto (razón en DESIGN-V4 §5).

Al ejecutarse, este stub SOLO imprime este aviso y el comando sustituto. No ejecuta ninguna lógica antigua.
