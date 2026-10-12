.PHONY: build run clean wintails wintails-sync msi docs

build:
	go build -C ntailsd -o ntailsd .

run:
	go run -C ntailsd .

# Builds ntailsd.exe and wintails/wintails.exe on a real Windows machine over
# SSH -- there's no Windows C toolchain here to cross-compile either one, so
# this can't run locally. Pass the box's address: make wintails WIN_HOST=...
#Fetches both binaries back into wintails/dist/windows/ when done.
# scp (not the ssh/PowerShell lines below) needs forward slashes even for a
# Windows path -- modern scp defaults to the SFTP protocol, which mangles
# backslashes into doubled escapes and then can't find the resulting path.
WIN_SRC := C:\Users\Dylan\ntails-src
WIN_SRC_SLASH := $(subst \,/,$(WIN_SRC))

wintails-sync:
	@test -n "$(WIN_HOST)" || (echo "WIN_HOST is not set. Usage: make wintails WIN_HOST=<host>"; exit 1)
	ssh $(WIN_HOST) 'New-Item -ItemType Directory -Force -Path $(WIN_SRC) | Out-Null'
	tar --exclude='.git' --exclude='.claude' --exclude='nTails' -cf /tmp/ntails-src.tar .
	scp /tmp/ntails-src.tar $(WIN_HOST):'$(WIN_SRC_SLASH).tar'
	ssh $(WIN_HOST) 'Remove-Item -Recurse -Force $(WIN_SRC)\ntailsd,$(WIN_SRC)\wintails -ErrorAction SilentlyContinue; tar.exe -xf $(WIN_SRC).tar -C $(WIN_SRC)'
	rm -f /tmp/ntails-src.tar

wintails: wintails-sync
	ssh $(WIN_HOST) 'cmd.exe /c $(WIN_SRC)\wintails\windows-build.bat'
	mkdir -p wintails/dist/windows
	scp $(WIN_HOST):'$(WIN_SRC_SLASH)/wintails/ntailsd.exe' wintails/dist/windows/ntailsd.exe
	scp $(WIN_HOST):'$(WIN_SRC_SLASH)/wintails/wintails.exe' wintails/dist/windows/wintails.exe
	scp $(WIN_HOST):'$(WIN_SRC_SLASH)/wintails/libqrencode.dll' wintails/dist/windows/libqrencode.dll
	scp $(WIN_HOST):'$(WIN_SRC_SLASH)/wintails/libwinpthread-1.dll' wintails/dist/windows/libwinpthread-1.dll
	@echo "Built wintails/dist/windows/{ntailsd.exe,wintails.exe,libqrencode.dll,libwinpthread-1.dll}"

# Builds ntails.msi (bundling both binaries + their runtime DLLs) on the
# Windows box via WiX Toolset v3 (winget install --id WiXToolset.WiXToolset
# -- needs only the .NET Framework already on Windows).
msi: wintails-sync
	ssh $(WIN_HOST) 'cmd.exe /c $(WIN_SRC)\wintails\windows-build.bat'
	ssh $(WIN_HOST) 'cmd.exe /c $(WIN_SRC)\wintails\installer\build.bat'
	mkdir -p wintails/dist/windows
	scp $(WIN_HOST):'$(WIN_SRC_SLASH)/wintails/installer/ntails.msi' wintails/dist/windows/ntails.msi
	@echo "Built wintails/dist/windows/ntails.msi"

# Previews the website at http://localhost:8000. Needs uv.
docs:
	uvx zensical@0.0.70 serve --open

clean:
	rm -rf ntailsd/ntailsd wintails/dist site
