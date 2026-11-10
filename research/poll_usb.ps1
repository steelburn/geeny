for ($i = 1; $i -le 12; $i++) {
    $dev = Get-PnpDevice -PresentOnly -ErrorAction SilentlyContinue |
        Where-Object { $_.InstanceId -match '2F05|USBSTOR' -or $_.FriendlyName -match 'Boya|Notra' }
    $vols = (Get-Volume | Where-Object { $_.DriveType -eq 'Removable' }).DriveLetter -join ','
    $disks = (Get-CimInstance Win32_DiskDrive | Measure-Object).Count
    $names = ($dev | ForEach-Object { $_.Class + ':' + $_.FriendlyName }) -join ' ; '
    '{0,2}s  disks={1}  removable=[{2}]  boya=[{3}]' -f ($i * 2), $disks, $vols, $names
    Start-Sleep -Seconds 2
}
