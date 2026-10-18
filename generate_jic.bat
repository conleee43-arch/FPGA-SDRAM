@echo off
setlocal
set "CPF=C:\altera\13.1\quartus\bin64\quartus_cpf.exe"

if not exist "%CPF%" (
    echo [ERROR] Cannot find quartus_cpf.exe at %CPF%
    exit /b 1
)

if not exist "sdram.sof" (
    echo [ERROR] Cannot find sdram.sof in current directory. Please compile in Quartus first.
    exit /b 1
)

echo Generating sdram.jic for EPCS16...
"%CPF%" -c -d EPCS16 -s EP4CE10 sdram.sof sdram.jic
if errorlevel 1 (
    echo [ERROR] Failed to generate sdram.jic!
    exit /b 1
)
echo Successfully generated sdram.jic.

echo Generating sdram_epcs64.jic for EPCS64 (fallback)...
"%CPF%" -c -d EPCS64 -s EP4CE10 sdram.sof sdram_epcs64.jic
if errorlevel 1 (
    echo [WARN] Failed to generate sdram_epcs64.jic.
) else (
    echo Successfully generated sdram_epcs64.jic.
)

echo All done! You can now program sdram.jic into Flash using Quartus Programmer.
endlocal
