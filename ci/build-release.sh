#!/bin/sh
# Builds ntailsd release archives for every target into dist/.
# Usage: ci/build-release.sh <version>   (e.g. v0.3.0)
set -eu

version=$1
cd "$(dirname "$0")/.."
export CGO_ENABLED=0

rm -rf dist
mkdir dist

for target in darwin/arm64 darwin/amd64 linux/amd64 linux/arm64 windows/amd64; do
    os=${target%/*}
    arch=${target#*/}
    name="ntailsd-$version-$os-$arch"
    ext=
    [ "$os" = windows ] && ext=.exe

    mkdir "dist/$name"
    cp LICENSE "dist/$name/"
    (cd ntailsd && GOOS=$os GOARCH=$arch go build -trimpath \
        -ldflags "-s -w -X main.version=$version" \
        -o "../dist/$name/ntailsd$ext" .)

    if [ "$os" = windows ]; then
        (cd dist && zip -qr "$name.zip" "$name")
    else
        tar -C dist -czf "dist/$name.tar.gz" "$name"
    fi
    rm -r "dist/$name"
done

(cd dist && shasum -a 256 ./* > SHA256SUMS)
