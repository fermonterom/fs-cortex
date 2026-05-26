# Sprint 9 — Autopilot Promotion Gate + Cleanup Bugs (v3 FINAL)

**Status:** ✅ v3 FINAL — AD Codex GPT-5.5 round 1 absorbido (4 P0 + 7 P1 + 3 P2). Listo para implementación PR1.
**Author:** sesión 2026-05-25 (post `/cx-analyze` + `/cx-validate`).
**Target release:** **v3.32.0** (minor, alcance grande — todo en un release).
**Operator UX goal:** sistema autopiloto real (auto-analyze + promotion HUMAN→AUTO) + cero bugs known en producción.

---

## 0. Origen del plan

Sprint 8 (v3.29.0) entregó el **detector overhaul**: 5 detectores reescritos / retirados, ghost guard, kill switches, banner fix, PreCompact hardening, multi-session promotion gate, acceptance gate. Plan §5 prometía un v3.30.0 que cerrase el ciclo con **autopilot real** (analyze_engine + promotion estadístico). **v3.30 NUNCA SE PUBLICÓ.** El sistema sufrió 5 hotfixes (v3.29.1 → v3.29.5) y un pivot (v3.31.0 trajo Sinapsis context.md format), saltándose la numeración v3.30 entera.

`/cx-analyze` ejecutado en esta sesión sobre 8767 observations / 70 sesiones / 43 días detectó **10 patrones nuevos** (9 aceptados como instincts) que confirman bugs reales en el sistema actual. Este plan los unifica con el v3.30 pendiente en un solo Sprint 9 → v3.32.0.

---

## 1. Estado actual (post-v3.31.1, 2026-05-25)

**Versión activa:** v3.31.1 (`install.sh` NEW_VERSION="3.31.1", `docs/FEATURES.md` header v3.31.1).

**Tags publicados desde Sprint 8:** v3.29.0 → v3.29.1 → v3.29.2 → v3.29.3 → v3.29.4 → v3.29.5 → **v3.31.0** → v3.31.1. (NO existe v3.30.x.)

**Cortex en vivo:**
- 12 active laws — **cap saturado** (LAW_MAX_ACTIVE=12 desde v3.29.2).
- 323 active instincts (125 global + 198 project) tras el `/cx-validate` de esta sesión.
- 278 pending proposals (227 HUMAN-gated `correction`/`coupling` + ~42 AUTO `error-recovery`/`agent-evolution`).
- 215 líneas en `auto-distill-candidates.md` (~50 instincts bloqueados de subir a law).
- 5 backups `proposals.json.bak-*` sin archivar (`tests/archive_proposals_backups.sh` existe pero nadie lo invoca).

**Lo que funciona y NO se toca:**
- Detectores activos: `detectErrorResolutions`, `detectUserCorrections`, `detectAgentPatterns`, `detectAgentSubtypes`, `detectFileCoupling`, `detectTimeOfDayPatterns`, `detectCommandUsage`.
- Sinapsis context.md format (v3.31.0) → reduce el writer a ≤ 500 bytes.
- 3 kill switches (`CORTEX_OBSERVE_OFF`, `CORTEX_DETECTORS_OFF`, `CORTEX_AUTODISTILL_OFF`).
- Ghost guard, multi-session promotion gate (con bug edge-case ver §2).
- Pre-push acceptance gate (`test_v329_acceptance.sh`).

**Lo que sigue roto / pendiente:**
- §5.1-5.3 del plan Sprint 8 (analyze_engine, auto-analyze trigger, promotion HUMAN→AUTO).
- 5 bugs concretos detectados al revisar la data en vivo (§2).
- 1 patrón skipped en `/cx-validate` por falta de refinamiento (`pattern-cortex-laws-cap-saturation`).

---

## 2. Diagnóstico técnico

### 2.1 Bugs encontrados revisando data viva

| # | Bug | Evidencia |
|---|-----|-----------|
| B1 | `§4.16 grandfather` edge case: instincts con `tracking_entry` presente pero `sessions: []` vacío NO se grandfatherizan. Quedan bloqueados con "sessions 0/3" pese a conf=0.95. | `gotcha-api-route-error-message-leak` conf=0.95 + `fersora-fs-codex-rescue-ad-trigger` conf=0.95, ambos blocked en `auto-distill-candidates.md`. |
| B2 | Ruido elevado sobre instincts conf=0.99 con triggers muy amplios. | `read-instructions-before-executing` noise=8 / 14d, `gotcha-Read-0b8111c8` noise=4, `pattern-test-after-change` noise=2, `cat-pipe-head-claudemd-anti` noise=2. |
| B3 | 42 AUTO pending proposals no son procesadas por `auto_validate_proposals` (corre 1×/24h, los proposals tienen conf ≥ 0.50 y domain whitelisted; held=0). Hay un gate silencioso. | `[ACTION] 42 pending proposals` en SessionStart banner. |
| B4 | 5 backups `proposals.json.bak-*` acumulados en 30 días. El script `tests/archive_proposals_backups.sh` existe pero no se cablea. | `ls ~/.claude/cortex/proposals.json.bak*` muestra 5 ficheros. |
| B5 | Laws cap 12/12 saturado. Promotion candidates con conf=0.99 quedan eternamente bloqueados por "laws == 12". Sin política de deprecación. | `auto-distill-candidates.md` muestra varios con "law already exists" Y nuevos bloqueados sin avenida de promoción. |

### 2.2 Items pendientes del plan Sprint 8 §5

| § | Item | Estado |
|---|------|--------|
| 5.1 | `hooks/lib/analyze_engine.py` (Opción C — no-op sin Opus 1M) | ❌ NO existe |
| 5.2 | Trigger auto-analyze en `session-start.py` step 3e | ❌ NO existe `.last-auto-analyze` marker |
| 5.3 | `can_promote_to_auto(detector_id)` + integración | ❌ NO existe |
| 5.4 | Sinapsis decision + cherry-pick | ✅ HECHO en v3.31.0 (context.md format) |

### 2.3 Items diferidos por refinamiento (skip en /cx-validate)

| Skip ID | Motivo | Acción en Sprint 9 |
|---------|--------|--------------------|
| `pattern-cortex-laws-cap-saturation` | Acción "adoptar política deprecation" demasiado vaga. | Refinar como §4.X con algoritmo objetivo (impact metrics, last_seen window). |

---

## 3. Decisiones de diseño (confirmadas 2026-05-25)

| # | Decisión | Opción elegida | Notas |
|---|----------|----------------|-------|
| D1 | `analyze_engine.py` invocación | **B inline si Opus 1M activo, sino `.learn-pending`** | Sin spawn de sub-Agent. Determinístico se ejecuta en la sesión actual cuando Opus 1M; sino solo se prepara `.learn-pending` marker. |
| D2 | Trigger auto-analyze cadencia | **A: 20h fixed + 50 obs floor** | Sprint 8 design ya validado. |
| D3 | Promotion HUMAN→AUTO threshold | **A: `n≥20 + accept≥70% + sessions≥3 + critical=0`** | Statistical strict. Mejor falso negativo (no promueve) que falso positivo (promueve ruido). |
| D4 | Laws cap policy | **A + subir cap 12→15** | **Híbrido**: (a) subir `LAW_MAX_ACTIVE = 15` para dar espacio inmediato a candidates bloqueados, (b) añadir algoritmo de deprecación para cuando se sature de nuevo (futuro 15/15). |
| D5 | `archive_proposals_backups.sh` wiring | **A: `/cx-dream` weekly cycle** | Consistente con el resto del pipeline. |
| D6 | Sinapsis 2ª ola | **B: SKIP** | 1ª ola ya entregó valor (context.md format en v3.31.0). No hay tiempo para investigación nueva ahora. |

---

## 4. Plan v3.32.0 — Sprint 9 atomic

### 4.1 Bug fixes (rápidos, sin features)

#### §4.1.A — Grandfather edge case (B1)

**File:** `hooks/lib/distill_engine.py:auto_promote_to_law` (alrededor línea ~660).

**Cambio:** extender la cláusula grandfather con check **explícito** `sessions == []` (AD P1-1: NO grandfather sobre `sessions: null` ni missing field — eso oculta corrupción de tracking).

```python
# Antes (v3.29.0 §4.16):
if not has_tracking_entry and conf >= LAW_THRESHOLD_CONF:
    distinct_sessions = LAW_MIN_DISTINCT_SESSIONS  # grandfathered

# Después (v3.31.2 §4.1.A — narrow per AD P1-1):
entry = tracking_data.get(iid)
no_meaningful_tracking = (
    not has_tracking_entry  # caso 1: entrada ausente (pre-v3.29 corpus)
    or (isinstance(entry, dict) and entry.get('sessions') == [])
    #                                            ^^^ explicit [] only
    # NO captura: sessions=null, missing 'sessions' key, sessions=0,
    # sessions='string' — esos casos siguen bloqueando para que el
    # operador detecte corrupción
)
if no_meaningful_tracking and conf >= LAW_THRESHOLD_CONF:
    distinct_sessions = LAW_MIN_DISTINCT_SESSIONS  # grandfathered
```

**Tests** (3 ramas + 2 negativos = 5 casos en `tests/test_distill_engine.sh`):
- ✅ entry ausente + conf=0.95 → promueve (grandfather caso 1)
- ✅ entry con `sessions: []` + conf=0.95 → promueve (grandfather caso 2)
- ✅ entry con `sessions: ['a','b','c']` + conf=0.95 → promueve (path normal)
- ❌ entry con `sessions: null` + conf=0.95 → NO promueve, blocked "sessions 0/3"
- ❌ entry sin key 'sessions' + conf=0.95 → NO promueve, blocked "sessions 0/3"

#### §4.1.B — AUTO pending instrumentation (B3, AD P1-4 absorbido)

**Scope:** instrumentation-only fix. NO cambio de comportamiento. NO ventana de observación 24-48h (AD P1-4 detectó que la ventana entraba en conflicto con el sequencing del Sprint). La investigación "por qué 42 pending no se procesan" se contesta SOLA después de 7 días de logs post-merge → candidato v3.33+.

**File:** `hooks/lib/distill_engine.py:auto_validate_proposals`.

**Cambio:** añadir tracking de skip-reasons agregado + persistencia a log file (NO stderr, NO contamination del SessionStart parent hook):

```python
from collections import Counter

def auto_validate_proposals(dry_run: bool = False) -> dict:
    skip_reasons = Counter()
    # ... lógica existente ...
    for p in proposals:
        if p.get('status') != 'pending':
            skip_reasons['not-pending'] += 1
            continue
        # En CADA continue/skip dentro del loop, agregar al Counter
        # con la razón concreta: low-confidence, already-instinct,
        # needs-human-judgment, unsafe-trigger, missing-trigger, etc.
        # ...

    # Persistir breakdown a fichero rotado, NO stdout/stderr
    log_path = CORTEX_DIR / 'log' / 'auto-validate-skips.jsonl'
    log_path.parent.mkdir(parents=True, exist_ok=True)
    with open(log_path, 'a', encoding='utf-8') as fh:
        fh.write(json.dumps({
            'ts': _dt.datetime.now(_dt.timezone.utc).isoformat(),
            'total': len(proposals),
            'skip_breakdown': dict(skip_reasons),
        }) + '\n')

    return {
        'accepted': accepted,
        'skipped': skipped,
        'ghost_restored': ghost_restored,
        'skip_breakdown': dict(skip_reasons),  # NEW: return value
    }
```

**Rotation:** `auto-validate-skips.jsonl` rotado a `.1` cuando > 512KB (mismo patrón que `session-learner.log`).

**Test:** `tests/test_distill_engine.sh` +2 casos:
- 4 proposals (1 each: not-pending, low-conf, needs-human, accepted) → `skip_breakdown` contiene las 3 razones de skip correctas + 1 aceptado
- Log file aparece en `CORTEX_DIR/log/auto-validate-skips.jsonl` tras 1 run con append correcto

#### §4.1.C — Backup archive wiring (B4)

**File:** `hooks/lib/dream_cycle.py` (o el comando `/cx-dream`).

**Cambio:** añadir step 3d (después del cleanup de context.md):
```python
# v3.32.0 §4.1.C: archive proposals.json backups weekly
if _file_older_than(CORTEX_DIR / '.last-proposals-archive', days=7):
    import subprocess
    subprocess.run(
        ['bash', str(REPO_ROOT / 'tests' / 'archive_proposals_backups.sh')],
        check=False, timeout=30,
    )
    (CORTEX_DIR / '.last-proposals-archive').touch()
```

**Test:** `tests/test_dream_cycle.sh` + 2 casos (first-run archives, second-run within 7d skips).

### 4.2 + 4.3 — DEFERRED a v3.33+ (AD P0-2 + P0-3 absorbidos)

**Decisión post-AD:** los 2 features del plan Sprint 8 §5.1/§5.2 (`hooks/lib/analyze_engine.py` + auto-analyze trigger en SessionStart) NO se entregan en v3.32.0.

**Por qué se difieren:**
- **AD P0-2** detectó que el diseño "queue-only" contradice la promesa "autopilot real" — sería un recordatorio glorificado, no automatización.
- **AD P0-3** detectó que `_is_opus_1m_active()` no tiene API testeable desde hooks deterministas. No hay forma de detectar el flag `[1m]` de la sesión Claude Code en runtime.
- Sprint 9 mantiene foco realista: 3 bug fixes + 2 features sólidos (promotion gate + laws cap), en lugar de 3 features a medio terminar.

**Trade-off aceptado:** el `[ACTION]` reminder `Run /cx-analyze to detect patterns` SE QUEDA como recurso manual del operador. Los 8767 obs / 70 sesiones de fs-cortex demostraron que el flujo manual funciona (`/cx-analyze` de esta sesión generó 10 proposals nuevos sin friction).

**Reentrada en v3.33+ (post-7d-medición):**
- Diseño concreto basado en datos de los `auto-validate-skips.jsonl` logs (§4.1.B).
- Mecanismo de "Opus 1M detection" definido: env var explícita o marker que el operador configura una vez, NO inferencia desde el hook.
- Spec del consumer del queue (si se mantiene el patrón queue) definido ANTES del producer.

### 4.4 Feature: Promotion HUMAN→AUTO con gate estadístico (§5.3 Sprint 8 + 4 P0/P1 absorbidos)

#### 4.4.a Source of truth: `proposals-history.jsonl` (AD P0-1)

**File a leer:** `~/.claude/cortex/proposals-history.jsonl` (storage split v3.29.5). `proposals.json` SÓLO tiene los vivos (status=pending). El histórico de accepts/rejects vive en el JSONL.

**Schema esperado** (verificar en runtime, fail-closed si no cuadra):
```jsonl
{"id":"...","status":"accepted","source":"session-learner:correction","accepted_at":"2026-05-19","accepted_by":"cx-validate","session_id":"<uuid>","rejection_category":null}
{"id":"...","status":"rejected","source":"session-learner:coupling","rejected_at":"2026-05-20","rejected_by":"cx-validate","rejection_category":"noise","rejected_reason":"too vague"}
```

#### 4.4.b `can_promote_to_auto()` + visibility tier (AD P1-2)

**File NEW:** `hooks/lib/distill_engine.py:can_promote_to_auto` (function).

```python
PROMOTE_REVIEW_THRESHOLD = 10   # n=10 → visible en /cx-status (NOT promotion)
PROMOTE_AUTO_THRESHOLD = 20     # n=20 → eligible para AUTO promotion
PROMOTE_ACCEPT_RATE = 0.70
PROMOTE_MIN_SESSIONS = 3

def can_promote_to_auto(detector_source: str) -> tuple[bool, str, dict]:
    """Check HUMAN→AUTO promotion eligibility.

    Returns (eligible, reason, stats). `eligible` is True only when ALL 4
    gates pass at the AUTO threshold (n>=20). Below 20 but >=10 returns
    (False, 'visible-only', stats) so /cx-status can surface progress
    without triggering promotion.
    """
    history = _load_proposals_history()   # NEW reader, fail-closed → []
    reviewed = [p for p in history
                if p.get('source') == detector_source
                and p.get('status') in ('accepted', 'rejected')]
    stats = {
        'reviewed_count': len(reviewed),
        'accept_count': sum(1 for p in reviewed if p.get('status') == 'accepted'),
        'distinct_sessions': len({p.get('session_id','') for p in reviewed
                                   if p.get('session_id')}),
        'critical_count': _count_critical_rejections(reviewed),
    }

    if stats['reviewed_count'] < PROMOTE_REVIEW_THRESHOLD:
        return False, f'reviewed {stats["reviewed_count"]}/10 (need review tier)', stats
    if stats['reviewed_count'] < PROMOTE_AUTO_THRESHOLD:
        return False, f'visible-only ({stats["reviewed_count"]}/20)', stats

    accept_rate = stats['accept_count'] / stats['reviewed_count']
    if accept_rate < PROMOTE_ACCEPT_RATE:
        return False, f'accept_rate {accept_rate:.2f} < 0.70', stats
    if stats['distinct_sessions'] < PROMOTE_MIN_SESSIONS:
        return False, f'distinct_sessions {stats["distinct_sessions"]} < 3', stats
    if stats['critical_count'] > 0:
        return False, f'critical_rejections {stats["critical_count"]} > 0', stats
    return True, 'all-gates-pass', stats
```

#### 4.4.c `rejection_category` enum opcional + fallback heuristic (AD P1-6)

**Schema breaking change:** rejects nuevos via `/cx-validate` escriben `rejection_category: security|breaking|injection|noise|other`. Rejects legacy no tienen el campo. `_count_critical_rejections` checkea **(a) enum first, (b) heuristic fallback** ES+EN.

```python
CRITICAL_CATEGORIES = {'security', 'breaking', 'injection'}
CRITICAL_KEYWORDS_FALLBACK = (
    # ES
    'seguridad', 'inseguro', 'rompedor', 'inyecci', 'breaking change',
    # EN
    'security', 'breaking', 'injection', 'unsafe', 'vulnerab',
)

def _count_critical_rejections(reviewed: list[dict]) -> int:
    n = 0
    for p in reviewed:
        if p.get('status') != 'rejected':
            continue
        cat = p.get('rejection_category')
        if cat in CRITICAL_CATEGORIES:
            n += 1
            continue
        if cat is None:  # legacy reject without enum
            reason = (p.get('rejected_reason') or '').lower()
            if any(kw in reason for kw in CRITICAL_KEYWORDS_FALLBACK):
                n += 1
    return n
```

**File:** `commands/cx-validate.md` extender Step 4b para que el operador escoja categoría en cada reject (4 opciones + skip-categoria-keep-legacy).

#### 4.4.d Marker file `.promoted-detectors.json` — fail-closed (AD P0-4)

**Schema estricto:**
```json
{
  "version": 1,
  "promoted": [
    {
      "source": "session-learner:correction",
      "since": "2026-06-15T10:00:00Z",
      "approved_by": "operator",
      "gate_snapshot": {
        "reviewed_count": 24,
        "accept_count": 19,
        "accept_rate": 0.79,
        "distinct_sessions": 4
      }
    }
  ]
}
```

**Reader:**
```python
def _load_promoted_detectors() -> set[str]:
    """Fail-closed: any parse/schema error → empty set (todas HUMAN).

    NEVER silently treats invalid markers as authorization.
    """
    path = CORTEX_DIR / '.promoted-detectors.json'
    if not path.exists():
        return set()
    try:
        data = json.loads(path.read_text(encoding='utf-8'))
        if not isinstance(data, dict) or data.get('version') != 1:
            log_security_event('promoted-detectors:invalid-schema', path)
            return set()
        promoted = data.get('promoted', [])
        if not isinstance(promoted, list):
            log_security_event('promoted-detectors:invalid-promoted', path)
            return set()
        result = set()
        for entry in promoted:
            if not isinstance(entry, dict):
                continue
            src = entry.get('source', '')
            # Validate source matches the detector pattern (no injection)
            if not re.fullmatch(r'[a-z][a-z0-9:_-]{2,80}', src or ''):
                log_security_event('promoted-detectors:invalid-source', src)
                continue
            since = entry.get('since', '')
            try:
                _dt.datetime.fromisoformat(since.replace('Z', '+00:00'))
            except (ValueError, TypeError):
                log_security_event('promoted-detectors:invalid-since', src)
                continue
            result.add(src)
        return result
    except (OSError, json.JSONDecodeError) as e:
        log_security_event('promoted-detectors:read-error', str(e))
        return set()
```

**Writer:** ÚNICO entrypoint `/cx-promote --auto <source> --confirm`. NO escrito automáticamente por el engine. NO escrito por `auto_promote_to_law`. NO escrito por `auto_validate_proposals`. El operador es el único actor con autoridad.

**File NEW:** `commands/cx-promote.md` extender con flag `--auto <source>` + obligatorio `--confirm`.

#### 4.4.e Integración en `auto_validate_proposals`

Cuando se evalúa una proposal con domain HUMAN-gated, comprobar si su `source` está en `_load_promoted_detectors()`. Si está, tratar el domain como AUTO para esta proposal (auto-validate). Si no, comportamiento actual (skip needs-human-judgment).

```python
# v3.32.0 §4.4.e
promoted_sources = _load_promoted_detectors()
# ... loop principal ...
source = p.get('source', '')
if domain in VALIDATE_HUMAN_DOMAINS and source not in promoted_sources:
    skipped.append({'id': iid, 'reason': 'needs-human-judgment'})
    continue
# Si source ∈ promoted_sources, falla-abierto a AUTO path
```

#### 4.4.f Tests

**`tests/test_promotion_gate.sh` NEW (8 casos):**
1. Source not in history → `(False, 'reviewed 0/10', ...)`
2. n=10 reviewed, all accept → `(False, 'visible-only (10/20)', ...)` ← P1-2 tier
3. n=20 reviewed, accept_rate=0.65 → `(False, 'accept_rate 0.65 < 0.70', ...)`
4. n=20 reviewed, accept_rate=0.80, 2 distinct sessions → `(False, 'distinct_sessions 2 < 3', ...)`
5. n=20, 80%, 3 sessions, 1 critical (enum) → `(False, 'critical_rejections 1', ...)`
6. n=20, 80%, 3 sessions, 1 critical (heuristic legacy "seguridad") → `(False, 'critical_rejections 1', ...)` ← P1-6 fallback
7. All gates pass → `(True, 'all-gates-pass', stats)`
8. Marker file parse fail → empty set (fail-closed) ← P0-4

**Extender `test_v329_acceptance.sh` → `test_v332_acceptance.sh`** con assert e2e (instinct `gotcha-ad-por-fase-no-sustituye-e2e`):
- Fixture `proposals-history.jsonl` 25 entradas de un source ficticio
- `/cx-promote --auto session-learner:fake-test --confirm` → marker file escrito
- `auto_validate_proposals` corre con proposal del mismo source domain HUMAN → AHORA se acepta
- Manipular el marker (JSON inválido) → todos los proposals HUMAN vuelven a skip (fail-closed verified)

### 4.5 Feature: Laws cap raise + deprecation policy (B5, D4 híbrido)

Decisión D4: aplicar **2 ejes en el mismo cambio**:

**Eje A — Subir cap 12 → 15** (alivio inmediato para candidates bloqueados HOY):

Files con la constante:
- `hooks/lib/distill_engine.py:83` — `LAW_MAX_ACTIVE = 12 → 15`
- `commands/cx-distill.md` — referencias "max 12" → "max 15" (línea 16, 99)
- `docs/FEATURES.md` — mention del cap
- `README.md` — sección Pipeline si menciona el número

(Cubierto por instinct `pattern-cortex-spec-doc-engine-trinity` — los 4 ficheros van en el mismo commit.)

**Eje B — Algoritmo de deprecación** (para cuando se sature 15/15 en el futuro):

**File:** `hooks/lib/distill_engine.py:auto_promote_to_law` (alrededor de la "Criteria 7" check).

```python
LAW_DEPRECATE_MIN_AGE_DAYS = 7  # AD P1-3: laws < 7d NO son candidatas

def _find_least_impactful_law(impact_per_iid: dict, days: int = 14):
    """Find the law most suitable for deprecation when cap is saturated.

    Heuristic: lowest (useful_14d / (1 + noise_14d)) ratio.
    Tie-break: oldest `last_seen` in the law's frontmatter.

    Returns law_id (filename stem) or None if no candidate qualifies.

    AD P1-3 absorbido: laws con `last_seen < 7 días` (recién promovidas)
    NO son candidatas. Sin esto, una law nueva sin impact data acumulada
    quedaría con ratio=0 y se marcaría para deprecation antes de tener
    chance de ejercerse.

    Edge cases:
      - law sin impact entries Y age >= 7d → ratio = 0 → top candidate (huérfana)
      - law sin impact entries Y age < 7d → SKIP (no candidata, AD P1-3)
      - law con useful=0 noise=0 Y age >= 7d → ratio = 0 → top candidate
      - todas las laws con ratio > 1.0 → return None (no deprecar productivas)
      - todas las laws < 7d edad → return None (cohort joven, esperar)
    """
    today = _dt.date.today()
    candidates = []
    for law_path in (LAWS_DIR.glob('*.txt') if LAWS_DIR.is_dir() else []):
        if 'archive' in str(law_path):
            continue
        iid = law_path.stem
        # Age guard (AD P1-3)
        last_seen = _read_law_last_seen(law_path)  # ISO date from frontmatter
        if last_seen is None:
            # No last_seen frontmatter → asumir hoy para safety
            continue
        age_days = (today - last_seen).days
        if age_days < LAW_DEPRECATE_MIN_AGE_DAYS:
            continue  # too fresh, skip
        # Impact ratio
        impact = impact_per_iid.get(iid, {'useful': 0, 'noise': 0})
        ratio = impact['useful'] / (1 + impact['noise'])
        candidates.append((ratio, last_seen, iid))

    if not candidates:
        return None
    # Sort: lowest ratio first, tie-break oldest last_seen
    candidates.sort(key=lambda x: (x[0], x[1]))
    best = candidates[0]
    if best[0] > 1.0:
        return None  # all laws productive, don't deprecate
    return best[2]

# In auto_promote_to_law, when cap saturated:
if active_laws >= LAW_MAX_ACTIVE:
    candidate = _find_least_impactful_law(impact)
    if candidate:
        failed_reasons.append(
            f'laws == {active_laws}/{LAW_MAX_ACTIVE} saturated; '
            f'would deprecate {candidate} via /cx-distill --swap'
        )
    else:
        failed_reasons.append(
            f'laws == {active_laws}/{LAW_MAX_ACTIVE} saturated; '
            f'no deprecation candidate (all productive OR < 7d age)'
        )
```

**File NEW (P1-7 absorbido):** implementación `/cx-distill --swap <to_deprecate>` requiere entrypoint concreto en `hooks/lib/distill_engine.py`:

```python
def manual_swap_promote(new_iid: str, deprecate_iid: str, dry_run=False):
    """Swap atomic: promote new_iid + archive deprecate_iid in one operation.

    Safety:
    - Pre-check: deprecate_iid existe en LAWS_DIR
    - Pre-check: new_iid es un instinct mature (conf>=0.95, sustained>=14d)
    - Backup: copia el law file a archive/ ANTES de crear el nuevo
    - Atomic: tmp+rename para evitar estado intermedio
    - Rollback: si la promoción del new falla, restaurar el old desde archive
    """
    # ... implementation ...
```

`commands/cx-distill.md` extender con `--swap <to_deprecate>` + obligatorio `--confirm`.

**Test:** `tests/test_distill_engine.sh` +6 casos (4 originales + 2 nuevos P1-3 + P1-7):
- cap raise 12→15: instinct n.13 que antes se bloqueaba ahora promueve
- `_find_least_impactful_law` devuelve el de menor ratio (mock impact data)
- `_find_least_impactful_law` tie-break por last_seen funciona
- swap promotes new + archives old (golden path)
- **NEW P1-3:** law con `last_seen` hace 3 días NO es candidata (skip por age guard)
- **NEW P1-7:** `manual_swap_promote` rollback funciona si new falla a mitad

### 4.6 Sprint doc retention policy (D5 sub-Q5: MANTENER)

**Decisión operador:** mantener los 3 docs históricos Sprint 8. La deletion del instinct `gotcha-sprint-doc-cleanup-after-ship` se difiere a v3.33+ cuando: (a) Sprint 9 esté cerrado, (b) haya pasado ≥1 minor sin referencias activas a estos docs.

**No-op en este Sprint:**
- `docs/SPRINT-8-DETECTOR-OVERHAUL.md` — mantener (referencia histórica activa)
- `docs/GHOST-CX-VALIDATE-AUTO.md` — mantener
- `docs/SINAPSIS-COMPARISON.md` — mantener

**Acción:** añadir TODO en `CHANGELOG.md` Removed-section del release v3.32.0 con texto:
```
- (deferred) docs/SPRINT-8-*.md, GHOST-*.md, SINAPSIS-*.md scheduled for
  deletion at v3.33+ once Sprint 9 retrospective is complete.
```

**Adicional:** `docs/SPRINT-9-AUTOPILOT.md` (este doc) debe whitelistearse en `.gitignore` para ser tracked en git (pattern: `!docs/SPRINT-9-AUTOPILOT.md` — consistente con cómo Sprint 8 docs están whitelisted).

### 4.7 Release flow — 2 bumps (PR1 + PR2)

#### PR1 — Release v3.31.2 (cierre Día 1)

Per `.claude/rules/release-workflow.md` + AD P2-2 (run test_integrity.sh):
- Bump 3.31.1 → 3.31.2 en 4 ficheros: `install.sh`, `install.ps1`, `docs/FEATURES.md`, `CHANGELOG.md`.
- CHANGELOG patch entry: §4.1.A grandfather, §4.1.B logging, §4.1.C dream archive wiring.
- `docs/FEATURES.md` row nuevo v3.31.2.
- Update `CLAUDE.md` Active sprint pointer → "Sprint 9 PR1 shipped, PR2 in flight".
- **AD P2-2 mandatory:** `bash tests/test_integrity.sh` + `bash tests/test_security.sh` + acceptance gate verde antes del tag.
- Tag v3.31.2 anotada + PR a main.

#### PR2 — Release v3.32.0 (cierre Día 3)

Per `.claude/rules/release-workflow.md`:
- Bump 3.31.2 → 3.32.0 en 4 ficheros.
- CHANGELOG minor entry completo: §4.4 promotion gate, §4.5 laws cap+deprecation, §4.6 docs retention (no-op), notas sobre §4.2/§4.3 diferidos.
- `docs/FEATURES.md` row nuevo v3.32.0.
- README.md actualizar sección Commands (nuevo `--auto` para `/cx-promote`, nuevo `--swap` para `/cx-distill`).
- Update `CLAUDE.md` Active sprint pointer → "Sprint 9 shipped en v3.32.0; v3.33+ medición 7d".
- **AD P2-2 mandatory:** `tests/test_integrity.sh` + `test_security.sh` + `test_v332_acceptance.sh` (renombrado) verdes.
- Tag v3.32.0 anotada + PR a main.
- **CHANGELOG note explícita:**
  ```markdown
  ### Notes
  - v3.30 nunca fue publicada (jumped 3.29.5 → 3.31.0 — see commit history).
  - §4.2 analyze_engine.py + §4.3 auto-analyze trigger deferred to v3.33+
    per AD P0-2/P0-3 (Sprint 9 plan §4.2+4.3 DEFERRED block).
  ```

---

## 5. Plan v3.33+ (post-medición 7d)

Tras shipping v3.32.0, **7 días de observación silenciosa** antes de planificar v3.33:

**Preguntas a contestar con datos reales post-merge:**
- ¿`can_promote_to_auto` empieza a recoger señal para los 3 detectores HUMAN-gated (correction, coupling, agent-quality)? Si > 10 reviewed después de 7 días → tier visibility activo; si > 20 → eligible para promoción manual.
- ¿Laws cap deprecation policy se invoca o sigue saturado a 15/15?
- ¿`/cx-distill` candidates queue se vacía gradualmente o sigue estancado?
- ¿`auto-validate-skips.jsonl` (logs §4.1.B) revela QUÉ skip reasons dominan los 42 AUTO pending estancados? Probable root cause: `low-confidence` (proposals con conf 0.50-0.55 borderline) o `already-instinct` (re-emisión de patterns ya capturados).

**Candidatos v3.33+ (en orden de prioridad):**

1. **§4.2 + §4.3 — Autopilot diferido de Sprint 9.**
   Re-diseñar con learning de 7d. Diseño concreto:
   - Mecanismo de "Opus 1M detection" via env var explícita `CORTEX_OPUS_1M=1` que el operador configura una vez en su `.zshrc` o `~/.claude/settings.json`. No inferencia desde el hook.
   - `analyze_engine.py` queue producer + spec del consumer ANTES de implementar.
   - Trigger en `session-start.py` step 3e con tests e2e que verifiquen la cadena completa.

2. **Investigación AUTO pending estancados (B3 root cause).**
   Lectura de `auto-validate-skips.jsonl` semanal + fix dirigido (subir conf floor, dedupe, etc).

3. **`/cx-evolve` automation:** tras 5+ instincts maduros del mismo domain, generar skill draft automático (extender `auto_evolve_detect` con thresholds finos).

4. **Cross-project promotion gate:** project-scoped instincts de fs-cortex que también aparezcan en fersora/LinkedIn deberían promoverse a global.

5. **Telemetry export:** panel HTML extendido con cohort analysis (instincts firing rate por proyecto, decay velocity, ratio histórico).

6. **Sprint 8/9 docs cleanup** (del instinct `gotcha-sprint-doc-cleanup-after-ship`): borrar `docs/SPRINT-8-DETECTOR-OVERHAUL.md` + `GHOST-*.md` + `SINAPSIS-*.md` + `SPRINT-9-AUTOPILOT.md` en el último commit del v3.33.

---

## 6. Decisiones del operador (confirmadas 2026-05-25)

| # | Pregunta | Respuesta | Reflejado en |
|---|----------|-----------|--------------|
| 1 | ¿Aprobar D1-D6 del §3? | **SÍ con matiz**: D4 = híbrido (cap 12→15 + algoritmo deprecation) | §3 + §4.5 reescrito |
| 2 | ¿Sprint 9 = 1 PR o 2 PRs? | **2 PRs**: PR1 bug fixes (Día 1), PR2 features + release (Día 2-3) | §8 sequencing |
| 3 | ¿Pre-implementation AD Codex GPT-5.5 sobre plan? | **SÍ** — review plan v2 + redacción Sprint 9 final tras incorporar findings | §11 trigger |
| 4 | ¿Aceptar `pattern-cortex-laws-cap-saturation` refinado como §4.5? | **SÍ** | §4.5 con algoritmo concreto |
| 5 | ¿Borrar 3 docs Sprint 8 ahora? | **NO — mantener** hasta v3.33+ | §4.6 reescrito |

### 6.b Decisiones post-AD Codex GPT-5.5 (confirmadas 2026-05-25)

Tras AD round 1 con verdict **REVISE** (4 P0 + 7 P1 + 3 P2), el operador confirmó las 7 remediation paths:

| # | AD finding | Remediation aplicada | Reflejado en |
|---|------------|----------------------|--------------|
| 1 | P0-1 source incorrecta | **SÍ** leer `proposals-history.jsonl` | §4.4.a |
| 2 | P0-2 queue-only contradice "autopilot real" | **OPCIÓN B** — diferir §4.2/§4.3 a v3.33+ | §4.2+4.3 DEFERRED block |
| 3 | P0-3 Opus 1M detection inviable | **SÍ** eliminar branch `_is_opus_1m_active()` | §4.2+4.3 DEFERRED (moot) |
| 4 | P0-4 marker schema sin definir | **SÍ** schema estricto + fail-closed + sólo `/cx-promote --auto --confirm` | §4.4.d |
| 5 | P1-2 n≥20 muy lento | **SÍ** umbral intermedio n=10 como **visibility tier** (no gate de promoción) | §4.4.b |
| 6 | P1-4 §4.1.B ventana 24-48h conflicta con sequencing | **KEEP §4.1.B como logging-only fix** sin ventana; investigación se difiere a v3.33+ | §4.1.B reescrito |
| 7 | P1-6 `critical_rejections` heuristic frágil | **ENUM opcional + fallback heuristic ES+EN** | §4.4.c |

**P1-1, P1-3, P1-5, P1-7, P2-1, P2-2, P2-3:** absorbidos sin necesidad de decisión operador (correcciones técnicas evidentes).

---

## 7. Risk register

| Riesgo | Prob | Impact | Mitigación |
|--------|------|--------|------------|
| §4.2/§4.3 diferidos crean expectativa rota ("autopilot real" sigue sin shippear) | media | bajo | CHANGELOG menciona el defer explícitamente; v3.33+ retoma con diseño concreto post-7d-data. |
| `can_promote_to_auto` thresholds demasiado estrictos → ningún detector promueve en 14 días | alta | bajo | Es el estado deseado durante observación. Tier n=10 visibility da feedback. Si tras 60 días ningún detector califica, relajar thresholds en v3.34+. |
| Laws cap deprecation policy borra una law importante por error | baja | alto | Algoritmo + age guard `>=7d` (AD P1-3) + `/cx-distill --swap` requiere `--confirm` + backup archive antes de borrar. |
| §4.1.B logging genera output ruidoso en SessionStart | baja | bajo | Log en fichero rotado `~/.claude/cortex/log/auto-validate-skips.jsonl`, NO stdout/stderr (AD P1-4). |
| §4.1.A grandfather edge case fix abre nuevo bug | baja | medio | Test cubre 5 ramas (3 positivos + 2 negativos: sessions:null y missing key NO grandfatherizan, AD P1-1). |
| `archive_proposals_backups.sh` se ejecuta en `/cx-dream` y borra backups útiles | baja | medio | Script tiene tar+sha256+manifest; nada se borra, solo se mueve a archive. |
| **NEW AD P0-4:** `.promoted-detectors.json` marker corrupto promueve `correction`/`coupling` a AUTO silenciosamente | media | **crítico** | **Fail-closed reader** (cualquier parse/schema error → empty set); writer ÚNICO en `/cx-promote --auto --confirm`. Test acceptance gate verifica fail-closed. |
| **NEW AD P1-6:** `rejection_category` enum breaking change para legacy rejects | baja | bajo | Field opcional; fallback heuristic ES+EN cubre legacy. NEW rejects via `/cx-validate` lo escriben; legacy pasa por fallback. |
| **NEW AD P0-1:** `can_promote_to_auto` leyendo `proposals.json` (no history) ve 0 reviewed → gate nunca dispara | baja (corregido en v3) | medio | v3 doc explícito: source = `proposals-history.jsonl` (storage split v3.29.5). Test fixture verifica. |
| AD Codex GPT-5.5 detecta P0 que retrasa el Sprint | media | bajo | Es el propósito; absorbido en v1→v2→v3 ya. Próxima ronda opcional si v4 emerge. |

---

## 8. Sequencing v3.32.0 (2 PRs, 3 días)

**Decisión Q2:** partir en 2 PRs para mantener review manejable y permitir merge incremental.

### PR1 — Bug fixes (Día 1, ~4h)

Branch: `release/v3.31.2` (patch bump 3.31.1 → 3.31.2). Si el AD round 2 detecta P0 en este lote, se absorbe sin tocar PR2.

| Sección | Cambio | Test |
|---------|--------|------|
| §4.1.A | Grandfather edge case fix (`sessions == []` explícito) | +5 casos `test_distill_engine.sh` (3 positivos + 2 negativos AD P1-1) |
| §4.1.B | AUTO pending skip_breakdown logging (NO behavior change) | +2 casos `test_distill_engine.sh` |
| §4.1.C | `archive_proposals_backups.sh` cableado a `/cx-dream` | +2 casos `test_dream_cycle.sh` |
| Release | Bump 3.31.1 → 3.31.2, CHANGELOG, tag, PR a main | `test_integrity.sh` + `test_security.sh` + `test_v329_acceptance.sh` verde (AD P2-2) |

Output: PR1 abierto, CI verde, merged a main antes de empezar PR2.

### PR2 — Features autopilot + release v3.32.0 (Día 2-3, ~9h)

Branch: `release/v3.32.0` (minor bump 3.31.2 → 3.32.0). Basada en main post-merge de PR1.

| Día | Sección | Cambio | Test |
|-----|---------|--------|------|
| Día 2 (5h) | §4.4 | `can_promote_to_auto()` reading `proposals-history.jsonl` + n=10 visibility tier + fail-closed marker + `rejection_category` enum + fallback + `/cx-promote --auto --confirm` | `test_promotion_gate.sh` NEW (8 casos) |
| Día 3 (4h) | §4.5 | `LAW_MAX_ACTIVE 12→15` + `_find_least_impactful_law` con age guard (AD P1-3) + `/cx-distill --swap --confirm` con rollback (AD P1-7) | `test_distill_engine.sh` +6 casos (4 originales + 2 P1-3/P1-7) |
| Día 3 (4h) | §4.6 | TODO en CHANGELOG Removed-section. `.gitignore` whitelist `!docs/SPRINT-9-AUTOPILOT.md` ya añadido | grep en post-release diff |
| Día 3 (4h) | E2E gate | Renombrar `test_v329_acceptance.sh` → `test_v332_acceptance.sh` + 2 asserts nuevos (instinct `gotcha-ad-por-fase-no-sustituye-e2e` mandatory, AD P1-5) | acceptance gate verde |
| Día 3 (4h) | §4.7 | Bump 3.31.2 → 3.32.0 (4 ficheros) + CHANGELOG completo + tag + PR | acceptance gate verde |

**Diferido a v3.33+:** §4.2 `analyze_engine.py` + §4.3 auto-analyze trigger (AD P0-2 / P0-3 — ver §4.2+4.3 DEFERRED block + §5).

### Día 0 (ya cerrado — esta sesión 2026-05-25) — pre-implementation

- ✅ AD Codex GPT-5.5 read-only sobre `docs/SPRINT-9-AUTOPILOT.md` v2 → findings JSON (4 P0 + 7 P1 + 3 P2)
- ✅ Incorporar findings → v3 (este doc)
- ⏸ Pendiente: confirmar arranque PR1 con prompt nueva sesión

### Total

**~13h en 3 días = presupuesto similar al Sprint 8 pero scope reducido (§4.2/§4.3 diferidos).**

Estimación tests (corrección AD P2-1, baseline real verificable):
- PR1 tests delta: +9 casos (5+2+2)
- PR2 tests delta: +16 casos (8 promotion gate + 6 distill engine + 2 e2e acceptance)
- **Total esperado: baseline TBD + 25 cases.** El número "433" del plan original NO está verificado contra `bash tests/run_all.sh` actual — el primer paso de PR1 es ejecutar la suite y capturar el baseline real.

Post-ship v3.32.0: 7 días observación silenciosa antes de planificar v3.33.

---

## 9. Verificación interna del plan v3 (post-AD self-check)

| Pregunta | Respuesta |
|----------|-----------|
| ¿Los 5 bugs B1-B5 están cubiertos con fix concreto? | SÍ (§4.1.A, §4.1.B, §4.1.C, §4.5; B2 broad-trigger noise queda como instinct sin code change inmediato) |
| ¿Cierra los 3 items pendientes del plan Sprint 8 §5? | **PARCIAL** — cierra §5.3 (en §4.4). §5.1 + §5.2 **DIFERIDOS a v3.33+** post-AD P0-2/P0-3. |
| ¿Hay tests asociados a cada cambio? | SÍ (6 suites tocadas + acceptance gate renombrado test_v332) |
| ¿Hay risk register con mitigaciones concretas? | SÍ (§7 actualizado con 3 nuevos riesgos AD-derived) |
| ¿Sequencing realista? | SÍ (~13h en 3 días; scope reducido por defer §4.2/§4.3) |
| ¿Operador puede usar Cortex sin nuevos `/cx-*` manuales tras v3.32? | PARCIAL — el flujo HUMAN→AUTO es semi-automático (operador decide `/cx-promote --auto` cuando gates pasan); `/cx-analyze` sigue siendo manual por diseño (review humano de proposals); auto-analyze trigger diferido a v3.33+ |
| ¿Hay rollback claro si algo sale mal? | SÍ (cada §4.X tiene archive/backup; v3.31.1 sigue siendo el último tag estable hasta el merge) |
| ¿AD round 1 está absorbido? | **SÍ** — 4 P0 + 7 P1 + 3 P2 absorbidos en v3. Round 2 opcional sobre v3 antes de PR1. |
| ¿Tests e2e (gotcha-ad-por-fase-no-sustituye-e2e)? | SÍ — `test_v332_acceptance.sh` (renombrado) con 2 asserts e2e nuevos (marker fail-closed + promotion full cycle) |

**Veredicto v3:** plan listo para implementación PR1. Round 2 AD sobre v3 es opcional (recomendado solo si scope cambia más).

---

## 10. Evolución del plan

- **v1 (2026-05-25 mañana):** post `/cx-analyze` + `/cx-validate`. 5 bugs + 3 features pendientes Sprint 8 §5 + 2 housekeeping. Pendiente decisiones operador.
- **v2 (2026-05-25 — este doc):** decisiones D1-D6 + Q1-Q5 aplicadas. Cambios clave:
  - D4 cambió de "promote-and-deprecate puro" a **híbrido** (cap 12→15 AND algoritmo deprecation).
  - Q2 cambió de "1 PR grande" a **2 PRs** (bug fixes v3.31.2 + features v3.32.0).
  - Q5 cambió de "borrar Sprint 8 docs" a **mantener hasta v3.33+**.
- **v3 (2026-05-25 — ESTE DOC, FINAL):** AD Codex GPT-5.5 round 1 absorbido. Cambios clave:
  - **AD P0-1**: §4.4.a source ahora explícito `proposals-history.jsonl` (no `proposals.json`).
  - **AD P0-2**: §4.2 + §4.3 **DIFERIDOS a v3.33+** (queue-only contradice "autopilot real"). Sprint 9 scope reducido a 5 features sólidos.
  - **AD P0-3**: branch `_is_opus_1m_active()` eliminado (moot tras defer).
  - **AD P0-4**: §4.4.d marker `.promoted-detectors.json` con schema estricto + fail-closed reader + writer ÚNICO en `/cx-promote --auto --confirm`.
  - **AD P1-1**: §4.1.A grandfather narrow a `sessions == []` explícito (no captura `null` ni missing key).
  - **AD P1-2**: §4.4.b umbral n=10 como **visibility tier** (no promotion gate).
  - **AD P1-3**: §4.5 `_find_least_impactful_law` con age guard `LAW_DEPRECATE_MIN_AGE_DAYS=7`.
  - **AD P1-4**: §4.1.B logging-only fix (sin ventana 24-48h que entraba en conflicto con sequencing).
  - **AD P1-5**: e2e gate vía `test_v332_acceptance.sh` renombrado +2 asserts nuevos.
  - **AD P1-6**: `rejection_category` enum opcional + fallback heuristic ES+EN.
  - **AD P1-7**: `manual_swap_promote` con rollback explícito.
  - **AD P2-1**: claim "433 → ~460 PASS" reemplazado por "baseline TBD + delta verificable".
  - **AD P2-2**: §4.7 explícito sobre run `test_integrity.sh` antes de tag.
  - **AD P2-3**: header v3 + footer sincronizados.

---

## 11. AD Codex GPT-5.5 — registro de rondas

### Round 1 — 2026-05-25 ✅ ABSORBIDO

**Verdict:** REVISE. 4 P0 + 7 P1 + 3 P2 findings.

Las 5 preguntas que pedí en v1/v2 contestadas:

1. ✅ **`analyze_engine.py` queue-only** → AD P0-2 detectó la contradicción "autopilot real" vs "recordatorio glorificado". **Decisión: defer §4.2/§4.3 a v3.33+.**
2. ✅ **`can_promote_to_auto` thresholds** → AD P1-2 sugirió tier intermedio. **Decisión: n=10 visibility (no gate) + n=20 promotion (gate).**
3. ✅ **Laws deprecation algorithm** → AD P1-3 detectó missing age guard. **Decisión: `LAW_DEPRECATE_MIN_AGE_DAYS=7` añadido.**
4. ✅ **§4.1.B logging design** → AD recomendó file rotation, NO stderr. **Decisión: `auto-validate-skips.jsonl` rotado a 512KB.**
5. ⏸ **Cross-platform compatibility** — NO investigado en round 1; queda como riesgo P1 a verificar pre-PR1 (¿`archive_proposals_backups.sh` corre en Windows via PowerShell?).

### Round 2 — OPCIONAL sobre v3

Si tras leer v3 hay dudas residuales, lanzar round 2 read-only con foco específico en:
- Verificar que la coordinación §4.4.a (history reader) + §4.4.d (marker fail-closed) + §4.4.e (auto_validate integration) no abre nuevos paths de race condition.
- Cross-platform compat del §4.1.C dream archive wiring (pregunta 5 pendiente de round 1).

**Trigger condición:** abrir round 2 SI scope cambia o si v3 introduce nuevo diseño no presente en v2. Caso contrario: arrancar PR1 directo.

---

**Sprint 9 plan v3 FINAL — listo para implementación PR1.**

**Próximo paso:** arrancar PR1 en sesión nueva con el prompt del operador (ver final de este chat).
