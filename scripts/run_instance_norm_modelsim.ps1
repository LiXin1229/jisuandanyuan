param([string]$Python='C:\Users\Administrator\.cache\codex-runtimes\codex-primary-runtime\dependencies\python\python.exe',
 [string]$Image='C:/Users/Administrator/Desktop/jisuan/pe10_10/weight/test.jpg',[string]$OutputDir='build/instance_residual_verified',[int]$FullInstance=0,[switch]$Inverted,[switch]$FullOutput,[switch]$Continuous,[switch]$ReuseAssets,[switch]$Seeded,[int]$DdrDelay=2)
$ErrorActionPreference='Stop'
Push-Location (Split-Path -Parent $PSScriptRoot)
try {
 if(!$ReuseAssets) {
  if($FullInstance) {
   $points=if($FullInstance -eq 2) {26} else {23}
   $modelDir=Join-Path $OutputDir 'model'
   & $Python tools/prepare_instance_norm_model.py --live-points $points --image $Image --output $modelDir
   if($LASTEXITCODE -ne 0) {throw 'Full IN model failed'}
   & $Python tools/prepare_instance_norm_deployment.py --model $modelDir --output $OutputDir
  } else {& $Python tools/prepare_instance_norm_deployment.py --output $OutputDir}
  if($LASTEXITCODE -ne 0) {throw 'Instance assets failed'}
  & $Python sim/prepare_models.py
 }
 $simulationStage=Join-Path $env:TEMP ('instance_sim_'+[guid]::NewGuid().ToString('N'))
 New-Item -ItemType Directory -Path $simulationStage | Out-Null
 $sources=@('mn_cache.sv','mn_param_ram.sv','mn_instruction_fifo.sv','mn_dw_buffer_bram.sv','mn_input_mux.sv','mn_pe_array.sv','mn_compact.sv','mn_postprocess.sv','mn_encoder_rom.sv','mn_residual_rom.sv','mn_generator_rom.sv','mn_tanh.sv','mobilenet_unit.sv','cyclegan_rgb_loader.sv','cyclegan_residual_scheduler.sv','cyclegan_residual_instance_scheduler.sv','cyclegan_encoder_instance_scheduler.sv','cyclegan_instance_pass.sv','mn_instance_norm.sv','mn_instance_norm_coeff.sv','mn_instance_norm_gamma.sv','cyclegan_encoder.sv','cyclegan_decoder_scheduler.sv','cyclegan_feature_writer.sv','cyclegan_ddr_read_bridge.sv')
 foreach($source in $sources+@('mn_isa.vh')) {Copy-Item -LiteralPath (Join-Path 'rtl' $source) -Destination $simulationStage}
 Copy-Item -LiteralPath rtl/ip/norm_sqrt80/norm_sqrt80.v,sim/vendor/norm_div64_40.sv -Destination $simulationStage
 $sources+=@('norm_sqrt80.v','norm_div64_40.sv')
 $test=if($FullOutput) {'tb_cyclegan_output'} else {'tb_cyclegan_residual_instance'}
 Copy-Item -LiteralPath "sim/$test.sv",build/sim/efx_dsp48_compat.sv,build/sim/efx_lut4_compat.sv,conv_mem/conv_mem_unit/efx_ram10.v,yilisi_sim_models/efx_dpram10.v -Destination $simulationStage
 New-Item -ItemType Directory -Force -Path (Join-Path $simulationStage 'rtl') | Out-Null
 Copy-Item -LiteralPath rtl/mn_tanh_u8.mem -Destination (Join-Path $simulationStage 'rtl')
 Copy-Item -LiteralPath $OutputDir/vectors,$OutputDir/vectors_inverted -Destination $simulationStage -Recurse
 $suffix=if($Inverted) {'_inverted'} else {''};$kind=if($FullOutput) {'output'} else {'residual'}
 $log="${kind}${suffix}_delay${DdrDelay}.log"
 Set-Content -LiteralPath "$OutputDir/${kind}${suffix}_path.txt" -Value $simulationStage
 Push-Location $simulationStage
 try {
  & vlib sim_work
  & vlog -sv -work sim_work '+incdir+.' @sources efx_ram10.v efx_dpram10.v efx_dsp48_compat.sv efx_lut4_compat.sv "$test.sv"
  if($LASTEXITCODE -ne 0) {throw 'Instance ModelSim compile failed'}
  $extra=if($Continuous) {'+continuous'} else {'+paused'}
  [string[]]$instanceOptions=@()
  if($FullOutput) {$instanceOptions+=('-gRESIDUAL_INSTANCE_NORM=1',"-gFULL_INSTANCE_NORM=$FullInstance")}
  if($Seeded) {
   if($FullOutput) {throw 'Seeded residual test cannot select FullOutput'}
   $instanceOptions+=('+seeded')
  }
  & vsim -c -vopt -suppress 3009 -lib sim_work $test @instanceOptions "+vectors=vectors$suffix" "+ddr-delay=$DdrDelay" $extra -l $log -do 'run -all; quit -f'
  $pass=if($FullOutput) {'PASS stage4:'} else {'PASS instance residual:'}
  if(!(Select-String -LiteralPath $log -Pattern $pass -Quiet)) {throw 'Instance numerical regression failed'}
 } finally {Pop-Location;Copy-Item -LiteralPath (Join-Path $simulationStage $log) -Destination "$OutputDir/$log" -ErrorAction SilentlyContinue}
} finally {Pop-Location}
