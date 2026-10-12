@echo off
rem Builds wintails.exe with MSYS2's mingw64 toolchain.
rem Append, don't prepend: MSYS2's bundled go.exe would shadow the real one.
set PATH=%PATH%;C:\msys64\mingw64\bin

cd /d %~dp0
rem Embeds wintails.manifest (Common Controls v6, i.e. themed controls).
windres wintails.rc -O coff -o wintails.res.o
if %ERRORLEVEL% neq 0 (
    echo BUILD_EXIT=%ERRORLEVEL%
    exit /b %ERRORLEVEL%
)
rem Statically link the gcc/stdc++/jansson runtimes so the only DLLs left to
rem ship alongside wintails.exe are libqrencode.dll and its own dependency
rem libwinpthread-1.dll (mingw-w64-x86_64-qrencode only ships a dynamic
rem build -- no libqrencode.a to link statically).
g++ -std=c++20 -municode -mwindows -O2 ^
    -static-libgcc -static-libstdc++ ^
    main.cpp rpc_client.cpp dialogs.cpp signin_dialog.cpp settings_dialog.cpp modal.cpp ssh_config.cpp system_proxy.cpp first_run.cpp ^
    wintails.res.o ^
    -IC:\msys64\mingw64\include ^
    -LC:\msys64\mingw64\lib ^
    -lcomctl32 -lcomdlg32 -lwininet -Wl,-Bstatic -ljansson -Wl,-Bdynamic -lqrencode -lshell32 -ladvapi32 ^
    -o wintails.exe
echo BUILD_EXIT=%ERRORLEVEL%
if %ERRORLEVEL% neq 0 exit /b %ERRORLEVEL%
copy /Y C:\msys64\mingw64\bin\libqrencode.dll . >nul
copy /Y C:\msys64\mingw64\bin\libwinpthread-1.dll . >nul
