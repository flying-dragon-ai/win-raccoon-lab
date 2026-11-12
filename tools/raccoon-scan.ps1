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
    -DumpRules  print the probe tables as JSON (used by the checks gate)

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
  [switch]$DumpRules,
  [int]$Top = 0,
  [int]$Throttle = 16
)

$ErrorActionPreference = 'Stop'
# Emit UTF-8 even when stdout is redirected. Without this, `-Json > report.json`
# writes GBK bytes on a zh-CN console and the result is not valid JSON.
[Console]::OutputEncoding = New-Object System.Text.UTF8Encoding($false)

Import-Module (Join-Path $PSScriptRoot 'Raccoon.Common.psm1') -Force

$script:Here = $PSScriptRoot
if (-not $MapPath) { $MapPath = Join-Path $script:Here 'cache-map.jsonl' }
$script:Sw = [System.Diagnostics.Stopwatch]::StartNew()

# ---------------------------------------------------------------- thresholds
# Probe verdicts. These mirror fixtures/forbidden.json; the checks gate asserts
# the scanner is never more permissive than the frozen policy.
$script:MaxUserContentRatio    = 0.30  # above this a directory holds user documents
$script:ForbidUserContentRatio = 0.60  # above this it is user state, not a cache
$script:ForbidMediaRatio       = 0.85  # browser caches are legitimately image-heavy
$script:ExtSampleLimit         = 4000  # files sampled per directory for the ratios
$script:ExtSummaryTop          = 6     # extensions listed in a probe's ext field
$script:DiscoverRoots = @($env:LOCALAPPDATA, $env:APPDATA, $env:USERPROFILE, 'C:\ProgramData')

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
  'service worker','cachestorage','blob_storage','pending','runtimes','bundles',
  'reshub','update','installer','crx_cache','component_crx_cache'
)
$script:InstallerExt = @(
  '.exe','.msi','.msix','.zip','.7z','.iso','.cab','.vsix','.nupkg','.appx','.bundle'
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

# ---------------------------------------------------------------- probe

function New-ProbeResult {
  param([string]$Path, [string]$Level, [int64]$Bytes, [int]$Files, [string]$Ext, $Reasons)
  return [pscustomobject]@{
    path = $Path; level = $Level; bytes = $Bytes; files = $Files
    ext = $Ext; reasons = ($Reasons -join '; ')
  }
}

function Test-HardForbidden {
  # Returns $true when the path is user state no matter what it is called.
  # Overrides are checked first: a known cache under a user root is allowed.
  param([string]$Full, [System.Collections.Generic.List[string]]$Reasons)
  foreach ($rx in $script:HardForbiddenOverride) {
    if ($Full -match $rx) {
      $Reasons.Add('override:known-cache-under-user-root')
      return $false
    }
  }
  foreach ($rx in $script:HardForbidden) {
    if ($Full -match $rx) {
      $Reasons.Add("hard-forbidden:$rx")
      return $true
    }
  }
  return $false
}

function Get-ProbeLevel {
  param($Profile, [string]$Leaf, [System.Collections.Generic.List[string]]$Reasons)
  $leafForbidden = $script:ForbiddenLeafNames -contains $Leaf
  $nameHit = ($script:CacheNames -contains $Leaf) -or
             ($Leaf -match '(^|[-_.])cache$|^cache$|^caches$|^cache2$|^cachestorage$') -or
             ($Leaf -match '-updater$')

  if ($leafForbidden) { $Reasons.Add("leaf-is-user-state:$Leaf") }
  if ($Profile.HasDb) { $Reasons.Add('contains-database-files') }
  if ($nameHit) { $Reasons.Add("name-is-cache:$Leaf") }
  if ($Profile.UserRatio -gt $script:MaxUserContentRatio) {
    $Reasons.Add(("user-content-ratio={0:P0}" -f $Profile.UserRatio))
  }
  if ($Profile.MediaRatio -gt $script:ForbidMediaRatio) {
    $Reasons.Add(("media-ratio={0:P0}" -f $Profile.MediaRatio))
  }

  if ($leafForbidden -or $Profile.UserRatio -gt $script:ForbidUserContentRatio -or
      $Profile.MediaRatio -gt $script:ForbidMediaRatio) { return 'forbidden' }
  if ($Profile.HasDb -and -not $nameHit) { return 'forbidden' }
  if ($nameHit -and $Profile.UserRatio -le $script:MaxUserContentRatio) { return 'safe' }
  if ($Profile.Files -eq 0) { $Reasons.Add('empty') }
  return 'caution'
}

function Invoke-Probe {
  param([string]$Raw)
  $p = Resolve-RaccoonPath -Raw $Raw
  $reasons = New-Object 'System.Collections.Generic.List[string]'

  if (-not (Test-Path -LiteralPath $p)) {
    return New-ProbeResult -Path $p -Level 'missing' -Bytes -1 -Files 0 -Ext '' -Reasons 'path does not exist'
  }

  $item = Get-Item -LiteralPath $p -Force -ErrorAction SilentlyContinue
  if ($null -ne $item -and -not $item.PSIsContainer) {
    $ext = $item.Extension.ToLowerInvariant()
    $parentLeaf = (Split-Path -Leaf (Split-Path -Parent $p)).ToLowerInvariant()
    $bytes = [int64]$item.Length
    if (($script:InstallerExt -contains $ext) -and ($parentLeaf -match '-updater$|^update|^pending')) {
      return New-ProbeResult -Path $p -Level 'safe' -Bytes $bytes -Files 1 -Ext $ext -Reasons "installer-in-updater:$parentLeaf"
    }
    return New-ProbeResult -Path $p -Level 'caution' -Bytes $bytes -Files 1 -Ext $ext -Reasons 'single-file'
  }

  $bytes = Get-RobocopyBytes -Path $p
  $full = $p.ToLowerInvariant().Replace([char]92, [char]47) + '/'
  $leaf = (Split-Path -Leaf $p).ToLowerInvariant()

  if (Test-HardForbidden -Full $full -Reasons $reasons) {
    return New-ProbeResult -Path $p -Level 'forbidden' -Bytes $bytes -Files 0 -Ext '' -Reasons $reasons
  }

  $profile = Get-ContentProfile -Path $p -UserExt $script:UserContentExt -MediaExt $script:MediaExt `
                                -DbExt $script:DbExt -Limit $script:ExtSampleLimit
  $level = Get-ProbeLevel -Profile $profile -Leaf $leaf -Reasons $reasons
  return New-ProbeResult -Path $p -Level $level -Bytes $bytes -Files $profile.Files `
                         -Ext $profile.ExtSummary -Reasons $reasons
}

# ---------------------------------------------------------------- render mode

function Add-MapSection {
  param([System.Text.StringBuilder]$Sb, $Section)
  [void]$Sb.AppendLine("## $($Section.Name)")
  [void]$Sb.AppendLine('')
  [void]$Sb.AppendLine('| 路径 | 是什么 | 等级 | 说明 |')
  [void]$Sb.AppendLine('|---|---|---|---|')
  foreach ($e in $Section.Group) {
    $mark = switch ($e.level) { 'safe' { '✅' } 'caution' { '⚠️' } 'forbidden' { '🚫' } default { '?' } }
    $note = [string]$e.note
    if ($e.admin) { $note = "需管理员；$note" }
    $shown = ([string]$e.path).Replace([char]47, [char]92)
    [void]$Sb.AppendLine("| ``$shown`` | $([string]$e.desc) | $mark | $note |")
  }
  [void]$Sb.AppendLine('')
}

function Invoke-Render {
  param($Entries, [string]$OutPath)
  $sb = New-Object System.Text.StringBuilder
  [void]$sb.AppendLine('# Windows 缓存地图（win-raccoon）')
  [void]$sb.AppendLine('')
  [void]$sb.AppendLine('> 本文件由 `tools/raccoon-scan.ps1 -Render` 从 `tools/cache-map.jsonl` 生成，不要手改。')
  [void]$sb.AppendLine('> 等级：✅ 安全（可再生，直接可清）｜⚠️ 注意（只清指定子目录/需权衡）｜🚫 别碰')
  [void]$sb.AppendLine('> 所有删除动作：先移入所在盘的 `.raccoon-trash\`；系统级路径交给用户在管理员 PowerShell 执行。')
  [void]$sb.AppendLine('')

  foreach ($sec in ($Entries | Group-Object -Property section | Sort-Object { $_.Name })) {
    Add-MapSection -Sb $sb -Section $sec
  }

  # Sections 6 and 7 are static guidance, not map data.
  $tail = @(
    '## 6. 系统官方入口（优先推荐用户自己跑）',
    '',
    '| 入口 | 说明 |',
    '|---|---|',
    '| 设置 → 系统 → 存储 → 临时文件 / 存储感知 | 官方一站式；⚠️ 别勾"下载" |',
    '| `cleanmgr`（磁盘清理） | 含"以前的 Windows 安装""传递优化文件" |',
    '| `Dism.exe /Online /Cleanup-Image /StartComponentCleanup` | 管理员；安全压缩组件存储 |',
    '| `Delete-DeliveryOptimizationCache -Force` | 管理员 PowerShell |',
    '| `Clear-RecycleBin -Force` | 清空回收站=真删，仅当用户明确要求 |',
    '',
    '## 7. 地图外路径的处理流程',
    '',
    '1. `raccoon-scan.ps1 -Probe <path>` 拿初判与理由。',
    '2. 查官方文档/源码，确认是"可再生缓存"。',
    '3. 不在禁止清单里 → 可以提议给用户；否则标"未知，不建议动"。',
    '4. 确认后写进 `tools/cache-map.jsonl`，跑 `raccoon-validate.ps1` 过闸门。',
    ''
  )
  foreach ($line in $tail) { [void]$sb.AppendLine($line) }

  [System.IO.File]::WriteAllText($OutPath, $sb.ToString(), (New-Object System.Text.UTF8Encoding($false)))
  Write-Host "rendered $OutPath"
}

# ---------------------------------------------------------------- discovery

function Get-CoveredPaths {
  param($Entries)
  $covered = New-Object 'System.Collections.Generic.List[string]'
  foreach ($e in $Entries) {
    $covered.Add((Resolve-RaccoonPath -Raw ([string]$e.path)).ToLowerInvariant())
  }
  return $covered
}

function Test-Covered {
  param([string]$Path, $Covered)
  $p = $Path.ToLowerInvariant()
  foreach ($c in $Covered) {
    if ($p -eq $c -or $p.StartsWith($c + '\')) { return $true }
  }
  return $false
}

function Invoke-Discover {
  param($Entries, [int]$MinMB, [int]$Top)
  $covered = Get-CoveredPaths -Entries $Entries
  $rows = New-Object 'System.Collections.Generic.List[object]'
  foreach ($root in $script:DiscoverRoots) {
    if (-not (Test-Path -LiteralPath $root)) { continue }
    foreach ($kid in @(Get-ChildItem -LiteralPath $root -Directory -Force -ErrorAction SilentlyContinue)) {
      try { if ($kid.Attributes -band [System.IO.FileAttributes]::ReparsePoint) { continue } } catch { continue }
      if (Test-Covered -Path $kid.FullName -Covered $covered) { continue }
      $bytes = Get-RobocopyBytes -Path $kid.FullName
      if ($bytes -lt ([int64]$MinMB * 1MB)) { continue }
      $rows.Add([pscustomobject]@{ bytes = $bytes; path = $kid.FullName })
    }
  }
  $rows | Sort-Object bytes -Descending | Select-Object -First $Top |
    ForEach-Object { Write-Host ("DISC|{0}|{1}" -f $_.bytes, $_.path) }
}

function Invoke-BigFiles {
  param($Entries, [int]$MinMB, [int]$Depth, [int]$Top)
  $covered = Get-CoveredPaths -Entries $Entries
  $rows = New-Object 'System.Collections.Generic.List[object]'
  foreach ($root in $script:DiscoverRoots) {
    if (-not (Test-Path -LiteralPath $root)) { continue }
    $stack = New-Object 'System.Collections.Generic.Stack[object]'
    $stack.Push([pscustomobject]@{ P = $root; D = 0 })
    while ($stack.Count -gt 0) {
      $cur = $stack.Pop()
      if ($cur.D -ge $Depth) { continue }
      $di = $null
      try { $di = [System.IO.DirectoryInfo]::new($cur.P) } catch { continue }
      try {
        foreach ($f in $di.EnumerateFiles()) {
          if ($script:InstallerExt -notcontains $f.Extension.ToLowerInvariant()) { continue }
          if ($f.Length -lt ([int64]$MinMB * 1MB)) { continue }
          if (Test-Covered -Path $f.FullName -Covered $covered) { continue }
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
}

# ---------------------------------------------------------------- scan

function ConvertTo-GiB {
  param([int64]$Bytes)
  return [math]::Round($Bytes / 1GB, 3)
}

function Resolve-EntryTargets {
  # Expands one map entry into the concrete filesystem objects it names.
  param($Entry)
  $resolved = Resolve-RaccoonPath -Raw ([string]$Entry.path)
  if ($resolved -match '[*?]') {
    $targets = @(Get-Item -Path $resolved -Force -ErrorAction SilentlyContinue)
    return [pscustomobject]@{ Resolved = $resolved; Targets = $targets }
  }
  $one = Get-Item -LiteralPath $resolved -Force -ErrorAction SilentlyContinue
  $targets = @()
  if ($null -ne $one) { $targets = @($one) }
  return [pscustomobject]@{ Resolved = $resolved; Targets = $targets }
}

function Get-EntryBytes {
  # -1 means "not measured" (missing, or measure:false); 0 means "measured empty".
  param($Entry, $Paths, $Sizes, [switch]$NoMeasure)
  if ($Entry.measure -eq $false) { return [int64]-1 }   # doc-only entry, never measured
  if ($NoMeasure) { return [int64]0 }
  $bytes = [int64]0
  foreach ($tp in $Paths) { if ($Sizes.ContainsKey($tp)) { $bytes += $Sizes[$tp] } }
  return $bytes
}

# ---------------------------------------------------------------- main

if ($Discover) {
  Invoke-Discover -Entries (Get-CacheMapEntries -Path $MapPath) -MinMB $MinMB -Top $Top
  exit 0
}

if ($BigFiles) {
  Invoke-BigFiles -Entries (Get-CacheMapEntries -Path $MapPath) -MinMB $MinMB -Depth $Depth -Top $Top
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
  foreach ($field in 'path', 'level', 'bytes', 'files', 'ext', 'reasons') {
    Write-Host "PROBE $field=$($r.$field)"
  }
  exit 0
}

if ($DumpRules) {
  # Introspection for the checks gate: the probe tables must never be more
  # permissive than fixtures/forbidden.json.
  [pscustomobject]@{
    hard_forbidden = $script:HardForbidden
    overrides = $script:HardForbiddenOverride
    user_content_ext = $script:UserContentExt
    media_ext = $script:MediaExt
    max_user_content_ratio = $script:MaxUserContentRatio
    forbid_user_content_ratio = $script:ForbidUserContentRatio
    forbid_media_ratio = $script:ForbidMediaRatio
  } | ConvertTo-Json -Depth 4
  exit 0
}

$entries = Get-CacheMapEntries -Path $MapPath

if ($Render) {
  Invoke-Render -Entries $entries -OutPath (Join-Path (Split-Path -Parent $script:Here) 'references\cache-map.md')
  exit 0
}

# pass 1: resolve every entry to concrete targets
$plan = New-Object 'System.Collections.Generic.List[object]'
$allPaths = New-Object 'System.Collections.Generic.List[string]'
foreach ($e in $entries) {
  $r = Resolve-EntryTargets -Entry $e
  $paths = New-Object 'System.Collections.Generic.List[string]'
  foreach ($t in $r.Targets) {
    $paths.Add($t.FullName)
    if (-not $NoMeasure -and $e.measure -ne $false) { $allPaths.Add($t.FullName) }
  }
  $plan.Add([pscustomobject]@{ Entry = $e; Resolved = $r.Resolved; Paths = $paths.ToArray() })
}

# pass 2: measure every target in parallel
$sizes = @{}
if (-not $NoMeasure -and $allPaths.Count -gt 0) {
  $sizes = Get-RobocopyBytesMany -Paths $allPaths.ToArray() -Throttle $Throttle
}

# pass 3: assemble the report
$report = New-Object 'System.Collections.Generic.List[object]'
$sumSafe = [int64]0
$sumCaution = [int64]0
$sumForbidden = [int64]0
$present = 0
$missing = 0

foreach ($p in $plan) {
  $e = $p.Entry
  $exists = ($p.Paths.Count -gt 0)
  $bytes = [int64]-1
  if ($exists) {
    $present++
    $bytes = Get-EntryBytes -Entry $e -Paths $p.Paths -Sizes $sizes -NoMeasure:$NoMeasure
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

if ($Json) {
  $payload = [pscustomobject]@{
    safe_gb = (ConvertTo-GiB $sumSafe); caution_gb = (ConvertTo-GiB $sumCaution)
    forbidden_gb = (ConvertTo-GiB $sumForbidden); entries = $entries.Count
    present = $present; missing = $missing; scan_seconds = $secs
    items = $report
  }
  $payload | ConvertTo-Json -Depth 6
  exit 0
}

$metrics = [ordered]@{
  safe_gb = (ConvertTo-GiB $sumSafe)
  caution_gb = (ConvertTo-GiB $sumCaution)
  forbidden_gb = (ConvertTo-GiB $sumForbidden)
  entries = $entries.Count
  present = $present
  missing = $missing
  scan_seconds = $secs
}
foreach ($k in $metrics.Keys) { Write-Host ("METRIC {0}={1}" -f $k, $metrics[$k]) }

if ($Top -gt 0) {
  Write-Host ''
  Write-Host "--- top $Top by bytes ---"
  $report | Where-Object { $_.exists -and $_.bytes -gt 0 } |
    Sort-Object bytes -Descending | Select-Object -First $Top |
    ForEach-Object { Write-Host ("{0,10:N1} MB  {1,-9} {2}" -f ($_.bytes / 1MB), $_.level, $_.path) }
}

if ($OutJson) {
  $json = $report | ConvertTo-Json -Depth 5
  [System.IO.File]::WriteAllText($OutJson, $json, (New-Object System.Text.UTF8Encoding($false)))
}
