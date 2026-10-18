@echo off
setlocal enabledelayedexpansion

echo ================================================================
echo      EP4CE10 + W25Q16 (EPCS16) Flash 一键自动固化烧录工具
echo ================================================================

set "QUARTUS_DIR=C:\altera\13.1\quartus\bin64"
set "CPF=%QUARTUS_DIR%\quartus_cpf.exe"
set "PGM=%QUARTUS_DIR%\quartus_pgm.exe"
set "JTAG=%QUARTUS_DIR%\jtagconfig.exe"

if not exist "%PGM%" (
    echo [错误] 未在 %QUARTUS_DIR% 找到 Quartus 编程工具！
    pause
    exit /b 1
)

if not exist "sdram.sof" (
    echo [错误] 当前目录下没有找到 sdram.sof，请先在 Quartus 中完整编译工程！
    pause
    exit /b 1
)

:: 检查是否需要重新生成 jic
echo [1/3] 检查并生成最新的 sdram.jic ...
"%CPF%" -c -d EPCS16 -s EP4CE10 sdram.sof sdram.jic
if errorlevel 1 (
    echo [错误] 生成 sdram.jic 失败！
    pause
    exit /b 1
)
echo [1/3] sdram.jic 生成完成！

:: 检测 USB-Blaster 下载器
echo [2/3] 检测 USB-Blaster 下载器连接状态 ...
:CHECK_CABLE
for /f "tokens=*" %%i in ('"%JTAG%"') do (
    set "LINE=%%i"
    echo !LINE! | findstr /i "USB-Blaster" >nul
    if not errorlevel 1 (
        echo [2/3] 成功识别到下载器: !LINE!
        goto PROCEED_FLASH
    )
)

echo [提示] 当前未检测到 USB-Blaster 下载器，请检查：
echo        1. USB-Blaster 是否已牢固插入电脑 USB 口；
echo        2. 开发板是否已开启电源；
echo        3. 10-pin JTAG 排线是否插紧。
echo.
set /p RETRY="插入后按回车(Enter)重新检测，或输入 Q 退出: "
if /i "%RETRY%"=="Q" exit /b 1
goto CHECK_CABLE

:PROCEED_FLASH
echo.
echo [3/3] 正在通过 JTAG 间接向板载 W25Q16 Flash 烧录配置...
echo       (耗时约 10~20 秒，请勿拔掉数据线或关闭电源)
echo.

"%PGM%" program_flash.cdf
if errorlevel 1 (
    echo.
    echo [错误] 烧录失败！请检查 JTAG 连接后重试。
    pause
    exit /b 1
)

echo.
echo ================================================================
echo [成功] W25Q16 Flash 烧录固化完成！
echo        请重新插拔开发板电源（或按开发板上的电源开关复位），
echo        FPGA 将自动从 Flash 加载程序，掉电不再丢失！
echo ================================================================
echo.
pause
