#!/bin/sh
# phaneslight-template v3.8.0 ledger
# Run-progress ledger mechanics (Phase 0 Compaction Survival made mechanical). Subcommands:
#   ledger append "<line>"  appends one caller-composed line (the caller owns the format;
#                           this script only writes; an argument containing CR or LF is
#                           refused, the ledger is line-oriented)
#   ledger status           prints CLOSED / OPEN <last line> / ABSENT / UNREADABLE
#   ledger close            appends the terminator line "CLOSED, run complete" (idempotent)
#   ledger reset            archives the ledger to run-progress.prev (one generation kept)
#                           and starts fresh (the mechanical arm of the consented fresh-run
#                           choice; the CONSENT stays in the session, decision B6)
# Advisory: always exits 0.
#
# Subcommand matching is case-sensitive on purpose (LG-2): `ledger RESET` must fall to the
# usage line below, not run the one subcommand here that destroys state. POSIX `case` is
# ordinal and case-sensitive by construction, which gives this for free with no extra guard,
# unlike the Windows form which needed an explicit -casesensitive switch.
TERMINATOR='CLOSED, run complete'

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

# Whole-string whitespace trim, POSIX's twin of [string]::Trim(). Deliberately built from
# shell parameter-expansion character stripping rather than `sed`/`awk`: the argument being
# trimmed here is a caller-supplied ledger line that is checked for embedded CR/LF a few lines
# below, so the trim itself must survive an embedded newline mid-string rather than treating it
# as a record separator the way a line-oriented tool would. `${v#?}` / `${v%?}` remove exactly
# one character regardless of what that character is. Known narrower than .NET's Trim(), which
# also strips a handful of Unicode whitespace code points this strips only space/tab/CR/LF for;
# the ledger's own callers write ASCII phase lines, so this is not expected to matter.
CR=$(printf '\r')
TAB=$(printf '\t')
NL='
'
trim_ws() {
  v=$1
  while true; do
    case "$v" in
      ' '*|"$TAB"*|"$CR"*|"$NL"*) v=${v#?} ;;
      *) break ;;
    esac
  done
  while true; do
    case "$v" in
      *' '|*"$TAB"|*"$CR"|*"$NL") v=${v%?} ;;
      *) break ;;
    esac
  done
  printf '%s' "$v"
}

# compute_ledger_state -> sets ledger_readable (1 true / 0 false) and ledger_last (the last
# non-blank line, or empty meaning null) from $LEDGER_FILE. The POSIX twin of Get-LedgerState.
# LG-3: 'absent' reads as Readable=true, Last=null (a fresh project, nothing wrong); anything
# other than 'absent' or 'ok' (i.e. 'unreadable') reads as Readable=false, and every caller
# below branches on that BEFORE acting, so a ledger that exists but cannot be read never gets
# treated as the fresh-project case.
compute_ledger_state() {
  lg_st=$(read_text_state "$LEDGER_FILE")
  case "$lg_st" in
    absent) ledger_readable=1; ledger_last='' ;;
    ok) ledger_readable=1; ledger_last=$(last_nonblank_line "$LEDGER_FILE") ;;
    *) ledger_readable=0; ledger_last='' ;;
  esac
}

root=$(find_root) || {
  echo 'ledger: .phaneslight/config.json not found from this directory' >&2
  exit 0
}

PHANESLIGHT_DIR="$root/.phaneslight"
LEDGER_FILE="$PHANESLIGHT_DIR/run-progress"
PREV_FILE="$PHANESLIGHT_DIR/run-progress.prev"

sub=$1
[ $# -gt 0 ] && shift

case "$sub" in
  append)
    line=$1
    trimmed=$(trim_ws "$line")
    if [ -z "$trimmed" ]; then
      echo 'ledger: append requires one non-empty line argument; nothing written' >&2
      exit 0
    fi
    case "$line" in
      *"$CR"*|*"$NL"*)
        echo 'ledger: append argument contains a line break; the ledger is line-oriented, nothing written' >&2
        exit 0
        ;;
    esac
    mkdir -p "$PHANESLIGHT_DIR" 2>/dev/null
    if append_lf "$line" "$LEDGER_FILE" 2>/dev/null; then
      :
    else
      echo "ledger: cannot write $LEDGER_FILE" >&2
    fi
    exit 0
    ;;
  status)
    compute_ledger_state
    if [ "$ledger_readable" = 0 ]; then
      printf '%s\n' 'UNREADABLE'
    elif [ -z "$ledger_last" ]; then
      printf '%s\n' 'ABSENT'
    elif [ "$ledger_last" = "$TERMINATOR" ]; then
      printf '%s\n' 'CLOSED'
    else
      printf 'OPEN %s\n' "$ledger_last"
    fi
    exit 0
    ;;
  close)
    compute_ledger_state
    # LG-1 repair: refuse to append to a ledger whose state could not be read, rather than
    # falling through to the append blind. Appending blind is the one thing a writer must not
    # do when its read failed; doing so would write a SECOND terminator and break the
    # documented idempotency of this subcommand on a file this run never actually saw.
    if [ "$ledger_readable" = 0 ]; then
      echo 'ledger: run-progress exists but cannot be read; nothing appended' >&2
      exit 0
    fi
    if [ -n "$ledger_last" ] && [ "$ledger_last" = "$TERMINATOR" ]; then
      exit 0
    fi
    mkdir -p "$PHANESLIGHT_DIR" 2>/dev/null
    if append_lf "$TERMINATOR" "$LEDGER_FILE" 2>/dev/null; then
      :
    else
      echo "ledger: cannot write $LEDGER_FILE" >&2
    fi
    exit 0
    ;;
  reset)
    # Existence, not readability: a directory sitting where the ledger belongs still counts as
    # something to reset (matches Test-Path, which is true for a directory too); it is the mv
    # below that decides whether the archive actually succeeds.
    if [ ! -e "$LEDGER_FILE" ]; then
      echo 'ledger: no run-progress ledger to reset' >&2
      exit 0
    fi
    if mv -f "$LEDGER_FILE" "$PREV_FILE" 2>/dev/null && printf '' > "$LEDGER_FILE" 2>/dev/null; then
      printf '%s\n' 'ledger: archived to run-progress.prev, fresh ledger started'
    else
      echo 'ledger: reset failed, ledger left as it was' >&2
    fi
    exit 0
    ;;
  *)
    echo 'ledger: usage: ledger append "<line>" | ledger status | ledger close | ledger reset' >&2
    exit 0
    ;;
esac
