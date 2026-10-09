param([double[]]$Frequencies = @(150),
      [string]$Top = 'cyclegan_bus_top',
      [string]$Python = 'python',
      [string]$EfinityRoot = 'D:\Efinity\2026.1')
$ErrorActionPreference = 'Stop'
$projectRoot = Split-Path -Parent $PSScriptRoot
Push-Location $projectRoot
try {
    foreach ($frequency in $Frequencies) {
        $timingStage = Join-Path $env:TEMP ('mobilenet_timing_' + [guid]::NewGuid().ToString('N'))
        $resultDirectory = "build/timing/$Top/$frequency"
        New-Item -ItemType Directory -Force $resultDirectory | Out-Null
        & $Python scripts/create_efinity_project.py --staging $timingStage --top $Top --clock-mhz $frequency
        if ($LASTEXITCODE -ne 0) { throw 'Timing project creation failed' }
        Set-Content -LiteralPath "$resultDirectory/staging_path.txt" -Value $timingStage
        Push-Location $timingStage
        try {
            & (Join-Path $EfinityRoot 'bin\efx_run.bat') mobilenet.xml --flow map
            if ($LASTEXITCODE -ne 0) { throw 'Timing synthesis failed' }
            & (Join-Path $EfinityRoot 'bin\efx_run.bat') mobilenet.xml --flow pnr
            if ($LASTEXITCODE -ne 0) { throw 'Timing placement/routing failed' }
        } finally {
            Pop-Location
            if (Test-Path -LiteralPath (Join-Path $timingStage 'outflow')) {
                Copy-Item -LiteralPath (Join-Path $timingStage 'outflow') -Destination $resultDirectory -Recurse -Force
            }
        }
        & $Python tools/check_timing.py "$resultDirectory/outflow/mobilenet.timing.rpt" --output "$resultDirectory/timing.json"
        if ($LASTEXITCODE -ne 0) { throw "Internal timing failed at $frequency MHz" }
    }
} finally { Pop-Location }
