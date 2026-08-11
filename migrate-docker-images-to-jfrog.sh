#!/bin/bash

set -euo pipefail

################################################################################
# Configuration Defaults
################################################################################
# Can be overridden by environment variables or a local .env file
JFROG_URL="${JFROG_URL:-docker-snapshot.abc.def.com}"
JFROG_REPO="${JFROG_REPO:-abc/alpfr/analytics/datarobot/dr_11_1_8}"

DRY_RUN=false
VENDOR=""
LOG_DIR="./logs"

################################################################################
# Usage Instructions
################################################################################
usage() {
    cat <<EOF
Usage:
    $0 [options]

Options:
    -v, --vendor NAME   Name of the vendor to search and migrate (e.g., rancher, datarobot)
    -d, --dry-run       Show what would be done without tagging or pushing
    -h, --help          Show this help message and exit

Environment Variables (can also be specified in a local .env file):
    JFROG_URL           Target JFrog domain (default: docker-snapshot.abc.def.com)
    JFROG_REPO          Target JFrog repository path (default: abc/alpfr/analytics/datarobot/dr_11_1_8)
EOF
    exit 1
}

# Parse arguments
while [[ "$#" -gt 0 ]]; do
    case $1 in
        -d|--dry-run)
            DRY_RUN=true
            ;;
        -v|--vendor)
            if [[ $# -lt 2 ]] || [[ "$2" == -* ]]; then
                echo "ERROR: --vendor requires a name argument." >&2
                usage
            fi
            VENDOR="$2"
            shift
            ;;
        -h|--help)
            usage
            ;;
        *)
            echo "ERROR: Unknown parameter: $1" >&2
            usage
            ;;
        esac
    shift
done

# Initialize Log Directory
mkdir -p "$LOG_DIR"
AUDIT_FILE="$LOG_DIR/audit_$(date +%Y%m%d_%H%M%S).log"

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

echo "======================================================="
echo "   Docker/Podman → JFrog Image Migration Script"
echo "======================================================="

if $DRY_RUN; then
    echo "⚠ DRY RUN MODE ENABLED — No images will be tagged or pushed"
fi
echo ""

# Prompt for vendor if not passed as an option
if [[ -z "$VENDOR" ]]; then
    read -r -p "Enter vendor name (e.g., rancher, datarobot): " VENDOR
fi

if [[ -z "$VENDOR" ]]; then
    echo "ERROR: Vendor cannot be empty. Exiting." >&2
    exit 1
fi

# Convert vendor name to lowercase for consistent matching
VENDOR_LOWER=$(echo "$VENDOR" | tr '[:upper:]' '[:lower:]')

echo "Searching for local ${CONTAINER_CLI} images matching vendor: $VENDOR"
echo "-------------------------------------------------------"

# Retrieve matching vendor images case-insensitively
IMAGES=$("$CONTAINER_CLI" images --format "{{.Repository}}:{{.Tag}}" | grep -i "$VENDOR" || true)

if [[ -z "$IMAGES" ]]; then
    echo "No images found matching vendor string: $VENDOR"
    exit 0
fi

# Count images safely
TOTAL_IMAGES=$(echo "$IMAGES" | grep -cv '^$' || true)

echo "Found $TOTAL_IMAGES images matching '$VENDOR':"
echo "$IMAGES"
echo "-------------------------------------------------------"
echo ""

# Helper to resolve clean target tags
get_target_image() {
    local source_image="$1"
    local vendor="$2"
    
    # 1. Strip registry prefix if present (e.g. docker.io/, quay.io/, registry.k8s.io/)
    local normalized_ref="$source_image"
    if [[ "$normalized_ref" == */* ]]; then
        local first_part="${normalized_ref%%/*}"
        if [[ "$first_part" == *.* || "$first_part" == *:* || "$first_part" == "localhost" ]]; then
            normalized_ref="${normalized_ref#*/}"
        fi
    fi
    
    # 2. Strip vendor namespace prefix if it starts with "$vendor/" to prevent nesting duplication
    local clean_image="$normalized_ref"
    if [[ "$clean_image" == "$vendor/"* ]]; then
        clean_image="${clean_image#"$vendor/"}"
    fi
    
    echo "${JFROG_URL}/${JFROG_REPO}/${vendor}/${clean_image}"
}

# Process the migration and stream logs to both console and audit trail file
{
    echo "=============================================="
    echo "Timestamp:          $(date)"
    echo "Vendor Search:      $VENDOR"
    echo "Dry Run:            $DRY_RUN"
    echo "Total Images Found: $TOTAL_IMAGES"
    echo "----------------------------------------------"
    
    SUCCESS_COUNT=0
    FAIL_COUNT=0

    while IFS= read -r IMAGE; do
        [[ -z "$IMAGE" ]] && continue
        echo "Processing: $IMAGE"

        # Resolve target reference path dynamically
        TARGET_IMAGE=$(get_target_image "$IMAGE" "$VENDOR_LOWER")
        echo "JFrog target: $TARGET_IMAGE"

        if $DRY_RUN; then
            echo "[DRY-RUN] Would tag  → $TARGET_IMAGE"
            echo "[DRY-RUN] Would push → $TARGET_IMAGE"
            SUCCESS_COUNT=$((SUCCESS_COUNT + 1))
        else
            if "$CONTAINER_CLI" tag "$IMAGE" "$TARGET_IMAGE" && "$CONTAINER_CLI" push "$TARGET_IMAGE"; then
                echo "✔ Successfully pushed: $TARGET_IMAGE"
                SUCCESS_COUNT=$((SUCCESS_COUNT + 1))
            else
                echo "✖ Failed to push: $TARGET_IMAGE"
                FAIL_COUNT=$((FAIL_COUNT + 1))
            fi
        fi
        echo "----------------------------------------------"
    done <<< "$IMAGES"

    echo ""
    echo "==================== SUMMARY ===================="
    echo "Vendor:            $VENDOR"
    echo "Total Images Found: $TOTAL_IMAGES"
    echo "Successful Pushes:  $SUCCESS_COUNT"
    echo "Failed Pushes:      $FAIL_COUNT"
    echo "Dry Run:            $DRY_RUN"
    echo "Audit log saved to: $AUDIT_FILE"
    echo "=================================================="
} | tee -a "$AUDIT_FILE"
