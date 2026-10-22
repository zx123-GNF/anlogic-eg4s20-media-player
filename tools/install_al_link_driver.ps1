#requires -RunAsAdministrator
# Install the Anlogic AL-Link (USB) programming-cable driver.
# Run elevated:  powershell -NoProfile -ExecutionPolicy Bypass -File .\install_al_link_driver.ps1
$ErrorActionPreference = 'Continue'

$inf = 'E:\driver\al-link\win10\x64\anlocyusb.inf'
$log = Join-Path $PSScriptRoot 'al-link-driver-install.log'
if (Test-Path $log) { Remove-Item $log -Force -ErrorAction SilentlyContinue }

function L([string]$m) {
    $line = '{0} {1}' -f (Get-Date -Format 'HH:mm:ss'), $m
    Add-Content -Path $log -Value $line -Encoding UTF8
    Write-Host $line
}

L '=== AL-LINK driver install start ==='
L ("inf      : " + $inf)
L ("admin    : " + ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator))
L ("inf exist: " + (Test-Path $inf))

L '--- step 1: pnputil /add-driver /install ---'
& pnputil.exe /add-driver $inf /install 2>&1 | ForEach-Object { L ('pnputil: ' + $_) }
L ('pnputil exit: ' + $LASTEXITCODE)

L '--- step 2: pnputil /scan-devices (re-enumerate) ---'
& pnputil.exe /scan-devices 2>&1 | ForEach-Object { L ('scan: ' + $_) }
Start-Sleep -Seconds 3

L '--- step 3: device state ---'
$devs = @(Get-PnpDevice -PresentOnly -ErrorAction SilentlyContinue | Where-Object { $_.InstanceId -match 'VID_336C' })
if ($devs.Count -eq 0) {
    L 'NOTE: no VID_336C device present (cable unplugged?)'
} else {
    foreach ($d in $devs) {
        L ('dev: ' + $d.InstanceId + ' | status=' + $d.Status + ' | problem=' + $d.Problem + ' | name=' + $d.FriendlyName)
    }
}

$svc = Get-Service -Name ANLOCYUSB -ErrorAction SilentlyContinue
if ($svc) { L ('service ANLOCYUSB: ' + $svc.Status + ' / ' + $svc.StartType) } else { L 'service ANLOCYUSB: not found' }

L '--- step 4: installed oem packages matching anlogic ---'
& pnputil.exe /enum-drivers 2>&1 | Select-String -Pattern 'anlocyusb|Anlogic' -Context 0,0 | ForEach-Object { L ('oem: ' + $_.Line.Trim()) }

L '=== AL-LINK driver install done ==='
