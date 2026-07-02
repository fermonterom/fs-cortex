---
name: cx-feedback-auto
description: "[DEPRECATED v4] Agent self-rating on tool-choice reflexes — emits feedback with source=agent"
command: true
---

# /cx-feedback-auto — DEPRECATED en v4.0.0

Este comando fue eliminado en el set v4 (docs/DESIGN-V4.md).

**Sin sustituto directo.** Razón: el self-rating del agente sobre reflexes no sobrevive a la simplificación v4 (ver DESIGN-V4 §5).

Mapeo: cx-analyze/cx-distill/cx-dream/cx-promote/cx-backfill → /cx-maintain (mantenimiento determinista). cx-validate/cx-evolve/cx-downvote/cx-retro → /cx-review (digest humano semanal). cx-timeline/cx-dashboard/cx-export → /cx-status. cx-audit → workflow `cortex-audit`. cx-feedback/cx-feedback-auto/cx-router/cx-stop → eliminados sin sustituto (razón en DESIGN-V4 §5).

Al ejecutarse, este stub SOLO imprime este aviso. No ejecuta ninguna lógica antigua.
