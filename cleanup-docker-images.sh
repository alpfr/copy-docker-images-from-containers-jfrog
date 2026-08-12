#!/bin/bash

set -euo pipefail

################################################################################
# Standalone Docker/Podman Image Cleanup Script
################################################################################

DRY_RUN=false
PATTERN=""

usage() {
    cat <<EOF
Usage:
    $0 -p <pattern> [options]

Arguments:
    -p, --pattern PATTERN   Search pattern/string to match images for cleanup (required)

Options:
    -d, --dry-run           Show which images would be removed without deleting them
    -h, --help              Show this help message and exit

Examples:
    $0 -p "dr_11_1_8"
    $0 -p "rancher" -d
EOF
    exit 1
}

# Parse arguments
while [[ "$#" -gt 0 ]]; do
    case $1 in
        -d|--dry-run)
            DRY_RUN=true
            ;;
        -p|--pattern)
            if [[ $# -lt 2 ]] || [[ "$2" == -* ]]; then
                echo "ERROR: --pattern requires an argument." >&2
                usage
            fi
            PATTERN="$2"
            shift
            ;;
        -h|--help)
            usage
            ;;
        *)
            echo "ERROR: Unknown option: $1" >&2
            usage
            ;;
    esac
    shift
done

if [[ -z "$PATTERN" ]]; then
    echo "ERROR: --pattern (-p) option is required." >&2
    usage
fi

# Detect container runtime CLI (docker or podman)
CONTAINER_CLI=""
if command -v docker >/dev/null 2>&1; then
    CONTAINER_CLI="docker"
elif command -v podman >/dev/null 2>&1; then
    CONTAINER_CLI="podman"
else
    echo "ERROR: Neither 'docker' nor 'podman' CLI tool was found in PATH." >&2
    exit 1
fi

echo "Searching for local ${CONTAINER_CLI} images matching pattern: '${PATTERN}'"
echo "-------------------------------------------------------"

# Retrieve matching vendor images case-insensitively
IMAGES=$("$CONTAINER_CLI" images --format "{{.Repository}}:{{.Tag}}" | grep -i "$PATTERN" || true)

if [[ -z "$IMAGES" ]]; then
    echo "No images found matching pattern: '${PATTERN}'"
    exit 0
fi

# Count images safely
IMAGE_COUNT=$(echo "$IMAGES" | grep -cv '^$' || true)

echo "Found ${IMAGE_COUNT} image(s) to clean up:"
echo "$IMAGES"
echo "-------------------------------------------------------"
echo ""

SUCCESS=0
FAILED=0

while IFS= read -r IMAGE; do
    [[ -z "$IMAGE" ]] && continue
    
    if $DRY_RUN; then
        echo "[DRY-RUN] Would remove image: ${IMAGE}"
        SUCCESS=$((SUCCESS + 1))
    else
        echo "Removing image: ${IMAGE}"
        # Try to delete, hide stderr to keep logs clean unless user needs it
        if "$CONTAINER_CLI" rmi "$IMAGE" >/dev/null 2>&1; then
            echo "✔ Removed successfully"
            SUCCESS=$((SUCCESS + 1))
        else
            echo "✖ Failed to remove ${IMAGE} (image may be in use by a container)"
            FAILED=$((FAILED + 1))
        fi
    fi
done <<< "$IMAGES"

# Sweep intermediate dangling layers
if ! $DRY_RUN; then
    echo
    echo "Sweeping intermediate dangling layers to reclaim additional space..."
    "$CONTAINER_CLI" image prune -f >/dev/null 2>&1 || true
fi

echo
echo "==================== Summary ===================="
echo "Pattern      : ${PATTERN}"
echo "Dry Run      : ${DRY_RUN}"
echo "Images Found : ${IMAGE_COUNT}"
echo "Removed      : ${SUCCESS}"
echo "Failed       : ${FAILED}"
echo "================================================="

if [[ ${FAILED} -gt 0 ]]; then
    exit 1
fi
