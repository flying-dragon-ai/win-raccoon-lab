# raccoon-validate.ps1 - checks gate for the win-raccoon autoresearch loop.
# ASCII only. Exit 1 on any FAIL.
[CmdletBinding()]
param([string]$Root)
$ErrorActionPreference = 'Stop'
if (-not $Root) { $Root = Split-Path -Parent $PSScriptRoot }

$script:Fail = 0
function Fail { param($m) Write-Host "FAIL $m"; $script:Fail++ }
function Ok   { param($m) Write-Host "ok   $m" }
function Warn { param($m) Write-Host "warn $m" }

$mapPath  = Join-Path $Root 'tools/cache-map.jsonl'
$scanPath = Join-Path $Root 'tools/raccoon-scan.ps1'
$polPath  = Join-Path $Root 'fixtures/forbidden.json'
$manPath  = Join-Path $Root 'fixtures/manifest.json'
$treeRoot = Join-Path $Root 'fixtures/tree'

$pol = Get-Content -Raw -LiteralPath $polPath | ConvertFrom-Json

function To-Slash {
  param([string]$p)
  $x = [Environment]::ExpandEnvironmentVariables($p).Replace([char]92, [char]47)
  if ($x.Length -gt 3) { $x = $x.TrimEnd('/') }
  return $x
}

# ---------------------------------------------------------------- 1. schema
$entries = New-Object 'System.Collections.Generic.List[object]'
$n = 0
foreach ($line in [System.IO.File]::ReadAllLines($mapPath)) {
  $n++
  $t = $line.Trim()
  if ($t -eq '' -or $t.StartsWith('#')) { continue }
  try { $o = $t | ConvertFrom-Json } catch { Fail "map line ${n}: invalid JSON"; continue }
  foreach ($f in 'id','section','path','level','app','kind','desc') {
    $v = $o.PSObject.Properties[$f]
    if ($null -eq $v -or [string]::IsNullOrWhiteSpace([string]$v.Value)) { Fail "map line ${n}: missing field '$f'" }
  }
  if (@('safe','caution','forbidden') -notcontains [string]$o.level) { Fail "map line ${n}: bad level '$($o.level)'" }
  $entries.Add($o)
}
if ($script:Fail -eq 0) { Ok "schema: $($entries.Count) entries" }

# ---------------------------------------------------------------- 2. duplicates
$ids = @{}
$paths = @{}
foreach ($e in $entries) {
  if ($ids.ContainsKey($e.id)) { Fail "duplicate id '$($e.id)'" } else { $ids[$e.id] = 1 }
  $k = (To-Slash ([string]$e.path)).ToLowerInvariant()
  if ($paths.ContainsKey($k)) { Fail "duplicate path '$k' (ids: $($paths[$k]), $($e.id))" } else { $paths[$k] = $e.id }
}
if ($script:Fail -eq 0) { Ok 'no duplicate ids or paths' }

# ---------------------------------------------------------------- 3. safe-entry policy
$allowedRoots = @($pol.allowed_roots) | ForEach-Object { (To-Slash $_).ToLowerInvariant() }

$policyFail = 0
foreach ($e in $entries) {
  $p = To-Slash ([string]$e.path)
  $full = $p.ToLowerInvariant() + '/'

  if ([string]$e.level -eq 'safe') {
    $rootOk = $false
    foreach ($r in $allowedRoots) { if ($full.StartsWith($r + '/') -or $full -eq ($r + '/')) { $rootOk = $true; break } }
    if (-not $rootOk) { Fail "$($e.id): safe path outside allowed roots: $p"; $policyFail++ }

    if ($e.regenerable -ne $true) { Fail "$($e.id): safe entry must set regenerable=true"; $policyFail++ }
    if ([string]::IsNullOrWhiteSpace([string]$e.source)) { Fail "$($e.id): safe entry needs a source"; $policyFail++ }
    $minEv = 6
    if ($null -ne $pol.min_evidence_chars) { $minEv = [int]$pol.min_evidence_chars }
    if (([string]$e.evidence).Length -lt $minEv) { Fail "$($e.id): safe entry needs evidence >= $minEv chars"; $policyFail++ }

    $overridden = $false
    foreach ($rx in $pol.overrides) { if ($full -match $rx) { $overridden = $true; break } }
    if (-not $overridden) {
      foreach ($rx in $pol.patterns) {
        if ($full -match $rx) { Fail "$($e.id): safe entry matches forbidden pattern '$rx'"; $policyFail++; break }
      }
    }
  }
}
if ($policyFail -eq 0) { Ok 'safe-entry policy: roots, regenerable, source, evidence, forbidden patterns' }

# ---------------------------------------------------------------- 4. user-content ratio on safe entries
function Get-ExtHistogram {
  param([string]$Path, [int]$Limit = 4000)
  $count = 0
  $hist = @{}
  $stack = New-Object 'System.Collections.Generic.Stack[string]'
  $stack.Push($Path)
  while ($stack.Count -gt 0 -and $count -lt $Limit) {
    $d = $stack.Pop()
    try { $items = [System.IO.Directory]::GetFileSystemEntries($d) } catch { continue }
    foreach ($i in $items) {
      try { $attr = [System.IO.File]::GetAttributes($i) } catch { continue }
      if ($attr -band [System.IO.FileAttributes]::ReparsePoint) { continue }
      if ($attr -band [System.IO.FileAttributes]::Directory) { $stack.Push($i); continue }
      $count++
      $x = [System.IO.Path]::GetExtension($i).ToLowerInvariant()
      if ($x -eq '') { $x = '(none)' }
      if ($hist.ContainsKey($x)) { $hist[$x]++ } else { $hist[$x] = 1 }
      if ($count -ge $Limit) { break }
    }
  }
  return [pscustomobject]@{ files = $count; hist = $hist }
}

$ratioFail = 0
$checked = 0
foreach ($e in $entries) {
  if ([string]$e.level -ne 'safe') { continue }
  $p = To-Slash ([string]$e.path)
  if ($p -match '[*?]') { continue }
  if (-not (Test-Path -LiteralPath $p)) { continue }
  $item = Get-Item -LiteralPath $p -Force -ErrorAction SilentlyContinue
  if ($null -eq $item -or -not $item.PSIsContainer) { continue }
  $h = Get-ExtHistogram $p
  if ($h.files -eq 0) { continue }
  $checked++
  $user = 0
  $media = 0
  foreach ($k in $h.hist.Keys) {
    if ($pol.user_content_ext -contains $k) { $user += $h.hist[$k] }
    if ($pol.media_ext -contains $k) { $media += $h.hist[$k] }
  }
  $ratio = [double]$user / [double]$h.files
  $mratio = [double]$media / [double]$h.files
  if ($ratio -gt [double]$pol.max_user_content_ratio) {
    Fail ("{0}: user-content ratio {1:P0} > {2:P0} ({3} of {4} files)" -f $e.id, $ratio, [double]$pol.max_user_content_ratio, $user, $h.files)
    $ratioFail++
  }
  if ($mratio -gt [double]$pol.max_media_ratio) {
    Fail ("{0}: media ratio {1:P0} > {2:P0} ({3} of {4} files)" -f $e.id, $mratio, [double]$pol.max_media_ratio, $media, $h.files)
    $ratioFail++
  }
}
if ($ratioFail -eq 0) { Ok "user-content ratio: $checked safe entries under threshold" }

# ---------------------------------------------------------------- 5. independent re-measure
function Ref-Measure {
  param([string]$Path, [int]$BudgetSec = 60)
  $sw = [System.Diagnostics.Stopwatch]::StartNew()
  $sum = [int64]0
  $stack = New-Object 'System.Collections.Generic.Stack[string]'
  $stack.Push($Path)
  while ($stack.Count -gt 0) {
    if ($sw.Elapsed.TotalSeconds -gt $BudgetSec) { return -1 }
    $d = $stack.Pop()
    $di = $null
    try { $di = [System.IO.DirectoryInfo]::new($d) } catch { continue }
    try { $files = $di.EnumerateFiles() } catch { $files = @() }
    foreach ($f in $files) { try { $sum += $f.Length } catch { } }
    try { $subs = $di.EnumerateDirectories() } catch { $subs = @() }
    foreach ($s in $subs) {
      try { if ($s.Attributes -band [System.IO.FileAttributes]::ReparsePoint) { continue } } catch { continue }
      $stack.Push($s.FullName)
    }
    }
  return $sum
}

$scanJson = & powershell -NoProfile -ExecutionPolicy Bypass -File $scanPath -Json 2>$null | Out-String
try { $scan = $scanJson | ConvertFrom-Json } catch { Fail 'scanner -Json output unparseable'; $scan = $null }

if ($null -ne $scan) {
  $topSafe = $scan.items | Where-Object { $_.level -eq 'safe' -and $_.exists -and $_.bytes -gt 0 } |
             Sort-Object bytes -Descending | Select-Object -First 3
  $refFail = 0
  $refDone = 0
  foreach ($it in $topSafe) {
    $ref = Ref-Measure $it.path
    if ($ref -lt 0) { Warn "ref-measure budget exceeded: $($it.path)"; continue }
    $refDone++
    $tol = [double]$pol.ref_measure_tolerance
    $diff = 0.0
    if ($ref -gt 0) { $diff = [math]::Abs([double]$it.bytes - [double]$ref) / [double]$ref }
    if ($diff -gt $tol) {
      Fail ("{0}: scanner reports {1} bytes, independent measure {2} (diff {3:P1})" -f $it.id, $it.bytes, $ref, $diff)
      $refFail++
    }
  }
  if ($refFail -eq 0) { Ok "independent re-measure: $refDone entries within tolerance" }
}

# ---------------------------------------------------------------- 6. scanner must stay read-only
$src = Get-Content -Raw -LiteralPath $scanPath
$destructive = @('Remove-Item','Move-Item','Clear-RecycleBin','Format-Volume','Rename-Item',
                 '\[System\.IO\.File\]::Delete','\[System\.IO\.Directory\]::Delete',
                 '\[System\.IO\.File\]::Move','\[System\.IO\.Directory\]::Move')
$roFail = 0
foreach ($d in $destructive) {
  if ($src -match $d) { Fail "scanner contains destructive token: $d"; $roFail++ }
}
if ($roFail -eq 0) { Ok 'scanner is read-only (no destructive cmdlets)' }

# ---------------------------------------------------------------- 7. fixture probe accuracy
$manifest = Get-Content -Raw -LiteralPath $manPath | ConvertFrom-Json
$listFile = Join-Path $env:TEMP ('raccoon-probe-' + [guid]::NewGuid().ToString('N') + '.txt')
$lines = @()
foreach ($c in $manifest.cases) { $lines += (Join-Path $treeRoot $c.rel) }
[System.IO.File]::WriteAllLines($listFile, $lines)

$probeOut = & powershell -NoProfile -ExecutionPolicy Bypass -File $scanPath -ProbeList $listFile 2>$null
Remove-Item -LiteralPath $listFile -Force -ErrorAction SilentlyContinue

$got = @{}
foreach ($l in $probeOut) {
  if ($l -match '^PROBE\|(.+?)\|([a-z]+)\|(-?\d+)\|') {
    $got[$matches[1].ToLowerInvariant()] = [pscustomobject]@{ level = $matches[2]; bytes = [int64]$matches[3] }
  }
}

$tp = 0; $fp = 0; $fn = 0; $tn = 0
$misses = @()
foreach ($c in $manifest.cases) {
  $full = (Join-Path $treeRoot $c.rel).ToLowerInvariant()
  if (-not $got.ContainsKey($full)) { Fail "fixture: no probe result for $($c.rel)"; continue }
  $g = $got[$full]
  $expSafe = ($c.level -eq 'safe')
  $gotSafe = ($g.level -eq 'safe')
  if ($expSafe -and $gotSafe) { $tp++ }
  elseif (-not $expSafe -and $gotSafe) { $fp++; $misses += "FP $($c.rel) -> $($g.level)" }
  elseif ($expSafe -and -not $gotSafe) { $fn++; $misses += "FN $($c.rel) -> $($g.level)" }
  else { $tn++ }
  if ($expSafe -and $gotSafe -and $c.bytes -gt 0) {
    $d = [math]::Abs([double]$g.bytes - [double]$c.bytes) / [double]$c.bytes
    if ($d -gt 0.02) { Fail ("fixture size: {0} expected {1} got {2}" -f $c.rel, $c.bytes, $g.bytes) }
  }
}
$denom = (2 * $tp) + $fp + $fn
$f1 = 0.0
if ($denom -gt 0) { $f1 = [math]::Round((2.0 * $tp) / $denom, 4) }
foreach ($m in $misses) { Warn "fixture $m" }
if ($f1 -lt [double]$pol.min_fixture_f1) {
  Fail ("fixture F1 {0} < required {1}" -f $f1, $pol.min_fixture_f1)
} else {
  Ok ("fixture F1 {0} (tp={1} fp={2} fn={3} tn={4})" -f $f1, $tp, $fp, $fn, $tn)
}
Write-Host ("METRIC probe_f1={0}" -f $f1)

# ---------------------------------------------------------------- verdict
if ($script:Fail -gt 0) {
  Write-Host "CHECKS FAILED ($script:Fail)"
  exit 1
}
Write-Host 'CHECKS PASSED'
exit 0
