#-----------------------------------------------------------------------------
# read_uart.ps1 -- read the FPGA debug UART (board USB-C / CH340E), 115200 8N1
#
#   powershell -NoProfile -ExecutionPolicy Bypass -File .\read_uart.ps1
#   ... -Seconds 10      listen longer (default 6 s)
#   ... -Port COM5       force a port instead of auto-detecting the CH340
#
# The design prints one line per recorded byte_seq read:
#     <'A'+rec> <off hi><off lo> <cnt> <state> <34 bytes hex> CR LF
# after reset (or 0.5 s later if fewer than 4 records were captured).
# Plugging the cable in is not enough: the design prints once after a reset,
# so press S2 / power-cycle the board while this script is listening.
#-----------------------------------------------------------------------------
param(
    [string]$Port = '',
    [int]$Seconds = 6,
    [int]$Baud = 115200
)
$ErrorActionPreference = 'Stop'

if (-not $Port) {
    $d = Get-PnpDevice -Class Ports -PresentOnly -ErrorAction SilentlyContinue |
         Where-Object { $_.InstanceId -match 'VID_1A86' } | Select-Object -First 1
    if (-not $d) {
        throw 'no CH340 serial port found: plug the board USB-C (data cable) into the PC'
    }
    if ($d.FriendlyName -match '\((COM\d+)\)') { $Port = $Matches[1] }
    else { throw "cannot parse the COM port from '$($d.FriendlyName)'" }
}
Write-Host "listening on $Port @ $Baud for $Seconds s (press S2 now)"

$sp = New-Object System.IO.Ports.SerialPort($Port, $Baud, [System.IO.Ports.Parity]::None, 8, [System.IO.Ports.StopBits]::One)
$sp.ReadTimeout = 300
$sp.NewLine = "`r`n"
try {
    $sp.Open()
    $sp.DiscardInBuffer()
    $sb = New-Object System.Text.StringBuilder
    $sw = [System.Diagnostics.Stopwatch]::StartNew()
    while ($sw.Elapsed.TotalSeconds -lt $Seconds) {
        try { $chunk = $sp.ReadExisting() } catch { $chunk = '' }
        if ($chunk) { [void]$sb.Append($chunk) }
        Start-Sleep -Milliseconds 50
    }
    $text = $sb.ToString()
} finally {
    if ($sp.IsOpen) { $sp.Close() }
    $sp.Dispose()
}

if (-not $text) { Write-Host 'nothing received'; exit 1 }
Write-Host '--------------- raw ---------------'
Write-Host $text
Write-Host '--------------- records -----------'
foreach ($line in ($text -split "`r?`n")) {
    $l = $line.Trim()
    if ($l -match '^[A-Z]') {
        $rec = $l[0]
        $hex = $l.Substring(1)
        if ($hex.Length -ge 8) {
            $off = 0
            $cnt = 0
            $st  = 0
            try {
                $off = [Convert]::ToInt32($hex.Substring(0, 4), 16)
                $cnt = [Convert]::ToInt32($hex.Substring(4, 2), 16)
                $st  = [Convert]::ToInt32($hex.Substring(6, 2), 16)
            } catch { }
            $payload = ''
            for ($i = 0; $i -lt $cnt; $i++) {
                $p = 8 + $i * 2
                if ($p + 2 -le $hex.Length) { $payload += $hex.Substring($p, 2) + ' ' }
            }
            'rec {0}: off=0x{1:X3} ({1}) cnt={2} state=0x{3:X2} payload={4}' -f $rec, $off, $cnt, $st, $payload.Trim()
        }
    }
}
