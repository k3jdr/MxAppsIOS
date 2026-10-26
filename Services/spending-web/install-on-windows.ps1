# Spending Analysis web page on K3JDR-DSKTOP-11: run once in an administrator PowerShell, from this folder, after
# spending_web.local.json is in place (copy spending_web.example.json; python spending_web.py --new-key for the key).
#   powershell -ExecutionPolicy Bypass -File .\install-on-windows.ps1
# It opens the port to the home network only (Private profile, LocalSubnet), and registers a task that starts the
# server at boot as this user (S4U: no stored password; it only needs this machine's PostgreSQL), then starts it.
$ErrorActionPreference = "Stop"
$here = Split-Path -Parent $MyInvocation.MyCommand.Path
$conf = Get-Content (Join-Path $here "spending_web.local.json") -Raw | ConvertFrom-Json
$port = if ($conf.port) { $conf.port } else { 8780 }
$python = (& py -3 -c "import sys; print(sys.executable)").Trim() -replace "python\.exe$", "pythonw.exe"

Get-NetFirewallRule -DisplayName "Spending Analysis web page" -ErrorAction SilentlyContinue | Remove-NetFirewallRule
New-NetFirewallRule -DisplayName "Spending Analysis web page" -Direction Inbound -Protocol TCP -LocalPort $port `
    -RemoteAddress LocalSubnet -Profile Private -Action Allow | Out-Null

$action = New-ScheduledTaskAction -Execute $python -Argument "`"$here\spending_web.py`" --log `"$here\spending_web.log`"" -WorkingDirectory $here
$trigger = New-ScheduledTaskTrigger -AtStartup
# The signed-in account as Windows names it (over SSH, USERDOMAIN says WORKGROUP rather than the computer's name).
$user = [System.Security.Principal.WindowsIdentity]::GetCurrent().Name
$principal = New-ScheduledTaskPrincipal -UserId $user -LogonType S4U -RunLevel Limited
$settings = New-ScheduledTaskSettingsSet -ExecutionTimeLimit ([TimeSpan]::Zero) -RestartCount 3 -RestartInterval (New-TimeSpan -Minutes 1) -StartWhenAvailable
Register-ScheduledTask -TaskName "Spending Analysis web page" -Action $action -Trigger $trigger -Principal $principal -Settings $settings -Force | Out-Null
Stop-ScheduledTask -TaskName "Spending Analysis web page" -ErrorAction SilentlyContinue
Start-ScheduledTask -TaskName "Spending Analysis web page"
Start-Sleep -Seconds 3
"Listening: " + [bool](Get-NetTCPConnection -LocalPort $port -State Listen -ErrorAction SilentlyContinue)
"Link: http://" + $env:COMPUTERNAME.ToLower() + ".local:$port/s/" + $conf.key + "/"
