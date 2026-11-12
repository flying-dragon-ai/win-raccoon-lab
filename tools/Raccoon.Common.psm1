# Raccoon.Common.psm1 - shared primitives for the win-raccoon tools.
#
# ASCII only, on purpose: raccoon-scan.ps1 imports this module and the checks
# gate asserts the scanner stays read-only. Nothing in here deletes, moves or
# writes anything.
#
# Everything that used to be copy-pasted across scan / clean / validate lives
# here: path resolution, map loading, the extension walker, robocopy
# measurement, and the runspace pool.

$script:NullDir = 'C:\__raccoon_null__'
# robocopy /L needs a destination argument. /L means "list only", so this path is
# never created and never written to; it only has to be syntactically valid.

$script:RobocopyBytesRow = 2
# robocopy's summary block ends with three rows - dirs, files, bytes - and the
# byte count is the third. Each row looks like "  Total  Copied  Skipped ...".

$script:MeasureDirBlock = {
  param($Path, $NullDir, $BytesRow)
  $rows = New-Object 'System.Collections.Generic.List[int64]'
  $out = & robocopy $Path $NullDir /L /S /BYTES /XJ /NFL /NDL /NJH /NP /R:0 /W:0 2>$null
  foreach ($line in $out) {
    if ($line -match ':\s+(\d+)\s+(\d+)\s+(\d+)\s+(\d+)\s+(\d+)\s+(\d+)\s*$') {
      $rows.Add([int64]$matches[1])
    }
  }
  if ($rows.Count -gt $BytesRow) { return $rows[$BytesRow] }
  return [int64]0
}
# A scriptblock rather than a function because the same body has to run inside
# runspace-pool workers, where module functions are not loaded. Invoke-Parallel
# ships it across with .ToString(), so it must stay self-contained.

function Resolve-RaccoonPath {
  param(
    [string]$Raw,
    [ValidateSet('\', '/')][string]$Separator = '\'
  )
  $p = [Environment]::ExpandEnvironmentVariables($Raw)
  $p = $p.Replace([char]92, [char]47)
  if ($Separator -eq '\') { $p = $p.Replace([char]47, [char]92) }
  # Length 3 is "C:\" - trimming it would leave a bare drive letter.
  if ($p.Length -gt 3) { $p = $p.TrimEnd($Separator) }
  return $p
}

function Read-CacheMap {
  # Returns { Entries, Errors }. Errors is a list of "line N: ..." strings, so a
  # caller can either fail fast (Get-CacheMapEntries) or report every bad line
  # and keep going (the checks gate).
  param([string]$Path)
  if (-not (Test-Path -LiteralPath $Path)) { throw "cache map not found: $Path" }
  $entries = New-Object 'System.Collections.Generic.List[object]'
  $errors = New-Object 'System.Collections.Generic.List[string]'
  $n = 0
  foreach ($line in [System.IO.File]::ReadAllLines($Path)) {
    $n++
    $t = $line.Trim()
    if ($t -eq '' -or $t.StartsWith('#')) { continue }
    try { $o = $t | ConvertFrom-Json } catch {
      $errors.Add("cache-map.jsonl line ${n}: invalid JSON")
      continue
    }
    $o | Add-Member -NotePropertyName _line -NotePropertyValue $n -Force
    $entries.Add($o)
  }
  return [pscustomobject]@{ Entries = $entries; Errors = $errors }
}

function Get-CacheMapEntries {
  # Strict variant: any malformed line aborts the run.
  param([string]$Path)
  $map = Read-CacheMap -Path $Path
  if ($map.Errors.Count -gt 0) { throw $map.Errors[0] }
  return $map.Entries
}

function Get-ExtHistogram {
  param([string]$Path, [int]$Limit = 4000)
  $count = 0
  $hist = @{}
  $stack = New-Object 'System.Collections.Generic.Stack[string]'
  $stack.Push($Path)
  while ($stack.Count -gt 0 -and $count -lt $Limit) {
    $d = $stack.Pop()
    $di = $null
    try { $di = [System.IO.DirectoryInfo]::new($d) } catch { continue }  # vanished between push and pop
    try {
      foreach ($f in $di.EnumerateFiles()) {
        $count++
        $x = $f.Extension.ToLowerInvariant()
        if ($x -eq '') { $x = '(none)' }
        if ($hist.ContainsKey($x)) { $hist[$x]++ } else { $hist[$x] = 1 }
        if ($count -ge $Limit) { break }
      }
    } catch { }  # access denied on one directory: skip it, keep walking
    if ($count -ge $Limit) { break }
    try {
      foreach ($s in $di.EnumerateDirectories()) {
        # Never follow junctions or symlinks: they would double count and can loop.
        if ($s.Attributes -band [System.IO.FileAttributes]::ReparsePoint) { continue }
        $stack.Push($s.FullName)
      }
    } catch { }
  }
  return [pscustomobject]@{ Files = $count; Hist = $hist }
}

function Get-ContentProfile {
  param(
    [string]$Path,
    [string[]]$UserExt = @(),
    [string[]]$MediaExt = @(),
    [string[]]$DbExt = @(),
    [int]$Limit = 4000
  )
  $h = Get-ExtHistogram -Path $Path -Limit $Limit
  $user = 0
  $media = 0
  $hasDb = $false
  foreach ($k in $h.Hist.Keys) {
    $n = $h.Hist[$k]
    if ($UserExt -contains $k) { $user += $n }
    if ($MediaExt -contains $k) { $media += $n }
    if ($DbExt -contains $k) { $hasDb = $true }
  }
  $userRatio = 0.0
  $mediaRatio = 0.0
  if ($h.Files -gt 0) {
    $userRatio = [double]$user / [double]$h.Files
    $mediaRatio = [double]$media / [double]$h.Files
  }
  $summary = ($h.Hist.GetEnumerator() | Sort-Object Value -Descending |
              Select-Object -First 6 | ForEach-Object { "$($_.Key):$($_.Value)" }) -join ','
  return [pscustomobject]@{
    Files = $h.Files; Hist = $h.Hist; ExtSummary = $summary
    UserRatio = $userRatio; MediaRatio = $mediaRatio; HasDb = $hasDb
  }
}

function Get-RobocopyBytes {
  param([string]$Path)
  return (& $script:MeasureDirBlock $Path $script:NullDir $script:RobocopyBytesRow)
}

function Get-PathBytes {
  param([string]$Path)
  $item = Get-Item -LiteralPath $Path -Force -ErrorAction SilentlyContinue
  if ($null -eq $item) { return [int64]-1 }
  if (-not $item.PSIsContainer) { return [int64]$item.Length }
  return (Get-RobocopyBytes -Path $Path)
}

function Invoke-Parallel {
  param(
    [string[]]$Items,
    [scriptblock]$Worker,
    [object[]]$WorkerArgs = @(),
    [int]$Throttle = 8
  )
  $results = @{}
  if ($null -eq $Items -or $Items.Count -eq 0) { return $results }

  $width = [Math]::Min($Throttle, $Items.Count)
  $pool = [runspacefactory]::CreateRunspacePool(1, $width)
  $pool.Open()
  $jobs = New-Object 'System.Collections.Generic.List[object]'
  foreach ($item in $Items) {
    $ps = [powershell]::Create()
    $ps.RunspacePool = $pool
    [void]$ps.AddScript($Worker.ToString())
    [void]$ps.AddArgument($item)
    foreach ($a in $WorkerArgs) { [void]$ps.AddArgument($a) }
    $jobs.Add([pscustomobject]@{ Item = $item; PS = $ps; Handle = $ps.BeginInvoke() })
  }
  foreach ($job in $jobs) {
    $value = [int64]-1
    try {
      $r = $job.PS.EndInvoke($job.Handle)
      if ($null -ne $r -and $r.Count -gt 0) { $value = [int64]$r[0] }
    } catch { $value = -1 }  # worker died: report -1, never a fake 0
    $results[$job.Item] = $value
    $job.PS.Dispose()
  }
  $pool.Close()
  $pool.Dispose()
  return $results
}

function Get-RobocopyBytesMany {
  param([string[]]$Paths, [int]$Throttle = 16)
  $res = @{}
  if ($null -eq $Paths -or $Paths.Count -eq 0) { return $res }

  $dirs = New-Object 'System.Collections.Generic.List[string]'
  foreach ($p in $Paths) {
    $it = Get-Item -LiteralPath $p -Force -ErrorAction SilentlyContinue
    if ($null -eq $it) { $res[$p] = [int64]-1; continue }
    if ($it.PSIsContainer) { $dirs.Add($p) } else { $res[$p] = [int64]$it.Length }
  }
  if ($dirs.Count -eq 0) { return $res }

  $measured = Invoke-Parallel -Items $dirs.ToArray() -Worker $script:MeasureDirBlock `
                              -WorkerArgs @($script:NullDir, $script:RobocopyBytesRow) -Throttle $Throttle
  foreach ($k in $measured.Keys) { $res[$k] = $measured[$k] }
  return $res
}

function Test-IsUnder {
  param([string]$Path, [string]$Root)
  $p = $Path.ToLowerInvariant()
  $r = $Root.ToLowerInvariant()
  return ($p -eq $r) -or $p.StartsWith($r + '\') -or $p.StartsWith($r + '/')
}

Export-ModuleMember -Function Resolve-RaccoonPath, Read-CacheMap, Get-CacheMapEntries,
  Get-ExtHistogram,
  Get-ContentProfile, Get-RobocopyBytes, Get-PathBytes, Invoke-Parallel,
  Get-RobocopyBytesMany, Test-IsUnder
