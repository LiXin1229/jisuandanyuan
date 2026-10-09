param([string]$Python = 'python')
$ErrorActionPreference = 'Stop'
$projectRoot = Split-Path -Parent $PSScriptRoot
Push-Location $projectRoot
try {
    if (!(Test-Path -LiteralPath build/efinity/outflow/mobilenet.map.v)) { throw 'Run synthesis first' }
    & $Python sim/prepare_models.py
    if ($LASTEXITCODE -ne 0) { throw 'Simulation model preparation failed' }
    & iverilog -g2012 -D MN_POSTMAP -s tb_mobilenet_bus -o build/sim/postmap.vvp sim/tb_mobilenet_bus.sv build/efinity/outflow/mobilenet.map.v conv_mem/conv_mem_unit/efx_ram10.v yilisi_sim_models/efx_dpram10.v build/sim/efx_dsp48_compat.sv build/sim/efx_lut4_compat.sv yilisi_sim_models/efx_ff.v yilisi_sim_models/efx_add.v yilisi_sim_models/efx_comb4.v yilisi_sim_models/efx_mult.v yilisi_sim_models/efx_srl8.v
    if ($LASTEXITCODE -ne 0) { throw 'Mapped netlist compilation failed' }
    & vvp build/sim/postmap.vvp | Tee-Object -FilePath build/sim/postmap.log
    if ($LASTEXITCODE -ne 0) { throw 'Mapped netlist simulation failed' }
} finally { Pop-Location }
