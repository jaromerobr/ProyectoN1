# Downloads the training photos saved on the ESP32 into esp32\datos\fotos_taxi\<date>.
# Usage (PowerShell):  .\descargar_fotos.ps1            (uses taxiff-cam.local)
#                      .\descargar_fotos.ps1 192.168.1.61
#                      .\descargar_fotos.ps1 192.168.1.61 -Borrar   (deletes them from the ESP32 afterwards)
param([string]$Ip = "taxiff-cam.local", [switch]$Borrar)

$base = "http://$Ip"
$dest = Join-Path $PSScriptRoot ("..\datos\fotos_taxi\" + (Get-Date -Format "yyyy-MM-dd_HHmm"))
$list = Invoke-RestMethod "$base/fotos" -TimeoutSec 10
if (-not $list.files -or $list.files.Count -eq 0) { "No hay fotos en el ESP32."; return }
New-Item -ItemType Directory -Force $dest | Out-Null
$ok = 0
foreach ($f in $list.files) {
  try { Invoke-WebRequest "$base/foto?f=$f" -OutFile (Join-Path $dest $f) -TimeoutSec 20; $ok++ }
  catch { "fallo: $f" }
}
"$ok de $($list.files.Count) fotos en $dest"
if ($Borrar -and $ok -eq $list.files.Count) {
  Invoke-RestMethod "$base/foto?borrar=todas" -TimeoutSec 30 | Out-Null
  "Fotos borradas del ESP32."
}
