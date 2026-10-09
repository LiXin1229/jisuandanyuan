param([string]$EfinityRoot='D:\Efinity\2026.1',[switch]$ReuseBuild,[switch]$Program,
 [string]$Python='C:\Users\Administrator\.cache\codex-runtimes\codex-primary-runtime\dependencies\python\python.exe',
 [string]$UsbUrl='ftdi://0x0403:0x6014:3:7/1',[string]$OutputDir='build/video_verified')
$ErrorActionPreference='Stop'
Push-Location (Split-Path -Parent $PSScriptRoot)
try {
 New-Item -ItemType Directory -Force -Path $OutputDir | Out-Null
 if($ReuseBuild) {$videoStage=(Get-Content -LiteralPath "$OutputDir/staging_path.txt" -Raw).Trim()}
 else {
  $videoStage=Join-Path $env:TEMP ('cyclegan_video_'+[guid]::NewGuid().ToString('N'))
  & (Join-Path $EfinityRoot 'bin/python3.bat') tools/prepare_video_deployment.py --board $videoStage > "$OutputDir/prepare_board.log" 2>&1
  if(!(Select-String -LiteralPath "$OutputDir/prepare_board.log" -Pattern '^VIDEO_BOARD_READY' -Quiet)) {throw 'Video project preparation failed'}
  Set-Content -LiteralPath "$OutputDir/staging_path.txt" -Value $videoStage
  Push-Location $videoStage
  try {
   foreach($flow in @('map','pnr','pgm')) {
    $result=@(& (Join-Path $EfinityRoot 'bin/efx_run.bat') encoder_board.xml --flow $flow 2>&1)
    $flowExit=$LASTEXITCODE;$result | Set-Content -LiteralPath "$flow.console.log"
    if($flowExit -ne 0 -or ($result -join "`n") -notmatch "$flow\s*:\s*PASS") {throw "$flow failed"}
    Write-Output "VIDEO_FLOW_PASS $flow"
   }
  } finally {Pop-Location}
 }
 $sourceGate='import hashlib,json,pathlib,sys; r=pathlib.Path.cwd(); p=pathlib.Path(sys.argv[1]); m=json.loads((p/"source_manifest.json").read_text()); sha=lambda p:hashlib.sha256(p.read_bytes()).hexdigest(); assert all(sha(r/"rtl"/n)==h for n,h in m["rtl_sha256"].items()),"Stale video RTL"; assert all(sha(r/"board/video"/n)==h for n,h in m["board_sha256"].items()),"Stale board templates"'
 & $Python -c $sourceGate $videoStage
 if($LASTEXITCODE -ne 0) {throw 'Video source manifest mismatch'}
 foreach($flow in @('map','pnr','pgm')) {
  if(!(Select-String -LiteralPath (Join-Path $videoStage "$flow.console.log") -Pattern "$flow\s*:\s*PASS" -Quiet)) {throw "Missing $flow PASS"}
 }
 $timingText=Get-Content -LiteralPath (Join-Path $videoStage 'outflow/encoder_board.timing.rpt') -Raw
 $rows=[regex]::Matches($timingText,'(?m)^\s*(\w+)\s+(\w+)\s+(-?[\d.]+)\s+(-?[\d.]+)\s+\(')
 if($rows.Count -eq 0) {throw 'Missing routed timing'}
 foreach($row in $rows) {if([double]$row.Groups[4].Value -lt 0) {throw ('Timing violation: '+$row.Value)}}
 $mapping=Get-Content -LiteralPath (Join-Path $videoStage 'outflow/encoder_board.map.rpt') -Raw
 $resources=@{}
 foreach($name in @('EFX_LUT4','EFX_FF','EFX_RAM10','EFX_DPRAM10','EFX_DSP48')) {
  $match=[regex]::Match($mapping,"(?m)^$name\s*:\s*(\d+)")
  if(!$match.Success) {throw "Missing resource: $name"};$resources[$name]=[int]$match.Groups[1].Value
 }
 if($resources.EFX_DSP48 -gt 103 -or ($resources.EFX_RAM10+$resources.EFX_DPRAM10) -gt 256) {throw 'Video resource budget exceeded'}
 $resources | ConvertTo-Json | Set-Content -LiteralPath "$OutputDir/resources.json"
 Write-Output ('VIDEO_RESOURCES '+($resources|ConvertTo-Json -Compress))
 Copy-Item -LiteralPath (Join-Path $videoStage 'outflow') -Destination $OutputDir -Recurse -Force
 if($Program) {
  $lines=@(& (Join-Path $EfinityRoot 'pgm/bin/ftdi_pgm.bat') -m jtag -b 'Generic Board Profile Using FT232H' -u $UsbUrl -a $UsbUrl (Join-Path $videoStage 'outflow/encoder_board.bit') 2>&1)
  $programExit=$LASTEXITCODE;$lines | Tee-Object -FilePath "$OutputDir/program.log"
  if($programExit -ne 0 -or ($lines -join "`n") -notmatch 'finished with JTAG programming' -or ($lines -join "`n") -notmatch '0x10660A79') {throw 'Ti60 programming failed'}
  Set-Content -LiteralPath 'build/video_active_stage.txt' -Value $videoStage
 }
} finally {Pop-Location}
