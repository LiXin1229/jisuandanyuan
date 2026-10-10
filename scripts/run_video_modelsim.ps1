param([string[]]$Tests=@('frontend','isp640','pool','key','stream','hdmi'),[string]$OutputDir='build/video_verified')
$ErrorActionPreference='Stop'
Push-Location (Split-Path -Parent $PSScriptRoot)
try {
 $simStage=Join-Path $env:TEMP ('video_sim_'+[guid]::NewGuid().ToString('N'))
 New-Item -ItemType Directory -Path $simStage | Out-Null
 Copy-Item -Path rtl/video/*,sim/video/* -Destination $simStage
 if(($Tests -contains 'board') -or ($Tests -contains 'image')) {
  Copy-Item -LiteralPath rtl/cyclegan_ddr_read_bridge.sv,rtl/cyclegan_feature_writer.sv -Destination $simStage
  New-Item -ItemType Directory -Force -Path "$simStage/build/stage4" | Out-Null
  Copy-Item -LiteralPath build/stage4/vectors,build/stage4/vectors_inverted -Destination "$simStage/build/stage4" -Recurse
  (Get-Content -LiteralPath "$simStage/protocol_models.v" -Raw).Replace('memory [0:524287]','memory [0:1048575]') | Set-Content -LiteralPath "$simStage/protocol_models.v"
 }
 New-Item -ItemType Directory -Force -Path $OutputDir | Out-Null
 Set-Content -LiteralPath "$OutputDir/unit_sim_path.txt" -Value $simStage
 Push-Location $simStage
 try {
  & vlib work
  $sources=@('camera_crop_bayer.v','camera_isp.v','camera_pool2x2.v','camera_frame_pingpong.v','camera_jtag_input.v','camera_frame_copy.v','camera_key.v','camera_hdmi.v','axi_read_arbiter2.v','axi_write_arbiter2.v','AXI4_AWARMux.v','tmds_channel.v','protocol_models.v')
  foreach($test in $Tests) {
   $testSources=$sources;$testTop="tb_$test";$testFile="$testTop.v"
   if($test -in @('board','image')) {
    $testTop=if($test -eq 'image') {'tb_video_image'} else {'tb_video_board'}
    $testFile="$testTop.sv"
    $testSources=$sources+@('camera_axi_mux.v','camera_schedule.v','cyclegan_camera_board.sv','cyclegan_ddr_read_bridge.sv','cyclegan_feature_writer.sv','video_core_protocol_model.sv')
   }
   & vlog -sv -work work '+incdir+.' @testSources $testFile > "${test}_compile.log" 2>&1
   if($LASTEXITCODE -ne 0) {throw "Video compile failed: $test"}
   & vsim -c -vopt -suppress 3009 -lib work $testTop -l "${test}_sim.log" -do 'onbreak {quit -code 1}; onerror {quit -code 1}; run -all; quit -code 0'
   if($LASTEXITCODE -ne 0 -or !(Select-String -LiteralPath "${test}_sim.log" -Pattern 'PASS camera' -Quiet)) {throw "Video simulation failed: $test"}
  }
 } finally {Pop-Location;Copy-Item -Path "$simStage/*_sim.log","$simStage/*_compile.log" -Destination $OutputDir -ErrorAction SilentlyContinue}
} finally {Pop-Location}
