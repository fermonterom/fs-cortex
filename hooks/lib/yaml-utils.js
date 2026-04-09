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
 * Handles floats (0.75), integers (5), quoted strings, and bare strings.
 */
function parseYamlFrontmatter(content) {
  const match = content.match(/^---\s*\n([\s\S]*?)\n---/);
  if (!match) return null;
  const fields = {};
  const body = content.slice(match[0].length).trim();
  for (const line of match[1].split('\n')) {
    const m = line.match(/^(\w[\w_-]*)\s*:\s*(.*)/);
    if (!m) continue;
    let val = m[2].trim();
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
