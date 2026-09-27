param(
  [string]$DevEcoHome = 'E:\DevEco Studio'
)

$ErrorActionPreference = 'Stop'
$repoRoot = Split-Path -Parent $PSScriptRoot
$hvigor = Join-Path $DevEcoHome 'tools\hvigor\bin\hvigorw.bat'
$env:DEVECO_SDK_HOME = Join-Path $DevEcoHome 'sdk'
$sampleSource = Join-Path $repoRoot 'entry\src\main\resources\rawfile\demo\under-the-lamp.epub'

function Invoke-Build([string]$target, [string]$mode) {
  & $hvigor assembleHap --mode module -p product=default -p "module=entry@$target" `
    -p "buildMode=$mode" --no-daemon --no-incremental
  if ($LASTEXITCODE -ne 0) { throw "Build failed: $target/$mode" }
}

function Assert-ProductionProfile([string]$mode) {
  $profilePath = Join-Path $repoRoot 'entry\build\default\intermediates\merge_profile\default\module.json'
  $profile = Get-Content -Raw -Encoding UTF8 $profilePath | ConvertFrom-Json
  $permissions = @($profile.module.requestPermissions | Where-Object { $null -ne $_ } | ForEach-Object { $_.name })
  if ($permissions.Count -ne 0) {
    throw "Unexpected production permission set in $mode"
  }
  if (($mode -eq 'release' -or $mode -eq 'benchmark') -and $profile.app.debug -ne $false) {
    throw "$mode profile is debuggable"
  }
}

function Assert-ProductionHap([string]$mode) {
  Add-Type -AssemblyName System.IO.Compression.FileSystem
  $hapPath = Join-Path $repoRoot 'entry\build\default\outputs\default\entry-default-signed.hap'
  if (-not (Test-Path -LiteralPath $hapPath)) { throw "Missing signed HAP for $mode" }
  $archive = [IO.Compression.ZipFile]::OpenRead($hapPath)
  try {
    $entries = @($archive.Entries | ForEach-Object { $_.FullName })
    $moduleEntry = $archive.GetEntry('module.json')
    if ($null -eq $moduleEntry) { throw "Missing packaged module manifest for $mode" }
    $moduleReader = [IO.StreamReader]::new($moduleEntry.Open())
    try { $moduleProfile = $moduleReader.ReadToEnd() | ConvertFrom-Json }
    finally { $moduleReader.Dispose() }
    if (@($moduleProfile.module.requestPermissions | Where-Object { $null -ne $_ } | ForEach-Object { $_.name }).Count -ne 0) {
      throw "Unexpected packaged permission set in $mode"
    }
    $bytecodeEntry = $archive.GetEntry('ets/modules.abc')
    if ($null -eq $bytecodeEntry) { throw "Missing compiled application module for $mode" }
    $bytecodeReader = [IO.StreamReader]::new($bytecodeEntry.Open(), [Text.Encoding]::Latin1)
    try { $bytecode = $bytecodeReader.ReadToEnd() }
    finally { $bytecodeReader.Dispose() }
    foreach ($marker in @('NativeAIHttpTransport', 'AISettingsPage', 'AIReadingActionSession',
        'AIReadingService', '@kit.NetworkKit', 'settings-section-ai', 'reader-ai-cover')) {
      if ($bytecode.Contains($marker)) { throw "Local-only HAP still contains $marker in $mode" }
    }
    $resourceEntry = $archive.GetEntry('resources.index')
    if ($null -eq $resourceEntry) { throw "Missing packaged resource index for $mode" }
    $resourceReader = [IO.StreamReader]::new($resourceEntry.Open(), [Text.Encoding]::UTF8)
    try { $resources = $resourceReader.ReadToEnd() }
    finally { $resourceReader.Dispose() }
    foreach ($marker in @('ai_settings_title', 'reader_ai_question_title', 'settings_ai_title')) {
      if ($resources.Contains($marker)) { throw "Local-only HAP still contains $marker in $mode" }
    }
    $sampleEntryPath = 'resources/rawfile/demo/under-the-lamp.epub'
    $forbidden = @($entries | Where-Object {
      ($_ -match '(?i)\.epub$' -and $_ -ne $sampleEntryPath) -or
      $_ -match 'ohosTest|ReaderImportUi|Ability\.test|\.(p12|p7b|cer|pem|key)$'
    })
    if ($forbidden.Count -gt 0) { throw "Forbidden production HAP entries: $($forbidden -join ', ')" }
    $sampleEntry = $archive.GetEntry($sampleEntryPath)
    if ($null -eq $sampleEntry -or $sampleEntry.Length -gt 262144) { throw "Missing or oversized packaged sample in $mode" }
    $sampleStream = $sampleEntry.Open()
    $sampleHasher = [Security.Cryptography.SHA256]::Create()
    try { $sampleHash = [BitConverter]::ToString($sampleHasher.ComputeHash($sampleStream)).Replace('-', '') }
    finally { $sampleHasher.Dispose(); $sampleStream.Dispose() }
    if ($sampleHash -ne (Get-FileHash -Algorithm SHA256 -LiteralPath $sampleSource).Hash) {
      throw "Packaged sample differs from generated source in $mode"
    }
    foreach ($license in @(
      'resources/rawfile/dictionary/THIRD_PARTY_NOTICES.txt',
      'resources/rawfile/web-reader/vendor/epubjs-0.3.93/LICENSE',
      'resources/rawfile/web-reader/vendor/jszip-3.10.1/LICENSE.markdown',
      'resources/rawfile/legal/LICENSE',
      'resources/rawfile/legal/NOTICE',
      'resources/rawfile/legal/THIRD_PARTY_NOTICES.md'
    )) {
      if ($entries -notcontains $license) { throw "Missing packaged license: $license" }
    }
    $legalPairs = @{
      'resources/rawfile/legal/LICENSE' = 'LICENSE'
      'resources/rawfile/legal/NOTICE' = 'NOTICE'
      'resources/rawfile/legal/THIRD_PARTY_NOTICES.md' = 'THIRD_PARTY_NOTICES.md'
      'resources/rawfile/privacy/yedeng-privacy-policy.txt' = 'entry/src/main/resources/rawfile/privacy/yedeng-privacy-policy.txt'
    }
    foreach ($entryPath in $legalPairs.Keys) {
      $entry = $archive.GetEntry($entryPath)
      if ($null -eq $entry) { throw "Missing packaged legal file: $entryPath" }
      $stream = $entry.Open()
      $sha256 = [Security.Cryptography.SHA256]::Create()
      try {
        $entryHash = [BitConverter]::ToString($sha256.ComputeHash($stream)).Replace('-', '')
      } finally {
        $sha256.Dispose()
        $stream.Dispose()
      }
      $sourceHash = (Get-FileHash -Algorithm SHA256 -LiteralPath (Join-Path $repoRoot $legalPairs[$entryPath])).Hash
      if ($entryHash -ne $sourceHash) { throw "Packaged legal content differs: $entryPath" }
    }
  } finally {
    $archive.Dispose()
  }
}

Push-Location $repoRoot
try {
  if (-not (Test-Path -LiteralPath $sampleSource)) {
    python tools/build-listing-demo-epub.py --package
    if ($LASTEXITCODE -ne 0) { throw 'Sample EPUB generation failed' }
  }
  node tools/run-source-contracts.cjs
  if ($LASTEXITCODE -ne 0) { throw 'Source contracts failed' }
  foreach ($mode in @('debug', 'release', 'benchmark')) {
    Invoke-Build 'default' $mode
    Assert-ProductionProfile $mode
    Assert-ProductionHap $mode
  }
  Write-Output 'Installed-SDK gate passed: debug/release/benchmark builds and production HAP audits.'
} finally {
  Pop-Location
}
