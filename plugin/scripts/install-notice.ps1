# phaneslight-template v3.7.0 install-notice
# SessionStart notice, once per install. Plain stdout reaches the model, not the user;
# the systemMessage JSON field is the only channel that reliably reaches the human.
$ErrorActionPreference = 'Stop'
try {
  $dataDir = $env:CLAUDE_PLUGIN_DATA
  if (-not $dataDir) { exit 0 }
  $marker = Join-Path $dataDir '.welcomed-3.7.0'
  if (Test-Path -LiteralPath $marker) { exit 0 }
  if (-not (Test-Path -LiteralPath $dataDir)) { New-Item -ItemType Directory -Force -Path $dataDir | Out-Null }
  Set-Content -LiteralPath $marker -Value '' -Encoding utf8
  $msg = 'PhanesLight v3.7.0 installed. Run /phaneslight:run to update Project Memory.'
  $payload = @{ systemMessage = $msg } | ConvertTo-Json -Compress
  [Console]::Out.Write($payload)
} catch { }
exit 0
