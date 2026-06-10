'use strict';
/**
 * Shared YAML frontmatter utilities for Cortex hooks.
 * Used by both injector.sh (inline) and session-learner.js.
 * Zero dependencies — pure Node.js.
 */

const fs = require('fs');
const path = require('path');

/**
 * Parse YAML frontmatter between --- markers.
 * Returns { fields, raw, body } or null if no frontmatter found.
 * Handles floats (0.75), integers (5), quoted strings, bare strings, and
 * (v3.36.1) block scalars (`key: |`, `|-`, `>`, `>-`): continuation lines
 * are collected and joined. Pre-v3.36.1 a block-scalar field returned just
 * the indicator ("|-", 2 chars) — five live multiline-action instincts
 * injected that garbage, and the v3.36.1 hollow-action guard would have
 * silently dropped them instead.
 */
function parseYamlFrontmatter(content) {
  const match = content.match(/^---\s*\n([\s\S]*?)\n---/);
  if (!match) return null;
  const fields = {};
  const body = content.slice(match[0].length).trim();
  const lines = match[1].split('\n');
  for (let i = 0; i < lines.length; i++) {
    const m = lines[i].match(/^(\w[\w_-]*)\s*:\s*(.*)/);
    if (!m) continue;
    let val = m[2].trim();
    const block = val.match(/^([|>])[+-]?\s*$/);
    if (block) {
      // Collect indented (or blank) continuation lines. A new top-level key
      // starts at column 0, so the indent test also terminates the block.
      const chunk = [];
      let j = i + 1;
      while (j < lines.length && (/^\s+\S/.test(lines[j]) || lines[j].trim() === '')) {
        chunk.push(lines[j]);
        j++;
      }
      while (chunk.length && chunk[chunk.length - 1].trim() === '') chunk.pop();
      const indents = chunk.filter((l) => l.trim()).map((l) => l.match(/^\s*/)[0].length);
      const minIndent = indents.length ? Math.min.apply(null, indents) : 0;
      const text = chunk.map((l) => l.slice(minIndent)).join('\n');
      // Folded scalars (>) join lines with spaces; literal (|) keeps newlines.
      fields[m[1]] = block[1] === '>' ? text.replace(/\n+/g, ' ').trim() : text;
      i = j - 1;
      continue;
    }
    // Strip surrounding quotes
    if ((val.startsWith('"') && val.endsWith('"')) || (val.startsWith("'") && val.endsWith("'"))) {
      val = val.slice(1, -1);
    }
    // Parse numbers: floats first, then integers
    if (/^\d+\.\d+$/.test(val)) {
      val = parseFloat(val);
    } else if (/^\d+$/.test(val)) {
      val = parseInt(val, 10);
    }
    fields[m[1]] = val;
  }
  return { fields, raw: match[1], body, fullMatch: match[0] };
}

/**
 * Update a single field in YAML frontmatter.
 * If field exists, replaces value. If not, appends it.
 */
function updateYamlField(content, fieldName, newValue) {
  const match = content.match(/^---\s*\n([\s\S]*?)\n---/);
  if (!match) return content;
  const frontmatter = match[1];
  const valueStr = typeof newValue === 'number' ? String(newValue) : `"${newValue}"`;
  const fieldRegex = new RegExp(`^(${fieldName}\\s*:\\s*)(.*)$`, 'm');
  let updated;
  if (fieldRegex.test(frontmatter)) {
    updated = frontmatter.replace(fieldRegex, `$1${valueStr}`);
  } else {
    updated = frontmatter + `\n${fieldName}: ${valueStr}`;
  }
  return content.replace(match[0], `---\n${updated}\n---`);
}

/**
 * List .yaml/.yml files in a directory (non-recursive).
 */
function listYamlFiles(dir) {
  try {
    return fs.readdirSync(dir)
      .filter(f => f.endsWith('.yaml') || f.endsWith('.yml'))
      .map(f => path.join(dir, f));
  } catch {
    return [];
  }
}

module.exports = { parseYamlFrontmatter, updateYamlField, listYamlFiles };
