# Checks a YOLO TXT dataset: draws the boxes on N random images (orig, dark and
# rotated versions included) and reports boxes per image, mean relative size,
# images without boxes and out-of-range boxes.
# Usage: .\verificar_dataset.ps1 -Dataset <folder with training\ and testing\> [-N 30]
param([Parameter(Mandatory)][string]$Dataset, [int]$N = 30, [string]$Out = "")

if (-not $Out) { $Out = Join-Path $Dataset "_verificacion" }
New-Item -ItemType Directory -Force $Out | Out-Null
Add-Type -AssemblyName System.Drawing

$rows = @()
foreach ($split in "training", "testing") {
  foreach ($img in Get-ChildItem "$Dataset\$split\images" -Filter *.jpg) {
    $lab = "$Dataset\$split\labels\$($img.BaseName).txt"
    $boxes = @()
    if (Test-Path $lab) {
      foreach ($line in [IO.File]::ReadAllLines($lab)) {
        $p = $line.Trim() -split '\s+'
        if ($p.Count -ge 5) { $boxes += ,@([double]$p[1], [double]$p[2], [double]$p[3], [double]$p[4]) }
      }
    }
    $rows += [pscustomobject]@{ split = $split; img = $img.FullName; name = $img.BaseName; boxes = $boxes }
  }
}

$all = $rows | ForEach-Object { $_.boxes }
$noBox = ($rows | Where-Object { $_.boxes.Count -eq 0 }).Count
$bad = ($all | Where-Object { $_[0] - $_[2]/2 -lt -0.01 -or $_[0] + $_[2]/2 -gt 1.01 -or $_[1] - $_[3]/2 -lt -0.01 -or $_[1] + $_[3]/2 -gt 1.01 -or $_[2] -le 0 -or $_[3] -le 0 }).Count
$perImg = ($rows | ForEach-Object { $_.boxes.Count } | Measure-Object -Average -Maximum)
"imagenes: $($rows.Count) | cajas: $($all.Count) | cajas por imagen: media $([math]::Round($perImg.Average,2)), max $($perImg.Maximum)"
"tamano medio relativo: ancho $([math]::Round(($all | ForEach-Object { $_[2] } | Measure-Object -Average).Average,3)), alto $([math]::Round(($all | ForEach-Object { $_[3] } | Measure-Object -Average).Average,3))"
"imagenes sin caja: $noBox | cajas fuera de rango: $bad"
foreach ($cf in "$Dataset\training\classes.txt", "$Dataset\data.yaml") {
  if (Test-Path $cf) { $raw = [IO.File]::ReadAllBytes($cf); "$(Split-Path $cf -Leaf): $(if ($raw -contains 13) { 'TIENE CR (mal)' } else { 'solo LF (bien)' })" }
}

# Random sample, making sure every variant type appears.
$rnd = New-Object Random 7
$pick = @()
foreach ($kind in "orig", "esp", "dark", "rot", "rotd") {
  $pool = @($rows | Where-Object { $_.name -like "*_$kind" })
  if ($pool.Count) { 1..[math]::Ceiling($N / 5) | ForEach-Object { $pick += $pool[$rnd.Next($pool.Count)] } }
}
$pick = $pick | Select-Object -First $N
$t = 320; $cols = 6; $nrows = [math]::Ceiling($pick.Count / $cols)
$mosaic = New-Object Drawing.Bitmap ($t * $cols), ($t * $nrows)
$g = [Drawing.Graphics]::FromImage($mosaic)
$pen = New-Object Drawing.Pen ([Drawing.Color]::Lime), 3
$font = New-Object Drawing.Font "Arial", 11
for ($i = 0; $i -lt $pick.Count; $i++) {
  $im = [Drawing.Image]::FromFile($pick[$i].img)
  $x0 = ($i % $cols) * $t; $y0 = [math]::Floor($i / $cols) * $t
  $g.DrawImage($im, $x0, $y0, $t, $t); $im.Dispose()
  foreach ($b in $pick[$i].boxes) {
    $g.DrawRectangle($pen, [float]($x0 + ($b[0] - $b[2]/2) * $t), [float]($y0 + ($b[1] - $b[3]/2) * $t), [float]($b[2] * $t), [float]($b[3] * $t))
  }
  $g.DrawString($pick[$i].name, $font, [Drawing.Brushes]::Yellow, $x0 + 4, $y0 + 4)
}
$g.Dispose()
$path = Join-Path $Out "verificacion.jpg"
$mosaic.Save($path, [Drawing.Imaging.ImageFormat]::Jpeg); $mosaic.Dispose()
"mosaico: $path"
