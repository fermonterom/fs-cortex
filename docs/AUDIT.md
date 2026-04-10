# Auditoria Incremental: fs-cortex v3.6.2
Fecha: 2026-04-09 | Score: 69/100 | Tipo: CLI / Shell Hooks

## Metadata
- Framework: Claude Code Hooks (SessionStart, PreToolUse, Stop)
- Lenguajes: Bash + JavaScript + Python
- LOC: 8,405
- Tests: 124 (8 suites)
- Cobertura estimada: 85% (bash/JS), 0% (PowerShell)
- Auditoria anterior: 2026-04-09 (AUDIT.md v3.0, 9 fases)

---

## Instrucciones de Ejecucion

Este documento esta disenado para ejecutarse paso a paso con Claude Code.
Cada fase crea una rama git dedicada con commits atomicos convencionales.

### Workflow por fase:
1. Determinar rama base (ver tabla de dependencias abajo)
2. Crear rama: `git checkout -b {prefix}/{fase-kebab}` desde la rama base
3. Ejecutar cada fix/mejora del listado
4. Hacer un commit por cada fix con el mensaje convencional indicado
5. Verificar que todo funciona antes de cada commit
6. Al terminar la fase: `git checkout main` — NO mergear, NO push
7. Repetir con la siguiente fase

### Rama base por fase:
- Fases SIN dependencias → branch from `main`
- Fases CON dependencias → branch from la rama de la que dependen

### Naming de ramas:
| Tipo de fase | Prefijo de rama | Prefijo de commit |
|-------------|----------------|-------------------|
| Seguridad | `fix/security-incremental` | `fix(security):` |
| Logica interna | `fix/internal-consistency` | `fix({modulo}):` |
| Testing | `chore/test-hardening` | `test({modulo}):` |
| Arquitectura | `refactor/architecture-sync` | `refactor({modulo}):` |
| DevOps | `chore/ci-improvements` | `chore(ci):` |

---

## Fase 1: Seguridad
**Rama:** `fix/security-incremental`
**Base:** `main`
**Dependencias:** ninguna

---

### SEC-001: install.ps1 backup import path traversal validation
- **Severidad**: ALTO
- **Archivo**: `install.ps1:332`
- **BEFORE**:
```powershell
$tempDir = New-Item -ItemType Directory -Path (Join-Path ([System.IO.Path]::GetTempPath()) ([System.IO.Path]::GetRandomFileName()))
tar -xzf $ImportBackup -C $tempDir.FullName 2>$null
```
- **AFTER**:
```powershell
# Validate archive: reject entries with path traversal or absolute paths
$unsafeEntries = tar -tzf $ImportBackup 2>$null | Where-Object { $_ -match '(^\\/|\\.\\.[\\/])' }
if ($unsafeEntries) {
    Print-Error "Backup archive contains unsafe paths (../ or absolute). Aborting import."
    return
}
$tempDir = New-Item -ItemType Directory -Path (Join-Path ([System.IO.Path]::GetTempPath()) ([System.IO.Path]::GetRandomFileName()))
tar -xzf $ImportBackup -C $tempDir.FullName 2>$null
```
- **Verificacion**: `grep -A5 'tar -xzf.*ImportBackup' install.ps1 | grep -q 'unsafe\|traversal'`
- **Commit**: `fix(security): add path traversal check to ps1 backup`

---

### SEC-002: injector.sh trap quoting fix
- **Severidad**: MEDIO
- **Archivo**: `hooks/injector.sh:28`
- **BEFORE**:
```bash
trap "rm -f '$_CX_INPUT_FILE'" EXIT
```
- **AFTER**:
```bash
trap 'rm -f "'"$_CX_INPUT_FILE"'"' EXIT
```
- **Verificacion**: `TMPDIR="/tmp/dir with spaces" bash hooks/injector.sh < /dev/null 2>/dev/null; ls "/tmp/dir with spaces/cx-input-"* 2>/dev/null && echo 'LEAK' || echo 'CLEAN'`
- **Commit**: `fix(security): fix trap quoting for TMPDIR with spaces in injector`

---

### SEC-003: session-start.sh CWD validation
- **Severidad**: MEDIO
- **Archivo**: `hooks/session-start.sh:125`
- **BEFORE**:
```bash
if [ -n "$_CWD" ] && [ -d "$_CWD" ] && command -v git &>/dev/null; then
```
- **AFTER**:
```bash
if [ -n "$_CWD" ] && [[ "$_CWD" == /* ]] && [[ "$_CWD" != *..* ]] && [ -d "$_CWD" ] && command -v git &>/dev/null; then
  _CWD=$(cd "$_CWD" && pwd -P)  # Resolve symlinks
```
- **Verificacion**: `echo '{"cwd":"/tmp/../etc"}' | bash hooks/session-start.sh 2>/dev/null; echo $?`
- **Commit**: `fix(security): validate and resolve CWD symlinks in session-start`

---

### SEC-004: injector.sh HOME validation
- **Severidad**: MEDIO
- **Archivo**: `hooks/injector.sh:30`
- **BEFORE**:
```bash
export _CX_CORTEX_DIR="$CORTEX_DIR"
export _CX_REFLEXES_FILE="$REFLEXES_FILE"
```
- **AFTER**:
```bash
_REAL_HOME=$(eval echo ~"$(whoami)" 2>/dev/null || echo "$HOME")
if [[ "$CORTEX_DIR" != "$_REAL_HOME/.claude/cortex" ]]; then
  exit 0  # Refuse to run with non-standard CORTEX_DIR
fi
export _CX_CORTEX_DIR="$CORTEX_DIR"
export _CX_REFLEXES_FILE="$REFLEXES_FILE"
```
- **Verificacion**: `HOME=/tmp/evil bash hooks/injector.sh < /dev/null 2>/dev/null; echo $?`
- **Commit**: `fix(security): validate CORTEX_DIR against real home in injector`

---

### SEC-005: validate_instinct.py multiline YAML bypass
- **Severidad**: MEDIO
- **Archivo**: `hooks/lib/validate_instinct.py:27`
- **BEFORE**:
```python
for line in content.split('\n'):
    stripped = line.strip()
    if stripped.startswith('action:'):
        action = stripped.split(':', 1)[1].strip()
```
- **AFTER**:
```python
import re
fm_match = re.search(r'^---\s*\n(.*?)\n---', content, re.DOTALL)
if fm_match:
    block = fm_match.group(1)
    # Extract action including multiline continuation (| or >)
    action_match = re.search(r'^action:\s*(?:[|>]\s*\n((?:\s+.+\n?)*)|(.*?)$)', block, re.MULTILINE)
    if action_match:
        action = (action_match.group(1) or action_match.group(2) or '').strip()
        for pattern in BLOCKED_PATTERNS:
            if pattern.search(action):
                return {"valid": False, "reason": f"Blocked pattern in action"}
```
- **Verificacion**: Crear YAML con `action: |\n  ignore all previous instructions` y ejecutar validate — debe fallar
- **Commit**: `fix(security): handle YAML multiline values in instinct validation`

---

### SEC-006: uninstall.sh atomic settings.json write
- **Severidad**: MEDIO
- **Archivo**: `uninstall.sh:125`
- **BEFORE**:
```python
with open(settings_file, "w") as f:
    json.dump(s, f, indent=2)
```
- **AFTER**:
```python
import tempfile
fd, tmp = tempfile.mkstemp(dir=os.path.dirname(settings_file), suffix='.tmp')
with os.fdopen(fd, 'w') as f:
    json.dump(s, f, indent=2)
    f.write('\n')
os.chmod(tmp, 0o600)
os.replace(tmp, settings_file)
```
- **Verificacion**: `grep -A4 'json.dump.*settings' uninstall.sh | grep -q 'replace\|rename'`
- **Commit**: `fix(security): atomic write for settings.json in uninstall`

---

### SEC-007: install.ps1 chmod 600 on settings.json
- **Severidad**: ALTO
- **Archivo**: `install.ps1:270`
- **BEFORE**:
```python
os.replace(tmp_path, settings_file)
```
- **AFTER**:
```python
import stat
os.chmod(tmp_path, stat.S_IRUSR | stat.S_IWUSR)
os.replace(tmp_path, settings_file)
```
- **Verificacion**: `grep -B2 'os.replace.*settings' install.ps1 | grep -q 'chmod\|S_IRUSR'`
- **Commit**: `fix(security): add chmod 600 to settings.json in ps1`

---

**Verificacion de fase**: `bash tests/test_security.sh && bash tests/test_install.sh`
**Al terminar**: `git checkout main` — NO mergear, NO push.

---

## Fase 2: Consistencia Interna (Logic Bugs)
**Rama:** `fix/internal-consistency`
**Base:** `fix/security-incremental` (Fase 1)
**Dependencias:** Fase 1

---

### FIX-001: Reset token budget at session start
- **Severidad**: ALTO
- **Archivo**: `hooks/session-start.sh` (add near top, after CORTEX_DIR assignment)
- **BEFORE**: (no reset exists)
- **AFTER**:
```bash
# Reset per-session token budget (prevents silent accumulation across sessions)
rm -f "$CORTEX_DIR/.session-token-budget"
```
- **Verificacion**: `echo 9999 > ~/.claude/cortex/.session-token-budget && bash hooks/session-start.sh < /dev/null 2>/dev/null && cat ~/.claude/cortex/.session-token-budget 2>/dev/null && echo 'NOT RESET' || echo 'RESET OK'`
- **Commit**: `fix(injector): reset session token budget at session start`

---

### FIX-002: Unify decay formula (dream_cycle.py → linear)
- **Severidad**: ALTO
- **Archivo**: `hooks/lib/dream_cycle.py:135`
- **BEFORE**:
```python
decay_factor = 1.0 - (score / 200.0)
inst['confidence'] = max(0.10, confidence * decay_factor)
```
- **AFTER**:
```python
# Linear decay matching cx-distill and documented behavior
# Read config or use default: -0.05 per 30 days
decay_per_30 = 0.05  # TODO: read from memory.json config
days_stale = score  # staleness_score is already in days
periods = days_stale // 30
new_conf = confidence - (decay_per_30 * periods)
inst['confidence'] = round(max(0.10, new_conf), 4)
```
- **Verificacion**: Test instinct with confidence 0.80, 60 days stale: should decay to 0.70 (not 0.56)
- **Commit**: `fix(dream-cycle): unify decay formula to linear -0.05/30d`

---

### FIX-003: Update MAX_INSTINCTS docs (6 locations)
- **Severidad**: ALTO
- **Archivos**: `core/memory.template.json`, `skills/cortex/SKILL.md` (x2), `README.md` (token table), `hooks/injector.sh:8`
- **BEFORE**: Various locations say "max 2"
- **AFTER**: All say "max 3" (matching injector.sh:245 `const MAX_INSTINCTS = 3`)
- **Verificacion**: `grep -rn 'max 2.*instinct\|max_instincts.*2' core/ skills/ README.md hooks/injector.sh | head -10`
- **Commit**: `fix(docs): update MAX_INSTINCTS from 2 to 3 in all 6 locations`

---

### FIX-004: dedup_instincts full pairwise comparison
- **Severidad**: MEDIO
- **Archivo**: `hooks/lib/dream_cycle.py:47`
- **BEFORE**:
```python
for kept in keep:
    sim = jaccard_similarity(...)
    if sim >= threshold:
        if inst.get('confidence',0) > kept.get('confidence',0):
            keep.remove(kept)
            keep.append(inst)
        is_dup = True
        break
```
- **AFTER**:
```python
matches = []
for kept in keep:
    sim = jaccard_similarity(...)
    if sim >= threshold:
        matches.append(kept)
if matches:
    best = max([inst] + matches, key=lambda x: x.get('confidence', 0))
    for m in matches:
        if m in keep:
            keep.remove(m)
    if best not in keep:
        keep.append(best)
    is_dup = (best != inst)
```
- **Verificacion**: `bash tests/test_dream_cycle.sh`
- **Commit**: `fix(dream-cycle): complete pairwise dedup instead of break-on-first`

---

### FIX-005: detectUserCorrections reduce false positives
- **Severidad**: MEDIO
- **Archivo**: `hooks/session-learner.js:323`
- **BEFORE**:
```javascript
if (edits.length >= 2) {
  corrections.push({...confidence: 0.50...})
```
- **AFTER**:
```javascript
// Require 3+ edits to same file AND check for overlapping old_string regions
if (edits.length >= 3 && hasOverlappingEdits(edits)) {
  corrections.push({...confidence: 0.40...})
```
- **Verificacion**: `bash tests/test_session_learner.sh`
- **Commit**: `fix(learner): require 3+ overlapping edits for user correction detection`

---

### FIX-006: observe.py error detection reduce false positives
- **Severidad**: MEDIO
- **Archivo**: `hooks/observe.py:83`
- **BEFORE**:
```python
ERROR_PATTERNS = [
    re.compile(r"\berror\b", re.I),
    re.compile(r"\bfailed\b", re.I),
    re.compile(r"\bpanic\b", re.I),
]
```
- **AFTER**:
```python
ERROR_PATTERNS = [
    re.compile(r"(?:^|\s)error[:\s]", re.I | re.M),
    re.compile(r"(?:^|\s)failed(?!\s*:\s*0)", re.I | re.M),
    re.compile(r"(?:^|\s)panic[:(]", re.I | re.M),
]
```
- **Verificacion**: `bash tests/test_observe.sh`
- **Commit**: `fix(observer): reduce error detection false positives`

---

**Verificacion de fase**: `bash tests/run_all.sh`
**Al terminar**: `git checkout main` — NO mergear, NO push.

---

## Fase 3: Paridad Windows (install.ps1)
**Rama:** `fix/windows-parity`
**Base:** `fix/security-incremental` (Fase 1, incluye SEC-001 y SEC-007)
**Dependencias:** Fase 1

---

### WIN-001: install.ps1 backup import — add 6 missing data categories
- **Severidad**: MEDIO
- **Archivo**: `install.ps1:327`
- **BEFORE**: Only copies laws/ and instincts/global/, instincts/personal/
- **AFTER**: Add copy logic for: memory.json, reflexes.json, projects/registry.json, projects/*/instincts/, evolved/*, daily-summaries/*.md (matching install.sh lines 404-421)
- **Verificacion**: Create backup with all categories, import in PS1, verify all files present
- **Commit**: `fix(install): add 6 missing backup import categories to install.ps1`

---

### WIN-002: install.ps1 atomic memory.json write
- **Severidad**: BAJO
- **Archivo**: `install.ps1:384`
- **BEFORE**:
```python
with open(mem_path, "w") as f:
    json.dump(mem, f, indent=2)
```
- **AFTER**:
```python
import tempfile
fd, tmp = tempfile.mkstemp(dir=os.path.dirname(mem_path), suffix=".tmp")
with os.fdopen(fd, "w") as f:
    json.dump(mem, f, indent=2)
os.replace(tmp, mem_path)
```
- **Verificacion**: `grep -A3 'mem_path' install.ps1 | grep -q 'replace\|rename'`
- **Commit**: `fix(install): atomic write for memory.json in install.ps1`

---

**Verificacion de fase**: `bash tests/test_install.sh`
**Al terminar**: `git checkout main` — NO mergear, NO push.

---

## Fase 4: Arquitectura y Refactor
**Rama:** `refactor/architecture-sync`
**Base:** `main`
**Dependencias:** ninguna (puede ejecutarse en paralelo con Fase 1)

---

### ARCH-001: injector.sh import yaml-utils.js instead of inline parsing
- **Severidad**: MEDIO
- **Archivo**: `hooks/injector.sh:86-119`
- **BEFORE**: Inline `parseInstinctYaml` and `listYamlFiles` functions
- **AFTER**: `const { parseYamlFrontmatter, listYamlFiles } = require(...)` from yaml-utils.js with adapter wrapper
- **Verificacion**: `bash tests/test_injector.sh`
- **Commit**: `refactor(injector): import yaml-utils.js instead of inline parsing`

---

### ARCH-002: injector.sh read memory.json config values
- **Severidad**: MEDIO
- **Archivo**: `hooks/injector.sh:245`
- **BEFORE**: `const MAX_INSTINCTS = 3;` (hardcoded)
- **AFTER**: Read from memory.json `config.injection` section with current values as defaults
- **Verificacion**: Set `max_instincts_per_injection: 1` in memory.json, verify only 1 injected
- **Commit**: `refactor(injector): read config from memory.json with fallback defaults`

---

### ARCH-003: session-learner.js add log rotation
- **Severidad**: BAJO
- **Archivo**: `hooks/session-learner.js:43`
- **BEFORE**: `fs.appendFileSync(LOG_PATH, line);`
- **AFTER**: Check size before append; if > 512KB, rename to .1
- **Verificacion**: `ls -lh ~/.claude/cortex/log/session-learner.log`
- **Commit**: `refactor(learner): add 512KB log rotation`

---

### ARCH-004: Unify error patterns between observe.py and session-learner.js
- **Severidad**: BAJO
- **Archivo**: `hooks/session-learner.js:251` + `hooks/observe.py:83`
- **BEFORE**: Different pattern sets in each file
- **AFTER**: Document shared patterns in comment header; align the 5 missing patterns
- **Verificacion**: `diff <(grep -oP "'\\\\b\w+\\\\b'" hooks/observe.py | sort) <(grep -oP "'\\\\b\w+\\\\b'" hooks/session-learner.js | sort)`
- **Commit**: `refactor(hooks): align error patterns between observer and learner`

---

**Verificacion de fase**: `bash tests/run_all.sh`
**Al terminar**: `git checkout main` — NO mergear, NO push.

---

## Fase 5: DevOps/CI
**Rama:** `chore/ci-improvements`
**Base:** `main`
**Dependencias:** ninguna

---

### CI-001: Remove || true from lint steps
- **Severidad**: MEDIO
- **Archivo**: `.github/workflows/test.yml:14,20`
- **BEFORE**:
```yaml
run: shellcheck hooks/*.sh tests/*.sh install.sh || true
run: pip install flake8 && flake8 hooks/*.py --max-line-length=120 --ignore=E501,W503 || true
```
- **AFTER**:
```yaml
run: shellcheck --severity=error hooks/*.sh tests/*.sh install.sh
run: pip install flake8 && flake8 hooks/*.py --max-line-length=120 --select=E9,F63,F7,F82
```
- **Verificacion**: `grep -c '|| true' .github/workflows/test.yml` (should be 0)
- **Commit**: `chore(ci): make lint steps blocking for errors`

---

### CI-002: Add test summary step using run_all.sh
- **Severidad**: BAJO
- **Archivo**: `.github/workflows/test.yml`
- **BEFORE**: No summary step
- **AFTER**: Add step at end: `bash tests/run_all.sh 2>&1 | tail -10`
- **Verificacion**: `grep 'run_all' .github/workflows/test.yml`
- **Commit**: `chore(ci): add test summary step using run_all.sh`

---

### CI-003: Add session-start.sh strict mode
- **Severidad**: BAJO
- **Archivo**: `hooks/session-start.sh:7`
- **BEFORE**: `set -e`
- **AFTER**: `set -euo pipefail` (with `${VAR:-}` expansion for optional vars)
- **Verificacion**: `head -10 hooks/session-start.sh | grep 'pipefail'`
- **Commit**: `chore(hooks): add set -uo pipefail to session-start.sh`

---

**Verificacion de fase**: `bash tests/run_all.sh`
**Al terminar**: `git checkout main` — NO mergear, NO push.

---

## Fase 6: Test Hardening
**Rama:** `chore/test-hardening`
**Base:** `fix/security-incremental` (Fase 1, para poder testear los fixes)
**Dependencias:** Fase 1

---

### TEST-001: test_install.sh trap cleanup
- **Severidad**: MEDIO
- **Archivo**: `tests/test_install.sh:19`
- **BEFORE**: Direct `rm -rf "$SANDBOX"` without trap
- **AFTER**: `SANDBOXES=()` array + `trap cleanup EXIT` function
- **Verificacion**: Kill test mid-execution, verify no /tmp dirs leaked
- **Commit**: `test(install): add trap cleanup for sandbox temp dirs`

---

### TEST-002: Fix trap quoting in test files
- **Severidad**: BAJO
- **Archivos**: `tests/test_hooks_e2e.sh:15`, `tests/test_security.sh`
- **BEFORE**: `trap "rm -rf $SANDBOX" EXIT`
- **AFTER**: `trap "rm -rf '$SANDBOX'" EXIT`
- **Verificacion**: `grep -n 'trap.*rm.*SANDBOX' tests/*.sh`
- **Commit**: `test(hooks): fix trap quoting for SANDBOX variable`

---

### TEST-003: Add token budget reset test
- **Severidad**: ALTO (validates FIX-001)
- **Archivo**: `tests/test_hooks_e2e.sh` (add test case)
- **Tests a crear**:
  - [ ] Test: session-start resets .session-token-budget file
  - [ ] Test: injector works after budget reset
- **Commit**: `test(hooks): add token budget reset e2e test`

---

### TEST-004: Add decay formula consistency test
- **Severidad**: ALTO (validates FIX-002)
- **Archivo**: `tests/test_dream_cycle.sh` (add test case)
- **Tests a crear**:
  - [ ] Test: decay(0.80, 60 days) == 0.70 (linear formula)
  - [ ] Test: decay(0.80, 30 days) == 0.75
  - [ ] Test: decay(0.80, 0 days) == 0.80 (no decay)
- **Commit**: `test(dream-cycle): add decay formula consistency tests`

---

**Verificacion de fase**: `bash tests/run_all.sh`
**Al terminar**: `git checkout main` — NO mergear, NO push.

---

## Resumen de Ramas

| # | Rama | Base | Commits | Hallazgos |
|---|------|------|---------|-----------|
| 1 | `fix/security-incremental` | `main` | 7 | 2 altos, 5 medios |
| 2 | `fix/internal-consistency` | Fase 1 | 6 | 3 altos, 3 medios |
| 3 | `fix/windows-parity` | Fase 1 | 2 | 1 medio, 1 bajo |
| 4 | `refactor/architecture-sync` | `main` | 4 | 2 medios, 2 bajos |
| 5 | `chore/ci-improvements` | `main` | 3 | 1 medio, 2 bajos |
| 6 | `chore/test-hardening` | Fase 1 | 4 | 1 medio, 1 bajo, 2 tests |

**Ninguna rama ha sido mergeada ni pusheada.**
Revisar cada rama y decidir: abrir PR, push, merge manual, o descartar.

---

## Orden de Merge Recomendado

```
1. fix/security-incremental    -> main  (bloquea Fase 2, 3, 6)
2. fix/internal-consistency    -> main  (requiere 1)
3. fix/windows-parity          -> main  (requiere 1)
4. refactor/architecture-sync  -> main  (independiente)
5. chore/ci-improvements       -> main  (independiente, en paralelo con 4)
6. chore/test-hardening        -> main  (requiere 1)
```

---

## Delta desde Auditoria Anterior

### Bugs corregidos (auditoria v3.0 → v3.6.1)
- ~~SECURITY.md desactualizado~~ → actualizado con versiones y contacto
- ~~lib/*.js no se copiaba en install.ps1~~ → corregido en v3.5.0/3.6.0
- ~~Sin tests para install~~ → test_install.sh con 3 escenarios
- ~~Sin tests e2e para hooks~~ → test_hooks_e2e.sh
- ~~YAML utils sin tests~~ → test_yaml_utils.sh con 13 tests

### Bugs nuevos introducidos
- **DA-003**: Token budget file nunca se resetea (v3.5.0)
- **DA-002**: MAX_INSTINCTS=3 sin actualizar 6 docs (v3.2.0)

### Score comparison
```
Auditoria anterior: sin score formal (roadmap, no auditoria cuantitativa)
Score actual:       69/100

Seguridad:     65/100
Testing:       75/100
Arquitectura:  60/100
Rendimiento:   80/100
Calidad:       70/100
DevOps:        65/100
```

---

## Checklist de Verificacion Final

### Seguridad
- [x] SEC-001: Path traversal validado en install.ps1
- [x] SEC-002: Trap quoting arreglado en injector
- [x] SEC-003: CWD validado con symlink resolution
- [x] SEC-004: HOME validado contra real home
- [x] SEC-005: YAML multiline bypass cerrado
- [x] SEC-006: uninstall.sh atomic write
- [x] SEC-007: chmod 600 en install.ps1 settings.json

### Logica
- [x] FIX-001: Token budget se resetea en cada sesion
- [x] FIX-002: Decay formula unificada (linear -0.05/30d)
- [x] FIX-003: MAX_INSTINCTS=3 en las 6 ubicaciones
- [x] FIX-004: dedup_instincts comparacion completa
- [x] FIX-005: detectUserCorrections sin falsos positivos
- [x] FIX-006: Error patterns sin falsos positivos

### Windows
- [x] WIN-001: Backup import con 8 categorias completas
- [x] WIN-002: memory.json atomic write

### Arquitectura
- [x] ARCH-001: injector importa yaml-utils.js
- [ ] ARCH-002: injector lee memory.json config — diferido a v3.7
- [x] ARCH-003: Log rotation en session-learner
- [x] ARCH-004: Error patterns alineados

### CI/DevOps
- [x] CI-001: Lint blocking en CI
- [x] CI-002: Summary step con run_all.sh
- [x] CI-003: session-start.sh strict mode

### Tests
- [x] TEST-001: Trap cleanup en test_install.sh
- [x] TEST-002: Trap quoting en test files
- [x] TEST-003: Token budget reset test
- [x] TEST-004: Decay formula consistency test
- [ ] Todos los tests pasan en macOS — pendiente CI
- [ ] Todos los tests pasan en Linux — pendiente CI

### Score estimado post-correccion: ~82/100
