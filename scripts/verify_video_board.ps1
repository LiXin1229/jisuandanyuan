param([string]$EfinityRoot='D:\Efinity\2026.1',
 [string]$Python='C:\Users\Administrator\.cache\codex-runtimes\codex-primary-runtime\dependencies\python\python.exe',
 [string]$UsbUrl='ftdi://0x0403:0x6014:3:7/1',[string]$OutputDir='build/video_verified',
 [int]$SecondsPerMode=60,[switch]$ReuseCapture,[string]$PhysicalConfirmation='',
 [string]$RecordPath='docs/analysis/cyclegan_video_fps_optimization.json',
 [string]$Baseline='docs/analysis/cyclegan_video_deployment.json')
$ErrorActionPreference='Stop'
Push-Location (Split-Path -Parent $PSScriptRoot)
try {
 $videoStage=(Get-Content -LiteralPath "$OutputDir/staging_path.txt" -Raw).Trim()
 $profile=Join-Path $videoStage 'debug_profile.json';$bit=Join-Path $videoStage 'outflow/encoder_board.bit'
 $efxPython=Join-Path $EfinityRoot 'bin/python3.bat';$pairDir="$OutputDir/live_pair"
 if(!$ReuseCapture) {
  & $efxPython tools/capture_video_pair.py --url $UsbUrl --profile $profile --bitstream $bit --output $pairDir > "$OutputDir/capture.log" 2>&1
  if(!(Select-String -LiteralPath "$OutputDir/capture.log" -Pattern '^MATCHED_PAIR_CAPTURE_PASS' -Quiet)) {throw 'Live matched-pair readback failed'}
 }
 & $Python tools/verify_video_deployment.py --pair $pairDir > "$OutputDir/pair_reference.log" 2>&1
 if($LASTEXITCODE -ne 0 -or !(Select-String -LiteralPath "$OutputDir/pair_reference.log" -Pattern '^VIDEO_PAIR_NUMERICAL_PASS' -Quiet)) {throw 'Live frame numerical comparison failed'}
 Write-Output 'VIDEO_LIVE_NUMERICAL_PASS'
 foreach($mode in @('style','original')) {
  & $efxPython tools/debug_video.py --url $UsbUrl --profile $profile --bitstream $bit --seconds $SecondsPerMode --mode $mode --check-switch --output "$OutputDir/stream_$mode.json" > "$OutputDir/stream_$mode.log" 2>&1
  if(!(Select-String -LiteralPath "$OutputDir/stream_$mode.log" -Pattern '^VIDEO_STREAM_PASS' -Quiet)) {throw "Video stream gate failed: $mode"}
  Write-Output "VIDEO_LIVE_MODE_PASS $mode"
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
 if(!$restoreValid) {throw 'Automatic key control restoration failed; inspect restore.log'}
 Push-Location (Split-Path -Parent $PSScriptRoot)
 try {
  $extra=@('--record-path',$RecordPath);if($PhysicalConfirmation) {$extra+=@('--physical-confirmation',$PhysicalConfirmation)}
  if($Baseline) {$extra+=@('--baseline',$Baseline)}
  & $Python tools/verify_video_deployment.py --record --out $OutputDir --pair $pairDir @extra
  if($LASTEXITCODE -ne 0) {throw 'Video deployment evidence gate failed'}
 } finally {Pop-Location}
}
