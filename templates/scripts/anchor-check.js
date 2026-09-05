#!/usr/bin/env node
// phaneslight-template v3.8.0 anchor-check
// Resolves the precise pointers a plan, brief or handover uses against the WORKING TREE and
// names the ones that have gone stale. An anchor is a file:line, a block range, a measured line
// count or a numeric constant. It goes stale when it was accurate when written and the tree then
// moved underneath it: the pointer still resolves, still looks authoritative, and names something
// else. There is no compiler to reject that, so the failure is silent, plausible, and survives
// review by eye.
//
// Resolution is against the working tree and NEVER against HEAD (decision D3 of the v3.8.0 plan).
// A handover written mid-edit must see what its successor will see, and four of the five observed
// stale anchors were stale at write time or inside a single uncommitted edit, where no commit
// boundary exists for git history to see. Git history is not the oracle here; content is.
//
// Advisory by default: exit 0 whatever it finds, matching loc-check. --strict exits 1 on anything
// worse than OK, for a caller that wants a gate rather than a sensor.
//
// Usage: node anchor-check.js [--plan <file>] [--strict] [file ...]
//   With no positional file it reads the two PhanesLight-standard surfaces: CLAUDE.local.md at
//   the project root, and the highest-numbered SS file under <docRoot>/session-summaries/.
'use strict';
// BEGIN SHARED node-core
const fs = require('fs');
const os = require('os');
const path = require('path');
const crypto = require('crypto');
const { spawnSync } = require('child_process');

// The directory holding the running script, exported by the sh wrapper. __dirname does not
// exist under `node -`, which is how every one of these programs is launched, so sibling
// resolution goes through this and never through __dirname or process.argv[1].
const HERE = process.env.PHANESLIGHT_HERE || '';

// The house root pattern: walk up from the current directory for .phaneslight/config.json,
// null when there is none. Terminates at the filesystem root by comparing the parent to the
// child, which is the one honest termination condition dirname gives on every platform.
function findRoot() {
  let d;
  try { d = process.cwd(); } catch (e) { return null; }
  for (;;) {
    try {
      if (fs.existsSync(path.join(d, '.phaneslight', 'config.json'))) return d;
    } catch (e) { /* an unreadable rung is not a root; keep walking */ }
    const p = path.dirname(d);
    if (!p || p === d) return null;
    d = p;
  }
}

// The user home directory, or null, NEVER a throw. A script contractually bound to always
// exit 0 must not die because HOME is unset, which is the POSIX shape of the Windows
// USERPROFILE defect recorded in lib/windows/shared.ps1.
function homeDir() {
  const h = process.env.HOME;
  if (typeof h === 'string' && h.trim() !== '') return h;
  try {
    const o = os.homedir();
    if (typeof o === 'string' && o.trim() !== '') return o;
  } catch (e) { /* fall through */ }
  return null;
}

// Guarded JSON read with the FOUR outcomes a sensor has to be able to tell apart. Returns
// { status: 'ok' | 'absent' | 'unreadable' | 'malformed', value, reason }.
//
// 'absent' and 'unreadable' are DIFFERENT ANSWERS and conflating them is the fabricated empty
// set this codebase bans outright. The five malformed shapes refused here are exactly the five
// the Windows sibling refuses: empty or whitespace only, not valid JSON, the literal null, a
// top level that is not an object, and a missing requireMember for a caller that knows its
// shape. An array top level is not an object: Array.isArray is tested explicitly because
// typeof [] is 'object'.
function readJsonFile(p, requireMember) {
  const res = { status: 'absent', value: null, reason: null };
  let st = null;
  try {
    st = fs.lstatSync(p);
  } catch (e) {
    if (e && e.code === 'ENOENT') return res;
    res.status = 'unreadable';
    res.reason = 'existence could not be determined: ' + (e && e.message ? e.message : String(e));
    return res;
  }
  if (st.isDirectory()) {
    res.status = 'unreadable';
    res.reason = 'path is a directory, not a file';
    return res;
  }
  let raw = null;
  try {
    raw = fs.readFileSync(p, 'utf8');
  } catch (e) {
    res.status = 'unreadable';
    res.reason = e && e.message ? e.message : String(e);
    return res;
  }
  if (raw === null || raw.trim().length === 0) {
    res.status = 'malformed';
    res.reason = 'file is empty or whitespace only';
    return res;
  }
  let parsed;
  try {
    parsed = JSON.parse(raw.charCodeAt(0) === 0xfeff ? raw.slice(1) : raw);
  } catch (e) {
    res.status = 'malformed';
    res.reason = 'not valid JSON';
    return res;
  }
  if (parsed === null) {
    res.status = 'malformed';
    res.reason = 'JSON literal null';
    return res;
  }
  if (typeof parsed !== 'object' || Array.isArray(parsed)) {
    res.status = 'malformed';
    res.reason = 'top level is not a JSON object';
    return res;
  }
  if (typeof requireMember === 'string' && requireMember !== '') {
    if (!Object.prototype.hasOwnProperty.call(parsed, requireMember)) {
      res.status = 'malformed';
      res.reason = "required member '" + requireMember + "' is absent";
      return res;
    }
  }
  res.status = 'ok';
  res.value = parsed;
  return res;
}

// The line-oriented sibling of the above, for the run-progress ledger and every other plain
// text surface. Same three-state contract and the same reason for it: a ledger that EXISTS but
// cannot be read must never report the verdict a ledger that is not there reports, because
// 'absent' is the fresh-project answer and acting on it archives or overwrites a run whose
// state was never seen. A directory in the file's place is 'unreadable'.
function readTextFile(p) {
  const res = { status: 'absent', text: null, reason: null };
  let st = null;
  try {
    st = fs.lstatSync(p);
  } catch (e) {
    if (e && e.code === 'ENOENT') return res;
    res.status = 'unreadable';
    res.reason = e && e.message ? e.message : String(e);
    return res;
  }
  if (st.isDirectory()) {
    res.status = 'unreadable';
    res.reason = 'path is a directory, not a file';
    return res;
  }
  try {
    res.text = fs.readFileSync(p, 'utf8');
    res.status = 'ok';
  } catch (e) {
    res.status = 'unreadable';
    res.reason = e && e.message ? e.message : String(e);
  }
  return res;
}

// node-parity JSON, and NOT JSON.stringify, for two measured reasons.
//
// 1. A plain JS object emits integer-like keys FIRST, in numeric order, whatever the insertion
//    order was. annotated-files.json, state.files and the doc-index dictionaries are all keyed
//    by user paths, so a tracked file named 123 would move to the top and the two platforms
//    would write different bytes. Every user-keyed dictionary is therefore built as a Map and
//    emitted here in insertion order. A Map is the ONLY container in this codebase allowed to
//    carry user-supplied keys.
// 2. JSON.stringify escapes a lone surrogate as \udXXX where the Windows emitter writes the
//    code unit raw. Iterating code units and appending them keeps the two in step.
//
// Layout matches JSON.stringify(x, null, 2): two-space indent, "key": value, one element per
// line, {} and [] for empty. Numbers: every value these reports emit is an integer, so
// String(n) matches the Windows InvariantCulture conversion.
function jsonStringLiteral(s) {
  let out = '"';
  for (let i = 0; i < s.length; i++) {
    const c = s.charCodeAt(i);
    if (c === 0x22) out += '\\"';
    else if (c === 0x5c) out += '\\\\';
    else if (c === 0x08) out += '\\b';
    else if (c === 0x0c) out += '\\f';
    else if (c === 0x0a) out += '\\n';
    else if (c === 0x0d) out += '\\r';
    else if (c === 0x09) out += '\\t';
    else if (c < 0x20) out += '\\u' + ('0000' + c.toString(16)).slice(-4);
    else out += s[i];
  }
  return out + '"';
}

function toNodeJson(value, indent) {
  const pad = ' '.repeat(indent);
  const padIn = ' '.repeat(indent + 2);
  if (value === null || value === undefined) return 'null';
  if (typeof value === 'string') return jsonStringLiteral(value);
  if (typeof value === 'boolean') return value ? 'true' : 'false';
  if (typeof value === 'number') return String(value);
  if (value instanceof Map) {
    if (value.size === 0) return '{}';
    const parts = [];
    for (const k of value.keys()) {
      parts.push(padIn + jsonStringLiteral(String(k)) + ': ' + toNodeJson(value.get(k), indent + 2));
    }
    return '{\n' + parts.join(',\n') + '\n' + pad + '}';
  }
  if (Array.isArray(value)) {
    if (value.length === 0) return '[]';
    const parts = [];
    for (const it of value) parts.push(padIn + toNodeJson(it, indent + 2));
    return '[\n' + parts.join(',\n') + '\n' + pad + ']';
  }
  if (typeof value === 'object') {
    const keys = Object.keys(value);
    if (keys.length === 0) return '{}';
    const parts = [];
    for (const k of keys) parts.push(padIn + jsonStringLiteral(k) + ': ' + toNodeJson(value[k], indent + 2));
    return '{\n' + parts.join(',\n') + '\n' + pad + '}';
  }
  return jsonStringLiteral(String(value));
}

function emitJson(value) {
  process.stdout.write(toNodeJson(value, 0) + '\n');
}

function sha256Hex(buf) {
  return crypto.createHash('sha256').update(buf).digest('hex');
}

// Is target inside root? Lexical containment first, with the trailing separator forced onto
// the root because without it /proj-evil passes a prefix test against /proj. The root itself
// counts as contained. Comparison is ORDINAL and case-sensitive: POSIX paths are.
//
// Then the symlink walk, which is the POSIX shape of the reparse-point ancestor check in
// batch-apply.ps1: a lexically contained path can still resolve outside the project if the
// target OR any directory between it and the root is a symbolic link. lstat, never stat: stat
// follows the link and reports the destination, which is exactly the fact being hidden.
function contained(root, target) {
  if (!root || !target) return false;
  const r = path.resolve(root);
  const t = path.resolve(target);
  if (t !== r) {
    const rp = r.endsWith(path.sep) ? r : r + path.sep;
    if (t.indexOf(rp) !== 0) return false;
  }
  let d = t;
  while (d && d !== r && d.length > r.length) {
    try {
      if (fs.lstatSync(d).isSymbolicLink()) return false;
    } catch (e) { /* absent is not a symlink; a path being created is the normal case */ }
    const p = path.dirname(d);
    if (!p || p === d) break;
    d = p;
  }
  return true;
}

// Run a child process and report what happened, never guessing. The verdict comes from the
// exit code and NEVER from the presence of stderr text: a tool that chatters on stderr and
// exits 0 succeeded, and treating its chatter as failure is the defect preflight.ps1 records
// at its B5 rule. An unlaunchable command (absent from PATH) is reported as available: false
// with the reason, not as an empty result.
function runChild(cmd, args, opts) {
  const o = opts || {};
  const r = spawnSync(cmd, args, {
    cwd: o.cwd || undefined,
    encoding: 'utf8',
    timeout: typeof o.timeoutMs === 'number' ? o.timeoutMs : 60000,
    killSignal: 'SIGKILL',
    stdio: ['ignore', 'pipe', 'pipe'],
    windowsHide: true
  });
  if (r.error) {
    return { available: false, code: null, stdout: '', stderr: '', reason: r.error.message };
  }
  if (r.status === null) {
    return { available: false, code: null, stdout: r.stdout || '', stderr: r.stderr || '',
             reason: 'terminated by signal ' + String(r.signal) };
  }
  return { available: true, code: r.status, stdout: r.stdout || '', stderr: r.stderr || '', reason: null };
}
// END SHARED node-core

// ------------------------------------------------------------------------------------------
// Arguments. Unknown flags are reported rather than ignored: a sensor that silently drops the
// flag you asked it for reports on something other than what you asked about.
// ------------------------------------------------------------------------------------------
const ARGV = process.argv.slice(2);
const OPTS = { strict: false, plan: null, inputs: [], bad: [] };
for (let i = 0; i < ARGV.length; i++) {
  const a = ARGV[i];
  if (a === '--strict') { OPTS.strict = true; }
  else if (a === '--plan') { i++; if (i < ARGV.length) OPTS.plan = ARGV[i]; else OPTS.bad.push('--plan needs a file'); }
  else if (a.indexOf('--plan=') === 0) { OPTS.plan = a.slice(7); }
  else if (a.indexOf('--') === 0) { OPTS.bad.push('unknown flag ' + a); }
  else { OPTS.inputs.push(a); }
}

const OUT = [];
function say(s) { OUT.push(s); }
function flush() { process.stdout.write(OUT.join('\n') + '\n'); }

const ROOT = findRoot();
if (!ROOT) {
  process.stderr.write('anchor-check: .phaneslight/config.json not found from this directory\n');
  process.exit(0);
}

for (const b of OPTS.bad) process.stderr.write('anchor-check: ' + b + '\n');

// ------------------------------------------------------------------------------------------
// Configuration. Every key is optional and every default is STATED in the output rather than
// assumed, because a default nobody can see is a default nobody can correct.
// ------------------------------------------------------------------------------------------
const CFG_READ = readJsonFile(path.join(ROOT, '.phaneslight', 'config.json'));
const CFG = CFG_READ.status === 'ok' ? CFG_READ.value : {};
if (CFG_READ.status === 'unreadable' || CFG_READ.status === 'malformed') {
  process.stderr.write('anchor-check: .phaneslight/config.json is ' + CFG_READ.status + ' (' + CFG_READ.reason + '); using defaults\n');
}
let DOC_ROOT = typeof CFG.docRoot === 'string' && CFG.docRoot.trim() !== '' ? CFG.docRoot.trim() : 'documentation';
DOC_ROOT = DOC_ROOT.replace(/\\/g, '/').replace(/\/+$/, '');
if (DOC_ROOT === '') DOC_ROOT = 'documentation';

const AC = (CFG.anchorCheck && typeof CFG.anchorCheck === 'object' && !Array.isArray(CFG.anchorCheck)) ? CFG.anchorCheck : {};
const DEFAULT_CONTROL_ROOTS = ['tests', 'test', '__tests__', 'spec'];
let CONTROL_ROOTS = DEFAULT_CONTROL_ROOTS;
let CONTROL_ROOTS_DECLARED = false;
if (Array.isArray(AC.controlRoots)) {
  const cleaned = AC.controlRoots.filter(function (r) { return typeof r === 'string' && r.trim() !== ''; })
    .map(function (r) { return r.trim().replace(/\\/g, '/').replace(/^\/+|\/+$/g, ''); });
  if (cleaned.length > 0) { CONTROL_ROOTS = cleaned; CONTROL_ROOTS_DECLARED = true; }
}
const OBLIGATIONS = Array.isArray(AC.obligations) ? AC.obligations.filter(function (o) { return o && typeof o === 'object' && !Array.isArray(o); }) : [];

// ------------------------------------------------------------------------------------------
// Candidate paths, in the order of 2.3. git first because it is the only source that knows what
// is ignored: the fallback walk would see roughly 150 installed copies of a script the git list
// answers uniquely for, and would report AMBIGUOUS where git reports one file. A fallback that
// cannot honour .gitignore says so in the summary rather than quietly answering differently.
// ------------------------------------------------------------------------------------------
function listCandidates() {
  const g = runChild('git', ['ls-files', '--cached', '--others', '--exclude-standard'], { cwd: ROOT, timeoutMs: 60000 });
  if (g.available && g.code === 0) {
    const list = g.stdout.split('\n').map(function (s) { return s.trim(); }).filter(function (s) { return s !== ''; });
    if (list.length > 0) return { list: list, source: 'git ls-files (cached, others, exclude-standard)', honoursIgnores: true };
  }
  const raw = readTextFile(path.join(ROOT, '.phaneslight', 'inventory', 'raw-files.txt'));
  if (raw.status === 'ok') {
    const list = raw.text.split('\n').map(function (s) { return s.trim().replace(/\\/g, '/'); }).filter(function (s) { return s !== ''; });
    if (list.length > 0) return { list: list, source: '.phaneslight/inventory/raw-files.txt (regenerated by repo-manifest)', honoursIgnores: true };
  }
  const list = [];
  const skipDirs = { '.git': 1, 'node_modules': 1 };
  const archive = DOC_ROOT + '/archive';
  const MAX = 20000;
  function walk(rel) {
    if (list.length >= MAX) return;
    let entries = [];
    try { entries = fs.readdirSync(path.join(ROOT, rel), { withFileTypes: true }); } catch (e) { return; }
    for (const ent of entries) {
      const child = rel === '' ? ent.name : rel + '/' + ent.name;
      if (ent.isDirectory()) {
        if (skipDirs[ent.name]) continue;
        if (child === archive) continue;
        walk(child);
      } else if (ent.isFile()) {
        if (list.length >= MAX) return;
        list.push(child);
      }
    }
  }
  walk('');
  return { list: list, source: 'a bounded walk (.git, node_modules and ' + archive + ' excluded); it does NOT honour .gitignore, so a token with installed copies may read AMBIGUOUS here where git would answer uniquely', honoursIgnores: false };
}

const CAND = listCandidates();
const CANDIDATES = CAND.list;
const BY_EXACT = new Set(CANDIDATES);

// ------------------------------------------------------------------------------------------
// Path resolution, in the order of 2.3. Returns { status, path, hits }.
// ------------------------------------------------------------------------------------------
function resolveToken(tokenRaw) {
  const token = String(tokenRaw).replace(/\\/g, '/').replace(/^\.\//, '');
  if (BY_EXACT.has(token)) return { status: 'ok', path: token, hits: [token] };
  const suffix = CANDIDATES.filter(function (c) { return c === token || c.endsWith('/' + token); });
  if (suffix.length === 1) return { status: 'ok', path: suffix[0], hits: suffix };
  if (suffix.length > 1) return { status: 'ambiguous', path: null, hits: suffix };
  if (token.indexOf('/') === -1 && !/\.[A-Za-z0-9]{1,8}$/.test(token)) {
    const pre = CANDIDATES.filter(function (c) {
      const b = c.slice(c.lastIndexOf('/') + 1);
      if (b.length <= token.length) return false;
      if (b.slice(0, token.length) !== token) return false;
      return !/[A-Za-z0-9]/.test(b.charAt(token.length));
    });
    if (pre.length === 1) return { status: 'ok', path: pre[0], hits: pre };
    if (pre.length > 1) return { status: 'ambiguous', path: null, hits: pre };
  }
  return { status: 'missing', path: null, hits: [] };
}

const LINE_CACHE = new Map();
function linesOf(rel) {
  if (LINE_CACHE.has(rel)) return LINE_CACHE.get(rel);
  const r = readTextFile(path.join(ROOT, rel));
  let lines = null;
  if (r.status === 'ok') {
    lines = r.text.split('\n');
    if (lines.length > 0 && lines[lines.length - 1] === '') lines.pop();
  }
  LINE_CACHE.set(rel, lines);
  return lines;
}

// ------------------------------------------------------------------------------------------
// Anchor parsing. A token is STRONGLY pathish when it carries a slash, a backslash or a dotted
// extension: that is the author's own evidence of intent, and such a token that does not resolve
// is reported MISSING. A bare stem (t75) is admitted only when it resolves, so ordinary prose
// like "Phase 1:2" is dropped rather than reported. The resolve-or-drop filter is what keeps a
// pattern scan over English from becoming a noise generator.
// ------------------------------------------------------------------------------------------
function isStronglyPathish(tok) {
  return tok.indexOf('/') !== -1 || tok.indexOf('\\') !== -1 || /\.[A-Za-z0-9]{1,8}$/.test(tok);
}

// Reads a double-quoted string starting at i (which must be the quote). Honours backslash
// escapes, so an expectation containing an escaped quote survives. Returns { value, end } or null.
function readQuoted(s, i) {
  if (s.charAt(i) !== '"') return null;
  let out = '';
  let j = i + 1;
  while (j < s.length) {
    const c = s.charAt(j);
    if (c === '\\' && j + 1 < s.length) { out += s.charAt(j + 1); j += 2; continue; }
    if (c === '"') return { value: out, end: j + 1 };
    out += c; j++;
  }
  return null;
}

function skipSpace(s, i) { while (i < s.length && (s.charAt(i) === ' ' || s.charAt(i) === '\t')) i++; return i; }

const TOKEN_RE = /(?<![A-Za-z0-9_.])(\.?[A-Za-z0-9_][A-Za-z0-9_.\-]*(?:[\/\\][A-Za-z0-9_.\-]+)*):(\d+)(?:-(\d+))?/g;
const CONST_RE = /\$([A-Za-z_][A-Za-z0-9_]*)\s*=\s*("(?:[^"\\]|\\.)*"|'(?:[^'\\]|\\.)*'|[^\s`,;)\]"']+)/g;
const COUNT_RE = /([A-Za-z0-9_][A-Za-z0-9_.\-]*(?:[\/\\][A-Za-z0-9_.\-]+)*)\s+is\s+(\d+)\s+lines\b/g;

function parseAnchors(text, sourceName) {
  const found = [];
  const lines = text.split('\n');
  for (let ln = 0; ln < lines.length; ln++) {
    const line = lines[ln];
    const where = sourceName + ':' + (ln + 1);

    TOKEN_RE.lastIndex = 0;
    let m;
    while ((m = TOKEN_RE.exec(line)) !== null) {
      const tok = m[1];
      const n1 = parseInt(m[2], 10);
      const n2 = m[3] ? parseInt(m[3], 10) : null;
      // A URL or a timestamp is not a path. Reject a token that is only digits, and reject the
      // scheme of a URL, whose "//" the token pattern cannot produce but whose host it can.
      if (/^\d+$/.test(tok)) continue;
      let i = skipSpace(line, m.index + m[0].length);
      let expect = null, expect2 = null;
      const q1 = readQuoted(line, i);
      if (q1) {
        expect = q1.value;
        i = skipSpace(line, q1.end);
        if (line.slice(i, i + 2) === '..') {
          i = skipSpace(line, i + 2);
          const q2 = readQuoted(line, i);
          if (q2) expect2 = q2.value;
        }
      }
      found.push({ kind: n2 === null ? 'line' : 'block', token: tok, n: n1, n2: n2, expect: expect, expect2: expect2, where: where, raw: m[0] + (expect !== null ? ' "' + expect + '"' : '') });
    }

    CONST_RE.lastIndex = 0;
    while ((m = CONST_RE.exec(line)) !== null) {
      if (m[2].charAt(0) === '<') continue;
      found.push({ kind: 'const', name: m[1], value: m[2], where: where, raw: '$' + m[1] + ' = ' + m[2] });
    }

    COUNT_RE.lastIndex = 0;
    while ((m = COUNT_RE.exec(line)) !== null) {
      found.push({ kind: 'count', token: m[1], n: parseInt(m[2], 10), where: where, raw: m[1] + ' is ' + m[2] + ' lines' });
    }
  }
  return found;
}

// ------------------------------------------------------------------------------------------
// Verdicts.
// ------------------------------------------------------------------------------------------
function hitsFor(lines, needle) {
  const hits = [];
  for (let i = 0; i < lines.length; i++) if (lines[i].indexOf(needle) !== -1) hits.push(i + 1);
  return hits;
}

// K is the hit NEAREST the cited line, and the rest are listed after it. A reader re-anchoring by
// hand picks the nearest hit; reporting the first would send them to a different one.
function movedText(hits, cited) {
  const sorted = hits.slice().sort(function (a, b) { return Math.abs(a - cited) - Math.abs(b - cited) || a - b; });
  const k = sorted[0];
  const rest = hits.filter(function (h) { return h !== k; }).sort(function (a, b) { return a - b; });
  return rest.length === 0 ? 'MOVED (found at :' + k + ')' : 'MOVED (found at :' + k + '; also ' + rest.map(function (h) { return ':' + h; }).join(', ') + ')';
}

function verdictForLine(a) {
  const r = resolveToken(a.token);
  if (r.status === 'ambiguous') return { v: 'AMBIGUOUS', note: r.hits.slice(0, 6).join(', ') + (r.hits.length > 6 ? ', ...' : '') };
  if (r.status === 'missing') {
    if (!isStronglyPathish(a.token)) return null;
    return { v: 'MISSING', note: 'no candidate path matches ' + a.token };
  }
  if (a.expect === null) return { v: 'UNVERIFIABLE', note: r.path + ' resolves; the anchor carries no expectation to check' };
  const lines = linesOf(r.path);
  if (lines === null) return { v: 'MISSING', note: r.path + ' could not be read' };
  const cited = lines[a.n - 1];
  if (typeof cited === 'string' && cited.indexOf(a.expect) !== -1) return { v: 'OK', note: r.path };
  const hits = hitsFor(lines, a.expect);
  if (hits.length === 0) return { v: 'MISSING', note: r.path + ' does not contain the expectation anywhere' };
  return { v: movedText(hits, a.n), note: r.path };
}

function verdictForBlock(a) {
  const r = resolveToken(a.token);
  if (r.status === 'ambiguous') return { v: 'AMBIGUOUS', note: r.hits.slice(0, 6).join(', ') + (r.hits.length > 6 ? ', ...' : '') };
  if (r.status === 'missing') {
    if (!isStronglyPathish(a.token)) return null;
    return { v: 'MISSING', note: 'no candidate path matches ' + a.token };
  }
  // A bare range still participates in the plan intersection (Phase 3), and is UNVERIFIABLE as an
  // anchor in its own right. The fixture's extraction designs write their ranges bare, so a rule
  // that ignored them would make the intersection unable to fire on real input.
  if (a.expect === null) return { v: 'UNVERIFIABLE', note: r.path + ' resolves; the block carries no first-line or last-line expectation' };
  const lines = linesOf(r.path);
  if (lines === null) return { v: 'MISSING', note: r.path + ' could not be read' };
  const first = lines[a.n - 1];
  const okFirst = typeof first === 'string' && first.indexOf(a.expect) !== -1;
  if (a.expect2 === null) {
    if (okFirst) return { v: 'UNVERIFIABLE', note: r.path + ' first line matches; the block carries no last-line expectation' };
    const hits = hitsFor(lines, a.expect);
    if (hits.length === 0) return { v: 'MISSING', note: r.path + ' does not contain the first-line expectation' };
    return { v: movedText(hits, a.n), note: r.path };
  }
  const last = lines[a.n2 - 1];
  const okLast = typeof last === 'string' && last.indexOf(a.expect2) !== -1;
  if (okFirst && okLast) return { v: 'OK', note: r.path };
  const h1 = hitsFor(lines, a.expect);
  const h2 = hitsFor(lines, a.expect2);
  if (h1.length === 0 || h2.length === 0) return { v: 'MISSING', note: r.path + ' does not contain ' + (h1.length === 0 ? 'the first-line' : 'the last-line') + ' expectation' };
  const k1 = movedText(h1, a.n).replace(/^MOVED \(found at :(\d+).*$/, '$1');
  const k2 = movedText(h2, a.n2).replace(/^MOVED \(found at :(\d+).*$/, '$1');
  return { v: 'MOVED (found at :' + k1 + '-' + k2 + ')', note: r.path };
}

// A constant carries no path. It resolves against ASSIGNMENT lines outside docRoot and outside
// .md, because the prose that quotes a stale value is exactly what must not be read as the
// definition: the fixture names $DUPLICATED_TOTAL in 13 files and assigns it in exactly one.
function verdictForConst(a) {
  const pool = CANDIDATES.filter(function (c) {
    if (c === DOC_ROOT || c.indexOf(DOC_ROOT + '/') === 0) return false;
    return !/\.md$/i.test(c);
  });
  const asg = new RegExp('^\\s*(?:\\$|(?:const|let|var|set)\\s+\\$?)?' + a.name + '\\s*=\\s*(.+)$');
  const found = [];
  for (const c of pool) {
    const lines = linesOf(c);
    if (lines === null) continue;
    for (let i = 0; i < lines.length; i++) {
      const m = asg.exec(lines[i]);
      if (m) found.push({ file: c, line: i + 1, value: stripTrailingComment(m[1].trim()) });
    }
  }
  if (found.length === 0) return { v: 'MISSING', note: 'no assignment of ' + a.name + ' outside ' + DOC_ROOT + '/ and *.md' };
  if (found.length > 1) return { v: 'AMBIGUOUS', note: found.map(function (f) { return f.file + ':' + f.line; }).slice(0, 6).join(', ') };
  const want = stripTrailingComment(String(a.value).trim());
  if (found[0].value === want) return { v: 'OK', note: found[0].file + ':' + found[0].line };
  return { v: 'MISMATCH (' + found[0].value + ')', note: found[0].file + ':' + found[0].line };
}

// A value may carry its own provenance comment, which is the good habit this command codifies
// rather than invents: "# measured <date> after <event>; was <prior value>". The comment is not
// part of the value. A quoted value keeps everything inside its quotes.
function stripTrailingComment(s) {
  if (s.charAt(0) === '"' || s.charAt(0) === "'") {
    const q = s.charAt(0);
    for (let i = 1; i < s.length; i++) {
      if (s.charAt(i) === '\\') { i++; continue; }
      if (s.charAt(i) === q) return s.slice(0, i + 1);
    }
    return s;
  }
  let cut = s.length;
  const h = s.indexOf(' #'); if (h !== -1 && h < cut) cut = h;
  const d = s.indexOf(' //'); if (d !== -1 && d < cut) cut = d;
  const c = s.indexOf(' ;'); if (c !== -1 && c < cut) cut = c;
  return s.slice(0, cut).trim().replace(/[,;]$/, '');
}

function verdictForCount(a) {
  const r = resolveToken(a.token);
  if (r.status === 'ambiguous') return { v: 'AMBIGUOUS', note: r.hits.slice(0, 6).join(', ') };
  if (r.status === 'missing') { if (!isStronglyPathish(a.token)) return null; return { v: 'MISSING', note: 'no candidate path matches ' + a.token }; }
  const lines = linesOf(r.path);
  if (lines === null) return { v: 'MISSING', note: r.path + ' could not be read' };
  if (lines.length === a.n) return { v: 'OK', note: r.path };
  return { v: 'MISMATCH (' + lines.length + ')', note: r.path };
}

// ------------------------------------------------------------------------------------------
// Inputs. Both defaults are PhanesLight-standard surfaces, and the summary says which rule chose
// the session summary, because "highest numbered" and "newest mtime" can disagree and a reader
// who does not know which one ran cannot tell whether the right file was read.
// ------------------------------------------------------------------------------------------
function defaultInputs() {
  const chosen = [];
  const notes = [];
  const reg = 'CLAUDE.local.md';
  if (fs.existsSync(path.join(ROOT, reg))) chosen.push(reg); else notes.push('CLAUDE.local.md is not present at the project root');
  const ssDir = DOC_ROOT + '/session-summaries';
  let entries = [];
  try { entries = fs.readdirSync(path.join(ROOT, ssDir)); } catch (e) { entries = []; }
  const ss = entries.filter(function (n) { return /^SS\d+.*\.md$/i.test(n); });
  if (ss.length > 0) {
    let best = null, bestN = -1;
    for (const n of ss) {
      const m = /^SS(\d+)/i.exec(n);
      const v = m ? parseInt(m[1], 10) : -1;
      if (v > bestN) { bestN = v; best = n; }
    }
    chosen.push(ssDir + '/' + best);
    notes.push('session summary chosen by highest SS number (' + best + ')');
  } else if (entries.length > 0) {
    let best = null, bestT = -1;
    for (const n of entries) {
      if (!/\.md$/i.test(n)) continue;
      let st; try { st = fs.statSync(path.join(ROOT, ssDir, n)); } catch (e) { continue; }
      if (st.mtimeMs > bestT) { bestT = st.mtimeMs; best = n; }
    }
    if (best) { chosen.push(ssDir + '/' + best); notes.push('session summary chosen by newest mtime (' + best + '); no filename matched the SS numbering'); }
  } else {
    notes.push('no session summaries found under ' + ssDir + '/');
  }
  return { chosen: chosen, notes: notes };
}

const inputList = [];
const inputNotes = [];
if (OPTS.inputs.length > 0) {
  for (const f of OPTS.inputs) inputList.push(f.replace(/\\/g, '/'));
} else {
  const d = defaultInputs();
  for (const f of d.chosen) inputList.push(f);
  for (const n of d.notes) inputNotes.push(n);
}
if (OPTS.plan) inputList.push(OPTS.plan.replace(/\\/g, '/'));


// ------------------------------------------------------------------------------------------
// Pin discovery (2.4). A pin is a LINE-PINNED CONTROL KEY: a quoted string literal naming a path
// and a line, which a control uses to assert something about that exact site. It is DISCOVERED
// and never declared, because the pin that bit was inside a control coupled to a change by a
// mechanism nobody had read, and a required declaration list is that same undeclared-coupling
// problem moved up one level. Declaration only WIDENS the search; it never replaces it.
//
// String literals look the same in .ps1, .js, .py, .go and .rs, so the pattern is
// language-agnostic. Every hit whose path does not resolve is DROPPED, and that filter is what
// removes the regex literals and format strings a bare pattern scan would otherwise report as
// pins. Measured on the fixture corpus: 9 literal hits, 8 genuine pins, 1 false positive.
// ------------------------------------------------------------------------------------------
const PIN_LITERAL_RE = /'([^'\n]{3,200})'|"([^"\n]{3,200})"/g;
const PIN_SHAPE_RE = /^(.+?)[|:#](\d+)$/;

function underControlRoots(rel) {
  for (const r of CONTROL_ROOTS) { if (rel === r || rel.indexOf(r + '/') === 0) return true; }
  return false;
}

function discoverPins() {
  const pins = [];
  let scanned = 0;
  let dropped = 0;
  for (const c of CANDIDATES) {
    if (!underControlRoots(c)) continue;
    const lines = linesOf(c);
    if (lines === null) continue;
    scanned++;
    for (let i = 0; i < lines.length; i++) {
      PIN_LITERAL_RE.lastIndex = 0;
      let m;
      while ((m = PIN_LITERAL_RE.exec(lines[i])) !== null) {
        const lit = m[1] !== undefined ? m[1] : m[2];
        const sh = PIN_SHAPE_RE.exec(lit);
        if (!sh) continue;
        const p = sh[1];
        if (p.indexOf('/') === -1 && p.indexOf('\\') === -1 && !/\.[A-Za-z0-9]{1,8}$/.test(p)) continue;
        const r = resolveToken(p);
        if (r.status !== 'ok') { dropped++; continue; }
        pins.push({ file: c, atLine: i + 1, literal: lit, target: r.path, targetLine: parseInt(sh[2], 10) });
      }
    }
  }
  return { pins: pins, scanned: scanned, dropped: dropped };
}

// ------------------------------------------------------------------------------------------
// Plan intersection. A block is MARKED when a word meaning deletion, extraction or movement
// occurs in the same paragraph as the path:A-B token. Paragraph rather than line, because a
// markdown table is one paragraph and the ranges that matter in practice are written in tables.
//
// A block with no substrings still participates. It is UNVERIFIABLE as an anchor in its own
// right, and it still intersects pins, because real extraction designs write their ranges bare
// and a rule that ignored them would leave the intersection unable to fire on real input.
// ------------------------------------------------------------------------------------------
const MARK_RE = /\b(delete|deleted|deletes|deleting|extract|extracted|extracts|extracting|move|moved|moves|moving|relocate|relocated)\b/i;

function planBlocks(text) {
  const out = [];
  const paras = text.split(/\n[ \t]*\n/);
  for (const para of paras) {
    if (!MARK_RE.test(para)) continue;
    TOKEN_RE.lastIndex = 0;
    let m;
    while ((m = TOKEN_RE.exec(para)) !== null) {
      if (!m[3]) continue;
      const r = resolveToken(m[1]);
      if (r.status !== 'ok') continue;
      out.push({ token: m[1], path: r.path, a: parseInt(m[2], 10), b: parseInt(m[3], 10) });
    }
  }
  return out;
}

// ------------------------------------------------------------------------------------------
// Obligations (2.6). Each is one grep. The plugin ships NO obligation table of its own: a
// project declares what its own couplings are, or it gets nothing, because the plugin cannot
// know any project's test layout, language or conventions.
// ------------------------------------------------------------------------------------------
function globToRe(g) {
  let out = '^';
  for (let i = 0; i < g.length; i++) {
    const ch = g.charAt(i);
    if (ch === '*') {
      if (g.charAt(i + 1) === '*') { out += '.*'; i++; if (g.charAt(i + 1) === '/') i++; }
      else out += '[^/]*';
    } else if (ch === '?') { out += '[^/]'; }
    else if ('.+^${}()|[]\\'.indexOf(ch) !== -1) { out += '\\' + ch; }
    else { out += ch; }
  }
  return new RegExp(out + '$');
}

// git status reports paths relative to the REPOSITORY root, which is not necessarily the project
// root: a plugin source tree can sit in a subdirectory of its own repository. The prefix is asked
// for rather than assumed, because assuming they are the same silently matches nothing.
function gitAddedFiles() {
  const out = [];
  const pre = runChild('git', ['rev-parse', '--show-prefix'], { cwd: ROOT });
  const prefix = (pre.available && pre.code === 0) ? pre.stdout.trim() : '';
  const g = runChild('git', ['status', '--porcelain'], { cwd: ROOT });
  if (!g.available || g.code !== 0) return out;
  for (const line of g.stdout.split('\n')) {
    if (line.trim() === '') continue;
    const st = line.slice(0, 2);
    if (st.indexOf('A') === -1 && st.indexOf('R') === -1 && st !== '??') continue;
    let p = line.slice(3).trim().replace(/^"|"$/g, '');
    const arrow = p.indexOf(' -> ');
    if (arrow !== -1) p = p.slice(arrow + 4);
    p = p.replace(/\\/g, '/');
    if (prefix && p.indexOf(prefix) === 0) p = p.slice(prefix.length);
    out.push(p);
  }
  return out;
}

function subjectFiles(planText) {
  const set = new Set();
  for (const f of gitAddedFiles()) set.add(f);
  if (planText) {
    const paras = planText.split(/\n[ \t]*\n/);
    const PATHY = /(?<![A-Za-z0-9_.])(\.?[A-Za-z0-9_][A-Za-z0-9_.\-]*(?:[\/\\][A-Za-z0-9_.\-]+)+)/g;
    for (const para of paras) {
      if (!/\bnew\b/i.test(para) && !/\bmoved?\b/i.test(para)) continue;
      PATHY.lastIndex = 0;
      let m;
      while ((m = PATHY.exec(para)) !== null) {
        const r = resolveToken(m[1]);
        if (r.status === 'ok') set.add(r.path);
      }
    }
  }
  return Array.from(set);
}

function checkObligations(subjects) {
  const misses = [];
  for (const ob of OBLIGATIONS) {
    if (typeof ob.glob !== 'string' || ob.glob === '') continue;
    let re;
    try { re = globToRe(ob.glob); } catch (e) { misses.push('OBLIGATION-MISS  glob ' + ob.glob + ' is not usable: ' + e.message); continue; }
    for (const f of subjects) {
      if (!re.test(f)) continue;
      const base = f.slice(f.lastIndexOf('/') + 1);
      const stem = base.replace(/\.[^.]*$/, '');
      if (Array.isArray(ob.mustAppearIn)) {
        for (const target of ob.mustAppearIn) {
          if (typeof target !== 'string' || target === '') continue;
          const t = readTextFile(path.join(ROOT, target));
          if (t.status !== 'ok') { misses.push('OBLIGATION-MISS  ' + f + ' must be mentioned in ' + target + ', which is ' + t.status); continue; }
          if (t.text.indexOf(stem) === -1) misses.push('OBLIGATION-MISS  ' + f + ' stem "' + stem + '" does not occur in ' + target);
        }
      }
      if (typeof ob.mustContain === 'string' && ob.mustContain !== '') {
        const t = readTextFile(path.join(ROOT, f));
        if (t.status !== 'ok') misses.push('OBLIGATION-MISS  ' + f + ' could not be read to check mustContain');
        else if (t.text.indexOf(ob.mustContain) === -1) misses.push('OBLIGATION-MISS  ' + f + ' does not contain "' + ob.mustContain + '"');
      }
    }
  }
  return misses;
}

// ------------------------------------------------------------------------------------------
// Report.
// ------------------------------------------------------------------------------------------
say('anchor-check v3.8.0, resolved against the working tree');
say('root: ' + ROOT);
say('candidates: ' + CANDIDATES.length + ' from ' + CAND.source);
say('inputs: ' + (inputList.length === 0 ? 'none' : inputList.join(', ')));
for (const n of inputNotes) say('  note: ' + n);

const anchors = [];
for (const rel of inputList) {
  const r = readTextFile(path.isAbsolute(rel) ? rel : path.join(ROOT, rel));
  if (r.status !== 'ok') { say('  note: input ' + rel + ' is ' + r.status + (r.reason ? ' (' + r.reason + ')' : '')); continue; }
  for (const a of parseAnchors(r.text, rel)) anchors.push(a);
}

const counts = { OK: 0, MOVED: 0, MISMATCH: 0, MISSING: 0, UNVERIFIABLE: 0, AMBIGUOUS: 0, 'WILL-MOVE': 0 };
const reported = [];
for (const a of anchors) {
  let res = null;
  if (a.kind === 'line') res = verdictForLine(a);
  else if (a.kind === 'block') res = verdictForBlock(a);
  else if (a.kind === 'const') res = verdictForConst(a);
  else if (a.kind === 'count') res = verdictForCount(a);
  if (res === null) continue;
  const head = res.v.split(' ')[0];
  if (Object.prototype.hasOwnProperty.call(counts, head)) counts[head]++;
  reported.push({ v: res.v, raw: a.raw, note: res.note, where: a.where });
}

say('');
if (reported.length === 0) {
  say('anchors: none found in the inputs above');
} else {
  for (const r of reported) say(r.v + '  ' + r.raw + '  [' + r.where + ']' + (r.note ? '  ' + r.note : ''));
}

// Plan intersection (Phase 3). A pin sitting BELOW the start of a block the plan moves will be
// pointing somewhere else once the plan is applied, and it will still resolve, which is the whole
// hazard. The intersection fires whether or not the extraction has already happened.
let planText = null;
if (OPTS.plan) {
  const pr = readTextFile(path.isAbsolute(OPTS.plan) ? OPTS.plan : path.join(ROOT, OPTS.plan));
  if (pr.status === 'ok') planText = pr.text;
  else say('  note: --plan ' + OPTS.plan + ' is ' + pr.status);
}
const pinInfo = discoverPins();
const blocks = planText ? planBlocks(planText) : [];
const willMove = [];
for (const b of blocks) {
  for (const pn of pinInfo.pins) {
    if (pn.target !== b.path) continue;
    if (b.a >= pn.targetLine) continue;
    willMove.push('WILL-MOVE  ' + pn.file + ':' + pn.atLine + " pins '" + pn.literal + "' at " + pn.target + ':' + pn.targetLine
      + ', below the block ' + b.token + ':' + b.a + '-' + b.b + ' this plan moves');
  }
}
counts['WILL-MOVE'] = willMove.length;
for (const w of willMove) say(w);

const obMisses = checkObligations(subjectFiles(planText));
for (const o of obMisses) say(o);

say('');
say('pins: ' + pinInfo.pins.length + ' under ' + CONTROL_ROOTS.join(', ')
  + (CONTROL_ROOTS_DECLARED ? ' (declared)' : '; declare anchorCheck.controlRoots to widen')
  + (pinInfo.dropped > 0 ? '; ' + pinInfo.dropped + ' literal(s) dropped because the path did not resolve' : ''));
say('obligations: ' + (OBLIGATIONS.length === 0 ? 'none declared' : OBLIGATIONS.length + ' declared, ' + obMisses.length + ' missed'));
say('anchors: ' + reported.length + ' checked, ' + counts.OK + ' OK, ' + counts.MOVED + ' MOVED, ' + counts.MISMATCH + ' MISMATCH, ' + counts.MISSING + ' MISSING, ' + counts.UNVERIFIABLE + ' UNVERIFIABLE, ' + counts.AMBIGUOUS + ' AMBIGUOUS, ' + counts['WILL-MOVE'] + ' WILL-MOVE');
flush();

const clean = (reported.length === 0 || counts.OK === reported.length) && willMove.length === 0 && obMisses.length === 0;
if (OPTS.strict && !clean) process.exit(1);
process.exit(0);
