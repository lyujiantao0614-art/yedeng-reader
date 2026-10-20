param(
  [Parameter(Mandatory = $true)][string]$DevEcoHome,
  [Parameter(Mandatory = $true)][string]$Sdk26Tools,
  [string]$HvigorCache = '',
  [ValidateSet('Full', 'Development', 'Release')]
  [string]$Mode = 'Full',
  [ValidateSet('default')]
  [string]$Target = 'default',
  [switch]$Rebuild
)

$ErrorActionPreference = 'Stop'
$repoRoot = Split-Path -Parent $PSScriptRoot
$hvigorWrapper = Join-Path $Sdk26Tools 'hvigor\bin\hvigorw.js'
$buildNode = Join-Path $Sdk26Tools 'tool\node\node.exe'
$hvigor = { & $buildNode $hvigorWrapper @args }
$sdkRoot = Join-Path $Sdk26Tools 'sdk'
$javaRoot = Join-Path $DevEcoHome 'jbr'
if ($Mode -eq 'Full' -and ($PSBoundParameters.ContainsKey('Target') -or $Rebuild)) {
  throw 'Target/Rebuild apply only to Development or Release. Full rebuilds the public debug/release/benchmark production targets.'
}
if ($Mode -eq 'Release' -and $Target -ne 'default') {
  throw 'Release supports only the default production target.'
}
$node = (Get-Command node -ErrorAction Stop).Source
$expectedNode = (Get-Content -Raw -LiteralPath (Join-Path $repoRoot '.node-version')).Trim()
if ((& $node --version).Trim().TrimStart('v') -ne $expectedNode) {
  throw "Node mismatch: expected $expectedNode. Dependencies were not changed."
}

if ((& $buildNode --version).Trim() -ne 'v24.14.1') { throw 'Approved build Node 24.14.1 required.' }
if ((Get-Content -Raw -LiteralPath (Join-Path $javaRoot 'release')) -notmatch 'JAVA_VERSION="21\.0\.8') {
  throw 'Approved JBR 21.0.8 required.'
}

function Invoke-Build([string]$target, [string]$buildMode) {
  $buildArguments = @('assembleHap', '--mode', 'module', '-p', 'product=default',
    '-p', "module=entry@$target", '-p', "buildMode=$buildMode", '--no-daemon')
  if ($Mode -eq 'Full' -or $Rebuild) { $buildArguments += '--no-incremental' }
  $logDirectory = Join-Path $repoRoot '.hvigor\major-development'
  New-Item -ItemType Directory -Path $logDirectory -Force | Out-Null
  $logPath = Join-Path $logDirectory "sdk-$Mode-$target-$buildMode.log"
  # Windows PowerShell 5 treats native stderr warnings as ErrorRecords.
  # Retain the local log; decide build success from the native exit code.
  $capturePreference = $ErrorActionPreference
  try {
    $ErrorActionPreference = 'Continue'
    $buildOutput = & $hvigor @buildArguments 2>&1
    $buildExit = $LASTEXITCODE
  } finally { $ErrorActionPreference = $capturePreference }
  $buildOutput | Set-Content -LiteralPath $logPath -Encoding UTF8
  if ($buildExit -ne 0) { throw "Build failed: $target/$buildMode. Inspect the ignored local SDK log." }
  & $node (Join-Path $repoRoot 'tools\check-arkts-warning-budget.cjs') $logPath
  if ($LASTEXITCODE -ne 0) { throw "ArkTS warning budget failed: $target/$buildMode" }
  Write-Output "SDK build passed: $target/$buildMode (gate=$Mode, forced rebuild=$($Mode -eq 'Full' -or [bool]$Rebuild))."
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
    if ($moduleProfile.app.compileSdkVersion -ne '26.0.0.105' -or
        $moduleProfile.app.targetAPIVersion -ne 260000026 -or $moduleProfile.app.minAPIVersion -ne 60001021) {
      throw "SDK26/target26/compatible21 packaged contract differs in $mode"
    }
    if (@($moduleProfile.module.requestPermissions | Where-Object { $null -ne $_ } | ForEach-Object { $_.name }).Count -ne 0) {
      throw "Unexpected packaged permission set in $mode"
    }
    $bytecodeEntry = $archive.GetEntry('ets/modules.abc')
    if ($null -eq $bytecodeEntry) { throw "Missing compiled application module for $mode" }
    $bytecodeReader = [IO.StreamReader]::new($bytecodeEntry.Open(), [Text.Encoding]::GetEncoding(28591))
    try { $bytecode = $bytecodeReader.ReadToEnd() }
    finally { $bytecodeReader.Dispose() }
    foreach ($marker in @('NativeAIHttpTransport', 'AISettingsPage', 'AIReadingActionSession',
        'AIReadingService', '@kit.NetworkKit', 'settings-section-ai', 'reader-ai-cover',
        'BundledSampleSeeder', 'seedBundledSample', 'bundled_sample', 'under-the-lamp.epub')) {
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
    $forbidden = @($entries | Where-Object {
      $_ -match '(?i)\.epub$' -or
      $_ -match 'ohosTest|ReaderImportUi|Ability\.test|\.(p12|p7b|cer|pem|key)$'
    })
    if ($forbidden.Count -gt 0) { throw "Forbidden production HAP entries: $($forbidden -join ', ')" }
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

$taskEnvNames = @('DEVECO_NODE_HOME', 'NODE_HOME', 'HVIGOR_USER_HOME', 'YEDENG_SDK26_WARNING_GATE', 'YEDENG_HVIGOR_CACHE')
$taskEnvPrevious = @{}
foreach ($name in $taskEnvNames) { $taskEnvPrevious[$name] = [Environment]::GetEnvironmentVariable($name, 'Process') }
$env:DEVECO_NODE_HOME = Join-Path $Sdk26Tools 'tool\node'
$env:NODE_HOME = $env:DEVECO_NODE_HOME
$env:HVIGOR_USER_HOME = Join-Path $repoRoot '.hvigor\major-development\sdk26-main-user-home'
$env:YEDENG_SDK26_WARNING_GATE = 'exact-nine'
$env:YEDENG_HVIGOR_CACHE = $HvigorCache
$previousSdk = $env:DEVECO_SDK_HOME
$previousJava = $env:JAVA_HOME
$previousPath = $env:PATH
$env:DEVECO_SDK_HOME = $sdkRoot
$env:JAVA_HOME = $javaRoot
$env:PATH = "$env:DEVECO_NODE_HOME;$(Join-Path $javaRoot 'bin');$(Join-Path $Sdk26Tools 'ohpm\bin');$previousPath"
Push-Location $repoRoot
try {
  & $node (Join-Path $repoRoot 'tools\prepare-sdk26-cache.cjs') $Sdk26Tools
  if ($LASTEXITCODE -ne 0) { throw 'SDK26 bundled cache preparation failed' }
  if ($Mode -eq 'Development' -or $Mode -eq 'Release') {
    $selectedBuildMode = if ($Mode -eq 'Release') { 'release' } else { 'debug' }
    Invoke-Build $Target $selectedBuildMode
    if ($Target -eq 'default') {
      Assert-ProductionProfile $selectedBuildMode
      Assert-ProductionHap $selectedBuildMode
    }
    Write-Output "$Mode SDK check passed. Run affected source/behavior checks separately; this is not a full SDK or device gate."
  } else {
    & $node tools/run-source-contracts.cjs
    if ($LASTEXITCODE -ne 0) { throw 'Source contracts failed' }
    foreach ($buildMode in @('debug', 'release', 'benchmark')) {
      Invoke-Build 'default' $buildMode
      Assert-ProductionProfile $buildMode
      Assert-ProductionHap $buildMode
    }
    Write-Output 'Public installed-SDK gate passed: debug/release/benchmark production builds and HAP audits; private device-test target is excluded.'
  }
} finally {
  Pop-Location
  $env:DEVECO_SDK_HOME = $previousSdk
  $env:JAVA_HOME = $previousJava
  $env:PATH = $previousPath
  foreach ($name in $taskEnvNames) { [Environment]::SetEnvironmentVariable($name, $taskEnvPrevious[$name], 'Process') }
}
