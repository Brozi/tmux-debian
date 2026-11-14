#!/usr/bin/env bash
# ==============================================================================
# check-upstream.sh - Check for new tmux-builds releases
# ==============================================================================
set -euo pipefail

UPSTREAM_REPO="tmux/tmux-builds"
GITHUB_API="https://api.github.com/repos/${UPSTREAM_REPO}/releases/latest"

OUTPUT_JSON=false
CURRENT_TAG=""

usage() {
    cat <<EOF
Usage: $(basename "$0") [OPTIONS]

Check for the latest release in ${UPSTREAM_REPO} and compare against local/specified version.

Options:
  -c, --current <TAG>    Current tag to compare against (e.g. "v3.8" or "3.8")
  -j, --json             Output result as JSON
  -h, --help             Show this help message

Exit codes:
  0 - Checked successfully. If --current was provided, exits 0 if newer release exists.
  1 - Checked successfully, but current release is already up to date.
  2 - Error fetching or parsing release data.
EOF
    exit 0
}

while [[ $# -gt 0 ]]; do
    case "$1" in
        -c|--current)
            CURRENT_TAG="$2"
            shift 2
            ;;
        -j|--json)
            OUTPUT_JSON=true
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

# Fetch latest release JSON from GitHub API
API_HEADERS=(-H "Accept: application/vnd.github.v3+json" -H "User-Agent: tmux-deb-builder")
if [[ -n "${GITHUB_TOKEN:-}" ]]; then
    API_HEADERS+=(-H "Authorization: Bearer ${GITHUB_TOKEN}")
fi

RELEASE_DATA=$(curl -sSL --fail "${API_HEADERS[@]}" "${GITHUB_API}" 2>/dev/null) || {
    echo "Error: Failed to fetch latest release from GitHub API (${GITHUB_API})" >&2
    exit 2
}

if command -v jq >/dev/null 2>&1; then
    LATEST_TAG=$(echo "${RELEASE_DATA}" | jq -r '.tag_name // empty')
    LATEST_NAME=$(echo "${RELEASE_DATA}" | jq -r '.name // empty')
    PUBLISHED_AT=$(echo "${RELEASE_DATA}" | jq -r '.published_at // empty')
elif command -v python3 >/dev/null 2>&1; then
    LATEST_TAG=$(echo "${RELEASE_DATA}" | python3 -c "import sys, json; data=json.load(sys.stdin); print(data.get('tag_name',''))")
    LATEST_NAME=$(echo "${RELEASE_DATA}" | python3 -c "import sys, json; data=json.load(sys.stdin); print(data.get('name',''))")
    PUBLISHED_AT=$(echo "${RELEASE_DATA}" | python3 -c "import sys, json; data=json.load(sys.stdin); print(data.get('published_at',''))")
else
    LATEST_TAG=$(echo "${RELEASE_DATA}" | grep -m1 '"tag_name":' | sed -E 's/.*"tag_name":[[:space:]]*"([^"]+)".*/\1/')
    LATEST_NAME="${LATEST_TAG}"
    PUBLISHED_AT=$(echo "${RELEASE_DATA}" | grep -m1 '"published_at":' | sed -E 's/.*"published_at":[[:space:]]*"([^"]+)".*/\1/')
fi
LATEST_VERSION="${LATEST_TAG#v}"

if [[ -z "${LATEST_TAG}" ]]; then
    echo "Error: Could not extract latest tag from GitHub response" >&2
    exit 2
fi

# Normalize current tag for comparison if provided
CURRENT_NORMALIZED="${CURRENT_TAG#v}"
IS_NEW=false
if [[ -n "${CURRENT_TAG}" ]]; then
    if [[ "${LATEST_VERSION}" != "${CURRENT_NORMALIZED}" ]]; then
        IS_NEW=true
    fi
else
    IS_NEW=true
fi

# If running inside GitHub Actions, export output variables
if [[ -n "${GITHUB_OUTPUT:-}" ]]; then
    echo "latest_tag=${LATEST_TAG}" >> "${GITHUB_OUTPUT}"
    echo "latest_version=${LATEST_VERSION}" >> "${GITHUB_OUTPUT}"
    echo "is_new_release=${IS_NEW}" >> "${GITHUB_OUTPUT}"
fi

if [[ "${OUTPUT_JSON}" == "true" ]]; then
    cat <<EOF
{
  "upstream_repo": "${UPSTREAM_REPO}",
  "latest_tag": "${LATEST_TAG}",
  "latest_version": "${LATEST_VERSION}",
  "name": "${LATEST_NAME}",
  "published_at": "${PUBLISHED_AT}",
  "current_tag": "${CURRENT_TAG}",
  "is_new_release": ${IS_NEW}
}
EOF
else
    echo "Upstream Repository: ${UPSTREAM_REPO}"
    echo "Latest Release Tag : ${LATEST_TAG}"
    echo "Latest Version     : ${LATEST_VERSION}"
    echo "Release Name       : ${LATEST_NAME}"
    echo "Published At       : ${PUBLISHED_AT}"
    if [[ -n "${CURRENT_TAG}" ]]; then
        echo "Current Version    : ${CURRENT_TAG}"
        if [[ "${IS_NEW}" == "true" ]]; then
            echo "Status             : NEW RELEASE AVAILABLE!"
            exit 0
        else
            echo "Status             : Up to date."
            exit 1
        fi
    fi
fi
