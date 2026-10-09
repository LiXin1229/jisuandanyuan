param([string]$EfinityRoot = 'D:\Efinity\2026.1')
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
} finally { Pop-Location }
