# phaneslight-template v3.8.1 phaneslight
# Dispatcher. Routes `phaneslight <subcommand> [args]` to the sibling script in this directory.
# Resolves siblings by this script's own location, so it works from any working directory.
$ErrorActionPreference = 'Stop'

if ($args.Count -lt 1) {
  # ENUMERATED from this directory, never hardcoded (v3.8.0). Both dispatchers used to carry a
  # hand-maintained list and the two had already drifted: the POSIX one named hook-ledger-status
  # and this one did not. Nothing in the build could see the difference, which is exactly why it
  # survived. A list derived from the directory cannot disagree with the directory.
  # Excluded: this dispatcher itself, and the hook-* scripts, which the harness fires on tool
  # calls and which are not user subcommands.
  $names = @(Get-ChildItem -LiteralPath $PSScriptRoot -Filter '*.ps1' -File |
    ForEach-Object { [System.IO.Path]::GetFileNameWithoutExtension($_.Name) } |
    Where-Object { $_ -ne 'phaneslight' -and $_ -notlike 'hook-*' } |
    Sort-Object)
  Write-Output ("phaneslight: subcommands: " + ($names -join ' '))
  exit 0
}

$sub = $args[0]
$rest = @()
if ($args.Count -gt 1) { $rest = $args[1..($args.Count - 1)] }

$target = Join-Path $PSScriptRoot ($sub + '.ps1')
if (-not (Test-Path -LiteralPath $target)) {
  [Console]::Error.WriteLine("phaneslight: unknown subcommand '$sub' (no $sub.ps1 in $PSScriptRoot)")
  exit 1
}

& $target @rest
exit $LASTEXITCODE
