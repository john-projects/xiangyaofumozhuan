$ErrorActionPreference='Stop'
$destination='E:\dream\godot\各种UI图\map'
$jobs=Get-Content -LiteralPath (Join-Path $PSScriptRoot 'manifest.json') -Raw -Encoding UTF8 | ConvertFrom-Json
if($jobs.Count -ne 27){throw 'Expected 27 complete maps'}
foreach($job in $jobs){if(-not(Test-Path -LiteralPath $job.path)){throw "Missing generated file: $($job.path)"}}
$existing=@(Get-ChildItem -LiteralPath $destination -File -Filter '*.png' | Where-Object {$stem=$_.BaseName; @($jobs | Where-Object {$stem -eq $_.name -or $stem.StartsWith($_.name+'-') -or $stem.StartsWith($_.name+'_')}).Count -gt 0})
$backup=Join-Path $destination ('_backup_before_regenerate_'+(Get-Date -Format 'yyyyMMdd_HHmmss'))
New-Item -ItemType Directory -Path $backup | Out-Null
foreach($file in $existing){
  $target=Join-Path $backup $file.Name
  [System.IO.File]::Copy($file.FullName,$target,$false)
  if((Get-FileHash -LiteralPath $file.FullName).Hash -ne (Get-FileHash -LiteralPath $target).Hash){throw "Backup verification failed: $target"}
}
foreach($job in $jobs){
  $target=Join-Path $destination ($job.name+'-ai.png')
  [System.IO.File]::Copy($job.path,$target,$true)
  if((Get-FileHash -LiteralPath $job.path).Hash -ne (Get-FileHash -LiteralPath $target).Hash){throw "Copy verification failed: $target"}
}
$missing=@($jobs | Where-Object {-not(Test-Path -LiteralPath (Join-Path $destination ($_.name+'-ai.png')))})
$report=[pscustomobject]@{saved=$jobs.Count;backedUp=$existing.Count;backup=$backup;remainingMissing=$missing.Count;destination=$destination;mode='built-in image_gen';format='1448x1086 RGBA PNG'}
$report | ConvertTo-Json | Set-Content -LiteralPath (Join-Path $PSScriptRoot 'delivery.json') -Encoding UTF8
$report | ConvertTo-Json -Compress
