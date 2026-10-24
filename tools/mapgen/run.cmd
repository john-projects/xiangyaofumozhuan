@echo off
setlocal
chcp 65001 >nul
set "PYTHONIOENCODING=utf-8"
set "PY="

call :check "python"
if not defined PY call :check "%USERPROFILE%\.dsh\dsh-runtimes\dsh-primary-runtime\dependencies\python\python.exe"

if not defined PY (
    echo [ERROR] No usable Python. Need 3.10+ with pillow and numpy.
    echo         Install: pip install pillow numpy
    exit /b 1
)

"%PY%" "%~dp0mapgen.py" %*
exit /b %ERRORLEVEL%

:check
if defined PY goto :eof
if "%~1"=="" goto :eof
"%~1" -c "import PIL, numpy" >nul 2>nul && set "PY=%~1"
goto :eof
