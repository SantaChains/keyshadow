@echo off
chcp 65001 >nul
cd /d "%~dp0"

rem ============================================================================
rem Ctrl2Enter 编译脚本
rem 依赖: AutoHotkey v2 完整版 (含 Ahk2Exe 编译器)
rem   下载: https://www.autohotkey.com/ (安装后 Compiler\Ahk2Exe.exe 可用)
rem 参考: SpaceKey 项目的内嵌 AutoHotkey64.exe 做法
rem ============================================================================

setlocal EnableDelayedExpansion

set "SRC=Ctrl2Enter.ahk"
set "OUT=Ctrl2Enter.exe"
set "BASE=%~dp0AutoHotkey64.exe"

rem ---- 定位 Ahk2Exe 编译器 ----
set "COMPILER="
if exist "%~dp0Ahk2Exe.exe" (
    set "COMPILER=%~dp0Ahk2Exe.exe"
)
if "!COMPILER!"=="" if exist "D:\Soft\Ahk2Exe.exe" (
    set "COMPILER=D:\Soft\Ahk2Exe.exe"
)
if "!COMPILER!"=="" if exist "C:\Program Files\AutoHotkey\Compiler\Ahk2Exe.exe" (
    set "COMPILER=C:\Program Files\AutoHotkey\Compiler\Ahk2Exe.exe"
)
if "!COMPILER!"=="" (
    for /d %%d in ("C:\Program Files\AutoHotkey\v2*") do (
        if exist "%%d\Compiler\Ahk2Exe.exe" set "COMPILER=%%d\Compiler\Ahk2Exe.exe"
    )
)
if "!COMPILER!"=="" (
    for /d %%d in ("%~dp0tools\*") do (
        if exist "%%d\Ahk2Exe.exe" set "COMPILER=%%d\Ahk2Exe.exe"
    )
)

rem ---- 前置检查 ----
if not exist "!COMPILER!" (
    echo [错误] 未找到 Ahk2Exe.exe 编译器
    echo.
    echo   请安装 AutoHotkey v2 完整版： https://www.autohotkey.com/
    echo   或手动放置 Ahk2Exe.exe 到以下任一位置：
    echo     1. 本目录下   : build.cmd 同级
    echo     2. %APPDATA%\AutoHotkey\tools\
    echo.
    pause
    exit /b 1
)

if not exist "%SRC%" (
    echo [错误] 未找到源脚本：%SRC%
    pause
    exit /b 1
)

if not exist "%BASE%" (
    echo [警告] 项目内未找到 AutoHotkey64.exe，尝试使用编译器自带...
    set "BASE="
)

rem ---- 信息 ----
echo [信息] 编译器  : !COMPILER!
echo [信息] 源脚本  : %SRC%
echo [信息] 输出    : %OUT%
echo [信息] v2 基础  : %BASE%
echo [信息] 图标    : 脚本头部内联 (@Ahk2Exe-SetMainIcon logo.ico)

rem ---- 编译 ----
if defined BASE (
    "!COMPILER!" /in "%SRC%" /out "%OUT%" /base "%BASE%"
) else (
    "!COMPILER!" /in "%SRC%" /out "%OUT%"
)

if exist "%OUT%" (
    echo.
    echo [完成] 已生成 %OUT%   大小约 %~zOUT% 字节
    exit /b 0
) else (
    echo.
    echo [失败] 编译未生成 %OUT%，请检查上方报错信息
    pause
    exit /b 1
)
