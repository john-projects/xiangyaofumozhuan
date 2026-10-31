$ErrorActionPreference='Stop'
$destination='E:\dream\godot\各种UI图\units\enemies'
$jobs=Get-Content -LiteralPath (Join-Path $PSScriptRoot 'manifest.json') -Raw -Encoding UTF8 | ConvertFrom-Json
foreach($job in $jobs){
  $target=Join-Path $destination ($job.name+'.png')
  if(Test-Path -LiteralPath $target){throw "Refusing to overwrite existing file: $target"}
  if(-not(Test-Path -LiteralPath $job.path)){throw "Missing generated file: $($job.path)"}
}
foreach($job in $jobs){
  $target=Join-Path $destination ($job.name+'.png')
  [System.IO.File]::Copy($job.path,$target,$false)
  if((Get-FileHash -LiteralPath $job.path).Hash -ne (Get-FileHash -LiteralPath $target).Hash){throw "Copy verification failed: $target"}
}
$images=Get-ChildItem -LiteralPath $destination -File | Where-Object Extension -In '.png','.jpg','.jpeg','.webp'
$missing=@(Get-ChildItem -LiteralPath $destination -Filter '*.txt' -File | Where-Object {$_.BaseName -ne '00_通用规范'} | Where-Object {$stem=$_.BaseName; -not($images | Where-Object {$_.BaseName -eq $stem -or $_.BaseName.StartsWith($stem+'-') -or $_.BaseName.StartsWith($stem+'_')})})
[pscustomobject]@{copied=$jobs.Count; remainingMissing=$missing.Count; destination=$destination} | ConvertTo-Json -Compress
