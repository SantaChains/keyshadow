@echo off
chcp 65001 >nul
REM ============================================================================
REM KeyMultiMap 一键打包脚本（需已安装 AutoHotkey v2）
REM   - 自动定位 Ahk2Exe 与 v2 运行时基础文件
REM   - 将 KeyMultiMap.ahk 编译为 KeyMultiMap.exe，并嵌入 logo.ico
REM ============================================================================
cd /d "%~dp0"

set "AHK=C:\Program Files\AutoHotkey"
set "COMPILER=%AHK%\Compiler\Ahk2Exe.exe"
set "SRC=KeyMultiMap.ahk"
set "OUT=KeyMultiMap.exe"
set "ICO=logo.ico"
set "BASE="

REM 自动查找 v2 基础：优先官方默认的 v2 目录，回退到任意 v2*/AutoHotkey64.exe
if exist "%AHK%\v2\AutoHotkey64.exe" (
    set "BASE=%AHK%\v2\AutoHotkey64.exe"
) else (
    for /d %%d in ("%AHK%\v2*") do (
        if exist "%%d\AutoHotkey64.exe" set "BASE=%%d\AutoHotkey64.exe"
    )
)

if not exist "%COMPILER%" (
    echo [错误] 未找到 Ahk2Exe：%COMPILER%
    echo         请先安装 AutoHotkey v2（https://www.autohotkey.com/）
    pause
    exit /b 1
)

if not exist "%SRC%" (
    echo [错误] 未找到源脚本：%SRC%
    pause
    exit /b 1
)

echo [信息] 编译器  : %COMPILER%
echo [信息] 源脚本  : %SRC%
if defined BASE (
    echo [信息] v2 基础  : %BASE%
) else (
    echo [警告] 未自动定位 v2 基础文件，将尝试不带 /base 编译
)

if defined BASE (
    "%COMPILER%" /in "%SRC%" /out "%OUT%" /icon "%ICO%" /base "%BASE%"
) else (
    "%COMPILER%" /in "%SRC%" /out "%OUT%" /icon "%ICO%"
)

if exist "%OUT%" (
    echo [完成] 已生成 %OUT%  （大小约 %~zOUT% 字节）
) else (
    echo [失败] 编译未生成 %OUT%，请检查上方报错信息
    pause
    exit /b 1
)
pause
