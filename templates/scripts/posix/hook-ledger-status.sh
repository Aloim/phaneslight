#!/bin/sh
# phaneslight-template v3.8.0 hook-ledger-status
# SessionStart hook. Prints NOTHING when the run-progress ledger is closed or absent; prints
# exactly one line when a prior run died mid-flight, so the session opens knowing it must ask
# the user: resume, or start fresh (ledger reset). The ASKING stays in the session; this hook
# only surfaces the state. Run by hand with terminal stdin it exits 0 at once, never blocking.
# Always exits 0: unlike the PowerShell original there is no ErrorActionPreference to set, so
# the contract is kept the POSIX way instead, no `set -e` anywhere and every branch below ends
# in an explicit `exit 0` rather than relying on a caught exception.
TERMINATOR='CLOSED, run complete'

# The longest ledger line this hook will surface. HK-3 repair: the draft echoed the last line
# whatever its length, and a 300 KB line went straight into session-start context, which is the
# most expensive place in the whole system to put unbounded text. The cap is generous enough
# that a real phase line (date, phase, TODOs) is never touched.
MAX_LINE=300

# BEGIN SHARED posix-core

find_root() {
  d=$(pwd)
  while [ -n "$d" ] && [ "$d" != "/" ]; do
    [ -f "$d/.phaneslight/config.json" ] && { printf '%s' "$d"; return 0; }
    d=$(dirname "$d")
  done
  [ -f "/.phaneslight/config.json" ] && { printf '%s' "/"; return 0; }
  return 1
}

cfg_str() { # cfg_str KEY FILE
  grep -o "\"$1\"[[:space:]]*:[[:space:]]*\"[^\"]*\"" "$2" 2>/dev/null | head -1 \
    | sed 's/.*:[[:space:]]*"\(.*\)"$/\1/'
}

cfg_arr() { # cfg_arr KEY FILE -> newline-separated values
  tr '\n' ' ' < "$2" 2>/dev/null \
    | sed -n "s/.*\"$1\"[[:space:]]*:[[:space:]]*\[\([^]]*\)\].*/\1/p" \
    | grep -o '"[^"]*"' | sed 's/"//g'
}

# cfg_key_bad KEY FILE -> true when KEY is present in the file but the extractors above cannot
# read its value. That combination is the signature of a malformed config. POSIX has no JSON
# parser (the helpers are regex extractors, which cannot fail), so an unreadable config would
# otherwise be indistinguishable from an unset key and would silently degrade to a default.
# An absent key is NOT bad: defaults are honest when the user simply did not set the option.
cfg_key_bad() {
  flat=$(tr '\n' ' ' < "$2" 2>/dev/null)
  printf '%s' "$flat" | grep -q "\"$1\"[[:space:]]*:" || return 1
  # Objects, numbers, booleans and null are well-formed JSON these extractors cannot read.
  # Unreadable is not the same as broken: leave those to the caller's default.
  printf '%s' "$flat" | grep -q "\"$1\"[[:space:]]*:[[:space:]]*[{0-9tfn-]" && return 1
  [ -n "$(cfg_str "$1" "$2")" ] && return 1
  [ -n "$(cfg_arr "$1" "$2")" ] && return 1
  printf '%s' "$flat" | grep -q "\"$1\"[[:space:]]*:[[:space:]]*\[[[:space:]]*\]" && return 1
  printf '%s' "$flat" | grep -q "\"$1\"[[:space:]]*:[[:space:]]*\"\"" && return 1
  return 0
}

normalize_path() { # normalize_path PATH -> lexically-normalized path (no filesystem access;
  # purely textual '.'/'..' collapsing, mirroring .NET's GetFullPath so a non-existent
  # target -- or one crossing a nonexistent directory -- can still be checked for
  # containment before anything is created on disk).
  set -f
  IFS=/; set -- $1; unset IFS
  set +f
  out=
  for seg in "$@"; do
    case "$seg" in
      ""|.) : ;;
      ..) out=${out%/*} ;;
      *) out="$out/$seg" ;;
    esac
  done
  [ -n "$out" ] && printf '%s' "$out" || printf '/'
}

# path_contained ROOT TARGET -> 0 when TARGET is inside ROOT, or is ROOT itself.
# The POSIX twin of Test-PhanesLightContained. Two differences from the Windows form and both
# are deliberate. Comparison is ORDINAL, case-sensitive, because POSIX paths are: folding case
# here would call two genuinely different directories the same one. And the trailing separator
# forced onto the root is load-bearing exactly as it is on Windows: without it "/proj-evil"
# passes a prefix test against "/proj".
path_contained() {
  [ -n "$1" ] && [ -n "$2" ] || return 1
  pc_r=$(normalize_path "$1")
  pc_t=$(normalize_path "$2")
  [ "$pc_t" = "$pc_r" ] && return 0
  case "$pc_r" in */) : ;; *) pc_r="$pc_r/" ;; esac
  case "$pc_t" in "$pc_r"*) return 0 ;; esac
  return 1
}

# read_text_state PATH -> prints exactly one of: absent, unreadable, ok.
# The three-state read every ledger consumer branches on BEFORE acting, and the POSIX twin of
# Read-PhanesLightTextFile. 'absent' and 'unreadable' are DIFFERENT ANSWERS: 'absent' is the
# fresh-project answer and acting on it archives or overwrites a run whose state was never
# seen. A directory sitting where a file belongs is 'unreadable', not 'absent'; that case is
# not hypothetical, it read as ABSENT in the Windows draft and is the reason this helper exists
# instead of a bare [ -f ] test.
read_text_state() {
  [ -e "$1" ] || { [ -L "$1" ] && { printf 'unreadable'; return 0; }; printf 'absent'; return 0; }
  [ -d "$1" ] && { printf 'unreadable'; return 0; }
  [ -f "$1" ] || { printf 'unreadable'; return 0; }
  [ -r "$1" ] || { printf 'unreadable'; return 0; }
  printf 'ok'
}

# last_nonblank_line FILE -> the last line with a non-whitespace character, CR stripped.
# CRLF tolerance is required, not optional: the ledger is written LF by these scripts and CRLF
# by anything a Windows editor has touched, and a trailing CR would otherwise make every
# comparison against a literal marker fail.
last_nonblank_line() {
  awk '{ sub(/\r$/, ""); if ($0 ~ /[^ \t]/) last = $0 } END { if (last != "") print last }' "$1" 2>/dev/null
}

# write_lf TEXT FILE -> writes TEXT plus one LF, no BOM, no CR, truncating FILE.
# printf and never echo: echo's handling of a leading -n, of backslashes, and of an argument
# that begins with a dash is implementation-defined across the shells this has to run under,
# and the ledger's content is user text.
write_lf() {
  printf '%s\n' "$1" > "$2"
}

# append_lf TEXT FILE -> the same, appending.
append_lf() {
  printf '%s\n' "$1" >> "$2"
}

# END SHARED posix-core

# Run by hand instead of by the harness (stdin is a console, no hook JSON is coming): exit
# cleanly rather than blocking forever on a read that never returns.
[ -t 0 ] && exit 0
# Drain the SessionStart payload; this hook decides from disk state, not from the payload.
raw=$(cat 2>/dev/null)

root=$(find_root) || exit 0
ledger="$root/.phaneslight/run-progress"

# HK-2 repair, ported. A ledger that EXISTS but cannot be read (a directory in its place, a
# denied permission) must never read the same as a healthy, absent project: that silence is
# the false-healthy signal on exactly the state this hook exists to surface. read_text_state
# gives the three-state answer this branches on; 'unreadable' is reported, in one line, like
# every other thing this hook has to say. It never collapses into 'absent'.
state=$(read_text_state "$ledger")
if [ "$state" = "absent" ]; then
  exit 0
fi
if [ "$state" != "ok" ]; then
  printf '%s\n' 'phaneslight: a run-progress ledger exists but could not be read, so it is unknown whether a prior run finished. Ask the user before starting work.'
  exit 0
fi

# last_nonblank_line only strips a trailing CR and skips whitespace-only lines; the PowerShell
# original additionally Trims() the surviving line before using it (both for the length check
# and for the TERMINATOR compare), so the trim is finished here, outside the shared block.
last=$(last_nonblank_line "$ledger")
[ -n "$last" ] || exit 0
last=$(printf '%s' "$last" | sed 's/^[[:space:]]*//; s/[[:space:]]*$//')
[ -n "$last" ] || exit 0
if [ "$last" = "$TERMINATOR" ]; then
  exit 0
fi

# Character count, not byte count, mirrors .NET's String.Length for the ASCII and BMP text a
# ledger phase line is made of; ${#last} is POSIX-standard and dash on this codebase's toolchain
# resolves it against the environment's UTF-8 locale. The cut below that performs the actual
# slice is NOT locale-aware on this toolchain (verified: it slices by byte, not by code point),
# so a truncated line containing multi-byte UTF-8 past the cap is a declared divergence from the
# PowerShell original, exactly as A5 of the v3.7.2 plan declares others; it does not corrupt an
# ASCII phase line, which is what every real ledger entry is.
llen=${#last}
if [ "$llen" -gt "$MAX_LINE" ]; then
  last=$(printf '%s' "$last" | cut -c1-"$MAX_LINE")
  last="$last [line truncated]"
fi

# Run type from the marker: '0' = a setup run died; any other value, or a read that fails for
# any reason (permission, a directory in the marker's place), = an update run died; a MISSING
# marker beside an existing ledger is the phaneslight.md anomaly case and is treated as an
# update, matching the spec's own rule. The default below is that rule; nothing here overrides
# it except an exact, trimmed '0'.
runType=update
marker="$root/.claude/.phaneslight"
if [ -f "$marker" ]; then
  mval=$(cat "$marker" 2>/dev/null)
  mval=$(printf '%s' "$mval" | sed 's/^[[:space:]]*//; s/[[:space:]]*$//')
  if [ "$mval" = "0" ]; then
    runType=setup
  fi
fi

printf 'phaneslight: unfinished %s run found, last completed: %s. Ask the user: resume from the next phase, or start fresh (ledger reset)?\n' "$runType" "$last"
exit 0
