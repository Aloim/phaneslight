# phaneslight-template v3.8.1 hook-stamp-guard
# PreToolUse(Write) guard. Reads the tool-call JSON from stdin. Denies (exit 2) creation of a NEW
# file under a stamped tree whose content lacks the required header stamp, so new files must go
# through `phaneslight new-file`. Every other call passes (exit 0). Fails open on tool-call JSON or IO
# trouble; a malformed .phaneslight/config.json instead falls back to the default stamped-tree list and
# says so on stderr, so the guard stays live and audible rather than silently switching off.
$ErrorActionPreference = 'Stop'

function Find-PhanesLightRoot {
  param([string]$start)
  $d = $start
  while ($true) {
    if (Test-Path -LiteralPath (Join-Path $d '.phaneslight\config.json')) { return $d }
    $p = [System.IO.Path]::GetDirectoryName($d)
    if (-not $p -or $p -eq $d) { return $null }
    $d = $p
  }
}

try {
  # Run by hand instead of by a hook (stdin is a console, no tool-call JSON is coming): exit
  # cleanly rather than blocking forever on a read that never returns.
  if (-not [Console]::IsInputRedirected) { exit 0 }
  $raw = [Console]::In.ReadToEnd()
  if (-not $raw) { exit 0 }
  $data = $raw | ConvertFrom-Json

  $fp = $data.tool_input.file_path
  if (-not $fp) { exit 0 }
  $content = [string]$data.tool_input.content

  # Only NEW files are guarded.
  if (Test-Path -LiteralPath $fp) { exit 0 }

  $startDir = [System.IO.Path]::GetDirectoryName($fp)
  if (-not $startDir) { $startDir = (Get-Location).Path }
  # Walk up from the file location, or the current directory, to locate the project root.
  $root = Find-PhanesLightRoot $startDir
  if (-not $root) { $root = Find-PhanesLightRoot (Get-Location).Path }
  if (-not $root) { exit 0 }

  $rootNorm = ((Resolve-Path -LiteralPath $root).Path -replace '\\', '/').TrimEnd('/')
  $fpNorm = ($fp -replace '\\', '/')
  if (-not $fpNorm.StartsWith($rootNorm, [System.StringComparison]::OrdinalIgnoreCase)) { exit 0 }
  $rel = $fpNorm.Substring($rootNorm.Length).TrimStart('/')

  $stamped = @('src', 'tests', 'documentation')
  try {
    $cfg = Get-Content -LiteralPath (Join-Path $root '.phaneslight\config.json') -Raw -Encoding utf8 | ConvertFrom-Json
    # An explicit stampedTrees is AUTHORITATIVE (v3.8.1). Appending modules to it, as this did
    # through v3.8.0, meant a project that deliberately excluded a tree had no knob that made the
    # exclusion hold: where modules are logical names rather than root paths, a name that happens
    # to equal an unrelated root directory guarded it anyway, and every new file there was denied
    # unless its author wrote the very stamp the project forbids. modules stays a convenience over
    # the DEFAULT list, where module names are usually source-root paths, and is never added to a
    # list the project wrote by hand.
    if ($cfg.stampedTrees -and @($cfg.stampedTrees).Count -gt 0) {
      $stamped = @($cfg.stampedTrees)
    } elseif ($cfg.modules) {
      $stamped += $cfg.modules
    }
    # docRoot is appended in BOTH branches and is the one floor an explicit list does not remove:
    # the DOC header it guards is what doc-index and doc-check read, so listing the documentation
    # root is a restatement of the rule rather than a choice.
    if ($cfg.docRoot) { $stamped += ([string]$cfg.docRoot).TrimEnd('/', '\') }
  } catch {
    # This is the PreToolUse gate that makes `phaneslight new-file` mandatory; a malformed config must
    # not silently switch it off. Fall back to the default stamped-tree list and say so on stderr,
    # so the failure is visible rather than a quiet no-op. Caught here, inside the guard's own
    # logic, so the outer catch's fail-open exit 0 below never swallows this specific case; the
    # guard still runs, against the default list, and stays live and audible on both platforms.
    [Console]::Error.WriteLine('hook-stamp-guard: .phaneslight/config.json is malformed, using default stamped trees (src, tests, documentation)')
  }

  $guarded = $false
  foreach ($t in $stamped) {
    $tn = ($t -replace '\\', '/').Trim('/')
    if ($tn -eq '') { continue }
    if ($rel -eq $tn -or $rel.StartsWith($tn + '/', [System.StringComparison]::OrdinalIgnoreCase)) { $guarded = $true; break }
  }
  if (-not $guarded) { exit 0 }

  $hasSource = $content -match 'Soft size threshold: 500 LOC'
  $hasDoc = $content -match '<!--\s*DOC\s*\|'
  if ($hasSource -or $hasDoc) { exit 0 }

  [Console]::Error.WriteLine("New files must be created via ``phaneslight new-file``, the stamp is what ``regen-registry`` slices modules by; bypassing it produces silent API-baseline drift.")
  exit 2
} catch {
  # Never wedge the session on a parse or IO error.
  exit 0
}
