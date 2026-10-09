param([string]$Python='C:\Users\Administrator\.cache\codex-runtimes\codex-primary-runtime\dependencies\python\python.exe',[switch]$Inverted)
$ErrorActionPreference='Stop'
Push-Location (Split-Path -Parent $PSScriptRoot)
try {
 & $Python tools/prepare_encoder_deployment.py --assets
 if($LASTEXITCODE -ne 0) { throw 'Encoder asset generation failed' }
 & $Python sim/prepare_models.py
 $sources=@('rtl/mn_cache.sv','rtl/mn_param_ram.sv','rtl/mn_instruction_fifo.sv','rtl/mn_dw_buffer_bram.sv','rtl/mn_input_mux.sv','rtl/mn_pe_array.sv','rtl/mn_compact.sv','rtl/mn_postprocess.sv','rtl/mn_model_rom.sv','rtl/mn_encoder_rom.sv','rtl/mn_tanh.sv','rtl/mobilenet_unit.sv','rtl/cyclegan_rgb_loader.sv','rtl/cyclegan_encoder.sv')
 & iverilog -g2012 -s tb_cyclegan_encoder -I rtl -o build/stage1/encoder.vvp sim/tb_cyclegan_encoder.sv @sources conv_mem/conv_mem_unit/efx_ram10.v yilisi_sim_models/efx_dpram10.v build/sim/efx_dsp48_compat.sv build/sim/efx_lut4_compat.sv
 if($LASTEXITCODE -ne 0) { throw 'Encoder compile failed' }
 $suffix=if($Inverted) {'_inverted'} else {''}
 & vvp -i build/stage1/encoder.vvp "+vectors=build/stage1/vectors$suffix" | Tee-Object -FilePath "build/stage1/simulation$suffix.log"
 if($LASTEXITCODE -ne 0) { throw 'Encoder simulation failed' }
} finally { Pop-Location }
