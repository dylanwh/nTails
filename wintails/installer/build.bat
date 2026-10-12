@echo off
rem Builds dist\ntails.msi from already-built ntailsd.exe and wintails/wintails.exe
rem (run wintails\windows-build.bat first). Needs WiX Toolset v3
rem (winget install --id WiXToolset.WiXToolset) -- no dotnet required.
setlocal
set PATH=%PATH%;C:\Program Files (x86)\WiX Toolset v3.14\bin

cd /d %~dp0
if not exist dist mkdir dist
if not exist obj mkdir obj

copy /Y ..\ntailsd.exe dist\ntailsd.exe >nul
copy /Y ..\wintails.exe dist\wintails.exe >nul
copy /Y ..\libqrencode.dll dist\libqrencode.dll >nul
copy /Y ..\libwinpthread-1.dll dist\libwinpthread-1.dll >nul

candle.exe -dDistDir=dist -out obj\ Product.wxs
if errorlevel 1 exit /b 1

rem Into dist\, next to what it packages (also: an ntails.msi left here by an
rem elevated build can't be overwritten from a normal prompt).
light.exe -out dist\ntails.msi obj\Product.wixobj
set LIGHT_EXIT=%ERRORLEVEL%
echo BUILD_EXIT=%LIGHT_EXIT%
rem exit with light's code: the echo above would otherwise reset it to 0
exit /b %LIGHT_EXIT%
