# Builds dataset_cabezas_v2 for Edge Impulse (FOMO, ESP32) from the Roboflow
# YOLOv8 export with head boxes:
# - train + valid -> training, test -> testing
# - ESP32 frames use the original 640x480 photo (Roboflow squashed them to
#   512x512; normalized YOLO boxes are the same in both)
# - adds ESP32-like copies (low res, strong JPEG, noise, dark) and 180 deg
#   rotations; real ESP32 frames only get the rotated copies
# - class "cabeza", files with LF line endings
param([string]$Src = "$PSScriptRoot\..\datos\roboflow_taxcab_v1",
      [string]$EspOriginals = "$PSScriptRoot\..\datos\para_roboflow",
      [string]$Out = "$PSScriptRoot\..\datos\dataset_cabezas_v2")

Add-Type -ReferencedAssemblies System.Drawing -TypeDefinition @"
using System;
using System.Drawing;
using System.Drawing.Imaging;
using System.Runtime.InteropServices;

public static class EspAug {
    static ImageCodecInfo jpegCodec() {
        foreach (ImageCodecInfo c in ImageCodecInfo.GetImageEncoders())
            if (c.MimeType == "image/jpeg") return c;
        return null;
    }

    public static void SaveJpeg(Bitmap b, string path, long q) {
        EncoderParameters p = new EncoderParameters(1);
        p.Param[0] = new EncoderParameter(System.Drawing.Imaging.Encoder.Quality, q);
        b.Save(path, jpegCodec(), p);
    }

    public static Bitmap Load(string path) {
        using (Image im = Image.FromFile(path)) {
            Bitmap b = new Bitmap(im.Width, im.Height, PixelFormat.Format24bppRgb);
            using (Graphics g = Graphics.FromImage(b)) g.DrawImage(im, 0, 0, im.Width, im.Height);
            return b;
        }
    }

    // Shrinks to `small` px wide and back up: loses detail like the OV3660 at QVGA.
    public static Bitmap Resample(Bitmap src, int small) {
        int sh = Math.Max(1, src.Height * small / src.Width);
        Bitmap a = new Bitmap(small, sh);
        using (Graphics g = Graphics.FromImage(a)) {
            g.InterpolationMode = System.Drawing.Drawing2D.InterpolationMode.HighQualityBilinear;
            g.DrawImage(src, 0, 0, small, sh);
        }
        Bitmap b = new Bitmap(src.Width, src.Height, PixelFormat.Format24bppRgb);
        using (Graphics g = Graphics.FromImage(b)) {
            g.InterpolationMode = System.Drawing.Drawing2D.InterpolationMode.Bilinear;
            g.DrawImage(a, 0, 0, src.Width, src.Height);
        }
        a.Dispose();
        return b;
    }

    // Brightness gain, washed-out contrast, colour cast and sensor noise.
    public static void Degrade(Bitmap b, double gain, double contrast, int noise, int seed, int castR, int castB) {
        Random rnd = new Random(seed);
        Rectangle r = new Rectangle(0, 0, b.Width, b.Height);
        BitmapData d = b.LockBits(r, ImageLockMode.ReadWrite, PixelFormat.Format24bppRgb);
        int n = d.Stride * b.Height;
        byte[] px = new byte[n];
        Marshal.Copy(d.Scan0, px, 0, n);
        for (int y = 0; y < b.Height; y++) {
            for (int x = 0; x < b.Width; x++) {
                int i = y * d.Stride + x * 3;
                int nz = noise > 0 ? rnd.Next(-noise, noise + 1) : 0;
                for (int c = 0; c < 3; c++) {
                    double v = px[i + c];
                    v = (v - 128) * contrast + 128;
                    v = v * gain + nz;
                    if (c == 2) v += castR;
                    if (c == 0) v += castB;
                    px[i + c] = (byte)Math.Max(0, Math.Min(255, v));
                }
            }
        }
        Marshal.Copy(px, 0, d.Scan0, n);
        b.UnlockBits(d);
    }
}
"@

if (Test-Path $Out) { Remove-Item -Recurse -Force $Out }
foreach ($s in "training", "testing") { New-Item -ItemType Directory -Force "$Out\$s\images", "$Out\$s\labels" | Out-Null }

# Variants: name, resample width (0 = none), gain, contrast, noise, jpeg q, rotate180, castR, castB
$variants = @(
  @("orig", 0,   1.0,  1.0,  0,  92, $false, 0, 0),
  @("esp",  240, 1.05, 0.8,  10, 30, $false, 6, -4),
  @("dark", 200, 0.55, 1.15, 16, 25, $false, 0, 8),
  @("rot",  240, 1.0,  0.85, 10, 30, $true,  0, 0),
  @("rotd", 200, 0.6,  1.1,  14, 25, $true,  4, 4)
)
$espVariants = @("orig", "rot")  # real ESP32 frames are already low quality

$lf = "`n"
$stats = @{ base = 0; esp = 0; boxes = 0 }
$seed = 1
foreach ($split in "train", "valid", "test") {
  $dest = if ($split -eq "test") { "testing" } else { "training" }
  foreach ($img in Get-ChildItem "$Src\$split\images" -Filter *.jpg) {
    $lab = "$Src\$split\labels\$($img.BaseName).txt"
    if (-not (Test-Path $lab)) { continue }
    $boxes = @()
    foreach ($line in [IO.File]::ReadAllLines($lab)) {
      $p = $line.Trim() -split '\s+'
      if ($p.Count -ge 5) { $boxes += ,@([double]$p[1], [double]$p[2], [double]$p[3], [double]$p[4]) }
    }
    if ($boxes.Count -eq 0) { continue }

    # Roboflow names files "<original>_jpg.rf.<hash>.jpg".
    $orig = ($img.Name -split '_jpg\.rf\.')[0]
    $isEsp = $orig -like "esp32_*"
    $path = $img.FullName
    if ($isEsp -and (Test-Path "$EspOriginals\$orig.jpg")) { $path = "$EspOriginals\$orig.jpg" }
    $srcBmp = [EspAug]::Load($path)
    if ($isEsp) { $stats.esp++ } else { $stats.base++ }
    $stats.boxes += $boxes.Count

    foreach ($v in $variants) {
      if ($isEsp -and $v[0] -notin $espVariants) { continue }
      $name = "$orig`_$($v[0])"
      $b = if ($v[1] -gt 0) { [EspAug]::Resample($srcBmp, $v[1]) } else { $srcBmp.Clone() }
      if ($v[0] -ne "orig") { [EspAug]::Degrade($b, $v[2], $v[3], $v[4], $seed++, $v[7], $v[8]) }
      $rot = $v[6]
      if ($rot) { $b.RotateFlip([Drawing.RotateFlipType]::Rotate180FlipNone) }
      [EspAug]::SaveJpeg($b, "$Out\$dest\images\$name.jpg", $v[5])
      $b.Dispose()
      $txt = foreach ($hb in $boxes) {
        $cx = if ($rot) { 1 - $hb[0] } else { $hb[0] }
        $cy = if ($rot) { 1 - $hb[1] } else { $hb[1] }
        [string]::Format([Globalization.CultureInfo]::InvariantCulture, "0 {0:0.000000} {1:0.000000} {2:0.000000} {3:0.000000}", $cx, $cy, $hb[2], $hb[3])
      }
      [IO.File]::WriteAllText("$Out\$dest\labels\$name.txt", (($txt -join $lf) + $lf))
    }
    $srcBmp.Dispose()
  }
}

# Edge Impulse reads the class name from these; LF only, so it is exactly "cabeza".
$yaml = "train: training/images${lf}val: testing/images${lf}nc: 1${lf}names: ['cabeza']${lf}"
foreach ($dir in $Out, "$Out\training", "$Out\testing") {
  [IO.File]::WriteAllText("$dir\data.yaml", $yaml)
  [IO.File]::WriteAllText("$dir\classes.txt", "cabeza$lf")
}

$tr = (Get-ChildItem "$Out\training\images").Count; $te = (Get-ChildItem "$Out\testing\images").Count
"fotos base: $($stats.base) | fotos reales ESP32: $($stats.esp) | cabezas: $($stats.boxes)"
"generadas: training $tr, testing $te"
