# Extracts clean training frames from a screen recording of the ESP32 page:
# crops the camera area, drops frames with the page's green detection box
# drawn on top, and drops near-duplicates.
param([string]$Video, [string]$Out, [string]$Crop = "1198:886:30:194", [double]$Fps = 2)

$ff = "C:\Users\ASUS Vivobook\.lunarclient\launcher-cache\Badlion Client\ffmpeg.exe"
$tmp = Join-Path $env:TEMP ("frames_" + [guid]::NewGuid().ToString("N"))
New-Item -ItemType Directory -Force $tmp, $Out | Out-Null
& $ff -hide_banner -loglevel error -y -i $Video -vf "fps=$Fps,crop=$Crop,scale=640:480" -q:v 2 "$tmp\f%04d.jpg"

Add-Type -ReferencedAssemblies System.Drawing -TypeDefinition @"
using System;
using System.Drawing;
using System.Drawing.Imaging;
using System.Runtime.InteropServices;

public static class FrameCheck {
    // Pixels close to the page's box colour #30c26b.
    public static int GreenPixels(string path, out byte[] thumb) {
        using (Bitmap b = new Bitmap(path)) {
            Rectangle r = new Rectangle(0, 0, b.Width, b.Height);
            BitmapData d = b.LockBits(r, ImageLockMode.ReadOnly, PixelFormat.Format24bppRgb);
            byte[] px = new byte[d.Stride * b.Height];
            Marshal.Copy(d.Scan0, px, 0, px.Length);
            b.UnlockBits(d);
            int green = 0;
            thumb = new byte[32 * 24];
            int[] sum = new int[32 * 24], cnt = new int[32 * 24];
            for (int y = 0; y < b.Height; y++) {
                for (int x = 0; x < b.Width; x++) {
                    int i = y * d.Stride + x * 3;
                    int bl = px[i], g = px[i + 1], rd = px[i + 2];
                    if (Math.Abs(rd - 48) < 40 && Math.Abs(g - 194) < 45 && Math.Abs(bl - 107) < 45) green++;
                    int t = (y * 24 / b.Height) * 32 + (x * 32 / b.Width);
                    sum[t] += (rd + g + bl) / 3; cnt[t]++;
                }
            }
            for (int t = 0; t < thumb.Length; t++) thumb[t] = (byte)(sum[t] / Math.Max(1, cnt[t]));
            return green;
        }
    }

    public static double Diff(byte[] a, byte[] b) {
        double s = 0;
        for (int i = 0; i < a.Length; i++) s += Math.Abs(a[i] - b[i]);
        return s / a.Length;
    }
}
"@

$kept = 0; $boxed = 0; $dup = 0; $prev = $null
$name = [IO.Path]::GetFileNameWithoutExtension($Video) -replace '[^\w]+', '_'
foreach ($f in Get-ChildItem $tmp -Filter *.jpg | Sort-Object Name) {
  $thumb = $null
  $g = [FrameCheck]::GreenPixels($f.FullName, [ref]$thumb)
  if ($g -gt 150) { $boxed++; continue }
  if ($prev -and [FrameCheck]::Diff($thumb, $prev) -lt 4) { $dup++; continue }
  $prev = $thumb
  $kept++
  Copy-Item $f.FullName (Join-Path $Out ("{0}_{1:000}.jpg" -f $name, $kept))
}
Remove-Item -Recurse -Force $tmp
"guardadas: $kept | descartadas con caja verde: $boxed | casi repetidas: $dup"
