<#
Descifra en la PC las fotos de la cola de una tarjeta SD de la cámara (las que
todavía no se subieron), por ejemplo si la cámara se dañó y solo queda la tarjeta.

  1. Clave de la cámara (por cable, con la cámara conectada):
       .\camara.ps1 clavesd
  2. Pon la tarjeta en la PC (aparece como una unidad, p. ej. E:) y ejecuta:
       .\descifrar_sd.ps1 -Tarjeta E:\ -Clave 00112233445566778899aabbccddeeff
  3. Las fotos quedan en la carpeta "fotos_descifradas" (o en -Salida).

Cifrado: AES-128 en modo CTR (ver docs/SEGURIDAD.md). Cada archivo /q/XXX/YYY.JPG
tiene una cabecera de 24 bytes (marca, arranque, hora en ms, ms desde el
arranque, pasajeros) y luego el JPEG. Marca "TXQ3" = cifrado, "TXQ2" = sin cifrar.
#>
param(
  [Parameter(Mandatory)][string]$Tarjeta,
  [Parameter(Mandatory)][string]$Clave,
  [string]$Salida = ".\fotos_descifradas"
)

if ($Clave -notmatch '^[0-9a-fA-F]{32}$') { Write-Host "La clave tiene que ser de 32 caracteres hexadecimales (la que muestra camara.ps1 clavesd)."; exit 1 }
$k = [byte[]]::new(16)
for ($i = 0; $i -lt 16; $i++) { $k[$i] = [Convert]::ToByte($Clave.Substring($i * 2, 2), 16) }

$cola = Join-Path $Tarjeta "q"
if (-not (Test-Path $cola)) { Write-Host "No encuentro la carpeta q en $Tarjeta (¿es la tarjeta de la cámara?)."; exit 1 }
New-Item -ItemType Directory -Force $Salida | Out-Null

# AES-CTR con el AES de Windows: cada bloque de 16 bytes se mezcla con el
# contador cifrado. El contador empieza en [arranque | ms | 0…0] y sube de a 1
# (como un número de 128 bits, el último byte es el menos significativo).
$aes = [Security.Cryptography.Aes]::Create()
$aes.Mode = [Security.Cryptography.CipherMode]::ECB
$aes.Padding = [Security.Cryptography.PaddingMode]::None
$aes.Key = $k
$enc = $aes.CreateEncryptor()

function Descifrar([byte[]]$datos, [int]$ini, [int]$largo, [byte[]]$contador) {
  $out = [byte[]]::new($largo)
  $bloque = [byte[]]::new(16)
  for ($p = 0; $p -lt $largo; $p += 16) {
    $null = $enc.TransformBlock($contador, 0, 16, $bloque, 0)
    $n = [Math]::Min(16, $largo - $p)
    for ($j = 0; $j -lt $n; $j++) { $out[$p + $j] = $datos[$ini + $p + $j] -bxor $bloque[$j] }
    for ($c = 15; $c -ge 0; $c--) { $contador[$c] = ($contador[$c] + 1) % 256; if ($contador[$c] -ne 0) { break } }
  }
  return $out
}

$ok = 0; $mal = 0
foreach ($f in Get-ChildItem $cola -Recurse -Filter *.JPG | Sort-Object FullName) {
  $d = [IO.File]::ReadAllBytes($f.FullName)
  if ($d.Length -le 26) { $mal++; continue }
  $marca = [Text.Encoding]::ASCII.GetString($d, 0, 4)
  $boot = [BitConverter]::ToUInt32($d, 4)
  $tsMs = [BitConverter]::ToUInt64($d, 8)
  $ms = [BitConverter]::ToUInt32($d, 16)
  $pax = [BitConverter]::ToInt32($d, 20)
  if ($marca -eq "TXQ3") {
    $ctr = [byte[]]::new(16)
    [Array]::Copy($d, 4, $ctr, 0, 4)    # arranque
    [Array]::Copy($d, 16, $ctr, 4, 4)   # ms desde el arranque
    $jpg = Descifrar $d 24 ($d.Length - 24) $ctr
  } elseif ($marca -eq "TXQ2") {
    $jpg = $d[24..($d.Length - 1)]
  } else { $mal++; continue }
  if ($jpg[0] -ne 0xFF -or $jpg[1] -ne 0xD8) { $mal++; continue }   # clave equivocada o archivo dañado
  $nombre = if ($tsMs -gt 0) { [DateTimeOffset]::FromUnixTimeMilliseconds([int64]$tsMs).ToLocalTime().ToString("yyyy-MM-dd_HH-mm-ss-fff") } else { "arranque$boot`_ms$ms" }
  [IO.File]::WriteAllBytes((Join-Path $Salida "$nombre`_${pax}pax.jpg"), [byte[]]$jpg)
  $ok++
}
Write-Host "Descifradas: $ok fotos en $((Resolve-Path $Salida).Path)"
if ($mal) { Write-Host "No se pudieron leer: $mal (clave equivocada, o archivos dañados por un corte de corriente)." }
