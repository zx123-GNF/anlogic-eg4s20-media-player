#-----------------------------------------------------------------------------
# flash.ps1 -- program the AC208 board (EG4S20BG256) from the command line,
#              no BitWriter GUI needed.
#
#   # program a project by name (finds <proj>\<proj>_Runs\phy_1\<proj>.bit)
#   powershell -NoProfile -ExecutionPolicy Bypass -File .\flash.ps1 -Proj m2_720p
#
#   # program an explicit bit file
#   powershell -NoProfile -ExecutionPolicy Bypass -File .\flash.ps1 -Bit E:\path\to\x.bit
#
#   # slower JTAG clock if the download is flaky (default 5 MHz)
#   ... -Spd 2
#
#   # write to SPI flash instead of SRAM (persistent; NOT verified on this board)
#   ... -Mode program_spi
#
# -Mode jtag (default) downloads into SRAM: instant, lost on power-off.
# Requires: AL-LINK driver (see tools\install_al_link_driver.ps1) + board powered.
#-----------------------------------------------------------------------------
param(
    [string]$Proj = '',
    [string]$Bit  = '',
    [string]$Mode = 'jtag',
    [int]$Spd     = 5,
    [int]$Cable   = 0
)
$ErrorActionPreference = 'Stop'

$root = Split-Path -Parent $MyInvocation.MyCommand.Definition      # ...\dsh_code\tools
$repo = Split-Path -Parent $root                                   # ...\dsh_code
$bw   = 'E:\bin\bw_commands_prompt.exe'

if (-not $Bit) {
    if (-not $Proj) { throw 'give -Proj <name> or -Bit <path>' }
    $Bit = Join-Path $repo "proj\$Proj\${Proj}_Runs\phy_1\$Proj.bit"
}
if (-not (Test-Path $Bit)) { throw "bit file not found: $Bit" }
$Bit = (Resolve-Path $Bit).Path -replace '\\', '/'

$env:BW_BIT   = $Bit
$env:BW_MODE  = $Mode
$env:BW_SPD   = "$Spd"
$env:BW_CABLE = "$Cable"

$log = Join-Path $root 'flash-last.log'
$tcl = (Join-Path $root 'bw_program.tcl') -replace '\\', '/'

$sw = [System.Diagnostics.Stopwatch]::StartNew()
$out = & $bw $tcl 2>&1
$rc  = $LASTEXITCODE
$sw.Stop()
$out | Set-Content -Path $log -Encoding UTF8
$out | Select-Object -Last 8 | ForEach-Object { Write-Host $_ }

$text = $out -join "`n"
$ok   = ($text -match 'PRG-2014 : Chip validation success') -and
        ($text -match 'finish command "download') -and
        ($text -notmatch '\bERROR\b')
if (-not $ok) {
    $err = ($text -split "`n" | Select-String -Pattern 'ERROR|FAIL' |
            Select-Object -Last 10 | ForEach-Object { $_.Line.Trim() }) -join "`n"
    throw "flash FAILED (elapsed $([math]::Round($sw.Elapsed.TotalSeconds,1)) s)`n$err`nlog: $log"
}
Write-Host ("OK  flashed {0} -> {1}, {2:N1} s  (log: {3})" -f `
            (Split-Path -Leaf $Bit), $Mode, $sw.Elapsed.TotalSeconds, $log)
