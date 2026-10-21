#-----------------------------------------------------------------------------
# build.ps1 -- one-command rebuild of the M1 SDRAM frame buffer project
#
#   powershell -NoProfile -ExecutionPolicy Bypass -File E:\fpga-2026\dsh_code\proj\m1_sdram_fb\build.ps1
#
# Runs the two Tang Dynasty runs in order:
#   m1_sdram_fb_Runs\syn_1  : read_design -> opt_rtl -> opt_gate
#   m1_sdram_fb_Runs\phy_1  : opt_place   -> opt_route -> bitgen
# Output: m1_sdram_fb_Runs\phy_1\m1_sdram_fb.bit
#
# The Tcl wrapper (run_flow.tcl) turns TD's unreliable exit status into a real
# one: the bare td_commands_prompt.exe returns 0 even when the flow fails and
# may stop at the "td >" prompt.
#-----------------------------------------------------------------------------
$ErrorActionPreference = 'Stop'

$td   = 'E:\bin\td_commands_prompt.exe'
$root = Split-Path -Parent $MyInvocation.MyCommand.Definition
$flow = ($root -replace '\\', '/') + '/run_flow.tcl'   # Tcl needs forward slashes
$runs = Join-Path $root 'm1_sdram_fb_Runs'
$bit  = Join-Path $runs 'phy_1\m1_sdram_fb.bit'

foreach ($r in @('syn_1', 'phy_1')) {
    $dir = Join-Path $runs $r
    Push-Location $dir
    & $td $flow *> console_ci.log
    $rc = $LASTEXITCODE
    Pop-Location

    $log = Get-Content (Join-Path $dir 'console_ci.log') -Raw
    if ($rc -ne 0 -or $log -notmatch 'TD_FLOW_OK') {
        $err = ($log -split "`n" | Select-String -Pattern 'ERROR|CRITICAL-WARNING|TD_FLOW_FAILED' |
                Select-Object -Last 15 | ForEach-Object { $_.Line.Trim() }) -join "`n"
        throw "TD flow failed in $r (exit $rc)`n$err`nsee $dir\console_ci.log"
    }
    Write-Host "OK  $r"
}

if (-not (Test-Path $bit)) { throw "bitstream missing: $bit" }
$len = (Get-Item $bit).Length
Write-Host ("OK  bitstream {0} ({1} bytes)" -f $bit, $len)
Get-Content (Join-Path $runs 'phy_1\m1_sdram_fb_phy.ts')
