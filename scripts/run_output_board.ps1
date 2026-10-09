param([string]$Python='C:\Users\Administrator\.cache\codex-runtimes\codex-primary-runtime\dependencies\python\python.exe',
 [string]$EfinityRoot='D:\Efinity\2026.1',[switch]$Program,[switch]$RepeatBoot,[switch]$ReuseBuild,
 [string]$UsbUrl='ftdi://0x0403:0x6014:3:7/1',[string]$OutputDir='build/stage4_verified')
$ErrorActionPreference='Stop'
Push-Location (Split-Path -Parent $PSScriptRoot)
try {
 & $Python tools/prepare_output_deployment.py --assets
 if($LASTEXITCODE -ne 0) {throw 'Assets failed'}
 New-Item -ItemType Directory -Force -Path $OutputDir | Out-Null
 if($ReuseBuild) {$outputStage=(Get-Content -LiteralPath "$OutputDir/staging_path.txt" -Raw).Trim()}
 else {
  $outputStage=Join-Path $env:TEMP ('cyclegan_output_'+[guid]::NewGuid().ToString('N'))
  & (Join-Path $EfinityRoot 'bin/python3.bat') tools/prepare_output_deployment.py --board $outputStage > "$OutputDir/prepare_board.log" 2>&1
  if(!(Select-String -LiteralPath "$OutputDir/prepare_board.log" -Pattern 'STAGE1_BOARD_READY' -Quiet)) {throw 'Board preparation failed'}
  Set-Content -LiteralPath "$OutputDir/staging_path.txt" -Value $outputStage
  Push-Location $outputStage
  try {
   foreach($flow in @('map','pnr','pgm')) {
    $result=@(& (Join-Path $EfinityRoot 'bin/efx_run.bat') encoder_board.xml --flow $flow 2>&1)
    $flowExit=$LASTEXITCODE;$result | Set-Content -LiteralPath "$flow.console.log"
    if($flowExit -ne 0 -or ($result -join "`n") -notmatch "$flow\s*:\s*PASS") {throw "$flow failed"}
   }
  } finally {Pop-Location}
 }
 & $Python -c "import hashlib,json,pathlib; r=pathlib.Path('.'); p=pathlib.Path(r'$outputStage'); m=json.loads((p/'source_manifest.json').read_text()); assert all(hashlib.sha256((r/'rtl'/n).read_bytes()).hexdigest()==h for n,h in m['rtl_sha256'].items()),'Stale board sources'"
 if($LASTEXITCODE -ne 0) {throw 'Source manifest mismatch'}
 foreach($flow in @('map','pnr','pgm')) {
  if(!(Select-String -LiteralPath (Join-Path $outputStage "$flow.console.log") -Pattern "$flow\s*:\s*PASS" -Quiet)) {throw "Missing $flow PASS"}
 }
 $timingText=Get-Content -LiteralPath (Join-Path $outputStage 'outflow/encoder_board.timing.rpt') -Raw
 $timingRows=[regex]::Matches($timingText,'(?m)^\s*(\w+)\s+(\w+)\s+(-?[\d.]+)\s+(-?[\d.]+)\s+\(')
 if($timingRows.Count -eq 0) {throw 'Missing routed timing'}
 foreach($row in $timingRows) {if([double]$row.Groups[4].Value -lt 0) {throw ('Timing violation: '+$row.Value)}}
 $mappingText=Get-Content -LiteralPath (Join-Path $outputStage 'outflow/encoder_board.map.rpt') -Raw
 $resources=@{}
 foreach($name in @('EFX_LUT4','EFX_FF','EFX_RAM10','EFX_DPRAM10','EFX_DSP48')) {
  $match=[regex]::Match($mappingText,"(?m)^$name\s*:\s*(\d+)")
  if(!$match.Success) {throw "Missing resource: $name"};$resources[$name]=[int]$match.Groups[1].Value
 }
 if($resources.EFX_DSP48 -ne 100 -or ($resources.EFX_RAM10+$resources.EFX_DPRAM10) -gt 256) {throw 'Resource budget exceeded'}
 Write-Output ('STAGE4_RESOURCES '+($resources|ConvertTo-Json -Compress))
 Copy-Item -LiteralPath (Join-Path $outputStage 'outflow') -Destination $OutputDir -Recurse -Force
 if($Program) {
  foreach($boot in $(if($RepeatBoot) {@('primary','repeat')} else {@('primary')})) {
   $lines=@(& (Join-Path $EfinityRoot 'pgm/bin/ftdi_pgm.bat') -m jtag -b 'Generic Board Profile Using FT232H' -u $UsbUrl -a $UsbUrl (Join-Path $outputStage 'outflow/encoder_board.bit') 2>&1)
   $programExit=$LASTEXITCODE;$lines | Tee-Object -FilePath "$OutputDir/program_$boot.log"
   if($programExit -ne 0 -or ($lines -join "`n") -notmatch 'finished with JTAG programming' -or ($lines -join "`n") -notmatch '0x10660A79') {throw 'Ti60 programming failed'}
   $extra=if($boot -eq 'primary') {'--verify-ddr'} else {'--continuous'}
   & (Join-Path $EfinityRoot 'bin/python3.bat') tools/debug_output_deployment.py --url $UsbUrl --project $outputStage --out $OutputDir $extra | Tee-Object -FilePath "$OutputDir/board_$boot.log"
   if(!(Select-String -LiteralPath "$OutputDir/board_$boot.log" -Pattern '^STAGE4_BOARD_PASS' -Quiet)) {throw 'Stage-4 board validation failed'}
   Copy-Item -LiteralPath "$OutputDir/board_result.json" -Destination "$OutputDir/board_${boot}_result.json"
  }
 }
} finally {Pop-Location}
