#!/bin/sh
set -e

# Ensure Go and user tool paths are available in Xcode's build environment
export PATH="/run/current-system/sw/bin:${HOME}/.nix-profile/bin:/opt/homebrew/bin:/usr/local/bin:${HOME}/.go/bin:${HOME}/go/bin:${PATH}"

# Xcode resets PATH for script phases, so CI passes GO_BIN explicitly.
if [ -n "${GO_BIN:-}" ]; then
	:
elif command -v go >/dev/null 2>&1; then
	GO_BIN="$(command -v go)"
elif [ -x "/run/current-system/sw/bin/go" ]; then
	GO_BIN="/run/current-system/sw/bin/go"
elif [ -x "/opt/homebrew/bin/go" ]; then
	GO_BIN="/opt/homebrew/bin/go"
elif [ -x "/usr/local/bin/go" ]; then
	GO_BIN="/usr/local/bin/go"
else
	echo "error: Go compiler not found in PATH or standard installation locations." >&2
	exit 1
fi

# Determine target destination inside the macOS app bundle
if [ -n "${BUILT_PRODUCTS_DIR}" ] && [ -n "${CONTENTS_FOLDER_PATH}" ]; then
	DEST_DIR="${BUILT_PRODUCTS_DIR}/${CONTENTS_FOLDER_PATH}/Helpers"
else
	DEST_DIR="${1:-${PROJECT_DIR}/../build}"
fi

mkdir -p "${DEST_DIR}"
TARGET_BIN="${DEST_DIR}/ntailsd"

GO_MODULE_DIR="${PROJECT_DIR}/../ntailsd"
if [ ! -f "${GO_MODULE_DIR}/go.mod" ]; then
	GO_MODULE_DIR="$(cd "$(dirname "$0")/../ntailsd" && pwd)"
fi

cd "${GO_MODULE_DIR}"
# Release builds set NTAILSD_VERSION to the git tag.
LDFLAGS="-s -w"
[ -n "${NTAILSD_VERSION:-}" ] && LDFLAGS="${LDFLAGS} -X main.version=${NTAILSD_VERSION}"

# One Go build per Xcode architecture, merged with lipo so the helper matches
# the app's slices. ntailsd has no cgo, so cross-compiling needs no toolchain.
export CGO_ENABLED=0
SLICES=
for arch in ${ARCHS:-$(uname -m)}; do
	case "${arch}" in
	x86_64) goarch=amd64 ;;
	*) goarch=${arch} ;;
	esac
	slice="${TARGET_BIN}.${arch}"
	echo "[nTails Build] Compiling Go backend (${goarch}) with ${GO_BIN} -> ${slice}"
	GOOS=darwin GOARCH=${goarch} "${GO_BIN}" build -trimpath \
		-tags ts_omit_portlist,ts_omit_useproxy -ldflags "${LDFLAGS}" -o "${slice}" .
	SLICES="${SLICES} ${slice}"
done
# shellcheck disable=SC2086
lipo -create ${SLICES} -output "${TARGET_BIN}"
rm -f ${SLICES}
chmod 755 "${TARGET_BIN}"

# Xcode signs only the main bundle; nested helpers need their own signature
# with hardened runtime for notarization.
SIGN_IDENTITY="${EXPANDED_CODE_SIGN_IDENTITY:-${CODE_SIGN_IDENTITY:--}}"
[ -z "${SIGN_IDENTITY}" ] && SIGN_IDENTITY="-"
if [ "${SIGN_IDENTITY}" = "-" ]; then
	codesign --force --options runtime --sign - --timestamp=none "${TARGET_BIN}"
else
	codesign --force --options runtime --timestamp --sign "${SIGN_IDENTITY}" "${TARGET_BIN}"
fi

echo "[nTails Build] Successfully bundled ntailsd into ${TARGET_BIN}"
