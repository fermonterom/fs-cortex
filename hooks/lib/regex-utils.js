// CORTEX-MANAGED — do not edit manually, updated by install.sh
// regex-utils.js — v3.29.0 (Sprint 8 §4.2)
//
// Small, dependency-free helpers for building regexes from user-controlled
// or runtime-derived strings safely. Centralised here so callers like
// session-learner.js (detectFileCoupling, detectUserCorrections) share one
// implementation instead of inlining the same escape pattern in two places.
//
// IMPORTANT: this module only HANDLES escaping. Callers that build a regex
// from user/runtime input MUST still pass the final pattern through the
// regex-guard before persisting it as an instinct trigger, because escape
// alone does not guarantee the resulting pattern is safe to execute (e.g.
// catastrophic backtracking from a malicious literal sequence).

'use strict';

/**
 * Escape a string so every character is matched literally inside a regex.
 *
 * Equivalent to lodash.escapeRegExp / MDN canonical example. Covers the
 * full set of ECMAScript regex metacharacters:
 *
 *     . * + ? ^ $ { } ( ) | [ ] \
 *
 * Hyphen `-` is intentionally NOT escaped — it is only special inside a
 * character class and our callers always embed escaped output OUTSIDE of
 * character classes (e.g. `Edit.*(?:${escapeRegex(name)}|...)`).
 *
 * @param {string} s
 * @returns {string}
 */
function escapeRegex(s) {
  return String(s == null ? '' : s).replace(/[.*+?^${}()|[\]\\]/g, '\\$&');
}

module.exports = { escapeRegex };
