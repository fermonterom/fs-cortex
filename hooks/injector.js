#!/usr/bin/env node
// CORTEX-MANAGED — do not edit manually, updated by install.sh/install.ps1
// Cortex Injector — cross-platform Node.js wrapper for lib/injector-engine.js
//
// Why this exists: injector.sh requires bash, which is not available by default
// on Windows. This wrapper provides the same behavior via Node.js, which is
// already a hard dependency for the engine itself, eliminating the bash
// requirement on Windows (issue: Adams Ayón report, v3.12.3).
//
// Safety: exits 0 silently on any error (never blocks Claude).
// Security: payload is written to a 0600-mode tmp file to avoid exposing the
// full hook payload via environment variables or /proc inspection.

'use strict';

const fs = require('fs');
const os = require('os');
const path = require('path');
const crypto = require('crypto');

const HOOK_DIR = path.dirname(fs.realpathSync(__filename));
const CORTEX_DIR = process.env.CORTEX_DIR || path.join(os.homedir(), '.claude', 'cortex');
const ENGINE = path.join(HOOK_DIR, 'lib', 'injector-engine.js');

function debug(msg) {
  if (process.env.CORTEX_DEBUG) {
    try { process.stderr.write('[cortex:injector] ' + msg + '\n'); } catch {}
  }
}

function readStdin() {
  return new Promise((resolve) => {
    let input = '';
    let resolved = false;
    const finish = () => { if (!resolved) { resolved = true; resolve(input); } };
    process.stdin.setEncoding('utf8');
    // Safety timeout — never block Claude waiting for input
    const timeoutId = setTimeout(finish, 2500);
    process.stdin.on('data', (chunk) => { input += chunk; });
    process.stdin.on('end', () => { clearTimeout(timeoutId); finish(); });
    process.stdin.on('error', () => { clearTimeout(timeoutId); finish(); });
  });
}

(async () => {
  let tmpFile = null;
  const cleanup = () => {
    if (tmpFile) {
      try { fs.unlinkSync(tmpFile); } catch {}
      tmpFile = null;
    }
  };

  try {
    // Engine must exist
    if (!fs.existsSync(ENGINE)) {
      debug('engine not found: ' + ENGINE);
      process.exit(0);
    }

    // Read hook payload from stdin
    const input = await readStdin();
    if (!input || !input.trim()) process.exit(0);

    // Validate CORTEX_DIR is under real home (mirror injector.sh guard)
    const realHome = os.homedir();
    const expected = path.join(realHome, '.claude', 'cortex');
    if (path.resolve(CORTEX_DIR) !== path.resolve(expected)) {
      debug('CORTEX_DIR mismatch: ' + CORTEX_DIR);
      process.exit(0);
    }

    // Write payload to 0600-mode tmp file (same security model as injector.sh)
    tmpFile = path.join(
      os.tmpdir(),
      'cx-input-' + crypto.randomBytes(6).toString('hex')
    );
    fs.writeFileSync(tmpFile, input, { mode: 0o600 });

    // Ensure cleanup on both normal exit and signals
    process.on('exit', cleanup);
    process.on('SIGINT', () => { cleanup(); process.exit(0); });
    process.on('SIGTERM', () => { cleanup(); process.exit(0); });

    // Set env vars expected by the engine
    process.env._CX_INPUT_FILE = tmpFile;
    process.env._CX_CORTEX_DIR = CORTEX_DIR;
    process.env._CX_REFLEXES_FILE = path.join(CORTEX_DIR, 'reflexes.json');
    process.env._CX_GLOBAL_INSTINCTS_DIR = path.join(CORTEX_DIR, 'instincts', 'global');

    // Delegate to engine — engine runs main() at require-time via its bottom
    // try/catch block and calls process.exit(0) on completion. Cleanup handler
    // registered above ensures the tmp file is removed.
    require(ENGINE);
  } catch (e) {
    debug('fatal: ' + (e && e.message ? e.message : String(e)));
    cleanup();
    process.exit(0);
  }
})();
