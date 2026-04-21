Get-CimInstance Win32_Process -Filter "Name='powershell.exe'" | Select-Object ProcessId, CommandLine | Format-Table -AutoSize
Get-CimInstance Win32_Process -Filter "Name='cmd.exe'" | Select-Object ProcessId, CommandLine | Format-Table -AutoSize
