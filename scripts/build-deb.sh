#!/usr/bin/env bash
# ==============================================================================
# build-deb.sh - Build universal .deb packages from tmux-builds
# ==============================================================================
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"

# Load package configuration defaults
if [[ -f "${REPO_ROOT}/package.env" ]]; then
    # shellcheck source=../package.env
    source "${REPO_ROOT}/package.env"
fi

UPSTREAM_REPO="tmux/tmux-builds"
TMUX_SOURCE_REPO="tmux/tmux"

# Detect host architecture
detect_host_arch() {
    local machine
    machine="$(uname -m)"
    case "${machine}" in
        x86_64) echo "amd64" ;;
        aarch64|arm64) echo "arm64" ;;
        *) echo "${machine}" ;;
    esac
}

VERSION="latest"
TARGET_ARCH="$(detect_host_arch)"
REVISION="${PACKAGE_REVISION:-1}"
OUT_DIR="${REPO_ROOT}/dist"
CACHE_DIR="${REPO_ROOT}/.cache"
PREFIX="/usr"
DISTRO_SUFFIX=""
CLEAN_BUILD=false
VERBOSE=false

usage() {
    cat <<EOF
Usage: $(basename "$0") [OPTIONS]

Build Debian/Ubuntu (.deb) packages from tmux/tmux-builds release binaries.
Produces universal packages compatible with Debian 11 (Bullseye), Debian 12 (Bookworm),
Debian 13 (Trixie), Debian 14 (Forky), Debian Sid, and Ubuntu Jammy, Noble, Questing, Resolute.

Options:
  -v, --version <VER>    tmux version to package (e.g. "3.8", "v3.8", "latest", "preview")
                         Default: "latest"
  -a, --arch <ARCH>      Target architecture: "amd64", "arm64", or "all" / "both"
                         Default: detected host architecture ("$(detect_host_arch)")
  -r, --revision <REV>   Debian package revision suffix (default: "${REVISION}")
  -o, --out-dir <DIR>    Output directory for built .deb files (default: "./dist")
  -p, --prefix <DIR>     Installation prefix inside package (default: "/usr")
  -m, --maintainer <STR> Override package maintainer
  --distro <NAME>        Optional distribution suffix (e.g. "noble" -> 3.8-1~noble_amd64.deb)
                         Leave empty for universal package (recommended)
  --clean                Clean staging directory after build
  --verbose              Enable verbose logging
  -h, --help             Show this help message

Examples:
  $(basename "$0")                          # Build latest version for host architecture
  $(basename "$0") -a all                   # Build latest version for both amd64 and arm64
  $(basename "$0") -v 3.8 -a all            # Build specific version 3.8 for all architectures
  $(basename "$0") -v preview -a amd64      # Build latest preview build
EOF
    exit 0
}

while [[ $# -gt 0 ]]; do
    case "$1" in
        -v|--version)
            VERSION="$2"
            shift 2
            ;;
        -a|--arch)
            TARGET_ARCH="$2"
            shift 2
            ;;
        -r|--revision)
            REVISION="$2"
            shift 2
            ;;
        -o|--out-dir)
            OUT_DIR="$2"
            shift 2
            ;;
        -p|--prefix)
            PREFIX="$2"
            shift 2
            ;;
        -m|--maintainer)
            MAINTAINER="$2"
            shift 2
            ;;
        --distro)
            DISTRO_SUFFIX="$2"
            shift 2
            ;;
        --clean)
            CLEAN_BUILD=true
            shift
            ;;
        --verbose)
            VERBOSE=true
            shift
            ;;
        -h|--help)
            usage
            ;;
        *)
            echo "Unknown option: $1" >&2
            usage
            ;;
    esac
done

if [[ "${VERBOSE}" == "true" ]]; then
    set -x
fi

# Ensure required host build tools are present
for tool in dpkg-deb curl tar gzip; do
    if ! command -v "${tool}" >/dev/null 2>&1; then
        echo "Error: Required command '${tool}' is not installed." >&2
        exit 1
    fi
done

mkdir -p "${OUT_DIR}" "${CACHE_DIR}"

API_HEADERS=(-H "Accept: application/vnd.github.v3+json" -H "User-Agent: tmux-deb-builder")
if [[ -n "${GITHUB_TOKEN:-}" ]]; then
    API_HEADERS+=(-H "Authorization: Bearer ${GITHUB_TOKEN}")
fi

echo "==> Resolving release for version: ${VERSION}..."
if [[ "${VERSION}" == "latest" ]]; then
    RELEASE_JSON=$(curl -sSL --fail "${API_HEADERS[@]}" "https://api.github.com/repos/${UPSTREAM_REPO}/releases/latest") || {
        echo "Error: Failed to fetch latest release from ${UPSTREAM_REPO}" >&2
        exit 1
    }
    TAG_NAME=$(echo "${RELEASE_JSON}" | grep -m1 '"tag_name":' | sed -E 's/.*"tag_name":[[:space:]]*"([^"]+)".*/\1/')
    PKG_VERSION="${TAG_NAME#v}"
elif [[ "${VERSION}" == "preview" ]]; then
    RELEASE_JSON=$(curl -sSL --fail "${API_HEADERS[@]}" "https://api.github.com/repos/${UPSTREAM_REPO}/releases/tags/preview") || {
        echo "Error: Failed to fetch preview release from ${UPSTREAM_REPO}" >&2
        exit 1
    }
    TAG_NAME="preview"
    # Preview versions use date and commit sha for clean sorting in dpkg
    PREVIEW_SHA=$(echo "${RELEASE_JSON}" | grep -oE 'tmux-[0-9]{8}-[0-9a-f]{8}-linux' | head -n1 | cut -d'-' -f2,3 || echo "preview")
    PKG_VERSION="0~preview.${PREVIEW_SHA}"
else
    # Explicit version given (e.g. "3.8" or "v3.8")
    PKG_VERSION="${VERSION#v}"
    TAG_NAME="v${PKG_VERSION}"
    RELEASE_JSON=$(curl -sSL --fail "${API_HEADERS[@]}" "https://api.github.com/repos/${UPSTREAM_REPO}/releases/tags/${TAG_NAME}") || {
        echo "Error: Failed to fetch release ${TAG_NAME} from ${UPSTREAM_REPO}" >&2
        exit 1
    }
fi

echo "    Release Tag    : ${TAG_NAME}"
echo "    Package Version: ${PKG_VERSION}"

# Determine target architectures to build
ARCH_LIST=()
if [[ "${TARGET_ARCH}" == "all" || "${TARGET_ARCH}" == "both" ]]; then
    ARCH_LIST=("amd64" "arm64")
else
    ARCH_LIST=("${TARGET_ARCH}")
fi

# Download LICENSES.tar.gz once if available
LICENSES_TAR="${CACHE_DIR}/LICENSES-${TAG_NAME}.tar.gz"
LICENSES_URL=$(echo "${RELEASE_JSON}" | grep -o 'https://[^"]*LICENSES\.tar\.gz' | head -n1 || true)
if [[ -n "${LICENSES_URL}" && ! -f "${LICENSES_TAR}" ]]; then
    echo "==> Downloading licenses bundle (${LICENSES_URL})..."
    curl -sSL -o "${LICENSES_TAR}" "${LICENSES_URL}" || rm -f "${LICENSES_TAR}"
fi

# Fetch tmux.1 man page from upstream tmux/tmux repo
MANPAGE_CACHE="${CACHE_DIR}/tmux-${PKG_VERSION}.1"
if [[ ! -f "${MANPAGE_CACHE}" ]]; then
    echo "==> Fetching man page from upstream tmux repository..."
    UPSTREAM_MAN_URL="https://raw.githubusercontent.com/${TMUX_SOURCE_REPO}/${TAG_NAME}/tmux.1"
    if ! curl -sSL --fail -o "${MANPAGE_CACHE}" "${UPSTREAM_MAN_URL}" 2>/dev/null; then
        echo "    Notice: Man page for tag ${TAG_NAME} not found directly, falling back to master branch..."
        curl -sSL --fail -o "${MANPAGE_CACHE}" "https://raw.githubusercontent.com/${TMUX_SOURCE_REPO}/master/tmux.1" || rm -f "${MANPAGE_CACHE}"
    fi
fi

BUILT_PACKAGES=()

for ARCH in "${ARCH_LIST[@]}"; do
    case "${ARCH}" in
        amd64) UPSTREAM_ARCH="x86_64" ;;
        arm64) UPSTREAM_ARCH="arm64" ;;
        *)
            echo "Error: Unsupported Debian architecture '${ARCH}'. Supported: amd64, arm64." >&2
            exit 1
            ;;
    esac

    echo ""
    echo "========================================================================"
    echo "==> Building package for architecture: ${ARCH} (${UPSTREAM_ARCH})"
    echo "========================================================================"

    # Find the matching tar.gz asset URL in release json
    ASSET_URL=$(echo "${RELEASE_JSON}" | grep -oE "https://[^\"]+linux-${UPSTREAM_ARCH}\.tar\.gz" | head -n1 || true)
    if [[ -z "${ASSET_URL}" ]]; then
        echo "Error: Could not locate release asset for linux-${UPSTREAM_ARCH} in release ${TAG_NAME}" >&2
        exit 1
    fi

    ARCHIVE_NAME="$(basename "${ASSET_URL}")"
    CACHED_ARCHIVE="${CACHE_DIR}/${ARCHIVE_NAME}"

    if [[ ! -f "${CACHED_ARCHIVE}" ]]; then
        echo "==> Downloading ${ASSET_URL}..."
        curl -sSL -o "${CACHED_ARCHIVE}" "${ASSET_URL}"
    else
        echo "==> Using cached archive: ${CACHED_ARCHIVE}"
    fi

    # Prepare staging directory
    BUILD_DIR="${REPO_ROOT}/build/${PKG_VERSION}_${ARCH}"
    rm -rf "${BUILD_DIR}"
    mkdir -p "${BUILD_DIR}/DEBIAN"
    mkdir -p "${BUILD_DIR}${PREFIX}/bin"
    mkdir -p "${BUILD_DIR}${PREFIX}/share/man/man1"
    mkdir -p "${BUILD_DIR}${PREFIX}/share/doc/tmux"

    # Extract binary into staging directory
    echo "==> Extracting binary to ${PREFIX}/bin/tmux..."
    tar -xzf "${CACHED_ARCHIVE}" -C "${BUILD_DIR}${PREFIX}/bin"
    chmod 0755 "${BUILD_DIR}${PREFIX}/bin/tmux"

    # Verify binary is executable
    if [[ ! -x "${BUILD_DIR}${PREFIX}/bin/tmux" ]]; then
        echo "Error: Extracted binary ${BUILD_DIR}${PREFIX}/bin/tmux is missing or not executable" >&2
        exit 1
    fi

    # Install compressed man page
    if [[ -f "${MANPAGE_CACHE}" ]]; then
        echo "==> Installing man page to ${PREFIX}/share/man/man1/tmux.1.gz..."
        gzip -9n -c "${MANPAGE_CACHE}" > "${BUILD_DIR}${PREFIX}/share/man/man1/tmux.1.gz"
        chmod 0644 "${BUILD_DIR}${PREFIX}/share/man/man1/tmux.1.gz"
    fi

    # Install copyright file
    COPYRIGHT_FILE="${BUILD_DIR}${PREFIX}/share/doc/tmux/copyright"
    cat <<EOF > "${COPYRIGHT_FILE}"
Format: https://www.debian.org/doc/packaging-manuals/copyright-format/1.0/
Upstream-Name: tmux
Upstream-Contact: Nicholas Marriott <nicholas.marriott@gmail.com>
Source: https://github.com/tmux/tmux
Binary-Build: https://github.com/tmux/tmux-builds

Files: *
Copyright: 2007-2026 Nicholas Marriott <nicholas.marriott@gmail.com>
License: ISC or BSD-2-Clause or BSD-3-Clause

--------------------------------------------------------------------------------
This package contains a statically linked binary combining tmux with:
- musl libc (MIT License)
- libevent (BSD-3-Clause License)
- ncurses (MIT / X11-style License)
- utf8proc (MIT License)

Licenses for all bundled components follow below.
--------------------------------------------------------------------------------
EOF

    # If LICENSES.tar.gz was downloaded, append subcomponent licenses
    if [[ -f "${LICENSES_TAR}" ]]; then
        LICENSES_TMP="${BUILD_DIR}/.licenses_tmp"
        mkdir -p "${LICENSES_TMP}"
        tar -xzf "${LICENSES_TAR}" -C "${LICENSES_TMP}"
        for lic in "${LICENSES_TMP}"/*; do
            if [[ -f "${lic}" ]]; then
                fname="$(basename "${lic}")"
                echo "" >> "${COPYRIGHT_FILE}"
                echo "=== License Component: ${fname} ===" >> "${COPYRIGHT_FILE}"
                cat "${lic}" >> "${COPYRIGHT_FILE}"
            fi
        done
        rm -rf "${LICENSES_TMP}"
    fi
    chmod 0644 "${COPYRIGHT_FILE}"

    # Install README.Debian if present
    if [[ -f "${REPO_ROOT}/debian/README.Debian" ]]; then
        cp "${REPO_ROOT}/debian/README.Debian" "${BUILD_DIR}${PREFIX}/share/doc/tmux/README.Debian"
        chmod 0644 "${BUILD_DIR}${PREFIX}/share/doc/tmux/README.Debian"
    fi

    # Generate md5sums file for installed contents
    echo "==> Generating DEBIAN/md5sums..."
    (
        cd "${BUILD_DIR}"
        find "${PREFIX#\/}" -type f ! -path 'DEBIAN/*' -exec md5sum {} + > DEBIAN/md5sums
        chmod 0644 DEBIAN/md5sums
    )

    # Compute Installed-Size in KB (standard Debian convention)
    INSTALLED_SIZE=$(du -ks "${BUILD_DIR}${PREFIX}" | cut -f1)

    # Construct version string
    if [[ -n "${DISTRO_SUFFIX}" ]]; then
        PACKAGE_FULL_VERSION="${PKG_VERSION}-${REVISION}~${DISTRO_SUFFIX}"
        DEB_FILENAME="${PACKAGE_NAME}_${PACKAGE_FULL_VERSION}_${ARCH}.deb"
    else
        PACKAGE_FULL_VERSION="${PKG_VERSION}-${REVISION}"
        DEB_FILENAME="${PACKAGE_NAME}_${PACKAGE_FULL_VERSION}_${ARCH}.deb"
    fi

    # Generate DEBIAN/control from template
    echo "==> Generating DEBIAN/control..."
    TEMPLATE_FILE="${REPO_ROOT}/debian/control.template"
    if [[ ! -f "${TEMPLATE_FILE}" ]]; then
        echo "Error: Template file ${TEMPLATE_FILE} not found" >&2
        exit 1
    fi

    # Render template using Python for clean, safe variable interpolation
    python3 -c "
import sys

with open('${TEMPLATE_FILE}', 'r') as f:
    template = f.read()

replacements = {
    '\${PACKAGE_NAME}': '${PACKAGE_NAME}',
    '\${PACKAGE_FULL_VERSION}': '${PACKAGE_FULL_VERSION}',
    '\${PACKAGE_VERSION}': '${PKG_VERSION}',
    '\${PACKAGE_REVISION}': '${REVISION}',
    '\${DEB_ARCH}': '${ARCH}',
    '\${MAINTAINER}': '''${MAINTAINER}''',
    '\${INSTALLED_SIZE}': '${INSTALLED_SIZE}',
    '\${SECTION}': '${SECTION}',
    '\${PRIORITY}': '${PRIORITY}',
    '\${HOMEPAGE}': '${HOMEPAGE}',
    '\${PROVIDES}': '${PROVIDES}',
    '\${REPLACES}': '${REPLACES}',
    '\${CONFLICTS}': '${CONFLICTS}',
    '\${DESCRIPTION_SUMMARY}': '''${DESCRIPTION_SUMMARY}''',
    '\${DESCRIPTION_BODY}': '''${DESCRIPTION_BODY}'''
}

rendered = template
for key, val in replacements.items():
    rendered = rendered.replace(key, val)

# Filter out empty optional fields (like Conflicts: if empty)
lines = []
for line in rendered.splitlines():
    if line.startswith(('Conflicts: ', 'Replaces: ', 'Provides: ')) and not line.split(':', 1)[1].strip():
        continue
    lines.append(line)

with open('${BUILD_DIR}/DEBIAN/control', 'w') as f:
    f.write('\n'.join(lines) + '\n')
"
    chmod 0644 "${BUILD_DIR}/DEBIAN/control"

    # Build the package with dpkg-deb using xz compression
    # -Zxz ensures compatibility with Debian 11 (Bullseye) through 14 and Ubuntu 22.04+
    TARGET_DEB="${OUT_DIR}/${DEB_FILENAME}"
    echo "==> Assembling .deb package: ${TARGET_DEB} (compression: xz)..."
    dpkg-deb -Zxz --build --root-owner-group "${BUILD_DIR}" "${TARGET_DEB}"

    # Generate SHA256 checksum
    (
        cd "${OUT_DIR}"
        sha256sum "${DEB_FILENAME}" > "${DEB_FILENAME}.sha256"
    )

    BUILT_PACKAGES+=("${TARGET_DEB}")

    if [[ "${CLEAN_BUILD}" == "true" ]]; then
        rm -rf "${BUILD_DIR}"
    fi
done

echo ""
echo "========================================================================"
echo " Packaging completed successfully!"
echo "========================================================================"
for pkg in "${BUILT_PACKAGES[@]}"; do
    echo "  Package: ${pkg}"
    echo "  Size   : $(du -h "${pkg}" | cut -f1)"
    echo "  SHA256 : $(cut -d' ' -f1 "${pkg}.sha256")"
    echo "------------------------------------------------------------------------"
done
