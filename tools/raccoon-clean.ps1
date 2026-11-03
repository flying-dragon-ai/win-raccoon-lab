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
$script:Here = Split-Path -Parent $PSCommandPath
if (-not $MapPath) { $MapPath = Join-Path $script:Here 'cache-map.jsonl' }
if (-not $TrashRoot) { $TrashRoot = Join-Path $env:USERPROFILE '.raccoon-trash' }
$stamp = Get-Date -Format 'yyyyMMdd-HHmm'

function Resolve-P { param([string]$Raw)
  $p = [Environment]::ExpandEnvironmentVariables($Raw).Replace([char]92, [char]47)
  if ($p.Length -gt 3) { $p = $p.TrimEnd('/') }
  return $p
}

$entries = New-Object 'System.Collections.Generic.List[object]'
foreach ($line in [System.IO.File]::ReadAllLines($MapPath)) {
  $t = $line.Trim()
  if ($t -eq '' -or $t.StartsWith('#')) { continue }
  $entries.Add(($t | ConvertFrom-Json))
}

$wanted = @('safe')
if ($IncludeCaution) { $wanted += 'caution' }

$moved = 0; $failed = 0; $bytesMoved = [int64]0; $skipped = 0
$log = New-Object 'System.Collections.Generic.List[string]'

foreach ($e in $entries) {
  if ($wanted -notcontains [string]$e.level) { continue }
  if ($Ids -and $Ids.Count -gt 0 -and $Ids -notcontains [string]$e.id) { continue }
  if ($e.measure -eq $false) { continue }

  $resolved = Resolve-P ([string]$e.path)
  $targets = @()
  if ($resolved -match '[*?]') {
    $targets = @(Get-Item -Path $resolved -Force -ErrorAction SilentlyContinue)
  } else {
    $one = Get-Item -LiteralPath $resolved -Force -ErrorAction SilentlyContinue
    if ($null -ne $one) { $targets = @($one) }
  }
  if ($targets.Count -eq 0) { $skipped++; continue }

  $dest = Join-Path $TrashRoot ("{0}-{1}" -f $stamp, $e.id)
  if (-not $DryRun) { New-Item -ItemType Directory -Path $dest -Force | Out-Null }

  foreach ($t in $targets) {
    $size = 0
    if ($t.PSIsContainer) {
      $size = [int64]0
      try { $size = (& robocopy $t.FullName 'C:\__raccoon_null__' /L /S /BYTES /XJ /NFL /NDL /NJH /NP /R:0 /W:0 2>$null |
             ForEach-Object { if ($_ -match ':\s+(\d+)\s+(\d+)\s+(\d+)\s+(\d+)\s+(\d+)\s+(\d+)\s*$') { [int64]$matches[1] } })[2] } catch { }
    } else { $size = [int64]$t.Length }

    if ($DryRun) {
      $log.Add(("DRY  {0,10:N1} MB  {1}" -f ($size/1MB), $t.FullName)); $moved++; $bytesMoved += $size; continue
    }

    $ok = $false
    try { Move-Item -LiteralPath $t.FullName -Destination $dest -Force -ErrorAction Stop; $ok = $true } catch { }

    if (-not $ok -and $t.PSIsContainer) {
      # whole-dir move failed (handle held): fall back to per-child moves
      $sub = Join-Path $dest $t.Name
      New-Item -ItemType Directory -Path $sub -Force | Out-Null
      $kids = @(Get-ChildItem -LiteralPath $t.FullName -Force -ErrorAction SilentlyContinue)
      foreach ($k in $kids) {
        try { Move-Item -LiteralPath $k.FullName -Destination $sub -Force -ErrorAction Stop; $ok = $true }
        catch { $log.Add(("LOCK {0}" -f $k.FullName)) }
      }
    }

    if ($ok) { $log.Add(("MOV  {0,10:N1} MB  {1}" -f ($size/1MB), $t.FullName)); $moved++; $bytesMoved += $size }
    else { $log.Add(("FAIL {0,10:N1} MB  {1}" -f ($size/1MB), $t.FullName)); $failed++ }
  }
}

$log | ForEach-Object { Write-Host $_ }
Write-Host ''
Write-Host ("SUMMARY moved={0} failed={1} skipped={2} bytes={3:N2} GB trash={4}" -f $moved, $failed, $skipped, ($bytesMoved/1GB), $TrashRoot)
