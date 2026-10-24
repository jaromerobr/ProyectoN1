<#
Compila el firmware de la cámara y lo carga por el cable USB (puerto UART).

  .\cargar_firmware.ps1                  compila y carga (usa el primer puerto COM)
  .\cargar_firmware.ps1 -Puerto COM5
  .\cargar_firmware.ps1 -SoloCompilar    solo genera el .bin (para publicarlo en el panel del servidor)

Requiere arduino-cli con el core esp32 2.0.17 (ver esp32/README.md).
#>
param([string]$Puerto = "", [switch]$SoloCompilar)

$ErrorActionPreference = "Stop"
$raiz = Resolve-Path "$PSScriptRoot\..\.."
$sketch = Join-Path $raiz "esp32\firmware\taxiff_cam"
$salida = Join-Path $raiz "build_esp32"
$fqbn = "esp32:esp32:esp32s3:PSRAM=opi,FlashSize=16M,PartitionScheme=app3M_fat9M_16MB,CDCOnBoot=default"

$cli = (Get-Command arduino-cli -ErrorAction SilentlyContinue).Source
if (-not $cli) { $cli = "$HOME\arduino-cli\arduino-cli.exe" }
if (-not (Test-Path $cli)) { Write-Host "No encuentro arduino-cli. Instálalo (ver esp32/README.md)."; exit 1 }
$paquetes = "$env:LOCALAPPDATA\Arduino15\packages\esp32"
$esptool = Get-ChildItem "$paquetes\tools\esptool_py\*\esptool.exe" -ErrorAction SilentlyContinue | Sort-Object FullName | Select-Object -Last 1
$bootApp0 = "$paquetes\hardware\esp32\2.0.17\tools\partitions\boot_app0.bin"
if (-not $esptool -or -not (Test-Path $bootApp0)) {
  Write-Host "Falta el core esp32 2.0.17. Instálalo con:"
  Write-Host "  arduino-cli core install esp32:esp32@2.0.17"
  exit 1
}

# Librería del modelo de cabezas: se instala desde el repositorio si falta.
$libs = Join-Path ([Environment]::GetFolderPath("MyDocuments")) "Arduino\libraries"
if (-not (Test-Path "$libs\taxiff-cabezas-v2_inferencing")) {
  Write-Host "Instalando la librería del modelo..."
  New-Item -ItemType Directory -Force $libs | Out-Null
  Expand-Archive (Join-Path $raiz "esp32\firmware\librerias\ei-taxiff-cabezas-v2-arduino-1.0.1.zip") $libs -Force
}

# Clave de administración de las cámaras: va en secretos.h, que no se sube a
# GitHub. La primera vez se crea con una clave al azar.
$secretos = Join-Path $sketch "secretos.h"
if (-not (Test-Path $secretos)) {
  $abc = "abcdefghijkmnpqrstuvwxyzABCDEFGHJKLMNPQRSTUVWXYZ23456789".ToCharArray()
  $rng = [Security.Cryptography.RandomNumberGenerator]::Create()
  $b = New-Object byte[] 14; $rng.GetBytes($b)
  $clave = -join ($b | ForEach-Object { $abc[$_ % $abc.Length] })
  # Sin BOM ni acentos: el compilador no acepta la marca BOM de UTF-8.
  $texto = "// Clave de administracion de las camaras (pagina en vivo, ajustes, fotos).`n" +
           "// Usuario: admin. NO se sube a GitHub. Guardala en un lugar seguro.`n" +
           "#define CLAVE_ADMIN `"$clave`"`n"
  [IO.File]::WriteAllText($secretos, $texto, (New-Object Text.UTF8Encoding $false))
  Write-Host "Se creó la clave de administración de las cámaras en $secretos"
  Write-Host "  usuario: admin   clave: $clave"
}

$version = (Select-String -Path "$sketch\taxiff_cam.ino" -Pattern 'FW_VERSION = "([\d\.]+)"').Matches[0].Groups[1].Value
Write-Host "Compilando firmware $version (la primera vez tarda varios minutos)..."
& $cli compile -b $fqbn --output-dir $salida $sketch 2>&1 | Select-String "error|Sketch uses" | ForEach-Object { Write-Host "  $($_.Line)" }
if ($LASTEXITCODE -ne 0) { Write-Host "La compilación falló."; exit 1 }
$bin = Join-Path $salida "taxiff_cam.ino.bin"
Write-Host "Listo: $bin"
Write-Host "Para actualizar las cámaras por internet: súbelo en el panel (Firmware de las cámaras) con la versión $version."
if ($SoloCompilar) { exit 0 }

if (-not $Puerto) { $Puerto = [System.IO.Ports.SerialPort]::GetPortNames() | Sort-Object | Select-Object -First 1 }
if (-not $Puerto) { Write-Host "No hay ninguna cámara conectada por USB (puerto UART)."; exit 1 }
Write-Host "Cargando en $Puerto..."
# El firmware va en los dos espacios (0x10000 y 0x310000): si alguna vez el
# primero queda dañado, la placa arranca el segundo, y antes ahí quedaba una
# versión vieja de una actualización por internet.
for ($i = 1; $i -le 3; $i++) {
  $o = & $esptool.FullName --chip esp32s3 --port $Puerto --baud 460800 write_flash -z --flash_mode dio --flash_freq 80m --flash_size 16MB `
    0x0 "$salida\taxiff_cam.ino.bootloader.bin" 0x8000 "$salida\taxiff_cam.ino.partitions.bin" `
    0xe000 $bootApp0 0x10000 $bin 0x310000 $bin 2>&1
  # Cada parte escrita se confirma por separado: tienen que estar las 5. (Antes
  # bastaba una, y un corte a mitad del firmware se daba por bueno.)
  $ok = @($o | Select-String "Hash of data verified").Count
  if ($ok -eq 5) { Write-Host "Firmware $version cargado. La cámara se reinicia sola."; exit 0 }
  Write-Host "  intento $i falló, reintentando..."
  Start-Sleep 3
}
Write-Host "No se pudo cargar. Prueba otro cable o puerto USB, o mantén pulsado BOOT al conectar."
exit 1
