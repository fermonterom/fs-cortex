// CORTEX-MANAGED — do not edit manually, updated by install.sh
// Cortex Regex Guard — shared ReDoS protection (v3.23.4+)
// Single source of truth for regex safety checks across injector, learner,
// distill_engine and dream_cycle. Python parity: lib/regex_guard.py.
//
// Limits raised in v3.23.4 to fix the bash-cat-use-read silent regression:
//   - MAX_LEN  100 → 200   (real-world condition reached 136 chars)
//   - MAX_PIPES  5 → 25    (extension lists like py|js|...|env are legitimate)
//   - REDOS_DETECTOR removed `?` from outer quantifier (`?` cannot cause
//     catastrophic backtracking; only `+` and `*` can).
// Live timeout (50ms) remains the ultimate safety net.

'use strict';

const MAX_LEN = 200;
const MAX_PIPES = 25;
const LIVE_TIMEOUT_MS = 50;
const LIVE_TEST_INPUT = 'a'.repeat(100);

// Catastrophic backtracking detector: `(...+)+` `(...+)*` `(...*)+` `(...*)*`.
// `(...)?` is safe (zero-or-one — no exponential paths).
//
// KNOWN GAP — alternation-overlap patterns like `(a|aa)+` are NOT detected
// statically. They CAN be ReDoS-vulnerable in theory but the live timeout
// (LIVE_TIMEOUT_MS, applied in unsafeReason) catches them dynamically against
// the 100-char probe input. Improving the static detector is tracked for
// v3.24.0+. See tests/test_guard_corpus.sh "known gaps" section.
const REDOS_DETECTOR = /\([^)]*[+*]\)[+*]/;

/**
 * Returns null if pattern is safe, or a short reason string if rejected.
 * Reasons: "non-string" | "len>200" | "redos" | "pipes>25" | "timeout" | "invalid".
 */
function unsafeReason(pattern) {
  if (typeof pattern !== 'string') return 'non-string';
  if (pattern.length > MAX_LEN) return `len>${MAX_LEN}`;
  if (REDOS_DETECTOR.test(pattern)) return 'redos';
  const pipes = (pattern.match(/\|/g) || []).length;
  if (pipes > MAX_PIPES) return `pipes>${MAX_PIPES}`;
  try {
    const re = new RegExp(pattern);
    const start = Date.now();
    re.test(LIVE_TEST_INPUT);
    if (Date.now() - start > LIVE_TIMEOUT_MS) return 'timeout';
  } catch {
    return 'invalid';
  }
  return null;
}

/** Boolean wrapper around unsafeReason. */
function isSafeRegex(pattern) {
  return unsafeReason(pattern) === null;
}

// Process-local dedup — avoids stderr spam if a malformed pattern is exercised
// on every PreToolUse. Bounded to keep memory flat; resets on process restart.
const _loggedRejections = new Set();
const _LOGGED_REJECTIONS_MAX = 256;

/**
 * Compile + test pattern against text. Returns false on unsafe or invalid.
 * Logs rejection to stderr (best-effort, deduped) so silent regressions are visible.
 */
function safeRegexTest(pattern, text, options) {
  const opts = options || {};
  const reason = unsafeReason(pattern);
  if (reason) {
    if (opts.logRejection !== false) {
      try {
        const tag = opts.tag || 'unknown';
        const snippet = (typeof pattern === 'string') ? pattern.slice(0, 64) : '?';
        const key = `${tag}|${reason}|${snippet}`;
        if (!_loggedRejections.has(key)) {
          if (_loggedRejections.size < _LOGGED_REJECTIONS_MAX) _loggedRejections.add(key);
          process.stderr.write(`[cortex:guard] rejected pattern in ${tag}: ${reason} (len=${pattern && pattern.length})\n`);
        }
      } catch {}
    }
    return false;
  }
  try {
    return new RegExp(pattern, 'i').test(text);
  } catch {
    return false;
  }
}

module.exports = {
  MAX_LEN,
  MAX_PIPES,
  LIVE_TIMEOUT_MS,
  REDOS_DETECTOR,
  unsafeReason,
  isSafeRegex,
  safeRegexTest,
};
