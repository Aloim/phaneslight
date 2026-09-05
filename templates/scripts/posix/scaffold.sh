#!/bin/sh
# phaneslight-template v3.8.0 scaffold
# Mechanizes Phase 2.5 Steps 1, 1b, and 2: creates the documentation tree (under the
# configured docRoot), the tests tree, and the four verbatim README files, reading the README
# bodies from the installed prompt templates (.claude/template/readme-docs.md and
# readme-tests.md, SECTION blocks). Merge-never-overwrite: an EXISTING file or folder is never
# touched, only absent ones are created, and every creation is listed on stdout. CLAUDE.md and
# CLAUDE.local.md are deliberately NOT scaffold's to create: their blocks carry per-project
# judgment (Pinned Directives, capability register) and the session remains their writer.
# NOT advisory: exit 0 on success (including "nothing to do"); exit 1 when the project, config,
# or a required template cannot be read, or when a write fails (the session then falls back to
# writing the Step 1/1b/2 content from phaneslight.md directly). On a write failure the items already
# created ARE listed before the error: "nothing created" is achievable for every pre-write
# refusal and is NOT achievable once the eighth of nineteen writes fails, so the contract states
# what the script can actually guarantee rather than a promise it would break in silence.
#
# POSIX port notes. Each is a place where the Windows original leans on something sh does not
# have, and each is a deliberate decision rather than an omission:
#   1. Config malformation. Windows parses .phaneslight/config.json with ConvertFrom-Json and
#      refuses any malformation anywhere in the file. POSIX has no JSON parser, so the shared
#      cfg_key_bad gate is applied to docRoot, the single key this script consumes: present but
#      unreadable is a refusal, genuinely absent is the honest 'documentation' default.
#      Malformation in a region docRoot never touches still degrades to that default here. That
#      residual gap is the platform divergence the run skill records, not an oversight.
#   2. No BOM, by construction. Section bodies are written with printf, which emits those bytes
#      and nothing else, so the UTF8Encoding($false) the Windows script builds has no twin.
#   3. Get-Content hands the parser lines with the line terminator already removed, CR included.
#      The parser below therefore strips one trailing CR per line, so that a CRLF-damaged
#      template still produces byte-identical LF README bodies on both platforms.
#   4. IsPathRooted has no POSIX twin. A leading '/' is the POSIX definition of rooted. A
#      leading backslash and a drive-qualified prefix are refused with the SAME message even
#      though POSIX would read them as ordinary relative names, because letting them through
#      would silently create a directory literally named 'C:\docs' where Windows refuses.
#   5. Sections are held in shell variables named SEC_<file>_<section>, with '-' mapped to '_'.
#      That mapping is injective because a validated section name cannot contain '_' (see D5),
#      and shell variable names are case-sensitive, which is what makes the Ordinal lookup the
#      Windows side gets from New-OrdinalHashtable reachable here at all (D1).

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

# ------------------------------------------------------------------------------------------
# Small pure-shell primitives. Each exists because forking a process per LINE of a template is
# the difference between a script that runs and one that crawls, and because character-range
# patterns like [A-Za-z] are collation-dependent in a shell case statement while an explicit
# enumeration is not.
CR=$(printf '\r')
TAB=$(printf '\t')
NL='
'

rtrim() { # rtrim STRING -> STRING with trailing space, tab and CR removed (PowerShell TrimEnd)
  rt_s=$1
  while :; do
    case "$rt_s" in
      *' '|*"$TAB"|*"$CR") rt_s=${rt_s%?} ;;
      *) break ;;
    esac
  done
  printf '%s' "$rt_s"
}

sec_name_ok() { # sec_name_ok NAME -> 0 when NAME matches ^[A-Za-z0-9-]+$ (D5)
  sn_s=$1
  [ -n "$sn_s" ] || return 1
  while [ -n "$sn_s" ]; do
    sn_c=${sn_s%"${sn_s#?}"}
    case "$sn_c" in
      [0123456789]|-) : ;;
      [abcdefghijklmnopqrstuvwxyz]) : ;;
      [ABCDEFGHIJKLMNOPQRSTUVWXYZ]) : ;;
      *) return 1 ;;
    esac
    sn_s=${sn_s#?}
  done
  return 0
}

sec_key() { # sec_key NAME -> NAME with '-' mapped to '_', for use in a shell variable name
  sk_s=$1; sk_o=
  while [ -n "$sk_s" ]; do
    sk_c=${sk_s%"${sk_s#?}"}
    case "$sk_c" in '-') sk_o="${sk_o}_" ;; *) sk_o="$sk_o$sk_c" ;; esac
    sk_s=${sk_s#?}
  done
  printf '%s' "$sk_o"
}

sec_has() { # sec_has PREFIX NAME -> 0 when that section was parsed (the ContainsKey twin)
  sh_k=$(sec_key "$2")
  eval "sh_v=\${SEC_${1}_${sh_k}+set}"
  [ "$sh_v" = set ]
}

# ------------------------------------------------------------------------------------------
# SECTION parser for the installed prompt templates. A missing or malformed template is a
# refusal naming the file: the fallback (authoring from the phaneslight.md verbatim blocks) is the
# session's judgment, not this script's.
# The parser was weak in five ways, and every one of them writes WRONG CONTENT at exit 0 rather
# than failing, which merge-never-overwrite then makes permanent: the bad file is never
# corrected on a later run, because a later run sees a file that already exists. That is what
# makes a parser bug here worse than a crash, and why all five refuse instead.
#   D1  section names were looked up case-insensitively, so a damaged template with the wrong
#       casing was silently accepted. Shell variable names are case-sensitive, which is the
#       POSIX form of the Ordinal hashtable the Windows script constructs.
#   D2  duplicate section names silently last-won.
#   D3  an END marker inside a fenced code block closed the section early: observed truncating
#       a body to a 33-byte stub.
#   D4  an empty section produced a 1-byte file.
#   D5  a marker whose name fell outside the [A-Za-z0-9-] charset was not recognized as a
#       marker at all, so the literal marker line shipped verbatim into the README.
# Returns 2 for missing or unreadable (the null of the Windows original), 1 for a parse defect
# with the message in GS_ERR (which the caller turns into a refusal naming the file), 0 on
# success with each body in SEC_<prefix>_<key>.
#
# The loop reads from a redirect and never from a pipe: in a pipeline the loop would run in a
# subshell and every parsed section would be discarded at the closing 'done'. The
# read-or-nonempty tail is not decoration either: a template whose final line carries no
# newline would otherwise lose that line, and Get-Content does not lose it.
GS_ERR=
get_sections() { # get_sections PREFIX PATH
  gs_pre=$1; gs_path=$2
  GS_ERR=
  [ "$(read_text_state "$gs_path")" = ok ] || return 2
  gs_cur=; gs_curkey=; gs_buf=; gs_fenced=0
  while IFS= read -r gs_ln || [ -n "$gs_ln" ]; do
    gs_ln=${gs_ln%"$CR"}
    gs_t=$(rtrim "$gs_ln")
    # D3: track fenced blocks so a marker quoted inside an example cannot close a section.
    gs_tl=$gs_t
    while :; do
      case "$gs_tl" in
        ' '*|"$TAB"*) gs_tl=${gs_tl#?} ;;
        *) break ;;
      esac
    done
    case "$gs_tl" in
      '```'*) if [ "$gs_fenced" = 0 ]; then gs_fenced=1; else gs_fenced=0; fi ;;
    esac
    if [ "$gs_fenced" = 0 ]; then
      gs_ismark=0; gs_name=
      case "$gs_t" in
        '<!-- SECTION '*' -->')
          gs_name=${gs_t#'<!-- SECTION '}
          gs_name=${gs_name%' -->'}
          # The \S+ of the Windows regex: a name carrying whitespace is not a marker at all.
          case "$gs_name" in
            ''|*' '*|*"$TAB"*) gs_name= ;;
            *) gs_ismark=1 ;;
          esac
          ;;
      esac
      if [ "$gs_ismark" = 1 ]; then
        # D5: a marker that looks like a marker but carries an out-of-charset name is a DAMAGED
        # template, not body text. Refusing beats shipping the marker line into a README.
        if ! sec_name_ok "$gs_name"; then
          GS_ERR="SECTION name '$gs_name' contains characters outside [A-Za-z0-9-]"; return 1
        fi
        if [ -n "$gs_cur" ]; then
          GS_ERR="SECTION $gs_name opens while SECTION $gs_cur is still open"; return 1
        fi
        if sec_has "$gs_pre" "$gs_name"; then GS_ERR="duplicate SECTION $gs_name"; return 1; fi
        gs_cur=$gs_name
        gs_curkey=$(sec_key "$gs_name")
        gs_buf=
        continue
      fi
      if [ "$gs_t" = '<!-- END SECTION -->' ]; then
        if [ -z "$gs_cur" ]; then GS_ERR='END SECTION with no open SECTION'; return 1; fi
        # D4: the Windows body is the lines joined with LF plus one trailing LF, so an empty
        # section yields a lone LF there and the empty string here; both are whitespace only
        # and both refuse. tr and not a [[:space:]] case pattern, whose class support is not
        # guaranteed by every sh this has to run under.
        gs_probe=$(printf '%s' "$gs_buf" | tr -d ' \011\012\013\014\015')
        if [ -z "$gs_probe" ]; then GS_ERR="SECTION $gs_cur is empty"; return 1; fi
        eval "SEC_${gs_pre}_${gs_curkey}=\$gs_buf"
        gs_cur=; gs_curkey=
        continue
      fi
    fi
    [ -n "$gs_cur" ] && gs_buf="$gs_buf$gs_ln$NL"
  done < "$gs_path"
  if [ -n "$gs_cur" ]; then GS_ERR="SECTION $gs_cur is never closed"; return 1; fi
  if [ "$gs_fenced" = 1 ]; then GS_ERR='unterminated code fence'; return 1; fi
  return 0
}

read_template() { # read_template PREFIX FILENAME
  get_sections "$1" "$tplDir/$2"; rt_rc=$?
  if [ "$rt_rc" = 1 ]; then
    echo "scaffold: .claude/template/$2 is damaged ($GS_ERR); nothing created. Reinstall templates (phaneslight install-templates) or fall back to the phaneslight.md Step 1/1b/2 blocks" >&2
    exit 1
  fi
  if [ "$rt_rc" = 2 ]; then eval "TPLNULL_$1=1"; else eval "TPLNULL_$1=0"; fi
}

check_template() { # check_template PREFIX FILENAME SECTION...
  ct_pre=$1; ct_file=$2; shift 2
  eval "ct_null=\$TPLNULL_$ct_pre"
  if [ "$ct_null" = 1 ]; then
    echo "scaffold: .claude/template/$ct_file is missing or unreadable; nothing created. Install templates first (phaneslight install-templates) or fall back to the phaneslight.md Step 1/1b/2 blocks" >&2
    exit 1
  fi
  for ct_s in "$@"; do
    if ! sec_has "$ct_pre" "$ct_s"; then
      echo "scaffold: .claude/template/$ct_file lacks SECTION $ct_s; nothing created (template damaged or from another version)" >&2
      exit 1
    fi
  done
}

# ------------------------------------------------------------------------------------------
root=$(find_root) || { echo "scaffold: .phaneslight/config.json not found from this directory" >&2; exit 1; }
cfgFile="$root/.phaneslight/config.json"

# Creating trees in the WRONG place is worse than refusing: an unreadable or malformed config is
# exit 1 here, not a silent default (the docRoot decides where a whole tree lands).
cfgState=$(read_text_state "$cfgFile")
if [ "$cfgState" != ok ]; then
  echo "scaffold: .phaneslight/config.json is $cfgState; nothing created, repair the config first" >&2
  exit 1
fi
# A docRoot whose value is a JSON ARRAY is well-formed JSON that simply is not a string, and the
# Windows -is [string] test then falls through to the 'documentation' default rather than
# refusing. cfg_key_bad cannot see that on its own: its well-formed-but-unreadable escape hatch
# covers objects, numbers, booleans and null, and an array whose elements are not quoted strings
# is the one shape it would otherwise call damaged. Measured, not assumed: a config carrying
# "docRoot": [1, 2] built the whole tree and exited 0 on Windows while this script refused.
# The probe reads the FIRST occurrence only, which is the occurrence cfg_str would read.
cfgFlat=$(tr '\n' ' ' < "$cfgFile" 2>/dev/null)
docRootArray=0
docRootHead=$(printf '%s' "$cfgFlat" | grep -o "\"docRoot\"[[:space:]]*:[[:space:]]*." | head -1)
case "$docRootHead" in *'[') docRootArray=1 ;; esac
if [ "$docRootArray" = 0 ] && cfg_key_bad docRoot "$cfgFile"; then
  echo "scaffold: .phaneslight/config.json is malformed (docRoot is present and its value cannot be read); nothing created, repair the config first" >&2
  exit 1
fi

# D7 repair. docRoot decides where an entire 19-item tree lands, and the draft checked it for
# JSON-parseability and string-ness only. A docRoot of "../escaped docs" built the whole tree ONE
# LEVEL ABOVE the project and exited 0. This is the same class SS00025's W1.3 item b already
# fixed once elsewhere in the library, which is why it is worth naming rather than just fixing.
# Two related shapes died with unhandled exceptions instead: an absolute docRoot, and a
# whitespace-only docRoot (stripping trailing separators does not strip spaces, so the value
# survived the emptiness test and then failed at the filesystem).
if [ "$docRootArray" = 1 ]; then docRoot=; else docRoot=$(cfg_str docRoot "$cfgFile"); fi
docRoot=$(printf '%s' "$docRoot" | sed 's/^[[:space:]]*//; s/[[:space:]]*$//')
[ -n "$docRoot" ] || docRoot=documentation
while :; do
  case "$docRoot" in
    */|*'\') docRoot=${docRoot%?} ;;
    *) break ;;
  esac
done
[ -n "$docRoot" ] || docRoot=documentation
case "$docRoot" in
  /*|'\'*|[abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ]:*)
    echo "scaffold: docRoot '$docRoot' is an absolute path; docRoot must be relative to the project root. Nothing created" >&2
    exit 1
    ;;
esac
if ! path_contained "$root" "$root/$docRoot"; then
  echo "scaffold: docRoot '$docRoot' resolves outside the project root; nothing created" >&2
  exit 1
fi

tplDir="$root/.claude/template"
read_template docs readme-docs.md
read_template tests readme-tests.md
read_template header doc-header.md
check_template docs readme-docs.md session-summaries-readme architecture-readme registry-readme
check_template tests readme-tests.md tests-readme
check_template header doc-header.md doc-discipline-header

created=; createdN=0
skipped=; skippedN=0

print_prefixed() { # print_prefixed LABEL LIST
  [ -n "$2" ] || return 0
  printf '%s\n' "$2" | while IFS= read -r pp_i; do
    [ -n "$pp_i" ] && printf '%s %s\n' "$1" "$pp_i"
  done
  return 0
}

# D6 repair: both writers were entirely unguarded. A file seeded where a directory belongs
# created EIGHT directories and then died with a raw stack trace, no scaffold: prefix and no
# summary line, against a contract promising "exit 1, nothing created". The same happened under
# a real deny-write permission. Guarding cannot restore "nothing created" once writes have
# begun, so the contract is corrected to what is actually achievable and the failure is
# reported honestly: every item created so far is listed, then the failed item is named.
#
# Every target also passes containment, not just docRoot. docRoot is the value most likely to
# escape, but it is not the only path assembled here, and a per-target gate costs nothing.
fail_scaffold() { # fail_scaffold ITEM WHY
  print_prefixed CREATED "$created"
  echo "scaffold: cannot create $1 ($2); $createdN item(s) were already created and are listed above" >&2
  exit 1
}

ensure_dir() { # ensure_dir REL
  ed_full="$root/$1"
  path_contained "$root" "$ed_full" || fail_scaffold "$1" 'resolves outside the project root'
  # Typed, not bare. A bare [ -e ] is true for a FILE sitting where a directory belongs, and the
  # run then printed "EXISTS <rel>/" for it: the trailing slash was the lie. Nothing below it can
  # be created and the contract forbids replacing it, so it is a failure, never EXISTS.
  if [ -d "$ed_full" ]; then
    skipped="$skipped$1/$NL"; skippedN=$((skippedN + 1)); return 0
  fi
  [ -e "$ed_full" ] && fail_scaffold "$1" 'exists but is not a directory'
  if ! ed_err=$( { mkdir -p "$ed_full"; } 2>&1 ); then
    [ -n "$ed_err" ] || ed_err='mkdir failed'
    fail_scaffold "$1" "$ed_err"
  fi
  # The Windows post-condition, mirrored so the two writers state the same contract. It is
  # unfireable here by measurement: mkdir -p reports non-zero in every blocked shape tested,
  # unlike New-Item -Force, which the Windows side had to stop using. It is kept for symmetry
  # and for whoever swaps the creation call.
  [ -d "$ed_full" ] || fail_scaffold "$1" 'no error was raised and the directory does not exist afterwards'
  created="$created$1/$NL"; createdN=$((createdN + 1))
}

ensure_file() { # ensure_file REL BODYVAR
  # The body arrives by VARIABLE NAME, never by value: a command substitution would strip the
  # trailing newline every section body ends with, and the file would then differ from the
  # Windows one by exactly the byte nobody looks at.
  ef_full="$root/$1"
  path_contained "$root" "$ef_full" || fail_scaffold "$1" 'resolves outside the project root'
  # Typed, not bare, for the same reason with the types swapped: a DIRECTORY at a file's path was
  # reported as "EXISTS <rel>" and the run exited 0 with the file never written.
  if [ -f "$ef_full" ]; then
    skipped="$skipped$1$NL"; skippedN=$((skippedN + 1)); return 0
  fi
  [ -e "$ef_full" ] && fail_scaffold "$1" 'exists but is not a file'
  eval "ef_body=\$$2"
  if ! ef_err=$( { printf '%s' "$ef_body" > "$ef_full"; } 2>&1 ); then
    [ -n "$ef_err" ] || ef_err='write failed'
    fail_scaffold "$1" "$ef_err"
  fi
  created="$created$1$NL"; createdN=$((createdN + 1))
}

# Step 1: documentation tree. The dated architecture snapshot folder is Phase 5's job (its
# content is judgment); scaffold creates only the stable skeleton.
for d in "$docRoot" "$docRoot/archive" "$docRoot/archive/projects" "$docRoot/session-summaries" "$docRoot/plans" "$docRoot/plans/implementation" "$docRoot/plans/fixes" "$docRoot/architecture" "$docRoot/registry"; do
  ensure_dir "$d"
done
ensure_file "$docRoot/session-summaries/README.md" SEC_docs_session_summaries_readme
ensure_file "$docRoot/architecture/README.md" SEC_docs_architecture_readme
ensure_file "$docRoot/registry/README.md" SEC_docs_registry_readme

# Step 1b: tests tree. Only the literal tests/ layout is mechanical. When a DIFFERENT
# conventional test directory already exists at the root, the merge is framework judgment
# (phaneslight.md Step 1b) and stays with the session: report and leave it alone.
existingConv=
for c in test __tests__ spec; do
  if [ -e "$root/$c" ]; then existingConv=$c; break; fi
done
if [ -n "$existingConv" ] && [ ! -e "$root/tests" ]; then
  printf '%s\n' "TESTTREE-EXISTS $existingConv/ (conventional test tree present; the Step 1b merge stays with the session, nothing created)"
else
  for d in tests tests/unit tests/integration tests/e2e tests/fixtures tests/helpers; do
    ensure_dir "$d"
  done
  ensure_file tests/README.md SEC_tests_tests_readme
fi

print_prefixed CREATED "$created"
print_prefixed EXISTS "$skipped"
printf '%s\n' "scaffold: created $createdN, left untouched $skippedN"
exit 0
