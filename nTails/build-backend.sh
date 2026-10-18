#!/bin/sh
set -e

# Ensure Go and user tool paths are available in Xcode's build environment
export PATH="/run/current-system/sw/bin:${HOME}/.nix-profile/bin:/opt/homebrew/bin:/usr/local/bin:${HOME}/.go/bin:${HOME}/go/bin:${PATH}"

if command -v go >/dev/null 2>&1; then
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

echo "[nTails Build] Compiling Go backend with ${GO_BIN} -> ${TARGET_BIN}"
cd "${GO_MODULE_DIR}"
"${GO_BIN}" build -tags ts_omit_portlist,ts_omit_useproxy -o "${TARGET_BIN}" .
chmod 755 "${TARGET_BIN}"

# Sign the auxiliary binary with hardened runtime to satisfy macOS security requirements
if command -v codesign >/dev/null 2>&1; then
    SIGN_IDENTITY="${EXPANDED_CODE_SIGN_IDENTITY:-${CODE_SIGN_IDENTITY:--}}"
    [ -z "${SIGN_IDENTITY}" ] && SIGN_IDENTITY="-"
    if [ "${SIGN_IDENTITY}" != "-" ]; then
        codesign --force --options runtime --sign "${SIGN_IDENTITY}" "${TARGET_BIN}" 2>/dev/null || \
        codesign --force --options runtime --sign - --timestamp=none "${TARGET_BIN}" 2>/dev/null || true
    else
        codesign --force --options runtime --sign - --timestamp=none "${TARGET_BIN}" 2>/dev/null || true
    fi
fi

echo "[nTails Build] Successfully bundled ntailsd into ${TARGET_BIN}"
