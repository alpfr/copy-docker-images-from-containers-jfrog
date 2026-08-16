#!/bin/bash

set -euo pipefail

################################################################################
# Version-Aware Docker/Podman Image Cleanup Script
# Safely purges local images <= a specified version (e.g. dr_11_1_7 and lower)
################################################################################

DRY_RUN=false
PATTERN=""
CUTOFF=""
LOG_DIR="./logs"

usage() {
    cat <<EOF
Usage:
    $0 -c <version> [options]

Arguments:
    -c, --cutoff VERSION    Cutoff version limit (e.g., dr_11_1_7 or 11.1.7).
                            Images <= this version will be deleted. (required)

Options:
    -p, --pattern PATTERN   Only process images matching this name pattern (e.g. datarobot, rancher).
                            If omitted, matches any images containing version tags.
    -d, --dry-run           Show which images would be removed without deleting them
    -h, --help              Show this help message and exit

Examples:
    $0 -c "dr_11_1_7"
    $0 -c "11.1.7" -p "datarobot" -d
EOF
    exit 1
}

# Parse arguments
while [[ "$#" -gt 0 ]]; do
    case $1 in
        -d|--dry-run)
            DRY_RUN=true
            ;;
        -c|--cutoff)
            if [[ $# -lt 2 ]] || [[ "$2" == -* ]]; then
                echo "ERROR: --cutoff requires a version string." >&2
                usage
            fi
            CUTOFF="$2"
            shift
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

if [[ -z "$CUTOFF" ]]; then
    echo "ERROR: --cutoff (-c) option is required." >&2
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

# Initialize Log Directory
mkdir -p "$LOG_DIR"
AUDIT_FILE="$LOG_DIR/audit_version_cleanup_$(date +%Y%m%d_%H%M%S).log"

# Semantic/Component version comparison function
# Returns:
#   0 if ver1 == ver2
#   1 if ver1 > ver2
#   2 if ver1 < ver2
version_compare() {
    local ver1="$1"
    local ver2="$2"
    
    # Normalize by removing prefixes (like 'dr_', 'v'), translating '_' and '-' to '.'
    ver1=$(echo "$ver1" | sed -E 's/[^0-9._-]//g' | tr '_-' '..')
    ver2=$(echo "$ver2" | sed -E 's/[^0-9._-]//g' | tr '_-' '..')
    
    if [[ "$ver1" == "$ver2" ]]; then
        return 0
    fi
    
    local IFS=.
    local i
    local ver1_parts=()
    local ver2_parts=()
    read -r -a ver1_parts <<< "$ver1"
    read -r -a ver2_parts <<< "$ver2"
    
    # Pad shorter arrays with zeros
    for ((i=${#ver1_parts[@]}; i<${#ver2_parts[@]}; i++)); do
        ver1_parts[i]=0
    done
    for ((i=${#ver2_parts[@]}; i<${#ver1_parts[@]}; i++)); do
        ver2_parts[i]=0
    done
    
    # Compare parts numerically
    for ((i=0; i<${#ver1_parts[@]}; i++)); do
        local num1=$((ver1_parts[i] + 0)) 2>/dev/null || local num1=0
        local num2=$((ver2_parts[i] + 0)) 2>/dev/null || local num2=0
        
        if ((num1 > num2)); then
            return 1
        fi
        if ((num1 < num2)); then
            return 2
        fi
    done
    return 0
}

echo "======================================================="
echo "   Version-Aware Image Cleanup Script"
echo "======================================================="
echo "Target Cutoff Limit : <= ${CUTOFF}"
if [[ -n "$PATTERN" ]]; then
    echo "Image Filter Pattern: ${PATTERN}"
fi
if $DRY_RUN; then
    echo "⚠ DRY RUN MODE ENABLED — No images will be deleted"
fi
echo ""

# Get all images
IMAGE_LIST=$("$CONTAINER_CLI" images --format "{{.Repository}} {{.Tag}}" || true)

if [[ -z "$IMAGE_LIST" ]]; then
    echo "No images found in local container store."
    exit 0
fi

# Stream logs to both terminal and audit log
{
    echo "======================================================="
    echo "Timestamp:           $(date)"
    echo "Cutoff limit:        <= $CUTOFF"
    echo "Pattern filter:      ${PATTERN:-[None]}"
    echo "Dry Run:             $DRY_RUN"
    echo "-------------------------------------------------------"

    SUCCESS_COUNT=0
    FAIL_COUNT=0
    SKIP_COUNT=0

    while read -r REPO TAG; do
        [[ -z "$REPO" || -z "$TAG" ]] && continue
        IMAGE="${REPO}:${TAG}"
        
        # 1. Filter by repository pattern if specified
        if [[ -n "$PATTERN" ]]; then
            if ! echo "$REPO" | grep -iq "$PATTERN"; then
                continue
            fi
        fi
        
        # 2. Safety Check: Verify the tag contains digits (version numbers)
        # Prevents deleting latest, stable, or non-version tags
        if [[ ! "$TAG" =~ [0-9] ]]; then
            echo "Skipping: $IMAGE (tag does not contain version numbers)"
            SKIP_COUNT=$((SKIP_COUNT + 1))
            continue
        fi
        
        # 3. Compare image version tag with the cutoff limit
        version_compare "$TAG" "$CUTOFF"
        cmp_res=$?
        
        # cmp_res == 0 (equal) or cmp_res == 2 (less than cutoff)
        if [[ $cmp_res -eq 0 ]] || [[ $cmp_res -eq 2 ]]; then
            if $DRY_RUN; then
                echo "[DRY-RUN] Would remove: $IMAGE (version: $TAG <= $CUTOFF)"
                SUCCESS_COUNT=$((SUCCESS_COUNT + 1))
            else
                echo "Removing: $IMAGE (version: $TAG <= $CUTOFF)"
                if "$CONTAINER_CLI" rmi "$IMAGE" >/dev/null 2>&1; then
                    echo "✔ Removed successfully"
                    SUCCESS_COUNT=$((SUCCESS_COUNT + 1))
                else
                    echo "✖ Failed to remove $IMAGE (image may be in use by a container)"
                    FAIL_COUNT=$((FAIL_COUNT + 1))
                fi
            fi
        else
            echo "Keeping : $IMAGE (version: $TAG > $CUTOFF)"
            SKIP_COUNT=$((SKIP_COUNT + 1))
        fi
        echo "-------------------------------------------------------"
    done <<< "$IMAGE_LIST"

    # Sweep dangling intermediate layers
    if ! $DRY_RUN; then
        echo
        echo "Sweeping intermediate dangling layers to reclaim additional space..."
        "$CONTAINER_CLI" image prune -f >/dev/null 2>&1 || true
    fi

    echo ""
    echo "==================== SUMMARY ===================="
    echo "Cutoff Limit:    <= $CUTOFF"
    echo "Pattern Filter:  ${PATTERN:-[None]}"
    echo "Removed/Purged:  $SUCCESS_COUNT"
    echo "Failed:          $FAIL_COUNT"
    echo "Kept/Skipped:    $SKIP_COUNT"
    echo "Dry Run:         $DRY_RUN"
    echo "Audit log saved to: $AUDIT_FILE"
    echo "=================================================="
} | tee -a "$AUDIT_FILE"
