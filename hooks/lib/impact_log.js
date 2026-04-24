// impact_log.js — JS writer mirroring hooks/lib/impact_log.py schema (v:1).
// Fast-path for injector-engine.js and session-learner.js: they must not
// spawn Python every tool-use, so we append directly with best-effort locking.
//
// Canonical events (shared with impact_log.py):
//   {"v":1,"ts":"...","ev":"inject","iid":"...","tool":"...","pid":"...","sid":"...","conf":0.75}
//   {"v":1,"ts":"...","ev":"follow","iid":"...","sid":"...","followed":true,"err_after":false,"win":3}
//   {"v":1,"ts":"...","ev":"reject","iid":"...","sid":"...","reason":"unrelated"}
//   {"v":1,"ts":"...","ev":"feedback","iid":"...","sid":"...","rating":"useful"}
//   {"v":1,"ts":"...","ev":"outcome","iid":"...","sid":"...","error_within_10":false}

const fs = require("fs");
const os = require("os");
const path = require("path");

const SCHEMA_VERSION = 1;
const CORTEX_DIR = process.env.CORTEX_DIR || path.join(os.homedir(), ".claude", "cortex");
const IMPACT_FILE = path.join(CORTEX_DIR, "impact.jsonl");

const VALID_EVENTS = new Set(["inject", "follow", "reject", "feedback", "outcome"]);

function nowIso() {
  return new Date().toISOString().replace(/\.\d{3}/, "");
}

function appendLine(line) {
  try {
    fs.mkdirSync(CORTEX_DIR, { recursive: true });
  } catch {}
  try {
    fs.appendFileSync(IMPACT_FILE, line.replace(/\s+$/, "") + "\n", { mode: 0o600 });
  } catch (err) {
    if (process.env.CORTEX_DEBUG) {
      process.stderr.write("[cortex:impact_log] append failed: " + err.message + "\n");
    }
  }
}

function logEvent(event, fields) {
  if (!VALID_EVENTS.has(event)) {
    if (process.env.CORTEX_DEBUG) {
      process.stderr.write("[cortex:impact_log] invalid event: " + event + "\n");
    }
    return;
  }
  const payload = { v: SCHEMA_VERSION, ts: nowIso(), ev: event };
  for (const [key, value] of Object.entries(fields || {})) {
    if (value === undefined || value === null) continue;
    payload[key] = value;
  }
  appendLine(JSON.stringify(payload));
}

function logInjectBatch(instincts, ctx) {
  // instincts: [{id, confidence, domain}]
  // ctx: {tool, pid, sid}
  if (!instincts || instincts.length === 0) return;
  for (const inst of instincts) {
    logEvent("inject", {
      iid: inst.id,
      tool: ctx && ctx.tool,
      pid: ctx && ctx.pid,
      sid: ctx && ctx.sid,
      conf: typeof inst.confidence === "number" ? Math.round(inst.confidence * 100) / 100 : undefined,
      dom: inst.domain,
    });
  }
}

function logFollow(iid, followed, errAfter, sid, windowSize) {
  logEvent("follow", { iid, followed, err_after: errAfter, sid, win: windowSize });
}

function logReject(iid, reason, sid) {
  logEvent("reject", { iid, reason, sid });
}

module.exports = {
  SCHEMA_VERSION,
  IMPACT_FILE,
  logEvent,
  logInjectBatch,
  logFollow,
  logReject,
};
