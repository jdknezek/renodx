@echo off
setlocal

set "VSWHERE=%ProgramFiles(x86)%\Microsoft Visual Studio\Installer\vswhere.exe"
if not exist "%VSWHERE%" (
  echo vswhere.exe not found. Install Visual Studio Build Tools with the "Desktop development with C++" workload.
  exit /b 1
)

for /f "usebackq tokens=*" %%i in (`"%VSWHERE%" -latest -products * -requires Microsoft.VisualStudio.Component.VC.Tools.x86.x64 -property installationPath`) do (
  set "VS_INSTALL_PATH=%%i"
)

if not defined VS_INSTALL_PATH (
  echo Could not locate a Visual Studio installation with the VC.Tools.x86.x64 component.
  exit /b 1
)

call "%VS_INSTALL_PATH%\VC\Auxiliary\Build\vcvarsall.bat" x64
if errorlevel 1 exit /b 1

cmake --preset ninja-x64
if errorlevel 1 exit /b 1

cmake --build --preset ninja-x64-release --target ffxiv -j 18
if errorlevel 1 exit /b 1

copy /y build\Release\renodx-ffxiv.addon64 "C:\Program Files (x86)\Steam\steamapps\common\FINAL FANTASY XIV Online\game"

endlocal
