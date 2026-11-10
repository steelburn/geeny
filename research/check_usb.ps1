Write-Output '=== anything Boya / VID_2F05 / USBSTOR present right now ==='
Get-PnpDevice -PresentOnly | Where-Object {
    $_.InstanceId -match '2F05' -or $_.FriendlyName -match 'Boya|Notra' -or $_.InstanceId -match 'USBSTOR'
} | Select-Object Class, FriendlyName, Status, InstanceId | Format-Table -AutoSize | Out-String -Width 220

Write-Output '=== volumes (again) ==='
Get-Volume | Select-Object DriveLetter, FileSystemLabel, FileSystem, DriveType |
    Format-Table -AutoSize | Out-String -Width 160

Write-Output '=== recent PnP driver events (last 10 min) ==='
Get-WinEvent -FilterHashtable @{LogName='Microsoft-Windows-Kernel-PnP/Configuration'; StartTime=(Get-Date).AddMinutes(-10)} `
    -MaxEvents 15 -ErrorAction SilentlyContinue |
    ForEach-Object { '{0}  {1}' -f $_.TimeCreated.ToString('HH:mm:ss'), ($_.Message -split "`r?`n")[0] }
