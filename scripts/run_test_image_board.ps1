param([string]$Image='C:\Users\Administrator\Desktop\jisuan\pe10_10\test.jpg',
 [string]$Python='C:\Users\Administrator\.cache\codex-runtimes\codex-primary-runtime\dependencies\python\python.exe',
 [string]$EfinityRoot='D:\Efinity\2026.1',[string]$UsbUrl='ftdi://0x0403:0x6014:3:7/1',
 [string]$OutputDir='build/test_jpg_verification')
$ErrorActionPreference='Stop'
Push-Location (Split-Path -Parent $PSScriptRoot)
try {
 $project=(Get-Content -LiteralPath build/stage4_verified/staging_path.txt -Raw).Trim()
 New-Item -ItemType Directory -Force -Path $OutputDir | Out-Null
 & $Python tools/verify_test_image.py --prepare --image $Image --out $OutputDir --project $project | Tee-Object -FilePath "$OutputDir/reference.log"
 if($LASTEXITCODE -ne 0 -or !(Select-String -LiteralPath "$OutputDir/reference.log" -Pattern '^TEST_IMAGE_REFERENCE_PASS' -Quiet)) {throw 'Fresh image references failed'}
 $lines=@(& (Join-Path $EfinityRoot 'pgm/bin/ftdi_pgm.bat') -m jtag -b 'Generic Board Profile Using FT232H' -u $UsbUrl -a $UsbUrl (Join-Path $project 'outflow/encoder_board.bit') 2>&1)
 $programExit=$LASTEXITCODE;$lines | Tee-Object -FilePath "$OutputDir/program.log"
 if($programExit -ne 0 -or ($lines -join "`n") -notmatch '0x10660A79' -or ($lines -join "`n") -notmatch 'finished with JTAG programming') {throw 'Programming failed'}
 foreach($mode in @('paused','continuous')) {
  $extra=if($mode -eq 'paused') {'--verify-ddr'} else {'--continuous'}
  New-Item -ItemType Directory -Force -Path "$OutputDir/$mode" | Out-Null
  & (Join-Path $EfinityRoot 'bin/python3.bat') tools/debug_output_deployment.py --url $UsbUrl --project $project --reference "$OutputDir/model/vectors" --out "$OutputDir/$mode" --frames 1 $extra | Tee-Object -FilePath "$OutputDir/$mode/board.log"
  if(!(Select-String -LiteralPath "$OutputDir/$mode/board.log" -Pattern '^STAGE4_BOARD_PASS' -Quiet)) {throw "Image board validation failed: $mode"}
 }
 & $Python tools/verify_test_image.py --record --image $Image --out $OutputDir --project $project
 if($LASTEXITCODE -ne 0) {throw 'Image evidence gate failed'}
} finally {Pop-Location}
