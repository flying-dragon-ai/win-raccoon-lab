# raccoon-clean.ps1 - move safe cache entries into a same-volume trash folder.
# Recoverable by design: nothing is deleted, everything is renamed into .raccoon-trash.
[CmdletBinding()]
param(
  [string]$MapPath,
  [string[]]$Ids,
  [string]$TrashRoot,
  [switch]$DryRun,
  [switch]$IncludeCaution
)
$ErrorActionPreference = 'Continue'
[Console]::OutputEncoding = New-Object System.Text.UTF8Encoding($false)

Import-Module (Join-Path $PSScriptRoot 'Raccoon.Common.psm1') -Force

$script:Here = $PSScriptRoot
if (-not $MapPath) { $MapPath = Join-Path $script:Here 'cache-map.jsonl' }
if (-not $TrashRoot) { $TrashRoot = Join-Path $env:USERPROFILE '.raccoon-trash' }
$stamp = Get-Date -Format 'yyyyMMdd-HHmm'

function Get-EntryTargets {
  # Forward slashes here: the trash layout and the log lines use them.
  param($Entry)
  $resolved = Resolve-RaccoonPath -Raw ([string]$Entry.path) -Separator '/'
  if ($resolved -match '[*?]') {
    return @(Get-Item -Path $resolved -Force -ErrorAction SilentlyContinue)
  }
  $one = Get-Item -LiteralPath $resolved -Force -ErrorAction SilentlyContinue
  if ($null -eq $one) { return @() }
  return @($one)
}

function Move-IntoTrash {
  # Whole-directory move first. If a handle is held, fall back to per-child moves
  # so one locked file does not strand the rest of the cache.
  param([string]$Source, [string]$Dest, [System.Collections.Generic.List[string]]$Log)
  $reason = ''
  try {
    Move-Item -LiteralPath $Source -Destination $Dest -Force -ErrorAction Stop
    return [pscustomobject]@{ Ok = $true; Reason = '' }
  } catch {
    $reason = $_.Exception.Message
  }

  $item = Get-Item -LiteralPath $Source -Force -ErrorAction SilentlyContinue
  if ($null -eq $item -or -not $item.PSIsContainer) {
    return [pscustomobject]@{ Ok = $false; Reason = $reason }
  }

  $sub = Join-Path $Dest $item.Name
  New-Item -ItemType Directory -Path $sub -Force | Out-Null
  $movedAny = $false
  foreach ($kid in @(Get-ChildItem -LiteralPath $Source -Force -ErrorAction SilentlyContinue)) {
    try {
      Move-Item -LiteralPath $kid.FullName -Destination $sub -Force -ErrorAction Stop
      $movedAny = $true
    } catch {
      $Log.Add(("LOCK {0}  ({1})" -f $kid.FullName, $_.Exception.Message))
    }
  }
  return [pscustomobject]@{ Ok = $movedAny; Reason = $reason }
}

$entries = Get-CacheMapEntries -Path $MapPath

$wanted = @('safe')
if ($IncludeCaution) { $wanted += 'caution' }

$stats = [ordered]@{ moved = 0; failed = 0; skipped = 0; bytes = [int64]0 }
$log = New-Object 'System.Collections.Generic.List[string]'

foreach ($e in $entries) {
  if ($wanted -notcontains [string]$e.level) { continue }
  if ($Ids -and $Ids.Count -gt 0 -and $Ids -notcontains [string]$e.id) { continue }
  if ($e.measure -eq $false) { continue }   # doc-only entry, nothing on disk

  $targets = @(Get-EntryTargets -Entry $e)
  if ($targets.Count -eq 0) { $stats.skipped++; continue }

  $dest = Join-Path $TrashRoot ("{0}-{1}" -f $stamp, $e.id)
  if (-not $DryRun) { New-Item -ItemType Directory -Path $dest -Force | Out-Null }

  foreach ($t in $targets) {
    $size = Get-PathBytes -Path $t.FullName
    if ($size -lt 0) { $size = [int64]0 }

    if ($DryRun) {
      $log.Add(("DRY  {0,10:N1} MB  {1}" -f ($size / 1MB), $t.FullName))
      $stats.moved++
      $stats.bytes += $size
      continue
    }

    $r = Move-IntoTrash -Source $t.FullName -Dest $dest -Log $log
    if ($r.Ok) {
      $log.Add(("MOV  {0,10:N1} MB  {1}" -f ($size / 1MB), $t.FullName))
      $stats.moved++
      $stats.bytes += $size
    } else {
      $log.Add(("FAIL {0,10:N1} MB  {1}  ({2})" -f ($size / 1MB), $t.FullName, $r.Reason))
      $stats.failed++
    }
  }
}

$log | ForEach-Object { Write-Host $_ }
Write-Host ''
Write-Host ("SUMMARY moved={0} failed={1} skipped={2} bytes={3:N2} GB trash={4}" -f `
  $stats.moved, $stats.failed, $stats.skipped, ($stats.bytes / 1GB), $TrashRoot)
