param([string]$Python='C:\Users\Administrator\.cache\codex-runtimes\codex-primary-runtime\dependencies\python\python.exe',[switch]$Inverted,[int]$DdrDelay=2,[switch]$Continuous,[string]$OutputDir='build/stage2')
$ErrorActionPreference='Stop'
$projectRoot=Split-Path -Parent $PSScriptRoot
Push-Location $projectRoot
try {
 & $Python tools/prepare_residual_deployment.py --assets
 if($LASTEXITCODE -ne 0) { throw 'Residual assets failed' }
 & $Python sim/prepare_models.py
 $simulationStage=Join-Path $env:TEMP ('residual_sim_' + [guid]::NewGuid().ToString('N'))
 New-Item -ItemType Directory -Path $simulationStage | Out-Null
 $sources=@('mn_cache.sv','mn_param_ram.sv','mn_instruction_fifo.sv','mn_dw_buffer_bram.sv','mn_input_mux.sv','mn_pe_array.sv','mn_compact.sv','mn_postprocess.sv','mn_encoder_rom.sv','mn_residual_rom.sv','cyclegan_residual_scheduler.sv','mn_tanh.sv','mobilenet_unit.sv','cyclegan_rgb_loader.sv','cyclegan_encoder.sv')
 New-Item -ItemType Directory -Force -Path $OutputDir | Out-Null
 foreach($source in $sources+@('mn_isa.vh')) { Copy-Item -LiteralPath (Join-Path 'rtl' $source) -Destination $simulationStage }
 Copy-Item -LiteralPath sim/tb_cyclegan_residual.sv,build/sim/efx_dsp48_compat.sv,build/sim/efx_lut4_compat.sv,conv_mem/conv_mem_unit/efx_ram10.v,yilisi_sim_models/efx_dpram10.v -Destination $simulationStage
 New-Item -ItemType Directory -Force -Path (Join-Path $simulationStage 'rtl'),(Join-Path $simulationStage 'build/stage2') | Out-Null
 Copy-Item -LiteralPath rtl/mn_tanh_u8.mem -Destination (Join-Path $simulationStage 'rtl')
 Copy-Item -LiteralPath build/stage2/vectors,build/stage2/vectors_inverted -Destination (Join-Path $simulationStage 'build/stage2') -Recurse
 $suffix=if($Inverted) {'_inverted'} else {''}
 Push-Location $simulationStage
 try {
  & vlib sim_work
  & vlog -sv -work sim_work '+incdir+.' @sources efx_ram10.v efx_dpram10.v efx_dsp48_compat.sv efx_lut4_compat.sv tb_cyclegan_residual.sv
  if($LASTEXITCODE -ne 0) { throw 'ModelSim compile failed' }
  $extra=if($Continuous) {'+continuous'} else {'+paused'}
  & vsim -c -vopt -suppress 3009 -lib sim_work tb_cyclegan_residual "+vectors=build/stage2/vectors$suffix" "+ddr-delay=$DdrDelay" $extra -l residual_native.log -do 'run -all; quit -f'
  if(!(Select-String -LiteralPath residual_native.log -Pattern 'PASS stage2:' -Quiet)) { throw 'Native residual simulation did not pass' }
 } finally { Pop-Location; $latencySuffix=if($DdrDelay -eq 2) {''} else {"_delay$DdrDelay"}; Copy-Item -LiteralPath (Join-Path $simulationStage 'residual_native.log') -Destination "$OutputDir/native$suffix$latencySuffix.log" -ErrorAction SilentlyContinue }
} finally { Pop-Location }
