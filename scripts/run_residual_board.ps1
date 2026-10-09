param([string]$Python='C:\Users\Administrator\.cache\codex-runtimes\codex-primary-runtime\dependencies\python\python.exe',
 [string]$EfinityRoot='D:\Efinity\2026.1',[switch]$Program,[switch]$RepeatBoot,[switch]$PhaseControl,[string]$UsbUrl='ftdi://0x0403:0x6014:3:7/1',[string]$OutputDir='build/stage2',[string]$ResourceBaselineJson='')
$ErrorActionPreference='Stop'
Push-Location (Split-Path -Parent $PSScriptRoot)
try {
 & $Python tools/prepare_residual_deployment.py --assets
 if($LASTEXITCODE -ne 0) { throw 'Assets failed' }
 New-Item -ItemType Directory -Force -Path $OutputDir | Out-Null
 $encoderStage=Join-Path $env:TEMP ('cyclegan_residual_' + [guid]::NewGuid().ToString('N'))
 & (Join-Path $EfinityRoot 'bin/python3.bat') tools/prepare_residual_deployment.py --board $encoderStage
 if($LASTEXITCODE -ne 0 -or !(Test-Path -LiteralPath (Join-Path $encoderStage 'outflow/encoder_board.lpf'))) { throw 'Board preparation failed' }
 Set-Content -LiteralPath "$OutputDir/staging_path.txt" -Value $encoderStage
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
 $mappingText=Get-Content -LiteralPath (Join-Path $encoderStage 'outflow/encoder_board.map.rpt') -Raw
 $resources=@{}
 foreach($name in @('EFX_LUT4','EFX_FF','EFX_RAM10','EFX_DPRAM10','EFX_DSP48')) {
  $match=[regex]::Match($mappingText,"(?m)^$name\s*:\s*(\d+)")
  if(!$match.Success) {throw "Missing resource: $name"}
  $resources[$name]=[int]$match.Groups[1].Value
 }
 if($resources.EFX_DSP48 -ne 100 -or ($resources.EFX_RAM10+$resources.EFX_DPRAM10) -gt 256) {throw 'Board resource budget exceeded'}
 if($ResourceBaselineJson) {
  $baseline=Get-Content -LiteralPath $ResourceBaselineJson -Raw | ConvertFrom-Json
  if($resources.EFX_LUT4 -ge $baseline.resources.EFX_LUT4 -or $resources.EFX_FF -ge $baseline.resources.EFX_FF) {throw 'Optimization must reduce both LUT and FF before board validation'}
 }
 Write-Output ('STAGE2_RESOURCES '+($resources | ConvertTo-Json -Compress))
 Copy-Item -LiteralPath (Join-Path $encoderStage 'outflow') -Destination $OutputDir -Recurse -Force
 if($Program) {
  $lines=@(& (Join-Path $EfinityRoot 'pgm/bin/ftdi_pgm.bat') -m jtag -b 'Generic Board Profile Using FT232H' -u $UsbUrl -a $UsbUrl (Join-Path $encoderStage 'outflow/encoder_board.bit') 2>&1)
  $programExit=$LASTEXITCODE;$lines | Tee-Object -FilePath "$OutputDir/program.log"
  if($programExit -ne 0 -or ($lines -join "`n") -notmatch 'finished with JTAG programming' -or ($lines -join "`n") -notmatch '0x10660A79') { throw 'Ti60 programming failed' }
  if($PhaseControl) {
   & (Join-Path $EfinityRoot 'bin/python3.bat') tools/debug_residual_deployment.py --url $UsbUrl --project $encoderStage --out $OutputDir --frames 1 --continuous --phy-phase 5 > "$OutputDir/phase5_control.log" 2>&1
   $control=Get-Content -LiteralPath "$OutputDir/board_result.json" -Raw | ConvertFrom-Json
   if($control.failure) {
    if($control.failure.error -notmatch '^Actual input CRC mismatch' -or $control.failure.state.phy_phase -ne 5) {throw 'Unexpected phase-5 control failure'}
   } elseif($control.frames.Count -ne 1 -or $control.frames[0].phy_phase -ne 5 -or $control.frames[0].mismatches -ne 0 -or $control.frames[0].input_checksum -ne $control.frames[0].expected_input_checksum) {
    throw 'Invalid phase-5 control result'
   }
   Copy-Item -LiteralPath "$OutputDir/board_result.json" -Destination "$OutputDir/board_phase5_control_result.json"
   if($control.failure) {Copy-Item -LiteralPath "$OutputDir/board_result.json" -Destination "$OutputDir/board_failed_phase5_result.json"}
  }
  & (Join-Path $EfinityRoot 'bin/python3.bat') tools/debug_residual_deployment.py --url $UsbUrl --project $encoderStage --out $OutputDir --verify-ddr --phy-phase 6 | Tee-Object -FilePath "$OutputDir/board.log"
  if($LASTEXITCODE -ne 0 -or !(Select-String -LiteralPath "$OutputDir/board.log" -Pattern '^STAGE2_BOARD_PASS' -Quiet)) { throw 'Stage-2 board validation failed' }
  if($RepeatBoot) {
   Copy-Item -LiteralPath "$OutputDir/board_result.json" -Destination "$OutputDir/board_primary_result.json"
   Copy-Item -LiteralPath "$OutputDir/program.log" -Destination "$OutputDir/program_primary.log"
   $repeatLines=@(& (Join-Path $EfinityRoot 'pgm/bin/ftdi_pgm.bat') -m jtag -b 'Generic Board Profile Using FT232H' -u $UsbUrl -a $UsbUrl (Join-Path $encoderStage 'outflow/encoder_board.bit') 2>&1)
   $repeatExit=$LASTEXITCODE;$repeatLines | Tee-Object -FilePath "$OutputDir/program_repeat.log"
   if($repeatExit -ne 0 -or ($repeatLines -join "`n") -notmatch 'finished with JTAG programming' -or ($repeatLines -join "`n") -notmatch '0x10660A79') {throw 'Ti60 repeat programming failed'}
   & (Join-Path $EfinityRoot 'bin/python3.bat') tools/debug_residual_deployment.py --url $UsbUrl --project $encoderStage --out $OutputDir --frames 4 --mixed | Tee-Object -FilePath "$OutputDir/board_repeat.log"
   if($LASTEXITCODE -ne 0 -or !(Select-String -LiteralPath "$OutputDir/board_repeat.log" -Pattern '^STAGE2_BOARD_PASS' -Quiet)) {throw 'Stage-2 repeat validation failed'}
  }
 }
} finally { Pop-Location }
