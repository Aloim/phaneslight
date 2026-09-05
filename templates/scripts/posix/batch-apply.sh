#!/bin/sh
# phaneslight-template v3.8.1 batch-apply
# Applies a batch of {file, old, new} exact-match edits and prints a per-edit review diff
# computed against saved pre-images. Git is NOT a dependency: the undo substrate is a
# byte-for-byte pre-image of every file touched, saved before the first write, so this
# works on untracked files, gitignored files, dirty trees, and outside any repository.
# Modes: default applies per-edit (failures do not discard the other edits); --atomic is
# all-or-nothing; --reject <indices> restores pre-images and re-applies the surviving
# edits of the SAME batch (the writing agent's self-check rejection path;
# the printed diff is also what <projectSlug>-closure reconciles against intent).
# Exit codes: 0 every requested edit applied; 1 usage error (nothing touched);
# 2 --reject refused (nothing touched); 3 nothing applied (all edits failed, or a write
# failure was reverted from pre-images); 4 partial (some applied, some failed).
#
# THE SHELL PART OF THIS FILE ENDS AT THE "# BEGIN NODE PROGRAM" MARKER. Everything after it
# is JavaScript, piped to node by the sed line below, never parsed by the shell. Check the two
# halves with two checkers: dash -n on the prefix, node --check on the suffix.
#
# Where this port deliberately parts company with the Windows sibling, and why:
#   Path identity is ORDINAL and case-sensitive. The Windows script lowercases both sides of
#   every path comparison because NTFS is case-insensitive; on POSIX src/A.js and src/a.js
#   are two files, and folding them together would let one edit splice into the other.
#   The pre-image store is os.tmpdir()/phaneslight-batch/<key> with the key hashed from the
#   UNLOWERCASED root path, for the same reason: lowercasing would give two genuinely
#   different projects one shared undo substrate.
#   A symbolic link is detected with lstat and never stat, because stat follows the link and
#   reports the destination, which is exactly the fact the check exists to expose.
#   Files are read and written as Buffers throughout, never as decoded strings, so a CRLF
#   file keeps its CRLF and a UTF-8 BOM survives byte for byte.
here=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd); export PHANESLIGHT_HERE="$here"
# Resolved through $here rather than used as given, so the program is read from the file that
# is running even when $0 arrived as a bare name through a PATH lookup.
self="$here/$(basename -- "$0")"
# batch-apply writes to the project. Without node it cannot read a file, cannot compute the
# sha256 the undo substrate is built on, and cannot honour the 0/1/2/3/4 exit contract its
# callers branch on. It therefore names the cause, touches nothing, and exits 1, the code that
# already means "nothing was touched". It never prints a report, because a report here would
# claim a batch was evaluated when no file was ever opened.
command -v node >/dev/null 2>&1 || { echo "batch-apply: node is required on PATH and was not found" >&2; exit 1; }
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

// The review-diff cap, hardcoded exactly as the Windows sibling hardcodes it at
// batch-apply.ps1:14. It is the batchApplyDiffCap constant; both sides carry the literal so
// neither has to read MANIFEST.json to print a diff.
const DIFF_CAP = 20000;

// stdout and stderr go through fs.writeSync, never process.stdout.write, because this program
// calls process.exit with a load-bearing code on every path and Node does not flush a pending
// asynchronous stream write on exit. A pipe is asynchronous on Linux and macOS, so the report
// would be truncated at exactly the moment the exit code claims it succeeded.
function writeFd(fd, s) {
  const b = Buffer.from(s, 'utf8');
  let off = 0;
  while (off < b.length) {
    let n = 0;
    try {
      n = fs.writeSync(fd, b, off, b.length - off);
    } catch (e) {
      if (e && (e.code === 'EAGAIN' || e.code === 'EINTR')) continue;
      return;
    }
    off += n;
  }
}
function out(s) { writeFd(1, s); }
function errLine(s) { writeFd(2, s + '\n'); }

function showUsage(msg) {
  let line = 'USAGE: batch-apply <edit-batch.json> [--atomic] [--reject <indices>]';
  if (msg) line = line + ' -- ' + msg;
  errLine(line);
  process.exit(1);
}

function denyReject(msg) {
  errLine('REJECT_REFUSED: ' + msg + '; nothing was changed on disk');
  process.exit(2);
}

function errMsg(e) { return e && e.message ? e.message : String(e); }

// Ordinal, case-sensitive string order, the POSIX shape of StringComparer.Ordinal. JS compares
// UTF-16 code units with < and >, which is what Ordinal compares.
function ordinalCompare(a, b) { if (a < b) return -1; if (a > b) return 1; return 0; }

function decodeUtf8(bytes) {
  const bom = bytes.length >= 3 && bytes[0] === 0xEF && bytes[1] === 0xBB && bytes[2] === 0xBF;
  let text;
  if (bom) text = bytes.toString('utf8', 3);
  else if (bytes.length === 0) text = '';
  else text = bytes.toString('utf8');
  return { text: text, bom: bom };
}

function encodeUtf8(text, bom) {
  const body = Buffer.from(text, 'utf8');
  if (bom) return Buffer.concat([Buffer.from([0xEF, 0xBB, 0xBF]), body]);
  return body;
}

function crlfToLf(s) { return s.split('\r\n').join('\n'); }
function lfToCrlf(s) { return s.split('\n').join('\r\n'); }

// Ordinal, non-overlapping occurrence count via indexOf: never a regular expression built from
// an escaped needle, which collapses on multi-megabyte needles (the 400-second M5 cliff).
function countOccurrences(hay, needle) {
  let n = 0;
  let i = 0;
  for (;;) {
    i = hay.indexOf(needle, i);
    if (i < 0) break;
    n++;
    i += needle.length;
  }
  return n;
}

function dominantEol(text) {
  const crlf = countOccurrences(text, '\r\n');
  const lone = countOccurrences(text, '\n') - crlf;
  if (crlf > lone) return '\r\n';
  return '\n';
}

// Match contract: old is normalized to LF, then tried against the buffer both as-is and
// expanded to CRLF (the buffer as earlier edits in this batch left it). Exactly one
// occurrence across the tried forms is required. The replacement takes the convention of
// the matched region; a single-line old takes the buffer-dominant convention for any
// newlines inside new. The splice touches only the matched span, so an edit can never
// change the line-ending convention of text it did not match.
function findMatch(text, oldRaw) {
  const oldLf = crlfToLf(oldRaw);
  const forms = [oldLf];
  if (oldLf.indexOf('\n') >= 0) forms.push(lfToCrlf(oldLf));
  let total = 0;
  let index = -1;
  let matched = null;
  for (const f of forms) {
    const n = countOccurrences(text, f);
    total += n;
    if (n > 0 && matched === null) { index = text.indexOf(f); matched = f; }
  }
  return { total: total, index: index, matched: matched, oldLf: oldLf };
}

function splitEditLines(s) {
  let parts = s.split(/\r\n|\n/);
  if (parts.length > 1 && parts[parts.length - 1] === '') parts = parts.slice(0, parts.length - 1);
  return parts;
}

const root = findRoot();
if (!root) {
  errLine('batch-apply: .phaneslight/config.json not found from this directory');
  process.exit(1);
}

const argv = process.argv.slice(2);
let batchArg = null;
let atomic = false;
let rejectArg = null;
for (let i = 0; i < argv.length; i++) {
  const a = String(argv[i]);
  if (a === '--atomic') { atomic = true; }
  else if (a === '--reject') {
    i++;
    if (i >= argv.length) showUsage('--reject needs a comma-separated index list');
    rejectArg = String(argv[i]);
  } else if (a.length > 1 && a.slice(0, 2) === '--') { showUsage('unknown option ' + a); }
  else if (batchArg === null) { batchArg = a; }
  else { showUsage('unexpected extra argument ' + a); }
}
if (batchArg === null) showUsage(null);
if (atomic && rejectArg !== null) showUsage('--atomic and --reject cannot be combined; a reject re-apply is always all-or-nothing');

let batchFile = batchArg;
if (!path.isAbsolute(batchFile)) batchFile = path.join(process.cwd(), batchFile);
try { batchFile = path.resolve(batchFile); } catch (e) { showUsage('cannot resolve ' + batchArg); }
let batchBytes = null;
try { batchBytes = fs.readFileSync(batchFile); } catch (e) { showUsage('cannot read ' + batchFile + ' (' + errMsg(e) + ')'); }
const bd = decodeUtf8(batchBytes);
let batch = null;
try { batch = JSON.parse(bd.text); } catch (e) { showUsage('could not parse ' + batchFile + ' as JSON: ' + errMsg(e)); }
if (!batch || !Array.isArray(batch.edits)) showUsage('batch must be a JSON object carrying an "edits" array');
const edits = batch.edits;
// An empty batch is bad input, not a failed batch and not a success: nothing was
// attempted, so exit 3 (failed) and exit 0 (applied) would both lie to the caller.
if (edits.length === 0) showUsage('edit batch is empty, nothing to apply');

const rootReal = path.resolve(root);
let rootTrimmed = rootReal;
while (rootTrimmed.length > 0 && rootTrimmed.charAt(rootTrimmed.length - 1) === path.sep) {
  rootTrimmed = rootTrimmed.slice(0, rootTrimmed.length - 1);
}
const rootPrefix = rootTrimmed + path.sep;
// ORDINAL and case-sensitive, deliberately unlike the Windows sibling, which lowercases both
// sides of every path comparison because NTFS is case-insensitive. POSIX paths are
// case-sensitive, so src/A.js and src/a.js are two files and folding them together would let
// one edit silently splice into the other. The same reasoning decides the pre-image key
// below: the Windows key hashes the LOWERCASED root, and hashing a lowercased root here
// would give two genuinely different projects one shared pre-image store.
const cmpPrefix = rootPrefix;
const rootKey = sha256Hex(Buffer.from(rootReal, 'utf8')).slice(0, 16);
const stateDir = path.join(os.tmpdir(), 'phaneslight-batch', rootKey);
const preDir = path.join(stateDir, 'pre');
const stateFile = path.join(stateDir, 'state.json');
const batchSha = sha256Hex(batchBytes);

// Keyed by resolved absolute path, so a Map and never a plain object: a project file named
// 123 would otherwise reorder itself to the front of any dictionary built from these keys.
const buffers = new Map();
const bufferOrder = [];
const dirChecked = new Map();

// The POSIX shape of Test-ReparseAncestor in the Windows sibling: a lexically contained path
// can still resolve outside the project when a directory between it and the root is a
// symbolic link. lstat, never stat, because stat follows the link and reports the
// destination, which is exactly the fact being hidden. The dirname equality break is not in
// the Windows loop and is required here: path.dirname of a filesystem root returns the root
// itself rather than null, so the length test alone would spin forever on a malformed root.
function hasSymlinkAncestor(resolved) {
  let d = path.dirname(resolved);
  while (d && d.length > rootReal.length) {
    if (dirChecked.has(d)) {
      if (dirChecked.get(d)) return true;
    } else {
      let isLink = false;
      try { if (fs.lstatSync(d).isSymbolicLink()) isLink = true; } catch (e) { /* an unreadable rung is not a link */ }
      dirChecked.set(d, isLink);
      if (isLink) return true;
    }
    const p = path.dirname(d);
    if (!p || p === d) break;
    d = p;
  }
  return false;
}

function getEditBuffer(fileField) {
  if (typeof fileField !== 'string' || fileField === '') return { err: '"file" must be a non-empty string path' };
  if (path.isAbsolute(fileField)) return { err: '"file" must be relative to the project root, not absolute' };
  let resolved = null;
  try { resolved = path.resolve(rootReal, fileField); } catch (e) { return { err: 'cannot resolve path: ' + fileField }; }
  if (resolved.indexOf(cmpPrefix) !== 0) return { err: 'path escapes the project root: resolves to ' + resolved };
  const key = resolved;
  if (buffers.has(key)) return { buf: buffers.get(key) };
  let st = null;
  try { st = fs.lstatSync(resolved); } catch (e) { return { err: 'file not found: ' + fileField }; }
  if (st.isDirectory()) return { err: 'not a regular file: ' + fileField };
  if (st.isSymbolicLink()) return { err: 'refusing to edit through a symbolic link: ' + fileField };
  if (hasSymlinkAncestor(resolved)) return { err: 'resolved path escapes the project root (symlinked parent): ' + fileField };
  const bytes = fs.readFileSync(resolved);
  const d = decodeUtf8(bytes);
  // Exactness guard: if decode-then-reencode does not reproduce the original bytes, the
  // file is not UTF-8 text (UTF-16, binary, mixed encodings) and a splice through a lossy
  // decode would corrupt the regions this batch never touched. Refuse instead.
  const roundTrip = encodeUtf8(d.text, d.bom);
  if (sha256Hex(roundTrip) !== sha256Hex(bytes)) return { err: 'not UTF-8 text, refusing to edit: ' + fileField };
  const rel = resolved.slice(rootPrefix.length).split(path.sep).join('/');
  const buf = { key: key, resolved: resolved, rel: rel, origBytes: bytes, text: d.text, bom: d.bom, modified: false, postBytes: null };
  buffers.set(key, buf);
  bufferOrder.push(buf);
  return { buf: buf };
}

function invokeEdits(indices) {
  const results = [];
  let applied = 0;
  let failed = 0;
  for (const i of indices) {
    const e = edits[i];
    let fileLabel = '(invalid file field)';
    if (e && typeof e.file === 'string') fileLabel = e.file;
    let reason = null;
    const eOld = (e === null || e === undefined) ? undefined : e.old;
    const eNew = (e === null || e === undefined) ? undefined : e.new;
    if (typeof eOld !== 'string' || typeof eNew !== 'string') reason = '"old" and "new" must both be JSON strings';
    else if (eOld === '') reason = '"old" must not be empty';
    if (reason !== null) { results.push({ index: i, file: fileLabel, status: 'failed', reason: reason }); failed++; continue; }
    const l = getEditBuffer(e.file);
    if (l.err) { results.push({ index: i, file: fileLabel, status: 'failed', reason: l.err }); failed++; continue; }
    const buf = l.buf;
    const loc = findMatch(buf.text, eOld);
    if (loc.total === 0) reason = 'old not found in ' + buf.rel + ' (matched after CRLF/LF normalization; a span mixing both conventions cannot match)';
    else if (loc.total > 1) reason = 'old matches ' + loc.total + ' times in ' + buf.rel + ', must be unique in the file as earlier edits left it';
    else if (crlfToLf(eNew) === loc.oldLf) reason = '"new" is identical to "old", nothing to change';
    if (reason !== null) { results.push({ index: i, file: buf.rel, status: 'failed', reason: reason }); failed++; continue; }
    const newLf = crlfToLf(eNew);
    let eol;
    if (loc.matched.indexOf('\r\n') >= 0) eol = '\r\n';
    else if (loc.oldLf.indexOf('\n') >= 0) eol = '\n';
    else eol = dominantEol(buf.text);
    const newOut = eol === '\r\n' ? lfToCrlf(newLf) : newLf;
    const before = buf.text.slice(0, loc.index);
    const after = buf.text.slice(loc.index + loc.matched.length);
    const line = countOccurrences(before, '\n') + 1;
    const bl = before.split(/\r\n|\n/);
    const ctxBefore = [];
    for (let k = Math.max(0, bl.length - 3); k < bl.length - 1; k++) ctxBefore.push(bl[k]);
    const al = after.split(/\r\n|\n/);
    const ctxAfter = [];
    for (let k = 1; k < Math.min(3, al.length); k++) ctxAfter.push(al[k]);
    buf.text = before + newOut + after;
    buf.modified = true;
    results.push({ index: i, file: buf.rel, status: 'applied', line: line,
      oldLines: splitEditLines(loc.matched), newLines: splitEditLines(newOut),
      ctxBefore: ctxBefore, ctxAfter: ctxAfter });
    applied++;
  }
  return { results: results, applied: applied, failed: failed };
}

function formatReviewDiff(results) {
  const blocks = [];
  for (const r of results) {
    if (r.status !== 'applied') continue;
    const lines = [];
    lines.push('=== edit ' + r.index + ': ' + r.file + ' @ line ' + r.line + ' ===');
    for (const l of r.ctxBefore) lines.push('  ' + l);
    for (const l of r.oldLines) lines.push('- ' + l);
    for (const l of r.newLines) lines.push('+ ' + l);
    for (const l of r.ctxAfter) lines.push('  ' + l);
    blocks.push(lines.join('\n'));
  }
  const full = blocks.join('\n\n');
  if (full.length <= DIFF_CAP) return { text: full, truncated: false };
  const stat = [];
  for (const r of results) {
    if (r.status !== 'applied') continue;
    stat.push('edit ' + r.index + ': ' + r.file + ' @ line ' + r.line + ' (-' + r.oldLines.length + ' +' + r.newLines.length + ' lines)');
  }
  stat.push('(review diff omitted: ' + full.length + ' chars exceeds the ' + DIFF_CAP + '-char cap; pre-images are kept under ' + preDir + ', diff any file manually, e.g. git diff --no-index <pre-image> <file>)');
  return { text: stat.join('\n'), truncated: true };
}

function writeReportAndExit(mode, res, rejected, exitCode, wrote, restored) {
  let touched = [];
  if (wrote) {
    for (const b of bufferOrder) { if (b.modified) touched.push(b.rel); }
    touched.sort(ordinalCompare);
  }
  const appliedIdx = [];
  const failedArr = [];
  for (const r of res.results) {
    if (r.status === 'applied') appliedIdx.push(r.index);
    else failedArr.push({ index: r.index, file: r.file, reason: r.reason });
  }
  let diffText = '(nothing was written)';
  let truncated = false;
  if (wrote) { const d = formatReviewDiff(res.results); diffText = d.text; truncated = d.truncated; }
  let preDirOut = null;
  if (wrote) preDirOut = stateDir;
  const report = {
    mode: mode,
    appliedCount: res.applied,
    failedCount: res.failed,
    applied: appliedIdx,
    failed: failedArr,
    rejectedIndices: rejected,
    touchedFiles: touched,
    restoredFiles: restored,
    preImageDir: preDirOut,
    diffTruncated: truncated
  };
  out(toNodeJson(report, 0) + '\n');
  out('--- review diff (computed against pre-images, uncommitted) ---\n');
  out(diffText + '\n');
  process.exit(exitCode);
}

if (rejectArg === null) {
  const all = [];
  for (let i = 0; i < edits.length; i++) all.push(i);
  const res = invokeEdits(all);
  for (const r of res.results) { if (r.status === 'failed') errLine('EDIT-FAILED ' + r.index + ': ' + r.reason); }
  let mode = 'partial';
  if (atomic) mode = 'atomic';
  if (res.applied === 0) {
    errLine('BATCH_FAILED: no edit could be applied; nothing was written');
    writeReportAndExit(mode, res, [], 3, false, []);
  }
  if (atomic && res.failed > 0) {
    errLine('BATCH_FAILED: ' + res.failed + ' edit(s) failed under --atomic; nothing was written');
    writeReportAndExit(mode, res, [], 3, false, []);
  }
  // A new apply invalidates any previous state: wipe first, then save every pre-image and
  // the state record BEFORE the first target write, so a crash between writes always
  // leaves a complete undo substrate on disk (and a later --reject verifies post-hashes,
  // so a stale or crashed state can never silently revert anything).
  const mods = [];
  for (const b of bufferOrder) { if (b.modified) mods.push(b); }
  // Ordinal by rel. The Windows sibling sorts with Sort-Object, which is culture-aware; this
  // sort is ordinal, the same order touchedFiles is emitted in, so the pre-image numbering
  // and the reported order agree on every platform.
  mods.sort(function (x, y) { return ordinalCompare(x.rel, y.rel); });
  fs.rmSync(stateDir, { recursive: true, force: true });
  fs.mkdirSync(preDir, { recursive: true });
  const appliedIndices = [];
  for (const r of res.results) { if (r.status === 'applied') appliedIndices.push(r.index); }
  // A Map, not an object: the keys are project-relative paths and a file named 123 must keep
  // the position the sort gave it instead of jumping to the front of an integer-keyed object.
  const filesDict = new Map();
  let n = 0;
  for (const b of mods) {
    const preName = String(n) + '.bin';
    n++;
    fs.writeFileSync(path.join(preDir, preName), b.origBytes);
    b.postBytes = encodeUtf8(b.text, b.bom);
    filesDict.set(b.rel, { pre: preName, preSha256: sha256Hex(b.origBytes), postSha256: sha256Hex(b.postBytes) });
  }
  const state = {
    batchSha256: batchSha,
    root: rootReal,
    createdAt: new Date().toISOString(),
    appliedIndices: appliedIndices,
    rejectedIndices: [],
    files: filesDict
  };
  fs.writeFileSync(stateFile, Buffer.from(toNodeJson(state, 0), 'utf8'));
  const written = [];
  let writeFailed = null;
  try {
    for (const b of mods) { fs.writeFileSync(b.resolved, b.postBytes); written.push(b); }
    for (const b of mods) {
      const back = fs.readFileSync(b.resolved);
      if (sha256Hex(back) !== filesDict.get(b.rel).postSha256) throw new Error('post-write read-back mismatch on ' + b.rel);
    }
  } catch (e) { writeFailed = errMsg(e); }
  if (writeFailed !== null) {
    errLine('BATCH_FAILED: write phase: ' + writeFailed);
    let revertOk = true;
    for (const b of written) {
      try { fs.writeFileSync(b.resolved, b.origBytes); }
      catch (e) {
        revertOk = false;
        errLine('REVERT-FAILED: ' + b.rel + ': ' + errMsg(e) + ' (pre-image kept: ' + path.join(preDir, filesDict.get(b.rel).pre) + ')');
      }
    }
    if (revertOk) {
      errLine('Reverted ' + written.length + ' file(s) to their pre-batch bytes.');
      try { fs.rmSync(stateDir, { recursive: true, force: true }); } catch (e) { /* the substrate is advisory once the tree is clean */ }
    }
    writeReportAndExit(mode, res, [], 3, false, []);
  }
  if (res.failed > 0) {
    errLine('PARTIAL: ' + res.applied + ' applied, ' + res.failed + ' failed; applied edits are kept, failures are listed in the report');
    writeReportAndExit(mode, res, [], 4, true, []);
  }
  writeReportAndExit(mode, res, [], 0, true, []);
} else {
  const rejectSeen = new Map();
  const rejectList = [];
  for (const part of rejectArg.split(',')) {
    const t = part.trim();
    if (t === '') continue;
    let v = 0;
    let okInt = /^[+-]?[0-9]+$/.test(t);
    if (okInt) {
      v = Number(t);
      if (!Number.isSafeInteger(v) || v > 2147483647 || v < -2147483648) okInt = false;
    }
    if (!okInt || v < 0) showUsage('--reject indices must be non-negative integers, got ' + part);
    if (v >= edits.length) showUsage('--reject index ' + v + ' is out of range for a batch of ' + edits.length + ' edit(s)');
    if (!rejectSeen.has(v)) { rejectSeen.set(v, true); rejectList.push(v); }
  }
  if (rejectList.length === 0) showUsage('--reject needs at least one index');
  let state = null;
  try {
    const raw = fs.readFileSync(stateFile, 'utf8');
    state = JSON.parse(raw.charCodeAt(0) === 0xfeff ? raw.slice(1) : raw);
  } catch (e) { state = null; }
  if (!state || !state.files) denyReject('no saved pre-image state for this project (' + stateDir + '); --reject only follows a successful batch-apply of the same batch');
  if (state.batchSha256 !== batchSha) denyReject('the saved state belongs to a different batch file; re-run batch-apply with the original batch');
  // Every touched file must still be exactly as the last apply (or last reject) left it,
  // otherwise restoring pre-images would destroy interleaved later work. This is the
  // stale-state guard: a crashed or superseded state can never silently revert anything.
  const stFiles = Object.keys(state.files);
  stFiles.sort(ordinalCompare);
  for (const rel of stFiles) {
    const resolved = path.resolve(rootReal, rel);
    let cur = null;
    try { cur = fs.readFileSync(resolved); } catch (e) { denyReject(rel + ' is unreadable (' + errMsg(e) + ')'); }
    if (sha256Hex(cur) !== state.files[rel].postSha256) denyReject(rel + ' changed since the batch was applied');
  }
  for (const rel of stFiles) {
    const resolved = path.resolve(rootReal, rel);
    const key = resolved;
    const bytes = fs.readFileSync(path.join(preDir, state.files[rel].pre));
    const d = decodeUtf8(bytes);
    const buf = { key: key, resolved: resolved, rel: rel, origBytes: bytes, text: d.text, bom: d.bom, modified: false, postBytes: null };
    buffers.set(key, buf);
    bufferOrder.push(buf);
  }
  const survivors = [];
  const priorApplied = Array.isArray(state.appliedIndices) ? state.appliedIndices : [];
  for (const iv of priorApplied) { if (!rejectSeen.has(Number(iv))) survivors.push(Number(iv)); }
  const res = invokeEdits(survivors);
  if (res.failed > 0) {
    for (const r of res.results) { if (r.status === 'failed') errLine('EDIT-FAILED ' + r.index + ': ' + r.reason); }
    denyReject('a surviving edit no longer applies without the rejected one(s); author a fresh batch instead');
  }
  const restored = [];
  const newFiles = new Map();
  for (const rel of stFiles) {
    const resolved = path.resolve(rootReal, rel);
    const b = buffers.get(resolved);
    b.postBytes = encodeUtf8(b.text, b.bom);
    fs.writeFileSync(resolved, b.postBytes);
    newFiles.set(rel, { pre: state.files[rel].pre, preSha256: state.files[rel].preSha256, postSha256: sha256Hex(b.postBytes) });
    if (!b.modified) restored.push(rel);
  }
  const rejectedSorted = rejectList.slice();
  rejectedSorted.sort(function (a, b) { return a - b; });
  const newState = {
    batchSha256: state.batchSha256,
    root: state.root,
    createdAt: state.createdAt,
    appliedIndices: survivors,
    rejectedIndices: rejectedSorted,
    files: newFiles
  };
  fs.writeFileSync(stateFile, Buffer.from(toNodeJson(newState, 0), 'utf8'));
  writeReportAndExit('reject', res, rejectedSorted, 0, true, restored);
}
