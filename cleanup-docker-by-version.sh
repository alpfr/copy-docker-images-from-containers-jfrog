#!/bin/bash

set -euo pipefail

################################################################################
# Version-Aware Docker/Podman Image Cleanup Script
# Safely purges local images <= a specified version (e.g. dr_11_1_7 and lower)
################################################################################

DRY_RUN=false
PATTERN=""
CUTOFF=""
EXACT=""
LOG_DIR="./logs"

usage() {
    cat <<EOF
Usage:
    $0 [options]

Arguments (Must specify exactly one of):
    -c, --cutoff VERSION    Cutoff version limit (e.g., dr_11_1_7 or 11.1.7).
                            Images <= this version will be deleted.
    -e, --exact VERSION     Exact version to delete (e.g., dr_11_1_7 or 11.1.7).
                            Only images == this version will be deleted.

Options:
    -p, --pattern PATTERN   Only process images matching this name pattern (e.g. datarobot, rancher).
                            If omitted, matches any images containing version tags.
    -d, --dry-run           Show which images would be removed without deleting them
    -h, --help              Show this help message and exit

Examples:
    $0 -c "dr_11_1_7"
    $0 -e "dr_11_1_7" -p "datarobot"
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
        -e|--exact)
            if [[ $# -lt 2 ]] || [[ "$2" == -* ]]; then
                echo "ERROR: --exact requires a version string." >&2
                usage
            fi
            EXACT="$2"
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

if [[ -z "$CUTOFF" ]] && [[ -z "$EXACT" ]]; then
    echo "ERROR: Either --cutoff (-c) or --exact (-e) option is required." >&2
    usage
fi

if [[ -n "$CUTOFF" ]] && [[ -n "$EXACT" ]]; then
    echo "ERROR: Cannot specify both --cutoff (-c) and --exact (-e)." >&2
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
if [[ -n "$EXACT" ]]; then
    echo "Target Exact Match  : == ${EXACT}"
else
    echo "Target Cutoff Limit : <= ${CUTOFF}"
fi
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
    if [[ -n "$EXACT" ]]; then
        echo "Target Version:      == $EXACT"
    else
        echo "Cutoff limit:        <= $CUTOFF"
    fi
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
        
        # 3. Compare image version tag
        local should_delete=false
        if [[ -n "$EXACT" ]]; then
            version_compare "$TAG" "$EXACT"
            if [[ $? -eq 0 ]]; then
                should_delete=true
            fi
        else
            version_compare "$TAG" "$CUTOFF"
            local cmp_res=$?
            if [[ $cmp_res -eq 0 ]] || [[ $cmp_res -eq 2 ]]; then
                should_delete=true
            fi
        fi
        
        # Action based on comparison
        if $should_delete; then
            local ver_info=""
            if [[ -n "$EXACT" ]]; then
                ver_info="version: $TAG == $EXACT"
            else
                ver_info="version: $TAG <= $CUTOFF"
            fi
            
            if $DRY_RUN; then
                echo "[DRY-RUN] Would remove: $IMAGE ($ver_info)"
                SUCCESS_COUNT=$((SUCCESS_COUNT + 1))
            else
                echo "Removing: $IMAGE ($ver_info)"
                if "$CONTAINER_CLI" rmi "$IMAGE" >/dev/null 2>&1; then
                    echo "✔ Removed successfully"
                    SUCCESS_COUNT=$((SUCCESS_COUNT + 1))
                else
                    echo "✖ Failed to remove $IMAGE (image may be in use by a container)"
                    FAIL_COUNT=$((FAIL_COUNT + 1))
                fi
            fi
        else
            if [[ -n "$EXACT" ]]; then
                echo "Keeping : $IMAGE (version: $TAG != $EXACT)"
            else
                echo "Keeping : $IMAGE (version: $TAG > $CUTOFF)"
            fi
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
    if [[ -n "$EXACT" ]]; then
        echo "Target Version:  == $EXACT"
    else
        echo "Cutoff Limit:    <= $CUTOFF"
    fi
    echo "Pattern Filter:  ${PATTERN:-[None]}"
    echo "Removed/Purged:  $SUCCESS_COUNT"
    echo "Failed:          $FAIL_COUNT"
    echo "Kept/Skipped:    $SKIP_COUNT"
    echo "Dry Run:         $DRY_RUN"
    echo "Audit log saved to: $AUDIT_FILE"
    echo "=================================================="
} | tee -a "$AUDIT_FILE"
