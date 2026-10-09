param([string]$Python='C:\Users\Administrator\.cache\codex-runtimes\codex-primary-runtime\dependencies\python\python.exe',[switch]$Inverted,[int]$DdrDelay=2,[switch]$Continuous,[switch]$OutputOnly,[string]$OutputDir='build/stage4_verified')
$ErrorActionPreference='Stop'
Push-Location (Split-Path -Parent $PSScriptRoot)
try {
 & $Python tools/prepare_output_deployment.py --assets
 if($LASTEXITCODE -ne 0) {throw 'Output assets failed'}
 & $Python sim/prepare_models.py
 $simulationStage=Join-Path $env:TEMP ('output_sim_'+[guid]::NewGuid().ToString('N'))
 New-Item -ItemType Directory -Path $simulationStage | Out-Null
 $sources=@('mn_cache.sv','mn_param_ram.sv','mn_instruction_fifo.sv','mn_dw_buffer_bram.sv','mn_input_mux.sv','mn_pe_array.sv','mn_compact.sv','mn_postprocess.sv','mn_generator_rom.sv','mn_encoder_rom.sv','mn_residual_rom.sv','mn_tanh.sv','mobilenet_unit.sv','cyclegan_decoder_scheduler.sv','cyclegan_feature_writer.sv','cyclegan_ddr_read_bridge.sv','cyclegan_rgb_loader.sv','cyclegan_residual_scheduler.sv','cyclegan_encoder.sv')
 foreach($source in $sources+@('mn_isa.vh')) {Copy-Item -LiteralPath (Join-Path 'rtl' $source) -Destination $simulationStage}
 Copy-Item -LiteralPath sim/tb_cyclegan_output.sv,build/sim/efx_dsp48_compat.sv,build/sim/efx_lut4_compat.sv,conv_mem/conv_mem_unit/efx_ram10.v,yilisi_sim_models/efx_dpram10.v -Destination $simulationStage
 New-Item -ItemType Directory -Force -Path (Join-Path $simulationStage 'rtl'),(Join-Path $simulationStage 'build/stage4') | Out-Null
 Copy-Item -LiteralPath rtl/mn_tanh_u8.mem -Destination (Join-Path $simulationStage 'rtl')
 Copy-Item -LiteralPath build/stage4/vectors,build/stage4/vectors_inverted -Destination (Join-Path $simulationStage 'build/stage4') -Recurse
 $suffix=if($Inverted) {'_inverted'} else {''}
 New-Item -ItemType Directory -Force -Path $OutputDir | Out-Null
 Push-Location $simulationStage
 try {
  & vlib sim_work
  & vlog -sv -work sim_work '+incdir+.' @sources efx_ram10.v efx_dpram10.v efx_dsp48_compat.sv efx_lut4_compat.sv tb_cyclegan_output.sv
  if($LASTEXITCODE -ne 0) {throw 'ModelSim compile failed'}
  $extra=if($Continuous) {'+continuous'} else {'+paused'}
  $full=if($OutputOnly) {0} else {1};$only=if($OutputOnly) {1} else {0}
  & vsim -c -vopt -suppress 3009 -lib sim_work tb_cyclegan_output "-gFULL_PREFIX=$full" "-gOUTPUT_ONLY=$only" "+vectors=build/stage4/vectors$suffix" "+ddr-delay=$DdrDelay" $extra -l output_native.log -do 'run -all; quit -f'
  if(!(Select-String -LiteralPath output_native.log -Pattern 'PASS stage4:' -Quiet)) {throw 'Native output simulation failed'}
 } finally {
  Pop-Location
  $latencySuffix=if($DdrDelay -eq 2) {''} else {"_delay$DdrDelay"}
  Copy-Item -LiteralPath (Join-Path $simulationStage 'output_native.log') -Destination "$OutputDir/native$suffix$latencySuffix.log" -ErrorAction SilentlyContinue
  Set-Content -LiteralPath "$OutputDir/native$suffix${latencySuffix}_path.txt" -Value $simulationStage
 }
} finally {Pop-Location}
