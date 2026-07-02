---
name: cx-timeline
description: "[DEPRECATED v4] View the semantic knowledge log — every knowledge-changing event in Cortex"
command: true
---

# /cx-timeline — DEPRECATED en v4.0.0

Este comando fue absorbido por el set v4 (docs/DESIGN-V4.md).

**Usa en su lugar:** `/cx-status` — el dashboard de texto ya incluye últimas promociones y próximo maintain; es la superficie de lectura oficial.

Mapeo: cx-analyze/cx-distill/cx-dream/cx-promote/cx-backfill → /cx-maintain (mantenimiento determinista). cx-validate/cx-evolve/cx-downvote/cx-retro → /cx-review (digest humano semanal). cx-timeline/cx-dashboard/cx-export → /cx-status. cx-audit → workflow `cortex-audit`. cx-feedback/cx-feedback-auto/cx-router/cx-stop → eliminados sin sustituto (razón en DESIGN-V4 §5).

Al ejecutarse, este stub SOLO imprime este aviso y el comando sustituto. No ejecuta ninguna lógica antigua.
