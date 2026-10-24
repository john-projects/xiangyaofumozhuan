# mapgen 启动器：自动挑一个"装了 Pillow + numpy"的 Python。
# 用法：
#   .\run.ps1 demo --out out\demo
#   .\run.ps1 build --sketch layout.png --image ai.png --id taohuacun --out out\taohuacun
$ErrorActionPreference = "Stop"

# 让 Python 输出 UTF-8、控制台也按 UTF-8 解码，中文提示才不会乱码
$env:PYTHONIOENCODING = "utf-8"
try {
    [Console]::OutputEncoding = [System.Text.Encoding]::UTF8
    $OutputEncoding = [System.Text.Encoding]::UTF8
} catch { }

function Test-Python($exe) {
    if (-not $exe) { return $false }
    try {
        & $exe -c "import PIL, numpy" 2>$null | Out-Null
        return ($LASTEXITCODE -eq 0)
    } catch {
        return $false
    }
}

$candidates = @()
$cmd = Get-Command python -ErrorAction SilentlyContinue
if ($cmd) { $candidates += $cmd.Source }
$candidates += (Join-Path $env:USERPROFILE ".dsh\dsh-runtimes\dsh-primary-runtime\dependencies\python\python.exe")

$py = $null
foreach ($c in $candidates) {
    if (Test-Python $c) { $py = $c; break }
}

if (-not $py) {
    Write-Error "没有可用的 Python（需要 3.10+ 且装了 pillow、numpy）。安装：pip install pillow numpy"
    exit 1
}

& $py (Join-Path $PSScriptRoot "mapgen.py") @args
exit $LASTEXITCODE
