.PHONY: build run clean wintails msi docs

build:
	go build -C ntailsd -o ntailsd .

run:
	go run -C ntailsd .

# wintails cross-builds here, in wintails/shell.nix (needs nix). Outputs land
# in wintails/build/.
MSI_VERSION ?= 0.0.0.0
WINTAILS_SETUP := meson setup --reconfigure build --cross-file cross/mingw64.ini -Dversion=$(MSI_VERSION)

wintails:
	cd wintails && nix-shell --run '$(WINTAILS_SETUP) && meson compile -C build'

msi:
	cd wintails && nix-shell --run '$(WINTAILS_SETUP) && meson compile -C build msi'

# Previews the website at http://localhost:8000. Needs uv.
docs:
	uvx zensical@0.0.70 serve --open

clean:
	rm -rf ntailsd/ntailsd wintails/build site
