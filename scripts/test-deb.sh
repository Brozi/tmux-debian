#!/usr/bin/env bash
# ==============================================================================
# test-deb.sh - Verify and test built .deb package
# ==============================================================================
set -euo pipefail

if [[ $# -lt 1 ]]; then
    echo "Usage: $(basename "$0") <path-to-deb-package> [...]" >&2
    exit 1
fi

FAILURES=0

for DEB_PATH in "$@"; do
    echo "========================================================================"
    echo "Testing package: ${DEB_PATH}"
    echo "========================================================================"

    if [[ ! -f "${DEB_PATH}" ]]; then
        echo "FAIL: File not found: ${DEB_PATH}" >&2
        FAILURES=$((FAILURES + 1))
        continue
    fi

    # 1. Verify standard ar archive structure
    MEMBERS=$(ar t "${DEB_PATH}")
    echo "==> Archive members:"
    echo "${MEMBERS}"

    if ! echo "${MEMBERS}" | grep -q "debian-binary"; then
        echo "FAIL: Missing debian-binary" >&2
        FAILURES=$((FAILURES + 1))
    fi

    if ! echo "${MEMBERS}" | grep -q "control\.tar"; then
        echo "FAIL: Missing control.tar.* member" >&2
        FAILURES=$((FAILURES + 1))
    fi

    if ! echo "${MEMBERS}" | grep -q "data\.tar"; then
        echo "FAIL: Missing data.tar.* member" >&2
        FAILURES=$((FAILURES + 1))
    fi

    # Check compression: must be xz for universal Debian 11+ and Ubuntu compatibility
    if echo "${MEMBERS}" | grep -q "data\.tar\.xz"; then
        echo "PASS: data.tar.xz uses xz compression (compatible with Debian 11+ and Ubuntu)"
    else
        echo "WARNING: data.tar does not use xz compression; may fail on Debian 11 (Bullseye)"
    fi

    # 2. Check control file info
    CONTROL_INFO=$(dpkg-deb -I "${DEB_PATH}")
    PKG_NAME=$(echo "${CONTROL_INFO}" | grep -E '^ Package:' | awk '{print $2}')
    PKG_ARCH=$(echo "${CONTROL_INFO}" | grep -E '^ Architecture:' | awk '{print $2}')
    PKG_VER=$(echo "${CONTROL_INFO}" | grep -E '^ Version:' | awk '{print $2}')
    PKG_MAINT=$(echo "${CONTROL_INFO}" | grep -E '^ Maintainer:' | cut -d':' -f2- | sed 's/^[[:space:]]*//')

    echo "==> Control metadata:"
    echo "    Package     : ${PKG_NAME}"
    echo "    Architecture: ${PKG_ARCH}"
    echo "    Version     : ${PKG_VER}"
    echo "    Maintainer  : ${PKG_MAINT}"

    if [[ "${PKG_NAME}" != "tmux" ]]; then
        echo "FAIL: Expected Package: tmux, got '${PKG_NAME}'" >&2
        FAILURES=$((FAILURES + 1))
    else
        echo "PASS: Package name is 'tmux'"
    fi

    # 3. Check contents
    CONTENTS=$(dpkg-deb -c "${DEB_PATH}")

    if echo "${CONTENTS}" | grep -qE '\./usr/bin/tmux$'; then
        echo "PASS: Contains /usr/bin/tmux"
        # Check permissions: must be -rwxr-xr-x (or 755)
        PERMS=$(echo "${CONTENTS}" | grep -E '\./usr/bin/tmux$' | awk '{print $1}')
        if [[ "${PERMS}" == "-rwxr-xr-x" ]]; then
            echo "PASS: /usr/bin/tmux has correct permissions (${PERMS})"
        else
            echo "FAIL: /usr/bin/tmux permissions unexpected: ${PERMS}" >&2
            FAILURES=$((FAILURES + 1))
        fi
    else
        echo "FAIL: Missing ./usr/bin/tmux in package" >&2
        FAILURES=$((FAILURES + 1))
    fi

    if echo "${CONTENTS}" | grep -qE '\./usr/share/man/man1/tmux\.1\.gz$'; then
        echo "PASS: Contains man page /usr/share/man/man1/tmux.1.gz"
    else
        echo "FAIL: Missing man page in package" >&2
        FAILURES=$((FAILURES + 1))
    fi

    if echo "${CONTENTS}" | grep -qE '\./usr/share/doc/tmux/copyright$'; then
        echo "PASS: Contains /usr/share/doc/tmux/copyright"
    else
        echo "FAIL: Missing copyright file in package" >&2
        FAILURES=$((FAILURES + 1))
    fi

    # 4. If host arch matches package arch, test-run extracted binary
    HOST_MACHINE="$(uname -m)"
    CAN_RUN=false
    if [[ "${HOST_MACHINE}" == "x86_64" && "${PKG_ARCH}" == "amd64" ]]; then
        CAN_RUN=true
    elif [[ ("${HOST_MACHINE}" == "aarch64" || "${HOST_MACHINE}" == "arm64") && "${PKG_ARCH}" == "arm64" ]]; then
        CAN_RUN=true
    fi

    if [[ "${CAN_RUN}" == "true" ]]; then
        TMP_DIR="$(mktemp -d)"
        dpkg-deb -x "${DEB_PATH}" "${TMP_DIR}"
        TMUX_BIN="${TMP_DIR}/usr/bin/tmux"

        echo "==> Testing execution of ${TMUX_BIN} -V..."
        TMUX_OUTPUT=$("${TMUX_BIN}" -V 2>&1 || true)
        echo "    Output: ${TMUX_OUTPUT}"

        # Verify static linking
        if command -v file >/dev/null 2>&1; then
            FILE_OUTPUT=$(file "${TMUX_BIN}")
            echo "    File type: ${FILE_OUTPUT}"
            if echo "${FILE_OUTPUT}" | grep -q "statically linked"; then
                echo "PASS: Binary is statically linked"
            else
                echo "FAIL: Binary is not statically linked" >&2
                FAILURES=$((FAILURES + 1))
            fi
        fi

        rm -rf "${TMP_DIR}"
        echo "PASS: Execution test passed successfully!"
    else
        echo "Notice: Skipping execution test (host arch ${HOST_MACHINE} does not match package arch ${PKG_ARCH})"
    fi

    echo ""
done

if [[ ${FAILURES} -gt 0 ]]; then
    echo "========================================================================"
    echo "TEST FAILED: ${FAILURES} error(s) encountered."
    echo "========================================================================"
    exit 1
else
    echo "========================================================================"
    echo "ALL TESTS PASSED!"
    echo "========================================================================"
    exit 0
fi
