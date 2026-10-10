param([string]$EfinityRoot='D:\Efinity\2026.1',
 [string]$Python='C:\Users\Administrator\.cache\codex-runtimes\codex-primary-runtime\dependencies\python\python.exe',
 [string]$UsbUrl='ftdi://0x0403:0x6014:3:7/1',[string]$OutputDir='build/video_instance_residual_verified',
 [int]$SecondsPerMode=30,[switch]$ReuseCapture,[switch]$DeferRecord)
$ErrorActionPreference='Stop'
Push-Location (Split-Path -Parent $PSScriptRoot)
try {
 $instanceProject=(Get-Content -LiteralPath "$OutputDir/staging_path.txt" -Raw).Trim()
 $profile=Join-Path $instanceProject 'debug_profile.json';$bit=Join-Path $instanceProject 'outflow/encoder_board.bit'
 $efxPython=Join-Path $EfinityRoot 'bin/python3.bat';$pairDir="$OutputDir/live_pair"
 if(!$ReuseCapture) {
  & $efxPython tools/capture_video_pair.py --url $UsbUrl --profile $profile --bitstream $bit --output $pairDir > "$OutputDir/capture.log" 2>&1
  if(!(Select-String -LiteralPath "$OutputDir/capture.log" -Pattern '^MATCHED_PAIR_CAPTURE_PASS' -Quiet)) {throw 'IN same-frame capture failed'}
 }
 & $Python -B tools/verify_instance_norm_deployment.py --pair $pairDir > "$OutputDir/pair_reference.log" 2>&1
 if($LASTEXITCODE -ne 0) {throw 'IN same-frame numerical comparison failed'}
 Write-Output 'INSTANCE_LIVE_NUMERICAL_PASS'
 foreach($mode in @('style','original')) {
  & $efxPython tools/debug_video.py --url $UsbUrl --profile $profile --bitstream $bit --seconds $SecondsPerMode --mode $mode --check-switch --output "$OutputDir/stream_$mode.json" > "$OutputDir/stream_$mode.log" 2>&1
  if(!(Select-String -LiteralPath "$OutputDir/stream_$mode.log" -Pattern '^VIDEO_STREAM_PASS' -Quiet)) {throw "IN stream failed: $mode"}
  Write-Output "INSTANCE_LIVE_MODE_PASS $mode"
 }
 $validated=$true
} finally {
 if($efxPython -and $profile -and $bit) {
  & $efxPython tools/debug_video.py --url $UsbUrl --profile $profile --bitstream $bit --seconds 1 --mode auto --output "$OutputDir/stream_restore.json" > "$OutputDir/restore.log" 2>&1
  $restoreValid=Select-String -LiteralPath "$OutputDir/restore.log" -Pattern '^VIDEO_STREAM_PASS' -Quiet
 }
 Pop-Location
}
if($validated) {
 if(!$restoreValid) {throw 'IN automatic key control restore failed'}
 if($DeferRecord) {Write-Output 'INSTANCE_HARDWARE_PASS; numerical and stream evidence saved';return}
 Push-Location (Split-Path -Parent $PSScriptRoot)
 try {
  & $Python -B tools/verify_instance_norm_deployment.py --record --out $OutputDir
  if($LASTEXITCODE -ne 0) {throw 'IN final evidence gate failed'}
 } finally {Pop-Location}
}
