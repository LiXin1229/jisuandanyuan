param([string]$EfinityRoot = 'D:\Efinity\2026.1', [string]$Python = 'python')
$ErrorActionPreference = 'Stop'
$projectRoot = Split-Path -Parent $PSScriptRoot
Push-Location $projectRoot
try {
    if (!(Test-Path -LiteralPath build/efinity/staging_path.txt)) { throw 'Run synthesis first' }
    $implementationStage = (Get-Content -LiteralPath build/efinity/staging_path.txt -Raw).Trim()
    if (!(Test-Path -LiteralPath (Join-Path $implementationStage 'mobilenet.xml'))) {
        throw 'Synthesis staging directory is missing; run synthesis again'
    }
    Push-Location $implementationStage
    try {
        & (Join-Path $EfinityRoot 'bin\efx_run.bat') mobilenet.xml --flow pnr
        if ($LASTEXITCODE -ne 0) { throw 'Efinity placement/routing failed' }
    } finally {
        Pop-Location
        Copy-Item -LiteralPath (Join-Path $implementationStage 'outflow') -Destination build/efinity -Recurse -Force
    }
    & $Python tools/check_timing.py build/efinity/outflow/mobilenet.timing.rpt --output build/efinity/timing.json
    if ($LASTEXITCODE -ne 0) { throw 'Internal setup/hold timing did not close' }
} finally { Pop-Location }
