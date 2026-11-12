# raccoon-validate.ps1 - checks gate for the win-raccoon autoresearch loop.
# Exit 1 on any FAIL.
[CmdletBinding()]
param([string]$Root)
$ErrorActionPreference = 'Stop'
# The scanner emits UTF-8; decode its output the same way.
[Console]::OutputEncoding = New-Object System.Text.UTF8Encoding($false)

Import-Module (Join-Path $PSScriptRoot 'Raccoon.Common.psm1') -Force

if (-not $Root) { $Root = Split-Path -Parent $PSScriptRoot }

$script:Fail = 0
$script:Sw = [System.Diagnostics.Stopwatch]::StartNew()
function Fail { param($m) Write-Host "FAIL $m"; $script:Fail++ }
function Ok   { param($m) Write-Host ("ok   {0}  [{1:N1}s]" -f $m, $script:Sw.Elapsed.TotalSeconds) }
function Warn { param($m) Write-Host "warn $m" }

$mapPath  = Join-Path $Root 'tools/cache-map.jsonl'
$scanPath = Join-Path $Root 'tools/raccoon-scan.ps1'
$polPath  = Join-Path $Root 'fixtures/forbidden.json'
$manPath  = Join-Path $Root 'fixtures/manifest.json'
$treeRoot = Join-Path $Root 'fixtures/tree'

$pol = Get-Content -Raw -LiteralPath $polPath | ConvertFrom-Json

function To-Slash {
  param([string]$p)
  return (Resolve-RaccoonPath -Raw $p -Separator '/')
}

# ---------------------------------------------------------------- 1. schema
$map = Read-CacheMap -Path $mapPath
foreach ($err in $map.Errors) { Fail $err }
$entries = $map.Entries
foreach ($e in $entries) {
  $n = $e._line
  foreach ($f in 'id','section','path','level','app','kind','desc') {
    $v = $e.PSObject.Properties[$f]
    if ($null -eq $v -or [string]::IsNullOrWhiteSpace([string]$v.Value)) {
      Fail "map line ${n}: missing field '$f'"
    }
  }
  if (@('safe','caution','forbidden') -notcontains [string]$e.level) {
    Fail "map line ${n}: bad level '$($e.level)'"
  }
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

# ---------------------------------------------------------------- 2b. same-level nesting
# Two entries at the same level whose paths nest would count the same bytes twice.
$byLevel = @{}
foreach ($e in $entries) {
  $lv = [string]$e.level
  if (-not $byLevel.ContainsKey($lv)) { $byLevel[$lv] = New-Object 'System.Collections.Generic.List[object]' }
  $byLevel[$lv].Add([pscustomobject]@{ id = $e.id; p = (To-Slash ([string]$e.path)).ToLowerInvariant() })
}
$nestFail = 0
foreach ($lv in $byLevel.Keys) {
  $list = $byLevel[$lv]
  for ($i = 0; $i -lt $list.Count; $i++) {
    for ($j = $i + 1; $j -lt $list.Count; $j++) {
      $a = $list[$i]
      $b = $list[$j]
      if ($a.p -eq $b.p) { continue }
      if ($a.p.StartsWith($b.p + '/') -or $b.p.StartsWith($a.p + '/')) {
        Fail "same-level nesting double counts ($lv): $($a.id) [$($a.p)] vs $($b.id) [$($b.p)]"
        $nestFail++
      }
    }
  }
}
if ($nestFail -eq 0) { Ok 'no same-level nesting (no double counting)' }

# ---------------------------------------------------------------- 3. safe-entry policy
$allowedRoots = @($pol.allowed_roots) | ForEach-Object { (To-Slash $_).ToLowerInvariant() }
$minEvidence = 6
if ($null -ne $pol.min_evidence_chars) { $minEvidence = [int]$pol.min_evidence_chars }

$policyFail = 0
foreach ($e in $entries) {
  if ([string]$e.level -ne 'safe') { continue }
  $p = To-Slash ([string]$e.path)
  $full = $p.ToLowerInvariant() + '/'

  $rootOk = $false
  foreach ($r in $allowedRoots) {
    if ($full.StartsWith($r + '/') -or $full -eq ($r + '/')) { $rootOk = $true; break }
  }
  if (-not $rootOk) { Fail "$($e.id): safe path outside allowed roots: $p"; $policyFail++ }

  if ($e.regenerable -ne $true) { Fail "$($e.id): safe entry must set regenerable=true"; $policyFail++ }
  if ([string]::IsNullOrWhiteSpace([string]$e.source)) { Fail "$($e.id): safe entry needs a source"; $policyFail++ }
  if (([string]$e.evidence).Length -lt $minEvidence) {
    Fail "$($e.id): safe entry needs evidence >= $minEvidence chars"; $policyFail++
  }

  $overridden = $false
  foreach ($rx in $pol.overrides) { if ($full -match $rx) { $overridden = $true; break } }
  if (-not $overridden) {
    foreach ($rx in $pol.patterns) {
      if ($full -match $rx) { Fail "$($e.id): safe entry matches forbidden pattern '$rx'"; $policyFail++; break }
    }
  }
}
if ($policyFail -eq 0) { Ok 'safe-entry policy: roots, regenerable, source, evidence, forbidden patterns' }

# ---------------------------------------------------------------- 4. user-content ratio on safe entries
$ratioFail = 0
$checked = 0
foreach ($e in $entries) {
  if ([string]$e.level -ne 'safe') { continue }
  $p = To-Slash ([string]$e.path)
  $targets = @()
  if ($p -match '[*?]') {
    $targets = @(Get-Item -Path $p -Force -ErrorAction SilentlyContinue)
  } else {
    $one = Get-Item -LiteralPath $p -Force -ErrorAction SilentlyContinue
    if ($null -ne $one) { $targets = @($one) }
  }

  foreach ($t in $targets) {
    if (-not $t.PSIsContainer) { continue }
    $h = Get-ExtHistogram -Path $t.FullName
    if ($h.Files -eq 0) { continue }
    $checked++

    $user = 0
    $media = 0
    foreach ($k in $h.Hist.Keys) {
      if ($pol.user_content_ext -contains $k) { $user += $h.Hist[$k] }
      if ($pol.media_ext -contains $k) { $media += $h.Hist[$k] }
    }
    $ratio = [double]$user / [double]$h.Files
    $mratio = [double]$media / [double]$h.Files

    if ($ratio -gt [double]$pol.max_user_content_ratio) {
      Fail ("{0}: user-content ratio {1:P0} > {2:P0} ({3} of {4} files)" -f `
        $e.id, $ratio, [double]$pol.max_user_content_ratio, $user, $h.Files)
      $ratioFail++
    }
    if ($mratio -gt [double]$pol.max_media_ratio) {
      Fail ("{0}: media ratio {1:P0} > {2:P0} ({3} of {4} files)" -f `
        $e.id, $mratio, [double]$pol.max_media_ratio, $media, $h.Files)
      $ratioFail++
    }
  }
}
if ($ratioFail -eq 0) { Ok "user-content ratio: $checked safe entries under threshold" }

# ---------------------------------------------------------------- 5. independent re-measure
# Deliberately a different algorithm from the scanner: a plain directory walk
# that sums FileInfo.Length, instead of robocopy's own accounting.
$refWorker = {
  param($root, $budget)
  $sw = [System.Diagnostics.Stopwatch]::StartNew()
  $sum = [int64]0
  $stack = New-Object 'System.Collections.Generic.Stack[string]'
  $stack.Push($root)
  while ($stack.Count -gt 0) {
    if ($sw.Elapsed.TotalSeconds -gt $budget) { return [int64]-1 }
    $d = $stack.Pop()
    $di = $null
    try { $di = [System.IO.DirectoryInfo]::new($d) } catch { continue }
    try { foreach ($f in $di.EnumerateFiles()) { $sum += $f.Length } } catch { }
    try {
      foreach ($s in $di.EnumerateDirectories()) {
        if ($s.Attributes -band [System.IO.FileAttributes]::ReparsePoint) { continue }
        $stack.Push($s.FullName)
      }
    } catch { }
  }
  return $sum
}

$scanJson = & powershell -NoProfile -ExecutionPolicy Bypass -File $scanPath -Json 2>$null | Out-String
$scan = $null
try { $scan = $scanJson | ConvertFrom-Json } catch { Fail 'scanner -Json output unparseable' }

if ($null -ne $scan) {
  $topSafe = $scan.items | Where-Object { $_.level -eq 'safe' -and $_.exists -and $_.bytes -gt 0 } |
             Sort-Object bytes -Descending | Select-Object -First 4
  $refPaths = @($topSafe | ForEach-Object { $_.path })
  $refSizes = Invoke-Parallel -Items $refPaths -Worker $refWorker -WorkerArgs @(90) -Throttle 4

  $refFail = 0
  $refDone = 0
  foreach ($it in $topSafe) {
    $ref = [int64]-1
    if ($refSizes.ContainsKey($it.path)) { $ref = [int64]$refSizes[$it.path] }
    if ($ref -lt 0) { Warn "ref-measure budget exceeded: $($it.path)"; continue }
    $refDone++

    $diff = 0.0
    if ($ref -gt 0) { $diff = [math]::Abs([double]$it.bytes - [double]$ref) / [double]$ref }
    if ($diff -gt [double]$pol.ref_measure_tolerance) {
      Fail ("{0}: scanner reports {1} bytes, independent measure {2} (diff {3:P1})" -f `
        $it.id, $it.bytes, $ref, $diff)
      $refFail++
    }
  }
  if ($refFail -eq 0) { Ok "independent re-measure: $refDone entries within tolerance" }
}

# ---------------------------------------------------------------- 6. scanner must stay read-only
$src = Get-Content -Raw -LiteralPath $scanPath
# Scan code, not prose: strip single-quoted literals and line comments first, so a
# documentation line that merely names a destructive cmdlet does not trip the guard.
$code = [regex]::Replace($src, "'(?:[^']|'')*'", "''")
$code = [regex]::Replace($code, '(?m)#.*$', '')
$destructive = @('Remove-Item','Move-Item','Clear-RecycleBin','Format-Volume','Rename-Item',
                 '\[System\.IO\.File\]::Delete','\[System\.IO\.Directory\]::Delete',
                 '\[System\.IO\.File\]::Move','\[System\.IO\.Directory\]::Move')
$roFail = 0
foreach ($d in $destructive) {
  if ($code -match $d) { Fail "scanner contains destructive token: $d"; $roFail++ }
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

# ---------------------------------------------------------------- 8. probe tables vs frozen policy
# The scanner ships its own copy of the probe tables so the skill works without
# fixtures/. That copy must never be more permissive than the frozen policy.
$rulesJson = & powershell -NoProfile -ExecutionPolicy Bypass -File $scanPath -DumpRules 2>$null | Out-String
$rules = $null
try { $rules = $rulesJson | ConvertFrom-Json } catch { Fail 'scanner -DumpRules output unparseable' }

if ($null -ne $rules) {
  $drift = 0
  foreach ($rx in @($rules.hard_forbidden)) {
    if (@($pol.patterns) -notcontains $rx) { Fail "scanner hard-forbidden pattern not in policy: $rx"; $drift++ }
  }
  foreach ($rx in @($rules.overrides)) {
    if (@($pol.overrides) -notcontains $rx) { Fail "scanner override not in policy: $rx"; $drift++ }
  }
  foreach ($x in @($rules.user_content_ext)) {
    if (@($pol.user_content_ext) -notcontains $x) { Fail "scanner user_content_ext not in policy: $x"; $drift++ }
  }
  foreach ($x in @($rules.media_ext)) {
    if (@($pol.media_ext) -notcontains $x) { Fail "scanner media_ext not in policy: $x"; $drift++ }
  }
  if ([double]$rules.max_user_content_ratio -ne [double]$pol.max_user_content_ratio) {
    Fail "scanner max_user_content_ratio $($rules.max_user_content_ratio) != policy $($pol.max_user_content_ratio)"; $drift++
  }
  if ([double]$rules.forbid_media_ratio -ne [double]$pol.max_media_ratio) {
    Fail "scanner forbid_media_ratio $($rules.forbid_media_ratio) != policy $($pol.max_media_ratio)"; $drift++
  }
  if ($drift -eq 0) { Ok 'scanner probe tables agree with the frozen policy' }
}

# ---------------------------------------------------------------- verdict
if ($script:Fail -gt 0) {
  Write-Host "CHECKS FAILED ($script:Fail)"
  exit 1
}
Write-Host 'CHECKS PASSED'
exit 0
