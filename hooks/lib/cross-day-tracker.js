'use strict';

const fs = require('fs');
const path = require('path');
const crypto = require('crypto');

const HOME = process.env.HOME || process.env.USERPROFILE || '/tmp';
const CORTEX_DIR = process.env.CORTEX_DIR || path.join(HOME, '.claude', 'cortex');
const TRACKER_PATH = path.join(CORTEX_DIR, 'cross-day-tracker.jsonl');

const BOOST_TIERS = [
  { minDays: 8, boost: 0.15 },
  { minDays: 4, boost: 0.10 },
  { minDays: 2, boost: 0.05 },
];
const CONFIDENCE_CAP = 0.95;
const JACCARD_THRESHOLD = 0.70;
const PRUNE_DAYS = 365;

let _trackerCache = null;

function ensureDir(dir) {
  try {
    fs.mkdirSync(dir, { recursive: true, mode: 0o700 });
  } catch (e) { /* ignore */ }
}

function normalizeTrigger(trigger) {
  return String(trigger || '')
    .toLowerCase()
    .replace(/[\\.|()\[\]{}*+?^$]/g, ' ')
    .replace(/\s+/g, ' ')
    .trim();
}

function jaccardSimilarity(a, b) {
  const tokensA = new Set((a || '').split(' ').filter(Boolean));
  const tokensB = new Set((b || '').split(' ').filter(Boolean));
  if (tokensA.size === 0 && tokensB.size === 0) return 0;
  const intersection = [...tokensA].filter(x => tokensB.has(x)).length;
  const union = new Set([...tokensA, ...tokensB]).size;
  return union === 0 ? 0 : intersection / union;
}

function loadTrackerCache() {
  if (_trackerCache !== null) return _trackerCache;
  _trackerCache = [];
  try {
    if (!fs.existsSync(TRACKER_PATH)) return _trackerCache;
    const content = fs.readFileSync(TRACKER_PATH, 'utf8');
    for (const line of content.split('\n')) {
      const trimmed = line.trim();
      if (!trimmed) continue;
      try {
        _trackerCache.push(JSON.parse(trimmed));
      } catch (_) {
        // Skip malformed lines silently
      }
    }
  } catch (_) {}
  return _trackerCache;
}

function appendDetection(entry) {
  try {
    ensureDir(CORTEX_DIR);
    fs.appendFileSync(TRACKER_PATH, JSON.stringify(entry) + '\n', { mode: 0o600 });
    if (_trackerCache !== null) _trackerCache.push(entry);
  } catch (_) {}
}

function applyCrossDayBoost(proposal) {
  const today = new Date().toISOString().slice(0, 10);
  const triggerNorm = normalizeTrigger(proposal.trigger);
  const tracker = loadTrackerCache();

  // Find matches: exact id OR Jaccard similarity above threshold.
  // Jaccard only activates for multi-token triggers (≥2 tokens) to avoid
  // false positives between unrelated single-token triggers like 'Bash' or 'Edit'.
  const triggerTokens = triggerNorm.split(' ').filter(Boolean);
  const useJaccard = triggerTokens.length >= 2;

  const matches = tracker.filter(e => {
    if (e.pattern_id === proposal.id) return true;
    if (!useJaccard) return false;
    const eTokens = (e.trigger_norm || '').split(' ').filter(Boolean);
    if (eTokens.length < 2) return false;
    return jaccardSimilarity(e.trigger_norm || '', triggerNorm) >= JACCARD_THRESHOLD;
  });

  const distinctDates = new Set(matches.map(m => m.date).filter(Boolean));
  distinctDates.add(today);

  // v3.28.4 — guard against same-day re-appends. Stop hook re-processes
  // observations on every session close, so the same pattern_id can be
  // emitted dozens of times per day. Only append once per (date, pattern_id)
  // to bound tracker file size. Distinct-date counting (boost logic) is
  // unaffected because the first append of the day is always made.
  const alreadyToday = matches.some(e =>
    e.date === today && e.pattern_id === proposal.id
  );
  if (!alreadyToday) {
    appendDetection({
      date: today,
      pattern_id: proposal.id,
      trigger_norm: triggerNorm,
      source_detector: proposal.source || 'unknown',
    });
  }

  const dayCount = distinctDates.size;
  let boost = 0;
  for (const tier of BOOST_TIERS) {
    if (dayCount >= tier.minDays) {
      boost = tier.boost;
      break;
    }
  }

  const existingTags = Array.isArray(proposal.tags) ? proposal.tags : [];
  const newTags = existingTags.filter(t => !/^cross-day-\d+$/.test(t));
  newTags.push(`cross-day-${dayCount}`);

  return {
    ...proposal,
    confidence: Math.min(CONFIDENCE_CAP, (proposal.confidence || 0) + boost),
    cross_day_count: dayCount,
    tags: newTags,
  };
}

// Known race: if Node appendFileSync runs between prune's readFile and renameSync,
// that appended line is lost. Impact is low (one tracker entry off by 1 day, self-heals
// on the next session). Cross-language locking (Node + Python) is deferred.
function prune(daysToKeep = PRUNE_DAYS) {
  if (!fs.existsSync(TRACKER_PATH)) return { before: 0, after: 0, pruned: 0 };
  const cutoff = new Date(Date.now() - daysToKeep * 86400000).toISOString().slice(0, 10);
  const lines = fs.readFileSync(TRACKER_PATH, 'utf8').split('\n');
  const kept = [];
  let before = 0;
  // v3.28.4 — also compact same-day same-pattern_id duplicates accumulated
  // before the dedup guard was added. Keeps the first occurrence per
  // (date, pattern_id) pair. Idempotent.
  const seen = new Set();
  for (const line of lines) {
    const trimmed = line.trim();
    if (!trimmed) continue;
    before++;
    try {
      const entry = JSON.parse(trimmed);
      if ((entry.date || '') < cutoff) continue;
      const key = `${entry.date}|${entry.pattern_id}`;
      if (seen.has(key)) continue;
      seen.add(key);
      kept.push(trimmed);
    } catch (_) {}
  }
  const tmp = TRACKER_PATH + '.tmp.' + process.pid;
  try {
    fs.writeFileSync(tmp, kept.length ? kept.join('\n') + '\n' : '', { mode: 0o600 });
    fs.renameSync(tmp, TRACKER_PATH);
    _trackerCache = null; // Invalidate cache
  } catch (_) {
    return { before, after: before, pruned: 0 };
  }
  return { before, after: kept.length, pruned: before - kept.length };
}

// Reset cache (for tests)
function _resetCache() { _trackerCache = null; }

module.exports = {
  applyCrossDayBoost,
  appendDetection,
  loadTrackerCache,
  jaccardSimilarity,
  normalizeTrigger,
  prune,
  _resetCache,
  TRACKER_PATH,
  BOOST_TIERS,
  CONFIDENCE_CAP,
  JACCARD_THRESHOLD,
  PRUNE_DAYS,
};
