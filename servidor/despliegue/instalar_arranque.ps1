<#
Hace que el servidor Taxiff y el túnel fijo arranquen solos cada vez que se
inicia sesión en Windows (tarea programada "Taxiff servidor").

  .\instalar_arranque.ps1             instala la tarea y la arranca ahora
  .\instalar_arranque.ps1 -Quitar     la quita (el servidor deja de arrancar solo)
#>
param([switch]$Quitar)

$nombre = "Taxiff servidor"
if ($Quitar) {
  Stop-ScheduledTask -TaskName $nombre -ErrorAction SilentlyContinue
  Unregister-ScheduledTask -TaskName $nombre -Confirm:$false -ErrorAction SilentlyContinue
  Write-Host "Tarea '$nombre' quitada."
  exit 0
}

$script = Join-Path $PSScriptRoot "servidor_siempre.ps1"
$accion = New-ScheduledTaskAction -Execute "powershell.exe" `
  -Argument "-NoProfile -WindowStyle Hidden -ExecutionPolicy Bypass -File `"$script`"" -WorkingDirectory $PSScriptRoot
$cuando = New-ScheduledTaskTrigger -AtLogOn -User $env:USERNAME
# Sin límite de tiempo, también con batería, y si se cae se reintenta.
$ajustes = New-ScheduledTaskSettingsSet -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries `
  -ExecutionTimeLimit ([TimeSpan]::Zero) -RestartCount 999 -RestartInterval (New-TimeSpan -Minutes 1) -StartWhenAvailable
Register-ScheduledTask -TaskName $nombre -Action $accion -Trigger $cuando -Settings $ajustes `
  -Description "Servidor Taxiff y túnel https://taxiff.site (servidor\despliegue\servidor_siempre.ps1)" -Force | Out-Null
Start-ScheduledTask -TaskName $nombre
Write-Host "Listo: '$nombre' arranca sola al iniciar sesión, y ya está corriendo."
Write-Host "Registro: servidor\datos\logs\siempre.log"
