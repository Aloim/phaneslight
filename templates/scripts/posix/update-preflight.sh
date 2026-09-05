#!/bin/sh
# phaneslight-template v3.8.0 update-preflight
# The update-run fast-path aggregator: runs the sensors (census-diff, hook table, register
# breach state, manifest sha256 drift, module-list vs config, optional spec-version compare)
# and the git delta, and emits ONE JSON verdict {sensors, quiet, gitDelta}. quiet is true only
# on POSITIVE evidence of stasis: a sensor that cannot observe reports available:false and the
# verdict is NOT quiet, because unknown is not quiet. gitDelta is separate from quiet by
# contract: the session requires quiet AND gitDelta.available AND an empty changedFiles before
# taking the fast path. hook-verify folds in here: `update-preflight --hooks-only` prints just
# the hooks sensor (the standalone hook-verify form; same logic, one implementation).
# Optional: --spec-version <v> compares the RUNNING spec's version against the installed one;
# without it that sensor is reported not-provided and excluded from quiet (Step 0's own
# self-version check already covers it and is never skipped). Advisory: always exits 0.
#
# THE SHELL PART OF THIS FILE ENDS AT THE "# BEGIN NODE PROGRAM" MARKER. Everything after it is
# JavaScript, read out of this file by sed and piped to `node -`, and never parsed by the shell,
# which has exited before it gets there. `dash -n` on the whole file therefore fails by design;
# each half is checked by its own checker, `dash -n` on the shell prefix and `node --check` on
# the JavaScript suffix. The heredoc form this shape replaces delivered ZERO BYTES for any body
# of 4096 bytes or more on the target machine's dash, silently, which for an always-exit-0
# aggregator is indistinguishable from a clean report.
#
# POSIX notes, each a place where the Windows original could not be copied word for word:
#
#   1. The three sibling sensors are invoked as `sh <sibling>.sh`, not run in-process. The
#      Windows sibling calls `& census-diff.ps1` inside its own PowerShell session, so a crash
#      in the child surfaces there as a caught exception; here it surfaces as a non-zero exit
#      code. The verdict is taken from the EXIT CODE on both sides and never from the presence
#      of stderr text, so a sibling that chatters on stderr and exits 0 still reads as success.
#   2. Siblings resolve through PHANESLIGHT_HERE, exported below. __dirname does not exist under
#      `node -`, and process.argv[1] is the literal "-", so neither can stand in for the
#      Windows $PSScriptRoot.
#   3. Three "not installed" reason strings name the POSIX file: 'census-diff.sh not installed',
#      'register-check.sh not installed', 'module-list.sh not installed', where the Windows
#      sibling names the .ps1. The hooks sensor likewise tests for
#      .phaneslight/scripts/<hook>.sh where Windows tests for <hook>.ps1. These are the only
#      intended stdout differences between the two verdicts, they fire only on a project missing
#      the sibling scripts entirely, and naming the Windows file on a POSIX box would be a
#      statement the script cannot support.
#   4. Path identity is ORDINAL and case-sensitive throughout, because POSIX paths are. The
#      sha256 compare stays case-INSENSITIVE, matching the Windows OrdinalIgnoreCase compare:
#      Node's crypto emits lowercase hex where Get-FileHash emits uppercase, and a manifest may
#      carry either.
#   5. node is required. When it is absent this script still prints a WHOLE verdict, with no
#      sensors, quiet false and gitDelta unavailable, and still exits 0. An aggregator that
#      cannot look must say so in the shape its consumer already parses; it must never print
#      nothing, and a caller that parses nothing reads it as a clean fast path. That degrade
#      block is one heredoc of well under the 4095-byte ceiling measured on the target machine's
#      dash, and it is the only heredoc left in this file.
here=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd); export PHANESLIGHT_HERE="$here"
# Resolved through $here rather than used as given, so the program is read from the file that is
# running even when $0 arrived as a bare name through a PATH lookup.
self="$here/$(basename -- "$0")"
command -v node >/dev/null 2>&1 || {
  echo "update-preflight: node is required on PATH and was not found; no sensor could be read and the verdict is NOT quiet" >&2
  cat <<'DEGRADE'
{
  "sensors": {},
  "quiet": false,
  "gitDelta": {
    "available": false,
    "reason": "node unavailable"
  }
}
DEGRADE
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

// updatePreflightListCap. Hardcoded 100, exactly as the Windows sibling hardcodes $CAP = 100 at
// its line 14. It caps FOUR lists: manifest.drifted, manifest.missing, customizations.entries
// and gitDelta.changedFiles. Every count beside them is exact and a listTruncated flag says
// whether a list was cut, so a consumer can never mistake 100 for "all".
const CAP = 100;

// PowerShell truthiness, replicated rather than approximated with a plain JS truthy check.
// PowerShell's boolean coercion of a collection is COUNT based: an empty array is false, a
// one-element array unwraps to the truthiness of that element, and a larger array is
// unconditionally true. A plain `if (settings.hooks.PreToolUse)` in JS reads an empty array as
// true, which would send the stale-entry scan into a list that has nothing in it and, worse,
// would read an explicitly emptied hook table as a populated one.
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

// PowerShell's @(x): a scalar becomes a one-element array and an array is left alone. Kept
// exactly, including the fact that @($null) iterates ONCE with a null element, because the
// guards inside each loop below were written against that behaviour: a manifest whose artifacts
// member is a dictionary rather than an array iterates once over the dictionary and is rejected
// by the per-entry type test, which is how a v3.4-and-later manifest reports checked 0 rather
// than crashing. Rewriting this as "empty array when absent" would be a different program.
function psArray(v) {
  if (Array.isArray(v)) return v;
  return [v];
}

// PowerShell's [string]$x for the one place a manifest value reaches a string cast: [string]$null
// is the empty string, where JS String(undefined) is the four characters "undefined".
function psString(v) {
  if (v === null || v === undefined) return '';
  return String(v);
}

// A child's stdout as PowerShell's `@(& script)` sees it: one element per line, with the final
// empty element after the trailing newline dropped and interior blank lines KEPT. Line
// discipline is CRLF tolerant because a sibling could have been installed with CRLF endings.
function outLines(s) {
  if (typeof s !== 'string' || s === '') return [];
  const parts = s.split(/\r?\n/);
  if (parts.length > 0 && parts[parts.length - 1] === '') parts.pop();
  return parts;
}

// The Windows sibling runs census-diff, register-check and module-list INSIDE its own PowerShell
// session with `& $path`, so whatever those three write to stderr lands on THIS script's stderr
// and reaches the operator. runChild captures a child's stderr into a pipe instead, which would
// silently swallow lines like "census-diff: .phaneslight/config.json is malformed", so it is
// written back out here verbatim. The verdict is still taken from the exit code alone: this
// forwards the text, it never reads it.
//
// git's stderr is deliberately NOT forwarded. On the failing branch git prints its entire
// several-kilobyte usage screen, which on Windows is an accident of running a native command
// in-process rather than anything the script chose to say, and the one fact it carries is
// already reported as gitDelta.reason. Reproducing that dump would bury the script's own lines.
function passThroughStderr(r) {
  if (r && typeof r.stderr === 'string' && r.stderr !== '') { process.stderr.write(r.stderr); }
}

// --- arguments
let hooksOnly = false;
let specVersion = null;
let specVersionMissing = false;
const argv = process.argv.slice(2);
for (let i = 0; i < argv.length; i++) {
  const a = String(argv[i]);
  if (a === '--hooks-only') { hooksOnly = true; }
  else if (a === '--spec-version') {
    // M5 repair, and SS00028's field investigation sharpened this well beyond its recorded
    // severity. This flag IS the new-spec-versus-old-scripts skew sensor, and skew is the NORMAL
    // state of every untouched project after a release: phaneslight.md propagates globally and
    // instantly from ~/.claude/commands, while scripts propagate to a project only when someone
    // runs an update there. The draft exited 0 printing NOTHING when the flag carried no value,
    // which a caller parses as null and reads as "no skew". A sensor whose whole job is catching
    // the normal post-release condition had a SILENT ALL-CLEAR failure mode. It now falls through
    // and emits the full verdict with the spec sensor explicitly unavailable, so the caller sees
    // could-not-observe rather than nothing at all.
    if (i + 1 >= argv.length) {
      process.stderr.write('update-preflight: --spec-version requires a value; the spec sensor reports unavailable\n');
      specVersionMissing = true;
    } else { specVersion = String(argv[i + 1]); i++; }
  }
  else { process.stderr.write("update-preflight: unknown argument '" + a + "' ignored\n"); }
}

const root = findRoot();
if (!root) {
  process.stderr.write('update-preflight: .phaneslight/config.json not found from this directory\n');
  emitJson({ sensors: {}, quiet: false, gitDelta: { available: false, reason: 'no project root' } });
  process.exit(0);
}

const cfgRead = readJsonFile(path.join(root, '.phaneslight', 'config.json'));
const cfg = cfgRead.value;
const cfgOk = (cfgRead.status === 'ok');

// ---------- hooks sensor (the folded hook-verify) ----------
function getHooksSensor() {
  // m5 repair, an inverse inconsistency rather than a missing guard. The three input states
  // collapsed into two here, and they collapsed the wrong way round: a MALFORMED settings file
  // correctly reported available: false, while an ABSENT one reported available: true, and an
  // UNREADABLE one (denied ACL) was silently treated as absent by a failed existence check.
  // Absent is a genuine observation, and the honest reading of it is "no hooks are configured",
  // so it stays available with delta true from the per-hook loop below. Unreadable and
  // malformed are both could-not-observe and now report identically.
  //
  // The manual line still merges the settings fragment (install-templates writes the three
  // hook entries into .claude/settings.json itself, unlike the plugin, which registers hooks
  // through its own manifest), so settings.json is the correct place to look for `present` and
  // `pathDiscipline`, matching the windows sibling's shape.
  const sensor = { available: true, delta: false };
  const settingsPath = path.join(root, '.claude', 'settings.json');
  let settings = null;
  const sr = readJsonFile(settingsPath);
  if (sr.status === 'ok') { settings = sr.value; }
  else if (sr.status !== 'absent') {
    sensor.available = false; sensor.delta = true;
    sensor.reason = '.claude/settings.json is ' + sr.status + ' (' + sr.reason + ')';
    return sensor;
  }
  const wanted = [
    { key: 'stampGuard', event: 'PreToolUse', needle: 'hook-stamp-guard' },
    { key: 'sizeCheck', event: 'PostToolUse', needle: 'hook-size-check' },
    { key: 'ledgerStatus', event: 'SessionStart', needle: 'hook-ledger-status' }
  ];
  for (const w of wanted) {
    const entry = { present: false, pathDiscipline: false, scriptExists: false };
    let cmd = null;
    if (settings && psTruthy(settings.hooks) && psTruthy(settings.hooks[w.event])) {
      for (const grp of psArray(settings.hooks[w.event])) {
        for (const h of psArray(grp ? grp.hooks : null)) {
          if (h && typeof h.command === 'string' && h.command.indexOf(w.needle) >= 0) { cmd = h.command; break; }
        }
        if (cmd !== null) break;
      }
    }
    if (cmd !== null) {
      entry.present = true;
      // The drive-letter test is kept on POSIX, where a drive letter cannot appear in a native
      // path, because settings.json is a portable file: a project shared from a Windows machine
      // carries Windows hook commands, and refusing to see them here would leave them unrepaired.
      entry.pathDiscipline = (cmd.indexOf('.phaneslight/scripts/') >= 0) &&
        !/[a-z]:[\\/]/i.test(cmd) && !/(^|\s)\//.test(cmd);
      entry.scriptExists = fs.existsSync(path.join(root, '.phaneslight', 'scripts', w.needle + '.sh'));
    }
    if (!(entry.present && entry.pathDiscipline && entry.scriptExists)) { sensor.delta = true; }
    sensor[w.key] = entry;
  }
  return sensor;
}

const hooksSensor = getHooksSensor();
if (hooksOnly) {
  emitJson({ hooks: hooksSensor });
  process.exit(0);
}

const sensors = {};
const here = HERE;

// ---------- spec sensor (optional by design) ----------
let spec = { available: false, delta: false, reason: 'spec version not provided; Step 0 covers it' };
// The two not-provided cases are NOT the same and must not report the same thing. Nobody asked
// (no flag) is a quiet, expected state that Step 0 covers by other means. Somebody asked and the
// value was missing is a FAILED sensor reading, and a failed reading is never quiet: delta is
// true so the composite fast-path condition cannot evaluate to quiet on the strength of a
// question that was never actually answered.
if (specVersionMissing) {
  spec = { available: false, delta: true, reason: '--spec-version was passed with no value; skew could NOT be measured' };
}
else if (specVersion !== null) {
  spec = { available: true, delta: false, spec: specVersion, installed: null };
  if (cfgOk && cfg && typeof cfg.phanesLightVersion === 'string') { spec.installed = cfg.phanesLightVersion; }
  // LEGACY-NAME-BLOCK BEGIN
  // A pre-v3.6.0 install still carries phanesVersion in .phanes/config.json. Without this the
  // fast-path aggregator reports a null installed version on every legacy-named install, its
  // delta is permanently true, and every update run pays for a full preflight it did not need.
  if (typeof spec.installed !== 'string') {
    try {
      const lcfg = JSON.parse(fs.readFileSync(path.join(root, '.phanes', 'config.json'), 'utf8'));
      if (lcfg && typeof lcfg.phanesVersion === 'string') { spec.installed = lcfg.phanesVersion; }
    } catch (e) { /* absent or unparseable legacy config: installed stays null, delta becomes true */ }
  }
  // LEGACY-NAME-BLOCK END
  if (typeof spec.installed !== 'string' || spec.installed !== specVersion) { spec.delta = true; }
}
sensors.spec = spec;

// ---------- census sensor (sibling census-diff, one implementation) ----------
const census = { available: false, delta: true };
try {
  const cdPath = path.join(here, 'census-diff.sh');
  if (fs.existsSync(cdPath)) {
    const cdRun = runChild('sh', [cdPath], {});
    passThroughStderr(cdRun);
    if (!cdRun.available) {
      census.reason = 'census-diff crashed (' + cdRun.reason + ')';
    } else if (cdRun.code === 0 && cdRun.stdout !== '') {
      const cd = JSON.parse(cdRun.stdout);
      census.available = true;
      census.delta = (!cd.selectionPresent) || !!cd.configUntrusted || (!cd.mcpAvailable) ||
        (cd.addedCount > 0) || (cd.removedCount > 0) || (cd.changedCount > 0);
      census.addedCount = cd.addedCount; census.removedCount = cd.removedCount; census.changedCount = cd.changedCount;
      census.selectionPresent = cd.selectionPresent; census.mcpAvailable = cd.mcpAvailable;
    } else { census.reason = 'census-diff failed or printed nothing'; }
  } else { census.reason = 'census-diff.sh not installed'; }
} catch (e) { census.reason = 'census-diff crashed (' + (e && e.message ? e.message : String(e)) + ')'; }
sensors.census = census;

// ---------- hooks sensor ----------
sensors.hooks = hooksSensor;

// ---------- register sensor (sibling register-check) ----------
const register = { available: false, delta: true };
try {
  const rcPath = path.join(here, 'register-check.sh');
  if (fs.existsSync(rcPath)) {
    const rcRun = runChild('sh', [rcPath], {});
    passThroughStderr(rcRun);
    if (!rcRun.available) {
      register.reason = 'register-check crashed (' + rcRun.reason + ')';
    } else if (rcRun.code === 0) {
      register.available = true;
      register.delta = false;
      const statuses = {};
      for (const ln of outLines(rcRun.stdout)) {
        const m = /^(CLAUDE\.md|CLAUDE\.local\.md): (.*)$/.exec(ln);
        if (!m) continue;
        const v = m[2];
        if (v === 'absent') { statuses[m[1]] = 'absent'; register.delta = true; }
        else if (v.indexOf('[CROP-REQUIRED]') >= 0) { statuses[m[1]] = 'CROP-REQUIRED'; register.delta = true; }
        else if (v.indexOf('[SOFT-BREACH]') >= 0) { statuses[m[1]] = 'SOFT-BREACH'; register.delta = true; }
        else { statuses[m[1]] = 'OK'; }
      }
      register.status = statuses;
    } else { register.reason = 'register-check exited ' + String(rcRun.code); }
  } else { register.reason = 'register-check.sh not installed'; }
} catch (e) { register.reason = 'register-check crashed (' + (e && e.message ? e.message : String(e)) + ')'; }
sensors.register = register;

// ---------- manifest drift sensor ----------
const manifest = { available: false, delta: true };
const manifestPath = path.join(root, '.phaneslight', 'manifest.json');
if (!fs.existsSync(manifestPath)) {
  manifest.reason = '.phaneslight/manifest.json absent (provenance unknown; pre-v3.4 install or incomplete run)';
} else {
  try {
    const prov = JSON.parse(fs.readFileSync(manifestPath, 'utf8'));
    const drifted = [];
    const missing = [];
    let checked = 0;
    for (const a of psArray(prov ? prov.artifacts : null)) {
      if (!a || typeof a.path !== 'string' || typeof a.sha256 !== 'string') { continue; }
      checked++;
      // The Windows sibling rewrites the manifest's forward slashes to backslashes here. On
      // POSIX the recorded separator IS the native one, so the path is joined as recorded; a
      // backslash in a manifest path is a legal POSIX filename character and is not rewritten.
      const full = path.join(root, a.path);
      if (!fs.existsSync(full)) { missing.push(a.path); continue; }
      let disk = null;
      try { disk = sha256Hex(fs.readFileSync(full)); } catch (e2) { drifted.push(a.path); continue; }
      // Case-insensitive, matching the Windows OrdinalIgnoreCase compare: Get-FileHash emits
      // uppercase hex and Node's crypto emits lowercase, and either may be what was recorded.
      if (disk.toLowerCase() !== a.sha256.toLowerCase()) { drifted.push(a.path); }
    }
    // Ordinal sort. The default JS comparator sorts by UTF-16 code unit, which is what
    // StringComparer.Ordinal does.
    drifted.sort();
    missing.sort();
    manifest.available = true;
    manifest.delta = (drifted.length > 0 || missing.length > 0);
    manifest.checked = checked;
    manifest.driftedCount = drifted.length;
    manifest.drifted = drifted.slice(0, CAP);
    manifest.missingCount = missing.length;
    manifest.missing = missing.slice(0, CAP);
    manifest.listTruncated = (drifted.length > CAP || missing.length > CAP);
  } catch (e) {
    manifest.reason = '.phaneslight/manifest.json is malformed';
  }
}
sensors.manifest = manifest;

// ---------- modules sensor (sibling module-list vs config; a consistency check that catches
// ---------- malformed config and a bespoke module-list whose verdict drifted) ----------
const modules = { available: false, delta: true };
try {
  const mlPath = path.join(here, 'module-list.sh');
  if (fs.existsSync(mlPath)) {
    const mlRun = runChild('sh', [mlPath], {});
    passThroughStderr(mlRun);
    if (!mlRun.available) {
      modules.reason = 'module-list crashed (' + mlRun.reason + ')';
    } else if (mlRun.code === 0) {
      const mlOut = outLines(mlRun.stdout);
      modules.available = true;
      let expected = [];
      if (cfgOk && cfg && psTruthy(cfg.modules)) { expected = psArray(cfg.modules).map(psString); }
      if (expected.length === 0) { expected = ['(no modules configured)']; }
      modules.delta = false;
      if (mlOut.length !== expected.length) { modules.delta = true; }
      else { for (let i = 0; i < expected.length; i++) { if (mlOut[i] !== expected[i]) { modules.delta = true; break; } } }
      modules.count = mlOut.length;
    } else { modules.reason = 'module-list exited ' + String(mlRun.code) + ' (malformed config or bespoke script)'; }
  } else { modules.reason = 'module-list.sh not installed'; }
} catch (e) { modules.reason = 'module-list crashed (' + (e && e.message ? e.message : String(e)) + ')'; }
sensors.modules = modules;

// ---------- customization inventory (W3.4) ----------
// This sensor runs OFFLINE. It therefore CANNOT know the current template hash and MUST NOT
// claim staleness: the staleness verdict belongs to install-templates, which holds the staged
// template at the moment it decides to preserve. What this can honestly report is the INVENTORY:
// which files are customized, and whether each one even has a baseline to be compared against
// later. A pre-v3.4 manifest carries no templateSha256, so those entries report
// templateSha256Known false and are counted as UNKNOWN, never as fresh and never as stale.
// This is degrade-never-fabricate applied to a new sensor, which matters given how much of the
// review that produced it was about sensors inventing answers.
//
// Deliberately NOT an input to `quiet`, and the reason is worth stating because it looks like an
// omission. UNKNOWN is the normal, permanent state for every project installed before v3.4, so
// feeding it into quiet would make those projects non-quiet forever and destroy the fast path
// this whole workstream exists to build. This sensor informs; it does not gate.
const customizations = { available: false, count: 0, unknownCount: 0, entries: [], listTruncated: false };
const mfRead = readJsonFile(path.join(root, '.phaneslight', 'manifest.json'), 'artifacts');
if (mfRead.status === 'ok') {
  customizations.available = true;
  const rows = [];
  let unknown = 0;
  for (const a of psArray(mfRead.value.artifacts)) {
    if (!a || typeof a.customized !== 'boolean' || !a.customized) { continue; }
    const known = (typeof a.templateSha256 === 'string') && (a.templateSha256.trim() !== '');
    if (!known) { unknown++; }
    rows.push({ path: psString(a.path), templateSha256Known: known });
  }
  customizations.count = rows.length;
  customizations.unknownCount = unknown;
  customizations.entries = rows.slice(0, CAP);
  customizations.listTruncated = (rows.length > CAP);
} else {
  customizations.reason = 'manifest is ' + mfRead.status;
}
sensors.customizations = customizations;

// ---------- git delta (separate from quiet by contract) ----------
const gitDelta = { available: false };
let lastRef = null;
if (cfgOk && cfg && psTruthy(cfg.lastRun) && typeof cfg.lastRun.ref === 'string' && cfg.lastRun.ref !== '') {
  lastRef = String(cfg.lastRun.ref);
}
if (lastRef === null) {
  gitDelta.reason = 'no lastRun.ref recorded in config';
} else {
  // cwd is the project root, which is the POSIX shape of the Windows Push-Location/Pop-Location
  // pair. An unlaunchable git and a non-zero git are the SAME answer here and are reported with
  // the same three-cause reason, because the Windows sibling reaches that string from both its
  // exit-code branch and its exception branch and does not distinguish them either.
  const diffRun = runChild('git', ['diff', '--name-only', lastRef + '..HEAD'], { cwd: root });
  if (!diffRun.available || diffRun.code !== 0) {
    gitDelta.reason = 'git diff failed (not a repository, git unavailable, or the recorded ref is gone)';
  } else {
    const files = outLines(diffRun.stdout).filter(function (s) { return s !== ''; });
    gitDelta.available = true;
    gitDelta.ref = lastRef;
    gitDelta.changedCount = files.length;
    gitDelta.changedFiles = files.slice(0, CAP);
    gitDelta.listTruncated = (files.length > CAP);
    // `git diff <ref>..HEAD` sees COMMITTED history only, so FOUR classes of real work are
    // invisible to it: modified-tracked, staged-uncommitted, untracked, and deleted-tracked.
    // Measured: the composite fast-path condition (quiet AND available AND empty changedFiles)
    // evaluated TRUE on a materially dirty worktree, licensing a skip over uncommitted work.
    // `git status --porcelain` closes all four with one cheap call, and the flag is reported
    // rather than folded into changedFiles, because "committed since the last run" and "dirty
    // right now" are different questions and the session's rule branches on both.
    //
    // null, not false, when the porcelain call itself failed. A worktree whose state could not
    // be read is not a clean worktree.
    let worktreeDirty = null;
    const porcelain = runChild('git', ['status', '--porcelain'], { cwd: root });
    if (porcelain.available && porcelain.code === 0) {
      worktreeDirty = (outLines(porcelain.stdout).filter(function (s) { return s !== ''; }).length > 0);
    }
    gitDelta.worktreeDirty = worktreeDirty;
  }
}

// ---------- verdict ----------
// quiet is a conjunction over the five GATING sensors only. customizations informs and does not
// gate (see its own note above). The spec sensor sits outside the loop and gates on its DELTA
// alone, never on its availability, because ONE of its unavailable shapes is legitimately quiet:
// nobody passed the flag, delta is false, and Step 0 covers the check by other means. The other
// unavailable shape is a sensor that was asked and FAILED, delta true, and gating on `available`
// swallowed it: measured on a compliant project, spec.delta was true and quiet was true in the
// same verdict, which is a silent all-clear from a sensor that had just said it could not
// measure. Reading delta alone keeps the no-flag case quiet and lets the failed reading gate.
let quiet = true;
for (const name of ['census', 'hooks', 'register', 'manifest', 'modules']) {
  const s = sensors[name];
  if (!s.available || s.delta) { quiet = false; }
}
if (sensors.spec.delta) { quiet = false; }

emitJson({ sensors: sensors, quiet: quiet, gitDelta: gitDelta });
process.exit(0);
