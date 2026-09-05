# phaneslight-template v3.8.1 anchor-check
# Windows launcher for the anchor-check node program. The program is ONE artifact shared by both
# platforms, exactly as scripts/cli.js already is, because its parser is a markdown grammar plus a
# tree-derived path resolver plus nested JSON config, and maintaining that twice would buy nothing
# but a second place for it to drift.
#
# The program resolves as a SIBLING of this launcher. That is true after install-templates
# flattens the library into .phaneslight/scripts/, and it is false in the plugin source tree where
# this file sits one directory below the program. A control that checks the program must therefore
# invoke node against templates/scripts/anchor-check.js directly and never through this shim.
$ErrorActionPreference = 'Stop'
$program = Join-Path $PSScriptRoot 'anchor-check.js'
if (-not (Test-Path -LiteralPath $program)) {
  [Console]::Error.WriteLine("anchor-check: the node program is not beside this launcher ($program)")
  exit 1
}
& node $program @args
exit $LASTEXITCODE
