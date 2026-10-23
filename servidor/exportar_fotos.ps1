<#
Copia las fotos que recibió el servidor a una carpeta normal, con nombres
legibles: "14-05-33 (2 pasajeros).jpg", separadas por cámara y por día.

  .\exportar_fotos.ps1                         todas las fotos, al Escritorio\Fotos Taxiff
  .\exportar_fotos.ps1 -Dia 2026-10-22         solo ese día
  .\exportar_fotos.ps1 -SoloPasajeros          solo las fotos donde se vio a alguien
  .\exportar_fotos.ps1 -Destino D:\fotos
#>
param([string]$Dia = "", [switch]$SoloPasajeros,
      [string]$Destino = (Join-Path ([Environment]::GetFolderPath("Desktop")) "Fotos Taxiff"))

$origen = Join-Path $PSScriptRoot "datos\fotos"
if (-not (Test-Path $origen)) { Write-Host "Todavía no hay fotos en el servidor ($origen)."; exit 0 }
$copiadas = 0
foreach ($camara in Get-ChildItem $origen -Directory) {
  foreach ($carpetaDia in Get-ChildItem $camara.FullName -Directory | Where-Object { -not $Dia -or $_.Name -eq $Dia }) {
    $salida = Join-Path $Destino "$($camara.Name)\$($carpetaDia.Name)"
    foreach ($json in Get-ChildItem $carpetaDia.FullName -Filter *.json) {
      $jpg = [IO.Path]::ChangeExtension($json.FullName, ".jpg")
      if (-not (Test-Path $jpg)) { continue }
      $info = Get-Content $json.FullName -Raw | ConvertFrom-Json
      if ($SoloPasajeros -and -not $info.n) { continue }
      $hora = [DateTimeOffset]::FromUnixTimeMilliseconds([long]($info.ts * 1000)).ToLocalTime()
      $nombre = $hora.ToString("HH-mm-ss") + " ($($info.n) pasajero$(if ($info.n -ne 1) { 's' })$(if ($info.aprox) { ', hora aproximada' })).jpg"
      New-Item -ItemType Directory -Force $salida | Out-Null
      $archivo = Join-Path $salida $nombre
      if (-not (Test-Path $archivo)) { Copy-Item $jpg $archivo; $copiadas++ }
    }
  }
}
Write-Host "$copiadas fotos copiadas a $Destino"
