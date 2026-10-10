param([int]$NormPoints=26,[string]$Image='C:\Users\Administrator\Desktop\jisuan\pe10_10\camera_original.png',
 [string]$OutputDir='build/video_image_verified',[switch]$ReuseBuild,
 [string]$EfinityRoot='D:\Efinity\2026.1',
 [string]$Python='C:\Users\Administrator\.cache\codex-runtimes\codex-primary-runtime\dependencies\python\python.exe',
 [string]$UsbUrl='ftdi://0x0403:0x6014:3:7/1')
$ErrorActionPreference='Stop'
Push-Location (Split-Path -Parent $PSScriptRoot)
try {
 New-Item -ItemType Directory -Force -Path $OutputDir | Out-Null
 & $Python -B tools/prepare_instance_norm_model.py --live-points $NormPoints --image $Image --output "$OutputDir/reference" > "$OutputDir/reference.log" 2>&1
 if($LASTEXITCODE -ne 0) {throw 'Photo reference failed'}
 & ./scripts/run_video_modelsim.ps1 -Tests image,board -OutputDir $OutputDir > "$OutputDir/sim.console.log" 2>&1
 if($LASTEXITCODE -ne 0) {throw 'Photo/camera protocol simulation failed'}
 & ./scripts/run_video_board.ps1 -NormPoints $NormPoints -HostImage -Program -ReuseBuild:$ReuseBuild -OutputDir $OutputDir -EfinityRoot $EfinityRoot -UsbUrl $UsbUrl
 $imageProject=(Get-Content -LiteralPath "$OutputDir/staging_path.txt" -Raw).Trim()
 & (Join-Path $EfinityRoot 'bin/python3.bat') tools/display_video_image.py --image $Image --reference "$OutputDir/reference" --project $imageProject --output $OutputDir --url $UsbUrl > "$OutputDir/image_display.log" 2>&1
 if(!(Select-String -LiteralPath "$OutputDir/image_display.log" -Pattern '^IMAGE_FPGA_HDMI_PASS ' -Quiet)) {throw 'FPGA photo display failed'}
 # Retain prior captures when repeating the board test.
 if(Test-Path -LiteralPath "$OutputDir/photo_pair") {
  $photoOutputRoot=(Resolve-Path -LiteralPath $OutputDir).Path
  $photoPairPath=(Resolve-Path -LiteralPath "$OutputDir/photo_pair").Path
  $photoArchivePath=Join-Path $photoOutputRoot ('photo_pair_'+[guid]::NewGuid().ToString('N'))
  if((Split-Path -Parent $photoPairPath) -ne $photoOutputRoot -or (Split-Path -Parent $photoArchivePath) -ne $photoOutputRoot) {throw 'Capture archive escaped output directory'}
  Move-Item -LiteralPath $photoPairPath -Destination $photoArchivePath
 }
 & (Join-Path $EfinityRoot 'bin/python3.bat') tools/capture_video_pair.py --profile "$imageProject/debug_profile.json" --bitstream "$imageProject/outflow/encoder_board.bit" --output "$OutputDir/photo_pair" --url $UsbUrl --leave-paused > "$OutputDir/capture.log" 2>&1
 if(!(Select-String -LiteralPath "$OutputDir/capture.log" -Pattern '^MATCHED_PAIR_CAPTURE_PASS ' -Quiet)) {throw 'Photo HDMI readback failed'}
 & $Python -B tools/verify_instance_norm_deployment.py --pair "$OutputDir/photo_pair" --live-points $NormPoints > "$OutputDir/comparison.log" 2>&1
 if($LASTEXITCODE -ne 0) {throw 'Photo integer comparison failed'}
 & $Python -B tools/verify_video_image.py --out $OutputDir
 if($LASTEXITCODE -ne 0) {throw 'Photo deployment gates failed'}
} finally {Pop-Location}
