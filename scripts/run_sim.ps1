param([string]$Python = 'D:\Users\Administrator\anaconda3\python.exe')
$ErrorActionPreference = 'Stop'
$projectRoot = Split-Path -Parent $PSScriptRoot
Push-Location $projectRoot
try {
    & $Python sim/generate_vectors.py
    if ($LASTEXITCODE -ne 0) { throw 'Vector generation failed' }
    New-Item -ItemType Directory -Force -Path build/sim | Out-Null
    & $Python sim/prepare_models.py
    if ($LASTEXITCODE -ne 0) { throw 'Simulation model preparation failed' }
    $rtlSources = @('rtl/mn_cache.sv','rtl/mn_param_ram.sv','rtl/mn_instruction_fifo.sv',
        'rtl/mn_dw_windows.sv','rtl/mn_pe_array.sv','rtl/mn_postprocess.sv','rtl/mobilenet_unit.sv')
    & iverilog -g2012 -s tb_mobilenet_unit -I rtl -o build/sim/unit.vvp sim/tb_mobilenet_unit.sv @rtlSources conv_mem/conv_mem_unit/efx_ram10.v yilisi_sim_models/efx_dpram10.v build/sim/efx_dsp48_compat.sv
    if ($LASTEXITCODE -ne 0) { throw 'RTL compilation failed' }
    & vvp build/sim/unit.vvp | Tee-Object -FilePath build/sim/unit.log
    if ($LASTEXITCODE -ne 0) { throw 'RTL simulation failed' }
    & iverilog -g2012 -s tb_mobilenet_bus -I rtl -o build/sim/bus.vvp sim/tb_mobilenet_bus.sv @rtlSources rtl/mobilenet_bus_top.sv conv_mem/conv_mem_unit/efx_ram10.v yilisi_sim_models/efx_dpram10.v build/sim/efx_dsp48_compat.sv
    if ($LASTEXITCODE -ne 0) { throw 'Bus compilation failed' }
    & vvp build/sim/bus.vvp | Tee-Object -FilePath build/sim/bus.log
    if ($LASTEXITCODE -ne 0) { throw 'Bus simulation failed' }
} finally { Pop-Location }
