Add-Type -AssemblyName System.Drawing
$jobs = Get-Content -LiteralPath (Join-Path $PSScriptRoot 'manifest.json') -Raw -Encoding UTF8 | ConvertFrom-Json
$sheet = New-Object System.Drawing.Bitmap(1250,1450)
$g = [System.Drawing.Graphics]::FromImage($sheet)
$g.Clear([System.Drawing.Color]::FromArgb(220,225,230))
$font = New-Object System.Drawing.Font('Microsoft YaHei',11)
$results = @()
$i = 0
foreach ($job in $jobs) {
  $img = [System.Drawing.Bitmap]::FromFile($job.path)
  $minAlpha = 255; $maxAlpha = 0
  for ($y=0; $y -lt $img.Height; $y+=16) { for ($x=0; $x -lt $img.Width; $x+=16) { $a=$img.GetPixel($x,$y).A; $minAlpha=[Math]::Min($minAlpha,$a); $maxAlpha=[Math]::Max($maxAlpha,$a) } }
  $results += [pscustomobject]@{name=$job.name; width=$img.Width; height=$img.Height; minAlpha=$minAlpha; maxAlpha=$maxAlpha; bytes=(Get-Item -LiteralPath $job.path).Length}
  $col=$i%5; $row=[Math]::Floor($i/5)
  $g.DrawImage($img,[int]($col*250+10),[int]($row*290+5),230,250)
  $g.DrawString($job.name,$font,[System.Drawing.Brushes]::Black,[single]($col*250+5),[single]($row*290+260))
  $img.Dispose(); $i++
}
$sheet.Save((Join-Path $PSScriptRoot 'contact_sheet.png'),[System.Drawing.Imaging.ImageFormat]::Png)
$g.Dispose(); $sheet.Dispose(); $font.Dispose()
$results | ConvertTo-Json | Set-Content -LiteralPath (Join-Path $PSScriptRoot 'verification.json') -Encoding UTF8
$results | Format-Table -AutoSize
