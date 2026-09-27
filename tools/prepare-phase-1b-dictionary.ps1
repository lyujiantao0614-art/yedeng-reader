param(
  [string]$OutputDir = "entry/build/phase1b-dataset-review/reproducible"
)

$ErrorActionPreference = "Stop"

$repoRoot = Resolve-Path (Join-Path $PSScriptRoot "..")
$sourceDir = Join-Path $repoRoot "entry/build/phase1b-dataset-review/sources"
$outputPath = Join-Path $repoRoot $OutputDir
$ccCedictPath = Join-Path $repoRoot "third_party/dictionary/sources/cc-cedict-2026-08-14.txt.gz"
$representativeCases = Join-Path $repoRoot "test-data/phase-1b/representative-words.json"
$builder = Join-Path $repoRoot "tools/build-phase-1b-dictionary.py"

$omwCmnPath = Join-Path $sourceDir "omw-cmn-2.0.tar.xz"
$omwEnPath = Join-Path $sourceDir "omw-en-2.0.tar.xz"

$sources = @(
  @{
    Path = $omwCmnPath
    Url = "https://github.com/omwn/omw-data/releases/download/v2.0/omw-cmn-2.0.tar.xz"
    Sha256 = "7D07AF60A6CED0CEDC4CA114D0B60A796D3F138DF0F3BE21F6322E53D004E91C"
  },
  @{
    Path = $omwEnPath
    Url = "https://github.com/omwn/omw-data/releases/download/v2.0/omw-en-2.0.tar.xz"
    Sha256 = "0E09DFB7F096BC3F10B9DE68FFECF13839FA22AE46FD9B227CEC890D204CA1DC"
  }
)

New-Item -ItemType Directory -Force $sourceDir | Out-Null
New-Item -ItemType Directory -Force $outputPath | Out-Null

foreach ($source in $sources) {
  if (Test-Path -LiteralPath $source.Path) {
    $existingHash = (Get-FileHash -LiteralPath $source.Path -Algorithm SHA256).Hash
    if ($existingHash -ne $source.Sha256) {
      throw "Pinned source hash mismatch: $($source.Path)"
    }
    continue
  }

  $temporaryPath = "$($source.Path).download"
  Invoke-WebRequest -Uri $source.Url -OutFile $temporaryPath
  $downloadHash = (Get-FileHash -LiteralPath $temporaryPath -Algorithm SHA256).Hash
  if ($downloadHash -ne $source.Sha256) {
    throw "Downloaded source hash mismatch: $($source.Url)"
  }
  Move-Item -LiteralPath $temporaryPath -Destination $source.Path
}

python $builder `
  --omw-cmn $omwCmnPath `
  --omw-en $omwEnPath `
  --cc-cedict $ccCedictPath `
  --representative-cases $representativeCases `
  --output-dir $outputPath

if ($LASTEXITCODE -ne 0) {
  throw "Dictionary generation failed with exit code $LASTEXITCODE"
}
