param([string]$Python='C:\Users\Administrator\.cache\codex-runtimes\codex-primary-runtime\dependencies\python\python.exe')
$ErrorActionPreference='Stop'
$projectRoot=Split-Path -Parent $PSScriptRoot
Push-Location $projectRoot
try {
    New-Item -ItemType Directory -Force build/sim | Out-Null
    # Some tests print only at completion. Do not expose a previous PASS
    # while the current simulation is still running.
    foreach($log in @('assets','model_bus','model_postmap','fifo_mapped')) {
        Set-Content -LiteralPath "build/sim/$log.log" -Value '' -NoNewline
    }
    & $Python sim/generate_model_smoke.py
    if($LASTEXITCODE -ne 0) { throw 'Model vectors failed' }
    & $Python sim/check_host_protocol.py
    if($LASTEXITCODE -ne 0) { throw 'Host protocol check failed' }
    & iverilog -g2012 -s tb_model_assets -I rtl -o build/sim/assets.vvp sim/tb_model_assets.sv rtl/mn_model_rom.sv rtl/mn_tanh.sv conv_mem/conv_mem_unit/efx_ram10.v
    if($LASTEXITCODE -ne 0) { throw 'Asset compilation failed' }
    & vvp build/sim/assets.vvp | Tee-Object -FilePath build/sim/assets.log
    if($LASTEXITCODE -ne 0) { throw 'Native asset check failed' }
    & $Python sim/prepare_models.py
    if($LASTEXITCODE -ne 0) { throw 'Simulation model preparation failed' }
    $rtlSources=@('rtl/mn_cache.sv','rtl/mn_param_ram.sv','rtl/mn_instruction_fifo.sv',
        'rtl/mn_dw_buffer.sv','rtl/mn_input_mux.sv','rtl/mn_pe_array.sv','rtl/mn_postprocess.sv','rtl/mn_model_rom.sv',
        'rtl/mn_tanh.sv','rtl/mobilenet_unit.sv','rtl/mobilenet_bus_top.sv','rtl/cyclegan_bus_top.sv')
    & iverilog -g2012 -s tb_cyclegan_bus -I rtl -o build/sim/model_bus.vvp sim/tb_cyclegan_bus.sv @rtlSources conv_mem/conv_mem_unit/efx_ram10.v yilisi_sim_models/efx_dpram10.v build/sim/efx_dsp48_compat.sv build/sim/efx_lut4_compat.sv
    if($LASTEXITCODE -ne 0) { throw 'Model bus compilation failed' }
    & vvp build/sim/model_bus.vvp | Tee-Object -FilePath build/sim/model_bus.log
    if($LASTEXITCODE -ne 0) { throw 'Model bus simulation failed' }
    if(Test-Path build/efinity/outflow/mobilenet.map.v) {
        $netlist=Get-Content build/efinity/outflow/mobilenet.map.v -Raw
        if($netlist -match 'module cyclegan_bus_top') {
            & iverilog -g2012 -s tb_cyclegan_bus -o build/sim/model_postmap.vvp sim/tb_cyclegan_bus.sv build/efinity/outflow/mobilenet.map.v conv_mem/conv_mem_unit/efx_ram10.v yilisi_sim_models/efx_dpram10.v build/sim/efx_dsp48_compat.sv build/sim/efx_lut4_compat.sv yilisi_sim_models/efx_ff.v yilisi_sim_models/efx_add.v yilisi_sim_models/efx_comb4.v yilisi_sim_models/efx_mult.v yilisi_sim_models/efx_srl8.v
            if($LASTEXITCODE -ne 0) { throw 'Model mapped-netlist compilation failed' }
            & vvp build/sim/model_postmap.vvp | Tee-Object -FilePath build/sim/model_postmap.log
            if($LASTEXITCODE -ne 0) { throw 'Model mapped-netlist simulation failed' }
        }
    }
    & ./scripts/run_fifo_mapped.ps1 -Python $Python
    if($LASTEXITCODE -ne 0) { throw 'Mapped FIFO check failed' }
} finally { Pop-Location }
