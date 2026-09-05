#!/bin/sh
# phaneslight-template v3.8.1 repo-manifest
# Generates the deterministic raw file list (.phaneslight/inventory/raw-files.txt, from
# git ls-files, docRoot/.phaneslight/.claude trees and binary extensions excluded) and diffs
# it against the Claude-maintained annotated summary list (annotated-files.json, shape
# {path: {summary, hash}}). Staleness is content-hash based: the hash is the index blob
# sha that git ls-files -s already returns. Pruning is keyed to GENUINE absence from the
# full unfiltered tracked set, never to the filters, so a misread docRoot can never
# destroy hand-written summaries. Advisory: always exits 0.
#
# THIS FILE IS TWO LANGUAGES. Shell down to and including "# BEGIN NODE PROGRAM" below,
# JavaScript after it. The shell exits before it would ever reach the JavaScript, so it is
# never parsed as shell; `dash -n` on the whole file is expected to fail on the JS half for
# exactly that reason, and is checked in two pieces (see guard 9 in the distribution's publish/publish.sh). The
# program is read out of this file's own tail with sed rather than a heredoc: on this
# machine's dash, a heredoc body of 4096 bytes or more is delivered to its reader as ZERO
# bytes, silently, no error from dash or from the reader (measured by bisection: 4095
# arrives whole, 4096 arrives empty). This program is far larger than that, so the plan's
# original `exec node - "$@" <<'JS'` shape made this script print nothing and exit 0, an
# advisory sensor's silent all-clear. sed has no such limit and copies bytes verbatim, so
# the shell never even sees the JavaScript, which is stricter literality than a quoted
# heredoc ever gave.
here=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd); export PHANESLIGHT_HERE="$here"
# Resolved through $here rather than used as given, so the program is read from the file
# that is actually running even when $0 arrived as a bare name through a PATH lookup.
self="$here/$(basename -- "$0")"
command -v node >/dev/null 2>&1 || {
  echo "repo-manifest: node is required on PATH and was not found" >&2
  # Without node this run can neither call git nor reconcile annotated-files.json, so it
  # cannot even tell whether the project sits inside a git repository. It reports the same
  # gitUnavailable: true shape the real run reports when git itself is unavailable, with a
  # reason field distinguishing the two causes. Counts and lists become null, never 0 or
  # [], because the tree was never scanned: reporting zero would claim a clean sweep that
  # never happened, the exact absent/unreadable collapse this codebase refuses to make.
  printf '%s\n' '{
  "totalTracked": null,
  "newCount": null,
  "new": null,
  "changedCount": null,
  "changed": null,
  "staleCount": null,
  "stale": null,
  "listTruncated": false,
  "annotatedMalformed": false,
  "configUntrusted": false,
  "gitUnavailable": true,
  "migrated": false,
  "reason": "node unavailable"
}'
  exit 0
}
sed '1,/^# BEGIN NODE PROGRAM$/d' "$self" | node - "$@"
exit $?
# BEGIN NODE PROGRAM
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

// repoManifestListCap (MANIFEST.json constants block), hardcoded here the same way the
// Windows sibling hardcodes $CAP: templates/MANIFEST.json is fetched into staging and never
// installed into .phaneslight/, so an installed script cannot read it at runtime.
const CAP = 100;

// Ordinal string compare: JS's default < and > on strings compare UTF-16 code units, which is
// exactly what .NET's [System.StringComparer]::Ordinal compares (.NET strings are UTF-16 too),
// so this matches the Windows sibling's sort order byte for byte on every path this script
// handles.
function ordinal(a, b) {
  if (a < b) return -1;
  if (a > b) return 1;
  return 0;
}

const root = findRoot();
if (!root) {
  process.stderr.write('repo-manifest: .phaneslight/config.json not found from this directory\n');
  process.exit(0);
}

const invDir = path.join(root, '.phaneslight', 'inventory');
const rawFile = path.join(invDir, 'raw-files.txt');
const annotatedFile = path.join(invDir, 'annotated-files.json');

const report = {
  totalTracked: 0,
  newCount: 0, new: [],
  changedCount: 0, changed: [],
  staleCount: 0, stale: [],
  listTruncated: false,
  annotatedMalformed: false,
  configUntrusted: false,
  gitUnavailable: false,
  migrated: false
};
function writeReportAndExit() {
  emitJson(report);
  process.exit(0);
}

// Config verdict: degrade, never destroy, identically on both platforms. A config that
// cannot be read or parsed does NOT stop the run and does NOT silently default either:
// the run continues on the default filters, the report carries configUntrusted: true,
// and every destructive or mutating write to annotated-files.json is suppressed, so a
// misread config can produce a confusing report but never a loss.
let docRoot = 'documentation';
let configUntrusted = false;
let cfg = null;
const cfgRes = readJsonFile(path.join(root, '.phaneslight', 'config.json'));
if (cfgRes.status === 'ok') {
  cfg = cfgRes.value;
} else {
  configUntrusted = true;
}
if (configUntrusted) {
  process.stderr.write('repo-manifest: .phaneslight/config.json is malformed or unreadable; running on default filters, pruning and annotation writes suppressed so no summary can be lost to a misread config\n');
}
if (!configUntrusted && typeof cfg.docRoot === 'string' && cfg.docRoot !== '') {
  docRoot = cfg.docRoot;
}
report.configUntrusted = configUntrusted;
docRoot = docRoot.replace(/\/+$/, '');
if (docRoot === '') docRoot = 'documentation';

// Native git: an unreachable or failing git degrades to "inventory left untouched" outside
// a repository. Nothing is written on this path: an empty tracked set from a FAILED git call
// must never be allowed to prune summaries.
const gitRes = runChild('git', ['ls-files', '-s', '-z'], { cwd: root });
let lsRaw = null;
if (gitRes.available && gitRes.code === 0) {
  lsRaw = gitRes.stdout;
}
if (lsRaw === null) {
  process.stderr.write('repo-manifest: not a git repository (or git unavailable), inventory left untouched\n');
  report.gitUnavailable = true;
  writeReportAndExit();
}

// Parse `git ls-files -s -z` records: "<mode> <sha> <stage>\t<path>". Two sets are kept
// deliberately: the FULL tracked set (prune substrate: only genuine absence from git counts
// as deleted) and the filtered inventory set (what agents browse). Excluded by a filter is
// not the same as deleted.
const binRe = /\.(png|jpg|jpeg|gif|ico|woff2?|ttf|eot|pdf|zip|exe|dll|so|dylib)$/;
const docPrefix = docRoot + '/';
const hashByPath = new Map();
const rawPaths = [];
const records = lsRaw.split('\0');
for (const e of records) {
  if (e === '') continue;
  const tab = e.indexOf('\t');
  if (tab < 0) continue;
  const meta = e.slice(0, tab).split(' ');
  if (meta.length < 3) continue;
  const p = e.slice(tab + 1);
  hashByPath.set(p, meta[1]);
  if (p.indexOf(docPrefix) === 0 || p.indexOf('.phaneslight/') === 0 || p.indexOf('.claude/') === 0) continue;
  if (binRe.test(p)) continue;
  rawPaths.push(p);
}
rawPaths.sort(ordinal);
report.totalTracked = rawPaths.length;

fs.mkdirSync(invDir, { recursive: true });
if (!fs.existsSync(annotatedFile)) {
  fs.writeFileSync(annotatedFile, '{}\n', 'utf8');
}

// A malformed annotated file is a degrade, never a reset: the one-line summaries are
// hand-maintained and unrecoverable from git, so report it and leave it untouched.
const annRes = readJsonFile(annotatedFile);
let annotatedObj = null;
let annotatedMalformed = false;
if (annRes.status === 'ok') {
  annotatedObj = annRes.value;
} else {
  annotatedMalformed = true;
  process.stderr.write('repo-manifest: .phaneslight/inventory/annotated-files.json is malformed, left untouched; the raw list was still regenerated\n');
}
report.annotatedMalformed = annotatedMalformed;

if (rawPaths.length > 0) {
  fs.writeFileSync(rawFile, rawPaths.join('\n') + '\n', 'utf8');
} else {
  fs.writeFileSync(rawFile, '', 'utf8');
}

if (!annotatedMalformed) {
  // Flat {path: "summary"} entries migrate to {summary, hash: null}; a null hash means
  // "stamp me this run". Own properties only: a tracked file named constructor or toString
  // is classified by lookup, never by inherited members (Object.keys yields own keys only,
  // and bracket access on an own key never reaches the prototype chain).
  const normalized = new Map();
  const normKeys = [];
  let migrated = false;
  for (const k of Object.keys(annotatedObj)) {
    const v = annotatedObj[k];
    if (typeof v === 'string') {
      normalized.set(k, { summary: v, hash: null });
      migrated = true;
    } else if (v !== null && typeof v === 'object' && !Array.isArray(v)) {
      let s = '';
      let h = null;
      if (typeof v.summary === 'string') s = v.summary;
      if (typeof v.hash === 'string') h = v.hash;
      normalized.set(k, { summary: s, hash: h });
    } else {
      normalized.set(k, { summary: '', hash: null });
    }
    normKeys.push(k);
  }
  report.migrated = migrated;

  const fresh = [];
  for (const p of rawPaths) {
    if (!normalized.has(p)) fresh.push(p);
  }
  const stale = [];
  const changed = [];
  for (const k of normKeys) {
    if (!hashByPath.has(k)) { stale.push(k); continue; }
    const rec = normalized.get(k);
    const cur = hashByPath.get(k);
    // A null hash is the "just written or just refreshed" marker: stamp it with the
    // current index blob sha. A present hash that no longer matches is the changed
    // signal, deliberately NOT overwritten here: it stays until an agent refreshes the
    // summary and nulls the hash, otherwise the signal would vanish unseen.
    if (rec.hash === null) {
      rec.hash = cur;
    } else if (rec.hash !== cur) {
      changed.push(k);
    }
  }
  const staleArr = stale.slice().sort(ordinal);
  const changedArr = changed.slice().sort(ordinal);
  const freshArr = fresh; // already in rawPaths' sorted order; never re-sorted on Windows either

  if (!configUntrusted) {
    const keep = [];
    for (const k of normKeys) {
      if (hashByPath.has(k)) keep.push(k);
    }
    keep.sort(ordinal);
    const out = new Map();
    for (const k of keep) {
      const rec = normalized.get(k);
      out.set(k, { summary: rec.summary, hash: rec.hash });
    }
    fs.writeFileSync(annotatedFile, toNodeJson(out, 0) + '\n', 'utf8');
  }

  report.newCount = freshArr.length;
  report.new = freshArr.length > CAP ? freshArr.slice(0, CAP) : freshArr;
  report.changedCount = changedArr.length;
  report.changed = changedArr.length > CAP ? changedArr.slice(0, CAP) : changedArr;
  report.staleCount = staleArr.length;
  report.stale = staleArr.length > CAP ? staleArr.slice(0, CAP) : staleArr;
  report.listTruncated = (freshArr.length > CAP || changedArr.length > CAP || staleArr.length > CAP);
}
writeReportAndExit();
