param([string]$Python='C:\Users\Administrator\.cache\codex-runtimes\codex-primary-runtime\dependencies\python\python.exe')
$ErrorActionPreference='Stop'
Push-Location (Split-Path -Parent $PSScriptRoot)
try {
 & $Python sim/generate_vectors.py
 & $Python sim/prepare_models.py
 $regressionStage=Join-Path $env:TEMP ('unit_sim_'+[guid]::NewGuid().ToString('N'))
 New-Item -ItemType Directory -Path $regressionStage | Out-Null
 $sources=@('mn_cache.sv','mn_param_ram.sv','mn_instruction_fifo.sv','mn_dw_buffer_bram.sv','mn_input_mux.sv','mn_pe_array.sv','mn_compact.sv','mn_postprocess.sv','mn_tanh.sv','mobilenet_unit.sv','mobilenet_bus_top.sv')
 foreach($source in $sources+@('mn_isa.vh')) {Copy-Item -LiteralPath (Join-Path 'rtl' $source) -Destination $regressionStage}
 Copy-Item -LiteralPath sim/tb_mobilenet_unit.sv,sim/tb_mobilenet_bus.sv,build/sim/efx_dsp48_compat.sv,build/sim/efx_lut4_compat.sv,conv_mem/conv_mem_unit/efx_ram10.v,yilisi_sim_models/efx_dpram10.v -Destination $regressionStage
 New-Item -ItemType Directory -Path (Join-Path $regressionStage 'rtl'),(Join-Path $regressionStage 'sim'),(Join-Path $regressionStage 'build/sim') | Out-Null
 Copy-Item -LiteralPath rtl/mn_tanh_u8.mem -Destination (Join-Path $regressionStage 'rtl')
 Copy-Item -LiteralPath sim/vectors.txt -Destination (Join-Path $regressionStage 'sim')
 Push-Location $regressionStage
 try {
  & vlib sim_work
  & vlog -sv -work sim_work '+incdir+.' @sources efx_ram10.v efx_dpram10.v efx_dsp48_compat.sv efx_lut4_compat.sv tb_mobilenet_unit.sv tb_mobilenet_bus.sv
  if($LASTEXITCODE -ne 0) {throw 'Unit regression compile failed'}
  foreach($bench in @('unit','bus')) {
   & vsim -c -vopt -suppress 3009 -lib sim_work "tb_mobilenet_$bench" -l "$bench.log" -do 'run -all; quit -f'
   if(!(Select-String -LiteralPath "$bench.log" -Pattern 'PASS' -Quiet)) {throw "$bench regression failed"}
  }
 } finally {Pop-Location}
 foreach($log in @('unit.log','bus.log')) {Copy-Item -LiteralPath (Join-Path $regressionStage $log) -Destination (Join-Path 'build/sim' $log)}
 Copy-Item -LiteralPath (Join-Path $regressionStage 'build/sim/commands.csv') -Destination build/sim/commands.csv
 & $Python sim/check_executor_cycles.py | Tee-Object -FilePath build/sim/executor_cycles.log
 if($LASTEXITCODE -ne 0) {throw 'Executor cycle regression failed'}
 Set-Content -LiteralPath build/stage2/unit_staging_path.txt -Value $regressionStage
} finally {Pop-Location}
