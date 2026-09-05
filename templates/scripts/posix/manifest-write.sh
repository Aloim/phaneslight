#!/bin/sh
# phaneslight-template v3.8.0 manifest-write
# Recomputes sha256 provenance for every installed script (.phaneslight/scripts/) and prompt
# template (.claude/template/) and rewrites .phaneslight/manifest.json (schema: phaneslight.md
# Phase 5). Blessing the CURRENT disk state is this script's one job: drift detection against
# the recorded state belongs to update-preflight; deciding whether drift was legitimate belongs
# to the session. Entries of every other class (agents, workflows, commands, config-blocks,
# doc-scaffolds) are preserved verbatim, keys, order and values; each recomputed entry keeps
# its recorded customized flag (new entries: false). NOT advisory: exit 0 on success; exit 1
# (nothing written) when the project, config, or an existing manifest cannot be read safely.
#
# POSIX note: the Windows sibling keys its recordedByPath table OrdinalIgnoreCase, because NTFS
# path identity is case-insensitive, and that table's collision report exists to catch two
# recorded paths that differ only by case colliding into one entry. POSIX path identity is
# Ordinal (case-sensitive), so that table here is a plain, case-sensitive Map and the collision
# branch below can never fire on this platform: it stays in the code, unreachable, rather than
# being deleted, matching the divergence named in the v3.7.2 POSIX-parity plan section A5.
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
command -v node >/dev/null 2>&1 || { echo "manifest-write: node is required on PATH and was not found" >&2; exit 1; }
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

// manifestWriteDropCap (MANIFEST.json constants block), hardcoded here the same way the
// Windows sibling hardcodes $DROP_CAP: templates/MANIFEST.json is fetched into staging and
// never installed into .phaneslight/, so an installed script cannot read it at runtime.
// MW-7 repair: the stale-entry and collision lists printed to stdout were uncapped and
// unflagged; 300 stale entries produced 9,122 characters straight into the calling session's
// context. The cap and the truncation flag close that.
const DROP_CAP = 20;

// $(...) in the .ps1 interpolates a null Reason as an empty string, not the word "null"; this
// keeps every fixed-shape refusal message byte-identical to that.
function reasonOrEmpty(r) { return (r === null || r === undefined) ? '' : r; }

function osMsg(e) { return (e && e.message) ? e.message : String(e); }

const root = findRoot();
if (!root) {
  process.stderr.write('manifest-write: .phaneslight/config.json not found from this directory\n');
  process.exit(1);
}

// Config: phanesLightVersion and projectSlug feed the manifest header. A malformed config is a
// refusal (exit 1): this script writes the provenance record other tooling trusts, and
// writing it while the project's own config is unreadable would bless an unknown state.
// MW-5 repair: the draft's read never distinguished the five malformed shapes (empty,
// whitespace-only, literal null, bare-array, bare-string) from a genuine object, so a manifest
// was written with a null phanesLightVersion and a null projectSlug at exit 0, blessing a state
// the script could not read. requireMember is not used here because a config legitimately may
// not carry either key; requiring a parsed OBJECT is the gate, and readJsonFile's shared check
// alone rejects all five shapes.
const cfgRead = readJsonFile(path.join(root, '.phaneslight', 'config.json'));
if (cfgRead.status !== 'ok') {
  process.stderr.write('manifest-write: .phaneslight/config.json is ' + cfgRead.status + ' (' + reasonOrEmpty(cfgRead.reason) + '); nothing written, repair the config first\n');
  process.exit(1);
}
const cfg = cfgRead.value;

// MW-1 repair, the CRITICAL one. Rewriting over a manifest we cannot parse destroys the
// agent-class and workflow-class provenance entries only the session can reconstruct, so this
// refuses on a parse failure. But that refusal never fired for FIVE corrupt shapes in the
// draft, by the same two mechanisms MW-5 closed for the config: an empty file short-circuited
// before the parse ever ran, and whitespace-only, literal-null, bare-array and bare-string
// content all parsed cleanly with no .artifacts member, so the manifest was rewritten from
// scratch at exit 0 and the preserved classes were gone. Requiring a parsed OBJECT carrying an
// artifacts member (readJsonFile's requireMember) closes all five with one guard; the sixth,
// an artifacts member present but not an array, is closed separately just below, because
// readJsonFile only knows the member exists, not its shape.
const manifestPath = path.join(root, '.phaneslight', 'manifest.json');
let existing = null;
const mfRead = readJsonFile(manifestPath, 'artifacts');
if (mfRead.status === 'ok') {
  existing = mfRead.value;
} else if (mfRead.status !== 'absent') {
  process.stderr.write('manifest-write: existing .phaneslight/manifest.json is ' + mfRead.status + ' (' + reasonOrEmpty(mfRead.reason) + '); nothing written. Repair or deliberately delete it, then re-run\n');
  process.exit(1);
}
if (existing !== null && !Array.isArray(existing.artifacts)) {
  process.stderr.write('manifest-write: existing .phaneslight/manifest.json has a non-array artifacts member; nothing written\n');
  process.exit(1);
}

// phanesLightVersion: config first, then templates.version, then the existing manifest, then
// null (a Phase 2.5 install runs before Phase 5 stamps phanesLightVersion; null is honest
// there).
let phanesLightVersion = null;
if (typeof cfg.phanesLightVersion === 'string') phanesLightVersion = cfg.phanesLightVersion;
else if (cfg.templates && typeof cfg.templates.version === 'string') phanesLightVersion = cfg.templates.version;
else if (existing && typeof existing.phanesLightVersion === 'string') phanesLightVersion = existing.phanesLightVersion;
// LEGACY-NAME-BLOCK BEGIN
// F-097. The third and fourth readers of the config/manifest key. A project whose config or
// manifest predates the v3.6.0 rename carries phanesVersion, which the rename turned into
// phanesLightVersion here but not on their disk. Without these two the read yields null and
// the rewritten manifest loses the version. Tried last, so no non-legacy project changes.
else if (typeof cfg.phanesVersion === 'string') phanesLightVersion = cfg.phanesVersion;
else if (existing && typeof existing.phanesVersion === 'string') phanesLightVersion = existing.phanesVersion;
// LEGACY-NAME-BLOCK END
let projectSlug = null;
if (typeof cfg.projectSlug === 'string') projectSlug = cfg.projectSlug;
else if (existing && typeof existing.projectSlug === 'string') projectSlug = existing.projectSlug;

// Recorded state: preserved classes pass through verbatim (the same parsed value is re-added
// to the output array untouched, so its own key order and any extra fields survive);
// recomputed-scope paths contribute their recorded class and customized flag.
function normalizeRel(p) { return String(p).split('\\').join('/'); }

// MW-6 and MW-10 are resolved together, because they pull in opposite directions: this table
// maps a recorded path to the FILE ON DISK it describes, which on Windows is an
// OrdinalIgnoreCase filesystem-identity question (MW-6: an Ordinal prefix test there created a
// permanent phantom manifest entry and dropped customized: true, because the recorded entry
// never matched the file it described). On POSIX, path identity is Ordinal, so a plain Map
// is the exact equivalent and needs no case-folding.
//
// MW-10, the collision case, is DETECTED and reported rather than made impossible: an
// OrdinalIgnoreCase table plus an explicit has() check before each insert on Windows, so two
// recorded entries differing only in case are merged with a warning instead of one silently
// vanishing. On POSIX this Map is case-sensitive, so two such entries are two distinct keys
// and never collide: the detection code stays (pathCollisions, the WARNING line below) because
// it is structurally part of the port, but it is unreachable here. This is the NTFS
// case-insensitive path identity divergence the v3.7.2 POSIX-parity plan names at section A5.
const recordedByPath = new Map();
const pathCollisions = [];
const preserved = [];
if (existing && existing.artifacts) {
  for (const a of existing.artifacts) {
    if (!a || typeof a.path !== 'string') continue;
    const np = normalizeRel(a.path);
    // MW-6: the scan-scope prefix test is a path check, so it follows the same platform rule
    // as recordedByPath above: OrdinalIgnoreCase on Windows, Ordinal here.
    if (np.indexOf('.phaneslight/scripts/') === 0 || np.indexOf('.claude/template/') === 0) {
      if (recordedByPath.has(np)) pathCollisions.push(np);
      recordedByPath.set(np, a);
    } else {
      preserved.push(a);
    }
  }
}

// Recompute: every file under .phaneslight/scripts/ and .claude/template/.
const artifacts = [];
const removed = [];
const seen = new Set();
const scanRoots = [
  { dir: path.join(root, '.phaneslight', 'scripts'), prefix: '.phaneslight/scripts/', class: 'script' },
  { dir: path.join(root, '.claude', 'template'), prefix: '.claude/template/', class: 'template' }
];
const counts = { script: 0, hook: 0, template: 0 };

// Found during W3.2 execution: both scanned trees are FLAT by contract (installed scripts are
// staged flat, and templates are flat for the same reason), and the enumeration below is
// deliberately non-recursive to match. The defect was not the flatness, it was the silence: a
// nested file was omitted from the manifest with no trace anywhere, so a file that IS installed
// carried no provenance and nothing ever said so. It is named here rather than turned into a
// refusal, because a new exit-1 condition would make a project carrying one stray nested file
// unable to record provenance until a human intervened.
const nestedFound = [];

for (const sr of scanRoots) {
  if (!fs.existsSync(sr.dir)) continue;
  const srFull = path.resolve(sr.dir);

  // Recursive, best-effort nested-file scan. Any enumeration error anywhere in the tree is
  // swallowed here, the POSIX shape of the empty catch around the .ps1's recursive
  // Get-ChildItem: this scan never blocks the write, only the flat listing below does.
  (function walk(d) {
    let entries;
    try { entries = fs.readdirSync(d, { withFileTypes: true }); } catch (e) { return; }
    for (const ent of entries) {
      const full = path.join(d, ent.name);
      if (ent.isDirectory()) {
        walk(full);
      } else if (ent.isFile()) {
        // A path compared against a path is the filesystem identity question: Ordinal here,
        // OrdinalIgnoreCase on Windows, the same rule as recordedByPath above.
        if (path.dirname(full) !== srFull) {
          nestedFound.push(sr.prefix + full.slice(srFull.length + 1).split(path.sep).join('/'));
        }
      }
    }
  })(sr.dir);

  // MW-9 repair: this enumeration sat outside any try/catch in the draft, so an unreadable
  // scan directory produced a raw stack trace instead of a manifest-write: message. It
  // degraded safely (exit 1, manifest untouched) either way, so the fix is the message, not
  // the outcome.
  let dirents;
  try {
    dirents = fs.readdirSync(sr.dir, { withFileTypes: true });
  } catch (e) {
    process.stderr.write('manifest-write: cannot enumerate ' + sr.dir + ' (' + osMsg(e) + '); nothing written\n');
    process.exit(1);
  }
  const names = [];
  for (const ent of dirents) { if (ent.isFile()) names.push(ent.name); }
  names.sort();
  for (const n of names) {
    const rel = sr.prefix + n;
    const full = path.join(sr.dir, n);
    let sha;
    try {
      sha = sha256Hex(fs.readFileSync(full));
    } catch (e) {
      process.stderr.write('manifest-write: cannot hash ' + rel + '; nothing written\n');
      process.exit(1);
    }
    let cls = sr.class;
    let customized = false;
    // W3.4: templateSha256 is the hash of the TEMPLATE the file was installed from, a
    // different question from sha256, the hash of the file ON DISK. For an uncustomized file
    // the two are equal; for a customized one they diverge, and templateSha256 is the
    // fingerprint of the template the user customized AWAY FROM. This script cannot know it (no
    // network, no staging directory): it PRESERVES a recorded value and never invents one. A
    // pre-v3.4 manifest carries none and stays unknown forever: a guessed value would produce a
    // false all-clear, worse than an admitted unknown.
    let templateSha = null;
    if (recordedByPath.has(rel)) {
      const rec = recordedByPath.get(rel);
      if (typeof rec.class === 'string') cls = rec.class;
      if (typeof rec.customized === 'boolean') customized = rec.customized;
      if (typeof rec.templateSha256 === 'string') templateSha = rec.templateSha256;
    } else if (sr.class === 'script' && n.indexOf('hook-') === 0) {
      // Artifact class by name: any newly seen file under the scripts tree whose name starts
      // with "hook-" is classed hook rather than script. Only for a NEW entry: a recorded
      // class always wins over this rule, which is why this branch is the else of the
      // recordedByPath lookup above, never a plain check on n alone.
      cls = 'hook';
    }
    // An UNCUSTOMIZED file is byte-identical to the template it came from, so the disk hash IS
    // the template hash and recording it is an observation, not a guess. This is the migration
    // path for pre-v3.4 manifests: uncustomized entries populate on the first run at this
    // version, customized ones stay unknown.
    if (templateSha === null && !customized) templateSha = sha;
    if (Object.prototype.hasOwnProperty.call(counts, cls)) counts[cls]++;
    seen.add(rel);
    const entry = new Map();
    entry.set('path', rel);
    entry.set('class', cls);
    entry.set('sha256', sha);
    entry.set('templateSha256', templateSha);
    entry.set('customized', customized);
    artifacts.push(entry);
  }
}
for (const rel of recordedByPath.keys()) {
  if (!seen.has(rel)) removed.push(rel);
}
removed.sort();

for (const a of preserved) artifacts.push(a);

// Timestamp, ISO 8601 with a numeric offset (or Z at UTC), matching the layout of the
// InvariantCulture 'yyyy-MM-ddTHH:mm:ssK' format the Windows sibling writes. This value is
// masked by the harness in every differential run: the two sides run at different instants and
// byte parity was never a claim for it.
function pad2(n) { return n < 10 ? '0' + n : String(n); }
function stampNow() {
  const d = new Date();
  const off = -d.getTimezoneOffset();
  const oh = pad2(Math.floor(Math.abs(off) / 60));
  const om = pad2(Math.abs(off) % 60);
  const tz = off === 0 ? 'Z' : ((off > 0 ? '+' : '-') + oh + ':' + om);
  return d.getFullYear() + '-' + pad2(d.getMonth() + 1) + '-' + pad2(d.getDate()) + 'T' +
    pad2(d.getHours()) + ':' + pad2(d.getMinutes()) + ':' + pad2(d.getSeconds()) + tz;
}

const manifest = new Map();
manifest.set('manifestVersion', 1);
manifest.set('phanesLightVersion', phanesLightVersion);
manifest.set('stampedAt', stampNow());
manifest.set('projectSlug', projectSlug);
manifest.set('artifacts', artifacts);

try {
  fs.writeFileSync(manifestPath, toNodeJson(manifest, 0) + '\n', 'utf8');
} catch (e) {
  process.stderr.write('manifest-write: cannot write ' + manifestPath + ' (' + osMsg(e) + ')\n');
  process.exit(1);
}

let msg = 'manifest-write: recorded ' + artifacts.length + ' artifacts (' + counts.script + ' scripts, ' + counts.hook + ' hooks, ' + counts.template + ' templates, ' + preserved.length + ' preserved other-class)';
// MW-7 repair: this list was uncapped and unflagged in the draft, and 300 stale entries
// produced 9,122 characters on stdout, straight into the calling session's context. A cap with
// the exact count and a truncation flag closes it.
if (removed.length > 0) {
  const shown = removed.slice(0, DROP_CAP);
  msg += '; dropped ' + removed.length + ' stale entries: ' + shown.join(', ');
  if (removed.length > DROP_CAP) msg += ' [list truncated, ' + (removed.length - DROP_CAP) + ' more]';
}
if (pathCollisions.length > 0) {
  msg += '; WARNING: ' + pathCollisions.length + ' recorded path(s) differ only by case and were merged: ' + pathCollisions.slice(0, DROP_CAP).join(', ');
}
if (nestedFound.length > 0) {
  const nestedSorted = nestedFound.slice().sort();
  const shownN = nestedSorted.slice(0, DROP_CAP);
  process.stderr.write('manifest-write: ' + nestedSorted.length + ' nested file(s) were NOT recorded; both scanned trees are flat by contract: ' + shownN.join(', ') + '\n');
  msg += '; NOT recorded, nested: ' + nestedSorted.length;
}
process.stdout.write(msg + '\n');
process.exit(0);
