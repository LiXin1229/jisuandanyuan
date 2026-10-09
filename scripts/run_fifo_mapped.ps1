param([string]$Python='python',[string]$EfinityRoot='D:\Efinity\2026.1')
$ErrorActionPreference='Stop'
$projectRoot=Split-Path -Parent $PSScriptRoot
Push-Location $projectRoot
try {
    # Isolate this small map; never replace the production core reports.
    $fifoStage=Join-Path $env:TEMP ('mn_fifo_'+[guid]::NewGuid().ToString('N'))
    & $Python scripts/create_efinity_project.py --staging $fifoStage --top mn_instruction_fifo
    if($LASTEXITCODE -ne 0) { throw 'FIFO map project failed' }
    Push-Location $fifoStage
    try {
        & (Join-Path $EfinityRoot 'bin\efx_run.bat') mobilenet.xml --flow map
        if($LASTEXITCODE -ne 0) { throw 'FIFO synthesis failed' }
    } finally { Pop-Location }
    New-Item -ItemType Directory -Force build/sim | Out-Null
    & $Python sim/prepare_models.py
    if($LASTEXITCODE -ne 0) { throw 'FIFO simulation models failed' }
    & iverilog -g2012 -s tb_instruction_fifo -o build/sim/fifo_mapped.vvp sim/tb_instruction_fifo.sv (Join-Path $fifoStage 'outflow/mobilenet.map.v') build/sim/efx_lut4_compat.sv yilisi_sim_models/efx_ff.v yilisi_sim_models/efx_add.v yilisi_sim_models/efx_srl8.v
    if($LASTEXITCODE -ne 0) { throw 'Mapped FIFO compilation failed' }
    & vvp -i build/sim/fifo_mapped.vvp | Tee-Object -FilePath build/sim/fifo_mapped.log
    if($LASTEXITCODE -ne 0) { throw 'Mapped FIFO simulation failed' }
    Copy-Item -LiteralPath (Join-Path $fifoStage 'outflow/mobilenet.map.rpt') -Destination build/sim/fifo.map.rpt -Force
} finally { Pop-Location }
