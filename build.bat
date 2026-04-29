@echo off
REM Build ER Save Backup on Windows.
REM
REM Usage:
REM   build.bat          compile
REM   build.bat run      compile and launch
REM
REM Prerequisites (one-time):
REM   1. Odin installed and on PATH.
REM   2. MSVC build tools — launch from the "x64 Native Tools" command
REM      prompt or a Developer PowerShell so cl.exe is on PATH.
REM   3. Vulkan loader on PATH (bundled with recent GPU drivers; otherwise
REM      install the Vulkan SDK from https://vulkan.lunarg.com/).
REM   4. Skald checked out. Defaults to ..\Skald; set GUI_PATH to override.
REM
REM The SDL3 runtime DLL is copied next to the built .exe automatically.

setlocal
cd /d %~dp0

REM Resolve GUI_PATH to an absolute path. Using `%~dp0..\Skald` directly
REM produces a string with a literal `..` segment, which `if exist` and
REM PowerShell `.\build.bat` invocations don't always resolve reliably
REM (especially with spaces in the path). `for %%I ... %%~fI` forces
REM cmd to canonicalise the path — drive letter, no `..`, no trailing
REM slash. Skip the default if the caller already set GUI_PATH.
if defined GUI_PATH goto skip_gui_path_default
for %%I in ("%~dp0..\Skald") do set GUI_PATH=%%~fI
:skip_gui_path_default

if not exist "%GUI_PATH%\skald" (
    echo error: Skald not found at %GUI_PATH%
    echo        set GUI_PATH to your Skald checkout, or clone it next to this repo.
    exit /b 1
)

set ACTION=%1
if "%ACTION%"=="" set ACTION=build

if not exist build mkdir build

odin build . -collection:gui="%GUI_PATH%" -out:"build\ersavebackup.exe" -subsystem:windows
if errorlevel 1 exit /b 1

REM Copy SDL3.dll from Odin's vendor tree next to the exe.
for /f "delims=" %%I in ('where odin') do set ODIN_EXE=%%I
for %%I in ("%ODIN_EXE%") do set ODIN_ROOT=%%~dpI
set SDL3_DLL=%ODIN_ROOT%vendor\sdl3\SDL3.dll

if exist "%SDL3_DLL%" (
    copy /Y "%SDL3_DLL%" "build\" >nul
) else (
    echo WARNING: SDL3.dll not found at %SDL3_DLL%
    echo          Copy it into build\ manually or the exe will fail to start.
)

if /i "%ACTION%"=="run" (
    "build\ersavebackup.exe"
)
