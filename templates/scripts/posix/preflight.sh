#!/bin/sh
# phaneslight-template v3.8.1 preflight
# Phase 0 mechanical pre-flights, observed and reported, NEVER acted on: run-type marker,
# installed version, the four standard MCP servers via `claude mcp list`, platform,
# capability-census counts, and the legacy-migration signals. Emits ONE digest JSON. Consent,
# AskUserQuestion, MCP installs, the STOP-and-route-to-phaneslightupgrade judgment, and every
# other decision stay in the session: this script observes and never mutates anything.
# Advisory: always exits 0.
#
# THE SHELL PART OF THIS FILE ENDS AT THE "# BEGIN NODE PROGRAM" MARKER. Everything after it is
# JavaScript, read out of this file by sed and piped to `node -`, and never parsed by the shell,
# which has exited before it gets there. `dash -n` on the whole file therefore fails by design;
# each half is checked by its own checker, `dash -n` on the shell prefix and `node --check` on
# the JavaScript suffix. The heredoc form this shape replaces delivered ZERO BYTES for any body
# of 4096 bytes or more on the target machine's dash, silently, which for an always-exit-0
# sensor is indistinguishable from a clean report.
#
# POSIX notes, each a place where the Windows original could not be copied word for word:
#
#   1. platform is reported as "posix" where the Windows sibling reports "windows". That single
#      key is the ONLY intended difference between the two digests, and the differential harness
#      masks exactly that key and fails if it is absent on either side.
#   2. The Windows script keeps the loose-root walk in a "# BEGIN SHARED looseroot" region. There
#      is no POSIX twin of that region because preflight is its only consumer, so it is ported
#      here as a private function, findRootLoose, immediately below the shared node-core block.
#   3. Path identity is ORDINAL here. The Windows sibling compares paths OrdinalIgnoreCase under
#      its documented NTFS exception; POSIX paths are case-sensitive and a case-insensitive
#      compare would merge two genuinely different directories.
#   4. Get-ChildItem skips attribute-hidden entries. There is no such attribute on POSIX, so the
#      census counters and the CLAUDE.md sprawl walk see every entry. This is a divergence only
#      on a Windows filesystem, and only for an entry carrying the hidden attribute.
#   5. `*.md` is matched case-sensitively, because a POSIX glob is.
#   6. node is required. When it is absent this script still prints its WHOLE digest, with
#      runType "unknown", markerReadable and configReadable false, rootSource "none" and every
#      other value null, and still exits 0. A sensor that cannot look must say so in the shape
#      its consumer already parses; it must never print nothing, and it must never print zeros.
#      That degrade block is one heredoc of 798 bytes, comfortably inside the 4095-byte ceiling
#      measured on the target machine's dash, and it is the only heredoc left in this file.
here=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd); export PHANESLIGHT_HERE="$here"
# Resolved through $here rather than used as given, so the program is read from the file that is
# running even when $0 arrived as a bare name through a PATH lookup.
self="$here/$(basename -- "$0")"
command -v node >/dev/null 2>&1 || {
  echo "preflight: node is required on PATH and was not found; every sensor degrades to could-not-observe" >&2
  cat <<'DEGRADE'
{
  "runType": "unknown",
  "marker": null,
  "legacyNaming": null,
  "markerReadable": false,
  "configReadable": false,
  "rootSource": "none",
  "installedVersion": null,
  "mcp": {
    "context7": null,
    "deepwiki": null,
    "serena": null,
    "semble": null
  },
  "platform": "posix",
  "censusCounts": {
    "agents": null,
    "commandsProject": null,
    "commandsUser": null,
    "plugins": null,
    "skillsProject": null,
    "skillsUser": null,
    "mcpServers": null
  },
  "censusUnreadable": null,
  "legacyMarkers": {
    "noVersionStamp": null,
    "unprefixedTemplateAgents": null,
    "unprefixedTemplateAgentsCount": null,
    "sequentialThinkingAgents": null,
    "sequentialThinkingAgentsCount": null,
    "subfolderClaudeMdCount": null,
    "listTruncated": null
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

// preflightListCap. Hardcoded 20, exactly as the Windows sibling hardcodes $CAP = 20 at its
// line 8. It caps the two legacy-signal LISTS only; the counts beside them are always exact and
// listTruncated says whether a list was cut, so a consumer can never mistake 20 for "all".
const CAP = 20;

// --- the loose root -----------------------------------------------------------------------
//
// Ported from the "# BEGIN SHARED looseroot" region of preflight.ps1. There is no shared POSIX
// twin of that region: preflight is its only consumer, so it lives here as a private function.
//
// The loose root, for preflight and preflight only: the one command that must also run against
// a project PhanesLight has NOT bootstrapped yet, where no .phaneslight/config.json exists.
// Strict root first, then a BOUNDED walk for a .claude directory, then the current directory.
//
// The walk is bounded because the unbounded version was the worst single defect in this set: it
// walked up into the user home and censused the whole machine as the project, reporting 6
// project commands and 12 CLAUDE.md files on an EMPTY fixture. Excluding one literal home
// string and SKIPPING that rung rather than stopping at it did not hold: the original signature
// was reproduced three separate ways, including a second .claude sitting above the excluded
// home.
//
// Four stop conditions replace the one exclusion:
//   1. depth cap of 24         A backstop, not a rule. It should never be the thing that stops a
//                              real walk, and if it ever is, source and stoppedBy say so.
//   2. the home directory      Stop. Resolved through homeDir(), which returns null rather than
//                              throwing, never by reading one environment string that can be
//                              unset or spelled differently from the walk's own spelling.
//   3. no parent               The filesystem root is never a project root, and it is refused
//                              WITHOUT testing the directory. On POSIX this is the bind-mount
//                              and chroot analogue of the Windows subst case: / can genuinely
//                              carry a .claude, so a no-parent check placed after the accept
//                              would never run.
//   4. .git in this directory  Stop after testing this level. Never walk out of a repository
//                              into its parent. This is also what protects a fresh project
//                              sitting under a directory that has grown its own .claude.
//
// EVERY refusing stop is evaluated BEFORE the accept, and that grouping is the whole design, not
// a style choice. A stop placed after the accept does not stop anything: the walk still ends on
// the forbidden directory, it just gets there by SUCCEEDING instead of by continuing, which is
// the original defect wearing a different shape. This was written the wrong way round twice on
// the Windows side and caught both times only by running it. Keep the stops together and above
// the accept, and the class cannot recur. The stop ORDER above is the source order and is
// preserved exactly: depth cap, home, no parent, then the accept, then .git.
//
// Returns { root, source ('config' | 'claude-walk' | 'cwd' | 'none'), stoppedBy }. It reports
// HOW it chose, not just what it chose, because preflight is observe-only and the session does
// the judging. A root reached by guessing is something the caller is entitled to know about
// before it acts on a census taken there.
function findRootLoose() {
  const strict = findRoot();
  if (strict) return { root: strict, source: 'config', stoppedBy: null };
  const home = homeDir();
  const homeResolved = home ? path.resolve(home) : null;
  let cwd = null;
  try { cwd = process.cwd(); } catch (e) { cwd = null; }
  let d = cwd;
  let depth = 0;
  let stopped = 'exhausted';
  while (d) {
    if (depth >= 24) { stopped = 'depth-cap'; break; }
    if (homeResolved && path.resolve(d) === homeResolved) { stopped = 'home'; break; }
    const parent = path.dirname(d);
    if (!parent || parent === d) { stopped = 'filesystem-root'; break; }
    try {
      if (fs.existsSync(path.join(d, '.claude'))) {
        return { root: d, source: 'claude-walk', stoppedBy: null };
      }
    } catch (e) { /* an unreadable rung is not an accept; fall through to the .git test */ }
    try {
      if (fs.existsSync(path.join(d, '.git'))) { stopped = 'git-root'; break; }
    } catch (e) { /* likewise */ }
    d = parent;
    depth = depth + 1;
  }
  if (cwd) return { root: cwd, source: 'cwd', stoppedBy: stopped };
  return { root: null, source: 'none', stoppedBy: stopped };
}

const rootInfo = findRootLoose();
let root = rootInfo.root;
if (!root) root = '.';

// --- marker and run type (phaneslight.md: "The .claude/.phaneslight marker file is the SOLE
// --- authority on install state"; the anomaly rule is applied by the SESSION, this only
// --- reports it)
//
// Three states, three answers: markerReadable false means could-not-observe and is never
// conflated with an absent marker. An ACL-denied or otherwise unreadable marker on a fully
// installed project would otherwise report the SAME verdict an absent marker reports, which the
// session acts on by running setup again.
let marker = null;
let markerReadable = true;
const markerPath = path.join(root, '.claude', '.phaneslight');
const mk = readTextFile(markerPath);
if (mk.status === 'ok') { marker = String(mk.text).trim(); }
else if (mk.status !== 'absent') {
  markerReadable = false;
  process.stderr.write('preflight: the .claude/.phaneslight marker exists but could not be read; install state is UNKNOWN, not fresh\n');
}

// LEGACY-NAME-BLOCK BEGIN
// A pre-v3.6.0 install carries its marker under the old name. Read it as the marker rather than
// inventing a fourth runType: the existing "marker is not null" branch below then resolves this
// to 'update', which is what it is, and 'anomaly' becomes unreachable for a healthy legacy
// install. Nothing downstream needs to learn a new value.
let legacyNaming = false;
if (marker === null && mk.status !== 'unreadable') {
  const legacyMarker = readTextFile(path.join(root, '.claude', '.phanes'));
  if (legacyMarker.status === 'ok') {
    marker = String(legacyMarker.text).trim();
    legacyNaming = true;
  } else if (fs.existsSync(path.join(root, '.phanes', 'config.json'))) {
    legacyNaming = true;
  }
}
// LEGACY-NAME-BLOCK END

// --- installed version from .phaneslight/config.json (guarded; malformed reads as null, and the
// --- three failure states stay distinct for the same reason the marker's do)
let cfg = null;
let installedVersion = null;
let docRoot = 'documentation';
let configReadable = true;
const cfgRead = readJsonFile(path.join(root, '.phaneslight', 'config.json'));
if (cfgRead.status === 'ok') { cfg = cfgRead.value; }
else if (cfgRead.status !== 'absent') { configReadable = false; }
if (cfg !== null) {
  if (typeof cfg.phanesLightVersion === 'string') { installedVersion = cfg.phanesLightVersion; }
  if (typeof cfg.docRoot === 'string' && String(cfg.docRoot).trim() !== '') {
    let dr = String(cfg.docRoot).trim();
    // TrimEnd('/', '\\') on the Windows side: both separators, repeatedly. A trailing separator
    // left on docRoot leaks a doubled separator into the anomaly probe below.
    while (dr.length > 0) {
      const last = dr.charAt(dr.length - 1);
      if (last !== '/' && last !== '\\') break;
      dr = dr.slice(0, -1);
    }
    docRoot = dr;
  }
}

// LEGACY-NAME-BLOCK BEGIN
if (installedVersion === null && legacyNaming) {
  try {
    // The Windows sibling reads this with Get-Content -Encoding utf8, which strips a BOM.
    // readFileSync does not, and a BOM in front of "{" is not valid JSON, so it is stripped
    // here for the same reason readJsonFile in the shared block strips it.
    const lraw = fs.readFileSync(path.join(root, '.phanes', 'config.json'), 'utf8');
    const lcfg = JSON.parse(lraw.charCodeAt(0) === 0xfeff ? lraw.slice(1) : lraw);
    if (lcfg && typeof lcfg.phanesVersion === 'string') { installedVersion = lcfg.phanesVersion; }
  } catch (e) { /* a legacy config that cannot be read simply leaves the version null */ }
}
// LEGACY-NAME-BLOCK END

// runType is decided from the marker, which is the spec's sole authority, and the anomaly branch
// exists for the partial-bootstrap case: marker absent but project furniture present. The branch
// requires the furniture to be present AND the marker to be genuinely absent rather than merely
// unread, because after a successful full-chain install .phaneslight always exists and a healthy
// fresh install would otherwise report 'anomaly'.
let runType = 'setup';
if (!markerReadable) { runType = 'unknown'; }
else if (marker !== null) { runType = 'update'; }
else if (fs.existsSync(path.join(root, '.phaneslight', 'config.json')) ||
         fs.existsSync(path.join(root, docRoot, 'session-summaries'))) { runType = 'anomaly'; }

// --- upstream stamp (network-tolerant: single attempt, 10 second timeout, sanity-checked;
// --- every failure shape degrades to null, never to a stop), matching the windows sibling.
const UPSTREAM_TIMEOUT_MS = 10000;
let upstream = null;
{
  const upstreamUrl = 'https://raw.githubusercontent.com/Aloim/phaneslight/main/phaneslight.md';
  const tmp = path.join(os.tmpdir(), 'phaneslight-upstream-' + process.pid + '-' + Date.now() + '.md');
  let fetchFailed = false;
  try {
    const prog = [
      "var https=require('https'),fs=require('fs');",
      "var out=process.argv[1],url=process.argv[2];",
      "var req=https.get(url,function(res){",
      "  if(res.statusCode!==200){res.resume();process.exit(1);return;}",
      "  var ws=fs.createWriteStream(out);",
      "  ws.on('error',function(){process.exit(1);});",
      "  ws.on('finish',function(){process.exit(0);});",
      "  res.on('error',function(){process.exit(1);});",
      "  res.pipe(ws);",
      "});",
      "req.on('error',function(){process.exit(1);});",
      "req.setTimeout(" + UPSTREAM_TIMEOUT_MS + ",function(){req.destroy();process.exit(1);});"
    ].join('\n');
    const r = runChild(process.execPath, ['-e', prog, tmp, upstreamUrl], { timeoutMs: UPSTREAM_TIMEOUT_MS + 5000 });
    if (!r.available || r.code !== 0) {
      fetchFailed = true;
    } else {
      const raw = fs.readFileSync(tmp, 'utf8');
      const clean = raw.charCodeAt(0) === 0xfeff ? raw.slice(1) : raw;
      const line1 = String(clean.split(/\r\n|\n|\r/)[0]);
      if (line1.indexOf('<!-- PhanesLight v') === 0) {
        const m = /PhanesLight v(\d+\.\d+(?:\.\d+)?)/.exec(line1);
        if (m) upstream = m[1];
      }
    }
  } catch (e) {
    fetchFailed = true;
  } finally {
    try { if (fs.existsSync(tmp)) fs.unlinkSync(tmp); } catch (e) { /* best effort cleanup */ }
  }
  if (fetchFailed) {
    upstream = null;
    process.stderr.write('preflight: upstream stamp fetch failed (offline, rate-limited, or unreachable); upstream reported as null\n');
  }
}

// --- the four standard MCP servers via `claude mcp list`
//
// The B5 rule, carried over intact: the EXIT CODE, and never the presence of stderr text,
// decides whether the listing is usable. A tool that chatters on stderr and exits 0 succeeded,
// and node and npx deprecation notices on an npx-launched CLI are a live case, not a
// hypothetical. A failed or unlaunchable listing degrades all four fields to null and NEVER to
// false: an empty result from a FAILED call is not an authoritative empty set.
const mcpRun = runChild('claude', ['mcp', 'list']);
let mcpLines = null;
if (mcpRun.available && mcpRun.code === 0) {
  mcpLines = [];
  const raw = String(mcpRun.stdout).split('\n');
  for (let i = 0; i < raw.length; i++) {
    // A CR survives split on a child that emits CRLF. Strip it so the trailing field of a line
    // is the same string it is on a child that emits LF.
    const ln = raw[i].replace(/\r$/, '');
    if (ln.indexOf(': ') >= 0) mcpLines.push(ln);
  }
}
const mcp = { context7: null, deepwiki: null, serena: null, semble: null };
let mcpServerCount = null;
if (mcpLines !== null) {
  const names = [];
  for (let i = 0; i < mcpLines.length; i++) {
    const j = mcpLines[i].indexOf(': ');
    if (j > 0) names.push(mcpLines[i].slice(0, j));
  }
  mcpServerCount = names.length;
  const keys = ['context7', 'deepwiki', 'serena', 'semble'];
  for (let i = 0; i < keys.length; i++) {
    let found = false;
    for (let n = 0; n < names.length; n++) {
      // OrdinalIgnoreCase substring test. toLowerCase, not toLocaleLowerCase: the latter maps
      // I to a dotless i under tr-TR and would stop matching a server whose name carries one.
      if (names[n].toLowerCase().indexOf(keys[i]) >= 0) { found = true; break; }
    }
    mcp[keys[i]] = found;
  }
} else {
  process.stderr.write('preflight: `claude mcp list` unavailable or failed; mcp fields reported as null, not false\n');
}

// --- census counts, disk-visible surfaces only (auth probing stays in the session)
//
// Both counters returned 0 on an unreadable directory in the draft, and 0 is an authoritative
// number: "this project has no project commands" is a different claim from "I could not look".
// null is the could-not-observe value throughout this script, so the counters use it too, and
// every unreadable surface is NAMED on stderr and in censusUnreadable rather than silently
// flattened. An absent directory is a real 0; an unreadable one is null. They never collapse.
const censusUnreadable = [];
function countFiles(dir, suffix) {
  if (!fs.existsSync(dir)) return 0;
  try {
    const ents = fs.readdirSync(dir, { withFileTypes: true });
    let n = 0;
    for (let i = 0; i < ents.length; i++) {
      const nm = ents[i].name;
      if (nm.length < suffix.length || nm.slice(nm.length - suffix.length) !== suffix) continue;
      if (ents[i].isFile()) n++;
    }
    return n;
  } catch (e) {
    censusUnreadable.push(dir);
    process.stderr.write('preflight: cannot enumerate ' + dir + '; reported as null, not 0\n');
    return null;
  }
}
function countDirs(dir) {
  if (!fs.existsSync(dir)) return 0;
  try {
    const ents = fs.readdirSync(dir, { withFileTypes: true });
    let n = 0;
    for (let i = 0; i < ents.length; i++) { if (ents[i].isDirectory()) n++; }
    return n;
  } catch (e) {
    censusUnreadable.push(dir);
    process.stderr.write('preflight: cannot enumerate ' + dir + '; reported as null, not 0\n');
    return null;
  }
}

// homeDir() returns null rather than throwing when HOME is unset and os.homedir() cannot answer.
// A null home degrades the two user-scoped counts to could-not-observe, which is the honest
// answer and the same shape the unreadable-directory case uses.
const userHome = homeDir();
let userClaude = null;
if (userHome) userClaude = path.join(userHome, '.claude');

let agentFiles = [];
let agentsUnreadable = false;
const agentsDir = path.join(root, '.claude', 'agents');
if (fs.existsSync(agentsDir)) {
  try {
    const ents = fs.readdirSync(agentsDir, { withFileTypes: true });
    for (let i = 0; i < ents.length; i++) {
      if (ents[i].isFile() && ents[i].name.slice(-3) === '.md') agentFiles.push(ents[i].name);
    }
  } catch (e) {
    censusUnreadable.push(agentsDir);
    process.stderr.write('preflight: cannot enumerate ' + agentsDir + '; reported as null, not 0\n');
    agentsUnreadable = true;
    agentFiles = [];
  }
}

let pluginCount = null;
let pluginsJson = null;
if (userClaude) pluginsJson = path.join(userClaude, 'plugins', 'installed_plugins.json');
if (pluginsJson && fs.existsSync(pluginsJson)) {
  pluginCount = 0;
  try {
    const raw = fs.readFileSync(pluginsJson, 'utf8');
    const pj = JSON.parse(raw.charCodeAt(0) === 0xfeff ? raw.slice(1) : raw);
    const plugins = pj ? pj.plugins : null;
    if (plugins && typeof plugins === 'object' && !Array.isArray(plugins)) {
      const pkeys = Object.keys(plugins);
      for (let i = 0; i < pkeys.length; i++) {
        const v = plugins[pkeys[i]];
        const insts = Array.isArray(v) ? v : [v];
        for (let k = 0; k < insts.length; k++) {
          const inst = insts[k];
          if (!inst || typeof inst !== 'object') continue;
          // Ordinal, case-sensitive, on both the scope literal and the project path. The Windows
          // sibling compares projectPath OrdinalIgnoreCase under its NTFS exception; POSIX paths
          // are case-sensitive and two paths differing only in case are two different projects.
          const scopeOk = inst.scope === 'user' ||
            (inst.scope === 'project' && typeof inst.projectPath === 'string' && inst.projectPath === root);
          if (scopeOk) { pluginCount++; break; }
        }
      }
    }
  } catch (e) {
    pluginCount = null;
    process.stderr.write('preflight: cannot read ' + pluginsJson + '; plugins reported as null, not 0\n');
  }
} else if (userClaude) {
  pluginCount = 0;
}

// The evaluation ORDER of these counters is the order censusUnreadable is filled in, and the
// Windows sibling fills it the same way because its ordered hashtable evaluates in source order.
// Keep them in this order.
const censusCounts = {
  agents: agentsUnreadable ? null : agentFiles.length,
  commandsProject: countFiles(path.join(root, '.claude', 'commands'), '.md'),
  commandsUser: userClaude ? countFiles(path.join(userClaude, 'commands'), '.md') : null,
  plugins: pluginCount,
  skillsProject: countDirs(path.join(root, '.claude', 'skills')),
  skillsUser: userClaude ? countDirs(path.join(userClaude, 'skills')) : null,
  mcpServers: mcpServerCount
};

// --- legacy-migration signals (phaneslight.md: "no phanesLightVersion in
// --- .phaneslight/config.json and no version stamp anywhere; agents referencing
// --- sequential-thinking or an MCP memory server; ... per-subfolder CLAUDE.md sprawl;
// --- ... unprefixed template-shaped agents"). Signals only; the
// --- STOP-and-route-to-phaneslightupgrade judgment stays in the session.
const archetypes = ['executor', 'critic', 'planner', 'architect', 'designer', 'cleaner',
  'synthesizer', 'close-verifier', 'scout', 'orchestrator', 'researcher', 'patch-author'];
const unprefixed = [];
const seqRefs = [];
for (let i = 0; i < agentFiles.length; i++) {
  const nm = agentFiles[i];
  const ext = path.extname(nm);
  const stem = ext ? nm.slice(0, nm.length - ext.length) : nm;
  for (let a = 0; a < archetypes.length; a++) {
    if (stem === archetypes[a]) { unprefixed.push(nm); break; }
  }
  try {
    const txt = fs.readFileSync(path.join(agentsDir, nm), 'utf8');
    const head = txt.split(/\r\n|\n|\r/).slice(0, 60).join('\n');
    if (head.toLowerCase().indexOf('sequential-thinking') >= 0) seqRefs.push(nm);
  } catch (e) { /* an agent head that cannot be read raises no signal, as on Windows */ }
}

// Per-subfolder CLAUDE.md sprawl. Depth 3 has the Get-ChildItem meaning, measured rather than
// assumed on 2026-09-04: -Recurse -Depth 3 reaches files three directory levels below the root
// and no deeper, and the root's own CLAUDE.md is then excluded by the DirectoryName test.
// An unreadable rung used to be skipped in silence, which made this counter do exactly what
// the agents counter did before c1f8b6a: report a smaller number instead of an unknown one.
// It matters for the same reason. subfolderClaudeMdCount is one of the legacy-migration
// signals the session weighs when it decides whether to STOP and route to PhanesLightUpgrade,
// so a project whose sprawl sits inside a denied subtree could be told it has less of it than
// it has, and the run would act on that. The walk still continues past a denied rung, because
// naming every denied directory is more useful than stopping at the first, but the COUNT it
// produces is discarded: a null count is not a zero.
let claudeMdSprawl = null;
const sprawlDenied = [];
try {
  let n = 0;
  const walk = function (dir, depth) {
    let ents;
    try { ents = fs.readdirSync(dir, { withFileTypes: true }); }
    catch (e) { sprawlDenied.push(dir); return; }
    for (let i = 0; i < ents.length; i++) {
      const e = ents[i];
      if (e.isDirectory()) {
        if (depth < 3) walk(path.join(dir, e.name), depth + 1);
      } else if (e.isFile() && e.name === 'CLAUDE.md' && dir !== root) {
        n++;
      }
    }
  };
  walk(root, 0);
  claudeMdSprawl = n;
} catch (e) { claudeMdSprawl = null; }
// The sprawl walk covers the whole project to depth 3, so it also descends through
// .claude/agents and would name a denied agents directory a SECOND time. Reporting the same
// path twice makes censusUnreadable read like two separate findings, so an entry already
// recorded by an earlier counter is skipped here rather than repeated.
if (sprawlDenied.length) {
  sprawlDenied.sort();
  for (let i = 0; i < sprawlDenied.length; i++) {
    if (censusUnreadable.indexOf(sprawlDenied[i]) !== -1) continue;
    censusUnreadable.push(sprawlDenied[i]);
    process.stderr.write('preflight: cannot enumerate ' + sprawlDenied[i] + '; reported as null, not 0\n');
  }
  claudeMdSprawl = null;
}

// StringComparer.Ordinal on the Windows side; the default Array sort compares UTF-16 code units,
// which is the same order.
const unprefixedArr = unprefixed.slice().sort();
const seqArr = seqRefs.slice().sort();

// Exact counts AND a listTruncated flag beside the capped lists: a consumer must be able to tell
// 20 legacy agents from 25 or from 200, on the signals that feed the legacy-migration STOP
// judgment.
const legacyMarkers = {
  noVersionStamp: (runType !== 'setup') && (installedVersion === null),
  unprefixedTemplateAgents: unprefixedArr.slice(0, CAP),
  unprefixedTemplateAgentsCount: agentsUnreadable ? null : unprefixedArr.length,
  sequentialThinkingAgents: seqArr.slice(0, CAP),
  sequentialThinkingAgentsCount: agentsUnreadable ? null : seqArr.length,
  subfolderClaudeMdCount: claudeMdSprawl,
  listTruncated: agentsUnreadable ? false : ((unprefixedArr.length > CAP) || (seqArr.length > CAP))
};

const digest = {
  runType: runType,
  marker: marker,
  legacyNaming: legacyNaming,
  markerReadable: markerReadable,
  configReadable: configReadable,
  rootSource: rootInfo.source,
  installedVersion: installedVersion,
  upstream: upstream,
  mcp: mcp,
  platform: 'posix',
  censusCounts: censusCounts,
  censusUnreadable: censusUnreadable,
  legacyMarkers: legacyMarkers
};
emitJson(digest);
process.exitCode = 0;
