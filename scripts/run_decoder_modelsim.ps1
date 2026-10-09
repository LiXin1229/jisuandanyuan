param([string]$Python='C:\Users\Administrator\.cache\codex-runtimes\codex-primary-runtime\dependencies\python\python.exe',[switch]$Inverted,[int]$DdrDelay=2,[switch]$Continuous,[switch]$FullPrefix,[string]$OutputDir='build/stage3_verified')
$ErrorActionPreference='Stop'
Push-Location (Split-Path -Parent $PSScriptRoot)
try {
 & $Python tools/prepare_decoder_deployment.py --assets
 if($LASTEXITCODE -ne 0) {throw 'Decoder assets failed'}
 & $Python sim/prepare_models.py
 $simulationStage=Join-Path $env:TEMP ('decoder_sim_'+[guid]::NewGuid().ToString('N'))
 New-Item -ItemType Directory -Path $simulationStage | Out-Null
 $sources=@('mn_cache.sv','mn_param_ram.sv','mn_instruction_fifo.sv','mn_dw_buffer_bram.sv','mn_input_mux.sv','mn_pe_array.sv','mn_compact.sv','mn_postprocess.sv','mn_decoder_rom.sv','mn_encoder_rom.sv','mn_residual_rom.sv','mn_tanh.sv','mobilenet_unit.sv','cyclegan_decoder_scheduler.sv','cyclegan_feature_writer.sv','cyclegan_ddr_read_bridge.sv','cyclegan_rgb_loader.sv','cyclegan_residual_scheduler.sv','cyclegan_encoder.sv')
 foreach($source in $sources+@('mn_isa.vh')) {Copy-Item -LiteralPath (Join-Path 'rtl' $source) -Destination $simulationStage}
 Copy-Item -LiteralPath sim/tb_cyclegan_decoder.sv,build/sim/efx_dsp48_compat.sv,build/sim/efx_lut4_compat.sv,conv_mem/conv_mem_unit/efx_ram10.v,yilisi_sim_models/efx_dpram10.v -Destination $simulationStage
 New-Item -ItemType Directory -Force -Path (Join-Path $simulationStage 'rtl'),(Join-Path $simulationStage 'build/stage3') | Out-Null
 Copy-Item -LiteralPath rtl/mn_tanh_u8.mem -Destination (Join-Path $simulationStage 'rtl')
 Copy-Item -LiteralPath build/stage3/vectors,build/stage3/vectors_inverted -Destination (Join-Path $simulationStage 'build/stage3') -Recurse
 $suffix=if($Inverted) {'_inverted'} else {''}
 New-Item -ItemType Directory -Force -Path $OutputDir | Out-Null
 Push-Location $simulationStage
 try {
  & vlib sim_work
  & vlog -sv -work sim_work '+incdir+.' @sources efx_ram10.v efx_dpram10.v efx_dsp48_compat.sv efx_lut4_compat.sv tb_cyclegan_decoder.sv
  if($LASTEXITCODE -ne 0) {throw 'ModelSim compile failed'}
  $extra=if($Continuous) {'+continuous'} else {'+paused'}
  $full=if($FullPrefix) {1} else {0}
  & vsim -c -vopt -suppress 3009 -lib sim_work tb_cyclegan_decoder "-gFULL_PREFIX=$full" "+vectors=build/stage3/vectors$suffix" "+ddr-delay=$DdrDelay" $extra -l decoder_native.log -do 'run -all; quit -f'
  if(!(Select-String -LiteralPath decoder_native.log -Pattern 'PASS stage3:' -Quiet)) {throw 'Native decoder simulation failed'}
 } finally {
  Pop-Location
  $latencySuffix=if($DdrDelay -eq 2) {''} else {"_delay$DdrDelay"}
  Copy-Item -LiteralPath (Join-Path $simulationStage 'decoder_native.log') -Destination "$OutputDir/native$suffix$latencySuffix.log" -ErrorAction SilentlyContinue
  Set-Content -LiteralPath "$OutputDir/native$suffix${latencySuffix}_path.txt" -Value $simulationStage
 }
} finally {Pop-Location}
