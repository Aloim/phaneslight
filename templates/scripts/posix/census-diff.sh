#!/bin/sh
# phaneslight-template v3.8.0 census-diff
# Re-enumerates the disk-visible capability surfaces (MCP servers via `claude mcp list`,
# plugins, skills, commands) and diffs them against capabilities.selection[] recorded in
# .phaneslight/config.json, mechanizing the update-run "diff, don't re-ask" duty. Prints a digest
# JSON: added (detected, not in selection), removed (in selection, no longer detected),
# changed (an MCP server whose connected state differs from the recorded authOk). The ASKING
# about deltas stays in the session. A failed `claude mcp list` degrades that one surface
# (mcpAvailable: false) and never reports its selection entries as removed: an empty result
# from a FAILED call is not an authoritative empty set. Advisory: always exits 0.
here=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd); export PHANESLIGHT_HERE="$here"
# Resolved through $here rather than used as given, so the program is read from the file that
# is running even when $0 arrived as a bare name through a PATH lookup.
self="$here/$(basename -- "$0")"
command -v node >/dev/null 2>&1 || {
  # Node missing is not "no answer": this script is advisory and always exits 0, and a JSON
  # emitter on an advisory path must still print its whole structure (plan A4). Without node
  # there is no way to find the root, read the config or call `claude mcp list`, so the report
  # printed here is byte-identical to the no-root report the Node program itself would print:
  # every field at its initial value, nothing detected, nothing diffed.
  echo "census-diff: node is required on PATH and was not found; emitting the default report" >&2
  printf '%s\n' \
'{' \
'  "selectionPresent": false,' \
'  "configUntrusted": false,' \
'  "mcpAvailable": false,' \
'  "addedCount": 0,' \
'  "added": [],' \
'  "removedCount": 0,' \
'  "removed": [],' \
'  "changedCount": 0,' \
'  "changed": [],' \
'  "ignoredSelectionEntries": 0,' \
'  "surfacesUnreadable": false,' \
'  "listTruncated": false' \
'}'
  exit 0
}
# The program is read out of this file's own tail by sed and piped to node, never fed through a
# heredoc: on this machine's dash, a heredoc body of 4096 bytes or more is delivered as ZERO
# BYTES, silently, and this program is far larger than that. See lib/posix/wrapper-template.sh
# for the measurement. The pipeline's exit status is node's; exec cannot be used on a pipeline,
# so `exit $?` on the next line is what passes it out unchanged.
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

// censusListCap (MANIFEST.json constant), hardcoded exactly as the Windows sibling hardcodes
// $CAP = 100 at census-diff.ps1:11: the report never lists more than this many entries per
// bucket, and listTruncated says so when the true count ran past it.
const CAP = 100;

const report = {
  selectionPresent: false,
  configUntrusted: false,
  mcpAvailable: false,
  addedCount: 0, added: [],
  removedCount: 0, removed: [],
  changedCount: 0, changed: [],
  ignoredSelectionEntries: 0,
  surfacesUnreadable: false,
  listTruncated: false
};
function writeReportAndExit() {
  emitJson(report);
  process.exit(0);
}

const root = findRoot();
if (!root) {
  process.stderr.write('census-diff: .phaneslight/config.json not found from this directory\n');
  writeReportAndExit();
}

// PowerShell truthiness for the config guard below, replicated exactly rather than approximated
// with a plain JS truthy check. PowerShell's boolean coercion of a collection is COUNT based:
// an empty array is false, a one-element array unwraps to the truthiness of that element, and a
// larger array is unconditionally true. A plain `if (cfg.capabilities.selection)` in JS would
// read an empty array as true, which flips selectionPresent for a project whose selection was
// explicitly recorded empty: the exact fabricated-truth shape this codebase bans.
function psTruthy(v) {
  if (v === null || v === undefined) return false;
  if (Array.isArray(v)) {
    if (v.length === 0) return false;
    if (v.length === 1) return psTruthy(v[0]);
    return true;
  }
  if (typeof v === 'boolean') return v;
  if (typeof v === 'number') return v !== 0;
  if (typeof v === 'string') return v !== '';
  return true; // a JSON object, present, is always truthy
}

// Selection from config, guarded. A malformed config degrades to "no diff computed", clearly
// flagged; it never reads as "everything was removed". findRoot() only returns a directory
// where .phaneslight/config.json exists, so the only failures reachable here are a read error
// or a parse error, both funneled to the same configUntrusted branch the Windows sibling uses:
// this script does not distinguish 'absent' from 'malformed' for its own config the way
// readJsonFile does for other sensors, because the Windows source does not either.
let selection = [];
try {
  const raw = fs.readFileSync(path.join(root, '.phaneslight', 'config.json'), 'utf8');
  const cfg = JSON.parse(raw);
  if (cfg && psTruthy(cfg.capabilities) && psTruthy(cfg.capabilities.selection)) {
    const sel = cfg.capabilities.selection;
    selection = Array.isArray(sel) ? sel.slice() : [sel];
    report.selectionPresent = true;
  }
} catch (e) {
  report.configUntrusted = true;
  process.stderr.write('census-diff: .phaneslight/config.json is malformed; no diff computed, nothing reported as removed\n');
  writeReportAndExit();
}

// --- detected surfaces. Each is (type, name); names are compared ordinal case-sensitively,
// --- exactly as recorded (a rename shows as removed + added, which the session can judge).
// detected and mcpConnected carry user-supplied keys (server, plugin, skill and command names),
// so both are Maps: a plain object would fold a case-only rename onto one slot only by luck and
// would sort an integer-like name to the front regardless of insertion order, exactly the two
// defects the Windows sibling's own comment records as measured, not hypothetical.
const detected = new Map();      // key "type\0name" -> true
const mcpConnected = new Map();  // mcp name -> connected state

const mcpRes = runChild('claude', ['mcp', 'list'], {});
let mcpRaw = null;
if (mcpRes.available && mcpRes.code === 0) {
  mcpRaw = mcpRes.stdout;
}
if (mcpRaw !== null) {
  report.mcpAvailable = true;
  // `& claude mcp list` in PowerShell captures one array element per output line, with no
  // spurious trailing empty element for the newline the last line ends with. Splitting and
  // popping exactly one trailing empty string reproduces that, without discarding a real blank
  // line that appears in the middle of the output.
  const lines = mcpRaw.replace(/\r\n/g, '\n').split('\n');
  if (lines.length > 0 && lines[lines.length - 1] === '') lines.pop();
  for (const ln of lines) {
    const i = ln.indexOf(': ');
    if (i <= 0) continue;
    const name = ln.substring(0, i);
    detected.set('mcp\0' + name, true);
    // Health mark: the line tail carries "- <mark> <status>"; U+2714 (heavy check mark) = connected.
    mcpConnected.set(name, ln.indexOf('✔') >= 0);
  }
} else {
  process.stderr.write('census-diff: `claude mcp list` unavailable or failed; MCP surface skipped, its selection entries are NOT reported as removed\n');
}

const userHome = homeDir();
let userClaude = null;
if (userHome) userClaude = path.join(userHome, '.claude');

// An unreadable directory is recorded here, and its recorded selection entries are skipped in
// the removed pass exactly as the MCP surface already is above: the whole point of the
// mcpAvailable guard is that a failed enumeration must never read as "everything was removed",
// and this is the same protection for the directory surfaces.
const unreadableTypes = new Map();
function addDirNames(dir, type, ext, dirs) {
  if (!dir) return;
  let st;
  try {
    st = fs.statSync(dir);
  } catch (e) {
    return; // absent: nothing there is not an error
  }
  if (!st.isDirectory()) return; // a file where a directory belongs: no entries, not an error
  let items;
  try {
    items = fs.readdirSync(dir, { withFileTypes: true });
  } catch (e) {
    unreadableTypes.set(type, true);
    process.stderr.write('census-diff: cannot enumerate ' + dir + '; ' + type + ' entries are NOT reported as removed\n');
    return;
  }
  for (const it of items) {
    if (dirs) {
      if (!it.isDirectory()) continue;
      detected.set(type + '\0' + it.name, true);
    } else {
      if (!it.isFile()) continue;
      if (ext && it.name.slice(-ext.length).toLowerCase() !== ext.toLowerCase()) continue;
      const n = it.name.slice(0, it.name.length - path.extname(it.name).length);
      detected.set(type + '\0' + n, true);
    }
  }
}
addDirNames(path.join(root, '.claude', 'commands'), 'command', '.md', false);
if (userClaude) { addDirNames(path.join(userClaude, 'commands'), 'command', '.md', false); } else { unreadableTypes.set('command', true); }
addDirNames(path.join(root, '.claude', 'skills'), 'skill', null, true);
if (userClaude) { addDirNames(path.join(userClaude, 'skills'), 'skill', null, true); } else { unreadableTypes.set('skill', true); }

let pluginsJson = null;
if (userClaude) { pluginsJson = path.join(userClaude, 'plugins', 'installed_plugins.json'); } else { unreadableTypes.set('plugin', true); }
if (pluginsJson) {
  let exists = false;
  try { exists = fs.existsSync(pluginsJson); } catch (e) { exists = false; }
  if (exists) {
    // Silent on a malformed installed_plugins.json, exactly as the Windows sibling's empty
    // catch is: this surface neither flags surfacesUnreadable nor writes to stderr on a parse
    // failure, only on the userClaude-absent case above. Ported as found, not tightened.
    try {
      const raw = fs.readFileSync(pluginsJson, 'utf8');
      const pj = JSON.parse(raw);
      if (pj && typeof pj.plugins === 'object' && pj.plugins !== null && !Array.isArray(pj.plugins)) {
        for (const name of Object.keys(pj.plugins)) {
          const val = pj.plugins[name];
          const insts = Array.isArray(val) ? val : [val];
          for (const inst of insts) {
            if (!inst || typeof inst !== 'object') continue;
            const scopeOk = inst.scope === 'user' ||
              (inst.scope === 'project' && typeof inst.projectPath === 'string' && inst.projectPath === root);
            if (scopeOk) {
              const n = String(name).split('@')[0];
              detected.set('plugin\0' + n, true);
              break;
            }
          }
        }
      }
    } catch (e) { /* malformed installed_plugins.json: silently no plugins detected */ }
  }
}

// --- diff against the recorded selection
const inSelection = new Map();
const added = [];
const removed = [];
const changed = [];
const diffTypes = ['mcp', 'plugin', 'skill', 'command'];
for (const e of selection) {
  if (!e || typeof e.name !== 'string' || typeof e.type !== 'string') { report.ignoredSelectionEntries++; continue; }
  if (diffTypes.indexOf(e.type) === -1) { report.ignoredSelectionEntries++; continue; }
  if (e.type === 'mcp' && !report.mcpAvailable) { inSelection.set(e.type + '\0' + e.name, true); continue; }
  // The consuming half of the unreadable-surface repair: a surface that could not be
  // enumerated cannot testify that anything on it is gone. Recording the key still suppresses
  // a false "added" for the same entry, exactly as the mcpAvailable branch above does.
  if (unreadableTypes.has(e.type)) { inSelection.set(e.type + '\0' + e.name, true); report.surfacesUnreadable = true; continue; }
  const key = e.type + '\0' + e.name;
  inSelection.set(key, true);
  if (!detected.has(key)) {
    removed.push({ name: e.name, type: e.type });
  } else if (e.type === 'mcp' && typeof e.authOk === 'boolean' && mcpConnected.has(e.name) && mcpConnected.get(e.name) !== e.authOk) {
    changed.push({ name: e.name, type: 'mcp', field: 'authOk', recorded: e.authOk, current: mcpConnected.get(e.name) });
  }
}
const detKeys = Array.from(detected.keys()).sort();
for (const key of detKeys) {
  if (!inSelection.has(key)) {
    const parts = key.split('\0');
    added.push({ name: parts[1], type: parts[0] });
  }
}

report.addedCount = added.length;
report.removedCount = removed.length;
report.changedCount = changed.length;
report.added = added.slice(0, CAP);
report.removed = removed.slice(0, CAP);
report.changed = changed.slice(0, CAP);
report.listTruncated = (added.length > CAP || removed.length > CAP || changed.length > CAP);
writeReportAndExit();
