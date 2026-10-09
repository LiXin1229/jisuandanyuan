param([string]$Python='C:\Users\Administrator\.cache\codex-runtimes\codex-primary-runtime\dependencies\python\python.exe',
 [string]$EfinityRoot='D:\Efinity\2026.1',[switch]$Program,[switch]$RepeatBoot,[string]$UsbUrl='ftdi://0x0403:0x6014:3:7/1')
$ErrorActionPreference='Stop'
Push-Location (Split-Path -Parent $PSScriptRoot)
try {
 & $Python tools/prepare_encoder_deployment.py --assets
 if($LASTEXITCODE -ne 0) { throw 'Assets failed' }
 $encoderStage=Join-Path $env:TEMP ('cyclegan_encoder_' + [guid]::NewGuid().ToString('N'))
 & (Join-Path $EfinityRoot 'bin/python3.bat') tools/prepare_encoder_deployment.py --board $encoderStage
 if($LASTEXITCODE -ne 0 -or !(Test-Path -LiteralPath (Join-Path $encoderStage 'outflow/encoder_board.lpf'))) { throw 'Board preparation failed' }
 Set-Content -LiteralPath build/stage1/staging_path.txt -Value $encoderStage
 Push-Location $encoderStage
 try {
  foreach($flow in @('map','pnr','pgm')) {
   $result=@(& (Join-Path $EfinityRoot 'bin/efx_run.bat') encoder_board.xml --flow $flow 2>&1)
   $exitCode=$LASTEXITCODE
   $result | Tee-Object -FilePath "$flow.console.log"
   if($exitCode -ne 0 -or ($result -join "`n") -notmatch "$flow\s*:\s*PASS") { throw "$flow failed" }
  }
 } finally { Pop-Location }
 $timingText=Get-Content -LiteralPath (Join-Path $encoderStage 'outflow/encoder_board.timing.rpt') -Raw
 $timingRows=[regex]::Matches($timingText,'(?m)^\s*(\w+)\s+(\w+)\s+(-?[\d.]+)\s+(-?[\d.]+)\s+\(')
 if($timingRows.Count -eq 0) { throw 'Missing routed clock relationship timing' }
 foreach($row in $timingRows) { if([double]$row.Groups[4].Value -lt 0) { throw ('Timing violation: '+$row.Value) } }
 Copy-Item -LiteralPath (Join-Path $encoderStage 'outflow') -Destination build/stage1 -Recurse -Force
 if($Program) {
  $lines=@(& (Join-Path $EfinityRoot 'pgm/bin/ftdi_pgm.bat') -m jtag -b 'Generic Board Profile Using FT232H' -u $UsbUrl -a $UsbUrl (Join-Path $encoderStage 'outflow/encoder_board.bit') 2>&1)
  $programExit=$LASTEXITCODE;$lines | Tee-Object -FilePath build/stage1/program.log
  if($programExit -ne 0 -or ($lines -join "`n") -notmatch 'finished with JTAG programming' -or ($lines -join "`n") -notmatch '0x10660A79') { throw 'Ti60 programming failed' }
  & (Join-Path $EfinityRoot 'bin/python3.bat') tools/debug_encoder_deployment.py --url $UsbUrl --project $encoderStage --verify-ddr | Tee-Object -FilePath build/stage1/board.log
  if($LASTEXITCODE -ne 0 -or !(Select-String -LiteralPath build/stage1/board.log -Pattern '^STAGE1_BOARD_PASS' -Quiet)) { throw 'Stage-1 board validation failed' }
  if($RepeatBoot) {
   Copy-Item -LiteralPath build/stage1/board_result.json -Destination build/stage1/board_primary_result.json
   Copy-Item -LiteralPath build/stage1/program.log -Destination build/stage1/program_primary.log
   $repeatLines=@(& (Join-Path $EfinityRoot 'pgm/bin/ftdi_pgm.bat') -m jtag -b 'Generic Board Profile Using FT232H' -u $UsbUrl -a $UsbUrl (Join-Path $encoderStage 'outflow/encoder_board.bit') 2>&1)
   $repeatExit=$LASTEXITCODE;$repeatLines | Tee-Object -FilePath build/stage1/program_repeat.log
   if($repeatExit -ne 0 -or ($repeatLines -join "`n") -notmatch 'finished with JTAG programming' -or ($repeatLines -join "`n") -notmatch '0x10660A79') {throw 'Ti60 repeat programming failed'}
   & (Join-Path $EfinityRoot 'bin/python3.bat') tools/debug_encoder_deployment.py --url $UsbUrl --project $encoderStage --frames 4 | Tee-Object -FilePath build/stage1/board_repeat.log
   if($LASTEXITCODE -ne 0 -or !(Select-String -LiteralPath build/stage1/board_repeat.log -Pattern '^STAGE1_BOARD_PASS' -Quiet)) {throw 'Stage-1 repeat validation failed'}
  }
 }
} finally { Pop-Location }
