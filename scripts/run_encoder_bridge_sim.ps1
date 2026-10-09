$ErrorActionPreference='Stop'
Push-Location (Split-Path -Parent $PSScriptRoot)
try {
 New-Item -ItemType Directory -Force -Path build/stage1 | Out-Null
 & iverilog -g2012 -s tb_cyclegan_ddr_read_bridge -o build/stage1/ddr_bridge.vvp sim/tb_cyclegan_ddr_read_bridge.sv rtl/cyclegan_ddr_read_bridge.sv
 if($LASTEXITCODE -ne 0) {throw 'DDR bridge compile failed'}
 & vvp -i build/stage1/ddr_bridge.vvp | Tee-Object -FilePath build/stage1/ddr_bridge.log
 if($LASTEXITCODE -ne 0 -or !(Select-String -LiteralPath build/stage1/ddr_bridge.log -Pattern '^PASS DDR bridge:' -Quiet)) {throw 'DDR bridge validation failed'}
} finally {Pop-Location}
