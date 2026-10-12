@echo off
rem Builds ntailsd.exe and wintails\wintails.exe. Run on Windows; no Windows
rem C toolchain exists on the Mac.
setlocal
set CGO_ENABLED=1
set PATH=%PATH%;C:\msys64\mingw64\bin

cd /d %~dp0\..\ntailsd

go build -o ntailsd.exe .
if errorlevel 1 exit /b 1

copy /Y ntailsd.exe ..\wintails\ntailsd.exe >nul

pushd ..\wintails
rem Absolute path: with NoDefaultCurrentDirectoryInExePath set, cmd won't
rem find a bare "build.bat" in the current directory.
call "%~dp0build.bat"
set WINTAILS_EXIT=%ERRORLEVEL%
popd
exit /b %WINTAILS_EXIT%
