param([string]$Image='C:\Users\Administrator\Desktop\jisuan\pe10_10\camera_original.png',
 [string]$Python='C:\Users\Administrator\.cache\codex-runtimes\codex-primary-runtime\dependencies\python\python.exe',
 [string]$EfinityRoot='D:\Efinity\2026.1',[string]$UsbUrl='ftdi://0x0403:0x6014:3:7/1',
 [string]$NativeDir='build/instance_full_timing_verified',
 [string]$LiveDir='build/video_instance_full_live_final',[string]$PhotoDir='build/video_instance_full_photo_final',
 [int]$SecondsPerMode=30,[switch]$ReuseSimulation,[switch]$ReuseBuild,[switch]$ReuseCapture)
$ErrorActionPreference='Stop'
Push-Location (Split-Path -Parent $PSScriptRoot)
try {
 & ./scripts/run_instance_norm_coeff.ps1
 & $Python tools/prepare_instance_norm_model.py --live-points 26 --image $Image --output "$NativeDir/model"
 if($LASTEXITCODE -ne 0) {throw 'Full IN reference failed'}
 & $Python tools/prepare_instance_norm_deployment.py --model "$NativeDir/model" --output $NativeDir
 if($LASTEXITCODE -ne 0) {throw 'Full IN assets failed'}
 if(!$ReuseSimulation) {
  & ./scripts/run_instance_norm_modelsim.ps1 -FullOutput -FullInstance 2 -ReuseAssets -OutputDir $NativeDir
  & ./scripts/run_instance_norm_modelsim.ps1 -FullOutput -FullInstance 2 -ReuseAssets -OutputDir $NativeDir -Inverted -Continuous -DdrDelay 45
 }
 & ./scripts/run_video_modelsim.ps1 -Tests image,board -OutputDir "$NativeDir/video_protocol"
 & ./scripts/run_video_board.ps1 -NormPoints 26 -Program -ReuseBuild:$ReuseBuild -OutputDir $LiveDir -EfinityRoot $EfinityRoot -UsbUrl $UsbUrl
 & ./scripts/verify_instance_norm_board.ps1 -NormPoints 26 -DeferRecord -ReuseCapture:$ReuseCapture -OutputDir $LiveDir -SecondsPerMode $SecondsPerMode -EfinityRoot $EfinityRoot -UsbUrl $UsbUrl
 & ./scripts/run_video_board.ps1 -NormPoints 26 -HostImage -Program -ReuseBuild:$ReuseBuild -OutputDir $PhotoDir -EfinityRoot $EfinityRoot -UsbUrl $UsbUrl
 $photoProject=(Get-Content -LiteralPath "$PhotoDir/staging_path.txt" -Raw).Trim()
 $vendorPython=Join-Path $EfinityRoot 'bin/python3.bat'
 & $vendorPython tools/display_video_image.py --image $Image --reference "$NativeDir/model" --project $photoProject --output "$PhotoDir/display" --url $UsbUrl > "$PhotoDir/image_display.log" 2>&1
 if(!(Select-String -LiteralPath "$PhotoDir/image_display.log" -Pattern '^IMAGE_FPGA_HDMI_PASS ' -Quiet)) {throw 'Full IN photo display failed'}
 if(Test-Path -LiteralPath "$PhotoDir/photo_pair") {
  $photoRoot=(Resolve-Path -LiteralPath $PhotoDir).Path
  $pairPath=(Resolve-Path -LiteralPath "$PhotoDir/photo_pair").Path
  $archivePath=Join-Path $photoRoot ('photo_pair_'+[guid]::NewGuid().ToString('N'))
  if((Split-Path -Parent $pairPath) -ne $photoRoot -or (Split-Path -Parent $archivePath) -ne $photoRoot) {throw 'Capture archive escaped output directory'}
  Move-Item -LiteralPath $pairPath -Destination $archivePath
 }
 & $vendorPython tools/capture_video_pair.py --profile "$photoProject/debug_profile.json" --bitstream "$photoProject/outflow/encoder_board.bit" --output "$PhotoDir/photo_pair" --url $UsbUrl --leave-paused > "$PhotoDir/capture.log" 2>&1
 if(!(Select-String -LiteralPath "$PhotoDir/capture.log" -Pattern '^MATCHED_PAIR_CAPTURE_PASS ' -Quiet)) {throw 'Full IN photo capture failed'}
 & $Python tools/verify_instance_norm_deployment.py --pair "$PhotoDir/photo_pair" --live-points 26
 if($LASTEXITCODE -ne 0) {throw 'Full IN photo comparison failed'}
 & $Python tools/record_full_instance_norm.py --points 26 --photo $PhotoDir --live $LiveDir --native $NativeDir
 if($LASTEXITCODE -ne 0) {throw 'Full IN evidence failed'}
} finally {Pop-Location}
