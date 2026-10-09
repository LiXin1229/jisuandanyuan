param([string]$Python = 'python', [int]$Jobs = 1)
$ErrorActionPreference = 'Stop'
$projectRoot = Split-Path -Parent $PSScriptRoot
Push-Location $projectRoot
try {
    & $Python sim/generate_vectors.py
    if ($LASTEXITCODE -ne 0) { throw 'Vector generation failed' }
    New-Item -ItemType Directory -Force -Path build/sim | Out-Null
    foreach($log in @('input_mux','compact','dsp_quant_probe','fifo','dw_buffer','postprocess',
                     'unit','executor_cycles','executor4_timing','bus')) {
        Set-Content -LiteralPath "build/sim/$log.log" -Value '' -NoNewline
    }
    & $Python sim/prepare_models.py
    if ($LASTEXITCODE -ne 0) { throw 'Simulation model preparation failed' }
    & iverilog -g2012 -s tb_input_mux -o build/sim/input_mux.vvp sim/tb_input_mux.sv rtl/mn_input_mux.sv build/sim/efx_lut4_compat.sv
    if ($LASTEXITCODE -ne 0) { throw 'PE input mux compilation failed' }
    & vvp build/sim/input_mux.vvp | Tee-Object -FilePath build/sim/input_mux.log
    if ($LASTEXITCODE -ne 0) { throw 'PE input mux simulation failed' }
    & iverilog -g2012 -s tb_compact -o build/sim/compact.vvp sim/tb_compact.sv rtl/mn_compact.sv build/sim/efx_lut4_compat.sv
    if ($LASTEXITCODE -ne 0) { throw 'Compact compilation failed' }
    & vvp build/sim/compact.vvp | Tee-Object -FilePath build/sim/compact.log
    if ($LASTEXITCODE -ne 0) { throw 'Compact simulation failed' }
    & iverilog -g2012 -s tb_dsp_quant_probe -o build/sim/dsp_quant_probe.vvp sim/tb_dsp_quant_probe.sv build/sim/efx_dsp48_compat.sv
    if ($LASTEXITCODE -ne 0) { throw 'DSP probe compilation failed' }
    & vvp -i build/sim/dsp_quant_probe.vvp | Tee-Object -FilePath build/sim/dsp_quant_probe.log
    if ($LASTEXITCODE -ne 0) { throw 'DSP feasibility probe failed' }
    & iverilog -g2012 -s tb_instruction_fifo -o build/sim/fifo.vvp sim/tb_instruction_fifo.sv rtl/mn_instruction_fifo.sv
    if ($LASTEXITCODE -ne 0) { throw 'FIFO compilation failed' }
    & vvp -i build/sim/fifo.vvp | Tee-Object -FilePath build/sim/fifo.log
    if ($LASTEXITCODE -ne 0) { throw 'FIFO simulation failed' }
    & iverilog -g2012 -s tb_dw_buffer -o build/sim/dw_buffer.vvp sim/tb_dw_buffer.sv rtl/mn_dw_buffer.sv
    if ($LASTEXITCODE -ne 0) { throw 'DW buffer compilation failed' }
    & vvp -i build/sim/dw_buffer.vvp | Tee-Object -FilePath build/sim/dw_buffer.log
    if ($LASTEXITCODE -ne 0) { throw 'DW buffer simulation failed' }
    & iverilog -g2012 -s tb_postprocess -I rtl -o build/sim/postprocess.vvp sim/tb_postprocess.sv rtl/mn_compact.sv rtl/mn_postprocess.sv build/sim/efx_lut4_compat.sv
    if ($LASTEXITCODE -ne 0) { throw 'Postprocess compilation failed' }
    & vvp -i build/sim/postprocess.vvp | Tee-Object -FilePath build/sim/postprocess.log
    if ($LASTEXITCODE -ne 0) { throw 'Postprocess simulation failed' }
    $rtlSources = @('rtl/mn_cache.sv','rtl/mn_param_ram.sv','rtl/mn_instruction_fifo.sv',
        'rtl/mn_dw_buffer.sv','rtl/mn_input_mux.sv','rtl/mn_pe_array.sv','rtl/mn_compact.sv','rtl/mn_postprocess.sv',
        'rtl/mn_model_rom.sv','rtl/mn_tanh.sv','rtl/mobilenet_unit.sv')
    & iverilog -g2012 -s tb_mobilenet_unit -I rtl -o build/sim/unit.vvp sim/tb_mobilenet_unit.sv @rtlSources conv_mem/conv_mem_unit/efx_ram10.v yilisi_sim_models/efx_dpram10.v build/sim/efx_dsp48_compat.sv build/sim/efx_lut4_compat.sv
    if ($LASTEXITCODE -ne 0) { throw 'RTL compilation failed' }
    & $Python sim/run_unit_regression.py --jobs $Jobs | Tee-Object -FilePath build/sim/unit.log
    if ($LASTEXITCODE -ne 0) { throw 'RTL simulation failed' }
    & $Python sim/check_executor_cycles.py | Tee-Object -FilePath build/sim/executor_cycles.log
    if ($LASTEXITCODE -ne 0) { throw 'Executor cycle check failed' }
    & $Python sim/prepare_executor_timing.py
    if ($LASTEXITCODE -ne 0) { throw 'Executor trace vectors failed' }
    & vvp -i build/sim/unit.vvp +vectors=build/sim/executor4_vectors.txt +metrics=build/sim/executor4_commands.csv +trace | Tee-Object -FilePath build/sim/executor4_timing.log
    if ($LASTEXITCODE -ne 0) { throw 'Executor edge trace failed' }
    & iverilog -g2012 -s tb_mobilenet_bus -I rtl -o build/sim/bus.vvp sim/tb_mobilenet_bus.sv @rtlSources rtl/mobilenet_bus_top.sv conv_mem/conv_mem_unit/efx_ram10.v yilisi_sim_models/efx_dpram10.v build/sim/efx_dsp48_compat.sv build/sim/efx_lut4_compat.sv
    if ($LASTEXITCODE -ne 0) { throw 'Bus compilation failed' }
    & vvp -i build/sim/bus.vvp | Tee-Object -FilePath build/sim/bus.log
    if ($LASTEXITCODE -ne 0) { throw 'Bus simulation failed' }
} finally { Pop-Location }
