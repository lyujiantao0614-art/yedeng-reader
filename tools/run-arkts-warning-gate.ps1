param(
  [string]$DevEcoHome = 'E:\DevEco Studio',
  [switch]$UpdateBaseline
)

$ErrorActionPreference = 'Stop'
$repoRoot = Split-Path -Parent $PSScriptRoot
$hvigor = Join-Path $DevEcoHome 'tools\hvigor\bin\hvigorw.bat'
$env:DEVECO_SDK_HOME = Join-Path $DevEcoHome 'sdk'
$warningLog = [IO.Path]::GetTempFileName()

Push-Location $repoRoot
try {
  $buildOutput = & $hvigor assembleHap --mode module -p product=default -p module=entry@default `
    -p buildMode=debug --no-daemon --no-incremental 2>&1
  $buildExit = $LASTEXITCODE
  $buildOutput | Set-Content -LiteralPath $warningLog -Encoding UTF8
  if ($buildExit -ne 0) {
    $buildOutput | Select-Object -Last 80 | Write-Output
    throw 'Debug build failed before the warning budget could be checked'
  }
  if ($UpdateBaseline) {
    node tools/check-arkts-warning-budget.cjs --write-baseline $warningLog
  } else {
    node tools/check-arkts-warning-budget.cjs $warningLog
  }
  if ($LASTEXITCODE -ne 0) { throw 'ArkTS warning budget failed' }
} finally {
  Pop-Location
  if (Test-Path -LiteralPath $warningLog) { Remove-Item -LiteralPath $warningLog -Force }
}
