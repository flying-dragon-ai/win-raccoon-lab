# gen-fixture.ps1 - build a synthetic profile tree with known ground truth.
# ASCII only. Idempotent: wipes and rebuilds fixtures/tree.
[CmdletBinding()]
param([string]$Root)
$ErrorActionPreference = 'Stop'
if (-not $Root) { $Root = Join-Path $PSScriptRoot 'tree' }
if (Test-Path -LiteralPath $Root) { Remove-Item -LiteralPath $Root -Recurse -Force }
New-Item -ItemType Directory -Path $Root -Force | Out-Null

function New-Blob {
  param([string]$Path, [int]$Bytes)
  $dir = Split-Path -Parent $Path
  if (-not (Test-Path -LiteralPath $dir)) { New-Item -ItemType Directory -Path $dir -Force | Out-Null }
  $buf = New-Object byte[] $Bytes
  [System.IO.File]::WriteAllBytes($Path, $buf)
}

# --- safe caches -------------------------------------------------------------
New-Blob "$Root/cache/a.bin" 102400
New-Blob "$Root/cache/b.bin" 102400
New-Blob "$Root/cache/c.bin" 102400
New-Blob "$Root/app/Cache/x.dat" 51200
New-Blob "$Root/app/Cache/y.dat" 51200
New-Blob "$Root/app/Code Cache/v8.bin" 20480
New-Blob "$Root/app/GPUCache/g.bin" 10240
New-Blob "$Root/dev/npm-cache/pkg1.tgz" 25600
New-Blob "$Root/dev/npm-cache/pkg2.tgz" 25600
New-Blob "$Root/dev/npm-cache/pkg3.tgz" 25600
New-Blob "$Root/dev/npm-cache/pkg4.tgz" 25600
New-Blob "$Root/dev/.cargo/crates.io-index" 30720
New-Blob "$Root/dev/.cargo/config.toml" 30720
New-Blob "$Root/dev/node_modules/a/index.js" 10240
New-Blob "$Root/dev/node_modules/b/index.js" 10240
New-Blob "$Root/dev/node_modules/c/index.js" 10240
New-Blob "$Root/dev/node_modules/d/index.js" 10240
New-Blob "$Root/dev/node_modules/e/index.js" 10240
New-Blob "$Root/dev/target/out.rlib" 40960
New-Blob "$Root/dev/target/deps.rlib" 40960

# --- user state (must never be classified safe) ------------------------------
New-Blob "$Root/user/Documents/report.docx" 61440
New-Blob "$Root/user/msg/attach/p1.jpg" 71680
New-Blob "$Root/user/msg/attach/p2.jpg" 71680
New-Blob "$Root/user/Login Data" 5120
New-Blob "$Root/user/plugins/a.jar" 15360
New-Blob "$Root/user/plugins/b.jar" 15360
New-Blob "$Root/user/plugins/c.jar" 15360
New-Blob "$Root/user/aha/users/000001.ldb" 20480
New-Blob "$Root/user/aha/users/000002.ldb" 20480
New-Blob "$Root/user/db_storage/msg.db" 30720

# --- mixed: cache-named dir dominated by user documents ----------------------
New-Blob "$Root/mixed/cache-with-docs/one.bin" 10240
New-Blob "$Root/mixed/cache-with-docs/d1.docx" 20480
New-Blob "$Root/mixed/cache-with-docs/d2.docx" 20480
New-Blob "$Root/mixed/cache-with-docs/d3.docx" 20480
New-Blob "$Root/mixed/cache-with-docs/d4.docx" 20480
New-Blob "$Root/mixed/cache-with-docs/d5.docx" 20480

# --- junction loop: must not hang, must not double count ---------------------
New-Blob "$Root/loop-cache/payload.bin" 10240
$loopTarget = Join-Path $Root 'loop-cache'
$loopLink = Join-Path $Root 'loop-cache/self'
if (-not (Test-Path -LiteralPath $loopLink)) {
  cmd /c mklink /J "$loopLink" "$loopTarget" | Out-Null
}

# --- empty cache -------------------------------------------------------------
New-Item -ItemType Directory -Path "$Root/empty-cache" -Force | Out-Null

Write-Host "fixture built at $Root"
