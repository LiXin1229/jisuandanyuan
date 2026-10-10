param([string]$Python='C:\Users\Administrator\.cache\codex-runtimes\codex-primary-runtime\dependencies\python\python.exe')
$ErrorActionPreference='Stop'
Push-Location (Split-Path -Parent $PSScriptRoot)
try {
 & $Python -B tools/prepare_norm_coeff_vectors.py
 if($LASTEXITCODE -ne 0) {throw 'Coefficient reference generation failed'}
 $coeffStage=Join-Path $env:TEMP ('instance_coeff_'+[guid]::NewGuid().ToString('N'))
 New-Item -ItemType Directory -Path $coeffStage | Out-Null
 Copy-Item -LiteralPath rtl/mn_instance_norm_coeff.sv,rtl/ip/norm_sqrt80/norm_sqrt80.v,sim/vendor/norm_div64_40.sv,sim/tb_instance_norm_coeff.sv,build/instance_residual_verified/coeff_edge.mem -Destination $coeffStage
 Push-Location $coeffStage
 try {
  & vlib sim_work
  & vlog -sv -work sim_work mn_instance_norm_coeff.sv norm_sqrt80.v norm_div64_40.sv tb_instance_norm_coeff.sv
  if($LASTEXITCODE -ne 0) {throw 'Coefficient compile failed'}
  & vsim -c -vopt -lib sim_work tb_instance_norm_coeff -l coeff_edge.log -do 'run -all; quit -f'
  if(!(Select-String -LiteralPath coeff_edge.log -Pattern 'PASS instance coefficient: 260 cases' -Quiet)) {throw 'Coefficient test failed'}
 } finally {Pop-Location;Copy-Item -LiteralPath (Join-Path $coeffStage 'coeff_edge.log') -Destination build/instance_residual_verified/coeff_edge.log -ErrorAction SilentlyContinue}
 Set-Content -LiteralPath build/instance_residual_verified/coeff_path.txt -Value $coeffStage
} finally {Pop-Location}
