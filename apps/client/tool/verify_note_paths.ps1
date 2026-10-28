# Stop on fixture and reporting errors; native test exit codes are handled below.
$ErrorActionPreference = 'Stop'
# Preserve native test exit codes instead of treating stderr as a PowerShell error.
$PSNativeCommandUseErrorActionPreference = $false

if (-not $IsWindows) {
  throw 'The note path regression requires Windows and a real 8.3 alias.'
}

# Locate the client while keeping diagnostics separate from disposable fixtures.
$clientRoot = (Resolve-Path -LiteralPath (Join-Path $PSScriptRoot '..')).Path
# Keep reports outside each disposable run directory.
$ciRoot = Join-Path $clientRoot 'build/ci'
# Use the operating system's real temporary volume, independent of the checkout disk.
$systemTemp = (Get-Item -LiteralPath ([IO.Path]::GetTempPath())).FullName
# Restrict fixture cleanup to a dedicated parent in the system temporary directory.
$fixtureRoot = Join-Path $systemTemp 'omni-note-path-fixtures'
# Reject redirected fixture parents before creating their descendants.
foreach ($parent in @($clientRoot, (Join-Path $clientRoot 'build'), $ciRoot, $systemTemp, $fixtureRoot)) {
  if (-not (Test-Path -LiteralPath $parent)) {
    New-Item -ItemType Directory -Path $parent -ErrorAction Stop | Out-Null
  }
  if (((Get-Item -LiteralPath $parent -Force).Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) {
    throw "Fixture parent must not be a link: $parent"
  }
}
$fixtureRoot = (Resolve-Path -LiteralPath $fixtureRoot).Path
# Use a unique run directory to avoid touching another process's files.
$runRoot = Join-Path $fixtureRoot ("NotePathRegression-" + [guid]::NewGuid().ToString('N'))
# Preserve the calling process's TEMP value.
$savedTemp = [Environment]::GetEnvironmentVariable('TEMP', 'Process')
# Preserve the calling process's TMP value.
$savedTmp = [Environment]::GetEnvironmentVariable('TMP', 'Process')
# Remove only this entry point's previous reports so failed setup cannot show stale results.
foreach ($previousReport in @('note-path-long.log', 'note-path-long.json', 'note-path-short.log', 'note-path-short.json', 'note-path-environment.log')) {
  # These fixed filenames are scoped to the verified diagnostics directory.
  $previousPath = Join-Path $ciRoot $previousReport
  if (Test-Path -LiteralPath $previousPath -PathType Leaf) {
    Remove-Item -LiteralPath $previousPath -Force
  }
}

# Delete only this run's verified tree, treating junctions and symlinks as leaves.
function Remove-OwnedTree([string] $target, [string] $owner) {
  # Compare full paths before touching the filesystem.
  $fullTarget = [IO.Path]::GetFullPath($target).TrimEnd('\')
  # The owner is the dedicated fixture parent.
  $fullOwner = [IO.Path]::GetFullPath($owner).TrimEnd('\')
  if (-not $fullTarget.StartsWith($fullOwner + '\', [StringComparison]::OrdinalIgnoreCase)) {
    throw "Refusing to remove path outside fixture root: $fullTarget"
  }
  # Inspect links without following them.
  $item = Get-Item -LiteralPath $fullTarget -Force
  if (($item.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) {
    Remove-Item -LiteralPath $fullTarget -Force
    return
  }
  if ($item.PSIsContainer) {
    # Inspect each child separately so links are never traversed.
    foreach ($child in Get-ChildItem -LiteralPath $fullTarget -Force) {
      Remove-OwnedTree $child.FullName $owner
    }
  }
  Remove-Item -LiteralPath $fullTarget -Force
}

# Report the machine-readable count of explicitly skipped test results.
function Write-SkipSummary([string] $reportPath, [string] $label) {
  if (-not (Test-Path -LiteralPath $reportPath -PathType Leaf)) {
    Write-Output "$label skipped: unknown (JSON report was not created)"
    return
  }
  # Count the test protocol's skipped completion events.
  $skipped = 0
  # Associate test IDs with their suite and display names.
  $tests = @{}
  # Associate suite IDs with their source paths.
  $suites = @{}
  # Collect skip messages independently of completion order.
  $reasons = @{}
  # Record skipped IDs until all messages have been read.
  $skippedIds = @()
  try {
    # Each line is one independent JSON event.
    foreach ($line in [IO.File]::ReadLines($reportPath)) {
      # The event describes a single test state change.
      $event = $line | ConvertFrom-Json
      if ($event.type -eq 'suite') { $suites["$($event.suite.id)"] = $event.suite.path }
      if ($event.type -eq 'testStart') { $tests["$($event.test.id)"] = $event.test }
      if ($event.type -eq 'print' -and $event.messageType -eq 'skip') {
        $reasons["$($event.testID)"] = $event.message
      }
      if ($event.type -eq 'testDone' -and $event.skipped -eq $true) {
        $skipped++
        $skippedIds += "$($event.testID)"
      }
    }
  } catch {
    Write-Output "$label skipped: unknown (invalid JSON report)"
    return
  }
  Write-Output "$label skipped: $skipped"
  foreach ($id in $skippedIds) {
    # A missing reason is reported explicitly rather than inferred.
    # Reporter metadata identifies both the test and its suite.
    $test = $tests[$id]
    # Metadata can supply a static skip reason when no message was emitted.
    $reason = if ($reasons.ContainsKey($id)) { $reasons[$id] } elseif ($test -and $test.metadata.skipReason) { $test.metadata.skipReason } else { 'No reason in reporter output' }
    $suite = if ($test) { $suites["$($test.suiteID)"] } else { 'unknown suite' }
    $name = if ($test) { $test.name } else { "unknown test ID $id" }
    Write-Output "  $suite :: $name :: $reason"
  }
}

# Run the same path and recovery suites for each temporary-directory spelling.
function Invoke-PathTests([string] $label, [string] $tempPath) {
  [Environment]::SetEnvironmentVariable('TEMP', $tempPath, 'Process')
  [Environment]::SetEnvironmentVariable('TMP', $tempPath, 'Process')
  # Retain the machine-readable stream for this round.
  $report = Join-Path $ciRoot "note-path-$label.json"
  # Retain the human-readable stream for this round.
  $log = Join-Path $ciRoot "note-path-$label.log"
  Write-Host "Running $label TEMP=$tempPath"
  & flutter test --no-pub --concurrency=1 --reporter expanded "--file-reporter=json:$report" `
    test/note_file_paths_test.dart `
    test/note_test_data_cleanup_test.dart `
    test/note_test_data_cleanup_resume_test.dart `
    test/features/notes/note_audio_service_test.dart `
    test/features/notes/note_repository_test.dart 2>&1 | Tee-Object -FilePath $log | Out-Host
  # Capture the native process result before invoking any other command.
  $testExit = $LASTEXITCODE
  Write-SkipSummary $report $label | Tee-Object -FilePath $log -Append | Out-Host
  return $testExit
}

try {
  New-Item -ItemType Directory -Path $runRoot -ErrorAction Stop | Out-Null
  $runRoot = (Resolve-Path -LiteralPath $runRoot).Path
  # Save runtime details before attempting alias discovery.
  @(
    "Revision: $(git -C $clientRoot rev-parse HEAD)"
    "Runner OS: $env:RUNNER_OS"
    "Runner image: $env:ImageOS $env:ImageVersion"
    "Long fixture: $runRoot"
    (flutter --version | Out-String)
  ) | Tee-Object -FilePath (Join-Path $ciRoot 'note-path-environment.log') | Out-Host
  # COM obtains the real alias for the fixture, never a guessed 8.3 name.
  $fileSystem = New-Object -ComObject Scripting.FileSystemObject
  # Fail if the volume cannot provide a distinct spelling.
  $shortRoot = $fileSystem.GetFolder($runRoot).ShortPath
  # Persist the actual alias even when it is missing or identical.
  "Short fixture: $shortRoot" | Tee-Object -FilePath (Join-Path $ciRoot 'note-path-environment.log') -Append | Out-Host
  if ([string]::IsNullOrWhiteSpace($shortRoot) -or
      [string]::Equals($shortRoot, $runRoot, [StringComparison]::OrdinalIgnoreCase)) {
    throw "No distinct 8.3 alias is available for $runRoot"
  }
  Write-Output "Long fixture: $runRoot"
  Write-Output "Short fixture: $shortRoot"
  Push-Location $clientRoot
  try {
    # Preserve each process exit code even when the first round fails.
    $longExit = Invoke-PathTests 'long' $runRoot
    # The second round uses the same fixture through its real short alias.
    $shortExit = Invoke-PathTests 'short' $shortRoot
  } finally {
    Pop-Location
  }
  if ($longExit -ne 0) { exit $longExit }
  if ($shortExit -ne 0) { exit $shortExit }
} finally {
  [Environment]::SetEnvironmentVariable('TEMP', $savedTemp, 'Process')
  [Environment]::SetEnvironmentVariable('TMP', $savedTmp, 'Process')
  if (Test-Path -LiteralPath $runRoot) {
    Remove-OwnedTree $runRoot $fixtureRoot
  }
}
