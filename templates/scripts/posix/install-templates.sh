#!/bin/sh
# phaneslight-template v3.8.0 install-templates
# Mechanizes CHECKLIST items 1-9 and 11 for the POSIX platform: fetches the manifest's posix
# script set plus the every-platform files (cli.js, prompt templates) into a staging directory,
# sanity-checks every stamp THERE, and only then installs (scripts flat into
# .phaneslight/scripts/, prompts to their installPath), sets the executable bit on every
# installed script (CHECKLIST item 5, the one step of this run that exists on POSIX and has no
# Windows counterpart), merges the settings fragment preserving existing hooks ONLY when the
# manifest still declares one (v3.7.0: the plugin registers the enforcement hooks itself, so it
# does not, and the merge is skipped), verifies the merge, smoke-runs the cli chain, writes the
# config templates block, and records provenance by invoking the just-installed manifest-write.
# Stage-then-commit: every fetch or stamp failure aborts BEFORE anything touches the project,
# and every failure path sweeps the staging directory. Preserve rules: a manifest entry with
# customized:true, and any prompt template whose on-disk sha no longer matches its manifest
# record, are never overwritten. NOT advisory: exit 0 success, exit 1 failure with the failed
# item named (the session then falls back to spec-generation exactly as CHECKLIST item 3
# prescribes). Optional: --source <baseUrlOrDir> overrides the pinned raw URL (testing,
# mirrors, air-gapped installs).
#
# --source is the LITERAL double-dash flag, parsed out of the argument list by hand. There is
# no -Source synonym on either platform: the Windows sibling has no param() block either, and a
# run that silently accepted -Source would resolve its library from the pinned URL instead of
# the caller's directory and say nothing about it.
#
# POSIX divergences from the Windows sibling, each deliberate and each named in section A5 of
# the v3.7.2 POSIX-parity plan:
#
#   1. The executable bit. Windows has no such bit; here every installed script is chmod 0755
#      as it lands, which is CHECKLIST item 5.
#   2. Path identity. NTFS path identity is case-insensitive, so the .ps1 keys its provenance
#      table OrdinalIgnoreCase and matches the preserved list back the same way (its C3
#      repair). POSIX path identity is case-sensitive, so the table here is a plain Map and the
#      match-back is a plain string compare. Both halves still agree with each other, which is
#      what C3 was actually about.
#   3. The URL fetch. Invoke-WebRequest has no synchronous Node equivalent, and this program is
#      synchronous end to end, so a fetch from a base URL runs in a short child node process
#      bounded by the same 30 seconds. The directory source is the normal path, because the
#      plugin ships the template library beside itself, and it touches no network at all.
#   4. The smoke run's child output. Start-Process -NoNewWindow lets the cli chain write
#      straight through to this script's stdout; runChild captures it instead, so it is written
#      back out at the point the child produced it and the two transcripts stay in step.
#   5. The 27th file. The manifest gives the Windows dispatcher two files (phaneslight.ps1 and
#      phaneslight.cmd) and the POSIX dispatcher one, so a Windows install reports 27 files and
#      a POSIX install 26. The counts are not meant to match and forcing them to would mean
#      installing a file the platform cannot run.
#
# THE SHELL PART OF THIS FILE ENDS AT THE MARKER LINE. Everything after "# BEGIN NODE PROGRAM"
# is JavaScript, never parsed by the shell: on this machine's dash a here-document body of 4096
# bytes or more is delivered to its reader as ZERO bytes, silently, with no error from dash and
# none from node, and this program is far past that size. Reading the program out of the
# script's own tail with sed has no such limit and needs no temp file, so that is what happens
# below instead of the plan's original quoted-heredoc shape. `exec` cannot be used on a
# pipeline, so `exit $?` on the next line is what passes node's exit code out unchanged.
here=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd); export PHANESLIGHT_HERE="$here"
# Resolved through $here rather than used as given, so the program is read from the file that
# is running even when $0 arrived as a bare name through a PATH lookup.
self="$here/$(basename -- "$0")"
command -v node >/dev/null 2>&1 || { echo "install-templates: node is required on PATH and was not found" >&2; exit 1; }
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

// --- constants ------------------------------------------------------------------------
// N5: an explicit bound on each smoke-run child process. The Windows sibling gets it from
// WaitForExit(ms); here it is runChild's spawnSync timeout, with killSignal SIGKILL so a child
// that ignores a polite signal still cannot outlive the bound.
const SMOKE_TIMEOUT_MS = 60000;
// The URL fetch bound, the POSIX equivalent of Invoke-WebRequest -TimeoutSec 30.
const FETCH_TIMEOUT_MS = 30000;

function osMsg(e) { return (e && e.message) ? e.message : String(e); }

// PowerShell interpolates $null inside "$(...)" as the EMPTY STRING, not as the word null.
// Every fixed-shape message below goes through this so its bytes match the sibling's.
function psInterp(v) { return (v === null || v === undefined) ? '' : String(v); }

// PowerShell's @($x) is an empty array on an absent member and a one-element array on a
// scalar. Every manifest member below is read through this, so a damaged manifest produces a
// refusal rather than a throw.
function arr(x) {
  if (Array.isArray(x)) return x;
  if (x === null || x === undefined) return [];
  return [x];
}

// [System.IO.Path]::GetFileName, which on Windows treats BOTH separators as separators. The
// manifest writes its relative paths with '/', so this gives the same answer on both platforms;
// path.basename does not, because on POSIX it would keep a backslash as an ordinary character.
function fileName(p) {
  const s = String(p);
  let i = -1;
  for (let k = 0; k < s.length; k++) { if (s.charAt(k) === '/' || s.charAt(k) === '\\') i = k; }
  return s.slice(i + 1);
}

function toSlash(p) { return String(p).split('\\').join('/'); }

// Recursive remove, guarded for a Node older than 14.14 where fs.rmSync does not exist. Every
// caller wraps this: a failing cleanup must never replace the real message with its own.
function removeTree(p) {
  if (typeof fs.rmSync === 'function') { fs.rmSync(p, { recursive: true, force: true }); return; }
  fs.rmdirSync(p, { recursive: true });
}

// (v4.0.0-beta, 2026-09-03, ported) EVERY FAILURE PATH SWEEPS THE STAGING DIRECTORY, and until
// that fix none of them did. `staging` is created before the fetch below and removed only on
// the happy path immediately before exit 0, so every failure between the two left a full copy
// of the fetched template tree behind in the temp directory: measured on one machine as 46
// leftover directories, 28,479,057 bytes. The guard on `staging` is load-bearing, not
// defensive: most argument and precondition failures are raised BEFORE the variable is set,
// where it reads null and the sweep is correctly skipped.
let staging = null;
function fail(msg) {
  process.stderr.write('install-templates: FAILED: ' + msg + '\n');
  if (staging) { try { removeTree(staging); } catch (e) { /* keep the real message */ } }
  process.exit(1);
}

// --- arguments
// The LITERAL double-dash flag and nothing else, mirroring the .ps1's manual $args loop. There
// is no param() block there and no -Source synonym here: a run that quietly accepted -Source
// would resolve its library from the pinned URL while the caller believed it had pointed the
// run at a directory, and would say nothing about the substitution.
const argvIn = process.argv.slice(2);
let source = null;
for (let i = 0; i < argvIn.length; i++) {
  if (argvIn[i] === '--source') {
    if (i + 1 >= argvIn.length) fail('usage: --source requires a value (base URL or directory)');
    source = String(argvIn[i + 1]); i++;
  } else {
    fail("unknown argument '" + argvIn[i] + "'");
  }
}

// --- own version from this file's stamp (the CHECKLIST item 3 comparison substrate)
// $PSCommandPath has no equivalent under `node -`: process.argv[1] is the literal "-", so the
// running file is resolved through PHANESLIGHT_HERE, which the sh wrapper exported from the
// directory of the file it read this program out of. The name is fixed by the manifest entry
// (scripts/posix/install-templates.sh, installed flat), so it is not guessed here.
let ownVersion = null;
try {
  const raw = fs.readFileSync(path.join(HERE, 'install-templates.sh'), 'utf8');
  const clean = raw.charCodeAt(0) === 0xfeff ? raw.slice(1) : raw;
  const head = clean.split(/\r\n|\n|\r/).slice(0, 2).join('\n');
  const m = /phaneslight-template v(\d+\.\d+\.\d+)/.exec(head);
  if (m) ownVersion = m[1];
} catch (e) { /* ownVersion stays null and the refusal below fires */ }
if (ownVersion === null) fail('cannot read own version stamp');

// Source resolution, in order. A caller may pass --source with a directory or a base URL, which
// is what the acceptance harness and any offline install use. Otherwise the library is fetched
// from the tag matching this script's own stamp. That URL points at the MANUAL repository,
// Aloim/phaneslight, whose library carries the settings fragment this script merges; the plugin's
// library at Aloim/phaneslightplugin carries no fragment and would leave the hooks unregistered.
if (source === null) source = 'https://raw.githubusercontent.com/Aloim/phaneslight/v' + ownVersion + '/templates';
let sourceIsDir = false;
try { sourceIsDir = fs.statSync(source).isDirectory(); } catch (e) { sourceIsDir = false; }

const root = findRoot();
if (!root) fail('.phaneslight/config.json not found from this directory (CHECKLIST item 6: config is written before the first script runs)');
const cfgPath = path.join(root, '.phaneslight', 'config.json');
// readJsonFile rather than a bare parse, because the .ps1's catch here never fires on the four
// shapes that PARSE cleanly without being an object (literal null, bare array, bare string,
// and on this side an empty file). All four are 'malformed' below and produce the same refusal
// the .ps1 produces for a syntax error, which is the answer the message already claims.
const cfgRead = readJsonFile(cfgPath);
if (cfgRead.status !== 'ok') fail('.phaneslight/config.json is malformed; repair it before installing (item 6)');
const cfg = cfgRead.value;

// Existing provenance (preserve substrate). Absent = fresh install, no records. Malformed =
// refuse: without readable records the customized-file preserve rule cannot be honored, and
// overwriting blind is exactly the destroy reflex this library forbids.
const manifestPath = path.join(root, '.phaneslight', 'manifest.json');
// C3 repair, applied to this platform's path rule. On NTFS the two halves of the preserve rule
// disagreed about case: preservation was DECIDED case-insensitively and flagged back
// case-sensitively, so a file preserved through a case-differing record was never flagged,
// manifest-write then blessed its current sha as canonical, and THE NEXT RUN OVERWROTE IT while
// this run printed that it had preserved it. POSIX path identity is case-sensitive, so both
// halves here are plain ordinal compares. What C3 requires is that the two halves AGREE, and
// on this platform they do.
const recordByPath = new Map();
if (fs.existsSync(manifestPath)) {
  let prov;
  let parsed = true;
  try { prov = JSON.parse(fs.readFileSync(manifestPath, 'utf8')); } catch (e) { parsed = false; }
  if (!parsed) fail('.phaneslight/manifest.json exists but cannot be parsed; the customized-file preserve rule cannot be honored, nothing installed. Repair or deliberately delete it first');
  for (const a of arr(prov && prov.artifacts)) {
    if (a && typeof a.path === 'string') recordByPath.set(toSlash(a.path), a);
  }
}

// --- staging fetch (nothing below touches the project until every file passed its check)
// The .ps1 forces TLS 1.2 onto ServicePointManager at this point because .NET Framework's
// default is older than the servers it fetches from. Node negotiates TLS itself and has no such
// default to repair, so that line has no counterpart here.
staging = path.join(os.tmpdir(), 'phaneslight-install-' + crypto.randomBytes(16).toString('hex'));
try { fs.mkdirSync(staging, { recursive: true }); } catch (e) { fail('cannot create the staging directory ' + staging + ' (' + osMsg(e) + ')'); }

// The URL half of Fetch-One. Invoke-WebRequest has no synchronous Node equivalent and this
// program is synchronous end to end, so the download runs in a child node process: builtins
// only, no dependency, and the same 30 second bound the .ps1 passes as -TimeoutSec. A non-200
// status, a redirect loop, a socket error and a timeout are all a non-zero exit, which is the
// single false this function reports, exactly as the .ps1's catch reports one.
function httpFetch(url, dest) {
  const prog = [
    "var http=require('http'),https=require('https'),fs=require('fs');",
    "var out=process.argv[1],target=process.argv[2],left=5;",
    "function go(u){",
    "  var mod=(new URL(u).protocol==='https:')?https:http;",
    "  var req=mod.get(u,function(res){",
    "    if(res.statusCode>=300&&res.statusCode<400&&res.headers.location){",
    "      res.resume(); if(--left<0){process.exit(1);}",
    "      return go(new URL(res.headers.location,u).href);",
    "    }",
    "    if(res.statusCode!==200){res.resume();process.exit(1);return;}",
    "    var ws=fs.createWriteStream(out);",
    "    ws.on('error',function(){process.exit(1);});",
    "    ws.on('finish',function(){process.exit(0);});",
    "    res.on('error',function(){process.exit(1);});",
    "    res.pipe(ws);",
    "  });",
    "  req.on('error',function(){process.exit(1);});",
    "  req.setTimeout(" + FETCH_TIMEOUT_MS + ",function(){req.destroy();process.exit(1);});",
    "}",
    "go(target);"
  ].join('\n');
  // The outer bound is the inner one plus a margin, so the child's own timeout is what normally
  // fires and its exit code is what this reads. runChild's SIGKILL is the backstop.
  const r = runChild(process.execPath, ['-e', prog, dest, url], { timeoutMs: FETCH_TIMEOUT_MS + 5000 });
  return r.available && r.code === 0;
}

function fetchOne(rel) {
  const dest = path.join(staging, rel);
  // C2, the staging half: `rel` is also manifest-sourced, so a traversing rel escapes the
  // staging directory exactly as a traversing installPath escaped the project. Refusing here
  // means a hostile or damaged manifest cannot write anywhere on the way in either.
  if (path.isAbsolute(String(rel)) || !contained(staging, dest)) {
    process.stderr.write("install-templates: manifest path '" + psInterp(rel) + "' escapes the staging directory; refusing\n");
    return false;
  }
  try { fs.mkdirSync(path.dirname(dest), { recursive: true }); } catch (e) { return false; }
  if (sourceIsDir) {
    const src = path.join(source, rel);
    if (!fs.existsSync(src)) return false;
    try { fs.copyFileSync(src, dest); } catch (e) { return false; }
    return true;
  }
  return httpFetch(String(source).replace(/\/+$/, '') + '/' + rel, dest);
}

if (!fetchOne('MANIFEST.json')) fail('cannot fetch MANIFEST.json from ' + source);
let man = null;
let manParsed = true;
try { man = JSON.parse(fs.readFileSync(path.join(staging, 'MANIFEST.json'), 'utf8')); } catch (e) { manParsed = false; }
if (!manParsed) fail('fetched MANIFEST.json does not parse (a 404 body or HTML error page must never be installed)');
// Read through a guard rather than off `man` directly: a fetched MANIFEST.json that parses to
// the literal null is not an object, and the .ps1 reaches this comparison with $null and
// refuses with an empty version in the message rather than throwing. This is that.
const manVersion = (man !== null && typeof man === 'object') ? man.version : null;
if (typeof manVersion !== 'string' || manVersion !== ownVersion) {
  fail("manifest version '" + psInterp(manVersion) + "' does not match this script's stamp version '" + ownVersion + "' (item 3); fall back to spec-generation");
}

// item 1: platform detected; only the posix variant set plus every-platform files fetched.
const plan = [];   // entries: rel, name, kind(script|prompt), installPath
for (const s of arr(man.scripts)) {
  const files = arr(s && s.posix).filter(function (x) { return typeof x === 'string'; });
  if (files.length === 0) { process.stdout.write('SKIPPED (no posix variant): ' + psInterp(s && s.name) + '\n'); continue; }
  for (const rel of files) {
    plan.push({ rel: rel, name: psInterp(s && s.name), kind: 'script', installPath: '.phaneslight/scripts/' + fileName(rel) });
  }
}
for (const p of arr(man.promptTemplates)) {
  plan.push({ rel: psInterp(p && p.file), name: psInterp(p && p.name), kind: 'prompt', installPath: toSlash(psInterp(p && p.installPath)) });
}
let fragRel = null;
if (man.settingsFragments && typeof man.settingsFragments.posix === 'string') fragRel = man.settingsFragments.posix;
// The manual line still merges fragments (it registers no enforcement hooks of its own), so an
// absent fragment here is a failure, matching the windows sibling's contract at
// install-templates.ps1. The merge blocks below stay guarded on fragRel rather than
// unconditional, since fragRel is always set past this point once the run has not already
// failed.
if (fragRel === null) fail('manifest carries no posix settings fragment');

for (const e of plan) { if (!fetchOne(e.rel)) fail('cannot fetch ' + psInterp(e.rel) + ' from ' + source + '; nothing installed'); }
if (fragRel && !fetchOne(fragRel)) fail('cannot fetch ' + fragRel + ' from ' + source + '; nothing installed');

// item 2: stamp sanity per staged file, BEFORE any install. The fragment is pure JSON (it
// cannot carry a comment stamp); its sanity check is a parse plus a hooks key.
for (const e of plan) {
  const staged = path.join(staging, e.rel);
  let head = [];
  try {
    const raw = fs.readFileSync(staged, 'utf8');
    const clean = raw.charCodeAt(0) === 0xfeff ? raw.slice(1) : raw;
    head = clean.split(/\r\n|\n|\r/).slice(0, 2);
  } catch (err) { head = []; }
  const want = 'phaneslight-template v' + ownVersion + ' ' + e.name;
  let ok = false;
  for (const ln of head) { if (String(ln).indexOf(want) >= 0) { ok = true; break; } }
  if (!ok) fail('stamp check failed for ' + psInterp(e.rel) + " (expected '" + want + "' within the first two lines); nothing installed");
}
let frag = null;
if (fragRel) {
  let fragBad = false;
  try {
    frag = JSON.parse(fs.readFileSync(path.join(staging, fragRel), 'utf8'));
    if (!frag || typeof frag !== 'object' || !frag.hooks) fragBad = true;
  } catch (e) { fragBad = true; }
  if (fragBad) fail('fetched settings fragment ' + fragRel + ' is not a hooks JSON; nothing installed');
}

// --- install (item 4: flat into .phaneslight/scripts/, extension kept; prompts to installPath).
// C2 repair, and the severity comes from where the string originates. `installPath` is taken
// verbatim from the FETCHED manifest, and the default source is a remote raw URL, so this is a
// path traversal whose payload is REMOTE CONTENT. "installPath": "../ESCAPED-OUTSIDE-ROOT.md"
// wrote above the project root and the run printed install-templates: OK and exited 0. An
// absolute installPath was caught only by accident of a Join-Path artifact, with a message that
// explained nothing. This repeats the class SS00025's W1.3 item b already fixed once.
//
// The gate runs in the PRE-COPY verification pass, so a rejected plan lands in state (A),
// untouched, rather than part-installed. The staging destination is validated on the same
// principle in fetchOne: a traversing `rel` must not escape the staging directory either.
for (const e of plan) {
  if (path.isAbsolute(e.installPath)) {
    fail("manifest installPath '" + e.installPath + "' is absolute; installPath must be relative to the project root. Nothing installed");
  }
  if (!contained(root, path.join(root, e.installPath))) {
    fail("manifest installPath '" + e.installPath + "' resolves outside the project root; nothing installed");
  }
}

// Only now, with every installPath validated, is the project touched at all. This ordering is
// load-bearing for the state (A) guarantee: the directory creation below used to run BEFORE the
// gate, so a refused hostile manifest still left .phaneslight/scripts/ behind. An empty
// directory is not damage, but "untouched" has to mean untouched or the contract is only
// approximately true, and approximately-true contracts are what this review kept finding.
try { fs.mkdirSync(path.join(root, '.phaneslight', 'scripts'), { recursive: true }); } catch (e) { fail('cannot create .phaneslight/scripts (' + osMsg(e) + ')'); }
const installed = [];
const preserved = [];
const staleCustomizations = [];   // W3.4
for (const e of plan) {
  const target = path.join(root, e.installPath);
  const targetDir = path.dirname(target);
  const stagedPath = path.join(staging, e.rel);
  if (fs.existsSync(target)) {
    const rec = recordByPath.has(e.installPath) ? recordByPath.get(e.installPath) : null;
    if (rec !== null && rec !== undefined) {
      let keep = (typeof rec.customized === 'boolean' && rec.customized);
      if (!keep && e.kind === 'prompt' && typeof rec.sha256 === 'string') {
        let disk;
        try { disk = sha256Hex(fs.readFileSync(target)); } catch (err) { disk = ''; }
        // Get-FileHash returns upper case and the .ps1 compares OrdinalIgnoreCase; crypto
        // returns lower case. Both sides are lowered so the comparison asks the same question.
        if (disk.toLowerCase() !== rec.sha256.toLowerCase()) keep = true;
      }
      if (keep) {
        preserved.push(e.installPath);
        process.stdout.write('PRESERVED (user-customized): ' + e.installPath + '\n');
        // W3.4: this is the ONE place in the system that can honestly answer "has the template
        // moved on since you customized this", because it is holding the staged replacement
        // template right now. update-preflight runs offline and must never claim it. The
        // preserve rule is NOT changed by any of this: the file is preserved either way, and
        // the user is simply told their reason to customize may have expired. An entry written
        // before v3.4 carries no templateSha256 at all, and it stays UNKNOWN: nothing is
        // printed for it, because a guessed baseline would be a false all-clear.
        let stagedSha = null;
        try { stagedSha = sha256Hex(fs.readFileSync(stagedPath)).toLowerCase(); } catch (err) { stagedSha = null; }
        let recTpl = null;
        if (typeof rec.templateSha256 === 'string') recTpl = rec.templateSha256.toLowerCase();
        if (stagedSha !== null && recTpl !== null) {
          if (stagedSha !== recTpl) {
            const shortRec = recTpl.slice(0, Math.min(8, recTpl.length));
            const shortNew = stagedSha.slice(0, Math.min(8, stagedSha.length));
            process.stdout.write('CUSTOMIZATION STALE: ' + e.installPath + ' (customized from template ' + shortRec + ', template is now ' + shortNew + '; your edit is preserved, review whether it is still needed)\n');
            staleCustomizations.push(e.installPath);
          }
        }
        continue;
      }
    }
  }
  try {
    fs.mkdirSync(targetDir, { recursive: true });
    fs.copyFileSync(stagedPath, target);
  } catch (err) {
    fail('copy failed for ' + e.installPath + ' (' + osMsg(err) + '); installed so far: ' + installed.join(', '));
  }
  // CHECKLIST item 5, and the one step in this file that exists on POSIX and has no Windows
  // counterpart: an installed script that is not executable is an install that looks complete
  // and cannot be run. It is a hard failure rather than a warning for that reason, and it names
  // what was already installed exactly as the copy failure above does. Prompt templates are
  // data and are deliberately left alone.
  if (e.kind === 'script') {
    try { fs.chmodSync(target, 0o755); } catch (err) {
      fail('cannot set the executable bit on ' + e.installPath + ' (' + osMsg(err) + '); installed so far: ' + installed.join(', '));
    }
  }
  installed.push(e.installPath);
}
process.stdout.write('installed: ' + installed.length + ' files, preserved: ' + preserved.length + '\n');

if (fragRel) {
// --- item 8: merge the settings fragment into .claude/settings.json, preserving existing
// --- hooks; a malformed existing settings file is a refusal, never a clobber.
const settingsPath = path.join(root, '.claude', 'settings.json');
let settings = null;
if (fs.existsSync(settingsPath)) {
  let sOk = true;
  try { settings = JSON.parse(fs.readFileSync(settingsPath, 'utf8')); } catch (e) { sOk = false; }
  if (!sOk || settings === null || typeof settings !== 'object' || Array.isArray(settings)) {
    fail('.claude/settings.json exists but cannot be parsed; merge refused so user settings are never clobbered. Repair it, then re-run');
  }
} else {
  try { fs.mkdirSync(path.join(root, '.claude'), { recursive: true }); } catch (e) { fail('cannot create .claude (' + osMsg(e) + ')'); }
  settings = {};
}
if (!settings.hooks) settings.hooks = {};
let mergedNew = 0; let mergedKept = 0;
for (const ev of Object.keys(frag.hooks)) {
  if (!settings.hooks[ev]) settings.hooks[ev] = [];
  const existingCmds = [];
  for (const grp of arr(settings.hooks[ev])) { for (const h of arr(grp && grp.hooks)) { if (h && typeof h.command === 'string') existingCmds.push(h.command); } }
  for (const grp of arr(frag.hooks[ev])) {
    const newCmds = [];
    for (const h of arr(grp && grp.hooks)) { if (h && typeof h.command === 'string') newCmds.push(h.command); }
    let allPresent = true;
    for (const c of newCmds) { if (existingCmds.indexOf(c) < 0) { allPresent = false; break; } }
    if (allPresent && newCmds.length > 0) { mergedKept++; continue; }
    settings.hooks[ev] = arr(settings.hooks[ev]).concat([grp]);
    mergedNew++;
  }
}
try { fs.writeFileSync(settingsPath, toNodeJson(settings, 0) + '\n', 'utf8'); } catch (e) { fail('cannot write .claude/settings.json (' + osMsg(e) + ')'); }
process.stdout.write('settings: merged ' + mergedNew + ' hook group(s), ' + mergedKept + ' already present\n');

// Read-back verification (the Step 4b path-discipline check, mechanical): every PhanesLight
// hook command must contain .phaneslight/scripts/ and carry no drive letter and no leading
// slash.
//
// N1 repair. A PRE-EXISTING legacy hook carrying an absolute path (the form PhanesLight
// installed before the path-discipline rule existed) made this check fail on a condition THIS
// RUN DID NOT CREATE AND COULD NOT CLEAR. Result: exit 1, state (B), and every subsequent run
// repeating it identically, with a hand-edit of settings.json the only escape, which is
// precisely the manual step mechanization exists to remove.
//
// So a legacy PhanesLight hook is REPAIRED rather than refused. Two fences keep this from
// becoming a destroy reflex. First, only commands already identified as PhanesLight hooks (they
// contain .phaneslight/scripts/) are touched; a non-PhanesLight hook is never rewritten,
// whatever it looks like. Second, if the rewrite does not produce a compliant command, the run
// still fails with the original message rather than writing something it cannot vouch for.
//
// The drive-letter test is kept on POSIX, where a drive letter cannot appear in a native path,
// because settings.json is a portable file: a project shared from a Windows machine carries
// Windows hook commands, and refusing to see them here would leave them unrepaired.
const verifyRead = readJsonFile(settingsPath);
if (verifyRead.status !== 'ok') fail('.claude/settings.json is ' + verifyRead.status + ' after the merge (' + psInterp(verifyRead.reason) + ')');
const verify = verifyRead.value;
const repairedHooks = [];
const verifyHooks = (verify.hooks && typeof verify.hooks === 'object') ? verify.hooks : {};
for (const ev of Object.keys(verifyHooks)) {
  for (const grp of arr(verifyHooks[ev])) {
    for (const h of arr(grp && grp.hooks)) {
      if (!h || typeof h.command !== 'string') continue;
      const c = h.command;
      const idx = c.indexOf('.phaneslight/scripts/');
      if (idx < 0) continue;   // not a PhanesLight hook
      const bad = /[A-Za-z]:[\\/]/.test(c) || /(^|\s)\//.test(c);
      if (!bad) continue;
      // Rewrite everything up to and including the drive-letter or leading-slash prefix so the
      // command starts at .phaneslight/scripts/, keeping the invocation words before it intact.
      // The .ps1 writes this as one alternation with a lookbehind; the same alternation is split
      // into two end-anchored passes here so the port needs no variable-length lookbehind, and
      // the results agree because both alternatives are anchored to the end of the head.
      const tail = c.slice(idx);
      let head = c.slice(0, idx);
      head = head.replace(/[A-Za-z]:[\\/]\S*$/, '');
      head = head.replace(/(^|\s)\/\S*$/, '$1');
      const fixed = head + tail;
      if (/[A-Za-z]:[\\/]/.test(fixed) || /(^|\s)\//.test(fixed)) {
        fail('hook command carries a non-relative path that could not be repaired (path discipline): ' + c);
      }
      h.command = fixed;
      repairedHooks.push(c);
    }
  }
}
if (repairedHooks.length > 0) {
  try {
    fs.writeFileSync(settingsPath, toNodeJson(verify, 0) + '\n', 'utf8');
  } catch (e) {
    fail('could not write the repaired hook path(s) back to .claude/settings.json (' + osMsg(e) + ')');
  }
  process.stdout.write('settings: repaired ' + repairedHooks.length + ' legacy absolute-path hook command(s) to the relative form\n');
  for (const rc of repairedHooks) process.stdout.write('  was: ' + rc + '\n');
}
process.stdout.write('settings: read-back verification passed (relative .phaneslight/scripts/ commands only)\n');
}

// --- item 7: smoke run through the cross-shell entry.
//
// The child's own stdout and stderr are written back out here because the Windows sibling's
// Start-Process -NoNewWindow hands the child this process's console handles: the cli chain's
// lines land in that script's transcript, in this exact position, so they land in the same
// place here. runChild pipes them instead of inheriting, which is what makes writing them back
// the faithful choice rather than an addition.
//
// The verdict is the EXIT CODE and never the presence of stderr text: a tool that chatters on
// stderr and exits 0 succeeded, which is the shared B5 rule, and it is also why the .ps1
// refuses to redirect the child's native stderr at all.
let smokeFail = null;
function invokeSmoke(sub) {
  const r = runChild('node', ['.phaneslight/scripts/cli.js', sub], { cwd: root, timeoutMs: SMOKE_TIMEOUT_MS });
  if (r.stdout) process.stdout.write(r.stdout);
  if (r.stderr) process.stderr.write(r.stderr);
  if (!r.available) {
    // spawnSync reports the timeout as an ETIMEDOUT error and a signal death as a null status,
    // and runChild folds both into available:false. They are DIFFERENT ANSWERS: one is this
    // script's own bound firing, the other is node failing to launch at all, and naming the
    // second as the first would report the wrong cause of a failed install.
    const why = psInterp(r.reason);
    if (why.indexOf('ETIMEDOUT') >= 0 || why.indexOf('terminated by signal') === 0) {
      return 'cli.js ' + sub + ' did not finish within ' + Math.floor(SMOKE_TIMEOUT_MS / 1000) + 's and was terminated';
    }
    return 'node unavailable (' + why + ')';
  }
  if (r.code !== 0) return 'cli.js ' + sub + ' exited ' + r.code;
  return null;
}
smokeFail = invokeSmoke('module-list');
if (smokeFail === null) smokeFail = invokeSmoke('register-check');
if (smokeFail !== null) fail('smoke run failed: ' + smokeFail + ' (scripts are on disk but unverified; no provenance recorded)');
process.stdout.write('smoke: module-list OK, register-check OK\n');

// --- item 11 provenance: sha256 recording via the just-installed manifest-write (one hashing
// --- implementation, not two).
//
// ORDER CORRECTED 2026-08-05. This block used to run AFTER the config templates block below,
// which quietly falsified the state (B) contract: templates: {...} in config is exactly the
// marker a later run reads as "this project has a completed install", so all three
// provenance-failure paths (manifest-write missing, manifest-write nonzero, flag-back failure)
// left that marker on disk with NO manifest beside it. The contract was repaired by moving the
// code to match it, not by weakening the wording to match the code.
const mwPath = path.join(root, '.phaneslight', 'scripts', 'manifest-write.sh');
if (!fs.existsSync(mwPath)) fail('manifest-write.sh is not in the installed set; provenance not recorded');
const mwRun = runChild('sh', [mwPath], {});
// manifest-write's stderr is passed straight through: the .ps1 calls it with & inside the same
// session, where its stderr reaches this script's stderr and nothing swallows it.
if (mwRun.stderr) process.stderr.write(mwRun.stderr);
// The verdict is the exit code, never the presence of stderr text. An unlaunchable
// manifest-write and a manifest-write that ran and refused are DIFFERENT ANSWERS and both are
// named, because "provenance not recorded" without the cause is barely a report.
if (!mwRun.available) fail('manifest-write could not be launched (' + psInterp(mwRun.reason) + '); provenance not recorded');
if (mwRun.code !== 0) fail('manifest-write exited ' + mwRun.code + '; provenance not recorded');
// $mwOut in the .ps1 is the captured output with its trailing newline gone, and PowerShell joins
// a multi-line capture with a single space when it interpolates it. This is that.
const mwLines = String(mwRun.stdout).split(/\r?\n/);
while (mwLines.length > 0 && mwLines[mwLines.length - 1] === '') mwLines.pop();
process.stdout.write('provenance: ' + mwLines.join(' ') + '\n');

// A file this run PRESERVED is durably customized: flag it, or the freshly blessed sha would
// make the next install overwrite it (the preserve signal must not be consumed by recording).
if (preserved.length > 0) {
  try {
    const prov2 = JSON.parse(fs.readFileSync(manifestPath, 'utf8'));
    for (const a of arr(prov2 && prov2.artifacts)) {
      if (!a || typeof a !== 'object') continue;
      // C3: matched the same way preservation was decided above, which on POSIX is an ordinal
      // compare on both halves.
      const ap = (typeof a.path === 'string') ? toSlash(a.path) : null;
      let isPreserved = false;
      if (ap !== null) {
        for (const pp of preserved) { if (pp === ap) { isPreserved = true; break; } }
      }
      if (isPreserved) a.customized = true;
      // W3.4: record the template this run WOULD have installed as the fingerprint the user is
      // customized away from, but only when the manifest does not already carry one. Overwriting
      // an existing value would silently re-baseline the customization to the current template
      // and permanently erase the staleness this field exists to detect: the entry would read
      // fresh forever, which is the false all-clear W3.4 was created to prevent.
      if (isPreserved && typeof a.templateSha256 !== 'string') {
        for (const pe of plan) {
          if (pe.installPath === ap) {
            try {
              a.templateSha256 = sha256Hex(fs.readFileSync(path.join(staging, pe.rel))).toLowerCase();
            } catch (err) { /* an unreadable staged file leaves the field unknown, never guessed */ }
            break;
          }
        }
      }
    }
    fs.writeFileSync(manifestPath, toNodeJson(prov2, 0) + '\n', 'utf8');
  } catch (e) {
    fail('could not flag preserved files as customized in .phaneslight/manifest.json (' + osMsg(e) + ')');
  }
  process.stdout.write('provenance: marked customized: ' + preserved.join(', ') + '\n');
}
if (staleCustomizations.length > 0) {
  process.stdout.write('customizations possibly stale: ' + staleCustomizations.length + ' (listed above; the preserve rule is unchanged and every edit was kept)\n');
}

// --- item 9: config templates block. LAST, after provenance succeeded (see the ordering note
// --- above): this block is the marker a later run reads as a completed install, so it must not
// --- exist on disk unless the install actually completed.
//
// templates.source keeps the literal value "fetched" even when the source was a local directory
// that touched no network. update-preflight reads that exact string back, so changing the word
// to describe the local case more accurately would introduce a real script-versus-spec mismatch
// in order to fix a cosmetic one.
cfg.templates = { version: ownVersion, source: 'fetched' };
try { fs.writeFileSync(cfgPath, toNodeJson(cfg, 0) + '\n', 'utf8'); } catch (e) { fail('cannot write config templates block (' + osMsg(e) + ')'); }
process.stdout.write('config: templates block written {version: ' + ownVersion + ', source: fetched}\n');

try { removeTree(staging); } catch (e) { /* a failing sweep must not fail a completed install */ }
process.stdout.write('install-templates: OK\n');
process.exit(0);
