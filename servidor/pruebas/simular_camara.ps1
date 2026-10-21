# Simulates an ESP32 camera against the server: registers, then sends photos
# with fake timestamps (one per second) to walk through a whole trip:
# empty cabin -> passenger -> empty again.
# Usage: .\simular_camara.ps1 [-Server http://localhost:8000] [-Id TX-SIM001]
param([string]$Server = "http://localhost:8000", [string]$Id = "TX-SIM001",
      [string]$Fotos = "$PSScriptRoot\..\..\esp32\datos\para_roboflow")

$reg = try { Invoke-RestMethod "$Server/api/v1/registro" -Method Post -ContentType "application/json" -Body (@{ id = $Id; fw = "simulador" } | ConvertTo-Json) } catch { $null }
if (-not $reg) { "El ID $Id ya tiene token: usa otro -Id o reinícialo en el panel."; return }
$tok = $reg.token
"registrada $Id (aprobada: $($reg.aprobado))"

$conGente = Get-ChildItem $Fotos -Filter "esp32_noche_*.jpg" | Sort-Object Name | Select-Object -First 40
# "Empty" cabin: a frame with the person cropped away is not available, so a
# black JPEG stands in for an empty, dark cabin.
Add-Type -AssemblyName System.Drawing
$vacia = Join-Path $env:TEMP "taxiff_vacia.jpg"
$b = New-Object Drawing.Bitmap 640, 480; $g = [Drawing.Graphics]::FromImage($b); $g.Clear([Drawing.Color]::FromArgb(20, 22, 20)); $g.Dispose(); $b.Save($vacia, [Drawing.Imaging.ImageFormat]::Jpeg); $b.Dispose()

$secuencia = @($vacia) * 5 + @($conGente.FullName) + @($vacia) * 15
$t0 = [DateTimeOffset]::Now.ToUnixTimeSeconds() - $secuencia.Count
$i = 0
foreach ($f in $secuencia) {
  $h = @{ "X-Dispositivo" = $Id; "Authorization" = "Bearer $tok"; "X-Ts" = ($t0 + $i); "X-Conteo" = 0; "X-Temp" = 50; "X-Rssi" = -55; "X-Fw" = "simulador" }
  $r = Invoke-RestMethod "$Server/api/v1/foto" -Method Post -Headers $h -ContentType "image/jpeg" -InFile $f
  if ($i % 5 -eq 0 -or $r.estado -ne $prev) { "t=$i s  pasajeros=$($r.pasajeros)  estado=$($r.estado)  modo=$($r.modo)" }
  $prev = $r.estado; $i++
}
"--- carreras guardadas ---"
$cred = [Convert]::ToBase64String([Text.Encoding]::ASCII.GetBytes("admin:taxiff"))
Invoke-RestMethod "$Server/api/panel/carreras" -Headers @{ Authorization = "Basic $cred" } | Where-Object { $_.dispositivo -eq $Id } |
  ForEach-Object { "duracion $([int]$_.duracion) s · max $($_.max_pax) pasajero(s) · valida $($_.valida) · $($_.fotos.Count) fotos de evidencia" }
