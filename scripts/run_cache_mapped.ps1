param([string]$Python='python',[string]$EfinityRoot='D:\Efinity\2026.1')
$ErrorActionPreference='Stop'
$projectRoot=Split-Path -Parent $PSScriptRoot
Push-Location $projectRoot
try {
    New-Item -ItemType Directory -Force build/sim | Out-Null
    Set-Content -LiteralPath build/sim/cache_mapped.log -Value '' -NoNewline
    # Keep the production CycleGAN netlist, reports and stage pointer intact.
    $cacheStage=Join-Path $env:TEMP ('mn_cache_'+[guid]::NewGuid().ToString('N'))
    & $Python scripts/create_efinity_project.py --staging $cacheStage --top mn_cache
    if($LASTEXITCODE -ne 0) { throw 'Cache map project failed' }
    Push-Location $cacheStage
    try {
        & (Join-Path $EfinityRoot 'bin\efx_run.bat') mobilenet.xml --flow map
        if($LASTEXITCODE -ne 0) { throw 'Cache synthesis failed' }
    } finally { Pop-Location }
    & $Python sim/prepare_models.py
    if($LASTEXITCODE -ne 0) { throw 'Cache simulation models failed' }
    & $Python sim/coalesce_cache_alias.py (Join-Path $cacheStage 'outflow/mobilenet.map.v') build/sim/cache_coalesced.v
    if($LASTEXITCODE -ne 0) { throw 'Cache output alias preparation failed' }
    & iverilog -g2012 -s tb_cache -o build/sim/cache_mapped.vvp sim/tb_cache.sv build/sim/cache_coalesced.v yilisi_sim_models/efx_dpram10.v build/sim/efx_lut4_compat.sv yilisi_sim_models/efx_ff.v yilisi_sim_models/efx_add.v yilisi_sim_models/efx_comb4.v
    if($LASTEXITCODE -ne 0) { throw 'Mapped cache compilation failed' }
    & vvp -i build/sim/cache_mapped.vvp +cache_progress | Tee-Object -FilePath build/sim/cache_mapped.log
    if($LASTEXITCODE -ne 0) { throw 'Mapped cache simulation failed' }
    Copy-Item -LiteralPath (Join-Path $cacheStage 'outflow/mobilenet.map.rpt') -Destination build/sim/cache.map.rpt -Force
} finally { Pop-Location }
