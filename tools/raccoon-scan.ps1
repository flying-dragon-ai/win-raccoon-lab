<#
.SYNOPSIS
  win-raccoon audit engine - read-only cache measurement and classification.
.DESCRIPTION
  Reads tools/cache-map.jsonl (one JSON object per line), expands environment
  variables, measures every present path with robocopy /L (fast, junction-safe)
  and emits METRIC lines plus an optional JSON report.

  Modes
    (default)   scan the map, emit METRIC lines
    -Probe P    classify an arbitrary path with heuristics (map-outside workflow)
    -Render     regenerate references/cache-map.md from the JSONL map
    -Json       emit the full report as JSON instead of METRIC lines

  This script is READ-ONLY. It never deletes, moves, or writes anything except
  the files named by -OutJson and -Render.
#>
[CmdletBinding()]
param(
  [string]$MapPath,
  [string]$OutJson,
  [string]$Probe,
  [string]$ProbeList,
  [switch]$Discover,
  [int]$MinMB = 50,
  [switch]$BigFiles,
  [int]$Depth = 4,
  [switch]$Render,
  [switch]$Json,
  [switch]$NoMeasure,
  [int]$Top = 0,
  [int]$Throttle = 16
)

$ErrorActionPreference = 'Stop'
$script:Here = Split-Path -Parent $PSCommandPath
if (-not $MapPath) { $MapPath = Join-Path $script:Here 'cache-map.jsonl' }
$script:NullDir = 'C:\__raccoon_null__'
$script:Sw = [System.Diagnostics.Stopwatch]::StartNew()

# ---------------------------------------------------------------- measurement

function Measure-Tree {
  param([string]$Path)
  $item = Get-Item -LiteralPath $Path -Force -ErrorAction SilentlyContinue
  if ($null -eq $item) { return -1 }
  if (-not $item.PSIsContainer) { return [int64]$item.Length }

  $rows = New-Object 'System.Collections.Generic.List[int64]'
  $out = & robocopy $Path $script:NullDir /L /S /BYTES /XJ /NFL /NDL /NJH /NP /R:0 /W:0 2>$null
  foreach ($line in $out) {
    if ($line -match ':\s+(\d+)\s+(\d+)\s+(\d+)\s+(\d+)\s+(\d+)\s+(\d+)\s*$') {
      $rows.Add([int64]$matches[1])
    }
  }
  if ($rows.Count -ge 3) { return $rows[2] }
  return 0
}

function Measure-Many {
  param([string[]]$Paths, [int]$Throttle = 8)
  $res = @{}
  if ($null -eq $Paths -or $Paths.Count -eq 0) { return $res }

  $dirs = New-Object 'System.Collections.Generic.List[string]'
  foreach ($p in $Paths) {
    $it = Get-Item -LiteralPath $p -Force -ErrorAction SilentlyContinue
    if ($null -eq $it) { $res[$p] = -1; continue }
    if ($it.PSIsContainer) { $dirs.Add($p) } else { $res[$p] = [int64]$it.Length }
  }
  if ($dirs.Count -eq 0) { return $res }

  $worker = {
    param($p, $nullDir)
    $rows = New-Object 'System.Collections.Generic.List[int64]'
    $out = & robocopy $p $nullDir /L /S /BYTES /XJ /NFL /NDL /NJH /NP /R:0 /W:0 2>$null
    foreach ($l in $out) {
      if ($l -match ':\s+(\d+)\s+(\d+)\s+(\d+)\s+(\d+)\s+(\d+)\s+(\d+)\s*$') { $rows.Add([int64]$matches[1]) }
    }
    if ($rows.Count -ge 3) { return $rows[2] }
    return [int64]0
  }

  $n = [Math]::Min($Throttle, $dirs.Count)
  $pool = [runspacefactory]::CreateRunspacePool(1, $n)
  $pool.Open()
  $jobs = New-Object 'System.Collections.Generic.List[object]'
  foreach ($p in $dirs) {
    $ps = [powershell]::Create()
    $ps.RunspacePool = $pool
    [void]$ps.AddScript($worker).AddArgument($p).AddArgument($script:NullDir)
    $jobs.Add([pscustomobject]@{ Path = $p; PS = $ps; Handle = $ps.BeginInvoke() })
  }
  foreach ($j in $jobs) {
    $v = [int64]0
    try {
      $r = $j.PS.EndInvoke($j.Handle)
      if ($null -ne $r -and $r.Count -gt 0) { $v = [int64]$r[0] }
    } catch { $v = -1 }
    $res[$j.Path] = $v
    $j.PS.Dispose()
  }
  $pool.Close()
  $pool.Dispose()
  return $res
}

function Resolve-RaccoonPath {
  param([string]$Raw)
  $p = [Environment]::ExpandEnvironmentVariables($Raw)
  $p = $p -replace '/', '\'
  if ($p.Length -gt 3) { $p = $p.TrimEnd('\') }
  return $p
}

function Get-TreeStats {
  param([string]$Path, [int]$Limit = 4000)
  $count = 0
  $ext = @{}
  $stack = New-Object 'System.Collections.Generic.Stack[string]'
  $stack.Push($Path)
  while ($stack.Count -gt 0 -and $count -lt $Limit) {
    $d = $stack.Pop()
    $di = $null
    try { $di = [System.IO.DirectoryInfo]::new($d) } catch { continue }
    try {
      foreach ($f in $di.EnumerateFiles()) {
        $count++
        $e = $f.Extension.ToLowerInvariant()
        if ($e -eq '') { $e = '(none)' }
        if ($ext.ContainsKey($e)) { $ext[$e]++ } else { $ext[$e] = 1 }
        if ($count -ge $Limit) { break }
      }
    } catch { }
    if ($count -ge $Limit) { break }
    try {
      foreach ($s in $di.EnumerateDirectories()) {
        if ($s.Attributes -band [System.IO.FileAttributes]::ReparsePoint) { continue }
        $stack.Push($s.FullName)
      }
    } catch { }
  }
  $top = ($ext.GetEnumerator() | Sort-Object Value -Descending |
          Select-Object -First 6 | ForEach-Object { "$($_.Key):$($_.Value)" }) -join ','
  return [pscustomobject]@{ files = $count; ext = $top; extMap = $ext }
}

# ---------------------------------------------------------------- map loading

function Read-Map {
  param([string]$Path)
  if (-not (Test-Path -LiteralPath $Path)) { throw "cache map not found: $Path" }
  $entries = New-Object 'System.Collections.Generic.List[object]'
  $n = 0
  foreach ($line in [System.IO.File]::ReadAllLines($Path)) {
    $n++
    $t = $line.Trim()
    if ($t -eq '' -or $t.StartsWith('#')) { continue }
    try { $o = $t | ConvertFrom-Json } catch { throw "cache-map.jsonl line ${n}: invalid JSON" }
    $o | Add-Member -NotePropertyName _line -NotePropertyValue $n -Force
    $entries.Add($o)
  }
  return $entries
}

# ---------------------------------------------------------------- probe rules

$script:HardForbidden = @(
  '/documents/', '/desktop/', '/pictures/', '/downloads/', '/onedrive',
  '/login data', '/cookies', '/web data', '/local state', '/bookmarks',
  '/msg/attach', '/msg/file', '/msg/video', '/db_storage', '/msgattach',
  '/filestorage/(file|image|video|msgattach|emotion)', '/tdata/',
  '/.ssh', '/.gnupg', '/.aws', '/.kube', '.kdbx',
  '/windows/installer', '/package cache', '/winsxs', '/windows/system32',
  'pagefile.sys', 'hiberfil.sys', '/.vscode/extensions',
  '/jetbrains/[^/]+/plugins', '/.android/avd', '/code/user'
)
$script:HardForbiddenOverride = @(
  '/xwechat_files/[^/]+/cache(/|$)',
  '/wechat files/[^/]+/filestorage/cache(/|$)'
)
$script:CacheNames = @(
  'cache','caches','code cache','gpucache','shadercache','htmlcache','cache2',
  'tmp','temp','log','logs','index','indexes','jcef_cache','compile-server',
  '.cache','.npm','.yarn','.pnpm-store','.nuget','.cargo','.rustup','.conda',
  'pkgs','.m2','go-build','modcache','.gradle','.venv','venv','.tox','.next',
  '.nuxt','.turbo','.parcel-cache','.svelte-kit','.angular','coverage',
  '.nyc_output','.eslintcache','.stylelintcache','__pycache__','.pytest_cache',
  '.mypy_cache','.ruff_cache','node_modules','dist','build','target','out',
  '.terraform','.serverless','.webpack','.rollup.cache','ms-playwright',
  '.puppeteer','.electron','.ivy2','.sbt','crashdumps','wer','d3dscache',
  'dxcache','glcache','thumbcache','inetcache','deliveryoptimization',
  'softwaredistribution','prefetch','minidump','livekernelreports','windows.old',
  'service worker','cachestorage','blob_storage'
)
$script:ForbiddenLeafNames = @(
  'plugins','extensions','users','db_storage','msg','tdata','avd','installer',
  'package cache','winsxs','system32','user','config','settings','profiles',
  'login data','cookies','history','bookmarks','web data','local state',
  'sessions','accounts','credentials','wallet','.ssh','.gnupg','.aws','.kube',
  'documents','desktop','pictures','downloads','onedrive','emotion','msgattach'
)
$script:DbExt = @(
  '.db','.db-wal','.db-journal','.db-shm','.ldb','.sqlite','.sqlite3','.mdb',
  '.pst','.ost','.edb','.kdbx','.wallet'
)
$script:UserContentExt = @(
  '.doc','.docx','.xls','.xlsx','.ppt','.pptx','.pdf','.rtf',
  '.db','.sqlite','.sqlite3','.ldb','.pst','.ost','.eml',
  '.key','.pem','.pfx','.kdbx','.wallet','.ovpn'
)
$script:MediaExt = @(
  '.jpg','.jpeg','.png','.gif','.bmp','.heic','.mp4','.mov','.avi','.mkv',
  '.mp3','.wav','.flac'
)

function Invoke-Probe {
  param([string]$Raw)
  $p = Resolve-RaccoonPath $Raw
  $reasons = New-Object 'System.Collections.Generic.List[string]'

  if (-not (Test-Path -LiteralPath $p)) {
    return [pscustomobject]@{ path = $p; level = 'missing'; bytes = -1; files = 0; ext = ''; reasons = 'path does not exist' }
  }

  $bytes = Measure-Tree $p
  $full = $p.ToLowerInvariant().Replace([char]92, [char]47) + '/'
  $leaf = (Split-Path -Leaf $p).ToLowerInvariant()

  $overridden = $false
  foreach ($rx in $script:HardForbiddenOverride) { if ($full -match $rx) { $overridden = $true; break } }

  if (-not $overridden) {
    foreach ($rx in $script:HardForbidden) {
      if ($full -match $rx) {
        $reasons.Add("hard-forbidden:$rx")
        return [pscustomobject]@{ path = $p; level = 'forbidden'; bytes = $bytes; files = 0; ext = ''; reasons = ($reasons -join '; ') }
      }
    }
  } else {
    $reasons.Add('override:known-cache-under-user-root')
  }

  $stats = Get-TreeStats $p
  $userHits = 0
  $mediaHits = 0
  $totalHits = 0
  foreach ($k in $stats.extMap.Keys) {
    $totalHits += $stats.extMap[$k]
    if ($script:UserContentExt -contains $k) { $userHits += $stats.extMap[$k] }
    if ($script:MediaExt -contains $k) { $mediaHits += $stats.extMap[$k] }
  }
  $userRatio = 0.0
  if ($totalHits -gt 0) { $userRatio = [double]$userHits / [double]$totalHits }
  $mediaRatio = 0.0
  if ($totalHits -gt 0) { $mediaRatio = [double]$mediaHits / [double]$totalHits }

  $dbHit = $false
  foreach ($k in $stats.extMap.Keys) {
    if ($script:DbExt -contains $k) { $dbHit = $true; break }
  }
  $leafForbidden = $script:ForbiddenLeafNames -contains $leaf
  $nameHit = ($script:CacheNames -contains $leaf) -or
             ($leaf -match '(^|[-_.])cache$|^cache$|^caches$|^cache2$|^cachestorage$')

  if ($leafForbidden) { $reasons.Add("leaf-is-user-state:$leaf") }
  if ($dbHit) { $reasons.Add('contains-database-files') }
  if ($nameHit) { $reasons.Add("name-is-cache:$leaf") }
  if ($userRatio -gt 0.30) { $reasons.Add(("user-content-ratio={0:P0}" -f $userRatio)) }
  if ($mediaRatio -gt 0.85) { $reasons.Add(("media-ratio={0:P0}" -f $mediaRatio)) }

  $level = 'caution'
  if ($leafForbidden -or $userRatio -gt 0.60 -or $mediaRatio -gt 0.85) { $level = 'forbidden' }
  elseif ($dbHit -and -not $nameHit) { $level = 'forbidden' }
  elseif ($nameHit -and $userRatio -le 0.30) { $level = 'safe' }
  elseif ($stats.files -eq 0) { $reasons.Add('empty') }

  return [pscustomobject]@{
    path = $p; level = $level; bytes = $bytes; files = $stats.files
    ext = $stats.ext; reasons = ($reasons -join '; ')
  }
}

# ---------------------------------------------------------------- render mode

function Invoke-Render {
  param($Entries, [string]$OutPath)
  $sb = New-Object System.Text.StringBuilder
  [void]$sb.AppendLine('# Windows 缓存地图（win-raccoon）')
  [void]$sb.AppendLine('')
  [void]$sb.AppendLine('> 本文件由 `tools/raccoon-scan.ps1 -Render` 从 `tools/cache-map.jsonl` 生成，不要手改。')
  [void]$sb.AppendLine('> 等级：✅ 安全（可再生，直接可清）｜⚠️ 注意（只清指定子目录/需权衡）｜🚫 别碰')
  [void]$sb.AppendLine('> 所有删除动作：先移入所在盘的 `.raccoon-trash\`；系统级路径交给用户在管理员 PowerShell 执行。')
  [void]$sb.AppendLine('')
  $sections = $Entries | Group-Object -Property section | Sort-Object { $_.Name }
  foreach ($sec in $sections) {
    [void]$sb.AppendLine("## $($sec.Name)")
    [void]$sb.AppendLine('')
    [void]$sb.AppendLine('| 路径 | 是什么 | 等级 | 说明 |')
    [void]$sb.AppendLine('|---|---|---|---|')
    foreach ($e in $sec.Group) {
      $mark = switch ($e.level) { 'safe' { '✅' } 'caution' { '⚠️' } 'forbidden' { '🚫' } default { '?' } }
      $desc = [string]$e.desc
      $note = [string]$e.note
      if ($e.admin) { $note = "需管理员；$note" }
      $shown = ([string]$e.path).Replace([char]47, [char]92)
      [void]$sb.AppendLine("| ``$shown`` | $desc | $mark | $note |")
    }
    [void]$sb.AppendLine('')
  }
  [System.IO.File]::WriteAllText($OutPath, $sb.ToString(), (New-Object System.Text.UTF8Encoding($false)))
  Write-Host "rendered $OutPath"
}

# ---------------------------------------------------------------- main

if ($Discover) {
  $roots = @($env:LOCALAPPDATA, $env:APPDATA, $env:USERPROFILE, 'C:\ProgramData')
  $covered = New-Object 'System.Collections.Generic.List[string]'
  foreach ($e in (Read-Map $MapPath)) {
    $rp = (Resolve-RaccoonPath ([string]$e.path)).ToLowerInvariant()
    $covered.Add($rp)
  }
  $rows = New-Object 'System.Collections.Generic.List[object]'
  foreach ($r in $roots) {
    if (-not (Test-Path -LiteralPath $r)) { continue }
    $kids = @(Get-ChildItem -LiteralPath $r -Directory -Force -ErrorAction SilentlyContinue)
    foreach ($k in $kids) {
      try { if ($k.Attributes -band [System.IO.FileAttributes]::ReparsePoint) { continue } } catch { continue }
      $kl = $k.FullName.ToLowerInvariant()
      $skip = $false
      foreach ($c in $covered) {
        if ($c -eq $kl) { $skip = $true; break }
        if ($kl.StartsWith($c + '\')) { $skip = $true; break }
      }
      if ($skip) { continue }
      $b = Measure-Tree $k.FullName
      if ($b -lt ([int64]$MinMB * 1MB)) { continue }
      $rows.Add([pscustomobject]@{ bytes = $b; path = $k.FullName })
    }
  }
  $rows | Sort-Object bytes -Descending | Select-Object -First $Top |
    ForEach-Object { Write-Host ("DISC|{0}|{1}" -f $_.bytes, $_.path) }
  exit 0
}

if ($BigFiles) {
  $roots = @($env:LOCALAPPDATA, $env:APPDATA, $env:USERPROFILE, 'C:\ProgramData')
  $exts = @('.exe','.msi','.msix','.zip','.7z','.iso','.dmg','.pkg','.cab','.vsix','.nupkg','.appx','.bundle')
  $covered = New-Object 'System.Collections.Generic.List[string]'
  foreach ($e in (Read-Map $MapPath)) {
    $covered.Add((Resolve-RaccoonPath ([string]$e.path)).ToLowerInvariant())
  }
  $rows = New-Object 'System.Collections.Generic.List[object]'
  foreach ($r in $roots) {
    if (-not (Test-Path -LiteralPath $r)) { continue }
    $stack = New-Object 'System.Collections.Generic.Stack[object]'
    $stack.Push([pscustomobject]@{ P = $r; D = 0 })
    while ($stack.Count -gt 0) {
      $cur = $stack.Pop()
      if ($cur.D -ge $Depth) { continue }
      $di = $null
      try { $di = [System.IO.DirectoryInfo]::new($cur.P) } catch { continue }
      try {
        foreach ($f in $di.EnumerateFiles()) {
          if ($exts -notcontains $f.Extension.ToLowerInvariant()) { continue }
          if ($f.Length -lt ([int64]$MinMB * 1MB)) { continue }
          $fl = $f.FullName.ToLowerInvariant()
          $skip = $false
          foreach ($c in $covered) { if ($fl -eq $c -or $fl.StartsWith($c + '\')) { $skip = $true; break } }
          if ($skip) { continue }
          $rows.Add([pscustomobject]@{ bytes = $f.Length; path = $f.FullName })
        }
      } catch { }
      try {
        foreach ($s in $di.EnumerateDirectories()) {
          if ($s.Attributes -band [System.IO.FileAttributes]::ReparsePoint) { continue }
          $stack.Push([pscustomobject]@{ P = $s.FullName; D = $cur.D + 1 })
        }
      } catch { }
    }
  }
  $rows | Sort-Object bytes -Descending | Select-Object -First $Top |
    ForEach-Object { Write-Host ("BIG|{0}|{1}" -f $_.bytes, $_.path) }
  exit 0
}

if ($ProbeList) {
  foreach ($line in [System.IO.File]::ReadAllLines($ProbeList)) {
    $t = $line.Trim()
    if ($t -eq '' -or $t.StartsWith('#')) { continue }
    $r = Invoke-Probe $t
    Write-Host ("PROBE|{0}|{1}|{2}|{3}" -f $r.path, $r.level, $r.bytes, $r.reasons)
  }
  exit 0
}

if ($Probe) {
  $r = Invoke-Probe $Probe
  Write-Host "PROBE path=$($r.path)"
  Write-Host "PROBE level=$($r.level)"
  Write-Host "PROBE bytes=$($r.bytes)"
  Write-Host "PROBE files=$($r.files)"
  Write-Host "PROBE ext=$($r.ext)"
  Write-Host "PROBE reasons=$($r.reasons)"
  exit 0
}

$entries = Read-Map $MapPath

if ($Render) {
  Invoke-Render -Entries $entries -OutPath (Join-Path (Split-Path -Parent $script:Here) 'references\cache-map.md')
  exit 0
}

$report = New-Object 'System.Collections.Generic.List[object]'
$sumSafe = [int64]0
$sumCaution = [int64]0
$sumForbidden = [int64]0
$present = 0
$missing = 0

# pass 1: resolve every entry to concrete targets
$plan = New-Object 'System.Collections.Generic.List[object]'
$allPaths = New-Object 'System.Collections.Generic.List[string]'
foreach ($e in $entries) {
  $resolved = Resolve-RaccoonPath ([string]$e.path)
  $targets = @()
  if ($resolved -match '[*?]') {
    $targets = @(Get-Item -Path $resolved -Force -ErrorAction SilentlyContinue)
  } else {
    $one = Get-Item -LiteralPath $resolved -Force -ErrorAction SilentlyContinue
    if ($null -ne $one) { $targets = @($one) }
  }
  $paths = @()
  foreach ($t in $targets) {
    $paths += $t.FullName
    if (-not $NoMeasure) { $allPaths.Add($t.FullName) }
  }
  $plan.Add([pscustomobject]@{ Entry = $e; Resolved = $resolved; Paths = $paths })
}

# pass 2: measure every target in parallel
$sizes = @{}
if (-not $NoMeasure -and $allPaths.Count -gt 0) {
  $sizes = Measure-Many -Paths $allPaths.ToArray() -Throttle $Throttle
}

# pass 3: assemble the report
foreach ($p in $plan) {
  $e = $p.Entry
  $exists = ($p.Paths.Count -gt 0)
  $bytes = -1
  if ($exists) {
    $present++
    if ($NoMeasure) {
      $bytes = 0
    } else {
      $bytes = [int64]0
      foreach ($tp in $p.Paths) { if ($sizes.ContainsKey($tp)) { $bytes += $sizes[$tp] } }
    }
  } else {
    $missing++
  }
  $level = [string]$e.level
  if ($exists -and $bytes -ge 0) {
    switch ($level) {
      'safe'      { $sumSafe += $bytes }
      'caution'   { $sumCaution += $bytes }
      'forbidden' { $sumForbidden += $bytes }
    }
  }
  $report.Add([pscustomobject]@{
    id = [string]$e.id; section = [string]$e.section; path = $p.Resolved
    level = $level; exists = $exists; bytes = $bytes
    app = [string]$e.app; kind = [string]$e.kind
  })
}

$script:Sw.Stop()
$secs = [math]::Round($script:Sw.Elapsed.TotalSeconds, 2)
$gb = { param($b) [math]::Round($b / 1GB, 3) }

if ($Json) {
  $payload = [pscustomobject]@{
    safe_gb = (& $gb $sumSafe); caution_gb = (& $gb $sumCaution)
    forbidden_gb = (& $gb $sumForbidden); entries = $entries.Count
    present = $present; missing = $missing; scan_seconds = $secs
    items = $report
  }
  $payload | ConvertTo-Json -Depth 6
  exit 0
}

Write-Host ("METRIC safe_gb={0}" -f (& $gb $sumSafe))
Write-Host ("METRIC caution_gb={0}" -f (& $gb $sumCaution))
Write-Host ("METRIC forbidden_gb={0}" -f (& $gb $sumForbidden))
Write-Host ("METRIC entries={0}" -f $entries.Count)
Write-Host ("METRIC present={0}" -f $present)
Write-Host ("METRIC missing={0}" -f $missing)
Write-Host ("METRIC scan_seconds={0}" -f $secs)

if ($Top -gt 0) {
  Write-Host ''
  Write-Host "--- top $Top by bytes ---"
  $report | Where-Object { $_.exists -and $_.bytes -gt 0 } |
    Sort-Object bytes -Descending | Select-Object -First $Top |
    ForEach-Object { Write-Host ("{0,10:N1} MB  {1,-9} {2}" -f ($_.bytes / 1MB), $_.level, $_.path) }
}

if ($OutJson) {
  $report | ConvertTo-Json -Depth 5 | Set-Content -LiteralPath $OutJson -Encoding UTF8
}
