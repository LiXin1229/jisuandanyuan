param([string]$Python = 'D:\Users\Administrator\anaconda3\python.exe',
      [string]$EfinityRoot = 'D:\Efinity\2026.1')
$ErrorActionPreference = 'Stop'
$projectRoot = Split-Path -Parent $PSScriptRoot
Push-Location $projectRoot
try {
    & $Python scripts/create_efinity_project.py
    if ($LASTEXITCODE -ne 0) { throw 'Project creation failed' }
    # Efinity native tools require ASCII-only paths. Isolate each run in TEMP.
    $synthesisStage = Join-Path $env:TEMP ('mobilenet_ti60_' + [guid]::NewGuid().ToString('N'))
    & $Python scripts/create_efinity_project.py --staging $synthesisStage
    if ($LASTEXITCODE -ne 0) { throw 'ASCII staging failed' }
    Set-Content -LiteralPath build/efinity/staging_path.txt -Value $synthesisStage
    Push-Location $synthesisStage
    try {
        & (Join-Path $EfinityRoot 'bin\efx_run.bat') mobilenet.xml --flow map
        if ($LASTEXITCODE -ne 0) { throw 'Efinity synthesis failed' }
    } finally {
        Pop-Location
        if (Test-Path -LiteralPath (Join-Path $synthesisStage 'outflow')) {
            Copy-Item -LiteralPath (Join-Path $synthesisStage 'outflow') -Destination build/efinity -Recurse -Force
        }
    }
} finally { Pop-Location }
